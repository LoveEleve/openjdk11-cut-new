# G1 Young GC 完整流程源码分析

> **核心目标**：将所有模块串联，形成完整的 Young GC 执行流程，理解各阶段的协作关系。

---

## 目录

1. [问题引入：Young GC 要解决什么问题？](#1-问题引入young-gc-要解决什么问题)
2. [整体流程概览](#2-整体流程概览)
3. [阶段一：GC 前置准备](#3-阶段一gc-前置准备)
4. [阶段二：根集扫描与 Evacuation](#4-阶段二根集扫描与-evacuation)
5. [阶段三：引用处理与收尾](#5-阶段三引用处理与收尾)
6. [阶段四：GC 后处理](#6-阶段四gc-后处理)
7. [关键数据流转](#7-关键数据流转)
8. [GDB 验证脚本](#8-gdb-验证脚本)
9. [面试级 Q&A](#9-面试级-qa)

---

## 1. 问题引入：Young GC 要解决什么问题？

### 问题场景

**Eden 区填满触发 GC**：

```
初始状态（-Xms8g -Xmx8g -XX:+UseG1GC）：
  Eden Regions: 100 个（约 400 MB）
  Survivor Regions: 10 个（约 40 MB）
  Old Regions: 200 个（约 800 MB）
  
应用运行：
  - 对象持续分配到 Eden
  - Eden 使用率逐渐升高
  - 达到阈值（默认 60%）→ 触发 Young GC

Young GC 目标：
  1. 回收 Eden 中的垃圾对象
  2. 存活对象复制到 Survivor/Old
  3. 更新所有引用
  4. 维护记忆集（RSet）
```

**核心挑战**：

```
1. **对象存活判断**：
   - 如何快速识别存活对象？
   - 如何遍历对象图？

2. **对象移动**：
   - 如何高效复制存活对象？
   - 如何更新所有引用？

3. **并发安全**：
   - 多线程如何协同工作？
   - 如何避免数据竞争？

4. **记忆集维护**：
   - 老年代如何找到年轻代引用？
   - 如何更新跨代引用？

5. **暂停时间控制**：
   - 如何在目标时间内完成？
   - 如何预测 GC 时间？
```

### G1 的解决方案

**分层设计**：

```
1. **策略层**（G1Policy）：
   - 决定 CSet 大小
   - 预测暂停时间
   - 调整年轻代大小

2. **执行层**（G1CollectedHeap）：
   - 协调 GC 各阶段
   - 管理并行任务
   - 处理异常情况

3. **工作层**（G1ParScanThreadState）：
   - 每线程独立执行
   - 对象复制、引用更新
   - Work Stealing

4. **基础设施层**：
   - 卡表、RSet（跨代引用）
   - PLAB（快速分配）
   - 闭包体系（引用扫描）
```

---

## 2. 整体流程概览

### 2.1 完整流程图

```
┌─────────────────────────────────────────────────────────────┐
│                   Young GC 完整流程                          │
└─────────────────────────────────────────────────────────────┘

1. GC 触发
   │
   ├─→ Eden 使用率达到阈值
   ├─→ G1Policy 计算 CSet
   └─→ VM_G1CollectForAllocation 提交 VM_Operation
   
2. 安全点检查
   │
   ├─→ 所有线程到达安全点
   └─→ 进入 STW 暂停

3. GC 前置准备
   │
   ├─→ 初始化 GC 状态
   ├─→ 创建闭包体系
   ├─→ 初始化 PLAB
   └─→ 重置统计信息

4. 根集扫描（并行）
   │
   ├─→ 线程栈引用
   ├─→ 静态字段
   ├─→ JNI 引用
   ├─→ ClassLoaderData
   └─→ Code Cache
   
5. Evacuation（并行）
   │
   ├─→ 处理引用队列
   │     ├─→ 对象在 CSet → 复制对象
   │     └─→ 对象不在 CSet → 更新 RSet
   │
   └─→ Work Stealing
   
6. 引用处理
   │
   ├─→ Soft/Weak/Phantom/Finializer
   └─→ JNI Weak
   
7. GC 收尾
   │
   ├─→ 刷新 PLAB 统计
   ├─→ 更新记忆集
   ├─→ 释放 CSet Regions
   └─→ 重置卡表

8. GC 后处理
   │
   ├─→ 调整年轻代大小
   ├─→ 更新预测模型
   ├─→ 触发并发标记（如需要）
   └─→ 退出安全点

9. 应用继续运行
   │
   └─→ Eden 重新填充...
```

### 2.2 时间线与各阶段耗时

```
标准 Young GC 时间线（-Xms8g -Xmx8g）：

┌────────────────────────────────────────────────────────────┐
│ GC Worker 0                                                │
├────────────────────────────────────────────────────────────┤
│ [准备      ]  1-2 ms                                      │
│ [根集扫描  ]  5-15 ms  ← 并行                              │
│ [Scan RS   ]  3-10 ms  ← 并行                              │
│ [对象复制  ]  20-50 ms ← 并行                              │
│ [终止      ]  1-5 ms                                      │
│ [清理      ]  2-5 ms                                      │
└────────────────────────────────────────────────────────────┘

总暂停时间：30-80 ms（取决于存活对象数量）

各阶段占比：
  - 根集扫描：10-20%
  - Scan RS：10-15%
  - 对象复制：50-70%
  - 其他：5-10%
```

---

## 3. 阶段一：GC 前置准备

### 3.1 GC 触发条件

```cpp
// src/hotspot/share/gc/g1/g1CollectedHeap.cpp:2729-2799
void G1CollectedHeap::collect(GCCause::Cause cause) {
  uint gc_count_before = total_collections();
  uint full_gc_count_before = total_full_collections();
  
  if (should_do_concurrent_full_gc(cause)) {
    // 并发 Full GC（Initial Mark）
    VM_G1CollectForAllocation op(0, gc_count_before, cause, 
                                   true,  // should_initiate_conc_mark
                                   g1_policy()->max_pause_time_ms());
    VMThread::execute(&op);
  } else {
    // Young GC
    VM_G1CollectForAllocation op(0, gc_count_before, cause, 
                                   false, // should_initiate_conc_mark
                                   g1_policy()->max_pause_time_ms());
    VMThread::execute(&op);
  }
}
```

**触发条件**：

```
1. Eden 填满：
   - 分配失败 → 触发 Young GC
   - 最常见场景

2. GCLocker：
   - JNI 临界区退出后
   - 需要补偿 GC

3. System.gc()：
   - 显式调用
   - 可配置为并发 GC

4. 白盒测试：
   - -XX:+WhiteBoxAPI
   - 测试触发 GC
```

### 3.2 初始化 GC 状态

```cpp
// src/hotspot/share/gc/g1/g1CollectedHeap.cpp（伪代码）
void G1CollectedHeap::do_collection_pause_at_safepoint() {
  // 1. 记录 GC 开始时间
  _gc_timer_stw->register_gc_start();
  
  // 2. 重置统计信息
  g1_policy()->record_collection_pause_start();
  
  // 3. 验证堆一致性
  verify_before_gc();
  
  // 4. 准备 CSet
  g1_policy()->finalize_cset();
  
  // 5. 初始化分配器
  _allocator->init_gc_alloc_regions(evacuation_info);
  
  // 6. 创建闭包体系
  G1EvacuationRootClosures* closures = 
    G1EvacuationRootClosures::create_root_closures(pss, this);
  
  // 7. 创建根集处理器
  G1RootProcessor root_processor(this);
  
  // 8. 创建并行任务
  G1ParTask task(this, pss, task_queues, &root_processor, n_workers);
  
  // 9. 执行并行任务
  workers()->run_task(&task);
  
  // ... 后续处理
}
```

### 3.3 CSet 选择

```cpp
// src/hotspot/share/gc/g1/g1Policy.cpp（伪代码）
void G1Policy::finalize_cset() {
  // Young GC：只选择年轻代 Region
  // Mixed GC：选择年轻代 + 部分老年代
  
  double young_start_time_sec = os::elapsedTime();
  
  // 1. 添加年轻代到 CSet
  _collection_set->add_young_regions();
  
  // 2. 计算年轻代预测时间
  double predicted_pause_time_ms = predict_young_collection_pause_time();
  
  // 3. 如果是 Mixed GC，尝试添加老年代
  if (!young_only_phase()) {
    add_old_regions_to_cset(predicted_pause_time_ms);
  }
  
  // 4. 记录 CSet 大小
  _young_cset_length = young_cset_region_length();
  _old_cset_length = old_cset_region_length();
}

double G1Policy::predict_young_collection_pause_time() {
  // 预测公式：
  // time = 常数部分 + 存活对象复制时间 + RSet 处理时间
  
  size_t young_bytes = young_cset_size_bytes();
  double survivor_rate = predict_survival_rate();
  size_t survivor_bytes = young_bytes * survivor_rate;
  
  // 复制时间 = 存活对象大小 × 复制速率
  double copy_time = survivor_bytes / predict_copy_time_per_byte();
  
  // RSet 处理时间
  double scan_rs_time = predict_scan_rs_time();
  
  // 其他固定开销
  double constant_time = predict_constant_other_time();
  
  return copy_time + scan_rs_time + constant_time;
}
```

**CSet 选择示例**：

```
场景：-Xms8g -Xmx8g，Eden 使用率 60%

年轻代：
  Eden Regions: 100 个（活跃 60 个）
  Survivor Regions: 10 个

选择策略：
  1. 所有活跃 Eden Region → CSet
  2. 所有 Survivor Region → CSet
  3. 总计：70 个 Region（280 MB）

预测时间：
  存活对象估计：30 MB（存活率 10%）
  复制时间：30 MB / 200 MB/ms = 0.15 ms
  RSet 处理：5 ms
  其他开销：10 ms
  总预测：15.15 ms

决策：
  预测 15 ms < 目标 200 ms
  → 执行 Young GC
```

---

## 4. 阶段二：根集扫描与 Evacuation

### 4.1 G1ParTask 并行任务框架

```cpp
// src/hotspot/share/gc/g1/g1CollectedHeap.cpp:3916-4003
class G1ParTask : public AbstractGangTask {
protected:
  G1CollectedHeap *_g1h;
  G1ParScanThreadStateSet *_pss;
  RefToScanQueueSet *_queues;
  G1RootProcessor *_root_processor;
  ParallelTaskTerminator _terminator;
  uint _n_workers;

public:
  void work(uint worker_id) {
    // 1. 获取线程状态
    G1ParScanThreadState *pss = _pss->state_for_worker(worker_id);
    
    // 2. 根集扫描
    _root_processor->evacuate_roots(pss, worker_id);
    
    // 3. 扫描记忆集
    _g1h->g1_rem_set()->oops_into_collection_set_do(pss, worker_id);
    
    // 4. Evacuate Followers（处理引用队列）
    G1ParEvacuateFollowersClosure evac(_g1h, pss, _queues, &_terminator);
    evac.do_void();
    
    // 5. 清空队列
    assert(pss->queue_is_empty(), "should be empty");
  }
};
```

### 4.2 根集扫描

```cpp
// src/hotspot/share/gc/g1/g1RootProcessor.cpp（伪代码）
void G1RootProcessor::evacuate_roots(G1ParScanThreadState* pss, uint worker_id) {
  // 获取闭包
  G1EvacuationRootClosures* closures = pss->closures();
  
  // 1. 扫描线程栈
  {
    G1RootScanClosure scan_cl(g1h, pss);
    Threads::possibly_parallel_oops_do(false, &scan_cl, &scan_cl);
  }
  
  // 2. 扫描 ObjectSynchronizer（锁对象）
  ObjectSynchronizer::oops_do(strong_roots);
  
  // 3. 扫描 SystemDictionary（类）
  {
    G1ParCopyClosure<G1BarrierCLD, G1MarkNone> scan_cl(g1h, pss);
    CLDToOopClosure cld_cl(&scan_cl, ClassLoaderData::_claim_strong);
    ClassLoaderDataGraph::cld_do(&cld_cl);
  }
  
  // 4. 扫描 Code Cache（JIT 代码）
  {
    G1CodeBlobClosure code_cl(g1h, pss);
    CodeCache::blobs_do(&code_cl);
  }
  
  // 5. 扫描 JVM 内部根
  {
    G1RootScanClosure scan_cl(g1h, pss);
    Universe::oops_do(&scan_cl);
    Management::oops_do(&scan_cl);
    JvmtiExport::oops_do(&scan_cl);
    // ... 其他内部根
  }
  
  // 6. 扫描 StringTable（字符串常量池）
  {
    G1StringDedupUnlinkOrOopsDoClosure closure(strong_roots, weak_roots);
    StringTable::possibly_parallel_oops_do(&closure);
  }
}
```

**根集类型**：

```
1. 线程栈引用：
   - 局部变量
   - 操作数栈
   - JNI 局部引用

2. 静态字段：
   - SystemDictionary
   - ClassLoaderData

3. JVM 内部：
   - Universe
   - ObjectSynchronizer（锁）
   - Management
   - JvmtiExport

4. 代码缓存：
   - JIT 编译代码
   - nmethods

5. 字符串常量池：
   - StringTable

总计：~10-20 ms（取决于根集大小）
```

### 4.3 扫描记忆集（Scan RS）

```cpp
// src/hotspot/share/gc/g1/g1RemSet.cpp（伪代码）
void G1RemSet::oops_into_collection_set_do(G1ParScanThreadState* pss, uint worker_id) {
  // 1. 更新 RSet（Update RS）
  update_rs_length();
  scan_rem_set(pss, worker_id);
  
  // 2. 扫描 RSet
  {
    G1ScanObjsDuringScanRSClosure scan_cl(g1h, pss);
    
    // 遍历 CSet 中所有 Region 的 RSet
    for (HeapRegion* hr : collection_set()) {
      scan_region_rem_set(hr, &scan_cl, worker_id);
    }
  }
}

void G1RemSet::scan_region_rem_set(HeapRegion* hr, 
                                     G1ScanObjsDuringScanRSClosure* cl,
                                     uint worker_id) {
  // 遍历 RSet 中的引用
  HeapRegionRemSet* rem_set = hr->rem_set();
  
  // Sparse PRT
  rem_set->iterate(cl);
  
  // Fine Grain PRT
  rem_set->iterate_fine(cl);
}
```

**Scan RS 流程**：

```
跨代引用：
  Old Region 50
    └─→ 对象 X.field → Eden Region 10 的对象 Y

RSet 记录：
  Eden Region 10 的 RSet 包含：
    - Old Region 50, Card 3

Scan RS：
  1. 遍历 Eden Region 10 的 RSet
  2. 找到 Old Region 50, Card 3
  3. 扫描 Card 3 中的对象
  4. 发现 X.field → Y
  5. G1ScanObjsDuringScanRSClosure.do_oop_work(&X.field)
     - Y 在 CSet → prefetch_and_push(&X.field, Y)
     - Y 不在 CSet → 跳过

结果：
  - 所有跨代引用被处理
  - Y 被复制（如果存活）
  - X.field 被更新
```

### 4.4 Evacuate Followers

```cpp
// src/hotspot/share/gc/g1/g1ParScanThreadState.cpp（伪代码）
class G1ParEvacuateFollowersClosure : public VoidClosure {
  void do_void() {
    // 循环处理引用队列
    do {
      // 1. 清空本地队列
      pss->trim_queue();
      
      // 2. 尝试 Work Stealing
      pss->steal_and_trim_queue(task_queues);
      
    } while (!terminator->offer_termination());
  }
};

void G1ParScanThreadState::trim_queue() {
  StarTask ref;
  while (_refs->pop_local(ref)) {
    // 分发引用
    dispatch_reference(ref);
  }
}

void G1ParScanThreadState::dispatch_reference(StarTask ref) {
  // 1. 解析引用
  oop obj = *ref;
  
  // 2. 检查对象状态
  const InCSetState state = _g1h->in_cset_state(obj);
  
  if (state.is_in_cset()) {
    // 对象在 CSet，需要处理
    markOop m = obj->mark_raw();
    
    if (m->is_marked()) {
      // 已转发，使用转发地址
      obj = (oop) m->decode_pointer();
    } else {
      // 未转发，复制对象
      obj = copy_to_survivor_space(state, obj, m);
    }
    
    // 更新引用
    RawAccess<>::oop_store(ref, obj);
  } else {
    // 对象不在 CSet
    handle_non_cset_obj(state, ref, obj);
  }
}
```

**Evacuation 流程图**：

```
┌─────────────────────────────────────────────────────────────┐
│                    Evacuation 流程                          │
└─────────────────────────────────────────────────────────────┘

初始状态：
  队列：[ref1, ref2, ref3, ...]

循环：
  while (队列不为空 || Work Stealing 成功) {
    
    ref = pop()  // 从队列取出引用
    
    ├─→ 检查对象状态
    │
    ├─→ 对象在 CSet？
    │     │
    │     ├─→ 已转发？
    │     │     └─→ 使用转发地址
    │     │
    │     └─→ 未转发
    │           │
    │           ├─→ PLAB 分配
    │           │     └─→ _plab_allocator->plab_allocate()
    │           │
    │           ├─→ CAS 安装转发指针
    │           │     └─→ old->forward_to_atomic()
    │           │
    │           ├─→ 复制对象
    │           │     └─→ Copy::aligned_disjoint_words()
    │           │
    │           └─→ 扫描新对象字段
    │                 └─→ obj->oop_iterate_backwards(&_scanner)
    │                       └─→ push_on_queue() // 新引用入队
    │
    └─→ 对象不在 CSet
          └─→ 更新 RSet
    
    // 队列可能增长：
    // 处理 1 个对象 → 产生 N 个新引用
  }
```

**Work Stealing 机制**：

```
场景：4 个 GC 线程

初始任务分配：
  W0: [ref1, ref2, ref3]
  W1: [ref4, ref5, ref6]
  W2: [ref7, ref8, ref9]
  W3: []

执行：
  T1: W0, W1, W2 处理本地队列
      W3 本地队列空 → steal(W0) → 取走 ref1
  
  T2: W0 队列空 → steal(W1) → 取走 ref4
      W1 队列空 → steal(W2) → 取走 ref7
      W2 队列空 → steal(W0) → 失败
      W3 处理 ref1（可能产生新引用）
  
  T3: 所有队列空 → offer_termination()
      - 所有线程同意终止
      - GC 结束

优势：
  - 负载均衡
  - 避免空闲线程
  - 提高并行度
```

---

## 5. 阶段三：引用处理与收尾

### 5.1 引用处理

```cpp
// src/hotspot/share/gc/g1/g1CollectedHeap.cpp（伪代码）
void G1CollectedHeap::process_references() {
  // 1. 处理 Soft/Weak/Phantom/Finializer
  ReferenceProcessor* rp = ref_processor_stw();
  
  // 发现引用
  rp->setup_policy(false); // clear discovered lists
  rp->discover_references();
  
  // 处理引用
  rp->process_discovered_references(
    &is_alive,          // 存活判断闭包
    &keep_alive,        // 保持存活闭包
    &drain_queue,       // 清空队列闭包
    NULL,               // 不需要执行器
    _gc_timer_stw
  );
  
  // 2. 处理 JNI Weak
  JNIHandles::weak_oops_do(&is_alive, &keep_alive);
  
  // 3. 处理 String Deduplication
  if (G1StringDedup::is_enabled()) {
    G1StringDedup::unlink_or_oops_do(&is_alive, &keep_alive);
  }
}
```

**引用类型处理**：

```
1. SoftReference：
   - 根据 JVM 内存压力决定是否清除
   - 策略：LRU（最近最少使用）
   
2. WeakReference：
   - 如果引用对象不可达（不在 CSet 或已死亡）
   - 清除引用
   
3. PhantomReference：
   - 引用对象已 Finalize
   - 入队到 ReferenceQueue
   
4. Finalizer：
   - 对象 finalize() 方法需要执行
   - 临时保持存活

示例：
  SoftReference<Object> softRef;
  
  GC 前：
    softRef → Object A（在 Eden）
  
  GC 时：
    - A 在 CSet
    - A 存活 → 复制到 Survivor
    - softRef 引用更新 → 指向新地址
  
  如果内存压力大：
    - A 可能被清除
    - softRef = null
```

### 5.2 刷新 PLAB 统计

```cpp
// src/hotspot/share/gc/g1/g1CollectedHeap.cpp（伪代码）
void G1CollectedHeap::flush_plab_stats() {
  // 刷新所有线程的 PLAB
  for (uint i = 0; i < n_workers; i++) {
    G1ParScanThreadState* pss = pss_set->state_for_worker(i);
    pss->flush();
  }
  
  // 调整 PLAB 大小
  _survivor_evac_stats.adjust_desired_plab_sz();
  _old_evac_stats.adjust_desired_plab_sz();
}
```

### 5.3 释放 CSet Regions

```cpp
// src/hotspot/share/gc/g1/g1CollectedHeap.cpp（伪代码）
void G1CollectedHeap::free_cset_regions() {
  // 遍历 CSet
  for (HeapRegion* hr : collection_set()) {
    // 1. 回收 Region
    free_region(hr);
    
    // 2. 添加到空闲列表
    _hrm.insert_into_free_list(hr);
  }
}

void G1CollectedHeap::free_region(HeapRegion* hr) {
  // 1. 清空 RSet
  hr->rem_set()->clear();
  
  // 2. 重置 Region 类型
  hr->set_free();
  
  // 3. 清空 Region 内容
  hr->clear();
  
  // 4. 更新统计
  _summary_bytes_used -= hr->used();
}
```

---

## 6. 阶段四：GC 后处理

### 6.1 调整年轻代大小

```cpp
// src/hotspot/share/gc/g1/g1Policy.cpp（伪代码）
void G1Policy::record_collection_pause_end() {
  // 1. 记录 GC 时间
  double elapsed_ms = _gc_timer->elapsed_time_ms();
  
  // 2. 更新预测模型
  _predictor->update(elapsed_ms);
  
  // 3. 调整年轻代大小
  adjust_young_list_length();
  
  // 4. 更新 IHOP（如需要）
  if (need_to_update_ihop()) {
    update_ihop();
  }
  
  // 5. 判断是否需要并发标记
  if (need_to_start_concurrent_mark()) {
    initiate_concurrent_mark();
  }
}

void G1Policy::adjust_young_list_length() {
  // 目标：暂停时间接近目标，但不超时
  
  double target_pause_time_ms = max_pause_time_ms();
  double actual_pause_time_ms = last_pause_time_ms();
  
  if (actual_pause_time_ms > target_pause_time_ms * 1.1) {
    // 暂停时间过长，减少年轻代
    decrease_young_list_length();
  } else if (actual_pause_time_ms < target_pause_time_ms * 0.8) {
    // 暂停时间过短，增加年轻代
    increase_young_list_length();
  }
}
```

**调整策略示例**：

```
场景：
  目标暂停时间：200 ms
  实际暂停时间：250 ms（超时 25%）
  
调整：
  当前年轻代：100 个 Region（400 MB）
  调整后：80 个 Region（320 MB）
  
原因：
  - 减少存活对象数量
  - 减少复制时间
  - 降低暂停时间

下次 GC：
  实际暂停时间：180 ms
  → 在目标范围内
  → 保持年轻代大小
```

### 6.2 更新预测模型

```cpp
// src/hotspot/share/gc/g1/g1Policy.cpp（伪代码）
void G1Policy::update_predictions() {
  // 1. 记录各项指标
  _cost_per_card_scan_ms->sample(cost_per_card_scan);
  _cost_per_card_update_ms->sample(cost_per_card_update);
  _cost_per_code_root_scan_ms->sample(cost_per_code_root_scan);
  _cost_per_copy_ms->sample(cost_per_copy);
  
  // 2. 更新存活率
  _survival_rate->sample(survival_rate);
  
  // 3. 更新其他预测
  _constant_other_time_ms->sample(constant_other_time);
  _young_other_cost_per_region_ms->sample(young_other_cost);
}
```

### 6.3 触发并发标记

```cpp
// src/hotspot/share/gc/g1/g1Policy.cpp（伪代码）
bool G1Policy::need_to_start_concurrent_mark() {
  // 条件1：老年代使用率达到 IHOP
  size_t old_bytes_used = old_regions_used_bytes();
  size_t old_capacity = old_regions_capacity_bytes();
  double old_occupancy = (double)old_bytes_used / old_capacity;
  
  if (old_occupancy > _ihop) {
    return true;
  }
  
  // 条件2：连续 Young GC 后需要标记
  if (_young_gc_counter > YoungGCCounterThreshold) {
    return true;
  }
  
  return false;
}
```

---

## 7. 关键数据流转

### 7.1 对象生命周期

```
1. 对象分配：
   TLAB → Eden Region
   
2. 第一次 Young GC：
   Eden → Survivor Region
   年龄 = 1
   
3. 第二次 Young GC：
   Survivor → Survivor Region
   年龄 = 2
   
   ...

N. 第 N 次 Young GC：
   年龄 >= 晋升阈值（默认 15）
   Survivor → Old Region

或：
   Survivor 空间不足
   Survivor → Old Region（过早晋升）

或：
   对象大小 > Region 一半
   直接分配到 Old Region（大对象）
```

### 7.2 引用更新流程

```
1. 根集扫描阶段：
   根引用 → 对象 A（在 CSet）
   ├─→ 复制 A 到 A'
   ├─→ 更新根引用 → A'
   └─→ 扫描 A' 的字段 → [ref1, ref2]

2. Evacuation 阶段：
   ref1 → 对象 B（在 CSet）
   ├─→ 复制 B 到 B'
   ├─→ 更新 ref1 → B'
   └─→ 扫描 B' 的字段 → [ref3, ref4]

3. 更新 RSet 阶段：
   ref3 → 对象 C（不在 CSet，在 Old）
   ├─→ 标记脏卡
   └─→ 入队 DCQ

4. GC 后期：
   批量处理 DCQ
   ├─→ 更新 Old Region 的 RSet
   └─→ 记录跨 Region 引用
```

### 7.3 统计数据聚合

```
每个线程独立统计：
  G1ParScanThreadState {
    _surviving_young_words: [100, 150, 80, ...]  // 每个年轻代 Region 的存活字数
    _plab_allocator: {
      _surviving_alloc_buffer: {
        _allocated: 5000 words
        _wasted: 200 words
        _undo_wasted: 50 words
      }
      _tenured_alloc_buffer: {
        _allocated: 10000 words
        _wasted: 300 words
        _undo_wasted: 100 words
      }
    }
  }

GC 结束时聚合：
  1. 遍历所有线程状态
  2. 累加存活字数
  3. 计算每个 Region 的存活比例
  4. 更新预测模型
```

---

## 8. GDB 验证脚本

### 8.1 观察完整 GC 流程

```gdb
# gdb_script: observe_young_gc_flow.gdb

# GC 开始
break G1CollectedHeap::collect
commands
  printf "\n=== GC Triggered ===\n"
  printf "cause: %d\n", $rdi
  continue
end

# 根集扫描
break G1RootProcessor::evacuate_roots
commands
  printf "\n=== Root Scanning ===\n"
  printf "worker_id: %d\n", $rsi
  continue
end

# 对象复制
break G1ParScanThreadState::copy_to_survivor_space
commands
  printf "\n=== Object Copy ===\n"
  continue
end

# Work Stealing
break G1ParScanThreadState::steal_and_trim_queue
commands
  printf "\n=== Work Stealing ===\n"
  continue
end

# 引用处理
break ReferenceProcessor::process_discovered_references
commands
  printf "\n=== Reference Processing ===\n"
  continue
end

run
```

### 8.2 统计各阶段耗时

```gdb
# gdb_script: stat_gc_phases.gdb

set $root_scan_time = 0.0
set $scan_rs_time = 0.0
set $evac_time = 0.0
set $ref_proc_time = 0.0

define print_gc_stats
  printf "\n=== GC Phase Statistics ===\n"
  printf "Root Scanning:    %.2f ms\n", $root_scan_time * 1000
  printf "Scan RS:          %.2f ms\n", $scan_rs_time * 1000
  printf "Evacuation:       %.2f ms\n", $evac_time * 1000
  printf "Reference Proc:   %.2f ms\n", $ref_proc_time * 1000
  printf "Total:            %.2f ms\n", ($root_scan_time + $scan_scan_time + $evac_time + $ref_proc_time) * 1000
end

# (gdb) print_gc_stats
```

### 8.3 观察对象存活情况

```gdb
# gdb_script: observe_survival.gdb

break G1ParScanThreadState::flush
commands
  printf "\n=== Flush Thread State ===\n"
  
  set $pss = (G1ParScanThreadState*)this
  
  # 查看 PLAB 统计
  set $plab = $pss->_plab_allocator
  
  printf "Survivor PLAB:\n"
  printf "  allocated: %lu words\n", $plab->_surviving_alloc_buffer._allocated
  printf "  wasted:    %lu words\n", $plab->_surviving_alloc_buffer._wasted
  
  printf "Old PLAB:\n"
  printf "  allocated: %lu words\n", $plab->_tenured_alloc_buffer._allocated
  printf "  wasted:    %lu words\n", $plab->_tenured_alloc_buffer._wasted
  
  continue
end

run
```

### 8.4 观察 CSet 变化

```gdb
# gdb_script: observe_cset_changes.gdb

define print_cset_info
  set $heap = (G1CollectedHeap*)Universe::_collectedHeap
  set $cset = $heap->_collection_set
  
  printf "\n=== Collection Set Info ===\n"
  printf "Young regions: %u\n", $cset->_young_region_length
  printf "Old regions:   %u\n", $cset->_old_region_length
  printf "Total bytes:   %lu\n", $cset->_bytes_used_before
end

break G1Policy::finalize_cset
commands
  print_cset_info
  continue
end

# (gdb) print_cset_info
```

---

## 9. 面试级 Q&A

### Q1: Young GC 和 Mixed GC 有什么区别？

**A**: CSet 选择策略不同。

| 维度 | Young GC | Mixed GC |
|------|----------|----------|
| **触发条件** | Eden 填满 | 并发标记后 |
| **CSet 内容** | 年轻代 Region | 年轻代 + 部分老年代 |
| **目标** | 回收年轻代垃圾 | 回收老年代垃圾 |
| **暂停时间** | 较短（30-80 ms） | 较长（50-200 ms） |

**详细对比**：

```
Young GC：
  CSet = 所有 Eden Region + 所有 Survivor Region
  
  示例：
    Eden: 100 个 Region（60 个活跃）
    Survivor: 10 个 Region
    CSet: 70 个 Region（280 MB）
    
  回收：
    - 存活对象复制到 Survivor/Old
    - 死亡对象所在的 Region 释放
    - Eden 重新使用

Mixed GC：
  CSet = 年轻代 Region + 回收价值高的老年代 Region
  
  示例：
    年轻代: 70 个 Region
    老年代: 20 个 Region（垃圾比例 > 50%）
    CSet: 90 个 Region（360 MB）
    
  回收：
    - 存活对象复制到 Survivor/Old
    - 老年代垃圾被回收
    - 减少老年代占用
```

---

### Q2: Work Stealing 如何保证正确性？

**A**: 通过原子操作和终止协议。

**队列设计**：

```
RefToScanQueue：
  - 每个线程一个本地队列
  - pop_local()：本地 pop，无锁
  - pop_global()：全局 pop（窃取），CAS
  - push()：本地 push，无锁

设计：
  - 本地操作优先，无锁快速
  - 窃取操作使用 CAS，保证并发安全
  - 支持全局查询（is_empty()）
```

**终止协议**：

```cpp
// ParallelTaskTerminator
bool offer_termination() {
  // 步骤1：增加已终止线程数
  if (Atomic::add(1, &_n_terminated) == _n_threads) {
    // 所有线程都已终止
    return true;
  }
  
  // 步骤2：等待其他线程
  while (true) {
    // 检查是否有新任务
    if (_queues->has_tasks()) {
      // 有新任务，取消终止
      Atomic::sub(1, &_n_terminated);
      return false;
    }
    
    // 检查是否所有线程都已终止
    if (_n_terminated == _n_threads) {
      return true;
    }
    
    // 短暂睡眠，避免忙等
    os::naked_yield();
  }
}
```

**正确性保证**：

```
场景：4 个线程

T1:
  W0: 本地队列空
      offer_termination() → _n_terminated = 1
      等待...
  
T2:
  W1: 本地队列空
      offer_termination() → _n_terminated = 2
      等待...
  
T3:
  W2: 本地队列有任务
      pop_local() → 处理
      push(new_refs) → 队列有新任务
  
T4:
  W0 和 W1 检查：
    _queues->has_tasks() = true
    取消终止，_n_terminated = 0
  
T5:
  W0: steal(W2) → 成功
      处理窃取的任务
      可能产生新任务
  
T6:
  所有队列空
  _n_terminated = 4
  所有线程终止
```

---

### Q3: 如何预测 GC 暂停时间？

**A**: 基于历史数据的衰减平均。

**预测公式**：

```
预测暂停时间 = 
  根集扫描时间 + 
  RSet 处理时间 + 
  对象复制时间 + 
  其他固定开销

详细：
  1. 根集扫描时间：
     estimated_time = 
       _root_region_scan_time->davg + 
       _root_region_scan_time->deviation * sigma
  
  2. RSet 处理时间：
     estimated_time = 
       scan_rs_length * cost_per_card_scan->davg +
       update_rs_length * cost_per_card_update->davg
  
  3. 对象复制时间：
     estimated_time = 
       surviving_bytes * cost_per_byte_copy->davg
  
  4. 其他固定开销：
     estimated_time = _constant_other_time->davg
```

**衰减平均**：

```
公式：
  davg = weight * new_val + (1 - weight) * old_davg

默认：
  weight = 0.7
  
示例：
  第1次 GC：actual = 50 ms
    davg = 50 ms
  
  第2次 GC：actual = 55 ms
    davg = 0.7 * 55 + 0.3 * 50 = 53.5 ms
  
  第3次 GC：actual = 48 ms
    davg = 0.7 * 48 + 0.3 * 53.5 = 49.65 ms
  
  第4次 GC：actual = 52 ms
    davg = 0.7 * 52 + 0.3 * 49.65 = 51.295 ms
  
  预测：~51 ms

特点：
  - 近期数据权重高
  - 快速适应变化
  - 平滑历史波动
```

**标准差修正**：

```
预测区间：
  prediction = davg + sigma * stddev
  
默认：
  sigma = 0.5
  
示例：
  davg = 50 ms
  stddev = 10 ms
  sigma = 0.5
  
  prediction = 50 + 0.5 * 10 = 55 ms
  
  意味着：
    - 有一定缓冲
    - 避免过于乐观
    - 提高成功率
```

---

### Q4: 如何处理 Evacuation Failure？

**A**: 对象自转发，保留在原 Region。

**触发条件**：

```
1. 老年代空间不足：
   - 无法分配 Survivor/Old Region
   - 无法扩展堆

2. PLAB 分配失败：
   - 无法申请新 PLAB
   - 无法直接从 Region 分配

3. 大对象分配失败：
   - 无法找到连续 Region
   - 大对象需要特殊处理
```

**处理流程**：

```cpp
// src/hotspot/share/gc/g1/g1ParScanThreadState.cpp（伪代码）
oop handle_evacuation_failure_par(oop old, markOop m) {
  // 步骤1：尝试自转发
  oop forward_ptr = old->forward_to_atomic(old, memory_order_relaxed);
  
  if (forward_ptr == NULL) {
    // 步骤2：自转发成功
    // 标记对象（避免重复处理）
    old->set_mark(old->mark()->set_marked());
    
    // 步骤3：标记 Region 为 evacuation_failed
    HeapRegion* r = _g1h->heap_region_containing(old);
    r->set_evacuation_failed(true);
    
    // 步骤4：扫描对象引用
    old->oop_iterate_backwards(&_scanner);
    
    // 步骤5：记录失败
    _evacuation_failed = true;
    
    return old;
  } else {
    // 其他线程已处理
    return forward_ptr;
  }
}
```

**后果**：

```
1. Region 保留：
   - CSet Region 不被释放
   - 下次 GC 再次尝试回收

2. 性能影响：
   - 增加暂停时间（对象保留，需要重新扫描）
   - 降低吞吐量（重复回收）
   - 可能触发 Full GC

3. 日志输出：
   [GC evacuation failure] Evacuation failure happened
   
   后续：
   - 打印详细错误日志
   - 可能触发 Full GC
   - 建议扩容或调整参数
```

**应对措施**：

```
1. 扩容堆：
   -XX:MaxHeapSize=16g

2. 调整 IHOP：
   -XX:InitiatingHeapOccupancyPercent=35

3. 增加年轻代：
   -XX:G1NewSizePercent=30
   -XX:G1MaxNewSizePercent=50

4. 增加 GC 线程：
   -XX:ParallelGCThreads=16

5. 减少晋升：
   -XX:MaxTenuringThreshold=20
```

---

### Q5: 如何优化 Young GC 性能？

**A**: 多维度优化。

**1. 年轻代大小优化**：

```
调整策略：
  -XX:G1NewSizePercent=5-10     # 最小年轻代比例
  -XX:G1MaxNewSizePercent=60    # 最大年轻代比例
  -XX:G1MaxNewSizePercent=40    # 建议值
  
原理：
  - 年轻代大：GC 频率低，但暂停时间长
  - 年轻代小：暂停时间短，但 GC 频繁
  
权衡：
  - 根据应用特点调整
  - 短生命周期对象多 → 增大年轻代
  - 长生命周期对象多 → 减小年轻代
```

**2. 并行度优化**：

```
调整：
  -XX:ParallelGCThreads=8-16    # GC 线程数
  
原则：
  - CPU 核心数 × 5/8
  - 例如：8 核 CPU → 5 线程
  - 例如：16 核 CPU → 10 线程
  
过多：
  - 线程竞争增加
  - Work Stealing 开销大
  - 性能下降

过少：
  - 并行度低
  - GC 时间长
```

**3. PLAB 优化**：

```
调整：
  -XX:G1PLABSize=4k-16k        # PLAB 大小
  -XX:ResizePLAB=true          # 自适应调整
  
优化：
  - 浪费多 → 减小 PLAB
  - Refill 频繁 → 增大 PLAB
  - 自适应通常效果最好
```

**4. RSet 优化**：

```
调整：
  -XX:G1RSetRegionEntries=256  # RSet 入口数
  -XX:G1RSetSparseRegionEntries=8
  
优化：
  - 减少跨 Region 引用
  - 合理设计对象分布
  - 避免过多跨代引用
```

**5. 对象分配优化**：

```
优化：
  1. 减少 TLAB 分配失败：
     -XX:TLABSize=1m
  
  2. 减少大对象：
     - 拆分大数组
     - 避免超大对象
  
  3. 减少晋升：
     -XX:MaxTenuringThreshold=20
```

---

### Q6: 如何理解 G1 的停顿预测模型？

**A**: 基于衰减平均 + 标准差 + 历史数据。

**预测模型架构**：

```
┌─────────────────────────────────────────────────────────────┐
│                    G1 预测模型                               │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  输入：                                                     │
│    - CSet 大小                                             │
│    - 存活对象估计                                           │
│    - RSet 大小                                             │
│    - 根集大小                                               │
│                                                             │
│  预测组件：                                                 │
│    ├─→ TruncatedSeq（衰减序列）                            │
│    │   - cost_per_card_scan                                │
│    │   - cost_per_card_update                              │
│    │   - cost_per_code_root_scan                           │
│    │   - cost_per_byte_copy                                │
│    │   - constant_other_time                               │
│    │   - young_other_cost_per_region                       │
│    │   - non_young_other_cost_per_region                   │
│    │                                                       │
│    └─→ 衰减平均算法：                                      │
│        davg = weight * new_val + (1 - weight) * old_davg  │
│        stddev = sqrt(variance)                             │
│        prediction = davg + sigma * stddev                  │
│                                                             │
│  输出：                                                     │
│    - 预测暂停时间                                           │
│    - 决策：是否执行 GC                                      │
│    - 调整：年轻代大小                                       │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**预测示例**：

```
场景：准备执行 Young GC

输入：
  CSet 大小：70 个 Region
  存活对象估计：30 MB
  RSet 大小：1000 张卡
  根集大小：5000 个引用

预测计算：

1. 根集扫描时间：
   prediction = 5 ms（基于历史数据）

2. RSet 处理时间：
   cost_per_card_scan = 0.001 ms
   scan_rs_time = 1000 * 0.001 = 1 ms

3. 对象复制时间：
   cost_per_byte_copy = 0.0001 ms/byte
   copy_time = 30 MB * 0.0001 = 3 ms

4. 其他固定开销：
   constant_other_time = 5 ms

总预测：
  total = 5 + 1 + 3 + 5 = 14 ms

决策：
  预测 14 ms < 目标 200 ms
  → 执行 Young GC

实际结果：
  actual = 18 ms
  → 更新预测模型
```

**自适应调整**：

```
场景：连续几次 GC 超时

第1次 GC：
  预测：15 ms
  实际：25 ms
  误差：+10 ms
  
第2次 GC：
  预测：20 ms（模型调整）
  实际：28 ms
  误差：+8 ms
  
第3次 GC：
  预测：24 ms（继续调整）
  实际：22 ms
  误差：-2 ms

调整策略：
  - 减少年轻代大小
  - 降低 CSet 大小
  - 调整预测参数

结果：
  预测逐渐准确
  实际暂停时间接近目标
```

---

## 总结

**G1 Young GC 的核心价值**：

1. **可预测暂停**：基于预测模型控制暂停时间
2. **并行高效**：Work Stealing + PLAB 优化
3. **增量回收**：只回收部分 Region，不 Full GC
4. **自适应**：根据 GC 表现动态调整参数

**关键数据**：
- 标准暂停时间：30-80 ms
- 根集扫描：10-20%
- RSet 处理：10-15%
- 对象复制：50-70%

**已分析模块串联**：
1. G1CardTable → 卡标记，支持 RSet
2. G1HotCardCache → 热卡优化，减少重复处理
3. G1BlockOffsetTable → 对象定位，支持快速遍历
4. G1RootProcessor → 根集扫描，识别存活对象
5. G1ParScanThreadState → Evacuation 执行，对象复制
6. G1PLABAllocator → 快速分配，优化性能
7. G1ScanEvacuatedObjClosure → 引用扫描，更新引用

**下一步学习**：
- G1ConcurrentMark：并发标记流程
- G1MixedGC：老年代回收
- G1FullGC：完整回收流程
