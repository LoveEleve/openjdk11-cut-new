# E.1 - WorkGang 创建（GC 线程池）

> **前置条件**：-Xms8G -Xmx8G，G1 GC，非大页，非 NUMA
> **前置知识**：B.1.1 ParallelGCThreads（16 核机器 = 13）

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **E.1 - WorkGang 创建（GC 线程池）**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 1. 概述

**WorkGang** 是 G1 GC 的并行工作线程池，用于执行 STW（Stop-The-World）阶段的并行任务，如：
- Young GC 的对象扫描和复制
- Mixed GC 的并行回收
- Full GC 的并行标记和压缩

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         G1 线程池架构                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  G1CollectedHeap::_workers (WorkGang)    ← STW 并行 GC 线程                 │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ GangWorker#0 │ GangWorker#1 │ ... │ GangWorker#12 │ (共 13 个)      │   │
│  └──────┬───────┴──────┬───────┴─────┴───────┬───────┘                 │   │
│         │              │                     │                          │   │
│         └──────────────┴─────────────────────┘                          │   │
│                         │                                               │   │
│                         ▼                                               │   │
│                   AbstractGangTask                                      │   │
│                   (并行任务抽象)                                          │   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 调用位置

```cpp
// g1CollectedHeap.cpp:1500-1504
G1CollectedHeap::G1CollectedHeap(...) {
  // 构造函数体
  _workers = new WorkGang("GC Thread", ParallelGCThreads,
          /* are_GC_task_threads */true,      // STW GC 线程
          /* are_ConcurrentGC_threads */false); // 非并发 GC 线程
  _workers->initialize_workers();
  ...
}
```

---

## 3. WorkGang 类继承体系

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         类继承关系                                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  CHeapObj<mtInternal>                                                       │
│       │                                                                     │
│       ▼                                                                     │
│  AbstractWorkGang                    ← 基类：管理线程数组                    │
│  ┌───────────────────────────────────────────────────────────────────┐     │
│  │ AbstractGangWorker** _workers     // 线程数组                      │     │
│  │ uint _total_workers               // 最大线程数 = 13               │     │
│  │ uint _active_workers              // 活跃线程数                    │     │
│  │ uint _created_workers             // 已创建线程数                  │     │
│  │ const char* _name                 // "GC Thread"                  │     │
│  │ bool _are_GC_task_threads         // true                         │     │
│  │ bool _are_ConcurrentGC_threads    // false                        │     │
│  └───────────────────────────────────────────────────────────────────┘     │
│       │                                                                     │
│       ▼                                                                     │
│  WorkGang                            ← 实现类：任务分发                      │
│  ┌───────────────────────────────────────────────────────────────────┐     │
│  │ GangTaskDispatcher* _dispatcher   // 任务分发器                    │     │
│  │ void run_task(AbstractGangTask*)  // 运行任务                      │     │
│  └───────────────────────────────────────────────────────────────────┘     │
│                                                                             │
│  WorkerThread                                                               │
│       │                                                                     │
│       ▼                                                                     │
│  AbstractGangWorker                  ← 工作线程基类                          │
│       │                                                                     │
│       ▼                                                                     │
│  GangWorker                          ← 具体工作线程                          │
│  ┌───────────────────────────────────────────────────────────────────┐     │
│  │ void loop()                       // 主循环：等待任务 → 执行 → 通知 │     │
│  └───────────────────────────────────────────────────────────────────┘     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. 源码深度分析

### 4.1 WorkGang 构造函数

```cpp
// workgroup.cpp（推断）
WorkGang::WorkGang(const char* name,
                   uint workers,
                   bool are_GC_task_threads,
                   bool are_ConcurrentGC_threads)
    : AbstractWorkGang(name, workers, are_GC_task_threads, are_ConcurrentGC_threads),
      _dispatcher(new GangTaskDispatcher())  // 创建任务分发器
{}
```

### 4.2 AbstractWorkGang 构造函数

```cpp
// workgroup.hpp:135-142
AbstractWorkGang(const char* name, uint workers, bool are_GC_task_threads, bool are_ConcurrentGC_threads) :
    _name(name),                    // "GC Thread"
    _total_workers(workers),        // 13（ParallelGCThreads）
    _active_workers(UseDynamicNumberOfGCThreads ? 1U : workers),
                                    // 动态模式：初始 1 个
                                    // 非动态模式：全部 13 个
    _created_workers(0),            // 尚未创建
    _are_GC_task_threads(are_GC_task_threads),      // true
    _are_ConcurrentGC_threads(are_ConcurrentGC_threads)  // false
{ }
```

### 4.3 initialize_workers()

```cpp
// workgroup.cpp:47-58
void AbstractWorkGang::initialize_workers() {
  log_develop_trace(gc, workgang)("Constructing work gang %s with %u threads", 
                                   name(), total_workers());
  
  // 分配指针数组（注意：是指针数组，不是线程对象数组）
  // 13 个指针 × 8 字节 = 104 字节
  _workers = NEW_C_HEAP_ARRAY(AbstractGangWorker*, total_workers(), mtInternal);
  if (_workers == NULL) {
    vm_exit_out_of_memory(0, OOM_MALLOC_ERROR, "Cannot create GangWorker array.");
  }
  
  // 添加工作线程
  add_workers(true);
}
```

### 4.4 add_workers()

```cpp
// workgroup.cpp:67-99
void AbstractWorkGang::add_workers(bool initializing) {
  add_workers(_active_workers, initializing);
}

void AbstractWorkGang::add_workers(uint active_workers, bool initializing) {
  // 确定线程类型
  os::ThreadType worker_type;
  if (are_ConcurrentGC_threads()) {
    worker_type = os::cgc_thread;   // Concurrent GC Thread
  } else {
    worker_type = os::pgc_thread;   // Parallel GC Thread ← G1 STW 使用这个
  }
  
  uint previous_created_workers = _created_workers;
  
  // 调用 WorkerManager 创建线程
  _created_workers = WorkerManager::add_workers(this,
                                                active_workers,   // 1（动态模式）
                                                _total_workers,   // 13
                                                _created_workers, // 0
                                                worker_type,      // pgc_thread
                                                initializing);    // true
  
  _active_workers = MIN2(_created_workers, _active_workers);
  
  // 日志输出（-Xlog:gc+task=trace）
  // "Adding initial GC Thread(s) previously created workers 0 active workers 1 total created workers 1"
  WorkerManager::log_worker_creation(this, previous_created_workers, 
                                     _active_workers, _created_workers, initializing);
}
```

### 4.5 WorkerManager::add_workers()

```cpp
// workerManager.hpp:50-96
template <class WorkerType>
static uint add_workers(WorkerType* holder,
                        uint active_workers,
                        uint total_workers,
                        uint created_workers,
                        os::ThreadType worker_type,
                        bool initializing) {
  
  // 计算需要创建的线程数
  uint start = created_workers;                           // 0
  uint end = MAX2(active_workers, created_workers);       // MAX(1, 0) = 1
  
  for (uint worker_id = start; worker_id < end; worker_id++) {
    // 创建新线程
    AbstractGangWorker* new_worker = holder->install_worker(worker_id);
    // 内部调用 allocate_worker(worker_id) 创建 GangWorker 对象
    
    // 启动线程！！
    os::start_thread(new_worker);
    
    created_workers++;  // 0 → 1
  }
  
  return created_workers;  // 1
}
```

---

## 5. UseDynamicNumberOfGCThreads 参数

### 5.1 参数定义

```cpp
// gc_globals.hpp:218-220
product(bool, UseDynamicNumberOfGCThreads, true,
        "Dynamically choose the number of threads up to a maximum of "
        "ParallelGCThreads parallel collectors will use for garbage "
        "collection work")
```

**默认值**：`true`（动态线程数）

### 5.2 动态 vs 非动态模式

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ UseDynamicNumberOfGCThreads = true（默认）                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  初始化时：                                                                  │
│    _total_workers = 13                                                      │
│    _active_workers = 1    ← 只有 1 个活跃                                   │
│    _created_workers = 1   ← 只创建 1 个线程                                 │
│                                                                             │
│  GC 时动态调整：                                                             │
│    根据堆大小和工作量动态增加/减少活跃线程                                    │
│    需要更多线程时，按需创建（懒创建）                                         │
│                                                                             │
│  优点：节省资源，小 GC 不需要全部线程                                        │
│  缺点：首次需要全部线程时有延迟                                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│ UseDynamicNumberOfGCThreads = false                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  初始化时：                                                                  │
│    _total_workers = 13                                                      │
│    _active_workers = 13   ← 全部活跃                                        │
│    _created_workers = 13  ← 全部创建                                        │
│                                                                             │
│  GC 时：始终使用全部线程                                                     │
│                                                                             │
│  优点：GC 时无延迟                                                          │
│  缺点：资源占用高                                                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 6. 线程类型

```cpp
// os.hpp
enum ThreadType {
  vm_thread,         // VM 线程（执行 GC 等操作）
  cgc_thread,        // Concurrent GC Thread（并发标记）
  pgc_thread,        // Parallel GC Thread（STW 并行）
  java_thread,       // Java 线程
  compiler_thread,   // JIT 编译线程
  ...
};
```

**G1 中的两种 GC 线程池**：

| 线程池 | 名称 | 线程类型 | 用途 |
|--------|------|----------|------|
| `_workers` | "GC Thread" | pgc_thread | STW 并行任务 |
| `_concurrent_workers` | "G1 Conc" | cgc_thread | 并发标记 |

---

## 7. 任务执行流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        WorkGang 任务执行流程                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  主线程（VM Thread）                       GangWorker 线程                   │
│  ═══════════════════                      ══════════════════                │
│                                                                             │
│  1. 创建 AbstractGangTask                                                   │
│     ┌──────────────────┐                                                   │
│     │ G1ParTask        │                                                   │
│     │ work(worker_id)  │                                                   │
│     └──────────────────┘                                                   │
│              │                                                             │
│              ▼                                                             │
│  2. 调用 run_task(task)                   3. GangWorker::loop() 等待       │
│     ┌──────────────────┐                  ┌──────────────────────────┐    │
│     │ _dispatcher->    │ ───────────────▶ │ WorkData = wait_for_task()│    │
│     │ coordinator_     │   通知           │ run_task(work)            │    │
│     │ execute_on_      │                  │   task->work(worker_id)  │    │
│     │ workers(task,n)  │                  │ signal_task_done()       │    │
│     └────────┬─────────┘                  └──────────────────────────┘    │
│              │                                      │                      │
│              │                                      │                      │
│  4. 等待所有线程完成    ◀─────────────────────────────┘                      │
│              │                                                             │
│              ▼                                                             │
│  5. 继续执行                                                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 8. GangWorker 主循环

```cpp
// workgroup.cpp（推断）
void GangWorker::loop() {
  for (;;) {
    // 1. 等待任务
    WorkData work = wait_for_task();
    
    // 2. 执行任务
    run_task(work);
    // 内部：work._task->work(work._worker_id);
    
    // 3. 通知完成
    signal_task_done();
  }
}
```

---

## 9. 内存布局

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        WorkGang 内存布局                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  WorkGang 对象                                                              │
│  ┌────────────────────────────────────────────────────────────────────┐    │
│  │ (继承自 AbstractWorkGang)                                          │    │
│  │ _workers ─────────────────────────┐                                │    │
│  │ _total_workers = 13               │                                │    │
│  │ _active_workers = 1               │                                │    │
│  │ _created_workers = 1              │                                │    │
│  │ _name = "GC Thread"               │                                │    │
│  │ _are_GC_task_threads = true       │                                │    │
│  │ _are_ConcurrentGC_threads = false │                                │    │
│  │ _dispatcher ────────────────────┐ │                                │    │
│  └──────────────────────────────── │─┼────────────────────────────────┘    │
│                                    │ │                                     │
│                                    │ │                                     │
│  指针数组（C Heap）                  │ │                                     │
│  ┌─────────────────────────────────┼─┼──┐                                  │
│  │ [0] ──▶ GangWorker#0           │ │  │                                  │
│  │ [1] ──▶ NULL (未创建)            │ │  │                                  │
│  │ [2] ──▶ NULL                    │ │  │                                  │
│  │ ...                             │ │  │                                  │
│  │ [12] ─▶ NULL                    ◀─┘ │  │                                  │
│  └─────────────────────────────────────┘                                   │
│                                      │                                     │
│                                      │                                     │
│  GangTaskDispatcher                  ◀─┘                                    │
│  ┌─────────────────────────────────────┐                                   │
│  │ _monitor                            │                                   │
│  │ _task                               │                                   │
│  │ _num_workers                        │                                   │
│  │ _started / _finished                │                                   │
│  └─────────────────────────────────────┘                                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 10. GDB 验证

### 10.1 GDB 脚本

```gdb
# 文件：jvm-md/tmp-file/universe-init/gdb_workgang.txt

b g1CollectedHeap.cpp:1504
commands
  silent
  printf "\n========== WorkGang Creation ==========\n"
  
  # 参数
  printf "----- Parameters -----\n"
  printf "ParallelGCThreads: %u\n", ParallelGCThreads
  printf "UseDynamicNumberOfGCThreads: %d\n", UseDynamicNumberOfGCThreads
  
  # WorkGang 字段
  printf "\n----- WorkGang Fields -----\n"
  printf "_name: %s\n", this->_workers->_name
  printf "_total_workers: %u\n", this->_workers->_total_workers
  printf "_active_workers: %u\n", this->_workers->_active_workers
  printf "_created_workers: %u\n", this->_workers->_created_workers
  printf "_are_GC_task_threads: %d\n", this->_workers->_are_GC_task_threads
  printf "_are_ConcurrentGC_threads: %d\n", this->_workers->_are_ConcurrentGC_threads
  
  # 线程数组
  printf "\n----- Worker Array -----\n"
  printf "_workers array address: %p\n", this->_workers->_workers
  printf "_workers[0]: %p\n", this->_workers->_workers[0]
  
  continue
end
run
```

### 10.2 预期输出

```
========== WorkGang Creation ==========
----- Parameters -----
ParallelGCThreads: 13                           ✅
UseDynamicNumberOfGCThreads: 1                  ✅ (true)

----- WorkGang Fields -----
_name: GC Thread                                ✅
_total_workers: 13                              ✅
_active_workers: 1                              ✅ (动态模式)
_created_workers: 1                             ✅ (只创建 1 个)
_are_GC_task_threads: 1                         ✅ (true)
_are_ConcurrentGC_threads: 0                    ✅ (false)

----- Worker Array -----
_workers array address: 0x7f...                 ✅
_workers[0]: 0x7f... (非 NULL)                  ✅ (第一个已创建)
```

### 10.3 日志输出验证

```bash
# 启动参数添加
-Xlog:gc+task=trace

# 输出
[0.010s][trace][gc,task] Constructing work gang GC Thread with 13 threads
[0.010s][trace][gc,task] Adding initial GC Thread(s) previously created workers 0 active workers 1 total created workers 1
```

---

## 11. 与其他线程池对比

| 特性 | WorkGang (_workers) | ConcurrentMark (_concurrent_workers) |
|------|---------------------|--------------------------------------|
| 名称 | "GC Thread" | "G1 Conc" |
| 线程数 | ParallelGCThreads (13) | ConcGCThreads (3) |
| 线程类型 | pgc_thread | cgc_thread |
| are_GC_task_threads | true | false |
| are_ConcurrentGC_threads | false | true |
| 用途 | STW 并行任务 | 并发标记 |

---

## 12. 总结

### 12.1 核心要点

1. **WorkGang 是 G1 的 STW 并行线程池**
   - 线程数 = ParallelGCThreads = 13
   - 用于 Young GC、Mixed GC、Full GC

2. **动态线程管理**
   - `UseDynamicNumberOfGCThreads=true`（默认）
   - 初始只创建 1 个线程
   - GC 时按需增加

3. **线程类型**
   - `pgc_thread`（Parallel GC Thread）
   - 非并发 GC 线程（STW 阶段工作）

### 12.2 8GB 堆（16 核）初始状态

| 字段 | 值 | 说明 |
|------|-----|------|
| _total_workers | 13 | 最大线程数 |
| _active_workers | 1 | 当前活跃 |
| _created_workers | 1 | 已创建 |
| _are_GC_task_threads | true | STW 线程 |
| _are_ConcurrentGC_threads | false | 非并发 |

---

## 待分析节点更新

| 节点 | 主题 | 状态 |
|------|------|------|
| B.1.1 | ParallelGCThreads 计算算法 | ✅ |
| F.1 | G1Predictions 预测器 | ✅ |
| E.5.1 | RefToScanQueue 工作窃取队列 | ✅ |
| D.4.1 | G1Policy 构造函数 | ✅ |
| F.2 | G1Analytics 分析器 | ✅ |
| F.3 | G1MMUTracker | ✅ |
| F.4 | G1IHOPControl | ✅ |
| C.1.1 | Region 大小计算算法 | ✅ |
| C.2 | RemSet 大小计算 | ✅ |
| C.3 | initialize_alignments() | ✅ |
| **E.1** | **WorkGang 创建** | **✅** |
