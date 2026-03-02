# CollectionSetChooser 专家级源码分析

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

CollectionSetChooser 的本质是**Mixed GC 的老年代 Region 候选列表管理器**：并发标记完成后，按"垃圾密度"（`(1 - 存活率) × Region大小`）对 Old Region 排序，Mixed GC 时按序选取 Region 加入 CSet，直到预测停顿时间达到目标。

### 0.2 为什么需要？

Mixed GC 需要从 Old 区选择 Region 回收，但不能选所有 Old Region（停顿时间会超标）。需要一个优先级队列：优先选择垃圾最多的 Region（回收效率最高），在停顿时间预算内尽量多回收。

### 0.3 怎么解决？

**排序 + 贪心选择**：`sortHeapRegions()` 按 `reclaimable_bytes` 降序排列所有 Old Region；`getNextMarkedRegion()` 依次返回下一个候选 Region；`G1Policy` 调用 `getNextMarkedRegion()` 直到预测停顿时间达到 `MaxGCPauseMillis`。

### 0.4 为什么这样设计？

- **为什么按垃圾密度排序而不是按 Region 大小？** 垃圾密度高的 Region 回收效率高（复制的存活对象少，释放的空间多）；按大小排序可能选到存活率高的大 Region，效率低
- **为什么用数组而不是堆（优先队列）？** 排序一次后顺序访问，数组的缓存局部性比堆好；且 Mixed GC 每次只选少量 Region，不需要动态插入

---

## 一、宏观理解：老年代区域选择器

### 1.1 一句话总结

**CollectionSetChooser 是 G1 的老年代区域选择器**，在并发标记完成后，负责从老年代中筛选出**回收效率高**的 Region，按 GC 效率排序，供 Mixed GC 选择。

### 1.2 为什么需要 CollectionSetChooser？

**问题背景**：
- Mixed GC 需要回收部分老年代区域以释放空间
- 老年代有数百到数千个 Region，不能全部回收（暂停时间限制）
- 需要优先回收"性价比"高的 Region（垃圾多、RS 小、回收快）

**解决方案**：
- CollectionSetChooser 维护一个**候选 Region 数组**
- 按**GC 效率**（ reclaimable_bytes / predicted_gc_time ）排序
- Mixed GC 时从数组头部依次选择，直到达到暂停时间目标

### 1.3 核心设计思想

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      CollectionSetChooser 设计思想                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   并发标记完成                                                               │
│        │                                                                     │
│        ▼                                                                     │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                         rebuild()                                   │   │
│   │  1. 并行遍历所有老年代 Region                                        │   │
│   │  2. 筛选符合条件的 Region（should_add）                              │   │
│   │     - 不是年轻代                                                     │   │
│   │     - 不是 Pinned                                                    │   │
│   │     - 存活对象比例 < G1MixedGCLiveThresholdPercent (默认 85%)        │   │
│   │     - 记忆集已构建完成                                               │   │
│   │  3. 计算 GC 效率（gc_efficiency）                                    │   │
│   │  4. 按 GC 效率排序（从高到低）                                       │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│        │                                                                     │
│        ▼                                                                     │
│   Mixed GC 触发                                                              │
│        │                                                                     │
│        ▼                                                                     │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                    finalize_old_part()                              │   │
│   │  循环：                                                              │   │
│   │    hr = peek()  <-- 获取最高效率的 Region                           │   │
│   │    if (满足所有约束条件)                                             │   │
│   │       pop()     <-- 从 Chooser 移除                                  │   │
│   │       add_old_region(hr)  <-- 加入 CSet                              │   │
│   │    else                                                            │   │
│   │       break                                                        │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.4 在 G1 中的位置

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         CollectionSetChooser 位置                           │
└─────────────────────────────────────────────────────────────────────────────┘

Concurrent Mark 完成
        │
        ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Concurrent Mark Cleanup                                                    │
│        │                                                                    │
│        ▼                                                                    │
│  record_concurrent_mark_cleanup_end()                                       │
│        │                                                                    │
│        ├──> cset_chooser()->rebuild()  <-- 重建候选 Region 列表             │
│        │       │                                                            │
│        │       ├──> 并行遍历所有老年代 Region                               │
│        │       ├──> 筛选符合条件的 Region                                   │
│        │       └──> 按 GC 效率排序                                          │
│        │                                                                    │
│        └──> mixed_gc_pending = next_gc_should_be_mixed()                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

Mixed GC 触发
        │
        ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  G1CollectionSet::finalize_old_part()                                       │
│        │                                                                    │
│        ├──> cset_chooser()->peek()  <-- 查看最高效率 Region                 │
│        ├──> cset_chooser()->pop()   <-- 取出并移除                          │
│        └──> add_old_region(hr)      <-- 加入 CSet                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 二、字段分析：数据结构的完整解剖

### 2.1 类定义与内存布局

```cpp
// collectionSetChooser.hpp:31-158
class CollectionSetChooser: public CHeapObj<mtGC> {
    // 核心存储：GrowableArray<HeapRegion*>
    GrowableArray<HeapRegion*> _regions;

    // 双指针管理（类似队列的 head/tail）
    uint _front;          // 下一个待收集的 Region 索引
    uint _end;            // 数组中有效 Region 的末尾

    // 并行添加支持
    uint _first_par_unreserved_idx;  // 下一个未分配的 chunk 索引

    // 筛选阈值
    size_t _region_live_threshold_bytes;  // 存活对象阈值（默认 85%）

    // 统计信息
    size_t _remaining_reclaimable_bytes;  // 剩余可回收字节数
};
```

**对象大小估算**：
```
CollectionSetChooser 对象：
  - _regions: GrowableArray 对象头 + 指针数组
  - _front, _end, _first_par_unreserved_idx: 12 bytes
  - _region_live_threshold_bytes, _remaining_reclaimable_bytes: 16 bytes
  - 总计：~40 bytes + 动态数组

_regions 数组（动态增长）：
  - 初始容量：100 个指针
  - 每个元素：8 bytes（HeapRegion*）
  - 老年代 Region 数：最多 2048 个（8GB 堆）
  - 实际占用：~16 KB（2048 × 8）
```

### 2.2 核心字段详解

#### 2.2.1 `_regions` —— Region 指针数组

**设计**：
```cpp
GrowableArray<HeapRegion*> _regions;
```

**内存布局**：
```
┌─────────────────────────────────────────────────────────────────┐
│                         _regions 数组                            │
│  ┌────────┬────────┬────────┬────────┬────────┬────────┐        │
│  │   r0   │   r1   │   r2   │  ...   │  rN-1  │ (空闲) │        │
│  └────────┴────────┴────────┴────────┴────────┴────────┘        │
│    8B      8B       8B              8B                          │
│                                                                  │
│   按 GC 效率从高到低排序                                          │
│   _front = 0                                                     │
│   _end = N（有效 Region 数量）                                    │
│                                                                  │
│   为什么用指针数组而不是索引数组？                                 │
│   - 需要存储 HeapRegion* 以便快速访问                              │
│   - 只在 Cleanup 阶段构建一次，内存占用可接受                      │
│   - G1CollectionSet 用索引数组是为了并发安全                        │
└─────────────────────────────────────────────────────────────────┘
```

#### 2.2.2 `_front` 和 `_end` —— 双指针管理

**设计**：
```cpp
uint _front;  // 队列头：下一个待 pop 的位置
uint _end;    // 队列尾：有效数据的末尾
```

**操作示例**：
```
初始状态：
  [r0, r1, r2, r3, r4, ...]
   ^              ^
   front=0        end=5

pop() 一次后：
  [NULL, r1, r2, r3, r4, ...]
         ^           ^
         front=1     end=5

pop() 两次后：
  [NULL, NULL, r2, r3, r4, ...]
               ^        ^
               front=2  end=5

remaining_regions() = _end - _front = 3
```

**为什么不用真正的队列（如链表）？**
- 需要**按索引随机访问**（并行遍历）
- 数组排序更高效（QuickSort）
- 延迟删除（NULL 标记）避免频繁内存移动

#### 2.2.3 `_remaining_reclaimable_bytes` —— 剩余可回收字节

**作用**：
- 跟踪还有多少垃圾可以回收
- 用于判断 Mixed GC 是否还有必要继续

**阈值检查**（g1Policy.cpp:1140-1147）：
```cpp
// 如果可回收百分比低于 G1HeapWastePercent，停止 Mixed GC
size_t reclaimable_bytes = cset_chooser()->remaining_reclaimable_bytes();
double reclaimable_percent = reclaimable_bytes_percent(reclaimable_bytes);
double threshold = (double) G1HeapWastePercent;  // 默认 5%

if (reclaimable_percent <= threshold) {
    // 停止 Mixed GC，回到 Young GC
    return false;
}
```

### 2.3 GC 效率计算

**定义**（heapRegion.hpp 中）：
```cpp
// gc_efficiency = reclaimable_bytes / predicted_gc_time
double gc_efficiency() {
    return (double) reclaimable_bytes() / (double) predicted_gc_time;
}
```

**排序比较**（collectionSetChooser.cpp:41-61）：
```cpp
static int order_regions(HeapRegion* hr1, HeapRegion* hr2) {
    double gc_eff1 = hr1->gc_efficiency();
    double gc_eff2 = hr2->gc_efficiency();
    if (gc_eff1 > gc_eff2) {
        return -1;  // hr1 效率更高，排前面
    } else if (gc_eff1 < gc_eff2) {
        return 1;
    } else {
        return 0;
    }
}
```

**为什么按 GC 效率而不是可回收字节排序？**
```
场景对比：

Region A: 可回收 100MB, 预测 GC 时间 50ms
          效率 = 100/50 = 2 MB/ms

Region B: 可回收 50MB, 预测 GC 时间 10ms
          效率 = 50/10 = 5 MB/ms

Region C: 可回收 200MB, 预测 GC 时间 200ms (RS 很大)
          效率 = 200/200 = 1 MB/ms

排序结果: B(5) > A(2) > C(1)

结论：优先回收 Region B，虽然垃圾少但回收快
```

### 2.4 筛选条件详解

**should_add() 方法**（collectionSetChooser.cpp:283-288）：
```cpp
bool CollectionSetChooser::should_add(HeapRegion* hr) const {
    return !hr->is_young() &&                          // 不是年轻代
           !hr->is_pinned() &&                         // 不是 Pinned
           region_occupancy_low_enough_for_evac(hr->live_bytes()) &&  // 存活比例低
           hr->rem_set()->is_complete();               // 记忆集已构建
}
```

**存活比例阈值**：
```cpp
// collectionSetChooser.hpp:104-106
static size_t mixed_gc_live_threshold_bytes() {
    return HeapRegion::GrainBytes * (size_t) G1MixedGCLiveThresholdPercent / 100;
}
// G1MixedGCLiveThresholdPercent 默认值 = 85
// 8GB 堆，4MB Region: 阈值 = 4MB × 85% = 3.4MB
```

**为什么需要这些筛选条件？**
| 条件 | 原因 |
|-----|------|
| 不是年轻代 | 年轻代由 Eden/Survivor 单独管理 |
| 不是 Pinned | Pinned Region 不能移动（JNI 关键段） |
| 存活比例 < 85% | 存活对象太多，复制成本高 |
| 记忆集已构建 | Mixed GC 需要扫描 RS |

---

## 三、方法分析：核心算法详解

### 3.1 重建候选列表：`rebuild()`

**流程图**：
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         rebuild() 流程                                       │
└─────────────────────────────────────────────────────────────────────────────┘

Concurrent Mark Cleanup 结束
         │
         ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  1. clear()                                                             │
│     清空 _regions，重置 _front=0, _end=0                                 │
└─────────────────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  2. prepare_for_par_region_addition()                                   │
│     预分配数组空间，准备并行添加                                         │
└─────────────────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  3. ParKnownGarbageTask（并行任务）                                     │
│     每个 GC 线程：                                                       │
│       - 遍历分配到的老年代 Region                                        │
│       - 调用 should_add() 筛选                                           │
│       - 符合条件的加入 _regions                                          │
└─────────────────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  4. sort_regions()                                                      │
│     按 GC 效率排序（从高到低）                                           │
└─────────────────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  5. verify()                                                            │
│     验证数组已排序、统计信息一致                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

**并行添加机制**：
```cpp
// 计算 chunk 大小：每个线程一次处理多少个 Region
uint chunk_size = calculate_parallel_work_chunk_size(n_workers, n_regions);
// 示例：2048 个 Region，8 个线程
// chunk_size = MAX2(2048/32, 2048/8) = MAX2(64, 256) = 256

// 每个线程的执行流程：
void work(uint worker_id) {
    ParKnownGarbageHRClosure cl(_hrSorted, _chunk_size);
    _g1h->heap_region_par_iterate_from_worker_offset(&cl, &_hrclaimer, worker_id);
}

// Closure 处理每个 Region：
bool do_heap_region(HeapRegion* r) {
    if (should_add(r)) {
        _cset_updater.add_region(r);  // 加入数组
    } else {
        r->rem_set()->clear(true);    // 清理 RS，释放内存
    }
}
```

### 3.2 Region 选择：`peek()` 和 `pop()`

**peek()** —— 查看最高效率 Region：
```cpp
HeapRegion* peek() {
    if (_front < _end) {
        return regions_at(_front);  // 返回但不移除
    }
    return NULL;  // 没有更多 Region
}
```

**pop()** —— 取出并移除最高效率 Region：
```cpp
HeapRegion* pop() {
    HeapRegion* hr = regions_at(_front);
    regions_at_put(_front, NULL);  // 标记为 NULL（延迟删除）
    
    // 更新统计信息
    _remaining_reclaimable_bytes -= hr->reclaimable_bytes();
    _front++;
    
    return hr;
}
```

**使用场景**（finalize_old_part）：
```cpp
HeapRegion* hr = cset_chooser()->peek();
while (hr != NULL) {
    // 检查各种约束...
    if (can_add) {
        cset_chooser()->pop();
        add_old_region(hr);
    } else {
        break;
    }
    hr = cset_chooser()->peek();
}
```

### 3.3 约束检查（在 finalize_old_part 中）

```cpp
// 约束 1：不能超过最大老年代 CSet 长度
if (old_region_length() >= max_old_cset_length) {
    break;
}

// 约束 2：可回收百分比必须超过阈值
size_t reclaimable_bytes = cset_chooser()->remaining_reclaimable_bytes();
double reclaimable_percent = _policy->reclaimable_bytes_percent(reclaimable_bytes);
if (reclaimable_percent <= G1HeapWastePercent) {  // 默认 5%
    break;
}

// 约束 3：预测时间不能超过剩余时间（但有例外）
double predicted_time_ms = predict_region_elapsed_time_ms(hr);
if (predicted_time_ms > time_remaining_ms) {
    // 例外：如果未达到最小长度，即使超时也要添加
    if (old_region_length() >= min_old_cset_length) {
        break;
    }
    // 否则添加这个 "expensive region"
}
```

---

## 四、关联分析：组件交互图

### 4.1 完整 Mixed GC CSet 选择流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Mixed GC CSet 选择完整流程                               │
└─────────────────────────────────────────────────────────────────────────────┘

Concurrent Mark 完成
         │
         ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Cleanup 阶段                                                           │
│  ────────────                                                           │
│  record_concurrent_mark_cleanup_end()                                   │
│       │                                                                 │
│       ├──> cset_chooser()->rebuild(workers, n_regions)                  │
│       │       │                                                         │
│       │       ├──> 并行筛选老年代 Region                                 │
│       │       ├──> 计算 GC 效率                                          │
│       │       └──> 按效率排序                                            │
│       │                                                                 │
│       └──> mixed_gc_pending = next_gc_should_be_mixed()                 │
│               检查：候选 Region 数量 > 0                                  │
│               检查：可回收百分比 > G1HeapWastePercent                    │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Mixed GC 触发                                                          │
│  ───────────                                                            │
│  G1CollectionSet::finalize_old_part()                                   │
│       │                                                                 │
│       ├──> cset_chooser()->peek()  获取最高效率 Region                   │
│       ├──> 检查约束（max/min/时间/可回收百分比）                         │
│       ├──> cset_chooser()->pop()   移除并加入 CSet                       │
│       └──> 循环直到不满足约束                                            │
│                                                                         │
│  排序策略：优先回收 GC 效率高的 Region                                    │
│  （垃圾多 + RS 小 + 复制快）                                              │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.2 与 G1Policy 的协作

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      CollectionSetChooser 协作图                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                         G1Policy                                       │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │  next_gc_should_be_mixed()                                       │  │  │
│  │  │    ├──> cset_chooser()->is_empty()                               │  │  │
│  │  │    └──> cset_chooser()->remaining_reclaimable_bytes()            │  │  │
│  │  │                                                                 │  │  │
│  │  │  finalize_collection_set()                                       │  │  │
│  │  │    └──> _collection_set->finalize_old_part()                     │  │  │
│  │  └─────────────────────────────────────────────────────────────────┘  │  │
│  │                              │                                        │  │
│  └──────────────────────────────┼────────────────────────────────────────┘  │
│                                 │                                           │
│  ┌──────────────────────────────┼────────────────────────────────────────┐  │
│  │                              ▼                                        │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │                    G1CollectionSet                               │  │  │
│  │  │  finalize_old_part():                                            │  │  │
│  │  │    while (true):                                                 │  │  │
│  │  │       hr = cset_chooser()->peek()   <-- 查看最高效率             │  │  │
│  │  │       if (!can_add) break                                        │  │  │
│  │  │       cset_chooser()->pop()         <-- 取出并移除               │  │  │
│  │  │       add_old_region(hr)            <-- 加入 CSet                │  │  │
│  │  └─────────────────────────────────────────────────────────────────┘  │  │
│  │                              │                                        │  │
│  └──────────────────────────────┼────────────────────────────────────────┘  │
│                                 │                                           │
│  ┌──────────────────────────────┼────────────────────────────────────────┐  │
│  │                              ▼                                        │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │                  CollectionSetChooser                            │  │  │
│  │  │  ┌─────────────────────────────────────────────────────────┐   │  │  │
│  │  │  │  _regions (按 GC 效率排序)                               │   │  │  │
│  │  │  │  [r0, r1, r2, r3, r4, ...]                              │   │  │  │
│  │  │  │   ↑         ↑                                           │   │  │  │
│  │  │  │   front     end                                         │   │  │  │
│  │  │  └─────────────────────────────────────────────────────────┘   │  │  │
│  │  │                                                                  │  │  │
│  │  │  _remaining_reclaimable_bytes                                   │  │  │
│  │  └─────────────────────────────────────────────────────────────────┘  │  │
│  └─────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 五、验证总结：日志与调试

### 5.1 关键日志输出

**启用详细日志**：
```bash
java -Xlog:gc+ergo+cset=debug,gc+liveness=trace \
     -Xms8g -Xmx8g -XX:+UseG1GC \
     -jar application.jar
```

**典型日志**：
```
# Cleanup 阶段重建 Chooser
[25.456s][debug][gc,liveness] Post-Sorting:
    Region 0: index=45, type=old, live=512KB, reclaimable=3584KB, gc_eff=71.23
    Region 1: index=123, type=old, live=1024KB, reclaimable=3072KB, gc_eff=30.15
    Region 2: index=78, type=old, live=2048KB, reclaimable=2048KB, gc_eff=10.05
    ...

# Mixed GC CSet 选择
[30.234s][debug][gc,ergo,cset] Finish choosing CSet.
    old: 12 regions,
    predicted old region time: 125.30ms,
    time remaining: 45.20ms

# 可回收空间检查
[35.678s][debug][gc,ergo] Do not continue mixed GCs
    (reclaimable percentage not over threshold).
    reclaimable: 314572800B (3.00%) threshold: 5
```

### 5.2 监控指标

| 指标 | 查看方法 | 健康范围 |
|-----|---------|---------|
| 候选 Region 数 | `cset_chooser()->length()` | > 0（Mixed GC 需要） |
| 剩余可回收空间 | `remaining_reclaimable_bytes()` | > heap × G1HeapWastePercent |
| GC 效率范围 | 日志输出 | 越高越好 |
| Mixed GC 次数 | GC 日志 | G1MixedGCCountTarget（默认 8） |

---

## 六、总结

### 6.1 CollectionSetChooser 的核心价值

CollectionSetChooser 实现了 G1 Mixed GC 的**智能区域选择**：

1. **筛选机制**：只选择回收价值高的老年代 Region
2. **排序策略**：按 GC 效率排序，优先回收"性价比"高的 Region
3. **动态管理**：每次并发标记后重建，反映最新的内存状况

### 6.2 关键设计要点

| 设计点 | 说明 |
|-------|------|
| **GC 效率排序** | reclaimable_bytes / predicted_gc_time，优先回收垃圾多且快的 Region |
| **双指针管理** | _front/_end 实现高效的 pop 操作，延迟删除避免内存移动 |
| **并行重建** | Cleanup 阶段多线程并行筛选和排序 |
| **动态阈值** | G1MixedGCLiveThresholdPercent（默认 85%）控制筛选严格程度 |

### 6.3 学习路径回顾

```
G1CollectedHeap::initialize() ──> 堆初始化
    ├── HeapRegionManager::initialize() ──> Region 管理
    ├── HeapRegion ──> 单 Region 结构（gc_efficiency()）
    ├── G1RemSet ──> 记忆集（is_complete()）
    │
    └── G1Policy ──> GC 决策中心
            ├── G1Predictions ──> 预测算法
            ├── G1Analytics ──> 统计数据
            │
            ├── G1CollectionSet ──> CSet 管理
            │       └── finalize_old_part() ──> 调用 Chooser
            │
            └── CollectionSetChooser ──> 老年代选择（当前）
                    └── rebuild() ──> Cleanup 阶段重建
```

---

**文档信息**：
- 分析版本：OpenJDK 11
- 分析日期：2026-02-10
- 源码路径：
  - `/data/workspace/openjdk-cut-new/src/hotspot/share/gc/g1/collectionSetChooser.hpp`
  - `/data/workspace/openjdk-cut-new/src/hotspot/share/gc/g1/collectionSetChooser.cpp`
