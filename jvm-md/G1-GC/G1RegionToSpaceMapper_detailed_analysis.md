# G1内存映射器(G1RegionToSpaceMapper)创建详细分析

## 目录

- [概述](#概述)
- [核心作用详解](#g1regiontospacemapper核心作用详解)
- [创建的数据结构/对象](#创建的数据结构对象)
- [内存布局](#内存布局)
- [核心机制](#g1regiontospacemapper核心机制)
  - [类层次结构](#类层次结构)
  - [设计模式: Strategy模式](#设计模式-strategy模式)
  - [commit_regions流程详解](#commit_regions流程详解-g1regionslargerthancommitsizemapper)
  - [底层G1PageBasedVirtualSpace::commit流程](#底层g1pagebasedvirtualspacecommit流程)
- [核心成员变量详解](#核心成员变量详解)
  - [_storage: G1PageBasedVirtualSpace](#1-_storage-g1pagebasedvirtualspace-底层存储)
  - [_commit_map: CHeapBitMap](#2-_commit_map-cheapbitmap-region状态位图)
  - [_region_granularity: size_t](#3-_region_granularity-size_t-region粒度)
  - [_listener: G1MappingChangedListener*](#4-_listener-g1mappingchangedlistener-监听器指针)
- [Region到Page的映射关系](#region到page的映射关系)
- [监听器机制完整调用链](#监听器机制mapping-changed-listener)
- [关键属性与注意事项](#关键属性与注意事项)
  - [页面大小](#1-页面大小page-size)
  - [Region大小](#2-region大小region-granularity)
  - [提交因子](#3-提交因子commit-factor)
  - [Commit位图](#4-commit位图_commit_map)
  - [监听器机制](#5-监听器机制mapping-changed-listener)
  - [预触摸](#6-预触摸pretouch)
  - [双缓冲位图](#7-双缓冲位图double-buffering-bitmaps)
  - [延迟提交](#8-延迟提交lazy-commitment)
  - [内存对齐](#9-内存对齐memory-alignment)
  - [NMT支持](#10-nmtnative-memory-tracking支持)
- [关键优势与内存转换公式](#关键优势与内存转换公式)
  - [G1RegionToSpaceMapper的关键优势](#一g1regiontospacemapper的关键优势)
  - [内存转换公式总结](#二内存转换公式总结)
  - [关键参数配置表](#三关键参数配置表)
  - [性能优化技巧](#四性能优化技巧)
- [内存占用统计](#内存占用统计8gb堆配置)
- [完整初始化流程](#完整初始化流程)
- [总结](#总结)

---

## 概述

在`G1CollectedHeap::initialize()`的第6步(Lines 1719-1782)中，创建了6个`G1RegionToSpaceMapper`对象，它们是G1GC内存管理的核心组件。这些映射器实现了**虚拟内存→物理内存的按需提交机制**，是G1GC能够高效管理堆内存和辅助数据结构的关键。

## G1RegionToSpaceMapper核心作用详解

### 一、核心定位

**G1RegionToSpaceMapper是G1GC内存管理的抽象层**，它将：
- **Region级别的内存操作**（4MB粒度，业务逻辑）
- 映射为
- **Page级别的系统调用**（4KB粒度，OS接口）

### 二、作用类比

为了更好地理解G1RegionToSpaceMapper，可以用以下类比：

#### 类比1: 内存翻译器
```
G1RegionToSpaceMapper ≈ 内存翻译器

输入 (Region级别): "提交Region 0-10"
    ↓
翻译器处理: Region索引 → Page索引转换
    ↓
输出 (Page级别): "调用os::commit_memory()分配40MB物理内存"
```

#### 类比2: 内存银行
```
G1RegionToSpaceMapper ≈ 内存银行

客户申请: "我要10个Region（40MB）"
    ↓
银行处理:
  1. 查询这些Region是否已提交 (_commit_map)
  2. 调用OS分配40960个Page的物理内存
  3. 更新账本 (_commit_map设置对应bit)
  4. 通知管理员 (触发监听器回调)
    ↓
结果: 客户可以使用这10个Region进行对象分配
```

#### 类比3: 两级仓库管理员
```
G1RegionToSpaceMapper ≈ 两级仓库管理员

上层管理员 (Region级别):
  - 接收业务请求: "分配3个Region给Eden区"
  - 管理业务逻辑: Region的分配、回收
  - 不关心底层细节

下层管理员 (Page级别):
  - 执行物理操作: 调用OS API提交内存
  - 管理物理资源: 页面的commit状态
  - 精确控制: 每个Page的物理内存分配

G1RegionToSpaceMapper充当两级管理员之间的协调者:
  - 将上层Region操作翻译为下层Page操作
  - 维护两级状态的一致性
  - 解耦业务逻辑和底层系统调用
```

### 三、核心价值

1. **抽象层**: 将业务逻辑（Region操作）与底层系统调用（Page操作）分离
2. **延迟提交**: 预留大虚拟空间，按需分配物理内存
3. **两级管理**: Region粒度便于GC，Page粒度便于OS
4. **监听器解耦**: 内存提交与Region初始化分离
5. **高效查询**: 位图O(1)查询Region状态

### 四、在G1GC生态中的位置

```
G1CollectedHeap (顶层协调者)
    ↓
HeapRegionManager (Region管理器)
    ↓ [调用commit_regions()]
G1RegionToSpaceMapper (内存映射器，共6个实例)
    ├─ heap_storage (Java堆)
    ├─ bot_storage (块偏移表)
    ├─ cardtable_storage (卡表)
    ├─ card_counts_storage (热卡计数)
    ├─ prev_bitmap_storage (上一轮标记位图)
    └─ next_bitmap_storage (当前标记位图)
    ↓ [调用os::commit_memory()]
操作系统 (物理内存管理)
```

## 创建的数据结构/对象

### 1. 堆存储映射器 (heap_storage)

```cpp
G1RegionToSpaceMapper* heap_storage =
    G1RegionToSpaceMapper::create_mapper(g1_rs,         // ReservedSpace对象
                                         g1_rs.size(),  // 8GB
                                         page_size,     // 4KB (系统页大小)
                                         HeapRegion::GrainBytes,  // 4MB (Region大小)
                                         1,             // commit_factor
                                         mtJavaHeap);   // NMT内存类型
```

**创建的对象:**
- `G1RegionsLargerThanCommitSizeMapper` (子类)
- `G1PageBasedVirtualSpace _storage` (成员变量)
- `CHeapBitMap _commit_map` (成员变量)

**作用:**
- 管理Java堆内存的虚拟空间
- 按Region粒度(4MB)进行内存提交/取消提交
- 支持2048个Region的动态管理
- 实现延迟分配(lazy allocation)机制

**参数详解(8GB堆为例):**
```
g1_rs.size()          = 8GB   (虚拟地址空间大小)
page_size             = 4KB   (系统页面大小)
HeapRegion::GrainBytes= 4MB   (Region大小 = 8GB / 2048)
commit_factor         = 1     (提交因子，无特殊压缩)
```

### 2. BOT映射器 (bot_storage)

```cpp
G1RegionToSpaceMapper* bot_storage =
    create_aux_memory_mapper("Block Offset Table",
                             G1BlockOffsetTable::compute_size(g1_rs.size() / HeapWordSize), // 16MB
                             G1BlockOffsetTable::heap_map_factor()); // 512B
```

**创建的对象:**
- `G1RegionsLargerThanCommitSizeMapper`
- 独立的虚拟空间 (16MB)

**作用:**
- 管理块偏移表(Block Offset Table)
- 快速定位对象起始地址(用于对象遍历和GC扫描)
- 每512字节堆内存对应1字节BOT

**大小计算:**
```
BOT大小 = 堆大小 / 512字节
       = 8GB / 512B
       = 16MB
```

### 3. 卡表映射器 (cardtable_storage)

```cpp
G1RegionToSpaceMapper* cardtable_storage =
    create_aux_memory_mapper("Card Table",
                             G1CardTable::compute_size(g1_rs.size() / HeapWordSize), // 16MB
                             G1CardTable::heap_map_factor()); // 512B
```

**创建的对象:**
- `G1RegionsLargerThanCommitSizeMapper`
- 独立的虚拟空间 (16MB)

**作用:**
- 管理卡表(Card Table)
- 跟踪跨Region引用关系
- 支持并发细化和增量收集
- 每512字节堆内存对应1字节Card

**大小计算:**
```
Card Table大小 = 堆大小 / 512字节
               = 8GB / 512B
               = 16MB
```

### 4. 卡计数映射器 (card_counts_storage)

```cpp
G1RegionToSpaceMapper* card_counts_storage =
    create_aux_memory_mapper("Card Counts Table",
                             G1CardCounts::compute_size(g1_rs.size() / HeapWordSize), // 16MB
                             G1CardCounts::heap_map_factor()); // 512B
```

**创建的对象:**
- `G1RegionsLargerThanCommitSizeMapper`
- 独立的虚拟空间 (16MB)

**作用:**
- 管理热卡计数表(Hot Card Counts)
- 记录每个Card被修改的次数
- 支持热卡缓存优化
- 避免重复处理频繁修改的Card

**大小计算:**
```
Card Counts大小 = 堆大小 / 512字节
                = 8GB / 512B
                = 16MB
```

### 5. Prev位图映射器 (prev_bitmap_storage)

```cpp
size_t bitmap_size = G1CMBitMap::compute_size(g1_rs.size()); // 128MB
G1RegionToSpaceMapper* prev_bitmap_storage =
    create_aux_memory_mapper("Prev Bitmap", bitmap_size, G1CMBitMap::heap_map_factor()); // 512B
```

**创建的对象:**
- `G1RegionsLargerThanCommitSizeMapper`
- 独立的虚拟空间 (128MB)

**作用:**
- 存储上一轮并发标记的结果
- 提供稳定的引用基准(快照)
- 作为Mixed GC中判断老年代对象存活性的依据
- 避免并发标记过程中的不一致性

**大小计算:**
```
Bitmap大小 = 堆大小 / 512字节 (每512字节对应1bit)
           = 8GB / 512B
           = 16M个字节 / 8 (bit→byte转换)
           = 2MB (存储原始bit)
           = 128MB (实际分配，考虑对齐和管理开销)
```

### 6. Next位图映射器 (next_bitmap_storage)

```cpp
G1RegionToSpaceMapper* next_bitmap_storage =
    create_aux_memory_mapper("Next Bitmap", bitmap_size, G1CMBitMap::heap_map_factor()); // 512B
```

**创建的对象:**
- `G1RegionsLargerThanCommitSizeMapper`
- 独立的虚拟空间 (128MB)

**作用:**
- 存储当前并发标记的结果(工作区)
- 并发标记线程在此位图上设置新的标记位
- 双缓冲机制：完成后与prev_bitmap交换
- 实现无锁切换

## 内存布局

### 整体内存布局图

```
虚拟地址空间 (Virtually Reserved)
┌─────────────────────────────────────────────────────────┐
│  Java Heap (8GB)                                        │
│  ┌──────────┬──────────┬──────────┬──────────┬────────┐│
│  │ Region 0 │ Region 1 │ Region 2 │ ...      │ 2047  ││
│  │  4MB     │  4MB     │  4MB     │          │  4MB   ││
│  └──────────┴──────────┴──────────┴──────────┴────────┘│
│         ↑ heap_storage映射器管理                          │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  Block Offset Table (16MB)                             │
│  ┌──────────┬──────────┬──────────┬──────────┬────────┐│
│  │ BOT(0-4MB)│BOT(4-8MB)│...       │          │        ││
│  │  8KB     │  8KB     │          │          │        ││
│  └──────────┴──────────┴──────────┴──────────┴────────┘│
│         ↑ bot_storage映射器管理                           │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  Card Table (16MB)                                      │
│  ┌──────────┬──────────┬──────────┬──────────┬────────┐│
│  │ CT(0-4MB)│ CT(4-8MB)│ ...      │          │        ││
│  │  8KB     │  8KB     │          │          │        ││
│  └──────────┴──────────┴──────────┴──────────┴────────┘│
│         ↑ cardtable_storage映射器管理                    │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  Card Counts Table (16MB)                              │
│  ┌──────────┬──────────┬──────────┬──────────┬────────┐│
│  │CC(0-4MB) │CC(4-8MB) │ ...      │          │        ││
│  │  8KB     │  8KB     │          │          │        ││
│  └──────────┴──────────┴──────────┴──────────┴────────┘│
│         ↑ card_counts_storage映射器管理                   │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  Prev Bitmap (128MB)                                    │
│  ┌──────────┬──────────┬──────────┬──────────┬────────┐│
│  │BM(0-4MB) │BM(4-8MB) │ ...      │          │        ││
│  │  1KB     │  1KB     │          │          │        ││
│  └──────────┴──────────┴──────────┴──────────┴────────┘│
│         ↑ prev_bitmap_storage映射器管理                   │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  Next Bitmap (128MB)                                    │
│  ┌──────────┬──────────┬──────────┬──────────┬────────┐│
│  │BM(0-4MB) │BM(4-8MB) │ ...      │          │        ││
│  │  1KB     │  1KB     │          │          │        ││
│  └──────────┴──────────┴──────────┴──────────┴────────┘│
│         ↑ next_bitmap_storage映射器管理                   │
└─────────────────────────────────────────────────────────┘

总计预留虚拟空间: 8GB + 16MB×3 + 128MB×2 = 8.368GB
实际使用物理内存: 按需提交 (初始可能只提交部分Region)
```

### 单个映射器的内存结构

```cpp
// 以heap_storage为例
G1RegionToSpaceMapper {
    G1PageBasedVirtualSpace _storage {
        char* _low_boundary;           // 虚拟空间起始地址
        char* _high_boundary;          // 虚拟空间结束地址
        size_t _page_size;              // 4KB (页面大小)
        CHeapBitMap _committed;         // 每页的commit状态位图
            /*
            _committed内存结构（每个字64位）：
            字0: [0000000000000000000000000000000000000000000000000000000000000000] (Page 0-63)
            字1: [0000000000000000000000000000000000000000000000000000000000000000] (Page 64-127)
            ...
            */
    }

    size_t _region_granularity;          // 4MB (Region大小)
    CHeapBitMap _commit_map;            // 每个Region的commit状态位图
        /*
        _commit_map内存结构（每个字64位）：
        字0: [0000000000000000000000000000000000000000000000000000000000000000] (Region 0-63)
        字1: [0000000000000000000000000000000000000000000000000000000000000000] (Region 64-127)
        ...
        字31:[0000000000000000000000000000000000000000000000000000000000000000] (Region 1984-2047)
        */

    G1MappingChangedListener* _listener; // 监听器指针
}
```

### 核心成员变量详解

#### 1. _storage: G1PageBasedVirtualSpace (底层存储)

**作用**: 封装底层虚拟空间，提供页级别的commit/uncommit操作

**核心成员**:
```cpp
class G1PageBasedVirtualSpace {
private:
    char* _low_boundary;      // 虚拟空间起始地址 (如: 0x7f12340000000)
    char* _high_boundary;     // 虚拟空间结束地址 (如: 0x7f12b40000000)
    size_t _page_size;        // 页大小 (4KB标准页 或 2MB大页)
    CHeapBitMap _committed;     // 每页的commit状态位图

public:
    bool commit(size_t start_page, size_t size_in_pages);      // 提交页面
    bool uncommit(size_t start_page, size_t size_in_pages);  // 取消提交
    void pretouch(size_t start_page, size_t size_in_pages, ...); // 预触摸
};
```

**关键操作**:

1. **commit**: 提交物理内存
```cpp
bool G1PageBasedVirtualSpace::commit(size_t start_page, size_t size_in_pages) {
    // 1. 计算物理地址
    char* start_address = page_start(start_page);
    size_t size_in_bytes = size_in_pages * _page_size;

    // 2. 调用OS API (核心系统调用)
    bool result = os::commit_memory(start_address, size_in_bytes, _executable);
    //    Linux实现: mprotect(addr, size, PROT_READ | PROT_WRITE)
    //    或: mmap() with MAP_PRIVATE | MAP_ANONYMOUS

    // 3. 更新位图
    _committed.set_range(start_page, start_page + size_in_pages);

    return result;
}
```

2. **uncommit**: 取消提交物理内存
```cpp
bool G1PageBasedVirtualSpace::uncommit(size_t start_page, size_t size_in_pages) {
    // 1. 调用OS API释放物理内存
    char* start_address = page_start(start_page);
    os::uncommit_memory(start_address, size_in_pages * _page_size);
    //    Linux实现: madvise(addr, size, MADV_DONTNEED)
    //    或: mprotect(addr, size, PROT_NONE)

    // 2. 更新位图
    _committed.clear_range(start_page, start_page + size_in_pages);
}
```

3. **page_start**: Page索引 → 物理地址转换
```cpp
char* page_start(size_t page_idx) const {
    return _low_boundary + page_idx * _page_size;
}
```

**示例** (heap_storage, 8GB堆):
```
_low_boundary = 0x7f12340000000
_page_size    = 4KB (0x1000)

Page 0    → 0x7f12340000000
Page 1    → 0x7f12340001000
Page 1023 → 0x7f12340fff000
...
Page 2097151 → 0x7f12b3fff000
```

#### 2. _commit_map: CHeapBitMap (Region状态位图)

**作用**: O(1)时间查询Region是否已提交

**数据结构**:
```cpp
CHeapBitMap _commit_map;  // 底层使用BitMap实现
```

**内存布局** (heap_storage, 2048个Region):
```
_commit_map (2048 bits = 256 bytes):
┌─────────────────────────────────────────────────────────────┐
│ Word 0 (64 bits)                                    │
│ [0000000000000000000000000000000000000000000000000000000000000000000000] │
│  Bit 0-63: Region 0-63 的commit状态                      │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│ Word 1 (64 bits)                                    │
│ [0000000000000000000000000000000000000000000000000000000000000000000000] │
│  Bit 64-127: Region 64-127 的commit状态                    │
└─────────────────────────────────────────────────────────────┘
...
┌─────────────────────────────────────────────────────────────┐
│ Word 31 (64 bits)                                   │
│ [0000000000000000000000000000000000000000000000000000000000000000000000] │
│  Bit 1984-2047: Region 1984-2047 的commit状态              │
└─────────────────────────────────────────────────────────────┘
```

**关键操作**:

1. **查询** (O(1)时间复杂度):
```cpp
bool is_committed(uintptr_t idx) const {
    return _commit_map.at(idx);
}

// 使用示例
if (heap_storage->is_committed(region_idx)) {
    // Region已提交，可以直接分配对象
} else {
    // Region未提交，需要先commit
    heap_storage->commit_regions(region_idx, 1);
}
```

2. **更新单个Region**:
```cpp
_commit_map.set_bit(idx);      // 标记为已提交
_commit_map.clear_bit(idx);    // 标记为未提交
```

3. **批量更新**:
```cpp
_commit_map.set_range(start_idx, end_idx);    // 批量设置
_commit_map.clear_range(start_idx, end_idx); // 批量清除
```

**位图优势**:
- **空间效率**: 2048 bits = 256 bytes
- **时间效率**: O(1)查询和更新
- **批量操作**: 支持范围操作，减少系统调用
- **CPU友好**: 位操作对CPU缓存友好

#### 3. _region_granularity: size_t (Region粒度)

**作用**: Region → Page的转换基准

**计算**:
```cpp
// 构造函数中设置
_region_granularity = region_granularity;  // 4MB

// 计算每个Region包含的Page数
size_t _pages_per_region = _region_granularity / _page_size;
//                     = 4MB / 4KB
//                     = 1024
```

**使用场景**:
```cpp
// Region索引 → Page索引转换
size_t page_idx = region_idx * _region_granularity / _page_size;
               = region_idx * _pages_per_region;

// Region 0 → Page 0
// Region 1 → Page 1024
// Region 2 → Page 2048
```

#### 4. _listener: G1MappingChangedListener* (监听器指针)

**作用**: 内存提交后的回调机制，解耦内存管理和Region初始化

**接口定义**:
```cpp
class G1MappingChangedListener {
public:
    virtual void on_commit(uint start_idx, size_t num_regions, bool zero_filled) = 0;
};
```

**实现类**:

1. **G1RegionMappingChangedListener** (在G1CollectedHeap中):
```cpp
class G1RegionMappingChangedListener : public G1MappingChangedListener {
public:
    virtual void on_commit(uint start_idx, size_t num_regions, bool zero_filled) {
        // 重置from card cache
        reset_from_card_cache(start_idx, num_regions);
    }
};
```

2. **G1CardTableChangedListener** (在G1CardTable中):
```cpp
class G1CardTableChangedListener : public G1MappingChangedListener {
private:
    G1CardTable* _card_table;
public:
    virtual void on_commit(uint start_idx, size_t num_regions, bool zero_filled) {
        // 初始化Card Table对应区域
        _card_table->initialize_for_regions(start_idx, num_regions);
    }
};
```

3. **G1CMBitMapMappingChangedListener** (在G1ConcurrentMarkBitMap中):
```cpp
class G1CMBitMapMappingChangedListener : public G1MappingChangedListener {
private:
    G1CMBitMap* _bm;
public:
    virtual void on_commit(uint start_idx, size_t num_regions, bool zero_filled) {
        // 清除位图中的旧数据
        if (!zero_filled) {
            MemRegion mr(G1CollectedHeap::heap()->bottom_addr_for_region(start_region),
                      num_regions * HeapRegion::GrainWords);
            _bm->clear_range(mr);
        }
    }
};
```

4. **G1CardCountsMappingChangedListener** (在G1CardCounts中):
```cpp
class G1CardCountsMappingChangedListener : public G1MappingChangedListener {
private:
    G1CardCounts* _counts;
public:
    virtual void on_commit(uint start_idx, size_t num_regions, bool zero_filled) {
        // 初始化卡计数表
        _counts->initialize_for_regions(start_idx, num_regions);
    }
};
```

**设置监听器**:
```cpp
// 在G1CollectedHeap::initialize()中
heap_storage->set_mapping_changed_listener(&_listener);  // G1RegionMappingChangedListener
bot_storage->set_mapping_changed_listener(&_bot_listener);    // G1CardTableChangedListener
cardtable_storage->set_mapping_changed_listener(&_cardtable_listener); // G1CardTableChangedListener
prev_bitmap_storage->set_mapping_changed_listener(&_prev_bitmap_listener); // G1CMBitMapMappingChangedListener
next_bitmap_storage->set_mapping_changed_listener(&_next_bitmap_listener); // G1CMBitMapMappingChangedListener
card_counts_storage->set_mapping_changed_listener(&_card_counts_listener); // G1CardCountsMappingChangedListener
```

**触发回调**:
```cpp
void fire_on_commit(uint start_idx, size_t num_regions, bool zero_filled) {
    if (_listener != NULL) {
        _listener->on_commit(start_idx, num_regions, zero_filled);
    }
}
```

**监听器优势**:
- **解耦设计**: 内存提交和Region初始化分离
- **灵活性**: 不同映射器可以有不同的监听器
- **自动化**: commit完成后自动触发，无需手动调用
- **可扩展**: 新增监听器不影响现有代码

### Region到Page的映射关系

```
对于heap_storage:
Region大小 = 4MB
Page大小  = 4KB
每Region包含的Page数 = 4MB / 4KB = 1024个Page

Region索引到Page索引的转换:
Page索引 = Region索引 × 1024

示例:
Region 0  → Pages 0-1023
Region 1  → Pages 1024-2047
...
Region 2047 → Pages 2096128-2097151

_commit_map结构:
┌────────┬────────┬────────┬────────┐
│ Bit 0  │ Bit 1  │ ...    │ Bit2047│
│Region0 │Region1 │        │Region2047│
└────────┴────────┴────────┴────────┘
   ↓         ↓              ↓
 Pages    Pages          Pages
  0-1023  1024-2047    2096128-2097151
```

## G1RegionToSpaceMapper核心机制

### 类层次结构

```
G1RegionToSpaceMapper (抽象基类)
├── 成员变量
│   ├── G1PageBasedVirtualSpace _storage
│   ├── size_t _region_granularity
│   ├── CHeapBitMap _commit_map
│   └── G1MappingChangedListener* _listener
│
├── 核心方法 (纯虚函数，子类必须实现)
│   ├── virtual void commit_regions(uint start_idx, size_t num_regions, WorkGang* pretouch_gang) = 0;
│   └── virtual void uncommit_regions(uint start_idx, size_t num_regions) = 0;
│
└── 两个子类实现
    ├── G1RegionsLargerThanCommitSizeMapper (通常情况: Region ≥ Page)
    │   ├── size_t _pages_per_region;
    │   └── 适合: 非大页模式，标准JVM配置
    │
    └── G1RegionsSmallerThanCommitSizeMapper (大页情况: Region < Page)
        ├── size_t _regions_per_page;
        └── CommitRefcountArray _refcounts;
```

### 设计模式: Strategy模式

**设计意图**: 根据Region大小与Page大小的关系，选择不同的内存提交策略。

#### 模式结构

```cpp
// 1. 策略抽象
class G1RegionToSpaceMapper {
    // 策略接口 (纯虚函数)
    virtual void commit_regions(...) = 0;
    virtual void uncommit_regions(...) = 0;
};

// 2. 具体策略A: Region ≥ Page (标准情况)
class G1RegionsLargerThanCommitSizeMapper : public G1RegionToSpaceMapper {
    // 一个Region = 多个Page
    // 映射关系: Region索引 × N = Page索引
};

// 3. 具体策略B: Region < Page (大页情况)
class G1RegionsSmallerThanCommitSizeMapper : public G1RegionToSpaceMapper {
    // 一个Page = 多个Region
    // 需要引用计数管理共享Page
};
```

#### 工厂方法创建策略

```cpp
// g1RegionToSpaceMapper.cpp:191
G1RegionToSpaceMapper* G1RegionToSpaceMapper::create_mapper(
    ReservedSpace rs, size_t actual_size, size_t page_size,
    size_t region_granularity, size_t commit_factor, MemoryType type) {

    // 根据运行时条件选择策略
    if (region_granularity >= (page_size * commit_factor)) {
        // 标准情况: Region(4MB) ≥ Page(4KB)
        return new G1RegionsLargerThanCommitSizeMapper(...);
    } else {
        // 大页情况: Region(1MB) < Page(2MB)
        return new G1RegionsSmallerThanCommitSizeMapper(...);
    }
}
```

#### 策略对比

|| 策略 | Region与Page关系 | 适用场景 | 实现复杂度 |
|-------|-----------------|---------|-----------|
| G1RegionsLargerThanCommitSizeMapper | Region ≥ Page<br>一个Region包含多个Page | 标准JVM配置<br>非大页模式 | 简单<br>直接映射 |
| G1RegionsSmallerThanCommitSizeMapper | Region < Page<br>一个Page包含多个Region | 大页模式<br>Region < Page大小 | 复杂<br>需要引用计数 |

#### 策略A详解: G1RegionsLargerThanCommitSizeMapper

**核心思想**: 一对多映射，Region → Pages

```cpp
class G1RegionsLargerThanCommitSizeMapper {
private:
    size_t _pages_per_region;  // 每个Region包含的Page数

public:
    G1RegionsLargerThanCommitSizeMapper(...) {
        _pages_per_region = alloc_granularity / (page_size * commit_factor);
        // 示例: 4MB / 4KB = 1024
    }

    void commit_regions(uint start_idx, size_t num_regions, ...) {
        // 1. Region索引 → Page索引转换
        size_t start_page = start_idx * _pages_per_region;
        //    示例: commit Region 10 → Page 10240

        // 2. 底层commit
        _storage.commit(start_page, num_regions * _pages_per_region);

        // 3. 更新位图
        _commit_map.set_range(start_idx, start_idx + num_regions);
    }
};
```

**映射关系**:
```
Region 0  → Pages 0-1023
Region 1  → Pages 1024-2047
Region 2  → Pages 2048-3071
...
```

#### 策略B详解: G1RegionsSmallerThanCommitSizeMapper

**核心思想**: 多对一映射，多个Region共享一个Page

```cpp
class G1RegionsSmallerThanCommitSizeMapper {
private:
    size_t _regions_per_page;        // 每个Page包含的Region数
    CommitRefcountArray _refcounts;   // 引用计数数组

public:
    void commit_regions(uint start_idx, size_t num_regions, ...) {
        for (uint i = start_idx; i < start_idx + num_regions; i++) {
            size_t page_idx = region_idx_to_page_idx(i);
            uint old_refcount = _refcounts.get_by_index(page_idx);

            if (old_refcount == 0) {
                // 首次使用此Page，需要commit
                _storage.commit(page_idx, 1);
            }

            // 增加引用计数
            _refcounts.set_by_index(page_idx, old_refcount + 1);
            _commit_map.set_bit(i);
        }
    }
};
```

**引用计数机制**:
```
Page 0:
  引用计数: 3
  包含Region: 0, 1, 2

Page 1:
  引用计数: 1
  包含Region: 3

Page 2:
  引用计数: 0
  包含Region: 4, 5 (未提交)
```

**uncommit逻辑**:
```cpp
void uncommit_regions(uint start_idx, size_t num_regions) {
    for (uint i = start_idx; i < start_idx + num_regions; i++) {
        size_t page_idx = region_idx_to_page_idx(i);
        uint old_refcount = _refcounts.get_by_index(page_idx);

        if (old_refcount == 1) {
            // 最后一个Region uncommit，可以释放Page
            _storage.uncommit(page_idx, 1);
        }

        // 减少引用计数
        _refcounts.set_by_index(page_idx, old_refcount - 1);
        _commit_map.clear_bit(i);
    }
}
```

#### 策略模式的优势

1. **灵活性**: 运行时根据配置自动选择合适的策略
2. **可扩展性**: 新增策略不影响现有代码
3. **封装性**: 策略内部实现细节对调用者透明
4. **性能优化**: 针对不同场景优化实现

### commit_regions流程详解 (G1RegionsLargerThanCommitSizeMapper)

```cpp
void commit_regions(uint start_idx, size_t num_regions, WorkGang* pretouch_gang) {
    // 1. 计算起始页号
    size_t const start_page = (size_t)start_idx * _pages_per_region;
    //    示例: commit Region 0-3 → start_page = 0

    // 2. 调用底层commit (核心操作)
    bool zero_filled = _storage.commit(start_page, num_regions * _pages_per_region);
    //    实际调用: os::commit_memory() 提交物理内存
    //    zero_filled: 表示内存是否已零填充(针对special空间)

    // 3. 预触摸(可选，默认关闭)
    if (AlwaysPreTouch) {
        _storage.pretouch(start_page, num_regions * _pages_per_region, pretouch_gang);
    }

    // 4. 更新_commit_map位图 (O(1)时间查询)
    _commit_map.set_range(start_idx, start_idx + num_regions);
    //    示例: commit Region 0-3 → 设置bit[0..3] = 1

    // 5. 触发监听器回调 (解耦内存管理和Region初始化)
    fire_on_commit(start_idx, num_regions, zero_filled);
    //    回调: HeapRegionManager::on_commit()
    //          → 初始化HeapRegion对象
    //          → 更新Region状态
}
```

### 底层G1PageBasedVirtualSpace::commit流程

```cpp
bool G1PageBasedVirtualSpace::commit(size_t start_page, size_t size_in_pages) {
    // 1. 参数检查
    guarantee(size_in_pages > 0, "Must be");
    guarantee(is_area_uncommitted(start_page, size_in_pages),
              "Must be uncommitted");

    // 2. 计算地址范围
    char* const start_address = page_start(start_page);
    char* const end_address = page_start(start_page + size_in_pages);

    // 3. 调用OS API提交物理内存 (核心系统调用)
    bool result = os::commit_memory(start_address, end_address - start_address, _executable);
    //    Linux: mmap() with MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, then mprotect()
    //    或: mprotect() to enable read/write access

    // 4. 更新_committed位图
    _committed.set_range(start_page, start_page + size_in_pages);

    // 5. 返回是否零填充
    return result && !_special;
}
```

## 关键属性与注意事项

### 1. 页面大小(Page Size)

**标准配置:**
- 默认: 4KB (系统标准页面)
- 大页: 2MB/1GB (需要OS支持)
- 透明大页: `-XX:+UseTransparentHugePages`

**影响:**
```
小页面(4KB):
- 精粒度内存管理
- 8GB堆 → 2M个Page
- _commit_map: 2M bits = 250KB

大页面(2MB):
- 减少TLB miss
- 8GB堆 → 4K个Page
- _commit_map: 4K bits = 512B
```

### 2. Region大小(Region Granularity)

**计算公式:**
```cpp
HeapRegion::GrainBytes = MAX(堆大小 / 2048, 1MB);
```

**8GB堆的Region大小:**
```
Region大小 = MAX(8GB / 2048, 1MB) = MAX(4MB, 1MB) = 4MB
Region数量 = 8GB / 4MB = 2048个Region
```

**Region大小的影响:**
| Region大小 | Region数量(8GB堆) | GC停顿时间 | 内存开销 |
|-----------|------------------|-----------|---------|
| 1MB       | 8192             | 最短      | 最高    |
| 4MB       | 2048             | 中等      | 中等    |
| 32MB      | 256              | 最长      | 最低    |

### 3. 提交因子(Commit Factor)

**作用:**
- 控制辅助数据结构的实际提交粒度
- 值为1表示完全提交(无压缩)
- 通常为1(堆存储)或heap_map_factor(辅助结构，512B)

**heap_map_factor详解:**
```
heap_map_factor = 512B (每512字节堆内存对应1字节辅助数据)

对于BOT/Card Table:
- 每4MB Region → 需要 4MB/512B = 8KB 辅助数据
- commit_factor = 512B 表示按512B粒度提交
- 实际上，commit_factor主要用于计算_commit_map的大小
```

### 4. Commit位图(_commit_map)

**大小计算:**
```cpp
// heap_storage的_commit_map
_commit_map大小 = rs.size() * commit_factor / region_granularity
                = 8GB * 1 / 4MB
                = 2048 bits
                = 256 bytes

// bot_storage的_commit_map
_commit_map大小 = 16MB * 512B / 4MB
                = 2048 bits
                = 256 bytes

// prev/next_bitmap_storage的_commit_map
_commit_map大小 = 128MB * 512B / 4MB
                = 16384 bits
                = 2KB
```

**位图结构:**
```
_commit_map (CHeapBitMap):
- 底层实现: BitMap (每个word 64位)
- 查询: O(1) 时间复杂度
- 更新: set_bit() / clear_bit() / set_range()

示例查询:
if (_commit_map.at(region_idx)) {
    // Region已提交
}
```

### 5. 监听器机制(Mapping Changed Listener)

**作用:**
- 解耦内存提交和Region初始化
- 当内存commit后自动触发回调
- HeapRegionManager实现此接口

#### 完整调用链详解

**场景**: JVM需要扩展堆，提交100个Region (400MB)

```
步骤1: G1CollectedHeap::initialize() 设置监听器
┌──────────────────────────────────────────────────────────┐
│ G1CollectedHeap::initialize()                 │
│   ┌───────────────────────────────────────┐       │
│   │ heap_storage = create_mapper(...)   │       │
│   │ heap_storage->set_mapping_changed_    │       │
│   │   listener(&_listener);              │       │
│   └───────────────────────────────────────┘       │
│   │                                           │
│   │ Listener: G1RegionMappingChangedListener │       │
│   │   └─> on_commit(): reset_card_cache()  │       │
└──────────────────────────────────────────────────────────┘

步骤2: HeapRegionManager::commit_regions() 提交内存
┌──────────────────────────────────────────────────────────┐
│ HeapRegionManager::commit_regions(0, 100)        │
│   ├─> _heap_mapper->commit_regions(...)       │
│   │   │                                        │
│   │   ├─> _prev_bitmap_mapper->commit_regions(...)│
│   │   │   │                                    │
│   │   │   ├─> _next_bitmap_mapper->commit_regions(...)
│   │   │   │   │                                │
│   │   │   │   ├─> _bot_mapper->commit_regions(...)
│   │   │   │   │   │                            │
│   │   │   │   │   └─> _cardtable_mapper->commit_regions(...)
│   │   │   │   │       │                        │
│   │   │   │   │       └─> _card_counts_mapper->commit_regions(...)
│   │   │   │   │                                  │
│   │   │   │   └─> 触发6个监听器回调              │
└──────────────────────────────────────────────────────────┘

步骤3: heap_storage内部commit流程
┌──────────────────────────────────────────────────────────┐
│ G1RegionsLargerThanCommitSizeMapper::commit_regions()  │
│   │                                           │
│   │ 1. Region → Page转换                       │
│   │    start_page = 0 * 1024 = 0            │
│   │    num_pages = 100 * 1024 = 102400       │
│   │                                           │
│   │ 2. 底层commit                             │
│   │    _storage.commit(0, 102400);               │
│   │    │                                        │
│   │    │  ├─> os::commit_memory() [系统调用]   │
│   │    │  │    Linux: mprotect(...)           │
│   │    │  │    分配400MB物理内存               │
│   │    │  │                                        │
│   │    │  └─> _committed.set_range(...)           │
│   │    │       更新Page状态位图                  │
│   │                                           │
│   │ 3. 预触摸 (可选)                          │
│   │    if (AlwaysPreTouch) {                   │
│   │        _storage.pretouch(...);                │
│   │    }                                        │
│   │                                           │
│   │ 4. 更新Region状态位图                       │
│   │    _commit_map.set_range(0, 100);             │
│   │                                           │
│   │ 5. 触发监听器回调 ★关键步骤               │
│   │    fire_on_commit(0, 100, false);            │
│   │    │                                        │
│   │    └─> _listener->on_commit(0, 100, false)│
└──────────────────────────────────────────────────────────┘

步骤4: 监听器回调 (6个并行触发)
┌──────────────────────────────────────────────────────────┐
│ heap_storage的监听器:                          │
│ G1RegionMappingChangedListener::on_commit()         │
│   └─> reset_from_card_cache(0, 100)            │
│      重置from card cache                        │
├──────────────────────────────────────────────────────┤
│ prev_bitmap_storage的监听器:                    │
│ G1CMBitMapMappingChangedListener::on_commit()      │
│   ├─> 检查zero_filled参数                     │
│   │   if (!zero_filled) {                     │
│   │       MemRegion mr(...);                     │
│   │       └─> _bm->clear_range(mr);            │
│   │          清除位图中的旧数据                   │
│   │   }                                        │
│   └─> 完成                                     │
├──────────────────────────────────────────────────────┤
│ next_bitmap_storage的监听器:                    │
│ G1CMBitMapMappingChangedListener::on_commit()      │
│   ├─> 检查zero_filled参数                     │
│   │   if (!zero_filled) {                     │
│   │       MemRegion mr(...);                     │
│   │       └─> _bm->clear_range(mr);            │
│   │          清除位图中的旧数据                   │
│   │   }                                        │
│   └─> 完成                                     │
├──────────────────────────────────────────────────────┤
│ bot_storage的监听器:                             │
│ G1CardTableChangedListener::on_commit()             │
│   └─> _card_table->initialize_for_regions(0, 100)│
│      初始化Card Table对应区域                   │
├──────────────────────────────────────────────────────┤
│ cardtable_storage的监听器:                      │
│ G1CardTableChangedListener::on_commit()             │
│   └─> _card_table->initialize_for_regions(0, 100)│
│      初始化Card Table对应区域                   │
└──────────────────────────────────────────────────────┘
card_counts_storage的监听器:
G1CardCountsMappingChangedListener::on_commit()
    └─> _counts->initialize_for_regions(0, 100)
          初始化卡计数表

步骤5: commit_regions() 返回
┌──────────────────────────────────────────────────────────┐
│ 所有6个mapper的commit_regions()都完成             │
│ 返回HeapRegionManager::commit_regions()         │
│   │                                           │
│   │ 下一步: make_regions_available()              │
│   └─> 创建HeapRegion对象 (100个)             │
└──────────────────────────────────────────────────────────┘
```

#### 调用链示例代码

```cpp
// 1. 应用层: 需要分配新Region
G1CollectedHeap::allocate_region() {
    // 找到空闲Region范围: 0-99
    HeapRegionManager::expand(100);  // 扩展100个Region

    // ↓
}

// 2. Region管理层: 提交内存
HeapRegionManager::expand(uint num_regions) {
    // 找到连续空闲Region: 0-99
    uint idx = find_contiguous(num_regions);

    // 提交这100个Region的内存
    commit_regions(idx, num_regions, NULL);

    // ↓ 内部实现
    void commit_regions(uint index, size_t num_regions, ...) {
        _num_committed += num_regions;  // 更新计数

        // 调用所有6个mapper的commit_regions()
        _heap_mapper->commit_regions(index, num_regions, pretouch_gang);
            // ↓ 触发heap_storage的commit流程
        _prev_bitmap_mapper->commit_regions(index, num_regions, pretouch_gang);
            // ↓ 触发prev_bitmap的commit流程
        _next_bitmap_mapper->commit_regions(index, num_regions, pretouch_gang);
            // ↓ 触发next_bitmap的commit流程
        _bot_mapper->commit_regions(index, num_regions, pretouch_gang);
            // ↓ 触发bot_storage的commit流程
        _cardtable_mapper->commit_regions(index, num_regions, pretouch_gang);
            // ↓ 触发cardtable_storage的commit流程
        _card_counts_mapper->commit_regions(index, num_regions, pretouch_gang);
            // ↓ 触发card_counts_storage的commit流程
    }

    // 继续创建HeapRegion对象
    make_regions_available(idx, num_regions, pretouch_gang);
}

// 3. Mapper层: commit_regions (以heap_storage为例)
G1RegionsLargerThanCommitSizeMapper::commit_regions(0, 100, ...) {
    size_t start_page = 0 * 1024 = 0;
    size_t num_pages = 100 * 1024 = 102400;

    // 底层commit
    bool zero_filled = _storage.commit(start_page, num_pages);
    // ↓ G1PageBasedVirtualSpace::commit()
    //   ↓ os::commit_memory() [系统调用]
    //   分配400MB物理内存

    // 更新位图
    _commit_map.set_range(0, 100);

    // 触发监听器回调 ★
    fire_on_commit(0, 100, zero_filled);
    // ↓ fire_on_commit()
    //   └─> _listener->on_commit(0, 100, false)
    //       ↓ G1RegionMappingChangedListener::on_commit()
    //          └─> reset_from_card_cache(0, 100)
}

// 4. 监听器层: 回调处理
G1RegionMappingChangedListener::on_commit(0, 100, false) {
    // 重置from card cache
    reset_from_card_cache(0, 100);
}
```

#### 调用链时序图

```
时间轴 ─────────────────────────────────────────────────────────────────>
      │
T1    │ G1CollectedHeap::allocate_region()
      │   └─> HeapRegionManager::expand(100)
      │
T2    │    └─> HeapRegionManager::commit_regions(0, 100)
      │         ├─> heap_storage->commit_regions()
      │         │    └─> G1PageBasedVirtualSpace::commit()
      │         │         └─> os::commit_memory() ★系统调用
      │         │    └─> 更新_commit_map
      │         │    └─> fire_on_commit(0, 100, false)
      │         │         └─> G1RegionMappingChangedListener::on_commit()
      │         │              └─> reset_from_card_cache(0, 100) ★完成
      │         │
      │         ├─> prev_bitmap_storage->commit_regions()
      │         │    └─> [同样流程]
      │         │         └─> G1CMBitMapMappingChangedListener::on_commit()
      │         │              └─> _bm->clear_range() ★完成
      │         │
      │         ├─> next_bitmap_storage->commit_regions()
      │         │    └─> [同样流程]
      │         │         └─> G1CMBitMapMappingChangedListener::on_commit()
      │         │              └─> _bm->clear_range() ★完成
      │         │
      │         ├─> bot_storage->commit_regions()
      │         │    └─> [同样流程]
      │         │         └─> G1CardTableChangedListener::on_commit()
      │         │              └─> initialize_for_regions(0, 100) ★完成
      │         │
      │         ├─> cardtable_storage->commit_regions()
      │         │    └─> [同样流程]
      │         │         └─> G1CardTableChangedListener::on_commit()
      │         │              └─> initialize_for_regions(0, 100) ★完成
      │         │
      │         └─> card_counts_storage->commit_regions()
      │              └─> [同样流程]
      │                   └─> G1CardCountsMappingChangedListener::on_commit()
      │                        └─> initialize_for_regions(0, 100) ★完成
      │
T3    │    └─> HeapRegionManager::make_regions_available(0, 100)
      │         └─> 创建100个HeapRegion对象
      │         └─> 更新_regions数组
      │
T4    │    └─> 返回HeapRegionManager::expand()
      │         └─> 返回第一个可用Region
      │
T5    │         └─> 返回G1CollectedHeap::allocate_region()
      │              └─> 应用程序可以使用这些Region进行对象分配
```

#### 监听器设计优势

1. **解耦**: 内存commit和Region初始化完全分离
2. **自动化**: commit完成后自动触发，无需手动调用
3. **灵活性**: 每个mapper可以有独立的监听器
4. **可扩展**: 新增监听器不影响现有代码
5. **并行处理**: 6个mapper的监听器并行触发，互不干扰

### 6. 预触摸(Pretouch)

**作用:**
- 在内存commit后立即访问所有页面
- 将页面真正加载到物理内存(避免缺页中断)
- 可选功能(默认关闭)

**启用方式:**
```bash
# JVM启动参数
-XX:+AlwaysPreTouch
```

**性能影响:**
- 优点: 减少运行时缺页中断，提升初始性能
- 缺点: 延长JVM启动时间(8GB堆可能需要几秒钟)

**并行预触摸:**
```cpp
if (AlwaysPreTouch) {
    _storage.pretouch(start_page, num_regions * _pages_per_page, pretouch_gang);
    // 使用WorkGang并行访问所有页面
}
```

### 7. 双缓冲位图(Double Buffering Bitmaps)

**为什么要两个位图?**
```
Prev Bitmap (稳定):
- 上一轮标记结果
- 用于Mixed GC
- 提供一致性视图

Next Bitmap (工作区):
- 当前标记结果
- 并发标记线程写入
- 标记完成后与Prev交换

交换过程:
1. 并发标记完成
2. 等待所有应用线程到达Safepoint
3. 快速交换prev/next指针
4. 继续下一次并发标记
```

**交换机制:**
```cpp
void G1CollectedHeap::swap_mark_bitmaps() {
    G1CMBitMap* temp = _prev_marker;
    _prev_marker = _next_marker;
    _next_marker = temp;
}
```

### 8. 延迟提交(Lazy Commitment)

**什么是延迟提交?**
```
初始化阶段:
- 预留8GB虚拟地址空间
- 不实际分配物理内存
- 只创建G1RegionToSpaceMapper对象

运行时动态提交:
- 当需要分配对象时
- 提交对应Region的内存
- 创建HeapRegion对象
```

**优势:**
- 减少启动时间
- 降低实际物理内存占用
- 支持动态堆扩展

**示例:**
```cpp
// 初始状态
- 预留8GB虚拟空间
- 已提交: 0字节
- 物理内存: ~100MB (映射器等开销)

// 运行时分配对象
- 扩展到1GB (256个Region)
- 已提交: 1GB
- 物理内存: 1.1GB (堆 + 辅助数据)
```

### 9. 内存对齐(Memory Alignment)

**对齐要求:**
```cpp
// ReservedSpace对齐
g1_rs.alignment() = os::vm_allocation_granularity(); // 64KB(通常)

// Region大小对齐(2的幂次)
HeapRegion::GrainBytes = 4MB (2^22)

// 辅助数据结构对齐
Preferred page size = os::page_size_for_region_unaligned(size, 1);
                     = 4KB (标准页) 或 2MB (大页)
```

**对齐的好处:**
- 避免跨页访问
- 提升TLB命中率
- 支持大页优化

### 10. NMT(Native Memory Tracking)支持

**MemoryType标记:**
```cpp
mtJavaHeap  // Java堆内存 (heap_storage)
mtGC        // GC辅助结构 (其他5个映射器)
```

**NMT记录:**
```cpp
MemTracker::record_virtual_memory_type((address)rs.base(), type);
```

**启用NMT:**
```bash
# JVM启动参数
-XX:NativeMemoryTracking=summary  // 摘要模式
-XX:NativeMemoryTracking=detail   // 详细模式
```

**查看NMT输出:**
```bash
# 使用jcmd查看
jcmd <pid> VM.native_memory summary
```

## 内存占用统计(8GB堆配置)

| 数据结构 | 虚拟预留 | 物理提交(初始) | 物理提交(最大) |
|---------|---------|---------------|---------------|
| Java Heap | 8GB | 0-8GB | 8GB |
| Block Offset Table | 16MB | 16MB | 16MB |
| Card Table | 16MB | 16MB | 16MB |
| Card Counts | 16MB | 16MB | 16MB |
| Prev Bitmap | 128MB | 128MB | 128MB |
| Next Bitmap | 128MB | 128MB | 128MB |
| **总计** | **8.368GB** | **~320MB** | **8.32GB** |

**映射器本身的开销:**
- G1RegionToSpaceMapper对象: ~2KB × 6 = 12KB
- _commit_map位图: 总计 ~3KB
- G1PageBasedVirtualSpace内部: ~10KB × 6 = 60KB
- **总计: ~75KB**

## 完整初始化流程

```cpp
// G1CollectedHeap::initialize() 第6步

// 1. 创建堆存储映射器
G1RegionToSpaceMapper* heap_storage =
    G1RegionToSpaceMapper::create_mapper(g1_rs, g1_rs.size(), page_size,
                                         HeapRegion::GrainBytes, 1, mtJavaHeap);
heap_storage->set_mapping_changed_listener(&_listener);

// 2-4. 创建辅助数据结构映射器(BOT, CardTable, CardCounts)
G1RegionToSpaceMapper* bot_storage =
    create_aux_memory_mapper("Block Offset Table", 16MB, 512B);
G1RegionToSpaceMapper* cardtable_storage =
    create_aux_memory_mapper("Card Table", 16MB, 512B);
G1RegionToSpaceMapper* card_counts_storage =
    create_aux_memory_mapper("Card Counts Table", 16MB, 512B);

// 5-6. 创建并发标记位图映射器(双缓冲)
size_t bitmap_size = G1CMBitMap::compute_size(g1_rs.size()); // 128MB
G1RegionToSpaceMapper* prev_bitmap_storage =
    create_aux_memory_mapper("Prev Bitmap", bitmap_size, 512B);
G1RegionToSpaceMapper* next_bitmap_storage =
    create_aux_memory_mapper("Next Bitmap", bitmap_size, 512B);

// 7. 将所有映射器传递给HeapRegionManager统一管理
_hrm.initialize(heap_storage, prev_bitmap_storage, next_bitmap_storage,
                bot_storage, cardtable_storage, card_counts_storage);

// 8. 初始化需要映射器的组件
_card_table->initialize(cardtable_storage);
_hot_card_cache->initialize(card_counts_storage);
```

## 关键优势与内存转换公式

### 一、G1RegionToSpaceMapper的关键优势

#### 1. 两级粒度管理

**Region级别 (4MB)** - 业务逻辑层:
- 对象分配、GC回收的粒度
- 便于实现增量收集和并发标记
- 支持Region的独立分配/回收

**Page级别 (4KB)** - 系统调用层:
- 操作系统内存管理的最小单位
- 支持细粒度的物理内存控制
- 减少内存碎片和浪费

**优势对比**:
```
传统GC (Parallel GC):
- 初始化: commit全部堆内存 (8GB)
- GC: 无法取消提交
- 浪费: 即使只使用1GB，也占用8GB

G1GC (G1RegionToSpaceMapper):
- 初始化: 预留虚拟空间 (0物理内存)
- 运行时: 按需commit (实际使用多少，commit多少)
- GC: 可以取消提交空闲Region
- 节省: 物理内存使用率接近100%
```

#### 2. 延迟提交机制 (Lazy Commitment)

**工作原理**:
```
初始化阶段 (JVM启动):
- os::reserve_memory(8GB)  → 预留虚拟地址空间
- 物理内存占用: ~100MB (映射器等元数据)

运行时动态提交 (分配对象时):
- commit_region(0-10)       → 提交40MB物理内存
- commit_region(10-20)      → 提交40MB物理内存
- 物理内存占用: 线性增长

垃圾回收时:
- uncommit_region(0-10)     → 释放40MB物理内存
- uncommit_region(10-20)    → 释放40MB物理内存
- 物理内存占用: 线性减少
```

**优势**:
1. **快速启动**: JVM启动时间减少80%+ (无需等待8GB内存初始化)
2. **内存效率**: 物理内存使用率提升至95%+ (按需分配)
3. **动态扩展**: 支持从-Xms到-Xmx的平滑过渡
4. **大堆友好**: 64GB堆也能快速启动 (初始只占虚拟空间)

#### 3. 监听器解耦机制

**传统方式** (紧耦合):
```cpp
// 内存提交后，手动调用初始化
heap_storage->commit_regions(0, 10);
// 程序员必须记得调用这些函数
initialize_heap_regions(0, 10);
initialize_card_table(0, 10);
initialize_bitmap(0, 10);
// ❌ 容易遗漏，维护困难
```

**监听器方式** (解耦):
```cpp
// 内存提交后，自动触发回调
heap_storage->commit_regions(0, 10);
// ↓ fire_on_commit()自动触发
//   └─> _listener->on_commit(0, 10, false)
//       ↓ 自动初始化所有相关数据结构
//       ↓ 不会遗漏，易于维护
```

**优势**:
1. **自动化**: commit完成后自动触发，无需手动调用
2. **完整性**: 6个监听器并行触发，确保所有数据结构初始化
3. **可扩展**: 新增监听器不影响现有代码
4. **解耦**: 内存管理和Region初始化完全分离

#### 4. 位图O(1)查询

**查询性能**:
```cpp
// 时间复杂度: O(1)
bool is_committed = _commit_map.at(region_idx);

// 对比遍历方式
bool is_committed_traditional(uint region_idx) {
    for (uint i = 0; i < _num_regions; i++) {
        if (i == region_idx) return _committed[i];
    }
    return false;
}
// 时间复杂度: O(n)，n=2048
```

**性能对比** (查询100万次):
```
位图方式: O(1) × 100万 = 100万次操作
遍历方式: O(2048) × 100万 = 204.8亿次操作

性能提升: 2048倍！
```

#### 5. 批量操作优化

**单次commit vs 批量commit**:
```cpp
// 单次commit (100次系统调用)
for (uint i = 0; i < 100; i++) {
    heap_storage->commit_regions(i, 1);  // 100次系统调用
}

// 批量commit (1次系统调用)
heap_storage->commit_regions(0, 100);  // 1次系统调用
```

**性能提升**:
- **系统调用**: 减少99次 (100→1)
- **位图操作**: 100次set_bit vs 1次set_range
- **监听器回调**: 100次触发 vs 1次触发
- **总性能提升**: 约100倍

#### 6. 双缓冲位图机制

**为什么需要两个位图**:
```
Prev Bitmap (稳定视图):
- 上一轮标记结果
- 用途: Mixed GC判断对象存活性
- 特点: 只读，并发标记期间不修改
- 一致性: 提供快照式的稳定视图

Next Bitmap (工作视图):
- 当前标记结果
- 用途: 并发标记线程工作区
- 特点: 读写，并发标记期间频繁修改
- 实时性: 实时更新标记结果
```

**交换过程** (无锁切换):
```
时刻T1: 并发标记进行中
┌─────────────────────────────────────┐
│ Prev Bitmap: 稳定，供Mixed GC使用  │
│ Next Bitmap: 并发标记线程写入       │
│   [标记新对象]                     │
└─────────────────────────────────────┘

时刻T2: 并发标记完成
┌─────────────────────────────────────┐
│ Safepoint: 所有应用线程暂停       │
│ swap_mark_bitmaps()               │
│   temp = _prev_marker             │
│   _prev_marker = _next_marker      │ ← 指针交换 (原子操作)
│   _next_marker = temp              │
│   耗时: 纳秒级                 │
└─────────────────────────────────────┘

时刻T3: 新一轮标记开始
┌─────────────────────────────────────┐
│ Prev Bitmap: 旧Next (已标记)      │ ← 成为新的稳定视图
│ Next Bitmap: 旧Prev (清空)        │ ← 成为新的工作区
│   [开始新标记]                     │
└─────────────────────────────────────┘
```

**优势**:
1. **无锁切换**: 原子指针交换，无需锁
2. **快速切换**: 纳秒级完成，不中断应用
3. **一致性**: Prev位图在Safepoint时切换，保证一致性
4. **并行支持**: Next位图标记时，Prev位图仍可被GC读取

### 二、内存转换公式总结

#### 1. Region到Page的转换

**基础公式**:
```cpp
pages_per_region = Region_Size / Page_Size
```

**heap_storage示例**:
```
Region_Size = 4MB = 4 × 1024 × 1024 bytes
Page_Size   = 4KB = 4 × 1024 bytes

pages_per_region = 4 × 1024 × 1024 / (4 × 1024)
                = 1024个Page/Region
```

**转换公式**:
```cpp
Region索引 → Page索引:
page_start_idx = region_idx × pages_per_region
page_end_idx   = (region_idx + 1) × pages_per_region - 1

// 示例
Region 0 → Pages 0-1023
Region 10 → Pages 10240-11263
```

#### 2. 地址到Region的转换

**堆地址 → Region索引**:
```cpp
region_idx = (address - heap_base_address) / Region_Size
```

**heap_storage示例** (假设base=0x7f12340000000):
```
address = 0x7f123401000000  (Region 1起始)
offset  = 0x7f123401000000 - 0x7f12340000000 = 0x100000 = 4MB

region_idx = 4MB / 4MB = 1
```

**Region索引 → 堆地址**:
```cpp
region_start_address = heap_base_address + region_idx × Region_Size
region_end_address   = heap_base_address + (region_idx + 1) × Region_Size

// 示例
Region 0 start = 0x7f12340000000 + 0 × 4MB = 0x7f12340000000
Region 0 end   = 0x7f12340000000 + 1 × 4MB = 0x7f12340400000
```

#### 3. 辅助数据结构的转换

**Card Table/COT**:
```cpp
// 堆地址 → Card索引
card_idx = (address - heap_base_address) / 512B

// Card索引 → 堆地址
card_start_address = heap_base_address + card_idx × 512B

// Region索引 → Card数量
cards_per_region = Region_Size / 512B
                = 4MB / 512B
                = 8192个Card/Region
```

**BitMap**:
```cpp
// 堆地址 → Bit索引
bit_idx = (address - heap_base_address) / 512B / 8

// Bit索引 → 堆地址
bit_start_address = heap_base_address + bit_idx × 8 × 512B

// Region索引 → Bit数量
bits_per_region = Region_Size / 512B / 8
                = 4MB / 512B / 8
                = 1024个bit/Region
                = 128字节/Region
```

#### 4. 内存占用计算

**虚拟地址空间**:
```cpp
// 总预留空间
total_reserved = heap_size + bot_size + cardtable_size +
               card_counts_size + prev_bitmap_size + next_bitmap_size

// 8GB堆示例
total_reserved = 8GB + 16MB + 16MB + 16MB + 128MB + 128MB
              = 8.368GB
```

**物理内存**:
```cpp
// 初始物理内存 (只提交必要的)
initial_physical = mapper_metadata + auxiliary_data
                ≈ 100MB (映射器等)

// 运行时物理内存 (随使用量增长)
runtime_physical = committed_heap × 1.04  // 4%为辅助数据开销

// 最大物理内存
max_physical = max_heap_size × 1.04

// 8GB堆示例
initial_physical = 100MB
runtime_physical = 8GB × 1.04 = 8.32GB
max_physical = 8.32GB
```

#### 5. 位图大小计算

**_commit_map大小**:
```cpp
// heap_storage
commit_map_size = num_regions / 8  // bits to bytes
               = 2048 / 8
               = 256 bytes

// bot_storage/cardtable_storage/card_counts_storage
commit_map_size = (aux_size / 512B) / 8
               = (16MB / 512B) / 8
               = 2048 / 8
               = 256 bytes

// prev/next_bitmap_storage
commit_map_size = (bitmap_size / 512B) / 8
               = (128MB / 512B) / 8
               = 16384 / 8
               = 2KB

// 总位图开销
total_bitmap_overhead = 256 × 5 + 2KB
                    ≈ 3.2KB
```

**_committed (Page状态位图)大小**:
```cpp
// heap_storage
committed_size = num_pages / 8  // bits to bytes
              = (8GB / 4KB) / 8
              = 2M / 8
              = 256KB

// 其他mapper
committed_size = (aux_size / 4KB) / 8
```

### 三、关键参数配置表

| 参数 | heap_storage | bot_storage | cardtable_storage | card_counts_storage | prev/next_bitmap |
|------|-------------|-------------|------------------|-------------------|------------------|
| **Region大小** | 4MB | 4MB | 4MB | 4MB |
| **Page大小** | 4KB | 4KB | 4KB | 4KB |
| **Region数量** | 2048 | 2048 | 2048 | 2048 |
| **Page数量** | 2,097,152 | 4,096 | 4,096 | 32,768 |
| **_commit_map大小** | 256B | 256B | 256B | 2KB |
| **_committed大小** | 256KB | 16KB | 16KB | 128KB |
| **总内存大小** | 8GB | 16MB | 16MB | 128MB |

### 四、性能优化技巧

#### 1. 批量操作
```cpp
// ✅ 推荐: 批量commit
heap_storage->commit_regions(0, 100);  // 1次系统调用

// ❌ 避免: 循环单次commit
for (uint i = 0; i < 100; i++) {
    heap_storage->commit_regions(i, 1);  // 100次系统调用
}
```

#### 2. 预触摸 (可选)
```bash
# 适用场景: 对延迟敏感的应用
java -XX:+AlwaysPreTouch -Xmx8g MyApp

# 不适用场景: 快速启动优先
java -Xmx8g MyApp  # 默认关闭
```

#### 3. 大页支持 (可选)
```bash
# 检查系统是否支持大页
cat /proc/meminfo | grep Hugepagesize

# 启用大页 (2MB)
java -XX:+UseLargePages -Xmx8g MyApp
```

#### 4. 监听器复用
```cpp
// ✅ 推荐: 复用监听器对象
G1MappingChangedListener* listener = new MyListener();
heap_storage->set_mapping_changed_listener(listener);
prev_bitmap->set_mapping_changed_listener(listener);

// ❌ 避免: 创建多个监听器对象
heap_storage->set_mapping_changed_listener(new MyListener1());
prev_bitmap->set_mapping_changed_listener(new MyListener2());
```

## 总结

G1RegionToSpaceMapper是G1GC内存管理的核心抽象，它提供了:

1. **虚拟内存管理**: 预留大地址空间，延迟提交物理内存
2. **粒度控制**: 支持Page(4KB)和Region(4MB)两级粒度
3. **双缓冲机制**: Prev/Next Bitmap支持并发标记
4. **监听器解耦**: 内存提交与Region初始化分离
5. **性能优化**: 预触摸、大页支持、位图O(1)查询

6个映射器的协同工作确保了G1GC能够高效管理Java堆及其辅助数据结构，为后续的内存分配、垃圾收集和并发标记奠定了坚实基础。
