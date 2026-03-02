# G1RedirtyCardsClosure 专家级源码分析

> **定位**：G1 Young GC 后期重新标记脏卡，确保 RSet 一致性  
> **核心问题**：为什么需要重新标记脏卡？哪些卡需要重新标记？  
> **源码路径**：`src/hotspot/share/gc/g1/g1CollectedHeap.cpp`

---

## 1. 一句话总结

**G1RedirtyCardsClosure 在 GC 后期遍历脏卡队列，将未被释放 Region 的卡片重新标记为 dirty，确保这些 Region 的 RSet 在后续 GC 中能被正确处理，同时避免对已释放 Region 的无效处理。**

---

## 2. 为什么需要 Redirty Cards？

### 2.1 问题背景

在 G1 Young GC 的 Evacuation 阶段：
1. **对象被复制**从 CSet Region 到 Survivor/Old Region
2. **引用关系变更**需要更新 RSet
3. **脏卡队列**（DirtyCardQueue）记录了需要处理的卡片

**核心问题**：
- Evacuation 阶段收集的脏卡指向 CSet 中的对象
- 这些 CSet Region 在 GC 后可能被**释放**（free）
- 如果 Region 被释放，其对应的脏卡处理将是无效的

### 2.2 如果不 Redirty？

```
问题场景
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

GC 前：
  Region A (Old, 不在 CSet)    Region B (CSet, Young)
  ┌─────────┐                 ┌─────────┐
  │ 对象 X  │────────────────→│ 对象 Y  │
  └─────────┘                 └─────────┘
  
  脏卡队列：[Card_A]  // 记录 X→Y 的引用

Evacuation 后：
  Region A (Old)               Region S (Survivor)
  ┌─────────┐                 ┌─────────┐
  │ 对象 X  │────────────────→│  对象 Y'│
  └─────────┘                 └─────────┘
  
  Region B 被释放（empty）
  
问题：
  - Card_A 仍然指向 Region B（已释放）
  - 如果直接处理 Card_A，会访问无效内存
  - 如果跳过 Card_A，X→Y' 的引用未被记录

解决方案：
  - Redirty 阶段检查 Card_A 对应的 Region
  - 如果 Region 将被释放，跳过不处理
  - 如果 Region 保留，重新标记为 dirty
```

---

## 3. 核心数据结构

### 3.1 RedirtyLoggedCardTableEntryClosure

```cpp
class RedirtyLoggedCardTableEntryClosure : public CardTableEntryClosure {
private:
    size_t _num_dirtied;          // 重新标记的卡片数
    G1CollectedHeap *_g1h;        // G1 堆
    G1CardTable *_g1_ct;          // 卡表

    // 根据卡指针获取对应 Region
    HeapRegion *region_for_card(jbyte *card_ptr) const {
        return _g1h->heap_region_containing(_g1_ct->addr_for(card_ptr));
    }

    // 判断 Region 是否会被释放
    bool will_become_free(HeapRegion *hr) const {
        // Region 会被释放的条件：
        // 1. 在 CSet 中
        // 2. 没有发生 Evacuation Failure
        return _g1h->is_in_cset(hr) && !hr->evacuation_failed();
    }

public:
    RedirtyLoggedCardTableEntryClosure(G1CollectedHeap *g1h) 
        : _num_dirtied(0), _g1h(g1h), _g1_ct(g1h->card_table()) {}

    // 处理每张卡片
    bool do_card_ptr(jbyte *card_ptr, uint worker_i) {
        HeapRegion *hr = region_for_card(card_ptr);

        // 只重新标记不会被释放的 Region 的卡片
        if (!will_become_free(hr)) {
            *card_ptr = G1CardTable::dirty_card_val();
            _num_dirtied++;
        }
        return true;  // 继续处理下一张卡
    }

    size_t num_dirtied() const { return _num_dirtied; }
};
```

### 3.2 G1RedirtyLoggedCardsTask

```cpp
class G1RedirtyLoggedCardsTask : public AbstractGangTask {
private:
    DirtyCardQueueSet *_queue;    // 脏卡队列集合
    G1CollectedHeap *_g1h;        // G1 堆

public:
    G1RedirtyLoggedCardsTask(DirtyCardQueueSet *queue, G1CollectedHeap *g1h) 
        : AbstractGangTask("Redirty Cards"), _queue(queue), _g1h(g1h) {}

    virtual void work(uint worker_id) {
        G1GCPhaseTimes *phase_times = _g1h->g1_policy()->phase_times();
        G1GCParPhaseTimesTracker x(phase_times, G1GCPhaseTimes::RedirtyCards, worker_id);

        // 创建闭包并应用到所有 completed buffers
        RedirtyLoggedCardTableEntryClosure cl(_g1h);
        _queue->par_apply_closure_to_all_completed_buffers(&cl);

        // 记录统计
        phase_times->record_thread_work_item(
            G1GCPhaseTimes::RedirtyCards, worker_id, cl.num_dirtied());
    }
};
```

---

## 4. Redirty Cards 流程详解

### 4.1 调用时机

```cpp
void G1CollectedHeap::redirty_logged_cards() {
    double redirty_logged_cards_start = os::elapsedTime();

    // 1. 创建并行任务
    G1RedirtyLoggedCardsTask redirty_task(&dirty_card_queue_set(), this);
    
    // 2. 重置并行迭代状态
    dirty_card_queue_set().reset_for_par_iteration();
    
    // 3. 并行执行 Redirty
    workers()->run_task(&redirty_task);

    // 4. 合并脏卡队列到全局队列
    DirtyCardQueueSet &dcq = G1BarrierSet::dirty_card_queue_set();
    dcq.merge_bufferlists(&dirty_card_queue_set());
    
    assert(dirty_card_queue_set().completed_buffers_num() == 0, 
           "All should be consumed");

    // 5. 记录时间
    g1_policy()->phase_times()->record_redirty_logged_cards_time_ms(
        (os::elapsedTime() - redirty_logged_cards_start) * 1000.0);
}
```

**调用链**：
```
G1CollectedHeap::do_collection_pause_at_safepoint()
  └── G1CollectedHeap::evacuate_collection_set()
      └── G1CollectedHeap::redirty_logged_cards()
```

### 4.2 处理逻辑详解

```cpp
bool RedirtyLoggedCardTableEntryClosure::do_card_ptr(jbyte *card_ptr, uint worker_i) {
    // 1. 获取卡对应的 Region
    HeapRegion *hr = region_for_card(card_ptr);

    // 2. 判断 Region 是否会被释放
    // 会被释放的条件：在 CSet 中 且 没有 Evacuation Failure
    if (!will_become_free(hr)) {
        // 3. 重新标记为 dirty
        *card_ptr = G1CardTable::dirty_card_val();
        _num_dirtied++;
    }
    // 4. 如果 Region 会被释放，跳过（卡片指向无效内存）
    
    return true;
}
```

**关键判断**：

```
will_become_free() 逻辑
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

场景1：Region 在 CSet 中，无 Evacuation Failure
  ┌─────────────────────────────────────────┐
  │ is_in_cset(hr) = true                  │
  │ hr->evacuation_failed() = false        │
  │ will_become_free = true                │
  │ → 卡片跳过（Region 即将被释放）         │
  └─────────────────────────────────────────┘

场景2：Region 在 CSet 中，有 Evacuation Failure
  ┌─────────────────────────────────────────┐
  │ is_in_cset(hr) = true                  │
  │ hr->evacuation_failed() = true         │
  │ will_become_free = false               │
  │ → 重新标记 dirty（Region 保留）         │
  └─────────────────────────────────────────┘

场景3：Region 不在 CSet 中（如 Old Region）
  ┌─────────────────────────────────────────┐
  │ is_in_cset(hr) = false                 │
  │ will_become_free = false               │
  │ → 重新标记 dirty（Region 保留）         │
  └─────────────────────────────────────────┘
```

---

## 5. 为什么需要这个机制？

### 5.1 CSet Region 的生命周期

```
CSet Region 状态转换
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

GC 前：
  Region B (Young, 在 CSet 中)
  ┌─────────────────┐
  │ 对象 Y (存活)   │
  │ 对象 Z (垃圾)   │
  └─────────────────┘

Evacuation 后（成功）：
  Region B 变为空 → 将被释放
  存活对象 Y' 在 Survivor Region
  
Evacuation 后（失败）：
  Region B 保留（部分对象未被复制）
  失败的对象留在原地，转发到自身

结论：
  - 只有完全成功的 CSet Region 才会被释放
  - 有 Evacuation Failure 的 Region 需要保留
```

### 5.2 脏卡指向分析

```
脏卡来源分析
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

来源1：老年代 → CSet
  Old Region A ──→ Young Region B (CSet)
  
  问题：
    - 卡指向 Region B
    - 如果 B 被释放，卡指向无效内存
    - 但引用关系 A→B 仍然存在（只是 B 的对象被复制了）
    
  处理：
    - 如果 B 被释放：跳过（引用关系已在 Evacuation 中处理）
    - 如果 B 保留（Evacuation Failure）：重新标记 dirty

来源2：老年代 → 老年代（跨 Region）
  Old Region A ──→ Old Region B
  
  问题：
    - B 不在 CSet 中，不会被释放
    - 但卡可能在之前的 GC 中被记录
    
  处理：
    - 重新标记 dirty（Region 保留）
```

---

## 6. 性能优化分析

### 6.1 并行处理

```cpp
// 并行应用闭包到所有 completed buffers
_queue->par_apply_closure_to_all_completed_buffers(&cl);
```

**优势**：
- 多线程并行处理脏卡队列
- 每个线程处理独立的缓冲区
- 减少 GC 暂停时间

### 6.2 过滤优化

```cpp
// 只重新标记不会被释放的 Region 的卡片
if (!will_become_free(hr)) {
    *card_ptr = G1CardTable::dirty_card_val();
    _num_dirtied++;
}
```

**效果**：
- 避免对已释放 Region 的无效处理
- 减少后续并发精炼的工作量
- 降低内存访问（跳过无效卡片）

### 6.3 时间开销

```
Redirty Cards 时间开销估算
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

场景1：小规模 Young GC
  - 脏卡数量：1000
  - 处理时间：~0.1-0.2ms
  - 占比：< 1% 的 GC 时间

场景2：大规模 Mixed GC
  - 脏卡数量：10000
  - 处理时间：~1-2ms
  - 占比：~1-2% 的 GC 时间

优化效果：
  - 并行处理后，时间随线程数增加而减少
  - 8 线程时，时间约为单线程的 1/4-1/6
```

---

## 7. 常见问题与面试题

### Q1: Redirty Cards 和 Update RS 有什么区别？

**答案**：

| 阶段 | 处理内容 | 目的 |
|------|----------|------|
| **Update RS** | 处理 Evacuation 阶段收集的脏卡，更新 RSet | 建立新的跨 Region 引用关系 |
| **Redirty Cards** | 重新标记不会被释放 Region 的卡片 | 清理无效卡片，为下次 GC 准备 |

时序：
```
Evacuation → Update RS → Redirty Cards → Free CSet
```

### Q2: 为什么跳过会被释放的 Region 的卡片？

**答案**：
1. **无效内存**：Region 被释放后，卡片指向的内存不再有效
2. **已处理**：引用关系已在 Evacuation 中处理（对象已复制）
3. **避免错误**：访问已释放 Region 会导致崩溃

### Q3: Evacuation Failure 的 Region 为什么需要 Redirty？

**答案**：
- Evacuation Failure 的 Region **不会被释放**
- Region 中仍有存活对象
- 这些对象的引用关系需要后续 GC 处理
- 因此对应的卡片需要重新标记为 dirty

### Q4: Redirty 后的卡片去哪里？

**答案**：
```cpp
// 合并到全局脏卡队列
dcq.merge_bufferlists(&dirty_card_queue_set());
```
- 重新标记的卡片保留在队列中
- 等待并发精炼线程处理
- 或者下次 GC 的 Update RS 阶段处理

---

## 8. 总结

### 8.1 核心设计要点

```
G1RedirtyCardsClosure 设计精髓
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. 清理无效卡片
   ├── 识别将被释放的 CSet Region
   ├── 跳过这些 Region 的卡片
   └── 避免访问无效内存

2. 保留有效卡片
   ├── 重新标记为 dirty
   ├── 包括：非 CSet Region、Evacuation Failure Region
   └── 确保后续 GC 能正确处理

3. 并行处理
   ├── 多线程处理脏卡队列
   ├── 独立处理各自的缓冲区
   └── 减少 GC 暂停时间

4. 与后续阶段衔接
   ├── 合并到全局脏卡队列
   ├── 并发精炼线程处理
   └── 为下次 GC 做准备
```

### 8.2 时序图

```
Redirty Cards 在 GC 流程中的位置
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Evacuation
  ├── 复制对象
  ├── 更新引用
  └── 收集脏卡到队列

Update RS
  ├── 处理脏卡队列
  ├── 扫描卡片对象
  └── 更新 RSet

Redirty Cards  ← 当前阶段
  ├── 遍历脏卡队列
  ├── 检查卡片对应 Region
  ├── 跳过将被释放的 Region
  └── 重新标记其他卡片为 dirty

Free CSet
  ├── 释放 CSet Region
  └── 归还到自由列表

Concurrent Refine
  └── 处理 Redirty 后的卡片
```

---

## 参考文档

1. OpenJDK 11: `src/hotspot/share/gc/g1/g1CollectedHeap.cpp`
2. OpenJDK 11: `src/hotspot/share/gc/g1/dirtyCardQueue.hpp`
3. OpenJDK 11: `src/hotspot/share/gc/g1/g1GCPhaseTimes.hpp`
4. G1 论文: Detlefs et al., "Garbage-First Garbage Collection"

---

**文档信息**
- 创建时间: 2026-02-10
- 源码版本: OpenJDK 11
- 分析类型: 专家级源码分析
- 配套技能: Read-BottomUp, JVM-Problem-Driven
