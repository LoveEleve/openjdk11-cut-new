# G1Policy与CollectionSet 逐行深度源码分析

> **分析目标**: G1 GC策略决策与CSet选择算法  
> **源码文件**: 
> - `src/hotspot/share/gc/g1/g1Policy.cpp/hpp`
> - `src/hotspot/share/gc/g1/g1CollectionSet.cpp/hpp`  

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

`G1Policy` 与 `G1CollectionSet` 的协作本质是**"预测→决策→执行"的闭环控制系统**：`G1Policy` 基于 `G1Analytics`（历史数据）和 `G1Predictions`（EMA 预测）做出决策（年轻代大小/IHOP/CSet 大小），`G1CollectionSet` 执行 CSet 构建，GC 完成后 `G1Policy` 更新历史数据，形成闭环。

### 0.2 核心决策流程

```
每次 GC 前：
  G1Policy::finalize_collection_set()
    → 计算停顿时间预算
    → 将所有 Young Region 加入 CSet
    → Mixed GC 时：从 CollectionSetChooser 贪心选 Old Region
    → 直到预测停顿时间达到 MaxGCPauseMillis

每次 GC 后：
  G1Policy::record_collection_pause_end()
    → 更新 G1Analytics 历史数据
    → 调整年轻代大小目标
    → 更新 IHOP 阈值（自适应 IHOP）
```

### 0.3 关键参数影响

| 参数 | 影响的决策 | 机制 |
|------|-----------|------|
| `-XX:MaxGCPauseMillis` | CSet 大小 | 停顿时间预算 = MaxGCPauseMillis |
| `-XX:G1NewSizePercent` | 年轻代最小值 | 年轻代 ≥ 堆大小 × G1NewSizePercent% |
| `-XX:G1MaxNewSizePercent` | 年轻代最大值 | 年轻代 ≤ 堆大小 × G1MaxNewSizePercent% |
| `-XX:InitiatingHeapOccupancyPercent` | 并发标记触发 | Old 区占用 > IHOP 时触发 |

---
> **分析标准**: 面试级深度 - 逐行解释 + 面试问答 + GDB调试技巧

---

## 第1章: G1Policy类结构与核心字段

### 1.1 G1Policy类定义

```cpp
55: class G1Policy: public CHeapObj<mtGC> {
56:  private:
57:   static G1IHOPControl* create_ihop_control(const G1OldGenAllocationTracker* old_gen_alloc_tracker,
58:                                             const G1Predictions* predictor);
```

**Line 55: G1Policy类定义深度解析**

**类继承关系：**
```
G1Policy : CHeapObj<mtGC> : AllStatic
    |           |
    |           └─ 内存分配追踪（NMT）
    └─ GC策略决策中心
```

**G1Policy核心职责：**
```
+------------------------------------------------------------------+
|                    G1Policy 核心职责                              |
+------------------------------------------------------------------+
|                                                                   |
|  1. CSet选择 (Collection Set Selection)                           |
|     └─ finalize_collection_set() - 确定每次GC回收哪些Region        |
|                                                                   |
|  2. 暂停时间预测 (Pause Time Prediction)                          |
|     └─ 预测GC各阶段耗时，确保不超过MaxGCPauseMillis                |
|                                                                   |
|  3. IHOP控制 (Initiating Heap Occupancy Percent)                  |
|     └─ 决定何时启动并发标记周期                                    |
|                                                                   |
|  4. 年轻代大小调整 (Young Gen Sizing)                             |
|     └─ 动态调整Eden/Survivor大小                                   |
|                                                                   |
|  5. Mixed GC决策 (Mixed GC Decision)                              |
|     └─ 决定何时开始/结束空间回收阶段                               |
+------------------------------------------------------------------+
```

**Line 57-58: IHOP控制创建**

```cpp
static G1IHOPControl* create_ihop_control(...);
```

**IHOP（Initiating Heap Occupancy Percent）概念：**
```
+------------------------------------------------------------------+
|                    IHOP 机制                                      |
+------------------------------------------------------------------+
|                                                                   |
|  目的：在堆内存耗尽前启动并发标记                                    |
|                                                                   |
|  触发条件：                                                        |
|  老年代占用 > IHOP阈值（默认45%）                                  │
|                                                                   |
|  为什么需要IHOP？                                                  │
|  ┌─────────────────────────────────────────────────────────┐     |
|  │  如果没有IHOP：                                          │     |
|  │  1. 应用持续分配对象                                      │     |
|  │  2. 老年代逐渐填满                                        │     |
|  │  3. 直到分配失败才触发Full GC                             │     |
|  │  4. 导致长时间STW暂停                                     │     |
|  │                                                          │     |
|  │  有了IHOP：                                              │     |
|  │  1. 老年代占用达45%                                       │     |
|  │  2. 触发并发标记（与应用并发执行）                          │     |
|  │  3. 标记完成时知道哪些对象是垃圾                           │     |
|  │  4. Mixed GC回收垃圾，避免Full GC                          │     |
|  └─────────────────────────────────────────────────────────┘     |
+------------------------------------------------------------------+
```

---

### 1.2 预测与分析组件

```cpp
66:   G1Predictions _predictor;
67:   G1Analytics* _analytics;
68:   G1RemSetTrackingPolicy _remset_tracker;
69:   G1MMUTracker* _mmu_tracker;
```

**Line 66-69: 四大分析组件**

| 组件 | 职责 | 关键算法 |
|------|------|----------|
| `G1Predictions` | 预测GC各阶段耗时 | 衰减平均、线性回归 |
| `G1Analytics` | 维护历史统计数据 | 滑动窗口平均 |
| `G1RemSetTrackingPolicy` | RSet跟踪策略 | 动态更新阈值 |
| `G1MMUTracker` | MMU（最小 mutator 利用率）跟踪 | 保证应用运行时间比例 |

**G1Predictions预测模型：**
```cpp
class G1Predictions {
public:
    // 基于历史数据预测下次GC耗时
    double predict_time(size_t num_bytes, double* history_data);
    
    // 使用衰减平均：新预测 = alpha * 旧预测 + (1-alpha) * 实际值
    static const double Alpha = 0.7;  // 衰减系数
};
```

**面试高频问题Q&A：**

**Q1: G1的预测模型为什么使用衰减平均而不是简单平均？**
```
A: 衰减平均的优势：

简单平均问题：
- 所有历史数据权重相同
- 很久之前的数据影响当前预测
- 不能快速适应应用行为变化

衰减平均优势：
- 最近的数据权重更高
- 旧数据影响逐渐减小
- 公式：新预测 = 0.7 * 旧预测 + 0.3 * 实际值
- 能快速适应应用负载变化

示例：
时间  实际值  简单平均(5次)  衰减平均
T1    100ms      100ms         100ms
T2    110ms      105ms         103ms  (0.7*100 + 0.3*110)
T3    90ms       100ms         96ms   (0.7*103 + 0.3*90)
T4    200ms      125ms         127ms  (0.7*96 + 0.3*200)

当T4突然增加到200ms时：
- 简单平均：125ms（低估）
- 衰减平均：127ms（更准确）
```

---

### 1.3 年轻代大小相关字段

```cpp
82:   uint _young_list_target_length;
83:   uint _young_list_fixed_length;
84:   uint _young_list_max_length;
```

**Line 82-84: 年轻代Region数量控制**

```
+------------------------------------------------------------------+
|                    年轻代大小三层控制                             |
+------------------------------------------------------------------+
|                                                                   |
|  _young_list_target_length                                        |
|  └─ 目标Eden Region数量                                           │
|     根据暂停时间目标动态计算                                        │
|     公式：target = pause_time / time_per_region                   │
|                                                                   |
|  _young_list_fixed_length                                         |
|  └─ 固定Eden大小（-XX:NewSize设置时）                              │
|     如果设置，则target_length = fixed_length                      │
|                                                                   |
|  _young_list_max_length                                           |
|  └─ Eden最大Region数量                                            │
|     防止GCLocker期间Eden无限增长                                    │
|     通常 = target_length * 2                                      │
+------------------------------------------------------------------+
```

---

## 第2章: finalize_collection_set - CSet选择核心 (Lines 1191-1194)

### 2.1 CSet选择入口

```cpp
1191: void G1Policy::finalize_collection_set(double target_pause_time_ms, G1SurvivorRegions* survivor) {
1192:   double time_remaining_ms = _collection_set->finalize_young_part(target_pause_time_ms, survivor);
1193:   _collection_set->finalize_old_part(time_remaining_ms);
1194: }
```

**Line 1191-1194: CSet选择两阶段**

**调用上下文：**
```
do_collection_pause_at_safepoint()
  └─ g1_policy()->finalize_collection_set(target_pause_time_ms, &_survivor)
       └─ 1. finalize_young_part() - 确定年轻代CSet
       └─ 2. finalize_old_part() - 确定老年代CSet（Mixed GC）
```

**CSet选择目标：**
```
+------------------------------------------------------------------+
|                    CSet选择优化目标                               |
+------------------------------------------------------------------+
|                                                                   |
|  约束条件：                                                        |
|  1. 总暂停时间 <= target_pause_time_ms（默认200ms）                │
|  2. Eden Region必须全部回收（强制）                                │
|                                                                   |
|  优化目标：                                                        |
|  Maximize: 回收的垃圾量 / 暂停时间                                  │
|                                                                   |
|  即：在有限时间内回收最多垃圾                                       │
+------------------------------------------------------------------+
```

---

### 2.2 finalize_young_part - 年轻代CSet确定

```cpp
// g1CollectionSet.cpp
double G1CollectionSet::finalize_young_part(double target_pause_time_ms, G1SurvivorRegions* survivor) {
    // 1. 添加所有Eden Region到CSet
    uint eden_count = _eden_region_length;
    
    // 2. 预测Eden回收时间
    double eden_time_ms = predict_eden_copy_time_ms(eden_count);
    
    // 3. 计算剩余时间
    double time_remaining_ms = target_pause_time_ms - eden_time_ms;
    
    // 4. 添加Survivor Region（如果有时间）
    uint survivor_count = 0;
    if (time_remaining_ms > 0) {
        survivor_count = add_survivor_regions_to_cset(time_remaining_ms);
    }
    
    return time_remaining_ms;
}
```

**Eden时间预测：**
```cpp
double predict_eden_copy_time_ms(uint eden_count) {
    // 基于历史数据预测
    // 考虑因素：
    // - Eden Region数量
    // - 对象存活率（通过SurvRateGroup统计）
    // - 复制速度（bytes/ms）
    
    size_t total_bytes = eden_count * HeapRegion::GrainBytes;
    double survival_ratio = _surv_rate_group->predict_survival_ratio();
    size_t bytes_to_copy = total_bytes * survival_ratio;
    
    return bytes_to_copy / _analytics->predict_copy_speed();
}
```

---

### 2.3 finalize_old_part - 老年代CSet确定（Mixed GC）

```cpp
// g1CollectionSet.cpp
void G1CollectionSet::finalize_old_part(double time_remaining_ms) {
    if (!collector_state()->in_mixed_phase()) {
        return;  // 不是Mixed GC，不选老年代Region
    }
    
    // 1. 从CSet Chooser获取候选Region（按回收效率排序）
    CollectionSetChooser* chooser = _cset_chooser;
    
    // 2. 在时间预算内选择Region
    while (time_remaining_ms > 0 && chooser->has_more_regions()) {
        HeapRegion* region = chooser->get_next_best_region();
        
        // 预测处理这个Region的耗时
        double region_time_ms = predict_region_time_ms(region);
        
        if (region_time_ms <= time_remaining_ms) {
            // 加入CSet
            add_old_region(region);
            time_remaining_ms -= region_time_ms;
        } else {
            // 时间不够，停止添加
            break;
        }
    }
}
```

**回收效率计算：**
```cpp
double calc_collection_efficiency(HeapRegion* region) {
    // 效率 = 可回收字节数 / 预计处理时间
    size_t reclaimable_bytes = region->reclaimable_bytes();
    double predicted_time_ms = predict_region_time_ms(region);
    
    return reclaimable_bytes / predicted_time_ms;
}
```

**面试高频问题Q&A：**

**Q2: Mixed GC如何选择老年代Region？为什么选择"回收效率"最高的？**
```
A: 贪心算法选择：

场景：时间预算100ms，有3个候选Region

Region  垃圾量   处理时间   回收效率
A       100MB    50ms      2MB/ms
B       80MB     20ms      4MB/ms  ← 最高
C       60MB     30ms      2MB/ms

选择顺序：
1. 选B（效率4MB/ms），剩余时间80ms
2. 选A（效率2MB/ms），剩余时间30ms
3. 选C需要30ms，刚好用完

总回收：240MB

如果按垃圾量选择（A->B->C）：
1. 选A（100MB），剩余50ms
2. 选B需要20ms，剩余30ms
3. 选C需要30ms，刚好用完

结果相同，但效率优先更稳健

极端情况：
Region D: 1000MB垃圾，需要200ms（效率5MB/ms）
如果选D，超时！只能回收1000MB
如果按时间选B+A+C，回收240MB但不超过时限
```

---

## 第3章: CollectionSetChooser - 老年代Region排序

### 3.1 CSet选择器数据结构

```cpp
class CollectionSetChooser {
private:
    // 按回收效率排序的Region数组
    GrowableArray<HeapRegion*> _regions;
    
    // 当前选择位置
    uint _curr_index;
    
public:
    // 添加标记完成的Region
    void add_region(HeapRegion* region);
    
    // 获取下一个最佳Region
    HeapRegion* get_next_best_region();
    
    // 按回收效率排序
    void sort_by_efficiency();
};
```

### 3.2 Region排序算法

```cpp
void CollectionSetChooser::sort_by_efficiency() {
    // 使用快速排序，按回收效率降序
    _regions.sort([&](HeapRegion* a, HeapRegion* b) {
        double eff_a = calc_collection_efficiency(a);
        double eff_b = calc_collection_efficiency(b);
        return eff_a > eff_b;  // 降序
    });
}
```

**排序时机：**
```
1. 并发标记完成后（Remark阶段）
2. 所有标记的Old Region加入Chooser
3. 按回收效率排序
4. 后续Mixed GC按此顺序选择
```

---

## 第4章: IHOP控制与并发标记触发 (Lines 1153-1189)

### 4.1 老年代CSet长度计算

```cpp
1153: uint G1Policy::calc_min_old_cset_length() const {
1154:   // The min old CSet region bound is based on the maximum desired
1155:   // number of mixed GCs after a cycle.
1156:   // 即使某些老年代Region回收效率低，也要保证在指定次数的Mixed GC内回收完
1157:   
1164:   const size_t region_num = (size_t) cset_chooser()->length();
1165:   const size_t gc_num = (size_t) MAX2(G1MixedGCCountTarget, (uintx) 1);
1166:   size_t result = region_num / gc_num;
1167:   // emulate ceiling
1168:   if (result * gc_num < region_num) {
1169:     result += 1;
1170:   }
1171:   return (uint) result;
1172: }
```

**Line 1153-1172: 最小老年代CSet长度计算**

**G1MixedGCCountTarget参数：**
```
-XX:G1MixedGCCountTarget=8（默认）

含义：希望在8次Mixed GC内回收完所有标记的老年代Region

计算示例：
- 标记了100个老年代Region
- 目标8次Mixed GC
- 每次至少选 100/8 = 13个Region（向上取整）

目的：防止Mixed GC拖太久，快速回收垃圾
```

### 4.2 最大老年代CSet长度限制

```cpp
1174: uint G1Policy::calc_max_old_cset_length() const {
1175:   // The max old CSet region bound is based on the threshold expressed
1176:   // as a percentage of the heap size.
1177:   
1181:   const G1CollectedHeap* g1h = G1CollectedHeap::heap();
1182:   const size_t region_num = g1h->num_regions();
1183:   const size_t perc = (size_t) G1OldCSetRegionThresholdPercent;
1184:   size_t result = region_num * perc / 100;
1185:   // emulate ceiling
1186:   if (100 * result < region_num * perc) {
1187:     result += 1;
1188:   }
1189:   return (uint) result;
1189: }
```

**Line 1174-1189: 最大老年代CSet长度计算**

**G1OldCSetRegionThresholdPercent参数：**
```
-XX:G1OldCSetRegionThresholdPercent=10（默认）

含义：老年代CSet最多占堆Region总数的10%

计算示例（8GB堆）：
- 总Region数：2048
- 最大老年代CSet：2048 * 10% = 205个Region
- 约820MB

目的：防止单次Mixed GC回收太多老年代Region，导致暂停时间过长
```

---

## 第5章: 预测模型详解

### 5.1 衰减平均实现

```cpp
// g1Predictions.hpp
class G1Predictions {
public:
    // 更新预测值
    static double update_prediction(double old_prediction, double new_value) {
        const double Alpha = 0.70;  // 衰减系数
        return Alpha * old_prediction + (1 - Alpha) * new_value;
    }
};
```

**衰减平均特性：**
```
Alpha = 0.7 的含义：
- 旧预测占70%权重
- 新实际值占30%权重

收敛速度：
- 约经过10次GC，旧数据影响降到5%以下
- 能快速适应应用行为变化

对比不同Alpha：
Alpha=0.9: 变化慢，稳定但滞后
Alpha=0.5: 变化快，敏感但波动大
Alpha=0.7: 平衡（G1选择）
```

### 5.2 各阶段耗时预测

```cpp
class G1Analytics {
public:
    // 根扫描时间预测
    double predict_root_scan_time_ms();
    
    // RSet更新时间预测
    double predict_update_rs_time_ms(size_t pending_cards);
    
    // RSet扫描时间预测
    double predict_scan_rs_time_ms(size_t rs_length);
    
    // 对象复制时间预测
    double predict_object_copy_time_ms(size_t bytes_to_copy);
    
    // 其他时间预测
    double predict_other_time_ms();
};
```

**预测公式示例：**
```cpp
double predict_scan_rs_time_ms(size_t rs_length) {
    // 线性模型：时间 = 基础时间 + 每卡处理时间 * 卡数量
    double base_time_ms = _rs_scan_base_time_ms;
    double time_per_card_ms = _rs_scan_time_per_card_ms;
    
    return base_time_ms + time_per_card_ms * rs_length;
}
```

---

## G1Policy与CSet选择总结

```
+==================================================================+
|              G1Policy 核心决策流程                                |
+==================================================================+
|                                                                   |
|  1. 年轻代大小决策                                                |
|     └─ 根据暂停目标计算Eden目标大小                                |
|        _young_list_target_length = f(pause_time_target)           |
|                                                                   |
|  2. IHOP决策                                                      |
|     └─ 老年代占用 > 45% 触发并发标记                               |
|        _ihop_control->update_ihop_prediction()                    |
|                                                                   |
|  3. CSet选择（GC时）                                              |
|     ├─ finalize_young_part()                                      |
|     │   ├─ 添加所有Eden Region                                    |
|     │   └─ 预测耗时，计算剩余时间                                  |
|     └─ finalize_old_part()（Mixed GC）                            |
|         ├─ 从Chooser获取候选Region                                |
|         ├─ 按回收效率排序                                         |
|         └─ 在剩余时间内选择Region                                  |
|                                                                   |
|  4. Mixed GC控制                                                  |
|     ├─ calc_min_old_cset_length() - 保证回收进度                   |
|     └─ calc_max_old_cset_length() - 限制暂停时间                   |
|                                                                   |
|  5. 预测模型更新                                                  |
|     └─ 每次GC后更新各阶段耗时预测                                  |
|        _analytics->update_predictions(actual_times)               |
|                                                                   |
+==================================================================+
```

---

**GDB调试脚本：**

```bash
# verify_g1_policy.gdb
set pagination off

break G1Policy::finalize_collection_set
break G1CollectionSet::finalize_young_part
break G1CollectionSet::finalize_old_part

run -Xms8g -Xmx8g -XX:+UseG1GC -XX:+PrintGCDetails

# 查看CSet组成
p _collection_set->_eden_region_length
p _collection_set->_survivor_region_length
p _collection_set->_old_region_length

# 查看预测值
p _analytics->_rs_scan_time_per_card_ms
p _analytics->_object_copy_time_per_byte_ms

# 查看IHOP
p _ihop_control->_current_ihop

continue
quit
```

---

**文档完成**

本文档完成了G1Policy与CollectionSet的逐行深度分析，涵盖：
- G1Policy类结构与核心字段
- finalize_collection_set两阶段选择
- CollectionSetChooser老年代Region排序
- IHOP控制与Mixed GC决策
- 衰减平均预测模型

下一章将分析：**并发标记（Concurrent Mark）** - Initial Mark到Remark到Cleanup的完整流程
