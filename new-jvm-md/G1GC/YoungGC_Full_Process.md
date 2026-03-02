# Young GC 完整执行流程分析

> **源码位置**: `src/hotspot/share/gc/g1/g1CollectedHeap.cpp:3541`
> **重要程度**: ⭐⭐⭐⭐⭐ (G1 GC 核心动态行为)
> **触发条件**: Eden 区分配失败、System.gc()、G1Policy 决定触发

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文是 G1 Young GC 完整执行流程的**深度分析**，聚焦于 `do_collection_pause_at_safepoint()` 的完整执行路径：从 SafePoint 建立到 GC 完成，覆盖 Pre-Evacuate/Evacuate/Post-Evacuate 三个主要阶段的所有关键函数调用。

### 0.2 三阶段详解

**Pre-Evacuate（GC 前准备）**：
- `update_rem_set()`：处理所有残留脏卡，确保 RSet 完整
- `finalize_collection_set()`：构建 CSet（所有 Young Region + Mixed GC 时的 Old Region）
- `clear_collection_set_survivors()`：清除上次 GC 的 Survivor 信息

**Evacuate（对象复制）**：
- `evacuate_roots()`：扫描 GC Roots，将直接可达对象复制到 Survivor/Old
- `G1ParEvacuateFollowersClosure`：传递闭包，递归复制所有可达对象
- Work Stealing：GC Worker 之间的负载均衡

**Post-Evacuate（GC 后清理）**：
- `free_collection_set()`：释放 CSet Region，加入 Free List
- `redirty_logged_cards()`：重新标记 Evacuation 产生的新跨 Region 引用
- `record_collection_pause_end()`：更新 G1Policy 预测模型

### 0.3 关键源码位置

| 函数 | 源码位置 | 作用 |
|------|---------|------|
| `do_collection_pause_at_safepoint` | `g1CollectedHeap.cpp:3541` | Young GC 主入口 |
| `evacuate_collection_set` | `g1CollectedHeap.cpp:4789` | Evacuation 主函数 |
| `post_evacuate_collection_set` | `g1CollectedHeap.cpp:5100` | Post-Evacuate 主函数 |

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