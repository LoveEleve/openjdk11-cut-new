# G1CollectedHeap 完整字段分析

> 基于 OpenJDK 11 源码 `g1CollectedHeap.hpp` (第 154-1449 行)
> 分析标准：`-Xms8g -Xmx8g -XX:+UseG1GC`，G1 Region = 4MB

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

`G1CollectedHeap` 的本质是 **G1 GC 的顶层协调者**：它持有 G1 GC 所有子系统的引用（50+ 个字段），协调 HeapRegionManager（Region 管理）、G1Policy（GC 决策）、G1ConcurrentMark（并发标记）、G1ConcurrentRefine（并发精化）、G1RemSet（跨 Region 引用）等子系统，是 G1 GC 的"神经中枢"。

### 0.2 为什么需要？

G1 GC 由多个独立子系统组成，每个子系统有自己的状态和生命周期。需要一个顶层类来：(1) 持有所有子系统的引用，提供统一的访问入口；(2) 协调子系统的初始化顺序（`initialize()` 方法）；(3) 实现 `CollectedHeap` 接口，对上层（Universe/JVM）屏蔽 G1 的实现细节。

### 0.3 字段分类概览

| 类别 | 字段数 | 核心作用 |
|------|-------|---------|
| 线程与工作线程 | 2 | GC 并行执行（WorkGang + 采样线程） |
| GC 策略 | 3 | 决策控制（G1Policy/G1HeapSizingPolicy） |
| 内存管理 | 3 | 卡表/偏移表/热卡缓存 |
| 区域管理 | 6 | HeapRegionManager + Eden/Survivor/Old/Humongous |
| 分配器 | 2 | Mutator 分配 + 归档分配 |
| 并发机制 | 5 | 并发标记 + 并发精化 + 脏卡队列 |
| 引用处理 | 6 | STW + CM 两套 ReferenceProcessor |
| 性能优化 | 1 | `_in_cset_fast_test`（O(1) CSet 查询） |
| 其他 | 20+ | 统计/监控/验证/计时等 |

### 0.4 为什么这样设计？

- **为什么 G1CollectedHeap 有 50+ 个字段？** G1 是一个完整的 GC 子系统，包含并发标记、并发精化、写屏障、RSet、CSet 选择等多个独立组件；每个组件都需要一个字段引用，字段多是功能复杂的必然结果
- **为什么 `_in_cset_fast_test` 是性能优化核心？** GC 热路径（写屏障、对象复制）需要频繁判断对象是否在 CSet 中；遍历 CSet 列表是 O(n)，数组直接索引是 O(1)；这个优化在高并发场景下效果显著
- **为什么有两套 ReferenceProcessor（STW + CM）？** STW 阶段和并发标记阶段的"存活"判断标准不同，需要不同的 `IsAliveClosure`；两套独立的 ReferenceProcessor 避免了状态混乱
- **为什么 `_summary_bytes_used` 不包括当前分配区域？** 当前分配区域（Eden Region）的已用字节在 GC 前是动态变化的（每次对象分配都在增加），精确统计代价高；GC 后统一更新 `_summary_bytes_used`，GC 前的值是近似值

---

## 1. 线程与工作线程

### 1.1 G1YoungRemSetSamplingThread* _young_gen_sampling_thread

| 属性 | 说明 |
|-----|------|
| **类型** | `G1YoungRemSetSamplingThread*` |
| **定义行** | 155 |
| **作用** | 年轻代 RSet 采样线程，用于周期性采样年轻代的 remembered set，以决定是否触发 GC |
| **关键方法** | `sampling_thread()` (第 555 行) |
| **初始化** | 在 `initialize_young_gen_sampling_thread()` 中创建 |

**源码位置**：
```cpp
155:  G1YoungRemSetSamplingThread* _young_gen_sampling_thread;
...
555:  G1YoungRemSetSamplingThread* sampling_thread() const { return _young_gen_sampling_thread; }
```

---

### 1.2 WorkGang* _workers

| 属性 | 说明 |
|-----|------|
| **类型** | `WorkGang*` |
| **定义行** | 157 |
| **作用** | GC 工作线程池，用于执行并行 GC 任务（如 Young GC、并行扫描等） |
| **关键方法** | `workers()` (第 557 行) |
| **线程数** | 默认 `ParallelGCThreads`，可通过 `-XX:ParallelGCThreads=N` 配置 |

**源码位置**：
```cpp
157:  WorkGang* _workers;
...
557:  WorkGang* workers() const { return _workers; }
```

---

## 2. GC 策略与策略对象

### 2.1 G1CollectorPolicy* _collector_policy

| 属性 | 说明 |
|-----|------|
| **类型** | `G1CollectorPolicy*` |
| **定义行** | 158 |
| **作用** | G1 收集策略基类，控制 GC 触发时机、收集集合构建、目标停顿时间等 |
| **子类** | `G1YoungGenSizer`、`G1OldGenSizer` |
| **关键方法** | `collector_policy()` (第 1000 行) |

---

### 2.2 G1Policy* _g1_policy

| 属性 | 说明 |
|-----|------|
| **类型** | `G1Policy*` |
| **定义行** | 405 |
| **作用** | G1 核心策略类，决定何时触发 GC、如何选择收集集合、预测停顿时间等 |
| **包含** | 停顿预测模型、CSet 选择器、年轻代大小计算 |
| **关键方法** | `g1_policy()` (第 995 行) |

---

### 2.3 G1HeapSizingPolicy* _heap_sizing_policy

| 属性 | 说明 |
|-----|------|
| **类型** | `G1HeapSizingPolicy*` |
| **定义行** | 406 |
| **作用** | 堆大小调整策略，根据 GC 信息动态调整堆大小 |
| **关键方法** | 用于 `resize_if_necessary_after_full_collection()` |

---

## 3. 内存管理与卡表

### 3.1 G1CardTable* _card_table

| 属性 | 说明 |
|-----|------|
| **类型** | `G1CardTable*` |
| **定义行** | 159 |
| **作用** | 卡表，记录哪些内存区域被修改，用于 Remembered Set 的构建 |
| **卡大小** | 512 字节 |
| **关键方法** | `card_table()` (第 1143 行) |
| **初始化** | 在 `G1CollectedHeap::initialize()` 中创建 |

**相关类**：
- `G1CardTable` 定义于 `gc/g1/g1CardTable.hpp`
- 每个 HeapRegion 对应一段卡表区域

---

### 3.2 G1BlockOffsetTable* _bot

| 属性 | 说明 |
|-----|------|
| **类型** | `G1BlockOffsetTable*` |
| **定义行** | 188 |
| **作用** | 块偏移表，用于快速查找对象起始地址（类似分代式堆的指针） |
| **关键方法** | `bot()` (第 1020 行) |
| **关联** | 每个 HeapRegion 有自己的 `G1BlockOffsetTablePart` |

---

### 3.3 G1HotCardCache* _hot_card_cache

| 属性 | 说明 |
|-----|------|
| **类型** | `G1HotCardCache*` |
| **定义行** | 787 |
| **作用** | 热卡缓存，优化频繁引用的卡，避免重复处理已知的热卡 |
| **关键方法** | `g1_hot_card_cache()` (第 1141 行) |
| **使用场景** | write barrier 时先将脏卡放入缓存，后续批量处理 |

---

## 4. 内存池与管理器

### 4.1 GCMemoryManager _memory_manager

| 属性 | 说明 |
|-----|------|
| **类型** | `GCMemoryManager` |
| **定义行** | 163 |
| **作用** | GC 内存管理器，追踪内存使用、生成 GC 统计信息 |
| **关联** | `_eden_pool`, `_survivor_pool`, `_old_pool` |

---

### 4.2 GCMemoryManager _full_gc_memory_manager

| 属性 | 说明 |
|-----|------|
| **类型** | `GCMemoryManager` |
| **定义行** | 164 |
| **作用** | Full GC 专用的内存管理器 |

---

### 4.3 MemoryPool* _eden_pool / _survivor_pool / _old_pool

| 属性 | 说明 |
|-----|------|
| **类型** | `MemoryPool*` |
| **定义行** | 166-168 |
| **作用** | JMX 监控用的内存池，对应 Eden、Survivor、Old 区 |
| **关键方法** | `memory_pools()` (第 1005 行) |

---

## 5. 堆区域管理

### 5.1 HeapRegionManager _hrm

| 属性 | 说明 |
|-----|------|
| **类型** | `HeapRegionManager` |
| **定义行** | 210 |
| **作用** | 堆区域管理器，管理所有 HeapRegion 的生命周期 |
| **核心方法** | `num_regions()`, `max_regions()`, `num_free_regions()`, `region_at()` |
| **Region 数量** | `-Xms8g` 时约 2048 个 (8GB / 4MB) |

**关键方法**：
```cpp
1056:  uint num_regions() const { return _hrm.length(); }
1059:  uint max_regions() const { return _hrm.max_length(); }
1062:  uint num_free_regions() const { return _hrm.num_free_regions(); }
```

---

### 5.2 HeapRegionSet _old_set

| 属性 | 说明 |
|-----|------|
| **类型** | `HeapRegionSet` |
| **定义行** | 173 |
| **作用** | Old 区区域集合，管理所有 Old 区域 |
| **关键方法** | `old_set_add()`, `old_set_remove()` (第 1077-1078 行) |

---

### 5.3 HeapRegionSet _humongous_set

| 属性 | 说明 |
|-----|------|
| **类型** | `HeapRegionSet` |
| **定义行** | 176 |
| **作用** | 巨型对象区域集合，管理跨越多个 Region 的大对象 |
| **触发条件** | 对象大小 > `_humongous_object_threshold_in_words` |

---

### 5.4 uint _expansion_regions

| 属性 | 说明 |
|-----|------|
| **类型** | `uint` |
| **定义行** | 185 |
| **作用** | 堆可以扩展的区域数（用于延迟扩展） |

---

### 5.5 G1EdenRegions _eden

| 属性 | 说明 |
|-----|------|
| **类型** | `G1EdenRegions` |
| **定义行** | 397 |
| **作用** | Eden 区域计数器（仅存储数量，因为 Eden 区域随时可能被回收） |
| **字段** | `_length` (int) - 当前 Eden 区域数量 |

**工作流程**：
```cpp
// 分配新对象 -> _eden._length++
// GC 开始 -> _eden.clear() -> Eden 区域全部回收
```

---

### 5.6 G1SurvivorRegions _survivor

| 属性 | 说明 |
|-----|------|
| **类型** | `G1SurvivorRegions` |
| **定义行** | 398 |
| **作用** | Survivor 区域集合（动态数组） |
| **字段** | `_regions` (GrowableArray<HeapRegion*>*) |
| **关键方法** | `survivor()` (第 1273 行), `survivor_regions_count()` (第 1275 行) |

**重要特性**：
- Survivor 区域在并发标记时需要作为根区域扫描
- 下次 GC 前需要转化为 Eden 类型

---

## 6. 分配器

### 6.1 G1Allocator* _allocator

| 属性 | 说明 |
|-----|------|
| **类型** | `G1Allocator*` |
| **定义行** | 213 |
| **作用** | G1 分配器，管理各类分配区域（mutator alloc region、GC alloc region） |
| **关键方法** | `allocator()` (第 559 行) |
| **子组件** | `MutatorAllocRegion`, `G1GCAllocRegion` |

---

### 6.2 G1ArchiveAllocator* _archive_allocator

| 属性 | 说明 |
|-----|------|
| **类型** | `G1ArchiveAllocator*` |
| **定义行** | 228 |
| **作用** | 归档区域分配器，用于分配 Java 归档对象 |
| **用途** | 允许将堆内对象序列化后映射到固定地址 |

---

## 7. 统计与验证

### 7.1 G1EvacStats _survivor_evac_stats

| 属性 | 说明 |
|-----|------|
| **类型** | `G1EvacStats` |
| **定义行** | 231 |
| **作用** | Survivor 区疏散统计（对象数、内存量、失败次数等） |
| **关键方法** | `alloc_buffer_stats(InCSetState::Young)` |

---

### 7.2 G1EvacStats _old_evac_stats

| 属性 | 说明 |
|-----|------|
| **类型** | `G1EvacStats` |
| **定义行** | 234 |
| **作用** | Old 区疏散统计 |

---

### 7.3 G1HeapVerifier* _verifier

| 属性 | 说明 |
|-----|------|
| **类型** | `G1HeapVerifier*` |
| **定义行** | 216 |
| **作用** | 堆验证器，用于调试和验证堆的一致性 |
| **关键方法** | `verifier()` (第 563 行) |

---

### 7.4 size_t _summary_bytes_used

| 属性 | 说明 |
|-----|------|
| **类型** | `size_t` |
| **定义行** | 220 |
| **作用** | 记录 GC 后已使用的字节数（不包括当前分配区域） |
| **更新** | `increase_used()`, `decrease_used()`, `set_used()` (第 222-225 行) |

---

### 7.5 static size_t _humongous_object_threshold_in_words

| 属性 | 说明 |
|-----|------|
| **类型** | `static size_t` |
| **定义行** | 170 |
| **作用** | 巨型对象阈值，超过此大小的对象分配在 humongous 区域 |
| **计算方式** | Region 大小的一半（G1 中一个 Region = 4MB，阈值 = 2MB） |

**判断方法**：
```cpp
1242:  static bool is_humongous(size_t word_size) {
1243:    return word_size > _humongous_object_threshold_in_words;
1244:  }
```

---

### 7.6 bool _expand_heap_after_alloc_failure

| 属性 | 说明 |
|-----|------|
| **类型** | `bool` |
| **定义行** | 242 |
| **作用** | 分配失败后是否尝试扩展堆 |
| **重置** | 每次 GC 开始时重置为 true |

---

## 8. 监控与打印

### 8.1 G1MonitoringSupport* _g1mm

| 属性 | 说明 |
|-----|------|
| **类型** | `G1MonitoringSupport*` |
| **定义行** | 245 |
| **作用** | 监控支持，提供 JMX 相关的内存池和内存管理器数据 |
| **关键方法** | `g1mm()` (第 567 行) |

---

### 8.2 G1HRPrinter _hr_printer

| 属性 | 说明 |
|-----|------|
| **类型** | `G1HRPrinter` |
| **定义行** | 276 |
| **作用** | 堆区域打印机，用于打印区域分配/回收信息 |
| **启用参数** | `-XX:+PrintHeapAtGC` |
| **关键方法** | `hr_printer()` (第 647 行) |

---

## 9. 收集集合与状态

### 9.1 G1CollectionSet _collection_set

| 属性 | 说明 |
|-----|------|
| **类型** | `G1CollectionSet` |
| **定义行** | 408 |
| **作用** | 收集集合，管理本次 GC 需要回收的区域 |
| **关键方法** | `collection_set()` (第 997-998 行) |
| **包含** | Eden、Survivor、Old 区中的待回收区域 |

---

### 9.2 G1CollectorState _collector_state

| 属性 | 说明 |
|-----|------|
| **类型** | `G1CollectorState` |
| **定义行** | 289 |
| **作用** | 收集器状态机，记录当前 GC 阶段（Young、Mixed、Concurrent Cycle 等） |
| **关键方法** | `collector_state()` (第 991-992 行) |

**状态转换**：
```
Empty -> Young -> InitialMark -> Remark -> Cleanup -> ...
```

---

### 9.3 volatile uint _old_marking_cycles_started / _completed

| 属性 | 说明 |
|-----|------|
| **类型** | `volatile uint` |
| **定义行** | 293, 297 |
| **作用** | 记录老年代标记周期（Full GC 或并发周期）的开始/完成次数 |
| **关键方法** | `increment_old_marking_cycles_started()`, `increment_old_marking_cycles_completed()` |

---

## 10. 并发标记与细化

### 10.1 G1ConcurrentMark* _cm

| 属性 | 说明 |
|-----|------|
| **类型** | `G1ConcurrentMark*` |
| **定义行** | 805 |
| **作用** | 并发标记对象，管理并发标记的 bitmap、任务队列、工作线程 |
| **关键方法** | `concurrent_mark()` (第 1340 行) |
| **包含** | `_prev_mark_bitmap`, `_next_mark_bitmap`, `_top_at_mark_start` |

---

### 10.2 G1ConcurrentMarkThread* _cm_thread

| 属性 | 说明 |
|-----|------|
| **类型** | `G1ConcurrentMarkThread*` |
| **定义行** | 806 |
| **作用** | 并发标记线程，实际执行并发标记任务的后台线程 |
| **启动** | 在 `initialize()` 中启动 |

---

### 10.3 G1ConcurrentRefine* _cr

| 属性 | 说明 |
|-----|------|
| **类型** | `G1ConcurrentRefine*` |
| **定义行** | 809 |
| **作用** | 并发细化器，在并发阶段处理 Dirty Card Queue，更新 RSet |
| **关键方法** | `concurrent_refine()` (第 1344 行) |

---

### 10.4 DirtyCardQueueSet _dirty_card_queue_set

| 属性 | 说明 |
|-----|------|
| **类型** | `DirtyCardQueueSet` |
| **定义行** | 794 |
| **作用** | 脏卡队列集合，存储并发标记期间发现的脏卡 |
| **关键方法** | `dirty_card_queue_set()` (第 954 行) |

---

### 10.5 RefToScanQueueSet* _task_queues

| 属性 | 说明 |
|-----|------|
| **类型** | `RefToScanQueueSet*` |
| **定义行** | 812 |
| **作用** | 引用扫描队列集合，用于并行扫描对象图 |
| **队列数** | 与 GC 线程数相同 |
| **关键方法** | `task_queue()` (第 949 行), `num_task_queues()` (第 951 行) |

---

## 11. 疏散失败处理

### 11.1 bool _evacuation_failed

| 属性 | 说明 |
|-----|------|
| **类型** | `bool` |
| **定义行** | 815 |
| **作用** | 标记当前 GC 是否发生疏散失败 |
| **关键方法** | `evacuation_failed()` (第 1094 行) |

---

### 11.2 EvacuationFailedInfo* _evacuation_failed_info_array

| 属性 | 说明 |
|-----|------|
| **类型** | `EvacuationFailedInfo*` |
| **定义行** | 817 |
| **作用** | 疏散失败信息数组，记录每个工作线程的失败信息 |

---

### 11.3 PreservedMarksSet _preserved_marks_set

| 属性 | 说明 |
|-----|------|
| **类型** | `PreservedMarksSet` |
| **定义行** | 827 |
| **作用** | 保存疏散失败对象的原始 mark word，用于后续恢复 |
| **方法** | `preserve_mark_during_evac_failure()` |

---

## 12. 引用处理

### 12.1 ReferenceProcessor* _ref_processor_stw

| 属性 | 说明 |
|-----|------|
| **类型** | `ReferenceProcessor*` |
| **定义行** | 916 |
| **作用** | STW 引用处理器，在 Stop-the-World 阶段处理 Soft/Weak/Final/Phantom Reference |
| **关键方法** | `ref_processor_stw()` (第 1025 行) |

---

### 12.2 G1STWIsAliveClosure _is_alive_closure_stw

| 属性 | 说明 |
|-----|------|
| **类型** | `G1STWIsAliveClosure` |
| **定义行** | 931 |
| **作用** | STW 阶段判断对象是否存活（用于 Reference 处理） |
| **实现** | `do_object_b(oop p)` |

---

### 12.3 G1STWSubjectToDiscoveryClosure _is_subject_to_discovery_stw

| 属性 | 说明 |
|-----|------|
| **类型** | `G1STWSubjectToDiscoveryClosure` |
| **定义行** | 933 |
| **作用** | STW 阶段判断对象是否需要发现引用 |

---

### 12.4 ReferenceProcessor* _ref_processor_cm

| 属性 | 说明 |
|-----|------|
| **类型** | `ReferenceProcessor*` |
| **定义行** | 936 |
| **作用** | 并发标记阶段的引用处理器 |
| **关键方法** | `ref_processor_cm()` (第 1030 行) |

---

### 12.5 G1CMIsAliveClosure _is_alive_closure_cm

| 属性 | 说明 |
|-----|------|
| **类型** | `G1CMIsAliveClosure` |
| **定义行** | 944 |
| **作用** | 并发标记阶段判断对象是否存活 |

---

### 12.6 G1CMSubjectToDiscoveryClosure _is_subject_to_discovery_cm

| 属性 | 说明 |
|-----|------|
| **类型** | `G1CMSubjectToDiscoveryClosure` |
| **定义行** | 946 |
| **作用** | 并发标记阶段判断对象是否需要发现引用 |

---

## 13. 快速测试数组

### 13.1 G1InCSetStateFastTestBiasedMappedArray _in_cset_fast_test

| 属性 | 说明 |
|-----|------|
| **类型** | `G1InCSetStateFastTestBiasedMappedArray` |
| **定义行** | 1121 |
| **作用** | **GC 性能优化核心** - 将 O(n) 的 CSet 遍历查找优化为 O(1) 的数组访问 |
| **存储** | 每个 Region 对应一个字节，标记其在 collection set 中的状态 |
| **使用场景** | write barrier、对象拷贝时快速判断对象是否在 CSet 中 |
| **值** | `InCSetState::Young` / `InCSetState::Old` / `InCSetState::Humongous` / `InCSetState::NotInCSet` |

**性能意义**：
- 原始方式：遍历 CSet 列表，时间复杂度 O(n)
- 优化后：直接数组访问，时间复杂度 O(1)
- 这是 G1 GC 热路径上的关键优化

---

## 14. 巨型对象回收

### 14.1 HumongousReclaimCandidates _humongous_reclaim_candidates

| 属性 | 说明 |
|-----|------|
| **类型** | `HumongousReclaimCandidates` (继承 `G1BiasedMappedArray<bool>`) |
| **定义行** | 268 |
| **作用** | 巨型对象回收候选数组，每个 Region 仅需 1 位标记 |
| **方法** | `set_candidate()`, `is_candidate()` (第 258-263 行) |

---

### 14.2 bool _has_humongous_reclaim_candidates

| 属性 | 说明 |
|-----|------|
| **类型** | `bool` |
| **定义行** | 274 |
| **作用** | 标记是否存在巨型对象回收候选，用于跳过不必要的处理步骤 |

---

## 15. GC 计时器和追踪器

### 15.1 STWGCTimer* _gc_timer_stw

| 属性 | 说明 |
|-----|------|
| **类型** | `STWGCTimer*` |
| **定义行** | 400 |
| **作用** | STW GC 计时器，测量 GC 停顿时间 |
| **用途** | 生成 GC 日志和性能数据 |

---

### 15.2 G1NewTracer* _gc_tracer_stw

| 属性 | 说明 |
|-----|------|
| **类型** | `G1NewTracer*` |
| **定义行** | 402 |
| **作用** | STW GC 追踪器，生成详细的 GC 事件数据 |
| **关键方法** | `gc_tracer_stw()` (第 1027 行) |

---

## 16. 监听器与回调

### 16.1 G1RegionMappingChangedListener _listener

| 属性 | 说明 |
|-----|------|
| **类型** | `G1RegionMappingChangedListener` |
| **定义行** | 207 |
| **作用** | 区域映射变更监听器，当 Region 被提交/归还时更新卡表缓存 |
| **方法** | `on_commit()` (第 127 行) |

---

## 17. 软引用策略

### 17.1 SoftRefPolicy _soft_ref_policy

| 属性 | 说明 |
|-----|------|
| **类型** | `SoftRefPolicy` |
| **定义行** | 161 |
| **作用** | 软引用策略，控制软引用的回收时机 |
| **关键方法** | `soft_ref_policy()` (第 1002 行) |
| **参数** | `-XX:SoftRefLRUPolicyMSPerMB` |

---

## 18. 其他

### 18.1 size_t _max_heap_capacity

| 属性 | 说明 |
|-----|------|
| **类型** | `size_t` |
| **定义行** | 1448 |
| **作用** | 最大堆容量 |

---

## 字段分类汇总

| 类别 | 字段数 | 核心功能 |
|------|-------|---------|
| 线程与工作线程 | 2 | GC 并行执行 |
| GC 策略 | 3 | 决策控制 |
| 内存管理 | 3 | 卡表、偏移表、热卡缓存 |
| 内存池 | 5 | 监控和管理 |
| 区域管理 | 6 | Region 生命周期 |
| 分配器 | 2 | 对象分配 |
| 统计验证 | 6 | 性能统计和调试 |
| 监控打印 | 2 | JMX 和日志 |
| 收集集合 | 3 | GC 目标区域 |
| 并发机制 | 5 | 并发标记和细化 |
| 疏散失败 | 3 | 错误恢复 |
| 引用处理 | 6 | Reference 处理 |
| 快速测试 | 1 | 性能优化 |
| 巨型对象 | 2 | 大对象管理 |
| 计时追踪 | 2 | 性能数据 |
| 其他 | 2 | 软引用、容量 |

---

## 字段关系图

```
G1CollectedHeap
├── 线程与工作线程
│   ├── _young_gen_sampling_thread
│   └── _workers ──────────────────► WorkGang (GC 线程池)
│
├── GC 策略
│   ├── _collector_policy ────────► G1CollectorPolicy
│   ├── _g1_policy ───────────────► G1Policy
│   └── _heap_sizing_policy ──────► G1HeapSizingPolicy
│
├── 内存管理
│   ├── _card_table ───────────────► G1CardTable (卡表)
│   ├── _bot ──────────────────────► G1BlockOffsetTable
│   └── _hot_card_cache ──────────► G1HotCardCache
│
├── 区域管理
│   ├── _hrm ──────────────────────► HeapRegionManager
│   │                                 └── HeapRegion[]
│   ├── _old_set ─────────────────► HeapRegionSet
│   ├── _humongous_set ───────────► HeapRegionSet
│   ├── _eden ─────────────────────► G1EdenRegions (int)
│   └── _survivor ────────────────► G1SurvivorRegions (数组)
│
├── 分配器
│   ├── _allocator ────────────────► G1Allocator
│   │                                 ├── MutatorAllocRegion
│   │                                 └── G1GCAllocRegion
│   └── _archive_allocator ───────► G1ArchiveAllocator
│
├── 并发机制
│   ├── _cm ───────────────────────► G1ConcurrentMark
│   │                                 ├── _prev_mark_bitmap
│   │                                 └── _next_mark_bitmap
│   ├── _cm_thread ────────────────► G1ConcurrentMarkThread
│   ├── _cr ──────────────────────► G1ConcurrentRefine
│   ├── _dirty_card_queue_set ────► DirtyCardQueueSet
│   └── _task_queues ──────────────► RefToScanQueueSet
│
├── 引用处理
│   ├── _ref_processor_stw ────────► ReferenceProcessor (STW)
│   ├── _ref_processor_cm ────────► ReferenceProcessor (CM)
│   ├── _is_alive_closure_stw
│   ├── _is_alive_closure_cm
│   ├── _is_subject_to_discovery_stw
│   └── _is_subject_to_discovery_cm
│
└── 性能优化
    └── _in_cset_fast_test ───────► G1InCSetStateFastTestBiasedMappedArray
                                      (O(1) CSet 查询)
```

---

## 初始化时序

### create_heap 阶段（构造函数）

在 `G1CollectedHeap::G1CollectedHeap()` 中初始化的字段：
- `_collector_policy` (参数传入)
- `_soft_ref_policy`
- `_g1_policy` (新建)
- `_collection_set` (新建)
- `_allocator` (新建)

### initialize_heap 阶段

在 `G1CollectedHeap::initialize()` 中初始化的字段：
- `_card_table`
- `_hrm`
- `_workers`
- `_gc_timer_stw`
- `_gc_tracer_stw`
- `_ref_processor_stw` / `_ref_processor_cm`
- `_cm` / `_cm_thread`
- `_cr`
- `_task_queues`
- `_dirty_card_queue_set`

---

## GDB 验证命令

```gdb
# 查看 G1CollectedHeap 对象地址
(gdb) p g1h

# 查看所有核心字段
(gdb) p *g1h

# 查看 Region 数量
(gdb) p g1h->_hrm._length

# 查看 Eden/Survivor 区域数
(gdb) p g1h->_eden._length
(gdb) p g1h->_survivor._length

# 查看并发标记
(gdb) p g1h->_cm
(gdb) p g1h->_cm_thread

# 查看收集集合
(gdb) p g1h->_collection_set

# 查看卡表
(gdb) p g1h->_card_table

# 查看 RSet
(gdb) p g1h->_g1_rem_set
```

---

## JVM 参数

| 功能 | 参数 |
|------|------|
| 启用 G1 GC | `-XX:+UseG1GC` |
| 设置最大停顿时间 | `-XX:MaxGCPauseMillis=200` |
| 设置 Region 大小 | `-XX:G1HeapRegionSize=4m` |
| 设置年轻代比例 | `-XX:NewRatio=2` 或 `-XX:G1NewSizePercent` |
| 启用 GC 日志 | `-Xlog:gc*` |
| 启用区域打印 | `-XX:+PrintHeapAtGC` |
| 并发标记线程数 | `-XX:ConcGCThreads=N` |
| Parallel GC 线程数 | `-XX:ParallelGCThreads=N` |

---

## 总结

G1CollectedHeap 是 G1 GC 的核心类，包含 **50+ 个字段**，分为以下大类：

1. **线程与并行**：支持多线程并行 GC
2. **策略决策**：控制何时触发 GC、收集哪些区域
3. **内存布局**：管理 Region、卡表、偏移表
4. **对象分配**：Mutator 和 GC 的分配区域
5. **并发机制**：并发标记、并发细化
6. **引用处理**：Soft/Weak/Final/Phantom Reference
7. **性能优化**：_in_cset_fast_test 数组将 O(n) 优化为 O(1)

理解这些字段及其关系，是深入学习 G1 GC 的基础。
