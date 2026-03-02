# A. 预留虚拟内存 (Reserve Heap)

## 概述

G1CollectedHeap::initialize() 的第一步是调用 `Universe::reserve_heap()` 预留虚拟内存。这个过程涉及：

1. **两阶段内存分配策略**: Reserve(预留) → Commit(提交)
2. **压缩指针优化**: 选择最优的堆基址以支持高效的 OOP 编码
3. **mmap() 系统调用**: 预留虚拟地址空间

```
调用链:
G1CollectedHeap::initialize()
└── Universe::reserve_heap(max_byte_size, heap_alignment)
    └── ReservedHeapSpace::ReservedHeapSpace(size, alignment, large, ...)
        └── initialize_compressed_heap()
            └── try_reserve_heap() / try_reserve_range()
                └── mmap(PROT_NONE, ...)
```

---

## 1. 两阶段内存分配策略

### 1.1 Reserve vs Commit

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    两阶段内存分配策略                                    │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  阶段 1: Reserve (预留)                                                  │
│  ┌─────────────────────────────────────────────────────────────┐        │
│  │  mmap(NULL, 8GB, PROT_NONE,                                 │        │
│  │       MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0)   │        │
│  │                                                             │        │
│  │  效果:                                                      │        │
│  │  - 只占用虚拟地址空间                                       │        │
│  │  - 不分配物理内存                                           │        │
│  │  - 不消耗 RSS (Resident Set Size)                           │        │
│  │  - 访问会触发 SIGSEGV                                       │        │
│  └─────────────────────────────────────────────────────────────┘        │
│                              │                                           │
│                              ▼                                           │
│  阶段 2: Commit (提交)                                                   │
│  ┌─────────────────────────────────────────────────────────────┐        │
│  │  mmap(addr, size, PROT_READ | PROT_WRITE,                   │        │
│  │       MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0)       │        │
│  │                                                             │        │
│  │  效果:                                                      │        │
│  │  - 修改页表权限                                             │        │
│  │  - 首次访问触发 page fault，分配物理页                       │        │
│  │  - 开始消耗 RSS                                             │        │
│  └─────────────────────────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.2 为什么使用两阶段策略？

| 优点 | 说明 |
|------|------|
| **按需分配** | 物理内存只在实际使用时才分配 |
| **地址空间连续** | 一次性预留保证虚拟地址连续 |
| **快速启动** | 预留只需更新页表，不涉及物理内存 |
| **支持压缩指针** | 可以选择最优的基地址 |

---

## 2. 核心数据结构

### 2.1 ReservedSpace

```cpp
// src/hotspot/share/memory/virtualspace.hpp
class ReservedSpace {
protected:
  char*  _base;             // 内存起始地址
  size_t _size;             // 堆内存大小
  size_t _noaccess_prefix;  // 保护页前缀大小
  size_t _alignment;        // 对齐要求
  bool   _special;          // 是否使用特殊分配（大页）
  int    _fd_for_heap;      // 堆文件描述符（持久内存用）
};
```

### 2.2 ReservedHeapSpace

```cpp
class ReservedHeapSpace : public ReservedSpace {
  // 尝试在指定地址预留堆
  void try_reserve_heap(size_t size, size_t alignment, bool large,
                        char* requested_address);
  
  // 在地址范围内搜索可用位置
  void try_reserve_range(char* highest_start, char* lowest_start, ...);
  
  // 压缩指针优化的堆分配
  void initialize_compressed_heap(const size_t size, size_t alignment, bool large);
  
  // 创建保护页（用于隐式空指针检查）
  void establish_noaccess_prefix();
};
```

### 2.3 三个内存描述类对比

| 类 | 职责 | 管理生命周期 |
|---|------|-------------|
| **MemRegion** | 轻量级内存范围描述 | ❌ 不管理 |
| **ReservedSpace** | 虚拟地址空间管理 | ✅ 管理预留 |
| **G1RegionToSpaceMapper** | 物理内存映射管理 | ✅ 管理提交 |

```
关系:
┌─────────────────────────────────────────────────────────────────────────┐
│  ReservedSpace                                                          │
│  ├─ 调用 mmap(PROT_NONE) 预留虚拟地址                                   │
│  └─ 传递给 G1RegionToSpaceMapper                                        │
│                                                                          │
│  G1RegionToSpaceMapper                                                   │
│  ├─ 保存 ReservedSpace                                                  │
│  ├─ 按需调用 mmap(PROT_READ|WRITE) 提交                                 │
│  └─ Region 粒度管理                                                     │
│                                                                          │
│  MemRegion                                                               │
│  └─ 仅描述 (start, size)，传参用                                        │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 压缩指针与堆地址选择

### 3.1 三种压缩指针模式

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       压缩指针模式对比                                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  1. Unscaled 模式 (堆 ≤ 4GB)                                            │
│     ┌─────────────────────────────────────────────────────┐             │
│     │  64位地址直接截断为32位                              │             │
│     │  无需任何计算                                        │             │
│     │                                                      │             │
│     │  编码: narrow_oop = (uint32_t)oop                    │             │
│     │  解码: oop = (uint64_t)narrow_oop                    │             │
│     │                                                      │             │
│     │  性能: 最优 (零开销)                                 │             │
│     └─────────────────────────────────────────────────────┘             │
│                                                                          │
│  2. ZeroBased 模式 (4GB < 堆 ≤ 32GB)                                    │
│     ┌─────────────────────────────────────────────────────┐             │
│     │  地址右移3位（因为对象8字节对齐）                     │             │
│     │  32位可表示 2^32 × 8 = 32GB                          │             │
│     │                                                      │             │
│     │  编码: narrow_oop = oop >> 3                         │             │
│     │  解码: oop = narrow_oop << 3                         │             │
│     │                                                      │             │
│     │  性能: 较优 (一次位移)                               │             │
│     └─────────────────────────────────────────────────────┘             │
│                                                                          │
│  3. HeapBased 模式 (堆基址非零)                                         │
│     ┌─────────────────────────────────────────────────────┐             │
│     │  需要加上基地址                                      │             │
│     │                                                      │             │
│     │  编码: narrow_oop = (oop - base) >> 3                │             │
│     │  解码: oop = (narrow_oop << 3) + base                │             │
│     │                                                      │             │
│     │  性能: 次优 (位移 + 加减法)                          │             │
│     └─────────────────────────────────────────────────────┘             │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.2 堆地址选择策略

```cpp
// src/hotspot/share/memory/virtualspace.cpp:540
void ReservedHeapSpace::initialize_compressed_heap(...) {
  // 关键常量
  // HeapBaseMinAddress = 2GB      (堆最低起始地址)
  // UnscaledOopHeapMax = 4GB      (Unscaled 模式上限)
  // OopEncodingHeapMax = 32GB     (压缩指针上限)
  // CompressedClassSpaceSize = 1GB (类元数据空间)
  
  // 策略 1: 尝试 Unscaled 模式 (堆 ≤ 2GB)
  if (2GB + size <= 4GB) {
    try_reserve_range(4GB - size, 2GB, ...);  // 从高到低搜索
  }
  
  // 策略 2: 尝试 ZeroBased 模式 (堆 ≤ 29GB)
  if (2GB + size <= 31GB && (_base == NULL || ...)) {
    try_reserve_range(31GB - size, 2GB, ...);  // 从高到低搜索
  }
  
  // 策略 3: 任意地址（HeapBased 模式）
  if (_base == NULL) {
    try_reserve_heap(size + noaccess_prefix, alignment, large, NULL);
  }
}
```

### 3.3 地址搜索图解

```
虚拟地址空间布局:
┌─────────────────────────────────────────────────────────────────────────┐
│  0GB        2GB        4GB                    31GB    32GB              │
│   │          │          │                       │       │               │
│   ▼          ▼          ▼                       ▼       ▼               │
├───┼──────────┼──────────┼───────────────────────┼───────┤               │
│   │  系统    │          │                       │ Class │               │
│   │  保留    │ Unscaled │      ZeroBased        │ Space │               │
│   │  (不用)  │  范围    │        范围           │ (1GB) │               │
│   │          │ (≤2GB堆)│     (≤29GB堆)         │       │               │
└───┴──────────┴──────────┴───────────────────────┴───────┘               │
                                                                           │
8GB 堆的分配示例:                                                          │
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│  搜索方向: 高地址 → 低地址                                              │
│                                                                          │
│  highest_start = 31GB - 8GB = 23GB                                      │
│  lowest_start = 2GB                                                     │
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  2GB          8GB         16GB        23GB        31GB          │   │
│  │   │           │            │           │           │            │   │
│   │   ▼           ▼            ▼           ▼           ▼            │   │
│   │   ├───────────┼────────────┼───────────┼───────────┤            │   │
│   │   │           │            │  ┌────────────────────┐            │   │
│   │   │           │            │  │    8GB 堆          │            │   │
│   │   │           │            │  │  (首选位置)        │            │   │
│   │   │           │            │  └────────────────────┘            │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│  ZeroBased 模式: base=0, shift=3                                        │
│  narrow_oop = oop >> 3                                                  │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.4 高级内存特性

#### 3.4.1 大页支持 (Huge Pages)
```cpp
// 大页配置检测
bool use_large_pages = UseLargePages && 
                       is_aligned(alignment, os::large_page_size());

// 透明大页 (THP) 支持
if (UseTransparentHugePages) {
    // 由操作系统自动管理大页
    // 通常 2MB 或 1GB 页面
}

// 显式大页 (Explicit Huge Pages)
if (UseHugeTLBFS) {
    // 预先分配的大页文件系统
    // 需要 root 权限配置
}
```

#### 3.4.2 NUMA 感知分配
```cpp
// NUMA 节点感知的内存分配
if (UseNUMA) {
    // 为每个 NUMA 节点分别预留内存
    // 优先在本地节点分配对象
    os::numa_make_global((char*)base, size);
}
```

#### 3.4.3 内存保护页
```cpp
// 隐式空指针检查保护页
if (UseGuardPages) {
    // 在堆起始处放置不可访问的保护页
    // 访问 NULL 指针时触发 SIGSEGV
    mprotect((void*)base, page_size, PROT_NONE);
}
```

---

## 4. 源码分析

### 4.1 Universe::reserve_heap()

```cpp
// src/hotspot/share/memory/universe.cpp:1031
ReservedSpace Universe::reserve_heap(size_t heap_size, size_t alignment) {
  // 1. 对齐堆大小
  size_t total_reserved = align_up(heap_size, alignment);
  
  // 2. 检查是否使用大页
  bool use_large_pages = UseLargePages && 
                         is_aligned(alignment, os::large_page_size());
  
  // 3. 创建 ReservedHeapSpace（触发 mmap）
  ReservedHeapSpace total_rs(total_reserved, alignment, 
                             use_large_pages, AllocateHeapAt);
  
  // 4. 检查分配结果
  if (total_rs.is_reserved()) {
    // 5. 设置压缩指针基地址
    if (UseCompressedOops) {
      Universe::set_narrow_oop_base(
        (address)total_rs.compressed_oop_base());
    }
    return total_rs;
  }
  
  // 分配失败，退出 JVM
  vm_exit_during_initialization("Could not reserve enough space...");
}
```

### 4.2 G1CollectedHeap 调用

```cpp
// src/hotspot/share/gc/g1/g1CollectedHeap.cpp:1701
ReservedSpace heap_rs = Universe::reserve_heap(
    max_byte_size,      // -Xmx 指定的大小 (8GB)
    heap_alignment      // 堆对齐 (通常为 Region 大小的倍数)
);

// 保存堆范围到 _reserved (MemRegion)
initialize_reserved_region(
    (HeapWord*)heap_rs.base(), 
    (HeapWord*)(heap_rs.base() + heap_rs.size())
);
```

---

## 5. Java 堆的位置

### 5.1 进程内存布局

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         进程虚拟地址空间                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  低地址                                                     高地址      │
│  ─────────────────────────────────────────────────────────────────►     │
│                                                                          │
│  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────────────────────┐ ┌──────┐          │
│  │ 代码 │ │ 数据 │ │ C堆  │ │      映射区          │ │  栈  │          │
│  │ 段   │ │ 段   │ │ brk  │ │      (mmap)          │ │      │          │
│  └──────┘ └──────┘ └──────┘ └──────────────────────┘ └──────┘          │
│                              │                      │                    │
│                              │   Java 堆在这里!    │                    │
│                              │   (通过 mmap 分配)   │                    │
│                              └──────────────────────┘                    │
│                                                                          │
│  重要澄清:                                                               │
│  - Java 堆 ≠ C 堆 (brk/sbrk 管理的区域)                                 │
│  - Java 堆位于映射区 (mmap 分配的匿名映射)                              │
│  - 这允许 JVM 选择最优的基地址以支持压缩指针                            │
└─────────────────────────────────────────────────────────────────────────┘
```

### 5.2 mmap 参数详解

```cpp
// JVM 预留堆内存的典型调用
mmap(
    preferred_addr,              // 期望的地址（为了压缩指针优化）
    max_heap_size,               // -Xmx 指定的大小
    PROT_NONE,                   // 先不可访问！只是预留地址空间
    MAP_PRIVATE |                // 私有映射，写时复制
    MAP_ANONYMOUS |              // 匿名映射，不关联文件
    MAP_NORESERVE,               // 不预留 swap 空间
    -1,                          // 匿名映射，不关联文件
    0                            // 偏移量
);
```

| 参数 | 值 | 含义 |
|------|-----|------|
| `PROT_NONE` | 0 | 不可读、不可写、不可执行 |
| `MAP_PRIVATE` | 私有 | 写时复制，修改不影响其他进程 |
| `MAP_ANONYMOUS` | 匿名 | 不关联文件，内存初始化为 0 |
| `MAP_NORESERVE` | 不预留 | 允许过量分配，不检查 swap |

---

## 6. GDB 验证

### 6.1 查看预留的堆空间

```gdb
# 查看 G1CollectedHeap 的 _reserved 字段
(gdb) p _g1_heap->_reserved
$1 = {
  _start = 0x600000000,      # 堆起始地址 (24GB)
  _word_size = 1073741824    # 堆大小 (8GB / 8 = 1G words)
}

# 验证地址
(gdb) p/x 0x600000000
$2 = 0x600000000  # 24GB，在 ZeroBased 范围内

# 计算堆结束地址
(gdb) p/x 0x600000000 + 8*1024*1024*1024
$3 = 0x800000000  # 32GB，刚好在 OopEncodingHeapMax 边界
```

### 6.2 查看压缩指针配置

```gdb
# 查看 narrow_oop 配置
(gdb) p Universe::_narrow_oop
$4 = {
  _base = 0x0,              # ZeroBased 模式，base = 0
  _shift = 3,               # 右移 3 位
  _use_implicit_null_checks = true
}

# 验证模式
# base=0, shift=3 → ZeroBased 模式
```

### 6.3 通过 /proc 查看内存映射

```bash
# 查看 Java 进程的内存映射
cat /proc/<pid>/maps | grep -E "^[0-9a-f]+.*heap"

# 或者查看匿名映射
cat /proc/<pid>/maps | grep anon

# 示例输出:
# 600000000-800000000 ---p 00000000 00:00 0  [预留的 8GB]
```

---

## 7. 内存布局总结

### 7.1 8GB 堆的典型布局

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    8GB 堆的虚拟地址布局                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  0x000000000 (0GB)                                                      │
│       │                                                                  │
│       │  [系统保留区域]                                                  │
│       │                                                                  │
│  0x080000000 (2GB)  ← HeapBaseMinAddress                                │
│       │                                                                  │
│       │  [可用于小堆的 Unscaled 区域]                                    │
│       │                                                                  │
│  0x100000000 (4GB)  ← UnscaledOopHeapMax                                │
│       │                                                                  │
│       │  [空闲区域]                                                      │
│       │                                                                  │
│  0x600000000 (24GB) ← 8GB堆的起始地址 (_base)                           │
│       │                                                                  │
│       │  ┌─────────────────────────────────────────────────────────┐    │
│       │  │                   Java 堆 (8GB)                         │    │
│       │  │                                                         │    │
│       │  │  Region 0 | Region 1 | ... | Region 2047               │    │
│       │  │   4MB      4MB             4MB                         │    │
│       │  └─────────────────────────────────────────────────────────┘    │
│       │                                                                  │
│  0x800000000 (32GB) ← OopEncodingHeapMax                                │
│       │                                                                  │
│       │  [Compressed Class Space 可能在这里]                            │
│       │                                                                  │
│  高地址                                                                  │
└─────────────────────────────────────────────────────────────────────────┘

压缩指针编码/解码:
  base = 0, shift = 3 (ZeroBased 模式)
  
  编码: narrow_oop = oop >> 3
  解码: oop = narrow_oop << 3
  
  例: 对象地址 0x600000100
      narrow_oop = 0x600000100 >> 3 = 0xC0000020
      恢复: 0xC0000020 << 3 = 0x600000100 ✓
```

---

## 8. 关键要点总结

| 要点 | 说明 |
|------|------|
| **两阶段分配** | Reserve(PROT_NONE) → Commit(PROT_READ\|WRITE) |
| **Java堆位置** | 在映射区(mmap)，不是 C 堆(brk) |
| **压缩指针优化** | 优先选择支持 Unscaled/ZeroBased 的地址 |
| **地址搜索** | 从高地址向低地址搜索，优先 ZeroBased |
| **8GB堆典型配置** | base=24GB, ZeroBased模式(shift=3) |

---

## 相关文件

- `src/hotspot/share/memory/universe.cpp` - Universe::reserve_heap()
- `src/hotspot/share/memory/virtualspace.cpp` - ReservedHeapSpace 实现
- `src/hotspot/share/memory/virtualspace.hpp` - ReservedSpace 类定义
- `src/hotspot/share/gc/g1/g1CollectedHeap.cpp` - G1 堆初始化
