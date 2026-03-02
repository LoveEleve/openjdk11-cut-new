# G1 GC 数据结构全景地图

> **目标**：站在设计者角度，梳理 G1 GC 中所有核心数据结构/对象及其关系
> **原则**：程序 = 数据结构 + 算法。先搞清楚"有什么"，再搞清楚"怎么用"
> **源码目录**：`src/hotspot/share/gc/g1/`（195 个源文件：95 .hpp + 20 .inline.hpp + 80 .cpp）
> **标准环境**：-Xms8g -Xmx8g -XX:+UseG1GC，G1 Region = 4MB，2048 个 Region

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1 GC 数据结构全景地图的本质是**G1 内存管理体系的"骨架图"**：G1 的 195 个源文件背后，核心数据结构可以归纳为 6 大类——Region 管理（HeapRegion/HeapRegionManager）、写屏障与卡表（G1CardTable/DirtyCardQueue）、记忆集（HeapRegionRemSet/SparsePRT）、并发标记（G1ConcurrentMark/G1CMBitMap）、GC 策略（G1Policy/G1Analytics）、Evacuation（G1ParScanThreadState/G1AllocRegion）。

### 0.2 为什么需要全景地图？

G1 的复杂性在于各子系统高度耦合：写屏障→卡表→DirtyCardQueue→Concurrent Refinement→RSet→GC 策略→CSet 选择→Evacuation，每个环节都依赖前一个。没有全景地图，容易陷入"只见树木不见森林"的困境，无法理解各组件的协作关系。

### 0.3 六大类数据结构

| 类别 | 核心结构 | 作用 |
|------|---------|------|
| Region 管理 | `HeapRegion`, `HeapRegionManager` | 堆内存的基本单元和管理器 |
| 写屏障与卡表 | `G1CardTable`, `DirtyCardQueue`, `G1SATBMarkQueue` | 追踪引用修改 |
| 记忆集 | `HeapRegionRemSet`, `SparsePRT`, `PerRegionTable` | 跨 Region 引用索引 |
| 并发标记 | `G1ConcurrentMark`, `G1CMBitMap`, `G1CMTask` | 并发标记存活对象 |
| GC 策略 | `G1Policy`, `G1Analytics`, `G1Predictions` | 自适应决策 |
| Evacuation | `G1ParScanThreadState`, `G1AllocRegion`, `G1PLAB` | 对象复制 |

---

---

## 一、总览：G1 GC 的 8 大子系统

从设计者角度看，G1 GC 可以分为 **8 个子系统**，每个子系统解决一个核心问题：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          G1CollectedHeap (总控)                              │
├─────────────┬─────────────┬─────────────┬───────────────────────────────────┤
│  ① 堆内存   │ ② 分代管理   │ ③ 对象分配   │ ④ 写屏障 + RSet                  │
│  管理       │             │             │  (跨 Region 引用追踪)              │
├─────────────┼─────────────┼─────────────┼───────────────────────────────────┤
│  ⑤ 并发标记  │ ⑥ 回收策略   │ ⑦ 疏散回收   │ ⑧ Full GC                       │
│  (识别垃圾)  │ (选择目标)   │  (复制存活)  │  (兜底方案)                       │
└─────────────┴─────────────┴─────────────┴───────────────────────────────────┘
```

---

## 二、全部数据结构分层分类

### 重要程度标注

| 标记 | 含义 | 建议 |
|------|------|------|
| ⭐⭐⭐⭐⭐ | **核心中的核心** | 必须逐行分析，完全理解 |
| ⭐⭐⭐⭐ | **重要** | 需要深入理解字段含义和工作机制 |
| ⭐⭐⭐ | **中等** | 理解作用和接口即可 |
| ⭐⭐ | **辅助** | 知道存在和用途即可 |
| ⭐ | **工具/统计** | 按需了解 |

---

## 三、子系统①：堆内存管理

> **核心问题**：如何管理 8GB 物理内存？如何划分为 2048 个 Region？

### 3.1 核心类总览

```
G1CollectedHeap (总控中心)  ⭐⭐⭐⭐⭐
  ├─ HeapRegionManager       (Region 管理器)        ⭐⭐⭐⭐⭐
  │    ├─ G1HeapRegionTable  (Region 指针数组)       ⭐⭐⭐⭐
  │    ├─ FreeRegionList     (空闲 Region 链表)      ⭐⭐⭐⭐
  │    └─ HeapRegionSet      (Region 集合基类)       ⭐⭐⭐
  ├─ HeapRegion [2048]       (单个 Region)           ⭐⭐⭐⭐⭐
  │    ├─ HeapRegionType     (Region 类型标记)        ⭐⭐⭐⭐
  │    ├─ G1BlockOffsetTablePart (BOT 分区)          ⭐⭐⭐⭐
  │    └─ HeapRegionRemSet   (每 Region 的 RSet)     ⭐⭐⭐⭐⭐
  ├─ G1RegionToSpaceMapper [6] (虚拟内存映射器)      ⭐⭐⭐
  │    └─ G1PageBasedVirtualSpace (页粒度虚拟空间)    ⭐⭐
  └─ G1BlockOffsetTable      (全局 BOT)              ⭐⭐⭐⭐
```

### 3.2 详细类说明

#### G1CollectedHeap ⭐⭐⭐⭐⭐
> **一句话**：G1 GC 的"大脑"，持有所有子系统的引用，是整个 GC 的总控中心。
> **继承**：`G1CollectedHeap → CollectedHeap`
> **源码**：`g1CollectedHeap.hpp`（1488 行）

| 关键字段 | 类型 | 作用 |
|---------|------|------|
| `_hrm` | `HeapRegionManager` | Region 管理器（内联对象） |
| `_policy` | `G1Policy*` | GC 策略（决定何时 GC、回收哪些 Region） |
| `_allocator` | `G1Allocator*` | 对象分配器 |
| `_card_table` | `G1CardTable*` | 卡表 |
| `_rem_set` | `G1RemSet*` | Remembered Set 管理 |
| `_cm` | `G1ConcurrentMark*` | 并发标记 |
| `_cm_thread` | `G1ConcurrentMarkThread*` | 并发标记线程 |
| `_cr` | `G1ConcurrentRefine*` | 并发精化 |
| `_collection_set` | `G1CollectionSet` | 回收集合 |
| `_hot_card_cache` | `G1HotCardCache*` | 热点卡缓存 |
| `_g1_barrier_set` | `G1BarrierSet*` | 写屏障集 |
| `_workers` | `WorkGang*` | GC 工作线程池 |
| `_g1mm` | `G1MonitoringSupport*` | 监控支持 |
| `_collector_state` | `G1CollectorState` | 收集器状态机 |
| `_old_marking_cycles_started` | `volatile uint` | 标记周期计数 |
| `_old_marking_cycles_completed` | `volatile uint` | 完成的标记周期数 |
| `_humongous_reclaim_candidates` | `G1BiasedMappedArray<bool>` | 大对象回收候选 |
| `_num_humongous_objects` | `volatile uint` | 大对象计数 |
| `_bot` | `G1BlockOffsetTable*` | Block Offset Table |
| `_prev_mark_bitmap` | `G1CMBitMap` | 上一轮标记位图 |
| `_next_mark_bitmap` | `G1CMBitMap` | 当前标记位图 |
| `_verifier` | `G1HeapVerifier*` | 堆验证器 |
| `_ref_processor_stw` | `ReferenceProcessor*` | STW 引用处理器 |
| `_ref_processor_cm` | `ReferenceProcessor*` | 并发标记引用处理器 |

#### HeapRegion ⭐⭐⭐⭐⭐
> **一句话**：G1 的基本内存管理单元。每个 Region = 4MB 连续内存，可以是 Eden/Survivor/Old/Humongous。
> **继承**：`HeapRegion → G1ContiguousSpace → CompactibleSpace → Space`
> **源码**：`heapRegion.hpp`（725 行）

| 关键字段 | 类型 | 作用 |
|---------|------|------|
| `_bottom` | `HeapWord*` | Region 起始地址（继承自 Space） |
| `_end` | `HeapWord*` | Region 结束地址 |
| `_top` | `HeapWord*` | 已分配对象的顶部（`[bottom, top)` = 已用） |
| `_hrm_index` | `uint` | 在 HeapRegionManager 中的索引 |
| `_type` | `HeapRegionType` | Region 类型（Eden/Survivor/Old/Humongous等） |
| `_rem_set` | `HeapRegionRemSet*` | 该 Region 的 Remembered Set |
| `_bot_part` | `G1BlockOffsetTablePart` | 该 Region 的 BOT 分区 |
| `_prev_top_at_mark_start` | `HeapWord*` | 上一轮标记开始时的 top（PTAMS） |
| `_next_top_at_mark_start` | `HeapWord*` | 当前标记开始时的 top（NTAMS） |
| `_gc_efficiency` | `double` | GC 效率评分（用于选择回收目标） |
| `_young_index_in_cset` | `int` | 在 CSet 中的索引 |
| `_surv_rate_group` | `SurvivorRateGroup*` | 存活率组 |
| `_age_in_surv_rate_group` | `int` | 存活率组中的年龄 |
| `_prev_marked_bytes` | `size_t` | 上一轮标记的存活字节数 |
| `_next_marked_bytes` | `size_t` | 当前标记的存活字节数 |
| `_evacuation_failed` | `bool` | 疏散是否失败 |
| `_node_index` | `uint` | NUMA 节点索引 |
| `_pinned_object_count` | `volatile jint` | 被钉住的对象数 |

#### HeapRegionType ⭐⭐⭐⭐
> **一句话**：Region 的类型标记，用位编码区分 Free/Young/Humongous/Old 等状态。
> **源码**：`heapRegionType.hpp`

| 值 | Tag | 含义 |
|----|-----|------|
| `0000` | Free | 空闲 |
| `0010` | Eden | Eden 区 |
| `0011` | Survivor | Survivor 区 |
| `0100` | StartsHumongous | 大对象起始 Region |
| `0101` | ContinuesHumongous | 大对象后续 Region |
| `1000` | Old | 老年代 |
| `1010` | Archive | 归档区（CDS） |

#### HeapRegionManager ⭐⭐⭐⭐⭐
> **一句话**：管理所有 2048 个 HeapRegion 的生命周期：创建、分配、回收、commit/uncommit。
> **源码**：`heapRegionManager.hpp`

| 关键字段 | 类型 | 作用 |
|---------|------|------|
| `_regions` | `G1HeapRegionTable` | Region 指针数组（biased array，O(1) 按索引/地址查找） |
| `_num_committed` | `uint` | 已 commit 的 Region 数 |
| `_available_map` | `CHeapBitMap` | 可用 Region 位图 |
| `_free_list` | `FreeRegionList` | 空闲 Region 链表 |
| `_bot_mapper` | `G1RegionToSpaceMapper*` | BOT 映射器 |
| `_cardtable_mapper` | `G1RegionToSpaceMapper*` | CardTable 映射器 |
| `_card_counts_mapper` | `G1RegionToSpaceMapper*` | CardCounts 映射器 |
| `_prev_bitmap_mapper` | `G1RegionToSpaceMapper*` | prev 位图映射器 |
| `_next_bitmap_mapper` | `G1RegionToSpaceMapper*` | next 位图映射器 |

#### HeapRegionSet / FreeRegionList ⭐⭐⭐
> **一句话**：HeapRegionSet 是 Region 集合的基类；FreeRegionList 是双向链表，管理空闲 Region。
> **源码**：`heapRegionSet.hpp`

```
HeapRegionSetBase          (基类：长度、总容量统计)
  ├─ HeapRegionSet         (无序集合：只统计不维护链表)
  └─ FreeRegionList        (有序双向链表：_head, _tail, 按地址排序)
```

#### G1BlockOffsetTable / G1BlockOffsetTablePart ⭐⭐⭐⭐
> **一句话**：给定堆中任意地址，快速找到该地址所在对象的起始位置。每 512 字节堆对应 1 个字节。
> **源码**：`g1BlockOffsetTable.hpp`

| 字段 | 类型 | 作用 |
|------|------|------|
| `_offset_array` | `volatile u_char*` | 偏移数组（16MB for 8GB 堆） |
| `_reserved` | `MemRegion` | 覆盖的堆区域 |

每个 `HeapRegion` 持有一个 `G1BlockOffsetTablePart`，管理自己那 4MB 范围内的偏移。

#### G1RegionToSpaceMapper ⭐⭐⭐
> **一句话**：将 Region 索引映射到辅助数据结构的对应虚拟内存页，支持按 Region 粒度 commit/uncommit。
> **源码**：`g1RegionToSpaceMapper.hpp`

共 6 个实例：heap_storage(8GB), bot(16MB), cardtable(16MB), card_counts(16MB), prev_bitmap(128MB), next_bitmap(128MB)。

---

## 四、子系统②：分代管理

> **核心问题**：如何动态管理 Young/Old 代的大小？

```
G1Policy               (GC 策略总控)                ⭐⭐⭐⭐⭐
  ├─ G1Analytics       (历史数据分析/预测)            ⭐⭐⭐⭐
  │    └─ G1Predictions (置信度预测工具)              ⭐⭐
  ├─ G1YoungGenSizer   (年轻代大小决策)              ⭐⭐⭐⭐
  ├─ G1CollectorState  (收集器状态机)                ⭐⭐⭐⭐
  ├─ G1IHOPControl     (IHOP 自适应阈值)             ⭐⭐⭐⭐
  ├─ G1MMUTracker      (最小 Mutator 利用率)         ⭐⭐⭐
  ├─ G1HeapSizingPolicy (堆大小调整策略)             ⭐⭐⭐
  ├─ SurvivorRateGroup  (存活率统计)                 ⭐⭐⭐
  └─ CollectionSetChooser (Mixed GC 候选选择)        ⭐⭐⭐⭐

G1EdenRegions          (Eden Region 追踪)            ⭐⭐⭐
G1SurvivorRegions      (Survivor Region 追踪)        ⭐⭐⭐
```

### 4.1 详细类说明

#### G1Policy ⭐⭐⭐⭐⭐
> **一句话**：G1 GC 的"决策中心"——决定何时触发 GC、分配多少 Young Region、选择哪些 Old Region 回收、暂停时间预测。
> **源码**：`g1Policy.hpp`（430 行）

| 关键字段 | 类型 | 作用 |
|---------|------|------|
| `_predictor` | `G1Predictions` | 预测器（基于历史数据 + 置信度） |
| `_analytics` | `G1Analytics*` | 历史数据分析器 |
| `_mmu_tracker` | `G1MMUTracker*` | 最小 Mutator 利用率追踪 |
| `_ihop_control` | `G1IHOPControl*` | IHOP 自适应控制 |
| `_policy_counters` | `GCPolicyCounters*` | 策略计数器 |
| `_young_list_fixed_length` | `uint` | 固定的年轻代长度 |
| `_young_list_target_length` | `uint` | 目标年轻代长度 |
| `_young_list_max_length` | `uint` | 最大年轻代长度 |
| `_collection_set` | `G1CollectionSet*` | 回收集合 |
| `_bytes_copied_during_gc` | `size_t` | GC 期间复制的字节数 |
| `_survivor_surv_rate_group` | `SurvivorRateGroup*` | Survivor 存活率组 |
| `_reserve_factor` | `double` | 保留因子 |
| `_reserve_regions` | `uint` | 保留 Region 数 |
| `_rs_lengths_prediction` | `size_t` | RSet 长度预测 |
| `_max_rs_lengths` | `size_t` | 最大 RSet 长度 |
| `_g1_heap_sizing_policy` | `G1HeapSizingPolicy*` | 堆大小调整策略 |
| `_old_gen_alloc_tracker` | `G1OldGenAllocationTracker` | 老年代分配追踪 |

关键决策方法：
- `record_collection_pause_start()` / `record_collection_pause_end()`
- `young_list_target_length()` → 年轻代应该有多少个 Region
- `predict_pause_time_ms()` → 预测暂停时间
- `can_expand_young_list()` → 是否可以扩展年轻代

#### G1Analytics ⭐⭐⭐⭐
> **一句话**：存储所有历史 GC 数据的统计引擎——暂停时间、复制时间、扫描时间等的 TruncatedSeq 序列。
> **源码**：`g1Analytics.hpp`

| 关键字段 | 类型 | 作用 |
|---------|------|------|
| `_predictor` | `const G1Predictions*` | 预测器引用 |
| `_recent_gc_times_ms` | `TruncatedSeq*` | 最近 GC 暂停时间序列 |
| `_concurrent_mark_remark_times_ms` | `TruncatedSeq*` | Remark 暂停时间 |
| `_concurrent_mark_cleanup_times_ms` | `TruncatedSeq*` | Cleanup 暂停时间 |
| `_alloc_rate_ms_seq` | `TruncatedSeq*` | 分配速率序列 |
| `_prev_collection_pause_end_ms` | `double` | 上一次暂停结束时间 |
| `_rs_length_diff_seq` | `TruncatedSeq*` | RSet 长度差序列 |
| `_cost_per_card_ms_seq` | `TruncatedSeq*` | 每张卡的处理成本 |
| `_cost_scan_hcc_seq` | `TruncatedSeq*` | 扫描 HotCardCache 成本 |
| `_young_cards_per_entry_ratio_seq` | `TruncatedSeq*` | 年轻代卡/条目比率 |
| `_mixed_cards_per_entry_ratio_seq` | `TruncatedSeq*` | Mixed 卡/条目比率 |
| `_cost_per_entry_ms_seq` | `TruncatedSeq*` | 每条目成本 |
| `_mixed_cost_per_entry_ms_seq` | `TruncatedSeq*` | Mixed 每条目成本 |
| `_cost_per_byte_ms_seq` | `TruncatedSeq*` | 每字节复制成本 |
| `_constant_other_time_ms_seq` | `TruncatedSeq*` | 固定开销时间 |
| `_young_other_cost_per_region_ms_seq` | `TruncatedSeq*` | 年轻代每 Region 其他成本 |
| `_non_young_other_cost_per_region_ms_seq` | `TruncatedSeq*` | 非年轻代每 Region 其他成本 |
| `_pending_cards_seq` | `TruncatedSeq*` | 待处理卡序列 |
| `_rs_lengths_seq` | `TruncatedSeq*` | RSet 长度序列 |

所有预测基于公式：**预测值 = 平均值 + σ × 标准差**

#### G1CollectorState ⭐⭐⭐⭐
> **一句话**：G1 收集器的状态机，用布尔标志组合表示当前处于哪个 GC 阶段。
> **源码**：`g1CollectorState.hpp`

| 标志 | 作用 |
|------|------|
| `_gcs_are_young` | 当前是否为纯 Young GC（非 Mixed） |
| `_last_gc_was_young` | 上一次是否为 Young GC |
| `_last_young_gc` | 是否是 Mixed 序列前的最后一次 Young GC |
| `_in_marking_window` | 是否在标记窗口中 |
| `_in_marking_window_im` | 标记窗口中且刚开始标记 |
| `_during_initial_mark_pause` | 正在执行 Initial Mark 暂停 |
| `_initiate_conc_mark_if_possible` | 是否应该启动并发标记 |
| `_mark_or_rebuild_in_progress` | 标记/重建 RSet 是否进行中 |
| `_clearing_next_bitmap` | 正在清理 next bitmap |
| `_full_collection` | 正在执行 Full GC |
| `_in_initial_mark_gc` | 在 Initial Mark GC 中 |

#### G1IHOPControl ⭐⭐⭐⭐
> **一句话**：控制何时触发并发标记——当老年代占用达到 IHOP 阈值时。有固定和自适应两种实现。
> **源码**：`g1IHOPControl.hpp`

- `G1StaticIHOPControl`：固定比例（`-XX:InitiatingHeapOccupancyPercent=45`）
- `G1AdaptiveIHOPControl`：根据历史分配速率和标记耗时自动调整（`-XX:+G1UseAdaptiveIHOP`，默认开启）

#### G1YoungGenSizer ⭐⭐⭐⭐
> **一句话**：决定年轻代包含多少个 Region。有固定和自适应两种模式。
> **源码**：`g1YoungGenSizer.hpp`

| 字段 | 类型 | 作用 |
|------|------|------|
| `_sizer_kind` | `SizerKind` | 模式：Adaptive/Fixed |
| `_min_desired_young_length` | `uint` | 最小年轻代 Region 数 |
| `_max_desired_young_length` | `uint` | 最大年轻代 Region 数 |
| `_adaptive_size` | `bool` | 是否自适应 |

模式由 JVM 参数决定：
- 不指定 `-XX:NewSize/-XX:MaxNewSize` → Adaptive（默认）
- 指定 `-XX:NewRatio` → Adaptive + 有边界
- 指定 `-XX:NewSize=MaxNewSize` → Fixed

#### CollectionSetChooser ⭐⭐⭐⭐
> **一句话**：在 Cleanup 阶段，根据 GC 效率排序 Old Region，为后续 Mixed GC 选择回收候选。
> **源码**：`collectionSetChooser.hpp`

| 字段 | 类型 | 作用 |
|------|------|------|
| `_regions` | `GrowableArray<HeapRegion*>` | 候选 Region 数组（按 GC 效率排序） |
| `_front` | `int` | 当前消费到的位置 |
| `_end` | `int` | 有效元素结束位置 |
| `_remaining_reclaimable_bytes` | `size_t` | 剩余可回收字节数 |

GC 效率 = `reclaimable_bytes / predicted_time`，效率越高越优先被选入 Mixed GC。

---

## 五、子系统③：对象分配

> **核心问题**：Java 对象如何分配到 Region 中？

```
G1Allocator             (分配器总控)                 ⭐⭐⭐⭐
  ├─ G1AllocRegion      (分配 Region 抽象基类)       ⭐⭐⭐⭐
  │    ├─ MutatorAllocRegion  (Mutator 分配)         ⭐⭐⭐⭐⭐
  │    ├─ SurvivorGCAllocRegion (GC Survivor 分配)   ⭐⭐⭐⭐
  │    └─ OldGCAllocRegion    (GC Old 分配)          ⭐⭐⭐⭐
  └─ G1PLABAllocator    (GC 并行分配 - PLAB)         ⭐⭐⭐⭐

G1PLAB                  (GC 线程的本地分配缓冲区)     ⭐⭐⭐
```

#### G1Allocator ⭐⭐⭐⭐
> **一句话**：管理 3 个分配 Region：Eden（Mutator 分配）、Survivor（Young GC 存活复制）、Old（晋升）。
> **源码**：`g1Allocator.hpp`

| 字段 | 类型 | 作用 |
|------|------|------|
| `_g1h` | `G1CollectedHeap*` | G1 堆 |
| `_survivor_is_full` | `bool` | Survivor 是否满 |
| `_old_is_full` | `bool` | Old 是否满 |
| `_mutator_alloc_region` | `MutatorAllocRegion` | Mutator 分配 Region |
| `_survivor_gc_alloc_region` | `SurvivorGCAllocRegion` | Survivor 分配 Region |
| `_old_gc_alloc_region` | `OldGCAllocRegion` | Old 分配 Region |
| `_retained_old_gc_alloc_region` | `HeapRegion*` | 保留的 Old Region（跨 GC 复用） |

#### G1AllocRegion ⭐⭐⭐⭐
> **一句话**：封装"当前正在使用的 Region"概念，提供 bump-pointer 快速分配 + 自动获取新 Region 的慢路径。
> **源码**：`g1AllocRegion.hpp`

| 字段 | 类型 | 作用 |
|------|------|------|
| `_alloc_region` | `HeapRegion*` | 当前分配 Region（满了时为 Dummy Region） |
| `_count` | `uint` | 已使用的 Region 计数 |
| `_used_bytes_before` | `size_t` | 切换前已使用字节数 |

**Dummy Region 设计**：当无可用 Region 时，`_alloc_region` 指向一个 `top == end` 的 Dummy Region，任何分配尝试立即失败 → 进入慢路径 → 从 FreeRegionList 获取新 Region。避免 NULL 检查。

#### G1PLABAllocator ⭐⭐⭐⭐
> **一句话**：GC 期间每个工作线程的并行分配缓冲区管理器。每个线程有自己的 PLAB，避免竞争。
> **源码**：`g1Allocator.hpp`

| 字段 | 类型 | 作用 |
|------|------|------|
| `_g1h` | `G1CollectedHeap*` | G1 堆 |
| `_alloc_buffers` | `G1PLAB*[InCSetState::Num]` | 每种目标区域一个 PLAB |
| `_surviving_alloc_buffer` | `G1PLAB` | Survivor PLAB |
| `_tenured_alloc_buffer` | `G1PLAB` | Old PLAB |

---

## 六、子系统④：写屏障 + Remembered Set

> **核心问题**：如何追踪跨 Region 引用？（Old → Young 的指针）

```
G1BarrierSet              (写屏障实现)               ⭐⭐⭐⭐⭐
  ├─ pre-write barrier    (SATB 写前屏障)            ⭐⭐⭐⭐⭐
  │    └─ SATBMarkQueue   (每线程 SATB 队列)         ⭐⭐⭐⭐
  └─ post-write barrier   (写后屏障)                 ⭐⭐⭐⭐⭐
       └─ DirtyCardQueue  (每线程脏卡队列)            ⭐⭐⭐⭐

G1CardTable               (全局卡表)                  ⭐⭐⭐⭐⭐
G1CardCounts              (卡热度计数)                ⭐⭐⭐
G1HotCardCache            (热点卡缓存)                ⭐⭐⭐

G1RemSet                  (RSet 总管)                 ⭐⭐⭐⭐⭐
  └─ HeapRegionRemSet     (每 Region 的 RSet)        ⭐⭐⭐⭐⭐
       └─ OtherRegionsTable (跨 Region 引用表)        ⭐⭐⭐⭐⭐
            ├─ PerRegionTable (细粒度表)              ⭐⭐⭐⭐
            │    └─ CHeapBitMap (位图：哪些卡有引用)   ⭐⭐⭐
            ├─ SparsePRT       (稀疏表)               ⭐⭐⭐⭐
            │    └─ RSHashTable (哈希表)              ⭐⭐⭐
            └─ G1FromCardCache (From Card 缓存)       ⭐⭐⭐

G1ConcurrentRefine       (并发精化总控)               ⭐⭐⭐⭐
  └─ G1ConcurrentRefineThread (精化工作线程)          ⭐⭐⭐
```

### 6.1 写屏障链路

```
Java 代码: obj.field = newValue;

→ pre-write barrier (SATB):
    如果正在标记: 将旧值放入 SATBMarkQueue
    SATBMarkQueue 满 → 转移到全局 SATBMarkQueueSet

→ 实际写入: *(field_addr) = newValue;

→ post-write barrier:
    计算 card_index = (field_addr - heap_base) >> 9
    如果 card != young_card && card != dirty_card:
        设置 card = dirty_card
        将 card_index 放入 DirtyCardQueue
        DirtyCardQueue 满 → 转移到全局 DirtyCardQueueSet

→ G1ConcurrentRefine 线程:
    从全局 DirtyCardQueueSet 取脏卡
    → G1HotCardCache 过滤热点卡
    → 扫描卡对应的 512B 内存，找出跨 Region 引用
    → 更新目标 Region 的 HeapRegionRemSet
```

#### G1BarrierSet ⭐⭐⭐⭐⭐
> **一句话**：G1 的写屏障实现，包含 pre-write（SATB）和 post-write 两部分。全局唯一实例。
> **源码**：`g1BarrierSet.hpp`

#### G1CardTable ⭐⭐⭐⭐⭐
> **一句话**：16MB 字节数组，堆中每 512 字节对应 1 个字节。用于追踪被修改的堆内存区域。
> **源码**：`g1CardTable.hpp`

| 字段 | 类型 | 作用 |
|------|------|------|
| `_byte_map` | `jbyte*` | 卡表字节数组 |
| `_byte_map_base` | `jbyte*` | 带偏移的基地址（`card = base + addr >> 9`） |

特殊卡值：
- `clean_card = -1` (0xFF)
- `dirty_card = 0`
- `g1_young_card = dirty_card + 1`

#### HeapRegionRemSet ⭐⭐⭐⭐⭐
> **一句话**：记录"谁引用了我"——每个 Region 持有一个 RSet，记录所有指向该 Region 的跨 Region 引用。
> **源码**：`heapRegionRemSet.hpp`

| 字段 | 类型 | 作用 |
|------|------|------|
| `_bot` | `G1BlockOffsetTable*` | BOT 引用 |
| `_code_roots` | `G1CodeRootSet` | Code Cache 引用集合 |
| `_other_regions` | `OtherRegionsTable` | **核心**：跨 Region 引用表 |
| `_strong_code_roots_list` | `GrowableArray<nmethod*>*` | 强 code root 列表 |

#### OtherRegionsTable ⭐⭐⭐⭐⭐
> **一句话**：RSet 的核心实现。使用三级存储结构（粗 → 细 → 稀疏）平衡空间和速度。

| 字段 | 类型 | 作用 |
|------|------|------|
| `_coarse_map` | `BitMap` | **粗粒度**：1 bit = 1 个 Region（引用太多就标记整个 Region） |
| `_n_coarse_entries` | `size_t` | 粗粒度条目数 |
| `_fine_grain_regions` | `PerRegionTable**` | **细粒度**：哈希表，每个条目是一个 PerRegionTable |
| `_n_fine_entries` | `size_t` | 细粒度条目数 |
| `_fine_eviction_start` | `size_t` | 驱逐起始位置 |
| `_fine_eviction_stride` | `static size_t` | 驱逐步长 |
| `_first_all_fine_prts` | `PerRegionTable*` | 所有 PRT 链表头 |
| `_last_all_fine_prts` | `PerRegionTable*` | 所有 PRT 链表尾 |
| `_sparse_table` | `SparsePRT` | **稀疏**：少量引用时使用 |
| `_max_fine_entries` | `static size_t` | 细粒度最大容量 |
| `_mod_max_fine_entries_mask` | `static size_t` | 哈希掩码 |

**三级存储的设计思想**：
1. **Sparse**（≤少量引用）：直接记录 `(region_index, card_index)` 对，最省空间
2. **Fine**（中等引用）：每个来源 Region 一个 PerRegionTable，用位图记录哪些 card 有引用
3. **Coarse**（大量引用）：放弃精确追踪，只标记"整个 Region 有引用"

#### G1ConcurrentRefine ⭐⭐⭐⭐
> **一句话**：管理并发精化线程，将脏卡转化为 RSet 条目。使用三区模型控制线程激活。
> **源码**：`g1ConcurrentRefine.hpp`

| 字段 | 类型 | 作用 |
|------|------|------|
| `_threads` | `G1ConcurrentRefineThread**` | 精化线程数组 |
| `_n_worker_threads` | `uint` | 工作线程数 |
| `_n_periods` | `uint` | 检查周期数 |
| `_green_zone` | `size_t` | 绿区阈值（≤13：不处理） |
| `_yellow_zone` | `size_t` | 黄区阈值（≤39：精化线程处理） |
| `_red_zone` | `size_t` | 红区阈值（≤65：应用线程也帮忙处理） |
| `_hot_card_cache` | `G1HotCardCache` | 热点卡缓存 |

---

## 七、子系统⑤：并发标记

> **核心问题**：如何在应用线程运行的同时识别所有存活对象？

```
G1ConcurrentMark          (并发标记总控)              ⭐⭐⭐⭐⭐
  ├─ G1ConcurrentMarkThread (并发标记线程)            ⭐⭐⭐⭐
  ├─ G1CMBitMap [2]         (prev/next 标记位图)      ⭐⭐⭐⭐⭐
  ├─ G1CMTask               (每工作线程的标记任务)     ⭐⭐⭐⭐
  │    └─ G1CMTaskQueue     (本地标记栈)              ⭐⭐⭐
  ├─ G1RegionMarkStatsCache (标记统计缓存)            ⭐⭐⭐
  ├─ G1CMRootRegions        (根 Region 集合)          ⭐⭐⭐
  └─ SATBMarkQueueSet       (全局 SATB 队列集)        ⭐⭐⭐⭐

G1ConcurrentMarkObjArrayProcessor (大数组分片处理)    ⭐⭐
```

#### G1ConcurrentMark ⭐⭐⭐⭐⭐
> **一句话**：实现 SATB 并发标记算法。管理标记位图、标记任务、finger 指针、global mark stack。
> **源码**：`g1ConcurrentMark.hpp`（894 行）

| 关键字段 | 类型 | 作用 |
|---------|------|------|
| `_g1h` | `G1CollectedHeap*` | G1 堆 |
| `_prev_mark_bitmap` | `G1CMBitMap*` | 上一轮标记位图（只读，Mixed GC 使用） |
| `_next_mark_bitmap` | `G1CMBitMap*` | 当前标记位图（并发标记写入） |
| `_heap` | `MemRegion` | 堆范围 |
| `_root_regions` | `G1CMRootRegions` | 根 Region |
| `_global_mark_stack` | `G1CMMarkStack` | 全局标记栈（溢出时使用） |
| `_finger` | `HeapWord* volatile` | 全局 finger 指针（标记进度） |
| `_max_num_tasks` | `uint` | 最大任务数 |
| `_num_active_tasks` | `uint` | 当前活跃任务数 |
| `_tasks` | `G1CMTask**` | 标记任务数组 |
| `_task_queues` | `G1CMTaskQueueSet*` | 任务队列集 |
| `_completed_initialization` | `bool` | 初始化是否完成 |
| `_concurrent_marking_in_progress` | `bool` | 并发标记是否进行中 |
| `_has_overflown` | `bool` | 全局标记栈是否溢出 |
| `_has_aborted` | `bool` | 是否被中止 |
| `_total_counting_data` | `G1RegionMarkStats*` | 全局 Region 标记统计 |
| `_max_concurrent_workers` | `uint` | 最大并发工作线程数 |
| `_concurrent_workers` | `WorkGang*` | 并发标记线程池 |
| `_remark_mark_stack_size` | `size_t` | Remark 时标记栈大小 |

**并发标记 5 个阶段**：
1. **Initial Mark**（STW）：标记 GC root 直接可达的对象，piggyback 在 Young GC 上
2. **Root Region Scanning**：扫描 Survivor Region（初始标记后存活对象引用的对象）
3. **Concurrent Marking**：遍历堆标记所有存活对象（与应用并发）
4. **Remark**（STW）：处理 SATB 队列中的引用变更，完成标记
5. **Cleanup**（部分 STW）：统计存活数据，排序 Old Region，交换 bitmap

#### G1CMBitMap ⭐⭐⭐⭐⭐
> **一句话**：标记位图，每个 HeapWord (8 bytes) 对应 1 bit。8GB 堆 → 128MB 位图。双缓冲设计（prev/next）。
> **源码**：`g1ConcurrentMarkBitMap.hpp`

#### G1CMTask ⭐⭐⭐⭐
> **一句话**：每个并发标记工作线程持有一个 CMTask，维护自己的 finger、本地队列、统计缓存。
> **源码**：`g1ConcurrentMark.hpp` 内部类

| 关键字段 | 类型 | 作用 |
|---------|------|------|
| `_worker_id` | `uint` | 工作线程 ID |
| `_cm` | `G1ConcurrentMark*` | 并发标记总控 |
| `_finger` | `HeapWord*` | 本地 finger 指针 |
| `_task_queue` | `G1CMTaskQueue*` | 本地标记队列 |
| `_mark_stats_cache` | `G1RegionMarkStatsCache` | 标记统计缓存 |
| `_calls` | `uint` | 调用计数 |
| `_refs_reached` | `uint` | 到达的引用数 |
| `_words_scanned` | `size_t` | 扫描的字数 |
| `_time_target_ms` | `double` | 时间预算（ms） |
| `_start_time_ms` | `double` | 开始时间 |
| `_elapsed_time_ms` | `double` | 已用时间 |
| `_has_aborted` | `bool` | 是否被中止 |

---

## 八、子系统⑥：回收策略

> **核心问题**：选择哪些 Region 来回收？

```
G1CollectionSet           (回收集合)                  ⭐⭐⭐⭐⭐
  ├─ collection_set_regions[] (被选中的 Region 列表)   ⭐⭐⭐⭐
  ├─ CollectionSetChooser  (Mixed GC 候选选择器)       ⭐⭐⭐⭐
  └─ G1InCSetState / InCSetState (CSet 成员查询)      ⭐⭐⭐

EvacuationInfo            (疏散信息记录)              ⭐⭐
```

#### G1CollectionSet ⭐⭐⭐⭐⭐
> **一句话**：本次 GC 要回收的 Region 集合。Young GC 包含所有 Eden+Survivor；Mixed GC 额外加入部分 Old Region。
> **源码**：`g1CollectionSet.hpp`

| 字段 | 类型 | 作用 |
|------|------|------|
| `_g1h` | `G1CollectedHeap*` | G1 堆 |
| `_policy` | `G1Policy*` | 策略 |
| `_cset_chooser` | `CollectionSetChooser*` | Mixed GC 候选选择器 |
| `_eden_region_length` | `uint` | Eden Region 数 |
| `_survivor_region_length` | `uint` | Survivor Region 数 |
| `_old_region_length` | `uint` | Old Region 数（Mixed GC 时 > 0） |
| `_collection_set_regions` | `uint*` | Region 索引数组 |
| `_collection_set_cur_length` | `volatile size_t` | 当前长度 |
| `_collection_set_max_length` | `size_t` | 最大长度 |
| `_bytes_used_before` | `size_t` | GC 前已使用字节数 |
| `_recorded_rs_lengths` | `size_t` | 记录的 RSet 总长度 |
| `_inc_bytes_used_before` | `size_t` | 增量 CSet 的使用字节数 |
| `_inc_recorded_rs_lengths` | `size_t` | 增量 CSet 的 RSet 长度 |
| `_inc_predicted_elapsed_time_ms` | `double` | 增量 CSet 的预测耗时 |

---

## 九、子系统⑦：疏散回收（Evacuation）

> **核心问题**：如何把存活对象从 CSet 中复制出来？

```
G1ParScanThreadState      (每工作线程的疏散状态)      ⭐⭐⭐⭐⭐
  ├─ G1PLABAllocator      (并行分配缓冲区)           ⭐⭐⭐⭐
  ├─ G1ScanEvacuatedObjClosure (扫描已疏散对象闭包)   ⭐⭐⭐⭐
  └─ RefToScanQueue        (待扫描引用队列)           ⭐⭐⭐⭐

G1RootProcessor           (根处理器)                  ⭐⭐⭐⭐
G1EvacFailure             (疏散失败处理)              ⭐⭐⭐

G1OopClosures 系列:
  ├─ G1ParCopyClosure      (对象复制闭包)             ⭐⭐⭐⭐
  ├─ G1ScanObjClosure      (对象扫描闭包)             ⭐⭐⭐
  ├─ G1CLDScanClosure      (CLD 扫描闭包)             ⭐⭐⭐
  └─ G1CodeBlobClosure     (CodeBlob 闭包)            ⭐⭐⭐
```

#### G1ParScanThreadState ⭐⭐⭐⭐⭐
> **一句话**：每个 GC 工作线程在疏散期间的完整状态——分配缓冲区、待扫描队列、年龄表、闭包等。
> **源码**：`g1ParScanThreadState.hpp`

| 关键字段 | 类型 | 作用 |
|---------|------|------|
| `_g1h` | `G1CollectedHeap*` | G1 堆 |
| `_task_queue` | `RefToScanQueue*` | 待扫描引用队列（work stealing） |
| `_plab_allocator` | `G1PLABAllocator*` | PLAB 分配器 |
| `_age_table` | `AgeTable` | 年龄表（对象年龄统计） |
| `_tenuring_threshold` | `uint` | 晋升阈值 |
| `_scanner` | `G1ScanEvacuatedObjClosure` | 已疏散对象扫描闭包 |
| `_worker_id` | `uint` | 工作线程 ID |
| `_num_optional_regions` | `size_t` | 可选 Region 数 |
| `_dest` | `InCSetState[InCSetState::Num]` | 每种来源的目标区域映射 |
| `_closures` | `G1SharedClosures<false>*` | 闭包集合（非标记模式） |
| `_closures_in_im` | `G1SharedClosures<true>*` | 闭包集合（Initial Mark 模式） |
| `_trim_ticks` | `Tickspan` | 队列修剪耗时 |

核心方法：`copy_to_survivor_space()` —— 对象复制的核心逻辑，包括分配空间、复制数据、安装 forwarding pointer、根据年龄决定目标区域。

---

## 十、子系统⑧：Full GC

> **核心问题**：当 Young GC / Mixed GC 都不够时，如何全堆回收？

```
G1FullCollector           (Full GC 总控)              ⭐⭐⭐⭐
  ├─ G1FullGCScope        (作用域管理)                ⭐⭐
  ├─ G1FullGCMarker       (Full GC 标记器)            ⭐⭐⭐
  ├─ G1FullGCCompactionPoint (压缩点)                 ⭐⭐⭐
  └─ 四阶段：
      ├─ G1FullGCMarkTask     (Phase 1: 标记存活对象)  ⭐⭐⭐
      ├─ G1FullGCPrepareTask  (Phase 2: 准备压缩)     ⭐⭐⭐
      ├─ G1FullGCAdjustTask   (Phase 3: 调整指针)     ⭐⭐⭐
      └─ G1FullGCCompactTask  (Phase 4: 执行压缩)     ⭐⭐⭐
```

Full GC 使用 **Mark-Compact** 算法（不是 Copy），4 个阶段：
1. 标记所有存活对象
2. 计算每个对象的新地址
3. 调整所有指针指向新地址
4. 移动对象到新位置

---

## 十一、辅助子系统

### 11.1 监控 & 统计

```
G1MonitoringSupport       (JMX 监控数据)              ⭐⭐
G1GCPhaseTimes            (GC 各阶段耗时统计)          ⭐⭐⭐
G1HeapTransition          (GC 前后堆状态对比)          ⭐⭐
G1EvacStats               (疏散统计)                  ⭐⭐
G1MemoryPool (3个)        (Eden/Survivor/Old 内存池)   ⭐⭐
G1HeapRegionEventSender   (Region 事件发送器)          ⭐
G1HRPrinter               (Region 打印器)             ⭐
```

#### G1GCPhaseTimes ⭐⭐⭐
> **一句话**：记录每次 GC 中每个阶段、每个工作线程的耗时，用于 GC 日志输出和性能分析。
> **源码**：`g1GCPhaseTimes.hpp`（407 行）

记录的阶段包括：Ext Root Scanning, Thread Roots, SATB Filtering, UpdateRS, ScanRS, Code Root Scanning, Object Copy, Termination, GC Worker Total/End, StringDedup 等。

### 11.2 字符串去重

```
G1StringDedup             (字符串去重)                ⭐⭐
  ├─ G1StringDedupQueue   (去重队列)                  ⭐⭐
  ├─ G1StringDedupTable   (去重表)                    ⭐⭐
  └─ G1StringDedupThread  (去重线程)                  ⭐⭐
  └─ G1StringDedupStat    (去重统计)                  ⭐
```

### 11.3 验证 & 调试

```
G1HeapVerifier            (堆验证器)                  ⭐⭐
G1RemSetSummary           (RSet 摘要)                 ⭐
vmStructs_g1              (SA 支持)                   ⭐
```

### 11.4 线程

```
G1ConcurrentMarkThread    (并发标记线程)              ⭐⭐⭐⭐
G1ConcurrentRefineThread  (并发精化线程，多个)         ⭐⭐⭐
G1YoungRemSetSamplingThread (RSet 采样线程)           ⭐⭐
G1StringDedupThread       (字符串去重线程)             ⭐⭐
```

---

## 十二、对象关系总图

```mermaid
graph TB
    subgraph "G1CollectedHeap (总控中心)"
        G1H["G1CollectedHeap ⭐⭐⭐⭐⭐"]
    end

    subgraph "① 堆内存管理"
        HRM["HeapRegionManager ⭐⭐⭐⭐⭐"]
        HR["HeapRegion [2048] ⭐⭐⭐⭐⭐"]
        HRT["HeapRegionType ⭐⭐⭐⭐"]
        FRL["FreeRegionList ⭐⭐⭐⭐"]
        BOT["G1BlockOffsetTable ⭐⭐⭐⭐"]
        MAPPER["G1RegionToSpaceMapper [6]"]
    end

    subgraph "② 分代策略"
        POL["G1Policy ⭐⭐⭐⭐⭐"]
        ANA["G1Analytics ⭐⭐⭐⭐"]
        YGS["G1YoungGenSizer ⭐⭐⭐⭐"]
        IHOP["G1IHOPControl ⭐⭐⭐⭐"]
        CST["G1CollectorState ⭐⭐⭐⭐"]
        CSC["CollectionSetChooser ⭐⭐⭐⭐"]
    end

    subgraph "③ 对象分配"
        ALLOC["G1Allocator ⭐⭐⭐⭐"]
        MAR["MutatorAllocRegion"]
        SAR["SurvivorGCAllocRegion"]
        OAR["OldGCAllocRegion"]
        PLAB["G1PLABAllocator ⭐⭐⭐⭐"]
    end

    subgraph "④ 写屏障 + RSet"
        BS["G1BarrierSet ⭐⭐⭐⭐⭐"]
        CT["G1CardTable ⭐⭐⭐⭐⭐"]
        RSET["G1RemSet ⭐⭐⭐⭐⭐"]
        HRRS["HeapRegionRemSet ⭐⭐⭐⭐⭐"]
        ORT["OtherRegionsTable ⭐⭐⭐⭐⭐"]
        PRT["PerRegionTable ⭐⭐⭐⭐"]
        SPRT["SparsePRT ⭐⭐⭐⭐"]
        CR["G1ConcurrentRefine ⭐⭐⭐⭐"]
        HCC["G1HotCardCache ⭐⭐⭐"]
        SATB["SATBMarkQueue ⭐⭐⭐⭐"]
        DCQ["DirtyCardQueue ⭐⭐⭐⭐"]
    end

    subgraph "⑤ 并发标记"
        CM["G1ConcurrentMark ⭐⭐⭐⭐⭐"]
        CMT["G1ConcurrentMarkThread ⭐⭐⭐⭐"]
        BM["G1CMBitMap [2] ⭐⭐⭐⭐⭐"]
        TASK["G1CMTask ⭐⭐⭐⭐"]
    end

    subgraph "⑥ 回收集合"
        CSET["G1CollectionSet ⭐⭐⭐⭐⭐"]
    end

    subgraph "⑦ 疏散回收"
        PSS["G1ParScanThreadState ⭐⭐⭐⭐⭐"]
        RP["G1RootProcessor ⭐⭐⭐⭐"]
    end

    %% G1CollectedHeap 到各子系统
    G1H -->|"_hrm"| HRM
    G1H -->|"_policy"| POL
    G1H -->|"_allocator"| ALLOC
    G1H -->|"_card_table"| CT
    G1H -->|"_rem_set"| RSET
    G1H -->|"_cm"| CM
    G1H -->|"_cm_thread"| CMT
    G1H -->|"_cr"| CR
    G1H -->|"_collection_set"| CSET
    G1H -->|"_g1_barrier_set"| BS
    G1H -->|"_hot_card_cache"| HCC
    G1H -->|"_bot"| BOT
    G1H -->|"_prev/next_mark_bitmap"| BM
    G1H -->|"_collector_state"| CST

    %% 堆内存管理内部
    HRM -->|"_regions[]"| HR
    HRM -->|"_free_list"| FRL
    HR -->|"_type"| HRT
    HR -->|"_rem_set"| HRRS
    HR -->|"_bot_part"| BOT

    %% 分代策略内部
    POL -->|"_analytics"| ANA
    POL -->|"_ihop_control"| IHOP
    CSET -->|"_cset_chooser"| CSC

    %% 对象分配内部
    ALLOC -->|"3 个 AllocRegion"| MAR
    ALLOC -->|""| SAR
    ALLOC -->|""| OAR

    %% RSet 内部
    HRRS -->|"_other_regions"| ORT
    ORT -->|"fine grain"| PRT
    ORT -->|"sparse"| SPRT
    RSET -->|"更新"| HRRS
    CR -->|"处理脏卡"| RSET

    %% 写屏障链路
    BS -->|"pre-write"| SATB
    BS -->|"post-write"| DCQ
    DCQ -->|"精化处理"| CR

    %% 并发标记内部
    CM -->|"_tasks[]"| TASK
    CMT -->|"驱动"| CM

    %% 疏散
    PSS -->|"_plab_allocator"| PLAB
    CSET -->|"选择目标"| HR
```

---

## 十三、攻破顺序建议

基于依赖关系和重要程度，建议按以下顺序逐一攻破：

| 阶段 | 目标 | 包含的核心类 | 理由 |
|------|------|------------|------|
| **1** | **HeapRegion 全貌** | HeapRegion, HeapRegionType, G1BlockOffsetTablePart | **基石**——所有操作都在 Region 上进行 |
| **2** | **HeapRegionManager + 内存管理** | HeapRegionManager, FreeRegionList, G1RegionToSpaceMapper | 理解 Region 的生命周期 |
| **3** | **对象分配路径** | G1Allocator, G1AllocRegion, TLAB | 理解对象从哪来 |
| **4** | **写屏障 + CardTable** | G1BarrierSet, G1CardTable, DirtyCardQueue, SATBMarkQueue | 理解引用变更如何被追踪 |
| **5** | **RSet 三级结构** | HeapRegionRemSet, OtherRegionsTable, PerRegionTable, SparsePRT | **最复杂**——G1 的精华所在 |
| **6** | **并发精化** | G1ConcurrentRefine, G1ConcurrentRefineThread, G1HotCardCache | 脏卡如何变成 RSet |
| **7** | **G1Policy + 预测模型** | G1Policy, G1Analytics, G1Predictions, G1YoungGenSizer | 理解"为什么选这些 Region" |
| **8** | **并发标记** | G1ConcurrentMark, G1CMBitMap, G1CMTask, SATB | 理解"如何识别垃圾" |
| **9** | **G1CollectionSet + 疏散** | G1CollectionSet, G1ParScanThreadState, CollectionSetChooser | Young GC / Mixed GC 完整流程 |
| **10** | **Full GC** | G1FullCollector, Mark-Compact 四阶段 | 兜底方案 |

---

## 十四、JVM 核心模块全景（按你提到的领域）

除了 G1 GC，JVM 还有以下核心模块值得深入：

| 模块 | 源码目录 | 重要程度 | 当前进度 |
|------|---------|---------|---------|
| **G1 GC** | `gc/g1/` | ⭐⭐⭐⭐⭐ | 📌 **正在攻破** |
| **线程系统** | `runtime/thread.*`, `runtime/vmThread.*` | ⭐⭐⭐⭐⭐ | ✅ #3(JavaThread) + #7(VMThread) 已完成 |
| **类加载** | `classfile/`, `oops/` | ⭐⭐⭐⭐⭐ | ⏳ 待开始 |
| **内存管理** | `memory/`, `gc/shared/` | ⭐⭐⭐⭐⭐ | 部分完成（堆初始化） |
| **JIT 编译** | `compiler/`, `opto/`, `c1/` | ⭐⭐⭐⭐ | ⏳ 待开始 |
| **解释器** | `interpreter/` | ⭐⭐⭐⭐ | ⏳ 待开始 |
| **同步/锁** | `runtime/mutex*`, `runtime/synchronizer.*` | ⭐⭐⭐⭐ | 部分涉及(Safepoint) |
| **信号处理** | `os/linux/os_linux.cpp` | ⭐⭐⭐ | ⏳ 待开始 |
| **Safepoint** | `runtime/safepoint.*` | ⭐⭐⭐⭐ | ✅ #7 已覆盖核心 |
| **对象模型** | `oops/oop.*`, `oops/markOop.*` | ⭐⭐⭐⭐⭐ | ⏳ 待开始 |
| **async-profiler** | `/data/workspace/async-profiler/src/` | ⭐⭐⭐⭐ | 部分完成（6课） |
| **Arthas** | `/data/workspace/arthas-4.1.2/` | ⭐⭐⭐ | ⏳ 待开始 |

**建议**：先把 G1 GC 彻底吃透（预计 10 篇左右深度文档），再扩展到类加载和对象模型。

---

## 十五、源文件→文档映射索引

> 方便从源文件名出发，快速定位到对应的深度分析文档。
> 共 195 个源文件（95 .hpp + 20 .inline.hpp + 80 .cpp），覆盖 175 个，20 个纯辅助类跳过。

### 堆内存管理

| 源文件 | 文档 |
|--------|------|
| `heapRegion.hpp/cpp/inline.hpp` | [#1 HeapRegion](./1-HeapRegion-Deep-Dive.md) |
| `heapRegionManager.hpp/cpp/inline.hpp` | [#2 HeapRegionManager](./2-HeapRegionManager-Deep-Dive.md) |
| `heapRegionSet.hpp/cpp/inline.hpp` | [#2 HeapRegionManager](./2-HeapRegionManager-Deep-Dive.md) |
| `heapRegionRemSet.hpp/cpp` | [#5 RSet 三级结构](./5-RSet-Three-Level-Structure.md) |
| `heapRegionType.hpp/cpp` | [#1 HeapRegion](./1-HeapRegion-Deep-Dive.md)（Region 类型体系） |
| `g1CollectedHeap.hpp/cpp/inline.hpp` | [#3 对象分配](./3-Object-Allocation-Path.md)、[#11 Young GC](./11-Young-GC-Complete-STW-Flow.md) |
| `g1PageBasedVirtualSpace.hpp/cpp` | [#2 HeapRegionManager](./2-HeapRegionManager-Deep-Dive.md)（6 路 Mapper） |
| `g1RegionToSpaceMapper.hpp/cpp` | [#2 HeapRegionManager](./2-HeapRegionManager-Deep-Dive.md)（6 路 Mapper） |
| `g1BiasedArray.hpp/cpp` | [#2 HeapRegionManager](./2-HeapRegionManager-Deep-Dive.md)（G1HeapRegionTable 基类） |

### 对象分配

| 源文件 | 文档 |
|--------|------|
| `g1Allocator.hpp/cpp/inline.hpp` | [#3 对象分配](./3-Object-Allocation-Path.md) |
| `g1AllocRegion.hpp/cpp/inline.hpp` | [#3 对象分配](./3-Object-Allocation-Path.md) |

### 写屏障 + CardTable

| 源文件 | 文档 |
|--------|------|
| `g1BarrierSet.hpp/cpp/inline.hpp` | [#4 写屏障+CardTable](./4-WriteBarrier-CardTable.md) |
| `g1CardTable.hpp/cpp/inline.hpp` | [#4 写屏障+CardTable](./4-WriteBarrier-CardTable.md) |
| `dirtyCardQueue.hpp/cpp` | [#4 写屏障+CardTable](./4-WriteBarrier-CardTable.md)、[#6 并发精化](./6-Concurrent-Refinement.md) |
| `ptrQueue.hpp/cpp` | [#4 写屏障+CardTable](./4-WriteBarrier-CardTable.md)（DirtyCardQueue/SATBMarkQueue 的基类） |
| `satbMarkQueue.hpp/cpp` | [#8 并发标记](./8-Concurrent-Marking.md)（SATB 写屏障队列） |
| `g1ThreadLocalData.hpp` | [#13 写屏障汇编](./13-Write-Barrier-Assembly-Full-Chain.md) |
| `g1BarrierSetRuntime.hpp/cpp` | [#13 写屏障汇编](./13-Write-Barrier-Assembly-Full-Chain.md)（slow-path Runtime） |
| `g1BarrierSetAssembler.hpp` + x86 实现 | [#13 写屏障汇编](./13-Write-Barrier-Assembly-Full-Chain.md)（解释器层） |
| `c1/g1BarrierSetC1.hpp/cpp` | [#13 写屏障汇编](./13-Write-Barrier-Assembly-Full-Chain.md)（C1 JIT 层） |
| `c2/g1BarrierSetC2.hpp/cpp` | [#13 写屏障汇编](./13-Write-Barrier-Assembly-Full-Chain.md)（C2 JIT 层） |

### RSet + 并发精化

| 源文件 | 文档 |
|--------|------|
| `heapRegionRemSet.hpp/cpp` | [#5 RSet 三级结构](./5-RSet-Three-Level-Structure.md) |
| `sparsePRT.hpp/cpp` | [#5 RSet 三级结构](./5-RSet-Three-Level-Structure.md)（Sparse 层） |
| `g1FromCardCache.hpp/cpp` | [#5 RSet 三级结构](./5-RSet-Three-Level-Structure.md)（FromCardCache） |
| `g1ConcurrentRefine.hpp/cpp` | [#6 并发精化](./6-Concurrent-Refinement.md) |
| `g1ConcurrentRefineThread.hpp/cpp` | [#6 并发精化](./6-Concurrent-Refinement.md) |
| `g1HotCardCache.hpp/cpp` | [#6 并发精化](./6-Concurrent-Refinement.md)（热卡缓存） |
| `g1CardCounts.hpp/cpp` | [#6 并发精化](./6-Concurrent-Refinement.md)（卡计数） |
| `g1RemSet.hpp/cpp` | [#12 G1RemSet 完整流程](./12-G1RemSet-Complete-Flow.md) |
| `g1RemSetSummary.hpp/cpp` | [#12 G1RemSet 完整流程](./12-G1RemSet-Complete-Flow.md) |
| `g1RemSetTrackingPolicy.hpp/cpp` | [#12 G1RemSet 完整流程](./12-G1RemSet-Complete-Flow.md)、[#16 策略](./16-Strategy-Adaptive-Adjustment.md) |
| `g1CodeCacheRemSet.hpp/cpp` | [#12 G1RemSet 完整流程](./12-G1RemSet-Complete-Flow.md)（nmethod 追踪） |
| `g1CodeBlobClosure.hpp/cpp` | [#12 G1RemSet 完整流程](./12-G1RemSet-Complete-Flow.md)（Code Root 扫描闭包） |

### 预测模型 + 策略

| 源文件 | 文档 |
|--------|------|
| `g1Policy.hpp/cpp` | [#7 预测模型](./7-G1Policy-Prediction-Model.md)、[#16 策略](./16-Strategy-Adaptive-Adjustment.md) |
| `g1Analytics.hpp/cpp` | [#7 预测模型](./7-G1Policy-Prediction-Model.md) |
| `g1Predictions.hpp` | [#7 预测模型](./7-G1Policy-Prediction-Model.md) |
| `g1IHOPControl.hpp/cpp` | [#7 预测模型](./7-G1Policy-Prediction-Model.md)、[#16 策略](./16-Strategy-Adaptive-Adjustment.md) |
| `g1YoungGenSizer.hpp/cpp` | [#7 预测模型](./7-G1Policy-Prediction-Model.md)、[#16 策略](./16-Strategy-Adaptive-Adjustment.md) |
| `g1CollectorState.hpp` | [#16 策略](./16-Strategy-Adaptive-Adjustment.md)（完整状态机） |
| `g1HeapSizingPolicy.hpp/cpp` | [#16 策略](./16-Strategy-Adaptive-Adjustment.md)（堆扩缩容） |
| `survRateGroup.hpp/cpp` | [#16 策略](./16-Strategy-Adaptive-Adjustment.md)（存活率预测） |
| `g1YoungRemSetSamplingThread.hpp/cpp` | [#16 策略](./16-Strategy-Adaptive-Adjustment.md)（RS 采样） |
| `g1MMUTracker.hpp/cpp` | [#16 策略](./16-Strategy-Adaptive-Adjustment.md)（MMU 跟踪） |
| `g1OldGenAllocationTracker.hpp/cpp` | [#16 策略](./16-Strategy-Adaptive-Adjustment.md)（老年代分配追踪） |

### 并发标记

| 源文件 | 文档 |
|--------|------|
| `g1ConcurrentMark.hpp/cpp/inline.hpp` | [#8 并发标记](./8-Concurrent-Marking.md)、[#8A 增补](./8A-Concurrent-Marking-Deep-Dive.md) |
| `g1ConcurrentMarkThread.hpp/cpp/inline.hpp` | [#8 并发标记](./8-Concurrent-Marking.md) |
| `g1ConcurrentMarkBitMap.hpp/cpp/inline.hpp` | [#8 并发标记](./8-Concurrent-Marking.md) |
| `g1ConcurrentMarkObjArrayProcessor.hpp/cpp/inline.hpp` | [#8 并发标记](./8-Concurrent-Marking.md) |
| `g1RegionMarkStatsCache.hpp/cpp/inline.hpp` | [#8 并发标记](./8-Concurrent-Marking.md) |

### CSet + Evacuation

| 源文件 | 文档 |
|--------|------|
| `g1CollectionSet.hpp/cpp` | [#9 CSet+Evacuation](./9-CollectionSet-Evacuation.md) |
| `collectionSetChooser.hpp/cpp` | [#9 CSet+Evacuation](./9-CollectionSet-Evacuation.md) |
| `g1InCSetState.hpp` | [#9 CSet+Evacuation](./9-CollectionSet-Evacuation.md) |
| `g1ParScanThreadState.hpp/cpp/inline.hpp` | [#9 CSet+Evacuation](./9-CollectionSet-Evacuation.md) |
| `g1OopClosures.hpp/cpp/inline.hpp` | [#9 CSet+Evacuation](./9-CollectionSet-Evacuation.md)、[#12 G1RemSet](./12-G1RemSet-Complete-Flow.md) |
| `g1RootProcessor.hpp/cpp` | [#9 CSet+Evacuation](./9-CollectionSet-Evacuation.md)（Root 扫描） |
| `g1RootClosures.hpp/cpp` | [#9 CSet+Evacuation](./9-CollectionSet-Evacuation.md) |
| `g1EvacFailure.hpp/cpp` | [#11 Young GC](./11-Young-GC-Complete-STW-Flow.md)（疏散失败处理） |
| `g1EvacStats.hpp/cpp/inline.hpp` | [#9 CSet+Evacuation](./9-CollectionSet-Evacuation.md)（PLAB 统计） |

### Full GC

| 源文件 | 文档 |
|--------|------|
| `g1FullCollector.hpp/cpp` | [#10 Full GC](./10-Full-GC.md) |
| `g1FullGCMarkTask.hpp/cpp` | [#10 Full GC](./10-Full-GC.md)（Phase 1） |
| `g1FullGCMarker.hpp/cpp/inline.hpp` | [#10 Full GC](./10-Full-GC.md) |
| `g1FullGCPrepareTask.hpp/cpp` | [#10 Full GC](./10-Full-GC.md)（Phase 2） |
| `g1FullGCAdjustTask.hpp/cpp` | [#10 Full GC](./10-Full-GC.md)（Phase 3） |
| `g1FullGCCompactTask.hpp/cpp` | [#10 Full GC](./10-Full-GC.md)（Phase 4） |
| `g1FullGCCompactionPoint.hpp/cpp` | [#10 Full GC](./10-Full-GC.md) |
| `g1FullGCOopClosures.hpp/cpp/inline.hpp` | [#10 Full GC](./10-Full-GC.md) |
| `g1FullGCScope.hpp/cpp` | [#10 Full GC](./10-Full-GC.md) |
| `g1FullGCTask.hpp/cpp` | [#10 Full GC](./10-Full-GC.md) |
| `g1FullGCReferenceProcessorExecutor.hpp/cpp` | [#10 Full GC](./10-Full-GC.md)、[#15 引用处理](./15-Reference-Processing-Full-Chain.md) |

### 跨模块

| 源文件 | 文档 |
|--------|------|
| `vm_operations_g1.hpp/cpp` | [#14 SafePoint+VMOp](./14-SafePoint-VMOperation.md) |

### 辅助子系统

| 源文件 | 文档 |
|--------|------|
| `g1BlockOffsetTable.hpp/cpp/inline.hpp` | [#17 辅助子系统](./17-Auxiliary-Subsystems.md)（BOT） |
| `g1GCPhaseTimes.hpp/cpp` | [#17 辅助子系统](./17-Auxiliary-Subsystems.md)、[#18 GC 日志](./18-GC-Log-Practice.md) |
| `g1StringDedup.hpp/cpp` | [#17 辅助子系统](./17-Auxiliary-Subsystems.md)（字符串去重） |
| `g1StringDedupQueue.hpp/cpp` | [#17 辅助子系统](./17-Auxiliary-Subsystems.md) |
| `g1HRPrinter.hpp` | [#17 辅助子系统](./17-Auxiliary-Subsystems.md) |
| `g1HeapVerifier.hpp/cpp` | [#17 辅助子系统](./17-Auxiliary-Subsystems.md) |
| `g1HeapTransition.hpp/cpp` | [#18 GC 日志](./18-GC-Log-Practice.md)（堆转换日志） |

### 未独立分析的 B 类文件（纯辅助/事件/JMX/工具）

以下 20 个文件无核心 GC 逻辑，不需要独立文档：

`evacuationInfo.hpp`、`g1CollectorPolicy.hpp/cpp`、`g1EdenRegions.hpp`、`g1HeapRegionEventSender.hpp/cpp`、`g1HeapRegionTraceType.hpp`、`g1MemoryPool.hpp/cpp`、`g1MonitoringSupport.hpp/cpp`、`g1SharedClosures.hpp`、`g1StringDedupStat.hpp/cpp`、`g1SurvivorRegions.hpp/cpp`、`g1YCTypes.hpp`、`g1_globals.hpp`、`heapRegionBounds.hpp/inline.hpp`、`heapRegionTracer.hpp/cpp`、`jvmFlagConstraintsG1.hpp/cpp`、`vmStructs_g1.hpp`、`g1InitialMarkToMixedTimeTracker.hpp`
