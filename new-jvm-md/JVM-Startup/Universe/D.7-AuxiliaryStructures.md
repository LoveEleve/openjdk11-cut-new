# D.7 辅助数据结构详解

> **分析条件**：8GB 堆（-Xms8g -Xmx8g），G1 GC，4MB Region
> **源码位置**：`g1CollectedHeap.cpp:1480-1490`

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **D.7 辅助数据结构详解**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 概述

G1CollectedHeap 构造函数中这些字段初始化为 NULL：

```cpp
_bot(NULL),            // Block Offset Table - 对象起始位置索引
_hot_card_cache(NULL), // 热卡缓存 - 延迟写屏障处理
_g1_rem_set(NULL),     // Remembered Set - 跨代引用记录
_cr(NULL),             // Concurrent Refinement - 并发精炼线程
_g1mm(NULL),           // Monitoring Support - JMX/jstat 监控
```

**为什么初始化为 NULL？**
- 这些结构需要依赖堆内存映射完成后才能创建
- 在 `G1CollectedHeap::initialize()` 中实际分配

虽然此时是 NULL，但理解它们的作用对后续分析至关重要。

---

## 1. G1BlockOffsetTable (BOT) - 对象起始查找

### 1.1 核心作用

BOT 用于**快速定位任意地址所在对象的起始位置**。

**场景**：GC 扫描卡表时，卡（512B）可能跨越多个对象，需要找到第一个对象的起始位置。

```
卡 (512B)
┌────────────────────────────────────────────┐
│   ┌──obj1───┐   ┌──────obj2──────┐  ┌─obj3 │ ...
│   │ header  │   │     header     │  │      │
│   │  data   │   │      data      │  │      │
│   └─────────┘   └────────────────┘  └──────│
└────────────────────────────────────────────┘
                                        ↑
                        GC 需要从这里找到 obj3 的起始
```

### 1.2 数据结构

```cpp
// g1BlockOffsetTable.hpp:45
class G1BlockOffsetTable: public CHeapObj<mtGC> {
  MemRegion _reserved;           // 覆盖的堆区域
  volatile u_char* _offset_array; // 偏移数组，1 字节/卡
};
```

**内存开销**：
```
8GB 堆 / 512B 卡 = 16M 个卡
偏移数组大小 = 16M × 1B = 16MB
开销比例 = 16MB / 8GB = 0.2%
```

### 1.3 查找算法

```cpp
// 给定地址 p，找到包含 p 的对象起始
HeapWord* block_start(const void* p) {
  size_t index = card_index(p);           // 计算所在卡索引
  u_char offset = _offset_array[index];   // 读取偏移值
  
  // 如果偏移 <= N_words(8)，直接回退
  // 否则递归回退多张卡
  while (offset == N_words) {
    index -= N_words;
    offset = _offset_array[index];
  }
  return card_to_block(index - offset);
}
```

### 1.4 🏭 生产环境实践

**诊断命令**：
```bash
# 查看 BOT 内存占用
jcmd <pid> VM.native_memory summary | grep "Card Table"
```

**性能影响**：
- BOT 查找是 O(1)~O(n) 操作，n 为跨越的卡数
- 大对象会导致多次回退，但通常很快收敛

---

## 2. G1HotCardCache - 热卡缓存

### 2.1 核心作用

**延迟处理频繁写入的卡**，提高写屏障性能。

**问题**：应用程序频繁更新同一个对象的引用字段，每次都触发写屏障会很昂贵。

**解决**：热卡缓存延迟这些卡的精炼，让写屏障快速返回。

### 2.2 工作流程

```
┌─────────────────────────────────────────────────────────────────┐
│  应用线程写引用                                                    │
│       ↓                                                          │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ 写屏障: if (card.is_dirty) return;  // 热卡直接跳过！    │    │
│  │                                                         │    │
│  │ card_counts[card]++;                                    │    │
│  │ if (count < threshold) {                                │    │
│  │   // 冷卡 → 立即放入 DCQS 等待精炼                        │    │
│  │   dcqs.enqueue(card);                                   │    │
│  │ } else {                                                │    │
│  │   // 热卡 → 放入缓存，延迟处理                            │    │
│  │   hot_cache.insert(card);  // 可能驱逐旧卡               │    │
│  │ }                                                       │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
                               ↓
                    GC STW 时统一处理缓存
```

### 2.3 数据结构

```cpp
// g1HotCardCache.hpp:56
class G1HotCardCache: public CHeapObj<mtGC> {
  bool              _use_cache;      // 是否启用（默认 true）
  G1CardCounts      _card_counts;    // 每张卡的访问计数
  
  jbyte**           _hot_cache;      // 热卡指针数组
  size_t            _hot_cache_size; // 缓存大小
  volatile size_t   _hot_cache_idx;  // 当前插入位置
};
```

**缓存大小**：
```cpp
_hot_cache_size = 1 << G1ConcRSLogCacheSize;  // 默认 1 << 10 = 1024
// 内存 = 1024 × 8B = 8KB
```

### 2.4 🏭 生产环境实践

**相关参数**：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `G1ConcRSLogCacheSize` | 10 | 热卡缓存大小 = 2^10 = 1024 |
| `G1ConcRSHotCardLimit` | 4 | 访问 ≥4 次判定为热卡 |

**调优建议**：

```bash
# 高写入负载场景（如大量更新操作）
-XX:G1ConcRSLogCacheSize=12   # 缓存增大到 4096

# 低延迟场景（减少 GC 暂停时的缓存处理）
-XX:G1ConcRSLogCacheSize=8    # 缓存减小到 256
```

**监控**：
```bash
# 通过 GC 日志查看热卡缓存处理
-Xlog:gc+remset*=debug

# 输出示例
[gc,remset] Hot Card Cache: size 1024, used 876
```

---

## 3. G1RemSet - 记忆集

### 3.1 核心作用

**记录跨 Region 引用**，避免 GC 时扫描整个堆。

```
Region A (老年代)          Region B (年轻代，待回收)
┌─────────────────┐       ┌─────────────────┐
│  obj_old        │──────→│  obj_young      │
│                 │       │  (需要回收)      │
└─────────────────┘       └─────────────────┘
                          
如果没有 RSet，GC 需要扫描整个堆找到 obj_old → obj_young 的引用
有了 RSet，Region B 的 RSet 记录了"Region A 的某个位置指向我"
```

### 3.2 数据结构

```cpp
// g1RemSet.hpp:69
class G1RemSet : public CHeapObj<mtGC> {
  G1RemSetScanState* _scan_state;     // GC 期间的扫描状态
  G1CardTable*       _ct;             // 卡表引用
  G1HotCardCache*    _hot_card_cache; // 热卡缓存
  
  size_t _num_conc_refined_cards;     // 统计：并发精炼的卡数
};
```

### 3.3 三层结构回顾

详见 [C.2-RemSetSize.md](C.2-RemSetSize.md)：

| 层级 | 数据结构 | 适用场景 | 8GB 配置 |
|------|----------|----------|----------|
| Sparse | 哈希表 | 少量引用 | 每源 Region ≤12 张卡 |
| Fine | Bitmap | 中等引用 | ≤768 个 PRT |
| Coarse | 位图 | 大量引用 | 2048 位 |

### 3.4 🏭 生产环境实践

**监控 RSet 内存**：
```bash
# GC 日志
-Xlog:gc+remset*=debug

# 输出示例
[gc,remset] Remembered Sets: 
  Young: 0 entries
  Old: 15234 entries
  Coarse: 3 regions
  Mem: 12.5MB
```

**问题诊断**：RSet 占用过高
```bash
# 症状：Update RS 时间过长
[gc,phases] Update RS (ms): Min: 15.2, Avg: 18.5, Max: 25.3

# 可能原因
1. 老年代对年轻代引用过多（常见于大缓存场景）
2. Region 大小不合适

# 解决方案
-XX:G1HeapRegionSize=8m  # 增大 Region，减少跨 Region 引用
```

---

## 4. G1ConcurrentRefine - 并发精炼

### 4.1 核心作用

**并发处理脏卡队列**，将卡表更新转化为 RSet 更新。

应用线程的写屏障只是将脏卡放入队列，真正的 RSet 更新由精炼线程异步完成。

### 4.2 三色区域机制

```cpp
// g1ConcurrentRefine.hpp:71
class G1ConcurrentRefine : public CHeapObj<mtGC> {
  size_t _green_zone;    // [0, green): 不处理，享受缓存效果
  size_t _yellow_zone;   // [green, yellow): 逐步激活精炼线程
  size_t _red_zone;      // [yellow, red): 所有线程全速运行
                         // ≥ red: 应用线程直接处理！
};
```

**流程图**：

```
队列长度
    │
    │  ┌─────────────────────────────────────────────────┐
red │  │ 应用线程直接处理（最坏情况，影响吞吐）            │
    │  └─────────────────────────────────────────────────┘
    │  ┌─────────────────────────────────────────────────┐
yellow│ │ 所有精炼线程运行                                │
    │  └─────────────────────────────────────────────────┘
    │  ┌─────────────────────────────────────────────────┐
green│  │ 逐步激活精炼线程                                │
    │  └─────────────────────────────────────────────────┘
    │  ┌─────────────────────────────────────────────────┐
  0 │  │ 不处理，享受缓存效果                             │
    │  └─────────────────────────────────────────────────┘
```

### 4.3 默认区域值

```cpp
// g1ConcurrentRefine.cpp:246
green  = ParallelGCThreads;              // 13
yellow = green * 2;                       // 26
red    = yellow + (yellow - green);       // 39
```

**8GB 堆（16 核）配置**：
```
Green Zone:  13 个缓冲区
Yellow Zone: 26 个缓冲区
Red Zone:    39 个缓冲区
```

### 4.4 🏭 生产环境实践

**相关参数**：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `G1ConcRefinementThreads` | ParallelGCThreads | 精炼线程数 |
| `G1UseAdaptiveConcRefinement` | true | 自适应调整区域 |
| `G1ConcRefinementGreenZone` | 0 (自动) | Green 区域阈值 |
| `G1ConcRefinementYellowZone` | 0 (自动) | Yellow 区域阈值 |
| `G1ConcRefinementRedZone` | 0 (自动) | Red 区域阈值 |

**监控**：
```bash
-Xlog:gc+refine*=debug

# 输出示例
[gc,refine] Concurrent refinement: 
  Green zone: 13, Yellow zone: 26, Red zone: 39
  Threads: 13 (active: 2)
  Refined cards: 15234
```

**问题诊断**：精炼跟不上

```bash
# 症状：频繁进入 Red Zone
[gc,refine] DCQS: 45 buffers (red threshold: 39)

# 解决方案
1. 增加精炼线程
   -XX:G1ConcRefinementThreads=20

2. 降低 Green Zone（减少缓存，更早开始处理）
   -XX:G1ConcRefinementGreenZone=8

3. 检查是否有异常的写入模式
```

---

## 5. G1MonitoringSupport - JMX/jstat 监控

### 5.1 核心作用

为 **jstat** 和 **JMX** 提供 G1 GC 统计数据。

### 5.2 数据结构

```cpp
// g1MonitoringSupport.hpp:117
class G1MonitoringSupport : public CHeapObj<mtGC> {
  // jstat 计数器
  CollectorCounters*   _incremental_collection_counters;  // YGC 计数
  CollectorCounters*   _full_collection_counters;         // Full GC 计数
  CollectorCounters*   _conc_collection_counters;         // 并发 GC 计数
  
  // 内存池计数器
  GenerationCounters*  _young_collection_counters;        // 年轻代
  GenerationCounters*  _old_collection_counters;          // 老年代
  
  // 空间计数器
  HSpaceCounters*      _eden_counters;
  HSpaceCounters*      _from_counters;   // Survivor from
  HSpaceCounters*      _to_counters;     // Survivor to
  HSpaceCounters*      _old_space_counters;
};
```

### 5.3 🏭 生产环境实践

**jstat 监控**：
```bash
# 每秒输出一次 GC 统计
jstat -gc <pid> 1000

# 输出字段解释（G1 相关）
# S0C/S1C: Survivor 容量（G1 中动态变化）
# EC: Eden 容量
# OC: Old 容量
# YGC: Young GC 次数
# YGCT: Young GC 总时间
# FGC: Full GC 次数
# FGCT: Full GC 总时间
```

**JMX 监控**：
```java
// 获取 G1 内存池
ManagementFactory.getMemoryPoolMXBeans().forEach(pool -> {
    if (pool.getName().contains("G1")) {
        System.out.println(pool.getName() + ": " + pool.getUsage());
    }
});

// 输出示例
G1 Eden Space: init=524288000, used=104857600, committed=524288000, max=524288000
G1 Survivor Space: init=0, used=8388608, committed=8388608, max=-1
G1 Old Gen: init=7549747200, used=52428800, committed=7549747200, max=8589934592
```

---

## 6. 完整架构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         G1CollectedHeap                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐                   │
│  │ HeapRegion 0 │    │ HeapRegion 1 │    │ HeapRegion N │                   │
│  │  ┌────────┐  │    │  ┌────────┐  │    │  ┌────────┐  │                   │
│  │  │ RSet   │←─┼────┼──│ 引用   │  │    │  │        │  │                   │
│  │  └────────┘  │    │  └────────┘  │    │  └────────┘  │                   │
│  └──────────────┘    └──────────────┘    └──────────────┘                   │
│         ↑                                                                    │
│         │                                                                    │
│  ┌──────┴───────────────────────────────────────────────────────────────┐   │
│  │                          G1RemSet                                     │   │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐       │   │
│  │  │ G1CardTable     │  │ G1HotCardCache  │  │ G1RemSetScanState│       │   │
│  │  │ (卡表)          │  │ (热卡缓存)       │  │ (扫描状态)       │       │   │
│  │  └─────────────────┘  └─────────────────┘  └─────────────────┘       │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│         ↑                       ↑                                            │
│         │                       │                                            │
│  ┌──────┴───────────────┐  ┌───┴──────────────────────────────────────┐     │
│  │ G1BlockOffsetTable   │  │           G1ConcurrentRefine             │     │
│  │ (对象起始索引)        │  │  ┌───────┐ ┌───────┐ ┌───────┐          │     │
│  │                      │  │  │Thread0│ │Thread1│ │ThreadN│          │     │
│  │ 16MB (8GB堆)         │  │  └───────┘ └───────┘ └───────┘          │     │
│  └──────────────────────┘  │                                          │     │
│                            │  Green → Yellow → Red Zone 控制          │     │
│                            └──────────────────────────────────────────┘     │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                     G1MonitoringSupport                               │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                   │   │
│  │  │ jstat 计数器 │  │ JMX 内存池  │  │ GC 事件追踪 │                   │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘                   │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 7. 🏭 生产环境综合监控清单

### 7.1 关键 JVM 参数

```bash
# 基础 G1 配置
-XX:+UseG1GC
-Xms8g -Xmx8g
-XX:MaxGCPauseMillis=200

# RSet 相关
-XX:G1RSetUpdatingPauseTimePercent=10   # Update RS 最大占暂停时间比例

# 并发精炼
-XX:G1ConcRefinementThreads=13          # 通常等于 ParallelGCThreads

# 日志（诊断时开启）
-Xlog:gc*=info
-Xlog:gc+remset*=debug
-Xlog:gc+refine*=debug
```

### 7.2 监控指标

| 指标 | 获取方式 | 正常范围 | 异常信号 |
|------|----------|----------|----------|
| Update RS 时间 | GC 日志 | < 10% 暂停时间 | > 20% |
| 精炼线程活跃数 | `gc+refine` 日志 | 0-3 | 持续 = max |
| RSet 内存 | `gc+remset` 日志 | < 5% 堆 | > 10% |
| 热卡缓存命中 | `gc+remset` 日志 | > 50% | < 20% |

### 7.3 常见问题速查

| 问题 | 症状 | 解决方案 |
|------|------|----------|
| RSet 膨胀 | Update RS 时间长 | 增大 Region、检查引用模式 |
| 精炼跟不上 | 进入 Red Zone | 增加精炼线程、降低 Green Zone |
| BOT 查找慢 | STW 中 Scan RS 慢 | 检查大对象分布 |

---

## GDB 验证脚本

```bash
# 文件：jvm-md/tmp-file/universe-init/gdb_auxiliary.txt

# 断点设置
b G1CollectedHeap::initialize
commands
  printf "\n=== D.7 辅助数据结构验证 ===\n"
  
  # BOT 相关
  printf "\n[1] G1BlockOffsetTable:\n"
  printf "  _bot = %p\n", _bot
  
  # 热卡缓存
  printf "\n[2] G1HotCardCache:\n"
  printf "  _hot_card_cache = %p\n", _hot_card_cache
  printf "  G1ConcRSLogCacheSize = %d\n", G1ConcRSLogCacheSize
  printf "  缓存大小 = %d 条目\n", (1 << G1ConcRSLogCacheSize)
  
  # RemSet
  printf "\n[3] G1RemSet:\n"
  printf "  _g1_rem_set = %p\n", _g1_rem_set
  
  # 并发精炼
  printf "\n[4] G1ConcurrentRefine:\n"
  printf "  _cr = %p\n", _cr
  printf "  G1ConcRefinementThreads = %d\n", G1ConcRefinementThreads
  
  # 监控
  printf "\n[5] G1MonitoringSupport:\n"
  printf "  _g1mm = %p\n", _g1mm
  
  continue
end

run
```

**预期输出**（构造函数中）：
```
=== D.7 辅助数据结构验证 ===

[1] G1BlockOffsetTable:
  _bot = 0x0                    # 构造函数中为 NULL

[2] G1HotCardCache:
  _hot_card_cache = 0x0         # 构造函数中为 NULL
  G1ConcRSLogCacheSize = 10
  缓存大小 = 1024 条目

[3] G1RemSet:
  _g1_rem_set = 0x0             # 构造函数中为 NULL

[4] G1ConcurrentRefine:
  _cr = 0x0                     # 构造函数中为 NULL
  G1ConcRefinementThreads = 13

[5] G1MonitoringSupport:
  _g1mm = 0x0                   # 构造函数中为 NULL
```

---

## 待分析节点更新

| 节点 | 主题 | 状态 |
|------|------|------|
| D.7.1 | 为什么这些字段先设为 NULL？ | ✅ |
| D.7.2 | 每个字段的用途概述 | ✅ |

> 这些结构在 `G1CollectedHeap::initialize()` 中实际创建，详见 3.2 节分析。
