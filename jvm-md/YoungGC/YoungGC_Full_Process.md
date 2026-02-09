# Young GC 完整执行流程分析

> **源码位置**: `src/hotspot/share/gc/g1/g1CollectedHeap.cpp:3541`
> **重要程度**: ⭐⭐⭐⭐⭐ (G1 GC 核心动态行为)
> **触发条件**: Eden 区分配失败、System.gc()、G1Policy 决定触发

---

## 1. Young GC 整体流程图

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         Young GC 完整执行流程                                      │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  【触发阶段】                                                                     │
│       │                                                                          │
│       ├── 1. 分配失败触发 ──→ G1CollectedHeap::satisfy_failed_allocation()      │
│       ├── 2. System.gc() ──→ G1CollectedHeap::collect()                         │
│       └── 3. G1Policy 决定 ──→ G1Policy::decide_on_conc_mark_initiation()       │
│       │                                                                          │
│       ▼                                                                          │
│  【VMThread 执行】                                                                │
│       VM_G1CollectForAllocation::doit()                                         │
│       │                                                                          │
│       ├── SafepointSynchronize::begin()  ← STW 开始                             │
│       │                                                                          │
│       ▼                                                                          │
│  【GC 核心阶段】                                                                  │
│       G1CollectedHeap::do_collection_pause_at_safepoint()                       │
│       │                                                                          │
│       ├── Phase 1: 准备阶段                                                      │
│       │   ├── note_gc_start()                   记录 GC 开始                     │
│       │   ├── wait_for_root_region_scanning()   等待根区域扫描                    │
│       │   └── decide_on_conc_mark_initiation()  决定是否并发标记                  │
│       │                                                                          │
│       ├── Phase 2: 选择回收集合 (CSet)                                           │
│       │   ├── finalize_collection_set()         确定要回收的 Region               │
│       │   └── register_humongous_regions_with_cset() 注册大对象区域               │
│       │                                                                          │
│       ├── Phase 3: 疏散 (Evacuation) ★★★                                        │
│       │   ├── pre_evacuate_collection_set()     疏散前准备                       │
│       │   ├── evacuate_collection_set()         并行复制存活对象                  │
│       │   │   └── G1ParEvacuateFollowersClosure 工作线程执行                      │
│       │   └── post_evacuate_collection_set()    疏散后处理                       │
│       │                                                                          │
│       ├── Phase 4: 清理                                                            │
│       │   ├── free_collection_set()             释放已回收 Region                 │
│       │   ├── eagerly_reclaim_humongous_regions() 回收大对象                      │
│       │   └── start_new_collection_set()        启动新回收集合                    │
│       │                                                                          │
│       └── Phase 5: 收尾                                                            │
│           ├── gc_epilogue()                     GC 结束处理                       │
│           └── start_concurrent_mark_if_needed() 启动并发标记（如果需要）          │
│       │                                                                          │
│       ▼                                                                          │
│       SafepointSynchronize::end()  ← STW 结束                                    │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 触发阶段详解

### 2.1 三种触发方式

| 触发方式 | 入口函数 | 典型场景 |
|---------|---------|---------|
| **分配失败** | `satisfy_failed_allocation()` | Eden + Survivor 都无法分配 |
| **System.gc()** | `collect()` | 显式调用或 RMI 触发 |
| **G1Policy 触发** | `decide_on_conc_mark_initiation()` | 定时或老年代占比达标 |

### 2.2 分配失败触发流程

```cpp
// G1CollectedHeap.cpp:3238
HeapWord* G1CollectedHeap::do_collection_pause(
    size_t word_size,           // 请求分配的大小
    uint gc_count_before,       // GC 次数（用于检查是否有其他 GC 发生）
    bool* succeeded,
    GCCause::Cause gc_cause     // GC 原因
) {
    // 创建 VM 操作
    VM_G1CollectForAllocation op(
        word_size,
        gc_count_before,
        gc_cause,
        false,                  // should_initiate_conc_mark
        g1_policy()->max_pause_time_ms()  // 目标暂停时间
    );
    
    // 提交给 VMThread 执行
    VMThread::execute(&op);
    
    // 返回结果
    *succeeded = op.pause_succeeded();
    return op.result();
}
```

---

## 3. GC 核心阶段详解

### 3.1 Phase 1: 准备阶段

```cpp
bool G1CollectedHeap::do_collection_pause_at_safepoint(
    double target_pause_time_ms
) {
    // 1. 记录 GC 开始时间
    _gc_timer_stw->register_gc_start();
    
    // 2. 等待根区域扫描完成（并发标记相关）
    wait_for_root_region_scanning();
    
    // 3. 决定是否启动并发标记
    // 如果是初始