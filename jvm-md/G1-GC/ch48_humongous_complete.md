# Ch48: G1 Humongous 对象完整追踪 — 分配 + Eager Reclaim 全链路

> **标准环境**: `-Xms8g -Xmx8g -XX:+UseG1GC`, 16 核, Region 4MB, Humongous 阈值 2MB
> **前置文档**: `Universe/E.4-HumongousThreshold.md`（阈值计算）、`Universe/C.7-FastTestArrays.md`（快速查询数组）
> **核心源码**: `g1CollectedHeap.cpp`（分配 + 回收）、`heapRegion.cpp`（Region 设置）、`heapRegionType.hpp`（类型标记）

---

## 1. 解决什么问题？

G1 的堆被划分为固定大小的 Region（4MB）。但程序中可能会分配**非常大的对象**——大到一个 Region 放不下（或者即使放得下，也占了 Region 的大部分空间）。

**核心问题**：如何处理超过 Region 容量一半的巨型对象？

如果把巨型对象塞进普通 Eden Region：
- 对象可能超过 Region 大小，物理上放不下
- 即使放得下，也会导致 Region 内碎片化，浪费空间
- 巨型对象如果晋升到 Old，复制成本极高

**G1 的解决方案**：为巨型对象开辟专门的 **Humongous Region**，不走正常的 Eden 分配路径，直接在 Old 代分配连续的 Region 序列。

---

## 2. 核心概念

### 2.1 什么是 Humongous 对象？

```cpp
// g1CollectedHeap.hpp:1248
static bool is_humongous(size_t word_size) {
    return word_size > _humongous_object_threshold_in_words;
}

// g1CollectedHeap.hpp:1252
static size_t humongous_threshold_for(size_t region_size) {
    return (region_size / 2);  // Region 大小的一半
}
```

**判断公式**：`对象大小 > Region大小 / 2`

在标准环境下：
- Region = 4MB = 524,288 words
- 阈值 = 524,288 / 2 = **262,144 words = 2MB**
- 任何 **>2MB** 的对象都是 Humongous 对象

### 2.2 Humongous Region 的两种类型

```
HeapRegionType 编码：
  StartsHumongousTag    = HumongousMask | PinnedMask = 4 | 8 = 12  (0b01100)
  ContinuesHumongousTag = HumongousMask | PinnedMask + 1    = 13  (0b01101)
```

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 3MB 对象 (占 1 个 Region)                                                   │
│                                                                             │
│  Region #N                                                                  │
│  ┌─────────────────────────────────────────────────────────┐                │
│  │ type: StartsHumongous (12)                              │                │
│  │ _humongous_start_region = this                          │                │
│  │ ┌──────────────────────────────┐┌──────────────────────┐│                │
│  │ │   3MB 对象数据               ││  ~1MB 填充 (filler)  ││                │
│  │ │   bottom → obj_top           ││  obj_top → end       ││                │
│  │ └──────────────────────────────┘└──────────────────────┘│                │
│  └─────────────────────────────────────────────────────────┘                │
│                                                                             │
│ 6MB 对象 (跨 2 个 Region)                                                   │
│                                                                             │
│  Region #M                          Region #M+1                             │
│  ┌──────────────────────────┐       ┌──────────────────────────┐            │
│  │ type: StartsHumongous    │       │ type: ContinuesHumongous │            │
│  │ _humongous_start = this  │       │ _humongous_start = #M    │            │
│  │ ┌──────────────────────┐ │       │ ┌─────────┐┌───────────┐│            │
│  │ │    4MB 对象数据       │ │       │ │ ~2MB    ││ ~2MB 填充 ││            │
│  │ │    bottom → end       │ │       │ │ 数据    ││ (filler)  ││            │
│  │ └──────────────────────┘ │       │ └─────────┘└───────────┘│            │
│  └──────────────────────────┘       └──────────────────────────┘            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**关键特性**：
- Humongous Region 同时具有 `HumongousMask` 和 `PinnedMask`，这意味着它是**固定的**（Pinned），不会被疏散
- `_humongous_start_region` 指针使得 ContinuesHumongous 可以快速找到对应的 StartsHumongous
- Region 尾部的空闲空间用 filler 对象填充（用于堆遍历的完整性）

### 2.3 GDB 验证 — 阈值与类型编码

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
┌──────────────────────────────────────────────────────────────┐
│ HeapRegion::GrainBytes = 4,194,304 (4MB)                     │
│ HeapRegion::GrainWords = 524,288                             │
│ _humongous_object_threshold_in_words = 262,144 (= 2MB)      │
│                                                              │
│ StartsHumongousTag = 12  (HumongousMask=4 | PinnedMask=8)   │
│ ContinuesHumongousTag = 13                                   │
│ HumongousMask = 4                                            │
│ PinnedMask = 8                                               │
│                                                              │
│ is_humongous() = (tag & 4) != 0                              │
│ is_pinned()    = (tag & 8) != 0                              │
│ → Humongous Region 同时满足 is_humongous() 和 is_pinned()   │
└──────────────────────────────────────────────────────────────┘
```

---

## 3. 分配全链路

### 3.1 入口：从哪里进入 Humongous 分配？

```
应用线程分配对象
  └── G1CollectedHeap::mem_allocate()
       └── is_humongous(word_size) ?  ← 判断是否为大对象
           ├── false → attempt_allocation() → 正常 TLAB/Eden 分配
           └── true  → attempt_allocation_humongous()  ← Humongous 路径
                         └── humongous_obj_allocate()
                              └── humongous_obj_allocate_initialize_regions()
```

注意：Humongous 对象的分配**不经过 TLAB**，也不在 Eden 中，而是直接在堆上找连续的空闲 Region。

### 3.2 attempt_allocation_humongous — 慢路径分配循环

```cpp
// g1CollectedHeap.cpp:870
HeapWord* G1CollectedHeap::attempt_allocation_humongous(size_t word_size) {
    // ① 可能触发并发标记
    if (g1_policy()->need_to_start_conc_mark("concurrent humongous allocation", word_size)) {
        collect(GCCause::_g1_humongous_allocation);
    }

    // ② 分配循环
    for (uint try_count = 1; /* ... */; try_count += 1) {
        {
            MutexLockerEx x(Heap_lock);  // 必须持有堆锁

            // ③ 尝试直接分配
            result = humongous_obj_allocate(word_size);
            if (result != NULL) {
                // 统计 + 返回
                return result;
            }

            // ④ 分配失败，需要 GC
            should_try_gc = !GCLocker::needs_gc();
            gc_count_before = total_collections();
        }

        if (should_try_gc) {
            // ⑤ 触发 Young GC（GCCause::_g1_humongous_allocation）
            result = do_collection_pause(word_size, gc_count_before, &succeeded,
                                         GCCause::_g1_humongous_allocation);
            if (result != NULL) return result;
            if (succeeded) return NULL;  // GC 成功但分配失败 → OOM
        } else {
            // ⑥ GCLocker 激活中，等待
            GCLocker::stall_until_clear();
        }
    }
}
```

**关键设计**：
- Humongous 分配必须**持有 Heap_lock**（`MutexLockerEx x(Heap_lock)`），因为需要操作全局的 free list
- 分配失败时触发的 GC 原因是 `_g1_humongous_allocation`，这个原因会触发**并发标记启动**
- 循环重试直到成功或确认无法分配

### 3.3 humongous_obj_allocate — Region 查找策略（三级递退）

```cpp
// g1CollectedHeap.cpp:327
HeapWord* G1CollectedHeap::humongous_obj_allocate(size_t word_size) {
    assert_heap_locked_or_at_safepoint(true);

    uint first = G1_NO_HRM_INDEX;
    uint obj_regions = (uint) humongous_obj_size_in_regions(word_size);

    // ========== 策略 1：单 Region 快速路径 ==========
    if (obj_regions == 1) {
        HeapRegion* hr = new_region(word_size, true /* is_old */, false /* do_expand */);
        if (hr != NULL) {
            first = hr->hrm_index();
        }
    } else {
        // ========== 策略 2：从 free list 中找连续的已提交 Region ==========
        first = _hrm.find_contiguous_only_empty(obj_regions);
        if (first != G1_NO_HRM_INDEX) {
            _hrm.allocate_free_regions_starting_at(first, obj_regions);
        }
    }

    if (first == G1_NO_HRM_INDEX) {
        // ========== 策略 3：找连续的空闲或未提交 Region，然后扩堆 ==========
        first = _hrm.find_contiguous_empty_or_unavailable(obj_regions);
        if (first != G1_NO_HRM_INDEX) {
            _hrm.expand_at(first, obj_regions, workers());  // 扩堆提交内存
            _hrm.allocate_free_regions_starting_at(first, obj_regions);
        }
    }

    // ========== 分配成功，初始化 Region ==========
    HeapWord* result = NULL;
    if (first != G1_NO_HRM_INDEX) {
        result = humongous_obj_allocate_initialize_regions(first, obj_regions, word_size);
        g1mm()->update_sizes();
    }

    return result;
}
```

**三级递退策略总结**：

```
策略 1: 单 Region 快速路径 (obj_regions == 1)
  └── new_region() 直接从 free list 取一个 Region
  └── 不需要连续性，最快

策略 2: 从 free list 找连续已提交 Region (obj_regions > 1)
  └── find_contiguous_only_empty(N)
  └── 要求 N 个连续的已提交空闲 Region
  └── 不扩堆

策略 3: 找连续空闲/未提交 Region + 扩堆
  └── find_contiguous_empty_or_unavailable(N)
  └── 允许包含未提交的 Region
  └── expand_at() 提交物理内存
  └── 最后手段（除了 GC 重试）
```

### 3.4 humongous_obj_allocate_initialize_regions — Region 初始化（并发安全）

这是最复杂的部分，因为初始化过程必须**与并发的 Refinement 线程安全交互**。

```cpp
// g1CollectedHeap.cpp:201
HeapWord* G1CollectedHeap::humongous_obj_allocate_initialize_regions(
    uint first, uint num_regions, size_t word_size) {

    uint last = first + num_regions - 1;
    size_t word_size_sum = (size_t) num_regions * HeapRegion::GrainWords;

    HeapRegion* first_hr = region_at(first);
    HeapWord* new_obj = first_hr->bottom();    // 对象起始地址
    HeapWord* obj_top = new_obj + word_size;    // 对象结束地址

    // ① 清零对象头 — 防止 Refinement 线程误读
    Copy::fill_to_words(new_obj, oopDesc::header_size(), 0);

    // ② 填充尾部空闲空间
    size_t word_fill_size = word_size_sum - word_size;
    if (word_fill_size >= min_fill_size()) {
        fill_with_objects(obj_top, word_fill_size);  // 放 filler 对象
    }

    // ③ 设置第一个 Region 为 StartsHumongous
    first_hr->set_starts_humongous(obj_top, word_fill_size);
    _g1_policy->remset_tracker()->update_at_allocate(first_hr);

    // ④ 设置后续 Region 为 ContinuesHumongous
    for (uint i = first + 1; i <= last; ++i) {
        HeapRegion* hr = region_at(i);
        hr->set_continues_humongous(first_hr);
        _g1_policy->remset_tracker()->update_at_allocate(hr);
    }

    // ⑤ StoreStore 屏障 — 确保所有初始化操作对其他线程可见
    OrderAccess::storestore();

    // ⑥ 更新所有 Region 的 top 指针
    for (uint i = first; i < last; ++i) {
        region_at(i)->set_top(region_at(i)->end());  // 前面的 Region 填满
    }
    HeapRegion* last_hr = region_at(last);
    last_hr->set_top(last_hr->end() - words_not_fillable);

    // ⑦ 更新统计 + 加入 _humongous_set
    increase_used((word_size_sum - words_not_fillable) * HeapWordSize);
    for (uint i = first; i <= last; ++i) {
        _humongous_set.add(region_at(i));
        _hr_printer.alloc(region_at(i));
    }

    return new_obj;
}
```

#### 3.4.1 为什么要先清零对象头？

```cpp
// 代码注释原文翻译：
// 当我们更新 top 指针后，一些 Refinement 线程可能会尝试扫描该 Region。
// 通过清零头部，我们确保任何尝试扫描的线程会遇到零值 klass 指针而退出。
//
// 注意：不能用 CollectedHeap::fill_with_object() 让它看起来像一个 int 数组。
// 因为分配线程稍后会更新对象头为不同的数组类型，在极短的时间窗口内
// klass 和 length 字段会不一致，可能导致 Refinement 线程计算出错误的对象大小。
```

这是一个**并发安全**的关键设计：
1. 先清零对象头（klass 指针 = 0）
2. 完成所有 Region 初始化
3. `OrderAccess::storestore()` 内存屏障
4. 最后才更新 top 指针（使对象"可见"）

Refinement 线程如果在 top 更新后扫描到这个 Region，会看到 klass=0 并安全退出。

#### 3.4.2 set_starts_humongous 的实现

```cpp
// heapRegion.cpp:197
void HeapRegion::set_starts_humongous(HeapWord* obj_top, size_t fill_size) {
    assert(!is_humongous(), "sanity");
    assert(top() == bottom(), "should be empty");

    _type.set_starts_humongous();              // 设置类型标记为 12
    _humongous_start_region = this;            // 指向自己

    _bot_part.set_for_starts_humongous(obj_top, fill_size);  // 设置 BOT
}
```

#### 3.4.3 set_continues_humongous 的实现

```cpp
// heapRegion.cpp:209
void HeapRegion::set_continues_humongous(HeapRegion* first_hr) {
    assert(!is_humongous(), "sanity");
    assert(top() == bottom(), "should be empty");
    assert(first_hr->is_starts_humongous(), "pre-condition");

    _type.set_continues_humongous();           // 设置类型标记为 13
    _humongous_start_region = first_hr;        // 指向 StartsHumongous Region

    _bot_part.set_object_can_span(true);       // BOT 标记为"对象可跨越"
}
```

### 3.5 GDB 验证 — 分配运行时数据

```
【GDB 验证】分配 3MB byte[] 数组
┌────────────────────────────────────────────────────────────────────┐
│ humongous_obj_allocate() 被调用                                    │
│   word_size = 393,218 words = 3,145,744 bytes ≈ 3MB               │
│   _humongous_threshold = 262,144 words = 2,097,152 bytes = 2MB    │
│   393,218 > 262,144 → is_humongous = true                         │
│   obj_regions = ceil(393218 / 524288) = 1 个 Region               │
│                                                                    │
│ humongous_obj_allocate_initialize_regions() 被调用                  │
│   first = 0 (Region #0)                                           │
│   num_regions = 1                                                  │
│   word_size_sum = 1 × 524,288 = 524,288 words = 4MB               │
│   word_fill_size = 524,288 - 393,218 = 131,070 words ≈ 1MB       │
│   → Region #0 设置为 StartsHumongous                               │
│   → 尾部 ~1MB 用 filler 对象填充                                   │
└────────────────────────────────────────────────────────────────────┘

【GDB 验证】分配 6MB byte[] 数组
┌────────────────────────────────────────────────────────────────────┐
│ humongous_obj_allocate() 被调用                                    │
│   word_size = 786,434 words = 6,291,472 bytes ≈ 6MB               │
│   obj_regions = ceil(786434 / 524288) = 2 个 Region               │
│                                                                    │
│ humongous_obj_allocate_initialize_regions() 被调用                  │
│   first = 1 (Region #1，因为 #0 已被 3MB 对象占用)                │
│   num_regions = 2                                                  │
│   word_size_sum = 2 × 524,288 = 1,048,576 words = 8MB             │
│   word_fill_size = 1,048,576 - 786,434 = 262,142 words ≈ 2MB     │
│   → Region #1 设置为 StartsHumongous                               │
│   → Region #2 设置为 ContinuesHumongous (start → Region #1)       │
│   → 尾部 ~2MB 用 filler 对象填充                                   │
└────────────────────────────────────────────────────────────────────┘
```

### 3.6 分配全流程时序图

```
应用线程                               G1CollectedHeap                 HeapRegionManager
─────────────────────────────────────────────────────────────────────────────────────────
new byte[3MB]
  │
  ├── mem_allocate(393218)
  │     └── is_humongous? → true (393218 > 262144)
  │
  ├── attempt_allocation_humongous(393218)
  │     │
  │     ├── MutexLockerEx(Heap_lock)  ← 加堆锁
  │     │
  │     ├── humongous_obj_allocate(393218)
  │     │     │
  │     │     ├── obj_regions = 1
  │     │     ├── new_region(393218, old, !expand) ────────────────── 从 free list 取 Region #0
  │     │     │                                                        └── first = 0
  │     │     │
  │     │     └── humongous_obj_allocate_initialize_regions(0, 1, 393218)
  │     │           ├── Copy::fill_to_words(bottom, 2, 0)    清零对象头
  │     │           ├── fill_with_objects(obj_top, 131070)    填充尾部
  │     │           ├── first_hr->set_starts_humongous()      设置类型
  │     │           ├── OrderAccess::storestore()             内存屏障
  │     │           ├── first_hr->set_top(end)                更新 top
  │     │           └── _humongous_set.add(first_hr)          加入集合
  │     │
  │     └── unlock Heap_lock
  │
  └── 返回 new_obj 地址 ← 对象分配在 Region #0 的 bottom
```


---

## 4. Eager Reclaim 全链路 — 在 Young GC 中回收 Humongous 对象

### 4.1 解决什么问题？

Humongous 对象分配在 Old 代，传统上只能在 Mixed GC 或 Full GC 中回收。但现实中，很多 Humongous 对象是**短生命周期**的（比如临时的大 byte 数组），如果等到 Mixed GC 才回收，会浪费大量内存。

**Eager Reclaim** 的核心思想：**在每次 Young GC 时，顺便检查 Humongous 对象是否已经死亡，如果是就立即回收**。

### 4.2 相关 JVM 参数

```cpp
// g1_globals.hpp:253
experimental(bool, G1EagerReclaimHumongousObjects, true,
    "Try to reclaim dead large objects at every young GC.")

experimental(bool, G1EagerReclaimHumongousObjectsWithStaleRefs, true,
    "Try to reclaim dead large objects that have a few stale "
    "references at every young GC.")
```

| 参数 | 默认值 | 作用 |
|------|--------|------|
| `G1EagerReclaimHumongousObjects` | **true** | 总开关：是否启用 Eager Reclaim |
| `G1EagerReclaimHumongousObjectsWithStaleRefs` | **true** | 是否也回收有少量"过时"引用的 Humongous 对象 |

### 4.3 Eager Reclaim 两阶段流程

Eager Reclaim 在 Young GC 中分两步执行：

```
Young GC 流程
│
├── Pre Evacuate Collection Set (GC 前)
│   └── register_humongous_regions_with_cset()   ← 阶段 1: 注册候选
│        ├── 遍历所有 StartsHumongous Region
│        ├── 判断是否是回收候选
│        └── 标记候选 + 注册到 _in_cset_fast_test
│
├── Evacuate Collection Set (对象疏散)
│   └── ... 正常疏散 ...
│
└── Post Evacuate Collection Set (GC 后)
    └── eagerly_reclaim_humongous_regions()      ← 阶段 2: 实际回收
         ├── 遍历所有 StartsHumongous Region
         ├── 检查候选标记 + RemSet 是否为空
         └── 回收死亡的 Humongous Region
```

### 4.4 阶段 1: register_humongous_regions_with_cset

#### 4.4.1 候选判断逻辑

```cpp
// g1CollectedHeap.cpp:3301 RegisterHumongousWithInCSetFastTestClosure
bool humongous_region_is_candidate(G1CollectedHeap* g1h, HeapRegion* region) const {
    assert(region->is_starts_humongous(), "Must start a humongous object");

    oop obj = oop(region->bottom());

    // ① 已死对象不是候选（class unloading 后查询 klass 不安全）
    if (g1h->is_obj_dead(obj, region)) {
        return false;
    }

    // ② RemSet 不完整不是候选（无法确认所有引用都已发现）
    if (!region->rem_set()->is_complete()) {
        return false;
    }

    // ③ 核心条件：只回收 typeArray 对象
    //    原因：typeArray 没有引用其他对象，不会在 RemSet 中产生跨 Region 引用
    //    而且 typeArray 的元数据是内建的（byte[], int[] 等的 Klass 不会被卸载）
    return obj->is_typeArray() &&
           g1h->is_potential_eager_reclaim_candidate(region);
}
```

**为什么只回收 typeArray？**

这是源码中最精妙的设计之一，有三层原因：

1. **RemSet 清理成本**：包含引用的对象（Object[]）会在其他 Region 的 RemSet 中留下条目。要回收这种 Humongous 对象，必须清理所有指向它的 RemSet 条目——成本太高。
2. **SATB 并发标记安全**：typeArray 不包含引用，不需要扫描其引用关系。即使在并发标记过程中回收 typeArray，也不会破坏 SATB 不变性。
3. **元数据安全**：typeArray 的 Klass（如 `[B`、`[I`）是 JVM 内建的，不会被类卸载。而 Object[] 的 Klass 理论上可能被卸载，回收后访问其元数据不安全。

#### 4.4.2 is_potential_eager_reclaim_candidate

```cpp
// g1CollectedHeap.cpp:3281
bool G1CollectedHeap::is_potential_eager_reclaim_candidate(HeapRegion* r) const {
    HeapRegionRemSet* rem_set = r->rem_set();

    return G1EagerReclaimHumongousObjectsWithStaleRefs ?
           rem_set->occupancy_less_or_equal_than(G1RSetSparseRegionEntries) :
           G1EagerReclaimHumongousObjects && rem_set->is_empty();
}
```

**两种模式**：
- `WithStaleRefs=true`（默认）：RemSet 条目数 ≤ `G1RSetSparseRegionEntries` 即可（允许有少量"过时"引用）
- `WithStaleRefs=false`：RemSet 必须完全为空

"过时引用"的场景：一个 Old Region 曾经引用过这个 Humongous 对象，但引用已经被覆盖或删除。由于 Refinement 可能还没来得及清理 RemSet，所以 RemSet 中还有残留条目。`WithStaleRefs=true` 允许忽略这些少量残留。

#### 4.4.3 候选注册

```cpp
virtual bool do_heap_region(HeapRegion* r) {
    if (!r->is_starts_humongous()) return false;

    bool is_candidate = humongous_region_is_candidate(g1h, r);

    // ① 标记到 _humongous_reclaim_candidates 数组
    g1h->set_humongous_reclaim_candidate(rindex, is_candidate);

    if (is_candidate) {
        _candidate_humongous++;

        // ② 注册到 _in_cset_fast_test（标记为 Humongous）
        g1h->register_humongous_region_with_cset(rindex);
        // → _in_cset_fast_test.set_humongous(index);

        // ③ 如果 RemSet 非空，将残留条目 flush 到 DCQS
        if (!r->rem_set()->is_empty()) {
            // 遍历 RemSet 条目，标记脏卡
            HeapRegionRemSetIterator hrrs(r->rem_set());
            size_t card_index;
            while (hrrs.has_next(card_index)) {
                jbyte* card_ptr = ct->byte_for_index(card_index);
                *card_ptr = G1CardTable::dirty_card_val();
                _dcq.enqueue(card_ptr);
            }
            // 清空 RemSet，但设为 Complete 状态
            r->rem_set()->clear_locked(true /* only_cardset */);
            r->rem_set()->set_state_complete();
        }
    }
    _total_humongous++;
    return false;
}
```

**为什么要 flush RemSet 到 DCQS？**

因为候选对象的 RemSet 条目可能是"过时"的，但也**可能是有效的**。为了安全，把这些条目重新放入 DCQS（Dirty Card Queue Set），在疏散阶段会重新处理这些卡片。如果疏散阶段发现确实没有活引用指向这个 Humongous 对象，那它就是真正死亡的。

#### 4.4.4 HumongousReclaimCandidates 数据结构

```cpp
// g1CollectedHeap.hpp:253
class HumongousReclaimCandidates : public G1BiasedMappedArray<bool> {
protected:
    bool default_value() const { return false; }
public:
    void set_candidate(uint region, bool value) {
        set_by_index(region, value);    // 按 Region 索引设置
    }
    bool is_candidate(uint region) {
        return get_by_index(region);    // 按 Region 索引查询
    }
};
```

这是一个**按 Region 索引的 bool 数组**，继承自 `G1BiasedMappedArray`（偏移映射数组）。每个 Region 只需 1 byte。

### 4.5 阶段 2: eagerly_reclaim_humongous_regions

```cpp
// g1CollectedHeap.cpp:5362
void G1CollectedHeap::eagerly_reclaim_humongous_regions() {
    assert_at_safepoint_on_vm_thread();

    // ① 前置检查
    if (!G1EagerReclaimHumongousObjects ||
        (!_has_humongous_reclaim_candidates && !log_is_enabled(Debug, gc, humongous))) {
        g1_policy()->phase_times()->record_fast_reclaim_humongous_time_ms(0.0, 0);
        return;
    }

    double start_time = os::elapsedTime();
    FreeRegionList local_cleanup_list("Local Humongous Cleanup List");

    // ② 遍历所有 Region，找到可回收的 Humongous Region
    G1FreeHumongousRegionClosure cl(&local_cleanup_list);
    heap_region_iterate(&cl);

    // ③ 从 _humongous_set 中移除
    remove_from_old_sets(0, cl.humongous_regions_reclaimed());

    // ④ 放回 free list
    prepend_to_freelist(&local_cleanup_list);

    // ⑤ 更新统计
    decrement_summary_bytes(cl.bytes_freed());
    g1_policy()->phase_times()->record_fast_reclaim_humongous_time_ms(
        (os::elapsedTime() - start_time) * 1000.0,
        cl.humongous_objects_reclaimed());
}
```

#### 4.5.1 G1FreeHumongousRegionClosure — 核心回收闭包

```cpp
// g1CollectedHeap.cpp:5244
class G1FreeHumongousRegionClosure : public HeapRegionClosure {
    virtual bool do_heap_region(HeapRegion* r) {
        if (!r->is_starts_humongous()) return false;

        oop obj = (oop) r->bottom();
        uint region_idx = r->hrm_index();

        // ① 最终存活性判断：是否是候选 + RemSet 是否为空
        if (!g1h->is_humongous_reclaim_candidate(region_idx) ||
            !r->rem_set()->is_empty()) {
            // 存活！输出日志
            log_debug(gc, humongous)(
                "Live humongous region %u object size %lu ...",
                region_idx, obj->size() * HeapWordSize, ...);
            return false;
        }

        // ② 确认是 typeArray（安全检查）
        guarantee(obj->is_typeArray(), "Only typeArray...");

        // ③ 日志输出
        log_debug(gc, humongous)(
            "Dead humongous region %u object size %lu ...",
            region_idx, obj->size() * HeapWordSize, ...);

        // ④ 通知并发标记
        cm->humongous_object_eagerly_reclaimed(r);

        // ⑤ 逐个释放 Region
        _humongous_objects_reclaimed++;
        do {
            HeapRegion* next = g1h->next_region_in_humongous(r);
            _freed_bytes += r->used();
            r->set_containing_set(NULL);
            _humongous_regions_reclaimed++;
            g1h->free_humongous_region(r, _free_region_list);
            r = next;
        } while (r != NULL);

        return false;
    }
};
```

**为什么最终还要检查 RemSet？**

因为在阶段 1（注册候选）到阶段 2（实际回收）之间，经历了整个疏散阶段。疏散过程中，其他对象可能被复制到新 Region，如果复制后的对象引用了这个 Humongous 对象，会在 RemSet 中增加新条目。如果 RemSet 不为空，说明还有活对象引用它，不能回收。

#### 4.5.2 free_humongous_region — 单个 Region 释放

```cpp
// g1CollectedHeap.cpp:4930
void G1CollectedHeap::free_humongous_region(HeapRegion* hr, FreeRegionList* free_list) {
    assert(hr->is_humongous(), "this is only for humongous regions");

    hr->clear_humongous();    // 清除 Humongous 标记 + _humongous_start_region = NULL
    free_region(hr, free_list, false, false, true);  // 清空 Region 并加入 free list
}
```

#### 4.5.3 next_region_in_humongous — 遍历连续 Region

```cpp
// heapRegionManager.inline.hpp:50
inline HeapRegion* HeapRegionManager::next_region_in_humongous(HeapRegion* hr) const {
    uint index = hr->hrm_index();
    index++;
    if (index < max_length() && is_available(index) && at(index)->is_continues_humongous()) {
        return at(index);    // 下一个是 ContinuesHumongous → 返回
    } else {
        return NULL;         // 不是 → 到达 Humongous 序列末尾
    }
}
```

### 4.6 GC 日志验证 — Eager Reclaim 全过程

```
【GC 日志验证】-Xlog:gc+humongous=debug,gc=info,gc+phases=debug
测试程序：分配 3MB + 6MB byte[]，释放引用后触发 Young GC

┌────────────────────────────────────────────────────────────────────┐
│ [gc,humongous] GC(0) Dead humongous region 0                       │
│   object size 3145744 (3MB)                                        │
│   start 0x0000000600000000                                         │
│   remset 0   code roots 0                                          │
│   is marked 0   reclaim candidate 1   type array 1                 │
│                                                                    │
│ [gc,humongous] GC(0) Dead humongous region 1                       │
│   object size 6291472 (6MB)                                        │
│   start 0x0000000600400000                                         │
│   remset 0   code roots 0                                          │
│   is marked 0   reclaim candidate 1   type array 1                 │
│                                                                    │
│ [gc,phases] GC(0) Humongous Register: 0.2ms                       │
│ [gc,phases] GC(0) Humongous Reclaim: 4.3ms                        │
│                                                                    │
│ [gc] GC(0) Pause Young (Normal) 419M→0M(8192M) 152.606ms         │
│                                                                    │
│ 结果：2 个 Humongous 对象（占 3 个 Region）成功被 Eager Reclaim     │
│       回收条件：is_typeArray=true + remset=0 + reclaim_candidate=1  │
└────────────────────────────────────────────────────────────────────┘
```

**日志关键字段解读**：
- `Dead humongous region 0`：Region #0 的 Humongous 对象被判定为死亡
- `reclaim candidate 1`：阶段 1 标记为候选
- `type array 1`：是 typeArray（byte[]），满足回收条件
- `remset 0`：RemSet 为空，确认无活引用
- `is marked 0`：未被标记（分配在并发标记开始之后，或标记尚未开始）

### 4.7 Eager Reclaim 完整时序图

```
时间    VMThread                     GangWorker(疏散)        Humongous Region#0 (3MB byte[])
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
T0     Young GC 开始
       │
T1     ──── 阶段 1: register_humongous_regions_with_cset() ─────
       │  遍历所有 StartsHumongous
       │  Region#0: is_typeArray? → true ✓
       │            rem_set()->is_complete()? → true ✓        remset: 0 条目
       │            is_potential_eager_reclaim? → true ✓       occupancy ≤ sparse threshold
       │  标记为候选: _humongous_reclaim_candidates[0] = true
       │  注册: _in_cset_fast_test.set_humongous(0)
       │
T2     ──── Evacuate Collection Set ────
       │                                  扫描 Eden Region
       │                                  复制存活对象到 Survivor
       │                                  没有对象引用 Region#0
       │                                                       remset: 仍然 0
       │
T3     ──── 阶段 2: eagerly_reclaim_humongous_regions() ────
       │  遍历所有 StartsHumongous
       │  Region#0: is_candidate(0)? → true ✓
       │            rem_set()->is_empty()? → true ✓            确认死亡!
       │  
       │  回收: clear_humongous() → free_region()
       │  Region#0 加入 free list                              Region#0: Free ✓
       │  update_sizes: freed 4MB
       │
T4     Young GC 结束
       日志: "Dead humongous region 0 ... reclaim candidate 1 type array 1"
```

---

## 5. Humongous 对象的特殊属性

### 5.1 Humongous 是 Pinned（固定的）

```cpp
StartsHumongousTag    = HumongousMask | PinnedMask = 4 | 8 = 12
ContinuesHumongousTag = HumongousMask | PinnedMask + 1    = 13
```

Humongous Region 同时设置了 `PinnedMask`，这意味着：
- **不会被疏散**：Humongous Region 不会出现在 Collection Set 中（CSet 只包含 Young + 选中的 Old）
- **不会被复制**：Humongous 对象太大，复制成本不可接受
- **回收方式**：只能"就地"回收整个 Region 序列

### 5.2 Humongous 不能被 relabel 为 Old

```cpp
// heapRegionType.hpp:162
bool relabel_as_old() {
    assert(!is_humongous(), "Should not try to move Humongous region");
    // ...
}
```

Humongous Region 不能通过 `relabel_as_old()` 改变类型。它的类型从分配到回收一直是 StartsHumongous/ContinuesHumongous。

### 5.3 Humongous 与并发标记

在并发标记期间，Humongous 对象有特殊的处理规则：
1. **typeArray 在标记期间可以被回收**：因为 typeArray 不会被 push 到标记栈，不会破坏 SATB 不变性
2. **包含引用的 Humongous 对象不能被 Eager Reclaim**：它们可能在标记栈上，回收会导致悬垂指针
3. **分配在并发标记开始之后的 Humongous 对象**：自动视为"存活"（所有并发标记期间分配的对象都被视为存活），但 typeArray 是例外——它们即使在标记开始前分配，也可以被回收

---

## 6. Humongous 对象空间浪费分析

### 6.1 内部碎片

一个 Humongous 对象占用 `ceil(obj_size / Region_size)` 个 Region，但最后一个 Region 通常有空闲空间。

```
对象大小    占用 Region 数    实际占用      浪费         浪费率
─────────────────────────────────────────────────────────
2.1 MB     1               4 MB         1.9 MB       47.5%
3.0 MB     1               4 MB         1.0 MB       25.0%
4.1 MB     2               8 MB         3.9 MB       48.7%
6.0 MB     2               8 MB         2.0 MB       25.0%
8.1 MB     3               12 MB        3.9 MB       32.5%
```

**最坏情况**：刚好超过 N 个 Region 的大小一点点，浪费接近 50%。

### 6.2 对外部碎片的影响

Humongous 分配需要**连续的空闲 Region**。如果 free list 中的空闲 Region 不连续（被其他 Old Region 隔开），即使总空闲空间足够，也可能找不到连续序列，导致：
1. 触发堆扩展（expand）
2. 触发 GC
3. 最终 OOM

这就是所谓的**外部碎片化**问题。

---

## 7. 日志参数速查

| 参数 | 示例输出 |
|------|---------|
| `-Xlog:gc+humongous=debug` | `Dead humongous region 0 object size 3145744 ...` |
| `-Xlog:gc+humongous=trace` | 更详细的 Humongous 分配/回收追踪 |
| `-Xlog:gc+phases=debug` | `Humongous Register: 0.2ms` / `Humongous Reclaim: 4.3ms` |
| `-Xlog:gc+ergo+heap=debug` | `Attempt heap expansion (humongous allocation request failed)` |

```bash
# 完整 Humongous 观测命令
java -Xms8g -Xmx8g -XX:+UseG1GC \
     -Xlog:gc+humongous=debug,gc+phases=debug,gc+ergo+heap=debug \
     -cp app.jar Main
```

---

## 8. GDB 验证脚本

### 8.1 Humongous 分配验证

```gdb
# 文件: jvm-md/tmp-file/humongous/gdb_humongous_alloc.txt

set pagination off
set print pretty on

b G1CollectedHeap::humongous_obj_allocate(size_t)
b G1CollectedHeap::humongous_obj_allocate_initialize_regions(unsigned int, unsigned int, size_t)

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.HumongousTest

# 每次命中打印关键数据
printf "word_size: %lu words = %lu bytes\n", word_size, word_size*8
printf "threshold: %lu words = %lu bytes\n", G1CollectedHeap::_humongous_object_threshold_in_words, G1CollectedHeap::_humongous_object_threshold_in_words*8
c

printf "first: %u  num_regions: %u  word_size: %lu\n", first, num_regions, word_size
c

quit
```

### 8.2 Eager Reclaim 验证

```bash
# 通过 GC 日志直接验证 Eager Reclaim
java -Xms8g -Xmx8g -XX:+UseG1GC -Xint \
     -Xlog:gc+humongous=debug,gc+phases=debug \
     -cp /data/workspace/demo/src com.wjcoder.HumongousTest

# 预期输出：
# Dead humongous region 0 object size 3145744 ... reclaim candidate 1 type array 1
# Dead humongous region 1 object size 6291472 ... reclaim candidate 1 type array 1
# Humongous Register: X.Xms
# Humongous Reclaim: X.Xms
```

---

## 9. 面试 Q&A

### Q1: G1 中什么是 Humongous 对象？阈值是多少？

**回答要点**：

Humongous 对象是指大小**超过 Region 大小一半**的对象。在 4MB Region 下，阈值是 2MB。

源码中的判断逻辑是 `word_size > _humongous_object_threshold_in_words`，阈值通过 `humongous_threshold_for(region_size) = region_size / 2` 计算。

Humongous 对象不走正常的 TLAB/Eden 分配路径，而是直接在 Old 代分配连续的 Region 序列。第一个 Region 标记为 StartsHumongous（tag=12），后续的标记为 ContinuesHumongous（tag=13）。

### Q2: Humongous 对象分配时找不到连续的空闲 Region 怎么办？

**回答要点**：

`humongous_obj_allocate()` 采用**三级递退策略**：

1. **单 Region 快速路径**（obj_regions==1）：直接从 free list 取一个 Region
2. **找连续已提交 Region**：`find_contiguous_only_empty(N)`，不扩堆
3. **找连续空闲/未提交 Region + 扩堆**：`find_contiguous_empty_or_unavailable(N)` + `expand_at()`

如果三种策略都失败，上层 `attempt_allocation_humongous()` 会触发 GC（原因 `_g1_humongous_allocation`），GC 后重试。如果 GC 后仍然失败，返回 NULL → OOM。

### Q3: 什么是 Eager Reclaim？为什么只回收 typeArray？

**回答要点**：

Eager Reclaim 是 G1 在每次 Young GC 时顺便检查 Humongous 对象是否死亡并立即回收的机制。默认开启（`G1EagerReclaimHumongousObjects=true`）。

只回收 typeArray（如 byte[]、int[]）有三个原因：
1. **RemSet 清理成本**：Object[] 会在其他 Region 的 RemSet 中留下条目，回收需要清理这些条目，成本高
2. **SATB 安全**：typeArray 不包含引用，不会被 push 到并发标记栈，回收不破坏 SATB 不变性
3. **元数据安全**：typeArray 的 Klass（`[B`, `[I`）是内建的，不会被类卸载

GDB 日志验证：`type array 1` 表示是 typeArray，`reclaim candidate 1` 表示被标记为候选。

### Q4: Eager Reclaim 的两阶段分别做什么？

**回答要点**：

**阶段 1**（`register_humongous_regions_with_cset`，Pre Evacuate 阶段）：
- 遍历所有 StartsHumongous Region
- 检查：是否 typeArray + RemSet 完整 + RemSet 条目少
- 如果是候选：标记到 `_humongous_reclaim_candidates` 数组 + 注册到 `_in_cset_fast_test`
- 如果 RemSet 有少量条目，flush 到 DCQS（让疏散阶段重新验证）

**阶段 2**（`eagerly_reclaim_humongous_regions`，Post Evacuate 阶段）：
- 遍历所有 StartsHumongous Region
- 检查：`is_candidate(region_idx)` + `rem_set()->is_empty()`
- 如果 RemSet 为空（疏散后仍无活引用）→ 确认死亡 → 释放 Region

两阶段之间经历了疏散（Evacuate），疏散过程中如果有对象被复制到引用了 Humongous 对象的位置，会更新 RemSet，阶段 2 就会发现 RemSet 非空而放弃回收。

### Q5: 频繁分配 Humongous 对象会有什么问题？

**回答要点**：

1. **空间浪费**：Humongous 对象占整数个 Region，最坏情况下浪费近 50% 的空间
2. **外部碎片化**：需要连续 Region，如果 free list 不连续可能分配失败
3. **触发额外 GC**：分配失败会触发 `_g1_humongous_allocation` GC，增加停顿
4. **并发标记触发**：Humongous 分配默认会检查是否需要启动并发标记
5. **Young GC 开销**：每次 Young GC 都要执行 Humongous Register + Reclaim 两阶段

**优化建议**：
- 调大 `G1HeapRegionSize` 使对象不超过阈值（但 Region 变大会增加 GC 粒度）
- 减少大数组的分配（使用对象池或分块处理）
- 观察 `-Xlog:gc+humongous=debug` 日志确认问题程度

### Q6: Humongous 对象为什么是 Pinned 的？

**回答要点**：

`StartsHumongousTag = HumongousMask | PinnedMask = 4 | 8 = 12`

Humongous 对象同时设置了 `PinnedMask`，这意味着它不会被疏散（不会被复制到其他 Region）。原因是 Humongous 对象可能跨多个 Region，复制成本极高。G1 选择"就地管理"——要么让 Humongous 对象一直占着 Region 直到死亡，要么通过 Eager Reclaim/Mixed GC 直接释放这些 Region。

---

## 10. 源码索引

| 文件 | 路径 | 关键内容 |
|------|------|---------|
| g1CollectedHeap.cpp:201 | `gc/g1/g1CollectedHeap.cpp` | `humongous_obj_allocate_initialize_regions` — Region 初始化 |
| g1CollectedHeap.cpp:327 | `gc/g1/g1CollectedHeap.cpp` | `humongous_obj_allocate` — 三级 Region 查找策略 |
| g1CollectedHeap.cpp:870 | `gc/g1/g1CollectedHeap.cpp` | `attempt_allocation_humongous` — 慢路径分配循环 |
| g1CollectedHeap.cpp:3281 | `gc/g1/g1CollectedHeap.cpp` | `is_potential_eager_reclaim_candidate` — 回收候选判断 |
| g1CollectedHeap.cpp:3295 | `gc/g1/g1CollectedHeap.cpp` | `RegisterHumongousWithInCSetFastTestClosure` — 阶段 1 注册 |
| g1CollectedHeap.cpp:5244 | `gc/g1/g1CollectedHeap.cpp` | `G1FreeHumongousRegionClosure` — 阶段 2 回收闭包 |
| g1CollectedHeap.cpp:5362 | `gc/g1/g1CollectedHeap.cpp` | `eagerly_reclaim_humongous_regions` — 阶段 2 入口 |
| g1CollectedHeap.cpp:4930 | `gc/g1/g1CollectedHeap.cpp` | `free_humongous_region` — 单 Region 释放 |
| g1CollectedHeap.hpp:253 | `gc/g1/g1CollectedHeap.hpp` | `HumongousReclaimCandidates` 类定义 |
| g1CollectedHeap.hpp:1248 | `gc/g1/g1CollectedHeap.hpp` | `is_humongous()` 和 `humongous_threshold_for()` |
| heapRegion.cpp:197 | `gc/g1/heapRegion.cpp` | `set_starts_humongous` / `set_continues_humongous` |
| heapRegionType.hpp:71 | `gc/g1/heapRegionType.hpp` | HeapRegionType 枚举定义 |
| heapRegionManager.inline.hpp:50 | `gc/g1/heapRegionManager.inline.hpp` | `next_region_in_humongous` |
| g1_globals.hpp:253 | `gc/g1/g1_globals.hpp` | `G1EagerReclaimHumongousObjects` 参数 |

---

*最后更新: 2026-02-09*
*GDB 验证环境: OpenJDK 11, -Xms8g -Xmx8g -XX:+UseG1GC, 16 核*
