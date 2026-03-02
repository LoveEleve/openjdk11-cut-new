# G1UpdateRemSetClosure 与 DirtyCardQueue 专家级源码分析

> **定位**：G1 Evacuation 阶段 RSet 更新机制，记录跨 Region 引用关系  
> **核心问题**：对象复制后如何更新 RSet？脏卡队列如何工作？  
> **源码路径**：`src/hotspot/share/gc/g1/g1ParScanThreadState.hpp`, `dirtyCardQueue.hpp`

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1UpdateRemSetClosure 的本质是**Evacuation 后 RSet 更新的闭包**：遍历新复制的对象的引用字段，对于跨 Region 的引用，将包含该字段的卡标记为 dirty（`card_table->dirty(addr)`）；这些脏卡会被 Concurrent Refinement 处理，更新目标 Region 的 RSet。

### 0.2 为什么需要？

对象复制到新 Region 后，新对象的引用字段可能指向其他 Region（跨 Region 引用）。这些新的跨 Region 引用需要被记录到 RSet 中，否则下次 GC 会漏标这些引用。G1UpdateRemSetClosure 通过标记脏卡的方式，将 RSet 更新推迟到 Concurrent Refinement。

### 0.3 怎么解决？

**遍历引用字段 + 标记脏卡**：`G1UpdateRemSetClosure::do_oop()` 检查引用是否跨 Region；如果跨 Region，`card_table->dirty(field_addr)` 标记包含该字段的卡为 dirty；同时将脏卡地址入 `DirtyCardQueue`；Concurrent Refinement 处理脏卡，更新目标 Region 的 RSet。

### 0.4 为什么这样设计？

- **为什么不在 Evacuation 时直接更新 RSet？** 直接更新 RSet 需要在 GC Worker 的热路径上做复杂的 RSet 操作（Sparse/Fine/Coarse 三级结构的查找+插入），代价高；标记脏卡代价低（写一个字节），RSet 更新推迟到 Concurrent Refinement
- **为什么需要同时入 DirtyCardQueue？** 只标记脏卡不够，还需要通知 Concurrent Refinement 有新的脏卡需要处理；DirtyCardQueue 是通知机制

---

## 1. 一句话总结

**G1 通过"Deferred RSet Update"机制优化跨 Region 引用记录：Evacuation 阶段将脏卡存入线程本地队列（DirtyCardQueue），GC 暂停后期批量处理，减少并发冲突并提高缓存局部性。**

---

## 2. 为什么需要 RSet 更新？

### 2.1 问题背景

在 G1 Young GC 的 Evacuation 阶段，存活对象被复制到新 Region：
- **新生代对象** → Survivor Region
- **晋升对象** → Old Region

**核心挑战**：
当对象移动后，指向该对象的引用需要更新，同时需要记录新的跨 Region 引用关系到 RSet。

### 2.2 如果不更新 RSet？

```
问题场景
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

复制前：
  Region A (Old)          Region B (CSet)
  ┌─────────┐            ┌─────────┐
  │ 对象 X  │───────────→│ 对象 Y  │
  └─────────┘ 引用       └─────────┘
                      
  RSet[B] = {A的卡索引}  // 记录跨 Region 引用

复制后（Y' 在 Survivor）：
  Region A (Old)          Region S (Survivor)
  ┌─────────┐            ┌─────────┐
  │ 对象 X  │───────────→│  对象 Y'│
  └─────────┘            └─────────┘
  
  如果不更新 RSet：
  - RSet[S] 为空（不知道有来自 A 的引用）
  - 下次 GC 不会扫描 Region A 中的引用
  - 对象 Y' 被错误回收！

结论：
  必须更新 RSet[S]，记录来自 Region A 的引用
```

---

## 3. 两种 RSet 更新策略

### 3.1 Immediate Update（立即更新）

```
流程：
  发现跨 Region 引用 ──→ 直接修改目标 Region 的 RSet
  
缺点：
  1. 多线程竞争：多个 GC 线程可能同时修改同一个 RSet
  2. 缓存失效：RSet 数据结构分散，频繁随机访问
  3. 阻塞风险：RSet 内部有锁，可能成为瓶颈
```

### 3.2 Deferred Update（延迟更新）✓ G1 采用

```
流程：
  发现跨 Region 引用 ──→ 记录脏卡到本地队列 ──→ GC 后期批量处理
  
优点：
  1. 无锁：线程本地队列，无竞争
  2. 批处理：合并同一卡的多个更新
  3. 缓存友好：顺序处理脏卡，预取优化
```

---

## 4. 核心数据结构

### 4.1 DirtyCardQueue 结构

```cpp
// dirtyCardQueue.hpp
class DirtyCardQueue : public PtrQueue {
public:
    DirtyCardQueue(DirtyCardQueueSet* qset, bool permanent = false);
    
    // 将脏卡加入队列
    void enqueue(jbyte* card_ptr) { ... }
    
    // Flush 到全局队列
    void flush() { flush_impl(); }
};

class DirtyCardQueueSet : public PtrQueueSet {
    DirtyCardQueue _shared_dirty_card_queue;
    
    // 应用到 completed buffers
    bool apply_closure_to_completed_buffer(
        CardTableEntryClosure* cl,
        uint worker_i,
        size_t stop_at,
        bool during_pause);
    
    // GC 期间处理
    bool apply_closure_during_gc(CardTableEntryClosure* cl, uint worker_i);
};
```

#### PtrQueue 基类

```cpp
// ptrQueue.hpp
class PtrQueue : public CHeapObj<mtGC> {
protected:
    PtrQueueSet* _qset;           // 所属队列集合
    void** _buf;                  // 缓冲区指针
    size_t _index;                // 当前写入位置
    bool _active;                 // 是否激活
    
public:
    // 入队操作
    void enqueue(void* ptr) {
        if (_index == 0) {
            handle_zero_index();  // 缓冲区满，处理
        }
        _buf[--_index] = ptr;
    }
};
```

### 4.2 G1ParScanThreadState 中的 RSet 更新

```cpp
class G1ParScanThreadState {
private:
    DirtyCardQueue _dcq;          // 线程本地脏卡队列
    G1CardTable*   _ct;           // 卡表
    
public:
    template <class T>
    void update_rs(HeapRegion* from, T* p, oop o) {
        // 1. 过滤同 Region 引用
        assert(!HeapRegion::is_in_same_region(p, o), ...);
        
        // 2. 只处理老年代到新生代/老年代的引用
        //    年轻代作为来源不需要记录（Young GC 会全扫描年轻代）
        if (!from->is_young() && 
            _g1h->heap_region_containing((HeapWord*)o)->rem_set()->is_tracked()) {
            
            // 3. 获取卡索引
            size_t card_index = ct()->index_for(p);
            
            // 4. 延迟标记：如果卡未被加入队列，则入队
            if (ct()->mark_card_deferred(card_index)) {
                dirty_card_queue().enqueue(
                    (jbyte*)ct()->byte_for_index(card_index));
            }
        }
    }
    
    DirtyCardQueue& dirty_card_queue() { return _dcq; }
};
```

#### 关键字段解析

| 字段 | 类型 | 作用 | 为什么重要 |
|------|------|------|-----------|
| `_dcq` | DirtyCardQueue | 线程本地脏卡队列 | 无锁添加脏卡 |
| `_ct` | G1CardTable* | 卡表指针 | 卡索引计算和标记 |
| `mark_card_deferred` | 方法 | 延迟标记卡 | 避免重复入队 |

---

## 5. RSet 更新流程详解

### 5.1 Evacuation 阶段收集脏卡

```cpp
// 在 do_oop_evac 中发现跨 Region 引用
template <class T> void G1ParScanThreadState::do_oop_evac(T* p) {
    // 1. 读取引用
    oop obj = RawAccess<IS_NOT_NULL>::oop_load(p);
    
    // 2. 复制对象（如果在 CSet 中）
    // ... copy_to_survivor_space ...
    
    // 3. 更新引用
    RawAccess<IS_NOT_NULL>::oop_store(p, obj);
    
    // 4. 检查是否需要更新 RSet
    // 条件：引用来源和目标是不同 Region
    if (!HeapRegion::is_in_same_region(p, obj)) {
        HeapRegion* from = _g1h->heap_region_containing(p);
        update_rs(from, p, obj);  // 记录脏卡
    }
}
```

### 5.2 update_rs 实现详解

```cpp
template <class T>
inline void G1ParScanThreadState::update_rs(HeapRegion* from, T* p, oop o) {
    // 关键优化：年轻代作为来源不需要记录
    // 原因：Young GC 时会全量扫描年轻代，无需 RSet
    //       Mixed GC 时只需要老年代的 RSet
    if (!from->is_young() && 
        _g1h->heap_region_containing((HeapWord*)o)->rem_set()->is_tracked()) {
        
        // 计算卡索引
        size_t card_index = ct()->index_for(p);
        
        // 延迟标记：尝试将卡标记为"已延迟"
        // 如果成功（卡之前未被标记），则入队
        // 如果失败（卡已被标记），则跳过（避免重复）
        if (ct()->mark_card_deferred(card_index)) {
            dirty_card_queue().enqueue(
                (jbyte*)ct()->byte_for_index(card_index));
        }
    }
}
```

**关键优化点**：

```
为什么 from->is_young() 不需要记录？
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

场景1：Young → Young
  Region A (Young) ──→ Region B (Young)
  处理：Young GC 会扫描所有年轻代 Region，无需 RSet

场景2：Young → Old
  Region A (Young) ──→ Region B (Old)
  处理：对象晋升到 Old，引用在 Young GC 中被处理
       下次 Old GC 时，引用已在 Old，不需要 RSet 记录

场景3：Old → Young
  Region A (Old) ──→ Region B (Young)
  ✅ 需要记录！
  原因：Young GC 需要知道哪些 Old Region 引用了年轻代

场景4：Old → Old
  Region A (Old) ──→ Region B (Old)
  ✅ 需要记录！
  原因：Mixed GC 需要知道跨 Old Region 引用

结论：
  只有来源是老年代时才需要记录 RSet
```

### 5.3 mark_card_deferred 实现

```cpp
// g1CardTable.hpp
inline bool G1CardTable::mark_card_deferred(size_t card_index) {
    jbyte* byte = _byte_map + card_index;
    jbyte val = *byte;
    
    // 如果卡已经是 clean 或 deferred，标记为 deferred
    if (val == clean_card_val() || val == deferred_card_val()) {
        *byte = deferred_card_val();
        return true;  // 成功标记，需要入队
    }
    
    // 卡已经是 dirty 或其他状态，不需要重复处理
    return false;
}
```

**卡状态转换**：

```
卡状态机
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

clean (0) ──→ deferred (1) ──→ dirty (2)
              ↑_______________│

状态说明：
  clean (0):   未修改，无引用变更
  deferred (1): 已加入脏卡队列，待处理
  dirty (2):   已处理，有跨 Region 引用

转换逻辑：
  - clean → deferred: 第一次发现引用变更，入队
  - deferred → dirty: 处理完成后设置
  - dirty → deferred: 新的引用变更，重新入队
```

---

## 6. Update RS 阶段处理

### 6.1 GC 后期批量处理

```cpp
// g1RemSet.cpp
void G1RemSet::update_rem_set(uint worker_i, G1ParScanThreadState* pss) {
    G1GCPhaseTimes* p = _g1h->g1_policy()->phase_times();
    
    // 跟踪 Update RS 阶段时间
    G1EvacPhaseTimesTracker x(p, pss, G1GCPhaseTimes::UpdateRS, worker_i);
    
    // 1. 创建处理闭包
    G1ScanObjsDuringUpdateRSClosure update_rs_cl(_g1h, pss, worker_i);
    
    // 2. 创建卡片处理闭包
    G1RefineCardClosure refine_card_cl(_g1h, &update_rs_cl);
    
    // 3. 迭代处理所有脏卡
    _g1h->iterate_dirty_card_closure(&refine_card_cl, worker_i);
    
    // 4. 记录统计
    p->record_thread_work_item(G1GCPhaseTimes::UpdateRS, worker_i, 
                               refine_card_cl.cards_scanned(), 
                               G1GCPhaseTimes::UpdateRSScannedCards);
}
```

### 6.2 G1RefineCardClosure 实现

```cpp
class G1RefineCardClosure: public CardTableEntryClosure {
    G1RemSet* _g1rs;
    G1ScanObjsDuringUpdateRSClosure* _update_rs_cl;
    size_t _cards_scanned;
    size_t _cards_skipped;
    
public:
    bool do_card_ptr(jbyte* card_ptr, uint worker_i) {
        // 1. 精炼卡片（扫描卡片范围内的对象）
        bool card_scanned = _g1rs->refine_card_during_gc(card_ptr, _update_rs_cl);
        
        if (card_scanned) {
            // 2. 部分处理队列（避免队列过长）
            _update_rs_cl->trim_queue_partially();
            _cards_scanned++;
        } else {
            _cards_skipped++;
        }
        return true;  // 继续处理下一张卡
    }
};
```

### 6.3 refine_card_during_gc 实现

```cpp
bool G1RemSet::refine_card_during_gc(
        jbyte* card_ptr,
        G1ScanObjsDuringUpdateRSClosure* update_rs_cl) {
    
    // 1. 获取卡对应的堆地址范围
    HeapWord* start = _ct->addr_for(card_ptr);
    HeapWord* end = start + G1CardTable::card_size_in_words;
    MemRegion dirty_region(start, end);
    
    // 2. 获取卡所在 Region
    uint card_region_idx = _g1h->addr_to_region(start);
    HeapRegion* card_region = _g1h->region_at(card_region_idx);
    
    // 3. 设置闭包的来源 Region
    update_rs_cl->set_region(card_region);
    
    // 4. 迭代卡片范围内的所有对象
    //    对对象的每个引用字段调用闭包
    bool card_processed = card_region->oops_on_card_seq_iterate_careful<true>(
        dirty_region, update_rs_cl);
    
    return card_processed;
}
```

### 6.4 G1ScanObjsDuringUpdateRSClosure 实现

```cpp
// g1OopClosures.inline.hpp
template <class T>
inline void G1ScanObjsDuringUpdateRSClosure::do_oop_work(T* p) {
    T o = RawAccess<>::oop_load(p);
    if (CompressedOops::is_null(o)) return;
    
    oop obj = CompressedOops::decode_not_null(o);
    
    // 1. 检查对象是否在 CSet 中（需要复制）
    const InCSetState state = _g1h->in_cset_state(obj);
    
    if (state.is_in_cset()) {
        // 对象需要被复制，Push 到队列后续处理
        prefetch_and_push(p, obj);
    } else {
        // 2. 检查是否是同 Region 引用
        HeapRegion* to = _g1h->heap_region_containing(obj);
        if (_from == to) return;  // 同 Region，无需记录
        
        // 3. 处理非 CSet 对象（如 Humongous）
        handle_non_cset_obj_common(state, p, obj);
        
        // 4. 添加到目标 Region 的 RSet
        to->rem_set()->add_reference(p, _worker_i);
    }
}
```

---

## 7. 脏卡队列的工作机制

### 7.1 线程本地队列结构

```cpp
// 每个 G1ParScanThreadState 有自己的 DirtyCardQueue
class G1ParScanThreadState {
    DirtyCardQueue _dcq;  // 线程本地队列
    
public:
    DirtyCardQueue& dirty_card_queue() { return _dcq; }
};

// DirtyCardQueue 继承自 PtrQueue
class DirtyCardQueue : public PtrQueue {
    // 使用 PtrQueue 的 enqueue 机制
};
```

### 7.2 缓冲区管理机制

```
PtrQueue 缓冲区管理
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

每个线程的 DirtyCardQueue：
┌─────────────────────────────────────────────────────┐
│ PtrQueue                                            │
│  ├── _buf: void**  (指向缓冲区数组)                │
│  ├── _index: size_t (下一个写入位置)               │
│  └── _qset: PtrQueueSet* (所属队列集合)            │
└─────────────────────────────────────────────────────┘

缓冲区状态：
  _index 从缓冲区大小递减到 0
  当 _index == 0 时，缓冲区满，需要 flush

Flush 过程：
  1. 将当前缓冲区加入全局 completed_buffers 列表
  2. 从 free list 获取新缓冲区
  3. 重置 _index
```

### 7.3 全局队列集合

```cpp
class DirtyCardQueueSet : public PtrQueueSet {
    // 已完成缓冲区列表（多个线程共享）
    BufferNode* _completed_buffers_head;
    BufferNode* _completed_buffers_tail;
    
    // 并行迭代状态
    BufferNode* volatile _cur_par_buffer_node;
    
public:
    // GC 期间处理所有 completed buffers
    bool apply_closure_during_gc(CardTableEntryClosure* cl, uint worker_i);
    
    // 并行处理（多线程协作）
    void par_apply_closure_to_all_completed_buffers(CardTableEntryClosure* cl);
};
```

---

## 8. 性能优化分析

### 8.1 Deferred vs Immediate 对比

| 指标 | Immediate Update | Deferred Update (G1) |
|------|------------------|---------------------|
| **锁竞争** | 高（多线程竞争 RSet 锁） | 低（线程本地队列） |
| **缓存局部性** | 差（随机访问 RSet） | 好（顺序处理脏卡） |
| **批处理** | 无（逐个更新） | 有（合并同一卡） |
| **实现复杂度** | 简单 | 复杂（需要队列管理） |
| **延迟** | 低（立即生效） | 稍高（GC 后期处理） |

### 8.2 批处理优化效果

```
批处理示例
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

场景：一个卡内有 10 个对象，每个对象有 5 个跨 Region 引用

Immediate Update：
  50 次 RSet 更新
  每次更新：获取锁 + 查找 RSet + 添加条目
  总时间：50 × 100ns = 5000ns

Deferred Update：
  1 次卡处理
  扫描卡内对象：10 个
  RSet 更新：50 次（但可能合并到同一区域）
  总时间：1 × 500ns + 50 × 50ns = 3000ns
  
优化效果：约 40% 提升
```

### 8.3 卡标记优化

```cpp
// mark_card_deferred 避免重复入队
if (ct()->mark_card_deferred(card_index)) {
    dirty_card_queue().enqueue(...);
}

效果：
  - 同一卡的多次更新只入队一次
  - 减少队列长度
  - 减少后续处理时间
```

---

## 9. 常见问题与面试题

### Q1: 为什么年轻代作为来源不需要记录 RSet？

**答案**：
- Young GC 会全量扫描年轻代 Region，不需要 RSet 指导
- Mixed GC 主要关注老年代，年轻代引用在 GC 时自然处理
- 减少不必要的 RSet 更新开销

### Q2: mark_card_deferred 的作用是什么？

**答案**：
1. **去重**：同一卡的多次引用变更只入队一次
2. **状态跟踪**：标记卡为"已延迟"，避免重复处理
3. **性能优化**：减少队列长度和处理时间

### Q3: Deferred Update 的缺点是什么？

**答案**：
1. **延迟**：RSet 更新有延迟，GC 暂停期间才处理
2. **内存**：需要额外的脏卡队列缓冲区
3. **复杂度**：需要管理队列生命周期和 flush

### Q4: Update RS 阶段和 Scan RS 阶段有什么区别？

**答案**：

| 阶段 | 处理内容 | 来源 |
|------|----------|------|
| **Update RS** | 处理脏卡队列，更新 RSet | Evacuation 阶段记录的脏卡 |
| **Scan RS** | 扫描 RSet，处理跨 Region 引用 | RSet 中已有的条目 |

时序：
```
Evacuation ──→ Update RS ──→ Scan RS
(产生脏卡)    (处理脏卡)    (使用 RSet)
```

---

## 10. 总结

### 10.1 核心设计要点

```
G1 RSet Update 设计精髓
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. Deferred Update 策略
   ├── 线程本地队列收集脏卡
   ├── GC 后期批量处理
   └── 减少竞争，提高缓存局部性

2. 智能过滤
   ├── 年轻代来源不记录
   ├── mark_card_deferred 去重
   └── 只处理跨 Region 引用

3. 批处理优化
   ├── 合并同一卡的多条更新
   ├── 顺序访问提高缓存命中率
   └── 并行处理（多线程协作）

4. 状态管理
   ├── clean → deferred → dirty
   ├── 避免重复处理
   └── 支持并发精炼
```

### 10.2 时序图

```
RSet Update 完整流程
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Evacuation 阶段（多线程并行）
┌─────────────────────────────────────────────────────┐
│ do_oop_evac()                                       │
│   └── update_rs()                                   │
│       └── dirty_card_queue().enqueue(card)         │
└─────────────────────────────────────────────────────┘
            ↓ 缓冲区满或 GC 结束
Flush 到全局队列
┌─────────────────────────────────────────────────────┐
│ PtrQueue::handle_zero_index()                       │
│   └── 加入 _completed_buffers 列表                 │
└─────────────────────────────────────────────────────┘
            ↓ GC 暂停后期
Update RS 阶段（并行处理）
┌─────────────────────────────────────────────────────┐
│ G1RemSet::update_rem_set()                          │
│   └── iterate_dirty_card_closure()                  │
│       └── refine_card_during_gc()                   │
│           └── add_reference()  // 更新 RSet         │
└─────────────────────────────────────────────────────┘
```

---

## 参考文档

1. OpenJDK 11: `src/hotspot/share/gc/g1/g1ParScanThreadState.hpp`
2. OpenJDK 11: `src/hotspot/share/gc/g1/dirtyCardQueue.hpp`
3. OpenJDK 11: `src/hotspot/share/gc/g1/g1RemSet.cpp`
4. OpenJDK 11: `src/hotspot/share/gc/g1/g1OopClosures.inline.hpp`
5. G1 论文: Detlefs et al., "Garbage-First Garbage Collection"

---

**文档信息**
- 创建时间: 2026-02-10
- 源码版本: OpenJDK 11
- 分析类型: 专家级源码分析
- 配套技能: Read-TopDown, JVM-Concurrency-Design
