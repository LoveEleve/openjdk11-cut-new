# D.1 G1ConcurrentMark - 并发标记

> G1 并发标记是实现**低延迟**的核心，与应用线程同时运行，减少 STW 暂停

---

## 1. 并发标记的五个阶段

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      G1 并发标记周期（Concurrent Marking Cycle）              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ① Initial Mark (STW)    ② Root Region Scan    ③ Concurrent Mark           │
│  ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐       │
│  │ 标记 GC Roots    │    │ 扫描 Survivor    │    │ 遍历整个堆       │       │
│  │ 直接引用的对象   │ →  │ 区域的根引用     │ →  │ 标记存活对象     │       │
│  │ (Young GC 顺带)  │    │ (并发执行)       │    │ (并发执行)       │       │
│  └──────────────────┘    └──────────────────┘    └──────────────────┘       │
│         ↓                                                                    │
│  ④ Remark (STW)          ⑤ Cleanup (STW + Concurrent)                       │
│  ┌──────────────────┐    ┌──────────────────┐                               │
│  │ 处理 SATB 队列   │    │ 回收空 Region    │                               │
│  │ 完成最终标记     │ →  │ 重置 RSet        │                               │
│  │ 处理弱引用       │    │ 排序 Region      │                               │
│  └──────────────────┘    └──────────────────┘                               │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

时间分布（典型值）：
  Initial Mark:  ~10ms (STW，顺带 Young GC)
  Root Region:   ~10-50ms (并发)
  Concurrent:    ~100-500ms (并发，取决于存活对象数)
  Remark:        ~10-50ms (STW)
  Cleanup:       ~10ms (STW + 并发)
```

---

## 2. G1ConcurrentMark 类结构

```cpp
// g1ConcurrentMark.hpp:301
class G1ConcurrentMark : public CHeapObj<mtGC> {
    // ======== 核心组件 ========
    G1ConcurrentMarkThread* _cm_thread;      // 并发标记线程
    G1CollectedHeap*        _g1h;            // G1 堆引用
    
    // ======== 双缓冲位图 ========
    G1CMBitMap              _mark_bitmap_1;  // 位图 1
    G1CMBitMap              _mark_bitmap_2;  // 位图 2
    G1CMBitMap*             _prev_mark_bitmap; // → 已完成的（只读）
    G1CMBitMap*             _next_mark_bitmap; // → 进行中的（可写）
    
    // ======== 并行任务管理 ========
    G1CMMarkStack           _global_mark_stack; // 全局标记栈（溢出用）
    G1CMTask**              _tasks;             // 任务数组（13个）
    G1CMTaskQueueSet*       _task_queues;       // 任务队列集合
    ParallelTaskTerminator  _terminator;        // 终止协调器
    
    // ======== 工作线程 ========
    WorkGang*               _concurrent_workers; // "G1 Conc" 线程池
    uint                    _num_concurrent_workers; // 并发线程数（3）
    uint                    _max_num_tasks;     // 最大任务数（13）
    
    // ======== 根区域管理 ========
    G1CMRootRegions         _root_regions;      // Survivor 区域
    
    // ======== 状态标志 ========
    volatile bool           _has_overflown;     // 标记栈溢出
    volatile bool           _concurrent;        // 是否并发阶段
    volatile bool           _has_aborted;       // 是否中止
};
```

---

## 3. 初始化详解

### 3.1 创建入口

```cpp
// g1CollectedHeap.cpp:2191
_cm = new G1ConcurrentMark(this, prev_bitmap_storage, next_bitmap_storage);
if (_cm == NULL || !_cm->completed_initialization()) {
    vm_shutdown_during_initialization("Could not create/initialize G1ConcurrentMark");
    return JNI_ENOMEM;
}
_cm_thread = _cm->cm_thread();  // 获取并发标记线程
```

### 3.2 构造函数核心初始化

```cpp
// g1ConcurrentMark.cpp:363
G1ConcurrentMark::G1ConcurrentMark(G1CollectedHeap* g1h,
                                   G1RegionToSpaceMapper* prev_bitmap_storage,
                                   G1RegionToSpaceMapper* next_bitmap_storage) :
    _g1h(g1h),
    _completed_initialization(false),
    
    // ① 双缓冲位图
    _mark_bitmap_1(),
    _mark_bitmap_2(),
    _prev_mark_bitmap(&_mark_bitmap_1),  // 已完成的位图
    _next_mark_bitmap(&_mark_bitmap_2),  // 工作中的位图
    
    // ② 堆范围
    _heap(_g1h->reserved_region()),
    
    // ③ 根区域管理器
    _root_regions(),
    
    // ④ 全局标记栈
    _global_mark_stack(),
    
    // ⑤ 线程 ID 偏移
    _worker_id_offset(DirtyCardQueueSet::num_par_ids() + G1ConcRefinementThreads),
    
    // ⑥ 任务数量
    _max_num_tasks(ParallelGCThreads),  // 13
    
    // ⑦ 任务队列集合
    _task_queues(new G1CMTaskQueueSet((int)_max_num_tasks)),
    
    // ⑧ 终止器
    _terminator(ParallelTaskTerminator((int)_max_num_tasks, _task_queues)),
    
    // ⑨ 统计信息
    _region_mark_stats(NEW_C_HEAP_ARRAY(G1RegionMarkStats, _g1h->max_regions(), mtGC)),
    _top_at_rebuild_starts(NEW_C_HEAP_ARRAY(HeapWord*, _g1h->max_regions(), mtGC))
{
    // ⑩ 初始化位图
    _mark_bitmap_1.initialize(g1h->reserved_region(), prev_bitmap_storage);
    _mark_bitmap_2.initialize(g1h->reserved_region(), next_bitmap_storage);
    
    // ⑪ 创建并发标记线程
    _cm_thread = new G1ConcurrentMarkThread(this);
    
    // ⑫ 配置 SATB 队列
    SATBMarkQueueSet& satb_qs = G1BarrierSet::satb_mark_queue_set();
    satb_qs.set_buffer_size(G1SATBBufferSize);  // 1024
    
    // ⑬ 初始化根区域
    _root_regions.init(_g1h->survivor(), this);
    
    // ⑭ 计算并发线程数
    // ConcGCThreads = max((ParallelGCThreads + 2) / 4, 1) = 3
    uint marking_thread_num = scale_concurrent_worker_threads(ParallelGCThreads);
    FLAG_SET_ERGO(uint, ConcGCThreads, marking_thread_num);
    
    // ⑮ 创建并发工作线程池
    _concurrent_workers = new WorkGang("G1 Conc", _max_concurrent_workers, false, true);
    _concurrent_workers->initialize_workers();
    
    // ⑯ 初始化全局标记栈
    _global_mark_stack.initialize(MarkStackSize, MarkStackSizeMax);
    
    // ⑰ 创建任务和任务队列
    _tasks = NEW_C_HEAP_ARRAY(G1CMTask*, _max_num_tasks, mtGC);
    for (uint i = 0; i < _max_num_tasks; ++i) {
        G1CMTaskQueue* task_queue = new G1CMTaskQueue();
        task_queue->initialize();  // 分配 1MB 存储
        _task_queues->register_queue(i, task_queue);
        _tasks[i] = new G1CMTask(i, this, task_queue, ...);
    }
    
    _completed_initialization = true;
}
```

---

## 4. 关键数据结构

### 4.1 双缓冲位图

```
┌─────────────────────────────────────────────────────────────────┐
│                    双缓冲位图机制                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  _mark_bitmap_1 (128MB)          _mark_bitmap_2 (128MB)         │
│  ┌────────────────────────┐      ┌────────────────────────┐     │
│  │ 0101001010110...       │      │ 1010110101001...       │     │
│  │ (每64字节堆→1bit)      │      │ (每64字节堆→1bit)      │     │
│  └────────────────────────┘      └────────────────────────┘     │
│           ↑                              ↑                       │
│   _prev_mark_bitmap              _next_mark_bitmap              │
│   (已完成，只读)                 (进行中，可写)                  │
│                                                                  │
│  标记周期完成时：                                                │
│  ┌────────────────────────────────────────────────────────┐     │
│  │ swap(_prev_mark_bitmap, _next_mark_bitmap);  // O(1)   │     │
│  └────────────────────────────────────────────────────────┘     │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 任务队列架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          任务队列架构（13个）                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  _task_queues (G1CMTaskQueueSet)                                            │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │ [0]        [1]        [2]     ...    [12]                            │   │
│  │  ↓          ↓          ↓              ↓                              │   │
│  │ Queue0    Queue1    Queue2    ...   Queue12                          │   │
│  │ (1MB)     (1MB)     (1MB)           (1MB)                            │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  每个 Queue 容量 = 131070 个 G1TaskQueueEntry                               │
│                                                                              │
│  _tasks (G1CMTask*[])                                                        │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │ Task0 ←→ Queue0                                                      │   │
│  │ Task1 ←→ Queue1                                                      │   │
│  │ ...                                                                  │   │
│  │ Task12 ←→ Queue12                                                    │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  工作窃取：Queue 空时从其他 Queue 偷取                                       │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.3 G1TaskQueueEntry

```cpp
// g1ConcurrentMark.hpp:55
class G1TaskQueueEntry {
    void* _holder;  // 可存储两种类型
    
    // 最低位区分类型
    static const uintptr_t ArraySliceBit = 1;
    
    // 类型 1：普通对象指针
    oop obj() const { return (oop)_holder; }
    
    // 类型 2：大数组切片地址
    HeapWord* slice() const { 
        return (HeapWord*)((uintptr_t)_holder & ~ArraySliceBit); 
    }
};
```

**为什么支持数组切片？**
```
大数组问题：new Object[1000000] 包含大量引用
  - 一次性扫描耗时过长
  - 阻塞其他线程获取工作

解决方案：将大数组分片处理
  - 每片作为独立任务入队
  - 支持增量扫描，提高响应性
```

---

## 5. 线程数量计算

```cpp
// 并发标记线程数
ConcGCThreads = max((ParallelGCThreads + 2) / 4, 1)

// 8GB 堆（ParallelGCThreads = 13）：
ConcGCThreads = (13 + 2) / 4 = 3
```

**两种线程数的区别**：

| | ParallelGCThreads | ConcGCThreads |
|---|---|---|
| **用途** | STW 并行阶段 | 并发阶段 |
| **典型值** | 13 | 3 |
| **CPU 占用** | 100%（STW 期间） | ~25%（与应用共享） |
| **使用场景** | Young GC, Remark | Concurrent Mark |

---

## 6. 全局标记栈

```cpp
// 初始化
_global_mark_stack.initialize(MarkStackSize, MarkStackSizeMax);

// 默认值
MarkStackSize = 3 * ConcGCThreads * TASKQUEUE_SIZE  // 约 400K entries
MarkStackSizeMax = 512M entries
```

**作用**：
- 当任务本地队列满时，溢出到全局栈
- 支持动态扩展（按需分配）
- 所有线程共享（需同步）

---

## 7. 内存布局总览

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    G1ConcurrentMark 内存占用                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  位图（与堆共用映射器）                                                      │
│  ├── _mark_bitmap_1: 128MB                                                  │
│  └── _mark_bitmap_2: 128MB                                                  │
│                                                                              │
│  任务队列（C++ 堆）                                                          │
│  └── 13 × 1MB = 13MB                                                        │
│                                                                              │
│  全局标记栈（虚拟内存，按需提交）                                            │
│  └── 初始: ~3MB，最大: 4GB                                                  │
│                                                                              │
│  Region 统计信息（C++ 堆）                                                   │
│  └── 2048 × sizeof(G1RegionMarkStats) ≈ 几十 KB                            │
│                                                                              │
│  任务对象（C++ 堆）                                                          │
│  └── 13 × sizeof(G1CMTask) ≈ 几 KB                                         │
│                                                                              │
│  总计：约 270MB（主要是位图）                                               │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 8. 初始化完成后的状态

```cpp
G1ConcurrentMark {
    _cm_thread: G1ConcurrentMarkThread* (已启动)
    _g1h: G1CollectedHeap*
    _completed_initialization: true
    
    // 双缓冲位图
    _mark_bitmap_1: 128MB (已初始化)
    _mark_bitmap_2: 128MB (已初始化)
    _prev_mark_bitmap: → _mark_bitmap_1
    _next_mark_bitmap: → _mark_bitmap_2
    
    // 任务管理
    _max_num_tasks: 13
    _task_queues: G1CMTaskQueueSet[13]
    _tasks: G1CMTask*[13]
    
    // 工作线程
    _concurrent_workers: WorkGang("G1 Conc", 3)
    _num_concurrent_workers: 3
    
    // 状态
    _has_overflown: false
    _concurrent: false
    _has_aborted: false
}
```

---

## 9. 日志验证

```bash
# 启用并发标记日志
java -Xms8g -Xmx8g -XX:+UseG1GC \
     -Xlog:gc*=debug \
     -version
```

**预期输出**：
```
[0.xxx][debug][gc] ConcGCThreads: 3 offset 16
[0.xxx][debug][gc] ParallelGCThreads: 13
```

---

## 10. 总结

### 10.1 G1ConcurrentMark 核心组件

| 组件 | 作用 | 数量/大小 |
|------|------|-----------|
| 双缓冲位图 | 标记存活对象 | 2 × 128MB |
| 任务队列 | 存储灰色对象 | 13 × 1MB |
| 全局标记栈 | 溢出处理 | 动态扩展 |
| 并发标记线程 | 执行标记 | 1 个 |
| 并发工作线程 | 并行标记 | 3 个 |

### 10.2 关键设计点

1. **双缓冲**：避免并发标记与 Mixed GC 冲突
2. **工作窃取**：任务队列空时从其他队列偷取
3. **增量处理**：大数组分片，提高响应性
4. **SATB**：写前屏障防止漏标
5. **线程数控制**：ConcGCThreads ≈ ParallelGCThreads / 4

### 10.3 为什么任务数是 13 而不是 3？

```
任务队列不仅在并发阶段使用，还在 STW 阶段使用：
- Concurrent Mark: 3 个并发线程
- Remark (STW): 13 个并行线程

所以需要 13 个任务队列来支持最大并行度
```
