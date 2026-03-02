# 5. Metaspace::global_initialize()

> Metaspace（元空间）：JVM 存储类元数据的本地内存区域

## 1. 源码入口

```cpp
// src/hotspot/share/memory/universe.cpp:746
Metaspace::global_initialize();
```

## 2. 什么是 Metaspace？

### 2.1 类元数据的内容

```
类元数据 = 描述 Java 类的所有信息
┌─────────────────────────────────────────────────────────────────────┐
│ 1. 类结构信息：类名、父类、接口列表、修饰符                          │
│ 2. 字段信息：字段名、类型、访问权限、偏移量                          │
│ 3. 方法信息：方法名、参数、返回值、字节码                            │
│ 4. 常量池：字符串常量、数字常量、符号引用                            │
│ 5. 注解信息                                                          │
│ 6. JIT 编译相关数据                                                  │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 为什么不放在 Java 堆？

| 对比 | Java 堆 | Metaspace |
|------|---------|-----------|
| 存储内容 | Java 对象实例 | 类元数据（Klass） |
| 生命周期 | 短，频繁创建销毁 | 长，随类加载器存活 |
| GC 频率 | 频繁 | 仅在类卸载时 |
| 内存位置 | 连续虚拟地址空间 | 本地内存（mmap） |

**分离的好处**：
- 类元数据生命周期长，不适合频繁 GC
- 减少 Full GC 压力
- 单独管理，便于类卸载

### 2.3 Metaspace 的两部分

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Metaspace 内存布局                            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  1. 压缩类空间 (Compressed Class Space) - 64 位系统专用              │
│     位置：紧挨着 Java 堆，0x800000000 ~ 0x840000000                  │
│     大小：默认 1GB（可通过 -XX:CompressedClassSpaceSize 调整）       │
│     内容：Klass 结构（类的元数据描述符）                             │
│     特点：支持压缩类指针（32 位），减少对象头大小                     │
│                                                                      │
│  2. 数据元空间 (Data Metaspace)                                     │
│     位置：本地内存的任意位置                                         │
│     大小：按需分配，受 MaxMetaspaceSize 限制                        │
│     内容：Method、ConstantPool、Bytecode、Annotation 等              │
│     特点：不支持压缩指针，地址可以在任意位置                         │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

## 3. global_initialize() 源码分析

```cpp
// src/hotspot/share/memory/metaspace.cpp:1384
void Metaspace::global_initialize() {
    // 1. 初始化 MetaspaceGC 阈值
    MetaspaceGC::initialize();
    
    // 2. 分配压缩类空间（64 位系统）
    #ifdef _LP64
    if (using_class_space()) {
        char* base = (char*)align_up(Universe::heap()->reserved_region().end(), 
                                      _reserve_alignment);
        allocate_metaspace_compressed_klass_ptrs(base, 0);
    }
    #endif
    
    // 3. 计算首个 Chunk 大小
    _first_chunk_word_size = InitialBootClassLoaderMetaspaceSize / BytesPerWord;  // 4MB
    _first_class_chunk_word_size = MIN2((size_t)MediumChunk*6,
                                        (CompressedClassSpaceSize/BytesPerWord)*2); // 384KB
    
    // 4. 创建数据元空间
    size_t word_size = VIRTUALSPACEMULTIPLIER * _first_chunk_word_size;  // 8MB
    _space_list = new VirtualSpaceList(word_size);
    _chunk_manager_metadata = new ChunkManager(false);
    
    // 5. 创建追踪器
    _tracer = new MetaspaceTracer();
    
    _initialized = true;
}
```

## 4. 核心数据结构

### 4.1 总体架构

```
                          Metaspace 架构图
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                      │
│   ┌──────────────────────────────────────┐  ┌──────────────────────────────────────┐│
│   │       压缩类空间 (Class Space)       │  │      数据元空间 (Data Metaspace)     ││
│   ├──────────────────────────────────────┤  ├──────────────────────────────────────┤│
│   │                                      │  │                                      ││
│   │  VirtualSpaceList (_class_space_list)│  │  VirtualSpaceList (_space_list)      ││
│   │           │                          │  │           │                          ││
│   │           ▼                          │  │           ▼                          ││
│   │  ┌─────────────────┐                 │  │  ┌─────────────────┐                 ││
│   │  │VirtualSpaceNode │                 │  │  │VirtualSpaceNode │                 ││
│   │  │   (1GB 预留)    │                 │  │  │   (8MB 预留)    │                 ││
│   │  └────────┬────────┘                 │  │  └────────┬────────┘                 ││
│   │           │                          │  │           │                          ││
│   │           ▼                          │  │           ▼                          ││
│   │      ┌────────┐                      │  │      ┌────────┐                      ││
│   │      │ Chunk  │ ...                  │  │      │ Chunk  │ ...                  ││
│   │      └────────┘                      │  │      └────────┘                      ││
│   │                                      │  │                                      ││
│   │  ChunkManager (_chunk_manager_class) │  │  ChunkManager (_chunk_manager_meta)  ││
│   │  管理空闲 Chunk 的回收和重用         │  │  管理空闲 Chunk 的回收和重用         ││
│   │                                      │  │                                      ││
│   └──────────────────────────────────────┘  └──────────────────────────────────────┘│
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 VirtualSpaceList

```cpp
// src/hotspot/share/memory/metaspace/virtualSpaceList.hpp:39
class VirtualSpaceList : public CHeapObj<mtClass> {
    VirtualSpaceNode* _virtual_space_list;      // 链表头
    VirtualSpaceNode* _current_virtual_space;   // 当前使用的节点
    
    bool _is_class;                // 是否是类空间
    size_t _reserved_words;        // 总预留字数
    size_t _committed_words;       // 总已提交字数
    size_t _virtual_space_count;   // 节点数量
    
    // 地址范围（用于快速判断指针是否属于此空间）
    address _envelope_lo;
    address _envelope_hi;
};
```

### 4.3 VirtualSpaceNode

```cpp
// src/hotspot/share/memory/metaspace/virtualSpaceNode.hpp:42
class VirtualSpaceNode : public CHeapObj<mtClass> {
    VirtualSpaceNode* _next;       // 链表指针
    const bool _is_class;          // 是否是类空间
    
    ReservedSpace _rs;             // 预留空间
    VirtualSpace _virtual_space;   // 虚拟空间（提交管理）
    MetaWord* _top;                // 当前分配位置
    uintx _container_count;        // 包含的 Chunk 数量
    
    OccupancyMap* _occupancy_map;  // 占用位图（用于合并）
};
```

### 4.4 ChunkManager（空闲 Chunk 管理）

```cpp
// src/hotspot/share/memory/metaspace/chunkManager.hpp:44
class ChunkManager : public CHeapObj<mtInternal> {
    // 按大小分类的空闲链表
    ChunkList _free_chunks[NumberOfFreeLists];
    //   [0] SpecializedChunk  (128 字)
    //   [1] SmallChunk        (512 字)
    //   [2] MediumChunk       (8K 字)
    
    // 巨型 Chunk 用树结构管理
    ChunkTreeDictionary _humongous_dictionary;
    
    const bool _is_class;
    size_t _free_chunks_total;    // 空闲 Chunk 总大小
    size_t _free_chunks_count;    // 空闲 Chunk 数量
};
```

### 4.5 Chunk 大小分类

| 类型 | 大小（字） | 大小（字节） | 用途 |
|------|----------|-------------|------|
| SpecializedChunk | 128 | 1 KB | 小类加载器 |
| SmallChunk | 512 | 4 KB | 普通类加载器 |
| MediumChunk | 8K | 64 KB | 大型类加载器 |
| HumongousChunk | >8K | >64 KB | 特殊大对象 |

## 5. 压缩类空间分配

### 5.1 地址选择策略

```cpp
// src/hotspot/share/memory/metaspace.cpp:1080
void Metaspace::allocate_metaspace_compressed_klass_ptrs(char* requested_addr, address cds_base) {
    // 目标：在堆末尾紧接着分配 1GB
    // requested_addr = 0x800000000（堆末尾，32GB 位置）
    
    ReservedSpace metaspace_rs = ReservedSpace(
        compressed_class_space_size(),    // 1GB
        _reserve_alignment,               // 对齐
        false,                            // 不用大页
        requested_addr                    // 请求地址
    );
    
    // 如果请求地址分配失败，尝试其他策略...
}
```

### 5.2 8GB 堆的典型布局

```
虚拟地址空间布局（-Xms8G -Xmx8G）
┌─────────────────────────────────────────────────────────────────────┐
│                                                                      │
│  0x000000000  ┌─────────────────────────────────────────────────┐   │
│               │                   低地址区域                      │   │
│               │              (可执行文件、共享库等)               │   │
│  0x600000000  ├─────────────────────────────────────────────────┤   │
│               │                                                  │   │
│               │                 Java 堆 (8 GB)                   │   │
│               │            0x600000000 ~ 0x800000000             │   │
│               │                                                  │   │
│  0x800000000  ├─────────────────────────────────────────────────┤   │
│               │                                                  │   │
│               │            压缩类空间 (1 GB)                      │   │
│               │            0x800000000 ~ 0x840000000             │   │
│               │           存储 Klass 结构（类元数据）             │   │
│               │                                                  │   │
│  0x840000000  └─────────────────────────────────────────────────┘   │
│                                                                      │
│                          ... 中间空隙 ...                            │
│                                                                      │
│  0x7fffc29f0000  ┌─────────────────────────────────────────────┐    │
│                  │                                              │    │
│                  │          数据元空间 (8 MB 初始)               │    │
│                  │         存储 Method、ConstantPool 等          │    │
│                  │                                              │    │
│  0x7fffc31f0000  └─────────────────────────────────────────────┘    │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 5.3 压缩类指针编码

```cpp
// 设置编码参数
set_narrow_klass_base_and_shift(metaspace_base, cds_base);

// narrow_klass._base = 0x800000000
// narrow_klass._shift = 0 (因为 1GB < 4GB，不需要移位)

// 编码示例：假设 Klass 位于 0x800001000
narrow_klass = (0x800001000 - 0x800000000) >> 0
             = 0x1000
             = 4096 (32 位值存储在对象头)

// 解码
klass_address = 0x800000000 + (4096 << 0)
              = 0x800001000 ✓
```

## 6. 数据元空间初始化

### 6.1 首个 Chunk 大小计算

```cpp
// Bootstrap ClassLoader 的首个 Chunk
_first_chunk_word_size = InitialBootClassLoaderMetaspaceSize / BytesPerWord;
// = 4MB / 8 = 512K 字 = 4MB
// 用于存储 JDK 核心类（java.lang.Object、java.lang.String 等）

// 首个类 Chunk
_first_class_chunk_word_size = MIN2((size_t)MediumChunk*6,
                                    (CompressedClassSpaceSize/BytesPerWord)*2);
// = MIN2(8K*6, 1GB/8*2) = MIN2(48K, 256M) = 48K 字 = 384KB
// 设计得比 MediumChunk 大，避免放入 Medium 空闲链表
```

### 6.2 VirtualSpaceList 创建

```cpp
// 初始虚拟空间 = 2 * 首个 Chunk = 8MB
size_t word_size = VIRTUALSPACEMULTIPLIER * _first_chunk_word_size;

// 创建数据元空间的 VirtualSpaceList
_space_list = new VirtualSpaceList(word_size);  // 预留 8MB

// 创建 ChunkManager
_chunk_manager_metadata = new ChunkManager(false);  // false = 非类空间
```

构造函数流程：
```cpp
VirtualSpaceList::VirtualSpaceList(size_t word_size) :
    _is_class(false),
    _virtual_space_list(NULL),
    _current_virtual_space(NULL),
    _reserved_words(0),
    _committed_words(0),
    _virtual_space_count(0) {
    
    MutexLockerEx cl(MetaspaceExpand_lock, Mutex::_no_safepoint_check_flag);
    create_new_virtual_space(word_size);  // 创建 8MB 虚拟空间
}
```

## 7. MetaspaceGC 阈值

```cpp
// src/hotspot/share/memory/metaspace.cpp:185
void MetaspaceGC::initialize() {
    // 启动时设为最大值，避免启动期间触发 GC
    _capacity_until_GC = MaxMetaspaceSize;
}

void MetaspaceGC::post_initialize() {
    // 启动完成后，设置合理阈值
    _capacity_until_GC = MAX2(MetaspaceUtils::committed_bytes(), MetaspaceSize);
}
```

为什么启动时设为最大值？
- JVM 启动需要加载大量核心类
- 此时触发 GC 会严重影响启动性能
- 启动完成后（`universe_post_init`）重新设置

## 8. 初始化后的状态

```
Metaspace 初始化完成后
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                      │
│  压缩类空间 (_class_space_list)                                                      │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐│
│  │ VirtualSpaceList:                                                               ││
│  │   _is_class = true                                                              ││
│  │   _reserved_words = 134,217,728 (1GB)                                           ││
│  │   _committed_words = 0 (按需提交)                                               ││
│  │   _virtual_space_count = 1                                                      ││
│  │   _envelope_lo = 0x800000000                                                    ││
│  │   _envelope_hi = 0x840000000                                                    ││
│  │                                                                                 ││
│  │   VirtualSpaceNode:                                                             ││
│  │     _rs._base = 0x800000000, _rs._size = 1GB                                    ││
│  │     _top = 0x800000000                                                          ││
│  │     _container_count = 0                                                        ││
│  └─────────────────────────────────────────────────────────────────────────────────┘│
│                                                                                      │
│  数据元空间 (_space_list)                                                            │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐│
│  │ VirtualSpaceList:                                                               ││
│  │   _is_class = false                                                             ││
│  │   _reserved_words = 1,048,576 (8MB)                                             ││
│  │   _committed_words = 0 (按需提交)                                               ││
│  │   _virtual_space_count = 1                                                      ││
│  │                                                                                 ││
│  │   VirtualSpaceNode:                                                             ││
│  │     _rs._base = 0x7fffc29f0000 (某个高地址)                                     ││
│  │     _rs._size = 8MB                                                             ││
│  └─────────────────────────────────────────────────────────────────────────────────┘│
│                                                                                      │
│  ChunkManager:                                                                       │
│    _chunk_manager_class: 管理类空间空闲 Chunk                                        │
│    _chunk_manager_metadata: 管理数据空间空闲 Chunk                                   │
│    初始都为空（没有空闲 Chunk）                                                      │
│                                                                                      │
│  MetaspaceGC:                                                                        │
│    _capacity_until_GC = MaxMetaspaceSize (启动期间不触发 GC)                         │
│                                                                                      │
│  MetaspaceTracer: 用于 JFR 事件报告                                                  │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

## 9. GDB 验证

```gdb
# 断点
b Metaspace::global_initialize

# 执行到初始化完成
(gdb) finish

# 查看类空间
(gdb) p Metaspace::_class_space_list
$1 = (metaspace::VirtualSpaceList *) 0x7ffff0c8ca80

(gdb) p *Metaspace::_class_space_list
$2 = {
  _virtual_space_list = 0x7ffff0c8cb00,
  _current_virtual_space = 0x7ffff0c8cb00,
  _is_class = true,
  _reserved_words = 134217728,  # 1GB / 8
  _committed_words = 0,
  _virtual_space_count = 1,
  _envelope_lo = 0x800000000,
  _envelope_hi = 0x840000000
}

# 查看数据元空间
(gdb) p Metaspace::_space_list
$3 = (metaspace::VirtualSpaceList *) 0x7ffff0c8d000

(gdb) p *Metaspace::_space_list
$4 = {
  _is_class = false,
  _reserved_words = 1048576,    # 8MB / 8
  _committed_words = 0,
  _virtual_space_count = 1
}

# 查看 GC 阈值
(gdb) p MetaspaceGC::_capacity_until_GC
$5 = 18446744073709551615  # MaxMetaspaceSize（无限大）
```

## 10. JVM 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-XX:MetaspaceSize` | 21MB | 初始 Metaspace 大小（触发 GC 的阈值） |
| `-XX:MaxMetaspaceSize` | 无限制 | 最大 Metaspace 大小 |
| `-XX:CompressedClassSpaceSize` | 1GB | 压缩类空间大小 |
| `-XX:InitialBootClassLoaderMetaspaceSize` | 4MB | Bootstrap ClassLoader 初始大小 |

查看日志：
```bash
java -Xlog:metaspace* -version
# 输出 Metaspace 分配和 GC 信息
```

## 11. 设计要点总结

| 特性 | 实现 |
|------|------|
| 两部分分离 | 类空间（固定位置）+ 数据空间（任意位置） |
| 按需提交 | 只预留虚拟地址，按需 commit 物理内存 |
| Chunk 复用 | ChunkManager 管理空闲 Chunk，类卸载时回收 |
| 压缩指针 | 类空间紧挨堆末尾，支持 32 位压缩类指针 |
| 启动优化 | 启动期间 GC 阈值设为最大，避免启动 GC |

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文分析 **5. Metaspace::global_initialize()** 的初始化过程：JVM 启动时该组件如何被创建、配置和激活，以及初始化顺序的约束关系。

### 0.2 为什么需要？

JVM 初始化顺序有严格的依赖关系——某些组件必须在其他组件之前初始化。理解初始化顺序有助于排查启动失败问题，也能理解各组件的设计约束。

### 0.3 怎么解决？

追踪初始化函数的调用链，分析每个初始化步骤的前置条件和后置效果，识别关键的初始化顺序约束。

### 0.4 为什么这样设计？

初始化顺序的设计原则：「被依赖的先初始化」。例如内存管理必须在 GC 之前初始化，GC 必须在类加载之前初始化。

---


## 下一步

Metaspace 是类元数据存储的基础设施，后续加载的每个类都会在这里分配空间。

接下来可以分析：
- **6. 性能计数器初始化** - MetaspaceCounters
- **9. ClassLoaderData::init_null_class_loader_data()** - Bootstrap ClassLoader
- **11. SymbolTable::create_table()** - 符号表
