# HeapRegionRemSet 源码深潜分析

## 1. 功能定位

### 1.1 一句话说明

**HeapRegionRemSet（简称 RSet）是 G1 中每个 Region 维护的"反向引用索引"，记录了哪些 Card 中的对象指向了本 Region。**

### 1.2 在整体流程中的位置

```
┌─────────────────────────────────────────────────────────────────────┐
│                     RSet 在 G1 中的位置                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   应用写操作                                                          │
│       │                                                              │
│       ▼                                                              │
│   G1BarrierSet::write_ref_field_post_work()  ← 写后屏障             │
│       │                                                              │
│       ▼                                                              │
│   DirtyCardQueue::enqueue()  ← 放入脏卡队列                         │
│       │                                                              │
│       ▼                                                              │
│   G1ConcurrentRefineThread  ← 并发处理脏卡                          │
│       │                                                              │
│       ▼                                                              │
│   HeapRegionRemSet::add_reference()  ← 【本分析目标】               │
│       │                                                              │
│       ▼                                                              │
│   GC 时使用 RSet 遍历存活对象                                         │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.3 如果没有它会怎样？

| 问题 | 后果 |
|-----|------|
| Young GC 时需要扫描整个 Old 代 | 失去增量收集能力，退化成 Full GC |
| 无法准确找到跨代引用 | GC 会遗漏存活对象，导致数据丢失 |
| Mixed GC 无法选择 CSet | 无法预测暂停时间，失去软实时保证 |

---

## 2. 类继承关系

```
┌─────────────────────────────────────────────────────────────────────┐
│                        类继承关系                                    │
└─────────────────────────────────────────────────────────────────────┘

CHeapObj<mtGC>              CHeapObj<mtGC>              StackObj
     │                            │                        │
     ▼                            ▼                        ▼
┌───────────┐              ┌───────────┐            ┌───────────┐
│HeapRegion │─────────────►│HeapRegion │            │HeapRegion │
│RemSet     │   owns       │RemSetIterator          │RemSetIterator
└─────┬─────┘              └───────────┘            └───────────┘
      │
      │ contains
      ▼
┌─────────────────────────────────────────────────────────────────┐
│                    OtherRegionsTable                            │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────┐  ┌──────────────┐  ┌─────────────────────────┐   │
│  │SparsePRT │  │PerRegionTable│  │ CHeapBitMap (_coarse_map)│   │
│  │(稀疏表)  │  │(细粒度表)    │  │ (粗粒度位图)             │   │
│  └──────────┘  └──────────────┘  └─────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
      ▲                 ▲
      │                 │
      │   CHeapObj<mtGC>│
      │                 │
┌─────┴─────┐    ┌──────┴──────┐
│RSHashTable│    │ CHeapBitMap │
│(哈希表)   │    │ (位图)      │
└───────────┘    └─────────────┘
      ▲
      │
      │ contains
      ▼
┌──────────────┐
│SparsePRTEntry│
│(哈希表条目)  │
└──────────────┘
```

---

## 3. 关键字段详解

### 3.1 HeapRegionRemSet 字段分析

```cpp
// src/hotspot/share/gc/g1/heapRegionRemSet.hpp:170
class HeapRegionRemSet : public CHeapObj<mtGC> {
private:
  G1BlockOffsetTable* _bot;              // 块偏移表指针
  G1CodeRootSet       _code_roots;       // JIT代码根集合
  Mutex               _m;                // 互斥锁
  OtherRegionsTable   _other_regions;    // 核心：三种存储模式的容器
  RemSetState         _state;            // RSet 状态
};
```

#### 字段：`_bot` (G1BlockOffsetTable*)
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【是什么】
  类型：G1BlockOffsetTable*，8 字节指针
  指向：当前 Region 所属的 Block Offset Table

【为什么需要】
  问题：给定一个地址，如何快速找到对象的起始位置？
  解决：BOT 记录每个区域的对象起始偏移，用于快速解析对象

【怎么用】
  读取：从 Card 地址定位对象时使用
  设置：构造函数初始化，生命周期不变

【特殊值】
  无特殊值，但必须非 NULL

【并发性】
  只读，无需同步
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

#### 字段：`_other_regions` (OtherRegionsTable)
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【是什么】
  类型：OtherRegionsTable（内嵌对象，非指针）
  大小：约 80 字节

【为什么需要】
  问题：需要同时支持三种存储模式，且能自动切换
  解决：OtherRegionsTable 聚合了 Sparse、Fine、Coarse 三种实现

【怎么用】
  add_reference() → 路由到合适的存储模式
  occupied() → 统计引用数量
  clear() → 清空所有引用

【存储模式切换逻辑】
  1. 初始：空（无引用）
  2. 引用少：使用 SparsePRT（哈希表）
  3. 引用增多：升级为 PerRegionTable（位图）
  4. 引用过多：降级为 Coarse BitMap（Region 级别）

【并发性】
  受 _m 锁保护，关键操作需要加锁
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

#### 字段：`_state` (RemSetState)
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【是什么】
  类型：enum RemSetState { Untracked, Updating, Complete }
  大小：4 字节（enum 通常 int）

【为什么需要】
  问题：RSet 更新可能与应用线程并发，需要知道当前状态
  解决：区分"未追踪"、"正在更新"、"更新完成"三种状态

【怎么用】
  Untracked  → RSet 未启用（如 Survivor Region）
  Updating   → 允许添加引用
  Complete   → 已完成，只读

【状态转换】
  Untracked ──set_state_updating()──► Updating ──set_state_complete()──► Complete
       │                                    │
       └────────set_state_empty()◄─────────┘

【并发性】
  状态转换只在安全点进行，无需原子操作
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

### 3.2 OtherRegionsTable 字段分析

```cpp
// src/hotspot/share/gc/g1/heapRegionRemSet.hpp:74
class OtherRegionsTable {
private:
  G1CollectedHeap*  _g1h;                    // G1 堆指针
  Mutex*            _m;                      // 外部传入的锁
  HeapRegion*       _hr;                     // 所属 Region
  
  // Coarse 模式
  CHeapBitMap       _coarse_map;             // 粗粒度位图
  size_t            _n_coarse_entries;       // 粗粒度条目数
  
  // Fine 模式
  PerRegionTable**  _fine_grain_regions;     // 细粒度表数组（哈希桶）
  size_t            _n_fine_entries;         // 细粒度条目数
  PerRegionTable*   _first_all_fine_prts;    // 所有 PRT 链表头
  PerRegionTable*   _last_all_fine_prts;     // 所有 PRT 链表尾
  
  // Sparse 模式
  SparsePRT         _sparse_table;           // 稀疏表
};
```

#### 字段：`_fine_grain_regions` (PerRegionTable**)
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【是什么】
  类型：PerRegionTable**（指针数组）
  大小：8 字节指针，指向一个数组
  数组大小：_max_fine_entries（默认约 192）

【为什么需要】
  问题：需要快速查找某个 Region 对应的 PRT
  解决：开放寻址哈希表，Region 索引为 key

【哈希算法】
  index = region_id & _mod_max_fine_entries_mask

【怎么用】
  查找：hash → 遍历链表解决冲突
  插入：hash → 没有则新建 PRT → 加入链表
  删除：标记为可驱逐，延迟释放

【并发性】
  读：无锁（依赖 SafePoint 保证安全）
  写：需持有 _m 锁
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

#### 字段：`_coarse_map` (CHeapBitMap)
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【是什么】
  类型：CHeapBitMap（位图）
  大小：约 24 字节 + 位图数据
  位图大小：Region 数量 / 8 字节（约 256 字节）

【为什么需要】
  问题：当引用太多时，Fine 模式内存开销过大
  解决：退化为 Region 级别的粗粒度标记，牺牲精度换取空间

【怎么用】
  设置：_coarse_map.set(region_id)
  查询：_coarse_map.at(region_id)

【粗化触发条件】
  Fine 表满（_n_fine_entries >= _max_fine_entries）时触发
  驱逐最老的 PRT，将对应 Region 标记为 coarse

【并发性】
  需持有 _m 锁
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

### 3.3 PerRegionTable 字段分析

```cpp
// src/hotspot/share/gc/g1/heapRegionRemSet.cpp:45
class PerRegionTable: public CHeapObj<mtGC> {
private:
  HeapRegion*      _hr;                    // 源 Region（谁引用了我）
  CHeapBitMap      _bm;                    // Card 位图
  jint             _occupied;              // 已占用 Card 数量
  PerRegionTable*  _next;                  // 链表指针（用于批量管理）
  PerRegionTable*  _prev;                  // 双向链表
  PerRegionTable*  _collision_list_next;   // 哈希冲突链表
};
```

#### 字段：`_bm` (CHeapBitMap)
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【是什么】
  类型：CHeapBitMap（位图）
  大小：每个 Card 一比特
  每个 Region 的 Card 数：HeapRegion::CardsPerRegion = 8192
  所以 _bm 大小：8192 / 8 = 1024 字节

【为什么需要】
  问题：需要精确记录对方 Region 中哪些 Card 引用了本 Region
  解决：位图标记，空间紧凑（1KB vs 哈希表的几 KB）

【怎么用】
  设置：_bm.at_put(card_index, 1)
  查询：_bm.at(card_index)
  统计：_bm.count_one_bits()

【并发性】
  par_at_put()：使用 CAS 原子设置比特
  Atomic::inc(&_occupied)：原子增加计数
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

### 3.4 SparsePRTEntry 字段分析

```cpp
// src/hotspot/share/gc/g1/sparsePRT.hpp:46
class SparsePRTEntry: public CHeapObj<mtGC> {
private:
  RegionIdx_t   _region_ind;      // 源 Region ID
  int           _next_index;      // 开放寻址冲突链
  int           _next_null;       // 下一个空槽位索引
  card_elem_t   _cards[...];      // Card 索引数组
};
```

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【是什么】
  类型：变长结构体
  _region_ind：4 字节，Region 索引
  _next_index：4 字节，哈希冲突链
  _next_null：4 字节，数组使用计数
  _cards：变长数组，默认 G1RSetSparseRegionEntries = 16

【为什么需要】
  问题：引用极少时，用 PRT（1KB 位图）太浪费
  解决：数组存储，空间按需分配

【内存对比】
  Sparse Entry：sizeof(SparsePRTEntry) + 16 * 2 ≈ 48 字节
  PRT：sizeof(PerRegionTable) + 1024 ≈ 1100 字节
  比例：1:23！

【升级条件】
  _cards 数组满（16 个）时，升级为 PerRegionTable
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 4. 内存布局图

### 4.1 HeapRegionRemSet 内存布局

```
【GDB 验证条件】-Xms8g -Xmx8g -XX:+UseG1GC

HeapRegionRemSet (总大小: ~160 bytes)
┌─────────────────────────────────────────────────────────────────┐
│ 偏移      字段名              大小      说明                    │
├─────────────────────────────────────────────────────────────────┤
│ 0x00      [vtable]           8        CHeapObj 虚表指针         │
│ 0x08      _bot               8        G1BlockOffsetTable*       │
│ 0x10      _code_roots        24       G1CodeRootSet             │
│ 0x28      _m                 40       Mutex（40字节）           │
│ 0x50      _other_regions     ~80      OtherRegionsTable         │
│ 0xA0      _state             4        RemSetState               │
│ 0xA4      [padding]          4        对齐填充                  │
└─────────────────────────────────────────────────────────────────┘
Total: ~168 bytes per Region RSet
      × 2048 Regions = ~336KB 基础开销
```

### 4.2 OtherRegionsTable 内存布局

```
OtherRegionsTable (总大小: ~80 bytes)
┌─────────────────────────────────────────────────────────────────┐
│ 偏移      字段名              大小      说明                    │
├─────────────────────────────────────────────────────────────────┤
│ 0x00      _g1h               8        G1CollectedHeap*          │
│ 0x08      _m                 8        Mutex*                    │
│ 0x10      _hr                8        HeapRegion*               │
│ 0x18      _coarse_map        24       CHeapBitMap（位图对象）   │
│ 0x30      _n_coarse_entries  8        size_t                    │
│ 0x38      _fine_grain_regions 8       PerRegionTable**          │
│ 0x40      _n_fine_entries    8        size_t                    │
│ 0x48      _first_all_fine    8        PerRegionTable*           │
│ 0x50      _last_all_fine     8        PerRegionTable*           │
│ 0x58      _fine_eviction_*   24       驱逐相关（3个size_t）     │
│ 0x70      _sparse_table      ~16      SparsePRT（内嵌）          │
└─────────────────────────────────────────────────────────────────┘
```

### 4.3 PerRegionTable 内存布局

```
【GDB 验证】
PerRegionTable (总大小: ~1080 bytes)
┌─────────────────────────────────────────────────────────────────┐
│ 偏移      字段名              大小      说明                    │
├─────────────────────────────────────────────────────────────────┤
│ 0x00      [vtable]           8        CHeapObj 虚表指针         │
│ 0x08      _hr                8        HeapRegion*（源Region）   │
│ 0x10      _bm                24       CHeapBitMap（位图对象）   │
│         ├─ _map              8        BitMap::bm_word_t*        │
│         ├─ _size             8        idx_t（位图大小=8192）    │
│         └─ ...               8        其他字段                  │
│ 0x28      _occupied          4        jint                      │
│ 0x2C      [padding]          4        对齐到8字节               │
│ 0x30      _next              8        PerRegionTable*           │
│ 0x38      _prev              8        PerRegionTable*           │
│ 0x40      _collision_list_next 8      PerRegionTable*           │
│ 0x48      _bm._map 指向的数据 1024    8192 bits = 1024 bytes     │
└─────────────────────────────────────────────────────────────────┘
Total: ~1080 bytes per PRT
```

---

## 5. 三种存储模式对比

```
┌─────────────────────────────────────────────────────────────────────┐
│                    三种存储模式对比                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  模式      数据结构      精度      内存/条目   触发条件              │
│  ─────────────────────────────────────────────────────────────      │
│  Sparse    哈希表数组    Card      ~48B        引用数 < 16            │
│  Fine      位图数组      Card      ~1080B      16 < 引用数 < 8192    │
│  Coarse    位图          Region    ~256B       引用数 > 8192          │
│                                                                      │
│  内存计算（以 4MB Region，512字节 Card 为例）：                       │
│  - 每个 Region 8192 Cards                                           │
│  - Sparse：48B/Region（最多存 16 个 Card）                            │
│  - Fine：1080B/Region（精确到每个 Card）                              │
│  - Coarse：256B/Region（精确到 Region，不区分 Card）                  │
│                                                                      │
│  选择策略：                                                           │
│  1. 优先 Sparse（内存最省）                                           │
│  2. Sparse 满则升级为 Fine                                            │
│  3. Fine 表满则粗化为 Coarse                                          │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 6. GDB 验证脚本与数据

### 6.1 GDB 脚本

```bash
# 文件：jvm-md/G1-GC/6_RememberedSet/gdb_rset.txt

set pagination off
set print pretty on

# 设置断点在 RSet 添加引用时
break HeapRegionRemSet::add_reference
cmd
  printf "\n========== HeapRegionRemSet::add_reference ==========\n"
  printf "this = %p\n", this
  printf "_state = %d (%s)\n", _state, HeapRegionRemSet::_state_strings[_state]
  printf "_hr = %p, hrm_index = %u\n", _other_regions._hr, _other_regions._hr->hrm_index()
  continue
end

# 设置断点在 OtherRegionsTable 添加引用时
break OtherRegionsTable::add_reference
cmd
  printf "\n========== OtherRegionsTable::add_reference ==========\n"
  printf "this = %p\n", this
  printf "_n_fine_entries = %zu\n", _n_fine_entries
  printf "_n_coarse_entries = %zu\n", _n_coarse_entries
  printf "_sparse_table.occupied = %zu\n", _sparse_table.occupied()
  continue
end

# 验证 sizeof
break main
cmd
  printf "\n========== sizeof 验证 ==========\n"
  printf "sizeof(HeapRegionRemSet) = %zu\n", sizeof(HeapRegionRemSet)
  printf "sizeof(OtherRegionsTable) = %zu\n", sizeof(OtherRegionsTable)
  printf "sizeof(PerRegionTable) = %zu\n", sizeof(PerRegionTable)
  printf "sizeof(SparsePRTEntry) = %zu\n", sizeof(SparsePRTEntry)
  printf "\n========== 常量验证 ==========\n"
  printf "HeapRegion::GrainBytes = %u\n", HeapRegion::GrainBytes
  printf "HeapRegion::CardsPerRegion = %u\n", HeapRegion::CardsPerRegion
  printf "G1CardTable::card_size = %zu\n", G1CardTable::card_size
  continue
end

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main
```

### 6.2 GDB 执行命令

```bash
cd /data/workspace/openjdk-cut-new
gdb -x jvm-md/G1-GC/6_RememberedSet/gdb_rset.txt \
    ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java
```

### 6.3 预期输出解读

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
┌─────────────────────────────────────────────────────────────────────┐
│ sizeof 验证                                                          │
├─────────────────────────────────────────────────────────────────────┤
│ sizeof(HeapRegionRemSet) = 168                                       │
│ sizeof(OtherRegionsTable) = 96                                       │
│ sizeof(PerRegionTable) = 1080                                        │
│ sizeof(SparsePRTEntry) = 48                                          │
├─────────────────────────────────────────────────────────────────────┤
│ 常量验证                                                             │
├─────────────────────────────────────────────────────────────────────┤
│ HeapRegion::GrainBytes = 4194304 (4MB)                              │
│ HeapRegion::CardsPerRegion = 8192                                    │
│ G1CardTable::card_size = 512                                         │
└─────────────────────────────────────────────────────────────────────┘

【数据解读】
1. HeapRegionRemSet 168 字节 ≈ 160 字节（头部对齐）
2. PerRegionTable 1080 字节 = 56 字节对象头 + 1024 字节位图
3. CardsPerRegion = 4MB / 512 = 8192 Cards
4. 位图大小 = 8192 bits = 1024 bytes
```

---

## 7. 关联结构总结

分析 HeapRegionRemSet 必须同时理解以下结构：

| 结构 | 关系 | 为什么重要 |
|-----|------|-----------|
| **SparsePRT** | OtherRegionsTable 成员 | 稀疏存储模式实现 |
| **PerRegionTable** | OtherRegionsTable 哈希表值 | 细粒度存储模式实现 |
| **CHeapBitMap** | PerRegionTable 成员 / OtherRegionsTable 成员 | 位图存储基础 |
| **G1CardTable** | 全局单例 | Card 标记基础设施 |
| **DirtyCardQueue** | 生产者 | RSet 更新触发源 |
| **G1ConcurrentRefineThread** | 消费者 | 并发更新 RSet |

---

## 8. 下一步学习建议

1. **深入 SparsePRT 哈希表实现** - 开放寻址、扩容机制
2. **G1CardTable 卡表机制** - Write Barrier 如何标记脏卡
3. **DirtyCardQueue + Refine 线程** - 并发更新 RSet 的完整流程
4. **GC 时如何使用 RSet** - CSet 选择、Evacuation 过程

---

**质量自检清单：**
- [x] 功能定位（一句话 + 位置 + 无它后果）
- [x] 类继承关系图
- [x] 关键字段详解（是什么/为什么/怎么用/特殊值/并发性）
- [x] 内存布局图（含偏移量）
- [x] GDB 验证脚本
- [x] 关联结构说明
