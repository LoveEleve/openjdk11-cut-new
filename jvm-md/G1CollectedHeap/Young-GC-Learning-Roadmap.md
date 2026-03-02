# Young GC 完整学习路线图

> 目标：彻底掌握 Young GC 从触发到完成的完整流程  
> 方法：逐一攻破每个数据结构，最后串联成完整流程  
> 预计产出：8-10 篇专家级分析文档

---

## 📊 Young GC 全景图

```
Young GC 完整流程
│
├─ 阶段 1: 触发与决策 ─────────────────────────────────────┐
│  ├─ G1MonitoringSupport     # 堆使用监控，触发条件检查    │
│  ├─ G1Policy                 # 决策：是否触发、选哪些 Region│
│  └─ G1CollectionSetChooser   # CSet 候选 Region 选择器    │
│                                                            │
├─ 阶段 2: 暂停准备 ───────────────────────────────────────┤
│  ├─ VM_G1CollectForAllocation # VM 操作，进入 Safepoint    │
│  ├─ G1GCPhaseTimes           # GC 阶段计时器              │
│  └─ G1TraceTime               # 详细日志跟踪              │
│                                                            │
├─ 阶段 3: 根处理 ─────────────────────────────────────────┤
│  ├─ G1RootProcessor          # GC Roots 处理器            │
│  │   ├─ ClassLoaderDataGraph  # CLDG Roots               │
│  │   ├─ Threads               # 线程栈 Roots             │
│  │   ├─ Universe              # JVM 系统 Roots           │
│  │   ├─ JNI Handles           # JNI 全局引用             │
│  │   ├─ Code Cache            # CodeBlob Roots           │
│  │   └─ StringTable/SymbolTable # 字符串/符号表          │
│  │                                                          │
│  ├─ G1OopClosures            # 对象引用处理闭包          │
│  │   ├─ G1RootScanClosure     # 根扫描闭包               │
│  │   └─ G1CLDScanClosure      # CLD 扫描闭包             │
│  │                                                          │
│  └─ RefToScanQueueSet         # 待扫描对象队列（OopQueue）│
│                                                            │
├─ 阶段 4: Evacuation（疏散）──────────────────────────────┤
│  ├─ G1ParScanThreadState      # 并行扫描线程状态          │
│  │   ├─ _scan_queue           # 线程本地扫描队列          │
│  │   ├─ _rdc_buffers          # 脏卡缓冲区               │
│  │   └─ _hash_seed            # 哈希种子（用于 Work Stealing）│
│  │                                                          │
│  ├─ G1ParEvacuateFollowersClosure  # 疏散主闭包          │
│  │   ├─ 处理 _scan_queue 中的对象                         │
│  │   ├─ 复制存活对象到新 Region                            │
│  │   ├─ 更新对象引用（转发指针）                           │
│  │   └─ 记录跨 Region 引用到 RSet                          │
│  │                                                          │
│  ├─ G1AllocRegion             # 分配目标 Region          │
│  │   ├─ MutatorAllocRegion    # Eden 分配                │
│  │   ├─ GCAllocRegion         # GC  Survivor 分配        │
│  │   └─ OldGCAllocRegion      # GC  Old 分配（晋升）      │
│  │                                                          │
│  └─ G1UpdateRemSetClosure     # RSet 更新闭包            │
│                                                            │
├─ 阶段 5: 并发处理 ───────────────────────────────────────┤
│  ├─ G1RedirtyCardsClosure     # 重新标记脏卡             │
│  ├─ G1ConcurrentRefineThread  # 并发精炼线程（处理脏卡）  │
│  └─ G1StringDedup             # 字符串去重（可选）        │
│                                                            │
└─ 阶段 6: 收尾 ───────────────────────────────────────────┤
   ├─ G1ParGCAllocator           # 并行分配器清理          │
   ├─ G1CollectionSet::clear     # 清空 CSet               │
   ├─ FreeRegionList             # 回收空闲 Region         │
   └─ G1Policy::record_young_gc_pause  # 记录 GC 统计      │
```

---

## 📚 学习章节规划

### 第 1 章：触发与决策机制
**文档**: `G1Policy-Young-GC-Decision.md`

```
核心问题：
1. 什么时候触发 Young GC？
   - Eden 满了？
   - TLAB 分配失败？
   - G1Policy 的启发式判断？

2. 选择哪些 Region 进 CSet？
   - 所有 Eden Region
   - 部分 Survivor Region？
   - 老年代 Region？（Young GC 不选）

3. 停顿时间预测模型
   - G1Predictions
   - 历史数据加权平均
   - 预测本次 GC 时间

关键数据结构：
- G1Policy
- G1CollectionSetChooser
- G1Predictions
- G1MonitoringSupport
```

### 第 2 章：CSet 管理
**文档**: `G1CollectionSet-Deep-Dive.md`

```
核心问题：
1. CSet 的物理结构
   - set of HeapRegion*
   - Eden Regions 列表
   - Survivor Regions 列表

2. CSet 选择算法
   - Young GC：所有 Eden + 部分 Survivor
   - Mixed GC：Young + 部分 Old（按回收收益排序）

3. CSet 预算控制
   - 根据目标停顿时间计算可收集 Region 数量
   - G1HeapRegion::reclaimable_bytes()
   - G1HeapRegion::predicted_time_ms()

关键数据结构：
- G1CollectionSet
- G1CollectionSetChooser
- G1CSetRegionWorkerData
```

### 第 3 章：GC Roots 处理
**文档**: `G1RootProcessor-Complete-Analysis.md`

```
核心问题：
1. GC Roots 有哪些来源？
   - 线程栈（Java + VM）
   - CLDG（ClassLoaderDataGraph）
   - JNI 全局引用
   - Code Cache（nmethod）
   - JVM 内部数据结构（StringTable 等）

2. 并行根扫描
   - WorkGang：线程组
   - StrongRootsScope：根扫描范围
   - 线程分片处理

3. 根扫描优化
   - CLDG 并行扫描
   - Code Cache 分块扫描
   - StringTable 并发标记

关键数据结构：
- G1RootProcessor
- G1RootClosures
- CLDGRoots
- Threads::oops_do
- CodeCache::blobs_do
```

### 第 4 章：待扫描队列
**文档**: `RefToScanQueue-and-OopQueueSet.md`

```
核心问题：
1. 为什么需要扫描队列？
   - 根扫描只是找到入口
   - 需要广度/深度优先遍历对象图
   - 队列存储"待处理"的对象

2. OopQueue 结构
   - 有界队列（默认 1024）
   - 多生产者单消费者
   - 批量处理优化

3. Work Stealing
   - 线程空闲时"偷"其他线程的任务
   - _hash_seed 决定偷取顺序
   - 负载均衡

关键数据结构：
- OopQueue
- OopQueueSet
- RefToScanQueueSet
- G1ParScanThreadState::_scan_queue
```

### 第 5 章：并行扫描线程状态
**文档**: `G1ParScanThreadState-Expert-Analysis.md`

```
核心问题：
1. 每个 GC 线程的私有数据
   - _scan_queue：待扫描对象
   - _rdc_buffers：脏卡缓冲区（Redirty Cards）
   - _hash_seed：Work Stealing 种子

2. 对象复制流程
   - 从 Eden 复制到 Survivor
   - 从 Survivor 复制到 Survivor/Old
   - 转发指针（Forwarding Pointer）

3. 引用更新
   - 更新堆内对象引用
   - 更新 RSet
   - 处理跨 Region 引用

关键数据结构：
- G1ParScanThreadState
- G1ParGCAllocator
- G1OopClosures
- G1UpdateRemSetClosure
```

### 第 6 章：分配 Region 管理
**文档**: `G1AllocRegion-Allocation-Management.md`

```
核心问题：
1. GC 期间的内存分配
   - MutatorAllocRegion：应用线程分配（Eden）
   - GCAllocRegion：GC 线程分配（Survivor/Old）

2. 分配失败处理
   - Heap 扩展
   - GC 触发
   - OOM

3. 转发指针（Forwarding Pointer）
   - 对象头中的特殊标记
   - 指向新地址
   - 处理并发访问

关键数据结构：
- G1AllocRegion
- MutatorAllocRegion
- GCAllocRegion
- OldGCAllocRegion
- G1HeapRegion::object_iterate
```

### 第 7 章：RSet 更新与脏卡处理
**文档**: `G1RemSet-Update-During-GC.md`

```
核心问题：
1. Evacuation 时如何更新 RSet？
   - 对象移动到新 Region
   - 引用关系变化
   - 记录新的跨 Region 引用

2. Redirty Cards
   - 为什么需要重新标记？
   - 延迟处理机制
   - 并发精炼

3. RSet 清理
   - GC 后清理无效的 RSet 条目
   - 回收内存

关键数据结构：
- G1UpdateRemSetClosure
- G1RedirtyCardsClosure
- G1DirtyCardQueueSet
- G1ConcurrentRefineThread
```

### 第 8 章：Young GC 完整流程串联
**文档**: `Young-GC-Complete-Flow.md`

```
将所有章节串联，形成完整调用链：

1. 触发阶段
   VM_G1CollectForAllocation::doit()
   └── G1CollectedHeap::do_collection_pause_at_safepoint()

2. 准备阶段
   ├── G1Policy::decide_on_concurrent_start_pause()
   ├── G1CollectionSet::init_region_lengths()
   └── G1RootProcessor::evacuate_roots()

3. 并行阶段
   WorkGang::run_task(&evacuate_task)
   └── G1EvacuateRegionsBaseTask::work()
       └── G1ParScanThreadState::do_work()

4. 收尾阶段
   ├── G1ParGCAllocator::release()
   ├── G1CollectionSet::clear()
   └── G1Policy::record_young_gc_pause()
```

---

## 📅 执行计划

| 章节 | 预计时间 | 依赖 | 优先级 |
|------|----------|------|--------|
| 第 1 章：G1Policy | 2-3 小时 | 无 | ⭐⭐⭐⭐⭐ |
| 第 2 章：G1CollectionSet | 2 小时 | 第 1 章 | ⭐⭐⭐⭐⭐ |
| 第 3 章：G1RootProcessor | 2-3 小时 | 无 | ⭐⭐⭐⭐⭐ |
| 第 4 章：RefToScanQueue | 1-2 小时 | 无 | ⭐⭐⭐⭐ |
| 第 5 章：G1ParScanThreadState | 2-3 小时 | 第 4 章 | ⭐⭐⭐⭐⭐ |
| 第 6 章：G1AllocRegion | 1-2 小时 | 第 5 章 | ⭐⭐⭐⭐ |
| 第 7 章：RSet 更新 | 1-2 小时 | 已学 G1RemSet | ⭐⭐⭐⭐ |
| 第 8 章：完整流程 | 2 小时 | 所有前置 | ⭐⭐⭐⭐⭐ |

**总计**：约 14-20 小时，预计 7-10 天完成

---

## ✅ 开始执行

准备好了吗？我们从 **第 1 章：G1Policy - Young GC 触发与决策** 开始！
