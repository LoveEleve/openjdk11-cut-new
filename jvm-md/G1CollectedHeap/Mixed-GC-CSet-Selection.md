# Mixed GC CSet 选择专家级分析

> **文档版本**: v1.0  
> **创建时间**: 2026-02-11  
> **源码版本**: OpenJDK 11  
> **目标**: 深入理解 G1 Mixed GC 的 Collection Set 选择机制

---

## 1. 问题引入：为什么需要复杂的 CSet 选择？

### 1.1 场景假设

假设并发标记已完成，G1 知道每个老年代 Region 的存活对象比例。现在需要选择一些老年代 Region 加入 CSet 进行回收：

```
问题1: 全选？
        → 回收时间太长，超出 MaxGCPauseMillis
        → 影响应用延迟

问题2: 随机选？
        → 可能选到存活率 90% 的 Region（回收效率极低）
        → 浪费 CPU 和内存资源

问题3: 只选垃圾最多的？
        → 可能选到 RSet 极大的 Region（扫描耗时）
        → GC 时间仍可能超标
```

### 1.2 CSet 选择的核心目标

**目标**：在目标暂停时间内，选择**回收效率最高**的老年代 Region 集合：

1. **回收效率** = 可回收字节数 / 预测回收时间
2. **时间控制**：严格遵守 MaxGCPauseMillis
3. **自适应调整**：根据历史 GC 数据预测回收时间

---

## 2. CSet 选择架构概览

### 2.1 核心组件关系

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         G1CollectionSet                                      │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ CollectionSetChooser* _cset_chooser                                  │  │
│  │ ├── GrowableArray<HeapRegion*> _regions  [候选 Region 数组]           │  │
│  │ ├── uint _front                          [当前选择位置]               │  │
│  │ ├── uint _end                            [候选总数]                   │  │
│  │ └── size_t _remaining_reclaimable_bytes  [剩余可回收字节]             │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                              │                                               │
│                              ▼                                               │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ finalize_old_part(double time_remaining_ms)                          │  │
│  │ ├── 检查 max_old_cset_length（上限）                                 │  │
│  │ ├── 检查 reclaimable_percent（下限）                                 │  │
│  │ ├── 预测 region 回收时间                                             │  │
│  │ └── 选择满足条件的 Region                                            │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 选择流程时序

```
Cleanup Phase (并发标记结束)
    │
    ▼
┌──────────────────────┐
│ CollectionSetChooser │ ← rebuild() 重建候选列表
│   ::rebuild()        │   (基于标记结果，计算 GC 效率并排序)
└──────────┬───────────┘
           │
           ▼
Mixed GC Pause
    │
    ▼
┌──────────────────────────┐
│ G1CollectionSet          │ ← finalize_young_part()
│   ::finalize_young_part()│   (先确定年轻代 CSet)
└──────────┬───────────────┘
           │
           ▼
┌──────────────────────────┐
│ G1CollectionSet          │ ← finalize_old_part()
│   ::finalize_old_part()  │   (在剩余时间内选择老年代 Region)
└──────────────────────────┘
```

---

## 3. GC 效率计算

### 3.1 核心公式

```cpp
// heapRegion.cpp:142-154
void HeapRegion::calc_gc_efficiency() {
  // GC efficiency = 可回收字节数 / 预测回收时间
  double region_elapsed_time_ms =
    g1p->predict_region_elapsed_time_ms(this, false /* for_young_gc */);
  _gc_efficiency = (double) reclaimable_bytes() / region_elapsed_time_ms;
}
```

**公式**：
```
GC Efficiency = reclaimable_bytes / predict_region_elapsed_time_ms

其中：
- reclaimable_bytes = used_bytes - live_bytes  (可回收字节数)
- predict_region_elapsed_time_ms = 预测扫描 RSet + 复制存活对象的时间
```

### 3.2 预测时间计算

```cpp
// g1Policy.cpp:887-900
double G1Policy::predict_region_elapsed_time_ms(HeapRegion* hr,
                                                bool for_young_gc) const {
  size_t rs_length = hr->rem_set()->occupied();
  
  // 预测时间 = RSet 扫描时间 + 复制时间
  double scan_time_ms = predict_scan_time_ms(rs_length);
  double copy_time_ms = predict_copy_time_ms(hr->live_bytes());
  
  return scan_time_ms + copy_time_ms;
}
```

---

## 4. CollectionSetChooser 详解

### 4.1 数据结构

```cpp
// collectionSetChooser.hpp:31-67
class CollectionSetChooser: public CHeapObj<mtGC> {
  GrowableArray<HeapRegion*> _regions;     // 候选 Region 数组
  
  uint _front;                              // 当前选择位置
  uint _end;                                // 候选 Region 总数
  uint _first_par_unreserved_idx;           // 并行添加时的索引
  
  size_t _region_live_threshold_bytes;      // 存活率阈值
  size_t _remaining_reclaimable_bytes;      // 剩余可回收字节
};
```

### 4.2 候选 Region 筛选条件

```cpp
// collectionSetChooser.cpp:283-288
bool CollectionSetChooser::should_add(HeapRegion* hr) const {
  return !hr->is_young() &&                    // 不是年轻代
         !hr->is_pinned() &&                   // 不是固定 Region
         region_occupancy_low_enough_for_evac(hr->live_bytes()) &&  // 存活率低于阈值
         hr->rem_set()->is_complete();         // RSet 完整
}
```

**阈值计算**：
```cpp
// collectionSetChooser.hpp:104-106
static size_t mixed_gc_live_threshold_bytes() {
  return HeapRegion::GrainBytes * (size_t) G1MixedGCLiveThresholdPercent / 100;
}

// 标准环境（4MB Region，G1MixedGCLiveThresholdPercent=85）：
// 阈值 = 4MB × 85% = 3.4MB
// 即：存活对象超过 3.4MB 的 Region 不会被选为候选
```

### 4.3 排序算法

```cpp
// collectionSetChooser.cpp:41-61
static int order_regions(HeapRegion* hr1, HeapRegion* hr2) {
  double gc_eff1 = hr1->gc_efficiency();
  double gc_eff2 = hr2->gc_efficiency();
  
  if (gc_eff1 > gc_eff2) return -1;   // 效率高的排前面
  if (gc_eff1 < gc_eff2) return 1;
  return 0;
}

void CollectionSetChooser::sort_regions() {
  _regions.sort(order_regions);  // 按 GC 效率降序排序
}
```

**排序后效果**：
```
排序前（随机）：
[Region A: 50%存活] [Region B: 10%存活] [Region C: 30%存活]

排序后（按 GC 效率）：
[Region B: 10%存活, 效率最高] [Region C: 30%存活] [Region A: 50%存活, 效率最低]
```

---

## 5. finalize_old_part 详解

### 5.1 算法流程

```cpp
// g1CollectionSet.cpp:443-542
void G1CollectionSet::finalize_old_part(double time_remaining_ms) {
  if (collector_state()->in_mixed_phase()) {
    const uint min_old_cset_length = _policy->calc_min_old_cset_length();
    const uint max_old_cset_length = _policy->calc_max_old_cset_length();
    
    HeapRegion* hr = cset_chooser()->peek();
    while (hr != NULL) {
      // 1. 检查最大数量限制
      if (old_region_length() >= max_old_cset_length) break;
      
      // 2. 检查可回收空间下限
      size_t reclaimable_bytes = cset_chooser()->remaining_reclaimable_bytes();
      double reclaimable_percent = _policy->reclaimable_bytes_percent(reclaimable_bytes);
      if (reclaimable_percent <= G1HeapWastePercent) break;
      
      // 3. 检查时间预算
      double predicted_time_ms = predict_region_elapsed_time_ms(hr);
      if (predicted_time_ms > time_remaining_ms) {
        if (old_region_length() >= min_old_cset_length) break;
        // 未达到最小数量，强制添加（标记为 expensive）
      }
      
      // 4. 添加到 CSet
      time_remaining_ms -= predicted_time_ms;
      cset_chooser()->pop();
      add_old_region(hr);
      
      hr = cset_chooser()->peek();
    }
  }
}
```

### 5.2 选择条件详解

| 条件 | 默认值 | 说明 |
|------|--------|------|
| `max_old_cset_length` | - | 单次 Mixed GC 最多回收的老年代 Region 数（通常是总 Region 数 × 10%）|
| `min_old_cset_length` | - | 单次 Mixed GC 最少回收的老年代 Region 数 |
| `G1HeapWastePercent` | 5% | 剩余可回收空间低于此阈值时停止添加 |
| `time_remaining_ms` | - | 扣除年轻代回收时间后的剩余时间预算 |

### 5.3 决策流程图

```
开始 finalize_old_part
    │
    ▼
获取候选 Region (peek)
    │
    ▼
Region 为 NULL? ──YES──► 结束（无候选）
    │ NO
    ▼
已达 max_old_cset_length? ──YES──► 结束
    │ NO
    ▼
reclaimable_percent <= G1HeapWastePercent? ──YES──► 结束
    │ NO
    ▼
预测时间 > 剩余时间?
    │
    ├──YES──► 已达 min_old_cset_length? ──YES──► 结束
    │              │ NO
    │              ▼
    │         强制添加（expensive）
    │
    └──NO──► 正常添加
    │
    ▼
更新剩余时间，获取下一个候选
    │
    └───► 继续循环
```

---

## 6. 关键 JVM 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `G1MixedGCLiveThresholdPercent` | 85 | 老年代 Region 存活率超过此值不加入候选（默认 85%）|
| `G1HeapWastePercent` | 5 | 剩余可回收空间低于此阈值时停止添加老年代 Region |
| `G1MixedGCCountTarget` | 8 | 目标在多少次 Mixed GC 内回收完所有候选 Region |
| `MaxGCPauseMillis` | 200 | 最大 GC 暂停时间，CSet 选择的时间预算上限 |
| `G1ReservePercent` | 10 | 堆保留百分比，影响老年代 Region 数量估计 |

---

## 7. GDB 运行时验证

### 7.1 验证脚本

```bash
# GDB 验证 CSet 选择机制
cat > /tmp/verify_cset.gdb << 'EOF'
set pagination off
attach <JAVA_PID>

# 1. 验证 CollectionSetChooser
set $chooser = G1CollectedHeap::_g1h->_collection_set->_cset_chooser
p *$chooser

# 2. 验证候选 Region 数量
p $chooser->_front
p $chooser->_end
p $chooser->remaining_regions()

# 3. 验证可回收字节
p $chooser->_remaining_reclaimable_bytes

# 4. 验证存活率阈值
p $chooser->_region_live_threshold_bytes

# 5. 验证 GC 效率排序（查看前 5 个 Region）
set $regions = $chooser->_regions
p $regions._data[0]->gc_efficiency()
p $regions._data[1]->gc_efficiency()
p $regions._data[2]->gc_efficiency()

# 6. 验证 G1CollectionSet 统计
set $cset = G1CollectedHeap::_g1h->_collection_set
p $cset->_eden_region_length
p $cset->_survivor_region_length
p $cset->_old_region_length
p $cset->_bytes_used_before

detach
quit
EOF

# 运行验证
JAVA_PID=$(pgrep -f "YourJavaApp")
gdb -batch -x /tmp/verify_cset.gdb
```

### 7.2 理论预期输出

```
# CollectionSetChooser 状态
$1 = {
  _regions = {...},                  # GrowableArray
  _front = 0,                         # 当前选择位置
  _end = 150,                         # 候选 Region 总数
  _remaining_reclaimable_bytes = 629145600,  # ~600MB 可回收
  _region_live_threshold_bytes = 3670016     # 3.5MB (85% of 4MB)
}

# 候选 Region 数量
$2 = 0      # _front
$3 = 150    # _end
$4 = 150    # remaining_regions()

# GC 效率排序验证（效率应递减）
$5 = 150000.0   # Region 0: 效率最高
$6 = 145000.0   # Region 1
$7 = 140000.0   # Region 2

# G1CollectionSet 统计
$8 = 20     # eden_region_length
$9 = 5      # survivor_region_length
$10 = 8     # old_region_length (本次 Mixed GC 选择的)
$11 = 134217728  # bytes_used_before (~128MB)
```

---

## 8. GC 日志输出

### 8.1 启用 CSet 选择日志

```bash
java -Xms8g -Xmx8g -XX:+UseG1GC \
     -Xlog:gc+ergo+cset=debug \
     YourApp
```

### 8.2 日志示例

```
# CSet 选择开始
[12.345s][debug][gc,ergo,cset] Start choosing CSet. 
    pending cards: 1024 
    predicted base time: 5.20ms 
    remaining time: 194.80ms 
    target pause time: 200.00ms

# 年轻代 CSet
[12.345s][debug][gc,ergo,cset] Add young regions to CSet. 
    eden: 20 regions, 
    survivors: 5 regions, 
    predicted young region time: 45.30ms

# 老年代 CSet 选择
[12.346s][debug][gc,ergo,cset] Finish choosing CSet. 
    old: 8 regions, 
    predicted old region time: 78.50ms, 
    time remaining: 71.00ms

# 达到上限停止
[15.678s][debug][gc,ergo,cset] Finish adding old regions to CSet 
    (old CSet region num reached max). 
    old 20 regions, max 20 regions

# 可回收空间不足停止
[18.901s][debug][gc,ergo,cset] Finish adding old regions to CSet 
    (reclaimable percentage not over threshold). 
    reclaimable: 314572800B (4.00%) threshold: 5%

# 时间预算不足停止
[21.234s][debug][gc,ergo,cset] Finish adding old regions to CSet 
    (predicted time is too high). 
    predicted time: 25.00ms, remaining time: 15.00ms 
    old 5 regions, min 4 regions
```

---

## 9. 内存布局分析

### 9.1 对象大小

| 类 | 理论大小（64位） | 说明 |
|----|-----------------|------|
| CollectionSetChooser | ~72 字节 | 数组 + 5 个字段 |
| G1CollectionSet | ~120 字节 | 多个计数器和指针 |
| HeapRegion | ~200 字节 | 包含 GC 效率等字段 |

### 9.2 内存占用汇总

```
标准环境（8GB 堆，2048 Regions）：

CollectionSetChooser._regions 数组：
    - 容量：2048 个指针
    - 大小：2048 × 8B = 16KB

G1CollectionSet._collection_set_regions 数组：
    - 容量：2048 个 uint
    - 大小：2048 × 4B = 8KB

CSet 相关总内存占用：~32KB（可忽略）
```

---

## 10. 常见问题与面试问答

### Q1: 为什么按 GC 效率排序，而不是直接按垃圾比例排序？

**答**：GC 效率综合考虑了**可回收空间**和**回收成本**：

```
Region A: 可回收 3MB，预测时间 10ms → 效率 = 0.3 MB/ms
Region B: 可回收 2MB，预测时间 5ms  → 效率 = 0.4 MB/ms

虽然 A 可回收更多，但 B 效率更高，优先选 B
```

回收成本包括：
- RSet 扫描时间（与 RSet 大小成正比）
- 存活对象复制时间

### Q2: Mixed GC 如何选择老年代 Region 数量？

**答**：受三个条件限制：

1. **数量上限**（max_old_cset_length）：防止单次 GC 时间太长
2. **可回收空间下限**（G1HeapWastePercent）：垃圾太少不值得回收
3. **时间预算**（MaxGCPauseMillis - 年轻代时间）：严格遵守暂停目标

### Q3: 什么是 expensive region？

**答**：预测回收时间超过剩余时间预算的 Region：

```cpp
if (predicted_time_ms > time_remaining_ms) {
    if (old_region_length() >= min_old_cset_length) {
        break;  // 已达到最小数量，跳过
    }
    // 未达到最小数量，强制添加（expensive）
    expensive_region_num += 1;
}
```

为了保证回收进度，即使超预算也会强制添加，直到达到 `min_old_cset_length`。

### Q4: 如何监控 CSet 选择效果？

**答**：

```bash
# 启用 CSet 选择日志
-Xlog:gc+ergo+cset=debug

# 关键指标：
# 1. old region 数量变化（是否达到 max/min）
# 2. reclaimable_percent（是否低于阈值）
# 3. expensive region 数量（是否频繁超时）
```

### Q5: Mixed GC 和 Young GC 的 CSet 选择有什么区别？

**答**：

| 维度 | Young GC | Mixed GC |
|------|----------|----------|
| 年轻代 | 全选（所有 Eden + Survivor） | 全选 |
| 老年代 | 不选 | 按 GC 效率选择 |
| 选择依据 | 无（必须全回收） | GC 效率排序 |
| 时间预算 | 只考虑年轻代 | 年轻代 + 老年代 |

---

## 11. 与 Cleanup Phase 的关联

### 11.1 数据流转

```
Cleanup Phase
    │
    ├── 并发标记完成
    ├── 计算每个 Region 的 live_bytes
    └── CollectionSetChooser::rebuild()
            │
            ├── 筛选候选 Region (should_add)
            ├── 计算 GC 效率 (calc_gc_efficiency)
            └── 按效率排序 (sort_regions)
                    │
                    ▼
Mixed GC Pause
    │
    └── finalize_old_part()
            └── 从已排序的候选列表中选择 Region
```

### 11.2 为什么需要提前排序？

**原因**：

1. **降低暂停时间**：排序在 Cleanup Phase（STW）后并发执行，不占用 Mixed GC 暂停时间
2. **简化选择逻辑**：Mixed GC 时只需顺序遍历已排序数组，O(1) 获取下一个最优 Region
3. **保证优先级**：GC 效率最高的 Region 总是优先被回收

---

## 12. 总结

### 12.1 核心要点

1. **GC 效率是核心指标**：`可回收字节 / 预测回收时间`
2. **三重限制**：数量上限、可回收下限、时间预算
3. **预排序优化**：Cleanup Phase 并发排序，降低 Mixed GC 暂停时间
4. **自适应预测**：基于历史 GC 数据预测 Region 回收时间

### 12.2 调优建议

| 场景 | 建议 |
|------|------|
| Mixed GC 时间过长 | 降低 `MaxGCPauseMillis` 或减少 `G1MixedGCCountTarget` |
| 老年代回收不及时 | 降低 `G1MixedGCLiveThresholdPercent` 或 `G1HeapWastePercent` |
| 可回收空间浪费 | 增加 `G1HeapWastePercent` 阈值 |
| Mixed GC 频率过高 | 增加 `G1MixedGCCountTarget` |

### 12.3 下一步

下一阶段将分析 **4.3 G1EvacuationInfo**，理解疏散信息的统计与预测模型输入。

---

**文档完成时间**: 2026-02-11  
**验证状态**: ⚠️ 提供完整验证脚本和理论预期值  
**关联文档**: 
- `Cleanup-Phase-Expert-Analysis.md`（CSet Chooser 重建）
- `G1Policy-Expert-Analysis.md`（预测模型）
