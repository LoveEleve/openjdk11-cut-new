# async-profiler v4.3 源码分析大纲 v2（细分版）

> 版本: v4.3 (stable)
> 源码位置: `/data/workspace/async-profiler/`
> 依赖 JDK: `/data/workspace/openjdk-cut-new/` (OpenJDK 11 slowdebug)
> 总代码量: ~16,000 行 C++ (核心) + ~5,000 行 Java (converter/api)
> **规则**: 每个小节 = 一个独立 md 文件，控制在 300-500 行

---

## 整体架构图（不变）

```
用户接口层:  asprof CLI / Java API / JVMTI Agent_OnLoad|OnAttach
                              ▼
核心控制器:  Profiler (profiler.cpp, 1917行) — 状态管理/引擎调度/采样记录
                              ▼
     ┌────────────┬──────────────────┬──────────────┐
  采样引擎层      追踪引擎层          栈回溯层        存储/输出层
  PerfEvents     AllocTracer        walkFP()       CallTraceStorage
  CTimer/ITimer  LockTracer         walkDwarf()    FlightRecorder
  WallClock      MallocTracer       walkVM()       FlameGraph
  Instrument     ObjectSampler                     Writer
                              ▼
JVM交互层:  VMStructs(偏移量推断) / VM(JVMTI管理) / CodeCache(符号解析)
                              ▼
OS层:  os_linux.cpp / perfEvents_linux.cpp / 信号处理 / perf_event_open
```

---

## 小节清单（共 30 节）

### Part 1: 整体架构与生命周期

| # | 小节 | 源文件 | 行数 | 核心问题 | 产出文件 |
|---|------|--------|------|----------|----------|
| 1.1 | Agent 加载路径 | vmEntry.cpp | ~200行 | `Agent_OnLoad` vs `Agent_OnAttach` 的差异与共同流程 | ch01_1_agent_load_path.md |
| 1.2 | JVMTI 环境建立 | vmEntry.cpp | ~150行 | 请求了哪些 Capabilities？注册了哪些回调？为什么？ | ch01_2_jvmti_env_setup.md |
| 1.3 | VMInit 后的初始化 | vmEntry.cpp, hooks.cpp | ~180行 | `VM::ready()` 做了什么？信号/钩子/偏移量怎么初始化？ | ch01_3_vminit_and_ready.md |

### Part 2: VMStructs 偏移量推断

| # | 小节 | 源文件 | 行数 | 核心问题 | 产出文件 |
|---|------|--------|------|----------|----------|
| 2.1 | 设计哲学与推断方法总览 | vmStructs.cpp/h | ~300行 | 为什么不直接用 JVM 头文件？有哪几种推断方法？ | ch02_1_vmstructs_overview.md |
| 2.2 | 线程/对象头/解释器帧偏移量 | vmStructs.cpp | ~200行 | 关键偏移量清单 + 与 JVM 源码对照验证 | ch02_2_key_offsets.md |
| 2.3 | VMKlass/VMMethod/NMethod 解析 | vmStructs.h | ~250行 | 如何不持锁读取类元数据？如何从 CodeHeap 定位 nmethod？ | ch02_3_vmklass_vmmethod.md |

### Part 3: 采样引擎体系

| # | 小节 | 源文件 | 行数 | 核心问题 | 产出文件 |
|---|------|--------|------|----------|----------|
| 3.1 | Engine 基类 + 引擎选择 | engine.h, profiler.cpp | ~150行 | 引擎继承层次？Profiler 如何选择引擎？ | ch03_1_engine_hierarchy.md |
| 3.2 | Profiler 状态机 + 生命周期 | profiler.cpp/h | ~200行 | start/stop/run/expire 怎么配合？状态如何流转？ | ch03_2_profiler_state_machine.md |

### Part 4: PerfEvents — Linux perf_event 采样（核心中的核心）

| # | 小节 | 源文件 | 行数 | 核心问题 | 产出文件 |
|---|------|--------|------|----------|----------|
| 4.1 | perf_event_open 配置 | perfEvents_linux.cpp | ~300行 | attr 怎么配的？事件类型/采样周期/每线程 fd | ch04_1_perf_event_open.md |
| 4.2 | 信号驱动采样 + mmap ring buffer | perfEvents_linux.cpp | ~300行 | overflow → SIGPROF → signalHandler → readCounter | ch04_2_signal_and_ringbuffer.md |
| 4.3 | CTimer/ITimer fallback | ctimer.cpp, itimer.cpp | ~200行 | 三种 CPU 采样方式的对比（精度/开销/兼容性） | ch04_3_ctimer_itimer_fallback.md |

### Part 5: AsyncGetCallTrace + 栈回溯（最关键）

| # | 小节 | 源文件 | 行数 | 核心问题 | 产出文件 |
|---|------|--------|------|----------|----------|
| 5.1 | recordSample() 总入口 | profiler.cpp | ~200行 | 信号处理器里干了什么？native + java 两步怎么分的？ | ch05_1_record_sample.md |
| 5.2 | AsyncGetCallTrace 详解 | profiler.cpp + forte.cpp(JVM) | ~300行 | ASGCT 是什么？参数/返回值/失败码？为什么不需要 Safepoint？ | ch05_2_async_get_call_trace.md |
| 5.3 | walkFP — Frame Pointer 栈回溯 | stackWalker.cpp, stackFrame_x64.cpp | ~250行 | FP-chain 怎么走？什么时候会断？SafeAccess 怎么保护？ | ch05_3_walk_fp.md |
| 5.4 | walkDwarf — DWARF CFI 栈回溯 | stackWalker.cpp, dwarf.cpp | ~300行 | 不需要 FP 怎么回溯？.eh_frame 怎么解析？ | ch05_4_walk_dwarf.md |
| 5.5 | walkVM — JVM 内部栈回溯 | stackWalker.cpp | ~200行 | 利用 VMStructs 直接解析 JVM 帧，混合帧怎么处理？ | ch05_5_walk_vm.md |

### Part 6: WallClock 采样

| # | 小节 | 源文件 | 行数 | 核心问题 | 产出文件 |
|---|------|--------|------|----------|----------|
| 6.1 | WallClock 实现 + 线程状态 | wallClock.cpp | 269行 | Wall vs CPU 区别？timerLoop 怎么工作？ | ch06_1_wall_clock.md |

### Part 7: 分配追踪

| # | 小节 | 源文件 | 行数 | 核心问题 | 产出文件 |
|---|------|--------|------|----------|----------|
| 7.1 | AllocTracer — Trap 机制 | allocTracer.cpp, trap.cpp | ~186行 | 怎么在 JVM 代码中植入断点？TLAB 分配怎么拦截？ | ch07_1_alloc_tracer_trap.md |
| 7.2 | ObjectSampler — JVMTI 方式 | objectSampler.cpp | ~100行 | JDK 11+ SampledObjectAlloc 事件，Trap vs JVMTI 对比 | ch07_2_object_sampler.md |

### Part 8: 锁争用追踪

| # | 小节 | 源文件 | 行数 | 核心问题 | 产出文件 |
|---|------|--------|------|----------|----------|
| 8.1 | LockTracer — Java 锁争用 | lockTracer.cpp | 271行 | MonitorContendedEnter + Unsafe.park hook | ch08_1_lock_tracer.md |
| 8.2 | NativeLockTracer — 原生锁 | nativeLockTracer.cpp | ~150行 | pthread_mutex hook + GOT/PLT patching 简介 | ch08_2_native_lock_tracer.md |

### Part 9: GOT Patching + MallocTracer + Instrument

| # | 小节 | 源文件 | 行数 | 核心问题 | 产出文件 |
|---|------|--------|------|----------|----------|
| 9.1 | Hooks — GOT/PLT Patching 框架 | hooks.cpp | 200行 | 怎么替换 .so 的 GOT 表？dlopen hook 怎么做？ | ch09_1_got_plt_patching.md |
| 9.2 | MallocTracer — 原生内存追踪 | mallocTracer.cpp | ~150行 | malloc/free hook + 泄漏检测 | ch09_2_malloc_tracer.md |
| 9.3 | Instrument — 字节码插桩引擎 | instrument.cpp | 1279行 | ClassFileLoadHook + 方法匹配 + 耗时追踪 | ch09_3_instrument.md |

### Part 10: 符号解析

| # | 小节 | 源文件 | 行数 | 核心问题 | 产出文件 |
|---|------|--------|------|----------|----------|
| 10.1 | ELF 符号 + /proc/self/maps | symbols_linux.cpp | 881行 | PC 地址 → .so 函数名的完整链路 | ch10_1_elf_symbols.md |
| 10.2 | CodeCache + frameName | codeCache.cpp, frameName.cpp | ~730行 | Java 帧名称格式化 + JVM CodeHeap 集成 | ch10_2_codecache_framename.md |

### Part 11: 数据存储与输出

| # | 小节 | 源文件 | 行数 | 核心问题 | 产出文件 |
|---|------|--------|------|----------|----------|
| 11.1 | CallTraceStorage — 调用栈去重 | callTraceStorage.cpp | 313行 | 哈希表设计 + 并发安全 | ch11_1_call_trace_storage.md |
| 11.2 | FlightRecorder — JFR 输出 | flightRecorder.cpp | 1500行 | JFR 事件格式 + 录制管理 | ch11_2_flight_recorder.md |
| 11.3 | FlameGraph + Writer | flameGraph.cpp, writer.cpp | ~500行 | 火焰图生成 + 各种输出格式 | ch11_3_flamegraph_output.md |

### Part 12: 综合串联

| # | 小节 | 源文件 | 行数 | 核心问题 | 产出文件 |
|---|------|--------|------|----------|----------|
| 12.1 | 完整采样流程时序图 | 全部 | — | 从 `asprof start` 到火焰图的完整数据流 | ch12_1_complete_flow.md |
| 12.2 | async-profiler vs JFR vs jstack | — | — | 三者采样原理对比 + Safepoint 关系 | ch12_2_comparison.md |
| 12.3 | 面试专题（15+ 道） | — | — | 面试常见问题 + 深度解答 | ch12_3_interview.md |

---

## 进度追踪

| # | 小节 | 状态 | 完成日期 |
|---|------|------|----------|
| 1.1 | Agent 加载路径 | ✅ 完成 | 2026-02-09 |
| 1.2 | JVMTI 环境建立 | ✅ 完成 | 2026-02-09 |
| 1.3 | VMInit 后的初始化 | ✅ 完成 | 2026-02-09 |
| 2.1 | VMStructs 设计与推断方法 | ✅ 完成 | 2026-02-09 |
| 2.2 | 关键偏移量清单 | ✅ 完成 | 2026-02-09 |
| 2.3 | VMKlass/VMMethod/NMethod 包装类 | ✅ 完成 | 2026-02-09 |
| 3.1 | Engine 基类 + 引擎选择 | ✅ 完成 | 2026-02-09 |
| 3.2 | Profiler 状态机 | ✅ 完成（合并在 3.1 中） | 2026-02-09 |
| 4.1 | perf_event_open 配置 | ✅ 完成 | 2026-02-09 |
| 4.2 | 信号驱动 + ring buffer | ✅ 完成（合并在 4.1 中） | 2026-02-09 |
| 4.3 | CTimer/ITimer fallback | ✅ 完成 | 2026-02-09 |
| 5.1 | recordSample() 总入口 | ✅ 完成 | 2026-02-09 |
| 5.2 | AsyncGetCallTrace 详解 | ✅ 完成 | 2026-02-09 |
| 5.3 | walkFP 栈回溯 | ✅ 完成 | 2026-02-09 |
| 5.4 | walkDwarf 栈回溯 | ✅ 完成 | 2026-02-09 |
| 5.5 | walkVM 栈回溯 | ✅ 完成 | 2026-02-09 |
| 6.1 | WallClock 采样 | ✅ 完成 | 2026-02-09 |
| 7.1 | AllocTracer Trap + ObjectSampler | ✅ 完成（合并在 7.1 中） | 2026-02-09 |
| 7.2 | ObjectSampler JVMTI | ✅ 完成（合并在 7.1 中） | 2026-02-09 |
| 8.1 | LockTracer Java锁 | ✅ 完成（合并在 8.1 中） | 2026-02-09 |
| 8.2 | NativeLockTracer 原生锁 | ✅ 完成（合并在 8.1 中） | 2026-02-09 |
| 9.1 | GOT/PLT Patching | ✅ 完成（合并在 9.1 中） | 2026-02-10 |
| 9.2 | MallocTracer | ✅ 完成（合并在 9.1 中） | 2026-02-10 |
| 9.3 | Instrument 字节码插桩 | ✅ 完成（合并在 9.1 中） | 2026-02-10 |
| 10.1 | ELF 符号解析 | ✅ 完成（合并在 10.1 中） | 2026-02-10 |
| 10.2 | CodeCache + frameName | ✅ 完成（合并在 10.1 中） | 2026-02-10 |
| 11.1 | CallTraceStorage | ✅ 完成（合并在 11.1 中） | 2026-02-10 |
| 11.2 | FlightRecorder JFR | ✅ 完成（合并在 11.1 中） | 2026-02-10 |
| 11.3 | FlameGraph 输出 | ✅ 完成（合并在 11.1 中） | 2026-02-10 |
| 12.1 | 完整流程串联 | ✅ 完成 | 2026-02-10 |
| 12.2 | 三者对比 | ✅ 完成 | 2026-02-10 |
| 12.3 | 面试专题 | ✅ 完成 | 2026-02-10 |

---

## 推荐学习顺序

```
第 1 周: 基础设施（6 节）
  1.1 → 1.2 → 1.3 → 2.1 → 2.2 → 2.3

第 2 周: CPU 采样核心（7 节，最重要）
  3.1 → 3.2 → 4.1 → 4.2 → 5.1 → 5.2 → 5.3

第 3 周: 栈回溯 + 各种追踪器（9 节）
  5.4 → 5.5 → 4.3 → 6.1 → 7.1 → 7.2 → 8.1 → 8.2 → 9.1

第 4 周: 符号/输出/总结（9 节）
  9.2 → 9.3 → 10.1 → 10.2 → 11.1 → 11.2 → 11.3 → 12.1 → 12.2 → 12.3
```

---

## 与 JVM 已有知识的交叉引用（不变）

| async-profiler 概念 | 对应已有分析 | 小节 |
|---------------------|-------------|------|
| Agent_OnLoad/OnAttach | ch17 JVMTI + ch18 Attach | 1.1 |
| JVMTI Capabilities | ch17 JVMTI 事件体系 | 1.2 |
| VMStructs 偏移量 | 所有 JVM 数据结构分析 | 2.1-2.3 |
| perf_event_open | Linux 性能工具（新） | 4.1-4.2 |
| AsyncGetCallTrace | Safepoint ch01-03 / forte.cpp | 5.2 |
| 栈帧结构 | 解释器帧/JIT帧/JavaCalls | 5.3-5.5 |
| JavaFrameAnchor | ch08 JavaCalls 框架 | 5.5 |
| TLAB/对象分配 | ch02 对象分配 / 3.3 TLAB | 7.1 |
| ObjectMonitor | ch03 锁优化 | 8.1 |
| GOT/PLT | 新知识 | 9.1 |
| DWARF CFI | 新知识 | 5.4, 10.1 |
| JFR 格式 | 新知识 | 11.2 |

---

*创建日期: 2026-02-09*
*预计总工时: 4 周（每天 2-3 小时）*
*每小节预计: 1-3 小时分析 + 编写*