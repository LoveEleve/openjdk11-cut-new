# G1EvacuationInfo 专家级分析

> **文档版本**: v1.0  
> **创建时间**: 2026-02-11  
> **源码版本**: OpenJDK 11  
> **目标**: 深入理解 G1 GC 疏散信息统计机制

---

## 1. 问题引入：为什么需要 EvacuationInfo？

### 1.1 场景假设

G1 完成一次 Mixed GC 后，我们需要回答以下问题：

```
问题1: 这次 GC 回收了多少空间？
        → 需要知道 CSet 使用前后的字节数变化

问题2: 复制了多少字节？
        → 用于评估 GC 工作量

问题3: 释放了多少个 Region？
        → 用于评估回收效率

问题4: 分配了多少个新 Region 用于疏散？
        → 用于评估内存分配压力
```

### 1.2 EvacuationInfo 的核心目标

**目标**：在 GC 过程中收集疏散统计信息，用于：

1. **GC 日志输出**：记录详细的回收统计
2. **JFR 事件**：通过 EventEvacuationInformation 发送诊断数据
3. **性能分析**：评估 GC 效率和内存压力
4. **预测模型输入**：为后续 GC 决策提供历史数据

---

## 2. EvacuationInfo 架构概览

### 2.1 数据结构定义

```cpp
// evacuationInfo.hpp:30-79
class EvacuationInfo : public StackObj {
  uint   _collectionset_regions;       // CSet 中的 Region 总数
  uint   _allocation_regions;          // 用于疏散的分配 Region 数
  size_t _collectionset_used_before;   // GC 前 CSet 使用字节数
  size_t _collectionset_used_after;    // GC 后 CSet 使用字节数
  size_t _alloc_regions_used_before;   // 分配 Region GC 前使用字节数
  size_t _bytes_copied;                // 复制字节数
  uint   _regions_freed;               // 释放的 Region 数

public:
  EvacuationInfo() : 
    _collectionset_regions(0), 
    _allocation_regions(0), 
    _collectionset_used_before(0),
    _collectionset_used_after(0), 
    _alloc_regions_used_before(0),
    _bytes_copied(0), 
    _regions_freed(0) { }
  
  // setter 方法...
  // getter 方法...
};
```

### 2.2 数据流转图

```
GC Pause Start
    │
    ▼
┌─────────────────────┐
│ EvacuationInfo      │ ← 栈上创建
│ evacuation_info;    │
└──────────┬──────────┘
           │
           ▼
finalize_collection_set()
    │
    ├── evacuation_info.set_collectionset_regions()  ← 记录 CSet Region 数
    │
    ▼
init_gc_alloc_regions(evacuation_info)
    │
    ├── evacuation_info.set_alloc_regions_used_before()  ← 记录保留 Region 使用量
    │
    ▼
evacuate_collection_set()
    │
    ├── 对象复制过程中统计...
    │
    ▼
post_evacuate_collection_set(evacuation_info)
    │
    ├── release_gc_alloc_regions(evacuation_info)
    │   └── evacuation_info.set_allocation_regions()  ← 记录分配 Region 数
    │
    ▼
free_collection_set(evacuation_info)
    │
    ├── evacuation_info.set_regions_freed()           ← 记录释放 Region 数
    ├── evacuation_info.increment_collectionset_used_after()  ← 记录幸存者字节
    │
    ▼
GC Pause End
    │
    ├── evacuation_info.set_collectionset_used_before()  ← 从 CSet 获取
    ├── evacuation_info.set_bytes_copied()               ← 从 Policy 获取
    │
    ▼
report_evacuation_info(&evacuation_info)  ← 发送 JFR 事件
```

---

## 3. 字段详解

### 3.1 字段汇总表

| 字段 | 类型 | 设置时机 | 用途 |
|------|------|----------|------|
| `_collectionset_regions` | uint | finalize_collection_set | CSet 总 Region 数 |
| `_allocation_regions` | uint | release_gc_alloc_regions | 疏散分配 Region 数 |
| `_collectionset_used_before` | size_t | GC Pause End | GC 前 CSet 使用字节 |
| `_collectionset_used_after` | size_t | free_collection_set | GC 后 CSet 使用字节 |
| `_alloc_regions_used_before` | size_t | init_gc_alloc_regions | 保留分配 Region 使用字节 |
| `_bytes_copied` | size_t | GC Pause End | 复制字节数 |
| `_regions_freed` | uint | free_collection_set | 释放 Region 数 |

### 3.2 关键字段计算逻辑

#### bytes_copied（复制字节数）

```cpp
// g1CollectedHeap.cpp:3799
evacuation_info.set_bytes_copied(g1_policy()->bytes_copied_during_gc());

// g1Policy.cpp 中统计逻辑
size_t G1Policy::bytes_copied_during_gc() {
  return _bytes_copied_during_gc;  // 在疏散过程中累加
}
```

**统计时机**：在 `G1ParScanThreadState::copy_to_survivor_space()` 中，每次成功复制对象时累加。

#### collectionset_used_before / after

```cpp
// GC 前：从 CSet 获取
size_t bytes_used_before = collection_set()->bytes_used_before();

// GC 后：累加每个 Region 的幸存者
template <class T>
void G1SerialFreeCollectionSetClosure::do_heap_region(HeapRegion* r) {
  // ...
  _after_used_bytes += (retained_bytes + evacuated_bytes);
}
```

---

## 4. 代码路径详解

### 4.1 创建与初始化

```cpp
// g1CollectedHeap.cpp:3591
do_collection_pause_at_safepoint() {
  EvacuationInfo evacuation_info;  // 栈上创建，自动初始化为 0
  
  // 记录 CSet Region 数量
  evacuation_info.set_collectionset_regions(
    collection_set()->region_length());
}
```

### 4.2 记录保留分配 Region

```cpp
// g1Allocator.cpp:59-92
void G1Allocator::reuse_retained_old_region(
    EvacuationInfo& evacuation_info,
    OldGCAllocRegion* old,
    HeapRegion** retained_old) {
  
  HeapRegion* retained_region = *retained_old;
  if (retained_region != NULL) {
    // 复用保留的 Old GC 分配 Region
    old->set(retained_region);
    
    // 记录该 Region GC 前的使用量
    evacuation_info.set_alloc_regions_used_before(
      retained_region->used());
  }
}
```

### 4.3 记录分配 Region 数量

```cpp
// g1Allocator.cpp:107-109
void G1Allocator::release_gc_alloc_regions(EvacuationInfo& evacuation_info) {
  // Survivor + Old 分配 Region 总数
  evacuation_info.set_allocation_regions(
    survivor_gc_alloc_region()->count() +
    old_gc_alloc_region()->count());
  
  // 释放 Survivor 分配 Region
  survivor_gc_alloc_region()->release();
  // ...
}
```

### 4.4 记录释放 Region

```cpp
// g1CollectedHeap.cpp:5048-5052 (G1SerialFreeCollectionSetClosure)
void complete_work() {
  // 记录释放的 Region 数量
  _evacuation_info->set_regions_freed(_local_free_list.length());
  
  // 记录 GC 后 CSet 使用量（幸存者）
  _evacuation_info->increment_collectionset_used_after(_after_used_bytes);
  
  // 将释放的 Region 加入空闲列表
  g1h->prepend_to_freelist(&_local_free_list);
}
```

---

## 5. JFR 事件报告

### 5.1 事件定义

```cpp
// gcTraceSend.cpp:212-224
void G1NewTracer::send_evacuation_info_event(EvacuationInfo* info) {
  EventEvacuationInformation e;
  if (e.should_commit()) {
    e.set_gcId(GCId::current());
    e.set_cSetRegions(info->collectionset_regions());
    e.set_cSetUsedBefore(info->collectionset_used_before());
    e.set_cSetUsedAfter(info->collectionset_used_after());
    // ... 更多字段
    e.commit();
  }
}
```

### 5.2 JFR 事件字段映射

| JFR 字段 | EvacuationInfo 字段 | 说明 |
|----------|---------------------|------|
| gcId | - | 当前 GC 标识 |
| cSetRegions | _collectionset_regions | CSet Region 数 |
| cSetUsedBefore | _collectionset_used_before | GC 前使用字节 |
| cSetUsedAfter | _collectionset_used_after | GC 后使用字节 |

---

## 6. GC 日志输出

### 6.1 启用 GC 日志

```bash
java -Xms8g -Xmx8g -XX:+UseG1GC \
     -Xlog:gc* \
     YourApp
```

### 6.2 日志示例

```
[12.345s][info][gc] GC(8) Pause Young (Mixed) (G1 Evacuation Pause)
[12.346s][info][gc] GC(8) Evacuation Information:
    CSet Regions: 28
    Allocation Regions: 3
    CSet Used Before: 120MB
    CSet Used After: 45MB
    Bytes Copied: 45MB
    Regions Freed: 25

[12.346s][info][gc] GC(8) Pause Young (Mixed) 120M->45M(8192M) 15.234ms
```

### 6.3 关键指标解读

| 指标 | 健康范围 | 异常信号 |
|------|----------|----------|
| Bytes Copied / CSet Used Before | < 50% | 过高表示存活对象多，GC 效率低 |
| Regions Freed / CSet Regions | > 80% | 过低表示很多 Region 未完全清空 |
| Allocation Regions | 1-5 | 过高表示大对象晋升或存活对象分散 |

---

## 7. GDB 运行时验证

### 7.1 验证脚本

```bash
# GDB 验证 EvacuationInfo
cat > /tmp/verify_evacuation_info.gdb << 'EOF'
set pagination off
attach <JAVA_PID>

# 在 do_collection_pause_at_safepoint 设置断点
break g1CollectedHeap.cpp:3591
commands
  # 创建 EvacuationInfo 后打印
  p evacuation_info
  continue
end

# 在 free_collection_set 设置断点
break g1CollectedHeap.cpp:5221
commands
  # 释放 CSet 前打印
  p evacuation_info
  continue
end

continue
EOF

# 运行验证
JAVA_PID=$(pgrep -f "YourJavaApp")
gdb -batch -x /tmp/verify_evacuation_info.gdb
```

### 7.2 理论预期输出

```
# 创建时（初始状态）
$1 = {
  _collectionset_regions = 0,
  _allocation_regions = 0,
  _collectionset_used_before = 0,
  _collectionset_used_after = 0,
  _alloc_regions_used_before = 0,
  _bytes_copied = 0,
  _regions_freed = 0
}

# CSet 确定后
$2 = {
  _collectionset_regions = 28,        # 25 年轻 + 3 老年代
  _allocation_regions = 0,            # 尚未分配
  _collectionset_used_before = 0,     # 稍后设置
  ...
}

# GC 完成后
$3 = {
  _collectionset_regions = 28,
  _allocation_regions = 3,            # Survivor + Old 分配 Region
  _collectionset_used_before = 125829120,   # 120MB
  _collectionset_used_after = 47185920,     # 45MB
  _alloc_regions_used_before = 1048576,     # 1MB
  _bytes_copied = 47185920,           # 45MB
  _regions_freed = 25                 # 释放 25 个 Region
}
```

---

## 8. 内存布局分析

### 8.1 对象大小

```cpp
// EvacuationInfo 字段分析
class EvacuationInfo : public StackObj {
  uint   _collectionset_regions;       // 4 bytes
  uint   _allocation_regions;          // 4 bytes
  size_t _collectionset_used_before;   // 8 bytes
  size_t _collectionset_used_after;    // 8 bytes
  size_t _alloc_regions_used_before;   // 8 bytes
  size_t _bytes_copied;                // 8 bytes
  uint   _regions_freed;               // 4 bytes
};  
// 理论大小: 44 bytes（可能填充到 48 bytes）
```

### 8.2 内存占用

```
EvacuationInfo 实例：
- 分配位置：栈上（StackObj）
- 生命周期：单次 GC Pause
- 内存占用：~48 字节（可忽略）
```

---

## 9. 常见问题与面试问答

### Q1: EvacuationInfo 和 G1CollectionSet 有什么关系？

**答**：
- `G1CollectionSet`：决定**哪些 Region** 需要回收
- `EvacuationInfo`：记录**回收过程**的统计信息

关系：EvacuationInfo 收集的数据基于 G1CollectionSet 的回收结果。

### Q2: bytes_copied 和 collectionset_used_after 有什么区别？

**答**：
- `bytes_copied`：实际**复制**到 Survivor/Old 的字节数
- `collectionset_used_after`：CSet Region 中**仍然占用**的字节数（幸存者）

理论上两者相等，但由于：
- 部分对象可能直接晋升到老年代
- 大对象可能在老年代直接分配

实际可能存在差异。

### Q3: 如何评估一次 GC 的效率？

**答**：关键指标：

```
回收效率 = (CSet Used Before - CSet Used After) / GC Pause Time
        = (120MB - 45MB) / 15.234ms
        = 4.92 MB/ms

存活率 = CSet Used After / CSet Used Before
       = 45MB / 120MB
       = 37.5%

Region 利用率 = Regions Freed / CSet Regions
              = 25 / 28
              = 89.3%
```

### Q4: allocation_regions 高说明什么？

**答**：`allocation_regions` 高可能表示：

1. **存活对象多**：需要更多 Survivor Region
2. **大对象晋升**：需要 Old Region 直接分配
3. **疏散分散**：存活对象分散在多个 Region

调优建议：
- 增加 Survivor 空间（`-XX:TargetSurvivorRatio`）
- 调整晋升阈值（`-XX:MaxTenuringThreshold`）

---

## 10. 与预测模型的关联

### 10.1 数据用途

```
EvacuationInfo 数据
    │
    ├──► GC 日志（人工分析）
    │
    ├──► JFR 事件（监控工具）
    │
    └──► G1Policy 预测模型
            │
            ├── bytes_copied ──► 预测下次复制时间
            ├── regions_freed ──► 预测堆收缩
            └── collectionset_used_after ──► 预测存活率
```

### 10.2 预测模型输入

```cpp
// g1Policy.cpp 使用历史数据预测
void G1Policy::record_collection_pause_end(...) {
  // 使用本次 GC 数据更新预测模型
  _analytics->report_rs_length_diff(...);
  _analytics->report_concurrent_mark_cleanup_times(...);
  
  // 基于历史 bytes_copied 预测下次复制时间
  double predicted_copy_time = 
    _predictor->predict_copy_time_ms(_analytics->bytes_copied_history());
}
```

---

## 11. 总结

### 11.1 核心要点

1. **EvacuationInfo 是 GC 统计容器**：记录疏散过程的 7 个关键指标
2. **栈上分配，生命周期短**：单次 GC Pause 内创建和销毁
3. **数据流向**：GC 过程 → EvacuationInfo → GC 日志 / JFR 事件
4. **预测模型输入**：为 G1Policy 提供历史数据支持

### 11.2 调优建议

| 指标 | 健康范围 | 调优建议 |
|------|----------|----------|
| Bytes Copied / CSet Used Before | < 50% | 过高时增加堆大小或调整晋升阈值 |
| Regions Freed / CSet Regions | > 80% | 过低时检查内存碎片 |
| Allocation Regions | 1-5 | 过高时增加 Survivor 空间 |

### 11.3 下一步

下一阶段将分析 **4.4 G1PostEvacuateCleanup**，理解疏散后的清理工作与并发标记状态更新。

---

**文档完成时间**: 2026-02-11  
**验证状态**: ⚠️ 提供完整验证脚本和理论预期值  
**关联文档**: 
- `Mixed-GC-CSet-Selection.md`（CSet 选择）
- `G1Policy-Expert-Analysis.md`（预测模型）
