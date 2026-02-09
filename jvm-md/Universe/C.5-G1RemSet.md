# C.5 G1RemSet - 记忆集管理器

> G1RemSet 是 G1 GC 中管理跨 Region 引用的核心组件，协调 RSet 扫描和卡表清理

---

## 1. 记忆集的核心问题

### 1.1 为什么需要记忆集？

```
┌─────────────────────────────────────────────────────────────────────┐
│                    跨 Region 引用问题                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  场景：GC 要回收 Region B，但 Region A 中的对象引用了 B 中的对象   │
│                                                                      │
│    Region A (不回收)              Region B (要回收)                 │
│   ┌─────────────────┐           ┌─────────────────┐                │
│   │   ┌─────┐       │           │   ┌─────┐       │                │
│   │   │ Obj │───────┼───────────┼──▶│ Obj │       │                │
│   │   │  A  │       │           │   │  B  │       │                │
│   │   └─────┘       │           │   └─────┘       │                │
│   └─────────────────┘           └─────────────────┘                │
│                                                                      │
│  问题：如何知道 Obj B 还被引用着？                                  │
│                                                                      │
│  方案 1：全堆扫描 → 太慢！                                          │
│  方案 2：记忆集 → 每个 Region 记录"谁引用了我"                     │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.2 卡表 vs 记忆集

| 特性 | CardTable | RSet (HeapRegionRemSet) |
|------|-----------|-------------------------|
| **记录什么** | "哪里被修改了" | "谁引用了我" |
| **粒度** | 512B（一张卡） | 卡级别 |
| **数量** | 整个堆共享一个 | 每个 Region 一个 |
| **更新时机** | 写屏障立即更新 | 精炼线程异步更新 |
| **更新开销** | 极低（一条指令） | 较高（分析引用） |

### 1.3 从脏卡到 RSet 的转换

```
┌─────────────────────────────────────────────────────────────────────┐
│                    精炼（Refinement）过程                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  写屏障:                                                            │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ obj.field = new_ref;                                          │   │
│  │ CardTable[card_index] = dirty;  // 立即标记                   │   │
│  │ DirtyCardQueue.enqueue(card);   // 入队                       │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                              ↓                                       │
│  精炼线程:                                                          │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ card_ptr = DirtyCardQueue.dequeue();                          │   │
│  │ for (oop obj : objects_in_card(card_ptr)) {                   │   │
│  │   for (oop* ref : reference_fields(obj)) {                    │   │
│  │     oop target = *ref;                                        │   │
│  │     if (target != NULL && is_cross_region(obj, target)) {     │   │
│  │       target_region->rem_set()->add_reference(ref);  // 更新! │   │
│  │     }                                                         │   │
│  │   }                                                           │   │
│  │ }                                                              │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. G1RemSet 类结构

### 2.1 类定义

```cpp
// g1RemSet.hpp:69-149

class G1RemSet : public CHeapObj<mtGC> {
private:
  // 核心：GC 期间的扫描状态管理
  G1RemSetScanState* _scan_state;
  
  // 统计信息
  G1RemSetSummary _prev_period_summary;
  
  // 堆引用
  G1CollectedHeap* _g1h;
  
  // 并发精炼的卡数量
  size_t _num_conc_refined_cards;
  
  // 组件引用
  G1CardTable*     _ct;           // 卡表
  G1Policy*        _g1p;          // GC 策略
  G1HotCardCache*  _hot_card_cache; // 热卡缓存

public:
  // 计算并发线程数量
  static uint num_par_rem_sets();
  
  // 初始化
  void initialize(size_t capacity, uint max_regions);
  
  // 并发精炼一张卡
  void refine_card_concurrently(jbyte* card_ptr, uint worker_i);
  
  // GC 期间精炼一张卡
  bool refine_card_during_gc(jbyte* card_ptr, ...);
  
  // GC 期间处理 Collection Set 的入边引用
  void oops_into_collection_set_do(G1ParScanThreadState* pss, uint worker_i);
};
```

### 2.2 内存布局

```
G1RemSet 对象:
┌────────────────────────────────────────────────────────────────────┐
│ _scan_state             │ → G1RemSetScanState*                     │ 8B
│ _prev_period_summary    │ G1RemSetSummary 内嵌对象                 │ ~100B
│ _g1h                    │ → G1CollectedHeap*                       │ 8B
│ _num_conc_refined_cards │ 统计：并发精炼的卡数量                    │ 8B
│ _ct                     │ → G1CardTable*                           │ 8B
│ _g1p                    │ → G1Policy*                              │ 8B
│ _hot_card_cache         │ → G1HotCardCache*                        │ 8B
└────────────────────────────────────────────────────────────────────┘
```

---

## 3. G1RemSetScanState - 扫描状态管理

### 3.1 核心问题

GC 暂停期间，多个 GC 线程需要并行扫描所有 Region 的 RSet：

```
问题：
1. 如何避免重复扫描同一个 Region？
2. 如何协调多线程扫描同一个 Region 的大 RSet？
3. GC 后如何清理卡表？
4. 如何确定扫描边界？
```

### 3.2 五个核心数组

```cpp
// g1RemSet.cpp:55-181

class G1RemSetScanState : public CHeapObj<mtGC> {
  size_t _max_regions;  // 最大 Region 数量
  
  // 数组 1: Region 扫描状态
  G1RemsetIterState volatile* _iter_states;
  // 每个 Region: Unclaimed(0) → Claimed(1) → Complete(2)
  
  // 数组 2: 卡片扫描进度
  size_t volatile* _iter_claims;
  // 记录每个 Region 的 RSet 扫描到第几张卡
  
  // 数组 3: 脏区域缓冲区
  uint* _dirty_region_buffer;
  // 存储需要清理卡表的 Region ID
  
  // 数组 4: 脏区域标记
  IsDirtyRegionState* _in_dirty_region_buffer;
  // 快速判断 Region 是否已在列表中
  
  // 数组 5: 扫描顶部指针
  HeapWord** _scan_top;
  // GC 开始时每个 Region 的 top 位置
};
```

### 3.3 内存布局（2048 个 Region）

```
G1RemSetScanState 内存分配:
┌─────────────────────────────────────────────────────────────────────┐
│                                                                      │
│  _iter_states (Region 扫描状态)                                     │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ [0]=0 │ [1]=1 │ [2]=2 │ [3]=0 │ ... │ [2047]=0              │    │
│  │ Unclaimed │ Claimed │ Complete │ Unclaimed │ ...             │    │
│  └─────────────────────────────────────────────────────────────┘    │
│  大小: 2048 × sizeof(jint) = 8KB                                    │
│                                                                      │
│  _iter_claims (卡片扫描进度)                                        │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ [0]=0 │ [1]=256 │ [2]=512 │ ... │ [2047]=0                  │    │
│  │ 每个值表示该 Region 的 RSet 扫描到了第几张卡                │    │
│  └─────────────────────────────────────────────────────────────┘    │
│  大小: 2048 × sizeof(size_t) = 16KB                                 │
│                                                                      │
│  _dirty_region_buffer (脏区域列表)                                  │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ [0]=5 │ [1]=17 │ [2]=42 │ [3]=100 │ ? │ ? │ ...            │    │
│  │                          ↑ _cur_dirty_region = 4            │    │
│  └─────────────────────────────────────────────────────────────┘    │
│  大小: 2048 × sizeof(uint) = 8KB                                    │
│                                                                      │
│  _in_dirty_region_buffer (脏区域标记)                               │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ [0]=0 │...│ [5]=1 │...│ [17]=1 │...│ [42]=1 │...│ [100]=1 ││    │
│  │ 只有 Region 5, 17, 42, 100 被标记为 Dirty                   │    │
│  └─────────────────────────────────────────────────────────────┘    │
│  大小: 2048 × sizeof(jbyte) = 2KB                                   │
│                                                                      │
│  _scan_top (扫描顶部)                                               │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ [0]=bottom │ [1]=top │ [2]=bottom │ ... │ [2047]=top        │    │
│  │ CSet Region 存 bottom，Old/Humongous 存 top                 │    │
│  └─────────────────────────────────────────────────────────────┘    │
│  大小: 2048 × sizeof(HeapWord*) = 16KB                              │
│                                                                      │
│  总计: 8 + 16 + 8 + 2 + 16 = 50KB                                   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 3.4 多线程协调流程

```
┌─────────────────────────────────────────────────────────────────────┐
│              多线程扫描 RSet 的协调机制                             │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  假设要扫描 Region #42 的 RSet，有 8 个 GC 线程:                    │
│                                                                      │
│  Step 1: 领取 Region (claim_iter)                                   │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ Thread 0: CAS(_iter_states[42], Unclaimed→Claimed) = SUCCESS │   │
│  │ Thread 1~7: CAS 失败，跳过这个 Region                        │   │
│  │                                                               │   │
│  │ 结果: 只有 Thread 0 负责"初始化"这个 Region 的扫描           │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  Step 2: 分块领取卡片 (iter_claimed_next)                           │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ 假设 Region #42 的 RSet 有 1000 张卡，块大小 = 64            │   │
│  │                                                               │   │
│  │ Thread 0: Atomic::add(64, &_iter_claims[42]) → 领取 [0,64)   │   │
│  │ Thread 2: Atomic::add(64, &_iter_claims[42]) → 领取 [64,128) │   │
│  │ Thread 5: Atomic::add(64, &_iter_claims[42]) → 领取 [128,192)│   │
│  │ ...                                                           │   │
│  │                                                               │   │
│  │ 多个线程可以协作扫描同一个 Region 的大 RSet                  │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  Step 3: 标记完成 (set_iter_complete)                               │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ 最后一个完成的线程:                                          │   │
│  │ CAS(_iter_states[42], Claimed→Complete) = SUCCESS            │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 4. G1FromCardCache - 卡片去重缓存

### 4.1 作用

避免同一个线程重复处理同一张卡：

```cpp
// g1FromCardCache.hpp:33-91

class G1FromCardCache : public AllStatic {
private:
  // 二维数组: [region_idx][worker_id] = 最近处理的卡片索引
  static uintptr_t** _cache;
  static uint _max_regions;

public:
  // 检查卡片是否在缓存中，如果不在则替换
  static bool contains_or_replace(uint worker_id, uint region_idx, uintptr_t card) {
    uintptr_t card_in_cache = at(worker_id, region_idx);
    if (card_in_cache == card) {
      return true;  // 命中缓存，跳过
    } else {
      set(worker_id, region_idx, card);
      return false;  // 未命中，处理并缓存
    }
  }
};
```

### 4.2 内存布局

```
G1FromCardCache 二维数组:
┌─────────────────────────────────────────────────────────────────────┐
│                                                                      │
│  行: Region 索引 (max_regions = 2048)                               │
│  列: 线程 ID (num_par_rem_sets ≈ 40)                                │
│                                                                      │
│           Thread 0   Thread 1   Thread 2   ...   Thread 39          │
│  Region 0 │ card_0  │ card_1   │ card_2   │ ... │ card_39  │        │
│  Region 1 │ card_0  │ card_1   │ card_2   │ ... │ card_39  │        │
│  ...      │  ...    │  ...     │  ...     │ ... │  ...     │        │
│  Region 2047 │ card_0 │ card_1 │ card_2   │ ... │ card_39  │        │
│                                                                      │
│  大小: 2048 × 40 × 8B ≈ 640KB                                       │
│                                                                      │
│  说明:                                                               │
│  - 每个 [region][thread] 存储该线程最近处理的指向该 Region 的卡     │
│  - 如果新卡与缓存的卡相同，说明刚处理过，跳过                       │
│  - 避免短时间内重复处理同一张卡                                     │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 4.3 线程数计算

```cpp
// g1RemSet.cpp:454-456

uint G1RemSet::num_par_rem_sets() {
  return DirtyCardQueueSet::num_par_ids()      // Mutator 线程数 (~13)
       + G1ConcurrentRefine::max_num_threads() // 精炼线程数 (13)
       + MAX2(ConcGCThreads, ParallelGCThreads); // GC 线程数 (13)
}
// 8GB 堆配置: 约 13 + 13 + 13 = 39 个线程
```

---

## 5. 初始化流程

### 5.1 G1RemSet 构造

```cpp
// g1RemSet.cpp:428-438

G1RemSet::G1RemSet(G1CollectedHeap* g1h,
                   G1CardTable* ct,
                   G1HotCardCache* hot_card_cache) :
  _g1h(g1h),
  _scan_state(new G1RemSetScanState()),  // 创建扫描状态管理器
  _num_conc_refined_cards(0),
  _ct(ct),
  _g1p(_g1h->g1_policy()),
  _hot_card_cache(hot_card_cache),
  _prev_period_summary() {
}
```

### 5.2 G1RemSet::initialize()

```cpp
// g1RemSet.cpp:458-470

void G1RemSet::initialize(size_t capacity, uint max_regions) {
  // Step 1: 初始化卡片去重缓存
  // num_par_rem_sets() ≈ 39, max_regions = 2048
  G1FromCardCache::initialize(num_par_rem_sets(), max_regions);
  
  // Step 2: 初始化扫描状态管理器
  // 分配 5 个数组，总计约 50KB
  _scan_state->initialize(max_regions);
}
```

### 5.3 G1RemSetScanState::initialize()

```cpp
// g1RemSet.cpp:211-220

void G1RemSetScanState::initialize(uint max_regions) {
  _max_regions = max_regions;
  
  // 分配 5 个数组
  _iter_states = NEW_C_HEAP_ARRAY(G1RemsetIterState, max_regions, mtGC);  // 8KB
  _iter_claims = NEW_C_HEAP_ARRAY(size_t, max_regions, mtGC);             // 16KB
  _dirty_region_buffer = NEW_C_HEAP_ARRAY(uint, max_regions, mtGC);       // 8KB
  _in_dirty_region_buffer = NEW_C_HEAP_ARRAY(IsDirtyRegionState, max_regions, mtGC); // 2KB
  _scan_top = NEW_C_HEAP_ARRAY(HeapWord*, max_regions, mtGC);             // 16KB
}
```

---

## 6. 与其他组件的协作

### 6.1 整体架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                    G1RemSet 在 G1 中的位置                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Mutator 写引用                                                      │
│       │                                                              │
│       ↓                                                              │
│  G1BarrierSet (写屏障)                                              │
│       │                                                              │
│       ├─────────────────────────────────────────────┐               │
│       ↓                                             ↓               │
│  G1CardTable (标记脏卡)              DirtyCardQueue (入队卡地址)    │
│       │                                             │               │
│       │                                             ↓               │
│       │                             DirtyCardQueueSet (全局队列)    │
│       │                                             │               │
│       │                             ┌───────────────┴───────────┐   │
│       │                             ↓                           ↓   │
│       │                    G1ConcurrentRefine      G1HotCardCache   │
│       │                    (并发精炼线程)          (热卡缓存)       │
│       │                             │                           │   │
│       │                             └───────────┬───────────────┘   │
│       │                                         ↓                   │
│       │                                  ┌─────────────┐            │
│       │                                  │  G1RemSet   │            │
│       │                                  │             │            │
│       │                                  │ - 协调精炼  │            │
│       │                                  │ - 管理扫描  │            │
│       │                                  │ - 更新 RSet │            │
│       │                                  └──────┬──────┘            │
│       │                                         ↓                   │
│       └─────────────────────────────────────────┴───────────────────┘
│                                         │                           │
│                                         ↓                           │
│                              HeapRegionRemSet (每个 Region 的 RSet) │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 6.2 GC 期间的工作流程

```
┌─────────────────────────────────────────────────────────────────────┐
│                    GC 期间 G1RemSet 的工作                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  1. 准备阶段 (prepare_for_oops_into_collection_set_do)              │
│     ┌───────────────────────────────────────────────────────────┐   │
│     │ - 重置 _scan_state                                         │   │
│     │ - 快照每个 Region 的 top 到 _scan_top                      │   │
│     │ - 禁用热卡缓存                                             │   │
│     └───────────────────────────────────────────────────────────┘   │
│                                                                      │
│  2. 扫描阶段 (oops_into_collection_set_do)                          │
│     ┌───────────────────────────────────────────────────────────┐   │
│     │ 并行执行:                                                  │   │
│     │ - scan_rem_set(): 扫描 CSet 中 Region 的 RSet             │   │
│     │ - update_rem_set(): 处理剩余的脏卡                        │   │
│     │                                                            │   │
│     │ 找到所有指向 CSet 的引用，作为 GC Roots                    │   │
│     └───────────────────────────────────────────────────────────┘   │
│                                                                      │
│  3. 清理阶段 (cleanup_after_oops_into_collection_set_do)            │
│     ┌───────────────────────────────────────────────────────────┐   │
│     │ - 清理扫描过的 Region 的卡表                              │   │
│     │ - 重置热卡缓存                                             │   │
│     │ - 更新统计信息                                             │   │
│     └───────────────────────────────────────────────────────────┘   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 7. 内存开销总结

| 组件 | 大小 | 说明 |
|------|------|------|
| G1RemSet 对象 | ~150B | 对象本身 |
| G1RemSetScanState | ~50KB | 5 个数组 |
| G1FromCardCache | ~640KB | 二维去重缓存 |
| **总计** | **~700KB** | G1RemSet 相关 |

---

## 8. 设计亮点

### 8.1 多级协调机制

```
Region 级别: _iter_states
  → 防止多个线程重复扫描同一个 Region

卡片级别: _iter_claims
  → 允许多个线程协作扫描大 RSet

线程级别: G1FromCardCache
  → 避免同一线程短时间内重复处理同一张卡
```

### 8.2 增量清理卡表

```
传统方式: GC 后全表扫描清理 → 慢！

G1 方式:
- 扫描时记录脏 Region (_dirty_region_buffer)
- GC 后只清理记录的 Region → 快！
```

### 8.3 扫描边界控制

```
_scan_top 的作用:
- 记录 GC 开始时的 top 位置
- 避免扫描 GC 期间新分配的对象
- 支持 SATB 语义（Snapshot-At-The-Beginning）
```

---

## 9. 总结

### 9.1 G1RemSet 核心职责

| 职责 | 说明 |
|------|------|
| **协调精炼** | 与精炼线程、热卡缓存配合更新 RSet |
| **管理扫描** | GC 期间协调多线程并行扫描 RSet |
| **清理卡表** | GC 后增量清理扫描过的 Region |
| **去重优化** | 通过 G1FromCardCache 避免重复处理 |

### 9.2 关键数据结构

| 结构 | 作用 |
|------|------|
| `G1RemSetScanState` | 管理 GC 期间的扫描状态 |
| `G1FromCardCache` | 线程级卡片去重缓存 |
| `HeapRegionRemSet` | 每个 Region 的实际 RSet 数据 |

### 9.3 与卡表的关系

```
CardTable:
  - 粗粒度，写屏障快速标记
  - 记录"哪里被修改"

G1RemSet:
  - 细粒度，精炼线程异步处理
  - 将"修改信息"转化为"引用信息"
  - 每个 Region 知道"谁引用了我"
```
