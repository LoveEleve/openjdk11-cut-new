# G1ParEvacuateFollowersClosure 专家级源码分析

> **定位**：G1 Young GC Evacuation 阶段的核心闭包，驱动对象复制和引用更新  
> **核心问题**：如何完成从根对象出发的完整对象图遍历和复制？  
> **源码路径**：`src/hotspot/share/gc/g1/g1CollectedHeap.hpp/cpp`

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1ParEvacuateFollowersClosure 的本质是**Evacuation 阶段的 BFS 驱动器**：从 GC Roots 出发，广度优先遍历对象图；每个 GC Worker 有一个实例，循环从 `RefToScanQueue` 取对象，调用 `G1ParScanThreadState::trim_queue()` 处理队列中的所有对象（复制 + 扫描引用字段）；队列空时尝试 Work Stealing。

### 0.2 为什么需要？

Root 扫描（`G1RootProcessor::evacuate_roots()`）只处理直接从 GC Roots 可达的对象，但这些对象的引用字段指向的对象也需要复制（传递闭包）。G1ParEvacuateFollowersClosure 驱动这个传递闭包：不断从队列取对象、复制、扫描引用字段、将新发现的对象加入队列，直到队列为空。

### 0.3 怎么解决？

**工作队列 + Work Stealing**：每个 GC Worker 有独立的 `RefToScanQueue`；`trim_queue()` 处理队列中的所有对象；队列空时 `steal_task()` 从其他 Worker 的队列偷任务；所有队列都空时 Evacuation 完成。

### 0.4 为什么这样设计？

- **为什么用 BFS（队列）而不是 DFS（栈）？** BFS 的内存局部性更好（相邻层的对象通常在相邻内存位置）；DFS 可能深入一条引用链，导致复制的对象分散在不同 Region
- **为什么需要 Work Stealing？** 不同 GC Worker 处理的对象数量不同（取决于 Root 扫描的分配），Work Stealing 让忙的 Worker 少做，闲的 Worker 多做，提高并行效率

---

## 1. 一句话总结

**G1ParEvacuateFollowersClosure 是 Evacuation 阶段的任务调度器，通过"处理本地队列 → Work Stealing → 终止协议"的三段式循环，驱动 GC 线程完成对象图的并行遍历和复制。**

---

## 2. 为什么需要 G1ParEvacuateFollowersClosure？

### 2.1 问题背景

在 G1 Young GC 的根扫描阶段结束后，RefToScanQueue 中已经有一批"灰色对象"（已标记但未处理其引用）。Evacuation 阶段需要：

1. **复制这些灰色对象**到 Survivor/Old Region
2. **更新对象引用**指向新的位置
3. **递归处理新发现的引用**直到队列为空

**核心挑战**：
- 对象图遍历是**动态生成任务**的（处理一个对象可能发现多个新引用）
- 线程间任务不均衡（某些区域对象引用多，某些区域少）
- 需要优雅地终止所有线程（不能简单等待，可能有窃取任务）

### 2.2 G1ParEvacuateFollowersClosure 的解决方案

```
三段式处理循环
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

第一阶段：处理本地队列 (trim_queue)
   └── 每个线程先处理自己的任务队列
   └── LIFO 顺序处理，利用缓存局部性
   
第二阶段：Work Stealing (steal_and_trim_queue)
   └── 本地队列为空后，从其他线程窃取任务
   └── Best-of-2 策略选择窃取目标
   
第三阶段：终止协议 (offer_termination)
   └── 所有队列为空后，进入终止协商
   └── 确保没有线程还在处理或生成新任务
```

---

## 3. 核心数据结构

### 3.1 G1ParEvacuateFollowersClosure 定义

```cpp
class G1ParEvacuateFollowersClosure : public VoidClosure {
private:
    double _start_term;       // 终止开始时间
    double _term_time;        // 终止阶段耗时
    size_t _term_attempts;    // 终止尝试次数
    
protected:
    G1CollectedHeap*              _g1h;           // G1 堆
    G1ParScanThreadState*         _par_scan_state; // 线程本地状态
    RefToScanQueueSet*            _queues;         // 任务队列集合
    ParallelTaskTerminator*       _terminator;     // 终止协调器
    
public:
    void do_void();  // 核心入口
    bool offer_termination();  // 终止协议
    
    double term_time() const { return _term_time; }
    size_t term_attempts() const { return _term_attempts; }
};
```

#### 字段解析

| 字段 | 类型 | 作用 | 为什么重要 |
|------|------|------|-----------|
| `_par_scan_state` | G1ParScanThreadState* | 线程本地扫描状态 | 包含队列、分配器、统计信息 |
| `_queues` | RefToScanQueueSet* | 所有线程的任务队列 | Work Stealing 的目标 |
| `_terminator` | ParallelTaskTerminator* | 终止协调器 | 确保所有线程安全终止 |
| `_term_time` | double | 终止阶段耗时 | GC 日志和性能分析 |
| `_term_attempts` | size_t | 终止尝试次数 | 反映任务不均衡程度 |

### 3.2 在 G1ParTask 中的使用

```cpp
class G1ParTask : public AbstractGangTask {
    void work(uint worker_id) {
        // 1. 获取线程本地状态
        G1ParScanThreadState* pss = _pss->state_for_worker(worker_id);
        
        // 2. 处理 RSet（跨 Region 引用）
        _g1h->g1_rem_set()->oops_into_collection_set_do(pss, worker_id);
        
        // 3. 创建 EvacuateFollowers 闭包
        G1ParEvacuateFollowersClosure evac(_g1h, pss, _queues, &_terminator);
        
        // 4. 执行 Evacuation
        evac.do_void();
        
        // 5. 记录统计信息
        p->record_time_secs(G1GCPhaseTimes::Termination, worker_id, evac.term_time());
    }
};
```

---

## 4. 核心算法详解

### 4.1 do_void() - 三段式处理入口

```cpp
void G1ParEvacuateFollowersClosure::do_void() {
    G1ParScanThreadState *const pss = par_scan_state();
    
    // 阶段 1：处理本地队列
    pss->trim_queue();
    
    // 阶段 2 & 3：窃取任务直到终止
    do {
        pss->steal_and_trim_queue(queues());
    } while (!offer_termination());
}
```

**为什么是这个顺序？**

```
执行顺序优化
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

优化 1：先处理本地队列
   ├── 原因：本地队列访问最快（L1/L2 缓存）
   ├── LIFO 顺序提高缓存命中率
   └── 减少与其他线程的竞争

优化 2：本地空后才 Stealing
   ├── 原因：Stealing 需要 CAS，有开销
   ├── 避免不必要的竞争
   └── Best-of-2 策略减少冲突

优化 3：终止协议最后
   ├── 原因：确保真的没任务了
   ├── 防止过早终止导致任务丢失
   └── 可重入（窃取后重新进入循环）
```

### 4.2 trim_queue() - 处理本地队列

```cpp
void G1ParScanThreadState::trim_queue() {
    StarTask ref;
    do {
        // 完全清空队列
        trim_queue_to_threshold(0);
    } while (!_refs->is_empty());
}

inline void G1ParScanThreadState::trim_queue_to_threshold(uint threshold) {
    StarTask ref;
    
    // 1. 先处理溢出栈（可能来自大对象数组）
    while (_refs->pop_overflow(ref)) {
        if (!_refs->try_push_to_taskqueue(ref)) {
            dispatch_reference(ref);
        }
    }
    
    // 2. 处理本地队列
    while (_refs->pop_local(ref, threshold)) {
        dispatch_reference(ref);
    }
}
```

**关键点**：
- **阈值控制**：`threshold=0` 表示完全清空
- **溢出栈优先**：溢出栈元素通常是大对象数组，处理时间较长
- **dispatch_reference**：实际处理引用（复制对象、更新引用）

### 4.3 steal_and_trim_queue() - Work Stealing

```cpp
void G1ParScanThreadState::steal_and_trim_queue(RefToScanQueueSet *task_queues) {
    StarTask stolen_task;
    
    // 不断尝试窃取，直到失败
    while (task_queues->steal(_worker_id, &_hash_seed, stolen_task)) {
        dispatch_reference(stolen_task);
        
        // 处理过程中可能生成新任务，优先处理本地队列
        trim_queue();
    }
}
```

**为什么是 `while` 而不是 `if`？**

```
Stealing 循环优化
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

单次窃取 (if):
  窃取一个任务 → 处理 → 返回
  问题：如果其他线程有很多任务，频繁进出函数开销大

循环窃取 (while):
  窃取一个任务 → 处理 → trim_queue → 再窃取
  优势：
    1. 批量处理窃取任务，减少函数调用
    2. 处理新任务后立即 trim，平衡本地队列
    3. 提高整体吞吐量
```

### 4.4 offer_termination() - 终止协议

```cpp
bool G1ParEvacuateFollowersClosure::offer_termination() {
    G1ParScanThreadState *const pss = par_scan_state();
    
    start_term_time();
    
    // 调用 ParallelTaskTerminator 的终止协议
    // 1. 尝试增加 _offered_termination 计数
    // 2. 如果所有线程都进入终止，返回 true
    // 3. 否则阻塞等待，直到有新任务或全部终止
    const bool res = terminator()->offer_termination();
    
    end_term_time();
    return res;
}
```

**终止协议的复杂性**：

```
为什么不能直接退出？
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

场景：线程 A 和 B 同时完成任务

T1: A 完成，检查队列为空
T2: B 完成，检查队列为空
T3: A 决定退出
T4: B 窃取到一个任务，处理时 push 新任务到队列
T5: B 完成，队列为空，决定退出
T6: A 的队列实际上有新任务（B push 的），但 A 已退出

解决方案：
  1. 使用原子计数器 _offered_termination
  2. 线程进入终止前递增计数器
  3. 只有当计数器 == 总线程数时，才真正终止
  4. 有新任务时唤醒等待线程
```

---

## 5. 对象复制核心流程

### 5.1 dispatch_reference() - 引用分发

```cpp
inline void G1ParScanThreadState::dispatch_reference(StarTask ref) {
    if (ref.is_narrow()) {
        deal_with_reference((narrowOop*)ref);
    } else {
        deal_with_reference((oop*)ref);
    }
}

inline void G1ParScanThreadState::deal_with_reference(oop* ref_to_scan) {
    // 检查是否是部分数组（大对象数组分块处理）
    if (!has_partial_array_mask(ref_to_scan)) {
        do_oop_evac(ref_to_scan);  // 普通对象处理
    } else {
        do_oop_partial_array(ref_to_scan);  // 大数组分块处理
    }
}
```

### 5.2 do_oop_evac() - 对象疏散核心

```cpp
template <class T> void G1ParScanThreadState::do_oop_evac(T* p) {
    // 1. 读取引用
    oop obj = RawAccess<IS_NOT_NULL>::oop_load(p);
    
    // 2. 检查对象是否在 CSet 中
    const InCSetState in_cset_state = _g1h->in_cset_state(obj);
    
    if (in_cset_state.is_in_cset()) {
        markOop m = obj->mark_raw();
        
        if (m->is_marked()) {
            // 2a. 已被其他线程复制，获取转发地址
            obj = (oop) m->decode_pointer();
        } else {
            // 2b. 未复制，执行复制
            obj = copy_to_survivor_space(in_cset_state, obj, m);
        }
        
        // 3. 更新引用指向新位置
        RawAccess<IS_NOT_NULL>::oop_store(p, obj);
    }
    
    // 4. 更新 RSet（跨 Region 引用）
    if (!HeapRegion::is_in_same_region(p, obj)) {
        update_rs(from, p, obj);
    }
}
```

### 5.3 copy_to_survivor_space() - 复制实现

```cpp
oop G1ParScanThreadState::copy_to_survivor_space(InCSetState const state,
                                                 oop const old,
                                                 markOop const old_mark) {
    const size_t word_sz = old->size();
    
    // 1. 确定目标 Region 类型（Survivor 或 Old）
    uint age = 0;
    InCSetState dest_state = next_state(state, old_mark, age);
    
    // 2. 尝试 PLAB 分配
    HeapWord* obj_ptr = _plab_allocator->plab_allocate(dest_state, word_sz);
    
    if (obj_ptr == NULL) {
        // 3. PLAB 满，尝试获取新 PLAB 或直接分配
        obj_ptr = _plab_allocator->allocate_direct_or_new_plab(dest_state, word_sz, ...);
        
        if (obj_ptr == NULL) {
            // 4. 分配失败，处理 Evacuation Failure
            return handle_evacuation_failure_par(old, old_mark);
        }
    }
    
    // 5. 尝试安装转发指针（CAS 竞争）
    const oop obj = oop(obj_ptr);
    const oop forward_ptr = old->forward_to_atomic(obj, memory_order_relaxed);
    
    if (forward_ptr == NULL) {
        // 6. CAS 成功，执行复制
        Copy::aligned_disjoint_words((HeapWord*) old, obj_ptr, word_sz);
        
        // 7. 更新年龄
        if (dest_state.is_young()) {
            age++;
            obj->set_mark_raw(old_mark->set_age(age));
        }
        
        // 8. 处理字符串去重
        if (G1StringDedup::is_enabled()) {
            G1StringDedup::enqueue_from_evacuation(...);
        }
        
        // 9. 处理对象引用（递归处理）
        if (obj->is_objArray() && arrayOop(obj)->length() >= ParGCArrayScanChunk) {
            // 大数组分块处理
            do_oop_partial_array(...);
        } else {
            // 普通对象，扫描其引用
            obj->oop_iterate_backwards(&_scanner);
        }
        
        return obj;
    } else {
        // 10. CAS 失败，其他线程已复制，释放分配的空间
        _plab_allocator->undo_allocation(dest_state, obj_ptr, word_sz);
        return forward_ptr;
    }
}
```

**关键设计**：

```
转发指针（Forwarding Pointer）机制
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

目的：处理多线程复制竞争

实现：
  1. 复制前 CAS 设置 Mark Word 为转发地址
  2. CAS 成功的线程执行复制
  3. CAS 失败的线程释放分配空间，返回转发地址

Mark Word 布局（复制期间）：
  ┌─────────────────────────────────────────────────────────┐
  │ 001（已标记）│ 转发地址（压缩后）                  │
  └─────────────────────────────────────────────────────────┘

优势：
  - 无锁：使用 CAS 而非互斥锁
  - 原子：其他线程看到已标记就使用转发地址
  - 安全：失败线程回滚分配，无内存泄漏
```

---

## 6. 大对象数组的特殊处理

### 6.1 为什么需要分块处理？

```
问题场景
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

对象数组：Object[100000]

如果一次性扫描：
  - 处理时间过长（可能几百微秒）
  - 其他线程空闲等待
  - 队列被长时间占用

分块处理方案：
  - 每块 50 个元素（ParGCArrayScanChunk）
  - 处理完一块后，将剩余部分 push 回队列
  - 其他线程可以窃取剩余块并行处理
```

### 6.2 do_oop_partial_array() 实现

```cpp
inline void G1ParScanThreadState::do_oop_partial_array(oop* p) {
    // 1. 解码原始数组对象
    oop from_obj = clear_partial_array_mask(p);
    objArrayOop from_obj_array = objArrayOop(from_obj);
    int length = from_obj_array->length();  // 原始长度
    
    // 2. 获取已复制的目标对象
    assert(from_obj->is_forwarded(), "must be forwarded");
    oop to_obj = from_obj->forwardee();
    objArrayOop to_obj_array = objArrayOop(to_obj);
    
    // 3. 获取上次处理到的索引（保存在目标对象的 length 字段）
    int next_index = to_obj_array->length();
    int start = next_index;
    int end = length;
    int remainder = end - start;
    
    // 4. 如果剩余部分还很大，分块处理
    if (remainder > 2 * ParGCArrayScanChunk) {
        end = start + ParGCArrayScanChunk;
        to_obj_array->set_length(end);  // 更新进度
        
        // 5. 将剩余部分 push 回队列（带 PartialArrayMask 标记）
        oop* from_obj_p = set_partial_array_mask(from_obj);
        push_on_queue(from_obj_p);
    } else {
        // 6. 最后一块，恢复原始长度
        to_obj_array->set_length(length);
    }
    
    // 7. 处理当前块 [start, end)
    to_obj_array->oop_iterate_range(&_scanner, start, end);
}
```

**PartialArrayMask 的作用**：

```cpp
// 标记指针，表示这是部分数组任务
#define G1_PARTIAL_ARRAY_MASK 0x2

inline oop* set_partial_array_mask(oop obj) {
    return (oop*) ((uintptr_t)(void *)obj | G1_PARTIAL_ARRAY_MASK);
}

inline bool has_partial_array_mask(oop* ref) {
    return ((uintptr_t)ref & G1_PARTIAL_ARRAY_MASK) == G1_PARTIAL_ARRAY_MASK;
}

// 用途：区分普通对象引用和部分数组任务
// 普通对象：直接处理其引用
// 部分数组：需要解码出原始数组，继续分块处理
```

---

## 7. Evacuation Failure 处理

### 7.1 什么情况下会失败？

```
Evacuation Failure 场景
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. Survivor 区满
   - 存活对象太多，Survivor 空间不足
   
2. Old 区满
   - 晋升对象太多，Old 区空间不足
   
3. 堆扩展失败
   - 达到 -Xmx 限制，无法扩展
   
4. 强制失败（测试用）
   - G1EvacuationFailureALot 参数触发
```

### 7.2 handle_evacuation_failure_par() 实现

```cpp
oop G1ParScanThreadState::handle_evacuation_failure_par(oop old, markOop m) {
    // 1. 尝试转发到自身（Forward-to-self）
    oop forward_ptr = old->forward_to_atomic(old, memory_order_relaxed);
    
    if (forward_ptr == NULL) {
        // 2. CAS 成功，成为对象的"所有者"
        // 标记对象未被复制，留在原地
        _evacuation_failed_info.register_copy_failure(old->size());
        
        // 3. 保留原始 Mark Word
        _preserved_marks->push(old, m);
        
        // 4. 仍然需要扫描对象引用（对象还在 CSet 中）
        old->oop_iterate_backwards(&_scanner);
        
        return old;
    } else {
        // 5. CAS 失败，其他线程已处理，返回转发地址
        return forward_ptr;
    }
}
```

**Forward-to-self 的含义**：

```
正常复制：
  Old Address ──→ Forwarding Pointer ──→ New Address

Evacuation Failure：
  Old Address ──→ Forwarding Pointer ──→ Old Address（指向自己）

目的：
  1. 其他线程看到这个标记就知道对象未被复制
  2. 避免重复尝试复制失败的同一个对象
  3. 统一处理逻辑（都通过转发指针访问）
```

---

## 8. 性能优化分析

### 8.1 批量处理优化

```cpp
// 部分 trim 的阈值控制
uint const _stack_trim_upper_threshold = 100;  // 开始处理的上限
uint const _stack_trim_lower_threshold = 10;   // 停止处理的下限

inline bool needs_partial_trimming() const {
    return !_refs->overflow_empty() || _refs->size() > _stack_trim_upper_threshold;
}

inline bool is_partially_trimmed() const {
    return _refs->overflow_empty() && _refs->size() <= _stack_trim_lower_threshold;
}
```

**优化原理**：
- 避免过于频繁地检查队列（减少原子操作）
- 批量处理提高缓存命中率
- 在"高负载"和"低负载"之间找到平衡点

### 8.2 统计信息收集

```cpp
// 终止阶段耗时统计
double term_time() const { return _term_time; }
size_t term_attempts() const { return _term_attempts; }

// 用途：
// 1. GC 日志输出（-Xlog:gc*）
// 2. 性能调优（识别任务不均衡）
// 3. 启发式算法（调整 PLAB 大小等）
```

**高终止时间的含义**：
- 任务分配不均衡（某些线程先完成，等待其他线程）
- Work Stealing 效率低
- 可能需要调整线程数或 PLAB 大小

---

## 9. 常见问题与面试题

### Q1: G1ParEvacuateFollowersClosure 和 G1ParScanThreadState 的关系是什么？

**答案**：
- **G1ParEvacuateFollowersClosure** 是任务调度器，控制处理流程（trim_queue → steal → termination）
- **G1ParScanThreadState** 是执行引擎，包含实际的队列、分配器和处理方法
- 关系：Closure 调用 State 的方法，State 提供执行能力

### Q2: 为什么要先处理本地队列再 Stealing？

**答案**：
1. **缓存局部性**：本地队列数据在 CPU 缓存中，访问最快
2. **减少竞争**：Stealing 需要 CAS 操作，有开销
3. **负载均衡**：本地有任务时不去抢别人的，避免频繁任务迁移

### Q3: Forwarding Pointer 是如何工作的？

**答案**：
1. 复制前，CAS 将对象的 Mark Word 设置为指向新地址
2. CAS 成功的线程执行复制，失败的线程读取转发地址
3. Evacuation Failure 时，转发到自身（Forward-to-self）
4. 保证多线程安全且无需全局锁

### Q4: 大对象数组为什么要分块处理？

**答案**：
1. **避免长时间阻塞**：大数组处理时间长，影响并行度
2. **负载均衡**：分块后其他线程可以窃取剩余部分
3. **响应性**：允许中断处理，插入其他任务

---

## 10. 总结

### 10.1 核心设计要点

```
G1ParEvacuateFollowersClosure 设计精髓
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. 三段式处理循环
   ├── trim_queue()：处理本地队列（LIFO，无锁）
   ├── steal_and_trim_queue()：Work Stealing（CAS）
   └── offer_termination()：终止协议（原子计数器）

2. 对象复制核心
   ├── CAS 安装转发指针（解决多线程竞争）
   ├── PLAB 分配（减少线程竞争）
   ├── 大数组分块（提高并行度）
   └── Evacuation Failure 处理（Forward-to-self）

3. 引用更新
   ├── 更新对象引用（指向新地址）
   ├── 更新 RSet（跨 Region 引用）
   └── 递归扫描新对象引用

4. 性能优化
   ├── 批量处理（阈值控制）
   ├── 缓存友好（LIFO 顺序）
   ├── 工作窃取（Best-of-2）
   └── 统计信息（性能调优）
```

### 10.2 执行流程图

```
G1ParEvacuateFollowersClosure 完整执行流程
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

开始
  │
  ▼
trim_queue() ──→ 处理本地队列 ──→ dispatch_reference()
  │                      │
  │                      ▼
  │              ┌───────────────┐
  │              │ do_oop_evac() │
  │              └───────────────┘
  │                      │
  │                      ▼
  │         ┌──────────────────────┐
  │         │ copy_to_survivor_space│
  │         └──────────────────────┘
  │                      │
  │         ┌────────────┼────────────┐
  │         ▼            ▼            ▼
  │    分配成功      CAS 成功      CAS 失败
  │         │            │            │
  │         ▼            ▼            ▼
  │    复制对象      扫描引用      返回转发地址
  │         │            │            │
  │         ▼            ▼            ▼
  │    更新引用    push 新任务    释放分配空间
  │
  ▼
本地队列空？
  │── 否 ──→ 继续 trim_queue()
  │
  是
  ▼
steal_and_trim_queue()
  │
  ▼
窃取成功？
  │── 是 ──→ dispatch_reference() ──→ trim_queue()
  │
  否
  ▼
offer_termination()
  │
  ▼
所有线程终止？
  │── 否 ──→ 重新 steal_and_trim_queue()
  │
  是
  ▼
结束
```

---

## 参考文档

1. OpenJDK 11: `src/hotspot/share/gc/g1/g1CollectedHeap.hpp`
2. OpenJDK 11: `src/hotspot/share/gc/g1/g1ParScanThreadState.hpp`
3. OpenJDK 11: `src/hotspot/share/gc/g1/g1ParScanThreadState.inline.hpp`
4. OpenJDK 11: `src/hotspot/share/gc/g1/g1ParScanThreadState.cpp`
5. G1 论文: Detlefs et al., "Garbage-First Garbage Collection"

---

**文档信息**
- 创建时间: 2026-02-10
- 源码版本: OpenJDK 11
- 分析类型: 专家级源码分析
- 配套技能: Read-TopDown, JVM-Concurrency-Design
