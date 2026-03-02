# 1.3 VMInit 后的初始化

> 源文件: `vmEntry.cpp:340-420`(VM::ready/VMInit), `vmStructs.cpp:441-650`(resolveOffsets/patchSafeFetch/initThreadBridge), `profiler.cpp:889-915`(setupSignalHandlers), `hooks.cpp:153-181`(Hooks::init)
> 前置章节: 1.1 Agent 加载路径, 1.2 JVMTI 环境建立

## 核心问题

**VMInit 回调触发后，async-profiler 从 "已注册但未工作" 到 "正式开始采样" 经历了哪些步骤？**

答：VMInit 回调中执行了 **5 个关键步骤**，按严格顺序依次完成：

```
VMInit 回调 (vmEntry.cpp:402)
  │
  ├─ Step 1: VM::ready()
  │    ├─ 1a. setupSignalHandlers()     → SIGTRAP / SIGSEGV / WAKEUP 信号处理器
  │    ├─ 1b. VMStructs::ready()
  │    │    ├─ resolveOffsets()          → 压缩指针/CodeHeap/帧结构/特性探测
  │    │    ├─ patchSafeFetch()          → JDK SafeFetch bug 修补
  │    │    └─ initThreadBridge()        → eetop字段 + TLS key + env_offset
  │    └─ 1c. Hook JVMTI 函数表          → 替换 RedefineClasses/RetransformClasses
  │
  ├─ Step 2: loadAllMethodIDs()          → 遍历 871 个已加载类, 预分配 jmethodID
  │
  ├─ Step 3: startHttpServer() (可选)    → --server 模式下启动 HTTP 服务
  │
  └─ Step 4: Profiler::run()             → 启动采样!
       ├─ selectEngine("cpu")            → 选择 PerfEvents 引擎
       ├─ PerfEvents::start()            → perf_event_open (后续 4.1 详析)
       ├─ switchThreadEvents(ENABLE)     → 启用 ThreadStart/ThreadEnd
       └─ _state = RUNNING              → 状态切换, profiling 开始
```

---

## 一、Step 1a: setupSignalHandlers — 信号处理器安装

`Profiler::setupSignalHandlers()` 安装 3 个信号处理器：

```cpp
void Profiler::setupSignalHandlers() {
    // 1. SIGTRAP → AllocTracer::trapHandler
    SigAction prev_handler = OS::installSignalHandler(SIGTRAP, AllocTracer::trapHandler);
    if (prev_handler == AllocTracer::trapHandler) return; // 幂等检查

    // 2. SIGSEGV/SIGBUS → crashHandler（仅 HotSpot）
    if (!VM::isOpenJ9() && !VM::isZing()) {
        // 记录 libasyncProfiler.so 的地址范围，用于判断崩溃是否发生在自己代码中
        profiler_lib_start = (uintptr_t)profiler_lib->minAddress();
        profiler_lib_end = (uintptr_t)profiler_lib->maxAddress();
        orig_crashHandler = OS::replaceCrashHandler(crashHandler);
    }

    // 3. WAKEUP_SIGNAL → wakeupHandler
    OS::installSignalHandler(WAKEUP_SIGNAL, NULL, wakeupHandler);
}
```

### 三个信号各自的作用

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ 信号        │ 处理器                    │ 用途                               │
├──────────────────────────────────────────────────────────────────────────────┤
│ SIGTRAP     │ AllocTracer::trapHandler  │ 分配追踪: 在 TLAB 分配路径中植入    │
│             │                           │ 断点(int3), 触发后采样分配事件       │
├──────────────────────────────────────────────────────────────────────────────┤
│ SIGSEGV     │ Profiler::crashHandler    │ 安全访问保护: 栈回溯时访问无效      │
│ SIGBUS      │                           │ 内存 → SafeAccess 捕获并跳过        │
│             │                           │ + isInterpretedFrameValid 崩溃修复   │
├──────────────────────────────────────────────────────────────────────────────┤
│ WAKEUP      │ Profiler::wakeupHandler   │ 唤醒 WallClock 采样器的 timerLoop   │
│ (SIGURG)    │                           │ 线程, 用于停止 profiling             │
└──────────────────────────────────────────────────────────────────────────────┘
```

### crashHandler 的精妙设计

```cpp
void Profiler::crashHandler(int signo, siginfo_t* siginfo, void* ucontext) {
    StackFrame frame(ucontext);

    // ① SafeAccess 故障恢复
    if (SafeAccess::checkFault(frame)) return;

    // ② 如果崩溃在 libasyncProfiler.so 内部 → StackWalker 故障恢复
    uintptr_t pc = frame.pc();
    if (pc >= profiler_lib_start && pc < profiler_lib_end) {
        StackWalker::checkFault();
    }

    // ③ JDK-8313796 workaround
    if (VMStructs::isInterpretedFrameValidFunc((const void*)pc) && frame.skipFaultInstruction())
        return;

    // ④ 都不是 → 传给 JVM 的原始处理器
    orig_crashHandler(signo, siginfo, ucontext);
}
```

这个设计的关键点：async-profiler **接管了 JVM 的崩溃处理器**（SIGSEGV），先检查是否是自己的"故意崩溃"（栈回溯时的安全访问），如果不是才传给 JVM 处理。这样做的好处是：
- 栈回溯时不需要对每个地址做 `mprotect` 检查
- 直接尝试读取，如果失败就被 SIGSEGV 捕获并跳过

---

## 二、Step 1b: VMStructs::ready() — 偏移量最终解析

`VMStructs::ready()` 做了三件事：

```cpp
void VMStructs::ready() {
    resolveOffsets();     // ① 解析压缩指针/CodeHeap/帧结构等运行时参数
    patchSafeFetch();     // ② 修补 JDK SafeFetch bug
    initThreadBridge();   // ③ 建立 Java Thread → VMThread 桥梁
}
```

### 2.1 resolveOffsets — 运行时参数解析

`resolveOffsets()` 在 `VMStructs::init()` 推断的"静态偏移量"基础上，进一步解析需要**运行时才能确定**的参数：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  resolveOffsets() 解析的运行时参数                                          │
├──────────────────────────────┬──────────────────────────────────────────────┤
│ 参数                          │ 作用                                        │
├──────────────────────────────┼──────────────────────────────────────────────┤
│ UseCompressedClassPointers   │ 是否启用压缩类指针                           │
│   _narrow_klass_base         │ = 0x800000000 (GDB 验证)                    │
│   _narrow_klass_shift        │ = 0 (GDB 验证)                              │
├──────────────────────────────┼──────────────────────────────────────────────┤
│ UseCompactObjectHeaders      │ JDK 24+ Lilliput 特性                       │
├──────────────────────────────┼──────────────────────────────────────────────┤
│ _interpreter_frame_bcp_offset│ 解释器帧中 BCP 的偏移                       │
│                              │ = -8 (x86_64, JDK11, GDB 验证)             │
├──────────────────────────────┼──────────────────────────────────────────────┤
│ CodeHeap 地址范围             │ JIT 代码堆的低/高地址边界                    │
│   _code_heap_low             │ = 0x7fffec7ff000 (GDB 验证)                 │
│   _code_heap_high            │ = 0x7fffef7ff000 (GDB 验证)                 │
│                              │ 大小 = 48MB (ReservedCodeCacheSize)          │
├──────────────────────────────┼──────────────────────────────────────────────┤
│ CodeHeap segment 参数         │ 从 CodeHeap 直接查找 nmethod 需要            │
├──────────────────────────────┼──────────────────────────────────────────────┤
│ _call_stub_return            │ call_stub 的返回地址, 用于栈回溯             │
├──────────────────────────────┼──────────────────────────────────────────────┤
│ _collected_heap              │ CollectedHeap 的预留区域, 用于判断地址是否在堆中│
└──────────────────────────────┴──────────────────────────────────────────────┘
```

解析完成后，根据各组偏移量是否齐全，设置 5 个**特性可用标志**：

```
┌───────────────────────────────────────────────────────────────────────┐
│ 特性标志                │ GDB 验证值 │ 含义                            │
├───────────────────────────────────────────────────────────────────────┤
│ _has_class_names        │ true       │ 可以从 oop 解析出类名           │
│ _has_method_structs     │ true       │ 可以解析 nmethod/Method/ConstMethod│
│ _has_compiler_structs   │ true       │ 可以获取当前编译任务            │
│ _has_stack_structs      │ true       │ 可以用 VMStructs 进行栈回溯     │
│ _has_class_loader_data  │ false (!)  │ 不能直接操作 ClassLoaderData     │
│ _has_native_thread_id   │ true (*)   │ 可以获取线程的 OS tid            │
│ _can_dereference_jmethod_id│ true    │ jmethodID 可直接解引用得到 Method*│
└───────────────────────────────────────────────────────────────────────┘

(!) _has_class_loader_data = false 的原因:
    _class_loader_data_next_offset 的值不满足条件
    == sizeof(uintptr_t) * 8 + 8 = 72, 但实际可能不匹配
    这不影响核心功能, 只是 loadMethodIDs 时不走 CLD 预分配优化路径

(*) _has_native_thread_id 在 initThreadBridge 后才变为 true
```

### 2.2 patchSafeFetch — JDK bug 修补

```cpp
void VMStructs::patchSafeFetch() {
    if (WX_MEMORY && VM::hotspot_version() == 17) {
        // JDK-8307549: SafeFetch32 在 Apple Silicon 上崩溃
        void** entry = _libjvm->findSymbol("_ZN12StubRoutines18_safefetch32_entryE");
        if (entry != NULL) *entry = (void*)SafeAccess::load32;
    } else if (WX_MEMORY && VM::hotspot_version() == 11) {
        // JDK-8321116: SafeFetchN 在 Apple Silicon 上崩溃
        void** entry = _libjvm->findSymbol("_ZN12StubRoutines17_safefetchN_entryE");
        if (entry != NULL) *entry = (void*)SafeAccess::load;
    }
}
```

**GDB 验证**: 在我们的环境（Linux x86_64）中，`WX_MEMORY = 0`，所以这个函数直接返回，不执行任何修补。这个 patch 只在 **Apple Silicon (macOS AArch64)** 上生效——因为 macOS 的 W^X 内存保护策略导致 JVM 的 SafeFetch stub 无法在某些场景下工作。

### 2.3 initThreadBridge — 核心桥梁建立

这是 VMInit 后初始化中**最精妙的部分**——建立 Java Thread 对象到 C++ VMThread 指针的映射：

```cpp
void VMStructs::initThreadBridge() {
    // ① 获取当前 Java 线程
    jthread thread;
    VM::jvmti()->GetCurrentThread(&thread);

    // ② 获取 tid 和 eetop 字段的 jfieldID
    JNIEnv* env = VM::jni();
    jclass thread_class = env->FindClass("java/lang/Thread");
    _tid = env->GetFieldID(thread_class, "tid", "J");     // Thread.tid (Java 层线程 ID)
    _eetop = env->GetFieldID(thread_class, "eetop", "J"); // Thread.eetop → VMThread* 指针

    // ③ 通过 eetop 获取当前线程的 VMThread*
    VMThread* vm_thread = VMThread::fromJavaThread(env, thread);

    // ④ 记录关键偏移
    _has_native_thread_id = true;
    _env_offset = (intptr_t)env - (intptr_t)vm_thread;     // JNIEnv 相对 VMThread 的偏移

    // ⑤ 复制 vtable
    memcpy(_java_thread_vtbl, vm_thread->vtable(), sizeof(_java_thread_vtbl));

    // ⑥ 暴力搜索 TLS key — 最精妙的部分
    initTLS(vm_thread);
}
```

### 2.4 initTLS — 暴力搜索 pthread TLS

```cpp
void VMStructs::initTLS(void* vm_thread) {
    for (int i = 0; i < 1024; i++) {
        if (pthread_getspecific((pthread_key_t)i) == vm_thread) {
            _tls_index = i;
            break;
        }
    }
}
```

这段代码的含义：JVM 在每个线程的 **pthread TLS (Thread-Local Storage)** 中存储了指向 `JavaThread*` 的指针。但 TLS 的 key 值是**不公开的**——它是 JVM 启动时通过 `pthread_key_create()` 动态分配的。

async-profiler 的做法极其暴力但有效：**遍历 0~1023 所有可能的 TLS key**，找到哪个 key 存的值恰好等于已知的 `vm_thread` 指针。找到后记录这个 key，以后在信号处理器中就可以通过 `pthread_getspecific(_tls_index)` 快速获取当前线程的 `JavaThread*`。

**为什么需要这个？** 因为在 SIGPROF 信号处理器中，没有 JNI/JVMTI 环境可用，不能走正常的 `eetop` 路径。TLS 是唯一能在信号处理器中安全使用的线程标识机制。

---

## 三、Step 1c: Hook JVMTI 函数表

```cpp
// vmEntry.cpp:385-392
JVMTIFunctions* functions = *(JVMTIFunctions**)_jvmti;
_orig_RedefineClasses = functions->RedefineClasses;       // 保存原始指针
_orig_RetransformClasses = functions->RetransformClasses;
functions->RedefineClasses = RedefineClassesHook;          // 替换为 Hook
functions->RetransformClasses = RetransformClassesHook;
```

已在 1.2 节详细分析，此处不再重复。核心目的是在类重定义后自动重载 jmethodID。

---

## 四、Step 2: loadAllMethodIDs — 预加载方法 ID

```cpp
void VM::loadAllMethodIDs(jvmtiEnv* jvmti, JNIEnv* jni) {
    jint class_count;
    jclass* classes;
    if (jvmti->GetLoadedClasses(&class_count, &classes) == 0) {  // ← 871 个类
        for (int i = 0; i < class_count; i++) {
            loadMethodIDs(jvmti, jni, classes[i]);
        }
        jvmti->Deallocate((unsigned char*)classes);
    }
}
```

### 为什么要预加载？

`AsyncGetCallTrace` 返回的栈帧中包含 `jmethodID`。但 JVM 的 jmethodID 是**惰性分配**的——只有当 JVMTI 或 JNI 首次请求某个方法的 ID 时才会创建。如果不预加载，采样时可能遇到未分配 ID 的方法，导致栈帧信息不完整。

### loadMethodIDs 的两条路径

```cpp
void VM::loadMethodIDs(jvmtiEnv* jvmti, JNIEnv* jni, jclass klass) {
    if (VMStructs::hasClassLoaderData()) {
        // 路径 A: 直接操作 ClassLoaderData 预分配空间
        // → 更高效，但需要 _class_loader_data_offset 等偏移量
        VMKlass* vmklass = VMKlass::fromJavaClass(jni, klass);
        cld->lock();
        // 预分配 MethodList 节点，避免后续分配时的竞争
        cld->unlock();
    }

    // 路径 B: 通过 JVMTI 标准 API 触发 jmethodID 分配
    jvmti->GetClassMethods(klass, &method_count, &methods);
    jvmti->Deallocate((unsigned char*)methods);
}
```

**GDB 验证**: `hasClassLoaderData() = false`，所以走了路径 B。这是更通用的路径——通过 JVMTI 的 `GetClassMethods()` 让 JVM 内部为每个方法分配 jmethodID。返回的 `methods` 数组本身不需要使用，立即释放。

---

## 五、Step 4: Profiler::run → start → Engine::start

### 5.1 run() — 命令分发

```cpp
Error Profiler::run(Arguments& args) {
    // args._action = ACTION_START (1)
    // args._event  = "cpu"
    // args._file   = "/tmp/profile.jfr"
    switch (args._action) {
        case ACTION_START: {
            Error error = start(args, true);  // reset=true
            out << "Profiling started\n";
            break;
        }
        // ...
    }
}
```

### 5.2 start() — 核心启动流程

`Profiler::start()` 是一个近 200 行的函数，按顺序做了以下事情：

```
start(args, reset=true)
  │
  ├─ ① 状态检查: _state > IDLE → 报错 "already started"
  │
  ├─ ② 计算 _event_mask: 从 args 中提取要监听的事件类型
  │
  ├─ ③ 重置计数器/字典（因为 reset=true）
  │     ├─ _total_samples = 0
  │     ├─ _class_map.clear()
  │     ├─ _thread_filter.clear()
  │     └─ _call_trace_storage.clear()
  │
  ├─ ④ 分配 CallTrace 缓冲区（16 个并发槽位）
  │     └─ 每个 = (_max_stack_depth + 128 + 10) × sizeof(CallTraceBuffer)
  │
  ├─ ⑤ selectEngine("cpu")
  │     └─ → 返回 &perf_events（PerfEvents 全局实例）
  │
  ├─ ⑥ 选择栈回溯策略
  │     └─ VMStructs::hasStackStructs() = true → _cstack = CSTACK_VM
  │
  ├─ ⑦ installTraps(begin, end)  → 分配追踪的断点设置
  │
  ├─ ⑧ _jfr.start()  → 初始化 JFR 输出（因为 file=*.jfr）
  │
  ├─ ⑨ _engine->start(args)  → PerfEvents::start()
  │     └─ 这里调用 perf_event_open()（后续 4.1 详析）
  │
  ├─ ⑩ switchThreadEvents(JVMTI_ENABLE)
  │     └─ 启用 THREAD_START + THREAD_END 事件
  │
  └─ ⑪ _state = RUNNING, _epoch++
        └─ profiling 正式开始!
```

### 5.3 selectEngine — 引擎选择逻辑

```
selectEngine("cpu") 的判断链:
  ├─ 如果 event_name 是 "cpu" → perf_events 或 ctimer（如果 perf 不支持）
  ├─ 如果是 "wall"           → wall_clock
  ├─ 如果是 "itimer"         → itimer
  ├─ 如果是 "ctimer"         → ctimer
  ├─ 如果是 "alloc"          → alloc_tracer
  ├─ 如果是 "lock"           → lock_tracer
  ├─ 如果以 "." 包含         → instrument（方法插桩）
  └─ 否则                    → perf_events（作为 perf 硬件事件）
```

**GDB 验证**: `selectEngine('cpu')` → 返回 `PerfEvents` 全局实例。

---

## 六、GDB 验证总结

### 【GDB 验证 1】完整执行时序

```
┌─────────────────────────────────────────────────────────────────────────┐
│ 时序 │ 步骤                          │ 关键数据                        │
├─────────────────────────────────────────────────────────────────────────┤
│  T1  │ VMInit 回调触发               │ 调用者: post_vm_initialized()    │
│  T2  │ setupSignalHandlers()         │ SIGTRAP + SIGSEGV + WAKEUP      │
│  T3  │ VMStructs::resolveOffsets()   │ 5 个特性标志 = true (CLD除外)   │
│  T4  │ VMStructs::patchSafeFetch()   │ Linux x86_64: 跳过 (WX=0)      │
│  T5  │ VMStructs::initThreadBridge() │ eetop + tid + TLS key=0         │
│  T6  │ Hook JVMTI 函数表             │ 保存 + 替换两个函数指针          │
│  T7  │ loadAllMethodIDs()            │ 遍历 871 个类                   │
│  T8  │ Profiler::run(START, "cpu")   │ args 参数传递                   │
│  T9  │ selectEngine("cpu")           │ → PerfEvents                    │
│  T10 │ PerfEvents::start()           │ perf_event_open (4.1 详析)      │
│  T11 │ switchThreadEvents(ENABLE)    │ ThreadStart + ThreadEnd         │
│  T12 │ _state = RUNNING              │ profiling 正式开始!             │
└─────────────────────────────────────────────────────────────────────────┘
```

### 【GDB 验证 2】initThreadBridge 核心数据

```
┌─────────────────────────────────────────────────────────────────────────┐
│ vm_thread            = 0x7ffff17cb800   (JavaThread* 指针)              │
│ _eetop (jfieldID)    = 0xd12043         (Thread.eetop 字段 ID)         │
│ _tid (jfieldID)      = 0xd12083         (Thread.tid 字段 ID)           │
│ _tls_index           = 0               (pthread TLS key)               │
│ _env_offset          = 920             (JNIEnv 相对 JavaThread 的偏移) │
│ _has_native_thread_id = true                                            │
│                                                                          │
│ 说明:                                                                    │
│   _tls_index = 0 表示 JVM 分配的 TLS key 恰好是 0                       │
│   _env_offset = 920 → 在信号处理器中可通过 (char*)vm_thread + 920        │
│                        获取 JNIEnv*, 无需调用任何 JVM API                 │
└─────────────────────────────────────────────────────────────────────────┘
```

### 【GDB 验证 3】resolveOffsets 特性探测结果

```
┌─────────────────────────────────────────────────────────────────────────┐
│ _has_class_names        = true   → 可以从 oop 解析类名                  │
│ _has_method_structs     = true   → 可以解析 nmethod/Method 结构         │
│ _has_compiler_structs   = true   → 可以获取编译任务                     │
│ _has_stack_structs      = true   → ★ 可以用 VM 模式栈回溯              │
│ _has_class_loader_data  = false  → 不走 CLD 预分配优化                  │
│ _compact_object_headers = false  → 非 Lilliput 模式                    │
│ _can_dereference_jmethod_id = true → JDK11 可以直接解引用 jmethodID    │
│                                                                          │
│ _narrow_klass_base      = 0x800000000                                   │
│ _narrow_klass_shift     = 0                                              │
│ _interpreter_frame_bcp_offset = -8  (x86_64, JDK11)                    │
│ _code_heap_low  = 0x7fffec7ff000                                        │
│ _code_heap_high = 0x7fffef7ff000  → CodeCache 大小 = 48MB               │
└─────────────────────────────────────────────────────────────────────────┘
```

### 【GDB 验证 4】loadAllMethodIDs 加载了 871 个类

```
class_count = 871
hasClassLoaderData = false → 全部走 JVMTI GetClassMethods() 路径
```

### 【GDB 验证 5】Profiler::run 启动参数

```
┌─────────────────────────────────────────────────────────────────────────┐
│ args._action    = 1 (ACTION_START)                                      │
│ args._event     = "cpu"                                                 │
│ args._file      = "/tmp/profile.jfr"                                    │
│ args._interval  = 0 (PerfEvents 将使用默认值 10ms)                      │
│ selectEngine    → PerfEvents                                            │
│ switchThreadEvents(mode=1) → JVMTI_ENABLE                               │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 七、设计洞察

### 为什么 ready() 和 loadAllMethodIDs() 不能在 Agent_OnLoad 中执行？

因为 `Agent_OnLoad` 运行在 JVM 的 **OnLoad Phase**：

| 需要的功能 | OnLoad Phase | VMInit 后 |
|-----------|:---:|:---:|
| JNI (FindClass, GetFieldID) | ❌ | ✅ |
| JVMTI GetCurrentThread | ❌ | ✅ |
| JVMTI GetLoadedClasses | ❌ | ✅ |
| pthread_getspecific 有效 | ❌ (Java线程未创建) | ✅ |

`initThreadBridge` 需要 JNI 来查找 `eetop` 字段，`loadAllMethodIDs` 需要 JVMTI 来遍历类——这些在 OnLoad Phase 都不可用。

### TLS 暴力搜索为什么安全？

1. TLS key 的有效范围是 `[0, PTHREAD_KEYS_MAX)`，Linux 上通常是 1024
2. `pthread_getspecific()` 对无效 key 返回 NULL，不会崩溃
3. 只要找到一个匹配的 key 就停止搜索
4. 如果 JVM 使用了 `pthread_key_create()`，key 必然在 0~1023 范围内

这个方法虽然看起来暴力，但在实践中非常可靠——因为 JVM 一定会在 TLS 中存储线程指针。

### _env_offset 的妙用

`_env_offset = 920` 表示 `JNIEnv*` 相对 `JavaThread*` 的偏移是 920 字节。这意味着在信号处理器中（没有 JNI 环境）：

```cpp
// 在信号处理器中获取 JNIEnv
JavaThread* thread = (JavaThread*)pthread_getspecific(_tls_index);
JNIEnv* env = (JNIEnv*)((char*)thread + _env_offset);
```

不需要调用任何 JVM API，纯粹的指针算术，在异步信号处理器中完全安全。

### _has_class_loader_data = false 的影响

GDB 验证显示这个标志为 false，这意味着 `loadMethodIDs()` 不走 CLD 预分配优化路径。这不影响功能正确性，只是性能略有差异：
- CLD 路径：直接在 ClassLoaderData 中预分配 MethodList 节点，避免后续并发分配
- JVMTI 路径：通过 `GetClassMethods()` 触发 JVM 内部的 jmethodID 分配

在 JDK 11 环境下，两种路径最终效果相同，只是 CLD 路径减少了一些内存分配竞争。

---

*创建日期: 2026-02-09*
*GDB 验证环境: OpenJDK 11 slowdebug + async-profiler v4.0 (git 00a0a12)*
*标准条件: -Xms8g -Xmx8g -XX:+UseG1GC -Xint*