# G1ParScanThreadState 逐行源码分析

> **核心目标**：深入理解 G1 Evacuation 阶段的对象复制、引用更新、PLAB 分配和 Work Stealing 机制。

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

`G1ParScanThreadState` 的本质是**单个 GC Worker 线程的 Evacuation 状态机**：封装了一个 GC Worker 在 Evacuation 阶段所需的所有状态——PLAB（分配缓冲）、`RefToScanQueue`（待扫描队列）、`G1AllocRegion`（目标 Region）、统计信息等；`copy_to_survivor_space()` 是核心方法，完成单个对象的复制。

### 0.2 核心字段

| 字段 | 类型 | 作用 |
|------|------|------|
| `_refs` | `RefToScanQueue*` | 待扫描对象队列（Work Stealing） |
| `_plab_allocator` | `G1PLABAllocator*` | PLAB 分配器（Survivor/Old 各一个） |
| `_scanner` | `G1ScanEvacuatedObjClosure` | 扫描复制后对象的引用字段 |
| `_dest` | `InCSetState` | 目标 Region 类型（Survivor/Old） |
| `_worker_id` | `uint` | Worker ID（用于 Work Stealing） |

### 0.3 `copy_to_survivor_space()` 核心流程

1. 检查对象是否已有转发指针（已被其他 Worker 复制）
2. 从 PLAB 分配目标空间
3. 复制对象（`Copy::aligned_disjoint_words()`）
4. CAS 写转发指针（`obj->forward_to(new_obj)`）
5. 将新对象加入 `RefToScanQueue`（扫描其引用字段）

### 0.4 为什么这样设计？

- **为什么用 CAS 写转发指针？** 多个 GC Worker 可能同时复制同一个对象；CAS 保证只有一个 Worker 成功，其他 Worker 直接使用转发指针
- **为什么 PLAB 有 Survivor 和 Old 两个？** 对象年龄 ≥ 阈值时晋升 Old，需要分别管理两种目标 Region 的分配

---

## 目录

1. [问题引入：Evacuation 要解决什么问题？](#1-问题引入evacuation-要解决什么问题)
2. [整体架构](#2-整体架构)
3. [内存布局](#3-内存布局)
4. [对象复制核心流程](#4-对象复制核心流程)
5. [PLAB 分配机制](#5-plab-分配机制)
6. [引用更新与 RSet 维护](#6-引用更新与-rset-维护)
7. [Work Stealing 机制](#7-work-stealing-机制)
8. [关键场景分析](#8-关键场景分析)
9. [GDB 验证脚本](#9-gdb-验证脚本)
10. [面试级 Q&A](#10-面试级-qa)

---

## 1. 问题引入：Evacuation 要解决什么问题？

### 问题场景

**对象移动的挑战**：

```java
// Young GC 前：
Eden Region 0:
  +----------+
  | Object A |  (地址 0x1000)
  +----------+
       ↓ 引用
  +----------+
  | Object B |  (地址 0x2000)
  +----------+

// Young GC 后：
Survivor Region:
  +----------+
  | Object A |  (新地址 0x5000)  ← 地址变了！
  +----------+
       ↓ 引用怎么办？
  +----------+
  | Object B |  (新地址 0x6000)
  +----------+
```

**核心问题**：
1. **对象复制**：如何高效复制存活对象？
2. **转发指针**：如何让其他引用找到新地址？
3. **引用更新**：如何更新所有指向旧对象的引用？
4. **并发安全**：多个线程如何协同工作？

### G1 的解决方案

**G1ParScanThreadState 的设计**：

```
1. 每个线程独立状态（Thread Local）
   - PLAB（线程本地分配缓冲区）
   - 引用队列（任务队列）
   - 统计数据

2. 对象复制流程：
   - 分配新空间（PLAB 快速路径）
   - 安装转发指针（CAS）
   - 复制对象内容
   - 更新引用

3. 并发协作：
   - Work Stealing（任务窃取）
   - Dirty Card Queue（RSet 更新）
   - 存活统计聚合
```

---

## 2. 整体架构

### 2.1 类关系图

```
┌─────────────────────────────────────────────────────────────┐
│                  G1ParScanThreadState                       │
│                                                             │
│  - _g1h: G1CollectedHeap*                                  │
│  - _refs: RefToScanQueue*                                  │
│  - _dcq: DirtyCardQueue                                    │
│  - _ct: G1CardTable*                                       │
│  - _closures: G1EvacuationRootClosures*                    │
│  - _plab_allocator: G1PLABAllocator*                       │
│  - _age_table: AgeTable                                    │
│  - _dest: InCSetState[Num]                                 │
│  - _tenuring_threshold: uint                               │
│  - _scanner: G1ScanEvacuatedObjClosure                     │
│  - _surviving_young_words: size_t*                         │
│  - _old_gen_is_full: bool                                  │
│                                                             │
│  + copy_to_survivor_space(state, obj, mark): oop           │
│  + do_oop_evac(p): void                                    │
│  + update_rs(from, p, o): void                             │
│  + trim_queue(): void                                      │
│  + steal_and_trim_queue(task_queues): void                 │
│  + handle_evacuation_failure_par(obj, mark): oop           │
└─────────────────────────────────────────────────────────────┘
                           │ 使用
                           ↓
┌─────────────────────────────────────────────────────────────┐
│                    G1PLABAllocator                          │
│                                                             │
│  - _alloc_buffers[G1AllocRegion::Num]: PLAB*              │
│  - _g1_alloc: G1Allocator*                                 │
│                                                             │
│  + plab_allocate(state, word_sz): HeapWord*                │
│  + allocate_direct_or_new_plab(state, word_sz): HeapWord*  │
│  + undo_allocation(state, obj_ptr, word_sz): void          │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 工作流程

```
GC 触发
    │
    ↓
创建 G1ParScanThreadStateSet（n_workers 个）
    │
    ↓
每个线程获取自己的 G1ParScanThreadState
    │
    ├─→ 根集扫描
    │     └─→ push_on_queue(ref)  // 将引用入队
    │
    ├─→ trim_queue()  // 处理本地队列
    │     │
    │     └─→ do_oop_evac(ref)
    │           ├─→ 检查对象是否在 CSet
    │           ├─→ copy_to_survivor_space()
    │           │     ├─→ PLAB 分配
    │           │     ├─→ 安装转发指针（CAS）
    │           │     ├─→ 复制对象
    │           │     └─→ 扫描新对象引用
    │           └─→ update_rs()  // 更新 RSet
    │
    ├─→ steal_and_trim_queue()  // Work Stealing
    │     │
    │     └─→ 从其他线程队列窃取任务
    │
    └─→ flush()  // 刷新统计数据
          ├─→ _dcq.flush()  // 刷新脏卡队列
          ├─→ _plab_allocator->flush_and_retire_stats()
          └─→ 聚合存活统计
```

---

## 3. 内存布局

### 3.1 G1ParScanThreadState 字段布局

```cpp
// src/hotspot/share/gc/g1/g1ParScanThreadState.hpp:45-78
class G1ParScanThreadState : public CHeapObj<mtGC> {
  G1CollectedHeap* _g1h;                                    // offset 0
  RefToScanQueue*  _refs;                                   // offset 8
  DirtyCardQueue   _dcq;                                    // offset 16
  G1CardTable*     _ct;                                     // offset ~48
  G1EvacuationRootClosures* _closures;                     // offset ~56
  
  G1PLABAllocator*  _plab_allocator;                        // offset ~64
  
  AgeTable          _age_table;                             // offset ~72
  InCSetState       _dest[InCSetState::Num];                // offset ~200
  uint              _tenuring_threshold;                    // offset ~208
  G1ScanEvacuatedObjClosure  _scanner;                      // offset ~216
  
  int  _hash_seed;                                          // offset ~280
  uint _worker_id;                                          // offset ~288
  
  uint const _stack_trim_upper_threshold;                   // offset ~292
  uint const _stack_trim_lower_threshold;                   // offset ~296
  
  Tickspan _trim_ticks;                                     // offset ~304
  size_t* _surviving_young_words_base;                      // offset ~312
  size_t* _surviving_young_words;                           // offset ~320
  
  bool _old_gen_is_full;                                    // offset ~328
};
```

**内存布局图**：

```
G1ParScanThreadState 对象（~350 bytes）：
+--------------------------------+ offset 0
| _g1h                           | 8 bytes
+--------------------------------+ offset 8
| _refs                          | 8 bytes
+--------------------------------+ offset 16
| _dcq                           | DirtyCardQueue (~32 bytes)
+--------------------------------+ offset ~48
| _ct                            | 8 bytes
+--------------------------------+ offset ~56
| _closures                      | 8 bytes
+--------------------------------+ offset ~64
| _plab_allocator                | 8 bytes
+--------------------------------+ offset ~72
| _age_table                     | AgeTable (~128 bytes)
+--------------------------------+ offset ~200
| _dest[Num]                     | 8 bytes (数组)
+--------------------------------+ offset ~208
| _tenuring_threshold            | 4 bytes
+--------------------------------+ offset ~216
| _scanner                       | G1ScanEvacuatedObjClosure (~64 bytes)
+--------------------------------+ offset ~280
| _hash_seed                     | 4 bytes
+--------------------------------+ offset ~284
| _worker_id                     | 4 bytes
+--------------------------------+ offset ~288
| _stack_trim_upper_threshold    | 4 bytes
+--------------------------------+ offset ~292
| _stack_trim_lower_threshold    | 4 bytes
+--------------------------------+ offset ~296
| _trim_ticks                    | 8 bytes
+--------------------------------+ offset ~304
| _surviving_young_words_base    | 8 bytes
+--------------------------------+ offset ~312
| _surviving_young_words         | 8 bytes
+--------------------------------+ offset ~320
| _old_gen_is_full               | 1 byte
+--------------------------------+ offset ~328
```

### 3.2 关键数据结构

#### 1. RefToScanQueue（引用扫描队列）

```cpp
// 继承自 OverflowTaskQueue<StarTask>
RefToScanQueue* _refs;

// StarTask：可以是 oop* 或 narrowOop*
class StarTask {
  void* _holder;
  
  bool is_narrow() const;
  oop* get_oop_ptr() const;
  narrowOop* get_narrow_oop_ptr() const;
};
```

**队列作用**：
```
存储待处理的引用：
  - 根集扫描时：push GC Roots 引用
  - 对象复制后：push 新对象的字段引用
  - Work Stealing：其他线程窃取引用
```

#### 2. DirtyCardQueue（脏卡队列）

```cpp
DirtyCardQueue _dcq;

// 作用：延迟更新 RSet
// 写屏障 → 标记脏卡 → 入队 _dcq → GC 后期批量处理
```

#### 3. InCSetState（CSet 状态）

```cpp
enum InCSetState {
  NotInCSet = 0,    // 不在 CSet 中
  Young      = 1,    // 年轻代（Eden/Survivor）
  Old        = 2,    // 老年代
  Num        = 3     // 状态数量
};

// 目标状态映射
_dest[NotInCSet] = NotInCSet;  // 不在 CSet，无需移动
_dest[Young]     = Old;         // 年轻代对象晋升到老年代
_dest[Old]       = Old;         // 老年代对象继续留在老年代
```

---

## 4. 对象复制核心流程

### 4.1 copy_to_survivor_space() 详解

```cpp
// src/hotspot/share/gc/g1/g1ParScanThreadState.cpp:214-324
oop G1ParScanThreadState::copy_to_survivor_space(InCSetState const state,
                                                 oop const old,
                                                 markOop const old_mark) {
  // 步骤1：计算对象大小
  const size_t word_sz = old->size();
  
  // 步骤2：确定目标状态
  uint age = 0;
  InCSetState dest_state = next_state(state, old_mark, age);
  
  // 步骤3：检查老年代是否已满
  if (_old_gen_is_full && dest_state.is_old()) {
    return handle_evacuation_failure_par(old, old_mark);
  }
  
  // 步骤4：尝试 PLAB 分配
  HeapWord* obj_ptr = _plab_allocator->plab_allocate(dest_state, word_sz);
  
  // 步骤5：PLAB 分配失败，尝试其他分配方式
  if (obj_ptr == NULL) {
    bool plab_refill_failed = false;
    obj_ptr = _plab_allocator->allocate_direct_or_new_plab(dest_state, word_sz, &plab_refill_failed);
    
    if (obj_ptr == NULL) {
      // 尝试分配到下一个区域（Young → Old）
      obj_ptr = allocate_in_next_plab(state, &dest_state, word_sz, plab_refill_failed);
      
      if (obj_ptr == NULL) {
        // 完全失败，处理 Evacuation Failure
        return handle_evacuation_failure_par(old, old_mark);
      }
    }
  }
  
  // 步骤6：预取优化
  Prefetch::write(obj_ptr, PrefetchCopyIntervalInBytes);
  
  // 步骤7：CAS 安装转发指针
  const oop obj = oop(obj_ptr);
  const oop forward_ptr = old->forward_to_atomic(obj, memory_order_relaxed);
  
  if (forward_ptr == NULL) {
    // 步骤8：CAS 成功，复制对象
    Copy::aligned_disjoint_words((HeapWord*) old, obj_ptr, word_sz);
    
    // 步骤9：更新年龄
    if (dest_state.is_young()) {
      if (age < markOopDesc::max_age) {
        age++;
      }
      obj->set_mark_raw(old_mark->set_age(age));
      _age_table.add(age, word_sz);
    } else {
      obj->set_mark_raw(old_mark);
    }
    
    // 步骤10：统计存活对象
    _surviving_young_words[young_index] += word_sz;
    
    // 步骤11：处理大数组（分块处理）
    if (obj->is_objArray() && arrayOop(obj)->length() >= ParGCArrayScanChunk) {
      arrayOop(obj)->set_length(0);
      oop* old_p = set_partial_array_mask(old);
      do_oop_partial_array(old_p);
    } else {
      // 步骤12：扫描新对象的引用字段
      HeapRegion* const to_region = _g1h->heap_region_containing(obj_ptr);
      _scanner.set_region(to_region);
      obj->oop_iterate_backwards(&_scanner);
    }
    
    return obj;
  } else {
    // CAS 失败，其他线程已经复制
    _plab_allocator->undo_allocation(dest_state, obj_ptr, word_sz);
    return forward_ptr;
  }
}
```

### 4.2 转发指针机制

**Mark Word 复用**：

```
对象 Mark Word（64 位）：
+----------------------------------+
| 锁状态 | GC 年龄 | 偏向锁 | 分代年龄 | ... |
+----------------------------------+

复制前：
  old->mark = 0x0000000000000001 (正常对象)
  
复制时（CAS）：
  old->mark = 0x00007f0000100000 | 0x2  (转发指针 + 标记位)
  obj->mark = old_mark            (复制 Mark Word)
  
复制后：
  其他线程看到 old->mark 被标记：
    if (old->mark->is_marked()) {
      obj = old->mark->decode_pointer();  // 直接使用转发地址
    }
```

**CAS 竞争处理**：

```
线程 A 和 B 同时复制同一个对象：

线程 A：
  forward_ptr = old->forward_to_atomic(obj_A)
  → CAS 成功，forward_ptr = NULL
  → 复制对象，返回 obj_A

线程 B：
  forward_ptr = old->forward_to_atomic(obj_B)
  → CAS 失败，forward_ptr = obj_A
  → 撤销分配，返回 obj_A

结果：只有一个线程成功复制，其他线程使用已复制的对象
```

### 4.3 年龄计算与晋升

```cpp
// src/hotspot/share/gc/g1/g1ParScanThreadState.cpp:189-198
InCSetState G1ParScanThreadState::next_state(InCSetState const state, markOop const m, uint& age) {
  if (state.is_young()) {
    // 读取对象年龄
    age = !m->has_displaced_mark_helper() ? m->age()
                                          : m->displaced_mark_helper()->age();
    
    // 判断是否达到晋升阈值
    if (age < _tenuring_threshold) {
      return state;  // 保留在 Survivor
    }
  }
  return dest(state);  // 晋升到 Old
}
```

**晋升决策**：

```
_tenuring_threshold = 15（默认）

示例：
  对象年龄 age = 10
  age < _tenuring_threshold → 保留在 Survivor
  
  对象年龄 age = 15
  age >= _tenuring_threshold → 晋升到 Old

动态调整：
  - G1 根据 Survivor 空间使用情况动态调整
  - Survivor 满时，降低 _tenuring_threshold
  - 避免过早晋升和 Survivor 溢出
```

---

## 5. PLAB 分配机制

### 5.1 PLAB 概念

```
PLAB (Promotion Local Allocation Buffer)：
  - 每个 GC 线程独立的分配缓冲区
  - 无锁 bump-the-pointer 分配
  - 减少 CAS 竞争

内存布局：
  Survivor PLAB:  ~1-4 KB
  Old PLAB:       ~1-4 KB
  
分配流程：
  Fast Path: PLAB 内分配（~5ns）
    ↓ PLAB 满
  Slow Path: 申请新 PLAB（~100ns-1μs）
    ↓ PLAB 申请失败
  Direct Allocate: 直接从 Region 分配（~2-10μs）
```

### 5.2 PLAB 分配实现

```cpp
// 步骤1：PLAB 快速路径
HeapWord* obj_ptr = _plab_allocator->plab_allocate(dest_state, word_sz);

// plab_allocate() 实现：
HeapWord* G1PLABAllocator::plab_allocate(InCSetState dest, size_t word_sz) {
  PLAB* buffer = alloc_buffer(dest);
  return buffer->allocate(word_sz);  // bump-the-pointer
}

// PLAB::allocate()
HeapWord* PLAB::allocate(size_t size) {
  if (_top + size <= _end) {
    HeapWord* result = _top;
    _top += size;
    return result;  // ~5ns
  }
  return NULL;
}
```

```cpp
// 步骤2：PLAB 慢路径（申请新 PLAB）
if (obj_ptr == NULL) {
  obj_ptr = _plab_allocator->allocate_direct_or_new_plab(dest_state, word_sz, &plab_refill_failed);
}

// 实现：
HeapWord* G1PLABAllocator::allocate_direct_or_new_plab(InCSetState dest,
                                                       size_t word_sz,
                                                       bool* plab_refill_failed) {
  // 尝试申请新 PLAB
  PLAB* buffer = alloc_buffer(dest);
  if (buffer->plab_size() >= word_sz) {
    // PLAB 大小足够，尝试填充
    HeapWord* buf = _g1_alloc->par_allocate_during_gc(dest, buffer->plab_size());
    if (buf != NULL) {
      buffer->retire();  // 回收旧 PLAB
      buffer->set_buf(buf, buffer->plab_size());
      return buffer->allocate(word_sz);  // 从新 PLAB 分配
    }
  }
  
  // PLAB 申请失败，直接分配
  *plab_refill_failed = true;
  return _g1_alloc->par_allocate_during_gc(dest, word_sz);
}
```

### 5.3 PLAB 浪费处理

```cpp
// 回收 PLAB 时的浪费统计
void PLAB::retire() {
  size_t waste = _end - _top;  // 未使用的空间
  _wasted += waste;
  _top = _end = NULL;
}

// 浪费过多时的优化：
void G1PLABAllocator::waste(size_t& wasted, size_t& undo_wasted) {
  wasted = 0;
  undo_wasted = 0;
  
  for (int i = 0; i < InCSetState::Num; i++) {
    PLAB* buf = _alloc_buffers[i];
    wasted += buf->wasted();
    undo_wasted += buf->undo_wasted();
  }
}

// 如果浪费 > 10%，减小 PLAB 大小
// 如果浪费 < 5%，增大 PLAB 大小
```

---

## 6. 引用更新与 RSet 维护

### 6.1 do_oop_evac() 核心流程

```cpp
// src/hotspot/share/gc/g1/g1ParScanThreadState.inline.hpp:33-63
template <class T> void G1ParScanThreadState::do_oop_evac(T* p) {
  // 步骤1：加载引用
  oop obj = RawAccess<IS_NOT_NULL>::oop_load(p);
  
  // 步骤2：检查对象是否在 CSet
  const InCSetState in_cset_state = _g1h->in_cset_state(obj);
  
  if (in_cset_state.is_in_cset()) {
    // 步骤3：对象在 CSet，需要处理
    markOop m = obj->mark_raw();
    
    if (m->is_marked()) {
      // 已经被复制，直接使用转发地址
      obj = (oop) m->decode_pointer();
    } else {
      // 未复制，复制对象
      obj = copy_to_survivor_space(in_cset_state, obj, m);
    }
    
    // 步骤4：更新引用
    RawAccess<IS_NOT_NULL>::oop_store(p, obj);
    
  } else if (in_cset_state.is_humongous()) {
    // 大对象处理
    _g1h->set_humongous_is_live(obj);
  }
  // else: 对象不在 CSet，无需处理
  
  // 步骤5：更新 RSet
  if (!HeapRegion::is_in_same_region(p, obj)) {
    HeapRegion* from = _g1h->heap_region_containing(p);
    update_rs(from, p, obj);
  }
}
```

### 6.2 update_rs() RSet 更新

```cpp
// src/hotspot/share/gc/g1/g1ParScanThreadState.hpp:108-120
template <class T> void update_rs(HeapRegion* from, T* p, oop o) {
  assert(!HeapRegion::is_in_same_region(p, o), "cross-region references");
  
  // 只处理非年轻代来源且目标 Region 追踪 RSet
  if (!from->is_young() && _g1h->heap_region_containing((HeapWord*)o)->rem_set()->is_tracked()) {
    // 计算卡索引
    size_t card_index = ct()->index_for(p);
    
    // 延迟标记脏卡（去重）
    if (ct()->mark_card_deferred(card_index)) {
      // 入队脏卡
      dirty_card_queue().enqueue((jbyte*)ct()->byte_for_index(card_index));
    }
  }
}
```

**mark_card_deferred() 去重机制**：

```cpp
// 卡状态：
//  clean_card    = 0xFF (-1)
//  dirty_card    = 0x00 (0)
//  claimed       = 0x01 (1)
//  deferred      = 0x02 (2)

bool mark_card_deferred(size_t card_index) {
  jbyte val = _byte_map[card_index];
  
  // 已经是 dirty 或 deferred，不需要再入队
  if (val == dirty_card || val == deferred) {
    return false;
  }
  
  // CAS 标记为 deferred
  jbyte new_val = deferred;
  jbyte old_val = Atomic::cmpxchg(new_val, &_byte_map[card_index], val);
  
  return old_val == val;  // 成功返回 true
}
```

**为什么延迟更新 RSet？**

```
直接更新 RSet：
  每次引用更新 → 立即修改 RSet
  问题：频繁锁竞争、性能差

延迟更新 RSet：
  引用更新 → 标记脏卡 → 入队
  GC 后期 → 批量处理脏卡 → 更新 RSet
  优势：
    1. 去重（同一张卡多次修改只处理一次）
    2. 批量处理（缓存友好）
    3. 减少锁竞争
```

---

## 7. Work Stealing 机制

### 7.1 trim_queue() 队列处理

```cpp
// src/hotspot/share/gc/g1/g1ParScanThreadState.cpp:142-148
void G1ParScanThreadState::trim_queue() {
  StarTask ref;
  do {
    // 完全清空队列
    trim_queue_to_threshold(0);
  } while (!_refs->is_empty());
}

void trim_queue_to_threshold(uint threshold) {
  StarTask ref;
  while (_refs->size() > threshold) {
    if (_refs->pop_local(ref)) {
      dispatch_reference(ref);  // 处理引用
    }
  }
}
```

### 7.2 steal_and_trim_queue() Work Stealing

```cpp
// src/hotspot/share/gc/g1/g1ParScanThreadState.inline.hpp:141-150
void G1ParScanThreadState::steal_and_trim_queue(RefToScanQueueSet *task_queues) {
  StarTask stolen_task;
  
  // 从其他线程队列窃取任务
  while (task_queues->steal(_worker_id, &_hash_seed, stolen_task)) {
    assert(verify_task(stolen_task), "sanity");
    dispatch_reference(stolen_task);  // 处理窃取的引用
    
    // 窃取后可能产生新任务，清空本地队列
    trim_queue();
  }
}
```

**Work Stealing 流程**：

```
初始状态：
  W0 队列: [Task1, Task2, Task3]
  W1 队列: [Task4, Task5, Task6]
  W2 队列: [Task7, Task8, Task9]
  W3 队列: []

时刻 T1：
  W0: pop_local() → Task1
  W1: pop_local() → Task4
  W2: pop_local() → Task7
  W3: steal() → Task2（从 W0 窃取）

时刻 T2：
  W0: pop_local() → Task3
  W1: pop_local() → Task5
  W2: pop_local() → Task8
  W3: steal() → Task6（从 W1 窃取）

时刻 T3：
  W0: 队列空，steal() → Task9（从 W2 窃取）
  W1: 队列空，steal() → 失败
  W2: 队列空，steal() → 失败
  W3: 处理 Task6

最终：所有任务被处理完毕
```

**steal() 算法**：

```cpp
// Best-of-2 策略：
bool steal(uint worker_id, int* hash_seed, StarTask& task) {
  // 随机选择两个队列
  uint queue1 = random_queue(hash_seed);
  uint queue2 = random_queue(hash_seed);
  
  // 选择任务更多的队列
  RefToScanQueue* q1 = _queues[queue1];
  RefToScanQueue* q2 = _queues[queue2];
  
  RefToScanQueue* target = (q1->size() > q2->size()) ? q1 : q2;
  
  // 尝试窃取
  return target->pop_global(task);
}
```

---

## 8. 关键场景分析

### 8.1 场景1：小对象复制

```
对象大小：32 bytes
来源：Eden Region
目标：Survivor Region

流程：
1. copy_to_survivor_space(state=Young, obj, mark)
2. word_sz = 32 / 8 = 4 words
3. dest_state = next_state(Young, mark, age)
   - age = mark->age() = 5
   - age < _tenuring_threshold (15)
   - dest_state = Young (保留在 Survivor)
4. obj_ptr = _plab_allocator->plab_allocate(Young, 4)
   - PLAB 内 bump-the-pointer
   - ~5ns
5. Prefetch::write(obj_ptr, 256)
6. forward_ptr = old->forward_to_atomic(obj)
   - CAS 成功
7. Copy::aligned_disjoint_words(old, obj_ptr, 4)
   - 复制 32 字节
8. obj->set_mark_raw(old_mark->set_age(6))
   - 年龄 +1
9. _surviving_young_words[young_index] += 4
10. obj->oop_iterate_backwards(&_scanner)
    - 扫描对象字段
    - push_on_queue() 入队引用

总耗时：~50-100ns
```

### 8.2 场景2：大对象晋升

```
对象大小：1 MB
来源：Survivor Region（age=15）
目标：Old Region

流程：
1. copy_to_survivor_space(state=Young, obj, mark)
2. word_sz = 1 MB / 8 = 131072 words
3. dest_state = next_state(Young, mark, age)
   - age = 15
   - age >= _tenuring_threshold (15)
   - dest_state = Old (晋升)
4. obj_ptr = _plab_allocator->plab_allocate(Old, 131072)
   - PLAB 太小（~4KB），失败
5. obj_ptr = allocate_direct_or_new_plab(Old, 131072, &failed)
   - 直接从 Old Region 分配
   - ~10μs
6. forward_ptr = old->forward_to_atomic(obj)
   - CAS 成功
7. Copy::aligned_disjoint_words(old, obj_ptr, 131072)
   - 复制 1 MB
   - ~1ms
8. obj->set_mark_raw(old_mark)
   - 老年代对象年龄不重要
9. obj->oop_iterate_backwards(&_scanner)
   - 扫描引用字段

总耗时：~1-2ms
```

### 8.3 场景3：大数组分块处理

```
数组大小：10000 个元素
元素类型：Object[]
数组大小：~80 KB

问题：
  扫描 10000 个引用 → 耗时过长
  阻塞其他任务处理

解决：分块处理
1. 检测大数组：
   if (obj->is_objArray() && arrayOop(obj)->length() >= ParGCArrayScanChunk) {
     // ParGCArrayScanChunk = 512（默认）
   }

2. 分块标记：
   arrayOop(obj)->set_length(0);  // to-space 对象 length=0
   oop* old_p = set_partial_array_mask(old);
   do_oop_partial_array(old_p);

3. 分块处理：
   do_oop_partial_array(oop* p):
     - from_obj = clear_partial_array_mask(p)
     - length = from_obj_array->length()  // from-space 的真实长度
     - next_index = to_obj_array->length()  // to-space 的 length 用于记录进度
     - 处理 [next_index, next_index + ParGCArrayScanChunk)
     - 更新 to_obj_array->set_length(next_index + ParGCArrayScanChunk)
     - 如果还有剩余，push_on_queue(p)

示例：
  数组长度 = 10000
  ParGCArrayScanChunk = 512
  
  第1次：处理 [0, 512)，push [512, 10000)
  第2次：处理 [512, 1024)，push [1024, 10000)
  ...
  第20次：处理 [9728, 10000)，完成

优势：
  - 每次处理 512 个引用，耗时可控
  - 允许其他线程窃取任务
  - 提高并行度
```

### 8.4 场景4：Evacuation Failure

```
触发条件：
  - 老年代空间不足
  - 无法分配新 PLAB
  - 无法直接分配

处理流程：
1. allocate_in_next_plab() 返回 NULL
2. handle_evacuation_failure_par(old, old_mark)
3. forward_ptr = old->forward_to_atomic(old)
   - 尝试转发到自身
4. if (forward_ptr == NULL) {
     // 成功自转发
     old->set_mark(old_mark | marked_bit);
     
     // 标记 Region 为 evacuation_failed
     r->set_evacuation_failed(true);
     
     // 扫描对象引用（对象保留在原位置）
     old->oop_iterate_backwards(&_scanner);
   } else {
     // 其他线程已经处理
     return forward_ptr;
   }

结果：
  - 对象保留在 CSet Region
  - CSet Region 不会被释放
  - 下次 GC 再尝试回收

影响：
  - 增加 GC 暂停时间
  - 降低吞吐量
  - 触发 Full GC 或扩容
```

---

## 9. GDB 验证脚本

### 9.1 验证对象复制流程

```gdb
# gdb_script: verify_object_copy.gdb

break G1ParScanThreadState::copy_to_survivor_space
commands
  printf "\n=== copy_to_survivor_space() ===\n"
  printf "old:     %p\n", $rsi
  printf "mark:    %p\n", $rdx
  
  # 单步执行
  next
  
  # 查看目标状态
  printf "dest_state: %d\n", $eax
  
  continue
end

run
```

### 9.2 观察 PLAB 分配

```gdb
# gdb_script: observe_plab_allocate.gdb

break PLAB::allocate
commands
  printf "\n=== PLAB::allocate() ===\n"
  printf "size:    %lu words\n", $rdi
  
  # 查看 PLAB 状态
  set $plab = (PLAB*)this
  printf "_top:    %p\n", $plab->_top
  printf "_end:    %p\n", $plab->_end
  printf "remain:  %lu words\n", $plab->_end - $plab->_top
  
  # 单步执行
  next
  
  if $rax != 0
    printf "allocated: %p\n", $rax
  else
    printf "failed\n"
  end
  
  continue
end

run
```

### 9.3 观察转发指针安装

```gdb
# gdb_script: observe_forward_ptr.gdb

break oopDesc::forward_to_atomic
commands
  printf "\n=== forward_to_atomic() ===\n"
  
  # 查看参数
  printf "old:  %p\n", $rdi
  printf "new:  %p\n", $rsi
  
  # 查看旧 mark
  set $obj = (oop)$rdi
  printf "old mark: %p\n", $obj->_mark
  
  # 单步执行 CAS
  next
  
  # 查看结果
  printf "forward_ptr: %p\n", $rax
  if $rax == 0
    printf "CAS success\n"
  else
    printf "CAS failed, already forwarded to: %p\n", $rax
  end
  
  continue
end

run
```

### 9.4 统计存活对象

```gdb
# gdb_script: stat_surviving_objects.gdb

define stat_surviving
  set $heap = (G1CollectedHeap*)Universe::_collectedHeap
  set $pss_set = $heap->_pss
  
  printf "\n=== 存活对象统计 ===\n"
  
  set $total = 0
  set $i = 0
  set $n_workers = $pss_set->_n_workers
  
  while $i < $n_workers
    set $pss = $pss_set->_states[$i]
    if $pss != 0
      set $j = 0
      while $j < $pss_set->_young_cset_length
        set $words = $pss->_surviving_young_words[$j]
        set $total = $total + $words
        set $j = $j + 1
      end
    end
    set $i = $i + 1
  end
  
  printf "总存活字节数: %lu = %.2f MB\n", $total * 8, (float)($total * 8) / 1024 / 1024
end

# 在 GC 后调用
# (gdb) stat_surviving
```

---

## 10. 面试级 Q&A

### Q1: G1 如何处理对象复制时的并发竞争？

**A**: 通过 CAS 转发指针机制。

**核心代码**：
```cpp
oop forward_ptr = old->forward_to_atomic(obj, memory_order_relaxed);
if (forward_ptr == NULL) {
  // 成功：复制对象
  Copy::aligned_disjoint_words(old, obj_ptr, word_sz);
  return obj;
} else {
  // 失败：其他线程已复制
  _plab_allocator->undo_allocation(dest_state, obj_ptr, word_sz);
  return forward_ptr;
}
```

**竞争场景**：
```
线程 A 和 B 同时复制对象 X：

初始：X->mark = 0x0001 (正常)

线程 A：
  CAS(&X->mark, obj_A, 0x0001)
  → 成功，X->mark = obj_A | marked_bit
  → 复制对象
  → 返回 obj_A

线程 B（同时）：
  CAS(&X->mark, obj_B, 0x0001)
  → 失败，X->mark 已被 A 改为 obj_A | marked_bit
  → 撤销分配
  → 返回 obj_A

结果：只有一个副本，其他线程使用已复制的对象
```

**为什么用 CAS 而不是锁？**

```
锁的缺点：
  - 每个对象加锁开销大
  - 锁竞争严重（热门对象）
  - 延迟高

CAS 的优势：
  - 无锁算法
  - 失败重试开销小
  - 缓存友好（单个原子操作）
  - 适合低竞争场景（大部分对象只被一个线程处理）
```

---

### Q2: 为什么需要 PLAB？直接从 Region 分配不行吗？

**A**: PLAB 消除 CAS 竞争，提升分配性能。

**直接从 Region 分配的问题**：
```
Region 分配：
  CAS(&region->_top, region->_top + size, old_top)
  
问题：
  - 每个 GC 线程都竞争同一个 _top
  - CAS 成功率低（多个线程同时尝试）
  - 缓存行争用（false sharing）

性能：
  单次分配：~100-500ns（CAS 重试）
  1000 个对象：~0.5-1ms
```

**PLAB 的优势**：
```
PLAB 分配：
  if (_top + size <= _end) {
    result = _top;
    _top += size;
    return result;
  }
  
优势：
  - 无锁 bump-the-pointer
  - 每个线程独立缓冲区
  - 无竞争

性能：
  单次分配：~5ns
  1000 个对象：~0.005ms
  提升：~100 倍
```

**PLAB 的代价**：
```
浪费：
  PLAB 末尾未使用空间：平均 50% PLAB 大小
  例如：4KB PLAB，浪费 ~2KB
  
回收：
  每个 GC 线程维护 2 个 PLAB（Survivor + Old）
  总浪费：n_workers × 2 × PLAB_size / 2
  
优化：
  - 自适应 PLAB 大小
  - 浪费 > 10% 时减小 PLAB
  - 浪费 < 5% 时增大 PLAB
```

---

### Q3: G1 如何处理大数组？

**A**: 分块处理，避免阻塞。

**问题**：
```
大数组：Object[10000]
扫描时间：~100μs

问题：
  - 阻塞当前线程
  - 其他线程无法窃取任务
  - 负载不均衡
```

**分块处理**：
```
ParGCArrayScanChunk = 512

处理流程：
  1. 检测大数组：
     length >= ParGCArrayScanChunk

  2. 分块标记：
     to_obj->set_length(0)  // length 字段复用为进度
     push_on_queue(mask(from_obj))

  3. 分块扫描：
     while (队列不为空) {
       task = pop()
       if (task 是部分数组) {
         start = to_obj->length()  // 当前进度
         end = min(start + 512, length)
         
         // 扫描 [start, end)
         to_obj->oop_iterate_range(&_scanner, start, end)
         
         // 更新进度
         if (end < length) {
           to_obj->set_length(end)
           push_on_queue(mask(from_obj))  // 推送剩余部分
         }
       }
     }

优势：
  - 每块 512 元素，~5μs
  - 允许 Work Stealing
  - 提高并行度
```

---

### Q4: Evacuation Failure 会发生什么？

**A**: 对象自转发，保留在原 Region。

**触发条件**：
```
1. 老年代空间不足
2. 无法分配新 PLAB
3. 直接分配失败
```

**处理流程**：
```cpp
oop handle_evacuation_failure_par(oop old, markOop m) {
  // 尝试自转发
  oop forward_ptr = old->forward_to_atomic(old);
  
  if (forward_ptr == NULL) {
    // 自转发成功
    HeapRegion* r = heap_region_containing(old);
    r->set_evacuation_failed(true);  // 标记 Region
    
    old->oop_iterate_backwards(&_scanner);  // 扫描引用
    
    return old;
  } else {
    // 其他线程已处理
    return forward_ptr;
  }
}
```

**后果**：
```
1. Region 保留：
   - CSet Region 不被释放
   - 下次 GC 再次尝试回收
   
2. 性能影响：
   - 暂停时间增加
   - 吞吐量降低
   - 可能触发 Full GC
   
3. 应对措施：
   - 扩容堆大小
   - 调整 IHOP
   - 增加 GC 线程数
```

---

### Q5: 如何优化 Evacuation 性能？

**A**: 多维度优化。

**1. PLAB 优化**：
```
调整 PLAB 大小：
  -XX:G1PLABSize=4K        # PLAB 大小
  -XX:G1PLABWaste=10       # 浪费阈值
  
自适应调整：
  - 根据浪费率自动调整
  - 避免过小（频繁 refill）
  - 避免过大（浪费多）
```

**2. GC 线程数优化**：
```
增加线程数：
  -XX:ParallelGCThreads=8
  
权衡：
  - 线程多：并行度高，但竞争增加
  - 线程少：竞争少，但并行度低
```

**3. Work Stealing 优化**：
```
调整队列大小：
  -XX:GCDrainStackTargetSize=64
  
影响：
  - 队列大：Work Stealing 机会多
  - 队列小：本地处理快
```

**4. 大对象优化**：
```
避免大数组：
  - 使用集合代替大数组
  - 分段处理大数组

调整分块大小：
  -XX:ParGCArrayScanChunk=512
```

**5. 内存优化**：
```
避免 Evacuation Failure：
  - 增大堆大小
  - 调整 IHOP
  - 减少对象晋升
```

---

### Q6: G1ParScanThreadState 为什么是线程本地的？

**A**: 消除锁竞争，提升并行性能。

**线程本地状态**：
```
每个 GC 线程独立的：
  - PLAB：分配缓冲区
  - RefToScanQueue：任务队列
  - DirtyCardQueue：脏卡队列
  - AgeTable：年龄表
  - 统计数据：存活字数
```

**消除的竞争**：
```
1. PLAB 分配：
   - 无需 CAS 竞争 Region->_top
   - 无锁 bump-the-pointer
   
2. 任务队列：
   - push_local()：无锁
   - pop_local()：无锁
   - 只有 steal() 才竞争
   
3. 脏卡队列：
   - 线程本地队列
   - flush 时批量提交
   
4. 统计数据：
   - 本地统计
   - flush 时聚合
```

**性能提升**：
```
无竞争操作：
  - PLAB 分配：~5ns
  - push_local()：~10ns
  - pop_local()：~10ns

有竞争操作：
  - CAS 操作：~50-100ns
  - 锁操作：~100-500ns

提升：~10-100 倍
```

---

## 总结

**G1ParScanThreadState 的核心价值**：

1. **线程本地状态**：消除锁竞争，提升并行性能
2. **PLAB 分配**：无锁 bump-the-pointer，~100 倍性能提升
3. **CAS 转发指针**：并发安全的对象复制
4. **Work Stealing**：负载均衡，充分利用多核
5. **延迟更新 RSet**：去重优化，减少竞争

**关键数据**：
- PLAB 大小：~1-4 KB
- PLAB 分配耗时：~5ns
- CAS 转发耗时：~50ns
- 大数组分块：512 元素/块

**下一步学习**：
- G1PLABAllocator：PLAB 管理的详细实现
- G1ScanEvacuatedObjClosure：引用扫描闭包
- G1EvacuationRootClosures：根集闭包体系
