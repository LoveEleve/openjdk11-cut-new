# E.5.1 RefToScanQueue 工作窃取队列 - 深度分析

> 源码位置：`taskqueue.hpp`、`taskqueue.inline.hpp`、`g1ParScanThreadState.inline.hpp`
> 13 个 GC 线程如何高效协作？答案是：**工作窃取（Work Stealing）**

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文是对 **E.5.1 RefToScanQueue 工作窃取队列 - 深度分析** 的深度源码分析：从数据结构到算法流程，逐层剖析其实现原理，并通过 GDB 验证关键结论。

### 0.2 为什么需要？

深入理解 JVM 内部实现，不仅能帮助排查生产问题，更能建立对 JVM 行为的精确预测能力——知道『为什么』比知道『是什么』更重要。

### 0.3 怎么解决？

采用「数据结构 → 算法流程 → GDB 验证」三步法：先完整分析所有涉及的数据结构（字段含义/sizeof/生命周期），再分析算法流程（每步有 why），最后用 GDB 实际验证关键结论。

### 0.4 为什么这样设计？

JVM 的每个设计决策都有其历史背景和性能考量。本文在分析每个关键设计时，都会解释「为什么这样而不是那样」，帮助读者建立设计直觉。

---


## 1. 功能定位

### 一句话说明
**RefToScanQueue 是 G1 GC 并行扫描阶段的任务队列**，每个 GC 线程有自己的队列，当自己的队列空了就从其他线程"偷"任务，实现动态负载均衡。

### 在整体流程中的位置
```
G1 Young GC 扫描阶段
│
├── 13 个 GC 线程并行工作
│   │
│   ├── Thread #0: 自己的 RefToScanQueue[0]
│   ├── Thread #1: 自己的 RefToScanQueue[1]
│   ├── ...
│   └── Thread #12: 自己的 RefToScanQueue[12]
│
├── 每个线程的工作流程：
│   │
│   │  ┌─────────────────────────────────────────┐
│   │  │ 1. push(): 发现新引用 → 压入自己的队列  │
│   │  │ 2. pop_local(): 处理自己队列的任务      │
│   │  │ 3. steal(): 自己队列空了 → 偷别人的任务 │
│   │  └─────────────────────────────────────────┘
│   │
│   └── 直到所有队列都空
│
└── 所有线程完成 → 扫描阶段结束
```

### 为什么需要工作窃取？

```
问题场景：13 个线程分配到不同的 Region 扫描

┌────────────────────────────────────────────────────────────────────┐
│ 静态分配（不用工作窃取）                                            │
│ ────────────────────────────────────────────────────────────────── │
│                                                                     │
│ Thread #0: Region 0-10 (存活对象多，耗时 50ms)                      │
│ Thread #1: Region 11-20 (存活对象少，耗时 10ms)                     │
│ Thread #2: Region 21-30 (存活对象少，耗时 10ms)                     │
│ ...                                                                 │
│                                                                     │
│ 问题：Thread #1,#2 完成后空闲，而 Thread #0 还在忙                  │
│ 总耗时：50ms（取决于最慢的线程）                                    │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│ 工作窃取                                                            │
│ ────────────────────────────────────────────────────────────────── │
│                                                                     │
│ Thread #1 完成自己的任务后，从 Thread #0 偷一些任务                 │
│ Thread #2 也从 Thread #0 偷任务                                     │
│                                                                     │
│ 结果：负载动态均衡，所有线程差不多同时完成                          │
│ 总耗时：约 20ms（负载均分）                                         │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

---

## 2. 类型定义

### 2.1 RefToScanQueue 的定义

```cpp
// g1CollectedHeap.hpp:98-99
typedef OverflowTaskQueue<StarTask, mtGC>         RefToScanQueue;
typedef GenericTaskQueueSet<RefToScanQueue, mtGC> RefToScanQueueSet;
```

### 2.2 类继承关系

```
TaskQueueSuper<N=131072, F=mtGC>
    │
    │  • _bottom: 队尾（push/pop_local 操作）
    │  • _age: 队头（pop_global/steal 操作）
    │
    └── GenericTaskQueue<StarTask, mtGC, 131072>
        │
        │  • _elems[131072]: 元素数组
        │  • push(): 压入任务
        │  • pop_local(): 本地弹出
        │  • pop_global(): 全局弹出（被偷）
        │
        └── OverflowTaskQueue<StarTask, mtGC, 131072>  ← RefToScanQueue
            │
            │  • _overflow_stack: 溢出栈（队列满了用这个）
            │  • push(): 先尝试队列，满了放溢出栈
            │
            └── 每个 GC 线程一个实例
```

### 2.3 元素类型 StarTask

```cpp
// StarTask 是一个联合类型，存储对象引用指针
// 可以是 oop* 或 narrowOop*（压缩指针）
class StarTask {
    void* _holder;  // 实际存储的指针
public:
    bool is_narrow() const;  // 判断是否是 narrowOop*
    operator oop*() const;
    operator narrowOop*() const;
};
```

---

## 3. 核心数据结构

### 3.1 双端队列（Deque）结构

```
GenericTaskQueue 使用一个环形数组实现双端队列：

┌─────────────────────────────────────────────────────────────────────┐
│                                                                      │
│   _elems[0]  [1]  [2]  [3]  [4]  [5]  [6]  [7]  ...  [N-1]          │
│      │                  │              │                             │
│      └──────────────────┼──────────────┘                             │
│                         │                                            │
│              ┌──────────┴──────────┐                                 │
│              │                     │                                 │
│           _age.top()            _bottom                              │
│           (队头)                 (队尾)                              │
│              │                     │                                 │
│              ▼                     ▼                                 │
│        ┌─────────────────────────────┐                               │
│        │  有效元素区域               │                               │
│        │  [top, bottom)              │                               │
│        └─────────────────────────────┘                               │
│              │                     │                                 │
│          pop_global()          push() / pop_local()                  │
│          (偷任务)              (本地操作)                            │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘

关键点：
• push()/pop_local() 在 _bottom 端操作（LIFO，后进先出）
• pop_global() 在 _age.top() 端操作（被其他线程偷）
• 这是 ABP（Aurora-Blumofe-Plaxton）算法的经典实现
```

### 3.2 队列大小

```cpp
// globalDefinitions.hpp:1029
#define TASKQUEUE_SIZE (NOT_LP64(1<<14) LP64_ONLY(1<<17))
// 64位系统：2^17 = 131072 个元素
// 32位系统：2^14 = 16384 个元素

// 实际最大元素数
uint max_elems() const { return N - 2; }  // 131072 - 2 = 131070
```

### 3.3 Age 结构（原子操作的关键）

```cpp
class Age {
    union {
        size_t _data;       // 64位整体
        struct {
            idx_t _top;     // 32位：队头索引
            idx_t _tag;     // 32位：ABA 问题防护标签
        } _fields;
    };
};

// 为什么需要 _tag？
// 防止 ABA 问题：
//   时刻 T1: top=5, 线程 A 读取 _elems[5]
//   时刻 T2: 其他线程把队列清空，又加入新元素，top 又变成 5
//   时刻 T3: 线程 A 的 CAS 可能误认为状态没变
//   解决：每次 top 回到 0 时，_tag++，CAS 时检查整个 Age
```

---

## 4. 核心算法：ABP 双端队列

### 4.1 论文来源

```
原始论文：
Arora, N. S., Blumofe, R. D., and Plaxton, C. G.
"Thread scheduling for multiprogrammed multiprocessors."
Theory of Computing Systems 34, 2 (2001), 115-144.

改进版本（弱内存模型）：
Le, N. M., Pop, A., Cohen A., and Nardell, F. Z.
"Correct and efficient work-stealing for weak memory models"
PPoPP 2013
```

### 4.2 push() - 压入任务（本地线程）

```cpp
// taskqueue.inline.hpp:78-98
template<class E, MEMFLAGS F, unsigned int N>
inline bool GenericTaskQueue<E, F, N>::push(E t) {
    uint localBot = _bottom;                    // ① 读取队尾
    idx_t top = _age.top();                     // ② 读取队头
    uint dirty_n_elems = dirty_size(localBot, top);
    
    if (dirty_n_elems < max_elems()) {          // ③ 检查是否有空间
        _elems[localBot] = t;                   // ④ 放入元素
        OrderAccess::release_store(&_bottom,    // ⑤ 更新队尾（带内存屏障）
                                   increment_index(localBot));
        return true;
    } else {
        return push_slow(t, dirty_n_elems);     // ⑥ 队列满，走慢速路径
    }
}
```

```
图解 push() 操作：

之前状态：
  _elems: [A] [B] [C] [ ] [ ] [ ]
           ↑           ↑
          top        bottom

push(D) 后：
  _elems: [A] [B] [C] [D] [ ] [ ]
           ↑               ↑
          top            bottom
```

### 4.3 pop_local() - 本地弹出（本地线程）

```cpp
// taskqueue.inline.hpp:154-194
template<class E, MEMFLAGS F, unsigned int N>
inline bool GenericTaskQueue<E, F, N>::pop_local(volatile E& t, uint threshold) {
    uint localBot = _bottom;
    uint dirty_n_elems = dirty_size(localBot, _age.top());
    
    if (dirty_n_elems <= threshold) return false;  // ① 元素太少，不弹出
    
    localBot = decrement_index(localBot);          // ② 先减 bottom
    _bottom = localBot;
    OrderAccess::fence();                          // ③ 内存屏障！
    
    t = _elems[localBot];                          // ④ 读取元素
    
    idx_t tp = _age.top();
    if (size(localBot, tp) > 0) {                  // ⑤ 还有元素，快速返回
        return true;
    } else {
        // ⑥ 只剩一个元素，可能和 steal 竞争
        return pop_local_slow(localBot, _age.get());
    }
}
```

```
图解 pop_local() 操作：

之前状态：
  _elems: [A] [B] [C] [D]
           ↑           ↑
          top        bottom

pop_local() 后（返回 D）：
  _elems: [A] [B] [C] [D]    ← D 还在数组里，但已经"逻辑删除"
           ↑       ↑
          top    bottom

特点：LIFO（后进先出），最近 push 的最先被处理
```

### 4.4 pop_global() - 全局弹出（其他线程偷）

```cpp
// taskqueue.inline.hpp:204-233
template<class E, MEMFLAGS F, unsigned int N>
bool GenericTaskQueue<E, F, N>::pop_global(volatile E& t) {
    Age oldAge = _age.get();                       // ① 读取当前 Age
    OrderAccess::fence();                          // ② 内存屏障
    uint localBot = OrderAccess::load_acquire(&_bottom);
    uint n_elems = size(localBot, oldAge.top());
    
    if (n_elems == 0) return false;                // ③ 队列空
    
    t = _elems[oldAge.top()];                      // ④ 读取队头元素
    
    Age newAge(oldAge);
    newAge.increment();                            // ⑤ top++, 如果 top=0 则 tag++
    Age resAge = _age.cmpxchg(newAge, oldAge);     // ⑥ CAS 更新 Age
    
    return resAge == oldAge;                       // ⑦ CAS 成功才算偷到
}
```

```
图解 pop_global()（偷任务）：

之前状态：
  _elems: [A] [B] [C] [D]
           ↑           ↑
          top        bottom
          (被偷的一端)

pop_global() 后（偷走 A）：
  _elems: [A] [B] [C] [D]
               ↑       ↑
              top    bottom

特点：FIFO（先进先出），最早 push 的被偷走
```

---

## 5. 工作窃取策略

### 5.1 steal() - 从其他线程偷任务

```cpp
// taskqueue.inline.hpp:258-267
template<class T, MEMFLAGS F>
bool GenericTaskQueueSet<T, F>::steal(uint queue_num, int* seed, E& t) {
    // 尝试 2*N 次（N=线程数）
    for (uint i = 0; i < 2 * _n; i++) {
        if (steal_best_of_2(queue_num, seed, t)) {
            return true;
        }
    }
    return false;
}
```

### 5.2 steal_best_of_2() - "二选一"策略

```cpp
// taskqueue.inline.hpp:236-255
template<class T, MEMFLAGS F>
bool GenericTaskQueueSet<T, F>::steal_best_of_2(uint queue_num, int* seed, E& t) {
    if (_n > 2) {
        // ① 随机选两个不同的队列（不是自己）
        uint k1 = random() % _n;  // 排除自己
        uint k2 = random() % _n;  // 排除自己和 k1
        
        // ② 比较两个队列的大小，偷较大的
        uint sz1 = _queues[k1]->size();
        uint sz2 = _queues[k2]->size();
        
        if (sz2 > sz1)
            return _queues[k2]->pop_global(t);
        else
            return _queues[k1]->pop_global(t);
    } else if (_n == 2) {
        // 只有两个队列，直接偷另一个
        return _queues[(queue_num + 1) % 2]->pop_global(t);
    }
    return false;
}
```

```
为什么是"二选一"而不是"选最大的"？

方案 A：选最大的队列
  • 需要遍历所有 N 个队列
  • 开销：O(N)
  • 所有线程都去偷最大的 → 竞争激烈

方案 B：随机二选一
  • 只采样 2 个队列
  • 开销：O(1)
  • 概率上偏向较大的队列，但竞争分散
  • 这是工作窃取的经典优化！

数学直觉：
  假设有 100 个队列，最大的有 1000 个任务
  随机选两个，选中最大那个的概率 ≈ 2%
  但选中的那个大概率是较大的队列
  平衡了"找大队列"和"减少竞争"
```

### 5.3 G1 中的使用：steal_and_trim_queue()

```cpp
// g1ParScanThreadState.inline.hpp:141-152
void G1ParScanThreadState::steal_and_trim_queue(RefToScanQueueSet *task_queues) {
    StarTask stolen_task;
    
    // 循环偷任务，直到偷不到为止
    while (task_queues->steal(_worker_id, &_hash_seed, stolen_task)) {
        // 处理偷来的任务
        dispatch_reference(stolen_task);
        
        // 处理过程中可能产生新任务，先处理自己的队列
        trim_queue();
    }
}
```

---

## 6. 内存布局与缓存优化

### 6.1 缓存行填充

```cpp
// taskqueue.hpp:150-153
volatile uint _bottom;
// 填充，避免 _bottom 和 _age 在同一缓存行
DEFINE_PAD_MINUS_SIZE(0, DEFAULT_CACHE_LINE_SIZE, sizeof(uint));
volatile Age _age;
```

```
为什么需要填充？

问题：False Sharing（伪共享）

CPU 缓存以"缓存行"为单位（通常 64 字节）
如果 _bottom 和 _age 在同一缓存行：

  Thread A 修改 _bottom → 整个缓存行失效
  Thread B 的 _age 缓存也失效 → 需要重新加载
  
  即使 A 和 B 操作的是不同变量，也会互相干扰！

解决：在 _bottom 和 _age 之间插入填充字节
     让它们分布在不同的缓存行

内存布局：
  ┌──────────────────────────────────────────────────────────────┐
  │ Cache Line 0                                                  │
  │ [_bottom (4B)] [padding (60B)]                               │
  ├──────────────────────────────────────────────────────────────┤
  │ Cache Line 1                                                  │
  │ [_age (8B)] [...]                                            │
  └──────────────────────────────────────────────────────────────┘
```

### 6.2 溢出栈（Overflow Stack）

```cpp
// OverflowTaskQueue 在队列满时使用溢出栈
template<class E, MEMFLAGS F, unsigned int N>
class OverflowTaskQueue: public GenericTaskQueue<E, F, N> {
    overflow_t _overflow_stack;  // Stack<E>
    
    bool push(E t) {
        if (!taskqueue_t::push(t)) {      // 队列满了
            overflow_stack()->push(t);     // 放入溢出栈
        }
        return true;
    }
};
```

```
为什么需要溢出栈？

场景：处理一个大数组对象时，会产生大量引用
      可能超过队列容量（131070 个）

解决：超出部分放入溢出栈
      处理时先清空溢出栈（让其他线程能偷）
```

---

## 7. GDB 验证 ✅

### 7.1 GDB 验证结果

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
断点位置：g1CollectedHeap.cpp:1535（所有队列创建完成后）

========== RefToScanQueue 配置 ==========
ParallelGCThreads = 13
队列数量 n_queues = 13

========== TASKQUEUE_SIZE 常量 ==========
TASKQUEUE_SIZE (64位) = 131072 (2^17)
max_elems = TASKQUEUE_SIZE - 2 = 131070
每个队列可存储 13 万个对象引用

========== 队列集合 _task_queues ==========
_task_queues 地址 = 0x7ffff0042670
_n (队列数量) = 13
_queues 数组地址 = 0x7ffff00426d0
```

### 7.2 队列结构详情

```
========== 13 个队列地址分布 ==========
_queues[0]  = 0x7ffff00429b0
_queues[1]  = 0x7ffff0042b00  (间隔 336 bytes)
_queues[2]  = 0x7ffff0042c50
_queues[3]  = 0x7ffff0042da0
_queues[4]  = 0x7ffff0042ef0
_queues[5]  = 0x7ffff0043040
_queues[6]  = 0x7ffff0043190
_queues[7]  = 0x7ffff00432e0
_queues[8]  = 0x7ffff0043430
_queues[9]  = 0x7ffff0043580
_queues[10] = 0x7ffff00436d0
_queues[11] = 0x7ffff0043820
_queues[12] = 0x7ffff0043970

队列对象间隔: 336 bytes (包含所有字段 + 虚表指针)
```

### 7.3 队列[0] 完整结构

```
队列[0] 完整结构:
{
  <GenericTaskQueue<StarTask, (MemoryType)5, 131072>> = {
    <TaskQueueSuper<131072, (MemoryType)5>> = {
      _bottom = 0,                           ← 队尾索引（初始为 0）
      _pad_buf0 = '\000' × 123,              ← 缓存行填充！
      _age = {
        _data = 0,                           ← 64 位整体
        _fields = {
          _top = 0,                          ← 队头索引
          _tag = 0                           ← ABA 防护标签
        }
      },
      stats = { _stats = {0, 0, 0, 0, 0, 0, 0} }
    },
    _elems = 0x7ffff4ffd030                  ← 元素数组（1MB）
  },
  _overflow_stack = {
    _seg_size = 510,                         ← 溢出栈段大小
    _max_size = 18446744073709551360,        ← 几乎无限
    _max_cache_size = 4,
    _cur_seg = 0x0,                          ← 当前无溢出
    _cache = 0x0
  }
}
```

### 7.4 缓存行填充验证

```
========== 缓存行填充验证 ==========
_bottom 偏移量（从对象起始）: 8 bytes
_age 偏移量（从对象起始）: 136 bytes

差值: 136 - 8 = 128 bytes (2 个缓存行)

✅ _bottom 和 _age 在不同缓存行
   → 避免 false sharing
   → 本地线程操作 _bottom 不会影响其他线程读 _age
```

### 7.5 元素数组分布

```
========== _elems 数组地址 ==========
队列[0] _elems: 0x7ffff4ffd030
队列[1] _elems: 0x7ffff4efc030
队列[2] _elems: 0x7ffff4dfb030

数组间隔计算:
0x7ffff4ffd030 - 0x7ffff4efc030 = 0x101000 = 1,052,672 bytes
                                            ≈ 1MB (符合预期)

每个 _elems 数组 = 131072 × 8 = 1,048,576 bytes = 1MB
```

### 7.6 验证总结

```
┌─────────────────────────────────────────────────────────────────────┐
│                    GDB 验证结果汇总                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  配置验证                             实际值                         │
│  ──────────────────────────────────────────────────────────────────  │
│  ParallelGCThreads                    13 ✅                          │
│  队列数量                             13 ✅                          │
│  TASKQUEUE_SIZE                       131072 ✅                      │
│                                                                      │
│  内存布局验证                                                        │
│  ──────────────────────────────────────────────────────────────────  │
│  队列对象大小                         336 bytes ✅                   │
│  _elems 数组大小                      ~1MB ✅                        │
│  _bottom/_age 间隔                    128 bytes ✅ (避免 false sharing)│
│                                                                      │
│  初始状态验证                                                        │
│  ──────────────────────────────────────────────────────────────────  │
│  _bottom                              0 ✅ (队列空)                  │
│  _age._data                           0 ✅ (top=0, tag=0)            │
│  _overflow_stack._cur_seg             NULL ✅ (无溢出)               │
│                                                                      │
│  内存占用计算                                                        │
│  ──────────────────────────────────────────────────────────────────  │
│  每队列 _elems 数组                   1MB                            │
│  13 个队列元素数组                    13MB                           │
│  队列对象本身                         13 × 336B ≈ 4KB                │
│  总计                                 ~13MB                          │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 8. 13 个 GC 线程如何协作

### 8.1 完整工作流程

```
┌────────────────────────────────────────────────────────────────────────┐
│                        G1 Young GC 扫描阶段                             │
├────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  阶段 1：初始分发                                                       │
│  ─────────────────────────────────────────────────────────────────────  │
│  • 根引用（栈、静态变量等）均分给 13 个线程                             │
│  • 每个线程把自己负责的引用 push 到自己的队列                           │
│                                                                         │
│  Thread #0: [ref1, ref2, ref3, ...]                                    │
│  Thread #1: [ref4, ref5, ref6, ...]                                    │
│  ...                                                                    │
│                                                                         │
│  阶段 2：并行处理                                                       │
│  ─────────────────────────────────────────────────────────────────────  │
│  • 每个线程 pop_local() 处理自己的任务                                  │
│  • 处理过程中发现新引用 → push() 到自己的队列                           │
│                                                                         │
│     Thread #0                Thread #1              Thread #12          │
│     ┌─────────┐              ┌─────────┐            ┌─────────┐        │
│     │ pop     │              │ pop     │            │ pop     │        │
│     │ process │              │ process │            │ process │        │
│     │ push    │              │ push    │            │ push    │        │
│     │ pop     │              │ (empty) │←── steal ──│ pop     │        │
│     │ ...     │              │ ...     │            │ ...     │        │
│     └─────────┘              └─────────┘            └─────────┘        │
│                                                                         │
│  阶段 3：工作窃取                                                       │
│  ─────────────────────────────────────────────────────────────────────  │
│  • Thread #1 自己的队列空了                                             │
│  • 调用 steal_and_trim_queue() 从其他线程偷任务                         │
│  • 使用"二选一"策略：随机选两个队列，偷较大的                           │
│                                                                         │
│  阶段 4：终止检测                                                       │
│  ─────────────────────────────────────────────────────────────────────  │
│  • 所有队列都空了 → 扫描阶段结束                                        │
│  • ParallelTaskTerminator 协调终止                                      │
│                                                                         │
└────────────────────────────────────────────────────────────────────────┘
```

### 8.2 为什么这样设计高效？

```
┌────────────────────────────────────────────────────────────────────────┐
│ 设计特点                           优势                                 │
├────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│ 1. 每个线程有自己的队列             • 本地操作无锁（大部分情况）        │
│                                     • 减少线程间竞争                    │
│                                                                         │
│ 2. pop_local 是 LIFO               • 刚 push 的任务还在缓存里          │
│                                     • 缓存友好，减少 cache miss         │
│                                                                         │
│ 3. steal 是 FIFO                   • 偷最老的任务                       │
│                                     • 减少与 owner 的竞争               │
│                                     • 最老的任务往往关联更多引用        │
│                                                                         │
│ 4. 二选一偷窃策略                  • O(1) 复杂度                        │
│                                     • 概率上偏向大队列                  │
│                                     • 分散竞争                          │
│                                                                         │
│ 5. CAS 操作只在竞争时               • 快速路径无原子操作                │
│                                     • 只有 steal 和最后一个元素时用 CAS │
│                                                                         │
└────────────────────────────────────────────────────────────────────────┘
```

### 8.3 数据示例

```
假设：处理 100 万个对象引用，13 个 GC 线程

无工作窃取：
  最快线程耗时: 20ms
  最慢线程耗时: 100ms（负载不均）
  总耗时: 100ms

有工作窃取：
  平均每线程处理: 100万/13 ≈ 77000 个引用
  偷窃次数: 约 1000-2000 次
  总耗时: 约 30-40ms

提升：2-3 倍！
```

---

## 9. 总结

### 9.1 核心概念

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│   RefToScanQueue = OverflowTaskQueue<StarTask, mtGC, 131072>            │
│                                                                          │
│   • 每个 GC 线程一个队列（共 13 个）                                    │
│   • 容量：131070 个任务                                                  │
│   • 溢出保护：满了放入 overflow_stack                                    │
│                                                                          │
│   工作窃取算法（ABP）：                                                  │
│   • push() / pop_local()：本地线程，队尾操作，无锁                       │
│   • pop_global()：其他线程，队头操作，CAS                                │
│   • steal_best_of_2()：随机选两个队列，偷较大的                          │
│                                                                          │
│   优化：                                                                 │
│   • 缓存行填充：避免 false sharing                                       │
│   • LIFO 本地：缓存友好                                                  │
│   • FIFO 偷窃：减少竞争                                                  │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 9.2 关键数值（16 核机器）

| 配置项 | 值 |
|--------|-----|
| ParallelGCThreads | 13 |
| 队列数量 | 13 |
| TASKQUEUE_SIZE | 131072 (2^17) |
| 每队列最大元素 | 131070 |
| 每队列内存占用 | ~1MB |
| 总内存占用 | ~13MB |
| 偷窃尝试次数 | 2 × 13 = 26 次 |

### 9.3 类关系图

```
                    RefToScanQueueSet
                    (管理 13 个队列)
                           │
          ┌────────────────┼────────────────┐
          │                │                │
          ▼                ▼                ▼
    RefToScanQueue   RefToScanQueue   RefToScanQueue
     (Thread #0)      (Thread #1)      (Thread #12)
          │                │                │
          ▼                ▼                ▼
    ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
    │ _elems[]    │  │ _elems[]    │  │ _elems[]    │
    │ _bottom     │  │ _bottom     │  │ _bottom     │
    │ _age        │  │ _age        │  │ _age        │
    │ _overflow   │  │ _overflow   │  │ _overflow   │
    └─────────────┘  └─────────────┘  └─────────────┘
          │                │                │
          └────────────────┼────────────────┘
                           │
                     steal_best_of_2()
                    (工作窃取协调)
```

---

## 下一步

建议继续学习：
- **E.1** `WorkGang` - 了解 GC 线程池的实现
- **3.2** `G1CollectedHeap::initialize()` - 看看堆初始化时如何使用这些队列
- **D.4.1** `G1Policy` - 了解如何决定收集多少个 Region

或者告诉我你想深入哪个方向！
