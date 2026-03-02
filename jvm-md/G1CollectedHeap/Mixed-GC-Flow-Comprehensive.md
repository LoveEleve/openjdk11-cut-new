# Mixed GC 完整流程综合分析

> **文档版本**: v1.0  
> **创建时间**: 2026-02-11  
> **源码版本**: OpenJDK 11  
> **目标**: 整合 Mixed GC 全流程，绘制时序图与状态转换图

---

## 1. 全景概览

### 1.1 Mixed GC 生命周期

```
应用运行 ──────────────────────────────────────────────────────────────►
    │
    │  IHOP 阈值触发 (45% 老年代占用)
    ▼
┌──────────────────────────────────────────────────────────────────────┐
│                        并发标记周期 (Concurrent Mark Cycle)            │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐             │
│  │ Initial Mark │──►│ Concurrent   │──►│   Remark     │             │
│  │   (STW)      │   │    Mark      │   │   (STW)      │             │
│  └──────────────┘   └──────────────┘   └──────┬───────┘             │
│         │                     │                │                      │
│         │  借道 Young GC       │  并发执行      │  SATB 屏障关闭        │
│         │  设置 TAMS           │  10ms/步       │  引用处理             │
│         │  启动 SATB           │  工作窃取      │  位图切换             │
│         ▼                     ▼                ▼                      │
│  ┌──────────────┐   ┌────────────────────────────────────────────┐  │
│  │   Cleanup    │──►│       Concurrent Cleanup                  │  │
│  │   (STW)      │   │        (并发)                             │  │
│  └──────────────┘   └────────────────────────────────────────────┘  │
│       │                                                          │
│       │  计算存活率    重建 CSet Chooser    释放空 Region          │
│       ▼                                                          │
└──────────────────────────────────────────────────────────────────────┘
    │
    │  CSet Chooser 准备就绪
    ▼
┌──────────────────────────────────────────────────────────────────────┐
│                        Mixed GC 执行阶段                               │
│                                                                      │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐   │
│  │   Mixed GC #1    │──►   Mixed GC #2    │──►   Mixed GC #N    │   │
│  │  (Young + Old)   │   │  (Young + Old)   │   │  (Young + Old)   │   │
│  └──────────────────┘  └──────────────────┘  └──────────────────┘   │
│         │                     │                      │               │
│         │ 选择 CSet           │ 选择 CSet            │ 选择 CSet      │
│         │ (GC效率排序)        │ (剩余候选)          │ (最后一批)     │
│         │                     │                      │               │
│         ▼                     ▼                      ▼               │
│   回收 ~10% Region      回收 ~10% Region       回收剩余 Region       │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
    │
    │ 所有候选 Region 回收完成
    ▼
返回 Young Only GC ────────────────────────────────────────────────────►
```

### 1.2 时序图

```
时间轴 ─────────────────────────────────────────────────────────────────────►

应用线程: ──────┬──────┬──────┬────────────────────────┬──────┬──────────►
                │      │      │  ← 并发标记期间运行    │      │
                │      │      │                        │      │
VM 线程:        ▼      ▼      ▼                        ▼      ▼
(GC 暂停)    [Young] [IM]  [Young]─[Young]─[Young]  [Remark] [Mixed]
                │      │      │      │      │            │      │
                │      │      │      │      │            │      │
并发标记线程:   ───────┴──────┴──────────────────────────┴──────┴────────►
                       │←───── Concurrent Mark ─────→│
                       │       (10ms 步长)           │
                       │                             │
                       ▼                             ▼
                 cycle_start                   cycle_end
```

---

## 2. 并发标记周期详解

### 2.1 阶段一：Initial Mark（初始标记）

**触发条件**：IHOP 阈值（45%）达到

```cpp
// g1Policy.cpp:584
bool need_to_start_conc_mark(const char* source, size_t alloc_word_size) {
  size_t marking_initiating_used_threshold = _ihop_control->get_conc_mark_start_threshold();
  size_t cur_used_bytes = _g1h->non_young_capacity_bytes();
  size_t marking_request_bytes = cur_used_bytes + alloc_byte_size;
  
  if (marking_request_bytes > marking_initiating_used_threshold) {
    return collector_state()->in_young_only_phase() && 
           !collector_state()->in_young_gc_before_mixed();
  }
}
```

**执行逻辑**：
```
Young GC Pause (借道)
    │
    ├── 扫描 GC Roots (年轻代 + 老年代)
    │
    ├── 设置 TAMS 指针 (Top At Mark Start)
    │   ├── _prev_top_at_mark_start = top
    │   └── _next_top_at_mark_start = top
    │
    ├── 启动 SATB 写屏障
    │   └── G1SATBMarkQueueSet::set_active_all_threads(true)
    │
    └── 启动并发标记线程
        └── G1ConcurrentMarkThread::run_service()
```

**关键数据结构更新**：
| 字段 | 更新值 | 说明 |
|------|--------|------|
| `_in_initial_mark_gc` | true | 标记是 Initial Mark GC |
| `_mark_or_rebuild_in_progress` | true | 标记周期开始 |
| `_next_top_at_mark_start` | 当前 top | TAMS 边界 |

### 2.2 阶段二：Concurrent Mark（并发标记）

**执行主体**：G1ConcurrentMarkThread

```cpp
// g1ConcurrentMarkThread.cpp:247-399
void G1ConcurrentMarkThread::run_service() {
  _cm->concurrent_cycle_start();
  
  // 1. 并发标记阶段
  _cm->mark_from_roots();
  
  // 2. 等待 Remark 安全点
  for (int i = 0; i < concurrent_remark_attempts; i++) {
    if (!cm()->has_aborted()) {
      VM_G1ConcurrentMark vm_op;
      VMThread::execute(&vm_op);  // 触发 Remark
    }
  }
  
  // 3. 等待 Cleanup
  // ...
  
  _cm->concurrent_cycle_end();
}
```

**并发标记任务**：
```cpp
// g1ConcurrentMark.cpp:2112-2170
void G1CMConcurrentMarkingTask::work(uint worker_id) {
  G1CMTask* task = _cm->task(worker_id);
  
  while (!task->has_aborted()) {
    // 1. 执行标记步 (10ms)
    task->do_marking_step(10.0, true, true);
    
    // 2. 检查是否需要让出 (VMThread 需要 safepoint)
    if (SuspendibleThreadSet::should_yield()) {
      SuspendibleThreadSet::yield();
    }
    
    // 3. 尝试工作窃取
    if (task->steal_and_mark()) {
      continue;
    }
    
    // 4. 处理 SATB 队列
    if (task->drain_satb_buffers()) {
      continue;
    }
    
    // 5. 检查完成
    if (_cm->mark_stack_empty() && !task->has_aborted()) {
      break;
    }
  }
}
```

**三色标记状态**：
```
初始状态: 所有对象 = 白色（未标记）

标记过程:
    GC Roots ──► 灰色队列 (G1CMMarkStack)
                    │
                    ▼
              标记对象 ──► 黑色（已标记）
                    │
                    └── 子对象 ──► 灰色队列
                    
最终: 黑色 = 存活, 白色 = 垃圾
```

### 2.3 阶段三：Remark（最终标记）

**触发时机**：并发标记完成或达到一定阈值

**执行内容**：
```
Remark Pause (STW)
    │
    ├── finalize_marking()
    │   ├── 完成剩余标记工作
    │   └── 处理 SATB 队列中的引用
    │
    ├── weak_refs_work()
    │   ├── 处理 SoftReference
    │   ├── 处理 WeakReference
    │   ├── 处理 PhantomReference
    │   └── 处理 FinalReference
    │
    └── swap_mark_bitmaps()
        ├── _prev_mark_bitmap = _next_mark_bitmap
        ├── _next_mark_bitmap = 新位图
        └── set_clearing_next_bitmap(true)
```

**关键操作**：
- **位图切换**：Prev/Next 位图交换，为 Mixed GC 提供存活数据
- **引用处理**：决定哪些引用对象需要清除
- **SATB 队列清理**：确保所有引用都被处理

### 2.4 阶段四：Cleanup（清理）

**执行内容**：
```
Cleanup Pause (STW)
    │
    ├── 计算每个 Region 的存活率
    │   └── live_bytes = _prev_marked_bytes
    │
    ├── 重建 CollectionSetChooser
    │   ├── 筛选候选 Region (存活率 < 85%)
    │   ├── 计算 GC 效率 (reclaimable_bytes / time)
    │   └── 按效率排序
    │
    ├── 回收完全空的 Region
    │   └── 立即加入空闲列表
    │
    └── 更新全局统计
        └── _summary_bytes_used -= freed_bytes
```

**关键数据结构**：
```cpp
// CollectionSetChooser 状态
_regions: [Region*, Region*, ...]  // 按 GC 效率排序
_front: 0                           // 当前选择位置
_end: N                             // 候选 Region 总数
_remaining_reclaimable_bytes: X     // 总可回收字节
```

### 2.5 阶段五：Concurrent Cleanup（并发清理）

**执行内容**：
```
Concurrent Cleanup (后台线程)
    │
    ├── 并发清理空 Region
    │   └── 已经在上一步完成，这里主要是确认
    │
    ├── 清理 Next 位图
    │   └── clear_bitmap(_next_mark_bitmap)
    │
    └── 重置标记状态
        ├── set_clearing_next_bitmap(false)
        └── set_mark_or_rebuild_in_progress(false)
```

---

## 3. Mixed GC 执行阶段

### 3.1 触发条件

```cpp
// g1Policy.cpp:573-577
bool about_to_start_mixed_phase() const {
  return _g1h->concurrent_mark()->cm_thread()->during_cycle() || 
         collector_state()->in_young_gc_before_mixed();
}
```

**触发时机**：
- Cleanup 完成后第一个 Young GC 自动转为 Mixed GC
- `_in_young_gc_before_mixed = true`

### 3.2 Mixed GC 执行流程

```
Mixed GC Pause
    │
    ├── finalize_collection_set()
    │   ├── finalize_young_part()
    │   │   └── 确定 Eden + Survivor Region 数
    │   │
    │   └── finalize_old_part()
    │       ├── 检查 max_old_cset_length (10% 总 Region)
    │       ├── 检查 reclaimable_percent (> 5%)
    │       ├── 检查 time_remaining_ms
    │       └── 从 CSet Chooser 选择 Region
    │
    ├── pre_evacuate_collection_set()
    │   └── 准备疏散 (重置状态、初始化分配区域)
    │
    ├── evacuate_collection_set()
    │   └── 并行疏散 (G1ParScanThreadState)
    │
    ├── post_evacuate_collection_set()
    │   ├── RSet 清理
    │   ├── 引用处理
    │   ├── 弱引用处理
    │   └── 热卡缓存重置
    │
    └── free_collection_set()
        └── 释放 Region 到空闲列表
```

### 3.3 Mixed GC 的多次执行

```
Mixed GC #1:
    候选 Region: [R100, R95, R90, R85, R80, ...]
    选择: 前 20 个效率最高的
    回收后: [R75, R70, R65, ...] 剩余
    
Mixed GC #2:
    候选 Region: [R75, R70, R65, R60, R55, ...]
    选择: 接下来的 20 个
    回收后: [R50, R45, R40, ...] 剩余
    
Mixed GC #N:
    候选 Region: [R20, R15, R10]
    选择: 剩余所有
    回收后: [] 清空
```

**控制参数**：
- `G1MixedGCCountTarget = 8`：目标在 8 次 GC 内回收完
- `G1HeapWastePercent = 5%`：剩余可回收 < 5% 时停止

---

## 4. 状态转换图

### 4.1 G1CollectorState 状态机

```
                         ┌─────────────────────────────────────┐
                         │                                     │
                         ▼                                     │
┌─────────────┐    Initial    ┌─────────────┐    Remark    ┌────┴────────┐
│ Young Only  │───► Mark GC   │  Concurrent │───► Pause    │ Mixed Phase │
│             │    (STW)      │    Mark     │    (STW)     │             │
└─────────────┘               └─────────────┘              └──────┬──────┘
      ▲                                                           │
      │                                                           │
      │              ┌────────────────────────────────────────────┘
      │              │
      │       Cleanup│Pause (STW)
      │              │
      │              ▼
      │       ┌───────────────┐    Concurrent    ┌──────────┐
      └───────┤  Concurrent   │───► Cleanup      │ Young    │
              │    Cleanup    │    (并发)        │ Only     │
              └───────────────┘                  └──────────┘
```

### 4.2 状态字段变化表

| 阶段 | _in_young_only | _in_young_before_mixed | _mark_or_rebuild | _clearing_next_bitmap |
|------|----------------|------------------------|------------------|----------------------|
| Young GC | true | false | false | false |
| Initial Mark | true | false | **true** | false |
| Concurrent Mark | true | false | true | false |
| Remark | true | false | true | false |
| Cleanup | **false** | **true** | true | false |
| Mixed GC #1 | false | true | true | false |
| Mixed GC #N | false | false | true | **true** |
| Concurrent Cleanup | false | false | **false** | true |
| 结束 | **true** | false | false | **false** |

---

## 5. 关键数据结构流转

### 5.1 CSet Chooser 生命周期

```
Cleanup Phase
    │
    ▼
┌──────────────────┐
│ rebuild()        │
│                  │
│ 1. 遍历所有 Region
│ 2. should_add() 筛选
│ 3. calc_gc_efficiency()
│ 4. sort_regions()
│
│ 结果: _regions[效率排序]
└────────┬─────────┘
         │
         ▼
Mixed GC #1 ──► finalize_old_part() ──► pop() 取走前 N 个
         │
         ▼
Mixed GC #2 ──► finalize_old_part() ──► pop() 取走接下来 N 个
         │
         ▼
         ...
         │
         ▼
Mixed GC #N ──► finalize_old_part() ──► pop() 取走所有剩余
         │
         ▼
    is_empty() == true ──► 恢复 Young Only GC
```

### 5.2 位图生命周期

```
时间 ────────────────────────────────────────────────────────────────►

Prev Bitmap:
[──────────────────────────────────────────────]
 │         │              │            │
 ▼         ▼              ▼            ▼
Initial   Concurrent      Remark      Cleanup    Concurrent
Mark      Mark (使用)    (swap)      (使用)     Cleanup (clear)

Next Bitmap:
[──────────────────────────────────────────────]
 │         │              │            │
 ▼         ▼              ▼            ▼
Initial   Concurrent      Remark      Cleanup    Concurrent
Mark      Mark (使用)    (swap)      (clear)    Cleanup (空)

交换点: Remark Phase 调用 swap_mark_bitmaps()
```

---

## 6. 性能指标与调优

### 6.1 关键监控指标

```bash
# 启用详细日志
java -XX:+UseG1GC -Xlog:gc* YourApp
```

| 指标 | 健康范围 | 诊断命令 |
|------|----------|----------|
| 并发标记时长 | < 堆大小(GB) × 100ms | `-Xlog:gc+mark=debug` |
| IHOP 阈值 | 30-60% | `-Xlog:gc+ihop=debug` |
| Mixed GC 次数 | ≤ G1MixedGCCountTarget | `-Xlog:gc+ergo+cset=debug` |
| 存活率 | < 50% | `-Xlog:gc+liveness=trace` |

### 6.2 常见问题诊断

| 问题 | 症状 | 解决方案 |
|------|------|----------|
| 并发标记过长 | 老年代增长过快，标记跟不上 | 降低 IHOP 阈值 |
| Mixed GC 次数多 | G1MixedGCCountTarget 设置过高 | 降低目标次数 |
| 回收效率低 | 存活率 > 70% | 增加堆大小 |
| 晋升失败 | Evacuation Failure 日志 | 增加 Survivor 空间 |

---

## 7. 面试问答汇总

### Q1: Mixed GC 和 CMS 的并发标记有什么区别？

**答**：

| 特性 | G1 Mixed GC | CMS |
|------|-------------|-----|
| 算法 | SATB (Snapshot-At-The-Beginning) | 增量更新 |
| 写屏障 | 记录旧引用 | 记录新引用 |
| 浮动垃圾 | 新分配对象 | 重新标记后修改的对象 |
| 内存碎片 | 少（Region 整理） | 多（标记清除） |

### Q2: 为什么 Mixed GC 要分多次执行？

**答**：
1. **暂停时间控制**：每次只回收部分老年代 Region，保证 MaxGCPauseMillis
2. **回收效率优先**：先回收垃圾最多的 Region，逐步清理
3. **避免堆抖动**：渐进式回收，避免一次回收导致大量对象晋升

### Q3: 并发标记期间新分配的对象如何处理？

**答**：
- TAMS (Top At Mark Start) 之后分配的对象**不参与**本轮标记
- 这些对象默认被视为**存活**（隐式标记）
- 通过 SATB 屏障确保 TAMS 之前的引用关系被记录

### Q4: 如何完全避免 Full GC？

**答**：
1. 调整 IHOP 阈值：`-XX:InitiatingHeapOccupancyPercent=35`
2. 增加并发标记线程：`-XX:ConcGCThreads=N`
3. 预留更多内存：`-XX:G1ReservePercent=20`
4. 避免大对象：`-XX:G1HeapRegionSize=16M`

---

## 8. 总结

### 8.1 Mixed GC 完整流程总结

```
触发 ──► 并发标记 ──► 候选筛选 ──► 分次回收 ──► 恢复
 │          │           │          │         │
 │          │           │          │         │
IHOP    5个阶段    CSet Chooser  Mixed GC   Young
阈值    STW+并发   按效率排序    多次执行    Only
```

### 8.2 关键设计思想

1. **预测模型驱动**：IHOP 自适应调整，CSet 基于 GC 效率选择
2. **渐进式回收**：Mixed GC 分多次执行，平衡延迟与吞吐量
3. **并发最大化**：标记过程与应用并发，STW 时间最小化
4. **Region 化设计**：细粒度 Region 管理，精确控制回收范围

### 8.3 文档产出统计

| 阶段 | 文档数 | 核心概念 |
|------|--------|----------|
| 并发标记架构 | 3 | 三色标记、SATB、CSet |
| 核心数据结构 | 6 | MarkStack、SATBQueue、Bitmap |
| 标记流程 | 5 | IM/CM/Remark/Cleanup |
| Mixed GC 决策 | 4 | IHOP、CSet选择、疏散 |
| 流程整合 | 2 | 时序图、Full GC |

---

**文档完成时间**: 2026-02-11  
**验证状态**: 综合前面所有文档的分析结果  
**关联文档**: 
- `IHOP-Expert-Analysis.md`（触发机制）
- `Concurrent-Mark-Phase-Expert-Analysis.md`（并发标记）
- `Mixed-GC-CSet-Selection.md`（CSet 选择）
