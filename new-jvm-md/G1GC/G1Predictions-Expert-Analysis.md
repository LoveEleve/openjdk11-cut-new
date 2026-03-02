# G1Predictions 专家级源码分析

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1Predictions 的本质是**基于 EMA（指数移动平均）的预测引擎**：从 `TruncatedSeq`（截断历史序列）中计算加权移动平均和标准差，生成带置信区间的预测值；`G1Policy` 用这些预测值计算 CSet 大小和 IHOP 阈值，实现"可预测的停顿时间"。

### 0.2 为什么需要？

G1Policy 需要预测"回收 N 个 Region 需要多少时间"，但 GC 代价随应用负载动态变化。简单平均对历史数据等权，无法快速响应变化；EMA 让近期数据权重更高，能快速适应应用行为变化（如突发大量对象分配）。

### 0.3 怎么解决？

**EMA + 置信区间**：`predict_in_unit_intervals(seq)` = `seq.davg() + confidence_factor × seq.dsd()`；`davg()` 是 EMA（衰减因子 0.5）；`dsd()` 是标准差估计；`confidence_factor` 默认 1.645（95% 置信区间）；预测值偏保守（加上标准差），避免低估停顿时间。

### 0.4 为什么这样设计？

- **为什么预测值要加上标准差？** 如果预测值等于 EMA（均值），有 50% 概率实际停顿超过预测值；加上标准差后，实际停顿超过预测值的概率降低到 5%（95% 置信区间）；G1 宁可少回收一些 Region，也不要停顿超标
- **为什么衰减因子是 0.5？** 衰减因子 0.5 意味着最近一次样本权重 50%，前一次 25%，再前一次 12.5%...；这是一个快速响应变化的设置；可通过 `-XX:G1ConfidencePercent` 调整

---

## 一、宏观理解：预测算法的数学基础

### 1.1 一句话总结

**G1Predictions 是 G1 的预测引擎**，基于**加权移动平均**和**标准差估计**，将历史 GC 统计数据转换为对未来 GC 行为的预测值。

### 1.2 为什么需要预测？

**问题背景**：
- G1 的核心目标是**可预测的暂停时间**（MaxGCPauseMillis）
- 但每次 Young GC 的时间取决于：年轻代大小、记忆集扫描时间、对象复制时间
- 这些因素随应用程序行为动态变化

**解决方案**：
- 维护历史统计数据（如过去 10 次 GC 的暂停时间）
- 使用**预测模型**估计未来的 GC 时间
- 基于预测值计算最优的年轻代大小

### 1.3 核心预测公式

```
预测值 = 历史加权平均 + 置信系数 × 标准差估计

即：prediction = davg + sigma × stddev_estimate
```

**公式解读**：
- **davg（加权移动平均）**：反映历史数据的中心趋势
- **sigma（置信系数）**：G1ConfidencePercent / 100.0（默认 0.5）
- **stddev_estimate（标准差估计）**：反映数据的波动程度
- **整体设计**：预测值 = 预期值 + 安全余量（应对波动）

### 1.4 小样本特殊处理

**问题**：当样本数量很少时（如刚开始运行），标准差不稳定

**解决方案**：
```
如果样本数 < 5：
    stddev_estimate = max(实际标准差, davg × (5 - 样本数) / 2)

样本数 = 1: stddev_estimate = davg × 2.0  (保守估计)
样本数 = 2: stddev_estimate = davg × 1.5
样本数 = 3: stddev_estimate = davg × 1.0
样本数 = 4: stddev_estimate = davg × 0.5
样本数 >= 5: stddev_estimate = 实际标准差
```

### 1.5 在 G1 中的位置

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         G1Predictions 在系统中的位置                          │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                              G1Policy                                        │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                         G1Predictions                                  │  │
│  │                                                                       │  │
│  │    get_new_prediction(seq) = seq->davg() + sigma × stddev_estimate    │  │
│  │                                                                       │  │
│  │    ┌─────────────────────────────────────────────────────────────┐   │  │
│  │    │                    TruncatedSeq                              │   │  │
│  │    │  - 维护最近 10 个历史样本                                     │   │  │
│  │    │  - davg(): 加权移动平均 (alpha=0.7)                           │   │  │
│  │    │  - dsd(): 加权标准差                                          │   │  │
│  │    └─────────────────────────────────────────────────────────────┘   │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            G1Analytics                                       │
│  维护 15+ 个 TruncatedSeq 实例，分别跟踪：                                      │
│  - _recent_gc_times_ms: 最近 GC 暂停时间                                       │
│  - _alloc_rate_ms_seq: 内存分配速率                                           │
│  - _cost_per_card_ms_seq: 每张卡片处理成本                                     │
│  - ...                                                                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 二、字段分析：数据结构的完整解剖

### 2.1 类定义与内存布局

```cpp
// g1Predictions.hpp:31-60
class G1Predictions {
 private:
  double _sigma;  // 置信系数（默认 0.5）

  double stddev_estimate(TruncatedSeq const* seq) const {
    double estimate = seq->dsd();  // 加权标准差
    int const samples = seq->num();
    if (samples < 5) {
      estimate = MAX2(seq->davg() * (5 - samples) / 2.0, estimate);
    }
    return estimate;
  }

 public:
  G1Predictions(double sigma) : _sigma(sigma) {
    assert(sigma >= 0.0, "Confidence must be larger than or equal to zero");
  }

  double sigma() const { return _sigma; }

  double get_new_prediction(TruncatedSeq const* seq) const {
    return seq->davg() + _sigma * stddev_estimate(seq);
  }
};
```

**对象大小**：
```cpp
sizeof(G1Predictions) = 8  // 只有一个 double _sigma
```

### 2.2 核心字段详解

#### 2.2.1 `_sigma` —— 置信系数

**含义**：预测值的置信水平，决定安全余量的大小

**默认值推导**：
```cpp
// g1Policy.cpp:50
_predictor(G1ConfidencePercent / 100.0)

// G1ConfidencePercent 默认值 = 50
// 所以 _sigma = 50 / 100.0 = 0.5
```

**作用效果**：
| sigma 值 | 预测偏向 | 适用场景 |
|---------|---------|---------|
| 0.0 | 纯平均，无余量 | 非常稳定的应用 |
| 0.5（默认） | 平均 + 0.5×标准差 | 一般应用 |
| 1.0 | 平均 + 1.0×标准差 | 波动大的应用 |
| 更高 | 更保守的预测 | 对延迟敏感的应用 |

**JVM 参数调整**：
```bash
# 调整置信百分比（默认 50）
-XX:G1ConfidencePercent=70  # 更保守的预测
-XX:G1ConfidencePercent=30  # 更激进的预测
```

### 2.3 TruncatedSeq —— 数据容器

G1Predictions 本身很简单，核心在于 `TruncatedSeq` 的数据结构。

#### 2.3.1 类继承关系

```
AbsSeq (抽象基类)
    ├── NumberSeq (全量序列)
    └── TruncatedSeq (截断序列，只保留最近 L 个)  <-- G1 使用这个
```

#### 2.3.2 TruncatedSeq 内存布局

```cpp
// numberSeq.hpp:107-132
class TruncatedSeq: public AbsSeq {
 private:
  enum PrivateConstants {
    DefaultSeqLength = 10  // 默认保留最近 10 个样本
  };

 protected:
  double *_sequence;  // 循环数组，存储最近 L 个值
  int     _length;    // L，数组长度（默认 10）
  int     _next;      // 下一个要覆盖的位置（循环指针）

  // 继承自 AbsSeq:
  int    _num;        // 当前样本数
  double _sum;        // 所有样本的和
  double _sum_of_squares;  // 平方和
  double _davg;       // 加权移动平均
  double _dvariance;  // 加权方差
  double _alpha;      // 衰减系数（默认 0.7）
};
```

**对象大小**（64-bit 系统）：
```
TruncatedSeq 大小 = 
    AbsSeq 基类: 56 bytes (7个 double/int)
    _sequence: 8 bytes (指针)
    _length: 4 bytes
    _next: 4 bytes
    对齐: 8 bytes
    -----------------
    总计: ~80 bytes + 动态数组 (10 × 8 = 80 bytes)
```

#### 2.3.3 核心方法解析

**`add(double val)` —— 添加新样本**

```cpp
void TruncatedSeq::add(double val) {
    // 1. 保存旧值（用于更新 sum 和 sum_of_squares）
    double old_val = 0.0;
    if (_num >= _length) {
        old_val = _sequence[_next];  // 即将被覆盖的值
    }
    
    // 2. 存入循环数组
    _sequence[_next] = val;
    _next = (_next + 1) % _length;  // 循环指针后移
    
    // 3. 更新统计量（继承自 AbsSeq）
    AbsSeq::add(val);
    
    // 4. 更新加权移动平均和方差
    if (_num == 0) {
        _davg = val;
        _dvariance = 0.0;
    } else {
        double diff = val - _davg;
        _davg = (1.0 - _alpha) * val + _alpha * _davg;
        _dvariance = (1.0 - _alpha) * diff * diff + _alpha * _dvariance;
    }
}
```

**加权移动平均算法详解**：

```
davg_new = (1 - alpha) × new_value + alpha × davg_old

默认 alpha = 0.7，意味着：
- 新值权重 = 30%
- 历史权重 = 70%

这个设计让历史数据有更大影响，预测更稳定。

示例（alpha=0.7）：
  第1次: davg = 100
  第2次: davg = 0.3×110 + 0.7×100 = 103
  第3次: davg = 0.3×120 + 0.7×103 = 108.1
  第4次: davg = 0.3×90 + 0.7×108.1 = 102.67

对比普通平均：(100+110+120+90)/4 = 105
加权平均对最新值响应更快，但不过度反应。
```

**`davg()` 和 `dsd()` —— 获取统计值**

```cpp
// numberSeq.hpp:79-81
double davg() const;      // 返回 _davg（加权移动平均）
double dvariance() const; // 返回 _dvariance（加权方差）
double dsd() const;       // 返回 sqrt(_dvariance)（加权标准差）
```

### 2.4 GDB 字段验证脚本

```gdb
# g1predictions_fields.gdb - G1Predictions & TruncatedSeq 验证

# 设置断点在 G1Policy 初始化后
break g1Policy.cpp:71
commands
    silent
    printf "\n=== G1Predictions 字段分析 ===\n"
    
    # G1Predictions 对象
    printf "&_predictor = 0x%lx\n", (unsigned long)&_predictor
    printf "sizeof(G1Predictions) = %zu\n", sizeof(G1Predictions)
    printf "_predictor._sigma = %f\n", _predictor._sigma
    printf "G1ConfidencePercent = %d (default: 50)\n", 50
    
    continue
end

# 设置断点在添加 GC 统计时
break g1Analytics.cpp:75
commands
    silent
    printf "\n=== TruncatedSeq 分析 (_recent_gc_times_ms) ===\n"
    
    # 假设我们可以访问到 _recent_gc_times_ms
    # 实际调试时需要根据具体对象路径调整
    
    printf "sizeof(TruncatedSeq) = %zu\n", sizeof(TruncatedSeq)
    printf "DefaultSeqLength = 10\n"
    printf "DEFAULT_ALPHA_VALUE = 0.7\n"
    
    continue
end

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main
```

---

## 三、方法分析：预测算法的数学原理

### 3.1 核心方法：`get_new_prediction()`

```cpp
// g1Predictions.hpp:57-59
double get_new_prediction(TruncatedSeq const* seq) const {
    return seq->davg() + _sigma * stddev_estimate(seq);
}
```

**数学公式**：
```
P = μ + σ × SE

其中：
  P = 预测值 (prediction)
  μ = 加权移动平均 (davg)
  σ = 置信系数 (_sigma, 默认 0.5)
  SE = 标准差估计 (stddev_estimate)
```

### 3.2 标准差估计方法：`stddev_estimate()`

```cpp
// g1Predictions.hpp:41-48
double stddev_estimate(TruncatedSeq const* seq) const {
    double estimate = seq->dsd();  // 加权标准差
    int const samples = seq->num();
    if (samples < 5) {
        estimate = MAX2(seq->davg() * (5 - samples) / 2.0, estimate);
    }
    return estimate;
}
```

**算法逻辑**：

```
样本数 >= 5: 直接使用加权标准差 (dsd)
样本数 < 5:  使用保守估计 max(dsd, davg × (5-n) / 2)

保守估计系数：
  n=1: davg × 2.0  (200%)
  n=2: davg × 1.5  (150%)
  n=3: davg × 1.0  (100%)
  n=4: davg × 0.5  (50%)
  n=5: davg × 0.0  (0%, 使用实际标准差)

为什么需要保守估计？
- 样本少时，统计标准差不稳定
- 避免预测值过于乐观，导致 GC 超时
- 随着样本增多，逐渐过渡到实际标准差
```

### 3.3 预测示例

**场景**：预测 Young GC 时间

```
历史 GC 时间（最近 10 次，单位 ms）：
  [120, 125, 118, 130, 122, 128, 115, 135, 121, 129]

计算过程：
  davg (加权平均) = 124.3 ms
  dsd (加权标准差) = 5.2 ms
  samples = 10 >= 5，使用实际标准差
  stddev_estimate = 5.2 ms

预测（不同 sigma）：
  sigma=0.0: 124.3 + 0.0×5.2 = 124.3 ms  (纯平均)
  sigma=0.5: 124.3 + 0.5×5.2 = 126.9 ms  (默认，+2.6ms 余量)
  sigma=1.0: 124.3 + 1.0×5.2 = 129.5 ms  (保守，+5.2ms 余量)
```

**对比**：如果暂停时间目标是 200ms，默认预测值 126.9ms 表明还有空间增加年轻代大小。

### 3.4 小样本场景示例

**场景**：应用启动后第 3 次 GC

```
历史 GC 时间（只有 3 次）：
  [150, 180, 210]

计算过程：
  davg = 178.5 ms
  dsd = 18.3 ms
  samples = 3 < 5，使用保守估计
  stddev_estimate = max(18.3, 178.5 × (5-3) / 2)
                  = max(18.3, 178.5)
                  = 178.5 ms

预测（sigma=0.5）：
  prediction = 178.5 + 0.5 × 178.5 = 267.8 ms

分析：
  小样本时，预测值非常保守（267.8ms）
  这是为了防止应用行为不稳定导致 GC 超时
  随着 GC 次数增加，预测会逐渐稳定
```

---

## 四、关联分析：组件交互图

### 4.1 G1Predictions 调用链

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        G1Predictions 调用链                                  │
└─────────────────────────────────────────────────────────────────────────────┘

用户代码分配对象
        │
        ▼
┌───────────────────┐
│ G1CollectedHeap   │
│ ::attempt_allocation│
└─────────┬─────────┘
          │ young_regions_count() >= _young_list_target_length?
          ▼
┌───────────────────┐
│   VM_GC_Operation │
│   (触发 GC)       │
└─────────┬─────────┘
          ▼
┌───────────────────┐
│  G1Policy         │
│  ::finalize_      │
│  collection_set() │
└─────────┬─────────┘
          │ 计算每个 Region 的预测时间
          ▼
┌───────────────────┐     ┌─────────────────────────────────────┐
│ predict_region_   │────>│ G1Predictions::get_new_prediction() │
│ elapsed_time_ms() │     │                                     │
└───────────────────┘     │  input: TruncatedSeq* (历史数据)    │
                          │  output: double (预测值)            │
                          │                                     │
                          │  formula: davg + sigma × stddev    │
                          └─────────────────────────────────────┘
                                          │
                                          ▼
                          ┌─────────────────────────────────────┐
                          │         TruncatedSeq                │
                          │  - 存储最近 10 个样本               │
                          │  - davg(): 加权移动平均             │
                          │  - dsd(): 加权标准差                │
                          └─────────────────────────────────────┘
```

### 4.2 G1Analytics 中的 TruncatedSeq 实例

```cpp
// g1Analytics.hpp:34-67
class G1Analytics {
    const static int TruncatedSeqLength = 10;  // 所有序列默认长度
    
    // GC 时间统计
    TruncatedSeq* _recent_gc_times_ms;              // 最近 GC 暂停时间
    TruncatedSeq* _concurrent_mark_remark_times_ms; // 并发标记 Remark 时间
    TruncatedSeq* _concurrent_mark_cleanup_times_ms;// 并发标记 Cleanup 时间
    
    // 分配和成本统计
    TruncatedSeq* _alloc_rate_ms_seq;               // 内存分配速率
    TruncatedSeq* _cost_per_card_ms_seq;            // 每张卡片处理成本
    TruncatedSeq* _cost_scan_hcc_seq;               // 扫描热卡片缓存成本
    TruncatedSeq* _cost_per_entry_ms_seq;           // 每个 RS 条目处理成本
    TruncatedSeq* _cost_per_byte_ms_seq;            // 每字节复制成本
    
    // RS 长度统计
    TruncatedSeq* _rs_length_diff_seq;              // RS 长度差异
    TruncatedSeq* _rs_lengths_seq;                  // RS 长度
    TruncatedSeq* _pending_cards_seq;               // 待处理卡片数
    
    // 其他统计
    TruncatedSeq* _constant_other_time_ms_seq;      // 其他固定时间
    TruncatedSeq* _young_other_cost_per_region_ms_seq;   // 年轻代其他成本
    TruncatedSeq* _non_young_other_cost_per_region_ms_seq;// 老年代其他成本
    
    // ... 共 15+ 个 TruncatedSeq 实例
};
```

**内存占用估算**：
```
每个 TruncatedSeq ≈ 160 bytes (对象头 + 数组 + 字段)
15 个 TruncatedSeq ≈ 2400 bytes ≈ 2.4 KB

相对于 G1 的其他数据结构（如卡表 16MB），可以忽略不计。
```

### 4.3 预测模型的数据流

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           预测模型数据流                                      │
└─────────────────────────────────────────────────────────────────────────────┘

GC 执行阶段
    │
    ▼
┌─────────────────────────────────┐
│ record_collection_pause_end()   │
│ (GC 结束后记录统计)              │
└─────────────┬───────────────────┘
              │ 提取本次 GC 数据
              ▼
┌─────────────────────────────────┐     ┌─────────────────────────────────┐
│ G1Analytics::report_*()         │────>│ 更新对应的 TruncatedSeq          │
│ - report_alloc_rate_ms()        │     │ - add(new_value)                │
│ - report_cost_per_card_ms()     │     │ - 更新 davg 和 dvariance        │
│ - report_rs_lengths()           │     │                                 │
│ - ...                           │     │ 算法:                           │
└─────────────────────────────────┘     │ davg = 0.3×new + 0.7×old       │
                                        │ dvar = 0.3×diff² + 0.7×old_var │
                                        └─────────────────────────────────┘
                                                        │
                    ┌───────────────────────────────────┼───────────────────┐
                    │                                   │                   │
                    ▼                                   ▼                   ▼
┌─────────────────────────────────┐     ┌─────────────────────────────────┐
│  下次 GC 触发前                  │     │ G1Policy::                      │
│  计算年轻代目标长度               │     │ predict_region_elapsed_time_ms()│
│                                 │     │                                 │
│ calculate_young_list_           │     │ 预测公式:                        │
│ target_length()                 │     │ prediction =                    │
│                                 │     │   davg + sigma × stddev         │
│ 需要预测:                        │<────┘                                 │
│ - 对象复制时间                   │                                       │
│ - RS 扫描时间                    │                                       │
│ - 其他开销                       │                                       │
└─────────────────────────────────┘                                       │
              │                                                          │
              ▼                                                          │
┌─────────────────────────────────┐                                      │
│ G1Predictions::                 │<─────────────────────────────────────┘
│ get_new_prediction()            │
│                                 │
│ 输入: TruncatedSeq*             │
│ 输出: double (预测时间)         │
└─────────────────────────────────┘
```

---

## 五、验证总结：GDB 调试与日志

### 5.1 查看预测值的日志

**启用 GC Ergonomics 日志**：
```bash
java -Xlog:gc+ergo*=debug:file=gc-ergo.log:time,uptime,level,tags \
     -Xms8g -Xmx8g -XX:+UseG1GC \
     -jar application.jar
```

**典型输出**：
```
# 年轻代大小调整决策
[12.345s][debug][gc,ergo] Young generation size adjustment:
    old target: 102 regions,
    new target: 156 regions,
    pause prediction: 198.45ms (target: 200ms),
    confidence: 50%

# CSet 选择决策
[15.678s][debug][gc,ergo] CSet selection:
    predicted young time: 125.34ms,
    predicted old time: 65.21ms,
    total predicted: 190.55ms,
    target: 200ms,
    adding 5 more old regions
```

### 5.2 验证预测准确度的方法

```gdb
# g1prediction_verify.gdb

# 在预测时打印详细信息
break G1Predictions::get_new_prediction
commands
    silent
    printf "\n=== G1Predictions::get_new_prediction ===\n"
    printf "seq address: 0x%lx\n", (unsigned long)seq
    printf "seq->num(): %d\n", seq->num()
    printf "seq->davg(): %f\n", seq->davg()
    printf "seq->dsd(): %f\n", seq->dsd()
    printf "_sigma: %f\n", _sigma
    
    set $stddev = stddev_estimate(seq)
    set $prediction = seq->davg() + _sigma * $stddev
    printf "stddev_estimate: %f\n", $stddev
    printf "prediction: %f\n", $prediction
    
    continue
end

run ...
```

### 5.3 预测准确度监控

**实际应用建议**：

| 监控指标 | 计算方法 | 健康范围 |
|---------|---------|---------|
| 预测误差率 | \|实际-预测\|/预测 | < 20% |
| 预测保守度 | 预测/实际 | 0.9 - 1.2 |
| 样本充足度 | TruncatedSeq::num() | >= 5 |

**如果预测误差大**：
1. 调整 `G1ConfidencePercent`（增加余量）
2. 检查应用负载是否突然变化
3. 考虑缩短 `TruncatedSeq` 长度（对变化更敏感）

---

## 六、总结

### 6.1 G1Predictions 的核心价值

G1Predictions 提供了**轻量级但有效的预测能力**：

1. **数学基础扎实**：加权移动平均 + 标准差估计，经典统计方法
2. **小样本鲁棒**：样本<5 时的保守估计策略
3. **可配置性强**：通过 `G1ConfidencePercent` 调整预测偏向

### 6.2 关键设计要点

| 设计点 | 说明 |
|-------|------|
| **加权移动平均** | alpha=0.7，历史权重 70%，新值权重 30% |
| **截断序列** | 只保留最近 10 个样本，避免历史数据主导 |
| **小样本保守** | 样本<5 时，使用 davg × (5-n)/2 作为标准差下界 |
| **安全余量** | prediction = davg + sigma × stddev |

### 6.3 对比其他预测方法

| 方法 | 优点 | 缺点 | G1 选择 |
|-----|------|------|--------|
| 简单平均 | 实现简单 | 对变化响应慢 | ❌ |
| 加权移动平均 | 平衡稳定和响应 | 需要调参 | ✅ |
| 指数平滑 | 响应快 | 可能过度反应 | ❌ |
| 线性回归 | 可预测趋势 | 计算复杂 | ❌ |
| 机器学习 | 精度高 | 开销大，难解释 | ❌ |

G1 选择**加权移动平均**是因为它在 JVM GC 场景下提供了最佳的**简单性、稳定性和响应性**平衡。

---

**文档信息**：
- 分析版本：OpenJDK 11
- 分析日期：2026-02-10
- 源码路径：
  - `/data/workspace/openjdk-cut-new/src/hotspot/share/gc/g1/g1Predictions.hpp`
  - `/data/workspace/openjdk-cut-new/src/hotspot/share/utilities/numberSeq.hpp`
