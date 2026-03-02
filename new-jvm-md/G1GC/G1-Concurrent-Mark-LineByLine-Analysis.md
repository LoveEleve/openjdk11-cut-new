# G1 Concurrent Mark 逐行深度源码分析

> **分析目标**: G1并发标记完整流程  
> **源码文件**: `src/hotspot/share/gc/g1/g1ConcurrentMark.cpp/hpp`  
> **分析标准**: 面试级深度 - 逐行解释 + 面试问答 + GDB调试技巧

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文是 G1 并发标记的**逐行深度分析**，聚焦于 `G1ConcurrentMark` 类的核心方法：`checkpoint_roots_initial_pre()`（Initial Mark 前置）、`scan_root_regions()`（Root Region Scan）、`mark_from_roots()`（Concurrent Mark 主循环）、`remark()`（Remark STW）、`cleanup()`（Cleanup STW）。

### 0.2 五阶段详解

| 阶段 | STW/并发 | 核心方法 | 作用 |
|------|---------|---------|------|
| Initial Mark | STW（搭便车） | `checkpoint_roots_initial_pre()` | 设置 TAMS，激活 SATB |
| Root Region Scan | 并发 | `scan_root_regions()` | 扫描 Survivor Region |
| Concurrent Mark | 并发 | `mark_from_roots()` | 多线程标记对象图 |
| Remark | STW | `remark()` | 处理 SATB 队列 |
| Cleanup | STW | `cleanup()` | 统计存活字节，交换 Bitmap |

### 0.3 关键设计决策

- **为什么 Root Region Scan 必须在下次 Young GC 之前完成？** Root Region Scan 扫描 Survivor Region（上次 Young GC 的幸存者），这些 Region 在下次 Young GC 时会被回收；如果未完成就触发 Young GC，会丢失标记信息
- **为什么 Remark 通常很短？** 并发标记期间 SATB 队列的积累量有限；Remark 只处理增量，不重新扫描整个堆

---

---

## 第1章: G1ConcurrentMark类结构与核心字段

### 1.1 类定义与双缓冲位图

```cpp
301: class G1ConcurrentMark : public CHeapObj<mtGC> {
302:   friend class G1ConcurrentMarkThread;
303:   friend class G1CMRefProcTaskProxy;
...
312:   G1ConcurrentMarkThread* _cm_thread;     // The thread doing the work
313:   G1CollectedHeap*        _g1h;           // The heap
314:   bool                    _completed_initialization;
315: 
316:   // Concurrent marking support structures
317:   G1CMBitMap              _mark_bitmap_1;
318:   G1CMBitMap              _mark_bitmap_2;
319:   G1CMBitMap*             _prev_mark_bitmap; // Completed mark bitmap
320:   G1CMBitMap*             _next_mark_bitmap; // Under-construction mark bitmap
```

**Line 317-320: 双缓冲位图机制深度解析**

**为什么需要两个位图？**
```
+------------------------------------------------------------------+
|                    双缓冲位图原理                                 |
+------------------------------------------------------------------+
|                                                                   |
|  场景：并发标记与Mixed GC同时进行                                  |
|                                                                   |
|  问题：如果只有一个位图                                            |
|  ┌─────────────────────────────────────────────────────────┐     |
|  │  并发标记线程：正在标记对象A为存活                           │     |
|  │  Mixed GC线程：同时读取对象A的存活状态                       │     |
|  │                                                          │     |
|  │  竞争条件：                                               │     |
|  │  - 标记线程写位图                                         │     |
|  │  - GC线程读位图                                           │     |
|  │  - 可能读到不一致的状态！                                    │     |
|  └─────────────────────────────────────────────────────────┘     |
|                                                                   |
|  解决方案：双缓冲                                                 │
|  ┌─────────────────────────────────────────────────────────┐     |
|  │  prev_mark_bitmap (上一轮结果)                            │     |
|  │  ├─ Mixed GC只读这个位图                                   │     |
|  │  ├─ 稳定的快照，不会被修改                                  │     |
|  │  └─ 用于判断老年代对象是否存活                              │     |
|  │                                                          │     |
|  │  next_mark_bitmap (当前正在构建)                          │     |
|  │  ├─ 并发标记线程写这个位图                                 │     |
|  │  ├─ 标记新发现的对象                                       │     |
|  │  └─ 完成后与prev交换                                       │     |
|  └─────────────────────────────────────────────────────────┘     |
+------------------------------------------------------------------+
```

**位图交换操作（O(1)原子操作）：**
```cpp
void swap_mark_bitmaps() {
    G1CMBitMap* tmp = _prev_mark_bitmap;
    _prev_mark_bitmap = _next_mark_bitmap;
    _next_mark_bitmap = tmp;
}
```

---

### 1.2 根Region与标记栈

```cpp
325:   // Root region tracking and claiming
326:   // 管理Young GC产生的Survivor区域,确保这些区域在并发标记期间优先被扫描
327:   G1CMRootRegions         _root_regions;
328: 
329:   // For grey objects
330:   // 存储灰色对象(已标记但是其还有未处理的引用字段)
331:   G1CMMarkStack           _global_mark_stack; // Grey objects behind global finger
332:   HeapWord* volatile      _finger;            // The global finger, region aligned,
333:                                               // always pointing to the end of the
334:                                               // last claimed region
```

**Line 327: G1CMRootRegions 根Region管理**

**为什么需要根Region？**
```
+------------------------------------------------------------------+
|                    根Region扫描机制                               |
+------------------------------------------------------------------+
|                                                                   |
|  并发标记的GC Roots来源：                                          │
|  1. 线程栈、寄存器（STW时扫描）                                    │
|  2. Survivor区对象（需要特殊处理）                                 │
|                                                                   |
|  Survivor区对象问题：                                              │
|  ┌─────────────────────────────────────────────────────────┐     |
|  │  Young GC后，Survivor区有新对象                            │     |
|  │  这些对象可能引用老年代对象                                  │     |
|  │  这些引用必须作为GC Roots扫描                                │     |
|  │                                                          │     |
|  │  但是：Young GC和并发标记是交错进行的                        │     │
|  │  - Initial Mark时扫描了当时的Survivor                       │     │
|  │  - 之后Young GC又产生了新的Survivor                         │     │
|  │  - 这些新Survivor也要扫描！                                  │     │
|  └─────────────────────────────────────────────────────────┘     |
|                                                                   |
|  解决方案：_root_regions跟踪所有需要扫描的Survivor                 │
|  - 每次Young GC后添加新Survivor到_root_regions                    │
|  - 并发标记阶段优先扫描这些Region                                  │
+------------------------------------------------------------------+
```

**Line 331-334: 全局标记栈与Finger指针**

**三色标记法：**
```
+------------------------------------------------------------------+
|                    三色标记法                                     |
+------------------------------------------------------------------+
|                                                                   |
|  白色：未访问的对象（垃圾回收候选）                                 │
|  灰色：已访问，但引用字段未处理（标记栈中的对象）                    │
|  黑色：已访问，引用字段已处理（存活对象）                           │
|                                                                   |
|  标记过程：                                                        │
|  1. 根对象标记为灰色，加入标记栈                                    │
|  2. 从标记栈弹出灰色对象                                           │
|  3. 扫描其引用字段，将白色对象标记为灰色并入栈                       │
|  4. 当前对象标记为黑色                                             │
|  5. 重复2-4直到标记栈为空                                          │
|                                                                   |
|  Finger指针：                                                      │
|  - 指向已完全扫描的Region边界                                      │
|  - Finger之前的Region所有对象都是黑色                              │
|  - 用于优化扫描，避免重复扫描                                       │
+------------------------------------------------------------------+
```

---

### 1.3 并发工作线程与任务队列

```cpp
336:   uint                    _worker_id_offset;
337:   uint                    _max_num_tasks;    // Maximum number of marking tasks
338:   uint                    _num_active_tasks; // Number of tasks currently active
339:   G1CMTask**              _tasks;            // Task queue array (max_worker_id length)
340: 
341:   G1CMTaskQueueSet*       _task_queues;      // Task queue set
342:   ParallelTaskTerminator  _terminator;       // For termination
```

**Line 339-342: 工作窃取（Work Stealing）机制**

```
+------------------------------------------------------------------+
|                    并发标记工作窃取机制                            |
+------------------------------------------------------------------+
|                                                                   |
|  每个并发标记线程有自己的任务队列：                                  │
|  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐             │
|  │ Task 0  │  │ Task 1  │  │ Task 2  │  │ Task 3  │             │
|  │ [A,B,C] │  │ [D,E]   │  │ [F,G,H] │  │ []      │             │
|  └─────────┘  └─────────┘  └─────────┘  └─────────┘             │
|                                                                   |
|  工作窃取流程：                                                    │
|  1. 线程3的队列为空，开始窃取                                       │
|  2. 随机选择线程2，从尾部窃取H                                      │
|  3. 线程3处理H，发现H引用I和J                                       │
|  4. I和J加入线程3的队列                                             │
|  5. 继续处理...                                                    │
|                                                                   |
|  终止条件（Terminator）：                                          │
|  - 所有队列为空                                                    │
|  - 没有正在处理的对象                                              │
|  - 全局标记栈为空                                                  │
+------------------------------------------------------------------+
```

---

## 第2章: Initial Mark阶段 (Lines 843-872)

### 2.1 pre_initial_mark - 初始化准备

```cpp
843: void G1ConcurrentMark::pre_initial_mark() {
844:   // Initialize marking structures. This has to be done in a STW phase.
845:   reset();
846: 
847:   // For each region note start of marking.
848:   NoteStartOfMarkHRClosure startcl;
849:   _g1h->heap_region_iterate(&startcl);
850: }
```

**Line 843-850: Initial Mark前置准备**

**调用时机：**
```
do_collection_pause_at_safepoint() [Young GC]
  └─ if (in_initial_mark_gc()) {
       concurrent_mark()->pre_initial_mark();  // STW中执行
       ...
       concurrent_mark()->post_initial_mark(); // 启动并发标记
     }
```

**reset()操作：**
```cpp
void reset() {
    // 1. 清空next_mark_bitmap
    clear_bitmap(_next_mark_bitmap);
    
    // 2. 清空全局标记栈
    _global_mark_stack->clear();
    
    // 3. 重置finger指针
    _finger = _heap.start();
    
    // 4. 重置所有任务状态
    for (uint i = 0; i < _max_num_tasks; i++) {
        _tasks[i]->reset();
    }
}
```

**NoteStartOfMarkHRClosure：**
```cpp
// 遍历所有Region，标记为"标记周期开始"
bool do_heap_region(HeapRegion* r) {
    r->note_start_of_marking();
    return false;
}

// 设置Region的_top_at_mark_start
// 这是并发标记的"快照"，标记期间新分配的对象（top之上）忽略
```

---

### 2.2 post_initial_mark - 启动并发标记

```cpp
853: void G1ConcurrentMark::post_initial_mark() {
854:   // Start Concurrent Marking weak-reference discovery.
855:   ReferenceProcessor* rp = _g1h->ref_processor_cm();
856:   // enable ("weak") refs discovery
857:   rp->enable_discovery();
858:   rp->setup_policy(false); // snapshot the soft ref policy to be used in this cycle
859: 
860:   SATBMarkQueueSet& satb_mq_set = G1BarrierSet::satb_mark_queue_set();
861:   // This is the start of the marking cycle, we're expected all
862:   // threads to have SATB queues with active set to false.
863:   satb_mq_set.set_active_all_threads(true, /* new active value */
864:                                      false /* expected_active */);
865: 
866:   _root_regions.prepare_for_scan();
867: }
```

**Line 853-867: Initial Mark后置处理**

**关键操作解析：**

| 行号 | 操作 | 作用 |
|------|------|------|
| 857 | `rp->enable_discovery()` | 启用引用发现，开始追踪Weak/Soft/Phantom引用 |
| 858 | `rp->setup_policy(false)` | 设置引用处理策略（是否清除Soft引用） |
| 863-864 | `set_active_all_threads(true, false)` | 启用SATB写屏障 |
| 866 | `_root_regions.prepare_for_scan()` | 准备扫描根Region |

**SATB（Snapshot-At-The-Beginning）机制：**
```
+------------------------------------------------------------------+
|                    SATB 写屏障机制                                |
+------------------------------------------------------------------+
|                                                                   |
|  问题：并发标记期间，应用线程修改对象引用                            │
|        可能导致"漏标"（对象被标记为垃圾但实际存活）                  │
|                                                                   |
|  示例：                                                           │
|  初始：A -> B -> C                                                │
|  并发标记：标记了A和B，还没标记C                                    │
|  应用修改：A -> C（B不再引用C）                                    │
|  结果：C没有被标记，但实际可达！                                    │
|                                                                   |
|  SATB解决方案：                                                   │
|  1. 在Initial Mark时建立"快照"                                    │
|  2. 写前屏障记录被覆盖的引用                                        │
|  ┌─────────────────────────────────────────────────────────┐     |
|  │  写前屏障代码（伪代码）：                                   │     |
|  │  void pre_write_barrier(Object* obj, Object* new_val) {   │     |
|  │      Object* old_val = obj->field;                        │     |
|  │      if (marking_active && old_val != NULL) {             │     |
|  │          satb_queue.enqueue(old_val);  // 记录旧值        │     │
|  │      }                                                    │     |
|  │      obj->field = new_val;                                │     │
|  │  }                                                        │     │
|  └─────────────────────────────────────────────────────────┘     |
|                                                                   |
|  3. Remark阶段处理SATB队列，标记队列中的对象                        │
|  4. 保证：快照中存活的对象最终都会被标记                              │
+------------------------------------------------------------------+
```

**面试高频问题Q&A：**

**Q1: SATB和CMS的增量更新（Incremental Update）有什么区别？**
```
A: 两种并发标记的解决方案：

SATB (G1使用)：
- 记录被修改的引用（旧值）
- 保证"快照开始时存活的对象最终都被标记"
- 写前屏障，记录旧引用到队列
- Remark阶段处理队列
- 优点：简单，不需要重新扫描
- 缺点：可能保留一些实际上已死亡的对象（浮动垃圾）

增量更新 (CMS使用)：
- 记录新建立的引用
- 保证"新引用指向的对象被标记"
- 写后屏障，记录新引用
- 需要重新扫描被修改的对象
- 优点：更精确，浮动垃圾少
- 缺点：复杂，可能需要多次重新扫描

对比：
+---------------+----------------+----------------+
|     特性      |      SATB      |  增量更新(CMS) |
+---------------+----------------+----------------+
| 记录时机      | 写前屏障        | 写后屏障       |
| 记录内容      | 旧引用          | 新引用         |
| 处理时机      | Remark阶段      | 并发阶段       |
| 浮动垃圾      | 较多            | 较少           |
| 实现复杂度    | 简单            | 复杂           |
+---------------+----------------+----------------+
```

---

## 第3章: 并发标记阶段 (Lines 1065-1084)

### 3.1 mark_from_roots - 并发标记入口

```cpp
1065: void G1ConcurrentMark::mark_from_roots() {
1066:   _restart_for_overflow = false;
1067: 
1068:   _num_concurrent_workers = calc_active_marking_workers();
1069:   uint active_workers = MAX2(1U, _num_concurrent_workers);
1070: 
1075:   active_workers = _concurrent_workers->update_active_workers(active_workers);
1076:   log_info(gc, task)("Using %u workers of %u for marking", active_workers, _concurrent_workers->total_workers());
1077: 
1079:   set_concurrency_and_phase(active_workers, true /* concurrent */);
1080: 
1081:   G1CMConcurrentMarkingTask marking_task(this);
1082:   _concurrent_workers->run_task(&marking_task);
1083:   print_stats();
1084: }
```

**Line 1065-1084: 并发标记执行流程**

**调用链：**
```
G1ConcurrentMarkThread::run()
  └─ sleep() 等待Initial Mark
  └─ mark_from_roots()  // 开始并发标记
       └─ G1CMConcurrentMarkingTask
            └─ G1CMTask::do_marking_step()
                 └─ 处理标记栈，扫描对象引用
```

**并发工作线程数计算：**
```cpp
uint calc_active_marking_workers() {
    // 默认使用所有并发标记线程
    uint workers = _concurrent_workers->total_workers();
    
    // 可根据堆大小调整
    // 小堆：减少线程数，避免过度竞争
    // 大堆：增加线程数，提高并行度
    
    return workers;
}
```

### 3.2 G1CMTask::do_marking_step - 标记步进

```cpp
void G1CMTask::do_marking_step(double time_target_ms) {
    // 1. 处理本地标记栈
    while (!local_mark_stack->is_empty() && time_not_expired()) {
        oop obj = local_mark_stack->pop();
        scan_object(obj);  // 扫描对象引用
    }
    
    // 2. 本地栈空，尝试窃取其他线程的任务
    if (local_mark_stack->is_empty()) {
        steal_tasks_from_other_workers();
    }
    
    // 3. 处理全局标记栈
    if (local_mark_stack->is_empty()) {
        process_global_mark_stack();
    }
    
    // 4. 处理SATB队列
    process_satb_buffers();
}

void scan_object(oop obj) {
    // 遍历对象的所有引用字段
    obj->oop_iterate([&](oop* field) {
        oop ref = *field;
        if (ref != NULL && !is_marked(ref)) {
            mark_object(ref);           // 标记为灰色
            local_mark_stack->push(ref); // 加入标记栈
        }
    });
    
    // 对象标记为黑色（已完成）
}
```

**并发标记时间片控制：**
```
G1使用时间片控制避免长时间占用CPU：

默认参数：
-XX:G1ConcMarkStepDurationMillis = 10ms

每个标记步进最多执行10ms，然后：
1. 保存当前状态
2. 让出CPU
3. 下次继续从保存点执行

这样可以与应用线程更好地共享CPU
```

---

## 第4章: Remark阶段 (Lines 1231-1327)

### 4.1 remark - 最终标记

```cpp
1231: void G1ConcurrentMark::remark() {
1232:   assert_at_safepoint_on_vm_thread();
1233: 
1236:   if (has_aborted()) {
1237:     return;
1238:   }
1241:   g1p->record_concurrent_mark_remark_start();
1244:   double start = os::elapsedTime();
1245:   verify_during_pause(G1HeapVerifier::G1VerifyRemark, VerifyOption_G1UsePrevMarking, "Remark before");
1248:   GCTraceTime(Debug, gc, phases) debug("Finalize Marking", _gc_timer_cm);
1249:   finalize_marking();
```

**Line 1231-1249: Remark阶段入口**

**Remark阶段目标：**
```
+------------------------------------------------------------------+
|                    Remark阶段目标                                 |
+------------------------------------------------------------------+
|                                                                   |
|  1. 完成并发标记未完成的标记工作                                    │
|     - 处理剩余的标记栈                                             │
|     - 处理所有SATB队列                                             │
|                                                                   |
|  2. 处理引用（Soft/Weak/Phantom）                                  │
|     - 决定哪些引用对象需要清除                                     │
|                                                                   |
|  3. 清理工作                                                       │
|     - 交换prev/next位图                                            │
|     - 清理空Region                                                 │
|     - 类卸载                                                       │
|                                                                   |
|  特点：STW暂停，但通常很短（<10ms）                                 │
+------------------------------------------------------------------+
```

**Line 1249: finalize_marking()**

```cpp
void finalize_marking() {
    // 1. 所有工作线程并行处理剩余标记栈
    G1CMRemarkTask remark_task(this);
    _g1h->workers()->run_task(&remark_task);
    
    // 2. 处理SATB队列
    drain_satb_buffers();
    
    // 3. 确保所有标记完成
    // 如果标记栈溢出，需要重新标记
}
```

### 4.2 引用处理与位图交换

```cpp
1254:   bool const mark_finished = !has_overflown();
1255:   if (mark_finished) {
1256:     weak_refs_work(false /* clear_all_soft_refs */);
1257: 
1258:     SATBMarkQueueSet& satb_mq_set = G1BarrierSet::satb_mark_queue_set();
1262:     satb_mq_set.set_active_all_threads(false, /* new active value */
1263:                                        true /* expected_active */);
1267:     flush_all_task_caches();
1271:     swap_mark_bitmaps();
```

**Line 1256: weak_refs_work() - 引用处理**

**引用类型处理：**
```
+------------------------------------------------------------------+
|                    引用类型处理策略                               |
+------------------------------------------------------------------+
|                                                                   |
|  Soft Reference（软引用）：                                        │
|  - 内存不足时清除                                                  │
|  - 由-XX:SoftRefLRUPolicyMSPerMB控制                              │
|                                                                   |
|  Weak Reference（弱引用）：                                        │
|  - 对象不可达时立即清除                                            │
|  - 用于缓存、监听器等                                              │
|                                                                   |
|  Phantom Reference（虚引用）：                                     │
|  - 对象被回收后通知                                                │
|  - 用于资源清理（DirectBuffer）                                    │
|                                                                   |
|  Final Reference（终结引用）：                                     │
|  - 对象finalize()方法调用                                          │
|  - 单独处理，可能耗时较长                                          │
+------------------------------------------------------------------+
```

**Line 1271: swap_mark_bitmaps() - 位图交换**

```cpp
void swap_mark_bitmaps() {
    // 原子交换prev和next位图指针
    G1CMBitMap* temp = _prev_mark_bitmap;
    _prev_mark_bitmap = _next_mark_bitmap;
    _next_mark_bitmap = temp;
    
    // 现在：
    // - prev_mark_bitmap 指向本轮标记结果
    // - next_mark_bitmap 指向旧位图（将在下次标记前清空）
}
```

### 4.3 空Region回收与清理

```cpp
1287:   GCTraceTime(Debug, gc, phases) debug("Reclaim Empty Regions", _gc_timer_cm);
1288:   reclaim_empty_regions();
1291:   if (ClassUnloadingWithConcurrentMark) {
1292:     GCTraceTime(Debug, gc, phases) debug("Purge Metaspace", _gc_timer_cm);
1293:     ClassLoaderDataGraph::purge();
1294:   }
1297:   compute_new_sizes();
```

**Line 1288: reclaim_empty_regions()**

```cpp
void reclaim_empty_regions() {
    // 遍历所有Region
    heap_region_iterate([&](HeapRegion* r) {
        // 如果Region有对象但标记为0存活，说明全是垃圾
        if (r->used() > 0 && r->max_live_bytes() == 0 && !r->is_young()) {
            // 回收这个Region
            free_region(r);
        }
    });
}
```

**Line 1293: ClassLoaderDataGraph::purge() - 类卸载**

```
条件：-XX:+ClassUnloadingWithConcurrentMark（默认启用）

卸载条件：
1. 类的所有对象都已死亡
2. 类的ClassLoader已死亡
3. 没有JNI引用

卸载操作：
- 清理Metaspace
- 释放Klass结构
- 清理Code Cache中的nmethod
```

---

## 第5章: Cleanup阶段 (Lines 1448-1476)

### 5.1 cleanup - 清理阶段

```cpp
1448: void G1ConcurrentMark::cleanup() {
1449:   assert_at_safepoint_on_vm_thread();
1452:   if (has_aborted()) {
1453:     return;
1454:   }
1457:   g1p->record_concurrent_mark_cleanup_start();
1460:   double start = os::elapsedTime();
1461:   verify_during_pause(G1HeapVerifier::G1VerifyCleanup, VerifyOption_G1UsePrevMarking, "Cleanup before");
1464:   GCTraceTime(Debug, gc, phases) debug("Update Remembered Set Tracking After Rebuild", _gc_timer_cm);
1465:   G1UpdateRemSetTrackingAfterRebuild cl(_g1h);
1466:   _g1h->heap_region_iterate(&cl);
1474:   verify_during_pause(G1HeapVerifier::G1VerifyCleanup, VerifyOption_G1UsePrevMarking, "Cleanup after");
1476:   _g1h->increment_total_collections();
```

**Line 1448-1476: Cleanup阶段**

**Cleanup阶段职责：**
```
+------------------------------------------------------------------+
|                    Cleanup阶段职责                                |
+------------------------------------------------------------------+
|                                                                   |
|  1. 更新RSet跟踪策略                                               │
|     - 根据标记结果调整RSet更新策略                                 │
|                                                                   |
|  2. 准备Mixed GC                                                   │
|     - 将标记的Region加入CSet Chooser                               │
|     - 按回收效率排序                                               │
|                                                                   |
|  3. 清理结束                                                       │
|     - 重置并发标记状态                                             │
|     - 准备下一个标记周期                                           │
|                                                                   |
|  特点：STW暂停，通常很短（<1ms）                                    │
+------------------------------------------------------------------+
```

---

## 并发标记完整流程总结

```
+==================================================================+
|              G1 Concurrent Mark 完整流程                          |
+==================================================================+
|                                                                   |
|  1. Initial Mark (STW)                                            |
|     ├─ pre_initial_mark()                                         |
|     │   ├─ 清空next_mark_bitmap                                   |
|     │   └─ 遍历Region设置标记起始                                  |
|     ├─ Young GC执行                                               |
|     └─ post_initial_mark()                                        |
|         ├─ 启用引用发现                                            |
|         ├─ 启用SATB写屏障                                          |
|         └─ 准备根Region扫描                                        |
|                                                                   |
|  2. Root Region Scanning (并发)                                    |
|     └─ 扫描Survivor区作为GC Roots                                  |
|                                                                   |
|  3. Concurrent Mark (并发)                                         |
|     ├─ mark_from_roots()                                          |
|     │   └─ 多线程并发遍历对象图                                     |
|     ├─ 三色标记（白->灰->黑）                                      |
|     ├─ SATB写屏障记录引用修改                                      |
|     └─ 工作窃取平衡负载                                            |
|                                                                   |
|  4. Remark (STW)                                                   |
|     ├─ finalize_marking()                                         │
|     │   └─ 完成剩余标记工作                                        │
|     ├─ 处理SATB队列                                                │
|     ├─ weak_refs_work() - 处理引用                                 │
|     ├─ swap_mark_bitmaps() - 交换位图                              |
|     ├─ reclaim_empty_regions() - 回收空Region                      │
|     └─ ClassLoaderDataGraph::purge() - 类卸载                     │
|                                                                   |
|  5. Cleanup (STW)                                                  |
|     ├─ 更新RSet跟踪策略                                            │
|     ├─ 准备Mixed GC（Region排序）                                  │
|     └─ 重置标记状态                                                │
|                                                                   |
|  6. Mixed GC (多次STW)                                             │
|     └─ 回收标记的老年代Region                                      │
|                                                                   |
+==================================================================+
```

---

**GDB调试脚本：**

```bash
# verify_concurrent_mark.gdb
set pagination off

break G1ConcurrentMark::pre_initial_mark
break G1ConcurrentMark::post_initial_mark
break G1ConcurrentMark::mark_from_roots
break G1ConcurrentMark::remark
break G1ConcurrentMark::cleanup

run -Xms8g -Xmx8g -XX:+UseG1GC -XX:+PrintGCDetails

# 查看位图
p _prev_mark_bitmap
p _next_mark_bitmap

# 查看标记栈
p _global_mark_stack

# 查看SATB队列状态
p G1BarrierSet::satb_mark_queue_set()

continue
quit
```

---

**文档完成**

本文档完成了G1 Concurrent Mark的逐行深度分析，涵盖：
- G1ConcurrentMark类结构与双缓冲位图
- Initial Mark阶段（pre/post）
- 并发标记阶段（mark_from_roots、工作窃取）
- Remark阶段（finalize、引用处理、位图交换）
- Cleanup阶段（RSet更新、Mixed GC准备）
- SATB写屏障机制
- 三色标记法

下一章将分析：**Mixed GC** - 空间回收阶段的详细执行流程
