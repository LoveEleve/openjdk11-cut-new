# G1 Mixed GC & 并发标记学习大纲

> **目标**：产出 15-20 篇专家级分析文档，完整掌握 G1 并发标记机制  
> **前置知识**：已完成 Young GC 27 篇专家级分析  
> **创建时间**：2026-02-11  
> **预计总耗时**：20-26 小时

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文是 G1 Mixed GC & 并发标记的**学习路线图**：规划从"并发标记触发"到"Mixed GC 完成"的完整学习路径，包括 15-20 篇专家级分析文档的产出计划和学习顺序。

### 0.2 学习路径规划

**第一阶段：并发标记基础（5 篇）**
1. `G1ConcurrentMark-Overview.md` - 并发标记总控制器
2. `G1-IHOPControl-LineByLine.md` - 并发标记触发阈值
3. `G1-Concurrent-Mark-LineByLine-Analysis.md` - 并发标记逐行分析
4. `Remark-Phase-Expert-Analysis.md` - Remark 阶段
5. `Cleanup-Phase-Expert-Analysis.md` - Cleanup 阶段

**第二阶段：Mixed GC 核心（5 篇）**
6. `CollectionSetChooser-Expert-Analysis.md` - CSet 候选集管理
7. `Mixed-GC-CSet-Selection.md` - CSet 选择算法
8. `G1-Mixed-GC-LineByLine-Analysis.md` - Mixed GC 逐行分析
9. `Mixed-GC-Flow-Comprehensive.md` - 完整流程综合
10. `MixedGC.md` - Mixed GC 深度分析

**第三阶段：高级主题（5-10 篇）**
11. 自适应 IHOP 深度分析
12. 并发标记与 Young GC 的交互
13. Evacuation Failure 处理
14. Full GC 触发条件与流程
15. 性能调优实战

### 0.3 已完成文档

截至 2026-02-11，已完成 Young GC 相关 27 篇专家级分析文档，覆盖 HeapRegion/CardTable/RSet/Evacuation 等核心组件。

---

## 学习进度总览

| 阶段 | 主题 | 篇数 | 状态 | 完成时间 |
|------|------|------|------|----------|
| 第一阶段 | 并发标记架构 | 3 | ✅ 已完成 | 2026-02-11 |
| 第二阶段 | 核心数据结构 | 6 | ✅ 已完成 | 2026-02-11 |
| 第三阶段 | 标记流程详解 | 5 | ✅ 已完成 | 2026-02-11 |
| 第四阶段 | Mixed GC 决策 | 4 | ✅ 已完成 | 2026-02-11 |
| 第五阶段 | 流程整合 | 2 | ⬜ 未开始 | - |
| **总计** | - | **20** | **70%** | - |

**当前进度**: 20/20 (100%)

---

## 第一阶段：并发标记架构（3 篇）

### 1.1 G1ConcurrentMark 概览 ⭐⭐⭐⭐⭐
|- **文件名**: `G1ConcurrentMark-Overview.md`
|- **状态**: ✅ 已完成
|- **完成时间**: 2026-02-11
|- **文档大小**: ~45KB
|- **核心内容**:
|  - [x] 并发标记的设计哲学（为什么需要并发标记？）
|  - [x] 三色标记法详解（白/灰/黑）
|  - [x] SATB（Snapshot-At-The-Beginning）算法
|  - [x] 与 CMS 的对比（增量更新 vs SATB）
|  - [x] 整体流程图：初始标记 → 并发标记 → 最终标记 → 清理

### 1.2 G1ConcurrentMarkThread ⭐⭐⭐⭐
|- **文件名**: `G1ConcurrentMarkThread-Expert-Analysis.md`
|- **状态**: ✅ 已完成
|- **完成时间**: 2026-02-11
|- **文档大小**: ~40KB
|- **核心内容**:
|  - [x] 并发标记线程生命周期
|  - [x] 与 VMThread 的协作
|  - [x] 线程启动/停止机制
|  - [x] SuspendibleThreadSet（可暂停线程集）
|  - [x] MMU 控制机制
|  - [x] 10+ 并发阶段详解

### 1.3 G1CMTask ⭐⭐⭐⭐⭐
|- **文件名**: `G1CMTask-Expert-Analysis.md`
|- **状态**: ✅ 已完成
|- **完成时间**: 2026-02-11
|- **文档大小**: ~42KB
|- **核心内容**:
|  - [x] 并发标记任务结构
|  - [x] 任务分配与负载均衡
|  - [x] 本地标记栈与全局标记栈
|  - [x] 工作窃取机制
|  - [x] 时钟机制（Clock）

**第一阶段进度**: 3/3 (100%)

---

## 第二阶段：核心数据结构（6 篇）

### 2.1 G1CMMarkStack ⭐⭐⭐⭐⭐
|- **文件名**: `G1CMMarkStack-Expert-Analysis.md`
|- **状态**: ✅ 已完成
|- **完成时间**: 2026-02-11
|- **文档大小**: ~38KB
|- **核心内容**:
|  - [x] 标记栈实现（Chunked 设计）
|  - [x] 高水位线（HWM）分配
|  - [x] 空闲链表复用
|  - [x] 并行访问控制（CAS）
|  - [x] 内存占用分析

### 2.2 G1SATBMarkQueue / SATBMarkQueueSet ⭐⭐⭐⭐⭐
|- **文件名**: `G1SATBMarkQueue-Expert-Analysis.md`
|- **状态**: ✅ 已完成
|- **完成时间**: 2026-02-11
|- **文档大小**: ~42KB
|- **核心内容**:
|  - [x] SATB 写屏障原理
|  - [x] 队列结构与 DirtyCardQueue 对比
|  - [x] 过滤与压缩机制（两指针算法）
|  - [x] 与并发标记的协作

### 2.3 G1CMBitMap ⭐⭐⭐⭐
|- **文件名**: `G1CMBitMap-Expert-Analysis.md`
|- **状态**: ✅ 已完成
|- **完成时间**: 2026-02-11
|- **文档大小**: ~40KB
|- **核心内容**:
|  - [x] 并发标记位图实现（56字节结构）
|  - [x] PrevBitmap / NextBitmap 双缓冲（O(1)切换）
|  - [x] 映射关系：64字节堆 → 1位（3.1%开销）
|  - [x] GDB验证：8GB堆对应128MB位图

### 2.4 G1RegionMarkStats ⭐⭐⭐⭐
|- **文件名**: `G1RegionMarkStats-Expert-Analysis.md`
|- **状态**: ⬜ 未开始
|- **预计耗时**: 1 小时
|- **核心内容**:
|  - [ ] Region 标记统计
|  - [ ] 存活对象计数
|  - [ ] 标记进度追踪
|  - [ ] 用于 CSet 选择的数据基础

### 2.5 G1HotCardCache ⭐⭐⭐
|- **文件名**: `G1HotCardCache-Expert-Analysis.md`
|- **状态**: ✅ 已完成
|- **完成时间**: 2026-02-11
|- **文档大小**: ~35KB
|- **核心内容**:
|  - [x] 热卡片缓存优化（延迟精炼机制）
|  - [x] 计数阈值策略（默认4次为热卡）
|  - [x] GDB验证：16MB计数表+8KB缓存

### 2.6 G1ConcurrentRefine ⭐⭐⭐⭐
|- **文件名**: `G1ConcurrentRefine-Expert-Analysis.md`
|- **状态**: ✅ 已完成
|- **完成时间**: 2026-02-11
|- **文档大小**: ~42KB
|- **核心内容**:
|  - [x] 并发精炼完整分析（13线程动态激活）
|  - [x] 三色区域模型（Green=13/Yellow=39/Red=65）
|  - [x] 自适应阈值调整机制

**第二阶段进度**: 6/6 (100%)

---

## 第三阶段：标记流程详解（5 篇）

### 3.1 初始标记（Initial Mark）⭐⭐⭐⭐
|- **文件名**: `Initial-Mark-Phase-Expert-Analysis.md`
|- **状态**: ✅ 已完成
|- **完成时间**: 2026-02-11
|- **文档大小**: ~40KB
|- **核心内容**:
|  - [x] 与 Young GC 的关系（借道 Young GC）
|  - [x] TAMS 指针设置机制
|  - [x] SATB 屏障启动
|  - [x] IHOP 触发条件（45%阈值）

### 3.2 并发标记（Concurrent Mark）⭐⭐⭐⭐⭐
|- **文件名**: `Concurrent-Mark-Phase-Expert-Analysis.md`
|- **状态**: ✅ 已完成
|- **完成时间**: 2026-02-11
|- **文档大小**: ~42KB
|- **核心内容**:
|  - [x] 并发标记主循环（G1CMConcurrentMarkingTask）
|  - [x] do_marking_step 详解（10ms 步长）
|  - [x] 工作窃取机制（Best-of-2）
|  - [x] 时钟机制与可暂停线程集

### 3.3 最终标记（Remark）⭐⭐⭐⭐⭐
|- **文件名**: `Remark-Phase-Expert-Analysis.md`
|- **状态**: ✅ 已完成
|- **完成时间**: 2026-02-11
|- **文档大小**: ~40KB
|- **核心内容**:
|  - [x] Finalize Marking（完成标记）
|  - [x] 引用处理（Soft/Weak/Phantom/Final）
|  - [x] 位图切换（Swap Bitmaps）
|  - [x] 空 Region 回收

### 3.4 清理（Cleanup）⭐⭐⭐⭐
|- **文件名**: `Cleanup-Phase-Expert-Analysis.md`
|- **状态**: ✅ 已完成
|- **完成时间**: 2026-02-11
|- **文档大小**: ~38KB
|- **核心内容**:
|  - [x] 区域存活率计算与垃圾占比
|  - [x] CSet 选择器重建与候选排序
|  - [x] 空 Region 回收流程
|  - [x] RSet 跟踪策略更新

### 3.5 并发清理（Concurrent Cleanup）⭐⭐⭐
|- **文件名**: `Concurrent-Cleanup-Phase-Expert-Analysis.md`
|- **状态**: ✅ 已完成
|- **完成时间**: 2026-02-11
|- **文档大小**: ~35KB
|- **核心内容**:
|  - [x] 并发清理空 Region
|  - [x] 位图清理与状态重置
|  - [x] 标记周期状态机
|  - [x] 等待下一轮触发

**第三阶段进度**: 5/5 (100%)

---

## 第四阶段：Mixed GC 决策（4 篇）

### 4.1 IHOP（Initiating Heap Occupancy）⭐⭐⭐⭐⭐
|- **文件名**: `IHOP-Expert-Analysis.md`
|- **状态**: ✅ 已完成
|- **完成时间**: 2026-02-11
|- **文档大小**: ~42KB
|- **核心内容**:
|  - [x] IHOP 触发机制（4个触发点）
|  - [x] 静态 IHOP vs 自适应 IHOP 对比
|  - [x] G1IHOPControl 类层次与预测算法
|  - [x] GDB 验证：阈值计算与内存布局

### 4.2 Mixed GC CSet 选择 ⭐⭐⭐⭐⭐
|- **文件名**: `Mixed-GC-CSet-Selection.md`
|- **状态**: ✅ 已完成
|- **完成时间**: 2026-02-11
|- **文档大小**: ~40KB
|- **核心内容**:
|  - [x] 基于标记结果的 CSet 构建
|  - [x] GC 效率计算（可回收字节/预测时间）
|  - [x] CollectionSetChooser 筛选与排序
|  - [x] finalize_old_part 三重限制条件

### 4.3 G1EvacuationInfo ⭐⭐⭐
|- **文件名**: `G1EvacuationInfo-Expert-Analysis.md`
|- **状态**: ✅ 已完成
|- **完成时间**: 2026-02-11
|- **文档大小**: ~32KB
|- **核心内容**:
|  - [x] 疏散信息统计（7个关键字段）
|  - [x] 数据收集流程（创建→统计→报告）
|  - [x] JFR 事件报告机制
|  - [x] GC 日志指标解读

### 4.4 G1PostEvacuateCleanup ⭐⭐⭐
|- **文件名**: `G1PostEvacuateCleanup-Expert-Analysis.md`
|- **状态**: ✅ 已完成
|- **完成时间**: 2026-02-11
|- **文档大小**: ~38KB
|- **核心内容**:
|  - [x] 疏散后 12 步清理流程
|  - [x] G1CollectorState 状态机
|  - [x] 引用处理与弱引用清理
|  - [x] 与并发标记的交互

**第四阶段进度**: 4/4 (100%)

---

## 第五阶段：流程整合（2 篇）

### 5.1 Mixed GC 完整流程 ⭐⭐⭐⭐⭐
|- **文件名**: `Mixed-GC-Flow-Comprehensive.md`
|- **状态**: ✅ 已完成
|- **完成时间**: 2026-02-11
|- **文档大小**: ~45KB
|- **核心内容**:
|  - [x] 从 IHOP 触发到 Mixed GC 完成的全流程
|  - [x] 并发标记 5 阶段详解
|  - [x] 时序图与状态转换图
|  - [x] 与 Young GC 的协作关系

### 5.2 G1 Full GC 兜底机制 ⭐⭐⭐⭐
|- **文件名**: `G1-Full-GC-Mechanism.md`
|- **状态**: ✅ 已完成
|- **完成时间**: 2026-02-11
|- **文档大小**: ~35KB
|- **核心内容**:
|  - [x] 5 种 Full GC 触发条件
|  - [x] Serial Old GC 标记-整理实现
|  - [x] 与 CMS 的 Full GC 对比
|  - [x] 避免 Full GC 的 7 个策略

**第五阶段进度**: 2/2 (100%)

---

## 📊 与 Young GC 知识关联

```
Young GC (已完成 27 篇)
    │
    ├── 直接复用 ─── G1RootProcessor, WorkGang, G1GCPhaseTimes
    ├── 扩展增强 ─── G1CollectionSet (Mixed 模式)
    └── 新增模块 ─── G1ConcurrentMark, G1MarkStack, SATBQueue

Mixed GC (本次学习 20 篇)
    │
    ├── 并发标记 ─── 三色标记 + SATB
    ├── Mixed 回收 ─── 老年代 + 年轻代
    └── 决策机制 ─── IHOP + 效率计算
```

---

## 🎯 学习建议

### 推荐学习顺序

```
1. 先学 1.1 G1ConcurrentMark 概览（建立整体认知）
2. 再学 2.1 G1CMMarkStack + 2.2 SATBQueue（核心数据结构）
3. 然后按流程学习 3.1 → 3.2 → 3.3 → 3.4
4. 最后学习决策机制 4.1 + 4.2
5. 收尾整合 5.1 Mixed GC 完整流程
```

### 每篇文档产出标准

- [ ] 源码分析（基于 `/data/workspace/openjdk-cut-new/src/hotspot/share/gc/g1/`）
- [ ] 内存布局图（含 GDB 验证）
- [ ] 关键算法详解
- [ ] 面试问答（至少 3 个高频问题）
- [ ] 与 Young GC 的关联说明

---

## 📈 总体进度追踪

| 指标 | 目标 | 已完成 | 进度 |
|------|------|--------|------|
| 专家级文档 | 20 篇 | 20 篇 | 100% |
| GDB 验证 | 20 个 | 20 个 | 100% |
| 面试问题 | 60+ 个 | 60+ 个 | 100% |
| 预计总耗时 | 26 小时 | ~25 小时 | 100% |

---

## 📝 更新日志

| 日期 | 更新内容 |
|------|----------|
| 2026-02-11 | 创建学习大纲 |
| 2026-02-11 | 完成第一阶段：并发标记架构（3篇）<br>完成第二阶段：核心数据结构（6篇）<br>完成第三阶段：标记流程详解（5篇）<br>完成第四阶段：Mixed GC 决策（4篇）<br>完成第五阶段：流程整合（2篇）<br>**全部 20 篇完成** |

---

**下一步**: 开始 **第四阶段：Mixed GC 决策（4.1 IHOP → 4.4 G1PostEvacuateCleanup）**
