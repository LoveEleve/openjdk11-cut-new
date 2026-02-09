# Ch17: JVMTI 事件体系 — 从 Event 注册到 Callback 分发

> 基于 OpenJDK 11 源码 | HotSpot JVMTI 深度分析
> 模块 A（第 3 篇 / 共 4 篇）| PerfMa 面试价值：⭐⭐⭐⭐

---

## 17.1 总览：JVMTI 事件体系解决什么问题？

### 核心场景

JVMTI (JVM Tool Interface) 需要让外部 Agent（调试器、APM 工具、Java Agent）在 JVM 的各种**关键时刻**收到通知。

关键时刻包括：类加载、方法进入/退出、异常抛出、字段访问/修改、GC 开始/结束、线程创建/销毁、断点命中等。

### 设计挑战

1. **多环境并存**：可能同时有多个 Agent（多个 JvmtiEnv），每个 Agent 关心不同的事件
2. **细粒度控制**：某个事件可以全局启用，也可以只对特定线程启用
3. **性能极致**：没有 Agent 时，事件检查的开销必须为零或接近零
4. **Phase 约束**：不同的 JVM 生命周期阶段，可启用的事件不同
5. **线程安全**：多线程并发触发事件，回调必须安全

### 整体架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                        JVMTI 事件体系架构                            │
│                                                                     │
│  Agent 代码                                                         │
│  ──────────                                                         │
│  SetEventCallbacks(callbacks)  ← 注册回调函数                       │
│  SetEventNotificationMode(ENABLE, event, thread)  ← 启用事件        │
│       │                                                             │
│       ▼                                                             │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │             JvmtiEventController（事件控制器）                 │   │
│  │                                                              │   │
│  │  四层数据结构：                                                │   │
│  │  ┌────────────────────────────────────────────────────────┐  │   │
│  │  │ L1: JvmtiEnvEventEnable（每个环境）                     │  │   │
│  │  │     _event_user_enabled     ← Agent 设置的启用位        │  │   │
│  │  │     _event_callback_enabled ← 有回调函数的事件位        │  │   │
│  │  │     _event_enabled          ← 真正启用 = user & callback│  │   │
│  │  ├────────────────────────────────────────────────────────┤  │   │
│  │  │ L2: JvmtiEnvThreadEventEnable（每个环境×每个线程）      │  │   │
│  │  │     _event_user_enabled     ← 线程级启用位              │  │   │
│  │  │     _event_enabled          ← 线程级真正启用            │  │   │
│  │  ├────────────────────────────────────────────────────────┤  │   │
│  │  │ L3: JvmtiThreadEventEnable（每个线程，跨所有环境）      │  │   │
│  │  │     _event_enabled          ← 该线程上任何环境启用的    │  │   │
│  │  ├────────────────────────────────────────────────────────┤  │   │
│  │  │ L4: _universal_global_event_enabled（全局）             │  │   │
│  │  │     ← 任何线程任何环境启用的事件的并集                   │  │   │
│  │  └────────────────────────────────────────────────────────┘  │   │
│  │                                                              │   │
│  │  核心方法: recompute_enabled()                                │   │
│  │  → 从 L1 聚合到 L2 → 聚合到 L3 → 聚合到 L4                  │   │
│  │  → 设置 JvmtiExport::_should_post_xxx 全局标志               │   │
│  └──────────────────────────────────────────────────────────────┘   │
│       │                                                             │
│       ▼                                                             │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │             JvmtiExport（事件分发器）                          │   │
│  │                                                              │   │
│  │  HotSpot 各处埋点：                                           │   │
│  │  ├── ClassFileParser      → post_class_file_load_hook()      │   │
│  │  ├── SystemDictionary     → post_class_load() / prepare()    │   │
│  │  ├── Interpreter 入口     → post_method_entry/exit()         │   │
│  │  ├── ObjectMonitor        → post_monitor_xxx()               │   │
│  │  ├── G1GC / 其他 GC      → post_gc_start/finish()           │   │
│  │  ├── Thread::start/end    → post_thread_start/end()          │   │
│  │  └── ...                                                     │   │
│  │                                                              │   │
│  │  分发模式（两种）：                                            │   │
│  │  ├── 全局事件：遍历所有 JvmtiEnv                              │   │
│  │  └── 线程过滤事件：遍历该线程的 JvmtiEnvThreadState           │   │
│  └──────────────────────────────────────────────────────────────┘   │
│       │                                                             │
│       ▼                                                             │
│  Agent 回调函数执行                                                  │
│  ─────────────────                                                  │
│  callback(jvmtiEnv, JNIEnv, jthread, ...)                           │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 17.2 事件分类：全局事件 vs 线程过滤事件

JVMTI 事件分为两大类，这决定了它们的启用方式和分发机制。

### 位图定义

**文件**：`jvmtiEventController.cpp` (line 50-100)

```
THREAD_FILTERED_EVENT_BITS（线程可过滤事件）：
  ├── SINGLE_STEP_BIT          ← 单步调试
  ├── FRAME_POP_BIT            ← 帧弹出
  ├── BREAKPOINT_BIT           ← 断点
  ├── FIELD_ACCESS_BIT         ← 字段读取
  ├── FIELD_MODIFICATION_BIT   ← 字段修改
  ├── METHOD_ENTRY_BIT         ← 方法进入
  ├── METHOD_EXIT_BIT          ← 方法退出
  ├── EXCEPTION_THROW_BIT      ← 异常抛出
  ├── EXCEPTION_CATCH_BIT      ← 异常捕获
  ├── MONITOR_CONTENDED_ENTER_BIT   ← 锁竞争进入
  ├── MONITOR_CONTENDED_ENTERED_BIT ← 锁竞争获得
  ├── MONITOR_WAIT_BIT         ← Object.wait()
  ├── MONITOR_WAITED_BIT       ← Object.wait() 返回
  ├── CLASS_LOAD_BIT           ← 类加载
  ├── CLASS_PREPARE_BIT        ← 类准备
  └── THREAD_END_BIT           ← 线程结束

GLOBAL_EVENT_BITS（全局事件）= ~THREAD_FILTERED_EVENT_BITS：
  ├── VM_START / VM_INIT / VM_DEATH
  ├── CLASS_FILE_LOAD_HOOK     ← ClassFileLoadHook（Ch15 分析过）
  ├── NATIVE_METHOD_BIND
  ├── COMPILED_METHOD_LOAD / UNLOAD
  ├── DYNAMIC_CODE_GENERATED
  ├── DATA_DUMP_REQUEST
  ├── GARBAGE_COLLECTION_START / FINISH
  ├── OBJECT_FREE
  ├── RESOURCE_EXHAUSTED
  ├── VM_OBJECT_ALLOC
  ├── SAMPLED_OBJECT_ALLOC
  └── THREAD_START
```

### 差异

| 维度 | 全局事件 | 线程过滤事件 |
|------|---------|-------------|
| 启用方式 | 只能全局启用 | 可全局启用，也可按线程启用 |
| 存储位置 | `JvmtiEnvEventEnable` | `JvmtiEnvThreadEventEnable` |
| 分发遍历 | `JvmtiEnvIterator`（遍历所有环境） | `JvmtiEnvThreadStateIterator`（遍历该线程的环境状态） |
| 典型使用 | GC 回调、类加载钩子 | 断点、单步、方法进出 |

### 特殊位图

```
INTERP_EVENT_BITS（需要进入解释器模式的事件）：
  = SINGLE_STEP | METHOD_ENTRY | METHOD_EXIT | FRAME_POP
    | FIELD_ACCESS | FIELD_MODIFICATION
  
  → 启用这些事件时，线程必须进入 interp_only_mode
  → 禁止 JIT 编译代码执行，所有帧必须反优化到解释器
  → 这就是调试模式会显著降低性能的原因

SHOULD_POST_ON_EXCEPTIONS_BITS：
  = EXCEPTION_THROW | EXCEPTION_CATCH | METHOD_EXIT | FRAME_POP
  → 设置到 JavaThread 上，用于快速判断异常处理路径是否需要通知 JVMTI

EARLY_EVENT_BITS（VM 启动早期可用的事件）：
  = CLASS_FILE_LOAD_HOOK | CLASS_LOAD | CLASS_PREPARE
    | VM_START | VM_INIT | VM_DEATH | NATIVE_METHOD_BIND
    | THREAD_START | THREAD_END | COMPILED_METHOD_LOAD/UNLOAD
    | DYNAMIC_CODE_GENERATED
```

---

## 17.3 四层事件启用数据结构

### 底层基础：JvmtiEventEnabled

```
JvmtiEventEnabled:
  _enabled_bits : jlong (64 位)
  
  每个 bit 对应一个事件类型：
  bit 0 = EXT_EVENT_CLASS_UNLOAD (扩展事件)
  bit 1 = JVMTI_EVENT_VM_INIT (50)
  bit 2 = JVMTI_EVENT_VM_DEATH (51)
  ...
  bit N = event_type - TOTAL_MIN_EVENT_TYPE_VAL
  
  方法：
  is_enabled(event_type) → 检查对应 bit
  set_enabled(event_type, on) → 设置/清除对应 bit
```

### L1: JvmtiEnvEventEnable（每个环境）

```
JvmtiEnvEventEnable:
  _event_user_enabled     : JvmtiEventEnabled  ← Agent 通过 SetEventNotificationMode 设置
  _event_callback_enabled : JvmtiEventEnabled  ← 由 set_event_callbacks 计算（有回调=1）
  _event_enabled          : JvmtiEventEnabled  ← 最终 = user_enabled & callback_enabled & phase_mask
```

**关键**：一个事件要真正启用，必须三个条件同时满足：
1. Agent 启用了该事件（`_event_user_enabled`）
2. Agent 注册了该事件的回调函数（`_event_callback_enabled`）
3. 当前 Phase 允许该事件（由 `recompute_env_enabled` 中的 phase switch 决定）

### L2: JvmtiEnvThreadEventEnable（环境×线程）

```
JvmtiEnvThreadEventEnable:
  _event_user_enabled : JvmtiEventEnabled  ← 线程级用户启用
  _event_enabled      : JvmtiEventEnabled  ← 最终启用
  
  计算公式：
  _event_enabled = THREAD_FILTERED_EVENT_BITS
                 & env._event_callback_enabled
                 & (env._event_user_enabled | this._event_user_enabled)
                 & frame_pop_check & field_watch_check & phase_check
```

### L3: JvmtiThreadEventEnable（每个线程，跨所有环境聚合）

```
JvmtiThreadEventEnable:
  _event_enabled : JvmtiEventEnabled
  
  = 所有 JvmtiEnvThreadEventEnable._event_enabled 的 OR
  
  → 只要任何一个环境在这个线程上启用了事件，就为 true
```

### L4: _universal_global_event_enabled（全局）

```
JvmtiEventController::_universal_global_event_enabled : JvmtiEventEnabled
  
  = 所有环境的 env_enabled OR 所有线程的 thread_enabled
  
  → 只要任何环境的任何线程启用了事件，就为 true
  → 这是 JvmtiExport::_should_post_xxx 全局标志的来源
```

### 四层聚合关系图

```
                      ┌───────────────────────────────────┐
                      │      L4: Universal Global          │
                      │  _universal_global_event_enabled   │
                      │  = 所有 env + 所有 thread 的 OR    │
                      └──────────┬──────┬─────────────────┘
                                 │      │
                    ┌────────────┘      └──────────────┐
                    ▼                                   ▼
          ┌──────────────────┐                ┌──────────────────┐
          │   L1: Env Event   │                │  L3: Thread Event │
          │   Enable (env A)  │                │  Enable (thread1) │
          │                   │                │  = OR of all L2    │
          │  user & callback  │                │    for thread1     │
          │  & phase          │                └────────┬──────────┘
          └──────────────────┘                          │
                    │                          ┌────────┴──────────┐
                    │                          ▼                    ▼
                    │               ┌──────────────────┐  ┌──────────────────┐
                    └──────────────►│L2: EnvThread     │  │L2: EnvThread     │
                                   │Enable(envA,thr1) │  │Enable(envB,thr1) │
                                   └──────────────────┘  └──────────────────┘
```

---

## 17.4 核心方法：recompute_enabled()

**文件**：`jvmtiEventController.cpp`

这是整个事件控制体系的**心脏**——每次事件状态变化时（启用/禁用事件、设置回调、环境创建/销毁），都会调用此方法重新计算所有层级的启用状态。

### 完整流程

```
recompute_enabled():
│
├── Step 1: 计算非线程过滤事件（全局事件）
│   for each JvmtiEnvBase env:
│   └── any_env_thread_enabled |= recompute_env_enabled(env)
│       │
│       └── now_enabled = env._event_callback_enabled
│                       & env._event_user_enabled
│                       & phase_mask
│           ← phase 控制：
│           ├── PRIMORDIAL/ONLOAD: 只允许 EARLY_EVENT_BITS & ~THREAD_FILTERED
│           ├── START: 只允许 EARLY_EVENT_BITS
│           ├── LIVE: 所有事件
│           └── DEAD: 无事件
│
├── Step 2: 如果有新的线程过滤事件被全局启用
│   → 为所有 JavaThread 创建 JvmtiThreadState（如果缺失）
│
├── Step 3: 计算每个线程的启用状态
│   for each JvmtiThreadState state:
│   └── any_env_thread_enabled |= recompute_thread_enabled(state)
│       │
│       ├── for each JvmtiEnvThreadState ets on this thread:
│       │   └── any_env_enabled |= recompute_env_thread_enabled(ets, state)
│       │       └── 计算公式见 L2
│       │
│       ├── 更新 state._thread_event_enable（L3）
│       │
│       ├── 更新 should_post_on_exceptions 缓存
│       │
│       └── ★ interp_only_mode 联动 ★
│           if (any_env_enabled & INTERP_EVENT_BITS) || has_frame_pops:
│             → enter_interp_only_mode(state)  ← 反优化所有帧！
│           else:
│             → leave_interp_only_mode(state)
│
├── Step 4: 设置全局 should_post_xxx 标志
│   if (delta != 0):  ← 有变化才更新
│   ├── JvmtiExport::set_should_post_field_access(...)
│   ├── JvmtiExport::set_should_post_field_modification(...)
│   ├── JvmtiExport::set_should_post_class_load(...)
│   ├── JvmtiExport::set_should_post_class_file_load_hook(...)
│   ├── ... (20+ 个 should_post 标志)
│   ├── JvmtiExport::set_should_post_thread_life(...)
│   │
│   ├── ★ SINGLE_STEP 特殊处理 ★
│   │   if (delta & SINGLE_STEP_BIT):
│   │     VM_ChangeSingleStep op(on)
│   │     VMThread::execute(&op)
│   │     → 切换解释器调度表（safepoint 表 vs 普通表）
│   │
│   └── 设置全局 _universal_global_event_enabled
│       + _should_post_on_exceptions
│
└── 完成
```

### recompute_enabled 的调用时机

| 触发条件 | 调用方 | 说明 |
|---------|--------|------|
| `SetEventNotificationMode(ENABLE/DISABLE)` | `set_user_enabled()` | Agent 启用/禁用事件 |
| `SetEventCallbacks(callbacks)` | `set_event_callbacks()` | Agent 注册回调 |
| `SetExtensionEventCallback(callback)` | `set_extension_event_callback()` | 扩展事件回调 |
| 环境创建 | `env_initialize()` | 新 Agent attach |
| 环境销毁 | `env_dispose()` | Agent detach |
| VM Phase 变化 | `vm_start()` / `vm_init()` / `vm_death()` | 生命周期变化 |
| Field Watch 变化 | `change_field_watch()` | SetFieldAccessWatch/Modification |
| Frame Pop 设置/清除 | `set_frame_pop()` / `clear_frame_pop()` | NotifyFramePop |

---

## 17.5 事件分发模型：post_xxx 的两种模式

### 模式 1: 全局事件分发

遍历所有 JvmtiEnv，检查每个环境是否启用了该事件。

```
// 典型示例：post_vm_initialized()
void JvmtiExport::post_vm_initialized() {
  JvmtiEventController::vm_init();    // 重新计算启用状态
  
  JvmtiEnvIterator it;
  for (JvmtiEnv* env = it.first(); env != NULL; env = it.next(env)) {
    if (env->is_enabled(JVMTI_EVENT_VM_INIT)) {
      JavaThread *thread = JavaThread::current();
      JvmtiThreadEventMark jem(thread);           // 准备 JNI 参数
      JvmtiJavaThreadEventTransition jet(thread);  // 线程状态转换
      jvmtiEventVMInit callback = env->callbacks()->VMInit;
      if (callback != NULL) {
        (*callback)(env->jvmti_external(), jem.jni_env(), jem.jni_thread());
      }
    }
  }
}
```

**使用此模式的事件**：VM_START, VM_INIT, VM_DEATH, GC_START/FINISH, COMPILED_METHOD_LOAD/UNLOAD, DYNAMIC_CODE_GENERATED, DATA_DUMP, THREAD_START, NATIVE_METHOD_BIND, VM_OBJECT_ALLOC 等。

### 模式 2: 线程过滤事件分发

只遍历当前线程的 JvmtiEnvThreadState，只通知在该线程上启用了事件的环境。

```
// 典型示例：post_class_load()
void JvmtiExport::post_class_load(JavaThread *thread, Klass* klass) {
  JvmtiThreadState* state = thread->jvmti_thread_state();
  if (state == NULL) return;
  
  JvmtiEnvThreadStateIterator it(state);
  for (JvmtiEnvThreadState* ets = it.first(); ets != NULL; ets = it.next(ets)) {
    if (ets->is_enabled(JVMTI_EVENT_CLASS_LOAD)) {
      JvmtiEnv *env = ets->get_env();
      JvmtiClassEventMark jem(thread, klass);
      JvmtiJavaThreadEventTransition jet(thread);
      jvmtiEventClassLoad callback = env->callbacks()->ClassLoad;
      if (callback != NULL) {
        (*callback)(env->jvmti_external(), jem.jni_env(), jem.jni_thread(), jem.jni_class());
      }
    }
  }
}
```

**使用此模式的事件**：BREAKPOINT, SINGLE_STEP, METHOD_ENTRY/EXIT, FIELD_ACCESS/MODIFICATION, EXCEPTION/EXCEPTION_CATCH, MONITOR_xxx, CLASS_LOAD, CLASS_PREPARE, THREAD_END, FRAME_POP。

### ClassFileLoadHook 的特殊分发（Ch15 已分析）

`post_class_file_load_hook` 是特殊的：它**两种模式都用**。
1. 第一轮：遍历非 retransformable 环境（全局方式）
2. 第二轮：遍历 retransformable 环境（全局方式）
3. retransform 时：跳过第一轮

---

## 17.6 JvmtiEventMark 层次结构 — 回调准备

每次 post 事件前，需要准备 JNI 参数（jthread, jclass, jmethodID 等）。这通过 `JvmtiEventMark` 体系完成。

```
JvmtiEventMark (base)
├── 功能：
│   ├── 保存 JavaThread、JNIEnv
│   ├── 分配新的 JNIHandleBlock（push local frame）
│   ├── 析构时释放 JNIHandleBlock（pop local frame）
│   ├── 保存/恢复 exception state
│   └── make_walkable（确保栈可遍历）
│
├── JvmtiThreadEventMark
│   └── 添加 _jt (jthread 句柄)
│
├── JvmtiClassEventMark
│   └── 添加 _jc (jclass 句柄)
│
├── JvmtiMethodEventMark
│   └── 添加 _mid (jmethodID)
│
├── JvmtiLocationEventMark
│   └── 添加 _loc (jlocation = address - method->code_base())
│
├── JvmtiExceptionEventMark
│   └── 添加 _exc (jobject 异常对象)
│
├── JvmtiClassFileLoadEventMark
│   └── 添加 class_name, jloader, protection_domain, class_being_redefined
│
├── JvmtiObjectAllocEventMark
│   └── 添加 _jobj, _size
│
├── JvmtiCompiledMethodLoadEventMark
│   └── 添加 code_data, code_size, map (pc→location 映射), compile_info
│
└── JvmtiMonitorEventMark
    └── 添加 _jobj (monitor 对象)
```

### 线程状态转换

```
JvmtiJavaThreadEventTransition:
  → ThreadToNativeFromVM(_transition)
  → 将线程从 _thread_in_vm 转换为 _thread_in_native
  → 因为 Agent 回调是 native 代码
  → 析构时自动恢复线程状态
  
JvmtiThreadEventTransition:
  → 更通用的版本，处理不同初始状态的线程
  → 最终都转换为 _thread_in_native
```

---

## 17.7 解释器联动：interp_only_mode

### 为什么需要 interp_only_mode？

SINGLE_STEP、METHOD_ENTRY/EXIT、FIELD_ACCESS/MODIFICATION 等事件需要在每个字节码/每次方法调用/每次字段访问时检查。

- **解释器**：可以在分发循环中插入检查
- **JIT 编译代码**：没有逐字节码分发，无法插入检查

**解决方案**：启用这类事件时，强制线程进入 interp_only_mode，反优化所有编译帧。

### 进入 interp_only_mode

```
VM_EnterInterpOnlyMode::doit():
│
├── state->invalidate_cur_stack_depth()
│
├── state->enter_interp_only_mode()
│   └── 设置 JavaThread._interp_only_mode = true
│       → 解释器不再分发到编译代码
│
└── 反优化所有编译帧
    for each vframe on thread's stack:
      if (can_be_deoptimized(vf)):
        vf->code()->mark_for_deoptimization()
    if (num_marked > 0):
      VM_Deoptimize op
      VMThread::execute(&op)
```

### SINGLE_STEP 的特殊处理

```
VM_ChangeSingleStep::doit():
│
├── JvmtiEventControllerPrivate::set_should_post_single_step(on)
│
├── if (on):
│   Interpreter::notice_safepoints()
│   → 切换到 safepoint 调度表
│   → 每个字节码分发都会检查 single step
│
└── else:
    Interpreter::ignore_safepoints()
    → 恢复普通调度表
```

---

## 17.8 JVM 生命周期 Phase 控制

### 五个 Phase

```
JVMTI_PHASE_ONLOAD     ← Agent_OnLoad 执行时
    │
    ▼
JVMTI_PHASE_PRIMORDIAL ← VM 初始化最早期
    │
    ▼
JVMTI_PHASE_START      ← JNI 可用但 VM 未完全初始化
    │
    ▼
JVMTI_PHASE_LIVE       ← VM 完全初始化，所有功能可用
    │
    ▼
JVMTI_PHASE_DEAD       ← VM 正在关闭
```

### Phase 对事件的影响

在 `recompute_env_enabled()` 中：

```
switch (env->phase()):
  PRIMORDIAL / ONLOAD:
    now_enabled &= (EARLY_EVENT_BITS & ~THREAD_FILTERED_EVENT_BITS)
    → 只允许早期全局事件
    
  START:
    now_enabled &= EARLY_EVENT_BITS
    → 允许早期事件（包括线程过滤的）
    
  LIVE:
    → 不做过滤，所有事件可用
    
  DEAD:
    now_enabled = 0
    → 禁止所有事件
```

### Phase 转换时的事件通知

```
thread.cpp create_vm():
│
├── JvmtiExport::enter_onload_phase()
│   → 执行 Agent_OnLoad
│
├── JvmtiExport::enter_start_phase()
│   → JvmtiEventController::vm_start()
│   → post_early_vm_start() + post_vm_start()
│   → 触发 VMStart 回调
│
├── JvmtiExport::enter_live_phase()
│   → JvmtiEventController::vm_init()
│   → post_vm_initialized()
│   → 触发 VMInit 回调（Ch15 中 premain 在这里被调用）
│
└── JvmtiExport::vm_death()
    → post_vm_death()
    → JvmtiEventController::vm_death()
    → phase = DEAD → 所有事件禁用
```

---

## 17.9 性能优化设计：should_post_xxx 快速检查

### 问题

HotSpot 中有大量事件埋点。如果没有 Agent，这些检查不应该有任何开销。

### 解决方案：全局 static bool 标志

```c++
// jvmtiExport.hpp 中通过宏定义：
JVMTI_SUPPORT_FLAG(should_post_class_load)
JVMTI_SUPPORT_FLAG(should_post_method_entry)
JVMTI_SUPPORT_FLAG(should_post_field_access)
// ... 20+ 个标志

// 展开为：
private:
  static bool _should_post_class_load;
public:
  inline static void set_should_post_class_load(bool on) { _should_post_class_load = on; }
  inline static bool should_post_class_load() { return _should_post_class_load; }
```

### 在 HotSpot 中的使用模式

```c++
// 类加载时的埋点（SystemDictionary）
if (JvmtiExport::should_post_class_load()) {
  JvmtiExport::post_class_load(thread, klass);
}

// GC 开始时的埋点
if (JvmtiExport::should_post_garbage_collection_start()) {
  JvmtiExport::post_garbage_collection_start();
}
```

**关键优化**：
- `should_post_xxx()` 是 `inline static bool` → **单次内存读取 + 分支预测**
- 没有 Agent 时，所有标志都是 `false` → 分支预测命中率极高
- 不需要任何锁、不需要遍历环境链表

### JvmtiGCMarker — RAII 风格的 GC 事件

```c++
JvmtiGCMarker::JvmtiGCMarker() {
  if (!JvmtiEnv::environments_might_exist()) return; // 无 Agent 直接返回
  if (JvmtiExport::should_post_garbage_collection_start())
    JvmtiExport::post_garbage_collection_start();
}

JvmtiGCMarker::~JvmtiGCMarker() {
  if (!JvmtiEnv::environments_might_exist()) return;
  if (JvmtiExport::should_post_garbage_collection_finish())
    JvmtiExport::post_garbage_collection_finish();
}

// 使用：在 GC 操作中构造一个 JvmtiGCMarker，析构时自动发送 GC finish
```

---

## 17.10 关键事件实现深入

### 17.10.1 Breakpoint 事件

```
post_raw_breakpoint(thread, method, location):
│
├── state = thread->jvmti_thread_state()
│
├── JvmtiEnvThreadStateIterator it(state)
│   for each ets:
│   ├── ets->compare_and_set_current_location(method, location, BREAKPOINT)
│   │   └── 防止在同一位置重复发送事件
│   │
│   ├── if (!ets->breakpoint_posted() && ets->is_enabled(BREAKPOINT)):
│   │   ├── thread->osthread()->set_state(BREAKPOINTED) ← 设置 OS 线程状态
│   │   ├── env = ets->get_env()
│   │   ├── JvmtiLocationEventMark jem(thread, mh, location)
│   │   ├── JvmtiJavaThreadEventTransition jet(thread)
│   │   ├── callback = env->callbacks()->Breakpoint
│   │   ├── callback(env, jni_env, jthread, jmethodID, jlocation)
│   │   └── ets->set_breakpoint_posted()
│   │
│   └── 恢复 OS 线程状态
```

### 17.10.2 Method Entry/Exit 事件

```
post_method_entry(thread, method, current_frame):
│
├── state = thread->jvmti_thread_state()
├── if (state == NULL || !state->is_interp_only_mode()) return
│   ← ★ 只在 interp_only_mode 下才触发
│
├── state->incr_cur_stack_depth()  ← 跟踪当前栈深度
│
└── if (state->is_enabled(METHOD_ENTRY)):
    for each ets:
      if (ets->is_enabled(METHOD_ENTRY)):
        callback(env, jni_env, jthread, jmethodID)
```

### 17.10.3 Exception 事件

```
post_exception_throw(thread, method, location, exception):
│
├── state = thread->jvmti_thread_state()
│
├── if (!state->is_exception_detected()):
│   state->set_exception_detected()
│   │
│   for each ets:
│     if (ets->is_enabled(EXCEPTION)):
│     │
│     ├── ★ 查找异常捕获位置 ★
│     │   vframeStream st(thread)
│     │   do:
│     │     current_bci = Method::fast_exception_handler_bci_for(mh, eh_klass, bci)
│     │     st.next()
│     │   while (current_bci < 0 && !st.at_end())
│     │   → 遍历调用栈找 catch handler
│     │
│     └── callback(env, jni_env, jthread, throw_method, throw_location,
│                  exception, catch_method, catch_location)
│
└── state->invalidate_cur_stack_depth()
```

---

## 17.11 load_agent_library — Attach 时的 Agent 加载

**文件**：`jvmtiExport.cpp` (line 2777)

这是通过 Attach API 动态加载 Agent 的入口（Ch19 将详细分析 Attach 机制）。

```
load_agent_library(agent, absParam, options, st):
│
├── is_absolute_path = strcmp(absParam, "true") == 0
├── agent_lib = new AgentLibrary(agent, options, is_absolute_path)
│
├── 查找内建 Agent
│   os::find_builtin_agent(agent_lib, AGENT_ONATTACH_SYMBOLS)
│
├── 如果非内建：
│   ├── 绝对路径 → os::dll_load(agent)
│   └── 相对路径 → 
│       ├── os::dll_locate_lib(standard_dir, agent) → dll_load
│       └── os::dll_build_name(agent) → dll_load（OS 默认路径）
│
├── 查找 Agent_OnAttach 函数
│   on_attach_entry = os::find_agent_function(agent_lib, AGENT_ONATTACH_SYMBOLS)
│
├── 调用 Agent_OnAttach
│   JvmtiThreadEventMark jem(THREAD)
│   JvmtiJavaThreadEventTransition jet(THREAD)
│   result = (*on_attach_entry)(&main_vm, options, NULL)
│
└── if (result == JNI_OK):
    Arguments::add_loaded_agent(agent_lib)  ← 添加到已加载列表
```

---

## 17.12 面试专题

### Q1: JVMTI 事件是怎么做到"没有 Agent 时零开销"的？

**回答**：
JVMTI 使用 `JvmtiExport::_should_post_xxx` 全局 static bool 标志。没有 Agent 时，所有标志都是 `false`。HotSpot 中的埋点通过 `if (should_post_xxx())` 检查，这只是一次内存读取 + 分支预测。由于分支预测器会学到这些分支几乎总是不走，所以开销趋近于零。

### Q2: 为什么启用 SINGLE_STEP 会让 JVM 变慢？

**回答**：
两个原因：
1. **interp_only_mode**：SINGLE_STEP 属于 `INTERP_EVENT_BITS`，启用时线程必须进入解释器模式，所有编译帧被反优化，JIT 编译代码不再使用
2. **safepoint 调度表**：`VM_ChangeSingleStep` 会切换解释器的调度表到 safepoint 版本（`Interpreter::notice_safepoints()`），每个字节码分发都会多一层检查

这就是 IDE 调试（尤其是单步）比正常运行慢很多的根本原因。

### Q3: 多个 Agent 同时监听同一个事件会怎样？

**回答**：
JVMTI 支持多个 Agent 并存。每个 Agent 对应一个 `JvmtiEnv`。事件分发时：
- 全局事件：遍历所有 `JvmtiEnv`，逐个检查 `env->is_enabled(event)`
- 线程过滤事件：遍历线程的 `JvmtiEnvThreadState` 链表

每个环境独立接收回调，一个环境的回调不影响另一个。`JvmtiEnvIterator` 使用 `entering_jvmti_env_iteration()` 保护遍历安全性。

### Q4: ClassFileLoadHook 和 ClassLoad 事件有什么区别？

| 维度 | ClassFileLoadHook | ClassLoad |
|------|------------------|-----------|
| 触发时机 | 解析字节码之前（parse_stream 中） | 类链接完成之后 |
| 能修改字节码 | ✅ 可以修改 class_bytes | ❌ 类已经生成 |
| 事件类型 | 全局事件 | 线程过滤事件 |
| 分发方式 | `JvmtiClassFileLoadHookPoster` 两轮遍历 | `JvmtiEnvThreadStateIterator` |
| retransform 时 | 触发（只 retransformable 环境） | 不触发 |

### Q5: recompute_enabled 会频繁调用吗？性能影响？

**回答**：
`recompute_enabled()` 只在事件状态变化时调用（设置回调、启用/禁用事件等），运行时正常执行不会触发。它需要持有 `JvmtiThreadState_lock`，遍历所有环境和线程。在 Agent 数量少的情况下（通常 1-2 个），开销很小。但在 attach/detach Agent 时会有一次性开销。

### Q6: should_post_on_exceptions 是干什么的？

**回答**：
这是一个设置在 `JavaThread` 上的标志（通过 `JvmtiThreadState::set_should_post_on_exceptions()`）。它是 `EXCEPTION_BITS | METHOD_EXIT | FRAME_POP` 的聚合。

异常处理是热路径，如果每次异常都要检查全局标志 + 遍历环境链表会很慢。所以将结果缓存到线程本地，异常处理路径只需检查 `thread->should_post_on_exceptions_flag()` 即可快速判断。

---

## 17.13 关联知识串联

| 本章知识点 | 串联已有分析 |
|-----------|-------------|
| ClassFileLoadHook 分发（`JvmtiClassFileLoadHookPoster`） | Ch15 Java Agent 机制 |
| retransform 时事件分发差异 | Ch16 retransformClasses 链路 |
| interp_only_mode / 反优化 | Ch16 flush_dependent_code |
| 解释器调度表切换 | Interpreter 初始化分析 |
| JvmtiThreadState 管理 | Ch15 `initializeJPLISAgent` |

---

## 下一步

**Ch18: agentmain 与动态 Attach Agent — 从 VirtualMachine.attach() 到 agentmain()**
- Java Agent 的 agentmain 入口
- 与 premain 的差异
- libinstrument 中的 agentmain 调用链路
- 与 Attach API（Ch19）的串联

---

*分析文件*：`src/hotspot/share/prims/jvmtiEventController.hpp` (四层数据结构定义)
*分析文件*：`src/hotspot/share/prims/jvmtiEventController.cpp` (recompute_enabled 核心逻辑)
*分析文件*：`src/hotspot/share/prims/jvmtiExport.hpp` (should_post_xxx 标志 + post_xxx 声明)
*分析文件*：`src/hotspot/share/prims/jvmtiExport.cpp` (所有 post_xxx 实现 + ClassFileLoadHookPoster)
*分析文件*：`src/hotspot/share/prims/jvmtiEnvBase.hpp` (JvmtiEnvBase 环境管理)
*分析文件*：`src/hotspot/share/prims/jvmtiThreadState.hpp` (JvmtiThreadState 线程状态)
