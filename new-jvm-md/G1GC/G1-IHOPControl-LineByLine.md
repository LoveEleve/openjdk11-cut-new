# G1IHOPControl：并发标记启动阈值控制

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1IHOPControl 的本质是**并发标记触发阈值的计算器**：维护 IHOP（Initiating Heap Occupancy Percent）阈值，当 Old 区占用率超过 IHOP 时触发并发标记；`G1StaticIHOPControl` 使用固定阈值（`-XX:InitiatingHeapOccupancyPercent`），`G1AdaptiveIHOPControl` 根据历史数据动态调整。

### 0.2 为什么需要？

并发标记需要时间（可能数秒），期间应用线程继续分配对象。如果 IHOP 太高，并发标记开始时堆已经很满，标记期间可能堆满触发 Full GC；如果 IHOP 太低，并发标记过于频繁，浪费 CPU。IHOP 需要在"足够早开始"和"不过于频繁"之间平衡。

### 0.3 自适应 IHOP 计算

```
IHOP = 堆大小 - 并发标记期间的预期分配量
预期分配量 = 分配速率（bytes/s）× 并发标记时间（s）
```

`G1AdaptiveIHOPControl` 从 `G1Analytics` 获取历史分配速率和并发标记时间，用 EMA 预测下次并发标记期间的分配量，动态调整 IHOP。

### 0.4 为什么这样设计？

- **为什么默认 IHOP 是 45%？** 45% 给并发标记留出 55% 的堆空间作为缓冲；经验值，适合大多数应用
- **为什么自适应 IHOP 比静态 IHOP 更好？** 不同应用的分配速率和并发标记时间差异很大；自适应 IHOP 根据历史数据找到最优值，避免静态值的过保守或过激进

---

## 1. 概览：解决什么问题？

### 1.1 背景：何时启动并发标记？

G1 GC 的并发标记周期需要在**合适的时机**启动：
- **启动太早**：老年代占用低，浪费并发标记资源
- **启动太晚**：老年代快速填满，来不及完成标记就触发 Full GC

**核心目标**：
```
找到最优的老年代占用阈值（IHOP），使得：

  标记开始时老年代占用
    + 标记期间老年代增长量
    ≤ 最终目标占用（避免 Full GC）
```

### 1.2 IHOP 的作用

```
┌────────────────────────────────────────────────────────────┐
│                   堆内存占用时间线                          │
└────────────────────────────────────────────────────────────┘

占用 ↑
     │
100% ├─────────────────────────────────────── Full GC危险线
     │
     │                                    ┌─ 标记完成
     │                               ┌────┤
     │                          ┌────┤    └─ Mixed GC 开始
     │                     ┌────┤    │
     │                ┌────┤    │    └─ 标记期间增长
     │           ┌────┤    │    │
     │      ┌────┤    │    │    │
     │ ─────┤    │    │    │    │
     │      │    │    │    │    │
     │      │    │    │    │    │
 45% ├──────┤    │    │    │    │
     │ IHOP │    │    │    │    │
     │      │    │    │    │    │
  0% └──────┴────┴────┴────┴────┴──────> 时间
          │
        启动并发标记

关键：
  IHOP 太低 → 标记完成时堆占用仍很低 → 浪费
  IHOP 太高 → 标记期间堆占用超过阈值 → Full GC
```

### 1.3 两种 IHOP 控制策略

**G1 提供两种实现**：

| 策略 | 类 | 特点 | 使用场景 |
|------|---|------|----------|
| **静态** | G1StaticIHOPControl | 固定阈值 | G1UseAdaptiveIHOP=false |
| **自适应** | G1AdaptiveIHOPControl | 动态调整 | G1UseAdaptiveIHOP=true（默认）|

---

## 2. 核心数据结构

### 2.1 继承层次

```
┌─────────────────────────────────────────────────────────┐
│                 G1IHOPControl (基类)                    │
│  - _initial_ihop_percent: double                       │
│  - _target_occupancy: size_t                           │
│  - _last_allocation_time_s: double                     │
│  - _old_gen_alloc_tracker: G1OldGenAllocationTracker*  │
└───────────────────────┬─────────────────────────────────┘
                        │ 继承
           ┌────────────┴────────────┐
           │                         │
┌──────────▼──────────┐    ┌─────────▼──────────┐
│ G1StaticIHOPControl │    │ G1AdaptiveIHOPControl│
│  - _last_marking_   │    │  - _marking_times_s │
│    length_s         │    │  - _allocation_rate_s│
│                     │    │  - _last_unrestrained│
│  固定阈值           │    │    _young_size      │
└─────────────────────┘    │  - _heap_reserve_%  │
                           │  - _heap_waste_%    │
                           │  - _predictor       │
                           └─────────────────────┘
```

### 2.2 G1IHOPControl 基类

**源码位置**：`gc/g1/g1IHOPControl.hpp:38-81`

```cpp
class G1IHOPControl : public CHeapObj<mtGC> {
protected:
  // 初始 IHOP 百分比（默认45%）
  double _initial_ihop_percent;

  // 目标占用（通常是堆最大容量）
  size_t _target_occupancy;

  // 最近一次 mutator 分配时间（秒）
  double _last_allocation_time_s;

  // 老年代分配追踪器
  const G1OldGenAllocationTracker* _old_gen_alloc_tracker;

public:
  // 获取并发标记启动阈值
  virtual size_t get_conc_mark_start_threshold() = 0;

  // 更新目标占用
  virtual void update_target_occupancy(size_t new_target_occupancy);

  // 更新分配信息
  virtual void update_allocation_info(double allocation_time_s, size_t additional_buffer_size);

  // 更新标记时长
  virtual void update_marking_length(double marking_length_s) = 0;
};
```

### 2.3 G1StaticIHOPControl：静态控制

**源码位置**：`gc/g1/g1IHOPControl.hpp:85-103`

```cpp
class G1StaticIHOPControl : public G1IHOPControl {
  // 最近一次标记时长
  double _last_marking_length_s;

public:
  size_t get_conc_mark_start_threshold() {
    guarantee(_target_occupancy > 0, "Target occupancy must have been initialized.");
    // 简单计算：阈值 = IHOP百分比 × 目标占用
    return (size_t)(_initial_ihop_percent * _target_occupancy / 100.0);
  }

  void update_marking_length(double marking_length_s) {
    _last_marking_length_s = marking_length_s;
  }
};
```

**计算示例**：

```
初始 IHOP = 45%
目标占用 = 8GB = 8589934592 bytes

静态阈值 = 45% × 8GB = 3.6GB

含义：老年代占用超过 3.6GB 时，启动并发标记
```

### 2.4 G1AdaptiveIHOPControl：自适应控制

**源码位置**：`gc/g1/g1IHOPControl.hpp:109-153`

```cpp
class G1AdaptiveIHOPControl : public G1IHOPControl {
  // 堆保留百分比（默认10%）
  size_t _heap_reserve_percent;

  // 堆浪费百分比（默认5%）
  size_t _heap_waste_percent;

  // 预测器
  const G1Predictions* _predictor;

  // 标记时长序列（用于预测）
  TruncatedSeq _marking_times_s;

  // 分配速率序列（用于预测）
  TruncatedSeq _allocation_rate_s;

  // 最近一次无约束的年轻代大小
  size_t _last_unrestrained_young_size;

  // 检查是否有足够数据进行预测
  bool have_enough_data_for_prediction() const;

  // 计算实际目标阈值
  size_t actual_target_threshold() const;

public:
  size_t get_conc_mark_start_threshold();
  void update_allocation_info(double allocation_time_s, size_t additional_buffer_size);
  void update_marking_length(double marking_length_s);
};
```

**内存布局**：

```
G1AdaptiveIHOPControl 对象
┌────────────────────────────────────────────────────────┐
│ G1IHOPControl 基类字段                                  │
│  ├─ _initial_ihop_percent: double (45.0)              │
│  ├─ _target_occupancy: size_t (8GB)                   │
│  ├─ _last_allocation_time_s: double                   │
│  └─ _old_gen_alloc_tracker: pointer                   │
├────────────────────────────────────────────────────────┤
│ G1AdaptiveIHOPControl 字段                              │
│  ├─ _heap_reserve_percent: size_t (10)                │
│  ├─ _heap_waste_percent: size_t (5)                   │
│  ├─ _predictor: pointer                               │
│  ├─ _marking_times_s: TruncatedSeq (容量10, alpha=0.95)│
│  ├─ _allocation_rate_s: TruncatedSeq (容量10, alpha=0.95)│
│  └─ _last_unrestrained_young_size: size_t             │
└────────────────────────────────────────────────────────┘
```

### 2.5 G1OldGenAllocationTracker

**源码位置**：`gc/g1/g1OldGenAllocationTracker.hpp:34-67`

```cpp
class G1OldGenAllocationTracker : public CHeapObj<mtGC> {
  // 上一个 mutator 周期的老年代分配字节数
  size_t _last_period_old_gen_bytes;

  // 上一个 mutator 周期的老年代净增长（考虑大对象回收）
  size_t _last_period_old_gen_growth;

  // 上次 GC 后的大对象字节数
  size_t _humongous_bytes_after_last_gc;

  // 非大对象分配
  size_t _allocated_bytes_since_last_gc;

  // 大对象分配
  size_t _allocated_humongous_bytes_since_last_gc;

public:
  void add_allocated_bytes_since_last_gc(size_t bytes);
  void add_allocated_humongous_bytes_since_last_gc(size_t bytes);
  size_t last_period_old_gen_bytes() const;
  size_t last_period_old_gen_growth() const;
  void reset_after_gc(size_t humongous_bytes_after_gc);
};
```

---

## 3. 核心算法：自适应 IHOP 计算

### 3.1 get_conc_mark_start_threshold()

**源码位置**：`gc/g1/g1IHOPControl.cpp:123-144`

```cpp
size_t G1AdaptiveIHOPControl::get_conc_mark_start_threshold() {
  // 【Line 124】检查是否有足够数据
  if (have_enough_data_for_prediction()) {
    // 【Line 125-126】预测标记时长和老年代分配速率
    double pred_marking_time = _predictor->get_new_prediction(&_marking_times_s);
    double pred_promotion_rate = _predictor->get_new_prediction(&_allocation_rate_s);

    // 【Line 127】预测标记期间的老年代增长量
    size_t pred_promotion_size = (size_t)(pred_marking_time * pred_promotion_rate);

    // 【Line 129-133】预测标记期间需要的总空间
    size_t predicted_needed_bytes_during_marking =
      pred_promotion_size +                    // 老年代增长
      _last_unrestrained_young_size;           // 年轻代最大大小

    // 【Line 135】获取实际目标阈值
    size_t internal_threshold = actual_target_threshold();

    // 【Line 136-138】计算 IHOP 阈值
    size_t predicted_initiating_threshold =
      predicted_needed_bytes_during_marking < internal_threshold ?
        internal_threshold - predicted_needed_bytes_during_marking : 0;

    return predicted_initiating_threshold;
  } else {
    // 【Line 141-142】数据不足，使用初始值
    return (size_t)(_initial_ihop_percent * _target_occupancy / 100.0);
  }
}
```

**计算公式**：

```
IHOP阈值 = 实际目标阈值 - 标记期间需要的空间
         = 实际目标阈值 - (标记时长 × 分配速率 + 年轻代大小)
```

### 3.2 actual_target_threshold()

**源码位置**：`gc/g1/g1IHOPControl.cpp:100-116`

```cpp
size_t G1AdaptiveIHOPControl::actual_target_threshold() const {
  guarantee(_target_occupancy > 0, "Target occupancy still not updated yet.");

  // 【Line 110】计算安全百分比
  // 安全百分比 = 堆保留% + 堆浪费%
  double safe_total_heap_percentage = MIN2(
    (double)(_heap_reserve_percent + _heap_waste_percent), 100.0);

  // 【Line 112-115】返回实际目标阈值
  // 取两者中较小值：
  // 1. 堆最大容量 × (100 - 安全百分比)
  // 2. 目标占用 × (100 - 堆浪费百分比)
  return (size_t)MIN2(
    G1CollectedHeap::heap()->max_capacity() * (100.0 - safe_total_heap_percentage) / 100.0,
    _target_occupancy * (100.0 - _heap_waste_percent) / 100.0
  );
}
```

**计算示例**：

```
堆最大容量 = 8GB
目标占用 = 8GB
堆保留百分比 = 10%
堆浪费百分比 = 5%

安全百分比 = 10% + 5% = 15%

实际目标阈值 = min(
  8GB × (100% - 15%) = 6.8GB,
  8GB × (100% - 5%) = 7.6GB
) = 6.8GB

含义：
  堆占用不应超过 6.8GB（留出 15% 安全裕量）
```

### 3.3 have_enough_data_for_prediction()

**源码位置**：`gc/g1/g1IHOPControl.cpp:118-121`

```cpp
bool G1AdaptiveIHOPControl::have_enough_data_for_prediction() const {
  return ((size_t)_marking_times_s.num() >= G1AdaptiveIHOPNumInitialSamples) &&
         ((size_t)_allocation_rate_s.num() >= G1AdaptiveIHOPNumInitialSamples);
}
```

**G1AdaptiveIHOPNumInitialSamples** 默认值需要查找：根据经验，通常是 3-5 个样本。

### 3.4 update_allocation_info()

**源码位置**：`gc/g1/g1IHOPControl.cpp:152-158`

```cpp
void G1AdaptiveIHOPControl::update_allocation_info(double allocation_time_s,
                                                   size_t additional_buffer_size) {
  // 【Line 154】调用基类方法
  G1IHOPControl::update_allocation_info(allocation_time_s, additional_buffer_size);

  // 【Line 155】计算并记录分配速率
  _allocation_rate_s.add(last_mutator_period_old_allocation_rate());

  // 【Line 157】记录年轻代大小
  _last_unrestrained_young_size = additional_buffer_size;
}
```

### 3.5 last_mutator_period_old_allocation_rate()

**源码位置**：`gc/g1/g1IHOPControl.cpp:146-150`

```cpp
double G1AdaptiveIHOPControl::last_mutator_period_old_allocation_rate() const {
  assert(_last_allocation_time_s > 0, "This should not be called when the last GC is full");

  // 分配速率 = 老年代净增长 / mutator 时间
  return _old_gen_alloc_tracker->last_period_old_gen_growth() / _last_allocation_time_s;
}
```

### 3.6 update_marking_length()

**源码位置**：`gc/g1/g1IHOPControl.cpp:160-163`

```cpp
void G1AdaptiveIHOPControl::update_marking_length(double marking_length_s) {
  assert(marking_length_s >= 0.0, "Marking length must be larger than zero but is %.3f", marking_length_s);
  _marking_times_s.add(marking_length_s);
}
```

---

## 4. 完整计算示例

### 4.1 初始阶段（数据不足）

```
初始配置：
  InitiatingHeapOccupancyPercent = 45
  G1ReservePercent = 10
  G1HeapWastePercent = 5

堆大小：8GB

第一次 GC 后：
  _marking_times_s.num() = 0
  _allocation_rate_s.num() = 0

have_enough_data_for_prediction() = false

IHOP阈值 = 45% × 8GB = 3.6GB（静态值）
```

### 4.2 数据收集阶段

```
第一次并发标记周期：
  标记时长 = 2.5 秒
  标记期间老年代增长 = 500MB
  年轻代大小 = 800MB

记录数据：
  _marking_times_s.add(2.5)
  _allocation_rate_s.add(500MB / mutator_time)

第二次并发标记周期：
  标记时长 = 2.8 秒
  标记期间老年代增长 = 600MB

记录数据：
  _marking_times_s.add(2.8)
  _allocation_rate_s.add(600MB / mutator_time)

...

第三次后（假设样本数 >= 3）：
  have_enough_data_for_prediction() = true
```

### 4.3 自适应计算阶段

```
历史数据：
  标记时长序列：[2.5, 2.8, 2.6, 2.7, ...]
  分配速率序列：[100MB/s, 120MB/s, 110MB/s, ...]

预测：
  pred_marking_time = predict(_marking_times_s) = 2.65 秒
  pred_promotion_rate = predict(_allocation_rate_s) = 110 MB/s

预测标记期间增长：
  pred_promotion_size = 2.65s × 110MB/s = 291.5 MB

预测总需要空间：
  predicted_needed = 291.5 MB + 800 MB (年轻代) = 1091.5 MB

实际目标阈值：
  actual_threshold = 6.8 GB

IHOP 阈值：
  IHOP = 6.8 GB - 1.09 GB = 5.71 GB = 71.4%

对比静态值：45% → 71.4%（提高了！）
含义：老年代分配速率高，需要更早启动标记
```

### 4.4 特殊情况：预测增长超过阈值

```
预测：
  pred_marking_time = 3.0 秒
  pred_promotion_rate = 200 MB/s

预测标记期间增长：
  pred_promotion_size = 3.0s × 200MB/s = 600 MB

预测总需要空间：
  predicted_needed = 600 MB + 800 MB = 1400 MB

实际目标阈值：
  actual_threshold = 6.8 GB

IHOP 阈值：
  predicted_needed (1.4 GB) < actual_threshold (6.8 GB)
  IHOP = 6.8 GB - 1.4 GB = 5.4 GB = 67.5%

如果 predicted_needed >= actual_threshold：
  IHOP = 0（立即启动标记！）
```

---

## 5. 在 G1Policy 中的使用

### 5.1 创建 IHOP 控制

**源码位置**：`gc/g1/g1Policy.cpp:787-798`

```cpp
G1IHOPControl* G1Policy::create_ihop_control(
    const G1OldGenAllocationTracker* old_gen_alloc_tracker,
    const G1Predictions* predictor) {

  if (G1UseAdaptiveIHOP) {
    // 【Line 790-794】创建自适应控制
    return new G1AdaptiveIHOPControl(
      InitiatingHeapOccupancyPercent,  // 初始 IHOP (默认45)
      old_gen_alloc_tracker,
      predictor,
      G1ReservePercent,                // 堆保留 (默认10)
      G1HeapWastePercent);             // 堆浪费 (默认5)
  } else {
    // 【Line 796】创建静态控制
    return new G1StaticIHOPControl(
      InitiatingHeapOccupancyPercent,
      old_gen_alloc_tracker);
  }
}
```

### 5.2 更新 IHOP 预测

**源码位置**：`gc/g1/g1Policy.cpp:800-836`

```cpp
void G1Policy::update_ihop_prediction(double mutator_time_s,
                                      size_t young_gen_size,
                                      bool this_gc_was_young_only) {
  // 【Line 808】最小有效时间阈值
  double const min_valid_time = 1e-6;

  bool report = false;
  double marking_to_mixed_time = -1.0;

  // 【Line 813-822】如果是 Mixed GC，记录标记时长
  if (!this_gc_was_young_only && _initial_mark_to_mixed.has_result()) {
    marking_to_mixed_time = _initial_mark_to_mixed.last_marking_time();
    if (marking_to_mixed_time > min_valid_time) {
      _ihop_control->update_marking_length(marking_to_mixed_time);
      report = true;
    }
  }

  // 【Line 828-831】如果是 Young GC，记录分配信息
  if (this_gc_was_young_only && mutator_time_s > min_valid_time) {
    _ihop_control->update_allocation_info(mutator_time_s, young_gen_size);
    report = true;
  }

  // 【Line 833-835】打印统计信息
  if (report) {
    report_ihop_statistics();
  }
}
```

### 5.3 GC 结束时调用

**源码位置**：`gc/g1/g1Policy.cpp:761-766`

```cpp
void G1Policy::record_collection_pause_end(...) {
  ...

  // 【Line 761】重置老年代分配追踪器
  _old_gen_alloc_tracker.reset_after_gc(
    _g1h->humongous_regions_count() * HeapRegion::GrainBytes);

  // 【Line 762-764】更新 IHOP 预测
  update_ihop_prediction(
    app_time_ms / 1000.0,
    last_unrestrained_young_length * HeapRegion::GrainBytes,
    this_pause_was_young_only);

  // 【Line 766】发送 trace 事件
  _ihop_control->send_trace_event(_g1h->gc_tracer_stw());
}
```

---

## 6. 数据流图

```
┌──────────────────────────────────────────────────────────────┐
│                  Mutator 运行期间                            │
│  - 老年代分配（普通对象晋升、大对象）                        │
│  - 年轻代大小动态调整                                        │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────────┐
        │        Young GC 结束                  │
        │  - 记录分配时间                       │
        │  - 记录年轻代大小                     │
        │  - 计算分配速率                       │
        │  - update_allocation_info()           │
        └───────────────────────────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────────┐
        │     并发标记结束（第一次 Mixed GC）   │
        │  - 记录标记时长                       │
        │  - update_marking_length()            │
        └───────────────────────────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────────┐
        │     样本数足够？                      │
        │  have_enough_data_for_prediction()    │
        └───────────────────────────────────────┘
                            │
                ┌───────────┴───────────┐
                │ 否                    │ 是
                ▼                       ▼
        ┌───────────────┐       ┌───────────────────┐
        │ 使用初始 IHOP │       │ 预测标记时长      │
        │ (45% 默认)    │       │ 预测分配速率      │
        └───────────────┘       │ 计算 IHOP 阈值    │
                                └───────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────────┐
        │  get_conc_mark_start_threshold()      │
        │  返回：老年代占用阈值                 │
        └───────────────────────────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────────┐
        │  need_to_start_conc_mark()            │
        │  检查：老年代占用 > 阈值？            │
        └───────────────────────────────────────┘
                            │
                ┌───────────┴───────────┐
                │ 否                    │ 是
                ▼                       ▼
        ┌───────────────┐       ┌───────────────────┐
        │ 继续运行      │       │ 启动并发标记      │
        └───────────────┘       └───────────────────┘
```

---

## 7. 关键参数

### 7.1 可调参数

| 参数 | 默认值 | 含义 |
|------|--------|------|
| `InitiatingHeapOccupancyPercent` | 45 | 初始 IHOP 百分比 |
| `G1UseAdaptiveIHOP` | true | 是否使用自适应 IHOP |
| `G1ReservePercent` | 10 | 堆保留百分比（用于晋升失败）|
| `G1HeapWastePercent` | 5 | 堆浪费百分比（碎片等）|
| `G1AdaptiveIHOPNumInitialSamples` | 3 | 开始预测需要的最小样本数 |

### 7.2 参数影响

```
InitiatingHeapOccupancyPercent 影响：
  - 静态模式：直接决定 IHOP 阈值
  - 自适应模式：作为初始值，后续会调整

G1ReservePercent 影响：
  - 实际目标阈值 = 堆容量 × (100 - Reserve - Waste)%
  - 增大 → 目标阈值降低 → 更早启动标记

G1HeapWastePercent 影响：
  - 考虑堆碎片等浪费
  - 增大 → 目标阈值降低
```

---

## 8. GDB 验证脚本

### 8.1 查看 IHOP 阈值计算

```bash
cat > /data/workspace/openjdk-cut-new/jvm-md/tmp-file/ihop/verify_ihop.gdb << 'EOF'
# 打印 IHOP 控制状态
define print_ihop_control
  set $ihop = (G1AdaptiveIHOPControl*)$arg0
  printf "\n=== Adaptive IHOP Control ===\n"
  printf "Initial IHOP: %.1f%%\n", $ihop->_initial_ihop_percent
  printf "Target occupancy: %lu bytes\n", $ihop->_target_occupancy
  printf "Heap reserve: %lu%%\n", $ihop->_heap_reserve_percent
  printf "Heap waste: %lu%%\n", $ihop->_heap_waste_percent
  printf "Marking times samples: %d\n", $ihop->_marking_times_s._num
  printf "Allocation rate samples: %d\n", $ihop->_allocation_rate_s._num
  printf "Current threshold: %lu bytes\n", $ihop->get_conc_mark_start_threshold()
end

break G1AdaptiveIHOPControl::get_conc_mark_start_threshold

commands 1
  printf "\n=== Calculating IHOP Threshold ===\n"
  continue
end

run
EOF
```

### 8.2 追踪 IHOP 更新

```bash
cat > /data/workspace/openjdk-cut-new/jvm-md/tmp-file/ihop/trace_ihop_update.gdb << 'EOF'
break G1AdaptiveIHOPControl::update_allocation_info

commands 1
  printf "\n=== Updating Allocation Info ===\n"
  printf "Allocation time: %.3f s\n", $arg0
  printf "Young gen size: %lu bytes\n", $arg1
  continue
end

break G1AdaptiveIHOPControl::update_marking_length

commands 2
  printf "\n=== Updating Marking Length ===\n"
  printf "Marking length: %.3f s\n", $arg0
  continue
end

run
EOF
```

### 8.3 查看分配速率序列

```bash
cat > /data/workspace/openjdk-cut-new/jvm-md/tmp-file/ihop/dump_alloc_rate.gdb << 'EOF'
define print_truncated_seq
  set $seq = (TruncatedSeq*)$arg0
  printf "num=%d, davg=%.3f, dsd=%.3f\n", $seq->_num, $seq->_davg, sqrt($seq->_dvariance)
  set $i = 0
  while $i < $seq->_num && $i < 5
    printf "  [%d] = %.3f\n", $i, $seq->_sequence[$i]
    set $i = $i + 1
  end
end

break G1Policy::update_ihop_prediction

commands 1
  printf "\n=== IHOP Prediction Update ===\n"
  continue
end

run
EOF
```

---

## 9. 关键问题与解答

### Q1: 为什么要用自适应 IHOP？

**A**:
- **静态 IHOP 的问题**：
  - 应用负载变化时，固定阈值可能不合适
  - 老年代分配速率高时，可能来不及完成标记
  - 分配速率低时，过早启动浪费资源

- **自适应 IHOP 的优势**：
  - 根据实际运行情况调整
  - 自动适应应用负载变化
  - 避免手动调优

### Q2: 为什么需要堆保留和堆浪费百分比？

**A**:
- **堆保留（G1ReservePercent）**：
  - 应对晋升失败（to-space exhausted）
  - GC 时需要临时空间拷贝存活对象
  - 默认 10%，通常足够

- **堆浪费（G1HeapWastePercent）**：
  - 堆碎片、TLAB 浪费等
  - 实际可用空间 < 名义空间
  - 默认 5%

两者都会降低实际目标阈值，留出安全裕量。

### Q3: 自适应 IHOP 何时生效？

**A**:
```
生效条件：
  - G1UseAdaptiveIHOP = true（默认）
  - _marking_times_s.num() >= 3
  - _allocation_rate_s.num() >= 3

前 3 次并发标记周期：使用静态 IHOP（45%）
之后：使用自适应计算
```

### Q4: 如何判断 IHOP 设置是否合理？

**A**:
```
观察日志（-Xlog:gc+ihop=debug）：

合理 IHOP：
  - 并发标记能及时完成
  - 老年代占用稳定在目标阈值附近
  - 无 Full GC 或很少

IHOP 过低：
  - 并发标记完成时堆占用仍很低
  - 日志显示 "threshold: 2.5GB, actual: 1.8GB"

IHOP 过高：
  - 标记期间堆占用超过阈值
  - 触发 Full GC 或 to-space exhausted
```

### Q5: 如何调优 IHOP？

**A**:
```
1. 使用自适应 IHOP（默认已开启）
   -XX:+G1UseAdaptiveIHOP

2. 如果禁用自适应，手动设置：
   -XX:InitiatingHeapOccupancyPercent=45

3. 调整安全裕量：
   -XX:G1ReservePercent=10   （增加裕量）
   -XX:G1HeapWastePercent=5

4. 观察日志，确认调整效果
```

---

## 10. 源码位置索引

| 文件 | 行号 | 内容 |
|------|------|------|
| `gc/g1/g1IHOPControl.hpp` | 38-81 | G1IHOPControl 基类定义 |
| `gc/g1/g1IHOPControl.hpp` | 85-103 | G1StaticIHOPControl 类 |
| `gc/g1/g1IHOPControl.hpp` | 109-153 | G1AdaptiveIHOPControl 类 |
| `gc/g1/g1IHOPControl.cpp` | 32-40 | G1IHOPControl 构造函数 |
| `gc/g1/g1IHOPControl.cpp` | 79-83 | G1StaticIHOPControl 构造函数 |
| `gc/g1/g1IHOPControl.cpp` | 85-98 | G1AdaptiveIHOPControl 构造函数 |
| `gc/g1/g1IHOPControl.cpp` | 100-116 | actual_target_threshold() |
| `gc/g1/g1IHOPControl.cpp` | 118-121 | have_enough_data_for_prediction() |
| `gc/g1/g1IHOPControl.cpp` | 123-144 | get_conc_mark_start_threshold() |
| `gc/g1/g1IHOPControl.cpp` | 146-150 | last_mutator_period_old_allocation_rate() |
| `gc/g1/g1IHOPControl.cpp` | 152-158 | update_allocation_info() |
| `gc/g1/g1IHOPControl.cpp` | 160-163 | update_marking_length() |
| `gc/g1/g1OldGenAllocationTracker.hpp` | 34-67 | G1OldGenAllocationTracker 类 |
| `gc/g1/g1Policy.cpp` | 787-798 | create_ihop_control() |
| `gc/g1/g1Policy.cpp` | 800-836 | update_ihop_prediction() |

---

## 11. 总结

**G1IHOPControl 的核心思想**：
1. **预测驱动**：根据历史数据预测标记时长和分配速率
2. **安全裕量**：考虑堆保留和堆浪费，留出安全空间
3. **自适应调整**：根据应用负载自动调整 IHOP
4. **保守策略**：宁可早启动，不可晚启动

**计算公式**：
```
IHOP阈值 = 实际目标阈值 - 标记期间增长量
标记期间增长量 = 预测标记时长 × 预测分配速率 + 年轻代大小
实际目标阈值 = 堆容量 × (100 - Reserve - Waste)%
```

**性能影响**：
- 合适的 IHOP 避免过早或过晚启动并发标记
- 自适应 IHOP 减少手动调优需求
- 预测准确性依赖足够的历史数据
