# G1 RemSet 数据结构逐行深度源码分析

> **分析目标**: G1 RSet核心数据结构 - PerRegionTable、OtherRegionsTable、SparsePRT  
> **源码文件**: `src/hotspot/share/gc/g1/heapRegionRemSet.cpp/hpp`  
> **分析标准**: 逐行核心代码 + 面试问答 + GDB验证

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1 RSet 数据结构的本质是**三级自适应存储结构**：`SparsePRT`（哈希表，精确到卡粒度）→ `PerRegionTable`（位图，精确到卡粒度）→ `_coarse_map`（位图，精确到 Region 粒度）；引用少时用哈希表（内存小），引用多时用位图（查找快），引用极多时退化为粗粒度（内存最小）。

### 0.2 三级结构详解

| 级别 | 数据结构 | 粒度 | 内存开销 | 升级条件 |
|------|---------|------|---------|---------|
| Sparse | `SparsePRT`（哈希表） | 卡（512B） | 极小 | > 4 个 from_region |
| Fine | `PerRegionTable`（位图） | 卡（512B） | 中等 | > 256 个 from_region |
| Coarse | `_coarse_map`（位图） | Region（4MB） | 最小 | 已是最粗粒度 |

### 0.3 SparsePRT 结构

```cpp
struct SparsePRTEntry {
    RegionIdx_t _region_ind;  // from_region 索引
    CardIdx_t   _cards[4];    // 最多 4 张卡的索引
};
```

哈希表：`SparsePRTEntry[]`，用 `region_ind % table_size` 哈希；冲突时线性探测。

### 0.4 为什么这样设计？

- **为什么需要三级而不是直接用位图？** 大多数 Region 的 RSet 很小（只有少量跨 Region 引用），直接用位图每个 Region 需要 128KB；三级结构让小 RSet 用哈希表，内存开销降低 10-100 倍
- **为什么升级是单向的？** 降级需要重建数据结构，代价高；而且引用数量通常只增不减

---

---

## 第1章: PerRegionTable (PRT) - 细粒度表核心

### 1.1 PerRegionTable类定义

```cpp
45: class PerRegionTable: public CHeapObj<mtGC> {
46:   friend class OtherRegionsTable;
47:   friend class HeapRegionRemSetIterator;
48:
49:   HeapRegion*     _hr;              // 关联的Region
50:   CHeapBitMap     _bm;              // 卡位图：记录哪些卡有引用
51:   jint            _occupied;        // 已占用卡数
52:
53:   // next pointer for free/allocated 'all' list
54:   PerRegionTable* _next;            // 双向链表next
55:
56:   // prev pointer for the allocated 'all' list
57:   PerRegionTable* _prev;            // 双向链表prev
58:
59:   // next pointer in collision list
60:   PerRegionTable * _collision_list_next;  // 哈希冲突链表
61:
62:   // Global free list of PRTs
63:   static PerRegionTable* volatile _free_list;  // 全局空闲链表
```

**Line 45-63: PerRegionTable核心字段深度解析**

**设计要点：**
```
+------------------------------------------------------------------+
|                    PerRegionTable 数据结构                        |
+------------------------------------------------------------------+
|                                                                   |
|  _hr (HeapRegion*)                                                │
|  └─ 指向这个PRT记录的是哪个Region的引用                             │
|     例如：Region A的RSet中有个PRT，_hr指向Region B                  │
|           表示"Region B有引用指向Region A"                         │
|                                                                   |
|  _bm (CHeapBitMap)                                                │
|  └─ 位图，每一位对应一张卡（512字节）                               │
|     大小 = HeapRegion::CardsPerRegion = 4MB/512B = 8192位 = 1KB   │
|     bit[i]=1 表示第i张卡有引用指向当前Region                        │
|                                                                   |
|  _occupied (jint)                                                 │
|  └─ 统计已设置的卡数，用于快速判断是否为空                          │
|                                                                   |
|  链表指针：                                                        │
|  _next/_prev → 双向链表，用于"all"列表                             │
|  _collision_list_next → 哈希冲突链表                               │
+------------------------------------------------------------------+
```

**内存布局：**
```
PerRegionTable对象 (约1KB + 对象头)
┌────────────────────────────────────────────────────────┐
│ _hr (8 bytes)           → Region指针                   │
│ _bm (约1024 bytes)      → 卡位图 (8192 bits)           │
│ _occupied (4 bytes)     → 计数器                       │
│ _next (8 bytes)         → 下一个PRT                    │
│ _prev (8 bytes)         → 上一个PRT                    │
│ _collision_list_next (8 bytes) → 冲突链表              │
└────────────────────────────────────────────────────────┘
```

### 1.2 add_card_work - 添加卡核心实现

```cpp
76:   void add_card_work(CardIdx_t from_card, bool par) {
77:     if (!_bm.at(from_card)) {           // 检查卡是否已设置
78:       if (par) {                         // 并行模式
79:         if (_bm.par_at_put(from_card, 1)) {  // CAS设置
80:           Atomic::inc(&_occupied);       // 原子增加计数
81:         }
82:       } else {                           // 串行模式
83:         _bm.at_put(from_card, 1);        // 直接设置
84:         _occupied++;                     // 直接增加
85:       }
86:     }
87:   }
```

**Line 76-87: add_card_work逐行分析**

**并行vs串行模式：**
```
+------------------------------------------------------------------+
|                    并行 vs 串行添加                               |
+------------------------------------------------------------------+
|                                                                   |
|  串行模式 (par = false)：                                         │
|  ┌─────────────────────────────────────────────────────────┐     │
|  │  1. 检查 bit 是否为0                                     │     │
|  │  2. 设置 bit = 1                                         │     │
|  │  3. occupied++                                           │     │
|  │  → 简单直接，无竞争                                       │     │
|  └─────────────────────────────────────────────────────────┘     │
|                                                                   |
|  并行模式 (par = true)：                                          │
|  ┌─────────────────────────────────────────────────────────┐     │
|  │  1. 检查 bit 是否为0                                     │     │
|  │  2. CAS设置 bit = 1                                      │     │
|  │     ├─ CAS成功：执行 Atomic::inc(&_occupied)             │     │
|  │     └─ CAS失败：说明其他线程已设置，跳过                  │     │
|  │  → 安全处理多线程竞争                                     │     │
|  └─────────────────────────────────────────────────────────┘     │
|                                                                   |
|  为什么需要两种模式？                                              │
|  - 串行：GC暂停时，单线程操作，更快                                 │
|  - 并行：并发细化线程，多线程同时添加引用                           │
+------------------------------------------------------------------+
```

### 1.3 add_reference_work - 添加引用核心

```cpp
89:   void add_reference_work(OopOrNarrowOopStar from, bool par) {
90:     // Must make this robust in case "from" is not in "_hr", because of
91:     // concurrency.
92:
93:     HeapRegion* loc_hr = hr();
94:     // If the test below fails, then this table was reused concurrently
95:     // with this operation.  This is OK, since the old table was coarsened,
96:     // and adding a bit to the new table is never incorrect.
97:     if (loc_hr->is_in_reserved(from)) {
98:       CardIdx_t from_card = OtherRegionsTable::card_within_region(from, loc_hr);
99:       add_card_work(from_card, par);
100:    }
101:  }
```

**Line 89-101: add_reference_work逐行分析**

**关键点：并发重用问题**
```
+------------------------------------------------------------------+
|                    PRT并发重用问题                                 |
+------------------------------------------------------------------+
|                                                                   |
|  问题场景：                                                        │
|  1. PRT原来记录Region A的引用                                      │
|  2. 细粒度表满，PRT被降级重用                                       │
|  3. PRT现在记录Region B的引用                                      │
|  4. 但可能有线程还在用旧指针添加Region A的引用                       │
|                                                                   |
|  为什么OK？                                                        │
|  - 旧PRT已被降级到coarse_map                                       │
|  - coarse_map已经记录了Region A有引用                              │
|  - 新添加到PRT只是额外信息，不会丢失                                │
|                                                                   |
|  Line 97检查：                                                     │
|  if (loc_hr->is_in_reserved(from))                                │
|  - 验证from是否在PRT关联的Region内                                 │
|  - 如果不在，说明PRT已被重用，直接跳过                              │
+------------------------------------------------------------------+
```

### 1.4 PRT分配与释放

```cpp
179:   // Returns an initialized PerRegionTable instance.
180:   static PerRegionTable* alloc(HeapRegion* hr) {
181:     PerRegionTable* fl = _free_list;
182:     while (fl != NULL) {
183:       PerRegionTable* nxt = fl->next();
184:       PerRegionTable* res = Atomic::cmpxchg(nxt, &_free_list, fl);
185:       if (res == fl) {
186:         fl->init(hr, true);
187:         return fl;
188:       } else {
189:         fl = _free_list;              // CAS失败，重新读取
190:       }
191:     }
192:     assert(fl == NULL, "Loop condition.");
193:     return new PerRegionTable(hr);   // 空闲链表空，新建
194:   }
```

**Line 180-194: PRT无锁分配**

**无锁分配算法：**
```
+------------------------------------------------------------------+
|                    PRT无锁分配流程                                |
+------------------------------------------------------------------+
|                                                                   |
|  空闲链表结构：                                                    │
|  _free_list → PRT1 → PRT2 → PRT3 → NULL                          │
|                                                                   |
|  分配流程（无锁）：                                                │
|  ┌─────────────────────────────────────────────────────────┐     │
|  │  1. 读取 _free_list = fl                                 │     │
|  │  2. 如果 fl == NULL，新建PRT返回                          │     │
|  │  3. 读取 fl->next() = nxt                                │     │
|  │  4. CAS(_free_list, fl, nxt)                             │     │
|  │     ├─ 成功：初始化fl，返回                               │     │
|  │     └─ 失败：其他线程已修改，重试                          │     │
|  └─────────────────────────────────────────────────────────┘     │
|                                                                   |
|  优势：                                                            │
|  - 无锁，适合高并发                                                │
|  - 避免PRT频繁创建销毁                                             │
|  - 重用已分配内存                                                  │
+------------------------------------------------------------------+
```

---

## 第2章: OtherRegionsTable - 三层存储管理

### 2.1 OtherRegionsTable类结构

```cpp
74: class OtherRegionsTable {
77:   G1CollectedHeap* _g1h;
78:   Mutex*           _m;
79:   HeapRegion*      _hr;
80:
81:   // These are protected by "_m".
82:   CHeapBitMap _coarse_map;              // 粗粒度位图
83:   size_t      _n_coarse_entries;        // 粗粒度条目数
84:   static jint _n_coarsenings;           // 降级次数统计
85:
86:   PerRegionTable** _fine_grain_regions; // 细粒度哈希表
87:   size_t           _n_fine_entries;     // 细粒度条目数
88:
103:  SparsePRT   _sparse_table;            // 稀疏表
```

**Line 74-103: OtherRegionsTable核心字段**

**三层存储关系：**
```
+------------------------------------------------------------------+
|                    OtherRegionsTable 三层存储                      |
+------------------------------------------------------------------+
|                                                                   |
|  添加引用决策流程：                                                │
|  ┌─────────────────────────────────────────────────────────┐     │
|  │                                                          │     │
|  │  add_reference(from)                                     │     │
|  │       │                                                   │     │
|  │       ▼                                                   │     │
|  │  检查 FromCardCache (快速缓存)                            │     │
|  │       │ 命中则返回                                        │     │
|  │       ▼                                                   │     │
|  │  检查 Coarse Map (粗粒度位图)                             │     │
|  │       │ 已记录则返回                                      │     │
|  │       ▼                                                   │     │
|  │  尝试 Sparse Table (稀疏表)                               │     │
|  │       │ 添加成功则返回                                    │     │
|  │       ▼ 表满                                              │     │
|  │  尝试 Fine Grain Table (细粒度表)                         │     │
|  │       │ 有空间则添加                                      │     │
|  │       ▼ 表满                                              │     │
|  │  降级：删除PRT，设置Coarse Map                            │     │
|  │                                                          │     │
|  └─────────────────────────────────────────────────────────┘     │
+------------------------------------------------------------------+
```

### 2.2 add_reference - 核心添加逻辑

```cpp
346: void OtherRegionsTable::add_reference(OopOrNarrowOopStar from, uint tid) {
347:   uint cur_hrm_ind = _hr->hrm_index();
348:
349:   uintptr_t from_card = uintptr_t(from) >> CardTable::card_shift;
350:
351:   if (G1FromCardCache::contains_or_replace(tid, cur_hrm_ind, from_card)) {
352:     assert(contains_reference(from), "We just found " PTR_FORMAT " in the FromCardCache", p2i(from));
353:     return;
354:   }
355:
356:   // Note that this may be a continued H region.
357:   HeapRegion* from_hr = _g1h->heap_region_containing(from);
358:   RegionIdx_t from_hrm_ind = (RegionIdx_t) from_hr->hrm_index();
359:
360:   // If the region is already coarsened, return.
361:   if (_coarse_map.at(from_hrm_ind)) {
362:     assert(contains_reference(from), "We just found " PTR_FORMAT " in the Coarse table", p2i(from));
363:     return;
364:   }
365:
366:   // Otherwise find a per-region table to add it to.
367:   size_t ind = from_hrm_ind & _mod_max_fine_entries_mask;
368:   PerRegionTable* prt = find_region_table(ind, from_hr);
369:   if (prt == NULL) {
370:     MutexLockerEx x(_m, Mutex::_no_safepoint_check_flag);
```

**Line 346-370: add_reference逐行分析**

**第一步：FromCardCache检查 (Line 351-354)**
```
+------------------------------------------------------------------+
|                    FromCardCache 优化                             |
+------------------------------------------------------------------+
|                                                                   |
|  目的：快速判断最近是否处理过这张卡                                 │
|                                                                   |
|  数据结构：per-thread cache                                        │
|  _from_card_cache[tid][region_index] = last_card                  │
|                                                                   |
|  检查逻辑：                                                        │
|  if (cache[tid][cur_hrm_ind] == from_card) {                      │
|      return;  // 最近刚处理过，无需重复                            │
|  } else {                                                         │
|      cache[tid][cur_hrm_ind] = from_card;  // 更新缓存             │
|      continue;  // 继续处理                                        │
|  }                                                                │
|                                                                   |
|  效果：避免重复处理同一张卡，显著提高性能                           │
+------------------------------------------------------------------+
```

**第二步：Coarse Map检查 (Line 361-364)**
```
+------------------------------------------------------------------+
|                    Coarse Map 检查                                |
+------------------------------------------------------------------+
|                                                                   |
|  _coarse_map：位图，每一位对应一个Region                           │
|                                                                   |
|  if (_coarse_map.at(from_hrm_ind)) {                              │
|      return;  // 该Region已在粗粒度表中记录                        │
|  }                                                                │
|                                                                   |
|  何时设置coarse_map？                                              │
|  - Fine Grain表满时降级                                           │
|  - 设置coarse_map[from_hrm_ind] = 1                               │
|  - 后续来自该Region的所有引用直接返回                              │
+------------------------------------------------------------------+
```

**第三步：Fine Grain Hash查找 (Line 367-368)**
```
+------------------------------------------------------------------+
|                    Fine Grain Hash Table                          |
+------------------------------------------------------------------+
|                                                                   |
|  哈希函数：                                                        │
|  ind = from_hrm_ind & _mod_max_fine_entries_mask                  │
|  = from_hrm_ind % _max_fine_entries                               │
|                                                                   |
|  查找：                                                            │
|  prt = _fine_grain_regions[ind]                                   │
|  while (prt != NULL && prt->hr() != from_hr) {                    │
|      prt = prt->collision_list_next();  // 冲突链表                │
|  }                                                                │
|                                                                   |
|  冲突处理：链地址法                                                │
|  _fine_grain_regions[i] → PRT1 → PRT2 → PRT3 → NULL               │
+------------------------------------------------------------------+
```

### 2.3 add_reference 继续 - Sparse Table和Fine Grain

```cpp
370:     MutexLockerEx x(_m, Mutex::_no_safepoint_check_flag);
371:     // Confirm that it's really not there...
372:     prt = find_region_table(ind, from_hr);
373:     if (prt == NULL) {
374:
375:       CardIdx_t card_index = card_within_region(from, from_hr);
376:
377:       if (G1HRRSUseSparseTable &&
378:           _sparse_table.add_card(from_hrm_ind, card_index)) {
379:         assert(contains_reference_locked(from), "We just added " PTR_FORMAT " to the Sparse table", p2i(from));
380:         return;
381:       }
382:
383:       if (_n_fine_entries == _max_fine_entries) {
384:         prt = delete_region_table();
385:         // There is no need to clear the links to the 'all' list here:
386:         // prt will be reused immediately, i.e. remain in the 'all' list.
387:         _coarse_map.at_put(from_hrm_ind, 1);
388:         _n_coarse_entries++;
389:       }
```

**Line 370-389: 加锁后的处理流程**

**为什么需要加锁？**
```
+------------------------------------------------------------------+
|                    并发问题与锁                                    |
+------------------------------------------------------------------+
|                                                                   |
|  不加锁的问题：                                                    │
|  线程A: 检查prt==NULL                                             │
|  线程B: 检查prt==NULL                                             │
|  线程A: 创建新PRT                                                  │
|  线程B: 也创建新PRT → 同一Region有两个PRT！                         │
|                                                                   |
|  加锁后：                                                          │
|  线程A: 获取锁，检查NULL，创建PRT                                  │
|  线程B: 等待锁                                                     │
|  线程A: 释放锁                                                     │
|  线程B: 获取锁，再次检查（Line 372），发现已有PRT                   │
+------------------------------------------------------------------+
```

**Sparse Table尝试 (Line 377-381)**
```
+------------------------------------------------------------------+
|                    Sparse PRT                                     |
+------------------------------------------------------------------+
|                                                                   |
|  特点：                                                            │
|  - 内存占用小                                                      │
|  - 适合少量引用                                                    │
|  - 精确到卡级别                                                    │
|                                                                   |
|  添加逻辑：                                                        │
|  if (_sparse_table.add_card(from_hrm_ind, card_index)) {          │
|      return;  // 添加成功                                          │
|  }                                                                │
|  // Sparse表满，继续到Fine Grain                                   │
|                                                                   |
|  何时满？                                                          │
|  - G1HRRSSparseTableEntries = 2048 条记录                         │
+------------------------------------------------------------------+
```

**降级处理 (Line 383-388)**
```
+------------------------------------------------------------------+
|                    Fine Grain Table满时的降级                      |
+------------------------------------------------------------------+
|                                                                   |
|  条件：_n_fine_entries == _max_fine_entries                       │
|                                                                   |
|  操作：                                                            │
|  1. delete_region_table()                                         │
|     - 选择一个PRT删除（通常是最久未使用的）                         │
|     - 将该PRT的Region标记到coarse_map                              │
|     - 返回被删除的PRT供重用                                        │
|                                                                   │
|  2. 设置coarse_map                                                 │
|     _coarse_map.at_put(from_hrm_ind, 1);                          │
|     _n_coarse_entries++;                                          │
|                                                                   |
|  效果：                                                            │
|  - 释放一个PRT槽位                                                 │
|  - 但精度降低（只记录Region级别）                                  │
+------------------------------------------------------------------+
```

---

## 第3章: 三层存储对比与选择

### 3.1 三层存储对比表

| 特性 | Sparse PRT | Fine Grain | Coarse Map |
|------|------------|------------|------------|
| 精度 | 卡级（512B）| 卡级（512B）| Region级（4MB）|
| 内存 | 最小 | 中等 | 最小（1bit/Region）|
| 容量 | ~2048条 | ~2048个PRT | 无限制 |
| 查询 | O(1) | O(1)哈希 | O(1) |
| 适用 | 少量引用 | 中等引用 | 大量引用 |

### 3.2 降级流程图

```
+==================================================================+
|                    RSet 降级流程                                  |
+==================================================================+
|                                                                   |
|  初始状态：只有 Sparse Table                                       │
|  ┌─────────────────────────────────────────────────────────┐     │
|  │  Sparse Table: {Region1: [card1, card2], ...}          │     │
|  └─────────────────────────────────────────────────────────┘     │
|                                                                   |
|  引用增多，Sparse满：                                              │
|  ┌─────────────────────────────────────────────────────────┐     │
|  │  Sparse → Fine Grain Table                              │     │
|  │  Fine Grain: {                                          │     │
|  │    PRT1: Region1 → [card1, card2, ...]                  │     │
|  │    PRT2: Region2 → [card5, card6, ...]                  │     │
|  │    ...                                                   │     │
|  │  }                                                       │     │
|  └─────────────────────────────────────────────────────────┘     │
|                                                                   |
|  引用继续增多，Fine Grain满：                                       │
|  ┌─────────────────────────────────────────────────────────┐     │
|  │  Fine Grain → Coarse Map                                │     │
|  │  Coarse Map: {Region1: 1, Region3: 1, ...}              │     │
|  │  精度降低：只知道Region有引用，不知道具体卡               │     │
|  └─────────────────────────────────────────────────────────┘     │
+==================================================================+
```

---

## 面试高频问题

### Q1: 为什么需要三层存储？直接用一层不行吗？

```
A: 平衡内存占用和查询精度：

假设只使用Fine Grain Table：
- 每个Region需要2048个PRT槽位
- 每个PRT约1KB
- 2048个Region × 2048槽位 × 1KB = 4GB！
- 内存开销不可接受

三层设计：
- Sparse Table：少量引用时，只占几KB
- Fine Grain：中等引用，按需分配
- Coarse Map：大量引用，只占256字节

实际内存：
- 大多数Region只有少量引用 → Sparse就够了
- 热点Region才需要Fine Grain
- 极端情况降级到Coarse Map
```

### Q2: 降级到Coarse Map会有什么问题？

```
A: 精度丢失，但不影响正确性：

问题：
- Coarse Map只记录"Region级"
- GC时需要扫描整个Region
- 暂停时间增加

不影响正确性：
- 宁可多扫描，不会漏掉引用
- 只是性能损失

优化：
- 只有极端引用密集的Region才会降级
- 通常不超过总Region的1%
```

---

## GDB调试脚本

```bash
# verify_rset_data_structures.gdb
set pagination off

break OtherRegionsTable::add_reference
break PerRegionTable::add_card_work
break OtherRegionsTable::delete_region_table

run -Xms8g -Xmx8g -XX:+UseG1GC -XX:+PrintGCDetails

# 查看三层存储统计
p _other_regions._n_fine_entries
p _other_regions._n_coarse_entries
p _other_regions._sparse_table._occupied()

# 查看PRT内容
p prt->_hr->hrm_index()
p prt->_occupied
p prt->_bm

# 查看Coarse Map
p _coarse_map

continue
quit
```

---

**文档完成**

本文档完成了G1 RemSet数据结构的逐行深度分析：
- PerRegionTable内部实现（位图、链表、无锁分配）
- OtherRegionsTable三层存储
- add_reference核心添加逻辑
- Sparse Table → Fine Grain → Coarse Map降级流程
- 并发控制与锁设计

下一部分：**G1Policy预测模型** - 衰减平均、存活率预测
