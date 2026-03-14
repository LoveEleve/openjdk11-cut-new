# JVM 源码手写笔记 · 总大纲

> 这不是教程，是我自己啃 JVM 源码时记下来的东西。  
> 风格参考：`/data/workspace/redis-7.0/src/md/cluster/Cluster-HandWritten.md`  
> 核心原则：**第一人称 · 学习时间线 · 真实踩坑 · 诚实标注盲区**

---

## 写作风格说明

### 和现有文档的区别

| 维度 | 现有文档（规范驱动） | 手写笔记（学习驱动） |
|------|---------------------|---------------------|
| 叙事视角 | 第三人称技术报告 | 第一人称学习过程 |
| 结构来源 | 预设模板（第0部分→第N部分） | 学习时间线（第零天→第N天） |
| 问题来源 | 预设的"解决什么问题" | 真实踩坑（"我以为...结果..."） |
| 盲区处理 | 标注"未验证" | 诚实写"我没搞懂"、"TODO" |
| 数据结构 | 先穷举清单，再逐个分析 | 先看算法踩坑，**回头补课** |
| 读者感受 | "这是一份完整的参考手册" | "我也会这样踩坑！" |

### 叙事结构模板（仿 Redis 文档）

```
第零天  → 我以为 XXX 很简单，结果...（建立误解起点）
第一天  → 我踩的第一个坑（打破最大的误解）
第一天半 → 数据结构补课（我第二天看算法时发现自己对某些字段完全没概念，回来补课）
第二天  → 核心流程（我以为只有一条路，结果有N条）
第三天  → 最反直觉的设计（为什么要这样做？）
第四天  → 边界情况（我以为不会发生的事情）
第五天  → 插桩验证（我用数据打脸了自己的猜测）
尾声    → 我现在怎么理解 XXX
还没搞懂的地方 → 诚实列出 TODO
```

---

## 文档清单

> 按学习顺序排列，每篇文档对应一个核心主题  
> 状态：⬜ 未开始 / 🔶 进行中 / ✅ 已完成

---

### 第一章：对象与锁（并发基础）

| # | 文件名 | 核心主题 | 对应现有文档 | 状态 |
|---|--------|---------|-------------|------|
| 01 | `01-synchronized-HandWritten.md` | synchronized / ObjectMonitor | `JVM-Core-Objects/05-ObjectMonitor-Deep-Dive.md` `Synchronization/3-ObjectMonitor-Enter-Exit-Deep-Dive.md` `RuntimeResolve/ch03_lock_optimization.md` | ✅ |
| 02 | `02-object-header-HandWritten.md` | 对象头 / MarkWord / 锁升级 | `JMM/5-Lock-Escalation-Full-Chain.md` `Synchronization/1-Synchronization-Mechanism-Deep-Dive.md` `RuntimeResolve/ch01_object_header_markword.md` `JVM-Core-Objects/04-MarkWord-Encoding.md` | ✅ |
| 03 | `03-wait-notify-HandWritten.md` | wait/notify / ObjectWaiter 状态机 | `JMM/4-ObjectMonitor-Wait-Notify-Deep-Dive.md` | ✅ |
| 04 | `04-park-unpark-HandWritten.md` | LockSupport.park / Parker / ParkEvent | `ParkerLockSupport/` | ✅ |

**第一章学习路线**：

```
第零天：我以为 synchronized 就是一把 0/1 的锁
    ↓
第一天：MarkWord 有 4 种状态（不是 0/1）
    ↓
第一天半：ObjectMonitor 数据结构补课（_owner 的三种值）
    ↓
第二天：加锁流程（4 条路径，不是 1 条）
    ↓
第三天：解锁流程（最反直觉：先释放锁再重新获取才能唤醒等待者）
    ↓
第四天：wait/notify（notify 不是立刻唤醒，只是移队列）
    ↓
第五天：插桩验证（sizeof=216，_owner 偏移 128，不是我猜的 64）
```

---

### 第二章：对象内存模型

| # | 文件名 | 核心主题 | 对应现有文档 | 状态 |
|---|--------|---------|-------------|------|
| 05 | `05-object-layout-HandWritten.md` | 对象内存布局 / oopDesc / instanceOopDesc | `ObjectModel/1-Oop-Klass-Architecture-Deep-Dive.md` | ✅ |
| 06 | `06-object-alloc-HandWritten.md` | 对象分配 / TLAB / 慢速分配 | `ObjectModel/2-Object-Allocation-Flow-Deep-Dive.md` `ObjectModel/4-TLAB-Deep-Dive.md` `RuntimeResolve/ch02_object_allocation.md` `JVM-Core-Objects/01-ObjectAlloc-Full-Chain.md` | ✅ |
| 07 | `07-klass-hierarchy-HandWritten.md` | Klass 体系 / InstanceKlass / ArrayKlass | `ClassLoading/klass_hierarchy.md` `ClassLoading/InstanceKlass-Expert-Analysis.md` `JVM-Core-Objects/07-InstanceKlass-Layout.md` | ✅ |

**第二章学习路线**：

```
第零天：我以为 new Object() 就是 malloc 一块内存
    ↓
第一天：对象头（MarkWord + Klass*）是什么？
    ↓
第一天半：oopDesc / instanceOopDesc 数据结构补课
    ↓
第二天：TLAB 分配（我以为每次都要加锁，结果大多数时候不需要）
    ↓
第三天：慢速分配路径（TLAB 满了怎么办？）
    ↓
第四天：数组对象和普通对象的区别（多一个 length 字段）
    ↓
第五天：插桩验证（对象头大小、字段偏移、TLAB 分配比例）
```

---

### 第三章：类加载

| # | 文件名 | 核心主题 | 对应现有文档 | 状态 |
|---|--------|---------|-------------|------|
| 08 | `08-classloading-HandWritten.md` | 类加载全流程 / 双亲委派 | `ClassLoading/classloading_complete_flow.md` `ClassLoading/ch07_parent_delegation_loadclass.md` `JVM-Core-Objects/06-ClassLoading-Timeline.md` | ✅ |
| 09 | `09-classfileparser-HandWritten.md` | ClassFileParser / .class 文件解析 | `ClassLoading/classfile_parser.md` `ClassLoading/ClassFileParser-Expert-Analysis.md` | ✅ |
| 10 | `10-linking-init-HandWritten.md` | 链接 / 初始化 / `<clinit>` | `ClassLoading/class_linking_initialization.md` | ✅ |
| 11 | `11-constantpool-HandWritten.md` | ConstantPool / 延迟解析 / 运行时解析 | `RuntimeResolve/1-Runtime-Resolution-Field-Resolve.md` `RuntimeResolve/2-Method-Resolution-Invoke-Dispatch.md` `RuntimeResolve/3-InvokeDynamic-MethodHandle-Deep-Dive.md` | ✅ |

**第三章学习路线**：

```
第零天：我以为类加载就是"把 .class 文件读进来"
    ↓
第一天：双亲委派（我以为是"先自己找，找不到再问父亲"，结果反过来）
    ↓
第一天半：InstanceKlass 数据结构补课（vtable/itable/ConstantPool 在哪里？）
    ↓
第二天：ClassFileParser（.class 文件格式，我以为很简单，结果有 200+ 种验证）
    ↓
第三天：链接阶段（验证/准备/解析，我以为是一次性完成的，结果解析是延迟的）
    ↓
第四天：初始化（`<clinit>` 的触发条件，我以为 new 就会触发，结果不一定）
    ↓
第五天：插桩验证（类加载次数、InstanceKlass 大小、vtable 长度）
```

---

### 第四章：JVM 启动流程

| # | 文件名 | 核心主题 | 对应现有文档 | 状态 |
|---|--------|---------|-------------|------|
| 12 | `12-jvm-startup-HandWritten.md` | create_vm / 12 个 Phase | `JVM-Startup/` | ✅ |
| 12b | `12b-jvm-args-tls-HandWritten.md` | JVM 参数解析 / Arguments / ThreadLocalStorage | `Arguments/arguments_parse.md` `ThreadLocalStorage/ThreadLocalStorage_init.md` | ⬜ |
| 13 | `13-vmthread-HandWritten.md` | VMThread / VMOperation 分发 | `VMThread/` | ✅ |
| 13b | `13b-service-watcher-thread-HandWritten.md` | ServiceThread / WatcherThread / JVM 后台线程体系 | `ServiceThread/ServiceThread-Analysis.md` `WatcherThread/WatcherThread-Analysis.md` | ✅ |
| 14 | `14-thread-lifecycle-HandWritten.md` | JavaThread 生命周期 / OSThread | `Thread/` `ThreadLifecycle/` | ⬜ |

**第四章学习路线**：

```
第零天：我以为 java 命令执行后 JVM 就直接开始跑 main 方法
    ↓
第一天：libjli.so 是什么？JVM 是怎么被加载进来的？
    ↓
第一天半：JavaThread / VMThread / OSThread 数据结构补课
    ↓
第二天：create_vm 的 12 个 Phase（我以为是线性的，结果有很多依赖关系）
    ↓
第三天：VMThread 是什么？为什么需要一个专门的线程来执行 VM 操作？
    ↓
第四天：main 方法是怎么被调用的？（从 C++ 到 Java 的跨越）
    ↓
第四天四分之一：JVM 参数解析（Arguments::parse() 是怎么把 -Xmx8g 变成内部参数的？）
            （ThreadLocalStorage：每个线程怎么快速找到自己的 JavaThread*？）
    ↓
第四天半：ServiceThread / WatcherThread（我以为 JVM 只有 VMThread 一个后台线程，结果有一堆！）
            （ServiceThread：处理 GC 通知/JVMTI 事件；WatcherThread：定时任务/JVM 内部计时器）
    ↓
第五天：插桩验证（各 Phase 耗时、线程数量、内存分配量）
```

---

### 第五章：解释器

| # | 文件名 | 核心主题 | 对应现有文档 | 状态 |
|---|--------|---------|-------------|------|
| 15 | `15-interpreter-HandWritten.md` | TemplateInterpreter / 字节码分发 | `Interpreter/` `TemplateTable/` | ✅ |
| 15b | `15b-stub-routines-HandWritten.md` | StubRoutines / 运行时桩代码 / arraycopy 汇编 | `StubRoutines/stubRoutines_init1.md` `StubRoutines/stubRoutines_init2.md` | ✅ |
| 16 | `16-stack-frame-HandWritten.md` | 栈帧 / 解释帧 / 编译帧 | `StackFrame/` `JVM-Core-Objects/03-StackFrame-Layout.md` | ✅ |
| 17 | `17-invoke-HandWritten.md` | invokevirtual / invokeinterface / invokedynamic | `Bytecodes/` `InlineCacheBuffer/` `RuntimeResolve/3-InvokeDynamic-MethodHandle-Deep-Dive.md` `JVM-Core-Objects/02-MethodInvocation-Full-Chain.md` | ✅ |
| 17b | `17b-method-handles-HandWritten.md` | MethodHandles 适配器生成 / invokedynamic 底层 / SharedRuntime | `MethodHandles/MethodHandles_generate_adapters.md` `RuntimeResolve/SharedRuntime_generate_stubs.md` | ✅ |
| 44 | `44-exception-handling-HandWritten.md` | 异常处理 / athrow / 异常表 / 跨帧传播 | `ExceptionHandling/1-Exception-Handling-Deep-Dive.md` `RuntimeResolve/ch06_exception_handling.md` | ✅ |
| 44b | `44b-exception-handling-advanced-HandWritten.md` | 异常处理进阶 / TRAPS宏体系 / ImplicitExceptionTable / forward_exception_entry | `ExceptionHandling/1-Exception-Handling-Deep-Dive.md` | ✅ |

**第五章学习路线**：

```
第零天：我以为解释器就是一个 switch-case，每个字节码一个 case
    ↓
第一天：TemplateInterpreter（不是 switch-case，是生成的汇编代码！）
    ↓
第一天半：InterpreterCodelet / DispatchTable 数据结构补课
    ↓
第二天：字节码分发（dispatch_next 是怎么跳转的？）
    ↓
第二天半：StubRoutines（解释器依赖的运行时桩代码，arraycopy 是汇编实现的！）
    ↓
第三天：invokevirtual（我以为就是查 vtable，结果有内联缓存）
    ↓
第四天：invokedynamic（我以为和 invokevirtual 差不多，结果完全不同）
    ↓
第四天半：异常处理（athrow 字节码 → 异常表查找 → 跨帧 stack unwinding）
    ↓
第四天三刻：MethodHandles 适配器（invokedynamic 最终落地在哪里？SharedRuntime 生成的适配器桩）
    ↓
第五天：插桩验证（字节码执行次数、内联缓存命中率、异常表大小）
```

---

### 第六章：JIT 编译器

| # | 文件名 | 核心主题 | 对应现有文档 | 状态 |
|---|--------|---------|-------------|------|
| 18 | `18-compilation-trigger-HandWritten.md` | 热点探测 / 方法计数器 / 编译触发 / CompileBroker / MethodData | `Compiler/1-Compilation-Trigger-Hot-Method-Detection.md` `Compiler/2-CompileBroker-Compilation-Dispatch.md` `InvocationCounter/` `MethodData/MethodData.md` | ✅ |
| 19 | `19-c1-pipeline-HandWritten.md` | C1 编译管线 / HIR→LIR→机器码 | `Compiler/3-C1-Compilation-Pipeline.md` `Compiler/c1_compilation_pipeline.md` | ⬜ |
| 20 | `20-c2-ideal-graph-HandWritten.md` | C2 Ideal Graph / 优化 | `Compiler/4-C2-Ideal-Graph.md` `Compiler/5-C2-Core-Optimizations.md` | ⬜ |
| 21 | `21-deopt-HandWritten.md` | 逆优化 / uncommon trap / 栈帧重建 | `Compiler/7-Deoptimization.md` | ⬜ |
| 21b | `21b-osr-HandWritten.md` | OSR（On-Stack Replacement）/ 循环热点替换 | `Compiler/6-OSR-On-Stack-Replacement.md` | ⬜ |
| 22 | `22-escape-analysis-HandWritten.md` | 逃逸分析 / 标量替换 / 栈上分配 | `Compiler/8-Escape-Analysis-Scalar-Replacement.md` `Compiler/escape_analysis.md` | ⬜ |

**第六章学习路线**：

```
第零天：我以为 JIT 就是"把热点方法编译成机器码"，很简单
    ↓
第一天：方法计数器（invocation_counter + backedge_counter，不是一个计数器）
    ↓
第一天半：CompileTask / CompileQueue / CompileBroker 数据结构补课
            （编译任务是怎么从 JavaThread 提交到 CompilerThread 的？）
    ↓
第一天三刻：MethodData（我以为 JIT 只看计数器，结果还有一个"方法画像"记录每个分支的执行情况！）
            （MethodData 是分层编译的数据基础：C1 收集 profile，C2 根据 profile 做激进优化）
    ↓
第二天：C1 管线（4 个阶段，我以为是直接翻译字节码，结果有 HIR/LIR 两层 IR）
    ↓
第三天：逆优化（我以为编译后就永远用编译版本，结果可以"反悔"）
    ↓
第三天半：OSR（我以为只有方法入口才能被编译，结果循环体中间也能替换！）
            （OSR 和逆优化是一对：解释→编译 vs 编译→解释）
    ↓
第四天：逃逸分析（我以为 new 一定在堆上，结果可以在栈上）
    ↓
第五天：插桩验证（编译触发阈值、C1/C2 编译次数、逆优化次数、OSR 次数）
```

---

### 第七章：G1 垃圾回收

| # | 文件名 | 核心主题 | 对应现有文档 | 状态 |
|---|--------|---------|-------------|------|
| 23 | `23-g1-overview-HandWritten.md` | G1 整体架构 / Region / 为什么需要 G1 | `G1GC/1-HeapRegion-Deep-Dive.md` `G1GC/0-G1-DataStructure-Map.md` `G1CollectedHeap-Deep-Dive/1-G1CollectedHeap-Complete-Field-Analysis.md` `G1CollectedHeap-Deep-Dive/2-G1CollectedHeap-initialize-Method-Analysis.md` `G1CollectedHeap-Deep-Dive/3-G1CollectedHeap-Field-Definition-Style.md` | ✅ |
| 24 | `24-g1-young-gc-HandWritten.md` | Young GC / 根扫描 / 对象疏散 | `G1GC/11-Young-GC-Complete-STW-Flow.md` `G1GC/4_2_Evacuation_Phase.md` | ⬜ |
| 25 | `25-g1-rset-HandWritten.md` | RSet / CardTable / 写屏障 | `G1GC/12-G1RemSet-Complete-Flow.md` `G1GC/5-RSet-Three-Level-Structure.md` `G1GC/13-Write-Barrier-Assembly-Full-Chain.md` | ⬜ |
| 26 | `26-g1-concurrent-mark-HandWritten.md` | 并发标记 / SATB / 三色标记 | `G1GC/`（需整合多篇） | ⬜ |
| 27 | `27-g1-mixed-gc-HandWritten.md` | Mixed GC / 回收集选择 / G1Policy 预测模型 | `G1GC/3_1_CSet_Selection.md` `G1GC/16-Strategy-Adaptive-Adjustment.md` | ⬜ |
| 27b | `27b-g1-full-gc-HandWritten.md` | G1 Full GC / Evacuation Failure / 兜底机制 | `G1GC/10-Full-GC.md` `G1GC/G1-Full-GC-LineByLine-Analysis.md` | ⬜ |
| 27c | `27c-g1-auxiliary-HandWritten.md` | G1 辅助子系统 / StringDedup / WorkGang / GC 日志实战 | `G1GC/17-Auxiliary-Subsystems.md` `G1GC/18-GC-Log-Practice.md` `G1GC/19-GC-Troubleshooting-Deep-Dive.md` | ⬜ |
| 28b | `28b-reference-processing-HandWritten.md` | 引用类型处理 / ReferenceProcessor / Finalizer | `ReferenceProcessing/referenceProcessor_init.md` `ReferenceProcessing/ReferenceHandler-Finalizer-Analysis.md` `G1GC/15-Reference-Processing-Full-Chain.md` `RuntimeResolve/ch04_object_finalization_reference.md` | ⬜ |

**第七章学习路线**：

```
第零天：我以为 G1 就是"把堆分成小块，每次只回收一部分"
    ↓
第一天：Region（不是简单的小块，有 Eden/Survivor/Old/Humongous 之分）
    ↓
第一天半：HeapRegion / G1CollectedHeap 数据结构补课
    ↓
第二天：Young GC（我以为就是扫描 Eden，结果还要处理跨 Region 引用）
    ↓
第三天：RSet（我以为是"记录谁引用了我"，结果是 CardTable 的索引）
    ↓
第四天：并发标记（SATB 是什么？为什么不用增量更新？）
    ↓
第四天半：Mixed GC + G1Policy 预测模型
            （我以为设置了 -XX:MaxGCPauseMillis=200 就一定不超 200ms，结果...）
    ↓
第五天：Full GC（我以为 G1 不会 Full GC，结果 Evacuation Failure 时会退化！）
    ↓
第五天半：引用类型处理（WeakReference/SoftReference/PhantomReference 在 GC 里怎么处理？）
    ↓
第五天三刻：G1 辅助子系统（StringDedup 是什么？WorkGang 是怎么并行化 GC 工作的？）
    ↓
第六天：GC 日志实战（-Xlog:gc* 输出怎么看？每一行对应哪个阶段？）
    ↓
第七天：插桩验证（Region 数量、RSet 大小、Young GC 各阶段耗时、Full GC 触发条件）
```

---

### 第八章：Safepoint

| # | 文件名 | 核心主题 | 对应现有文档 | 状态 |
|---|--------|---------|-------------|------|
| 28 | `28-safepoint-HandWritten.md` | Safepoint 全流程 / STW 机制 | `Safepoint/` `G1GC/14-SafePoint-VMOperation.md` | ⬜ |
| 29 | `29-thread-state-HandWritten.md` | 线程状态转换 / 5 种 JavaThread 状态 | `G1GC/14A-SafePoint-Thread-State-Transitions-Deep-Dive.md` | ⬜ |
| 29b | `29b-handshake-HandWritten.md` | Handshake 机制 / 单线程 Safepoint / JDK 10+ | `Handshake/Handshake.md` | ⬜ |

**第八章学习路线**：

```
第零天：我以为 STW 就是"暂停所有线程"，很简单
    ↓
第一天：Polling Page（不是直接 suspend，是让线程自己停下来）
    ↓
第一天半：SafepointSynchronize / ThreadSafepointState 数据结构补课
    ↓
第二天：begin()（我以为是一个函数调用，结果要等所有线程都到达安全点）
    ↓
第三天：线程状态（5 种状态，每种状态响应 Safepoint 的方式不同）
    ↓
第四天：end() + cleanup（Safepoint 结束后还要做 11 件事）
    ↓
第四天半：Handshake（我以为 JDK 10+ 只是优化了 Safepoint，结果是完全不同的机制！）
            （Safepoint = 全局停，Handshake = 只停一个线程，开销差一个数量级）
    ↓
第五天：插桩验证（STW 时间、各线程到达安全点的时间分布、Handshake vs Safepoint 开销对比）
```

---

### 第九章：JMM 与内存屏障

| # | 文件名 | 核心主题 | 对应现有文档 | 状态 |
|---|--------|---------|-------------|------|
| 30 | `30-jmm-HandWritten.md` | Java 内存模型 / Happens-Before / 内存屏障 | `JMM/1-Java-Memory-Model-Deep-Dive.md` | ⬜ |
| 31 | `31-volatile-HandWritten.md` | volatile 在解释器/C1/C2 的三层实现 | `JMM/2-Volatile-Three-Layer-Implementation.md` | ⬜ |
| 32 | `32-cas-atomic-HandWritten.md` | CAS / Unsafe / AtomicXxx 底层 | `JMM/3-Synchronized-Interpreter-Implementation.md`（需补充 CAS 部分） | ⬜ |

**第九章学习路线**：

```
第零天：我以为 volatile 就是"禁止缓存，每次从内存读"
    ↓
第一天：内存屏障（不是"禁止缓存"，是"禁止指令重排序"）
    ↓
第一天半：OrderAccess / Atomic 数据结构补课（x86 上的实现）
    ↓
第二天：volatile 在解释器里的实现（字节码层面加了什么？）
    ↓
第三天：volatile 在 C1/C2 里的实现（JIT 编译后加了什么指令？）
    ↓
第四天：CAS（我以为是一条原子指令，结果在 x86 上是 lock cmpxchg）
    ↓
第五天：插桩验证（内存屏障指令数量、CAS 失败率）
```

---

### 第十章：Metaspace

| # | 文件名 | 核心主题 | 对应现有文档 | 状态 |
|---|--------|---------|-------------|------|
| 33 | `33-metaspace-HandWritten.md` | Metaspace 架构 / 内存分配 / 类卸载 | `Metaspace/` | ⬜ |
| 33b | `33b-codecache-HandWritten.md` | CodeCache / CodeBlob / nmethod 生命周期 | `CodeCache/` | ⬜ |

**第十章学习路线**：

```
第零天：我以为 Metaspace 就是"把 PermGen 移到 native 内存"
    ↓
第一天：Metaspace 的三级结构（VirtualSpaceList → VirtualSpaceNode → Chunk）
    ↓
第一天半：MetaspaceChunk / SpaceManager 数据结构补课
    ↓
第二天：类加载时 Metaspace 分配（InstanceKlass 是怎么分配到 Metaspace 的？）
    ↓
第三天：类卸载（ClassLoaderData 的生命周期，什么时候才能回收？）
    ↓
第四天：Metaspace OOM（为什么会 OOM？怎么排查？）
    ↓
第五天：插桩验证（Metaspace 使用量、Chunk 大小分布、类卸载次数）
```

---

### 第十一章：SO 动态库

| # | 文件名 | 核心主题 | 对应现有文档 | 状态 |
|---|--------|---------|-------------|------|
| 34 | `34-libjli-HandWritten.md` | libjli.so / JVM 启动器 / dlopen | `SOLibrary/5-libjli-Java-Launcher-Deep-Dive.md` | ⬜ |
| 35 | `35-libjsig-HandWritten.md` | libjsig.so / 信号链 / LD_PRELOAD | `SOLibrary/3-libjsig-Signal-Chaining-Deep-Dive.md` | ⬜ |
| 36 | `36-libinstrument-HandWritten.md` | libinstrument.so / Java Agent / premain | `SOLibrary/11-libinstrument-Java-Agent-Deep-Dive.md` | ⬜ |
| 37 | `37-libnio-HandWritten.md` | libnio.so / epoll / NIO 底层 | `SOLibrary/9-libnio-NIO-Deep-Dive.md` | ⬜ |
| 45 | `45-jni-HandWritten.md` | JNI / Local/Global/WeakGlobal Reference / Java↔C++ 边界 | `JNIReference/1-JNI-Global-Weak-Reference-Deep-Dive.md` | ⬜ |
| 46 | `46-libjdwp-HandWritten.md` | libjdwp.so / JDWP 调试协议 / 与 Arthas attach 的关联 | `SOLibrary/6-libjdwp-JDWP-Deep-Dive.md` | ⬜ |
| 47 | `47-libzip-libjimage-HandWritten.md` | libzip.so / libjimage.so / JAR 读取 / JDK9 模块系统 | `SOLibrary/7-libzip-ZIP-JAR-Deep-Dive.md` `SOLibrary/8-libjimage-JDK9-Module-Deep-Dive.md` `NativeLibraries/ch24_libzip_libjimage_class_resource.md` | ⬜ |
| 49 | `49-libnet-libsaproc-HandWritten.md` | libnet.so / libsaproc.so / libjava.so / JVM 网络与诊断底层 | `NativeLibraries/4.2-libnet.so-Java-Network-Implementation-Complete-Source-Analysis.md` `NativeLibraries/5.1-libsaproc.so-Serviceability-Agent-Complete-Source-Analysis.md` `NativeLibraries/ch14_libjava.md` | ⬜ |

**第十一章学习路线**：

```
第零天：我以为 java 命令就是直接启动 JVM
    ↓
第一天：libjli.so（java 命令只是一个 launcher，真正的 JVM 在 libjvm.so 里）
    ↓
第一天半：dlopen / dlsym / JNI_CreateJavaVM 数据结构补课
    ↓
第二天：libjsig.so（我以为信号处理很简单，结果 JVM 和用户代码都要注册信号）
    ↓
第三天：libinstrument.so（Java Agent 是怎么在 premain 里修改字节码的？）
    ↓
第三天半：JNI（我以为 Java 调 C++ 就是直接调，结果有 Local/Global Reference 的生命周期管理）
    ↓
第四天：libnio.so（epoll 是怎么被 Java NIO 用起来的？）
    ↓
第四天半：libzip.so / libjimage.so（类加载时 JAR 和 .jimage 文件是怎么读的？）
    ↓
第五天：libjdwp.so（调试协议和 Arthas attach 有什么关系？）
    ↓
第五天半：libnet.so / libsaproc.so / libjava.so（我以为 Java 网络就是 NIO，结果还有 libnet.so 这一层）
    ↓
第六天：插桩验证（SO 加载顺序、信号注册链、Agent 加载时机、JNI 引用泄漏检测）
```

---

### 第十二章：Arthas 核心机制

| # | 文件名 | 核心主题 | 对应现有文档 | 状态 |
|---|--------|---------|-------------|------|
| 38 | `38-arthas-attach-HandWritten.md` | Arthas attach 机制 / libattach.so | `SOLibrary/4-libattach-Attach-Mechanism-Deep-Dive.md` `Arthas-new/00-Arthas-Complete-Outline.md` | ⬜ |
| 39 | `39-arthas-enhancer-HandWritten.md` | 字节码增强 / ASM / Spy 机制 | `Arthas-new/02-Enhancer-Deep-Dive.md` `Arthas-new/03-Spy-Interceptor-Deep-Dive.md` | ⬜ |
| 40 | `40-arthas-watch-HandWritten.md` | watch/trace/monitor 全链路 | `Arthas-new/06-WatchCommand-Deep-Dive.md` `Arthas-new/07-TraceCommand-Deep-Dive.md` `Arthas-new/08-MonitorCommand-Deep-Dive.md` | ⬜ |

**第十二章学习路线**：

```
第零天：我以为 Arthas 就是"连上 JVM 然后执行命令"
    ↓
第一天：attach 机制（不是直接连，是通过 UNIX socket + signal 触发 JVM 加载 agent）
    ↓
第一天半：AttachListener / VirtualMachine 数据结构补课
    ↓
第二天：字节码增强（watch 命令是怎么在不重启的情况下修改方法的？）
    ↓
第三天：Spy 机制（增强后的字节码是怎么把数据传回 Arthas 的？）
    ↓
第四天：OGNL 表达式（`#cost > 100` 是怎么被执行的？）
    ↓
第五天：插桩验证（attach 耗时、字节码增强前后的 class 对比）
```

---

### 第十三章：AsyncProfiler 核心机制

| # | 文件名 | 核心主题 | 对应现有文档 | 状态 |
|---|--------|---------|-------------|------|
| 41 | `41-async-profiler-cpu-HandWritten.md` | CPU 采样 / perf_event / 信号 | `AsyncProfiler/05-CPU-Profiling-PerfEvents-Deep-Dive.md` | ⬜ |
| 42 | `42-async-profiler-stack-HandWritten.md` | 栈回溯 / AsyncGetCallTrace / 安全点偏差 | `AsyncProfiler/01-Safepoint-Bias-Problem.md` `AsyncProfiler/02-AsyncGetCallTrace-Solution.md` `AsyncProfiler/03-Stack-Walking-Methods-Comparison.md` | ⬜ |
| 43 | `43-async-profiler-alloc-HandWritten.md` | 内存分配采样 / AllocTracer | `AsyncProfiler/06-Allocation-Profiling-Deep-Dive.md` | ⬜ |

**第十三章学习路线**：

```
第零天：我以为 CPU 采样就是"每隔一段时间看看线程在哪里"
    ↓
第一天：安全点偏差（传统采样只在安全点采，会漏掉大量热点！）
    ↓
第一天半：perf_event / AsyncGetCallTrace 数据结构补课
    ↓
第二天：CPU 采样（perf_event 触发信号，信号处理里调用 AsyncGetCallTrace）
    ↓
第三天：栈回溯（我以为就是读 rbp 链，结果 JIT 编译的帧没有 rbp！）
    ↓
第四天：内存分配采样（TLAB 慢速分配路径上的 hook）
    ↓
第五天：插桩验证（采样精度、安全点偏差对比、栈回溯成功率）
```

---

---

### 第十四章：JVM 内部数据结构

| # | 文件名 | 核心主题 | 对应现有文档 | 状态 |
|---|--------|---------|-------------|------|
| 48 | `48-concurrent-hash-table-HandWritten.md` | ConcurrentHashTable / SymbolTable / StringTable | `ConcurrentHashTable/ConcurrentHashTable-Core-Algorithms.md` `ConcurrentHashTable/ConcurrentHashTable-Performance.md` | ⬜ |
| 50 | `50-reflection-javacalls-HandWritten.md` | Java 反射底层 / JavaCalls 框架 / C++ 调 Java 的桥梁 | `RuntimeResolve/ch07_reflection_deep_dive.md` `RuntimeResolve/ch08_javacalls_framework.md` | ⬜ |

**第十四章学习路线**：

```
第零天：我以为 JVM 内部的哈希表就是 Java 的 HashMap
    ↓
第一天：ConcurrentHashTable（JVM 内部用 C++ 实现的无锁哈希表，和 Java HashMap 完全不同）
    ↓
第一天半：SymbolTable / StringTable 数据结构补课
            （类加载时的符号表、String.intern() 的字符串表都用它）
    ↓
第二天：无锁并发设计（CAS + 分段锁，我以为 JVM 内部都是加锁的，结果不是）
    ↓
第三天：插桩验证（SymbolTable 大小、StringTable 碰撞率、intern 性能）
```

---

### 第十五章：反射与 JavaCalls

| # | 文件名 | 核心主题 | 对应现有文档 | 状态 |
|---|--------|---------|-------------|------|
| 50 | `50-reflection-javacalls-HandWritten.md` | Java 反射底层 / JavaCalls 框架 / C++ 调 Java 的桥梁 | `RuntimeResolve/ch07_reflection_deep_dive.md` `RuntimeResolve/ch08_javacalls_framework.md` | ⬜ |

**第十五章学习路线**：

```
第零天：我以为 Java 反射就是"通过字符串找到方法然后调用"
    ↓
第一天：反射底层（Method.invoke() 最终走到哪里？NativeMethodAccessorImpl vs GeneratedMethodAccessorImpl）
    ↓
第一天半：JavaCalls 框架（C++ 代码是怎么调用 Java 方法的？JVM 内部到处都在用这个框架）
    ↓
第二天：反射膨胀（我以为反射一直走 native，结果调用超过 15 次会生成字节码！）
    ↓
第三天：插桩验证（反射调用次数、膨胀阈值、JavaCalls 调用链）
```

---

### 第十六章：JVMTI 与 Native 调用

| # | 文件名 | 核心主题 | 对应现有文档 | 状态 |
|---|--------|---------|-------------|------|
| 51 | `51-jvmti-HandWritten.md` | JVMTI / JVM 工具接口 / Agent 事件回调 | `Runtime/3-JVMTI-Deep-Dive.md` | ⬜ |
| 52 | `52-native-invoke-HandWritten.md` | Native 方法调用框架 / NativeWrapper / JNI 调用约定 | `Runtime/2-Native-Method-Invocation.md` `NativeWrapper/1-Native-Method-Calling-Framework.md` | ⬜ |
| 53 | `53-string-table-HandWritten.md` | String / StringTable / intern() 底层 | `Runtime/1-String-StringTable-Deep-Dive.md` | ⬜ |

**第十六章学习路线**：

```
第零天：我以为 JVMTI 就是 Arthas 用的那个接口，很简单
    ↓
第一天：JVMTI 事件体系（有多少种事件？每种事件在哪个线程回调？）
            （ClassFileLoadHook 是怎么让 Agent 修改字节码的？）
    ↓
第一天半：Native 方法调用框架（Java 调 native 方法，JVM 是怎么找到 C 函数的？）
            （NativeWrapper：JVM 为每个 native 方法生成的适配器桩）
    ↓
第二天：String.intern()（我以为 intern 就是"放进常量池"，结果是 StringTable 哈希表）
    ↓
第三天：插桩验证（JVMTI 事件触发次数、NativeWrapper 大小、StringTable 碰撞率）
```

---

### 第十七章：其他 GC（ParallelGC / ZGC / Shenandoah）

| # | 文件名 | 核心主题 | 对应现有文档 | 状态 |
|---|--------|---------|-------------|------|
| 54 | `54-parallel-gc-HandWritten.md` | ParallelGC / PSScavenge / PSParallelCompact | `ParallelGC/01-Overview-and-Architecture.md` `ParallelGC/05-Young-GC-PSScavenge.md` `ParallelGC/06-Full-GC-PSParallelCompact.md` | ⬜ |
| 55 | `55-zgc-shenandoah-HandWritten.md` | ZGC / Shenandoah / 低延迟 GC 对比 | `Other-GCs/1-GC-Overview-and-Comparison.md` `Other-GCs/2-ZGC-Overview.md` `Other-GCs/3-Shenandoah-Overview.md` | ⬜ |

**第十七章学习路线**：

```
第零天：我以为 G1 是最好的 GC，其他 GC 不用了解
    ↓
第一天：ParallelGC（吞吐量优先，PSScavenge 是怎么并行 Young GC 的？）
            （PSParallelCompact：Full GC 的并行压缩算法）
    ↓
第二天：ZGC（我以为 ZGC 只是"更快的 G1"，结果是完全不同的着色指针方案）
    ↓
第三天：Shenandoah（和 ZGC 有什么区别？Brooks Pointer 是什么？）
    ↓
第四天：GC 选型（什么场景用哪个 GC？数据说话）
```

---

### 第十八章：全链路整合视图

| # | 文件名 | 核心主题 | 对应现有文档 | 状态 |
|---|--------|---------|-------------|------|
| 56 | `56-object-lifecycle-HandWritten.md` | 对象完整生命周期 / 从 new 到 GC 回收 | `Integration/1-Object-Complete-Lifecycle.md` | ⬜ |
| 57 | `57-method-invocation-fullpath-HandWritten.md` | 方法调用全路径 / 解释→C1→C2→逆优化 | `Integration/2-Method-Invocation-Full-Path.md` | ⬜ |
| 58 | `58-young-gc-fullstack-HandWritten.md` | Young GC 全栈视图 / 从触发到完成 | `Integration/3-Young-GC-Full-Stack-View.md` | ⬜ |
| 59 | `59-thread-creation-HandWritten.md` | 线程创建 JVM+OS 视图 / JavaThread→OSThread→pthread | `Integration/4-Thread-Creation-JVM-OS-View.md` | ⬜ |
| 60 | `60-nio-network-fullpath-HandWritten.md` | NIO 网络请求全路径 / Java→libnio→epoll | `Integration/5-NIO-Network-Request-Full-Path.md` | ⬜ |
| 61 | `61-java-agent-fullpath-HandWritten.md` | Java Agent 全路径 / attach→premain→字节码增强 | `Integration/6-Java-Agent-Full-Path.md` | ⬜ |

**第十八章学习路线**：

```
这一章是"串联章"，不引入新知识，而是把前面所有章节串起来
    ↓
第一天：对象生命周期（new → TLAB分配 → Young GC疏散 → Old晋升 → 并发标记 → 回收）
    ↓
第二天：方法调用全路径（字节码 → 解释执行 → C1编译 → C2编译 → 逆优化 → 重新解释）
    ↓
第三天：Young GC 全栈（触发条件 → Safepoint → 根扫描 → 疏散 → RSet更新 → 恢复）
    ↓
第四天：线程创建（Thread.start() → JavaThread → OSThread → pthread_create → 回调 run()）
    ↓
第五天：NIO 全路径（SocketChannel.read() → libnio.so → epoll_wait → 数据拷贝）
    ↓
第六天：Java Agent 全路径（java -javaagent → libinstrument → premain → ASM增强 → 重定义）
```

---

### 第十九章：面试指南

| # | 文件名 | 核心主题 | 对应现有文档 | 状态 |
|---|--------|---------|-------------|------|
| 62 | `62-interview-object-gc-HandWritten.md` | 对象生命周期 / GC 面试题 | `Interview/1-Object-Lifecycle-Interview-Guide.md` `Interview/3-GC-G1GC-Interview-Guide.md` `RuntimeResolve/ch05_interview_guide.md` | ⬜ |
| 63 | `63-interview-thread-jmm-HandWritten.md` | 线程并发 / JMM / volatile 面试题 | `Interview/2-Thread-Concurrency-Interview-Guide.md` `Interview/6-JMM-Volatile-Synchronized-Interview-Guide.md` | ⬜ |
| 64 | `64-interview-jit-classloading-HandWritten.md` | JIT / 类加载 / Metaspace 面试题 | `Interview/4-JIT-Compiler-Interview-Guide.md` `Interview/5-ClassLoading-Metaspace-Interview-Guide.md` | ⬜ |
| 65 | `65-interview-perf-troubleshoot-HandWritten.md` | 性能调优 / 故障排查面试题 | `Interview/7-Performance-Troubleshooting-Interview-Guide.md` | ⬜ |

> **注意**：面试指南章节建议在所有技术章节完成后再写，作为总结和复习材料。

---

### 第二十章：真实案例

| # | 文件名 | 核心主题 | 对应现有文档 | 状态 |
|---|--------|---------|-------------|------|
| 66 | `66-case-cpu-memory-HandWritten.md` | CPU 飙高 / 内存泄漏真实案例 | `RealWorld-Cases/01-CPU-High-Case-Study.md` `RealWorld-Cases/02-Memory-Leak-Case-Study.md` | ⬜ |
| 67 | `67-case-lock-gc-HandWritten.md` | 锁竞争 / GC 故障真实案例 | `RealWorld-Cases/03-Lock-Contention-Case-Study.md` `RealWorld-Cases/04-GC-Troubleshooting-Case-Study.md` | ⬜ |
| 68 | `68-case-classloading-native-HandWritten.md` | 类加载问题 / Native 内存泄漏真实案例 | `RealWorld-Cases/05-ClassLoading-Issue-Case-Study.md` `RealWorld-Cases/06-Native-Memory-Leak-Case-Study.md` | ⬜ |

> **注意**：真实案例章节是整个笔记的"压轴"，建议最后写，把所有知识点融合到实际问题中。

---

## 写作优先级

### 第一批（最核心，先写）

1. `01-synchronized-HandWritten.md` — 并发基础，踩坑最多
2. `23-g1-overview-HandWritten.md` — GC 是 JVM 最重要的模块
3. `28-safepoint-HandWritten.md` — GC 的基础设施
4. `12-jvm-startup-HandWritten.md` — 理解 JVM 的起点
5. `08-classloading-HandWritten.md` — 类加载是所有 Java 程序的基础

### 第二批（重要，次优先）

6. `18-compilation-trigger-HandWritten.md` — JIT 是性能的关键（含 CompileBroker）
7. `30-jmm-HandWritten.md` — 并发编程的理论基础
8. `05-object-layout-HandWritten.md` — 对象模型是一切的基础
9. `15-interpreter-HandWritten.md` — 字节码执行的基础
10. `33-metaspace-HandWritten.md` — 类加载的内存基础
11. `44-exception-handling-HandWritten.md` — 异常处理，和解释器强相关
12. `29b-handshake-HandWritten.md` — Safepoint 的现代替代方案
13. `27b-g1-full-gc-HandWritten.md` — G1 三种 GC 模式缺一不可

### 第三批（工具类，最后写）

14. `38-arthas-attach-HandWritten.md` — 诊断工具
15. `41-async-profiler-cpu-HandWritten.md` — 性能分析工具
16. `34-libjli-HandWritten.md` — SO 库系列
17. `35-libjsig-HandWritten.md` — SO 库系列
18. `21b-osr-HandWritten.md` — 和逆优化配套
19. `28b-reference-processing-HandWritten.md` — GC 引用处理
20. `45-jni-HandWritten.md` — Java/C++ 边界
21. `48-concurrent-hash-table-HandWritten.md` — JVM 内部数据结构
22. `13b-service-watcher-thread-HandWritten.md` — JVM 后台线程体系
23. `17b-method-handles-HandWritten.md` — MethodHandles 适配器（invokedynamic 底层）
24. `27c-g1-auxiliary-HandWritten.md` — G1 辅助子系统 + GC 日志实战
25. `49-libnet-libsaproc-HandWritten.md` — 更多 SO 库
26. `50-reflection-javacalls-HandWritten.md` — 反射与 JavaCalls 框架
27. `12b-jvm-args-tls-HandWritten.md` — JVM 参数解析 / ThreadLocalStorage
28. `51-jvmti-HandWritten.md` — JVMTI 事件体系
29. `52-native-invoke-HandWritten.md` — Native 方法调用框架
30. `53-string-table-HandWritten.md` — String / StringTable / intern()
31. `54-parallel-gc-HandWritten.md` — ParallelGC 完整分析
32. `55-zgc-shenandoah-HandWritten.md` — ZGC / Shenandoah 对比

### 第四批（整合与应用类，最后写）

33. `56-object-lifecycle-HandWritten.md` — 对象完整生命周期全链路
34. `57-method-invocation-fullpath-HandWritten.md` — 方法调用全路径
35. `58-young-gc-fullstack-HandWritten.md` — Young GC 全栈视图
36. `59-thread-creation-HandWritten.md` — 线程创建 JVM+OS 视图
37. `60-nio-network-fullpath-HandWritten.md` — NIO 网络请求全路径
38. `61-java-agent-fullpath-HandWritten.md` — Java Agent 全路径
39. `62-interview-object-gc-HandWritten.md` — 对象/GC 面试题
40. `63-interview-thread-jmm-HandWritten.md` — 线程/JMM 面试题
41. `64-interview-jit-classloading-HandWritten.md` — JIT/类加载 面试题
42. `65-interview-perf-troubleshoot-HandWritten.md` — 性能调优面试题
43. `66-case-cpu-memory-HandWritten.md` — CPU飙高/内存泄漏真实案例
44. `67-case-lock-gc-HandWritten.md` — 锁竞争/GC故障真实案例
45. `68-case-classloading-native-HandWritten.md` — 类加载/Native内存泄漏真实案例

> **注意**：
> - 第十一章 SO 动态库中，`libjli.so` 和 JVM 启动流程（第四章）高度重叠，建议先写第四章再写第十一章，避免重复。
> - `15b-stub-routines-HandWritten.md` 建议在 `15-interpreter-HandWritten.md` 之后立即写，两者强依赖。
> - `21b-osr-HandWritten.md` 必须在 `21-deopt-HandWritten.md` 之后写，OSR 和逆优化是一对。

---

## 每篇文档的质量标准

### 必须包含

- [ ] **第一人称叙事**：用"我以为..."、"我踩的坑"、"我没想到"等表达
- [ ] **学习时间线**：按"第零天→第N天"组织，不是按"第0部分→第N部分"
- [ ] **真实踩坑**：每个知识点都从"误解"出发，而不是直接给出正确答案
- [ ] **数据结构补课节**：仿 Redis 文档的"第一天半"，诚实说"我第N天看算法时发现自己对某些字段没概念，回来补课"
- [ ] **插桩验证节**：用实际数据打脸自己的猜测，列出"猜测 vs 实测"对比表
- [ ] **还没搞懂的地方**：诚实列出 TODO，不要假装全懂了
- [ ] **Mermaid 图**：至少一张，串联全文的数据结构关系或流程

### 禁止

- ❌ 第三人称技术报告语气（"ObjectMonitor 包含以下字段..."）
- ❌ 预设模板结构（"第0部分：核心原理"、"第1部分：数据结构"）
- ❌ 假装一次就搞懂了（不能没有"我以为..."的误解起点）
- ❌ 只列字段不讲踩坑（数据结构要在"踩坑"的语境下出现）

---

## 插桩数据库（Instrumentation/）

> **这是整个手写笔记"第五天：插桩验证"节的核心数据来源。**  
> 每篇手写笔记的"猜测 vs 实测"对比表，数据都来自这里。

`Instrumentation/` 目录包含 22 个插桩探针结果文件，覆盖 JVM 各核心模块：

| 文件 | 对应手写笔记章节 | 核心数据 |
|------|----------------|---------|
| `00-Instrumentation-Master-Outline.md` | 全局 | 所有探针的总索引，写新探针前必看 |
| `01-JVM-Startup-Probe-Plan.md` / `02-JVM-Startup-Probe-Results.md` | 第四章 `12-jvm-startup` | create_vm 各 Phase 耗时、线程数量 |
| `03-ObjectAlloc-Probe-Results.md` | 第二章 `06-object-alloc` | TLAB 分配比例、慢速分配触发频率 |
| `04-YoungGC-Probe-Results.md` | 第七章 `24-g1-young-gc` | Young GC 各阶段耗时、疏散对象数量 |
| `04B-WriteBarrier-Probe-Results.md` | 第七章 `25-g1-rset` | 写屏障触发次数、CardTable 更新频率 |
| `04C-ConcMark-Probe-Results.md` | 第七章 `26-g1-concurrent-mark` | 并发标记各阶段耗时、SATB 队列大小 |
| `04D-MixedGC-Probe-Results.md` | 第七章 `27-g1-mixed-gc` | Mixed GC 回收集大小、预测模型误差 |
| `05-JIT-Probe-Results.md` | 第六章 `18-compilation-trigger` | 编译触发阈值、C1/C2 编译次数 |
| `05B-OSR-Probe-Results.md` | 第六章 `21b-osr` | OSR 触发次数、循环计数器阈值 |
| `05C-Deoptimization-Probe-Results.md` / `05C-Deopt-Probe-Results.md` | 第六章 `21-deopt` | 逆优化次数、uncommon trap 触发原因 |
| `05D-TemplateInterpreter-Probe-Results.md` | 第五章 `15-interpreter` | 字节码执行次数、分发表大小 |
| `06-Safepoint-Probe-Results.md` | 第八章 `28-safepoint` | STW 时间、各线程到达安全点的时间分布 |
| `07-Synchronization-Deep-Dive.md` | 第一章 `01-synchronized` | sizeof=216、_owner 偏移 128、锁升级次数 |
| `08-ThreadLifecycle-Probe.md` | 第四章 `14-thread-lifecycle` | 线程状态转换次数、OSThread 创建耗时 |
| `09-Signal-Probe-Results.md` | 第十一章 `35-libjsig` | 信号注册链长度、JVM 占用的信号列表 |
| `10-Attach-Probe-Results.md` | 第十二章 `38-arthas-attach` | attach 耗时、UNIX socket 创建时机 |
| `11-Handshake-Probe.md` | 第八章 `29b-handshake` | Handshake vs Safepoint 开销对比 |
| `12-Metaspace-Probe.md` | 第十章 `33-metaspace` | Metaspace 使用量、Chunk 大小分布 |
| `13-CodeCache-Sweeper-Probe.md` | 第十章 `33b-codecache` | CodeCache 使用量、nmethod 生命周期 |
| `17-JMM-Barrier-Probe.md` | 第九章 `31-volatile` | 内存屏障指令数量、volatile 读写开销 |

**使用方式**：写每篇手写笔记的"插桩验证"节时，先查这里有没有对应的探针数据，有则直接引用，没有则需要新增探针。先看 `00-Instrumentation-Master-Outline.md` 总索引，再找具体文件。

---

## 和现有文档的关系

**手写笔记不是替代现有文档，而是补充。**

- 现有文档：完整的参考手册，适合查阅
- 手写笔记：学习过程的记录，适合理解
- 插桩数据库（`Instrumentation/`）：实验数据，支撑手写笔记的"猜测 vs 实测"

三者关系：
```
手写笔记（学习过程）
    ↓ 引用
现有文档（参考手册）+ 插桩数据库（实验数据）
```

两者可以互相引用：
- 手写笔记里说"详细字段分析见 `../JVM-Core-Objects/05-ObjectMonitor-Deep-Dive.md`"
- 手写笔记里说"实测数据见 `../Instrumentation/07-Synchronization-Deep-Dive.md`"
- 现有文档里说"学习路线参考 `../new-md/01-synchronized-HandWritten.md`"

---

*大纲制定日期：2026-03-06*  
*参考风格：`/data/workspace/redis-7.0/src/md/cluster/Cluster-HandWritten.md`*
