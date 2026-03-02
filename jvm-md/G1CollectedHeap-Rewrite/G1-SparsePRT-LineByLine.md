# SparsePRT：RSet存储的第一层

## 1. 概览：解决什么问题？

### 1.1 背景：跨代引用的存储需求

G1 GC 的 RSet 需要记录**跨 Region 引用**：
```
Region A (老年代) ──────引用──────> Region B (年轻代)

RSet of Region B 需要记录：
  "Region A 的 Card 37 有指向我的引用"
```

**数据特点**：
- **稀疏性**：大多数 Region 只被少数其他 Region 引用
- **扇出有限**：一个 Region 的 RSet 通常只记录少量 Card
- **动态变化**：引用模式随应用运行变化

### 1.2 SparsePRT 的角色

G1 使用**三层存储**记录 RSet：

```
┌────────────────────────────────────────────────────────────┐
│             第一层：SparsePRT（稀疏表）                    │
│  - 存储：Region → Card[] 映射                             │
│  - 特点：占用少，访问快                                   │
│  - 容量：有限（默认每个Entry存4个Card）                   │
│  - 适用：扇出小的Region                                   │
└────────────────────────────────────────────────────────────┘
                         │ overflow
                         ▼
┌────────────────────────────────────────────────────────────┐
│            第二层：Fine Grain Table（细粒度表）            │
│  - 存储：PerRegionTable (PRT) 数组                        │
│  - 特点：容量大，占用多                                   │
│  - 适用：扇出中等的Region                                 │
└────────────────────────────────────────────────────────────┘
                         │ overflow
                         ▼
┌────────────────────────────────────────────────────────────┐
│             第三层：Coarse Map（粗粒度位图）               │
│  - 存储：Region位图（每个Region一位）                     │
│  - 特点：最粗粒度，占用固定                               │
│  - 适用：扇出大的Region                                   │
└────────────────────────────────────────────────────────────┘
```

**SparsePRT 的定位**：
- **第一层存储**：优先使用
- **容量有限**：每个 Entry 最多存储 `G1RSetSparseRegionEntries`（默认4）个 Card
- **溢出迁移**：Entry 满后，迁移到 Fine Grain Table

### 1.3 设计目标

1. **空间效率**：对于扇出小的 Region，避免分配大表
2. **访问效率**：O(1) 查找 Region，O(n) 查找 Card
3. **并发安全**：支持并发读，写操作需要外部锁
4. **自动扩容**：Entry 数量增长时自动扩容

---

## 2. 核心数据结构

### 2.1 SparsePRTEntry：单个条目

**源码位置**：`gc/g1/sparsePRT.hpp:46-110`

```cpp
class SparsePRTEntry: public CHeapObj<mtGC> {
private:
  typedef uint16_t card_elem_t;  // Card 索引类型（16位）

  // 对齐要求：确保 sizeof(SparsePRTEntry) 是 int 大小的倍数
  static const size_t card_array_alignment = sizeof(int) / sizeof(card_elem_t);

  RegionIdx_t _region_ind;    // 源 Region 索引
  int         _next_index;    // 链表下一个节点（开链法）
  int         _next_null;     // Card 数组下一个空闲位置

  // Card 数组（变长，放在最后）
  card_elem_t _cards[card_array_alignment];

public:
  // Entry 大小（用于分配）
  static size_t size() {
    return sizeof(SparsePRTEntry) +
           sizeof(card_elem_t) * (cards_num() - card_array_alignment);
  }

  // Card 数组容量
  static int cards_num() {
    return align_up((int)G1RSetSparseRegionEntries, (int)card_array_alignment);
  }
};
```

**内存布局**：

```
SparsePRTEntry (cards_num = 4, 默认配置)
┌─────────────────────────────────────────────────────────┐
│ _region_ind (RegionIdx_t = int)     : 4 bytes          │
│ _next_index (int)                   : 4 bytes          │
│ _next_null (int)                    : 4 bytes          │
├─────────────────────────────────────────────────────────┤
│ _cards[0] (card_elem_t = uint16_t)  : 2 bytes          │
│ _cards[1]                            : 2 bytes          │
│ _cards[2]                            : 2 bytes          │
│ _cards[3]                            : 2 bytes          │
└─────────────────────────────────────────────────────────┘
总大小：16 + 8 = 24 bytes（对齐后）

变长数组实现：
- _cards[card_array_alignment] 是编译时确定的初始大小
- 实际大小 = size() = sizeof(SparsePRTEntry) + sizeof(card_elem_t) * (cards_num() - card_array_alignment)
- 这允许 cards_num() > card_array_alignment 时正确分配
```

**关键点**：
1. **变长数组**：`_cards[]` 放在结构体末尾，支持动态大小
2. **对齐保证**：确保内存访问不会触发 SIGBUS
3. **容量限制**：`cards_num()` 由 `G1RSetSparseRegionEntries` 决定（默认4）

### 2.2 RSHashTable：哈希表

**源码位置**：`gc/g1/sparsePRT.hpp:112-187`

```cpp
class RSHashTable : public CHeapObj<mtGC> {
  static float TableOccupancyFactor;  // 占用因子 0.5

  size_t _num_entries;         // Entry 数组实际容量
  size_t _capacity;            // 哈希桶数量
  size_t _capacity_mask;       // capacity - 1（用于取模）
  size_t _occupied_entries;    // 已占用 Entry 数
  size_t _occupied_cards;      // 已占用 Card 总数

  SparsePRTEntry* _entries;    // Entry 数组（连续内存）
  int*            _buckets;    // 哈希桶数组（存储 Entry 索引）

  int _free_region;            // 下一个未分配的 Entry 索引
  int _free_list;              // 空闲链表头（已释放的 Entry）

public:
  static const int NullEntry = -1;  // 空指针标记

  bool should_expand() const {
    return _occupied_entries == _num_entries;
  }

  SparsePRTEntry* entry(int i) const {
    return (SparsePRTEntry*)((char*)_entries + SparsePRTEntry::size() * i);
  }
};
```

**内存布局**：

```
RSHashTable (capacity = 16, 初始配置)
┌─────────────────────────────────────────────────────────┐
│ 成员变量                                                 │
│  _num_entries = (16 * 0.5) + 1 = 9                      │
│  _capacity = 16                                          │
│  _capacity_mask = 15                                     │
│  _occupied_entries = 0                                   │
│  _occupied_cards = 0                                     │
├─────────────────────────────────────────────────────────┤
│ _buckets[16] (int 数组)                                 │
│  ┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐            │
│  │-1 │-1 │-1 │-1 │-1 │-1 │-1 │-1 │... │-1 │ 初始全-1   │
│  └───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘            │
├─────────────────────────────────────────────────────────┤
│ _entries[9] (SparsePRTEntry 数组)                       │
│  ┌─────────┬─────────┬─────────┬─────┬─────────┐       │
│  │ Entry 0 │ Entry 1 │ Entry 2 │ ... │ Entry 8 │       │
│  │ 24 bytes│ 24 bytes│ 24 bytes│     │ 24 bytes│       │
│  └─────────┴─────────┴─────────┴─────┴─────────┘       │
└─────────────────────────────────────────────────────────┘

总内存：
  _buckets: 16 * 4 = 64 bytes
  _entries: 9 * 24 = 216 bytes
  总计：64 + 216 + sizeof(RSHashTable) ≈ 300 bytes
```

**关键点**：
1. **开链法**：`_buckets` 存储链表头索引，通过 `_next_index` 链接
2. **Entry 分配**：先从 `_free_region` 分配，再用 `_free_list` 回收
3. **变长 Entry**：通过 `entry(i)` 计算地址，支持不同大小的 Entry

### 2.3 SparsePRT：顶层封装

**源码位置**：`gc/g1/sparsePRT.hpp:225-320`

```cpp
class SparsePRT {
  // 双缓冲：支持并发访问
  RSHashTable* _cur;    // 当前表（迭代时使用）
  RSHashTable* _next;   // 下一表（修改时使用）

  HeapRegion* _hr;      // 所属 Region

  enum SomeAdditionalPrivateConstants {
    InitialCapacity = 16  // 初始容量
  };

  bool _expanded;              // 是否已扩容
  SparsePRT* _next_expanded;   // 扩容链表下一个节点

  static SparsePRT* volatile _head_expanded_list;  // 全局扩容链表头

public:
  size_t occupied() const {
    return _next->occupied_cards();
  }

  bool add_card(RegionIdx_t region_id, CardIdx_t card_index);
  SparsePRTEntry* get_entry(RegionIdx_t region_ind);
  bool delete_entry(RegionIdx_t region_ind);
  void clear();
  void cleanup();
  void expand();
};
```

**双缓冲机制**：

```
┌────────────────────────────────────────────────────────────┐
│                       SparsePRT                            │
│                                                            │
│  _cur ──> RSHashTable (old)  ←─ 迭代器访问                │
│            - GC 开始时的快照                              │
│            - 只读                                          │
│                                                            │
│  _next ─> RSHashTable (new)  ←─ 写操作访问                │
│            - 当前最新数据                                  │
│            - 可扩容                                        │
│                                                            │
│  正常状态：_cur == _next                                   │
│  扩容状态：_cur != _next (old 被标记删除)                 │
│  GC 结束：cleanup() 使 _cur = _next                        │
└────────────────────────────────────────────────────────────┘
```

---

## 3. 核心方法逐行分析

### 3.1 SparsePRTEntry::init()

**源码位置**：`gc/g1/sparsePRT.cpp:40-49`

```cpp
void SparsePRTEntry::init(RegionIdx_t region_ind) {
  // 【Line 43-44】编译时断言：确保 card_elem_t 能表示所有 Card
  // 16位可表示 65536 个 Card，每个 Card 512 bytes
  // => Region 最大 32MB，满足要求
  assert(((size_t)1 << (sizeof(SparsePRTEntry::card_elem_t) * BitsPerByte)) *
         G1CardTable::card_size >= HeapRegionBounds::max_size(), "precondition");

  assert(G1RSetSparseRegionEntries > 0, "precondition");

  // 【Line 46】设置源 Region 索引
  _region_ind = region_ind;

  // 【Line 47】初始化链表指针
  _next_index = RSHashTable::NullEntry;  // -1，表示链表末尾

  // 【Line 48】Card 数组初始为空
  _next_null = 0;
}
```

### 3.2 SparsePRTEntry::add_card()

**源码位置**：`gc/g1/sparsePRT.cpp:60-73`

```cpp
SparsePRTEntry::AddCardResult SparsePRTEntry::add_card(CardIdx_t card_index) {
  // 【Line 61-65】检查是否已存在（去重）
  for (int i = 0; i < num_valid_cards(); i++) {
    if (card(i) == card_index) {
      return found;  // 已存在，无需添加
    }
  }

  // 【Line 66-70】检查是否有空间
  if (num_valid_cards() < cards_num() - 1) {
    // 还有空间，添加 Card
    _cards[_next_null] = (card_elem_t)card_index;
    _next_null++;
    return added;
  }

  // 【Line 71-72】空间不足
  return overflow;
}
```

**关键点**：
1. **去重**：遍历现有 Card，避免重复
2. **提前留一个空位**：`cards_num() - 1` 而非 `cards_num()`
   - 原因：避免迭代时判断结束需要额外标志
3. **返回值**：
   - `found`：Card 已存在
   - `added`：成功添加
   - `overflow`：空间不足

### 3.3 RSHashTable::get_entry()

**源码位置**：`gc/g1/sparsePRT.cpp:139-153`

```cpp
SparsePRTEntry* RSHashTable::get_entry(RegionIdx_t region_ind) const {
  // 【Line 140】计算哈希桶索引
  int ind = (int)(region_ind & capacity_mask());

  // 【Line 141】获取链表头
  int cur_ind = _buckets[ind];
  SparsePRTEntry* cur;

  // 【Line 143-146】遍历链表查找
  while (cur_ind != NullEntry &&
         (cur = entry(cur_ind))->r_ind() != region_ind) {
    cur_ind = cur->next_index();
  }

  // 【Line 148】未找到
  if (cur_ind == NullEntry) return NULL;

  // 【Line 150-152】找到
  assert(cur->r_ind() == region_ind, "Postcondition");
  assert(cur->num_valid_cards() > 0, "Inv");
  return cur;
}
```

**哈希查找流程**：

```
region_ind = 37, capacity = 16, capacity_mask = 15

1. 计算桶索引：
   ind = 37 & 15 = 5

2. 查看 _buckets[5]：
   假设 _buckets[5] = 2

3. 遍历链表：
   Entry 2: r_ind = 37 ✓ 找到！
   或
   Entry 2: r_ind = 21 → next = 7
   Entry 7: r_ind = 37 ✓ 找到！
   或
   Entry 2: r_ind = 21 → next = 7
   Entry 7: r_ind = 53 → next = -1
   未找到
```

### 3.4 RSHashTable::entry_for_region_ind_create()

**源码位置**：`gc/g1/sparsePRT.cpp:175-189`

```cpp
SparsePRTEntry*
RSHashTable::entry_for_region_ind_create(RegionIdx_t region_ind) {
  // 【Line 177】先尝试查找
  SparsePRTEntry* res = get_entry(region_ind);

  // 【Line 178-187】不存在则创建
  if (res == NULL) {
    // 【Line 179】分配新 Entry
    int new_ind = alloc_entry();
    res = entry(new_ind);

    // 【Line 181】初始化 Entry
    res->init(region_ind);

    // 【Line 183-185】插入链表头部（头插法）
    int ind = (int)(region_ind & capacity_mask());
    res->set_next_index(_buckets[ind]);
    _buckets[ind] = new_ind;

    // 【Line 186】更新统计
    _occupied_entries++;
  }
  return res;
}
```

### 3.5 RSHashTable::alloc_entry()

**源码位置**：`gc/g1/sparsePRT.cpp:191-204`

```cpp
int RSHashTable::alloc_entry() {
  int res;

  // 【Line 193-197】优先从空闲链表分配（回收的 Entry）
  if (_free_list != NullEntry) {
    res = _free_list;
    _free_list = entry(res)->next_index();
    return res;
  }
  // 【Line 197-200】从未分配区域分配
  else if ((size_t)_free_region < _num_entries) {
    res = _free_region;
    _free_region++;
    return res;
  }
  // 【Line 201-203】空间耗尽
  else {
    return NullEntry;
  }
}
```

**Entry 分配策略**：

```
分配顺序：
┌────────────────────────────────────────────────────────┐
│ 1. _free_list（空闲链表）                              │
│    - 已使用但已删除的 Entry                            │
│    - 通过 free_entry() 回收                           │
│                                                        │
│ 2. _free_region（未分配区）                            │
│    - 从未使用的 Entry                                  │
│    - 连续分配，索引递增                                │
│                                                        │
│ 3. NullEntry（分配失败）                               │
│    - 触发扩容                                          │
└────────────────────────────────────────────────────────┘

示例：
  _num_entries = 9
  _free_region = 5  （Entry 0-4 已分配）
  _free_list = 7    （Entry 7 已删除）

  alloc_entry() 返回 7，_free_list = entry(7)->next_index()
  下次 alloc_entry() 返回 5，_free_region = 6
  ...
```

### 3.6 RSHashTable::add_card()

**源码位置**：`gc/g1/sparsePRT.cpp:129-137`

```cpp
bool RSHashTable::add_card(RegionIdx_t region_ind, CardIdx_t card_index) {
  // 【Line 130】获取或创建 Entry
  SparsePRTEntry* e = entry_for_region_ind_create(region_ind);
  assert(e != NULL && e->r_ind() == region_ind, "Postcondition");

  // 【Line 133】添加 Card
  SparsePRTEntry::AddCardResult res = e->add_card(card_index);

  // 【Line 134】更新统计
  if (res == SparsePRTEntry::added) {
    _occupied_cards++;
  }

  assert(e->num_valid_cards() > 0, "Postcondition");

  // 【Line 136】返回是否成功（overflow 时返回 false）
  return res != SparsePRTEntry::overflow;
}
```

### 3.7 SparsePRT::expand()

**源码位置**：`gc/g1/sparsePRT.cpp:422-435`

```cpp
void SparsePRT::expand() {
  // 【Line 423】保存旧表
  RSHashTable* last = _next;

  // 【Line 424】创建新表（容量翻倍）
  _next = new RSHashTable(last->capacity() * 2);

  // 【Line 425-430】迁移所有 Entry
  for (size_t i = 0; i < last->num_entries(); i++) {
    SparsePRTEntry* e = last->entry((int)i);
    if (e->valid_entry()) {
      _next->add_entry(e);
    }
  }

  // 【Line 431-433】删除旧表（如果不同于 _cur）
  if (last != _cur) {
    delete last;
  }

  // 【Line 434】加入扩容链表（用于后续清理）
  add_to_expanded_list(this);
}
```

**扩容流程**：

```
扩容前：
  _cur --> RSHashTable (capacity=16)
  _next --> 同上

需要扩容：
  _cur --> RSHashTable (capacity=16)  ← 保留（迭代器可能在使用）
  _next --> RSHashTable (capacity=32) ← 新表

迁移数据：
  for each Entry in old table:
    add_entry(Entry) to new table

加入扩容链表：
  _head_expanded_list -> SparsePRT -> ...

GC 结束后 cleanup()：
  delete _cur;
  _cur = _next;
```

### 3.8 SparsePRT::add_card()

**源码位置**：`gc/g1/sparsePRT.cpp:381-386`

```cpp
bool SparsePRT::add_card(RegionIdx_t region_id, CardIdx_t card_index) {
  // 【Line 382-384】检查是否需要扩容
  if (_next->should_expand()) {
    expand();
  }

  // 【Line 385】添加 Card
  return _next->add_card(region_id, card_index);
}
```

---

## 4. 完整流程示例

### 4.1 添加引用的过程

```
应用写入引用：
  obj_in_region_A.field = obj_in_region_B;

写屏障触发：
  card_idx = get_card_index(obj_in_region_A);
  region_id = get_region_index(obj_in_region_A);

  // 记录到 Region B 的 RSet
  Region_B.rset()->add_card(region_id, card_idx);

SparsePRT::add_card(region_id=37, card_idx=5)：
  │
  ├─ _next->should_expand()?
  │   └─ 是 → expand()
  │
  └─ _next->add_card(37, 5)
      │
      ├─ entry_for_region_ind_create(37)
      │   ├─ get_entry(37) → NULL（不存在）
      │   ├─ alloc_entry() → 返回新 Entry 索引
      │   ├─ init(37)
      │   └─ 插入链表头部
      │
      └─ entry->add_card(5)
          ├─ 检查是否已存在 → 否
          ├─ 检查是否溢出 → 否
          └─ 添加到 _cards[]
```

### 4.2 哈希冲突处理

```
假设：
  capacity = 16, capacity_mask = 15
  已有 Entry: region_ind=37, Entry_index=2
  _buckets[5] = 2  (37 & 15 = 5)

添加 region_ind=53：
  1. 计算 hash = 53 & 15 = 5
  2. 检查 _buckets[5] = 2
  3. Entry 2: r_ind=37 != 53
  4. Entry 2: next_index = -1（链表末尾）
  5. 创建新 Entry，索引=3
  6. 设置 Entry 3 的 next_index = 2
  7. 设置 _buckets[5] = 3

结果：
  _buckets[5] = 3
  Entry 3: r_ind=53, next_index=2
  Entry 2: r_ind=37, next_index=-1

链表结构：
  _buckets[5] → Entry 3 (53) → Entry 2 (37) → NULL
```

### 4.3 迭代过程

**源码位置**：`gc/g1/sparsePRT.cpp:236-272`

```cpp
bool RSHashTableIter::has_next(size_t& card_index) {
  // 【Line 237】移动到下一个 Card
  _card_ind++;

  // 【Line 238-244】当前 Entry 还有 Card
  if (_bl_ind >= 0) {
    SparsePRTEntry* e = _rsht->entry(_bl_ind);
    if (_card_ind < e->num_valid_cards()) {
      CardIdx_t ci = e->card(_card_ind);
      card_index = compute_card_ind(ci);
      return true;
    }
  }

  // 【Line 247-248】移动到链表下一个 Entry
  _card_ind = 0;

  // 【Line 250-257】在当前桶的链表中查找
  if (_bl_ind != RSHashTable::NullEntry) {
    _bl_ind = _rsht->entry(_bl_ind)->next_index();
    CardIdx_t ci = find_first_card_in_list();
    if (ci != NoCardFound) {
      card_index = compute_card_ind(ci);
      return true;
    }
  }

  // 【Line 258-269】移动到下一个桶
  _tbl_ind++;
  while ((size_t)_tbl_ind < _rsht->capacity()) {
    _bl_ind = _rsht->_buckets[_tbl_ind];
    CardIdx_t ci = find_first_card_in_list();
    if (ci != NoCardFound) {
      card_index = compute_card_ind(ci);
      return true;
    }
    _tbl_ind++;
  }

  return false;
}
```

**迭代流程图**：

```
RSHashTableIter 迭代顺序：

┌────────────────────────────────────────────────────────┐
│ 初始化：                                                │
│  _tbl_ind = -1                                         │
│  _bl_ind = -1                                          │
│  _card_ind = cards_num() - 1                           │
└────────────────────────────────────────────────────────┘
                    │
                    ▼
┌────────────────────────────────────────────────────────┐
│ 第一步：移动到下一个桶                                  │
│  _tbl_ind++                                            │
│  _bl_ind = _buckets[_tbl_ind]                          │
└────────────────────────────────────────────────────────┘
                    │
                    ▼
┌────────────────────────────────────────────────────────┐
│ 第二步：遍历链表                                        │
│  while (_bl_ind != NullEntry) {                        │
│    Entry = entry(_bl_ind)                              │
│    for each card in Entry:                             │
│      return (region_ind * CardsPerRegion + card)       │
│    _bl_ind = Entry->next_index()                       │
│  }                                                     │
└────────────────────────────────────────────────────────┘
                    │
                    ▼
              回到第一步
```

---

## 5. 并发访问与双缓冲

### 5.1 问题：为什么需要双缓冲？

**场景**：
1. GC 开始时，迭代器开始遍历 `_cur` 表
2. GC 运行期间，应用线程可能修改 RSet（写入新引用）
3. 如果直接修改 `_cur`，迭代器可能看到不一致的数据

**解决方案**：
- `_cur`：只读，迭代器使用
- `_next`：可写，修改操作使用
- GC 结束时，`cleanup()` 同步两个表

### 5.2 实现细节

**写入操作**：

```cpp
bool SparsePRT::add_card(RegionIdx_t region_id, CardIdx_t card_index) {
  if (_next->should_expand()) {
    expand();  // 只扩容 _next
  }
  return _next->add_card(region_id, card_index);  // 写入 _next
}
```

**读取操作**：

```cpp
SparsePRTIter::SparsePRTIter(const SparsePRT* sprt) :
  RSHashTableIter(sprt->cur()) {}  // 迭代 _cur
```

**清理操作**：

```cpp
void SparsePRT::cleanup() {
  if (_cur != _next) {
    delete _cur;  // 删除旧表
  }
  _cur = _next;   // 同步
  set_expanded(false);
}
```

### 5.3 扩容链表

**为什么需要扩容链表？**

扩容后，旧表可能还被迭代器引用，不能立即删除。需要延迟到 GC 结束时清理。

**全局链表**：

```cpp
static SparsePRT* volatile _head_expanded_list;

void SparsePRT::add_to_expanded_list(SparsePRT* sprt) {
  if (sprt->expanded()) return;  // 避免重复添加
  sprt->set_expanded(true);

  // CAS 操作，线程安全
  SparsePRT* hd = _head_expanded_list;
  while (true) {
    sprt->_next_expanded = hd;
    SparsePRT* res = Atomic::cmpxchg(sprt, &_head_expanded_list, hd);
    if (res == hd) return;
    else hd = res;
  }
}
```

**清理过程**：

```cpp
void SparsePRT::cleanup_all() {
  SparsePRT* sprt = get_from_expanded_list();
  while (sprt != NULL) {
    sprt->cleanup();  // 使 _cur = _next
    sprt = get_from_expanded_list();
  }
}
```

---

## 6. 容量与溢出

### 6.1 容量限制

**Entry 容量**：
- 初始：`InitialCapacity = 16` 桶
- 每桶最多存储：`G1RSetSparseRegionEntries` 个 Card（默认4）
- Entry 数组大小：`_num_entries = capacity * 0.5 + 1`

**扩容触发条件**：

```cpp
bool should_expand() const {
  return _occupied_entries == _num_entries;
}
```

**Entry 溢出条件**：

```cpp
if (num_valid_cards() < cards_num() - 1) {
  // 还有空间
} else {
  // 溢出，需要迁移到 Fine Grain Table
}
```

### 6.2 溢出处理

当 `SparsePRTEntry::add_card()` 返回 `overflow` 时：

```cpp
// 在 OtherRegionsTable::add_reference() 中处理
if (!_sparse_table.add_card(from_region, card_index)) {
  // SparsePRT 溢出，迁移到 Fine Grain Table
  ...
}
```

---

## 7. 内存占用分析

### 7.1 初始大小

```
RSHashTable (capacity=16)：
  _buckets: 16 * 4 = 64 bytes
  _entries: 9 * 24 = 216 bytes
  RSHashTable 结构：~40 bytes
  总计：~320 bytes

SparsePRT：
  两个 RSHashTable (初始 _cur == _next)
  总计：~320 bytes
```

### 7.2 扩容后大小

```
扩容一次后 (capacity=32)：
  _cur (capacity=16)：~320 bytes
  _next (capacity=32)：
    _buckets: 32 * 4 = 128 bytes
    _entries: 17 * 24 = 408 bytes
    总计：~580 bytes

  SparsePRT 总计：320 + 580 = ~900 bytes
```

### 7.3 最大容量

```
多次扩容后（假设 capacity=1024）：
  _buckets: 1024 * 4 = 4 KB
  _entries: 513 * 24 = ~12 KB
  单个 RSHashTable：~16 KB

  SparsePRT（双缓冲）：~32 KB
```

---

## 8. GDB 验证脚本

### 8.1 查看 SparsePRT 结构

```bash
cat > /data/workspace/openjdk-cut-new/jvm-md/tmp-file/sparseprt/verify_structure.gdb << 'EOF'
# 打印 SparsePRTEntry 结构
define print_entry
  set $e = (SparsePRTEntry*)$arg0
  printf "Entry: region_ind=%d, next_index=%d, next_null=%d\n", \
         $e->_region_ind, $e->_next_index, $e->_next_null
  printf "  Cards: "
  set $i = 0
  while $i < $e->_next_null
    printf "%d ", $e->_cards[$i]
    set $i = $i + 1
  end
  printf "\n"
end

# 打印 RSHashTable 统计
define print_rsht_stats
  set $ht = (RSHashTable*)$arg0
  printf "HashTable: capacity=%d, num_entries=%d\n", \
         $ht->_capacity, $ht->_num_entries
  printf "  occupied_entries=%d, occupied_cards=%d\n", \
         $ht->_occupied_entries, $ht->_occupied_cards
  printf "  free_region=%d, free_list=%d\n", \
         $ht->_free_region, $ht->_free_list
end

# 打印 SparsePRT 状态
define print_sprt
  set $sprt = (SparsePRT*)$arg0
  printf "SparsePRT: expanded=%d\n", $sprt->_expanded
  printf "_cur:\n"
  print_rsht_stats $sprt->_cur
  printf "_next:\n"
  print_rsht_stats $sprt->_next
end

break HeapRegionRemSet::add_reference

commands 1
  printf "\n=== Adding Reference ===\n"
  continue
end

run
EOF
```

### 8.2 追踪扩容过程

```bash
cat > /data/workspace/openjdk-cut-new/jvm-md/tmp-file/sparseprt/trace_expand.gdb << 'EOF'
break SparsePRT::expand

commands 1
  printf "\n=== SparsePRT Expand ===\n"
  printf "Before: capacity=%d\n", ((SparsePRT*)this)->_next->_capacity
  printf "After: capacity=%d\n", ((SparsePRT*)this)->_next->_capacity * 2
  continue
end

run
EOF
```

### 8.3 查看哈希表内容

```bash
cat > /data/workspace/openjdk-cut-new/jvm-md/tmp-file/sparseprt/dump_table.gdb << 'EOF'
define dump_rsht
  set $ht = (RSHashTable*)$arg0
  printf "=== RSHashTable Dump ===\n"
  printf "Capacity: %d, Entries: %d\n", $ht->_capacity, $ht->_num_entries

  set $bucket = 0
  while $bucket < $ht->_capacity
    set $entry_ind = $ht->_buckets[$bucket]
    if $entry_ind != -1
      printf "Bucket %d: ", $bucket
      while $entry_ind != -1
        set $e = $ht->entry($entry_ind)
        printf "[%d:r%d:c%d] ", $entry_ind, $e->_region_ind, $e->_next_null
        set $entry_ind = $e->_next_index
      end
      printf "\n"
    end
    set $bucket = $bucket + 1
  end
end

break G1CollectedHeap::collect

commands 1
  printf "\n=== Before GC ===\n"
  continue
end

run
EOF
```

---

## 9. 关键问题与解答

### Q1: 为什么 SparsePRT 要用变长 Entry？

**A**:
- `G1RSetSparseRegionEntries` 可配置，不同配置需要不同 Entry 大小
- 变长数组允许在编译时确定部分大小，运行时分配完整大小
- 避免硬编码，提高灵活性

### Q2: 为什么用开链法而不是开放寻址法？

**A**:
- **删除操作频繁**：GC 可能删除 Entry，开链法删除简单
- **内存连续**：Entry 数组连续，缓存友好
- **负载因子控制**：开链法对高负载更稳定

### Q3: 为什么需要双缓冲？

**A**:
- **读写分离**：迭代器读 `_cur`，写操作修改 `_next`
- **避免锁**：读操作无需加锁
- **一致性**：迭代器看到的是 GC 开始时的快照

### Q4: SparsePRT 什么时候溢出？

**A**:
- 单个 Entry 满时（Card 数达到 `cards_num() - 1`）
- 此时返回 `false`，调用者需要迁移到 Fine Grain Table
- Entry 数量满时触发扩容，而非溢出

### Q5: 如何调整 SparsePRT 容量？

**A**:
- `G1RSetSparseRegionEntries`：每个 Entry 存储的 Card 数（默认4）
- 增大可以存储更多 Card，但增加内存占用
- 减小会更快溢出到 Fine Grain Table

---

## 10. 源码位置索引

| 文件 | 行号 | 内容 |
|------|------|------|
| `gc/g1/sparsePRT.hpp` | 46-110 | SparsePRTEntry 类定义 |
| `gc/g1/sparsePRT.hpp` | 112-187 | RSHashTable 类定义 |
| `gc/g1/sparsePRT.hpp` | 225-320 | SparsePRT 类定义 |
| `gc/g1/sparsePRT.cpp` | 40-49 | SparsePRTEntry::init() |
| `gc/g1/sparsePRT.cpp` | 60-73 | SparsePRTEntry::add_card() |
| `gc/g1/sparsePRT.cpp` | 90-100 | RSHashTable 构造函数 |
| `gc/g1/sparsePRT.cpp` | 129-137 | RSHashTable::add_card() |
| `gc/g1/sparsePRT.cpp` | 139-153 | RSHashTable::get_entry() |
| `gc/g1/sparsePRT.cpp` | 175-189 | entry_for_region_ind_create() |
| `gc/g1/sparsePRT.cpp` | 191-204 | alloc_entry() |
| `gc/g1/sparsePRT.cpp` | 236-272 | RSHashTableIter::has_next() |
| `gc/g1/sparsePRT.cpp` | 422-435 | SparsePRT::expand() |
| `gc/g1/sparsePRT.cpp` | 381-386 | SparsePRT::add_card() |

---

## 11. 总结

**SparsePRT 的核心思想**：
1. **稀疏存储**：为扇出小的 Region 提供高效存储
2. **哈希表 + 开链法**：O(1) 查找，简单删除
3. **双缓冲**：支持并发读写分离
4. **自动扩容**：适应数据增长
5. **溢出迁移**：超出容量时迁移到下一层

**性能特点**：
- **空间效率**：小扇出时占用少
- **访问效率**：哈希查找 O(1)，Card 遍历 O(n)
- **并发友好**：读写分离，无锁迭代

**与其他存储层的关系**：
- SparsePRT → Fine Grain Table → Coarse Map
- 逐层退化，平衡内存与精度
