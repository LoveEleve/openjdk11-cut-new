# G1CollectedHeap 字段定义清单

> 基于 OpenJDK 11 源码 `g1CollectedHeap.hpp`  
> 标准环境：-Xms8g -Xmx8g -XX:+UseG1GC，G1 Region = 4MB

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文是 `G1CollectedHeap` 类的**完整字段定义清单**：按功能分组列出 G1CollectedHeap 的所有私有/保护字段，说明每个字段的类型、含义和用途，是理解 G1 GC 内部状态的参考手册。

### 0.2 为什么需要？

`G1CollectedHeap` 是 G1 GC 的核心类，包含数十个字段，涵盖堆内存管理、Region 分配、并发标记、GC 策略等各个方面。没有一份完整的字段清单，很难在阅读源码时快速理解各字段的作用。

### 0.3 字段分类

| 类别 | 字段数量 | 代表字段 |
|------|---------|---------|
| 堆内存管理 | ~10 | `_hrm`, `_g1mm`, `_summary_bytes_used` |
| Region 分配 | ~8 | `_allocator`, `_survivor`, `_old_set` |
| 并发标记 | ~5 | `_cm`, `_cm_thread` |
| GC 策略 | ~5 | `_policy`, `_g1h` |
| 卡表/RSet | ~5 | `_card_table`, `_hot_card_cache` |
| 其他 | ~10 | 各种统计/标志字段 |

### 0.4 为什么这样设计？

G1CollectedHeap 字段多而复杂，是因为 G1 GC 本身就是一个复杂的系统：需要同时管理 Young/Old/Humongous Region、维护 RSet、支持并发标记、实现自适应停顿时间预测。每类功能都需要对应的状态字段。

---

/*
 * G1CollectedHeap 字段定义清单（C++ 风格注释版）
 */

class G1CollectedHeap : public CollectedHeap {

private:
    // ========================================================================
    // 第一部分：线程与工作线程
    // ========================================================================

    // 年轻代 RSet 采样线程
    // 作用：周期性采样年轻代的 remembered set，以决定是否触发 GC
    // 采样间隔：每 300ms 采样一次
    G1YoungRemSetSamplingThread* _young_gen_sampling_thread;

    // GC 工作线程池
    // 作用：执行并行 GC 任务（Young GC、并行扫描、对象复制等）
    // 线程数：ParallelGCThreads（默认 CPU * 5/8）
    // 可通过 -XX:ParallelGCThreads=N 配置
    WorkGang* _workers;

    // ========================================================================
    // 第二部分：GC 策略
    // ========================================================================

    // G1 收集器策略基类
    // 作用：控制 GC 触发时机、收集集合构建、目标停顿时间等
    // 子类：G1YoungGenSizer、G1OldGenSizer
    G1CollectorPolicy* _collector_policy;

    // 软引用策略
    // 作用：控制软引用的回收时机
    // 参数：-XX:SoftRefLRUPolicyMSPerMB（默认 1000ms）
    SoftRefPolicy _soft_ref_policy;

    // ========================================================================
    // 第三部分：内存管理器
    // ========================================================================

    // GC 内存管理器
    // 作用：追踪内存使用、生成 GC 统计信息
    // 关联：_eden_pool、_survivor_pool、_old_pool
    GCMemoryManager _memory_manager;

    // Full GC 专用内存管理器
    GCMemoryManager _full_gc_memory_manager;

    // Eden 区内存池（JMX 监控用）
    MemoryPool* _eden_pool;

    // Survivor 区内存池（JMX 监控用）
    MemoryPool* _survivor_pool;

    // Old 区内存池（JMX 监控用）
    MemoryPool* _old_pool;

    // ========================================================================
    // 第四部分：堆区域管理
    // ========================================================================

    // 巨型对象阈值（静态）
    // 作用：超过此大小的对象分配在 humongous 区域
    // 计算：Region 大小的一半 = 2MB（4MB Region）
    static size_t _humongous_object_threshold_in_words;

    // Old 区区域集合
    // 作用：管理所有 Old 区域
    // 方法：old_set_add()、old_set_remove()
    HeapRegionSet _old_set;

    // 巨型对象区域集合
    // 作用：管理跨越多个 Region 的大对象
    // 触发条件：对象大小 > _humongous_object_threshold_in_words
    HeapRegionSet _humongous_set;

    // 堆可以扩展的区域数
    // 作用：用于延迟扩展
    uint _expansion_regions;

    // 块偏移表
    // 作用：快速定位对象起始地址（类似分代式堆的指针）
    // 核心算法：对数跳跃（基 16），O(log n) 查询
    // 内存开销：约 0.2%
    G1BlockOffsetTable* _bot;

    // 区域映射变更监听器
    // 作用：当 Region 被提交/归还时更新卡表缓存
    // 方法：on_commit()
    G1RegionMappingChangedListener _listener;

    // HeapRegion 管理器
    // 作用：管理所有 HeapRegion 的生命周期
    // Region 数量：2048 个（8GB / 4MB）
    // 核心方法：num_regions()、max_regions()、region_at()
    HeapRegionManager _hrm;

    // G1 分配器
    // 作用：管理各类分配区域（mutator alloc region、GC alloc region）
    // 子组件：MutatorAllocRegion、G1GCAllocRegion
    G1Allocator* _allocator;

    // 堆验证器
    // 作用：调试和验证堆的一致性
    G1HeapVerifier* _verifier;

    // GC 后已使用的字节数
    // 作用：记录 GC 后已使用的内存（不包括当前分配区域）
    // 更新方法：increase_used()、decrease_used()、set_used()
    size_t _summary_bytes_used;

    // ========================================================================
    // 第五部分：分配器相关
    // ========================================================================

    // 归档区域分配器
    // 作用：用于分配 Java 归档对象
    // 用途：允许将堆内对象序列化后映射到固定地址
    G1ArchiveAllocator* _archive_allocator;

    // Survivor 区疏散统计
    // 作用：记录 Survivor 区对象复制数量、内存量、失败次数等
    // 关键方法：alloc_buffer_stats(InCSetState::Young)
    G1EvacStats _survivor_evac_stats;

    // Old 区疏散统计
    G1EvacStats _old_evac_stats;

    // 分配失败后是否尝试扩展堆
    // 作用：标记当前是否允许扩展堆
    // 重置：每次 GC 开始时重置为 true
    bool _expand_heap_after_alloc_failure;

    // 监控支持
    // 作用：提供 JMX 相关的内存池和内存管理器数据
    // 核心功能：将 Region 模型转换为传统分代模型供 jstat 使用
    G1MonitoringSupport* _g1mm;

    // 巨型对象回收候选数组
    // 作用：标记可回收的 Humongous Region，每个 Region 仅需 1 位
    // 方法：set_candidate()、is_candidate()
    HumongousReclaimCandidates _humongous_reclaim_candidates;

    // 是否存在巨型对象回收候选
    // 作用：优化标志，如果没有候选对象可以跳过一些处理步骤
    bool _has_humongous_reclaim_candidates;

    // 堆区域打印机
    // 作用：打印区域分配/回收信息
    // 启用参数：-XX:+PrintHeapAtGC
    G1HRPrinter _hr_printer;

    // ========================================================================
    // 第六部分：GC 状态
    // ========================================================================

    // 收集器状态机
    // 作用：记录当前 GC 阶段（Young、Mixed、Concurrent Cycle 等）
    // 状态转换：Empty -> Young -> InitialMark -> Remark -> Cleanup -> ...
    G1CollectorState _collector_state;

    // 记录老年代标记周期开始次数
    // 包括：Full GC 或并发周期
    volatile uint _old_marking_cycles_started;

    // 记录老年代标记周期完成次数
    volatile uint _old_marking_cycles_completed;

    // ========================================================================
    // 第七部分：年轻代管理
    // ========================================================================

    // Eden 区域计数器
    // 作用：记录当前 Eden 区域数量
    // 说明：仅存储数量（int），因为 Eden 随时可能被回收
    // 工作流程：
    //   - 分配新对象 -> _eden._length++
    //   - GC 开始 -> _eden.clear() -> Eden 区域全部回收
    G1EdenRegions _eden;

    // Survivor 区域集合
    // 作用：管理 Survivor 区域（动态数组）
    // 字段：_regions (GrowableArray<HeapRegion*>*)
    // 重要特性：
    //   - 并发标记时需要作为根区域扫描
    //   - 下次 GC 前需要转化为 Eden 类型
    G1SurvivorRegions _survivor;

    // ========================================================================
    // 第八部分：GC 策略对象
    // ========================================================================

    // STW GC 计时器
    // 作用：测量 GC 停顿时间
    // 用途：生成 GC 日志和性能数据
    STWGCTimer* _gc_timer_stw;

    // STW GC 追踪器
    // 作用：生成详细的 GC 事件数据
    G1NewTracer* _gc_tracer_stw;

    // G1 核心策略
    // 作用：决定何时触发 GC、如何选择收集集合、预测停顿时间等
    // 包含：停顿预测模型、CSet 选择器、年轻代大小计算
    G1Policy* _g1_policy;

    // 堆大小调整策略
    // 作用：根据 GC 信息动态调整堆大小
    G1HeapSizingPolicy* _heap_sizing_policy;

    // 收集集合
    // 作用：管理本次 GC 需要回收的区域
    // 包含：Eden、Survivor、Old 区中的待回收区域
    G1CollectionSet _collection_set;

    // ========================================================================
    // 第九部分：并发机制
    // ========================================================================

    // 热卡缓存
    // 作用：优化频繁引用的卡，避免重复处理已知的热卡
    // 使用场景：write barrier 时先将脏卡放入缓存，后续批量处理
    // 核心参数：热卡阈值 = 4，缓存大小 = 1024 slots
    G1HotCardCache* _hot_card_cache;

    // G1 Remembered Set
    // 作用：管理跨 Region 引用，提供引用查询和更新
    // 核心功能：协调卡表、热卡缓存和各 Region 的记忆集
    G1RemSet* _g1_rem_set;

    // 脏卡队列集合
    // 作用：存储并发标记期间发现的脏卡
    // 处理时机：并发细化线程 / GC Update RS 阶段
    DirtyCardQueueSet _dirty_card_queue_set;

    // 并发标记对象
    // 作用：管理并发标记的 bitmap、任务队列、工作线程
    // 包含：_prev_mark_bitmap、_next_mark_bitmap、_top_at_mark_start
    G1ConcurrentMark* _cm;

    // 并发标记线程
    // 作用：实际执行并发标记任务的后台线程
    // 启动：在 initialize() 中启动
    G1ConcurrentMarkThread* _cm_thread;

    // 并发细化器
    // 作用：在并发阶段处理 Dirty Card Queue，更新 RSet
    // 核心方法：concurrent_refine()、do_refinement_step()
    G1ConcurrentRefine* _cr;

    // 引用扫描队列集合
    // 作用：用于并行扫描对象图
    // 队列数：与 GC 线程数相同
    // 核心方法：task_queue()、num_task_queues()
    RefToScanQueueSet* _task_queues;

    // ========================================================================
    // 第十部分：疏散失败处理
    // ========================================================================

    // 疏散失败标志
    // 作用：标记当前 GC 是否发生疏散失败
    // 方法：evacuation_failed()
    bool _evacuation_failed;

    // 疏散失败信息数组
    // 作用：记录每个工作线程的失败信息
    EvacuationFailedInfo* _evacuation_failed_info_array;

    // 原始 mark 保存集合
    // 作用：保存疏散失败对象的原始 mark word，用于后续恢复
    // 场景：Evacuation Failure 时使用 mark word 存储转发指针
    PreservedMarksSet _preserved_marks_set;

    // ========================================================================
    // 第十一部分：引用处理
    // ========================================================================

    // STW 引用处理器
    // 作用：在 Stop-the-World 阶段处理 Soft/Weak/Final/Phantom Reference
    // 关键方法：ref_processor_stw()
    ReferenceProcessor* _ref_processor_stw;

    // STW 阶段判断对象是否存活（用于 Reference 处理）
    G1STWIsAliveClosure _is_alive_closure_stw;

    // STW 阶段判断对象是否需要发现引用
    G1STWSubjectToDiscoveryClosure _is_subject_to_discovery_stw;

    // 并发标记阶段的引用处理器
    ReferenceProcessor* _ref_processor_cm;

    // 并发标记阶段判断对象是否存活
    G1CMIsAliveClosure _is_alive_closure_cm;

    // 并发标记阶段判断对象是否需要发现引用
    G1CMSubjectToDiscoveryClosure _is_subject_to_discovery_cm;

    // ========================================================================
    // 第十二部分：性能优化核心
    // ========================================================================

    // CSet 快速测试数组（性能优化核心）
    // 作用：将 O(n) 的 CSet 遍历查找优化为 O(1) 的数组访问
    // 存储：每个 Region 对应一个字节，标记其在 collection set 中的状态
    // 使用场景：
    //   - write barrier 判断对象是否在 CSet
    //   - 对象拷贝时快速判断目标 Region
    // 值说明：
    //   0: NotInCSet    - 不在 CSet
    //   1: Young        - 年轻代，在 CSet 中
    //   2: Old          - 老年代，在 CSet 中
    //  -1: Humongous    - 巨型对象
    //
    // 为什么需要这个？
    //   - 问题：GC 过程中需要频繁判断对象/Region 是否在 CSet 中
    //   - 原始方式：遍历 CSet 列表 -> O(n)
    //   - 优化后：数组直接索引 -> O(1)
    //   - 这是 G1 GC 热路径上的关键优化！
    G1InCSetStateFastTestBiasedMappedArray _in_cset_fast_test;

    // ========================================================================
    // 第十三部分：其他
    // ========================================================================

    // 最大堆容量
    size_t _max_heap_capacity;

};
