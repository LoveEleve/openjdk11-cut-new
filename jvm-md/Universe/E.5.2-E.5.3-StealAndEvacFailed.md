# E.5.2 + E.5.3 工作窃取负载均衡与疏散失败统计 - 深度分析

> 源码位置：`taskqueue.hpp`、`taskqueue.cpp`、`copyFailedInfo.hpp`、`g1CollectedHeap.cpp`
> 本节分析 G1 GC 中工作窃取的负载均衡机制和疏散失败的统计处理

---

## 1. 功能定位

### E.5.2 工作窃取负载均衡

**一句话说明**：当 GC 线程自己的队列空了，它会从其他线程"偷"任务，通过 `steal_best_of_2()` 算法实现动态负载均衡。

### E.5.3 EvacuationFailedInfo

**一句话说明**：记录疏散失败的统计信息（失败次数、对象大小），用于 JFR 事件报告和 GC 后的清理决策。

---

## 2. E.5.2 工作窃取负载均衡

### 2.1 steal() 方法 - 偷窃入口

```cpp
// taskqueue.inline.hpp:258-267
template<class T, MEMFLAGS F>
bool GenericTaskQueueSet<T, F>::steal(uint queue_num, int* seed, E& t) {
    // 尝试 2 * N 次（N = 队列数量）
    for (uint i = 0; i < 2 * _n; i++) {
        if (steal_best_of_2(queue_num, seed, t)) {
            TASKQUEUE_STATS_ONLY(queue(queue_num)->stats.record_steal(true));
            return true;
        }
    }
    TASKQUEUE_STATS_ONLY(queue(queue_num)->stats.record_steal(false));
    return false;
}
```

**关键点**：
- 13 个线程时，最多尝试 `2 × 13 = 26` 次
- 每次尝试调用 `steal_best_of_2()`
- 成功则记录统计并返回

### 2.2 steal_best_of_2() - "二选一"策略【核心】

```cpp
// taskqueue.inline.hpp:236-255
template<class T, MEMFLAGS F>
bool GenericTaskQueueSet<T, F>::steal_best_of_2(uint queue_num, int* seed, E& t) {
    if (_n > 2) {
        // ① 随机选第一个队列（排除自己）
        uint k1 = queue_num;
        while (k1 == queue_num) 
            k1 = TaskQueueSetSuper::randomParkAndMiller(seed) % _n;
        
        // ② 随机选第二个队列（排除自己和 k1）
        uint k2 = queue_num;
        while (k2 == queue_num || k2 == k1) 
            k2 = TaskQueueSetSuper::randomParkAndMiller(seed) % _n;
        
        // ③ 比较两个队列大小，偷较大的
        uint sz1 = _queues[k1]->size();
        uint sz2 = _queues[k2]->size();
        
        if (sz2 > sz1) 
            return _queues[k2]->pop_global(t);
        else 
            return _queues[k1]->pop_global(t);
            
    } else if (_n == 2) {
        // 只有两个队列，直接偷另一个
        uint k = (queue_num + 1) % 2;
        return _queues[k]->pop_global(t);
    } else {
        return false;  // 只有一个队列，无法偷
    }
}
```

### 2.3 为什么是"二选一"而不是"选最大的"？

```
┌─────────────────────────────────────────────────────────────────────────┐
│ 方案对比                                                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  方案 A：选最大的队列（贪心）                                            │
│  ────────────────────────────────────────────────────────────────────    │
│  优点：每次都能偷到最多的任务                                            │
│  缺点：                                                                  │
│    • 需要遍历所有 N 个队列 → O(N) 开销                                  │
│    • 所有空闲线程都去偷最大的 → 严重竞争                                │
│    • CAS 失败率高 → 浪费 CPU                                            │
│                                                                          │
│  方案 B：随机二选一（概率）                                              │
│  ────────────────────────────────────────────────────────────────────    │
│  优点：                                                                  │
│    • 只采样 2 个队列 → O(1) 开销                                        │
│    • 竞争分散到不同队列                                                  │
│    • 概率上偏向较大的队列                                                │
│  缺点：不是最优选择（但足够好）                                          │
│                                                                          │
│  数学直觉：                                                              │
│  ────────────────────────────────────────────────────────────────────    │
│  设 N=13，最大队列有 1000 个任务                                         │
│  随机选两个，至少选中最大那个的概率 ≈ 1 - (12/13)² ≈ 14.8%              │
│  即使没选中最大的，选中的两个中较大者也是"较优"选择                      │
│                                                                          │
│  工作窃取的经典论文（ABP 1997）证明：                                    │
│  随机二选一在实践中接近最优，且大幅减少竞争                              │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.4 Park-Miller 随机数生成器

```cpp
// taskqueue.cpp:114-130
int TaskQueueSetSuper::randomParkAndMiller(int *seed0) {
    const int a =      16807;      // 乘数
    const int m = 2147483647;      // 模数（2³¹ - 1）
    const int q =     127773;      // m div a
    const int r =       2836;      // m mod a
    
    int seed = *seed0;
    int hi   = seed / q;
    int lo   = seed % q;
    int test = a * lo - r * hi;
    
    if (test > 0)
        seed = test;
    else
        seed = test + m;
    
    *seed0 = seed;
    return seed;
}
```

**特点**：
- 线性同余发生器（LCG）的变体
- 无除法版本（避免除法指令的高延迟）
- 周期约 2³¹（足够长）
- 每个 GC 线程有自己的 `_hash_seed`，无竞争

### 2.5 G1 中的工作窃取使用

```cpp
// g1ParScanThreadState.inline.hpp:141-152
void G1ParScanThreadState::steal_and_trim_queue(RefToScanQueueSet *task_queues) {
    StarTask stolen_task;
    
    // 循环偷任务，直到偷不到为止
    while (task_queues->steal(_worker_id, &_hash_seed, stolen_task)) {
        assert(verify_task(stolen_task), "sanity");
        dispatch_reference(stolen_task);  // 处理偷来的引用
        
        // 处理过程中可能产生新任务，先处理自己的队列
        trim_queue();
    }
}
```

### 2.6 终止协议 ParallelTaskTerminator

```cpp
// taskqueue.cpp:152-237
bool ParallelTaskTerminator::offer_termination(TerminatorTerminator* terminator) {
    assert(_n_threads > 0, "Initialization is incorrect");
    
    // ① 原子递增"愿意终止"的线程计数
    Atomic::inc(&_offered_termination);
    
    uint yield_count = 0;
    uint hard_spin_count = 0;
    uint hard_spin_limit = WorkStealingHardSpins;  // 默认 4096
    
    while (true) {
        // ② 检查是否所有线程都愿意终止
        if (_offered_termination == _n_threads) {
            return true;  // 全部完成！
        }
        
        // ③ 自旋/yield/sleep 策略
        if (yield_count <= WorkStealingYieldsBeforeSleep) {  // 默认 5000
            yield_count++;
            
            if (hard_spin_count > WorkStealingSpinToYieldRatio) {  // 默认 10
                yield();  // 让出 CPU
                hard_spin_count = 0;
            } else {
                // 硬自旋
                for (uint j = 0; j < hard_spin_limit; j++) {
                    SpinPause();  // x86: PAUSE 指令
                }
                hard_spin_count++;
            }
        } else {
            yield_count = 0;
            sleep(WorkStealingSleepMillis);  // 默认 1ms
        }
        
        // ④ 再次检查是否有新任务
        if (peek_in_queue_set()) {
            Atomic::dec(&_offered_termination);
            return false;  // 发现新任务，继续工作
        }
    }
}
```

```
终止协议状态机：

                    ┌─────────────────────────────────────────────────────┐
                    │                                                      │
                    ▼                                                      │
┌──────────┐    ┌─────────────┐    ┌─────────────┐    ┌────────────┐     │
│ 处理任务  │───▶│ 队列空，偷  │───▶│ 偷不到，终止 │───▶│ 全部终止？  │─NO──┘
└──────────┘    └─────────────┘    │ 提议        │    └────────────┘
      ▲               │            └─────────────┘          │
      │               │                   │                 │ YES
      │               ▼                   │                 ▼
      │         ┌─────────────┐           │          ┌────────────┐
      └─────────│ 偷到任务    │           │          │ 任务完成！  │
                └─────────────┘           │          └────────────┘
                                          │
                        ┌─────────────────┘
                        │
                        ▼
            ┌─────────────────────────────────────────┐
            │ 自旋等待策略（避免忙等待 CPU 浪费）      │
            │                                          │
            │  阶段 1：硬自旋（SpinPause）             │
            │          默认 4096 次                    │
            │          ↓ 超过 10 轮                    │
            │  阶段 2：yield()（让出 CPU）             │
            │          ↓ 超过 5000 次                  │
            │  阶段 3：sleep(1ms)                      │
            │                                          │
            │  每次等待后检查 peek_in_queue_set()      │
            │  如果发现新任务 → 返回继续工作           │
            └─────────────────────────────────────────┘
```

### 2.7 终止参数（可调优）

| 参数 | 默认值 | 含义 |
|------|--------|------|
| `WorkStealingHardSpins` | 4096 | 每轮硬自旋的 SpinPause 次数 |
| `WorkStealingSpinToYieldRatio` | 10 | 多少轮硬自旋后才 yield |
| `WorkStealingYieldsBeforeSleep` | 5000 | 多少次 yield 后才 sleep |
| `WorkStealingSleepMillis` | 1 | sleep 时长（毫秒）|

**生产实践**：
- 这些参数通常不需要调整
- 如果 GC 日志显示 `Termination` 时间长，可能是负载不均衡（而非参数问题）
- 监控方式：`-Xlog:gc*=debug` 查看 `Termination` 阶段

---

## 3. E.5.3 EvacuationFailedInfo 疏散失败统计

### 3.1 什么是疏散失败（Evacuation Failure）？

```
正常疏散：
┌─────────────────┐          ┌─────────────────┐
│  From Region    │          │   To Region     │
│  (CSet 成员)    │   复制   │  (Survivor/Old) │
│  ┌───────────┐  │  ─────▶  │  ┌───────────┐  │
│  │  Object   │  │          │  │  Object'  │  │
│  └───────────┘  │          │  └───────────┘  │
└─────────────────┘          └─────────────────┘

疏散失败（To-space Exhausted）：
┌─────────────────┐          ┌─────────────────┐
│  From Region    │          │   To Region     │
│  ┌───────────┐  │   ✗      │  （已满！）      │
│  │  Object   │  │  ─────▶  │                 │
│  └───────────┘  │  失败    │                 │
│       │         │          └─────────────────┘
│       ▼         │
│  保留在原地     │
│  设置自转发指针 │
└─────────────────┘
```

**触发条件**：
- To-space（Survivor 或 Old）没有足够空间
- 通常发生在堆使用率很高时
- 日志标志：`To-space exhausted`

### 3.2 CopyFailedInfo 基类

```cpp
// copyFailedInfo.hpp:32-64
class CopyFailedInfo : public CHeapObj<mtGC> {
    size_t    _first_size;     // 第一个失败对象的大小
    size_t    _smallest_size;  // 最小失败对象的大小
    size_t    _total_size;     // 所有失败对象的总大小
    uint      _count;          // 失败次数

public:
    CopyFailedInfo() : _first_size(0), _smallest_size(0), 
                       _total_size(0), _count(0) {}

    // 注册一次复制失败
    virtual void register_copy_failure(size_t size) {
        if (_first_size == 0) {
            _first_size = size;
            _smallest_size = size;
        } else if (size < _smallest_size) {
            _smallest_size = size;
        }
        _total_size += size;
        _count++;
    }

    // 重置统计
    virtual void reset() {
        _first_size = 0;
        _smallest_size = 0;
        _total_size = 0;
        _count = 0;
    }

    // 查询方法
    bool has_failed() const { return _count != 0; }
    size_t first_size() const { return _first_size; }
    size_t smallest_size() const { return _smallest_size; }
    size_t total_size() const { return _total_size; }
    uint failed_count() const { return _count; }
};
```

### 3.3 EvacuationFailedInfo 子类

```cpp
// copyFailedInfo.hpp:91
class EvacuationFailedInfo : public CopyFailedInfo {};
// G1 特化，目前没有额外字段
// 另一个子类 PromotionFailedInfo 会记录线程 ID（用于 ParNew/CMS）
```

### 3.4 每个 GC 线程一个实例

```cpp
// g1CollectedHeap.hpp:817
EvacuationFailedInfo* _evacuation_failed_info_array;

// g1CollectedHeap.cpp:1521-1527
_evacuation_failed_info_array = NEW_C_HEAP_ARRAY(EvacuationFailedInfo, n_queues, mtGC);
for (uint i = 0; i < n_queues; i++) {
    RefToScanQueue *q = new RefToScanQueue();
    q->initialize();
    _task_queues->register_queue(i, q);
    // 使用 placement new 初始化
    ::new(&_evacuation_failed_info_array[i]) EvacuationFailedInfo();
}
```

**为什么每个线程一个？**
- 避免多线程竞争
- 记录失败时无需加锁
- GC 结束后汇总

### 3.5 疏散失败时的处理

```cpp
// g1CollectedHeap.cpp:3888-3898
void G1CollectedHeap::preserve_mark_during_evac_failure(uint worker_id, 
                                                        oop obj, markOop m) {
    // ① 设置全局失败标志
    if (!_evacuation_failed) {
        _evacuation_failed = true;
    }
    
    // ② 记录到线程本地统计
    _evacuation_failed_info_array[worker_id].register_copy_failure(obj->size());
    
    // ③ 保存对象的 mark word（后续恢复用）
    _preserved_marks_set.get(worker_id)->push_if_necessary(obj, m);
}
```

```cpp
// g1ParScanThreadState.cpp:362-370
// 实际调用点
if (!r->evacuation_failed()) {
    r->set_evacuation_failed(true);
    _g1h->hr_printer()->evac_failure(r);
}
_g1h->preserve_mark_during_evac_failure(_worker_id, old, m);
```

### 3.6 GC 结束后的汇总

```cpp
// g1CollectedHeap.cpp:3741-3750
if (evacuation_failed()) {
    // ① 重新计算堆使用量（因为有些对象没被复制）
    set_used(recalculate_used());
    
    if (_archive_allocator != NULL) {
        _archive_allocator->clear_used();
    }
    
    // ② 汇总所有线程的失败统计，报告 JFR 事件
    for (uint i = 0; i < ParallelGCThreads; i++) {
        if (_evacuation_failed_info_array[i].has_failed()) {
            _gc_tracer_stw->report_evacuation_failed(_evacuation_failed_info_array[i]);
        }
    }
}
```

### 3.7 疏散失败后的清理

```cpp
// g1CollectedHeap.cpp:4864-4869
if (evacuation_failed()) {
    restore_after_evac_failure();
    
    // 重置计数器和标志
    NOT_PRODUCT(reset_evacuation_should_fail();)
}
```

---

## 4. 整体流程图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         G1 Young GC 扫描阶段                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                     G1ParTask.work(worker_id)                        │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                    │                                         │
│                                    ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ 1. 扫描根引用                                                        │    │
│  │    • Java 栈                                                         │    │
│  │    • 静态变量                                                        │    │
│  │    • JNI 引用                                                        │    │
│  │    → 发现的引用 push 到自己的 RefToScanQueue                         │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                    │                                         │
│                                    ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ 2. G1ParEvacuateFollowersClosure.do_void()                          │    │
│  │                                                                      │    │
│  │    ┌──────────────────────────────────────────────────────────┐     │    │
│  │    │ pss->trim_queue();  // 处理自己队列                       │     │    │
│  │    │                                                           │     │    │
│  │    │ do {                                                      │     │    │
│  │    │     pss->steal_and_trim_queue(queues());  // 偷+处理     │     │    │
│  │    │ } while (!offer_termination());  // 终止协议              │     │    │
│  │    └──────────────────────────────────────────────────────────┘     │    │
│  │                                                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                    │                                         │
│          ┌─────────────────────────┼─────────────────────────┐              │
│          │                         │                         │              │
│          ▼                         ▼                         ▼              │
│  ┌───────────────┐        ┌───────────────┐        ┌───────────────┐       │
│  │  Thread #0    │        │  Thread #1    │        │  Thread #12   │       │
│  │  ───────────  │        │  ───────────  │        │  ───────────  │       │
│  │  pop_local()  │        │  pop_local()  │        │  pop_local()  │       │
│  │  process()    │        │  (队列空)     │        │  process()    │       │
│  │  push()       │←─steal─│  steal()      │        │  push()       │       │
│  │  ...          │        │  process()    │        │  ...          │       │
│  └───────────────┘        └───────────────┘        └───────────────┘       │
│                                                                              │
│  ────────────────────────────────────────────────────────────────────────   │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ 3. 复制对象到 To-space                                               │    │
│  │                                                                      │    │
│  │    正常情况：对象复制到 Survivor 或 Old Region                       │    │
│  │                                                                      │    │
│  │    疏散失败：                                                        │    │
│  │    ┌────────────────────────────────────────────────────────────┐   │    │
│  │    │ _evacuation_failed = true;                                  │   │    │
│  │    │ _evacuation_failed_info_array[worker_id]                    │   │    │
│  │    │     .register_copy_failure(obj->size());                    │   │    │
│  │    │ _preserved_marks_set.get(worker_id)                         │   │    │
│  │    │     ->push_if_necessary(obj, m);                            │   │    │
│  │    └────────────────────────────────────────────────────────────┘   │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ────────────────────────────────────────────────────────────────────────   │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ 4. 终止协议                                                          │    │
│  │                                                                      │    │
│  │    所有线程：                                                        │    │
│  │    • 自己的队列空                                                    │    │
│  │    • 偷不到任务                                                      │    │
│  │    • 调用 offer_termination()                                        │    │
│  │                                                                      │    │
│  │    当 _offered_termination == _n_threads 时，扫描阶段结束            │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. 内存布局

### 5.1 EvacuationFailedInfo 数组

```
_evacuation_failed_info_array（13 个元素，每个 32 字节）
│
├── [0] EvacuationFailedInfo（Thread #0 使用）
│   ├── _first_size:     8 bytes  (size_t)
│   ├── _smallest_size:  8 bytes  (size_t)
│   ├── _total_size:     8 bytes  (size_t)
│   └── _count:          4 bytes  (uint) + 4 bytes padding
│
├── [1] EvacuationFailedInfo（Thread #1 使用）
│   └── ...
│
├── ...
│
└── [12] EvacuationFailedInfo（Thread #12 使用）
    └── ...

总大小：13 × 32 = 416 bytes
```

### 5.2 与 RefToScanQueue 的关系

```
G1CollectedHeap
│
├── _task_queues: RefToScanQueueSet*
│   │
│   └── _queues[13]: RefToScanQueue*
│       ├── [0] → RefToScanQueue（Thread #0）
│       ├── [1] → RefToScanQueue（Thread #1）
│       └── ...
│
├── _evacuation_failed_info_array: EvacuationFailedInfo*
│   │
│   └── 数组[13]: EvacuationFailedInfo
│       ├── [0] → EvacuationFailedInfo（Thread #0）
│       ├── [1] → EvacuationFailedInfo（Thread #1）
│       └── ...
│
└── _evacuation_failed: bool（全局标志）

索引对应关系：
• _task_queues[i] 和 _evacuation_failed_info_array[i] 
  都被 Thread #i 使用
• 无锁设计：每个线程只操作自己的元素
```

---

## 6. 生产环境实践

### 6.1 监控工作窃取效率

**GC 日志方式**：
```bash
-Xlog:gc*=debug
```

输出示例：
```
[debug] GC(5) Termination (ms): Min: 0.1, Avg: 0.5, Max: 2.3, Diff: 2.2
[debug] GC(5) Termination attempts: 123
```

**解读**：
- `Termination` 时间越短越好
- 时间长说明负载不均衡或线程数过多
- `attempts` 次数可反映偷窃活跃度

### 6.2 监控疏散失败

**GC 日志方式**：
```bash
-Xlog:gc*=info
```

输出示例：
```
[info] GC(12) To-space exhausted
[debug] Evacuation Failure: 5.2ms
[debug] Recalculate Used: 1.1ms
[debug] Remove Self Forwards: 3.8ms
```

**JFR 事件**：
```java
// jdk.G1EvacuationYoungStatistics 或 jdk.G1EvacuationOldStatistics
// 字段：failedCount, firstSize, smallestSize, totalSize
```

### 6.3 预防疏散失败

| 参数 | 推荐值 | 作用 |
|------|--------|------|
| `-XX:G1ReservePercent` | 10（默认） | 保留堆空间比例 |
| `-XX:G1HeapWastePercent` | 5（默认） | 允许的碎片比例 |
| `-XX:MaxGCPauseMillis` | 根据需求 | 过小可能导致 CSet 过大 |

**最佳实践**：
1. 保证 `-Xms = -Xmx`（避免堆扩展带来的不确定性）
2. 监控 `G1ReservePercent` 是否足够
3. 如果频繁疏散失败，考虑增大堆或调整暂停目标

### 6.4 疏散失败的影响

```
疏散失败的代价：
┌───────────────────────────────────────────────────────────────────────────┐
│                                                                            │
│  1. 性能影响                                                               │
│     • 需要重新计算堆使用量                                                 │
│     • 需要移除自转发指针                                                   │
│     • 需要恢复 mark word                                                   │
│     → 额外的 STW 时间                                                      │
│                                                                            │
│  2. 内存影响                                                               │
│     • 失败的 Region 保留在原处                                             │
│     • 可能触发后续的 Full GC                                               │
│                                                                            │
│  3. 触发条件（需要同时满足）                                               │
│     • 堆使用率高                                                           │
│     • 存活对象多                                                           │
│     • 预留空间不足                                                         │
│                                                                            │
└───────────────────────────────────────────────────────────────────────────┘
```

---

## 7. GDB 验证

### 7.1 验证脚本

```gdb
# 断点设置
break g1CollectedHeap.cpp:1535

# 运行到断点
run -Xms8g -Xmx8g -XX:+UseG1GC -version

# 查看 RefToScanQueueSet
p _task_queues
p _task_queues->_n
p _task_queues->_queues[0]

# 查看 EvacuationFailedInfo 数组
p _evacuation_failed_info_array
p _evacuation_failed_info_array[0]

# 查看全局失败标志
p _evacuation_failed

# 查看终止协议参数（需要在运行时）
p WorkStealingHardSpins
p WorkStealingSpinToYieldRatio
p WorkStealingYieldsBeforeSleep
p WorkStealingSleepMillis
```

### 7.2 预期输出

```
========== RefToScanQueueSet ==========
_task_queues = 0x7ffff0042670
_n = 13
_queues = 0x7ffff00426d0

========== EvacuationFailedInfo 数组 ==========
_evacuation_failed_info_array = 0x7ffff0043ac0
_evacuation_failed_info_array[0] = {
    _first_size = 0,
    _smallest_size = 0,
    _total_size = 0,
    _count = 0
}

========== 全局标志 ==========
_evacuation_failed = false

========== 终止协议参数 ==========
WorkStealingHardSpins = 4096
WorkStealingSpinToYieldRatio = 10
WorkStealingYieldsBeforeSleep = 5000
WorkStealingSleepMillis = 1
```

---

## 8. 总结

### 8.1 E.5.2 工作窃取负载均衡

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│  核心算法：steal_best_of_2()                                             │
│  ────────────────────────────────────────────────────────────────────    │
│  • 随机选两个队列（不是自己）                                            │
│  • 比较大小，偷较大的                                                    │
│  • 使用 pop_global() 从队头偷（FIFO）                                    │
│  • 概率上偏向大队列，同时分散竞争                                        │
│                                                                          │
│  终止协议：ParallelTaskTerminator                                        │
│  ────────────────────────────────────────────────────────────────────    │
│  • 所有线程都愿意终止时才真正结束                                        │
│  • 自旋 → yield → sleep 三阶段等待                                       │
│  • 发现新任务则返回继续工作                                              │
│                                                                          │
│  性能特点：                                                              │
│  ────────────────────────────────────────────────────────────────────    │
│  • 本地操作无锁（push/pop_local）                                        │
│  • 偷窃操作仅 CAS（pop_global）                                          │
│  • 缓存行填充避免 false sharing                                          │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 8.2 E.5.3 EvacuationFailedInfo

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│  数据结构：                                                              │
│  ────────────────────────────────────────────────────────────────────    │
│  • 继承 CopyFailedInfo                                                   │
│  • 字段：first_size, smallest_size, total_size, count                    │
│  • 每个 GC 线程一个实例（无锁设计）                                      │
│                                                                          │
│  触发条件：                                                              │
│  ────────────────────────────────────────────────────────────────────    │
│  • To-space 空间不足                                                     │
│  • 日志标志：To-space exhausted                                          │
│                                                                          │
│  处理流程：                                                              │
│  ────────────────────────────────────────────────────────────────────    │
│  • 设置 _evacuation_failed = true                                        │
│  • 记录到 _evacuation_failed_info_array[worker_id]                       │
│  • 保存对象的 mark word                                                  │
│  • GC 结束后：汇总统计、报告 JFR、清理                                   │
│                                                                          │
│  生产影响：                                                              │
│  ────────────────────────────────────────────────────────────────────    │
│  • 额外 STW 时间（清理、恢复）                                           │
│  • 可能触发 Full GC                                                      │
│  • 通过 G1ReservePercent 预防                                            │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 8.3 关键数值（16 核机器）

| 项目 | 值 |
|------|-----|
| ParallelGCThreads | 13 |
| 队列/统计数组元素数 | 13 |
| 每次 steal 最多尝试 | 26 次 |
| WorkStealingHardSpins | 4096 |
| WorkStealingYieldsBeforeSleep | 5000 |
| EvacuationFailedInfo 数组大小 | 416 bytes |

---

## 待分析节点更新

| 节点 | 主题 | 状态 |
|------|------|------|
| **E.5.2** | 工作窃取负载均衡 | ✅ |
| - | steal_best_of_2 算法 | ✅ |
| - | ParallelTaskTerminator 终止协议 | ✅ |
| **E.5.3** | EvacuationFailedInfo | ✅ |
| - | 疏散失败统计结构 | ✅ |
| - | 疏散失败处理流程 | ✅ |
