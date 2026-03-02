# G1CardTable 逐行源码分析

> **核心目标**：深入理解 G1 卡表的内存布局、状态管理、地址映射算法和 write barrier 流程。

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1CardTable 的本质是**堆内存修改追踪的字节数组**：将整个堆划分为 512 字节的卡（Card），每张卡对应一个字节（`jbyte`）；写屏障将包含被修改引用字段的卡标记为 dirty（`0x00`）；Concurrent Refinement 扫描 dirty 卡，更新目标 Region 的 RSet。

### 0.2 为什么需要？

G1 需要追踪跨 Region 引用（哪些 Region 外的对象引用了 Region 内的对象），但不能在每次引用写入时立即更新 RSet（代价太高）。CardTable 提供了一个轻量的"脏标记"机制：写屏障只需写一个字节（`card_table[addr >> 9] = dirty`），真正的 RSet 更新推迟到后台线程。

### 0.3 卡状态编码

| 值 | 状态 | 含义 |
|----|------|------|
| `0x00` | dirty | 卡内有引用被修改，需要 Refinement 处理 |
| `0x01` | clean | 卡内无修改 |
| `0x02` | claimed | 正在被 Refinement 线程处理 |
| `0x04` | deferred | 延迟处理（并发标记期间） |

### 0.4 为什么这样设计？

- **为什么用字节而不是位（bit）？** 字节写操作是原子的（不需要 CAS），位操作需要 read-modify-write（需要同步）；字节浪费 7 倍空间，但换来了无锁写屏障
- **为什么卡大小是 512 字节？** 512 字节 = 1 字节卡表项，8GB 堆只需 16MB 卡表；粒度太小卡表太大，粒度太大扫描代价高；512 字节是经验最优值

---

## 目录

1. [问题引入：为什么需要卡表？](#1-问题引入为什么需要卡表)
2. [内存布局](#2-内存布局)
3. [核心算法：地址到卡索引映射](#3-核心算法地址到卡索引映射)
4. [卡状态定义](#4-卡状态定义)
5. [初始化流程](#5-初始化流程)
6. [Write Barrier 完整流程](#6-write-barrier-完整流程)
7. [关键场景分析](#7-关键场景分析)
8. [GDB 验证脚本](#8-gdb-验证脚本)
9. [面试级 Q&A](#9-面试级-qa)

---

## 1. 问题引入：为什么需要卡表？

### 问题场景

G1 GC 需要**跨代引用跟踪**：老年代对象引用年轻代对象时，需要在年轻代 GC 时扫描这些引用。

**直接方案的问题**：
- 如果每次 Young GC 都扫描整个老年代 → **性能灾难**
- 如果记录每个对象级别的跨代引用 → **内存开销太大**

**卡表的折中方案**：
- 将堆划分为**固定大小的卡**（Card，512 字节）
- 用一个字节数组记录每个卡的状态
- 粒度适中：既避免了全堆扫描，又不会过度消耗内存

### 核心思想

```
堆内存布局（8GB）：
+------------+------------+------------+------------+-----+
| Card 0     | Card 1     | Card 2     | Card 3     | ... |
| 512 bytes  | 512 bytes  | 512 bytes  | 512 bytes  |     |
+------------+------------+------------+------------+-----+

卡表布局（16MB）：
+----+----+----+----+-----+
| 0  | 1  | 2  | 3  | ... |  每个字节对应堆中 512 字节
+----+----+----+----+-----+
  ↓    ↓    ↓    ↓
状态 状态 状态 状态
```

**关键公式**：
```
卡表大小 = 堆大小 / 512
8GB 堆 → 16MB 卡表
```

---

## 2. 内存布局

### 2.1 继承关系

```
┌─────────────────────────────────────────────────────────────┐
│                     BarrierSet (基类)                        │
│  - _fake_rtti (类型标签)                                     │
│  - _barrier_set_assembler                                    │
│  - _barrier_set_c1/c2                                        │
└──────────────────────────┬──────────────────────────────────┘
                           │ 继承
                           ↓
┌─────────────────────────────────────────────────────────────┐
│                   CardTableBarrierSet                        │
│  - _card_table (G1CardTable*)                                │
└──────────────────────────┬──────────────────────────────────┘
                           │ 继承
                           ↓
┌─────────────────────────────────────────────────────────────┐
│                     G1BarrierSet                             │
│  - _satb_mark_queue_set (静态成员)                           │
│  - _dirty_card_queue_set (静态成员)                          │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 CardTable 字段布局

```cpp
// src/hotspot/share/gc/shared/cardTable.hpp:147-179
class CardTable: public CHeapObj<mtGC> {
  friend class VMStructs;
  
 public:
  // Card sizes
  enum CardValues {                                          // 卡状态枚举
    clean_card                  = -1,                        // 干净卡（0xFF）
    dirty_card                  =  0,                        // 脏卡（0x00）
    CT_MR_BS_last_reserved      =  1                         // 保留值
  };
  
  // 卡大小 = 512 字节 = 2^9
  static const size_t card_size = 512;
  static const size_t card_size_in_words = card_size / sizeof(HeapWord); // 64 words
  static const size_t card_shift = 9;                        // 右移位数
  
 protected:
  bool       _scanned_concurrently;                          // 是否并发扫描
  MemRegion  _whole_heap;                                    // 整个堆的内存区域
  size_t     _guard_index;                                   // 哨兵卡索引
  MemRegion  _guard_region;                                  // 哨兵页区域
  size_t     _last_valid_index;                              // 最后有效卡索引
  size_t     _page_size;                                     // 系统页大小
  size_t     _byte_map_size;                                 // 卡表字节数组大小
  MemRegion* _covered;                                       // 覆盖区域数组
  MemRegion* _committed;                                     // 已提交区域数组
  int        _cur_covered_regions;                           // 当前覆盖区域数量
  
  jbyte*     _byte_map;                                      // 卡表数组指针
  jbyte*     _byte_map_base;                                 // 卡表基地址（优化用）
};
```

**内存布局图**：

```
CardTable 对象布局：
+------------------------+ offset 0
| _scanned_concurrently  | bool (1 字节，对齐后占 8 字节)
+------------------------+ offset 8
| _whole_heap            | MemRegion (16 字节)
|  - _start              |
|  - _word_size          |
+------------------------+ offset 24
| _guard_index           | size_t (8 字节)
+------------------------+ offset 32
| _guard_region          | MemRegion (16 字节)
+------------------------+ offset 48
| _last_valid_index      | size_t (8 字节)
+------------------------+ offset 56
| _page_size             | size_t (8 字节)
+------------------------+ offset 64
| _byte_map_size         | size_t (8 字节)
+------------------------+ offset 72
| _covered               | MemRegion* (8 字节)
+------------------------+ offset 80
| _committed             | MemRegion* (8 字节)
+------------------------+ offset 88
| _cur_covered_regions   | int (4 字节，对齐后 8 字节)
+------------------------+ offset 96
| _byte_map              | jbyte* (8 字节)
+------------------------+ offset 104
| _byte_map_base         | jbyte* (8 字节)
+------------------------+ offset 112
```

### 2.3 G1CardTable 字段布局

```cpp
// src/hotspot/share/gc/g1/g1CardTable.hpp:31-56
class G1CardTable: public CardTable {
 public:
  enum G1CardValues {
    g1_young_gen = CT_MR_BS_last_reserved << 1              // G1 年轻代标记 = 2
  };
  
  static jbyte g1_young_card_val() { return g1_young_gen; }  // 返回年轻代卡值
  static jbyte dirty_card_val() { return dirty_card; }       // 返回脏卡值
  
  // 其他方法...
};
```

**关键**：G1CardTable 只是在 CardTable 基础上增加了一个 `g1_young_gen` 状态，没有额外字段。

---

## 3. 核心算法：地址到卡索引映射

### 3.1 地址到卡索引转换

**关键公式**：
```
卡索引 = 堆地址 >> 9
卡表地址 = _byte_map_base + (uintptr_t(heap_addr) >> 9)
```

### 3.2 byte_for() 实现详解

```cpp
// src/hotspot/share/gc/shared/cardTable.hpp:188-195
jbyte* byte_for(const void* p) const {
  assert(_whole_heap.contains(p),
         "Attempt to access card table for " PTR_FORMAT " outside heap", p2i(p));
  
  // 关键计算：_byte_map_base + (addr >> 9)
  jbyte* result = &_byte_map_base[uintptr_t(p) >> card_shift];
  return result;
}
```

**优化原理**：

传统方法（需要两次计算）：
```cpp
card_index = (addr - heap_start) / 512;    // 计算卡索引
card_addr = _byte_map + card_index;         // 计算卡表地址
```

优化方法（一次计算）：
```cpp
card_addr = _byte_map_base + (addr >> 9);   // 直接得到卡表地址
```

**_byte_map_base 的计算**：
```cpp
// src/hotspot/share/gc/shared/cardTable.cpp:122-123
_byte_map = (jbyte*) heap_rs.base();                        // 卡表数组起始地址
_byte_map_base = _byte_map - (uintptr_t(low_bound) >> card_shift);
```

**示例**：
```
堆起始地址 = 0x00007f0000000000
堆结束地址 = 0x00007f0200000000  (8GB)

卡表起始地址 = 0x00007f0080000000
_byte_map_base = 0x00007f0080000000 - (0x00007f0000000000 >> 9)
               = 0x00007f0080000000 - 0x0000000040000000
               = 0x00007f0040000000

对堆地址 0x00007f0000001000 的计算：
  byte_for(0x00007f0000001000) 
  = &_byte_map_base[0x00007f0000001000 >> 9]
  = &_byte_map_base[0x0000000000002000]
  = 0x00007f0040000000 + 0x2000
  = 0x00007f0040002000
  
验证：
  卡索引 = (0x00007f0000001000 - 0x00007f0000000000) / 512
         = 0x1000 / 512 = 0x2000 = 8192
  卡表地址 = _byte_map + 8192 = 0x00007f0080000000 + 0x2000 = 0x00007f0080002000
  
优化前后的结果相同，但优化方法少了一次减法运算。
```

### 3.3 卡索引到地址转换

```cpp
// src/hotspot/share/gc/shared/cardTable.hpp:197-202
HeapWord* addr_for(const jbyte* card) const {
  // 反向计算：addr = (card - _byte_map_base) << 9
  return (HeapWord*) align_down((uintptr_t)card - (uintptr_t)_byte_map_base, 
                                 card_size);
}
```

---

## 4. 卡状态定义

### 4.1 CardTable 基础状态

```cpp
// src/hotspot/share/gc/shared/cardTable.hpp:152-156
enum CardValues {
  clean_card = -1,      // 0xFF：干净卡，表示该卡中没有被修改的引用
  dirty_card = 0,       // 0x00：脏卡，表示该卡中有被修改的引用，需要处理
  CT_MR_BS_last_reserved = 1  // 保留值，用于扩展
};
```

### 4.2 G1CardTable 扩展状态

```cpp
// src/hotspot/share/gc/g1/g1CardTable.hpp:33-35
enum G1CardValues {
  g1_young_gen = CT_MR_BS_last_reserved << 1  // = 2，表示年轻代区域
};
```

### 4.3 状态语义详解

| 状态值 | 名称 | 含义 | 谁设置 | 谁处理 |
|--------|------|------|--------|--------|
| 0xFF (-1) | clean_card | 干净卡，无跨代引用 | GC 结束时清理 | 不需要处理 |
| 0x00 (0) | dirty_card | 脏卡，有跨代引用 | Write Barrier | RSet 更新线程 |
| 0x02 (2) | g1_young_gen | 年轻代区域 | Young GC 开始 | Young GC 结束清理 |

**状态转换图**：

```
                ┌─────────────┐
                │ clean_card  │ ← GC 结束清理
                │   (0xFF)    │
                └──────┬──────┘
                       │ Write Barrier（老年代对象被修改）
                       ↓
                ┌─────────────┐
                │ dirty_card  │ ──→ 入队 DirtyCardQueue
                │   (0x00)    │
                └──────┬──────┘
                       │ RSet 更新完成
                       ↓
                ┌─────────────┐
                │ clean_card  │
                │   (0xFF)    │
                └─────────────┘

年轻代卡的特殊处理：
                ┌─────────────┐
                │ g1_young    │ ← Young GC 开始时设置
                │   (0x02)    │
                └──────┬──────┘
                       │ Write Barrier 检测到 young_card，跳过处理
                       │
                       ↓ Young GC 结束
                ┌─────────────┐
                │ clean_card  │
                │   (0xFF)    │
                └─────────────┘
```

---

## 5. 初始化流程

### 5.1 CardTable 构造函数

```cpp
// src/hotspot/share/gc/shared/cardTable.cpp:45-77
CardTable::CardTable(MemRegion whole_heap, bool conc_scan) :
  _scanned_concurrently(conc_scan),                         // G1 默认为 true
  _whole_heap(whole_heap),                                 // 保存整个堆的内存区域
  _guard_index(0),                                         // 哨兵卡索引（稍后计算）
  _guard_region(),                                         // 哨兵页区域
  _last_valid_index(0),                                    // 最后有效卡索引
  _page_size(os::vm_page_size()),                          // 系统页大小（通常 4KB）
  _byte_map_size(0),                                       // 卡表大小（稍后计算）
  _covered(NULL),                                          // 覆盖区域数组
  _committed(NULL),                                        // 已提交区域数组
  _cur_covered_regions(0),                                 // 当前覆盖区域数量
  _byte_map(NULL),                                         // 卡表数组指针
  _byte_map_base(NULL)                                     // 卡表基地址
{
  // 堆起始和结束地址必须按卡大小对齐
  assert((uintptr_t(_whole_heap.start()) & (card_size - 1)) == 0, 
         "heap must start at card boundary");
  assert((uintptr_t(_whole_heap.end()) & (card_size - 1)) == 0, 
         "heap must end at card boundary");
  
  // 分配覆盖区域数组
  _covered = new MemRegion[_max_covered_regions];          // _max_covered_regions = 2
  if (_covered == NULL) {
    vm_exit_during_initialization("Could not allocate card table covered region set.");
  }
}
```

### 5.2 CardTable::initialize()

```cpp
// src/hotspot/share/gc/shared/cardTable.cpp:90-138
void CardTable::initialize() {
  // 计算哨兵卡索引和最后有效索引
  _guard_index = cards_required(_whole_heap.word_size()) - 1;
  _last_valid_index = _guard_index - 1;
  
  // 计算卡表大小（按页对齐）
  _byte_map_size = compute_byte_map_size();                // 见下方详解
  
  HeapWord* low_bound = _whole_heap.start();
  HeapWord* high_bound = _whole_heap.end();
  
  _cur_covered_regions = 0;
  
  // 分配已提交区域数组
  _committed = new MemRegion[_max_covered_regions];
  if (_committed == NULL) {
    vm_exit_during_initialization("Could not allocate card table committed region set.");
  }
  
  // 预留卡表内存空间
  const size_t rs_align = _page_size == (size_t)os::vm_page_size() ? 0 :
    MAX2(_page_size, (size_t)os::vm_allocation_granularity());
  ReservedSpace heap_rs(_byte_map_size, rs_align, false);
  
  if (!heap_rs.is_reserved()) {
    vm_exit_during_initialization("Could not reserve enough space for the card marking array");
  }
  
  // 关键：设置 _byte_map 和 _byte_map_base
  _byte_map = (jbyte*) heap_rs.base();
  _byte_map_base = _byte_map - (uintptr_t(low_bound) >> card_shift);
  
  assert(byte_for(low_bound) == &_byte_map[0], "Checking start of map");
  assert(byte_for(high_bound-1) <= &_byte_map[_last_valid_index], "Checking end of map");
  
  // 设置哨兵页
  jbyte* guard_card = &_byte_map[_guard_index];
  HeapWord* guard_page = align_down((HeapWord*)guard_card, _page_size);
  _guard_region = MemRegion(guard_page, _page_size);
  os::commit_memory_or_exit((char*)guard_page, _page_size, _page_size,
                            !ExecMem, "card table last card");
  *guard_card = last_card;                                 // 标记哨兵卡
}
```

### 5.3 compute_byte_map_size() 详解

```cpp
// src/hotspot/share/gc/shared/cardTable.cpp:36-42
size_t CardTable::compute_byte_map_size() {
  assert(_guard_index == cards_required(_whole_heap.word_size()) - 1,
         "uninitialized, check declaration order");
  assert(_page_size != 0, "uninitialized, check declaration order");
  
  const size_t granularity = os::vm_allocation_granularity();  // Linux 通常 4KB
  
  // 按 MAX2(page_size, granularity) 对齐
  return align_up(_guard_index + 1, MAX2(_page_size, granularity));
}
```

**计算示例**（8GB 堆）：
```
堆大小 = 8GB = 8 * 1024 * 1024 * 1024 = 8589934592 字节
堆字数 = 8589934592 / 8 = 1073741824 words
卡数量 = 1073741824 / 64 = 16777216 张卡
_guard_index = 16777216 - 1 = 16777215

_byte_map_size = align_up(16777216, 4096) = 16777216 字节 = 16MB
```

---

## 6. Write Barrier 完整流程

### 6.1 Write Barrier 触发时机

```java
// Java 代码示例
class Example {
  Object field;
  
  void setObject(Object obj) {
    field = obj;  // ← 这里触发 write barrier
  }
}
```

**触发条件**：
- 堆内对象引用字段的写入
- 数组元素的写入
- 不触发：栈变量、静态字段、本地方法中的写入

### 6.2 G1BarrierSet 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    G1BarrierSet                             │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐ │
│  │           SATB Barrier (Pre-Write)                    │ │
│  │  写前屏障：记录被覆盖的旧引用值                         │ │
│  │  write_ref_field_pre() → enqueue() → SATBQueue       │ │
│  └───────────────────────────────────────────────────────┘ │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐ │
│  │           Card Table Barrier (Post-Write)             │ │
│  │  写后屏障：标记脏卡                                    │ │
│  │  write_ref_field_post() → write_ref_field_post_slow()│ │
│  │                          → DirtyCardQueue             │ │
│  └───────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### 6.3 write_ref_field_post() 快速路径

```cpp
// src/hotspot/share/gc/g1/g1BarrierSet.inline.hpp:48-55
template <DecoratorSet decorators, typename T>
inline void G1BarrierSet::write_ref_field_post(T* field, oop new_val) {
  // 步骤1：获取该字段对应的卡表项地址
  volatile jbyte* byte = _card_table->byte_for(field);
  
  // 步骤2：快速检查 - 如果是年轻代卡，直接返回
  // 原因：年轻代 GC 会扫描整个年轻代，不需要记录年轻代内的引用
  if (*byte != G1CardTable::g1_young_card_val()) {
    // 步骤3：如果不是年轻代，走慢路径
    write_ref_field_post_slow(byte);
  }
}
```

**流程图**：

```
write_ref_field_post(field, new_val)
         │
         ↓
   byte_for(field)
         │
         ↓
   *byte == g1_young_card_val() ?
         │
    ┌────┴────┐
    │ Yes     │ No
    ↓         ↓
  返回    write_ref_field_post_slow(byte)
```

### 6.4 write_ref_field_post_slow() 慢路径

```cpp
// src/hotspot/share/gc/g1/g1BarrierSet.cpp:156-171
void G1BarrierSet::write_ref_field_post_slow(volatile jbyte* byte) {
  // 断言：进入慢路径的卡一定不是 young_card
  assert(*byte != G1CardTable::g1_young_card_val(), 
         "slow path invoked without filtering");
  
  // 步骤1：内存屏障（StoreLoad）
  // 确保前面的写入对其他线程可见，再读取卡状态
  OrderAccess::storeload();
  
  // 步骤2：检查是否已经是脏卡
  // 如果已经是脏卡，不需要重复入队
  if (*byte != G1CardTable::dirty_card_val()) {
    // 步骤3：标记为脏卡
    *byte = G1CardTable::dirty_card_val();
    
    // 步骤4：入队到脏卡队列
    Thread* thr = Thread::current();
    if (thr->is_Java_thread()) {
      // Java 线程：入队到线程本地队列
      G1ThreadLocalData::dirty_card_queue(thr).enqueue(byte);
    } else {
      // 非 Java 线程：入队到全局共享队列
      MutexLockerEx x(Shared_DirtyCardQ_lock, Mutex::_no_safepoint_check_flag);
      _dirty_card_queue_set.shared_dirty_card_queue()->enqueue(byte);
    }
  }
}
```

**流程图**：

```
write_ref_field_post_slow(byte)
         │
         ↓
  OrderAccess::storeload()
         │
         ↓
   *byte == dirty_card_val() ?
         │
    ┌────┴────┐
    │ Yes     │ No
    ↓         ↓
  返回    *byte = dirty_card_val()
              │
              ↓
         入队到 DirtyCardQueue
              │
         ┌────┴────┐
         │ Java    │ Non-Java
         ↓         ↓
    线程本地队列  全局共享队列
```

### 6.5 为什么需要 StoreLoad 屏障？

**关键代码**：
```cpp
OrderAccess::storeload();  // 为什么需要这个屏障？
```

**原因**：防止指令重排序导致的问题。

**无屏障的场景**：
```
Thread 1 (应用线程):
  1. obj.field = new_obj;        // 写入新引用
  2. // 没有屏障，可能重排序
  3. if (*byte != dirty_card) {  // 读取卡状态
       *byte = dirty_card;       // 标记脏卡
     }

Thread 2 (RSet 更新线程):
  1. if (*byte == dirty_card) {  // 检查卡状态
  2.   scan(obj.field);          // 扫描字段
     }

问题：Thread 2 可能在 Thread 1 写入新引用之前就读到了 dirty_card，
     然后扫描旧值，漏掉新引用！
```

**有屏障的场景**：
```
Thread 1:
  1. obj.field = new_obj;        // 写入新引用
  2. OrderAccess::storeload();   // 屏障：确保上面的写入完成
  3. if (*byte != dirty_card) {  // 读取卡状态
       *byte = dirty_card;
     }

Thread 2:
  1. if (*byte == dirty_card) {
  2.   scan(obj.field);          // 此时必然能看到新引用
     }
```

---

## 7. 关键场景分析

### 7.1 场景1：年轻代对象引用老年代对象

```java
// young_obj 在年轻代，old_obj 在老年代
young_obj.field = old_obj;
```

**处理流程**：
```
1. write_ref_field_post(young_obj.field, old_obj)
2. byte = byte_for(young_obj.field)  // young_obj 在年轻代
3. *byte == g1_young_card_val()?      // 是
4. 直接返回，不做任何处理
```

**原因**：年轻代 GC 会扫描整个年轻代，年轻代内的引用不需要额外记录。

### 7.2 场景2：老年代对象引用年轻代对象

```java
// old_obj 在老年代，young_obj 在年轻代
old_obj.field = young_obj;
```

**处理流程**：
```
1. write_ref_field_post(old_obj.field, young_obj)
2. byte = byte_for(old_obj.field)  // old_obj 在老年代
3. *byte == g1_young_card_val()?    // 否（老年代卡）
4. write_ref_field_post_slow(byte)
5. *byte = dirty_card_val()
6. enqueue(byte) → DirtyCardQueue
```

**效果**：该卡会被 RSet 更新线程处理，记录跨代引用。

### 7.3 场景3：老年代对象引用老年代对象

```java
// old_obj1 和 old_obj2 都在老年代
old_obj1.field = old_obj2;
```

**处理流程**：
```
1. write_ref_field_post(old_obj1.field, old_obj2)
2. byte = byte_for(old_obj1.field)
3. *byte == g1_young_card_val()?    // 否
4. write_ref_field_post_slow(byte)
5. *byte = dirty_card_val()
6. enqueue(byte) → DirtyCardQueue
```

**原因**：虽然都是老年代，但 G1 是 Region-based GC，可能存在跨 Region 引用，需要记录。

### 7.4 场景4：批量 invalidate()

```cpp
// src/hotspot/share/gc/g1/g1BarrierSet.cpp:173-210
void G1BarrierSet::invalidate(MemRegion mr) {
  if (mr.is_empty()) return;
  
  volatile jbyte* byte = _card_table->byte_for(mr.start());
  jbyte* last_byte = _card_table->byte_for(mr.last());
  Thread* thr = Thread::current();
  
  // 跳过所有连续的 young_card
  for (; byte <= last_byte && *byte == G1CardTable::g1_young_card_val(); byte++);
  
  if (byte <= last_byte) {
    OrderAccess::storeload();
    
    // 批量标记脏卡并入队
    if (thr->is_Java_thread()) {
      for (; byte <= last_byte; byte++) {
        if (*byte == G1CardTable::g1_young_card_val()) continue;
        if (*byte != G1CardTable::dirty_card_val()) {
          *byte = G1CardTable::dirty_card_val();
          G1ThreadLocalData::dirty_card_queue(thr).enqueue(byte);
        }
      }
    } else {
      // 非 Java 线程：需要加锁
      MutexLockerEx x(Shared_DirtyCardQ_lock, Mutex::_no_safepoint_check_flag);
      for (; byte <= last_byte; byte++) {
        if (*byte == G1CardTable::g1_young_card_val()) continue;
        if (*byte != G1CardTable::dirty_card_val()) {
          *byte = G1CardTable::dirty_card_val();
          _dirty_card_queue_set.shared_dirty_card_queue()->enqueue(byte);
        }
      }
    }
  }
}
```

**使用场景**：
- `System.arraycopy()` 批量复制对象引用
- 对象移动（Evacuation）

---

## 8. GDB 验证脚本

### 8.1 验证卡表内存布局

```gdb
# gdb_script: verify_card_table_layout.gdb
# 用法: gdb -x verify_card_table_layout.gdb --args java -Xms8g -Xmx8g -XX:+UseG1GC ...

# 1. 启动程序，在初始化完成后停止
break Threads::create_vm
commands
  continue
end

run

# 2. 查找 G1CollectedHeap 实例
print (G1CollectedHeap*)Universe::_collectedHeap

# 3. 查看卡表信息
set $heap = (G1CollectedHeap*)Universe::_collectedHeap
set $ct = (CardTable*)$heap->_card_table

# 4. 打印卡表关键字段
printf "\n=== CardTable 内存布局 ===\n"
printf "_whole_heap.start:  %p\n", $ct->_whole_heap._start
printf "_whole_heap.end:    %p\n", (HeapWord*)((char*)$ct->_whole_heap._start + $ct->_whole_heap._word_size * 8)
printf "_whole_heap.size:   %lu words = %lu MB\n", $ct->_whole_heap._word_size, $ct->_whole_heap._word_size * 8 / 1024 / 1024
printf "\n"
printf "_byte_map:          %p\n", $ct->_byte_map
printf "_byte_map_base:     %p\n", $ct->_byte_map_base
printf "_byte_map_size:     %lu bytes = %lu MB\n", $ct->_byte_map_size, $ct->_byte_map_size / 1024 / 1024
printf "\n"
printf "_guard_index:       %lu\n", $ct->_guard_index
printf "_last_valid_index:  %lu\n", $ct->_last_valid_index
printf "_page_size:         %lu bytes = %lu KB\n", $ct->_page_size, $ct->_page_size / 1024

# 5. 验证 _byte_map_base 优化
printf "\n=== 验证 _byte_map_base 计算 ===\n"
set $heap_start = (uintptr_t)$ct->_whole_heap._start
set $byte_map_base_calc = (jbyte*)((uintptr_t)$ct->_byte_map - ($heap_start >> 9))
printf "计算值: _byte_map - (heap_start >> 9) = %p\n", $byte_map_base_calc
printf "实际值: _byte_map_base = %p\n", $ct->_byte_map_base
printf "匹配: %s\n", ($byte_map_base_calc == $ct->_byte_map_base ? "是" : "否")

# 6. 测试 byte_for() 函数
printf "\n=== 测试 byte_for() 映射 ===\n"
set $test_addr = $ct->_whole_heap._start
set $card_addr = &$ct->_byte_map_base[(uintptr_t)$test_addr >> 9]
printf "测试地址: %p\n", $test_addr
printf "byte_for(): %p\n", $card_addr
printf "卡索引: %lu\n", (uintptr_t)$test_addr >> 9
printf "卡状态: 0x%02x\n", *$card_addr
```

### 8.2 验证卡状态

```gdb
# gdb_script: verify_card_states.gdb
# 在 Young GC 前后观察卡状态变化

# 1. 在 Young GC 开始处设置断点
break G1CollectedHeap::gc_prologue
commands
  printf "\n=== Young GC Prologue ===\n"
  set $heap = (G1CollectedHeap*)Universe::_collectedHeap
  set $ct = (G1CardTable*)$heap->_card_table
  
  # 找一个年轻代 Region
  set $young_region = (HeapRegion*)$heap->_young_list->first()
  printf "年轻代 Region: %p\n", $young_region
  printf "Region 起始: %p\n", $young_region->_bottom
  printf "Region 结束: %p\n", $young_region->_top
  
  # 查看该 Region 的卡状态
  set $young_card = $ct->byte_for($young_region->_bottom)
  printf "卡地址: %p\n", $young_card
  printf "卡状态: 0x%02x (期望: 0x02 = young_card)\n", *$young_card
  
  continue
end

# 2. 在 write barrier 处设置断点
break G1BarrierSet::write_ref_field_post_slow
commands
  printf "\n=== Write Barrier Slow Path ===\n"
  printf "卡地址: %p\n", $rdi
  printf "卡状态(前): 0x%02x\n", *(jbyte*)$rdi
  
  # 单步执行，观察卡状态变化
  next
  printf "卡状态(后): 0x%02x\n", *(jbyte*)$rdi
  
  continue
end

run
```

### 8.3 观察 DirtyCardQueue 入队

```gdb
# gdb_script: observe_dirty_card_queue.gdb

# 在脏卡入队处设置断点
break DirtyCardQueue::enqueue
commands
  printf "\n=== 脏卡入队 ===\n"
  
  # 获取线程本地队列
  set $thr = (Thread*)$rdi
  set $queue = (PtrQueue*)$thr
  
  printf "线程: %p\n", $thr
  printf "队列索引: %d\n", $queue->_index
  printf "队列容量: %d\n", $queue->_buf_size
  printf "剩余空间: %d\n", $queue->_index
  
  continue
end

run
```

### 8.4 统计卡状态分布

```gdb
# gdb_script: count_card_states.gdb

define count_cards
  set $ct = (CardTable*)$arg0
  set $start = $ct->_byte_map
  set $end = $start + $ct->_byte_map_size
  
  set $clean_count = 0
  set $dirty_count = 0
  set $young_count = 0
  set $other_count = 0
  
  set $p = $start
  while $p < $end
    set $val = *$p
    if $val == 0xff
      set $clean_count = $clean_count + 1
    else
      if $val == 0x00
        set $dirty_count = $dirty_count + 1
      else
        if $val == 0x02
          set $young_count = $young_count + 1
        else
          set $other_count = $other_count + 1
        end
      end
    end
    set $p = $p + 1
  end
  
  printf "\n=== 卡状态统计 ===\n"
  printf "Clean 卡 (0xFF):  %d = %.2f%%\n", $clean_count, (float)$clean_count * 100 / $ct->_byte_map_size
  printf "Dirty 卡 (0x00):  %d = %.2f%%\n", $dirty_count, (float)$dirty_count * 100 / $ct->_byte_map_size
  printf "Young 卡 (0x02):  %d = %.2f%%\n", $young_count, (float)$young_count * 100 / $ct->_byte_map_size
  printf "其他状态:         %d = %.2f%%\n", $other_count, (float)$other_count * 100 / $ct->_byte_map_size
  printf "总计:             %d\n", $ct->_byte_map_size
end

# 在程序运行一段时间后手动调用
# (gdb) count_cards ((G1CollectedHeap*)Universe::_collectedHeap)->_card_table
```

---

## 9. 面试级 Q&A

### Q1: 为什么卡表大小是 512 字节？为什么不是 256 或 1024？

**A**: 512 字节是权衡的结果：

**太小的问题（如 64 字节）**：
```
卡表大小 = 8GB / 64 = 128MB
内存开销太大
```

**太大的问题（如 4KB）**：
```
卡表大小 = 8GB / 4KB = 2MB
但每张卡覆盖的区域太大，精确度低
如果 4KB 中只有一个跨代引用，整个 4KB 都要被扫描
```

**512 字节的优势**：
```
卡表大小 = 8GB / 512 = 16MB（可接受）
精确度：512 字节约包含 64 个对象引用
缓存友好：512 字节正好是 L1 缓存行大小的整数倍
```

---

### Q2: _byte_map_base 优化的原理是什么？为什么能加速？

**A**: 传统方法需要两次运算：

```cpp
// 传统方法
card_index = (addr - heap_start) >> 9;    // 减法 + 移位
card_addr = _byte_map + card_index;        // 加法
```

优化方法：

```cpp
// 优化方法
card_addr = _byte_map_base + (addr >> 9);  // 只需移位 + 加法

// _byte_map_base 的推导
// card_addr = _byte_map + ((addr - heap_start) >> 9)
//           = _byte_map + (addr >> 9) - (heap_start >> 9)
// 令 _byte_map_base = _byte_map - (heap_start >> 9)
// 则 card_addr = _byte_map_base + (addr >> 9)
```

**性能提升**：
- 少一次减法运算
- 在 x86 上，移位和加法可以在一个时钟周期内完成

---

### Q3: 为什么 write_ref_field_post_slow() 中需要 StoreLoad 屏障？

**A**: 防止指令重排序导致的数据不一致。

**问题场景**：
```
Thread 1 (应用线程):
  obj.field = new_value;    // (1) 写入新引用
  // 如果没有屏障，(1) 和 (3) 可能重排序
  if (*byte != dirty) {     // (3) 读取卡状态
    *byte = dirty;          // (4) 标记脏卡
  }

Thread 2 (RSet 更新线程):
  if (*byte == dirty) {     // (2) 读取卡状态
    scan(obj.field);        // (5) 扫描字段
  }

可能的执行顺序：1 → 3 → 4 → 2 → 5
但如果没有屏障，可能：3 → 4 → 1 → 2 → 5
Thread 2 在 (5) 时可能看到旧的 obj.field 值！
```

**StoreLoad 屏障的作用**：
```
obj.field = new_value;
OrderAccess::storeload();   // 确保 (1) 在 (3) 之前完成
if (*byte != dirty) {
  *byte = dirty;
}
```

---

### Q4: G1 为什么需要 g1_young_card_val() 状态？不直接用 dirty_card 可以吗？

**A**: g1_young_card_val() 是性能优化，避免不必要的脏卡入队。

**如果只用 dirty_card**：
```
年轻代对象 A 引用老年代对象 B:
1. A.field = B;
2. write_ref_field_post() 发现 *byte = clean_card
3. 标记为 dirty_card
4. 入队到 DirtyCardQueue
5. RSet 更新线程处理这个脏卡
6. 但这是年轻代内的引用，Young GC 会全扫描，不需要记录！
```

**使用 g1_young_card_val()**：
```
Young GC 开始时，将年轻代 Region 的所有卡标记为 g1_young_card_val()

年轻代对象 A 引用老年代对象 B:
1. A.field = B;
2. write_ref_field_post() 发现 *byte = g1_young_card_val()
3. 直接返回，不做任何处理
4. 避免了无用的脏卡入队和 RSet 更新
```

---

### Q5: 为什么 CardTable 需要 guard page（哨兵页）？

**A**: 防止数组越界访问，用于调试和验证。

**原理**：
```cpp
_guard_index = cards_required(_whole_heap.word_size()) - 1;
_guard_region = MemRegion(guard_page, _page_size);
*guard_card = last_card;  // 标记为特殊值
```

**作用**：
```
如果代码错误地访问了 _byte_map[_last_valid_index + 1]：
1. 实际访问的是 guard_card
2. guard_card 的值是 last_card (特殊值)
3. 代码可以检测到这个非法访问
4. 如果没有 guard page，可能访问到未映射内存 → SIGSEGV
```

**位置**：
```
_byte_map[0]               _byte_map[_last_valid_index]    _byte_map[_guard_index]
   ↓                              ↓                                ↓
+---+---+---+---+---------+-------+-------+---------+---------------+
| 0 | 1 | 2 | 3 |  ...    | last  |guard  | 未使用   | 其他内存      |
+---+---+---+---+---------+-------+-------+---------+---------------+
   ↑                              ↑          ↑
有效卡                          有效卡     哨兵卡
```

---

### Q6: 卡表是在堆内还是堆外内存？

**A**: 卡表在**堆外内存**（Off-Heap）。

**代码证据**：
```cpp
// src/hotspot/share/gc/shared/cardTable.cpp:107-108
ReservedSpace heap_rs(_byte_map_size, rs_align, false);
MemTracker::record_virtual_memory_type((address)heap_rs.base(), mtGC);
```

**原因**：
1. **避免循环依赖**：如果卡表在堆内，GC 需要管理卡表内存，但卡表又是 GC 的基础设施
2. **稳定性**：堆外内存不受 GC 影响，更稳定
3. **性能**：堆外内存不会被移动，地址固定，适合频繁访问

**内存布局**：
```
进程地址空间：
+------------------------+ 高地址
|    栈                  |
+------------------------+
|    ...                 |
+------------------------+
|    卡表 (16MB)         | ← 堆外内存
+------------------------+
|    堆 (8GB)            | ← 堆内存
+------------------------+ 低地址
```

---

### Q7: 如何用 GDB 查看一个对象对应的卡状态？

**A**: 完整步骤如下：

```gdb
# 1. 找到对象地址
(gdb) print obj
$1 = (oop) 0x00007f0000100000

# 2. 获取卡表
(gdb) set $heap = (G1CollectedHeap*)Universe::_collectedHeap
(gdb) set $ct = (G1CardTable*)$heap->_card_table

# 3. 计算卡地址
(gdb) set $obj_addr = (uintptr_t)0x00007f0000100000
(gdb) set $card_addr = &$ct->_byte_map_base[$obj_addr >> 9]
(gdb) print $card_addr
$2 = (jbyte *) 0x00007f0080002000

# 4. 查看卡状态
(gdb) printf "Card state: 0x%02x\n", *$card_addr
Card state: 0xff  # clean_card

# 5. 查看卡对应的堆区域
(gdb) set $card_start = (HeapWord*)(($card_addr - $ct->_byte_map_base) << 9)
(gdb) print $card_start
$3 = (HeapWord *) 0x00007f0000100000

# 6. 查看卡覆盖的范围
(gdb) printf "Card covers: [%p, %p)\n", $card_start, (HeapWord*)((char*)$card_start + 512)
Card covers: [0x00007f0000100000, 0x00007f0000100200)
```

---

### Q8: 如何理解 "卡表是跨代引用的粗粒度记录"？

**A**: 通过对比理解：

**对象级记录（精确）**：
```
对象 A → 对象 B
对象 C → 对象 D
...

记录每个跨代引用：
优点：精确，只扫描必要的对象
缺点：内存开销大，维护成本高
```

**卡级记录（粗粒度）**：
```
Card 0 → 包含对象 A, B, C
Card 1 → 包含对象 D, E, F
...

记录：Card 0 有跨代引用（不记录具体哪个对象）

优点：内存开销小（1 字节 per 512 字节）
缺点：可能扫描不必要的对象（Card 0 中只有 A 有跨代引用，但 B, C 也要扫描）
```

**G1 的选择**：
```
卡表 + RSet 结合：
- 卡表：粗粒度记录哪些区域可能有跨代引用
- RSet：精确定位到具体的 Region

例如：
老年代 Region R1 的 RSet 记录：
  "Region R2 的 Card 123, 456 有指向 R1 的引用"

Young GC 时：
1. 扫描 RSet，找到所有指向年轻代的卡
2. 只扫描这些卡中的对象
3. 避免全堆扫描
```

---

### Q9: 为什么卡表用 jbyte（有符号字节）而不是 uint8_t？

**A**: 历史原因 + 兼容性。

**状态值设计**：
```cpp
clean_card = -1;   // 0xFF (有符号) 或 255 (无符号)
dirty_card = 0;    // 0x00
```

**使用 jbyte 的好处**：
```cpp
// 检查是否为脏卡
if (*byte == dirty_card) {  // dirty_card = 0
  // 无论 signed/unsigned，0 都是一样的
}

// 检查是否为干净卡
if (*byte == clean_card) {  // clean_card = -1 或 0xFF
  // signed: -1
  // unsigned: 255
  // 都可以工作
}
```

**如果用 uint8_t**：
```cpp
enum CardValues {
  clean_card = 255,  // 0xFF
  dirty_card = 0
};

// 需要显式转换
if ((uint8_t)*byte == clean_card) {
  // ...
}
```

**HotSpot 的惯例**：`jbyte` 是 JVM 中标准的字节类型，统一使用避免混淆。

---

### Q10: 如何验证卡表的性能影响？

**A**: 通过 JVM 参数和工具：

**1. 启用卡表相关日志**：
```bash
-XX:+PrintGCDetails
-Xlog:gc+barrier=trace

# 输出示例
[gc,barrier] CardTable::CardTable: 
[gc,barrier]     &_byte_map[0]: 0x00007f0080000000  &_byte_map[_last_valid_index]: 0x00007f0081000000
[gc,barrier]     _byte_map_base: 0x00007f0040000000
```

**2. 使用 Perf 观察卡表访问**：
```bash
perf stat -e cache-references,cache-misses java -Xms8g -Xmx8g -XX:+UseG1GC MyApp

# 卡表访问模式：
# - 顺序访问（批量扫描）
# - 随机访问（write barrier）
# - 缓存命中率影响性能
```

**3. 使用 JFR 记录 write barrier 开销**：
```bash
jfr start -d 60s -n barrier_profile settings=profile

# 分析：
# - G1BarrierSet::write_ref_field_post 调用次数
# - write_ref_field_post_slow 调用比例
# - DirtyCardQueue 入队次数
```

**4. 优化建议**：
```
如果 write_ref_field_post_slow 比例过高：
  → 减少引用写入频率
  → 使用 -XX:G1UpdateBufferSize 调整缓冲区大小

如果脏卡处理慢：
  → 使用 -XX:G1ConcRefinementThreads 增加细化线程数
  → 使用 -XX:G1RSetScanBlockSize 调整扫描块大小
```

---

## 总结

**G1CardTable 的核心价值**：

1. **空间效率**：16MB 卡表记录 8GB 堆的跨代引用信息
2. **时间效率**：`_byte_map_base` 优化使地址转换只需一次加法
3. **并发安全**：StoreLoad 屏障保证 write barrier 的正确性
4. **G1 特化**：`g1_young_card_val()` 避免年轻代的不必要处理

**关键数据**：
- 卡大小：512 字节
- 卡状态：clean (0xFF), dirty (0x00), young (0x02)
- 卡表大小：堆大小 / 512
- _byte_map_base 优化：减少一次减法运算

**下一步学习**：
- G1HotCardCache：热点卡缓存优化
- G1RSet：记忆集如何使用卡表信息
- G1ConcurrentRefine：脏卡处理的并发细化线程
