# F.4 G1IHOPControl - IHOP 控制器深度分析

> 源码位置：`g1IHOPControl.hpp`、`g1IHOPControl.cpp`
> IHOP = Initiating Heap Occupancy Percent（启动并发标记的堆占用率阈值）

---

## 1. 功能定位

### 一句话说明
**G1IHOPControl 决定"何时启动并发标记"**，确保在老年代填满之前完成标记，避免 Full GC。

### 为什么需要 IHOP？

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     IHOP 解决的问题                                       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  问题场景：老年代逐渐填满                                                 │
│  ─────────────────────────────────────────────────────────────────────   │
│                                                                          │
│  时间轴：                                                                │
│  ──────────────────────────────────────────────────────────────────────  │
│                                                                          │
│       老年代占用率                                                        │
│       100% ┼─────────────────────────────────────●─────── Full GC！      │
│            │                                    ╱                        │
│        80% │                                  ╱                          │
│            │                                ╱                            │
│  ▶ IHOP ▶ │- - - - - - - - - ●- - - - - -╱- - - - - - - - 启动并发标记   │
│        45% │                  │         ╱                                │
│            │                  │       ╱                                  │
│        20% │                  │     ╱                                    │
│            │                  │   ╱                                      │
│         0% ┼──────────────────●─╱────────────────────────────────────    │
│            t0               t1  t2                    t3                 │
│                                                                          │
│  如果太晚启动并发标记：                                                   │
│  • 标记还没完成，老年代就满了                                             │
│  • 触发 Full GC（STW 几秒甚至几十秒）                                     │
│                                                                          │
│  IHOP 的作用：                                                           │
│  • 预测何时启动并发标记                                                   │
│  • 确保标记完成前老年代不会满                                             │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 两种模式

### 2.1 静态模式 vs 自适应模式

```cpp
// g1Policy.cpp:787-798
G1IHOPControl* G1Policy::create_ihop_control(...) {
    if (G1UseAdaptiveIHOP) {  // 默认 true
        return new G1AdaptiveIHOPControl(...);  // 自适应
    } else {
        return new G1StaticIHOPControl(...);    // 静态
    }
}
```

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    静态 vs 自适应 IHOP                                    │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  静态模式 (G1StaticIHOPControl)                                          │
│  ─────────────────────────────────────────────────────────────────────   │
│  • 阈值 = InitiatingHeapOccupancyPercent × target_occupancy / 100       │
│  • 例如：45% × 8GB = 3.6GB                                               │
│  • 老年代占用 > 3.6GB 时启动并发标记                                      │
│  • 简单但不智能                                                          │
│                                                                          │
│  自适应模式 (G1AdaptiveIHOPControl)【默认】                               │
│  ─────────────────────────────────────────────────────────────────────   │
│  • 根据历史数据动态调整阈值                                               │
│  • 考虑因素：                                                            │
│    - 分配速率（应用每秒向老年代分配多少）                                 │
│    - 标记耗时（并发标记需要多长时间）                                     │
│    - 年轻代大小（标记期间年轻代会晋升多少）                               │
│  • 公式：threshold = actual_target - predicted_needed                   │
│  • 更智能，能适应应用负载变化                                             │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.2 类继承结构

```
G1IHOPControl（抽象基类）
│
│  • _initial_ihop_percent = 45（初始阈值百分比）
│  • _target_occupancy（目标占用量，后续更新）
│  • get_conc_mark_start_threshold()（获取阈值）
│
├── G1StaticIHOPControl（静态模式）
│   │
│   │  阈值 = _initial_ihop_percent × _target_occupancy / 100
│   │
│   └── 简单固定值
│
└── G1AdaptiveIHOPControl（自适应模式）【默认】
    │
    │  • _heap_reserve_percent = 10（预留 10%）
    │  • _heap_waste_percent = 5（浪费 5%）
    │  • _marking_times_s（标记时间序列）
    │  • _allocation_rate_s（分配速率序列）
    │
    └── 阈值 = actual_target - predicted_needed
```

---

## 3. 自适应 IHOP 算法详解

### 3.1 核心公式

```cpp
// g1IHOPControl.cpp:123-144
size_t G1AdaptiveIHOPControl::get_conc_mark_start_threshold() {
    if (have_enough_data_for_prediction()) {
        // 预测标记时间
        double pred_marking_time = _predictor->get_new_prediction(&_marking_times_s);
        // 预测分配速率
        double pred_promotion_rate = _predictor->get_new_prediction(&_allocation_rate_s);
        // 预测标记期间需要的空间
        size_t pred_promotion_size = pred_marking_time * pred_promotion_rate;
        
        // 总共需要预留的空间
        size_t predicted_needed = pred_promotion_size + _last_unrestrained_young_size;
        
        // 计算阈值
        size_t internal_threshold = actual_target_threshold();
        return (predicted_needed < internal_threshold) ?
               internal_threshold - predicted_needed : 0;
    } else {
        // 样本不足，使用初始值
        return _initial_ihop_percent * _target_occupancy / 100.0;
    }
}
```

### 3.2 公式图解

```
┌─────────────────────────────────────────────────────────────────────────┐
│                   自适应 IHOP 阈值计算                                    │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  目标：确保并发标记完成时，老年代不会溢出                                 │
│                                                                          │
│  堆内存布局（8GB 堆）：                                                   │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                        8GB 总堆                                     │ │
│  ├────────────────────────────────────────────────────────────────────┤ │
│  │                                                                     │ │
│  │  ┌──────────────────┐ ┌─────────┐ ┌─────────┐ ┌─────────────────┐ │ │
│  │  │   可用空间        │ │ 预留10% │ │ 浪费5% │ │ 年轻代 + 晋升  │ │ │
│  │  │   (IHOP 阈值)     │ │  800MB  │ │ 400MB  │ │   需要的空间   │ │ │
│  │  └──────────────────┘ └─────────┘ └─────────┘ └─────────────────┘ │ │
│  │                                                                     │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  计算步骤：                                                              │
│  ─────────────────────────────────────────────────────────────────────   │
│                                                                          │
│  1. actual_target = min(                                                │
│       heap × (100 - reserve - waste) / 100,                             │
│       target × (100 - waste) / 100                                      │
│     )                                                                    │
│     = min(8GB × 85%, 8GB × 95%)                                         │
│     = 6.8GB                                                              │
│                                                                          │
│  2. predicted_needed = pred_marking_time × pred_alloc_rate + young_size │
│     假设：                                                               │
│     - 标记时间 = 2 秒                                                    │
│     - 分配速率 = 500MB/秒                                                │
│     - 年轻代 = 1GB                                                       │
│     = 2 × 500MB + 1GB = 2GB                                             │
│                                                                          │
│  3. threshold = actual_target - predicted_needed                        │
│     = 6.8GB - 2GB = 4.8GB                                               │
│                                                                          │
│  结论：当老年代占用 > 4.8GB 时，启动并发标记                             │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.3 样本收集

```cpp
// 需要至少 3 个样本才能启用自适应
bool G1AdaptiveIHOPControl::have_enough_data_for_prediction() const {
    return (_marking_times_s.num() >= G1AdaptiveIHOPNumInitialSamples) &&  // 3
           (_allocation_rate_s.num() >= G1AdaptiveIHOPNumInitialSamples);  // 3
}

// 样本不足时，使用静态值
// threshold = 45% × target_occupancy = 45% × 8GB = 3.6GB
```

---

## 4. GDB 验证 ✅

### 4.1 GDB 验证结果

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
断点位置：g1Policy.cpp:71（G1Policy 构造后）

========== JVM 参数 ==========
G1UseAdaptiveIHOP = 1 ✅ (默认启用自适应)
InitiatingHeapOccupancyPercent = 45 ✅ (初始 IHOP 阈值)
G1ReservePercent = 10 ✅ (预留百分比)
G1HeapWastePercent = 5 ✅ (浪费百分比)
G1AdaptiveIHOPNumInitialSamples = 3 ✅ (自适应所需样本数)

========== IHOP 基类字段 ==========
_initial_ihop_percent = 45.0 ✅
_target_occupancy = 0 (初始为0，堆扩展时更新)

========== 自适应 IHOP 特有字段 ==========
_heap_reserve_percent = 10 ✅
_heap_waste_percent = 5 ✅
_marking_times_s (窗口大小=10, alpha=0.95)
_allocation_rate_s (窗口大小=10, alpha=0.95)
```

### 4.2 验证总结

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    G1IHOPControl GDB 验证结果                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  模式选择                                                                │
│  ──────────────────────────────────────────────────────────────────────  │
│  G1UseAdaptiveIHOP = true → G1AdaptiveIHOPControl ✅                     │
│                                                                          │
│  参数验证                                                                │
│  ──────────────────────────────────────────────────────────────────────  │
│  InitiatingHeapOccupancyPercent    45% ✅                                │
│  G1ReservePercent                  10% ✅                                │
│  G1HeapWastePercent                5% ✅                                 │
│  G1AdaptiveIHOPNumInitialSamples   3 ✅                                  │
│                                                                          │
│  初始状态                                                                │
│  ──────────────────────────────────────────────────────────────────────  │
│  _target_occupancy = 0（堆扩展时更新）                                   │
│  _marking_times_s 样本数 = 0（还没发生过并发标记）                       │
│  _allocation_rate_s 样本数 = 0（还没收集过分配速率）                     │
│                                                                          │
│  初始阈值计算                                                            │
│  ──────────────────────────────────────────────────────────────────────  │
│  样本不足时：threshold = 45% × 8GB = 3.6GB                               │
│  当老年代占用 > 3.6GB 时，启动并发标记                                   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 5. 工作流程

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      IHOP 工作流程                                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  阶段 1：初始化                                                          │
│  ─────────────────────────────────────────────────────────────────────   │
│  • _initial_ihop_percent = 45%                                          │
│  • _target_occupancy = 0（等待堆扩展）                                   │
│  • 样本数 = 0                                                            │
│                                                                          │
│  阶段 2：堆扩展后                                                        │
│  ─────────────────────────────────────────────────────────────────────   │
│  • update_target_occupancy(8GB)                                          │
│  • 此时 threshold = 45% × 8GB = 3.6GB                                   │
│                                                                          │
│  阶段 3：每次 GC 后更新                                                  │
│  ─────────────────────────────────────────────────────────────────────   │
│  • update_allocation_info(分配时间, 年轻代大小)                          │
│    → 记录老年代分配速率                                                  │
│  • update_marking_length(标记耗时)                                       │
│    → 记录并发标记时间（如果刚完成标记）                                  │
│                                                                          │
│  阶段 4：检查是否需要启动并发标记                                        │
│  ─────────────────────────────────────────────────────────────────────   │
│  • G1Policy::need_to_start_conc_mark() 调用                             │
│  • threshold = get_conc_mark_start_threshold()                          │
│  • if (老年代占用 > threshold) → 启动并发标记                           │
│                                                                          │
│  阶段 5：自适应调整                                                      │
│  ─────────────────────────────────────────────────────────────────────   │
│  • 样本数 >= 3 后，启用自适应预测                                        │
│  • 根据分配速率和标记耗时动态调整阈值                                    │
│  • 分配速率高 → 阈值降低（更早启动标记）                                 │
│  • 分配速率低 → 阈值升高（延迟启动标记）                                 │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 6. 日志输出

### 6.1 启用 IHOP 日志

```bash
java -Xms8g -Xmx8g -XX:+UseG1GC -Xlog:gc+ihop=debug ...
```

### 6.2 日志示例

```
[gc,ihop] Target occupancy update: old: 0B, new: 8589934592B
[gc,ihop] Basic information (value update), threshold: 3865470566B (45.00%), 
          target occupancy: 8589934592B, current occupancy: 524288000B,
          recent allocation size: 104857600B, recent allocation duration: 50.00ms,
          recent old gen allocation rate: 2097152000.00B/s, 
          recent marking phase length: 2000.00ms
[gc,ihop] Adaptive IHOP information (value update), threshold: 4831838208B (70.82%),
          internal target occupancy: 6821068390B, occupancy: 524288000B,
          additional buffer size: 428867584B, 
          predicted old gen allocation rate: 1500000000.00B/s,
          predicted marking phase length: 1800.00ms, prediction active: true
```

---

## 7. 关键参数说明

| 参数 | 默认值 | 说明 |
|------|--------|------|
| G1UseAdaptiveIHOP | true | 是否启用自适应 IHOP |
| InitiatingHeapOccupancyPercent | 45 | 初始 IHOP 阈值（%） |
| G1ReservePercent | 10 | 预留空间百分比（防晋升失败） |
| G1HeapWastePercent | 5 | 不可用空间百分比（碎片等） |
| G1AdaptiveIHOPNumInitialSamples | 3 | 启用自适应所需的样本数 |

---

## 8. 总结

### 8.1 G1IHOPControl 是什么？

```
IHOP = Initiating Heap Occupancy Percent

决定"何时启动并发标记"：
• 太早启动：浪费 CPU（频繁标记）
• 太晚启动：老年代满了 → Full GC

两种模式：
• 静态：固定阈值 = 45% × target
• 自适应：动态调整 = actual_target - predicted_needed

自适应考虑因素：
• 分配速率（应用向老年代分配的速度）
• 标记耗时（并发标记需要多长时间）
• 年轻代大小（标记期间会晋升多少）
```

### 8.2 关键数值（8GB 堆）

| 阶段 | 阈值 | 说明 |
|------|------|------|
| 初始 | 3.6GB | 45% × 8GB |
| 自适应后 | 动态 | 根据分配速率和标记耗时调整 |

### 8.3 核心方法

| 方法 | 作用 |
|------|------|
| get_conc_mark_start_threshold() | 获取当前阈值 |
| update_allocation_info() | 更新分配速率 |
| update_marking_length() | 更新标记耗时 |
| update_target_occupancy() | 更新目标占用量 |

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
| **F.4** | **G1IHOPControl** | **✅** |
