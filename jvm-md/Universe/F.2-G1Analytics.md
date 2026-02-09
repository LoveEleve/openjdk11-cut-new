# F.2 G1Analytics 分析器 - 深度分析

> 源码位置：`g1Analytics.cpp`、`g1Analytics.hpp`
> G1Analytics 是 G1 GC 的"数据仓库"，存储所有历史数据供预测使用

---

## 1. 功能定位

### 一句话说明
**G1Analytics 是 G1 的历史数据存储中心**，记录每次 GC 的各项成本数据，供 G1Predictions 预测器计算未来 GC 耗时。

### 在整体流程中的位置
```
G1Policy（决策核心）
│
├── G1Predictions（预测器）
│   └── get_new_prediction(seq)  ← 从 G1Analytics 的序列中预测
│
└── G1Analytics（数据仓库）← 我们分析这里
    │
    ├── 17 个 TruncatedSeq 序列
    │   ├── GC 耗时相关（3 个）
    │   ├── 成本预测相关（10 个）
    │   └── 输入数据相关（4 个）
    │
    └── 默认值表
        └── 按 ParallelGCThreads 分级（8 档）
```

### 核心职责

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        G1Analytics 工作流程                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  每次 GC 结束                                                            │
│  ─────────────────────────────────────────────────────────────────────   │
│  1. 收集本次 GC 的各项数据：                                              │
│     • 扫描了多少张卡片？                                                  │
│     • 复制了多少字节？                                                    │
│     • 各阶段耗时多少？                                                    │
│                                                                          │
│  2. 计算单位成本：                                                        │
│     • cost_per_card_ms = 扫描卡片耗时 / 卡片数                           │
│     • cost_per_byte_ms = 复制耗时 / 复制字节数                           │
│     • ... 等                                                             │
│                                                                          │
│  3. 添加到对应的 TruncatedSeq：                                           │
│     • _cost_per_card_ms_seq->add(cost_per_card_ms)                       │
│     • TruncatedSeq 自动计算衰减平均                                       │
│                                                                          │
│  下次 GC 前                                                               │
│  ─────────────────────────────────────────────────────────────────────   │
│  1. G1Policy 需要预测 GC 耗时                                             │
│  2. 调用 analytics->predict_xxx()                                        │
│  3. G1Analytics 委托给 G1Predictions：                                    │
│     return _predictor->get_new_prediction(seq)                           │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 构造函数源码分析

```cpp
// g1Analytics.cpp:72-116
G1Analytics::G1Analytics(const G1Predictions* predictor) :
    _predictor(predictor),
    
    // ===== GC 耗时序列 =====
    _recent_gc_times_ms(new TruncatedSeq(NumPrevPausesForHeuristics)),  // 10
    _concurrent_mark_remark_times_ms(new TruncatedSeq(NumPrevPausesForHeuristics)),
    _concurrent_mark_cleanup_times_ms(new TruncatedSeq(NumPrevPausesForHeuristics)),
    
    // ===== 分配速率 =====
    _alloc_rate_ms_seq(new TruncatedSeq(TruncatedSeqLength)),  // 10
    _prev_collection_pause_end_ms(0.0),
    
    // ===== RSet 处理成本 =====
    _rs_length_diff_seq(new TruncatedSeq(TruncatedSeqLength)),
    _cost_per_card_ms_seq(new TruncatedSeq(TruncatedSeqLength)),
    _cost_scan_hcc_seq(new TruncatedSeq(TruncatedSeqLength)),
    _young_cards_per_entry_ratio_seq(new TruncatedSeq(TruncatedSeqLength)),
    _mixed_cards_per_entry_ratio_seq(new TruncatedSeq(TruncatedSeqLength)),
    _cost_per_entry_ms_seq(new TruncatedSeq(TruncatedSeqLength)),
    _mixed_cost_per_entry_ms_seq(new TruncatedSeq(TruncatedSeqLength)),
    
    // ===== 对象复制成本 =====
    _cost_per_byte_ms_seq(new TruncatedSeq(TruncatedSeqLength)),
    _cost_per_byte_ms_during_cm_seq(new TruncatedSeq(TruncatedSeqLength)),
    
    // ===== 其他开销 =====
    _constant_other_time_ms_seq(new TruncatedSeq(TruncatedSeqLength)),
    _young_other_cost_per_region_ms_seq(new TruncatedSeq(TruncatedSeqLength)),
    _non_young_other_cost_per_region_ms_seq(new TruncatedSeq(TruncatedSeqLength)),
    
    // ===== 预测输入 =====
    _pending_cards_seq(new TruncatedSeq(TruncatedSeqLength)),
    _rs_lengths_seq(new TruncatedSeq(TruncatedSeqLength)),
    
    // ===== GC 结束时间追踪 =====
    _recent_prev_end_times_for_all_gcs_sec(new TruncatedSeq(NumPrevPausesForHeuristics)),
    _recent_avg_pause_time_ratio(0.0),
    _last_pause_time_ratio(0.0)
{
    // 初始化种子值
    _recent_prev_end_times_for_all_gcs_sec->add(os::elapsedTime());
    _prev_collection_pause_end_ms = os::elapsedTime() * 1000.0;
    
    // 计算默认值索引：ParallelGCThreads=13 → index=7
    int index = MIN2(ParallelGCThreads - 1, 7u);
    
    // 用默认值初始化各序列
    _rs_length_diff_seq->add(rs_length_diff_defaults[index]);
    _cost_per_card_ms_seq->add(cost_per_card_ms_defaults[index]);
    _cost_scan_hcc_seq->add(0.0);
    _young_cards_per_entry_ratio_seq->add(young_cards_per_entry_ratio_defaults[index]);
    _cost_per_entry_ms_seq->add(cost_per_entry_ms_defaults[index]);
    _cost_per_byte_ms_seq->add(cost_per_byte_ms_defaults[index]);
    _constant_other_time_ms_seq->add(constant_other_time_ms_defaults[index]);
    _young_other_cost_per_region_ms_seq->add(young_other_cost_per_region_ms_defaults[index]);
    _non_young_other_cost_per_region_ms_seq->add(non_young_other_cost_per_region_ms_defaults[index]);
    
    // 并发标记时间初始估计
    _concurrent_mark_remark_times_ms->add(0.05);   // 50ms
    _concurrent_mark_cleanup_times_ms->add(0.20);  // 200ms
}
```

---

## 3. 默认值表详解

### 3.1 按 ParallelGCThreads 分级

```cpp
// 索引 0-7 对应 ParallelGCThreads 1-8+
// index = MIN2(ParallelGCThreads - 1, 7)

// 16 核机器：ParallelGCThreads = 13
// index = MIN2(13 - 1, 7) = MIN2(12, 7) = 7
```

### 3.2 默认值表一览

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    G1Analytics 默认值表（按 ParallelGCThreads 分级）              │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  ParallelGCThreads:      1       2       3       4       5       6       7      8+│
│  索引:                   0       1       2       3       4       5       6       7│
│  ─────────────────────────────────────────────────────────────────────────────── │
│                                                                                  │
│  cost_per_card_ms      0.01   0.005   0.005   0.003   0.003   0.002   0.002  0.0015│
│  (每张卡片扫描成本)                                                              │
│                                                                                  │
│  cost_per_entry_ms     0.015   0.01    0.01   0.008   0.008  0.0055  0.0055  0.005│
│  (每条RSet条目成本)                                                              │
│                                                                                  │
│  cost_per_byte_ms     0.00006 0.00003 0.00003 0.000015 0.000015 0.00001 0.00001 0.000009│
│  (每字节复制成本)                                                                │
│                                                                                  │
│  constant_other_ms       5.0     5.0     5.0     5.0     5.0     5.0     5.0    5.0│
│  (固定开销)                                                                      │
│                                                                                  │
│  young_other_per_region 0.3     0.2     0.2    0.15    0.15    0.12    0.12    0.1│
│  (年轻代其他开销/Region)                                                         │
│                                                                                  │
│  non_young_other_per_region 1.0   0.7     0.7     0.5     0.5    0.42    0.42   0.3│
│  (老年代其他开销/Region)                                                         │
│                                                                                  │
│  rs_length_diff          0.0     0.0     0.0     0.0     0.0     0.0     0.0    0.0│
│  young_cards_per_entry   1.0     1.0     1.0     1.0     1.0     1.0     1.0    1.0│
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘

为什么线程越多，单位成本越低？
──────────────────────────────────────────────────────────────────────────────────
• 并行处理效率提高
• 单线程需要 0.01ms/卡，13 线程只需 0.0015ms/卡
• 但不是线性下降（存在同步开销）
```

### 3.3 16 核机器的默认值（index=7）

| 参数 | 值 | 说明 |
|------|-----|------|
| cost_per_card_ms | **0.0015 ms** | 扫描一张脏卡需要 1.5μs |
| cost_per_entry_ms | **0.005 ms** | 处理一条 RSet 条目需要 5μs |
| cost_per_byte_ms | **0.000009 ms** | 复制一字节需要 9ns |
| constant_other_time_ms | **5.0 ms** | 固定开销 5ms |
| young_other_cost_per_region_ms | **0.1 ms** | 年轻代每个 Region 额外开销 0.1ms |
| non_young_other_cost_per_region_ms | **0.3 ms** | 老年代每个 Region 额外开销 0.3ms |

---

## 4. 17 个 TruncatedSeq 序列详解

### 4.1 序列分类

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    G1Analytics 的 17 个序列                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  类别 A：GC 耗时（3 个，窗口=10）                                         │
│  ─────────────────────────────────────────────────────────────────────   │
│  _recent_gc_times_ms              最近 GC 暂停时间（ms）                  │
│  _concurrent_mark_remark_times_ms 并发标记 Remark 阶段耗时               │
│  _concurrent_mark_cleanup_times_ms 并发标记 Cleanup 阶段耗时             │
│                                                                          │
│  类别 B：RSet 处理成本（7 个，窗口=10）                                   │
│  ─────────────────────────────────────────────────────────────────────   │
│  _rs_length_diff_seq              RSet 长度变化量                         │
│  _cost_per_card_ms_seq            每张脏卡的处理成本                      │
│  _cost_scan_hcc_seq               热卡缓存扫描成本                        │
│  _young_cards_per_entry_ratio_seq 年轻代：卡片数/RSet条目数               │
│  _mixed_cards_per_entry_ratio_seq 混合GC：卡片数/RSet条目数               │
│  _cost_per_entry_ms_seq           每条 RSet 条目的处理成本                │
│  _mixed_cost_per_entry_ms_seq     混合 GC 时每条条目的成本                │
│                                                                          │
│  类别 C：对象复制成本（2 个，窗口=10）                                    │
│  ─────────────────────────────────────────────────────────────────────   │
│  _cost_per_byte_ms_seq            普通时期每字节复制成本                  │
│  _cost_per_byte_ms_during_cm_seq  并发标记期间每字节复制成本              │
│                                                                          │
│  类别 D：其他开销（3 个，窗口=10）                                        │
│  ─────────────────────────────────────────────────────────────────────   │
│  _constant_other_time_ms_seq      固定开销（与数据量无关）                │
│  _young_other_cost_per_region_ms_seq  年轻代每 Region 额外开销           │
│  _non_young_other_cost_per_region_ms_seq 老年代每 Region 额外开销        │
│                                                                          │
│  类别 E：预测输入（2 个，窗口=10）                                        │
│  ─────────────────────────────────────────────────────────────────────   │
│  _pending_cards_seq               待处理卡片数                            │
│  _rs_lengths_seq                  RSet 总长度                             │
│                                                                          │
│  类别 F：其他（2 个）                                                     │
│  ─────────────────────────────────────────────────────────────────────   │
│  _alloc_rate_ms_seq               分配速率（字节/ms）                     │
│  _recent_prev_end_times_for_all_gcs_sec  GC 结束时间戳                   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.2 TruncatedSeq 工作原理

```cpp
// TruncatedSeq 是一个固定长度的滑动窗口
// 超过长度时，旧数据被丢弃

class TruncatedSeq : public AbsSeq {
    double* _sequence;  // 存储最近 N 个值
    int _length;        // 窗口大小（10）
    int _next;          // 下一个写入位置
};

// 添加数据时自动更新统计量
void TruncatedSeq::add(double val) {
    // AbsSeq::add 会更新 _davg（衰减平均）和 _dvariance（衰减方差）
    AbsSeq::add(val);
    
    // 存储到循环数组
    _sequence[_next] = val;
    _next = (_next + 1) % _length;
}
```

---

## 5. 预测方法详解

### 5.1 GC 耗时预测公式

```
GC 总耗时 = 基础耗时 + RSet 更新耗时 + RSet 扫描耗时 + 对象复制耗时 + 其他耗时

┌─────────────────────────────────────────────────────────────────────────┐
│                        GC 耗时预测公式分解                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  1. RSet 更新耗时                                                        │
│     predict_rs_update_time_ms(pending_cards)                            │
│     = pending_cards × cost_per_card_ms + scan_hcc_ms                    │
│     = 待处理卡片数 × 0.0015ms + 热卡缓存扫描时间                         │
│                                                                          │
│  2. RSet 扫描耗时                                                        │
│     predict_rs_scan_time_ms(card_num, for_young_gc)                     │
│     = card_num × cost_per_entry_ms                                      │
│     = 卡片数 × 0.005ms                                                   │
│                                                                          │
│  3. 对象复制耗时                                                         │
│     predict_object_copy_time_ms(bytes_to_copy)                          │
│     = bytes_to_copy × cost_per_byte_ms                                  │
│     = 复制字节数 × 0.000009ms                                            │
│                                                                          │
│  4. 其他耗时                                                             │
│     = constant_other_time_ms                                            │
│     + young_num × young_other_cost_per_region_ms                        │
│     + non_young_num × non_young_other_cost_per_region_ms                │
│     = 5.0ms + 年轻代Region数 × 0.1ms + 老年代Region数 × 0.3ms           │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 5.2 预测示例（16 核机器，8GB 堆）

```
假设场景：
• pending_cards = 10,000（待处理脏卡）
• rs_length = 5,000（RSet 条目数）
• bytes_to_copy = 100MB（存活对象）
• young_regions = 102（年轻代 Region 数）

预测计算：
─────────────────────────────────────────────────────────────────────────
1. RSet 更新耗时 = 10,000 × 0.0015ms = 15ms

2. RSet 扫描耗时 = 5,000 × 0.005ms = 25ms

3. 对象复制耗时 = 100MB × 0.000009ms/byte
                = 104,857,600 × 0.000009ms
                ≈ 944ms  ← 复制是大头！

4. 其他耗时 = 5.0ms + 102 × 0.1ms + 0 × 0.3ms
           = 5.0ms + 10.2ms
           = 15.2ms

预测总耗时 ≈ 15 + 25 + 944 + 15.2 ≈ 1000ms

实际情况：
• 如果预测 > 200ms（目标），G1 会减少年轻代大小
• 减少年轻代 → 减少存活对象 → 减少复制时间
```

### 5.3 关键预测方法

```cpp
// 预测 RSet 更新耗时
double G1Analytics::predict_rs_update_time_ms(size_t pending_cards) const {
    return pending_cards * predict_cost_per_card_ms() + predict_scan_hcc_ms();
}

// 预测对象复制耗时
double G1Analytics::predict_object_copy_time_ms(size_t bytes_to_copy, 
                                                 bool during_concurrent_mark) const {
    if (during_concurrent_mark) {
        return predict_object_copy_time_ms_during_cm(bytes_to_copy);
    } else {
        return bytes_to_copy * get_new_prediction(_cost_per_byte_ms_seq);
    }
}

// 并发标记期间复制成本更高（约 1.1 倍）
double G1Analytics::predict_object_copy_time_ms_during_cm(size_t bytes_to_copy) const {
    if (_cost_per_byte_ms_during_cm_seq->num() < 3) {
        // 样本不足，用普通成本 × 1.1
        return (1.1 * bytes_to_copy) * get_new_prediction(_cost_per_byte_ms_seq);
    } else {
        return bytes_to_copy * get_new_prediction(_cost_per_byte_ms_during_cm_seq);
    }
}
```

---

## 6. GDB 验证 ✅

### 6.1 GDB 验证结果

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
断点位置：g1Analytics.cpp:116（构造函数完成后）

========== G1Analytics 构造函数完成后 ==========
this = 0x7ffff0038d10
_predictor = 0x7ffff0038ab8 (指向 G1Policy::_predictor)

========== 默认值索引计算 ==========
ParallelGCThreads = 13
index = MIN2(13 - 1, 7) = MIN2(12, 7) = 7 ✅

========== 序列初始值验证 ==========
_cost_per_card_ms_seq->_davg = 0.0015 ✅
_cost_per_entry_ms_seq->_davg = 0.005 ✅
_cost_per_byte_ms_seq->_davg = 0.000009 ✅
_constant_other_time_ms_seq->_davg = 5.0 ✅

========== 并发标记初始值 ==========
_concurrent_mark_remark_times_ms 初始 = 0.05 (50ms)
_concurrent_mark_cleanup_times_ms 初始 = 0.20 (200ms)
```

### 6.2 验证总结

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    G1Analytics GDB 验证结果                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  默认值索引（16核机器）                                                   │
│  ──────────────────────────────────────────────────────────────────────  │
│  ParallelGCThreads = 13                                                  │
│  index = MIN2(12, 7) = 7 ✅                                              │
│                                                                          │
│  序列初始值验证                                                          │
│  ──────────────────────────────────────────────────────────────────────  │
│  cost_per_card_ms         0.0015 ms ✅                                   │
│  cost_per_entry_ms        0.005 ms ✅                                    │
│  cost_per_byte_ms         0.000009 ms ✅                                 │
│  constant_other_time_ms   5.0 ms ✅                                      │
│                                                                          │
│  序列参数                                                                │
│  ──────────────────────────────────────────────────────────────────────  │
│  TruncatedSeqLength = 10（滑动窗口大小）                                 │
│  NumPrevPausesForHeuristics = 10                                         │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 7. G1Analytics 与 G1Predictions 的关系

```
┌─────────────────────────────────────────────────────────────────────────┐
│                   G1Analytics + G1Predictions 协作                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   G1Analytics（数据仓库）              G1Predictions（预测器）            │
│   ──────────────────────              ────────────────────               │
│                                                                          │
│   TruncatedSeq                                                           │
│   ┌─────────────────┐                                                    │
│   │ 0.0015          │ ─────┐                                             │
│   │ 0.0012          │      │                                             │
│   │ 0.0018          │      │  get_new_prediction(seq)                    │
│   │ 0.0014          │      │  ─────────────────────►  prediction         │
│   │ ...             │      │                          = davg + σ×stddev  │
│   │ (最近10个值)    │ ─────┘                          = 0.0014 + 0.5×0.0002│
│   │                 │                                 = 0.0015           │
│   │ davg = 0.0014   │                                                    │
│   │ dsd = 0.0002    │                                                    │
│   └─────────────────┘                                                    │
│                                                                          │
│   数据流：                                                               │
│   ────────────────────────────────────────────────────────────────────   │
│   1. 每次 GC 后：analytics->report_xxx(实际值)                           │
│   2. 预测时：analytics->predict_xxx()                                    │
│      └── predictor->get_new_prediction(seq)                              │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 8. 总结

### 8.1 G1Analytics 是什么？

```
G1Analytics = 17 个 TruncatedSeq 序列 + 默认值表

• TruncatedSeq：固定长度（10）的滑动窗口，自动计算衰减平均
• 默认值表：按 ParallelGCThreads 分 8 档，线程越多单位成本越低
• 职责：存储历史数据，供 G1Predictions 预测使用
```

### 8.2 关键数值（16 核机器，index=7）

| 参数 | 初始值 | 说明 |
|------|--------|------|
| cost_per_card_ms | 0.0015 ms | 1.5μs/卡 |
| cost_per_entry_ms | 0.005 ms | 5μs/RSet条目 |
| cost_per_byte_ms | 0.000009 ms | 9ns/字节 |
| constant_other_time_ms | 5.0 ms | 固定开销 |
| concurrent_mark_remark | 50 ms | Remark 阶段初始估计 |
| concurrent_mark_cleanup | 200 ms | Cleanup 阶段初始估计 |

### 8.3 序列分类

| 类别 | 数量 | 用途 |
|------|------|------|
| GC 耗时 | 3 | 记录历史 GC 暂停时间 |
| RSet 处理成本 | 7 | 预测 RSet 更新和扫描耗时 |
| 对象复制成本 | 2 | 预测复制存活对象耗时 |
| 其他开销 | 3 | 预测固定开销和每 Region 开销 |
| 预测输入 | 2 | 记录待处理卡片数和 RSet 长度 |

---

## 待分析节点更新

| 节点 | 主题 | 状态 |
|------|------|------|
| B.1.1 | ParallelGCThreads 计算算法 | ✅ |
| F.1 | G1Predictions 预测器 | ✅ |
| E.5.1 | RefToScanQueue 工作窃取队列 | ✅ |
| D.4.1 | G1Policy 构造函数 | ✅ |
| **F.2** | **G1Analytics 分析器** | **✅** |
