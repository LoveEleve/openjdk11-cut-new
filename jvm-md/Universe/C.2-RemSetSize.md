# C.2 - HeapRegionRemSet::setup_remset_size()

> **前置条件**：-Xms8G -Xmx8G，G1 GC，非大页，非 NUMA
> **前置知识**：C.1.1 Region 大小计算（GrainBytes=4MB, LogOfHRGrainBytes=22）

---

## 1. 概述

**RSet (Remembered Set)** 是 G1 GC 实现跨 Region 引用追踪的核心数据结构。每个 Region 都有一个 RSet，记录"哪些其他 Region 的哪些卡指向了我"。

`setup_remset_size()` 根据 Region 大小计算 RSet 相关参数：
- **G1RSetSparseRegionEntries**：稀疏表每 Region 最大条目数
- **G1RSetRegionEntries**：细粒度表每 Region 最大条目数

---

## 2. RSet 三层结构

G1 的 RSet 采用**三层渐进式结构**，根据引用数量动态升级：

```
┌────────────────────────────────────────────────────────────────────────┐
│                      HeapRegionRemSet 三层结构                          │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  ┌─────────────────────────────────────────────────────────────────┐  │
│  │ 层级 1：Sparse PRT（稀疏表）                                      │  │
│  │ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━│  │
│  │ • 存储：<region_idx, card_array[12]>                            │  │
│  │ • 每个源 Region 最多存 12 张卡（G1RSetSparseRegionEntries）       │  │
│  │ • 适用：引用稀疏，少量卡                                          │  │
│  │ • 优点：空间最省                                                  │  │
│  └─────────────────────────────────────────────────────────────────┘  │
│                              ↓ 卡数超过 12                             │
│  ┌─────────────────────────────────────────────────────────────────┐  │
│  │ 层级 2：Fine-grain PRT（细粒度表）                                │  │
│  │ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━│  │
│  │ • 存储：PerRegionTable（CHeapBitMap，8192 位 = 1KB）             │  │
│  │ • 每 Region 一个 Bitmap，精确记录每张卡                          │  │
│  │ • 容量：最多 768 个 PerRegionTable（G1RSetRegionEntries）        │  │
│  │ • 优点：查询快，O(1) 判断某卡是否存在                             │  │
│  └─────────────────────────────────────────────────────────────────┘  │
│                              ↓ 超过 768 个源 Region                    │
│  ┌─────────────────────────────────────────────────────────────────┐  │
│  │ 层级 3：Coarse Bitmap（粗粒度位图）                               │  │
│  │ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━│  │
│  │ • 存储：CHeapBitMap（2048 位 = 256 字节）                        │  │
│  │ • 只记录"哪些 Region 指向我"，不记录具体哪张卡                    │  │
│  │ • 适用：引用极密集的热点 Region                                   │  │
│  │ • 缺点：GC 时需要扫描整个源 Region                                │  │
│  └─────────────────────────────────────────────────────────────────┘  │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 源码分析

### 3.1 setup_remset_size()

```cpp
// heapRegionRemSet.cpp:630-642
void HeapRegionRemSet::setup_remset_size() {
  // 公式：table_size = base * (log(region_size / 1M) + 1)
  // 即：region_size 每翻倍，table_size 线性增长
  
  const int LOG_M = 20;  // log2(1MB) = 20
  
  // region_size_log_mb = log2(region_size) - log2(1MB)
  //                    = log2(region_size / 1MB)
  // 8GB 堆：= 22 - 20 = 2（即 4MB / 1MB = 4 = 2^2）
  int region_size_log_mb = MAX2(HeapRegion::LogOfHRGrainBytes - LOG_M, 0);
  
  // ===== 稀疏表条目数 =====
  if (FLAG_IS_DEFAULT(G1RSetSparseRegionEntries)) {
    // G1RSetSparseRegionEntriesBase = 4（develop 参数）
    // 8GB 堆：4 * (2 + 1) = 12
    G1RSetSparseRegionEntries = G1RSetSparseRegionEntriesBase * (region_size_log_mb + 1);
  }
  
  // ===== 细粒度表条目数 =====
  if (FLAG_IS_DEFAULT(G1RSetRegionEntries)) {
    // G1RSetRegionEntriesBase = 256（develop 参数）
    // 8GB 堆：256 * (2 + 1) = 768
    G1RSetRegionEntries = G1RSetRegionEntriesBase * (region_size_log_mb + 1);
  }
  
  guarantee(G1RSetSparseRegionEntries > 0 && G1RSetRegionEntries > 0, "Sanity");
}
```

### 3.2 计算公式详解

```
┌─────────────────────────────────────────────────────────────────────────┐
│ 公式：entries = base × (region_size_log_mb + 1)                         │
│                                                                         │
│ 其中：region_size_log_mb = MAX(LogOfHRGrainBytes - 20, 0)              │
│                         = MAX(log2(region_size) - log2(1MB), 0)        │
│                         = MAX(log2(region_size / 1MB), 0)              │
└─────────────────────────────────────────────────────────────────────────┘

8GB 堆计算：
  region_size_log_mb = MAX(22 - 20, 0) = 2
  
  G1RSetSparseRegionEntries = 4 × (2 + 1) = 12
  G1RSetRegionEntries = 256 × (2 + 1) = 768
```

### 3.3 不同堆大小的参数值

| 堆大小 | Region | LogOfHRGrainBytes | region_size_log_mb | Sparse 条目 | Fine 条目 |
|--------|--------|-------------------|-------------------|-------------|-----------|
| 1GB | 1MB | 20 | 0 | 4 | 256 |
| 2GB | 1MB | 20 | 0 | 4 | 256 |
| 4GB | 2MB | 21 | 1 | 8 | 512 |
| **8GB** | **4MB** | **22** | **2** | **12** | **768** |
| 16GB | 8MB | 23 | 3 | 16 | 1024 |
| 32GB | 16MB | 24 | 4 | 20 | 1280 |
| 64GB | 32MB | 25 | 5 | 24 | 1536 |

---

## 4. 三层结构详解

### 4.1 层级 1：SparsePRT（稀疏表）

```cpp
// sparsePRT.hpp:46-76
class SparsePRTEntry: public CHeapObj<mtGC> {
private:
  typedef uint16_t card_elem_t;  // 2 字节，可表示 0-65535
  
  RegionIdx_t _region_ind;       // 4 字节：源 Region 索引
  int         _next_index;       // 4 字节：哈希冲突链
  int         _next_null;        // 4 字节：下一个空槽位
  card_elem_t _cards[12];        // 24 字节：卡数组（对齐后 12 个）
  // 总共约 36 字节
  
public:
  static int cards_num() {
    // 8GB 堆：align_up(12, 2) = 12
    return align_up((int)G1RSetSparseRegionEntries, (int)card_array_alignment);
  }
};
```

**稀疏表工作方式**：
```
SparsePRT（哈希表）
├── bucket[0] → Entry(region=5, cards=[100,200,300]) → Entry(region=10, cards=[50])
├── bucket[1] → Entry(region=2, cards=[800,900])
├── bucket[2] → NULL
└── ...

每个 Entry 存储一个源 Region 的最多 12 张卡的索引
```

### 4.2 层级 2：PerRegionTable（细粒度表）

```cpp
// heapRegionRemSet.cpp:45-74
class PerRegionTable: public CHeapObj<mtGC> {
  HeapRegion*     _hr;         // 指向源 Region
  CHeapBitMap     _bm;         // 位图：8192 位 = 1KB
  jint            _occupied;   // 已设置的位数
  
  // 链表指针
  PerRegionTable* _next;
  PerRegionTable* _prev;
  PerRegionTable* _collision_list_next;
  
  PerRegionTable(HeapRegion* hr) :
    _hr(hr),
    _occupied(0),
    _bm(HeapRegion::CardsPerRegion, mtGC),  // 8192 位
    _collision_list_next(NULL), _next(NULL), _prev(NULL)
  {}
};
```

**细粒度表工作方式**：
```
OtherRegionsTable
├── _fine_grain_regions[768]  // 哈希表，最多 768 个 PRT
│   ├── [0] → PRT(region=5) → PRT(region=100) → ...
│   ├── [1] → PRT(region=2)
│   └── ...
│
└── 每个 PRT 是一个 8192 位的 Bitmap
    ┌─────────────────────────────────────────┐
    │ 0 0 1 0 0 0 1 0 0 0 0 1 ... (8192 bits) │
    │     ↑       ↑       ↑                   │
    │   card2   card6   card11               │
    └─────────────────────────────────────────┘
```

### 4.3 层级 3：Coarse Bitmap（粗粒度位图）

```cpp
// heapRegionRemSet.hpp:74-84
class OtherRegionsTable {
  CHeapBitMap _coarse_map;     // 2048 位 = 256 字节
  size_t      _n_coarse_entries;
  
  // 当 fine-grain 表满时，驱逐一个 PRT 并设置 coarse 位
  // 这意味着需要扫描整个源 Region
};
```

**粗粒度位图**：
```
_coarse_map (2048 bits)
┌─────────────────────────────────────────────────────────┐
│ 0 0 1 0 0 0 0 0 0 0 1 0 0 0 0 0 0 0 1 0 0 ... (2048)   │
│     ↑               ↑               ↑                   │
│   region2         region10       region18              │
│   "整个 Region     "整个 Region    "整个 Region         │
│    指向我"          指向我"         指向我"              │
└─────────────────────────────────────────────────────────┘

GC 时需要扫描整个 region2、region10、region18
```

---

## 5. 升级/降级流程

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         RSet 层级转换流程                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  新引用到达                                                              │
│       │                                                                 │
│       ▼                                                                 │
│  ┌─────────────────┐                                                   │
│  │ 检查 Sparse PRT │                                                   │
│  └────────┬────────┘                                                   │
│           │                                                             │
│     ┌─────┴─────┐                                                      │
│     │ 源Region  │                                                      │
│     │ 已在表中? │                                                      │
│     └─────┬─────┘                                                      │
│      YES  │  NO                                                        │
│     ┌─────┴─────┐                                                      │
│     │           │                                                      │
│     ▼           ▼                                                      │
│  ┌──────────┐  ┌──────────────┐                                        │
│  │ 卡数<12? │  │ 创建新 Entry │                                        │
│  └────┬─────┘  └──────────────┘                                        │
│   YES │ NO                                                             │
│   ┌───┴───┐                                                            │
│   │       │                                                            │
│   ▼       ▼                                                            │
│ 直接添加  ┌───────────────────────────────────────┐                    │
│         │ 升级到 Fine-grain PRT                  │                    │
│         │ 1. 创建 PerRegionTable (1KB Bitmap)    │                    │
│         │ 2. 复制 12 张卡到 Bitmap               │                    │
│         │ 3. 删除 SparsePRTEntry                 │                    │
│         └───────────────────────────────────────┘                     │
│                        │                                               │
│                        ▼                                               │
│         ┌───────────────────────────────────────┐                     │
│         │ Fine-grain 表已有 768 个 PRT？         │                     │
│         └───────────────┬───────────────────────┘                     │
│                    YES  │  NO                                          │
│               ┌─────────┴─────────┐                                    │
│               │                   │                                    │
│               ▼                   ▼                                    │
│  ┌───────────────────────┐    正常添加                                 │
│  │ 升级到 Coarse Bitmap  │                                            │
│  │ 1. 选择一个 PRT 驱逐   │                                            │
│  │ 2. 设置 coarse 位      │                                            │
│  │ 3. 释放 PRT           │                                            │
│  └───────────────────────┘                                            │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 6. 为什么按 Region 大小缩放？

**设计原理**：Region 越大，每个 Region 内的对象越多，跨 Region 引用也越多。

```
┌─────────────────────────────────────────────────────────────────────────┐
│ 假设：对象引用密度相同                                                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│ 1MB Region:                                                            │
│ ┌────┐                                                                 │
│ │ R  │ ← 假设平均 4 个源 Region 指向它                                  │
│ └────┘   每个源 Region 平均 4 张卡                                      │
│          → Sparse 够用（4×4=16 < 4×256=1024 总容量）                   │
│                                                                         │
│ 4MB Region (4倍大):                                                    │
│ ┌────────────────┐                                                     │
│ │       R        │ ← 平均 16 个源 Region 指向它（4倍）                  │
│ └────────────────┘   每个源 Region 平均 16 张卡（4倍）                  │
│          → 需要更大的 Sparse（12 条目）和 Fine（768 个 PRT）           │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 7. 内存开销分析（8GB 堆）

### 7.1 最坏情况估算

```
每个 Region 的 RSet 内存：
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SparsePRT:
  - 初始容量 16 个桶
  - 每个 Entry ≈ 36 字节
  - 最大 ≈ 若干 KB

Fine-grain:
  - 最多 768 个 PerRegionTable
  - 每个 PRT = Bitmap(1KB) + 元数据(≈32字节) ≈ 1KB
  - 最大 = 768 × 1KB ≈ 768KB

Coarse Bitmap:
  - 固定 2048 位 = 256 字节

单个 Region RSet 最大 ≈ 768KB + 256B ≈ 768KB

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
全堆（2048 Region）最坏情况：
  2048 × 768KB = 1.5GB

但这是极端情况（每个 Region 都有 768 个源指向它）
实际通常 << 1.5GB
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### 7.2 典型场景

```
典型 Java 应用：
  - 大部分 Region 只需要 Sparse PRT
  - 少数热点 Region 使用 Fine-grain
  - 极少数使用 Coarse

实际 RSet 开销通常在堆大小的 1%-5%
8GB 堆 → 约 80MB - 400MB
```

---

## 8. GDB 验证

### 8.1 GDB 脚本

```gdb
# 文件：jvm-md/tmp-file/universe-init/gdb_remset_size.txt

b heapRegionRemSet.cpp:641
commands
  silent
  printf "\n========== RemSet Size Calculation ==========\n"
  
  # 输入：Region 大小
  printf "HeapRegion::LogOfHRGrainBytes: %d\n", HeapRegion::LogOfHRGrainBytes
  printf "HeapRegion::GrainBytes: %lu (%lu MB)\n", HeapRegion::GrainBytes, HeapRegion::GrainBytes/1048576
  
  # 计算中间值
  printf "\nregion_size_log_mb: %d (= LogOfHRGrainBytes - 20)\n", HeapRegion::LogOfHRGrainBytes - 20
  
  # Base 值
  printf "\n----- Base Values -----\n"
  printf "G1RSetSparseRegionEntriesBase: %d\n", G1RSetSparseRegionEntriesBase
  printf "G1RSetRegionEntriesBase: %d\n", G1RSetRegionEntriesBase
  
  # 计算结果
  printf "\n----- Calculated Results -----\n"
  printf "G1RSetSparseRegionEntries: %d\n", G1RSetSparseRegionEntries
  printf "G1RSetRegionEntries: %d\n", G1RSetRegionEntries
  
  # 验证计算
  printf "\n----- Verification -----\n"
  printf "Expected Sparse: %d * %d = %d\n", G1RSetSparseRegionEntriesBase, (HeapRegion::LogOfHRGrainBytes - 20 + 1), G1RSetSparseRegionEntriesBase * (HeapRegion::LogOfHRGrainBytes - 20 + 1)
  printf "Expected Fine: %d * %d = %d\n", G1RSetRegionEntriesBase, (HeapRegion::LogOfHRGrainBytes - 20 + 1), G1RSetRegionEntriesBase * (HeapRegion::LogOfHRGrainBytes - 20 + 1)
  
  continue
end
run
```

### 8.2 预期输出

```
========== RemSet Size Calculation ==========
HeapRegion::LogOfHRGrainBytes: 22
HeapRegion::GrainBytes: 4194304 (4 MB)

region_size_log_mb: 2 (= LogOfHRGrainBytes - 20)

----- Base Values -----
G1RSetSparseRegionEntriesBase: 4         ✅ develop 参数
G1RSetRegionEntriesBase: 256             ✅ develop 参数

----- Calculated Results -----
G1RSetSparseRegionEntries: 12            ✅ 4 × 3 = 12
G1RSetRegionEntries: 768                 ✅ 256 × 3 = 768

----- Verification -----
Expected Sparse: 4 * 3 = 12              ✅
Expected Fine: 256 * 3 = 768             ✅
```

---

## 9. 关联结构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        HeapRegionRemSet 结构关系                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  HeapRegion                                                                 │
│  ┌────────────────────────────┐                                            │
│  │ ...                        │                                            │
│  │ HeapRegionRemSet* _rem_set │──────┐                                     │
│  │ ...                        │      │                                     │
│  └────────────────────────────┘      │                                     │
│                                      │                                     │
│                                      ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │ HeapRegionRemSet                                                     │  │
│  │ ┌───────────────────────────────────────────────────────────────┐   │  │
│  │ │ OtherRegionsTable _other_regions                               │   │  │
│  │ │ ┌─────────────────────────────────────────────────────────┐   │   │  │
│  │ │ │ CHeapBitMap _coarse_map (256B)     ← 粗粒度：2048 位     │   │   │  │
│  │ │ │ PerRegionTable** _fine_grain_regions[768] ← 细粒度     │   │   │  │
│  │ │ │ SparsePRT _sparse_table            ← 稀疏表              │   │   │  │
│  │ │ └─────────────────────────────────────────────────────────┘   │   │  │
│  │ └───────────────────────────────────────────────────────────────┘   │  │
│  │ G1CodeRootSet _code_roots    ← 记录指向此 Region 的 nmethod        │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  PerRegionTable                           SparsePRTEntry                   │
│  ┌────────────────────────┐              ┌────────────────────────────┐   │
│  │ HeapRegion* _hr        │              │ RegionIdx_t _region_ind    │   │
│  │ CHeapBitMap _bm (1KB)  │              │ card_elem_t _cards[12]     │   │
│  │ jint _occupied         │              │ int _next_index            │   │
│  │ PerRegionTable* _next  │              └────────────────────────────┘   │
│  └────────────────────────┘                                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 10. 总结

### 10.1 核心公式

```
region_size_log_mb = MAX(LogOfHRGrainBytes - 20, 0)
                   = MAX(log2(region_size / 1MB), 0)

G1RSetSparseRegionEntries = 4 × (region_size_log_mb + 1)
G1RSetRegionEntries = 256 × (region_size_log_mb + 1)
```

### 10.2 8GB 堆计算结果

| 参数 | 值 | 含义 |
|------|-----|------|
| region_size_log_mb | 2 | log2(4MB/1MB) = 2 |
| G1RSetSparseRegionEntries | **12** | 稀疏表每源 Region 最多 12 张卡 |
| G1RSetRegionEntries | **768** | 细粒度表最多 768 个 PerRegionTable |

### 10.3 设计要点

1. **三层渐进式结构**：空间效率与查询效率的平衡
2. **按 Region 大小缩放**：Region 越大，引用越多，需要更大的表
3. **最坏情况保护**：Coarse Bitmap 确保不会 OOM，代价是 GC 时扫描更多

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
| **C.2** | **RemSet 大小计算** | **✅** |
