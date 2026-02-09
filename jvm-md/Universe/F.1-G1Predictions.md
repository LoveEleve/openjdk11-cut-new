# F.1 G1Predictions 预测器 - 深度分析

> 源码位置：`g1Predictions.hpp`、`numberSeq.hpp`、`numberSeq.cpp`
> 调用链：`G1Policy` → `G1Analytics` → `G1Predictions` → `TruncatedSeq`

---

## 1. 功能定位

### 一句话说明
**G1Predictions 是 G1 GC 暂停时间预测的核心**，它基于历史数据（衰减平均 + 标准差）预测下一次 GC 操作的耗时。

### 在整体流程中的位置
```
G1Policy（决策大脑）
│
├── 问题：应该选多少个 Region 进 CSet？
│         ↓
│   需要预测每个 Region 回收需要多长时间
│         ↓
└── G1Analytics（数据分析器）
    │
    ├── 持有 15+ 个 TruncatedSeq 序列（历史数据）
    │   • _cost_per_card_ms_seq     每张卡的处理成本
    │   • _cost_per_entry_ms_seq    每个 RemSet 条目的成本
    │   • _cost_per_byte_ms_seq     每字节复制的成本
    │   • ...
    │
    └── G1Predictions（预测器）  ← 【当前分析】
        │
        └── 预测公式：prediction = davg + sigma * stddev_estimate
```

### 为什么需要预测器？

```
┌────────────────────────────────────────────────────────────────────┐
│                       G1 的核心目标                                  │
│                                                                     │
│   用户设置：-XX:MaxGCPauseMillis=200（暂停时间目标 200ms）          │
│                                                                     │
│   G1 需要决定：本次 GC 回收多少个 Region？                          │
│                                                                     │
│   • 回收太多 → 暂停超过 200ms → 违反 SLA                            │
│   • 回收太少 → 内存回收不足 → 频繁 GC 或 Full GC                    │
│                                                                     │
│   解决方案：预测每个 Region 的回收成本，动态选择 CSet               │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

---

## 2. 核心公式

### 2.1 预测公式

```cpp
// g1Predictions.hpp:57
double get_new_prediction(TruncatedSeq const* seq) const {
    return seq->davg() + _sigma * stddev_estimate(seq);
}
```

**数学表达**：
```
┌─────────────────────────────────────────────────────────────────┐
│                                                                  │
│   prediction = davg + σ × stddev_estimate                        │
│                                                                  │
│   其中：                                                         │
│   • davg = 衰减平均值（Decaying Average）                        │
│   • σ (sigma) = 置信度因子（默认 0.5）                           │
│   • stddev_estimate = 标准差估计值                               │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 为什么是 davg + sigma * stddev？

```
问题：如果只用平均值预测，会有什么问题？

场景：GC 耗时历史数据 = [10ms, 12ms, 8ms, 50ms, 11ms]
      平均值 avg = 18.2ms

使用平均值预测：
  下次预测 = 18.2ms
  但如果实际是 50ms（异常值再次出现）→ 预测严重低估 → 超时！

使用 davg + sigma * stddev：
  davg ≈ 18ms（衰减平均，更接近最近的值）
  stddev ≈ 16ms（标准差，反映波动）
  sigma = 0.5（默认置信度）
  
  预测 = 18 + 0.5 × 16 = 26ms
  
  这个预测更保守，能应对波动！

┌────────────────────────────────────────────────────────────────┐
│                                                                 │
│   核心思想：预测值 = 平均值 + 安全余量                          │
│                                                                 │
│   • sigma 越大 → 预测越保守 → 超时风险越低 → 但 CSet 可能太小  │
│   • sigma 越小 → 预测越激进 → 超时风险越高 → 但吞吐量更好       │
│                                                                 │
│   默认 sigma = 0.5 是 Oracle 调优出来的平衡点                   │
│                                                                 │
└────────────────────────────────────────────────────────────────┘
```

---

## 3. 衰减平均（Decaying Average）详解

### 3.1 什么是衰减平均？

```
传统平均：avg = (x1 + x2 + ... + xn) / n
          所有历史数据权重相同

衰减平均：davg = (1-α) × 新值 + α × 旧davg
          最近的数据权重更大！
```

### 3.2 核心源码

```cpp
// numberSeq.cpp:36-47
void AbsSeq::add(double val) {
    if (_num == 0) {
        // 第一个元素：衰减平均 = 这个值本身
        _davg = val;
        _dvariance = 0.0;
    } else {
        // 后续元素：指数加权移动平均
        _davg = (1.0 - _alpha) * val + _alpha * _davg;
        //        ↑新值权重(0.3)      ↑旧值权重(0.7)
        
        double diff = val - _davg;
        _dvariance = (1.0 - _alpha) * diff * diff + _alpha * _dvariance;
    }
}
```

### 3.3 alpha 参数的影响

```cpp
#define DEFAULT_ALPHA_VALUE 0.7  // numberSeq.hpp:43
```

```
alpha = 0.7 意味着：
  新值权重 = 1 - 0.7 = 0.3 (30%)
  旧值权重 = 0.7 (70%)

历史数据的权重衰减（假设 alpha = 0.7）：
┌──────────────────────────────────────────────────────────────────┐
│  数据点      距离现在    权重                                     │
│  ─────────────────────────────────────────────────────────────   │
│  最新 (n)      0        0.30   (30%)      ████████████           │
│  n-1           1        0.21   (21%)      ███████                │
│  n-2           2        0.147  (14.7%)    █████                  │
│  n-3           3        0.103  (10.3%)    ████                   │
│  n-4           4        0.072  (7.2%)     ███                    │
│  n-5           5        0.050  (5%)       ██                     │
│  ...          ...       ...               ...                    │
│  ─────────────────────────────────────────────────────────────   │
│  公式：权重(k) = (1-α) × α^k = 0.3 × 0.7^k                       │
└──────────────────────────────────────────────────────────────────┘

特点：
• 最近 3 个数据点占总权重的 65%
• 越久远的数据影响越小
• 自动适应工作负载的变化
```

### 3.4 为什么用衰减平均而不是简单平均？

```
场景：应用程序从低负载切换到高负载

时间线：
  T0-T10: 低负载，GC 耗时约 20ms
  T11+:   高负载，GC 耗时约 80ms

┌───────────────────────────────────────────────────────────────────┐
│ 方案 A：简单平均                                                   │
│ ────────────────────────────────────────────────────────────────  │
│ T12 时的预测：                                                     │
│   历史 = [20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 80]             │
│   avg = (20×10 + 80) / 11 = 25.4ms                                │
│   预测 = 25ms  ← 严重低估！实际需要 80ms！                         │
│                                                                    │
│ 问题：历史数据拖后腿，无法快速适应新负载                           │
└───────────────────────────────────────────────────────────────────┘

┌───────────────────────────────────────────────────────────────────┐
│ 方案 B：衰减平均（alpha = 0.7）                                    │
│ ────────────────────────────────────────────────────────────────  │
│ T12 时的 davg：                                                    │
│   旧 davg ≈ 20ms（之前的低负载）                                   │
│   新值 = 80ms                                                      │
│   新 davg = 0.3 × 80 + 0.7 × 20 = 24 + 14 = 38ms                  │
│                                                                    │
│ T13 时（又一次 80ms GC）：                                         │
│   新 davg = 0.3 × 80 + 0.7 × 38 = 24 + 26.6 = 50.6ms              │
│                                                                    │
│ T14 时：davg = 0.3 × 80 + 0.7 × 50.6 = 59.4ms                     │
│ T15 时：davg = 0.3 × 80 + 0.7 × 59.4 = 65.6ms                     │
│ T16 时：davg = 0.3 × 80 + 0.7 × 65.6 = 69.9ms                     │
│                                                                    │
│ 优点：几次 GC 后就能快速适应新负载！                               │
└───────────────────────────────────────────────────────────────────┘
```

---

## 4. 标准差估计（stddev_estimate）详解

### 4.1 特殊处理：小样本

```cpp
// g1Predictions.hpp:41-48
double stddev_estimate(TruncatedSeq const* seq) const {
    double estimate = seq->dsd();  // 衰减标准差
    int const samples = seq->num();
    
    if (samples < 5) {
        // 样本少于 5 个时的保守估计
        estimate = MAX2(seq->davg() * (5 - samples) / 2.0, estimate);
    }
    return estimate;
}
```

### 4.2 为什么小样本需要特殊处理？

```
问题：JVM 刚启动时，只有 1-2 次 GC 历史数据

场景：只有 2 次 GC，耗时 [10ms, 12ms]
  davg = 11ms
  dsd ≈ 1ms（标准差很小，因为数据太少）
  
  如果直接用：
    prediction = 11 + 0.5 × 1 = 11.5ms
    
  这个预测太自信了！样本太少，不确定性很大！

解决方案：小样本时人为增大标准差估计

公式：estimate = MAX2(davg × (5 - samples) / 2.0, dsd)

samples=1: estimate = MAX2(davg × 4/2, dsd) = MAX2(davg × 2.0, dsd)
samples=2: estimate = MAX2(davg × 3/2, dsd) = MAX2(davg × 1.5, dsd)
samples=3: estimate = MAX2(davg × 2/2, dsd) = MAX2(davg × 1.0, dsd)
samples=4: estimate = MAX2(davg × 1/2, dsd) = MAX2(davg × 0.5, dsd)
samples≥5: estimate = dsd（使用真实标准差）

效果：
  samples=2, davg=11ms:
    estimate = MAX2(11 × 1.5, 1) = 16.5ms
    prediction = 11 + 0.5 × 16.5 = 19.25ms  ← 更保守！
```

### 4.3 图解：小样本保护机制

```
 stddev_estimate
        │
  2.0×davg  ┤ ●
            │   \
  1.5×davg  ┤    ●
            │      \
  1.0×davg  ┤        ●
            │          \
  0.5×davg  ┤            ●
            │              \
      dsd   ┼────────────────●────────────────────► samples
            0  1  2  3  4  5  6  7  8  ...
            
            └─── 小样本保护区 ───┘ └─ 使用真实 dsd ─
```

---

## 5. sigma (σ) 参数详解

### 5.1 参数定义

```cpp
// g1_globals.hpp:60
product(uintx, G1ConfidencePercent, 50, ...)

// g1Policy.cpp:50
_predictor(G1ConfidencePercent / 100.0),  // sigma = 50/100 = 0.5
```

### 5.2 sigma 的统计学含义

```
在正态分布中：
  • μ (平均值)
  • σ (标准差)

预测 = μ + k×σ 的覆盖率：
  k=0:   50%  的情况 ≤ 预测值
  k=0.5: 69%  的情况 ≤ 预测值  ← G1 默认
  k=1:   84%  的情况 ≤ 预测值
  k=2:   97%  的情况 ≤ 预测值
  k=3:   99.7% 的情况 ≤ 预测值

G1 选择 sigma=0.5 的含义：
  "我们有约 69% 的信心，实际值不会超过预测值"
  
  这是一个平衡点：
  • 不会太保守（否则 CSet 太小，吞吐量低）
  • 也不会太激进（否则经常超时）
```

### 5.3 调优 G1ConfidencePercent

```bash
# 更保守（减少超时风险）
java -XX:G1ConfidencePercent=80 ...  # sigma = 0.8

# 更激进（提高吞吐量，可能超时）
java -XX:G1ConfidencePercent=30 ...  # sigma = 0.3
```

```
┌────────────────────────────────────────────────────────────────────┐
│ G1ConfidencePercent 调优指南                                        │
│                                                                     │
│ 值较小（如 30）：                                                   │
│   • 预测值更接近平均值                                              │
│   • CSet 可能更大 → 吞吐量更好                                      │
│   • 但更容易超过 MaxGCPauseMillis → 延迟不稳定                      │
│                                                                     │
│ 值较大（如 80）：                                                   │
│   • 预测值更保守（加更多安全余量）                                  │
│   • CSet 可能更小 → 延迟更稳定                                      │
│   • 但可能需要更频繁 GC → 吞吐量下降                                │
│                                                                     │
│ 默认值 50：Oracle 调优的平衡点                                      │
└────────────────────────────────────────────────────────────────────┘
```

---

## 6. TruncatedSeq 滑动窗口

### 6.1 数据结构

```cpp
class TruncatedSeq: public AbsSeq {
private:
    double *_sequence;  // 环形缓冲区，存储最近 L 个值
    int     _length;    // 窗口大小 L（默认 10）
    int     _next;      // 下一个要覆盖的位置
};
```

### 6.2 环形缓冲区原理

```
TruncatedSeq（length = 5）

初始状态：
  _sequence = [0.0, 0.0, 0.0, 0.0, 0.0]
  _next = 0
  _num = 0

添加 10ms:
  _sequence = [10.0, 0.0, 0.0, 0.0, 0.0]
  _next = 1
  _num = 1

添加 12ms:
  _sequence = [10.0, 12.0, 0.0, 0.0, 0.0]
  _next = 2
  _num = 2

... 添加 8ms, 15ms, 11ms ...

  _sequence = [10.0, 12.0, 8.0, 15.0, 11.0]
  _next = 0  ← 回到开头
  _num = 5   ← 缓冲区满了

添加 20ms（覆盖最老的 10ms）:
  _sequence = [20.0, 12.0, 8.0, 15.0, 11.0]
              ↑覆盖
  _next = 1
  _num = 5   ← 保持不变（已满）
```

### 6.3 add() 实现

```cpp
// numberSeq.cpp:145-167
void TruncatedSeq::add(double val) {
    AbsSeq::add(val);  // 更新衰减平均和方差
    
    // 获取即将被覆盖的旧值
    double old_val = _sequence[_next];
    
    // 从累加和中减去旧值
    _sum -= old_val;
    _sum_of_squares -= old_val * old_val;
    
    // 加上新值
    _sum += val;
    _sum_of_squares += val * val;
    
    // 替换旧值
    _sequence[_next] = val;
    _next = (_next + 1) % _length;  // 环形移动
    
    // 缓冲区未满时才增加 _num
    if (_num < _length)
        ++_num;
}
```

---

## 7. G1Analytics 中的使用

### 7.1 15+ 个预测序列

```cpp
// g1Analytics.cpp:72-95
G1Analytics::G1Analytics(const G1Predictions* predictor) :
    _predictor(predictor),
    
    // ══════ GC 时间相关 ══════
    _recent_gc_times_ms(new TruncatedSeq(NumPrevPausesForHeuristics)),  // 最近 GC 耗时
    _concurrent_mark_remark_times_ms(new TruncatedSeq(...)),            // 并发标记 remark 耗时
    _concurrent_mark_cleanup_times_ms(new TruncatedSeq(...)),           // 并发标记 cleanup 耗时
    
    // ══════ 分配速率 ══════
    _alloc_rate_ms_seq(new TruncatedSeq(TruncatedSeqLength)),           // 分配速率（字节/ms）
    
    // ══════ 卡表扫描成本 ══════
    _cost_per_card_ms_seq(new TruncatedSeq(...)),          // 每张卡的扫描成本
    _cost_scan_hcc_seq(new TruncatedSeq(...)),             // 热卡缓存扫描成本
    
    // ══════ RemSet 处理成本 ══════
    _young_cards_per_entry_ratio_seq(new TruncatedSeq(...)),    // 年轻代卡表比例
    _mixed_cards_per_entry_ratio_seq(new TruncatedSeq(...)),    // 混合 GC 卡表比例
    _cost_per_entry_ms_seq(new TruncatedSeq(...)),              // 每个条目的成本
    
    // ══════ 复制成本 ══════
    _cost_per_byte_ms_seq(new TruncatedSeq(...)),               // 每字节复制成本
    _cost_per_byte_ms_during_cm_seq(new TruncatedSeq(...)),     // 并发标记期间
    
    // ══════ 其他开销 ══════
    _constant_other_time_ms_seq(new TruncatedSeq(...)),         // 固定开销（根扫描等）
    _young_other_cost_per_region_ms_seq(new TruncatedSeq(...)), // 每 Region 额外开销
    _non_young_other_cost_per_region_ms_seq(new TruncatedSeq(...)),
    
    // ══════ 记忆集大小 ══════
    _rs_length_diff_seq(new TruncatedSeq(...)),    // RemSet 长度差异
    _rs_lengths_seq(new TruncatedSeq(...)),        // RemSet 长度
    _pending_cards_seq(new TruncatedSeq(...)),     // 待处理卡数
    ...
```

### 7.2 预测调用示例

```cpp
// G1Policy 中计算回收一个 Region 的预期成本
double G1Policy::predict_region_elapsed_time_ms(HeapRegion* hr, bool for_young_gc) {
    // 1. 获取 Region 的各项指标
    size_t rs_length = hr->rem_set()->occupied();  // RemSet 大小
    size_t used_bytes = hr->used();                // 已用字节
    
    // 2. 预测各项成本（使用 G1Predictions）
    double cards_cost = _analytics->predict_scan_rs_time_ms(rs_length);
    double copy_cost = _analytics->predict_object_copy_time_ms(used_bytes);
    double other_cost = _analytics->predict_young_other_time_ms(1);
    
    // 3. 总成本
    return cards_cost + copy_cost + other_cost;
}

// G1Analytics 中的预测实现
double G1Analytics::predict_scan_rs_time_ms(size_t rs_length) {
    // 使用 G1Predictions 预测
    return get_new_prediction(_cost_per_entry_ms_seq) * rs_length;
    //     ↑ 调用 _predictor->get_new_prediction()
    //       = davg + sigma * stddev_estimate
}
```

---

## 8. GDB 验证

### 8.1 实际 GDB 输出

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
┌─────────────────────────────────────────────────────────────────────┐
│                     G1Predictions 实际参数                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  核心参数                                                            │
│  ───────────────────────────────                                     │
│  G1ConfidencePercent = 50                                            │
│  sigma = 50 / 100.0 = 0.500000  ✓                                   │
│                                                                      │
│  默认值索引                                                          │
│  ───────────────────────────────                                     │
│  ParallelGCThreads = 13                                              │
│  index = min(13-1, 7) = 7   （使用最后一组默认值）                   │
│                                                                      │
│  当前使用的默认值 (index=7)                                          │
│  ───────────────────────────────                                     │
│  cost_per_card_ms = 0.0015 ms    （每张卡的扫描成本）                │
│  cost_per_entry_ms = 0.005 ms    （每个 RemSet 条目的成本）          │
│  cost_per_byte_ms = 0.000009 ms  （每字节复制的成本）                │
│  constant_other_time_ms = 5.0 ms （固定开销，如根扫描）              │
│                                                                      │
│  衰减平均参数                                                        │
│  ───────────────────────────────                                     │
│  DEFAULT_ALPHA_VALUE = 0.7       （新值权重 30%，旧值权重 70%）      │
│  TruncatedSeqLength = 10         （历史序列窗口大小）                │
│  NumPrevPausesForHeuristics = 10 （GC 时间序列窗口大小）             │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 8.2 默认值表解读

```
为什么 ParallelGCThreads 越多，成本默认值越小？

┌──────────────────────────────────────────────────────────────────────┐
│  线程数     索引    cost_per_card    cost_per_entry    cost_per_byte │
│  ───────────────────────────────────────────────────────────────────  │
│    1         0       0.01 ms          0.015 ms         0.00006 ms    │
│   2-3       1-2      0.005 ms         0.01 ms          0.00003 ms    │
│   4-5       3-4      0.003 ms         0.008 ms         0.000015 ms   │
│   6-7       5-6      0.002 ms         0.0055 ms        0.00001 ms    │
│   8+         7       0.0015 ms        0.005 ms         0.000009 ms   │ ← 当前
│  ───────────────────────────────────────────────────────────────────  │
│                                                                       │
│  原因：线程越多，并行度越高，单位工作的耗时越短                       │
│  这些值是 Oracle 在 SPECjbb 和 GCOld 基准测试中调出来的经验值         │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

### 8.3 GDB 脚本位置

```bash
# 脚本路径
jvm-md/tmp-file/universe-init/gdb_g1predictions.txt

# 执行命令
cd /data/workspace/openjdk-cut-new
gdb -batch -x jvm-md/tmp-file/universe-init/gdb_g1predictions.txt \
    ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java
```

---

## 9. 完整预测示例

### 9.1 场景：预测回收 10 个 Region 需要多长时间

```
已知条件（假设）：
  • 10 个 Region，每个 4MB
  • 每个 Region 的 RemSet 有 1000 个条目
  • 每个 Region 有 2MB 存活对象

历史数据（假设 _cost_per_entry_ms_seq）：
  • davg = 0.008ms（每个 RemSet 条目的处理时间）
  • dsd = 0.002ms（标准差）
  • samples = 10（足够多，不需要小样本保护）

预测计算：
  sigma = 0.5
  stddev_estimate = dsd = 0.002ms（samples >= 5）
  
  cost_per_entry = davg + sigma * stddev_estimate
                 = 0.008 + 0.5 * 0.002
                 = 0.009ms
  
  RemSet 处理总时间 = 10 Regions * 1000 entries * 0.009ms
                    = 90ms

类似地计算复制成本：
  cost_per_byte = 预测值（假设 0.00001ms/byte）
  复制总时间 = 10 Regions * 2MB * 0.00001ms/byte
             = 10 * 2 * 1024 * 1024 * 0.00001ms
             ≈ 210ms

固定开销：
  constant_other_time = 5ms（根扫描等）

总预测时间：
  90ms + 210ms + 5ms = 305ms

决策：
  MaxGCPauseMillis = 200ms
  预测 305ms > 200ms
  → 需要减少 CSet 大小！
  → 可能只选择 6-7 个 Region
```

---

## 10. 总结

### 10.1 核心公式

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                  │
│   prediction = davg + sigma × stddev_estimate                    │
│                                                                  │
│   davg：衰减平均值                                               │
│     • 公式：davg_new = (1-α) × 新值 + α × davg_old              │
│     • α = 0.7，新值权重 30%，旧值权重 70%                        │
│     • 特点：快速适应工作负载变化                                 │
│                                                                  │
│   stddev_estimate：标准差估计                                    │
│     • samples >= 5：使用真实衰减标准差 dsd                       │
│     • samples < 5：保守估计，基于 davg 放大                      │
│                                                                  │
│   sigma：置信度因子                                              │
│     • 默认 0.5（G1ConfidencePercent = 50）                       │
│     • 值越大预测越保守                                           │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 10.2 设计理念

```
G1 的暂停时间预测是"科学 + 艺术"：

科学部分：
  • 基于统计学的衰减平均和标准差
  • 环形缓冲区存储历史数据
  • 小样本保护机制

艺术部分：
  • alpha = 0.7（经验值）
  • sigma = 0.5（经验值）
  • 各种 cost 默认值（基准测试调优）

目标：
  • 在吞吐量和延迟之间取得平衡
  • 快速适应工作负载变化
  • 避免严重的预测失误
```

### 10.3 类关系图

```
┌─────────────────────────────────────────────────────────────────┐
│                        G1Policy                                  │
│                           │                                      │
│                           ▼                                      │
│    ┌───────────────── G1Analytics ─────────────────┐            │
│    │                      │                         │            │
│    │            ┌─────────┴─────────┐               │            │
│    │            ▼                   ▼               │            │
│    │     G1Predictions      15+ TruncatedSeq       │            │
│    │     (预测器)            (历史数据序列)         │            │
│    │            │                   │               │            │
│    │            ▼                   ▼               │            │
│    │         sigma              davg, dsd          │            │
│    │         (0.5)              (衰减统计)          │            │
│    │            │                   │               │            │
│    │            └─────────┬─────────┘               │            │
│    │                      ▼                         │            │
│    │    prediction = davg + sigma * stddev_estimate │            │
│    └────────────────────────────────────────────────┘            │
│                           │                                      │
│                           ▼                                      │
│              年轻代大小 / CSet 选择 / GC 触发时机                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 下一步

建议继续学习：
- **F.2** `G1Analytics` - 了解 15+ 个预测序列的具体用途
- **F.4** `IHOP 控制器` - 了解何时触发并发标记
- **B.5** `MaxGCPauseMillis` - 了解暂停时间目标如何影响 CSet 选择

或者告诉我："运行 GDB 验证 F.1"，我帮你执行脚本获取实际数据。
