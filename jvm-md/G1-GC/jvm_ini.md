# jvm启动核心方法概述
jvm启动的最关键的方法：JNI_CreateJavaVM_inner(),位于jni.cpp文件中
- 使用变量保证jvm只能被创建一次
- result = Threads::create_vm():超级核心的方法
    「这个方法是超级核心的方法,同样这也很复杂」
- 对返回值进行处理,重要的点在于设置了 JavaVM 和 JNIEnv 指针(这两个指针的作用是什么呢?) 后续做介绍
- JVMCI编译器初始化(skip)
```text
    对JVMCI的简单介绍:
        - JVMCI（JVM Compiler Interface）是一个允许用Java编写JIT编译器的接口
        - GraalVM 就是基于JVMCI实现的
        - 这是性能优化相关的初始化，不是VM核心功能
```
- 运行时服务记录
```text
    作用:
        - 记录应用程序开始运行的时间戳
        - 用于GC性能统计：计算应用运行时间 vs GC暂停时间的比例
        - 为JVM监控和性能分析提供基础数据
```
- JVMTI 事件通知
```text
    作用:
        - JVMTI（JVM Tool Interface）是JVM提供给调试器、性能分析工具的接口
        - 通知所有注册的JVMTI代理：主线程已经启动
        - 调试器（如IDE的调试功能）、性能分析工具（如JProfiler）依赖这些事件
```
- 线程状态转换
    - 将主线程状态从 _thread_in_vm（正在执行VM代码）转换为 _thread_in_native

## Threads::create_vm()
```text
    这个方法很复杂,在这里我先只关注超级重点的方法,对于一些基础的,容易理解的方法,后续在进行补充
这里说的这个方法就是 init_globals() -> 用于初始化jvm的核心模块的
    而init_globals()这个方法也是超级复杂,所以在这里同样只关注重点方法+重点的数据结构
    这里有3个超级核心的方法：
        1.universe_init():创建Java堆,元空间等核心数据结构「超级大核心」
        2.interpreter_init():字节码解释器初始化
        3.javaClasses_init():Java核心类初始化
    还有一些其他的,后续再补充,
```

### universe_init()
- Universe::initialize_heap():初始化堆,以G1堆为例
    -  _collectedHeap = create_heap() -> 创建 G1CollectedHeap
    ```text
        Universe::create_heap()
        └── GCConfig::arguments()->create_heap()  // 根据GC类型选择,这里创建的是 G1Arguments
            └── G1Arguments::create_heap()        // G1 GC实现
                └── create_heap_with_policy<G1CollectedHeap, G1CollectorPolicy>()
                这个方法就是创建G1堆的核心方法了
    ```

    ```cpp
    CollectedHeap* GCArguments::create_heap_with_policy() {
            Policy* policy = new Policy(); // 这里创建的是 G1CollectorPolicy
            policy->initialize_all();
            return new Heap(policy);
        }
    
    // new Policy() : 创建的是 G1CollectorPolicy ，此时内部的属性为：
    _initial_heap_byte_size = {size_t} 8589934592  // 8GB    
    _max_heap_byte_size = {size_t} 8589934592      // 8GB
    _min_heap_byte_size = {size_t} 8589934592      // 8GB
    _space_alignment = {size_t} 0 // 未初始化(Region大小)
    _heap_alignment = {size_t} 0 // 未初始化(堆的最终对齐值)
    // policy->initialize_all(); 初始化
    _initial_heap_byte_size = {size_t} 8589934592  // 8GB    
    _max_heap_byte_size = {size_t} 8589934592      // 8GB
    _min_heap_byte_size = {size_t} 8589934592      // 8GB
    _space_alignment = {size_t} 0 // 4MB(8GB下的Region大小为4MB)
    _heap_alignment = {size_t} 0 // 4MB(堆的最终对齐值-能够保证Region都按照4MB对齐,同时满足卡表和页面的对其要求)

    // new Heap(policy) 在这里初始化了很多属性,一下子搞懂是不可能的,在这里先简单的介绍一下
    
    首先， G1CollectedHeap 继承自CollectedHeap，所以它包含父类的核心属性：
    - 父类CollectedHeap的核心属性
        static int _fire_out_of_memory_count;      // OOM计数器（调试用）
        GCHeapLog* _gc_heap_log;                   // GC堆日志记录器
        MemRegion _reserved;                       // 保留的堆内存区域（核心！）
        bool _is_gc_active;                        // GC是否正在进行的标志
        static size_t _filler_array_max_size;      // 填充数组的最大大小
        unsigned int _total_collections;           // 总GC次数
        unsigned int _total_full_collections;      // 总Full GC次数
        GCCause::Cause _gc_cause;                  // 当前GC触发原因
        GCCause::Cause _gc_lastcause;              // 上次GC触发原因
        PerfStringVariable* _perf_gc_cause;        // 性能统计：GC原因
        PerfStringVariable* _perf_gc_lastcause;    // 性能统计：上次GC原因
    
    然后是 G1CollectedHeap 自己的属性：
    - 线程管理类
        G1YoungRemSetSamplingThread* _young_gen_sampling_thread;  // 年轻代记忆集采样线程
        WorkGang* _workers;                                       // 并行GC工作线程池
    - 策略与配置类
        G1CollectorPolicy* _collector_policy;  // G1收集器策略（旧版本，现在主要用G1Policy）
        G1CardTable* _card_table;              // 卡表，用于记录跨代引用
    - 内存池管理
        GCMemoryManager _memory_manager;       // GC内存管理器
        GCMemoryManager _full_gc_memory_manager; // Full GC内存管理器
        MemoryPool* _eden_pool;                // Eden内存池
        MemoryPool* _survivor_pool;            // Survivor内存池  
        MemoryPool* _old_pool;                 // 老年代内存池
    - Region集合管理
        HeapRegionSet _old_set;                // 老年代Region集合
        HeapRegionSet _humongous_set;          // 巨型对象Region集合
        uint _expansion_regions;               // 可扩展的Region数量
    - 核心管理组件
        HeapRegionManager _hrm;                // Region管理器（核心！）
        G1Allocator* _allocator;               // G1分配器
        G1HeapVerifier* _verifier;             // 堆验证器
        G1MonitoringSupport* _g1mm;            // 监控支持组件
        G1BlockOffsetTable* _bot;              // G1块偏移表
        G1ArchiveAllocator* _archive_allocator; // 归档分配器
    - 统计与监控
        size_t _summary_bytes_used;            // 已使用字节数统计
        G1EvacStats _survivor_evac_stats;      // Survivor疏散统计
        G1EvacStats _old_evac_stats;           // 老年代疏散统计
        PLABStats _survivor_plab_stats;        // Survivor PLAB统计
        PLABStats _old_plab_stats;             // 老年代PLAB统计
    - 时间与追踪   
        STWGCTimer* _gc_timer_stw;             // Stop-The-World GC计时器
        G1NewTracer* _gc_tracer_stw;           // GC事件追踪器（用于JFR等）
        ConcurrentGCTimer* _gc_timer_cm;       // 并发GC计时器
        G1OldTracer* _gc_tracer_cm;            // 并发GC事件追踪器
    - 并发标记相关
        G1ConcurrentMark* _cm;                 // G1并发标记器
        G1ConcurrentMarkThread* _cm_thread;    // 并发标记线程
        volatile uint _old_marking_cycles_started;    // 已启动的老年代标记周期数
        volatile uint _old_marking_cycles_completed;  // 已完成的老年代标记周期数
    - 并发精炼相关
        G1ConcurrentRefine* _cr;               // 并发精炼器
        DirtyCardQueueSet _dirty_card_queue_set; // 脏卡队列集
    - 并行任务管理
        RefToScanQueueSet *_task_queues;       // 并行任务队列集
    - 巨型对象回收
        size_t _humongous_object_threshold_in_words; // 巨型对象阈值（以字为单位）
        // forcus 巨型对象回收候选数组 - 高效管理跨区域大对象的回收
        // note 巨型对象跨越多个区域，需要特殊的回收策略和跟踪机制，每个区域仅需1位标记
        HumongousReclaimCandidates _humongous_reclaim_candidates;
        // forcus 优化标志：是否存在巨型对象回收候选
        // note 如果没有候选对象，可以跳过一些处理步骤，提高性能
        bool _has_humongous_reclaim_candidates;
    - 策略与收集集
        G1Policy* _g1_policy;                  // G1策略（核心决策组件）
        G1HeapSizingPolicy* _heap_sizing_policy; // 堆大小调整策略
        G1CollectionSet _collection_set;       // 收集集（本次GC要回收的Region集合）
        G1CollectorState _collector_state;     // 收集器状态
        G1HRPrinter _hr_printer;               // HeapRegion打印器
    - 年轻代管理
        // The young region list.
        G1EdenRegions _eden;                   // Eden区域管理（轻量级计数器）
        G1SurvivorRegions _survivor;           // Survivor区域管理（动态数组）
        uint _young_list_fixed_length;         // 年轻代列表固定长度
        uint _young_list_target_length;        // 年轻代列表目标长度
        uint _young_list_max_length;           // 年轻代列表最大长度
    - 失败处理与控制
        bool _evacuation_failed;               // 疏散失败标志
        EvacuationFailedInfo* _evacuation_failed_info_array; // 疏散失败信息数组
        bool _expand_heap_after_alloc_failure; // 分配失败后扩展堆标志
        bool _free_regions_coming;             // 即将有空闲Region标志
    - GC标识
        uint _next_young_gc_id;                // 下一个年轻代GC的ID
        uint _next_old_gc_id;                  // 下一个老年代GC的ID

    初次看到这里,怎么办？想放弃了....
    属性按照重要性进行简单分类：
        - 父类核心属性（基础必须理解）
            _reserved - MemRegion：保留的堆内存区域（所有堆的基础）
            _is_gc_active - bool：GC活跃状态标志
            _total_collections - 总GC次数统计
            _gc_cause - GC触发原因
        - 核心组件（必须掌握）
            _hrm - HeapRegionManager：Region的总管理器
            _allocator - G1Allocator：内存分配器
            _old_set / _humongous_set - Region集合管理
            _g1_policy - G1Policy：GC决策核心
        - 重要组件（需要理解原理）
            _workers - WorkGang：并行工作线程池
            _cm - G1ConcurrentMark：并发标记器
            _card_table - G1CardTable：跨代引用追踪
            _collection_set - 收集集管理
            _eden / _survivor - 年轻代管理
            _collector_state - G1CollectorState：收集器状态
            _task_queues - RefToScanQueueSet：并行任务队列
        - 辅助组件（了解作用即可）
            _dirty_card_queue_set - 脏卡队列集
            _cr - G1ConcurrentRefine：并发精炼器
            _cm_thread - 并发标记线程
            _heap_sizing_policy - 堆大小调整策略
            _bot - G1BlockOffsetTable：块偏移表
            _young_gen_sampling_thread - 年轻代采样线程
        - 监控统计（了解即可）
            _g1mm - G1MonitoringSupport：监控支持
            _survivor_evac_stats / _old_evac_stats - 疏散统计
            _gc_timer_stw / _gc_timer_cm - 时间追踪
            _gc_tracer_stw / _gc_tracer_cm - 事件追踪
            _verifier - G1HeapVerifier：堆验证器
            各种内存池和统计信息
    ```

    -  