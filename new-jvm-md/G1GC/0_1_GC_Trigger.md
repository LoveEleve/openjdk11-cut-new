# 0.1 GC 触发机制深度分析

> **源码位置**: `src/hotspot/share/gc/g1/g1CollectedHeap.cpp`
> **重要程度**: ⭐⭐⭐⭐⭐ (理解 GC 从源头到执行的全链路)
> **功能**: 分配失败时如何触发 Young GC

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

GC 触发机制的本质是**分配失败→VM Operation→SafePoint→GC 执行的完整链路**：应用线程在 TLAB 满且 Eden 满时，`attempt_allocation_slow()` 返回 NULL，触发 `VM_G1CollectForAllocation` VM Operation；VMThread 在 SafePoint 执行 GC；GC 完成后应用线程重试分配。

### 0.2 触发链路

```
new Object()
    ↓ 字节码 new → JIT 生成的分配代码
TLAB 快速路径（指针碰撞）
    ↓ TLAB 满
attempt_allocation()  // Eden Region 分配
    ↓ Eden 满
attempt_allocation_slow()  // 尝试扩展 Eden 或触发 GC
    ↓ 无法扩展
do_collection_pause()  // 提交 VM_G1CollectForAllocation
    ↓ VMThread 在 SafePoint 执行
do_collection_pause_at_safepoint()  // Young GC 主入口
```

### 0.3 三种触发条件

| 触发条件 | 源码位置 | 说明 |
|---------|---------|------|
| Eden 分配失败 | `g1CollectedHeap.cpp` | 最常见，TLAB 满且 Eden 满 |
| Humongous 分配失败 | `g1CollectedHeap.cpp` | 大对象无法分配 |
| `System.gc()` | `g1CollectedHeap.cpp` | 显式触发（除非 `-XX:+DisableExplicitGC`） |

### 0.4 为什么这样设计？

- **为什么通过 VM Operation 而不是直接触发 GC？** GC 需要 STW，必须等所有线程到达 SafePoint；VM Operation 机制提供了这个同步点
- **为什么 TLAB 满不立即触发 GC？** TLAB 满时先尝试申请新 TLAB（Eden 可能还有空间）；只有 Eden 也满了才触发 GC；减少不必要的 GC 次数

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

GC 触发机制的本质是**分配失败驱动的 VM Operation 提交**：应用线程分配对象失败时，将 `VM_G1CollectForAllocation` 提交到 VMThread 队列；VMThread 在 SafePoint 下执行 GC；GC 完成后应用线程重试分配。整个过程是同步的（应用线程等待 GC 完成）。

### 0.2 为什么需要？

对象分配是 JVM 最频繁的操作，分配失败（TLAB 满/Eden 满/Free Region 不足）必须触发 GC 回收内存。但 GC 需要 STW，不能在应用线程上下文中直接执行（会破坏 SafePoint 协议）；必须通过 VM Operation 机制，由 VMThread 在 SafePoint 下执行。

### 0.3 怎么解决？

**四级分配 + VM Operation 触发**：
1. TLAB 快速路径失败 → `attempt_allocation()` 尝试在当前 Eden Region 分配新 TLAB
2. Eden Region 满 → `attempt_allocation_slow()` 申请新 Eden Region
3. Free Region 不足 → 提交 `VM_G1CollectForAllocation` 到 VMThread 队列
4. VMThread 在 SafePoint 下执行 `do_collection_pause_at_safepoint()`，完成 Young GC

### 0.4 为什么这样设计？

- **为什么 GC 必须通过 VM Operation 而不是直接触发？** 直接触发 GC 需要先进入 SafePoint，但进入 SafePoint 的协议只能由 VMThread 发起；应用线程不能自己发起 SafePoint
- **为什么 `VM_G1CollectForAllocation::doit()` 先尝试直接分配？** 进入 SafePoint 等待期间，其他线程可能已完成 GC 并释放了空间；先尝试直接分配，如果成功就不需要 GC，节省一次 GC 开销
- **为什么分配失败后不立即扩堆？** 扩堆需要 commit 新内存（系统调用，代价高）；Young GC 通常能快速回收大量 Eden Region，满足分配需求；只有 GC 后仍然不足才考虑扩堆

---

## 1. 分配流程概览

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         对象分配 → GC 触发完整链路                               │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  Java 代码: new Object()                                                        │
│       │                                                                          │
│       ▼                                                                          │
│  Interpreter / JIT 生成的代码                                                   │
│       │                                                                          │
│       ├── 1. TLAB 分配 (快速路径)                                               │
│       │   └── ThreadLocalAllocBuffer::allocate()                                │
│       │       └── 成功 → 返回对象地址                                           │
│       │                                                                          │
│       └── 2. TLAB 不足 → 进入慢路径                                             │
│           │                                                                      │
│           ▼                                                                      │
│       G1CollectedHeap::allocate_new_tlab()                                      │
│           │                                                                      │
│           ├── 3. 尝试在 Eden 区分配新 TLAB                                      │
│           │   └── attempt_allocation()                                          │
│           │       └── 成功 → 返回 TLAB 地址                                     │
│           │                                                                      │
│           └── 4. Eden 区满 → 触发 GC                                            │
│               │                                                                  │
│               ▼                                                                  │
│       G1CollectedHeap::attempt_allocation_slow()                                │
│           │                                                                      │
│           ├── 5. 获取 Heap_lock                                                 │
│           ├── 6. 再次尝试分配 (可能其他线程已释放空间)                          │
│           └── 7. 仍失败 → 执行 GC                                               │
│               │                                                                  │
│               ▼                                                                  │
│       G1CollectedHeap::do_collection_pause()                                    │
│           │                                                                      │
│           └── 8. 创建 VM_G1CollectForAllocation                                 │
│               └── VMThread::execute()                                           │
│                   └── SafepointSynchronize::begin()                             │
│                       └── ... GC 执行 ...                                       │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 分配路径详解

### 2.1 TLAB 快速分配

```cpp
// 每个线程有自己的 TLAB (Thread Local Allocation Buffer)
class ThreadLocalAllocBuffer {
    HeapWord* _top;      // 当前分配位置
    HeapWord* _end;      // TLAB 结束位置
    
public:
    // 快速分配：只是移动指针
    inline HeapWord* allocate(size_t size) {
        HeapWord* obj = _top;
        HeapWord* new_top = obj + size;
        if (new_top <= _end) {
            _top = new_top;
            return obj;  // 分配成功
        }
        return NULL;  // TLAB 不足
    }
};
```

**为什么 TLAB 快？**
- 无锁分配（线程本地）
- 只是指针移动（bump-the-pointer）
- 无 GC 检查

### 2.2 TLAB 不足处理

```cpp
// G1CollectedHeap.cpp
HeapWord* G1CollectedHeap::allocate_new_tlab(
    size_t min_size,
    size_t requested_size,
    size_t* actual_size
) {
    // 1. 首先尝试在 Eden 区分配新 TLAB
    HeapWord* result = attempt_allocation(min_size, requested_size, actual_size);
    
    if (result != NULL) {
        return result;  // 成功
    }
    
    // 2. TLAB 分配失败，进入慢路径
    result = attempt_allocation_slow(requested_size);
    
    if (result != NULL) {
        return result;
    }
    
    // 3. 分配失败，返回 NULL（最终会抛出 OOM）
    return NULL;
}
```

### 2.3 慢路径：触发 GC

```cpp
HeapWord* G1CollectedHeap::attempt_allocation_slow(size_t word_size) {
    // 获取堆锁
    MutexLocker ml(Heap_lock);
    
    // 1. 再次尝试分配（可能其他线程已释放空间）
    HeapWord* result = attempt_allocation(word_size);
    if (result != NULL) {
        return result;
    }
    
    // 2. 尝试扩展堆
    if (expand_heap_and_allocate(word_size)) {
        return result;
    }
    
    // 3. ★★★ 触发 GC ★★★
    bool succeeded = false;
    result = do_collection_pause(
        word_size,           // 请求分配的大小
        gc_count_before,     // 当前 GC 计数
        &succeeded,          // GC 是否成功
        GCCause::_g1_inc_collection_pause  // GC 原因
    );
    
    return result;
}
```

---

## 3. GC 触发入口

### 3.1 do_collection_pause()

```cpp
HeapWord* G1CollectedHeap::do_collection_pause(
    size_t word_size,
    uint gc_count_before,
    bool* succeeded,
    GCCause::Cause gc_cause
) {
    // 创建 VM 操作
    VM_G1CollectForAllocation op(
        word_size,
        gc_count_before,
        gc_cause,
        false,  // should_initiate_conc_mark
        g1_policy()->max_pause_time_ms()  // 目标暂停时间
    );
    
    // ★★★ 提交给 VMThread 执行 ★★★
    VMThread::execute(&op);
    
    // 获取结果
    *succeeded = op.pause_succeeded();
    return op.result();
}
```

### 3.2 VMThread 执行 GC

```cpp
void VMThread::loop() {
    // 从队列获取 GC 操作
    VM_Operation* op = _vm_queue->remove_next();
    
    // 开始安全点（STW）
    SafepointSynchronize::begin();
    
    // 执行 GC
    op->evaluate();
    
    // 结束安全点
    SafepointSynchronize::end();
}
```

---

## 4. 触发原因 (GCCause)

| 触发原因 | 说明 | 场景 |
|---------|------|------|
| `_g1_inc_collection_pause` | 增量回收暂停 | Eden 区分配失败 |
| `_g1_humongous_allocation` | 大对象分配 | Humongous 对象分配失败 |
| `_java_lang_system_gc` | System.gc() | 显式调用 |
| `_g1_periodic_collection` | 周期性回收 | 定时触发 |
| `_allocation_failure` | 分配失败 | 其他分配失败 |

---

## 5. 完整调用链

```
Java: new Object()
    │
    ▼
Interpreter: new 字节码
    │
    ▼
TemplateTable::_new()
    │
    ▼
G1CollectedHeap::allocate_new_tlab()
    │
    ├── attempt_allocation()  ← 快速路径
    │       └── 成功 → 返回
    │
    └── attempt_allocation_slow()  ← 慢路径
            │
            ├── 再次尝试分配
            ├── 尝试扩展堆
            │
            └── ★ do_collection_pause() ★
                    │
                    ├── VM_G1CollectForAllocation 创建
                    ├── VMThread::execute()
                    │       │
                    │       ├── SafepointSynchronize::begin()
                    │       ├── VM_G1CollectForAllocation::doit()
                    │       │       │
                    │       │       ├── finalize_collection_set()  ← CSet 选择
                    │       │       ├── evacuate_collection_set()  ← 疏散
                    │       │       └── free_collection_set()      ← 清理
                    │       │
                    │       └── SafepointSynchronize::end()
                    │
                    └── 返回分配结果
```

---

## 6. GDB 验证

### 6.1 断点设置

```gdb
# TLAB 分配
break ThreadLocalAllocBuffer::allocate

# TLAB 不足，进入慢路径
break G1CollectedHeap::attempt_allocation_slow

# GC 触发入口
break G1CollectedHeap::do_collection_pause

# VM 操作执行
break VM_G1CollectForAllocation::doit
```

### 6.2 验证内容

```gdb
# 查看请求分配大小
print word_size

# 查看 GC 原因
print gc_cause

# 查看目标暂停时间
print g1_policy()->max_pause_time_ms()
```

---

## 7. 总结

### 核心要点

1. **分层分配策略**:
   - TLAB（线程本地，最快）
   - Eden 区分配（需要锁）
   - GC 后分配（STW）

2. **GC 触发条件**:
   - TLAB 分配失败
   - Eden 区分配失败
   - 堆扩展失败

3. **安全点机制**:
   - 所有 GC 都在 VMThread 中执行
   - 通过 SafepointSynchronize 暂停 Java 线程

4. **分配与 GC 闭环**:
   ```
   分配失败 → 触发 GC → 回收内存 → 重新分配
   ```

---

## 8. Young GC 快速理解路径完成！

### 已完成模块

| 模块 | 状态 |
|------|------|
| 0.1 触发机制 | ✅ (本文) |
| 1.1 VM 操作 | ✅ |
| 3.1 CSet 选择 | ✅ |
| 4.2 疏散阶段 | ✅ |

### 核心流程串联

```
【触发】分配失败 → attempt_allocation_slow()
    ↓
【提交】do_collection_pause() → VMThread::execute()
    ↓
【STW】SafepointSynchronize::begin()
    ↓
【CSet】finalize_collection_set()  ← Garbage First
    ↓
【疏散】evacuate_collection_set()  ← 对象复制
    ↓
【清理】free_collection_set()
    ↓
【恢复】SafepointSynchronize::end()
    ↓
【分配】返回新分配的对象地址
```

---

## 9. 下一步建议

Young GC 快速理解路径已完成！可以：

### 选项 A: 深入其他 GC 类型
- Mixed GC（老年代回收）
- Full GC（整堆回收）
- Concurrent Mark（并发标记）

### 选项 B: 性能调优实践
- GC 日志分析
- 参数调优
- 内存泄漏排查

### 选项 C: 转向其他子系统
- 类加载机制
- JIT 编译器
- 锁优化

**请问想继续哪个方向？**
