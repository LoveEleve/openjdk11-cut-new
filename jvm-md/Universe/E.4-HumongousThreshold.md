# E.4 - 巨型对象阈值（Humongous Object Threshold）

> **前置条件**：-Xms8G -Xmx8G，G1 GC，非大页，非 NUMA
> **前置知识**：C.1.1 Region 大小（GrainBytes=4MB, GrainWords=524288）

---

## 1. 概述

**巨型对象（Humongous Object）** 是 G1 GC 的特殊概念：
- **定义**：大小 > Region 大小的一半（50%）
- **8GB 堆**：对象 > 2MB 视为巨型对象
- **特殊处理**：直接分配到连续的 Humongous Region，跳过 TLAB 和年轻代

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         巨型对象分配示意图                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  普通对象 (≤ 2MB)           巨型对象 (> 2MB)                                │
│                                                                             │
│  ┌────────────┐            ┌────────────────────────────────────────┐      │
│  │ Eden Region│            │ StartsHumongous │ ContinuesHumongous │ ...    │
│  │   (4MB)    │            │     (4MB)       │      (4MB)          │        │
│  │  ┌─────┐   │            │ ┌────────────────────────────────────┐│       │
│  │  │ obj │   │            │ │         5MB 巨型对象                ││       │
│  │  └─────┘   │            │ │         (跨越 2 个 Region)         ││       │
│  │            │            │ └────────────────────────────────────┘│       │
│  └────────────┘            └────────────────────────────────────────┘      │
│       ↓                                    ↓                                │
│   TLAB 分配                         直接分配到老年代                          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 源码分析

### 2.1 阈值计算

```cpp
// g1CollectedHeap.cpp:1511
_humongous_object_threshold_in_words = humongous_threshold_for(HeapRegion::GrainWords);

// g1CollectedHeap.hpp:1252-1254
static size_t humongous_threshold_for(size_t region_size) {
  return (region_size / 2);  // Region 的一半
}
```

**8GB 堆计算**：
```
GrainWords = 524,288（HeapWord 数）
threshold = 524,288 / 2 = 262,144 HeapWords
          = 262,144 × 8 bytes = 2,097,152 bytes = 2MB
```

### 2.2 静态变量定义

```cpp
// g1CollectedHeap.hpp:170
static size_t _humongous_object_threshold_in_words;

// g1CollectedHeap.cpp:99
size_t G1CollectedHeap::_humongous_object_threshold_in_words = 0;
```

### 2.3 巨型对象判断

```cpp
// g1CollectedHeap.hpp:1242-1248
static bool is_humongous(size_t word_size) {
  // 注意：是严格大于（>），不是大于等于（>=）
  // 原因：TLAB 上限正好等于阈值，确保：
  //   1. 不会尝试分配巨型 TLAB
  //   2. 不会在 TLAB 中分配巨型对象
  return word_size > _humongous_object_threshold_in_words;
}
```

**边界条件**：
| 对象大小 | 是否巨型 | 分配方式 |
|----------|----------|----------|
| ≤ 262,144 words (2MB) | 否 | TLAB / Eden |
| > 262,144 words (2MB) | **是** | Humongous Region |

### 2.4 填充数组上限

```cpp
// g1CollectedHeap.cpp:1513-1516
// 设置填充数组最大大小，避免创建巨型填充对象
_filler_array_max_size = _humongous_object_threshold_in_words;
```

**目的**：GC 时需要填充空隙，确保填充对象不超过阈值，避免意外创建巨型对象。

---

## 3. 巨型对象占用的 Region 数量

```cpp
// g1CollectedHeap.cpp:319-322
size_t G1CollectedHeap::humongous_obj_size_in_regions(size_t word_size) {
  assert(is_humongous(word_size), "Object must be humongous here");
  return align_up(word_size, HeapRegion::GrainWords) / HeapRegion::GrainWords;
}
```

**示例计算**：

| 对象大小 | 计算过程 | 占用 Region |
|----------|----------|-------------|
| 2.5MB (327,680 words) | ceil(327,680 / 524,288) = 1 | 1 |
| 5MB (655,360 words) | ceil(655,360 / 524,288) = 2 | 2 |
| 10MB (1,310,720 words) | ceil(1,310,720 / 524,288) = 3 | 3 |

---

## 4. Humongous Region 类型

```cpp
// heapRegion.cpp:198-214
void HeapRegion::set_starts_humongous(...) {
  _type.set_starts_humongous();
  _humongous_start_region = this;
}

void HeapRegion::set_continues_humongous(HeapRegion* first_hr) {
  _type.set_continues_humongous();
  _humongous_start_region = first_hr;  // 指向起始 Region
}
```

```
┌─────────────────────────────────────────────────────────────────────────────┐
│              巨型对象跨越多个 Region 的布局                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  5MB 巨型对象分配（需要 2 个 Region）                                        │
│                                                                             │
│  Region N                              Region N+1                           │
│  ┌────────────────────────────────┐   ┌────────────────────────────────┐   │
│  │ type: StartsHumongous         │   │ type: ContinuesHumongous       │   │
│  │ _humongous_start_region: self │   │ _humongous_start_region: N     │   │
│  │                               │   │                                │   │
│  │ ┌───────────────────────────────────────────────────────────────┐ │   │
│  │ │                    5MB 巨型对象                                │ │   │
│  │ │    对象头 │ 实例数据 ...                                       │ │   │
│  │ └───────────────────────────────────────────────────────────────┘ │   │
│  │ ← 4MB →                       │   │← 1MB →│    未使用 (3MB)       │   │
│  └────────────────────────────────┘   └────────────────────────────────┘   │
│                                                                             │
│  注意：ContinuesHumongous Region 中未使用的空间被浪费                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. TLAB 与巨型对象的关系

```cpp
// g1CollectedHeap.cpp:2929-2931
size_t G1CollectedHeap::max_tlab_size() const {
  return align_down(_humongous_object_threshold_in_words, MinObjAlignment);
}
```

**设计原则**：
```
TLAB 最大大小 = 巨型对象阈值（向下对齐）
             = 262,144 words（约 2MB）

原因：
1. TLAB 永远不应该成为巨型对象
2. TLAB 中的对象永远不应该是巨型对象
3. 阈值正好是边界，使用 > 而非 >= 确保边界清晰
```

---

## 6. 为什么阈值是 Region 的一半？

### 6.1 空间利用率考虑

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 场景分析：如果阈值是 Region 大小（100%）                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  4.1MB 对象：                                                               │
│  ┌─────────────────┐  ┌─────────────────┐                                  │
│  │ Region (4MB)    │  │ Region (4MB)    │                                  │
│  │ ███████████████ │  │ █               │  ← 0.1MB 使用，3.9MB 浪费！      │
│  └─────────────────┘  └─────────────────┘                                  │
│  利用率：4MB / 8MB = 50%                                                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│ 场景分析：阈值是 Region 的一半（50%）= 当前设计                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  2.1MB 对象：                                                               │
│  ┌─────────────────┐                                                       │
│  │ Region (4MB)    │                                                       │
│  │ ████████████    │  ← 2.1MB 使用，1.9MB 浪费                             │
│  └─────────────────┘                                                       │
│  利用率：2.1MB / 4MB = 52.5%                                                │
│                                                                             │
│  最坏情况（刚好超过阈值 2MB+1byte）：                                         │
│  利用率 ≈ 50%                                                               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 GC 效率考虑

- **巨型对象不参与年轻代 GC**：避免大对象频繁复制
- **独立回收**：巨型对象可以在并发标记后直接回收
- **50% 阈值**：平衡空间利用率和 GC 效率

---

## 7. 不同堆大小的阈值

| 堆大小 | Region 大小 | 阈值 (bytes) | 阈值 (words) |
|--------|------------|--------------|--------------|
| 1GB | 1MB | 512KB | 65,536 |
| 2GB | 1MB | 512KB | 65,536 |
| 4GB | 2MB | 1MB | 131,072 |
| **8GB** | **4MB** | **2MB** | **262,144** |
| 16GB | 8MB | 4MB | 524,288 |
| 32GB | 16MB | 8MB | 1,048,576 |
| 64GB | 32MB | 16MB | 2,097,152 |

---

## 8. GDB 验证

### 8.1 GDB 脚本

```gdb
# 文件：jvm-md/tmp-file/universe-init/gdb_humongous.txt

b g1CollectedHeap.cpp:1516
commands
  silent
  printf "\n========== Humongous Threshold ==========\n"
  
  # Region 大小
  printf "----- Region Size -----\n"
  printf "HeapRegion::GrainBytes: %lu (%lu MB)\n", HeapRegion::GrainBytes, HeapRegion::GrainBytes/1048576
  printf "HeapRegion::GrainWords: %lu\n", HeapRegion::GrainWords
  
  # 阈值
  printf "\n----- Humongous Threshold -----\n"
  printf "_humongous_object_threshold_in_words: %lu\n", G1CollectedHeap::_humongous_object_threshold_in_words
  printf "Threshold in bytes: %lu (%lu MB)\n", G1CollectedHeap::_humongous_object_threshold_in_words * 8, G1CollectedHeap::_humongous_object_threshold_in_words * 8 / 1048576
  
  # 填充数组上限
  printf "\n----- Filler Array Max Size -----\n"
  printf "_filler_array_max_size: %lu\n", this->_filler_array_max_size
  
  # 验证
  printf "\n----- Verification -----\n"
  printf "GrainWords / 2 = %lu\n", HeapRegion::GrainWords / 2
  printf "Match: %s\n", (G1CollectedHeap::_humongous_object_threshold_in_words == HeapRegion::GrainWords / 2) ? "YES" : "NO"
  
  continue
end
run
```

### 8.2 预期输出

```
========== Humongous Threshold ==========
----- Region Size -----
HeapRegion::GrainBytes: 4194304 (4 MB)
HeapRegion::GrainWords: 524288

----- Humongous Threshold -----
_humongous_object_threshold_in_words: 262144      ✅
Threshold in bytes: 2097152 (2 MB)                ✅

----- Filler Array Max Size -----
_filler_array_max_size: 262144                    ✅

----- Verification -----
GrainWords / 2 = 262144                           ✅
Match: YES                                        ✅
```

---

## 9. 监控巨型对象分配

### 9.1 JVM 参数

```bash
# 打印巨型对象分配日志
-Xlog:gc+humongous=debug

# 输出示例
[0.123s][debug][gc,humongous] G1CollectedHeap::humongous_obj_allocate(size=327680 words) 
    for Thread "main" returning 0x00000007ffc00000
```

### 9.2 JFR 事件

```java
// jdk.G1HeapRegionInformation
// regionType = "Humongous" 表示巨型对象 Region
```

---

## 10. 总结

### 10.1 核心公式

```
humongous_threshold = GrainWords / 2
                    = 524,288 / 2
                    = 262,144 words
                    = 2MB
```

### 10.2 8GB 堆计算结果

| 参数 | 值 | 说明 |
|------|-----|------|
| GrainWords | 524,288 | Region 大小（HeapWord） |
| threshold (words) | **262,144** | 阈值（HeapWord） |
| threshold (bytes) | **2MB** | 阈值（字节） |
| _filler_array_max_size | 262,144 | 填充数组上限 |

### 10.3 设计要点

1. **阈值 = 50%**：平衡空间利用率和 GC 效率
2. **严格大于（>）**：确保边界清晰，TLAB 最大等于阈值
3. **直接老年代**：巨型对象跳过年轻代，避免复制开销

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
| C.3 | initialize_alignments() | ✅ |
| E.1 | WorkGang 创建 | ✅ |
| **E.4** | **巨型对象阈值** | **✅** |
