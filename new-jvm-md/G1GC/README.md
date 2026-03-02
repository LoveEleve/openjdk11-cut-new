# G1 GC 逐行深度源码分析 - 重写版

> **重写标准**: 按照Native Libraries最高标准，逐行代码分析 + 面试深度问答 + GDB验证  
> **目标**: 每行代码都有解释，每个概念都有图解，每个问题都有深度回答

---

## 已完成分析

### 1. G1CollectedHeap::initialize() (Lines 1587-2445)

| 文档 | 内容范围 | 行数 | 面试Q&A | GDB脚本 |
|------|----------|------|---------|---------|
| [Part 1](G1CollectedHeap-initialize-LineByLine-Analysis.md) | Lines 1587-1744 | ~150行 | 10个 | 有 |
| [Part 2](G1CollectedHeap-initialize-LineByLine-Analysis-Part2.md) | Lines 1745-2005 | ~260行 | 5个 | 有 |
| [Part 3](G1CollectedHeap-initialize-LineByLine-Analysis-Part3.md) | Lines 2006-2445 | ~240行 | 4个 | 有 |

**核心内容覆盖：**
1. **方法入口与基础验证** - 虚拟时间启用、堆锁获取、HeapWordSize验证
2. **虚拟内存预留** - mmap系统调用、压缩指针优化、ReservedSpace管理
3. **卡表与屏障集** - 512:1映射原理、双屏障机制、全局屏障设置
4. **热卡缓存** - G1HotCardCache原理、阈值调优
5. **6个内存映射器** - heap/bot/cardtable/counts/prev_bm/next_bm
6. **HeapRegionManager** - 2048 Region索引表、可用性位图
7. **G1RemSet** - Remembered Set原理、跨Region引用追踪
8. **BOT** - Block Offset Table、对象起始快速定位
9. **CSet快速测试** - _in_cset_fast_test、O(1)判断优化
10. **最终初始化** - 分配器、验证器、JMX监控、预触摸

### 2. Young GC执行流程

| 文档 | 内容范围 | 面试Q&A | GDB脚本 |
|------|----------|---------|---------|
| [Part 1](G1-Young-GC-LineByLine-Analysis.md) | GC触发到工作线程准备 | 5个 | 有 |
| [Part 2](G1-Young-GC-LineByLine-Analysis-Part2.md) | CSet选择到GC完成 | 1个 | 有 |

**核心内容覆盖：**
1. **GC触发入口** - collect()方法、GC计数器快照
2. **VM操作执行** - VM_G1CollectForAllocation::doit()
3. **并发标记判断** - Initial Mark触发逻辑、IHOP
4. **核心GC执行** - do_collection_pause_at_safepoint
5. **CSet选择** - finalize_collection_set、预测模型
6. **对象复制** - evacuate_collection_set、转发指针
7. **GC后处理** - 引用处理、CSet释放、PLAB调整

### 3. G1Policy与CollectionSet

| 文档 | 内容范围 | 面试Q&A | GDB脚本 |
|------|----------|---------|---------|
| [G1Policy分析](G1Policy-and-CollectionSet-LineByLine-Analysis.md) | 策略决策与CSet选择 | 2个 | 有 |

**核心内容覆盖：**
1. **G1Policy类结构** - 预测组件、IHOP控制、年轻代大小
2. **finalize_collection_set** - 两阶段CSet选择算法
3. **CollectionSetChooser** - 老年代Region回收效率排序
4. **IHOP控制** - calc_min/max_old_cset_length
5. **预测模型** - 衰减平均、各阶段耗时预测

### 4. Concurrent Mark（并发标记）

| 文档 | 内容范围 | 面试Q&A | GDB脚本 |
|------|----------|---------|---------|
| [并发标记分析](G1-Concurrent-Mark-LineByLine-Analysis.md) | Initial Mark到Cleanup完整流程 | 1个 | 有 |

**核心内容覆盖：**
1. **G1ConcurrentMark类结构** - 双缓冲位图、根Region、标记栈
2. **Initial Mark** - pre_initial_mark、post_initial_mark、SATB启用
3. **并发标记** - mark_from_roots、工作窃取、三色标记
4. **Remark** - finalize_marking、引用处理、位图交换
5. **Cleanup** - RSet更新、Mixed GC准备
6. **SATB机制** - 写屏障、漏标防护
7. **三色标记** - 白灰黑、Finger指针

### 5. Mixed GC（空间回收）

| 文档 | 内容范围 | 面试Q&A | GDB脚本 |
|------|----------|---------|---------|
| [Mixed GC分析](G1-Mixed-GC-LineByLine-Analysis.md) | Mixed GC触发到退出完整流程 | 2个 | 有 |

**核心内容覆盖：**
1. **触发条件** - next_gc_should_be_mixed、G1HeapWastePercent
2. **状态转换** - in_mixed_phase、young_gc_pause_kind
3. **CSet选择** - finalize_old_part、回收效率排序
4. **min/max限制** - calc_min/max_old_cset_length
5. **退出条件** - 可回收空间阈值、CSet Chooser为空

### 6. 对象分配（Object Allocation）

| 文档 | 内容范围 | 面试Q&A | GDB脚本 |
|------|----------|---------|---------|
| [对象分配分析](G1-Object-Allocation-LineByLine-Analysis.md) | TLAB、PLAB、分配路径 | 1个 | 有 |

**核心内容覆盖：**
1. **分配入口** - mem_allocate、巨型对象判断
2. **TLAB机制** - Thread Local Allocation Buffer、无锁分配
3. **PLAB机制** - Promotion Local Allocation Buffer、GC线程本地分配
4. **分配失败处理** - attempt_allocation_slow、GC触发
5. **巨型对象** - Humongous Object、连续Region分配

### 7. Full GC（降级Full GC）

| 文档 | 内容范围 | 面试Q&A | GDB脚本 |
|------|----------|---------|---------|
| [Full GC分析](G1-Full-GC-LineByLine-Analysis.md) | 4阶段标记-整理算法 | 1个 | 有 |

**核心内容覆盖：**
1. **触发条件** - 分配失败、巨型对象分配失败、System.gc()
2. **4阶段算法** - Mark、Prepare、Adjust、Compact
3. **G1FullCollector** - 标记器、压缩点、引用处理
4. **堆调整** - Min/MaxHeapFreeRatio

### 8. RemSet（Remembered Set）

| 文档 | 内容范围 | 面试Q&A | GDB脚本 |
|------|----------|---------|---------|
| [RemSet分析](G1-RemSet-LineByLine-Analysis.md) | 跨Region引用追踪 | 2个 | 有 |

**核心内容覆盖：**
1. **设计原理** - 为什么需要RemSet
2. **三层存储** - Coarse Map、Fine Grain、Sparse
3. **写屏障** - 跨Region引用检测
4. **RSet扫描** - Young GC时扫描
5. **并发细化** - 异步更新RSet

**关键数据（8GB堆标准条件）：**
- Region数量: 2048个
- Region大小: 4MB
- 辅助结构总大小: ~320MB（4%堆大小）
- 6个内存映射器协调工作

---

## 分析格式标准

每个章节包含：
1. **源码行** - 精确行号 + 代码
2. **逐行深度解析** - 每行代码的详细解释
3. **调用链追踪** - 从入口到系统调用的完整链路
4. **内存布局图** - ASCII图示数据结构
5. **面试高频问题Q&A** - 3-5个深度问题
6. **GDB验证技巧** - 可执行的调试命令

---

## 下一步计划

按照相同标准继续重写：

1. **HeapRegionManager::initialize()** - Region管理器详细初始化
2. **G1Policy/G1CollectorPolicy** - GC策略与决策中心
3. **Young GC流程** - VM_G1CollectForAllocation完整分析
4. **并发标记** - G1ConcurrentMark初始标记到清理
5. **Mixed GC** - 老年代回收决策与执行
6. **对象分配** - TLAB、PLAB、快速分配路径

---

## 与旧版文档对比

| 对比项 | 旧版文档 | 新版重写 |
|--------|----------|----------|
| 分析粒度 | 函数级/段落级 | 逐行级 |
| 代码引用 | 节选 | 精确行号+完整代码 |
| 面试深度 | 概念解释 | 原理+场景+优化 |
| GDB验证 | 简单示例 | 完整脚本+输出 |
| 图解 | 架构图 | ASCII详细内存布局 |
| 问题覆盖 | 一般 | 19个高频面试题 |

---

**重写完成日期**: 2025-02-12  
**源码版本**: OpenJDK 11  
**标准环境**: -Xms8g -Xmx8g -XX:+UseG1GC
