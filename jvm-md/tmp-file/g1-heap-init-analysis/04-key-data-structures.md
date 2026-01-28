# G1核心数据结构详解

## 🎯 1. ReservedSpace - 虚拟内存预留

```cpp
// 作用：预留8GB虚拟地址空间，但不分配物理内存
ReservedSpace heap_rs = Universe::reserve_heap(max_byte_size, heap_alignment);

// 底层实现：
mmap(preferred_addr,     // 期望地址（压缩指针优化）
     8GB,                // 堆大小
     PROT_NONE,          // 不可访问，只预留地址空间
     MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE,
     -1, 0);
```

**关键理解**：
- 只是在进程地址空间中"占位"
- 不消耗物理内存和swap
- 为后续的Region分配提供连续地址空间

## 🃏 2. G1CardTable - 卡表系统

```cpp
// 创建卡表，每512字节堆内存对应1字节卡表项
G1CardTable* ct = new G1CardTable(reserved_region());

// 卡表大小计算：
// 8GB堆 ÷ 512字节/卡 = 16MB卡表
```

**卡表的作用**：
- 跟踪跨Region引用
- 支持增量收集
- 减少扫描范围

**卡表状态**：
- Clean卡：没有跨Region引用
- Dirty卡：有跨Region引用，需要扫描
- Hot卡：频繁修改的卡

## 🛡️ 3. G1BarrierSet - 屏障集

```cpp
G1BarrierSet* bs = new G1BarrierSet(ct);
BarrierSet::set_barrier_set(bs);
```

**两种屏障**：
1. **写前屏障（Pre-Write Barrier）**
   - 记录引用修改前的旧值
   - 支持SATB并发标记
   
2. **写后屏障（Post-Write Barrier）**
   - 标记卡表为脏
   - 记录跨Region引用

## 🔥 4. G1HotCardCache - 热卡缓存

```cpp
_hot_card_cache = new G1HotCardCache(this);
```

**优化原理**：
- 频繁修改的卡先缓存
- 避免重复处理
- GC时统一处理

## 🗺️ 5. G1RegionToSpaceMapper - 内存映射器

创建6个映射器，管理不同类型的内存：

```cpp
// 1. 主堆存储
G1RegionToSpaceMapper* heap_storage = 
    G1RegionToSpaceMapper::create_mapper(g1_rs, g1_rs.size(), 
                                         page_size, HeapRegion::GrainBytes, 1, mtJavaHeap);

// 2. BOT存储 (16MB)
G1RegionToSpaceMapper* bot_storage = 
    create_aux_memory_mapper("Block Offset Table", 
                             G1BlockOffsetTable::compute_size(...), ...);

// 3. 卡表存储 (16MB)
G1RegionToSpaceMapper* cardtable_storage = 
    create_aux_memory_mapper("Card Table", 
                             G1CardTable::compute_size(...), ...);

// 4. 热卡计数存储 (16MB)  
G1RegionToSpaceMapper* card_counts_storage = 
    create_aux_memory_mapper("Card Counts Table", 
                             G1CardCounts::compute_size(...), ...);

// 5. 上轮标记位图 (128MB)
G1RegionToSpaceMapper* prev_bitmap_storage = 
    create_aux_memory_mapper("Prev Bitmap", bitmap_size, ...);

// 6. 当前标记位图 (128MB)
G1RegionToSpaceMapper* next_bitmap_storage = 
    create_aux_memory_mapper("Next Bitmap", bitmap_size, ...);
```

## 🏛️ 6. HeapRegionManager - Region总管理器

```cpp
_hrm.initialize(heap_storage, prev_bitmap_storage, next_bitmap_storage, 
                bot_storage, cardtable_storage, card_counts_storage);
```

**职责**：
- 管理所有Region的生命周期
- 协调各种辅助数据结构
- 提供Region分配和释放接口

## 🧠 7. G1ConcurrentMark - 并发标记器

```cpp
_cm = new G1ConcurrentMark(this, prev_bitmap_storage, next_bitmap_storage);
```

**核心功能**：
- 管理双缓冲标记位图
- 协调并发标记周期
- 提供存活性分析数据

**标记周期**：
1. Initial Mark (STW)
2. Root Region Scan (并发)
3. Concurrent Mark (并发) ← 核心工作
4. Remark (STW)
5. Cleanup (STW/并发)

## 📊 内存使用汇总

| 数据结构 | 大小 | 计算公式 |
|----------|------|----------|
| 主堆 | 8GB | -Xmx参数 |
| BOT | 16MB | 堆大小 ÷ 512字节 |
| Card Table | 16MB | 堆大小 ÷ 512字节 |
| Card Counts | 16MB | 堆大小 ÷ 512字节 |
| Prev Bitmap | 128MB | 堆大小 ÷ 64字节 |
| Next Bitmap | 128MB | 堆大小 ÷ 64字节 |