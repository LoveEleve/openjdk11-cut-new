# C.1.1 - Region 大小计算算法

> **前置条件**：-Xms8G -Xmx8G，G1 GC，非大页，非 NUMA

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **C.1.1 - Region 大小计算算法**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 1. 概述

**Region 是 G1 GC 的核心概念**，整个堆被划分为大小相等的 Region。Region 大小直接影响：
- GC 回收粒度
- 巨型对象判定阈值
- 卡表大小
- RSet 开销

```
┌─────────────────────────────────────────────────────────────┐
│                     G1 Heap (8GB)                           │
├───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┤
│ R │ R │ R │ R │ R │ R │ R │ R │ R │ R │...│ R │ R │ R │ R │
│ 0 │ 1 │ 2 │ 3 │ 4 │ 5 │ 6 │ 7 │ 8 │ 9 │   │...│...│...│2047│
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
  │                                                           │
  └─── 每个 Region = 4MB ─────────────────────────────────────┘
  
  8GB / 4MB = 2048 个 Region
```

---

## 2. 调用位置

```cpp
// g1CollectorPolicy.cpp:42-50
G1CollectorPolicy::G1CollectorPolicy() {
  // 注释：存在循环依赖
  // - Region 大小基于堆大小计算
  // - 堆大小应该对齐到 Region 大小
  // 解决方案：使用未对齐的 InitialHeapSize/MaxHeapSize
  HeapRegion::setup_heap_region_size(InitialHeapSize, MaxHeapSize);
  HeapRegionRemSet::setup_remset_size();
}
```

---

## 3. 源码深度分析

### 3.1 HeapRegionBounds - 边界常量

```cpp
// heapRegionBounds.hpp:30-52
class HeapRegionBounds : public AllStatic {
private:
  // 最小 Region 大小：1MB
  // 注释：未来可能减小以更好地处理小堆
  static const size_t MIN_REGION_SIZE = 1024 * 1024;  // 1MB

  // 最大 Region 大小：32MB
  // 原因：Region 太大会降低清理效率（标记后找到完全空闲 Region 的机会更少）
  static const size_t MAX_REGION_SIZE = 32 * 1024 * 1024;  // 32MB

  // 目标 Region 数量：2048
  // 这是 G1 设计的"甜蜜点"，平衡管理开销和回收粒度
  static const size_t TARGET_REGION_NUMBER = 2048;

public:
  static inline size_t min_size();        // 返回 1MB
  static inline size_t max_size();        // 返回 32MB
  static inline size_t target_number();   // 返回 2048
};
```

**设计要点**：
| 常量 | 值 | 设计原因 |
|------|-----|----------|
| MIN_REGION_SIZE | 1MB | 避免管理开销过大 |
| MAX_REGION_SIZE | 32MB | 保证清理效率（找到空闲 Region） |
| TARGET_REGION_NUMBER | 2048 | G1 算法的最优工作点 |

### 3.2 setup_heap_region_size() - 核心算法

```cpp
// heapRegion.cpp:63-110
void HeapRegion::setup_heap_region_size(size_t initial_heap_size, size_t max_heap_size) {
  // ===== 步骤 1：确定初始 region_size =====
  size_t region_size = G1HeapRegionSize;  // 默认为 0
  
  if (FLAG_IS_DEFAULT(G1HeapRegionSize)) {
    // 用户未显式设置，自动计算
    // 公式：average_heap_size / TARGET_REGION_NUMBER
    size_t average_heap_size = (initial_heap_size + max_heap_size) / 2;
    // 8GB 堆：(8GB + 8GB) / 2 = 8GB
    
    region_size = MAX2(average_heap_size / HeapRegionBounds::target_number(),
                       HeapRegionBounds::min_size());
    // 8GB / 2048 = 4MB，取 MAX(4MB, 1MB) = 4MB
  }

  // ===== 步骤 2：向下取整为 2 的幂 =====
  int region_size_log = log2_long((jlong) region_size);
  // log2(4MB) = log2(4194304) = 22
  
  // 重新计算确保是 2 的幂
  // 如果输入不是 2 的幂，取 <= 该值的最大 2 的幂
  region_size = ((size_t)1 << region_size_log);
  // 1 << 22 = 4194304 = 4MB

  // ===== 步骤 3：边界检查 =====
  if (region_size < HeapRegionBounds::min_size()) {
    region_size = HeapRegionBounds::min_size();  // 至少 1MB
  } else if (region_size > HeapRegionBounds::max_size()) {
    region_size = HeapRegionBounds::max_size();  // 最多 32MB
  }

  // ===== 步骤 4：重算 log 值（边界检查后可能变化）=====
  region_size_log = log2_long((jlong) region_size);

  // ===== 步骤 5：设置全局静态变量 =====
  guarantee(LogOfHRGrainBytes == 0, "we should only set it once");
  LogOfHRGrainBytes = region_size_log;  // = 22

  guarantee(LogOfHRGrainWords == 0, "we should only set it once");
  LogOfHRGrainWords = LogOfHRGrainBytes - LogHeapWordSize;
  // = 22 - 3 = 19（64位系统 LogHeapWordSize=3）

  guarantee(GrainBytes == 0, "we should only set it once");
  GrainBytes = region_size;  // = 4MB = 4194304
  
  // 输出日志：Heap region size: 4M
  log_info(gc, heap)("Heap region size: " SIZE_FORMAT "M", GrainBytes / M);

  guarantee(GrainWords == 0, "we should only set it once");
  GrainWords = GrainBytes >> LogHeapWordSize;
  // = 4194304 >> 3 = 524288 个 HeapWord
  guarantee((size_t) 1 << LogOfHRGrainWords == GrainWords, "sanity");

  guarantee(CardsPerRegion == 0, "we should only set it once");
  CardsPerRegion = GrainBytes >> G1CardTable::card_shift;
  // = 4194304 >> 9 = 8192 张卡

  // ===== 步骤 6：同步 JVM Flag =====
  if (G1HeapRegionSize != GrainBytes) {
    FLAG_SET_ERGO(size_t, G1HeapRegionSize, GrainBytes);
  }
}
```

---

## 4. 计算过程图解（8GB 堆）

```
输入：InitialHeapSize = 8GB, MaxHeapSize = 8GB

┌──────────────────────────────────────────────────────────────────┐
│ 步骤 1：计算目标 Region 大小                                      │
├──────────────────────────────────────────────────────────────────┤
│ average_heap_size = (8GB + 8GB) / 2 = 8GB = 8,589,934,592 bytes  │
│                                                                   │
│ region_size = MAX(8GB / 2048, 1MB)                               │
│             = MAX(4,194,304, 1,048,576)                          │
│             = 4,194,304 bytes = 4MB                              │
└──────────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│ 步骤 2：向下取整为 2 的幂                                         │
├──────────────────────────────────────────────────────────────────┤
│ region_size_log = log2(4,194,304) = 22                           │
│ region_size = 1 << 22 = 4,194,304 bytes = 4MB  ✓ 已是 2 的幂     │
└──────────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│ 步骤 3：边界检查                                                  │
├──────────────────────────────────────────────────────────────────┤
│ 1MB ≤ 4MB ≤ 32MB  ✓ 在有效范围内                                 │
└──────────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│ 步骤 4：设置全局变量                                              │
├──────────────────────────────────────────────────────────────────┤
│ LogOfHRGrainBytes = 22                                           │
│ LogOfHRGrainWords = 22 - 3 = 19                                  │
│ GrainBytes = 4,194,304 (4MB)                                     │
│ GrainWords = 4,194,304 >> 3 = 524,288                            │
│ CardsPerRegion = 4,194,304 >> 9 = 8,192                          │
└──────────────────────────────────────────────────────────────────┘
```

---

## 5. 不同堆大小的 Region 计算

| 堆大小 | 平均堆大小 | 计算值 | 取整后 | Region 数 |
|--------|-----------|--------|--------|-----------|
| 1GB | 1GB | 512KB | 1MB (min) | 1024 |
| 2GB | 2GB | 1MB | 1MB | 2048 |
| 4GB | 4GB | 2MB | 2MB | 2048 |
| 8GB | 8GB | 4MB | 4MB | 2048 |
| 16GB | 16GB | 8MB | 8MB | 2048 |
| 32GB | 32GB | 16MB | 16MB | 2048 |
| 64GB | 64GB | 32MB | 32MB (max) | 2048 |
| 128GB | 128GB | 64MB | 32MB (max) | 4096 |

**关键规律**：
1. **2GB ~ 64GB**：Region 数保持 2048 不变
2. **<2GB**：Region 数减少（受最小 1MB 限制）
3. **>64GB**：Region 数增加（受最大 32MB 限制）

---

## 6. 相关常量计算详解

### 6.1 CardsPerRegion（每 Region 的卡数）

```cpp
// 卡表常量（cardTable.hpp:234）
enum SomePublicConstants {
  card_shift = 9,          // 地址右移 9 位得到卡索引
  card_size = 1 << 9,      // = 512 bytes，每张卡覆盖 512 字节
  card_size_in_words = 512 / 8  // = 64 个 HeapWord
};

// Region 内的卡数
CardsPerRegion = GrainBytes >> card_shift
               = 4,194,304 >> 9
               = 8,192 张卡
```

**验证**：`8192 × 512 = 4,194,304 bytes = 4MB` ✓

```
┌─────────────────── Region (4MB) ───────────────────┐
│ Card │ Card │ Card │ Card │ ... │ Card │ Card │Card│
│  0   │  1   │  2   │  3   │ ... │ 8189 │ 8190 │8191│
└──────┴──────┴──────┴──────┴─────┴──────┴──────┴────┘
  512B   512B   512B   512B         512B   512B  512B
  
  总共 8192 张卡，每张 512 字节
```

### 6.2 GrainWords（每 Region 的字数）

```cpp
// 64 位系统：HeapWord = 8 bytes
LogHeapWordSize = 3  // log2(8) = 3

GrainWords = GrainBytes >> LogHeapWordSize
           = 4,194,304 >> 3
           = 524,288 个 HeapWord

// 验证
LogOfHRGrainWords = LogOfHRGrainBytes - LogHeapWordSize
                  = 22 - 3 = 19
1 << 19 = 524,288 ✓
```

### 6.3 巨型对象阈值

```cpp
// g1CollectedHeap.cpp:1522
_humongous_object_threshold_in_words = humongous_threshold_for(HeapRegion::GrainWords);

// g1CollectedHeap.hpp:1013
static size_t humongous_threshold_for(size_t region_size) {
  return (region_size / 2);  // Region 的一半
}

// 8GB 堆
humongous_threshold = 524,288 / 2 = 262,144 words = 2MB
```

**规则**：对象大小 ≥ 2MB 视为巨型对象，直接分配到 Humongous Region

---

## 7. 为什么选择 2048 个 Region？

G1 论文和实现选择 2048 作为目标 Region 数量的原因：

### 7.1 管理开销平衡

```
┌─────────────────────────────────────────────────────────────────┐
│ Region 数量过多（如 10000+）                                     │
├─────────────────────────────────────────────────────────────────┤
│ ❌ 管理结构（HeapRegionManager、Bitmap）占用内存大                │
│ ❌ 遍历所有 Region 耗时增加                                      │
│ ❌ RSet 条目可能更多                                             │
│ ✅ 回收粒度细，更精确                                            │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ Region 数量过少（如 100）                                        │
├─────────────────────────────────────────────────────────────────┤
│ ✅ 管理开销小                                                    │
│ ❌ 回收粒度粗，灵活性差                                          │
│ ❌ 标记后难找到完全空闲的 Region                                  │
│ ❌ 年轻代/老年代比例调整不精细                                    │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ 2048 Region（G1 选择）                                           │
├─────────────────────────────────────────────────────────────────┤
│ ✅ 管理开销适中                                                  │
│ ✅ 11 位索引，位运算高效                                         │
│ ✅ 足够的回收粒度                                                │
│ ✅ 合理的 RSet 开销                                              │
└─────────────────────────────────────────────────────────────────┘
```

### 7.2 位运算优化

```cpp
// 2048 = 2^11，正好用 11 位表示 Region 索引
// Region 大小是 2 的幂，地址计算可用移位代替除法

// 快速计算地址所在 Region 索引
inline uint addr_to_region(HeapWord* addr) {
  return (uint)(pointer_delta(addr, _reserved.start(), sizeof(uint8_t)) 
                >> HeapRegion::LogOfHRGrainBytes);
  // 右移 22 位，非常高效
}
```

---

## 8. GDB 验证

### 8.1 GDB 脚本

```gdb
# 文件：jvm-md/tmp-file/universe-init/gdb_region_size.txt

# 断点设置在 Region 大小计算完成后
b heapRegion.cpp:109
commands
  silent
  printf "\n========== Region Size Calculation ==========\n"
  
  # 输入参数（通过寄存器或栈获取）
  printf "InitialHeapSize: %lu bytes (%.2f GB)\n", InitialHeapSize, InitialHeapSize/1073741824.0
  printf "MaxHeapSize: %lu bytes (%.2f GB)\n", MaxHeapSize, MaxHeapSize/1073741824.0
  
  # G1HeapRegionSize Flag
  printf "\n----- G1HeapRegionSize Flag -----\n"
  printf "G1HeapRegionSize (before): %lu\n", G1HeapRegionSize
  
  # 计算结果
  printf "\n----- Calculated Results -----\n"
  printf "LogOfHRGrainBytes: %d\n", HeapRegion::LogOfHRGrainBytes
  printf "LogOfHRGrainWords: %d\n", HeapRegion::LogOfHRGrainWords
  printf "GrainBytes: %lu (%lu MB)\n", HeapRegion::GrainBytes, HeapRegion::GrainBytes/1048576
  printf "GrainWords: %lu\n", HeapRegion::GrainWords
  printf "CardsPerRegion: %lu\n", HeapRegion::CardsPerRegion
  
  # 验证
  printf "\n----- Verification -----\n"
  printf "Expected Region count: %lu\n", MaxHeapSize / HeapRegion::GrainBytes
  printf "2^LogOfHRGrainBytes = %lu\n", (1UL << HeapRegion::LogOfHRGrainBytes)
  printf "2^LogOfHRGrainWords = %lu\n", (1UL << HeapRegion::LogOfHRGrainWords)
  
  continue
end
run
```

### 8.2 验证结果（8GB 堆）

```
========== Region Size Calculation ==========
InitialHeapSize: 8589934592 bytes (8.00 GB)
MaxHeapSize: 8589934592 bytes (8.00 GB)

----- G1HeapRegionSize Flag -----
G1HeapRegionSize (before): 0

----- Calculated Results -----
LogOfHRGrainBytes: 22              ✅ log2(4MB) = 22
LogOfHRGrainWords: 19              ✅ 22 - 3 = 19
GrainBytes: 4194304 (4 MB)         ✅ 4MB
GrainWords: 524288                 ✅ 4MB / 8 = 524288
CardsPerRegion: 8192               ✅ 4MB / 512 = 8192

----- Verification -----
Expected Region count: 2048        ✅ 8GB / 4MB = 2048
2^LogOfHRGrainBytes = 4194304      ✅
2^LogOfHRGrainWords = 524288       ✅
```

### 8.3 日志输出验证

启动 JVM 时添加参数：`-Xlog:gc+heap=info`

```
[0.005s][info][gc,heap] Heap region size: 4M
```

---

## 9. 手动指定 Region 大小

用户可以通过 `-XX:G1HeapRegionSize=<size>` 手动指定：

```bash
# 指定 8MB Region
java -XX:+UseG1GC -Xms8g -Xmx8g -XX:G1HeapRegionSize=8m ...

# 约束检查（jvmFlagConstraintsG1.cpp:63-71）
# - 必须 >= 1MB（HeapRegionBounds::min_size()）
# - 必须 <= 32MB（隐式，通过 range(0, 32*M) 约束）
# - 会自动向下取整为 2 的幂
```

**注意**：即使手动指定非 2 的幂，也会被取整。例如指定 5MB 会变成 4MB。

---

## 10. 设置的静态变量汇总

| 变量 | 值 (8GB堆) | 含义 |
|------|------------|------|
| `LogOfHRGrainBytes` | 22 | log2(GrainBytes) |
| `LogOfHRGrainWords` | 19 | log2(GrainWords) |
| `GrainBytes` | 4,194,304 | Region 大小（字节） |
| `GrainWords` | 524,288 | Region 大小（HeapWord） |
| `CardsPerRegion` | 8,192 | 每 Region 的卡数 |
| `G1HeapRegionSize` (Flag) | 4,194,304 | JVM Flag（同步更新） |

---

## 11. 流程图

```
                     ┌─────────────────────────────────┐
                     │ G1CollectorPolicy::G1Collector  │
                     │           Policy()              │
                     └───────────────┬─────────────────┘
                                     │
                     ┌───────────────▼─────────────────┐
                     │ HeapRegion::setup_heap_region_  │
                     │ size(InitialHeapSize,MaxHeapSize)│
                     └───────────────┬─────────────────┘
                                     │
              ┌──────────────────────┴──────────────────────┐
              │                                             │
              ▼                                             ▼
┌─────────────────────────┐               ┌─────────────────────────┐
│ FLAG_IS_DEFAULT(        │     NO        │ region_size =           │
│   G1HeapRegionSize)?    │─────────────▶│ G1HeapRegionSize        │
└───────────┬─────────────┘               └───────────┬─────────────┘
            │ YES                                     │
            ▼                                         │
┌─────────────────────────┐                           │
│ avg = (init + max) / 2  │                           │
│ region_size = MAX(      │                           │
│   avg/2048, 1MB)        │                           │
└───────────┬─────────────┘                           │
            │                                         │
            └────────────────────┬────────────────────┘
                                 │
                     ┌───────────▼─────────────┐
                     │ log = log2(region_size) │
                     │ region_size = 1 << log  │
                     │ (向下取整为 2 的幂)       │
                     └───────────┬─────────────┘
                                 │
                     ┌───────────▼─────────────┐
                     │ 边界检查：               │
                     │ 1MB ≤ region_size ≤ 32MB│
                     └───────────┬─────────────┘
                                 │
                     ┌───────────▼─────────────┐
                     │ 设置全局静态变量：        │
                     │ • LogOfHRGrainBytes = 22│
                     │ • LogOfHRGrainWords = 19│
                     │ • GrainBytes = 4MB      │
                     │ • GrainWords = 524288   │
                     │ • CardsPerRegion = 8192 │
                     └─────────────────────────┘
```

---

## 12. 关键设计决策

### 12.1 为什么必须是 2 的幂？

```cpp
// 位运算优化：除法变移位
addr / GrainBytes  →  addr >> LogOfHRGrainBytes  // 快 ~10x

// Region 索引计算（g1CollectedHeap.inline.hpp:70）
inline uint addr_to_region(HeapWord* addr) {
  return (uint)(pointer_delta(addr, reserved_region().start(), sizeof(uint8_t)) 
                >> HeapRegion::LogOfHRGrainBytes);
}

// 如果不是 2 的幂，每次地址到索引的转换都需要除法，严重影响性能
```

### 12.2 为什么用 average_heap_size？

```cpp
// 考虑 -Xms1g -Xmx8g 场景
// 如果只用 MaxHeapSize：Region = 8GB/2048 = 4MB
// 如果只用 InitialHeapSize：Region = 1GB/2048 = 512KB → 取整为 1MB

// 使用平均值：(1GB + 8GB)/2 = 4.5GB → 4.5GB/2048 ≈ 2.2MB → 取整为 2MB
// 这是一个折中方案，兼顾初始和最大堆大小
```

### 12.3 为什么先设再同步 Flag？

```cpp
// 先设置 GrainBytes，再同步 G1HeapRegionSize
GrainBytes = region_size;

if (G1HeapRegionSize != GrainBytes) {
  FLAG_SET_ERGO(size_t, G1HeapRegionSize, GrainBytes);
}

// 原因：
// 1. GrainBytes 是内部使用的变量，性能关键
// 2. G1HeapRegionSize 是 JVM Flag，用于诊断和监控
// 3. 同步确保 jcmd/JMX 能看到正确的值
```

---

## 总结

**Region 大小计算的核心公式**：

```
region_size = MAX(average_heap_size / 2048, 1MB)
            = round_down_to_power_of_2(region_size)
            = clamp(region_size, 1MB, 32MB)
```

**8GB 堆的计算结果**：
- Region 大小：**4MB**
- Region 数量：**2048**
- 每 Region 卡数：**8192**
- 巨型对象阈值：**2MB**

这个设计平衡了管理开销、回收粒度和性能优化，是 G1 GC 的基础设施。

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
| **C.1.1** | **Region 大小计算算法** | **✅** |
