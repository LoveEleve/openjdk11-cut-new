# G1RemSet 更新机制：并发精炼与 RSet 维护

> **分析目标**：深入理解 G1 如何维护 Remembered Set（记忆集），以及如何通过并发精炼、延迟更新等机制优化性能。
>
> **标准环境**：-Xms8g -Xmx8g -XX:+UseG1GC，G1 Region = 4MB，并发精炼线程数 = 13

---

## 一、问题引入：为什么需要 RSet 更新机制？

### 1.1 G1 的核心挑战

G1 GC 的核心特点是 **Region-based**，每个 Region 独立回收。但要实现这一点，必须解决一个问题：

```
┌─────────────────────────────────────────────────────────────────┐
│  问题：如何快速找出指向某个 Region 的所有外部引用？             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  假设我们要回收 Region A：                                      │
│                                                                 │
│    Region B ────┐                                              │
│    Region C ────┼──→ Region A  (多个 Region 持有 A 的引用)    │
│    Region D ────┘                                              │
│                                                                 │
│  如果不知道这些引用在哪，就必须扫描整个堆 → 性能灾难！         │
│                                                                 │
│  解决方案：Remembered Set（RSet）                               │
│    - 每个 Region 维护一个 RSet                                  │
│    - RSet 记录"谁引用了我"（其他 Region 的哪些卡片）           │
│    - GC 时只需扫描 RSet，无需扫描整个堆                         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 1.2 RSet 更新的性能挑战

RSet 需要实时更新（引用关系改变时），但这带来性能问题：

```
┌─────────────────────────────────────────────────────────────────┐
│  场景：应用线程执行 obj.field = new_value                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  朴素方案（同步更新）：                                         │
│    1. 写屏障检测到跨 Region 引用                                │
│    2. 立即更新目标 Region 的 RSet                               │
│    3. 需要加锁（多线程并发更新同一 RSet）                       │
│    → 性能开销：~500ns/次，应用线程停顿                          │
│                                                                 │
│  G1 的优化方案（延迟更新）：                                     │
│    1. 写屏障只标记卡片为 dirty（~5ns）                          │
│    2. 后台线程异步处理脏卡，更新 RSet                           │
│    3. 批量处理 + 去重优化                                       │
│    → 性能提升：~100 倍                                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**核心优化思路**：
1. **延迟更新**：写屏障只记录，不立即处理
2. **批量处理**：积累一批脏卡后统一处理
3. **并发精炼**：后台线程异步处理，不阻塞应用
4. **去重优化**：同一张卡只处理一次

---

## 二、核心数据结构

### 2.1 G1RemSetScanState：扫描状态管理器

**问题**：GC 期间，多个 GC 线程如何并行扫描所有 Region 的 RSet？

```
┌─────────────────────────────────────────────────────────────────┐
│  G1RemSetScanState 的 5 个核心字段                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. _iter_states（Region 级别领取）                             │
│     - 类型：G1RemsetIterState volatile*                         │
│     - 大小：max_regions × sizeof(jint) = 2048 × 4B = 8 KB       │
│     - 作用：避免重复扫描同一 Region                             │
│     - 状态：Unclaimed(0) → Claimed(1) → Complete(2)             │
│     - 操作：CAS 原子领取，确保每个 Region 只被一个线程开始扫描  │
│                                                                 │
│  2. _iter_claims（卡片级别分块）                                │
│     - 类型：size_t volatile*                                    │
│     - 大小：2048 × 8B = 16 KB                                   │
│     - 作用：多线程协作扫描同一个 Region 的 RSet                 │
│     - 机制：每次领取 block_size 张卡，CAS 原子递增              │
│                                                                 │
│  3. _dirty_region_buffer（脏区域列表）                          │
│     - 类型：uint*                                               │
│     - 大小：2048 × 4B = 8 KB                                    │
│     - 作用：记录哪些 Region 的卡表需要清理                      │
│     - 使用：GC 结束后遍历此列表，清空卡表                       │
│                                                                 │
│  4. _in_dirty_region_buffer（去重标记）                         │
│     - 类型：IsDirtyRegionState*                                 │
│     - 大小：2048 × 1B = 2 KB                                    │
│     - 作用：快速判断 Region 是否已在脏列表中                    │
│     - 优化：避免重复添加，O(1) 查询                             │
│                                                                 │
│  5. _scan_top（扫描边界快照）                                   │
│     - 类型：HeapWord**                                          │
│     - 大小：2048 × 8B = 16 KB                                   │
│     - 作用：记录 GC 开始时每个 Region 的 top                    │
│     - 目的：不扫描 GC 开始后新分配的对象（SATB 语义）           │
│                                                                 │
│  总内存：~50 KB（固定开销）                                      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**核心流程示例**：

```cpp
// Region 领取（避免重复扫描）
bool claim_iter(uint region) {
    if (_iter_states[region] != Unclaimed) {
        return false;  // 已被领取
    }
    G1RemsetIterState res = Atomic::cmpxchg(Claimed, 
                                             &_iter_states[region], 
                                             Unclaimed);
    return (res == Unclaimed);  // CAS 成功则领取成功
}

// 卡片分块领取（协作扫描）
size_t iter_claimed_next(uint region, size_t step) {
    return Atomic::add(step, &_iter_claims[region]) - step;
    // 原子递增，返回之前的值（领取的起始位置）
}

// 添加脏区域（去重）
void add_dirty_region(uint region) {
    if (_in_dirty_region_buffer[region] == Dirty) {
        return;  // 已在列表中
    }
    
    bool marked = Atomic::cmpxchg(Dirty, 
                                   &_in_dirty_region_buffer[region], 
                                   Clean) == Clean;
    if (marked) {
        size_t idx = Atomic::add(1u, &_cur_dirty_region) - 1;
        _dirty_region_buffer[idx] = region;  // 加入列表
    }
}
```

### 2.2 G1ConcurrentRefine：并发精炼控制器

**问题**：如何平衡应用吞吐量与 RSet 更新延迟？

```
┌─────────────────────────────────────────────────────────────────┐
│  三色区域模型（Green/Yellow/Red Zone）                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  脏卡队列长度                                                   │
│       ↑                                                         │
│       │                                                         │
│  65   ├────────────────────── Red Zone（紧急）                  │
│       │  • 所有精炼线程运行                                     │
│       │  • Mutator 参与处理（应用线程帮忙）                     │
│       │  • 避免 GC 暂停时堆积过多脏卡                           │
│  39   ├────────────────────── Yellow Zone（渐进）               │
│       │  • 逐渐激活更多精炼线程                                 │
│       │  • 线程 n 激活线程 n+1                                  │
│       │  • 链式激活，渐进增加并发度                             │
│  13   ├────────────────────── Green Zone（缓存）                │
│       │  • 精炼线程空闲等待                                     │
│       │  • 利用热卡缓存效应                                     │
│       │  • 减少重复处理                                         │
│       │                                                         │
│       └──────────────────────────────────→ 时间                 │
│                                                                 │
│  默认值（标准环境）：                                            │
│    - Green Zone = 13                                            │
│    - Yellow Zone = 39                                           │
│    - Red Zone = 65                                              │
│    - 最大线程数 = 13                                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**核心字段**：

```cpp
class G1ConcurrentRefine : public CHeapObj<mtGC> {
    size_t _green_zone;           // 缓存区域上限
    size_t _yellow_zone;          // 渐进激活区域
    size_t _red_zone;             // 紧急区域上限
    size_t _min_yellow_zone_size; // Yellow Zone 最小大小
    
    G1ConcurrentRefineThreadControl _thread_control;  // 线程管理
};
```

**阈值计算**（每个线程不同的激活/去激活阈值）：

```cpp
size_t activation_threshold(uint worker_id) const {
    // Worker 0: threshold = 13（最早激活）
    // Worker 1: threshold = 15
    // ...
    // Worker 12: threshold = 39（最后激活）
    return _green_zone + worker_id * step_size;
}

size_t deactivation_threshold(uint worker_id) const {
    // 去激活阈值 = 激活阈值 - 缓冲值
    // 避免抖动（频繁激活/去激活）
    return activation_threshold(worker_id) - buffer;
}
```

### 2.3 G1ConcurrentRefineThread：精炼工作线程

**问题**：精炼线程如何高效工作？

```
┌─────────────────────────────────────────────────────────────────┐
│  G1ConcurrentRefineThread 工作循环                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  void run_service() {                                           │
│      while (!should_terminate()) {                              │
│          // 1. 等待激活                                         │
│          wait_for_completed_buffers();                          │
│          // ↓ 线程阻塞，不消耗 CPU                              │
│          // ↓ 脏卡队列长度 > activation_threshold 时被唤醒      │
│                                                                 │
│          // 2. 处理脏卡                                         │
│          while (true) {                                         │
│              if (!_cr->do_refinement_step(_worker_id)) {        │
│                  break;  // 队列长度 < deactivation_threshold   │
│              }                                                   │
│              // ↓ 处理一批脏卡，更新 RSet                       │
│          }                                                       │
│                                                                 │
│          // 3. 去激活                                           │
│          deactivate();                                          │
│          // ↓ 回到等待状态                                      │
│      }                                                           │
│  }                                                               │
│                                                                 │
│  特点：                                                          │
│    - 事件驱动（Monitor 等待/唤醒）                              │
│    - 链式激活（线程 n 激活线程 n+1）                            │
│    - 动态创建（按需创建，默认只创建线程 0）                     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**链式激活机制**：

```cpp
void maybe_activate_more_threads(uint worker_id, size_t num_cur_buffers) {
    // 当前脏卡数量超过下一线程的激活阈值？
    if (num_cur_buffers > activation_threshold(worker_id + 1)) {
        _thread_control.maybe_activate_next(worker_id);
        // ↓ 激活线程 worker_id + 1
    }
}
```

---

## 三、完整更新流程

### 3.1 写屏障：记录脏卡

**触发时机**：应用线程执行对象字段写入

```
┌─────────────────────────────────────────────────────────────────┐
│  写屏障流程（G1BarrierSet::write_ref_field_post）               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  void write_ref_field_post(void* field, oop new_val) {          │
│      // 1. 计算卡片地址                                         │
│      jbyte* card_ptr = card_table()->byte_for(field);           │
│      // ↓ field 地址右移 9 位 + byte_map_base                   │
│                                                                 │
│      // 2. 检查卡片状态                                         │
│      if (*card_ptr != dirty_card_val) {                         │
│          // 3. 标记为 dirty                                     │
│          *card_ptr = dirty_card_val;                            │
│          // ↓ 仅内存写，~2ns                                    │
│                                                                 │
│          // 4. 入队到线程本地 DCQ                                │
│          dirty_card_queue().enqueue(card_ptr);                  │
│          // ↓ 无锁入队，~3ns                                    │
│      }                                                           │
│  }                                                               │
│                                                                 │
│  性能开销：~5ns（极快）                                          │
│  目的：最小化应用线程影响                                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**DirtyCardQueue 结构**：

```
┌─────────────────────────────────────────────────────────────────┐
│  DirtyCardQueue（线程本地队列）                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  容量：默认 256 张卡                                             │
│  倒序写入：_index 从 capacity 递减到 0                           │
│                                                                 │
│      _buf                                                       │
│       ↓                                                         │
│       ┌────┬────┬────┬────┬────┬────────────────────────┐      │
│       │ C5 │ C4 │ C3 │ C2 │ C1 │        未使用           │      │
│       └────┴────┴────┴────┴────┴────────────────────────┘      │
│                                      ↑                          │
│                                   _index                        │
│                                                                 │
│  满（_index == 0）→ 提交到全局队列                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 并发精炼：异步处理脏卡

**触发条件**：脏卡队列长度超过阈值

```
┌─────────────────────────────────────────────────────────────────┐
│  refine_card_concurrently() 流程                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  void refine_card_concurrently(jbyte* card_ptr, uint worker_i) {│
│      // 1. 检查卡片是否仍为 dirty                               │
│      if (*card_ptr != dirty_card_val) {                         │
│          return;  // 已被其他线程处理                           │
│      }                                                           │
│                                                                 │
│      // 2. 检查 Region 类型                                     │
│      HeapRegion* r = heap_region_containing(card_ptr);          │
│      if (!r->is_old_or_humongous()) {                           │
│          return;  // 年轻代卡片，无需记录 RSet                  │
│      }                                                           │
│                                                                 │
│      // 3. 热卡缓存优化                                         │
│      if (_hot_card_cache->use_cache()) {                        │
│          card_ptr = _hot_card_cache->insert(card_ptr);          │
│          if (card_ptr == NULL) {                                │
│              return;  // 缓存了，稍后处理                       │
│          }                                                       │
│      }                                                           │
│                                                                 │
│      // 4. 确定扫描范围                                         │
│      HeapWord* start = addr_for(card_ptr);                      │
│      HeapWord* scan_limit = r->top();                           │
│      if (scan_limit <= start) {                                 │
│          return;  // 过期卡片，Region 已释放                    │
│      }                                                           │
│                                                                 │
│      // 5. 清理卡片（标记为 clean）                             │
│      *card_ptr = clean_card_val;                                │
│      OrderAccess::fence();  // 内存屏障，确保清理可见           │
│                                                                 │
│      // 6. 扫描卡片中的对象                                     │
│      MemRegion dirty_region(start, MIN2(scan_limit, end));      │
│      G1ConcurrentRefineOopClosure cl(this, worker_i);           │
│      r->oops_on_card_seq_iterate_careful(dirty_region, &cl);    │
│      // ↓ 找出所有跨 Region 引用，更新目标 Region 的 RSet       │
│  }                                                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**关键优化**：

1. **热卡缓存**：频繁写入的卡片缓存起来，延迟处理
2. **类型过滤**：年轻代卡片直接跳过（Young GC 会全量扫描）
3. **边界裁剪**：只扫描已分配的对象，不扫描空闲区域
4. **失败重试**：遇到并发分配的对象，重新标记脏卡并入队

### 3.3 GC 期间的 Update RS 阶段

**触发时机**：GC 暂停开始时，处理剩余脏卡队列

```
┌─────────────────────────────────────────────────────────────────┐
│  update_rem_set() 流程                                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  void update_rem_set(G1ParScanThreadState* pss, uint worker_i) {│
│      // 1. 处理热卡缓存                                         │
│      if (G1HotCardCache::default_use_cache()) {                 │
│          G1ScanObjsDuringUpdateRSClosure cl(...);               │
│          G1RefineCardClosure refine_cl(...);                    │
│          iterate_hcc_closure(&refine_cl, worker_i);             │
│      }                                                           │
│                                                                 │
│      // 2. 处理脏卡队列                                          │
│      G1ScanObjsDuringUpdateRSClosure cl(...);                   │
│      G1RefineCardClosure refine_cl(...);                        │
│      iterate_dirty_card_closure(&refine_cl, worker_i);          │
│      // ↓ 调用 refine_card_during_gc() 处理每张脏卡             │
│  }                                                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**refine_card_during_gc() 实现**：

```cpp
bool refine_card_during_gc(jbyte* card_ptr, 
                           G1ScanObjsDuringUpdateRSClosure* cl) {
    // 1. 检查卡片状态
    if (*card_ptr != dirty_card_val) {
        return false;  // 已处理
    }
    
    // 2. 标记为 clean + claimed
    *card_ptr = clean_card_val | claimed_card_val;
    
    // 3. 确定扫描范围（使用 _scan_top 快照）
    HeapWord* card_start = addr_for(card_ptr);
    uint region_idx = addr_to_region(card_start);
    
    _scan_state->add_dirty_region(region_idx);  // 记录脏区域
    HeapWord* scan_limit = _scan_state->scan_top(region_idx);
    
    if (scan_limit <= card_start) {
        return false;  // 超出扫描范围
    }
    
    // 4. 扫描卡片，找出指向 CSet 的引用
    MemRegion dirty_region(card_start, MIN2(scan_limit, card_end));
    HeapRegion* card_region = region_at(region_idx);
    cl->set_region(card_region);
    
    bool processed = card_region->oops_on_card_seq_iterate_careful(dirty_region, cl);
    // ↓ 找到指向 CSet 的引用 → 复制对象（Evacuation）
    
    return processed;
}
```

**与并发精炼的区别**：

| 维度 | 并发精炼 | GC 期间 Update RS |
|------|----------|-------------------|
| 时机 | GC 之外，并发执行 | GC 暂停期间 |
| 目的 | 更新 RSet（记录跨 Region 引用） | 找出指向 CSet 的引用 |
| 扫描范围 | Region 的 top（动态） | _scan_top（快照） |
| 处理结果 | 更新目标 Region 的 RSet | 复制对象到新 Region |

### 3.4 Scan RS 阶段：使用 RSet 扫描

**触发时机**：Update RS 之后，扫描 CSet 中每个 Region 的 RSet

```
┌─────────────────────────────────────────────────────────────────┐
│  scan_rem_set() 流程                                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  void scan_rem_set(G1ParScanThreadState* pss, uint worker_i) {  │
│      G1ScanObjsDuringScanRSClosure scan_cl(...);                │
│      G1ScanRSForRegionClosure cl(_scan_state, &scan_cl, ...);   │
│                                                                 │
│      // 遍历 CSet 中的每个 Region                               │
│      collection_set_iterate_from(&cl, worker_i);                │
│      // ↓ 调用 do_heap_region() 处理每个 Region                 │
│  }                                                               │
│                                                                 │
│  bool do_heap_region(HeapRegion* r) {                           │
│      assert(r->in_collection_set(), "Must be in CSet");         │
│                                                                 │
│      // 1. 领取 Region                                          │
│      if (_scan_state->claim_iter(r->hrm_index())) {             │
│          _scan_state->add_dirty_region(r->hrm_index());         │
│      }                                                           │
│                                                                 │
│      // 2. 扫描 Region 的 RSet                                  │
│      scan_rem_set_roots(r);                                     │
│      // ↓ 找出所有指向本 Region 的卡片                          │
│      // ↓ 扫描这些卡片，找出引用本 Region 的对象                │
│                                                                 │
│      // 3. 标记完成                                             │
│      if (_scan_state->set_iter_complete(r->hrm_index())) {      │
│          scan_strong_code_roots(r);  // 扫描代码根              │
│      }                                                           │
│  }                                                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**scan_rem_set_roots() 详解**：

```cpp
void scan_rem_set_roots(HeapRegion* r) {
    uint region_idx = r->hrm_index();
    
    // 使用卡片分块领取机制
    size_t block_size = G1RSetScanBlockSize;  // 默认 256 张卡
    
    HeapRegionRemSetIterator iter(r->rem_set());
    size_t card_index;
    
    // 原子领取卡片块
    size_t claimed_block = _scan_state->iter_claimed_next(region_idx, block_size);
    
    for (size_t current_card = 0; iter.has_next(card_index); current_card++) {
        // 超过当前块，领取下一块
        if (current_card >= claimed_block + block_size) {
            claimed_block = _scan_state->iter_claimed_next(region_idx, block_size);
        }
        
        // 跳过不属于当前块的卡片
        if (current_card < claimed_block) {
            _cards_skipped++;
            continue;
        }
        
        // 跳过脏卡（已在 Update RS 阶段处理）
        if (_ct->is_card_claimed(card_index) || _ct->is_card_dirty(card_index)) {
            continue;
        }
        
        // 检查扫描边界
        HeapWord* card_start = bot()->address_for_index(card_index);
        HeapWord* top = _scan_state->scan_top(region_idx_for_card);
        if (card_start >= top) {
            continue;  // 超出扫描范围
        }
        
        // 领取卡片并扫描
        claim_card(card_index, region_idx_for_card);
        MemRegion mr(card_start, MIN2(card_start + BOTConstants::N_words, top));
        scan_card(mr, region_idx_for_card);
    }
}
```

---

## 四、性能优化总结

### 4.1 延迟更新的性能收益

```
┌─────────────────────────────────────────────────────────────────┐
│  性能对比：同步更新 vs 延迟更新                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  同步更新（无优化）：                                            │
│    • 写屏障开销：~500ns（加锁 + RSet 更新）                     │
│    • 锁竞争：多线程更新同一 Region 的 RSet                      │
│    • 缓存失效：频繁修改 RSet 数据结构                           │
│                                                                 │
│  延迟更新（G1）：                                                │
│    • 写屏障开销：~5ns（仅标记脏卡 + 入队）                      │
│    • 性能提升：~100 倍                                          │
│                                                                 │
│  关键优化：                                                       │
│    1. 去重：同一张卡多次写入，只处理一次                        │
│    2. 批量：积累一批脏卡后统一处理，缓存友好                    │
│    3. 并发：后台线程处理，不阻塞应用                            │
│    4. 热卡缓存：频繁写入的卡片延迟处理                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 三色区域的性能平衡

```
┌─────────────────────────────────────────────────────────────────┐
│  三色区域的目标：平衡吞吐量与延迟                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Green Zone（缓存）：                                            │
│    • 目标：最大化缓存效应，减少重复处理                         │
│    • 行为：精炼线程空闲等待                                     │
│    • 性能影响：应用线程无干扰，吞吐量最高                       │
│                                                                 │
│  Yellow Zone（渐进）：                                           │
│    • 目标：渐进增加并发度，避免突然抢占 CPU                     │
│    • 行为：链式激活精炼线程                                     │
│    • 性能影响：轻微影响应用，但延迟可控                         │
│                                                                 │
│  Red Zone（紧急）：                                              │
│    • 目标：防止 GC 暂停时堆积过多脏卡                           │
│    • 行为：所有线程运行 + Mutator 参与                          │
│    • 性能影响：应用线程帮忙处理，吞吐量下降，但延迟最低         │
│                                                                 │
│  自适应调整：                                                     │
│    • 根据 Update RS 时间反馈调整区域边界                        │
│    • 目标：让大部分时间处于 Green Zone                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.3 内存开销

```
┌─────────────────────────────────────────────────────────────────┐
│  RSet 更新机制的内存开销（8GB 堆，2048 Region）                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  G1RemSetScanState：                                             │
│    • _iter_states: 2048 × 4B = 8 KB                             │
│    • _iter_claims: 2048 × 8B = 16 KB                            │
│    • _dirty_region_buffer: 2048 × 4B = 8 KB                     │
│    • _in_dirty_region_buffer: 2048 × 1B = 2 KB                  │
│    • _scan_top: 2048 × 8B = 16 KB                               │
│    小计：~50 KB                                                  │
│                                                                 │
│  每个 Region 的 RSet：                                           │
│    • HeapRegionRemSet：~320 bytes（初始）                       │
│    • 可扩展到 ~32 KB（大量跨 Region 引用时）                    │
│    • 平均：~1-2 KB                                              │
│    总计：2048 × 2KB ≈ 4 MB                                       │
│                                                                 │
│  总内存开销：                                                     │
│    • 固定开销：~50 KB                                           │
│    • RSet 数据：~4 MB（可变）                                   │
│    • 占堆比例：~0.05%                                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 五、关键源码位置

| 组件 | 文件 | 核心函数 |
|------|------|----------|
| **G1RemSet** | `g1RemSet.hpp/cpp` | `update_rem_set()`, `scan_rem_set()`, `refine_card_concurrently()` |
| **G1RemSetScanState** | `g1RemSet.cpp` | `claim_iter()`, `iter_claimed_next()`, `add_dirty_region()` |
| **G1ConcurrentRefine** | `g1ConcurrentRefine.hpp/cpp` | `do_refinement_step()`, `activation_threshold()` |
| **G1ConcurrentRefineThread** | `g1ConcurrentRefineThread.cpp` | `run_service()`, `activate()`, `deactivate()` |
| **G1BarrierSet** | `g1BarrierSet.inline.hpp` | `write_ref_field_post()` |
| **DirtyCardQueue** | `dirtyCardQueue.hpp/cpp` | `enqueue()`, `apply_closure_to_buffer()` |

---

## 六、面试级深度问答

### Q1: 为什么需要延迟更新 RSet？直接同步更新不行吗？

**A**: 同步更新有三大性能问题：

1. **锁竞争**：多线程更新同一 Region 的 RSet，需要加锁，开销 ~500ns
2. **缓存失效**：频繁修改 RSet 数据结构，缓存命中率低
3. **应用阻塞**：写屏障变慢，直接影响应用吞吐量

延迟更新的优化：
- 写屏障仅标记脏卡（~5ns），无锁无阻塞
- 后台线程批量处理，缓存友好
- 去重优化，同一张卡只处理一次

性能提升约 **100 倍**。

### Q2: 三色区域（Green/Yellow/Red）的设计目的是什么？

**A**: 平衡应用吞吐量与 GC 延迟：

- **Green Zone**：缓存效应，精炼线程空闲，应用吞吐量最高
- **Yellow Zone**：渐进激活线程，避免突然抢占 CPU
- **Red Zone**：紧急处理，Mutator 参与，防止 GC 暂停时堆积过多脏卡

核心思想：**让大部分时间处于 Green Zone，需要时渐进激活，紧急时全力以赴**。

### Q3: G1RemSetScanState 的 5 个字段分别解决什么问题？

**A**:

1. **_iter_states**：Region 级别领取，避免重复扫描同一 Region
2. **_iter_claims**：卡片级别分块，多线程协作扫描同一个 Region 的 RSet
3. **_dirty_region_buffer**：记录需要清理卡表的 Region 列表
4. **_in_dirty_region_buffer**：去重标记，避免重复添加同一 Region
5. **_scan_top**：扫描边界快照，不扫描 GC 开始后新分配的对象

### Q4: 并发精炼与 GC 期间的 Update RS 有什么区别？

**A**:

| 维度 | 并发精炼 | GC 期间 Update RS |
|------|----------|-------------------|
| **时机** | GC 之外，并发执行 | GC 暂停期间 |
| **目的** | 更新 RSet（记录跨 Region 引用） | 找出指向 CSet 的引用 |
| **扫描范围** | Region 的 top（动态） | _scan_top（快照） |
| **处理结果** | 更新目标 Region 的 RSet | 复制对象到新 Region |
| **卡片状态** | dirty → clean | dirty → clean + claimed |

### Q5: 热卡缓存（Hot Card Cache）的作用是什么？

**A**: 频繁写入的卡片缓存起来，延迟处理：

- **目的**：减少重复处理同一张卡
- **容量**：默认 1024 个 slots
- **阈值**：卡片被标记 dirty 次数 ≥ 4 才算"热"
- **收益**：热卡缓存命中率可达 30-50%，减少 ~30% 的 RSet 更新工作

---

## 七、GDB 验证脚本

### 7.1 观察 RSet 更新流程

```gdb
# observe_rset_update.gdb
# 观察脏卡处理和 RSet 更新

set pagination off
set logging file jvm-md/tmp-file/rset/observe_rset_update.log
set logging on

# 断点：refine_card_concurrently（并发精炼）
break G1RemSet::refine_card_concurrently
  commands
    printf "=== 并发精炼卡片 ===\n"
    printf "卡片地址: %p\n", card_ptr
    printf "卡片状态: %d (dirty=%d, clean=%d)\n", *card_ptr, 1, 0
    printf "Worker ID: %d\n", worker_i
    continue
  end

# 断点：refine_card_during_gc（GC 期间）
break G1RemSet::refine_card_during_gc
  commands
    printf "=== GC 期间精炼卡片 ===\n"
    printf "卡片地址: %p\n", card_ptr
    printf "卡片状态: %d\n", *card_ptr
    continue
  end

# 断点：add_reference（更新 RSet）
break HeapRegionRemSet::add_reference
  commands
    printf "=== 添加引用到 RSet ===\n"
    printf "来源 Region: %u\n", from
    printf "卡片索引: %u\n", card_index
    continue
  end

run
```

**预期输出**：

```
=== 并发精炼卡片 ===
卡片地址: 0x7f1234567890
卡片状态: 1 (dirty=1, clean=0)
Worker ID: 0
=== 添加引用到 RSet ===
来源 Region: 15
卡片索引: 128
...
=== GC 期间精炼卡片 ===
卡片地址: 0x7f1234567a00
卡片状态: 1
...
```

### 7.2 观察精炼线程激活/去激活

```gdb
# observe_refine_thread.gdb
# 观察精炼线程的工作状态

set pagination off

# 断点：线程激活
break G1ConcurrentRefineThread::activate
  commands
    printf "=== 精炼线程激活 ===\n"
    printf "Worker ID: %d\n", $_thread->_worker_id
    printf "当前脏卡队列长度: %lu\n", \
      G1BarrierSet::dirty_card_queue_set().completed_buffers_num()
    continue
  end

# 断点：线程去激活
break G1ConcurrentRefineThread::deactivate
  commands
    printf "=== 精炼线程去激活 ===\n"
    printf "Worker ID: %d\n", $_thread->_worker_id
    printf "当前脏卡队列长度: %lu\n", \
      G1BarrierSet::dirty_card_queue_set().completed_buffers_num()
    continue
  end

# 断点：do_refinement_step
break G1ConcurrentRefine::do_refinement_step
  commands
    printf "=== 执行精炼步骤 ===\n"
    printf "Worker ID: %d\n", worker_id
    continue
  end

run
```

**预期输出**：

```
=== 精炼线程激活 ===
Worker ID: 0
当前脏卡队列长度: 15
=== 执行精炼步骤 ===
Worker ID: 0
=== 执行精炼步骤 ===
Worker ID: 0
...
=== 精炼线程去激活 ===
Worker ID: 0
当前脏卡队列长度: 10
...
```

### 7.3 统计 RSet 更新性能

```gdb
# stat_rset_performance.gdb
# 统计 RSet 更新的性能数据

set pagination off

# 计数器
set $cards_refined = 0
set $cards_concurrent = 0
set $cards_during_gc = 0
set $start_time = 0

# 断点：GC 开始
break G1CollectedHeap::collect
  commands
    set $start_time = $_clock
    set $cards_concurrent = 0
    set $cards_during_gc = 0
    printf "=== GC 开始 ===\n"
    continue
  end

# 断点：并发精炼计数
break G1RemSet::refine_card_concurrently
  commands
    set $cards_concurrent = $cards_concurrent + 1
    continue
  end

# 断点：GC 期间精炼计数
break G1RemSet::refine_card_during_gc
  commands
    set $cards_during_gc = $cards_during_gc + 1
    continue
  end

# 断点：GC 结束
break G1CollectedHeap::collect
  if $start_time > 0
    set $elapsed = $_clock - $start_time
    printf "\n=== GC 结束统计 ===\n"
    printf "并发精炼卡片数: %d\n", $cards_concurrent
    printf "GC 期间精炼卡片数: %d\n", $cards_during_gc
    printf "总耗时: %f 秒\n", $elapsed / 1000000.0
    set $start_time = 0
  end
  continue

run
```

**预期输出**：

```
=== GC 开始 ===
...
=== GC 结束统计 ===
并发精炼卡片数: 1250
GC 期间精炼卡片数: 380
总耗时: 0.045 秒
...
```

---

## 八、总结

### 核心设计思想

```
┌─────────────────────────────────────────────────────────────────┐
│  G1RemSet 更新机制的三大核心思想                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 延迟更新（Deferred Update）                                 │
│     • 写屏障只记录，不立即处理                                  │
│     • 性能提升：~100 倍                                         │
│                                                                 │
│  2. 并发精炼（Concurrent Refinement）                           │
│     • 后台线程异步处理脏卡                                      │
│     • 三色区域模型平衡吞吐量与延迟                              │
│                                                                 │
│  3. 协作扫描（Cooperative Scanning）                            │
│     • Region 级别领取避免重复                                   │
│     • 卡片级别分块提高并行度                                    │
│     • 扫描边界快照保证一致性                                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 性能数据（标准环境）

| 操作 | 延迟 | 频率 | 总开销 |
|------|------|------|--------|
| 写屏障（标记脏卡） | ~5ns | 每次对象写入 | 极小 |
| 并发精炼（处理脏卡） | ~50μs/卡 | 后台运行 | 不影响应用 |
| GC 期间 Update RS | ~50μs/卡 | GC 暂停 | 可控 |
| Scan RS | ~100ns/引用 | GC 暂停 | 可控 |

### 关键参数

```bash
# 并发精炼线程数（默认 = 并行 GC 线程数）
-XX:G1ConcRefinementThreads=13

# 脏卡队列容量（每个线程）
-XX:G1UpdateBufferSize=256

# 热卡缓存大小
-XX:G1HotCardCacheSize=1024

# 日志开关
-Xlog:gc+refine=debug   # 精炼线程活动
-Xlog:gc+remset=trace   # RSet 更新详情
```

---

**下一步分析**：G1RemSet 的 RSet 数据结构详解（HeapRegionRemSet、SparsePRT、PerRegionTable）
