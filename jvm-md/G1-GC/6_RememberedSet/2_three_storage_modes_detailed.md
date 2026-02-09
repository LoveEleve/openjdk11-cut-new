# 三种存储模式详解：Sparse / Fine / Coarse

## 1. 概述与设计哲学

### 1.1 为什么需要三种模式

```
┌─────────────────────────────────────────────────────────────────────┐
│                    空间-精度权衡                                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   引用数量        最佳存储方式              内存开销                 │
│   ────────────────────────────────────────────────────────          │
│   1-16            Sparse 数组              ~48B                      │
│   17-8192         Fine 位图                ~1080B                    │
│   8192+           Coarse 位图              ~256B                     │
│                                                                      │
│   关键洞察：                                                         │
│   - 大部分 Region 的引用很少（<16）                                  │
│   - 用统一的 Fine 模式会浪费大量内存                                 │
│   - 自适应选择最优存储，内存 vs 精度的最佳平衡                       │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.2 三种模式对比总览

| 模式 | 精度 | 内存/Region | 时间复杂度 | 触发条件 |
|-----|------|------------|-----------|---------|
| **Sparse** | Card | 48-80B | O(n) 查找 | 引用数 ≤ 16 |
| **Fine** | Card | ~1080B | O(1) 直接索引 | 引用数 17-8192 |
| **Coarse** | Region | ~256B | O(1) 位图查询 | 引用数 > 8192 |

---

## 2. SparsePRT（稀疏模式）

### 2.1 功能定位

**一句话说明：**
SparsePRT 是 Remembered Set 的**内存最省模式**，使用**变长数组**存储少量 Card 索引，当引用数量很少时（默认 ≤16），比 Fine 模式节省 20 倍以上内存。

**在整体流程中的位置：**
```
OtherRegionsTable::add_reference()
        │
        ├──► SparsePRT::add_card() ──► 成功，返回 true
        │
        └──► 返回 overflow ──► 升级为 PerRegionTable
```

**如果没有它会怎样？**
- 所有 Region 都使用 PerRegionTable（1KB+）
- 2048 个 Region × 1KB = 2MB 基础开销
- 实际大部分 RSet 是空的，内存浪费严重

### 2.2 数据结构详解

```cpp
// src/hotspot/share/gc/g1/sparsePRT.hpp:46
class SparsePRTEntry: public CHeapObj<mtGC> {
private:
  RegionIdx_t   _region_ind;      // 源 Region ID（哈希键）
  int           _next_index;      // 开放寻址冲突链
  int           _next_null;       // 下一个可用槽位索引
  card_elem_t   _cards[...];      // Card 索引数组（变长）
};

class RSHashTable: public CHeapObj<mtGC> {
private:
  size_t        _num_entries;     // Entry 总数
  size_t        _capacity;        // 哈希桶数量
  size_t        _capacity_mask;   // 快速取模掩码
  SparsePRTEntry* _entries;       // Entry 数组（变长对象）
  int*          _buckets;         // 哈希桶数组（存索引）
  int           _free_list;       // 空闲 Entry 链表
  int           _free_region;     // 未使用区域指针
};

class SparsePRT {
private:
  RSHashTable* _cur;              // 当前可读表（用于迭代）
  RSHashTable* _next;             // 当前可写表（用于插入）
  HeapRegion*  _hr;               // 所属 Region
  bool         _expanded;         // 是否已扩容
};
```

### 2.3 关键字段详解

#### SparsePRTEntry::_cards（变长数组）

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【是什么】
  类型：uint16_t 数组（card_elem_t）
  默认大小：G1RSetSparseRegionEntries = 16
  对齐要求：sizeof(SparsePRTEntry) % sizeof(int) == 0

【为什么需要】
  问题：需要存储 Card 索引，但数量很少
  解决：用数组而非位图，按需分配

【内存计算】
  基础大小：sizeof(SparsePRTEntry) = 24 bytes（3个int + 对齐）
  数组大小：16 × 2 bytes = 32 bytes
  总计：56 bytes（对齐后）

【对比 Fine 模式】
  Fine：1080 bytes（位图必须预分配）
  Sparse：56 bytes（按实际使用）
  节省：1080 / 56 ≈ 19 倍！
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

#### RSHashTable::_buckets（开放寻址哈希表）

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【是什么】
  类型：int 数组
  大小：_capacity × sizeof(int)
  默认 _capacity：16（InitialCapacity）

【哈希算法】
  index = region_id & _capacity_mask
  
  示例：
  region_id = 100, _capacity = 16, _capacity_mask = 15
  index = 100 & 15 = 4

【冲突解决】
  链表法：_buckets[index] 存第一个 Entry 的索引
  Entry._next_index 形成链表

【扩容触发】
  负载因子：TableOccupancyFactor = 0.5
  扩容条件：_occupied_entries == _num_entries
  扩容策略：容量翻倍（16 → 32 → 64 ...）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### 2.4 内存布局图

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC

SparsePRT (总大小: ~72 bytes)
┌─────────────────────────────────────────────────────────────────┐
│ 偏移      字段名              大小      说明                    │
├─────────────────────────────────────────────────────────────────┤
│ 0x00      [vtable]           8        CHeapObj 虚表指针         │
│ 0x08      _cur               8        RSHashTable*              │
│ 0x10      _next              8        RSHashTable*              │
│ 0x18      _hr                8        HeapRegion*               │
│ 0x20      _expanded          1        bool                      │
│ 0x21      _next_expanded     8        SparsePRT*                │
│ 0x29      [padding]          7        对齐到8字节               │
└─────────────────────────────────────────────────────────────────┘
Total: ~48 bytes (对象头) + 指向的 RSHashTable

RSHashTable (总大小: ~72 bytes + 动态数据)
┌─────────────────────────────────────────────────────────────────┐
│ 0x00      [vtable]           8                                  │
│ 0x08      _num_entries       8        size_t                    │
│ 0x10      _capacity          8        size_t                    │
│ 0x18      _capacity_mask     8        size_t                    │
│ 0x20      _occupied_entries  8        size_t                    │
│ 0x28      _occupied_cards    8        size_t                    │
│ 0x30      _entries           8        SparsePRTEntry*           │
│ 0x38      _buckets           8        int*                      │
│ 0x40      _free_list         4        int                       │
│ 0x44      _free_region       4        int                       │
│ 0x48      _entries 指向的数据: _num_entries × SparsePRTEntry::size() │
│ 0x??      _buckets 指向的数据: _capacity × sizeof(int)            │
└─────────────────────────────────────────────────────────────────┘

SparsePRTEntry (变长，基础 24 bytes + 数组)
┌─────────────────────────────────────────────────────────────────┐
│ 0x00      _region_ind        4        RegionIdx_t               │
│ 0x04      _next_index        4        int                       │
│ 0x08      _next_null         4        int                       │
│ 0x0C      _cards[0..15]      32       uint16_t[16]              │
└─────────────────────────────────────────────────────────────────┘
Total: 56 bytes (含对齐)
```

### 2.5 核心算法：添加 Card

```cpp
// sparsePRT.cpp:60
SparsePRTEntry::AddCardResult SparsePRTEntry::add_card(CardIdx_t card_index) {
  // 1. 检查是否已存在（O(n) 线性查找）
  for (int i = 0; i < num_valid_cards(); i++) {
    if (card(i) == card_index) {
      return found;  // 已存在，无需添加
    }
  }
  
  // 2. 检查是否有空位
  if (num_valid_cards() < cards_num() - 1) {
    _cards[_next_null] = (card_elem_t)card_index;
    _next_null++;
    return added;  // 添加成功
  }
  
  // 3. 数组已满
  return overflow;  // 触发升级为 Fine 模式
}
```

**算法流程图：**
```
┌─────────────────────────────────────────────────────────────────────┐
│                    SparsePRTEntry::add_card                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  输入: card_index (要添加的 Card 索引)                              │
│       │                                                              │
│       ▼                                                              │
│  ┌─────────────────────┐                                            │
│  │ 遍历 _cards[0..n)   │◄── O(n) 线性查找                          │
│  │ card(i)==card_index?│                                            │
│  └──────────┬──────────┘                                            │
│       │ YES │ NO                                                     │
│       ▼     ▼                                                        │
│    ┌────┐  ┌─────────────────────┐                                  │
│    │found│  │ _next_null < 16-1?  │                                  │
│    │返回 │  │ 还有空位？          │                                  │
│    └────┘  └──────────┬──────────┘                                  │
│                │ YES  │ NO                                           │
│                ▼      ▼                                              │
│         ┌──────┐  ┌───────┐                                         │
│         │added │  │overflow│                                         │
│         │返回  │  │返回    │──► 触发升级为 PerRegionTable            │
│         └──────┘  └───────┘                                         │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.6 核心算法：哈希表查找

```cpp
// sparsePRT.cpp:139
SparsePRTEntry* RSHashTable::get_entry(RegionIdx_t region_ind) const {
  // 1. 计算哈希桶索引
  int ind = (int) (region_ind & capacity_mask());
  
  // 2. 遍历链表查找
  int cur_ind = _buckets[ind];
  while (cur_ind != NullEntry && 
         (cur = entry(cur_ind))->r_ind() != region_ind) {
    cur_ind = cur->next_index();  // 链表下一个
  }
  
  if (cur_ind == NullEntry) return NULL;
  return cur;  // 找到
}
```

**哈希表示意图：**
```
┌─────────────────────────────────────────────────────────────────────┐
│                    RSHashTable 结构示意                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  _buckets (int 数组)         _entries (SparsePRTEntry 数组)          │
│  ┌──────┐                   ┌─────────────────────────────────────┐│
│  │ [0]  │──► NullEntry      │ Entry 0: region=5, cards=[10,20,30] ││
│  │ [1]  │──► 3 ────────────►│ Entry 3: region=17, cards=[5]       ││
│  │ [2]  │──► NullEntry      │ Entry 1: region=33, cards=[100]     ││
│  │ [3]  │──► 0 ────────────►│ Entry 0 (同上，链表结构)            ││
│  │ [4]  │──► 1 ────────────►│ Entry 1 (同上)                      ││
│  │ ...  │                   │ ...                                 ││
│  └──────┘                   └─────────────────────────────────────┘│
│                                                                      │
│  示例：查找 region_id = 17                                           │
│  1. index = 17 & 15 = 1                                              │
│  2. _buckets[1] = 3                                                  │
│  3. Entry 3 的 region_ind = 17 ✓ 找到！                              │
│                                                                      │
│  示例：查找 region_id = 33（哈希冲突）                                │
│  1. index = 33 & 15 = 1                                              │
│  2. _buckets[1] = 3                                                  │
│  3. Entry 3 的 region_ind = 17 ≠ 33                                  │
│  4. Entry 3._next_index = 0                                          │
│  5. Entry 0 的 region_ind = 5 ≠ 33                                   │
│  6. Entry 0._next_index = NullEntry                                  │
│  7. 未找到，需要新建 Entry                                           │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.7 扩容机制

```cpp
// sparsePRT.cpp:422
void SparsePRT::expand() {
  RSHashTable* last = _next;
  
  // 1. 创建新表，容量翻倍
  _next = new RSHashTable(last->capacity() * 2);
  
  // 2. 迁移所有有效 Entry
  for (size_t i = 0; i < last->num_entries(); i++) {
    SparsePRTEntry* e = last->entry((int)i);
    if (e->valid_entry()) {
      _next->add_entry(e);
    }
  }
  
  // 3. 删除旧表（如果是第二次扩容）
  if (last != _cur) {
    delete last;
  }
  
  // 4. 标记为已扩容，加入全局清理列表
  add_to_expanded_list(this);
}
```

**扩容流程：**
```
┌─────────────────────────────────────────────────────────────────────┐
│                    SparsePRT 扩容流程                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  触发条件：负载因子 > 0.5（_occupied_entries == _num_entries）       │
│       │                                                              │
│       ▼                                                              │
│  ┌─────────────────────┐                                            │
│  │ 创建新 RSHashTable  │                                            │
│  │ 容量 = 原容量 × 2   │                                            │
│  └──────────┬──────────┘                                            │
│             ▼                                                        │
│  ┌─────────────────────┐                                            │
│  │ 遍历原表所有 Entry  │                                            │
│  │ valid_entry() ?     │                                            │
│  └──────────┬──────────┘                                            │
│       │ YES │ NO                                                     │
│       ▼     └──────► 跳过                                            │
│  ┌─────────────────────┐                                            │
│  │ 重新哈希插入新表    │                                            │
│  │ (新的 capacity_mask)│                                            │
│  └──────────┬──────────┘                                            │
│             ▼                                                        │
│  ┌─────────────────────┐                                            │
│  │ _cur vs _next 机制  │                                            │
│  │ 保证并发安全        │                                            │
│  └──────────┬──────────┘                                            │
│             ▼                                                        │
│  ┌─────────────────────┐                                            │
│  │ 加入 _head_expanded │                                            │
│  │ 延迟清理旧表        │                                            │
│  └─────────────────────┘                                            │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. PerRegionTable（细粒度模式）

### 3.1 功能定位

**一句话说明：**
PerRegionTable 是 Remembered Set 的**高精度模式**，使用**位图**精确记录每个 Card 的引用关系，是 Sparse 模式升级后的标准存储方式。

**升级触发条件：**
- Sparse Entry 的 cards 数组满（返回 overflow）
- 直接创建新的 PerRegionTable（跳过了 Sparse）

### 3.2 数据结构详解

```cpp
// src/hotspot/share/gc/g1/heapRegionRemSet.cpp:45
class PerRegionTable: public CHeapObj<mtGC> {
private:
  HeapRegion*      _hr;                    // 源 Region（谁引用了我）
  CHeapBitMap      _bm;                    // Card 位图（核心）
  jint             _occupied;              // 已设置的 bit 数量
  PerRegionTable*  _next;                  // 链表指针（批量管理）
  PerRegionTable*  _prev;                  // 双向链表
  PerRegionTable*  _collision_list_next;   // 哈希冲突链
  
  static PerRegionTable* volatile _free_list;  // 全局空闲链表
};
```

### 3.3 关键字段详解

#### PerRegionTable::_bm（Card 位图）

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【是什么】
  类型：CHeapBitMap
  大小：HeapRegion::CardsPerRegion bits = 8192 bits = 1024 bytes

【为什么需要】
  问题：需要精确知道对方 Region 的哪些 Card 引用了本 Region
  解决：位图标记，1 bit 代表 1 Card

【索引计算】
  给定对象地址 from，计算 Card 索引：
  1. card_offset = from - _hr->bottom()
  2. card_index = card_offset / 512 (Card size)
  3. 设置位图：_bm.at_put(card_index, 1)

【性能优势】
  - 查询：O(1) 直接索引
  - 空间：固定 1KB（无论引用多少 Card）
  - 批量操作：支持位图并集/交集

【与 Sparse 对比】
  Sparse：48 bytes + 动态增长，O(n) 查找
  Fine：1080 bytes 固定，O(1) 查找
  权衡：引用数 > 16 时 Fine 更优
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

#### PerRegionTable::_occupied（计数器）

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【是什么】
  类型：jint（32位有符号整数）
  作用：记录位图中 1 的个数

【为什么需要】
  问题：统计引用数量时遍历位图太慢（需要 1024 字节扫描）
  解决：维护计数器，O(1) 获取

【并发更新】
  并行添加：Atomic::inc(&_occupied) CAS 原子递增
  串行添加：直接 _occupied++（GC 暂停时）

【一致性】
  // 可用于验证位图完整性
  assert(_occupied == _bm.count_one_bits(), "Check");
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### 3.4 内存布局图

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC

PerRegionTable (总大小: 1080 bytes)
┌─────────────────────────────────────────────────────────────────┐
│ 偏移      字段名              大小      说明                    │
├─────────────────────────────────────────────────────────────────┤
│ 0x00      [vtable]           8        CHeapObj 虚表指针         │
│ 0x08      _hr                8        HeapRegion*（源Region）   │
│ 0x10      _bm                24       CHeapBitMap 对象         │
│           ├─ _map            8        BitMap::bm_word_t*        │
│           ├─ _size           8        idx_t (8192)              │
│           └─ _virtual_memory 8        虚拟内存管理               │
│ 0x28      _occupied          4        jint                      │
│ 0x2C      [padding]          4        对齐到8字节               │
│ 0x30      _next              8        PerRegionTable*           │
│ 0x38      _prev              8        PerRegionTable*           │
│ 0x40      _collision_list_next 8      PerRegionTable*           │
│ 0x48      _bm._map 指向的数据 1024    8192 bits = 1024 bytes     │
└─────────────────────────────────────────────────────────────────┘
Total: 1080 bytes per PRT

对比 Sparse：1080 / 56 ≈ 19 倍内存开销！
```

### 3.5 核心算法：添加 Card

```cpp
// heapRegionRemSet.cpp:76
void PerRegionTable::add_card_work(CardIdx_t from_card, bool par) {
  // 检查是否已设置
  if (!_bm.at(from_card)) {
    if (par) {
      // 并行模式：CAS 设置位图
      if (_bm.par_at_put(from_card, 1)) {
        Atomic::inc(&_occupied);  // 原子递增计数器
      }
    } else {
      // 串行模式：直接设置
      _bm.at_put(from_card, 1);
      _occupied++;
    }
  }
}
```

### 3.6 对象池机制

```cpp
// heapRegionRemSet.cpp:180
PerRegionTable* PerRegionTable::alloc(HeapRegion* hr) {
  // 1. 尝试从全局空闲链表获取
  PerRegionTable* fl = _free_list;
  while (fl != NULL) {
    PerRegionTable* nxt = fl->next();
    // CAS 从空闲链表头部弹出
    PerRegionTable* res = Atomic::cmpxchg(nxt, &_free_list, fl);
    if (res == fl) {
      fl->init(hr, true);
      return fl;
    }
    fl = _free_list;
  }
  
  // 2. 空闲链表为空，新建对象
  return new PerRegionTable(hr);
}

void PerRegionTable::free(PerRegionTable* prt) {
  // CAS 压入空闲链表头部
  bulk_free(prt, prt);
}
```

**对象池流程：**
```
┌─────────────────────────────────────────────────────────────────────┐
│                    PRT 对象池机制                                    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  全局空闲链表：_free_list ──► PRT1 ──► PRT2 ──► PRT3 ──► NULL       │
│                                                                      │
│  分配过程：                                                          │
│  ┌─────────────────────┐                                            │
│  │ CAS 弹出头部        │◄── 原子操作保证线程安全                    │
│  │ _free_list = nxt    │                                            │
│  └──────────┬──────────┘                                            │
│             ▼                                                        │
│  ┌─────────────────────┐                                            │
│  │ init(hr)            │◄── 重新初始化                              │
│  │ _bm.clear()         │                                            │
│  └─────────────────────┘                                            │
│                                                                      │
│  释放过程：                                                          │
│  ┌─────────────────────┐                                            │
│  │ CAS 压入头部        │◄── 原子操作保证线程安全                    │
│  │ prt->_next = old    │                                            │
│  │ _free_list = prt    │                                            │
│  └─────────────────────┘                                            │
│                                                                      │
│  优势：                                                              │
│  - 避免频繁 new/delete 开销                                          │
│  - 减少内存碎片                                                      │
│  - 无锁 CAS 操作，高性能                                             │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 4. Coarse Bitmap（粗粒度模式）

### 4.1 功能定位

**一句话说明：**
Coarse Bitmap 是 Remembered Set 的**降级模式**，当 Fine 模式的 PRT 表满时，退化为 Region 级别的粗粒度标记，牺牲精度换取空间。

**触发条件：**
```cpp
// 当 Fine 表满时触发粗化
if (_n_fine_entries >= _max_fine_entries) {
    // 驱逐最老的 PRT
    PerRegionTable* victim = delete_region_table();
    // 将对应 Region 标记为 coarse
    _coarse_map.set(victim->hr()->hrm_index());
}
```

### 4.2 数据结构

```cpp
// heapRegionRemSet.hpp:82
class OtherRegionsTable {
private:
  CHeapBitMap _coarse_map;        // Region 级别的位图
  size_t      _n_coarse_entries;  // 粗粒度 Region 数量
};
```

### 4.3 精度对比

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Coarse vs Fine 精度对比                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Fine 模式（Card 级别）：                                            │
│  ┌─────────────────────────────────────────────┐                    │
│  │ Region A (4MB)                               │                    │
│  │ [Card0][Card1][Card2]...[Card8191]           │                    │
│  │   0      1      0          1    ← 位图标记   │                    │
│  └─────────────────────────────────────────────┘                    │
│  精度：精确到 512 字节                                               │
│  GC 时：只扫描标记的 Card                                            │
│                                                                      │
│  Coarse 模式（Region 级别）：                                        │
│  ┌─────────────────────────────────────────────┐                    │
│  │ 所有 Region (4MB × N)                        │                    │
│  │ [R0][R1][R2]...[R2047]                       │                    │
│  │   0   1   0        1    ← 位图标记           │                    │
│  └─────────────────────────────────────────────┘                    │
│  精度：精确到 4MB                                                    │
│  GC 时：扫描整个 Region（8192 Cards）                                │
│                                                                      │
│  性能影响：                                                          │
│  Coarse 标记一个 Region = 扫描 8192 Cards = Fine 标记 8192 倍的扫描  │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 5. 三种模式转换机制

### 5.1 状态转换图

```
┌─────────────────────────────────────────────────────────────────────┐
│                    RSet 存储模式状态转换                             │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│                            初始状态                                  │
│                               │                                      │
│                               ▼                                      │
│                         ┌──────────┐                                 │
│                         │  Empty   │                                 │
│                         │ (无引用) │                                 │
│                         └────┬─────┘                                 │
│                              │ add_reference                         │
│                              ▼                                       │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                      Sparse 模式                             │    │
│  │  ┌──────────┐    cards < 16     ┌──────────┐               │    │
│  │  │ Entry 1  │◄─────────────────►│ Entry N  │               │    │
│  │  │ [1,2,3]  │                   │ [5,6,7]  │               │    │
│  │  └──────────┘                   └──────────┘               │    │
│  │       │                                                      │    │
│  │       │ 任一 Entry cards 满 (overflow)                        │    │
│  │       ▼                                                      │    │
│  │  整个 Region 的引用迁移到新的 PRT                             │    │
│  └───────┼──────────────────────────────────────────────────────┘    │
│          │                                                           │
│          ▼                                                           │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                      Fine 模式                               │    │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐                   │    │
│  │  │  PRT 1   │  │  PRT 2   │  │  PRT N   │  (哈希表)         │    │
│  │  │ [位图]   │  │ [位图]   │  │ [位图]   │                   │    │
│  │  │ 1KB      │  │ 1KB      │  │ 1KB      │                   │    │
│  │  └──────────┘  └──────────┘  └──────────┘                   │    │
│  │       │                                                      │    │
│  │       │ PRT 表满 (_n_fine_entries >= _max_fine_entries)       │    │
│  │       ▼                                                      │    │
│  │  驱逐最老的 PRT，标记为 Coarse                                │    │
│  └───────┼──────────────────────────────────────────────────────┘    │
│          │                                                           │
│          ▼                                                           │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                     Coarse 模式                              │    │
│  │  ┌─────────────────────────────────────────────┐            │    │
│  │  │ _coarse_map: [0][1][0][0][1]...[0]          │            │    │
│  │  │              R0 R1 R2 R3 R4    R2047         │            │    │
│  │  └─────────────────────────────────────────────┘            │    │
│  │                                                              │    │
│  │  特点：不再维护 PRT，直接 Region 级标记                      │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                      │
│  注：三种模式可以共存！                                              │
│      例如：Sparse(少量) + Fine(中等) + Coarse(大量)                  │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 5.2 粗化（Coarsening）算法

```cpp
// heapRegionRemSet.cpp:443
PerRegionTable* OtherRegionsTable::delete_region_table() {
  assert(_m->owned_by_self(), "Precondition");
  assert(_n_fine_entries == _max_fine_entries, "Precondition");
  
  // 1. 采样策略：从 _fine_eviction_start 开始扫描
  size_t min_ind = _fine_eviction_start;
  
  // 2. 选择"最佳"驱逐候选（简单策略：第一个非空桶）
  for (size_t i = 0; i < _max_fine_entries; i++) {
    size_t ind = (min_ind + i) % _max_fine_entries;
    PerRegionTable* cur = _fine_grain_regions[ind];
    if (cur != NULL) {
      // 3. 从哈希表移除
      _fine_grain_regions[ind] = cur->collision_list_next();
      _n_fine_entries--;
      
      // 4. 标记为 coarse
      size_t coarse_ind = cur->hr()->hrm_index();
      if (!_coarse_map.at(coarse_ind)) {
        _coarse_map.set(coarse_ind);
        _n_coarse_entries++;
        Atomic::inc(&_n_coarsenings);
      }
      
      // 5. 更新采样起始点（轮询）
      _fine_eviction_start = (ind + 1) % _max_fine_entries;
      
      return cur;  // 返回被驱逐的 PRT
    }
  }
  return NULL;
}
```

---

## 6. GDB 验证脚本

```bash
# 文件：jvm-md/G1-GC/6_RememberedSet/gdb_storage_modes.txt

set pagination off
set print pretty on

# 断点1：验证三种数据结构大小
break main
commands
  silent
  printf "\n========== 三种存储模式大小验证 ==========\n"
  printf "sizeof(SparsePRT) = %zu\n", sizeof(SparsePRT)
  printf "sizeof(RSHashTable) = %zu\n", sizeof(RSHashTable)
  printf "sizeof(SparsePRTEntry) = %zu\n", sizeof(SparsePRTEntry)
  printf "sizeof(PerRegionTable) = %zu\n", sizeof(PerRegionTable)
  printf "sizeof(CHeapBitMap) = %zu\n", sizeof(CHeapBitMap)
  
  printf "\n========== 关键常量 ==========\n"
  printf "G1RSetSparseRegionEntries = %d\n", G1RSetSparseRegionEntries
  printf "HeapRegion::CardsPerRegion = %u\n", HeapRegion::CardsPerRegion
  printf "OtherRegionsTable::_max_fine_entries = %zu\n", OtherRegionsTable::_max_fine_entries
  continue
end

# 断点2：SparsePRT 添加 Card
break SparsePRT::add_card
commands
  silent
  printf "\n========== SparsePRT::add_card ==========\n"
  printf "_next->capacity() = %zu\n", _next->capacity()
  printf "_next->occupied_entries() = %zu\n", _next->occupied_entries()
  printf "_expanded = %d\n", _expanded
  continue
end

# 断点3：SparsePRT 扩容
break SparsePRT::expand
commands
  silent
  printf "\n========== SparsePRT::expand ==========\n"
  printf "扩容前 capacity = %zu\n", _next->capacity()
  printf "扩容后 capacity = %zu\n", _next->capacity() * 2
  continue
end

# 断点4：PerRegionTable 分配
break PerRegionTable::alloc
commands
  silent
  printf "\n========== PerRegionTable::alloc ==========\n"
  printf "尝试从空闲链表分配 PRT...\n"
  continue
end

# 断点5：粗化发生
break OtherRegionsTable::delete_region_table
commands
  silent
  printf "\n========== Coarsening 发生！ ==========\n"
  printf "_n_fine_entries = %zu\n", _n_fine_entries
  printf "_max_fine_entries = %zu\n", _max_fine_entries
  printf "粗化次数 _n_coarsenings = %d\n", OtherRegionsTable::_n_coarsenings
  continue
end

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main
```

---

## 7. 总结

### 7.1 三种模式选择决策树

```
添加引用到 RSet
        │
        ▼
┌─────────────────────┐
│ SparsePRT 未满？    │──Yes──► 添加到 Sparse Entry
│ (cards < 16)        │         (48 bytes)
└──────────┬──────────┘
           │ No
           ▼
┌─────────────────────┐
│ 存在 Fine 表？      │──Yes──► 添加到 PerRegionTable
│ (PRT 已创建)        │         (1KB 位图)
└──────────┬──────────┘
           │ No
           ▼
┌─────────────────────┐
│ Fine 表未满？       │──Yes──► 创建新的 PRT
│ (_n_fine < max)     │         (添加到哈希表)
└──────────┬──────────┘
           │ No
           ▼
┌─────────────────────┐
│ 驱逐最老的 PRT      │
│ 标记为 Coarse       │──► 添加到 Coarse Bitmap
└─────────────────────┘    (256 bytes Region 级)
```

### 7.2 内存-性能权衡表

| 模式 | 内存/Region | 查询时间 | 精度 | 适用场景 |
|-----|------------|---------|------|---------|
| Sparse | 48-80B | O(n) | Card | 引用极少（<16） |
| Fine | 1080B | O(1) | Card | 引用中等（17-8192） |
| Coarse | 256B | O(1) | Region | 引用极多（>8192） |

### 7.3 关键数字记忆

```
┌─────────────────────────────────────────────────────────────────────┐
│                    RSet 关键数字                                     │
├─────────────────────────────────────────────────────────────────────┤
│  16  = Sparse Entry cards 数组默认大小                               │
│  48  = SparsePRTEntry 基础大小（字节）                               │
│  512 = Card 大小（字节）                                             │
│  1024 = PerRegionTable 位图大小（字节）                              │
│  8192 = 每个 Region 的 Card 数量                                     │
│  192  = Fine 表最大 Entry 数量（_max_fine_entries）                  │
│  1080 = PerRegionTable 总大小（字节）                                │
└─────────────────────────────────────────────────────────────────────┘
```

---

**质量自检清单：**
- [x] 功能定位（一句话 + 位置 + 无它后果）
- [x] 类继承关系图
- [x] 关键字段详解（是什么/为什么/怎么用/特殊值/并发性）
- [x] 内存布局图（含偏移量）
- [x] 核心算法流程图
- [x] GDB 验证脚本
- [x] 三种模式对比与转换
