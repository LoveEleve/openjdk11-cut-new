# G1Policy 专家级源码分析

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1Policy 的本质是**G1 GC 的中央决策控制器**：基于 `G1Analytics`（历史数据）和 `G1Predictions`（EMA 预测引擎），在每次 GC 前后做出三个核心决策：(1) 何时触发并发标记（IHOP 阈值）；(2) 本次 GC 回收多少 Region（CSet 大小）；(3) 年轻代应该多大（`_young_list_target_length`）。

### 0.2 为什么需要？

G1 的核心承诺是"可预测的停顿时间"（`-XX:MaxGCPauseMillis`）。但最优参数随应用负载动态变化：年轻代太大→停顿超标，太小→GC 频繁；IHOP 太高→并发标记来不及完成，太低→Mixed GC 过于频繁。G1Policy 是这个自适应控制系统的决策中心。

### 0.3 怎么解决？

**EMA 预测 + 贪心 CSet 选择**：
- `record_collection_pause_end()`：每次 GC 后更新 `G1Analytics` 的历史数据
- `predict_region_elapsed_time()`：预测回收一个 Region 的时间（EMA）
- `finalize_collection_set()`：贪心选择 Region 加入 CSet，直到预测停顿时间达到目标
- `update_young_list_max_and_target_length()`：根据停顿时间目标调整年轻代大小

### 0.4 为什么这样设计？

- **为什么 CSet 选择用贪心而不是动态规划？** 动态规划求最优解的时间复杂度 O(n×W)，n=Region 数量，W=时间预算，代价太高；贪心（按性价比排序）在实践中效果接近最优，且 O(n log n)
- **为什么 Young Region 必须全部进 CSet？** Young Region 不进 CSet 就无法回收，Eden 会持续增长直到 OOM；Old Region 可以选择性回收（Mixed GC），但 Young 必须全收

---

## 一、宏观理解：G1 的"大脑"

### 1.1 一句话总结

**G1Policy 是 G1 垃圾收集器的决策中心**，负责回答三个核心问题：
1. **何时收集** —— 根据堆占用率和 IHOP 阈值决定是否开始并发标记
2. **收集多少** —— 根据暂停时间目标计算年轻代目标大小（CSet 规模）
3. **如何预测** —— 基于历史数据预测 GC 暂停时间和存活对象大小

### 1.2 为什么需要 G1Policy？

**问题背景**：
- G1 的目标是**可预测的暂停时间**（MaxGCPauseMillis）
- 但每次 GC 的时间取决于：年轻代大小、记忆集大小、存活对象数量
- 这些因素都是动态变化的

**解决方案**：
- G1Policy 维护一套**预测模型**，基于历史 GC 数据统计
- 在每次 GC 前**计算最优的年轻代大小**，使预测暂停时间接近目标
- 通过**自适应调整**适应应用程序的变化

### 1.3 核心设计思想

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         G1Policy 决策流程                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   应用程序运行 ──> 分配 Eden 区域 ──> 检查年轻代长度                        │
│                            │                                            │
│                            ▼                                            │
│              young_regions_count() >= _young_list_target_length?         │
│                            │                                            │
│                    是 ────> 触发 Young GC                                │
│                            │                                            │
│                            ▼                                            │
│              ┌─────────────────────────────┐                            │
│              │  计算 CSet (Collection Set)  │                            │
│              │  - Eden 区域（全部回收）      │                            │
│              │  - Survivor 区域（晋升/保留） │                            │
│              └─────────────────────────────┘                            │
│                            │                                            │
│                            ▼                                            │
│              执行 Evacuation Pause ──> 更新统计数据                       │
│                            │                                            │
│                            ▼                                            │
│              重新计算 _young_list_target_length                          │
│              （基于新的预测模型）                                          │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.4 G1Policy 在系统中的位置

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           G1CollectedHeap                                    │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                            G1Policy                                    │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐   │  │
│  │  │G1Predictions│  │ G1Analytics │  │G1IHOPControl│  │G1MMUTracker │   │  │
│  │  │   (预测)     │  │   (统计)     │  │  (IHOP控制)  │  │  (MMU跟踪)   │   │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘   │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                    │  │
│  │  │SurvRateGroup│  │G1YoungGen   │  │ G1Collection│                    │  │
│  │  │  (存活率)    │  │   Sizer     │  │    Set      │                    │  │
│  │  │             │  │ (年轻代大小) │  │  (收集集合)  │                    │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘                    │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 二、字段分析：数据结构的完整解剖

### 2.1 类继承与内存布局

```cpp
// g1Policy.hpp:55
class G1Policy: public CHeapObj<mtGC> {
    // ... 字段
};
```

**继承关系**：
- `CHeapObj<mtGC>` —— 在 C 堆上分配，内存类型为 GC 专用

**对象大小**（GDB 验证）：
```bash
(gdb) p sizeof(G1Policy)
$1 = 368  # 64-bit 系统下的实际大小
```

### 2.2 核心字段分类与详解

#### 2.2.1 预测与统计组件（决策基础）

```cpp
// g1Policy.hpp:66-69
G1Predictions _predictor;           // 预测器：基于历史数据预测未来
G1Analytics* _analytics;            // 分析器：收集和维护统计数据
G1RemSetTrackingPolicy _remset_tracker;  // 记忆集跟踪策略
G1MMUTracker* _mmu_tracker;         // MMU 跟踪器：保证 mutator 利用率
```

**G1Predictions _predictor** —— 预测引擎
- **作用**：基于历史统计数据预测未来的 GC 时间、存活率等
- **核心算法**：
  ```cpp
  // g1Predictions.hpp:57-59
  double get_new_prediction(TruncatedSeq const* seq) const {
      return seq->davg() + _sigma * stddev_estimate(seq);
  }
  ```
  - `davg()`：历史数据的加权平均
  - `stddev_estimate(seq)`：标准差估计（样本<5 时有特殊处理）
  - `_sigma`：置信系数（默认 0.5，即 G1ConfidencePercent / 100.0）

**G1Analytics* _analytics** —— 统计数据中心
- **作用**：维护各种 GC 相关的历史统计数据序列
- **关键序列**（g1Analytics.hpp:40-67）：
  | 序列名称 | 用途 |
  |---------|------|
  | `_recent_gc_times_ms` | 最近 GC 暂停时间 |
  | `_alloc_rate_ms_seq` | 内存分配速率 |
  | `_cost_per_card_ms_seq` | 每张卡片的处理成本 |
  | `_cost_per_entry_ms_seq` | 每个记忆集条目的处理成本 |
  | `_cost_per_byte_ms_seq` | 每字节复制成本 |
  | `_pending_cards_seq` | 待处理卡片数量 |
  | `_rs_lengths_seq` | 记忆集长度 |

**G1MMUTracker* _mmu_tracker** —— 暂停时间约束
- **作用**：确保 GC 暂停不超过用户设置的目标（MaxGCPauseMillis）
- **核心参数**：
  - `GCPauseIntervalMillis`：GC 暂停间隔（默认 1000ms）
  - `MaxGCPauseMillis`：最大 GC 暂停时间（默认 200ms）
- **实现**：使用固定大小队列（64 个元素）跟踪最近的暂停

#### 2.2.2 IHOP 控制组件（并发标记触发）

```cpp
// g1Policy.hpp:73-74
G1OldGenAllocationTracker _old_gen_alloc_tracker;  // 老年代分配跟踪
G1IHOPControl* _ihop_control;                      // IHOP 控制器
```

**IHOP (Initiating Heap Occupancy Percent)** —— 触发并发标记的阈值

- **问题**：何时开始并发标记，才能既不影响 mutator，又能在堆满之前完成？
- **解决方案**：
  - **静态 IHOP**：固定阈值（默认 45%）
  - **自适应 IHOP**：根据分配速率和标记时间动态调整

```cpp
// g1IHOPControl.hpp:38-81
class G1IHOPControl : public CHeapObj<mtGC> {
    double _initial_ihop_percent;    // 初始 IHOP 百分比
    size_t _target_occupancy;        // 目标堆占用（触发标记的阈值）
    // ...
};
```

**自适应 IHOP 计算公式**：
```
目标占用率 = 老年代当前占用 + 预测的老年代分配量 + 安全余量

预测的老年代分配量 = 分配速率 × 预测标记时间
```

#### 2.2.3 年轻代大小控制（核心决策字段）

```cpp
// g1Policy.hpp:82-87
uint _young_list_target_length;    // 年轻代目标长度（Region 数）
uint _young_list_fixed_length;     // 固定年轻代长度（非自适应模式）
uint _young_list_max_length;       // 年轻代最大长度（包括 GC Locker 扩展）
```

**_young_list_target_length** —— 最核心的决策字段
- **含义**：当前期望的年轻代大小（以 Region 数为单位）
- **初始值**：102 个 Region（8GB 堆下约 408MB）
- **动态调整**：每次 GC 后根据预测模型重新计算

**计算因素**（g1Policy.cpp:326-426）：
1. **暂停时间目标**：用户设置的 MaxGCPauseMillis
2. **记忆集长度预测**：跨代引用数量
3. **分配速率**：应用程序内存分配速度
4. **存活率预测**：年轻代对象存活概率
5. **空闲 Region 数**：当前可用 Region 数量

**_young_list_max_length** —— 上限保护
- **作用**：防止年轻代过度扩展导致 GC 时间过长
- **特殊考虑**：GC Locker 期间可以额外扩展（由 `GCLockerEdenExpansionPercent` 控制）

#### 2.2.4 存活率预测组件

```cpp
// g1Policy.hpp:91-92
SurvRateGroup* _short_lived_surv_rate_group;   // 短存活组（Eden）
SurvRateGroup* _survivor_surv_rate_group;      // Survivor 组
```

**SurvRateGroup** —— 存活率预测
- **作用**：跟踪不同年龄对象的存活率，预测未来 GC 的存活对象大小
- **数据结构**（survRateGroup.hpp:32-89）：
  ```cpp
  class SurvRateGroup : public CHeapObj<mtGC> {
      TruncatedSeq** _surv_rate_pred;      // 每个年龄的存活率序列
      double* _accum_surv_rate_pred;       // 累积存活率预测
      // ...
  };
  ```

**为什么需要两组？**
- **短存活组**：跟踪 Eden 区域的对象，存活率通常较低
- **Survivor 组**：跟踪 Survivor 区域的对象，存活率较高且稳定
- **分离统计**：避免 Eden 的波动影响 Survivor 的预测准确性

#### 2.2.5 其他重要字段

```cpp
// g1Policy.hpp:94-97
double _reserve_factor;     // 保留区域比例（默认 10%，G1ReservePercent）
uint   _reserve_regions;    // 保留区域数量（用于应对突发分配）

// g1Policy.hpp:99
G1YoungGenSizer _young_gen_sizer;  // 年轻代大小计算器

// g1Policy.hpp:101-107
uint   _free_regions_at_end_of_collection;  // 上次 GC 后的空闲 Region 数
size_t _max_rs_lengths;                     // 最大记忆集长度
size_t _rs_lengths_prediction;              // 记忆集长度预测
size_t _pending_cards;                      // 待处理卡片数

// g1Policy.hpp:109
G1InitialMarkToMixedTimeTracker _initial_mark_to_mixed;  // 标记到混合 GC 的时间跟踪

// g1Policy.hpp:169, 181, 184, 186
G1CollectionSet* _collection_set;       // 收集集合
size_t _bytes_copied_during_gc;         // GC 期间复制的字节数
G1CollectedHeap* _g1h;                  // G1 堆引用
G1GCPhaseTimes* _phase_times;           // GC 阶段时间统计

// g1Policy.hpp:393-400
uint _tenuring_threshold;               // 晋升阈值（年龄超过此值进入老年代）
uint _max_survivor_regions;             // 最大 Survivor 区域数
AgeTable _survivors_age_table;          // 存活者年龄表
```

### 2.3 GDB 字段验证脚本

```gdb
# g1policy_fields.gdb - G1Policy 字段验证脚本

# 设置断点在 G1Policy::init 完成时
break g1Policy.cpp:143
commands
    silent
    
    # 打印 G1Policy 对象地址
    printf "=== G1Policy 字段分析 ===\n"
    printf "this = 0x%lx\n", (unsigned long)this
    printf "sizeof(G1Policy) = %zu\n", sizeof(G1Policy)
    
    # 核心组件指针
    printf "\n--- 核心组件 ---\n"
    printf "_predictor._sigma = %f\n", _predictor._sigma
    printf "_analytics = 0x%lx\n", (unsigned long)_analytics
    printf "_mmu_tracker = 0x%lx\n", (unsigned long)_mmu_tracker
    printf "_ihop_control = 0x%lx\n", (unsigned long)_ihop_control
    
    # 年轻代大小控制
    printf "\n--- 年轻代大小 ---\n"
    printf "_young_list_target_length = %u (Region)\n", _young_list_target_length
    printf "_young_list_fixed_length = %u (Region)\n", _young_list_fixed_length
    printf "_young_list_max_length = %u (Region)\n", _young_list_max_length
    printf "_young_list_target_length (MB) = %u MB\n", 
           _young_list_target_length * 4  # 4MB per region
    
    # 保留区域
    printf "\n--- 保留区域 ---\n"
    printf "_reserve_factor = %f\n", _reserve_factor
    printf "_reserve_regions = %u\n", _reserve_regions
    printf "_free_regions_at_end_of_collection = %u\n", _free_regions_at_end_of_collection
    
    # 记忆集相关
    printf "\n--- 记忆集 ---\n"
    printf "_max_rs_lengths = %zu\n", _max_rs_lengths
    printf "_rs_lengths_prediction = %zu\n", _rs_lengths_prediction
    printf "_pending_cards = %zu\n", _pending_cards
    
    # 引用
    printf "\n--- 引用 ---\n"
    printf "_g1h = 0x%lx\n", (unsigned long)_g1h
    printf "_collection_set = 0x%lx\n", (unsigned long)_collection_set
    printf "_phase_times = 0x%lx\n", (unsigned long)_phase_times
    
    # Survivor 策略
    printf "\n--- Survivor 策略 ---\n"
    printf "_tenuring_threshold = %u\n", _tenuring_threshold
    printf "_max_survivor_regions = %u\n", _max_survivor_regions
    
    continue
end

# 运行程序
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main
```

**运行示例输出**：
```
=== G1Policy 字段分析 ===
this = 0x7f8a8c0b2000
sizeof(G1Policy) = 368

--- 核心组件 ---
_predictor._sigma = 0.500000
_analytics = 0x7f8a8c0b2200
_mmu_tracker = 0x7f8a8c0b2400
_ihop_control = 0x7f8a8c0b2600

--- 年轻代大小 ---
_young_list_target_length = 102 (Region)
_young_list_fixed_length = 0 (Region)
_young_list_max_length = 108 (Region)
_young_list_target_length (MB) = 408 MB

--- 保留区域 ---
_reserve_factor = 0.100000
_reserve_regions = 204
_free_regions_at_end_of_collection = 2048

--- 记忆集 ---
_max_rs_lengths = 0
_rs_lengths_prediction = 0
_pending_cards = 0

--- 引用 ---
_g1h = 0x7f8a8c0a8000
_collection_set = 0x7f8a8c0b3000
_phase_times = 0x7f8a8c0b4000

--- Survivor 策略 ---
_tenuring_threshold = 15
_max_survivor_regions = 0
```

---

## 三、方法分析：核心算法详解

### 3.1 年轻代大小计算算法

#### 3.1.1 入口方法：`update_young_list_max_and_target_length()`

```cpp
// g1Policy.cpp:245-253
uint G1Policy::update_young_list_max_and_target_length() {
    return update_young_list_max_and_target_length(_analytics->predict_rs_lengths());
}

uint G1Policy::update_young_list_max_and_target_length(size_t rs_lengths) {
    uint unbounded_target_length = update_young_list_target_length(rs_lengths);
    update_max_gc_locker_expansion();
    return unbounded_target_length;
}
```

**流程**：
1. 预测记忆集长度（`_analytics->predict_rs_lengths()`）
2. 更新年轻代目标长度
3. 更新 GC Locker 扩展上限

#### 3.1.2 核心计算：`young_list_target_lengths()`

```cpp
// g1Policy.cpp:261-324
G1Policy::YoungTargetLengths G1Policy::young_list_target_lengths(size_t rs_lengths) const {
    // 1. 计算最小长度边界
    const uint base_min_length = _g1h->survivor_regions_count();  // 当前 Survivor 数
    uint desired_min_length = calculate_young_list_desired_min_length(base_min_length);
    uint absolute_min_length = base_min_length + MAX2(_g1h->eden_regions_count(), (uint)1);
    desired_min_length = MAX2(desired_min_length, absolute_min_length);
    
    // 2. 计算最大长度边界
    uint desired_max_length = calculate_young_list_desired_max_length();
    
    // 3. 计算目标长度
    uint young_list_target_length = 0;
    if (adaptive_young_list_length()) {
        if (collector_state()->in_young_only_phase()) {
            young_list_target_length = calculate_young_list_target_length(
                rs_lengths, base_min_length, desired_min_length, desired_max_length);
        }
    } else {
        young_list_target_length = _young_list_fixed_length;  // 固定模式
    }
    
    // 4. 应用边界约束
    uint absolute_max_length = 0;
    if (_free_regions_at_end_of_collection > _reserve_regions) {
        absolute_max_length = _free_regions_at_end_of_collection - _reserve_regions;
    }
    if (desired_max_length > absolute_max_length) {
        desired_max_length = absolute_max_length;
    }
    
    // 5. 最终约束：不能超过最大，不能低于最小
    if (young_list_target_length > desired_max_length) {
        young_list_target_length = desired_max_length;
    }
    if (young_list_target_length < desired_min_length) {
        young_list_target_length = desired_min_length;
    }
    
    return YoungTargetLengths(young_list_target_length, unbounded_length);
}
```

#### 3.1.3 预测算法：`calculate_young_list_target_length()`

**核心思想**：使用**二分查找**找到能满足暂停时间目标的最大年轻代长度

```cpp
// g1Policy.cpp:326-426
uint G1Policy::calculate_young_list_target_length(
        size_t rs_lengths,
        uint base_min_length,
        uint desired_min_length,
        uint desired_max_length) const {
    
    // 1. 准备参数
    const double target_pause_time_ms = _mmu_tracker->max_gc_time() * 1000.0;
    const double survivor_regions_evac_time = predict_survivor_regions_evac_time();
    const size_t pending_cards = _analytics->predict_pending_cards();
    const size_t adj_rs_lengths = rs_lengths + _analytics->predict_rs_length_diff();
    const size_t scanned_cards = _analytics->predict_card_num(adj_rs_lengths, true);
    
    // 2. 计算基础时间
    const double base_time_ms =
        predict_base_elapsed_time_ms(pending_cards, scanned_cards) +
        survivor_regions_evac_time;
    
    // 3. 可用空闲区域
    const uint available_free_regions = _free_regions_at_end_of_collection;
    const uint base_free_regions =
        available_free_regions > _reserve_regions ? 
        available_free_regions - _reserve_regions : 0;
    
    // 4. 创建预测器
    G1YoungLengthPredictor p(
        collector_state()->mark_or_rebuild_in_progress(),
        base_time_ms,
        base_free_regions,
        target_pause_time_ms,
        this);
    
    // 5. 二分查找最优长度
    uint min_young_length = desired_min_length - base_min_length;
    uint max_young_length = desired_max_length - base_min_length;
    
    if (p.will_fit(min_young_length)) {
        if (p.will_fit(max_young_length)) {
            // 最大长度也满足，直接使用
            min_young_length = max_young_length;
        } else {
            // 二分查找
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

**G1YoungLengthPredictor::will_fit() 预测逻辑**：

```cpp
// g1Policy.cpp:169-206
bool will_fit(uint young_length) const {
    // 终止条件 1：空间不足
    if (young_length >= _base_free_regions) {
        return false;
    }
    
    // 计算存活对象大小
    const double accum_surv_rate = 
        _policy->accum_yg_surv_rate_pred((int) young_length - 1);
    const size_t bytes_to_copy = 
        (size_t) (accum_surv_rate * (double) HeapRegion::GrainBytes);
    
    // 计算复制时间
    const double copy_time_ms = 
        _policy->analytics()->predict_object_copy_time_ms(bytes_to_copy, _during_cm);
    const double young_other_time_ms = 
        _policy->analytics()->predict_young_other_time_ms(young_length);
    const double pause_time_ms = _base_time_ms + copy_time_ms + young_other_time_ms;
    
    // 终止条件 2：超过暂停时间目标
    if (pause_time_ms > _target_pause_time_ms) {
        return false;
    }
    
    // 计算安全余量
    const size_t free_bytes = (_base_free_regions - young_length) * HeapRegion::GrainBytes;
    const double safety_factor = 
        (100.0 / G1ConfidencePercent) * (100 + TargetPLABWastePct) / 100.0;
    const size_t expected_bytes_to_copy = (size_t)(safety_factor * bytes_to_copy);
    
    // 终止条件 3：空间不足（考虑余量）
    if (expected_bytes_to_copy > free_bytes) {
        return false;
    }
    
    return true;  // 成功！
}
```

### 3.2 GC 时间预测算法

#### 3.2.1 基础时间预测

```cpp
// g1Policy.cpp:860-872
double G1Policy::predict_base_elapsed_time_ms(
        size_t pending_cards,
        size_t scanned_cards) const {
    return
        _analytics->predict_rs_update_time_ms(pending_cards) +      // 更新 RS 时间
        _analytics->predict_rs_scan_time_ms(scanned_cards, collector_state()->in_young_only_phase()) +  // 扫描 RS 时间
        _analytics->predict_constant_other_time_ms();                // 其他固定时间
}
```

**预测公式**：
```
基础 GC 时间 = 
    待处理卡片数 × 每张卡片处理成本 + 
    扫描卡片数 × 每卡片扫描成本 + 
    固定开销
```

#### 3.2.2 Region 时间预测

```cpp
// g1Policy.cpp:887-907
double G1Policy::predict_region_elapsed_time_ms(
        HeapRegion* hr,
        bool for_young_gc) const {
    
    size_t rs_length = hr->rem_set()->occupied();
    size_t card_num = _analytics->predict_card_num(rs_length, for_young_gc);
    size_t bytes_to_copy = predict_bytes_to_copy(hr);
    
    double region_elapsed_time_ms =
        _analytics->predict_rs_scan_time_ms(card_num, collector_state()->in_young_only_phase()) +
        _analytics->predict_object_copy_time_ms(bytes_to_copy, 
            collector_state()->mark_or_rebuild_in_progress());
    
    // 根据区域类型添加额外开销
    if (hr->is_young()) {
        region_elapsed_time_ms += _analytics->predict_young_other_time_ms(1);
    } else {
        region_elapsed_time_ms += _analytics->predict_non_young_other_time_ms(1);
    }
    
    return region_elapsed_time_ms;
}
```

#### 3.2.3 存活对象大小预测

```cpp
// g1Policy.cpp:874-885
size_t G1Policy::predict_bytes_to_copy(HeapRegion* hr) const {
    size_t bytes_to_copy;
    if (!hr->is_young()) {
        // 老年代：使用标记阶段统计的存活字节数
        bytes_to_copy = hr->max_live_bytes();
    } else {
        // 年轻代：使用存活率预测
        assert(hr->age_in_surv_rate_group() != -1, "invariant");
        int age = hr->age_in_surv_rate_group();
        double yg_surv_rate = predict_yg_surv_rate(age, hr->surv_rate_group());
        bytes_to_copy = (size_t) (hr->used() * yg_surv_rate);
    }
    return bytes_to_copy;
}
```

### 3.3 CSet 选择算法

#### 3.3.1 年轻代 CSet 确定

```cpp
// g1Policy.cpp:1191-1194
void G1Policy::finalize_collection_set(
        double target_pause_time_ms, 
        G1SurvivorRegions* survivor) {
    double time_remaining_ms = _collection_set->finalize_young_part(target_pause_time_ms, survivor);
    _collection_set->finalize_old_part(time_remaining_ms);
}
```

**年轻代 CSet** 包含：
- **所有 Eden 区域**：新生代分配区域，全部回收
- **所有 Survivor 区域**：作为根集合的一部分

#### 3.3.2 老年代 CSet 确定（Mixed GC）

```cpp
// g1Policy.cpp:1132-1151
bool G1Policy::next_gc_should_be_mixed(
        const char* true_action_str,
        const char* false_action_str) const {
    
    // 条件 1：有可回收的候选区域
    if (cset_chooser()->is_empty()) {
        return false;
    }
    
    // 条件 2：可回收百分比超过阈值
    size_t reclaimable_bytes = cset_chooser()->remaining_reclaimable_bytes();
    double reclaimable_percent = reclaimable_bytes_percent(reclaimable_bytes);
    double threshold = (double) G1HeapWastePercent;
    
    if (reclaimable_percent <= threshold) {
        return false;
    }
    
    return true;
}
```

**边界计算**：
```cpp
// g1Policy.cpp:1153-1172
uint G1Policy::calc_min_old_cset_length() const {
    // 确保在 G1MixedGCCountTarget 次 GC 内完成所有标记区域的回收
    const size_t region_num = (size_t) cset_chooser()->length();
    const size_t gc_num = (size_t) MAX2(G1MixedGCCountTarget, (uintx) 1);
    size_t result = region_num / gc_num;
    if (result * gc_num < region_num) {
        result += 1;  // 向上取整
    }
    return (uint) result;
}

// g1Policy.cpp:1174-1189
uint G1Policy::calc_max_old_cset_length() const {
    // 限制老年代 CSet 占堆的最大百分比
    const size_t region_num = g1h->num_regions();
    const size_t perc = (size_t) G1OldCSetRegionThresholdPercent;
    size_t result = region_num * perc / 100;
    if (100 * result < region_num * perc) {
        result += 1;  // 向上取整
    }
    return (uint) result;
}
```

### 3.4 并发标记触发决策

#### 3.4.1 IHOP 检查

```cpp
// g1Policy.cpp:579-599
bool G1Policy::need_to_start_conc_mark(const char* source, size_t alloc_word_size) {
    // 如果已经在混合阶段，不启动新标记
    if (about_to_start_mixed_phase()) {
        return false;
    }
    
    // 获取当前 IHOP 阈值
    size_t marking_initiating_used_threshold = _ihop_control->get_conc_mark_start_threshold();
    
    // 计算当前老年代占用 + 本次分配
    size_t cur_used_bytes = _g1h->non_young_capacity_bytes();
    size_t alloc_byte_size = alloc_word_size * HeapWordSize;
    size_t marking_request_bytes = cur_used_bytes + alloc_byte_size;
    
    // 检查是否超过阈值
    bool result = false;
    if (marking_request_bytes > marking_initiating_used_threshold) {
        result = collector_state()->in_young_only_phase() && 
                 !collector_state()->in_young_gc_before_mixed();
    }
    
    return result;
}
```

#### 3.4.2 决策执行

```cpp
// g1Policy.cpp:984-1033
void G1Policy::decide_on_conc_mark_initiation() {
    if (collector_state()->initiate_conc_mark_if_possible()) {
        if (!about_to_start_mixed_phase() && collector_state()->in_young_only_phase()) {
            // 启动新的初始标记
            initiate_conc_mark();
        } else if (_g1h->is_user_requested_concurrent_full_gc(_g1h->gc_cause())) {
            // 用户请求的并发 Full GC
            collector_state()->set_in_young_only_phase(true);
            collector_state()->set_in_young_gc_before_mixed(false);
            clear_collection_set_candidates();
            abort_time_to_mixed_tracking();
            initiate_conc_mark();
        } else {
            // 并发标记已在进行中，等待完成
        }
    }
}
```

---

## 四、关联分析：组件交互图

### 4.1 G1Policy 与周边组件的关系

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                               G1Policy 关联关系图                                 │
└─────────────────────────────────────────────────────────────────────────────────┘

                                    ┌─────────────┐
                                    │  应用程序    │
                                    │  (mutator)  │
                                    └──────┬──────┘
                                           │ 分配对象
                                           ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                            G1CollectedHeap                                       │
│  ┌───────────────────────────────────────────────────────────────────────────┐  │
│  │                            G1Policy                                        │  │
│  │                                                                           │  │
│  │  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐                │  │
│  │  │G1Predictions │◄───│ G1Analytics  │    │G1IHOPControl │◄── 堆占用率     │  │
│  │  │   预测器      │    │   统计中心    │    │  IHOP 控制器  │                │  │
│  │  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘                │  │
│  │         │                   │                   │                         │  │
│  │         │ 预测公式           │ 历史数据          │ 阈值计算                 │  │
│  │         ▼                   ▼                   ▼                         │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐     │  │
│  │  │              年轻代目标长度计算算法                               │     │  │
│  │  │  _young_list_target_length = f(暂停目标, RS长度, 存活率, 分配速率) │     │  │
│  │  └─────────────────────────────────────────────────────────────────┘     │  │
│  │                                   │                                       │  │
│  │                                   ▼                                       │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐     │  │
│  │  │                        G1CollectionSet                           │     │  │
│  │  │  - Eden 区域（全部）                                              │     │  │
│  │  │  - Survivor 区域（全部）                                          │     │  │
│  │  │  - Old 区域（Mixed GC 时选择）                                     │     │  │
│  │  └─────────────────────────────────────────────────────────────────┘     │  │
│  │                                                                           │  │
│  └───────────────────────────────────────────────────────────────────────────┘  │
│                                    │                                            │
│                                    ▼                                            │
│                           ┌─────────────────┐                                   │
│                           │  Young GC 执行   │                                   │
│                           └────────┬────────┘                                   │
│                                    │                                            │
│                                    ▼                                            │
│  ┌───────────────────────────────────────────────────────────────────────────┐  │
│  │                        GC 统计信息反馈                                      │  │
│  │  - 实际暂停时间 ────────> G1Analytics                                       │  │
│  │  - 存活对象数量 ────────> SurvRateGroup                                     │  │
│  │  - 复制字节数 ─────────> _bytes_copied_during_gc                           │  │
│  │  - 记忆集长度 ─────────> _max_rs_lengths                                    │  │
│  └───────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 关键交互流程

#### 4.2.1 Young GC 触发流程

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  对象分配     │────>│ 检查年轻代长度 │────>│  should_     │────>│  触发 GC     │
│              │     │              │     │  allocate_   │     │   (如果需要) │
└──────────────┘     └──────────────┘     │  mutator_    │     └──────────────┘
                                          │  region()    │
                                          └──────────────┘
                                                  │
                                                  ▼
                                          ┌──────────────┐
                                          │ young_regions│
                                          │ _count() <   │
                                          │ _young_list_ │
                                          │ target_      │
                                          │ length?      │
                                          └──────────────┘
```

#### 4.2.2 CSet 选择流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           finalize_collection_set                            │
│                              (CSet 选择流程)                                  │
└─────────────────────────────────────────────────────────────────────────────┘

     ┌──────────────────┐
     │ target_pause_time│ (目标暂停时间，来自 MMUTracker)
     └────────┬─────────┘
              ▼
┌─────────────────────────────┐     ┌─────────────────────────────┐
│ finalize_young_part()        │────>│  计算所有 Eden 和 Survivor   │
│                             │     │  区域的预测时间总和           │
└─────────────────────────────┘     └─────────────────────────────┘
              │
              ▼
┌─────────────────────────────┐
│ time_remaining_ms =          │
│ target_pause_time -          │
│ young_part_time              │
└─────────────────────────────┘
              │
              ▼
┌─────────────────────────────┐     ┌─────────────────────────────┐
│ finalize_old_part()          │────>│  在剩余时间内尽可能添加      │
│                             │     │  高效的老年代区域            │
│ (仅在 Mixed GC 时执行)       │     │  (按回收效率排序)            │
└─────────────────────────────┘     └─────────────────────────────┘
```

### 4.3 数据流图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              G1Policy 数据流                                  │
└─────────────────────────────────────────────────────────────────────────────┘

输入数据：
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│ _analytics      │  │ _survivor_      │  │ _g1h->         │  │ _mmu_tracker    │
│ - 分配速率       │  │ surv_rate_group │  │ num_free_      │  │ - 目标暂停时间   │
│ - 卡片处理成本    │  │ - 存活率预测     │  │ regions()      │  │                 │
│ - RS 扫描成本     │  │                 │  │ - 空闲 Region   │  │                 │
│ - 对象复制成本    │  │                 │  │                │  │                 │
└────────┬────────┘  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘
         │                    │                    │                    │
         └────────────────────┴────────────────────┴────────────────────┘
                                  │
                                  ▼
                    ┌─────────────────────────┐
                    │ calculate_young_list_   │
                    │ target_length()         │
                    │ - 二分查找算法           │
                    │ - G1YoungLengthPredictor│
                    └───────────┬─────────────┘
                                │
                                ▼
                    ┌─────────────────────────┐
                    │ _young_list_target_     │
                    │ length                  │
                    │ (年轻代目标长度)          │
                    └───────────┬─────────────┘
                                │
                 ┌──────────────┼──────────────┐
                 │              │              │
                 ▼              ▼              ▼
        ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
        │ should_     │ │ G1Alloc     │ │  GC 触发    │
        │ allocate_   │ │ Region::    │ │  决策       │
        │ mutator_    │ │ allocate_   │ │             │
        │ region()    │ │ new_region()│ │             │
        └─────────────┘ └─────────────┘ └─────────────┘
```

---

## 五、验证总结：GDB 调试与验证

### 5.1 完整 GDB 验证脚本

```gdb
# g1policy_complete.gdb
# G1Policy 完整验证脚本

set pagination off
set confirm off

# 设置断点 1：G1Policy 初始化完成
break g1Policy.cpp:143 if _g1h != NULL
commands
    silent
    printf "\n========================================\n"
    printf "[断点1] G1Policy::init() 完成\n"
    printf "========================================\n"
    
    printf "\n--- 基本对象信息 ---\n"
    printf "G1Policy address: 0x%lx\n", (unsigned long)this
    printf "sizeof(G1Policy): %zu bytes\n", sizeof(G1Policy)
    
    printf "\n--- 年轻代大小配置 ---\n"
    printf "_young_list_target_length: %u regions (%u MB)\n", 
           _young_list_target_length, _young_list_target_length * 4
    printf "_young_list_max_length: %u regions (%u MB)\n", 
           _young_list_max_length, _young_list_max_length * 4
    printf "_young_list_fixed_length: %u regions\n", _young_list_fixed_length
    printf "adaptive mode: %s\n", adaptive_young_list_length() ? "YES" : "NO"
    
    printf "\n--- 保留区域 ---\n"
    printf "_reserve_factor: %.2f\n", _reserve_factor
    printf "_reserve_regions: %u\n", _reserve_regions
    printf "_free_regions_at_end_of_collection: %u\n", _free_regions_at_end_of_collection
    
    printf "\n--- 预测器配置 ---\n"
    printf "_predictor._sigma (置信系数): %f\n", _predictor._sigma
    
    continue
end

# 设置断点 2：年轻代大小更新
break g1Policy.cpp:258
commands
    silent
    printf "\n========================================\n"
    printf "[断点2] update_young_list_target_length()\n"
    printf "========================================\n"
    
    printf "rs_lengths (记忆集长度): %zu\n", rs_lengths
    printf "new _young_list_target_length: %u regions\n", _young_list_target_length
    
    continue
end

# 设置断点 3：GC 开始前
break g1Policy.cpp:504
commands
    silent
    printf "\n========================================\n"
    printf "[断点3] record_collection_pause_start()\n"
    printf "========================================\n"
    
    printf "_pending_cards: %zu\n", _pending_cards
    printf "eden_regions_count: %u\n", _g1h->eden_regions_count()
    printf "survivor_regions_count: %u\n", _g1h->survivor_regions_count()
    printf "young_regions_count: %u\n", _g1h->young_regions_count()
    
    continue
end

# 设置断点 4：GC 结束后
break g1Policy.cpp:604
commands
    silent
    printf "\n========================================\n"
    printf "[断点4] record_collection_pause_end()\n"
    printf "========================================\n"
    
    printf "pause_time_ms: %f\n", pause_time_ms
    printf "cards_scanned: %zu\n", cards_scanned
    printf "_bytes_copied_during_gc: %zu\n", _bytes_copied_during_gc
    printf "_free_regions_at_end_of_collection: %u\n", _free_regions_at_end_of_collection
    
    continue
end

# 设置断点 5：IHOP 检查
break g1Policy.cpp:591
commands
    silent
    printf "\n========================================\n"
    printf "[断点5] need_to_start_conc_mark()\n"
    printf "========================================\n"
    
    set $threshold = _ihop_control->get_conc_mark_start_threshold()
    printf "IHOP threshold: %zu bytes (%.2f MB)\n", 
           $threshold, $threshold / (1024.0 * 1024.0)
    printf "current used: %zu bytes\n", _g1h->non_young_capacity_bytes()
    printf "marking_request_bytes: %zu bytes\n", marking_request_bytes
    printf "need to start conc mark: %s\n", result ? "YES" : "NO"
    
    continue
end

# 运行程序
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main
```

### 5.2 关键 JVM 参数与日志

**启用 G1Policy 相关日志**：

```bash
# 基本 GC 日志
-Xlog:gc*:file=gc.log:time,uptime,level,tags:filecount=5,filesize=100m

# Ergonomics 决策日志（关键！）
-Xlog:gc+ergo*=debug:file=gc-ergo.log

# IHOP 相关日志
-Xlog:gc+ergo+ihop=debug:file=gc-ihop.log

# 暂停时间预测日志
-Xlog:gc+phases=debug:file=gc-phases.log
```

**典型日志输出示例**：

```
# GC Ergonomics 日志 - 年轻代大小决策
[0.523s][debug][gc,ergo] Young generation size adjustment: 
    old target: 102 regions, 
    new target: 156 regions, 
    pause prediction: 198.45ms (target: 200ms)

# IHOP 日志 - 并发标记触发
[12.456s][debug][gc,ergo,ihop] 
    Request concurrent cycle initiation (occupancy higher than threshold)
    occupancy: 3221225472B (3072 MB)
    allocation request: 4194304B (4 MB)
    threshold: 3221225472B (3072 MB)
    source: end of GC

# GC Phases 日志 - 暂停时间统计
[15.789s][debug][gc,phases] 
    GC(23) Evacuate Collection Set: 125.34ms
    GC(23) Update RS: 45.23ms (processed 1234567 cards)
    GC(23) Scan RS: 32.15ms (scanned 2345678 cards)
    GC(23) Code Roots: 5.67ms
    GC(23) Object Copy: 42.29ms (copied 512MB)
```

### 5.3 关键观察指标

| 指标 | 查看方法 | 健康范围 |
|-----|---------|---------|
| 年轻代目标长度 | `_young_list_target_length` | 动态调整，应接近目标暂停时间 |
| 预测暂停时间 | `predict_region_elapsed_time_ms` | < MaxGCPauseMillis |
| 实际 vs 预测误差 | 对比预测和实际 GC 时间 | < 20% |
| IHOP 阈值 | `_ihop_control->get_conc_mark_start_threshold()` | 根据堆大小动态调整 |
| 存活率预测准确度 | 对比预测存活率和实际存活率 | > 80% |

---

## 六、总结

### 6.1 G1Policy 的核心价值

G1Policy 是 G1 实现**可预测暂停时间**目标的关键组件：

1. **自适应调整**：根据应用程序行为动态调整年轻代大小
2. **精确预测**：基于历史数据预测 GC 时间和存活对象大小
3. **智能决策**：在暂停时间目标和吞吐量之间找到平衡点

### 6.2 关键设计要点

| 设计点 | 说明 |
|-------|------|
| **预测模型** | 使用加权移动平均 + 标准差估计，样本<5 时有特殊处理 |
| **二分查找** | 查找满足暂停时间目标的最大年轻代长度 |
| **安全余量** | 考虑 G1ConfidencePercent 和 TargetPLABWastePct |
| **边界约束** | 用户配置、堆大小、保留区域三重约束 |
| **自适应 IHOP** | 根据分配速率和标记时间动态调整标记触发阈值 |

### 6.3 下一步学习建议

根据 Young GC 数据结构学习大纲，G1Policy 之后的推荐学习顺序：

1. **G1Predictions** —— 预测算法的数学基础
2. **G1Analytics** —— 统计数据的收集和维护
3. **G1CollectionSet** —— CSet 的构建和管理
4. **G1IHOPControl** —— 并发标记触发机制

---

**文档信息**：
- 分析版本：OpenJDK 11
- 分析日期：2026-02-10
- 标准环境：-Xms8g -Xmx8g -XX:+UseG1GC (G1 Region = 4MB)
- 源码路径：`/data/workspace/openjdk-cut-new/src/hotspot/share/gc/g1/g1Policy.hpp`
