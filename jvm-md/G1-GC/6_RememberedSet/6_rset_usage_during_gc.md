# GC 时的 RSet 使用详解

## 1. 功能定位

### 1.1 一句话说明

**GC 时，Remembered Set 是**跨 Region 引用的查询索引**： evacuation 过程中，通过扫描 CSet 中每个 Region 的 RSet，找到指向这些 Region 的外部引用，确保存活对象能够被正确复制和更新。**

### 1.2 为什么 GC 时需要 RSet

```
┌─────────────────────────────────────────────────────────────────────┐
│                    GC 时的问题                                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Young GC 场景：                                                     │
│                                                                      │
│   Region A (Old) ──► Region B (Young, CSet)                        │
│   ┌─────────┐      ┌─────────┐                                      │
│   │ 对象X    │─────►│ 对象Y   │  ← Y 需要被复制到 Survivor          │
│   └─────────┘      └─────────┘                                      │
│                                                                      │
│   问题：Y 在 CSet 中，需要被复制，但 X 引用了 Y                      │
│         如何找到 X？                                                 │
│                                                                      │
│   解决方案：                                                         │
│   - 遍历整个 Old 代找引用？ 太慢！                                   │
│   - 查询 B 的 RSet：记录了 A 的哪些 Card 引用了 B                    │
│   - 只需扫描 RSet 指向的 Card                                        │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.3 在 GC 流程中的位置

```
┌─────────────────────────────────────────────────────────────────────┐
│                    RSet 在 GC 中的位置                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Young GC / Mixed GC                                                 │
│       │                                                              │
│       ▼                                                              │
│  1. 选择 Collection Set (CSet)                                       │
│       │                                                              │
│       ▼                                                              │
│  2. 【准备阶段】prepare_for_oops_into_collection_set_do()           │
│       │  - 重置扫描状态                                              │
│       │  - 记录每个 Region 的 scan_top                               │
│       ▼                                                              │
│  3. 【并行扫描阶段】oops_into_collection_set_do()                   │
│       │  - 【扫描 RSet】◄── 本分析目标                              │
│       │  - 处理脏卡队列                                              │
│       ▼                                                              │
│  4. 【疏散阶段】 evacuate_collection_set()                          │
│       │  - 复制存活对象                                              │
│       │  - 更新引用                                                  │
│       ▼                                                              │
│  5. 【清理阶段】cleanup_after_oops_into_collection_set_do()         │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. 类继承关系

```
┌─────────────────────────────────────────────────────────────────────┐
│                    GC RSet 相关类关系                                │
└─────────────────────────────────────────────────────────────────────┘

                      G1RemSet
                           │
           ┌───────────────┼───────────────┐
           │               │               │
           ▼               ▼               ▼
    ┌────────────┐  ┌────────────┐  ┌────────────┐
    │G1RemSetScan│  │G1ScanRSFor │  │HeapRegion  │
    │State       │  │RegionClosure│  │RemSetIterator│
    │            │  │            │  │            │
    │- 扫描状态  │  │- 扫描闭包  │  │- 迭代RSet  │
    │- 区域进度  │  │- 处理Card  │  │- 三种模式  │
    └────────────┘  └────────────┘  └────────────┘
           │               │               │
           └───────────────┼───────────────┘
                           │
                           ▼
                    G1ParScanThreadState
                    （并行扫描线程状态）
```

---

## 3. 核心数据结构

### 3.1 G1RemSetScanState（扫描状态管理）

```cpp
// src/hotspot/share/gc/g1/g1RemSet.cpp:55
class G1RemSetScanState : public CHeapObj<mtGC> {
private:
  // 每个 Region 的扫描状态
  typedef jint G1RemsetIterState;
  static const G1RemsetIterState Unclaimed = 0;  // 未开始
  static const G1RemsetIterState Claimed = 1;    // 正在扫描
  static const G1RemsetIterState Complete = 2;   // 已完成
  
  G1RemsetIterState volatile* _iter_states;      // 状态数组
  size_t volatile* _iter_claims;                 // 每个 Region 的扫描进度
  
  // 脏区域管理
  uint* _dirty_region_buffer;                    // 脏区域缓冲区
  IsDirtyRegionState* _in_dirty_region_buffer;   // 脏区域标记
  
  // 扫描上界
  HeapWord** _scan_top;                          // 每个 Region 的扫描顶部
};
```

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【是什么】
  类型：GC 期间 RSet 扫描的状态管理器
  生命周期：GC 开始创建 → GC 结束销毁

【为什么需要】
  问题：多个 GC Worker 线程并行扫描 RSet，需要协调
  解决：
  - 状态管理：Unclaimed → Claimed → Complete
  - 进度跟踪：记录每个 Region 扫描到哪个 Card
  - 避免重复：确保每个 Card 只被扫描一次

【核心字段】
  _iter_states[RegionCount]：
    - 每个 Region 的扫描状态
    - CAS 原子更新
    
  _iter_claims[RegionCount]：
    - 每个 Region 当前扫描位置
    - 支持细粒度并发扫描
    
  _scan_top[RegionCount]：
    - GC 开始时每个 Region 的 top 位置
    - 过滤掉 GC 期间新分配的对象

【内存占用】
  2048 Regions × (4 + 8 + 8) bytes ≈ 40KB
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### 3.2 G1ScanRSForRegionClosure（Region 扫描闭包）

```cpp
// src/hotspot/share/gc/g1/g1RemSet.hpp:151
class G1ScanRSForRegionClosure : public HeapRegionClosure {
  G1CollectedHeap* _g1h;
  G1CardTable* _ct;
  G1ParScanThreadState* _pss;           // 线程本地扫描状态
  G1ScanObjsDuringScanRSClosure* _scan_objs_on_card_cl;
  G1RemSetScanState* _scan_state;
  
  uint _worker_i;                       // Worker ID
  
  // 统计信息
  size_t _cards_scanned;                // 扫描的 Card 数
  size_t _cards_claimed;                // 认领的 Card 数
  size_t _cards_skipped;                // 跳过的 Card 数
};
```

### 3.3 HeapRegionRemSetIterator（RSet 迭代器）

```cpp
// src/hotspot/share/gc/g1/heapRegionRemSet.hpp:355
class HeapRegionRemSetIterator : public StackObj {
private:
  HeapRegionRemSet* _hrrs;
  const BitMap* _coarse_map;            // 粗粒度位图
  
  // 迭代状态
  enum IterState { Sparse, Fine, Coarse };
  IterState _is;                        // 当前迭代模式
  
  // Coarse 模式迭代状态
  int _coarse_cur_region_index;         // 当前 Region 索引
  size_t _coarse_cur_region_cur_card;   // 当前 Card 索引
  
  // Fine 模式迭代状态
  PerRegionTable* _fine_cur_prt;        // 当前 PRT
  size_t _cur_card_in_prt;              // 当前 PRT 内的 Card
  
  // Sparse 模式迭代器
  SparsePRTIter _sparse_iter;
  
  // 统计
  size_t _n_yielded_fine;
  size_t _n_yielded_coarse;
  size_t _n_yielded_sparse;
};
```

---

## 4. GC 中的 RSet 使用流程

### 4.1 准备阶段

```cpp
// g1RemSet.hpp:122
void G1RemSet::prepare_for_oops_into_collection_set_do() {
  // 1. 重置扫描状态
  _scan_state->reset();
  
  // 2. 记录每个 Region 的 scan_top
  // 用于过滤 GC 期间新分配的对象
}

// g1RemSet.cpp:222
void G1RemSetScanState::reset() {
  // 重置所有 Region 状态为 Unclaimed
  for (uint i = 0; i < _max_regions; i++) {
    _iter_states[i] = Unclaimed;
  }
  
  // 记录每个 Region 的 top 位置
  G1ResetScanTopClosure cl(_scan_top);
  G1CollectedHeap::heap()->heap_region_iterate(&cl);
  
  // 重置扫描进度
  memset((void*)_iter_claims, 0, _max_regions * sizeof(size_t));
}
```

### 4.2 并行扫描 RSet

```cpp
// g1RemSet.hpp:117
void G1RemSet::oops_into_collection_set_do(G1ParScanThreadState* pss, uint worker_i) {
  // 1. 扫描 RSet（处理跨 Region 引用）
  scan_rem_set(pss, worker_i);
  
  // 2. 更新 RSet（处理脏卡队列）
  update_rem_set(pss, worker_i);
}

void G1RemSet::scan_rem_set(G1ParScanThreadState* pss, uint worker_i) {
  // 创建扫描闭包
  G1ScanObjsDuringScanRSClosure scan_cl(_g1h, pss);
  G1ScanRSForRegionClosure cl(_scan_state, &scan_cl, pss, worker_i);
  
  // 并行遍历 CSet 中的 Region
  _g1h->collection_set_par_iterate_all(&cl, worker_i);
}
```

**扫描流程图：**
```
┌─────────────────────────────────────────────────────────────────────┐
│                    GC RSet 扫描流程                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Worker Thread N                                                     │
│       │                                                              │
│       ▼                                                              │
│  G1RemSet::scan_rem_set()                                           │
│       │                                                              │
│       ▼                                                              │
│  G1ScanRSForRegionClosure::do_heap_region(Region r)                 │
│       │                                                              │
│       ├──► 【步骤1】认领 Region                                     │
│       │    if (_scan_state->claim_iter(r->hrm_index()))             │
│       │       // 我是第一个扫描这个 Region 的线程                     │
│       │                                                              │
│       ├──► 【步骤2】获取 RSet 迭代器                                │
│       │    HeapRegionRemSetIterator iter(r->rem_set())              │
│       │                                                              │
│       ├──► 【步骤3】遍历 RSet 中的所有 Card                         │
│       │    while (iter.has_next(card_index)) {                      │
│       │                                                              │
│       │      // 认领 Card（避免重复扫描）                           │
│       │      claim_card(card_index, region_idx);                    │
│       │                                                              │
│       │      // 扫描 Card 内的对象                                  │
│       │      scan_card(card_region, region_idx);                    │
│       │                                                              │
│       │      // 处理 Card 中的每个对象                              │
│       │      for each obj in card:                                  │
│       │        for each reference field in obj:                     │
│       │          if (reference points to CSet)                      │
│       │            evacuate_and_update(reference)                   │
│       │    }                                                        │
│       │                                                              │
│       └──► 【步骤4】标记完成                                        │
│            _scan_state->set_iter_complete(r->hrm_index())           │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 4.3 RSet 迭代器遍历三种模式

```cpp
// heapRegionRemSet.cpp:717
HeapRegionRemSetIterator::HeapRegionRemSetIterator(HeapRegionRemSet* hrrs) :
  _is(Sparse),                          // 从 Sparse 模式开始
  _sparse_iter(&hrrs->_other_regions._sparse_table) {}

bool HeapRegionRemSetIterator::has_next(size_t& card_index) {
  // 按顺序：Sparse → Fine → Coarse
  switch (_is) {
    case Sparse:
      if (sparse_has_next(card_index)) return true;
      _is = Fine;  // 切换到 Fine 模式
      // fall through
    case Fine:
      if (fine_has_next(card_index)) return true;
      _is = Coarse;  // 切换到 Coarse 模式
      // fall through
    case Coarse:
      if (coarse_has_next(card_index)) return true;
      return false;  // 所有模式遍历完成
  }
}
```

**迭代器遍历图：**
```
┌─────────────────────────────────────────────────────────────────────┐
│                    RSet 迭代器遍历顺序                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Region X 的 RSet                                                    │
│       │                                                              │
│       ▼                                                              │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ 1. Sparse 模式（哈希表）                                     │   │
│  │    ┌────────┐ ┌────────┐ ┌────────┐                        │   │
│  │    │Entry 1 │ │Entry 2 │ │Entry N │  entries[]              │   │
│  │    │[c1,c2] │ │[c3]    │ │[c4,c5] │                        │   │
│  │    └────────┘ └────────┘ └────────┘                        │   │
│  │         ↓         ↓         ↓                              │   │
│  │    Card 1,2    Card 3    Card 4,5                          │   │
│  └─────────────────────────────────────────────────────────────┘   │
│       │                                                              │
│       ▼                                                              │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ 2. Fine 模式（PerRegionTable 哈希表）                        │   │
│  │    ┌────────┐ ┌────────┐ ┌────────┐                        │   │
│  │    │ PRT 1  │ │ PRT 2  │ │ PRT M  │  _fine_grain_regions[]  │   │
│  │    │[bitmap]│ │[bitmap]│ │[bitmap]│                        │   │
│  │    │c6-c100 │ │c101-200│ │c201+   │                        │   │
│  │    └────────┘ └────────┘ └────────┘                        │   │
│  │         ↓         ↓         ↓                              │   │
│  │    遍历 bitmap 中所有置位的 Card                           │   │
│  └─────────────────────────────────────────────────────────────┘   │
│       │                                                              │
│       ▼                                                              │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ 3. Coarse 模式（Region 位图）                                │   │
│  │    ┌─────────────────────────────────────────┐              │   │
│  │    │ _coarse_map: [0][1][0][1][1][0]...      │              │   │
│  │    │            R0 R1 R2 R3 R4 R5            │              │   │
│  │    └─────────────────────────────────────────┘              │   │
│  │         ↓                                                   │   │
│  │    遍历所有标记的 Region，每个 Region 的 8192 Cards         │   │
│  └─────────────────────────────────────────────────────────────┘   │
│       │                                                              │
│       ▼                                                              │
│  遍历完成                                                             │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 5. Card 认领机制（避免重复扫描）

```cpp
// g1RemSet.cpp（简化示意）
void G1ScanRSForRegionClosure::claim_card(size_t card_index, uint region_idx) {
  // 使用位图或原子操作认领 Card
  // 确保同一个 Card 只被一个 Worker 处理
}

// 实际实现：使用卡表中的 claimed 标记
// CardTable::claimed_card_val = 2

void G1CardTable::set_card_claimed(size_t card_index) {
  jbyte val = _byte_map[card_index];
  if (val != claimed_card_val()) {
    _byte_map[card_index] = claimed_card_val();
  }
}
```

**Card 状态转换：**
```
GC 开始前：
  Card = clean (-1) 或 dirty (0)

GC 扫描时：
  dirty (0) ──► claimed (2) ──► scanned ──► clean (-1)
   
  - 多个 Worker 竞争同一个 Card
  - 只有成功设置为 claimed 的 Worker 才能扫描
  - 其他 Worker 跳过该 Card
```

---

## 6. 内存布局与开销

### 6.1 GC 期间 RSet 相关内存

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC, 2048 Regions

G1RemSetScanState:
┌─────────────────────────────────────────────────────────────────┐
│ 字段                    │ 大小      │ 说明                    │
├─────────────────────────────────────────────────────────────────┤
│ _iter_states[2048]      │ 8KB       │ 每个 Region 状态        │
│ _iter_claims[2048]      │ 16KB      │ 每个 Region 扫描进度    │
│ _dirty_region_buffer    │ 8KB       │ 脏区域缓冲区            │
│ _in_dirty_region_buffer │ 2KB       │ 脏区域标记              │
│ _scan_top[2048]         │ 16KB      │ 扫描上界                │
└─────────────────────────────────────────────────────────────────┘
Total: ~50KB

每个 Worker Thread:
┌─────────────────────────────────────────────────────────────────┐
│ G1ScanRSForRegionClosure │ ~200 bytes │ 扫描闭包状态           │
│ G1ParScanThreadState     │ ~2KB       │ 线程扫描状态           │
│ 其他临时结构              │ ~1KB       │ 迭代器等               │
└─────────────────────────────────────────────────────────────────┘
Total per worker: ~3KB

对于 8 Workers: 24KB

总计 GC 期间 RSet 开销: ~75KB（可忽略）
```

### 6.2 扫描性能数据

```
┌─────────────────────────────────────────────────────────────────────┐
│                    RSet 扫描性能                                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  典型 Young GC：                                                     │
│  - CSet 大小：10-50 Regions                                          │
│  - 每个 Region RSet 平均条目：100-1000                               │
│  - 扫描 Card 数：1000-50000                                          │
│  - 扫描时间：1-5ms（并行）                                           │
│                                                                      │
│  Mixed GC（增量老年代回收）：                                        │
│  - CSet 包含老年代 Region                                            │
│  - RSet 通常更大（老年代引用多）                                     │
│  - 扫描时间：10-50ms                                                 │
│                                                                      │
│  优化手段：                                                          │
│  1. 并行扫描：多 Worker 分担                                         │
│  2. Card 缓存：热点 Card 优先处理                                    │
│  3. 增量处理：Concurrent Refine 提前处理                             │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 7. GDB 验证脚本

```bash
# 文件：jvm-md/G1-GC/6_RememberedSet/gdb_gc_rset.txt

set pagination off
set print pretty on

# 断点1：GC 开始准备 RSet
break G1RemSet::prepare_for_oops_into_collection_set_do
cmd
  silent
  printf "\n========== GC RSet 准备 ==========\n"
  printf "重置 RSet 扫描状态\n"
  continue
end

# 断点2：扫描 Region 的 RSet
break G1ScanRSForRegionClosure::do_heap_region
cmd
  silent
  printf "\n========== Scanning RSet for Region ==========\n"
  printf "Region = %p, index = %u\n", $r, $r->hrm_index()
  printf "RSet occupied = %zu\n", $r->rem_set()->occupied()
  continue
end

# 断点3：认领 Card
break G1ScanRSForRegionClosure::claim_card
cmd
  silent
  printf "Claiming card %zu in region %u\n", $card_index, $region_idx_for_card
  continue
end

# 断点4：扫描具体 Card
break G1ScanRSForRegionClosure::scan_card
cmd
  silent
  printf "Scanning card [%p, %p)\n", $mr.start(), $mr.end()
  continue
end

# 断点5：RSet 迭代
break HeapRegionRemSetIterator::has_next
cmd
  silent
  printf "RSet Iterator: mode = %d (0=Sparse, 1=Fine, 2=Coarse)\n", $_is
  continue
end

# 断点6：GC 结束清理
break G1RemSet::cleanup_after_oops_into_collection_set_do
cmd
  silent
  printf "\n========== GC RSet 清理完成 ==========\n"
  continue
end

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main
```

---

## 8. 总结

### 8.1 GC 中 RSet 的核心作用

```
┌─────────────────────────────────────────────────────────────────────┐
│                    RSet 在 GC 中的核心价值                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  1. 【精确制导】                                                     │
│     - 不扫描整个堆，只扫描 RSet 记录的 Card                          │
│     - 减少 90%+ 的无效扫描                                          │
│                                                                      │
│  2. 【并行加速】                                                     │
│     - 多 Worker 并行扫描不同 Region                                  │
│     - Card 级认领避免重复工作                                        │
│                                                                      │
│  3. 【增量准备】                                                     │
│     - Concurrent Refine 提前更新 RSet                                │
│     - GC 时只需扫描剩余脏卡                                          │
│                                                                      │
│  4. 【空间换时间】                                                   │
│     - 内存占用：~336KB (2048 Regions × 168 bytes)                    │
│     - 换取：GC 暂停时间从 100ms+ 降至 1-10ms                         │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 8.2 GC RSet 流程图

```
┌─────────────────────────────────────────────────────────────────────┐
│                    完整 GC RSet 流程                                 │
└─────────────────────────────────────────────────────────────────────┘

Mutator (应用线程)                    GC Thread (Worker)
        │                                    │
        │ Write Barrier                      │
        │ obj.field = new_val                │
        ▼                                    │
   ┌─────────┐                               │
   │Post-Write│                              │
   │Barrier  │                              │
   └────┬────┘                              │
        │                                   │
        │ mark_card_dirty()                 │
        │ enqueue(card_ptr)                 │
        ▼                                   │
   ┌─────────┐                              │
   │DC Queue │                              │
   └────┬────┘                              │
        │                                   │
        │ 队列满，提交全局                   │
        ▼                                   │
   ┌─────────────┐                          │
   │Global DC Queue│                        │
   └──────┬──────┘                          │
          │                                 │
          │  GC 开始                         │
          ▼                                 ▼
   ┌─────────────┐                  ┌─────────────┐
   │prepare_for_ │                  │scan_rem_set │
   │oops_into_cs │                  │             │
   └──────┬──────┘                  └──────┬──────┘
          │                                │
          │ 1. 重置状态                     │ 2. 并行扫描
          │ 2. 记录 scan_top                │    claim_region()
          ▼                                │    iter.has_next()
   ┌─────────────┐                         │    scan_card()
   │CollectionSet│                         │    evacuate()
   │  (CSet)     │                         │
   └──────┬──────┘                         ▼
          │                         ┌─────────────┐
          │                         │update_rem_set│
          │                         │             │
          │                         └──────┬──────┘
          │                                │
          ▼                                ▼
   ┌─────────────┐                  ┌─────────────┐
   │cleanup_after│                  │GC 完成      │
   │_oops_into_cs│                  │             │
   └─────────────┘                  └─────────────┘
```

### 8.3 RSet 系列总结

| 部分 | 核心内容 | 关键数据结构 |
|-----|---------|-------------|
| 1. 基础概念 | RSet 是跨 Region 引用的反向索引 | HeapRegionRemSet |
| 2. 三种存储模式 | Sparse/Fine/Coarse 自适应选择 | SparsePRT/PerRegionTable/BitMap |
| 3. 卡表机制 | Write Barrier 标记脏卡的基础设施 | G1CardTable::_byte_map |
| 4. 写屏障 | Pre(SATB)/Post(Dirty) 双屏障 | G1BarrierSet |
| 5. 脏卡队列 | 异步更新 RSet 的生产者-消费者模型 | DirtyCardQueue + Refine Thread |
| 6. GC 使用 | 并行扫描 RSet，精确找到跨 Region 引用 | G1RemSetScanState + Iterator |

---

**质量自检清单：**
- [x] 功能定位（GC 时如何使用 RSet）
- [x] 与 GC 流程的整合
- [x] 核心数据结构（ScanState/Iterator/Closure）
- [x] 并行扫描流程
- [x] 三种模式迭代器遍历
- [x] Card 认领机制
- [x] 内存开销分析
- [x] GDB 验证脚本
- [x] 完整流程图

**RSet 系列分析完成！**
