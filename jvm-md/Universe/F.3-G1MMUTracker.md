# F.3 G1MMUTracker - MMU 追踪器深度分析

> 源码位置：`g1MMUTracker.hpp`、`g1MMUTracker.cpp`
> MMU = Minimum Mutator Utilisation（最小应用运行比例）

---

## 1. 功能定位

### 一句话说明
**G1MMUTracker 追踪历史 GC 暂停，确保在任意时间窗口内，应用程序运行时间不低于 MMU 目标**。

### MMU 的定义

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          MMU 概念详解                                     │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Mutator Utilisation（应用利用率）                                        │
│  ─────────────────────────────────────────────────────────────────────   │
│  对于给定的时间窗口 ts：                                                  │
│                                                                          │
│      Mutator Utilisation = 应用运行时间 / ts                             │
│                          = (ts - GC暂停时间) / ts                        │
│                          = 1 - (GC暂停时间 / ts)                         │
│                                                                          │
│  Minimum Mutator Utilisation（最小应用利用率）                            │
│  ─────────────────────────────────────────────────────────────────────   │
│  所有可能时间窗口中，最差的利用率                                         │
│                                                                          │
│      MMU = min(所有窗口的 Mutator Utilisation)                           │
│                                                                          │
│  示例：                                                                  │
│  ─────────────────────────────────────────────────────────────────────   │
│  时间窗口 = 201ms                                                        │
│  最大 GC 时间 = 200ms                                                    │
│                                                                          │
│      MMU = 1 - (200 / 201) ≈ 0.005 (0.5%)                               │
│                                                                          │
│  含义：在任意 201ms 窗口内，应用至少能运行 1ms（0.5%）                    │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 为什么 G1 的 MMU 约束很宽松？

```
GCPauseIntervalMillis = MaxGCPauseMillis + 1 = 201ms

这意味着：
• 时间窗口 = 201ms
• 允许 GC = 200ms
• 应用最少运行 = 1ms

为什么设计这么宽松？
─────────────────────────────────────────────────────────────────────────
1. 给 G1 最大灵活性
   - 如果窗口太小，可能无法完成一次完整 GC
   - G1 的目标是单次暂停 ≤ 200ms，而不是严格的 MMU

2. G1 实际上靠预测控制暂停时间
   - G1Policy 预测 GC 耗时
   - 动态调整年轻代大小
   - MMUTracker 只是辅助检查

3. 真正的约束是 MaxGCPauseMillis
   - 用户关心的是单次暂停时间
   - MMU 只是理论上的保障
```

---

## 2. 类结构

### 2.1 类继承关系

```
G1MMUTracker（抽象基类）
│
│  • _time_slice：时间窗口（秒）
│  • _max_gc_time：最大 GC 时间（秒）
│  • when_sec()：计算何时可以 GC
│
└── G1MMUTrackerQueue（队列实现）
    │
    │  • _array[64]：暂停记录循环队列
    │  • _head_index, _tail_index：队头队尾
    │  • _no_entries：当前记录数
    │
    ├── add_pause()：记录一次 GC 暂停
    ├── when_sec()：计算何时可以再次 GC
    └── calculate_gc_time()：计算窗口内总 GC 时间
```

### 2.2 数据结构

```cpp
// 暂停记录元素
class G1MMUTrackerQueueElem {
    double _start_time;  // 暂停开始时间（秒）
    double _end_time;    // 暂停结束时间（秒）
    
    double duration() { return _end_time - _start_time; }
};

// 队列实现
class G1MMUTrackerQueue : public G1MMUTracker {
    enum { QueueLength = 64 };  // 最多记录 64 次暂停
    
    G1MMUTrackerQueueElem _array[64];  // 循环队列
    int _head_index;  // 最新记录位置
    int _tail_index;  // 最老记录位置
    int _no_entries;  // 当前记录数
};
```

---

## 3. 核心算法

### 3.1 add_pause() - 记录 GC 暂停

```cpp
// g1MMUTracker.cpp:78-113
void G1MMUTrackerQueue::add_pause(double start, double end) {
    // 1. 移除过期记录（超出时间窗口的）
    remove_expired_entries(end);
    
    // 2. 处理队列满的情况
    if (_no_entries == QueueLength) {
        // 队列满了，覆盖最老的记录
        // 这可能暂时违反 MMU，但实际很少发生
        _head_index = trim_index(_head_index + 1);
        _tail_index = trim_index(_tail_index + 1);
    } else {
        _head_index = trim_index(_head_index + 1);
        ++_no_entries;
    }
    
    // 3. 添加新记录
    _array[_head_index] = G1MMUTrackerQueueElem(start, end);
    
    // 4. 计算当前窗口内的 GC 总时间
    double slice_time = calculate_gc_time(end);
    
    // 5. 如果超过限制，打印警告日志
    if (slice_time >= _max_gc_time) {
        log_info(gc, mmu)("MMU target violated: %.1lfms (%.1lfms/%.1lfms)",
                          slice_time * 1000.0, 
                          _max_gc_time * 1000.0, 
                          _time_slice * 1000);
    }
}
```

### 3.2 calculate_gc_time() - 计算窗口内 GC 时间

```cpp
// g1MMUTracker.cpp:62-76
double G1MMUTrackerQueue::calculate_gc_time(double current_time) {
    double gc_time = 0.0;
    double limit = current_time - _time_slice;  // 窗口起始时间
    
    for (int i = 0; i < _no_entries; ++i) {
        G1MMUTrackerQueueElem *elem = &_array[trim_index(_tail_index + i)];
        
        if (elem->end_time() > limit) {
            // 这次暂停在窗口内
            if (elem->start_time() > limit) {
                // 完全在窗口内
                gc_time += elem->duration();
            } else {
                // 部分在窗口内（起始在窗口外）
                gc_time += elem->end_time() - limit;
            }
        }
    }
    return gc_time;
}
```

```
图解 calculate_gc_time()：

时间轴：
──────────────────────────────────────────────────────────────────────────
      |←─────────── time_slice (201ms) ───────────→|
      limit                                    current_time
      ↓                                             ↓
──────┼──────────────────────────────────────────────┼─────────────────────
      │                                              │
      │   [GC1]        [GC2]       [GC3]            │
      │   ├──┤         ├──┤        ├──┤             │
      │                                              │
──────┼──────────────────────────────────────────────┼─────────────────────

GC1: 完全在窗口内 → gc_time += duration
GC2: 完全在窗口内 → gc_time += duration
GC3: 完全在窗口内 → gc_time += duration

特殊情况：
──────┼──────────────────────────────────────────────┼─────────────────────
   [GC0]                                             │
   ├──────┤                                          │
      ↑                                              │
      limit                                          │

GC0: 部分在窗口内 → gc_time += (end_time - limit)
```

### 3.3 when_sec() - 计算何时可以 GC

```cpp
// g1MMUTracker.cpp:115-140
double G1MMUTrackerQueue::when_sec(double current_time, double pause_time) {
    // 1. 限制 pause_time 不超过最大值
    double adjusted_pause_time = min(pause_time, max_gc_time());
    
    // 2. 计算假设现在开始 GC 的结束时间
    double earliest_end = current_time + adjusted_pause_time;
    
    // 3. 计算这个时间点的窗口内总 GC 时间
    double gc_time = calculate_gc_time(earliest_end);
    
    // 4. 计算超出多少
    double diff = gc_time + adjusted_pause_time - max_gc_time();
    
    // 5. 如果没超出，可以立即 GC
    if (diff <= 0) return 0.0;
    
    // 6. 否则，计算需要等多久
    // 需要等到某些旧的 GC 记录"滑出"窗口
    // ... 复杂计算 ...
}
```

---

## 4. GDB 验证 ✅

### 4.1 GDB 验证结果

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
断点位置：g1Policy.cpp:71（G1Policy 构造后）

========== G1MMUTrackerQueue 验证 ==========
_mmu_tracker = 0x7ffff003a240

========== 核心参数 ==========
_mmu_tracker->_time_slice = 0.201000 sec ✅ (时间窗口 201ms)
_mmu_tracker->_max_gc_time = 0.200000 sec ✅ (最大GC时间 200ms)

========== 队列状态 ==========
_head_index = 0
_tail_index = 1
_no_entries = 0 ✅ (初始为空)
QueueLength = 64 (最大容量)

========== JVM 参数验证 ==========
GCPauseIntervalMillis = 201 ms ✅
MaxGCPauseMillis = 200 ms ✅
```

### 4.2 验证总结

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    G1MMUTracker GDB 验证结果                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  核心参数                                                                │
│  ──────────────────────────────────────────────────────────────────────  │
│  _time_slice      0.201 sec (201ms) ✅                                   │
│  _max_gc_time     0.200 sec (200ms) ✅                                   │
│                                                                          │
│  MMU 计算                                                                │
│  ──────────────────────────────────────────────────────────────────────  │
│  MMU = 1 - (200/201) ≈ 0.5%                                              │
│  含义：任意 201ms 内，应用至少运行 1ms                                   │
│                                                                          │
│  队列状态（初始）                                                        │
│  ──────────────────────────────────────────────────────────────────────  │
│  _no_entries = 0（空队列）                                               │
│  QueueLength = 64（最多记录 64 次暂停）                                  │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 5. 工作流程图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      G1MMUTracker 工作流程                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  GC 开始前                                                               │
│  ─────────────────────────────────────────────────────────────────────   │
│                                                                          │
│  1. G1Policy 计划进行 GC                                                 │
│     │                                                                    │
│     ▼                                                                    │
│  2. 调用 mmu_tracker->when_sec(now, predicted_pause)                    │
│     │                                                                    │
│     ├── 返回 0：可以立即 GC                                              │
│     │                                                                    │
│     └── 返回 > 0：需要等待 X 秒                                          │
│                   （等旧的 GC 记录滑出窗口）                              │
│                                                                          │
│  GC 结束后                                                               │
│  ─────────────────────────────────────────────────────────────────────   │
│                                                                          │
│  3. GC 完成，记录本次暂停                                                │
│     │                                                                    │
│     ▼                                                                    │
│  4. mmu_tracker->add_pause(start_time, end_time)                        │
│     │                                                                    │
│     ├── 移除过期记录                                                     │
│     ├── 添加新记录到循环队列                                             │
│     └── 检查是否违反 MMU                                                 │
│         │                                                                │
│         └── 如果违反，打印警告日志：                                     │
│             "MMU target violated: 250.0ms (200.0ms/201.0ms)"            │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 6. 日志输出示例

### 6.1 启用 MMU 日志

```bash
java -Xms8g -Xmx8g -XX:+UseG1GC -Xlog:gc,gc+mmu=debug ...
```

### 6.2 日志示例

```
[gc,mmu] MMU target violated: 250.0ms (200.0ms/201.0ms)
         │                    │        │        │
         │                    │        │        └── 时间窗口
         │                    │        └── 最大允许 GC 时间
         │                    └── 实际 GC 时间
         └── 超过目标！
```

---

## 7. 为什么 G1 的 MMU 约束如此宽松？

```
┌─────────────────────────────────────────────────────────────────────────┐
│                  G1 MMU 设计哲学                                          │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  问题：为什么 GCPauseIntervalMillis = MaxGCPauseMillis + 1？             │
│                                                                          │
│  答案：G1 的真正目标是控制单次暂停时间，而不是严格的 MMU                  │
│                                                                          │
│  ─────────────────────────────────────────────────────────────────────   │
│                                                                          │
│  传统 MMU 约束（假设 MMU=50%，窗口=400ms）                                │
│  ───────────────────────────────────────                                 │
│  • 400ms 窗口内，GC 最多占 200ms                                         │
│  • 可能是 1 次 200ms，或 2 次 100ms，或 4 次 50ms                        │
│  • 约束很严格，但用户不一定关心                                          │
│                                                                          │
│  G1 的方式（MMU≈0.5%，窗口=201ms）                                       │
│  ───────────────────────────────────                                     │
│  • 201ms 窗口内，GC 最多占 200ms                                         │
│  • 实际上只约束：不能连续 GC 超过 200ms                                  │
│  • 用户真正关心的是：每次暂停 ≤ 200ms                                    │
│                                                                          │
│  G1 的核心是预测，不是 MMU                                               │
│  ───────────────────────────────────                                     │
│  • G1Analytics 收集历史数据                                              │
│  • G1Predictions 预测 GC 耗时                                            │
│  • G1Policy 调整年轻代大小                                               │
│  • 目标：每次 GC 预测耗时 ≤ 200ms                                        │
│                                                                          │
│  MMUTracker 只是"保险"                                                   │
│  ───────────────────────────────────                                     │
│  • 极端情况下的检查                                                      │
│  • 打印警告日志                                                          │
│  • 不会主动阻止 GC                                                       │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 8. 总结

### 8.1 G1MMUTracker 是什么？

```
G1MMUTracker = 循环队列 + 时间窗口计算

• 记录最近 64 次 GC 暂停
• 计算任意时间窗口内的 GC 总时间
• 检查是否违反 MMU 约束
• 打印警告日志
```

### 8.2 关键数值

| 参数 | 值 | 说明 |
|------|-----|------|
| _time_slice | 0.201 sec | 时间窗口（GCPauseIntervalMillis） |
| _max_gc_time | 0.200 sec | 最大 GC 时间（MaxGCPauseMillis） |
| QueueLength | 64 | 最多记录 64 次暂停 |
| MMU | 0.5% | 最小应用运行比例 |

### 8.3 核心方法

| 方法 | 作用 |
|------|------|
| add_pause(start, end) | 记录一次 GC 暂停 |
| when_sec(time, pause) | 计算何时可以 GC |
| calculate_gc_time(time) | 计算窗口内总 GC 时间 |

---

## 待分析节点更新

| 节点 | 主题 | 状态 |
|------|------|------|
| B.1.1 | ParallelGCThreads 计算算法 | ✅ |
| F.1 | G1Predictions 预测器 | ✅ |
| E.5.1 | RefToScanQueue 工作窃取队列 | ✅ |
| D.4.1 | G1Policy 构造函数 | ✅ |
| F.2 | G1Analytics 分析器 | ✅ |
| **F.3** | **G1MMUTracker** | **✅** |
