# G1BlockOffsetTable 逐行源码分析

> **核心目标**：深入理解 G1 块偏移表的对数跳跃算法、快速对象定位机制和内存布局。

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1BlockOffsetTable（BOT）的本质是**堆地址→对象起始地址的快速查找索引**：将堆划分为 512 字节的块（Block），每个块对应一个字节的 BOT 条目；给定堆内任意地址，通过 BOT 可以 O(log n) 地找到包含该地址的对象的起始地址，无需从 Region 头部线性扫描。

### 0.2 为什么需要？

GC 扫描 Region 时，需要从任意地址找到对象的起始地址（对象头）。如果从 Region 头部线性扫描（遍历所有对象直到找到包含目标地址的对象），代价 O(n)，对大 Region 不可接受。BOT 提供 O(log n) 的快速定位。

### 0.3 怎么解决？

**对数跳跃算法**：BOT 条目存储"当前块的对象起始地址距当前块起始地址的偏移"；如果对象跨多个块，后续块的 BOT 条目存储"需要向前跳多少块才能找到对象起始地址"（对数编码：1→1块，2→2块，3→4块，4→8块...）；查找时从目标地址对应的块开始，按对数跳跃向前，直到找到对象起始地址。

### 0.4 为什么这样设计？

- **为什么用对数跳跃而不是直接存储对象起始地址？** 直接存储需要 4-8 字节/块（指针大小），512 字节块的 BOT 需要 1/64 的额外内存；对数编码只需 1 字节/块，内存开销降低 4-8 倍
- **为什么块大小是 512 字节？** 与 CardTable 的卡大小一致（512 字节），两个数据结构共享相同的地址→索引映射，简化实现

---

## 目录

1. [问题引入：为什么需要块偏移表？](#1-问题引入为什么需要块偏移表)
2. [整体架构](#2-整体架构)
3. [核心常量与算法](#3-核心常量与算法)
4. [内存布局](#4-内存布局)
5. [对象定位算法详解](#5-对象定位算法详解)
6. [块分配与更新机制](#6-块分配与更新机制)
7. [关键场景分析](#7-关键场景分析)
8. [GDB 验证脚本](#8-gdb-验证脚本)
9. [面试级 Q&A](#9-面试级-qa)

---

## 1. 问题引入：为什么需要块偏移表？

### 问题场景

**对象定位问题**：给定堆中任意地址，找到包含该地址的对象起始位置。

```java
// 示例场景
Object obj = new Object();  // 对象起始地址：0x1000
// 内部字段地址：0x1010

// GC 需要解决的问题：
// 给定地址 0x1010，如何快速找到对象起始地址 0x1000？
```

**传统方案的问题**：

```
方案1：从堆起始地址遍历
  for (addr = heap_start; addr < target; ) {
    Object obj = (Object)addr;
    addr += obj.size();
  }
  问题：O(n) 时间复杂度，大对象性能灾难

方案2：维护完整映射表
  map[target_addr] = obj_start_addr
  问题：内存开销太大（每8字节一个映射）
```

**G1 的折中方案**：

```
块偏移表（BlockOffsetTable）：
- 将堆划分为固定大小的块（512字节）
- 每个块记录：相对前一个块起始位置的偏移
- 平衡查询效率和内存开销

查询复杂度：O(log n)（对数跳跃）
内存开销：每512字节堆占用1字节（0.2%）
```

---

## 2. 整体架构

### 2.1 类关系图

```
┌─────────────────────────────────────────────────────────────┐
│                  BOTConstants (常量定义)                     │
│  - LogN = 9                                                 │
│  - N_bytes = 512                                            │
│  - N_words = 64                                             │
│  - LogBase = 4, Base = 16                                   │
│  - N_powers = 14                                            │
└─────────────────────────────────────────────────────────────┘
                           ↑
                           │ 使用
                           │
┌─────────────────────────────────────────────────────────────┐
│                 G1BlockOffsetTable                          │
│                                                             │
│  - _reserved: MemRegion                                     │
│  - _offset_array: volatile u_char*                          │
│                                                             │
│  + index_for(addr): size_t                                  │
│  + address_for_index(idx): HeapWord*                        │
└──────────────────────────┬──────────────────────────────────┘
                           │ 组合
                           ↓
┌─────────────────────────────────────────────────────────────┐
│              G1BlockOffsetTablePart                         │
│                                                             │
│  - _bot: G1BlockOffsetTable*                                │
│  - _space: G1ContiguousSpace*                               │
│  - _next_offset_threshold: HeapWord*                        │
│  - _next_offset_index: size_t                               │
│                                                             │
│  + block_start(addr): HeapWord*                             │
│  + alloc_block(start, end): void                            │
│  + reset_bot(): void                                        │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 工作原理

```
堆内存布局：
+----------+----------+----------+----------+----------+
| Block 0  | Block 1  | Block 2  | Block 3  | Block 4  |
| 512B     | 512B     | 512B     | 512B     | 512B     |
+----------+----------+----------+----------+----------+
     ↓          ↓          ↓          ↓          ↓

BOT 数组：
+---+---+---+---+---+
| 0 | 1 | 64| 2 | 0 |  每个字节记录偏移信息
+---+---+---+---+---+

示例：
对象A 起始：Block 0 偏移0
对象B 起始：Block 2 偏移64（跨块对象）
对象C 起始：Block 4 偏移0

查询地址 0x900（Block 2）：
  BOT[2] = 64 → 回退64个字 → 找到对象B起始地址
```

---

## 3. 核心常量与算法

### 3.1 BOTConstants 定义

```cpp
// src/hotspot/share/gc/shared/blockOffsetTable.hpp:50-76
class BOTConstants : public AllStatic {
public:
  // 每个BOT条目覆盖的堆大小：512字节
  static const uint LogN = 9;                    // log2(512) = 9
  static const uint LogN_words = LogN - LogHeapWordSize;  // 9 - 3 = 6
  static const uint N_bytes = 1 << LogN;         // 512 bytes
  static const uint N_words = 1 << LogN_words;   // 64 words (8 bytes/word)
  
  // 对数跳跃参数
  static const uint LogBase = 4;                 // 对数基数 = 4
  static const uint Base = (1 << LogBase);       // 16
  static const uint N_powers = 14;               // 对数区域数量
  
  // 计算回退卡数
  static size_t power_to_cards_back(uint i) {
    return (size_t)1 << (LogBase * i);          // 16^i
  }
  
  static size_t power_to_words_back(uint i) {
    return power_to_cards_back(i) * N_words;    // 转换为字数
  }
  
  // 从BOT条目转换为回退卡数
  static size_t entry_to_cards_back(u_char entry) {
    assert(entry >= N_words, "Precondition");
    return power_to_cards_back(entry - N_words);
  }
  
  static size_t entry_to_words_back(u_char entry) {
    assert(entry >= N_words, "Precondition");
    return power_to_words_back(entry - N_words);
  }
};
```

### 3.2 对数跳跃算法

**问题**：如何处理大对象（跨越多个块）？

**对数跳跃的思路**：

```
假设对象跨越 1000 个块：
- 线性回退：需要查询 1000 次
- 对数跳跃：只需查询 ~4 次

对数跳跃表：
+-----+-------+------------------+
| i   | 回退卡数 | 回退字数          |
+-----+-------+------------------+
| 0   | 1     | 64 words         |
| 1   | 16    | 1024 words       |
| 2   | 256   | 16384 words      |
| 3   | 4096  | 262144 words     |
| ... | ...   | ...              |
+-----+-------+------------------+

BOT 条目值映射：
  entry < N_words (64)：直接偏移（字数）
  entry >= N_words：对数跳跃模式
    entry = N_words + i
    回退卡数 = 16^i

示例：
  entry = 64 → 回退 1 卡
  entry = 65 → 回退 16 卡
  entry = 66 → 回退 256 卡
  entry = 67 → 回退 4096 卡
```

### 3.3 完整算法示例

```
查询地址 addr = 0x2000（第4个块，索引3）

步骤1：读取 BOT[3] = 67

步骤2：entry >= N_words (64)，对数跳跃模式
  i = 67 - 64 = 3
  回退卡数 = 16^3 = 4096 卡

步骤3：回退 4096 卡
  new_index = 3 - 4096 = -4093（超出范围，说明对象起始在堆开始）

步骤4：从堆开始线性遍历找到对象起始

优化：如果对象很大，BOT 会记录对数跳跃，大幅减少查询次数
```

---

## 4. 内存布局

### 4.1 G1BlockOffsetTable 字段布局

```cpp
// src/hotspot/share/gc/g1/g1BlockOffsetTable.hpp:45-107
class G1BlockOffsetTable: public CHeapObj<mtGC> {
  friend class G1BlockOffsetTablePart;
  friend class VMStructs;

private:
  MemRegion _reserved;                // 覆盖的堆内存区域
  volatile u_char* _offset_array;     // BOT 数组
};
```

**内存布局图**：

```
G1BlockOffsetTable 对象：
+------------------------+ offset 0
| _reserved              | MemRegion (16 bytes)
|  - _start              |
|  - _word_size          |
+------------------------+ offset 16
| _offset_array          | u_char* (8 bytes)
+------------------------+ offset 24
```

### 4.2 BOT 数组布局

```cpp
// src/hotspot/share/gc/g1/g1BlockOffsetTable.cpp:41-51
G1BlockOffsetTable::G1BlockOffsetTable(MemRegion heap, G1RegionToSpaceMapper* storage) :
  _reserved(heap), _offset_array(NULL) {
  MemRegion bot_reserved = storage->reserved();
  _offset_array = (u_char*)bot_reserved.start();
}
```

**数组大小计算**：

```cpp
// src/hotspot/share/gc/g1/g1BlockOffsetTable.hpp:82-85
static size_t compute_size(size_t mem_region_words) {
  size_t number_of_slots = (mem_region_words / BOTConstants::N_words);
  return ReservedSpace::allocation_align_size_up(number_of_slots);
}
```

**计算示例（8GB 堆）**：

```
堆大小 = 8GB = 8 * 1024 * 1024 * 1024 = 8589934592 字节
堆字数 = 8589934592 / 8 = 1073741824 words

BOT 条目数 = 1073741824 / 64 = 16777216 条目
BOT 大小 = 16777216 字节 = 16MB

内存占用：16MB / 8GB = 0.195% （约 0.2%）
```

**内存映射**：

```
堆内存：
+----------+----------+----------+----------+-----+
| Block 0  | Block 1  | Block 2  | Block 3  | ... |
| 512 bytes| 512 bytes| 512 bytes| 512 bytes|     |
+----------+----------+----------+----------+-----+
     ↓          ↓          ↓          ↓
BOT 数组：
+---+---+---+---+-----+
| 0 | 1 | 2 | 3 | ... |
+---+---+---+---+-----+

每个 BOT 条目（1字节）对应堆中 512 字节
```

### 4.3 G1BlockOffsetTablePart 字段布局

```cpp
// src/hotspot/share/gc/g1/g1BlockOffsetTable.hpp:109-125
class G1BlockOffsetTablePart {
  friend class G1BlockOffsetTable;
  friend class VMStructs;
private:
  HeapWord* _next_offset_threshold;   // 下一个需要更新的阈值
  size_t    _next_offset_index;       // 对应的索引
  
  debug_only(bool _object_can_span;)  // 调试标记
  
  G1BlockOffsetTable* _bot;           // 指向全局 BOT
  G1ContiguousSpace* _space;          // 所属的空间（HeapRegion）
};
```

**内存布局图**：

```
G1BlockOffsetTablePart 对象：
+---------------------------+ offset 0
| _next_offset_threshold    | HeapWord* (8 bytes)
+---------------------------+ offset 8
| _next_offset_index        | size_t (8 bytes)
+---------------------------+ offset 16
| _object_can_span          | bool (1 byte, padding to 8)
+---------------------------+ offset 24
| _bot                      | G1BlockOffsetTable* (8 bytes)
+---------------------------+ offset 32
| _space                    | G1ContiguousSpace* (8 bytes)
+---------------------------+ offset 40
```

---

## 5. 对象定位算法详解

### 5.1 block_start_const() 主流程

```cpp
// src/hotspot/share/gc/g1/g1BlockOffsetTable.inline.hpp
inline HeapWord* G1BlockOffsetTablePart::block_start_const(const void* addr) const {
  // 步骤1：找到地址对应的 BOT 索引
  size_t index = _bot->index_for(addr);
  
  // 步骤2：读取 BOT 条目
  HeapWord* q = _bot->address_for_index(index);
  u_char entry = _bot->offset_array(index);
  
  // 步骤3：根据条目值处理
  if (entry < BOTConstants::N_words) {
    // 情况1：直接偏移
    HeapWord* block_start = q - entry;
    return block_start;
  } else {
    // 情况2：对数跳跃
    HeapWord* n = q + BOTConstants::N_words;
    return forward_to_block_containing_addr_const(q, n, addr);
  }
}
```

### 5.2 forward_to_block_containing_addr_const() 详解

```cpp
// src/hotspot/share/gc/g1/g1BlockOffsetTable.hpp:155-156
inline HeapWord* G1BlockOffsetTablePart::forward_to_block_containing_addr_const(
    HeapWord* q, HeapWord* n, const void* addr) const {
  
  // q: 当前块起始地址
  // n: 下一个块起始地址
  // addr: 目标地址
  
  // 步骤1：检查是否在当前块
  if (addr < n) {
    // 在当前块内，返回块起始
    return q;
  }
  
  // 步骤2：处理对数跳跃
  size_t index = _bot->index_for(n);
  u_char entry = _bot->offset_array(index);
  
  // 步骤3：计算回退距离
  size_t backskip = BOTConstants::entry_to_cards_back(entry);
  size_t landing_index = index - backskip;
  
  // 步骤4：递归查找
  HeapWord* landing = _bot->address_for_index(landing_index);
  HeapWord* next_boundary = _bot->address_for_index(index) + BOTConstants::N_words;
  
  return forward_to_block_containing_addr_const(landing, next_boundary, addr);
}
```

### 5.3 完整示例

```
场景：对象 A 跨越多个块

堆布局：
+----------+----------+----------+----------+----------+
| Block 0  | Block 1  | Block 2  | Block 3  | Block 4  |
+----------+----------+----------+----------+----------+
  对象A起始  |-------- 对象A跨越 -------------------|
  
BOT 数组：
+---+---+---+---+---+
| 0 | 67| 66| 65| 64|
+---+---+---+---+---+

查询 addr 在 Block 3：

第1次调用：
  index = 3
  entry = BOT[3] = 65
  entry >= 64，对数跳跃
  i = 65 - 64 = 1
  backskip = 16^1 = 16 卡
  
  landing_index = 3 - 16 = -13（超出范围）
  
  回退到堆起始，线性遍历找到对象A起始

优化版（对象跨越不超过 backskip）：
  假设对象A 跨越 Block 0-4
  BOT[4] = 64 → 回退 1 卡 → Block 3
  BOT[3] = 64 → 回退 1 卡 → Block 2
  BOT[2] = 64 → 回退 1 卡 → Block 1
  BOT[1] = 64 → 回退 1 卡 → Block 0
  BOT[0] = 0 → 找到对象起始

查询次数：5 次（远少于线性遍历）
```

---

## 6. 块分配与更新机制

### 6.1 alloc_block() 流程

```cpp
// src/hotspot/share/gc/g1/g1BlockOffsetTable.hpp:217-224
void alloc_block(HeapWord* blk_start, HeapWord* blk_end) {
  if (blk_end > _next_offset_threshold) {
    alloc_block_work(&_next_offset_threshold, &_next_offset_index, blk_start, blk_end);
  }
}
```

### 6.2 alloc_block_work() 详解

```cpp
// src/hotspot/share/gc/g1/g1BlockOffsetTable.cpp:252-326
void G1BlockOffsetTablePart::alloc_block_work(HeapWord** threshold_, size_t* index_,
                                               HeapWord* blk_start, HeapWord* blk_end) {
  HeapWord* threshold = *threshold_;
  size_t    index = *index_;
  
  // 步骤1：设置当前块的偏移值
  _bot->set_offset_array(index, threshold, blk_start);
  
  // 步骤2：计算块结束索引
  size_t end_index = _bot->index_for(blk_end - 1);
  
  // 步骤3：设置跨越块的 BOT 条目
  if (index + 1 <= end_index) {
    HeapWord* rem_st  = _bot->address_for_index(index + 1);
    HeapWord* rem_end = _bot->address_for_index(end_index) + BOTConstants::N_words;
    set_remainder_to_point_to_start(rem_st, rem_end);
  }
  
  // 步骤4：更新阈值和索引
  index = end_index + 1;
  threshold = _bot->address_for_index(end_index) + BOTConstants::N_words;
  
  *threshold_ = threshold;
  *index_ = index;
}
```

### 6.3 set_remainder_to_point_to_start() 详解

```cpp
// src/hotspot/share/gc/g1/g1BlockOffsetTable.cpp:140-165
void G1BlockOffsetTablePart::set_remainder_to_point_to_start_incl(size_t start_card, size_t end_card) {
  if (start_card > end_card) {
    return;
  }
  
  size_t start_card_for_region = start_card;
  u_char offset = max_jubyte;
  
  // 对数跳跃设置
  for (uint i = 0; i < BOTConstants::N_powers; i++) {
    // 计算对数跳跃的覆盖范围
    size_t reach = start_card - 1 + (BOTConstants::power_to_cards_back(i+1) - 1);
    offset = BOTConstants::N_words + i;
    
    if (reach >= end_card) {
      _bot->set_offset_array(start_card_for_region, end_card, offset);
      start_card_for_region = reach + 1;
      break;
    }
    
    _bot->set_offset_array(start_card_for_region, reach, offset);
    start_card_for_region = reach + 1;
  }
}
```

**设置示例**：

```
对象跨越 Block 10 到 Block 50（共 40 个块）

设置对数跳跃：
  Block 10: offset = 0（对象起始）
  Block 11-26: offset = 65（回退 16 卡）
  Block 27-42: offset = 66（回退 256 卡）
  Block 43-50: offset = 67（回退 4096 卡）

查询 Block 50：
  entry = 67 → 回退 4096 卡 → Block 50 - 4096 = -4046
  超出范围，回退到堆起始

优化：对数跳跃减少 BOT 更新开销
  不需要为每个块单独设置偏移
  对数跳跃自动处理跨越多个块的对象
```

---

## 7. 关键场景分析

### 7.1 场景1：小对象（单块内）

```
对象大小：256 字节（小于 512 字节，单块内）

分配：
  blk_start = 0x1000
  blk_end = 0x1100
  
BOT 更新：
  index = index_for(0x1000) = 2
  BOT[2] = 0（块起始偏移为 0）

查询地址 0x1050：
  index = index_for(0x1050) = 2
  entry = BOT[2] = 0
  q = address_for_index(2) = 0x1000
  block_start = q - 0 = 0x1000 ✓

查询次数：1 次
```

### 7.2 场景2：中等对象（跨少量块）

```
对象大小：1024 字节（跨越 2 个块）

分配：
  blk_start = 0x1000
  blk_end = 0x1400
  
BOT 更新：
  index = index_for(0x1000) = 2
  BOT[2] = 0（对象起始）
  
  end_index = index_for(0x1400 - 1) = 3
  set_remainder_to_point_to_start(Block 3, Block 3)
    BOT[3] = N_words + 0 = 64（回退 1 卡）

查询地址 0x1300（Block 3）：
  index = 3
  entry = BOT[3] = 64
  entry >= 64，对数跳跃
  i = 64 - 64 = 0
  backskip = 16^0 = 1 卡
  
  landing_index = 3 - 1 = 2
  landing = address_for_index(2) = 0x1000
  next_boundary = 0x1200
  
  递归调用：addr 0x1300 >= next_boundary 0x1200
    index = index_for(0x1200) = 2
    entry = BOT[2] = 0
    q = 0x1000
    n = 0x1200
    
    addr 0x1300 >= n 0x1200，继续
    
    但 Block 2 已经处理过，返回 q = 0x1000

查询次数：2 次
```

### 7.3 场景3：大对象（跨多个块）

```
对象大小：10 KB（跨越 20 个块）

分配：
  blk_start = 0x1000
  blk_end = 0x3A00
  
BOT 更新：
  index = index_for(0x1000) = 2
  BOT[2] = 0
  
  end_index = index_for(0x3A00 - 1) = 21
  set_remainder_to_point_to_start(Block 3, Block 21)
    Block 3-18: offset = 65（回退 16 卡）
    Block 19-21: offset = 66（回退 256 卡）

查询地址 0x3000（Block 20）：
  index = 20
  entry = BOT[20] = 66
  i = 66 - 64 = 2
  backskip = 16^2 = 256 卡
  
  landing_index = 20 - 256 = -236
  超出范围，回退到堆起始
  
  从堆起始线性遍历找到对象起始 0x1000

查询次数：1 次对数跳跃 + 线性遍历
```

---

## 8. GDB 验证脚本

### 8.1 验证 BOT 内存布局

```gdb
# gdb_script: verify_bot_layout.gdb
# 用法: gdb -x verify_bot_layout.gdb --args java -Xms8g -Xmx8g -XX:+UseG1GC ...

break Threads::create_vm
commands
  continue
end

run

# 查找 G1BlockOffsetTable
set $heap = (G1CollectedHeap*)Universe::_collectedHeap
set $bot = $heap->_bot

printf "\n=== G1BlockOffsetTable 布局 ===\n"
printf "_reserved.start:   %p\n", $bot->_reserved._start
printf "_reserved.end:     %p\n", (HeapWord*)((char*)$bot->_reserved._start + $bot->_reserved._word_size * 8)
printf "_reserved.size:    %lu words = %lu MB\n", $bot->_reserved._word_size, $bot->_reserved._word_size * 8 / 1024 / 1024
printf "_offset_array:     %p\n", $bot->_offset_array

# 计算 BOT 大小
set $bot_size = $bot->_reserved._word_size / 64
printf "BOT 条目数:        %lu\n", $bot_size
printf "BOT 大小:          %lu bytes = %lu MB\n", $bot_size, $bot_size / 1024 / 1024

# 验证常量
printf "\n=== BOTConstants ===\n"
printf "LogN:              %d\n", 9
printf "N_bytes:           %d bytes = %d KB\n", 512, 512
printf "N_words:           %d words\n", 64
printf "LogBase:           %d\n", 4
printf "Base:              %d\n", 16
printf "N_powers:          %d\n", 14
```

### 8.2 观察 block_start 查询

```gdb
# gdb_script: observe_block_start.gdb

break G1BlockOffsetTablePart::block_start_const
commands
  printf "\n=== block_start_const() 被调用 ===\n"
  printf "查询地址: %p\n", $rdi
  
  # 单步执行
  next
  
  # 查看结果
  printf "对象起始: %p\n", $rax
  
  continue
end

run
```

### 8.3 观察 BOT 更新

```gdb
# gdb_script: observe_bot_update.gdb

break G1BlockOffsetTablePart::alloc_block_work
commands
  printf "\n=== alloc_block_work() 被调用 ===\n"
  printf "blk_start: %p\n", $rsi
  printf "blk_end:   %p\n", $rdx
  
  # 计算块数
  set $size = $rdx - $rsi
  printf "对象大小:  %lu bytes\n", $size
  printf "跨越块数:  %lu\n", $size / 512 + ($size % 512 ? 1 : 0)
  
  continue
end

run
```

### 8.4 统计 BOT 条目分布

```gdb
# gdb_script: count_bot_entries.gdb

define count_bot_entries
  set $heap = (G1CollectedHeap*)Universe::_collectedHeap
  set $bot = $heap->_bot
  
  set $direct_count = 0
  set $log_count = 0
  set $zero_count = 0
  
  set $i = 0
  set $total = $bot->_reserved._word_size / 64
  
  while $i < $total
    set $entry = $bot->_offset_array[$i]
    
    if $entry == 0
      set $zero_count = $zero_count + 1
    else
      if $entry < 64
        set $direct_count = $direct_count + 1
      else
        set $log_count = $log_count + 1
      end
    end
    
    set $i = $i + 1
  end
  
  printf "\n=== BOT 条目统计 ===\n"
  printf "零偏移:          %lu = %.2f%%\n", $zero_count, (float)$zero_count * 100 / $total
  printf "直接偏移 (<64):  %lu = %.2f%%\n", $direct_count, (float)$direct_count * 100 / $total
  printf "对数跳跃 (>=64): %lu = %.2f%%\n", $log_count, (float)$log_count * 100 / $total
  printf "总计:            %lu\n", $total
end

# 在程序运行一段时间后调用
# (gdb) count_bot_entries
```

---

## 9. 面试级 Q&A

### Q1: 为什么 BOT 每个条目覆盖 512 字节？

**A**: 权衡查询效率和内存开销。

**如果太小（如 64 字节）**：
```
BOT 大小 = 8GB / 64 = 128MB
内存开销太大
```

**如果太大（如 4KB）**：
```
BOT 大小 = 8GB / 4KB = 2MB
但每个块内对象定位效率降低
如果一个 4KB 块内有多个对象，仍需线性遍历
```

**512 字节的优势**：
```
BOT 大小 = 8GB / 512 = 16MB（可接受）
块内对象数：平均 2-8 个对象（小对象）
线性遍历块内对象效率高
平衡点：既能减少内存开销，又能保证查询效率
```

---

### Q2: 对数跳跃算法为什么用 16 作为基数？

**A**: 平衡跳跃距离和条目数量。

**基数 16 的跳跃表**：

```
i = 0: 回退 1 卡 = 512 字节
i = 1: 回退 16 卡 = 8 KB
i = 2: 回退 256 卡 = 128 KB
i = 3: 回退 4096 卡 = 2 MB
i = 4: 回退 65536 卡 = 32 MB
...

N_powers = 14，最大回退：
  16^14 卡 ≈ 268 TB（远超堆大小）
```

**如果基数太大（如 64）**：
```
i = 1: 回退 64 卡 = 32 KB（太大，浪费）
```

**如果基数太小（如 2）**：
```
i = 1: 回退 2 卡 = 1 KB（太小，效率低）
需要更多次跳跃才能到达目标
```

**基数 16 的优势**：
```
- 小对象（<512B）：1 次查询
- 中等对象（<8KB）：2 次查询
- 大对象（<128KB）：3 次查询
- 超大对象（<2MB）：4 次查询

大多数对象只需 1-2 次查询
```

---

### Q3: BOT 和卡表有什么区别？

**A**: 两者目的不同，互补使用。

| 维度 | BlockOffsetTable (BOT) | CardTable |
|------|------------------------|-----------|
| 目的 | 定位对象起始地址 | 追踪堆内存修改 |
| 粒度 | 512 字节/条目 | 512 字节/条目 |
| 大小 | 16MB (8GB heap) | 16MB (8GB heap) |
| 更新时机 | 对象分配/移动 | 写屏障 |
| 查询操作 | `block_start(addr)` | `byte_for(addr)` |
| 典型场景 | GC 扫描、对象遍历 | 跨代引用跟踪 |

**协作场景**：

```
GC 扫描脏卡：
1. 从 DirtyCardQueue 取出脏卡地址
2. card_start = address_for_index(card_index)
3. obj_start = bot->block_start(card_start)  // BOT 定位对象
4. 扫描对象引用字段
```

---

### Q4: _next_offset_threshold 的作用是什么？

**A**: 优化 BOT 更新，避免频繁操作。

**原理**：

```
对象分配时：
  if (blk_end > _next_offset_threshold) {
    // 更新 BOT
    alloc_block_work(...);
  } else {
    // 跳过更新（块内对象，BOT 已正确）
  }

示例：
  Block 2 已有对象A（0x1000-0x1100）
  _next_offset_threshold = 0x1200（Block 3 起始）
  
  分配对象B（0x1100-0x1180）：
    blk_end = 0x1180 < _next_offset_threshold
    跳过 BOT 更新（对象在块内，BOT 已指向对象A）
    
  分配对象C（0x1180-0x1300）：
    blk_end = 0x1300 > _next_offset_threshold
    更新 BOT（对象跨越块边界）
```

**优化效果**：

```
无优化：每次分配都更新 BOT
有优化：只有跨越块边界才更新
减少 ~80% 的 BOT 更新操作
```

---

### Q5: 如何用 GDB 查找给定地址的对象起始？

**A**: 完整步骤：

```gdb
# 1. 找到目标地址
(gdb) print target_addr
$1 = (void*) 0x00007f0000101234

# 2. 获取 G1BlockOffsetTable
set $heap = (G1CollectedHeap*)Universe::_collectedHeap
set $bot = $heap->_bot

# 3. 计算 BOT 索引
set $addr = (uintptr_t)0x00007f0000101234
set $heap_start = (uintptr_t)$bot->_reserved._start
set $offset = $addr - $heap_start
set $index = $offset / 512

(gdb) printf "BOT index: %lu\n", $index
BOT index: 5678

# 4. 读取 BOT 条目
set $entry = $bot->_offset_array[$index]
(gdb) printf "BOT entry: %d\n", $entry
BOT entry: 65

# 5. 判断条目类型
if $entry < 64
  # 直接偏移
  set $block_addr = $heap_start + $index * 512
  set $obj_start = $block_addr - $entry * 8
  (gdb) printf "Object start: %p\n", $obj_start
else
  # 对数跳跃（需要递归或调用 block_start_const）
  (gdb) call $heap->_bot->block_start_const((void*)0x00007f0000101234)
end
```

---

### Q6: reset_bot() 什么时候调用？

**A**: Region 被重新使用时。

**调用场景**：

```cpp
// src/hotspot/share/gc/g1/g1BlockOffsetTable.hpp:204-207
void reset_bot() {
  zero_bottom_entry_raw();        // BOT[bottom_index] = 0
  initialize_threshold_raw();     // 重置阈值
}
```

**时机**：

```
1. Region 从空闲状态转为活跃状态
2. Region 从 Survivor 转为 Eden 或 Old
3. Region 被回收后重新分配

示例流程：
  Region R1 原本是 Eden，包含对象A、B、C
  Young GC 后，R1 被回收（对象全部移走）
  R1 被重新用作 Survivor 或 Old
  调用 reset_bot() 清空 BOT
  BOT 恢复到初始状态
```

**为什么不直接清零整个 BOT？**：

```
原因：
  1. 性能：清零 16MB 内存开销大
  2. 不必要：下次分配时会覆盖
  
reset_bot() 只重置关键信息：
  - BOT[bottom_index] = 0
  - _next_offset_threshold 指向下一个块边界
  
后续分配会逐步覆盖其他条目
```

---

### Q7: G1BlockOffsetTablePart 为什么独立于 G1BlockOffsetTable？

**A**: 每个 HeapRegion 一个 Part，实现细粒度管理。

**架构**：

```
G1BlockOffsetTable（全局唯一）
  - 管理整个堆的 BOT 数组
  - 提供地址↔索引转换
  
G1BlockOffsetTablePart（每个 Region 一个）
  - 管理 Region 内的 BOT 子区域
  - 维护分配阈值（_next_offset_threshold）
  - 提供对象定位接口

为什么分开？
  1. Region 独立性：每个 Region 有自己的分配状态
  2. 并发安全：不同 Region 的 BOT 更新不冲突
  3. 内存效率：只管理当前 Region 的 BOT 子区域
```

**示例**：

```
Region R0（0x0000 - 0x400000）：
  Part0._next_offset_threshold = 0x1000
  Part0._next_offset_index = 2

Region R1（0x400000 - 0x800000）：
  Part1._next_offset_threshold = 0x401000
  Part1._next_offset_index = 2050

两个 Region 的 BOT 更新互不干扰
```

---

## 总结

**G1BlockOffsetTable 的核心价值**：

1. **快速对象定位**：O(log n) 复杂度，优于线性遍历
2. **内存效率**：0.2% 内存开销（16MB for 8GB heap）
3. **对数跳跃算法**：减少大对象查询次数
4. **细粒度管理**：每个 Region 独立管理 BOT Part

**关键数据**：
- 块大小：512 字节
- BOT 大小：16MB（8GB heap）
- 对数基数：16
- 对数区域：14 个

**下一步学习**：
- G1RootProcessor：GC Roots 扫描如何使用 BOT
- G1RemSet：记忆集如何与 BOT 协作
- HeapRegion：Region 的 BOT 初始化与重置
