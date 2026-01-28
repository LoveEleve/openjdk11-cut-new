# G1CollectedHeap::initialize() 数据结构初始化详细分析

## 概述

`jint status = _collectedHeap->initialize()` 调用的是 `G1CollectedHeap::initialize()` 方法，这是G1垃圾收集器最核心的初始化过程。该方法按照特定顺序初始化了G1GC运行所需的所有关键数据结构。

## 初始化流程与数据结构

### 1. 基础参数获取与验证 (Lines 1566-1587)

```cpp
// 获取堆大小参数
size_t init_byte_size = collector_policy()->initial_heap_byte_size(); // -Xms
size_t max_byte_size = collector_policy()->max_heap_byte_size();       // -Xmx  
size_t heap_alignment = collector_policy()->heap_alignment();          // 堆对齐
```

**初始化的数据结构:**
- 堆大小配置参数
- 对齐验证机制

### 2. 虚拟内存预留 (Lines 1628-1640)

```cpp
ReservedSpace heap_rs = Universe::reserve_heap(max_byte_size, heap_alignment);
initialize_reserved_region((HeapWord*)heap_rs.base(), 
                          (HeapWord*)(heap_rs.base() + heap_rs.size()));
```

**初始化的数据结构:**
- `ReservedSpace heap_rs` - 预留的虚拟地址空间
- `_reserved` (MemRegion) - 堆的内存区域描述符
  - `_start`: 堆起始地址
  - `_word_size`: 堆大小(以HeapWord为单位)

### 3. 卡表(Card Table)初始化 (Lines 1651-1653)

```cpp
G1CardTable* ct = new G1CardTable(reserved_region());
ct->initialize();
_card_table = ct;
```

**初始化的数据结构:**
- `G1CardTable* _card_table` - G1专用卡表
  - 每512字节堆内存对应1字节卡表项
  - 8GB堆 → 16MB卡表
  - 用于跟踪跨Region引用

### 4. 屏障集(Barrier Set)初始化 (Lines 1662-1669)

```cpp
G1BarrierSet* bs = new G1BarrierSet(ct);
bs->initialize();
BarrierSet::set_barrier_set(bs);
```

**初始化的数据结构:**
- `G1BarrierSet` - G1写屏障系统
  - 写前屏障(pre-write barrier): SATB队列支持
  - 写后屏障(post-write barrier): 卡表更新
  - 全局唯一的屏障集实例

### 5. 热卡缓存(Hot Card Cache)初始化 (Lines 1681)

```cpp
_hot_card_cache = new G1HotCardCache(this);
```

**初始化的数据结构:**
- `G1HotCardCache* _hot_card_cache` - 热卡缓存
  - 缓存频繁修改的"热卡"
  - 避免重复处理，优化并发细化性能

### 6. 内存映射器(Memory Mappers)创建 (Lines 1719-1782)

#### 6.1 堆存储映射器
```cpp
G1RegionToSpaceMapper* heap_storage = 
    G1RegionToSpaceMapper::create_mapper(g1_rs, g1_rs.size(), page_size, 
                                        HeapRegion::GrainBytes, 1, mtJavaHeap);
```

#### 6.2 辅助数据结构映射器
```cpp
// BOT映射器 - 块偏移表
G1RegionToSpaceMapper* bot_storage = 
    create_aux_memory_mapper("Block Offset Table", 
                            G1BlockOffsetTable::compute_size(...), ...);

// 卡表映射器
G1RegionToSpaceMapper* cardtable_storage = 
    create_aux_memory_mapper("Card Table", 
                            G1CardTable::compute_size(...), ...);

// 卡计数映射器
G1RegionToSpaceMapper* card_counts_storage = 
    create_aux_memory_mapper("Card Counts Table", 
                            G1CardCounts::compute_size(...), ...);

// 并发标记位图映射器(双缓冲)
G1RegionToSpaceMapper* prev_bitmap_storage = 
    create_aux_memory_mapper("Prev Bitmap", bitmap_size, ...);
G1RegionToSpaceMapper* next_bitmap_storage = 
    create_aux_memory_mapper("Next Bitmap", bitmap_size, ...);
```

**初始化的数据结构:**
- **6个G1RegionToSpaceMapper对象**，管理不同数据结构的内存映射
- 每个映射器负责虚拟内存到物理内存的按需提交

### 7. 堆区域管理器(HeapRegionManager)初始化 (Lines 1787)

```cpp
_hrm.initialize(heap_storage, prev_bitmap_storage, next_bitmap_storage, 
                bot_storage, cardtable_storage, card_counts_storage);
```

**初始化的数据结构:**
- `HeapRegionManager _hrm` - G1核心管理组件
  - 管理所有HeapRegion对象
  - 协调6个映射器的内存管理
  - 提供Region分配/释放接口

### 8. 记忆集(Remembered Set)初始化 (Lines 1809-1810)

```cpp
_g1_rem_set = new G1RemSet(this, _card_table, _hot_card_cache);
_g1_rem_set->initialize(max_capacity(), max_regions());
```

**初始化的数据结构:**
- `G1RemSet* _g1_rem_set` - G1记忆集
  - 跟踪跨Region引用关系
  - 支持增量收集的根集合扫描
  - 集成卡表和热卡缓存

### 9. 块偏移表(Block Offset Table)初始化 (Lines 1827)

```cpp
_bot = new G1BlockOffsetTable(reserved_region(), bot_storage);
```

**初始化的数据结构:**
- `G1BlockOffsetTable* _bot` - 块偏移表
  - 快速定位对象起始地址
  - 每512字节堆内存对应1字节BOT
  - 支持对象遍历和GC扫描

### 10. 快速测试数组初始化 (Lines 1845-1848)

```cpp
_in_cset_fast_test.initialize(start, end, granularity);
_humongous_reclaim_candidates.initialize(start, end, granularity);
```

**初始化的数据结构:**
- `G1InCSetState* _in_cset_fast_test` - 收集集合快速测试
  - O(1)时间判断Region是否在CSet中
  - 优化GC性能的关键数据结构
- `G1BiasedMappedArray<bool> _humongous_reclaim_candidates` - 巨型对象回收候选
  - 标记可回收的巨型Region
  - 支持巨型对象的增量回收

### 11. 并发标记器(Concurrent Mark)初始化 (Lines 1894-1899)

```cpp
_cm = new G1ConcurrentMark(this, prev_bitmap_storage, next_bitmap_storage);
_cm_thread = _cm->cm_thread();
```

**初始化的数据结构:**
- `G1ConcurrentMark* _cm` - 并发标记管理器
  - 双缓冲标记位图(prev/next)
  - 并发标记线程池
  - 任务队列和全局标记栈
  - SATB队列处理机制
- `ConcurrentMarkThread* _cm_thread` - 并发标记线程

### 12. 堆扩展与Region创建 (Lines 1910-1913)

```cpp
if (!expand(init_byte_size, _workers)) {
    vm_shutdown_during_initialization("Failed to allocate initial heap.");
    return JNI_ENOMEM;
}
```

**初始化的数据结构:**
- 将虚拟内存转换为已提交的物理内存
- 创建初始的HeapRegion对象
- 提交所有辅助数据结构的内存

### 13. 策略与队列系统初始化 (Lines 1917-1947)

```cpp
// G1策略初始化
g1_policy()->init(this, &_collection_set);

// SATB队列初始化
G1BarrierSet::satb_mark_queue_set().initialize(...);

// 脏卡队列初始化  
G1BarrierSet::dirty_card_queue_set().initialize(...);
dirty_card_queue_set().initialize(...);
```

**初始化的数据结构:**
- `G1Policy* _g1_policy` - G1收集策略
- `SATBMarkQueueSet` - SATB标记队列集合
- `DirtyCardQueueSet` - 脏卡队列集合(双套)

### 14. 并发细化与采样线程初始化 (Lines 1924-1932)

```cpp
jint ecode = initialize_concurrent_refinement();
ecode = initialize_young_gen_sampling_thread();
```

**初始化的数据结构:**
- `G1ConcurrentRefine* _cr` - 并发细化管理器
- `G1YoungGenSamplingThread* _young_gen_sampling_thread` - 年轻代采样线程

### 15. 分配器与监控初始化 (Lines 1951-1972)

```cpp
// 虚拟Region设置
HeapRegion* dummy_region = _hrm.get_dummy_region();
G1AllocRegion::setup(this, dummy_region);

// 分配器初始化
_allocator->init_mutator_alloc_region();

// 监控支持
_g1mm = new G1MonitoringSupport(this);

// 字符串去重
G1StringDedup::initialize();

// 保留标记集合
_preserved_marks_set.init(ParallelGCThreads);

// 收集集合
_collection_set.initialize(max_regions());
```

**初始化的数据结构:**
- `G1Allocator* _allocator` - G1分配器
- `G1MonitoringSupport* _g1mm` - 监控支持
- `G1StringDedup` - 字符串去重系统
- `PreservedMarksSet _preserved_marks_set` - 保留标记集合
- `G1CollectionSet _collection_set` - 收集集合

## 内存占用统计

基于8GB堆内存(-Xms=8GB -Xmx=8GB)的配置:

| 数据结构 | 大小 | 说明 |
|---------|------|------|
| 堆内存预留 | 8GB | 虚拟地址空间 |
| Card Table | 16MB | 8GB ÷ 512B = 16MB |
| Block Offset Table | 16MB | 8GB ÷ 512B = 16MB |
| Card Counts Table | 16MB | 热卡计数 |
| Prev Bitmap | 128MB | 并发标记位图 |
| Next Bitmap | 128MB | 并发标记位图 |
| HeapRegion对象 | ~8MB | 2048个Region × 4KB |
| 其他数据结构 | ~50MB | 队列、策略、监控等 |
| **总计辅助结构** | **~362MB** | **约占堆内存的4.5%** |

## 初始化顺序的重要性

1. **内存预留优先** - 确保地址空间可用
2. **卡表先于屏障** - 屏障依赖卡表
3. **映射器先于管理器** - HRM需要所有映射器
4. **基础结构先于策略** - 策略依赖基础数据结构
5. **线程最后启动** - 避免并发访问未初始化的结构

## 关键依赖关系

```
ReservedSpace → MemRegion → G1CardTable → G1BarrierSet
                     ↓
            6个RegionToSpaceMapper → HeapRegionManager
                     ↓
            G1RemSet + G1BlockOffsetTable + FastTest数组
                     ↓
            G1ConcurrentMark + 线程系统
                     ↓
            expand() → 物理内存提交 + HeapRegion创建
                     ↓
            策略初始化 + 队列系统 + 监控系统
```

这个初始化过程确保了G1GC的所有核心组件都能正确协同工作，为后续的内存分配和垃圾收集奠定了坚实的基础。

## 创建对象的最终存储位置详细分析

在`G1CollectedHeap::initialize()`方法中创建的所有对象都有明确的存储位置，以下是详细的对象→成员变量映射关系：

### 📍 对象存储位置映射表

| 初始化步骤 | 创建的对象 | 存储到的成员变量 | 变量类型 | 作用域 |
|-----------|-----------|-----------------|---------|--------|
| **2. 虚拟内存预留** | `ReservedSpace heap_rs` | `_reserved` (通过initialize_reserved_region) | `MemRegion` | `CollectedHeap` 基类 |
| **3. 卡表初始化** | `G1CardTable* ct` | `_card_table` | `G1CardTable*` | `G1CollectedHeap` private |
| **4. 屏障集初始化** | `G1BarrierSet* bs` | 全局`BarrierSet::_barrier_set` | `G1BarrierSet*` | 全局静态变量 |
| **5. 热卡缓存** | `G1HotCardCache` | `_hot_card_cache` | `G1HotCardCache*` | `G1CollectedHeap` private |
| **6.1 堆存储映射器** | `G1RegionToSpaceMapper* heap_storage` | 传递给`_hrm.initialize()` | 局部变量→HRM管理 | `HeapRegionManager` |
| **6.2 BOT映射器** | `G1RegionToSpaceMapper* bot_storage` | 传递给`_hrm.initialize()` + `_bot构造` | 局部变量→多处使用 | `HeapRegionManager` + `G1BlockOffsetTable` |
| **6.3 卡表映射器** | `G1RegionToSpaceMapper* cardtable_storage` | 传递给`_card_table->initialize()` | 局部变量→卡表管理 | `G1CardTable` |
| **6.4 卡计数映射器** | `G1RegionToSpaceMapper* card_counts_storage` | 传递给`_hot_card_cache->initialize()` | 局部变量→热卡缓存 | `G1HotCardCache` |
| **6.5 Prev位图映射器** | `G1RegionToSpaceMapper* prev_bitmap_storage` | 传递给`G1ConcurrentMark构造` | 局部变量→并发标记 | `G1ConcurrentMark` |
| **6.6 Next位图映射器** | `G1RegionToSpaceMapper* next_bitmap_storage` | 传递给`G1ConcurrentMark构造` | 局部变量→并发标记 | `G1ConcurrentMark` |
| **7. 堆区域管理器** | `HeapRegionManager` (已存在) | `_hrm` | `HeapRegionManager` | `G1CollectedHeap` private |
| **8. 记忆集** | `G1RemSet` | `_g1_rem_set` | `G1RemSet*` | `G1CollectedHeap` private |
| **9. 块偏移表** | `G1BlockOffsetTable` | `_bot` | `G1BlockOffsetTable*` | `G1CollectedHeap` private |
| **10.1 CSet快速测试** | `G1InCSetStateFastTestBiasedMappedArray` (已存在) | `_in_cset_fast_test` | `G1InCSetStateFastTestBiasedMappedArray` | `G1CollectedHeap` private |
| **10.2 巨型对象候选** | `HumongousReclaimCandidates` (已存在) | `_humongous_reclaim_candidates` | `HumongousReclaimCandidates` | `G1CollectedHeap` private |
| **11.1 并发标记器** | `G1ConcurrentMark` | `_cm` | `G1ConcurrentMark*` | `G1CollectedHeap` private |
| **11.2 并发标记线程** | `ConcurrentMarkThread` | `_cm_thread` | `G1ConcurrentMarkThread*` | `G1CollectedHeap` private |
| **13.1 G1策略** | `G1Policy` (已存在) | `_g1_policy` | `G1Policy*` | `G1CollectedHeap` private |
| **13.2 收集集合** | `G1CollectionSet` (已存在) | `_collection_set` | `G1CollectionSet` | `G1CollectedHeap` private |
| **14.1 并发细化** | `G1ConcurrentRefine` | `_cr` | `G1ConcurrentRefine*` | `G1CollectedHeap` private |
| **14.2 采样线程** | `G1YoungGenSamplingThread` | `_young_gen_sampling_thread` | `G1YoungRemSetSamplingThread*` | `G1CollectedHeap` private |
| **15.1 分配器** | `G1Allocator` (已存在) | `_allocator` | `G1Allocator*` | `G1CollectedHeap` private |
| **15.2 监控支持** | `G1MonitoringSupport` | `_g1mm` | `G1MonitoringSupport*` | `G1CollectedHeap` private |
| **15.3 保留标记集合** | `PreservedMarksSet` (已存在) | `_preserved_marks_set` | `PreservedMarksSet` | `G1CollectedHeap` private |

### 🔍 关键存储位置详解

#### 1. 继承自CollectedHeap的成员变量
```cpp
class CollectedHeap {
protected:
  MemRegion _reserved;  // ← ReservedSpace转换后存储在这里
};
```

#### 2. G1CollectedHeap的核心成员变量
```cpp
class G1CollectedHeap : public CollectedHeap {
private:
  // 线程管理
  G1YoungRemSetSamplingThread* _young_gen_sampling_thread;  // ← 采样线程
  WorkGang* _workers;
  
  // 策略与配置
  G1CollectorPolicy* _collector_policy;
  G1Policy* _g1_policy;                    // ← G1策略
  G1HeapSizingPolicy* _heap_sizing_policy;
  
  // 内存管理核心组件
  G1CardTable* _card_table;                // ← 卡表
  HeapRegionManager _hrm;                  // ← 堆区域管理器
  G1Allocator* _allocator;                 // ← 分配器
  G1BlockOffsetTable* _bot;                // ← 块偏移表
  
  // 垃圾收集相关
  G1HotCardCache* _hot_card_cache;         // ← 热卡缓存
  G1RemSet* _g1_rem_set;                   // ← 记忆集
  G1ConcurrentMark* _cm;                   // ← 并发标记器
  G1ConcurrentMarkThread* _cm_thread;      // ← 并发标记线程
  G1ConcurrentRefine* _cr;                 // ← 并发细化
  
  // 收集集合管理
  G1CollectionSet _collection_set;         // ← 收集集合
  G1InCSetStateFastTestBiasedMappedArray _in_cset_fast_test;  // ← CSet快速测试
  HumongousReclaimCandidates _humongous_reclaim_candidates;   // ← 巨型对象候选
  
  // 监控与统计
  G1MonitoringSupport* _g1mm;              // ← 监控支持
  PreservedMarksSet _preserved_marks_set;  // ← 保留标记集合
  
  // 引用处理器(在initialize中设置但不创建)
  ReferenceProcessor* _ref_processor_stw;  // ← STW引用处理器
  ReferenceProcessor* _ref_processor_cm;   // ← CM引用处理器
  G1STWIsAliveClosure _is_alive_closure_stw;
  G1STWSubjectToDiscoveryClosure _is_subject_to_discovery_stw;
  G1CMIsAliveClosure _is_alive_closure_cm;
  G1CMSubjectToDiscoveryClosure _is_subject_to_discovery_cm;
};
```

### 🎯 特殊存储机制

#### 1. 全局静态存储
- **G1BarrierSet**: 存储在全局静态变量`BarrierSet::_barrier_set`中
- **所有线程可通过`BarrierSet::barrier_set()`访问**

#### 2. 局部变量→传递机制
```cpp
// 6个映射器都是局部变量，但通过参数传递给相应组件管理
G1RegionToSpaceMapper* heap_storage = ...;     // → 传递给_hrm
G1RegionToSpaceMapper* bot_storage = ...;      // → 传递给_hrm + _bot
G1RegionToSpaceMapper* cardtable_storage = ...; // → 传递给_card_table
G1RegionToSpaceMapper* card_counts_storage = ...;// → 传递给_hot_card_cache
G1RegionToSpaceMapper* prev_bitmap_storage = ...;// → 传递给_cm
G1RegionToSpaceMapper* next_bitmap_storage = ...;// → 传递给_cm

// 这些映射器在各自的组件内部被保存和管理
```

#### 3. 嵌套对象存储
```cpp
// HeapRegionManager内部保存映射器引用
class HeapRegionManager {
private:
  G1RegionToSpaceMapper* _heap_mapper;     // ← heap_storage
  G1RegionToSpaceMapper* _prev_bitmap_mapper; // ← prev_bitmap_storage  
  G1RegionToSpaceMapper* _next_bitmap_mapper; // ← next_bitmap_storage
  G1RegionToSpaceMapper* _bot_mapper;      // ← bot_storage
  G1RegionToSpaceMapper* _cardtable_mapper; // ← cardtable_storage
  G1RegionToSpaceMapper* _card_counts_mapper; // ← card_counts_storage
};
```

### 📊 内存所有权层次

```
G1CollectedHeap (顶层容器)
├── 直接拥有的指针成员
│   ├── _card_table (G1CardTable*)
│   ├── _hot_card_cache (G1HotCardCache*)  
│   ├── _g1_rem_set (G1RemSet*)
│   ├── _bot (G1BlockOffsetTable*)
│   ├── _cm (G1ConcurrentMark*)
│   ├── _cm_thread (G1ConcurrentMarkThread*)
│   ├── _cr (G1ConcurrentRefine*)
│   ├── _young_gen_sampling_thread (G1YoungRemSetSamplingThread*)
│   └── _g1mm (G1MonitoringSupport*)
│
├── 直接拥有的值成员  
│   ├── _hrm (HeapRegionManager)
│   ├── _collection_set (G1CollectionSet)
│   ├── _in_cset_fast_test (G1InCSetStateFastTestBiasedMappedArray)
│   ├── _humongous_reclaim_candidates (HumongousReclaimCandidates)
│   └── _preserved_marks_set (PreservedMarksSet)
│
├── 继承的成员 (CollectedHeap)
│   └── _reserved (MemRegion)
│
└── 间接管理的对象
    ├── _hrm 内部管理6个映射器
    ├── _cm 内部管理位图映射器
    ├── _card_table 内部管理卡表映射器
    └── _hot_card_cache 内部管理计数映射器
```

### 🔧 访问器方法

所有存储的对象都提供了相应的访问器方法：

```cpp
// 公共访问器
G1CardTable* card_table() const { return _card_table; }
G1HotCardCache* g1_hot_card_cache() const { return _hot_card_cache; }
G1RemSet* g1_rem_set() const { return _g1_rem_set; }
G1ConcurrentMark* concurrent_mark() const { return _cm; }
G1MonitoringSupport* g1mm() { return _g1mm; }
HeapRegionManager* hrm() { return &_hrm; }
G1CollectionSet* collection_set() { return &_collection_set; }

// 继承的访问器
MemRegion reserved_region() const { return _reserved; }
```

这种设计确保了：
1. **明确的所有权**: 每个对象都有明确的拥有者
2. **生命周期管理**: 对象的创建和销毁都由拥有者负责
3. **访问控制**: 通过访问器方法提供受控的访问
4. **内存安全**: 避免悬空指针和内存泄漏