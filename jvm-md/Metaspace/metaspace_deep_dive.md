# Metaspace 深入源码分析

> 基于 OpenJDK 11，标准环境：`-Xms8g -Xmx8g -XX:+UseG1GC`，Region=4MB
> 源码：`src/hotspot/share/memory/metaspace.cpp` + `memory/metaspace/` 子目录

---

## 1. Metaspace 解决了什么问题

Java 8 之前，类元数据存在永久代（PermGen），有三个致命问题：**固定大小**（启动时确定，不能动态扩展）、**GC 效率低**（回收需要 Full GC）、**碎片化严重**（类和字符串常量混在一起）。

Metaspace 的解决方案：用操作系统 native memory 管理类元数据，每个 ClassLoader 独立分配/释放，通过多级 Chunk 减少碎片，通过 HWM 触发 GC 控制总量。

---

## 2. 整体架构

```
Metaspace (AllStatic, 全局入口)
  ├── _space_list (VirtualSpaceList, 数据元空间) ──→ VSN1 → VSN2 → ...
  ├── _class_space_list (VirtualSpaceList, 类空间) ──→ VSN (固定1GB)
  ├── _chunk_manager_metadata (ChunkManager, 数据空闲池)
  └── _chunk_manager_class (ChunkManager, 类空闲池)

每个 ClassLoader 拥有:
  ClassLoaderMetaspace
    ├── SpaceManager (_vsm, NonClass) → chunk_list → current_chunk (bump ptr)
    └── SpaceManager (_class_vsm, Class) → chunk_list → current_chunk
```

**两套独立管线**（64位 JVM）：

| 类型 | 存储内容 | 地址范围 |
|------|---------|---------|
| NonClass（数据） | Method, ConstantPool, Bytecode | 任意位置（mmap），初始 8MB |
| Class（类） | Klass 结构体 | 紧邻堆末尾，固定 1GB |

---

## 3. 核心数据结构

### 3.1 Metaspace（全局静态入口）— `metaspace.hpp:94`

AllStatic 类，关键静态字段：

```cpp
VirtualSpaceList* _space_list;           // 数据 VSL
VirtualSpaceList* _class_space_list;     // 类 VSL  
ChunkManager*     _chunk_manager_metadata;
ChunkManager*     _chunk_manager_class;
size_t _first_chunk_word_size;       // Boot首个数据Chunk = 4MB (524288 words)
size_t _first_class_chunk_word_size; // Boot首个类Chunk = 384KB (49152 words)
size_t _commit_alignment;    // = page_size (4KB)
size_t _reserve_alignment;   // = max(page_size, alloc_granularity)
```

MetaspaceType 影响首次 Chunk 大小：Boot→4MB/384KB，Standard→4KB/2KB，Anonymous/Reflection→1KB/1KB。

### 3.2 ClassLoaderMetaspace — `metaspace.hpp:237`

每 ClassLoader 一个，字段：`_lock`, `_space_type`, `_vsm`(SpaceManager*), `_class_vsm`(SpaceManager*)。

构造时（`metaspace.cpp:1688`）创建两个 SpaceManager，并为每个分配首个 Chunk。

### 3.3 SpaceManager — `spaceManager.hpp:43`

实际执行分配的核心类。字段：`_chunk_list`(所有使用中Chunk链表), `_current_chunk`(当前bump pointer), `_block_freelists`(回收小块), `_capacity_words/_used_words/_overhead_words`(计数器)。

**Chunk 大小选择**（`calc_chunk_size()` spaceManager.cpp:110）：Anonymous/Reflection 最多4个Specialized → 最多4个Small → 之后全用Medium → 超大则Humongous。

### 3.4 ChunkManager — `chunkManager.hpp:44`

全局空闲Chunk池，两个实例（数据+类）。

| 结构 | 管理的Chunk | 数据结构 |
|------|-----------|---------|
| `_free_chunks[0]` | Specialized (128w/1KB) | 链表 |
| `_free_chunks[1]` | Small (512w/4KB 或 256w/2KB) | 链表 |
| `_free_chunks[2]` | Medium (8192w/64KB 或 4096w/32KB) | 链表 |
| `_humongous_dictionary` | > Medium | BinaryTreeDictionary（红黑树） |

分配时先查freelist，没有则拆分更大Chunk（`split_chunk`）；归还时尝试合并相邻小Chunk（`attempt_to_coalesce_around_chunk`）。

### 3.5 VirtualSpaceList — `virtualSpaceList.hpp:39`

管理 VirtualSpaceNode 链表。数据空间可动态添加VSN，类空间永远只有1个VSN。

字段：`_virtual_space_list`(头), `_current_virtual_space`, `_reserved_words`, `_committed_words`, `_envelope_lo/_hi`(快速范围判断)。

`get_new_chunk()`：先从当前VSN切→不够则expand_by提交更多物理内存→还不够则创建新VSN。

### 3.6 VirtualSpaceNode — `virtualSpaceNode.hpp:42`

一块 mmap 预留的虚拟内存。字段：`_rs`(ReservedSpace), `_virtual_space`(VirtualSpace管理commit), `_top`(bump pointer), `_container_count`(使用中Chunk数), `_occupancy_map`(位图)。

`take_from_committed()`：对齐→创建padding chunk→bump _top→placement new Metachunk→更新位图。

### 3.7 Metachunk — `metachunk.hpp:80`

分配量子，直接构造在VSN内存上。**overhead = 8 words = 64 bytes**。

字段：`_word_size`(总大小), `_top`(bump ptr), `_container`(所属VSN), `_sentinel`(0x4d4554EF,"MET"), `_chunk_type`, `_origin`(normal/pad/merge/split), `_use_count`。

分配就是 `_top += word_size`，O(1)。

### 3.8 OccupancyMap — `occupancyMap.hpp`

每VSN一个，两层位图（chunk_start_map + in_use_map），1 bit = 1个最小Chunk区域(1KB)。类空间1GB需要256KB位图。用于合并时快速检查区域是否全空闲，32/64位对齐时一次整数比较。

### 3.9 BlockFreelist / SmallBlocks

当Chunk中的元数据被释放（如retire_current_chunk剩余空间），放入BlockFreelist供复用。包含SmallBlocks（数组，精确匹配小块）和BlockTreeDictionary（红黑树，大块best-fit）。WasteMultiplier=4：找到的块超过请求4倍则放弃。

---

## 4. Chunk 大小体系

```cpp
// metaspaceCommon.hpp:35
enum ChunkSizes {   // in words
  SpecializedChunk = 128,       // 1KB     ClassSpecializedChunk = 128   // 1KB
  SmallChunk = 512,             // 4KB     ClassSmallChunk = 256         // 2KB
  MediumChunk = 8 * K,          // 64KB    ClassMediumChunk = 4 * K     // 32KB
};
// Humongous: > MediumChunk
```

类空间Chunk更小：Klass通常几百字节~几KB，且总共1GB需要更精细管理。

---

## 5. 初始化流程

```
Metaspace::ergo_initialize()     // 设置对齐，调整参数
universe_init() → Metaspace::global_initialize()  // metaspace.cpp:1384
  ├── MetaspaceGC::initialize()  → _capacity_until_GC = MaxMetaspaceSize (启动期不GC)
  ├── allocate_metaspace_compressed_klass_ptrs(heap_end, 0)
  │     ├── ReservedSpace(1GB) 紧邻堆后 (0x800000000)
  │     ├── set_narrow_klass_base_and_shift()  // base=0x800000000, shift=0
  │     └── initialize_class_space() → new VirtualSpaceList(rs) + new ChunkManager(true)
  ├── _first_chunk_word_size = 4MB/8 = 524288 words
  ├── _first_class_chunk_word_size = 49152 words = 384KB
  ├── _space_list = new VirtualSpaceList(8MB)  // 数据元空间
  ├── _chunk_manager_metadata = new ChunkManager(false)
  └── _tracer = new MetaspaceTracer()

Metaspace::post_initialize()
  └── _capacity_until_GC = MAX2(committed_bytes, MetaspaceSize ~21MB)
```

---

## 6. 分配流程（6层）

```
L1: Metaspace::allocate(loader_data, word_size, type)         // 入口
L2:   ClassLoaderMetaspace::allocate(word_size, mdtype)       // 选vsm/class_vsm
L3:     SpaceManager::allocate(word_size)                     // 加锁
          ├── BlockFreelist::get_block() (如果total>4K words)  // 回收块复用
L4:       └── allocate_work(raw_word_size)
                ├── current_chunk()->allocate()                // bump pointer
L5:             └── grow_and_allocate()
                      ├── ChunkManager::chunk_freelist_allocate() // 全局空闲池
L6:                   └── VirtualSpaceList::get_new_chunk()
                            ├── VSN::take_from_committed()     // bump _top切Chunk
                            ├── expand_by() → mmap commit      // 提交更多物理内存
                            └── create_new_virtual_space()     // 新VSN (仅数据空间)
分配失败 → GC + retry → OOM
```

---

## 7. Chunk 生命周期

1. **诞生**：`take_from_committed`(origin_normal) / `split_chunk`(origin_split) / `coalesce`(origin_merge) / padding(origin_pad)
2. **使用**：加入SpaceManager._chunk_list，current_chunk通过bump ptr分配
3. **退役**：`retire_current_chunk()` 将剩余空间放入BlockFreelist
4. **归还**：ClassLoader卸载 → `SpaceManager::~SpaceManager()` → `ChunkManager::return_chunk_list()` 整批归还
5. **合并**：归还时自动尝试合并(Specialized→Small→Medium)
6. **清除**：`VirtualSpaceList::purge()` 在Safepoint释放container_count==0的VSN

---

## 8. MetaspaceGC 机制

通过 HWM（_capacity_until_GC）控制增长，`volatile size_t`，CAS更新。

**生命周期**：`initialize()`设为MaxMetaspaceSize → `post_initialize()`设为MAX2(committed, MetaspaceSize) → 运行期`compute_new_size()`每次GC后调整。

**GC后调整**（`compute_new_size()` metaspace.cpp:244）：
- 扩展：如果 `capacity_until_GC < used / (1 - MinMetaspaceFreeRatio/100)` → 增加HWM
- 收缩：如果 `capacity_until_GC > used / (1 - MaxMetaspaceFreeRatio/100)` → 减少HWM（阻尼：0%→10%→40%→100%）

**日志参数**：`-Xlog:gc+metaspace=trace`

```
[trace][gc,metaspace] MetaspaceGC::compute_new_size: 
[trace][gc,metaspace]     minimum_free_percentage:   0.40  maximum_used_percentage:   0.60
[trace][gc,metaspace]      used_after_gc       :  15234.2KB
```

---

## 9. 压缩类空间

所有Klass必须在连续的有限区域内，使64位地址可编码为32位：`narrowKlass = (addr - base) >> shift`。

标准环境：base=0x800000000，shift=0（1GB<4GB不需移位），CompressedClassSpaceSize=1GB。

类空间只有1个VSN，不能动态添加新VSN。

---

## 10. ClassLoader 隔离与类卸载

每个ClassLoader独立的ClassLoaderMetaspace→SpaceManager→chunk_list。卸载时`~SpaceManager()`将所有Chunk整批通过`return_chunk_list()`归还ChunkManager。之后`VirtualSpaceList::purge()`释放空VSN。

这是比PermGen高效的核心：不遍历每个对象，整批释放。

---

## 11. Chunk 合并与拆分

**合并**（`attempt_to_coalesce_around_chunk` chunkManager.cpp:126）：归还时，Specialized/Small尝试合并为Medium（不行则Small）。通过OccupancyMap检查对齐区域内所有Chunk是否空闲，移除旧Chunk，placement new新大Chunk，更新位图。

**拆分**（`split_chunk` chunkManager.cpp:405）：请求的Chunk大小无空闲但有更大Chunk时，拆分为目标大小+剩余尽可能大的Chunk。

---

## 12. JVM 参数与日志

| 参数 | 默认值 | 含义 |
|------|--------|------|
| `MetaspaceSize` | ~21MB | 初始GC阈值 |
| `MaxMetaspaceSize` | unlimited | 最大Metaspace |
| `CompressedClassSpaceSize` | 1GB | 压缩类空间 |
| `InitialBootClassLoaderMetaspaceSize` | 4MB | Boot CL首个Chunk |
| `MinMetaspaceFreeRatio` | 40 | GC后最小空闲比 |
| `MaxMetaspaceFreeRatio` | 70 | GC后最大空闲比 |

**日志**：
```bash
-Xlog:gc+metaspace=info              # 基本信息
-Xlog:gc+metaspace=trace             # GC调整详情
-Xlog:gc+metaspace+freelist=trace    # Chunk分配/释放/合并
-Xlog:gc+metaspace+alloc=trace       # Humongous分配
```

---

## 13. GDB 验证脚本与实测数据

### 13.1 验证命令

```gdb
# 全局状态
p Metaspace::_space_list->_reserved_words
p Metaspace::_space_list->_committed_words
p Metaspace::_class_space_list->_committed_words
p MetaspaceGC::_capacity_until_GC

# ChunkManager
set $cm = Metaspace::_chunk_manager_metadata
p $cm->_free_chunks_total
p $cm->_free_chunks[0]._count   # Specialized
p $cm->_free_chunks[1]._count   # Small  
p $cm->_free_chunks[2]._count   # Medium

# 遍历 VSN
set $vsn = Metaspace::_space_list->_virtual_space_list
while $vsn != 0
  printf "VSN %p: containers=%lu top=%p\n", $vsn, $vsn->_container_count, $vsn->_top
  set $vsn = $vsn->_next
end

# 检查 Metachunk
set $c = (Metachunk*)0x7fffc29f0000
p $c->_word_size
p $c->_chunk_type
printf "sentinel valid: %d\n", $c->_sentinel == 0x4d4554ef
p $c->_origin
p $c->_use_count
```

### 13.2 实测数据（post_initialize 入口，-Xms8g -Xmx8g -XX:+UseG1GC -Xint -version）

| 字段 | 实测值 | 含义 |
|------|--------|------|
| `_first_chunk_word_size` | **524288** | Boot 数据 Chunk = 4MB ✅ |
| `_first_class_chunk_word_size` | **49152** | Boot 类 Chunk = 384KB ✅ |
| `_commit_alignment` | 4096 | 4KB 页对齐 |
| `_capacity_until_GC` | ~UINT64_MAX | 启动期不触发 GC |
| 数据 VSL `_reserved_words` | **1048576** | 8MB = 2×4MB (VIRTUALSPACEMULTIPLIER) ✅ |
| 数据 VSL `_committed_words` | **524288** | 4MB（Boot 首个 chunk） ✅ |
| 类 VSL `_reserved_words` | **134217728** | 1GB = CompressedClassSpaceSize ✅ |
| 类 VSL `_committed_words` | **49152** | 384KB（Boot 首个 chunk） ✅ |
| ChunkManager 空闲 | 0/0 | 初始化时全部在用 ✅ |
| `narrow_klass_base` | **0x800000000** | 紧邻 8GB 堆末尾 ✅ |
| `narrow_klass_shift` | **0** | 1GB < 4GB 不需移位 ✅ |

### 13.3 启动完成后统计（PrintMetaspaceStatisticsAtExit）

```
Usage:
  Non-class:  5.04 MB capacity, ~99% used
  Class:      586 KB capacity, 538 KB (92%) used
  Both:       5.61 MB capacity, 5.53 MB (99%) used

Virtual space:
  Non-class: 8.00 MB reserved, 5.25 MB (66%) committed
  Class:     1.00 GB reserved, 640 KB (<1%) committed

Initial GC threshold: 20.80 MB
Current GC threshold: 20.80 MB  (未触发GC)
```

结论：java -version 仅使用约 **5.61MB** 元空间（数据 5.04MB + 类 586KB），GC 阈值 20.80MB（≈MetaspaceSize 默认值）。

---

## 14. 源码文件索引

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `metaspace.hpp` | 497 | Metaspace/ClassLoaderMetaspace/MetaspaceGC 类定义 |
| `metaspace.cpp` | 2013 | 全局初始化/分配入口/MetaspaceGC/压缩类空间/MetaspaceUtils |
| `spaceManager.hpp/cpp` | 235/523 | SpaceManager 分配管理器 |
| `chunkManager.hpp/cpp` | 225/725 | ChunkManager 空闲池/合并/拆分 |
| `virtualSpaceList.hpp/cpp` | 170/470 | VirtualSpaceList 虚拟空间链表 |
| `virtualSpaceNode.hpp/cpp` | 168/663 | VirtualSpaceNode 虚拟空间节点 |
| `metachunk.hpp/cpp` | 174/172 | Metachunk 元数据块 |
| `occupancyMap.hpp/cpp` | 243/136 | OccupancyMap 占用位图 |
| `blockFreelist.hpp/cpp` | 94/110 | BlockFreelist 小块回收 |
| `smallBlocks.hpp` | 90 | SmallBlocks 精确匹配小块链表 |
| `metaspaceCommon.hpp` | 133 | ChunkSizes/ChunkIndex 枚举常量 |
