# async-profiler v4.3 源码分析大纲

> 版本: v4.3 (stable)
> 源码位置: `/data/workspace/async-profiler/`
> 依赖 JDK: `/data/workspace/openjdk-cut-new/` (OpenJDK 11 slowdebug)
> 编译参数: `CXXFLAGS_EXTRA="-O0 -g"` (可 GDB 单步调试)
> 总代码量: ~16,000 行 C++ (核心) + ~5,000 行 Java (converter/api)

---

## 分析目标

**核心问题**：async-profiler 为什么能在 **不触发 Safepoint** 的情况下安全采样 Java 线程调用栈？

这个问题涉及：
1. **信号驱动采样**：如何通过 `SIGPROF`/`perf_event` 中断线程并获取上下文？
2. **AsyncGetCallTrace**：这个未公开的 HotSpot API 做了什么？为什么它能在信号处理器中使用？
3. **与 JVM 内部结构的交互**：如何在不持有锁的情况下解析 CodeCache/Klass/Method？
4. **安全栈回溯**：如何处理不完整栈帧、JIT 编译代码、解释器帧等各种情况？

**你已有的知识基础**（直接可利用）：
- ✅ Safepoint 机制 100%（ch01-ch03）— 理解 async-profiler 的设计哲学对标
- ✅ JVMTI 事件体系（ch17）— 理解 Agent 如何加载和与 JVM 交互
- ✅ Attach API（ch18-ch19）— 理解 async-profiler 的动态注入路径
- ✅ 解释器系统 92%（entry point/字节码模板）— 理解解释器帧结构
- ✅ 编译系统 90%（C1/C2/CodeCache）— 理解 JIT 帧和 NMethod 结构
- ✅ JavaCalls 框架（ch08）— 理解 call_stub/JavaFrameAnchor
- ✅ 线程系统 100%（线程状态/Parker）— 理解线程采样时机
- ✅ JMM（ch01-ch03）— 理解 Atomic/OrderAccess 在无锁设计中的作用
- ✅ ObjectMonitor（ch03）— 理解锁争用事件的底层

---

## 整体架构

```
┌────────────────────────────────────────────────────────────────────────────────┐
│                         async-profiler v4.3 架构                              │
│                                                                                │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │                        用户接口层                                       │   │
│  │   asprof (CLI)  │  Java API  │  JVMTI Agent_OnLoad/Agent_OnAttach      │   │
│  │   main.cpp       │  javaApi.cpp│  vmEntry.cpp                           │   │
│  └───────────────────────────┬─────────────────────────────────────────────┘   │
│                              ▼                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │                   核心控制器: Profiler (profiler.cpp, 1917 行)          │   │
│  │   状态管理 │ 引擎调度 │ 采样记录 │ 栈回溯 │ 输出生成                    │   │
│  └───────┬──────────┬──────────┬──────────┬────────────────────────────────┘   │
│          │          │          │          │                                     │
│  ┌───────▼──────┐ ┌─▼────────┐│  ┌───────▼──────┐  ┌──────────────────────┐   │
│  │ 采样引擎层    │ │ 追踪引擎层 ││  │  栈回溯层     │  │  存储/输出层         │   │
│  │              │ │          │ │  │              │  │                      │   │
│  │ Engine (基类) │ │          │ │  │ StackWalker  │  │ CallTraceStorage     │   │
│  │  ├ CpuEngine │ │AllocTracer│ │  │  walkFP()    │  │ FlightRecorder(JFR)  │   │
│  │  │ ├PerfEvents│ │ObjectSamp│ │  │  walkDwarf() │  │ FlameGraph           │   │
│  │  │ ├CTimer   │ │LockTracer│ │  │  walkVM()    │  │ Writer (collapsed/   │   │
│  │  │ └ITimer   │ │NativeLock│ │  │              │  │  text/html)          │   │
│  │  ├ WallClock │ │MallocTrc │ │  │ StackFrame   │  │                      │   │
│  │  └ Instrument│ │          │ │  │  (x64/arm..) │  │                      │   │
│  └──────────────┘ └──────────┘ │  └──────────────┘  └──────────────────────┘   │
│                                │                                               │
│  ┌─────────────────────────────▼───────────────────────────────────────────┐   │
│  │                   JVM 交互层                                            │   │
│  │  VMStructs (偏移量推断)  │  VM (JVMTI管理)  │  CodeCache (符号解析)      │   │
│  │  vmStructs.cpp (756行)   │  vmEntry.cpp      │  codeCache.cpp            │   │
│  │  symbols_linux.cpp (881行)│                   │  dwarf.cpp                │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │                   操作系统层                                            │   │
│  │  os_linux.cpp (693行)  │  perfEvents_linux.cpp (987行)                  │   │
│  │  信号处理 / 线程枚举 / perf_event_open / mmap ring buffer              │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────────────────┘
```

---

## 分析计划（共 12 章）

### 第一部分：整体架构与生命周期（2 章）

---

### Ch01: Agent 加载与初始化 — 从 attach 到 ready

**源文件**: `vmEntry.cpp` (530行), `vmEntry.h`, `hooks.cpp`, `zInit.cpp`

**核心问题**: async-profiler 作为 JVMTI Agent 是怎么加载到 JVM 的？初始化了什么？

**分析内容**:

1. **两种加载路径**
   - `-agentpath` 方式 → `Agent_OnLoad()` (JVM 启动时)
   - 动态 attach 方式 → `Agent_OnAttach()` (运行时注入)
   - 两者的差异和共同的初始化流程
   - **关联知识**: 你已分析的 `ch18_agentmain_dynamic_attach.md`

2. **VM::init() — JVMTI 环境建立**
   - `AddCapabilities()` — 请求哪些 JVMTI 能力？为什么？
   - `SetEventCallbacks()` — 注册了哪些回调？
     - `VMInit` / `VMDeath`
     - `ClassLoad` / `ClassPrepare`（为什么需要？→ `loadMethodIDs()`）
     - `CompiledMethodLoad` / `DynamicCodeGenerated`
     - `ThreadStart` / `ThreadEnd`
     - `GarbageCollectionFinish`
   - **关联知识**: 你已分析的 `ch17_jvmti_event_system.md`

3. **VMInit 回调 — JVM 就绪后的初始化**
   - `VM::ready()` → 发现 JVM 内部结构
   - `VMStructs::init()` → 偏移量推断（下一章详细分析）
   - `Hooks::init()` → `dlopen` 钩子安装
   - `Profiler::setupSignalHandlers()` → 信号处理器注册

4. **RedefineClasses/RetransformClasses Hook**
   - 为什么要 hook 这两个 JVMTI 函数？（保护 methodID 映射一致性）
   - `JVMTIFunctions` 结构体 — 直接 patch 函数表
   - **关联知识**: 你已分析的 `ch16_retransform_classes.md`

5. **GDB 验证**
   - 断点 `Agent_OnLoad` / `Agent_OnAttach` 观察参数
   - 断点 `VM::VMInit` 观察初始化顺序
   - 验证 JVMTI capabilities 请求

**产出**: `jvm-md/AsyncProfiler/ch01_agent_loading_and_init.md`

---

### Ch02: VMStructs — 运行时偏移量推断（async-profiler 的"黑科技"）

**源文件**: `vmStructs.cpp` (756行), `vmStructs.h` (717行)

**核心问题**: async-profiler 不依赖 JVM 编译时头文件，如何知道 JVM 内部对象的字段偏移？

**分析内容**:

1. **设计哲学 — 为什么不直接用 JVM 头文件？**
   - 跨 JDK 版本兼容（JDK 8 ~ 25）
   - 不同 JVM 实现（HotSpot / OpenJ9 / Zing）
   - 运行时推断 vs 编译时绑定的权衡

2. **偏移量推断方法**
   - **符号表查找**: `readSymbol()` — 从 `libjvm.so` 查找导出的全局变量
   - **JVM Flag 扫描**: `JVMFlag::find()` — 通过遍历 flag 数组定位
   - **JVMTI API 探测**: 利用 JVMTI 返回值反推结构
   - **vtable 匹配**: `_java_thread_vtbl` — 识别 JavaThread
   - **硬编码偏移表**: 不同 JDK 版本的 fallback

3. **关键偏移量清单（与你已分析的 JVM 结构对照）**
   - **线程相关**: `_thread_osthread_offset`, `_thread_anchor_offset`, `_thread_state_offset`
     → 对照你的 `Thread/ch01_thread_start_complete_flow.md`
   - **CodeCache 相关**: `_blob_size_offset`, `_frame_size_offset`, `_nmethod_*_offset`
     → 对照你的 `CodeCache/codeCache_init.md`
   - **对象头相关**: `_oop_klass_offset`, `_narrow_klass_base`, `_narrow_klass_shift`
     → 对照你的 `Runtime/ch01_object_header_markword.md`
   - **解释器帧**: `_interpreter_frame_bcp_offset`, `_entry_frame_call_wrapper_offset`
     → 对照你的 `Interpreter/generate_normal_entry.md`
   - **JavaFrameAnchor**: `_anchor_sp_offset`, `_anchor_pc_offset`, `_anchor_fp_offset`
     → 对照你的 `Runtime/ch08_javacalls_framework.md`

4. **VMKlass / VMMethod / VMSymbol — 类元数据访问**
   - 不持有锁读取 Klass/Method 信息
   - `VMKlass::fromOop()` — 压缩指针解码
   - `VMMethod::id()` / `validatedId()` — jmethodID 安全获取
   - `isStaleMethodId()` — JDK-8313816 workaround

5. **NMethod 解析 — 从 CodeCache 中定位编译代码**
   - `CodeHeap::findNMethod()` — 通过 segment map 定位
   - `ScopeDesc` — 从 nmethod 中解析内联调用链
   - `NMethod::findScopeOffset()` — 通过 PcDesc 映射 PC 到 scope
   - **关联知识**: 你对 C2 编译管线和 CodeCache 的分析

6. **JavaFrameAnchor — 从 Native 回到 Java**
   - `fromEntryFrame()` — 从 entry frame 中找到 CallWrapper
   - `getFrame()` / `restoreFrame()` — 获取最近的 Java 帧
   - **关联知识**: 你的 `Runtime/ch08_javacalls_framework.md` 中的 JavaFrameAnchor 分析

7. **GDB 验证**
   - 在运行时打印 async-profiler 推断的偏移量 vs 你直接从 JVM 源码计算的偏移量
   - 验证 VMKlass/VMMethod 解析正确性

**产出**: `jvm-md/AsyncProfiler/ch02_vmstructs_offset_discovery.md`

---

### 第二部分：CPU 采样核心（3 章，最重要）

---

### Ch03: 采样引擎体系 — Engine 继承层次与调度

**源文件**: `engine.h/cpp`, `cpuEngine.h/cpp`, `profiler.cpp` (selectEngine 部分)

**核心问题**: async-profiler 支持多种采样方式，它们之间有什么区别？如何选择？

**分析内容**:

1. **Engine 基类设计**
   - `start()` / `stop()` — 虚方法接口
   - `updateCounter()` — CAS 采样率控制（interval 的作用）
   - `_enabled` volatile 标志

2. **引擎继承体系**
   ```
   Engine (engine.h)
   ├── CpuEngine (cpuEngine.h)            — CPU 采样基类
   │   ├── PerfEvents (perfEvents.h)      — perf_event_open (Linux, 推荐)
   │   ├── CTimer (ctimer.h)              — timer_create (Linux, fallback)
   │   └── ITimer (itimer.h)              — setitimer (跨平台, 进程级)
   ├── WallClock (wallClock.h)            — Wall clock 采样
   ├── AllocTracer (allocTracer.h)        — TLAB 分配追踪 (Trap)
   ├── ObjectSampler (objectSampler.h)    — JVMTI 对象采样
   ├── LockTracer (lockTracer.h)          — Java 锁争用
   ├── NativeLockTracer (nativeLockTracer.h) — 原生锁争用
   ├── MallocTracer (mallocTracer.h)      — malloc/free 追踪
   └── Instrument (instrument.h)          — 字节码插桩
   ```

3. **CpuEngine 通用机制**
   - 信号处理器 `signalHandler()` — 采样入口
   - `setupThreadHook()` — `pthread_create` hook，确保新线程自动注册
   - `createForAllThreads()` — 遍历 `/proc/self/task/` 为每个线程创建采样源
   - `onThreadStart()` / `onThreadEnd()` — 线程生命周期联动

4. **Profiler::selectEngine() — 引擎选择策略**
   - 事件名 → 引擎映射（cpu/wall/alloc/lock/malloc/...）
   - PerfEvents 优先级最高，fallback 到 CTimer / ITimer

5. **Profiler 状态机**
   - `NEW → IDLE → RUNNING → IDLE → TERMINATED`
   - `start()` / `stop()` / `run()` / `expire()` 的关系

**产出**: `jvm-md/AsyncProfiler/ch03_engine_hierarchy_and_dispatch.md`

---

### Ch04: PerfEvents — perf_event_open 采样（核心中的核心）

**源文件**: `perfEvents_linux.cpp` (987行), `perfEvents.h`

**核心问题**: async-profiler 如何利用 Linux perf_event 子系统实现高精度、低开销的 CPU 采样？

**分析内容**:

1. **perf_event_open 系统调用**
   - `struct perf_event_attr` 配置
   - `PERF_TYPE_SOFTWARE` (cpu-clock) vs `PERF_TYPE_HARDWARE` (cycles/cache-miss/...)
   - `sample_period` / `sample_freq` — 采样间隔
   - `PERF_SAMPLE_CALLCHAIN` — 内核态帮助收集 callchain
   - **每线程 fd**：为什么不用系统级 fd？

2. **信号驱动采样 (Signal-based profiling)**
   - `fcntl(fd, F_SETSIG, SIGPROF)` — 将 overflow 绑定到信号
   - `signalHandler()` — 信号处理器完整流程
   - `readCounter()` — 从 mmap ring buffer 读取精确计数器值
   - **异步信号安全性**：为什么能在信号处理器中做这些事？

3. **perf_event mmap ring buffer**
   - `_use_perf_mmap` — 为什么用 mmap？（减少系统调用开销）
   - ring buffer 布局：`perf_event_mmap_page` + data region
   - `walk()` — 从 ring buffer 中读取内核栈 callchain

4. **PerfEvents::start() 完整流程**
   - 事件类型解析（`cpu` / `cycles` / `cache-misses` / 自定义 PMU）
   - `createForAllThreads()` → 为每个线程调用 `createForThread()`
   - `perf_event_open()` 参数配置
   - 信号绑定 + mmap 映射

5. **与 JVM 的协调**
   - `PerfEvents` 在 GC 期间仍然会触发吗？→ `ASGCT_Failure` 处理
   - `_alluser` 模式 vs kernel+user 模式
   - `_kernel_stack` — 是否收集内核态调用栈

6. **CTimer / ITimer fallback 对比**
   - `timer_create(CLOCK_THREAD_CPUTIME_ID)` — 线程级 CPU 时间
   - `setitimer(ITIMER_PROF)` — 进程级，信号发给随机线程
   - 三者精度/开销/兼容性对比

7. **GDB 验证**
   - `strace` 追踪 `perf_event_open` 系统调用参数
   - 断点 `PerfEvents::signalHandler` 观察采样流程
   - 验证 ring buffer 内容

**产出**: `jvm-md/AsyncProfiler/ch04_perf_events_sampling.md`

---

### Ch05: AsyncGetCallTrace + 栈回溯 — 信号安全的调用栈采集

**源文件**: `profiler.cpp` (recordSample 部分), `stackWalker.cpp` (512行), `stackFrame_x64.cpp` (322行), `safeAccess.cpp`

**核心问题**: 在信号处理器中，如何安全地获取 Java + Native 混合调用栈？

**分析内容**:

1. **recordSample() — 采样记录的总入口**
   - 从信号处理器调用
   - `getNativeTrace()` — 先获取 native 部分
   - `getJavaTraceAsync()` — 再获取 Java 部分
   - `fillFrameTypes()` — 标记帧类型（解释/JIT/内联/native）
   - 为什么要分两步？两者的边界在哪？

2. **AsyncGetCallTrace — HotSpot 的未公开 API**
   - 函数签名: `void AsyncGetCallTrace(ASGCT_CallTrace*, jint, void*)`
   - 从 `libjvm.so` 动态查找: `VM::_asyncGetCallTrace = dlsym("AsyncGetCallTrace")`
   - **ASGCT_CallTrace** 结构: `env` + `num_frames` + `frames[]`
   - **ASGCT_CallFrame** 结构: `bci` + `method_id`
   - **Failure codes**: `ticks_no_Java_frame`, `ticks_GC_active`, `ticks_not_walkable_*`
   - **为什么它能在信号处理器中使用？**
     - 不需要 Safepoint
     - 不分配内存
     - 但有 failure 情况需要处理
   - **HotSpot 源码对照**: `forte.cpp` → `AsyncGetCallTrace()` 实现
     → 对照你已有的解释器帧/JIT 帧知识

3. **StackWalker::walkFP() — Frame Pointer 栈回溯**
   - 经典 FP-chain: `rbp → previous rbp → ...`
   - 限制：需要 `-fno-omit-frame-pointer`
   - Java 代码（C2 默认保留 FP）vs native 代码（可能不保留）
   - 安全访问: `SafeAccess` / `SEGV` 信号恢复

4. **StackWalker::walkDwarf() — DWARF CFI 栈回溯**
   - 不需要 FP，利用 DWARF `.eh_frame` 信息
   - `FrameDesc` 结构 — 预计算的 CFA 规则
   - `dwarf.cpp` — DWARF 解析
   - 比 FP 更可靠但更慢

5. **StackWalker::walkVM() — JVM 内部栈回溯**
   - 利用 `VMStructs` 偏移量直接解析 JVM 栈帧
   - 处理混合帧: 解释器帧 → JIT 帧 → entry 帧 → native 帧
   - `JavaFrameAnchor` 的关键作用 — 从 native 回到 Java
   - `NMethod::findScopeOffset()` + `ScopeDesc` — 解析 JIT 内联帧

6. **StackFrame (平台相关)**
   - `stackFrame_x64.cpp` — x86_64 平台的帧解析
   - `ucontext` → 提取 `rip/rsp/rbp`
   - `checkInterruptedSyscall()` — 如果信号中断了系统调用
   - `isSyscall()` — 检测 `syscall` 指令

7. **SafeAccess — 安全内存访问**
   - `safeAccess.cpp` — SIGSEGV 恢复机制
   - 为什么在信号处理器中读内存可能 crash？（指针已被 GC 移动、内存已被释放）
   - `checkFault()` — 处理页错误

8. **GDB 验证**
   - 断点 `Profiler::recordSample` 观察完整采样流程
   - 对比 `AsyncGetCallTrace` 返回 vs `walkFP` 返回
   - 验证 ASGCT 失败码分布

**产出**: `jvm-md/AsyncProfiler/ch05_async_get_call_trace_and_stack_walk.md`

---

### 第三部分：各种追踪引擎（4 章）

---

### Ch06: WallClock 采样 — 全线程采样与线程状态

**源文件**: `wallClock.cpp` (269行), `wallClock.h`

**核心问题**: Wall clock 采样和 CPU 采样有什么区别？如何识别线程在"等什么"？

**分析内容**:

1. **Wall vs CPU 的根本区别**
   - CPU 采样：只有在 CPU 上运行时才采样
   - Wall 采样：不管线程在不在 CPU 上都采样
   - 场景：定位 IO 等待/锁等待/sleep 等非 CPU 热点

2. **实现原理**
   - 独立采样线程 `timerLoop()` — pthread 轮询
   - 遍历所有线程 → `tgkill(SIGPROF)` 发信号
   - `WALL_BATCH` vs `WALL_LEGACY` 模式区别
   - `CPU_ONLY` 模式（退化为 CPU 采样）

3. **线程状态获取**
   - `getThreadState()` — 从 `ucontext` 推断线程在做什么
   - `ThreadState` 枚举: RUNNING / SLEEPING / ...
   - **关联知识**: 你的 `Thread/ch02_thread_interrupt_mechanism.md`

4. **GDB 验证**
   - 对比 wall 和 cpu 采样结果差异

**产出**: `jvm-md/AsyncProfiler/ch06_wall_clock_sampling.md`

---

### Ch07: AllocTracer — TLAB 分配追踪（Trap 机制）

**源文件**: `allocTracer.cpp` (122行), `allocTracer.h`, `trap.cpp` (64行), `trap.h`

**核心问题**: async-profiler 如何在不使用 JVMTI 的情况下追踪对象分配？

**分析内容**:

1. **Trap 机制 — 代码注入**
   - `Trap` 类 — 在 JVM 代码中植入断点指令 (`int3` / `brk`)
   - `_in_new_tlab` / `_outside_tlab` — 两个 trap 点
   - **目标函数**: JVM 中的 TLAB 分配入口
   - 信号处理 `trapHandler()` → `SIGTRAP` → 识别是哪个 trap → 记录分配

2. **为什么不用 JVMTI ObjectAlloc 事件？**
   - JVMTI 事件需要 Safepoint（你已经分析过）
   - Trap 方式是异步的，开销更低
   - 只采样，不拦截每一次分配

3. **分配事件类型**
   - `ALLOC_SAMPLE` — TLAB 内分配（`in_new_tlab`）
   - `ALLOC_OUTSIDE_TLAB` — TLAB 外分配（大对象）
   - **关联知识**: 你的 `Runtime/ch02_object_allocation.md` 和 `Universe/3.3-TLAB.md`

4. **ObjectSampler — JVMTI 方式对比**
   - JDK 11+ `SampledObjectAlloc` 事件
   - `_live` 模式 — GC 后只保留存活对象
   - Trap vs JVMTI 两种方式的适用场景对比

5. **GDB 验证**
   - 断点 `AllocTracer::trapHandler` 观察分配追踪

**产出**: `jvm-md/AsyncProfiler/ch07_alloc_tracer_trap_mechanism.md`

---

### Ch08: LockTracer + NativeLockTracer — 锁争用追踪

**源文件**: `lockTracer.cpp` (271行), `nativeLockTracer.cpp`, `lockTracer.h`, `nativeLockTracer.h`

**核心问题**: async-profiler 如何追踪 Java 锁争用和原生锁争用？

**分析内容**:

1. **Java 锁争用 — LockTracer**
   - JVMTI `MonitorContendedEnter` / `MonitorContendedEntered` 事件
   - `Unsafe.park()` hook — 追踪 `j.u.c` 锁
   - `RegisterNativesHook` — 拦截 `Unsafe.park` 的 native 注册
   - **关联知识**: 你的 `Runtime/ch03_lock_optimization.md` (ObjectMonitor)

2. **原生锁争用 — NativeLockTracer**
   - `pthread_mutex_lock` / `pthread_rwlock_*` hook
   - GOT/PLT patching — 替换动态链接函数入口
   - `hooks.cpp` — `patchLibraries()` 机制

3. **锁争用度量**
   - 等待时间累积
   - 采样率控制（`_interval`）

4. **GDB 验证**
   - 构造锁争用场景，观察 LockTracer 触发

**产出**: `jvm-md/AsyncProfiler/ch08_lock_tracer_contention.md`

---

### Ch09: MallocTracer + Instrument — 原生内存 + 字节码插桩

**源文件**: `mallocTracer.cpp`, `instrument.cpp` (1279行), `hooks.cpp` (200行)

**核心问题**: async-profiler 如何追踪原生内存泄漏？如何实现 Java 方法级插桩？

**分析内容**:

1. **MallocTracer — 原生内存追踪**
   - `malloc` / `calloc` / `realloc` / `free` hook
   - GOT patching 机制（同 NativeLockTracer）
   - `_nofree` 模式 — 追踪内存泄漏

2. **Hooks — GOT/PLT Patching 统一框架**
   - `patchLibraries()` — 扫描所有 .so 的 GOT 表
   - `patchImport()` — 替换函数指针
   - `dlopen_hook` — 新加载的 .so 也要 patch
   - **这是 async-profiler 的一个"黑科技"**

3. **Instrument — 字节码插桩引擎**
   - `ClassFileLoadHook` — JVMTI 字节码转换
   - 目标方法匹配（`_targets` map）
   - 注入 `recordEntry()` / `recordExit0()` 调用
   - 方法耗时追踪（METHOD_TRACE 事件）
   - **关联知识**: 你的 `ch16_retransform_classes.md` 和 `ch17_jvmti_event_system.md`

4. **GDB 验证**
   - 观察 GOT patching 过程

**产出**: `jvm-md/AsyncProfiler/ch09_malloc_tracer_and_instrument.md`

---

### 第四部分：符号解析与输出（2 章）

---

### Ch10: CodeCache + 符号解析 — 从地址到函数名

**源文件**: `codeCache.cpp` (327行), `codeCache.h`, `symbols_linux.cpp` (881行), `frameName.cpp` (403行), `dwarf.cpp` (357行)

**核心问题**: 一个采样得到的 PC 地址，如何变成可读的"类名.方法名"或"libxxx.so::function"？

**分析内容**:

1. **CodeCacheArray — 本地库符号表管理**
   - 每个 .so → 一个 `CodeCache` 对象
   - `CodeBlob` — 地址范围 → 函数名映射
   - `binarySearch()` — O(log n) 符号查找

2. **symbols_linux.cpp — ELF 符号解析**
   - 解析 `/proc/self/maps` → 定位所有加载的 .so
   - ELF `.symtab` / `.dynsym` 解析
   - `demangle()` — C++ 名称还原

3. **frameName.cpp — Java 帧名称格式化**
   - `jmethodID` → 类名 + 方法名 + 签名
   - `VMKlass::name()` → `VMSymbol` → 字符串
   - 内联帧的特殊处理

4. **DWARF — 调试信息解析**
   - `.eh_frame` / `.debug_frame` 解析
   - `FrameDesc` — CFA (Canonical Frame Address) 规则
   - 用于 `walkDwarf()` 栈回溯

5. **JVM CodeHeap 集成**
   - `CodeHeap::findNMethod()` — 从 JVM CodeCache 中查找 nmethod
   - 与 async-profiler 自身的 `_runtime_stubs` 和 `_native_libs` 配合

**产出**: `jvm-md/AsyncProfiler/ch10_symbol_resolution.md`

---

### Ch11: 数据存储与输出 — JFR/FlameGraph/Collapsed

**源文件**: `callTraceStorage.cpp` (313行), `flightRecorder.cpp` (1500行), `flameGraph.cpp` (301行), `writer.cpp`

**核心问题**: 采样数据如何存储、聚合、最终输出为火焰图/JFR 文件？

**分析内容**:

1. **CallTraceStorage — 调用栈去重存储**
   - 哈希表实现 — `LongHashTable`
   - `put()` — 新调用栈的存储
   - `add()` — 已有调用栈的计数累加
   - `_overflow` — 哈希表满时的处理
   - 并发安全 — `SpinLock[CONCURRENCY_LEVEL]`

2. **FlightRecorder — JFR 格式输出**
   - JFR 事件格式兼容
   - `Recording` 类 — 录制管理
   - 事件写入 — `recordEvent()`
   - JFR 元数据 — `jfrMetadata.cpp`

3. **输出格式**
   - `dumpCollapsed()` — Collapsed 格式（适配 FlameGraph.pl）
   - `dumpFlameGraph()` — 内置 HTML 火焰图
   - `dumpText()` — 文本格式
   - `dumpOtlp()` — OpenTelemetry 格式

4. **Arguments 解析**
   - `arguments.cpp` — 命令行参数解析
   - `start,event=cpu,interval=10ms,file=output.jfr` 格式

**产出**: `jvm-md/AsyncProfiler/ch11_data_storage_and_output.md`

---

### 第五部分：综合（1 章）

---

### Ch12: 完整采样流程串联 + 与 JVM 的关系 + 面试专题

**核心问题**: 从 `asprof start` 到生成火焰图，完整的数据流是什么？

**分析内容**:

1. **完整采样流程时序图**
   ```
   用户: asprof -d 30 -f profile.html <pid>
     → Attach API → Agent_OnAttach → Profiler::run()
       → selectEngine("cpu") → PerfEvents
         → perf_event_open(每个线程)
           → 信号溢出 → SIGPROF
             → signalHandler()
               → Profiler::recordSample()
                 → getNativeTrace() [FP/DWARF]
                 → getJavaTraceAsync() [AsyncGetCallTrace]
                 → CallTraceStorage::put()
                 → FlightRecorder::recordEvent()
       → 30 秒后 stop()
         → close(perf_event fd)
         → Profiler::dump() → dumpFlameGraph()
   ```

2. **async-profiler 与 JVM Safepoint 的关系**
   - **核心对比**: JVMTI GetStackTrace (需要 Safepoint) vs AsyncGetCallTrace (不需要)
   - 你已经分析了 Safepoint 的 5 阶段、TTSP、Counted Loop 等
   - 在此基础上深入理解"为什么 async-profiler 不需要 STW"
   - ASGCT 的 failure 类型 vs Safepoint 保证

3. **async-profiler vs JFR 采样对比**
   - JFR 使用 `JfrThreadSampling::do_sample()` — 在 Safepoint 中采样
   - async-profiler 使用 `perf_event` 信号 — 异步采样
   - 精度 / 开销 / 安全性 / 适用场景

4. **面试专题（15+ 道）**
   - Q: async-profiler 为什么不需要 Safepoint？（区别于 JFR/jstack）
   - Q: perf_event_open 和 setitimer 有什么区别？
   - Q: AsyncGetCallTrace 是什么？什么时候会失败？
   - Q: 如何在信号处理器中安全地回溯栈？
   - Q: Frame Pointer vs DWARF 栈回溯的优劣？
   - Q: async-profiler 的 alloc 采样原理？（Trap vs JVMTI）
   - Q: async-profiler 如何 hook dlopen/malloc/pthread_mutex_lock？
   - Q: 混合模式火焰图（Java + Native + Kernel）怎么实现的？
   - Q: 为什么需要 `-XX:+PreserveFramePointer`？什么时候不需要？
   - Q: async-profiler 如何处理 JIT 内联的方法？
   - Q: Wall clock 采样和 CPU 采样的区别？
   - Q: async-profiler 如何知道 JVM 内部结构的偏移量？
   - ...

5. **与 PerfMa 产品的关联**
   - PerfMa XSea 线上诊断 → 底层可能使用类似的采样技术
   - 你对 async-profiler 源码的理解 **直接命中 PerfMa 核心业务**

**产出**: `jvm-md/AsyncProfiler/ch12_complete_flow_and_interview.md`

---

## 分析顺序建议

```
Phase 1: 核心机制（最重要，1-2 周）
┌─────────────────────────────────────────────────────────────┐
│ Ch01 Agent 加载   →  Ch02 VMStructs  →  Ch04 PerfEvents    │
│ (1天)              (2天)              (2天)                 │
│                                                             │
│ Ch05 AsyncGetCallTrace + 栈回溯  →  Ch03 引擎体系          │
│ (3天, 最核心)                       (1天)                   │
└─────────────────────────────────────────────────────────────┘

Phase 2: 各种追踪器（选读，1 周）
┌─────────────────────────────────────────────────────────────┐
│ Ch06 WallClock  →  Ch07 AllocTracer  →  Ch08 LockTracer    │
│ (0.5天)           (1天)                (1天)               │
│                                                             │
│ Ch09 MallocTracer + Instrument                              │
│ (1天)                                                       │
└─────────────────────────────────────────────────────────────┘

Phase 3: 符号解析与输出（1 周）
┌─────────────────────────────────────────────────────────────┐
│ Ch10 符号解析  →  Ch11 存储/输出  →  Ch12 完整串联 + 面试   │
│ (2天)             (2天)             (1天)                   │
└─────────────────────────────────────────────────────────────┘
```

## 源文件-章节映射表

| 源文件 | 行数 | 对应章节 | 重要度 |
|--------|------|----------|--------|
| `profiler.cpp` | 1917 | Ch03/Ch05/Ch12 | ⭐⭐⭐⭐⭐ |
| `profiler.h` | 257 | Ch03 | ⭐⭐⭐⭐⭐ |
| `perfEvents_linux.cpp` | 987 | Ch04 | ⭐⭐⭐⭐⭐ |
| `vmStructs.cpp` | 756 | Ch02 | ⭐⭐⭐⭐⭐ |
| `vmStructs.h` | 717 | Ch02 | ⭐⭐⭐⭐⭐ |
| `vmEntry.cpp` | 530 | Ch01 | ⭐⭐⭐⭐⭐ |
| `stackWalker.cpp` | 512 | Ch05 | ⭐⭐⭐⭐⭐ |
| `symbols_linux.cpp` | 881 | Ch10 | ⭐⭐⭐⭐ |
| `flightRecorder.cpp` | 1500 | Ch11 | ⭐⭐⭐⭐ |
| `instrument.cpp` | 1279 | Ch09 | ⭐⭐⭐ |
| `os_linux.cpp` | 693 | Ch04/Ch06 | ⭐⭐⭐ |
| `arguments.cpp` | 660 | Ch11 | ⭐⭐⭐ |
| `codeCache.cpp` | 327 | Ch10 | ⭐⭐⭐ |
| `stackFrame_x64.cpp` | 322 | Ch05 | ⭐⭐⭐⭐ |
| `callTraceStorage.cpp` | 313 | Ch11 | ⭐⭐⭐ |
| `flameGraph.cpp` | 301 | Ch11 | ⭐⭐ |
| `lockTracer.cpp` | 271 | Ch08 | ⭐⭐⭐ |
| `wallClock.cpp` | 269 | Ch06 | ⭐⭐⭐ |
| `dwarf.cpp` | 357 | Ch10 | ⭐⭐⭐ |
| `frameName.cpp` | 403 | Ch10 | ⭐⭐ |
| `hooks.cpp` | 200 | Ch09 | ⭐⭐⭐ |
| `allocTracer.cpp` | 122 | Ch07 | ⭐⭐⭐ |
| `mallocTracer.cpp` | — | Ch09 | ⭐⭐ |
| `trap.cpp` | 64 | Ch07 | ⭐⭐⭐ |

---

## 与你已有 JVM 知识的交叉引用

| async-profiler 概念 | 你已有的 JVM 分析 | 交叉价值 |
|---------------------|------------------|----------|
| AsyncGetCallTrace | Safepoint ch01-03 | **核心对比**: 为什么 ASGCT 不需要 Safepoint |
| Agent_OnLoad/Attach | ch17 JVMTI + ch18 Attach | **完整闭环**: 从外部工具到 JVM 内部 |
| VMStructs 偏移量 | 所有 JVM 数据结构分析 | **验证**: 你计算的偏移量 vs asprof 推断的 |
| 信号处理器中的栈回溯 | 解释器帧/JIT 帧/JavaCalls | **深入理解**: 各种帧类型在采样时的表现 |
| PerfEvents + perf_event_open | Linux 性能工具差距 | **弥补差距**: 这正是 PerfMa 要的 |
| Trap 分配追踪 | TLAB/对象分配 ch02 | **完整链路**: 从分配到追踪 |
| MonitorContendedEnter | ObjectMonitor ch03 | **应用层面**: 锁争用诊断 |
| GOT/PLT patching | — | **新知识**: 动态链接层面的 hook |
| DWARF CFI | — | **新知识**: 调试信息格式 |
| JFR 输出格式 | — | **新知识**: 事件录制协议 |

---

*创建日期: 2026-02-09*
*预计总工时: 3-4 周（每天 2-3 小时）*
