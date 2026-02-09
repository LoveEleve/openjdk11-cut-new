# C.1 HeapRegionManager 初始化

> HeapRegionManager 是 G1 管理 2048 个 Region 的**核心组件**

---

## 1. 整体结构

```cpp
// heapRegionManager.hpp:70
class HeapRegionManager : public CHeapObj<mtGC> {
    // ======== 核心数据结构 ========
    G1HeapRegionTable _regions;          // 地址 → HeapRegion* 映射
    
    // ======== 6 个映射器引用 ========
    G1RegionToSpaceMapper* _heap_mapper;
    G1RegionToSpaceMapper* _prev_bitmap_mapper;
    G1RegionToSpaceMapper* _next_bitmap_mapper;
    G1RegionToSpaceMapper* _bot_mapper;
    G1RegionToSpaceMapper* _cardtable_mapper;
    G1RegionToSpaceMapper* _card_counts_mapper;
    
    // ======== 空闲列表 ========
    FreeRegionList _free_list;           // 空闲 Region 双向链表
    
    // ======== 状态跟踪 ========
    CHeapBitMap _available_map;          // Region 可用性位图
    uint _num_committed;                 // 已提交 Region 数
    uint _allocated_heapregions_length;  // 已分配 HeapRegion 对象数
};
```

**内存布局**：
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        HeapRegionManager 结构                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  _regions (G1HeapRegionTable)                                               │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  基于偏置数组的快速索引                                                │  │
│  │  ┌────────┬────────┬────────┬─────────────────────┬────────┐          │  │
│  │  │ HR[0]* │ HR[1]* │ HR[2]* │   ...2048 个指针... │HR[2047]*          │  │
│  │  └────────┴────────┴────────┴─────────────────────┴────────┘          │  │
│  │     ↓         ↓         ↓                             ↓               │  │
│  │  HeapRegion HeapRegion HeapRegion              HeapRegion             │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  _free_list (FreeRegionList)                                                │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  _head ─→ HR[0] ←→ HR[1] ←→ HR[2] ←→ ... ←→ HR[2047] ←─ _tail        │  │
│  │          (双向链表)                                                    │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  _available_map (CHeapBitMap)                                               │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  [1111111111...1111] (2048 bits = 256 bytes)                          │  │
│  │   全1表示所有 Region 都已提交并可用                                    │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 初始化源码分析

```cpp
// heapRegionManager.cpp:34
void HeapRegionManager::initialize(
    G1RegionToSpaceMapper* heap_storage,
    G1RegionToSpaceMapper* prev_bitmap,
    G1RegionToSpaceMapper* next_bitmap,
    G1RegionToSpaceMapper* bot,
    G1RegionToSpaceMapper* cardtable,
    G1RegionToSpaceMapper* card_counts) 
{
    // Step 1: 重置计数器
    _allocated_heapregions_length = 0;
    
    // Step 2: 保存 6 个映射器引用
    // 用于后续 commit/uncommit 时同步管理
    _heap_mapper = heap_storage;
    _prev_bitmap_mapper = prev_bitmap;
    _next_bitmap_mapper = next_bitmap;
    _bot_mapper = bot;
    _cardtable_mapper = cardtable;
    _card_counts_mapper = card_counts;
    
    // Step 3: 初始化 Region 表
    MemRegion reserved = heap_storage->reserved();
    _regions.initialize(reserved.start(),   // 0x600000000
                        reserved.end(),     // 0x800000000
                        HeapRegion::GrainBytes);  // 4MB
    
    // Step 4: 初始化可用性位图
    _available_map.initialize(_regions.length());  // 2048 bits
}
```

---

## 3. G1HeapRegionTable - 偏置数组详解

### 3.1 为什么需要偏置数组？

**问题**：给定任意堆地址，如何快速找到对应的 HeapRegion？

**朴素方案**：
```cpp
// 方案 A：线性搜索 - O(n)，太慢
HeapRegion* find_region(address addr) {
    for (int i = 0; i < 2048; i++) {
        if (regions[i].contains(addr)) return &regions[i];
    }
}

// 方案 B：计算索引 - O(1)，但需要减法
HeapRegion* find_region(address addr) {
    size_t idx = (addr - heap_start) / 4MB;  // 需要减法
    return regions[idx];
}
```

**G1 优化方案：偏置数组**
```cpp
// 方案 C：偏置数组 - O(1)，无需减法
HeapRegion* find_region(address addr) {
    size_t biased_idx = addr >> 22;  // 只需右移
    return biased_base[biased_idx];  // 直接访问
}
```

### 3.2 偏置原理

```
问题：堆起始地址是 0x600000000，不是 0

普通数组：
  index = (addr - heap_start) / 4MB
        = (addr - 0x600000000) >> 22
  需要减法！

偏置数组：
  预先计算 bias = heap_start / 4MB = 0x600000000 >> 22 = 0x1800 (6144)
  
  _biased_base = _base - bias * sizeof(HeapRegion*)
               = _base - 6144 * 8
               = _base - 0xC000
  
  访问时：
  biased_idx = addr >> 22
  return _biased_base[biased_idx];  // 无需减法！
```

**图解**：
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          偏置数组原理图                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  虚拟地址空间                                                                │
│  ┌──────────────────────────────────────────────────────────────────┐       │
│  │  0x0        0x600000000                    0x800000000           │       │
│  │  │          │←───────── 堆 (8GB) ─────────→│                     │       │
│  └──────────────────────────────────────────────────────────────────┘       │
│                                                                              │
│  Region 索引                                                                 │
│  ┌──────────────────────────────────────────────────────────────────┐       │
│  │  0    ...   6144 (0x1800)                  8191 (0x1FFF)         │       │
│  │             │←─────── 实际使用 ────────────→│                    │       │
│  └──────────────────────────────────────────────────────────────────┘       │
│                 ↑ bias                                                       │
│                                                                              │
│  普通数组 (_base)                                                            │
│  ┌────────────────────────────────────────────────────────────────┐         │
│  │ [0] [1] [2] ... [2047]                                         │         │
│  │  ↑                                                              │         │
│  │ _base                                                           │         │
│  └────────────────────────────────────────────────────────────────┘         │
│                                                                              │
│  偏置基地址 (_biased_base)                                                   │
│  ┌────────────────────────────────────────────────────────────────┐         │
│  │ [-6144] ... [-1] [0] [1] ... [2047]                            │         │
│  │  ↑                ↑                                             │         │
│  │ _biased_base    _base                                           │         │
│  └────────────────────────────────────────────────────────────────┘         │
│                                                                              │
│  访问示例（地址 0x600400000，即 Region[1]）：                                │
│  biased_idx = 0x600400000 >> 22 = 0x1801 (6145)                             │
│  result = _biased_base[6145]                                                 │
│         = _base[6145 - 6144]                                                 │
│         = _base[1]  ✓                                                        │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.3 核心代码

```cpp
// g1BiasedArray.hpp:56
void initialize_base(address base, size_t length, size_t bias, 
                     size_t elem_size, uint shift_by) {
    _base = base;                              // 实际数组起始
    _length = length;                          // 2048
    _biased_base = base - (bias * elem_size);  // 偏置基地址
    _bias = bias;                              // 6144
    _shift_by = shift_by;                      // 22 (log2(4MB))
}

// g1BiasedArray.hpp:157
T get_by_address(HeapWord* value) const {
    // 只需右移，无需减法
    idx_t biased_index = ((uintptr_t)value) >> this->shift_by();
    return biased_base()[biased_index];
}
```

### 3.4 性能对比

| 操作 | 普通数组 | 偏置数组 |
|------|----------|----------|
| 计算索引 | 减法 + 除法 | 右移 |
| 指令数 | 3-4 条 | 1 条 |
| 热路径性能 | 基准 | **快 2-3 倍** |

---

## 4. FreeRegionList - 空闲链表

### 4.1 结构

```cpp
// heapRegionSet.hpp:155
class FreeRegionList : public HeapRegionSetBase {
    HeapRegion* _head;   // 链表头
    HeapRegion* _tail;   // 链表尾
    HeapRegion* _last;   // 上次操作位置（优化）
};
```

### 4.2 链表操作

```cpp
// 分配 Region（从头部或尾部取）
HeapRegion* allocate_free_region(bool is_old) {
    HeapRegion* hr = _free_list.remove_region(is_old);
    return hr;
}

// 释放 Region（按索引顺序插入）
void insert_into_free_list(HeapRegion* hr) {
    _free_list.add_ordered(hr);
}
```

### 4.3 初始化后状态

```
expand() 后的 _free_list：

_head ─→ HR[0] ←→ HR[1] ←→ HR[2] ←→ ... ←→ HR[2047] ←─ _tail
         │         │         │                │
         │         │         │                │
         ↓         ↓         ↓                ↓
      0x600M    0x604M    0x608M    ...    0x7FC M

链表长度：2048
每个节点通过 _next/_prev 指针连接
```

---

## 5. _available_map - 可用性位图

### 5.1 作用

```cpp
// 快速判断 Region 是否已提交并可用
bool HeapRegionManager::is_available(uint region) const {
    return _available_map.at(region);
}
```

### 5.2 状态变化

| 时机 | 操作 | 位图状态 |
|------|------|----------|
| 初始化后 | 未提交 | 全 0 |
| expand() 后 | 已提交 | 全 1 |
| uncommit Region | 释放内存 | 对应位置 0 |

### 5.3 内存开销

```
位图大小 = 2048 bits = 256 bytes
```

---

## 6. 三个长度的含义

```cpp
// heapRegionManager.hpp:61-67 注释
// _num_committed:      已提交 Region 数（可能不连续）
// _allocated_heapregions_length: 已分配 HeapRegion 对象数 + 1
// max_length():        最大 Region 数（固定 2048）
```

**示例**：
```
初始化后：
  _num_committed = 0
  _allocated_heapregions_length = 0
  max_length() = 2048

expand(8GB) 后：
  _num_committed = 2048
  _allocated_heapregions_length = 2048
  max_length() = 2048
```

---

## 7. 完整初始化流程

```
┌─────────────────────────────────────────────────────────────────┐
│              HeapRegionManager 初始化流程                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. HeapRegionManager() 构造                                    │
│     ├── _regions = G1HeapRegionTable()                          │
│     ├── _free_list = FreeRegionList("Free list")                │
│     ├── _available_map = CHeapBitMap(mtGC)                      │
│     └── _num_committed = 0                                       │
│                                                                  │
│  2. initialize() 调用                                            │
│     ├── 保存 6 个映射器引用                                      │
│     ├── _regions.initialize() ─→ 创建偏置数组                   │
│     │   ├── 计算 bias = 0x1800                                  │
│     │   ├── 分配数组 (2048 * 8 = 16KB)                          │
│     │   └── 计算 _biased_base                                   │
│     └── _available_map.initialize(2048)                          │
│                                                                  │
│  3. expand(8GB) 调用（在 E.1 分析过）                            │
│     ├── commit_regions(0, 2048)                                  │
│     │   └── 6 个 mmap(PROT_READ|PROT_WRITE)                     │
│     ├── 创建 2048 个 HeapRegion 对象                            │
│     ├── _available_map.set_range(0, 2048)                        │
│     └── 加入 _free_list                                          │
│                                                                  │
│  结果：                                                          │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ _regions: [HR[0]*, HR[1]*, ..., HR[2047]*]               │   │
│  │ _free_list: HR[0] ↔ HR[1] ↔ ... ↔ HR[2047]              │   │
│  │ _available_map: [1111...1111] (2048 个 1)               │   │
│  │ _num_committed: 2048                                     │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 8. 关键操作

### 8.1 地址到 Region

```cpp
// heapRegionManager.inline.hpp
inline HeapRegion* HeapRegionManager::addr_to_region(HeapWord* addr) const {
    // O(1) 查找
    return _regions.get_by_address(addr);
}

// 使用示例
HeapWord* obj_addr = 0x600500000;
HeapRegion* hr = _hrm.addr_to_region(obj_addr);
// hr = Region[1] (0x600400000 ~ 0x600800000)
```

### 8.2 分配 Region

```cpp
HeapRegion* HeapRegionManager::allocate_free_region(bool is_old) {
    HeapRegion* hr = _free_list.remove_region(is_old);
    if (hr != NULL) {
        assert(is_available(hr->hrm_index()), "Must be committed");
    }
    return hr;
}
```

### 8.3 释放 Region

```cpp
void HeapRegionManager::insert_into_free_list(HeapRegion* hr) {
    _free_list.add_ordered(hr);
}
```

---

## 9. GDB 验证

```bash
# gdb_hrm.txt
set pagination off

# 断点：initialize
b heapRegionManager.cpp:34
commands
  printf "=== HeapRegionManager::initialize() ===\n"
  continue
end

# 断点：_regions 初始化
b heapRegionManager.cpp:64
commands
  printf "_regions.initialize: start=%p, end=%p\n", reserved.start(), reserved.end()
  printf "  length = %lu regions\n", _regions.length()
  continue
end

# 验证偏置数组
b g1BiasedArray.hpp:113
commands
  printf "BiasedArray: bias=%lu, shift_by=%u\n", bias, shift_by
  printf "  _base=%p, _biased_base=%p\n", base, _biased_base
  continue
end

run
```

**预期输出**：
```
=== HeapRegionManager::initialize() ===
_regions.initialize: start=0x600000000, end=0x800000000
  length = 2048 regions
BiasedArray: bias=6144, shift_by=22
  _base=0x..., _biased_base=0x...
```

---

## 10. 总结

### 10.1 HeapRegionManager 核心职责

| 职责 | 实现 |
|------|------|
| 地址 → Region 映射 | G1HeapRegionTable（偏置数组） |
| 空闲 Region 管理 | FreeRegionList（双向链表） |
| Region 可用性跟踪 | CHeapBitMap（位图） |
| 内存提交/释放 | 6 个 G1RegionToSpaceMapper |

### 10.2 性能优化

| 优化点 | 技术 | 效果 |
|--------|------|------|
| 地址查找 | 偏置数组 | O(1)，无减法 |
| Region 分配 | 双向链表 | O(1) 头尾操作 |
| 可用性判断 | 位图 | O(1)，缓存友好 |

### 10.3 内存开销

```
偏置数组：2048 * 8B = 16KB
位图：    2048 bits = 256B
链表：    2048 * (prev + next) = 32KB（包含在 HeapRegion 中）
总计：    约 48KB（不含 HeapRegion 对象本身）
```
