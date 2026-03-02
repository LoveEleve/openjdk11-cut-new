# G1PLABAllocator 逐行源码分析

> **核心目标**：深入理解 G1 的 PLAB 管理机制、分配策略、自适应调整和统计收集。

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

`G1PLABAllocator` 的本质是**GC Worker 线程的 PLAB 管理器**：为每个 GC Worker 管理 Survivor 和 Old 两个 PLAB（Parallel Local Allocation Buffer）；PLAB 内分配无锁（指针碰撞），PLAB 满时申请新 PLAB（加锁）；`G1PLABStats` 根据历史使用率自适应调整 PLAB 大小。

### 0.2 PLAB 分配流程

```
allocate(word_size):
  1. 尝试从当前 PLAB 分配（指针碰撞，无锁）
  2. 失败 → retire 当前 PLAB（填充 dummy 对象）
  3. 申请新 PLAB（加锁，从 G1AllocRegion 分配）
  4. 从新 PLAB 分配
  5. 新 PLAB 也失败 → 直接从 Region 分配（无 PLAB）
```

### 0.3 自适应 PLAB 大小

`G1PLABStats` 跟踪每次 GC 的 PLAB 使用率（`used / allocated`）：
- 使用率高（PLAB 几乎用完）→ 增大 PLAB 大小
- 使用率低（PLAB 大量浪费）→ 减小 PLAB 大小
- 目标：使用率接近 100%，最小化 PLAB 末尾浪费

### 0.4 为什么这样设计？

- **为什么 PLAB 末尾需要填充 dummy 对象？** GC 结束后堆必须是可解析的（从任意地址可以找到对象边界）；PLAB 末尾未用空间填充 dummy 对象（`int[]`），保证堆的可解析性
- **为什么 Survivor 和 Old 各有独立的 PLAB？** 对象晋升 Old 时需要向 Old Region 分配，与 Survivor 分配互不干扰；独立 PLAB 避免两种分配的竞争

---

## 目录

1. [问题引入：为什么需要 PLABAllocator？](#1-问题引入为什么需要-plaballocator)
2. [整体架构](#2-整体架构)
3. [内存布局](#3-内存布局)
4. [PLAB 分配核心流程](#4-plab-分配核心流程)
5. [G1Allocator 底层分配](#5-g1allocator-底层分配)
6. [PLAB 统计与自适应调整](#6-plab-统计与自适应调整)
7. [关键场景分析](#7-关键场景分析)
8. [GDB 验证脚本](#8-gdb-验证脚本)
9. [面试级 Q&A](#9-面试级-qa)

---

## 1. 问题引入：为什么需要 PLABAllocator？

### 问题场景

**并发分配的挑战**：

```
场景：多个 GC 线程同时复制存活对象

线程 A: 需要 32 字节 → 从 Survivor Region 分配
线程 B: 需要 64 字节 → 从 Survivor Region 分配
线程 C: 需要 48 字节 → 从 Survivor Region 分配
...

直接从 Region 分配：
  CAS(&region->_top, region->_top + size, old_top)
  
问题：
  1. 竞争激烈：所有线程竞争同一个 _top
  2. CAS 失败率高：多线程同时尝试
  3. 缓存行争用：false sharing
  4. 延迟高：重试开销
```

**性能对比**：

```
直接 Region 分配：
  单次成功：~50ns
  单次失败（重试）：~200-500ns
  1000 个对象：~0.5ms
  
PLAB 分配：
  单次成功：~5ns（bump-the-pointer）
  1000 个对象：~0.005ms
  
提升：~100 倍
```

### G1 的解决方案

**G1PLABAllocator 的设计**：

```
1. 两层分配架构：
   - PLAB 快速路径：线程本地缓冲区（~5ns）
   - Region 慢路径：全局分配（~50-100ns）

2. 每线程双缓冲区：
   - Survivor PLAB：年轻代对象
   - Tenured PLAB：老年代对象

3. 自适应调整：
   - 根据 GC 表现调整 PLAB 大小
   - 浪费过多 → 减小
   - Refill 频繁 → 增大

4. 统计收集：
   - 已分配、浪费、撤销浪费、未使用
   - 支持预测模型和性能优化
```

---

## 2. 整体架构

### 2.1 类关系图

```
┌─────────────────────────────────────────────────────────────┐
│                    G1PLABAllocator                          │
│                                                             │
│  - _g1h: G1CollectedHeap*                                  │
│  - _allocator: G1Allocator*                                │
│  - _surviving_alloc_buffer: PLAB                           │
│  - _tenured_alloc_buffer: PLAB                             │
│  - _alloc_buffers[Num]: PLAB*[2]                           │
│  - _survivor_alignment_bytes: uint                         │
│  - _direct_allocated[Num]: size_t[2]                       │
│                                                             │
│  + plab_allocate(dest, word_sz): HeapWord*                 │
│  + allocate_direct_or_new_plab(dest, word_sz): HeapWord*   │
│  + undo_allocation(dest, obj, word_sz): void               │
│  + flush_and_retire_stats(): void                          │
│  + waste(wasted, undo_wasted): void                        │
└─────────────────────────────────────────────────────────────┘
                           │ 使用
                           ↓
┌─────────────────────────────────────────────────────────────┐
│                      G1Allocator                            │
│                                                             │
│  - _g1h: G1CollectedHeap*                                  │
│  - _survivor_is_full: bool                                 │
│  - _old_is_full: bool                                      │
│  - _mutator_alloc_region: MutatorAllocRegion               │
│  - _survivor_gc_alloc_region: SurvivorGCAllocRegion        │
│  - _old_gc_alloc_region: OldGCAllocRegion                  │
│  - _retained_old_gc_alloc_region: HeapRegion*              │
│                                                             │
│  + par_allocate_during_gc(dest, word_sz): HeapWord*        │
│  + survivor_attempt_allocation(...): HeapWord*             │
│  + old_attempt_allocation(...): HeapWord*                  │
└─────────────────────────────────────────────────────────────┘
                           │ 委托
                           ↓
┌─────────────────────────────────────────────────────────────┐
│                      PLAB (基础)                            │
│                                                             │
│  - _word_sz: size_t                                        │
│  - _bottom, _top, _end, _hard_end: HeapWord*               │
│  - _allocated, _wasted, _undo_wasted: size_t               │
│                                                             │
│  + allocate(word_sz): HeapWord*                            │
│  + set_buf(buf, word_sz): void                             │
│  + retire(): void                                          │
│  + undo_allocation(obj, word_sz): void                     │
│  + flush_and_retire_stats(stats): void                     │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 分配流程

```
对象复制请求（来自 G1ParScanThreadState）
    │
    ↓
┌─────────────────────────────────────────┐
│  plab_allocate(dest, word_sz)           │
│  - 从 PLAB 缓冲区分配                    │
│  - bump-the-pointer (~5ns)              │
└─────────────────────────────────────────┘
    │
    ├─→ 成功 → 返回地址
    │
    └─→ 失败（PLAB 满）
         │
         ↓
    ┌─────────────────────────────────────────┐
    │  allocate_direct_or_new_plab()          │
    │  - 尝试申请新 PLAB                      │
    │  - 或直接从 Region 分配                 │
    └─────────────────────────────────────────┘
         │
         ├─→ 申请新 PLAB 成功 → 从新 PLAB 分配 → 返回
         │
         └─→ PLAB 申请失败
              │
              ↓
         ┌─────────────────────────────────────────┐
         │  par_allocate_during_gc()              │
         │  - 直接从 Region 分配                  │
         │  - CAS 竞争 (~50-100ns)               │
         └─────────────────────────────────────────┘
              │
              ├─→ 成功 → 返回地址
              │
              └─→ 失败 → Evacuation Failure
```

---

## 3. 内存布局

### 3.1 G1PLABAllocator 字段布局

```cpp
// src/hotspot/share/gc/g1/g1Allocator.hpp:127-178
class G1PLABAllocator : public CHeapObj<mtGC> {
  G1CollectedHeap* _g1h;                              // offset 0
  G1Allocator* _allocator;                            // offset 8
  
  PLAB  _surviving_alloc_buffer;                      // offset 16 (~80 bytes)
  PLAB  _tenured_alloc_buffer;                        // offset ~96 (~80 bytes)
  PLAB* _alloc_buffers[InCSetState::Num];             // offset ~176 (16 bytes)
  
  const uint _survivor_alignment_bytes;               // offset ~192
  size_t _direct_allocated[InCSetState::Num];         // offset ~200 (16 bytes)
};
```

**内存布局图**：

```
G1PLABAllocator 对象（~220 bytes）：
+--------------------------------+ offset 0
| _g1h                           | 8 bytes
+--------------------------------+ offset 8
| _allocator                     | 8 bytes
+--------------------------------+ offset 16
| _surviving_alloc_buffer        | PLAB (~80 bytes)
|  - head[32] (padding)          |
|  - _word_sz                    |
|  - _bottom, _top, _end         |
|  - _hard_end                   |
|  - _allocated, _wasted         |
|  - tail[32] (padding)          |
+--------------------------------+ offset ~96
| _tenured_alloc_buffer          | PLAB (~80 bytes)
+--------------------------------+ offset ~176
| _alloc_buffers[2]              | 16 bytes
|  [0] = &_surviving_alloc_buffer|
|  [1] = &_tenured_alloc_buffer  |
+--------------------------------+ offset ~192
| _survivor_alignment_bytes      | 4 bytes
+--------------------------------+ offset ~200
| _direct_allocated[2]           | 16 bytes
+--------------------------------+ offset ~216
```

### 3.2 PLAB 字段布局

```cpp
// src/hotspot/share/gc/shared/plab.hpp:36-49
class PLAB: public CHeapObj<mtGC> {
protected:
  char      head[32];        // 缓存行填充（避免 false sharing）
  size_t    _word_sz;        // PLAB 总大小（words）
  HeapWord* _bottom;         // PLAB 起始地址
  HeapWord* _top;            // 当前分配指针
  HeapWord* _end;            // 可分配结束地址
  HeapWord* _hard_end;       // 真实结束地址（_end + AlignmentReserve）
  size_t    _allocated;      // 累计分配字数
  size_t    _wasted;         // 浪费字数（PLAB 末尾未使用）
  size_t    _undo_wasted;    // 撤销浪费字数
  char      tail[32];        // 缓存行填充
};
```

**内存布局图**：

```
PLAB 对象（~80 bytes）：
+--------------------------------+ offset 0
| head[32] (缓存行填充)          | 32 bytes
+--------------------------------+ offset 32
| _word_sz                       | 8 bytes
+--------------------------------+ offset 40
| _bottom                        | 8 bytes
+--------------------------------+ offset 48
| _top                           | 8 bytes
+--------------------------------+ offset 56
| _end                           | 8 bytes
+--------------------------------+ offset 64
| _hard_end                      | 8 bytes
+--------------------------------+ offset 72
| _allocated                     | 8 bytes
+--------------------------------+ offset 80
| _wasted                        | 8 bytes
+--------------------------------+ offset 88
| _undo_wasted                   | 8 bytes
+--------------------------------+ offset 96
| tail[32] (缓存行填充)          | 32 bytes
+--------------------------------+ offset 128
```

**PLAB 内存结构**：

```
PLAB 缓冲区内存布局：
+----------------+ _bottom
|                |
|   已分配对象   | _top 指向这里
|                |
+----------------+ _top
|                |
|  未分配空间    | ← bump-the-pointer 分配
|                |
+----------------+ _end
| AlignmentReserve| ← 对齐保留区（填充对象）
+----------------+ _hard_end
```

### 3.3 G1Allocator 字段布局

```cpp
// src/hotspot/share/gc/g1/g1Allocator.hpp:38-58
class G1Allocator : public CHeapObj<mtGC> {
  G1CollectedHeap* _g1h;                             // offset 0
  
  bool _survivor_is_full;                            // offset 8
  bool _old_is_full;                                 // offset 9
  
  MutatorAllocRegion _mutator_alloc_region;          // offset ~16
  SurvivorGCAllocRegion _survivor_gc_alloc_region;   // offset ~48
  OldGCAllocRegion _old_gc_alloc_region;             // offset ~80
  
  HeapRegion* _retained_old_gc_alloc_region;         // offset ~112
};
```

**关键设计**：

```
三个分配区域：
1. MutatorAllocRegion：
   - Mutator 线程的 TLAB 分配
   - 非并发，不需要 CAS
   
2. SurvivorGCAllocRegion：
   - GC 期间的 Survivor 对象分配
   - 并发，需要 CAS
   
3. OldGCAllocRegion：
   - GC 期间的 Old 对象分配
   - 并发，需要 CAS
   - 可保留（retained）跨 GC 使用

_full 标志：
  - survivor_is_full：Survivor 区域已满
  - old_is_full：Old 区域已满
  - 避免无效重试
```

---

## 4. PLAB 分配核心流程

### 4.1 plab_allocate() 快速路径

```cpp
// src/hotspot/share/gc/g1/g1Allocator.inline.hpp:73-81
inline HeapWord* G1PLABAllocator::plab_allocate(InCSetState dest,
                                                 size_t word_sz) {
  PLAB* buffer = alloc_buffer(dest);
  
  // Survivor 对象可能需要额外对齐
  if (_survivor_alignment_bytes == 0 || !dest.is_young()) {
    return buffer->allocate(word_sz);
  } else {
    return buffer->allocate_aligned(word_sz, _survivor_alignment_bytes);
  }
}
```

**PLAB::allocate() 实现**：

```cpp
// src/hotspot/share/gc/shared/plab.hpp:87-95
HeapWord* PLAB::allocate(size_t word_sz) {
  HeapWord* res = _top;
  
  if (pointer_delta(_end, _top) >= word_sz) {
    _top = _top + word_sz;  // bump-the-pointer
    return res;
  } else {
    return NULL;  // PLAB 满
  }
}
```

**性能分析**：

```
操作：
  1. 读取 _top 和 _end
  2. 计算剩余空间
  3. 如果足够，更新 _top
  4. 返回地址

无锁：
  - 单线程独占
  - 无 CAS
  - 无内存屏障

耗时：~5ns

对比：
  CAS 操作：~50ns
  锁操作：~100-500ns
  
提升：~10-100 倍
```

### 4.2 allocate_direct_or_new_plab() 慢路径

```cpp
// src/hotspot/share/gc/g1/g1Allocator.cpp:264-306
HeapWord* G1PLABAllocator::allocate_direct_or_new_plab(InCSetState dest,
                                                       size_t word_sz,
                                                       bool* plab_refill_failed) {
  // 步骤1：获取期望的 PLAB 大小
  size_t plab_word_size = _g1h->desired_plab_sz(dest);
  
  // 步骤2：计算需要申请的大小（对象大小 + 对齐保留）
  size_t required_in_plab = PLAB::size_required_for_allocation(word_sz);
  
  // 步骤3：判断是否值得申请新 PLAB
  // 条件1：对象能放入 PLAB
  // 条件2：浪费比例不超过阈值
  if ((required_in_plab <= plab_word_size) &&
      may_throw_away_buffer(required_in_plab, plab_word_size)) {
    
    // 步骤4：回收旧 PLAB
    PLAB* alloc_buf = alloc_buffer(dest);
    alloc_buf->retire();
    
    // 步骤5：申请新 PLAB
    size_t actual_plab_size = 0;
    HeapWord* buf = _allocator->par_allocate_during_gc(dest,
                                                        required_in_plab,
                                                        plab_word_size,
                                                        &actual_plab_size);
    
    // 步骤6：申请成功，设置新 PLAB
    if (buf != NULL) {
      alloc_buf->set_buf(buf, actual_plab_size);
      
      // 从新 PLAB 分配
      HeapWord* const obj = alloc_buf->allocate(word_sz);
      return obj;
    }
    
    // 步骤7：PLAB 申请失败，标记
    *plab_refill_failed = true;
  }
  
  // 步骤8：直接从 Region 分配
  HeapWord* result = _allocator->par_allocate_during_gc(dest, word_sz);
  if (result != NULL) {
    _direct_allocated[dest.value()] += word_sz;  // 统计直接分配
  }
  return result;
}
```

**may_throw_away_buffer() 浪费判断**：

```cpp
// src/hotspot/share/gc/g1/g1Allocator.cpp:260-262
bool G1PLABAllocator::may_throw_away_buffer(size_t const allocation_word_sz,
                                             size_t const buffer_size) const {
  // 浪费比例 = allocation / buffer_size
  // 如果浪费 < ParallelGCBufferWastePct（默认 10%），可以丢弃
  return (allocation_word_sz * 100 < buffer_size * ParallelGCBufferWastePct);
}
```

**浪费判断示例**：

```
ParallelGCBufferWastePct = 10（默认）

示例1：
  PLAB 大小 = 4096 words
  对象大小 = 256 words
  浪费比例 = 256 / 4096 = 6.25%
  6.25% < 10% → 可以丢弃旧 PLAB，申请新的

示例2：
  PLAB 大小 = 4096 words
  对象大小 = 1024 words
  浪费比例 = 1024 / 4096 = 25%
  25% > 10% → 不值得丢弃，直接从 Region 分配

原理：
  - 浪费太多 → 保留旧 PLAB，等下次 GC 回收
  - 浪费较少 → 丢弃旧 PLAB，申请新的
```

### 4.3 PLAB::retire() 回收

```cpp
// src/hotspot/share/gc/shared/plab.cpp:78-89
void PLAB::retire() {
  _wasted += retire_internal();
}

size_t PLAB::retire_internal() {
  size_t result = 0;
  if (_top < _hard_end) {
    // 用填充对象填满剩余空间
    Universe::heap()->fill_with_dummy_object(_top, _hard_end, true);
    
    // 使 PLAB 失效
    result = invalidate();
  }
  return result;
}

size_t PLAB::invalidate() {
  _end = _hard_end;
  size_t remaining = pointer_delta(_end, _top);  // 剩余空间
  _top = _end;      // 强制后续分配失败
  _bottom = _end;   // 强制 contains() 返回 false
  return remaining;
}
```

**填充对象的作用**：

```
为什么需要填充？

1. 对齐要求：
   - 对象必须对齐到 8 字节边界
   - 剩余空间可能无法放下最小对象

2. 堆遍历：
   - GC 需要遍历整个堆
   - 填充对象确保遍历不会越界

3. 安全性：
   - 防止野指针访问
   - 填充对象可识别

填充对象类型：
  - int 数组（最小对象）
  - 大小 = 剩余空间
```

### 4.4 undo_allocation() 撤销分配

```cpp
// src/hotspot/share/gc/g1/g1Allocator.cpp:308-310
void G1PLABAllocator::undo_allocation(InCSetState dest,
                                       HeapWord* obj,
                                       size_t word_sz) {
  alloc_buffer(dest)->undo_allocation(obj, word_sz);
}

// src/hotspot/share/gc/shared/plab.cpp:102-111
void PLAB::undo_allocation(HeapWord* obj, size_t word_sz) {
  // 检查是否在当前 PLAB 中
  if (contains(obj)) {
    // 在 PLAB 内，直接撤销
    undo_last_allocation(obj, word_sz);
  } else {
    // 已退休的 PLAB，标记为撤销浪费
    add_undo_waste(obj, word_sz);
  }
}

void PLAB::undo_last_allocation(HeapWord* obj, size_t word_sz) {
  assert(pointer_delta(_top, _bottom) >= word_sz, "Bad undo");
  assert(pointer_delta(_top, obj) == word_sz, "Bad undo");
  _top = obj;  // 回退 _top 指针
}

void PLAB::add_undo_waste(HeapWord* obj, size_t word_sz) {
  // 用填充对象覆盖
  Universe::heap()->fill_with_dummy_object(obj, obj + word_sz, true);
  _undo_wasted += word_sz;  // 统计撤销浪费
}
```

**撤销场景**：

```
场景1：CAS 转发指针失败

线程 A 和 B 同时复制对象 X：
  
线程 A：
  obj_ptr = plab_allocate(32)  → 成功，地址 0x1000
  forward_ptr = old->forward_to_atomic(obj_ptr)
  → CAS 成功
  → 复制对象
  → 返回 obj_ptr

线程 B：
  obj_ptr = plab_allocate(32)  → 成功，地址 0x2000
  forward_ptr = old->forward_to_atomic(obj_ptr)
  → CAS 失败，forward_ptr = 0x1000（线程 A 的地址）
  → undo_allocation(0x2000, 32)
  → 返回 forward_ptr

结果：
  - 对象只被复制一次
  - 线程 B 的分配被撤销
  - _top 回退或 _undo_wasted 增加
```

---

## 5. G1Allocator 底层分配

### 5.1 par_allocate_during_gc() 入口

```cpp
// src/hotspot/share/gc/g1/g1Allocator.cpp:164-187
HeapWord* G1Allocator::par_allocate_during_gc(InCSetState dest,
                                               size_t min_word_size,
                                               size_t desired_word_size,
                                               size_t* actual_word_size) {
  switch (dest.value()) {
    case InCSetState::Young:
      return survivor_attempt_allocation(min_word_size,
                                          desired_word_size,
                                          actual_word_size);
    case InCSetState::Old:
      return old_attempt_allocation(min_word_size,
                                     desired_word_size,
                                     actual_word_size);
    default:
      ShouldNotReachHere();
      return NULL;
  }
}
```

### 5.2 survivor_attempt_allocation() Survivor 分配

```cpp
// src/hotspot/share/gc/g1/g1Allocator.cpp:189-211
HeapWord* G1Allocator::survivor_attempt_allocation(size_t min_word_size,
                                                    size_t desired_word_size,
                                                    size_t* actual_word_size) {
  // 步骤1：无锁快速尝试
  HeapWord* result = survivor_gc_alloc_region()->attempt_allocation(min_word_size,
                                                                      desired_word_size,
                                                                      actual_word_size);
  
  // 步骤2：失败且未满，加锁重试
  if (result == NULL && !survivor_is_full()) {
    MutexLockerEx x(FreeList_lock, Mutex::_no_safepoint_check_flag);
    
    result = survivor_gc_alloc_region()->attempt_allocation_locked(min_word_size,
                                                                    desired_word_size,
                                                                    actual_word_size);
    
    // 步骤3：仍然失败，标记满
    if (result == NULL) {
      set_survivor_full();
    }
  }
  
  // 步骤4：成功分配，标记年轻代脏卡
  if (result != NULL) {
    _g1h->dirty_young_block(result, *actual_word_size);
  }
  
  return result;
}
```

**分配流程**：

```
第一次尝试（无锁）：
  attempt_allocation() → CAS 分配
  
  成功 → 返回
  
  失败 → 可能竞争，也可能 Region 满

第二次尝试（加锁）：
  attempt_allocation_locked() → 加锁后分配
  
  成功 → 返回
  
  失败 → Region 确实满了

标记满：
  set_survivor_full()
  
  后续线程直接跳过无锁尝试
```

### 5.3 old_attempt_allocation() Old 分配

```cpp
// src/hotspot/share/gc/g1/g1Allocator.cpp:213-232
HeapWord* G1Allocator::old_attempt_allocation(size_t min_word_size,
                                               size_t desired_word_size,
                                               size_t* actual_word_size) {
  // 与 survivor_attempt_allocation() 类似
  // 但没有 dirty_young_block() 调用
  
  HeapWord* result = old_gc_alloc_region()->attempt_allocation(min_word_size,
                                                                 desired_word_size,
                                                                 actual_word_size);
  
  if (result == NULL && !old_is_full()) {
    MutexLockerEx x(FreeList_lock, Mutex::_no_safepoint_check_flag);
    
    result = old_gc_alloc_region()->attempt_allocation_locked(min_word_size,
                                                               desired_word_size,
                                                               actual_word_size);
    
    if (result == NULL) {
      set_old_full();
    }
  }
  
  return result;
}
```

**Survivor vs Old 的区别**：

```
Survivor 分配：
  1. 标记年轻代脏卡
     - dirty_young_block(result, size)
     - 用于 RSet 维护
  
  2. 意义：
     - Survivor 区域的对象可能被老年代引用
     - 需要追踪这些跨代引用

Old 分配：
  1. 无需额外处理
     - 老年代对象不会被标记
  
  2. 意义：
     - 老年代对象不会被年轻代引用
     - 不需要追踪
```

### 5.4 retained_old_gc_alloc_region 保留机制

```cpp
// src/hotspot/share/gc/g1/g1Allocator.cpp:59-92
void G1Allocator::reuse_retained_old_region(EvacuationInfo& evacuation_info,
                                             OldGCAllocRegion* old,
                                             HeapRegion** retained_old) {
  HeapRegion* retained_region = *retained_old;
  *retained_old = NULL;
  
  // 判断是否可以重用
  if (retained_region != NULL &&
      !retained_region->in_collection_set() &&      // 不在 CSet
      !(retained_region->top() == retained_region->end()) &&  // 未满
      !retained_region->is_empty() &&               // 非空
      !retained_region->is_humongous()) {           // 非大对象
    
    // 从 old_set 移除（分配时不允许在集合中）
    _g1h->old_set_remove(retained_region);
    
    // 标记开始复制
    bool during_im = _g1h->collector_state()->in_initial_mark_gc();
    retained_region->note_start_of_copying(during_im);
    
    // 设置为当前 Old 分配区域
    old->set(retained_region);
    
    // 记录使用量
    evacuation_info.set_alloc_regions_used_before(retained_region->used());
  }
}
```

**保留机制的意义**：

```
问题：
  Old Region 分配频繁：
    - Young GC 后晋升
    - 对象年龄达标晋升
  
  每次 GC 都申请新 Region：
    - Region 分配开销大
    - Region 元数据更新开销大

解决：
  保留未满的 Old Region：
    - 上次 GC 使用的 Old Region
    - 如果未满，下次 GC 继续使用
    - 避免频繁 Region 分配

条件：
  1. 不在 CSet（不会被回收）
  2. 未满（还有空间）
  3. 非空（不是刚分配就放弃）
  4. 非大对象（大对象有特殊处理）
```

---

## 6. PLAB 统计与自适应调整

### 6.1 PLABStats 统计结构

```cpp
// src/hotspot/share/gc/shared/plab.hpp:146-212
class PLABStats : public CHeapObj<mtGC> {
protected:
  const char* _description;              // 标识符
  
  size_t _allocated;                     // 总分配字数
  size_t _wasted;                        // 浪费字数（PLAB 末尾未使用）
  size_t _undo_wasted;                   // 撤销浪费字数
  size_t _unused;                        // 最后一个 PLAB 未使用字数
  
  size_t _desired_net_plab_sz;           // 期望 PLAB 大小
  AdaptiveWeightedAverage _filter;       // 衰减平均过滤器
  
public:
  // 计算当前 GC 线程数下的 PLAB 大小
  size_t desired_plab_sz(uint no_of_gc_workers);
  
  // 根据统计调整 PLAB 大小
  void adjust_desired_plab_sz();
  
  size_t used() const { 
    return allocated() - (wasted() + unused()); 
  }
};
```

### 6.2 G1EvacStats G1 扩展统计

```cpp
// src/hotspot/share/gc/g1/g1EvacStats.hpp:31-75
class G1EvacStats : public PLABStats {
private:
  size_t _region_end_waste;   // Region 末尾浪费字数
  uint   _regions_filled;     // 填满的 Region 数量
  size_t _direct_allocated;   // 直接从 Region 分配的字数
  
  size_t _failure_used;       // Evacuation Failure 区域的已用字数
  size_t _failure_waste;      // Evacuation Failure 区域的浪费字数
};
```

### 6.3 flush_and_retire_stats() 统计刷新

```cpp
// src/hotspot/share/gc/g1/g1Allocator.cpp:312-322
void G1PLABAllocator::flush_and_retire_stats() {
  for (uint state = 0; state < InCSetState::Num; state++) {
    PLAB* const buf = _alloc_buffers[state];
    
    if (buf != NULL) {
      // 获取统计对象
      G1EvacStats* stats = _g1h->alloc_buffer_stats(state);
      
      // 刷新 PLAB 统计
      buf->flush_and_retire_stats(stats);
      
      // 添加直接分配统计
      stats->add_direct_allocated(_direct_allocated[state]);
      
      // 重置直接分配计数
      _direct_allocated[state] = 0;
    }
  }
}
```

**PLAB::flush_and_retire_stats()**：

```cpp
// src/hotspot/share/gc/shared/plab.cpp:60-76
void PLAB::flush_and_retire_stats(PLABStats* stats) {
  // 回收最后一个 PLAB
  size_t unused = retire_internal();
  
  // 刷新统计
  stats->add_allocated(_allocated);
  stats->add_wasted(_wasted);
  stats->add_undo_wasted(_undo_wasted);
  stats->add_unused(unused);
  
  // 重置（保留 PLAB 对象跨 GC）
  _allocated   = 0;
  _wasted      = 0;
  _undo_wasted = 0;
}
```

### 6.4 adjust_desired_plab_sz() 自适应调整

```cpp
// src/hotspot/share/gc/shared/plab.cpp:145-173
void PLABStats::adjust_desired_plab_sz() {
  // 打印当前统计
  log_plab_allocation();
  
  // 如果禁用自适应，直接返回
  if (!ResizePLAB) {
    reset();
    return;
  }
  
  // 计算理想 PLAB 大小
  size_t plab_sz = compute_desired_plab_sz();
  
  // 衰减平均
  _filter.sample(plab_sz);
  _desired_net_plab_sz = MAX2(min_size(), (size_t)_filter.average());
  
  // 打印调整结果
  log_sizing(plab_sz, _desired_net_plab_sz);
  
  // 重置统计
  reset();
}
```

**compute_desired_plab_sz() 计算逻辑**：

```cpp
// src/hotspot/share/gc/shared/plab.cpp:175-186
size_t PLABStats::compute_desired_plab_sz() {
  size_t allocated = MAX2(_allocated, size_t(1));  // 避免除零
  
  // 计算浪费比例
  double wasted_frac = (double)_unused / (double)allocated;
  
  // 计算目标 refill 次数
  size_t target_refills = (size_t)((wasted_frac * TargetSurvivorRatio) / TargetPLABWastePct);
  if (target_refills == 0) {
    target_refills = 1;
  }
  
  // 计算实际使用量
  size_t used = allocated - _wasted - _unused;
  
  // 计算理想 PLAB 大小
  size_t recent_plab_sz = used / target_refills;
  
  return recent_plab_sz;
}
```

**调整算法详解**：

```
目标：
  最小化浪费，最大化利用率

参数：
  TargetSurvivorRatio = 50（默认）
  TargetPLABWastePct = 10（默认）

公式：
  target_refills = (unused_ratio * TargetSurvivorRatio) / TargetPLABWastePct
  ideal_plab_sz = used / target_refills

示例1：浪费过多
  allocated = 10000 words
  wasted = 0
  unused = 2000 words（最后一个 PLAB 剩余）
  
  wasted_frac = 2000 / 10000 = 20%
  target_refills = (0.2 * 50) / 10 = 1
  used = 10000 - 0 - 2000 = 8000
  recent_plab_sz = 8000 / 1 = 8000 words
  
  解读：
    - 浪费比例高（20%）
    - 应减少 refill 次数
    - 增大 PLAB 大小

示例2：浪费合理
  allocated = 10000 words
  wasted = 0
  unused = 500 words
  
  wasted_frac = 500 / 10000 = 5%
  target_refills = (0.05 * 50) / 10 = 0.25 → 1
  used = 10000 - 0 - 500 = 9500
  recent_plab_sz = 9500 / 1 = 9500 words
  
  解读：
    - 浪费比例合理（5%）
    - PLAB 大小保持

示例3：Refill 频繁
  allocated = 10000 words
  wasted = 0
  unused = 100 words
  
  wasted_frac = 100 / 10000 = 1%
  target_refills = (0.01 * 50) / 10 = 0.05 → 1
  
  解读：
    - 浪费极少（1%）
    - 可能 PLAB 太小，refill 频繁
    - 应增大 PLAB
```

**衰减平均**：

```cpp
// AdaptiveWeightedAverage 实现
class AdaptiveWeightedAverage {
  float _average;       // 当前平均值
  unsigned _weight;     // 权重（0-100）
  
  void sample(float new_val) {
    // 衰减平均公式：
    // avg = weight% * new_val + (100 - weight)% * old_avg
    _average = _weight * new_val / 100.0 + 
               (100 - _weight) * _average / 100.0;
  }
};

// PLABStats 使用 weight = 95
// 即：95% 新值 + 5% 旧值
// 近期数据权重更高，快速适应变化
```

---

## 7. 关键场景分析

### 7.1 场景1：小对象 PLAB 分配（快速路径）

```
对象大小：32 bytes
来源：Eden Region
目标：Survivor Region

流程：
1. copy_to_survivor_space(state=Young, obj, mark)
2. word_sz = 32 / 8 = 4 words
3. dest_state = Young（保留在 Survivor）
4. obj_ptr = _plab_allocator->plab_allocate(Young, 4)
   
   plab_allocate() 内部：
   - buffer = &_surviving_alloc_buffer
   - buffer->allocate(4)
     - res = _top = 0x1000
     - _end - _top = 2048 words >= 4 words
     - _top = 0x1000 + 4 = 0x1020
     - return 0x1000

耗时分析：
  - PLAB 分配：~5ns
  - CAS 转发：~50ns
  - 复制对象：~20ns（32 bytes）
  - 扫描引用：~10ns
  
总耗时：~85ns
```

### 7.2 场景2：PLAB 满，申请新 PLAB

```
当前 PLAB 状态：
  _top = 0x1FE0
  _end = 0x2000
  剩余 = 32 words

对象大小：64 bytes = 8 words

流程：
1. plab_allocate(Young, 8)
   - 剩余 32 words < 8 words
   - 返回 NULL

2. allocate_direct_or_new_plab(Young, 8, &failed)
   - plab_word_size = desired_plab_sz(Young) = 2048 words
   - required_in_plab = 8 + AlignmentReserve = 16 words
   - may_throw_away_buffer(16, 2048) = true
     - 16 * 100 = 1600 < 2048 * 10 = 20480
   
   - alloc_buf->retire()
     - _wasted += 32 words
     - fill_with_dummy_object(0x1FE0, 0x2000)
   
   - par_allocate_during_gc(Young, 16, 2048, &actual)
     - survivor_attempt_allocation()
     - CAS 分配成功
     - buf = 0x3000
     - actual = 2048 words
   
   - alloc_buf->set_buf(0x3000, 2048)
     - _bottom = 0x3000
     - _top = 0x3000
     - _end = 0x3000 + 2048 - 8 = 0x3FF0
     - _hard_end = 0x3000 + 2048 = 0x4000
   
   - alloc_buf->allocate(8)
     - _top = 0x3000
     - _end - _top = 2032 words >= 8 words
     - _top = 0x3000 + 8 = 0x3020
     - return 0x3000

耗时分析：
  - retire()：~50ns
  - par_allocate_during_gc()：~100ns
  - set_buf()：~10ns
  - allocate()：~5ns
  
总耗时：~165ns（比直接 Region 分配快 ~3 倍）
```

### 7.3 场景3：大对象直接分配

```
对象大小：100 KB = 12800 words
来源：Eden Region
目标：Old Region

问题：
  PLAB 大小 = 2048 words
  对象大小 = 12800 words
  对象 > PLAB

流程：
1. plab_allocate(Old, 12800)
   - PLAB 太小，返回 NULL

2. allocate_direct_or_new_plab(Old, 12800, &failed)
   - required_in_plab = 12800 + 8 = 12808 words
   - plab_word_size = 2048 words
   - required_in_plab > plab_word_size
   
   - 跳过 PLAB 申请
   
   - par_allocate_during_gc(Old, 12800)
     - old_attempt_allocation()
     - CAS 分配
     - 返回地址

统计：
  _direct_allocated[Old] += 12800

耗时分析：
  - par_allocate_during_gc()：~200ns
  - CAS 可能重试 1-2 次
  
总耗时：~300ns
```

### 7.4 场景4：Evacuation Failure

```
Old 区域已满：
  _old_is_full = true

对象大小：32 bytes
目标：Old Region

流程：
1. copy_to_survivor_space(state=Young, obj, mark)
2. dest_state = Old（晋升）
3. if (_old_gen_is_full && dest_state.is_old())
     return handle_evacuation_failure_par(obj, mark)

4. handle_evacuation_failure_par()
   - forward_ptr = old->forward_to_atomic(old, memory_order_relaxed)
   - 如果 CAS 成功：
     - 标记对象（self-forwarded）
     - 标记 Region 为 evacuation_failed
     - 扫描引用

结果：
  - 对象保留在原位置
  - Region 不被释放
  - 下次 GC 再次尝试回收
```

---

## 8. GDB 验证脚本

### 8.1 观察 PLAB 分配

```gdb
# gdb_script: observe_plab_allocation.gdb

break PLAB::allocate
commands
  printf "\n=== PLAB::allocate() ===\n"
  printf "word_sz: %lu words\n", $rdi
  
  # 查看 PLAB 状态
  set $plab = (PLAB*)this
  printf "_bottom: %p\n", $plab->_bottom
  printf "_top:    %p\n", $plab->_top
  printf "_end:    %p\n", $plab->_end
  printf "remain:  %lu words\n", $plab->_end - $plab->_top
  
  # 单步执行
  next
  
  if $rax != 0
    printf "allocated: %p\n", $rax
    printf "new _top:  %p\n", $plab->_top
  else
    printf "failed (PLAB full)\n"
  end
  
  continue
end

run
```

### 8.2 观察 PLAB Refill

```gdb
# gdb_script: observe_plab_refill.gdb

break G1PLABAllocator::allocate_direct_or_new_plab
commands
  printf "\n=== allocate_direct_or_new_plab() ===\n"
  printf "dest:    %d\n", $rdi
  printf "word_sz: %lu words\n", $rsi
  
  # 单步执行
  next
  
  # 查看分配结果
  printf "result:  %p\n", $rax
  
  continue
end

break G1Allocator::par_allocate_during_gc
commands
  printf "\n=== par_allocate_during_gc() ===\n"
  printf "dest:    %d\n", $rdi
  printf "size:    %lu words\n", $rsi
  
  continue
end

run
```

### 8.3 统计 PLAB 使用情况

```gdb
# gdb_script: stat_plab_usage.gdb

define stat_plab
  set $heap = (G1CollectedHeap*)Universe::_collectedHeap
  set $pss_set = $heap->_pss
  
  printf "\n=== PLAB 使用统计 ===\n"
  
  set $i = 0
  set $n_workers = $pss_set->_n_workers
  
  while $i < $n_workers
    set $pss = $pss_set->_states[$i]
    if $pss != 0
      set $plab_alloc = $pss->_plab_allocator
      
      # Survivor PLAB
      set $surv_buf = &$plab_alloc->_surviving_alloc_buffer
      printf "Worker %d - Survivor PLAB:\n", $i
      printf "  _top:     %p\n", $surv_buf->_top
      printf "  _end:     %p\n", $surv_buf->_end
      printf "  remain:   %lu words\n", $surv_buf->_end - $surv_buf->_top
      printf "  allocated: %lu words\n", $surv_buf->_allocated
      printf "  wasted:    %lu words\n", $surv_buf->_wasted
      
      # Tenured PLAB
      set $tenured_buf = &$plab_alloc->_tenured_alloc_buffer
      printf "Worker %d - Tenured PLAB:\n", $i
      printf "  _top:     %p\n", $tenured_buf->_top
      printf "  _end:     %p\n", $tenured_buf->_end
      printf "  remain:   %lu words\n", $tenured_buf->_end - $tenured_buf->_top
      printf "  allocated: %lu words\n", $tenured_buf->_allocated
      printf "  wasted:    %lu words\n", $tenured_buf->_wasted
    end
    set $i = $i + 1
  end
end

# 在 GC 中调用
# (gdb) stat_plab
```

### 8.4 观察 PLAB 大小调整

```gdb
# gdb_script: observe_plab_resize.gdb

break PLABStats::adjust_desired_plab_sz
commands
  printf "\n=== adjust_desired_plab_sz() ===\n"
  
  # 查看统计
  set $stats = (PLABStats*)this
  printf "allocated:   %lu words\n", $stats->_allocated
  printf "wasted:      %lu words\n", $stats->_wasted
  printf "unused:      %lu words\n", $stats->_unused
  printf "current sz:  %lu words\n", $stats->_desired_net_plab_sz
  
  # 单步执行计算
  next
  
  printf "new sz:      %lu words\n", $stats->_desired_net_plab_sz
  
  continue
end

run
```

---

## 9. 面试级 Q&A

### Q1: 为什么 G1 需要两层分配架构（PLAB + Region）？

**A**: 平衡性能和空间利用率。

**直接 Region 分配的问题**：
```
1. 竞争激烈：
   - 所有 GC 线程竞争同一个 _top
   - CAS 失败率高（多线程并发）
   - 缓存行争用（false sharing）

2. 性能差：
   - 单次成功：~50ns
   - 单次失败：~200-500ns（重试）
   - 1000 个对象：~0.5ms

3. 内存屏障：
   - CAS 需要内存屏障
   - 增加延迟
```

**PLAB 的优势**：
```
1. 无竞争：
   - 每线程独占缓冲区
   - bump-the-pointer
   - 无 CAS，无内存屏障

2. 性能高：
   - 单次分配：~5ns
   - 1000 个对象：~0.005ms
   - 提升：~100 倍

3. 缓存友好：
   - 本地分配，缓存命中率高
   - 减少远程内存访问
```

**代价**：
```
1. 浪费：
   - PLAB 末尾未使用空间
   - 平均浪费 ~50% PLAB 大小
   
2. 调整：
   - 需要自适应算法
   - 根据 GC 表现动态调整
```

---

### Q2: PLAB 大小如何自适应调整？

**A**: 基于浪费比例和 refill 次数。

**调整算法**：
```
1. 收集统计：
   - allocated：总分配字数
   - wasted：PLAB 末尾浪费
   - unused：最后一个 PLAB 未使用

2. 计算浪费比例：
   wasted_frac = unused / allocated

3. 计算目标 refill 次数：
   target_refills = (wasted_frac * TargetSurvivorRatio) / TargetPLABWastePct
   
   默认：
   - TargetSurvivorRatio = 50
   - TargetPLABWastePct = 10

4. 计算理想 PLAB 大小：
   used = allocated - wasted - unused
   ideal_plab_sz = used / target_refills

5. 衰减平均：
   avg = 95% * new_sz + 5% * old_avg
```

**示例**：
```
场景1：浪费过多
  allocated = 10000 words
  unused = 2000 words
  wasted_frac = 20%
  
  target_refills = (0.2 * 50) / 10 = 1
  used = 8000 words
  ideal_plab_sz = 8000 words
  
  解读：增大 PLAB，减少 refill

场景2：Refill 频繁
  allocated = 10000 words
  unused = 100 words
  wasted_frac = 1%
  
  target_refills = 1
  used = 9900 words
  ideal_plab_sz = 9900 words
  
  解读：PLAB 可能太小，增大
```

**关键参数**：
```
-XX:ResizePLAB=true              # 启用自适应（默认）
-XX:TargetPLABWastePct=10        # 浪费阈值
-XX:MinTLABSize=2k               # 最小 PLAB 大小
-XX:G1PLABSize=16k               # 初始 PLAB 大小
```

---

### Q3: 为什么需要 undo_allocation()？

**A**: 处理 CAS 转发指针失败。

**场景**：
```
线程 A 和 B 同时复制对象 X：

线程 A：
  obj_ptr = plab_allocate(32)  → 0x1000
  forward_ptr = old->forward_to_atomic(0x1000)
  → CAS 成功（old->mark = 0x1000 | marked_bit）
  → 复制对象
  → 返回 0x1000

线程 B（同时）：
  obj_ptr = plab_allocate(32)  → 0x2000
  forward_ptr = old->forward_to_atomic(0x2000)
  → CAS 失败（old->mark 已被 A 改为 0x1000 | marked_bit）
  → forward_ptr = 0x1000
  
  需要撤销 0x2000 的分配！
  
  undo_allocation(0x2000, 32)
    → _top 回退，或
    → _undo_wasted 增加
  
  返回 0x1000（线程 A 的地址）
```

**为什么不能忽略？**
```
1. 空间泄漏：
   - 0x2000 已分配但未使用
   - 如果不撤销，这块空间永久浪费

2. 统计不准确：
   - allocated 包含 0x2000
   - 但实际未使用
   - 影响自适应调整

3. PLAB 满判断：
   - 如果 0x2000 是 PLAB 最后空间
   - 不撤销会导致 PLAB 提前满
```

---

### Q4: retained_old_gc_alloc_region 有什么作用？

**A**: 避免 Old Region 频繁分配和释放。

**问题**：
```
Old Region 分配场景：
  - Young GC 后晋升
  - 对象年龄达标晋升

频繁分配：
  - 每次 GC 申请新 Old Region
  - Region 元数据更新开销大
  - 可能触发 Region 分配瓶颈
```

**解决方案**：
```
保留机制：
  - GC 结束时，检查 Old 分配区域
  - 如果未满，保留
  - 下次 GC 重用

重用条件：
  1. 不在 CSet（不会被回收）
  2. 未满（还有空间）
  3. 非空（不是刚分配就放弃）
  4. 非大对象（大对象有特殊处理）
```

**示例**：
```
Young GC #1：
  - 晋升对象：50 KB
  - Old Region：Region 100（4 MB）
  - 使用量：50 KB / 4 MB = 1.25%
  
  GC 结束：
    - Region 100 未满，保留
    - _retained_old_gc_alloc_region = Region 100

Young GC #2：
  - 重用 Region 100
  - 晋升对象：100 KB
  - 使用量：150 KB / 4 MB = 3.75%
  
  GC 结束：
    - Region 100 仍未满，继续保留

...

Young GC #N：
  - Region 100 快满
  - 晋升对象：50 KB
  - 使用量：3.9 MB / 4 MB = 97.5%
  
  GC 结束：
    - Region 100 满，释放
    - _retained_old_gc_alloc_region = NULL
```

**性能影响**：
```
无保留：
  - 每次 GC：申请 Region → 设置元数据 → 分配
  - 开销：~1-2ms

有保留：
  - 重用已有 Region
  - 开销：~0.1ms

提升：~10 倍
```

---

### Q5: Survivor 对齐有什么作用？

**A**: 优化压缩指针和缓存行对齐。

**配置**：
```
-XX:SurvivorAlignmentInBytes=64

默认：
  SurvivorAlignmentInBytes = ObjectAlignmentInBytes（通常 8）
  即：不额外对齐
```

**对齐效果**：
```
无对齐（默认）：
  对象地址：0x1000, 0x1018, 0x1030, ...
  对齐：8 字节（对象自然对齐）

64 字节对齐：
  对象地址：0x1000, 0x1040, 0x1080, ...
  对齐：64 字节（缓存行对齐）
```

**优势**：
```
1. 缓存行对齐：
   - 每个对象在独立缓存行
   - 避免 false sharing
   - 适合多核访问

2. 压缩指针优化：
   - Oop 偏移量是 64 的倍数
   - 可以编码更大的堆
```

**代价**：
```
1. 浪费空间：
   - 每个对象额外浪费 ~56 字节
   - 总堆使用量增加

2. 适用场景：
   - 多核高频访问
   - 对象较少
```

---

### Q6: 如何优化 PLAB 性能？

**A**: 多维度调整。

**1. PLAB 大小调整**：
```
-XX:G1PLABSize=16k               # 初始大小
-XX:MinTLABSize=2k               # 最小大小
-XX:ResizePLAB=true              # 启用自适应

原则：
  - 小 PLAB：浪费少，但 refill 频繁
  - 大 PLAB：refill 少，但浪费多
  - 自适应：动态调整
```

**2. 浪费阈值调整**：
```
-XX:TargetPLABWastePct=10        # 浪费阈值（%）
-XX:ParallelGCBufferWastePct=10  # PLAB 丢弃阈值（%）

原则：
  - 低阈值：更保守，PLAB 大小增长慢
  - 高阈值：更激进，PLAB 大小增长快
```

**3. GC 线程数调整**：
```
-XX:ParallelGCThreads=8          # GC 线程数

影响：
  - 线程多：
    - 并行度高
    - 但 PLAB 总大小 = 线程数 × 单 PLAB
    - 总浪费可能增加
  
  - 线程少：
    - 并行度低
    - 但 PLAB 总浪费少
```

**4. 直接分配优化**：
```
场景：大对象频繁

问题：
  - 大对象直接从 Region 分配
  - CAS 竞争
  - 性能差

解决：
  - 避免大对象
  - 分段处理
  - 调整 ParGCArrayScanChunk
```

**5. 监控和调试**：
```
启用日志：
  -Xlog:gc+plab=debug

输出示例：
  [GC,plab] Young PLAB allocation: allocated: 65536B, wasted: 1024B, unused: 512B
  [GC,plab] Young sizing: calculated: 16384B, actual: 16384B

分析：
  - wasted 高 → 减小 PLAB
  - unused 高 → 减小 PLAB
  - calculated < actual → 增大 PLAB
```

---

## 总结

**G1PLABAllocator 的核心价值**：

1. **两层分配**：PLAB 快速路径（~5ns）+ Region 慢路径（~100ns）
2. **线程本地**：每个 GC 线程独立缓冲区，无竞争
3. **双缓冲区**：Survivor + Tenured，支持不同目标区域
4. **自适应调整**：根据浪费比例动态调整 PLAB 大小
5. **统计完善**：allocated、wasted、unused、undo_wasted，支持优化

**关键数据**：
- PLAB 大小：~2-16 KB（自适应）
- PLAB 分配耗时：~5ns
- Region 分配耗时：~50-100ns
- 浪费阈值：10%（默认）
- 衰减权重：95%

**下一步学习**：
- G1AllocRegion：分配区域的详细管理
- G1ScanEvacuatedObjClosure：引用扫描闭包
- G1EvacuationRootClosures：根集闭包体系
