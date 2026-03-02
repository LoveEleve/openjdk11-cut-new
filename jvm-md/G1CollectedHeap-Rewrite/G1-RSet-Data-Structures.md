# G1 RSet 数据结构：HeapRegionRemSet、SparsePRT、PerRegionTable

> **分析目标**：深入理解 G1 如何存储跨 Region 引用关系，以及三层存储架构（Sparse/Fine/Coarse）的设计权衡。
>
> **标准环境**：-Xms8g -Xmx8g -XX:+UseG1GC，G1 Region = 4MB，每 Region 8192 张卡

---

## 一、问题引入：如何高效存储跨 Region 引用？

### 1.1 核心挑战

```
┌─────────────────────────────────────────────────────────────────┐
│  问题：如何为每个 Region 维护"谁引用了我"的信息？              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  假设 Region A 有如下引用关系：                                 │
│                                                                 │
│    Region B 的第 5 张卡 ────┐                                  │
│    Region C 的第 128 张卡 ──┼──→ Region A                      │
│    Region D 的第 42 张卡 ───┘                                  │
│    ...                                                          │
│                                                                 │
│  需求：                                                          │
│    1. 快速查询：给定卡片，判断是否在 RSet 中                   │
│    2. 空间高效：避免为每个 Region 维护大表                     │
│    3. 动态适应：引用少时占用少，引用多时容量大                 │
│                                                                 │
│  G1 的解决方案：三层存储架构                                     │
│    - Sparse PRT（稀疏表）：少量引用，紧凑存储                  │
│    - Fine PRT（精细表）：中等引用，位图存储                    │
│    - Coarse BitMap（粗糙位图）：大量引用，一个 Region 一位     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 1.2 设计权衡

```
┌─────────────────────────────────────────────────────────────────┐
│  三层存储架构的权衡                                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  存储效率 vs 查询效率：                                          │
│                                                                 │
│  ┌───────────────┬─────────────┬─────────────┬─────────────┐  │
│  │ 层级          │ 存储效率    │ 查询效率    │ 适用场景    │  │
│  ├───────────────┼─────────────┼─────────────┼─────────────┤  │
│  │ Sparse PRT    │ 最高        │ O(n) 线性  │ 引用极少    │  │
│  │ Fine PRT      │ 中等        │ O(1) 位图  │ 引用适中    │  │
│  │ Coarse BitMap │ 最低        │ O(1) 位图  │ 引用极多    │  │
│  └───────────────┴─────────────┴─────────────┴─────────────┘  │
│                                                                 │
│  示例（Region A 的 RSet）：                                      │
│                                                                 │
│  场景 1：只有 2 个其他 Region 引用 A                             │
│    → Sparse PRT：~100 bytes（紧凑）                             │
│    → Fine PRT：~8 KB × 2 = 16 KB（浪费）                        │
│    → 选择：Sparse PRT                                           │
│                                                                 │
│  场景 2：有 100 个其他 Region 引用 A                             │
│    → Sparse PRT：~5 KB（查询慢）                                │
│    → Fine PRT：~8 KB × 100 = 800 KB（过大）                     │
│    → Coarse BitMap：256 bytes（256 位）                         │
│    → 选择：Coarse BitMap                                        │
│                                                                 │
│  场景 3：有 10 个其他 Region，每个 Region 100 张卡引用 A         │
│    → Sparse PRT：~1 KB（卡片溢出）                              │
│    → Fine PRT：~8 KB × 10 = 80 KB（适中）                       │
│    → 选择：Fine PRT                                             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 二、整体架构

### 2.1 HeapRegionRemSet：顶层封装

```
┌─────────────────────────────────────────────────────────────────┐
│  HeapRegionRemSet 结构（每个 Region 一个）                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  class HeapRegionRemSet {                                       │
│      G1BlockOffsetTable* _bot;    // 对象定位器                 │
│      G1CodeRootSet _code_roots;   // 代码根引用                 │
│      Mutex _m;                    // 保护锁                     │
│      OtherRegionsTable _other_regions;  // 其他 Region 引用     │
│      RemSetState _state;          // 状态：Untracked/Updating/Complete │
│  };                                                              │
│                                                                 │
│  内存布局（标准环境）：                                          │
│    - 固定开销：~100 bytes                                       │
│    - OtherRegionsTable：动态（~320 bytes 初始）                 │
│    - 总计：~420 bytes（初始）                                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**三种状态**：

```cpp
enum RemSetState {
    Untracked,  // 不追踪（新生代 Region）
    Updating,   // 更新中（并发标记期间）
    Complete    // 完整（老年代 Region）
};

// 状态转换
set_state_updating()  // 并发标记开始时，Untracked → Updating
set_state_complete()  // 并发标记结束时，Updating → Complete
set_state_empty()     // Region 回收时，→ Untracked
```

**核心方法**：

```cpp
// 添加引用（并发）
void add_reference(OopOrNarrowOopStar from, uint tid) {
    RemSetState state = _state;
    if (state == Untracked) {
        return;  // 不追踪
    }
    _other_regions.add_reference(from, tid);
}

// 查询引用是否存在
bool contains_reference(OopOrNarrowOopStar from) const {
    return _other_regions.contains_reference(from);
}

// 统计占用卡片数
size_t occupied() {
    MutexLockerEx x(&_m, Mutex::_no_safepoint_check_flag);
    return _other_regions.occupied();
}
```

### 2.2 OtherRegionsTable：三层存储核心

```
┌─────────────────────────────────────────────────────────────────┐
│  OtherRegionsTable 结构（RSet 核心数据结构）                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  class OtherRegionsTable {                                      │
│      G1CollectedHeap* _g1h;                                     │
│      Mutex* _m;                   // 保护锁                     │
│      HeapRegion* _hr;             // 所属 Region                │
│                                                                 │
│      // Layer 1: Sparse PRT（稀疏表）                           │
│      SparsePRT _sparse_table;     // 少量引用时的紧凑存储       │
│                                                                 │
│      // Layer 2: Fine PRT（精细表）                             │
│      PerRegionTable** _fine_grain_regions;  // 哈希表           │
│      size_t _n_fine_entries;      // Fine PRT 条目数            │
│      PerRegionTable* _first_all_fine_prts;  // 双向链表头       │
│      PerRegionTable* _last_all_fine_prts;   // 双向链表尾       │
│                                                                 │
│      // Layer 3: Coarse BitMap（粗糙位图）                      │
│      CHeapBitMap _coarse_map;     // 每个 Region 一位           │
│      size_t _n_coarse_entries;    // Coarse 条目数              │
│  };                                                              │
│                                                                 │
│  内存布局（标准环境，2048 Region）：                            │
│    - SparsePRT：~320 bytes（初始）                              │
│    - Fine PRT 哈希表：~8 KB（指针数组）                         │
│    - Coarse BitMap：256 bytes（2048 位）                        │
│    - 固定开销：~9 KB                                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**三层存储示意图**：

```
┌─────────────────────────────────────────────────────────────────┐
│  Region A 的 RSet（OtherRegionsTable）                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  引用来源：Region B(卡5,卡10) / Region C(卡128) / Region D(全部)│
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ Layer 1: Sparse PRT（优先使用）                           │  │
│  │ ┌────────────────────────────────────────────────────┐   │  │
│  │ │ Region B → [卡5, 卡10]                              │   │  │
│  │ │ Region C → [卡128]                                  │   │  │
│  │ │ ...                                                 │   │  │
│  │ │ 容量：~4 张卡/Region，总 Entry 数受限于表大小      │   │  │
│  │ └────────────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────────┘  │
│                    ↓ 溢出降级                                   │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ Layer 2: Fine PRT（哈希表）                               │  │
│  │ ┌────────────────────────────────────────────────────┐   │  │
│  │ │ Hash Bucket 0 → NULL                               │   │  │
│  │ │ Hash Bucket 1 → PRT(Region B) → 位图[卡5,卡10]    │   │  │
│  │ │ Hash Bucket 2 → NULL                               │   │  │
│  │ │ Hash Bucket 3 → PRT(Region C) → 位图[卡128]       │   │  │
│  │ │ ...                                                 │   │  │
│  │ │ 每个 PRT：~8 KB 位图（8192 张卡）                   │   │  │
│  │ │ 最大 PRT 数量：受限于 _max_fine_entries            │   │  │
│  │ └────────────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────────┘  │
│                    ↓ 溢出降级                                   │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ Layer 3: Coarse BitMap（粗糙位图）                        │  │
│  │ ┌────────────────────────────────────────────────────┐   │  │
│  │ │ 位图[Region D] = 1  // Region D 整个被引用         │   │  │
│  │ │ 位图[Region E] = 0                                 │   │  │
│  │ │ ...                                                 │   │  │
│  │ │ 大小：2048 位 = 256 bytes                          │   │  │
│  │ │ 精度：每个 Region 一位（丢失卡片精度）             │   │  │
│  │ └────────────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 三、SparsePRT：稀疏表实现

### 3.1 数据结构

```
┌─────────────────────────────────────────────────────────────────┐
│  SparsePRT 结构（紧凑存储少量引用）                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  class SparsePRT {                                              │
│      RSHashTable* _cur;    // 当前表（迭代用）                  │
│      RSHashTable* _next;   // 下一表（修改用）                  │
│  };                                                              │
│                                                                 │
│  class RSHashTable {                                            │
│      size_t _num_entries;        // Entry 数组容量              │
│      size_t _capacity;           // 哈希桶数量                  │
│      size_t _occupied_entries;   // 已占用 Entry 数             │
│      size_t _occupied_cards;     // 已占用卡片总数              │
│                                                                 │
│      SparsePRTEntry* _entries;   // Entry 数组                  │
│      int* _buckets;              // 哈希桶数组                   │
│      int _free_list;             // 自由列表头                  │
│  };                                                              │
│                                                                 │
│  class SparsePRTEntry {                                         │
│      RegionIdx_t _region_ind;    // Region 索引                 │
│      int _next_index;            // 开链法下一节点              │
│      int _next_null;             // 卡片数组当前长度            │
│      card_elem_t _cards[N];      // 卡片数组（变长）            │
│  };                                                              │
│                                                                 │
│  默认参数：                                                      │
│    - G1RSetSparseRegionEntries = 4（每个 Entry 最多 4 张卡）   │
│    - 初始容量：由参数 G1RSetRegionEntries 决定                 │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 内存布局（标准环境）

```
┌─────────────────────────────────────────────────────────────────┐
│  SparsePRT 内存布局示例                                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  假设记录 2 个 Region 的引用：Region B(卡5,卡10), Region C(卡128)│
│                                                                 │
│  RSHashTable:                                                   │
│    ┌─────────────────────────────────────────────────────────┐ │
│    │ _num_entries = 8                                        │ │
│    │ _capacity = 16                                          │ │
│    │ _occupied_entries = 2                                   │ │
│    │ _occupied_cards = 3                                     │ │
│    └─────────────────────────────────────────────────────────┘ │
│                                                                 │
│  _buckets（哈希桶数组，16 个桶）：                              │
│    ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐          │
│    │  0  │ -1  │  1  │ -1  │ -1  │ -1  │ -1  │ ... │          │
│    └─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘          │
│      ↑          ↑                                               │
│      │          └─ Entry 1 (Region C)                          │
│      └─ Entry 0 (Region B)                                     │
│                                                                 │
│  _entries（Entry 数组，每个 ~20 bytes）：                       │
│    ┌─────────────────────────────────────────────────────────┐ │
│    │ Entry 0:                                                 │ │
│    │   _region_ind = B的索引                                 │ │
│    │   _next_index = -1                                      │ │
│    │   _next_null = 2                                        │ │
│    │   _cards = [5, 10, -, -]                                │ │
│    ├─────────────────────────────────────────────────────────┤ │
│    │ Entry 1:                                                 │ │
│    │   _region_ind = C的索引                                 │ │
│    │   _next_index = -1                                      │ │
│    │   _next_null = 1                                        │ │
│    │   _cards = [128, -, -, -]                               │ │
│    ├─────────────────────────────────────────────────────────┤ │
│    │ Entry 2-7: 未使用（自由列表）                           │ │
│    └─────────────────────────────────────────────────────────┘ │
│                                                                 │
│  总内存：~320 bytes                                              │
│    - RSHashTable 头：~80 bytes                                  │
│    - _buckets：16 × 4 = 64 bytes                               │
│    - _entries：8 × 20 = 160 bytes                              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.3 核心操作

```cpp
// 添加卡片到 SparsePRT
bool RSHashTable::add_card(RegionIdx_t region_id, CardIdx_t card_index) {
    // 1. 查找 Entry
    SparsePRTEntry* e = get_entry(region_id);
    
    if (e == NULL) {
        // 2. Entry 不存在，创建新 Entry
        e = entry_for_region_ind_create(region_id);
        if (e == NULL) {
            return false;  // 表满，需要降级
        }
    }
    
    // 3. 添加卡片到 Entry
    SparsePRTEntry::AddCardResult res = e->add_card(card_index);
    switch (res) {
        case SparsePRTEntry::added:
            _occupied_cards++;
            return true;
        case SparsePRTEntry::found:
            return true;  // 已存在，去重
        case SparsePRTEntry::overflow:
            return false;  // Entry 满，需要降级
    }
}

// Entry 添加卡片
SparsePRTEntry::AddCardResult SparsePRTEntry::add_card(CardIdx_t card_index) {
    // 检查是否已存在（去重）
    for (int i = 0; i < _next_null; i++) {
        if (_cards[i] == card_index) {
            return found;
        }
    }
    
    // 检查是否有空间
    if (_next_null < cards_num()) {
        _cards[_next_null++] = card_index;
        return added;
    }
    
    return overflow;  // Entry 满
}
```

### 3.4 双缓冲机制

```
┌─────────────────────────────────────────────────────────────────┐
│  SparsePRT 双缓冲机制（读写分离）                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  目的：迭代时不阻塞修改，修改时不影响迭代                       │
│                                                                 │
│  结构：                                                          │
│    SparsePRT {                                                  │
│        RSHashTable* _cur;   // 迭代器读这个表                   │
│        RSHashTable* _next;  // 修改写这个表                     │
│    }                                                             │
│                                                                 │
│  工作流程：                                                      │
│                                                                 │
│  1. 初始状态：                                                   │
│     _cur → Table A (空)                                         │
│     _next → Table A (同一个表)                                  │
│                                                                 │
│  2. 添加引用时：                                                 │
│     直接修改 _next (Table A)                                    │
│                                                                 │
│  3. 开始迭代时：                                                 │
│     创建新 Table B                                              │
│     _next → Table B                                             │
│     _cur 保持不变 → Table A                                     │
│     迭代器遍历 _cur (Table A)                                   │
│     新引用写入 _next (Table B)                                  │
│                                                                 │
│  4. 迭代完成后：                                                 │
│     删除 _cur (Table A)                                         │
│     _cur → Table B                                              │
│     _next → Table B                                             │
│                                                                 │
│  优势：                                                          │
│    - 迭代器无锁读取                                             │
│    - 修改不阻塞迭代                                             │
│    - 内存一致性好                                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 四、PerRegionTable（PRT）：精细表实现

### 4.1 数据结构

```
┌─────────────────────────────────────────────────────────────────┐
│  PerRegionTable 结构（位图存储一个 Region 的卡片）              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  class PerRegionTable : public CHeapObj<mtGC> {                 │
│      HeapRegion* _hr;          // 对应的 Region                 │
│      CHeapBitMap _bm;          // 位图（8192 位）               │
│      jint _occupied;           // 已占用卡片数                  │
│                                                                 │
│      // 双向链表（用于快速遍历所有 PRT）                        │
│      PerRegionTable* _next;                                    │
│      PerRegionTable* _prev;                                    │
│                                                                 │
│      // 哈希冲突链表                                            │
│      PerRegionTable* _collision_list_next;                     │
│                                                                 │
│      // 全局自由列表（复用 PRT）                                │
│      static PerRegionTable* volatile _free_list;               │
│  };                                                              │
│                                                                 │
│  内存布局（标准环境）：                                          │
│    - 固定开销：~40 bytes（指针 + 计数器）                       │
│    - 位图：8192 位 = 1024 bytes = 1 KB                         │
│    - 总计：~1 KB 每个 PRT                                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 位图详解

```
┌─────────────────────────────────────────────────────────────────┐
│  PRT 位图详解（4MB Region = 8192 张卡）                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  位图大小：8192 位 = 1024 bytes = 1 KB                          │
│  位图索引：卡片在 Region 内的索引（0-8191）                     │
│                                                                 │
│  示例：Region B 的 PRT，记录卡 5、卡 10、卡 128 引用 Region A  │
│                                                                 │
│  _bm（位图，8192 位）：                                          │
│    位索引：  0  1  2  3  4  5  6  7  8  9  10 ... 128 ...      │
│           ┌──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬─...─┬──┬─...─┐  │
│    值：   │0 │0 │0 │0 │0 │1 │0 │0 │0 │0 │1 │ ... │1 │ ... │  │
│           └──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴─...─┴──┴─...─┘  │
│                     ↑           ↑              ↑                │
│                   卡5          卡10           卡128             │
│                                                                 │
│  _occupied = 3（已占用 3 张卡）                                 │
│                                                                 │
│  查询操作：                                                      │
│    bool contains_card(CardIdx_t card_index) {                  │
│        return _bm.at(card_index);                              │
│    }                                                             │
│    // 时间复杂度：O(1)                                          │
│                                                                 │
│  添加操作：                                                      │
│    void add_card_work(CardIdx_t from_card, bool par) {         │
│        if (!_bm.at(from_card)) {                               │
│            if (par) {                                          │
│                if (_bm.par_at_put(from_card, 1)) {             │
│                    Atomic::inc(&_occupied);                    │
│                }                                                │
│            } else {                                             │
│                _bm.at_put(from_card, 1);                       │
│                _occupied++;                                    │
│            }                                                    │
│        }                                                        │
│    }                                                             │
│    // 并发安全：CAS 原子操作                                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.3 Fine PRT 哈希表

```
┌─────────────────────────────────────────────────────────────────┐
│  Fine PRT 哈希表结构                                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  _fine_grain_regions（哈希表，指针数组）：                      │
│    大小：_max_fine_entries（默认 2048）                         │
│    类型：PerRegionTable**                                       │
│    哈希函数：region_index % _max_fine_entries                   │
│                                                                 │
│  示例：记录 Region B、C、D 的引用                               │
│                                                                 │
│    哈希桶索引：                                                 │
│      Region B (index=5)  → hash(5) = 5                         │
│      Region C (index=13) → hash(13) = 13                       │
│      Region D (index=21) → hash(21) = 21                       │
│                                                                 │
│    哈希表：                                                     │
│      ┌───────┬───────┬───────┬───────┬───────┬───────┐        │
│      │  0    │  1    │  2    │  3    │  4    │  5    │ ...    │
│      └───────┴───────┴───────┴───────┴───────┴───────┘        │
│                                                 ↓                │
│                                              PRT(B)              │
│                                                                 │
│    冲突处理（开链法）：                                         │
│      Region X (index=2053) → hash(2053) = 5（冲突）            │
│      ┌───────┐                                                 │
│      │  5    │ → PRT(B) → _collision_list_next → PRT(X)       │
│      └───────┘                                                 │
│                                                                 │
│  双向链表（遍历所有 PRT）：                                     │
│    _first_all_fine_prts ↔ PRT(B) ↔ PRT(C) ↔ PRT(D)             │
│                              ↑                                  │
│                        _last_all_fine_prts                      │
│                                                                 │
│  内存开销：                                                      │
│    - 哈希表：2048 × 8B = 16 KB                                 │
│    - 每个 PRT：~1 KB                                           │
│    - 假设 10 个 PRT：16 KB + 10 KB = 26 KB                     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.4 PRT 复用机制

```
┌─────────────────────────────────────────────────────────────────┐
│  PRT 全局自由列表（复用机制）                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  目的：避免频繁分配/释放 PRT，提高性能                          │
│                                                                 │
│  工作流程：                                                      │
│                                                                 │
│  1. 分配 PRT：                                                  │
│     PerRegionTable* alloc(HeapRegion* hr) {                    │
│         PerRegionTable* fl = _free_list;                       │
│         while (fl != NULL) {                                   │
│             PerRegionTable* nxt = fl->next();                  │
│             PerRegionTable* res = Atomic::cmpxchg(nxt,         │
│                                                   &_free_list, │
│                                                   fl);         │
│             if (res == fl) {                                   │
│                 fl->init(hr, true);                            │
│                 return fl;                                     │
│             } else {                                           │
│                 fl = _free_list;                               │
│             }                                                  │
│         }                                                      │
│         return new PerRegionTable(hr);  // 列表空，创建新对象  │
│     }                                                           │
│                                                                 │
│  2. 释放 PRT：                                                  │
│     void free(PerRegionTable* prt) {                           │
│         bulk_free(prt, prt);                                   │
│     }                                                           │
│                                                                 │
│     void bulk_free(PerRegionTable* prt, PerRegionTable* last) {│
│         while (true) {                                         │
│             PerRegionTable* fl = _free_list;                   │
│             last->set_next(fl);                                │
│             PerRegionTable* res = Atomic::cmpxchg(prt,         │
│                                                   &_free_list, │
│                                                   fl);         │
│             if (res == fl) {                                   │
│                 return;                                        │
│             }                                                  │
│         }                                                      │
│     }                                                           │
│                                                                 │
│  优势：                                                          │
│    - 无锁分配（CAS）                                            │
│    - 批量释放（减少竞争）                                       │
│    - 内存复用（减少碎片）                                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 五、Coarse BitMap：粗糙位图

### 5.1 数据结构

```
┌─────────────────────────────────────────────────────────────────┐
│  Coarse BitMap 结构（每个 Region 一位）                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  class OtherRegionsTable {                                      │
│      CHeapBitMap _coarse_map;  // 位图，2048 位                 │
│      size_t _n_coarse_entries; // 已设置位数                    │
│      static jint _n_coarsenings;  // 总降级次数（统计）         │
│  };                                                              │
│                                                                 │
│  大小：2048 位 = 256 bytes                                       │
│  索引：Region 索引（0-2047）                                    │
│                                                                 │
│  示例：Region B、D、E 完全引用 Region A                         │
│                                                                 │
│    _coarse_map（位图，2048 位）：                                │
│      位索引：  0  1  2  3  4  5  6  7  8  9  10 11 12 13 14 ... │
│             ┌──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬...┐│
│      值：   │0 │0 │0 │0 │1 │0 │0 │0 │1 │0 │0 │0 │1 │0 │0 │...││
│             └──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴...┘│
│                           ↑           ↑           ↑              │
│                        Region B   Region D   Region E            │
│                        (index=4)  (index=8)  (index=12)          │
│                                                                 │
│  _n_coarse_entries = 3                                          │
│                                                                 │
│  语义：位 = 1 表示该 Region 中可能有卡片引用本 Region           │
│  精度损失：丢失了具体卡片信息，扫描时需遍历整个 Region          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 降级机制

```
┌─────────────────────────────────────────────────────────────────┐
│  降级流程：Sparse → Fine → Coarse                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  触发条件：                                                      │
│    1. Sparse PRT Entry 满了（卡片数 > 4）                       │
│    2. Fine PRT 哈希表满了（PRT 数量 > _max_fine_entries）       │
│                                                                 │
│  Sparse → Fine 降级：                                           │
│    void expand_to_fine_grain(RegionIdx_t region_id,            │
│                               CardIdx_t card_index) {          │
│        // 1. 从 Sparse PRT 删除该 Region 的 Entry              │
│        SparsePRTEntry* e = _sparse_table.get_entry(region_id); │
│        CardIdxT cards[SparsePRTEntry::cards_num()];            │
│        e->copy_cards(cards);                                   │
│        _sparse_table.delete_entry(region_id);                  │
│                                                                 │
│        // 2. 创建或查找 Fine PRT                               │
│        PerRegionTable* prt = find_region_tableOrCreate(region_id);│
│                                                                 │
│        // 3. 将所有卡片迁移到 Fine PRT                         │
│        for (int i = 0; i < e->num_valid_cards(); i++) {        │
│            prt->add_card(cards[i]);                            │
│        }                                                        │
│        prt->add_card(card_index);  // 添加新卡片               │
│    }                                                            │
│                                                                 │
│  Fine → Coarse 降级：                                           │
│    PerRegionTable* delete_region_table() {                     │
│        // 1. 选择一个 PRT 驱逐（采样策略）                     │
│        PerRegionTable* prt = select_prt_to_evict();            │
│                                                                 │
│        // 2. 设置 Coarse BitMap                                │
│        _coarse_map.set_bit(prt->hr()->hrm_index());            │
│        _n_coarse_entries++;                                    │
│                                                                 │
│        // 3. 删除 PRT                                          │
│        unlink_from_all(prt);                                   │
│        PerRegionTable::free(prt);                              │
│                                                                 │
│        return prt;                                             │
│    }                                                            │
│                                                                 │
│  统计信息：                                                      │
│    - _n_coarsenings：总降级次数                                │
│    - 可通过 `-Xlog:gc+remset=trace` 查看                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 六、完整添加引用流程

### 6.1 add_reference() 完整流程

```cpp
void OtherRegionsTable::add_reference(OopOrNarrowOopStar from, uint tid) {
    // 1. 计算来源 Region 和卡片索引
    HeapRegion* from_hr = _g1h->heap_region_containing(from);
    RegionIdx_t from_hr_idx = from_hr->hrm_index();
    CardIdx_t card_index = card_within_region(from, from_hr);
    
    // 2. 检查 Coarse BitMap（快速路径）
    if (_coarse_map.at(from_hr_idx)) {
        return;  // 已在 Coarse 中，无需重复添加
    }
    
    // 3. 查找或创建 Fine PRT
    PerRegionTable* prt = find_region_table(from_hr_idx);
    if (prt != NULL) {
        prt->add_card(card_index);  // 已有 PRT，直接添加
        return;
    }
    
    // 4. 尝试添加到 Sparse PRT
    if (_sparse_table.add_card(from_hr_idx, card_index)) {
        return;  // 添加成功
    }
    
    // 5. Sparse PRT 满了，降级到 Fine PRT
    MutexLockerEx x(_m, Mutex::_no_safepoint_check_flag);
    
    // 再次检查（可能在加锁期间其他线程已创建）
    prt = find_region_table(from_hr_idx);
    if (prt != NULL) {
        prt->add_card(card_index);
        return;
    }
    
    // 6. 检查 Fine PRT 哈希表是否已满
    if (_n_fine_entries >= _max_fine_entries) {
        // Fine PRT 满了，驱逐一个 PRT 到 Coarse
        prt = delete_region_table();
        // 迁移被驱逐 PRT 的卡片到 Coarse
        _coarse_map.set_bit(prt->hr()->hrm_index());
    }
    
    // 7. 创建新的 Fine PRT
    prt = PerRegionTable::alloc(from_hr);
    // 迁移 Sparse PRT 的卡片到 Fine PRT
    SparsePRTEntry* e = _sparse_table.get_entry(from_hr_idx);
    if (e != NULL) {
        for (int i = 0; i < e->num_valid_cards(); i++) {
            prt->add_card(e->card(i));
        }
        _sparse_table.delete_entry(from_hr_idx);
    }
    prt->add_card(card_index);
    
    // 8. 插入到哈希表
    size_t ind = hash_code(from_hr_idx);
    prt->set_collision_list_next(_fine_grain_regions[ind]);
    _fine_grain_regions[ind] = prt;
    _n_fine_entries++;
    link_to_all(prt);
}
```

### 6.2 流程图

```
┌─────────────────────────────────────────────────────────────────┐
│  add_reference() 决策流程                                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  开始：add_reference(from, tid)                                 │
│    ↓                                                             │
│  计算：region_id, card_index                                    │
│    ↓                                                             │
│  检查：Coarse BitMap[region_id] == 1？                          │
│    ├─ 是 → 返回（已存在）                                       │
│    └─ 否 ↓                                                      │
│                                                                 │
│  查找：Fine PRT 哈希表[region_id] 存在？                        │
│    ├─ 是 → PRT.add_card(card_index) → 返回                     │
│    └─ 否 ↓                                                      │
│                                                                 │
│  尝试：Sparse PRT.add_card(region_id, card_index)               │
│    ├─ 成功 → 返回                                               │
│    └─ 失败（Entry 满） ↓                                        │
│                                                                 │
│  加锁：MutexLocker(_m)                                          │
│    ↓                                                             │
│  再次查找：Fine PRT（避免重复创建）                             │
│    ├─ 存在 → PRT.add_card(card_index) → 返回                   │
│    └─ 不存在 ↓                                                  │
│                                                                 │
│  检查：Fine PRT 哈希表满？                                      │
│    ├─ 是 → 驱逐一个 PRT → 设置 Coarse BitMap                   │
│    └─ 否 ↓                                                      │
│                                                                 │
│  创建：新的 Fine PRT                                            │
│    ↓                                                             │
│  迁移：Sparse PRT 的卡片 → Fine PRT                             │
│    ↓                                                             │
│  添加：新卡片到 Fine PRT                                        │
│    ↓                                                             │
│  插入：Fine PRT 到哈希表                                        │
│    ↓                                                             │
│  返回                                                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 七、性能分析

### 7.1 内存开销对比

```
┌─────────────────────────────────────────────────────────────────┐
│  不同场景下的内存开销                                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  场景 1：极少引用（2 个 Region，各 1 张卡）                     │
│    - Sparse PRT：~320 bytes                                     │
│    - Fine PRT：~2 KB（浪费）                                    │
│    - Coarse：256 bytes（精度损失）                              │
│    → 选择：Sparse PRT                                           │
│                                                                 │
│  场景 2：中等引用（10 个 Region，各 100 张卡）                  │
│    - Sparse PRT：无法存储（Entry 溢出）                         │
│    - Fine PRT：~10 KB（10 个 PRT）                              │
│    - Coarse：256 bytes（精度损失大）                            │
│    → 选择：Fine PRT                                             │
│                                                                 │
│  场景 3：大量引用（100 个 Region，各 100 张卡）                 │
│    - Sparse PRT：无法存储                                       │
│    - Fine PRT：~100 KB（接近上限）                              │
│    - Coarse：256 bytes（精度损失极大）                          │
│    → 选择：Fine PRT + 部分 Coarse                               │
│                                                                 │
│  场景 4：极端引用（500 个 Region，整个 Region 都引用）          │
│    - Sparse PRT：无法存储                                       │
│    - Fine PRT：~500 KB（超限，驱逐）                            │
│    - Coarse：256 bytes（最佳）                                  │
│    → 选择：Coarse BitMap                                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 7.2 查询性能对比

| 操作 | Sparse PRT | Fine PRT | Coarse BitMap |
|------|-----------|----------|---------------|
| 查询卡片 | O(n) 线性扫描 | O(1) 位图查询 | O(1) 位图查询 |
| 添加卡片 | O(n) 去重检查 | O(1) 位图设置 | O(1) 位图设置 |
| 删除卡片 | O(n) 线性查找 | O(1) 位图清除 | O(1) 位图清除 |
| 遍历所有卡片 | O(n) 顺序访问 | O(n/word) 位图遍历 | N/A（无卡片信息） |

### 7.3 典型配置参数

```bash
# Sparse PRT 每个 Entry 的卡片容量
-XX:G1RSetSparseRegionEntries=4  # 默认 4 张卡

# Fine PRT 哈希表大小
-XX:G1RSetRegionEntries=2048  # 默认 2048

# 示例：调整参数优化特定场景
# 场景：大量跨 Region 引用
-XX:G1RSetRegionEntries=4096  # 增大 Fine PRT 容量
```

---

## 八、面试级深度问答

### Q1: 为什么需要三层存储架构？统一用一种不行吗？

**A**: 统一用一种存储会面临困境：

1. **全部用 Sparse PRT**：
   - 少量引用时效率高
   - 大量引用时线性查询太慢（O(n)）
   - Entry 容量有限，容易溢出

2. **全部用 Fine PRT**：
   - 查询快（O(1) 位图）
   - 少量引用时浪费内存（~1 KB per PRT）
   - 大量 PRT 时哈希表过大

3. **全部用 Coarse BitMap**：
   - 内存最省（256 bytes）
   - 丢失卡片精度，扫描范围扩大 8192 倍
   - GC 时间不可控

三层架构的核心思想：**动态适应引用密度，平衡内存与查询效率**。

### Q2: Sparse PRT 的双缓冲机制解决了什么问题？

**A**: 解决迭代与修改的并发冲突：

**问题**：
- GC 期间需要迭代 RSet（扫描跨 Region 引用）
- 同时可能并发更新 RSet（引用关系变化）
- 传统方案：加锁 → 性能下降

**双缓冲方案**：
- `_cur`：迭代器读取，不受干扰
- `_next`：修改写入，不影响迭代
- 迭代完成后交换指针

**优势**：
- 迭代器无锁读取
- 修改不阻塞迭代
- 内存一致性好

### Q3: Fine PRT 为什么用位图而不是哈希表？

**A**: 空间效率与查询效率的权衡：

**位图方案**：
- 大小：8192 位 = 1 KB（固定）
- 查询：O(1)，位索引直接访问
- 内存：固定，不随卡片数变化
- 适用：卡片密集的场景

**哈希表方案**：
- 大小：卡片数 × Entry 大小（可变）
- 查询：O(1)，哈希计算 + 链表遍历
- 内存：随卡片数增长
- 适用：卡片稀疏的场景

**选择原因**：
- Fine PRT 场景：单个 Region 内的卡片通常较多（溢出 Sparse）
- 位图固定大小，可预测
- 位图查询更简单（无哈希计算）

### Q4: 降级到 Coarse BitMap 后，如何保证扫描正确性？

**A**: 精度损失的正确性保证：

**精度损失**：
- Coarse BitMap 只记录 Region 索引
- 丢失具体卡片信息
- 扫描时需遍历整个 Region

**正确性保证**：
- 保守策略：Coarse BitMap 设置后，整个 Region 都需要扫描
- 宁可多扫描（不影响正确性），不可漏扫
- 扫描时会检查卡片的 top 边界，不会访问无效对象

**性能影响**：
- 扫描范围扩大：1 张卡 → 整个 Region（8192 张卡）
- 影响：增加 ~10ms 扫描时间（4MB Region）
- 缓解：降级是渐进的，只有引用极多的 Region 才会降级

### Q5: PRT 自由列表的作用是什么？为什么需要批量释放？

**A**: 性能优化与内存碎片控制：

**自由列表作用**：
- 复用已释放的 PRT 对象
- 避免频繁 new/delete
- 减少内存碎片

**批量释放原因**：
- GC 结束时需要释放大量 PRT（整个 Region 回收）
- 单个 CAS 操作释放多个 PRT
- 减少锁竞争（_free_list 是全局变量）

**实现**：
```cpp
void bulk_free(PerRegionTable* prt, PerRegionTable* last) {
    while (true) {
        PerRegionTable* fl = _free_list;
        last->set_next(fl);  // 链接到现有列表
        PerRegionTable* res = Atomic::cmpxchg(prt, &_free_list, fl);
        if (res == fl) {
            return;  // 成功
        }
        // 失败，重试
    }
}
```

---

## 九、GDB 验证脚本

### 9.1 观察 RSet 结构

```gdb
# observe_rset_structure.gdb
# 观察 HeapRegionRemSet 的结构

set pagination off

# 断点：Region 初始化时
break HeapRegionRemSet::HeapRegionRemSet
  commands
    printf "=== 创建 HeapRegionRemSet ===\n"
    printf "Region 地址: %p\n", hr
    printf "RSet 地址: %p\n", this
    printf "固定开销: %lu bytes\n", sizeof(HeapRegionRemSet)
    continue
  end

# 断点：添加引用
break OtherRegionsTable::add_reference
  commands
    printf "=== 添加引用到 RSet ===\n"
    printf "来源地址: %p\n", from
    printf "线程 ID: %d\n", tid
    continue
  end

# 断点：降级到 Coarse
break OtherRegionsTable::delete_region_table
  commands
    printf "=== 降级到 Coarse BitMap ===\n"
    printf "Coarse 条目数: %lu\n", _n_coarse_entries
    printf "总降级次数: %d\n", OtherRegionsTable::_n_coarsenings
    continue
  end

run
```

### 9.2 统计 RSet 内存占用

```gdb
# stat_rset_memory.gdb
# 统计 RSet 的内存占用

set pagination off

# 定义统计函数
define print_rset_stats
  printf "\n=== RSet 统计信息 ===\n"
  printf "Region 索引: %u\n", $arg0->hr()->hrm_index()
  printf "占用卡片数: %lu\n", $arg0->occupied()
  printf "  Sparse: %lu\n", $arg0->occ_sparse()
  printf "  Fine: %lu\n", $arg0->occ_fine()
  printf "  Coarse: %lu\n", $arg0->occ_coarse()
  printf "内存占用: %lu bytes\n", $arg0->mem_size()
end

# 断点：GC 结束后
break G1CollectedHeap::collect
  commands
    # 统计所有 Region 的 RSet
    set $i = 0
    set $total_mem = 0
    while $i < 2048
      set $hr = $_g1h->region_at($i)
      if $hr != 0
        set $rset = $hr->rem_set()
        if $rset != 0
          set $mem = $rset->mem_size()
          set $total_mem = $total_mem + $mem
        end
      end
      set $i = $i + 1
    end
    printf "\n=== RSet 总内存: %lu KB ===\n", $total_mem / 1024
    continue
  end

run
```

---

## 十、总结

### 核心设计思想

```
┌─────────────────────────────────────────────────────────────────┐
│  RSet 数据结构的三大核心思想                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 三层存储架构（动态适应）                                     │
│     • Sparse PRT：紧凑存储，少量引用                            │
│     • Fine PRT：位图存储，中等引用                              │
│     • Coarse BitMap：粗糙存储，大量引用                         │
│                                                                 │
│  2. 空间-时间权衡                                                │
│     • 少量引用：节省空间，接受 O(n) 查询                        │
│     • 大量引用：牺牲空间，换取 O(1) 查询                        │
│     • 极端情况：牺牲精度，保证可控                               │
│                                                                 │
│  3. 并发优化                                                     │
│     • Sparse PRT 双缓冲：读写分离                               │
│     • Fine PRT CAS 操作：无锁添加                               │
│     • PRT 自由列表：复用减少竞争                                │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 关键数据

| 项目 | 数值 |
|------|------|
| Region 大小 | 4 MB |
| 每张卡大小 | 512 B |
| 每 Region 卡片数 | 8192 张 |
| Sparse PRT Entry 容量 | 4 张卡 |
| Fine PRT 位图大小 | 1 KB |
| Coarse BitMap 大小 | 256 bytes |
| 初始 RSet 大小 | ~320 bytes |
| 最大 Fine PRT 数量 | 2048 |

### 关键源码位置

| 组件 | 文件 | 核心函数 |
|------|------|----------|
| **HeapRegionRemSet** | `heapRegionRemSet.hpp/cpp` | `add_reference()`, `occupied()` |
| **OtherRegionsTable** | `heapRegionRemSet.cpp` | `add_reference()`, `delete_region_table()` |
| **SparsePRT** | `sparsePRT.hpp/cpp` | `add_card()`, `delete_entry()` |
| **PerRegionTable** | `heapRegionRemSet.cpp` | `add_card_work()`, `alloc()`, `free()` |

---

**下一步分析**：G1 Concurrent Mark 详细流程（三色标记、SATB、并发标记阶段）
