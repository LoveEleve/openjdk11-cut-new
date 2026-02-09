# D.2 G1ConcurrentRefine - 并发精炼

> G1 的 **并发精炼（Concurrent Refinement）** 负责在 Mutator 运行期间持续处理脏卡，将卡表信息精炼到 RSet 中

---

## 1. 并发精炼的目的

### 1.1 问题：为什么需要并发精炼？

```
┌─────────────────────────────────────────────────────────────────────┐
│                    没有并发精炼的情况                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Mutator 执行期间，引用赋值 → 产生脏卡                               │
│                                                                      │
│     obj.field = new_ref;                                             │
│           ↓                                                          │
│     CardTable[card_index] = dirty(0);                               │
│           ↓                                                          │
│     脏卡进入 DirtyCardQueue                                          │
│           ↓                                                          │
│     累积大量脏卡...                                                  │
│           ↓                                                          │
│     GC 停顿时必须处理所有脏卡 → 停顿时间变长！                       │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.2 解决方案：并发精炼

```
┌─────────────────────────────────────────────────────────────────────┐
│                    有并发精炼的情况                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌─────────────┐    ┌─────────────────────┐    ┌─────────────────┐  │
│  │  Mutator    │ → │ DirtyCardQueue      │ → │ Refine Thread   │  │
│  │ (产生脏卡)  │    │ (缓冲脏卡地址)      │    │ (并发处理)      │  │
│  └─────────────┘    └─────────────────────┘    └─────────────────┘  │
│                                                        ↓             │
│                                               ┌─────────────────┐   │
│                                               │     RSet        │   │
│                                               │ (引用关系记录)   │   │
│                                               └─────────────────┘   │
│                                                                      │
│  效果：GC 停顿时脏卡已经很少，停顿时间更短！                        │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. 三色区域机制（Green/Yellow/Red Zone）

### 2.1 核心思想

根据脏卡队列长度动态调整处理强度：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        脏卡缓冲区数量 →                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  0                  13                  39                  65               │
│  ├──────────────────┼──────────────────┼──────────────────┼                 │
│  │      绿区        │       黄区       │       红区       │                 │
│  │  (Green Zone)    │  (Yellow Zone)   │   (Red Zone)     │                 │
│  │                  │                  │                  │                 │
│  │  什么都不做      │  逐步唤醒精炼    │  应用线程也      │                 │
│  │  (利用缓存效应)  │  线程处理        │  必须帮忙处理    │                 │
│  │                  │                  │                  │                 │
│  └──────────────────┴──────────────────┴──────────────────┘                 │
│                                                                              │
│  绿区: [0, 13)     - 精炼线程休眠，让 CPU 缓存生效                          │
│  黄区: [13, 39)    - 逐步激活更多精炼线程                                    │
│  红区: [39, 65)    - 所有精炼线程全速运行                                    │
│  超红: ≥65         - Mutator 线程也必须帮忙处理！                           │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 区域边界计算

```cpp
// g1ConcurrentRefine.cpp:245-275

// Green Zone: 默认等于 ParallelGCThreads
static size_t calc_init_green_zone() {
  size_t green = G1ConcRefinementGreenZone;
  if (FLAG_IS_DEFAULT(G1ConcRefinementGreenZone)) {
    green = ParallelGCThreads;  // 13
  }
  return MIN2(green, max_green_zone);
}

// Yellow Zone: Green Zone 的 3 倍
static size_t calc_init_yellow_zone(size_t green, size_t min_size) {
  // 默认: green * 2 + green = green * 3
  size_t size = green * 2;  // 26
  size = MAX2(size, min_size);  // min_size = 26
  return green + size;  // 13 + 26 = 39
}

// Red Zone: Yellow Zone + (Yellow - Green)
static size_t calc_init_red_zone(size_t green, size_t yellow) {
  size_t size = yellow - green;  // 39 - 13 = 26
  return yellow + size;  // 39 + 26 = 65
}
```

### 2.3 8GB 堆配置下的区域边界

| 参数 | 值 | 含义 |
|------|-----|------|
| `ParallelGCThreads` | 13 | 并行 GC 线程数 |
| `G1ConcRefinementThreads` | 13 | 并发精炼线程数 |
| `green_zone` | 13 | 绿区上限 |
| `yellow_zone` | 39 | 黄区上限 |
| `red_zone` | 65 | 红区上限 |
| `min_yellow_zone_size` | 26 | 黄区最小宽度 |

---

## 3. G1ConcurrentRefine 类结构

### 3.1 类定义

```cpp
// g1ConcurrentRefine.hpp:71-137

class G1ConcurrentRefine : public CHeapObj<mtGC> {
  // 线程控制器（管理精炼线程池）
  G1ConcurrentRefineThreadControl _thread_control;
  
  // 三色区域边界
  size_t _green_zone;           // 绿区上限 = 13
  size_t _yellow_zone;          // 黄区上限 = 39
  size_t _red_zone;             // 红区上限 = 65
  size_t _min_yellow_zone_size; // 黄区最小宽度 = 26
  
public:
  // 工厂方法
  static G1ConcurrentRefine* create(jint* ecode);
  
  // 区域访问器
  size_t green_zone() const  { return _green_zone;  }
  size_t yellow_zone() const { return _yellow_zone; }
  size_t red_zone() const    { return _red_zone;    }
  
  // 线程激活/去激活阈值
  size_t activation_threshold(uint worker_id) const;
  size_t deactivation_threshold(uint worker_id) const;
  
  // 执行一步精炼
  bool do_refinement_step(uint worker_id);
  
  // 最大线程数 = G1ConcRefinementThreads
  static uint max_num_threads();
};
```

### 3.2 内存布局

```
G1ConcurrentRefine 对象:
┌────────────────────────────────────────────────────────────┐
│ _thread_control       │ G1ConcurrentRefineThreadControl    │ 内嵌对象
├────────────────────────────────────────────────────────────┤
│ _green_zone           │ 13                                 │ 8 字节
│ _yellow_zone          │ 39                                 │ 8 字节
│ _red_zone             │ 65                                 │ 8 字节
│ _min_yellow_zone_size │ 26                                 │ 8 字节
└────────────────────────────────────────────────────────────┘

G1ConcurrentRefineThreadControl:
┌────────────────────────────────────────────────────────────┐
│ _cr                   │ → G1ConcurrentRefine*              │ 8 字节
│ _threads              │ → G1ConcurrentRefineThread*[13]    │ 8 字节
│ _num_max_threads      │ 13                                 │ 4 字节
└────────────────────────────────────────────────────────────┘
```

---

## 4. 创建流程详解

### 4.1 G1ConcurrentRefine::create()

```cpp
// g1ConcurrentRefine.cpp:277-312

G1ConcurrentRefine* G1ConcurrentRefine::create(jint* ecode) {
  // Step 1: 计算三个区域的边界
  size_t min_yellow_zone_size = calc_min_yellow_zone_size();  // 26
  size_t green_zone = calc_init_green_zone();                  // 13
  size_t yellow_zone = calc_init_yellow_zone(green_zone, min_yellow_zone_size);  // 39
  size_t red_zone = calc_init_red_zone(green_zone, yellow_zone);  // 65

  // Step 2: 打印初始区域信息（需要 -Xlog:gc+ergo+refine=debug）
  LOG_ZONES("Initial Refinement Zones: "
            "green: " SIZE_FORMAT ", "
            "yellow: " SIZE_FORMAT ", "
            "red: " SIZE_FORMAT ", "
            "min yellow size: " SIZE_FORMAT,
            green_zone, yellow_zone, red_zone, min_yellow_zone_size);

  // Step 3: 创建 G1ConcurrentRefine 对象
  G1ConcurrentRefine* cr = new G1ConcurrentRefine(green_zone,
                                                   yellow_zone,
                                                   red_zone,
                                                   min_yellow_zone_size);

  // Step 4: 初始化线程池
  *ecode = cr->initialize();  // → _thread_control.initialize()
  return cr;
}
```

### 4.2 线程池初始化

```cpp
// g1ConcurrentRefine.cpp:69-92

jint G1ConcurrentRefineThreadControl::initialize(G1ConcurrentRefine* cr, 
                                                  uint num_max_threads) {
  _cr = cr;
  _num_max_threads = num_max_threads;  // 13
  
  // 分配线程指针数组
  _threads = NEW_C_HEAP_ARRAY(G1ConcurrentRefineThread*, num_max_threads, mtGC);
  
  // 关键: UseDynamicNumberOfGCThreads 控制初始创建数量
  for (uint i = 0; i < num_max_threads; i++) {
    if (UseDynamicNumberOfGCThreads && i != 0) {
      // 动态模式: 只创建第 0 个线程
      _threads[i] = NULL;  // 延迟创建
    } else {
      // 创建线程
      _threads[i] = create_refinement_thread(i, true);
    }
  }
  return JNI_OK;
}
```

### 4.3 精炼线程创建

```cpp
// g1ConcurrentRefineThread.cpp:35-57

G1ConcurrentRefineThread::G1ConcurrentRefineThread(G1ConcurrentRefine* cr, 
                                                    uint worker_id) :
  ConcurrentGCThread(),
  _worker_id(worker_id),
  _active(false),
  _monitor(NULL),
  _cr(cr),
  _vtime_accum(0.0)
{
  // 第 0 号线程（primary）使用全局监视器
  // 其他线程使用私有监视器
  if (!is_primary()) {
    _monitor = new Monitor(Mutex::nonleaf, "Refinement monitor", true,
                           Monitor::_safepoint_check_never);
  } else {
    _monitor = DirtyCardQ_CBL_mon;  // 全局脏卡队列监视器
  }

  // 设置线程名称
  set_name("G1 Refine#%d", worker_id);  // "G1 Refine#0", "G1 Refine#1", ...
  
  // 创建并启动 OS 线程
  create_and_start();
}
```

---

## 5. 线程激活阈值计算

### 5.1 每个线程的激活/去激活阈值

精炼线程按层级激活，每个线程有自己的阈值：

```cpp
// g1ConcurrentRefine.cpp:199-216

static Thresholds calc_thresholds(size_t green_zone,
                                  size_t yellow_zone,
                                  uint worker_i) {
  double yellow_size = yellow_zone - green_zone;  // 39 - 13 = 26
  double step = yellow_size / G1ConcurrentRefine::max_num_threads();  // 26/13 = 2
  
  if (worker_i == 0) {
    // 第 0 号线程更积极激活
    step = MIN2(step, ParallelGCThreads / 2.0);  // MIN2(2, 6.5) = 2
  }
  
  // 激活阈值 = green_zone + ceil(step * (worker_i + 1))
  size_t activate_offset = static_cast<size_t>(ceil(step * (worker_i + 1)));
  // 去激活阈值 = green_zone + floor(step * worker_i)
  size_t deactivate_offset = static_cast<size_t>(floor(step * worker_i));
  
  return Thresholds(green_zone + activate_offset,
                    green_zone + deactivate_offset);
}
```

### 5.2 各线程的阈值表

```
┌──────────┬─────────────────┬──────────────────┬────────────────────────┐
│ Worker # │ 激活阈值        │ 去激活阈值       │ 说明                   │
├──────────┼─────────────────┼──────────────────┼────────────────────────┤
│    0     │ 13 + 2 = 15     │ 13 + 0 = 13      │ 缓冲区 ≥15 时激活      │
│    1     │ 13 + 4 = 17     │ 13 + 2 = 15      │ 缓冲区 ≥17 时激活      │
│    2     │ 13 + 6 = 19     │ 13 + 4 = 17      │ ...                    │
│    3     │ 13 + 8 = 21     │ 13 + 6 = 19      │                        │
│    4     │ 13 + 10 = 23    │ 13 + 8 = 21      │                        │
│    5     │ 13 + 12 = 25    │ 13 + 10 = 23     │                        │
│    6     │ 13 + 14 = 27    │ 13 + 12 = 25     │                        │
│    7     │ 13 + 16 = 29    │ 13 + 14 = 27     │                        │
│    8     │ 13 + 18 = 31    │ 13 + 16 = 29     │                        │
│    9     │ 13 + 20 = 33    │ 13 + 18 = 31     │                        │
│   10     │ 13 + 22 = 35    │ 13 + 20 = 33     │                        │
│   11     │ 13 + 24 = 37    │ 13 + 22 = 35     │                        │
│   12     │ 13 + 26 = 39    │ 13 + 24 = 37     │ 最后一个精炼线程       │
└──────────┴─────────────────┴──────────────────┴────────────────────────┘
```

### 5.3 激活流程图

```
                    脏卡缓冲区数量
        0     13    15    17    19    21    ...   37    39    65
        ├──────┼─────┼─────┼─────┼─────┼─────────┼─────┼─────┤
              绿    #0    #1    #2    #3          #11   #12   红
              区    激活  激活  激活  激活        激活  激活  区
                    │     │     │     │           │     │
                    ↓     ↓     ↓     ↓           ↓     ↓
                   ┌───┐ ┌───┐ ┌───┐ ┌───┐      ┌───┐ ┌───┐
                   │ 0 │ │ 1 │ │ 2 │ │ 3 │ ···  │11 │ │12 │
                   └───┘ └───┘ └───┘ └───┘      └───┘ └───┘
                    ↓     ↓     ↓     ↓           ↓     ↓
                   处理  处理  处理  处理        处理  处理
                   脏卡  脏卡  脏卡  脏卡        脏卡  脏卡
```

---

## 6. 精炼线程工作流程

### 6.1 主循环

```cpp
// g1ConcurrentRefineThread.cpp:92-135

void G1ConcurrentRefineThread::run_service() {
  _vtime_start = os::elapsedVTime();

  while (!should_terminate()) {
    // Step 1: 等待被激活
    wait_for_completed_buffers();
    
    if (should_terminate()) break;

    size_t buffers_processed = 0;
    
    // Step 2: 加入可暂停线程集合（遇到 Safepoint 会暂停）
    {
      SuspendibleThreadSetJoiner sts_join;

      // Step 3: 循环处理脏卡
      while (!should_terminate()) {
        if (sts_join.should_yield()) {
          sts_join.yield();  // Safepoint 时让步
          continue;
        }

        // 执行一步精炼
        if (!_cr->do_refinement_step(_worker_id)) {
          break;  // 缓冲区数量低于去激活阈值，退出
        }
        ++buffers_processed;
      }
    }

    // Step 4: 去激活自己
    deactivate();
  }
}
```

### 6.2 do_refinement_step() - 执行一步精炼

```cpp
// g1ConcurrentRefine.cpp:438-455

bool G1ConcurrentRefine::do_refinement_step(uint worker_id) {
  DirtyCardQueueSet& dcqs = G1BarrierSet::dirty_card_queue_set();

  size_t curr_buffer_num = dcqs.completed_buffers_num();
  
  // 如果缓冲区数量降到黄区以下，清除 padding
  if (dcqs.completed_queue_padding() > 0 && curr_buffer_num <= yellow_zone()) {
    dcqs.set_completed_queue_padding(0);
  }

  // 尝试激活下一个线程
  maybe_activate_more_threads(worker_id, curr_buffer_num);

  // 处理一个完成的缓冲区
  // 如果缓冲区数量 < 去激活阈值，返回 false
  return dcqs.refine_completed_buffer_concurrently(
      worker_id + worker_id_offset(),
      deactivation_threshold(worker_id));
}
```

### 6.3 线程激活流程图

```
┌─────────────────────────────────────────────────────────────────────┐
│                     精炼线程激活流程                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│    Mutator Thread                                                    │
│         │                                                            │
│         │ 写屏障产生脏卡                                             │
│         ↓                                                            │
│    DirtyCardQueue (TLS)                                              │
│         │                                                            │
│         │ 缓冲区满了                                                 │
│         ↓                                                            │
│    DirtyCardQueueSet (全局)                                          │
│         │                                                            │
│         │ 缓冲区数量 ≥ 15                                            │
│         ↓                                                            │
│    通知 DirtyCardQ_CBL_mon                                           │
│         │                                                            │
│         │ G1 Refine#0 等待此监视器                                   │
│         ↓                                                            │
│    G1 Refine#0 被唤醒                                                │
│         │                                                            │
│         │ 处理脏卡，同时检查是否需要激活 #1                          │
│         ↓                                                            │
│    if (缓冲区数量 ≥ 17)                                              │
│         │                                                            │
│         │ 激活 G1 Refine#1                                           │
│         ↓                                                            │
│    G1 Refine#1 开始工作...                                           │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 7. 动态区域调整

### 7.1 GC 后调整区域边界

```cpp
// g1ConcurrentRefine.cpp:388-416

void G1ConcurrentRefine::adjust(double update_rs_time,
                                size_t update_rs_processed_buffers,
                                double goal_ms) {
  DirtyCardQueueSet& dcqs = G1BarrierSet::dirty_card_queue_set();

  if (G1UseAdaptiveConcRefinement) {
    // 根据 GC 性能调整区域边界
    update_zones(update_rs_time, update_rs_processed_buffers, goal_ms);

    // 更新脏卡队列的通知阈值
    size_t activate = activation_threshold(0);
    dcqs.set_process_completed_threshold((int)activate);
    dcqs.set_max_completed_queue((int)red_zone());
  }

  // 如果当前缓冲区数量 ≥ 黄区，设置 padding
  size_t curr_queue_size = dcqs.completed_buffers_num();
  if (curr_queue_size >= yellow_zone()) {
    dcqs.set_completed_queue_padding(curr_queue_size);
  } else {
    dcqs.set_completed_queue_padding(0);
  }
  dcqs.notify_if_necessary();
}
```

### 7.2 区域更新算法

```cpp
// g1ConcurrentRefine.cpp:333-386

static size_t calc_new_green_zone(size_t green,
                                  double update_rs_time,
                                  size_t update_rs_processed_buffers,
                                  double goal_ms) {
  const double inc_k = 1.1, dec_k = 0.9;
  
  if (update_rs_time > goal_ms) {
    // GC 时间超标，减小绿区（更早开始精炼）
    green = static_cast<size_t>(green * dec_k);  // × 0.9
  } else if (update_rs_time < goal_ms &&
             update_rs_processed_buffers > green) {
    // GC 时间充裕，增大绿区（更多缓存效应）
    green = static_cast<size_t>(MAX2(green * inc_k, green + 1.0));  // × 1.1
  }
  return green;
}

// Yellow Zone = Green + Green * 2
static size_t calc_new_yellow_zone(size_t green, size_t min_yellow_size) {
  size_t size = green * 2;
  size = MAX2(size, min_yellow_size);
  return green + size;
}

// Red Zone = Yellow + (Yellow - Green)
static size_t calc_new_red_zone(size_t green, size_t yellow) {
  return yellow + (yellow - green);
}
```

---

## 8. 与脏卡队列的交互

### 8.1 整体架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                        脏卡处理架构                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                           │
│  │ Mutator  │  │ Mutator  │  │ Mutator  │                           │
│  │ Thread 1 │  │ Thread 2 │  │ Thread 3 │                           │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘                           │
│       │             │             │                                  │
│       ↓             ↓             ↓                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                           │
│  │  DCQS    │  │  DCQS    │  │  DCQS    │   TLS 缓冲区              │
│  │ (local)  │  │ (local)  │  │ (local)  │   每个 1KB                │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘                           │
│       │             │             │                                  │
│       │ 满了        │ 满了        │ 满了                            │
│       ↓             ↓             ↓                                  │
│  ┌─────────────────────────────────────────┐                        │
│  │          DirtyCardQueueSet              │                        │
│  │         (全局完成缓冲区列表)             │                        │
│  │                                          │                        │
│  │  _completed_buffers_head → buf → buf... │                        │
│  │  _completed_buffers_num = N             │                        │
│  └─────────────────────────────────────────┘                        │
│       │                                                              │
│       │ N ≥ 15                                                       │
│       ↓                                                              │
│  ┌─────────────┐ ┌─────────────┐           ┌─────────────┐          │
│  │G1 Refine#0  │ │G1 Refine#1  │ ·····     │G1 Refine#12 │          │
│  │ (primary)   │ │             │           │             │          │
│  └──────┬──────┘ └──────┬──────┘           └──────┬──────┘          │
│         │               │                         │                  │
│         ↓               ↓                         ↓                  │
│  ┌─────────────────────────────────────────────────────────┐        │
│  │                        RSet                              │        │
│  │              (每个 Region 的记忆集)                      │        │
│  └─────────────────────────────────────────────────────────┘        │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 8.2 精炼一个脏卡的过程

```cpp
// 伪代码
void refine_card(CardValue* card_addr) {
    // 1. 获取卡对应的堆地址范围
    HeapWord* start = card_to_heap_start(card_addr);
    HeapWord* end = start + CardTableModRefBS::card_size_in_words;  // 512B
    
    // 2. 获取卡所在的 Region
    HeapRegion* card_region = heap_region_containing(start);
    
    // 3. 扫描这 512 字节内的所有对象
    for (oop obj : objects_in_range(start, end)) {
        // 4. 扫描对象的每个引用字段
        for (oop* ref : reference_fields(obj)) {
            oop target = *ref;
            if (target != NULL) {
                HeapRegion* target_region = heap_region_containing(target);
                
                // 5. 如果是跨 Region 引用，更新目标的 RSet
                if (card_region != target_region) {
                    target_region->rem_set()->add_reference(ref, worker_id);
                }
            }
        }
    }
    
    // 6. 清除卡为 clean
    *card_addr = CardTableModRefBS::clean_card_val();
}
```

---

## 9. 相关 JVM 参数

### 9.1 核心参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-XX:G1ConcRefinementThreads` | ParallelGCThreads | 并发精炼线程数 |
| `-XX:G1ConcRefinementGreenZone` | ParallelGCThreads | 绿区上限 |
| `-XX:G1ConcRefinementYellowZone` | 0 (自动) | 黄区上限 |
| `-XX:G1ConcRefinementRedZone` | 0 (自动) | 红区上限 |
| `-XX:+G1UseAdaptiveConcRefinement` | true | 自适应调整区域边界 |
| `-XX:+UseDynamicNumberOfGCThreads` | true | 动态创建精炼线程 |

### 9.2 查看区域信息的日志参数

```bash
# 查看初始区域值
-Xlog:gc+ergo+refine=debug

# 查看精炼线程激活/去激活
-Xlog:gc+refine=debug
```

### 9.3 日志输出示例

```
[0.015s][debug][gc,ergo,refine] Initial Refinement Zones: green: 13, yellow: 39, red: 65, min yellow size: 26

[1.234s][debug][gc,refine] Activated worker 0, on threshold: 15, current: 23
[1.256s][debug][gc,refine] Deactivated worker 0, off threshold: 13, current: 11, processed: 8
```

---

## 10. 内存布局总览

### 10.1 G1ConcurrentRefine 相关内存

```
┌─────────────────────────────────────────────────────────────────────┐
│                  G1ConcurrentRefine 内存布局                        │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  G1ConcurrentRefine 对象                                            │
│  ┌──────────────────────────────────────────────────────┐           │
│  │ _thread_control                                      │           │
│  │   ├── _cr          → this                            │           │
│  │   ├── _threads     → G1ConcurrentRefineThread*[13]   │           │
│  │   └── _num_max_threads = 13                          │           │
│  │ _green_zone = 13                                     │           │
│  │ _yellow_zone = 39                                    │           │
│  │ _red_zone = 65                                       │           │
│  │ _min_yellow_zone_size = 26                           │           │
│  └──────────────────────────────────────────────────────┘           │
│                                                                      │
│  线程数组（初始只创建 1 个，动态扩展）                              │
│  ┌─────────────────────────────────────────────┐                    │
│  │ [0] → G1ConcurrentRefineThread#0 (primary)  │ ← 初始创建         │
│  │ [1] → NULL                                  │ ← 延迟创建         │
│  │ [2] → NULL                                  │                    │
│  │ ...                                         │                    │
│  │ [12] → NULL                                 │                    │
│  └─────────────────────────────────────────────┘                    │
│                                                                      │
│  每个 G1ConcurrentRefineThread:                                     │
│  ┌──────────────────────────────────────────────────────┐           │
│  │ _worker_id        = 0~12                             │           │
│  │ _active           = false                            │           │
│  │ _monitor          → Monitor 对象                     │           │
│  │ _cr               → G1ConcurrentRefine*              │           │
│  │ _vtime_accum      = 0.0                              │           │
│  │ (继承 ConcurrentGCThread 的 OS 线程栈)               │           │
│  └──────────────────────────────────────────────────────┘           │
│                                                                      │
│  内存开销：                                                         │
│  - G1ConcurrentRefine 对象: ~64B                                    │
│  - 线程指针数组: 13 × 8B = 104B                                     │
│  - 每个线程对象: ~200B + 线程栈 (默认 1MB)                          │
│  - 总计（13线程全部创建时）: ~13MB（主要是线程栈）                  │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 11. 设计亮点

### 11.1 动态线程创建

```
优点:
- 初始只创建 1 个线程，节省内存
- 工作负载增加时按需创建
- 减少不必要的上下文切换

实现:
- UseDynamicNumberOfGCThreads = true（默认）
- 第 N 个线程激活时才创建第 N+1 个线程
```

### 11.2 渐进式激活

```
优点:
- 工作负载轻时，少量线程即可处理
- 工作负载重时，逐步增加处理能力
- 避免"全部激活→全部睡眠"的震荡

实现:
- 每个线程有独立的激活/去激活阈值
- 阈值均匀分布在黄区范围内
```

### 11.3 绿区缓存效应

```
绿区的作用:
- 脏卡短时间内可能被多次修改
- 立即处理可能造成重复工作
- 等待积累一定数量后批量处理更高效

权衡:
- 绿区太大 → GC 停顿时剩余脏卡多
- 绿区太小 → 失去缓存效应
- 自适应调整根据 GC 性能动态平衡
```

---

## 12. 总结

### 12.1 G1ConcurrentRefine 核心职责

| 组件 | 职责 |
|------|------|
| **G1ConcurrentRefine** | 管理精炼策略和线程池 |
| **G1ConcurrentRefineThread** | 执行具体的脏卡精炼工作 |
| **三色区域** | 控制精炼线程的激活强度 |
| **自适应调整** | 根据 GC 性能动态调整区域边界 |

### 12.2 关键数值（8GB 堆）

| 数值 | 含义 |
|------|------|
| 13 | 最大精炼线程数 |
| 13 | 绿区上限（缓冲区数量） |
| 39 | 黄区上限 |
| 65 | 红区上限（超过此值 Mutator 帮忙） |
| 2 | 相邻线程激活阈值差 |

### 12.3 与其他组件的协作

```
Mutator → 写屏障 → DirtyCardQueue (TLS)
                          ↓
              DirtyCardQueueSet (全局)
                          ↓
           G1ConcurrentRefine (控制激活)
                          ↓
           G1ConcurrentRefineThread (处理脏卡)
                          ↓
                        RSet
```
