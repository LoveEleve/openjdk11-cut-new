# 1.2 JVMTI 环境建立

> 源文件: `vmEntry.cpp:140-300`, `vmEntry.h` (JVMTIFunctions / VM 类)
> 关联 JVM 源码: `jvmtiEnv.cpp` (AddCapabilities/SetEventCallbacks/SetEventNotificationMode)
> 前置章节: 1.1 Agent 加载路径

## 核心问题

**async-profiler 请求了哪些 JVMTI Capabilities？注册了哪些回调？启用了哪些事件？为什么？**

答：在 `VM::init()` 中，async-profiler 按严格顺序执行 **3 步 JVMTI 配置**：
1. `AddCapabilities` → 声明需要哪些 JVMTI 能力
2. `SetEventCallbacks` → 注册 15 个事件回调函数
3. `SetEventNotificationMode` → 启用需要立即监听的事件

这三步的顺序不能打乱：先有能力，才能注册回调；先注册回调，才能启用事件。

---

## 一、Step 1: AddCapabilities — 声明 JVMTI 能力

### 1.1 请求了什么能力？

```cpp
// vmEntry.cpp:236-247
jvmtiCapabilities capabilities = {0};
capabilities.can_generate_all_class_hook_events      = 1;
capabilities.can_retransform_classes                  = 1;
capabilities.can_retransform_any_class                = isOpenJ9() ? 0 : 1;
capabilities.can_generate_vm_object_alloc_events      = isOpenJ9() ? 1 : 0;
capabilities.can_get_bytecodes                        = 1;
capabilities.can_get_constant_pool                    = 1;
capabilities.can_get_source_file_name                 = 1;
capabilities.can_get_line_numbers                     = 1;
capabilities.can_generate_compiled_method_load_events = 1;
capabilities.can_generate_monitor_events              = 1;
capabilities.can_generate_garbage_collection_events   = 1;
capabilities.can_tag_objects                          = 1;
_jvmti->AddCapabilities(&capabilities);
```

### 1.2 每个能力的用途

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                 async-profiler 请求的 JVMTI 能力清单                         │
├─────────────────────────────────────────┬───────────────────────────────────┤
│ 能力                                    │ 用途 (哪个组件需要)                │
├─────────────────────────────────────────┼───────────────────────────────────┤
│ can_generate_all_class_hook_events      │ Instrument: ClassFileLoadHook     │
│   → 允许接收所有类的字节码加载事件         │   事件, 用于方法插桩               │
├─────────────────────────────────────────┼───────────────────────────────────┤
│ can_retransform_classes                 │ Instrument: 运行时重新转换类的字节  │
│   → 允许调用 RetransformClasses          │   码, 用于动态插桩/卸桩            │
├─────────────────────────────────────────┼───────────────────────────────────┤
│ can_retransform_any_class               │ Instrument: 重转换包括 bootstrap   │
│   → HotSpot 专有(OpenJ9 不支持)          │   类加载器加载的系统类             │
├─────────────────────────────────────────┼───────────────────────────────────┤
│ can_get_bytecodes                       │ Instrument: 读取方法字节码进行分析  │
│   → 方法匹配和过滤                       │                                   │
├─────────────────────────────────────────┼───────────────────────────────────┤
│ can_get_constant_pool                   │ Instrument: 读取常量池获取类/方法   │
│   → 类信息解析                           │   引用信息                         │
├─────────────────────────────────────────┼───────────────────────────────────┤
│ can_get_source_file_name                │ 符号解析: 获取源文件名              │
│   → 火焰图/JFR 中显示 "Foo.java"        │                                   │
├─────────────────────────────────────────┼───────────────────────────────────┤
│ can_get_line_numbers                    │ 符号解析: 获取行号表               │
│   → 精确到代码行的 profiling              │                                   │
├─────────────────────────────────────────┼───────────────────────────────────┤
│ can_generate_compiled_method_load_events │ CodeCache: JIT 编译通知           │
│   → 追踪 JIT 编译的方法入口地址           │                                   │
├─────────────────────────────────────────┼───────────────────────────────────┤
│ can_generate_monitor_events             │ LockTracer: 锁争用事件            │
│   → MonitorContendedEnter/Entered       │                                   │
├─────────────────────────────────────────┼───────────────────────────────────┤
│ can_generate_garbage_collection_events   │ ObjectSampler: GC 开始/结束事件   │
│   → 在 GC 期间暂停分配追踪               │                                   │
├─────────────────────────────────────────┼───────────────────────────────────┤
│ can_tag_objects                          │ ObjectSampler: 对象标记           │
│   → 追踪存活对象                         │                                   │
├─────────────────────────────────────────┼───────────────────────────────────┤
│ can_generate_vm_object_alloc_events     │ J9ObjectSampler: OpenJ9 专有      │
│   → OpenJ9 不支持 SampledObjectAlloc     │   的分配事件                      │
└─────────────────────────────────────────┴───────────────────────────────────┘
```

### 1.3 JVM 侧 AddCapabilities 做了什么？

```
调用链:
  _jvmti->AddCapabilities(&capabilities)
    → jvmti_AddCapabilities()                    // 生成的 JVMTI 入口
      → JvmtiEnv::AddCapabilities()              // jvmtiEnv.cpp:603
        → JvmtiManageCapabilities::add_capabilities()  // 核心逻辑
```

JVM 侧的处理逻辑（`jvmtiManageCapabilities.cpp:239`）：
1. 先计算 **potential capabilities**（当前可用的能力池）
2. 用 `desired & potential` 过滤掉不可用的能力
3. 更新 `result` = `current | filtered_desired`
4. 同步更新全局能力集合

**关键点**: JVMTI 能力的 `prohibited` 字段用于防止多个 agent 之间的冲突。一旦一个 agent 获得了某个互斥能力，其他 agent 就无法再请求。

---

## 二、Step 2: SetEventCallbacks — 注册 15 个回调

### 2.1 回调注册代码

```cpp
// vmEntry.cpp:249-266
jvmtiEventCallbacks callbacks = {0};
callbacks.VMInit                   = VMInit;
callbacks.VMDeath                  = VMDeath;
callbacks.ClassLoad                = ClassLoad;
callbacks.ClassPrepare             = ClassPrepare;
callbacks.ClassFileLoadHook        = Instrument::ClassFileLoadHook;
callbacks.CompiledMethodLoad       = Profiler::CompiledMethodLoad;
callbacks.DynamicCodeGenerated     = Profiler::DynamicCodeGenerated;
callbacks.ThreadStart              = Profiler::ThreadStart;
callbacks.ThreadEnd                = Profiler::ThreadEnd;
callbacks.MonitorContendedEnter    = LockTracer::MonitorContendedEnter;
callbacks.MonitorContendedEntered  = LockTracer::MonitorContendedEntered;
callbacks.VMObjectAlloc            = J9ObjectSampler::VMObjectAlloc;
callbacks.SampledObjectAlloc       = ObjectSampler::SampledObjectAlloc;
callbacks.GarbageCollectionStart   = ObjectSampler::GarbageCollectionStart;
callbacks.GarbageCollectionFinish  = Profiler::GarbageCollectionFinish;
_jvmti->SetEventCallbacks(&callbacks, sizeof(callbacks));
```

### 2.2 回调分类和触发时机

```
┌─────────────────────────────────────────────────────────────────────────────┐
│              async-profiler 注册的 15 个 JVMTI 回调                          │
├──────────────────────┬──────────────────────────┬──────────────────────────┤
│ 回调函数              │ 触发时机                  │ 处理逻辑                 │
├──────────────────────┼──────────────────────────┼──────────────────────────┤
│     ◆ 生命周期 (2个)  │                          │                          │
│ VMInit               │ JVM 初始化完成后          │ ready() + loadAllMethodIDs│
│                      │                          │ + 启动 profiling          │
│ VMDeath              │ JVM 关闭前               │ 停止 profiling + 输出结果 │
├──────────────────────┼──────────────────────────┼──────────────────────────┤
│     ◆ 类加载 (3个)    │                          │                          │
│ ClassLoad            │ 类加载时                  │ 空实现(ASGCT需要该事件)   │
│ ClassPrepare         │ 类准备完毕后             │ loadMethodIDs(): 预分配   │
│                      │                          │   jmethodID              │
│ ClassFileLoadHook    │ 类字节码加载时            │ Instrument: 字节码插桩    │
├──────────────────────┼──────────────────────────┼──────────────────────────┤
│     ◆ 编译 (2个)      │                          │                          │
│ CompiledMethodLoad   │ JIT 编译完成             │ 记录 nmethod 地址 →       │
│                      │                          │   更新 CodeCache          │
│ DynamicCodeGenerated │ 动态代码生成(stub等)      │ 记录代码块地址 →          │
│                      │                          │   更新 CodeCache          │
├──────────────────────┼──────────────────────────┼──────────────────────────┤
│     ◆ 线程 (2个)      │                          │                          │
│ ThreadStart          │ Java 线程启动            │ 记录线程信息              │
│ ThreadEnd            │ Java 线程结束            │ 清理线程信息              │
├──────────────────────┼──────────────────────────┼──────────────────────────┤
│     ◆ 锁 (2个)        │                          │                          │
│ MonitorContendedEnter│ 线程开始等待锁           │ LockTracer: 记录开始时间  │
│ MonitorContendedEntrd│ 线程获得锁               │ LockTracer: 计算等待耗时  │
├──────────────────────┼──────────────────────────┼──────────────────────────┤
│     ◆ 分配 (2个)      │                          │                          │
│ VMObjectAlloc        │ VM 分配对象(OpenJ9)      │ J9ObjectSampler          │
│ SampledObjectAlloc   │ 采样分配事件(JDK 11+)    │ ObjectSampler            │
├──────────────────────┼──────────────────────────┼──────────────────────────┤
│     ◆ GC (2个)        │                          │                          │
│ GCStart              │ GC 开始                  │ ObjectSampler: 暂停采样   │
│ GCFinish             │ GC 结束                  │ Profiler: 恢复采样        │
└──────────────────────┴──────────────────────────┴──────────────────────────┘
```

### 2.3 ClassLoad 回调为什么是空实现？

```cpp
static void JNICALL ClassLoad(jvmtiEnv* jvmti, JNIEnv* jni, jthread thread, jclass klass) {
    // Needed only for AsyncGetCallTrace support
}
```

这是个精妙的设计。`AsyncGetCallTrace` 内部（`forte.cpp`）在回溯栈帧时，会检查当前线程是否正在类加载中（通过 `JvmtiExport::should_post_class_load()` 判断）。如果没有注册 `ClassLoad` 回调，JVM 就不会设置这个标志，导致 ASGCT 在某些边界情况下返回错误码 `ticks_no_class_load`。所以即使回调体是空的，**注册本身就有意义**。

### 2.4 JVM 侧 SetEventCallbacks 做了什么？

```
调用链:
  _jvmti->SetEventCallbacks(&callbacks, sizeof(callbacks))
    → JvmtiEnv::SetEventCallbacks()            // jvmtiEnv.cpp:513
      → JvmtiEventController::set_event_callbacks()  // jvmtiEventController.cpp:974
```

JVM 侧将回调函数指针保存到 `JvmtiEnvBase` 的 `_event_callbacks` 字段中。当事件发生时，JVM 通过这个结构查找回调地址并调用。

---

## 三、Step 3: SetEventNotificationMode — 启用事件

### 3.1 默认启用的 5 个事件

```cpp
// vmEntry.cpp:267-273
_jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_VM_DEATH,               NULL);
_jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_CLASS_LOAD,             NULL);
_jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_CLASS_PREPARE,          NULL);
_jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_DYNAMIC_CODE_GENERATED, NULL);
_jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_GARBAGE_COLLECTION_FINISH, NULL);
```

**注意**: 这 5 个事件在 `VM::init()` 中**立即启用**，无论是 `-agentpath` 还是 Attach 模式。而 `ThreadStart`、`ThreadEnd`、`MonitorContendedEnter` 等事件是在 profiling 启动时才按需启用的。

### 3.2 CompiledMethodLoad 的条件分支

这是 JVMTI 环境建立中**最精妙的设计之一**：

```cpp
// vmEntry.cpp:275-283
if (hotspot_version() == 0 || !CodeHeap::available()) {
    // Workaround for JDK-8173361
    _jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_COMPILED_METHOD_LOAD, NULL);
} else {
    // DebugNonSafepoints is automatically enabled with CompiledMethodLoad,
    // otherwise we set the flag manually
    JVMFlag* f = JVMFlag::find("DebugNonSafepoints");
    if (f != NULL && f->isDefault()) {
        f->set(1);
    }
}
```

**为什么有两个分支？**

```
┌─────────────────────────────────────────────────────────────────────────────┐
│               CompiledMethodLoad 事件的两难选择                              │
│                                                                              │
│  情况1: 非 HotSpot 或 CodeHeap 不可用                                       │
│    → 启用 COMPILED_METHOD_LOAD 事件                                         │
│    → 每次 JIT 编译完成都会发通知                                             │
│    → 好处: 自动启用 DebugNonSafepoints                                      │
│    → 坏处: JDK-8173361 可能导致死锁(已修复的 JDK 可以用)                     │
│                                                                              │
│  情况2: HotSpot + CodeHeap 可用（我们的标准条件走这里）                       │
│    → 不启用 COMPILED_METHOD_LOAD 事件                                       │
│    → 通过 VMStructs 直接从 CodeHeap 读取 nmethod 信息                       │
│    → 需要手动设置 DebugNonSafepoints Flag                                   │
│    → 好处: 避免事件通知开销 + 避免 JDK bug                                  │
│    → 坏处: 需要自己解析 CodeHeap 结构                                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.3 DebugNonSafepoints 为什么重要？

`DebugNonSafepoints` 是一个 JVM diagnostic Flag（`globals.hpp:1271`），控制 JIT 编译器是否为 **非 Safepoint 位置**生成调试信息（PC → 行号映射）。

- **默认值**: `trueInDebug`（debug 版为 true，release 版为 false）
- **async-profiler 需要它为 true**: 因为 `AsyncGetCallTrace` 返回的 PC 地址需要映射到具体的 Java 代码行。如果 `DebugNonSafepoints=false`，很多 PC 地址无法映射，profiling 精度大幅下降。

async-profiler 直接通过 `JVMFlag::find()` + `JVMFlag::set()` **绕过 JVM 命令行**修改这个 Flag——这是它能在不需要用户设置 JVM 参数的情况下工作的关键。

### 3.4 SampledObjectAlloc 能力的临时请求

```cpp
// vmEntry.cpp:285-293
if (addSampleObjectsCapability()) {
    JVMFlag* f = JVMFlag::find("UseTLAB");
    if (f != NULL && !f->get()) {
        _jvmti->SetHeapSamplingInterval(0);
    }
    VM::releaseSampleObjectsCapability();
}
```

**为什么请求了又立即释放？**

这是一个**启动时 workaround**：
1. 请求 `can_generate_sampled_object_alloc_events` → JVM 内部开始准备堆采样基础设施
2. 检查 `UseTLAB=false` → 如果没用 TLAB，就设置 `HeapSamplingInterval=0` 禁用采样（因为无 TLAB 时采样开销太大）
3. 立即释放能力 → 不持有不需要的能力（真正做 alloc profiling 时才重新请求）

这里的设计目的是：**尽早配置堆采样参数，让 JVM 启动阶段的分配也能被正确采样**，同时避免持有不必要的能力。

### 3.5 attach 模式下的差异 — VMInit 事件

```cpp
// vmEntry.cpp:295-301
if (attach) {
    loadAllMethodIDs(jvmti(), jni());
    _jvmti->GenerateEvents(JVMTI_EVENT_DYNAMIC_CODE_GENERATED);
    _jvmti->GenerateEvents(JVMTI_EVENT_COMPILED_METHOD_LOAD);
} else {
    _jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_VM_INIT, NULL);
}
```

| attach=false（启动加载） | attach=true（动态附加） |
|:---|:---|
| 注册 `VM_INIT` 事件等回调 | 立即 `loadAllMethodIDs()` |
| 等 JVM 就绪后在 VMInit 回调中执行 | 立即 `GenerateEvents()` 回放已有事件 |
| 不需要 `GenerateEvents` 因为会自然收到 | 需要 `GenerateEvents` 弥补错过的事件 |

---

## 四、Step 4: JVMTI 函数表 Hook（在 VMInit/ready 中执行）

这一步不在 `VM::init()` 中，而是在后续的 `VM::ready()` 中执行：

```cpp
// vmEntry.cpp:383-392
void VM::ready() {
    Profiler::setupSignalHandlers();
    {
        JitWriteProtection jit(true);
        VMStructs::ready();
    }
    // Hook JVMTI 函数表
    JVMTIFunctions* functions = *(JVMTIFunctions**)_jvmti;
    _orig_RedefineClasses = functions->RedefineClasses;
    _orig_RetransformClasses = functions->RetransformClasses;
    functions->RedefineClasses = RedefineClassesHook;
    functions->RetransformClasses = RetransformClassesHook;
}
```

### 4.1 为什么要 Hook JVMTI 函数表？

当外部工具（如 IDE 调试器、DCEVM、其他 agent）调用 `RedefineClasses` 或 `RetransformClasses` 时，JVM 会**重新生成 jmethodID**。如果 async-profiler 不知道这个变化，它保存的旧 jmethodID 就会指向无效内存。

所以 async-profiler 替换了 JVMTI 函数表中的这两个指针，在每次类重定义后自动调用 `loadMethodIDs()` 重新加载受影响类的 jmethodID：

```cpp
jvmtiError VM::RedefineClassesHook(jvmtiEnv* jvmti, jint class_count,
                                    const jvmtiClassDefinition* class_definitions) {
    jvmtiError result = _orig_RedefineClasses(jvmti, class_count, class_definitions);
    if (result == 0) {
        JNIEnv* env = jni();
        for (int i = 0; i < class_count; i++) {
            if (class_definitions[i].klass != NULL) {
                loadMethodIDs(jvmti, env, class_definitions[i].klass);
            }
        }
    }
    return result;
}
```

### 4.2 JVMTIFunctions 结构体的布局

```cpp
// vmEntry.h:87-92
typedef struct {
    void* unused1[86];       // 前 86 个函数指针（跳过）
    jvmtiError (JNICALL *RedefineClasses)(...);   // 第 87 个
    void* unused2[64];       // 中间 64 个函数指针（跳过）
    jvmtiError (JNICALL *RetransformClasses)(...); // 第 152 个
} JVMTIFunctions;
```

这个结构是**手工构造的**，只包含 async-profiler 需要 Hook 的两个函数指针，其他位置用 `unused` 数组填充。偏移量必须和 JVM 内部的 `jvmtiInterface_1_` 函数表布局完全一致。

---

## 五、GDB 验证

### 【GDB 验证 1】JVMTI 事件启用顺序（event_type 编码）

```
┌──────────────────────────────────────────────────────────────────────────┐
│  启用顺序  │ event_type (枚举值)  │ 事件名称                            │
├──────────────────────────────────────────────────────────────────────────┤
│     1      │     51              │ JVMTI_EVENT_VM_DEATH                │
│     2      │     55              │ JVMTI_EVENT_CLASS_LOAD              │
│     3      │     56              │ JVMTI_EVENT_CLASS_PREPARE           │
│     4      │     70              │ JVMTI_EVENT_DYNAMIC_CODE_GENERATED  │
│     5      │     82              │ JVMTI_EVENT_GARBAGE_COLLECTION_FINISH│
│     6      │     50              │ JVMTI_EVENT_VM_INIT ← 最后注册!     │
│ --- VMInit 回调后 (profiling 启动时) ---                                 │
│     7      │     52              │ JVMTI_EVENT_THREAD_START            │
│     8      │     53              │ JVMTI_EVENT_THREAD_END              │
│ --- profiling 停止后 ---                                                 │
│     9      │     52              │ JVMTI_EVENT_THREAD_START (DISABLE)  │
│    10      │     53              │ JVMTI_EVENT_THREAD_END (DISABLE)    │
└──────────────────────────────────────────────────────────────────────────┘
```

**关键发现**: `THREAD_START`/`THREAD_END` 是在 **profiling 启动后才启用，停止后就禁用**的——这说明 async-profiler 严格按需启用事件，最小化 JVMTI 开销。

### 【GDB 验证 2】AddCapabilities 被调用了 2 次

```
调用次数  │  调用者                            │  请求的能力
───────────────────────────────────────────────────────────────
第 1 次    │ VM::init() 主能力请求               │ 11 个能力（见上表）
第 2 次    │ VM::addSampleObjectsCapability()   │ 仅 can_generate_sampled_object_alloc_events
           │ → 紧接着调用 releaseSampleObjectsCapability() 释放
```

### 【GDB 验证 3】DebugNonSafepoints Flag 状态

```
┌────────────────────────────────────────────────────────────────────────┐
│ JVMFlag* f = 0x7ffff75b64a0                                           │
│ f->name()      = 'DebugNonSafepoints'                                 │
│ f->addr()      = 0x7ffff75b0271                                       │
│ f->get()       = 1  (修改前就是 1, 因为 slowdebug 版 trueInDebug)      │
│ f->isDefault() = 1  (用户没手动设置过)                                  │
│                                                                        │
│ 结论: slowdebug 版默认就是 true, asprof 的 set(1) 是冗余但无害的       │
│       在 release 版 JDK 中, 默认为 false, asprof 的 set(1) 就是必须的  │
└────────────────────────────────────────────────────────────────────────┘
```

### 【GDB 验证 4】JVMTI 函数表 Hook 地址

```
┌────────────────────────────────────────────────────────────────────────┐
│ _orig_RedefineClasses    = 0x7ffff6421077 (JVM 原始实现)               │
│ _orig_RetransformClasses = 0x7ffff6420e08 (JVM 原始实现)               │
│ RedefineClassesHook      = 0x7ffff7b707ae (asprof 替换)               │
│ RetransformClassesHook   = 0x7ffff7b70860 (asprof 替换)               │
│                                                                        │
│ 说明: asprof 保存了原始指针, Hook 中先调原始实现, 再执行自己的逻辑       │
└────────────────────────────────────────────────────────────────────────┘
```

### 【GDB 验证 5】回调函数指针全部非空

```
┌────────────────────────────────────────────────────────────────────────┐
│ 所有 15 个回调函数指针都已设置（全部位于 libasyncProfiler.so 地址空间）   │
│                                                                        │
│ VMInit                  = 0x7ffff7b7068e                               │
│ VMDeath                 = 0x7ffff7b7077a                               │
│ ClassLoad               = 0x7ffff7b2eee2                               │
│ ClassPrepare            = 0x7ffff7b2eef9                               │
│ ClassFileLoadHook       = 0x7ffff7b4d194  (Instrument::)              │
│ CompiledMethodLoad      = 0x7ffff7b2f928  (Profiler::)                │
│ DynamicCodeGenerated    = 0x7ffff7b2f965  (Profiler::)                │
│ ThreadStart             = 0x7ffff7b2f99a  (Profiler::)                │
│ ThreadEnd               = 0x7ffff7b2f9cd  (Profiler::)                │
│ MonitorContendedEnter   = 0x7ffff7b52fa6  (LockTracer::)             │
│ MonitorContendedEntered = 0x7ffff7b53002  (LockTracer::)             │
│ GarbageCollectionStart  = 0x7ffff7b55cc0  (ObjectSampler::)          │
│ GarbageCollectionFinish = 0x7ffff7b2fa00  (Profiler::)               │
│ VMObjectAlloc           = 0x7ffff7b4dba8  (J9ObjectSampler::)        │
│ SampledObjectAlloc      = 0x7ffff7b55c68  (ObjectSampler::)          │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 六、设计洞察

### 为什么 ClassLoad 注册了空回调？

因为 `AsyncGetCallTrace`（HotSpot 内部的 `forte.cpp`）在判断是否可以安全回溯栈帧时，会检查 `should_post_class_load()` 标志。如果没有 agent 注册 `ClassLoad` 回调，这个标志为 false，ASGCT 可能会返回 `ticks_no_class_load` 错误。注册空回调让 JVM 设置这个标志，避免了不必要的 ASGCT 失败。

### 为什么优先用 VMStructs 而不是 CompiledMethodLoad 事件？

1. **性能**：CompiledMethodLoad 事件每次 JIT 编译都要回调，有不可忽略的开销
2. **安全**：JDK-8173361 bug 会导致 CompiledMethodLoad 回调中死锁
3. **自主性**：通过 VMStructs 直接读取 CodeHeap，不依赖 JVM 的事件通知机制
4. **精度**：可以自己控制什么时候读取，不受事件投递延迟影响

### 事件注册 vs 事件启用 — 两步分离设计

JVMTI 的设计将"回调注册"和"事件启用"分为两步：
- `SetEventCallbacks` 只是告诉 JVM 回调函数地址
- `SetEventNotificationMode` 才真正开始投递事件

async-profiler 利用这个特性实现**按需启用**：启动时只启用必要的基础事件（ClassLoad、ClassPrepare 等），profiling 启动后才启用 ThreadStart 等事件，停止后又禁用——最小化 JVMTI 运行时开销。

---

*创建日期: 2026-02-09*
*GDB 验证环境: OpenJDK 11 slowdebug + async-profiler v4.0 (git 00a0a12)*
*标准条件: -Xms8g -Xmx8g -XX:+UseG1GC -Xint*