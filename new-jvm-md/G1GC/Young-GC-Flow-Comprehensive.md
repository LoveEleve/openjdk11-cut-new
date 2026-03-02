# G1 Young GC 完整流程深度解析

> 本文档整合 26 个核心数据结构，从触发到结束，全景式展现 G1 Young GC 的完整执行流程。

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文是 G1 Young GC 的**全景式综合分析**：整合 26 个核心数据结构（HeapRegion/CardTable/RSet/PLAB/WorkGang 等），以时序图和数据流图展现 Young GC 从"Eden 满"到"GC 完成"的完整执行流程，串联所有子系统的协作关系。

### 0.2 26 个核心数据结构分类

| 类别 | 数据结构 | 作用 |
|------|---------|------|
| 内存管理 | HeapRegion, HeapRegionManager, G1AllocRegion | Region 分配与管理 |
| 写屏障 | G1CardTable, DirtyCardQueue, G1SATBMarkQueue | 引用修改追踪 |
| 记忆集 | HeapRegionRemSet, SparsePRT, PerRegionTable | 跨 Region 引用索引 |
| GC 策略 | G1Policy, G1Analytics, G1Predictions | 自适应决策 |
| Evacuation | G1ParScanThreadState, G1PLABAllocator, WorkGang | 并行对象复制 |
| 并发精炼 | G1ConcurrentRefineThread, G1HotCardCache | 后台 RSet 更新 |

### 0.3 完整执行时序

```
Eden 满 → attempt_allocation_slow() 失败
    ↓ VM_G1CollectForAllocation
STW 开始
    ↓ Pre-Evacuate（5-20ms）
    │  update_rem_set()：处理残留脏卡
    │  finalize_collection_set()：构建 CSet
    ↓ Evacuate（50-150ms）
    │  evacuate_roots()：扫描 GC Roots
    │  G1ParEvacuateFollowersClosure：传递闭包
    ↓ Post-Evacuate（5-20ms）
    │  释放 CSet Region
    │  重新标记脏卡（新跨 Region 引用）
STW 结束
    ↓ record_collection_pause_end()：更新预测模型
```

---

## 一、流程总览

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           G1 Young GC 完整流程                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  阶段1: 触发/决策                    数据结构/组件                            │
│  ┌─────────────────┐                                                        │
│  │ Eden 分配失败    │ ──> G1AllocRegion ──> 慢速分配失败                    │
│  │ 或达到阈值       │ ──> G1Policy::should_start_gc()                       │
│  └────────┬────────┘                检查 MMU 限制                           │
│           │                                                                │
│           ▼                                                                │
│  ┌─────────────────┐               G1CollectionSet                          │
│  │ 确定 CSet       │ ──> finalize_young_part()                             │
│  │ (Eden+Survivor) │ ──> 选择待回收 Region                                  │
│  └────────┬────────┘                                                        │
│           │                                                                │
│  阶段2: 暂停准备                                                            │
│           │                                                                │
│           ▼                                                                │
│  ┌─────────────────┐               WorkGang                                 │
│  │ 启动 GC 线程    │ ──> 唤醒 N 个 GC Worker                                │
│  │ (并行准备)      │ ──> Semaphore 同步                                    │
│  └────────┬────────┘                                                        │
│           │                                                                │
│  阶段3: 根扫描                    G1RootProcessor                            │
│           │                       G1RootClosures                             │
│           ▼                                                                │
│  ┌─────────────────┐               SubTasksDone (13 种根来源)               │
│  │ 并行扫描 GC Roots│ ──> Thread Roots                                      │
│  │                │ ──> StringTable Roots                                  │
│  │                │ ──> JNI/JVMTI Roots                                    │
│  │                │ ──> CLDG Roots (强/弱分离)                              │
│  └────────┬────────┘                                                        │
│           │                                                                │
│  阶段4: Evacuation (疏散)       G1ParEvacuateFollowersClosure               │
│           │                     G1ParScanThreadState                         │
│           │                     RefToScanQueue (ABP Work Stealing)          │
│           ▼                                                                │
│  ┌─────────────────┐                                                        │
│  │ Update RS       │ ──> 处理 DirtyCardQueue                                │
│  │ (更新 RSet)     │ ──> G1UpdateRemSetClosure                              │
│  │                │ ──> G1CardTable.mark_card_deferred()                   │
│  ├─────────────────┤                                                        │
│  │ Scan RS         │ ──> 扫描 RSet，获取跨 Region 引用                     │
│  │ (扫描记忆集)    │ ──> G1RemSet                                           │
│  ├─────────────────┤                                                        │
│  │ ObjCopy         │ ──> G1ParCopyClosure                                   │
│  │ (对象复制)      │ ──> PLAB 分配 (G1PLABAllocator)                        │
│  │                │ ──> CAS 安装转发指针 (Forwarding)                       │
│  │                │ ──> 处理 Evacuation Failure                             │
│  ├─────────────────┤                                                        │
│  │ Termination     │ ──> Work Stealing (Best-of-2)                         │
│  │ (终止协议)      │ ──> offer_termination()                                │
│  └────────┬────────┘                                                        │
│           │                                                                │
│  阶段5: 后处理                                                              │
│           │                                                                │
│           ▼                                                                │
│  ┌─────────────────┐               G1RedirtyCardsClosure                    │
│  │ Redirty Cards   │ ──> 清理无效卡片                                       │
│  │ (重新标记脏卡)  │ ──> 为下次 GC 准备                                     │
│  ├─────────────────┤                                                        │
│  │ Free CSet       │ ──> 释放 Eden/Survivor Region                          │
│  │ (释放 CSet)     │ ──> 清空并回收 Region                                  │
│  ├─────────────────┤                                                        │
│  │ String Dedup    │ ──> G1StringDedup                                      │
│  │ (字符串去重)    │ ──> 候选选择 + 异步处理                                 │
│  └────────┬────────┘                                                        │
│           │                                                                │
│  阶段6: 恢复与统计                                                          │
│           │                                                                │
│           ▼                                                                │
│  ┌─────────────────┐               G1GCPhaseTimes                           │
│  │ 打印 GC 日志    │ ──> 30+ 阶段耗时统计                                   │
│  │                │ ──> info/debug/trace 三级输出                           │
│  ├─────────────────┤                                                        │
│  │ 更新统计        │ ──> G1Analytics                                        │
│  │                │ ──> 17 个统计指标更新                                    │
│  ├─────────────────┤                                                        │
│  │ MMU 跟踪        │ ──> G1MMUTracker.add_pause()                           │
│  │                │ ──> 记录 GC 历史                                        │
│  ├─────────────────┤                                                        │
│  │ 唤醒应用线程    │ ──> WorkGang 信号量释放                                 │
│  │                │ ──> 恢复 mutator 执行                                    │
│  └─────────────────┘                                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 二、核心数据结构职责速查

| # | 数据结构 | 核心职责 | 所在阶段 |
|---|---------|---------|---------|
| 1 | G1CollectedHeap | 堆管理入口 | 全阶段 |
| 2 | HeapRegionManager | Region 生命周期管理 | 初始化、回收 |
| 3 | HeapRegion | 单 Region 状态管理 | 全阶段 |
| 4 | G1CardTable | 卡表，追踪内存修改 | Write Barrier、Update RS |
| 5 | G1RemSet | 记忆集，管理跨 Region 引用 | Update RS、Scan RS |
| 6 | G1Policy | GC 决策中心 | 触发、CSet 选择 |
| 7 | G1Predictions | 预测算法 | 决策支持 |
| 8 | G1Analytics | 统计数据中心 | 决策支持、GC 后更新 |
| 9 | G1CollectionSet | CSet 管理 | 准备阶段、Evacuation |
| 10 | CollectionSetChooser | 老年代选择 | Mixed GC |
| 11 | G1RootProcessor | GC Roots 处理协调 | 根扫描阶段 |
| 12 | G1ParScanThreadState | 线程本地扫描状态 | Evacuation |
| 13 | WorkGang | GC 工作线程池 | 并行阶段 |
| 14 | RefToScanQueue | 待扫描对象队列 (ABP) | Evacuation |
| 15 | G1AllocRegion | 目标 Region 分配器 | Evacuation |
| 16 | G1ParEvacuateFollowersClosure | 疏散主闭包 | Evacuation |
| 17 | G1RootClosures | GC Roots 处理闭包 | 根扫描阶段 |
| 18 | G1PLAB | 线程局部分配缓冲区 | 对象复制 |
| 19 | G1UpdateRemSetClosure | RSet 更新闭包 | Update RS |
| 20 | G1RedirtyCardsClosure | 脏卡重新标记 | 后处理阶段 |
| 21 | G1ConcurrentRefineThread | 并发精炼线程 | 并发阶段 |
| 22 | G1MonitoringSupport | 监控支持 | 统计输出 |
| 23 | G1StringDedup | 字符串去重 | 后处理阶段 |
| 24 | G1MMUTracker | MMU 跟踪 | 决策、GC 后 |
| 25 | G1GCPhaseTimes | GC 阶段计时器 | 日志输出 |
| 26 | DirtyCardQueue | 脏卡队列 | Write Barrier、Update RS |

---

## 三、详细流程分析

### 3.1 触发阶段

**触发条件**：
```cpp
// 条件1: Eden 分配失败
def new_instance() {
  obj = G1CollectedHeap::allocate(...);
  if (obj == NULL) {
    // 分配失败，触发 GC
    do_collection_pause();  // Young GC
  }
}

// 条件2: 达到年轻代目标大小
if (G1Policy::should_start_gc()) {
  // _young_list_target_length 已满足
  do_collection_pause();
}
```

**MMU 检查**：
```cpp
// G1Policy::should_start_gc()
if (_mmu_tracker->now_max_gc(os::elapsedTime())) {
  // 可以执行最大 GC，允许触发
  return true;
}
// 需要等待，暂不触发
return false;
```

### 3.2 CSet 确定

```cpp
// G1CollectionSet::finalize_young_part()
void finalize_young_part() {
  // 1. 添加所有 Eden Region
  for (Region r : _eden_regions) {
    add_region(r);
  }
  
  // 2. 添加所有 Survivor Region
  for (Region r : _survivor_regions) {
    add_region(r);
  }
  
  // 3. 设置年轻代长度
  _young_region_length = _eden_region_length + _survivor_region_length;
}
```

### 3.3 根扫描

```cpp
// G1RootProcessor::process_roots()
void process_roots(...) {
  // 13 种根来源，使用 SubTasksDone 并行认领
  SubTasksDone tasks(GCParPhases::Sentinel);
  
  // 第一阶段：强根
  process_java_roots();      // Thread Roots
  process_string_table();    // StringTable Roots
  process_jni_roots();       // JNI Roots
  ...
  
  // 第二阶段：弱根
  process_weak_cld_roots();  // Weak CLD Roots
}
```

### 3.4 Evacuation 核心循环

```cpp
// G1ParEvacuateFollowersClosure::do_void()
void do_void() {
  // 阶段1: 处理本地队列
  pss->trim_queue();
  
  // 阶段2: 窃取其他队列
  do {
    pss->steal_and_trim_queue(queues());
  } while (!offer_termination());
}

// trim_queue() 内部
void trim_queue() {
  while (!queue.is_empty()) {
    obj = queue.pop_local();
    
    // 1. 扫描对象字段
    for (field : obj.oop_fields()) {
      // 2. 获取引用对象
      ref = *field;
      
      // 3. 检查是否在 CSet 中
      if (in_cset(ref)) {
        // 4. 复制对象
        new_ref = copy_to_survivor_space(ref);
        
        // 5. CAS 安装转发指针
        if (CAS(field, ref, new_ref)) {
          // 6. 将新对象加入队列继续扫描
          queue.push(new_ref);
        }
      }
    }
  }
}
```

### 3.5 对象复制详细流程

```cpp
// copy_to_survivor_space()
HeapWord* copy_to_survivor_space(oop obj) {
  // 步骤1: 检查是否已复制（转发指针）
  if (obj->is_forwarded()) {
    return obj->forwardee();
  }
  
  // 步骤2: PLAB 快速分配
  size_t size = obj->size();
  HeapWord* new_addr = plab_allocate(size);
  
  if (new_addr == NULL) {
    // PLAB 不足，直接分配或分配新 PLAB
    new_addr = allocate_direct_or_new_plab(size);
  }
  
  // 步骤3: 复制对象
  Copy::aligned_conjoint_words(obj, new_addr, size);
  
  // 步骤4: CAS 安装转发指针
  if (obj->cas_forward_to(new_addr)) {
    // 成功，返回新地址
    return new_addr;
  } else {
    // 失败，其他线程已复制
    undo_allocation(new_addr, size);
    return obj->forwardee();
  }
}
```

---

## 四、数据流图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          Young GC 数据流                                 │
└─────────────────────────────────────────────────────────────────────────┘

Write Barrier (应用线程持续执行)
    │
    │ 发现跨 Region 引用修改
    ▼
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│ G1CardTable │────>│DirtyCardQueue│────>│ Concurrent  │
│ mark_dirty  │     │ enqueue()   │     │ Refine      │
└─────────────┘     └─────────────┘     │ Thread      │
                                        │ (异步处理)   │
                                        └──────┬──────┘
                                               │
                                               ▼
                                        ┌─────────────┐
                                        │  G1RemSet   │
                                        │  update RS  │
                                        └─────────────┘

Young GC 触发
    │
    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         GC 暂停期间                                      │
└─────────────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│    Roots    │────>│   Update RS │────>│   Scan RS   │
│  (13种来源)  │     │ (处理DCQ)   │     │ (使用RSet)  │
└─────────────┘     └──────┬──────┘     └──────┬──────┘
                           │                    │
                           │  获取跨Region引用   │
                           ▼                    ▼
                    ┌─────────────┐     ┌─────────────┐
                    │  脏卡队列    │     │  RSet 扫描   │
                    │  批量处理    │     │  获取引用    │
                    └─────────────┘     └──────┬──────┘
                                                │
                                                ▼
                                         ┌─────────────┐
                                         │   ObjCopy   │
                                         │  (对象复制)  │
                                         │ PLAB分配    │
                                         │ CAS转发指针  │
                                         └──────┬──────┘
                                                │
                                                ▼
                                         ┌─────────────┐
                                         │ RefToScanQueue│
                                         │ 待扫描队列   │
                                         │ (Work Steal) │
                                         └─────────────┘
```

---

## 五、性能关键点

### 5.1 快速路径 vs 慢速路径

| 操作 | 快速路径 | 慢速路径 | 触发条件 |
|------|---------|---------|---------|
| Eden 分配 | TLAB bump | PLAB refill / 直接分配 | TLAB 满 |
| PLAB 分配 | bump-the-pointer | 获取新 PLAB | PLAB 满 |
| 对象复制 | CAS 成功 | 已转发，读取转发地址 | 竞争复制 |
| Work Steal | 本地队列 | 窃取其他队列 | 本地空 |

### 5.2 并行度与负载均衡

```
理想状态：
  Worker 0:  ████████████████████  100ms
  Worker 1:  ████████████████████  100ms
  Worker 2:  ████████████████████  100ms
  Worker 3:  ████████████████████  100ms

实际状态（需要 Work Stealing）：
  Worker 0:  ████████████████████████  120ms
  Worker 1:  ██████████████  70ms ──> 窃取 30ms
  Worker 2:  ████████████████  80ms ──> 窃取 20ms
  Worker 3:  ██████████████  70ms ──> 窃取 30ms
  
负载均衡度量：diff = max - min
```

### 5.3 内存占用总结

| 数据结构 | 8GB 堆内存占用 | 说明 |
|---------|---------------|------|
| 堆本身 | 8GB | Java 对象存储 |
| G1CardTable | 16MB | 卡表 |
| BOT | 16MB | 块偏移表 |
| 位图×2 | 256MB | 并发标记用 |
| RSet | 可变 | 通常 1-5% 堆大小 |
| PLAB | N × 4KB | 线程本地缓冲区 |

---

## 六、面试速查表

### Q1: Young GC 的完整流程是什么？

**答案要点**：
1. **触发**：Eden 满或达到阈值，检查 MMU
2. **CSet 确定**：选择 Eden + Survivor Region
3. **根扫描**：13 种根来源，并行处理
4. **Evacuation**：Update RS → Scan RS → ObjCopy → Termination
5. **后处理**：Redirty Cards、Free CSet、String Dedup
6. **恢复**：打印日志、更新统计、恢复应用

### Q2: 对象复制的过程是什么？

**答案要点**：
1. 检查转发指针（是否已复制）
2. PLAB 分配空间
3. 复制对象数据
4. CAS 安装转发指针
5. 扫描新对象引用字段
6. 加入 RefToScanQueue

### Q3: Work Stealing 怎么工作？

**答案要点**：
1. 本地队列空时触发
2. Best-of-2 策略选择目标队列
3. CAS 窃取全局端（FIFO）
4. 继续处理窃取的对象
5. 终止协议检测全局完成

### Q4: G1 如何实现可预测暂停时间？

**答案要点**：
1. G1Policy 预测各阶段耗时
2. 基于历史数据（G1Analytics）
3. 计算满足暂停目标的最大年轻代大小
4. MMU Tracker 确保时间片限制
5. 可中断的并行阶段（如 Termination）

---

## 七、总结

**G1 Young GC 是一个精心设计的并行、分阶段、可预测的垃圾回收流程，通过 26+ 个核心数据结构的协作，实现了高吞吐量和低延迟的平衡。**

### 核心设计思想

1. **Region 化**：细粒度内存管理，支持增量回收
2. **并行化**：多线程并行处理，Work Stealing 负载均衡
3. **延迟化**：写屏障异步处理，减少应用停顿
4. **预测化**：基于历史数据预测，实现可预测暂停

### 学习建议

1. **先整体后细节**：理解流程骨架，再深入研究数据结构
2. **多画图**：内存布局图、流程图、时序图
3. **多实验**：用 GDB 验证理论，查看实际数据
4. **多总结**：整理面试问答，形成自己的理解

---

**本文档整合 26 篇专家级分析，总字数超过 800KB，涵盖 G1 Young GC 的方方面面。建议结合具体源码和 GDB 调试，深入理解每个细节。**

---

*文档生成时间: 2026-02-11*  
*源码版本: OpenJDK 11*  
*文档数量: 27 篇（26 数据结构 + 1 流程总结）*
