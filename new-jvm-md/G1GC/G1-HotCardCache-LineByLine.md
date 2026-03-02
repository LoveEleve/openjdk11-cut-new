# G1HotCardCache 逐行源码分析

> **核心目标**：深入理解 G1 热卡缓存的优化原理、LRU 驱逐策略、卡计数机制和并发安全保障。

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1HotCardCache 的本质是**频繁修改的"热卡"的去重缓冲区**：某些卡（512 字节区域）被频繁修改（如循环中修改同一个数组），每次修改都产生一个脏卡入队，导致 Refinement 线程重复处理同一张卡。HotCardCache 缓存这些热卡，避免重复入队，减少 Refinement 线程的工作量。

### 0.2 工作原理

**固定大小哈希表 + LRU 驱逐**：
- `G1HotCardCache` 是一个固定大小的哈希表（默认 `G1HotCardCacheSize = 16K` 个槽位）
- 写屏障将脏卡地址哈希到槽位，如果槽位已有相同地址则不入队（去重）
- 如果槽位有不同地址则将旧地址入队（驱逐），新地址占用槽位（LRU 近似）
- GC 开始时 `drain()` 将所有缓存的热卡入队处理

### 0.3 热卡判定

卡被修改次数超过 `G1HotCardCacheThreshold`（默认 4）次时，认为是"热卡"；热卡进入 HotCardCache 而不是直接入 DirtyCardQueue；避免热卡被 Refinement 线程反复处理。

### 0.4 为什么这样设计？

- **为什么用固定大小哈希表？** 写屏障在热路径上，哈希操作必须 O(1) 且代价极低；固定大小避免动态扩容
- **为什么 GC 开始时 drain？** GC 需要处理所有脏卡（确保 RSet 完整）；HotCardCache 中的热卡也需要在 GC 前处理

---

## 目录

1. [问题引入：为什么需要热卡缓存？](#1-问题引入为什么需要热卡缓存)
2. [整体架构](#2-整体架构)
3. [内存布局](#3-内存布局)
4. [G1CardCounts 卡计数器](#4-g1cardcounts-卡计数器)
5. [热卡缓存核心算法](#5-热卡缓存核心算法)
6. [并发安全保障](#6-并发安全保障)
7. [关键场景分析](#7-关键场景分析)
8. [GDB 验证脚本](#8-gdb-验证脚本)
9. [面试级 Q&A](#9-面试级-qa)

---

## 1. 问题引入：为什么需要热卡缓存？

### 问题场景

**热点数据的写屏障开销**：

```java
// 热点数据：频繁修改的对象
class HotData {
    Object field1;  // 被频繁修改
}

// 模拟热点数据
for (int i = 0; i < 10000; i++) {
    hotData.field1 = new Object();  // 每次都触发写屏障
}
```

**传统写屏障的重复工作**：

```
第1次写入：hotData.field1 = obj1
  → 写屏障标记卡为 dirty
  → 并发精炼线程扫描卡，更新 RSet

第2次写入：hotData.field1 = obj2
  → 写屏障标记卡为 dirty（已经是 dirty，跳过）
  → 但之前已经入队的卡还在处理中
  → 并发精炼线程再次扫描同一张卡

第3次写入：hotData.field1 = obj3
  → 同样的流程重复...

问题：同一张卡被反复扫描，大量重复工作！
```

**性能影响**：

```
假设一张卡在短时间内被修改 100 次：
传统方式：100 次精炼扫描
热卡缓存：只精炼 1 次（最后一次写入后的状态）
性能提升：~100 倍
```

### 解决方案

**热卡缓存的核心思想**：

```
1. 统计每张卡被修改的次数
2. 超过阈值（默认 4 次）的卡被认为是"热卡"
3. 热卡不立即精炼，而是放入缓存
4. 等缓存满驱逐或 GC 时批量处理
5. 减少重复扫描，提升性能
```

**优化效果**：

| 场景 | 传统方式 | 热卡缓存 | 提升 |
|------|----------|----------|------|
| 热点数据（100次修改） | 100次精炼 | 1次精炼 | 100倍 |
| 普通数据（1次修改） | 1次精炼 | 1次精炼 | 无变化 |
| 混合场景 | 平均N次 | 平均1-2次 | 显著 |

---

## 2. 整体架构

### 2.1 类关系图

```
┌─────────────────────────────────────────────────────────────┐
│                    G1HotCardCache                           │
│                                                             │
│  - _g1h: G1CollectedHeap*                                  │
│  - _use_cache: bool                                        │
│  - _card_counts: G1CardCounts                              │
│  - _hot_cache: jbyte**                                     │
│  - _hot_cache_size: size_t (1024)                          │
│  - _hot_cache_idx: volatile size_t                         │
│  - _hot_cache_par_claimed_idx: volatile size_t             │
│                                                             │
│  + insert(card_ptr): jbyte*                                │
│  + drain(cl, worker_i): void                               │
│  + reset_hot_cache(): void                                 │
└───────────────────────────┬─────────────────────────────────┘
                            │ 组合
                            ↓
┌─────────────────────────────────────────────────────────────┐
│                    G1CardCounts                             │
│                                                             │
│  - _g1h: G1CollectedHeap*                                  │
│  - _ct: G1CardTable*                                       │
│  - _card_counts: jubyte*                                   │
│  - _reserved_max_card_num: size_t                          │
│  - _ct_bot: const jbyte*                                   │
│                                                             │
│  + add_card_count(card_ptr): uint                          │
│  + is_hot(count): bool                                     │
│  + clear_region(hr): void                                  │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 工作流程

```
写屏障触发
    │
    ↓
G1HotCardCache::insert(card_ptr)
    │
    ├─→ _card_counts.add_card_count(card_ptr)
    │       │
    │       ↓
    │   count = _card_counts[card_num]
    │   if (count < 4) _card_counts[card_num]++
    │   return count
    │
    ├─→ is_hot(count)?
    │       │
    │   ┌───┴───┐
    │   │ No    │ Yes (count >= 4)
    │   ↓       ↓
    │ return    放入热卡缓存
    │ card_ptr      │
    │ (立即精炼)     ├─→ index = Atomic::add(1, &_hot_cache_idx) - 1
    │               │
    │               ├─→ masked_index = index & (_hot_cache_size - 1)
    │               │
    │               └─→ Atomic::cmpxchg(card_ptr, &_hot_cache[masked_index], current_ptr)
    │                       │
    │                   ┌───┴───┐
    │                   │ 成功  │ 失败（竞争）
    │                   ↓       ↓
    │               返回被驱逐  返回当前卡
    │               的旧卡      (稍后重试)
    │
    ↓
返回值处理
    │
    ├─→ NULL：卡在缓存中，无需处理
    ├─→ card_ptr：立即精炼
    └─→ evicted_card：精炼被驱逐的卡
```

---

## 3. 内存布局

### 3.1 G1HotCardCache 字段布局

```cpp
// src/hotspot/share/gc/g1/g1HotCardCache.hpp:56-84
class G1HotCardCache: public CHeapObj<mtGC> {
  G1CollectedHeap*  _g1h;                                // offset 0

  bool              _use_cache;                          // offset 8

  G1CardCounts      _card_counts;                        // offset 16

  jbyte**           _hot_cache;                          // offset ?
  size_t            _hot_cache_size;                     // offset ?
  size_t            _hot_cache_par_chunk_size;           // offset ?

  char _pad_before[DEFAULT_CACHE_LINE_SIZE];             // 缓存行填充（64字节）
  volatile size_t   _hot_cache_idx;                      // 避免伪共享
  volatile size_t   _hot_cache_par_claimed_idx;          // 避免伪共享
  char _pad_after[DEFAULT_CACHE_LINE_SIZE];              // 缓存行填充（64字节）

  static const int ClaimChunkSize = 32;                  // 并行处理块大小
};
```

**内存布局图**：

```
G1HotCardCache 对象：
+----------------------------+ offset 0
| _g1h                       | 8 bytes
+----------------------------+ offset 8
| _use_cache                 | 1 byte (padding to 8)
+----------------------------+ offset 16
| _card_counts               | G1CardCounts 对象 (~40 bytes)
+----------------------------+ offset ~56
| _hot_cache                 | 8 bytes
+----------------------------+
| _hot_cache_size            | 8 bytes
+----------------------------+
| _hot_cache_par_chunk_size  | 8 bytes
+----------------------------+
| _pad_before[64]            | 64 bytes (缓存行对齐)
+----------------------------+
| _hot_cache_idx             | 8 bytes (原子变量)
+----------------------------+
| _hot_cache_par_claimed_idx | 8 bytes (原子变量)
+----------------------------+
| _pad_after[64]             | 64 bytes (缓存行对齐)
+----------------------------+
```

### 3.2 _hot_cache 数组布局

```cpp
// 默认大小：_hot_cache_size = 1 << G1ConcRSLogCacheSize = 1 << 10 = 1024
_hot_cache = new jbyte*[1024];  // 每个元素是一个指向卡表项的指针
```

**内存布局**：

```
_hot_cache 数组（堆外内存）：
+--------+--------+--------+--------+-----+
| slot 0 | slot 1 | slot 2 | slot 3 | ... | 1024 slots
+--------+--------+--------+--------+-----+
    ↓        ↓        ↓        ↓
 卡指针   卡指针   卡指针   卡指针

每个 slot 大小：8 bytes（64位指针）
总大小：1024 * 8 = 8 KB
```

### 3.3 G1CardCounts 计数数组布局

```cpp
// src/hotspot/share/gc/g1/g1CardCounts.cpp:87
_card_counts = (jubyte*) mapper->reserved().start();
_reserved_max_card_num = mapper->reserved().byte_size();  // 16MB (8GB堆)
```

**计数数组与卡表的关系**：

```
卡表 (_byte_map)：
+----+----+----+----+----+----+----+----+-----+
| 0  | 1  | 2  | 3  | 4  | 5  | 6  | 7  | ... | 16777216 个字节
+----+----+----+----+----+----+----+----+-----+
  ↓    ↓    ↓    ↓    ↓    ↓    ↓    ↓
 卡状态

计数数组 (_card_counts)：
+----+----+----+----+----+----+----+----+-----+
| 0  | 1  | 2  | 3  | 4  | 5  | 6  | 7  | ... | 16777216 个字节
+----+----+----+----+----+----+----+----+-----+
  ↓    ↓    ↓    ↓    ↓    ↓    ↓    ↓
 修改次数

一一对应关系：
  卡表[i] 的修改次数 = 计数数组[i]
  
示例：
  卡表[100] = dirty_card (0x00)
  计数数组[100] = 5 (被修改了5次)
```

---

## 4. G1CardCounts 卡计数器

### 4.1 初始化

```cpp
// src/hotspot/share/gc/g1/g1CardCounts.cpp:65-91
void G1CardCounts::initialize(G1RegionToSpaceMapper* mapper) {
  assert(_g1h->max_capacity() > 0, "initialization order");
  assert(_g1h->capacity() == 0, "initialization order");
  
  // G1ConcRSHotCardLimit 默认值 = 4
  if (G1ConcRSHotCardLimit > 0) {
    guarantee(G1ConcRSHotCardLimit <= max_jubyte, "sanity");
    
    // 获取卡表引用
    _ct = _g1h->card_table();
    
    // 计算卡表起始位置
    // _ct_bot = &_byte_map_base[heap_start >> 9]
    _ct_bot = _ct->byte_for_const(_g1h->reserved_region().start());
    
    // 获取计数数组存储空间
    _card_counts = (jubyte*) mapper->reserved().start();
    _reserved_max_card_num = mapper->reserved().byte_size();  // 16MB
    
    mapper->set_mapping_changed_listener(&_listener);
  }
}
```

**关键点**：
- 计数数组大小 = 卡表大小（16MB for 8GB heap）
- `_ct_bot` 是卡表的起始位置，用于计算卡索引

### 4.2 add_card_count() 详解

```cpp
// src/hotspot/share/gc/g1/g1CardCounts.cpp:93-115
uint G1CardCounts::add_card_count(jbyte* card_ptr) {
  uint count = 0;
  
  if (has_count_table()) {
    // 步骤1：计算卡索引
    size_t card_num = ptr_2_card_num(card_ptr);
    
    // 步骤2：读取当前计数
    count = (uint) _card_counts[card_num];
    
    // 步骤3：如果计数 < 热卡阈值，则增加
    if (count < G1ConcRSHotCardLimit) {
      _card_counts[card_num] =
        (jubyte)(MIN2((uintx)(_card_counts[card_num] + 1), G1ConcRSHotCardLimit));
    }
  }
  
  return count;  // 返回增加前的计数
}
```

**计数逻辑**：

```
第一次写入：
  count = _card_counts[card_num] = 0
  _card_counts[card_num] = MIN2(0 + 1, 4) = 1
  return 0

第二次写入：
  count = _card_counts[card_num] = 1
  _card_counts[card_num] = MIN2(1 + 1, 4) = 2
  return 1

第三次写入：
  count = _card_counts[card_num] = 2
  _card_counts[card_num] = MIN2(2 + 1, 4) = 3
  return 2

第四次写入：
  count = _card_counts[card_num] = 3
  _card_counts[card_num] = MIN2(3 + 1, 4) = 4
  return 3

第五次写入：
  count = _card_counts[card_num] = 4
  if (count < 4) 不满足，不增加
  return 4

is_hot(4) = true  // 认为是热卡
```

### 4.3 ptr_2_card_num() 地址转换

```cpp
// src/hotspot/share/gc/g1/g1CardCounts.cpp:79-89
size_t ptr_2_card_num(const jbyte* card_ptr) {
  assert(card_ptr >= _ct_bot,
         "Invalid card pointer: "
         "card_ptr: " PTR_FORMAT ", "
         "_ct_bot: " PTR_FORMAT,
         p2i(card_ptr), p2i(_ct_bot));
  
  size_t card_num = pointer_delta(card_ptr, _ct_bot, sizeof(jbyte));
  
  assert(card_num < _reserved_max_card_num,
         "card pointer out of range: " PTR_FORMAT, p2i(card_ptr));
  
  return card_num;
}
```

**计算示例**：

```
堆起始地址：     0x00007f0000000000
卡表起始地址：   0x00007f0080000000 (_byte_map)
_ct_bot =       0x00007f0080000000

卡指针：         0x00007f0080001000

card_num = pointer_delta(0x00007f0080001000, 0x00007f0080000000, 1)
         = 0x00007f0080001000 - 0x00007f0080000000
         = 0x1000 = 4096

验证：
  第 4096 张卡对应的堆地址：
  heap_addr = heap_start + card_num * 512
             = 0x00007f0000000000 + 4096 * 512
             = 0x00007f0000000000 + 2097152
             = 0x00007f0000200000

  卡表指针：
  byte_for(0x00007f0000200000) = &_byte_map_base[0x00007f0000200000 >> 9]
                                = &_byte_map_base[4096]
                                = _byte_map + 4096
                                = 0x00007f0080000000 + 4096
                                = 0x00007f0080001000 ✓
```

---

## 5. 热卡缓存核心算法

### 5.1 insert() 详解

```cpp
// src/hotspot/share/gc/g1/g1HotCardCache.cpp:110-132
jbyte* G1HotCardCache::insert(jbyte* card_ptr) {
  // 步骤1：增加卡计数
  uint count = _card_counts.add_card_count(card_ptr);
  
  // 步骤2：检查是否为热卡
  if (!_card_counts.is_hot(count)) {
    // 不是热卡，立即返回，让调用者精炼
    return card_ptr;
  }
  
  // 步骤3：是热卡，放入缓存
  // 原子递增索引
  size_t index = Atomic::add(1u, &_hot_cache_idx) - 1;
  
  // 步骤4：计算槽位（环形缓冲）
  size_t masked_index = index & (_hot_cache_size - 1);
  
  // 步骤5：读取当前槽位的卡指针
  jbyte* current_ptr = _hot_cache[masked_index];
  
  // 步骤6：CAS 更新槽位
  jbyte* previous_ptr = Atomic::cmpxchg(card_ptr,
                                        &_hot_cache[masked_index],
                                        current_ptr);
  
  // 步骤7：返回被驱逐的卡或当前卡
  return (previous_ptr == current_ptr) ? previous_ptr : card_ptr;
}
```

**算法详解**：

#### 步骤1：增加卡计数

```cpp
uint count = _card_counts.add_card_count(card_ptr);
```

- 返回增加**前**的计数
- 如果 `count >= 4`，认为是热卡

#### 步骤2：热卡判断

```cpp
bool G1CardCounts::is_hot(uint count) {
  return (count >= G1ConcRSHotCardLimit);  // 默认 4
}
```

#### 步骤3：环形缓冲索引

```cpp
size_t index = Atomic::add(1u, &_hot_cache_idx) - 1;
size_t masked_index = index & (_hot_cache_size - 1);
```

**环形缓冲原理**：

```
_hot_cache_size = 1024 = 2^10
_hot_cache_size - 1 = 0x000003FF

index = 0  → masked_index = 0  & 0x3FF = 0
index = 1  → masked_index = 1  & 0x3FF = 1
...
index = 1023 → masked_index = 1023 & 0x3FF = 1023
index = 1024 → masked_index = 1024 & 0x3FF = 0    // 环回
index = 1025 → masked_index = 1025 & 0x3FF = 1    // 环回

优点：
  - 无需取模运算（%），位运算更快
  - 大小必须是 2 的幂
```

#### 步骤4-6：CAS 更新

```cpp
jbyte* current_ptr = _hot_cache[masked_index];
jbyte* previous_ptr = Atomic::cmpxchg(card_ptr,
                                      &_hot_cache[masked_index],
                                      current_ptr);
return (previous_ptr == current_ptr) ? previous_ptr : card_ptr;
```

**CAS 语义**：

```
if (_hot_cache[masked_index] == current_ptr) {
  _hot_cache[masked_index] = card_ptr;
  return current_ptr;  // 成功，返回旧值（可能为 NULL）
} else {
  return card_ptr;     // 失败，返回当前卡
}
```

**竞争场景**：

```
线程A：
  index_A = Atomic::add(1, &_hot_cache_idx) - 1 = 100
  masked_index_A = 100 & 1023 = 100
  current_ptr_A = _hot_cache[100] = NULL
  
线程B：
  index_B = Atomic::add(1, &_hot_cache_idx) - 1 = 101
  masked_index_B = 101 & 1023 = 101  // 不同的槽位
  
无竞争！因为 Atomic::add 保证索引唯一
```

**驱逐场景**：

```
初始状态：
  _hot_cache_idx = 0
  _hot_cache[0] = card_1

插入 card_2：
  index = Atomic::add(1, &_hot_cache_idx) - 1 = 0
  masked_index = 0
  current_ptr = card_1
  cmpxchg(card_2, &_hot_cache[0], card_1)
  成功：返回 card_1（被驱逐的卡）

结果：
  _hot_cache[0] = card_2
  返回 card_1（需要精炼）
```

### 5.2 返回值语义

```cpp
jbyte* result = hot_card_cache->insert(card_ptr);
```

| 返回值 | 含义 | 调用者动作 |
|--------|------|------------|
| `NULL` | 卡在缓存中，无需处理 | 无 |
| `card_ptr` | 卡不是热卡，或 CAS 失败 | 立即精炼 |
| `evicted_card` | 成功插入，驱逐了旧卡 | 精炼被驱逐的卡 |

**调用者代码**：

```cpp
// src/hotspot/share/gc/g1/g1RemSet.cpp
void G1RemSet::refine_card(...) {
  jbyte* card_ptr = ...;
  
  // 尝试插入热卡缓存
  jbyte* card_to_refine = _hot_card_cache->insert(card_ptr);
  
  if (card_to_refine == NULL) {
    // 卡在缓存中，无需处理
    return;
  }
  
  // 精炼卡（可能是当前卡，也可能是被驱逐的旧卡）
  do_refinement(card_to_refine);
}
```

---

## 6. 并发安全保障

### 6.1 _hot_cache_idx 的原子递增

```cpp
size_t index = Atomic::add(1u, &_hot_cache_idx) - 1;
```

**为什么用 Atomic::add 而不是 Atomic::fetch_and_add？**

```cpp
// Atomic::add 返回增加后的值
size_t Atomic::add(1u, &_hot_cache_idx);  // 返回新值

// 所以需要 -1 得到旧值
size_t index = Atomic::add(1u, &_hot_cache_idx) - 1;
```

**原子性保证**：

```
线程A：index_A = Atomic::add(1, &_hot_cache_idx) - 1
        假设 _hot_cache_idx 从 0 变为 1，返回 0

线程B：index_B = Atomic::add(1, &_hot_cache_idx) - 1
        假设 _hot_cache_idx 从 1 变为 2，返回 1

每个线程得到唯一的索引！
```

### 6.2 缓存行填充避免伪共享

```cpp
char _pad_before[DEFAULT_CACHE_LINE_SIZE];  // 64 bytes
volatile size_t _hot_cache_idx;
volatile size_t _hot_cache_par_claimed_idx;
char _pad_after[DEFAULT_CACHE_LINE_SIZE];   // 64 bytes
```

**伪共享问题**：

```
假设两个原子变量在同一缓存行：
+-------------------------------------------+
| _hot_cache_idx | _hot_cache_par_claimed_idx|
+-------------------------------------------+
       缓存行 A（64 bytes）

线程A 更新 _hot_cache_idx → 锁定缓存行 A
线程B 更新 _hot_cache_par_claimed_idx → 等待缓存行 A

伪共享导致性能下降！
```

**缓存行填充后**：

```
+-------------------------------------------+
|          _pad_before (64 bytes)           |
+-------------------------------------------+
|         _hot_cache_idx (8 bytes)          |
+-------------------------------------------+
|   _hot_cache_par_claimed_idx (8 bytes)    |
+-------------------------------------------+
|          _pad_after (64 bytes)            |
+-------------------------------------------+

每个原子变量独占缓存行，无伪共享！
```

### 6.3 CAS 更新缓存槽位

```cpp
jbyte* previous_ptr = Atomic::cmpxchg(card_ptr,
                                      &_hot_cache[masked_index],
                                      current_ptr);
```

**CAS 的作用**：

```
场景：多个线程竞争更新同一个槽位（极少发生）

线程A：
  current_ptr_A = _hot_cache[100] = card_1
  cmpxchg(card_A, &_hot_cache[100], card_1)

线程B：
  current_ptr_B = _hot_cache[100] = card_1
  cmpxchg(card_B, &_hot_cache[100], card_1)

如果 A 先成功：
  _hot_cache[100] = card_A
  
B 的 CAS 失败：
  因为 _hot_cache[100] != card_1（现在是 card_A）
  返回 card_B
  
B 会精炼 card_B，稍后可能重试插入
```

---

## 7. 关键场景分析

### 7.1 场景1：普通卡（修改次数 < 4）

```java
// 第一次写入
obj.field = new Object();
```

**处理流程**：

```
1. 写屏障标记卡为 dirty
2. G1HotCardCache::insert(card_ptr)
3. count = _card_counts.add_card_count(card_ptr) = 0
4. _card_counts[card_num]++ → 1
5. is_hot(0)? → No
6. return card_ptr
7. 调用者立即精炼该卡
```

**第二次、第三次写入**：

```
count = 1 → is_hot(1)? → No
count = 2 → is_hot(2)? → No

每次都立即精炼
```

### 7.2 场景2：热卡（修改次数 >= 4）

```java
// 热点数据，频繁修改
for (int i = 0; i < 100; i++) {
    hotObj.field = new Object();
}
```

**处理流程**：

```
第1次写入：count = 0 → 不是热卡 → 立即精炼
第2次写入：count = 1 → 不是热卡 → 立即精炼
第3次写入：count = 2 → 不是热卡 → 立即精炼
第4次写入：count = 3 → 不是热卡 → 立即精炼
第5次写入：count = 4 → 是热卡！ → 放入缓存
第6次写入：count = 4（已达到阈值）→ 是热卡 → 放入缓存
...
第100次写入：count = 4 → 是热卡 → 放入缓存

前4次：立即精炼
后96次：延迟精炼（等缓存满或 GC）

优化效果：96 次精炼 → 1 次精炼（缓存满时驱逐）
```

### 7.3 场景3：缓存满驱逐

```
假设缓存已满：
_hot_cache[0] = card_A
_hot_cache[1] = card_B
...
_hot_cache[1023] = card_Z

新插入 card_New：
1. index = Atomic::add(1, &_hot_cache_idx) - 1 = 1024
2. masked_index = 1024 & 1023 = 0
3. current_ptr = _hot_cache[0] = card_A
4. cmpxchg(card_New, &_hot_cache[0], card_A)
5. 成功，返回 card_A

结果：
_hot_cache[0] = card_New
card_A 被驱逐，需要精炼

LRU 语义：
  虽然不是严格的 LRU，但环形缓冲提供了一种"先进先出"的驱逐策略
  最早插入的卡最先被驱逐
```

### 7.4 场景4：GC 时批量处理

```cpp
// src/hotspot/share/gc/g1/g1HotCardCache.cpp:134-159
void G1HotCardCache::drain(CardTableEntryClosure* cl, uint worker_i) {
  assert(default_use_cache(), "Drain only necessary if we use the hot card cache.");
  assert(_hot_cache != NULL, "Logic");
  assert(!use_cache(), "cache should be disabled");

  // 并行处理热卡缓存
  while (_hot_cache_par_claimed_idx < _hot_cache_size) {
    // 每个线程认领 32 个卡
    size_t end_idx = Atomic::add(_hot_cache_par_chunk_size,
                                 &_hot_cache_par_claimed_idx);
    size_t start_idx = end_idx - _hot_cache_par_chunk_size;
    
    end_idx = MIN2(end_idx, _hot_cache_size);
    
    // 处理认领的卡
    for (size_t i = start_idx; i < end_idx; i++) {
      jbyte* card_ptr = _hot_cache[i];
      if (card_ptr != NULL) {
        bool result = cl->do_card_ptr(card_ptr, worker_i);
        assert(result, "Closure should always return true");
      } else {
        break;
      }
    }
  }
}
```

**并行处理流程**：

```
假设 4 个 GC 线程：

线程1：认领 [0, 32)
线程2：认领 [32, 64)
线程3：认领 [64, 96)
线程4：认领 [96, 128)

线程1：认领 [128, 160)
...

Atomic::add 保证每个线程认领不同的范围
```

---

## 8. GDB 验证脚本

### 8.1 验证热卡缓存布局

```gdb
# gdb_script: verify_hot_card_cache.gdb
# 用法: gdb -x verify_hot_card_cache.gdb --args java -Xms8g -Xmx8g -XX:+UseG1GC ...

break Threads::create_vm
commands
  continue
end

run

# 查找 G1HotCardCache
set $heap = (G1CollectedHeap*)Universe::_collectedHeap
set $hcc = $heap->_hot_card_cache

printf "\n=== G1HotCardCache 布局 ===\n"
printf "_use_cache:         %s\n", $hcc->_use_cache ? "true" : "false"
printf "_hot_cache_size:    %lu\n", $hcc->_hot_cache_size
printf "_hot_cache:         %p\n", $hcc->_hot_cache
printf "_hot_cache_idx:     %lu\n", $hcc->_hot_cache_idx
printf "_hot_cache_par_claimed_idx: %lu\n", $hcc->_hot_cache_par_claimed_idx

# 验证缓存数组
printf "\n=== _hot_cache 数组内容（前10个）===\n"
set $i = 0
while $i < 10
  printf "[%3lu] %p\n", $i, $hcc->_hot_cache[$i]
  set $i = $i + 1
end

# 验证 G1CardCounts
set $cc = &$hcc->_card_counts
printf "\n=== G1CardCounts 布局 ===\n"
printf "_card_counts:       %p\n", $cc->_card_counts
printf "_reserved_max_card_num: %lu\n", $cc->_reserved_max_card_num
printf "_ct_bot:            %p\n", $cc->_ct_bot
printf "G1ConcRSHotCardLimit: %d\n", G1ConcRSHotCardLimit
```

### 8.2 观察热卡插入过程

```gdb
# gdb_script: observe_hot_card_insert.gdb

break G1HotCardCache::insert
commands
  printf "\n=== insert() 被调用 ===\n"
  printf "card_ptr: %p\n", $rdi
  
  # 单步执行
  next
  
  # 查看计数
  printf "count: %d\n", $eax
  
  # 查看是否为热卡
  if $eax >= 4
    printf "→ 热卡！将放入缓存\n"
  else
    printf "→ 普通卡，立即精炼\n"
  end
  
  continue
end

run
```

### 8.3 统计热卡分布

```gdb
# gdb_script: count_hot_cards.gdb

define count_hot_cards
  set $heap = (G1CollectedHeap*)Universe::_collectedHeap
  set $hcc = $heap->_hot_card_cache
  set $cc = &$hcc->_card_counts
  
  set $hot_count = 0
  set $warm_count = 0
  set $cold_count = 0
  
  set $i = 0
  while $i < $cc->_reserved_max_card_num
    set $count = $cc->_card_counts[$i]
    
    if $count >= 4
      set $hot_count = $hot_count + 1
    else
      if $count > 0
        set $warm_count = $warm_count + 1
      else
        set $cold_count = $cold_count + 1
      end
    end
    
    set $i = $i + 1
  end
  
  printf "\n=== 卡计数统计 ===\n"
  printf "热卡（count >= 4）: %lu = %.2f%%\n", $hot_count, (float)$hot_count * 100 / $cc->_reserved_max_card_num
  printf "温卡（0 < count < 4）: %lu = %.2f%%\n", $warm_count, (float)$warm_count * 100 / $cc->_reserved_max_card_num
  printf "冷卡（count = 0）: %lu = %.2f%%\n", $cold_count, (float)$cold_count * 100 / $cc->_reserved_max_card_num
end

# 在程序运行一段时间后调用
# (gdb) count_hot_cards
```

### 8.4 观察缓存驱逐

```gdb
# gdb_script: observe_cache_eviction.gdb

set $evicted_count = 0

break G1HotCardCache::insert
commands
  # 跳过非热卡
  next
  if $eax < 4
    continue
  end
  
  # 热卡插入
  next
  next
  next
  
  # 检查是否有驱逐
  set $evicted = (jbyte*)$rax
  if $evicted != 0
    set $evicted_count = $evicted_count + 1
    printf "\n=== 缓存驱逐 #%lu ===\n", $evicted_count
    printf "被驱逐的卡: %p\n", $evicted
  end
  
  continue
end

run
```

---

## 9. 面试级 Q&A

### Q1: 热卡缓存解决了什么问题？为什么能提升性能？

**A**: 解决热点数据重复精炼的问题。

**问题**：
- 某些内存区域被频繁修改（热点数据）
- 每次修改都触发写屏障，标记脏卡
- 并发精炼线程反复扫描同一张卡
- 大量重复工作，浪费 CPU

**解决方案**：
- 统计每张卡被修改的次数
- 超过阈值（默认4次）认为是热卡
- 热卡不立即精炼，放入缓存
- 等缓存满或 GC 时批量处理

**性能提升**：
```
假设一张卡被修改 100 次：
传统方式：100 次精炼扫描
热卡缓存：1 次精炼（最后一次状态）
提升：~100 倍
```

---

### Q2: G1ConcRSHotCardLimit 为什么默认是 4？

**A**: 权衡过早缓存和过度精炼。

**如果阈值太低（如 1）**：
```
第1次修改：立即缓存
问题：大多数卡只修改1次，过早缓存反而增加开销
```

**如果阈值太高（如 10）**：
```
第1-9次修改：立即精炼
第10次修改：才缓存
问题：真正的热卡在第4-9次时已经做了大量重复精炼
```

**默认值 4 的理由**：
```
第1-4次：立即精炼（确认不是瞬时热点）
第5次起：缓存（确认为持续热点）

经验值，平衡两种情况：
- 大多数卡修改次数 < 4，立即精炼
- 真正的热卡修改次数 >= 4，延迟精炼
```

---

### Q3: 热卡缓存是严格的 LRU 吗？

**A**: 不是，是环形缓冲 + LRU 近似。

**严格 LRU 实现**：
```
需要维护访问时间戳或链表
每次访问都需要更新
开销较大
```

**G1 的环形缓冲**：
```
_hot_cache_idx 递增
masked_index = index & (_hot_cache_size - 1)
环形覆盖旧条目

驱逐策略：先进先出（FIFO）
近似 LRU：最早插入的卡最先被驱逐
```

**为什么够用**：
```
热卡缓存的目的：延迟精炼，减少重复工作
不要求精确的 LRU
环形缓冲足够应对大多数场景
实现简单，性能高
```

---

### Q4: 计数数组会不会溢出？最大值是多少？

**A**: 不会溢出，最大值被限制为 G1ConcRSHotCardLimit。

**代码**：
```cpp
if (count < G1ConcRSHotCardLimit) {
  _card_counts[card_num] =
    (jubyte)(MIN2((uintx)(_card_counts[card_num] + 1), G1ConcRSHotCardLimit));
}
```

**逻辑**：
```
count = _card_counts[card_num]

if (count < 4) {
  _card_counts[card_num] = MIN2(count + 1, 4);
}

第1次：count=0 → _card_counts=MIN2(1, 4)=1
第2次：count=1 → _card_counts=MIN2(2, 4)=2
第3次：count=2 → _card_counts=MIN2(3, 4)=3
第4次：count=3 → _card_counts=MIN2(4, 4)=4
第5次：count=4 → 不满足 count<4，不增加

最大值：4（或 G1ConcRSHotCardLimit）
```

**为什么这样设计**：
```
一旦 count >= G1ConcRSHotCardLimit，就是热卡
后续无论修改多少次，都只返回 count=4
is_hot(4) = true
无需记录精确次数，节省一位
```

---

### Q5: 为什么需要缓存行填充？不填充会怎样？

**A**: 避免伪共享，提升性能。

**伪共享问题**：

```
假设两个原子变量在同一缓存行（64字节）：
+--------------------------------------------------+
| _hot_cache_idx (8B) | _hot_cache_par_claimed_idx (8B) | ... |
+--------------------------------------------------+
          缓存行 A（64 bytes）

线程A（CPU核心1）：更新 _hot_cache_idx
  → 锁定整个缓存行 A

线程B（CPU核心2）：更新 _hot_cache_par_claimed_idx
  → 需要等待缓存行 A 解锁
  → 虽然两个线程修改的是不同的变量，但因为共享缓存行，必须串行

性能影响：多线程并发更新时，伪共享导致缓存行频繁失效和同步
```

**缓存行填充后**：

```
+--------------------------------------------------+
|              _pad_before (64 bytes)              |
+--------------------------------------------------+
|            _hot_cache_idx (8 bytes)              |
+--------------------------------------------------+
|       _hot_cache_par_claimed_idx (8 bytes)       |
+--------------------------------------------------+
|              _pad_after (64 bytes)               |
+--------------------------------------------------+

每个原子变量独占一个缓存行
线程A 更新 _hot_cache_idx → 锁定缓存行 1
线程B 更新 _hot_cache_par_claimed_idx → 锁定缓存行 2
无干扰，真正并行！
```

**性能对比**：

```
无填充：多线程更新时，性能下降 20-50%
有填充：真正并行，无性能损失

代价：增加内存占用（128 字节）
收益：消除伪共享，显著提升并发性能
```

---

### Q6: drain() 为什么用 Atomic::add 认领块？不会重复吗？

**A**: Atomic::add 保证每个线程认领不同的范围。

**代码**：

```cpp
while (_hot_cache_par_claimed_idx < _hot_cache_size) {
  size_t end_idx = Atomic::add(_hot_cache_par_chunk_size,
                               &_hot_cache_par_claimed_idx);
  size_t start_idx = end_idx - _hot_cache_par_chunk_size;
  
  end_idx = MIN2(end_idx, _hot_cache_size);
  
  for (size_t i = start_idx; i < end_idx; i++) {
    // 处理卡
  }
}
```

**执行过程**：

```
假设 _hot_cache_size = 1024, _hot_cache_par_chunk_size = 32

线程1：
  end_idx = Atomic::add(32, &_hot_cache_par_claimed_idx) = 32
  _hot_cache_par_claimed_idx: 0 → 32
  start_idx = 32 - 32 = 0
  处理 [0, 32)

线程2：
  end_idx = Atomic::add(32, &_hot_cache_par_claimed_idx) = 64
  _hot_cache_par_claimed_idx: 32 → 64
  start_idx = 64 - 32 = 32
  处理 [32, 64)

线程3：
  end_idx = Atomic::add(32, &_hot_cache_par_claimed_idx) = 96
  _hot_cache_par_claimed_idx: 64 → 96
  start_idx = 96 - 32 = 64
  处理 [64, 96)

线程1 完成 [0, 32)，循环继续：
  end_idx = Atomic::add(32, &_hot_cache_par_claimed_idx) = 128
  _hot_cache_par_claimed_idx: 96 → 128
  start_idx = 128 - 32 = 96
  处理 [96, 128)

...

Atomic::add 的原子性保证：
  每次调用返回唯一的 end_idx
  每个线程认领不重叠的范围
```

**不会重复的原因**：

```
Atomic::add 是原子的：
  read(_hot_cache_par_claimed_idx) → add(_hot_cache_par_chunk_size) → write(_hot_cache_par_claimed_idx)

整个过程不可分割，保证：
  线程1 读到 0，加 32，写回 32
  线程2 读到 32，加 32，写回 64
  线程3 读到 64，加 32，写回 96
  ...

每个线程读到的值都不同，认领的范围也不重叠
```

---

### Q7: 如何用 GDB 查看某个卡是否为热卡？

**A**: 完整步骤：

```gdb
# 1. 找到对象地址
(gdb) print obj
$1 = (oop) 0x00007f0000100000

# 2. 获取卡表
set $heap = (G1CollectedHeap*)Universe::_collectedHeap
set $ct = $heap->_card_table

# 3. 计算卡指针
set $card_ptr = &$ct->_byte_map_base[(uintptr_t)0x00007f0000100000 >> 9]
(gdb) print $card_ptr
$2 = (jbyte *) 0x00007f0080002000

# 4. 获取卡计数数组
set $hcc = $heap->_hot_card_cache
set $cc = &$hcc->_card_counts

# 5. 计算卡索引
set $card_num = $card_ptr - $cc->_ct_bot

# 6. 查看计数
(gdb) printf "Card count: %d\n", $cc->_card_counts[$card_num]
Card count: 5

# 7. 判断是否为热卡
(gdb) printf "Is hot: %s\n", ($cc->_card_counts[$card_num] >= 4 ? "Yes" : "No")
Is hot: Yes

# 8. 查看卡状态
(gdb) printf "Card state: 0x%02x\n", *$card_ptr
Card state: 0x00  # dirty_card
```

---

### Q8: 热卡缓存和 DirtyCardQueue 是什么关系？

**A**: 它们是两个独立的机制，协同工作。

```
写屏障触发
    │
    ↓
G1BarrierSet::write_ref_field_post()
    │
    ├─→ 标记卡为 dirty
    │
    └─→ G1HotCardCache::insert(card_ptr)
            │
            ├─→ 返回 NULL：卡在缓存中，无需处理
            ├─→ 返回 card_ptr：立即精炼
            └─→ 返回 evicted_card：精炼被驱逐的卡
                    │
                    ↓
                DirtyCardQueue::enqueue(card_ptr)
                    │
                    ↓
                并发精炼线程处理
```

**对比**：

| 维度 | G1HotCardCache | DirtyCardQueue |
|------|----------------|----------------|
| 目的 | 延迟热卡精炼 | 收集脏卡地址 |
| 大小 | 1024 个槽位 | 每个线程 ~256 个槽位 |
| 判断依据 | 卡修改次数 >= 4 | 所有脏卡 |
| 处理时机 | 缓存满或 GC | 队列满或 GC |
| 优化目标 | 减少重复精炼 | 批量处理 |

**协同关系**：

```
1. 写屏障标记脏卡
2. G1HotCardCache::insert() 判断：
   - 不是热卡 → 返回卡指针 → 入队 DirtyCardQueue
   - 是热卡 → 放入缓存 → 不入队
   - 驱逐旧卡 → 返回旧卡 → 入队 DirtyCardQueue
3. 并发精炼线程从 DirtyCardQueue 取卡精炼
4. GC 时 drain() 处理热卡缓存
```

---

## 总结

**G1HotCardCache 的核心价值**：

1. **减少重复精炼**：热卡延迟处理，避免反复扫描
2. **提升性能**：热点数据写入开销降低 ~100 倍
3. **内存效率**：只需 8KB 缓存 + 16MB 计数数组
4. **并发安全**：CAS + 原子递增保证线程安全

**关键数据**：
- 热卡阈值：G1ConcRSHotCardLimit = 4（默认）
- 缓存大小：_hot_cache_size = 1024（默认）
- 计数数组大小：16MB（8GB heap）
- 并行块大小：ClaimChunkSize = 32

**下一步学习**：
- G1RemSet：如何使用热卡信息更新 RSet
- G1ConcurrentRefine：并发精炼线程的工作机制
- G1UpdateRSOnCardTable：卡表到 RSet 的映射
