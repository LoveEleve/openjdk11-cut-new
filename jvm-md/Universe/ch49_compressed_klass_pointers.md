# Ch49: CompressedKlassPointers 完整分析 — 压缩类指针的编码/解码/初始化全链路

> **标准环境**: `-Xms8g -Xmx8g -XX:+UseG1GC`, 16 核, Region 4MB
> **前置文档**: `Universe/3.4-CompressedOops.md`（压缩对象指针）、`Universe/5-Metaspace.md`（Metaspace 结构）
> **核心源码**: `klass.inline.hpp`（编解码）、`metaspace.cpp`（初始化）、`universe.hpp`（NarrowPtrStruct）

---

## 1. 解决什么问题？

### 1.1 问题背景

在 64 位 JVM 中，每个 Java 对象头都包含一个指向其 **Klass 元数据**的指针。Klass 对象存储在 Metaspace 中，记录了类名、方法表、字段布局等信息。

对象头结构：
\`\`\`
oopDesc (每个 Java 对象)
┌──────────────────────┐
│ _mark (8 bytes)      │ ← markWord (锁状态/hashCode/GC 年龄)
├──────────────────────┤
│ _metadata (8 bytes)  │ ← 指向 Klass 的指针
└──────────────────────┘
\`\`\`

如果直接使用 64 位（8 bytes）的 Klass 指针，**每个对象**都要多花 8 字节存储。对于一个有数百万对象的 Java 应用，这些 Klass 指针占用的总内存相当可观。

### 1.2 核心思路

**Compressed Klass Pointers** 的核心思路：**用 32 位（4 bytes）存储 Klass 指针，运行时再解码为 64 位地址**。

\`\`\`
对象头对比：
                  不压缩                    压缩
               ┌──────────┐           ┌──────────┐
               │ _mark    │ 8B        │ _mark    │ 8B
               │ _klass   │ 8B        │ _cKlass  │ 4B  ← 节省 4 字节
               └──────────┘           │ [gap]    │ 4B  ← 但对齐需要填充
               共 16B                  └──────────┘
                                      共 16B (含 gap)
\`\`\`

> **注意**：虽然 narrowKlass 只有 4 字节，但 _mark 是 8 字节，加上 4 字节 narrowKlass 后需要对齐，所以对象头仍然是 16 字节。节省主要体现在**对象内部引用其他 Klass 的场景**和 Klass 指针在对象头中的紧凑存储（具体节省取决于 JVM 实现细节）。

这就要求：**所有 Klass 对象必须分配在一个有限的地址范围内**，使得 32 位足以编码所有 Klass 地址。这个范围就是 **Compressed Class Space**。

---

## 2. 核心数据结构

### 2.1 NarrowPtrStruct — 编解码参数

CompressedOops 和 CompressedKlassPointers 共用同一个参数结构体：

\`\`\`cpp
// universe.hpp:79
struct NarrowPtrStruct {
    address _base;                      // 基址
    int     _shift;                     // 移位量
    bool    _use_implicit_null_checks;  // 是否使用隐式空检查
};

// universe.hpp:192-195
static struct NarrowPtrStruct _narrow_oop;    // CompressedOops 参数
static struct NarrowPtrStruct _narrow_klass;  // CompressedKlassPointers 参数
static address _narrow_ptrs_base;
static uint64_t _narrow_klass_range;          // Klass 可用地址范围
\`\`\`

### 2.2 narrowKlass 类型

\`\`\`cpp
// oopsHierarchy.hpp:40
typedef juint narrowKlass;  // = uint32_t，32 位无符号整数
\`\`\`

### 2.3 对象头中的 _metadata union

\`\`\`cpp
// oop.hpp:60
union _metadata {
    Klass*      _klass;             // 64 位原始指针（不压缩时使用）
    narrowKlass _compressed_klass;  // 32 位压缩指针（压缩时使用）
} _metadata;
\`\`\`

通过 union，同一个内存位置可以存储 64 位 Klass 指针（不压缩时）或 32 位 narrowKlass（压缩时）。

### 2.4 GDB 验证 — 数据结构大小

\`\`\`
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
┌──────────────────────────────────────────────────────┐
│ sizeof(NarrowPtrStruct) = 16 bytes                   │
│   _base:                     8 bytes (address)       │
│   _shift:                    4 bytes (int)           │
│   _use_implicit_null_checks: 1 byte  (bool)          │
│   [padding]:                 3 bytes                 │
│                                                      │
│ sizeof(narrowKlass) = 4 bytes (uint32_t)             │
│ sizeof(Klass*)      = 8 bytes (64-bit pointer)       │
│                                                      │
│ → 压缩后节省 4 bytes per Klass pointer               │
└──────────────────────────────────────────────────────┘
\`\`\`

---

## 3. 关键常量

\`\`\`cpp
// globalDefinitions.hpp:510-525

const int LogKlassAlignmentInBytes = 3;      // Klass 对齐: 2^3 = 8 字节
const int KlassAlignmentInBytes    = 8;      // = 1 << 3

// 压缩类指针的最大编码范围
const uint64_t KlassEncodingMetaspaceMax = (uint64_t(max_juint) + 1) << LogKlassAlignmentInBytes;
// = (4294967295 + 1) << 3
// = 4G × 8
// = 32GB
\`\`\`

\`\`\`
关键常量总结：
┌──────────────────────────────────────────────────────┐
│ LogKlassAlignmentInBytes  = 3                        │
│ KlassAlignmentInBytes     = 8 bytes                  │
│ KlassEncodingMetaspaceMax = 32GB (最大编码范围)       │
│ CompressedClassSpaceSize  = 1GB (默认，类空间大小)    │
│ UnscaledClassSpaceMax     = 4GB (零移位编码上限)      │
│                                                      │
│ 32 位 × 8 字节对齐 = 32GB 地址空间                   │
│ 与 CompressedOops 原理完全相同                        │
└──────────────────────────────────────────────────────┘
\`\`\`

---

## 4. 编码与解码

### 4.1 编码：Klass* → narrowKlass

\`\`\`cpp
// klass.inline.hpp:48
inline narrowKlass Klass::encode_klass_not_null(Klass* v) {
    assert(!is_null(v), "klass value can never be zero");
    assert(check_klass_alignment(v), "Address not aligned");

    int    shift = Universe::narrow_klass_shift();
    // ① 计算相对于 base 的偏移
    uint64_t pd = (uint64_t)(pointer_delta((void*)v, Universe::narrow_klass_base(), 1));
    assert(KlassEncodingMetaspaceMax > pd, "change encoding max if new encoding");

    // ② 右移 shift 位
    uint64_t result = pd >> shift;
    assert((result & CONST64(0xffffffff00000000)) == 0, "narrow klass pointer overflow");
    assert(decode_klass(result) == v, "reversibility");

    return (narrowKlass)result;
}
\`\`\`

**编码公式**：`narrowKlass = (klass_address - base) >> shift`

### 4.2 解码：narrowKlass → Klass*

\`\`\`cpp
// klass.inline.hpp:60
inline Klass* Klass::decode_klass_not_null(narrowKlass v) {
    assert(!is_null(v), "narrow klass value can never be zero");

    int    shift = Universe::narrow_klass_shift();
    // ① 左移 shift 位
    // ② 加上 base
    Klass* result = (Klass*)(void*)((uintptr_t)Universe::narrow_klass_base() + ((uintptr_t)v << shift));
    assert(check_klass_alignment(result), "address not aligned");

    return result;
}
\`\`\`

**解码公式**：`klass_address = base + (narrowKlass << shift)`

### 4.3 编解码模式对比

\`\`\`
模式 1: UnscaledKlass (base=0, shift=0)
┌──────────────────────────────────────────────────────┐
│ 条件: 所有 Klass 地址 < 4GB                          │
│ 编码: narrowKlass = (uint32_t)klass_address          │
│ 解码: klass_address = (uint64_t)narrowKlass          │
│ 性能: 最优（零开销）                                  │
└──────────────────────────────────────────────────────┘

模式 2: ZeroBasedKlass (base=0, shift=3)
┌──────────────────────────────────────────────────────┐
│ 条件: 所有 Klass 地址 < 32GB                         │
│ 编码: narrowKlass = klass_address >> 3               │
│ 解码: klass_address = narrowKlass << 3               │
│ 性能: 较优（一条 shift 指令）                         │
└──────────────────────────────────────────────────────┘

模式 3: BaseKlass (base≠0, shift=0) ← 我们标准环境的模式！
┌──────────────────────────────────────────────────────┐
│ 条件: base + 类空间大小 < base + 4GB                 │
│ 编码: narrowKlass = klass_address - base             │
│ 解码: klass_address = base + narrowKlass             │
│ 性能: 较优（一条 add/sub 指令）                       │
└──────────────────────────────────────────────────────┘

模式 4: BaseShiftKlass (base≠0, shift=3)
┌──────────────────────────────────────────────────────┐
│ 条件: base + 类空间大小 > base + 4GB                 │
│ 编码: narrowKlass = (klass_address - base) >> 3      │
│ 解码: klass_address = base + (narrowKlass << 3)      │
│ 性能: 最差（add/sub + shift）                        │
└──────────────────────────────────────────────────────┘
\`\`\`

### 4.4 GDB 验证 — 实际编码示例

\`\`\`
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
base = 0x800000000 (32GB), shift = 0

┌─────────────────────────────────────────────────────────────────────────┐
│ byte[] Klass:                                                           │
│   地址: 0x800000840                                                     │
│   narrowKlass = (0x800000840 - 0x800000000) >> 0 = 2112                │
│   验证: 0x800000000 + (2112 << 0) = 0x800000840 ✓                      │
│   距 base: 2112 bytes ≈ 2 KB                                           │
│                                                                         │
│ String Klass:                                                           │
│   地址: 0x800002D18                                                     │
│   narrowKlass = (0x800002D18 - 0x800000000) >> 0 = 11544               │
│   验证: 0x800000000 + (11544 << 0) = 0x800002D18 ✓                     │
│   距 base: 11544 bytes ≈ 11 KB                                         │
│                                                                         │
│ Object[] Klass:                                                         │
│   地址: 0x800013778                                                     │
│   narrowKlass = (0x800013778 - 0x800000000) >> 0 = 79736               │
│   验证: 0x800000000 + (79736 << 0) = 0x800013778 ✓                     │
│   距 base: 79736 bytes ≈ 78 KB                                         │
│                                                                         │
│ 说明:                                                                   │
│   shift=0 意味着 narrowKlass 直接等于相对 base 的字节偏移               │
│   32 位 uint 最大值 = 4,294,967,295 ≈ 4GB                              │
│   类空间只有 1GB，足够容纳所有 Klass 对象                               │
└─────────────────────────────────────────────────────────────────────────┘
\`\`\`

---

## 5. 初始化全链路

### 5.1 整体流程

\`\`\`
Threads::create_vm()
 └── init_globals()
      └── universe_init()
           └── Universe::initialize_heap()
                └── reserve_heap()  ← 分配 Java 堆 [24GB ~ 32GB]
                     │
                     │  堆分配时已经为类空间预留位置:
                     │  heap 上界 = 32GB - 1GB(类空间) = 31GB
                     │  实际: 8GB 堆分配在 [24GB ~ 32GB]
                     │
      └── Metaspace::global_initialize()
           │
           ├── MetaspaceGC::initialize()
           │
           ├── if (using_class_space()) {
           │     // ① 计算请求地址 = 堆末尾对齐
           │     base = align_up(heap()->reserved_region().end(), reserve_alignment)
           │     // = align_up(0x800000000, 4KB) = 0x800000000 (32GB)
           │
           │     // ② 分配 Compressed Class Space
           │     allocate_metaspace_compressed_klass_ptrs(base, 0)
           │       └── ReservedSpace(1GB, alignment, false, 0x800000000)
           │       └── set_narrow_klass_base_and_shift(0x800000000, 0)
           │            ├── lower_base = 0x800000000
           │            ├── higher_address = 0x800000000 + 1GB = 0x840000000
           │            │
           │            ├── 0x840000000 > 4GB → base ≠ 0
           │            │   Universe::set_narrow_klass_base(0x800000000)
           │            │
           │            ├── higher - lower = 1GB < 4GB → shift = 0
           │            │   Universe::set_narrow_klass_shift(0)
           │            │
           │       └── initialize_class_space(metaspace_rs)
           │            └── 创建 VirtualSpaceList (class=true)
           │   }
           │
           └── 创建 non-class VirtualSpaceList + ChunkManagers
\`\`\`

### 5.2 set_narrow_klass_base_and_shift — 核心决策逻辑

\`\`\`cpp
// metaspace.cpp:1023
void Metaspace::set_narrow_klass_base_and_shift(address metaspace_base, address cds_base) {
    address lower_base;
    address higher_address;

    // 非 CDS 场景（标准条件）
    {
        higher_address = metaspace_base + compressed_class_space_size();
        // = 0x800000000 + 1GB = 0x840000000 (33GB)
        lower_base = metaspace_base;
        // = 0x800000000 (32GB)

        uint64_t klass_encoding_max = UnscaledClassSpaceMax << LogKlassAlignmentInBytes;
        // = 4GB << 3 = 32GB = KlassEncodingMetaspaceMax

        // 如果类空间在低 32GB 内，base 可以为 0
        if (higher_address <= (address)klass_encoding_max) {
            lower_base = 0;  // 零基址模式
        }
        // 标准条件: 0x840000000 (33GB) > 32GB → 不进入，lower_base = 0x800000000
    }

    // ① 设置 base
    Universe::set_narrow_klass_base(lower_base);
    // = 0x800000000

    // ② 设置 shift
    if (!UseSharedSpaces
        && (uint64_t)(higher_address - lower_base) <= UnscaledClassSpaceMax) {
        // 0x840000000 - 0x800000000 = 1GB <= 4GB → shift = 0
        Universe::set_narrow_klass_shift(0);
    } else {
        Universe::set_narrow_klass_shift(LogKlassAlignmentInBytes);  // = 3
    }
}
\`\`\`

**决策逻辑总结**：

\`\`\`
┌────────────────────────────────────────────────────────────────────┐
│                  narrow_klass 参数决策                              │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  Step 1: 确定 base                                                │
│  ────────────────────                                              │
│    if (类空间最高地址 ≤ 32GB):                                     │
│        base = 0           ← ZeroBased/Unscaled                    │
│    else:                                                           │
│        base = metaspace_base  ← BaseKlass/BaseShiftKlass          │
│                                                                    │
│    标准条件: 33GB > 32GB → base = 0x800000000                      │
│                                                                    │
│  Step 2: 确定 shift                                               │
│  ────────────────────                                              │
│    if (类空间总大小 ≤ 4GB):                                        │
│        shift = 0          ← Unscaled/BaseKlass                    │
│    else:                                                           │
│        shift = 3          ← ZeroBased/BaseShiftKlass              │
│                                                                    │
│    标准条件: 1GB ≤ 4GB → shift = 0                                 │
│                                                                    │
│  最终结果: base = 0x800000000, shift = 0                           │
│  模式: BaseKlass（base 偏移，无移位）                              │
└────────────────────────────────────────────────────────────────────┘
\`\`\`

### 5.3 为什么标准条件下 base ≠ 0？

这是 CompressedKlassPointers 和 CompressedOops 最大的区别之一。

**CompressedOops**：堆在 [24GB ~ 32GB]，heap_end = 32GB ≤ OopEncodingHeapMax(32GB) → `base = 0, shift = 3`（ZeroBased 模式）

**CompressedKlassPointers**：类空间在 [32GB ~ 33GB]，higher_address = 33GB > KlassEncodingMetaspaceMax(32GB) → `base = 0x800000000, shift = 0`

\`\`\`
地址空间布局：
  0GB         24GB         32GB   33GB
   │           │            │      │
   │  [未使用]  │  Java 堆   │ CSS  │
   │           │   (8GB)    │(1GB) │
   │           │            │      │
                             ↑
                        堆末尾 = 类空间起始 = 0x800000000

CompressedOops 视角:    [0 ~ 32GB] 全在 32GB 内 → base=0, shift=3
CompressedKlassPointers: [32GB ~ 33GB] 超出 32GB → base=32GB, shift=0
\`\`\`

### 5.4 堆分配时如何为类空间预留位置？

在 `reserve_heap()` 中（`virtualspace.cpp`），ZeroBased 模式的堆分配会预留类空间：

\`\`\`cpp
// virtualspace.cpp:665
if (UseCompressedClassPointers &&
    !UseSharedSpaces &&
    OopEncodingHeapMax <= KlassEncodingMetaspaceMax &&
    (uint64_t)(aligned_heap_base_min_address + size + class_space) <= KlassEncodingMetaspaceMax) {
    // 2GB + 8GB + 1GB = 11GB ≤ 32GB → 条件满足
    zerobased_max = (char*)OopEncodingHeapMax - class_space;
    // = 32GB - 1GB = 31GB
}
\`\`\`

这意味着堆的搜索上界从 32GB 降到了 31GB，**给类空间在堆末尾留了 1GB 的位置**。

\`\`\`
┌────────────────────────────────────────────────────────────────────┐
│  标准条件下的地址空间规划                                          │
│                                                                    │
│  0       2GB            24GB         31GB  32GB  33GB             │
│  │        │              │            │     │     │               │
│  │ [保留]  │   [搜索范围]  │   Java 堆  │     │ CSS  │              │
│  │        │              │   (8GB)    │     │(1GB)│              │
│  │        │              │            │     │     │               │
│  │        ↑              ↑            ↑     ↑     ↑               │
│  │   lowest_start    堆起始      zerobased_max  堆结束  CSS结束     │
│  │   (2GB)           (24GB)      (31GB)   (32GB) (33GB)          │
│                                                                    │
│  堆搜索: highest_start = 31GB - 8GB = 23GB ≈ 24GB(对齐后)         │
│  → 堆分配在 [24GB ~ 32GB]                                         │
│  → 类空间分配在 [32GB ~ 33GB]                                      │
│  → 两者紧密相邻                                                    │
└────────────────────────────────────────────────────────────────────┘
\`\`\`

### 5.5 GDB 验证 — 初始化运行时数据

\`\`\`
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC

========== set_narrow_klass_base_and_shift 输入 ==========
┌──────────────────────────────────────────────────────────┐
│ metaspace_base = 0x800000000 (32GB，紧接堆末尾)          │
│ cds_base = 0x0 (未使用 CDS)                              │
│ UseSharedSpaces = false                                  │
│ compressed_class_space_size = 1,073,741,824 = 1024 MB    │
└──────────────────────────────────────────────────────────┘

========== 编码结果 ==========
┌──────────────────────────────────────────────────────────┐
│ narrow_klass_base  = 0x800000000 (32GB)                  │
│ narrow_klass_shift = 0                                   │
│ narrow_klass_range = 4,294,967,296 (4GB)                 │
│ narrow_klass_use_implicit_null_checks = true              │
│ narrow_ptrs_base   = 0x0                                 │
│                                                          │
│ → 模式: BaseKlass (base偏移，无移位)                     │
│ → 编码: narrowKlass = klass_address - 0x800000000        │
│ → 解码: klass_address = 0x800000000 + narrowKlass        │
│ → 每个 narrowKlass 值直接等于距 base 的字节偏移          │
│ → 最大可编码范围: 4GB (uint32_t max)                     │
│ → 类空间仅 1GB，远小于 4GB 上限                          │
└──────────────────────────────────────────────────────────┘

========== 对比 narrow_oop ==========
┌──────────────────────────────────────────────────────────┐
│ narrow_oop_base  = 0x0                                   │
│ narrow_oop_shift = 3                                     │
│ → 模式: ZeroBased (零基址，3位移位)                       │
│ → 编码: narrowOop = oop_address >> 3                     │
│ → 解码: oop_address = narrowOop << 3                     │
└──────────────────────────────────────────────────────────┘

========== 堆布局 ==========
┌──────────────────────────────────────────────────────────┐
│ heap start: 0x600000000 (24GB)                           │
│ heap end:   0x800000000 (32GB)                           │
│ heap size:  8192 MB = 8GB                                │
│                                                          │
│ class space start: 0x800000000 (32GB)                    │
│ class space end:   0x840000000 (33GB)                    │
│ class space size:  1GB                                   │
└──────────────────────────────────────────────────────────┘

========== 初始化时 Compressed Class Space 使用量 ==========
┌──────────────────────────────────────────────────────────┐
│ class space used:     10,023 words = 78 KB               │
│ class space capacity: 49,152 words = 384 KB              │
│ non-class used:       137,999 words = 1078 KB            │
│ non-class capacity:   524,288 words = 4096 KB            │
│                                                          │
│ → 启动时类空间仅使用 78KB / 1GB = 0.007%                │
│ → 非类 Metaspace 使用 ~1MB / capacity 4MB               │
└──────────────────────────────────────────────────────────┘
\`\`\`

---

## 6. CompressedKlassPointers vs CompressedOops 完整对比

| 维度 | CompressedOops | CompressedKlassPointers |
|------|---------------|------------------------|
| **目的** | 压缩 Java 堆中的对象引用 | 压缩对象头中的 Klass 指针 |
| **存储位置** | 对象字段、栈、寄存器 | 对象头 `_metadata._compressed_klass` |
| **类型** | `narrowOop` (uint32_t) | `narrowKlass` (uint32_t) |
| **指向空间** | Java 堆 | Compressed Class Space (Metaspace 子区) |
| **对齐** | 8 字节 (LogMinObjAlignmentInBytes=3) | 8 字节 (LogKlassAlignmentInBytes=3) |
| **最大编码范围** | 32GB (OopEncodingHeapMax) | 32GB (KlassEncodingMetaspaceMax) |
| **默认空间大小** | 由 -Xmx 决定 (8GB) | 1GB (CompressedClassSpaceSize) |
| **JVM 参数** | `-XX:+UseCompressedOops` | `-XX:+UseCompressedClassPointers` |
| **依赖关系** | 独立 | 依赖 CompressedOops (关闭 Oops → 关闭 KlassPointers) |
| **标准条件下的模式** | ZeroBased (base=0, shift=3) | BaseKlass (base=32GB, shift=0) |
| **编码公式** | `oop >> 3` | `klass - 0x800000000` |
| **x86 编码指令** | `shr reg, 3` | `sub reg, 0x800000000` |
| **x86 解码指令** | `shl reg, 3` | `add reg, 0x800000000` |

**关键差异解释**：

为什么 CompressedOops 用 shift=3 而 CompressedKlassPointers 用 shift=0？

- CompressedOops：堆在 [24GB ~ 32GB]，base=0，需要 shift=3 才能将 32GB 压缩到 4GB 的 32 位范围
- CompressedKlassPointers：类空间在 [32GB ~ 33GB]，只有 1GB，base=32GB 后偏移量只有 [0 ~ 1GB]，远小于 4GB → 不需要 shift

\`\`\`
CompressedOops 地址范围:
  [0GB ────────────────────────── 32GB]  需要用 32 位表示 32GB
  32 位 × 8 对齐 = 32GB ✓  → shift = 3

CompressedKlassPointers 地址范围:
  [32GB ──── 33GB]  只需用 32 位表示 1GB
  32 位 × 1 = 4GB > 1GB ✓  → shift = 0 (无需移位)
\`\`\`

---

## 7. 不同堆大小下的编码模式

\`\`\`
┌─────────────────────────────────────────────────────────────────────────────┐
│                     不同堆大小下的编码参数                                  │
├──────────┬────────────┬──────────────────┬──────────┬──────────────────────┤
│ 堆大小   │ 堆范围      │ 类空间范围        │ base     │ shift │ 模式       │
├──────────┼────────────┼──────────────────┼──────────┼──────────────────────┤
│ ≤2GB     │ [2G~4G]    │ [4G~5G]          │ 0        │ 0     │ Unscaled   │
│ 4GB      │ [27G~31G]  │ [31G~32G]        │ 0        │ 3     │ ZeroBased  │
│ 8GB      │ [24G~32G]  │ [32G~33G]        │ 32G      │ 0     │ BaseKlass  │
│ 16GB     │ [16G~32G]  │ [32G~33G]        │ 32G      │ 0     │ BaseKlass  │
│ 30GB     │ [2G~32G]   │ [32G~33G]        │ 32G      │ 0     │ BaseKlass  │
│ >32GB    │ 超出范围    │ —                │ —        │ —     │ 关闭压缩   │
├──────────┴────────────┴──────────────────┴──────────┴──────────────────────┤
│ 注: 实际地址可能因 OS ASLR 和对齐要求有微小变化                            │
│     堆 > 32GB 时 UseCompressedOops=false → UseCompressedClassPointers=false│
└─────────────────────────────────────────────────────────────────────────────┘
\`\`\`

**关键观察**：
- 小堆（≤2GB）时，堆和类空间都在低 4GB 内，可以不用 base 也不用 shift（Unscaled，性能最优）
- 中等堆（~4GB）时，堆和类空间都在 32GB 内，类空间可以不用 base 只用 shift（ZeroBased）
- 标准堆（8~30GB）时，类空间被推到 32GB 以上，必须用 base，但只有 1GB 不需要 shift（BaseKlass）
- 超大堆（>32GB）必须关闭压缩指针

---

## 8. Compressed Class Space 内存布局

### 8.1 整体布局

\`\`\`
JVM 虚拟地址空间 (标准条件: -Xms8g -Xmx8g)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

0x000000000  ┌─────────────────────────────┐
             │  OS 保留区 + JVM 代码        │
             │  (~2GB)                     │
0x600000000  ├─────────────────────────────┤  ← heap start (24GB)
             │                             │
             │      Java 堆 (8GB)          │
             │   2048 个 G1 Region (4MB)   │
             │                             │
0x800000000  ├─────────────────────────────┤  ← heap end / class space start (32GB)
             │                             │     narrow_klass_base
             │  Compressed Class Space     │
             │  (1GB, 虚拟预留)             │
             │                             │
             │  ┌───────────────────────┐  │
             │  │ byte[] Klass  @+2KB   │  │  narrowKlass = 2112
             │  │ String Klass  @+11KB  │  │  narrowKlass = 11544
             │  │ Object[] Klass @+78KB │  │  narrowKlass = 79736
             │  │ ...更多 Klass 对象... │  │
             │  │ (启动时已用 78KB)      │  │
             │  └───────────────────────┘  │
             │                             │
0x840000000  ├─────────────────────────────┤  ← class space end (33GB)
             │                             │
             │  非类 Metaspace             │
             │  (动态增长)                 │
             │  存储：方法、常量池、注解等  │
             │                             │
             ├─────────────────────────────┤
             │  C Heap / 其他              │
             └─────────────────────────────┘
\`\`\`

### 8.2 什么存在 Compressed Class Space？什么不存在？

\`\`\`
┌─────────────────────────────────────────────────────────────────────┐
│  Compressed Class Space (ClassType)      非类 Metaspace (NonClassType)
├─────────────────────────────────────────────────────────────────────┤
│  ✅ InstanceKlass                        ✅ ConstMethod            │
│  ✅ InstanceMirrorKlass                  ✅ Method                 │
│  ✅ InstanceRefKlass                     ✅ ConstantPool           │
│  ✅ InstanceClassLoaderKlass             ✅ ConstantPoolCache      │
│  ✅ ObjArrayKlass                        ✅ Symbol                 │
│  ✅ TypeArrayKlass                       ✅ Annotations            │
│  ✅ ArrayKlass                           ✅ MethodCounters         │
│                                          ✅ MethodData             │
│  只有 Klass 家族的对象                    ✅ Array<Method*>        │
│  (对象头中被 narrowKlass 引用的)          ✅ Array<Klass*>         │
│                                          ✅ RecordComponent        │
│  → 需要被压缩指针编码的对象               → 不需要被压缩编码的对象  │
└─────────────────────────────────────────────────────────────────────┘
\`\`\`

**为什么要分开**？

因为 narrowKlass 只需编码 **Klass 类型的对象**（存在对象头中），不需要编码 Method、ConstantPool 等其他元数据。把 Klass 集中在一个有限地址范围（Compressed Class Space）内，确保 32 位足以编码所有 Klass 地址。其他元数据可以分散在任意地址。

---

## 9. JVM 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| \`UseCompressedClassPointers\` | **true** (64bit) | 总开关 |
| \`CompressedClassSpaceSize\` | **1GB** | 类空间大小 |
| \`UseCompressedOops\` | **true** (64bit) | 对象压缩指针（关闭则 KlassPointers 也关闭） |

**注意事项**：
- \`CompressedClassSpaceSize\` 不能超过 \`KlassEncodingMetaspaceMax\`（32GB），否则警告并关闭
- 关闭 \`UseCompressedOops\` 会自动关闭 \`UseCompressedClassPointers\`
- \`CompressedClassSpaceSize + 最小 Metaspace\` 不能超过 \`MaxMetaspaceSize\`

### 查看当前配置

\`\`\`bash
# 查看压缩类指针配置
java -Xms8g -Xmx8g -XX:+UseG1GC \
     -Xlog:gc+metaspace=info -version

# 输出示例:
# Compressed class space mapped at: 0x0000000800000000-0x0000000840000000, reserved size: 1073741824
# Narrow klass base: 0x0000000800000000, Narrow klass shift: 0

# 查看 Metaspace 使用情况
java -Xms8g -Xmx8g -XX:+UseG1GC \
     -Xlog:gc+metaspace=debug -version
\`\`\`

---

## 10. x86 汇编层面的编解码

### 10.1 标准条件 (base=0x800000000, shift=0)

\`\`\`asm
; 编码: klass_address → narrowKlass
; narrowKlass = klass_address - base
sub rax, 0x800000000    ; 1 条指令

; 解码: narrowKlass → klass_address
; klass_address = base + narrowKlass
movl eax, [rdi + 8]          ; 从对象头读取 32-bit narrowKlass
addq rax, 0x800000000        ; 1 条指令 (加上 base)
; rax 现在是完整的 Klass* 地址
\`\`\`

### 10.2 ZeroBased 场景 (base=0, shift=3)

\`\`\`asm
; 编码: narrowKlass = klass_address >> 3
shr rax, 3              ; 1 条指令

; 解码: klass_address = narrowKlass << 3
movl eax, [rdi + 8]     ; 读取 narrowKlass
shl rax, 3              ; 1 条指令
\`\`\`

### 10.3 对比 CompressedOops (base=0, shift=3)

\`\`\`asm
; CompressedOops 编码
shr rax, 3              ; narrowOop = oop >> 3

; CompressedKlassPointers 编码 (标准条件)
sub rax, 0x800000000    ; narrowKlass = klass - base

; 两者都只需要 1 条指令，性能基本相同
\`\`\`

---

## 11. 面试 Q&A

### Q1: 什么是 Compressed Class Pointers？和 Compressed Oops 有什么区别？

**回答要点**：

Compressed Class Pointers 是将对象头中的 64 位 Klass 指针压缩为 32 位存储的优化机制。

两者的核心区别：
- **CompressedOops** 压缩的是 Java 堆中的**对象引用**（oop），指向 Java 堆
- **CompressedKlassPointers** 压缩的是**对象头中的 Klass 指针**，指向 Compressed Class Space（Metaspace 子区）

在标准条件 (-Xms8g -Xmx8g) 下：
- CompressedOops：base=0, shift=3（ZeroBased 模式），编码就是 `oop >> 3`
- CompressedKlassPointers：base=0x800000000(32GB), shift=0（BaseKlass 模式），编码就是 `klass - base`

两者都只需要 1 条 x86 指令完成编解码。

### Q2: narrow_klass_base 和 narrow_klass_shift 是怎么确定的？

**回答要点**：

在 `Metaspace::set_narrow_klass_base_and_shift()` 中决定：

1. **base 的确定**：如果 `类空间最高地址 ≤ 32GB（KlassEncodingMetaspaceMax）`，则 base=0；否则 base=metaspace_base。标准条件下类空间在 [32GB~33GB]，超过 32GB，所以 base=32GB。

2. **shift 的确定**：如果 `类空间总大小 ≤ 4GB（UnscaledClassSpaceMax）`，则 shift=0；否则 shift=3。标准条件下类空间 1GB < 4GB，所以 shift=0。

GDB 验证：base=0x800000000, shift=0。

### Q3: Compressed Class Space 放的是什么？大小是多少？

**回答要点**：

Compressed Class Space 只存放**Klass 家族的对象**（InstanceKlass、ArrayKlass 等），即那些会被对象头中的 narrowKlass 引用的元数据对象。

其他元数据（Method、ConstantPool、Symbol 等）存放在非类 Metaspace 中，不需要被压缩指针编码。

默认大小 1GB（\`CompressedClassSpaceSize\`），启动后实际使用非常少（GDB 测量：启动时仅用 78KB）。

### Q4: 堆超过多大就不能使用 Compressed Class Pointers 了？

**回答要点**：

准确说是 **堆 > 32GB** 时不能使用。

因为 CompressedKlassPointers 依赖 CompressedOops（关闭 Oops → 关闭 KlassPointers）。CompressedOops 最大支持 32GB 堆（32位 × 8字节对齐 = 32GB），堆超过 32GB 必须关闭 CompressedOops，CompressedKlassPointers 也随之关闭。

此时对象头的 Klass 指针变回 8 字节，每个对象多花 4 字节。

### Q5: 为什么类空间在 32GB 以上，还能用 shift=0？

**回答要点**：

因为 shift 的决定取决于**类空间自身的大小**，而不是其绝对地址。

shift=0 的条件是 `(higher_address - lower_base) ≤ 4GB`，即类空间的总大小不超过 4GB。标准条件下类空间只有 1GB（33GB - 32GB = 1GB），远小于 4GB，所以 shift=0。

shift=0 意味着 narrowKlass 直接等于相对 base 的字节偏移（无需位移），编解码只需一条 add/sub 指令。

### Q6: UseCompressedClassPointers 和 UseCompressedOops 的关系？

**回答要点**：

\`UseCompressedOops\` 是 \`UseCompressedClassPointers\` 的**前提条件**。

\`\`\`
UseCompressedOops = false → UseCompressedClassPointers 强制 = false
UseCompressedOops = true  → UseCompressedClassPointers 默认 = true (可单独关闭)
\`\`\`

原因：CompressedClassPointers 的实现依赖 CompressedOops 的基础设施（NarrowPtrStruct 共享、reserve_heap 中的地址规划等）。关闭 Oops 后没有必要也无法维护 Klass 的压缩编码。

---

## 12. GDB 验证脚本

### 12.1 压缩类指针初始化验证

\`\`\`gdb
# 文件: jvm-md/tmp-file/compressed-klass/gdb_compressed_klass.txt

set pagination off
set print pretty on

b Metaspace::set_narrow_klass_base_and_shift
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

printf "metaspace_base: %p\n", metaspace_base
printf "cds_base: %p\n", cds_base
finish

printf "narrow_klass_base: %p\n", Universe::_narrow_klass._base
printf "narrow_klass_shift: %d\n", Universe::_narrow_klass._shift
printf "CompressedClassSpaceSize: %lu MB\n", CompressedClassSpaceSize/1024/1024
quit
\`\`\`

### 12.2 Klass 编码验证

\`\`\`gdb
# 文件: jvm-md/tmp-file/compressed-klass/gdb_klass_encode.txt

set pagination off
b universe_post_init
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

set \$base = Universe::_narrow_klass._base
set \$shift = Universe::_narrow_klass._shift
set \$klass = Universe::_byteArrayKlassObj
printf "byte[] Klass: %p\n", \$klass
printf "narrowKlass: %u\n", (unsigned int)((uint64_t)((char*)\$klass - (char*)\$base) >> \$shift)
quit
\`\`\`

---

## 13. 源码索引

| 文件 | 路径 | 关键内容 |
|------|------|---------|
| universe.hpp:79 | \`memory/universe.hpp\` | NarrowPtrStruct 结构体定义 |
| universe.hpp:192 | \`memory/universe.hpp\` | _narrow_klass / _narrow_oop 静态字段 |
| universe.hpp:245 | \`memory/universe.hpp\` | set_narrow_klass_base() |
| universe.hpp:437 | \`memory/universe.hpp\` | narrow_klass_base() / shift() 访问器 |
| universe.hpp:454 | \`memory/universe.hpp\` | set_narrow_klass_shift() (assert shift==0 or 3) |
| klass.inline.hpp:48 | \`oops/klass.inline.hpp\` | encode_klass_not_null() 编码实现 |
| klass.inline.hpp:60 | \`oops/klass.inline.hpp\` | decode_klass_not_null() 解码实现 |
| oopsHierarchy.hpp:40 | \`oops/oopsHierarchy.hpp\` | \`typedef juint narrowKlass\` |
| oop.hpp:60 | \`oops/oop.hpp\` | _metadata union (Klass* / narrowKlass) |
| metaspace.cpp:1023 | \`memory/metaspace.cpp\` | set_narrow_klass_base_and_shift() 核心决策 |
| metaspace.cpp:1085 | \`memory/metaspace.cpp\` | allocate_metaspace_compressed_klass_ptrs() |
| metaspace.cpp:1384 | \`memory/metaspace.cpp\` | global_initialize() 入口 |
| globalDefinitions.hpp:510 | \`utilities/globalDefinitions.hpp\` | LogKlassAlignmentInBytes/KlassEncodingMetaspaceMax |
| globals.hpp:1822 | \`runtime/globals.hpp\` | CompressedClassSpaceSize 默认 1G |
| virtualspace.cpp:665 | \`memory/virtualspace.cpp\` | reserve_heap 为类空间预留位置 |

---

*最后更新: 2026-02-09*
*GDB 验证环境: OpenJDK 11, -Xms8g -Xmx8g -XX:+UseG1GC, 16 核*
