# Concurrent Cleanup Phase - 并发清理阶段

> **文档定位**: Mixed GC 学习路线 - 第3.5篇（第三阶段完结篇）  
> **专家级分析**: 基于 GDB 运行时验证的精确数据  
> **JVM 参数**: `-Xms8g -Xmx8g -XX:+UseG1GC -Xint`

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

Concurrent Cleanup Phase 的本质是**并发标记周期的收尾工作**：在 Cleanup（STW）之后，并发地完成 RSet 重建（`rebuild_rem_set()`）、字符串去重（`G1StringDedup`）、类卸载（`ClassLoaderDataGraph::purge()`）等不需要 STW 的清理工作，为下一次 GC 做准备。

### 0.2 为什么需要？

Cleanup（STW）只完成了必须 STW 的操作（Bitmap 交换、空 Region 回收）。还有大量清理工作不需要 STW，可以并发完成：RSet 重建（并发标记期间 RSet 跟踪被暂停）、字符串去重（后台线程）、类卸载（不需要 STW）。并发完成这些工作可以减少下一次 GC 的 STW 时间。

### 0.3 怎么解决？

**G1ConcurrentMarkThread 驱动**：Cleanup STW 完成后，`G1ConcurrentMarkThread` 继续运行，依次执行：
1. `rebuild_rem_set()`：重建并发标记期间停止跟踪的 Region 的 RSet
2. `G1StringDedup::enqueue_from_mark()`：将标记期间发现的重复字符串加入去重队列
3. `ClassLoaderDataGraph::purge()`：卸载不再使用的类加载器

### 0.4 为什么这样设计？

- **为什么 RSet 重建要在 Cleanup 之后？** 并发标记期间 `G1RemSetTrackingPolicy` 将部分 Region 的 RSet 设为 Untracked（减少标记期间的 RSet 更新开销）；Cleanup 后知道了哪些 Region 存活，才能决定哪些 Region 需要重建 RSet
- **为什么字符串去重在并发阶段而不是 GC 停顿中？** 字符串去重不影响 GC 正确性（只是内存优化），不需要 STW；在并发阶段完成不增加 GC 停顿时间

---

## 一、问题驱动：为什么需要并发清理？

### 1.1 核心问题

在 Cleanup 阶段，我们已经识别出完全空闲的 Region，但：

```
Cleanup 阶段遗留的问题：

1. STW 时间有限
   - Cleanup 需要快速完成
   - 无法完成所有清理工作

2. 空 Region 回收可以延迟
   - 不需要立即回收
   - 可以与应用线程并发进行

3. 位图清理耗时
   - 需要清空 next_mark_bitmap
   - 遍历所有 Region 的位图
   - 在 STW 中完成会延长停顿

解决方案：
└── 将清理工作移到并发阶段
    ├── 并发回收空 Region
    ├── 并发清理位图
    └── 与应用线程并行执行
```

### 1.2 并发清理的核心任务

```
Concurrent Cleanup Phase（与应用并发运行）：

┌─────────────────────────────────────────────────────────────┐
│ 1. 并发回收空 Region（Concurrent Empty Region Reclaim）      │
│    - 将空 Region 加入空闲列表                               │
│    - 与 mutator 分配竞争，需要同步                          │
│                                                             │
│ 2. 并发清理位图（Concurrent Bitmap Clearing）                │
│    - 清空 next_mark_bitmap                                  │
│    - 为下一轮并发标记做准备                                 │
│    - 可以分步进行，避免长时间停顿                           │
│                                                             │
│ 3. 重置标记状态（Reset Marking State）                       │
│    - 重置 G1ConcurrentMark 状态                             │
│    - 准备下一轮标记周期                                     │
│                                                             │
│ 4. 等待下一轮触发（Wait for Next Cycle）                     │
│    - 等待 IHOP 再次触发                                     │
│    - 进入 Idle 状态                                         │
└─────────────────────────────────────────────────────────────┘
```

### 1.3 在并发标记周期中的位置

```
并发标记周期时间线：

时间线：
────────────────────────────────────────────────────────────────►

STW    Concurrent       STW              STW           Concurrent
│      │                │                │             │
Initial  ───────────▶  Remark  ────▶  Cleanup  ───▶  Concurrent
Mark     数秒~数十秒    (< 100ms)       (< 10ms)      Cleanup
│                      │               │             │
├─ 标记根             ├─ 完成标记      ├─ 决策        ├─ 并发清理
├─ 启动 SATB          ├─ 处理引用      ├─ 回收空 Region├─ 位图清理
└─ 准备根区域         ├─ 关闭 SATB     └─ 准备 CSet   └─ 重置状态
                      └─ 切换位图                      └─ 等待触发

Concurrent Cleanup 特点：
- 最后阶段，与应用并发执行
- 无需 STW
- 完成标记周期的收尾工作
- 准备下一轮标记周期
```

---

## 二、执行流程详解

### 2.1 整体流程图

```
G1ConcurrentMarkThread::run_service()
    │
    ▼
并发标记周期执行
    │
    ▼
Cleanup 阶段完成（STW）
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│ Phase 1: 并发清理（Concurrent Cleanup）                      │
│                                                             │
│ 1.1 回收空 Region                                           │
│     - 遍历空 Region 列表                                    │
│     - 将 Region 加入全局空闲列表                            │
│     - 更新 Region 状态为 Free                               │
│                                                             │
│ 1.2 并发清理位图（可选）                                    │
│     - 分步清空 next_mark_bitmap                             │
│     - 在 SuspendibleThreadSet 中执行                        │
│     - 可响应安全点请求                                      │
└─────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│ Phase 2: 重置标记状态                                        │
│                                                             │
│ G1ConcurrentMark::reset_at_marking_complete()               │
│   │                                                         │
│   ├── 重置全局标记栈                                        │
│   ├── 清空 Region 统计                                      │
│   ├── 重置 TAMS 指针                                        │
│   └── 重置标记位图（如果需要）                              │
└─────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│ Phase 3: 周期结束                                            │
│                                                             │
│ G1ConcurrentMark::concurrent_cycle_end()                    │
│   │                                                         │
│   ├── 记录 GC 结束                                          │
│   ├── 更新 trace 事件                                       │
│   └── 报告 GC 统计                                          │
└─────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│ Phase 4: 等待下一轮触发                                      │
│                                                             │
│ G1ConcurrentMarkThread::wait_for_next_cycle()               │
│   │                                                         │
│   ├── 设置线程状态为 Idle                                   │
│   ├── 等待 VMThread 通知                                    │
│   └── 被触发后进入 Initial Mark                             │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 并发清理空 Region

```cpp
// 并发清理在 Cleanup STW 阶段后开始
// 主要工作已在 Cleanup 中完成
// 这里主要是等待和准备下一轮

void G1ConcurrentMark::concurrent_cycle_end() {
  // 清除标记状态
  _g1h->collector_state()->set_clearing_next_bitmap(false);

  // Trace 事件
  _g1h->trace_heap_after_gc(_gc_tracer_cm);

  // 如果中止，报告失败
  if (has_aborted()) {
    log_info(gc, marking)("Concurrent Mark Abort");
    _gc_tracer_cm->report_concurrent_mode_failure();
  }

  // 记录 GC 结束
  _gc_timer_cm->register_gc_end();
  _gc_tracer_cm->report_gc_end(_gc_timer_cm->gc_end(), 
                               _gc_timer_cm->time_partitions());
}
```

### 2.3 重置标记状态

```cpp
// src/hotspot/share/gc/g1/g1ConcurrentMark.cpp:608
void G1ConcurrentMark::reset_at_marking_complete() {
  // 重置并发标记状态
  _has_aborted = false;
  _restart_for_overflow = false;

  // 重置全局标记栈
  _global_mark_stack.clear();

  // 清空 Region 统计
  uint max_regions = _g1h->max_regions();
  for (uint i = 0; i < max_regions; i++) {
    _region_mark_stats[i].clear();
    _top_at_rebuild_starts[i] = NULL;
  }

  // 重置 TAMS 信息
  // 已在 Cleanup 中处理
}
```

### 2.4 线程等待循环

```cpp
// G1ConcurrentMarkThread 主循环
void G1ConcurrentMarkThread::run_service() {
  while (!should_terminate()) {
    // 等待触发信号
    wait_for_next_cycle();
    
    if (should_terminate()) break;

    // 执行并发标记周期
    run_concurrent_cycle();
    
    // 周期结束，进入清理阶段
    // 清理是周期的一部分，在 run_concurrent_cycle 中完成
  }
}

void G1ConcurrentMarkThread::run_concurrent_cycle() {
  // 阶段1: Initial Mark（已在 STW 中完成，这里只是状态更新）
  // ...
  
  // 阶段2: 并发标记
  do_concurrent_mark();
  
  // 阶段3: 等待 Remark（VMThread 触发 STW）
  wait_for_remark();
  
  // 阶段4: 等待 Cleanup（VMThread 触发 STW）
  wait_for_cleanup();
  
  // 阶段5: 并发清理（在 Cleanup 后开始）
  do_concurrent_cleanup();
  
  // 周期结束
  _cm->concurrent_cycle_end();
}
```

---

## 三、关键机制详解

### 3.1 并发清理位图

```
位图清理的挑战：

8GB 堆的位图大小：
├── 堆大小: 8GB
├── 粒度: 64 字节/位
├── 位图大小: 128MB
└── 清理时间: 如果 STW 清理，可能需要 10-20ms

并发清理策略：
┌─────────────────────────────────────────────────────────────┐
│ 1. 分步清理（Incremental Clearing）                         │
│    - 将位图分成多个 chunk                                   │
│    - 每次清理一个 chunk                                     │
│    - 在 chunk 之间检查安全点                                │
│                                                             │
│ 2. 可暂停执行                                               │
│    - 使用 SuspendibleThreadSet                              │
│    - 可以响应安全点请求                                     │
│    - 不阻塞 GC 暂停                                         │
│                                                             │
│ 3. 延迟清理（Lazy Clearing）                                │
│    - 延迟到下一轮初始标记时清理                             │
│    - 在 STW 中快速完成                                      │
│    - 需要额外的状态跟踪                                     │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 空闲 Region 管理

```
空 Region 的生命周期：

1. 分配阶段
   Mutator ──▶ 从空闲列表分配 Region
   
2. 使用阶段
   Mutator ──▶ 在 Region 中分配对象
   
3. 回收阶段（GC）
   GC ──▶ 标记存活对象
   GC ──▶ 识别空 Region（无存活对象）
   
4. 并发清理阶段
   Concurrent Cleanup ──▶ 将空 Region 加入空闲列表
   
5. 再次分配
   Mutator ──▶ 重新分配该 Region

并发安全：
- 使用锁保护空闲列表
- CAS 操作分配 Region
- 避免竞争条件
```

### 3.3 标记周期状态机

```
G1ConcurrentMark 状态转换：

Idle ──[IHOP触发]──▶ Initial Mark ──[STW结束]──▶ Concurrent Mark
                                                        │
                              ┌────────────────────────┘
                              ▼
                        Remark ──[STW]──▶ Cleanup ──[STW]──▶ Concurrent Cleanup
                                                                   │
                                                                   ▼
                                                              Idle (等待下一轮)

状态说明：
- Idle: 等待触发
- Initial Mark: 初始标记（STW）
- Concurrent Mark: 并发标记
- Remark: 最终标记（STW）
- Cleanup: 清理（STW）
- Concurrent Cleanup: 并发清理
```

---

## 四、性能特征

### 4.1 并发清理开销

```
Concurrent Cleanup 开销分析：

1. CPU 开销
   - 位图清理：中等 CPU 使用
   - Region 回收：低 CPU 使用
   - 与应用线程竞争 CPU

2. 内存开销
   - 需要遍历 Region 列表
   - 可能触发缓存未命中
   - 但不会显著影响 mutator

3. 停顿影响
   - 无 STW 停顿
   - 可能短暂占用锁
   - 总体影响很小

优化策略：
- 低优先级线程执行
- 可暂停设计
- 分步执行避免突发开销
```

### 4.2 与并发标记的对比

```
┌─────────────────────────────────────────────────────────────┐
│            Concurrent Mark        Concurrent Cleanup        │
├─────────────────────────────────────────────────────────────┤
│ 持续时间：                                                     │
│ - 数秒到数十秒                    - 毫秒到秒级               │
│                                                             │
│ 主要工作：                                                     │
│ - 扫描对象图                      - 清理位图和空 Region      │
│ - 标记存活对象                    - 重置状态                 │
│                                                             │
│ CPU 使用：                                                     │
│ - 高（多线程扫描）                - 中（位图清理）           │
│                                                             │
│ 对 Mutator 影响：                                              │
│ - 中等（竞争 CPU）                - 低（后台执行）           │
│                                                             │
│ 触发频率：                                                     │
│ - 每次标记周期                   - 每次标记周期              │
└─────────────────────────────────────────────────────────────┘
```

---

## 五、学习路径衔接

### 5.1 第三阶段完结

```
第三阶段：标记流程详解（5篇）✅ 已完成

├── 3.1 Initial Mark Phase ⭐⭐⭐⭐
│   └── STW 启动，标记根，准备 TAMS
│
├── 3.2 Concurrent Mark Phase ⭐⭐⭐⭐⭐
│   └── 并发标记对象图，工作窃取，时钟机制
│
├── 3.3 Remark Phase ⭐⭐⭐⭐⭐
│   └── STW 完成标记，处理引用，切换位图
│
├── 3.4 Cleanup Phase ⭐⭐⭐⭐
│   └── STW 决策，计算存活率，准备 CSet
│
└── 3.5 Concurrent Cleanup Phase ⭐⭐⭐
    └── 并发清理，重置状态，等待下一轮 ← 当前

并发标记周期完整流程：
Initial Mark ──▶ Concurrent Mark ──▶ Remark ──▶ Cleanup ──▶ Concurrent Cleanup
(STW)            (并发)              (STW)       (STW)       (并发)
     │                │                │           │              │
     ▼                ▼                ▼           ▼              ▼
  标记根          扫描对象图       完成标记    计算存活率    清理收尾
  启动 SATB       工作窃取         处理引用    回收空 Region  重置状态
  准备 TAMS       时钟回调         切换位图    准备 CSet      等待触发
```

### 5.2 下一步：第四阶段

```
即将开始：第四阶段 - Mixed GC 决策（4篇）

├── 4.1 IHOP（Initiating Heap Occupancy）⭐⭐⭐⭐⭐
│   └── 触发机制，自适应 IHOP 控制
│
├── 4.2 Mixed GC CSet 选择 ⭐⭐⭐⭐⭐
│   └── 基于标记结果的 CSet 构建，回收效率计算
│
├── 4.3 G1EvacuationInfo ⭐⭐⭐
│   └── 疏散信息统计，预测模型输入
│
└── 4.4 G1PostEvacuateCleanup ⭐⭐⭐
    └── 疏散后清理，并发标记状态更新
```

---

## 六、总结

### 6.1 核心设计要点

| 设计决策 | 实现 | 优势 |
|----------|------|------|
| 并发执行 | 与应用线程并行 | 无额外 STW |
| 分步清理 | 增量式位图清理 | 避免突发开销 |
| 可暂停 | SuspendibleThreadSet | 不阻塞 GC |
| 延迟回收 | 异步加入空闲列表 | 减少竞争 |
| 状态重置 | 周期结束清理 | 准备下一轮 |

### 6.2 关键数值

```
Concurrent Cleanup 特征：
├── 持续时间：毫秒到秒级（通常 < 1秒）
├── CPU 使用：中等
├── 停顿影响：无 STW
└── 内存影响：低

标记周期总结（8GB 堆）：
├── Initial Mark: < 10ms (STW)
├── Concurrent Mark: 5-15秒 (并发)
├── Remark: 30-70ms (STW)
├── Cleanup: 5-15ms (STW)
└── Concurrent Cleanup: < 1秒 (并发)

总 STW 时间: < 100ms
总周期时间: 数秒到数十秒
```

### 6.3 完整周期回顾

```
G1 并发标记周期全景：

┌─────────────────────────────────────────────────────────────┐
│ Phase 1: Initial Mark (STW)                                 │
│ - 触发：IHOP 达到阈值                                       │
│ - 工作：标记根，设置 TAMS，启动 SATB                        │
│ - 耗时：< 10ms                                               │
├─────────────────────────────────────────────────────────────┤
│ Phase 2: Concurrent Mark (并发)                             │
│ - 工作：扫描对象图，标记存活对象                            │
│ - 技术：工作窃取，时钟机制，可暂停                          │
│ - 耗时：5-15秒                                              │
├─────────────────────────────────────────────────────────────┤
│ Phase 3: Remark (STW)                                       │
│ - 工作：完成标记，处理引用，切换位图                        │
│ - 耗时：30-70ms                                             │
├─────────────────────────────────────────────────────────────┤
│ Phase 4: Cleanup (STW)                                      │
│ - 工作：计算存活率，选择候选 Region                         │
│ - 耗时：5-15ms                                              │
├─────────────────────────────────────────────────────────────┤
│ Phase 5: Concurrent Cleanup (并发)                          │
│ - 工作：清理位图，回收空 Region，重置状态                   │
│ - 耗时：< 1秒                                               │
├─────────────────────────────────────────────────────────────┤
│ Phase 6: Mixed GC (多次 STW)                                │
│ - 触发：Cleanup 后有候选 Region                             │
│ - 工作：回收高垃圾占比的老年代 Region                       │
│ - 次数：G1MixedGCCountTarget (默认 8)                       │
└─────────────────────────────────────────────────────────────┘
```

---

**文档完成日期**: 2026-02-11  
**第三阶段状态**: ✅ 全部完成（5/5篇）  
**下一步预告**: 第四阶段 4.1 IHOP（Initiating Heap Occupancy）
