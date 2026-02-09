# D.4.1 G1Policy 构造函数 - 深度分析

> 源码位置：`g1Policy.cpp:49-71`、`g1Policy.hpp`
> G1Policy 是 G1 GC 的**决策核心**，决定"何时 GC"和"收集哪些 Region"

---

## 1. 功能定位

### 一句话说明
**G1Policy 是 G1 GC 的大脑**，它基于历史数据预测 GC 耗时，动态调整年轻代大小，确保暂停时间不超过用户设定的目标（默认 200ms）。

### 在整体流程中的位置
```
G1CollectedHeap 构造函数
│
├── 初始化列表
│   │
│   └── _g1_policy(new G1Policy(_gc_timer_stw))  ← 我们分析这里
│       │
│       ├── _predictor      ← 预测器（已分析 F.1）
│       ├── _analytics      ← 分析器（存储历史数据）
│       ├── _mmu_tracker    ← MMU 追踪器（暂停时间约束）
│       ├── _ihop_control   ← IHOP 控制器（何时启动并发标记）
│       └── ... 其他组件
│
└── G1Policy::init() 在堆初始化后调用
    └── 计算年轻代大小
```

### G1Policy 的核心职责

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        G1Policy 决策流程                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   输入数据                                                                │
│   ─────────────────────────────────────────────────────────────────────  │
│   • 历史 GC 数据：每次 GC 的耗时、复制字节数、扫描卡片数等                 │
│   • 实时数据：待处理卡片数、记忆集长度、分配速率等                         │
│   • 用户配置：MaxGCPauseMillis (200ms)、MaxHeapSize (8GB) 等              │
│                                                                          │
│   决策过程                                                                │
│   ─────────────────────────────────────────────────────────────────────  │
│   1. G1Analytics 存储历史数据（TruncatedSeq 滑动窗口）                    │
│   2. G1Predictions 基于衰减平均预测未来                                   │
│   3. 根据预测计算：可以收集多少个 Region 而不超时                         │
│                                                                          │
│   输出决策                                                                │
│   ─────────────────────────────────────────────────────────────────────  │
│   • _young_list_target_length：年轻代目标大小                             │
│   • CSet（收集集合）：这次 GC 要收集哪些 Region                           │
│   • 是否启动并发标记                                                      │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 构造函数源码分析

```cpp
// g1Policy.cpp:49-71
G1Policy::G1Policy(STWGCTimer* gc_timer) :
  // ===== 1. 预测器 =====
  _predictor(G1ConfidencePercent / 100.0),  // sigma = 50/100 = 0.5
  
  // ===== 2. 分析器（存储历史数据）=====
  _analytics(new G1Analytics(&_predictor)),
  
  // ===== 3. RemSet 追踪策略 =====
  _remset_tracker(),
  
  // ===== 4. MMU 追踪器（暂停时间约束）=====
  _mmu_tracker(new G1MMUTrackerQueue(
      GCPauseIntervalMillis / 1000.0,  // 201ms → 0.201s
      MaxGCPauseMillis / 1000.0)),     // 200ms → 0.200s
  
  // ===== 5. 老年代分配追踪 =====
  _old_gen_alloc_tracker(),
  
  // ===== 6. IHOP 控制器 =====
  _ihop_control(create_ihop_control(&_old_gen_alloc_tracker, &_predictor)),
  
  // ===== 7. JMX 计数器 =====
  _policy_counters(new GCPolicyCounters("GarbageFirst", 1, 2)),
  
  // ===== 8. 年轻代长度控制 =====
  _young_list_fixed_length(0),
  
  // ===== 9. 存活率预测组 =====
  _short_lived_surv_rate_group(new SurvRateGroup()),  // Eden 区存活率
  _survivor_surv_rate_group(new SurvRateGroup()),     // Survivor 区存活率
  
  // ===== 10. 预留空间 =====
  _reserve_factor((double) G1ReservePercent / 100.0), // 10% → 0.1
  _reserve_regions(0),
  
  // ===== 11. 其他初始化 =====
  _rs_lengths_prediction(0),
  _initial_mark_to_mixed(),
  _collection_set(NULL),
  _g1h(NULL),
  
  // ===== 12. GC 阶段计时器 =====
  _phase_times(new G1GCPhaseTimes(gc_timer, ParallelGCThreads)),
  
  // ===== 13. Survivor 策略 =====
  _tenuring_threshold(MaxTenuringThreshold),  // 15
  _max_survivor_regions(0),
  _survivors_age_table(true),
  _collection_pause_end_millis(os::javaTimeNanos() / NANOSECS_PER_MILLISEC)
{
  // 构造函数体为空，所有初始化在初始化列表完成
}
```

---

## 3. 核心组件详解

### 3.1 G1Predictions 预测器（已分析 F.1）

```cpp
_predictor(G1ConfidencePercent / 100.0)  // sigma = 0.5
```

```
预测公式：prediction = davg + sigma × stddev_estimate

作用：给预测值加一个"安全余量"
  • sigma = 0：只用平均值（冒险）
  • sigma = 0.5：平均值 + 0.5倍标准差（默认，平衡）
  • sigma = 1.0：平均值 + 1倍标准差（保守）
```

### 3.2 G1Analytics 分析器

```cpp
_analytics(new G1Analytics(&_predictor))
```

```
G1Analytics 是"数据仓库"，存储 15+ 个历史序列：

┌─────────────────────────────────────────────────────────────────────────┐
│                    G1Analytics 内部数据结构                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  TruncatedSeq 序列（滑动窗口大小 = 10）                                   │
│  ─────────────────────────────────────────────────────────────────────   │
│                                                                          │
│  GC 耗时相关：                                                           │
│  • _recent_gc_times_ms          最近 GC 耗时                             │
│  • _concurrent_mark_remark_times_ms    并发标记 Remark 耗时              │
│  • _concurrent_mark_cleanup_times_ms   并发标记 Cleanup 耗时             │
│                                                                          │
│  分配速率：                                                              │
│  • _alloc_rate_ms_seq           每毫秒分配字节数                         │
│                                                                          │
│  RSet 处理成本：                                                         │
│  • _cost_per_card_ms_seq        每张卡处理成本                           │
│  • _cost_scan_hcc_seq           热卡缓存扫描成本                         │
│  • _cost_per_entry_ms_seq       每条 RSet 条目扫描成本                   │
│  • _young_cards_per_entry_ratio_seq    年轻代卡片/条目比                 │
│  • _mixed_cards_per_entry_ratio_seq    混合 GC 卡片/条目比               │
│                                                                          │
│  对象复制成本：                                                          │
│  • _cost_per_byte_ms_seq        每字节复制成本                           │
│  • _cost_per_byte_ms_during_cm_seq    并发标记期间复制成本               │
│                                                                          │
│  其他开销：                                                              │
│  • _constant_other_time_ms_seq        固定开销                           │
│  • _young_other_cost_per_region_ms_seq    年轻代其他开销/Region          │
│  • _non_young_other_cost_per_region_ms_seq    老年代其他开销/Region      │
│                                                                          │
│  预测输入：                                                              │
│  • _pending_cards_seq           待处理卡片数                             │
│  • _rs_lengths_seq              RSet 长度                                │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.3 G1MMUTracker - MMU 追踪器

```cpp
_mmu_tracker(new G1MMUTrackerQueue(
    GCPauseIntervalMillis / 1000.0,  // 201ms → 0.201s (时间窗口)
    MaxGCPauseMillis / 1000.0))      // 200ms → 0.200s (最大暂停)
```

```
MMU = Minimum Mutator Utilisation（最小应用运行比例）

┌─────────────────────────────────────────────────────────────────────────┐
│                         MMU 概念图解                                      │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  时间窗口 = 201ms                                                        │
│  最大 GC 时间 = 200ms                                                    │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │           201ms 时间窗口                                            │ │
│  │  ┌──────────────────────────────────────┐┌────────────────────────┐│ │
│  │  │        应用运行时间 ≥ 1ms            ││   GC 暂停 ≤ 200ms     ││ │
│  │  │        (Mutator Time)                ││   (GC Time)           ││ │
│  │  └──────────────────────────────────────┘└────────────────────────┘│ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  MMU = 应用运行时间 / 时间窗口 ≥ 1/201 ≈ 0.5%                           │
│                                                                          │
│  为什么 GCPauseIntervalMillis = MaxGCPauseMillis + 1?                   │
│  ─────────────────────────────────────────────────────────────────────   │
│  • 给 G1 最大灵活性                                                      │
│  • 允许在任意 201ms 窗口内有 200ms 的 GC                                 │
│  • 实际 MMU 约束非常宽松                                                 │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.4 G1IHOPControl - IHOP 控制器

```cpp
_ihop_control(create_ihop_control(&_old_gen_alloc_tracker, &_predictor))
```

```
IHOP = Initiating Heap Occupancy Percent（启动并发标记的堆占用率阈值）

┌─────────────────────────────────────────────────────────────────────────┐
│                        IHOP 决策流程                                      │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  问题：何时启动并发标记？                                                 │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                                                                   │   │
│  │      老年代占用率                                                  │   │
│  │      ────────────────────────────────────────────────────────────│   │
│  │      0%          45%              80%                     100%   │   │
│  │      ├───────────┼────────────────┼───────────────────────┤      │   │
│  │                  ↑                ↑                               │   │
│  │           IHOP 阈值         需要预留空间                          │   │
│  │        (启动并发标记)       (给晋升对象)                          │   │
│  │                                                                   │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│  两种 IHOP 模式：                                                        │
│  ─────────────────────────────────────────────────────────────────────   │
│  1. 静态模式 (-XX:InitiatingHeapOccupancyPercent=45)                    │
│     • 固定阈值，老年代占用 > 45% 就启动                                  │
│                                                                          │
│  2. 自适应模式（默认）                                                   │
│     • 根据分配速率和标记耗时动态调整                                     │
│     • 目标：在老年代满之前完成标记                                       │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.5 SurvRateGroup - 存活率预测组

```cpp
_short_lived_surv_rate_group(new SurvRateGroup()),  // Eden 对象
_survivor_surv_rate_group(new SurvRateGroup()),     // Survivor 对象
```

```
存活率预测：预测不同年龄对象的存活概率

┌─────────────────────────────────────────────────────────────────────────┐
│                       存活率预测                                          │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  年龄      0       1       2       3       4       ...      15          │
│  存活率   80%     60%     50%     40%     35%     ...      10%         │
│                                                                          │
│  用途：                                                                  │
│  • 预测年轻代 GC 需要复制多少字节                                        │
│  • 决定是否应该晋升（年龄 > _tenuring_threshold）                        │
│                                                                          │
│  两个 SurvRateGroup：                                                    │
│  • _short_lived_surv_rate_group：Eden → Survivor 的存活率                │
│  • _survivor_surv_rate_group：Survivor → Survivor 的存活率               │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.6 G1GCPhaseTimes - GC 阶段计时

```cpp
_phase_times(new G1GCPhaseTimes(gc_timer, ParallelGCThreads))
```

```
记录 GC 各阶段耗时，用于：
1. 日志输出（-Xlog:gc*）
2. JFR 事件
3. 预测模型更新

主要阶段：
• ExtRootScan - 外部根扫描
• UpdateRS - 更新记忆集
• ScanRS - 扫描记忆集  
• ObjCopy - 对象复制
• Termination - 终止阶段
• ... 等 20+ 个阶段
```

---

## 4. GDB 验证 ✅

### 4.1 GDB 验证结果

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
断点位置：g1Policy.cpp:71（构造函数完成后）

========== G1Policy 构造函数完成后 ==========
this = 0x7ffff0038ab0

========== 1. G1Predictions 预测器 ==========
_predictor._sigma = 0.500000 ✅

========== 2. G1Analytics 分析器 ==========
_analytics = 0x7ffff0038d10
_analytics->_predictor = 0x7ffff0038ab8  (指向 this->_predictor)
TruncatedSeqLength = 10 (滑动窗口大小)

========== 3. G1MMUTracker ==========
_mmu_tracker = 0x7ffff003a240
_mmu_tracker->_time_slice = 0.201000 sec ✅  (GCPauseIntervalMillis)
_mmu_tracker->_max_gc_time = 0.200000 sec ✅  (MaxGCPauseMillis)

========== 4. G1IHOPControl ==========
_ihop_control = 0x7ffff003a6a0

========== 5. GCPolicyCounters ==========
_policy_counters = 0x7ffff003a8d0

========== 6. 年轻代长度控制 ==========
_young_list_fixed_length = 0 ✅ (自适应模式)

========== 7. 存活率组 ==========
_short_lived_surv_rate_group = 0x7ffff003ae20
_survivor_surv_rate_group = 0x7ffff003b030

========== 8. 预留因子 ==========
_reserve_factor = 0.100000 ✅ (G1ReservePercent=10 → 0.1)
_reserve_regions = 0 (稍后在堆扩展时设置)

========== 9. GC 阶段计时器 ==========
_phase_times = 0x7ffff003b240

========== 10. Survivor 策略 ==========
_tenuring_threshold = 15 ✅ (MaxTenuringThreshold)
_max_survivor_regions = 0 (稍后计算)

========== 关键参数验证 ==========
G1ConfidencePercent = 50 ✅
GCPauseIntervalMillis = 201 ms ✅
MaxGCPauseMillis = 200 ms ✅
G1ReservePercent = 10 ✅
MaxTenuringThreshold = 15 ✅
```

### 4.2 验证总结

```
┌─────────────────────────────────────────────────────────────────────┐
│                    G1Policy 构造函数验证结果                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  组件                              状态                              │
│  ──────────────────────────────────────────────────────────────────  │
│  G1Predictions._sigma              0.5 ✅                            │
│  G1Analytics                       已创建 ✅                         │
│  G1MMUTracker._time_slice          0.201s ✅                         │
│  G1MMUTracker._max_gc_time         0.200s ✅                         │
│  G1IHOPControl                     已创建 ✅                         │
│  _reserve_factor                   0.1 (10%) ✅                      │
│  _tenuring_threshold               15 ✅                             │
│                                                                      │
│  年轻代控制（构造时）                                                │
│  ──────────────────────────────────────────────────────────────────  │
│  _young_list_fixed_length          0 (自适应模式)                    │
│  _young_list_target_length         未初始化（init() 中设置）         │
│  _young_list_max_length            未初始化（init() 中设置）         │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 5. 组件关系图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           G1Policy 组件关系图                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│                            ┌──────────────────┐                              │
│                            │    G1Policy      │                              │
│                            │   (决策核心)      │                              │
│                            └────────┬─────────┘                              │
│                                     │                                        │
│         ┌───────────────────────────┼───────────────────────────┐            │
│         │                           │                           │            │
│         ▼                           ▼                           ▼            │
│  ┌──────────────┐           ┌──────────────┐           ┌──────────────┐      │
│  │ G1Predictions │           │  G1Analytics │           │ G1MMUTracker │      │
│  │  (预测器)     │◄─────────│   (数据仓库)  │           │  (MMU约束)   │      │
│  │ sigma=0.5    │  使用      │ 15+序列       │           │ 200ms/201ms  │      │
│  └──────────────┘           └──────────────┘           └──────────────┘      │
│         │                           │                           │            │
│         │ 预测                      │ 历史数据                  │ 时间约束    │
│         │                           │                           │            │
│         └───────────────────────────┼───────────────────────────┘            │
│                                     │                                        │
│                                     ▼                                        │
│                     ┌───────────────────────────────┐                        │
│                     │     年轻代大小决策             │                        │
│                     │  _young_list_target_length    │                        │
│                     └───────────────────────────────┘                        │
│                                     │                                        │
│         ┌───────────────────────────┼───────────────────────────┐            │
│         │                           │                           │            │
│         ▼                           ▼                           ▼            │
│  ┌──────────────┐           ┌──────────────┐           ┌──────────────┐      │
│  │G1IHOPControl │           │ SurvRateGroup │           │G1GCPhaseTimes│      │
│  │ (IHOP控制)   │           │ ×2 (存活率)   │           │ (阶段计时)   │      │
│  │ 何时并发标记  │           │ Eden/Survivor │           │ 20+阶段     │      │
│  └──────────────┘           └──────────────┘           └──────────────┘      │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 6. init() 方法概览

G1Policy 构造后，还需要调用 `init()` 完成初始化：

```cpp
// g1Policy.cpp:79-143
void G1Policy::init(G1CollectedHeap* g1h, G1CollectionSet* collection_set) {
  _g1h = g1h;
  _collection_set = collection_set;
  
  // 1. 固定模式：设置固定年轻代长度
  if (!adaptive_young_list_length()) {
    _young_list_fixed_length = _young_gen_sizer.min_desired_young_length();
  }
  
  // 2. 调整年轻代最大值（不超过堆总大小）
  _young_gen_sizer.adjust_max_new_size(_g1h->max_regions());
  
  // 3. 初始化空闲 Region 计数
  _free_regions_at_end_of_collection = _g1h->num_free_regions();
  
  // 4. 计算年轻代目标长度【核心】
  update_young_list_max_and_target_length();
  
  // 5. 开始增量构建收集集
  _collection_set->start_incremental_building();
}
```

init() 完成后的状态（8GB 堆）：
```
_young_list_target_length = 102  (目标：102 个 Region = 408MB)
_young_list_max_length = 108     (当前最大：108 个 Region)
_young_list_fixed_length = 0     (自适应模式)
```

---

## 7. 关键数值汇总

| 字段 | 值 | 来源 |
|------|-----|------|
| _predictor._sigma | 0.5 | G1ConfidencePercent / 100 |
| _mmu_tracker._time_slice | 0.201s | GCPauseIntervalMillis |
| _mmu_tracker._max_gc_time | 0.200s | MaxGCPauseMillis |
| _reserve_factor | 0.1 | G1ReservePercent / 100 |
| _tenuring_threshold | 15 | MaxTenuringThreshold |
| TruncatedSeqLength | 10 | 滑动窗口大小（硬编码） |

---

## 8. 总结

### 8.1 G1Policy 是什么？

```
G1Policy = 预测器 + 分析器 + 约束器 + 决策器

• G1Predictions：预测 GC 耗时（衰减平均 + 置信区间）
• G1Analytics：存储历史数据（15+ 个 TruncatedSeq）
• G1MMUTracker：暂停时间约束（200ms/201ms）
• G1IHOPControl：并发标记触发时机
• SurvRateGroup：存活率预测
• G1GCPhaseTimes：阶段计时统计
```

### 8.2 为什么这样设计？

```
设计目标：在不超过 200ms 暂停的前提下，最大化吞吐量

实现方式：
1. 记录每次 GC 的详细数据
2. 用衰减平均预测未来
3. 动态调整年轻代大小
4. 精确控制每次 GC 的工作量
```

### 8.3 下一步

建议继续学习：
- **F.2** `G1Analytics` - 详细了解 15+ 个历史序列
- **F.3** `G1MMUTracker` - MMU 约束的实现细节
- **F.4** `G1IHOPControl` - 自适应 IHOP 算法

---

## 待分析节点更新

| 节点 | 主题 | 状态 |
|------|------|------|
| B.1.1 | ParallelGCThreads 计算算法 | ✅ |
| F.1 | G1Predictions 预测器 | ✅ |
| E.5.1 | RefToScanQueue 工作窃取队列 | ✅ |
| **D.4.1** | **G1Policy 构造函数** | **✅** |
