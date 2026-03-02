# G1MMUTracker：最小 Mutator 利用率追踪器

## 1. 概览：解决什么问题？

### 1.1 背景：暂停时间目标的定义

G1 GC 的核心目标之一是**控制暂停时间**。用户可以设置两个参数：

| 参数 | 默认值 | 含义 |
|------|--------|------|
| `MaxGCPauseMillis` | 200ms | 单次 GC 最大暂停时间目标 |
| `GCPauseIntervalMillis` | 0 | 时间间隔（0表示自动计算）|

### 1.2 MMU（Minimum Mutator Utilization）概念

**定义**：
```
Mutator Utilization（Mutator 利用率）=
  时间片内 Mutator 运行时间 / 时间片总时长
  = (时间片 - GC时间) / 时间片

MMU（最小 Mutator 利用率）=
  所有时间片中 Mutator 利用率的最小值
```

**目标**：
- 确保**最坏情况下** Mutator 仍能获得足够的运行时间
- 避免 GC 过于频繁，导致应用"卡死"

### 1.3 MMU 追踪器的作用

**G1MMUTracker 解决两个核心问题**：

1. **何时可以开始下一次 GC？**
   - 检查历史 GC 记录
   - 确保 MMU 约束不被违反

2. **当前时间片内还能做多少 GC？**
   - 计算剩余 GC 配额
   - 指导年轻代大小调整

```
┌────────────────────────────────────────────────────────────┐
│                    时间片示例（200ms）                      │
└────────────────────────────────────────────────────────────┘

时间轴：
     0ms     50ms    100ms   150ms   200ms
      │       │       │       │       │
      ├───────┼───────┼───────┼───────┤
      │ GC 1  │       │ GC 2  │       │
      │ 30ms  │       │ 20ms  │       │
      └───────┘       └───────┘       │
      └───────────────────────────────┘
                200ms 时间片

GC 时间 = 30ms + 20ms = 50ms
Mutator 时间 = 200ms - 50ms = 150ms
Mutator 利用率 = 150ms / 200ms = 75%

如果 MMU 目标 = 60%（即 GC 最多 40%）
  → 50ms < 80ms（200ms × 40%）→ 满足目标
```

---

## 2. 核心数据结构

### 2.1 继承层次

```
┌─────────────────────────────────────────────────────────┐
│                G1MMUTracker (抽象基类)                  │
│  - _time_slice: double        时间片长度（秒）         │
│  - _max_gc_time: double       时间片内最大GC时间（秒）│
│                                                         │
│  + add_pause(start, end)     记录暂停                  │
│  + when_sec(current, pause)  计算何时可以GC            │
└───────────────────────┬─────────────────────────────────┘
                        │ 继承
                        │
┌───────────────────────▼─────────────────────────────────┐
│               G1MMUTrackerQueue (队列实现)              │
│  - _array[64]: G1MMUTrackerQueueElem  环形队列          │
│  - _head_index: int                   队列头           │
│  - _tail_index: int                   队列尾           │
│  - _no_entries: int                   条目数           │
│                                                         │
│  + remove_expired_entries()    移除过期记录             │
│  + calculate_gc_time()         计算GC时间              │
└─────────────────────────────────────────────────────────┘
```

### 2.2 G1MMUTracker 基类

**源码位置**：`gc/g1/g1MMUTracker.hpp:50-82`

```cpp
class G1MMUTracker: public CHeapObj<mtGC> {
protected:
  double _time_slice;    // 时间片长度（秒）
  double _max_gc_time;   // 时间片内最大GC时间（秒）

public:
  G1MMUTracker(double time_slice, double max_gc_time);

  // 记录一次GC暂停
  virtual void add_pause(double start, double end) = 0;

  // 计算何时可以开始下一次GC
  // 返回：距离现在多少秒后可以开始GC
  virtual double when_sec(double current_time, double pause_time) = 0;

  // 获取最大GC时间
  double max_gc_time() const { return _max_gc_time; }

  // 检查现在是否可以做最大GC
  bool now_max_gc(double current_time) {
    return when_sec(current_time, max_gc_time()) < 0.00001;
  }

  // 计算何时可以做最大GC（秒）
  double when_max_gc_sec(double current_time) {
    return when_sec(current_time, max_gc_time());
  }

  // 计算何时可以做最大GC（毫秒）
  jlong when_max_gc_ms(double current_time) {
    double when = when_max_gc_sec(current_time);
    return (jlong)(when * 1000.0);
  }
};
```

### 2.3 G1MMUTrackerQueueElem

**源码位置**：`gc/g1/g1MMUTracker.hpp:84-103`

```cpp
class G1MMUTrackerQueueElem {
private:
  double _start_time;  // GC 开始时间（秒）
  double _end_time;    // GC 结束时间（秒）

public:
  double start_time() { return _start_time; }
  double end_time()   { return _end_time; }
  double duration()   { return _end_time - _start_time; }

  G1MMUTrackerQueueElem() : _start_time(0.0), _end_time(0.0) {}

  G1MMUTrackerQueueElem(double start_time, double end_time) {
    _start_time = start_time;
    _end_time = end_time;
  }
};
```

### 2.4 G1MMUTrackerQueue

**源码位置**：`gc/g1/g1MMUTracker.hpp:107-143`

```cpp
class G1MMUTrackerQueue: public G1MMUTracker {
private:
  enum PrivateConstants {
    QueueLength = 64  // 队列最大长度
  };

  // 环形队列：存储最近的GC暂停记录
  G1MMUTrackerQueueElem _array[QueueLength];
  int _head_index;      // 队列头（最新记录）
  int _tail_index;      // 队列尾（最老记录）
  int _no_entries;      // 当前记录数

  // 环形索引调整
  inline int trim_index(int index) {
    return (index + QueueLength) % QueueLength;
  }

  // 移除过期记录
  void remove_expired_entries(double current_time);

  // 计算时间片内的GC时间
  double calculate_gc_time(double current_time);

public:
  G1MMUTrackerQueue(double time_slice, double max_gc_time);

  void add_pause(double start, double end);
  double when_sec(double current_time, double pause_time);
};
```

**内存布局**：

```
G1MMUTrackerQueue 对象
┌────────────────────────────────────────────────────────┐
│ G1MMUTracker 基类字段                                  │
│  ├─ _time_slice: double (0.2 秒 = 200ms)              │
│  └─ _max_gc_time: double (0.08 秒 = 80ms)             │
├────────────────────────────────────────────────────────┤
│ G1MMUTrackerQueue 字段                                  │
│  ├─ _array[64]: G1MMUTrackerQueueElem                  │
│  │   每个元素 16 bytes（两个 double）                  │
│  │   总计 64 × 16 = 1024 bytes                         │
│  ├─ _head_index: int                                   │
│  ├─ _tail_index: int                                   │
│  └─ _no_entries: int                                   │
└────────────────────────────────────────────────────────┘

环形队列示意（QueueLength=64）：
┌────┬────┬────┬────┬────┬────┐
│ 0  │ 1  │ 2  │... │ 62 │ 63 │
└────┴────┴────┴────┴────┴────┘
  ▲                      ▲
  │                      │
_head                 _tail
(最新)                (最老)

添加新记录：
  _head = (_head + 1) % 64
  _array[_head] = new_entry

移除最老记录：
  _tail = (_tail + 1) % 64
```

---

## 3. 核心算法逐行分析

### 3.1 构造函数

**源码位置**：`gc/g1/g1MMUTracker.cpp:40-48`

```cpp
G1MMUTracker::G1MMUTracker(double time_slice, double max_gc_time) :
  _time_slice(time_slice),
  _max_gc_time(max_gc_time) { }

G1MMUTrackerQueue::G1MMUTrackerQueue(double time_slice, double max_gc_time) :
  G1MMUTracker(time_slice, max_gc_time),
  _head_index(0),
  _tail_index(trim_index(_head_index + 1)),  // tail = head + 1
  _no_entries(0) { }
```

**初始化示例**：

```
默认参数：
  MaxGCPauseMillis = 200ms
  GCPauseIntervalMillis = 0（自动计算）

计算：
  _time_slice = GCPauseIntervalMillis / 1000.0
             = 200ms / 1000 = 0.2 秒

  _max_gc_time = MaxGCPauseMillis / 1000.0
             = 200ms / 1000 = 0.2 秒？不对！

实际计算在 G1Policy 构造函数中：
  _mmu_tracker = new G1MMUTrackerQueue(
    GCPauseIntervalMillis / 1000.0,    // time_slice = 0.2s
    MaxGCPauseMillis / 1000.0          // max_gc_time = 0.2s
  );

含义：
  时间片 = 200ms
  最大GC时间 = 200ms（整个时间片都可以GC？）
  → 这不太合理，实际应该更小

实际生产环境：
  如果 MaxGCPauseMillis = 200ms
  则 max_gc_time 通常是 200ms
  time_slice 可能是更大的值（如 1000ms）
  → 这样 MMU 才有意义
```

### 3.2 add_pause()：记录GC暂停

**源码位置**：`gc/g1/g1MMUTracker.cpp:78-113`

```cpp
void G1MMUTrackerQueue::add_pause(double start, double end) {
  // 【Line 79】计算持续时间
  double duration = end - start;

  // 【Line 81】先移除过期记录
  remove_expired_entries(end);

  // 【Line 82-103】处理队列满的情况
  if (_no_entries == QueueLength) {
    // 【Line 82-99】队列已满，覆盖最老的记录
    // 这可能导致 MMU 计算不准确，但这是权衡之举
    _head_index = trim_index(_head_index + 1);
    assert(_head_index == _tail_index, "Because we have a full circular buffer");
    _tail_index = trim_index(_tail_index + 1);
  } else {
    // 【Line 100-103】队列未满，正常添加
    _head_index = trim_index(_head_index + 1);
    ++_no_entries;
  }

  // 【Line 104】添加新记录
  _array[_head_index] = G1MMUTrackerQueueElem(start, end);

  // 【Line 107-108】计算当前时间片的GC时间并报告
  double slice_time = calculate_gc_time(end);
  G1MMUTracer::report_mmu(_time_slice, slice_time, _max_gc_time);

  // 【Line 110-112】检查是否违反MMU目标
  if (slice_time >= _max_gc_time) {
    log_info(gc, mmu)("MMU target violated: %.1lfms (%.1lfms/%.1lfms)",
                      slice_time * 1000.0, _max_gc_time * 1000.0, _time_slice * 1000);
  }
}
```

### 3.3 remove_expired_entries()：移除过期记录

**源码位置**：`gc/g1/g1MMUTracker.cpp:50-60`

```cpp
void G1MMUTrackerQueue::remove_expired_entries(double current_time) {
  // 【Line 51】计算时间片下限
  // 只保留 [current_time - time_slice, current_time] 范围内的记录
  double limit = current_time - _time_slice;

  // 【Line 52-58】移除结束时间早于 limit 的记录
  while (_no_entries > 0) {
    if (is_double_geq(limit, _array[_tail_index].end_time())) {
      // 最老的记录已过期，移除
      _tail_index = trim_index(_tail_index + 1);
      --_no_entries;
    } else {
      // 最老的记录仍在时间片内，停止
      return;
    }
  }

  guarantee(_no_entries == 0, "should have no entries in the array");
}
```

**移除逻辑图示**：

```
假设：
  current_time = 10.0s
  time_slice = 0.2s
  limit = 9.8s

队列中的记录：
  _array[tail]: start=9.5s, end=9.6s → 已过期，移除
  _array[tail+1]: start=9.7s, end=9.9s → 部分在时间片内，保留
  _array[tail+2]: start=10.0s, end=10.1s → 在时间片内，保留

时间轴：
  9.5s   9.6s   9.7s   9.8s   9.9s   10.0s   10.1s
    │      │      │      │      │       │       │
    ├──────┤      │      │      │       │       │
    │过期  │      ├──────┤      │       │       │
    │      │      │保留  │      ├───────┤       │
    │      │      │      │      │ 保留  │       │
    └──────┴──────┴──────┴──────┴───────┴───────┘
                   ▲
                 limit
```

### 3.4 calculate_gc_time()：计算时间片内GC时间

**源码位置**：`gc/g1/g1MMUTracker.cpp:62-76`

```cpp
double G1MMUTrackerQueue::calculate_gc_time(double current_time) {
  double gc_time = 0.0;

  // 【Line 64】计算时间片下限
  double limit = current_time - _time_slice;

  // 【Line 65-74】遍历所有记录
  for (int i = 0; i < _no_entries; ++i) {
    int index = trim_index(_tail_index + i);
    G1MMUTrackerQueueElem *elem = &_array[index];

    // 【Line 68】只统计结束时间 > limit 的记录
    if (elem->end_time() > limit) {
      // 【Line 69-70】如果开始时间也 > limit，完全在时间片内
      if (elem->start_time() > limit) {
        gc_time += elem->duration();
      }
      // 【Line 71-72】如果开始时间 <= limit，部分在时间片内
      else {
        gc_time += elem->end_time() - limit;
      }
    }
  }
  return gc_time;
}
```

**计算示例**：

```
时间片：[9.8s, 10.0s]，宽度 0.2s

记录1：start=9.5s, end=9.6s
  → end_time (9.6s) <= limit (9.8s)
  → 不统计

记录2：start=9.7s, end=9.9s
  → end_time (9.9s) > limit (9.8s)
  → start_time (9.7s) <= limit (9.8s)
  → 部分在时间片内
  → gc_time += 9.9s - 9.8s = 0.1s

记录3：start=9.85s, end=10.0s
  → end_time (10.0s) > limit (9.8s)
  → start_time (9.85s) > limit (9.8s)
  → 完全在时间片内
  → gc_time += 10.0s - 9.85s = 0.15s

总 gc_time = 0.1s + 0.15s = 0.25s

如果 max_gc_time = 0.08s (80ms)
  → gc_time (250ms) > max_gc_time (80ms)
  → 违反 MMU 目标！
```

### 3.5 when_sec()：计算何时可以开始GC

**源码位置**：`gc/g1/g1MMUTracker.cpp:115-140`

```cpp
double G1MMUTrackerQueue::when_sec(double current_time, double pause_time) {
  // 【Line 117-118】如果请求的暂停超过最大值，截断
  double adjusted_pause_time =
    (pause_time > max_gc_time()) ? max_gc_time() : pause_time;

  // 【Line 119】假设现在开始GC，最早结束时间
  double earliest_end = current_time + adjusted_pause_time;

  // 【Line 120】计算时间片下限
  double limit = earliest_end - _time_slice;

  // 【Line 121】计算时间片内的GC时间
  double gc_time = calculate_gc_time(earliest_end);

  // 【Line 122】计算还需要多少时间"额度"
  // diff = 当前GC时间 + 新GC时间 - 最大允许GC时间
  double diff = gc_time + adjusted_pause_time - max_gc_time();

  // 【Line 123-124】如果 diff <= 0，说明现在就可以GC
  if (is_double_leq_0(diff))
    return 0.0;

  // 【Line 126-139】需要等待某些GC记录"过期"
  int index = _tail_index;
  while (1) {
    G1MMUTrackerQueueElem *elem = &_array[index];

    // 【Line 129-133】统计这个记录贡献的GC时间
    if (elem->end_time() > limit) {
      if (elem->start_time() > limit)
        diff -= elem->duration();
      else
        diff -= elem->end_time() - limit;

      // 【Line 134-135】如果 diff <= 0，找到了合适的等待时间
      if (is_double_leq_0(diff))
        return elem->end_time() + diff + _time_slice - adjusted_pause_time - current_time;
    }

    // 【Line 137-138】移动到下一个记录
    index = trim_index(index + 1);
    guarantee(index != trim_index(_head_index + 1), "should not go past head");
  }
}
```

**计算示例**：

```
当前状态：
  current_time = 10.0s
  time_slice = 0.2s (200ms)
  max_gc_time = 0.08s (80ms)

历史GC记录：
  GC1: start=9.85s, end=9.95s (duration=0.1s)
  GC2: start=9.98s, end=10.05s (duration=0.07s)

问题：何时可以开始一个 50ms 的新GC？

计算过程：
1. adjusted_pause_time = min(0.05s, 0.08s) = 0.05s

2. earliest_end = 10.0s + 0.05s = 10.05s

3. limit = 10.05s - 0.2s = 9.85s

4. gc_time = calculate_gc_time(10.05s)
   - GC1: end=9.95s > limit=9.85s, start=9.85s <= limit
     → gc_time += 9.95s - 9.85s = 0.1s
   - GC2: end=10.05s > limit=9.85s, start=9.98s > limit
     → gc_time += 0.07s
   - 总计 gc_time = 0.1s + 0.07s = 0.17s

5. diff = 0.17s + 0.05s - 0.08s = 0.14s > 0
   → 需要等待

6. 遍历记录，找到需要"过期"多少：
   - GC1 贡献 0.1s，diff = 0.14s - 0.1s = 0.04s > 0
   - GC2 贡献 0.07s，diff = 0.04s - 0.07s = -0.03s < 0
   → 在 GC2 过期后即可开始

7. 计算等待时间：
   return = GC2.end_time + diff + time_slice - adjusted_pause - current
          = 10.05s + (-0.03s) + 0.2s - 0.05s - 10.0s
          = 0.17s = 170ms

答案：170ms 后可以开始 50ms 的GC
```

---

## 4. 完整流程示例

### 4.1 初始化

```
G1Policy 构造函数：
  _mmu_tracker = new G1MMUTrackerQueue(
    GCPauseIntervalMillis / 1000.0,  // time_slice
    MaxGCPauseMillis / 1000.0        // max_gc_time
  );

假设默认参数：
  MaxGCPauseMillis = 200ms
  GCPauseIntervalMillis = 200ms（默认等于暂停目标）

结果：
  _time_slice = 0.2s
  _max_gc_time = 0.2s

问题：time_slice = max_gc_time = 200ms
  → 时间片内可以全是GC？
  → 这不合理！

实际生产环境通常设置：
  -XX:MaxGCPauseMillis=200
  -XX:GCPauseIntervalMillis=1000（1秒）

结果：
  _time_slice = 1.0s
  _max_gc_time = 0.2s
  → MMU = (1.0 - 0.2) / 1.0 = 80%
  → 合理！
```

### 4.2 第一次 GC

```
第一次 Young GC：
  start = 1.0s
  end = 1.15s
  duration = 0.15s

add_pause(1.0, 1.15):
  1. remove_expired_entries(1.15)
     - limit = 1.15 - 0.2 = 0.95s
     - _no_entries = 0，无需移除

  2. _no_entries < QueueLength，正常添加
     - _head_index = 1
     - _no_entries = 1
     - _array[1] = (1.0s, 1.15s)

  3. calculate_gc_time(1.15) = 0.15s

  4. 检查 MMU：
     - slice_time (0.15s) < max_gc_time (0.2s)
     - 满足目标
```

### 4.3 连续 GC 场景

```
时间轴：
  1.0s   1.15s  1.2s   1.35s  1.4s   1.55s
    │      │      │      │      │       │
    ├──────┤      ├──────┤      ├───────┤
    │ GC1  │      │ GC2  │      │ GC3   │
    │150ms │      │150ms │      │ 150ms │
    └──────┘      └──────┘      └───────┘

假设 time_slice = 0.4s, max_gc_time = 0.16s (160ms)

在 1.2s 时，尝试开始 GC2：
  current_time = 1.2s
  pause_time = 0.15s

  calculate_gc_time(1.2 + 0.15 = 1.35s):
    - limit = 1.35 - 0.4 = 0.95s
    - GC1: end=1.15s > limit, start=1.0s > limit
      → gc_time += 0.15s

  diff = 0.15s + 0.15s - 0.16s = 0.14s > 0
  → 需要等待

  遍历 GC1：
    diff = 0.14s - 0.15s = -0.01s < 0
    → 在 GC1 过期后即可

  when = GC1.end_time + diff + time_slice - pause - current
       = 1.15s + (-0.01s) + 0.4s - 0.15s - 1.2s
       = 0.19s = 190ms

答案：190ms 后可以开始 GC2
```

---

## 5. 在 G1Policy 中的使用

### 5.1 查询是否可以开始 GC

```cpp
// 在 G1CollectedHeap::do_collection_pause_at_safepoint() 中
bool should_do_gc = false;

if (g1_policy->force_initial_mark_if_outside_cycle(cause)) {
  should_do_gc = true;
} else {
  // 检查是否满足 MMU 约束
  double pause_time = g1_policy->max_pause_time_ms() / 1000.0;
  double when = g1_policy->mmu_tracker()->when_sec(current_time, pause_time);
  
  if (when <= 0.0) {
    should_do_gc = true;  // 现在就可以GC
  }
}
```

### 5.2 记录 GC 暂停

```cpp
void G1Policy::record_collection_pause_end(double pause_time_ms, ...) {
  // 计算暂停开始和结束时间
  double end_time_sec = os::elapsedTime();
  double start_time_sec = end_time_sec - pause_time_ms / 1000.0;

  // 记录到 MMU 追踪器
  _mmu_tracker->add_pause(start_time_sec, end_time_sec);
}
```

### 5.3 计算年轻代大小时考虑 MMU

```cpp
// 在 calculate_young_list_target_length() 中
double target_pause_time_ms = _mmu_tracker->max_gc_time() * 1000.0;

// 二分搜索年轻代大小，使得预测暂停时间 <= target_pause_time_ms
while (min_young_length < max_young_length) {
  uint young_length = (min_young_length + max_young_length) / 2;
  
  if (will_fit(young_length, target_pause_time_ms)) {
    min_young_length = young_length;
  } else {
    max_young_length = young_length;
  }
}
```

---

## 6. 数据流图

```
┌──────────────────────────────────────────────────────────────┐
│                   GC 开始                                     │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────────┐
        │  检查 MMU 约束                        │
        │  when_sec(current_time, pause_time)   │
        └───────────────────────────────────────┘
                            │
                ┌───────────┴───────────┐
                │ when <= 0             │ when > 0
                ▼                       ▼
        ┌───────────────┐       ┌───────────────────┐
        │ 现在开始 GC   │       │ 等待 when 秒后    │
        └───────────────┘       └───────────────────┘
                │
                ▼
        ┌───────────────────────────────────────┐
        │  GC 执行                              │
        │  - 记录开始时间                       │
        │  - 执行 GC                            │
        │  - 记录结束时间                       │
        └───────────────────────────────────────┘
                │
                ▼
        ┌───────────────────────────────────────┐
        │  add_pause(start, end)                │
        │  - 移除过期记录                       │
        │  - 添加新记录到队列                   │
        │  - 计算 GC 时间                       │
        │  - 检查是否违反 MMU                   │
        └───────────────────────────────────────┘
                │
                ▼
        ┌───────────────────────────────────────┐
        │  GC 时间 >= max_gc_time?              │
        │  - 是：打印警告 "MMU target violated" │
        │  - 否：正常                           │
        └───────────────────────────────────────┘
```

---

## 7. 参数影响分析

### 7.1 参数关系

```
用户设置：
  -XX:MaxGCPauseMillis=200
  -XX:GCPauseIntervalMillis=1000

计算：
  _time_slice = 1000ms / 1000 = 1.0s
  _max_gc_time = 200ms / 1000 = 0.2s

MMU 目标：
  MMU = (1.0s - 0.2s) / 1.0s = 80%

含义：
  - 任意 1 秒时间片内，GC 最多占用 200ms
  - 应用至少获得 800ms 运行时间
```

### 7.2 参数调优建议

| 场景 | MaxGCPauseMillis | GCPauseIntervalMillis | MMU |
|------|------------------|----------------------|-----|
| 低延迟应用 | 50ms | 200ms | 75% |
| 平衡应用 | 200ms | 1000ms | 80% |
| 高吞吐应用 | 500ms | 5000ms | 90% |

**注意事项**：
1. **time_slice 太小**：MMU 约束过于严格，GC 频率受限制
2. **max_gc_time 太小**：每次 GC 可用时间少，年轻代大小受限
3. **max_gc_time > time_slice**：不合理，相当于无约束

---

## 8. GDB 验证脚本

### 8.1 查看 MMU 追踪器状态

```bash
cat > /data/workspace/openjdk-cut-new/jvm-md/tmp-file/mmu/verify_mmu.gdb << 'EOF'
# 打印 MMU 追踪器状态
define print_mmu_tracker
  set $mmu = (G1MMUTrackerQueue*)$arg0
  printf "\n=== MMU Tracker ===\n"
  printf "Time slice: %.3f s (%.1f ms)\n", $mmu->_time_slice, $mmu->_time_slice * 1000.0
  printf "Max GC time: %.3f s (%.1f ms)\n", $mmu->_max_gc_time, $mmu->_max_gc_time * 1000.0
  printf "No entries: %d\n", $mmu->_no_entries
  printf "Head index: %d, Tail index: %d\n", $mmu->_head_index, $mmu->_tail_index

  if $mmu->_no_entries > 0
    printf "\nRecent GC pauses:\n"
    set $i = 0
    while $i < $mmu->_no_entries && $i < 5
      set $idx = ($mmu->_tail_index + $i) % 64
      set $elem = &$mmu->_array[$idx]
      printf "  GC %d: %.3f - %.3f (%.3f s)\n", $i, $elem->_start_time, $elem->_end_time, $elem->_end_time - $elem->_start_time
      set $i = $i + 1
    end
  end
end

break G1MMUTrackerQueue::add_pause

commands 1
  printf "\n=== Adding Pause ===\n"
  printf "Start: %.3f s\n", $arg0
  printf "End: %.3f s\n", $arg1
  printf "Duration: %.3f s\n", $arg1 - $arg0
  continue
end

run
EOF
```

### 8.2 追踪 when_sec 计算

```bash
cat > /data/workspace/openjdk-cut-new/jvm-md/tmp-file/mmu/trace_when.gdb << 'EOF'
break G1MMUTrackerQueue::when_sec

commands 1
  printf "\n=== Calculating When ===\n"
  printf "Current time: %.3f s\n", $arg0
  printf "Pause time: %.3f s\n", $arg1
  continue
end

run
EOF
```

### 8.3 查看 MMU 违规日志

```bash
cat > /data/workspace/openjdk-cut-new/jvm-md/tmp-file/mmu/check_violation.gdb << 'EOF'
break G1MMUTrackerQueue::add_pause

commands 1
  # 检查是否违规
  set $mmu = (G1MMUTrackerQueue*)this
  set $end = $arg1
  set $gc_time = $mmu->calculate_gc_time($end)

  if $gc_time >= $mmu->_max_gc_time
    printf "\n*** MMU VIOLATION ***\n"
    printf "GC time: %.3f s\n", $gc_time
    printf "Max GC time: %.3f s\n", $mmu->_max_gc_time
  end
  continue
end

run
EOF
```

---

## 9. 关键问题与解答

### Q1: 为什么需要 MMU 追踪器？

**A**:
- **防止 GC 窒息应用**：连续 GC 可能导致应用长时间无法运行
- **提供服务质量保证**：确保最坏情况下 Mutator 也能运行
- **自适应调节**：根据历史数据调整 GC 时机

### Q2: time_slice 和 max_gc_time 如何设置？

**A**:
```
推荐配置：
  -XX:MaxGCPauseMillis=200      # 单次 GC 目标
  -XX:GCPauseIntervalMillis=1000 # 1秒时间片

含义：
  - 每 1 秒内，GC 最多 200ms
  - MMU = 80%

如果不设置 GCPauseIntervalMillis：
  - 默认 = MaxGCPauseMillis
  - MMU 约束几乎无意义
```

### Q3: 队列长度 64 是否足够？

**A**:
- **通常足够**：G1 GC 通常不会在时间片内执行 64 次 GC
- **极端情况**：如果队列满，会丢弃最老记录，可能违反 MMU
- **生产环境**：很少遇到队列满的情况

### Q4: when_sec 返回负数怎么办？

**A**:
```cpp
double when = when_sec(current_time, pause_time);
if (when < 0.0) {
  // 已经可以开始 GC
  // 负数表示可以提前开始
}
```

实际上，`when_sec` 确保返回值 >= 0（通过 `is_double_leq_0` 检查）。

### Q5: MMU 如何影响年轻代大小？

**A**:
```
年轻代大小计算考虑 MMU：
  target_pause_time = _mmu_tracker->max_gc_time()

  young_size = max_size_satisfying(target_pause_time)

如果 MMU 约束紧：
  - target_pause_time 小
  - 年轻代大小受限
  - GC 更频繁但暂停短

如果 MMU 约束松：
  - target_pause_time 大
  - 年轻代可以更大
  - GC 不频繁但暂停可能长
```

---

## 10. 源码位置索引

| 文件 | 行号 | 内容 |
|------|------|------|
| `gc/g1/g1MMUTracker.hpp` | 50-82 | G1MMUTracker 基类定义 |
| `gc/g1/g1MMUTracker.hpp` | 84-103 | G1MMUTrackerQueueElem 类 |
| `gc/g1/g1MMUTracker.hpp` | 107-143 | G1MMUTrackerQueue 类 |
| `gc/g1/g1MMUTracker.cpp` | 40-48 | 构造函数 |
| `gc/g1/g1MMUTracker.cpp` | 50-60 | remove_expired_entries() |
| `gc/g1/g1MMUTracker.cpp` | 62-76 | calculate_gc_time() |
| `gc/g1/g1MMUTracker.cpp` | 78-113 | add_pause() |
| `gc/g1/g1MMUTracker.cpp` | 115-140 | when_sec() |

---

## 11. 总结

**G1MMUTracker 的核心思想**：
1. **历史追踪**：记录最近的 GC 暂停时间
2. **时间片约束**：在时间片内限制 GC 总时间
3. **预测计算**：根据历史数据预测何时可以开始 GC
4. **服务质量保证**：确保最坏情况下 Mutator 仍能运行

**核心公式**：
```
MMU = (time_slice - gc_time) / time_slice

when_sec = 最早可开始GC时间 - 当前时间
         = 某个GC记录过期时间 - (max_gc_time - 剩余GC时间)
```

**性能影响**：
- 合适的 MMU 参数避免 GC 窒息应用
- 过紧的 MMU 约束限制 GC 效率
- 过松的 MMU 约束可能导致应用卡顿
