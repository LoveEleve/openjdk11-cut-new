# G1CardTable 专家级源码分析

## 一、一句话总结

**G1CardTable 是 G1 的"内存修改追踪器"，它通过一个字节数组将堆内存划分为 512 字节的卡片，标记哪些区域发生了跨代引用修改，是 Remembered Set (RSet) 的基础数据结构，也是写屏障实现的核心组件。**

---

## 二、设计哲学：为什么需要卡表？

### 2.1 问题背景

在分代/分区 GC 中，需要快速找到**跨代引用**（老年代 → 年轻代）：

```
场景：Young GC 时需要找到所有引用年轻代对象的老年代对象
问题：
  - 遍历整个老年代？太慢（可能几十 GB）
  - 为每个对象维护引用列表？内存开销大
  
需要：一种空间换时间的快速查找机制
```

### 2.2 解决方案

**卡表 (Card Table)**：

```
┌─────────────────────────────────────────────────────────────────┐
│                        堆内存 (8GB)                              │
│  ├─────────┬─────────┬─────────┬─────────┬─────────┬─────────┤ │
│  │ Region 0│ Region 1│ Region 2│   ...   │Region2046│Region2047│ │
│  │  (4MB)  │  (4MB)  │  (4MB)  │         │  (4MB)   │  (4MB)   │ │
│  └─────────┴─────────┴─────────┴─────────┴─────────┴─────────┘ │
│       │         │         │                                    │
│       ▼         ▼         ▼                                    │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    卡表 (16MB)                            │  │
│  │  [card0][card1][card2] ... [card16777215]                 │  │
│  │    │      │      │                                        │  │
│  │    └──────┴──────┘                                        │  │
│  │       每卡 512 字节                                        │  │
│  │       每卡 1 字节状态                                      │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘

映射关系：
  堆地址 0x0000_0000 ~ 0x0000_0200 (512B) ──> 卡表[0]
  堆地址 0x0000_0200 ~ 0x0000_0400 (512B) ──> 卡表[1]
  ...
  卡表索引 = (堆地址 - 堆起始) / 512
```

---

## 三、整体架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                    CardTable (基类，通用实现)                         │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  核心字段：                                                   │  │
│  │  • _byte_map - 卡表字节数组指针                               │  │
│  │  • _byte_map_size - 卡表大小                                  │  │
│  │  • _byte_map_base - 快速计算基址                              │  │
│  │  • card_size = 512 字节                                       │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                              ▲                                      │
│                              │ 继承                                 │
│                    ┌─────────┴─────────┐                           │
│                    ▼                   ▼                           │
│  ┌────────────────────────┐  ┌────────────────────────┐            │
│  │    G1CardTable         │  │   其他 GC 的卡表        │            │
│  │  (G1 特有实现)          │  │  (如 CMSCardTable)      │            │
│  └────────────────────────┘  └────────────────────────┘            │
│                                                                     │
│  G1 特有功能：                                                       │
│  • g1_young_gen - 年轻代特殊标记                                     │
│  • mark_card_deferred - 延迟标记                                     │
│  • set_card_claimed - 认领标记                                       │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 四、核心数据结构详解

### 4.1 CardTable (基类)

```cpp
class CardTable: public CHeapObj<mtGC> {
protected:
  // 卡表字节数组
  jbyte* _byte_map;           // 卡表起始地址
  size_t _byte_map_size;      // 卡表总大小（字节）
  
  // 快速计算优化
  jbyte* _byte_map_base;      // 基址 = _byte_map - (heap_start >> 9)
  
  // 堆信息
  MemRegion _whole_heap;      // 整个堆的内存区域
  size_t _guard_index;        // 守护索引（越界保护）
  size_t _last_valid_index;   // 最后一个有效索引
  
  // 覆盖区域管理
  MemRegion* _covered;        // 被覆盖的堆区域数组
  MemRegion* _committed;      // 已提交的卡表内存
  int _cur_covered_regions;   // 当前覆盖区域数

public:
  // 核心常量
  static const int card_size = 512;                    // 每张卡覆盖的堆大小
  static const int card_size_in_words = 512 / sizeof(HeapWord);  // 64 words
  static const int card_shift = 9;                     // log2(512) = 9
  
  // 卡状态值
  static jbyte dirty_card_val()       { return -1; }    // 0xFF 脏卡
  static jbyte clean_card_val()       { return 0; }     // 0x00 干净
  static jbyte claimed_card_val()     { return 1; }     // 0x01 已认领
  static jbyte deferred_card_val()    { return 2; }     // 0x02 延迟
  static jbyte clean_card_mask_val()  { return 3; }     // 0x03 掩码
};
```

### 4.2 G1CardTable (G1 特化)

```cpp
class G1CardTable: public CardTable {
  G1CardTableChangedListener _listener;   // Region commit 监听器
  
  enum G1CardValues {
    g1_young_gen = CT_MR_BS_last_reserved << 1  // 年轻代特殊值 = 8
  };

public:
  G1CardTable(MemRegion whole_heap): CardTable(whole_heap, true) {
    _listener.set_card_table(this);
  }
  
  // G1 特有方法
  static jbyte g1_young_card_val() { return g1_young_gen; }
  void g1_mark_as_young(const MemRegion& mr);  // 标记年轻代区域
  
  // 卡片状态检查
  bool is_card_dirty(size_t card_index);
  bool is_card_claimed(size_t card_index);
  bool is_card_deferred(size_t card_index);
  
  // 卡片状态修改
  inline void set_card_claimed(size_t card_index);
  bool mark_card_deferred(size_t card_index);  // CAS 延迟标记
  
  // 初始化
  void initialize(G1RegionToSpaceMapper* mapper);
  
  // 年轻代检查
  virtual bool is_in_young(oop obj) const;
};
```

**内存布局：**
```
G1CardTable (继承 CardTable)
偏移      字段名                 大小      说明
────────────────────────────────────────────────────
0x000    CardTable 基类字段      ~72B     见上
0x048    _listener               16B      监听器
────────────────────────────────────────────────────
总大小：约 88 bytes
```

---

## 五、核心算法详解

### 5.1 地址映射算法

**问题**：给定堆地址，如何快速找到对应的卡表项？

**传统方法**：
```cpp
jbyte* byte_for(HeapWord* heap_addr) {
  size_t offset = (uintptr_t)heap_addr - (uintptr_t)_whole_heap.start();
  size_t card_index = offset >> card_shift;  // 除以 512
  return &_byte_map[card_index];
}
```

**优化方法（G1 使用）**：
```cpp
// 初始化时计算基址
_byte_map_base = _byte_map - (uintptr_t(low_bound) >> card_shift);

// 运行时快速计算
jbyte* byte_for(HeapWord* heap_addr) {
  return &_byte_map_base[(uintptr_t)heap_addr >> card_shift];
}
```

**优化原理**：
```
传统：&_byte_map[(addr - base) >> 9]
     = _byte_map + (addr - base) / 512
     = _byte_map + addr/512 - base/512  ← 两次运算

优化：&_byte_map_base[addr >> 9]
     = (_byte_map - base/512) + addr/512
     = _byte_map + addr/512 - base/512  ← 编译期合并 base/512

结果：运行时只需一次移位和一次加法！
```

### 5.2 卡表大小计算

```cpp
// 对于 8GB 堆（标准条件）
static size_t compute_size(size_t mem_region_size_in_words) {
  // 8GB = 1G words (假设 8 字节/字)
  // 卡片数 = 1G words / 64 words per card = 16M cards
  size_t number_of_slots = mem_region_size_in_words / card_size_in_words;
  
  // 对齐到页大小（通常 4KB）
  return ReservedSpace::allocation_align_size_up(number_of_slots);
  // 16M × 1B = 16MB
}
```

**标准配置计算**：
```
堆大小：8GB
字大小：8 bytes
堆字数：8GB / 8B = 1G words
卡片大小：512 bytes = 64 words
卡片数量：1G / 64 = 16M (16,777,216)
卡表大小：16M × 1 byte = 16MB
```

### 5.3 mark_card_deferred - 延迟标记

```cpp
bool G1CardTable::mark_card_deferred(size_t card_index) {
  jbyte val = _byte_map[card_index];
  
  // 已经是延迟状态，直接返回
  if ((val & (clean_card_mask_val() | deferred_card_val())) == deferred_card_val()) {
    return false;  // 已经标记过，无需重复入队
  }
  
  // 计算新值
  jbyte new_val = val;
  if (val == clean_card_val()) {
    new_val = deferred_card_val();           // clean -> deferred
  } else if (val & claimed_card_val()) {
    new_val = val | deferred_card_val();     // claimed -> claimed+deferred
  }
  
  // CAS 更新（无锁）
  if (new_val != val) {
    Atomic::cmpxchg(new_val, &_byte_map[card_index], val);
  }
  return true;  // 标记成功，需要入队
}
```

**用途**：去重优化，避免同一卡片重复进入 DirtyCardQueue。

**状态转换图**：
```
          write barrier
   clean ─────────────────> dirty
     │                        │
     │ mark_card_deferred     │
     ▼                        │
  deferred <──────────────────┘
     │      处理完成
     ▼
   clean (或 young)
```

### 5.4 g1_mark_as_young - 标记年轻代

```cpp
void G1CardTable::g1_mark_as_young(const MemRegion& mr) {
  jbyte* first = byte_for(mr.start());   // 起始卡
  jbyte* last = byte_after(mr.last());   // 结束卡
  
  // 并发安全的 memset
  memset_with_concurrent_readers(first, g1_young_gen, last - first);
}
```

**用途**：标记年轻代 Region 的所有卡片为特殊值 `g1_young_gen`，这样：
1. 写屏障发现是年轻代来源，不记录 RSet
2. is_in_young() 快速检查对象是否在年轻代

---

## 六、卡状态值详解

| 值 | 名称 | 含义 | 使用场景 |
|----|------|------|---------|
| 0xFF (-1) | dirty | 脏卡，需要处理 | 写屏障设置 |
| 0x00 (0) | clean | 干净，无需处理 | 初始状态/处理完成 |
| 0x01 (1) | claimed | 已认领，正在处理 | 并发处理时标记 |
| 0x02 (2) | deferred | 延迟，已入队 | mark_card_deferred |
| 0x08 (8) | young | 年轻代 | G1 特有，年轻代区域 |

**状态组合**：
```
claimed | deferred = 0x03  (同时被认领和延迟)
```

---

## 七、GDB 验证

### 7.1 GDB 脚本

```gdb
# jvm-md/tmp-file/g1cardtable/gdb_g1cardtable.txt

set pagination off
set print pretty on

# 在 G1CardTable::initialize 设置断点
break G1CardTable::initialize

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

printf "\n========== G1CardTable 基本信息 ==========\n"
set $ct = G1CollectedHeap::heap()->_card_table
printf "_byte_map: %p\n", $ct->_byte_map
printf "_byte_map_size: %zu (%.2f MB)\n", $ct->_byte_map_size, $ct->_byte_map_size / (1024.0*1024.0)
printf "_byte_map_base: %p\n", $ct->_byte_map_base
printf "_guard_index: %zu\n", $ct->_guard_index
printf "_last_valid_index: %zu\n", $ct->_last_valid_index

printf "\n========== 卡状态常量 ==========\n"
printf "card_size: %d bytes\n", CardTable::card_size
printf "card_shift: %d\n", CardTable::card_shift
printf "dirty_card_val: %d (0x%02x)\n", CardTable::dirty_card_val(), CardTable::dirty_card_val()
printf "clean_card_val: %d (0x%02x)\n", CardTable::clean_card_val(), CardTable::clean_card_val()
printf "g1_young_card_val: %d (0x%02x)\n", G1CardTable::g1_young_card_val(), G1CardTable::g1_young_card_val()

printf "\n========== 地址映射验证 ==========\n"
set $heap_start = $ct->_whole_heap.start()
set $test_addr = $heap_start + 1024
set $card_ptr = $ct->byte_for($test_addr)
set $card_idx = (uintptr_t)$card_ptr - (uintptr_t)$ct->_byte_map
printf "Heap start: %p\n", $heap_start
printf "Test addr: %p (offset 1KB)\n", $test_addr
printf "Card pointer: %p\n", $card_ptr
printf "Card index: %zu (expected: 2)\n", $card_idx

continue
```

### 7.2 预期输出示例

```
========== G1CardTable 基本信息 ==========
_byte_map: 0x7f1234000000
_byte_map_size: 16777216 (16.00 MB)
_byte_map_base: 0x7f11b4000000
_guard_index: 16777216
_last_valid_index: 16777215

========== 卡状态常量 ==========
card_size: 512 bytes
card_shift: 9
dirty_card_val: -1 (0xff)
clean_card_val: 0 (0x00)
g1_young_card_val: 8 (0x08)

========== 地址映射验证 ==========
Heap start: 0x7f0000000000
Test addr: 0x7f0000000400
Card pointer: 0x7f1234000002
Card index: 2 (expected: 2)
```

---

## 八、关键设计决策

### 8.1 为什么是 512 字节一张卡？

| 卡片大小 | 优点 | 缺点 |
|---------|------|------|
| 256B | 精度高，扫描范围小 | 卡表内存大（32MB for 8GB） |
| 512B | 平衡 | 平衡 |
| 1KB | 卡表内存小（8MB） | 精度低，扫描范围大 |
| 4KB | 卡表内存很小 | 精度太低，大量无效扫描 |

**选择 512B**：经验证的平衡点，卡表内存占用 0.2%（16MB/8GB）。

### 8.2 为什么是 1 字节而不是 1 位？

| 方案 | 优点 | 缺点 |
|------|------|------|
| 1 字节 | 可表示多种状态，CAS 操作简单 | 内存占用 8 倍于位图 |
| 1 位 | 内存占用小 | 无法表示多状态，需要额外数据结构 |

**选择 1 字节**：需要表示 dirty/clean/claimed/deferred/young 多种状态。

### 8.3 为什么需要 _byte_map_base 优化？

**背景**：`byte_for()` 是写屏障热路径，需要极致性能。

**传统方法**：
```cpp
// 3 次运算：减法、移位、加法
return _byte_map + ((addr - heap_start) >> 9);
```

**优化方法**：
```cpp
// 2 次运算：移位、加法（base/heap_start 已预计算）
return _byte_map_base + (addr >> 9);
```

**收益**：减少约 30% 的计算时间（对于 write barrier 意义重大）。

---

## 九、面试问答

### Q1: G1CardTable 的作用是什么？

**答案要点**：
1. 将堆内存划分为 512 字节的卡片
2. 标记哪些区域发生了跨代引用修改
3. 是 RSet 的基础数据结构
4. 支持 write barrier 快速判断和标记

### Q2: 卡表大小如何计算？

**答案要点**：
1. 卡表大小 = 堆大小 / 512
2. 8GB 堆 = 16MB 卡表
3. 内存占用约 0.2%

### Q3: mark_card_deferred 的作用？

**答案要点**：
1. 去重优化，避免同一卡片重复入队
2. CAS 无锁更新
3. 状态从 clean -> deferred 或 claimed -> claimed+deferred

### Q4: _byte_map_base 的优化原理？

**答案要点**：
1. 预计算 `_byte_map - heap_start/512`
2. 运行时只需移位和加法，省去减法
3. 写屏障热路径性能优化

---

## 十、总结

**G1CardTable 是 G1 的"内存雷达"，通过 512 字节粒度的卡片追踪堆内存修改，实现跨代引用的快速定位。**

| 核心机制 | 说明 |
|---------|------|
| 512B 卡片 | 平衡的精度和内存占用 |
| 多状态值 | dirty/clean/claimed/deferred/young |
| _byte_map_base | 写屏障热路径优化 |
| mark_card_deferred | 去重减少队列压力 |

**一句话记忆**：G1CardTable 就像是堆内存的"航海图"，把大海（堆）划分成小格子（卡片），标记哪些格子有宝藏（跨代引用），让 GC 能快速找到目标。

---

*文档生成时间: 2026-02-11*  
*源码版本: OpenJDK 11*  
*分析文件: g1CardTable.hpp/cpp*
