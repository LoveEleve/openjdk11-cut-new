# G1 Young GC 逐行深度源码分析 - Part 2

> **延续**: Part 1 (GC触发到工作线程准备)  
> **本章**: Collection Set选择到GC完成  
> **源码文件**: `src/hotspot/share/gc/g1/g1CollectedHeap.cpp`

---

## 第4章: Collection Set选择与准备 (Lines 3692-3724)

### 4.1 finalize_collection_set - CSet最终确定

```cpp
3692:                 g1_policy()->finalize_collection_set(target_pause_time_ms, &_survivor);
```

**Line 3692: CSet最终确定深度解析**

**Collection Set (CSet) 概念：**
```
+------------------------------------------------------------------+
|                    Collection Set (回收集合)                      |
+------------------------------------------------------------------+
|                                                                   |
|  CSet是本次GC要回收的Region集合                                    |
|                                                                   |
|  Young GC的CSet组成：                                              |
|  +---------------------------------------------------------+     |
|  |  1. 所有Eden Region（强制）                               |     |
|  |     - 新对象分配区，每次Young GC必须回收                   |     |
|  |                                                          |     |
|  |  2. 部分Survivor Region（可选）                           |     |
|  |     - 如果Survivor区对象存活少，可能不回收                 |     |
|  |                                                          |     |
|  |  3. 部分Old Region（Mixed GC）                            |     |
|  |     - 根据回收收益选择垃圾最多的老年代Region               |     |
|  +---------------------------------------------------------+     |
|                                                                   |
|  CSet选择目标：在MaxGCPauseMillis内回收最多垃圾                     |
+------------------------------------------------------------------+
```

**finalize_collection_set算法：**
```cpp
void G1Policy::finalize_collection_set(double target_pause_time_ms, SurvivorRegions* survivor) {
    // 1. 添加所有Eden Region到CSet
    collection_set()->add_eden_regions(eden()->length());
    
    // 2. 计算可用于GC的时间预算
    double time_remaining_ms = predict_young_collection_time();
    
    // 3. 如果是Mixed GC，选择老年代Region
    if (collector_state()->in_mixed_phase()) {
        add_old_regions_to_cset(time_remaining_ms);
    }
    
    // 4. 设置CSet完成标记
    collection_set()->set_fully_initialized();
}
```

**预测模型：**
```
G1使用历史数据预测GC耗时：

predict_young_collection_time() = 
    predict_eden_copy_time() +      // Eden区复制时间
    predict_survivor_copy_time() +  // Survivor区复制时间
    predict_root_scan_time() +      // 根扫描时间
    predict_remembered_set_scan_time() +  // RSet扫描时间
    predict_other_time()            // 其他开销
```

---

### 4.2 记忆集清理与巨型对象注册

```cpp
3696:                 g1_rem_set()->cleanupHRRS();
3703:                 register_humongous_regions_with_cset();
```

**Line 3697: cleanupHRRS() - 热卡缓存清理**

GC开始前必须确保所有脏卡已处理，否则RSet不完整。

**Line 3703: 巨型对象注册**

检查StartsHumongous Region，如果只有来自CSet的引用且CSet将回收，可以积极回收。

---

### 4.3 GC分配区初始化

```cpp
3717:                 _allocator->init_gc_alloc_regions(evacuation_info);
3719:                 G1ParScanThreadStateSet per_thread_states(this, workers()->active_workers(),
3720:                                                           collection_set()->young_region_length());
3724:                 evacuate_collection_set(&per_thread_states);
```

**Line 3717: 初始化GC分配区**
- Survivor GC Alloc Region
- Old GC Alloc Region
- PLAB (每个线程本地分配缓冲区)

**Line 3719-3720: 并行扫描状态创建**
为每个工作线程创建独立的扫描状态，避免线程竞争。

**Line 3724: evacuate_collection_set - 核心复制操作**

---

## 第5章: 对象复制与疏散

### 5.1 对象复制详细流程

**复制算法：**
```cpp
oop G1ParScanThreadState::copy_to_survivor_space(oop old_obj) {
    // 1. 检查对象是否已转发
    if (old_obj->is_forwarded()) {
        return old_obj->forwardee();
    }
    
    // 2. 分配新对象空间
    HeapWord* new_addr = allocate_in_plab(word_size);
    
    // 3. 复制对象数据
    Copy::aligned_disjoint_words((HeapWord*)old_obj, new_addr, word_size);
    
    // 4. 设置转发指针
    old_obj->forward_to((oop)new_addr);
    
    return (oop)new_addr;
}
```

**转发指针机制：**
- 复用对象头的Mark Word存储新地址
- 其他引用访问时先检查转发指针
- 确保所有引用指向新对象

---

## 第6章: GC后处理与完成

### 6.1 疏散后处理

```cpp
3726:                 post_evacuate_collection_set(evacuation_info, &per_thread_states);
3729:                 free_collection_set(&_collection_set, evacuation_info, surviving_young_words);
3731:                 eagerly_reclaim_humongous_regions();
```

**Line 3726: 后处理**
- 处理引用队列（Soft/Weak/Phantom）
- 清理卡表
- 更新RSet

**Line 3729: 释放CSet**
重置Region状态，Eden Region清空并加入空闲列表。

**Line 3731: 巨型对象积极回收**
检查只有CSet引用的巨型对象，直接回收。

### 6.2 PLAB调整与堆扩展

```cpp
3734:                 _survivor_evac_stats.adjust_desired_plab_sz();
3735:                 _old_evac_stats.adjust_desired_plab_sz();
3772:                 size_t expand_bytes = _heap_sizing_policy->expansion_amount();
3777:                 expand(expand_bytes, _workers, &expand_ms);
```

**Line 3734-3735: 自适应PLAB大小**
根据PLAB浪费率动态调整大小，目标浪费率<10%。

**Line 3772-3777: 堆扩展**
如果GC后内存仍然紧张，提交新的Region。

### 6.3 GC结束

```cpp
3757:                 if (collector_state()->in_initial_mark_gc()) {
3761:                     concurrent_mark()->post_initial_mark();
3762:                 }
3796:                 g1_policy()->record_collection_pause_end(pause_time_ms, ...);
3828:         g1_policy()->print_phases();
```

**Line 3757-3762: 启动并发标记**
如果是Initial Mark，通知并发标记线程开始工作。

**Line 3796: 记录GC统计**
记录实际暂停时间，用于预测模型调整。

**Line 3828: 打印GC详情**
输出各阶段耗时统计。

---

## Young GC完整流程总结

```
+==================================================================+
|                    G1 Young GC 完整流程                           |
+==================================================================+
|                                                                   |
|  1. 触发阶段                                                       |
|     +- Eden区满 / System.gc() / 大对象分配失败                     |
|     +- G1CollectedHeap::collect()                                 |
|     +- 创建VM_G1CollectForAllocation操作                          |
|                                                                   |
|  2. VM操作执行 (Safepoint)                                         |
|     +- VMThread执行doit()                                         |
|     +- 判断是否Initial Mark                                       |
|     +- 调用do_collection_pause_at_safepoint()                     |
|                                                                   |
|  3. GC暂停执行                                                     |
|     +- finalize_collection_set() - 确定CSet                       |
|     +- evacuate_collection_set() - 核心复制操作                    |
|     |   +- 根扫描                                                  |
|     |   +- RSet扫描                                                |
|     |   +- 对象复制（Eden->Survivor->Old）                         |
|     +- free_collection_set() - 释放CSet                           |
|     +- 堆扩展（如需要）                                            |
|                                                                   |
|  4. 并发阶段（如果是Initial Mark）                                  |
|     +- 启动Concurrent Mark Thread                                  |
|                                                                   |
+==================================================================+
```

---

**文档完成**

已完成G1 Young GC的逐行深度分析，涵盖GC触发、VM操作、CSet选择、对象复制、GC后处理等完整流程。
