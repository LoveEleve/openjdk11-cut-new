# G1ParScanThreadState 专家级源码分析

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1ParScanThreadState 的本质是**单个 GC Worker 线程的 Evacuation 状态机**：封装了一个 GC Worker 在 Evacuation 阶段所需的所有状态——PLAB（分配缓冲）、`RefToScanQueue`（待扫描队列）、`G1AllocRegion`（目标 Region）、统计信息等；`copy_to_survivor_space()` 是核心方法，完成单个对象的复制。

### 0.2 为什么需要？

Evacuation 阶段多个 GC Worker 并发复制对象，每个 Worker 需要独立的状态（避免竞争）：独立的 PLAB（无锁分配）、独立的扫描队列（Work Stealing 协议）、独立的统计信息（避免原子操作）。G1ParScanThreadState 封装了这些独立状态。

### 0.3 怎么解决？

**线程本地状态 + CAS 转发指针**：每个 GC Worker 有独立的 `G1ParScanThreadState`；`copy_to_survivor_space()` 先尝试从 PLAB 分配，失败时申请新 PLAB；用 CAS 写转发指针（`obj->forward_to(new_obj)`）解决并发复制冲突；复制完成后扫描新对象的引用字段，将引用对象加入 `RefToScanQueue`。

### 0.4 为什么这样设计？

- **为什么 `copy_to_survivor_space()` 用 CAS 而不是锁？** 多个 GC Worker 可能同时复制同一个对象（从不同的引用路径到达）；CAS 保证只有一个 Worker 成功复制，其他 Worker 直接使用转发指针；CAS 比锁开销低
- **为什么 PLAB 在 G1ParScanThreadState 中而不是全局？** 全局分配需要加锁，多个 GC Worker 竞争；线程本地 PLAB 无锁分配，只有 PLAB 满时才申请新 PLAB（加锁），大幅减少锁竞争

---

## 一、宏观理解：并行 Evacuation 的核心引擎

### 1.1 一句话总结

**G1ParScanThreadState 是 G1 Young GC 并行 Evacuation 阶段的核心引擎**，每个 GC 线程拥有一个实例，负责将 CSet 中的存活对象复制到 Survivor/Old 区域，并通过工作队列实现并行扫描和负载均衡。

### 1.2 为什么需要 G1ParScanThreadState？

**问题背景**：
- Young GC 需要复制大量对象（可能数百万个）
- 需要多线程并行处理以缩短暂停时间
- 需要处理对象引用关系（递归扫描）
- 需要负载均衡避免线程空闲

**解决方案**：
- 每个 GC 线程有自己的 `G1ParScanThreadState`
- 使用 **任务队列（RefToScanQueue）** 存储待扫描的引用
- 支持 **工作窃取（Work Stealing）** 实现负载均衡
- 使用 **PLAB（Promotion Local Allocation Buffer）** 加速内存分配

### 1.3 核心工作流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    G1ParScanThreadState 工作流程                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   GC 线程启动                                                                 │
│        │                                                                     │
│        ▼                                                                     │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │  1. 初始化 G1ParScanThreadState                                      │   │
│   │     - 创建 PLAB 分配器                                               │
│   │     - 初始化扫描队列 (_refs)                                         │
│   │     - 设置晋升阈值 (_tenuring_threshold)                             │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│        │                                                                     │
│        ▼                                                                     │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │  2. 处理根对象（G1RootProcessor::evacuate_roots）                    │   │
│   │     - 扫描 GC Roots                                                  │
│   │     - 对引用指向 CSet 的对象：                                       │
│   │       └── copy_to_survivor_space() -> 加入扫描队列                   │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│        │                                                                     │
│        ▼                                                                     │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │  3. 主循环：trim_queue()                                             │   │
│   │     while (队列不为空):                                              │   │
│   │       - pop 一个引用                                                 │   │
│   │       - do_oop_evac(): 处理该引用                                    │   │
│   │         ├── 如果 obj 在 CSet：复制到 Survivor/Old                    │   │
│   │         └── 遍历 obj 的字段，将引用 push 到队列                      │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│        │                                                                     │
│        ▼                                                                     │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │  4. 工作窃取：steal_and_trim_queue()                                 │   │
│   │     - 自己的队列为空时，尝试窃取其他线程的队列                        │   │
│   │     - 窃取成功：继续处理                                             │   │
│   │     - 所有队列为空：完成                                             │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│        │                                                                     │
│        ▼                                                                     │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │  5. 清理和统计：flush()                                              │   │
│   │     - 提交 PLAB 统计                                                 │   │
│   │     - 合并年龄表统计                                                 │   │
│   │     - 释放资源                                                       │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.4 在 Young GC 中的位置

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Young GC 中的 G1ParScanThreadState                        │
└─────────────────────────────────────────────────────────────────────────────┘

G1ParTask::work(worker_id)
        │
        ├──> G1RootProcessor::evacuate_roots()      // 扫描根对象
        │       └── 根引用指向 CSet -> push 到队列
        │
        ├──> G1ParEvacuateFollowersClosure::do_void()  // Evacuation 主循环
        │       │
        │       └──> G1ParScanThreadState::trim_queue()  // 处理队列
        │               │
        │               ├──> do_oop_evac()           // 复制对象
        │               │       └── copy_to_survivor_space()
        │               │
        │               └──> steal_and_trim_queue()  // 工作窃取
        │
        └──> flush()                                 // 提交统计
```

---

## 二、字段分析：数据结构的完整解剖

### 2.1 类定义与核心字段

```cpp
// g1ParScanThreadState.hpp:45-211
class G1ParScanThreadState : public CHeapObj<mtGC> {
    G1CollectedHeap* _g1h;              // G1 堆引用
    RefToScanQueue*  _refs;             // 扫描队列（核心！）
    DirtyCardQueue   _dcq;              // 脏卡队列（用于跨 Region 引用）
    G1CardTable*     _ct;               // 卡表
    G1EvacuationRootClosures* _closures; // 根扫描闭包
    
    G1PLABAllocator*  _plab_allocator;  // PLAB 分配器（加速对象分配）
    
    AgeTable          _age_table;       // 年龄表（统计对象年龄分布）
    InCSetState       _dest[InCSetState::Num]; // 目标状态映射
    uint              _tenuring_threshold;    // 晋升阈值
    G1ScanEvacuatedObjClosure  _scanner;      // 对象扫描闭包
    
    int  _hash_seed;                    // 哈希种子（用于工作窃取）
    uint _worker_id;                    // 工作线程 ID
    
    // 队列裁剪阈值
    uint const _stack_trim_upper_threshold;
    uint const _stack_trim_lower_threshold;
    
    // 存活对象统计
    size_t* _surviving_young_words_base;
    size_t* _surviving_young_words;
    
    // 老年代是否已满（用于 Evacuation Failure 处理）
    bool _old_gen_is_full;
};
```

### 2.2 核心字段详解

#### 2.2.1 `_refs` —— 扫描队列（任务队列）

**类型**：`RefToScanQueue*`

**作用**：
- 存储待扫描的对象引用
- 每个 GC 线程有自己的队列（线程本地）
- 支持 push/pop/steal 操作

**队列元素类型**：
```cpp
// StarTask 可以存储 oop* 或 narrowOop*
class StarTask {
    void* _holder;  // 实际存储的是 oop* 或 narrowOop*
};
```

**队列的工作流程**：
```
┌─────────────────────────────────────────────────────────────────┐
│                     扫描队列的工作流程                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  根扫描阶段：                                                    │
│  G1RootProcessor 发现 obj 引用指向 CSet                         │
│       │                                                         │
│       ▼                                                         │
│  push_on_queue(ref) ──> _refs->push(ref)                       │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  _refs (线程本地队列)                                    │   │
│  │  ┌────┬────┬────┬────┬────┐                            │   │
│  │  │ref1│ref2│ref3│... │    │                            │   │
│  │  └────┴────┴────┴────┴────┘                            │   │
│  │   ↑                            ↑                       │   │
│  │  top                         bottom                    │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│  Evacuation 阶段：                                               │
│  trim_queue() ──> pop_local(ref) ──> dispatch_reference(ref)   │
│       │                                                         │
│       ▼                                                         │
│  do_oop_evac(ref)                                               │
│       ├──> copy_to_survivor_space()                            │
│       └──> 遍历新对象的字段，push 到队列                         │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

#### 2.2.2 `_plab_allocator` —— PLAB 分配器

**PLAB（Promotion Local Allocation Buffer）**：
- 每个 GC 线程私有的内存分配缓冲区
- 避免多线程竞争堆内存分配锁
- 批量从堆申请内存，小对象从 PLAB 分配

**内存分配层次**：
```
┌─────────────────────────────────────────────────────────────────┐
│                     内存分配层次                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. 首先尝试从 PLAB 分配（最快，无锁）                           │
│       └── _plab_allocator->plab_allocate(dest_state, word_sz)  │
│                                                                  │
│  2. PLAB 不足，尝试 refill PLAB                                  │
│       └── _plab_allocator->allocate_direct_or_new_plab()       │
│                                                                  │
│  3. 如果目标区域是 Young，尝试分配到 Old                         │
│       └── allocate_in_next_plab()                              │
│                                                                  │
│  4. 所有尝试失败，触发 Evacuation Failure                        │
│       └── handle_evacuation_failure_par()                      │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

#### 2.2.3 `_age_table` —— 年龄表

**作用**：
- 统计存活对象的年龄分布
- 用于计算新的晋升阈值（tenuring threshold）

**年龄分布示例**：
```
_age_table[1] = 100MB   (age=1 的对象总大小)
_age_table[2] = 80MB    (age=2 的对象总大小)
_age_table[3] = 60MB    (age=3 的对象总大小)
...
_age_table[15] = 5MB    (age=15 的对象总大小)

用于决定 _tenuring_threshold：
- 如果 age=3 的对象总大小 < TargetSurvivorRatio，则晋升阈值为 3
```

#### 2.2.4 `_surviving_young_words` —— 存活对象统计

**作用**：
- 统计每个年轻代 Region 的存活对象大小
- 用于 G1Policy 更新存活率预测

**数组结构**：
```cpp
// 索引 = Region 在 CSet 中的 young_index_in_cset + 1
// +1 是因为索引 0 用于非年轻代 Region（age=-1）
size_t* _surviving_young_words;

// 示例：
// CSet 有 3 个年轻代 Region，索引分别为 0, 1, 2
// _surviving_young_words[1] = Region 0 的存活大小
// _surviving_young_words[2] = Region 1 的存活大小
// _surviving_young_words[3] = Region 2 的存活大小
```

### 2.3 GDB 字段验证脚本

```gdb
# g1parscanthreadstate_fields.gdb - G1ParScanThreadState 字段验证

set pagination off

# 断点 1：构造函数
break G1ParScanThreadState::G1ParScanThreadState
commands
    silent
    printf "\n=== G1ParScanThreadState 构造函数 ===\n"
    printf "this = 0x%lx\n", (unsigned long)this
    printf "worker_id = %u\n", worker_id
    printf "_refs = 0x%lx\n", (unsigned long)_refs
    printf "_plab_allocator = 0x%lx\n", (unsigned long)_plab_allocator
    printf "_tenuring_threshold = %u\n", _tenuring_threshold
    printf "_stack_trim_upper_threshold = %u\n", _stack_trim_upper_threshold
    printf "_stack_trim_lower_threshold = %u\n", _stack_trim_lower_threshold
    continue
end

# 断点 2：复制对象
break G1ParScanThreadState::copy_to_survivor_space
commands
    silent
    printf "\n=== copy_to_survivor_space ===\n"
    printf "old = 0x%lx\n", (unsigned long)old
    printf "word_sz = %zu\n", word_sz
    printf "dest_state = %d\n", dest_state.value()
    continue
end

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp ... Main
```

---

## 三、方法分析：Evacuation 核心算法

### 3.1 对象复制：`copy_to_survivor_space()`

**这是 G1ParScanThreadState 最核心的方法**，负责将 CSet 中的对象复制到 Survivor/Old 区域。

**完整流程**：
```cpp
oop G1ParScanThreadState::copy_to_survivor_space(InCSetState const state,
                                                 oop const old,
                                                 markOop const old_mark) {
    // 1. 计算对象大小和目标状态
    const size_t word_sz = old->size();
    uint age = 0;
    InCSetState dest_state = next_state(state, old_mark, age);
    
    // 2. 尝试分配内存（多层回退策略）
    HeapWord* obj_ptr = _plab_allocator->plab_allocate(dest_state, word_sz);
    
    if (obj_ptr == NULL) {
        // 2.1 PLAB 不足，尝试 refill
        bool plab_refill_failed = false;
        obj_ptr = _plab_allocator->allocate_direct_or_new_plab(dest_state, word_sz, 
                                                               &plab_refill_failed);
        if (obj_ptr == NULL) {
            // 2.2 尝试下一个区域（Young -> Old）
            obj_ptr = allocate_in_next_plab(state, &dest_state, word_sz, plab_refill_failed);
            if (obj_ptr == NULL) {
                // 2.3 所有尝试失败，Evacuation Failure
                return handle_evacuation_failure_par(old, old_mark);
            }
        }
    }
    
    // 3. 安装转发指针（原子操作）
    oop forward_ptr = old->forward_to_atomic(obj, memory_order_relaxed);
    
    if (forward_ptr == NULL) {
        // 3.1 成功获得复制权，执行复制
        Copy::aligned_disjoint_words((HeapWord*) old, obj_ptr, word_sz);
        
        // 4. 更新年龄和 Mark Word
        if (dest_state.is_young()) {
            age++;
            obj->set_mark_raw(old_mark->set_age(age));
            _age_table.add(age, word_sz);
        } else {
            obj->set_mark_raw(old_mark);
        }
        
        // 5. 统计存活对象
        _surviving_young_words[young_index] += word_sz;
        
        // 6. 处理对象字段（递归扫描）
        if (obj->is_objArray() && arrayOop(obj)->length() >= ParGCArrayScanChunk) {
            // 大数组：分块处理
            do_oop_partial_array(old_p);
        } else {
            // 普通对象：遍历所有字段
            obj->oop_iterate_backwards(&_scanner);
        }
        
        return obj;
    } else {
        // 3.2 其他线程已复制，撤销分配
        _plab_allocator->undo_allocation(dest_state, obj_ptr, word_sz);
        return forward_ptr;
    }
}
```

### 3.2 转发指针（Forwarding Pointer）机制

**问题**：多个 GC 线程可能同时尝试复制同一个对象

**解决方案**：使用转发指针
```
┌─────────────────────────────────────────────────────────────────┐
│                     转发指针机制                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  对象头（Mark Word）结构：                                       │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  未复制时：                                              │   │
│  │  ┌──────────────┬──────────────┬──────────────────────┐ │   │
│  │  │  hashcode    │    age       │  other flags         │ │   │
│  │  └──────────────┴──────────────┴──────────────────────┘ │   │
│  │                                                          │   │
│  │  已复制时（Marked）：                                    │   │
│  │  ┌────────────────────────────────────────────────────┐ │   │
│  │  │  0...01 (marked) │ forwarding pointer (压缩后地址)   │ │   │
│  │  └────────────────────────────────────────────────────┘ │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│  复制流程：                                                      │
│  线程 A：                                                        │
│    1. 分配新内存 obj_ptr                                         │
│    2. old->forward_to_atomic(obj)                               │
│       - CAS 操作：如果 Mark Word 未被标记，设置为转发指针        │
│       - 返回 NULL 表示成功                                       │
│    3. 复制对象内容                                               │
│                                                                  │
│  线程 B（同时尝试复制同一对象）：                                │
│    1. 分配新内存（可能不同地址）                                 │
│    2. old->forward_to_atomic(obj)                               │
│       - CAS 失败：Mark Word 已被标记                             │
│       - 返回 forward_ptr（对象的新地址）                         │
│    3. 撤销自己的分配                                             │
│    4. 使用 forward_ptr 更新引用                                  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 3.3 引用处理：`do_oop_evac()`

**作用**：处理单个引用，如果引用指向 CSet 中的对象，则复制该对象。

```cpp
template <class T> void G1ParScanThreadState::do_oop_evac(T* p) {
    // 1. 加载引用
    oop obj = RawAccess<IS_NOT_NULL>::oop_load(p);
    
    // 2. 检查对象是否在 CSet 中
    const InCSetState in_cset_state = _g1h->in_cset_state(obj);
    
    if (in_cset_state.is_in_cset()) {
        // 2.1 对象在 CSet 中，需要复制
        markOop m = obj->mark_raw();
        if (m->is_marked()) {
            // 已被其他线程复制，获取转发地址
            obj = (oop) m->decode_pointer();
        } else {
            // 复制对象
            obj = copy_to_survivor_space(in_cset_state, obj, m);
        }
        // 更新引用
        RawAccess<IS_NOT_NULL>::oop_store(p, obj);
    }
    
    // 3. 更新记忆集（跨 Region 引用）
    if (!HeapRegion::is_in_same_region(p, obj)) {
        HeapRegion* from = _g1h->heap_region_containing(p);
        update_rs(from, p, obj);
    }
}
```

### 3.4 队列处理：`trim_queue()`

**主循环**：不断从队列取出引用并处理，直到队列为空。

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
    
    // 1. 先处理溢出队列（overflow queue）
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

### 3.5 工作窃取：`steal_and_trim_queue()`

**作用**：当自己的队列为空时，从其他线程的队列窃取任务。

```cpp
void G1ParScanThreadState::steal_and_trim_queue(RefToScanQueueSet *task_queues) {
    StarTask stolen_task;
    // 尝试窃取
    while (task_queues->steal(_worker_id, &_hash_seed, stolen_task)) {
        dispatch_reference(stolen_task);
        // 窃取后可能产生新的任务，先处理自己的队列
        trim_queue();
    }
}
```

**窃取算法**：
```
┌─────────────────────────────────────────────────────────────────┐
│                     工作窃取算法                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  线程 A（繁忙）                    线程 B（空闲，尝试窃取）      │
│  ┌─────────────┐                   ┌─────────────┐              │
│  │ 任务队列    │                   │ 空队列      │              │
│  │ ┌─┬─┬─┬─┐  │                   │ ┌─┐        │              │
│  │ │1│2│3│4│  │                   │ └─┘        │              │
│  │ └─┴─┴─┴─┘  │                   └─────────────┘              │
│  └─────────────┘                          │                     │
│                                           ▼                     │
│                                    steal()                      │
│                                    - 随机选择受害者线程         │
│                                    - 从队列底部窃取（pop）      │
│                                    - 减少与所有者线程的竞争     │
│                                           │                     │
│  ┌─────────────┐                   ┌─────────────┐              │
│  │ ┌─┬─┬─┐    │                   │ ┌─┐        │              │
│  │ │1│2│3│    │                   │ │4│        │              │
│  │ └─┴─┴─┘    │                   │ └─┘        │              │
│  └─────────────┘                   └─────────────┘              │
│                                                                  │
│  为什么从底部窃取？                                              │
│  - 所有者线程从顶部 push/pop（LIFO，热点数据）                  │
│  - 窃取者从底部 pop（FIFO，旧数据）                             │
│  - 减少缓存竞争                                                  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 四、关联分析：组件交互图

### 4.1 完整 Evacuation 流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      Young GC Evacuation 完整流程                           │
└─────────────────────────────────────────────────────────────────────────────┘

GC 线程池（WorkGang）
        │
        ├──> Worker 0: G1ParScanThreadState[0]
        │       ├──> trim_queue()
        │       ├──> steal_and_trim_queue()
        │       └──> flush()
        │
        ├──> Worker 1: G1ParScanThreadState[1]
        │       ├──> trim_queue()
        │       ├──> steal_and_trim_queue()
        │       └──> flush()
        │
        └──> Worker N: G1ParScanThreadState[N]
                ├──> trim_queue()
                ├──> steal_and_trim_queue()
                └──> flush()

┌─────────────────────────────────────────────────────────────────────────────┐
│  单个 Worker 的详细流程                                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  G1ParTask::work(worker_id)                                                 │
│       │                                                                      │
│       ├──> G1RootProcessor::evacuate_roots()                                │
│       │       └── 扫描根，将指向 CSet 的引用 push 到队列                     │
│       │                                                                      │
│       ├──> G1ParEvacuateFollowersClosure::do_void()                         │
│       │       │                                                              │
│       │       ├──> trim_queue()                                             │
│       │       │       └── 处理自己的队列直到为空                             │
│       │       │                                                              │
│       │       └──> steal_and_trim_queue()                                   │
│       │               └── 窃取其他线程的任务                                 │
│       │                                                                      │
│       └──> flush()                                                          │
│               └── 提交统计信息                                               │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 关键交互组件

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      G1ParScanThreadState 组件关系图                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                    G1ParScanThreadState                                │  │
│  │                                                                        │  │
│  │  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐               │  │
│  │  │   _refs     │    │ _plab_allocator│   │ _age_table  │               │  │
│  │  │ (扫描队列)  │    │ (PLAB分配器) │    │ (年龄统计)  │               │  │
│  │  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘               │  │
│  │         │                   │                   │                      │  │
│  │         │ push/pop          │ allocate          │ add                  │  │
│  │         ▼                   ▼                   ▼                      │  │
│  │  ┌─────────────────────────────────────────────────────────────┐      │  │
│  │  │                    copy_to_survivor_space()                  │      │  │
│  │  │                        │                                     │      │  │
│  │  │      ┌─────────────────┼─────────────────┐                  │      │  │
│  │  │      │                 │                 │                  │      │  │
│  │  │      ▼                 ▼                 ▼                  │      │  │
│  │  │  ┌─────────┐    ┌────────────┐    ┌────────────┐           │      │  │
│  │  │  │分配内存 │───>│复制对象内容│───>│遍历字段push│           │      │  │
│  │  │  │(PLAB)  │    │           │    │到_refs    │           │      │  │
│  │  │  └─────────┘    └────────────┘    └────────────┘           │      │  │
│  │  └─────────────────────────────────────────────────────────────┘      │  │
│  │                              │                                         │  │
│  └──────────────────────────────┼─────────────────────────────────────────┘  │
│                                 │                                             │
│  ┌──────────────────────────────┼─────────────────────────────────────────┐  │
│  │                              ▼                                         │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │                  RefToScanQueueSet (全局队列集)                  │  │  │
│  │  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │  │  │
│  │  │  │  Queue[0]    │  │  Queue[1]    │  │  Queue[N]    │          │  │  │
│  │  │  │(Worker 0)    │  │(Worker 1)    │  │(Worker N)    │          │  │  │
│  │  │  └──────────────┘  └──────────────┘  └──────────────┘          │  │  │
│  │  │                                                                    │  │  │
│  │  │  steal(worker_id, hash_seed, task)  <-- 工作窃取接口             │  │  │
│  │  └─────────────────────────────────────────────────────────────────┘  │  │
│  └─────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 五、验证总结：日志与调试

### 5.1 关键日志输出

**启用详细日志**：
```bash
java -Xlog:gc+phases=debug:file=gc-phases.log \
     -Xms8g -Xmx8g -XX:+UseG1GC \
     -jar application.jar
```

**典型日志**：
```
# Evacuation 阶段日志
[15.234s][debug][gc,phases] GC(23) Evacuate Collection Set: 125.34ms
[15.234s][debug][gc,phases] GC(23)   Object Copy: 42.29ms
[15.234s][debug][gc,phases] GC(23)   Thread Termination: 8.45ms
[15.234s][debug][gc,phases] GC(23)   External Root Scanning: 12.45ms
```

### 5.2 监控指标

| 指标 | 查看方法 | 健康范围 |
|-----|---------|---------|
| Object Copy 时间 | GC 日志 | < 50ms |
| 线程终止时间 | GC 日志 Thread Termination | < 10ms |
| 队列大小 | 代码中 _refs->size() | 动态变化 |
| PLAB 效率 | 代码中 PLAB 统计 | > 80% |

---

## 六、总结

### 6.1 G1ParScanThreadState 的核心价值

G1ParScanThreadState 实现了 G1 **并行 Evacuation** 的核心机制：

1. **线程本地状态**：每个 GC 线程独立工作，避免锁竞争
2. **任务队列**：通过队列实现递归扫描的并行化
3. **工作窃取**：实现负载均衡，避免线程空闲
4. **PLAB 分配**：加速对象复制，减少堆内存分配竞争

### 6.2 关键设计要点

| 设计点 | 说明 |
|-------|------|
| **转发指针** | CAS 安装，解决多线程复制竞争 |
| **分层分配** | PLAB -> Refill -> 下一区域 -> Evacuation Failure |
| **队列裁剪** | 部分裁剪避免队列过长，同时保持缓存友好 |
| **工作窃取** | 从队列底部窃取，减少与所有者的竞争 |

### 6.3 学习路径回顾

```
G1CollectedHeap::initialize() ──> 堆初始化
    ├── G1CollectionSet ──> CSet 管理
    ├── G1RootProcessor ──> 根扫描
    │       └── evacuate_roots()
    │
    └── G1ParScanThreadState ──> 并行 Evacuation（当前）
            ├── copy_to_survivor_space()  // 对象复制
            ├── do_oop_evac()             // 引用处理
            ├── trim_queue()              // 队列处理
            └── steal_and_trim_queue()    // 工作窃取
```

**并行处理层核心已完成！** 接下来建议：
1. **G1PLAB** - 深入了解 PLAB 分配器
2. **RefToScanQueue** - 任务队列实现
3. **WorkGang** - GC 工作线程池

---

**文档信息**：
- 分析版本：OpenJDK 11
- 分析日期：2026-02-10
- 源码路径：
  - `/data/workspace/openjdk-cut-new/src/hotspot/share/gc/g1/g1ParScanThreadState.hpp`
  - `/data/workspace/openjdk-cut-new/src/hotspot/share/gc/g1/g1ParScanThreadState.cpp`
  - `/data/workspace/openjdk-cut-new/src/hotspot/share/gc/g1/g1ParScanThreadState.inline.hpp`
