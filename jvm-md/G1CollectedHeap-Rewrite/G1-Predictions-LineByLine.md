# G1 预测模型：衰减平均与自适应决策

## 1. 概览：解决什么问题？

G1 GC 需要在**运行时自适应**地做出决策：
- **年轻代应该多大？** → 决定 GC 频率和暂停时间
- **下一次 GC 会在什么时候？** → 基于分配速率预测
- **混合 GC 应该选哪些老年代 Region？** → 基于回收效率预测
- **何时启动并发标记？** → 基于 IHOP 预测

这些决策都需要**预测未来**，而预测需要：
1. **追踪历史数据**（最近 N 次 GC 的耗时、分配速率等）
2. **计算趋势**（平均值、标准差）
3. **考虑不确定性**（置信区间）

G1 的预测模型基于**衰减平均（Decaying Average）**，它能：
- 给最近的数据更高权重（更反映当前状态）
- 自动平滑历史波动
- 用标准差表示预测的不确定性

---

## 2. 核心数据结构

### 2.1 继承层次

```
┌─────────────────────────────────────────────────────────┐
│                     AbsSeq (抽象基类)                    │
│  - _num: 元素数量                                        │
│  - _sum: 元素和                                          │
│  - _sum_of_squares: 平方和                               │
│  - _davg: 衰减平均 ★                                    │
│  - _dvariance: 衰减方差 ★                               │
│  - _alpha: 衰减因子（默认0.7）                          │
└───────────────────────┬─────────────────────────────────┘
                        │ 继承
           ┌────────────┴────────────┐
           │                         │
┌──────────▼──────────┐    ┌─────────▼──────────┐
│    NumberSeq        │    │   TruncatedSeq ★   │
│  (无限序列)          │    │  (有限环形缓冲)     │
│  - _last: 最新值    │    │  - _sequence[]: 缓冲│
│  - _maximum: 最大值 │    │  - _length: 容量    │
└─────────────────────┘    │  - _next: 下一个位置│
                           └────────────────────┘
```

### 2.2 TruncatedSeq 内存布局

**源码位置**：`utilities/numberSeq.hpp:107-132`

```cpp
class TruncatedSeq: public AbsSeq {
private:
  double *_sequence;  // 环形缓冲区指针
  int     _length;    // 容量 L（默认10）
  int     _next;      // 下一个要覆盖的位置（最老的元素）
};
```

**内存布局（以 length=10 为例）**：

```
TruncatedSeq 对象 (32字节)
┌────────────────────────────────────────────────────────┐
│ AbsSeq 基类字段                                         │
│  ├─ _num (int)             : 4 bytes                   │
│  ├─ _sum (double)          : 8 bytes                   │
│  ├─ _sum_of_squares (double): 8 bytes                  │
│  ├─ _davg (double)         : 8 bytes  ← 衰减平均       │
│  ├─ _dvariance (double)    : 8 bytes                   │
│  └─ _alpha (double)        : 8 bytes  ← 默认0.7        │
├────────────────────────────────────────────────────────┤
│ TruncatedSeq 字段                                       │
│  ├─ _sequence (double*)    : 8 bytes  ──┐              │
│  ├─ _length (int)          : 4 bytes    │              │
│  └─ _next (int)            : 4 bytes    │              │
└────────────────────────────────────────┼──────────────┘
                                         │
                                         ▼
                         堆上分配的数组 (80 bytes)
                         ┌──────┬──────┬──────┬─────┬──────┐
                         │ [0]  │ [1]  │ [2]  │...  │ [9]  │
                         │ val0 │ val1 │ val2 │     │ val9 │
                         └──────┴──────┴──────┴─────┴──────┘
                           ▲
                           │
                         _next 指向最老元素，新值将覆盖它
```

**关键点**：
1. `_sequence` 是堆上分配的数组，大小为 `_length * sizeof(double)`
2. `_next` 是环形指针，始终指向最老元素的位置
3. `_num` 表示当前有效元素数，最多等于 `_length`

### 2.3 G1Analytics 字段

**源码位置**：`gc/g1/g1Analytics.hpp:34-66`

```cpp
class G1Analytics: public CHeapObj<mtGC> {
  const static int TruncatedSeqLength = 10;          // 容量
  const static int NumPrevPausesForHeuristics = 10;  // 历史GC数

  const G1Predictions* _predictor;

  // ===== GC 时间统计 =====
  TruncatedSeq* _recent_gc_times_ms;                 // 最近10次GC时间
  TruncatedSeq* _concurrent_mark_remark_times_ms;    // 并发标记Remark耗时
  TruncatedSeq* _concurrent_mark_cleanup_times_ms;   // 并发标记Cleanup耗时

  // ===== 分配速率 =====
  TruncatedSeq* _alloc_rate_ms_seq;                  // 分配速率 (bytes/ms)
  double        _prev_collection_pause_end_ms;       // 上次GC结束时间

  // ===== RSet 相关 =====
  TruncatedSeq* _rs_length_diff_seq;                 // RSet长度变化
  TruncatedSeq* _cost_per_card_ms_seq;               // 每张Card处理成本
  TruncatedSeq* _cost_scan_hcc_seq;                  // Hot Card Cache扫描成本
  TruncatedSeq* _young_cards_per_entry_ratio_seq;    // Young GC Card/Entry比
  TruncatedSeq* _mixed_cards_per_entry_ratio_seq;    // Mixed GC Card/Entry比
  TruncatedSeq* _cost_per_entry_ms_seq;              // 每个Entry扫描成本
  TruncatedSeq* _mixed_cost_per_entry_ms_seq;        // Mixed GC每Entry成本

  // ===== 拷贝成本 =====
  TruncatedSeq* _cost_per_byte_ms_seq;               // 每字节拷贝成本
  TruncatedSeq* _cost_per_byte_ms_during_cm_seq;     // 并发标记期间拷贝成本

  // ===== 其他开销 =====
  TruncatedSeq* _constant_other_time_ms_seq;         // 固定开销
  TruncatedSeq* _young_other_cost_per_region_ms_seq; // Young Region额外开销
  TruncatedSeq* _non_young_other_cost_per_region_ms_seq; // Old Region额外开销

  // ===== 待处理数据 =====
  TruncatedSeq* _pending_cards_seq;                  // 待处理Card数
  TruncatedSeq* _rs_lengths_seq;                     // RSet长度

  // ===== GC 时间比率 =====
  double _recent_avg_pause_time_ratio;               // 平均暂停时间比率
  double _last_pause_time_ratio;                     // 最近一次暂停比率
};
```

**内存布局**：

```
G1Analytics 对象 (~600 bytes)
┌─────────────────────────────────────────────────────────────┐
│ _predictor: G1Predictions* (8 bytes)                        │
├─────────────────────────────────────────────────────────────┤
│ TruncatedSeq 指针数组 (18个指针，每个8字节 = 144 bytes)       │
│  [0]: _recent_gc_times_ms ──────┐                           │
│  [1]: _concurrent_mark_remark...──┼──┐                      │
│  [2]: _alloc_rate_ms_seq ────────┼──┼──┐                   │
│  ...                             │  │  │                    │
│  [17]: _rs_lengths_seq ──────────┘  │  │                    │
├─────────────────────────────────────┼──┼────────────────────┤
│ _prev_collection_pause_end_ms (8)  │  │                    │
│ _recent_avg_pause_time_ratio (8)   │  │                    │
│ _last_pause_time_ratio (8)         │  │                    │
└─────────────────────────────────────┼──┼────────────────────┘
                                      │  │
              ┌───────────────────────┘  │
              │  ┌────────────────────────┘
              │  │
              ▼  ▼
        每个TruncatedSeq独立分配在堆上
        ┌───────────┐  ┌───────────┐  ┌───────────┐
        │ TruncSeq  │  │ TruncSeq  │  │ TruncSeq  │
        │ + 数组    │  │ + 数组    │  │ + 数组    │
        └───────────┘  └───────────┘  └───────────┘
```

---

## 3. 核心算法：衰减平均（Decaying Average）

### 3.1 为什么不用普通平均？

**普通平均的问题**：
```
假设记录了最近10次GC时间：[100, 100, 100, 100, 100, 100, 100, 100, 100, 200]
普通平均 = 110ms
```

问题：第10次GC耗时突增（可能是负载变化），但普通平均只给了10%权重，
无法快速反映**当前状态**。

**衰减平均的优势**：
- 最近的数据权重更高
- 能快速适应变化
- 不需要保存所有历史数据（只需要当前值和衰减值）

### 3.2 算法实现（逐行分析）

**源码位置**：`utilities/numberSeq.cpp:36-48`

```cpp
void AbsSeq::add(double val) {
  if (_num == 0) {
    // 【Line 38-41】第一个元素：衰减平均=当前值，方差=0
    _davg = val;
    _dvariance = 0.0;
  } else {
    // 【Line 44】衰减平均公式 ★★★★★
    // _davg_new = (1 - alpha) * val + alpha * _davg_old
    // alpha = 0.7 (默认)
    //   => 新值占30%权重，历史值占70%权重
    _davg = (1.0 - _alpha) * val + _alpha * _davg;

    // 【Line 45-46】衰减方差公式
    // 计算当前值与衰减平均的偏差
    double diff = val - _davg;
    // 方差也采用衰减：新偏差平方占30%，历史方差占70%
    _dvariance = (1.0 - _alpha) * diff * diff + _alpha * _dvariance;
  }
}
```

**衰减平均数学推导**：

设 `alpha = 0.7`，展开递归：

```
davg[n] = 0.3 * val[n] + 0.7 * davg[n-1]
        = 0.3 * val[n] + 0.7 * (0.3 * val[n-1] + 0.7 * davg[n-2])
        = 0.3 * val[n] + 0.21 * val[n-1] + 0.49 * davg[n-2]
        = 0.3 * val[n] + 0.21 * val[n-1] + 0.147 * val[n-2] + 0.343 * davg[n-3]
        ...
```

**权重分布（alpha=0.7）**：

```
样本索引    权重
─────────────────────
n (最新)    0.3000 (30%)
n-1         0.2100 (21%)
n-2         0.1470 (14.7%)
n-3         0.1029 (10.3%)
n-4         0.0720 (7.2%)
n-5         0.0504 (5.0%)
n-6         0.0353 (3.5%)
n-7         0.0247 (2.5%)
...
```

**关键观察**：
1. **最近3个样本占了65%权重**（0.3+0.21+0.147）
2. **权重呈指数衰减**，符合"近大远小"原则
3. **alpha越大，衰减越快**（历史权重越高，越平滑）
4. **alpha越小，对新值越敏感**（但波动更大）

### 3.3 预测公式（加入置信区间）

**源码位置**：`gc/g1/g1Predictions.hpp:57-59`

```cpp
double get_new_prediction(TruncatedSeq const* seq) const {
  // 预测值 = 衰减平均 + 置信因子 * 标准差估计
  return seq->davg() + _sigma * stddev_estimate(seq);
}
```

**stddev_estimate 实现**（`g1Predictions.hpp:41-48`）：

```cpp
double stddev_estimate(TruncatedSeq const* seq) const {
  double estimate = seq->dsd();  // 衰减标准差
  int const samples = seq->num();

  // 【Line 44-46】小样本修正 ★★★
  // 样本数 < 5 时，标准差不可靠，用平均值的一部分代替
  if (samples < 5) {
    // 样本数=1: 使用 2 * 平均值
    // 样本数=4: 使用 0.5 * 平均值
    estimate = MAX2(seq->davg() * (5 - samples) / 2.0, estimate);
  }
  return estimate;
}
```

**小样本修正示例**：

```
样本数  修正系数  标准差估计
──────────────────────────────
1       2.0      2.0 * davg
2       1.5      1.5 * davg
3       1.0      1.0 * davg
4       0.5      0.5 * davg
5+      -        使用实际标准差
```

**为什么需要小样本修正？**
- 1个样本时，标准差为0，预测值=平均值
- 但实际不确定性很大，需要保守估计
- 用平均值的倍数表示"更保守"的预测

### 3.4 置信因子 sigma

**源码位置**：`gc/g1/g1_globals.hpp:60-62`

```cpp
product(uintx, G1ConfidencePercent, 50,        // 默认50
        "Confidence level for MMU/pause predictions")
        range(0, 100)
```

**G1Policy 构造函数**（`g1Policy.cpp:50`）：

```cpp
_predictor(G1ConfidencePercent / 100.0)  // sigma = 0.5
```

**sigma 的作用**：

```
sigma = 0.5 表示：
  预测值 = 衰减平均 + 0.5 * 标准差

sigma 越大 → 预测越保守（预测值更大）
sigma 越小 → 预测越激进（预测值接近平均值）
```

**示例**：

```
假设：
  衰减平均 = 100ms
  标准差 = 20ms

不同 sigma 的预测值：
  sigma = 0.0 → 预测值 = 100ms （最激进）
  sigma = 0.5 → 预测值 = 110ms （默认）
  sigma = 1.0 → 预测值 = 120ms （保守）
  sigma = 2.0 → 预测值 = 140ms （非常保守）
```

---

## 4. TruncatedSeq::add() 完整流程

**源码位置**：`utilities/numberSeq.cpp:145-167`

```cpp
void TruncatedSeq::add(double val) {
  // 【Line 146】先调用基类的 add()，更新衰减平均和方差
  AbsSeq::add(val);

  // 【Line 149】获取即将被覆盖的最老值
  double old_val = _sequence[_next];

  // 【Line 151-152】从普通平均的统计中移除最老值
  _sum -= old_val;
  _sum_of_squares -= old_val * old_val;

  // 【Line 155-156】加入新值
  _sum += val;
  _sum_of_squares += val * val;

  // 【Line 159】环形缓冲区：新值覆盖最老值
  _sequence[_next] = val;

  // 【Line 160】移动 _next 到下一个位置（环形）
  _next = (_next + 1) % _length;

  // 【Line 163-164】如果缓冲区未满，增加计数
  if (_num < _length)
    ++_num;

  // 【Line 166】断言：方差不应该为负
  guarantee(variance() > -1.0, "variance should be >= 0");
}
```

**环形缓冲区操作示意**（length=5）：

```
初始状态（空）：
_sequence: [ 0 | 0 | 0 | 0 | 0 ]
_next = 0, _num = 0

add(10)：
_sequence: [10 | 0 | 0 | 0 | 0 ]
_next = 1, _num = 1

add(20)：
_sequence: [10 |20 | 0 | 0 | 0 ]
_next = 2, _num = 2

...

add(50)（缓冲区满）：
_sequence: [10 |20 |30 |40 |50 ]
_next = 0, _num = 5
           ↑
         下一个将被覆盖

add(60)（覆盖最老值）：
_sequence: [60 |20 |30 |40 |50 ]
_next = 1, _num = 5
              ↑
            下一个将被覆盖
```

**关键点**：
1. **普通平均**：维护 `_sum` 和 `_sum_of_squares`，用于计算普通平均值和方差
2. **衰减平均**：只依赖 `_davg` 和 `_dvariance`，不需要保存历史值
3. **环形覆盖**：`_next` 指向最老元素，新值覆盖它后移动到下一个

---

## 5. G1Analytics 初始化与默认值

### 5.1 构造函数（逐行分析）

**源码位置**：`gc/g1/g1Analytics.cpp:72-116`

```cpp
G1Analytics::G1Analytics(const G1Predictions* predictor) :
    _predictor(predictor),
    // ===== 创建所有 TruncatedSeq =====
    _recent_gc_times_ms(new TruncatedSeq(NumPrevPausesForHeuristics)),  // 容量10
    _concurrent_mark_remark_times_ms(new TruncatedSeq(NumPrevPausesForHeuristics)),
    _concurrent_mark_cleanup_times_ms(new TruncatedSeq(NumPrevPausesForHeuristics)),
    _alloc_rate_ms_seq(new TruncatedSeq(TruncatedSeqLength)),  // 容量10
    _prev_collection_pause_end_ms(0.0),
    _rs_length_diff_seq(new TruncatedSeq(TruncatedSeqLength)),
    _cost_per_card_ms_seq(new TruncatedSeq(TruncatedSeqLength)),
    _cost_scan_hcc_seq(new TruncatedSeq(TruncatedSeqLength)),
    _young_cards_per_entry_ratio_seq(new TruncatedSeq(TruncatedSeqLength)),
    _mixed_cards_per_entry_ratio_seq(new TruncatedSeq(TruncatedSeqLength)),
    _cost_per_entry_ms_seq(new TruncatedSeq(TruncatedSeqLength)),
    _mixed_cost_per_entry_ms_seq(new TruncatedSeq(TruncatedSeqLength)),
    _cost_per_byte_ms_seq(new TruncatedSeq(TruncatedSeqLength)),
    _cost_per_byte_ms_during_cm_seq(new TruncatedSeq(TruncatedSeqLength)),
    _constant_other_time_ms_seq(new TruncatedSeq(TruncatedSeqLength)),
    _young_other_cost_per_region_ms_seq(new TruncatedSeq(TruncatedSeqLength)),
    _non_young_other_cost_per_region_ms_seq(new TruncatedSeq(TruncatedSeqLength)),
    _pending_cards_seq(new TruncatedSeq(TruncatedSeqLength)),
    _rs_lengths_seq(new TruncatedSeq(TruncatedSeqLength)),
    _recent_prev_end_times_for_all_gcs_sec(new TruncatedSeq(NumPrevPausesForHeuristics)),
    _recent_avg_pause_time_ratio(0.0),
    _last_pause_time_ratio(0.0) {

  // 【Line 98-99】记录初始时间
  _recent_prev_end_times_for_all_gcs_sec->add(os::elapsedTime());
  _prev_collection_pause_end_ms = os::elapsedTime() * 1000.0;

  // 【Line 101】根据GC线程数选择默认值索引
  // ParallelGCThreads-1 限制在 [0, 7] 范围
  int index = MIN2(ParallelGCThreads - 1, 7u);

  // 【Line 103-111】用默认值初始化序列 ★★★
  // 这些默认值是通过性能测试得出的经验值
  _rs_length_diff_seq->add(rs_length_diff_defaults[index]);
  _cost_per_card_ms_seq->add(cost_per_card_ms_defaults[index]);
  _cost_scan_hcc_seq->add(0.0);
  _young_cards_per_entry_ratio_seq->add(young_cards_per_entry_ratio_defaults[index]);
  _cost_per_entry_ms_seq->add(cost_per_entry_ms_defaults[index]);
  _cost_per_byte_ms_seq->add(cost_per_byte_ms_defaults[index]);
  _constant_other_time_ms_seq->add(constant_other_time_ms_defaults[index]);
  _young_other_cost_per_region_ms_seq->add(young_other_cost_per_region_ms_defaults[index]);
  _non_young_other_cost_per_region_ms_seq->add(non_young_other_cost_per_region_ms_defaults[index]);

  // 【Line 114-115】并发标记时间的保守估计
  _concurrent_mark_remark_times_ms->add(0.05);   // 50ms
  _concurrent_mark_cleanup_times_ms->add(0.20);  // 200ms
}
```

### 5.2 默认值表（基于GC线程数）

**源码位置**：`gc/g1/g1Analytics.cpp:37-70`

```cpp
// ===== RSet 长度差异 =====
static double rs_length_diff_defaults[] = {
  0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0  // 所有线程数都为0
};

// ===== 每张Card处理时间（ms）=====
// 线程数越多，每张Card的平均处理时间越短（并行效率）
static double cost_per_card_ms_defaults[] = {
  0.01,   // 1线程
  0.005,  // 2线程
  0.005,  // 3线程
  0.003,  // 4线程
  0.003,  // 5线程
  0.002,  // 6线程
  0.002,  // 7线程
  0.0015  // 8+线程
};

// ===== Young GC Card/Entry 比例 =====
static double young_cards_per_entry_ratio_defaults[] = {
  1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0  // 都是1.0
};

// ===== 每个Entry扫描时间（ms）=====
static double cost_per_entry_ms_defaults[] = {
  0.015,   // 1线程
  0.01,    // 2线程
  0.01,    // 3线程
  0.008,   // 4线程
  0.008,   // 5线程
  0.0055,  // 6线程
  0.0055,  // 7线程
  0.005    // 8+线程
};

// ===== 每字节拷贝时间（ms）=====
static double cost_per_byte_ms_defaults[] = {
  0.00006,    // 1线程
  0.00003,    // 2线程
  0.00003,    // 3线程
  0.000015,   // 4线程
  0.000015,   // 5线程
  0.00001,    // 6线程
  0.00001,    // 7线程
  0.000009    // 8+线程
};

// ===== 固定开销（ms）=====
static double constant_other_time_ms_defaults[] = {
  5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0  // 所有线程数都是5ms
};

// ===== Young Region额外开销（ms/Region）=====
static double young_other_cost_per_region_ms_defaults[] = {
  0.3,   // 1线程
  0.2,   // 2线程
  0.2,   // 3线程
  0.15,  // 4线程
  0.15,  // 5线程
  0.12,  // 6线程
  0.12,  // 7线程
  0.1    // 8+线程
};

// ===== Old Region额外开销（ms/Region）=====
static double non_young_other_cost_per_region_ms_defaults[] = {
  1.0,   // 1线程
  0.7,   // 2线程
  0.7,   // 3线程
  0.5,   // 4线程
  0.5,   // 5线程
  0.42,  // 6线程
  0.42,  // 7线程
  0.30   // 8+线程
};
```

**观察**：
1. **GC线程数越多，单位操作时间越短**（并行效率提升）
2. **默认值是经验值**，通过 `GCOld` 和 `SPECjbb` 基准测试得出
3. **初始时使用这些值**，运行中会被实际测量值替代

---

## 6. 预测使用示例：年轻代大小计算

### 6.1 目标

计算**年轻代目标大小**，使得 GC 暂停时间不超过 `MaxGCPauseMillis`（默认200ms）。

### 6.2 核心方法：calculate_young_list_target_length

**源码位置**：`gc/g1/g1Policy.cpp:326-426`

```cpp
uint G1Policy::calculate_young_list_target_length(
    size_t rs_lengths,         // 预测的RSet长度
    uint base_min_length,      // 基础最小长度（当前Survivor数）
    uint desired_min_length,   // 期望最小长度
    uint desired_max_length    // 期望最大长度
) const {

  // 【Line 335-337】边界检查
  if (desired_max_length <= desired_min_length) {
    return desired_min_length;
  }

  // 【Line 345-347】调整范围（排除已有的Survivor）
  uint min_young_length = desired_min_length - base_min_length;
  uint max_young_length = desired_max_length - base_min_length;

  // 【Line 349】目标暂停时间（默认200ms）
  const double target_pause_time_ms = _mmu_tracker->max_gc_time() * 1000.0;

  // 【Line 350】预测Survivor Region的回收时间
  const double survivor_regions_evac_time = predict_survivor_regions_evac_time();

  // 【Line 351-353】预测待处理的Card数和扫描Card数
  const size_t pending_cards = _analytics->predict_pending_cards();
  const size_t adj_rs_lengths = rs_lengths + _analytics->predict_rs_length_diff();
  const size_t scanned_cards = _analytics->predict_card_num(adj_rs_lengths, true);

  // 【Line 354-356】基础时间 = RSet更新 + RSet扫描 + Survivor回收
  const double base_time_ms =
    predict_base_elapsed_time_ms(pending_cards, scanned_cards) +
    survivor_regions_evac_time;

  // 【Line 357-359】可用空闲Region数（排除保留Region）
  const uint base_free_regions = available_free_regions > _reserve_regions
    ? available_free_regions - _reserve_regions : 0;

  // 【Line 364-368】创建预测器对象
  G1YoungLengthPredictor p(
    collector_state()->mark_or_rebuild_in_progress(),
    base_time_ms,
    base_free_regions,
    target_pause_time_ms,
    this
  );

  // 【Line 369-420】二分搜索找到最优年轻代大小 ★★★
  if (p.will_fit(min_young_length)) {
    if (p.will_fit(max_young_length)) {
      // 最大值也能满足暂停时间目标
      min_young_length = max_young_length;
    } else {
      // 二分搜索
      uint diff = (max_young_length - min_young_length) / 2;
      while (diff > 0) {
        uint young_length = min_young_length + diff;
        if (p.will_fit(young_length)) {
          min_young_length = young_length;
        } else {
          max_young_length = young_length;
        }
        diff = (max_young_length - min_young_length) / 2;
      }
    }
  }

  return base_min_length + min_young_length;
}
```

### 6.3 G1YoungLengthPredictor::will_fit

**源码位置**：`gc/g1/g1Policy.cpp:169-206`

```cpp
bool will_fit(uint young_length) const {
  // 【Line 170-172】边界检查1：空间不足
  if (young_length >= _base_free_regions) {
    return false;
  }

  // 【Line 175】预测累积存活率
  const double accum_surv_rate = _policy->accum_yg_surv_rate_pred((int)young_length - 1);

  // 【Line 176-177】预测需要拷贝的字节数
  const size_t bytes_to_copy =
    (size_t)(accum_surv_rate * (double)HeapRegion::GrainBytes);

  // 【Line 178-179】预测拷贝时间
  const double copy_time_ms =
    _policy->analytics()->predict_object_copy_time_ms(bytes_to_copy, _during_cm);

  // 【Line 180】预测Young Region额外开销
  const double young_other_time_ms =
    _policy->analytics()->predict_young_other_time_ms(young_length);

  // 【Line 181】预测总暂停时间
  const double pause_time_ms = _base_time_ms + copy_time_ms + young_other_time_ms;

  // 【Line 182-184】边界检查2：超过暂停时间目标
  if (pause_time_ms > _target_pause_time_ms) {
    return false;
  }

  // 【Line 187-196】边界检查3：空间不足（考虑安全系数）
  const size_t free_bytes = (_base_free_regions - young_length) * HeapRegion::GrainBytes;

  // 安全系数：考虑预测不确定性和PLAB浪费
  const double safety_factor = (100.0 / G1ConfidencePercent) * (100 + TargetPLABWastePct) / 100.0;
  const size_t expected_bytes_to_copy = (size_t)(safety_factor * bytes_to_copy);

  if (expected_bytes_to_copy > free_bytes) {
    return false;
  }

  return true;
}
```

### 6.4 预测流程图

```
┌──────────────────────────────────────────────────────────────┐
│          计算 Young Generation 目标大小                      │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────────┐
        │  1. 获取预测数据                       │
        │  - predict_pending_cards()            │
        │  - predict_rs_lengths()               │
        │  - predict_alloc_rate_ms()            │
        │  - predict_cost_per_card_ms()         │
        │  - ...                                │
        └───────────────────────────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────────┐
        │  2. 计算基础时间                       │
        │  base_time =                          │
        │    RSet更新时间 + RSet扫描时间 +      │
        │    Survivor回收时间                   │
        └───────────────────────────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────────┐
        │  3. 二分搜索                          │
        │                                       │
        │  min = 最小Young长度                  │
        │  max = 最大Young长度                  │
        │                                       │
        │  while (min < max) {                  │
        │    mid = (min + max) / 2              │
        │    if (will_fit(mid)) {               │
        │      // 预测暂停时间 ≤ 目标时间      │
        │      min = mid                        │
        │    } else {                           │
        │      max = mid                        │
        │    }                                  │
        │  }                                    │
        └───────────────────────────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────────┐
        │  will_fit(young_length) 判断          │
        │                                       │
        │  1. 空间足够？                        │
        │  2. 暂停时间 ≤ 目标？                 │
        │  3. 拷贝后空间足够？（安全系数）     │
        └───────────────────────────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────────┐
        │  返回最优 young_length                │
        └───────────────────────────────────────┘
```

---

## 7. GDB 验证脚本

### 7.1 查看衰减平均计算过程

```bash
# 创建GDB脚本
cat > /data/workspace/openjdk-cut-new/jvm-md/tmp-file/predictions/verify_decaying_avg.gdb << 'EOF'
# 设置断点在 AbsSeq::add
break AbsSeq::add

commands 1
  # 打印当前值和历史衰减平均
  printf "=== AbsSeq::add() called ===\n"
  printf "val = %f\n", $arg0
  printf "_num = %d\n", _num
  printf "_davg (before) = %f\n", _davg
  printf "_alpha = %f\n", _alpha
  continue
end

# 设置断点在 G1Predictions::get_new_prediction
break G1Predictions::get_new_prediction

commands 2
  printf "\n=== G1Predictions::get_new_prediction() ===\n"
  printf "sigma = %f\n", ((G1Predictions*)this)->_sigma
  continue
end

run
EOF

# 运行
gdb -x /data/workspace/openjdk-cut-new/jvm-md/tmp-file/predictions/verify_decaying_avg.gdb \
    /data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java
```

### 7.2 查看 G1Analytics 所有序列的当前值

```bash
cat > /data/workspace/openjdk-cut-new/jvm-md/tmp-file/predictions/print_analytics.gdb << 'EOF'
# 在GC结束后打印所有统计序列

define print_truncated_seq
  printf "  num=%d, davg=%.6f, dsd=%.6f, last=%.6f\n", \
         $arg0->_num, $arg0->_davg, \
         (double)sqrt($arg0->_dvariance), \
         ((TruncatedSeq*)$arg0)->last()
end

break G1CollectedHeap::collect

commands 1
  # 打印所有TruncatedSeq的统计信息
  printf "\n===== G1Analytics Statistics =====\n"

  printf "\n1. GC Times:\n"
  print_truncated_seq _analytics->_recent_gc_times_ms

  printf "\n2. Alloc Rate:\n"
  print_truncated_seq _analytics->_alloc_rate_ms_seq

  printf "\n3. Cost Per Card:\n"
  print_truncated_seq _analytics->_cost_per_card_ms_seq

  printf "\n4. Cost Per Entry:\n"
  print_truncated_seq _analytics->_cost_per_entry_ms_seq

  printf "\n5. Cost Per Byte:\n"
  print_truncated_seq _analytics->_cost_per_byte_ms_seq

  printf "\n6. Pending Cards:\n"
  print_truncated_seq _analytics->_pending_cards_seq

  printf "\n7. RS Lengths:\n"
  print_truncated_seq _analytics->_rs_lengths_seq

  continue
end

run
EOF
```

### 7.3 追踪年轻代大小计算

```bash
cat > /data/workspace/openjdk-cut-new/jvm-md/tmp-file/predictions/trace_young_length.gdb << 'EOF'
# 追踪年轻代目标长度计算

break G1Policy::calculate_young_list_target_length

commands 1
  printf "\n=== calculate_young_list_target_length ===\n"
  printf "rs_lengths = %lu\n", $arg0
  printf "base_min_length = %u\n", $arg1
  printf "desired_min_length = %u\n", $arg2
  printf "desired_max_length = %u\n", $arg3
  continue
end

break G1Policy::predict_region_elapsed_time_ms

commands 2
  printf "predict_region_elapsed_time_ms: region=%p, for_young=%d\n", $arg0, $arg1
  continue
end

run
EOF
```

---

## 8. 数据流图：预测模型的输入与输出

```
┌────────────────────────────────────────────────────────────────────────┐
│                          数据来源（每次GC后记录）                       │
└────────────────────────────────────────────────────────────────────────┘
                                    │
        ┌───────────────────────────┼───────────────────────────┐
        │                           │                           │
        ▼                           ▼                           ▼
┌───────────────┐         ┌───────────────┐         ┌───────────────┐
│ GC Phase      │         │ RSet Stats    │         │ Copy Stats    │
│ Times         │         │               │         │               │
│ - Update RS   │         │ - rs_length   │         │ - bytes_copied│
│ - Scan RS     │         │ - pending_cards│        │ - copy_time   │
│ - Object Copy │         │ - cards_scanned│        │               │
└───────┬───────┘         └───────┬───────┘         └───────┬───────┘
        │                         │                         │
        └─────────────────────────┼─────────────────────────┘
                                  │
                                  ▼
                    ┌───────────────────────────────┐
                    │      G1Analytics::report_*()  │
                    │  添加到对应的 TruncatedSeq    │
                    └───────────────┬───────────────┘
                                    │
                                    ▼
                    ┌───────────────────────────────┐
                    │   TruncatedSeq::add(val)      │
                    │   更新 _davg 和 _dvariance    │
                    └───────────────┬───────────────┘
                                    │
        ┌───────────────────────────┼───────────────────────────┐
        │                           │                           │
        ▼                           ▼                           ▼
┌───────────────┐         ┌───────────────┐         ┌───────────────┐
│ predict_gc_   │         │ predict_alloc_│         │ predict_copy_ │
│ time()        │         │ rate()        │         │ time()        │
└───────┬───────┘         └───────┬───────┘         └───────┬───────┘
        │                         │                         │
        │                         │                         │
        │  ┌──────────────────────┴───────────────────────┐│
        │  │       G1Predictions::get_new_prediction()     ││
        │  │                                               ││
        │  │  return davg + sigma * stddev_estimate(seq)  ││
        │  └──────────────────────┬───────────────────────┘│
        │                         │                         │
        └─────────────────────────┼─────────────────────────┘
                                  │
                                  ▼
                    ┌───────────────────────────────┐
                    │          G1Policy 决策        │
                    └───────────────────────────────┘
                                    │
        ┌───────────────────────────┼───────────────────────────┐
        │                           │                           │
        ▼                           ▼                           ▼
┌───────────────┐         ┌───────────────┐         ┌───────────────┐
│ 年轻代大小    │         │ CSet 选择     │         │ IHOP 触发     │
│ 计算         │         │ 效率排序      │         │ 判断          │
└───────────────┘         └───────────────┘         └───────────────┘
```

---

## 9. 关键问题与解答

### Q1: 为什么用衰减平均而不是滑动窗口平均？

**A**:
- **衰减平均优点**：只需要存储一个值（`_davg`），不需要保存所有历史数据
- **滑动窗口平均**：需要保存最近N个值，内存开销更大
- **G1选择衰减平均**：统计指标种类多（18个TruncatedSeq），内存敏感
- **缺点**：衰减平均对突变敏感度可通过`alpha`调节

### Q2: G1ConfidencePercent 应该设为多少？

**A**:
- **默认值50**：`prediction = davg + 0.5 * stddev`
- **增大（如80）**：预测更保守，GC更早触发，暂停时间更有保证
- **减小（如20）**：预测更激进，GC推迟，吞吐量可能提升但暂停时间可能超标
- **建议**：保持默认，除非有明确的暂停时间/吞吐量调优目标

### Q3: 小样本修正的意义是什么？

**A**:
- **问题**：样本数少时，标准差为0或不可靠
- **解决**：用平均值的倍数代替标准差，表示"不确定性"
- **效果**：
  - 1个样本：`prediction = davg + 2*davg = 3*davg`（非常保守）
  - 5个样本：使用实际标准差

### Q4: 年轻代大小预测如何影响GC行为？

**A**:
1. **预测GC耗时** → 调整年轻代大小
2. **年轻代大** → GC频率低，但单次暂停时间长
3. **年轻代小** → GC频率高，单次暂停时间短
4. **目标**：找到最大年轻代大小，使得预测暂停时间 ≤ `MaxGCPauseMillis`

---

## 10. 源码位置索引

| 文件 | 行号 | 内容 |
|------|------|------|
| `utilities/numberSeq.hpp` | 45-86 | AbsSeq 基类定义 |
| `utilities/numberSeq.hpp` | 107-132 | TruncatedSeq 类定义 |
| `utilities/numberSeq.cpp` | 36-48 | 衰减平均算法实现 |
| `utilities/numberSeq.cpp` | 145-167 | TruncatedSeq::add() |
| `gc/g1/g1Predictions.hpp` | 31-60 | G1Predictions 类 |
| `gc/g1/g1Analytics.hpp` | 34-159 | G1Analytics 类定义 |
| `gc/g1/g1Analytics.cpp` | 37-70 | 默认值表 |
| `gc/g1/g1Analytics.cpp` | 72-116 | G1Analytics 构造函数 |
| `gc/g1/g1Policy.cpp` | 326-426 | calculate_young_list_target_length |
| `gc/g1/g1Policy.cpp` | 169-206 | G1YoungLengthPredictor::will_fit |
| `gc/g1/g1_globals.hpp` | 60-62 | G1ConfidencePercent 定义 |

---

## 11. 总结

**G1预测模型的核心思想**：
1. **追踪历史**：用TruncatedSeq记录最近N次GC的各项指标
2. **衰减平均**：给最近数据更高权重，快速适应变化
3. **置信区间**：`prediction = davg + sigma * stddev`，考虑不确定性
4. **自适应决策**：基于预测调整年轻代大小、CSet选择、IHOP触发等

**参数调优建议**：
- `G1ConfidencePercent`：增大使预测更保守（适合暂停时间敏感场景）
- `MaxGCPauseMillis`：影响年轻代大小上限
- 默认配置在大多数场景下已经足够

**关键数据结构**：
- `TruncatedSeq`：环形缓冲区+衰减平均
- `G1Analytics`：18个统计序列，追踪所有GC指标
- `G1Predictions`：提供带置信区间的预测接口
