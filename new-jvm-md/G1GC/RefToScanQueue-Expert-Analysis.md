# RefToScanQueue 与 TaskQueue 专家级源码分析

> **定位**：G1 Young GC 并行对象扫描的核心数据结构  
> **核心问题**：如何实现 GC 线程间的任务分发与 Work Stealing？  
> **源码路径**：`src/hotspot/share/gc/shared/taskqueue.hpp`

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

RefToScanQueue 的本质是**支持 Work Stealing 的双端队列（Deque）**：每个 GC Worker 有独立的 `RefToScanQueue`，从队列头部 push/pop（线程本地，无锁）；其他 Worker 从队列尾部 steal（Work Stealing，CAS）；实现了 GC Worker 间的动态负载均衡。

### 0.2 为什么需要？

Evacuation 阶段多个 GC Worker 并行复制对象，每个 Worker 发现的待扫描对象数量不同（取决于 Root 扫描的分配）。如果某个 Worker 队列空了而其他 Worker 队列还有大量任务，空闲 Worker 浪费 CPU。Work Stealing 让空闲 Worker 从忙碌 Worker 的队列"偷"任务，实现负载均衡。

### 0.3 怎么解决？

**双端队列 + CAS Steal**：队列内部是一个固定大小的环形数组；`push(obj)` 从头部入队（无锁，只有当前线程操作头部）；`pop(obj)` 从头部出队（无锁）；`steal(obj)` 从尾部出队（CAS，多个线程可能同时 steal）；`TaskQueueSet` 管理所有 Worker 的队列，提供 `steal()` 接口。

### 0.4 为什么这样设计？

- **为什么头部 push/pop 无锁而尾部 steal 需要 CAS？** 头部只有当前线程操作，不需要同步；尾部可能有多个线程同时 steal，需要 CAS 保证原子性
- **为什么用固定大小的环形数组而不是动态链表？** 固定大小避免动态内存分配（GC 热路径上不能分配内存）；环形数组的缓存局部性比链表好；队列满时 push 到全局 `G1CMMarkStack`（溢出处理）

---

## 1. 一句话总结

**RefToScanQueue 是一个基于 ABP (Aurora-Blumofe-Plaxton) 算法的无锁双端队列，支持线程本地操作（push/pop_local）和其他线程窃取（pop_global/steal），配合 Overflow 栈处理队列溢出的情况。**

---

## 2. 为什么需要 RefToScanQueue？

### 2.1 问题背景

在 G1 Young GC 的 Evacuation 阶段，GC 线程需要：
1. **复制存活对象**从 CSet Region 到 Survivor/Old Region
2. **扫描对象引用**找到引用指向 CSet 的对象
3. **处理引用关系**更新引用、记录 RSet 等

**核心挑战**：
- 对象图遍历是**动态生成任务**的（遇到引用就需要处理）
- 不同 Region 的对象引用数量差异巨大
- 某些线程可能很快处理完自己的任务，而其他线程还有大量任务

### 2.2 如果没有 RefToScanQueue？

```
❌ 方案1：每个线程只处理自己的 Region
   - 问题：对象引用可能指向其他 Region，导致重复扫描或遗漏
   
❌ 方案2：全局任务队列 + 互斥锁
   - 问题：高并发下锁竞争激烈，性能瓶颈
   
✅ 方案3：每个线程本地队列 + Work Stealing（实际采用）
   - 本地操作无锁（fast path）
   - 窃取操作使用 CAS（慢但并发安全）
   - 负载均衡通过 Stealing 实现
```

---

## 3. 整体架构与类继承关系

```
类继承层次
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CHeapObj<F> (内存分配基类)
    └── TaskQueueSuper<N, F>              # 核心状态管理
            └── GenericTaskQueue<E, F, N> # 通用队列实现
                    └── OverflowTaskQueue<E, F, N>  # 带溢出栈

CHeapObj<F>
    └── TaskQueueSetSuperImpl<F>
            └── GenericTaskQueueSet<T, F>  # 队列集合管理

G1 中的具体类型定义
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
typedef OverflowTaskQueue<StarTask, mtGC>         RefToScanQueue;
typedef GenericTaskQueueSet<RefToScanQueue, mtGC> RefToScanQueueSet;
```

---

## 4. 核心数据结构详解

### 4.1 TaskQueueSuper - 队列状态基类

```cpp
template <unsigned int N, MEMFLAGS F>
class TaskQueueSuper: public CHeapObj<F> {
protected:
    // 使用 uint16_t (32位) 或 uint32_t (64位) 作为索引
    typedef NOT_LP64(uint16_t) LP64_ONLY(uint32_t) idx_t;
    
    enum { MOD_N_MASK = N - 1 };  // 用于快速取模（N必须是2的幂）
    
    // Age 结构：封装 top + tag，用于 ABA 问题检测
    class Age {
        union {
            size_t _data;           // 原子操作的整体数据
            struct fields {
                idx_t _top;         // 队列顶部索引（pop_global 从这里取）
                idx_t _tag;         // 版本号，防止 ABA 问题
            } _fields;
        };
    };
    
    volatile uint _bottom;          // 队列底部（push/pop_local 操作）
    DEFINE_PAD_MINUS_SIZE(0, DEFAULT_CACHE_LINE_SIZE, sizeof(uint));
    volatile Age _age;              // 队列顶部 + 版本号
};
```

#### 关键字段解析

| 字段 | 类型 | 作用 | 访问模式 |
|------|------|------|----------|
| `_bottom` | volatile uint | 指向下一个空闲位置（push 写入这里） | 本地线程写，其他线程读 |
| `_age._top` | idx_t | 队列顶部，pop_global 从这里取 | CAS 操作更新 |
| `_age._tag` | idx_t | 版本号，解决 ABA 问题 | 队列空时递增 |

**为什么需要 `_tag`？**

```
场景：ABA 问题
─────────────────────────────────────────────────
T1: 读取 _age (top=0, tag=0)
T1: 队列被其他线程操作，变成空又变回非空
    (top=0→1→0, tag 从 0→1→2)
T1: CAS 操作如果只看 top，会误认为队列没变
    但加上 tag 就能检测到变化（期望 tag=0，实际 tag=2）
```

### 4.2 GenericTaskQueue - 通用队列实现

```cpp
template <class E, MEMFLAGS F, unsigned int N = TASKQUEUE_SIZE>
class GenericTaskQueue: public TaskQueueSuper<N, F> {
private:
    volatile E* _elems;  // 环形数组存储元素
    
public:
    bool push(E t);                           // 本地 push
    bool pop_local(volatile E& t, uint threshold = 0);  // 本地 pop
    bool pop_global(volatile E& t);           // 全局 steal
};
```

#### 环形数组布局

```
队列内存布局（N = 16 示例）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
索引:  0    1    2    3    4    5    6    7    8    9   ...
      ┌────┬────┬────┬────┬────┬────┬────┬────┬────┬────┐
      │E0  │E1  │E2  │E3  │E4  │    │    │    │    │    │
      └────┴────┴────┴────┴────┴────┴────┴────┴────┴────┘
            ↑                   ↑
          _age._top=1        _bottom=5
          
元素范围: [top, bottom) = [1, 5)，包含 E1, E2, E3, E4
```

### 4.3 OverflowTaskQueue - 带溢出栈的队列

```cpp
template<class E, MEMFLAGS F, unsigned int N = TASKQUEUE_SIZE>
class OverflowTaskQueue: public GenericTaskQueue<E, F, N> {
private:
    Stack<E, F> _overflow_stack;  // 溢出栈（无界）
    
public:
    bool push(E t);           // 优先队列，满时入栈
    bool pop_overflow(E& t);  // 从溢出栈弹出
};
```

**为什么需要溢出栈？**

```
场景：大对象数组扫描
─────────────────────────────────────────────────
对象数组: Object[10000]
处理方式: 分块扫描
  - 扫描前 50 个元素
  - 把剩余 9950 个元素打包成 PartialArrayScanTask
  - push 到队列

问题：如果队列已满（256个元素），PartialArrayScanTask 无处可放
解决：溢流到 _overflow_stack（无界栈）
```

### 4.4 GenericTaskQueueSet - 队列集合管理

```cpp
template<class T, MEMFLAGS F>
class GenericTaskQueueSet: public TaskQueueSetSuperImpl<F> {
private:
    uint _n;        // 队列数量（等于 GC 线程数）
    T** _queues;    // 队列指针数组
    
public:
    bool steal(uint queue_num, int* seed, E& t);           // 窃取任务
    bool steal_best_of_2(uint queue_num, int* seed, E& t); // best-of-2 策略
};
```

---

## 5. 核心算法详解

### 5.1 Push 操作（本地线程）

```cpp
template<class E, MEMFLAGS F, unsigned int N> inline bool
GenericTaskQueue<E, F, N>::push(E t) {
    uint localBot = _bottom;
    idx_t top = _age.top();
    uint dirty_n_elems = dirty_size(localBot, top);  // 计算当前元素数
    
    if (dirty_n_elems < max_elems()) {  // fast path：队列未满
        _elems[localBot] = t;           // 写入元素
        OrderAccess::release_store(&_bottom, increment_index(localBot));
        return true;
    } else {
        return push_slow(t, dirty_n_elems);  // slow path：处理边界情况
    }
}
```

**关键点**：
- **Fast Path 无锁**：只有一个线程会修改 `_bottom`（队列拥有者）
- **Release Store**：保证元素写入对窃取线程可见
- **max_elems() = N-2**：为什么留 2 个空位？为了区分满和空的状态

### 5.2 Pop Local 操作（本地线程 - LIFO）

```cpp
template<class E, MEMFLAGS F, unsigned int N> inline bool
GenericTaskQueue<E, F, N>::pop_local(volatile E& t, uint threshold) {
    uint localBot = _bottom;
    uint dirty_n_elems = dirty_size(localBot, _age.top());
    
    if (dirty_n_elems <= threshold) return false;  // 元素不足，不 pop
    
    localBot = decrement_index(localBot);  // bottom--
    _bottom = localBot;
    OrderAccess::fence();                  // 防止重排序
    
    t = _elems[localBot];                  // 读取元素
    
    if (size(localBot, _age.top()) > 0) {
        return true;                       // 还有元素，直接返回
    } else {
        return pop_local_slow(localBot, _age.get());  // 竞争处理
    }
}
```

**关键点**：
- **LIFO 顺序**：从 `_bottom-1` 处取（最近 push 的）
- **Fence 屏障**：保证 bottom 更新在元素读取之前完成
- **Slow Path**：当只剩一个元素时，需要和 steal 线程竞争

### 5.3 Pop Global 操作（窃取线程 - FIFO）

```cpp
template<class E, MEMFLAGS F, unsigned int N>
bool GenericTaskQueue<E, F, N>::pop_global(volatile E& t) {
    Age oldAge = _age.get();
    uint localBot = OrderAccess::load_acquire(&_bottom);
    uint n_elems = size(localBot, oldAge.top());
    
    if (n_elems == 0) return false;  // 队列为空
    
    t = _elems[oldAge.top()];        // 从顶部取（最老的元素）
    
    Age newAge(oldAge);
    newAge.increment();              // top++，可能 tag++
    Age resAge = _age.cmpxchg(newAge, oldAge);  // CAS 竞争
    
    return resAge == oldAge;         // CAS 成功才算窃取成功
}
```

**关键点**：
- **FIFO 顺序**：从 `_age._top` 处取（最早 push 的）
- **Acquire Load**：保证看到最新的 bottom
- **CAS 竞争**：多个窃取线程同时 CAS，只有一个成功

### 5.4 Steal 操作（Best-of-2 策略）

```cpp
template<class T, MEMFLAGS F> bool
GenericTaskQueueSet<T, F>::steal_best_of_2(uint queue_num, int* seed, E& t) {
    if (_n > 2) {
        // 随机选两个其他队列
        uint k1 = randomParkAndMiller(seed) % _n;
        while (k1 == queue_num) k1 = randomParkAndMiller(seed) % _n;
        
        uint k2 = randomParkAndMiller(seed) % _n;
        while (k2 == queue_num || k2 == k1) k2 = randomParkAndMiller(seed) % _n;
        
        // 比较两个队列的大小，偷更大的那个
        uint sz1 = _queues[k1]->size();
        uint sz2 = _queues[k2]->size();
        if (sz2 > sz1) return _queues[k2]->pop_global(t);
        else return _queues[k1]->pop_global(t);
    } else if (_n == 2) {
        uint k = (queue_num + 1) % 2;  // 只有一个选择
        return _queues[k]->pop_global(t);
    }
    return false;
}
```

**Best-of-2 策略优势**：
- **简单高效**：只比较两个队列，O(1) 复杂度
- **负载均衡**：优先偷任务多的队列
- **随机性**：避免总是偷同一个队列造成的冲突

---

## 6. 内存布局与 GDB 验证

### 6.1 结构体大小

```cpp
// 在 taskqueue.hpp 中
#define TASKQUEUE_SIZE 256  // 默认队列大小

// 类型定义
typedef OverflowTaskQueue<StarTask, mtGC> RefToScanQueue;
```

【GDB 验证脚本】
```bash
cd /data/workspace/openjdk-cut-new

cat > jvm-md/tmp-file/reftoscanqueue/gdb_verify.txt << 'EOF'
set pagination off
set print pretty on

# 在队列初始化后断点
b G1CollectedHeap::initialize
run -XX:+UseG1GC -Xms8g -Xmx8g -version

# 验证队列大小
printf "\n========== TaskQueue 结构验证 ==========\n"
printf "TASKQUEUE_SIZE = %d\n", 256

# 计算各结构大小
printf "\n结构体大小:\n"
printf "sizeof(StarTask)              = %lu\n", sizeof(StarTask)
printf "sizeof(GenericTaskQueue<StarTask, mtGC, 256>) = %lu\n", sizeof(GenericTaskQueue<StarTask, mtGC, 256>)
printf "sizeof(OverflowTaskQueue<StarTask, mtGC>) = %lu\n", sizeof(OverflowTaskQueue<StarTask, mtGC>)
printf "sizeof(RefToScanQueue)        = %lu\n", sizeof(RefToScanQueue)

# 验证队列数量
printf "\n队列数量（等于 GC 线程数）:\n"
printf "ParallelGCThreads = %d\n", ParallelGCThreads

quit
EOF

gdb -batch -x jvm-md/tmp-file/reftoscanqueue/gdb_verify.txt \
    --args ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
    -XX:+UseG1GC -Xms8g -Xmx8g -version 2>/dev/null
```

【预期输出】
```
========== TaskQueue 结构验证 ==========
TASKQUEUE_SIZE = 256

结构体大小:
sizeof(StarTask)              = 8
sizeof(GenericTaskQueue<StarTask, mtGC, 256>) = ~2064
sizeof(OverflowTaskQueue<StarTask, mtGC>) = ~2080
sizeof(RefToScanQueue)        = ~2080

队列数量（等于 GC 线程数）:
ParallelGCThreads = 8  (根据 CPU 核数)
```

### 6.2 StarTask 详解

```cpp
// 包装类：支持常规 oop* 和压缩指针 narrowOop*
class StarTask {
    void* _holder;  // 实际存储的指针
    enum { COMPRESSED_OOP_MASK = 1 };  // 最低位标记是否为压缩指针
    
public:
    StarTask(narrowOop* p) {  // 压缩指针构造
        _holder = (void *)((uintptr_t)p | COMPRESSED_OOP_MASK);
    }
    StarTask(oop* p) {        // 常规指针构造
        _holder = (void*)p;
    }
    
    bool is_narrow() const {  // 判断是否为压缩指针
        return (((uintptr_t)_holder & COMPRESSED_OOP_MASK) != 0);
    }
};
```

**设计目的**：
- 统一处理常规指针和压缩指针
- 用最低位作为标记，无需额外字段
- 保证 2 字节对齐的指针才能使用（JVM 保证）

---

## 7. 在 G1 中的使用场景

### 7.1 队列初始化

```cpp
// G1CollectedHeap::initialize()
void G1CollectedHeap::initialize() {
    // ...
    
    // 1. 创建队列集合
    uint n_queues = ParallelGCThreads;
    _task_queues = new RefToScanQueueSet(n_queues);
    
    // 2. 为每个 GC 线程创建队列
    for (uint i = 0; i < n_queues; i++) {
        RefToScanQueue* q = new RefToScanQueue();
        q->initialize();  // 分配 _elems 数组
        _task_queues->register_queue(i, q);
    }
}
```

### 7.2 Evacuation 阶段使用流程

```
G1ParScanThreadState 使用队列的流程
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. 根扫描阶段
   ┌─────────────────────────────────────────────────────┐
   │ G1RootProcessor::process_roots()                     │
   │   └── 对每个 GC Root 调用 oop_closure               │
   │       └── push_on_queue(ref)  # 将引用压入队列      │
   └─────────────────────────────────────────────────────┘
                           ↓
2. 本地处理阶段
   ┌─────────────────────────────────────────────────────┐
   │ trim_queue()                                        │
   │   └── while (pop_local(task))                       │
   │       └── process_task(task)  # 处理对象引用        │
   │           └── 可能 push 新任务到队列               │
   └─────────────────────────────────────────────────────┘
                           ↓
3. Work Stealing 阶段（本地队列为空）
   ┌─────────────────────────────────────────────────────┐
   │ steal_and_trim_queue(task_queues)                   │
   │   └── while (task_queues->steal(worker_id, seed, task))
   │       └── process_task(task)                        │
   └─────────────────────────────────────────────────────┘
                           ↓
4. 终止阶段（所有队列为空）
   ┌─────────────────────────────────────────────────────┐
   │ ParallelTaskTerminator::offer_termination()         │
   │   └── 所有线程都完成，GC 结束                       │
   └─────────────────────────────────────────────────────┘
```

### 7.3 Push 和 Pop 的具体代码

```cpp
// g1ParScanThreadState.inline.hpp
template <class T> 
inline void G1ParScanThreadState::push_on_queue(T* ref) {
    StarTask t(ref);  // 包装成 StarTask
    
    // 优先 push 到本地队列
    if (!_refs->try_push_to_taskqueue(t)) {
        // 队列满，使用溢出栈
        _refs->push(t);
    }
}

// 队列处理
void G1ParScanThreadState::trim_queue() {
    StarTask ref;
    
    // 1. 先处理本地队列（LIFO，无锁）
    while (_refs->pop_local(ref)) {
        dispatch_reference(ref);
    }
    
    // 2. 处理溢出栈（如果有）
    while (_refs->pop_overflow(ref)) {
        dispatch_reference(ref);
    }
}

// Work Stealing
void G1ParScanThreadState::steal_and_trim_queue(RefToScanQueueSet *task_queues) {
    StarTask stolen_task;
    
    // 不断尝试窃取，直到成功或所有队列为空
    while (task_queues->steal(_worker_id, &_hash_seed, stolen_task)) {
        // 处理窃取到的任务
        dispatch_reference(stolen_task);
        
        // 处理过程中可能产生新任务，先处理本地队列
        trim_queue();
    }
}
```

---

## 8. 并发安全性分析

### 8.1 操作分类

| 操作 | 执行线程 | 是否需要同步 | 实现机制 |
|------|----------|--------------|----------|
| `push` | 队列拥有者 | 否（fast path） | 仅修改 `_bottom` |
| `pop_local` | 队列拥有者 | 否（fast path） | 仅修改 `_bottom` |
| `pop_global` | 其他线程 | 是 | CAS 修改 `_age` |
| `size/empty` | 任意 | 最终一致 | 读取 `_bottom` 和 `_age` |

### 8.2 ABA 问题解决

```
ABA 问题场景
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

初始状态: _age = (top=5, tag=0), _bottom = 10

T1 (窃取线程)                      T2 (拥有者线程)
─────────────                     ────────────────
读取 _age = (5, 0)
                                  pop_local() 取走最后一个元素
                                  _age = (6, 1)  [top++, tag++]
                                  
                                  push() 新元素
                                  _age = (5, 2)  [top--, tag++]
                                  
尝试 CAS: 期望 (5, 0) → (6, 0)
实际发现 (5, 2) ≠ (5, 0)
CAS 失败！

结论：tag 检测到状态变化，避免 ABA 问题
```

### 8.3 内存序保证

```cpp
// Push 中的 release store
OrderAccess::release_store(&_bottom, new_bottom);
// 保证：_elems[old_bottom] = task 写入先完成，然后才更新 _bottom

// Pop global 中的 acquire load
uint localBot = OrderAccess::load_acquire(&_bottom);
// 保证：读取 _bottom 后，才能读取 _elems
```

---

## 9. 性能优化技巧

### 9.1 批量处理（Trim Threshold）

```cpp
// G1ParScanThreadState 配置
uint const _stack_trim_upper_threshold = 100;  // 开始处理的上限
uint const _stack_trim_lower_threshold = 10;   // 停止处理的下限

void G1ParScanThreadState::trim_queue_partially() {
    // 只在队列长度超过上限时才处理，避免频繁处理小批量
    if (_refs->size() > _stack_trim_upper_threshold) {
        trim_queue_to_threshold(_stack_trim_lower_threshold);
    }
}
```

**优化原理**：
- 减少函数调用开销
- 提高缓存局部性
- 避免过早处理导致频繁的 push/pop

### 9.2 缓存行对齐

```cpp
class TaskQueueSuper {
    volatile uint _bottom;
    DEFINE_PAD_MINUS_SIZE(0, DEFAULT_CACHE_LINE_SIZE, sizeof(uint));
    volatile Age _age;
};
```

**为什么需要 Padding？**
- `_bottom` 和 `_age` 被不同线程频繁访问
- 如果它们在同一个缓存行，会造成**伪共享（False Sharing）**
- Padding 确保它们在不同缓存行，避免无效缓存同步

---

## 10. 统计与监控

### 10.1 TaskQueueStats

```cpp
class TaskQueueStats {
public:
    enum StatId {
        push,             // push 次数
        pop,              // pop 次数
        pop_slow,         // slow path pop 次数
        steal_attempt,    // steal 尝试次数
        steal,            // steal 成功次数
        overflow,         // 溢出次数
        overflow_max_len, // 溢出栈最大长度
    };
    size_t _stats[last_stat_id];
};
```

### 10.2 启用统计

```bash
# 需要 debug 构建或定义 TASKQUEUE_STATS
java -XX:+UseG1GC -Xms8g -Xmx8g -XX:+PrintGCDetails \
     -XX:+UnlockDiagnosticVMOptions \
     -XX:+PrintTaskQueueStatistics \
     MyApp
```

---

## 11. 常见问题与面试题

### Q1: RefToScanQueue 为什么用 LIFO 处理本地任务，FIFO 处理窃取任务？

**答案**：
- **本地 LIFO**：最近 push 的任务最有可能还在 CPU 缓存中（局部性原理）
- **窃取 FIFO**：最老的任务通常处理时间更长，有助于负载均衡

### Q2: 如果队列满了怎么办？

**答案**：
- 主队列满（256 个元素）后，新任务进入溢出栈（无界）
- pop 时优先处理主队列，主队列空后才处理溢出栈
- 溢出栈使用传统 Stack 实现，push/pop 需要加锁

### Q3: Work Stealing 中的 Best-of-2 策略是什么？为什么有效？

**答案**：
- 每次窃取时随机选两个队列，比较它们的大小
- 从任务更多的队列窃取
- 优点：简单（O(1)）、有效（接近全局最优）、避免热点

### Q4: TaskQueue 如何保证线程安全？

**答案**：
- **本地操作**：单线程访问，无需同步
- **窃取操作**：使用 CAS 竞争，保证原子性
- **ABA 防护**：Age 结构包含版本号 tag
- **内存序**：使用 acquire/release 保证可见性

---

## 12. 总结

### 12.1 核心设计要点

```
RefToScanQueue 设计精髓
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. 双端队列设计
   ├── 本地线程：push/pop_local (LIFO, 无锁)
   └── 窃取线程：pop_global (FIFO, CAS)

2. ABP 算法保证
   ├── Age 结构：top + tag 解决 ABA
   ├── 内存屏障：acquire/release 保证可见性
   └── 环形数组：O(1) 索引计算

3. 溢出处理
   ├── 主队列：固定大小（256），无锁操作
   └── 溢出栈：动态扩容，有锁保护

4. 负载均衡
   └── Best-of-2：随机采样 + 贪心选择
```

### 12.2 与其他 GC 的对比

| 特性 | G1 RefToScanQueue | ZGC WorkQueue | ParallelGC TaskQueue |
|------|-------------------|---------------|---------------------|
| 算法 | ABP Work Stealing | 无锁 MPMC | ABP Work Stealing |
| 队列大小 | 256 + 溢出栈 | 动态扩展 | 256 |
| Steal 策略 | Best-of-2 | 轮询 | 随机 |
| 内存分配 | CHeap | CHeap | CHeap |

---

## 参考文档

1. [Arora et al., 2001] Thread scheduling for multiprogrammed multiprocessors
2. [Chase & Lev, 2005] Dynamic circular work-stealing deque
3. [Le et al., 2013] Correct and efficient work-stealing for weak memory models
4. OpenJDK 11: `src/hotspot/share/gc/shared/taskqueue.hpp`
5. OpenJDK 11: `src/hotspot/share/gc/g1/g1ParScanThreadState.hpp`

---

**文档信息**
- 创建时间: 2026-02-10
- 源码版本: OpenJDK 11
- 分析类型: 专家级源码分析
- 配套技能: Read-BottomUp, JVM-Concurrency-Design
