# G1SATBMarkQueue 专家级源码分析

> **文档定位**：Mixed GC 学习 - 第二阶段第 2 篇  
> **分析模式**：Read-TopDown（自顶向下）  
> **创建时间**：2026-02-11  

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1SATBMarkQueue 的本质是**Pre 写屏障与并发标记之间的异步缓冲队列**：应用线程写引用字段前，Pre 写屏障将旧值（被覆盖的引用）放入线程本地 SATB 队列；队列满时 flush 到全局 `SATBMarkQueueSet`；Remark（STW）阶段处理所有 SATB 队列，确保旧引用不被漏标。

### 0.2 为什么需要？

并发标记期间，应用线程可能修改引用（将黑色对象的引用字段指向白色对象），导致漏标（黑色对象不会被重新扫描）。SATB（Snapshot-At-The-Beginning）语义：标记开始时存活的对象必须被标记；Pre 写屏障记录旧值（被删除的引用），确保旧值指向的对象不被漏标。

### 0.3 怎么解决？

**线程本地缓冲 + 全局队列集合**：每个 Java 线程有一个 `G1SATBMarkQueue`（线程本地缓冲）；Pre 写屏障：`if (_active) { queue.enqueue(old_value); }`；队列满时 flush 到全局 `SATBMarkQueueSet`；Remark 阶段 `G1CMTask::drain_satb_buffers()` 处理所有 SATB 队列，将旧引用加入标记队列。

### 0.4 为什么这样设计？

- **为什么 Pre 屏障检查 `_active` 标志？** 只有并发标记进行中时才需要 SATB；`_active` 为 false 时 Pre 屏障是空操作，避免非标记期间的额外开销；`_active` 在 Initial Mark 时设为 true，Remark 完成后设为 false
- **为什么记录旧值而不是新值？** SATB 语义：标记开始时存活的对象必须被标记；旧值是"被删除的引用"，如果不记录，旧值指向的对象可能被漏标；新值会在正常标记过程中被发现（通过扫描黑色对象的引用字段）

---

## 一、一句话总结

**G1SATBMarkQueue 是 G1 SATB（Snapshot-At-The-Beginning）算法的核心组件，它通过线程本地缓冲区收集并发标记期间被修改的引用（旧值），并在 Remark 阶段批量处理，确保标记的完整性和正确性。**

---

## 二、设计哲学：为什么需要 SATB 队列？

### 2.1 问题背景

**并发标记的挑战**：
```
场景：并发标记期间，应用线程修改对象引用

时间线：
  T1: 标记器扫描对象 A，标记为黑色
  T2: 应用线程执行 A.field = B（B 是白色对象）
  T3: 标记器不会重新扫描 A（已是黑色）
  
结果：B 对象丢失，被错误回收！
```

### 2.2 SATB 解决方案

**核心思想**：记录修改前的旧值
```
写屏障拦截引用修改：

应用代码：obj.field = new_value

写屏障执行：
  1. 记录 old_value（旧引用）到 SATB 队列
  2. 执行实际修改：obj.field = new_value
  
结果：
  - 如果 old_value 需要标记，会在 Remark 阶段处理
  - 即使对象关系变化，也能保证标记完整性
```

### 2.3 与 DirtyCardQueue 的对比

| 特性 | SATBMarkQueue | DirtyCardQueue |
|------|---------------|----------------|
| **用途** | 记录旧引用（SATB） | 记录脏卡（跨代引用） |
| **触发时机** | 引用修改时（写屏障） | 引用修改时（写屏障） |
| **存储内容** | 对象地址（oop） | 卡表地址（card_ptr） |
| **处理时机** | Remark 阶段 | 并发精炼/GC 阶段 |
| **设计目标** | 保证标记完整性 | 更新记忆集 |

---

## 三、整体架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      SATB 队列整体架构                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  应用线程执行引用修改                                                          │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────────┐                                                         │
│  │   SATB 写屏障   │                                                         │
│  │  (g1BarrierSet) │                                                         │
│  └────────┬────────┘                                                         │
│           │ 1. 记录旧值到本地队列                                               │
│           ▼                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                   SATBMarkQueueSet (全局管理)                         │  │
│  │                                                                      │  │
│  │  ┌────────────────────────────────────────────────────────────────┐  │  │
│  │  │                 已完成缓冲区链表                                 │  │  │
│  │  │  _completed_buffers_head ──► [Buffer] ──► [Buffer] ──► NULL   │  │  │
│  │  └────────────────────────────────────────────────────────────────┘  │  │
│  │                                                                      │  │
│  │  ┌────────────────────────────────────────────────────────────────┐  │  │
│  │  │                 空闲缓冲区链表                                   │  │  │
│  │  │  _buf_free_list ──► [Buffer] ──► [Buffer] ──► NULL             │  │  │
│  │  └────────────────────────────────────────────────────────────────┘  │  │
│  │                                                                      │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│           ▲                                                                  │
│           │ 每个线程一个                                                     │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                    SATBMarkQueue (线程本地)                           │  │
│  │                                                                      │  │
│  │  ┌──────────────────────────────────────────────────────────────┐   │  │
│  │  │  _buf ──► [entry1, entry2, ..., entryN]                       │   │  │
│  │  │  _index (下一个写入位置)                                       │   │  │
│  │  │  _capacity (缓冲区容量)                                        │   │  │
│  │  │  _active (是否激活)                                            │   │  │
│  │  └──────────────────────────────────────────────────────────────┘   │  │
│  │                                                                      │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  Remark 阶段处理：                                                            │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────────┐                                                         │
│  │ 处理 SATB 队列  │  1. 遍历所有线程的 SATB 队列                             │
│  │                 │  2. 过滤无效条目（已标记/不需要标记）                      │
│  │                 │  3. 标记剩余对象                                         │
│  └─────────────────┘                                                         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 四、核心数据结构

### 4.1 SATBMarkQueue（线程本地队列）

```cpp
class SATBMarkQueue : public PtrQueue {
private:
  void filter();  // 过滤无效条目

public:
  SATBMarkQueue(SATBMarkQueueSet* qset, bool permanent = false);

  void flush();  // 刷新队列到全局

  // 应用闭包并清空队列（必须在安全点调用）
  void apply_closure_and_empty(SATBBufferClosure* cl);

  // 判断是否应将缓冲区加入全局队列
  virtual bool should_enqueue_buffer();
};
```

**继承关系**：
```
PtrQueue (基类)
    │
    └── SATBMarkQueue
```

### 4.2 SATBMarkQueueSet（全局管理器）

```cpp
class SATBMarkQueueSet : public PtrQueueSet {
  SATBMarkQueue _shared_satb_queue;  // 共享队列（VM 线程等使用）

public:
  SATBMarkQueueSet();

  void initialize(Monitor* cbl_mon, Mutex* fl_lock,
                  int process_completed_threshold, Mutex* lock);

  // 设置所有线程的 SATB 队列激活状态
  void set_active_all_threads(bool active, bool expected_active);

  // 过滤所有线程的 SATB 缓冲区
  void filter_thread_buffers();

  // 应用闭包到已完成的缓冲区
  bool apply_closure_to_completed_buffer(SATBBufferClosure* cl);

  // 放弃部分标记（Full GC 时调用）
  void abandon_partial_marking();
};
```

### 4.3 关键字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `_buf` | void** | 缓冲区，存储对象指针 |
| `_index` | size_t | 下一个写入位置（倒序） |
| `_capacity` | size_t | 缓冲区容量 |
| `_active` | bool | 是否激活（只在并发标记期间激活） |

---

## 五、核心机制详解

### 5.1 写屏障实现

```cpp
// SATB 写屏障（简化版）
void satb_write_barrier(oop* field, oop new_value) {
  // 1. 获取旧值
  oop old_value = *field;

  // 2. 如果旧值非空且 SATB 队列已激活
  if (old_value != NULL && satb_queue.is_active()) {
    // 3. 将旧值存入 SATB 队列
    satb_queue.enqueue(old_value);
  }

  // 4. 执行实际修改
  *field = new_value;
}
```

### 5.2 过滤机制（Filter）

**为什么需要过滤？**
- SATB 队列中的条目可能已经失效
- 对象可能已经被标记
- 对象可能不需要标记（如在 nTAMS 之上）

**过滤条件**：
```cpp
inline bool retain_entry(const void* entry, G1CollectedHeap* heap) {
  // 1. 检查是否需要标记（在 nTAMS 之下）
  bool requires_marking = requires_marking(entry, heap);

  // 2. 检查是否已标记
  bool not_marked = !heap->is_marked_next((oop)entry);

  // 保留：需要标记且未标记
  return requires_marking && not_marked;
}

inline bool requires_marking(const void* entry, G1CollectedHeap* heap) {
  HeapRegion* region = heap->heap_region_containing(entry);

  // 如果 entry >= nTAMS，不需要标记
  // - 新分配的对象（隐式存活）
  // - 年轻代对象（单独处理）
  if (entry >= region->next_top_at_mark_start()) {
    return false;
  }

  return true;
}
```

**双指针压缩算法**：
```cpp
void SATBMarkQueue::filter() {
  G1CollectedHeap* g1h = G1CollectedHeap::heap();
  void** buf = _buf;

  if (buf == NULL) return;

  // 双指针压缩（向尾部压缩）
  void** src = &buf[index()];      // 从 index 开始（低地址）
  void** dst = &buf[capacity()];   // 从 capacity 开始（高地址）

  for (; src < dst; ++src) {
    void* entry = *src;

    // 查找需要保留的条目
    if (retain_entry(entry, g1h)) {
      // 从高地址查找可以丢弃的条目
      while (src < --dst) {
        if (!retain_entry(*dst, g1h)) {
          *dst = entry;  // 用保留条目替换丢弃条目
          break;
        }
      }
    }
  }

  // 更新 index（指向最低保留条目）
  set_index(dst - buf);
}
```

### 5.3 缓冲区处理决策

```cpp
bool SATBMarkQueue::should_enqueue_buffer() {
  // 1. 先过滤
  filter();

  // 2. 计算使用率
  size_t cap = capacity();
  size_t percent_used = ((cap - index()) * 100) / cap;

  // 3. 如果使用率超过阈值，加入全局队列
  // G1SATBBufferEnqueueingThresholdPercent 默认 60
  bool should_enqueue = percent_used > G1SATBBufferEnqueueingThresholdPercent;
  return should_enqueue;
}
```

**决策流程**：
```
缓冲区满了
    │
    ▼
调用 should_enqueue_buffer()
    │
    ├──► filter() 过滤无效条目
    │
    ├──► 计算使用率 = (已用空间 / 总容量) × 100%
    │
    └──► 使用率 > 60% ?
             │
            Yes ──► 加入全局已完成队列
             │
            No  ──► 复用缓冲区（不入队）
```

### 5.4 Remark 阶段处理

```cpp
void SATBMarkQueue::apply_closure_and_empty(SATBBufferClosure* cl) {
  assert(SafepointSynchronize::is_at_safepoint(),
         "SATB queues must only be processed at safepoints");

  if (_buf != NULL) {
    // 1. 应用闭包处理缓冲区
    cl->do_buffer(&_buf[index()], size());

    // 2. 清空缓冲区
    reset();
  }
}
```

**处理流程**：
```cpp
// Remark 阶段处理所有线程的 SATB 队列
void G1ConcurrentMark::remark() {
  // 1. 处理已完成的缓冲区
  SATBBufferClosure cl;
  while (satb_queue_set.apply_closure_to_completed_buffer(&cl)) {
    // 循环处理直到没有更多缓冲区
  }

  // 2. 处理所有线程的本地队列
  for (each JavaThread t) {
    SATBMarkQueue& queue = G1ThreadLocalData::satb_mark_queue(t);
    queue.apply_closure_and_empty(&cl);
  }
}
```

---

## 六、与 DirtyCardQueue 的详细对比

| 对比维度 | SATBMarkQueue | DirtyCardQueue |
|---------|---------------|----------------|
| **核心目的** | 保证 SATB 标记完整性 | 更新记忆集（RSet） |
| **触发条件** | 并发标记期间引用修改 | 任何跨 Region 引用修改 |
| **记录内容** | 旧引用地址（oop） | 卡表地址（card_ptr） |
| **激活时机** | 并发标记周期内 | 始终激活 |
| **处理时机** | Remark 阶段（STW） | 并发精炼/GC 阶段 |
| **过滤机制** | 复杂（检查 nTAMS、是否已标记） | 简单（去重） |
| **处理目标** | 标记存活对象 | 更新 RSet |

**流程对比**：
```
SATBMarkQueue 流程：
  写屏障 → 记录旧 oop → 本地队列 → 过滤 → Remark 处理 → 标记对象

DirtyCardQueue 流程：
  写屏障 → 记录 card_ptr → 本地队列 → 并发精炼 → 更新 RSet
```

---

## 七、激活与去激活

### 7.1 生命周期管理

```cpp
// 并发标记周期开始时激活
void G1ConcurrentMark::pre_initial_mark() {
  // 激活所有线程的 SATB 队列
  satb_queue_set.set_active_all_threads(true, false);
}

// 并发标记周期结束时去激活
void G1ConcurrentMark::concurrent_cycle_end() {
  // 去激活所有线程的 SATB 队列
  satb_queue_set.set_active_all_threads(false, true);
}
```

### 7.2 实现细节

```cpp
void SATBMarkQueueSet::set_active_all_threads(bool active, bool expected_active) {
  assert(SafepointSynchronize::is_at_safepoint(), "Must be at safepoint.");

  // 1. 设置全局状态
  set_active(active);

  // 2. 设置所有 Java 线程的队列
  for (JavaThreadIteratorWithHandle jtiwh; JavaThread *t = jtiwh.next(); ) {
    G1ThreadLocalData::satb_mark_queue(t).set_active(active);
  }

  // 3. 设置共享队列
  shared_satb_queue()->set_active(active);
}
```

---

## 八、GDB 验证

### 8.1 GDB 脚本

```gdb
# jvm-md/tmp-file/g1satbqueue/gdb_g1satb.txt

set pagination off
set print pretty on

break G1CollectedHeap::initialize

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -version

continue
continue

printf "\n========== SATBMarkQueue 验证 ==========\n"
set $g1h = G1CollectedHeap::heap()
set $cm = $g1h->_cm

printf "\n---------- SATB Queue Set ----------\n"
set $satb_set = $g1h->_satb_mark_queue_set
printf "_satb_mark_queue_set: %p\n", $satb_set
printf "is_active: %d\n", $satb_set->is_active()
printf "completed_buffers_num: %zu\n", $satb_set->completed_buffers_num()

printf "\n---------- 线程本地 SATB 队列 ----------\n"
set $thread = Threads::first()
set $satb_queue = $thread->_gc_state._satb_mark_queue
printf "Thread 0 SATB queue: %p\n", $satb_queue
printf "is_active: %d\n", $satb_queue->is_active()
printf "size: %zu\n", $satb_queue->size()

continue
quit
```

### 8.2 预期输出

```
========== SATBMarkQueue 验证 ==========

---------- SATB Queue Set ----------
_satb_mark_queue_set: 0x7ffff00XXXXX
is_active: 0
completed_buffers_num: 0

---------- 线程本地 SATB 队列 ----------
Thread 0 SATB queue: 0x7ffff00XXXXX
is_active: 0
size: 0
```

---

## 九、面试问答

### Q1: SATBMarkQueue 的作用是什么？

**答案要点**：
1. 实现 SATB（Snapshot-At-The-Beginning）算法
2. 记录并发标记期间被修改的引用（旧值）
3. 在 Remark 阶段处理，确保标记完整性
4. 防止"丢失"白色对象（被修改引用后无法到达）

### Q2: 为什么需要过滤机制？

**答案要点**：
1. 队列中的条目可能已经失效
2. 对象可能已经被标记
3. 对象可能在 nTAMS 之上（新分配的对象）
4. 过滤可以减少无效处理，提高效率

### Q3: SATB 与增量更新有什么区别？

**答案要点**：
1. SATB：记录旧引用，保守但简单
2. 增量更新：记录新引用，精确但复杂
3. SATB 的 Remark 停顿更可控
4. G1 选择 SATB 是因为实现简单、可靠性高

### Q4: 什么时候激活/去激活 SATB 队列？

**答案要点**：
1. 激活：Initial Mark 阶段开始时
2. 去激活：并发标记周期结束时
3. 只在并发标记期间激活，减少平时开销
4. 通过 set_active_all_threads() 统一控制

---

## 十、下一步学习

**本阶段关联**：
- 上一篇：`G1CMMarkStack-Expert-Analysis.md` - 标记栈实现

**下阶段预告**：
- **2.3 G1ConcurrentMarkBitMap** - 并发标记位图（双缓冲设计）

---

## 十一、总结

**G1SATBMarkQueue 是 SATB 算法的核心实现，通过线程本地缓冲区收集并发标记期间的引用修改，并在 Remark 阶段批量处理，确保标记的完整性和正确性。**

| 核心机制 | 说明 |
|---------|------|
| 写屏障拦截 | 记录修改前的旧引用 |
| 过滤机制 | 去除已标记/不需要标记的条目 |
| 双指针压缩 | 高效过滤算法 |
| 批量处理 | Remark 阶段统一处理 |

**一句话记忆**：G1SATBMarkQueue 就像是并发标记的"保险丝"，当应用修改对象引用时，它会悄悄记录下旧值，确保标记器不会"漏掉"任何存活对象。

---

*文档生成时间: 2026-02-11*  
*源码版本: OpenJDK 11*  
*分析文件: satbMarkQueue.hpp/cpp*
