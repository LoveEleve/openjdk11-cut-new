# G1ConcurrentRefineThread 专家级源码分析

> **定位**：G1 并发精炼线程，应用运行时并发处理脏卡队列，维护 RSet 准确性  
> **核心问题**：如何在应用运行时高效处理脏卡？如何动态调整并发强度？  
> **源码路径**：`src/hotspot/share/gc/g1/g1ConcurrentRefine.hpp/cpp`, `g1ConcurrentRefineThread.hpp/cpp`

---

## 1. 一句话总结

**G1ConcurrentRefineThread 是一组在应用运行时并发工作的后台线程，通过"三色区域（Green/Yellow/Red）"机制动态调整并发强度，及时将写屏障产生的脏卡处理成 RSet 条目，避免脏卡队列堆积导致 GC 暂停时间增加。**

---

## 2. 为什么需要并发精炼线程？

### 2.1 问题背景

在 G1 中，写屏障（Write Barrier）会记录跨 Region 引用变更到脏卡队列：
- **应用线程持续产生脏卡**：每次跨 Region 引用写入都产生脏卡
- **脏卡需要及时处理**：将卡表中的 dirty 卡扫描并更新到 RSet
- **不能仅在 GC 时处理**：如果积压太多，GC 暂停时间会很长

**核心挑战**：
1. **及时处理**：脏卡不能无限堆积
2. **低干扰**：不能影响应用线程性能
3. **自适应**：根据负载动态调整处理速度

### 2.2 如果没有并发精炼线程？

```
无并发精炼的场景
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

应用运行期间：
  脏卡队列不断增长
  ┌─────────────────────────────────────────────────────┐
  │ 脏卡: [C1, C2, C3, C4, C5, ... , C10000]            │
  └─────────────────────────────────────────────────────┘
  
GC 暂停时：
  需要处理所有脏卡
  Update RS 时间 = 10000 卡 × 0.1ms = 1000ms
  
结果：
  - GC 暂停时间过长（秒级）
  - 应用响应性严重下降
  - 无法满足低延迟需求

✅ 有并发精炼的场景：
  应用运行期间：
    精炼线程并发处理脏卡
    保持脏卡队列在合理范围（< 100）
  
  GC 暂停时：
    Update RS 时间 = 100 卡 × 0.1ms = 10ms
    
  结果：
    - GC 暂停时间可控（毫秒级）
    - 满足低延迟需求
```

---

## 3. 整体架构

### 3.1 类层次关系

```
并发精炼架构
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

G1ConcurrentRefine (控制器)
├── _thread_control: G1ConcurrentRefineThreadControl
│       └── _threads: G1ConcurrentRefineThread[]
├── _green_zone: size_t    // 绿色区域阈值
├── _yellow_zone: size_t   // 黄色区域阈值
├── _red_zone: size_t      // 红色区域阈值
├── update_zones(): 自适应调整阈值
└── do_refinement_step(): 执行精炼步骤

G1ConcurrentRefineThread (工作线程)
├── _worker_id: uint       // 线程ID
├── _active: bool          // 激活状态
├── _monitor: Monitor*     // 等待/通知机制
├── run_service(): 主循环
│       └── wait_for_completed_buffers()
│       └── do_refinement_step()
└── activate()/deactivate()

DirtyCardQueueSet (数据源)
├── _completed_buffers: BufferNode链表
├── completed_buffers_num(): 当前数量
├── refine_completed_buffer_concurrently(): 处理缓冲
└── set_process_completed_threshold(): 设置阈值
```

### 3.2 三色区域模型

```
三色区域模型
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

缓冲区数量
    ↑
    │                    ┌─────────────────┐
red │ ←─────────────────→│   Red Zone      │ ← 应用线程参与
(65)│                    │  应用线程也处理  │
    │                    └─────────────────┘
    │                    ┌─────────────────┐
yellow│ ←───────────────→│  Yellow Zone    │ ← 逐渐激活线程
(39)│                    │ 逐渐激活更多线程│
    │                    └─────────────────┘
    │     ┌──────────────┐
green│ ←──→│  Green Zone  │ ← 线程0处理
(13)│     │  基本保持空闲│
    │     └──────────────┘
    └────────────────────────────────────────→
        0         13         39         65

默认配置（8并行GC线程）：
  - Green Zone: 13 (ParallelGCThreads)
  - Yellow Zone: 39 (green × 3)
  - Red Zone: 65 (yellow × 1.67)
  - 最大线程数: 13 (默认)

行为规则：
  Green Zone [0, 13): 
    - 线程0空闲等待
    - 利用缓存效应，不急于处理
    
  Yellow Zone [13, 39):
    - 逐渐激活更多精炼线程
    - 线程n在阈值达到时激活线程n+1
    
  Red Zone [39, 65):
    - 所有精炼线程运行
    - 应用线程也开始处理（Mutator Refinement）
    
  超过 Red Zone:
    - 应用线程必须处理完成后才能继续
    - 写屏障阻塞（最坏情况）
```

---

## 4. 核心数据结构详解

### 4.1 G1ConcurrentRefine 控制器

```cpp
class G1ConcurrentRefine : public CHeapObj<mtGC> {
private:
    G1ConcurrentRefineThreadControl _thread_control;  // 线程控制器
    
    // 三色区域阈值
    size_t _green_zone;    // 绿色区域：无需处理
    size_t _yellow_zone;   // 黄色区域：逐渐激活线程
    size_t _red_zone;      // 红色区域：全部线程运行
    size_t _min_yellow_zone_size;

public:
    // 创建实例
    static G1ConcurrentRefine* create(jint* ecode);
    
    // 基于 Update RS 时间和目标自适应调整区域
    void adjust(double update_rs_time, 
                size_t update_rs_processed_buffers, 
                double goal_ms);
    
    // 获取线程激活/停用阈值
    size_t activation_threshold(uint worker_id) const;
    size_t deactivation_threshold(uint worker_id) const;
    
    // 执行一次精炼步骤
    bool do_refinement_step(uint worker_id);
    
    // 最大线程数
    static uint max_num_threads() { return G1ConcRefinementThreads; }
};
```

#### 阈值计算

```cpp
// 计算线程激活/停用阈值
static Thresholds calc_thresholds(size_t green_zone,
                                  size_t yellow_zone,
                                  uint worker_i) {
    double yellow_size = yellow_zone - green_zone;
    double step = yellow_size / G1ConcurrentRefine::max_num_threads();
    
    if (worker_i == 0) {
        // 线程0更激进，保持队列接近 green_zone
        step = MIN2(step, ParallelGCThreads / 2.0);
    }
    
    size_t activate_offset = static_cast<size_t>(ceil(step * (worker_i + 1)));
    size_t deactivate_offset = static_cast<size_t>(floor(step * worker_i));
    
    return Thresholds(green_zone + activate_offset,
                      green_zone + deactivate_offset);
}

// 示例（green=13, yellow=39, max_threads=13）：
// step = (39-13) / 13 = 2
// Worker 0: activate = 13+ceil(2*1)=15, deactivate = 13+floor(2*0)=13
// Worker 1: activate = 13+ceil(2*2)=17, deactivate = 13+floor(2*1)=15
// ...
// Worker 12: activate = 13+ceil(2*13)=39, deactivate = 13+floor(2*12)=37
```

### 4.2 G1ConcurrentRefineThread 工作线程

```cpp
class G1ConcurrentRefineThread : public ConcurrentGCThread {
private:
    uint _worker_id;           // 线程ID (0 ~ max-1)
    bool _active;              // 是否激活
    Monitor* _monitor;         // 等待/通知机制
    G1ConcurrentRefine* _cr;   // 控制器

    // 等待有工作要做
    void wait_for_completed_buffers() {
        MonitorLockerEx ml(_monitor, Monitor::_no_safepoint_check_flag);
        while (!_should_terminate && !is_active()) {
            ml.wait(Monitor::_no_safepoint_check_flag, 1000);  // 等待1秒或通知
        }
    }

public:
    // 主服务循环
    void run_service() {
        while (!_should_terminate) {
            // 1. 等待激活或工作
            wait_for_completed_buffers();
            
            // 2. 执行精炼步骤
            while (is_active() && do_refinement_step()) {
                // 继续处理，直到被停用或无工作
            }
            
            // 3. 检查是否需要停用
            if (should_deactivate()) {
                deactivate();
            }
        }
    }
    
    // 激活线程
    void activate() {
        MonitorLockerEx ml(_monitor, Monitor::_no_safepoint_check_flag);
        _active = true;
        ml.notify();  // 唤醒等待的线程
    }
    
    // 停用线程
    void deactivate() {
        MonitorLockerEx ml(_monitor, Monitor::_no_safepoint_check_flag);
        _active = false;
    }
};
```

### 4.3 线程控制管理器

```cpp
class G1ConcurrentRefineThreadControl {
private:
    G1ConcurrentRefine* _cr;
    G1ConcurrentRefineThread** _threads;  // 线程指针数组
    uint _num_max_threads;                  // 最大线程数

public:
    // 初始化：创建线程（默认只创建第0个）
    jint initialize(G1ConcurrentRefine* cr, uint num_max_threads) {
        _threads = NEW_C_HEAP_ARRAY(G1ConcurrentRefineThread*, num_max_threads, mtGC);
        
        for (uint i = 0; i < num_max_threads; i++) {
            // 动态线程创建：初始只创建线程0
            if (UseDynamicNumberOfGCThreads && i != 0) {
                _threads[i] = NULL;  // 延迟创建
            } else {
                _threads[i] = create_refinement_thread(i, true);
            }
        }
        return JNI_OK;
    }
    
    // 激活下一个线程（当当前线程发现工作太多时）
    void maybe_activate_next(uint cur_worker_id) {
        uint next_id = cur_worker_id + 1;
        if (next_id >= _num_max_threads) return;
        
        G1ConcurrentRefineThread* next = _threads[next_id];
        if (next == NULL) {
            next = create_refinement_thread(next_id, false);
            _threads[next_id] = next;
        }
        
        if (next != NULL && !next->is_active()) {
            next->activate();
        }
    }
};
```

---

## 5. 精炼流程详解

### 5.1 精炼步骤执行

```cpp
bool G1ConcurrentRefine::do_refinement_step(uint worker_id) {
    DirtyCardQueueSet& dcqs = G1BarrierSet::dirty_card_queue_set();
    
    size_t curr_buffer_num = dcqs.completed_buffers_num();
    
    // 1. 如果队列回落到 yellow_zone 以下，清除 padding
    if (dcqs.completed_queue_padding() > 0 && 
        curr_buffer_num <= yellow_zone()) {
        dcqs.set_completed_queue_padding(0);
    }
    
    // 2. 检查是否需要激活更多线程
    maybe_activate_more_threads(worker_id, curr_buffer_num);
    
    // 3. 处理下一个缓冲区（如果有足够工作）
    return dcqs.refine_completed_buffer_concurrently(
        worker_id + worker_id_offset(),
        deactivation_threshold(worker_id));
}
```

### 5.2 动态线程激活

```cpp
void G1ConcurrentRefine::maybe_activate_more_threads(
        uint worker_id, 
        size_t num_cur_buffers) {
    // 如果当前缓冲区数量超过下一个线程的激活阈值
    if (num_cur_buffers > activation_threshold(worker_id + 1)) {
        _thread_control.maybe_activate_next(worker_id);
    }
}

// 激活链式反应：
// Worker 0 发现队列 > 15 → 激活 Worker 1
// Worker 1 发现队列 > 17 → 激活 Worker 2
// ...
// 直到队列回落或所有线程激活
```

### 5.3 并发精炼过程

```cpp
// DirtyCardQueueSet::refine_completed_buffer_concurrently
bool refine_completed_buffer_concurrently(uint worker_i, size_t stop_at) {
    // 1. 获取一个已完成的缓冲区
    BufferNode* node = get_completed_buffer(stop_at);
    if (node == NULL) return false;
    
    // 2. 创建闭包处理卡片
    G1RefineCardConcurrentlyClosure cl;
    
    // 3. 遍历缓冲区中的所有卡片
    for (size_t i = node->index(); i < buffer_size(); i++) {
        jbyte* card_ptr = static_cast<jbyte*>(node->buffer()[i]);
        
        // 4. 精炼卡片：扫描并更新 RSet
        cl.do_card_ptr(card_ptr, worker_i);
    }
    
    // 5. 释放缓冲区
    deallocate_buffer(node);
    return true;
}
```

---

## 6. 自适应调整机制

### 6.1 调整触发

```cpp
// GC 后调用，基于 Update RS 阶段的表现调整
void G1ConcurrentRefine::adjust(double update_rs_time,
                                size_t update_rs_processed_buffers,
                                double goal_ms) {
    if (G1UseAdaptiveConcRefinement) {
        // 1. 更新三色区域
        update_zones(update_rs_time, update_rs_processed_buffers, goal_ms);
        
        // 2. 更新脏卡队列阈值
        if (max_num_threads() == 0) {
            dcqs.set_process_completed_threshold(INT_MAX);
        } else {
            size_t activate = activation_threshold(0);
            dcqs.set_process_completed_threshold((int)activate);
        }
        dcqs.set_max_completed_queue((int)red_zone());
        
        // 3. 如果需要，添加 padding
        size_t curr_queue_size = dcqs.completed_buffers_num();
        if (curr_queue_size >= yellow_zone()) {
            dcqs.set_completed_queue_padding(curr_queue_size);
        }
    }
    
    // 4. 通知等待的线程
    dcqs.notify_if_necessary();
}
```

### 6.2 区域自适应算法

```cpp
void G1ConcurrentRefine::update_zones(double update_rs_time,
                                      size_t update_rs_processed_buffers,
                                      double goal_ms) {
    // 根据 Update RS 时间和目标调整 green zone
    const double inc_k = 1.1, dec_k = 0.9;
    
    if (update_rs_time > goal_ms) {
        // 太慢：减小 green zone（更积极处理）
        if (_green_zone > 0) {
            _green_zone = static_cast<size_t>(_green_zone * dec_k);
        }
    } else if (update_rs_time < goal_ms && 
               update_rs_processed_buffers > _green_zone) {
        // 太快且有工作可做：增大 green zone（更宽松）
        _green_zone = static_cast<size_t>(MAX2(_green_zone * inc_k, _green_zone + 1.0));
        _green_zone = MIN2(_green_zone, max_green_zone);
    }
    
    // 基于新的 green zone 计算 yellow 和 red
    _yellow_zone = calc_new_yellow_zone(_green_zone, _min_yellow_zone_size);
    _red_zone = calc_new_red_zone(_green_zone, _yellow_zone);
}
```

**自适应逻辑**：

```
自适应调整示例
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

初始状态：
  green=13, yellow=39, red=65
  Update RS 目标时间 = 10ms

场景1：Update RS 耗时 15ms（超过目标）
  → 减小 green zone
  green = 13 × 0.9 = 11
  yellow = 11 × 3 = 33
  red = 33 × 1.67 = 55
  
  效果：更早开始处理，降低 GC 负担

场景2：Update RS 耗时 5ms（低于目标）
  → 增大 green zone
  green = 13 × 1.1 = 14
  yellow = 14 × 3 = 42
  red = 42 × 1.67 = 70
  
  效果：更晚开始处理，减少并发开销
```

---

## 7. 性能优化分析

### 7.1 多级处理策略

```
脏卡处理层级
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Level 1: 并发精炼线程（主要）
  - 应用运行时后台处理
  - 无锁或轻量锁竞争
  - 吞吐量高

Level 2: 应用线程（Mutator Refinement）
  - Red Zone 时触发
  - 写屏障中处理
  - 有性能开销，但保证不溢出

Level 3: GC Update RS 阶段（保底）
  - GC 暂停时处理剩余
  - 必须完成所有脏卡
  - 影响 GC 暂停时间

目标：
  尽量让 Level 1 处理大部分工作
  避免触发 Level 2（应用受影响）
  最小化 Level 3 的工作量（GC 暂停短）
```

### 7.2 缓存效应利用

```cpp
// Green Zone 的目的：利用缓存效应
// 不立即处理脏卡，让同一区域的多次写入合并

示例：
  T1: 写入对象 A 的字段（卡 C1 dirty）
  T2: 写入对象 A 的另一个字段（卡 C1 已经是 dirty）
  
  如果不等待：
    处理 C1 两次（冗余）
    
  如果等待（Green Zone）：
    只处理 C1 一次
    减少 50% 的工作量
```

---

## 8. 常见问题与面试题

### Q1: 三色区域（Green/Yellow/Red）分别代表什么？

**答案**：
| 区域 | 缓冲区数量 | 行为 |
|------|------------|------|
| **Green** | [0, green) | 线程0空闲等待，利用缓存效应 |
| **Yellow** | [green, yellow) | 逐渐激活更多精炼线程 |
| **Red** | [yellow, red) | 所有精炼线程运行，应用线程也可能参与 |

### Q2: 为什么要动态创建线程？

**答案**：
1. **资源节约**：低负载时不需要所有线程
2. **按需扩展**：负载高时动态创建更多线程
3. **启动优化**：减少 JVM 启动时间

### Q3: 自适应调整如何工作？

**答案**：
- **触发时机**：每次 GC 后根据 Update RS 时间调整
- **调整逻辑**：
  - Update RS 太慢 → 减小 green zone（更早处理）
  - Update RS 太快 → 增大 green zone（更晚处理）
- **目标**：让 Update RS 时间接近目标值（默认 GC 暂停时间的 10%）

### Q4: Mutator Refinement 是什么？

**答案**：
- **触发条件**：脏卡队列达到 Red Zone
- **执行者**：应用线程（Mutator）
- **处理方式**：在写屏障中处理脏卡
- **特点**：有性能开销，但防止队列无限增长

---

## 9. 总结

### 9.1 核心设计要点

```
G1ConcurrentRefineThread 设计精髓
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. 三色区域模型
   ├── Green Zone：空闲等待，利用缓存
   ├── Yellow Zone：逐渐激活线程
   └── Red Zone：全力处理，应用参与

2. 动态线程管理
   ├── 初始只创建线程0
   ├── 负载高时动态创建
   └── 链式激活机制

3. 自适应调整
   ├── 基于 Update RS 时间反馈
   ├── 调整三色区域阈值
   └── 平衡并发开销和 GC 负担

4. 多级处理保障
   ├── L1: 并发精炼（主要）
   ├── L2: Mutator Refinement（应急）
   └── L3: GC Update RS（保底）
```

### 9.2 时序图

```
并发精炼线程生命周期
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

JVM 启动
  │
  ▼
创建 G1ConcurrentRefine
  ├── 计算三色区域阈值
  ├── 创建线程0（Primary）
  └── 其他线程延迟创建

应用运行期间
  │
  ▼
写屏障产生脏卡
  │
  ▼
脏卡队列增长
  │
  ├── Green Zone ──→ 线程0等待
  │
  ├── Yellow Zone ──→ 线程0激活
  │             └── 链式激活其他线程
  │
  └── Red Zone ──→ 所有线程运行
              └── 应用线程参与

GC 暂停
  │
  ▼
Update RS 阶段
  └── 处理剩余脏卡

GC 结束
  │
  ▼
adjust() 调整阈值
  └── 自适应优化
```

---

## 参考文档

1. OpenJDK 11: `src/hotspot/share/gc/g1/g1ConcurrentRefine.hpp/cpp`
2. OpenJDK 11: `src/hotspot/share/gc/g1/g1ConcurrentRefineThread.hpp/cpp`
3. G1 论文: Detlefs et al., "Garbage-First Garbage Collection"

---

**文档信息**
- 创建时间: 2026-02-10
- 源码版本: OpenJDK 11
- 分析类型: 专家级源码分析
- 配套技能: Read-BottomUp, JVM-Concurrency-Design, JVM-Optimization-Design
