# G1 Mixed GC 逐行深度源码分析

> **分析目标**: G1 Mixed GC（空间回收阶段）完整流程  
> **源码文件**: 
> - `src/hotspot/share/gc/g1/g1Policy.cpp`
> - `src/hotspot/share/gc/g1/g1CollectionSet.cpp`  

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

Mixed GC 的本质是**Young GC + 部分 Old Region 回收的组合**：在 Young GC 的基础上，额外将部分 Old Region 加入 CSet（由 `CollectionSetChooser` 按垃圾密度排序选取）；Mixed GC 在并发标记完成后触发，持续进行直到 Old 区占用率降到 `G1HeapWastePercent` 以下。

### 0.2 触发条件

1. 并发标记周期完成（Cleanup 阶段完成）
2. Old 区占用率 > `G1HeapWastePercent`（默认 5%）
3. 有足够的 Old Region 候选（`CollectionSetChooser` 非空）

### 0.3 Mixed GC 与 Young GC 的区别

| 特性 | Young GC | Mixed GC |
|------|---------|---------|
| CSet 组成 | Eden + Survivor | Eden + Survivor + 部分 Old |
| 触发条件 | Eden 满 | 并发标记完成 + Old 区占用高 |
| 持续次数 | 每次 Eden 满触发 | 连续多次（直到 Old 区占用降低） |
| 停顿时间 | 较短 | 略长（多了 Old Region 的 Evacuation） |

### 0.4 为什么这样设计？

- **为什么 Mixed GC 要连续多次？** 一次 Mixed GC 只回收部分 Old Region（停顿时间限制）；需要多次 Mixed GC 才能将 Old 区占用率降到目标以下
- **为什么 Mixed GC 在并发标记完成后才触发？** Mixed GC 需要知道 Old Region 的存活率（决定哪些 Region 值得回收）；并发标记提供这些数据

---
> **分析标准**: 面试级深度 - 逐行解释 + 面试问答 + GDB调试技巧

---

## 第1章: Mixed GC触发条件与决策

### 1.1 何时进入Mixed GC阶段

```cpp
1035: void G1Policy::record_concurrent_mark_cleanup_end() {
1036:   cset_chooser()->rebuild(_g1h->workers(), _g1h->num_regions());
1037:
1038:   bool mixed_gc_pending = next_gc_should_be_mixed("request mixed gcs", "request young-only gcs");
1039:   if (!mixed_gc_pending) {
1040:     clear_collection_set_candidates();
1041:     abort_time_to_mixed_tracking();
1042:   }
1043:   collector_state()->set_in_young_gc_before_mixed(mixed_gc_pending);
1044:   collector_state()->set_mark_or_rebuild_in_progress(false);
```

**Line 1035-1044: Cleanup阶段后的Mixed GC决策**

**调用时机：**
```
Concurrent Mark Cleanup阶段结束
  └─ record_concurrent_mark_cleanup_end()
       └─ 决定是否进入Mixed GC阶段
```

**Line 1036: cset_chooser()->rebuild()**

```cpp
cset_chooser()->rebuild(workers, num_regions);
```

**CSet Chooser重建：**
```
+------------------------------------------------------------------+
|                    CSet Chooser 重建流程                          |
+------------------------------------------------------------------+
|                                                                   |
|  1. 遍历所有老年代Region                                           |
|     - 检查Region的标记结果（通过prev_mark_bitmap）                 |
|                                                                   |
|  2. 计算每个Region的回收效率                                        |
|     效率 = 可回收字节数 / 预计处理时间                              |
|                                                                   |
|  3. 按效率降序排序                                                 |
|     - 效率高的Region排在前面                                       |
|     - 优先回收收益高的Region                                       |
|                                                                   |
|  4. 构建候选Region列表                                             |
|     - 只有标记过的Region才加入列表                                  |
|     - 记录每个Region的可回收字节数                                  |
+------------------------------------------------------------------+
```

### 1.2 next_gc_should_be_mixed - Mixed GC决策核心

```cpp
1132: bool G1Policy::next_gc_should_be_mixed(const char* true_action_str,
1133:                                          const char* false_action_str) const {
1134:   if (cset_chooser()->is_empty()) {
1135:     log_debug(gc, ergo)("%s (candidate old regions not available)", false_action_str);
1136:     return false;
1137:   }
1138:
1139:   // Is the amount of uncollected reclaimable space above G1HeapWastePercent?
1140:   size_t reclaimable_bytes = cset_chooser()->remaining_reclaimable_bytes();
1141:   double reclaimable_percent = reclaimable_bytes_percent(reclaimable_bytes);
1142:   double threshold = (double) G1HeapWastePercent;
1143:   if (reclaimable_percent <= threshold) {
1144:     log_debug(gc, ergo)("%s (reclaimable percentage not over threshold). "
1145:                         "candidate old regions: %u reclaimable: " SIZE_FORMAT " (%1.2f) threshold: " UINTX_FORMAT,
1146:                         false_action_str, cset_chooser()->remaining_regions(),
1147:                         reclaimable_bytes, reclaimable_percent, G1HeapWastePercent);
1148:     return false;
1149:   }
1150:   log_debug(gc, ergo)("%s (reclaimable old regions available). "
1151:                       "candidate old regions: %u reclaimable: " SIZE_FORMAT " (%1.2f) threshold: " UINTX_FORMAT,
1152:                       true_action_str, cset_chooser()->remaining_regions(),
1153:                       reclaimable_bytes, reclaimable_percent, G1HeapWastePercent);
1154:   return true;
1155: }
```

**Line 1132-1155: Mixed GC触发条件深度解析**

**两个关键条件：**

| 条件 | 说明 | 参数 |
|------|------|------|
| 候选Region非空 | CSet Chooser中有标记过的老年代Region | - |
| 可回收空间足够 | 可回收空间占比 > G1HeapWastePercent | 默认5% |

**G1HeapWastePercent参数：**
```
-XX:G1HeapWastePercent=5（默认）

含义：当可回收空间占堆总大小的比例超过5%时，才进行Mixed GC

为什么需要这个阈值？
- 如果可回收空间太少（如1%）
- Mixed GC的收益很低
- 但暂停时间开销仍然存在
- 不如等到积累更多垃圾再回收

计算示例（8GB堆）：
- 堆大小：8GB
- 阈值：5%
- 可回收空间 > 8GB * 5% = 409.6MB 才触发Mixed GC
```

**面试高频问题Q&A：**

**Q1: 为什么需要G1HeapWastePercent阈值？不设行不行？**
```
A: 需要阈值的原因：

场景：没有阈值，只要有一个Region可回收就触发Mixed GC

问题：
1. Mixed GC频率过高
   - 每次只回收1-2个Region
   - 暂停时间虽然短，但累积起来很长
   
2. 吞吐量下降
   - GC开销占比增加
   - 应用实际运行时间减少

3. 碎片问题
   - 频繁小粒度回收
   - 可能导致内存碎片

阈值的作用：
- 批量回收：积累足够多的垃圾一次性回收
- 提高效率：单次GC回收更多空间
- 平衡：暂停时间和回收效率的权衡

类比：
就像倒垃圾，不会有一个垃圾就倒一次，
而是等垃圾桶快满了（达到一定阈值）再倒。
```

---

## 第2章: Mixed GC状态转换

### 2.1 收集器状态转换

```cpp
1043:   collector_state()->set_in_young_gc_before_mixed(mixed_gc_pending);
1044:   collector_state()->set_mark_or_rebuild_in_progress(false);
```

**Line 1043-1044: 状态设置深度解析**

**G1收集器状态机：**
```
+------------------------------------------------------------------+
|                    G1 收集器状态转换图                            |
+------------------------------------------------------------------+
|                                                                   |
|  +------------------+                                             |
|  |  Young-Only Phase |                                            |
|  |  (只回收年轻代)   |                                            |
|  +--------+---------+                                             |
|           |                                                       |
|           | IHOP触发 / System.gc()                                 |
|           v                                                       |
|  +------------------+     并发标记完成      +------------------+  |
|  |  Concurrent Mark  |-------------------->|  Mixed GC Phase   |  |
|  |  (并发标记阶段)   |                    |  (空间回收阶段)   |  |
|  +------------------+                    +--------+---------+  |
|                                                  |                |
|                                                  | 可回收空间<=5%  |
|                                                  v                |
|                                         +--------+---------+     |
|                                         |  Young-Only Phase |     |
|                                         |  (回到年轻代阶段)  |     |
|                                         +------------------+     |
|                                                                   |
+------------------------------------------------------------------+
```

**关键状态标志：**

| 状态标志 | 含义 | 设置位置 |
|----------|------|----------|
| `in_young_only_phase()` | 只回收年轻代 | 初始/Mixed GC结束 |
| `in_mixed_phase()` | 回收年轻代+老年代 | Cleanup后 |
| `in_young_gc_before_mixed()` | 准备进入Mixed | Cleanup后设置 |
| `mark_or_rebuild_in_progress()` | 并发标记进行中 | Initial Mark后 |

### 2.2 young_gc_pause_kind - GC类型判断

```cpp
1082: G1Policy::PauseKind G1Policy::young_gc_pause_kind() const {
1083:   assert(!collector_state()->in_full_gc(), "must be");
1084:   if (collector_state()->in_initial_mark_gc()) {
1085:     assert(!collector_state()->in_young_gc_before_mixed(), "must be");
1086:     return InitialMarkGC;
1087:   } else if (collector_state()->in_young_gc_before_mixed()) {
1088:     assert(!collector_state()->in_initial_mark_gc(), "must be");
1089:     return LastYoungGC;
1090:   } else if (collector_state()->in_mixed_phase()) {
1091:     assert(!collector_state()->in_initial_mark_gc(), "must be");
1092:     assert(!collector_state()->in_young_gc_before_mixed(), "must be");
1093:     return MixedGC;
1094:   } else {
1095:     assert(!collector_state()->in_initial_mark_gc(), "must be");
1096:     assert(!collector_state()->in_young_gc_before_mixed(), "must be");
1097:     return YoungOnlyGC;
1098:   }
1099: }
```

**Line 1082-1099: GC暂停类型判断**

**四种GC暂停类型：**

| 类型 | 触发条件 | 回收范围 | 日志标识 |
|------|----------|----------|----------|
| `InitialMarkGC` | IHOP触发 | 年轻代 | (young) (initial-mark) |
| `LastYoungGC` | Mixed GC前 | 年轻代 | (young) (prepare mixed) |
| `MixedGC` | Mixed阶段 | 年轻代+老年代 | (mixed) |
| `YoungOnlyGC` | Eden满 | 年轻代 | (young) (normal) |

**状态转换示例：**
```
时间线：

T1: Young GC (Normal)
    └─ in_young_only_phase() = true
    
T2: Young GC (Initial Mark)
    └─ IHOP触发，开始并发标记
    
T3: Concurrent Mark Running
    └─ mark_or_rebuild_in_progress() = true
    
T4: Young GC (Prepare Mixed)
    └─ Cleanup后，in_young_gc_before_mixed() = true
    
T5: Mixed GC
    └─ in_mixed_phase() = true
    
T6: Mixed GC
    └─ 继续Mixed GC...
    
T7: Young GC (Normal)
    └─ 可回收空间<=5%，回到Young-Only
```

---

## 第3章: finalize_old_part - Mixed GC的CSet选择 (Lines 443-537)

### 3.1 老年代CSet选择入口

```cpp
443: void G1CollectionSet::finalize_old_part(double time_remaining_ms) {
444:   double non_young_start_time_sec = os::elapsedTime();
445:   double predicted_old_time_ms = 0.0;
446:
447:   if (collector_state()->in_mixed_phase()) {
448:     cset_chooser()->verify();
449:     const uint min_old_cset_length = _policy->calc_min_old_cset_length();
450:     const uint max_old_cset_length = _policy->calc_max_old_cset_length();
```

**Line 443-450: Mixed GC CSet选择入口**

**关键参数：**

| 参数 | 默认值 | 含义 |
|------|--------|------|
| `min_old_cset_length` | 动态计算 | 最少选择的老年代Region数 |
| `max_old_cset_length` | 堆的10% | 最多选择的老年代Region数 |

**calc_min_old_cset_length计算：**
```cpp
uint calc_min_old_cset_length() const {
    // 希望在G1MixedGCCountTarget次GC内回收完所有标记的Region
    // 默认G1MixedGCCountTarget = 8
    
    uint marked_regions = cset_chooser()->length();
    uint target_gc_count = G1MixedGCCountTarget;
    
    return (marked_regions + target_gc_count - 1) / target_gc_count;  // 向上取整
}

// 示例：
// 标记了100个Region，目标8次GC
// min_old_cset_length = (100 + 8 - 1) / 8 = 13
// 即每次Mixed GC至少选13个老年代Region
```

### 3.2 老年代Region选择循环

```cpp
455:     HeapRegion* hr = cset_chooser()->peek();
456:     while (hr != NULL) {
457:       if (old_region_length() >= max_old_cset_length) {
458:         // Added maximum number of old regions to the CSet.
459:         log_debug(gc, ergo, cset)("Finish adding old regions to CSet (old CSet region num reached max). "
460:                                   "old %u regions, max %u regions",
461:                                   old_region_length(), max_old_cset_length);
462:         break;
463:       }
464:
465:       // Stop adding regions if the remaining reclaimable space is
466:       // not above G1HeapWastePercent.
467:       size_t reclaimable_bytes = cset_chooser()->remaining_reclaimable_bytes();
468:       double reclaimable_percent = _policy->reclaimable_bytes_percent(reclaimable_bytes);
469:       double threshold = (double) G1HeapWastePercent;
470:       if (reclaimable_percent <= threshold) {
471:         // We've added enough old regions that the amount of uncollected
472:         // reclaimable space is at or below the waste threshold.
473:         log_debug(gc, ergo, cset)("Finish adding old regions to CSet (reclaimable percentage not over threshold). "
474:                                   "old %u regions, max %u regions, reclaimable: " SIZE_FORMAT "B (%1.2f%%) threshold: " UINTX_FORMAT "%%",
475:                                   old_region_length(), max_old_cset_length, reclaimable_bytes, reclaimable_percent, threshold);
476:         break;
477:       }
```

**Line 456-477: Region选择循环 - 终止条件1和2**

**终止条件1（Line 457-462）：达到最大Region数**
```
if (old_region_length() >= max_old_cset_length) break;

目的：限制单次Mixed GC的暂停时间
默认max_old_cset_length = 堆Region总数的10%

8GB堆示例：
- 总Region数：2048
- max_old_cset_length = 2048 * 10% = 205
- 单次Mixed GC最多回收205个老年代Region（约820MB）
```

**终止条件2（Line 470-476）：可回收空间不足**
```
if (reclaimable_percent <= G1HeapWastePercent) break;

目的：避免回收收益太低
当剩余可回收空间 <= 5%时停止

示例：
- 初始可回收空间：1GB（12.5%）
- 已选择Region回收了900MB
- 剩余可回收：100MB（1.25%）< 5%
- 停止添加，留给下次GC
```

### 3.3 时间预算检查与Region添加

```cpp
479:       double predicted_time_ms = predict_region_elapsed_time_ms(hr);
480:       if (check_time_remaining) {
481:         if (predicted_time_ms > time_remaining_ms) {
482:           // Too expensive for the current CSet.
483:
484:           if (old_region_length() >= min_old_cset_length) {
485:             // We have added the minimum number of old regions to the CSet,
486:             // we are done with this CSet.
487:             log_debug(gc, ergo, cset)("Finish adding old regions to CSet (predicted time is too high). "
488:                                       "predicted time: %1.2fms, remaining time: %1.2fms old %u regions, min %u regions",
489:                                       predicted_time_ms, time_remaining_ms, old_region_length(), min_old_cset_length);
490:             break;
491:           }
492:
493:           // We'll add it anyway given that we haven't reached the
494:           // minimum number of old regions.
495:           expensive_region_num += 1;
496:         }
497:       } else {
498:         if (old_region_length() >= min_old_cset_length) {
499:           // In the non-auto-tuning case, we'll finish adding regions
500:           // to the CSet if we reach the minimum.
501:           break;
502:         }
503:       }
504:
505:       // We will add this region to the CSet.
506:       time_remaining_ms = MAX2(time_remaining_ms - predicted_time_ms, 0.0);
507:       predicted_old_time_ms += predicted_time_ms;
508:       cset_chooser()->pop(); // already have region via peek()
509:       _g1h->old_set_remove(hr);
510:       add_old_region(hr);
511:
512:       hr = cset_chooser()->peek();
513:     }
```

**Line 479-512: 时间预算检查与Region添加**

**时间预算逻辑：**
```
+------------------------------------------------------------------+
|                    时间预算决策流程                               |
+------------------------------------------------------------------+
|                                                                   |
|  场景：剩余时间20ms，min=13，max=205                               |
|  当前已选：10个Region                                              |
|                                                                   |
|  下一个Region预测耗时：25ms                                        |
|  ┌─────────────────────────────────────────────────────────┐     |
|  │  if (25ms > 20ms) {  // 时间不够                          │     │
|  │      if (10 >= 13) {  // 已达到最小值？                    │     │
|  │          break;  // 停止添加                              │     │
|  │      } else {                                              │     │
|  │          // 未达到最小值，强制添加                         │     │
|  │          expensive_region_num++;                          │     │
|  │      }                                                     │     │
|  │  }                                                         │     │
|  │  // 添加Region到CSet                                      │     │
|  │  time_remaining -= 25ms;  // 可能变负数                   │     │
|  └─────────────────────────────────────────────────────────┘     |
|                                                                   |
|  为什么允许时间变负数？                                            │
|  - 必须满足min_old_cset_length                                    │
|  - 保证Mixed GC进度（不能拖太久）                                  │
|  - 稍微超时可以接受（预测不完全准确）                               │
+------------------------------------------------------------------+
```

**面试高频问题Q&A：**

**Q2: 为什么需要min_old_cset_length？不设置行不行？**
```
A: min_old_cset_length的作用：

场景：没有min限制，只根据时间选择Region

问题：
1. Mixed GC拖太久
   - 每次只选几个Region
   - 需要几十次Mixed GC才能回收完
   - 老年代垃圾长时间占用内存
   
2. 并发标记周期重叠风险
   - 如果Mixed GC拖太久
   - 下一次并发标记可能已经开始
   - 两个周期重叠，复杂度增加

min_old_cset_length的计算：
- 标记Region数 / 目标GC次数
- 默认目标8次（G1MixedGCCountTarget）
- 保证在8次内回收完

示例：
- 标记了100个Region
- min = 100 / 8 = 13
- 每次Mixed GC至少选13个
- 最多8次完成回收

类比：
就像项目排期，设定里程碑，
确保项目不会无限期拖延。
```

---

## 第4章: Mixed GC执行与退出

### 4.1 Mixed GC执行流程

```cpp
662:     if (!next_gc_should_be_mixed("continue mixed GCs",
663:                                  "do not continue mixed GCs")) {
664:       collector_state()->set_in_young_only_phase(true);
665:
666:       clear_collection_set_candidates();
667:       maybe_start_marking();
668:     }
```

**Line 662-668: Mixed GC退出判断**

**每次Mixed GC后检查：**
```
if (!next_gc_should_be_mixed()) {
    // 退出Mixed GC阶段
    set_in_young_only_phase(true);
    clear_collection_set_candidates();
    
    // 检查是否需要开始新的并发标记
    maybe_start_marking();
}
```

**退出条件（与进入条件相同）：**
1. CSet Chooser为空（所有标记Region已回收）
2. 可回收空间 <= G1HeapWastePercent（5%）

### 4.2 Mixed GC完整生命周期

```
+==================================================================+
|                    Mixed GC 完整生命周期                          |
+==================================================================+
|                                                                   |
|  1. 触发阶段                                                       |
|     └─ Cleanup阶段后，检查可回收空间 > 5%                          │
|                                                                   |
|  2. 准备阶段                                                       |
|     ├─ set_in_young_gc_before_mixed(true)                         │
|     └─ 执行一次Young GC (Prepare Mixed)                            │
|                                                                   |
|  3. Mixed GC阶段（多次）                                           │
|     ├─ finalize_old_part()                                        │
|     │   ├─ 按效率排序选择老年代Region                              │
|     │   ├─ 受min/max/time限制                                     │
|     │   └─ 添加到CSet                                             │
|     ├─ evacuate_collection_set()                                  │
|     │   └─ 复制存活对象（Eden/Survivor/Old -> Survivor/Old）       │
|     └─ 检查是否继续Mixed GC                                        │
|         └─ next_gc_should_be_mixed()                              │
|                                                                   |
|  4. 退出阶段                                                       |
|     ├─ 可回收空间 <= 5% 或 CSet Chooser为空                        │
|     ├─ set_in_young_only_phase(true)                              │
|     └─ 回到Young-Only阶段                                          │
|                                                                   |
+==================================================================+
```

---

## Mixed GC关键参数总结

| 参数 | 默认值 | 说明 |
|------|--------|------|
| G1HeapWastePercent | 5% | 触发/退出Mixed GC的可回收空间阈值 |
| G1MixedGCCountTarget | 8 | 目标Mixed GC次数，影响min_old_cset_length |
| G1OldCSetRegionThresholdPercent | 10% | 单次Mixed GC最大老年代Region占比 |
| G1MixedGCLiveThresholdPercent | 85% | Region存活率超过此值不回收 |

---

**GDB调试脚本：**

```bash
# verify_mixed_gc.gdb
set pagination off

break G1Policy::next_gc_should_be_mixed
break G1CollectionSet::finalize_old_part
break G1Policy::record_concurrent_mark_cleanup_end

run -Xms8g -Xmx8g -XX:+UseG1GC -XX:+PrintGCDetails

# 查看Mixed GC状态
p collector_state()->_in_mixed_phase
p collector_state()->_in_young_gc_before_mixed

# 查看CSet Chooser
p cset_chooser()->_remaining_reclaimable_bytes
p cset_chooser()->_remaining_regions

# 查看min/max限制
p _policy->calc_min_old_cset_length()
p _policy->calc_max_old_cset_length()

continue
quit
```

---

**文档完成**

本文档完成了G1 Mixed GC的逐行深度分析，涵盖：
- Mixed GC触发条件（G1HeapWastePercent）
- 收集器状态转换
- finalize_old_part CSet选择算法
- min/max_old_cset_length限制
- Mixed GC退出条件

下一章将分析：**对象分配** - TLAB、PLAB、快速分配路径
