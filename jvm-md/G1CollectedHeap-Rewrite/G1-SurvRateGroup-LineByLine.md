# SurvRateGroup：存活率预测组

## 1. 概览：解决什么问题？

### 1.1 背景：年轻代对象的存活率

G1 GC 的年轻代包含：
- **Eden Region**：新分配的对象
- **Survivor Region**：经历过一次或多次 GC 的对象

**关键问题**：
- GC 时，Eden/Survivor 中的对象有多少会存活？
- 存活率决定了：
  - 需要拷贝多少数据（影响 GC 暂停时间）
  - Survivor 区应该多大（影响对象晋升年龄）
  - 年轻代目标大小（影响 GC 频率）

### 1.2 存活率的特点

```
对象年龄与存活率的关系：

年龄 0 (Eden)     → 存活率 ~50%
年龄 1 (Survivor) → 存活率 ~40%
年龄 2 (Survivor) → 存活率 ~30%
年龄 3 (Survivor) → 存活率 ~20%
年龄 4+           → 存活率 <10%

规律：年龄越大，存活率越低（大部分对象生命周期很短）
```

### 1.3 SurvRateGroup 的角色

**G1Policy 使用两个 SurvRateGroup**：

```cpp
class G1Policy {
  SurvRateGroup* _short_lived_surv_rate_group;  // Eden Region
  SurvRateGroup* _survivor_surv_rate_group;     // Survivor Region
};
```

**每个 Region 的年龄**：
- **Eden Region**：年龄 = 当前 GC 次数 - 创建时的 GC 次数
- **Survivor Region**：年龄 = 在 Survivor 区经历的 GC 次数

**预测目标**：
1. **单年龄存活率**：年龄为 N 的 Region 的存活率
2. **累积存活率**：前 N 个最老 Region 的总存活率（用于计算年轻代总拷贝量）

---

## 2. 核心数据结构

### 2.1 SurvRateGroup 类定义

**源码位置**：`gc/g1/survRateGroup.hpp:32-89`

```cpp
class SurvRateGroup : public CHeapObj<mtGC> {
private:
  size_t  _stats_arrays_length;      // 数组长度
  double* _accum_surv_rate_pred;     // 累积存活率预测数组
  double  _last_pred;                // 最后一个预测值（用于外推）
  TruncatedSeq** _surv_rate_pred;    // 每个年龄的存活率序列数组

  int _all_regions_allocated;        // 总共分配的 Region 数
  size_t _region_num;                // 当前活跃 Region 数
  size_t _setup_seq_num;             // 设置时的序列数

public:
  // 核心方法
  void record_surviving_words(int age_in_group, size_t surv_words);
  void all_surviving_words_recorded(const G1Predictions& predictor, bool update_predictors);

  // 获取累积存活率预测
  double accum_surv_rate_pred(int age) const;

  // 获取指定年龄的序列
  TruncatedSeq* get_seq(size_t age) const;
};
```

### 2.2 内存布局

```
SurvRateGroup 对象 (假设 _stats_arrays_length = 5)
┌────────────────────────────────────────────────────────┐
│ _stats_arrays_length = 5                               │
│ _accum_surv_rate_pred ──┐                              │
│ _last_pred              │                              │
│ _surv_rate_pred ────┐   │                              │
│ _all_regions_allocated│                              │
│ _region_num          │   │                              │
│ _setup_seq_num       │   │                              │
└──────────────────────┼───┼──────────────────────────────┘
                       │   │
         ┌─────────────┘   └──────────┐
         │                            │
         ▼                            ▼
   _surv_rate_pred[5]          _accum_surv_rate_pred[5]
   (TruncatedSeq* 数组)        (double 数组)
   ┌──────┐                    ┌─────────┐
   │ [0]  │──> TruncatedSeq    │ [0]: 0.5│ ← 年龄0的累积存活率
   ├──────┤                    ├─────────┤
   │ [1]  │──> TruncatedSeq    │ [1]: 0.9│ ← 年龄0+1的累积
   ├──────┤                    ├─────────┤
   │ [2]  │──> TruncatedSeq    │ [2]: 1.2│ ← 年龄0+1+2的累积
   ├──────┤                    ├─────────┤
   │ [3]  │──> TruncatedSeq    │ [3]: 1.4│
   ├──────┤                    ├─────────┤
   │ [4]  │──> TruncatedSeq    │ [4]: 1.5│
   └──────┘                    └─────────┘

每个 TruncatedSeq 存储：
  - 最近10次 GC 的该年龄存活率
  - 用于计算衰减平均和预测
```

**关键点**：
1. **_surv_rate_pred[i]**：存储年龄 i 的存活率历史序列
2. **_accum_surv_rate_pred[i]**：存储年龄 0 到 i 的累积存活率
3. **_last_pred**：最后一个有效预测值，用于外推超龄情况

---

## 3. 核心方法逐行分析

### 3.1 构造函数与初始化

**源码位置**：`gc/g1/survRateGroup.cpp:33-39`

```cpp
SurvRateGroup::SurvRateGroup() :
    _accum_surv_rate_pred(NULL),
    _surv_rate_pred(NULL),
    _stats_arrays_length(0) {
  reset();
  start_adding_regions();
}
```

### 3.2 reset()：重置状态

**源码位置**：`gc/g1/survRateGroup.cpp:41-66`

```cpp
void SurvRateGroup::reset() {
  // 【Line 42-46】初始化计数器
  _all_regions_allocated = 0;
  _setup_seq_num         = 0;
  _last_pred             = 0.0;
  _region_num            = 1;  // 临时设为1，触发数组分配

  // 【Line 51-54】删除旧的 TruncatedSeq 数组
  for (size_t i = 0; i < _stats_arrays_length; ++i) {
    delete _surv_rate_pred[i];
  }
  _stats_arrays_length = 0;

  // 【Line 56】停止添加 Region，触发数组分配
  stop_adding_regions();

  // 【Line 58-63】设置初始预测值
  guarantee(_stats_arrays_length == 1, "invariant");
  guarantee(_surv_rate_pred[0] != NULL, "invariant");

  // 初始存活率设为 0.4（经验值）
  const double initial_surv_rate = 0.4;
  _surv_rate_pred[0]->add(initial_surv_rate);
  _last_pred = _accum_surv_rate_pred[0] = initial_surv_rate;

  // 【Line 65】重置 Region 数量
  _region_num = 0;
}
```

**关键点**：
- **初始存活率 0.4**：经验值，表示刚创建的对象有 40% 存活率
- **保证数组长度至少为 1**：即使没有 Region，也能预测年龄 0 的存活率

### 3.3 start_adding_regions() / stop_adding_regions()

**源码位置**：`gc/g1/survRateGroup.cpp:68-84`

```cpp
void SurvRateGroup::start_adding_regions() {
  // 【Line 69】记录当前数组长度
  _setup_seq_num = _stats_arrays_length;

  // 【Line 70】重置 Region 计数
  _region_num = 0;
}

void SurvRateGroup::stop_adding_regions() {
  // 【Line 74】如果添加的 Region 数 > 当前数组长度，扩容
  if (_region_num > _stats_arrays_length) {
    // 【Line 75-76】重新分配数组
    _accum_surv_rate_pred = REALLOC_C_HEAP_ARRAY(double, _accum_surv_rate_pred, _region_num, mtGC);
    _surv_rate_pred = REALLOC_C_HEAP_ARRAY(TruncatedSeq*, _surv_rate_pred, _region_num, mtGC);

    // 【Line 78-80】为新位置创建 TruncatedSeq
    for (size_t i = _stats_arrays_length; i < _region_num; ++i) {
      _surv_rate_pred[i] = new TruncatedSeq(10);  // 容量10
    }

    // 【Line 82】更新数组长度
    _stats_arrays_length = _region_num;
  }
}
```

**扩容流程**：

```
初始状态：
  _stats_arrays_length = 1
  _region_num = 0

添加 Region 1, 2, 3：
  next_age_index() 返回 1, _region_num = 1
  next_age_index() 返回 2, _region_num = 2
  next_age_index() 返回 3, _region_num = 3

stop_adding_regions()：
  _region_num (3) > _stats_arrays_length (1)
  → 扩容到 3
  → 创建 _surv_rate_pred[1], _surv_rate_pred[2]
```

### 3.4 record_surviving_words()：记录存活数据

**源码位置**：`gc/g1/survRateGroup.cpp:86-92`

```cpp
void SurvRateGroup::record_surviving_words(int age_in_group, size_t surv_words) {
  guarantee(0 <= age_in_group && (size_t)age_in_group < _region_num,
            "pre-condition");

  // 【Line 90】计算存活率 = 存活字数 / Region 总字数
  double surv_rate = (double)surv_words / (double)HeapRegion::GrainWords;

  // 【Line 91】添加到对应年龄的序列
  _surv_rate_pred[age_in_group]->add(surv_rate);
}
```

**调用时机**：
```cpp
// GC 结束后，遍历 Survivor Region
for (HeapRegion* hr : survivor_regions) {
  int age = hr->age_in_surv_rate_group();
  size_t surv_words = hr->used() / HeapWordSize;

  // 记录存活数据
  hr->surv_rate_group()->record_surviving_words(age, surv_words);
}
```

**示例**：
```
Region A (年龄=2)：
  总大小：4MB = 1048576 words
  存活大小：1.2MB = 314572 words
  存活率 = 314572 / 1048576 = 0.3

  _surv_rate_pred[2]->add(0.3)
```

### 3.5 all_surviving_words_recorded()：更新预测

**源码位置**：`gc/g1/survRateGroup.cpp:94-99`

```cpp
void SurvRateGroup::all_surviving_words_recorded(const G1Predictions& predictor, bool update_predictors) {
  // 【Line 95-97】如果需要更新预测器，填充未记录的年龄
  if (update_predictors) {
    fill_in_last_surv_rates();
  }

  // 【Line 98】计算最终预测
  finalize_predictions(predictor);
}
```

### 3.6 fill_in_last_surv_rates()：填充缺失数据

**源码位置**：`gc/g1/survRateGroup.cpp:101-108`

```cpp
void SurvRateGroup::fill_in_last_surv_rates() {
  if (_region_num > 0) {
    // 【Line 103】获取最后一个有数据年龄的存活率
    double surv_rate = _surv_rate_pred[_region_num - 1]->last();

    // 【Line 104-106】填充超出当前年龄范围的位置
    for (size_t i = _region_num; i < _stats_arrays_length; ++i) {
      _surv_rate_pred[i]->add(surv_rate);
    }
  }
}
```

**为什么需要填充？**

```
假设：
  _region_num = 3  （当前有 3 个 Region）
  _stats_arrays_length = 5  （数组长度 5）

年龄分布：
  _surv_rate_pred[0]：有数据
  _surv_rate_pred[1]：有数据
  _surv_rate_pred[2]：有数据
  _surv_rate_pred[3]：无数据 ← 需要填充
  _surv_rate_pred[4]：无数据 ← 需要填充

填充策略：
  用年龄 2 的最后一个存活率填充年龄 3、4
```

### 3.7 finalize_predictions()：计算累积预测

**源码位置**：`gc/g1/survRateGroup.cpp:110-120`

```cpp
void SurvRateGroup::finalize_predictions(const G1Predictions& predictor) {
  double accum = 0.0;  // 累积存活率
  double pred = 0.0;   // 当前年龄预测

  // 【Line 113-118】遍历所有年龄
  for (size_t i = 0; i < _stats_arrays_length; ++i) {
    // 【Line 114】使用预测器获取预测值（衰减平均）
    pred = predictor.get_new_prediction(_surv_rate_pred[i]);

    // 【Line 115】存活率不能超过 1.0
    if (pred > 1.0) pred = 1.0;

    // 【Line 116】累积
    accum += pred;

    // 【Line 117】存储累积存活率
    _accum_surv_rate_pred[i] = accum;
  }

  // 【Line 119】保存最后一个预测值（用于外推）
  _last_pred = pred;
}
```

**计算示例**：

```
假设预测结果：
  年龄 0：存活率 = 0.5
  年龄 1：存活率 = 0.4
  年龄 2：存活率 = 0.3
  年龄 3：存活率 = 0.2
  年龄 4：存活率 = 0.1

累积存活率计算：
  _accum_surv_rate_pred[0] = 0.5
  _accum_surv_rate_pred[1] = 0.5 + 0.4 = 0.9
  _accum_surv_rate_pred[2] = 0.9 + 0.3 = 1.2
  _accum_surv_rate_pred[3] = 1.2 + 0.2 = 1.4
  _accum_surv_rate_pred[4] = 1.4 + 0.1 = 1.5

含义：
  前 3 个 Region 的累积存活率 = 1.2 个 Region
  → GC 时需要拷贝约 1.2 个 Region 的数据
```

### 3.8 accum_surv_rate_pred()：获取累积预测

**源码位置**：`gc/g1/survRateGroup.hpp:55-63`

```cpp
double accum_surv_rate_pred(int age) const {
  assert(age >= 0, "must be");

  // 【Line 57-58】如果年龄在数组范围内，直接返回
  if ((size_t)age < _stats_arrays_length) {
    return _accum_surv_rate_pred[age];
  }
  // 【Line 59-61】超出范围，线性外推
  else {
    double diff = (double)(age - _stats_arrays_length + 1);
    return _accum_surv_rate_pred[_stats_arrays_length - 1] + diff * _last_pred;
  }
}
```

**外推示例**：

```
假设：
  _stats_arrays_length = 5
  _accum_surv_rate_pred[4] = 1.5
  _last_pred = 0.1

查询年龄 7 的累积存活率：
  diff = 7 - 5 + 1 = 3
  result = 1.5 + 3 * 0.1 = 1.8

含义：
  前 8 个 Region（年龄 0-7）的累积存活率 ≈ 1.8 个 Region
```

---

## 4. 在 G1Policy 中的使用

### 4.1 predict_yg_surv_rate()

**源码位置**：`gc/g1/g1Policy.cpp:846-854`

```cpp
double G1Policy::predict_yg_surv_rate(int age, SurvRateGroup* surv_rate_group) const {
  // 【Line 847】获取指定年龄的存活率序列
  TruncatedSeq* seq = surv_rate_group->get_seq(age);

  guarantee(seq->num() > 0, "There should be some young gen survivor samples available. Tried to access with age %d", age);

  // 【Line 849】使用预测器获取预测值
  double pred = _predictor.get_new_prediction(seq);

  // 【Line 850-852】存活率不能超过 1.0
  if (pred > 1.0) {
    pred = 1.0;
  }
  return pred;
}
```

### 4.2 accum_yg_surv_rate_pred()

**源码位置**：`gc/g1/g1Policy.cpp:856-858`

```cpp
double G1Policy::accum_yg_surv_rate_pred(int age) const {
  return _short_lived_surv_rate_group->accum_surv_rate_pred(age);
}
```

### 4.3 predict_bytes_to_copy()

**源码位置**：`gc/g1/g1Policy.cpp:874-885`

```cpp
size_t G1Policy::predict_bytes_to_copy(HeapRegion* hr) const {
  size_t bytes_to_copy;

  if (!hr->is_young()) {
    // 【Line 877】老年代：直接使用存活数据
    bytes_to_copy = hr->max_live_bytes();
  } else {
    // 【Line 879-882】年轻代：使用存活率预测
    assert(hr->age_in_surv_rate_group() != -1, "invariant");
    int age = hr->age_in_surv_rate_group();

    // 预测存活率
    double yg_surv_rate = predict_yg_surv_rate(age, hr->surv_rate_group());

    // 预测需要拷贝的字节数
    bytes_to_copy = (size_t)(hr->used() * yg_surv_rate);
  }
  return bytes_to_copy;
}
```

### 4.4 在年轻代大小计算中的使用

**源码位置**：`gc/g1/g1Policy.cpp:175` (在 G1YoungLengthPredictor::will_fit 中)

```cpp
// 预测累积存活率
const double accum_surv_rate = _policy->accum_yg_surv_rate_pred((int)young_length - 1);

// 预测需要拷贝的字节数
const size_t bytes_to_copy = (size_t)(accum_surv_rate * (double)HeapRegion::GrainBytes);

// 预测拷贝时间
const double copy_time_ms = _policy->analytics()->predict_object_copy_time_ms(bytes_to_copy, _during_cm);

// 预测总暂停时间
const double pause_time_ms = _base_time_ms + copy_time_ms + young_other_time_ms;

// 检查是否超过目标暂停时间
if (pause_time_ms > _target_pause_time_ms) {
  return false;
}
```

---

## 5. 完整流程示例

### 5.1 GC 开始时

```
1. start_adding_regions()
   - 记录当前数组长度
   - 重置 _region_num = 0

2. Region 被加入年轻代
   - hr->install_surv_rate_group(_short_lived_surv_rate_group)
   - age_index = surv_rate_group->next_age_index()
   - HeapRegion 记录自己的 age_index

3. stop_adding_regions()
   - 如果 _region_num > _stats_arrays_length
   - 扩容数组
   - 创建新的 TruncatedSeq
```

### 5.2 GC 结束时

```
1. 遍历 Survivor Region
   for each survivor_region:
     age = hr->age_in_surv_rate_group()
     surv_words = hr->used() / HeapWordSize
     surv_rate_group->record_surviving_words(age, surv_words)

2. all_surviving_words_recorded()
   - fill_in_last_surv_rates()
   - finalize_predictions()

3. 更新预测
   - 计算每个年龄的存活率预测
   - 计算累积存活率
```

### 5.3 预测年轻代大小时

```
1. 计算基础时间
   base_time = RSet更新时间 + RSet扫描时间 + 固定开销

2. 二分搜索年轻代大小
   for young_length in [min, max]:
     accum_surv_rate = accum_yg_surv_rate_pred(young_length - 1)
     bytes_to_copy = accum_surv_rate * RegionSize
     copy_time = predict_copy_time(bytes_to_copy)
     total_time = base_time + copy_time

     if total_time <= target_pause_time:
       min_young_length = young_length
     else:
       break

3. 返回最优年轻代大小
```

---

## 6. 数据流图

```
┌──────────────────────────────────────────────────────────────┐
│                    GC 结束时记录数据                         │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────────┐
        │  record_surviving_words(age, words)   │
        │  - 计算 surv_rate = words / RegionSize│
        │  - 添加到 _surv_rate_pred[age]        │
        └───────────────────────────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────────┐
        │  all_surviving_words_recorded()       │
        │  - fill_in_last_surv_rates()          │
        │  - finalize_predictions()             │
        └───────────────────────────────────────┘
                            │
        ┌───────────────────┴───────────────────┐
        │                                       │
        ▼                                       ▼
┌───────────────────┐                 ┌───────────────────┐
│ finalize_predictions│                │ fill_in_last_surv_rates│
│ for each age:      │                 │ for age > region_num:  │
│   pred = predict() │                 │   use last_surv_rate   │
│   accum += pred    │                 └───────────────────┘
│   store accum[i]   │
└───────────────────┘
        │
        ▼
┌──────────────────────────────────────────────────────────────┐
│                    数据已准备好供查询                        │
└──────────────────────────────────────────────────────────────┘
                            │
        ┌───────────────────┴───────────────────┐
        │                                       │
        ▼                                       ▼
┌───────────────────┐                 ┌───────────────────┐
│ predict_yg_surv_  │                 │ accum_yg_surv_    │
│ rate(age)         │                 │ rate_pred(age)    │
│ - 获取单个年龄    │                 │ - 获取累积存活率  │
│   的存活率预测    │                 │   (年龄0~age)     │
└───────────────────┘                 └───────────────────┘
        │                                       │
        └───────────────────┬───────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────────┐
        │     年轻代大小计算 / CSet 选择        │
        │  - predict_bytes_to_copy(hr)          │
        │  - calculate_young_list_target_length │
        └───────────────────────────────────────┘
```

---

## 7. 内存占用分析

### 7.1 单个 SurvRateGroup

```
假设最大年龄 = 15（MaxTenuringThreshold）

_surs_rate_pred[16]：
  - 16 个 TruncatedSeq 指针：16 * 8 = 128 bytes
  - 每个 TruncatedSeq：
    - 对象大小：~80 bytes
    - 内部数组 (capacity=10)：10 * 8 = 80 bytes
    - 总计：16 * (80 + 80) = 2560 bytes

_accum_surv_rate_pred[16]：
  - 16 个 double：16 * 8 = 128 bytes

SurvRateGroup 对象本身：~80 bytes

总计：128 + 2560 + 128 + 80 = ~2900 bytes ≈ 3 KB
```

### 7.2 两个 SurvRateGroup

```
_short_lived_surv_rate_group：~3 KB
_survivor_surv_rate_group：~3 KB

总计：~6 KB
```

---

## 8. GDB 验证脚本

### 8.1 查看存活率序列

```bash
cat > /data/workspace/openjdk-cut-new/jvm-md/tmp-file/survrate/verify_seq.gdb << 'EOF'
# 打印存活率序列
define print_surv_seq
  set $group = (SurvRateGroup*)$arg0
  printf "=== SurvRateGroup ===\n"
  printf "region_num: %d, array_length: %d\n", $group->_region_num, $group->_stats_arrays_length

  set $i = 0
  while $i < $group->_stats_arrays_length && $i < 10
    set $seq = $group->_surv_rate_pred[$i]
    printf "Age %d: num=%d, davg=%.3f, last=%.3f\n", \
           $i, $seq->_num, $seq->_davg, $seq->_last
    set $i = $i + 1
  end
end

# 打印累积存活率
define print_accum_surv
  set $group = (SurvRateGroup*)$arg0
  printf "=== Accumulated Survival Rate Predictions ===\n"

  set $i = 0
  while $i < $group->_stats_arrays_length && $i < 10
    printf "Age 0~%d: accum_surv_rate = %.3f\n", \
           $i, $group->_accum_surv_rate_pred[$i]
    set $i = $i + 1
  end
end

break G1Policy::record_collection_pause_end

commands 1
  printf "\n=== After GC ===\n"
  continue
end

run
EOF
```

### 8.2 追踪存活率记录

```bash
cat > /data/workspace/openjdk-cut-new/jvm-md/tmp-file/survrate/trace_record.gdb << 'EOF'
break SurvRateGroup::record_surviving_words

commands 1
  printf "\n=== Recording Surviving Words ===\n"
  printf "age_in_group: %d\n", $arg0
  printf "surv_words: %lu\n", $arg1
  printf "surv_rate: %.3f\n", (double)$arg1 / (double)1048576
  continue
end

run
EOF
```

### 8.3 查看预测更新

```bash
cat > /data/workspace/openjdk-cut-new/jvm-md/tmp-file/survrate/trace_finalize.gdb << 'EOF'
break SurvRateGroup::finalize_predictions

commands 1
  printf "\n=== Finalizing Predictions ===\n"
  continue
end

break SurvRateGroup::accum_surv_rate_pred

commands 2
  printf "\n=== Query Accum Survival Rate ===\n"
  printf "age: %d\n", $arg0
  continue
end

run
EOF
```

---

## 9. 关键问题与解答

### Q1: 为什么需要两个 SurvRateGroup？

**A**:
- **Eden Region**：使用 `_short_lived_surv_rate_group`
  - 对象刚创建，存活率较高（~40-50%）
  - 年龄 = GC 次数差

- **Survivor Region**：使用 `_survivor_surv_rate_group`
  - 对象已经历过 GC，存活率较低（~10-30%）
  - 年龄 = 在 Survivor 区的 GC 次数

分离追踪可以获得更准确的预测。

### Q2: 累积存活率为什么可能 > 1.0？

**A**:
累积存活率是**多个 Region 的存活率之和**：

```
年龄 0：存活率 0.5（50%）
年龄 1：存活率 0.4（40%）
年龄 2：存活率 0.3（30%）

累积存活率[2] = 0.5 + 0.4 + 0.3 = 1.2

含义：前 3 个 Region 的总存活量 ≈ 1.2 个 Region
```

### Q3: 为什么初始存活率是 0.4？

**A**:
- 经验值：大多数对象的首次 GC 存活率约为 40%
- 可配置：可以通过修改代码调整
- 保守估计：避免预测过低导致 Survivor 区溢出

### Q4: 如何处理超出数组范围的年龄？

**A**:
```cpp
// 线性外推
double diff = (double)(age - _stats_arrays_length + 1);
return _accum_surv_rate_pred[_stats_arrays_length - 1] + diff * _last_pred;
```

假设：
- 最大记录年龄 = 5
- 查询年龄 = 10
- 最后一个预测值 = 0.1

结果 = _accum_surv_rate_pred[4] + (10 - 5 + 1) * 0.1

### Q5: 存活率预测如何影响 GC？

**A**:
1. **年轻代大小**：
   - 累积存活率 → 拷贝量 → GC 时间
   - 调整年轻代大小使预测时间 ≤ 目标时间

2. **晋升年龄**：
   - 如果 Survivor 区存活率预测过高
   - 提前晋升到老年代

3. **CSet 选择**：
   - 预测每个 Region 的拷贝时间
   - 选择效率最高的 Region

---

## 10. 源码位置索引

| 文件 | 行号 | 内容 |
|------|------|------|
| `gc/g1/survRateGroup.hpp` | 32-89 | SurvRateGroup 类定义 |
| `gc/g1/survRateGroup.cpp` | 33-39 | 构造函数 |
| `gc/g1/survRateGroup.cpp` | 41-66 | reset() |
| `gc/g1/survRateGroup.cpp` | 68-84 | start/stop_adding_regions() |
| `gc/g1/survRateGroup.cpp` | 86-92 | record_surviving_words() |
| `gc/g1/survRateGroup.cpp` | 94-99 | all_surviving_words_recorded() |
| `gc/g1/survRateGroup.cpp` | 101-108 | fill_in_last_surv_rates() |
| `gc/g1/survRateGroup.cpp` | 110-120 | finalize_predictions() |
| `gc/g1/g1Policy.cpp` | 846-854 | predict_yg_surv_rate() |
| `gc/g1/g1Policy.cpp` | 856-858 | accum_yg_surv_rate_pred() |
| `gc/g1/g1Policy.cpp` | 874-885 | predict_bytes_to_copy() |

---

## 11. 总结

**SurvRateGroup 的核心思想**：
1. **按年龄追踪**：不同年龄的对象有不同的存活率
2. **历史预测**：使用衰减平均预测未来存活率
3. **累积计算**：预测多个 Region 的总存活量
4. **外推机制**：处理超出历史范围的情况

**性能特点**：
- **空间效率**：每个年龄只需一个 TruncatedSeq
- **访问效率**：O(1) 查询累积存活率
- **自适应**：根据实际数据自动调整预测

**应用场景**：
- 年轻代大小计算
- CSet 选择效率评估
- 晋升年龄决策
