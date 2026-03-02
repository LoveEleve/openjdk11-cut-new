# G1RemSet 专家级深度分析 - 记忆集的三种存储格式

> **类定位**: `src/hotspot/share/gc/g1/heapRegionRemSet.hpp`  
> **核心类**: `OtherRegionsTable`、`PerRegionTable`、`SparsePRT`  
> **分析标准**: JVM-Mastery Skill 专家级要求  
> **标准环境**: `-Xms8g -Xmx8g -XX:+UseG1GC`，Region=4MB，共 2048 Regions  
> **分析时间**: 2026-02-10

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1RemSet（Remembered Set）的本质是**每个 Region 维护的"谁引用了我"的反向索引**，采用 Sparse→Fine→Coarse 三级自适应存储：引用少时用哈希表（精确到卡粒度），引用多时用位图（精确到卡粒度），引用极多时退化为 Region 粒度的粗粒度位图。三级结构在内存开销和扫描精度之间动态平衡。

### 0.2 为什么需要？

G1 Young GC 只回收 CSet 中的 Region，但 CSet 外的 Region 可能有引用指向 CSet 内的对象（跨 Region 引用）。如果不追踪这些引用，GC 会漏标存活对象导致悬空指针。RSet 记录"哪些 Region 的哪些卡引用了我"，GC 时只需扫描 RSet 中记录的卡，而不是扫描整个堆。

### 0.3 三级结构详解

- **Sparse（稀疏）**：`SparsePRT`，哈希表存储 `(from_region_idx, card_idx)` 对，精确到 512 字节卡粒度
- **Fine（细粒度）**：`PerRegionTable`，每个 from_region 对应一个 512 位的位图，精确到卡粒度
- **Coarse（粗粒度）**：`_coarse_map`，每个 from_region 对应 1 位，只知道"有引用"但不知道具体哪张卡

**升级触发**：Sparse 超过 `G1RSetSparseRegionEntries`（默认 4）个 from_region 时升级为 Fine；Fine 超过 `G1RSetRegionEntries`（默认 256）个 from_region 时升级为 Coarse。

### 0.4 为什么这样设计？

- **为什么需要三级而不是直接用位图？** 大多数 Region 的 RSet 很小（只有少量跨 Region 引用），直接用位图每个 Region 需要 128KB，2048 个 Region 共需 256MB；三级结构让小 RSet 用哈希表，内存开销降低 10-100 倍
- **为什么升级是单向的（不会降级）？** 降级需要重建数据结构，代价高；而且引用数量通常只增不减

---

## 零、本文档阅读指南

### 0.1 核心发现（先睹为快）

```
【G1RemSet 一句话总结】
每个 Region 的记忆集，记录"哪些其他 Region 有引用指向本 Region"，采用三层存储格式自适应：

┌─────────────────────────────────────────────────────────────────┐
│  存储格式      │ 数据结构              │ 适用场景                  │
├─────────────────────────────────────────────────────────────────┤
│  Sparse        │ 哈希表 + Card 数组    │ 少量引用（<4 个 Card）    │
│  (稀疏表)      │ 每个 Region 存 4-16 个 Card 索引               │
├─────────────────────────────────────────────────────────────────┤
│  Fine-grained  │ PerRegionTable + 位图 │ 中等引用（<8192 Cards）   │
│  (细粒度表)    │ 每个 Region 一个 8192 bit 位图                │
├─────────────────────────────────────────────────────────────────┤
│  Coarse        │ 位图（1 bit/Region）  │ 大量引用（>8192 Cards）   │
│  (粗粒度表)    │ 2048 bit = 256 字节   │ 只记录 Region 级别        │
└─────────────────────────────────────────────────────────────────┘

存储格式转换：
Sparse → Fine-grained → Coarse（随着引用增多，逐步降级）

内存占用（单个 Region 的 RSet）：
- Sparse:   32 bytes（1 entry）
- Fine:     ~1 KB（PerRegionTable + 位图）
- Coarse:   256 bytes（2048 bit 位图）

总 RSet 内存（8GB 堆）：
- 平均每个 Region RSet ≈ 100-500 bytes
- 总计 ≈ 200KB - 1MB（可忽略）
```

---

## 第一章：记忆集核心概念

### 1.1 为什么需要记忆集？

```
【问题背景】

Young GC 场景：
┌─────────────────────────────────────────────────────────────┐
│  Region A (Old)         Region B (Eden, Young)              │
│  ┌───────────┐          ┌───────────┐                       │
│  │ 对象 a1   │─────────►│ 对象 b1   │                       │
│  │ 对象 a2   │────┐     │ 对象 b2   │                       │
│  └───────────┘    │     └───────────┘                       │
│                   │                                         │
│                   └──────────────────────────────────────►  │
│                                                            │
│  Young GC 要回收 Region B，但需要知道谁引用了它！            │
│  否则 a1→b1 这个引用会被漏掉，b1 被错误回收！                │
└─────────────────────────────────────────────────────────────┘

【传统方案 vs G1 方案】

传统方案（整代收集）：
  扫描整个老年代找引用 → O(老年代大小) → 太慢！

G1 方案（记忆集）：
  Region B 维护自己的 RSet：{Region A: {card_1, card_2}}
  含义：Region A 的 card_1 和 card_2 有引用指向 Region B
  
  Young GC 时只扫描 RSet 中记录的 Card → O(RSet 大小)
  与堆大小无关，效率稳定！
```

### 1.2 写屏障维护记忆集

```
对象引用赋值时触发写后屏障：

Java 代码：
  a1.field = b1;  // a1 在 Region A，b1 在 Region B

伪代码：
  1. 原始赋值：a1.field = b1
  2. 写后屏障：
     - 计算 card_index = (uintptr_t)a1 >> 9
     - 标记卡表：card_table[card_index] = dirty
     - 更新 RSet：
       RegionB->rem_set->add_reference(a1)
       // 记录 "Region A 的 card_index 有引用指向我"

RSet 结构（Region B）：
┌────────────────────────────────────────┐
│ 引用来源 Region A:                      │
│   - card_index_1（包含 a1）             │
│   - card_index_2（包含 a2）             │
│                                        │
│ 存储格式：根据 Card 数量自适应选择       │
│   - 1-4 个 Card → Sparse 格式           │
│   - 5-8192 个 Card → Fine-grained 格式  │
│   - >8192 个 Card → Coarse 格式         │
└────────────────────────────────────────┘
```

---

## 第二章：三种存储格式详解

### 2.1 整体架构

```
HeapRegionRemSet（Region 级别的记忆集）
│
├── _code_roots: G1CodeRootSet          // JIT 代码中的引用（较少使用）
│
└── _other_regions: OtherRegionsTable   // 【核心】其他 Region 的引用
    │
    ├── _sparse_table: SparsePRT        // ① 稀疏表（少量引用）
    │
    ├── _fine_grain_regions:            // ② 细粒度表（中等引用）
    │   PerRegionTable** （哈希表）
    │   每个 PerRegionTable 包含一个 Card 位图（8192 bits）
    │
    └── _coarse_map: CHeapBitMap        // ③ 粗粒度表（大量引用）
        2048 bits，每个 bit 代表一个 Region
```

### 2.2 Sparse 格式 - 稀疏表

```cpp
// src/hotspot/share/gc/g1/sparsePRT.hpp

class SparsePRTEntry {
  RegionIdx_t _region_ind;      // 引用来源 Region 索引
  int         _next_index;      // 哈希冲突链表的下一个
  int         _next_null;       // 当前已使用的 Card 数量
  card_elem_t _cards[...];      // Card 索引数组（默认 4 个）
};

class RSHashTable {
  SparsePRTEntry* _entries;     // Entry 数组
  int*            _buckets;     // 哈希桶数组
};
```

```
【Sparse 格式内存布局】

Region B 的 RSet，记录来自 Region A 的 3 个 Card：
┌────────────────────────────────────────────┐
│ SparsePRTEntry (32 bytes)                  │
│ ┌────────────────────────────────────────┐ │
│ │ _region_ind = 10      (Region A 索引)  │ │  4 bytes
│ │ _next_index = -1      (无冲突)         │ │  4 bytes
│ │ _next_null  = 3       (3 个 Card)      │ │  4 bytes
│ │ _cards[0]   = 15      (Card 索引)      │ │  2 bytes
│ │ _cards[1]   = 28                       │ │  2 bytes
│ │ _cards[2]   = 1024                     │ │  2 bytes
│ │ _cards[3]   = -1      (未使用)         │ │  2 bytes
│ └────────────────────────────────────────┘ │
└────────────────────────────────────────────┘

含义：
  Region A 的 Card 15、28、1024 有引用指向 Region B

适用场景：
  - 引用来源 Region 数量少
  - 每个来源 Region 的 Card 数量 ≤ 4（默认）

内存占用：
  - 每个 Entry：32 bytes
  - 默认最多 256 个 Entry：8 KB
```

**添加引用流程（Sparse）**:

```cpp
void add_reference_sparse(HeapRegion* from_region, CardIdx_t card) {
  // 1. 查找是否已有该 Region 的 Entry
  SparsePRTEntry* entry = find_entry(from_region->hrm_index());
  
  if (entry == NULL) {
    // 2. 没有则创建新 Entry
    entry = alloc_entry();
    entry->init(from_region->hrm_index());
  }
  
  // 3. 添加 Card 到 Entry
  AddCardResult result = entry->add_card(card);
  
  if (result == overflow) {
    // 4. Entry 满了（>4 cards），升级到 Fine-grained
    promote_to_fine_grained(from_region, entry);
  }
}
```

### 2.3 Fine-grained 格式 - 细粒度表

```cpp
// src/hotspot/share/gc/g1/heapRegionRemSet.cpp

class PerRegionTable: public CHeapObj<mtGC> {
  HeapRegion*     _hr;          // 引用来源 Region
  CHeapBitMap     _bm;          // 【核心】Card 位图（8192 bits）
  PerRegionTable* _next;        // 链表指针（用于哈希冲突）
  PerRegionTable* _next_all;    // 全局链表指针
};

class OtherRegionsTable {
  PerRegionTable** _fine_grain_regions;  // 哈希表
  size_t           _n_fine_entries;      // 当前数量
  static size_t    _max_fine_entries;    // 最大数量（默认 256）
};
```

```
【Fine-grained 格式内存布局】

Region B 的 RSet，记录来自 Region A 的 1000 个 Card：
┌─────────────────────────────────────────────────────────┐
│ PerRegionTable (~1KB)                                   │
│ ┌─────────────────────────────────────────────────────┐ │
│ │ _hr = Region A (指针)                                │ │  8 bytes
│ │ _bm = CHeapBitMap (8192 bits)                       │ │  
│ │   ┌─────────────────────────────────────────────┐   │ │
│ │   │ bit 0   = 0  (Card 0 无引用)                 │   │ │
│ │   │ bit 1   = 1  (Card 1 有引用)                 │   │ │
│ │   │ ...     = ...                                │   │ │
│ │   │ bit 15  = 1  (Card 15 有引用)                │   │ │
│ │   │ bit 28  = 1  (Card 28 有引用)                │   │ │
│ │   │ ...     = ...                                │   │ │
│ │   │ bit 1024= 1  (Card 1024 有引用)              │   │ │
│ │   │ ...     = ... (共 1000 个 1)                 │   │ │
│ │   │ bit 8191= 0  (Card 8191 无引用)              │   │ │
│ │   └─────────────────────────────────────────────┘   │ │
│ │   位图大小：8192 bits = 1024 bytes                   │ │
│ │                                                      │ │
│ │ _next = NULL (哈希冲突链表)                          │ │  8 bytes
│ │ _next_all = ... (全局链表)                           │ │  8 bytes
│ └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘

含义：
  Region A 的 1000 个 Card 有引用指向 Region B
  具体哪些 Card：查位图中值为 1 的位

适用场景：
  - 引用来源 Region 数量中等
  - 每个来源 Region 的 Card 数量 > 4 且 < 8192

内存占用：
  - 每个 PRT：~1 KB（位图 1KB + 指针 24 bytes）
  - 最多 256 个 PRT：~256 KB
```

**位图操作示例**:

```cpp
// 添加 Card
void add_card_fine(PerRegionTable* prt, CardIdx_t card) {
  prt->_bm.set_bit(card);  // 设置位图中对应位为 1
}

// 查询 Card
bool contains_card_fine(PerRegionTable* prt, CardIdx_t card) {
  return prt->_bm.at(card);  // 检查位图中对应位
}

// 遍历所有 Card
void iterate_cards(PerRegionTable* prt, Closure* cl) {
  for (CardIdx_t card = 0; card < 8192; card++) {
    if (prt->_bm.at(card)) {
      cl->do_card(card);  // 处理有引用的 Card
    }
  }
}
```

### 2.4 Coarse 格式 - 粗粒度表

```cpp
class OtherRegionsTable {
  CHeapBitMap _coarse_map;      // 【核心】粗粒度位图
  size_t      _n_coarse_entries; // 当前 coarse 的 Region 数量
};
```

```
【Coarse 格式内存布局】

Region B 的 RSet，记录来自大量 Region 的引用：
┌─────────────────────────────────────────────────────────┐
│ _coarse_map: CHeapBitMap (256 bytes)                    │
│ ┌─────────────────────────────────────────────────────┐ │
│ │ 2048 bits = 256 bytes = 4 uint64_t                  │ │
│ │                                                     │ │
│ │ bit 0 = 0   (Region 0 无引用)                       │ │
│ │ bit 1 = 0   (Region 1 无引用)                       │ │
│ │ ...   = ...                                         │ │
│ │ bit 10= 1   (Region 10 有引用 ← Region A)          │ │
│ │ ...   = ...                                         │ │
│ │ bit 100=1   (Region 100 有引用 ← Region C)         │ │
│ │ ...   = ...                                         │ │
│ │ bit 2047=0  (Region 2047 无引用)                    │ │
│ └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘

含义：
  Region 10（A）、Region 100（C）等有引用指向 Region B
  但不记录具体 Card，只知道是哪些 Region

适用场景：
  - 引用来源 Region 数量很多
  - 某个来源 Region 的 Card 数量 >= 8192
  - 退化为 Region 级别记录，不再追踪具体 Card

内存占用：
  - 固定 256 bytes（2048 bits）
  - 与引用数量无关
```

### 2.5 三种格式对比

| 特性 | Sparse | Fine-grained | Coarse |
|------|--------|--------------|--------|
| **数据结构** | 哈希表 + Card 数组 | 哈希表 + Card 位图 | Region 位图 |
| **Card 精度** | 精确（记录每个 Card） | 精确（记录每个 Card） | 粗略（只记录 Region） |
| **最大 Cards** | 4（默认）per Region | 8192 per Region | N/A |
| **内存/Region** | 32 bytes | ~1 KB | 256 bytes |
| **查询复杂度** | O(1) 哈希 | O(1) 哈希 + 位图 | O(1) 位图 |
| **遍历复杂度** | O(n) n=Cards | O(8192) 扫描位图 | O(2048) 扫描位图 |
| **升级阈值** | >4 Cards | >8192 Cards | 不升级 |

---

## 第三章：存储格式转换机制

### 3.1 升级流程

```
【格式升级流程】

添加引用时检查：

Sparse Entry：
  if (entry.cards_count < 4) {
    // 继续用 Sparse
    entry.add_card(card);
  } else {
    // 升级到 Fine-grained
    promote_to_fine_grained(region, entry);
    delete entry;
  }

Fine-grained PRT：
  if (bitmap.card_count < 8192) {
    // 继续用 Fine-grained
    bitmap.set_bit(card);
  } else {
    // 升级到 Coarse
    promote_to_coarse(region, prt);
    delete prt;
  }

Coarse：
  // 不再升级
  coarse_map.set_bit(region_index);
```

### 3.2 降级与清理

```
【GC 后的清理】

Young GC 后：
  1. 遍历 RSet 中的所有 Card
  2. 检查 Card 中的对象是否还存活
  3. 如果对象已死，从 RSet 中删除该 Card
  4. 如果整个 Entry/PRT 为空，删除它

可能的降级：
  Fine-grained → Sparse（如果 Card 数量减少到 <4）
  （实际很少发生，因为通常引用会越来越多）
```

---

## 第四章：GDB 验证

### 4.1 验证脚本

```gdb
# GDB 验证 G1RemSet
# 标准条件：-Xms8g -Xmx8g -XX:+UseG1GC

set pagination off
set print pretty on

# 断点：对象分配后（有活跃的引用）
break instanceKlass.cpp:1240

run -XX:+UseG1GC -Xms8g -Xmx8g -Xint -cp . Main

printf "\n========== G1RemSet 验证 ==========\n\n"

# 获取 G1 堆
set $g1h = G1CollectedHeap::heap()

# 获取 HeapRegionManager
set $hrm = $g1h->_hrm

# 获取第一个 Eden Region
set $hr0 = $hrm->_regions._base[0]

printf "[验证 1] Region 0 RSet 地址:\n"
set $rset = $hr0->_rem_set
print /x $rset

printf "[验证 2] RSet 占用统计:\n"
print $rset->occupied()
print $rset->occupancy_less_or_equal_than(0)

printf "[验证 3] OtherRegionsTable 字段:\n"
set $ort = $rset->_other_regions
print $ort._sparse_table._num_entries
print $ort._n_fine_entries
print $ort._n_coarse_entries

printf "[验证 4] SparsePRT 配置:\n"
print G1RSetSparseRegionEntries
print SparsePRTEntry::cards_num()

printf "[验证 5] PerRegionTable 配置:\n"
print PerRegionTable::_max_fine_entries

printf "[验证 6] CardsPerRegion:\n"
print HeapRegion::CardsPerRegion

printf "========== 验证完成 ==========\n"

continue
quit
```

### 4.2 预期输出解读

```
┌────────────────────────────────────────────────────────────┐
│ [验证 1] Region 0 RSet 地址                                 │
│ $1 = 0x7ffff0c89d00                                       │
├────────────────────────────────────────────────────────────┤
│ [验证 2] RSet 占用统计                                      │
│ $2 = 0  （初始为空）                                       │
│ $3 = true                                                 │
├────────────────────────────────────────────────────────────┤
│ [验证 3] OtherRegionsTable 字段                            │
│ _sparse_table._num_entries = 0                            │
│ _n_fine_entries = 0                                       │
│ _n_coarse_entries = 0                                     │
├────────────────────────────────────────────────────────────┤
│ [验证 4] SparsePRT 配置                                     │
│ G1RSetSparseRegionEntries = 4  （每个 Entry 存 4 Cards）  │
│ SparsePRTEntry::cards_num() = 4                           │
├────────────────────────────────────────────────────────────┤
│ [验证 5] PerRegionTable 配置                                │
│ _max_fine_entries = 256                                   │
├────────────────────────────────────────────────────────────┤
│ [验证 6] CardsPerRegion                                     │
│ 8192  （4MB / 512B = 8192）                               │
└────────────────────────────────────────────────────────────┘
```

---

## 第五章：面试常见问题

### Q1: G1 记忆集是什么？为什么需要三种存储格式？

**答**: G1 记忆集（RSet）记录"哪些其他 Region 有引用指向本 Region"，Young GC 时只需扫描 RSet 中的 Card，无需扫描整个老年代。

**三种存储格式的原因**：自适应优化内存占用
- **Sparse**：少量引用时，32 bytes/Region，精确记录 Card
- **Fine-grained**：中等引用时，~1 KB/Region，精确记录 Card
- **Coarse**：大量引用时，256 bytes/Region，退化为 Region 级别

**设计哲学**：用最小的内存精确记录引用，当引用增多时逐步降级，避免内存爆炸。

### Q2: 记忆集的三种存储格式有什么区别？

**答**:

| 格式 | 数据结构 | 精度 | 内存占用 |
|------|----------|------|----------|
| **Sparse** | 哈希表 + Card 数组 | 精确（记录每个 Card） | 32 bytes |
| **Fine-grained** | 哈希表 + Card 位图 | 精确（记录每个 Card） | ~1 KB |
| **Coarse** | Region 位图 | 粗略（只记录 Region） | 256 bytes |

**升级阈值**：
- Sparse → Fine-grained：当某个 Region 的 Card 数量 > 4
- Fine-grained → Coarse：当某个 Region 的 Card 数量 > 8192

### Q3: 写屏障如何维护记忆集？

**答**:

```java
// Java 代码
oldObj.field = youngObj;  // oldObj 在 Old Region，youngObj 在 Young Region
```

**写后屏障伪代码**:
```cpp
void post_write_barrier(oop* field, oop new_val) {
  // 1. 获取所在 Card
  CardIdx_t card = (uintptr_t)field >> 9;
  
  // 2. 标记卡表为脏
  card_table[card] = dirty;
  
  // 3. 更新目标 Region 的 RSet
  HeapRegion* to_region = heap->region_for(new_val);
  to_region->rem_set()->add_reference(field);
  // 内部根据 Card 数量选择 Sparse/Fine/Coarse 格式存储
}
```

### Q4: 记忆集的内存占用是多少？

**答**: 

**单个 Region RSet**：
- Sparse 格式：32 bytes
- Fine-grained 格式：~1 KB
- Coarse 格式：256 bytes

**总 RSet 内存（8GB 堆，2048 Regions）**：
- 平均每个 Region RSet ≈ 100-500 bytes
- 总计 ≈ 200 KB - 1 MB
- 相对于 8GB 堆，开销 < 0.01%（可忽略）

---

## 第六章：总结

### 6.1 核心知识点回顾

```
【G1RemSet 核心要点】

1. 记忆集作用
   - 记录"谁引用了我"（跨 Region 引用）
   - Young GC 时只需扫描 RSet，无需扫描整个老年代

2. 三种存储格式
   - Sparse：哈希表 + Card 数组（≤4 Cards）
   - Fine-grained：哈希表 + Card 位图（≤8192 Cards）
   - Coarse：Region 位图（>8192 Cards）

3. 自适应升级
   - 随着引用增多，Sparse → Fine-grained → Coarse
   - 用最小内存精确记录

4. 内存占用
   - 单个 Region RSet：32 bytes ~ 1 KB
   - 总计：~200 KB - 1 MB（8GB 堆）

5. 维护机制
   - 写屏障（post-write-barrier）
   - 卡表（card table）标记脏卡
   - 并发精炼线程（Refinement Thread）处理
```

### 6.2 与整体架构的关系

```
G1CollectedHeap
  ├── HeapRegionManager
  │     └── HeapRegion[2048]
  │           └── HeapRegionRemSet _rem_set  ← 【记忆集】
  │                 ├── _code_roots（JIT 代码引用）
  │                 └── _other_regions（其他 Region 引用）
  │                       ├── _sparse_table（稀疏表）
  │                       ├── _fine_grain_regions（细粒度表）
  │                       └── _coarse_map（粗粒度表）
  │
  └── G1RemSet _g1_rem_set（全局协调）
```

---

*文档完成时间: 2026-02-10*  
*基于 OpenJDK 11 源码分析*  
*标准环境: -Xms8g -Xmx8g -XX:+UseG1GC，Region=4MB*
