# C.3 - initialize_alignments() 对齐参数初始化

> **前置条件**：-Xms8G -Xmx8G，G1 GC，非大页，非 NUMA
> **前置知识**：C.1.1 Region 大小（GrainBytes=4MB）

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文分析 **C.3 - initialize_alignments() 对齐参数初始化** 的初始化过程：JVM 启动时该组件如何被创建、配置和激活，以及初始化顺序的约束关系。

### 0.2 为什么需要？

JVM 初始化顺序有严格的依赖关系——某些组件必须在其他组件之前初始化。理解初始化顺序有助于排查启动失败问题，也能理解各组件的设计约束。

### 0.3 怎么解决？

追踪初始化函数的调用链，分析每个初始化步骤的前置条件和后置效果，识别关键的初始化顺序约束。

### 0.4 为什么这样设计？

初始化顺序的设计原则：「被依赖的先初始化」。例如内存管理必须在 GC 之前初始化，GC 必须在类加载之前初始化。

---


## 1. 概述

`initialize_alignments()` 设置两个关键的对齐参数：
- **_space_alignment**：Region 内部空间对齐（4MB）
- **_heap_alignment**：整个堆的对齐（取多个约束的最大值）

对齐的目的：
1. **性能优化**：对齐的内存访问更高效
2. **位运算优化**：地址计算可用移位代替除法
3. **操作系统约束**：内存映射需要页对齐

---

## 2. 源码分析

### 2.1 initialize_alignments()

```cpp
// g1CollectorPolicy.cpp:52-57
void G1CollectorPolicy::initialize_alignments() {
  // ===== 空间对齐 = Region 大小 =====
  _space_alignment = HeapRegion::GrainBytes;  // 4MB
  
  // ===== 卡表对齐约束 =====
  size_t card_table_alignment = CardTableRS::ct_max_alignment_constraint();
  // = card_size * vm_page_size = 512 * 4096 = 2MB
  
  // ===== 页面大小 =====
  size_t page_size = UseLargePages ? os::large_page_size() : os::vm_page_size();
  // 非大页：4KB
  // 大页：2MB（典型值）
  
  // ===== 堆对齐 = 三者最大值 =====
  _heap_alignment = MAX3(card_table_alignment, _space_alignment, page_size);
  // 非大页：MAX(2MB, 4MB, 4KB) = 4MB
}
```

### 2.2 ct_max_alignment_constraint()

```cpp
// cardTable.cpp:473-475
uintx CardTable::ct_max_alignment_constraint() {
  return card_size * os::vm_page_size();
  // = 512 * 4096 = 2,097,152 = 2MB
}
```

**为什么是 card_size × page_size？**

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 卡表对齐约束推导                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│ 卡表（Card Table）是一个字节数组，存储在 C Heap 中：                          │
│                                                                             │
│   card_table_size = heap_size / card_size                                  │
│                   = heap_size / 512                                        │
│                                                                             │
│ 卡表内存向 OS 申请，需要按页对齐：                                            │
│                                                                             │
│   card_table_size = N × page_size      （N 为整数）                         │
│                                                                             │
│ 因此：                                                                       │
│   heap_size / 512 = N × 4096                                               │
│   heap_size = N × 512 × 4096                                               │
│   heap_size = N × 2MB                                                      │
│                                                                             │
│ 结论：堆大小必须是 2MB 的整数倍                                              │
│       card_table_alignment = 512 × 4096 = 2MB                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 计算过程图解（8GB 堆，非大页）

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 输入参数                                                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│ HeapRegion::GrainBytes = 4,194,304 (4MB)                                   │
│ card_size = 512 bytes                                                       │
│ os::vm_page_size() = 4,096 (4KB)                                           │
│ UseLargePages = false                                                       │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 计算各约束                                                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│ _space_alignment = GrainBytes                                              │
│                  = 4,194,304 (4MB)                                         │
│                                                                             │
│ card_table_alignment = card_size × page_size                               │
│                      = 512 × 4,096                                         │
│                      = 2,097,152 (2MB)                                     │
│                                                                             │
│ page_size = os::vm_page_size()                                             │
│           = 4,096 (4KB)                                                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 计算 _heap_alignment                                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│ _heap_alignment = MAX3(card_table_alignment, _space_alignment, page_size)  │
│                 = MAX3(2MB, 4MB, 4KB)                                      │
│                 = 4MB                                                       │
│                                                                             │
│ 结果：                                                                       │
│   _space_alignment = 4MB                                                   │
│   _heap_alignment  = 4MB                                                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. 不同场景对比

### 4.1 标准场景（非大页）

| 参数 | 值 | 说明 |
|------|-----|------|
| GrainBytes | 4MB | Region 大小 |
| card_size | 512B | 卡大小 |
| page_size | 4KB | 普通页 |
| card_table_alignment | 2MB | 512 × 4K |
| **_space_alignment** | **4MB** | = GrainBytes |
| **_heap_alignment** | **4MB** | MAX(2M, 4M, 4K) |

### 4.2 大页场景（-XX:+UseLargePages）

| 参数 | 值 | 说明 |
|------|-----|------|
| GrainBytes | 4MB | Region 大小 |
| card_size | 512B | 卡大小 |
| large_page_size | 2MB | Linux HugePage |
| card_table_alignment | 2MB | 512 × 4K |
| **_space_alignment** | **4MB** | = GrainBytes |
| **_heap_alignment** | **4MB** | MAX(2M, 4M, 2M) |

### 4.3 小堆场景（1GB 堆）

| 参数 | 值 | 说明 |
|------|-----|------|
| GrainBytes | 1MB | Region 大小 |
| card_size | 512B | 卡大小 |
| page_size | 4KB | 普通页 |
| card_table_alignment | 2MB | 512 × 4K |
| **_space_alignment** | **1MB** | = GrainBytes |
| **_heap_alignment** | **2MB** | MAX(2M, 1M, 4K) |

---

## 5. 对齐的用途

### 5.1 堆大小对齐

```cpp
// collectorPolicy.cpp:105-107
// 用户输入的堆大小必须对齐
_min_heap_byte_size = align_up(_min_heap_byte_size, _heap_alignment);
size_t aligned_initial_heap_size = align_up(InitialHeapSize, _heap_alignment);
size_t aligned_max_heap_size = align_up(MaxHeapSize, _heap_alignment);
```

**示例**：
```
用户指定 -Xms8000m -Xmx8000m
8000MB = 8,388,608,000 bytes

对齐到 4MB：
aligned_size = align_up(8,388,608,000, 4,194,304)
             = 8,388,608,000 向上对齐到 4MB 的倍数
             = 8,388,608,000 (已经是 4MB 的倍数? 否)
             = 8,392,802,304 (约 8001.5MB)

JVM 日志会显示实际使用的对齐后大小
```

### 5.2 Region 对齐

```cpp
// Region 边界自然对齐到 _space_alignment (4MB)
// 每个 Region 起始地址都是 4MB 的倍数

Region 0: [0x00000000, 0x00400000)     // 0MB - 4MB
Region 1: [0x00400000, 0x00800000)     // 4MB - 8MB
Region 2: [0x00800000, 0x00C00000)     // 8MB - 12MB
...
```

### 5.3 验证断言

```cpp
// collectorPolicy.cpp:58-59
assert(InitialHeapSize % _heap_alignment == 0, "InitialHeapSize alignment");
assert(MaxHeapSize % _heap_alignment == 0, "MaxHeapSize alignment");
```

---

## 6. 对齐的内存布局

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      堆内存布局（对齐后）                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  地址空间（低 → 高）                                                         │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ 堆起始地址 (heap_base)                                                │  │
│  │ 必须对齐到 _heap_alignment (4MB)                                      │  │
│  ├──────────────────────────────────────────────────────────────────────┤  │
│  │                                                                      │  │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐       ┌─────────┐              │  │
│  │  │ Region  │ │ Region  │ │ Region  │  ...  │ Region  │              │  │
│  │  │    0    │ │    1    │ │    2    │       │  2047   │              │  │
│  │  │  4MB    │ │  4MB    │ │  4MB    │       │  4MB    │              │  │
│  │  └─────────┘ └─────────┘ └─────────┘       └─────────┘              │  │
│  │  ↑          ↑          ↑                                            │  │
│  │  对齐到     对齐到      对齐到                                        │  │
│  │  4MB       4MB        4MB                                           │  │
│  │                                                                      │  │
│  ├──────────────────────────────────────────────────────────────────────┤  │
│  │ 堆结束地址 (heap_end)                                                 │  │
│  │ 必须对齐到 _heap_alignment (4MB)                                      │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  堆大小 = heap_end - heap_base = 8GB = 2048 × 4MB                         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 7. 卡表对齐详解

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         卡表与堆的对应关系                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  堆内存 (8GB)                                                               │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ 512B │ 512B │ 512B │ 512B │ 512B │ ... │ 512B │（共 16,777,216 个)    │   │
│  └──┬───┴──┬───┴──┬───┴──┬───┴──┬───┴─────┴──┬───┘                     │   │
│     │      │      │      │                   │                          │   │
│     ▼      ▼      ▼      ▼                   ▼                          │   │
│  卡表 (16MB)                                                            │   │
│  ┌────┬────┬────┬────┬────┬─────────────┬────┐                         │   │
│  │ B0 │ B1 │ B2 │ B3 │ B4 │    ...      │ Bn │ （共 16,777,216 字节）   │   │
│  └────┴────┴────┴────┴────┴─────────────┴────┘                         │   │
│                                                                             │
│  计算：                                                                      │
│  card_table_size = heap_size / card_size                                   │
│                  = 8GB / 512B                                              │
│                  = 8,589,934,592 / 512                                     │
│                  = 16,777,216 字节 = 16MB                                  │
│                                                                             │
│  卡表对齐要求：                                                              │
│  card_table_size 必须是 page_size (4KB) 的整数倍                           │
│  16MB / 4KB = 4096 ✓                                                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 8. GDB 验证

### 8.1 GDB 脚本

```gdb
# 文件：jvm-md/tmp-file/universe-init/gdb_alignments.txt

b g1CollectorPolicy.cpp:57
commands
  silent
  printf "\n========== Alignment Initialization ==========\n"
  
  # 输入参数
  printf "----- Input Parameters -----\n"
  printf "HeapRegion::GrainBytes: %lu (%lu MB)\n", HeapRegion::GrainBytes, HeapRegion::GrainBytes/1048576
  printf "CardTable::card_size: %d bytes\n", 512
  printf "os::vm_page_size(): %d bytes\n", 4096
  printf "UseLargePages: %d\n", UseLargePages
  
  # 中间计算
  printf "\n----- Intermediate Values -----\n"
  printf "card_table_alignment = 512 * 4096 = %lu (%lu MB)\n", 512*4096, 512*4096/1048576
  
  # 结果
  printf "\n----- Results -----\n"
  p this->_space_alignment
  p this->_heap_alignment
  
  printf "\n_space_alignment: %lu bytes (%lu MB)\n", this->_space_alignment, this->_space_alignment/1048576
  printf "_heap_alignment: %lu bytes (%lu MB)\n", this->_heap_alignment, this->_heap_alignment/1048576
  
  continue
end
run
```

### 8.2 预期输出

```
========== Alignment Initialization ==========
----- Input Parameters -----
HeapRegion::GrainBytes: 4194304 (4 MB)
CardTable::card_size: 512 bytes
os::vm_page_size(): 4096 bytes
UseLargePages: 0

----- Intermediate Values -----
card_table_alignment = 512 * 4096 = 2097152 (2 MB)

----- Results -----
$1 = 4194304
$2 = 4194304

_space_alignment: 4194304 bytes (4 MB)   ✅
_heap_alignment: 4194304 bytes (4 MB)    ✅
```

---

## 9. 设计要点

### 9.1 为什么 _heap_alignment ≥ _space_alignment？

```cpp
// collectorPolicy.cpp:77-78
assert(_heap_alignment >= _space_alignment,
       "heap_alignment less than space_alignment");
```

- 堆整体对齐必须 ≥ 内部空间对齐
- 否则 Region 边界可能无法正确对齐

### 9.2 为什么 _heap_alignment 是 _space_alignment 的倍数？

```cpp
// collectorPolicy.cpp:80-82
assert(_heap_alignment % _space_alignment == 0,
       "heap_alignment not aligned by space_alignment");
```

- 确保堆内的所有 Region 都能正确对齐
- 堆起始地址对齐到 _heap_alignment，Region 对齐到 _space_alignment
- 需要 _heap_alignment 是 _space_alignment 的倍数

### 9.3 为什么 G1 不像其他 GC 那样复杂？

```cpp
// 对比 MarkSweepPolicy::initialize_alignments()
// markSweepPolicy 使用 compute_heap_alignment()，考虑更多因素

// G1 简化了：
// 1. 只考虑卡表对齐、Region 大小、页面大小
// 2. 不需要考虑代际对齐（G1 没有传统的分代边界）
```

---

## 10. 总结

### 10.1 核心公式

```
_space_alignment = HeapRegion::GrainBytes = 4MB

card_table_alignment = card_size × page_size = 512 × 4K = 2MB

_heap_alignment = MAX3(card_table_alignment, _space_alignment, page_size)
                = MAX3(2MB, 4MB, 4KB)
                = 4MB
```

### 10.2 8GB 堆结果

| 参数 | 值 | 含义 |
|------|-----|------|
| _space_alignment | **4MB** | Region 内部空间对齐 |
| _heap_alignment | **4MB** | 堆整体对齐 |
| card_table_alignment | 2MB | 卡表约束 |

### 10.3 影响

- **InitialHeapSize** 和 **MaxHeapSize** 会被向上对齐到 4MB
- 所有 Region 边界都是 4MB 对齐
- 卡表大小自然满足页对齐（因为 4MB > 2MB）

---

## 待分析节点更新

| 节点 | 主题 | 状态 |
|------|------|------|
| B.1.1 | ParallelGCThreads 计算算法 | ✅ |
| F.1 | G1Predictions 预测器 | ✅ |
| E.5.1 | RefToScanQueue 工作窃取队列 | ✅ |
| D.4.1 | G1Policy 构造函数 | ✅ |
| F.2 | G1Analytics 分析器 | ✅ |
| F.3 | G1MMUTracker | ✅ |
| F.4 | G1IHOPControl | ✅ |
| C.1.1 | Region 大小计算算法 | ✅ |
| C.2 | RemSet 大小计算 | ✅ |
| **C.3** | **initialize_alignments()** | **✅** |
