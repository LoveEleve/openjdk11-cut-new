# G1CollectedHeap::initialize() 完整分析

> 基于 OpenJDK 11 源码分析  
> 文件位置: `src/hotspot/share/gc/g1/g1CollectedHeap.cpp:1587`

---

## 一、方法概览

### 1.1 方法签名
```cpp
jint G1CollectedHeap::initialize()
```

### 1.2 核心职责
这是 **G1 GC 启动的核心入口**，负责：
1. 预留和提交堆内存
2. 创建所有辅助数据结构
3. 初始化 6 个 G1RegionToSpaceMapper（映射器）
4. 初始化 HeapRegionManager
5. 初始化并发标记系统
6. 创建初始 Region 并分配

### 1.3 调用关系
```
Universe::initialize_heap()
    └── CollectedHeap::allocate_collected_heap()  // 创建 G1CollectedHeap 对象
        └── G1CollectedHeap::initialize()         // 本方法（真正干活）
```

---

## 二、初始化流程详解

### Phase 1: 堆内存预留 (行 1587-1713)

```cpp
// 1. 获取堆大小参数
size_t init_byte_size = collector_policy()->initial_heap_byte_size();  // -Xms
size_t max_byte_size  = collector_policy()->max_heap_byte_size();      // -Xmx
size_t heap_alignment = collector_policy()->heap_alignment();

// 2. 对齐检查
Universe::check_alignment(max_byte_size, HeapRegion::GrainBytes, "g1 heap");

// 3. 通过 mmap 预留虚拟地址空间
ReservedSpace heap_rs = Universe::reserve_heap(max_byte_size, heap_alignment);

// 4. 保存到 _reserved (MemRegion)
initialize_reserved_region((HeapWord*)heap_rs.base(), 
                           (HeapWord*)(heap_rs.base() + heap_rs.size()));
```

**关键知识点：**
- Java 堆位于 **mmap 映射区**，不在 C 堆中
- 使用 `mmap(..., PROT_NONE, ...)` 先预留地址空间，不分配物理内存
- ReservedSpace 管理虚拟地址空间生命周期

---

### Phase 2: 卡表和屏障集 (行 1715-1744)

```cpp
// 1. 创建 G1 卡表
G1CardTable *ct = new G1CardTable(reserved_region());
ct->initialize();

// 2. 创建 G1 屏障集
G1BarrierSet *bs = new G1BarrierSet(ct);
bs->initialize();
BarrierSet::set_barrier_set(bs);  // 设置全局屏障集
_card_table = ct;
```

**卡表作用：**
- 每 512 字节堆内存对应 1 字节卡表项
- 8GB 堆 = 16MB 卡表
- 记录哪些内存区域被修改过（脏卡）

**屏障类型：**
- 写前屏障（pre-write）：记录旧值到 SATB 队列
- 写后屏障（post-write）：标记卡表为脏

---

### Phase 3: 热卡缓存 (行 1746-1755)

```cpp
_hot_card_cache = new G1HotCardCache(this);
```

**解决的问题：**
- 某些卡被频繁修改（热点代码中的对象）
- 每次修改都立即处理会造成重复工作
- 热卡缓存先放入缓存，GC 暂停时再统一处理

---

### Phase 4: 创建 6 个内存映射器 (行 1757-1999)

这是 G1 堆初始化的核心，创建了 6 个 `G1RegionToSpaceMapper`：

| # | 映射器名称 | 大小 (8GB堆) | 用途 |
|---|-----------|-------------|------|
| 1 | `heap_storage` | 8GB | 堆内存本身 |
| 2 | `bot_storage` | 16MB | Block Offset Table |
| 3 | `cardtable_storage` | 16MB | 卡表 |
| 4 | `card_counts_storage` | 16MB | 热卡计数表 |
| 5 | `prev_bitmap_storage` | 128MB | 上一轮标记位图 |
| 6 | `next_bitmap_storage` | 128MB | 当前标记位图 |

```cpp
// 1. 堆存储映射器（使用已有的 ReservedSpace）
G1RegionToSpaceMapper *heap_storage =
    G1RegionToSpaceMapper::create_mapper(g1_rs, g1_rs.size(), page_size,
                                         HeapRegion::GrainBytes, 1, mtJavaHeap);

// 2-4. 辅助存储映射器（创建新的 ReservedSpace）
G1RegionToSpaceMapper *bot_storage = 
    create_aux_memory_mapper("Block Offset Table", ...);
G1RegionToSpaceMapper *cardtable_storage = 
    create_aux_memory_mapper("Card Table", ...);
G1RegionToSpaceMapper *card_counts_storage = 
    create_aux_memory_mapper("Card Counts Table", ...);

// 5-6. 并发标记位图（双缓冲机制）
G1RegionToSpaceMapper *prev_bitmap_storage = 
    create_aux_memory_mapper("Prev Bitmap", bitmap_size, ...);
G1RegionToSpaceMapper *next_bitmap_storage = 
    create_aux_memory_mapper("Next Bitmap", bitmap_size, ...);
```

**双缓冲位图机制：**
- `prev_bitmap`：上一轮完成的标记结果（Mixed GC 使用，只读）
- `next_bitmap`：当前正在进行的标记（并发标记线程写入）
- 标记周期完成时交换指针：O(1) 操作

---

### Phase 5: 初始化 HeapRegionManager (行 2001-2005)

```cpp
_hrm.initialize(heap_storage, prev_bitmap_storage, next_bitmap_storage,
                bot_storage, cardtable_storage, card_counts_storage);
```

**HeapRegionManager 职责：**
- 管理所有 G1 Region（8GB 堆 = 2048 个 Region）
- 维护空闲 Region 列表
- 协调 6 个映射器的内存分配

---

### Phase 6: 初始化辅助数据结构 (行 2007-2143)

```cpp
// 1. 卡表初始化
_card_table->initialize(cardtable_storage);

// 2. 热卡缓存初始化
_hot_card_cache->initialize(card_counts_storage);

// 3. 创建 G1RemSet（记忆集）
_g1_rem_set = new G1RemSet(this, _card_table, _hot_card_cache);
_g1_rem_set->initialize(max_capacity(), max_regions());

// 4. 创建 G1BlockOffsetTable
_bot = new G1BlockOffsetTable(reserved_region(), bot_storage);

// 5. 初始化 _in_cset_fast_test（O(1) 判断 Region 是否在 CSet 中）
_in_cset_fast_test.initialize(start, end, granularity);

// 6. 初始化巨型对象回收候选数组
_humongous_reclaim_candidates.initialize(start, end, granularity);

// 7. 创建 G1ConcurrentMark（并发标记）
_cm = new G1ConcurrentMark(this, prev_bitmap_storage, next_bitmap_storage);
_cm_thread = _cm->cm_thread();
```

**_in_cset_fast_test 作用：**
- 问题：判断对象是否在 Collection Set 中需要遍历，O(n) 太慢
- 解决：创建长度为 Region 数量的数组（2048）
- 给对象地址 addr，计算 index = (addr - heap_start) >> 22
- 直接访问数组：O(1) 判断

---

### Phase 7: 扩展初始堆 (行 2198-2210)

```cpp
// 提交初始堆大小（-Xms）的物理内存
// 创建 HeapRegion 对象并初始化
if (!expand(init_byte_size, _workers)) {
    vm_shutdown_during_initialization("Failed to allocate initial heap.");
    return JNI_ENOMEM;
}
```

**expand() 方法做的事情：**
1. 提交虚拟地址空间的物理内存（mmap PROT_READ|PROT_WRITE）
2. 创建 HeapRegion 对象（2048 个）
3. 初始化每个 Region 的元数据
4. 将 Region 加入空闲列表

---

### Phase 8: G1 策略初始化 (行 2212-2217)

```cpp
g1_policy()->init(this, &_collection_set);
```

**G1Policy::init() 做的事情：**
- 设置年轻代大小边界
- 启动收集集合的增量构建机制
- 此时 2048 个 Region 已创建完成，都在 `_free_list` 中

---

## 三、内存布局总览

```
┌─────────────────────────────────────────────────────────────────────┐
│                          G1 堆内存布局 (8GB)                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Heap Storage (8GB)                                          │   │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐     ┌─────────┐       │   │
│  │  │ Region  │ │ Region  │ │ Region  │ ... │ Region  │       │   │
│  │  │    0    │ │    1    │ │    2    │     │  2047   │       │   │
│  │  │ (4MB)   │ │ (4MB)   │ │ (4MB)   │     │ (4MB)   │       │   │
│  │  └─────────┘ └─────────┘ └─────────┘     └─────────┘       │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  BOT Storage (16MB)              每512字节堆对应1字节BOT      │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Card Table (16MB)               每512字节堆对应1字节卡表     │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Card Counts (16MB)              热卡缓存计数表               │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Prev Bitmap (128MB)             上一轮标记结果              │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Next Bitmap (128MB)             当前标记位图                │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  总计: 8GB + 16MB + 16MB + 16MB + 128MB + 128MB ≈ 8.3GB            │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 四、关键数据结构关系

```
G1CollectedHeap
├── _hrm (HeapRegionManager)
│   ├── heap_storage ──────┐
│   ├── bot_storage ───────┤
│   ├── cardtable_storage ─┤
│   ├── card_counts_storage┤  6个 G1RegionToSpaceMapper
│   ├── prev_bitmap_storage┤
│   └── next_bitmap_storage┘
│
├── _card_table (G1CardTable) ← 使用 cardtable_storage
├── _bot (G1BlockOffsetTable) ← 使用 bot_storage
├── _hot_card_cache (G1HotCardCache) ← 使用 card_counts_storage
├── _g1_rem_set (G1RemSet)
├── _cm (G1ConcurrentMark) ← 使用 prev/next_bitmap_storage
├── _in_cset_fast_test (G1InCSetStateFastTestBiasedMappedArray)
└── _humongous_reclaim_candidates (HumongousReclaimCandidates)
```

---

## 五、G1 GC 阶段流转

```
═══════════════════════════════════════════════════════════════════════
                        Young-Only Phase
═══════════════════════════════════════════════════════════════════════
  │
  ├── [Young GC] ──→ Normal (只回收年轻代)
  │
  ├── [Young GC] ──→ Normal
  │
  │  老年代占用逐渐增加...
  │  当老年代占用 > IHOP 阈值 (默认 45%)：
  │     ↓
  ├── [Young GC + Initial Mark] ──→ 并发标记开始
  │     ↓
  ════════════════════════════════════════════════════════════════════
                      Concurrent Marking
  ════════════════════════════════════════════════════════════════════
  │
  ├── Scan Root Regions (并发)
  ├── Concurrent Mark (并发) ← G1ConcurrentMark 工作
  ├── Remark (STW)
  └── Cleanup (STW)
  │     ↓
  ════════════════════════════════════════════════════════════════════
  │
  ├── [Young GC] ──→ Prepare Mixed (最后一次 Young GC)
  │     ↓
═══════════════════════════════════════════════════════════════════════
                    Space Reclamation Phase
═══════════════════════════════════════════════════════════════════════
  │
  ├── [Mixed GC] ──→ 回收年轻代 + 部分老年代
  ├── [Mixed GC] ──→ 回收年轻代 + 部分老年代
  │
  │  当可回收空间 < 阈值 (默认 5%)：
  │     ↓
  ════════════════════════════════════════════════════════════════════
  │
  └── 回到 Young-Only Phase
      (循环往复...)
```

---

## 六、总结

### initialize() 方法完成了：

1. **内存预留**：通过 mmap 预留 8GB 虚拟地址空间
2. **6 个映射器**：创建堆内存和所有辅助数据结构的映射器
3. **HeapRegionManager**：初始化，准备管理 2048 个 Region
4. **辅助结构**：卡表、BOT、热卡缓存、记忆集、位图
5. **并发标记**：创建 G1ConcurrentMark 对象
6. **初始扩展**：提交初始堆大小，创建 HeapRegion 对象
7. **策略初始化**：G1Policy 初始化，准备 GC 决策

### 标准环境内存占用：

| 组件 | 大小 (8GB 堆) |
|------|--------------|
| Java 堆 | 8GB |
| BOT | 16MB |
| Card Table | 16MB |
| Card Counts | 16MB |
| Prev Bitmap | 128MB |
| Next Bitmap | 128MB |
| **总计** | **~8.3GB** |

---

## 七、下一步学习建议

1. **expand() 方法**：了解如何创建 HeapRegion 对象
2. **G1Policy::init()**：了解 G1 策略如何决策
3. **Young GC 流程**：从 `VM_G1CollectForAllocation` 开始
4. **Mixed GC 流程**：结合位图和回收候选

---

> 分析完成！如需深入某个子方法，告诉我！
