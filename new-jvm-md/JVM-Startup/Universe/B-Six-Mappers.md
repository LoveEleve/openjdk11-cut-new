# B. 6 个 G1RegionToSpaceMapper 详解

> 理解 G1 内存管理的关键：堆内存 + 5 个辅助数据结构

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **B. 6 个 G1RegionToSpaceMapper 详解**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 1. 整体概览

G1 在 `initialize()` 中创建 **6 个 G1RegionToSpaceMapper**，用于管理堆内存和辅助数据结构：

| 编号 | 名称 | 大小 (8GB堆) | 映射比例 | 用途 |
|------|------|-------------|----------|------|
| B.1 | heap_storage | 8GB | 1:1 | Java 堆本身 |
| B.2 | bot_storage | 16MB | 512B → 1B | 块偏移表 |
| B.3 | cardtable_storage | 16MB | 512B → 1B | 卡表 |
| B.4 | card_counts_storage | 16MB | 512B → 1B | 热卡计数 |
| B.5 | prev_bitmap_storage | 128MB | 64B → 1bit | 上轮标记位图 |
| B.6 | next_bitmap_storage | 128MB | 64B → 1bit | 本轮标记位图 |
| | **总计** | **8.3GB** | | |

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          G1 内存布局（8GB 堆）                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                        Java 堆 (8GB)                                   │ │
│  │    0x600000000                                          0x800000000    │ │
│  │    ├──────┬──────┬──────┬────────────────────────────┬──────┤          │ │
│  │    │ R[0] │ R[1] │ R[2] │    ... 2048 Regions ...   │R[2047│          │ │
│  │    │ 4MB  │ 4MB  │ 4MB  │                           │ 4MB  │          │ │
│  │    └──────┴──────┴──────┴────────────────────────────┴──────┘          │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              ↓ 每 512B 堆 → 1B                               │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                       │
│  │ BOT (16MB)   │  │CardTable(16MB│  │CardCounts    │                       │
│  │              │  │              │  │   (16MB)     │                       │
│  └──────────────┘  └──────────────┘  └──────────────┘                       │
│                              ↓ 每 64B 堆 → 1bit                              │
│  ┌────────────────────────┐  ┌────────────────────────┐                     │
│  │ Prev Bitmap (128MB)    │  │ Next Bitmap (128MB)    │                     │
│  └────────────────────────┘  └────────────────────────┘                     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 映射因子（heap_map_factor）详解

每个辅助结构都有一个**映射因子**，表示"多少字节堆内存对应 1 单位辅助结构"：

```cpp
// 1. BOT: 每 512 字节堆 → 1 字节 BOT
// blockOffsetTable.hpp:54
static const uint N_bytes = 1 << 9;  // 512
static size_t heap_map_factor() { return BOTConstants::N_bytes; }  // 512

// 2. CardTable: 每 512 字节堆 → 1 字节卡表
// cardTable.hpp:235
enum { card_size = 1 << 9 };  // 512
static size_t heap_map_factor() { return card_size; }  // 512

// 3. CardCounts: 与 CardTable 相同
// g1CardCounts.cpp:46
size_t G1CardCounts::heap_map_factor() {
    return G1CardTable::heap_map_factor();  // 512
}

// 4. Bitmap: 每 64 字节堆 → 1 bit
// g1ConcurrentMarkBitMap.cpp:42
size_t G1CMBitMap::mark_distance() {
    return MinObjAlignmentInBytes * BitsPerByte;  // 8 * 8 = 64
}
static size_t heap_map_factor() { return mark_distance(); }  // 64
```

### 大小计算公式

```
辅助结构大小 = 堆大小 / 映射因子

BOT:        8GB / 512B = 16MB
CardTable:  8GB / 512B = 16MB  
CardCounts: 8GB / 512B = 16MB
Bitmap:     8GB / 64B / 8bit = 128MB (每个)
```

---

## 3. 各映射器详解

### B.1 heap_storage - 堆内存映射器

```cpp
// g1CollectedHeap.cpp:1801
G1RegionToSpaceMapper* heap_storage =
    G1RegionToSpaceMapper::create_mapper(
        g1_rs,                    // 预留的虚拟地址空间
        g1_rs.size(),             // 8GB
        page_size,                // 4KB
        HeapRegion::GrainBytes,   // 4MB (Region 大小)
        1,                        // commit_factor = 1
        mtJavaHeap);              // NMT 内存类型

heap_storage->set_mapping_changed_listener(&_listener);
```

**特点**：
- 这是唯一使用 `create_mapper()` 直接创建的映射器
- 其他 5 个都使用 `create_aux_memory_mapper()` 创建
- commit_factor = 1，表示 1:1 映射

### B.2 bot_storage - 块偏移表

```cpp
// g1CollectedHeap.cpp:1823
G1RegionToSpaceMapper* bot_storage =
    create_aux_memory_mapper(
        "Block Offset Table",
        G1BlockOffsetTable::compute_size(g1_rs.size() / HeapWordSize),  // 16MB
        G1BlockOffsetTable::heap_map_factor());  // 512
```

**BOT 的作用**：
```
问题：给定堆中任意地址，如何快速找到包含它的对象的起始位置？

解决：BOT 记录每个 512 字节块的偏移信息
      通过查表 + 回溯，O(1) 时间找到对象起始

示例：
┌─────────────────────────────────────────────────────────┐
│ 堆内存（每格 512B）                                      │
│ ┌────┬────┬────┬────┬────┬────┬────┬────┐              │
│ │ 0  │ 1  │ 2  │ 3  │ 4  │ 5  │ 6  │ 7  │              │
│ └────┴────┴────┴────┴────┴────┴────┴────┘              │
│   ↑         ↑                   ↑                       │
│ obj_start  块1                块5(查询点)                │
│                                                          │
│ BOT[5] = 5  →  "往前回溯 5 个块找到对象起始"             │
└─────────────────────────────────────────────────────────┘
```

**GC 用途**：
- 扫描卡表时，需要找到跨越卡边界的对象
- 疏散时快速定位 Region 内对象

### B.3 cardtable_storage - 卡表

```cpp
// g1CollectedHeap.cpp:1829
G1RegionToSpaceMapper* cardtable_storage =
    create_aux_memory_mapper(
        "Card Table",
        G1CardTable::compute_size(g1_rs.size() / HeapWordSize),  // 16MB
        G1CardTable::heap_map_factor());  // 512
```

**卡表的作用**：
```
问题：老年代对象引用年轻代对象，Minor GC 如何避免全堆扫描？

解决：写屏障 + 卡表
      修改引用时，标记对应的卡为 dirty
      Minor GC 只扫描 dirty 卡

卡值含义：
┌──────────────────────────────────────────────────────────┐
│ 卡值              │ 含义                                  │
├───────────────────┼───────────────────────────────────────┤
│ 0x00 (clean)      │ 干净，无需扫描                        │
│ 0x01 (dirty)      │ 脏，有跨 Region 引用，需要扫描        │
│ 0x02 (young)      │ 年轻代卡，不需要扫描                  │
│ 0x80 (deferred)   │ 延迟处理                              │
└──────────────────────────────────────────────────────────┘
```

**示意图**：
```
┌────────────────────────────────────────────────────────────┐
│                        堆内存                               │
│  Old Region            │    Young Region                   │
│  ┌──────────────┐      │    ┌──────────────┐              │
│  │ ObjA ──────────────────→ │ ObjB         │              │
│  │     (写引用)  │      │    │              │              │
│  └──────────────┘      │    └──────────────┘              │
│         ↓               │                                   │
│  CardTable[idx] = dirty │                                   │
└────────────────────────────────────────────────────────────┘

写屏障伪代码：
void store_ref(Object* obj, Object** field, Object* value) {
    *field = value;  // 实际写入
    
    // 写后屏障：标记卡为脏
    size_t card_idx = ((uintptr_t)field) >> 9;  // 除以 512
    card_table[card_idx] = DIRTY;
}
```

### B.4 card_counts_storage - 热卡计数

```cpp
// g1CollectedHeap.cpp:1835
G1RegionToSpaceMapper* card_counts_storage =
    create_aux_memory_mapper(
        "Card Counts Table",
        G1CardCounts::compute_size(g1_rs.size() / HeapWordSize),  // 16MB
        G1CardCounts::heap_map_factor());  // 512
```

**热卡优化**：
```
问题：某些卡被频繁修改（热卡），每次都处理很浪费

解决：记录每张卡的修改次数
      超过阈值的热卡，延迟到 GC 暂停时处理
      避免并发精炼线程反复处理同一张卡

示例：
┌────────────────────────────────────────────────────────────┐
│ CardCounts[idx]                                             │
│                                                             │
│ 0  →  1  →  2  →  3  →  ... →  G1HotCardCountThreshold(4)  │
│                                          ↓                  │
│                                    加入 HotCardCache        │
│                                    延迟处理                 │
└────────────────────────────────────────────────────────────┘
```

### B.5 & B.6 prev/next_bitmap_storage - 双缓冲标记位图

```cpp
// g1CollectedHeap.cpp:1845
size_t bitmap_size = G1CMBitMap::compute_size(g1_rs.size());  // 128MB

// g1CollectedHeap.cpp:1991
G1RegionToSpaceMapper* prev_bitmap_storage =
    create_aux_memory_mapper("Prev Bitmap", bitmap_size, 
                             G1CMBitMap::heap_map_factor());  // 64

G1RegionToSpaceMapper* next_bitmap_storage =
    create_aux_memory_mapper("Next Bitmap", bitmap_size,
                             G1CMBitMap::heap_map_factor());  // 64
```

**双缓冲的必要性**：
```
问题：并发标记 + Mixed GC 同时进行，如何避免冲突？

场景：
- Mixed GC 需要【读取】上一轮完成的标记结果
- 并发标记需要【写入】当前正在进行的标记

解决：双缓冲
- prev_bitmap：上轮结果（只读），Mixed GC 使用
- next_bitmap：本轮标记（可写），并发标记线程使用

标记周期完成时：
    swap(prev_bitmap, next_bitmap);  // O(1) 指针交换
```

**位图结构**：
```
┌────────────────────────────────────────────────────────────┐
│ 位图映射（每 64 字节堆 → 1 bit）                            │
│                                                             │
│ 堆内存：                                                    │
│ ┌────┬────┬────┬────┬────┬────┬────┬────┐                  │
│ │64B │64B │64B │64B │64B │64B │64B │64B │                  │
│ └────┴────┴────┴────┴────┴────┴────┴────┘                  │
│   ↓    ↓    ↓    ↓    ↓    ↓    ↓    ↓                     │
│ 位图：                                                      │
│ ┌──┬──┬──┬──┬──┬──┬──┬──┐                                  │
│ │ 1│ 0│ 1│ 0│ 0│ 1│ 0│ 1│  (1=对象起始, 0=无对象)          │
│ └──┴──┴──┴──┴──┴──┴──┴──┘                                  │
│                                                             │
│ 为什么是 64B？                                              │
│ MinObjAlignmentInBytes = 8B (最小对象对齐)                  │
│ BitsPerByte = 8                                             │
│ mark_distance = 8 * 8 = 64B                                 │
└────────────────────────────────────────────────────────────┘
```

---

## 4. create_aux_memory_mapper() 实现

```cpp
// g1CollectedHeap.cpp:1538
G1RegionToSpaceMapper* G1CollectedHeap::create_aux_memory_mapper(
    const char* description,
    size_t size,              // 辅助结构大小
    size_t translation_factor // 映射因子
) {
    // 1. 选择页大小（通常 4KB）
    size_t preferred_page_size = os::page_size_for_region_unaligned(size, 1);
    
    // 2. 创建独立的 ReservedSpace（与堆分离）
    ReservedSpace rs(size, preferred_page_size);
    
    // 3. 创建映射器
    G1RegionToSpaceMapper* result =
        G1RegionToSpaceMapper::create_mapper(
            rs,
            size,
            rs.alignment(),
            HeapRegion::GrainBytes,      // 4MB
            translation_factor,          // 512 或 64
            mtGC);
    
    return result;
}
```

**关键区别**：
| | heap_storage | 辅助结构 |
|---|---|---|
| 创建方式 | 直接 create_mapper | create_aux_memory_mapper |
| ReservedSpace | 共享 g1_rs | 独立 new ReservedSpace |
| commit_factor | 1 | translation_factor |
| 内存类型 | mtJavaHeap | mtGC |

---

## 5. G1RegionToSpaceMapper 类层次

```cpp
// g1RegionToSpaceMapper.cpp
class G1RegionToSpaceMapper {
protected:
    G1PageBasedVirtualSpace _storage;  // 底层虚拟内存
    size_t _region_granularity;        // Region 粒度（4MB）
    MappingChangedListener* _listener; // 变更监听器
    CHeapBitMap _commit_map;           // 提交状态位图
    
public:
    virtual void commit_regions(uint start, size_t count, WorkGang* gang) = 0;
    virtual void uncommit_regions(uint start, size_t count) = 0;
};

// 子类：Region >= Page（常见情况：4MB Region, 4KB Page）
class G1RegionsLargerThanCommitSizeMapper : public G1RegionToSpaceMapper {
    size_t _pages_per_region;  // 1024 (4MB / 4KB)
    
    void commit_regions(uint start, size_t count, WorkGang* gang) override {
        size_t start_page = start * _pages_per_region;
        _storage.commit(start_page, count * _pages_per_region);
        _commit_map.set_range(start, start + count);
        fire_on_commit(start, count, zero_filled);
    }
};

// 子类：Region < Page（大页情况）
class G1RegionsSmallerThanCommitSizeMapper : public G1RegionToSpaceMapper {
    // 使用引用计数，多个 Region 共享一个大页
};
```

---

## 6. 内存提交流程

```
┌─────────────────────────────────────────────────────────────────┐
│                    映射器提交流程                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  HeapRegionManager::commit_regions(0, 2048)                     │
│  │                                                               │
│  ├── _heap_mapper->commit_regions(0, 2048)                      │
│  │   └── _storage.commit(0, 2048 * 1024 pages)                  │
│  │       └── mmap(0x600000000, 8GB, PROT_READ|WRITE)            │
│  │                                                               │
│  ├── _bot_mapper->commit_regions(0, 2048)                       │
│  │   └── _storage.commit(0, 2048 * 8 pages)                     │
│  │       └── mmap(bot_addr, 16MB, PROT_READ|WRITE)              │
│  │                                                               │
│  ├── _cardtable_mapper->commit_regions(0, 2048)                 │
│  │   └── mmap(card_addr, 16MB, ...)                             │
│  │                                                               │
│  └── ... (其他 3 个)                                             │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 7. 监听器回调机制

```cpp
// HeapRegionManager 实现 MappingChangedListener
class HeapRegionManager::CommitCallBack : public MappingChangedListener {
    void on_commit(uint start_idx, size_t num_regions, bool zero_filled) override {
        // 当堆内存提交时，同步提交辅助结构
        // （实际上在 commit_regions 中已经处理）
    }
};

// 用途：确保堆内存和辅助结构同步提交/取消提交
```

---

## 8. GDB 验证

```bash
# 验证脚本 gdb_mappers.txt
set pagination off

# 断点：heap_storage 创建
b g1CollectedHeap.cpp:1801
commands
  printf "Creating heap_storage: size=%lu GB\n", g1_rs.size()/1073741824
  continue
end

# 断点：bot_storage 创建
b g1CollectedHeap.cpp:1823
commands
  printf "Creating BOT: heap_map_factor=%lu\n", G1BlockOffsetTable::heap_map_factor()
  continue
end

# 断点：cardtable_storage 创建  
b g1CollectedHeap.cpp:1829
commands
  printf "Creating CardTable: heap_map_factor=%lu\n", G1CardTable::heap_map_factor()
  continue
end

# 断点：bitmap 创建
b g1CollectedHeap.cpp:1845
commands
  printf "Bitmap size=%lu MB\n", bitmap_size/1048576
  continue
end

run
```

---

## 9. 总结

### 9.1 六个映射器的作用

| 映射器 | 作用 | GC 阶段 |
|--------|------|---------|
| heap_storage | Java 堆本身 | 所有阶段 |
| bot_storage | 快速定位对象起始 | 扫描、疏散 |
| cardtable_storage | 跨 Region 引用跟踪 | Minor GC、Mixed GC |
| card_counts_storage | 热卡优化 | 并发精炼 |
| prev_bitmap | 上轮标记结果 | Mixed GC |
| next_bitmap | 本轮标记进行 | 并发标记 |

### 9.2 内存开销

```
8GB 堆的辅助结构开销：

BOT:        16MB   (堆的 0.2%)
CardTable:  16MB   (堆的 0.2%)
CardCounts: 16MB   (堆的 0.2%)
Bitmaps:   256MB   (堆的 3.1%)
────────────────────────────
总计:      304MB   (堆的 3.7%)
```

### 9.3 设计权衡

| 方案 | 优点 | 缺点 |
|------|------|------|
| 更大映射因子 | 节省内存 | 精度降低 |
| 更小映射因子 | 精度高 | 浪费内存 |
| **当前方案** | 平衡精度和开销 | 约 3.7% 额外开销 |

---

## 10. 下一步

理解了 6 个映射器后，可以继续分析：
- **C.1** HeapRegionManager 如何使用这些映射器
- **C.3** G1BarrierSet 如何与 CardTable 配合
- **D.1** G1ConcurrentMark 如何使用双缓冲位图
