# F.5 - SurvRateGroup 存活率统计

> **前置条件**：-Xms8G -Xmx8G，G1 GC，非大页，非 NUMA
> **前置知识**：F.1 G1Predictions 预测器，C.1.1 Region 大小

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **F.5 - SurvRateGroup 存活率统计**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 1. 概述

**SurvRateGroup** 用于统计和预测年轻代 Region 中对象的存活率（Survival Rate）。G1 根据存活率预测来：
- 估算 GC 时需要复制的字节数
- 预测 GC 暂停时间
- 动态调整年轻代大小

G1Policy 包含两个 SurvRateGroup：
- **_short_lived_surv_rate_group**：Eden Region 的存活率
- **_survivor_surv_rate_group**：Survivor Region 的存活率

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    存活率统计概念图                                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Eden Region (age=0)       Survivor Region (age=1,2,...)                   │
│  ┌─────────────────┐       ┌─────────────────┐                             │
│  │ ████████████    │  GC   │ ██████████      │                             │
│  │ 活对象 (40%)   │ ────▶ │ 活对象 (60%)   │                             │
│  │ ░░░░░░░░░░░░░░  │       │ ░░░░░░░░░░░░░░  │                             │
│  │ 死对象 (60%)    │       │ 死对象 (40%)    │                             │
│  └─────────────────┘       └─────────────────┘                             │
│                                                                             │
│  存活率 = 存活字节数 / Region 总字节数                                       │
│  初始假设：40%                                                              │
│  随 age 增加，存活率通常增加（老对象更可能存活）                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 类定义

```cpp
// survRateGroup.hpp:32-89
class SurvRateGroup : public CHeapObj<mtGC> {
private:
  size_t  _stats_arrays_length;     // 数组长度
  double* _accum_surv_rate_pred;    // 累积存活率预测数组
  double  _last_pred;               // 最后一个预测值
  TruncatedSeq** _surv_rate_pred;   // 存活率预测序列数组（每个 age 一个）

  int _all_regions_allocated;       // 已分配的 Region 总数
  size_t _region_num;               // 当前 Region 数量
  size_t _setup_seq_num;            // 设置时的序列号
  
public:
  SurvRateGroup();
  void reset();
  void start_adding_regions();
  void stop_adding_regions();
  void record_surviving_words(int age_in_group, size_t surv_words);
  void all_surviving_words_recorded(const G1Predictions& predictor, bool update_predictors);
  
  // 获取累积存活率预测
  double accum_surv_rate_pred(int age) const;
  
  // 获取指定 age 的 TruncatedSeq
  TruncatedSeq* get_seq(size_t age) const;
  
  // 获取下一个 age 索引
  int next_age_index();
  
  // 计算 Region 在组内的 age
  int age_in_group(int age_index) const;
};
```

---

## 3. 源码深度分析

### 3.1 构造函数

```cpp
// survRateGroup.cpp:33-39
SurvRateGroup::SurvRateGroup() :
    _accum_surv_rate_pred(NULL),
    _surv_rate_pred(NULL),
    _stats_arrays_length(0) {
  reset();                    // 重置状态
  start_adding_regions();     // 开始添加 Region
}
```

### 3.2 reset() - 重置并初始化

```cpp
// survRateGroup.cpp:41-66
void SurvRateGroup::reset() {
  _all_regions_allocated = 0;
  _setup_seq_num         = 0;
  _last_pred             = 0.0;
  _region_num            = 1;  // 初始长度为 1
  
  // 释放旧的 TruncatedSeq 数组
  for (size_t i = 0; i < _stats_arrays_length; ++i) {
    delete _surv_rate_pred[i];
  }
  _stats_arrays_length = 0;
  
  stop_adding_regions();  // 分配新数组
  
  // ===== 设置初始存活率 =====
  guarantee(_stats_arrays_length == 1, "invariant");
  guarantee(_surv_rate_pred[0] != NULL, "invariant");
  
  // 初始存活率假设：40%
  const double initial_surv_rate = 0.4;
  _surv_rate_pred[0]->add(initial_surv_rate);
  _last_pred = _accum_surv_rate_pred[0] = initial_surv_rate;
  
  _region_num = 0;
}
```

**关键点**：初始存活率假设为 **40%**

### 3.3 stop_adding_regions() - 动态扩展数组

```cpp
// survRateGroup.cpp:73-84
void SurvRateGroup::stop_adding_regions() {
  if (_region_num > _stats_arrays_length) {
    // 扩展累积存活率数组
    _accum_surv_rate_pred = REALLOC_C_HEAP_ARRAY(double, _accum_surv_rate_pred, 
                                                  _region_num, mtGC);
    // 扩展存活率序列数组
    _surv_rate_pred = REALLOC_C_HEAP_ARRAY(TruncatedSeq*, _surv_rate_pred, 
                                            _region_num, mtGC);
    
    // 为新增的 age 创建 TruncatedSeq（窗口大小 10）
    for (size_t i = _stats_arrays_length; i < _region_num; ++i) {
      _surv_rate_pred[i] = new TruncatedSeq(10);
    }
    
    _stats_arrays_length = _region_num;
  }
}
```

### 3.4 record_surviving_words() - 记录存活字数

```cpp
// survRateGroup.cpp:86-92
void SurvRateGroup::record_surviving_words(int age_in_group, size_t surv_words) {
  guarantee(0 <= age_in_group && (size_t)age_in_group < _region_num, "pre-condition");
  
  // 存活率 = 存活字数 / Region 总字数
  double surv_rate = (double)surv_words / (double)HeapRegion::GrainWords;
  // 8GB 堆：surv_rate = surv_words / 524288
  
  _surv_rate_pred[age_in_group]->add(surv_rate);
}
```

### 3.5 finalize_predictions() - 计算累积预测

```cpp
// survRateGroup.cpp:110-120
void SurvRateGroup::finalize_predictions(const G1Predictions& predictor) {
  double accum = 0.0;
  double pred = 0.0;
  
  for (size_t i = 0; i < _stats_arrays_length; ++i) {
    // 使用 G1Predictions 预测每个 age 的存活率
    pred = predictor.get_new_prediction(_surv_rate_pred[i]);
    if (pred > 1.0) pred = 1.0;  // 存活率不能超过 100%
    
    // 累积存活率
    accum += pred;
    _accum_surv_rate_pred[i] = accum;
  }
  _last_pred = pred;
}
```

### 3.6 accum_surv_rate_pred() - 获取累积存活率

```cpp
// survRateGroup.hpp:55-63
double accum_surv_rate_pred(int age) const {
  assert(age >= 0, "must be");
  if ((size_t)age < _stats_arrays_length)
    return _accum_surv_rate_pred[age];
  else {
    // 超出数组范围：线性外推
    double diff = (double)(age - _stats_arrays_length + 1);
    return _accum_surv_rate_pred[_stats_arrays_length-1] + diff * _last_pred;
  }
}
```

---

## 4. 数据结构图解

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    SurvRateGroup 数据结构                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  SurvRateGroup                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │ _stats_arrays_length = 5                                              │ │
│  │ _last_pred = 0.52                                                     │ │
│  │ _region_num = 5                                                       │ │
│  │ _all_regions_allocated = 10                                           │ │
│  │                                                                       │ │
│  │ _surv_rate_pred ─────────────────────────────────────────────┐        │ │
│  │ _accum_surv_rate_pred ───────────────────────────────────┐   │        │ │
│  └────────────────────────────────────────────────────────── │ ─ │ ───────┘ │
│                                                              │   │          │
│                                                              ▼   ▼          │
│  累积存活率数组 (double[5])           存活率序列数组 (TruncatedSeq*[5])     │
│  ┌─────┬─────┬─────┬─────┬─────┐    ┌─────┬─────┬─────┬─────┬─────┐      │
│  │ 0.40│ 0.85│ 1.32│ 1.81│ 2.33│    │ Seq │ Seq │ Seq │ Seq │ Seq │      │
│  │age=0│age=1│age=2│age=3│age=4│    │  0  │  1  │  2  │  3  │  4  │      │
│  └─────┴─────┴─────┴─────┴─────┘    └──┬──┴──┬──┴──┬──┴──┬──┴──┬──┘      │
│    │     │     │     │     │           │     │     │     │     │          │
│    │     │     │     │     │           ▼     ▼     ▼     ▼     ▼          │
│    │     │     │     │     │       TruncatedSeq (窗口=10)                 │
│    │     │     │     │     │       记录最近 10 次 GC 的存活率              │
│    │     │     │     │     │                                              │
│    ▼     ▼     ▼     ▼     ▼                                              │
│  0.40  0.45  0.47  0.49  0.52   ← 单个 age 的预测存活率                   │
│   │                                                                       │
│   └── 累积：0.40 + 0.45 + 0.47 + 0.49 + 0.52 = 2.33                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. 工作流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    SurvRateGroup 工作流程                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌───────────────────┐                                                     │
│  │ 1. 年轻代 GC 开始  │                                                     │
│  └─────────┬─────────┘                                                     │
│            │                                                               │
│            ▼                                                               │
│  ┌───────────────────────────────────────┐                                 │
│  │ 2. start_adding_regions()             │                                 │
│  │    _setup_seq_num = _stats_arrays_length                                │
│  │    _region_num = 0                                                      │
│  └─────────┬─────────────────────────────┘                                 │
│            │                                                               │
│            ▼                                                               │
│  ┌───────────────────────────────────────┐                                 │
│  │ 3. 为每个 Eden/Survivor Region        │                                 │
│  │    调用 next_age_index()              │                                 │
│  │    分配 age 索引                       │                                 │
│  └─────────┬─────────────────────────────┘                                 │
│            │                                                               │
│            ▼                                                               │
│  ┌───────────────────────────────────────┐                                 │
│  │ 4. GC 执行：扫描、复制存活对象          │                                 │
│  └─────────┬─────────────────────────────┘                                 │
│            │                                                               │
│            ▼                                                               │
│  ┌───────────────────────────────────────┐                                 │
│  │ 5. record_surviving_words()           │                                 │
│  │    记录每个 Region 的存活字数          │                                 │
│  │    surv_rate = surv_words / GrainWords │                                │
│  └─────────┬─────────────────────────────┘                                 │
│            │                                                               │
│            ▼                                                               │
│  ┌───────────────────────────────────────┐                                 │
│  │ 6. stop_adding_regions()              │                                 │
│  │    扩展数组（如果需要）                │                                 │
│  └─────────┬─────────────────────────────┘                                 │
│            │                                                               │
│            ▼                                                               │
│  ┌───────────────────────────────────────┐                                 │
│  │ 7. all_surviving_words_recorded()     │                                 │
│  │    → finalize_predictions()           │                                 │
│  │    计算累积存活率预测                  │                                 │
│  └───────────────────────────────────────┘                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 6. G1Policy 中的使用

### 6.1 两个 SurvRateGroup

```cpp
// g1Policy.cpp:58-59
_short_lived_surv_rate_group(new SurvRateGroup()),  // Eden
_survivor_surv_rate_group(new SurvRateGroup()),     // Survivor
```

### 6.2 关联到 Region

```cpp
// g1Policy.hpp:122-130
void set_region_eden(HeapRegion* hr) {
  hr->set_eden();
  hr->install_surv_rate_group(_short_lived_surv_rate_group);
}

void set_region_survivor(HeapRegion* hr) {
  assert(hr->is_survivor(), "pre-condition");
  hr->install_surv_rate_group(_survivor_surv_rate_group);
}
```

### 6.3 预测复制字节数

```cpp
// g1Policy.cpp:856-858
double G1Policy::accum_yg_surv_rate_pred(int age) const {
  return _short_lived_surv_rate_group->accum_surv_rate_pred(age);
}

// 使用示例：预测 N 个 Region 需要复制的字节数
// bytes_to_copy = accum_yg_surv_rate_pred(N) * GrainBytes
```

---

## 7. 累积存活率的含义

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    累积存活率示例                                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  假设有 5 个 Eden Region，每个的预测存活率：                                 │
│                                                                             │
│  age │ 存活率预测 │ 累积存活率 │ 含义                                       │
│  ────┼───────────┼───────────┼──────────────────────────────────────────   │
│   0  │   0.40    │   0.40    │ 1 个 Region 预计存活 0.40 × 4MB = 1.6MB     │
│   1  │   0.45    │   0.85    │ 2 个 Region 预计存活 0.85 × 4MB = 3.4MB     │
│   2  │   0.47    │   1.32    │ 3 个 Region 预计存活 1.32 × 4MB = 5.3MB     │
│   3  │   0.49    │   1.81    │ 4 个 Region 预计存活 1.81 × 4MB = 7.2MB     │
│   4  │   0.52    │   2.33    │ 5 个 Region 预计存活 2.33 × 4MB = 9.3MB     │
│                                                                             │
│  如果年轻代有 5 个 Eden Region (20MB)：                                     │
│  预计需要复制 9.3MB 数据到 Survivor/Old                                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 8. 初始假设值

```cpp
// survRateGroup.cpp:61
const double initial_surv_rate = 0.4;  // 40%
```

**为什么是 40%？**
- 经验值：大多数 Eden 对象是短命的
- 保守估计：比典型的 10-20% 高，留有余地
- 会被实际数据快速更新

---

## 9. GDB 验证

### 9.1 GDB 脚本

```gdb
# 文件：jvm-md/tmp-file/universe-init/gdb_survrategroup.txt

b g1Policy.cpp:62
commands
  silent
  printf "\n========== SurvRateGroup Creation ==========\n"
  
  # 检查两个 SurvRateGroup
  printf "----- Short-lived SurvRateGroup -----\n"
  printf "Address: %p\n", _short_lived_surv_rate_group
  printf "_stats_arrays_length: %lu\n", _short_lived_surv_rate_group->_stats_arrays_length
  printf "_region_num: %lu\n", _short_lived_surv_rate_group->_region_num
  printf "_last_pred: %f\n", _short_lived_surv_rate_group->_last_pred
  
  printf "\n----- Survivor SurvRateGroup -----\n"
  printf "Address: %p\n", _survivor_surv_rate_group
  printf "_stats_arrays_length: %lu\n", _survivor_surv_rate_group->_stats_arrays_length
  printf "_region_num: %lu\n", _survivor_surv_rate_group->_region_num
  printf "_last_pred: %f\n", _survivor_surv_rate_group->_last_pred
  
  # 验证初始存活率
  printf "\n----- Initial Survival Rate -----\n"
  printf "_accum_surv_rate_pred[0]: %f\n", _short_lived_surv_rate_group->_accum_surv_rate_pred[0]
  
  continue
end
run
```

### 9.2 预期输出

```
========== SurvRateGroup Creation ==========
----- Short-lived SurvRateGroup -----
Address: 0x7f...
_stats_arrays_length: 1                 ✅
_region_num: 0                          ✅
_last_pred: 0.400000                    ✅ (初始 40%)

----- Survivor SurvRateGroup -----
Address: 0x7f...
_stats_arrays_length: 1                 ✅
_region_num: 0                          ✅
_last_pred: 0.400000                    ✅

----- Initial Survival Rate -----
_accum_surv_rate_pred[0]: 0.400000      ✅ (初始 40%)
```

---

## 10. 总结

### 10.1 核心概念

| 概念 | 说明 |
|------|------|
| SurvRateGroup | 按 age 统计存活率的数据结构 |
| _short_lived_surv_rate_group | Eden Region 的存活率统计 |
| _survivor_surv_rate_group | Survivor Region 的存活率统计 |
| 初始存活率 | **40%** |
| TruncatedSeq 窗口 | **10** 次 GC |

### 10.2 计算公式

```
存活率 = 存活字数 / GrainWords
累积存活率 = Σ(各 age 的存活率预测)
预计复制字节数 = 累积存活率 × GrainBytes
```

### 10.3 设计要点

1. **按 age 分组**：不同 age 的 Region 有不同存活率
2. **动态扩展**：数组随年轻代 Region 数增长
3. **衰减平均**：使用 TruncatedSeq + G1Predictions 平滑预测
4. **累积存活率**：快速计算 N 个 Region 的总复制量

---

## 待分析节点更新

| 节点 | 主题 | 状态 |
|------|------|------|
| B.1.1 | ParallelGCThreads 计算算法 | ✅ |
| F.1 | G1Predictions 预测器 | ✅ |
| E.5.1 | RefToScanQueue 工作窃取队列 | ✅ |
| D.4.1 | G1Policy 构造函数 | ✅ |
| F.2 | G1Analytics 分析器 | ✅ |
| F.3 | G1MMUTracker | ✅ |
| F.4 | G1IHOPControl | ✅ |
| C.1.1 | Region 大小计算算法 | ✅ |
| C.2 | RemSet 大小计算 | ✅ |
| C.3 | initialize_alignments() | ✅ |
| E.1 | WorkGang 创建 | ✅ |
| E.4 | 巨型对象阈值 | ✅ |
| **F.5** | **SurvRateGroup 存活率统计** | **✅** |
