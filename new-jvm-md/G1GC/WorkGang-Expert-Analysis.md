# WorkGang 专家级源码分析

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

WorkGang 的本质是**GC 并行工作线程池框架**：管理固定数量的 `GangWorker` 线程，通过 `AbstractGangTask` 分发任务；STW 模式下所有 Worker 同步执行同一个任务（`run_task()`），并发模式下 Worker 持续等待新任务；`WorkGang` 是 G1 所有并行 GC 操作（Root 扫描/对象复制/RSet 更新等）的执行引擎。

### 0.2 为什么需要？

GC 的各个阶段（Root 扫描/Evacuation/RSet 更新）都可以并行化，但需要一个统一的线程池管理框架：(1) 避免每次 GC 都创建/销毁线程（代价高）；(2) 提供统一的任务分发接口；(3) 支持 STW 和并发两种执行模式。WorkGang 提供这个框架。

### 0.3 怎么解决？

**预创建线程 + 任务队列**：JVM 启动时创建 `ParallelGCThreads` 个 `GangWorker` 线程，这些线程在 `loop()` 中等待任务；`run_task(task)` 将任务分发给所有 Worker，Worker 调用 `task->work(worker_id)` 执行；所有 Worker 完成后 `run_task()` 返回（STW 模式下等待所有 Worker 完成）。

### 0.4 为什么这样设计？

- **为什么 Worker 数量等于 `ParallelGCThreads`？** `ParallelGCThreads` 默认等于 CPU 核数（或 `min(8, cpu_count * 5/8)`），充分利用多核并行；Worker 数量固定避免动态创建线程的开销
- **为什么 `work(worker_id)` 传入 worker_id？** 任务可以根据 worker_id 分配不同的工作范围（如 Worker 0 处理 Region 0-99，Worker 1 处理 Region 100-199），实现静态负载分配；动态负载均衡通过 Work Stealing 补充

---

## 一、宏观理解：GC 并行工作线程池

### 1.1 一句话总结

**WorkGang 是 JVM GC 的并行工作线程池框架**，负责管理 GC 工作线程的生命周期、任务分发和同步协调，支持 STW（Stop-The-World）并行 GC 和并发 GC 两种模式。

### 1.2 为什么需要 WorkGang？

**问题背景**：
- 现代服务器有数十个 CPU 核心
- 单线程 GC 无法充分利用多核性能
- 需要并行执行 GC 任务（标记、复制、清理等）
- 需要协调多线程之间的同步和负载均衡

**解决方案**：
- WorkGang 提供一个通用的并行任务执行框架
- 支持动态线程数调整
- 提供任务分发和同步机制
- 统一的线程管理和监控

### 1.3 核心设计思想

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         WorkGang 设计思想                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  主从架构（Master-Worker）                                                    │
│  ─────────────────────────                                                    │
│                                                                              │
│  协调者线程（Coordinator）                    工作者线程（Workers）           │
│        │                                         │                           │
│        │ 1. 准备任务                             │                           │
│        ▼                                         │                           │
│  ┌─────────────┐                                 │                           │
│  │ run_task()  │─────────────────────────────────┼──> 唤醒工作者             │
│  │             │                                 │                           │
│  │ 2. 分发任务 │                                 │                           │
│  │ dispatcher  │─────────────────────────────────┼──> 获取任务并执行         │
│  │ .coordinator│                                 │    work(worker_id)        │
│  │ _execute_   │                                 │                           │
│  │ on_workers()│                                 │                           │
│  └─────────────┘                                 │                           │
│        │                                         │                           │
│        │ 3. 等待完成                             │                           │
│        │ <────────────────────────────────────────┼──> 通知完成               │
│        │                                         │    signal_task_done()     │
│        ▼                                         │                           │
│  ┌─────────────┐                                 │                           │
│  │ 任务完成    │                                 │                           │
│  └─────────────┘                                 │                           │
│                                                                              │
│  ═══════════════════════════════════════════════════════════════════════    │
│                                                                              │
│  两种实现方式：                                                               │
│  ─────────────                                                                │
│  1. SemaphoreGangTaskDispatcher (默认)                                        │
│     - 使用信号量进行同步                                                      │
│     - 低延迟，唤醒线程时无需重新获取锁                                        │
│                                                                              │
│  2. MutexGangTaskDispatcher                                                   │
│     - 使用互斥锁 + 条件变量                                                   │
│     - 更传统的实现                                                            │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.4 在 G1 中的应用

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      WorkGang 在 G1 中的应用                                 │
└─────────────────────────────────────────────────────────────────────────────┘

G1CollectedHeap
        │
        ├──> WorkGang* _workers  // STW 并行工作线程池
        │       ├──> Young GC 并行 Evacuation
        │       ├──> Mixed GC 并行标记和复制
        │       └──> Full GC 并行压缩
        │
        └──> WorkGang* _concurrent_workers  // 并发标记线程池
                └──> 并发标记周期（Concurrent Mark Cycle）

使用示例：
┌─────────────────────────────────────────────────────────────────────────┐
│  // Young GC 启动并行任务                                                │
│  G1ParTask g1_par_task(g1h, per_thread_states);                         │
│  _workers->run_task(&g1_par_task);  // 使用所有活跃线程                  │
│                                                                         │
│  // 在 G1ParTask::work(worker_id) 中                                   │
│  G1ParScanThreadState* pss = per_thread_states->state_for_worker(worker_id);
│  G1RootProcessor root_processor(g1h, n_workers);                        │
│  root_processor.evacuate_roots(pss, worker_id);  // 每个线程执行         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 二、字段分析：数据结构的完整解剖

### 2.1 类继承关系

```
Class 继承关系：

AbstractGangTask           // 任务基类
    └── 用户自定义任务（如 G1ParTask）

GangTaskDispatcher         // 任务分发器接口
    ├── SemaphoreGangTaskDispatcher  // 信号量实现
    └── MutexGangTaskDispatcher      // 互斥锁实现

AbstractWorkGang           // 工作线程池基类
    └── WorkGang                   // 具体实现

WorkerThread               // 工作线程基类
    └── AbstractGangWorker
            └── GangWorker       // 具体工作线程

StackObj                   // 栈对象基类
    ├── WorkGangBarrierSync      // 线程屏障同步
    ├── WithUpdatedActiveWorkers // 临时调整活跃线程数
    └── SequentialSubTasksDone   // 顺序任务认领

CHeapObj                   // 堆对象基类
    ├── SubTasksDone             // 子任务认领管理
    └── GangTaskDispatcher
```

### 2.2 WorkGang 核心字段

```cpp
// workgroup.hpp:226-254
class WorkGang: public AbstractWorkGang {
    GangTaskDispatcher* const _dispatcher;  // 任务分发器（核心）
    
public:
    WorkGang(const char* name,
             uint workers,
             bool are_GC_task_threads,
             bool are_ConcurrentGC_threads);
    
    void run_task(AbstractGangTask* task);
    void run_task(AbstractGangTask* task, uint num_workers, bool add_foreground_work = false);
};
```

**AbstractWorkGang 字段**（workgroup.hpp:110-202）：
```cpp
class AbstractWorkGang : public CHeapObj<mtInternal> {
protected:
    AbstractGangWorker** _workers;     // 工作线程指针数组
    uint _total_workers;               // 最大线程数
    uint _active_workers;              // 当前活跃线程数
    uint _created_workers;             // 已创建的线程数
    const char* _name;                 // 线程组名称
    
    const bool _are_GC_task_threads;      // 是否是 STW GC 线程
    const bool _are_ConcurrentGC_threads; // 是否是并发 GC 线程
};
```

**线程数关系**：
```
_created_workers <= _active_workers <= _total_workers

示例（8核系统）：
    _total_workers = 8      (最大8个线程)
    _active_workers = 4     (当前使用4个)
    _created_workers = 4    (已创建4个线程)

动态扩展（UseDynamicNumberOfGCThreads）：
    - 初始：_active_workers = 1
    - 需要时：增加到 _total_workers
```

### 2.3 GangTaskDispatcher —— 任务分发器

**接口定义**（workgroup.hpp:85-105）：
```cpp
class GangTaskDispatcher : public CHeapObj<mtGC> {
public:
    // 协调者 API：主线程调用
    virtual void coordinator_execute_on_workers(AbstractGangTask* task, 
                                                 uint num_workers,
                                                 bool add_foreground_work) = 0;
    
    // 工作者 API：工作线程调用
    virtual WorkData worker_wait_for_task() = 0;    // 等待任务
    virtual void worker_done_with_task() = 0;       // 通知完成
};
```

**信号量实现**（workgroup.cpp:142-210）：
```cpp
class SemaphoreGangTaskDispatcher : public GangTaskDispatcher {
    AbstractGangTask* _task;           // 当前任务
    volatile uint _started;            // 已启动的工作者数
    volatile uint _not_finished;       // 未完成的工作者数
    Semaphore* _start_semaphore;       // 启动信号量
    Semaphore* _end_semaphore;         // 完成信号量
};
```

**信号量实现的优势**：
```
┌─────────────────────────────────────────────────────────────────┐
│              Semaphore vs Mutex 的对比                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Mutex 实现：                                                     │
│  ──────────                                                       │
│  1. 主线程：notify_all() 唤醒所有工作者                          │
│  2. 工作者：被唤醒后需要重新竞争获取锁                            │
│  3. 问题：大量线程同时竞争，产生锁争用                            │
│                                                                  │
│  Semaphore 实现：                                                 │
│  ────────────────                                                 │
│  1. 主线程：signal(num_workers) 发送 n 个信号                    │
│  2. 工作者：wait() 直接获取信号，无需重新竞争锁                   │
│  3. 优势：更低的唤醒延迟，减少锁争用                              │
│                                                                  │
│  性能对比：                                                       │
│  - 信号量：O(1) 唤醒，无锁竞争                                    │
│  - 互斥锁：O(n) 唤醒，需要重新获取锁                              │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 2.4 GangWorker —— 工作线程

**定义**（workgroup.hpp:279-292）：
```cpp
class GangWorker: public AbstractGangWorker {
public:
    GangWorker(WorkGang* gang, uint id) : AbstractGangWorker(gang, id) {}

protected:
    virtual void loop();  // 主循环
    
private:
    WorkData wait_for_task();       // 等待任务
    void run_task(WorkData work);   // 执行任务
    void signal_task_done();        // 通知完成
};
```

**主循环**（workgroup.cpp:377-385）：
```cpp
void GangWorker::loop() {
    while (true) {
        WorkData data = wait_for_task();    // 阻塞等待任务
        run_task(data);                      // 执行任务
        signal_task_done();                  // 通知完成
    }
}
```

### 2.5 SubTasksDone —— 子任务认领管理

**作用**：管理一组子任务的认领状态，用于并行任务分配。

**使用场景**：G1RootProcessor 中的 13 个根来源任务

```cpp
// workgroup.hpp:341-377
class SubTasksDone: public CHeapObj<mtInternal> {
    volatile uint* _tasks;             // 任务状态数组（0=未认领，1=已认领）
    uint _n_tasks;                     // 任务总数
    volatile uint _threads_completed;  // 完成任务的线程数
};
```

**核心方法**：
```cpp
// 尝试认领任务 t，返回 true 表示已被其他线程认领
bool is_task_claimed(uint t) {
    uint old = Atomic::cmpxchg(1u, &_tasks[t], 0u);
    return old != 0;  // old==0 表示成功认领
}

// 通知所有任务已完成
void all_tasks_completed(uint n_threads);
```

---

## 三、方法分析：任务执行流程详解

### 3.1 任务执行完整流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      WorkGang 任务执行完整流程                               │
└─────────────────────────────────────────────────────────────────────────────┘

主线程（Coordinator）                              工作线程（Workers）
        │                                               │
        │ 1. 准备任务                                    │
        ▼                                               │
┌───────────────────┐                                   │
│ AbstractGangTask  │                                   │
│ - G1ParTask       │                                   │
│ - G1EvacuateTask  │                                   │
│ - ...             │                                   │
└─────────┬─────────┘                                   │
          │                                             │
          ▼                                             │
┌─────────────────────────────────────────────────────────────────────────┐
│ WorkGang::run_task(task, num_workers)                                   │
│   │                                                                      │
│   ├── 2. 更新活跃线程数                                                   │
│   │   update_active_workers(num_workers)                                │
│   │                                                                      │
│   ├── 3. 分发任务                                                         │
│   ▼   _dispatcher->coordinator_execute_on_workers(task, num_workers)    │
│                                                                          │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │ SemaphoreGangTaskDispatcher::coordinator_execute_on_workers()   │   │
│   │   │                                                             │   │
│   │   ├── _task = task;                                             │   │
│   │   ├── _not_finished = num_workers;                              │   │
│   │   └── _start_semaphore->signal(num_workers);  ────────────────┼───┼──> 唤醒工作者
│   │       │                                                         │   │
│   │       ▼                                                         │   │
│   │   ┌─────────────────────────────────────────────────────────┐   │   │
│   │   │ run_foreground_task_if_needed()                          │   │   │
│   │   │ （可选：主线程也参与执行）                                 │   │   │
│   │   └─────────────────────────────────────────────────────────┘   │   │
│   │       │                                                         │   │
│   │       ▼                                                         │   │
│   │   _end_semaphore->wait();  <────────────────────────────────────┼───┼──> 等待完成
│   │       │                                                         │   │
│   │       ▼                                                         │   │
│   │   所有工作者完成                                                 │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘

工作线程执行流程：
┌─────────────────────────────────────────────────────────────────────────┐
│ GangWorker::loop()                                                       │
│   │                                                                      │
│   ├── wait_for_task()  <───────────────────────────────────────────────┤
│   │   └── _start_semaphore->wait();  // 等待任务                        │
│   │                                                                      │
│   ├── run_task(WorkData data)                                           │
│   │   └── data._task->work(data._worker_id);  // 执行具体任务           │
│   │       └── G1ParTask::work(worker_id)                                │
│   │           └── G1ParScanThreadState...                               │
│   │                                                                      │
│   └── signal_task_done()  ────────────────────────────────────────────┤
│       └── _end_semaphore->signal();  // 通知完成                        │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.2 线程创建和初始化

**WorkGang 初始化**（workgroup.cpp:47-58）：
```cpp
void AbstractWorkGang::initialize_workers() {
    // 1. 分配工作者指针数组
    _workers = NEW_C_HEAP_ARRAY(AbstractGangWorker*, total_workers(), mtInternal);
    
    // 2. 添加工作者线程
    add_workers(true);
}
```

**添加工作者**（workgroup.cpp:71-99）：
```cpp
void AbstractWorkGang::add_workers(uint active_workers, bool initializing) {
    // 确定线程类型
    os::ThreadType worker_type;
    if (are_ConcurrentGC_threads()) {
        worker_type = os::cgc_thread;  // 并发 GC 线程
    } else {
        worker_type = os::pgc_thread;  // 并行 GC 线程
    }
    
    // 创建线程
    _created_workers = WorkerManager::add_workers(
        this, active_workers, _total_workers, _created_workers, 
        worker_type, initializing);
    
    _active_workers = MIN2(_created_workers, _active_workers);
}
```

**工作者线程初始化**（workgroup.cpp:329-343）：
```cpp
void AbstractGangWorker::run() {
    initialize();
    loop();
}

void AbstractGangWorker::initialize() {
    initialize_named_thread();
    os::set_priority(this, NearMaxPriority);  // 设置高优先级
}
```

### 3.3 线程屏障同步

**WorkGangBarrierSync**（workgroup.hpp:298-335）：

用于多线程之间的同步点（如所有线程完成某个阶段后，再进入下一阶段）。

```cpp
class WorkGangBarrierSync : public StackObj {
    Monitor _monitor;
    uint _n_workers;         // 总线程数
    uint _n_completed;       // 已完成进入的线程数
    bool _should_reset;      // 是否需要重置
    bool _aborted;           // 是否中止
};
```

**使用示例**：
```cpp
WorkGangBarrierSync barrier(n_workers, "GC Barrier");

// 每个线程执行：
void worker_task() {
    // 阶段 1 工作
    do_phase1_work();
    
    // 到达屏障，等待其他线程
    barrier.enter();
    
    // 阶段 2 工作（所有线程都已完成阶段 1）
    do_phase2_work();
}
```

---

## 四、关联分析：组件交互图

### 4.1 完整交互关系

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      WorkGang 组件交互关系图                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                         G1CollectedHeap                                │  │
│  │                                                                        │  │
│  │  ┌──────────────────┐    ┌──────────────────┐                         │  │
│  │  │ _workers         │    │ _concurrent_workers│                       │  │
│  │  │ (STW WorkGang)   │    │ (Concurrent WorkGang)│                     │  │
│  │  └────────┬─────────┘    └────────┬─────────┘                         │  │
│  │           │                       │                                    │  │
│  │           │ run_task()            │ run_task()                        │  │
│  └───────────┼───────────────────────┼────────────────────────────────────┘  │
│              │                       │                                         │
│              ▼                       ▼                                         │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                         WorkGang                                       │  │
│  │                                                                        │  │
│  │  ┌───────────────────────────────────────────────────────────────┐   │  │
│  │  │                    GangTaskDispatcher                          │   │  │
│  │  │                    (Semaphore/Mutex)                           │   │  │
│  │  │                        │                                       │   │  │
│  │  │      ┌─────────────────┼─────────────────┐                     │   │  │
│  │  │      │                 │                 │                     │   │  │
│  │  │      ▼                 ▼                 ▼                     │   │  │
│  │  │  coordinator     worker_wait_     worker_done_                │   │  │
│  │  │  _execute_       for_task()       with_task()                 │   │  │
│  │  │  _on_workers()                                                   │   │  │
│  │  └───────────────────────────────────────────────────────────────┘   │  │
│  │                                                                        │  │
│  │  ┌───────────┐  ┌───────────┐  ┌───────────┐                        │  │
│  │  │GangWorker0│  │GangWorker1│  │GangWorkerN│                        │  │
│  │  │  Thread   │  │  Thread   │  │  Thread   │                        │  │
│  │  └─────┬─────┘  └─────┬─────┘  └─────┬─────┘                        │  │
│  │        │              │              │                               │  │
│  │        └──────────────┼──────────────┘                               │  │
│  │                       │                                              │  │
│  │                       ▼                                              │  │
│  │              AbstractGangTask::work(worker_id)                       │  │
│  │                       │                                              │  │
│  │                       ▼                                              │  │
│  │              ┌─────────────────┐                                     │  │
│  │              │ G1ParTask::work()│                                     │  │
│  │              │ G1Evacuate...    │                                     │  │
│  │              │ G1RebuildRS...   │                                     │  │
│  │              └─────────────────┘                                     │  │
│  │                                                                        │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 与 G1ParScanThreadState 的协作

```
┌─────────────────────────────────────────────────────────────────────────────┐
│              WorkGang 与 G1ParScanThreadState 协作流程                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  阶段 1：准备                                                                │
│  ───────────                                                                 │
│  G1CollectedHeap::do_collection_pause_at_safepoint()                         │
│       │                                                                      │
│       ├──> G1ParScanThreadStateSet pss_set(g1h, n_workers, young_length)    │
│       │       └── 为每个线程创建 G1ParScanThreadState                        │
│       │                                                                      │
│       └──> G1ParTask g1_par_task(g1h, &pss_set)                             │
│                                                                              │
│  阶段 2：执行                                                                │
│  ───────────                                                                 │
│  _workers->run_task(&g1_par_task)                                            │
│       │                                                                      │
│       ├──> 唤醒 n_workers 个 GangWorker                                     │
│       │                                                                      │
│       └──> 每个 GangWorker 执行 G1ParTask::work(worker_id)                  │
│               │                                                              │
│               ├──> G1ParScanThreadState* pss = pss_set.state_for_worker(id) │
│               │                                                              │
│               ├──> G1RootProcessor root_processor(g1h, n_workers)           │
│               │       └── evacuate_roots(pss, worker_id)                    │
│               │                                                              │
│               └──> G1ParEvacuateFollowersClosure                            │
│                       └── trim_queue()                                       │
│                                                                              │
│  阶段 3：完成                                                                │
│  ───────────                                                                 │
│  所有 GangWorker 完成                                                        │
│       │                                                                      │
│       └──> pss_set.flush()                                                   │
│               └── 合并各线程统计信息                                         │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 五、验证总结：日志与调试

### 5.1 关键日志输出

**启用工作线程日志**：
```bash
java -Xlog:gc+workgang=debug,gc+task=trace \
     -Xms8g -Xmx8g -XX:+UseG1GC \
     -jar application.jar
```

**典型日志**：
```
# 线程创建日志
[0.023s][debug][gc,workgang] Constructing work gang G1 Main with 8 threads
[0.045s][debug][gc,workgang] Constructing work gang G1 Conc with 3 threads

# 任务执行日志
[15.234s][trace][gc,workgang] Running work gang: G1 Main task: G1ParTask worker: 0
[15.234s][trace][gc,workgang] Running work gang: G1 Main task: G1ParTask worker: 1
[15.235s][trace][gc,workgang] Finished work gang: G1 Main task: G1ParTask worker: 0
[15.236s][trace][gc,workgang] Finished work gang: G1 Main task: G1ParTask worker: 1

# 活跃线程数调整
[20.456s][trace][gc,task] G1 Main: using 4 out of 8 workers
```

### 5.2 监控指标

| 指标 | 查看方法 | 健康范围 |
|-----|---------|---------|
| 活跃线程数 | `_active_workers` | <= `_total_workers` |
| 任务执行时间 | GC 日志 | 根据任务类型 |
| 线程同步延迟 | 代码中测量 | 尽可能小 |

---

## 六、总结

### 6.1 WorkGang 的核心价值

WorkGang 实现了 JVM GC 的**通用并行任务执行框架**：

1. **线程池管理**：统一管理 GC 工作线程的生命周期
2. **任务分发**：支持主从模式的任务分发
3. **同步机制**：提供信号量和互斥锁两种同步实现
4. **负载均衡**：通过 SubTasksDone 实现任务认领

### 6.2 关键设计要点

| 设计点 | 说明 |
|-------|------|
| **信号量同步** | 默认使用信号量，降低线程唤醒延迟 |
| **任务认领** | SubTasksDone 实现动态任务分配 |
| **线程屏障** | WorkGangBarrierSync 实现多阶段同步 |
| **动态线程数** | 支持运行时调整活跃线程数 |

### 6.3 学习路径回顾

```
G1CollectedHeap::initialize() ──> 堆初始化
    ├── WorkGang ──> GC 工作线程池（当前）
    │       ├── AbstractWorkGang ──> 线程池管理
    │       ├── GangTaskDispatcher ──> 任务分发
    │       ├── GangWorker ──> 工作线程
    │       └── SubTasksDone ──> 任务认领
    │
    ├── G1RootProcessor ──> 根处理
    ├── G1ParScanThreadState ──> 并行 Evacuation
    └── ...
```

**基础架构层已完成！** 现在 Young GC 的核心组件已经基本分析完毕。

---

**文档信息**：
- 分析版本：OpenJDK 11
- 分析日期：2026-02-10
- 源码路径：
  - `/data/workspace/openjdk-cut-new/src/hotspot/share/gc/shared/workgroup.hpp`
  - `/data/workspace/openjdk-cut-new/src/hotspot/share/gc/shared/workgroup.cpp`
