# GC 系统 (Garbage Collection) 重要文件

> **源码路径**：`src/hotspot/share/gc/`  
> **重要程度**：⭐⭐⭐⭐⭐

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文是 **GC 系统 (Garbage Collection) 重要文件** 的源码导航地图：列出该模块最重要的源码文件，说明每个文件的核心职责，帮助快速定位关键代码。

### 0.2 为什么需要？

JVM 源码体量庞大（HotSpot 约 200 万行），直接阅读容易迷失。有一份「重要文件地图」，能让学习者快速找到核心代码，避免在次要代码上浪费时间。

### 0.3 怎么解决？

按功能模块分类整理源码文件，标注每个文件的重要程度（⭐ 数量）和核心职责，并指出文件间的依赖关系。

### 0.4 为什么这样设计？

优先级排序基于「对理解 JVM 核心行为的贡献度」：直接影响 GC/JIT/类加载等核心机制的文件优先级最高。

---


## GC 基础设施 (Shared)

### 堆抽象基类

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `shared/collectedHeap.cpp` | ⭐⭐⭐⭐⭐ | 堆抽象基类，定义 GC 接口 |
| `shared/collectedHeap.hpp` | ⭐⭐⭐⭐⭐ | 堆接口定义 |
| `shared/collectedHeap.inline.hpp` | ⭐⭐⭐⭐ | 堆内联函数 |

### 引用处理

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `shared/referenceProcessor.cpp` | ⭐⭐⭐⭐⭐ | 引用处理实现 |
| `shared/referenceProcessor.hpp` | ⭐⭐⭐⭐⭐ | 引用处理器接口 |
| `shared/referencePendingListLocker.cpp` | ⭐⭐⭐ | 待处理引用列表锁 |
| `shared/referencePolicy.cpp` | ⭐⭐⭐⭐ | 引用策略（Soft/Weak/Phantom） |

### 内存管理

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `shared/cardTable.cpp` | ⭐⭐⭐⭐⭐ | 卡表实现 |
| `shared/cardTable.hpp` | ⭐⭐⭐⭐⭐ | 卡表接口 |
| `shared/blockOffsetTable.cpp` | ⭐⭐⭐⭐ | 块偏移表 |
| `shared/blockOffsetTable.hpp` | ⭐⭐⭐⭐ | BOT 接口 |
| `shared/memRegion.cpp` | ⭐⭐⭐⭐ | 内存区域抽象 |
| `shared/memRegion.hpp` | ⭐⭐⭐⭐ | 内存区域接口 |

### 并行任务框架

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `shared/taskqueue.cpp` | ⭐⭐⭐⭐⭐ | GC 任务队列 |
| `shared/taskqueue.hpp` | ⭐⭐⭐⭐⭐ | 任务队列接口 |
| `shared/workgroup.hpp` | ⭐⭐⭐⭐⭐ | 工作组框架 |
| `shared/workgroup.cpp` | ⭐⭐⭐⭐ | 工作组实现 |
| `shared/parallelTaskTerminator.cpp` | ⭐⭐⭐⭐ | 并行任务终止协议 |

### TLAB

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `shared/threadLocalAllocBuffer.hpp` | ⭐⭐⭐⭐⭐ | TLAB 实现 |
| `shared/threadLocalAllocBuffer.inline.hpp` | ⭐⭐⭐⭐ | TLAB 内联 |
| `shared/tlab_Stats.cpp` | ⭐⭐⭐ | TLAB 统计 |

---

## G1 GC

### 核心

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `g1/g1CollectedHeap.cpp` | ⭐⭐⭐⭐⭐ | G1 堆实现，核心 GC 算法 |
| `g1/g1CollectedHeap.hpp` | ⭐⭐⭐⭐⭐ | G1CollectedHeap 类定义 |
| `g1/g1HeapRegionManager.cpp` | ⭐⭐⭐⭐⭐ | 堆区域管理器 |
| `g1/heapRegion.cpp` | ⭐⭐⭐⭐⭐ | 单个堆区域实现 |
| `g1/heapRegion.hpp` | ⭐⭐⭐⭐⭐ | HeapRegion 类定义 |

### 策略与决策

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `g1/g1Policy.cpp` | ⭐⭐⭐⭐⭐ | G1 收集策略实现 |
| `g1/g1Policy.hpp` | ⭐⭐⭐⭐⭐ | G1Policy 接口 |
| `g1/g1CollectorPolicy.cpp` | ⭐⭐⭐⭐⭐ | GC 策略参数配置 |
| `g1/g1Analytics.cpp` | ⭐⭐⭐⭐ | GC 统计分析 |
| `g1/g1Predictions.cpp` | ⭐⭐⭐⭐ | 停顿时间预测模型 |

### 并发标记

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `g1/g1ConcurrentMark.cpp` | ⭐⭐⭐⭐⭐ | 并发标记算法实现 |
| `g1/g1ConcurrentMark.hpp` | ⭐⭐⭐⭐⭐ | 并发标记接口 |
| `g1/g1ConcurrentMarkThread.cpp` | ⭐⭐⭐⭐⭐ | 并发标记线程 |
| `g1/g1ConcurrentMarkThread.hpp` | ⭐⭐⭐⭐⭐ | CMThread 接口 |
| `g1/g1CMTask.cpp` | ⭐⭐⭐⭐⭐ | 并发标记任务 |
| `g1/g1CMTask.hpp` | ⭐⭐⭐⭐⭐ | CMTask 接口 |

### 记忆集 (RSet)

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `g1/g1RemSet.cpp` | ⭐⭐⭐⭐⭐ | 记忆集实现 |
| `g1/g1RemSet.hpp` | ⭐⭐⭐⭐⭐ | RSet 接口 |
| `g1/g1CardTable.cpp` | ⭐⭐⭐⭐ | G1 卡表 |
| `g1/g1HotCardCache.cpp` | ⭐⭐⭐⭐ | 热卡缓存 |
| `g1/g1ConcurrentRefine.cpp` | ⭐⭐⭐⭐⭐ | 并发精炼 |
| `g1/g1ConcurrentRefineThread.cpp` | ⭐⭐⭐⭐⭐ | 并发精炼线程 |

### 收集集合

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `g1/g1CollectionSet.cpp` | ⭐⭐⭐⭐⭐ | 收集集合管理 |
| `g1/g1CollectionSet.hpp` | ⭐⭐⭐⭐⭐ | CSet 接口 |
| `g1/collectionSetChooser.cpp` | ⭐⭐⭐⭐ | 老年代区域选择 |
| `g1/g1InCSetState.cpp` | ⭐⭐⭐⭐ | CSet 状态快速测试 |

### 对象复制

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `g1/g1ParScanThreadState.cpp` | ⭐⭐⭐⭐⭐ | 并行扫描线程状态 |
| `g1/g1ParScanThreadState.hpp` | ⭐⭐⭐⭐⭐ | PSS 接口 |
| `g1/g1ParScanClosure.cpp` | ⭐⭐⭐⭐ | 并行扫描闭包 |
| `g1/g1EvacFailure.cpp` | ⭐⭐⭐⭐ | 疏散失败处理 |

### 根扫描

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `g1/g1RootProcessor.cpp` | ⭐⭐⭐⭐⭐ | GC 根节点处理器 |
| `g1/g1RootProcessor.hpp` | ⭐⭐⭐⭐⭐ | 根处理接口 |

### Full GC

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `g1/g1FullCollector.cpp` | ⭐⭐⭐⭐⭐ | Full GC 收集器实现 |
| `g1/g1FullGCCompactionPoint.cpp` | ⭐⭐⭐⭐ | Full GC 压缩点 |
| `g1/g1FullGCMarker.cpp` | ⭐⭐⭐⭐ | Full GC 标记 |
| `g1/g1FullGCObjectClosure.cpp` | ⭐⭐⭐⭐ | Full GC 对象闭包 |

### 其他 G1 组件

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `g1/g1GCPhaseTimes.cpp` | ⭐⭐⭐⭐ | GC 阶段时间统计 |
| `g1/g1GCPhaseTimes.hpp` | ⭐⭐⭐⭐ | 阶段时间接口 |
| `g1/g1MonitoringSupport.cpp` | ⭐⭐⭐⭐ | 监控支持 |
| `g1/g1MMUTracker.cpp` | ⭐⭐⭐⭐ | MMU 跟踪器 |
| `g1/g1AllocRegion.cpp` | ⭐⭐⭐⭐ | 分配区域管理 |
| `g1/g1 SurvivorPlabClosure.cpp` | ⭐⭐⭐⭐ | Survivor PLAB 闭包 |

---

## Serial GC (DefNew + Tenured)

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `serial/defNewGeneration.cpp` | ⭐⭐⭐⭐ | 新生代实现 (Serial Copying) |
| `serial/defNewGeneration.hpp` | ⭐⭐⭐⭐ | DefNewGeneration 接口 |
| `serial/tenuredGeneration.cpp` | ⭐⭐⭐⭐ | 老年代实现 |
| `serial/genMarkSweep.cpp` | ⭐⭐⭐⭐ | 标记-整理算法 |
| `serial/genMarkSweep.hpp` | ⭐⭐⭐⭐ | MarkSweep 接口 |
| `serial/serialHeap.cpp` | ⭐⭐⭐⭐ | Serial 堆实现 |
| `serial/serialHeap.hpp` | ⭐⭐⭐⭐ | SerialHeap 接口 |

---

## Parallel GC (PS)

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `parallel/parallelScavengeHeap.cpp` | ⭐⭐⭐⭐⭐ | Parallel Scavenge 堆实现 |
| `parallel/parallelScavengeHeap.hpp` | ⭐⭐⭐⭐⭐ | PSHeap 接口 |
| `parallel/psYoungGen.cpp` | ⭐⭐⭐⭐ | 年轻代并行收集 |
| `parallel/psOldGen.cpp` | ⭐⭐⭐⭐ | 老年代并行收集 |
| `parallel/psScavenge.cpp` | ⭐⭐⭐⭐⭐ | Young GC 实现 |
| `parallel/psParallelCompact.cpp` | ⭐⭐⭐⭐⭐ | 并行压缩算法 |
| `parallel/psMarkSweep.cpp` | ⭐⭐⭐⭐ | 标记-整理 |
| `parallel/gcTaskManager.cpp` | ⭐⭐⭐⭐ | GC 任务管理器 |
| `parallel/psAdaptiveSizePolicy.cpp` | ⭐⭐⭐⭐ | 自适应大小策略 |
| `parallel/psPromotionManager.cpp` | ⭐⭐⭐⭐ | 提升管理器 |
| `parallel/psOldGen.cpp` | ⭐⭐⭐⭐ | 老年代管理 |

---

## CMS GC

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `cms/concurrentMarkSweepGeneration.cpp` | ⭐⭐⭐⭐⭐ | CMS 老年代收集器核心实现 |
| `cms/concurrentMarkSweepGeneration.hpp` | ⭐⭐⭐⭐⭐ | CMS 接口 |
| `cms/parNewGeneration.cpp` | ⭐⭐⭐⭐ | ParNew 年轻代收集器 |
| `cms/compactibleFreeListSpace.cpp` | ⭐⭐⭐⭐ | 空闲列表空间管理 |
| `cms/cmsCardTable.cpp` | ⭐⭐⭐⭐ | CMS 卡表实现 |
| `cms/concurrentMarkSweepThread.cpp` | ⭐⭐⭐⭐ | CMS 线程 |
| `cms/parMarkBitMap.cpp` | ⭐⭐⭐⭐ | 并行标记位图 |

---

## ZGC

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `z/zCollectedHeap.cpp` | ⭐⭐⭐⭐⭐ | ZGC 堆实现 |
| `z/zCollectedHeap.hpp` | ⭐⭐⭐⭐⭐ | ZGC 堆接口 |
| `z/zDirector.cpp` | ⭐⭐⭐⭐ | GC 触发决策器 |
| `z/zDriver.cpp` | ⭐⭐⭐⭐ | GC 执行驱动 |
| `z/zHeap.cpp` | ⭐⭐⭐⭐⭐ | ZGC 堆管理 |
| `z/zMark.cpp` | ⭐⭐⭐⭐⭐ | 并发标记实现 |
| `z/zMark.inline.hpp` | ⭐⭐⭐⭐⭐ | 标记内联 |
| `z/zReferenceProcessor.cpp` | ⭐⭐⭐⭐⭐ | 引用处理器 |
| `z/zRelocate.cpp` | ⭐⭐⭐⭐⭐ | 迁移/重定位实现 |
| `z/zRelocationSelector.cpp` | ⭐⭐⭐⭐ | 重定位选择器 |
| `z/zPage.cpp` | ⭐⭐⭐⭐ | 页面管理 |
| `z/zPageTable.cpp` | ⭐⭐⭐⭐ | 页表 |
| `z/zBarrier.cpp` | ⭐⭐⭐⭐⭐ | 屏障实现 |
| `z/zBarrierSet.cpp` | ⭐⭐⭐⭐⭐ | 屏障集 |

---

## Epsilon GC

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `epsilon/epsilonHeap.cpp` | ⭐⭐⭐ | 无操作 GC |
| `epsilon/epsilonCollector.cpp` | ⭐⭐⭐ | 空收集器 |
| `epsilon/epsilonMemoryPool.cpp` | ⭐⭐⭐ | 内存池 |

---

## Shenandoah GC

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `shenandoah/shenandoahHeap.cpp` | ⭐⭐⭐⭐⭐ | Shenandoah 堆实现 |
| `shenandoah/shenandoahConcurrentMark.cpp` | ⭐⭐⭐⭐⭐ | 并发标记 |
| `shenandoah/shenandoahControlThread.cpp` | ⭐⭐⭐⭐⭐ | GC 控制线程 |
| `shenandoah/shenandoahMarkCompact.cpp` | ⭐⭐⭐⭐ | 标记-压缩 |
| `shenandoah/shenandoahFreeSet.cpp` | ⭐⭐⭐⭐ | 空闲内存集合 |
| `shenandoah/shenandoahVerifier.cpp` | ⭐⭐⭐⭐ | 验证器 |
| `shenandoah/shenandoahBarrierSet.cpp` | ⭐⭐⭐⭐⭐ | 屏障集 |

---

## 核心调用链

### G1 Young GC
```
G1CollectedHeap::collect()
  → G1Policy::record_collection_pause_start()
  → G1CollectedHeap::gc_prologue()
  → G1CollectedHeap::allocate_dummy_regions()
  → G1CollectorPolicy::finalize_young_part()
  → G1RootProcessor::process_roots()
  → G1ParTask::work()
    → G1ParScanThreadState::copy_to_survivor_region()
  → G1CollectedHeap::gc_epilogue()
```

### G1 Concurrent Mark
```
G1ConcurrentMarkThread::run_service()
  → G1ConcurrentMark::mark_from_roots()
    → G1CMTask::do_marking_step()
  → G1ConcurrentMark::checkpoint_roots_final()
```

---

## 学习建议

1. **优先级 P0**：collectedHeap.cpp, g1CollectedHeap.cpp, g1Policy.cpp, g1RemSet.cpp, g1ConcurrentMark.cpp
2. **优先级 P1**：g1CollectionSet.cpp, heapRegion.cpp, g1ParScanThreadState.cpp, referenceProcessor.cpp
3. **优先级 P2**：其他 GC 实现（Serial, Parallel, CMS, ZGC, Shenandoah）

---

*GC 系统是 JVM 最复杂的模块之一，G1 GC 目前是默认收集器，需要重点掌握。*
