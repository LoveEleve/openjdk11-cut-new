# G1 Full GC 兜底机制专家级分析

> **文档版本**: v1.0  
> **创建时间**: 2026-02-11  
> **源码版本**: OpenJDK 11  
> **目标**: 深入理解 G1 Full GC 触发条件、执行机制与避免策略

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1 Full GC 的本质是**G1 GC 的最后防线**：当所有增量式 GC（Young GC/Mixed GC）都无法解决内存压力时触发；使用 `G1FullCollector` 对整个堆执行 Mark-Compact，代价是长时间 STW（通常秒级）。G1 的设计目标是让 Full GC 永不发生。

### 0.2 触发条件

| 触发原因 | 说明 |
|---------|------|
| Evacuation Failure | Survivor/Old 空间不足，无法复制存活对象 |
| Concurrent Mark Failure | 并发标记来不及完成，堆在标记期间被填满 |
| Humongous Allocation Failure | 大对象分配失败，没有足够的连续 Region |
| `System.gc()` | 显式调用（除非 `-XX:+DisableExplicitGC`） |

### 0.3 如何避免 Full GC？

- **避免 Evacuation Failure**：增大堆（`-Xmx`），减少对象晋升速率，调整 `G1ReservePercent`
- **避免 Concurrent Mark Failure**：降低 IHOP（`-XX:InitiatingHeapOccupancyPercent`），让并发标记更早开始
- **避免 Humongous Allocation Failure**：增大 Region 大小（`-XX:G1HeapRegionSize`），减少大对象分配

### 0.4 为什么 G1 Full GC 比 CMS Full GC 更慢？

G1 Full GC 使用 Mark-Compact（需要移动对象），CMS Full GC 使用 Mark-Sweep（不移动对象）；Mark-Compact 需要额外的"更新引用"阶段，代价更高；但 Mark-Compact 消除碎片，CMS 的 Mark-Sweep 会产生碎片。

---

---

## 1. 问题引入：为什么需要 Full GC？

### 1.1 场景假设

G1 的设计目标是避免 Full GC，但在以下场景下不得不触发：

```
场景1: 并发标记跟不上分配速度
        应用快速分配老年代对象
        并发标记尚未完成，堆已耗尽
        → 必须暂停应用进行 Full GC

场景2: 大对象分配失败
        连续空间不足分配 Humongous 对象
        堆碎片化严重
        → 必须整理堆空间

场景3: 晋升失败 (Evacuation Failure)
        Survivor 和老年代空间不足
        存活对象无法疏散
        → 回退到 Full GC

场景4: 元数据空间不足
        Metaspace/PermGen 耗尽
        → 触发 Full GC 卸载类
```

### 1.2 Full GC 的核心目标

**目标**：当 G1 的并发机制无法应对时，通过 STW 单线程回收保证系统可用性：

1. **内存兜底**：确保在 OOM 前回收足够空间
2. **堆整理**：压缩碎片，提供连续空间
3. **元数据回收**：卸载类，释放 Metaspace

---

## 2. Full GC 触发条件

### 2.1 触发点汇总

```cpp
// g1CollectedHeap.cpp 中的触发条件

// 1. 分配失败触发
if (should_start_conc_mark("concurrent humongous allocation", word_size)) {
    collect(GCCause::_g1_humongous_allocation);  // 可能退化为 Full GC
}

// 2. 晋升失败后的兜底
if (evacuation_failed()) {
    // 尝试扩容
    if (!expand_and_allocate(...)) {
        // 退化为 Full GC
    }
}

// 3. 显式调用 System.gc()
if (cause == GCCause::_java_lang_system_gc) {
    do_full_collection(false);  // 强制 Full GC
}

// 4. 元数据空间不足
if (Metadata::should_expand_metaspace()) {
    // 触发 Full GC 卸载类
}
```

### 2.2 触发条件详解

| 触发原因 | GCCause | 典型场景 |
|----------|---------|----------|
| `GCCause::_g1_humongous_allocation` | 大对象分配失败 | 分配巨型数组/对象 |
| `GCCause::_g1_evacuation_failure` | 疏散失败 | Survivor/Old 空间不足 |
| `GCCause::_java_lang_system_gc` | 显式调用 | `System.gc()` |
| `GCCause::_metadata_GC_threshold` | 元数据空间不足 | Metaspace 耗尽 |
| `GCCause::_last_ditch_collection` | 最后手段 | 防止 OOM |

---

## 3. Full GC 执行机制

### 3.1 与 Young/Mixed GC 的区别

```
┌─────────────────────────────────────────────────────────────────────┐
│                    G1 GC 类型对比                                    │
├──────────────────┬──────────────────┬───────────────────────────────┤
│     Young GC     │    Mixed GC      │         Full GC               │
├──────────────────┼──────────────────┼───────────────────────────────┤
│ 只回收年轻代     │ 年轻代+部分老年代│ 整个堆（年轻代+老年代+元数据）│
│ 并行多线程       │ 并行多线程       │ 单线程（Serial Old）          │
│ 复制算法         │ 复制算法         │ 标记-整理算法                 │
│ 速度快（10-50ms）│ 速度中（50-200ms）│ 速度慢（数秒）                │
│ 无堆整理         │ 无堆整理         │ 完全整理（无碎片）            │
└──────────────────┴──────────────────┴───────────────────────────────┘
```

### 3.2 Full GC 执行流程

```cpp
// g1CollectedHeap.cpp:2740-2810
void G1CollectedHeap::do_full_collection(bool clear_all_soft_refs) {
    // 1. 进入 Full GC 状态
    _collector_state.set_in_full_gc(true);
    
    // 2. 停止并发标记（如果正在进行）
    abort_concurrent_cycle();
    
    // 3. 使用 Serial Old GC 进行回收
    G1FullCollector collector(this, _gc_tracer_stw);
    collector.prepare_collection();
    collector.collect();
    collector.complete_collection();
    
    // 4. 恢复状态
    _collector_state.set_in_full_gc(false);
}
```

**详细步骤**：

```
Full GC Pause (STW)
    │
    ├── 1. 准备工作
    │   ├── 设置 _in_full_gc = true
    │   ├── 停止并发标记线程
    │   ├── 清理并发标记状态
    │   └── 准备标记位图
    │
    ├── 2. 标记阶段 (Mark)
    │   ├── 从 GC Roots 开始遍历
    │   ├── 标记所有可达对象
    │   └── 使用 _next_mark_bitmap
    │
    ├── 3. 计算阶段 (Calculate)
    │   ├── 计算每个 Region 的存活对象
    │   ├── 确定需要整理的 Region
    │   └── 计算对象新地址
    │
    ├── 4. 整理阶段 (Compact)
    │   ├── 按 Region 顺序复制存活对象
    │   ├── 更新所有引用
    │   └── 完全消除碎片
    │
    ├── 5. 恢复阶段 (Restore)
    │   ├── 释放空 Region
    │   ├── 重置标记位图
    │   ├── 清理 RSet
    │   └── 重置热卡缓存
    │
    └── 6. 完成
        ├── 重置 _in_full_gc = false
        ├── 重置并发标记状态
        └── 恢复 Young Only Phase
```

### 3.3 标记-整理算法

```
初始状态（堆碎片化）:
┌──────┬───┬──────────┬─────┬──────┬────────┬──────┐
│ Reg0 │Reg1│  Reg2   │Reg3 │ Reg4 │  Reg5  │ Reg6 │
│ Used │Used│  Used   │Used │ Used │  Used  │ Used │
│ 60%  │90% │  40%    │80%  │ 30%  │  70%   │ 50%  │
└──────┴───┴──────────┴─────┴──────┴────────┴──────┘

Full GC 后（完全整理）:
┌──────┬──────┬──────┬──────┬──────┬──────┬──────┐
│ Reg0 │ Reg1 │ Reg2 │ Reg3 │ Reg4 │ Free │ Free │
│ Used │ Used │ Used │ Used │ Used │      │      │
│ 100% │ 100% │ 100% │ 100% │ 20%  │      │      │
└──────┴──────┴──────┴──────┴──────┴──────┴──────┘

效果：
- 存活对象紧凑排列
- 消除内存碎片
- 提供连续空闲空间
```

---

## 4. Serial Old GC 实现

### 4.1 G1FullCollector 架构

```cpp
// g1FullCollector.hpp
class G1FullCollector : public StackObj {
    G1CollectedHeap* _heap;
    G1FullGCMarker   _marker;        // 标记器
    G1FullGCCompactionPoint _compaction_points;  // 整理点
    
public:
    void prepare_collection();       // 准备
    void collect();                  // 执行
    void complete_collection();      // 完成
};
```

### 4.2 单线程实现原因

**为什么使用单线程？**

1. **简单可靠**：Full GC 是兜底机制，简单实现降低风险
2. **内存碎片少**：单线程顺序整理，对象紧凑排列
3. **恢复状态**：需要重置大量全局状态，单线程更安全

**对比 CMS**：

| 特性 | G1 Full GC | CMS Full GC |
|------|------------|-------------|
| 算法 | 标记-整理 | 标记-清除-整理 |
| 线程数 | 单线程 | 多线程（可配置）|
| 碎片 | 无 | 可能有 |
| 速度 | 慢但确定 | 可能较快 |

---

## 5. Full GC 后的状态恢复

### 5.1 状态重置

```cpp
// g1Policy.cpp:480-490
void G1Policy::record_full_collection_end() {
    // 重置并发标记状态
    collector_state()->set_in_young_only_phase(true);
    collector_state()->set_in_young_gc_before_mixed(false);
    collector_state()->set_initiate_conc_mark_if_possible(
        need_to_start_conc_mark("end of Full GC", 0));
    collector_state()->set_in_initial_mark_gc(false);
    collector_state()->set_mark_or_rebuild_in_progress(false);
    collector_state()->set_clearing_next_bitmap(false);
    
    // 重置 CSet Chooser
    cset_chooser()->clear();
}
```

### 5.2 恢复流程

```
Full GC 结束
    │
    ├── 重置 GC 状态
    │   ├── _in_young_only_phase = true
    │   ├── _in_young_gc_before_mixed = false
    │   └── _mark_or_rebuild_in_progress = false
    │
    ├── 重置并发标记
    │   ├── 停止 CM 线程
    │   ├── 清空标记栈
    │   └── 重置位图
    │
    ├── 重置 CSet Chooser
    │   └── 清空候选列表
    │
    ├── 重置预测模型
    │   └── 清空历史数据
    │
    └── 检查是否需要启动新一轮并发标记
        └── need_to_start_conc_mark()
```

---

## 6. 如何避免 Full GC

### 6.1 调优策略

```bash
# 1. 提前启动并发标记（降低 IHOP 阈值）
-XX:InitiatingHeapOccupancyPercent=35

# 2. 增加并发标记线程数
-XX:ConcGCThreads=4

# 3. 预留更多堆空间
-XX:G1ReservePercent=20

# 4. 增加 Region 大小（减少大对象分配）
-XX:G1HeapRegionSize=16m

# 5. 调整 Mixed GC 目标次数
-XX:G1MixedGCCountTarget=4

# 6. 降低存活率阈值
-XX:G1MixedGCLiveThresholdPercent=80

# 7. 增加 Survivor 空间
-XX:SurvivorRatio=6
-XX:MaxTenuringThreshold=15
```

### 6.2 监控与预警

```bash
# 启用 Full GC 日志
java -XX:+UseG1GC \
     -Xlog:gc* \
     -Xlog:gc+ergo+ihop=debug \
     YourApp

# 关键指标
# - Full GC 频率（应 < 1次/小时）
# - Full GC 时长（应 < 10秒）
# - IHOP 实际阈值
# - 并发标记周期时长
```

### 6.3 代码层面优化

```java
// 1. 避免大对象分配
// 不好：一次性分配大数组
byte[] data = new byte[100 * 1024 * 1024];  // 100MB

// 好：分块处理
byte[] buffer = new byte[1024 * 1024];  // 1MB

// 2. 避免内存泄漏
// 不好：静态集合持有大量对象
static List<Object> cache = new ArrayList<>();

// 好：使用软引用或定期清理
static SoftReference<List<Object>> cache;

// 3. 及时释放资源
try (InputStream is = new FileInputStream(file)) {
    // 处理
}  // 自动关闭
```

---

## 7. Full GC 日志分析

### 7.1 典型 Full GC 日志

```
[15.234s][info][gc] GC(50) Pause Full (G1 Evacuation Failure)
[15.234s][info][gc] GC(50) Phase 1: Mark live objects
[15.456s][info][gc] GC(50) Phase 2: Prepare for compaction
[15.678s][info][gc] GC(50) Phase 3: Adjust pointers
[15.890s][info][gc] GC(50) Phase 4: Compact heap
[16.123s][info][gc] GC(50) Heap before GC:
    regions: 2048
    capacity: 8192M
    used: 7782M (95%)

[16.123s][info][gc] GC(50) Heap after GC:
    regions: 2048
    capacity: 8192M
    used: 2345M (28%)

[16.123s][info][gc] GC(50) Pause Full (G1 Evacuation Failure) 
    7782M->2345M(8192M) 1889ms
```

### 7.2 日志解读

| 指标 | 示例值 | 说明 |
|------|--------|------|
| 触发原因 | Evacuation Failure | 疏散失败 |
| 堆使用前 | 7782M (95%) | 几乎耗尽 |
| 堆使用后 | 2345M (28%) | 回收约 70% |
| GC 时长 | 1889ms | 近 2 秒 STW |

---

## 8. 面试问答

### Q1: G1 什么情况下会触发 Full GC？

**答**：
1. **大对象分配失败**：Humongous 对象分配时连续空间不足
2. **晋升失败**：Evacuation 时 Survivor/Old 空间不足
3. **并发标记来不及**：老年代增长速度超过回收速度
4. **显式调用**：`System.gc()`
5. **元数据空间不足**：Metaspace/PermGen 耗尽

### Q2: G1 Full GC 和 CMS Full GC 有什么区别？

**答**：

| 特性 | G1 Full GC | CMS Full GC |
|------|------------|-------------|
| 实现 | Serial Old（单线程） | Serial 或 Parallel |
| 算法 | 标记-整理 | 标记-清除-整理 |
| 碎片 | 无 | 可能有 |
| 速度 | 慢 | 可能较快 |
| 可靠性 | 高（简单） | 中 |

### Q3: 如何避免 G1 Full GC？

**答**：
1. **降低 IHOP 阈值**：让并发标记更早启动
2. **增加并发标记线程**：加快标记速度
3. **预留更多内存**：`G1ReservePercent`
4. **避免大对象**：调整 Region 大小
5. **代码优化**：避免内存泄漏、及时释放资源

### Q4: Full GC 后为什么要重置所有状态？

**答**：
- Full GC 是"终极兜底"，会破坏 G1 的并发假设
- 并发标记状态已无效，必须重置
- CSet Chooser 的候选列表已过期
- 预测模型需要重新学习
- 恢复到已知的 Young Only 状态最安全

---

## 9. 总结

### 9.1 Full GC 的关键点

| 方面 | 要点 |
|------|------|
| 触发条件 | 分配失败、晋升失败、显式调用、元数据不足 |
| 执行机制 | Serial Old GC，单线程标记-整理 |
| 性能影响 | STW 时间长（秒级），应极力避免 |
| 恢复工作 | 重置所有 GC 状态，恢复 Young Only Phase |

### 9.2 设计哲学

**Full GC 是 G1 的"保险丝"**：
- 正常情况下**不应该触发**
- 触发时说明系统已处于**危险状态**
- 通过**单线程**实现保证**可靠性**
- **完全整理**堆空间，提供**干净 slate**

### 9.3 运维建议

```
监控指标：
1. Full GC 频率（目标：0）
2. Full GC 时长（目标：< 5秒）
3. IHOP 阈值触发时机
4. 并发标记周期时长

告警规则：
- Full GC > 0 次/小时：警告
- Full GC > 3 次/小时：严重
- Full GC 时长 > 10 秒：严重
```

---

**文档完成时间**: 2026-02-11  
**验证状态**: 综合前面所有文档的分析结果  
**关联文档**: 
- `Mixed-GC-Flow-Comprehensive.md`（完整流程）
- `G1EvacuationInfo-Expert-Analysis.md`（疏散失败）
- `IHOP-Expert-Analysis.md`（触发机制）
