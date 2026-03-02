# G1CollectedHeap::initialize() 专家级深度分析

> 基于 OpenJDK 11 源码 `g1CollectedHeap.cpp` (第 1587-2471 行)
> 分析标准：`-Xms8g -Xmx8g -XX:+UseG1GC`，G1 Region = 4MB

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

`G1CollectedHeap::initialize()` 的本质是 **G1 GC 的"大爆炸"函数**：约 900 行代码，14 个阶段，从零开始建立完整的 G1 内存管理体系——预留虚拟内存、创建 6 个数据结构映射器、初始化 2048 个 Region、建立卡表/屏障集/RSet、启动并发标记和精化线程。

### 0.2 为什么需要？

JVM 启动时 G1 GC 的所有子系统都需要初始化，且有严格的依赖顺序：卡表必须在 RSet 之前创建（RSet 依赖卡表），HeapRegionManager 必须在 Region 分配之前初始化，并发标记线程必须在堆扩展之后启动（需要有实际的堆内存）。`initialize()` 按正确顺序完成所有初始化。

### 0.3 14 个阶段概览

| 阶段 | 核心操作 | 关键数据结构 |
|------|---------|------------|
| 1 环境准备 | 获取堆大小参数 | `-Xms`/`-Xmx` |
| 2 虚拟内存预留 | `mmap(PROT_NONE)` | `ReservedSpace` |
| 3 卡表和屏障集 | `new G1CardTable/G1BarrierSet` | `G1CardTable`(16MB) |
| 4 六大映射器 | 创建 6 个 `G1RegionToSpaceMapper` | BOT/CardTable/Bitmap 等 |
| 5 HeapRegionManager | `_hrm.initialize()` | 2048 个 `HeapRegion` |
| 6 G1RemSet | `new G1RemSet()` | `G1RemSet` |
| 7 快速测试数组 | `_in_cset_fast_test.initialize()` | O(1) CSet 查询 |
| 8 并发标记 | `new G1ConcurrentMark()` | 双缓冲 Bitmap(256MB) |
| 9 堆扩展 | `expand(init_byte_size)` | commit 物理内存 |
| 10 策略和队列 | SATB/DirtyCard 队列初始化 | `SATBMarkQueueSet` |
| 11 分配器 | Dummy Region + mutator alloc | `G1Allocator` |
| 12 监控和去重 | `new G1MonitoringSupport()` | JMX 支持 |
| 13 PreservedMarksSet | `_preserved_marks_set.init()` | Evacuation Failure 恢复 |
| 14 CollectionSet | `_collection_set.initialize()` | CSet 管理 |

### 0.4 为什么这样设计？

- **为什么虚拟内存预留（Phase 2）在卡表创建（Phase 3）之前？** 卡表大小 = 堆大小 / 512，必须先知道堆的虚拟地址范围才能创建卡表；Phase 2 确定了堆的地址范围
- **为什么六大映射器（Phase 4）在 HeapRegionManager（Phase 5）之前？** HeapRegionManager 的 `initialize()` 需要传入这 6 个映射器作为参数，建立 Region 与辅助数据结构的映射关系
- **为什么堆扩展（Phase 9）在并发标记（Phase 8）之后？** 并发标记线程启动时需要知道 Bitmap 的地址范围（Phase 8 创建），但不需要实际的堆内存；堆扩展（commit 物理内存）可以推迟到 Phase 9
- **为什么 Dummy Region（Phase 11）是必要的？** `G1AllocRegion` 的 `_alloc_region` 字段永不为 NULL（避免 NULL 检查），Dummy Region 作为占位符，分配时必定失败（`_top == _end`），触发申请新 Region 的逻辑

---

## 1. 整体概述

### 1.1 方法定位

`G1CollectedHeap::initialize()` 是 G1 GC 堆初始化的**核心方法**，在 JVM 启动流程中被 `Universe::initialize_heap()` 调用。

### 1.2 调用链

```
create_vm()
  └── Universe::initialize_heap()
        └── G1CollectedHeap::create_heap()
              └── G1CollectedHeap::initialize()  ← 本文档分析目标
```

### 1.3 返回值

- `JNI_OK (0)` - 初始化成功
- `JNI_ENOMEM` - 内存不足

---

## 2. 完整流程分析（自顶向下）

### 2.1 第一阶段：环境准备（第 1588-1613 行）

```cpp
1588:    os::enable_vtime();
1592:    MutexLocker x(Heap_lock);
1599:    guarantee(HeapWordSize == wordSize, ...);
1601:    size_t init_byte_size = collector_policy()->initial_heap_byte_size();  // -Xms
1602:    size_t max_byte_size = collector_policy()->max_heap_byte_size();      // -Xmx
1603:    size_t heap_alignment = collector_policy()->heap_alignment();
1606-1608:    Universe::check_alignment(...);  // 验证对齐
```

**关键动作**：
1. 启用虚拟时间统计
2. 获取 Heap_lock 互斥锁
3. 获取堆大小参数（-Xms/-Xmx）
4. 验证对齐要求

---

### 2.2 第二阶段：虚拟内存预留（第 1622-1713 行）

```cpp
1701:    ReservedSpace heap_rs = Universe::reserve_heap(max_byte_size, heap_alignment);
1713:    initialize_reserved_region(...);
```

**核心概念**：

```
┌─────────────────────────────────────────────────────────────┐
│              两阶段内存分配策略                               │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  阶段1: Reserve (预留)                                      │
│    mmap(addr, size, PROT_NONE, MAP_PRIVATE|MAP_ANONYMOUS)  │
│    • 只占用虚拟地址空间，不分配物理内存                      │
│    • 不消耗 RSS (Resident Set Size)                        │
│    • PROT_NONE = 不可读/不可写/不可执行                     │
│                                                             │
│  阶段2: Commit (提交)                                       │
│    mmap(addr, size, PROT_READ|PROT_WRITE, MAP_FIXED)       │
│    • 修改页表权限为可读写                                   │
│    • 触发 Page Fault 时才分配物理页                         │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**关键数据结构**：

| 类型 | 作用 |
|------|------|
| `MemRegion` | 轻量级内存范围描述符（仅描述，不管理生命周期）|
| `ReservedSpace` | 虚拟内存管理者（管理地址空间生命周期）|
| `G1RegionToSpaceMapper` | 物理内存管理者（管理虚拟→物理映射）|

---

### 2.3 第三阶段：卡表和屏障集创建（第 1715-1755 行）

```cpp
1724:    G1CardTable *ct = new G1CardTable(reserved_region());
1727:    ct->initialize();
1736:    G1BarrierSet *bs = new G1BarrierSet(ct);
1737:    bs->initialize();
1743:    BarrierSet::set_barrier_set(bs);
1744:    _card_table = ct;
1755:    _hot_card_cache = new G1HotCardCache(this);
```

**核心组件**：

#### G1CardTable（卡表）

| 属性 | 值 |
|------|-----|
| 粒度 | 512 字节 |
| 8GB 堆大小 | 16MB |
| 内存占比 | 0.2% |

**作用**：追踪堆内存修改，每 512 字节对应 1 字节卡表项

#### G1BarrierSet（屏障集）

| 屏障类型 | 作用 |
|---------|------|
| 写前屏障 (SATB) | 引用被覆盖前记录旧值，支持并发标记 |
| 写后屏障 | 引用被修改后标记卡表为脏，记录跨 Region 引用 |

#### G1HotCardCache（热卡缓存）

**问题背景**：
- 每次引用修改都触发写后屏障
- 热点代码修改频繁，造成重复工作

**解决方案**：
- 热卡先放入缓存
- GC 暂停时统一处理
- 避免重复劳动

---

### 2.4 第四阶段：六大数据结构映射器（第 1757-2000 行）

```cpp
1801:    G1RegionToSpaceMapper *heap_storage = ...        // 堆内存
1823:    G1RegionToSpaceMapper *bot_storage = ...         // BOT
1829:    G1RegionToSpaceMapper *cardtable_storage = ...   // 卡表
1835:    G1RegionToSpaceMapper *card_counts_storage = ... // 卡计数
1990:    G1RegionToSpaceMapper *prev_bitmap_storage = ... // 上一轮位图
1998:    G1RegionToSpaceMapper *next_bitmap_storage = ... // 当前位图
```

**六大数据结构汇总**：

| 数据结构 | 大小（8GB 堆）| 作用 |
|---------|---------------|------|
| **Heap** | 8GB | Java 堆内存 |
| **BOT** | 16MB | 块偏移表（对象定位）|
| **Card Table** | 16MB | 跨代引用标记 |
| **Card Counts** | 16MB | 热卡计数 |
| **Prev Bitmap** | 128MB | 上一轮标记位图 |
| **Next Bitmap** | 128MB | 当前标记位图 |

**总辅助内存**：304MB（约 3.7%）

**位图双缓冲机制**：

```
┌─────────────────────────────────────────────────────────────┐
│                    双缓冲位图机制                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  prev_mark_bitmap（上一轮结果，只读）                       │
│    → Mixed GC 使用，判断对象是否存活                        │
│                                                             │
│  next_mark_bitmap（当前正在标记，可写）                      │
│    → 并发标记线程，设置新的标记位                           │
│                                                             │
│  标记完成时：交换指针（O(1) 操作）                          │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

### 2.5 第五阶段：HeapRegionManager 初始化（第 2004-2005 行）

```cpp
2004:    _hrm.initialize(heap_storage, prev_bitmap_storage, next_bitmap_storage,
2005:                      bot_storage, cardtable_storage, card_counts_storage);
```

**HeapRegionManager 核心职责**：
- 管理所有 HeapRegion 生命周期
- 维护空闲 Region 列表
- 支持 Region 分配和回收

**Region 数量计算**：
```
8GB / 4MB = 2048 个 Region
```

---

### 2.6 第六阶段：G1RemSet 创建（第 2021-2031 行）

```cpp
2030:    _g1_rem_set = new G1RemSet(this, _card_table, _hot_card_cache);
2031:    _g1_rem_set->initialize(max_capacity(), max_regions());
```

**G1RemSet 核心职责**：
- 管理跨 Region 引用（RSet）
- 提供引用查询和更新
- 协调并发细化

---

### 2.7 第七阶段：快速测试数组初始化（第 2050-2136 行）

```cpp
2062-2089:    _in_cset_fast_test.initialize(start, end, granularity);
2092-2136:    _humongous_reclaim_candidates.initialize(start, end, granularity);
```

#### _in_cset_fast_test（性能优化核心）

**问题背景**：
- GC 过程中需要频繁判断对象/Region 是否在 CSet 中
- 原始方式：遍历 CSet 列表 → O(n)
- 热路径上不可接受

**解决方案**：
- 用内存换时间：O(1) 数组访问
- 每个 Region 对应 1 个字节

```
_in_cset_fast_test[index]:
  0: NotInCSet    - 不在 CSet
  1: Young        - 年轻代，在 CSet 中
  2: Old          - 老年代，在 CSet 中
 -1: Humongous    - 巨型对象
```

**使用场景**：
- write barrier 判断对象是否在 CSet
- 对象拷贝时快速定位目标 Region

#### _humongous_reclaim_candidates

**作用**：标记可回收的巨型对象 Region

**什么是 Humongous 对象**？
- 对象大小 ≥ Region 大小的 50%
- 在 G1 中可能跨越多个 Region

**快速回收条件**：
1. 必须是纯数据类型数组（byte[]、int[]）
2. 记忆集足够小

---

### 2.8 第八阶段：并发标记初始化（第 2139-2196 行）

```cpp
2191:    _cm = new G1ConcurrentMark(this, prev_bitmap_storage, next_bitmap_storage);
2196:    _cm_thread = _cm->cm_thread();
```

**G1ConcurrentMark 核心职责**：

| 阶段 | 类型 | 说明 |
|------|------|------|
| Initial Mark | STW | 标记 GC Roots，搭便车在 Young GC 上 |
| Root Region Scan | 并发 | 扫描 Survivor 区 |
| Concurrent Mark | 并发 | 遍历对象图，标记存活对象 |
| Remark | STW | 处理 SATB 队列，完成标记 |
| Cleanup | STW | 统计存活率，准备 Mixed GC |

---

### 2.9 第九阶段：堆扩展（第 2198-2210 行）

```cpp
2207:    if (!expand(init_byte_size, _workers)) {
2208:        vm_shutdown_during_initialization("Failed to allocate initial heap.");
2209:        return JNI_ENOMEM;
2210:    }
```

**expand() 核心动作**：

```
1. 将预留的虚拟地址空间转换为已提交的物理内存
2. 创建 HeapRegion 对象并初始化
3. 提交所有辅助数据结构的内存
4. 将 Region 加入空闲列表
```

---

### 2.10 第十阶段：策略和队列初始化（第 2212-2273 行）

```cpp
2217:    g1_policy()->init(this, &_collection_set);
2233-2236:    G1BarrierSet::satb_mark_queue_set().initialize(...);
2238:    initialize_concurrent_refinement();
2243:    initialize_young_gen_sampling_thread();
2255-2261:    G1BarrierSet::dirty_card_queue_set().initialize(...);
2268-2273:    dirty_card_queue_set().initialize(...);
```

**SATB 队列**：
- 作用：记录并发标记期间的引用变更
- 阈值：20 个缓冲区触发处理

**并发细化线程**：
- 作用：处理 Dirty Card Queue，更新 RSet
- 三色区域：Green(13)/Yellow(39)/Red(65)

---

### 2.11 第十一阶段：分配器初始化（第 2275-2323 行）

```cpp
2278:    HeapRegion *dummy_region = _hrm.get_dummy_region();
2289:    dummy_region->set_eden();
2291:    dummy_region->set_top(dummy_region->end());
2310:    G1AllocRegion::setup(this, dummy_region);
2323:    _allocator->init_mutator_alloc_region();
```

**Dummy Region 作用**：
- 作为占位符，避免 NULL 检查
- 没有可用 Region 时，分配必定失败
- 简化代码，分支预测优化

---

### 2.12 第十二阶段：监控和字符串去重初始化（第 2327-2359 行）

```cpp
2334:    _g1mm = new G1MonitoringSupport(this);
2359:    G1StringDedup::initialize();
```

**G1MonitoringSupport**：
- 为 jstat、JMX 提供监控数据
- 将 Region 模型转换为传统分代模型

**G1StringDedup**：
- 字符串去重（需配合 `-XX:+UseStringDeduplication`）
- 默认年龄阈值 = 3

---

### 2.13 第十三阶段：PreservedMarksSet 初始化（第 2361-2411 行）

```cpp
2411:    _preserved_marks_set.init(ParallelGCThreads);
```

**作用**：在 Evacuation Failure 时保存对象原始 mark word

**场景**：
- 对象复制失败时，使用 mark word 存储转发指针
- 需要保存原始信息（hash code、偏向锁状态等）
- GC 结束后恢复

---

### 2.14 第十四阶段：CollectionSet 初始化（第 2413-2443 行）

```cpp
2442:    _collection_set.initialize(max_regions());
2444:    return JNI_OK;
```

**CollectionSet 核心职责**：
- 管理本次 GC 需要回收的 Region 集合
- 增量构建机制

---

## 3. 完整流程图

```
G1CollectedHeap::initialize()
│
├─[Phase 1] 环境准备
│  ├─ os::enable_vtime()
│  ├─ MutexLocker(Heap_lock)
│  └─ 获取堆大小参数(-Xms/-Xmx)
│
├─[Phase 2] 虚拟内存预留
│  ├─ Universe::reserve_heap() → ReservedSpace
│  └─ initialize_reserved_region() → MemRegion
│
├─[Phase 3] 卡表和屏障集
│  ├─ new G1CardTable()
│  ├─ new G1BarrierSet()
│  └─ new G1HotCardCache()
│
├─[Phase 4] 六大数据结构映射器
│  ├─ heap_storage (8GB)
│  ├─ bot_storage (16MB)
│  ├─ cardtable_storage (16MB)
│  ├─ card_counts_storage (16MB)
│  ├─ prev_bitmap_storage (128MB)
│  └─ next_bitmap_storage (128MB)
│
├─[Phase 5] HeapRegionManager 初始化
│  └─ _hrm.initialize(...) → 2048 个 Region
│
├─[Phase 6] G1RemSet 创建
│  └─ new G1RemSet() + initialize()
│
├─[Phase 7] 快速测试数组
│  ├─ _in_cset_fast_test (O(1) CSet 查询)
│  └─ _humongous_reclaim_candidates
│
├─[Phase 8] 并发标记初始化
│  ├─ new G1ConcurrentMark()
│  └─ _cm_thread = _cm->cm_thread()
│
├─[Phase 9] 堆扩展
│  └─ expand(init_byte_size, _workers)
│
├─[Phase 10] 策略和队列
│  ├─ g1_policy()->init()
│  ├─ SATB 队列初始化
│  ├─ 并发细化线程
│  ├─ 采样线程
│  └─ Dirty Card 队列
│
├─[Phase 11] 分配器
│  ├─ 创建 Dummy Region
│  └─ _allocator->init_mutator_alloc_region()
│
├─[Phase 12] 监控和字符串去重
│  ├─ new G1MonitoringSupport()
│  └─ G1StringDedup::initialize()
│
├─[Phase 13] PreservedMarksSet
│  └─ _preserved_marks_set.init()
│
└─[Phase 14] CollectionSet
   └─ _collection_set.initialize()
      │
      ▼
   return JNI_OK
```

---

## 4. 内存布局总结

### 4.1 堆内存布局（8GB）

```
┌─────────────────────────────────────────────────────────────┐
│                    G1 堆内存布局 (8GB)                      │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Java Heap      │ 8GB  (2048 × 4MB Regions)               │
│                                                             │
│  ───────────────┼─────────────────────────────────────────  │
│                                                             │
│  辅助数据结构  │  大小      │  占比    │  说明             │
│  ───────────────┼────────────┼──────────┼────────────────  │
│  BOT            │  16MB     │  0.19%   │  块偏移表         │
│  Card Table     │  16MB     │  0.19%   │  卡表             │
│  Card Counts    │  16MB     │  0.19%   │  热卡缓存         │
│  Prev Bitmap    │  128MB    │  1.56%   │  标记位图         │
│  Next Bitmap    │  128MB    │  1.56%   │  标记位图         │
│  ───────────────┼────────────┼──────────┼────────────────  │
│  总计           │  304MB    │  3.70%   │                   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Region 结构

```
┌─────────────────────────────────────────────────────────────┐
│                    单个 HeapRegion (4MB)                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  _bottom ──► ┌──────────────────────────┐                 │
│               │    对象数据              │                 │
│               │    (可用空间)            │                 │
│               │                          │                 │
│  _top ───────►│──────────────────────────│                 │
│               │    未使用                │                 │
│               │                          │                 │
│  _end ───────►└──────────────────────────┘                 │
│                                                             │
│  ┌───────────────────────────────────────────┐             │
│  │  RSet (Per Region)                        │             │
│  │  - SparsePRT (可选)                       │             │
│  │  - FineGrain (可选)                       │             │
│  │  - CoarseGrain (可选)                    │             │
│  └───────────────────────────────────────────┘             │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 5. GDB 验证

### 5.1 验证命令

```gdb
# 断点在 initialize 完成后
break G1CollectedHeap::initialize
commands
    next 500  # 执行到方法结束
    print this
    print _hrm._length
    print _card_table
    print _g1_rem_set
    print _cm
    continue
end

# 验证堆地址
(gdb) p g1h->_hrm.reserved().start()
(gdb) p g1h->_hrm.reserved().end()

# 验证 Region 数量
(gdb) p g1h->_hrm._length
# 预期: 2048

# 验证卡表
(gdb) p g1h->_card_table
(gdb) p g1h->_card_table->_byte_map
(gdb) p g1h->_card_table->_byte_map_base

# 验证位图
(gdb) p g1h->_cm->_prev_bitmap_map
(gdb) p g1h->_cm->_next_bitmap_map
```

### 5.2 JVM 日志验证

```bash
# 启动参数
-Xms8g -Xmx8g -XX:+UseG1GC -Xlog:gc*=debug

# 预期输出
# [debug] G1CollectedHeap::initialize
#   Heap reserved: 0x0000000600000000 - 0x0000000680000000 (8589934592)
#   Region size: 4194304 bytes
#   Number of regions: 2048
```

---

## 6. JVM 参数

| 参数 | 默认值 | 作用 |
|------|--------|------|
| `-XX:+UseG1GC` | - | 启用 G1 GC |
| `-Xms` | 物理内存/64 | 初始堆大小 |
| `-Xmx` | 物理内存/4 | 最大堆大小 |
| `-XX:G1HeapRegionSize` | 自动 | Region 大小 |
| `-XX:MaxGCPauseMillis` | 200 | 目标停顿时间 |
| `-XX:InitiatingHeapOccupancyPercent` | 45 | IHOP 阈值 |
| `-XX:+UseStringDeduplication` | false | 字符串去重 |

---

## 7. 面试价值

| 问题 | 答案要点 |
|------|----------|
| G1CollectedHeap::initialize() 主要做了什么？ | 建立完整的 G1 内存管理体系，包括虚拟内存预留、六大数据结构映射器、2048 个 Region 初始化、卡表/屏障集/记忆集创建 |
| 为什么 Java 堆不在 C 堆中？ | 通过 mmap 直接映射，支持大内存管理、独立生命周期、压缩指针优化 |
| 什么是双缓冲位图？ | Prev Bitmap（上一轮结果，只读）+ Next Bitmap（当前标记，可写），标记完成后交换指针 |
| _in_cset_fast_test 是什么？ | 将 CSet 遍历 O(n) 优化为 O(1) 数组访问，G1 性能优化核心 |
| 延迟更新 RSet 是什么？ | 写屏障仅标记脏卡入队，GC 后期批量处理，性能提升 ~100 倍 |
| Dummy Region 有什么用？ | 避免 NULL 检查，_alloc_region 永不为空，简化代码 |

---

## 8. 总结

`G1CollectedHeap::initialize()` 方法是 G1 GC 初始化的核心，共约 900 行代码，完成以下任务：

1. **虚拟内存预留**：mmap 预留 8GB 虚拟地址空间
2. **六大数据结构**：创建 Heap、BOT、Card Table、Card Counts、Prev/Next Bitmap 映射器
3. **2048 个 Region**：初始化 HeapRegionManager
4. **卡表和屏障集**：G1CardTable + G1BarrierSet
5. **并发标记**：G1ConcurrentMark + G1ConcurrentMarkThread
6. **引用处理**：SATB 队列 + Dirty Card 队列
7. **性能优化**：_in_cset_fast_test + 热卡缓存
8. **监控支持**：G1MonitoringSupport

总辅助内存约 304MB（3.7%），这是一个精心设计trade-off。
