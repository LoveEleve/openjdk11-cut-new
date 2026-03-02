# IHOP（Initiating Heap Occupancy）专家级分析

> **文档版本**: v1.0  
> **创建时间**: 2026-02-11  
> **源码版本**: OpenJDK 11  
> **目标**: 深入理解 G1 Mixed GC 触发机制的核心决策逻辑

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

IHOP（Initiating Heap Occupancy Percent）的本质是**并发标记的触发阈值**：当 Old 区占用率超过 IHOP 时，触发并发标记周期（Initial Mark）；IHOP 的目标是让并发标记在堆满之前完成，为 Mixed GC 做准备。`G1AdaptiveIHOP` 根据历史并发标记时间和分配速率动态调整 IHOP。

### 0.2 为什么需要？

并发标记需要时间（可能数秒），期间应用线程继续分配对象。如果 IHOP 太高（如 90%），并发标记开始时堆已经很满，标记期间可能堆满触发 Full GC；如果 IHOP 太低（如 20%），并发标记过于频繁，浪费 CPU。IHOP 需要在"足够早开始"和"不过于频繁"之间平衡。

### 0.3 怎么解决？

**静态 IHOP + 自适应 IHOP**：
- **静态 IHOP**：`-XX:InitiatingHeapOccupancyPercent=45`（默认），固定阈值
- **自适应 IHOP**（`-XX:+G1UseAdaptiveIHOP`，默认开启）：`G1AdaptiveIHOP` 根据历史数据预测：`IHOP = 堆大小 - 并发标记期间的预期分配量`；`预期分配量 = 分配速率 × 并发标记时间`

### 0.4 为什么这样设计？

- **为什么默认 IHOP 是 45%？** 45% 给并发标记留出 55% 的堆空间作为缓冲；经验值，适合大多数应用；`G1AdaptiveIHOP` 会根据实际情况动态调整
- **为什么自适应 IHOP 比静态 IHOP 更好？** 不同应用的分配速率和并发标记时间差异很大；静态 IHOP 对某些应用太保守（浪费内存），对某些应用太激进（并发标记来不及完成）；自适应 IHOP 根据历史数据找到最优值

---

## 1. 问题引入：为什么需要 IHOP？

### 1.1 场景假设

假设没有 IHOP 机制，G1 何时触发并发标记？

```
问题1: 等堆满了再标记？
        → 标记期间新对象分配导致 OOM
        → 必须触发代价极高的 Full GC

问题2: 固定时间间隔触发？
        → 应用分配速率波动大时失效
        → 快分配场景来不及完成标记
        → 慢分配场景浪费 CPU 资源
```

### 1.2 IHOP 的核心目标

**目标**：在"老年代被填满之前"及时启动并发标记，确保：

1. **标记完成时，堆还未满**（有足够的空间用于分配）
2. **根据应用行为自适应调整**（不是固定的 45%）
3. **最大化并发度**（标记与应用并行执行）

---

## 2. IHOP 架构概览

### 2.1 类层次结构

```
G1IHOPControl (抽象基类)
    │
    ├── G1StaticIHOPControl    → 静态阈值（固定百分比）
    │
    └── G1AdaptiveIHOPControl  → 自适应阈值（预测模型）
```

### 2.2 核心数据结构关系

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          G1Policy                                            │
│  ┌─────────────────────┐  ┌─────────────────────┐                            │
│  │ _ihop_control       │  │ _old_gen_alloc_tracker                          │
│  │ (G1IHOPControl*)    │  │ (G1OldGenAllocationTracker)                     │
│  └──────────┬──────────┘  └──────────┬──────────┘                            │
│             │                        │                                       │
│             ▼                        ▼                                       │
│  ┌─────────────────────┐  ┌─────────────────────┐                            │
│  │ G1AdaptiveIHOPControl│  │ 追踪老年代分配速率   │                            │
│  │ ─────────────────── │  │ _last_period_old_gen_growth                    │
│  │ _marking_times_s    │  │ _allocated_bytes_since_last_gc                 │
│  │ _allocation_rate_s  │  │ _allocated_humongous_bytes_since_last_gc       │
│  │ _predictor          │  └─────────────────────┘                            │
│  └─────────────────────┘                                                    │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 关键参数详解

### 3.1 JVM 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `InitiatingHeapOccupancyPercent` | 45 | 初始 IHOP 阈值百分比 |
| `G1UseAdaptiveIHOP` | true | 是否启用自适应 IHOP |
| `G1AdaptiveIHOPNumInitialSamples` | 3 | 启用预测所需的最小样本数 |
| `G1ReservePercent` | 10 | 堆保留百分比（预防晋升失败） |
| `G1HeapWastePercent` | 5 | 堆浪费百分比（无法回收的空间） |

### 3.2 内存计算公式

**标准环境（8GB 堆）**：

```
初始阈值 = 45% × 老年代容量
         ≈ 45% × 8GB = 3.6GB

实际目标阈值计算（含保留和浪费）：
safe_total_heap_percentage = MIN(10 + 5, 100) = 15%
actual_target_threshold = MIN(
    8GB × (100 - 15) / 100 = 6.8GB,
    target_occupancy × (100 - 5) / 100
)
```

---

## 4. 静态 IHOP（G1StaticIHOPControl）

### 4.1 实现源码

```cpp
// g1IHOPControl.hpp:85-103
class G1StaticIHOPControl : public G1IHOPControl {
  double _last_marking_length_s;  // 最近标记周期时长

public:
  size_t get_conc_mark_start_threshold() {
    guarantee(_target_occupancy > 0, "Target occupancy must have been initialized.");
    return (size_t) (_initial_ihop_percent * _target_occupancy / 100.0);
  }
};
```

### 4.2 工作原理

```
阈值 = 固定百分比 × 目标占用量
     = 45% × _target_occupancy

特点：
- 简单直接，无运行时开销
- 无法适应应用分配速率变化
- 适合分配速率稳定的场景
```

---

## 5. 自适应 IHOP（G1AdaptiveIHOPControl）

### 5.1 核心思想

**预测模型**：根据历史数据预测未来的老年代分配速率和标记时长

```
目标：在标记完成前，老年代不会被填满

核心公式：
阈值 = 实际目标占用量 - 预测标记期间需要分配的内存

其中：
- 预测标记期间需要分配的内存 = 预测标记时长 × 预测分配速率 + 年轻代大小
```

### 5.2 预测算法详解

```cpp
// g1IHOPControl.cpp:123-144
size_t G1AdaptiveIHOPControl::get_conc_mark_start_threshold() {
  if (have_enough_data_for_prediction()) {
    // 1. 预测标记时长（基于历史标记周期）
    double pred_marking_time = _predictor->get_new_prediction(&_marking_times_s);
    
    // 2. 预测老年代分配速率（基于历史 mutator 期间）
    double pred_promotion_rate = _predictor->get_new_prediction(&_allocation_rate_s);
    
    // 3. 计算标记期间需要分配的内存
    size_t pred_promotion_size = (size_t)(pred_marking_time * pred_promotion_rate);
    
    size_t predicted_needed_bytes_during_marking =
      pred_promotion_size + _last_unrestrained_young_size;
    
    // 4. 计算阈值
    size_t internal_threshold = actual_target_threshold();
    size_t predicted_initiating_threshold = 
      predicted_needed_bytes_during_marking < internal_threshold ?
      internal_threshold - predicted_needed_bytes_during_marking : 0;
    
    return predicted_initiating_threshold;
  } else {
    // 数据不足，使用初始值
    return (size_t)(_initial_ihop_percent * _target_occupancy / 100.0);
  }
}
```

### 5.3 预测数据结构

```cpp
// g1IHOPControl.hpp:109-126
class G1AdaptiveIHOPControl : public G1IHOPControl {
  const G1Predictions * _predictor;     // 预测器（使用高置信度统计）
  
  TruncatedSeq _marking_times_s;        // 标记时长序列（截断，保留最近10个，置信度95%）
  TruncatedSeq _allocation_rate_s;      // 分配速率序列（截断，保留最近10个，置信度95%）
  
  size_t _last_unrestrained_young_size; // 最近无约束年轻代大小
  size_t _heap_reserve_percent;         // 堆保留百分比
  size_t _heap_waste_percent;           // 堆浪费百分比
};
```

### 5.4 样本收集机制

```cpp
// g1IHOPControl.cpp:118-121
bool G1AdaptiveIHOPControl::have_enough_data_for_prediction() const {
  return ((size_t)_marking_times_s.num() >= G1AdaptiveIHOPNumInitialSamples) &&
         ((size_t)_allocation_rate_s.num() >= G1AdaptiveIHOPNumInitialSamples);
}
```

**至少需要 3 个周期的数据才能启用预测**

### 5.5 数据更新流程

```
                    GC 结束
                      │
                      ▼
    ┌─────────────────────────────────────┐
    │ update_marking_length()             │ ← 记录本次标记周期时长
    │ _marking_times_s.add(marking_length)│
    └─────────────────────────────────────┘
                      │
                      ▼
    ┌─────────────────────────────────────┐
    │ update_allocation_info()            │ ← 记录 mutator 期间分配信息
    │ _allocation_rate_s.add(rate)        │
    │ _last_unrestrained_young_size = sz  │
    └─────────────────────────────────────┘
```

---

## 6. 触发判断流程

### 6.1 触发条件检查（need_to_start_conc_mark）

```cpp
// g1Policy.cpp:579-599
bool G1Policy::need_to_start_conc_mark(const char* source, size_t alloc_word_size) {
  // 1. 检查是否已经在进行 mixed 阶段
  if (about_to_start_mixed_phase()) {
    return false;  // 已经在并发标记周期中，不需要再次触发
  }

  // 2. 获取当前 IHOP 阈值
  size_t marking_initiating_used_threshold = _ihop_control->get_conc_mark_start_threshold();

  // 3. 计算当前占用 + 本次分配请求
  size_t cur_used_bytes = _g1h->non_young_capacity_bytes();
  size_t alloc_byte_size = alloc_word_size * HeapWordSize;
  size_t marking_request_bytes = cur_used_bytes + alloc_byte_size;

  // 4. 判断是否超过阈值
  bool result = false;
  if (marking_request_bytes > marking_initiating_used_threshold) {
    result = collector_state()->in_young_only_phase() && 
             !collector_state()->in_young_gc_before_mixed();
    // 输出诊断日志
    log_debug(gc, ergo, ihop)("...");
  }

  return result;
}
```

### 6.2 触发点汇总

```
┌─────────────────────────────────────────────────────────────────┐
│                        IHOP 触发点                              │
├─────────────────────────────────────────────────────────────────┤
│ 1. 大对象分配前 (humongous allocation)                           │
│    └─ g1CollectedHeap.cpp:870                                   │
│       if (need_to_start_conc_mark("concurrent humongous allocation"))
│                                                                  │
│ 2. 大对象分配后 (STW humongous allocation)                       │
│    └─ g1CollectedHeap.cpp:976                                   │
│       if (need_to_start_conc_mark("STW humongous allocation"))   │
│       collector_state()->set_initiate_conc_mark_if_possible(true)│
│                                                                  │
│ 3. Young GC 结束后                                               │
│    └─ g1Policy.cpp:1073-1078 (maybe_start_marking)              │
│       if (need_to_start_conc_mark("end of GC"))                  │
│       collector_state()->set_initiate_conc_mark_if_possible(true)│
│                                                                  │
│ 4. Full GC 结束后                                                │
│    └─ g1Policy.cpp:485                                          │
│       collector_state()->set_initiate_conc_mark_if_possible(     │
│           need_to_start_conc_mark("end of Full GC", 0))          │
└─────────────────────────────────────────────────────────────────┘
```

---

## 7. GDB 运行时验证

> **验证状态**: ⚠️ 提供验证脚本和理论预期值，建议在本地环境中运行验证

### 7.1 验证脚本

```bash
# GDB 验证 IHOP 数据结构
cat > /tmp/verify_ihop.gdb << 'EOF'
set pagination off
attach <JAVA_PID>

# 1. 验证 G1Policy 中的 ihop_control
p G1CollectedHeap::_g1h->_policy->_ihop_control

# 2. 验证 G1IHOPControl 类型（静态 vs 自适应）
set $ihop = G1CollectedHeap::_g1h->_policy->_ihop_control
p *$ihop

# 3. 验证关键字段
p $ihop->_initial_ihop_percent
p $ihop->_target_occupancy
p $ihop->_last_allocation_time_s

# 4. 验证自适应 IHOP 特有字段
p ((G1AdaptiveIHOPControl*)$ihop)->_heap_reserve_percent
p ((G1AdaptiveIHOPControl*)$ihop)->_heap_waste_percent
p ((G1AdaptiveIHOPControl*)$ihop)->_last_unrestrained_young_size

# 5. 验证当前阈值
p $ihop->get_conc_mark_start_threshold()

# 6. 验证老年代分配追踪器
set $tracker = G1CollectedHeap::_g1h->_policy->_old_gen_alloc_tracker
p *$tracker

# 7. 验证堆使用情况
p G1CollectedHeap::_g1h->used()
p G1CollectedHeap::_g1h->non_young_capacity_bytes()
p G1CollectedHeap::_g1h->capacity()

detach
quit
EOF

# 运行验证
JAVA_PID=$(pgrep -f "YourJavaApp" | head -1)
gdb -batch -x /tmp/verify_ihop.gdb
```

### 7.2 理论预期输出（基于源码分析）

基于源码分析和标准环境（`-Xms8g -Xmx8g -XX:+UseG1GC`），预期输出：

```
# ihop_control 指针
$1 = (G1IHOPControl *) 0x... [实际内存地址]

# G1IHOPControl 基类字段（G1AdaptiveIHOPControl 会包含这些）
$2 = {
  _initial_ihop_percent = 45,              # 默认初始值 45%
  _target_occupancy = 8589934592,          # 8GB = 8 * 1024 * 1024 * 1024
  _last_allocation_time_s = [上次GC后的mutator时间],
  _old_gen_alloc_tracker = 0x...           # 分配追踪器指针
}

# 自适应 IHOP 特有字段
$3 = 10     # _heap_reserve_percent (G1ReservePercent 默认值)
$4 = 5      # _heap_waste_percent (G1HeapWastePercent 默认值)
$5 = [年轻代大小，单位字节]

# 计算阈值（初始值 45% × 目标占用量）
$6 = 3865470566  # ≈ 3.6GB = 45% × 8GB

# 老年代分配追踪器
$7 = {
  _last_period_old_gen_bytes = [上次mutator期间老年代分配字节数],
  _last_period_old_gen_growth = [老年代增长量],
  _humongous_bytes_after_last_gc = [上次GC后大对象字节数],
  _allocated_bytes_since_last_gc = [自上次GC分配的常规字节数],
  _allocated_humongous_bytes_since_last_gc = [自上次GC分配的大对象字节数]
}

# 堆使用情况
$8 = [当前堆使用量，字节]
$9 = [非年轻代容量，字节]
$10 = [总堆容量，字节]
```

### 7.3 运行时阈值变化验证

```bash
# 观察自适应 IHOP 阈值变化
cat > /data/workspace/openjdk-cut-new/jvm-md/tmp-file/ihop/monitor_ihop.gdb << 'EOF'
set pagination off

# 在 get_conc_mark_start_threshold 设置断点
break G1AdaptiveIHOPControl::get_conc_mark_start_threshold
commands
  silent
  p _initial_ihop_percent
  p _target_occupancy
  p _marking_times_s.num()
  p _allocation_rate_s.num()
  continue
end

# 在 need_to_start_conc_mark 设置断点
break G1Policy::need_to_start_conc_mark
commands
  silent
  p marking_initiating_used_threshold
  p cur_used_bytes
  p marking_request_bytes
  continue
end

continue
EOF
```

---

## 8. GC 日志输出

### 8.1 启用 IHOP 日志

```bash
# 查看 IHOP 相关日志
java -Xms8g -Xmx8g -XX:+UseG1GC \
     -Xlog:gc+ihop=debug,gc+ergo+ihop=debug \
     com.wjcoder.Main
```

### 8.2 日志示例

```
# 基础 IHOP 信息（静态）
[0.456s][debug][gc,ihop] Basic information (value update), 
    threshold: 3865470566B (45.00), 
    target occupancy: 8589934592B, 
    current occupancy: 2877628080B, 
    recent allocation size: 52428800B, 
    recent allocation duration: 500.00ms, 
    recent old gen allocation rate: 104857600.00B/s, 
    recent marking phase length: 2000.00ms

# 自适应 IHOP 信息
[0.456s][debug][gc,ihop] Adaptive IHOP information (value update), 
    threshold: 3221225472B (47.37), 
    internal target occupancy: 6800000000B, 
    occupancy: 2877628080B, 
    additional buffer size: 16777216B, 
    predicted old gen allocation rate: 115343360.00B/s, 
    predicted marking phase length: 1800.00ms, 
    prediction active: true

# 触发决策日志
[5.234s][debug][gc,ergo,ihop] Request concurrent cycle initiation (occupancy higher than threshold) 
    occupancy: 3951369912B 
    allocation request: 0B 
    threshold: 3865470566B (45.00) 
    source: end of GC
```

---

## 9. 内存布局分析

### 9.1 对象大小（基于源码计算）

```cpp
// g1IHOPControl.hpp 字段分析

// G1IHOPControl 基类（虚表 + 4 个字段）
class G1IHOPControl : public CHeapObj<mtGC> {
  // 虚表指针: 8 bytes
  double _initial_ihop_percent;           // 8 bytes
  size_t _target_occupancy;               // 8 bytes  
  double _last_allocation_time_s;         // 8 bytes
  G1OldGenAllocationTracker* _old_gen_alloc_tracker;  // 8 bytes
};
// 理论大小: ~40 bytes (含填充对齐)

// G1StaticIHOPControl（继承 + 1 个字段）
class G1StaticIHOPControl : public G1IHOPControl {
  double _last_marking_length_s;          // 8 bytes
};
// 理论大小: ~48 bytes

// G1AdaptiveIHOPControl（继承 + 6 个字段 + 2 个 TruncatedSeq）
class G1AdaptiveIHOPControl : public G1IHOPControl {
  size_t _heap_reserve_percent;           // 8 bytes
  size_t _heap_waste_percent;             // 8 bytes
  G1Predictions* _predictor;              // 8 bytes
  TruncatedSeq _marking_times_s;          // ~48 bytes (TruncatedSeq 含数组和统计字段)
  TruncatedSeq _allocation_rate_s;        // ~48 bytes
  size_t _last_unrestrained_young_size;   // 8 bytes
};
// 理论大小: ~128 bytes

// G1OldGenAllocationTracker（5 个 size_t 字段）
class G1OldGenAllocationTracker {
  size_t _last_period_old_gen_bytes;
  size_t _last_period_old_gen_growth;
  size_t _humongous_bytes_after_last_gc;
  size_t _allocated_bytes_since_last_gc;
  size_t _allocated_humongous_bytes_since_last_gc;
};
// 理论大小: 40 bytes
```

**GDB 验证命令**：
```bash
gdb -p <PID> -ex "p sizeof(G1IHOPControl)" \
            -ex "p sizeof(G1StaticIHOPControl)" \
            -ex "p sizeof(G1AdaptiveIHOPControl)" \
            -ex "p sizeof(G1OldGenAllocationTracker)" \
            -ex "quit"
```

**预期结果**：
| 类 | 理论大小（64位） | GDB 验证值 |
|----|-----------------|------------|
| G1IHOPControl | ~40 字节 | 待验证 |
| G1StaticIHOPControl | ~48 字节 | 待验证 |
| G1AdaptiveIHOPControl | ~128 字节 | 待验证 |
| G1OldGenAllocationTracker | 40 字节 | 待验证 |

### 9.2 内存占用汇总

```
标准环境（8GB 堆）：

G1IHOPControl（自适应实现）：~128 字节
G1OldGenAllocationTracker：~40 字节
TruncatedSeq × 2（标记时长 + 分配速率序列）：
    - 每个 TruncatedSeq：~48 字节（含 10 个 double 的截断缓冲区）
    - 总计：~96 字节

IHOP 相关总内存占用：~264 字节（远小于 1KB，可忽略）
```

---

## 10. 常见问题与面试问答

### Q1: IHOP 阈值是固定的 45% 吗？

**答**：不是。

- **默认行为**：启用 `G1UseAdaptiveIHOP=true`，阈值会根据应用行为动态调整
- **初始值**：45% 只是初始值，实际阈值可能在 30%-60% 之间波动
- **静态模式**：如果设置 `-XX:-G1UseAdaptiveIHOP`，则固定为 45%

### Q2: 自适应 IHOP 是如何计算的？

**答**：核心公式：

```
阈值 = 实际目标占用量 - 预测标记期间需要分配的内存

预测标记期间需要分配的内存 = 
    预测标记时长 × 预测老年代分配速率 + 年轻代大小
```

预测基于历史数据（最近 10 个周期，置信度 95%），使用截断序列去除异常值。

### Q3: 什么时候会触发并发标记？

**答**：四个触发点：

1. **大对象分配前**（并发分配检查）
2. **大对象分配后**（STW 分配检查）
3. **Young GC 结束后**（最常见的触发点）
4. **Full GC 结束后**

触发条件：当前老年代占用 + 本次分配请求 > IHOP 阈值

### Q4: 为什么需要 `about_to_start_mixed_phase()` 检查？

**答**：防止重复触发。

如果已经开始了并发标记周期（`during_cycle()` 返回 true）或者正在等待第一次 Mixed GC（`in_young_gc_before_mixed()`），则不应该再次触发初始标记。

### Q5: 如何监控 IHOP 效果？

**答**：

```bash
# 启用 IHOP 调试日志
-Xlog:gc+ihop=debug,gc+ergo+ihop=debug

# 关键指标：
# 1. 实际阈值 vs 初始阈值（观察自适应效果）
# 2. 预测标记时长 vs 实际标记时长（观察预测准确度）
# 3. 触发时老年代占用（观察触发时机）
```

---

## 11. 与 Young GC 的关联

### 11.1 触发协作

```
Young GC 流程中：
    
    record_collection_pause_end()
        │
        ├── 如果本次是 Initial Mark
        │   └── record_concurrent_mark_init_end()
        │
        └── 如果不是 Initial Mark
            └── maybe_start_marking()  ← 检查 IHOP 阈值
                    │
                    ├── need_to_start_conc_mark()?
                    │       ├── 获取当前阈值
                    │       ├── 检查占用量
                    │       └── 判断是否触发
                    │
                    └── 如果触发
                        └── set_initiate_conc_mark_if_possible(true)
```

### 11.2 为什么借道 Young GC？

**原因**：

1. **避免额外 STW**：利用 Young GC 已有的 STW 时间，无需额外暂停
2. **根扫描复用**：Young GC 已经扫描了根集合，可以直接复用
3. **TAMS 设置**：在 Young GC 结束时设置 TAMS 指针，逻辑更清晰

---

## 12. 总结

### 12.1 核心要点

1. **IHOP 是 G1 并发标记的触发器**，确保在堆满之前开始标记
2. **双模式设计**：静态模式简单直接，自适应模式智能预测
3. **预测模型**：基于历史标记时长和分配速率进行预测
4. **多处触发点**：大对象分配、Young GC 结束、Full GC 结束
5. **内存占用极小**：整个 IHOP 系统 < 1KB

### 12.2 调优建议

| 场景 | 建议 |
|------|------|
| 分配速率稳定 | 使用静态 IHOP（`-XX:-G1UseAdaptiveIHOP`） |
| 分配速率波动大 | 使用自适应 IHOP（默认） |
| 频繁过早触发 | 提高 `InitiatingHeapOccupancyPercent` |
| 频繁延迟触发 | 降低 `InitiatingHeapOccupancyPercent` |
| 需要更多稳定性 | 增加 `G1AdaptiveIHOPNumInitialSamples` |

### 12.3 下一步

下一阶段将分析 **4.2 Mixed GC CSet 选择**，理解如何根据标记结果选择回收效率最高的老年代 Region。

---

**文档完成时间**: 2026-02-11  
**验证状态**: ⚠️ 提供完整验证脚本和理论预期值（实际 GDB attach 受环境限制未完成）  
**关联文档**: 
- `Initial-Mark-Phase-Expert-Analysis.md`（初始标记触发）
- `G1ConcurrentMark-Overview.md`（并发标记概览）
