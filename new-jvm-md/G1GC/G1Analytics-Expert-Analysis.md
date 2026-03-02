# G1Analytics 专家级源码分析

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1Analytics 的本质是**G1 GC 的历史数据仓库**：维护 17 个 `TruncatedSeq`（截断序列，保留最近 N 个样本），分别跟踪 GC 暂停时间、分配速率、卡片处理成本等关键指标；`G1Predictions` 从这些序列中计算 EMA（指数移动平均）和置信区间，为 `G1Policy` 的决策提供数据基础。

### 0.2 为什么需要？

G1Policy 需要预测"回收 N 个 Region 需要多少时间"，但 GC 代价随应用负载动态变化。需要一个历史数据仓库：记录每次 GC 的各项指标，供预测模型使用。G1Analytics 就是这个仓库，`TruncatedSeq` 保证只保留最近的样本（避免历史数据过时影响预测）。

### 0.3 怎么解决？

**17 个 TruncatedSeq + EMA 预测**：每次 GC 后 `G1Policy::record_collection_pause_end()` 更新各个序列；`G1Predictions::predict_in_unit_intervals()` 从序列计算 EMA；`G1Policy` 用预测值计算 CSet 大小和 IHOP 阈值。

### 0.4 为什么这样设计？

- **为什么用 TruncatedSeq 而不是无限历史？** 应用行为随时间变化，太旧的数据会降低预测精度；TruncatedSeq 只保留最近 N 个样本（默认 8），让预测模型快速适应应用行为变化
- **为什么需要 17 个序列而不是 1 个？** 不同指标的变化规律不同（分配速率变化快，卡片处理成本变化慢）；分开记录可以对每个指标独立调整权重和窗口大小

---

## 一、宏观理解：G1 的统计数据中心

### 1.1 一句话总结

**G1Analytics 是 G1 的统计数据中心**，维护 **17 个 TruncatedSeq 序列**，分别跟踪 GC 暂停时间、分配速率、卡片处理成本等关键指标，为 G1Policy 的预测决策提供数据基础。

### 1.2 为什么需要 G1Analytics？

**问题背景**：
- G1Policy 需要预测未来的 GC 行为（暂停时间、存活对象大小等）
- 预测需要基于历史统计数据
- 不同指标需要分开跟踪（Young GC vs Mixed GC、并发标记期间 vs 正常期间）

**解决方案**：
- G1Analytics 集中管理所有 GC 相关的统计数据
- 每个指标一个 TruncatedSeq（保留最近 10 个样本）
- 提供统一的 `report_*` 接口记录数据、`predict_*` 接口获取预测

### 1.3 核心设计思想

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         G1Analytics 设计思想                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   GC 执行 ──> 收集统计数据 ──> 存入 TruncatedSeq ──> 预测时读取               │
│                                                                              │
│   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐  │
│   │ report_*()  │───>│ TruncatedSeq│───>│ get_new_    │───>│  prediction │  │
│   │  记录数据   │    │  存储历史   │    │ prediction()│    │   预测值    │  │
│   └─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘  │
│                                                                              │
│   17 个指标分类：                                                             │
│   ├── 时间类：GC 暂停时间、Remark/Cleanup 时间                               │
│   ├── 成本类：每卡片成本、每字节复制成本、每 RS 条目成本                     │
│   ├── 比率类：分配速率、卡片/条目比率                                        │
│   └── 数量类：待处理卡片数、RS 长度                                          │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.4 G1Analytics 在系统中的位置

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              G1Policy                                        │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  ┌─────────────┐        ┌─────────────────────────────────────────┐  │  │
│  │  │G1Predictions│<───────│           G1Analytics                    │  │  │
│  │  │   (预测器)   │        │          (统计数据中心)                   │  │  │
│  │  └─────────────┘        └─────────────────────────────────────────┘  │  │
│  │                                   │                                   │  │
│  │         ┌───────────────────────┼───────────────────────┐            │  │
│  │         │                       │                       │            │  │
│  │         ▼                       ▼                       ▼            │  │
│  │  ┌─────────────┐        ┌─────────────┐        ┌─────────────┐       │  │
│  │  │ _alloc_rate │        │ _cost_per_  │        │ _recent_gc_ │       │  │
│  │  │ _ms_seq     │        │ card_ms_seq │        │ _times_ms   │       │  │
│  │  └─────────────┘        └─────────────┘        └─────────────┘       │  │
│  │         │                       │                       │            │  │
│  │         │ 17 个 TruncatedSeq    │                       │            │  │
│  │         └───────────────────────┼───────────────────────┘            │  │
│  │                                 │                                    │  │
│  │  ┌──────────────────────────────┴──────────────────────────────┐    │  │
│  │  │                    GC 执行流程                                │    │  │
│  │  │  record_collection_pause_end()                                │    │  │
│  │  │    ├── report_alloc_rate_ms()                                 │    │  │
│  │  │    ├── report_cost_per_card_ms()                              │    │  │
│  │  │    ├── report_rs_lengths()                                    │    │  │
│  │  │    └── ...                                                    │    │  │
│  │  └──────────────────────────────────────────────────────────────┘    │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 二、字段分析：数据结构的完整解剖

### 2.1 类定义与内存布局

```cpp
// g1Analytics.hpp:34-159
class G1Analytics: public CHeapObj<mtGC> {
    const static int TruncatedSeqLength = 10;           // 默认序列长度
    const static int NumPrevPausesForHeuristics = 10;   // 暂停时间序列长度
    const G1Predictions* _predictor;                    // 预测器指针
    
    // 17 个 TruncatedSeq 指针
    TruncatedSeq* _recent_gc_times_ms;                  // 最近 GC 暂停时间
    TruncatedSeq* _concurrent_mark_remark_times_ms;     // Remark 时间
    TruncatedSeq* _concurrent_mark_cleanup_times_ms;    // Cleanup 时间
    TruncatedSeq* _alloc_rate_ms_seq;                   // 内存分配速率
    TruncatedSeq* _rs_length_diff_seq;                  // RS 长度差异
    TruncatedSeq* _cost_per_card_ms_seq;                // 每张卡片处理成本
    TruncatedSeq* _cost_scan_hcc_seq;                   // 扫描热卡片缓存成本
    TruncatedSeq* _young_cards_per_entry_ratio_seq;     // Young GC 卡片/条目比
    TruncatedSeq* _mixed_cards_per_entry_ratio_seq;     // Mixed GC 卡片/条目比
    TruncatedSeq* _cost_per_entry_ms_seq;               // 每个 RS 条目处理成本
    TruncatedSeq* _mixed_cost_per_entry_ms_seq;         // Mixed GC 条目成本
    TruncatedSeq* _cost_per_byte_ms_seq;                // 每字节复制成本
    TruncatedSeq* _cost_per_byte_ms_during_cm_seq;      // 并发标记期间复制成本
    TruncatedSeq* _constant_other_time_ms_seq;          // 其他固定时间
    TruncatedSeq* _young_other_cost_per_region_ms_seq;  // 年轻代其他成本
    TruncatedSeq* _non_young_other_cost_per_region_ms_seq; // 老年代其他成本
    TruncatedSeq* _pending_cards_seq;                   // 待处理卡片数
    TruncatedSeq* _rs_lengths_seq;                      // RS 长度
    TruncatedSeq* _recent_prev_end_times_for_all_gcs_sec; // GC 结束时间
    
    // 其他字段
    double _prev_collection_pause_end_ms;               // 上次 GC 结束时间
    double _recent_avg_pause_time_ratio;                // 平均暂停时间比率
    double _last_pause_time_ratio;                      // 上次暂停时间比率
};
```

**对象大小估算**（64-bit 系统）：
```
G1Analytics 对象本身：
  - _predictor: 8 bytes
  - 17 个 TruncatedSeq*: 17 × 8 = 136 bytes
  - 3 个 double: 3 × 8 = 24 bytes
  - 总计: ~168 bytes + 对齐

TruncatedSeq 对象（17 个）：
  - 每个 TruncatedSeq: ~160 bytes（对象）+ 80 bytes（数组）= 240 bytes
  - 17 × 240 = 4080 bytes ≈ 4 KB

总计: ~4.2 KB（可忽略不计）
```

### 2.2 17 个 TruncatedSeq 详解

#### 2.2.1 时间类指标（3 个）

| 字段 | 用途 | 序列长度 | 默认值 |
|-----|------|---------|--------|
| `_recent_gc_times_ms` | Young/Mixed GC 暂停时间 | 10 | 无 |
| `_concurrent_mark_remark_times_ms` | 并发标记 Remark 阶段时间 | 10 | 50ms |
| `_concurrent_mark_cleanup_times_ms` | 并发标记 Cleanup 阶段时间 | 10 | 200ms |

**使用场景**：
- 预测下次 GC 暂停时间
- 计算 GC 时间比率

#### 2.2.2 成本类指标（7 个）

| 字段 | 用途 | 计算公式 | 默认值（8 GC 线程） |
|-----|------|---------|-------------------|
| `_cost_per_card_ms_seq` | 每张卡片处理成本 | UpdateRS 时间 / 待处理卡片 | 0.0015 ms |
| `_cost_scan_hcc_seq` | 扫描热卡片缓存成本 | ScanHCC 时间 | 0 |
| `_cost_per_entry_ms_seq` | 每个 RS 条目扫描成本 | ScanRS 时间 / 扫描条目数 | 0.005 ms |
| `_mixed_cost_per_entry_ms_seq` | Mixed GC RS 条目成本 | 同上（Mixed GC 专用） | 无 |
| `_cost_per_byte_ms_seq` | 每字节复制成本 | ObjCopy 时间 / 复制字节数 | 0.000009 ms |
| `_cost_per_byte_ms_during_cm_seq` | 并发标记期间复制成本 | 同上（并发标记期间） | 无 |
| `_constant_other_time_ms_seq` | 其他固定时间 | 不可变开销 | 5 ms |

**预测公式示例**：
```cpp
// 预测 RS 更新时间
predict_rs_update_time_ms(pending_cards) = 
    pending_cards × predict_cost_per_card_ms() + predict_scan_hcc_ms()

// 预测对象复制时间
predict_object_copy_time_ms(bytes_to_copy) = 
    bytes_to_copy × predict_cost_per_byte_ms()
```

#### 2.2.3 比率类指标（2 个）

| 字段 | 用途 | 计算公式 |
|-----|------|---------|
| `_young_cards_per_entry_ratio_seq` | Young GC 卡片/RS 条目比率 | 扫描卡片数 / RS 条目数 |
| `_mixed_cards_per_entry_ratio_seq` | Mixed GC 卡片/RS 条目比率 | 同上（Mixed GC 专用） |

**使用场景**：
```cpp
// 预测 RS 扫描的卡片数
size_t predict_card_num(size_t rs_length, bool for_young_gc) {
    if (for_young_gc) {
        return rs_length × predict_young_cards_per_entry_ratio();
    } else {
        return rs_length × predict_mixed_cards_per_entry_ratio();
    }
}
```

#### 2.2.4 数量类指标（2 个）

| 字段 | 用途 | 记录时机 |
|-----|------|---------|
| `_pending_cards_seq` | 待处理卡片数（Dirty Card） | GC 开始时 |
| `_rs_lengths_seq` | 记忆集总长度 | GC 结束时 |

**作用**：
- 预测下次 GC 的待处理工作量
- 估算 RS 扫描时间

#### 2.2.5 其他指标（3 个）

| 字段 | 用途 |
|-----|------|
| `_alloc_rate_ms_seq` | 内存分配速率（Region/ms） |
| `_rs_length_diff_seq` | RS 长度预测误差 |
| `_recent_prev_end_times_for_all_gcs_sec` | GC 结束时间戳（用于计算间隔） |
| `_young_other_cost_per_region_ms_seq` | 年轻代每个 Region 的其他开销 |
| `_non_young_other_cost_per_region_ms_seq` | 老年代每个 Region 的其他开销 |

### 2.3 默认值策略

**根据 ParallelGCThreads 选择默认值**（g1Analytics.cpp:37-70）：

```cpp
// 示例：cost_per_card_ms_defaults
// 索引 = MIN2(ParallelGCThreads - 1, 7)
// 即支持 1-8 个 GC 线程的配置

static double cost_per_card_ms_defaults[] = {
    0.01,    // 1 GC 线程
    0.005,   // 2 GC 线程
    0.005,   // 3 GC 线程
    0.003,   // 4 GC 线程
    0.003,   // 5 GC 线程
    0.002,   // 6 GC 线程
    0.002,   // 7 GC 线程
    0.0015   // 8+ GC 线程
};
```

**设计思想**：
- GC 线程越多，每张卡片的处理成本越低（并行处理）
- 默认值基于 GCOld 和 SPECjbb 测试调优
- 应用运行后会被实际数据覆盖

### 2.4 GDB 字段验证脚本

```gdb
# g1analytics_fields.gdb - G1Analytics 字段验证

set pagination off

# 断点 1：构造函数完成
break G1Analytics::G1Analytics
commands
    silent
    printf "\n=== G1Analytics 构造函数 ===\n"
    printf "this = 0x%lx\n", (unsigned long)this
    printf "sizeof(G1Analytics) ≈ %zu bytes\n", sizeof(G1Analytics)
    printf "_predictor = 0x%lx\n", (unsigned long)_predictor
    printf "TruncatedSeqLength = %d\n", TruncatedSeqLength
    printf "NumPrevPausesForHeuristics = %d\n", NumPrevPausesForHeuristics
    
    printf "\n--- 17 个 TruncatedSeq 指针 ---\n"
    printf "_recent_gc_times_ms = 0x%lx\n", (unsigned long)_recent_gc_times_ms
    printf "_alloc_rate_ms_seq = 0x%lx\n", (unsigned long)_alloc_rate_ms_seq
    printf "_cost_per_card_ms_seq = 0x%lx\n", (unsigned long)_cost_per_card_ms_seq
    printf "_cost_per_byte_ms_seq = 0x%lx\n", (unsigned long)_cost_per_byte_ms_seq
    printf "_rs_lengths_seq = 0x%lx\n", (unsigned long)_rs_lengths_seq
    printf "... (共 17 个)\n"
    
    continue
end

# 断点 2：记录分配速率时
break G1Analytics::report_alloc_rate_ms
commands
    silent
    printf "\n=== report_alloc_rate_ms ===\n"
    printf "alloc_rate = %f regions/ms\n", alloc_rate
    printf "相当于 %f MB/ms\n", alloc_rate * 4  # 4MB per region
    continue
end

# 断点 3：预测 RS 长度时
break G1Analytics::predict_rs_lengths
commands
    silent
    printf "\n=== predict_rs_lengths ===\n"
    printf "_rs_lengths_seq->num() = %d\n", _rs_lengths_seq->num()
    printf "_rs_lengths_seq->davg() = %f\n", _rs_lengths_seq->davg()
    printf "prediction = %zu\n", predict_rs_lengths()
    continue
end

run -Xms8g -Xmx8g -XX:+UseG1GC -XX:ParallelGCThreads=8 -Xint -cp ... Main
```

---

## 三、方法分析：统计与预测机制

### 3.1 数据记录方法（report_*）

**统一模式**：
```cpp
void report_xxx(double value) {
    _xxx_seq->add(value);
}
```

**关键记录点**（在 `G1Policy::record_collection_pause_end()` 中）：

```cpp
// g1Policy.cpp:633-744（简化版）
void G1Policy::record_collection_pause_end(double pause_time_ms, ...) {
    // 1. 记录分配速率
    uint regions_allocated = _collection_set->eden_region_length();
    double alloc_rate_ms = (double) regions_allocated / app_time_ms;
    _analytics->report_alloc_rate_ms(alloc_rate_ms);
    
    // 2. 记录卡片处理成本
    if (_pending_cards > 0) {
        double cost_per_card_ms = 
            average_time_ms(G1GCPhaseTimes::UpdateRS) / (double) _pending_cards;
        _analytics->report_cost_per_card_ms(cost_per_card_ms);
    }
    
    // 3. 记录 RS 条目扫描成本
    if (cards_scanned > 10) {
        double cost_per_entry_ms = 
            average_time_ms(G1GCPhaseTimes::ScanRS) / (double) cards_scanned;
        _analytics->report_cost_per_entry_ms(cost_per_entry_ms, this_pause_was_young_only);
    }
    
    // 4. 记录对象复制成本
    if (_collection_set->bytes_used_before() > freed_bytes) {
        size_t copied_bytes = _collection_set->bytes_used_before() - freed_bytes;
        double average_copy_time = average_time_ms(G1GCPhaseTimes::ObjCopy);
        double cost_per_byte_ms = average_copy_time / (double) copied_bytes;
        _analytics->report_cost_per_byte_ms(cost_per_byte_ms, ...);
    }
    
    // 5. 记录 RS 长度和待处理卡片
    if (this_pause_was_young_only) {
        _analytics->report_pending_cards((double) _pending_cards);
        _analytics->report_rs_lengths((double) _max_rs_lengths);
    }
}
```

### 3.2 预测方法（predict_*）

**基础预测**：
```cpp
// g1Analytics.cpp:118-124
double G1Analytics::get_new_prediction(TruncatedSeq const* seq) const {
    return _predictor->get_new_prediction(seq);  // 委托给 G1Predictions
}
```

**复合预测公式**：

```cpp
// 1. RS 更新时间预测（线性模型）
double predict_rs_update_time_ms(size_t pending_cards) const {
    return pending_cards × predict_cost_per_card_ms() + predict_scan_hcc_ms();
}
// 时间 = 卡片数 × 单卡片成本 + 热缓存扫描时间

// 2. RS 扫描时间预测（考虑 Young/Mixed GC 差异）
double predict_rs_scan_time_ms(size_t card_num, bool for_young_gc) const {
    if (for_young_gc) {
        return card_num × get_new_prediction(_cost_per_entry_ms_seq);
    } else {
        return predict_mixed_rs_scan_time_ms(card_num);
    }
}

// 3. 对象复制时间预测（考虑并发标记影响）
double predict_object_copy_time_ms(size_t bytes_to_copy, bool during_cm) const {
    if (during_cm) {
        return predict_object_copy_time_ms_during_cm(bytes_to_copy);
    } else {
        return bytes_to_copy × get_new_prediction(_cost_per_byte_ms_seq);
    }
}

// 4. Region 其他时间预测（Young/Old 区分）
double predict_region_other_time_ms(HeapRegion* hr) {
    if (hr->is_young()) {
        return get_new_prediction(_young_other_cost_per_region_ms_seq);
    } else {
        return get_new_prediction(_non_young_other_cost_per_region_ms_seq);
    }
}
```

### 3.3 小样本处理策略

**Mixed GC 数据不足时的回退策略**：

```cpp
// g1Analytics.cpp:241-247
// Mixed GC 卡片/条目比率：数据不足时使用 Young GC 的数据
double predict_mixed_cards_per_entry_ratio() const {
    if (_mixed_cards_per_entry_ratio_seq->num() < 2) {
        return predict_young_cards_per_entry_ratio();  // 回退到 Young GC
    } else {
        return get_new_prediction(_mixed_cards_per_entry_ratio_seq);
    }
}

// g1Analytics.cpp:265-271
// Mixed GC RS 扫描成本：数据不足时使用 Young GC 的数据
double predict_mixed_rs_scan_time_ms(size_t card_num) const {
    if (_mixed_cost_per_entry_ms_seq->num() < 3) {
        return card_num × get_new_prediction(_cost_per_entry_ms_seq);
    } else {
        return card_num × get_new_prediction(_mixed_cost_per_entry_ms_seq);
    }
}

// g1Analytics.cpp:273-279
// 并发标记期间复制成本：数据不足时增加 10% 余量
double predict_object_copy_time_ms_during_cm(size_t bytes_to_copy) const {
    if (_cost_per_byte_ms_during_cm_seq->num() < 3) {
        return (1.1 × bytes_to_copy) × get_new_prediction(_cost_per_byte_ms_seq);
    } else {
        return bytes_to_copy × get_new_prediction(_cost_per_byte_ms_during_cm_seq);
    }
}
```

**设计思想**：
- Mixed GC 执行频率低于 Young GC，数据积累慢
- 数据不足时使用 Young GC 的数据作为近似
- 并发标记期间对象复制可能受干扰，保守估计 +10%

---

## 四、关联分析：组件交互图

### 4.1 完整数据流

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         G1Analytics 数据流全景图                              │
└─────────────────────────────────────────────────────────────────────────────┘

GC 执行阶段
    │
    ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                      record_collection_pause_end()                         │
│  （GC 结束后收集统计数据）                                                  │
└───────────────────────────────────────────────────────────────────────────┘
    │
    ├──> report_alloc_rate_ms() ──> _alloc_rate_ms_seq
    │       计算: eden_regions / app_time
    │
    ├──> report_cost_per_card_ms() ──> _cost_per_card_ms_seq
    │       计算: UpdateRS_time / pending_cards
    │
    ├──> report_cost_per_entry_ms() ──> _cost_per_entry_ms_seq / _mixed_cost_per_entry_ms_seq
    │       计算: ScanRS_time / cards_scanned
    │
    ├──> report_cost_per_byte_ms() ──> _cost_per_byte_ms_seq / _cost_per_byte_ms_during_cm_seq
    │       计算: ObjCopy_time / copied_bytes
    │
    ├──> report_rs_lengths() ──> _rs_lengths_seq
    │       记录: _max_rs_lengths
    │
    └──> report_pending_cards() ──> _pending_cards_seq
            记录: _pending_cards
    │
    ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                      下次 GC 触发前：年轻代大小计算                          │
│                     calculate_young_list_target_length()                   │
└───────────────────────────────────────────────────────────────────────────┘
    │
    ├──> predict_alloc_rate_ms()
    │       预测未来分配速率
    │
    ├──> predict_rs_lengths()
    │       预测记忆集长度
    │
    ├──> predict_rs_update_time_ms(pending_cards)
    │       预测 RS 更新时间
    │       └─> predict_cost_per_card_ms()
    │       └─> predict_scan_hcc_ms()
    │
    ├──> predict_rs_scan_time_ms(card_num, for_young_gc)
    │       预测 RS 扫描时间
    │       └─> predict_card_num() ──> predict_young/mixed_cards_per_entry_ratio()
    │
    └──> predict_object_copy_time_ms(bytes_to_copy, during_cm)
            预测对象复制时间
            └─> predict_cost_per_byte_ms()
    │
    ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                         G1Predictions::get_new_prediction()                │
│  （统一预测公式：davg + sigma × stddev_estimate）                           │
└───────────────────────────────────────────────────────────────────────────┘
    │
    ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                         计算 _young_list_target_length                     │
│  （二分查找找到满足暂停时间目标的最大年轻代长度）                           │
└───────────────────────────────────────────────────────────────────────────┘
```

### 4.2 与其他组件的关系

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        G1Analytics 组件关系图                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                           G1Analytics                                  │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │                      17 个 TruncatedSeq                          │  │  │
│  │  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │  │  │
│  │  │  │ _alloc   │  │ _cost_per│  │ _rs_     │  │ _recent  │        │  │  │
│  │  │  │ _rate_   │  │ _card_   │  │ lengths_ │  │ _gc_     │        │  │  │
│  │  │  │ ms_seq   │  │ ms_seq   │  │ seq      │  │ times_   │        │  │  │
│  │  │  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘        │  │  │
│  │  │       │             │             │             │              │  │  │
│  │  └───────┴─────────────┴─────────────┴─────────────┘              │  │  │
│  │                   │                                                │  │  │
│  │                   │ get_new_prediction()                          │  │  │
│  │                   ▼                                                │  │  │
│  │  ┌─────────────────────────────────────────────────────────────┐  │  │  │
│  │  │                    G1Predictions                             │  │  │  │
│  │  │  prediction = davg + sigma × stddev_estimate                │  │  │  │
│  │  └─────────────────────────────────────────────────────────────┘  │  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│              ┌─────────────────────┼─────────────────────┐                  │
│              │                     │                     │                  │
│              ▼                     ▼                     ▼                  │
│  ┌───────────────────┐  ┌───────────────────┐  ┌───────────────────┐        │
│  │   G1Policy        │  │   G1IHOPControl   │  │  CSet 选择        │        │
│  │ 年轻代大小计算    │  │  IHOP 阈值计算    │  │  Region 预测时间  │        │
│  └───────────────────┘  └───────────────────┘  └───────────────────┘        │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 五、验证总结：日志与调试

### 5.1 关键日志输出

**启用 GC 详细日志**：
```bash
java -Xlog:gc*:debug:file=gc.log:time,uptime,level,tags \
     -Xms8g -Xmx8g -XX:+UseG1GC \
     -jar application.jar
```

**典型日志分析**：
```
# GC 统计记录日志
[15.234s][debug][gc,ergo] GC(23) Allocation rate: 2.5 regions/ms (10 MB/ms)
[15.234s][debug][gc,ergo] GC(23) Cost per card: 0.0018 ms/card
[15.234s][debug][gc,ergo] GC(23) Cost per entry: 0.0052 ms/entry
[15.234s][debug][gc,ergo] GC(23) Cost per byte: 0.000012 ms/byte

# 预测值日志
[20.456s][debug][gc,ergo] GC(25) Predictions:
    RS length: 1234567 entries
    Pending cards: 45678 cards
    Predicted update time: 82.3 ms
    Predicted scan time: 185.6 ms
    Predicted copy time: 45.2 ms
    Total predicted: 313.1 ms (target: 200ms)
```

### 5.2 监控指标建议

| 指标 | 查看方法 | 健康范围 |
|-----|---------|---------|
| 分配速率 | `_analytics->predict_alloc_rate_ms()` | 根据应用负载 |
| 卡片处理成本 | `predict_cost_per_card_ms()` | < 0.01 ms/card |
| 对象复制成本 | `predict_cost_per_byte_ms()` | < 0.00002 ms/byte |
| RS 扫描成本 | `predict_rs_scan_time_ms()` | < 目标暂停的 50% |
| 预测准确度 | 对比预测 vs 实际 | 误差 < 20% |

---

## 六、总结

### 6.1 G1Analytics 的核心价值

G1Analytics 是 G1 **预测能力的根基**：

1. **数据集中管理**：17 个指标，统一维护
2. **自适应学习**：应用运行过程中不断收集数据、更新预测
3. **多场景支持**：Young/Mixed、并发标记期间等不同场景分别统计

### 6.2 关键设计要点

| 设计点 | 说明 |
|-------|------|
| **17 个 TruncatedSeq** | 每个指标独立跟踪，避免相互干扰 |
| **默认值策略** | 基于 GC 线程数选择合理的初始值 |
| **小样本回退** | Mixed GC 数据不足时使用 Young GC 数据 |
| **并发标记补偿** | 并发标记期间增加 10% 复制时间余量 |

### 6.3 学习路径回顾

```
G1Policy (决策中心)
    └── 依赖 G1Predictions (预测公式)
            └── 依赖 G1Analytics (统计数据)
                    └── 依赖 TruncatedSeq (数据容器)

已分析：G1Policy → G1Predictions → G1Analytics
待分析：TruncatedSeq 内部实现、G1CollectionSet
```

---

**文档信息**：
- 分析版本：OpenJDK 11
- 分析日期：2026-02-10
- 源码路径：
  - `/data/workspace/openjdk-cut-new/src/hotspot/share/gc/g1/g1Analytics.hpp`
  - `/data/workspace/openjdk-cut-new/src/hotspot/share/gc/g1/g1Analytics.cpp`
