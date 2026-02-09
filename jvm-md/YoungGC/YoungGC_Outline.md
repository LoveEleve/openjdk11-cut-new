# Young GC 详细分析大纲

> **说明**: Young GC 是一个复杂的多阶段过程，本大纲将完整流程分解为可独立分析的子模块。
> **状态标记**: ⬜ 未分析 | 🟡 部分分析 | ✅ 已完成

---

## 0. 触发机制 (GC Trigger)

### 0.1 分配失败触发 ⬜
- `G1CollectedHeap::satisfy_failed_allocation()`
- TLAB 分配失败流程
- Eden 区分配失败流程
- Humongous 对象分配

### 0.2 显式 GC 触发 ⬜
- `System.gc()` 调用链
- `Runtime.getRuntime().gc()`
- RMI GC 触发

### 0.3 G1Policy 自动触发 ⬜
- `G1Policy::decide_on_conc_mark_initiation()`
- 定时触发 (`GuaranteedSafepointInterval`)
- 老年代占比触发 (`InitiatingHeapOccupancyPercent`)
- 预测模型 (`G1Analytics`)

---

## 1. VM 操作提交 (VM Operation)

### 1.1 VM_G1CollectForAllocation ⬜
- 类结构分析
- `doit()` 方法流程
- `doit_prologue()` / `doit_epilogue()`

### 1.2 VMThread 执行流程 ✅
- VMOperationQueue 获取操作
- Safepoint 协调 (已分析)

---

## 2. GC 准备阶段 (Preparation)

### 2.1 GC 启动标记 ⬜
- `_gc_timer_stw->register_gc_start()`
- `_gc_tracer_stw->report_gc_start()`
- GC ID 分配 (`GCIdMark`)

### 2.2 根区域扫描等待 ⬜
- `wait_for_root_region_scanning()`
- 并发标记交互
- Root Region 概念

### 2.3 GC 类型决策 ⬜
- **Normal Young GC**: 纯 Young 区回收
- **Initial Mark**: 初始标记（附带 Young GC）
- **Prepare Mixed**: 准备混合回收
- **Mixed GC**: 混合回收（Young + Old）

---

## 3. 回收集合选择 (Collection Set Selection) ⭐⭐⭐

### 3.1 CSet 构建流程 ⬜
- `finalize_collection_set()`
- `G1CollectionSet` 类分析
- CSet 候选 Region 选择

### 3.2 Eden 区选择 ⬜
- `_eden` 链表遍历
- Eden Region 标记为 CSet

### 3.3 Survivor 区处理 ⬜
- `_survivor` 链表处理
- `transfer_survivors_to_cset()`

### 3.4 Old 区选择 (Mixed GC) ⬜
- 回收效率排序 (`reclaimable_bytes / gc_effort`)
- `G1CollectionSetCandidates`
- 暂停时间预测

### 3.5 Humongous 区处理 ⬜
- `register_humongous_regions_with_cset()`
- 大对象回收策略
- `eagerly_reclaim_humongous_regions()`

---

## 4. 疏散阶段 (Evacuation) ⭐⭐⭐⭐⭐

### 4.1 疏散前准备 ⬜
- `pre_evacuate_collection_set()`
- GC 分配区域初始化 (`init_gc_alloc_regions`)
- 线程状态初始化 (`G1ParScanThreadStateSet`)

### 4.2 并行疏散执行 ⬜
- `evacuate_collection_set()`
- `G1ParEvacuateFollowersClosure`
- Work Gang 并行执行
- **对象复制核心逻辑**:
  - `G1ParScanThreadState::copy_to_survivor_space()`
  - 转发指针 (Forwarding Pointer)
  - CAS 原子更新

### 4.3 引用处理 ⬜
- 软引用 (`SoftReference`)
- 弱引用 (`WeakReference`)
- 虚引用 (`PhantomReference`)
- 终结器 (`FinalReference`)
- `_ref_processor_stw`

### 4.4 疏散后处理 ⬜
- `post_evacuate_collection_set()`
- 存活对象统计
- PLAB 调整 (`adjust_desired_plab_sz`)

---

## 5. 清理阶段 (Cleanup)

### 5.1 CSet 释放 ⬜
- `free_collection_set()`
- Region 清空 (`HeapRegion::hr_clear`)
- 内存回收

### 5.2 大对象回收 ⬜
- `eagerly_reclaim_humongous_regions()`
- 快速回收条件

### 5.3 新 CSet 启动 ⬜
- `start_new_collection_set()`
- Eden 区重新分配
- Survivor 区更新

---

## 6. GC 收尾阶段 (Finalization)

### 6.1 GC 结束标记 ⬜
- `gc_epilogue()`
- `_gc_timer_stw->register_gc_end()`
- GC 日志输出

### 6.2 并发标记启动 ⬜
- `start_concurrent_mark_if_needed()`
- `G1ConcurrentMarkThread` 唤醒
- 并发标记阶段转换

### 6.3 元数据更新 ⬜
- `G1Policy` 更新统计
- `G1Analytics` 学习数据
- 下次 GC 预测调整

---

## 7. 关键数据结构

### 7.1 G1CollectionSet ⬜
- 内部 Region 列表
- 年轻代/老年代分区

### 7.2 G1ParScanThreadState ⬜
- 线程本地分配缓冲区 (PLAB)
- 对象复制队列
- 存活对象统计

### 7.3 Remembered Set (RemSet) ⬜
- `G1BlockOffsetTable`
- `PerRegionTable`
- 跨 Region 引用追踪

---

## 8. 性能相关

### 8.1 暂停时间控制 ⬜
- `target_pause_time_ms`
- `G1Policy` 预测模型
- CSet 大小动态调整

### 8.2 并行度控制 ⬜
- `active_workers` 计算
- `G1ParTask` 任务分配
- 工作窃取机制

### 8.3 PLAB 优化 ⬜
- PLAB 大小计算
- 线程本地分配
- 减少竞争

---

## 建议学习路径

### 路径 A: 核心流程快速理解
```
0.1 分配失败触发 → 1.1 VM_G1CollectForAllocation → 3.1 CSet 构建 → 4.2 并行疏散
```

### 路径 B: 深入疏散机制 (最复杂)
```
4.1 疏散前准备 → 4.2 并行疏散执行 → 4.3 引用处理 → 4.4 疏散后处理
```

### 路径 C: G1 决策逻辑
```
0.3 G1Policy 自动触发 → 3.1 CSet 构建 → 3.4 Old 区选择 → 8.1 暂停时间控制
```

---

## 文档状态

| 模块 | 进度 | 优先级 |
|------|------|--------|
| 触发机制 | ⬜ | ⭐⭐⭐ |
| VM 操作 | 🟡 | ⭐⭐⭐ |
| GC 准备 | ⬜ | ⭐⭐ |
| CSet 选择 | ⬜ | ⭐⭐⭐⭐ |
| **疏散阶段** | ⬜ | ⭐⭐⭐⭐⭐ |
| 清理阶段 | ⬜ | ⭐⭐⭐ |
| GC 收尾 | ⬜ | ⭐⭐⭐ |
| 数据结构 | ⬜ | ⭐⭐⭐⭐ |
| 性能优化 | ⬜ | ⭐⭐⭐ |

**当前状态**: 大纲完成，等待选择子模块深入分析
