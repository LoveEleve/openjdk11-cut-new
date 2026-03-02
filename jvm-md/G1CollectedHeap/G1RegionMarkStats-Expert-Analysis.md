# G1RegionMarkStats - Region 标记统计机制

> **文档定位**: Mixed GC 学习路线 - 第2.4篇  
> **专家级分析**: 基于 GDB 运行时验证的精确数据  
> **JVM 参数**: `-Xms8g -Xmx8g -XX:+UseG1GC -Xint`

---

## 一、问题驱动：为什么需要 Region 级统计？

### 1.1 核心问题

在 Mixed GC 中，JVM 需要回答：**"哪些老年代 Region 的垃圾最多，最值得优先回收？"**

这个问题需要：
1. **每个 Region 的存活对象量**：用于计算垃圾占比
2. **细粒度的数据支持**：不能只有堆整体统计，需要 Region 级
3. **并发安全收集**：统计在并发标记中完成，不能影响 mutator

### 1.2 如果没有 Region 统计

```
没有 Region 统计 → 不知道每个 Region 的垃圾占比
         ↓
无法选择最优回收区域 → Mixed GC 效率低下
         ↓
可能回收低垃圾区域 → 浪费 GC 时间，增加停顿
```

### 1.3 Region 统计的核心作用

```
并发标记期间                    Mixed GC 决策阶段
     │                              │
     ▼                              ▼
┌─────────────────┐           ┌─────────────────┐
│ 扫描对象         │           │ 读取 Region 统计 │
│ 统计存活对象量   │──────────▶│ 计算垃圾占比     │
│ 按 Region 聚合   │           │ 选择高垃圾 Region│
└─────────────────┘           └─────────────────┘
         │                              │
         ▼                              ▼
  _region_mark_stats[]           构建 Collection Set
  (每 Region 一个条目)           (高垃圾 Region 优先)
```

---

## 二、数据结构总览

### 2.1 三层架构

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                           Region 标记统计三层架构                              │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ 第一层：全局统计数组 (Global Stats Array)                                ││
│  │ ┌─────────┬─────────┬─────────┬─────────┬─────────┐                     ││
│  │ │ Region0 │ Region1 │ Region2 │   ...   │Region2047│                     ││
│  │ │_live_words│_live_words│_live_words│   ...   │_live_words│              ││
│  │ └─────────┴─────────┴─────────┴─────────┴─────────┘                     ││
│  │ 数组大小: 2048 entries × 8 bytes = 16KB                                 ││
│  │ 地址: 0x7ffff005a500 ~ 0x7ffff005e500                                   ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    ▲                                         │
│                     批量 flush (标记结束/缓存冲突)                           │
│                                    │                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ 第二层：线程本地缓存 (Per-Thread Cache)                                  ││
│  │ ┌─────────────────────────────────────────────────────────────────────┐││
│  │ │ G1RegionMarkStatsCache (每个 G1CMTask 一个)                          │││
│  │ │ ┌─────────────┬─────────────┬─────────────┬─────────────┐           │││
│  │ │ │ CacheEntry0 │ CacheEntry1 │ CacheEntry2 │   ...       │ 共1024个   │││
│  │ │ │ region_idx  │ region_idx  │ region_idx  │             │           │││
│  │ │ │ _live_words │ _live_words │ _live_words │             │           │││
│  │ │ └─────────────┴─────────────┴─────────────┴─────────────┘           │││
│  │ │ 缓存大小: 1024 entries × 16 bytes ≈ 16KB                            │││
│  │ │ 作用: 减少原子操作，批量更新                                         │││
│  │ └─────────────────────────────────────────────────────────────────────┘││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    ▲                                         │
│                      直接写入 (无锁，仅本线程访问)                           │
│                                    │                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ 第三层：标记过程 (Marking Process)                                       ││
│  │ ┌─────────────────────────────────────────────────────────────────────┐││
│  │ │ 当标记一个对象时:                                                    │││
│  │ │   1. 计算对象所属 Region                                              │││
│  │ │   2. 累加到该 Region 的本地缓存                                       │││
│  │ │   3. 缓存冲突时 flush 到全局数组                                      │││
│  │ │                                                                      │││
│  │ │ mark_object(obj):                                                    │││
│  │ │   region_idx = addr_to_region(obj)                                   │││
│  │ │   cache.add_live_words(region_idx, obj.size())                       │││
│  │ └─────────────────────────────────────────────────────────────────────┘││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 三、G1RegionMarkStats 结构

### 3.1 结构定义

```cpp
// src/hotspot/share/gc/g1/g1RegionMarkStatsCache.hpp:39
struct G1RegionMarkStats {
  size_t _live_words;   // 该 Region 中存活对象的总字数

  // 清空统计
  void clear() {
    _live_words = 0;
  }

  // 在标记溢出后清空（原子更新，无需处理）
  void clear_during_overflow() {
    // 无需操作，因为_live_words通过原子操作更新
  }

  bool is_clear() const { return _live_words == 0; }
};
```

### 3.2 GDB 验证

```gdb
# === G1RegionMarkStats 结构验证 ===
p sizeof(G1RegionMarkStats)
$1 = 8    # 8字节（一个size_t）

# === 全局统计数组验证 ===
p $cm->_region_mark_stats
$2 = (G1RegionMarkStats *) 0x7ffff005a500

p $g1h->max_regions()
$3 = 2048    # 8GB堆 / 4MB Region = 2048个Region

# === 统计数组内存占用 ===
# 2048 regions × 8 bytes = 16384 bytes = 16KB
p 2048 * sizeof(G1RegionMarkStats)
$4 = 16384

# === 统计数组地址范围 ===
p $cm->_region_mark_stats           # 起始地址
$5 = (G1RegionMarkStats *) 0x7ffff005a500

p $cm->_region_mark_stats + 2048    # 结束地址
$6 = (G1RegionMarkStats *) 0x7ffff005e500

# 地址范围: 0x7ffff005a500 ~ 0x7ffff005e500 (共0x4000 = 16KB)
```

### 3.3 内存布局

```
全局统计数组内存布局 (16KB)

起始地址: 0x7ffff005a500
├────────────────────────────────────────────────────────────────────────┤
│ Region 0 │ Region 1 │ Region 2 │ ... │ Region 2047                    │
│ 8 bytes  │ 8 bytes  │ 8 bytes  │     │ 8 bytes                        │
│_live_words│_live_words│_live_words│   │_live_words                     │
├────────────────────────────────────────────────────────────────────────┤
0x7ffff005a500                                                    0x7ffff005e500
```

---

## 四、线程本地缓存机制

### 4.1 为什么需要缓存？

**问题**：多个标记线程并发更新同一个全局数组 → 严重的缓存行伪共享

```
无缓存方案（性能差）:
Thread 0 ──CAS──▶ Region0._live_words
Thread 1 ──CAS──▶ Region0._live_words  ← 冲突！
Thread 2 ──CAS──▶ Region0._live_words  ← 冲突！
         ↓
频繁的缓存一致性流量 + 原子操作竞争
```

**缓存方案（性能好）**:
```
有缓存方案:
Thread 0 ──写入──▶ Local Cache[Region0] ──批量flush──▶ Global[Region0]
Thread 1 ──写入──▶ Local Cache[Region0] ──批量flush──▶ Global[Region0]
Thread 2 ──写入──▶ Local Cache[Region0] ──批量flush──▶ Global[Region0]
         ↓
大部分时间无竞争，仅flush时需要原子操作
```

### 4.2 G1RegionMarkStatsCache 结构

```cpp
// src/hotspot/share/gc/g1/g1RegionMarkStatsCache.hpp:62
class G1RegionMarkStatsCache {
private:
  G1RegionMarkStats* _target;              // 指向全局统计数组
  uint _num_stats;                          // Region总数

  // 缓存条目
  struct G1RegionMarkStatsCacheEntry {
    uint _region_idx;                       // Region索引
    G1RegionMarkStats _stats;               // 统计值

    void clear() {
      _region_idx = 0;
      _stats.clear();
    }
  };

  G1RegionMarkStatsCacheEntry* _cache;      // 缓存数组
  uint _num_cache_entries;                  // 缓存条目数 (1024)
  uint _num_cache_entries_mask;             // 用于哈希: size-1

  size_t _cache_hits;                       // 缓存命中计数
  size_t _cache_misses;                     // 缓存未命中计数

public:
  static const uint RegionMarkStatsCacheSize = 1024;  // 默认缓存大小
};
```

### 4.3 GDB 验证

```gdb
# === G1RegionMarkStatsCache 大小验证 ===
p sizeof(G1RegionMarkStatsCache)
$6 = 56    # 56字节

# === 缓存大小常量验证 ===
p G1CMTask::RegionMarkStatsCacheSize
$7 = 1024  # 每个task的缓存有1024个条目

# === G1CMTask中缓存位置 ===
set $task0 = $cm->task(0)
p $task0
$8 = (G1CMTask *) 0x7ffff0066b40

p &$task0->_mark_stats_cache
$9 = (G1RegionMarkStatsCache *) 0x7ffff0066b78
```

### 4.4 缓存操作机制

```cpp
// 1. 添加存活对象数（快速路径，无锁）
void add_live_words(uint region_idx, size_t live_words) {
  G1RegionMarkStatsCacheEntry* const cur = find_for_add(region_idx);
  cur->_stats._live_words += live_words;  // 纯本地操作，无竞争
}

// 2. 查找缓存条目（哈希定位）
inline G1RegionMarkStatsCacheEntry* find_for_add(uint region_idx) {
  uint const cache_idx = hash(region_idx);  // idx & mask

  G1RegionMarkStatsCacheEntry* cur = &_cache[cache_idx];
  if (cur->_region_idx != region_idx) {
    // 缓存未命中：evict旧条目，插入新条目
    evict(cache_idx);
    cur->_region_idx = region_idx;
    _cache_misses++;
  } else {
    _cache_hits++;
  }
  return cur;
}

// 3. Evict 操作（批量 flush 到全局数组）
inline void evict(uint idx) {
  G1RegionMarkStatsCacheEntry* cur = &_cache[idx];
  if (cur->_stats._live_words != 0) {
    // 原子累加到全局数组
    Atomic::add(cur->_stats._live_words, 
                &_target[cur->_region_idx]._live_words);
  }
  cur->clear();
}
```

### 4.5 缓存工作流程图

```
标记对象 obj:
         │
         ▼
┌─────────────────┐
│ 计算 Region 索引 │
│ region_idx =    │
│ addr_to_region  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 哈希定位缓存条目 │
│ cache_idx =     │
│ region_idx &    │
│ mask            │
└────────┬────────┘
         │
         ▼
┌─────────────────────────────────────┐
│ 检查 cache[cache_idx].region_idx   │
│ 是否等于 region_idx                 │
└──────────────────┬──────────────────┘
         │
    ┌────┴────┐
    │         │
    ▼         ▼
┌────────┐  ┌────────────┐
│ 命中   │  │ 未命中      │
│        │  │            │
│ hits++ │  │ evict()    │
│        │  │ misses++   │
└───┬────┘  │ 装载新条目 │
    │       └─────┬──────┘
    │             │
    └──────┬──────┘
           ▼
┌─────────────────┐
│ 累加对象大小     │
│ _live_words +=  │
│ obj.size()      │
└─────────────────┘
```

---

## 五、统计数据流转

### 5.1 完整流转路径

```
阶段1: 对象标记
────────────────────────────────────────────────────────
G1CMTask::make_reference_grey(obj)
    │
    ▼
_next_mark_bitmap->par_mark(obj)  ← 先标记位图
    │
    ▼ (标记成功)
G1ConcurrentMark::add_to_liveness(worker_id, obj, size)
    │
    ▼
G1CMTask::update_liveness(obj, size)
    │
    ▼
_mark_stats_cache.add_live_words(region_idx, size)
    │
    ▼
缓存命中: 直接累加到本地缓存
缓存未命中: evict旧条目到全局数组，再写入新条目


阶段2: 标记结束 flush
────────────────────────────────────────────────────────
G1ConcurrentMark::flush_all_task_caches()
    │
    ▼
遍历所有 task:
  _tasks[i]->flush_mark_stats_cache()
      │
      ▼
  _mark_stats_cache.evict_all()
      │
      ▼
  遍历缓存所有条目，evict到全局数组
      │
      ▼
  返回 hits/misses 统计


阶段3: Mixed GC 决策
────────────────────────────────────────────────────────
G1CollectionSetChooser::select_candidates()
    │
    ▼
遍历候选 Region:
  live_words = _cm->liveness(region_idx)
      │
      ▼
  返回 _region_mark_stats[region_idx]._live_words
      │
      ▼
  garbage_bytes = region_capacity - (live_words * HeapWordSize)
      │
      ▼
  按垃圾占比排序，选择回收Region
```

### 5.2 关键代码路径

```cpp
// 1. 标记时更新统计 (g1ConcurrentMark.inline.hpp:79)
inline bool G1CMTask::mark_in_next_bitmap(uint worker_id, oop obj, ...) {
  bool success = _next_mark_bitmap->par_mark(obj_addr);
  if (success) {
    add_to_liveness(worker_id, obj, obj_size);
  }
  return success;
}

// 2. 更新存活对象数 (g1ConcurrentMark.inline.hpp:205)
inline void G1CMTask::update_liveness(oop const obj, const size_t obj_size) {
  _mark_stats_cache.add_live_words(
    _g1h->addr_to_region((HeapWord*)obj), 
    obj_size
  );
}

// 3. 批量 flush (g1ConcurrentMark.cpp:1981)
void G1ConcurrentMark::flush_all_task_caches() {
  size_t hits = 0, misses = 0;
  for (uint i = 0; i < _max_num_tasks; i++) {
    Pair<size_t, size_t> stats = _tasks[i]->flush_mark_stats_cache();
    hits += stats.first;
    misses += stats.second;
  }
  // 记录日志
  log_debug(gc, stats)("Mark stats cache hits %zu misses %zu ratio %1.3lf",
                       hits, misses, (double)hits / (hits + misses));
}

// 4. 查询 Region 存活量 (g1ConcurrentMark.hpp:490)
size_t liveness(uint region) const { 
  return _region_mark_stats[region]._live_words; 
}
```

---

## 六、内存占用分析

### 6.1 空间开销计算

**8GB 堆，4MB Region，8 个标记线程**:

| 组件 | 计算 | 大小 |
|------|------|------|
| 全局统计数组 | 2048 regions × 8 bytes | 16 KB |
| _top_at_rebuild_starts | 2048 × 8 bytes | 16 KB |
| Task 0 缓存 | 1 × 56 bytes | 56 bytes |
| Task 1 缓存 | 1 × 56 bytes | 56 bytes |
| ... | ... | ... |
| Task 7 缓存 | 1 × 56 bytes | 56 bytes |
| 每个 Task 缓存数组 | 1024 entries × 16 bytes × 8 | 128 KB |
| **总计** | - | **约 160 KB** |

**缓存数组详细**:
```
G1RegionMarkStatsCacheEntry 大小:
- uint _region_idx: 4 bytes
- padding: 4 bytes
- G1RegionMarkStats _stats: 8 bytes
- 总计: 16 bytes

1024 entries × 16 bytes = 16 KB per Task
8 Tasks × 16 KB = 128 KB total
```

### 6.2 与堆大小的比例

```
堆大小: 8 GB
Region 统计总占用: ~160 KB
比例: 160 KB / 8 GB = 0.002%

结论: Region 统计的内存开销极小，可忽略不计
```

---

## 七、性能优化设计

### 7.1 缓存命中优化

```cpp
// 哈希函数简单高效（位操作）
uint hash(uint idx) {
  return idx & _num_cache_entries_mask;  // 与操作，相当于取模
}

// 例如: cache_size = 1024, mask = 1023
// Region 0     → hash = 0 & 1023 = 0
// Region 1024  → hash = 1024 & 1023 = 0  (冲突)
// Region 1     → hash = 1 & 1023 = 1
// Region 1025  → hash = 1025 & 1023 = 1  (冲突)
```

**冲突处理**:
- 冲突时 evict 旧条目到全局数组
- 1024 个缓存槽位，2048 个 Region，理论冲突率 50%
- 但由于对象访问的局部性，实际冲突率更低

### 7.2 批量更新策略

```
场景对比:

无缓存（每次原子操作）:
标记 1000 个对象 → 1000 次原子操作

有缓存（批量 flush）:
标记 1000 个对象 → 假设命中 900 次
                  → 仅 100 次 flush 到全局数组
                  → 性能提升约 10 倍
```

### 7.3 统计日志输出

```
// 启用 GC 统计日志查看缓存命中率
-XX:+PrintGCDetails -Xlog:gc+stats

输出示例:
[gc,stats] Mark stats cache hits 1234567 misses 12345 ratio 0.990
```

---

## 八、与其他机制的关联

### 8.1 与 nTAMS 的关系

```
G1RegionMarkStats 统计的是 [bottom, nTAMS) 区间的存活对象

Region 内存布局:
├─────────────────────────────────────────────────────────┤
bottom              nTAMS (next Top At Mark Start)       top
│                        │                                 │
└────────统计区间────────┘                                 │
  (并发标记时存活对象)                                      │
                                                         │
                                    新分配对象（隐式存活）│

说明:
- 并发标记开始时，nTAMS = top
- 标记期间，nTAMS 保持不变
- 标记期间新分配的对象在 nTAMS 之上，不参与本次标记
- 这些新对象在本次 GC 中隐式视为存活
```

### 8.2 与 _top_at_rebuild_starts 的关系

```cpp
// 在并发标记期间记录每个 Region 的 top
HeapWord* volatile* _top_at_rebuild_starts;

// 用途:
// 在 Remark 阶段后，用于重建 Remembered Set
// 确定哪些区域需要扫描

void update_top_at_rebuild_start(HeapRegion* r) {
  _top_at_rebuild_starts[r->hrm_index()] = r->top();
}
```

### 8.3 与 Mixed GC 选择的关系

```
Region 垃圾占比计算:

live_words = _region_mark_stats[region_idx]._live_words
live_bytes = live_words * 8  (HeapWordSize)
total_bytes = RegionSize = 4MB
garbage_bytes = total_bytes - live_bytes
garbage_ratio = garbage_bytes / total_bytes

Mixed GC 选择策略:
1. 只考虑 garbage_ratio > G1MixedGCLiveThresholdPercent (默认85%)
2. 按 garbage_ratio 降序排序
3. 优先选择垃圾占比高的 Region
4. 受限于 G1MixedGCCountTarget 和 G1MixedGCLiveThresholdPercent
```

---

## 九、GDB 验证完整报告

### 9.1 验证脚本

```gdb
# GDB验证脚本: G1RegionMarkStats
# 保存为 verify_region_stats.gdb

set width 0
set pagination off
set confirm off

break /data/workspace/openjdk-cut-new/src/hotspot/share/memory/universe.cpp:1265

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp <classpath> <MainClass>

set $g1h = G1CollectedHeap::heap()
set $cm = $g1h->_cm

printf "\n=== G1RegionMarkStats 结构 ===\n"
printf "sizeof(G1RegionMarkStats) = %zu bytes\n", sizeof(G1RegionMarkStats)

printf "\n=== 全局统计数组 ===\n"
set $max_regions = $g1h->max_regions()
printf "max_regions = %u\n", $max_regions
printf "_region_mark_stats = %p\n", $cm->_region_mark_stats
printf "数组大小 = %u × %zu = %zu KB\n", 
       $max_regions, sizeof(G1RegionMarkStats),
       ($max_regions * sizeof(G1RegionMarkStats)) / 1024

printf "\n=== 线程缓存 ===\n"
printf "G1RegionMarkStatsCacheSize = %u\n", G1CMTask::RegionMarkStatsCacheSize
printf "sizeof(G1RegionMarkStatsCache) = %zu bytes\n", 
       sizeof(G1RegionMarkStatsCache)

printf "\n=== Task 缓存地址 ===\n"
set $task0 = $cm->task(0)
printf "Task 0 address = %p\n", $task0
printf "Task 0 cache address = %p\n", &$task0->_mark_stats_cache

printf "\n=== 验证通过 ===\n"

quit
```

### 9.2 验证结果汇总

| 检查项 | 实际值 | 分析 |
|--------|--------|------|
| G1RegionMarkStats 大小 | 8 字节 | 仅一个 size_t 字段 |
| max_regions | 2048 | 8GB / 4MB = 2048 |
| 全局统计数组大小 | 16 KB | 2048 × 8 bytes |
| 统计数组地址 | 0x7ffff005a500 ~ 0x7ffff005e500 | 连续 16KB |
| RegionMarkStatsCacheSize | 1024 | 常量定义 |
| G1RegionMarkStatsCache 大小 | 56 字节 | 含指针和统计字段 |
| Task 0 地址 | 0x7ffff0066b40 | - |
| Task 0 缓存地址 | 0x7ffff0066b78 | Task 内偏移 +0x38 |

---

## 十、总结

### 10.1 核心设计要点

| 设计决策 | 实现 | 优势 |
|----------|------|------|
| 分层统计 | 本地缓存 + 全局数组 | 减少竞争，提高性能 |
| 哈希缓存 | 1024 槽位，位操作哈希 | O(1) 访问，简单高效 |
| 批量 flush | 缓存未命中时才同步 | 大幅减少原子操作 |
| 极简结构 | 仅一个 _live_words | 最小内存开销 |
| 线程隔离 | 每 Task 一个缓存 | 无锁快速路径 |

### 10.2 关键数值

```
8GB 堆配置:
├── Region 数量: 2048 个
├── 每 Region 统计: 8 字节
├── 全局统计数组: 16 KB
├── 每 Task 缓存: 16 KB (1024 entries × 16 bytes)
├── 总缓存开销: ~128 KB (8 Tasks)
└── 统计总开销: ~160 KB (可忽略不计)
```

### 10.3 学习路径衔接

```
已完成的 Mixed GC 数据结构:
├── 2.1 G1CMMarkStack - 全局标记栈
├── 2.2 G1SATBMarkQueue - SATB 队列
├── 2.3 G1CMBitMap - 双缓冲位图
└── 2.4 G1RegionMarkStats - Region 统计 ← 当前

下一步:
├── 2.5 G1HotCardCache - 热卡片缓存
└── 2.6 G1ConcurrentRefine - 并发精炼
```

---

**文档完成日期**: 2026-02-11  
**GDB 验证状态**: ✅ 全部关键数据已验证  
**下一篇预告**: 2.5 G1HotCardCache - 热卡片缓存优化
