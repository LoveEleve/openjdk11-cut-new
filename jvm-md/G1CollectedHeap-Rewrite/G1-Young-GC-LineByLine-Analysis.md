# G1 Young GC 逐行深度源码分析

> **分析目标**: G1 Young GC完整执行流程  
> **源码文件**: 
> - `src/hotspot/share/gc/g1/vm_operations_g1.cpp`
> - `src/hotspot/share/gc/g1/g1CollectedHeap.cpp`  
> **分析标准**: 面试级深度 - 逐行解释 + 面试问答 + GDB调试技巧

---

## 第1章: Young GC触发与VM操作 (Lines 2729-2758)

### 1.1 G1CollectedHeap::collect() - GC入口

```cpp
2729: void G1CollectedHeap::collect(GCCause::Cause cause) {
2730:     assert_heap_not_locked();
2731: 
2732:     uint gc_count_before;
2733:     uint old_marking_count_before;
2734:     uint full_gc_count_before;
2735:     bool retry_gc;
2736: 
2737:     do {
2738:         retry_gc = false;
2739: 
2740:         {
2741:             MutexLocker ml(Heap_lock);
2742: 
2743:             // Read the GC count while holding the Heap_lock
2744:             gc_count_before = total_collections();
2745:             full_gc_count_before = total_full_collections();
2746:             old_marking_count_before = _old_marking_cycles_started;
2747:         }
2748: 
2749:         if (should_do_concurrent_full_gc(cause)) {
2750:             // Schedule an initial-mark evacuation pause that will start a
2751:             // concurrent cycle. We're setting word_size to 0 which means that
2752:             // we are not requesting a post-GC allocation.
2753:             VM_G1CollectForAllocation op(0,     /* word_size */
2754:                                          gc_count_before,
2755:                                          cause,
2756:                                          true,  /* should_initiate_conc_mark */
2757:                                          g1_policy()->max_pause_time_ms());
2758:             VMThread::execute(&op);
```

**Line 2729: collect()方法入口深度解析**

**调用链追踪：**
```
Java代码触发GC:
System.gc()
  └→ JVM_ENTRY_NO_ENV(void, JVM_GC(void))     [src/hotspot/share/prims/jvm.cpp:...]
       └→ Universe::heap()->collect(...)
            └→ G1CollectedHeap::collect(cause)  ← 我们在这里

或者分配失败触发:
TLAB分配失败 / 大对象分配失败
  └→ G1CollectedHeap::allocate_from_tlab_slow(...)
       └→ G1CollectedHeap::attempt_allocation_slow(...)
            └→ G1CollectedHeap::collect(cause)  ← 我们在这里
```

**Line 2730: assert_heap_not_locked()**

```cpp
assert_heap_not_locked();
```

**作用：**
- 确保调用时未持有Heap_lock
- 防止死锁：GC过程中会获取Heap_lock，如果调用前已持有会导致死锁

**Line 2732-2746: GC计数器快照**

```cpp
uint gc_count_before = total_collections();
uint full_gc_count_before = total_full_collections();
uint old_marking_count_before = _old_marking_cycles_started;
```

**为什么需要快照？**
```
+------------------------------------------------------------------+
|                    GC计数器快照的作用                             |
+------------------------------------------------------------------+
|                                                                   |
|  场景：多线程同时请求GC                                            |
|                                                                   |
|  Thread A                                          Thread B       |
|  ---------                                         ---------      |
|  读取gc_count = 10                                 读取gc_count = 10|
|  创建VM_G1CollectForAllocation                     创建VM_G1CollectForAllocation|
|  gc_count_before = 10                              gc_count_before = 10|
|  提交到VMThread                                    提交到VMThread  |
|                                                                   |
|  VMThread执行顺序：                                                |
|  1. 执行Thread A的GC → gc_count变为11                             |
|  2. 检查Thread B的gc_count_before (10) < 当前gc_count (11)         |
|  3. 发现已经发生过GC，跳过Thread B的请求                            |
|                                                                   |
|  结论：防止重复GC，确保每个请求只执行一次                           |
+------------------------------------------------------------------+
```

**Line 2749-2758: 并发Full GC判断**

```cpp
if (should_do_concurrent_full_gc(cause)) {
    VM_G1CollectForAllocation op(0, gc_count_before, cause, 
                                 true,  // should_initiate_conc_mark
                                 g1_policy()->max_pause_time_ms());
    VMThread::execute(&op);
```

**should_do_concurrent_full_gc条件：**
```cpp
bool G1CollectedHeap::should_do_concurrent_full_gc(GCCause::Cause cause) {
    switch (cause) {
        case GCCause::_gc_locker:           // GCLocker触发
            return GCLockerInvokesConcurrent;
        case GCCause::_java_lang_system_gc: // System.gc()
            return ExplicitGCInvokesConcurrent;
        case GCCause::_g1_humongous_allocation: // 大对象分配
            return true;
        case GCCause::_wb_conc_mark:        // WhiteBox测试
            return true;
        default:
            return false;
    }
}
```

**面试高频问题Q&A：**

**Q1: 为什么GC要提交给VMThread执行，而不是直接执行？**
```
A: Safepoint机制要求：

1. GC需要STW（Stop-The-World），所有Java线程必须停在安全点
2. 只有VMThread可以协调进入Safepoint
3. GC操作封装为VM_Operation，由VMThread调度执行

执行流程：
┌─────────────────────────────────────────────────────────────┐
│  Java Thread        VM Thread         GC Thread             │
│  -----------        ---------         ---------             │
│       │                  │                  │               │
│       │  1.提交VM_Operation              │               │
│       │────────────────>│                  │               │
│       │                  │                  │               │
│       │  2.触发Safepoint                │               │
│       │<────────────────│                  │               │
│       │                  │                  │               │
│       │  3.在安全点等待                  │               │
│       │<─Safepoint──────│>                 │               │
│       │                  │                  │               │
│       │                  │  4.执行GC        │               │
│       │                  │─────────────────>│               │
│       │                  │                  │               │
│       │                  │  5.GC完成        │               │
│       │                  │<─────────────────│               │
│       │                  │                  │               │
│       │  6.恢复执行      │                  │               │
│       │<─Resume─────────│                  │               │
└─────────────────────────────────────────────────────────────┘
```

---

## 第2章: VM_G1CollectForAllocation::doit() (Lines 75-132)

### 2.1 VM操作执行入口

```cpp
75: void VM_G1CollectForAllocation::doit() {
76:   G1CollectedHeap* g1h = G1CollectedHeap::heap();
77:   assert(!_should_initiate_conc_mark || g1h->should_do_concurrent_full_gc(_gc_cause),
78:       "only a GC locker, a System.gc(), stats update, whitebox, or a hum allocation induced GC should start a cycle");
79: 
80:   if (_word_size > 0) {
81:     // An allocation has been requested. So, try to do that first.
82:     _result = g1h->attempt_allocation_at_safepoint(_word_size,
83:                                                    false /* expect_null_cur_alloc_region */);
84:     if (_result != NULL) {
85:       // If we can successfully allocate before we actually do the
86:       // pause then we will consider this pause successful.
87:       _pause_succeeded = true;
88:       return;
89:     }
90:   }
```

**Line 75-78: VM操作入口与断言**

**VM_Operation执行上下文：**
```
当VMThread执行到此函数时：
1. 所有Java线程已在Safepoint停止
2. 当前线程是VMThread
3. Heap_lock已被持有
```

**Line 80-89: 快速分配尝试**

```cpp
if (_word_size > 0) {
    _result = g1h->attempt_allocation_at_safepoint(_word_size, false);
    if (_result != NULL) {
        _pause_succeeded = true;
        return;
    }
}
```

**为什么先尝试分配？**
```
场景：GC请求提交后，其他GC可能已经释放了足够空间

Thread A请求分配1MB → 提交GC
Thread B请求分配1MB → 提交GC

VMThread执行：
1. 执行Thread A的GC，释放5MB空间
2. 执行Thread B的GC前，发现已有足够空间
3. Thread B直接分配，无需GC

优化效果：避免不必要的GC，减少暂停时间
```

**attempt_allocation_at_safepoint逻辑：**
```cpp
HeapWord* G1CollectedHeap::attempt_allocation_at_safepoint(size_t word_size, bool expect_null_mutator_alloc_region) {
    // 在Safepoint中，可以安全地检查空闲列表
    if (_allocator->mutator_alloc_region()->is_active()) {
        // 尝试在当前分配Region分配
        return _allocator->mutator_alloc_region()->attempt_allocation(word_size, ...);
    }
    
    // 尝试从空闲列表获取新Region
    HeapRegion* new_alloc_region = new_mutator_alloc_region(word_size, ...);
    if (new_alloc_region != NULL) {
        return _allocator->mutator_alloc_region()->attempt_allocation(word_size, ...);
    }
    
    return NULL;  // 分配失败，需要GC
}
```

---

### 2.2 并发标记触发判断

```cpp
92:   GCCauseSetter x(g1h, _gc_cause);
93:   if (_should_initiate_conc_mark) {
94:     // It's safer to read old_marking_cycles_completed() here, given
95:     // that noone else will be updating it concurrently. Since we'll
96:     // only need it if we're initiating a marking cycle, no point in
97:     // setting it earlier.
98:     _old_marking_cycles_completed_before = g1h->old_marking_cycles_completed();
99: 
100:    // At this point we are supposed to start a concurrent cycle. We
101:    // will do so if one is not already in progress.
102:    bool res = g1h->g1_policy()->force_initial_mark_if_outside_cycle(_gc_cause);
103: 
104:    // The above routine returns true if we were able to force the
105:    // next GC pause to be an initial mark; it returns false if a
105:    // marking cycle is already in progress.
```

**Line 92: GCCauseSetter作用**

```cpp
GCCauseSetter x(g1h, _gc_cause);
```

**RAII模式设置GC原因：**
```cpp
class GCCauseSetter : public StackObj {
    CollectedHeap* _heap;
    GCCause::Cause _previous_cause;
public:
    GCCauseSetter(CollectedHeap* heap, GCCause::Cause cause) 
        : _heap(heap), _previous_cause(heap->gc_cause()) {
        heap->set_gc_cause(cause);
    }
    ~GCCauseSetter() {
        _heap->set_gc_cause(_previous_cause);  // 析构时恢复
    }
};
```

**Line 93-128: 初始标记触发逻辑**

**并发标记触发条件：**
```
+------------------------------------------------------------------+
|                    并发标记触发条件                               |
+------------------------------------------------------------------+
|                                                                   |
|  _should_initiate_conc_mark = true 的情况：                        │
|  1. System.gc() + ExplicitGCInvokesConcurrent=true                 │
|  2. GCLocker触发 + GCLockerInvokesConcurrent=true                  │
|  3. 大对象分配失败 (_g1_humongous_allocation)                       │
|  4. WhiteBox测试 (_wb_conc_mark)                                   │
|                                                                   |
|  force_initial_mark_if_outside_cycle逻辑：                         │
|  ┌─────────────────────────────────────────────────────────┐     │
|  │  if (并发标记已在进行中) {                                │     │
|  │      return false;  // 不重复触发                        │     │
|  │  }                                                       │     │
|  │  设置下一个GC为Initial Mark类型                          │     │
|  │  return true;                                            │     │
|  └─────────────────────────────────────────────────────────┘     │
+------------------------------------------------------------------+
```

**G1 GC阶段转换：**
```
+------------------------------------------------------------------+
|                    G1 GC阶段转换图                                |
+------------------------------------------------------------------+
|                                                                   |
|  Young-Only Phase ──> Concurrent Mark ──> Space Reclamation       │
|       │                      │                    │               │
|       │                      │                    │               │
|       ▼                      ▼                    ▼               │
|  [Young GC]           [Initial Mark]        [Mixed GC]            │
|  [Young GC]           [Concurrent Mark]     [Mixed GC]            │
|  [Young GC]           [Remark]              [Mixed GC]            │
|       │               [Cleanup]                   │               │
|       │                      │                    │               │
|       └──────────────────────┴────────────────────┘               │
|                          (循环)                                   │
+------------------------------------------------------------------+
```

---

### 2.3 执行GC暂停

```cpp
131:   // Try a partial collection of some kind.
132:   _pause_succeeded = g1h->do_collection_pause_at_safepoint(_target_pause_time_ms);
```

**Line 132: 核心GC执行调用**

这是Young GC的核心入口！`_target_pause_time_ms`来自`-XX:MaxGCPauseMillis`（默认200ms）。

**完整调用链：**
```
VM_G1CollectForAllocation::doit()
  └→ G1CollectedHeap::do_collection_pause_at_safepoint(target_pause_time_ms)
       └→ 执行Young GC / Initial Mark / Mixed GC
```

**面试高频问题Q&A：**

**Q2: 为什么GC原因（GCCause）需要保存和恢复？**
```
A: 嵌套GC场景：

场景：System.gc()触发GC，GC过程中又触发其他GC

Thread 1: System.gc()
  └→ GCCause = _java_lang_system_gc
       └→ GC执行中...
            └→ 分配失败！
                 └→ 再次GC
                      └→ GCCause需要是_allocation_failure
                           └→ GC完成，恢复为_java_lang_system_gc

如果不恢复，后续GC日志会显示错误的GC原因
```

**Q3: 什么是Initial Mark？为什么要"搭便车"在Young GC上？**
```
A: Initial Mark是并发标记的起点：

单独Initial Mark的问题：
- 需要单独STW暂停
- 只标记GC Roots，耗时很短（<10ms）
- 为这10ms暂停整个应用不划算

搭便车优化：
- Young GC本来就要STW
- 在Young GC开始时顺便做Initial Mark
- 零额外暂停时间！

日志示例：
[GC pause (G1 Evacuation Pause) (young) (initial-mark), 0.015s]
                                    ^^^^^^^^^^^^^ 搭便车标记
```

---

## 第3章: do_collection_pause_at_safepoint核心 (Lines 3542-3691)

### 3.1 入口验证与计时开始

```cpp
3542: G1CollectedHeap::do_collection_pause_at_safepoint(double target_pause_time_ms) {
3543:     assert_at_safepoint_on_vm_thread();
3544:     guarantee(!is_gc_active(), "collection is not reentrant");
3545: 
3546:     if (GCLocker::check_active_before_gc()) {
3547:         return false;
3548:     }
3549: 
3550:     _gc_timer_stw->register_gc_start();
3551: 
3552:     GCIdMark gc_id_mark;
3553:     _gc_tracer_stw->report_gc_start(gc_cause(), _gc_timer_stw->gc_start());
```

**Line 3543: assert_at_safepoint_on_vm_thread()**

```cpp
assert_at_safepoint_on_vm_thread();
```

**双重断言：**
```cpp
#define assert_at_safepoint_on_vm_thread()                    \
    assert_at_safepoint();     /* 当前在Safepoint */          \
    assert(Thread::current()->is_VM_thread(), "必须是VMThread") 
```

**Line 3546-3548: GCLocker检查**

```cpp
if (GCLocker::check_active_before_gc()) {
    return false;
}
```

**GCLocker机制：**
```
+------------------------------------------------------------------+
|                    GCLocker 机制                                  |
+------------------------------------------------------------------+
|                                                                   |
|  问题：JNI代码可能直接操作Java对象引用                              │
|        如果GC移动了对象，JNI持有的指针就失效了！                     │
|                                                                   |
|  解决方案：GCLocker                                                │
|  ┌─────────────────────────────────────────────────────────┐     │
|  │  JNI临界区进入: GCLocker::lock()                         │     │
|  │  - 增加_active计数                                       │     │
|  │  - 阻止GC启动                                            │     │
|  │                                                          │     │
|  │  JNI临界区退出: GCLocker::unlock()                       │     │
|  │  - 减少_active计数                                       │     │
|  │  - 如果计数为0且有GC请求，触发GC                          │     │
|  └─────────────────────────────────────────────────────────┘     │
|                                                                   |
|  check_active_before_gc():                                         │
|  - 如果GCLocker激活，延迟GC                                        │
|  - 返回true表示GC被延迟                                            │
+------------------------------------------------------------------+
```

**Line 3550-3553: GC计时与追踪开始**

```cpp
_gc_timer_stw->register_gc_start();
GCIdMark gc_id_mark;
_gc_tracer_stw->report_gc_start(gc_cause(), _gc_timer_stw->gc_start());
```

**GC计时架构：**
```
+------------------------------------------------------------------+
|                    GC计时与追踪架构                               |
+------------------------------------------------------------------+
|                                                                   |
|  GCTimer (STW)                                                    │
|  ├─ register_gc_start()      // 记录GC开始时间戳                   │
|  ├─ register_gc_end()        // 记录GC结束时间戳                   │
|  └─ 计算各阶段耗时                                                │
|                                                                   |
|  GCTracer (JFR/日志)                                              │
|  ├─ report_gc_start()        // 发送GC开始事件                     │
|  ├─ report_gc_end()          // 发送GC结束事件                     │
|  └─ 记录详细统计信息                                              │
|                                                                   |
|  GCIdMark                                                         │
|  └─ 为当前GC分配唯一ID，用于日志关联                               │
+------------------------------------------------------------------+
```

---

### 3.2 GC类型决策与准备

```cpp
3558:     g1_policy()->note_gc_start();
3559: 
3560:     wait_for_root_region_scanning();
3561: 
3562:     print_heap_before_gc();
3563:     print_heap_regions();
3564:     trace_heap_before_gc(_gc_tracer_stw);
3565: 
3566:     _verifier->verify_region_sets_optional();
3567:     _verifier->verify_dirty_young_regions();
3568: 
3569:     // We should not be doing initial mark unless the conc mark thread is running
3570:     if (!_cm_thread->should_terminate()) {
3571:         // This call will decide whether this pause is an initial-mark
3572:         // pause. If it is, in_initial_mark_gc() will return true
3573:         // for the duration of this pause.
3574:         g1_policy()->decide_on_conc_mark_initiation();
3575:     }
```

**Line 3560: wait_for_root_region_scanning()**

```cpp
wait_for_root_region_scanning();
```

**根Region扫描等待：**
```
+------------------------------------------------------------------+
|                    根Region扫描 (Root Region Scanning)            |
+------------------------------------------------------------------+
|                                                                   |
|  背景：Initial Mark阶段需要扫描Survivor区作为GC Roots             │
|                                                                   |
|  并发标记流程：                                                    │
|  1. Initial Mark (STW)                                            │
|     └─ 标记GC Roots（包括Survivor区对象）                          │
|                                                                   │
|  2. Root Region Scanning (并发)                                   │
|     └─ 并发扫描Survivor区的引用                                     │
|                                                                   │
|  3. Concurrent Mark (并发)                                        │
|     └─ 遍历整个对象图                                               │
|                                                                   │
|  wait_for_root_region_scanning()：                                 │
|  - 如果上一轮并发标记的根Region扫描未完成                           │
|  - 等待扫描完成，确保一致性                                         │
+------------------------------------------------------------------+
```

**Line 3574: decide_on_conc_mark_initiation()**

```cpp
g1_policy()->decide_on_conc_mark_initiation();
```

**IHOP触发判断：**
```cpp
void G1Policy::decide_on_conc_mark_initiation() {
    // 如果老年代占用超过IHOP阈值，触发并发标记
    if (is_conc_mark_needed()) {
        collector_state()->set_initiate_conc_mark_if_possible(true);
    }
    
    // 如果请求了Initial Mark且不在并发周期中
    if (collector_state()->initiate_conc_mark_if_possible() &&
        !collector_state()->in_concurrent_mark_cycle()) {
        set_initial_mark_gc();
    }
}
```

**IHOP (Initiating Heap Occupancy Percent)：**
```
默认45%，即老年代占用超过45%时触发并发标记

计算公式：
IHOP = _old_gen_size / _heap_size > 0.45

自适应IHOP（JDK 9+）：
-XX:+G1UseAdaptiveIHOP
根据历史GC数据动态调整阈值
```

---

### 3.3 GC类型确定与日志输出

```cpp
3587:     // Record whether this pause is an initial mark. When the current
3588:     // thread has completed its logging output and it's safe to signal
3589:     // the CM thread, the flag's value in the policy has been reset.
3590:     bool should_start_conc_mark = collector_state()->in_initial_mark_gc();
3591: 
3592:     // Inner scope for scope based logging, timers, and stats collection
3593:     {
3594:         EvacuationInfo evacuation_info;
3595: 
3596:         if (collector_state()->in_initial_mark_gc()) {
3597:             // We are about to start a marking cycle, so we increment the
3598:             // full collection counter.
3599:             increment_old_marking_cycles_started();
3600:             _cm->gc_tracer_cm()->set_gc_cause(gc_cause());
3601:         }
3602: 
3603:         _gc_tracer_stw->report_yc_type(collector_state()->yc_type());
3604: 
3605:         GCTraceCPUTime tcpu;
3606: 
3607:         FormatBuffer<> gc_string("Pause Young ");
3608:         if (collector_state()->in_initial_mark_gc()) {
3609:             gc_string.append("(Concurrent Start)");
3610:         } else if (collector_state()->in_young_only_phase()) {
3611:             if (collector_state()->in_young_gc_before_mixed()) {
3612:                 gc_string.append("(Prepare Mixed)");
3613:             } else {
3614:                 gc_string.append("(Normal)");
3615:             }
3616:         } else {
3617:             gc_string.append("(Mixed)");
3618:         }
3619:         GCTraceTime(Info, gc) tm(gc_string, NULL, gc_cause(), true);
```

**Line 3607-3618: GC类型字符串构建**

**四种Young GC类型：**

| GC类型 | 触发条件 | 日志输出 |
|--------|----------|----------|
| Normal Young GC | Eden满，非并发标记阶段 | Pause Young (Normal) |
| Initial Mark | IHOP触发或System.gc() | Pause Young (Concurrent Start) |
| Prepare Mixed | 并发标记完成后的Young GC | Pause Young (Prepare Mixed) |
| Mixed GC | 空间回收阶段 | Pause Young (Mixed) |

**日志示例：**
```
[2024-01-15T10:23:45.123+0800][gc,start] GC(42) Pause Young (Normal)
[2024-01-15T10:24:12.456+0800][gc,start] GC(43) Pause Young (Concurrent Start)
[2024-01-15T10:25:01.789+0800][gc,start] GC(50) Pause Young (Mixed)
```

---

### 3.4 工作线程准备

```cpp
3622:         uint active_workers = AdaptiveSizePolicy::calc_active_workers(
3623:                                       workers()->total_workers(),
3624:                                       workers()->active_workers(),
3625:                                       Threads::number_of_non_daemon_threads());
3626:         active_workers = workers()->update_active_workers(active_workers);
3627:         log_info(gc, task)("Using %u workers of %u for evacuation", 
3628:                            active_workers, workers()->total_workers());
```

**Line 3622-3626: 动态工作线程数计算**

**AdaptiveSizePolicy算法：**
```cpp
uint calc_active_workers(uint total_workers, uint current_active, uint non_daemon_threads) {
    // 基于非守护线程数计算建议值
    uint suggested = non_daemon_threads / 2;
    
    // 限制在合理范围
    suggested = MAX2(suggested, 1);
    suggested = MIN2(suggested, total_workers);
    
    // 平滑变化（不超过当前2倍）
    uint max_change = current_active * 2;
    suggested = MIN2(suggested, max_change);
    
    return suggested;
}
```

**默认配置：**
```
-XX:ParallelGCThreads=N  // 默认CPU核心数（最多8）

例如8核机器：
- total_workers = 8
- 实际使用可能根据负载在1-8之间动态调整
```

---

由于篇幅限制，Young GC分析文档将分为多个部分。本章已覆盖：

1. **GC触发入口** - collect()方法、GC计数器快照
2. **VM操作执行** - VM_G1CollectForAllocation::doit()
3. **并发标记判断** - Initial Mark触发逻辑
4. **核心GC执行** - do_collection_pause_at_safepoint入口

下一章将继续分析：
- Collection Set选择
- 根扫描与对象复制
- 引用处理
- GC后清理与恢复

**GDB调试脚本：**
```bash
# verify_young_gc.gdb
set pagination off

break G1CollectedHeap::collect
break VM_G1CollectForAllocation::doit
break G1CollectedHeap::do_collection_pause_at_safepoint

run -Xms8g -Xmx8g -XX:+UseG1GC -XX:+PrintGCDetails

# 查看GC原因
p cause

# 查看是否Initial Mark
p collector_state()->_in_initial_mark_gc

# 查看工作线程数
p active_workers

continue
quit
```
