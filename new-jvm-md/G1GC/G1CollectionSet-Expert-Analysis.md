# G1CollectionSet 专家级源码分析

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1CollectionSet 的本质是**GC 回收目标 Region 的管理中心**：维护本次 GC 要回收的所有 Region（Eden + Survivor + 部分 Old），支持增量构建（Mutator 运行时逐步添加 Eden Region）和最终确定（GC 触发时添加 Survivor + Old Region）；提供并行遍历接口供多 GC Worker 使用。

### 0.2 为什么需要？

G1 GC 需要知道"本次 GC 要回收哪些 Region"，这个集合（CSet）在 GC 前需要确定。CSet 的构建有两个阶段：(1) Mutator 运行时增量添加 Eden Region（每次 Eden Region 满时加入）；(2) GC 触发时添加 Survivor + Old Region（Mixed GC 时）。G1CollectionSet 管理这个两阶段构建过程。

### 0.3 怎么解决？

**增量构建 + 并行遍历**：`add_eden_region()` 在 Mutator 运行时增量添加 Eden Region；`finalize_initial_collection_set()` 在 GC 触发时添加 Survivor；`finalize_old_part_of_collection_set()` 添加 Old Region（Mixed GC）；`G1CollectionSetChooser` 按垃圾密度排序 Old Region 候选列表。

### 0.4 为什么这样设计？

- **为什么 Eden Region 增量添加而不是 GC 时一次性添加？** Eden Region 在 Mutator 运行时动态分配，GC 触发时可能有数百个 Eden Region；增量添加避免 GC 触发时的大量遍历，减少 STW 时间
- **为什么 CSet 需要并行遍历接口？** Evacuation 阶段多个 GC Worker 并行处理 CSet 中的 Region；并行遍历接口让每个 Worker 独立获取下一个 Region，避免竞争

---

## 一、宏观理解：CSet（收集集合）的管理中心

### 1.1 一句话总结

**G1CollectionSet 是 G1 的收集集合（CSet）管理中心**，负责：
1. **增量构建** —— 在 mutator 运行时逐步收集 Eden 区域
2. **最终确定** —— GC 触发时确定 CSet 的最终内容（Eden + Survivor + Old）
3. **并行遍历** —— 支持多 GC 线程并行处理 CSet 中的 Region

### 1.2 为什么需要 G1CollectionSet？

**问题背景**：
- G1 的 Young GC 需要回收所有 Eden 区域和部分 Survivor 区域
- Mixed GC 还需要额外添加老年代区域
- CSet 需要支持**增量构建**（mutator 运行时逐步添加）和**最终确定**（GC 时冻结）

**解决方案**：
- G1CollectionSet 维护一个 Region 索引数组（`_collection_set_regions`）
- 使用**增量构建状态机**（Active/Inactive）管理构建过程
- 提供并行遍历接口支持多线程 GC

### 1.3 核心设计思想

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         G1CollectionSet 设计思想                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   增量构建阶段（Mutator 运行时）                                              │
│   ─────────────────────────────                                              │
│   分配 Eden Region ──> add_eden_region() ──> 加入增量 CSet                   │
│        │                                         │                           │
│        │                                         ▼                           │
│        │                              _collection_set_regions[]              │
│        │                              _inc_bytes_used_before                 │
│        │                              _inc_recorded_rs_lengths               │
│        │                              _inc_predicted_elapsed_time_ms         │
│        │                                                                     │
│        ▼                                                                     │
│   Region 满 ──>  retire ──> 分配新 Eden                                      │
│                                                                              │
│   ═══════════════════════════════════════════════════════════════════════   │
│                                                                              │
│   最终确定阶段（GC 触发时）                                                   │
│   ─────────────────────────                                                  │
│                                                                              │
│   finalize_young_part() ──> 确定年轻代 CSet                                  │
│        │                                                                     │
│        ├── 所有 Eden 区域（全部回收）                                        │
│        └── 所有 Survivor 区域（作为根）                                      │
│        │                                                                     │
│        ▼                                                                     │
│   finalize_old_part() ──> 确定老年代 CSet（Mixed GC）                        │
│        │                                                                     │
│        ├── 按回收效率排序的老年代区域                                         │
│        └── 受限于剩余暂停时间                                                 │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.4 在 G1 中的位置

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              G1Policy                                        │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │                    G1CollectionSet                               │  │  │
│  │  │                                                                  │  │  │
│  │  │  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────┐  │  │  │
│  │  │  │ _collection_set │    │ finalize_young  │    │ finalize_old│  │  │  │
│  │  │  │ _regions[]      │    │ _part()         │    │ _part()     │  │  │  │
│  │  │  │ (Region索引数组) │    │ (年轻代CSet)     │    │ (老年代CSet)│  │  │  │
│  │  │  └────────┬────────┘    └─────────────────┘    └─────────────┘  │  │  │
│  │  │           │                                                     │  │  │
│  │  │           ▼                                                     │  │  │
│  │  │  ┌─────────────────────────────────────────────────────────┐   │  │  │
│  │  │  │              _collection_set_regions                     │   │  │  │
│  │  │  │  ┌────┬────┬────┬────┬────┬─────────┬────┐              │   │  │  │
│  │  │  │  │r0  │r1  │r2  │r3  │r4  │  ...    │rN  │              │   │  │  │
│  │  │  │  └────┴────┴────┴────┴────┴─────────┴────┘              │   │  │  │
│  │  │  │   存储 HeapRegion 的 hrm_index                          │   │  │  │
│  │  │  └─────────────────────────────────────────────────────────┘   │  │  │
│  │  └─────────────────────────────────────────────────────────────────┘  │  │
│  │                                    │                                   │  │
│  │  ┌─────────────────────────────────┼───────────────────────────────┐  │  │
│  │  │         CollectionSetChooser    │                               │  │  │
│  │  │         (老年代区域排序选择器)   │                               │  │  │
│  │  └─────────────────────────────────┘                               │  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 二、字段分析：数据结构的完整解剖

### 2.1 类定义与内存布局

```cpp
// g1CollectionSet.hpp:39-197
class G1CollectionSet {
    // 核心引用
    G1CollectedHeap* _g1h;              // G1 堆引用
    G1Policy* _policy;                  // G1 策略引用
    CollectionSetChooser* _cset_chooser; // 老年代区域选择器
    
    // CSet 区域数量统计
    uint _eden_region_length;           // Eden 区域数
    uint _survivor_region_length;       // Survivor 区域数
    uint _old_region_length;            // Old 区域数
    
    // CSet 存储（核心数据结构）
    uint* _collection_set_regions;      // Region 索引数组
    volatile size_t _collection_set_cur_length;  // 当前长度
    size_t _collection_set_max_length;  // 最大容量（2048）
    
    // 统计数据
    size_t _bytes_used_before;          // CSet 中对象总大小
    size_t _recorded_rs_lengths;        // 记忆集总长度
    
    // 增量构建状态
    enum CSetBuildType { Active, Inactive };
    CSetBuildType _inc_build_state;     // 增量构建状态
    
    // 增量构建统计数据
    size_t _inc_bytes_used_before;      // 增量构建时统计的字节数
    size_t _inc_recorded_rs_lengths;    // 增量构建时统计的 RS 长度
    ssize_t _inc_recorded_rs_lengths_diffs; // RS 长度变化（并发更新用）
    double _inc_predicted_elapsed_time_ms;      // 预测时间
    double _inc_predicted_elapsed_time_ms_diffs;// 预测时间变化（并发更新用）
};
```

**对象大小估算**（64-bit 系统）：
```
G1CollectionSet 对象：
  - 指针（3个）：24 bytes
  - uint（3个）：12 bytes
  - size_t/volatile size_t（3个）：24 bytes
  - double（2个）：16 bytes
  - ssize_t（1个）：8 bytes
  - enum（1个）：4 bytes
  - 总计：~88 bytes + 对齐 = ~96 bytes

_collection_set_regions 数组：
  - 2048 个 uint = 8192 bytes = 8 KB

总计：~8.1 KB
```

### 2.2 核心字段详解

#### 2.2.1 `_collection_set_regions` —— Region 索引数组

**设计**：
```cpp
uint* _collection_set_regions;  // 指向 C 堆分配的数组
```

**内存布局**（initialize() 时分配）：
```
┌─────────────────────────────────────────────────────────────────┐
│                    _collection_set_regions                       │
│  ┌────┬────┬────┬────┬────┬─────────┬─────────┬─────────┐       │
│  │r0  │r1  │r2  │r3  │r4  │  ...    │ rN-1    │ (空闲)  │       │
│  └────┴────┴────┴────┴────┴─────────┴─────────┴─────────┘       │
│   4B   4B   4B   4B   4B            4B                        │
│                                                                  │
│   容量：_collection_set_max_length = 2048                        │
│   当前：_collection_set_cur_length = N                           │
│   元素：HeapRegion 的 hrm_index（Region 在数组中的索引）          │
│                                                                  │
│   为什么存索引而不是指针？                                         │
│   - 节省内存：uint(4B) < 指针(8B)                                │
│   - 支持并发：索引是值类型，更新安全                               │
│   - 通过 _g1h->region_at(index) 快速获取 Region 指针              │
└─────────────────────────────────────────────────────────────────┘
```

**并发安全设计**（iterate_from() 中的注释）：
```cpp
// 假设：最多只有一个 writer，但可以有多个 concurrent readers
// writer 使用 storestore barrier，reader 使用 loadload barrier
```

#### 2.2.2 `_collection_set_cur_length` —— 当前 CSet 长度

**设计**：
```cpp
volatile size_t _collection_set_cur_length;
```

**使用场景**：
- **增量构建阶段**：每次添加 Eden Region 时递增
- **最终确定阶段**：在 finalize_young_part() 时确定年轻代部分
- **Mixed GC**：在 finalize_old_part() 时继续添加老年代区域

**并发更新示例**（add_young_region_common）：
```cpp
_collection_set_regions[collection_set_length] = hr->hrm_index();
OrderAccess::storestore();  // 确保数组写入在长度更新前完成
_collection_set_cur_length++;
```

#### 2.2.3 增量构建相关字段

```cpp
// 增量构建状态
CSetBuildType _inc_build_state;  // Active = 接受新 Region，Inactive = 停止接受

// 增量统计数据（GC 时用于计算）
size_t _inc_bytes_used_before;           // CSet 中对象总大小
size_t _inc_recorded_rs_lengths;         // 记忆集总长度
double _inc_predicted_elapsed_time_ms;   // 预测 GC 时间

// 并发更新差异（避免锁竞争）
ssize_t _inc_recorded_rs_lengths_diffs;       // RS 长度变化
double _inc_predicted_elapsed_time_ms_diffs;  // 预测时间变化
```

**为什么需要 `_diffs` 字段？**
- 并发优化线程会定期采样年轻代的 RS 长度
- 直接更新 `_inc_recorded_rs_lengths` 需要加锁
- 解决方案：累积变化到 `_diffs`，GC 开始时批量应用

### 2.3 GDB 字段验证脚本

```gdb
# g1collectionset_fields.gdb - G1CollectionSet 字段验证

set pagination off

# 断点 1：initialize() 完成
break G1CollectionSet::initialize
commands
    silent
    printf "\n=== G1CollectionSet::initialize() ===\n"
    printf "this = 0x%lx\n", (unsigned long)this
    printf "max_region_length = %u\n", max_region_length
    printf "_collection_set_max_length = %zu\n", _collection_set_max_length
    printf "_collection_set_regions = 0x%lx (8KB)\n", (unsigned long)_collection_set_regions
    continue
end

# 断点 2：添加 Eden Region
break G1CollectionSet::add_eden_region
commands
    silent
    printf "\n=== add_eden_region ===\n"
    printf "hrm_index = %u\n", hr->hrm_index()
    printf "_collection_set_cur_length (before) = %zu\n", _collection_set_cur_length
    continue
end

# 断点 3：finalize_young_part 完成
break G1CollectionSet::finalize_young_part
commands
    silent
    printf "\n=== finalize_young_part ===\n"
    printf "_eden_region_length = %u\n", _eden_region_length
    printf "_survivor_region_length = %u\n", _survivor_region_length
    printf "_collection_set_cur_length = %zu\n", _collection_set_cur_length
    printf "_bytes_used_before = %zu\n", _bytes_used_before
    printf "return time_remaining_ms = %f\n", $return_value
    continue
end

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp ... Main
```

---

## 三、方法分析：CSet 构建流程

### 3.1 增量构建：`add_eden_region()` 和 `add_survivor_regions()`

**流程图**：
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         增量构建流程                                          │
└─────────────────────────────────────────────────────────────────────────────┘

Mutator 分配对象
        │
        ▼
┌───────────────────┐
│ G1AllocRegion::   │
│ allocate()        │
└─────────┬─────────┘
          │ Region 满？
          ▼
┌───────────────────┐
│ retire() ────────>│───> add_eden_region()
└───────────────────┘          │
                               ▼
                    ┌─────────────────────┐
                    │ add_young_region_common()
                    └──────────┬──────────┘
                               │
          ┌────────────────────┼────────────────────┐
          │                    │                    │
          ▼                    ▼                    ▼
┌───────────────────┐ ┌───────────────────┐ ┌───────────────────┐
│ _collection_set_  │ │ hr->set_young_    │ │ 统计信息更新       │
│ regions[length] = │ │ index_in_cset()   │ │ _inc_recorded_    │
│ hrm_index         │ │                   │ │ rs_lengths        │
└───────────────────┘ └───────────────────┘ │ _inc_predicted_   │
                                            │ elapsed_time_ms   │
                                            │ _inc_bytes_used_  │
                                            │ before            │
                                            └───────────────────┘
```

**代码解析**（add_young_region_common）：
```cpp
void G1CollectionSet::add_young_region_common(HeapRegion* hr) {
    // 1. 设置年轻代在 CSet 中的索引（用于并行遍历）
    hr->set_young_index_in_cset((int)collection_set_length);
    
    // 2. 将 Region 索引存入数组
    _collection_set_regions[collection_set_length] = hr->hrm_index();
    
    // 3. 内存屏障：确保数组写入在长度更新前完成
    OrderAccess::storestore();
    _collection_set_cur_length++;
    
    // 4. 更新统计信息（用于预测 GC 时间）
    if (!in_full_gc()) {
        size_t rs_length = hr->rem_set()->occupied();
        double region_time = predict_region_elapsed_time_ms(hr);
        
        _inc_recorded_rs_lengths += rs_length;
        _inc_predicted_elapsed_time_ms += region_time;
        _inc_bytes_used_before += hr->used();
        
        // 缓存到 Region，用于后续更新
        hr->set_recorded_rs_length(rs_length);
        hr->set_predicted_elapsed_time_ms(region_time);
    }
    
    // 5. 注册到堆（设置 in_collection_set 标志）
    _g1h->register_young_region_with_cset(hr);
}
```

### 3.2 年轻代 CSet 确定：`finalize_young_part()`

**流程图**：
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      finalize_young_part() 流程                              │
└─────────────────────────────────────────────────────────────────────────────┘

GC 触发
   │
   ▼
┌─────────────────────────┐
│ finalize_incremental_   │  <-- 应用 _diffs 累积的变化
│ building()              │
└──────────┬──────────────┘
           │
           ▼
┌─────────────────────────┐
│ 计算基础时间             │
│ base_time_ms = predict_ │
│ base_elapsed_time_ms()  │
└──────────┬──────────────┘
           │
           ▼
┌─────────────────────────┐     ┌─────────────────────────┐
│ time_remaining_ms =     │     │ init_region_lengths()   │
│ target - base_time      │     │ - eden_region_length    │
│ - inc_predicted_time    │     │ - survivor_region_length│
└──────────┬──────────────┘     └─────────────────────────┘
           │
           │ 返回 time_remaining_ms
           │（用于 finalize_old_part）
           ▼
```

**代码解析**：
```cpp
double G1CollectionSet::finalize_young_part(double target_pause_time_ms, 
                                            G1SurvivorRegions* survivors) {
    // 1. 完成增量构建（应用并发更新的差异）
    finalize_incremental_building();
    
    // 2. 计算基础 GC 时间（UpdateRS + ScanRS 等固定开销）
    size_t pending_cards = _policy->pending_cards();
    double base_time_ms = _policy->predict_base_elapsed_time_ms(pending_cards);
    double time_remaining_ms = target_pause_time_ms - base_time_ms;
    
    // 3. 确定年轻代区域数量
    uint survivor_length = survivors->length();
    uint eden_length = _g1h->eden_regions_count();
    init_region_lengths(eden_length, survivor_length);
    
    // 4. 计算年轻代 GC 时间
    _bytes_used_before = _inc_bytes_used_before;
    time_remaining_ms -= _inc_predicted_elapsed_time_ms;
    
    // 5. 保存 RS 长度统计
    set_recorded_rs_lengths(_inc_recorded_rs_lengths);
    
    return time_remaining_ms;  // 剩余时间用于老年代 CSet
}
```

### 3.3 老年代 CSet 确定：`finalize_old_part()`

**流程图**：
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       finalize_old_part() 流程                               │
└─────────────────────────────────────────────────────────────────────────────┘

time_remaining_ms（来自 finalize_young_part）
         │
         ▼
┌─────────────────────┐
│ in_mixed_phase()?   │──No──> return（Young GC 结束）
└──────────┬──────────┘
          Yes
           ▼
┌─────────────────────┐     ┌─────────────────────┐
│ calc_min/max_old_   │     │ CollectionSetChooser│
│ cset_length()       │     │ ::peek()            │
│ - min: 必须回收的数量 │     │ （按回收效率排序）   │
│ - max: 不能超过的数量 │     │                     │
└──────────┬──────────┘     └──────────┬──────────┘
           │                           │
           └───────────┬───────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│                    老年代区域选择循环                            │
│  for each candidate region:                                      │
│    1. 检查是否超过 max_old_cset_length                           │
│    2. 检查可回收百分比是否超过 G1HeapWastePercent                │
│    3. 检查预测时间是否超过 time_remaining_ms                     │
│    4. 如果满足条件，加入 CSet                                    │
│                                                                  │
│  约束：即使时间超限，也要保证达到 min_old_cset_length            │
└─────────────────────────────────────────────────────────────────┘
```

**核心选择逻辑**（finalize_old_part）：
```cpp
void G1CollectionSet::finalize_old_part(double time_remaining_ms) {
    if (collector_state()->in_mixed_phase()) {
        const uint min_old_cset_length = _policy->calc_min_old_cset_length();
        const uint max_old_cset_length = _policy->calc_max_old_cset_length();
        
        bool check_time_remaining = _policy->adaptive_young_list_length();
        uint expensive_region_num = 0;
        
        HeapRegion* hr = cset_chooser()->peek();
        while (hr != NULL) {
            // 约束 1：不能超过最大老年代 CSet 长度
            if (old_region_length() >= max_old_cset_length) {
                break;
            }
            
            // 约束 2：可回收百分比必须超过阈值
            size_t reclaimable_bytes = cset_chooser()->remaining_reclaimable_bytes();
            double reclaimable_percent = _policy->reclaimable_bytes_percent(reclaimable_bytes);
            if (reclaimable_percent <= G1HeapWastePercent) {
                break;
            }
            
            double predicted_time_ms = predict_region_elapsed_time_ms(hr);
            
            // 约束 3：预测时间不能超过剩余时间（但有例外）
            if (check_time_remaining && predicted_time_ms > time_remaining_ms) {
                // 例外：如果已经达到最小长度，则停止
                if (old_region_length() >= min_old_cset_length) {
                    break;
                }
                // 否则即使超时也要添加（expensive regions）
                expensive_region_num++;
            }
            
            // 添加 Region 到 CSet
            time_remaining_ms -= predicted_time_ms;
            cset_chooser()->pop();
            add_old_region(hr);
            
            hr = cset_chooser()->peek();
        }
    }
    
    // 最后对 CSet 按 Region 索引排序（优化缓存）
    QuickSort::sort(_collection_set_regions, _collection_set_cur_length, 
                    compare_region_idx, true);
}
```

### 3.4 并行遍历：`iterate_from()`

**设计目标**：
- 多 GC 线程并行处理 CSet
- 每个线程处理 CSet 的不同部分
- 支持工作窃取（循环遍历）

**算法**：
```cpp
void G1CollectionSet::iterate_from(HeapRegionClosure* cl, 
                                   uint worker_id, 
                                   uint total_workers) const {
    size_t len = _collection_set_cur_length;
    OrderAccess::loadload();  // 确保看到最新的 CSet 长度
    
    if (len == 0) return;
    
    // 计算起始位置（均匀分配）
    size_t start_pos = (worker_id * len) / total_workers;
    size_t cur_pos = start_pos;
    
    do {
        // 获取当前 Region
        HeapRegion* r = _g1h->region_at(_collection_set_regions[cur_pos]);
        
        // 应用闭包
        bool result = cl->do_heap_region(r);
        if (result) {
            cl->set_incomplete();
            return;
        }
        
        // 循环到下一个位置
        cur_pos++;
        if (cur_pos == len) {
            cur_pos = 0;  // 循环回开头
        }
    } while (cur_pos != start_pos);  // 处理完一圈后停止
}
```

**示例**（4 个 GC 线程，CSet 有 12 个 Region）：
```
CSet: [r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11]

worker 0: start=0,  处理 r0, r1, r2  (然后循环)
worker 1: start=3,  处理 r3, r4, r5
worker 2: start=6,  处理 r6, r7, r8
worker 3: start=9,  处理 r9, r10, r11

如果某个线程先完成，可以继续处理其他线程的区域（循环设计）
```

---

## 四、关联分析：组件交互图

### 4.1 完整 CSet 构建流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    G1CollectionSet 完整构建流程                               │
└─────────────────────────────────────────────────────────────────────────────┘

应用运行阶段
     │
     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      增量构建（Mutator 运行时）                            │
│                                                                          │
│   分配 Region ──> add_eden_region()                                      │
│                       │                                                  │
│                       ▼                                                  │
│              add_young_region_common()                                   │
│                       │                                                  │
│          ┌────────────┼────────────┐                                    │
│          │            │            │                                    │
│          ▼            ▼            ▼                                    │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐                              │
│   │ _collection│  │ _inc_     │  │ _g1h->   │                              │
│   │ _set_    │  │ recorded │  │ register_│                              │
│   │ regions[]│  │ rs_lengths│  │ young_   │                              │
│   └──────────┘  └──────────┘  └──────────┘                              │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼  GC 触发（Eden 满）
┌─────────────────────────────────────────────────────────────────────────┐
│                      最终确定阶段（GC 暂停期间）                           │
│                                                                          │
│   G1Policy::finalize_collection_set()                                    │
│           │                                                              │
│           ├──> finalize_young_part()                                     │
│           │         │                                                    │
│           │         ├──> Eden + Survivor = 年轻代 CSet                    │
│           │         └──> return time_remaining_ms                        │
│           │                                                              │
│           └──> finalize_old_part(time_remaining_ms)                      │
│                     │                                                    │
│                     ├──> 从 CollectionSetChooser 选择老年代区域          │
│                     │     （按回收效率排序）                              │
│                     │                                                    │
│                     └──> 受限于：max_old_cset_length                     │
│                           min_old_cset_length                            │
│                           time_remaining_ms                              │
│                           G1HeapWastePercent                             │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        GC 执行阶段（并行）                                │
│                                                                          │
│   iterate_from(closure, worker_id, total_workers)                        │
│        │                                                                 │
│        └──> 每个 GC 线程处理 CSet 的不同部分                              │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.2 与 CollectionSetChooser 的关系

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                   CollectionSetChooser 简介                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   作用：管理标记周期中发现的老年代垃圾区域，按回收效率排序                      │
│                                                                              │
│   数据结构：                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                    CollectionSetChooser                            │   │
│   │  ┌─────────────────────────────────────────────────────────────┐   │   │
│   │  │  _regions (GrowableArray<HeapRegion*>)                       │   │   │
│   │  │  ┌────────┬────────┬────────┬────────┬────────┐              │   │   │
│   │  │  │region1 │region2 │region3 │  ...   │regionN │              │   │   │
│   │  │  └────────┴────────┴────────┴────────┴────────┘              │   │   │
│   │  │                                                              │   │   │
│   │  │  排序依据：回收效率 = 可回收字节 / 预测 GC 时间                 │   │   │
│   │  │  （高回收效率的区域优先）                                       │   │   │
│   │  └─────────────────────────────────────────────────────────────┘   │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│   使用：                                                                     │
│   - peek() 查看最高效率的 Region                                             │
│   - pop()  取出并移除该 Region                                               │
│   - 在 finalize_old_part() 中循环添加老年代区域到 CSet                        │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 五、验证总结：日志与调试

### 5.1 关键日志输出

**启用 CSet 详细日志**：
```bash
java -Xlog:gc+ergo+cset=debug:file=gc-cset.log:time,uptime,level,tags \
     -Xms8g -Xmx8g -XX:+UseG1GC \
     -jar application.jar
```

**典型日志分析**：
```
# Young GC CSet 日志
[15.234s][debug][gc,ergo,cset] Start choosing CSet. 
    pending cards: 45678 
    predicted base time: 82.34ms 
    remaining time: 117.66ms 
    target pause time: 200.00ms

[15.234s][debug][gc,ergo,cset] Add young regions to CSet. 
    eden: 128 regions, 
    survivors: 12 regions, 
    predicted young region time: 95.20ms, 
    target pause time: 200.00ms

# Mixed GC CSet 日志
[25.456s][debug][gc,ergo,cset] Finish choosing CSet. 
    old: 8 regions, 
    predicted old region time: 45.30ms, 
    time remaining: 72.46ms
```

### 5.2 监控指标

| 指标 | 查看方法 | 健康范围 |
|-----|---------|---------|
| CSet 大小 | `_collection_set_cur_length` | 根据目标暂停时间动态调整 |
| 年轻代比例 | young_length / total_length | 通常 > 80% |
| 老年代添加 | old_region_length | Mixed GC 时 > 0 |
| 预测准确度 | 对比预测 vs 实际 GC 时间 | 误差 < 20% |

---

## 六、总结

### 6.1 G1CollectionSet 的核心价值

G1CollectionSet 实现了 G1 的**增量 CSet 构建**机制：

1. **增量构建**：mutator 运行时逐步收集 Eden 区域
2. **最终确定**：GC 触发时快速确定 CSet 内容
3. **并行处理**：支持多 GC 线程并行遍历 CSet

### 6.2 关键设计要点

| 设计点 | 说明 |
|-------|------|
| **Region 索引数组** | 存储 hrm_index 而非指针，节省内存且线程安全 |
| **增量状态机** | Active/Inactive 状态控制增量构建过程 |
| **并发更新优化** | 使用 `_diffs` 字段避免锁竞争 |
| **并行遍历** | `iterate_from()` 支持多线程均匀分配 |
| **分层 CSet** | 先确定年轻代，剩余时间用于老年代 |

### 6.3 学习路径回顾

```
G1CollectedHeap::initialize() ──> 堆初始化
    ├── HeapRegionManager::initialize() ──> Region 管理
    ├── HeapRegion ──> 单 Region 结构
    ├── G1RemSet ──> 记忆集
    │
    └── G1Policy ──> GC 决策中心
            ├── G1Predictions ──> 预测算法
            ├── G1Analytics ──> 统计数据
            │
            └── G1CollectionSet ──> CSet 管理（当前）
                    └── CollectionSetChooser ──> 老年代选择（待分析）
```

---

**文档信息**：
- 分析版本：OpenJDK 11
- 分析日期：2026-02-10
- 源码路径：
  - `/data/workspace/openjdk-cut-new/src/hotspot/share/gc/g1/g1CollectionSet.hpp`
  - `/data/workspace/openjdk-cut-new/src/hotspot/share/gc/g1/g1CollectionSet.cpp`
