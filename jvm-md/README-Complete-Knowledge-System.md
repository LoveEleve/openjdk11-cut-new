# JVM 源码深度分析 - 完整知识体系大纲

> **最后更新**：2025年2月  
> **文档总数**：100+ 篇专家级分析  
> **覆盖范围**：OpenJDK 11 HotSpot JVM 全栈  
> **核心价值**：从 JVM 启动到 GC、从线程到编译器、从源码到实战

---

## 📚 知识体系统计

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         文档统计概览                                     │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  总文档数: 100+ 篇                                                       │
│  总字数: ~1,500,000+ 字                                                  │
│  代码行数覆盖: ~50,000+ 行                                               │
│  GDB 脚本: 30+ 个                                                        │
│                                                                         │
│  六大核心领域:                                                           │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  1. JVM 启动流程        20+ 篇    30%                          │   │
│  │  2. G1 垃圾回收器       50+ 篇    40%                          │   │
│  │  3. 类加载系统          10+ 篇    10%                          │   │
│  │  4. 编译器系统           5+ 篇     5%                          │   │
│  │  5. 并发与数据结构       5+ 篇     5%                          │   │
│  │  6. 性能分析工具        25+ 篇    10%                          │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 一、JVM 启动流程（20+ 篇）

### 1.1 整体架构

| 文档 | 路径 | 核心内容 |
|------|------|----------|
| **create_vm 完整大纲** | `create_vm_outline.md` | Threads::create_vm() 8 阶段全流程 |
| **init_globals 大纲** | `init_globals_outline.md` | 19 个核心模块初始化 |

### 1.2 Phase 2: 全局数据结构初始化

| 文档 | 路径 | 核心内容 |
|------|------|----------|
| **os::init_2() 分析** | `Phase2/2.1_os_init_2_analysis.md` | 信号/内存/线程初始化 |
| **vm_init_globals() 分析** | `Phase2/2.2_vm_init_globals_analysis.md` | 全局管理器初始化 |
| **SafepointMechanism 分析** | `Safepoint/SafepointMechanism.md` | 安全点机制、Polling Page |

### 1.3 Phase 3: 主线程创建

| 文档 | 路径 | 核心内容 |
|------|------|----------|
| **JavaThread 与 OSThread** | `Phase3/3.1_JavaThread_OSThread_analysis.md` | 线程对象关系 |
| **线程状态分析** | `Phase3/3.2_thread_state_analysis.md` | 状态机转换 |
| **栈信息与保护页** | `Phase3/3.4_3.7_stack_analysis.md` | 栈溢出保护 |
| **JNI Handle 分配** | `Phase3/3.5_jni_handle_analysis.md` | 本地句柄 |
| **ObjectMonitor 机制** | `Phase3/3.8_objectmonitor_analysis.md` | 同步子系统 |

### 1.4 Phase 4: 核心模块初始化

| 文档 | 路径 | 核心内容 |
|------|------|----------|
| **Universe 初始化** | `Universe/universe_init.md` | 堆初始化、基础类型 |
| **create_heap 深度分析** | `Universe/3.1-create_heap.md` | 堆内存创建 |
| **CodeCache 初始化** | `CodeCache/codeCache_init.md` | JIT 代码缓存 |
| **CompileBroker 初始化** | `CompileBroker/compileBroker_init.md` | 编译器线程 |
| **StubQueue 布局** | `Interpreter/1.0-StubQueue-Layout.md` | 桩代码队列 |
| **InlineCacheBuffer 初始化** | `InlineCacheBuffer/InlineCacheBuffer_init.md` | 内联缓存 |
| **Bytecodes 初始化** | `Bytecodes/bytecodes_init.md` | 字节码表 |

### 1.5 Phase 5-8: 服务线程与收尾

| 文档 | 路径 | 核心内容 |
|------|------|----------|
| **VMThread 创建** | `VMThread/VMThread.md` | VM 核心后台线程 |
| **AttachListener 分析** | `AttachListener/AttachListener-Analysis.md` | Attach 机制 |
| **ServiceThread 分析** | `ServiceThread/ServiceThread-Analysis.md` | 服务线程 |
| **WatcherThread 分析** | `WatcherThread/WatcherThread-Analysis.md` | 看门狗线程 |
| **ReferenceHandler/Finalizer** | `ReferenceHandler/ReferenceHandler-Finalizer-Analysis.md` | 引用处理 |
| **System 三阶段初始化** | `SystemInit/System_initPhases.md` | initPhase1/2/3 |
| **Handshake 机制** | `Handshake/Handshake.md` | 握手协议 |

---

## 二、G1 垃圾回收器（50+ 篇）⭐ 核心领域

### 2.1 G1 整体架构

| 文档 | 路径 | 核心内容 |
|------|------|----------|
| **G1CollectedHeap 初始化** | `G1CollectedHeap/G1CollectedHeap-initialize-Expert-Analysis.md` | 6 大数据结构映射器 |
| **HeapRegionManager 初始化** | `G1CollectedHeap/HeapRegionManager-initialize-Expert-Analysis.md` | Region 管理器 |
| **Young GC 流程** | `G1CollectedHeap/Young-GC-Flow-Comprehensive.md` | 年轻代回收全流程 |
| **Mixed GC 流程** | `G1CollectedHeap/Mixed-GC-Flow-Comprehensive.md` | 混合回收流程 |
| **G1 Full GC 机制** | `G1CollectedHeap/G1-Full-GC-Mechanism.md` | Full GC 原理 |

### 2.2 并发标记系统

| 文档 | 路径 | 核心内容 |
|------|------|----------|
| **G1ConcurrentMark 概览** | `G1CollectedHeap/G1ConcurrentMark-Overview.md` | 并发标记架构 |
| **Initial Mark Phase** | `G1CollectedHeap/Initial-Mark-Phase-Expert-Analysis.md` | 初始标记 |
| **Concurrent Mark Phase** | `G1CollectedHeap/Concurrent-Mark-Phase-Expert-Analysis.md` | 并发标记 |
| **Remark Phase** | `G1CollectedHeap/Remark-Phase-Expert-Analysis.md` | 再标记 |
| **Cleanup Phase** | `G1CollectedHeap/Cleanup-Phase-Expert-Analysis.md` | 清理阶段 |
| **G1CMBitMap 分析** | `G1CollectedHeap/G1CMBitMap-Expert-Analysis.md` | 标记位图 |
| **G1CMMarkStack 分析** | `G1CollectedHeap/G1CMMarkStack-Expert-Analysis.md` | 标记栈 |
| **G1CMTask 分析** | `G1CollectedHeap/G1CMTask-Expert-Analysis.md` | 标记任务 |
| **G1ConcurrentMarkThread** | `G1CollectedHeap/G1ConcurrentMarkThread-Expert-Analysis.md` | 标记线程 |
| **SATBMarkQueue** | `G1CollectedHeap/G1SATBMarkQueue-Expert-Analysis.md` | SATB 队列 |

### 2.3 记忆集与屏障

| 文档 | 路径 | 核心内容 |
|------|------|----------|
| **G1RemSet 分析** | `G1CollectedHeap/G1RemSet-Expert-Analysis.md` | 记忆集 |
| **G1CardTable 分析** | `G1CollectedHeap/G1CardTable-Expert-Analysis.md` | 卡表 |
| **DirtyCardQueue** | `G1CollectedHeap/DirtyCardQueue-Expert-Analysis.md` | 脏卡队列 |
| **G1HotCardCache** | `G1CollectedHeap/G1HotCardCache-Expert-Analysis.md` | 热卡缓存 |
| **G1UpdateRemSetClosure** | `G1CollectedHeap/G1UpdateRemSetClosure-Expert-Analysis.md` | RSet 更新 |
| **PerRegionTable 深度分析** | `G1-GC/8.1_PerRegionTable_and_OtherRegionsTable_deep_dive.md` | PRT/ORT |
| **G1 Barrier JIT 版本** | `G1-GC/8.7_G1_Barrier_JIT_Version.md` | JIT 屏障优化 |
| **CardTable 与 WriteBarrier** | `G1-GC/8.4_CardTable_and_WriteBarrier_deep_dive.md` | 写屏障深度分析 |

### 2.4 回收与复制

| 文档 | 路径 | 核心内容 |
|------|------|----------|
| **G1ParScanThreadState** | `G1CollectedHeap/G1ParScanThreadState-Expert-Analysis.md` | 并行扫描状态 |
| **G1ParEvacuateFollowersClosure** | `G1CollectedHeap/G1ParEvacuateFollowersClosure-Expert-Analysis.md` | 疏散闭包 |
| **G1PLAB 分析** | `G1CollectedHeap/G1PLAB-Expert-Analysis.md` | 晋升本地分配缓冲区 |
| **G1AllocRegion** | `G1CollectedHeap/G1AllocRegion-Expert-Analysis.md` | 分配 Region |
| **G1PostEvacuateCleanup** | `G1CollectedHeap/G1PostEvacuateCleanup-Expert-Analysis.md` | 疏散后清理 |
| **G1RedirtyCardsClosure** | `G1CollectedHeap/G1RedirtyCardsClosure-Expert-Analysis.md` | 重脏卡 |
| **RefToScanQueue** | `G1CollectedHeap/RefToScanQueue-Expert-Analysis.md` | 引用扫描队列 |

### 2.5 策略与预测

| 文档 | 路径 | 核心内容 |
|------|------|----------|
| **G1Policy 分析** | `G1CollectedHeap/G1Policy-Expert-Analysis.md` | GC 策略决策 |
| **G1Analytics 分析** | `G1CollectedHeap/G1Analytics-Expert-Analysis.md` | 统计分析 |
| **G1Predictions 分析** | `G1CollectedHeap/G1Predictions-Expert-Analysis.md` | 预测模型 |
| **G1CollectionSet** | `G1CollectedHeap/G1CollectionSet-Expert-Analysis.md` | CSet 管理 |
| **CollectionSetChooser** | `G1CollectedHeap/CollectionSetChooser-Expert-Analysis.md` | CSet 选择器 |
| **Mixed GC CSet 选择** | `G1CollectedHeap/Mixed-GC-CSet-Selection.md` | 混合回收 CSet |
| **IHOP 分析** | `G1CollectedHeap/IHOP-Expert-Analysis.md` | 并发标记触发阈值 |
| **G1MMUTracker** | `G1CollectedHeap/G1MMUTracker-Expert-Analysis.md` | GC 时间跟踪 |
| **G1GCPhaseTimes** | `G1CollectedHeap/G1GCPhaseTimes-Expert-Analysis.md` | GC 阶段时间 |

### 2.6 并发优化与辅助

| 文档 | 路径 | 核心内容 |
|------|------|----------|
| **G1ConcurrentRefine** | `G1CollectedHeap/G1ConcurrentRefine-Expert-Analysis.md` | 并发细化 |
| **G1ConcurrentRefineThread** | `G1CollectedHeap/G1ConcurrentRefineThread-Expert-Analysis.md` | 细化线程 |
| **G1StringDedup** | `G1CollectedHeap/G1StringDedup-Expert-Analysis.md` | 字符串去重 |
| **G1MonitoringSupport** | `G1CollectedHeap/G1MonitoringSupport-Expert-Analysis.md` | 监控支持 |
| **G1RegionMarkStats** | `G1CollectedHeap/G1RegionMarkStats-Expert-Analysis.md` | Region 标记统计 |
| **G1EvacuationInfo** | `G1CollectedHeap/G1EvacuationInfo-Expert-Analysis.md` | 疏散信息 |
| **WorkGang** | `G1CollectedHeap/WorkGang-Expert-Analysis.md` | 工作线程组 |
| **G1RootProcessor** | `G1CollectedHeap/G1RootProcessor-Expert-Analysis.md` | 根处理 |
| **G1RootClosures** | `G1CollectedHeap/G1RootClosures-Expert-Analysis.md` | 根闭包 |
| **HeapRegion 分析** | `G1CollectedHeap/HeapRegion-Expert-Analysis.md` | Region 详情 |

### 2.7 G1 调优实战

| 文档 | 路径 | 核心内容 |
|------|------|----------|
| **G1 Tuning 基础** | `G1-GC/7.1_G1_Tuning_Basic_and_YoungGen.md` | 基础调优 |
| **Mixed GC 调优** | `G1-GC/7.2_G1_Tuning_Mixed_GC.md` | 混合回收调优 |
| **RSet 与 Refine 调优** | `G1-GC/7.3_G1_Tuning_RSet_and_Refine.md` | 记忆集调优 |
| **Concurrent Mark 调优** | `G1-GC/7.4_G1_Tuning_Concurrent_Mark.md` | 并发标记调优 |
| **Special Scenarios** | `G1-GC/7.5_G1_Tuning_Special_Scenarios.md` | 特殊场景 |
| **Diagnostics** | `G1-GC/7.6_G1_Tuning_Diagnostics.md` | 诊断方法 |
| **Practical Cases** | `G1-GC/7.7_G1_Tuning_Practical_Cases.md` | 实战案例 |
| **G1 GC Log 完全指南** | `G1-GC/9.0_G1_GC_Log_Complete_Guide.md` | 日志分析 |
| **Humongous 对象完整分析** | `G1-GC/ch48_humongous_complete.md` | 大对象处理 |
| **RememberedSet 基础** | `G1-GC/6.1_RememberedSet_Basic_Concepts.md` | RSet 基础 |
| **Full GC 详细分析** | `G1-GC/5_Full_GC_detailed_analysis.md` | Full GC |
| **Young GC 完整流程** | `G1-GC/8.3_Young_GC_Complete_Flow.md` | 年轻代完整流程 |
| **Mixed GC 完整流程** | `G1-GC/8.5_Mixed_GC_Complete_Flow.md` | 混合回收完整流程 |
| **G1Policy 决策逻辑** | `G1-GC/8.6_G1Policy_Decision_Logic.md` | 策略决策 |
| **Young GC 学习路线** | `G1CollectedHeap/Young-GC-Learning-Roadmap.md` | 学习路线 |
| **Mixed GC 学习路线** | `G1CollectedHeap/Mixed-GC-Learning-Roadmap.md` | 学习路线 |
| **G1 Tuning 参数大纲** | `G1-GC/G1_Tuning_Parameters_Outline.md` | 参数速查 |

---

## 三、类加载系统（10+ 篇）

| 文档 | 路径 | 核心内容 |
|------|------|----------|
| **类加载完整流程** | `ClassLoading/classloading_complete_flow.md` | 全流程分析 |
| **类加载器层次** | `ClassLoading/ch06_classloader_hierarchy.md` | Bootstrap/Ext/App |
| **双亲委派与 loadClass** | `ClassLoading/ch07_parent_delegation_loadclass.md` | 委派机制 |
| **defineClass JNI 桥接** | `ClassLoading/ch08_defineclass_jni_bridge.md` | native 桥接 |
| **类链接与初始化** | `ClassLoading/class_linking_initialization.md` | 链接初始化 |
| **ClassFileParser** | `ClassLoading/classfile_parser.md` | 类文件解析 |
| **Klass 层次结构** | `ClassLoading/klass_hierarchy.md` | Klass 对象模型 |
| **SystemDictionary 深度分析** | `ClassLoading/system_dictionary_deep_dive.md` | 系统字典 |
| **类加载面试与 GDB** | `ClassLoading/ch09_classloading_interview_gdb.md` | 面试实战 |

---

## 四、编译器系统（5+ 篇）

| 文档 | 路径 | 核心内容 |
|------|------|----------|
| **C1 编译管线与优化** | `C1Compiler/c1_compilation_pipeline.md` | C1 编译器 |
| **C2 编译管线与优化** | `C2Compiler/ch01_c2_compilation_pipeline_and_optimizations.md` | C2 编译器 |
| **逃逸分析** | `C2Compiler/escape_analysis.md` | 逃逸分析优化 |

---

## 五、并发与数据结构（5+ 篇）

| 文档 | 路径 | 核心内容 |
|------|------|----------|
| **ConcurrentHashTable 架构** | `ConcurrentHashTable/ConcurrentHashTable-Architecture.md` | 整体架构 |
| **ConcurrentHashTable 核心算法** | `ConcurrentHashTable/ConcurrentHashTable-Core-Algorithms.md` | 算法实现 |
| **ConcurrentHashTable 性能** | `ConcurrentHashTable/ConcurrentHashTable-Performance.md` | 性能分析 |
| **StringTable 专家分析** | `StringTable-Expert-Analysis.md` | 字符串表 |

---

## 六、性能分析工具（25+ 篇）⭐ 实战领域

### 6.1 Arthas 源码分析

| 文档 | 路径 | 核心内容 |
|------|------|----------|
| **Arthas 大纲** | `Arthas/arthas_outline.md` | 整体架构 |
| **Boot 与 Attach** | `Arthas/ch01_1_boot_and_attach.md` | 启动流程 |
| **Agent Bootstrap** | `Arthas/ch01_2_agent_bootstrap.md` | Agent 加载 |
| **Arthas Bootstrap** | `Arthas/ch01_3_arthas_bootstrap.md` | 核心启动 |
| **Arthas ClassLoader** | `Arthas/ch02_1_arthas_classloader.md` | 类加载器 |
| **Spy 机制** | `Arthas/ch02_2_spy_mechanism.md` | Spy 技术 |
| **字节码增强引擎** | `Arthas/ch05_bytecode_enhancement_engine.md` | Instrument |
| **OGNL 表达式引擎** | `Arthas/ch06_ognl_expression_engine.md` | OGNL |
| **Watch/Trace/Monitor/Stack** | `Arthas/ch07_watch_trace_monitor_stack.md` | 核心命令 |
| **TimeTunnel** | `Arthas/ch08_time_tunnel.md` | tt 命令 |
| **Jad/Redefine/Retransform** | `Arthas/ch09_jad_redefine_retransform.md` | 热更新 |
| **系统诊断命令** | `Arthas/ch10_system_diagnostic_commands.md` | 系统命令 |
| **VMTool JVMTI** | `Arthas/ch11_vmtool_jvmti.md` | JVMTI 工具 |
| **Profiler 命令** | `Arthas/ch12_profiler_command.md` | 性能分析 |
| **Memory Compiler** | `Arthas/ch13_memory_compiler_and_others.md` | 内存编译器 |
| **Spring Boot Starter** | `Arthas/ch14_spring_boot_starter.md` | Spring 集成 |

### 6.2 Async-Profiler 源码分析

| 文档 | 路径 | 核心内容 |
|------|------|----------|
| **Async-Profiler 大纲 v2** | `AsyncProfiler/async_profiler_outline_v2.md` | 新大纲 |
| **Agent 加载路径** | `AsyncProfiler/ch01_1_agent_load_path.md` | 加载流程 |
| **JVMTI Env 设置** | `AsyncProfiler/ch01_2_jvmti_env_setup.md` | JVMTI |
| **VMInit 与 Ready** | `AsyncProfiler/ch01_3_vminit_and_ready.md` | 初始化 |
| **VMStructs 概览** | `AsyncProfiler/ch02_1_vmstructs_overview.md` | VMStructs |
| **关键偏移量** | `AsyncProfiler/ch02_2_key_offsets.md` | 偏移计算 |
| **包装类** | `AsyncProfiler/ch02_3_wrapper_classes.md` | Wrapper |
| **引擎层次** | `AsyncProfiler/ch03_1_engine_hierarchy.md` | 引擎架构 |
| **PerfEventOpen** | `AsyncProfiler/ch04_1_perf_event_open.md` | perf_event |
| **CTimer/ITimer Fallback** | `AsyncProfiler/ch04_3_ctimer_itimer_fallback.md` | 回退机制 |
| **Record Sample** | `AsyncProfiler/ch05_1_record_sample.md` | 采样记录 |
| **AsyncGetCallTrace** | `AsyncProfiler/ch05_2_async_get_call_trace.md` | 栈回溯 |
| **Walk FP** | `AsyncProfiler/ch05_3_walk_fp.md` | 帧指针遍历 |
| **Walk DWARF** | `AsyncProfiler/ch05_4_walk_dwarf.md` | DWARF 遍历 |
| **Walk VM** | `AsyncProfiler/ch05_5_walk_vm.md` | VM 遍历 |
| **Wall Clock** | `AsyncProfiler/ch06_1_wall_clock.md` | 墙钟模式 |
| **Alloc Tracer** | `AsyncProfiler/ch07_1_alloc_tracer.md` | 分配追踪 |
| **Lock Tracer** | `AsyncProfiler/ch08_lock_tracer.md` | 锁追踪 |
| **Hooks Malloc Instrument** | `AsyncProfiler/ch09_hooks_malloc_instrument.md` | Hook 机制 |
| **Symbols CodeCache FrameName** | `AsyncProfiler/ch10_symbols_codecache_framename.md` | 符号解析 |
| **Storage JFR FlameGraph** | `AsyncProfiler/ch11_storage_jfr_flamegraph.md` | 存储格式 |
| **Complete Flow** | `AsyncProfiler/ch12_1_complete_flow.md` | 完整流程 |
| **Comparison** | `AsyncProfiler/ch12_2_comparison.md` | 对比分析 |
| **Interview** | `AsyncProfiler/ch12_3_interview.md` | 面试题 |
| **使用指南 Part1** | `AsyncProfiler/async_profiler_usage_guide_part1.md` | 使用指南 |
| **使用指南 Part2** | `AsyncProfiler/async_profiler_usage_guide_part2.md` | 使用指南 |
| **使用指南 Part3** | `AsyncProfiler/async_profiler_usage_guide_part3.md` | 使用指南 |

---

## 七、JVM 原生库研究（新领域）

| 文档 | 路径 | 核心内容 |
|------|------|----------|
| **JVM 原生库路线图** | `JVM-Native-Libraries/JVM-Native-Libraries-Roadmap.md` | 13+ so 库全景 |

### 待分析原生库：

| 库名 | 重要度 | 说明 |
|------|--------|------|
| libjvm.so (JVMTI/VMStructs) | ⭐⭐⭐⭐⭐ | 核心引擎深入 |
| libjsig.so | ⭐⭐⭐⭐ | 信号链机制 |
| libattach.so (JDK) | ⭐⭐⭐⭐ | Attach 工具库 |
| libjava.so | ⭐⭐⭐⭐ | Java 基础 native |
| libnio.so | ⭐⭐⭐⭐ | NIO/DirectBuffer |
| libnet.so | ⭐⭐⭐ | 网络编程 |
| libzip.so | ⭐⭐⭐ | 压缩库 |
| libmanagement.so | ⭐⭐⭐ | JMX 管理 |
| libjli.so | ⭐⭐⭐ | Java 启动器 |
| libinstrument.so | ⭐⭐⭐ | Java Agent |

---

## 八、辅助文档与工具

| 文档 | 路径 | 用途 |
|------|------|------|
| **GDB 验证报告** | `G1CollectedHeap/GDB-Verification-Report.md` | GDB 调试记录 |
| **我的构建笔记** | `my_build.md` | 编译配置 |
| **职业差距分析** | `career/perfma_gap_analysis.md` | 职业发展 |
| **AI 提示词** | `AI提示词.md` | 辅助提示 |

---

## 学习路径建议

### 路径一：JVM 启动流程（基础）
```
create_vm_outline.md
  ├── Phase 2: SafepointMechanism → os::init_2
  ├── Phase 3: JavaThread/OSThread → ObjectMonitor
  ├── Phase 4: Universe_init → init_globals
  ├── Phase 5: VMThread
  ├── Phase 7: AttachListener → ServiceThread
  └── Phase 8: WatcherThread → ReferenceHandler
```

### 路径二：G1 GC 专家（核心）
```
G1CollectedHeap/G1CollectedHeap-initialize-Expert-Analysis.md
  ├── G1Policy → G1Analytics → IHOP
  ├── Young-GC-Flow → G1ParScanThreadState
  ├── Concurrent-Mark → G1CMTask → G1CMBitMap
  ├── G1RemSet → G1CardTable → DirtyCardQueue
  └── Mixed-GC → CSet-Selection → Humongous
```

### 路径三：性能分析工具（实战）
```
AsyncProfiler/async_profiler_outline_v2.md
  ├── Agent 加载 → JVMTI → VMStructs
  ├── PerfEventOpen → AsyncGetCallTrace
  ├── Walk FP/DWARF/VM → 栈回溯
  └── Storage JFR → FlameGraph

Arthas/arthas_outline.md
  ├── Attach → Agent Bootstrap
  ├── Bytecode Enhancement → OGNL
  └── Watch/Trace/Profiler 命令
```

---

## 统计信息

```
文档总数: 100+
总字数: 1,500,000+
代码行数: 50,000+
GDB 脚本: 30+
面试题: 200+
图示: 50+
```

---

**最后更新**: 2025年2月  
**维护者**: JVM 源码分析助手  
**目标**: 打造最完整的 OpenJDK 11 中文学习资料库
