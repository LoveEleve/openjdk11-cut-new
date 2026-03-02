# 4.2 并行疏散执行 (Evacuation) 深度分析

> **源码位置**: 
> - `src/hotspot/share/gc/g1/g1CollectedHeap.cpp:4789`
> - `src/hotspot/share/gc/g1/g1ParScanThreadState.cpp:214`
> 

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

Evacuation 的本质是**并行对象复制 + 引用更新**：多个 GC Worker 并发地将 CSet 中的存活对象复制到 Survivor/Old Region，同时更新所有指向旧地址的引用（通过转发指针）；使用 Work Stealing 实现负载均衡；Evacuation Failure 时原地保留对象（不复制）。

### 0.2 为什么需要？

G1 使用 Copying GC（复制式 GC）回收 CSet 中的 Region：将存活对象复制到新 Region，原 Region 整体释放（无碎片）。Evacuation 是这个复制过程的并行实现，多个 GC Worker 并发复制，充分利用多核 CPU。

### 0.3 怎么解决？

**CAS 转发指针 + PLAB + Work Stealing**：
1. Root 扫描：`G1RootProcessor::evacuate_roots()` 扫描 GC Roots，将直接可达对象复制到 Survivor/Old
2. 传递闭包：`G1ParEvacuateFollowersClosure` 从 `RefToScanQueue` 取对象，扫描引用字段，递归复制
3. CAS 转发：`obj->forward_to(new_obj)` 用 CAS 写转发指针，解决并发复制冲突
4. Work Stealing：队列空时从其他 Worker 的队列偷任务

### 0.4 为什么这样设计？

- **为什么用 CAS 转发指针而不是锁？** 多个 GC Worker 可能同时复制同一个对象（从不同引用路径到达）；CAS 保证只有一个 Worker 成功复制，其他 Worker 直接使用转发指针；CAS 比锁开销低
- **为什么 Evacuation Failure 时原地保留？** 如果 Survivor/Old 空间不足，无法复制对象；原地保留（对象留在 CSet Region）是最后的兜底策略；Evacuation Failure 后 G1 会触发 Full GC

---
> **重要程度**: ⭐⭐⭐⭐⭐ (Young GC 最核心阶段)
> **功能**: 将存活对象从 Eden/Survivor 复制到 Survivor/Old

---

## 1. 疏散阶段整体架构

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         并行疏散执行架构                                           │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  G1CollectedHeap::evacuate_collection_set()                                     │
│       │                                                                          │
│       ├── 1. 初始化 GC Worker 线程                                               │
│       │   └── workers()->run_task(&g1_par_task)                                 │
│       │                                                                          │
│       ├── 2. 每个 Worker 执行 G1ParTask                                         │
│       │   └── G1ParEvacuateFollowersClosure::do_void()                          │
│       │                                                                          │
│       ├── 3. 对象复制核心                                                       │
│       │   └── copy_to_survivor_space() ★★★                                      │
│       │       ├── PLAB 分配内存                                                  │
│       │       ├── 设置转发指针 (Forwarding Pointer)                              │
│       │       ├── 复制对象数据                                                   │
│       │       └── 扫描对象引用                                                   │
│       │                                                                          │
│       └── 4. 工作窃取 + 终止检测                                                 │
│           ├── steal_and_trim_queue()                                            │
│           └── offer_termination()                                               │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 入口: evacuate_collection_set()

```cpp
void G1CollectedHeap::evacuate_collection_set(G1ParScanThreadStateSet *per_thread_states) {
    // 1. 确保 DCQ (Dirty Card Queue) 为空
    assert(dirty_card_queue_set().completed_buffers_num() == 0, "Should be empty");
    
    // 2. 创建并行任务
    G1ParTask g1_par_task(this, per_thread_states, _task_queues);
    
    // 3. 启动 GC Worker 线程并行执行
    // active_workers = ParallelGCThreads (默认等于 CPU 核心数)
    workers()->run_task(&g1_par_task, active_workers);
    
    // 4. 处理疏散失败
    if (evacuation_failed()) {
        remove_self_forwarding_pointers();
    }
}
```

**关键概念**:
- **GC Worker 线程**: 专门用于 GC 的线程池，不是 Java 线程
- **并行度**: 默认等于 CPU 核心数，可通过 `-XX:ParallelGCThreads` 调整

---

## 3. 对象复制核心: copy_to_survivor_space() ★★★

### 3.1 整体流程

```cpp
oop G1ParScanThreadState::copy_to_survivor_space(
    InCSetState const state,    // 对象当前状态 (Eden/Survivor/Old)
    oop const old,              // 原对象指针
    markOop const old_mark      // 原对象 mark word
) {
    // 1. 计算对象大小
    const size_t word_sz = old->size();
    
    // 2. 决定目标区域 (Survivor 还是 Old)
    uint age = 0;
    InCSetState dest_state = next_state(state, old_mark, age);
    
    // 3. 在 PLAB 中分配新内存
    HeapWord* obj_ptr = _plab_allocator->plab_allocate(dest_state, word_sz);
    
    // 4. 如果 PLAB 不足，尝试分配新 PLAB 或直接分配
    if (obj_ptr == NULL) {
        obj_ptr = _plab_allocator->allocate_direct_or_new_plab(...);
    }
    
    // 5. 设置转发指针 (关键！)
    oop forward_ptr = old->forward_to_atomic(obj, memory_order_relaxed);
    
    if (forward_ptr == NULL) {
        // 6. 复制对象数据
        Copy::aligned_disjoint_words((HeapWord*) old, obj_ptr, word_sz);
        
        // 7. 更新年龄
        if (dest_state.is_young()) {
            age++;
            obj->set_mark_raw(old_mark->set_age(age));
        }
        
        // 8. 扫描对象引用，递归复制
        obj->oop_iterate_backwards(&_scanner);
        
        return obj;
    } else {
        // 其他线程已复制，返回转发地址
        return forward_ptr;
    }
}
```

### 3.2 转发指针 (Forwarding Pointer) 机制 ★★★

**问题**: 多个 GC Worker 线程可能同时尝试复制同一个对象，如何避免重复复制？

**解决方案**: 使用转发指针

```
对象内存布局:
┌─────────────────────────────────────┐
│  Mark Word (64 bits)                │
│  ┌───────────────────────────────┐  │
│  │  正常状态: 哈希码 | 年龄 | 锁状态  │  │
│  └───────────────────────────────┘  │
│                                     │
│  转发状态 (GC 期间):                │
│  ┌───────────────────────────────┐  │
│  │  0...01 | 新对象地址 (62 bits) │  │
│  └───────────────────────────────┘  │
│         ↑                           │
│     最低位标记为 1 表示已转发       │
└─────────────────────────────────────┘
```

**CAS 原子操作**:
```cpp
// 尝试设置转发指针
oop forward_ptr = old->forward_to_atomic(obj, memory_order_relaxed);

if (forward_ptr == NULL) {
    // CAS 成功，我是第一个复制的线程
    // 执行复制...
} else {
    // CAS 失败，其他线程已复制
    // 返回转发地址，使用其他线程复制的结果
    return forward_ptr;
}
```

### 3.3 PLAB (Promotion Local Allocation Buffer) ★★

**问题**: 多个线程同时分配内存，如何避免竞争？

**解决方案**: 每个线程有自己的本地缓冲区

```
PLAB 结构:
┌─────────────────────────────────────┐
│  PLAB (每个 GC Worker 线程一个)      │
│                                     │
│  ┌─────────────────────────────┐   │
│  │ 已用区域 (Top)               │   │
│  ├─────────────────────────────┤   │
│  │ 空闲区域 (End - Top)         │   │  ← 快速分配，无锁
│  ├─────────────────────────────┤   │
│  │ ...                         │   │
│  ├─────────────────────────────┤   │
│  │ 已用区域                     │   │
│  └─────────────────────────────┘   │
│           ↑                         │
│      需要新 PLAB 时从堆分配         │
└─────────────────────────────────────┘
```

**分配流程**:
```cpp
HeapWord* obj_ptr = _plab_allocator->plab_allocate(dest_state, word_sz);

if (obj_ptr != NULL) {
    // PLAB 中有足够空间，直接分配 (无锁，快速路径)
} else {
    // PLAB 已满，尝试分配新 PLAB
    obj_ptr = _plab_allocator->allocate_direct_or_new_plab(...);
    
    if (obj_ptr == NULL) {
        // 堆空间不足，疏散失败
        return handle_evacuation_failure_par(old, old_mark);
    }
}
```

---

## 4. 年龄计算与晋升

### 4.1 年龄递增

```cpp
if (dest_state.is_young()) {
    if (age < markOopDesc::max_age) {
        age++;  // 年龄 +1
    }
    obj->set_mark_raw(old_mark->set_age(age));
    _age_table.add(age, word_sz);
}
```

### 4.2 晋升到 Old

```cpp
InCSetState next_state(InCSetState state, markOop old_mark, uint& age) {
    if (state.is_young()) {
        age = old_mark->age();
        if (age < markOopDesc::max_age) {
            // 年龄未达阈值，留在 Survivor
            return InCSetState::Survivor;
        } else {
            // 年龄达到 15 (默认)，晋升到 Old
            return InCSetState::Old;
        }
    }
    return state;
}
```

**晋升阈值**: `-XX:MaxTenuringThreshold` (默认 15)

---

## 5. 工作窃取与负载均衡

### 5.1 问题

- 不同 Region 的存活对象数量不同
- 某些线程可能先完成，其他线程还在忙碌
- 需要负载均衡

### 5.2 解决方案: 工作窃取

```cpp
void G1ParEvacuateFollowersClosure::do_void() {
    G1ParScanThreadState *const pss = par_scan_state();
    
    // 1. 先处理自己的队列
    pss->trim_queue();
    
    // 2. 尝试窃取其他线程的工作
    do {
        pss->steal_and_trim_queue(queues());
    } while (!offer_termination());
}
```

**窃取机制**:
```
Thread 1: [对象A] [对象B] [对象C]  ← 忙碌
Thread 2: [对象D]                  ← 空闲
              ↓
Thread 2 窃取 Thread 1 的对象C
              ↓
Thread 1: [对象A] [对象B]
Thread 2: [对象D] [对象C]
```

---

## 6. GDB 验证

### 6.1 断点设置

```gdb
# 对象复制入口
break G1ParScanThreadState::copy_to_survivor_space

# 转发指针设置
break oopDesc::forward_to_atomic

# PLAB 分配
break G1PLABAllocator::plab_allocate
```

### 6.2 验证内容

```gdb
# 查看对象年龄
print old_mark->age()

# 查看目标状态
print dest_state.value()

# 查看转发指针
print old->mark_raw()

# 查看 PLAB 使用情况
print _plab_allocator->plab_used()
```

---

## 7. 总结

### 核心要点

1. **并行执行**: 多个 GC Worker 线程同时复制对象

2. **转发指针**: CAS 原子操作确保对象只被复制一次

3. **PLAB**: 线程本地缓冲区，减少内存分配竞争

4. **年龄计算**: 对象在 Survivor 区之间复制时年龄 +1

5. **晋升**: 年龄达到阈值 (默认 15) 后晋升到 Old 区

6. **工作窃取**: 空闲线程窃取忙碌线程的工作，实现负载均衡

### 性能关键点

| 优化点 | 机制 | 效果 |
|--------|------|------|
| 无锁分配 | PLAB | 避免线程竞争 |
| CAS 复制 | 转发指针 | 确保一致性 |
| 负载均衡 | 工作窃取 | 充分利用 CPU |
| 快速晋升 | 年龄阈值 | 减少复制次数 |

---

## 8. 下一步

基于当前分析，可以深入：

### 选项 A: PLAB 详细机制
- PLAB 大小计算
- PLAB 刷新策略
- 大小调整算法

### 选项 B: 引用处理
- 软/弱/虚引用处理
- 终结器队列
- ReferenceProcessor

### 选项 C: 疏散失败处理
- Evacuation Failure 场景
- 自转发指针
- 失败恢复机制

**请问想继续深入哪个部分？**
