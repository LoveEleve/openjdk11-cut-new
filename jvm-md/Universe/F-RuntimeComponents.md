# F. 运行时组件初始化

## 概述

在堆内存扩展完成（E 部分）后，G1 需要初始化一系列运行时组件来支持 GC 的正常运行：

```
initialize() 最后阶段调用链:
├── F.1 G1Policy::init()           - GC 策略初始化
├── F.2 SATBMarkQueueSet 初始化    - SATB 写前屏障队列
├── F.3 DirtyCardQueueSet 初始化   - 脏卡写后屏障队列
├── F.4 G1AllocRegion 初始化       - 分配区域管理
├── F.5 G1MonitoringSupport        - JMX 监控支持
├── F.6 G1StringDedup 初始化       - 字符串去重
└── F.7 PreservedMarksSet 初始化   - Evacuation Failure 保护
```

---

## F.1 G1Policy 初始化

### F.1.1 核心作用

G1Policy 是 G1 GC 的"大脑"，负责：
- 年轻代大小的动态调整
- GC 暂停时间预测和控制
- 收集集合（CSet）的选择策略

```cpp
// src/hotspot/share/gc/g1/g1CollectedHeap.cpp:2217
g1_policy()->init(this, &_collection_set);
```

### F.1.2 init() 方法详解

```cpp
// src/hotspot/share/gc/g1/g1Policy.cpp:79
void G1Policy::init(G1CollectedHeap* g1h, G1CollectionSet* collection_set) {
  _g1h = g1h;
  _collection_set = collection_set;
  
  // 1. 年轻代模式判断
  if (!adaptive_young_list_length()) {
    // 固定模式：使用最小年轻代长度
    _young_list_fixed_length = _young_gen_sizer.min_desired_young_length();
  }
  
  // 2. 调整年轻代最大边界
  _young_gen_sizer.adjust_max_new_size(_g1h->max_regions());
  
  // 3. 初始化空闲 Region 计数
  _free_regions_at_end_of_collection = _g1h->num_free_regions(); // 2048
  
  // 4. 计算年轻代目标长度
  update_young_list_max_and_target_length();
  
  // 5. 启动 CSet 增量构建
  _collection_set->start_incremental_building();
}
```

### F.1.3 年轻代大小计算（8GB 堆）

```
自适应模式（默认）:
┌─────────────────────────────────────────────────────────────┐
│  参数                        │  值                          │
├─────────────────────────────────────────────────────────────┤
│  G1NewSizePercent            │  5%                          │
│  G1MaxNewSizePercent         │  60%                         │
│  heap_regions                │  2048                        │
├─────────────────────────────────────────────────────────────┤
│  min_desired_young_length    │  2048 × 5% = 102 (408MB)    │
│  max_desired_young_length    │  2048 × 60% = 1228 (4.9GB)  │
├─────────────────────────────────────────────────────────────┤
│  初始目标                                                   │
│  _young_list_target_length   │  102 个 Region (408MB)      │
│  _young_list_max_length      │  108 个 Region (432MB)      │
└─────────────────────────────────────────────────────────────┘

年轻代大小会根据以下因素动态调整:
- 记忆集长度预测（RSet 大小）
- GC 暂停时间目标（MaxGCPauseMillis）
- 应用分配速率
- 对象存活率预测
```

### F.1.4 两种年轻代模式对比

| 模式 | 配置方式 | 特点 |
|------|----------|------|
| **自适应模式** | 默认（不设置 NewSize） | 年轻代在 102-1228 Region 间动态调整 |
| **固定模式** | `-XX:NewSize=MaxNewSize` 或 `-XX:NewRatio` | 年轻代大小固定不变 |

---

## F.2 SATBMarkQueueSet 初始化

### F.2.1 SATB 机制回顾

SATB（Snapshot-At-The-Beginning）是并发标记的核心机制，通过**写前屏障**记录并发标记期间被覆盖的引用：

```
写前屏障伪代码:
void write_ref_field_pre(oop* field) {
  oop old_value = *field;
  if (marking_active && old_value != NULL) {
    satb_queue.enqueue(old_value);  // 保存旧值
  }
}
```

### F.2.2 初始化代码

```cpp
// src/hotspot/share/gc/g1/g1CollectedHeap.cpp:2233
G1BarrierSet::satb_mark_queue_set().initialize(
    SATB_Q_CBL_mon,              // 完成缓冲区列表的 Monitor 锁
    SATB_Q_FL_lock,              // 空闲缓冲区池的 Mutex 锁
    G1SATBProcessCompletedThreshold,  // = 20，触发处理阈值
    Shared_SATB_Q_lock           // 共享队列的锁（VM线程用）
);
```

### F.2.3 队列架构

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        SATBMarkQueueSet                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────────┐                                                    │
│  │ _shared_satb_queue │  ← VM线程、GC线程共用                           │
│  └─────────────────┘                                                    │
│                                                                          │
│  每个 Java 线程各有一个 SATBMarkQueue（线程本地）                        │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐                        │
│  │ Thread 1    │ │ Thread 2    │ │ Thread N    │                        │
│  │ SATBQueue   │ │ SATBQueue   │ │ SATBQueue   │                        │
│  │ ┌─────────┐ │ │ ┌─────────┐ │ │ ┌─────────┐ │                        │
│  │ │ buffer  │ │ │ │ buffer  │ │ │ │ buffer  │ │                        │
│  │ │ 1KB     │ │ │ │ 1KB     │ │ │ │ 1KB     │ │                        │
│  │ └─────────┘ │ │ └─────────┘ │ │ └─────────┘ │                        │
│  └──────┬──────┘ └──────┬──────┘ └──────┬──────┘                        │
│         │               │               │                                │
│         └───────────────┼───────────────┘                                │
│                         ▼                                                │
│              ┌─────────────────────┐                                    │
│              │  Completed Buffer   │  ← 缓冲区满后入队                  │
│              │       List          │                                    │
│              │  (阈值 = 20)        │                                    │
│              └─────────────────────┘                                    │
│                         │                                                │
│                         │ 达到阈值后                                     │
│                         ▼                                                │
│              ┌─────────────────────┐                                    │
│              │  GC 线程处理        │                                    │
│              │  标记保存的旧值     │                                    │
│              └─────────────────────┘                                    │
│                                                                          │
│  ┌─────────────────────┐                                                │
│  │   Free Buffer Pool  │  ← 缓冲区复用池                                │
│  └─────────────────────┘                                                │
└─────────────────────────────────────────────────────────────────────────┘
```

### F.2.4 关键参数

| 参数 | 值 | 含义 |
|------|------|------|
| `G1SATBProcessCompletedThreshold` | 20 | 完成队列达到 20 个缓冲区时开始处理 |
| 缓冲区大小 | 1KB | 每个 SATB 缓冲区可存储 128 个指针 |

---

## F.3 DirtyCardQueueSet 初始化

### F.3.1 两个脏卡队列集合

G1 有**两个** DirtyCardQueueSet，用途不同：

```cpp
// 1. 全局脏卡队列（主角）- G1BarrierSet 持有
G1BarrierSet::dirty_card_queue_set().initialize(
    DirtyCardQ_CBL_mon,
    DirtyCardQ_FL_lock,
    (int) concurrent_refine()->yellow_zone(),  // = 39，触发精炼
    (int) concurrent_refine()->red_zone(),     // = 65，队列上限
    Shared_DirtyCardQ_lock,
    NULL,   // 自己管理空闲缓冲区池
    true    // 初始化并行处理 ID
);

// 2. 堆自己的脏卡队列（辅助）- G1CollectedHeap 持有
dirty_card_queue_set().initialize(
    DirtyCardQ_CBL_mon,
    DirtyCardQ_FL_lock,
    -1,     // 永不触发自动处理
    -1,     // 队列长度无限制
    Shared_DirtyCardQ_lock,
    &G1BarrierSet::dirty_card_queue_set()  // 借用第一个的空闲池
);
```

### F.3.2 两者区别

| 特性 | G1BarrierSet 的 | G1CollectedHeap 的 |
|------|-----------------|-------------------|
| 触发处理阈值 | 39 个缓冲区 | -1（永不触发） |
| 队列长度上限 | 65 个缓冲区 | -1（无限制） |
| 空闲缓冲区池 | 自己管理 | 借用第一个的 |
| 用途 | Java 线程写屏障 | GC 内部使用 |

### F.3.3 队列架构与精炼触发

```
┌─────────────────────────────────────────────────────────────────────────┐
│                   DirtyCardQueueSet 工作流程                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Java 线程执行写操作:                                                    │
│  ┌─────────────────────────────────────────────────────────────┐        │
│  │  obj.field = new_value;                                     │        │
│  │                                                             │        │
│  │  // 写后屏障                                                 │        │
│  │  card_table[&obj.field >> 9] = dirty;                       │        │
│  │  dirty_card_queue.enqueue(&obj.field >> 9);                 │        │
│  └─────────────────────────────────────────────────────────────┘        │
│                              │                                           │
│                              ▼                                           │
│  ┌─────────────────────────────────────────────────────────────┐        │
│  │              Completed Buffer List                          │        │
│  │                                                             │        │
│  │  ┌────┐ ┌────┐ ┌────┐ ┌────┐ ... ┌────┐                    │        │
│  │  │ B1 │ │ B2 │ │ B3 │ │ B4 │     │ Bn │                    │        │
│  │  └────┘ └────┘ └────┘ └────┘     └────┘                    │        │
│  │                                                             │        │
│  │  队列长度:                                                  │        │
│  │    < 13 (Green)  → 精炼线程休眠                             │        │
│  │    ≥ 39 (Yellow) → 唤醒精炼线程处理                         │        │
│  │    ≥ 65 (Red)    → Java 线程自己处理                        │        │
│  └─────────────────────────────────────────────────────────────┘        │
│                              │                                           │
│                              ▼                                           │
│  ┌─────────────────────────────────────────────────────────────┐        │
│  │              G1ConcurrentRefine 线程处理                    │        │
│  │                                                             │        │
│  │  for each card in buffer:                                   │        │
│  │    region = card_to_region(card)                            │        │
│  │    if (region->rem_set needs update)                        │        │
│  │      update_rem_set(card)                                   │        │
│  └─────────────────────────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## F.4 G1AllocRegion 初始化

### F.4.1 Dummy Region 机制

```cpp
// src/hotspot/share/gc/g1/g1CollectedHeap.cpp:2278
HeapRegion* dummy_region = _hrm.get_dummy_region();
dummy_region->set_eden();
dummy_region->set_top(dummy_region->end());  // 标记为"满的"
G1AllocRegion::setup(this, dummy_region);
_allocator->init_mutator_alloc_region();
```

### F.4.2 为什么需要 Dummy Region？

```
问题场景:
  GC 过程中，可能没有可用的 Region 来分配对象
  此时 _alloc_region 应该指向什么？

解决方案: 使用"满的"假 Region 作为占位符

正常情况:
  _alloc_region ─────► [Region X]
                       top < end
                       free() > 0
                       分配成功 ✓

无可用 Region 时:
  _alloc_region ─────► [dummy_region]
                       top = end
                       free() = 0
                       分配失败 → 触发 slow path

优点:
  - 无需判断 _alloc_region == NULL
  - 统一的分配失败处理路径
  - 空指针的优雅替代
```

### F.4.3 G1Allocator 结构

```cpp
class G1Allocator {
  MutatorAllocRegion _mutator_alloc_region;    // Java 线程分配普通对象
  SurvivorGCAllocRegion _survivor_gc_alloc_region;  // GC 复制到 Survivor
  OldGCAllocRegion _old_gc_alloc_region;       // GC 晋升到 Old
};
```

```
分配流程:
┌─────────────────────────────────────────────────────────────────────────┐
│  Java 线程分配对象                                                       │
│                                                                          │
│  1. Fast Path (TLAB 内分配)                                              │
│     if (tlab.remaining >= obj_size)                                     │
│       return tlab.allocate(obj_size)                                    │
│                                                                          │
│  2. TLAB 不够 → 从 MutatorAllocRegion 分配新 TLAB                        │
│     if (_mutator_alloc_region.free() >= tlab_size)                      │
│       return allocate_new_tlab()                                        │
│                                                                          │
│  3. Region 也不够 → Slow Path                                            │
│     region = _free_list.get_first()  // 从空闲链表获取新 Region          │
│     _mutator_alloc_region.set(region)                                   │
│     return retry_allocation()                                           │
│                                                                          │
│  4. 没有空闲 Region → 触发 GC                                            │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## F.5 G1MonitoringSupport

### F.5.1 监控数据提供

```cpp
// src/hotspot/share/gc/g1/g1CollectedHeap.cpp:2334
_g1mm = new G1MonitoringSupport(this);
```

G1MonitoringSupport 为以下工具提供监控数据：

| 工具 | 用途 |
|------|------|
| `jstat -gc` / `jstat -gcutil` | GC 统计信息 |
| `MemoryMXBean` | Java 内存管理 API |
| JConsole / VisualVM | 可视化监控 |
| `-Xlog:gc*` | GC 日志 |

### F.5.2 提供的指标

```
G1MonitoringSupport 提供:
┌─────────────────────────────────────────────────────────────┐
│  Eden 空间统计                                               │
│  - 当前大小 / 已使用 / 最大容量                              │
│                                                              │
│  Survivor 空间统计                                           │
│  - 当前大小 / 已使用 / 最大容量                              │
│                                                              │
│  Old 空间统计                                                │
│  - 当前大小 / 已使用 / 最大容量                              │
│                                                              │
│  GC 次数和时间                                               │
│  - Young GC 次数 / 总时间                                    │
│  - Mixed GC 次数 / 总时间                                    │
│  - Full GC 次数 / 总时间                                     │
└─────────────────────────────────────────────────────────────┘
```

---

## F.6 G1StringDedup 初始化

### F.6.1 字符串去重机制

```cpp
// src/hotspot/share/gc/g1/g1CollectedHeap.cpp:2359
G1StringDedup::initialize();
```

### F.6.2 问题与解决方案

```
问题: Java 程序中存在大量内容相同的 String 对象

String s1 = "hello";  →  s1.value = char[]{'h','e','l','l','o'}
String s2 = "hello";  →  s2.value = char[]{'h','e','l','l','o'} (重复!)

解决: 让多个 String 共享同一个底层 char[]/byte[]

去重后: s1.value = s2.value = 同一个 char[]
```

### F.6.3 核心组件

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       G1StringDedup 架构                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  1. StringDedup-Queue (候选队列)                                        │
│     ┌─────────────────────────────────────────────────────┐             │
│     │ 存储待处理的 String 候选                            │             │
│     │ GC 时发现存活 3+ 次的 String 加入队列               │             │
│     └─────────────────────────────────────────────────────┘             │
│                              │                                           │
│                              ▼                                           │
│  2. StringDedup-Thread (后台线程)                                       │
│     ┌─────────────────────────────────────────────────────┐             │
│     │ 从队列取出候选                                      │             │
│     │ 计算 char[] 的哈希值                                │             │
│     │ 在哈希表中查找                                      │             │
│     └─────────────────────────────────────────────────────┘             │
│                              │                                           │
│                              ▼                                           │
│  3. StringDedup-Table (去重哈希表)                                      │
│     ┌─────────────────────────────────────────────────────┐             │
│     │ 存储所有唯一的 char[]/byte[]                        │             │
│     │ 找到相同的 → 替换 String.value 指向已有的           │             │
│     │ 没找到 → 将当前 char[] 加入表中                     │             │
│     └─────────────────────────────────────────────────────┘             │
└─────────────────────────────────────────────────────────────────────────┘
```

### F.6.4 启用参数

```bash
# 启用字符串去重 (必须配合 G1 GC)
-XX:+UseG1GC -XX:+UseStringDeduplication

# 设置年龄阈值 (默认=3, 即 String 存活 3 次 GC 后才考虑去重)
-XX:StringDeduplicationAgeThreshold=3

# 查看去重统计日志
-Xlog:gc+stringdedup=debug
```

---

## F.7 PreservedMarksSet 初始化

### F.7.1 Evacuation Failure 场景

```cpp
// src/hotspot/share/gc/g1/g1CollectedHeap.cpp:2411
_preserved_marks_set.init(ParallelGCThreads);
```

### F.7.2 为什么需要 PreservedMarksSet？

```
Evacuation Failure 场景:
  GC 期间，复制对象到新 Region 时可能失败（内存不足）
  
问题:
  失败时，GC 需要用对象的 mark word 存储 self-forwarding pointer
  但 mark word 中可能包含需要保留的信息:
  
  64位 mark word 结构:
  ┌────────────────────────────────────────────────────────────────┐
  │ unused:25 │ hash:31 │ unused:1 │ age:4 │ biased_lock:1 │ lock:2│
  └────────────────────────────────────────────────────────────────┘
  
  需要保留:
  - identity hash code (一旦计算就不能丢失)
  - 偏向锁状态
  - 锁状态 (如果对象被锁定)

解决方案:
  PreservedMarksSet 临时保存这些 mark word，GC 结束后恢复
```

### F.7.3 数据结构

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        PreservedMarksSet                                │
├─────────────────────────────────────────────────────────────────────────┤
│  _in_c_heap: true                                                       │
│  _num: ParallelGCThreads (13)                                           │
│  _stacks: Padded<PreservedMarks>*                                       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │              _stacks[0..12]                                       │   │
│  │  ┌───────────────┐ ┌───────────────┐     ┌───────────────┐       │   │
│  │  │ Worker 0      │ │ Worker 1      │ ... │ Worker 12     │       │   │
│  │  │ PreservedMarks│ │ PreservedMarks│     │ PreservedMarks│       │   │
│  │  │  ┌─────────┐  │ │  ┌─────────┐  │     │  ┌─────────┐  │       │   │
│  │  │  │ Stack   │  │ │  │ Stack   │  │     │  │ Stack   │  │       │   │
│  │  │  │ <oop,   │  │ │  │ <oop,   │  │     │  │ <oop,   │  │       │   │
│  │  │  │  mark>  │  │ │  │  mark>  │  │     │  │  mark>  │  │       │   │
│  │  │  └─────────┘  │ │  └─────────┘  │     │  └─────────┘  │       │   │
│  │  │  padding...   │ │  padding...   │     │  padding...   │       │   │
│  │  └───────────────┘ └───────────────┘     └───────────────┘       │   │
│  │                                                                   │   │
│  │  每个 GC Worker 线程独占一个栈，避免锁竞争                        │   │
│  └──────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘

栈元素: (oop, markOop) 对
  - oop: 对象指针
  - markOop: 原始的 mark word
```

### F.7.4 工作流程

```
1. Evacuation Failure 发生:
   - 无法复制对象到新 Region
   - 需要设置 self-forwarding pointer

2. 保存 mark word:
   _preserved_marks_set.get(worker_id)->push(obj, obj->mark());

3. 设置 forwarding pointer:
   obj->set_mark(obj);  // 指向自己

4. GC 结束后恢复:
   for each (oop, mark) in stack:
     oop->set_mark(mark);  // 恢复原始 mark word
```

---

## 内存占用总结

| 组件 | 内存占用 | 说明 |
|------|----------|------|
| G1Policy | ~1KB | 策略数据和预测器 |
| SATBMarkQueueSet | ~10KB | 队列管理结构 + 缓冲区池 |
| DirtyCardQueueSet | ~10KB | 两个队列集合 |
| G1AllocRegion | ~100B | 分配管理结构 |
| G1MonitoringSupport | ~1KB | 监控计数器 |
| G1StringDedup | ~100KB | 去重哈希表（动态增长） |
| PreservedMarksSet | ~几KB | 13 个栈（Evacuation Failure 时使用） |

---

## 初始化完成后的组件关系图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           G1CollectedHeap                                    │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                         运行时组件                                   │    │
│  │                                                                      │    │
│  │  ┌────────────┐    ┌────────────────┐    ┌────────────────┐         │    │
│  │  │ G1Policy   │    │ G1Allocator    │    │ G1Monitoring   │         │    │
│  │  │            │    │                │    │ Support        │         │    │
│  │  │ - 年轻代   │    │ - Mutator      │    │                │         │    │
│  │  │   大小计算 │    │   AllocRegion  │    │ - jstat        │         │    │
│  │  │ - 暂停时间 │    │ - Survivor     │    │ - JMX          │         │    │
│  │  │   预测     │    │   GCAllocRegion│    │ - 日志         │         │    │
│  │  │ - CSet选择 │    │ - Old          │    │                │         │    │
│  │  └────────────┘    │   GCAllocRegion│    └────────────────┘         │    │
│  │                    └────────────────┘                                │    │
│  │                                                                      │    │
│  │  ┌────────────────────────────────────────────────────────┐         │    │
│  │  │                   队列系统                              │         │    │
│  │  │  ┌─────────────────┐    ┌─────────────────┐            │         │    │
│  │  │  │ SATBMarkQueueSet│    │DirtyCardQueueSet│            │         │    │
│  │  │  │                 │    │                 │            │         │    │
│  │  │  │ 写前屏障        │    │ 写后屏障        │            │         │    │
│  │  │  │ 并发标记防漏标  │    │ 跨代引用跟踪    │            │         │    │
│  │  │  │                 │    │                 │            │         │    │
│  │  │  │ 阈值: 20        │    │ Yellow: 39      │            │         │    │
│  │  │  │                 │    │ Red: 65         │            │         │    │
│  │  │  └─────────────────┘    └─────────────────┘            │         │    │
│  │  └────────────────────────────────────────────────────────┘         │    │
│  │                                                                      │    │
│  │  ┌────────────────────────────────────────────────────────┐         │    │
│  │  │                   辅助组件                              │         │    │
│  │  │  ┌─────────────────┐    ┌─────────────────┐            │         │    │
│  │  │  │ G1StringDedup   │    │PreservedMarksSet│            │         │    │
│  │  │  │                 │    │                 │            │         │    │
│  │  │  │ 字符串去重      │    │ Evacuation      │            │         │    │
│  │  │  │ (可选特性)      │    │ Failure 保护    │            │         │    │
│  │  │  └─────────────────┘    └─────────────────┘            │         │    │
│  │  └────────────────────────────────────────────────────────┘         │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 关键要点总结

| 组件 | 核心功能 | 关键参数 |
|------|----------|----------|
| G1Policy | 年轻代大小动态调整、暂停时间预测 | min=5%, max=60% |
| SATBMarkQueueSet | 写前屏障队列，并发标记防漏标 | 阈值=20 |
| DirtyCardQueueSet | 写后屏障队列，跨代引用跟踪 | Yellow=39, Red=65 |
| G1AllocRegion | 对象分配管理，Dummy Region 机制 | - |
| PreservedMarksSet | Evacuation Failure 时保存 mark word | 13 个栈 |

---

## 相关文件

- `src/hotspot/share/gc/g1/g1Policy.cpp` - G1 策略实现
- `src/hotspot/share/gc/g1/satbMarkQueue.hpp` - SATB 队列定义
- `src/hotspot/share/gc/g1/dirtyCardQueue.hpp` - 脏卡队列定义
- `src/hotspot/share/gc/g1/g1AllocRegion.hpp` - 分配区域管理
- `src/hotspot/share/gc/g1/g1StringDedup.cpp` - 字符串去重
