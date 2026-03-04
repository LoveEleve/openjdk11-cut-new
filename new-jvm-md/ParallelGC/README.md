# Parallel GC 深度解析专题

> 基于 OpenJDK 11 源码分析  
> 源码路径：`src/hotspot/share/gc/parallel/`  
> JDK 8 默认垃圾回收器，JDK 9+ 仍然可用（`-XX:+UseParallelGC`）

---

## 为什么要专门学 Parallel GC？

很多人认为 Parallel GC 是"老旧"的 GC，不值得深入学习。这是一个误区：

1. **JDK 8 至今仍是最广泛部署的 JDK 版本**，大量生产环境跑的就是 Parallel GC
2. **Parallel GC 的 Full GC 算法（PSParallelCompact）是 JVM 中最精妙的压缩算法之一**，其 Summary Phase 的 Region 密度计算思想在学术界也有重要地位
3. **自适应策略（PSAdaptiveSizePolicy）是理解 JVM 自动调优的基础**，G1 的策略设计也借鉴了它的思想
4. **理解 Parallel GC 是理解 GC 演进史的关键**：Serial → Parallel → CMS → G1 → ZGC，每一步都是对前一步问题的回答

---

## ⚠️ 重要：两种 Full GC 实现

Parallel GC 有**两套 Full GC 实现**，这是大纲中最容易遗漏的关键点：

| 实现 | 源码 | 启用条件 | 算法 |
|------|------|---------|------|
| **PSParallelCompact** | `psParallelCompact.cpp`（128KB） | `-XX:+UseParallelOldGC`（JDK 7+ 默认开启） | 三阶段并行压缩（Marking→Summary→Compact） |
| **PSMarkSweep** | `psMarkSweep.cpp`（24KB） | `-XX:-UseParallelOldGC`（禁用 ParallelOld 时） | 四阶段串行 Mark-Sweep-Compact（继承自 Serial GC 的 MarkSweep） |

**绝大多数情况下用的是 PSParallelCompact**，但 PSMarkSweep 作为备用路径必须了解。

---

## 文档体系总览

```
ParallelGC/
├── README.md                           ← 本文件（目录索引）
│
├── 01-Overview-and-Architecture.md     ← 整体架构与设计哲学
├── 02-Heap-Initialization.md           ← 堆初始化：从参数到内存布局
├── 03-Heap-DataStructures.md           ← 堆数据结构全景（核心类完整字段分析）
├── 04-Object-Allocation.md             ← 对象分配路径（TLAB→Eden→Old）
├── 05-Young-GC-PSScavenge.md           ← Young GC 完整流程（PSScavenge）
├── 06-Full-GC-PSParallelCompact.md     ← Full GC 三阶段（PSParallelCompact）⭐ 最核心
├── 07-Full-GC-PSMarkSweep.md           ← Full GC 备用路径（PSMarkSweep 四阶段）
├── 08-AdaptiveSizePolicy.md            ← 自适应大小策略（PSAdaptiveSizePolicy）
├── 09-GCTaskManager.md                 ← 并行任务调度系统（GCTaskManager）
├── 10-CardTable-and-RemSet.md          ← 卡表与跨代引用（PSCardTable）
├── 11-NUMA-Aware-Allocation.md         ← NUMA 感知分配（MutableNUMASpace）
├── 12-GC-Log-and-Tuning.md             ← GC 日志解读与调优
└── 13-Comparison-with-G1.md            ← 与 G1 的深度对比
│
└── tmp-file/                           ← GDB 验证脚本
    ├── verify-heap-layout.gdb
    ├── verify-young-gc.gdb
    ├── verify-full-gc-parallel-compact.gdb
    └── verify-full-gc-mark-sweep.gdb
```

---

## 各篇文档内容速览

### 01 - 整体架构与设计哲学 ✅
- Parallel GC 解决什么问题（Serial GC 的瓶颈在哪）
- 核心设计：多线程并行 + 自适应策略
- 堆结构总览：`ParallelScavengeHeap` = `PSYoungGen` + `PSOldGen`
- 两种 GC 的触发条件与选择逻辑
- 与 Serial/CMS/G1 的定位对比

### 02 - 堆初始化
- `ParallelArguments::initialize()`：参数校验与默认值设置
- `ParallelArguments::create_heap()`：堆对象创建入口
- `ParallelScavengeHeap::initialize()`：完整初始化流程
- `AdjoiningGenerations`：年轻代与老年代共享虚拟地址空间的边界管理
- `AdjoiningVirtualSpaces`：两个相邻虚拟空间的协调扩缩
- `GenerationSizer`：根据参数计算各代初始/最小/最大大小
- `VM_ParallelGCFailedAllocation` / `VM_ParallelGCSystemGC`：GC 触发的 VM 操作封装

### 03 - 堆数据结构全景
- `ParallelScavengeHeap`：顶层堆对象，完整字段分析
- `PSYoungGen` / `ASPSYoungGen`：年轻代（普通版 vs 自适应版）
- `PSOldGen` / `ASPSOldGen`：老年代（普通版 vs 自适应版）
- `ImmutableSpace`：不可变空间基类（`_bottom` + `_end`）
- `MutableSpace`：可变空间（继承 ImmutableSpace，增加 `_top`）
- `PSVirtualSpace`：虚拟内存管理（reserved vs committed）
- `ObjectStartArray`：Full GC 压缩时的对象起始位置索引

### 04 - 对象分配路径
- TLAB 快速路径：`CollectedHeap::allocate_from_tlab()`
- Eden 慢速路径：`PSYoungGen::allocate()`
- NUMA 感知路径：`MutableNUMASpace::allocate()`（`-XX:+UseNUMA` 时）
- 大对象直接进 Old：`PSOldGen::cas_allocate()`
- 分配失败触发 GC 的完整链路：`VM_ParallelGCFailedAllocation`

### 05 - Young GC（PSScavenge）完整流程
- 入口：`PSScavenge::invoke_no_policy()`（`psScavenge.cpp:236`）
- 根扫描：`ScavengeRootsTask`（`psTasks.cpp`）
- 对象复制：`PSPromotionManager` + PLAB 机制（`psPromotionLAB.cpp`）
- 晋升失败（Promotion Failure）处理
- Survivor 空间管理与年龄阈值

### 06 - Full GC（PSParallelCompact）完整流程 ⭐ 最核心
- 入口：`PSParallelCompact::invoke_no_policy()`（`psParallelCompact.cpp:1719`）
- **Phase 1 - Marking**：并行标记所有存活对象，写入 `ParMarkBitMap`
- **Phase 2 - Summary**：计算每个 Region 的压缩目标地址（最精妙的部分）
  - `RegionData`：每个 Region 的统计信息（存活字节数、目标地址等）
  - `DeadWoodLimiter`：决定哪些 Region 值得压缩（`ParallelOldDeadWoodLimiterMean/StdDev`）
  - Dense prefix 计算：找到不需要移动的前缀区域
- **Phase 3 - Compact**：并行压缩，`PSCompactionManager` 负责对象移动
  - `pcTasks.cpp`：Full GC 并行任务（`DrainStacksCompactionTask` 等）
- `PSMarkSweepProxy`：Full GC 实现的代理选择器

### 07 - Full GC 备用路径（PSMarkSweep）
- 触发条件：`-XX:-UseParallelOldGC` 时使用
- 继承自 Serial GC 的 `MarkSweep`：四阶段实现
  - Phase 1：标记（`mark_sweep_phase1`）
  - Phase 2：计算新地址（`mark_sweep_phase2`）
  - Phase 3：更新指针（`mark_sweep_phase3`）
  - Phase 4：移动对象（`mark_sweep_phase4`）
- `PSMarkSweepDecorator`：为 Parallel GC 的空间适配 MarkSweep 算法
- `absorb_live_data_from_eden()`：GC 后尝试将 Eden 存活对象吸收进 Old
- 与 PSParallelCompact 的对比：单线程 vs 多线程，四阶段 vs 三阶段

### 08 - 自适应大小策略（PSAdaptiveSizePolicy）
- 自适应策略解决什么问题
- 核心数据：GC 时间比例、吞吐量目标
- Eden/Survivor/Old 大小的动态调整算法
- `PSAdaptiveSizePolicy::compute_eden_space_size()` 详解
- `gcAdaptivePolicyCounters` / `psGCAdaptivePolicyCounters`：性能计数器
- 相关 JVM 参数：`-XX:GCTimeRatio`、`-XX:AdaptiveSizePolicyWeight`

### 09 - 并行任务调度系统（GCTaskManager）
- `GCTaskManager`：任务队列管理（`gcTaskManager.cpp`，34KB）
- `GCTaskThread`：GC 工作线程（`gcTaskThread.cpp`）
- `GCTask` 类型体系：`ScavengeRootsTask`、`DrainStacksCompactionTask` 等
- 任务分发与负载均衡
- 与 G1 的 `WorkGang` 对比

### 10 - 卡表与跨代引用（PSCardTable）
- `PSCardTable` 的结构（`psCardTable.cpp`，26KB）
- 写屏障实现
- Young GC 时如何扫描 Old→Young 引用
- 卡表扫描优化

### 11 - NUMA 感知分配（MutableNUMASpace）⭐ 容易遗漏
- 为什么需要 NUMA 感知：跨 NUMA 节点访问内存的性能损失
- `MutableNUMASpace`：将 Eden 按 NUMA 节点分割成多个 `LGRPSpace`
- `LGRPSpace`：每个 NUMA 节点的本地空间（含 `AdaptiveWeightedAverage` 分配率统计）
- 自适应 chunk 大小：根据各节点分配率动态调整 chunk 大小
- Page Scanner：扫描并释放"远端页"（remote pages）
- 启用参数：`-XX:+UseNUMA`
- 与普通 `MutableSpace` 的对比

### 12 - GC 日志解读与调优
- 开启 GC 日志：`-Xlog:gc*:file=gc.log:time,uptime,level,tags`
- Young GC 日志格式解读
- Full GC 日志格式解读（PSParallelCompact 三阶段各自的日志）
- 常见性能问题诊断
- 关键调优参数速查表（含 `parallel_globals.hpp` 中的所有参数）

### 13 - 与 G1 的深度对比
- 堆结构对比：连续分代 vs Region 化
- Young GC 对比：PSScavenge vs G1YoungGC
- Full GC 对比：PSParallelCompact vs G1FullGC
- 自适应策略对比
- 适用场景：什么时候用 Parallel，什么时候用 G1

---

## 完整源码文件索引（共 40 个文件）

### 堆结构与初始化（8 个文件）

| 源码文件 | 大小 | 对应文档 | 核心内容 |
|---------|------|---------|---------|
| `parallelArguments.cpp/hpp` | 3.7KB | 02 | GC 参数初始化，`create_heap()` 入口 |
| `parallelScavengeHeap.cpp/hpp` | 38KB | 02, 03, 04 | 顶层堆对象，GC 触发入口 |
| `parallelScavengeHeap.inline.hpp` | 2.2KB | 03 | 内联方法 |
| `adjoiningGenerations.cpp/hpp` | 14.6KB | 02 | 年轻代/老年代共享虚拟空间的边界管理 |
| `adjoiningVirtualSpaces.cpp/hpp` | 7.2KB | 02 | 两个相邻虚拟空间的协调扩缩 |
| `generationSizer.cpp/hpp` | 4.2KB | 02 | 根据参数计算各代大小 |
| `vmPSOperations.cpp/hpp` | 4.7KB | 02, 04 | GC 触发的 VM 操作封装 |
| `parallel_globals.hpp` | 5.3KB | 12 | 所有 Parallel GC 专属 JVM 参数定义 |

### 空间与内存管理（8 个文件）

| 源码文件 | 大小 | 对应文档 | 核心内容 |
|---------|------|---------|---------|
| `immutableSpace.cpp/hpp` | 5.1KB | 03 | 不可变空间基类（`_bottom` + `_end`） |
| `mutableSpace.cpp/hpp` | 15KB | 03, 04 | 可变空间（增加 `_top`，bump-pointer 分配） |
| `mutableNUMASpace.cpp/hpp` | 47.5KB | 11 | NUMA 感知分配（最大的空间实现！） |
| `psVirtualspace.cpp/hpp` | 17.6KB | 03 | 虚拟内存管理（reserved vs committed） |
| `psYoungGen.cpp/hpp` | 43.1KB | 03, 05 | 年轻代（Eden+From+To） |
| `asPSYoungGen.cpp/hpp` | 24.6KB | 03, 08 | 自适应大小年轻代（继承 PSYoungGen） |
| `psOldGen.cpp/hpp` | 25.9KB | 03, 06 | 老年代 |
| `asPSOldGen.cpp/hpp` | 9.3KB | 03, 08 | 自适应大小老年代（继承 PSOldGen） |

### Young GC（5 个文件）

| 源码文件 | 大小 | 对应文档 | 核心内容 |
|---------|------|---------|---------|
| `psScavenge.cpp/hpp` | 35.9KB | 05 | Young GC 核心实现 |
| `psScavenge.inline.hpp` | 5.5KB | 05 | 内联方法 |
| `psPromotionManager.cpp/hpp` | 26.1KB | 05 | 对象晋升管理 |
| `psPromotionManager.inline.hpp` | 13KB | 05 | 内联方法 |
| `psPromotionLAB.cpp/hpp` | 9.6KB | 05 | 晋升本地分配缓冲区（PLAB） |
| `psPromotionLAB.inline.hpp` | 2KB | 05 | 内联方法 |
| `psTasks.cpp/hpp` | 10.8KB | 05, 09 | Young GC 并行任务 |

### Full GC - PSParallelCompact（6 个文件）

| 源码文件 | 大小 | 对应文档 | 核心内容 |
|---------|------|---------|---------|
| `psParallelCompact.cpp/hpp` | **179KB** | 06 | Full GC 核心实现（最大文件！） |
| `psParallelCompact.inline.hpp` | 5.1KB | 06 | 内联方法 |
| `parMarkBitMap.cpp/hpp` | 17.5KB | 06 | 并行标记位图 |
| `parMarkBitMap.inline.hpp` | 7KB | 06 | 内联方法 |
| `psCompactionManager.cpp/hpp` | 17.2KB | 06 | 压缩管理器 |
| `psCompactionManager.inline.hpp` | 5.2KB | 06 | 内联方法 |
| `pcTasks.cpp/hpp` | 14KB | 06, 09 | Full GC 并行任务 |
| `objectStartArray.cpp/hpp` | 11.1KB | 06 | 对象起始位置索引 |
| `objectStartArray.inline.hpp` | 2.1KB | 06 | 内联方法 |

### Full GC - PSMarkSweep（2 个文件）

| 源码文件 | 大小 | 对应文档 | 核心内容 |
|---------|------|---------|---------|
| `psMarkSweep.cpp/hpp` | 27.5KB | 07 | Full GC 备用实现（串行 Mark-Sweep-Compact） |
| `psMarkSweepDecorator.cpp/hpp` | 17.1KB | 07 | 为 Parallel GC 空间适配 MarkSweep |
| `psMarkSweepProxy.hpp` | 2.5KB | 07 | Full GC 实现的代理选择器 |

### 自适应策略（3 个文件）

| 源码文件 | 大小 | 对应文档 | 核心内容 |
|---------|------|---------|---------|
| `psAdaptiveSizePolicy.cpp/hpp` | 62.5KB | 08 | 自适应大小策略（**第二大文件**！） |
| `gcAdaptivePolicyCounters.cpp/hpp` | 17.6KB | 08 | 通用自适应策略性能计数器 |
| `psGCAdaptivePolicyCounters.cpp/hpp` | 16.1KB | 08 | PS 专属自适应策略性能计数器 |

### 并行任务调度（2 个文件）

| 源码文件 | 大小 | 对应文档 | 核心内容 |
|---------|------|---------|---------|
| `gcTaskManager.cpp/hpp` | 56.5KB | 09 | 并行任务调度（**第三大文件**！） |
| `gcTaskThread.cpp/hpp` | 10.1KB | 09 | GC 工作线程 |

### 卡表（1 个文件）

| 源码文件 | 大小 | 对应文档 | 核心内容 |
|---------|------|---------|---------|
| `psCardTable.cpp/hpp` | 30.9KB | 10 | 卡表实现 |

### 其他（4 个文件）

| 源码文件 | 大小 | 对应文档 | 核心内容 |
|---------|------|---------|---------|
| `psMemoryPool.cpp/hpp` | 6.8KB | 12 | 内存池（JMX 监控用） |
| `psGenerationCounters.cpp/hpp` | 4.8KB | 12 | 代计数器（JMX 监控用） |
| `spaceCounters.cpp/hpp` | 5.4KB | 12 | 空间计数器（JMX 监控用） |
| `jvmFlagConstraintsParallel.cpp/hpp` | 4.6KB | 12 | JVM 参数约束检查 |
| `vmStructs_parallelgc.hpp` | 8.7KB | 03 | 暴露给 SA/HSDB 调试工具的结构体信息 |

---

## 学习路径建议

```
入门路径（理解 Parallel GC 是什么）：
  01 → 03 → 12

标准路径（理解 Young GC + Full GC）：
  01 → 02 → 03 → 04 → 05 → 06

深度路径（理解所有机制）：
  01 → 02 → 03 → 04 → 05 → 06 → 07 → 08 → 09 → 10 → 11 → 12 → 13

对比学习路径（已学 G1，补充 Parallel）：
  01 → 06 → 08 → 13

NUMA 专项路径：
  03（MutableSpace）→ 11（MutableNUMASpace）→ 04（分配路径）
```

---

## 关键问题导航

| 问题 | 看哪篇 |
|------|--------|
| Parallel GC 的堆长什么样？ | 03 |
| 堆是怎么初始化的？年轻代和老年代怎么共享虚拟空间？ | 02 |
| 对象是怎么分配的？ | 04 |
| Young GC 怎么触发？怎么执行？ | 05 |
| Full GC 的三个阶段是什么？ | 06 |
| Summary Phase 的 Region 密度算法是什么？ | 06 |
| PSMarkSweep 和 PSParallelCompact 有什么区别？ | 07 |
| JVM 怎么自动调整堆大小？ | 08 |
| GC 线程是怎么并行工作的？ | 09 |
| 跨代引用怎么处理？ | 10 |
| NUMA 机器上怎么优化内存分配？ | 11 |
| GC 日志怎么看？ | 12 |
| 什么时候用 Parallel，什么时候用 G1？ | 13 |

---

## 进度追踪

- [x] 01 - 整体架构与设计哲学
- [x] 02 - 堆初始化（AdjoiningGenerations + ParallelArguments）
- [x] 03 - 堆数据结构全景
- [x] 04 - 对象分配路径
- [x] 05 - Young GC（PSScavenge）完整流程
- [x] 06 - Full GC（PSParallelCompact）完整流程 ⭐
- [ ] 07 - Full GC 备用路径（PSMarkSweep）
- [ ] 08 - 自适应大小策略（PSAdaptiveSizePolicy）
- [ ] 09 - 并行任务调度系统（GCTaskManager）
- [ ] 10 - 卡表与跨代引用（PSCardTable）
- [ ] 11 - NUMA 感知分配（MutableNUMASpace）
- [ ] 12 - GC 日志解读与调优
- [ ] 13 - 与 G1 的深度对比
