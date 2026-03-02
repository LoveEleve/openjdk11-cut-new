# G1 GC 专家级补完计划

> **目标**：将现有 10153 行 / 11 篇文档补充到 JVM 专家（Committer）级别
> **标准**：G1 GC 195 个源文件中，每个关键方法都有逐行级源码分析 + GDB 验证
> **当前覆盖率**：~75-80% → 目标 100%

---

## 一、现有文档总览

| # | 文档 | 行数 | 核心覆盖 |
|---|------|------|---------|
| 0 | 数据结构全景 | 877 | 类/字段列表（无方法分析） |
| 1 | HeapRegion | 720 | ✅ 字段完整 |
| 2 | HeapRegionManager | 753 | ✅ 字段+流程完整 |
| 3 | 对象分配路径 | 996 | ✅ TLAB→CAS→Lock→GC 全链路 |
| 4 | 写屏障+CardTable | 854 | ✅ Pre/Post barrier (C++ 解释器层) |
| 5 | RSet 三级结构 | 648 | ✅ Sparse/Fine/Coarse |
| 6 | 并发精化 | 1023 | ✅ 级联激活+refine_card |
| 7 | G1Policy+预测模型 | 1250 | ✅ EWMA+二分搜索+IHOP |
| 8 | 并发标记 | 1128 | ✅ 5 阶段+SATB+finger |
| 9 | CSet+Evacuation | 1165 | ✅ 增量构建+copy_to_survivor |
| 10 | Full GC | 739 | ✅ 4 阶段 Mark-Compact |

**总计 10153 行，覆盖了全部 8 个核心子系统的骨架和关键方法。**

---

## 二、缺口分析：7 大类 21 个待补充主题

### A 类：核心流程的深层方法（已有文档中提到但未逐行分析的方法）

| 编号 | 主题 | 现状 | 涉及源文件 | 源码行数 | 补入文档 |
|------|------|------|-----------|---------|---------|
| A1 | **Young GC 完整 STW 流程** — `do_collection_pause_at_safepoint()` 从头到尾逐行 | #9 只有阶段概览 | g1CollectedHeap.cpp:2811-3200 | ~400 行 | 新建 #11 |
| A2 | **post_evacuate_collection_set()** 所有子步骤逐行 | #9 仅列标题 | g1CollectedHeap.cpp:3300-3550 | ~250 行 | 并入 #11 |
| A3 | **G1RemSet::scan_rem_set()** + G1ScanRSForRegionClosure 逐行 | #9 仅一段描述 | g1RemSet.cpp 核心 300 行 | ~300 行 | 新建 #12 |
| A4 | **Evacuation Failure 完整处理** — `G1ParRemoveSelfForwardPtrsTask` 逐行 | #9 仅概述 | g1EvacFailure.cpp:262 行 | 262 行 | 并入 #11 |
| A5 | **do_marking_step() 逐行** — 并发标记核心 420 行 | #8 有 6 Phase 划分但不够细 | g1ConcurrentMark.cpp:2700-3120 | ~420 行 | 增补 #8 |
| A6 | **Cleanup 阶段逐行** — rebuild + sort + 统计 | #8 有骨架 | g1ConcurrentMark.cpp:1500-1700 | ~200 行 | 增补 #8 |

### B 类：JIT/汇编级写屏障（全新主题）

| 编号 | 主题 | 现状 | 涉及源文件 | 源码行数 | 补入文档 |
|------|------|------|-----------|---------|---------|
| B1 | **x86 汇编级屏障** — 解释器 + MacroAssembler 级别的 pre/post barrier 生成 | 完全未覆盖 | g1BarrierSetAssembler_x86.cpp | 599 行 | 新建 #13 |
| B2 | **C1 JIT 屏障** — LIR 级别 G1 屏障生成 | 完全未覆盖 | c1/g1BarrierSetC1.cpp + .hpp | 365 行 | 并入 #13 |
| B3 | **C2 JIT 屏障** — Ideal Graph 级别 G1 屏障节点 + 优化 | 完全未覆盖 | c2/g1BarrierSetC2.cpp + .hpp | 867 行 | 并入 #13 |
| B4 | **G1BarrierSetRuntime** — slow-path JRT 入口 | 未独立分析 | g1BarrierSetRuntime.cpp/hpp | 111 行 | 并入 #13 |

### C 类：SafePoint + VM Operation（跨模块交互）

| 编号 | 主题 | 现状 | 涉及源文件 | 源码行数 | 补入文档 |
|------|------|------|-----------|---------|---------|
| C1 | **SafePoint 机制** — begin/end/轮询页/线程状态同步 | 完全未覆盖 | safepoint.cpp + safepointMechanism.* | ~1775 行 | 新建 #14 |
| C2 | **VM Operation 调度** — VMThread 如何执行 GC 操作 | 完全未覆盖 | vm_operations_g1.cpp + vmOperations.* | ~850 行 | 并入 #14 |

### D 类：引用处理框架（跨 GC 共享）

| 编号 | 主题 | 现状 | 涉及源文件 | 源码行数 | 补入文档 |
|------|------|------|-----------|---------|---------|
| D1 | **ReferenceProcessor** — Soft/Weak/Final/Phantom 四阶段处理 | #9/#10 仅提触发点 | referenceProcessor.hpp/cpp | ~1200 行 | 新建 #15 |
| D2 | **WeakProcessor** — VM 内部弱引用容器清理 | 仅提名字 | weakProcessor.hpp/cpp | ~100 行 | 并入 #15 |

### E 类：策略与自适应调整（补充深度）

| 编号 | 主题 | 现状 | 涉及源文件 | 源码行数 | 补入文档 |
|------|------|------|-----------|---------|---------|
| E1 | **堆大小动态调整** — 扩容/缩容策略 | 完全未覆盖 | g1HeapSizingPolicy.cpp + g1CollectedHeap.cpp 相关段 | ~250 行 | 新建 #16 |
| E2 | **SurvRateGroup** — 存活率预测 + 累积存活率 | 仅提字段 | survRateGroup.hpp/cpp | ~213 行 | 并入 #16 |
| E3 | **G1YoungRemSetSamplingThread** — RS 采样 + 年轻代动态调整 | 仅提名字 | g1YoungRemSetSamplingThread.cpp | ~122 行 | 并入 #16 |
| E4 | **G1CollectorState 状态机** — 完整状态转换图 | 仅提字段 | g1CollectorState.hpp | 127 行 | 并入 #16 |
| E5 | **G1RemSetTrackingPolicy** — RS 跟踪状态管理 | 完全未覆盖 | g1RemSetTrackingPolicy.cpp | 178 行 | 并入 #16 |

### F 类：辅助功能（补齐完整性）

| 编号 | 主题 | 现状 | 涉及源文件 | 源码行数 | 补入文档 |
|------|------|------|-----------|---------|---------|
| F1 | **BlockOffsetTable** — 对象查找 + 阈值更新逻辑 | 未独立分析 | g1BlockOffsetTable.hpp/inline/cpp | ~830 行 | 新建 #17 |
| F2 | **G1GCPhaseTimes** — GC 日志输出框架 + 日志解读 | 未独立分析 | g1GCPhaseTimes.hpp/cpp | ~1000 行 | 并入 #17 |
| F3 | **字符串去重** — 候选选择 + 去重表 + 去重线程 | 未独立分析 | g1StringDedup*.hpp/cpp | ~400 行 | 并入 #17 |
| F4 | **G1HRPrinter + G1HeapVerifier** — 调试与验证 | 未独立分析 | g1HRPrinter.hpp + g1HeapVerifier.* | ~350 行 | 并入 #17 |

### G 类：GC 日志实战对照（全新维度）

| 编号 | 主题 | 现状 | 涉及源文件 | 补入文档 |
|------|------|------|-----------|---------|
| G1 | **GC 日志完整解读** — 每一行 GC 日志对应哪行源码 | 散落各篇，不系统 | g1GCPhaseTimes.cpp + 各处 log | 新建 #18 |
| G2 | **关键参数调优实验** — 调参 vs 行为变化的量化验证 | 完全没有 | 运行时实验 | 并入 #18 |

---

## 三、新文档编排

| 新编号 | 标题 | 内容 | 涉及缺口 | 预估行数 |
|--------|------|------|---------|---------|
| **#11** | **Young GC 完整 STW 流程** | do_collection_pause_at_safepoint 逐行 + post_evacuate 逐行 + Evacuation Failure 处理 | A1, A2, A4 | ~1200 |
| **#12** | **G1RemSet 完整流程** | scan_rem_set + G1ScanRSForRegionClosure + update_rem_set + rebuild_rem_set 逐行 | A3 | ~800 |
| **#13** | **写屏障汇编级全链路** | 解释器 x86 生成 + C1 LIR + C2 Ideal + BarrierSetRuntime slow-path | B1-B4 | ~1500 |
| **#14** | **SafePoint + VM Operation** | SafePoint begin/end/轮询页 + VMThread 调度 + G1 VM Operations | C1-C2 | ~1200 |
| **#15** | **引用处理全链路** | ReferenceProcessor 四阶段 + WeakProcessor + G1 集成 | D1-D2 | ~800 |
| **#16** | **策略与自适应调整** | 堆 resize + SurvRateGroup + RS 采样 + CollectorState + RS Tracking | E1-E5 | ~1000 |
| **#17** | **辅助子系统** | BOT + GCPhaseTimes + StringDedup + HRPrinter + HeapVerifier | F1-F4 | ~1000 |
| **#18** | **GC 日志实战** | 日志每行对应源码 + 关键参数调优实验 | G1-G2 | ~600 |
| **增补 #8** | 并发标记增补 | do_marking_step 逐行 + Cleanup 逐行 | A5-A6 | +600 |

---

## 四、攻破顺序

```
Phase 1：核心流程深化（最高优先级）
  ├─ #11 Young GC 完整 STW 流程     ← 这是 G1 最高频的操作！
  ├─ #12 G1RemSet 完整流程            ← Evacuation 依赖 RemSet
  └─ 增补 #8 并发标记逐行增补

Phase 2：跨模块交互（理解 GC 如何被触发和执行）
  ├─ #14 SafePoint + VM Operation    ← GC 的"操控台"
  └─ #15 引用处理全链路               ← GC 后的"善后工作"

Phase 3：JIT 级写屏障（理解应用线程的真实路径）
  └─ #13 写屏障汇编级全链路           ← 最硬核的部分

Phase 4：策略与调优
  ├─ #16 策略与自适应调整             ← 连接"数据"和"决策"
  └─ #18 GC 日志实战                 ← 从日志反推源码

Phase 5：补齐完整性
  └─ #17 辅助子系统                  ← BOT/StringDedup/Verifier
```

---

## 五、完成标准

每篇文档必须包含：
- [ ] 完整源码文件列表（涉及的所有 .hpp/.cpp）
- [ ] 每个关键方法的**逐行分析**（不是伪代码，是实际源码引用）
- [ ] 所有关键数据结构的 sizeof + GDB 验证
- [ ] 至少一个 Mermaid 流程图
- [ ] JVM 参数说明 + 日志输出示例
- [ ] GDB 验证脚本 + 运行结果

---

## 六、量化目标

| 指标 | 当前 | 目标 |
|------|------|------|
| 文档篇数 | 11 | 19（+8 新建, 增补 #8） |
| 总行数 | 10,153 | ~18,800（+8,650） |
| 覆盖源文件数 | ~80 / 195 | ~160 / 195（82%） |
| 逐行分析的方法数 | ~120 | ~250+ |
| GDB 验证脚本 | 10 | 19 |
| 未覆盖文件（仅辅助/统计/事件） | - | ~35（g1HeapRegionEventSender, g1MemoryPool 等纯工具类） |

**注**：剩余 ~35 个未覆盖文件均为纯辅助/事件通知/JMX 集成类，无核心 GC 逻辑，不影响专家级定位。

---

## 七、各篇详细大纲

### #11 Young GC 完整 STW 流程

```
1. do_collection_pause_at_safepoint() 逐行
   1.1 进入准备（STW 确认、GC cause、timing）
   1.2 decide_on_conc_mark_initiation()
   1.3 pre_evacuate_collection_set()
     - 禁用 hot card cache
     - 选择 CSet（finalize_young_part + finalize_old_part）
     - choose_collection_set()
     - 记录 collection set regions
   1.4 evacuate_collection_set()
     - G1ParTask 创建与执行
     - evacuate_roots()
     - process_discovered_references (如果 Initial Mark)
   1.5 post_evacuate_collection_set() — 所有子步骤逐行
     - process_discovered_references（非 Initial Mark）
     - enqueue_discovered_references()
     - merge_per_thread_state_info()
     - clear dirty card queue
     - redirty logged cards
     - free_collection_set()
     - eagerly_reclaim_humongous_regions()
     - record_collection_pause_end()
     - expand_heap_after_young_collection()
     - resign/retire GC alloc regions
   1.6 Evacuation Failure 处理 — G1ParRemoveSelfForwardPtrsTask 逐行
     - RemoveSelfForwardPtrObjClosure
     - 恢复 mark word
     - 更新 BOT
     - 用 filler 填充死对象
   1.7 GDB 验证：完整 Young GC 断点追踪
```

### #12 G1RemSet 完整流程

```
1. G1RemSet 类结构与字段
2. scan_rem_set() 完整流程
   2.1 G1ScanRSForRegionClosure 逐行
   2.2 scan_card() — 扫描单张卡
   2.3 scan_strong_code_roots()
3. update_rem_set() 流程
   3.1 G1RefineCardClosure
   3.2 process_card_during_evacuation
4. rebuild_rem_set_concurrently()
   4.1 G1RebuildRemSetClosure
   4.2 与并发标记的协作
5. G1CodeCacheRemSet — nmethod 根追踪
   5.1 add/remove 逻辑
   5.2 与 CodeCache 的交互
6. GDB 验证
```

### #13 写屏障汇编级全链路

```
1. 写屏障执行层次总览
   解释器 → C1 JIT → C2 JIT → Runtime slow-path
2. 解释器级（x86 MacroAssembler）
   2.1 g1_write_barrier_pre() — x86 汇编逐指令分析
   2.2 g1_write_barrier_post() — x86 汇编逐指令分析
   2.3 resolve_jobject() 中的屏障
3. C1 JIT 级
   3.1 G1BarrierSetC1::pre_barrier / post_barrier
   3.2 G1PreBarrierStub / G1PostBarrierStub — LIR 代码生成
   3.3 生成的机器码示例（反汇编）
4. C2 JIT 级
   4.1 G1BarrierSetC2 Ideal Graph 节点
   4.2 pre/post barrier 的图优化
   4.3 生成的机器码示例（反汇编）
5. G1BarrierSetRuntime — slow-path 入口
   5.1 write_ref_field_pre_entry()
   5.2 write_ref_field_post_entry()
6. 三层生成代码的对比
7. GDB 验证：在实际运行中观察各层写屏障
```

### #14 SafePoint + VM Operation

```
1. SafePoint 解决什么问题
2. SafepointSynchronize::begin() 逐行
   2.1 通知所有线程
   2.2 轮询页机制（polling page）
   2.3 线程状态分类与同步策略
   2.4 等待所有线程到达
3. SafepointSynchronize::end() 逐行
4. SafepointMechanism
   4.1 全局轮询 vs 线程局部轮询
   4.2 arm/disarm
5. 线程如何感知 SafePoint
   5.1 解释器中的 SafePoint check
   5.2 JIT 中的 SafePoint poll
   5.3 native 线程的处理
6. VM Operation 框架
   6.1 VMThread 主循环
   6.2 VM_Operation 子类体系
7. G1 VM Operations
   7.1 VM_G1CollectForAllocation — Young GC 入口
   7.2 VM_G1CollectFull — Full GC 入口
   7.3 VM_CGC_Operation — 并发标记 STW 操作
8. 完整调用链：分配失败 → VM Operation → SafePoint → GC → 恢复
9. GDB 验证
```

### #15 引用处理全链路

```
1. Java 四种引用类型回顾
2. ReferenceProcessor 类结构
   2.1 discovered_refs 数组
   2.2 多线程发现 vs 单线程发现
3. 引用发现（Discovery）
   3.1 discover_reference() 在 GC 中的调用点
   3.2 发现条件判断
4. 引用处理四阶段
   4.1 Phase 1: 软引用策略评估
   4.2 Phase 2: 丢弃存活引用 + 清理/入队
   4.3 Phase 3: Final 引用传递闭包
   4.4 Phase 4: Phantom 引用处理
5. G1 中的引用处理集成
   5.1 Young GC 中的引用处理
   5.2 并发标记 Remark 中的引用处理
   5.3 Full GC 中的引用处理
6. WeakProcessor
   6.1 weak_oops_do() 清理流程
   6.2 注册机制
7. GDB 验证
```

### #16 策略与自适应调整

```
1. G1CollectorState 完整状态机
   1.1 所有状态标志含义
   1.2 状态转换图（Mermaid）
   1.3 yc_type() 判定逻辑
2. 堆大小动态调整
   2.1 G1HeapSizingPolicy 完整逻辑
   2.2 扩容触发条件 + 扩容量计算
   2.3 缩容逻辑
   2.4 uncommit_regions_if_necessary()
3. SurvRateGroup 存活率预测
   3.1 add() — 按年龄记录存活率
   3.2 accum_surv_rate_pred() — 累积存活率
   3.3 在 G1Policy 中的使用场景
4. G1YoungRemSetSamplingThread
   4.1 run_service() 主循环
   4.2 sample_young_list_rs_lengths()
   4.3 revise_young_list_target_length_if_necessary()
5. G1RemSetTrackingPolicy
   5.1 状态定义：Untracked/Updating/Complete
   5.2 update_at_allocate() — 初始状态
   5.3 update_before_rebuild() — Remark 后判断
   5.4 update_after_rebuild() — 重建完成
6. G1OldGenAllocationTracker
   6.1 跟踪老年代分配量
   6.2 IHOP 数据输入
7. GDB 验证
```

### #17 辅助子系统

```
1. G1BlockOffsetTable (BOT)
   1.1 数据结构：一字节偏移数组
   1.2 block_start() — 如何从地址找到对象头
   1.3 threshold 更新逻辑
   1.4 N-word 划分与偏移编码
2. G1GCPhaseTimes
   2.1 WorkerDataArray 模板
   2.2 所有 GCParPhases 枚举值含义
   2.3 print() 输出格式
   2.4 GC 日志格式详解
3. 字符串去重
   3.1 G1StringDedup 候选选择策略
   3.2 G1StringDedupQueue 队列实现
   3.3 StringDedupTable 去重表（哈希表）
   3.4 StringDedupThread 去重线程
4. G1HRPrinter
   4.1 事件类型与输出格式
   4.2 -Xlog:gc,region=trace 输出示例
5. G1HeapVerifier
   5.1 验证类型与使用场景
   5.2 VerifyGCType 参数
6. GDB 验证
```

### #18 GC 日志实战

```
1. 标准 GC 日志配置
   1.1 -Xlog:gc*=info vs trace vs debug
   1.2 常用日志标签组合
2. Young GC 日志逐行解读
   2.1 每一行对应哪个源码位置
   2.2 时间指标含义
   2.3 如何判断是否健康
3. Mixed GC 日志逐行解读
4. Full GC 日志逐行解读
5. 并发标记日志逐行解读
6. 关键参数调优实验
   6.1 MaxGCPauseMillis 对年轻代大小的影响
   6.2 G1MixedGCLiveThresholdPercent 对 Mixed GC 的影响
   6.3 G1HeapWastePercent 对 Mixed GC 持续条件的影响
   6.4 IHOP 自适应 vs 固定阈值
   6.5 ParallelGCThreads / ConcGCThreads 对吞吐量的影响
7. 故障场景日志分析
   7.1 Evacuation Failure 日志特征
   7.2 Full GC 频繁触发特征
   7.3 长暂停排查
```

### 增补 #8 并发标记

```
新增：
A. do_marking_step() 逐行分析（420 行核心代码）
   - Phase 1: drain_satb_buffers 逐行
   - Phase 2: 处理本地队列逐行
   - Phase 3: bitmap 扫描逐行
   - Phase 4: steal 逐行
   - Phase 5: 终止协议逐行
   - Phase 6: 溢出处理逐行
B. cleanup() 完整流程逐行
   - cleanup_ref_processor → cleanup_counts → rebuild_strong_code_roots
   - rebuild CollectionSetChooser
   - sort_regions
```

---

## 八、状态跟踪

| 编号 | 标题 | 状态 |
|------|------|------|
| #11 | Young GC 完整 STW 流程 | ✅ 完成 |
| #12 | G1RemSet 完整流程 | ✅ 完成 |
| 增补 #8 | 并发标记逐行增补 | ✅ 完成 |
| #14 | SafePoint + VM Operation | ✅ 完成 |
| #15 | 引用处理全链路 | ✅ 完成 |
| #13 | 写屏障汇编级全链路 | ✅ 完成 |
| #16 | 策略与自适应调整 | ✅ 完成 |
| #18 | GC 日志实战 | ✅ 完成 |
| #17 | 辅助子系统 | ✅ 完成 |
