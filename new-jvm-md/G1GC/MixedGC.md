# Mixed GC 深度分析

> **源码位置**: `src/hotspot/share/gc/g1/g1Policy.cpp`
> **重要程度**: ⭐⭐⭐⭐⭐ (G1 核心特色，老年代增量回收)
> **功能**: 在 Young GC 的同时回收部分老年代 Region

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

Mixed GC 的本质是**G1 的老年代增量回收机制**：在 Young GC 的基础上，额外将部分 Old Region 加入 CSet 一起回收；通过并发标记获得 Old Region 的存活率数据，按垃圾密度贪心选取 Old Region；连续多次 Mixed GC 将 Old 区占用率降到目标以下。

### 0.2 Mixed GC 与 Young GC 的本质区别

| 维度 | Young GC | Mixed GC |
|------|---------|---------|
| CSet 组成 | Eden + Survivor | Eden + Survivor + 部分 Old |
| 触发条件 | Eden 满 | 并发标记完成 + Old 区占用高 |
| 数据依赖 | 无 | 依赖并发标记的存活率数据 |
| 持续次数 | 每次 Eden 满 | 连续多次直到 Old 区占用降低 |

### 0.3 Mixed GC 触发判断

```cpp
// g1Policy.cpp
bool G1Policy::next_gc_should_be_mixed() {
    // 条件1：有足够的 Old Region 候选（垃圾密度 > G1HeapWastePercent）
    if (cset_chooser()->is_empty()) return false;
    // 条件2：Old 区可回收字节 > 堆大小 × G1HeapWastePercent
    size_t reclaimable = cset_chooser()->remaining_reclaimable_bytes();
    return reclaimable > heap_waste_bytes;
}
```

### 0.4 为什么这样设计？

- **为什么 Mixed GC 不一次回收所有 Old Region？** 一次回收所有 Old Region 的停顿时间不可接受（可能数秒）；增量回收（每次只回收部分）让停顿时间可控
- **为什么需要并发标记才能做 Mixed GC？** Mixed GC 需要知道 Old Region 的存活率（决定哪些 Region 值得回收）；没有并发标记数据，无法做出正确的 CSet 选择

---

## 1. 为什么需要 Mixed GC？

### 1.1 传统 GC 的问题

```
传统 Full GC:
├── 回收整个老年代
├── 暂停时间长（几秒甚至几十秒）
└── 导致应用卡顿

问题：老年代很大时（几十 GB），Full GC 无法忍受
```

### 1.2 G1 的解决方案：Mixed GC

```
Mixed GC 思想:
├── 老年代分成多个 Region
├── 每次只回收部分 Region（垃圾最多的）
├── 分散到多次 GC 中完成
└── 每次暂停时间可控

比喻：
- 传统 Full GC = 一次性打扫整个房子
- Mixed GC = 每次只打扫最脏的几个房间
```

---

## 2. Mixed GC 触发条件

### 2.1 触发流程图

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         Mixed GC 触发流程                                        │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  1. 并发标记完成                                                                 │
│       │                                                                          │
│       ▼                                                                          │
│  2. G1Policy::record_concurrent_mark_cleanup_end()                              │
│       │                                                                          │
│       ├── 构建 CSet Chooser（按 GC 效率排序的老年代 Region）                     │
│       │   └── cset_chooser()->rebuild()                                         │
│       │                                                                          │
│       └── 设置状态: set_in_young_gc_before_mixed(true)                          │
│                                                                                  │
│  3. 下一次 Young GC                                                              │
│       │                                                                          │
│       ▼                                                                          │
│  4. 状态判断                                                                     │
│       ├── in_young_gc_before_mixed() == true                                    │
│       └── 这是 "Prepare Mixed" GC                                               │
│                                                                                  │
│  5. 再下一次 GC                                                                  │
│       │                                                                          │
│       ▼                                                                          │
│  6. 进入 Mixed Phase                                                             │
│       ├── set_in_young_only_phase(false)                                        │
│       └── 开始 Mixed GC 序列                                                    │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 关键代码

```cpp
void G1Policy::record_concurrent_mark_cleanup_end() {
    // 1. 重建 CSet Chooser
    // 将所有可回收的老年代 Region 按效率排序
    cset_chooser()->rebuild(_g1h->workers(), _g1h->num_regions());
    
    // 2. 判断是否需要 Mixed GC
    bool mixed_gc_pending = next_gc_should_be_mixed(
        "request mixed gcs", 
        "request young-only gcs"
    );
    
    if (mixed_gc_pending) {
        // 3. 设置状态：准备进入 Mixed GC
        collector_state()->set_in_young_gc_before_mixed(true);
    }
}

bool G1Policy::next_gc_should_be_mixed(const char* true_action_str,
                                       const char* false_action_str) const {
    // 1. 检查是否有候选 Region
    if (cset_chooser()->is_empty()) {
        return false;
    }
    
    // 2. 检查可回收空间是否超过阈值
    size_t reclaimable_bytes = cset_chooser()->remaining_reclaimable_bytes();
    double reclaimable_percent = reclaimable_bytes_percent(reclaimable_bytes);
    double threshold = (double) G1HeapWastePercent;  // 默认 5%
    
    return reclaimable_percent > threshold;
}
```

---

## 3. Mixed GC 状态机

### 3.1 G1 GC 状态转换

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         G1 GC 状态转换图                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────┐                                                           │
│  │ Young-Only   │ ← 初始状态，只回收年轻代                                   │
│  │ Phase        │                                                           │
│  └──────┬───────┘                                                           │
│         │ 老年代占比达到阈值 (IHOP)                                         │
│         ▼                                                                   │
│  ┌──────────────┐                                                           │
│  │ Initial Mark │ ← 初始标记（附带 Young GC）                                │
│  │ (Young GC)   │   启动并发标记                                              │
│  └──────┬───────┘                                                           │
│         │ 并发标记完成                                                       │
│         ▼                                                                   │
│  ┌──────────────┐                                                           │
│  │ Prepare      │ ← 准备 Mixed GC                                            │
│  │ Mixed        │   最后一次纯 Young GC                                      │
│  └──────┬───────┘                                                           │
│         │                                                                    │
│         ▼                                                                   │
│  ┌──────────────┐     ┌─────────────────┐                                  │
│  │ Mixed Phase  │ ←→  │ Mixed GC        │                                  │
│  │              │     │ (Young + Old)   │                                  │
│  └──────┬───────┘     └─────────────────┘                                  │
│         │ 可回收空间 < 阈值 或 CSet Chooser 为空                             │
│         ▼                                                                   │
│  ┌──────────────┐                                                           │
│  │ Young-Only   │ ← 回到初始状态                                             │
│  │ Phase        │                                                           │
│  └──────────────┘                                                           │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 状态判断代码

```cpp
G1Policy::PauseKind G1Policy::young_gc_pause_kind() const {
    if (collector_state()->in_initial_mark_gc()) {
        return InitialMarkGC;      // 初始标记
    } else if (collector_state()->in_young_gc_before_mixed()) {
        return LastYoungGC;        // Prepare Mixed
    } else if (collector_state()->in_mixed_phase()) {
        return MixedGC;            // Mixed GC
    } else {
        return YoungOnlyGC;        // 纯 Young GC
    }
}
```

---

## 4. Mixed GC 执行流程

### 4.1 与 Young GC 的区别

| 阶段 | Young GC | Mixed GC |
|------|----------|----------|
| **CSet** | Eden + Survivor | Eden + Survivor + **Old** |
| **根扫描** | 只扫描年轻代 | 扫描年轻代 + **老年代根** |
| **疏散** | 只复制年轻代对象 | 复制年轻代 + **老年代对象** |
| **时间** | 较短 | 较长（但可控） |

### 4.2 CSet 构建差异

```cpp
void G1Policy::finalize_collection_set(double target_pause_time_ms, 
                                       G1SurvivorRegions* survivor) {
    // 1. 年轻代部分（与 Young GC 相同）
    double time_remaining_ms = 
        _collection_set->finalize_young_part(target_pause_time_ms, survivor);
    
    // 2. 老年代部分（Mixed GC 特有）
    // 在剩余时间内选择最高效的老年代 Region
    _collection_set->finalize_old_part(time_remaining_ms);
}
```

### 4.3 老年代 Region 选择

```cpp
void G1CollectionSet::finalize_old_part(double time_remaining_ms) {
    CollectionSetChooser* chooser = _g1h->cset_chooser();
    
    // 按 GC 效率排序，选择 Region 直到时间用完
    while (time_remaining_ms > 0 && !chooser->is_empty()) {
        HeapRegion* region = chooser->pop();  // 获取最高效的 Region
        
        double predicted_time = 
            predict_region_elapsed_time_ms(region);
        
        if (predicted_time <= time_remaining_ms) {
            add_old_region(region);
            time_remaining_ms -= predicted_time;
        } else {
            break;  // 时间不够，停止选择
        }
    }
}
```

---

## 5. Mixed GC 序列

### 5.1 为什么需要多次 Mixed GC？

```
问题：老年代有 100 个 Region 需要回收
- 一次回收 100 个 Region → 暂停时间太长
- 分成 10 次，每次回收 10 个 → 暂停时间可控

Mixed GC 序列:
┌─────────┐  ┌─────────┐  ┌─────────┐         ┌─────────┐
│ Mixed 1 │→│ Mixed 2 │→│ Mixed 3 │→...→→│ Mixed N │
│ 10 Old  │  │ 10 Old  │  │ 10 Old  │         │  5 Old  │
│ Regions │  │ Regions │  │ Regions │         │ Regions │
└─────────┘  └─────────┘  └─────────┘         └─────────┘
     ↓            ↓            ↓                  ↓
   Eden+       Eden+        Eden+              Eden+
   Survivor    Survivor     Survivor           Survivor
```

### 5.2 结束条件

```cpp
// 每次 Mixed GC 后检查是否继续
if (!next_gc_should_be_mixed("continue mixed GCs",
                             "do not continue mixed GCs")) {
    // 结束 Mixed Phase，回到 Young-Only Phase
    collector_state()->set_in_young_only_phase(true);
    clear_collection_set_candidates();
}
```

**结束条件**:
1. CSet Chooser 为空（没有候选 Region 了）
2. 可回收空间比例 < `G1HeapWastePercent`（默认 5%）

---

## 6. 关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-XX:G1HeapWastePercent` | 5% | 停止 Mixed GC 的阈值 |
| `-XX:G1MixedGCCountTarget` | 8 | 目标 Mixed GC 次数 |
| `-XX:G1OldCSetRegionThresholdPercent` | 10% | 每次 Mixed GC 最多回收的老年代百分比 |
| `-XX:G1MixedGCLiveThresholdPercent` | 85% | Region 存活率阈值（超过不回收） |

### 6.1 参数影响

```
G1MixedGCCountTarget = 8:
├── 并发标记后有 80 个 Old Region 需要回收
├── 目标分 8 次完成
└── 每次回收约 10 个 Region

G1OldCSetRegionThresholdPercent = 10%:
├── 如果老年代有 1000 个 Region
├── 每次 Mixed GC 最多回收 100 个
└── 防止单次 GC 时间过长
```

---

## 7. 总结

### Mixed GC 核心要点

1. **增量回收**: 将老年代回收分散到多次 GC

2. **垃圾优先**: 每次选择回收效率最高的 Region

3. **暂停可控**: 通过限制 CSet 大小控制暂停时间

4. **状态驱动**: 通过状态机管理 GC 类型转换

### Mixed GC vs Full GC

| 特性 | Mixed GC | Full GC |
|------|----------|---------|
| 回收范围 | 部分老年代 | 整个老年代 |
| 暂停时间 | 可控（~200ms） | 长（几秒~几十秒） |
| 触发频率 | 频繁 | 极少 |
| 碎片处理 | 复制整理 | 压缩整理 |

### 完整 GC 周期

```
Young GC → Young GC → ... → Initial Mark → Concurrent Mark 
                                        ↓
Young GC (Prepare Mixed) → Mixed GC → Mixed GC → ... → Young GC
```

---

## 8. 下一步

基于当前分析，可以深入：

### 选项 A: 并发标记 (Concurrent Mark)
- SATB 算法
- 三色标记
- 并发阶段与 STW 阶段

### 选项 B: Full GC
- 触发条件
- 串行 vs 并行 Full GC
- 压缩算法

### 选项 C: 性能调优
- Mixed GC 参数调优
- GC 日志分析
- 内存泄漏排查

**请问想继续哪个方向？**
