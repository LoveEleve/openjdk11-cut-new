# D.3 G1YoungRemSetSamplingThread - RSet 采样线程

> 每 300ms 采样一次年轻代 RSet 大小，动态调整年轻代长度以满足停顿时间目标

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **D.3 G1YoungRemSetSamplingThread - RSet 采样线程**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 1. 为什么需要 RSet 采样？

### 1.1 问题：GC 停顿时间预测不准

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Young GC 停顿时间组成                            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Total Pause Time = Root Scan + RSet Scan + Object Copy + Other     │
│                           ↑                                         │
│                    这部分时间与 RSet 大小成正比！                    │
│                                                                      │
│  问题:                                                               │
│  - GC 结束时根据当前 RSet 大小预测下次 GC 停顿时间                   │
│  - 但 RSet 在两次 GC 之间会持续增长（精炼线程不断添加）             │
│  - 导致预测不准，可能超过 MaxGCPauseMillis 目标                     │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.2 解决方案：周期性采样

```
┌─────────────────────────────────────────────────────────────────────┐
│                    RSet 采样线程工作原理                            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  时间轴:                                                             │
│  ─────────────────────────────────────────────────────────────────  │
│  │    │    │    │    │    │    │    │                               │
│  GC   采   采   采   采   采   采   GC                              │
│  #1   样   样   样   样   样   样   #2                              │
│       ↑    ↑    ↑    ↑    ↑    ↑                                    │
│      300ms                        每 300ms 采样一次                  │
│                                                                      │
│  采样发现 RSet 增长过快:                                            │
│  → 调小年轻代大小                                                   │
│  → 提前触发 GC                                                      │
│  → 保证停顿时间不超标                                               │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. G1YoungRemSetSamplingThread 类

### 2.1 类定义

```cpp
// g1YoungRemSetSamplingThread.hpp:42-58

class G1YoungRemSetSamplingThread: public ConcurrentGCThread {
private:
  Monitor _monitor;  // 用于休眠和唤醒

  void sample_young_list_rs_lengths();  // 核心采样方法
  void run_service();                    // 线程主循环
  void stop_service();                   // 停止线程
  void sleep_before_next_cycle();        // 休眠 300ms

  double _vtime_accum;  // 累积 CPU 时间

public:
  G1YoungRemSetSamplingThread();
  double vtime_accum() { return _vtime_accum; }
};
```

### 2.2 内存布局

```
G1YoungRemSetSamplingThread 对象:
┌───────────────────────────────────────────────────────────┐
│ 继承自 ConcurrentGCThread                                 │
│   ├── _should_terminate                                   │
│   └── OS 线程句柄                                         │
├───────────────────────────────────────────────────────────┤
│ _monitor          │ Monitor 对象                          │ ~64B
│ _vtime_accum      │ 累积 CPU 时间                         │ 8B
└───────────────────────────────────────────────────────────┘
```

---

## 3. 创建流程

### 3.1 构造函数

```cpp
// g1YoungRemSetSamplingThread.cpp:35-43

G1YoungRemSetSamplingThread::G1YoungRemSetSamplingThread() :
    ConcurrentGCThread(),
    _monitor(Mutex::nonleaf,
             "G1YoungRemSetSamplingThread monitor",
             true,
             Monitor::_safepoint_check_never) {
  // 设置线程名称
  set_name("G1 Young RemSet Sampling");
  // 创建并启动 OS 线程
  create_and_start();
}
```

### 3.2 在 G1CollectedHeap::initialize() 中创建

```cpp
// g1CollectedHeap.cpp:1575-1580

jint G1CollectedHeap::initialize_young_gen_sampling_thread() {
  _young_gen_sampling_thread = new G1YoungRemSetSamplingThread();
  if (_young_gen_sampling_thread->osthread() == NULL) {
    vm_shutdown_during_initialization("Could not create G1YoungRemSetSamplingThread");
    return JNI_ENOMEM;
  }
  return JNI_OK;
}
```

---

## 4. 主循环详解

### 4.1 run_service() - 线程主循环

```cpp
// g1YoungRemSetSamplingThread.cpp:53-67

void G1YoungRemSetSamplingThread::run_service() {
  double vtime_start = os::elapsedVTime();

  while (!should_terminate()) {
    // Step 1: 执行采样
    sample_young_list_rs_lengths();

    // Step 2: 更新累积时间
    if (os::supports_vtime()) {
      _vtime_accum = (os::elapsedVTime() - vtime_start);
    } else {
      _vtime_accum = 0.0;
    }

    // Step 3: 休眠 300ms
    sleep_before_next_cycle();
  }
}
```

### 4.2 sleep_before_next_cycle() - 休眠等待

```cpp
// g1YoungRemSetSamplingThread.cpp:45-51

void G1YoungRemSetSamplingThread::sleep_before_next_cycle() {
  MutexLockerEx x(&_monitor, Mutex::_no_safepoint_check_flag);
  if (!should_terminate()) {
    // G1ConcRefinementServiceIntervalMillis = 300ms
    uintx waitms = G1ConcRefinementServiceIntervalMillis;
    _monitor.wait(Mutex::_no_safepoint_check_flag, waitms);
  }
}
```

---

## 5. 采样核心逻辑

### 5.1 sample_young_list_rs_lengths()

```cpp
// g1YoungRemSetSamplingThread.cpp:106-121

void G1YoungRemSetSamplingThread::sample_young_list_rs_lengths() {
  // 加入可暂停线程集合（遇到 Safepoint 会暂停）
  SuspendibleThreadSetJoiner sts;
  
  G1CollectedHeap* g1h = G1CollectedHeap::heap();
  G1Policy* g1p = g1h->g1_policy();

  // 只有启用自适应年轻代长度时才采样
  if (g1p->adaptive_young_list_length()) {
    // 创建采样闭包
    G1YoungRemSetSamplingClosure cl(&sts);

    // 遍历 Collection Set 中的年轻代 Region
    G1CollectionSet* g1cs = g1h->collection_set();
    g1cs->iterate(&cl);

    // 如果遍历完成（未被打断），根据采样结果调整年轻代
    if (cl.is_complete()) {
      g1p->revise_young_list_target_length_if_necessary(cl.sampled_rs_lengths());
    }
  }
}
```

### 5.2 G1YoungRemSetSamplingClosure - 采样闭包

```cpp
// g1YoungRemSetSamplingThread.cpp:74-104

class G1YoungRemSetSamplingClosure : public HeapRegionClosure {
  SuspendibleThreadSetJoiner* _sts;
  size_t _regions_visited;      // 已访问的 Region 数
  size_t _sampled_rs_lengths;   // 累积的 RSet 大小

public:
  G1YoungRemSetSamplingClosure(SuspendibleThreadSetJoiner* sts) :
    HeapRegionClosure(), _sts(sts), 
    _regions_visited(0), _sampled_rs_lengths(0) { }

  virtual bool do_heap_region(HeapRegion* r) {
    // 获取当前 Region 的 RSet 大小
    size_t rs_length = r->rem_set()->occupied();
    _sampled_rs_lengths += rs_length;

    // 更新 Collection Set 中该 Region 的预测信息
    G1CollectedHeap::heap()->collection_set()
        ->update_young_region_prediction(r, rs_length);

    _regions_visited++;

    // 每 10 个 Region 检查一次是否需要暂停
    if (_regions_visited == 10) {
      if (_sts->should_yield()) {
        _sts->yield();  // GC 开始，暂停采样
        return true;    // 中断遍历，采样数据可能已过时
      }
      _regions_visited = 0;
    }
    return false;  // 继续遍历
  }

  size_t sampled_rs_lengths() const { return _sampled_rs_lengths; }
};
```

---

## 6. 年轻代长度调整

### 6.1 revise_young_list_target_length_if_necessary()

```cpp
// g1Policy.cpp:440-449

void G1Policy::revise_young_list_target_length_if_necessary(size_t rs_lengths) {
  guarantee(adaptive_young_list_length(), "should not call this otherwise");

  // 只有当采样值超过预测值时才调整
  if (rs_lengths > _rs_lengths_prediction) {
    // 增加 10% 余量，避免频繁调整
    size_t rs_lengths_prediction = rs_lengths * 1100 / 1000;
    update_rs_lengths_prediction(rs_lengths_prediction);

    // 根据新的 RSet 预测值调整年轻代目标长度
    update_young_list_max_and_target_length(rs_lengths_prediction);
  }
}
```

### 6.2 调整流程图

```
┌─────────────────────────────────────────────────────────────────────┐
│                    年轻代长度调整流程                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  采样线程每 300ms:                                                  │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                                                               │   │
│  │  遍历年轻代 Region                                           │   │
│  │       ↓                                                       │   │
│  │  累加 RSet 大小 = sampled_rs_lengths                         │   │
│  │       ↓                                                       │   │
│  │  比较: sampled_rs_lengths vs _rs_lengths_prediction          │   │
│  │       │                                                       │   │
│  │       ├── sampled ≤ prediction → 无需调整                    │   │
│  │       │                                                       │   │
│  │       └── sampled > prediction → 需要调整 ↓                  │   │
│  │                                                               │   │
│  │           更新预测值 = sampled × 1.1 (增加 10% 余量)         │   │
│  │                 ↓                                             │   │
│  │           重新计算年轻代目标长度                              │   │
│  │                 ↓                                             │   │
│  │           ┌─────────────────────────────────────────────┐    │   │
│  │           │ 新目标长度 < 当前年轻代长度?                │    │   │
│  │           │     ↓                                        │    │   │
│  │           │ 是 → 下次分配时不扩展年轻代                 │    │   │
│  │           │      或提前触发 GC                          │    │   │
│  │           └─────────────────────────────────────────────┘    │   │
│  │                                                               │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 7. 与 Safepoint 的交互

### 7.1 为什么需要 SuspendibleThreadSetJoiner？

```
问题:
- 采样线程遍历 Collection Set 时
- GC 可能随时触发
- 如果不暂停，可能访问到已被移动的对象 → 崩溃！

解决:
- SuspendibleThreadSetJoiner 让线程加入"可暂停集合"
- GC 开始时，会等待集合中的线程到达 yield 点
- 采样线程每 10 个 Region 检查一次 should_yield()
```

### 7.2 采样与 GC 的时序

```
┌─────────────────────────────────────────────────────────────────────┐
│                    采样与 GC 的时序关系                             │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  采样线程:                                                          │
│  ────────────────────────────────────────────────────────────────   │
│  │ 遍历 Region │ yield │ 休眠 300ms │ 遍历 Region │ yield │ ...    │
│                    ↑                                  ↑              │
│                    │                                  │              │
│  GC 线程:          │                                  │              │
│  ──────────────────┼──────────────────────────────────┼───────────   │
│                    │    GC (STW)                      │              │
│                    │                                  │              │
│  说明:                                                               │
│  - 采样线程遇到 should_yield() 时暂停                               │
│  - GC 完成后，采样线程从休眠中恢复                                  │
│  - 之前的采样数据已过时，下次重新采样                               │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 8. 相关 JVM 参数

### 8.1 核心参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-XX:G1ConcRefinementServiceIntervalMillis` | 300 | 采样间隔（毫秒） |
| `-XX:+G1UseAdaptiveIHOP` | true | 自适应 IHOP |
| `-XX:MaxGCPauseMillis` | 200 | 最大 GC 停顿目标 |

### 8.2 采样间隔的权衡

```
间隔太短 (如 50ms):
  + 更及时发现 RSet 增长
  - CPU 开销增加
  - 频繁调整年轻代大小

间隔太长 (如 1000ms):
  + CPU 开销小
  - 可能错过快速增长
  - 导致 GC 停顿超标

默认 300ms:
  - 每秒约 3 次采样
  - 在响应性和开销之间取得平衡
```

---

## 9. 完整工作流程

```
┌─────────────────────────────────────────────────────────────────────┐
│              G1YoungRemSetSamplingThread 工作流程                   │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  1. 创建阶段 (initialize())                                         │
│     ┌─────────────────────────────────────────────────────────┐     │
│     │ new G1YoungRemSetSamplingThread()                       │     │
│     │   → 创建 Monitor                                        │     │
│     │   → set_name("G1 Young RemSet Sampling")                │     │
│     │   → create_and_start()  启动 OS 线程                    │     │
│     └─────────────────────────────────────────────────────────┘     │
│                              ↓                                       │
│  2. 主循环阶段 (run_service())                                      │
│     ┌─────────────────────────────────────────────────────────┐     │
│     │ while (!should_terminate()) {                          │     │
│     │   sample_young_list_rs_lengths();  // 采样              │     │
│     │   sleep_before_next_cycle();       // 休眠 300ms       │     │
│     │ }                                                       │     │
│     └─────────────────────────────────────────────────────────┘     │
│                              ↓                                       │
│  3. 采样阶段 (sample_young_list_rs_lengths())                       │
│     ┌─────────────────────────────────────────────────────────┐     │
│     │ SuspendibleThreadSetJoiner sts;  // 可被 GC 暂停       │     │
│     │                                                         │     │
│     │ for (HeapRegion* r : collection_set) {                 │     │
│     │   rs_length = r->rem_set()->occupied();                │     │
│     │   total_rs_lengths += rs_length;                       │     │
│     │                                                         │     │
│     │   if (visited % 10 == 0 && sts.should_yield()) {       │     │
│     │     sts.yield();  // GC 开始，暂停采样                 │     │
│     │     return;       // 采样数据已过时                     │     │
│     │   }                                                     │     │
│     │ }                                                       │     │
│     └─────────────────────────────────────────────────────────┘     │
│                              ↓                                       │
│  4. 调整阶段 (revise_young_list_target_length_if_necessary())       │
│     ┌─────────────────────────────────────────────────────────┐     │
│     │ if (sampled_rs > predicted_rs) {                       │     │
│     │   new_prediction = sampled_rs × 1.1;  // +10% 余量     │     │
│     │   update_young_list_max_and_target_length();           │     │
│     │ }                                                       │     │
│     └─────────────────────────────────────────────────────────┘     │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 10. 与其他组件的协作

```
┌─────────────────────────────────────────────────────────────────────┐
│                        组件协作关系                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                  G1YoungRemSetSamplingThread                │    │
│  │                        (采样线程)                            │    │
│  └───────────────────────────┬─────────────────────────────────┘    │
│                              │                                       │
│                    每 300ms 采样                                     │
│                              ↓                                       │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                      G1CollectionSet                        │    │
│  │                    (年轻代 Region 集合)                      │    │
│  │                                                              │    │
│  │  遍历所有年轻代 Region，获取 RSet 大小                      │    │
│  └───────────────────────────┬─────────────────────────────────┘    │
│                              │                                       │
│                    采样结果                                          │
│                              ↓                                       │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                        G1Policy                             │    │
│  │                      (GC 策略)                               │    │
│  │                                                              │    │
│  │  revise_young_list_target_length_if_necessary()             │    │
│  │    - 比较采样值与预测值                                      │    │
│  │    - 必要时调整年轻代目标长度                                │    │
│  └───────────────────────────┬─────────────────────────────────┘    │
│                              │                                       │
│                    影响                                              │
│                              ↓                                       │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                    下次对象分配                              │    │
│  │                                                              │    │
│  │  - 年轻代不再扩展（如果已达目标）                           │    │
│  │  - 或提前触发 Young GC                                      │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 11. 总结

### 11.1 G1YoungRemSetSamplingThread 核心职责

| 职责 | 说明 |
|------|------|
| **周期采样** | 每 300ms 遍历年轻代 Region |
| **RSet 统计** | 累加所有年轻代 Region 的 RSet 大小 |
| **动态调整** | RSet 增长过快时缩小年轻代目标 |
| **保证停顿** | 间接保证 GC 停顿时间不超标 |

### 11.2 关键数值

| 数值 | 含义 |
|------|------|
| 300ms | 采样间隔 (`G1ConcRefinementServiceIntervalMillis`) |
| 10 | 每遍历 10 个 Region 检查一次 yield |
| 10% | RSet 预测值增加的余量 |

### 11.3 设计亮点

```
1. 轻量级: 只有 1 个线程，每 300ms 工作一次
2. 安全性: 与 Safepoint 机制协作，避免并发问题
3. 自适应: 只在 RSet 增长超预期时调整，避免抖动
4. 余量设计: +10% 避免频繁调整
```

### 11.4 线程名称

```
jstack 中显示为: "G1 Young RemSet Sampling"
```
