# Ch03: WorkGang/GangWorker — JVM 内部线程池深度分析

> **标准环境**: `-Xms8g -Xmx8g -XX:+UseG1GC`, 16 核机器, Region 4MB
> **前置文档**: `Universe/E.1-WorkGang.md`（创建初始化）、`Thread/ch01_thread_start_complete_flow.md`
> **源码路径**: `src/hotspot/share/gc/shared/workgroup.hpp/cpp`、`workerManager.hpp`

---

## 1. 解决什么问题？

JVM 的垃圾回收器需要**并行处理**大量工作（扫描根、复制对象、标记存活对象等）。如果这些工作全部由单线程完成，GC 停顿时间会非常长。

**核心问题**：如何高效地将 GC 任务分配给多个工作线程并行执行，并在所有线程完成后汇合？

**JVM 的解决方案**：WorkGang — 一个专门为 GC 设计的**内部线程池**。

与 Java 层的 `ThreadPoolExecutor` 不同，WorkGang 有以下特点：
1. **无任务队列** — 不是"提交任务到队列"，而是"广播同一个任务给所有 worker"
2. **全员同步** — 必须等所有 worker 完成才继续
3. **worker_id 分工** — 每个 worker 拿到不同的 worker_id，各自处理不同的数据分区
4. **懒创建** — 默认只创建 1 个线程，需要时再扩容（`UseDynamicNumberOfGCThreads=true`）

---

## 2. 完整类继承体系

```
Thread (os_thread 包装)
  └── NamedThread (_name 字段)
       └── WorkerThread (_id 字段, 858 行 thread.hpp)
            └── AbstractGangWorker (_gang 指向 AbstractWorkGang)
                 └── GangWorker (真正的工作线程)

CHeapObj<mtInternal>
  └── AbstractWorkGang (管理 worker 数组 + 线程计数)
       └── WorkGang (持有 GangTaskDispatcher, 任务分发)

CHeapObj<mtGC>
  └── GangTaskDispatcher (接口: 协调者 API + 工作者 API)
       ├── SemaphoreGangTaskDispatcher (信号量实现，默认)
       └── MutexGangTaskDispatcher (互斥锁 + 条件变量实现)
```

### 2.1 WorkerThread 基类 (thread.hpp:858)

```cpp
class WorkerThread: public NamedThread {
 private:
  uint _id;  // 工作线程编号
 public:
  WorkerThread() : _id(0) { }
  virtual bool is_Worker_thread() const { return true; }
  void set_id(uint work_id) { _id = work_id; }
  uint id() const { return _id; }
};
```

**极简设计**：只增加了一个 `_id` 字段。这个 `_id` 不是 OS 线程 ID，而是在 WorkGang 中的**逻辑编号**（0, 1, 2, ...）。

### 2.2 AbstractGangWorker

```cpp
class AbstractGangWorker: public WorkerThread {
protected:
  AbstractWorkGang* _gang;  // 指向所属的线程池

  virtual void initialize();  // 设置线程名称、优先级
  virtual void loop() = 0;   // 纯虚函数，子类实现主循环

public:
  virtual void run() {
    initialize();  // 初始化线程
    loop();        // 进入主循环（永远不返回）
  }
};
```

**关键点**：`run()` 方法是线程的入口。`loop()` 是一个**无限循环**——线程创建后就永远在循环中等待任务、执行任务、等待下一个任务。

### 2.3 GangWorker — 核心工作循环

```cpp
class GangWorker: public AbstractGangWorker {
protected:
  void loop() override {
    while (true) {
      WorkData data = wait_for_task();  // ① 阻塞等待任务
      run_task(data);                    // ② 执行任务
      signal_task_done();                // ③ 通知完成
    }
  }
private:
  WorkData wait_for_task() {
    return gang()->dispatcher()->worker_wait_for_task();  // 委托给 Dispatcher
  }
  void run_task(WorkData data) {
    GCIdMark gc_id_mark(data._task->gc_id());
    data._task->work(data._worker_id);  // 调用任务的 work() 方法
  }
  void signal_task_done() {
    gang()->dispatcher()->worker_done_with_task();  // 委托给 Dispatcher
  }
};
```

**这是整个线程池的核心循环**：
1. **wait_for_task()** — 阻塞在信号量/Monitor 上，等待协调者分发任务
2. **run_task(data)** — 拿到 `WorkData{task, worker_id}`，调用 `task->work(worker_id)`
3. **signal_task_done()** — 通知协调者"我完成了"

---

## 3. 任务分发器 — 两种实现深度对比

任务分发器是 WorkGang 的核心同步组件，负责**协调者线程**（通常是 VMThread）和**工作者线程**（GangWorker）之间的通信。

### 3.1 GangTaskDispatcher 接口

```cpp
class GangTaskDispatcher : public CHeapObj<mtGC> {
public:
  // 协调者 API — 主线程调用
  virtual void coordinator_execute_on_workers(AbstractGangTask* task, 
                                              uint num_workers,
                                              bool add_foreground_work) = 0;
  // 工作者 API — GangWorker 线程调用
  virtual WorkData worker_wait_for_task() = 0;
  virtual void     worker_done_with_task() = 0;
};
```

### 3.2 选择策略

```cpp
static GangTaskDispatcher* create_dispatcher() {
  if (UseSemaphoreGCThreadsSynchronization) {  // 默认 true
    return new SemaphoreGangTaskDispatcher();   // ← 默认使用信号量
  }
  return new MutexGangTaskDispatcher();          // 备选：Monitor
}
```

`UseSemaphoreGCThreadsSynchronization` 默认值为 `true`（`gc_globals.hpp:214`），即**默认使用信号量实现**。


### 3.3 SemaphoreGangTaskDispatcher（默认实现）

这是性能更高的实现。核心思想：**用信号量代替 Monitor，避免 worker 唤醒时重新竞争锁**。

#### 3.3.1 数据结构

```cpp
class SemaphoreGangTaskDispatcher : public GangTaskDispatcher {
  AbstractGangTask* _task;       // 当前要执行的任务
  volatile uint _started;        // 已启动的 worker 数（CAS 递增，用于分配 worker_id）
  volatile uint _not_finished;   // 未完成的 worker 数（CAS 递减）
  Semaphore* _start_semaphore;   // 启动信号量 — 协调者 signal(N)，worker wait()
  Semaphore* _end_semaphore;     // 结束信号量 — 最后一个 worker signal(1)，协调者 wait()
};
```

【GDB 验证】sizeof(SemaphoreGangTaskDispatcher) = **40 bytes**

#### 3.3.2 协调者端：分发任务

```cpp
void coordinator_execute_on_workers(AbstractGangTask* task, uint num_workers,
                                    bool add_foreground_work) {
  // ① 设置共享状态
  _task         = task;           // worker 将从这里读取任务
  _not_finished = num_workers;    // 倒计数器

  // ② 信号量 signal(N) — 唤醒 N 个 worker
  _start_semaphore->signal(num_workers);

  // ③ 可选：前台线程也参与执行
  run_foreground_task_if_needed(task, num_workers, add_foreground_work);

  // ④ 等待最后一个 worker 完成
  _end_semaphore->wait();  // 阻塞，直到最后一个 worker signal

  // ⑤ 清理状态
  assert(_not_finished == 0, "...");
  _task    = NULL;
  _started = 0;
}
```

#### 3.3.3 工作者端：等待与完成

```cpp
WorkData worker_wait_for_task() {
  // ① 阻塞等待启动信号
  _start_semaphore->wait();

  // ② 原子递增 _started，获取 worker_id
  uint num_started = Atomic::add(1u, &_started);
  uint worker_id = num_started - 1;  // 从 0 开始

  return WorkData(_task, worker_id);
}

void worker_done_with_task() {
  // ③ 原子递减 _not_finished
  uint not_finished = Atomic::sub(1u, &_not_finished);

  // ④ 最后一个完成的 worker 唤醒协调者
  if (not_finished == 0) {
    _end_semaphore->signal();
  }
}
```

#### 3.3.4 时序图

```
时间    协调者 (VMThread)              GangWorker#0         GangWorker#1         GangWorker#2
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
T0     _task = G1ParTask              wait()阻塞           wait()阻塞           wait()阻塞
       _not_finished = 3
       _start_semaphore->signal(3)
         │
T1     │                              被唤醒               被唤醒               被唤醒
       │                              _started CAS: 0→1   _started CAS: 1→2   _started CAS: 2→3
       │                              worker_id=0          worker_id=1          worker_id=2
       │                              task->work(0)        task->work(1)        task->work(2)
       │                                │                    │                    │
       _end_semaphore->wait()           │                    │                    │
         │阻塞                          │                    │                    │
T2     │                              完成                 │                    │
       │                              _not_finished: 3→2   │                    │
       │                              (非0,不signal)        │                    │
T3     │                                                   完成                 │
       │                                                   _not_finished: 2→1   │
       │                                                   (非0,不signal)        │
T4     │                                                                        完成
       │                                                                        _not_finished: 1→0
       │                                                                        _end_semaphore->signal()
         │                                                                        │
T5     被唤醒 ◀────────────────────────────────────────────────────────────────────┘
       _task = NULL
       _started = 0
       继续执行...
```

### 3.4 MutexGangTaskDispatcher（备选实现）

使用传统的 Monitor（互斥锁 + 条件变量）实现。

#### 3.4.1 数据结构

```cpp
class MutexGangTaskDispatcher : public GangTaskDispatcher {
  AbstractGangTask* _task;
  volatile uint _started;     // 已开始执行的 worker 数
  volatile uint _finished;    // 已完成的 worker 数
  volatile uint _num_workers; // 本轮需要的 worker 数
  Monitor* _monitor;          // 互斥锁 + 条件变量
};
```

#### 3.4.2 协调者端

```cpp
void coordinator_execute_on_workers(AbstractGangTask* task, uint num_workers,
                                    bool add_foreground_work) {
  MutexLockerEx ml(_monitor, Mutex::_no_safepoint_check_flag);  // 加锁

  _task        = task;
  _num_workers = num_workers;

  _monitor->notify_all();  // 唤醒所有 worker

  run_foreground_task_if_needed(task, num_workers, add_foreground_work);

  // 等待所有 worker 完成
  while (_finished < _num_workers) {
    _monitor->wait(true);  // no_safepoint_check
  }

  // 清理
  _task = NULL; _num_workers = 0; _started = 0; _finished = 0;
}
```

#### 3.4.3 工作者端

```cpp
WorkData worker_wait_for_task() {
  MonitorLockerEx ml(_monitor, Mutex::_no_safepoint_check_flag);

  // 等待条件：有任务 且 还有名额
  while (_num_workers == 0 || _started == _num_workers) {
    _monitor->wait(true);
  }

  _started++;
  uint worker_id = _started - 1;
  return WorkData(_task, worker_id);
}

void worker_done_with_task() {
  MonitorLockerEx ml(_monitor, Mutex::_no_safepoint_check_flag);

  _finished++;
  if (_finished == _num_workers) {
    _monitor->notify_all();  // 唤醒协调者 + 所有等待的 worker
  }
}
```

### 3.5 两种实现对比

| 维度 | SemaphoreGangTaskDispatcher | MutexGangTaskDispatcher |
|------|---------------------------|------------------------|
| **同步原语** | 两个 Semaphore | 一个 Monitor |
| **worker_id 分配** | `Atomic::add` (lock-free) | `_started++` (持锁) |
| **唤醒延迟** | 低：信号量 wait 返回后无需重新竞争锁 | 高：wait 返回后需重新获取 Monitor 锁 |
| **完成通知** | 最后一个 worker signal(1) | `_finished++` + notify_all（惊群） |
| **锁竞争** | 无锁（CAS） | 有锁（Monitor） |
| **适用场景** | 高并行（默认） | 调试/兼容 |
| **sizeof** | 40 bytes | 更大（含 Monitor） |
| **JVM 参数** | `UseSemaphoreGCThreadsSynchronization=true` | `=false` |

**为什么信号量更快？**

关键在于 **worker 被唤醒后的行为差异**：
- **Semaphore**：`wait()` 返回后直接执行，不需要竞争任何锁
- **Monitor**：`wait()` 返回后必须**重新获取 Monitor 锁**，多个 worker 同时被 notify_all 唤醒会产生**锁竞争**

在 GC 场景下，13 个 worker 同时被唤醒去执行任务，如果每个都要先竞争同一个锁，会导致不必要的延迟。


---

## 4. 辅助同步原语

WorkGang 体系还提供了三个辅助同步工具，用于**任务内部**的子任务划分。

### 4.1 WorkGangBarrierSync — 屏障同步

**解决什么问题**：多个 worker 执行到某个阶段后，需要等所有 worker 都到达同一点，才能继续下一阶段。

```
Worker#0  ──────▶ │barrier│ ─等待─────────────────▶ 继续
Worker#1  ────────────────▶ │barrier│ ─等待────────▶ 继续
Worker#2  ──────────────────────────▶ │barrier│ ──▶ 继续（最后到达，唤醒所有人）
```

**核心实现**：

```cpp
class WorkGangBarrierSync : public StackObj {
  Monitor _monitor;
  uint    _n_workers;     // 预期到达的 worker 数
  uint    _n_completed;   // 已到达的 worker 数
  bool    _should_reset;  // 延迟重置标志
  bool    _aborted;       // 中止标志
};
```

```cpp
bool WorkGangBarrierSync::enter() {
  MutexLockerEx x(monitor(), Mutex::_no_safepoint_check_flag);
  
  if (should_reset()) {
    zero_completed();       // 第一个进入的 worker 重置计数
    set_should_reset(false);
  }
  
  inc_completed();
  
  if (n_completed() == n_workers()) {
    // 最后一个到达 — 设置延迟重置标志，唤醒所有人
    set_should_reset(true);
    monitor()->notify_all();
  } else {
    // 不是最后一个 — 等待
    while (n_completed() != n_workers() && !aborted()) {
      monitor()->wait(true);
    }
  }
  return !aborted();
}
```

**为什么不直接将 `_n_completed` 重置为 0？**

因为 `notify_all()` 后，其他 worker 可能还没从 `wait()` 返回。如果这时 `_n_completed` 已经被清零，那些 worker 醒来后发现 `n_completed() != n_workers()`，会重新进入等待。所以用 `_should_reset` 延迟到**下一轮第一个 worker 进入时**才重置。

【GDB 验证】sizeof(WorkGangBarrierSync) = **176 bytes**（主要是内嵌的 Monitor 对象）

### 4.2 SubTasksDone — 子任务认领

**解决什么问题**：有 N 个不同的子任务（比如"扫描 StringTable"、"扫描 JNI Handles"），每个子任务只需要一个 worker 执行，不需要重复做。

```cpp
class SubTasksDone : public CHeapObj<mtInternal> {
  volatile uint* _tasks;         // 子任务数组，0=未认领，1=已认领
  uint _n_tasks;                 // 子任务总数
  volatile uint _threads_completed;  // 已完成报到的线程数
};
```

**认领机制（CAS）**：

```cpp
bool SubTasksDone::is_task_claimed(uint t) {
  uint old = _tasks[t];
  if (old == 0) {
    old = Atomic::cmpxchg(1u, &_tasks[t], 0u);  // CAS: 0→1
  }
  return old != 0;  // true = 已被别人认领，false = 认领成功
}
```

**使用模式**：

```cpp
// 典型用法（多个 worker 并行执行）
void work(uint worker_id) {
  if (!_sub_tasks.is_task_claimed(TASK_SCAN_STRING_TABLE)) {
    // 只有第一个 CAS 成功的 worker 会执行
    scan_string_table();
  }
  if (!_sub_tasks.is_task_claimed(TASK_SCAN_JNI_HANDLES)) {
    scan_jni_handles();
  }
  // ... 更多子任务
  _sub_tasks.all_tasks_completed(num_workers);  // 报到
}
```

【GDB 验证】sizeof(SubTasksDone) = **32 bytes**

### 4.3 SequentialSubTasksDone — 顺序子任务认领

**解决什么问题**：有 N 个**连续编号**的子任务（比如遍历 0~2047 号 HeapRegion），多个 worker 通过 CAS 递增计数器来"认领下一个"。

```cpp
class SequentialSubTasksDone : public StackObj {
  uint _n_tasks;              // 总任务数
  volatile uint _n_claimed;   // 已认领到第几号
  uint _n_threads;            // 总线程数
  volatile uint _n_completed; // 已完成报到数
};
```

```cpp
bool SequentialSubTasksDone::is_task_claimed(uint& t) {
  t = _n_claimed;
  while (t < _n_tasks) {
    uint res = Atomic::cmpxchg(t+1, &_n_claimed, t);  // CAS: t→t+1
    if (res == t) {
      return false;  // 认领成功，t 就是任务编号
    }
    t = res;  // CAS 失败，用最新值重试
  }
  return true;  // 没有更多任务了
}
```

**使用模式**：类似于"工作窃取"的简化版——每个 worker 不断认领下一个任务编号，直到所有编号被认领完。

```cpp
void work(uint worker_id) {
  uint task_id;
  while (!_sequential_tasks.is_task_claimed(task_id)) {
    process_region(task_id);  // 处理第 task_id 号 Region
  }
  if (_sequential_tasks.all_tasks_completed()) {
    // 最后一个完成的线程做清理
    cleanup();
  }
}
```

### 4.4 三种辅助原语对比

| 原语 | 用途 | 分配方式 | 同步机制 |
|------|------|---------|---------|
| WorkGangBarrierSync | 阶段同步（所有人等齐） | 栈对象 | Monitor |
| SubTasksDone | 枚举型子任务认领 | 堆对象 | CAS |
| SequentialSubTasksDone | 连续编号子任务认领 | 栈对象 | CAS |

---

## 5. G1 中的两个 WorkGang 实例

### 5.1 实例创建

G1 在初始化时创建了**两个 WorkGang 实例**：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         G1 WorkGang 实例                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  G1CollectedHeap::_workers                G1ConcurrentMark::_concurrent_workers  │
│  ┌──────────────────────────┐             ┌──────────────────────────┐      │
│  │ 名称: "GC Thread"        │             │ 名称: "G1 Conc"          │      │
│  │ 最大线程数: 13            │             │ 最大线程数: 3             │      │
│  │ are_GC_task: true        │             │ are_GC_task: false       │      │
│  │ are_Conc: false          │             │ are_Conc: true           │      │
│  │ 线程类型: pgc_thread     │             │ 线程类型: cgc_thread     │      │
│  │ 用途: STW 并行任务       │             │ 用途: 并发标记/清理       │      │
│  │ 初始创建: 1 个            │             │ 初始创建: 1 个            │      │
│  └──────────────────────────┘             └──────────────────────────┘      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 GDB 验证 — WorkGang 创建参数

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
┌────────────────────────────────────────────────────────────────────┐
│ WorkGang #1 — G1CollectedHeap 构造函数中创建                       │
│   name: "GC Thread"                                                │
│   workers: 13 (= ParallelGCThreads)                               │
│   are_GC_task_threads: true                                        │
│   are_ConcurrentGC_threads: false                                  │
│   初始 active_workers: 1                                           │
│   初始 created_workers: 0 → 创建后变为 1                           │
├────────────────────────────────────────────────────────────────────┤
│ WorkGang #2 — G1ConcurrentMark 构造函数中创建                      │
│   name: "G1 Conc"                                                  │
│   workers: 3 (= ConcGCThreads)                                    │
│   are_GC_task_threads: false                                       │
│   are_ConcurrentGC_threads: true                                   │
│   初始 active_workers: 1                                           │
│   初始 created_workers: 0 → 创建后变为 1                           │
├────────────────────────────────────────────────────────────────────┤
│ sizeof(WorkGang): 56 bytes                                         │
│ sizeof(AbstractWorkGang): 48 bytes                                 │
│ sizeof(GangWorker): 896 bytes                                      │
│ sizeof(SemaphoreGangTaskDispatcher): 40 bytes                      │
│ sizeof(AbstractGangTask): 24 bytes                                 │
│ sizeof(WorkGangBarrierSync): 176 bytes                             │
│ sizeof(SubTasksDone): 32 bytes                                     │
└────────────────────────────────────────────────────────────────────┘
```

### 5.3 GDB 验证 — run_task 运行时数据

```
【GDB 验证】首次 run_task 调用
┌────────────────────────────────────────────────────────────────────┐
│ run_task #1                                                        │
│   gang: "GC Thread"                                                │
│   task: "Parallel Safepoint Cleanup"                               │
│   num_workers: 1                                                   │
│   total_workers: 13                                                │
│   active_workers: 1                                                │
│   created_workers: 1                                               │
│   调用线程: VM Thread                                              │
├────────────────────────────────────────────────────────────────────┤
│ run_task #2                                                        │
│   gang: "GC Thread"                                                │
│   task: "Parallel Safepoint Cleanup"                               │
│   num_workers: 1                                                   │
├────────────────────────────────────────────────────────────────────┤
│ run_task #3                                                        │
│   gang: "GC Thread"                                                │
│   task: "Parallel verify task"                                     │
│   num_workers: 1                                                   │
└────────────────────────────────────────────────────────────────────┘
```

**关键发现**：
1. 第一个 GangWorker (GC Thread#0) 在 WorkGang 创建后立即启动，进入 `GangWorker::loop()` 等待
2. `hello jvm` 这样的简单程序只触发了少量 Safepoint Cleanup 任务
3. 默认动态模式下，只有 1 个 worker 在工作（`num_workers: 1`）


---

## 6. G1 中的具体任务场景

G1 在不同 GC 阶段使用不同的 AbstractGangTask 子类，通过 WorkGang 并行执行。

### 6.1 使用 "GC Thread" 线程池 (STW 任务)

| 任务类 | 任务名 | 使用场景 | 调用位置 |
|--------|--------|---------|---------|
| **G1ParTask** | "G1 collection" | **Young GC / Mixed GC 并行疏散** | `g1CollectedHeap.cpp:4807` |
| G1CMRemarkTask | "G1 Remark" | 并发标记 Remark 阶段 (STW) | `g1ConcurrentMark.cpp:1968` |
| G1CMRefProcTaskProxy | 引用处理任务 | 引用处理 (Soft/Weak/Phantom) | `g1ConcurrentMark.cpp:1665` |
| G1FullGCMarkTask 等 | Full GC 各阶段 | Full GC 标记/调整/压缩 | `g1FullCollector.cpp:274` |
| G1UpdateRemSetTrackingBeforeRebuild | "Update RemSet Tracking Before Rebuild" | RemSet 追踪更新 | `g1RemSet.cpp:306` |
| G1MergeHeapRootsTask | "G1 Merge Heap Roots" | 合并堆根 | `g1RemSet.cpp:1165` |
| G1ParallelCleaningTask | 并行清理 | Safepoint 清理 | `g1CollectedHeap.cpp:4414/4427` |
| G1RedirtyLoggedCardsTask | "G1 Redirty Logged Cards" | 重脏化日志卡 | `g1CollectedHeap.cpp:4455` |
| SafepointCleanupTask | "Parallel Safepoint Cleanup" | Safepoint 后并行清理 | 每次 Safepoint |
| G1HeapVerifyTask | "Parallel verify task" | 堆验证（调试用） | `g1HeapVerifier.cpp:455` |

### 6.2 使用 "G1 Conc" 线程池 (并发任务)

| 任务类 | 任务名 | 使用场景 | 调用位置 |
|--------|--------|---------|---------|
| **G1CMConcurrentMarkingTask** | "Concurrent Mark" | **并发标记主循环** | `g1ConcurrentMark.cpp:1033` |
| G1CMRootRegionScanTask | "G1 Root Region Scan" | 根 Region 扫描 | `g1ConcurrentMark.cpp:1082` |

### 6.3 核心任务 G1ParTask 的 work() 方法

这是 Young GC 并行疏散的核心，每个 worker 执行以下步骤：

```cpp
void G1ParTask::work(uint worker_id) {
  if (worker_id >= _n_workers) return;  // 多余的 worker 直接返回

  // ① 获取线程私有的扫描状态
  G1ParScanThreadState* pss = _pss->state_for_worker(worker_id);
  pss->set_ref_discoverer(rp);

  // ② 根扫描（每个 worker 扫描不同的根集合分区）
  _root_processor->evacuate_roots(pss, worker_id);

  // ③ RemSet 扫描（扫描跨 Region 引用）
  _g1h->g1_rem_set()->oops_into_collection_set_do(pss, worker_id);

  // ④ 对象复制 + 工作窃取终止协议
  G1ParEvacuateFollowersClosure evac(_g1h, pss, _queues, &_terminator);
  evac.do_void();  // 处理自己队列中的对象引用，队列空了就去偷别人的
}
```

**worker_id 的关键作用**：
- `state_for_worker(worker_id)` — 获取线程私有的 PLAB 分配缓冲区
- `evacuate_roots(pss, worker_id)` — 根据 worker_id 分配不同的根集合分区
- 每个 worker 有自己的 `RefToScanQueue`，避免锁竞争

### 6.4 核心任务 G1CMConcurrentMarkingTask

这是并发标记的核心，与应用线程并行执行：

```cpp
void G1CMConcurrentMarkingTask::work(uint worker_id) {
  assert(Thread::current()->is_ConcurrentGC_thread(), "...");

  SuspendibleThreadSetJoiner sts_join;  // 加入可暂停集合

  G1CMTask* task = _cm->task(worker_id);  // 获取线程私有的标记任务
  task->record_start_time();

  if (!_cm->has_aborted()) {
    do {
      task->do_marking_step(G1ConcMarkStepDurationMillis,  // 每步时长限制
                            true,   // do_termination
                            false); // not serial
      _cm->do_yield_check();  // 检查是否需要让出 CPU（STW 请求）
    } while (!_cm->has_aborted() && task->has_aborted());
  }
}
```

**关键设计**：
- `SuspendibleThreadSetJoiner` — 使线程能被 STW 暂停
- `do_yield_check()` — 检查 Safepoint 请求，必要时暂停标记
- `do_marking_step()` — 增量标记，每次只标记 `G1ConcMarkStepDurationMillis` 毫秒

---

## 7. 线程创建与懒扩容机制

### 7.1 WorkerManager::add_workers — 懒创建

```cpp
template <class WorkerType>
static uint add_workers(WorkerType* holder,
                        uint active_workers,    // 需要的活跃数
                        uint total_workers,     // 最大允许数
                        uint created_workers,   // 已创建数
                        os::ThreadType worker_type,
                        bool initializing) {
  uint start = created_workers;
  uint end = MIN2(active_workers, total_workers);

  for (uint worker_id = start; worker_id < end; worker_id++) {
    // ① 分配 GangWorker 对象并存入数组
    WorkerThread* new_worker = holder->install_worker(worker_id);

    // ② 创建 OS 线程（pthread_create）
    if (!os::create_thread(new_worker, worker_type)) {
      // 创建失败处理...
      break;
    }
    created_workers++;

    // ③ 启动线程 → 执行 AbstractGangWorker::run() → loop()
    os::start_thread(new_worker);
  }
  return created_workers;
}
```

### 7.2 动态扩容时机

```
初始化: created=1, active=1, total=13

     ┌─────────────────────────────────────────────────────┐
     │ 发现需要更多 worker 时（如 Young GC 需要 13 个）      │
     │                                                     │
     │ WorkGang::run_task(task, 13)                        │
     │   → update_active_workers(13)                       │
     │     → _active_workers = 13                          │
     │     → add_workers(false)                            │
     │       → WorkerManager::add_workers(...)             │
     │         start=1, end=13                             │
     │         创建 GC Thread#1 ~ GC Thread#12             │
     │                                                     │
     │ 结果: created=13, active=13, total=13               │
     └─────────────────────────────────────────────────────┘
```

### 7.3 WithUpdatedActiveWorkers — RAII 活跃数管理

```cpp
class WithUpdatedActiveWorkers : public StackObj {
  AbstractWorkGang* const _gang;
  const uint _old_active_workers;  // 保存旧值

public:
  WithUpdatedActiveWorkers(AbstractWorkGang* gang, uint requested) :
      _gang(gang), _old_active_workers(gang->active_workers()) {
    gang->update_active_workers(MIN2(requested, gang->total_workers()));
  }
  ~WithUpdatedActiveWorkers() {
    _gang->update_active_workers(_old_active_workers);  // 恢复旧值
  }
};
```

使用方式：
```cpp
{
  WithUpdatedActiveWorkers update_workers(gang, desired_workers);
  gang->run_task(&my_task);
}  // 析构时自动恢复
```

---

## 8. 内存布局与 sizeof

### 8.1 WorkGang 对象布局

```
WorkGang (56 bytes, 继承自 AbstractWorkGang + 1个指针)
偏移    字段                              大小    说明
─────────────────────────────────────────────────────────
0x000   [vtable]                          8      虚表指针
0x008   _workers (AbstractGangWorker**)   8      worker 指针数组
0x010   _total_workers                    4      最大线程数 (13)
0x014   _active_workers                   4      活跃线程数
0x018   _created_workers                  4      已创建线程数
0x01c   [padding]                         4      对齐
0x020   _name                             8      "GC Thread"
0x028   _are_GC_task_threads              1      true
0x029   _are_ConcurrentGC_threads         1      false
0x02a   [padding]                         6      对齐
0x030   _dispatcher (GangTaskDispatcher*) 8      任务分发器
─────────────────────────────────────────────────────────
总计: 56 bytes
```

### 8.2 GangWorker 对象布局

```
GangWorker (896 bytes, 继承自 AbstractGangWorker → WorkerThread → NamedThread → Thread)
                                             大小
─────────────────────────────────────────────────
Thread 基类部分（含 _osthread, _stack 等）   ~880 bytes
NamedThread::_name                           指针 (8B)
WorkerThread::_id                            uint (4B)
AbstractGangWorker::_gang                    指针 (8B)
─────────────────────────────────────────────────
总计: 896 bytes
```

**注意**：GangWorker 自身没有增加任何字段，因此 sizeof(GangWorker) == sizeof(AbstractGangWorker) == 896 bytes。绝大部分空间都是 Thread 基类的字段。

---

## 9. 与 Java ThreadPoolExecutor 对比

| 维度 | JVM WorkGang | Java ThreadPoolExecutor |
|------|-------------|------------------------|
| **位置** | HotSpot C++ 内部 | Java 标准库 |
| **任务模型** | 广播模型：同一个任务给所有 worker | 队列模型：每个任务独立 |
| **worker_id** | 有，用于数据分区 | 无 |
| **任务队列** | 无 | BlockingQueue |
| **同步模型** | 全员完成才返回 | 提交即返回 (Future) |
| **线程回收** | 永不回收（线程池生命周期=JVM生命周期） | keepAliveTime 后回收 |
| **拒绝策略** | 无（任务数量确定） | 4 种拒绝策略 |
| **创建策略** | 懒创建，按需扩容 | core/max 两级 |
| **同步原语** | Semaphore/Monitor + CAS | AQS + ReentrantLock |
| **工作窃取** | 外部实现（RefToScanQueue + ParallelTaskTerminator） | ForkJoinPool 内置 |

**为什么 JVM 不用 ThreadPoolExecutor？**

1. **性能**：GC 线程是极度延迟敏感的场景。WorkGang 使用 C++ 原生信号量，比 Java AQS 开销更低
2. **确定性**：GC 任务需要"所有 worker 都完成才继续"，ThreadPoolExecutor 的异步模型不适合
3. **分区**：GC 任务通过 worker_id 静态分区，不需要任务队列
4. **生命周期**：GC 线程与 JVM 同生共死，不需要动态回收

---

## 10. 日志参数

| 参数 | 用途 | 示例输出 |
|------|------|---------|
| `-Xlog:gc+task=trace` | 线程创建、任务执行日志 | `Adding initial GC Thread(s) previously created workers 0 active workers 1 total created workers 1` |
| `-Xlog:gc+task+stats=debug` | GC 各 worker 耗时统计 | 各 worker 的 elapsed/strong roots/termination 耗时 |
| `-Xlog:gc,workgang=trace` | WorkGang 内部详细日志 | `Constructing work gang GC Thread with 13 threads` |

```bash
# 查看 WorkGang 创建日志
java -Xms8g -Xmx8g -XX:+UseG1GC -Xlog:gc+task=trace -version

# 查看每个 worker 的 GC 耗时统计
java -Xms8g -Xmx8g -XX:+UseG1GC -Xlog:gc+task+stats=debug -cp app.jar Main
```

---

## 11. GDB 验证脚本

### 11.1 WorkGang 创建验证脚本

```gdb
# 文件: jvm-md/tmp-file/workgang/gdb_workgang2.txt

set pagination off
set print pretty on

b WorkGang::WorkGang
b AbstractWorkGang::initialize_workers
b GangWorker::loop

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# WorkGang #1: GC Thread
printf "\n========== WorkGang #1 ==========\n"
printf "name: %s\n", name
printf "workers: %u\n", workers
printf "sizeof(WorkGang): %lu\n", sizeof(WorkGang)
printf "sizeof(GangWorker): %lu\n", sizeof(GangWorker)
printf "sizeof(SemaphoreGangTaskDispatcher): %lu\n", sizeof(SemaphoreGangTaskDispatcher)
c

# initialize_workers #1
printf "\n========== init #1: total=%u active=%u created=%u ==========\n", this->_total_workers, this->_active_workers, this->_created_workers
c

# GangWorker::loop #1
printf "\n========== GangWorker id=%u gang=%s ==========\n", this->_id, this->_gang->_name
c

# WorkGang #2: G1 Conc
printf "\n========== WorkGang #2: name=%s workers=%u ==========\n", name, workers
c

# init #2
printf "\n========== init #2: total=%u active=%u created=%u ==========\n", this->_total_workers, this->_active_workers, this->_created_workers
c

delete breakpoints
c
quit
```

### 11.2 run_task 运行时验证脚本

```gdb
# 文件: jvm-md/tmp-file/workgang/gdb_runtask.txt

set pagination off
set print pretty on

b WorkGang::run_task(AbstractGangTask*, unsigned int, bool)

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# 观察前几次 run_task 调用
printf "\nrun_task: gang=%s task=%s workers=%u\n", this->_name, task->_name, num_workers
c
printf "\nrun_task: gang=%s task=%s workers=%u\n", this->_name, task->_name, num_workers
c
printf "\nrun_task: gang=%s task=%s workers=%u\n", this->_name, task->_name, num_workers

delete breakpoints
c
quit
```

---

## 12. 面试 Q&A

### Q1: JVM 内部的 GC 线程池和 Java 的 ThreadPoolExecutor 有什么本质区别？

**回答要点**：

JVM 的 WorkGang 是**广播 + 全员同步**模型，ThreadPoolExecutor 是**队列 + 异步提交**模型。

具体来说，WorkGang 调用 `run_task(task)` 时，会把**同一个 AbstractGangTask 广播给所有 worker**，每个 worker 拿到不同的 `worker_id`（0~N-1），用 worker_id 来决定自己处理堆的哪一部分数据。协调者（通常是 VMThread）必须等所有 worker 都完成才继续——因为 GC 阶段结束的前提是所有 Region 都处理完毕。

而 ThreadPoolExecutor 是每次提交一个独立的 Runnable/Callable 到 BlockingQueue，worker 从队列取任务执行，不需要等其他 worker。

源码层面，WorkGang 默认使用 `SemaphoreGangTaskDispatcher`，协调者 `signal(N)` 唤醒 N 个 worker，worker 通过 `Atomic::add` 无锁获取 worker_id，最后一个完成的 worker `signal(1)` 唤醒协调者。整个过程没有锁竞争。

### Q2: G1 有几个线程池？分别做什么？

**回答要点**：

G1 有两个 WorkGang 线程池：

1. **"GC Thread"** — `G1CollectedHeap::_workers`
   - ParallelGCThreads 个线程（我们环境是 13 个）
   - 线程类型 `pgc_thread`（Parallel GC Thread）
   - 用于 STW 阶段：Young GC 疏散 (G1ParTask)、Remark (G1CMRemarkTask)、Full GC 等
   - 需要进入 Safepoint 才执行

2. **"G1 Conc"** — `G1ConcurrentMark::_concurrent_workers`
   - ConcGCThreads 个线程（我们环境是 3 个）
   - 线程类型 `cgc_thread`（Concurrent GC Thread）
   - 用于并发阶段：并发标记 (G1CMConcurrentMarkingTask)、Root Region 扫描
   - 与应用线程并发运行，通过 `SuspendibleThreadSet` 响应 STW 请求

### Q3: UseDynamicNumberOfGCThreads 的作用？

**回答要点**：

默认为 `true`。开启时，WorkGang 初始只创建 **1 个** GangWorker，后续按需扩容。

比如 `_total_workers=13`，初始只创建 `GC Thread#0`。当第一次 Young GC 发生时，VMThread 调用 `run_task(task, 13)`，`update_active_workers(13)` 触发 `add_workers()`，这时才通过 `WorkerManager::add_workers()` 创建剩余的 `GC Thread#1` ~ `GC Thread#12`。

好处是**节省资源**：大多数简单程序可能不需要 13 个 GC 线程全部就绪。坏处是第一次需要全部线程时会有**创建延迟**。

GDB 验证可以看到，初始化时 `created_workers=1, active_workers=1, total_workers=13`。

### Q4: 信号量分发器为什么比 Monitor 分发器性能更好？

**回答要点**：

核心差异在于 **worker 被唤醒后的行为**：

- **SemaphoreGangTaskDispatcher**：`_start_semaphore->wait()` 返回后，worker **直接执行**，不需要竞争任何锁。worker_id 通过 `Atomic::add` 无锁获取。
- **MutexGangTaskDispatcher**：`_monitor->wait()` 返回后，worker 必须**重新获取 Monitor 锁**。13 个 worker 同时被 `notify_all()` 唤醒，会产生锁竞争。

在 GC 场景下，worker 数量多（13+）且都在同一时刻被唤醒，Monitor 的锁竞争开销是不可忽略的。信号量方案的 `sizeof` 只有 40 bytes，而且完成通知只需要最后一个 worker `signal(1)`，不存在惊群问题。

### Q5: SubTasksDone 和 SequentialSubTasksDone 有什么区别？什么场景用哪个？

**回答要点**：

- **SubTasksDone**：适用于**枚举型子任务**。比如 Safepoint Cleanup 有 5 种清理任务（清理 String Table、清理 Class Loader Data 等），每种只需一个 worker 执行。worker 通过 `is_task_claimed(TASK_ID)` + CAS 认领。
- **SequentialSubTasksDone**：适用于**连续编号的同质任务**。比如扫描 2048 个 HeapRegion，每个 Region 的处理逻辑相同。worker 通过 CAS 递增 `_n_claimed` 认领下一个编号。

两者都是 **无锁** 设计（CAS），但 SubTasksDone 是**一次性认领**（每个编号只被一个 worker 认领），SequentialSubTasksDone 是**流式认领**（不断认领直到没有更多）。

### Q6: GangWorker 线程的生命周期是怎样的？

**回答要点**：

GangWorker 线程的生命周期 = JVM 的生命周期。一旦创建，就**永远不会销毁**。

创建流程：
1. `WorkerManager::add_workers()` 调用 `os::create_thread()` → `pthread_create()`
2. 新线程执行 `AbstractGangWorker::run()` → `initialize()` + `loop()`
3. `loop()` 是一个无限循环：`while(true) { wait_for_task(); run_task(); signal_done(); }`

worker 线程在没有任务时**阻塞在信号量 wait 上**（或 Monitor wait 上），不消耗 CPU。有任务时被唤醒执行，执行完又回到等待状态。

这与 Java ThreadPoolExecutor 的 `keepAliveTime` 机制不同——ThreadPoolExecutor 的非核心线程空闲超时会被回收，但 GangWorker 永远不会回收。

### Q7: 如果 GC 线程数设置不合理会怎样？

**回答要点**：

- **ParallelGCThreads 过多**：线程间同步开销增加，CPU 上下文切换频繁。每个 worker 需要独立的 PLAB（约 4KB），内存浪费。RefToScanQueue 数量增加，工作窃取的终止协议变慢。
- **ParallelGCThreads 过少**：GC 并行度不够，STW 时间变长。在大堆（8GB+）场景下尤其明显。
- **ConcGCThreads 过多**：抢占应用线程 CPU，影响应用吞吐量。
- **ConcGCThreads 过少**：并发标记跟不上应用的分配速率，触发 Full GC。

经验法则：ParallelGCThreads 通常 = CPU 核数的 60%~75%，ConcGCThreads ≈ ParallelGCThreads / 4。我们 16 核环境中，ParallelGCThreads=13, ConcGCThreads=3 是 JVM 自动计算的合理值。

---

## 13. 源码索引

| 文件 | 路径 | 关键内容 |
|------|------|---------|
| workgroup.hpp | `gc/shared/workgroup.hpp` | 类定义：AbstractWorkGang, WorkGang, AbstractGangWorker, GangWorker, WorkGangBarrierSync, SubTasksDone, SequentialSubTasksDone |
| workgroup.cpp | `gc/shared/workgroup.cpp` | 实现：SemaphoreGangTaskDispatcher, MutexGangTaskDispatcher, GangWorker::loop(), WorkGangBarrierSync::enter() |
| workerManager.hpp | `gc/shared/workerManager.hpp` | WorkerManager::add_workers() 线程创建 |
| thread.hpp | `runtime/thread.hpp:858` | WorkerThread 基类 |
| semaphore.hpp | `runtime/semaphore.hpp` | Semaphore 包装 |
| gc_globals.hpp | `gc/shared/gc_globals.hpp:214` | UseSemaphoreGCThreadsSynchronization 默认 true |
| g1CollectedHeap.cpp:1500 | `gc/g1/g1CollectedHeap.cpp` | 创建 "GC Thread" WorkGang |
| g1ConcurrentMark.cpp:508 | `gc/g1/g1ConcurrentMark.cpp` | 创建 "G1 Conc" WorkGang |
| g1CollectedHeap.cpp:3916 | `gc/g1/g1CollectedHeap.cpp` | G1ParTask 定义 |
| g1ConcurrentMark.cpp:919 | `gc/g1/g1ConcurrentMark.cpp` | G1CMConcurrentMarkingTask 定义 |

---

*最后更新: 2026-02-09*
*GDB 验证环境: OpenJDK 11, -Xms8g -Xmx8g -XX:+UseG1GC, 16 核*
