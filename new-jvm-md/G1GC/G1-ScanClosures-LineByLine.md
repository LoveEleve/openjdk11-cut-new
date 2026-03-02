# G1ScanEvacuatedObjClosure 与闭包体系逐行源码分析

> **核心目标**：深入理解 G1 的引用扫描闭包体系、对象字段遍历、跨代引用处理和 RSet 更新机制。

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

`G1ScanEvacuatedObjClosure` 的本质是**Evacuation 阶段的引用字段扫描器**：对每个新复制的对象，遍历其所有引用字段；对于指向 CSet 内对象的引用，将目标对象加入 `RefToScanQueue`（待复制队列）；对于跨 Region 的引用，标记脏卡（更新 RSet）。

### 0.2 闭包体系

| 闭包 | 用途 | `do_oop()` 行为 |
|------|------|----------------|
| `G1ScanEvacuatedObjClosure` | Evacuation 阶段扫描新复制对象 | 复制引用对象 + 更新 RSet |
| `G1CopyingClosure` | Root 扫描阶段 | 复制 Root 直接可达对象 |
| `G1MarkingClosure` | 并发标记阶段 | 标记对象（不复制） |
| `G1UpdateRSOrPushRefOopClosure` | RSet 更新 | 更新 RSet 或入队 |

### 0.3 `do_oop()` 核心逻辑

```cpp
void do_oop(oop* p) {
    oop obj = *p;
    if (obj == NULL) return;
    if (in_cset(obj)) {
        // 目标对象在 CSet 中，需要复制
        oop new_obj = _par_scan_state->copy_to_survivor_space(obj);
        *p = new_obj;  // 更新引用
        if (cross_region(p, new_obj)) {
            // 跨 Region 引用，标记脏卡
            mark_dirty_card(p);
        }
    }
}
```

### 0.4 为什么这样设计？

- **为什么闭包模式？** 将"如何处理引用"与"如何遍历对象字段"解耦；`oop_iterate()` 负责遍历，闭包负责处理；不同 GC 阶段可以复用同一套遍历框架，只需提供不同的闭包
- **为什么需要更新 RSet？** 新复制的对象在 Survivor/Old Region，其引用字段可能指向其他 Region；这些新的跨 Region 引用需要被记录到 RSet 中

---

## 目录

1. [问题引入：为什么需要闭包体系？](#1-问题引入为什么需要闭包体系)
2. [整体架构](#2-整体架构)
3. [内存布局](#3-内存布局)
4. [G1ScanEvacuatedObjClosure 核心实现](#4-g1scanevacuatedobjclosure-核心实现)
5. [G1ParCopyClosure 根集处理](#5-g1parcopyclosure-根集处理)
6. [闭包选择与创建机制](#6-闭包选择与创建机制)
7. [关键场景分析](#7-关键场景分析)
8. [GDB 验证脚本](#8-gdb-验证脚本)
9. [面试级 Q&A](#9-面试级-qa)

---

## 1. 问题引入：为什么需要闭包体系？

### 问题场景

**对象引用追踪的挑战**：

```java
// Young GC 前：
Eden Region 0:
  +----------------+
  | Object A       |
  | - field1 → B   |  // 引用对象 B
  | - field2 → C   |  // 引用对象 C
  +----------------+

// 问题：
// 1. 如何遍历对象的所有引用字段？
// 2. 如何判断对象是否在 CSet？
// 3. 如何处理跨 Region 引用？
// 4. 如何更新 RSet？
```

**不同场景的不同需求**：

```
场景1：Evacuation（对象复制后）
  - 扫描新对象的字段
  - 如果引用对象在 CSet → 入队处理
  - 如果引用对象不在 CSet → 更新 RSet

场景2：根集扫描
  - 扫描 GC Roots
  - 如果引用对象在 CSet → 复制对象
  - 如果引用对象不在 CSet → 标记（Initial Mark）

场景3：Update RS（更新 RSet）
  - 扫描脏卡
  - 处理跨 Region 引用
  - 更新 RSet

场景4：Concurrent Mark（并发标记）
  - 扫描对象字段
  - 标记存活对象
  - 不复制对象
```

### G1 的解决方案

**闭包体系设计**：

```
1. 统一接口：
   - do_oop(oop* p)：处理宽指针
   - do_oop(narrowOop* p)：处理压缩指针
   - 支持模板泛型

2. 层次化继承：
   BasicOopIterateClosure（基础）
     ↓
   G1ScanClosureBase（G1 公共基类）
     ↓
   ├─→ G1ScanEvacuatedObjClosure（Evacuation）
   ├─→ G1ScanObjsDuringScanRSClosure（Scan RS）
   ├─→ G1ScanObjsDuringUpdateRSClosure（Update RS）
   └─→ G1ConcurrentRefineOopClosure（Concurrent Refine）

3. 特化闭包：
   G1ParCopyHelper（根集处理基类）
     ↓
   G1ParCopyClosure<barrier, mark>
     - G1BarrierNone：无屏障
     - G1BarrierCLD：CLD 屏障
     - G1MarkNone：不标记
     - G1MarkFromRoot：从根标记
     - G1MarkPromotedFromRoot：晋升根标记
```

---

## 2. 整体架构

### 2.1 闭包继承关系图

```
┌─────────────────────────────────────────────────────────────┐
│              BasicOopIterateClosure（基础接口）              │
│  + do_oop(oop* p)                                           │
│  + do_oop(narrowOop* p)                                     │
│  + reference_iteration_mode()                               │
└─────────────────────────────────────────────────────────────┘
                           ↑ 继承
                           │
┌─────────────────────────────────────────────────────────────┐
│                    G1ScanClosureBase                        │
│  # _g1h: G1CollectedHeap*                                  │
│  # _par_scan_state: G1ParScanThreadState*                  │
│  # _from: HeapRegion*                                      │
│                                                             │
│  # prefetch_and_push(p, obj)                               │
│  # handle_non_cset_obj_common(state, p, obj)               │
│  + set_region(from)                                        │
│  + trim_queue_partially()                                  │
└─────────────────────────────────────────────────────────────┘
                           ↑ 继承
        ┌──────────────────┼──────────────────┐
        │                  │                  │
┌───────────────┐  ┌────────────────┐  ┌──────────────────┐
│ G1Scan        │  │ G1ScanObjs     │  │ G1ScanObjs       │
│ Evacuated     │  │ DuringScanRS   │  │ DuringUpdateRS   │
│ ObjClosure    │  │ Closure        │  │ Closure          │
├───────────────┤  ├────────────────┤  ├──────────────────┤
│ 用于 Evacuation│  │ 用于 Scan RS   │  │ 用于 Update RS   │
│ 扫描复制后对象 │  │ 扫描记忆集     │  │ 更新 RSet        │
└───────────────┘  └────────────────┘  └──────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                     OopClosure（基础接口）                   │
└─────────────────────────────────────────────────────────────┘
                           ↑ 继承
                           │
┌─────────────────────────────────────────────────────────────┐
│                    G1ParCopyHelper                          │
│  # _g1h: G1CollectedHeap*                                  │
│  # _par_scan_state: G1ParScanThreadState*                  │
│  # _worker_id: uint                                        │
│  # _scanned_cld: ClassLoaderData*                          │
│  # _cm: G1ConcurrentMark*                                  │
│                                                             │
│  # mark_object(obj)                                        │
│  # mark_forwarded_object(from_obj, to_obj)                 │
│  # do_cld_barrier(new_obj)                                 │
└─────────────────────────────────────────────────────────────┘
                           ↑ 继承
                           │
┌─────────────────────────────────────────────────────────────┐
│         G1ParCopyClosure<barrier, do_mark_object>           │
│                                                             │
│  barrier: G1BarrierNone / G1BarrierCLD                     │
│  do_mark_object: G1MarkNone / G1MarkFromRoot /             │
│                  G1MarkPromotedFromRoot                    │
│                                                             │
│  用于根集扫描：                                             │
│  - 处理 GC Roots 引用                                      │
│  - 复制对象（如果在 CSet）                                  │
│  - 标记对象（Initial Mark）                                │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 使用场景映射

```
┌─────────────────────────────────────────────────────────────┐
│                     GC 阶段                                 │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Young GC / Mixed GC：                                      │
│    ├─→ 根集扫描                                            │
│    │     └─→ G1ParCopyClosure<G1BarrierNone, G1MarkNone>   │
│    │                                                       │
│    ├─→ Evacuation（对象复制后扫描）                        │
│    │     └─→ G1ScanEvacuatedObjClosure                     │
│    │                                                       │
│    ├─→ Scan RS（扫描记忆集）                               │
│    │     └─→ G1ScanObjsDuringScanRSClosure                 │
│    │                                                       │
│    └─→ Update RS（更新 RSet）                              │
│          └─→ G1ScanObjsDuringUpdateRSClosure               │
│                                                             │
│  Initial Mark：                                             │
│    ├─→ 强根集扫描                                          │
│    │     └─→ G1ParCopyClosure<G1BarrierNone,               │
│    │                           G1MarkFromRoot>             │
│    │                                                       │
│    └─→ 弱根集扫描                                          │
│          └─→ G1ParCopyClosure<G1BarrierNone,               │
│                                G1MarkPromotedFromRoot>     │
│                                                             │
│  Concurrent Refine：                                        │
│    └─→ G1ConcurrentRefineOopClosure                        │
│                                                             │
│  Concurrent Mark：                                          │
│    └─→ G1CMOopClosure                                      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. 内存布局

### 3.1 G1ScanClosureBase 字段布局

```cpp
// src/hotspot/share/gc/g1/g1OopClosures.hpp:42-62
class G1ScanClosureBase : public BasicOopIterateClosure {
protected:
  G1CollectedHeap* _g1h;               // offset 0（继承自 vtable）
  G1ParScanThreadState* _par_scan_state; // offset 8
  HeapRegion* _from;                   // offset 16
};
```

**内存布局图**：

```
G1ScanClosureBase 对象（~32 bytes）：
+--------------------------------+ offset 0
| vtable                         | 8 bytes（虚函数表指针）
+--------------------------------+ offset 8
| _g1h                           | 8 bytes
+--------------------------------+ offset 16
| _par_scan_state                | 8 bytes
+--------------------------------+ offset 24
| _from                          | 8 bytes
+--------------------------------+ offset 32
```

### 3.2 G1ScanEvacuatedObjClosure 字段布局

```cpp
// src/hotspot/share/gc/g1/g1OopClosures.hpp:92-104
class G1ScanEvacuatedObjClosure : public G1ScanClosureBase {
public:
  G1ScanEvacuatedObjClosure(G1CollectedHeap* g1h,
                             G1ParScanThreadState* par_scan_state);
  
  template <class T> void do_oop_work(T* p);
  virtual void do_oop(oop* p);
  virtual void do_oop(narrowOop* p);
};
```

**内存布局**：

```
G1ScanEvacuatedObjClosure 对象（~32 bytes）：
+--------------------------------+ offset 0
| vtable                         | 8 bytes
+--------------------------------+ offset 8
| _g1h                           | 8 bytes（继承）
+--------------------------------+ offset 16
| _par_scan_state                | 8 bytes（继承）
+--------------------------------+ offset 24
| _from                          | 8 bytes（继承）
+--------------------------------+ offset 32

无额外字段！
- 仅通过 vtable 区分不同闭包
- 所有逻辑在 do_oop_work() 中
```

### 3.3 G1ParCopyHelper 字段布局

```cpp
// src/hotspot/share/gc/g1/g1OopClosures.hpp:107-133
class G1ParCopyHelper : public OopClosure {
protected:
  G1CollectedHeap* _g1h;               // offset ~8
  G1ParScanThreadState* _par_scan_state; // offset ~16
  uint _worker_id;                     // offset ~24
  ClassLoaderData* _scanned_cld;       // offset ~32
  G1ConcurrentMark* _cm;               // offset ~40
};
```

**内存布局图**：

```
G1ParCopyHelper 对象（~48 bytes）：
+--------------------------------+ offset 0
| vtable                         | 8 bytes
+--------------------------------+ offset 8
| _g1h                           | 8 bytes
+--------------------------------+ offset 16
| _par_scan_state                | 8 bytes
+--------------------------------+ offset 24
| _worker_id                     | 4 bytes
+--------------------------------+ offset 28
| _scanned_cld                   | 8 bytes
+--------------------------------+ offset 36
| _cm                            | 8 bytes
+--------------------------------+ offset 44
```

### 3.4 G1SharedClosures 容器

```cpp
// src/hotspot/share/gc/g1/g1SharedClosures.hpp:33-47
template <G1Mark Mark>
class G1SharedClosures {
public:
  G1ParCopyClosure<G1BarrierNone, Mark> _oops;          // ~48 bytes
  G1ParCopyClosure<G1BarrierCLD,  Mark> _oops_in_cld;   // ~48 bytes
  
  G1CLDScanClosure _clds;                               // ~24 bytes
  G1CodeBlobClosure _codeblobs;                         // ~16 bytes
};
```

**内存布局图**：

```
G1SharedClosures<G1MarkNone> 对象（~136 bytes）：
+--------------------------------+ offset 0
| _oops                          | G1ParCopyClosure (48 bytes)
|  - _g1h                        |
|  - _par_scan_state             |
|  - _worker_id                  |
|  - _scanned_cld                |
|  - _cm                         |
+--------------------------------+ offset 48
| _oops_in_cld                   | G1ParCopyClosure (48 bytes)
+--------------------------------+ offset 96
| _clds                          | G1CLDScanClosure (24 bytes)
+--------------------------------+ offset 120
| _codeblobs                     | G1CodeBlobClosure (16 bytes)
+--------------------------------+ offset 136
```

---

## 4. G1ScanEvacuatedObjClosure 核心实现

### 4.1 do_oop_work() 核心逻辑

```cpp
// src/hotspot/share/gc/g1/g1OopClosures.inline.hpp:74-92
template <class T>
inline void G1ScanEvacuatedObjClosure::do_oop_work(T* p) {
  // 步骤1：加载引用
  T heap_oop = RawAccess<>::oop_load(p);
  
  // 步骤2：检查是否为空
  if (CompressedOops::is_null(heap_oop)) {
    return;
  }
  
  // 步骤3：解码对象指针
  oop obj = CompressedOops::decode_not_null(heap_oop);
  
  // 步骤4：检查对象是否在 CSet
  const InCSetState state = _g1h->in_cset_state(obj);
  
  if (state.is_in_cset()) {
    // 对象在 CSet，预取并入队
    prefetch_and_push(p, obj);
  } else {
    // 对象不在 CSet
    
    // 步骤5：检查是否同 Region
    if (HeapRegion::is_in_same_region(p, obj)) {
      return;  // 同 Region，无需处理
    }
    
    // 步骤6：处理非 CSet 对象（如大对象）
    handle_non_cset_obj_common(state, p, obj);
    
    // 步骤7：更新 RSet
    _par_scan_state->update_rs(_from, p, obj);
  }
}
```

**流程图**：

```
do_oop_work(p)
    │
    ├─→ 加载引用 heap_oop
    │
    ├─→ 是否为空？
    │     └─→ 是 → return
    │
    ├─→ 解码对象 obj
    │
    ├─→ 对象在 CSet？
    │     │
    │     └─→ 是
    │          │
    │          ├─→ 预取 mark word
    │          ├─→ 入队到任务队列
    │          └─→ return
    │
    └─→ 否
          │
          ├─→ 同 Region？
          │     └─→ 是 → return
          │
          ├─→ 处理大对象
          │     └─→ 标记大对象存活
          │
          └─→ 更新 RSet
                └─→ 标记脏卡 → 入队 DCQ
```

### 4.2 prefetch_and_push() 预取优化

```cpp
// src/hotspot/share/gc/g1/g1OopClosures.inline.hpp:42-61
template <class T>
inline void G1ScanClosureBase::prefetch_and_push(T* p, const oop obj) {
  // 预取优化：
  // 1. 预取 mark word（用于写，可能安装转发指针）
  Prefetch::write(obj->mark_addr_raw(), 0);
  
  // 2. 预取 mark word 附近（用于读，后续访问）
  Prefetch::read(obj->mark_addr_raw(), (HeapWordSize*2));
  
  // 断言：确保引用关系正确
  assert((obj == RawAccess<>::oop_load(p)) ||
         (obj->is_forwarded() &&
          obj->forwardee() == RawAccess<>::oop_load(p)),
         "p should still be pointing to obj or to its forwardee");
  
  // 入队引用
  _par_scan_state->push_on_queue(p);
}
```

**预取的作用**：

```
对象 A 被复制后，扫描其字段：

字段 1 → 对象 B（在 CSet）
  ↓
prefetch_and_push(p, obj_B)
  ↓
预取 B 的 mark word
  ↓
push_on_queue(p)  // 入队
  ↓
稍后 pop 并处理 B
  ↓
此时 B 的 mark word 已在缓存中
  ↓
检查是否已转发更快

性能提升：
  - 无预取：访问 mark word → cache miss → ~100ns
  - 有预取：访问 mark word → cache hit → ~5ns
  - 提升：~20 倍
```

### 4.3 handle_non_cset_obj_common() 非CSet对象处理

```cpp
// src/hotspot/share/gc/g1/g1OopClosures.inline.hpp:63-68
template <class T>
inline void G1ScanClosureBase::handle_non_cset_obj_common(InCSetState const state,
                                                           T* p,
                                                           oop const obj) {
  if (state.is_humongous()) {
    // 标记大对象存活
    _g1h->set_humongous_is_live(obj);
  }
}
```

**大对象存活标记**：

```
大对象（Humongous Object）：
  - 占用多个连续 Region
  - 直接在 Old 区分配
  - 回收代价高

存活标记：
  - 记录大对象在本次 GC 中存活
  - 用于：
    1. 避免过早回收
    2. 支持并发回收（Concurrent Cleanup）

示例：
  Region 100-103：大对象 A（16 MB）
  
  扫描时发现引用指向 A：
    - state.is_humongous() = true
    - set_humongous_is_live(A)
    - 标记 Region 100-103 存活
  
  GC 后：
    - 不回收 Region 100-103
    - 下次 GC 再评估
```

### 4.4 update_rs() RSet 更新

```cpp
// 在 G1ParScanThreadState 中实现
template <class T>
void G1ParScanThreadState::update_rs(HeapRegion* from, T* p, oop obj) {
  // 只处理跨 Region 引用
  assert(!HeapRegion::is_in_same_region(p, obj), "cross-region reference");
  
  // 只处理非年轻代来源
  if (!from->is_young() && 
      _g1h->heap_region_containing((HeapWord*)obj)->rem_set()->is_tracked()) {
    
    // 计算卡索引
    size_t card_index = ct()->index_for(p);
    
    // 标记脏卡（延迟更新）
    if (ct()->mark_card_deferred(card_index)) {
      // 入队脏卡
      dirty_card_queue().enqueue((jbyte*)ct()->byte_for_index(card_index));
    }
  }
}
```

**RSet 更新流程**：

```
引用关系：
  Old Region 50 (from)
    └─→ 对象 A
          └─→ field → Eden Region 10 (obj)

步骤：
1. 检查是否跨 Region：
   from (Region 50) != obj (Region 10)
   → 是跨 Region 引用

2. 检查 from 是否年轻代：
   from->is_young() = false
   → 需要更新 RSet

3. 检查 obj 的 RSet 是否追踪：
   obj_region->rem_set()->is_tracked() = true
   → 需要更新

4. 计算卡索引：
   card_index = (p - heap_base) / 512

5. 标记脏卡：
   if (mark_card_deferred(card_index)) {
     // 成功标记，入队
     dirty_card_queue().enqueue(card_ptr)
   }

延迟处理：
  - 标记为 deferred
  - 入队到 DCQ
  - GC 后期批量更新 RSet
```

---

## 5. G1ParCopyClosure 根集处理

### 5.1 do_oop_work() 根集处理逻辑

```cpp
// src/hotspot/share/gc/g1/g1OopClosures.inline.hpp:236-281
template <G1Barrier barrier, G1Mark do_mark_object>
template <class T>
void G1ParCopyClosure<barrier, do_mark_object>::do_oop_work(T* p) {
  // 步骤1：加载引用
  T heap_oop = RawAccess<>::oop_load(p);
  
  // 步骤2：检查是否为空
  if (CompressedOops::is_null(heap_oop)) {
    return;
  }
  
  // 步骤3：解码对象
  oop obj = CompressedOops::decode_not_null(heap_oop);
  
  // 步骤4：检查对象是否在 CSet
  const InCSetState state = _g1h->in_cset_state(obj);
  
  if (state.is_in_cset()) {
    // 对象在 CSet，需要复制
    oop forwardee;
    markOop m = obj->mark_raw();
    
    if (m->is_marked()) {
      // 已转发，直接使用转发地址
      forwardee = (oop) m->decode_pointer();
    } else {
      // 未转发，复制对象
      forwardee = _par_scan_state->copy_to_survivor_space(state, obj, m);
    }
    
    assert(forwardee != NULL, "forwardee should not be NULL");
    
    // 步骤5：更新引用
    RawAccess<IS_NOT_NULL>::oop_store(p, forwardee);
    
    // 步骤6：标记（如果需要）
    if (do_mark_object != G1MarkNone && forwardee != obj) {
      mark_forwarded_object(obj, forwardee);
    }
    
    // 步骤7：CLD 屏障（如果需要）
    if (barrier == G1BarrierCLD) {
      do_cld_barrier(forwardee);
    }
    
  } else {
    // 对象不在 CSet
    
    // 步骤8：处理大对象
    if (state.is_humongous()) {
      _g1h->set_humongous_is_live(obj);
    }
    
    // 步骤9：标记（Initial Mark）
    if (do_mark_object == G1MarkFromRoot) {
      mark_object(obj);
    }
  }
  
  // 步骤10：局部清空队列
  trim_queue_partially();
}
```

**根集处理流程图**：

```
do_oop_work(p)
    │
    ├─→ 加载引用 obj
    │
    ├─→ 对象在 CSet？
    │     │
    │     └─→ 是
    │          │
    │          ├─→ 已转发？
    │          │     ├─→ 是 → 使用转发地址
    │          │     └─→ 否 → 复制对象
    │          │
    │          ├─→ 更新引用（p = forwardee）
    │          │
    │          ├─→ 需要标记？
    │          │     └─→ 是 → mark_forwarded_object()
    │          │
    │          └─→ 需要 CLD 屏障？
    │                └─→ 是 → do_cld_barrier()
    │
    └─→ 否
          │
          ├─→ 大对象？
          │     └─→ 是 → set_humongous_is_live()
          │
          └─→ Initial Mark？
                └─→ 是 → mark_object()
    
    └─→ trim_queue_partially()
```

### 5.2 mark_object() 标记对象

```cpp
// src/hotspot/share/gc/g1/g1OopClosures.inline.hpp:210-215
void G1ParCopyHelper::mark_object(oop obj) {
  // 断言：不在 CSet
  assert(!_g1h->heap_region_containing(obj)->in_collection_set(),
         "should not mark objects in the CSet");
  
  // 在 Next Bitmap 中标记
  _cm->mark_in_next_bitmap(_worker_id, obj);
}
```

**Initial Mark 标记**：

```
场景：Initial Mark GC（并发标记开始）

根集扫描：
  - 扫描 GC Roots
  - 对象不在 CSet（不是 Young GC）
  - 需要标记存活对象

标记流程：
  1. 扫描根集引用
  2. 对象不在 CSet
  3. do_mark_object = G1MarkFromRoot
  4. mark_object(obj)
     - 在 Next Bitmap 中设置对应位
     - 对象被标记为存活

后续：
  - 并发标记阶段会扫描这些对象
  - 构建完整的存活图
```

### 5.3 mark_forwarded_object() 标记转发对象

```cpp
// src/hotspot/share/gc/g1/g1OopClosures.inline.hpp:217-230
void G1ParCopyHelper::mark_forwarded_object(oop from_obj, oop to_obj) {
  // 断言：from 已转发
  assert(from_obj->is_forwarded(), "from obj should be forwarded");
  assert(from_obj->forwardee() == to_obj, "to obj should be the forwardee");
  assert(from_obj != to_obj, "should not be self-forwarded");
  
  // 断言：from 在 CSet，to 不在 CSet
  assert(_g1h->heap_region_containing(from_obj)->in_collection_set(),
         "from obj should be in the CSet");
  assert(!_g1h->heap_region_containing(to_obj)->in_collection_set(),
         "should not mark objects in the CSet");
  
  // 在 Next Bitmap 中标记 to_obj
  // 使用 from_obj 的 size（to_obj 可能未完全复制）
  _cm->mark_in_next_bitmap(_worker_id, to_obj, from_obj->size());
}
```

**转发对象标记的场景**：

```
场景：Initial Mark GC + 晋升对象

根集扫描：
  - 发现对象在 Eden（CSet）
  - 对象需要晋升到 Old
  
处理：
  1. copy_to_survivor_space()
     - 从 Eden 复制到 Old
     - 安装转发指针
  
  2. mark_forwarded_object(from_obj, to_obj)
     - to_obj 在 Old（不在 CSet）
     - 标记 to_obj 存活
     - 确保并发标记正确追踪

关键：
  - to_obj 可能还在复制中
  - 不能读取 to_obj->size()
  - 使用 from_obj->size()
```

### 5.4 do_cld_barrier() CLD 屏障

```cpp
// src/hotspot/share/gc/g1/g1OopClosures.inline.hpp:204-208
void G1ParCopyHelper::do_cld_barrier(oop new_obj) {
  // 如果新对象在年轻代，标记 CLD 为 modified
  if (_g1h->heap_region_containing(new_obj)->is_young()) {
    _scanned_cld->record_modified_oops();
  }
}
```

**CLD 屏障的作用**：

```
CLD（ClassLoaderData）：
  - 类加载器数据
  - 包含类元数据
  - 可能引用年轻代对象

场景：
  扫描 CLD 时：
    - 发现引用 obj（在 CSet）
    - 复制 obj 到 new_obj（年轻代）
    
  问题：
    - CLD 是弱根
    - 可能被并发修改
    - 需要确保一致性
  
  解决：
    do_cld_barrier(new_obj)
      - 如果 new_obj 在年轻代
      - 标记 CLD 为 modified
      - 后续重新扫描

目的：
  - 确保弱根一致性
  - 避免丢失引用
  - 支持 CMS 风格的类卸载
```

---

## 6. 闭包选择与创建机制

### 6.1 create_root_closures() 工厂方法

```cpp
// src/hotspot/share/gc/g1/g1RootClosures.cpp:100-112
G1EvacuationRootClosures* G1EvacuationRootClosures::create_root_closures(
    G1ParScanThreadState* pss, G1CollectedHeap* g1h) {
  
  G1EvacuationRootClosures* res = NULL;
  
  if (g1h->collector_state()->in_initial_mark_gc()) {
    // Initial Mark GC
    if (ClassUnloadingWithConcurrentMark) {
      // 启用并发类卸载
      res = new G1InitialMarkClosures<G1MarkPromotedFromRoot>(g1h, pss);
    } else {
      // 不启用并发类卸载
      res = new G1InitialMarkClosures<G1MarkFromRoot>(g1h, pss);
    }
  } else {
    // Young GC / Mixed GC
    res = new G1EvacuationClosures(g1h, pss, 
                                    g1h->collector_state()->in_young_only_phase());
  }
  
  return res;
}
```

**闭包选择决策树**：

```
create_root_closures()
    │
    ├─→ Initial Mark GC？
    │     │
    │     ├─→ 是
    │     │     │
    │     │     ├─→ ClassUnloadingWithConcurrentMark？
    │     │     │     ├─→ true
    │     │     │     │     └─→ G1InitialMarkClosures<G1MarkPromotedFromRoot>
    │     │     │     │         - 弱根需要两阶段处理
    │     │     │     │         - 支持类卸载
    │     │     │     │
    │     │     │     └─→ false
    │     │     │           └─→ G1InitialMarkClosures<G1MarkFromRoot>
    │     │     │               - 所有根统一处理
    │     │     │               - 不支持类卸载
    │     │
    │     └─→ 否
    │           │
    │           └─→ Young GC / Mixed GC
    │                 └─→ G1EvacuationClosures
    │                     - 强弱根统一处理
    │                     - 不需要标记
```

### 6.2 G1EvacuationClosures 标准闭包

```cpp
// src/hotspot/share/gc/g1/g1RootClosures.cpp:31-53
class G1EvacuationClosures : public G1EvacuationRootClosures {
  G1SharedClosures<G1MarkNone> _closures;
  
public:
  G1EvacuationClosures(G1CollectedHeap* g1h,
                       G1ParScanThreadState* pss,
                       bool in_young_gc) :
      _closures(g1h, pss, in_young_gc, /* must_claim_cld */ false) {}
  
  // 所有引用统一处理
  OopClosure* weak_oops()   { return &_closures._oops; }
  OopClosure* strong_oops() { return &_closures._oops; }
  
  // 所有 CLD 统一处理
  CLDClosure* weak_clds()             { return &_closures._clds; }
  CLDClosure* strong_clds()           { return &_closures._clds; }
  CLDClosure* second_pass_weak_clds() { return NULL; }
  
  // 所有 CodeBlob 统一处理
  CodeBlobClosure* strong_codeblobs() { return &_closures._codeblobs; }
  CodeBlobClosure* weak_codeblobs()   { return &_closures._codeblobs; }
  
  OopClosure* raw_strong_oops() { return &_closures._oops; }
  
  bool trace_metadata() { return false; }
};
```

**特点**：

```
1. 统一处理：
   - weak_oops == strong_oops
   - weak_clds == strong_clds
   - weak_codeblobs == strong_codeblobs

2. 无标记：
   - G1MarkNone
   - 不需要标记对象

3. 无二次处理：
   - second_pass_weak_clds() = NULL
   - 弱根不需要分阶段

适用场景：
  - Young GC
  - Mixed GC
  - 不需要标记存活对象
```

### 6.3 G1InitialMarkClosures Initial Mark 闭包

```cpp
// src/hotspot/share/gc/g1/g1RootClosures.cpp:55-98
template <G1Mark MarkWeak>
class G1InitialMarkClosures : public G1EvacuationRootClosures {
  G1SharedClosures<G1MarkFromRoot> _strong;  // 强根闭包
  G1SharedClosures<MarkWeak>       _weak;    // 弱根闭包
  
public:
  G1InitialMarkClosures(G1CollectedHeap* g1h,
                        G1ParScanThreadState* pss) :
      _strong(g1h, pss, /* process_only_dirty_klasses */ false, /* must_claim_cld */ true),
      _weak(g1h, pss,   /* process_only_dirty_klasses */ false, /* must_claim_cld */ true) {}
  
  // 强根和弱根分开处理
  OopClosure* weak_oops()   { return &_weak._oops; }
  OopClosure* strong_oops() { return &_strong._oops; }
  
  // CLD 处理
  CLDClosure* weak_clds()             { return null_if<G1MarkPromotedFromRoot>(&_weak._clds); }
  CLDClosure* strong_clds()           { return &_strong._clds; }
  CLDClosure* second_pass_weak_clds() { return null_if<G1MarkFromRoot>(&_weak._clds); }
  
  // CodeBlob 处理
  CodeBlobClosure* strong_codeblobs() { return &_strong._codeblobs; }
  CodeBlobClosure* weak_codeblobs()   { return &_weak._codeblobs; }
  
  OopClosure* raw_strong_oops() { return &_strong._oops; }
  
  // 是否追踪元数据
  bool trace_metadata() { return MarkWeak == G1MarkPromotedFromRoot; }
};
```

**两种模式的区别**：

```
模式1：G1MarkFromRoot
  - 所有根统一标记
  - weak_oops != strong_oops（但都标记）
  - second_pass_weak_clds() = NULL
  - trace_metadata() = false
  
  适用：
    - ClassUnloadingWithConcurrentMark = false
    - 不支持类卸载
    - 所有对象都标记

模式2：G1MarkPromotedFromRoot
  - 弱根需要二次处理
  - weak_clds() = NULL（第一遍不处理）
  - second_pass_weak_clds() = &_weak._clds（第二遍处理）
  - trace_metadata() = true
  
  适用：
    - ClassUnloadingWithConcurrentMark = true
    - 支持类卸载
    - 需要追踪哪些元数据存活
```

---

## 7. 关键场景分析

### 7.1 场景1：Evacuation 扫描复制后对象

```
对象 A 被复制到 Survivor：
  from: Eden Region 10
  to:   Survivor Region 20
  
对象 A 的字段：
  - field1 → 对象 B（在 Eden）
  - field2 → 对象 C（在 Old）
  - field3 → null

流程：
1. obj->oop_iterate_backwards(&_scanner)
   - 遍历对象 A 的字段
   - 对每个字段调用 do_oop_work()

2. field1 → B（在 CSet）：
   do_oop_work(&field1)
     - obj = B
     - state.is_in_cset() = true
     - prefetch_and_push(&field1, B)
       - 预取 B 的 mark word
       - push_on_queue(&field1)

3. field2 → C（不在 CSet）：
   do_oop_work(&field2)
     - obj = C
     - state.is_in_cset() = false
     - HeapRegion::is_in_same_region(&field2, C) = false
       - field2 在 Survivor Region 20
       - C 在 Old Region 50
     - update_rs(from=Region20, &field2, C)
       - 标记脏卡
       - 入队 DCQ

4. field3 → null：
   do_oop_work(&field3)
     - heap_oop = null
     - return

结果：
  - 队列中：[&field1]（待处理）
  - DCQ 中：[card(field2)]（待更新 RSet）
```

### 7.2 场景2：根集扫描（Young GC）

```
根集扫描：
  - 线程栈引用
  - 静态字段
  - JNI 全局引用

闭包：G1ParCopyClosure<G1BarrierNone, G1MarkNone>

示例：
  线程栈局部变量 p → 对象 A（在 Eden）

流程：
1. do_oop_work(p)
   - obj = A
   - state.is_in_cset() = true
   
2. m = A->mark_raw()
   - m->is_marked() = false（未转发）

3. forwardee = copy_to_survivor_space(state, obj, m)
   - 复制 A 到 Survivor
   - 安装转发指针
   - 返回新地址

4. RawAccess<>::oop_store(p, forwardee)
   - 更新栈引用

5. do_mark_object = G1MarkNone
   - 不标记

6. trim_queue_partially()
   - 清空队列（处理新产生的引用）

结果：
  - 栈引用更新到新地址
  - 对象 A 已复制
  - 队列中可能有 A 的字段引用
```

### 7.3 场景3：Initial Mark 根集扫描

```
Initial Mark GC：
  - 触发并发标记
  - 需要标记根集对象

闭包：G1ParCopyClosure<G1BarrierNone, G1MarkFromRoot>

示例：
  静态字段 StaticClass.field → 对象 A（在 Old）

流程：
1. do_oop_work(&StaticClass.field)
   - obj = A
   - state.is_in_cset() = false
     - Initial Mark 不回收 Old

2. state.is_humongous() = false
   - 普通对象

3. do_mark_object = G1MarkFromRoot
   - mark_object(A)
   - 在 Next Bitmap 中标记 A

4. trim_queue_partially()
   - 清空队列

后续：
  - 并发标记阶段从 A 开始遍历
  - 标记所有可达对象
  - 构建存活图
```

### 7.4 场景4：Scan RS（扫描记忆集）

```
场景：
  Old Region 50 引用 Eden Region 10
  RSet 记录了这个跨代引用

闭包：G1ScanObjsDuringScanRSClosure

流程：
1. 扫描 RSet 中的脏卡
2. 对脏卡中的对象字段调用 do_oop_work()

示例：
  Old Region 50 的 Card 3 被标记脏
  Card 3 包含对象 X
  X.field → 对象 Y（在 Eden）

do_oop_work(&X.field)
  - obj = Y
  - state.is_in_cset() = true
  - prefetch_and_push(&X.field, Y)
    - 入队处理

结果：
  - 老年代到年轻代的引用被处理
  - Y 被复制（如果存活）
  - 引用被更新
```

---

## 8. GDB 验证脚本

### 8.1 观察 G1ScanEvacuatedObjClosure

```gdb
# gdb_script: observe_scan_evacuated_obj.gdb

break G1ScanEvacuatedObjClosure::do_oop_work
commands
  printf "\n=== G1ScanEvacuatedObjClosure::do_oop_work() ===\n"
  
  # 查看参数
  printf "p: %p\n", $rdi
  
  # 加载引用
  set $heap_oop = *((HeapWord**)$rdi)
  printf "heap_oop: %p\n", $heap_oop
  
  # 单步执行
  next
  
  # 查看对象状态
  printf "state: %d\n", $eax
  
  continue
end

run
```

### 8.2 观察 G1ParCopyClosure

```gdb
# gdb_script: observe_par_copy.gdb

break G1ParCopyHelper::mark_object
commands
  printf "\n=== mark_object() ===\n"
  printf "obj: %p\n", $rdi
  
  # 查看对象信息
  set $obj = (oop)$rdi
  printf "obj->klass(): %p\n", $obj->_metadata._klass
  
  continue
end

break G1ParCopyHelper::mark_forwarded_object
commands
  printf "\n=== mark_forwarded_object() ===\n"
  printf "from_obj: %p\n", $rdi
  printf "to_obj:   %p\n", $rsi
  
  continue
end

run
```

### 8.3 统计闭包调用次数

```gdb
# gdb_script: stat_closure_calls.gdb

set $scan_evacuated_count = 0
set $par_copy_count = 0
set $update_rs_count = 0

break G1ScanEvacuatedObjClosure::do_oop_work
commands
  set $scan_evacuated_count = $scan_evacuated_count + 1
  continue
end

break G1ParCopyClosure::do_oop_work
commands
  set $par_copy_count = $par_copy_count + 1
  continue
end

break G1ParScanThreadState::update_rs
commands
  set $update_rs_count = $update_rs_count + 1
  continue
end

define print_stats
  printf "\n=== 闭包调用统计 ===\n"
  printf "G1ScanEvacuatedObjClosure: %d\n", $scan_evacuated_count
  printf "G1ParCopyClosure:          %d\n", $par_copy_count
  printf "update_rs:                 %d\n", $update_rs_count
end

# GC 后调用
# (gdb) print_stats
```

### 8.4 观察闭包创建

```gdb
# gdb_script: observe_closure_creation.gdb

break G1EvacuationRootClosures::create_root_closures
commands
  printf "\n=== create_root_closures() ===\n"
  
  # 单步执行
  next
  
  # 查看返回值
  printf "created closures: %p\n", $rax
  
  continue
end

break G1EvacuationClosures::G1EvacuationClosures
commands
  printf "\n=== G1EvacuationClosures 构造 ===\n"
  continue
end

break G1InitialMarkClosures::G1InitialMarkClosures
commands
  printf "\n=== G1InitialMarkClosures 构造 ===\n"
  continue
end

run
```

---

## 9. 面试级 Q&A

### Q1: G1ScanEvacuatedObjClosure 和 G1ParCopyClosure 有什么区别？

**A**: 用途和处理方式不同。

| 维度 | G1ScanEvacuatedObjClosure | G1ParCopyClosure |
|------|---------------------------|------------------|
| **用途** | 扫描复制后对象的字段 | 处理根集引用 |
| **调用时机** | 对象复制后 | GC Roots 扫描时 |
| **CSet 对象处理** | 入队，稍后处理 | 立即复制 |
| **引用更新** | 不更新（已更新） | 更新根引用 |
| **标记对象** | 不标记 | 可能标记（Initial Mark） |
| **RSet 更新** | 更新 | 不更新 |

**详细对比**：

```
G1ScanEvacuatedObjClosure：
  扫描复制后的对象字段
    ↓
  字段引用 → 对象 B（在 CSet）
    ↓
  prefetch_and_push(&field, B)
    - 预取 B 的 mark word
    - 入队到任务队列
    - 不立即复制（延迟处理）

G1ParCopyClosure：
  处理根集引用
    ↓
  根引用 → 对象 A（在 CSet）
    ↓
  copy_to_survivor_space(state, A, mark)
    - 立即复制对象
    - 更新根引用
    - 扫描新对象字段
```

---

### Q2: 为什么需要 prefetch_and_push() 预取？

**A**: 减少缓存未命中，提升性能。

**问题**：

```
对象 A 复制后，扫描字段：

字段 1 → 对象 B（在 CSet）
  ↓
入队 &field1
  ↓
稍后 pop 处理
  ↓
检查 B 是否已转发
  ↓
访问 B->mark
  ↓
可能 cache miss（~100ns）
```

**预取优化**：

```
字段 1 → 对象 B（在 CSet）
  ↓
prefetch_and_push(&field1, B)
  ↓
Prefetch::write(B->mark_addr, 0)  // 预取 mark word
  ↓
push_on_queue(&field1)
  ↓
稍后 pop 处理
  ↓
检查 B 是否已转发
  ↓
访问 B->mark
  ↓
cache hit（~5ns）

提升：~20 倍
```

**为什么先入队，不立即处理？**

```
立即处理的问题：
  1. 深度优先遍历
     - 栈深度大
     - 可能栈溢出
  
  2. Work Stealing 不均衡
     - 某些线程任务多
     - 某些线程任务少

入队处理的优势：
  1. 广度优先遍历
     - 栈深度小
     - 内存友好
  
  2. Work Stealing 均衡
     - 任务可窃取
     - 负载均衡

预取 + 入队：
  - 兼顾性能和并行度
  - 预取减少延迟
  - 入队支持 Work Stealing
```

---

### Q3: Initial Mark 的两种模式有什么区别？

**A**: 对弱根的处理方式不同。

**G1MarkFromRoot 模式**：

```
特点：
  - 所有根统一标记
  - weak_oops() 和 strong_oops() 都标记
  - second_pass_weak_clds() = NULL
  
适用：
  - ClassUnloadingWithConcurrentMark = false
  - 不支持类卸载
  - 所有对象都被标记

示例：
  扫描弱根（如 StringTable）
    ↓
  发现对象 A
    ↓
  mark_object(A)
    ↓
  A 被标记存活
  
  结果：
    - 所有可达对象都被标记
    - 包括弱引用可达的对象
    - 不支持类卸载（所有类都存活）
```

**G1MarkPromotedFromRoot 模式**：

```
特点：
  - 弱根需要两阶段处理
  - first pass：处理强根，标记存活
  - second pass：处理弱根，标记存活
  - trace_metadata() = true
  
适用：
  - ClassUnloadingWithConcurrentMark = true
  - 支持类卸载
  - 需要追踪哪些元数据存活

示例：
  First Pass（强根）：
    - 扫描线程栈、静态字段等
    - 标记所有可达对象
    - 记录哪些 CLD 被访问
  
  Second Pass（弱根）：
    - 扫描 StringTable、JNI Weak 等
    - 标记弱引用可达的对象
    - 但不标记未访问的 CLD
  
  结果：
    - 强引用可达的对象被标记
    - 弱引用可达的对象被标记
    - 未访问的 CLD 对应的类可卸载
```

**为什么要两阶段？**

```
单阶段的问题：
  - 弱根可能引用年轻代对象
  - 这些对象会被晋升
  - 但弱根扫描可能并发修改
  - 需要确保一致性

两阶段的解决：
  1. First Pass：
     - 处理强根
     - 标记强引用可达对象
     - 记录 CLD 访问
  
  2. Second Pass：
     - 处理弱根
     - 如果 CLD 已被访问，处理其弱引用
     - 确保一致性

类卸载：
  - 未被访问的 CLD
  - 对应的类可卸载
  - 释放元空间
```

---

### Q4: CLD 屏障的作用是什么？

**A**: 确保弱根一致性。

**问题场景**：

```
CLD（ClassLoaderData）：
  - 包含类元数据
  - 可能引用年轻代对象

示例：
  ClassLoaderData for ClassA
    └─→ ClassA.staticField → Eden 对象 B

并发问题：
  线程 1（GC）：
    - 扫描 CLD
    - 发现引用 → B（在 CSet）
    - 复制 B 到 B'
    - 更新引用为 B'
  
  线程 2（Mutator）：
    - 修改 ClassA.staticField
    - 写入新值 C
  
  竞态：
    - 线程 1 可能丢失线程 2 的修改
    - B' 可能成为垃圾（如果线程 2 覆盖了引用）
```

**CLD 屏障的解决**：

```
do_cld_barrier(new_obj):
  if (new_obj 在年轻代) {
    _scanned_cld->record_modified_oops()
  }

含义：
  - 如果扫描 CLD 时发现引用年轻代对象
  - 标记 CLD 为 modified
  - 后续重新扫描

流程：
  1. First Pass：
     - 扫描 CLD
     - 发现引用 → B（在 CSet）
     - 复制 B 到 B'（年轻代）
     - do_cld_barrier(B')
       - B' 在年轻代
       - 标记 CLD 为 modified
  
  2. Second Pass：
     - 重新扫描 modified CLD
     - 确保一致性

目的：
  - 确保弱根一致性
  - 避免丢失引用
  - 支持 CMS 风格的类卸载
```

---

### Q5: update_rs() 为什么要延迟更新？

**A**: 去重、批量处理、减少竞争。

**立即更新的问题**：

```
跨 Region 引用：
  Old Region 50
    └─→ Eden Region 10

每次引用更新都立即修改 RSet：
  1. 获取 RSet 锁
  2. 添加引用到 RSet
  3. 释放锁

问题：
  1. 锁竞争
     - 多线程修改同一个 Region 的 RSet
     - 锁竞争严重
  
  2. 重复处理
     - 同一张卡可能被多次引用
     - 每次都修改 RSet
  
  3. 性能差
     - 每次引用更新 ~100ns
     - 大量引用更新成为瓶颈
```

**延迟更新的优势**：

```
流程：
  1. 引用更新：
     - 标记卡为 deferred
     - 入队到 DCQ（DirtyCardQueue）
     - 快速（~5ns）
  
  2. GC 后期：
     - 批量处理 DCQ
     - 去重（同一张卡只处理一次）
     - 批量更新 RSet

优势：
  1. 去重：
     - 同一张卡多次修改
     - 只入队一次
     - 只更新 RSet 一次
  
  2. 批量处理：
     - 缓存友好
     - 减少锁竞争
  
  3. 性能提升：
     - 引用更新：~5ns（标记脏卡）
     - RSet 更新：~50ns（批量处理）
     - 提升：~10 倍

示例：
  Old Region 50 引用 Eden Region 10 的对象：
  
  对象 A.field1 → Eden 对象 X（Card 0）
  对象 A.field2 → Eden 对象 Y（Card 0）
  对象 A.field3 → Eden 对象 Z（Card 0）
  
  立即更新：
    - 处理 field1：更新 RSet（Card 0）
    - 处理 field2：更新 RSet（Card 0）【重复】
    - 处理 field3：更新 RSet（Card 0）【重复】
  
  延迟更新：
    - 处理 field1：标记 Card 0 为 deferred，入队
    - 处理 field2：Card 0 已 deferred，跳过
    - 处理 field3：Card 0 已 deferred，跳过
    - GC 后期：批量处理 Card 0，更新 RSet 一次
  
  结果：
    - 3 次 → 1 次
    - 减少 66% 的 RSet 更新
```

---

### Q6: 如何选择合适的闭包？

**A**: 根据 GC 类型和需求选择。

**决策流程**：

```
1. 确定 GC 类型：
   - Young GC / Mixed GC
   - Initial Mark GC
   - Remark / Cleanup

2. Young GC / Mixed GC：
   使用 G1EvacuationClosures
   - G1ParCopyClosure<G1BarrierNone, G1MarkNone>
   - 不需要标记对象
   - 强弱根统一处理

3. Initial Mark GC：
   
   3.1 ClassUnloadingWithConcurrentMark = false：
       使用 G1InitialMarkClosures<G1MarkFromRoot>
       - G1ParCopyClosure<G1BarrierNone, G1MarkFromRoot>
       - 所有对象都标记
       - 不支持类卸载
   
   3.2 ClassUnloadingWithConcurrentMark = true：
       使用 G1InitialMarkClosures<G1MarkPromotedFromRoot>
       - G1ParCopyClosure<G1BarrierNone, G1MarkPromotedFromRoot>
       - 弱根两阶段处理
       - 支持类卸载

4. Evacuation（对象复制后）：
   使用 G1ScanEvacuatedObjClosure
   - 扫描新对象字段
   - 处理 CSet 引用
   - 更新 RSet

5. Scan RS（扫描记忆集）：
   使用 G1ScanObjsDuringScanRSClosure
   - 扫描脏卡
   - 处理跨代引用

6. Update RS（更新 RSet）：
   使用 G1ScanObjsDuringUpdateRSClosure
   - 处理 DCQ
   - 更新 RSet
```

**关键参数**：

```
控制闭包行为：

-XX:+ClassUnloadingWithConcurrentMark
  - true: G1InitialMarkClosures<G1MarkPromotedFromRoot>
  - false: G1InitialMarkClosures<G1MarkFromRoot>

-XX:+G1TraceEagerReclaimHumongousObjects
  - 打印大对象回收信息
  - 用于调试 handle_non_cset_obj_common()

-Xlog:gc+ref=debug
  - 打印引用处理信息
  - 用于调试闭包行为
```

---

## 总结

**闭包体系的核心价值**：

1. **统一接口**：`do_oop()` 支持所有引用类型
2. **层次化设计**：基类提供公共功能，子类特化行为
3. **类型安全**：模板参数编译时确定，无运行时开销
4. **性能优化**：预取、延迟更新、批量处理

**关键数据**：
- 闭包对象大小：~32-48 bytes
- 预取提升：~20 倍
- RSet 延迟更新提升：~10 倍
- 引用扫描：~5ns（队列）vs ~50ns（直接）

**下一步学习**：
- G1RootProcessor：根集扫描的完整流程
- G1RemSet：记忆集的详细实现
- G1ConcurrentMark：并发标记的闭包体系
