# G1PostEvacuateCleanup 专家级分析

> **文档版本**: v1.0  
> **创建时间**: 2026-02-11  
> **源码版本**: OpenJDK 11  
> **目标**: 深入理解 G1 GC 疏散后清理与并发标记状态更新

---

## 1. 问题引入：疏散后还需要做什么？

### 1.1 场景假设

对象疏散（Evacuation）完成后，堆内存中有很多"悬而未决"的状态需要处理：

```
问题1: CSet 中的 Region 已经疏散完毕，如何回收？
        → 需要将这些 Region 归还到空闲列表

问题2: RSet 中的卡表数据如何处理？
        → 需要清理过时的卡片引用

问题3: 引用对象（Soft/Weak/Phantom）如何处理？
        → 需要决定哪些引用对象应该被清除

问题4: 并发标记状态如何更新？
        → Mixed GC 完成后可能需要重置标记状态
```

### 1.2 疏散后清理的核心目标

**目标**：在 GC 暂停结束前完成所有善后工作：

1. **RSet 清理**：清理卡表中的临时数据
2. **引用处理**：处理 discovered references
3. **弱引用清理**：清理不再可达的弱引用对象
4. **Region 回收**：将 CSet Region 归还空闲列表
5. **状态重置**：重置热卡缓存、分配区域等

---

## 2. 疏散后清理架构概览

### 2.1 调用链

```
do_collection_pause_at_safepoint()
    │
    ├── pre_evacuate_collection_set()     ← 疏散前准备
    │
    ├── evacuate_collection_set()         ← 实际疏散（并行）
    │
    ├── post_evacuate_collection_set()    ← 疏散后清理（本分析重点）
    │
    └── free_collection_set()             ← 释放 CSet Region
```

### 2.2 post_evacuate_collection_set 流程

```cpp
// g1CollectedHeap.cpp:4825-4894
void G1CollectedHeap::post_evacuate_collection_set(
    EvacuationInfo &evacuation_info,
    G1ParScanThreadStateSet *per_thread_states) 
{
    // 1. RSet 清理
    g1_rem_set()->cleanup_after_oops_into_collection_set_do();
    
    // 2. 引用处理
    process_discovered_references(per_thread_states);
    
    // 3. 弱引用处理
    WeakProcessor::weak_oops_do(&is_alive, &keep_alive);
    
    // 4. 字符串去重
    if (G1StringDedup::is_enabled()) {
        G1StringDedup::unlink_or_oops_do(...);
    }
    
    // 5. 疏散失败恢复
    if (evacuation_failed()) {
        restore_after_evac_failure();
    }
    
    // 6. 释放 GC 分配区域
    _allocator->release_gc_alloc_regions(evacuation_info);
    
    // 7. 合并线程统计
    merge_per_thread_state_info(per_thread_states);
    
    // 8. 重置热卡缓存
    _hot_card_cache->reset_hot_cache();
    _hot_card_cache->set_use_cache(true);
    
    // 9. 代码根清理
    purge_code_root_memory();
    
    // 10. 重新标记卡片
    redirty_logged_cards();
    
    // 11. 更新派生指针表
    DerivedPointerTable::update_pointers();
    
    // 12. 打印年龄表
    g1_policy()->print_age_table();
}
```

---

## 3. 详细步骤分析

### 3.1 RSet 清理

```cpp
// 清理卡表中的临时重复检测信息
g1_rem_set()->cleanup_after_oops_into_collection_set_do();
```

**作用**：
- 清理 UpdateRS/ScanRS 期间使用的临时卡表数据
- 移除指向已回收 Region 的过时卡片引用

### 3.2 引用处理

```cpp
// 处理发现的引用对象
process_discovered_references(per_thread_states);
```

**处理流程**：
```
Discovered References
    │
    ├── SoftReference ──► 根据内存压力决定是否清除
    ├── WeakReference ──► 清除不可达引用
    ├── PhantomReference ──► 加入引用队列
    └── FinalReference ──► 触发 finalize()
```

**注意**：必须在释放 GC 分配区域前完成，因为可能需要复制一些可达的引用对象。

### 3.3 弱引用处理

```cpp
G1STWIsAliveClosure is_alive(this);
G1KeepAliveClosure keep_alive(this);

WeakProcessor::weak_oops_do(&is_alive, &keep_alive);
```

**作用**：
- 清理不再可达的弱引用对象（如 Class 元数据、JVM 内部数据结构等）
- 保持仍然可达的弱引用对象

### 3.4 字符串去重

```cpp
if (G1StringDedup::is_enabled()) {
    G1StringDedup::unlink_or_oops_do(&is_alive, &keep_alive, ...);
}
```

**条件**：仅在启用 `-XX:+UseStringDeduplication` 时执行。

### 3.5 疏散失败恢复

```cpp
if (evacuation_failed()) {
    restore_after_evac_failure();
    NOT_PRODUCT(reset_evacuation_should_fail();)
}
```

**触发条件**：疏散过程中内存不足（Evacuation Failure）

**恢复工作**：
- 回滚部分疏散操作
- 恢复对象的原始状态
- 保留无法疏散的对象在原 Region

### 3.6 释放 GC 分配区域

```cpp
_allocator->release_gc_alloc_regions(evacuation_info);
```

**操作**：
- 释放 Survivor GC 分配区域
- 释放/保留 Old GC 分配区域
- 统计分配 Region 数量到 EvacuationInfo

### 3.7 合并线程统计

```cpp
merge_per_thread_state_info(per_thread_states);
```

**作用**：
- 合并所有 GC 工作线程的统计信息
- 更新全局 GC 指标
- 为预测模型提供输入数据

### 3.8 重置热卡缓存

```cpp
_hot_card_cache->reset_hot_cache();
_hot_card_cache->set_use_cache(true);
```

**作用**：
- 清空热卡缓存（因为 CSet Region 已被回收，缓存计数失效）
- 重新启用热卡缓存

### 3.9 代码根清理

```cpp
purge_code_root_memory();
```

**作用**：
- 清理已回收 Region 的代码根（Code Root）引用
- 更新代码缓存的引用信息

### 3.10 重新标记卡片

```cpp
redirty_logged_cards();
```

**作用**：
- 将 evacuation 期间记录的卡片重新标记为 dirty
- 确保并发 refinement 线程能正确处理这些卡片

### 3.11 更新派生指针表

```cpp
#if COMPILER2_OR_JVMCI
DerivedPointerTable::update_pointers();
#endif
```

**作用**：
- 更新 JIT 编译代码中的派生指针（如对象字段地址）
- 确保编译代码中的对象引用指向新的位置

### 3.12 打印年龄表

```cpp
g1_policy()->print_age_table();
```

**作用**：
- 打印对象年龄分布表（用于 Tenuring Threshold 调优）
- 仅在启用日志时输出

---

## 4. G1CollectorState 状态更新

### 4.1 状态机

```
                    ┌─────────────────────────────────────────────────────────────┐
                    │                     G1CollectorState                         │
                    │                                                              │
    ┌───────────────┼──────────────────────────────────────────────────────────┐  │
    │               │                                                              │  │
    │   Young GC    │   _in_young_only_phase = true                                │  │
    │               │   _in_young_gc_before_mixed = false                          │  │
    │               │   _in_initial_mark_gc = false                                │  │
    │               │   _mark_or_rebuild_in_progress = false                       │  │
    │               │                                                              │  │
    └───────┬───────┼──────────────────────────────────────────────────────────┘  │
            │       │                                                              │
            │       │  Initial Mark GC                                             │
            ▼       │   _in_initial_mark_gc = true                                 │
                    │   _mark_or_rebuild_in_progress = true                        │
    Concurrent      │                                                              │
    Marking Phase   │  During Marking                                              │
            │       │   _in_initial_mark_gc = false                                │
            │       │   _mark_or_rebuild_in_progress = true                        │
            ▼       │                                                              │
                    │  Cleanup Phase                                               │
    Mixed Phase     │   _in_young_only_phase = false                               │
            │       │   _in_young_gc_before_mixed = true (第一个 Mixed GC)         │
            │       │   _mark_or_rebuild_in_progress = true                        │
            ▼       │                                                              │
                    │  After Cleanup                                               │
    Young GC        │   _in_young_only_phase = false                               │
    Resumes         │   _mark_or_rebuild_in_progress = false                       │
            │       │   _clearing_next_bitmap = true                               │
            ▼       │                                                              │
                    │  Concurrent Cleanup End                                      │
                    │   _in_young_only_phase = true (恢复到 Young Only)            │
                    │   _clearing_next_bitmap = false                              │
                    │                                                              │
                    └─────────────────────────────────────────────────────────────┘
```

### 4.2 关键状态字段

| 字段 | 说明 | 典型变化时机 |
|------|------|-------------|
| `_in_young_only_phase` | 仅年轻代 GC 阶段 | Initial Mark 前=true，Cleanup 后=false，Concurrent Cleanup 结束后=true |
| `_in_young_gc_before_mixed` | Mixed GC 前的 Young GC | Cleanup 后=true，第一个 Mixed GC 后=false |
| `_in_initial_mark_gc` | 初始标记 GC | 开始=true，结束=false |
| `_mark_or_rebuild_in_progress` | 标记/重建进行中 | Initial Mark=true，Cleanup 结束=false |
| `_clearing_next_bitmap` | 正在清理 next bitmap | Cleanup 结束=true，Concurrent Cleanup 结束=false |

---

## 5. 与并发标记的交互

### 5.1 Mixed GC 期间的并发标记状态

```cpp
// g1CollectorState.hpp:100-122
bool in_young_only_phase() const { 
  return _in_young_only_phase && !_in_full_gc; 
}

bool in_mixed_phase() const { 
  return !in_young_only_phase() && !_in_full_gc; 
}

G1YCType yc_type() const {
  if (in_initial_mark_gc()) {
    return InitialMark;
  } else if (mark_or_rebuild_in_progress()) {
    return DuringMarkOrRebuild;  // 并发标记进行中
  } else if (in_young_only_phase()) {
    return Normal;
  } else {
    return Mixed;  // Mixed GC
  }
}
```

### 5.2 位图管理

```cpp
// g1ConcurrentMark.cpp:1848-1853
void G1ConcurrentMark::swap_mark_bitmaps() {
  G1CMBitMap* temp = _prev_mark_bitmap;
  _prev_mark_bitmap = _next_mark_bitmap;
  _next_mark_bitmap = temp;
  _g1h->collector_state()->set_clearing_next_bitmap(true);
}
```

**位图切换时机**：
- **Remark Phase 结束时**：交换 Prev/Next 位图
- **Cleanup Phase 开始时**：Next 位图变为 Prev，用于 Mixed GC 存活判断
- **Concurrent Cleanup 结束时**：清理 Next 位图，准备下一轮标记

---

## 6. GDB 运行时验证

### 6.1 验证脚本

```bash
# GDB 验证疏散后清理
cat > /tmp/verify_post_evac.gdb << 'EOF'
set pagination off
attach <JAVA_PID>

# 1. 验证 G1CollectorState
set $state = G1CollectedHeap::_g1h->_collector_state
p *$state

# 2. 验证各个状态字段
p $state->_in_young_only_phase
p $state->_in_young_gc_before_mixed
p $state->_mark_or_rebuild_in_progress
p $state->_clearing_next_bitmap

# 3. 验证并发标记位图
set $cm = G1CollectedHeap::_g1h->_cm
p $cm->_prev_mark_bitmap
p $cm->_next_mark_bitmap

# 4. 验证热卡缓存
p G1CollectedHeap::_g1h->_hot_card_cache->_use_cache

# 5. 在 post_evacuate_collection_set 设置断点
break G1CollectedHeap::post_evacuate_collection_set
commands
  p "Entering post_evacuate_collection_set"
  continue
end

continue
EOF

# 运行验证
JAVA_PID=$(pgrep -f "YourJavaApp")
gdb -batch -x /tmp/verify_post_evac.gdb
```

### 6.2 理论预期输出

```
# G1CollectorState（Mixed Phase）
$1 = {
  _in_young_only_phase = false,           // 不在 Young Only Phase
  _in_young_gc_before_mixed = false,      // 不在第一个 Mixed GC
  _in_initial_mark_gc = false,
  _initiate_conc_mark_if_possible = false,
  _mark_or_rebuild_in_progress = true,    // 标记进行中（Cleanup 前）
  _clearing_next_bitmap = false,
  _in_full_gc = false
}

# 并发标记位图
$2 = (G1CMBitMap *) 0x7ffff0059870   // Prev Bitmap（已完成标记）
$3 = (G1CMBitMap *) 0x7ffff00598a8   // Next Bitmap（正在清理）

# 热卡缓存状态
$4 = true   // use_cache
```

---

## 7. GC 日志输出

### 7.1 启用详细日志

```bash
java -Xms8g -Xmx8g -XX:+UseG1GC \
     -Xlog:gc*,gc+remset=debug,gc+ref=debug \
     YourApp
```

### 7.2 日志示例

```
# 疏散后清理开始
[12.345s][debug][gc] Post Evacuate Collection Set

# RSet 清理
[12.345s][debug][gc,remset] Cleanup RSet after oops into collection set

# 引用处理
[12.346s][debug][gc,ref] Process discovered references
[12.346s][debug][gc,ref] SoftReference: 50 discovered, 10 cleared
[12.346s][debug][gc,ref] WeakReference: 100 discovered, 80 cleared
[12.346s][debug][gc,ref] PhantomReference: 20 discovered, 15 cleared

# 弱引用处理
[12.347s][debug][gc] WeakProcessor: processed 500 weak oops

# 热卡缓存重置
[12.348s][debug][gc] Reset hot card cache

# GC 结束
[12.350s][info][gc] GC(10) Pause Young (Mixed) (G1 Evacuation Pause)
    120M->45M(8192M) 25.234ms
```

---

## 8. 性能影响分析

### 8.1 各阶段耗时占比

```
典型 Mixed GC 暂停时间分布（200ms 目标）：

┌─────────────────────────────────────────────────────────────┐
│ 阶段                          耗时        占比              │
├─────────────────────────────────────────────────────────────┤
│ pre_evacuate_collection_set   5ms         2.5%              │
│ evacuate_collection_set       150ms       75%  (并行)       │
│ post_evacuate_collection_set  35ms        17.5%             │
│   - RSet 清理                 5ms                           │
│   - 引用处理                  15ms                          │
│   - 弱引用处理                5ms                           │
│   - 其他清理                  10ms                          │
│ free_collection_set           10ms        5%                │
├─────────────────────────────────────────────────────────────┤
│ 总计                          200ms       100%              │
└─────────────────────────────────────────────────────────────┘
```

### 8.2 优化建议

| 瓶颈 | 症状 | 优化方案 |
|------|------|----------|
| 引用处理耗时 | ref 日志占比 > 20% | 减少 SoftReference 使用 |
| 弱引用过多 | WeakProcessor 耗时高 | 检查 ClassLoader 泄漏 |
| 热卡缓存竞争 | reset_hot_cache 耗时高 | 调整 G1UpdateBufferSize |

---

## 9. 常见问题与面试问答

### Q1: post_evacuate_collection_set 和 free_collection_set 有什么区别？

**答**：
- `post_evacuate_collection_set`：清理和恢复工作（引用处理、状态重置等）
- `free_collection_set`：实际的 Region 释放（归还空闲列表、更新堆统计）

顺序：先 post_evacuate（清理），再 free_collection_set（释放）。

### Q2: 为什么引用处理要在释放 GC 分配区域前完成？

**答**：因为引用处理过程中可能需要复制一些可达的引用对象（及其可达子图）。如果先释放了分配区域，这些对象就没有地方可以复制了。

### Q3: _in_young_only_phase 和 _mark_or_rebuild_in_progress 有什么区别？

**答**：
- `_in_young_only_phase`：表示 GC 类型（Young Only vs Mixed）
- `_mark_or_rebuild_in_progress`：表示并发标记生命周期（从 Initial Mark 到 Cleanup）

可以同时为 true（Initial Mark GC）或 false（正常 Young GC）。

### Q4: 什么时候会触发 evacuation_failed？

**答**：当 Survivor 或 Old 区域不足以容纳所有存活对象时：
- 堆空间不足
- Survivor 空间太小
- 突发的大量对象晋升

需要调用 `restore_after_evac_failure()` 恢复状态。

### Q5: 如何监控疏散后清理的耗时？

**答**：

```bash
# 启用详细阶段日志
-Xlog:gc+phases=trace

# 关注以下指标：
# - Post Evacuate Collection Set 总时间
# - Process References 时间
# - Weak Processing 时间
```

---

## 10. 总结

### 10.1 核心要点

1. **12 个清理步骤**：从 RSet 清理到年龄表打印
2. **引用处理关键**：必须在释放分配区域前完成
3. **状态机复杂**：_in_young_only_phase、_mark_or_rebuild_in_progress 等协同工作
4. **性能敏感**：占 GC 暂停时间的 15-20%

### 10.2 与 Mixed GC 的关系

```
Mixed GC 完整流程：
    
    finalize_collection_set()     ← 选择 CSet（老年代+年轻代）
            │
            ▼
    pre_evacuate_collection_set() ← 准备
            │
            ▼
    evacuate_collection_set()     ← 并行疏散（核心工作）
            │
            ▼
    post_evacuate_collection_set() ← 清理与恢复（本分析重点）
            │
            ▼
    free_collection_set()         ← 释放 Region
            │
            ▼
    eagerly_reclaim_humongous_regions() ← 回收大对象
```

### 10.3 下一步

第四阶段完成！接下来进入 **第五阶段：流程整合**：
- **5.1 Mixed GC 完整流程**：从 IHOP 触发到 Mixed GC 完成的全流程
- **5.2 G1 Full GC 兜底机制**：何时触发、如何避免

---

**文档完成时间**: 2026-02-11  
**验证状态**: ⚠️ 提供完整验证脚本和理论预期值  
**关联文档**: 
- `G1EvacuationInfo-Expert-Analysis.md`（疏散统计）
- `Cleanup-Phase-Expert-Analysis.md`（CSet Chooser 重建）
