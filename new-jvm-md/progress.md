# JVM 源码分析进度

> 最后更新：2026-03-02

---

## AsyncProfiler 文档翻新进度

### 四项改进任务（2026-03-02 全部完成）

| 优先级 | 任务 | 状态 | 说明 |
|--------|------|------|------|
| P1 | 补 GDB 验证 | ✅ 完成 | 10 篇 Deep Dive 文档全部有 GDB 验证 |
| P2 | 清理重复 | ✅ 完成 | 7 篇 Review Day 文件从 ~900-1280 行精简为 ~420-580 行"复习卡片"格式 |
| P3 | 补数据结构关系图 | ✅ 完成 | 10 篇 Deep Dive 文档全部有 Mermaid 关系图 |
| P4 | 统一质量标准 | ✅ 完成 | 10 篇 Deep Dive 算法描述全部达到 L4+（真实源码+逐行注释+设计解释） |

### 综合审计结果（2026-03-02）

- 26 个 .md 文件全部检查完毕
- 7 篇 Review Day 文件：全部已转为"复习卡片"格式（知识索引 + 面试问答 + 自测题）
- 10 篇 Deep Dive 文档（05-14）：全部 L4+ 质量，其中 08/12/13 达到 L5
- 4 篇辅助文档（Complete-Guide/Review-Plan/Review-Plan-Summary/Checklist）：已清除模板样板
- Review-Plan-Summary.md：统计数据已更新为实际行数

### 翻新详情

| 章节 | 状态 | 说明 |
|------|------|------|
| Chapter 01 | ✅ 翻新完成 | Safepoint Bias 问题 |
| Chapter 02 | ✅ 翻新完成 | AsyncGetCallTrace 解决方案 |
| Chapter 03 | ✅ 翻新完成（2026-03-02） | 四种栈回溯方法深度对比。修复 10 项问题：虚构 GDB 数据、不存在的方法（StackFrame::pop/DwarfParser::unwind）、不完整数据结构、ASCII 图替换 Mermaid、补充 Part 0、补充 FrameDesc/StackContext 分析、修正勘误表 |
| Chapter 04 Part 0 | ✅ 修复（2026-03-02） | 移除 ASCII 框图 |
| Chapter 05 Part 0 | ✅ 修复（2026-03-02） | 移除堆砌的 ASCII 图/对比表格/量化数据，改为精炼文字说明 |
| Chapter 06 Part 0 | ✅ 修复（2026-03-02） | 移除堆砌的 ASCII 场景列表/对比表格，改为精炼文字说明 |
| Chapter 07 Part 0 | ✅ 修复（2026-03-02） | 移除 ASCII 架构图，改为精炼文字说明 |
| Chapter 08 | ✅ Part 0 已符合规范 | Profiler 核心控制器 |

### 翻新记录

| 章节 | 状态 | 说明 |
|------|------|------|
| Chapter 04 全文翻新 | ✅ 完成（2026-03-02） | 修复 11 项严重 bug：VMStructEntry 字段数错误(4→6)、sizeof 错误(32→48)、readSymbol 实现错误(dlsym→CodeCache ELF)、捏造三种推断方法(实际只有一种)、捏造函数(inferThreadOffsets/validateThreadOffset/inferFromInterpreter)、捏造 GDB/性能数据、遗漏 3 张符号表 |
| Chapter 05 全文翻新 | ✅ 完成（2026-03-02） | 修复 15 项严重 bug：PerfEventType 字段数错误(6→7)、事件名错误(cpu→cpu-clock)、PerfEvents 字段遗漏(5→15)、CONCURRENCY_LEVEL 错误(64→16)、getLockIndex 算法错误(简单取模→XOR哈希)、_ioc_enable 默认值错误(ENABLE→REFRESH)、start() 源码 20+ 不符、RingBuffer 类缺失、性能/GDB/strace 数据捏造、CTimer/ITimer 伪代码、ASCII 图、recordSample 行号错误 |
| Chapter 06 全文翻新 | ✅ 完成（2026-03-02） | 修复 14 项问题：AllocTracer.type()返回值错误、AllocEvent继承链/布局错误、Trap字段表不完整(4→6)、ObjectSampler字段遗漏、LiveRefs类完全缺失、stop()不完整、DEFAULT_ALLOC_INTERVAL未提及、GDB数据捏造、StackFrame文件名错误、ASCII图、lookupClassId缺失 |
| Chapter 07 全文翻新 | ✅ 完成（2026-03-02） | 修复 19 项问题：NativeLockTracer完全缺失、NativeLockEvent缺失、"双路径"→三路径、DEFAULT_LOCK_INTERVAL未提及、while(_enabled)误描述为循环、setUnsafeParkEntry/setEntry0/getParkBlocker/getLockName未分析、性能数字无源、GDB验证捏造、ASCII图、ImportId/patchImport机制缺失、dlopen hook缺失、Profiler引擎注册缺失、RegisterNativesHook返回0原因未解释 |
| Chapter 09 全文翻新 | ✅ 完成（2026-03-02） | 修复 19 项问题：LongHashTable _padding0 大小错误(void* 8B 误写 56B)、内存布局偏移全错(_capacity偏移16非64、_size偏移80非128)、sizeof(LongHashTable)错误(144非192)、子节编号错误(1.6→1.8)、缺失 add()/resetCounters()/collectTraces()/collectSamples()×2/clear() 函数分析、calcHash()尾部分支未说明、_overflow_trace具体值未分析、reserve触发条件不精确、memcpy不可用原因不准确、Mermaid标记缺失、性能数字无源、safeAlloc实现未说明、findCallTrace()读取语义未解释、FRAME_CPP注释不精确 |
| Chapter 10 全文翻新 | ✅ 完成（2026-03-02） | 修复 19 项问题：_imports[35][2]→[14][2](NUM_IMPORTS=14非35)、sizeof(CodeCache)估算664B→实际320B(_imports=224B)、关系图_imports维度错误、总结内存占用错误、name()实现严重偏离源码(伪造bci<0判断/用find非lower_bound)、BCI_LIVE_OBJECT误入switch、BCI_ALLOC/LOCK误称resolveClassName(实为_class_names查找)、缓存插入未用hint-based insert、BCI_ERROR未包裹方括号、BCI_CPU未说明0x7fff掩码、needsDemangling判断条件不完整、性能数字无源×3、_saved_locale生命周期未分析、sizeof偏差原因敷衍、GDB脚本_imports维度错误、findSymbolByPrefix dot逻辑缺失、JMethodCache用伪代码描述 |
| Chapter 11 全文翻新 | ✅ 完成（2026-03-02） | 修复 23 项问题：recordEvent()只列7种事件(实际13种)、缺失switch后flushIfNeeded+addThread、FlightRecorder.h字段不完整、缺start()/stop()/flush()分析、Recording sizeof从~1.13MB修正为1,168,128B(≈1.11MB)、_thread_set从~100B修正为~32KB、_process_sampler从~100B修正为~20KB、_chunk_size最小约束262144未提及、_chunk_time最小约束5s未提及、putVar64()循环展开优化未分析、putVar32固定5字节版本未分析、putByteString()/putFloat()未分析、全局静态变量(_rec_lock初始值=1)未分析、recordLog()+alloca未分析、timerTick()/finishChunk()/writePoolHeader()/JFR Sync机制未分析 |
| Chapter 12 全文翻新 | ✅ 完成（2026-03-02） | 修复 23 项问题：sizeof估算错误(32B→24B)且遗漏vtable ptr、WALL_LEGACY触发条件编造_wall_interval(实为_nobatch)、数据结构清单仅4项(应11项)、缺Engine/WallClockEvent/ExecutionEvent/ThreadState/ThreadList/全局常量、缺start()/stop()函数分析、trace复合编码(tid<<32\|trace_id)误称"call_trace_id"、drain() CAS/counter=0/内存序协议未分析、getThreadState页面边界保护未解释、getProfilingSignal(1) mode含义未解释、Part 0堆砌场景、缺problem-driven-design问题推导 |
| Chapter 13 全文翻新 | ✅ 完成（2026-03-02） | 修复 29 项问题：addChild() switch 误描述为更新父节点计数(实为获取JIT_COMPILED子节点+提前return)、_self设置位置错误、FlameGraph sizeof偏移计算错误(_minwidth需8字节对齐)、GDB输出疑似伪造、Part 0堆砌场景列表、缺失 printFrame() f/u/n 增量编码分析、缺失 printCpool() 前缀压缩算法(prefix_len+32编码/上限95/UTF-8安全)、缺失 dump()/printTreeFrame()/printTill()/dumpFlameGraph()/dumpCollapsed() 完整源码分析、缺失 INCBIN 机制/Writer类体系/StringUtils/Format 分析、缺失 type() 动态帧类型判定(阈值1/3和1/2)、缺失 depth() 双重作用分析、缺失叶节点 _total/_self 双累加、缺失 flame.html JS 解码函数、缺失 _mintotal/MAX_CANVAS_HEIGHT、缺失问题驱动推导 |
| Chapter 14 全文翻新 | ✅ 完成（2026-03-02） | 修复 32 项严重 bug：dumpCollapsed 行号/源码全部错误(1368→1487、buf[4096]指针→FrameName+Writer流式)、dumpText 行号/源码全部错误(1425→1580、伪造FrameStats→实际三阶段:summary+traces+flat)、dumpOtlp 零分析(补完Recorder/ProtoBuffer/Index/SampleInfo完整体系)、FrameName 14字段→几行伪代码、BCI_WALL=-13编造(实为BCI_LIVE_OBJECT)、缺失5个BCI值、FrameName::get()伪造Method::name/CodeCache::find(实为JVMTI三步查询)、缺失Output/Style/Matcher/JMethodCache/locale/FrameType/collectSamples两重载/excludeTrace/logEmptyOutput/detectOutputFormat/javaClassName四阶段/type()/typeSuffix()/decodeNativeSymbol/Mermaid图/问题驱动推导 |
| Chapter 15 检查 | ✅ 完成（2026-03-02） | 实战验证报告审查通过：测试程序/profiler命令/输出文件/代码片段全部准确，删除不存在的引用文件和临时脚本路径 |
| 总指南重复 Section 3 | ✅ 修复（2026-03-02） | 删除第一个"补充大纲"Section 3（过时学习路线图），保留第二个实际内容 Section 3 |

---

## 对象模型系列（Week 7，Day 41-）

### 已完成

|| 序号 | 文档 | 状态 |
||------|------|------|
|| Day 41 | [**oop/Klass 架构深度剖析**](./ObjectModel/1-Oop-Klass-Architecture-Deep-Dive.md) | ✅ 完成（~1715 行：9 大数据结构全字段分析 + mark word 位布局 + 压缩指针原理 + 关键字段生命周期 + 值域图 + 对象创建流程源码级分析 + GDB sizeof/offset/常量验证全 ✓）|
|| Day 42 | [**对象分配流程深度分析**](./ObjectModel/2-Object-Allocation-Flow-Deep-Dive.md) | ✅ 完成（~1400 行：10 大数据结构全字段分析 + TLAB 内存布局 + CAS pointer bumping 源码级分析 + TLAB/Eden/堆分配三级路径 + 关键字段生命周期 + 设计决策 + GDB 验证全 ✓）|
|| Day 43 | [**Finalizer 与引用类型全解**](./ObjectModel/3-Finalizer-And-Reference-Types-Deep-Dive.md) | ✅ 完成（~900 行：完整引用分类：Java 层 6 种 + JNI 3 种 + JVM 枚举 + 10 大数据结构 + Finalizer 完整生命周期 + GC 四阶段处理 + ReferenceHandler/FinalizerThread 双线程 + 对象复活机制 + 最佳实践 ✓）|

||| Day 44 | [**ClassLoader 子系统深度剖析**](./ObjectModel/6-ClassLoader-Deep-Dive.md) | ✅ 完成（~2300 行：7 大数据结构全字段分析 + 双亲委派/类加载约束/TCCL 源码级分析 + ClassLoaderData 完整生命周期 + 类卸载机制 + GDB 验证 + JVM 参数全 ✓）|

||| Day 45 | [**反射机制深度剖析**](./ObjectModel/7-Reflection-Deep-Dive.md) | ✅ 完成（~782 行：4 大数据结构全字段分析 + invoke_method 逐行注释 + 7 阶段调用流程 + 性能开销逐项分析 + MethodHandle 对比 + GDB 验证全 ✓）|
||| Day 46 | [**动态代理机制深度剖析**](./ObjectModel/8-DynamicProxy-Deep-Dive.md) | ✅ 完成（~865 行：Proxy/ProxyGenerator/JVM_DefineClass 全字段分析 + 字节码生成流程 + 7 阶段创建流程 + 代理类结构详解 + 性能对比 + GDB 验证全 ✓）|

> **对象模型系列第 6 篇完成，覆盖反射与动态代理机制。**

---

## Threads::create_vm 详细分析（拆分版）

### 已完成

| 序号 | 文档 | 状态 |
|------|------|------|
| 0 | [**全景宏观理解**](./Thread/create_vm/0-Macro-Understanding.md) | ✅ 完成 |
| 1 | [Phase 1: 前置检查](./Thread/create_vm/1-Phase1-Pre-Check.md) | ✅ 完成 |
| 2 | [Phase 2: OS与参数解析](./Thread/create_vm/2-Phase2-OS-Arguments.md) | ✅ 完成 |
| 3 | [Phase 5: 线程创建](./Thread/create_vm/3-Phase5-Thread-Creation.md) | ✅ 完成 |
| 4 | [Phase 6: init_globals](./Thread/create_vm/4-Phase6-init_globals.md) | ✅ 完成 |
| 4A | [**Phase 6: init_globals 数据结构全景**](./Thread/create_vm/4A-init_globals-DataStructure-Map.md) | ✅ 完成 |

| 5 | [**Phase 6: universe_init 深入**](./Thread/create_vm/5-universe_init-Deep-Dive.md) | ✅ 完成 |
| 6 | [**Phase 6: G1CollectedHeap::initialize**](./Thread/create_vm/6-G1CollectedHeap-initialize-Deep-Dive.md) | ✅ 完成 |
| 7 | [**Phase 7: VMThread**](./Thread/create_vm/7-VMThread-Deep-Dive.md) | ✅ 完成 |

| 8 | [**Phase 8: Java 类初始化与 VM 启动完成**](./Thread/create_vm/8-Phase8-Java-Class-Init-And-VM-Completion.md) | ✅ 完成 |

> **Threads::create_vm() 全流程已 100% 覆盖（#0 ~ #8 + 4A~4I，共 18 篇文档）。**

### 待完成

| 序号 | 文档 | 状态 |
|------|------|------|
| - | create_vm 系列已全部完成 | ✅ |

---

## 规范

每篇详细文档要求：
- [x] 宏观理解
- [x] 逐行详细分析
- [x] 核心数据结构
- [x] GDB 验证实验
- [x] 总结

**状态**：持续分析中...

---

## 本次分析产出

1. **文档**：`new-jvm-md/Thread/create_vm-Complete.md`
2. **GDB 脚本**：`new-jvm-md/tmp-file/create_vm_verify.gdb`
3. **验证日志**：`gdb.txt`

---

## 核心调用链

```
JavaMain
  → JNI_CreateJavaVM
    → JNI_CreateJavaVM_inner
      → Threads::create_vm (L3876)
        → vm_init_globals (L4002)
          → init_globals (L4060)
            → universe_init (init.cpp:119)
              → Universe::initialize_heap (universe.cpp:924)
                → G1CollectedHeap::initialize (g1CollectedHeap.cpp:1588)
        → VMThread::create (L4087)
        → initialize_java_lang_classes (L4130)
```

---

## G1 GC 深度攻克系列

### 已完成

| 序号 | 文档 | 状态 |
|------|------|------|
| 0 | [G1 数据结构全景](./G1GC/0-G1-DataStructure-Map.md) | ✅ 完成 |
| 1 | [**HeapRegion 深度剖析**](./G1GC/1-HeapRegion-Deep-Dive.md) | ✅ 完成 |
| 2 | [**HeapRegionManager 深度分析**](./G1GC/2-HeapRegionManager-Deep-Dive.md) | ✅ 完成 |
| 3 | [**对象分配路径**](./G1GC/3-Object-Allocation-Path.md) | ✅ 完成 |
| 4 | [**写屏障 + CardTable**](./G1GC/4-WriteBarrier-CardTable.md) | ✅ 完成 |
| 5 | [**RSet 三级结构**](./G1GC/5-RSet-Three-Level-Structure.md) | ✅ 完成 |
| 6 | [**并发精化 Concurrent Refinement**](./G1GC/6-Concurrent-Refinement.md) | ✅ 完成 |
| 7 | [**G1Policy + 预测模型**](./G1GC/7-G1Policy-Prediction-Model.md) | ✅ 完成 |
| 8 | [**并发标记 Concurrent Marking**](./G1GC/8-Concurrent-Marking.md) | ✅ 完成 |
| 9 | [**G1CollectionSet + 疏散 Evacuation**](./G1GC/9-CollectionSet-Evacuation.md) | ✅ 完成 |

| 10 | [**Full GC 深度剖析**](./G1GC/10-Full-GC.md) | ✅ 完成 |

> 🎉 **G1 GC 深度攻克系列全部 11 篇（#0 ~ #10）已完成！**

### 专家级补完系列（Phase 1-5）

| 序号 | 文档 | 状态 |
|------|------|------|
| 11 | [**Young GC 完整 STW 流程**](./G1GC/11-Young-GC-Complete-STW-Flow.md) | ✅ 完成 |
| 12 | [**G1RemSet 完整流程**](./G1GC/12-G1RemSet-Complete-Flow.md) | ✅ 完成 |
| 增补 #8 | [**并发标记逐行增补**](./G1GC/8A-Concurrent-Marking-Deep-Dive.md) | ✅ 完成 |
| 14 | [**SafePoint + VM Operation**](./G1GC/14-SafePoint-VMOperation.md) | ✅ 完成 |
| 15 | [**引用处理全链路**](./G1GC/15-Reference-Processing-Full-Chain.md) | ✅ 完成 |
| 13 | [**写屏障汇编级全链路**](./G1GC/13-Write-Barrier-Assembly-Full-Chain.md) | ✅ 完成 |
| 16 | [**策略与自适应调整**](./G1GC/16-Strategy-Adaptive-Adjustment.md) | ✅ 完成 |
| 18 | [**GC 日志实战**](./G1GC/18-GC-Log-Practice.md) | ✅ 完成 |
| 17 | [**辅助子系统**](./G1GC/17-Auxiliary-Subsystems.md) | ✅ 完成 |
| 14A | [**SafePoint 深度补充：线程状态转换+信号处理全链路**](./G1GC/14A-SafePoint-Thread-State-Transitions-Deep-Dive.md) | ✅ 完成 |

> 详细计划见 [G1 Expert-Level Plan](./G1GC/G1-Expert-Level-Plan.md)
>
> 🎉 **G1 GC 专家级补完系列全部 9 篇（#11 ~ #18 + 增补 #8 + 增补 #14A）已完成！**
>
> **GC 实战系列**
>
> | 序号 | 文档 | 状态 |
> |------|------|------|
> | 19 | [**GC 问题排查实战深度剖析**](./G1GC/19-GC-Troubleshooting-Deep-Dive.md) | ✅ 完成（~921 行：P0事故案例 + GC日志模式库(正常/异常) + 3种内存泄漏场景详解 + MAT分析实战 + 5个调优案例 + 完整JVM参数模板 + GDB诊断脚本 + 监控体系 + 与G1源码关联分析）|

---

## init_globals 深入探索系列

| 序号 | 文档 | 状态 |
|------|------|------|
| 4B | [**CodeCache + CodeHeap 深度剖析**](./Thread/create_vm/4B-CodeCache-Deep-Dive.md) | ✅ 完成 |
| 4C | [**解释器 + TemplateTable 深度剖析**](./Thread/create_vm/4C-Interpreter-TemplateTable-Deep-Dive.md) | ✅ 完成 |
| 4D | [**StubRoutines 两阶段深度剖析**](./Thread/create_vm/4D-StubRoutines-Two-Phase-Deep-Dive.md) | ✅ 完成 |
| 4E | [**universe2_init (Genesis) 深度剖析**](./Thread/create_vm/4E-universe2_init-Genesis-Deep-Dive.md) | ✅ 完成 |
| 4F | [**universe_post_init 深度剖析**](./Thread/create_vm/4F-universe_post_init-Deep-Dive.md) | ✅ 完成 |
| 4G | [**SharedRuntime Blob 深度剖析**](./Thread/create_vm/4G-SharedRuntime-Blob-Deep-Dive.md) | ✅ 完成 |
| 4H | [**javaClasses_init 深度剖析**](./Thread/create_vm/4H-javaClasses_init-Deep-Dive.md) | ✅ 完成 |
| 4I | [**辅助初始化函数合集**](./Thread/create_vm/4I-Auxiliary-Init-Functions.md) | ✅ 完成 |
| 5A | [**SymbolTable 深度剖析**](./Thread/create_vm/5A-SymbolTable-Deep-Dive.md) | ✅ 完成 |
| 5B | [**StringTable 深度剖析**](./Thread/create_vm/5B-StringTable-Deep-Dive.md) | ✅ 完成 |

> **init_globals() 30 个函数已 100% 覆盖（4A~4I + 5A~5B，共 11 篇文档）。**

---

## C1/C2 编译系统系列（Week 3，Day 15-21）

### 已完成

| 序号 | 文档 | 状态 |
|------|------|------|
| 1 | [**编译触发与热点方法检测**](./Compiler/1-Compilation-Trigger-Hot-Method-Detection.md) | ✅ 完成 |
| 2 | [**CompileBroker — 编译请求分发**](./Compiler/2-CompileBroker-Compilation-Dispatch.md) | ✅ 完成 |
| 3 | [**C1 编译管道 — HIR → LIR → 机器码**](./Compiler/3-C1-Compilation-Pipeline.md) | ✅ 完成 |
| 4 | [**C2 Ideal Graph — Sea-of-Nodes 架构**](./Compiler/4-C2-Ideal-Graph.md) | ✅ 完成 |

| 5 | [**C2 核心优化（逃逸分析、标量替换、内联）**](./Compiler/5-C2-Core-Optimizations.md) | ✅ 完成 |
| 6 | [**OSR（栈上替换）**](./Compiler/6-OSR-On-Stack-Replacement.md) | ✅ 完成 |
| 7 | [**Deoptimization（去优化）**](./Compiler/7-Deoptimization.md) | ✅ 完成 |

> **C1/C2 编译系统系列全部 7 篇（#1 ~ #7）已完成！**

---

## Metaspace + 类加载深化系列（Week 4，Day 22-28）

### 已完成

| 序号 | 文档 | 状态 |
|------|------|------|
| Day 22 | [**Metaspace 整体架构**](./Metaspace/1-Metaspace-Architecture.md) | ✅ 完成 |
| Day 23 | [**ChunkManager + SpaceManager 深度剖析**](./Metaspace/2-ChunkManager-SpaceManager-Deep-Dive.md) | ✅ 完成 |

| Day 24 | [**类卸载机制（ClassLoaderData 生命周期）**](./Metaspace/3-Class-Unloading-Mechanism.md) | ✅ 完成 |

| Day 25 | [**SystemDictionary 深度剖析**](./Metaspace/4-SystemDictionary-Deep-Dive.md) | ✅ 完成（Section 二 源码逐行分析已重写：12 个子节 + 完整真实源码 + 逐行注释，~1251 行；Section 三 数据结构全景已按"程序=数据结构+算法"原则重写：4 层架构 + 完整继承链 + GDB sizeof/offset 验证，~1020 行） |

| Day 26 | [**ConstantPool 深度剖析**](./Metaspace/5-ConstantPool-Deep-Dive.md) | ✅ 完成（三层索引架构 + 6 大解析入口源码逐行分析 + CPCacheEntry 位布局 + Tag 状态机 + GDB sizeof/offset/断点验证，~1400 行） |

| Day 27 | [**Rewriter + 字节码重写深度剖析**](./Metaspace/6-Rewriter-Bytecode-Rewriting.md) | ✅ 完成（Rewriter 六大重写类型 + compute_index_maps/scan_method 两遍扫描 + CPCache 三段式布局 + 字节序转换 + GDB 字节码前后对比验证，~1300 行） |
| Day 28 | [**类加载 GDB 实战串联**](./Metaspace/7-ClassLoading-GDB-Full-Chain.md) | ✅ 完成（13 步完整时序 + 5 大阶段 + 地址一致性验证 + init_state 状态机 + Day 22-27 全部交叉验证 ✓） |

> 🎉 **Metaspace + 类加载深化系列全部 7 篇（Day 22 ~ Day 28）已完成！**

---

## Runtime Resolution 系列（Week 5，Day 29-）

### 已完成

| 序号 | 文档 | 状态 |
|------|------|------|
| Day 29 | [**Runtime Resolution 总览 + 字段解析全链路**](./RuntimeResolve/1-Runtime-Resolution-Field-Resolve.md) | ✅ 完成（resolve_from_cache 分发 + resolve_get_put 全链路 + LinkResolver::resolve_field + CPCacheEntry::set_field 位布局 + 模板解释器快速路径 + GDB BEFORE/AFTER 验证） |
| Day 30 | [**方法解析 — resolve_invoke + vtable/itable 调度**](./RuntimeResolve/2-Method-Resolution-Invoke-Dispatch.md) | ✅ 完成（程序=数据结构+算法重写：LinkInfo/CallInfo/Method::_vtable_index 完整字段+生命周期 + vtable/itable 构建算法 + 四种解析路径 + CPCacheEntry 六种填充 + 数据结构关系图） |
| Day 31 | [**invokedynamic / invokehandle / MethodHandle 深度剖析**](./RuntimeResolve/3-InvokeDynamic-MethodHandle-Deep-Dive.md) | ✅ 完成（7 个 Java 层映射类完整字段 + _operands 两段式布局 + CPCacheEntry MH/indy 模式 + 负数索引编码 + Rewriter invokehandle 重写 + resolve_invokedynamic 三层并发防护 + set_method_handle_common 写入顺序 + 模板解释器快路径 + jump_to_lambda_form 4 次解引用 + linkTo* vtable/itable 调度） |

### 待完成

| 序号 | 文档 | 状态 |
|------|------|------|
| Day 32+ | GDB 实战验证（invokedynamic 全链路断点 + CPCacheEntry 数据验证） | 📝 计划中 |

---

## 异常处理系列（Week 5，Day 32-）

### 已完成

| 序号 | 文档 | 状态 |
|------|------|------|
| Day 32 | [**异常处理机制深度剖析**](./ExceptionHandling/1-Exception-Handling-Deep-Dive.md) | ✅ 完成（ThreadShadow+TRAPS/CHECK/THROW 宏体系 + ExceptionTableElement/HandlerTableEntry/ImplicitExceptionTable/ExceptionCache 4 大异常表结构 + 栈保护区 4 层机制 + athrow 字节码/栈展开/隐式空指针/栈溢出/编译代码异常/VM 内部 THROW 6 大算法流程 + 解释器 vs 编译器对比） |

| Day 33 | [**异常处理 GDB/CLion 验证指南**](./ExceptionHandling/2-Exception-Handling-GDB-Verification.md) | ✅ 完成（sizeof/offset GDB 验证 + 栈保护区 4 层精确验证 + CLion 6 个断点验证方案 + Yellow Zone 修正 8KB） |

### 待完成

| 序号 | 文档 | 状态 |
|------|------|------|
| Day 34 | [**同步机制深度剖析 — monitorenter/monitorexit → 轻量级锁 → ObjectMonitor**](./Synchronization/1-Synchronization-Mechanism-Deep-Dive.md) | ✅ 完成（6大数据结构全字段+sizeof/offset GDB验证 + MarkWord编码/BasicLock值域图/ObjectMonitor内存布局 + **19个算法/函数源码级分析**：fast_enter/fast_exit/slow_enter/inflate/enter/TryLock/TrySpin/EnterI/UnlinkAfterAcquire/exit/ExitEpilog/wait/INotify/ReenterI/WaitSet操作/omAlloc三级分配/PlatformEvent状态机/SpinAcquire退避/DeferredInitialize + Knob_*速查表 + GDB断点验证） |

---

## 同步机制系列（Week 5，Day 34-）

### 已完成

| 序号 | 文档 | 状态 |
|------|------|------|
| Day 34 | [**同步机制深度剖析**](./Synchronization/1-Synchronization-Mechanism-Deep-Dive.md) | ✅ 完成（sizeof/offset GDB 验证 ✅ + 流程断点验证 ✅ + **19 个算法/函数源码级深度分析 ✅**） |

---

## JMM / 内存屏障系列（Week 5，Day 35-）

### 已完成

| 序号 | 文档 | 状态 |
|------|------|------|
| Day 35 | [**Java 内存模型 — volatile / Unsafe CAS / 内存屏障在 x86 的落地**](./JMM/1-Java-Memory-Model-Deep-Dive.md) | ✅ 完成（x86 TSO 分析 + Access 5 步管线 + 10 大数据结构全字段分析 + 5 条完整调用链） |

---

## 运行时/并发机制系列（Week 6，Day 36-39）

### 已完成

| 序号 | 文档 | 状态 |
|------|------|------|
| Day 36 | [**线程生命周期深度剖析**](./ThreadLifecycle/1-Thread-Lifecycle-Deep-Dive.md) | ✅ 完成（1481 行：9 大数据结构全字段分析 — ThreadShadow/Thread/JavaThread/OSThread/JavaThreadState/ThreadState/_thread_state 值域 + 6 大算法源码级分析 — Thread.start() 8 步调用链/thread_entry→run→thread_main_inner 三级入口/exit() 4 阶段退出/sleep() 中断感知+条件等待/interrupt() 非阻塞+阻塞双路径/join() Cpp→Java→ObjectMonitor::wait 三层 + GDB sizeof/offset/断点验证全 ✓） |
| Day 37 | [**Parker / LockSupport 深度剖析**](./ParkerLockSupport/1-Parker-LockSupport-Deep-Dive.md) | ✅ 完成（916 行：Parker 类 pthread_mutex+pthread_cond 实现 + _counter 许可证机制 + park/unpark 源码逐行分析 + 4 种场景时序图 + GDB 验证） |
| Day 38 | [**Native 方法调用框架深度剖析**](./NativeWrapper/1-Native-Method-Calling-Framework.md) | ✅ 完成（1239 行：解释器 generate_native_entry vs 编译器 generate_native_wrapper 双路径 + The Grand Shuffle 参数重排 + oop→JNI Handle 转换 + 线程状态转换 _thread_in_vm→_thread_in_native→_thread_in_vm + GC 安全点交互 + GDB 验证） |
| Day 39 | [**JNI Global/Weak Reference 深度剖析**](./JNIReference/1-JNI-Global-Weak-Reference-Deep-Dive.md) | ✅ 完成（865 行：OopStorage 架构 — Global/Weak Reference 管理 + Block/ActiveArray 两级结构 + Local Ref → JNIHandleBlock 链式管理 + GDB 验证） |

| Day 36 补充 | [**线程栈内存布局 + Thread-SMR + 全局线程列表管理**](./ThreadLifecycle/2-Thread-Lifecycle-Supplement-Deep-Dive.md) | ✅ 完成（7 个数据结构全字段分析 — ThreadsList(40B)/SafeThreadsListPtr(32B)/ThreadsListHandle(64B)/ThreadsSMRSupport/StackGuardState/Thread SMR 字段组 + 14 个算法源码级分析 — Red/Yellow/Reserved/Shadow Zone 栈布局 + NPTL guard page 修正 + Hazard Pointer 快速路径/嵌套路径/释放 + COW add/remove + smr_delete 等待循环 + free_list 扫描释放 + Threads::add 头插法 + Threads::remove 全流程 + GDB 11 项验证全 ✓） |

> **运行时/并发机制系列共 5 篇文档（Day 36-39 + Day 36 补充），合计约 5700 行，覆盖线程生命周期、栈内存布局、Thread-SMR、Parker/LockSupport、Native 调用框架、JNI 引用管理。**

---

## 栈帧结构与栈遍历系列（Week 6，Day 40）

### 已完成

| 序号 | 文档 | 状态 |
|------|------|------|
| Day 40 | [**栈帧结构与栈遍历深度剖析**](./StackFrame/1-Stack-Frame-And-Stack-Walking-Deep-Dive.md) | ✅ 完成（1135 行：frame 类 3 种帧类型 + 13 个核心数据结构全字段分析 + sender() 3 路派发 + StackFrameStream 遍历 + OopMap/RegisterMap GC 扫描 + GDB sizeof/offset/运行时验证） |
| Day 40 补充 | [**栈帧结构与栈遍历 — 深度补全**](./StackFrame/2-Stack-Frame-Supplement-Deep-Dive.md) | ✅ 完成（1367 行：10 个补充数据结构全字段分析 — JavaFrameAnchor/InterpreterOopMap/OopMapCacheEntry/OopMapCache/OopMapForCacheEntry/ScopeDesc/SimpleScopeDesc/PcDesc/CodeBlob._frame_size/DebugInformationRecorder + 4 个算法源码级分析 — oops_interpreted_do 5 步扫描/InterpreterFrameClosure/resource_copy/mask_for 路由 + GDB 验证 10 项全 ✓） |
| Day 40 补充2 | [**栈帧结构与栈遍历 — 深度补全（二）**](./StackFrame/3-Stack-Frame-Supplement-2-Deep-Dive.md) | ✅ 完成（~750 行：7 个补充数据结构 — JavaCallWrapper(72B)/JavaCallArguments(136B)/UnrollBlock(88B)/vframeArrayElement(96B)/vframeArray(5408B)/MonitorChunk(32B)/CompiledArgumentOopFinder(144B) + 4 个算法 — safe_for_sender()/oops_entry_do()/real_sender()/CompiledArgumentOopFinder::oops_do() + GDB 验证 11 项全 ✓） |

> **Day 40 栈帧系列共 3 篇文档，~3250 行，覆盖 30 个数据结构 + 13 个算法，全部 GDB 验证通过。**

---

## SO 库系列（Week 7+，Day 41-）

### 已完成

| 序号 | 文档 | 状态 |
|------|------|------|
| Day 41 | [**libinstrument.so — Java Agent 机制深度剖析**](./SOLibrary/1-libinstrument-Java-Agent-Deep-Dive.md) | ✅ 完成（三层架构：Java API / libinstrument.so / HotSpot JVMTI。10 个数据结构全字段分析 — JPLISAgent(120B ✅)/JPLISEnvironment(24B ✅)/AgentLibrary/InstrumentationImpl/TransformerManager(COW)/JvmtiClassFileLoadHookPoster(14字段)/Reentrancy Token。10 大算法 L4+ 源码级：启动加载 6 阶段/动态 Attach/CFLH 事件链(5子节)/重入保护/convertCapabilityAttributes/retransformableEnvironment/setHasTransformers 懒启用/InstrumentationImpl.transform 分发。GDB 验证 ✅：sizeof 精确匹配 + 14 字段偏移 + 8 断点全命中 + CFLH 调用链 + 重入令牌 TLS + 懒加载证实。） |

### 待完成

| 序号 | 文档 | 状态 |
|------|------|------|
| Day 42+ | libjsig.so / libjli.so / libattach.so | 📝 计划中 |

---

## 插桩系列（Instrumentation，持续进行中）

### 已完成

| 序号 | 文档 | 状态 |
|------|------|------|
| 第1章 | [**JVM 启动探针结果**](./Instrumentation/02-JVM-Startup-Probe-Results.md) | ✅ 完成（Threads::create_vm 11个阶段全覆盖） |
| 第2章 | [**对象分配探针结果**](./Instrumentation/03-ObjectAlloc-Probe-Results.md) | ✅ 完成（TLAB/Humongous 分配路径验证） |
| 第4章 | [**G1 YoungGC 探针结果**](./Instrumentation/04-YoungGC-Probe-Results.md) | ✅ 完成（2次YoungGC完整数据：触发条件/CSet/复制字节数/Region守恒验证。关键修复：探针必须在note_gc_start()之前读Eden，在set_bytes_copied()之后读evacuation_info） |
| 第4B章 | [**G1 写屏障漏斗分析**](./Instrumentation/04B-WriteBarrier-Probe-Results.md) | ✅ 完成（汇编快路径全路径插桩：431万次触发漏斗分析。关键发现：最大过滤是Young Card(88.1%)而非同Region(8%)；真正入队仅0.0009%；校验和误差<15符合多线程非原子计数器预期。修正总纲"95%同Region"的错误预期） |
| 第6章 | [**SafePoint 机制插桩结果（完整版）**](./Instrumentation/06-Safepoint-Probe-Results.md) | ✅ 完成（14 个探针全命中：SafepointMechanism::init 轮询页 armed/disarmed 值 + poll_bit=8；STS 系列 7 个探针（join/leave/yield/yield_resume/synchronize/synchronize_done/desynchronize）；safepoint.cpp begin/phase1/phase2/end/block；safepointMechanism block_if_requested_slow。关键发现：STS::synchronize 几乎零耗时（already_sync，nthreads=0）；TTSP 约 0.05ms（-Xint）；Java 线程阻塞时 state=7（_thread_in_Java）；poll_bit=0x8 通过 bit3 区分 armed/disarmed；Safepoint 计数器奇偶交替验证通过。） |

---

## new-md G1 GC 系列（出版级，持续进行中）

### 已完成

| 篇章 | 文件 | 状态 | 说明 |
|------|------|------|------|
| 第 22 篇 | `22-g1-allocation-HandWritten.md`（889行） | 🟢 初稿完成 | 数据结构完整，GDB 验证完成（sizeof=144B，TLAB=2048KB，Humongous=2MB） |
| 第 23 篇 | `23-g1-overview-HandWritten.md`（1190行） | 🟢 数据结构补强完成 | HeapRegion/HeapRegionRemSet 6项分析完成，GDB验证完成 |
| 第 24 篇 | `24-g1-young-gc-HandWritten.md`（1068行） | 🟢 出版级完成 | 6项数据结构分析 + copy_to_survivor_space源码逐行注释 + 工作窃取终止协议 + GDB验证 |
| 第 25 篇 | `25-g1-rset-HandWritten.md`（1131行） | 🟢 补强完成 | G1FromCardCache完整分析，DCQ三区源码推导，打桩数据完整 |
| 第 26 篇 | `26-g1-concurrent-mark-HandWritten.md`（1300行） | 🟢 出版级完成 | do_marking_step()六阶段源码逐行注释，打桩验证（SATB_QUEUE=98.7%） |
| 第 27 篇 | `27-g1-mixed-gc-HandWritten.md`（1071行） | 🟢 出版级完成 | TruncatedSeq衰减均值算法源码，G1Analytics完整字段，打桩验证 |
| 第 27b 篇 | `27b-g1-full-gc-HandWritten.md`（777行） | 🟢 补强完成 | G1FullCollector完整字段分析，四个阶段源码逐行注释，打桩验证 |
| 第 27c 篇 | `27c-g1-humongous-HandWritten.md`（989行） | 🟢 补强完成 | 分配三级策略源码，急切回收四条件源码，打桩验证 |
| 第 27d 篇 | `27d-g1-auxiliary-HandWritten.md`（678行） | 🟢 出版级完成 | G1StringDedup完整数据结构分析（6项）+ 去重算法源码逐行注释 + String.intern() vs 字符串去重对比 + 打桩验证（入队/新条目/去重发生 3个探针全命中） |
| 第 27e 篇 | `27e-g1-reference-HandWritten.md`（768行） | 🟢 补强完成 | 四种引用类型完整分析，discover_reference/process_discovered_references源码逐行注释，打桩验证 |
| 第 28 篇 | `28-g1-safepoint-stw-HandWritten.md`（739行） | 🟢 出版级完成 | SafepointSynchronize/ThreadSafepointState完整字段分析 + begin()/block()/end()源码逐行注释 + 奇偶编码状态机 + 打桩验证（TTSP≈24μs，STW总时长40ms，_safepoint_counter奇偶交替，block()线程state=7） |
| 第 29 篇 | `29-g1-gc-log-HandWritten.md`（722行） | 🟢 初稿完成 | 真实日志采集，8大部分：日志格式/Young GC/并发标记/异常识别/详细子阶段/诊断框架，源码行号对齐 |
| 第 30 篇 | `30-g1-tuning-HandWritten.md`（840行） | 🟢 初稿完成 | 10大部分：调优姿势/参数全景/Young GC优化/Full GC预防/Mixed GC优化/内存泄漏/Metaspace/实战案例/决策树/ZGC对比 |

### 待完成

| 篇章 | 文件 | 状态 |
|------|------|------|
| 第 31 篇 | `31-gc-comparison-HandWritten.md` | 🟢 **出版级完成**（944行，G1/ZGC/Shenandoah 三维对比：着色指针/Brooks指针/Region化堆完整数据结构分析 + 三款GC停顿来源源码分析 + 核心指标对比表 + GC选择决策树（Mermaid）+ 演进趋势（分代ZGC/IU模式/G1 JDK12-17优化）） |