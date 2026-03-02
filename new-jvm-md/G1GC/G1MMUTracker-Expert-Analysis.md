# G1MMUTracker 专家级源码分析

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1MMUTracker 的本质是**GC 停顿时间的滑动窗口守门员**：维护最近 `GCPauseIntervalMillis`（默认 201ms）时间窗口内的 GC 停顿历史，计算"当前时刻可以执行多长时间的 GC 而不违反 MMU（Minimum Mutator Utilization）约束"；`G1Policy` 用这个值限制 GC 停顿时间。

### 0.2 为什么需要？

`-XX:MaxGCPauseMillis=200` 只限制单次 GC 停顿时间，但如果 GC 频繁发生，应用线程的实际运行时间可能远低于 80%（MMU）。G1MMUTracker 追踪时间窗口内的总 GC 时间，确保应用线程在任意 `GCPauseIntervalMillis` 时间窗口内的运行时间 ≥ `(1 - GCTimeRatio)%`。

### 0.3 怎么解决？

**滑动时间窗口 + 历史记录**：`G1MMUTracker` 维护一个环形缓冲区，记录最近的 GC 停顿（开始时间 + 持续时间）；`when_sec()` 计算"从当前时刻开始，执行多长时间的 GC 不会违反 MMU"；`add_pause()` 在 GC 完成后更新历史记录。

### 0.4 为什么这样设计？

- **为什么用滑动窗口而不是固定时间段？** 固定时间段（如每秒统计一次）会有边界效应（窗口切换时统计重置）；滑动窗口任意时刻都能准确反映最近的 GC 负担
- **为什么 `GCPauseIntervalMillis` 默认 201ms 而不是 200ms？** 比 `MaxGCPauseMillis`（200ms）多 1ms，确保在最坏情况下（连续 GC）应用线程至少有 1ms 的运行时间

---

## 一、一句话总结

**G1MMUTracker 是 G1 的垃圾回收暂停时间"守门员"，它通过维护一个滑动时间窗口内的 GC 历史记录，实时计算"何时可以执行下一次 GC"以及"可以执行多长时间"，确保应用程序在每个时间片内获得承诺的最小运行时间（MMU）。**

---

## 二、设计哲学：为什么要 MMU？

### 2.1 问题背景

G1 的核心承诺是**可预测的暂停时间**。但如果没有限制，可能会出现以下情况：

```
时间线：  0s    0.2s   0.4s   0.6s   0.8s   1.0s
         ├──────┼──────┼──────┼──────┼──────┤
GC:      ██████ ██████ ██████ ██████ ██████
App:                              ▔▔▔▔▔▔

问题：1秒内 GC 占用了 80%，应用只运行了 20%
```

### 2.2 MMU 定义

**Minimum Mutator Utilization (最小应用利用率)**：

```
对于任意时间片 ts：
  Mutator Utilization = (ts - GC时间) / ts
  
MMU = 所有时间片中最小的 Mutator Utilization
```

### 2.3 G1 的承诺

| 参数 | 默认值 | 含义 |
|------|--------|------|
| `-XX:MaxGCPauseMillis` | 200ms | 单次 GC 最大暂停时间 |
| `-XX:GCPauseIntervalMillis` | 1000ms | MMU 计算的时间片长度 |

**承诺**：在任意 1 秒时间窗口内，GC 时间不超过 200ms，应用运行时间至少 800ms。

---

## 三、整体架构

```
┌─────────────────────────────────────────────────────────────┐
│                     G1MMUTracker (抽象基类)                  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  核心参数：                                          │   │
│  │  • _time_slice = 1.0s (GCPauseIntervalMillis)       │   │
│  │  • _max_gc_time = 0.2s (MaxGCPauseMillis)           │   │
│  └─────────────────────────────────────────────────────┘   │
│                          ▲                                  │
│                          │ 继承                             │
│              ┌───────────┴───────────┐                      │
│              ▼                       ▼                      │
│  ┌──────────────────────┐  ┌──────────────────────┐        │
│  │ G1MMUTrackerQueue    │  │ (其他实现，如数组)    │        │
│  │ (循环队列实现)        │  │                      │        │
│  └──────────────────────┘  └──────────────────────┘        │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      使用场景                                │
│  ┌─────────────────┐  ┌──────────────────┐                  │
│  │ G1Policy        │  │ 并发标记调度      │                  │
│  │ (决策何时GC)     │  │ (控制标记步长)    │                  │
│  └─────────────────┘  └──────────────────┘                  │
└─────────────────────────────────────────────────────────────┘
```

---

## 四、核心数据结构详解

### 4.1 G1MMUTracker (抽象基类)

```cpp
class G1MMUTracker: public CHeapObj<mtGC> {
protected:
  double          _time_slice;      // 时间片长度（秒）
  double          _max_gc_time;     // 每个时间片允许的最大GC时间（秒）

public:
  virtual void add_pause(double start, double end) = 0;    // 记录一次暂停
  virtual double when_sec(double current_time, double pause_time) = 0;  // 何时可以执行
  
  // 便捷方法
  bool now_max_gc(double current_time) {                    // 现在是否可以执行最大GC
    return when_sec(current_time, max_gc_time()) < 0.00001;
  }
  
  jlong when_max_gc_ms(double current_time) {               // 返回毫秒
    return (jlong)(when_max_gc_sec(current_time) * 1000.0);
  }
};
```

**【字段详解】**

| 字段 | 类型 | 大小 | 说明 |
|------|------|------|------|
| `_time_slice` | double | 8B | 时间片长度，默认 1.0s (1000ms) |
| `_max_gc_time` | double | 8B | 每时间片最大GC时间，默认 0.2s (200ms) |

**内存布局：**
```
G1MMUTracker (基类)
偏移      字段名              大小    说明
──────────────────────────────────────────────
0x000    [vtable]           8      虚表指针
0x008    _time_slice        8      时间片长度
0x010    _max_gc_time       8      最大GC时间
──────────────────────────────────────────────
总大小：24 bytes（不含子类字段）
```

### 4.2 G1MMUTrackerQueueElem (队列元素)

```cpp
class G1MMUTrackerQueueElem {
private:
  double _start_time;   // 暂停开始时间
  double _end_time;     // 暂停结束时间

public:
  inline double start_time() { return _start_time; }
  inline double end_time()   { return _end_time; }
  inline double duration()   { return _end_time - _start_time; }
};
```

**内存布局：**
```
G1MMUTrackerQueueElem
偏移      字段名              大小    说明
──────────────────────────────────────────────
0x000    _start_time        8      开始时间戳
0x008    _end_time          8      结束时间戳
──────────────────────────────────────────────
总大小：16 bytes
```

### 4.3 G1MMUTrackerQueue (核心实现)

```cpp
class G1MMUTrackerQueue: public G1MMUTracker {
private:
  enum PrivateConstants {
    QueueLength = 64    // 固定长度循环队列
  };

  G1MMUTrackerQueueElem _array[QueueLength];  // 暂停记录数组
  int                   _head_index;          // 队列头部（最新元素）
  int                   _tail_index;          // 队列尾部（最旧元素）
  int                   _no_entries;          // 当前元素数量

  inline int trim_index(int index) {          // 索引循环取模
    return (index + QueueLength) % QueueLength;
  }

  void remove_expired_entries(double current_time);    // 移除过期记录
  double calculate_gc_time(double current_time);       // 计算当前时间片内的GC时间

public:
  virtual void add_pause(double start, double end);
  virtual double when_sec(double current_time, double pause_time);
};
```

**【字段详解】**

| 字段 | 类型 | 大小 | 说明 |
|------|------|------|------|
| `_array[64]` | G1MMUTrackerQueueElem[64] | 1024B | 循环队列存储，64个元素 |
| `_head_index` | int | 4B | 头部索引，指向最新插入的元素 |
| `_tail_index` | int | 4B | 尾部索引，指向最旧的元素 |
| `_no_entries` | int | 4B | 当前队列中的元素数量 |
| [padding] | - | 4B | 对齐填充（64位对齐） |

**完整内存布局：**
```
G1MMUTrackerQueue (总大小: 1064 bytes)
偏移      字段名                 大小      说明
────────────────────────────────────────────────────
0x000    [vtable]               8        虚表指针（继承自基类）
0x008    _time_slice            8        时间片长度（继承）
0x010    _max_gc_time           8        最大GC时间（继承）
0x018    _array[0..63]          1024     64个队列元素 × 16B
0x418    _head_index            4        头部索引
0x41C    _tail_index            4        尾部索引
0x420    _no_entries            4        元素数量
0x424    [padding]              4        对齐到8字节边界
────────────────────────────────────────────────────
总大小：0x428 = 1064 bytes
```

---

## 五、核心算法详解

### 5.1 循环队列的工作原理

```
初始状态 (空队列):
array: [ ][ ][ ][ ][ ][ ]...[ ]  (64个空槽)
        ▲                  ▲
      head=0             tail=1
      entries=0

插入第1个暂停 (0.0s - 0.1s):
array: [ ][A][ ][ ][ ][ ]...[ ]  A=[0.0, 0.1]
          ▲                 ▲
        head=1            tail=1
        entries=1

插入第2个暂停 (0.3s - 0.4s):
array: [ ][A][B][ ][ ][ ]...[ ]  B=[0.3, 0.4]
             ▲              ▲
           head=2         tail=1
           entries=2

插入第64个暂停后 (队列满):
array: [D][A][B][C]...[ ][ ]     填满64个元素
        ▲                  ▲
      head=0             tail=1
      entries=64

插入第65个暂停:
array: [E][A][B][C]...[ ][ ]     E替换D，tail前移
        ▲  ▲
      head  tail=2
      entries=64 (保持)
      
注意：队列满时覆盖最旧元素（_head = _tail 后两者都前移）
```

### 5.2 add_pause() - 记录一次 GC 暂停

```cpp
void G1MMUTrackerQueue::add_pause(double start, double end) {
  double duration = end - start;

  // 步骤1：移除过期的记录（超出当前时间片的）
  remove_expired_entries(end);
  
  // 步骤2：处理队列满的情况
  if (_no_entries == QueueLength) {
    // 队列满：覆盖最旧的记录（tail指向的元素）
    _head_index = trim_index(_head_index + 1);
    assert(_head_index == _tail_index, "循环缓冲区满");
    _tail_index = trim_index(_tail_index + 1);
  } else {
    // 队列未满：正常插入
    _head_index = trim_index(_head_index + 1);
    ++_no_entries;
  }
  
  // 步骤3：存储新记录
  _array[_head_index] = G1MMUTrackerQueueElem(start, end);

  // 步骤4：计算并报告当前时间片的GC时间
  double slice_time = calculate_gc_time(end);
  G1MMUTracer::report_mmu(_time_slice, slice_time, _max_gc_time);

  // 步骤5：检查是否违反 MMU 目标
  if (slice_time >= _max_gc_time) {
    log_info(gc, mmu)("MMU target violated: %.1lfms (%.1lfms/%.1lfms)", 
                      slice_time * 1000.0, _max_gc_time * 1000.0, _time_slice * 1000);
  }
}
```

### 5.3 remove_expired_entries() - 移除过期记录

```cpp
void G1MMUTrackerQueue::remove_expired_entries(double current_time) {
  // 计算时间片边界：当前时间 - 时间片长度
  double limit = current_time - _time_slice;
  
  while (_no_entries > 0) {
    // 如果尾部元素的结束时间早于边界，说明已过期
    if (is_double_geq(limit, _array[_tail_index].end_time())) {
      _tail_index = trim_index(_tail_index + 1);  // 尾部前移
      --_no_entries;                               // 元素数减1
    } else {
      return;  // 找到未过期的，停止
    }
  }
  guarantee(_no_entries == 0, "应该没有元素了");
}
```

**示例：**
```
时间片 = 1.0s, 当前时间 = 5.5s
边界 = 5.5 - 1.0 = 4.5s

队列内容：
  [3.0-3.2], [3.5-3.8], [4.2-4.6], [4.8-5.1], [5.2-5.4]
                              ▲
                          结束时间 > 4.5，保留
                              
移除后：
  [4.2-4.6], [4.8-5.1], [5.2-5.4]
  
说明：只保留最近1秒内的GC记录
```

### 5.4 calculate_gc_time() - 计算当前时间片内的 GC 时间

```cpp
double G1MMUTrackerQueue::calculate_gc_time(double current_time) {
  double gc_time = 0.0;
  double limit = current_time - _time_slice;  // 时间片边界
  
  for (int i = 0; i < _no_entries; ++i) {
    int index = trim_index(_tail_index + i);
    G1MMUTrackerQueueElem *elem = &_array[index];
    
    if (elem->end_time() > limit) {           // 元素在时间片内
      if (elem->start_time() > limit) {
        // 整个暂停都在时间片内
        gc_time += elem->duration();
      } else {
        // 暂停跨越时间片边界，只计算在时间片内的部分
        gc_time += elem->end_time() - limit;
      }
    }
  }
  return gc_time;
}
```

**示例：**
```
时间片 = 1.0s, 当前时间 = 5.5s
边界 = 4.5s

GC记录：
  A: [3.0-3.2]  → 结束时间 3.2 < 4.5，完全过期，跳过
  B: [4.2-4.6]  → 跨越边界，只算 4.6-4.5 = 0.1s
  C: [4.8-5.1]  → 完全在边界内，算 5.1-4.8 = 0.3s
  D: [5.2-5.4]  → 完全在边界内，算 5.4-5.2 = 0.2s
  
总 GC 时间 = 0.1 + 0.3 + 0.2 = 0.6s
```

### 5.5 when_sec() - 计算何时可以执行指定时长的 GC

**这是 G1MMUTracker 最核心的算法！**

```cpp
double G1MMUTrackerQueue::when_sec(double current_time, double pause_time) {
  // 如果请求的暂停时间超过最大值，按最大值计算
  double adjusted_pause_time = 
    (pause_time > max_gc_time()) ? max_gc_time() : pause_time;
  
  // 计算这次 GC 结束后的时间
  double earliest_end = current_time + adjusted_pause_time;
  
  // 计算以 earliest_end 为结束点的时间片边界
  double limit = earliest_end - _time_slice;
  
  // 计算在该时间片内已有的 GC 时间
  double gc_time = calculate_gc_time(earliest_end);
  
  // 计算如果现在就执行GC，会超出限制多少
  double diff = gc_time + adjusted_pause_time - max_gc_time();
  
  // 如果不超出限制，可以立即执行（返回0）
  if (is_double_leq_0(diff))
    return 0.0;

  // 超出限制，需要计算要等待多久
  // 算法：从最早记录开始，逐个"扣除"GC时间，直到不超出限制
  int index = _tail_index;
  while (1) {
    G1MMUTrackerQueueElem *elem = &_array[index];
    if (elem->end_time() > limit) {
      if (elem->start_time() > limit)
        diff -= elem->duration();       // 整个暂停都计入
      else
        diff -= elem->end_time() - limit; // 部分计入
      
      // 扣除后如果不超了，说明可以等到这个暂停结束后执行
      if (is_double_leq_0(diff))
        return elem->end_time() + diff + _time_slice - adjusted_pause_time - current_time;
    }
    index = trim_index(index+1);
    guarantee(index != trim_index(_head_index + 1), "不应该超过head");
  }
}
```

**算法图解：**
```
场景：时间片=1s, 最大GC=0.2s, 当前时间=5.0s, 请求GC=0.15s

当前队列（最近1秒内）：
  [4.2-4.3]: 0.1s
  [4.5-4.6]: 0.1s
  
时间片边界（如果5.15s结束）= 5.15 - 1 = 4.15s

计算：
  已有GC时间 = 0.1 + 0.1 = 0.2s (都在边界内)
  diff = 0.2 + 0.15 - 0.2 = 0.15s > 0 → 超出限制！
  
逐个扣除：
  扣除 [4.2-4.3]: diff = 0.15 - 0.1 = 0.05s > 0，还需要等
  扣除 [4.5-4.6]: diff = 0.05 - 0.1 = -0.05s <= 0，可以了！
  
返回值 = 4.6 + (-0.05) + 1 - 0.15 - 5.0 = 0.4s

结论：需要等待 0.4s，即在 5.4s 时可以执行这次 GC
```

---

## 六、实际使用场景

### 6.1 在 G1Policy 中的使用

```cpp
// g1Policy.cpp
bool G1Policy::about_to_start_mixed_phase() {
  // 检查 MMU 限制，看是否可以开始 Mixed GC
  if (_mmu_tracker->now_max_gc(os::elapsedTime())) {
    // 现在可以执行最大GC，可以开始 Mixed GC
    return true;
  }
  // 需要等待，暂不开始
  return false;
}

// 计算何时可以开始并发标记
double G1Policy::predict_ihop_completion_time() {
  // 考虑 MMU 限制，预测标记完成时间
  double when = _mmu_tracker->when_max_gc_sec(os::elapsedTime());
  return when;
}
```

### 6.2 GC 日志输出

启用 `-Xlog:gc,gc+mmu` 可以看到 MMU 相关信息：

```
[gc,mmu] MMU target violated: 250.0ms (200.0ms/1000.0ms)
```

这表示：最近1秒内GC占用了250ms，超过了200ms的目标。

---

## 七、GDB 验证

### 7.1 GDB 脚本

```gdb
# jvm-md/tmp-file/g1mmutracker/gdb_g1mmutracker.txt

set pagination off
set print pretty on

# 在 G1MMUTrackerQueue::add_pause 设置断点
break G1MMUTrackerQueue::add_pause

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# 第1次命中时打印基本信息
printf "\n========== G1MMUTracker 基本信息 ==========\n"
set $mmu = (G1MMUTrackerQueue*)g1h->policy()->_mmu_tracker
printf "_time_slice: %.3f seconds (%.0f ms)\n", $mmu->_time_slice, $mmu->_time_slice * 1000
printf "_max_gc_time: %.3f seconds (%.0f ms)\n", $mmu->_max_gc_time, $mmu->_max_gc_time * 1000
printf "_no_entries: %d\n", $mmu->_no_entries
printf "_head_index: %d\n", $mmu->_head_index
printf "_tail_index: %d\n", $mmu->_tail_index

# 打印队列内容
printf "\n========== GC 暂停历史 (最近%d条) ==========\n", $mmu->_no_entries
set $i = 0
while $i < $mmu->_no_entries
  set $idx = ($mmu->_tail_index + $i) % 64
  set $elem = &$mmu->_array[$idx]
  printf "[%2d] Start: %.3f, End: %.3f, Duration: %.3f ms\n", \
         $idx, $elem->_start_time, $elem->_end_time, \
         ($elem->_end_time - $elem->_start_time) * 1000
  set $i = $i + 1
end

# 计算当前GC时间
call $mmu->calculate_gc_time($arg2)
printf "\n当前时间片内 GC 时间: %.3f ms\n", $ * 1000

continue
```

### 7.2 预期输出示例

```
========== G1MMUTracker 基本信息 ==========
_time_slice: 1.000 seconds (1000 ms)
_max_gc_time: 0.200 seconds (200 ms)
_no_entries: 3
_head_index: 3
_tail_index: 0

========== GC 暂停历史 (最近3条) ==========
[ 0] Start: 15.234, End: 15.412, Duration: 178.0 ms
[ 1] Start: 16.523, End: 16.698, Duration: 175.0 ms
[ 2] Start: 17.845, End: 18.034, Duration: 189.0 ms

当前时间片内 GC 时间: 189.0 ms
```

---

## 八、关键设计决策

### 8.1 为什么使用固定长度队列？

| 方案 | 优点 | 缺点 |
|------|------|------|
| 固定队列(64) | 内存确定、无动态分配 | 极端场景可能溢出 |
| 动态扩容 | 不会溢出 | 需要锁、内存不确定 |
| 链表 | 无长度限制 | 内存开销大、缓存不友好 |

**JVM 的选择**：固定队列（64个），在队列满时覆盖最旧记录。

**理由**：
1. 正常场景下 64 个足够了（1秒内最多几十次 GC）
2. 极端场景（如 ScavengeALot 测试模式）覆盖最旧记录是可接受的近似

### 8.2 为什么时间是 double 而不是 jlong？

JVM 内部时间使用 `double`（秒）作为单位，原因：
1. **精度足够**：double 可以精确表示毫秒级时间
2. **计算方便**：除法、乘法运算更直观
3. **历史原因**：JVM 早期设计延续

### 8.3 为什么需要 when_sec()？

**核心用途**：让 G1Policy 在做决策时知道"何时可以执行GC"。

```
场景：
  - 当前 Eden 快满了
  - 但最近GC已经很频繁
  - G1Policy 调用 when_max_gc_sec()
  
结果：
  - 返回 0：可以立即执行 Young GC
  - 返回 0.3：需要等 300ms，可以先尝试扩容 Eden
```

---

## 九、面试问答

### Q1: G1MMUTracker 的作用是什么？

**答案要点**：
1. 跟踪最近 GC 暂停历史，维护滑动时间窗口
2. 计算"何时可以执行下一次 GC"
3. 确保 MMU (Minimum Mutator Utilization) 目标得到满足
4. 基于 GCPauseIntervalMillis 和 MaxGCPauseMillis 参数

### Q2: when_sec() 算法的核心思想是什么？

**答案要点**：
1. 计算如果现在就执行 GC，是否会超出时间限制
2. 如果超出，从最早记录开始逐个"扣除"GC时间
3. 直到扣除后不再超出，返回需要等待的时间
4. 保证任意时间片内 GC 时间不超过限制

### Q3: 队列满了怎么办？

**答案要点**：
1. 覆盖最旧的记录（_head = _tail，然后两者都前移）
2. 这是可接受的近似，因为被覆盖的记录已经"很旧"了
3. 正常场景不会满，极端测试模式才可能
4. 64 个元素可以存储 1 秒内 64 次 GC（远超正常频率）

### Q4: MMU 和 MaxGCPauseMillis 的关系？

**答案要点**：
- MaxGCPauseMillis：单次 GC 的最大暂停时间
- GCPauseIntervalMillis：MMU 计算的时间片长度
- MMU = (时间片 - 最大GC时间) / 时间片
- 两者共同决定 G1 的暂停时间目标

---

## 十、总结

**G1MMUTracker 是 G1 "可预测暂停时间"承诺的制度保障。**

| 核心机制 | 说明 |
|---------|------|
| 滑动窗口 | 64元素循环队列，记录最近GC历史 |
| 过期清理 | 自动移除超出时间片的记录 |
| 时间计算 | `when_sec()` 智能计算等待时间 |
| 策略配合 | G1Policy 基于 MMU 做 GC 决策 |

**一句话记忆**：MMU Tracker 就像是 GC 的"交通管制员"，确保 GC 不会在短时间内"堵车"太多，让应用程序有足够的时间"通行"。

---

*文档生成时间: 2026-02-11*  
*源码版本: OpenJDK 11*  
*分析文件: g1MMUTracker.hpp/cpp*
