# G1CollectedHeap::initialize() 深度分析

## 方法概述
- **位置**: `/data/workspace/openjdk-cut-new/src/hotspot/share/gc/g1/g1CollectedHeap.cpp:1587`
- **行数**: 约400行 (L1587-2445)
- **功能**: G1堆的核心初始化方法，建立完整的G1内存管理体系
- **调用时机**: JVM启动时，由 `Universe::initialize_heap()` 间接调用

## 初始化流程详析

### 1. 基础环境检查 (L1588-1603)
```cpp
os::enable_vtime();
MutexLocker x(Heap_lock);
guarantee(HeapWordSize == wordSize, "HeapWordSize must equal wordSize");
size_t init_byte_size = collector_policy()->initial_heap_byte_size();
size_t max_byte_size = collector_policy()->max_heap_byte_size();
size_t heap_alignment = collector_policy()->heap_alignment();
```

**关键参数**:
- `init_byte_size`: -Xms 指定的初始堆大小 (默认物理内存1/64)
- `max_byte_size`: -Xmx 指定的最大堆大小 (默认物理内存1/4)  
- `heap_alignment`: 堆对齐大小

**验证**: 确保大小按 `HeapRegion::GrainBytes` (1MB~32MB) 对齐

### 2. 虚拟内存预留 (L1701-1713)

#### 核心发现：Java堆不在C堆中！
```cpp
ReservedSpace heap_rs = Universe::reserve_heap(max_byte_size, heap_alignment);
initialize_reserved_region((HeapWord*)heap_rs.base(), (HeapWord*)(heap_rs.base() + heap_rs.size()));
```

**技术细节**:
- **位置**: 映射区 (mapped memory area)，非进程堆 (C heap)
- **系统调用**: `mmap(addr, size, PROT_NONE, MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE, -1, 0)`
- **策略**: 两阶段分配
  1. **Reserve**: 预留虚拟地址空间，不分配物理内存
  2. **Commit**: 修改页表权限，触发page fault时分配物理页

#### 三层内存管理架构
```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────────┐
│   MemRegion     │    │  ReservedSpace   │    │ G1RegionToSpaceMapper│
│ 轻量级描述符     │◄──►│ 虚拟内存管理者    │◄──►│ 物理内存管理者       │
│ • _start        │    │ • _base          │    │ • _storage          │
│ • _word_size    │    │ • _size          │    │ • 映射逻辑           │
│ 仅描述范围       │    │ 管理生命周期      │    │ 管理虚实映射         │
└─────────────────┘    └──────────────────┘    └─────────────────────┘
```

### 3. 屏障集与卡表初始化 (L1715-1744)

#### G1CardTable (L1724-1727)
```cpp
G1CardTable *ct = new G1CardTable(reserved_region());
ct->initialize();
```
- **大小**: 8GB堆 → 16MB卡表 (每512字节堆内存对应1字节卡表)
- **作用**: 记录跨代/跨区域引用，GC时只扫描脏卡

#### G1BarrierSet (L1729-1743)
```cpp
G1BarrierSet *bs = new G1BarrierSet(ct);
bs->initialize();
BarrierSet::set_barrier_set(bs);
```
**双重屏障**:
- **写前屏障**: SATB队列记录旧值，支持并发标记
- **写后屏障**: 标记卡表为脏，记录跨Region引用

#### G1HotCardCache (L1746-1755)
```cpp
_hot_card_cache = new G1HotCardCache(this);
```
**优化原理**: 频繁修改的"热卡"先缓存，GC暂停时统一处理，避免重复劳动

### 4. 六个核心映射器创建 (L1777-2000)

#### 4.1 堆内存映射器 (L1801-1815)
```cpp
G1RegionToSpaceMapper *heap_storage =
    G1RegionToSpaceMapper::create_mapper(g1_rs, g1_rs.size(), page_size,
                                        HeapRegion::GrainBytes, 1, mtJavaHeap);
```
- **作用**: 管理堆内存本身 (8GB)
- **Region大小**: 4MB (8GB/2048个Region)

#### 4.2 辅助数据结构映射器 (L1820-1999)
```cpp
// BOT (Block Offset Table) - 快速定位对象起始地址
G1RegionToSpaceMapper *bot_storage =
    create_aux_memory_mapper("Block Offset Table",
                            G1BlockOffsetTable::compute_size(g1_rs.size() / HeapWordSize),
                            G1BlockOffsetTable::heap_map_factor());

// 卡表存储
G1RegionToSpaceMapper *cardtable_storage =
    create_aux_memory_mapper("Card Table",
                            G1CardTable::compute_size(g1_rs.size() / HeapWordSize),
                            G1CardTable::heap_map_factor());

// 卡计数表 (热卡缓存优化)
G1RegionToSpaceMapper *card_counts_storage =
    create_aux_memory_mapper("Card Counts Table",
                            G1CardCounts::compute_size(g1_rs.size() / HeapWordSize),
                            G1CardCounts::heap_map_factor());

// 并发标记位图 (双缓冲机制)
G1RegionToSpaceMapper *prev_bitmap_storage =
    create_aux_memory_mapper("Prev Bitmap", bitmap_size, G1CMBitMap::heap_map_factor());
G1RegionToSpaceMapper *next_bitmap_storage =
    create_aux_memory_mapper("Next Bitmap", bitmap_size, G1CMBitMap::heap_map_factor());
```

**位图双缓冲机制**:
- **prev_mark_bitmap**: 上一轮标记结果，Mixed GC读取
- **next_mark_bitmap**: 当前标记结果，并发标记线程写入
- **交换**: O(1)指针交换，无需数据复制
- **大小**: 8GB堆 → 128MB位图 (每64字节对应1bit)

### 5. 堆区域管理器初始化 (L2004-2005)
```cpp
_hrm.initialize(heap_storage, prev_bitmap_storage, next_bitmap_storage, 
               bot_storage, cardtable_storage, card_counts_storage);
```
- **职责**: 统一管理2048个HeapRegion及其辅助结构
- **Region类型**: Eden(新对象)、Survivor(存活对象)、Old(长期存活)、Humongous(大对象≥2MB)

### 6. 记忆集系统初始化 (L2029-2043)
```cpp
_g1_rem_set = new G1RemSet(this, _card_table, _hot_card_cache);
_g1_rem_set->initialize(max_capacity(), max_regions());
```
- **作用**: 跟踪跨Region引用
- **结构**: 每个Region维护RSet，记录指向它的其他Region的卡

### 7. 快速测试数组 (L2089-2137)

#### CSet快速测试 (L2089-2089)
```cpp
_in_cset_fast_test.initialize(start, end, granularity);
```
- **目的**: O(1)判断对象是否在收集集合(CSet)中
- **实现**: 虚拟数组，每个Region对应1字节状态
  - 0: NotInCSet, 1: Young, 2: Old, -1: Humongous

#### 巨型对象回收候选 (L2136-2136)
```cpp
_humongous_reclaim_candidates.initialize(start, end, granularity);
```
- **Eager Reclaim条件**: 
  1. 纯数据类型数组(byte[]/int[]等，无内部引用)
  2. 记忆集足够小
  3. 实际回收时记忆集必须为空

### 8. 并发标记系统 (L2139-2196)
```cpp
_cm = new G1ConcurrentMark(this, prev_bitmap_storage, next_bitmap_storage);
_cm_thread = _cm->cm_thread();
```
**G1ConcurrentMark职责**:
- **双缓冲位图管理**: 256MB位图记录对象存活状态
- **任务队列集合**: 多线程并行标记，工作窃取算法
- **SATB队列**: 处理并发更新，避免漏标
- **全局标记栈**: 处理队列溢出

**并发标记阶段**:
1. **Initial Mark** (STW): 搭车Young GC执行
2. **Root Region Scan** (并发): 扫描Survivor区
3. **Concurrent Mark** (并发): 遍历对象图，多线程并行
4. **Remark** (STW): 处理SATB队列，完成标记
5. **Cleanup** (STW): 统计区域存活率，准备Mixed GC

### 9. 堆扩展至初始大小 (L2207-2210)
```cpp
if (!expand(init_byte_size, _workers)) {
    vm_shutdown_during_initialization("Failed to allocate initial heap.");
    return JNI_ENOMEM;
}
```
- **_workers**: 13个GC线程
- **效果**: 提交虚拟内存，创建2048个HeapRegion对象

### 10. 策略与线程初始化 (L2212-2273)

#### G1策略初始化 (L2217-2217)
```cpp
g1_policy()->init(this, &_collection_set);
```
- 设置年轻代大小边界
- 启动CSet增量构建机制

#### SATB队列系统 (L2233-2236)
```cpp
G1BarrierSet::satb_mark_queue_set().initialize(SATB_Q_CBL_mon, SATB_Q_FL_lock,
                                               G1SATBProcessCompletedThreshold, // 20
                                               Shared_SATB_Q_lock);
```

#### 并发精炼线程 (L2238-2241)
```cpp
jint ecode = initialize_concurrent_refinement();
```
- **职责**: 处理脏卡，更新RSet
- **线程数**: 自适应，基于系统负载

#### 脏卡队列系统 (L2255-2273)
```cpp
// 全局脏卡队列
G1BarrierSet::dirty_card_queue_set().initialize(DirtyCardQ_CBL_mon, DirtyCardQ_FL_lock,
                                                39, 65, Shared_DirtyCardQ_lock, NULL, true);
// G1堆专用队列
_dirty_card_queue_set().initialize(DirtyCardQ_CBL_mon, DirtyCardQ_FL_lock,
                                   -1, -1, Shared_DirtyCardQ_lock,
                                   &G1BarrierSet::dirty_card_queue_set());
```

### 11. 分配器初始化 (L2275-2323)

#### Dummy Region创建 (L2278-2291)
```cpp
HeapRegion *dummy_region = _hrm.get_dummy_region();
dummy_region->set_eden();
dummy_region->set_top(dummy_region->end());
```
- **作用**: 分配失败时的占位符，保证空值优雅处理
- **特点**: 标记为满的Eden Region，top=end

#### G1Allocator初始化 (L2310-2323)
```cpp
G1AllocRegion::setup(this, dummy_region);
_allocator->init_mutator_alloc_region();
```
**分配器结构**:
```cpp
class G1Allocator {
    MutatorAllocRegion _mutator_alloc_region;    // Java线程分配用
    SurvivorGCAllocRegion _survivor_gc_alloc_region; // GC时复制存活对象
    OldGCAllocRegion _old_gc_alloc_region;            // GC时晋升对象
};
```

### 12. 监控与服务 (L2325-2360)

#### G1MonitoringSupport (L2334-2334)
```cpp
_g1mm = new G1MonitoringSupport(this);
```
- **用途**: 为jstat、MemoryMXBean、JConsole提供监控数据

#### 字符串去重 (L2359-2359)
```cpp
G1StringDedup::initialize();
```
- **启用参数**: -XX:+UseStringDeduplication
- **原理**: 多个String共享同一char[]/byte[]

### 13. 标记保留集合 (L2411-2411)
```cpp
_preserved_marks_set.init(ParallelGCThreads);
```
- **用途**: Evacuation失败时保存对象mark word
- **结构**: 每个GC线程一个栈，避免锁竞争

### 14. 收集集合初始化 (L2442-2442)
```cpp
_collection_set.initialize(max_regions());
```
- **CSet构成**: 
  - Young GC: 所有Eden + Survivor Region
  - Mixed GC: Young Region + 部分垃圾多的Old Region

## GDB验证脚本

### 验证虚拟内存预留
```bash
# 启动GDB
gdb --args /data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java -Xms8g -Xmx8g -XX:+UseG1GC

# 断点设置
break G1CollectedHeap::initialize
break Universe::reserve_heap

# 关键变量检查
print heap_rs.base()     # 堆基地址
print heap_rs.size()      # 堆总大小 (8589934592 = 8GB)
print max_byte_size       # -Xmx值
print init_byte_size       # -Xms值
```

### 验证Region创建
```bash
# 继续执行到expand函数
continue
break G1CollectedHeap::expand

# 检查Region数量
print max_regions()       # 2048
print HeapRegion::GrainBytes  # 4194304 (4MB)
```

### 验证位图大小
```bash
# 在位图创建处检查
print bitmap_size         # 134217728 (128MB)
print G1CMBitMap::compute_size(8589934592)  # 128MB
```

## 性能特征

### 内存开销
- **堆内存**: 8GB
- **卡表**: 16MB (每512B堆内存1B)
- **BOT表**: 16MB 
- **位图**: 256MB (双缓冲128MB×2)
- **RSet**: 约占总堆2-3%
- **总计额外开销**: ~300MB

### 启动时间
- **虚拟内存预留**: <1ms (mmap系统调用)
- **Region创建**: ~10ms (2048个对象)
- **辅助结构映射**: ~5ms
- **总计**: ~20ms

## JVM参数影响

### 必需参数
- `-Xms8g -Xmx8g`: 堆大小 (通常相等)
- `-XX:+UseG1GC`: 启用G1收集器

### 可选参数
- `-XX:MaxGCPauseMillis=200`: 目标暂停时间
- `-XX:G1HeapRegionSize=4m`: Region大小 (1MB~32MB)
- `-XX:+UseLargePages`: 启用大页
- `-XX:+UseStringDeduplication`: 启用字符串去重

### 调试参数
- `-XX:+PrintGCDetails`: 打印GC详情
- `-XX:+PrintGCTimeStamps`: 打印时间戳
- `-Xlog:gc+heap=debug`: 堆相关日志

## 关键设计亮点

1. **虚拟内存两阶段分配**: 避免物理内存浪费
2. **Region化管理**: 细粒度控制回收粒度  
3. **双缓冲位图**: 无锁切换，支持并发标记
4. **增量CSet构建**: 平衡回收效率与暂停时间
5. **Eager Reclaim**: 及时回收大对象
6. **热卡缓存**: 减少RSet更新频率

## 相关源码文件
- `src/hotspot/share/gc/g1/g1CollectedHeap.cpp` (主实现)
- `src/hotspot/share/gc/g1/heapRegionManager.hpp` (区域管理)
- `src/hotspot/share/gc/g1/g1RegionToSpaceMapper.hpp` (内存映射)
- `src/hotspot/share/gc/g1/g1ConcurrentMark.hpp` (并发标记)

---
*分析基于OpenJDK 11源码，标准配置: -Xms8g -Xmx8g -XX:+UseG1GC*