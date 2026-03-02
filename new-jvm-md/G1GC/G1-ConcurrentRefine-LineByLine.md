# G1 并发精炼线程：三色区域与工作循环

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1 并发精炼（Concurrent Refinement）的本质是**脏卡队列的弹性消费者**：`G1ConcurrentRefineThread` 从全局 `DirtyCardQueueSet` 取出脏卡缓冲区，调用 `G1RemSet::refine_card_concurrently()` 处理每张脏卡（扫描卡内引用，更新目标 Region 的 RSet）；三色水位线（Green/Yellow/Red）控制线程数量和应用线程参与度。

### 0.2 三色水位线

| 水位线 | 默认值 | 触发行为 |
|--------|--------|---------|
| Green | 13 缓冲区 | 只有 1 个 Refinement 线程运行 |
| Yellow | 39 缓冲区 | 激活更多 Refinement 线程（最多 4 个） |
| Red | 65 缓冲区 | 应用线程在分配时也帮助处理脏卡（背压） |

### 0.3 工作循环

```
while (true) {
    if (队列 < Green) { 等待; continue; }
    取一个脏卡缓冲区;
    for (每张脏卡) {
        refine_card_concurrently(card);  // 扫描卡内引用，更新 RSet
    }
}
```

### 0.4 为什么这样设计？

- **为什么需要三色水位线？** 脏卡产生速率随应用负载动态变化；固定线程数在低负载时浪费 CPU，高负载时处理不及；三色水位线让线程数量自适应
- **为什么 Red 区让应用线程参与？** 如果 Refinement 线程跟不上，队列无限增长，GC 开始时需要处理大量积压脏卡，延长 STW；Red 区背压限制积压量

---

## 1. 概览：解决什么问题？

### 1.1 问题背景

G1 使用**写屏障**在引用更新时记录 Dirty Card：
```
对象引用更新时（obj.field = newRef）：
1. 写屏障拦截
2. 标记对应的 Card 为 dirty
3. 将 Card 指针加入线程本地缓冲区
4. 缓冲区满后加入全局完成队列
```

**这些 Dirty Card 必须被处理**：
- 将引用关系更新到 **Remembered Set（RSet）**
- 否则 GC 时会遗漏跨代引用

**核心矛盾**：
- **处理太快**：占用过多 CPU 资源，影响应用吞吐量
- **处理太慢**：积累太多 Dirty Card，GC 时 RSet 更新耗时过长
- **完全不做**：GC 时同步处理，暂停时间爆炸

### 1.2 解决方案：并发精炼（Concurrent Refinement）

**核心思想**：
- 在**应用运行期间**，用后台线程**并发处理** Dirty Card
- 根据**负载动态调整**线程数量和工作强度
- 用**三色区域**机制控制激活时机

**三个区域**：
```
┌─────────────────────────────────────────────────────────────┐
│                 Dirty Card Queue 长度                       │
│                                                              │
│  0      green    yellow                      red            │
│  │        │        │                           │            │
│  │ 绿色区  │ 黄色区 │        红色区             │            │
│  │ (缓存) │(渐进激活)│      (全线程+Mutator)   │            │
│  └────────┴────────┴───────────────────────────┘            │
│                                                              │
│  [0, green)：不处理，利用 Card 缓存效果                     │
│  [green, yellow)：逐步激活精炼线程                          │
│  [yellow, red)：所有精炼线程工作                            │
│  [red, max)：Mutator 也帮忙处理（降级措施）                 │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. 数据结构

### 2.1 G1ConcurrentRefine

**源码位置**：`gc/g1/g1ConcurrentRefine.hpp:71-137`

```cpp
class G1ConcurrentRefine : public CHeapObj<mtGC> {
  G1ConcurrentRefineThreadControl _thread_control;  // 线程管理器

  // ===== 三色区域边界 =====
  size_t _green_zone;           // 绿色区上界（缓冲区数）
  size_t _yellow_zone;          // 黄色区上界
  size_t _red_zone;             // 红色区上界（最大队列长度）
  size_t _min_yellow_zone_size; // 黄色区最小大小

  // 方法
  size_t activation_threshold(uint worker_id) const;   // 激活阈值
  size_t deactivation_threshold(uint worker_id) const; // 去激活阈值
  bool do_refinement_step(uint worker_id);             // 执行一步精炼
};
```

**内存布局**：

```
G1ConcurrentRefine 对象 (~80 bytes)
┌───────────────────────────────────────────────┐
│ _thread_control                               │
│  └─ _threads[]: G1ConcurrentRefineThread*[]   │
│  └─ _num_max_threads: uint                    │
├───────────────────────────────────────────────┤
│ _green_zone: size_t  (默认 ~ParallelGCThreads)│
│ _yellow_zone: size_t (默认 green*2)          │
│ _red_zone: size_t    (默认 yellow+(yellow-green))│
│ _min_yellow_zone_size: size_t                │
└───────────────────────────────────────────────┘
```

### 2.2 G1ConcurrentRefineThread

**源码位置**：`gc/g1/g1ConcurrentRefineThread.hpp:37-69`

```cpp
class G1ConcurrentRefineThread: public ConcurrentGCThread {
  double _vtime_start;          // 虚拟时间起点
  double _vtime_accum;          // 累计虚拟时间

  uint _worker_id;              // 线程ID (0开始)
  uint _worker_id_offset;       // ID偏移（用于并行处理）

  bool _active;                 // 是否激活（非Primary线程）
  Monitor* _monitor;            // 等待/唤醒用的Monitor
  G1ConcurrentRefine* _cr;      // 指向精炼控制器

  // 核心方法
  void wait_for_completed_buffers();  // 等待工作
  void run_service();                  // 主循环 ★★★
  void deactivate();                   // 去激活
};
```

**Primary 线程 vs 非 Primary 线程**：

```
┌────────────────────────────────────────────────────────────┐
│                    G1 Refine#0 (Primary)                   │
│  - 由 Mutator 线程通过 DirtyCardQueueSet 通知激活          │
│  - _monitor = DirtyCardQ_CBL_mon (全局锁)                 │
│  - is_active() 检查 dcqs.process_completed_buffers()      │
├────────────────────────────────────────────────────────────┤
│                   G1 Refine#1~N (非Primary)                │
│  - 由前一个线程激活（#0 激活 #1，#1 激活 #2...）          │
│  - _monitor = 新创建的私有 Monitor                         │
│  - is_active() 检查自己的 _active 字段                     │
└────────────────────────────────────────────────────────────┘
```

### 2.3 G1ConcurrentRefineThreadControl

**源码位置**：`gc/g1/g1ConcurrentRefine.hpp:40-62`

```cpp
class G1ConcurrentRefineThreadControl {
  G1ConcurrentRefine* _cr;

  G1ConcurrentRefineThread** _threads;  // 线程指针数组
  uint _num_max_threads;                // 最大线程数

  // 创建线程
  G1ConcurrentRefineThread* create_refinement_thread(uint worker_id, bool initializing);

  // 激活下一个线程
  void maybe_activate_next(uint cur_worker_id);
};
```

---

## 3. 初始化：三色区域计算

### 3.1 create() 方法

**源码位置**：`gc/g1/g1ConcurrentRefine.cpp:277-312`

```cpp
G1ConcurrentRefine* G1ConcurrentRefine::create(jint* ecode) {
  // 【Line 287】计算最小黄色区大小
  // min_yellow_size = G1ConcRefinementThresholdStep * max_num_threads
  // 默认: 2 * 13 = 26
  size_t min_yellow_zone_size = calc_min_yellow_zone_size();

  // 【Line 288】计算绿色区大小
  // 默认: green = ParallelGCThreads (例如13)
  size_t green_zone = calc_init_green_zone();

  // 【Line 289】计算黄色区大小
  // 默认: yellow = green * 2 = 26
  // 但必须 >= min_yellow_zone_size，所以可能是26
  size_t yellow_zone = calc_init_yellow_zone(green_zone, min_yellow_zone_size);

  // 【Line 290】计算红色区大小
  // red = yellow + (yellow - green) = 26 + 13 = 39
  size_t red_zone = calc_init_red_zone(green_zone, yellow_zone);

  // 【Line 292-297】日志输出
  LOG_ZONES("Initial Refinement Zones: "
            "green: " SIZE_FORMAT ", "
            "yellow: " SIZE_FORMAT ", "
            "red: " SIZE_FORMAT ", "
            "min yellow size: " SIZE_FORMAT,
            green_zone, yellow_zone, red_zone, min_yellow_zone_size);

  // 【Line 299-302】创建对象
  G1ConcurrentRefine* cr = new G1ConcurrentRefine(green_zone,
                                                   yellow_zone,
                                                   red_zone,
                                                   min_yellow_zone_size);
  // 【Line 310】初始化线程控制器
  *ecode = cr->initialize();
  return cr;
}
```

### 3.2 详细计算过程

**calc_init_green_zone()**（`g1ConcurrentRefine.cpp:245-251`）：

```cpp
static size_t calc_init_green_zone() {
  size_t green = G1ConcRefinementGreenZone;
  if (FLAG_IS_DEFAULT(G1ConcRefinementGreenZone)) {
    // 默认使用 ParallelGCThreads
    green = ParallelGCThreads;  // 例如 13
  }
  return MIN2(green, max_green_zone);
}
```

**calc_init_yellow_zone()**（`g1ConcurrentRefine.cpp:253-264`）：

```cpp
static size_t calc_init_yellow_zone(size_t green, size_t min_size) {
  size_t config = G1ConcRefinementYellowZone;
  size_t size = 0;
  if (FLAG_IS_DEFAULT(G1ConcRefinementYellowZone)) {
    // 默认: yellow_size = green * 2
    size = green * 2;  // 13 * 2 = 26
  } else if (green < config) {
    size = config - green;
  }
  size = MAX2(size, min_size);  // 确保 >= min_size
  size = MIN2(size, max_yellow_zone);
  return MIN2(green + size, max_yellow_zone);  // yellow = green + size
}
```

**calc_init_red_zone()**（`g1ConcurrentRefine.cpp:266-275`）：

```cpp
static size_t calc_init_red_zone(size_t green, size_t yellow) {
  size_t size = yellow - green;  // yellow_zone 的宽度
  if (!FLAG_IS_DEFAULT(G1ConcRefinementRedZone)) {
    size_t config = G1ConcRefinementRedZone;
    if (yellow < config) {
      size = MAX2(size, config - yellow);
    }
  }
  // red = yellow + yellow_width
  return MIN2(yellow + size, max_red_zone);
}
```

**标准配置示例**（ParallelGCThreads=13）：

```
Green Zone  = 13
Yellow Zone = 39  (13 + 26)
Red Zone    = 65  (39 + 26)

Yellow Width = 39 - 13 = 26
Red Width    = 65 - 39 = 26
```

---

## 4. 核心流程：run_service() 主循环

### 4.1 主循环框架

**源码位置**：`gc/g1/g1ConcurrentRefineThread.cpp:92-138`

```cpp
void G1ConcurrentRefineThread::run_service() {
  _vtime_start = os::elapsedVTime();

  while (!should_terminate()) {
    // ===== 阶段1: 等待工作 =====
    wait_for_completed_buffers();
    if (should_terminate()) {
      break;
    }

    // ===== 阶段2: 处理工作 =====
    size_t buffers_processed = 0;
    log_debug(gc, refine)("Activated worker %d, on threshold: " SIZE_FORMAT
                          ", current: " SIZE_FORMAT,
                          _worker_id, _cr->activation_threshold(_worker_id),
                          G1BarrierSet::dirty_card_queue_set().completed_buffers_num());

    {
      // 加入可挂起线程集（支持GC期间挂起）
      SuspendibleThreadSetJoiner sts_join;

      while (!should_terminate()) {
        // 检查是否需要让出CPU（GC或其他线程需要）
        if (sts_join.should_yield()) {
          sts_join.yield();
          continue;
        }

        // 执行一步精炼
        if (!_cr->do_refinement_step(_worker_id)) {
          break;  // 缓冲区数量降到阈值以下，退出
        }
        ++buffers_processed;
      }
    }

    // ===== 阶段3: 去激活 =====
    deactivate();
    log_debug(gc, refine)("Deactivated worker %d, off threshold: " SIZE_FORMAT
                          ", current: " SIZE_FORMAT ", processed: " SIZE_FORMAT,
                          _worker_id, _cr->deactivation_threshold(_worker_id),
                          G1BarrierSet::dirty_card_queue_set().completed_buffers_num(),
                          buffers_processed);

    // 更新累计虚拟时间
    if (os::supports_vtime()) {
      _vtime_accum = (os::elapsedVTime() - _vtime_start);
    }
  }

  log_debug(gc, refine)("Stopping %d", _worker_id);
}
```

**流程图**：

```
┌────────────────────────────────────────────────────────────┐
│                    run_service() 主循环                    │
└────────────────────────────────────────────────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────────┐
        │  阶段1: wait_for_completed_buffers()  │
        │  - 在 _monitor 上等待                 │
        │  - 被 activate() 或 terminate 唤醒   │
        └───────────────────────────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────────┐
        │  阶段2: 处理循环                      │
        │                                       │
        │  while (!terminate) {                 │
        │    if (should_yield) yield();         │
        │                                       │
        │    if (!do_refinement_step())         │
        │      break; // 缓冲区数 < 阈值        │
        │                                       │
        │    buffers_processed++;               │
        │  }                                    │
        └───────────────────────────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────────┐
        │  阶段3: deactivate()                  │
        │  - 设置 _active = false               │
        │  - 或 dcqs.set_process_completed(false)│
        └───────────────────────────────────────┘
                            │
                            ▼
                      循环回到阶段1
```

### 4.2 wait_for_completed_buffers()

**源码位置**：`gc/g1/g1ConcurrentRefineThread.cpp:59-64`

```cpp
void G1ConcurrentRefineThread::wait_for_completed_buffers() {
  MutexLockerEx x(_monitor, Mutex::_no_safepoint_check_flag);
  while (!should_terminate() && !is_active()) {
    _monitor->wait(Mutex::_no_safepoint_check_flag);
  }
}
```

**等待条件**：
- **Primary 线程**：`is_active()` 检查 `dcqs.process_completed_buffers()`
- **非 Primary 线程**：`is_active()` 检查自己的 `_active` 字段

### 4.3 activate() / deactivate()

**源码位置**：`gc/g1/g1ConcurrentRefineThread.cpp:71-90`

```cpp
void G1ConcurrentRefineThread::activate() {
  MutexLockerEx x(_monitor, Mutex::_no_safepoint_check_flag);
  if (!is_primary()) {
    // 非 Primary 线程：设置 _active 标志
    set_active(true);
  } else {
    // Primary 线程：设置 DirtyCardQueueSet 标志
    DirtyCardQueueSet& dcqs = G1BarrierSet::dirty_card_queue_set();
    dcqs.set_process_completed(true);
  }
  _monitor->notify();  // 唤醒等待的线程
}

void G1ConcurrentRefineThread::deactivate() {
  MutexLockerEx x(_monitor, Mutex::_no_safepoint_check_flag);
  if (!is_primary()) {
    set_active(false);
  } else {
    DirtyCardQueueSet& dcqs = G1BarrierSet::dirty_card_queue_set();
    dcqs.set_process_completed(false);
  }
}
```

---

## 5. 阈值计算：calc_thresholds()

### 5.1 激活/去激活阈值计算

**源码位置**：`gc/g1/g1ConcurrentRefine.cpp:199-216`

```cpp
static Thresholds calc_thresholds(size_t green_zone,
                                  size_t yellow_zone,
                                  uint worker_i) {
  // 【Line 202】计算黄色区宽度
  double yellow_size = yellow_zone - green_zone;

  // 【Line 203】每个线程的步进大小
  // step = yellow_width / max_threads
  // 例如: 26 / 13 = 2
  double step = yellow_size / G1ConcurrentRefine::max_num_threads();

  // 【Line 204-211】对 worker 0 的特殊处理
  if (worker_i == 0) {
    // Primary 线程更激进地激活，避免积累太多缓冲区
    // step = min(step, ParallelGCThreads/2)
    // 例如: min(2, 6.5) = 2
    step = MIN2(step, ParallelGCThreads / 2.0);
  }

  // 【Line 212-213】计算激活和去激活偏移
  // 激活偏移 = ceil(step * (worker_i + 1))
  // 去激活偏移 = floor(step * worker_i)
  size_t activate_offset = static_cast<size_t>(ceil(step * (worker_i + 1)));
  size_t deactivate_offset = static_cast<size_t>(floor(step * worker_i));

  // 【Line 214-215】返回阈值对
  // activation_threshold = green + activate_offset
  // deactivation_threshold = green + deactivate_offset
  return Thresholds(green_zone + activate_offset,
                    green_zone + deactivate_offset);
}
```

### 5.2 阈值示例（green=13, yellow=39, max_threads=13）

```
yellow_width = 39 - 13 = 26
step = 26 / 13 = 2

┌─────────┬──────────────┬────────────────┬──────────────────┐
│Worker ID│ Activate Thd │ Deactivate Thd │ 步进区间          │
├─────────┼──────────────┼────────────────┼──────────────────┤
│    0    │ 13 + ceil(2) │ 13 + floor(0)  │ [13, 15]         │
│         │    = 15      │    = 13        │                  │
├─────────┼──────────────┼────────────────┼──────────────────┤
│    1    │ 13 + ceil(4) │ 13 + floor(2)  │ (13, 17]         │
│         │    = 17      │    = 15        │                  │
├─────────┼──────────────┼────────────────┼──────────────────┤
│    2    │ 13 + ceil(6) │ 13 + floor(4)  │ (15, 19]         │
│         │    = 19      │    = 17        │                  │
├─────────┼──────────────┼────────────────┼──────────────────┤
│    3    │      21      │      19        │ (17, 21]         │
├─────────┼──────────────┼────────────────┼──────────────────┤
│    4    │      23      │      21        │ (19, 23]         │
├─────────┼──────────────┼────────────────┼──────────────────┤
│   ...   │     ...      │      ...       │ ...              │
├─────────┼──────────────┼────────────────┼──────────────────┤
│   12    │ 13 + ceil(26)│ 13 + floor(24) │ (35, 39]         │
│         │    = 39      │    = 37        │                  │
└─────────┴──────────────┴────────────────┴──────────────────┘

关键观察：
- Worker 0: 缓冲区数 > 15 激活，< 13 去激活
- Worker 1: 缓冲区数 > 17 激活，< 15 去激活
- Worker 12: 缓冲区数 > 39 激活（即到达 yellow zone）
```

### 5.3 激活图示

```
缓冲区数量
    │
 40 ┤                                          [所有线程工作]
 39 ┼───────┬─────────────────────────────────┤ Yellow Zone
    │       │                                  ▲
 37 ┤       │                                  │ Worker 12 激活
    │       │                                  │
 35 ┤       │                                  │
    │       │                                  │
 30 ┤       │    渐进激活区                     │
    │       │    (Yellow Zone)                 │
 25 ┤       │                                  │
    │       │                                  │
 20 ┤       │                                  │
    │       │                                  │
 17 ┤       │                      ┌───────────┘ Worker 2 激活
 15 ┼───────┤──────────────────────┤ Worker 1 激活
 13 ┼───────┤──────────────────────┴───────────┘ Worker 0 激活
    │       │  Green Zone (缓存)
  0 ┼───────┴───────────────────────────────────────
    │       │                                    │
    └───────┴────────────────────────────────────┴───> 时间

缓冲区数量增加时，线程渐进激活：
- 缓冲区数 > 15: 激活 Worker 0
- 缓冲区数 > 17: 激活 Worker 1
- 缓冲区数 > 19: 激活 Worker 2
- ...
- 缓冲区数 > 39: 激活所有线程
```

---

## 6. do_refinement_step()：单步精炼

### 6.1 方法实现

**源码位置**：`gc/g1/g1ConcurrentRefine.cpp:438-455`

```cpp
bool G1ConcurrentRefine::do_refinement_step(uint worker_id) {
  DirtyCardQueueSet& dcqs = G1BarrierSet::dirty_card_queue_set();

  // 【Line 441】获取当前缓冲区数量
  size_t curr_buffer_num = dcqs.completed_buffers_num();

  // 【Line 443-448】GC后清理 padding
  // GC期间会设置 padding 防止线程退出，GC后需要清除
  if (dcqs.completed_queue_padding() > 0 && curr_buffer_num <= yellow_zone()) {
    dcqs.set_completed_queue_padding(0);
  }

  // 【Line 450】可能激活下一个线程 ★★★
  // 如果缓冲区数 > 下一个线程的激活阈值，激活它
  maybe_activate_more_threads(worker_id, curr_buffer_num);

  // 【Line 453-454】处理一个缓冲区
  // 返回 true: 处理成功，继续循环
  // 返回 false: 缓冲区数 <= deactivation_threshold，退出循环
  return dcqs.refine_completed_buffer_concurrently(
           worker_id + worker_id_offset(),
           deactivation_threshold(worker_id));
}
```

### 6.2 maybe_activate_more_threads()

**源码位置**：`gc/g1/g1ConcurrentRefine.cpp:432-436`

```cpp
void G1ConcurrentRefine::maybe_activate_more_threads(uint worker_id, size_t num_cur_buffers) {
  // 如果当前缓冲区数 > 下一个线程的激活阈值，激活它
  if (num_cur_buffers > activation_threshold(worker_id + 1)) {
    _thread_control.maybe_activate_next(worker_id);
  }
}
```

### 6.3 G1ConcurrentRefineThreadControl::maybe_activate_next()

**源码位置**：`gc/g1/g1ConcurrentRefine.cpp:94-113`

```cpp
void G1ConcurrentRefineThreadControl::maybe_activate_next(uint cur_worker_id) {
  assert(cur_worker_id < _num_max_threads, "Invalid worker id");

  // 【Line 98-101】已经是最后一个线程，无需激活
  if (cur_worker_id == (_num_max_threads - 1)) {
    return;
  }

  // 【Line 103】计算下一个线程ID
  uint worker_id = cur_worker_id + 1;

  // 【Line 104-109】获取或创建下一个线程
  G1ConcurrentRefineThread* thread_to_activate = _threads[worker_id];
  if (thread_to_activate == NULL) {
    // 懒创建：第一次需要时才创建
    _threads[worker_id] = create_refinement_thread(worker_id, false);
    thread_to_activate = _threads[worker_id];
  }

  // 【Line 110-112】如果线程未激活，激活它
  if (thread_to_activate != NULL && !thread_to_activate->is_active()) {
    thread_to_activate->activate();
  }
}
```

### 6.4 refine_completed_buffer_concurrently()

**源码位置**：`gc/g1/dirtyCardQueue.cpp:254-257`

```cpp
bool DirtyCardQueueSet::refine_completed_buffer_concurrently(uint worker_i, size_t stop_at) {
  // 创建闭包对象
  G1RefineCardConcurrentlyClosure cl;

  // 应用闭包到已完成的缓冲区，直到剩余缓冲区数 <= stop_at
  return apply_closure_to_completed_buffer(&cl, worker_i, stop_at, false);
}
```

### 6.5 apply_closure_to_completed_buffer()

**源码位置**：`gc/g1/dirtyCardQueue.cpp:264-285`

```cpp
bool DirtyCardQueueSet::apply_closure_to_completed_buffer(CardTableEntryClosure* cl,
                                                          uint worker_i,
                                                          size_t stop_at,
                                                          bool during_pause) {
  // 【Line 269】获取一个缓冲区
  // 如果缓冲区数 <= stop_at，返回 NULL
  BufferNode* nd = get_completed_buffer(stop_at);

  if (nd == NULL) {
    return false;  // 缓冲区数不足，告诉调用者退出循环
  } else {
    // 【Line 273】应用闭包处理缓冲区中的所有 Card
    if (apply_closure_to_buffer(cl, nd, true, worker_i)) {
      // 【Line 276】完全处理完，释放缓冲区
      deallocate_buffer(nd);
      Atomic::inc(&_processed_buffers_rs_thread);
    } else {
      // 【Line 281】未完全处理（可能是 should_yield），放回队列
      guarantee(!during_pause, "Should never stop early");
      enqueue_complete_buffer(nd);
    }
    return true;  // 成功处理一个缓冲区，继续循环
  }
}
```

### 6.6 get_completed_buffer()

**源码位置**：`gc/g1/dirtyCardQueue.cpp:231-252`

```cpp
BufferNode* DirtyCardQueueSet::get_completed_buffer(size_t stop_at) {
  BufferNode* nd = NULL;
  MutexLockerEx x(_cbl_mon, Mutex::_no_safepoint_check_flag);

  // 【Line 235-238】如果缓冲区数 <= stop_at，返回 NULL
  // 这会让调用者知道应该退出循环
  if (_n_completed_buffers <= stop_at) {
    _process_completed = false;  // 标记不需要处理
    return NULL;
  }

  // 【Line 240-248】从队列头部取出一个缓冲区
  if (_completed_buffers_head != NULL) {
    nd = _completed_buffers_head;
    _completed_buffers_head = nd->next();
    _n_completed_buffers--;
    if (_completed_buffers_head == NULL) {
      _completed_buffers_tail = NULL;
    }
  }
  return nd;
}
```

---

## 7. 自适应调整：update_zones()

### 7.1 adjust() 方法

**源码位置**：`gc/g1/g1ConcurrentRefine.cpp:388-416`

```cpp
void G1ConcurrentRefine::adjust(double update_rs_time,
                                size_t update_rs_processed_buffers,
                                double goal_ms) {
  DirtyCardQueueSet& dcqs = G1BarrierSet::dirty_card_queue_set();

  // 【Line 393】自适应调整（默认开启）
  if (G1UseAdaptiveConcRefinement) {
    // 更新三色区域边界
    update_zones(update_rs_time, update_rs_processed_buffers, goal_ms);

    // 【Line 397-405】更新 DirtyCardQueueSet 参数
    if (max_num_threads() == 0) {
      // 没有精炼线程，禁用通知
      dcqs.set_process_completed_threshold(INT_MAX);
    } else {
      // 设置 Worker 0 的激活阈值
      size_t activate = activation_threshold(0);
      dcqs.set_process_completed_threshold((int)activate);
    }
    // 设置最大队列长度
    dcqs.set_max_completed_queue((int)red_zone());
  }

  // 【Line 409-415】队列 padding 管理
  size_t curr_queue_size = dcqs.completed_buffers_num();
  if (curr_queue_size >= yellow_zone()) {
    // 防止线程在 GC 后立即退出
    dcqs.set_completed_queue_padding(curr_queue_size);
  } else {
    dcqs.set_completed_queue_padding(0);
  }
  dcqs.notify_if_necessary();
}
```

### 7.2 update_zones()

**源码位置**：`gc/g1/g1ConcurrentRefine.cpp:362-386`

```cpp
void G1ConcurrentRefine::update_zones(double update_rs_time,
                                      size_t update_rs_processed_buffers,
                                      double goal_ms) {
  log_trace(CTRL_TAGS)("Updating Refinement Zones: "
                       "update_rs time: %.3fms, "
                       "update_rs buffers: " SIZE_FORMAT ", "
                       "update_rs goal time: %.3fms",
                       update_rs_time,
                       update_rs_processed_buffers,
                       goal_ms);

  // 【Line 373-376】更新绿色区
  _green_zone = calc_new_green_zone(_green_zone,
                                    update_rs_time,
                                    update_rs_processed_buffers,
                                    goal_ms);

  // 【Line 377】更新黄色区
  _yellow_zone = calc_new_yellow_zone(_green_zone, _min_yellow_zone_size);

  // 【Line 378】更新红色区
  _red_zone = calc_new_red_zone(_green_zone, _yellow_zone);

  assert_zone_constraints_gyr(_green_zone, _yellow_zone, _red_zone);
  LOG_ZONES("Updated Refinement Zones: "
            "green: " SIZE_FORMAT ", "
            "yellow: " SIZE_FORMAT ", "
            "red: " SIZE_FORMAT,
            _green_zone, _yellow_zone, _red_zone);
}
```

### 7.3 calc_new_green_zone()

**源码位置**：`gc/g1/g1ConcurrentRefine.cpp:333-350`

```cpp
static size_t calc_new_green_zone(size_t green,
                                  double update_rs_time,
                                  size_t update_rs_processed_buffers,
                                  double goal_ms) {
  // 【Line 339】调整系数
  const double inc_k = 1.1, dec_k = 0.9;

  // 【Line 340-343】如果 RSet 更新时间超过目标，减小 green zone
  if (update_rs_time > goal_ms) {
    if (green > 0) {
      green = static_cast<size_t>(green * dec_k);  // 减少 10%
    }
  }
  // 【Line 344-348】如果 RSet 更新时间低于目标且处理量充足，增大 green zone
  else if (update_rs_time < goal_ms &&
           update_rs_processed_buffers > green) {
    green = static_cast<size_t>(MAX2(green * inc_k, green + 1.0));  // 增加 10%
    green = MIN2(green, max_green_zone);
  }
  return green;
}
```

**调整逻辑**：

```
GC 期间的 RSet 更新时间 (update_rs_time)
      │
      ├─ > goal_ms  → 减小 green zone → 更早激活精炼线程
      │               (让精炼线程承担更多工作)
      │
      └─ < goal_ms  → 增大 green zone → 推迟激活精炼线程
                      (充分利用 Card 缓存效果)
```

---

## 8. G1RefineCardConcurrentlyClosure：实际处理

### 8.1 闭包实现

**源码位置**：`gc/g1/dirtyCardQueue.cpp:43-55`

```cpp
class G1RefineCardConcurrentlyClosure: public CardTableEntryClosure {
public:
  bool do_card_ptr(jbyte* card_ptr, uint worker_i) {
    // 调用 G1RemSet 处理单张 Card
    G1CollectedHeap::heap()->g1_rem_set()->refine_card_concurrently(card_ptr, worker_i);

    // 【Line 48-50】检查是否需要让出 CPU
    if (SuspendibleThreadSet::should_yield()) {
      return false;  // 未完成，需要让出
    }
    return true;  // 完成
  }
};
```

### 8.2 apply_closure_to_buffer()

**源码位置**：`gc/g1/dirtyCardQueue.cpp:177-199`

```cpp
bool DirtyCardQueueSet::apply_closure_to_buffer(CardTableEntryClosure* cl,
                                                BufferNode* node,
                                                bool consume,
                                                uint worker_i) {
  if (cl == NULL) return true;
  bool result = true;
  void** buf = BufferNode::make_buffer_from_node(node);
  size_t i = node->index();  // 从上次处理位置继续
  size_t limit = buffer_size();

  // 遍历缓冲区中的所有 Card 指针
  for ( ; i < limit; ++i) {
    jbyte* card_ptr = static_cast<jbyte*>(buf[i]);
    assert(card_ptr != NULL, "invariant");

    // 应用闭包处理 Card
    if (!cl->do_card_ptr(card_ptr, worker_i)) {
      result = false;  // 未完成处理
      break;
    }
  }

  // 【Line 194-197】更新索引（支持断点续传）
  if (consume) {
    node->set_index(i);
  }
  return result;
}
```

---

## 9. 完整工作流

### 9.1 缓冲区数量变化时的线程行为

```
时间轴 →

缓冲区数量
    │
 65 ┼─────────────────────────────────────── Red Zone
    │  │                                   ▲
 60 ┤  │                                   │ 所有精炼线程工作
    │  │                                   │ Mutator 也可能帮忙
 50 ┤  │                                   │
    │  │                                   │
 40 ┤  │    所有线程工作中                  │
 39 ┼──┤────────────────────────────────────┤ Yellow Zone
    │  │                                   │
 35 ┤  │   Worker 12 工作                   │
    │  │                                   │
 30 ┤  │   Worker 10, 11, 12 工作          │
    │  │                                   │
 25 ┤  │   Worker 8, 9, 10, 11, 12 工作    │
    │  │                                   │
 20 ┤  │   Worker 4, 5, 6, 7 工作          │
    │  │                                   │
 17 ┤  │   Worker 1, 2, 3 工作              │
 15 ┼──┤────────────────────────────────────┤ Worker 0 激活阈值
 13 ┼──┤────────────────────────────────────┤ Green Zone (缓存)
    │  │                                   │
  0 ┼──┴────────────────────────────────────┴───
    └──┴────────────────────────────────────┴───> 时间

缓冲区数量减少时，线程逐个去激活：
- 缓冲区数 < 37: Worker 12 去激活
- 缓冲区数 < 35: Worker 11 去激活
- ...
- 缓冲区数 < 13: Worker 0 去激活
```

### 9.2 交互序列图

```
Mutator        DCQS       Refine#0     Refine#1    Refine#2    G1RemSet
   │            │            │            │           │           │
   │ enqueue    │            │            │           │           │
   ├───────────>│            │            │           │           │
   │            │ count=15   │            │           │           │
   │            ├───────────>│ activate   │           │           │
   │            │            │ (threshold=15)         │           │
   │            │            │            │           │           │
   │            │            │ process    │           │           │
   │            │            ├───────────────────────────────────>│
   │            │            │            │           │           │
   │            │            │ count=17   │           │           │
   │            │            ├───────────>│ activate  │           │
   │            │            │            │ (thd=17)  │           │
   │            │            │            │           │           │
   │            │            │            │ process   │           │
   │            │            │            ├──────────────────────>│
   │            │            │            │           │           │
   │            │            │ count=19   │           │           │
   │            │            ├───────────────────────>│ activate  │
   │            │            │            │           │ (thd=19)  │
   │            │            │            │           │           │
   │            │            │            │           │ process   │
   │            │            │            │           ├──────────>│
   │            │            │            │           │           │
   │            │            │            │           │           │
```

---

## 10. GDB 验证脚本

### 10.1 追踪线程激活

```bash
cat > /data/workspace/openjdk-cut-new/jvm-md/tmp-file/refine/trace_activation.gdb << 'EOF'
# 在 activate() 设置断点
break G1ConcurrentRefineThread::activate

commands 1
  printf "\n=== Thread %d Activated ===\n", ((G1ConcurrentRefineThread*)this)->_worker_id
  printf "Current buffers: %lu\n", \
         G1BarrierSet::dirty_card_queue_set().completed_buffers_num()
  printf "Activation threshold: %lu\n", \
         ((G1ConcurrentRefineThread*)this)->_cr->activation_threshold(((G1ConcurrentRefineThread*)this)->_worker_id)
  continue
end

run
EOF
```

### 10.2 追踪区域阈值

```bash
cat > /data/workspace/openjdk-cut-new/jvm-md/tmp-file/refine/print_zones.gdb << 'EOF'
# 在 GC 后打印区域值
break G1ConcurrentRefine::adjust

commands 1
  printf "\n=== Refinement Zones Updated ===\n"
  printf "Green: %lu\n", ((G1ConcurrentRefine*)this)->_green_zone
  printf "Yellow: %lu\n", ((G1ConcurrentRefine*)this)->_yellow_zone
  printf "Red: %lu\n", ((G1ConcurrentRefine*)this)->_red_zone
  printf "Update RS time: %.3f ms\n", $arg0
  printf "Processed buffers: %lu\n", $arg1
  printf "Goal time: %.3f ms\n", $arg2
  continue
end

run
EOF
```

### 10.3 查看精炼线程状态

```bash
cat > /data/workspace/openjdk-cut-new/jvm-md/tmp-file/refine/thread_status.gdb << 'EOF'
define print_refine_thread
  set $t = (G1ConcurrentRefineThread*)$arg0
  printf "Worker %d: active=%d, vtime=%.3f\n", \
         $t->_worker_id, $t->_active, $t->_vtime_accum
end

break G1CollectedHeap::collect

commands 1
  printf "\n=== Refine Thread Status ===\n"
  # 需要手动调用 print_refine_thread
  continue
end

run
EOF
```

---

## 11. 关键问题与解答

### Q1: 为什么需要三色区域？

**A**:
- **Green Zone**：允许缓冲区积累，利用 Card 缓存效果（同一个 Card 可能被多次标记 dirty）
- **Yellow Zone**：渐进激活线程，避免突然唤醒所有线程造成 CPU 抖动
- **Red Zone**：最终防线，让 Mutator 也帮忙处理，防止 GC 暂停时间过长

### Q2: 为什么阈值有激活和去激活之分？

**A**:
- 避免线程频繁激活/去激活（抖动）
- 例如 Worker 0：
  - 缓冲区 > 15 激活
  - 缓冲区 < 13 去激活
  - 中间有 2 个缓冲区的缓冲区，避免频繁切换

### Q3: 什么时候会触发 Mutator 处理？

**A**:
- 缓冲区数达到 Red Zone（默认 65）
- `DirtyCardQueueSet::handle_zero_index()` 会检查
- 如果超过 Red Zone，Mutator 线程会调用 `mut_process_buffer()` 处理缓冲区

### Q4: 如何调整精炼行为？

**A**:
- `G1ConcRefinementThreads`：最大精炼线程数（默认 ParallelGCThreads）
- `G1ConcRefinementGreenZone`：绿色区大小
- `G1ConcRefinementYellowZone`：黄色区大小
- `G1ConcRefinementRedZone`：红色区大小
- `G1UseAdaptiveConcRefinement`：是否自适应调整（默认 true）

---

## 12. 源码位置索引

| 文件 | 行号 | 内容 |
|------|------|------|
| `gc/g1/g1ConcurrentRefine.hpp` | 71-137 | G1ConcurrentRefine 类定义 |
| `gc/g1/g1ConcurrentRefineThread.hpp` | 37-69 | G1ConcurrentRefineThread 类定义 |
| `gc/g1/g1ConcurrentRefineThread.cpp` | 92-138 | run_service() 主循环 |
| `gc/g1/g1ConcurrentRefineThread.cpp` | 59-64 | wait_for_completed_buffers() |
| `gc/g1/g1ConcurrentRefineThread.cpp` | 71-90 | activate() / deactivate() |
| `gc/g1/g1ConcurrentRefine.cpp` | 199-216 | calc_thresholds() |
| `gc/g1/g1ConcurrentRefine.cpp` | 277-312 | create() 初始化 |
| `gc/g1/g1ConcurrentRefine.cpp` | 438-455 | do_refinement_step() |
| `gc/g1/g1ConcurrentRefine.cpp` | 362-386 | update_zones() |
| `gc/g1/dirtyCardQueue.cpp` | 43-55 | G1RefineCardConcurrentlyClosure |
| `gc/g1/dirtyCardQueue.cpp` | 254-257 | refine_completed_buffer_concurrently() |
| `gc/g1/dirtyCardQueue.cpp` | 231-252 | get_completed_buffer() |

---

## 13. 总结

**G1 并发精炼的核心思想**：
1. **异步处理**：Mutator 只负责记录 dirty card，后台线程负责处理
2. **三色区域**：根据负载动态调整线程数量
3. **渐进激活**：避免突然唤醒大量线程
4. **自适应调整**：根据 GC 表现调整区域边界
5. **可挂起**：支持 GC 期间安全挂起

**关键参数**：
- Green Zone：缓存效果与处理时机的平衡点
- Yellow Zone：线程渐进激活的区间
- Red Zone：最终防线，触发 Mutator 帮忙

**性能影响**：
- 精炼线程占用 CPU，但减少了 GC 暂停时间
- 三色区域机制在吞吐量和延迟之间找到平衡
