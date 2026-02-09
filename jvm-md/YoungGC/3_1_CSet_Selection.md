# 3.1 回收集合选择 (Collection Set Selection) 深度分析

> **源码位置**: 
> - `src/hotspot/share/gc/g1/g1Policy.cpp:1191`
> - `src/hotspot/share/gc/g1/g1CollectionSet.cpp`
> 
> **重要程度**: ⭐⭐⭐⭐⭐ (G1 核心设计，"Garbage First" 名字由来)
> **功能**: 决定本次 GC 回收哪些 Region，平衡回收效率与暂停时间

---

## 1. 为什么叫 "Garbage First"？

### 1.1 核心思想

```
传统 GC (如 CMS):
├── 回收整个老年代
├── 暂停时间长
└── 不管 Region 里有多少垃圾

G1:
├── 只回收部分 Region
├── 优先回收垃圾最多的 Region
├── 在目标暂停时间内回收最多内存
└── "Garbage First" = 垃圾优先回收
```

### 1.2 回收效率公式

```
                    可回收字节数 (reclaimable_bytes)
GC 效率 = ─────────────────────────────────────────────
          预测回收时间 (predicted_collection_time)

选择策略：
1. 计算每个 Region 的 GC 效率
2. 按效率从高到低排序
3. 在目标暂停时间内，选择效率最高的 Region
```

---

## 2. CSet 构建流程

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         CSet (Collection Set) 构建流程                           │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  G1Policy::finalize_collection_set(target_pause_time_ms, survivor)              │
│       │                                                                          │
│       ├── 1.  finalize_young_part()  ← 年轻代部分                               │
│       │       ├── 所有 Eden Region → 必须加入 CSet                              │
│       │       ├── Survivor Region → 根据存活率决定                              │
│       │       └── 计算剩余时间预算                                              │
│       │                                                                          │
│       └── 2.  finalize_old_part()  ← 老年代部分 (Mixed GC)                      │
│               ├── 从 CSet Chooser 获取候选 Region                               │
│               ├── 按 GC 效率排序                                                │
│               └── 在剩余时间内选择最高效的 Region                                │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 年轻代 CSet 构建

### 3.1 Eden Region 处理

```cpp
// 所有 Eden Region 必须加入 CSet
void G1CollectionSet::finalize_young_part(double target_pause_time_ms, 
                                          G1SurvivorRegions* survivor) {
    // Eden 区所有 Region 加入 CSet
    uint eden_region_length = _g1h->eden().length();
    for (uint i = 0; i < eden_region_length; i++) {
        HeapRegion* eden_region = _g1h->eden().at(i);
        add_young_region(eden_region);
    }
    
    // 计算 Eden 回收预测时间
    double predicted_eden_time = predict_eden_collection_time();
    
    // 返回剩余时间给老年代部分
    return target_pause_time_ms - predicted_eden_time;
}
```

**为什么 Eden 必须全部回收？**
- Eden 是分配新对象的地方
- 新对象大部分很快变成垃圾（朝生夕死）
- 不回收 Eden 会导致分配失败

### 3.2 Survivor Region 处理

```cpp
// Survivor Region 根据存活率决定是否加入 CSet
if (survivor->length() > _max_survivor_regions) {
    // Survivor 区过多，部分需要回收
    // 存活率低的优先回收
}
```

---

## 4. 老年代 CSet 构建 (Mixed GC) ⭐⭐⭐

### 4.1 核心问题

**问题**: 老年代可能有几百个 Region，不能全部回收（暂停时间太长）

**解决方案**: 选择"性价比"最高的 Region

### 4.2 GC 效率计算

```cpp
// HeapRegion.cpp:143-153
void HeapRegion::calc_gc_efficiency() {
    // 可回收字节数 = 总容量 - 存活对象大小
    size_t reclaimable = reclaimable_bytes();
    
    // 预测回收时间（基于历史数据）
    double predicted_time_ms = 
        g1p->predict_region_elapsed_time_ms(this, false);
    
    // GC 效率 = 可回收字节 / 预测时间
    _gc_efficiency = (double) reclaimable / predicted_time_ms;
}
```

### 4.3 Region 排序与选择

```cpp
// CollectionSetChooser 维护按效率排序的 Region 列表
class CollectionSetChooser {
    HeapRegion** _regions;      // Region 数组
    uint _front;                // 当前选择位置
    uint _end;                  // 结束位置
    
public:
    // 获取下一个候选 Region（效率最高的）
    HeapRegion* pop() {
        HeapRegion* hr = _regions[_front];
        _front++;
        return hr;
    }
};
```

### 4.4 暂停时间控制

```cpp
void G1CollectionSet::finalize_old_part(double time_remaining_ms) {
    CollectionSetChooser* chooser = _g1h->cset_chooser();
    
    while (time_remaining_ms > 0 && !chooser->is_empty()) {
        // 获取下一个最高效的 Region
        HeapRegion* region = chooser->pop();
        
        // 预测这个 Region 的回收时间
        double predicted_time = 
            predict_region_elapsed_time_ms(region);
        
        // 如果时间够，加入 CSet
        if (predicted_time <= time_remaining_ms) {
            add_old_region(region);
            time_remaining_ms -= predicted_time;
        } else {
            // 时间不够，放弃这个 Region
            break;
        }
    }
}
```

---

## 5. 预测模型 (G1Analytics)

### 5.1 为什么需要预测？

```
问题：如何知道回收一个 Region 需要多长时间？

方案：基于历史数据预测
- 记录每次 GC 的实际时间
- 使用指数加权移动平均 (EWMA) 预测下次时间
```

### 5.2 预测公式

```cpp
// 指数加权移动平均
double predict = 
    _alpha * last_value +           // 上次实际值 (权重 α)
    (1 - _alpha) * old_predict;     // 上次预测值 (权重 1-α)

// α 越大，对最新数据越敏感
// 默认 α = 0.3
```

### 5.3 预测内容

| 指标 | 用途 |
|------|------|
| `predict_region_elapsed_time_ms` | 回收一个 Region 的时间 |
| `predict_bytes_to_copy` | 需要复制的字节数 |
| `predict_rset_update_time` | 更新 Remembered Set 时间 |
| `predict_code_root_scan_time` | 扫描 Code Root 时间 |

---

## 6. 关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-XX:MaxGCPauseMillis` | 200 ms | 目标最大暂停时间 |
| `-XX:G1HeapWastePercent` | 5% | 允许浪费的堆百分比 |
| `-XX:G1MixedGCLiveThresholdPercent` | 85% | Region 存活率阈值 |
| `-XX:G1OldCSetRegionThresholdPercent` | 10% | 每次 Mixed GC 最多回收的老年代百分比 |

### 6.1 参数影响示例

```
场景：老年代有 100 个 Region，每个 4MB

G1HeapWastePercent = 5%:
├── 如果可回收空间 < 5% * 400MB = 20MB
├── 不触发 Mixed GC
└── 避免回收效率低的 Region

G1MixedGCLiveThresholdPercent = 85%:
├── 如果 Region 存活率 > 85%
├── 不加入 CSet Chooser
└── 避免回收存活对象过多的 Region
```

---

## 7. 完整示例

### 7.1 Mixed GC CSet 选择过程

```
假设：
- 目标暂停时间：200 ms
- Eden 回收预测：50 ms
- 剩余时间：150 ms

老年代候选 Region (已按 GC 效率排序):
┌──────┬────────────────┬─────────────────┬────────────────┐
│ Rank │ Region ID      │ Reclaimable(MB) │ Predicted(ms)  │
├──────┼────────────────┼─────────────────┼────────────────┤
│  1   │ Old-5          │ 3.5             │ 8              │
│  2   │ Old-12         │ 3.2             │ 10             │
│  3   │ Old-8          │ 2.8             │ 9              │
│  4   │ Old-23         │ 2.5             │ 12             │
│  5   │ Old-17         │ 2.0             │ 15             │
│ ...  │ ...            │ ...             │ ...            │
└──────┴────────────────┴─────────────────┴────────────────┘

选择过程:
1. 选 Old-5:  剩余 150-8  = 142 ms ✓
2. 选 Old-12: 剩余 142-10 = 132 ms ✓
3. 选 Old-8:  剩余 132-9  = 123 ms ✓
4. 选 Old-23: 剩余 123-12 = 111 ms ✓
5. 选 Old-17: 剩余 111-15 = 96 ms  ✓
...
直到剩余时间 < 下一个 Region 预测时间

最终 CSet:
- Eden: 所有 Eden Region
- Survivor: 部分 Survivor Region
- Old: Old-5, Old-12, Old-8, Old-23, Old-17, ... (约 10 个)
```

---

## 8. GDB 验证

### 8.1 断点设置

```gdb
# CSet 构建入口
break G1Policy::finalize_collection_set

# 年轻代部分
break G1CollectionSet::finalize_young_part

# 老年代部分
break G1CollectionSet::finalize_old_part

# 查看 CSet Chooser
break CollectionSetChooser::pop
```

### 8.2 验证内容

```gdb
# 查看目标暂停时间
print target_pause_time_ms

# 查看 Eden Region 数量
print _g1h->eden().length()

# 查看选择的 Old Region 数量
print collection_set()->old_region_length()

# 查看 GC 效率
print region->_gc_efficiency
```

---

## 9. 总结

### 核心要点

1. **Garbage First**: 优先回收垃圾最多的 Region

2. **GC 效率**: `reclaimable_bytes / predicted_time`

3. **暂停时间控制**: 在目标时间内选择最高效的 Region

4. **预测模型**: 基于历史数据预测回收时间

5. **分层构建**:
   - Eden: 必须全部回收
   - Survivor: 根据存活率选择
   - Old: 按效率排序选择

### G1 vs 传统 GC

| 特性 | G1 | CMS/Parallel |
|------|-----|--------------|
| 回收范围 | 部分 Region | 整个老年代 |
| 选择策略 | 垃圾优先 | 全部回收 |
| 暂停时间 | 可预测 | 不可预测 |
| 碎片处理 | 复制整理 | CMS 有碎片 |

---

## 10. 下一步

基于当前分析，可以深入：

### 选项 A: G1Analytics 预测模型
- 指数加权移动平均算法
- 预测准确性调优
- 历史数据维护

### 选项 B: Mixed GC 完整流程
- 并发标记交互
- 老年代回收策略
- 碎片整理

### 选项 C: 回到 Young GC 其他模块
- 0.1 触发机制
- 5.1 清理阶段

**请问想继续哪个部分？**
