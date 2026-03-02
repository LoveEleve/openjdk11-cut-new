# D.4.2 G1CollectionSet 详解

> **分析条件**：8GB 堆（-Xms8g -Xmx8g），G1 GC，4MB Region
> **源码位置**：`g1CollectedHeap.cpp:1451` / `g1CollectionSet.cpp`

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **D.4.2 G1CollectionSet 详解**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 概述

**Collection Set (CSet)** 是 G1 GC 中待回收 Region 的集合。G1 的核心优势之一就是**可预测的暂停时间**，而 CSet 的构建是实现这一目标的关键。

```cpp
// g1CollectedHeap.cpp:1451
_collection_set(this, _g1_policy),
```

---

## 1. 数据结构

### G1CollectionSet 类

```cpp
// g1CollectionSet.hpp:39
class G1CollectionSet {
  G1CollectedHeap* _g1h;              // G1 堆引用
  G1Policy* _policy;                   // 策略引用
  
  CollectionSetChooser* _cset_chooser; // 老年代 Region 选择器
  
  // Region 数量统计
  uint _eden_region_length;            // Eden Region 数
  uint _survivor_region_length;        // Survivor Region 数
  uint _old_region_length;             // Old Region 数
  
  // CSet 数组（Region 索引）
  uint* _collection_set_regions;       // Region 索引数组
  volatile size_t _collection_set_cur_length;  // 当前长度
  size_t _collection_set_max_length;           // 最大长度
  
  // 统计信息
  size_t _bytes_used_before;           // GC 前已用字节
  size_t _recorded_rs_lengths;         // 记录的 RSet 长度
  
  // 增量构建状态
  enum CSetBuildType { Active, Inactive };
  CSetBuildType _inc_build_state;
  
  // 增量构建统计
  size_t _inc_bytes_used_before;
  size_t _inc_recorded_rs_lengths;
  ssize_t _inc_recorded_rs_lengths_diffs;      // RSet 长度差异
  double _inc_predicted_elapsed_time_ms;       // 预测耗时
  double _inc_predicted_elapsed_time_ms_diffs; // 预测耗时差异
};
```

### 构造函数

```cpp
// g1CollectionSet.cpp:53
G1CollectionSet::G1CollectionSet(G1CollectedHeap* g1h, G1Policy* policy) :
  _g1h(g1h),
  _policy(policy),
  _cset_chooser(new CollectionSetChooser()),  // 创建选择器
  _eden_region_length(0),
  _survivor_region_length(0),
  _old_region_length(0),
  _bytes_used_before(0),
  _recorded_rs_lengths(0),
  _collection_set_regions(NULL),              // 延迟分配
  _collection_set_cur_length(0),
  _collection_set_max_length(0),
  // Incremental CSet attributes
  _inc_build_state(Inactive),                 // 初始为非活跃
  _inc_bytes_used_before(0),
  _inc_recorded_rs_lengths(0),
  _inc_recorded_rs_lengths_diffs(0),
  _inc_predicted_elapsed_time_ms(0.0),
  _inc_predicted_elapsed_time_ms_diffs(0.0) {
}
```

---

## 2. CSet 构建流程

### 2.1 增量构建（Young GC）

G1 采用**增量构建**策略，在应用运行期间逐步构建 Young CSet：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      增量构建 Young CSet                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  应用运行期间（Mutator 阶段）                                                 │
│  ┌────────────────────────────────────────────────────────────────────┐     │
│  │                                                                    │     │
│  │  分配 Eden Region → add_eden_region(hr)                           │     │
│  │       │                                                           │     │
│  │       └─→ 更新 _inc_bytes_used_before                             │     │
│  │       └─→ 更新 _inc_recorded_rs_lengths                           │     │
│  │       └─→ 更新 _inc_predicted_elapsed_time_ms                     │     │
│  │                                                                    │     │
│  │  采样线程周期更新                                                   │     │
│  │       └─→ _inc_recorded_rs_lengths_diffs += 新增 RSet 条目        │     │
│  │       └─→ _inc_predicted_elapsed_time_ms_diffs += 增量预测        │     │
│  │                                                                    │     │
│  └────────────────────────────────────────────────────────────────────┘     │
│                              ↓                                               │
│  GC 开始时                                                                   │
│  ┌────────────────────────────────────────────────────────────────────┐     │
│  │  finalize_incremental_building()                                   │     │
│  │       │                                                           │     │
│  │       └─→ 合并增量：                                               │     │
│  │           _inc_recorded_rs_lengths += _inc_recorded_rs_lengths_diffs     │
│  │           _inc_predicted_elapsed_time_ms += _inc_..._diffs        │     │
│  │                                                                    │     │
│  │  finalize_young_part(target_pause_time_ms)                        │     │
│  │       │                                                           │     │
│  │       └─→ 确定最终 Eden + Survivor Region                         │     │
│  │       └─→ 检查是否满足暂停时间目标                                  │     │
│  └────────────────────────────────────────────────────────────────────┘     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Mixed GC 老年代选择

Mixed GC 时还需要选择老年代 Region：

```cpp
// 在 finalize_old_part() 中
void G1CollectionSet::finalize_old_part(double time_remaining_ms) {
  // 从 CollectionSetChooser 选择收益最高的老年代 Region
  while (time_remaining_ms > 0 && cset_chooser->has_more_regions()) {
    HeapRegion* hr = cset_chooser->pop_min_live_region();
    
    // 预测回收这个 Region 需要的时间
    double region_time_ms = predict_region_elapsed_time_ms(hr);
    
    if (region_time_ms <= time_remaining_ms) {
      add_old_region(hr);
      time_remaining_ms -= region_time_ms;
    } else {
      break;  // 超出预算，停止添加
    }
  }
}
```

---

## 3. CollectionSetChooser

**老年代 Region 的选择策略**：选择垃圾最多（收益最高）的 Region。

```cpp
// collectionSetChooser.hpp:31
class CollectionSetChooser: public CHeapObj<mtGC> {
  GrowableArray<HeapRegion*> _regions;  // 候选 Region 列表
  
  uint _front;                           // 下一个要处理的索引
  uint _end;                             // 最后一个索引
  
  size_t _region_live_threshold_bytes;   // 存活阈值（超过则不选）
  size_t _remaining_reclaimable_bytes;   // 可回收字节总量
};
```

**选择标准**：
1. **存活率低**：存活对象少，回收收益高
2. **RSet 小**：扫描开销低
3. **按回收效率排序**：垃圾多/RSet 小的优先

```
候选 Region 排序（按垃圾率降序）
┌──────────────────────────────────────────────────────────────────┐
│  Region  │ 存活率 │ 垃圾量 │ RSet 大小 │ 回收优先级              │
├──────────┼────────┼────────┼───────────┼─────────────────────────┤
│  R1      │  10%   │ 3.6MB  │   小      │  ★★★★★ 最高            │
│  R2      │  20%   │ 3.2MB  │   小      │  ★★★★                  │
│  R3      │  30%   │ 2.8MB  │   中      │  ★★★                   │
│  R4      │  60%   │ 1.6MB  │   大      │  ★★                    │
│  R5      │  85%   │ 0.6MB  │   大      │  ★ 可能不选             │
└──────────┴────────┴────────┴───────────┴─────────────────────────┘
```

---

## 4. CSet 与暂停时间目标

### 4.1 时间预算分配

```
MaxGCPauseMillis = 200ms
├── 固定开销 ≈ 10-20ms（根扫描、引用处理等）
├── Young CSet ≈ 预测时间（必须全部回收）
└── Old CSet ≈ 剩余时间（按预算选择）

示例：
  固定开销:     15ms
  Young CSet:  100ms (200 个 Eden + 20 个 Survivor)
  剩余预算:     85ms
  可选老年代:   ~40 个 Region（每个约 2ms）
```

### 4.2 预测模型

```cpp
// 预测回收一个 Region 的时间
double predict_region_elapsed_time_ms(HeapRegion* hr) {
  // 复制存活对象时间
  double copy_time = predict_bytes_to_copy(hr) * cost_per_byte;
  
  // 扫描 RSet 时间
  double scan_rs_time = hr->rem_set()->occupied() * cost_per_card;
  
  // 其他开销
  double other = ...;
  
  return copy_time + scan_rs_time + other;
}
```

---

## 5. 内存布局图

```
G1CollectionSet
┌────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│  _collection_set_regions (uint* 数组)                                       │
│  ┌────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬─────────────────┐     │
│  │ 15 │ 23 │ 45 │ 67 │ 89 │ 12 │ 34 │...│...│...│    未使用        │     │
│  └────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴─────────────────┘     │
│    ↑                     ↑              ↑           ↑                       │
│    │                     │              │           │                       │
│    Eden Regions          │         Old Regions      │                       │
│    (0 ~ eden_len-1)      │      (young_len ~ cur_len-1)                     │
│                          │                          │                       │
│                   Survivor Regions            _collection_set_max_length    │
│                (eden_len ~ young_len-1)                                     │
│                                                                             │
│  统计信息:                                                                   │
│  ├── _eden_region_length = 200                                              │
│  ├── _survivor_region_length = 20                                           │
│  ├── _old_region_length = 40                                                │
│  └── _collection_set_cur_length = 260                                       │
│                                                                             │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## 6. 🏭 生产环境实践

### 监控 CSet

```bash
# GC 日志
-Xlog:gc+ergo+cset=debug

# 输出示例
[gc,ergo,cset] CSet: 220 regions (200 eden, 20 survivor)
[gc,ergo,cset] CSet: added 40 old regions, time remaining: 15.3ms
[gc,ergo,cset] CSet chooser: 150 candidate regions, 320MB reclaimable
```

### 关键指标

| 指标 | 获取方式 | 正常范围 | 异常信号 |
|------|----------|----------|----------|
| Eden Region 数 | GC 日志 | 动态变化 | 过少（频繁 GC） |
| Old Region 数 | GC 日志 | Mixed GC 时 > 0 | 0（未选中老年代） |
| 预测 vs 实际暂停 | GC 日志 | 接近 | 差距大（预测不准） |

### 常见问题

| 问题 | 症状 | 解决方案 |
|------|------|----------|
| 暂停超时 | 实际 > MaxGCPauseMillis | 增大目标时间或减少存活对象 |
| Mixed GC 不触发 | 老年代持续增长 | 检查 IHOP 设置 |
| CSet 过小 | 回收不彻底 | 检查预测模型参数 |

### 调优参数

```bash
# 暂停时间目标（核心）
-XX:MaxGCPauseMillis=200

# Mixed GC 每次回收的老年代 Region 数量
-XX:G1MixedGCCountTarget=8    # 分 8 次回收

# 老年代占用比例阈值（触发 Mixed GC）
-XX:G1HeapWastePercent=5      # 5% 垃圾时停止

# 存活率阈值（超过则不加入 CSet）
-XX:G1MixedGCLiveThresholdPercent=85
```

---

## 7. 完整流程图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         G1 CSet 构建完整流程                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ① 应用运行期（增量构建 Young CSet）                                          │
│  ───────────────────────────────────────────                                │
│  每次分配 Eden Region:                                                       │
│    └─→ add_eden_region() → 更新增量统计                                      │
│                                                                              │
│  采样线程周期更新:                                                           │
│    └─→ 更新 RSet 长度差异和预测时间差异                                       │
│                                                                              │
│  ② GC 触发                                                                   │
│  ───────────────────────────────────────────                                │
│  finalize_incremental_building()                                            │
│    └─→ 合并增量统计                                                          │
│                                                                              │
│  ③ 确定 Young CSet                                                           │
│  ───────────────────────────────────────────                                │
│  finalize_young_part(target_pause_time_ms)                                  │
│    ├─→ 添加所有 Eden Region（必须）                                          │
│    ├─→ 添加所有 Survivor Region（必须）                                      │
│    └─→ 计算剩余时间预算                                                      │
│                                                                              │
│  ④ 确定 Old CSet（Mixed GC 时）                                              │
│  ───────────────────────────────────────────                                │
│  finalize_old_part(time_remaining_ms)                                       │
│    └─→ while (有预算 && 有候选) {                                            │
│           hr = cset_chooser.pop_min_live_region();                          │
│           if (预测时间 <= 剩余时间) {                                        │
│             add_old_region(hr);                                             │
│           }                                                                 │
│        }                                                                    │
│                                                                              │
│  ⑤ 执行疏散                                                                  │
│  ───────────────────────────────────────────                                │
│  遍历 CSet，复制存活对象到 Survivor/Old                                       │
│                                                                              │
│  ⑥ 清理                                                                      │
│  ───────────────────────────────────────────                                │
│  clear() → 重置 CSet，释放 Region                                            │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## GDB 验证脚本

```bash
# 文件：jvm-md/tmp-file/universe-init/gdb_cset.txt

b G1CollectionSet::G1CollectionSet
commands
  printf "\n=== D.4.2 G1CollectionSet 构造验证 ===\n"
  printf "  _g1h = %p\n", _g1h
  printf "  _policy = %p\n", _policy
  printf "  _cset_chooser = %p\n", _cset_chooser
  printf "  _inc_build_state = %d (0=Active, 1=Inactive)\n", _inc_build_state
  printf "  _collection_set_regions = %p\n", _collection_set_regions
  continue
end

# 验证 GC 时的 CSet 状态
b G1CollectionSet::finalize_young_part
commands
  printf "\n=== CSet finalize_young_part ===\n"
  printf "  target_pause_time_ms = %f\n", target_pause_time_ms
  printf "  _eden_region_length = %u\n", _eden_region_length
  printf "  _survivor_region_length = %u\n", _survivor_region_length
  printf "  _inc_predicted_elapsed_time_ms = %f\n", _inc_predicted_elapsed_time_ms
  continue
end

run
```

**预期输出**（构造时）：
```
=== D.4.2 G1CollectionSet 构造验证 ===
  _g1h = 0x7f...
  _policy = 0x7f...
  _cset_chooser = 0x7f...        # 已创建
  _inc_build_state = 1           # Inactive
  _collection_set_regions = 0x0  # 延迟分配
```

---

## 待分析节点更新

| 节点 | 主题 | 状态 |
|------|------|------|
| **D.4.2** | G1CollectionSet 初始化 | ✅ |
| - | 增量构建机制 | ✅ |
| - | CollectionSetChooser 选择策略 | ✅ |
| - | 暂停时间目标与预算分配 | ✅ |
