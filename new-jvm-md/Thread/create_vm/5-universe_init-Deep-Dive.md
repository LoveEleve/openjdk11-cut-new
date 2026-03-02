# universe_init() 深度分析

> 源码：`src/hotspot/share/memory/universe.cpp:681-873`（193 行）
> 调用位置：`init_globals()` → `universe_init()`（init.cpp:119）
> 环境：`-Xms8g -Xmx8g -XX:+UseG1GC`，G1 Region = 4MB
> 原则：**每个调用都说清楚：做了什么、创建了什么、为什么需要、GDB 实际数据**

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文是对 **universe_init() 深度分析** 的深度源码分析：从数据结构到算法流程，逐层剖析其实现原理，并通过 GDB 验证关键结论。

### 0.2 为什么需要？

深入理解 JVM 内部实现，不仅能帮助排查生产问题，更能建立对 JVM 行为的精确预测能力——知道『为什么』比知道『是什么』更重要。

### 0.3 怎么解决？

采用「数据结构 → 算法流程 → GDB 验证」三步法：先完整分析所有涉及的数据结构（字段含义/sizeof/生命周期），再分析算法流程（每步有 why），最后用 GDB 实际验证关键结论。

### 0.4 为什么这样设计？

JVM 的每个设计决策都有其历史背景和性能考量。本文在分析每个关键设计时，都会解释「为什么这样而不是那样」，帮助读者建立设计直觉。

---


## 一句话总结

`universe_init()` 是 JVM 启动过程中**最重量级**的单个初始化函数——它创建了 Java 堆（8GB mmap）、元空间、压缩指针配置、符号表、字符串表、Bootstrap ClassLoaderData。这些是 JVM 能够加载和运行 Java 代码的**物质基础**。

---

## 调用链全景图

```
universe_init()                                         // universe.cpp:681
│
├── [1] JavaClasses::compute_hard_coded_offsets()        // javaClasses.cpp:4462
│        └─ 计算 Boxing 类和 Reference 类的字段偏移量
│
├── [2] ★★★ Universe::initialize_heap()                 // universe.cpp:924
│   │
│   ├── [2.1] Universe::create_heap()                   // universe.cpp:876
│   │   └── GCConfig::arguments()->create_heap()        // 多态分发
│   │       └── G1Arguments::create_heap()              // g1Arguments.cpp:178
│   │           └── create_heap_with_policy<G1CollectedHeap, G1CollectorPolicy>()
│   │               ├── new G1CollectorPolicy()         // 创建策略对象
│   │               ├── policy->initialize_all()        // 初始化策略参数
│   │               └── new G1CollectedHeap(policy)     // 构造堆对象（还没分配内存！）
│   │
│   ├── [2.2] ★ _collectedHeap->initialize()            // G1CollectedHeap::initialize()
│   │   └── 真正的堆初始化：mmap 8GB、创建 2048 个 HeapRegion、CardTable、RemSet...
│   │       （已在 jvm-md/Universe/ 中详细分析，此处不展开）
│   │
│   ├── [2.3] TLAB max_size 设置
│   │
│   ├── [2.4] ★ 压缩 OOP 配置（base + shift）
│   │
│   └── [2.5] TLAB startup_initialization()
│
├── [3] SystemDictionary::initialize_oop_storage()       // systemDictionary.cpp:3045
│        └─ 创建 VM 弱引用容器（OopStorage）
│
├── [4] ★★ Metaspace::global_initialize()                // metaspace.cpp:1384
│   ├── MetaspaceGC::initialize()
│   ├── allocate_metaspace_compressed_klass_ptrs()       // 压缩类空间 1GB
│   ├── new VirtualSpaceList()                           // 数据元空间 8MB
│   └── new ChunkManager()
│
├── [5] MetaspaceCounters + CompressedClassSpaceCounters  // 8 个性能计数器
│
├── [6] AOTLoader::universe_init()                        // AOT 相关（我们环境无效）
│
├── [7] ClassLoaderData::init_null_class_loader_data()    // Bootstrap ClassLoader 数据
│
├── [8] 6 × new LatestMethodCache()                       // 方法缓存
│
├── [9] SymbolTable::create_table()                       // 符号表
│
├── [10] StringTable::create_table()                      // 字符串表
│
└── [11] ResolvedMethodTable::create_table()              // 已解析方法表
```

---

## 逐步深入分析

### [1] JavaClasses::compute_hard_coded_offsets()

**源码**：`javaClasses.cpp:4462-4473`

```cpp
void JavaClasses::compute_hard_coded_offsets() {
  // java.lang.boxing_object (Integer, Long 等包装类)
  java_lang_boxing_object::value_offset =
      member_offset(java_lang_boxing_object::hc_value_offset);
  java_lang_boxing_object::long_value_offset =
      align_up(member_offset(java_lang_boxing_object::hc_value_offset), BytesPerLong);

  // java.lang.ref.Reference (SoftReference, WeakReference 等)
  java_lang_ref_Reference::referent_offset =
      member_offset(java_lang_ref_Reference::hc_referent_offset);
  java_lang_ref_Reference::queue_offset =
      member_offset(java_lang_ref_Reference::hc_queue_offset);
  java_lang_ref_Reference::next_offset =
      member_offset(java_lang_ref_Reference::hc_next_offset);
  java_lang_ref_Reference::discovered_offset =
      member_offset(java_lang_ref_Reference::hc_discovered_offset);
}
```

**做了什么**：根据硬编码的偏移量常量（`hc_XXX_offset`），计算 Boxing 类和 Reference 类中**特定字段在 Java 对象中的字节偏移量**。

**为什么需要**：JVM 在 C++ 层频繁访问这些 Java 对象的字段：
- `Integer.value`：拆箱时需要直接读取
- `Reference.referent`：GC 引用处理时需要直接读取
- `Reference.discovered`：GC 引用发现链需要直接写入

这些偏移量是**硬编码**的，意味着如果 Java 层修改了这些类的字段布局（比如增加了字段），JVM 需要同步修改。但这些是 JDK 核心类，布局很稳定。

**为什么在堆创建之前**：后续 `initialize_heap()` → `G1CollectedHeap::initialize()` 内部需要配置引用处理器（`ReferenceProcessor`），引用处理器工作时需要知道 `Reference.referent` 等字段的偏移量。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐ 一般 | 前置依赖，代码量很小 |

---

### [2] Universe::initialize_heap() ⭐⭐⭐⭐⭐

**源码**：`universe.cpp:924-1009`（85 行，但内部调用了 `G1CollectedHeap::initialize()` 那个巨型函数）

这是 `universe_init()` 中最重要的调用，负责创建和配置 Java 堆。

#### [2.1] Universe::create_heap() — 创建堆对象

```cpp
// universe.cpp:876-879
CollectedHeap* Universe::create_heap() {
  assert(_collectedHeap == NULL, "Heap already created");
  return GCConfig::arguments()->create_heap();
}
```

`GCConfig::arguments()` 返回 `G1Arguments*`（因为我们指定了 `-XX:+UseG1GC`）。多态调用 `G1Arguments::create_heap()`：

```cpp
// g1Arguments.cpp:178-180
CollectedHeap* G1Arguments::create_heap() {
  return create_heap_with_policy<G1CollectedHeap, G1CollectorPolicy>();
}
```

展开模板：

```cpp
// gcArguments.inline.hpp:30-34
G1CollectorPolicy* policy = new G1CollectorPolicy();
policy->initialize_all();      // 计算分代比例、暂停时间目标等
return new G1CollectedHeap(policy);
```

**注意：这一步只是在 C 堆上分配了一个 `G1CollectedHeap` 对象（1864 字节），还没有 mmap 8GB 的堆内存！** 真正的内存分配在下一步。

**GC 选择的多态设计**：

```
GCArguments (抽象基类)
├── G1Arguments          → create_heap_with_policy<G1CollectedHeap, G1CollectorPolicy>()
├── SerialArguments       → create_heap_with_policy<SerialHeap, MarkSweepPolicy>()
├── ParallelArguments     → create_heap_with_policy<ParallelScavengeHeap, GenerationSizer>()
├── CMSArguments          → create_heap_with_policy<CMSHeap, ConcurrentMarkSweepPolicy>()
├── ZArguments            → create_heap_with_policy<ZCollectedHeap, ZCollectorPolicy>()
├── ShenandoahArguments   → create_heap_with_policy<ShenandoahHeap, ShenandoahCollectorPolicy>()
└── EpsilonArguments      → create_heap_with_policy<EpsilonHeap, EpsilonCollectorPolicy>()
```

GC 选择在 `GCConfig::select_gc()` 中完成：
- 用户指定了 GC → 直接用
- 用户没指定 → 服务器级别默认 **G1GC**，客户端级别默认 SerialGC
- 如果指定了多个 GC → 报错

| 重要性 | 分类 |
|--------|------|
| ⭐⭐⭐⭐⭐ | GC 多态的核心，决定了堆的具体实现 |

#### [2.2] _collectedHeap->initialize() — 真正的堆初始化

```cpp
jint status = _collectedHeap->initialize();
```

多态调用 `G1CollectedHeap::initialize()`（`g1CollectedHeap.cpp:1588`）。这是一个约 300 行的函数，做了以下事情：
- `mmap` 预留 8GB 连续虚拟地址空间
- 创建 2048 个 `HeapRegion` 对象（每个 432 字节）
- 创建 `G1CardTable`（16MB）
- 创建 `G1RemSet`
- 创建 `G1ConcurrentMark`
- 创建 GC 并行工作线程
- 创建 `G1ConcurrentRefine` 线程
- ...

**这部分已在 `jvm-md/Universe/` 系列文档中详细分析，此处不重复展开。**

#### [2.3] TLAB max_size 设置

```cpp
ThreadLocalAllocBuffer::set_max_size(Universe::heap()->max_tlab_size());
```

`G1CollectedHeap::max_tlab_size()` 返回 `RegionSize / 2 / HeapWordSize`。

在我们环境下：
- RegionSize = 4MB
- max_tlab_size = 4MB / 2 = 2MB（即 262144 words）

**为什么 TLAB 最大是 Region 的一半**：
- TLAB 必须完整放入一个 Region
- G1 中，超过 RegionSize / 2 的对象是 Humongous 对象，需要特殊分配路径
- TLAB 内的对象不能触发 Humongous 逻辑，所以 TLAB 本身必须 < RegionSize / 2

#### [2.4] 压缩 OOP 配置 ⭐⭐⭐⭐

```cpp
if (UseCompressedOops) {
    // 堆 end > 4GB → 需要移位
    if ((uint64_t)heap()->reserved_region().end() > UnscaledOopHeapMax) {
        Universe::set_narrow_oop_shift(LogMinObjAlignmentInBytes);  // shift = 3
    }
    // 堆 end <= 32GB → 可以用 base = 0
    if ((uint64_t)heap()->reserved_region().end() <= OopEncodingHeapMax) {
        Universe::set_narrow_oop_base(0);  // base = NULL
    }
    Universe::set_narrow_ptrs_base(Universe::narrow_oop_base());
}
```

**压缩 OOP 三种模式**：

| 模式 | 条件 | base | shift | 解码公式 |
|------|------|------|-------|----------|
| Unscaled | 堆 end ≤ 4GB | 0 | 0 | `oop = compressed_oop` |
| Zero-based | 4GB < 堆 end ≤ 32GB | 0 | 3 | `oop = compressed_oop << 3` |
| Disjoint/HeapBased | 堆 end > 32GB | 非0 | 3 | `oop = base + (compressed_oop << 3)` |

**在我们环境下**：
- 堆范围：`0x600000000 ~ 0x800000000`
- 堆 end = `0x800000000` = 32GB
- `0x800000000 > UnscaledOopHeapMax(4GB)` → shift = 3 ✓
- `0x800000000 <= OopEncodingHeapMax(32GB)` → base = 0 ✓
- **→ Zero-based 模式**

**为什么 Zero-based 比 HeapBased 快**：
- Zero-based 解码：`oop = compressed_oop << 3`（一条移位指令）
- HeapBased 解码：`oop = base + (compressed_oop << 3)`（一条移位 + 一条加法）
- 对象访问是**最频繁的操作**之一，少一条指令意味着大量 CPU 节省

**为什么 shift = 3**：Java 对象按 8 字节对齐（`ObjectAlignmentInBytes = 8`），所以对象地址的低 3 位永远是 0。压缩时右移 3 位丢掉这些 0，解压时左移 3 位恢复。这样 32 位就能表示 4GB × 8 = 32GB 的地址空间。

**`-Xlog:gc,heap,coops` 可以看到压缩指针模式日志**：
```
[info][gc,heap,coops] Heap address: 0x0000000600000000, size: 8192 MB, Compressed Oops mode: Zero based, Oop shift amount: 3
```

#### [2.5] TLAB startup_initialization()

```cpp
if (UseTLAB) {
    ThreadLocalAllocBuffer::startup_initialization();
}
```

初始化 TLAB 的全局参数：目标重填次数（`_target_refills`）、统计计数器等。每个线程的实际 TLAB 在线程创建时分配。

### [2] GDB 验证——initialize_heap() 关键数据

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
┌─────────────────────────────────────────────────────────────────┐
│ _collectedHeap 地址:       0x7ffff0031bb0                       │
│ sizeof(G1CollectedHeap):   1864 bytes                           │
│                                                                 │
│ reserved._start:           0x600000000 (24GB)                   │
│ reserved end:              0x800000000 (32GB)                   │
│ 堆大小:                    8 GB                                  │
│                                                                 │
│ _hrm._num_committed:       2048 个 Region                       │
│ HeapRegion::GrainBytes:    4,194,304 (4MB)                      │
│ HeapRegion::LogOfHRGrainBytes: 22 (2^22 = 4MB)                 │
│ sizeof(HeapRegion):        432 bytes                            │
│                                                                 │
│ 压缩 OOP 模式:             Zero-based                           │
│ narrow_oop._base:          NULL (0)                             │
│ narrow_oop._shift:         3                                    │
│ narrow_oop._use_implicit_null_checks: 1 (启用)                  │
│                                                                 │
│ TLAB _max_size:            262,144 words = 2,097,152 bytes(2MB) │
└─────────────────────────────────────────────────────────────────┘
```

**`implicit_null_checks` 是什么**：当 Java 代码访问 `obj.field` 时，JVM 不需要显式检查 `obj == null`。而是直接访问内存，如果 obj 是 null（地址为 0），访问 `0 + offset` 会触发 `SIGSEGV`，JVM 捕获信号后抛出 `NullPointerException`。这消除了每次对象访问时的 null 检查分支，是**性能优化**。

---

### [3] SystemDictionary::initialize_oop_storage()

**源码**：`systemDictionary.cpp:3045`

```cpp
void SystemDictionary::initialize_oop_storage() {
  _vm_weak_oop_storage =
    new OopStorage("VM Weak Oop Handles",
                   VMWeakAlloc_lock,
                   VMWeakActive_lock);
}
```

**创建了什么**：一个 `OopStorage` 对象——VM 内部弱引用的集中存储容器。

**为什么需要**：JVM 内部许多地方需要持有对 Java 对象的弱引用（不阻止 GC 回收），例如：
- VM 内部的临时引用
- 反射缓存
- 某些 JVMTI 引用

**OopStorage 的设计**：
```
OopStorage "VM Weak Oop Handles"
├── _active_array → [Block0*, Block1*, Block2*, ...]
│                      ↓         ↓         ↓
│                   ┌──────┐ ┌──────┐ ┌──────┐
│                   │ oop[]│ │ oop[]│ │ oop[]│
│                   │bitmap│ │bitmap│ │bitmap│
│                   └──────┘ └──────┘ └──────┘
├── VMWeakAlloc_lock  → 保护 Block 内的分配/释放
└── VMWeakActive_lock → 保护 _active_array 的修改
```

**两把锁分离的原因**：GC 遍历时只需要 active_lock（读取块列表），分配/释放只需要 alloc_lock。减少锁竞争。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐⭐ 重要 | GC 引用处理的基础设施 |

---

### [4] Metaspace::global_initialize() ⭐⭐⭐⭐

**源码**：`metaspace.cpp:1384-1485`

#### 概述

Metaspace（元空间）存储**类元数据**——类结构、字段信息、方法字节码、常量池等。JDK 8 之前这些数据放在 PermGen（永久代，堆的一部分），JDK 8+ 移到了堆外的 Metaspace，**好处是类元数据不再受制于固定大小的永久代**。

#### 调用序列

```
Metaspace::global_initialize()
├── MetaspaceGC::initialize()                    // 初始化 GC 触发阈值
├── allocate_metaspace_compressed_klass_ptrs()    // 预留 1GB 压缩类空间
├── 计算 _first_chunk_word_size                   // 4MB
├── 计算 _first_class_chunk_word_size             // 384KB
├── new VirtualSpaceList(word_size)               // 创建数据元空间（8MB 虚拟空间）
├── new ChunkManager(false)                       // 创建 Chunk 管理器
└── new MetaspaceTracer()                         // JFR 事件追踪器
```

#### 4.1 压缩类空间分配

```cpp
if (using_class_space()) {
    char* base = (char*)align_up(
        Universe::heap()->reserved_region().end(),
        _reserve_alignment);
    allocate_metaspace_compressed_klass_ptrs(base, 0);
}
```

**做了什么**：在堆末尾（`0x800000000`）紧接着预留 **1GB** 的虚拟地址空间，用于存储 Klass 结构（即类元数据中的类描述信息）。

**为什么 Klass 要单独分配空间**：
- 每个 Java 对象头中有一个指向 Klass 的指针
- 开启 `UseCompressedClassPointers` 时，这个指针被压缩为 32 位
- 要让 32 位能表示所有 Klass 的地址，所有 Klass 必须在同一个连续的地址范围内
- 这个范围就是"压缩类空间"

#### 4.2 数据元空间初始化

```cpp
_first_chunk_word_size = InitialBootClassLoaderMetaspaceSize / BytesPerWord;
// = 4MB / 8 = 524288 words

_first_class_chunk_word_size = MIN2((size_t)MediumChunk*6,
                                   (CompressedClassSpaceSize/BytesPerWord)*2);
// = MIN2(64K*6, 1GB/8*2) = 384KB

size_t word_size = VIRTUALSPACEMULTIPLIER * _first_chunk_word_size;
// = 2 × 524288 = 1048576 words = 8MB

_space_list = new VirtualSpaceList(word_size);  // 预留 8MB 虚拟内存
_chunk_manager_metadata = new ChunkManager(false);
```

**解释**：
- `_first_chunk_word_size = 4MB`：Bootstrap ClassLoader 的第一个 Chunk 大小，用于存储 `java.lang.Object`、`java.lang.String` 等核心类的元数据
- `_first_class_chunk_word_size = 384KB`：压缩类空间的第一个 Chunk
- `VirtualSpaceList`：管理多个 `VirtualSpaceNode`，每个 Node 是一段连续的虚拟内存
- `ChunkManager`：Chunk 空闲列表管理器（类似 ChunkPool，但用于 Metaspace）

#### 4.3 JVM 虚拟地址空间布局

```
JVM 虚拟地址空间布局（标准条件 -Xms8g -Xmx8g -XX:+UseG1GC）

0x000000000 ┌─────────────────────────────────┐
            │         保留区域                  │
0x600000000 ├─────────────────────────────────┤ ← 堆起始
            │                                 │
            │         Java 堆 (8GB)           │
            │     2048 个 HeapRegion × 4MB    │
            │     narrow_oop 地址空间          │
            │                                 │
0x800000000 ├─────────────────────────────────┤ ← 堆结束 = 压缩类空间起始
            │                                 │
            │     压缩类空间 (1GB)             │
            │     存储 Klass 结构              │
            │     narrow_klass 地址空间        │
            │                                 │
0x840000000 ├─────────────────────────────────┤
            │         ... (空隙) ...           │
            │                                 │
0x7fffc29f0000 ├──────────────────────────────┤
            │     数据元空间 (初始 8MB)        │
            │     Method, ConstantPool,       │
            │     Bytecode, Annotations       │
0x7fffc31f0000 └──────────────────────────────┘
```

#### GDB 验证——Metaspace 关键数据

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
┌─────────────────────────────────────────────────────────────────┐
│ _space_list:                   0x7ffff0c8aff0                   │
│ _chunk_manager_metadata:       0x7ffff0c8ba70                   │
│ _first_chunk_word_size:        524,288 words (4MB)              │
│ _first_class_chunk_word_size:  49,152 words (384KB)             │
│                                                                 │
│ UseCompressedClassPointers:    1 (启用)                         │
│ narrow_klass._base:            0x800000000 (= 堆末尾)          │
│ narrow_klass._shift:           0                                │
└─────────────────────────────────────────────────────────────────┘
```

**`narrow_klass._shift = 0` 的含义**：Klass 结构没有对齐要求（不像 Java 对象按 8 字节对齐），所以不需要移位。`compressed_klass = klass_address - base` 就够了。1GB 空间用 32 位表示绰绰有余。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐⭐⭐ 非常重要 | 类加载的存储基础 |

---

### [5] 性能计数器初始化

```cpp
MetaspaceCounters::initialize_performance_counters();
CompressedClassSpaceCounters::initialize_performance_counters();
```

**做了什么**：在 PerfMemory 共享内存中注册 8 个计数器：

| 计数器名称 | 类型 | 说明 |
|-----------|------|------|
| `sun.gc.metaspace.minCapacity` | 常量 | = 0 |
| `sun.gc.metaspace.capacity` | 变量 | 已提交的 Metaspace 大小 |
| `sun.gc.metaspace.maxCapacity` | 变量 | 最大 Metaspace 大小（~1032MB） |
| `sun.gc.metaspace.used` | 变量 | 已使用的 Metaspace 大小 |
| `sun.gc.compressedclassspace.minCapacity` | 常量 | = 0 |
| `sun.gc.compressedclassspace.capacity` | 变量 | 已提交的类空间大小 |
| `sun.gc.compressedclassspace.maxCapacity` | 变量 | = 1GB |
| `sun.gc.compressedclassspace.used` | 变量 | 已使用的类空间大小 |

**怎么看这些数据**：
```bash
# 方式1：jstat
jstat -gc <pid>
# MC=Metaspace Capacity, MU=Metaspace Used
# CCSC=Compressed Class Space Capacity, CCSU=Used

# 方式2：jcmd
jcmd <pid> PerfCounter.print | grep metaspace
```

| 重要性 | 分类 |
|--------|------|
| ⭐⭐ 一般 | 监控基础设施 |

---

### [6] AOTLoader::universe_init()

**源码**：`aotLoader.cpp:171-210`

**做了什么**：如果启用了 AOT（Ahead-of-Time 编译），验证 AOT 库中保存的压缩指针参数与当前 JVM 的一致（shift 值等），然后为每个 AOT 库创建 `AOTCodeHeap` 并加入 CodeCache。

**在我们环境下**：`UseAOT` 默认为 false（JDK 11 中 AOT 是实验性功能），跳过。

| 重要性 | 分类 |
|--------|------|
| ⭐ 不重要 | 实验性功能，默认关闭 |

---

### [7] ClassLoaderData::init_null_class_loader_data()

**做了什么**：为 Bootstrap ClassLoader 创建 `ClassLoaderData` 对象。

Bootstrap ClassLoader 是 JVM 中最特殊的类加载器：
- **用 C++ 实现**，不是 Java 对象
- 在 Java 中 `Class.getClassLoader()` 返回 `null` 表示 Bootstrap
- 负责加载 `java.lang.*`、`java.util.*` 等 JDK 核心类

`ClassLoaderData` 是 JVM 内部跟踪一个类加载器加载了哪些类、使用了多少 Metaspace 的数据结构。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐⭐ 重要 | 类加载体系的起点 |

---

### [8] 6 × LatestMethodCache

```cpp
Universe::_finalizer_register_cache = new LatestMethodCache();
Universe::_loader_addClass_cache    = new LatestMethodCache();
Universe::_pd_implies_cache         = new LatestMethodCache();
Universe::_throw_illegal_access_error_cache = new LatestMethodCache();
Universe::_throw_no_such_method_error_cache = new LatestMethodCache();
Universe::_do_stack_walk_cache      = new LatestMethodCache();
```

**做了什么**：创建 6 个方法缓存对象，此时只是空壳（`_klass = NULL, _method_idnum = -1`），后续在 `Universe::initialize_known_methods()` 中真正初始化。

**缓存的方法**：

| 缓存 | 缓存的 Java 方法 | 用途 |
|------|------------------|------|
| `_finalizer_register_cache` | `Finalizer.register(Object)` | 注册需要 finalize 的对象 |
| `_loader_addClass_cache` | `ClassLoader.addClass(Class)` | 类加载器注册已加载的类 |
| `_pd_implies_cache` | `ProtectionDomain.impliesCreateAccessControlContext()` | 安全检查 |
| `_throw_illegal_access_error_cache` | `Unsafe.throwIllegalAccessError()` | 抛出非法访问异常 |
| `_throw_no_such_method_error_cache` | `Unsafe.throwNoSuchMethodError()` | 抛出方法不存在 |
| `_do_stack_walk_cache` | `AbstractStackWalker.doStackWalk(...)` | 栈遍历回调 |

**为什么要缓存**：这些方法被 JVM 频繁调用（特别是 `Finalizer.register`——每个重写了 `finalize()` 的对象创建时都会调用）。缓存 `Method*` 指针避免每次通过类名+方法名查找。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐ 一般 | 性能优化，空壳创建 |

---

### [9] SymbolTable::create_table() ⭐⭐⭐⭐

> 📖 **深度剖析**：[5A-SymbolTable-Deep-Dive.md](5A-SymbolTable-Deep-Dive.md)

**源码**：`symbolTable.hpp:222-237`

```cpp
static void create_table() {
  assert(_the_table == NULL, "One symbol table allowed.");
  _the_table = new SymbolTable();
  initialize_symbols(symbol_alloc_arena_size);  // 创建 360KB Arena
}
```

**SymbolTable 是什么**：存储 JVM 中所有的 `Symbol`——类名、方法名、字段名、方法签名等的**哈希表**。

**例如**：
- 类名 `"java/lang/Object"` 是一个 Symbol
- 方法名 `"toString"` 是一个 Symbol
- 方法签名 `"()Ljava/lang/String;"` 是一个 Symbol

**为什么需要统一的符号表**：
1. **去重**：相同的字符串只存一份，节省内存
2. **快速比较**：两个 Symbol 指针相等 = 字符串相等，O(1) 比较
3. **GC 友好**：Symbol 不在 Java 堆中，不参与 GC

**`initialize_symbols` 做了什么**：创建一个 360KB 的 `Arena`，预分配一批 VM 内部常用的 Symbol（`vmSymbols`），如 `"<init>"`、`"<clinit>"`、`"java/lang/Object"`、`"java/lang/String"` 等。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐⭐⭐ 非常重要 | 类加载的核心数据结构 |

---

### [10] StringTable::create_table() ⭐⭐⭐

> 📖 **深度剖析**：[5B-StringTable-Deep-Dive.md](5B-StringTable-Deep-Dive.md)

**源码**：`stringTable.hpp:107-110`

```cpp
static void create_table() {
  assert(_the_table == NULL, "One string table allowed.");
  _the_table = new StringTable();
}
```

**StringTable 是什么**：Java 字符串常量池（`String.intern()` 的底层实现）。

**与 SymbolTable 的区别**：
- `SymbolTable` 存的是 JVM 内部的 `Symbol*`（C++ 对象，不在 Java 堆中）
- `StringTable` 存的是 Java 层 `java.lang.String` 对象的**弱引用**（对象在 Java 堆中）

**为什么 StringTable 存弱引用**：如果存强引用，字符串永远不会被 GC 回收，导致内存泄漏。弱引用允许 GC 在内存不足时回收不再被使用的 intern 字符串。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐⭐ 重要 | String.intern() 的底层 |

---

### [11] ResolvedMethodTable::create_table()

**做了什么**：创建已解析方法表。

**用途**：当 Java 代码使用 `MethodHandle`、反射调用时，JVM 需要把方法引用解析为实际的 `Method*`。`ResolvedMethodTable` 缓存这些解析结果，并在 `JVMTI RedefineClasses`（热替换类）时更新它们。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐ 一般 | 反射/MethodHandle 支持 |

---

## GDB 验证——universe_init() 完整数据

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC -Xint
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

=== Java 堆 ===
_collectedHeap (G1CollectedHeap*):  0x7ffff0031bb0
sizeof(G1CollectedHeap):            1,864 bytes
reserved._start:                    0x600000000 (24GB)
reserved end:                       0x800000000 (32GB)
堆大小:                             8 GB
Region 数量 (_num_committed):       2,048
HeapRegion::GrainBytes:             4,194,304 (4MB)
sizeof(HeapRegion):                 432 bytes

=== 压缩 OOP（对象指针）===
模式:                               Zero-based
narrow_oop._base:                   NULL (0)
narrow_oop._shift:                  3
implicit_null_checks:               启用
解码公式:                           oop = compressed_oop << 3

=== 压缩 Klass 指针 ===
narrow_klass._base:                 0x800000000 (= 堆末尾)
narrow_klass._shift:                0
解码公式:                           klass = base + compressed_klass

=== TLAB ===
max_size:                           262,144 words = 2 MB

=== Metaspace ===
_space_list:                        0x7ffff0c8aff0
_chunk_manager_metadata:            0x7ffff0c8ba70
_first_chunk_word_size:             524,288 words = 4 MB (Bootstrap Chunk)
_first_class_chunk_word_size:       49,152 words = 384 KB

=== 表 ===
SymbolTable:                        0x7ffff0c90ec0
StringTable:                        0x7ffff0c90fa0
ResolvedMethodTable:                0x7ffff0c91470

=== 其他 ===
_null_class_loader_data:            0x7ffff0c8c340
_finalizer_register_cache:          0x7ffff0c90ce0
_loader_addClass_cache:             0x7ffff0c90d30
_pd_implies_cache:                  0x7ffff0c90d80
_do_stack_walk_cache:               0x7ffff0c90e70
_throw_illegal_access_error_cache:  0x7ffff0c90dd0
_throw_no_such_method_error_cache:  0x7ffff0c90e20

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## universe_init() 创建的全部对象汇总

```
universe_init() 创建的对象/状态（按重要性排序）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

★★★★★ 最关键
├─ G1CollectedHeap (1864 bytes)
│   ├─ 8GB mmap 堆内存 (0x600000000 ~ 0x800000000)
│   ├─ 2048 × HeapRegion (每个 432 bytes)
│   ├─ G1CardTable (16MB)
│   ├─ G1RemSet
│   ├─ G1ConcurrentMark
│   ├─ GC 工作线程
│   └─ G1ConcurrentRefine 线程
│
├─ 压缩 OOP 配置
│   ├─ base = NULL, shift = 3 (Zero-based)
│   └─ TLAB max_size = 2MB
│
├─ SymbolTable (符号表)
│   └─ 包含预分配的 vmSymbols Arena (360KB)
│
└─ StringTable (字符串常量池)

★★★★ 非常重要
├─ Metaspace
│   ├─ 压缩类空间 (1GB 预留 @ 0x800000000)
│   │   └─ narrow_klass: base=0x800000000, shift=0
│   ├─ 数据元空间 (8MB 初始)
│   │   ├─ VirtualSpaceList
│   │   └─ ChunkManager
│   └─ MetaspaceTracer (JFR)
│
├─ ClassLoaderData (_null_class_loader_data)
│   └─ Bootstrap ClassLoader 的元数据管理
│
└─ 压缩 Klass 指针配置

★★★ 重要
├─ OopStorage "VM Weak Oop Handles"
├─ 8 个 Metaspace 性能计数器
├─ ResolvedMethodTable
└─ 6 × LatestMethodCache (空壳)

★★ 一般
├─ JavaClasses 硬编码偏移量
└─ AOTLoader（默认无效）
```

---

## 关键设计决策总结

| 设计决策 | 原因 | 影响 |
|---------|------|------|
| 堆分配在 24-32GB 地址范围 | 保证压缩指针能用 Zero-based 模式 | 少一条加法指令/次对象访问 |
| 压缩类空间紧挨堆末尾 | Klass 指针也需要压缩，必须在连续范围内 | 对象头从 16 字节压到 12 字节 |
| TLAB max = Region/2 | 避免 TLAB 触发 Humongous 分配 | 对象分配路径统一 |
| SymbolTable 用哈希表 | O(1) 查找 + 自动去重 | 类加载性能 |
| StringTable 存弱引用 | 防止 intern 字符串导致内存泄漏 | 可被 GC 回收 |
| Metaspace 分类空间和数据空间 | 类指针需要压缩 | Klass 集中在 1GB 范围内 |
| Bootstrap ClassLoader 第一个 Chunk = 4MB | JDK 核心类（Object/String/Class 等）元数据量大 | 避免频繁扩展 |

---

## 相关 JVM 参数

| 参数 | 作用 | 默认值 |
|------|------|--------|
| `-Xlog:gc,heap,coops` | 查看堆地址和压缩指针模式 | 关闭 |
| `-Xlog:startuptime` | 查看 "Genesis" 耗时 | 关闭 |
| `-XX:CompressedClassSpaceSize` | 压缩类空间大小 | 1GB |
| `-XX:InitialBootClassLoaderMetaspaceSize` | Bootstrap 初始 Metaspace | 4MB |
| `-XX:MetaspaceSize` | Metaspace GC 触发阈值 | ~21MB |
| `-XX:MaxMetaspaceSize` | Metaspace 上限 | 无限制 |

**查看 Genesis 耗时**：
```bash
java -Xms8g -Xmx8g -XX:+UseG1GC -Xlog:startuptime -version
# 输出: [info][startuptime] Genesis, 0.0XXX secs
```

**查看压缩指针模式**：
```bash
java -Xms8g -Xmx8g -XX:+UseG1GC -Xlog:gc+heap+coops -version
# 输出: Heap address: 0x0000000600000000, size: 8192 MB, Compressed Oops mode: Zero based, Oop shift amount: 3
```

---

## 遗留问题（待后续文档展开）

1. `G1CollectedHeap::initialize()` 内部的完整流程（已有部分分析在 `jvm-md/Universe/`）
2. `VirtualSpaceList` 和 `ChunkManager` 的内部实现（Metaspace 内存管理细节）
3. `SymbolTable` 的哈希表实现（桶数量、扩容策略、并发访问）
4. `StringTable` 的并发哈希表实现（JDK 9+ 改用了 `ConcurrentHashTable`）
