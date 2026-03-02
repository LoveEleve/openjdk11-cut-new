# G1 Object Allocation 逐行深度源码分析

> **分析目标**: G1对象分配完整流程 - TLAB、PLAB、快速分配路径  
> **源码文件**: 
> - `src/hotspot/share/gc/g1/g1CollectedHeap.cpp`
> - `src/hotspot/share/gc/g1/g1Allocator.cpp/hpp`  

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1 对象分配的本质是**三级分配路径**：(1) TLAB 快速路径（指针碰撞，无锁，纳秒级）；(2) Eden Region 慢路径（TLAB 满时申请新 TLAB 或直接分配）；(3) Humongous 分配（大对象直接分配到 Humongous Region）。

### 0.2 三级分配路径

| 路径 | 触发条件 | 代价 | 实现 |
|------|---------|------|------|
| TLAB 快速路径 | TLAB 有足够空间 | 纳秒级（指针碰撞） | `CollectedHeap::allocate_from_tlab_slow()` |
| Eden 慢路径 | TLAB 满 | 微秒级（申请新 TLAB） | `G1CollectedHeap::attempt_allocation()` |
| Humongous 分配 | 对象 > Region/2 | 毫秒级（可能触发 GC） | `G1CollectedHeap::humongous_obj_allocate()` |

### 0.3 TLAB 的作用

TLAB（Thread-Local Allocation Buffer）是每个 Java 线程的私有分配缓冲区：线程在 TLAB 内分配对象无需加锁（指针碰撞）；TLAB 满时申请新 TLAB（加锁，但频率低）；TLAB 大小自适应（根据历史分配速率调整）。

### 0.4 为什么这样设计？

- **为什么 TLAB 是线程私有的？** 多线程共享分配区域需要加锁，锁竞争严重；TLAB 让每个线程有私有分配区域，无锁分配
- **为什么 Humongous 对象不走 TLAB？** Humongous 对象 > Region/2（> 2MB），TLAB 通常只有几十 KB，无法容纳；Humongous 对象直接分配到专用的 Humongous Region

---
> **分析标准**: 面试级深度 - 逐行解释 + 面试问答 + GDB调试技巧

---

## 第1章: 对象分配入口与TLAB

### 1.1 mem_allocate - 分配入口

```cpp
407: HeapWord* G1CollectedHeap::mem_allocate(size_t word_size,
408:                                           bool *gc_overhead_limit_was_exceeded) {
409:     assert_heap_not_locked_and_not_at_safepoint();
410:
411:     if (is_humongous(word_size)) {
412:         return attempt_allocation_humongous(word_size);
413:     }
414:     size_t dummy = 0;
415:     return attempt_allocation(word_size, word_size, &dummy);
416: }
```

**Line 407-416: 对象分配入口深度解析**

**调用链：**
```
Java: new Object()
  └→ Interpreter/Compiled Code
       └→ CollectedHeap::obj_allocate()
            └→ mem_allocate(word_size, ...)
                 ├─ is_humongous() ? attempt_allocation_humongous()
                 └─ attempt_allocation()  ← 普通对象
```

**巨型对象判断（Line 411）：**
```cpp
bool is_humongous(size_t word_size) {
    // 对象大小 >= RegionSize / 2 即为巨型对象
    // 4MB Region：对象 >= 2MB (256K words) 为巨型
    return word_size >= _humongous_object_threshold_in_words;
}
```

**对象大小分类：**
```
+------------------------------------------------------------------+
|                    G1 对象大小分类                                |
+------------------------------------------------------------------+
|                                                                   |
|  1. 小型对象 (Small Object)                                        |
|     - 大小 < RegionSize / 2                                       |
|     - 使用TLAB快速分配                                             |
|     - 分配路径：attempt_allocation()                               |
|                                                                   |
|  2. 巨型对象 (Humongous Object)                                    |
|     - 大小 >= RegionSize / 2                                      |
|     - 需要连续多个Region                                           |
|     - 分配路径：attempt_allocation_humongous()                     |
|     - 特殊处理：直接分配在老年代                                    |
+------------------------------------------------------------------+
```

---

### 1.2 attempt_allocation - 快速分配尝试

```cpp
467: inline HeapWord* attempt_allocation(size_t min_word_size,
468:                                       size_t desired_word_size,
469:                                       size_t* actual_word_size);
```

**分配层次结构：**
```
+------------------------------------------------------------------+
|                    G1 对象分配层次                                |
+------------------------------------------------------------------+
|                                                                   |
|  Level 1: TLAB分配（无锁，最快）                                   |
|  ├─ 检查TLAB是否有足够空间                                         │
|  ├─ 有：直接分配                                                   │
|  └─ 无：进入Level 2                                               │
|                                                                   |
|  Level 2: Mutator Alloc Region分配（无锁，很快）                   │
|  ├─ 检查当前Eden Region是否有空间                                  │
|  ├─ 有：在Eden分配，可能需要创建新TLAB                             │
|  └─ 无：进入Level 3                                               │
|                                                                   |
|  Level 3: attempt_allocation_slow（加锁，较慢）                    │
|  ├─ 获取新的Eden Region                                            │
|  ├─ 可能触发GC                                                     │
|  └─ 失败：返回NULL，抛出OOM                                        │
+------------------------------------------------------------------+
```

**TLAB（Thread Local Allocation Buffer）机制：**
```
+------------------------------------------------------------------+
|                    TLAB 机制详解                                  |
+------------------------------------------------------------------+
|                                                                   |
|  问题：多线程竞争Eden区分配                                         │
|  ┌─────────────────────────────────────────────────────────┐     │
|  │  无TLAB时：                                               │     │
|  │  Thread 1 ──> Eden ──┐                                   │     │
|  │  Thread 2 ──> Eden ──┼──> 需要同步（CAS/锁）              │     │
|  │  Thread 3 ──> Eden ──┘                                   │     │
|  │  每次分配都有竞争开销！                                    │     │
|  └─────────────────────────────────────────────────────────┘     │
|                                                                   |
|  TLAB解决方案：                                                   │
|  ┌─────────────────────────────────────────────────────────┐     │
|  │  Thread 1 ──> TLAB 1 ──┐                                 │     │
|  │  Thread 2 ──> TLAB 2 ──┼──> 无竞争，各用各的              │     │
|  │  Thread 3 ──> TLAB 3 ──┘                                 │     │
|  │  只有TLAB满时才需要同步申请新TLAB                          │     │
|  └─────────────────────────────────────────────────────────┘     │
|                                                                   |
|  TLAB参数：                                                       │
|  -XX:+UseTLAB (默认启用)                                          │
|  -XX:TLABSize (默认动态调整)                                      │
|  -XX:MinTLABSize (默认2KB)                                        │
|  -XX:MaxTLABSize (最大不超过Eden区一半)                            │
+------------------------------------------------------------------+
```

---

## 第2章: PLAB - GC线程本地分配缓冲区

### 2.1 G1PLABAllocator类结构

```cpp
127: class G1PLABAllocator : public CHeapObj<mtGC> {
128:   friend class G1ParScanThreadState;
129: private:
130:   G1CollectedHeap* _g1h;
131:   G1Allocator* _allocator;
132:
133:   PLAB  _surviving_alloc_buffer;  // Survivor区PLAB
134:   PLAB  _tenured_alloc_buffer;    // Old区PLAB
135:   PLAB* _alloc_buffers[InCSetState::Num];
136:
137:   const uint _survivor_alignment_bytes;
138:
139:   size_t _direct_allocated[InCSetState::Num];
140:
141:   void flush_and_retire_stats();
142:   inline PLAB* alloc_buffer(InCSetState dest);
```

**Line 127-142: PLAB分配器结构**

**PLAB（Promotion Local Allocation Buffer）vs TLAB：**
```
+------------------------------------------------------------------+
|                    TLAB vs PLAB 对比                              |
+------------------------------------------------------------------+
|                                                                   |
|  TLAB (Thread Local Allocation Buffer)                            │
|  ├─ 用途：应用线程分配新对象                                        │
|  ├─ 位置：Eden区                                                   │
|  ├─ 生命周期：线程整个生命周期                                       │
|  └─ 触发：对象分配时                                                │
|                                                                   |
|  PLAB (Promotion Local Allocation Buffer)                         │
|  ├─ 用途：GC线程复制存活对象                                        │
|  ├─ 位置：Survivor区或Old区                                        │
|  ├─ 生命周期：单次GC暂停                                            │
|  └─ 触发：GC evacuation阶段                                         │
|                                                                   |
|  为什么GC需要PLAB？                                                │
|  ┌─────────────────────────────────────────────────────────┐     │
|  │  GC场景：多个GC线程同时复制对象到Survivor/Old             │     │
|  │  如果没有PLAB：                                          │     │
|  │  - 所有线程竞争同一个Survivor Region                     │     │
|  │  - 大量CAS操作，性能下降                                  │     │
|  │                                                          │     │
|  │  有了PLAB：                                              │     │
|  │  - 每个GC线程有自己的缓冲区                              │     │
|  │  - 无锁分配，性能提升                                     │     │
|  │  - PLAB满时才竞争申请新空间                               │     │
|  └─────────────────────────────────────────────────────────┘     │
+------------------------------------------------------------------+
```

### 2.2 PLAB分配流程

```cpp
// G1ParScanThreadState::allocate_in_plab
HeapWord* allocate_in_plab(size_t word_size, InCSetState dest) {
    PLAB* buffer = alloc_buffer(dest);
    
    // 1. 尝试在PLAB分配
    HeapWord* result = buffer->allocate(word_size);
    if (result != NULL) {
        return result;  // 快速路径成功
    }
    
    // 2. PLAB已满，申请新PLAB
    size_t plab_word_size = get_desired_plab_size(dest);
    HeapWord* plab_buf = allocate_new_plab(plab_word_size, dest);
    
    // 3. 初始化新PLAB
    buffer->set_buf(plab_buf, plab_word_size);
    
    // 4. 重新尝试分配
    return buffer->allocate(word_size);
}
```

**PLAB大小自适应调整：**
```cpp
void adjust_desired_plab_sz() {
    // 根据PLAB使用效率调整大小
    // 目标：浪费率 < 10%
    
    double waste_ratio = (double)_wasted / _used;
    
    if (waste_ratio > 0.10) {
        // 浪费太多，减小PLAB
        _desired_plab_sz = _desired_plab_sz / 2;
    } else if (waste_ratio < 0.05) {
        // 浪费太少，增大PLAB
        _desired_plab_sz = _desired_plab_sz * 2;
    }
    
    // 限制在合理范围
    _desired_plab_sz = clamp(_desired_plab_sz, MinPLABSize, MaxPLABSize);
}
```

**面试高频问题Q&A：**

**Q1: 为什么GC需要PLAB？直接用TLAB不行吗？**
```
A: TLAB和PLAB的使用场景完全不同：

TLAB：
- 应用线程使用
- 分配新对象到Eden
- 线程长期存在

PLAB：
- GC线程使用
- 复制存活对象到Survivor/Old
- GC暂停期间临时存在

为什么GC不能用TLAB？
1. 目标区域不同
   - TLAB在Eden
   - GC需要复制到Survivor或Old
   
2. 生命周期不同
   - TLAB长期存在
   - GC只需要暂停期间存在
   
3. 大小需求不同
   - TLAB较小（KB级）
   - PLAB较大（MB级），因为GC批量复制

类比：
TLAB就像每个人的办公桌抽屉（长期个人使用）
PLAB就像搬家时的临时纸箱（短期批量搬运）
```

---

## 第3章: 分配失败处理与GC触发

### 3.1 attempt_allocation_slow - 慢速分配路径

```cpp
418: HeapWord* G1CollectedHeap::attempt_allocation_slow(size_t word_size) {
419:     ResourceMark rm;
420:
421:     assert_heap_not_locked_and_not_at_safepoint();
422:     assert(!is_humongous(word_size), "...");
423:
434:     HeapWord *result = NULL;
435:     for (uint try_count = 1, gclocker_retry_count = 0; /* we'll return */; try_count += 1) {
436:         bool should_try_gc;
437:         uint gc_count_before;
438:
439:         {
440:             MutexLocker ml(Heap_lock);
441:
442:             // Retry allocation while holding the Heap_lock
443:             result = attempt_allocation(word_size, word_size, &dummy);
444:             if (result != NULL) {
445:                 return result;
446:             }
447:
448:             // 获取新的Eden Region
449:             if (_allocator->mutator_alloc_region()->get(word_size)) {
450:                 result = attempt_allocation(word_size, word_size, &dummy);
451:                 assert(result != NULL, "...");
452:                 return result;
453:             }
454:
455:             // 获取失败，可能需要GC
456:             should_try_gc = ...;
457:             gc_count_before = total_collections();
458:         }
459:
460:         if (should_try_gc) {
461:             // 触发GC
462:             collect(GCCause::_allocation_failure);
463:             ...
464:         }
465:     }
466: }
```

**Line 418-466: 慢速分配与GC触发**

**分配失败处理流程：**
```
+------------------------------------------------------------------+
|                    分配失败处理流程                               |
+------------------------------------------------------------------+
|                                                                   |
|  1. 快速分配失败（TLAB和Mutator Region都满）                       │
|     └─ 进入attempt_allocation_slow()                              │
|                                                                   |
|  2. 加锁重试（Heap_lock）                                          │
|     ├─ 其他线程可能已释放空间                                       │
|     ├─ 再次尝试快速分配                                             │
|     └─ 成功：返回结果                                               │
|                                                                   |
|  3. 获取新的Eden Region                                            │
|     ├─ 从空闲列表获取新Region                                       │
|     ├─ 成功：分配并返回                                             │
|     └─ 失败：空闲Region不足                                         │
|                                                                   |
|  4. 触发GC                                                         │
|     ├─ 释放CSet中的垃圾                                             │
|     ├─ 可能扩展堆                                                   │
|     └─ 重试分配                                                     │
|                                                                   |
|  5. GC后仍失败                                                      │
|     ├─ 尝试扩展堆                                                   │
|     └─ 最终失败：抛出OOM                                            │
+------------------------------------------------------------------+
```

---

## 第4章: 巨型对象分配

### 4.1 attempt_allocation_humongous

```cpp
// 巨型对象分配特殊处理
HeapWord* attempt_allocation_humongous(size_t word_size) {
    // 1. 计算需要的Region数量
    uint num_regions = (word_size + region_size_words - 1) / region_size_words;
    
    // 2. 尝试分配连续的Region
    HeapRegion* start_region = find_contiguous_regions(num_regions);
    
    if (start_region != NULL) {
        // 3. 标记为Humongous Region
        mark_as_humongous(start_region, num_regions);
        return start_region->bottom();
    }
    
    // 4. 分配失败，触发GC
    collect(GCCause::_g1_humongous_allocation);
    
    // 5. 重试
    ...
}
```

**巨型对象特点：**
```
+------------------------------------------------------------------+
|                    巨型对象 (Humongous Object)                    |
+------------------------------------------------------------------+
|                                                                   |
|  定义：对象大小 >= RegionSize / 2                                  │
|  4MB Region：对象 >= 2MB 为巨型对象                                │
|                                                                   |
|  分配特点：                                                        │
|  1. 直接分配在老年代                                               │
|  2. 需要连续的多个Region                                           │
|  3. 可能触发并发标记（如果老年代压力大）                              │
|                                                                   |
|  Region类型：                                                      │
|  ┌─────────────────┬─────────────────┐                           │
|  │ StartsHumongous │ContinuesHumongous│                           │
|  │    (第一个)      │   (后续)         │                           │
|  ├─────────────────┼─────────────────┤                           │
|  │ 存储对象头       │ 存储对象数据     │                           │
|  │ 管理RSet        │ 无独立RSet       │                           │
|  │ 决定整个对象生命周期│ 跟随StartsRegion │                           │
|  └─────────────────┴─────────────────┘                           │
|                                                                   |
|  回收特点：                                                        │
|  - 只有整个对象不可达时才能回收                                     │
|  - 可能产生内存碎片（最后一个Region可能浪费）                         │
+------------------------------------------------------------------+
```

---

## 对象分配完整流程总结

```
+==================================================================+
|              G1 对象分配完整流程                                    |
+==================================================================+
|                                                                   |
|  1. 小型对象分配 (< RegionSize/2)                                  │
|     ├─ mem_allocate()                                             │
|     ├─ attempt_allocation()                                       │
|     │   ├─ TLAB分配（无锁，最快）                                  │
|     │   ├─ Mutator Region分配（无锁）                              │
|     │   └─ 失败：attempt_allocation_slow()                         │
|     │       ├─ 加锁重试                                            │
|     │       ├─ 获取新Eden Region                                   │
|     │       └─ 触发GC                                              │
|     └─ 返回对象地址或抛出OOM                                        │
|                                                                   |
|  2. 巨型对象分配 (>= RegionSize/2)                                 │
|     ├─ attempt_allocation_humongous()                             │
|     ├─ 查找连续Region                                              │
|     ├─ 标记为Humongous                                             │
|     ├─ 失败：触发GC或扩展堆                                         │
|     └─ 返回对象地址或抛出OOM                                        │
|                                                                   |
|  3. GC时的对象复制（PLAB）                                          │
|     ├─ G1ParScanThreadState::copy_to_survivor_space()             │
|     ├─ PLAB分配（无锁，GC线程本地）                                 │
|     ├─ PLAB满：申请新PLAB                                          │
|     └─ 复制对象数据，更新引用                                       │
|                                                                   |
+==================================================================+
```

---

**GDB调试脚本：**

```bash
# verify_object_allocation.gdb
set pagination off

break G1CollectedHeap::mem_allocate
break G1CollectedHeap::attempt_allocation
break G1CollectedHeap::attempt_allocation_slow
break G1PLABAllocator::allocate_in_plab

run -Xms8g -Xmx8g -XX:+UseG1GC -XX:+PrintTLAB

# 查看TLAB信息
p Thread::current()->tlab()

# 查看PLAB信息
p _plab_allocator->_surviving_alloc_buffer
p _plab_allocator->_tenured_alloc_buffer

# 查看分配统计
p _allocator->mutator_alloc_region()

continue
quit
```

---

**文档完成**

本文档完成了G1对象分配的逐行深度分析，涵盖：
- 对象分配入口（mem_allocate）
- TLAB快速分配机制
- PLAB GC线程本地分配
- 分配失败处理与GC触发
- 巨型对象特殊处理

至此，G1 GC核心模块重写分析完成！
