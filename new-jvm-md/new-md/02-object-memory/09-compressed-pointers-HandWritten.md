# 压缩指针的完整实现 — 我以为 32GB 限制是"硬编码的魔法数字"

> 第一人称学习笔记 · 基于 OpenJDK 11 源码  
> 承接：`05-object-layout-HandWritten.md` 遗留问题 3  
> 核心原则：**第一人称 · 学习时间线 · 真实踩坑 · 源码级深度**

---

## 第零天：我以为压缩指针就是"把 64 位指针压成 32 位"

在 05 那篇笔记里，我知道了压缩指针的基本原理：

```
编码：narrowOop = (oop - heap_base) >> shift
解码：oop = (narrowOop << shift) + heap_base
```

我以为这就是全部了。32GB 限制？我以为是某个工程师随手写的魔法数字。`heap_base` 是什么？我以为就是堆的起始地址，JVM 随便选一个地址就行了。

结果翻开源码，发现这里面有三个我完全没想到的设计：

**没想到 1：压缩指针有四种模式，不是一种**

`UnscaledNarrowOop`、`ZeroBasedNarrowOop`、`DisjointBaseNarrowOop`、`HeapBasedNarrowOop`——四种模式，编解码逻辑完全不同，JVM 启动时根据堆大小和地址自动选择。

**没想到 2：32GB 不是魔法数字，是数学推导出来的**

32 位能表示 2³² = 4GB 地址空间。对象 8 字节对齐，低 3 位永远是 0，可以省略。所以 32 位能寻址 4GB × 8 = 32GB。这是数学，不是魔法。

**没想到 3：`heap_base` 不是随便选的，JVM 会主动"抢占"低地址**

JVM 启动时会主动尝试把堆分配在 4GB 以内（Unscaled 模式）或 32GB 以内（ZeroBased 模式），这样 `heap_base` 就可以是 0，编解码最快。如果抢不到，才退化到需要 base 的模式。

---

## 第一天：四种压缩模式的本质

### 坑：我以为只有一种编解码公式

翻开 `universe.hpp:405`，发现有个枚举我完全没注意到：

```cpp
// universe.hpp:405-411
enum NARROW_OOP_MODE {
  UnscaledNarrowOop  = 0,   // base=0, shift=0
  ZeroBasedNarrowOop = 1,   // base=0, shift=3
  DisjointBaseNarrowOop = 2, // base!=0 但 base 的位与 oop 的位不重叠
  HeapBasedNarrowOop = 3,   // base!=0，需要减法
  AnyNarrowOopMode = 4
};
```

四种模式！再看 `narrow_oop_mode()` 的判断逻辑：

```cpp
// universe.cpp:1127-1141
Universe::NARROW_OOP_MODE Universe::narrow_oop_mode() {
  if (narrow_oop_base_disjoint()) {
    return DisjointBaseNarrowOop;  // ★ base 的高位与 oop 的低位不重叠
  }
  if (narrow_oop_base() != 0) {
    return HeapBasedNarrowOop;     // ★ base != 0，需要减法
  }
  if (narrow_oop_shift() != 0) {
    return ZeroBasedNarrowOop;     // ★ base=0，但需要移位
  }
  return UnscaledNarrowOop;        // ★ base=0，shift=0，最快
}
```

判断顺序很有意思：先判断 Disjoint（特殊优化），再判断 base 是否为 0，最后判断 shift 是否为 0。

### 四种模式的编解码对比

通用公式（`compressedOops.inline.hpp:44-56`）：

```cpp
// compressedOops.inline.hpp:44-56
inline oop decode_not_null(narrowOop v) {
  address base  = Universe::narrow_oop_base();   // 运行时读取
  int     shift = Universe::narrow_oop_shift();  // 运行时读取
  oop result = (oop)(void*)((uintptr_t)base + ((uintptr_t)v << shift));
  return result;
}

inline narrowOop encode_not_null(oop v) {
  address base  = Universe::narrow_oop_base();
  int     shift = Universe::narrow_oop_shift();
  uint64_t pd = (uint64_t)(pointer_delta((void*)v, (void*)base, 1)); // v - base
  uint64_t result = pd >> shift;
  return (narrowOop)result;
}
```

这是通用实现，但 JIT 编译器会根据运行时确定的 base/shift 值内联优化：

| 模式 | base | shift | 编码公式 | 解码公式 | 触发条件 |
|------|------|-------|---------|---------|---------|
| **Unscaled** | 0 | 0 | `narrowOop = (uint32_t)oop` | `oop = (uint64_t)narrowOop` | 堆在 0~4GB 内 |
| **ZeroBased** | 0 | 3 | `narrowOop = oop >> 3` | `oop = narrowOop << 3` | 堆在 0~32GB 内 |
| **DisjointBase** | ≠0 | 3 | `narrowOop = (oop - base) >> 3` | `oop = (narrowOop << 3) \| base` | base 高位与 oop 低位不重叠 |
| **HeapBased** | ≠0 | 3 | `narrowOop = (oop - base) >> 3` | `oop = (narrowOop << 3) + base` | 堆超过 32GB 或地址不理想 |

**DisjointBase 的特殊优化**：当 base 的高位与 oop 的低 32 位不重叠时，解码可以用 `|`（位或）代替 `+`（加法），因为两者的位不会互相干扰。这在某些 CPU 上更快。

判断是否 Disjoint（`universe.hpp:419-422`）：

```cpp
// universe.hpp:419-422
static bool is_disjoint_heap_base_address(address addr) {
  return (((uint64_t)(intptr_t)addr) &
          (((uint64_t)UCONST64(0xFFFFffffFFFFffff)) >> (32-LogMinObjAlignmentInBytes))) == 0;
}
```

这个位运算的含义：检查 addr 的低 `(32 - 3) = 29` 位是否全为 0。如果是，说明 base 的有效位（高位）和 oop 的有效位（低 29 位）完全不重叠，可以用 `|` 代替 `+`。

---

## 第二天：32GB 限制是怎么算出来的

### 坑：我以为 32GB 是随手写的

翻开 `arguments.cpp:1639`：

```cpp
// arguments.cpp:1639
// 使用压缩指针时能够寻址的最大堆内存大小
OopEncodingHeapMax = (uint64_t(max_juint) + 1) << LogMinObjAlignmentInBytes;
```

拆开来看：
- `max_juint` = `0xFFFFFFFF` = 2³² - 1（32 位无符号整数最大值）
- `max_juint + 1` = `0x100000000` = 2³² = 4GB（narrowOop 能表示的地址数量）
- `LogMinObjAlignmentInBytes` = 3（对象 8 字节对齐，log₂(8) = 3）
- `4GB << 3` = `4GB × 8` = **32GB**

这是纯数学推导：

```
narrowOop 是 32 位整数，能表示 2³² = 4,294,967,296 个不同的值
每个值代表一个"格子"，每个格子 8 字节（对象对齐要求）
所以能寻址的总内存 = 4,294,967,296 × 8 = 34,359,738,368 字节 = 32GB
```

同理，4GB 的 Unscaled 边界（`globalDefinitions.hpp:517`）：

```cpp
// globalDefinitions.hpp:517
// Maximal size of heap where unscaled compression can be used. Also upper bound
// for heap placement: 4GB.
const uint64_t UnscaledOopHeapMax = (uint64_t(max_juint) + 1);
// = 2³² = 4GB
```

Unscaled 模式下 shift=0，每个 narrowOop 值直接对应一个字节地址，所以只能寻址 4GB。

### 两个关键常量的值

```
UnscaledOopHeapMax  = 4GB  = 0x0000_0001_0000_0000
OopEncodingHeapMax  = 32GB = 0x0000_0008_0000_0000
KlassEncodingMetaspaceMax = 32GB（narrowKlass 的上限，同样是 4GB << 3）
```

---

## 第三天：JVM 如何"抢占"低地址

### 坑：我以为 heap_base 就是堆的起始地址

翻开 `virtualspace.cpp:541`，发现 JVM 会主动尝试把堆分配在特定地址范围内：

```cpp
// virtualspace.cpp:541-750（核心逻辑）
void ReservedHeapSpace::initialize_compressed_heap(const size_t size, size_t alignment, bool large) {
  // ★ 前置检查：堆大小必须 ≤ 32GB
  guarantee(size + noaccess_prefix_size(alignment) <= OopEncodingHeapMax,
            "can not allocate compressed oop heap for this size");

  // ★ 堆的最低起始地址：2GB（Linux x86_64 上 HeapBaseMinAddress = 2GB）
  char* aligned_heap_base_min_address = 
      (char*)align_up((void*)HeapBaseMinAddress, alignment);
  
  // ...（三轮尝试，见下文）
}
```

**为什么堆不能从 0 开始？**

因为 0 地址是 NULL，JVM 需要用 NULL 检查来捕获空指针异常。如果堆从 0 开始，`narrowOop = 0` 就会和 NULL 混淆。所以堆的起始地址至少是 `HeapBaseMinAddress`（Linux 上是 2GB）。

### 三轮尝试策略

JVM 按优先级从高到低尝试三种分配策略：

```
第一轮：Unscaled 模式（base=0, shift=0）
  条件：堆大小 ≤ 2GB（2GB + size ≤ 4GB）
  目标：把堆放在 2GB~4GB 之间
  好处：编解码最快，narrowOop 直接就是地址

第二轮：ZeroBased 模式（base=0, shift=3）
  条件：堆大小 ≤ 29GB（2GB + size ≤ 31GB，留 1GB 给 CompressedClassSpace）
  目标：把堆放在 2GB~31GB 之间
  好处：base=0，解码只需要移位，不需要加法

第三轮：Disjoint/HeapBased 模式（base≠0）
  条件：前两轮都失败（堆 > 29GB 或地址被占用）
  目标：把堆放在 OopEncodingHeapMax 的整数倍地址上
  好处：可能满足 Disjoint 条件，用 | 代替 +
```

**第一轮：Unscaled 模式的尝试**（`virtualspace.cpp:605-637`）

```cpp
// virtualspace.cpp:605-637
// 条件：2GB + size ≤ 4GB，即 size ≤ 2GB
if (aligned_heap_base_min_address + size <= (char*)UnscaledOopHeapMax) {
  // 搜索范围：从高地址到低地址（优先高地址，减少碎片）
  char* const highest_start = align_down(
      (char*)UnscaledOopHeapMax - size, attach_point_alignment);  // 4GB - size
  char* const lowest_start  = align_up(
      aligned_heap_base_min_address, attach_point_alignment);     // 2GB
  
  // ★ 从 highest_start 向 lowest_start 逐步尝试
  try_reserve_range(highest_start, lowest_start, attach_point_alignment,
                    aligned_heap_base_min_address,
                    (char*)UnscaledOopHeapMax,  // 有效范围上界：4GB
                    size, alignment, large);
}
```

**第二轮：ZeroBased 模式的尝试**（`virtualspace.cpp:646-710`）

```cpp
// virtualspace.cpp:646-710
// 为 CompressedClassSpace 预留 1GB
char* zerobased_max = (char*)OopEncodingHeapMax;  // 32GB
if (UseCompressedClassPointers && !UseSharedSpaces &&
    OopEncodingHeapMax <= KlassEncodingMetaspaceMax &&
    (uint64_t)(aligned_heap_base_min_address + size + class_space) <= KlassEncodingMetaspaceMax) {
  // ★ 堆上界 = 32GB - 1GB = 31GB（留 1GB 给 Klass 空间）
  zerobased_max = (char*)OopEncodingHeapMax - class_space;
}

// 条件：2GB + size ≤ 31GB，即 size ≤ 29GB
if (aligned_heap_base_min_address + size <= zerobased_max &&
    (_base == NULL || _base + size > zerobased_max)) {
  
  char* const highest_start = align_down(zerobased_max - size, attach_point_alignment);
  char* lowest_start = aligned_heap_base_min_address;
  
  // ★ 避开 Unscaled 区域（如果第一轮已经尝试过 2GB~4GB，这里从 4GB-size 开始）
  uint64_t unscaled_end = UnscaledOopHeapMax - size;
  if (unscaled_end < UnscaledOopHeapMax) {  // 防止溢出
    lowest_start = MAX2(lowest_start, (char*)unscaled_end);
  }
  
  try_reserve_range(highest_start, lowest_start, attach_point_alignment,
                    aligned_heap_base_min_address, zerobased_max, size, alignment, large);
}
```

**第三轮：Disjoint 模式的尝试**（`virtualspace.cpp:720-745`）

```cpp
// virtualspace.cpp:720-745
// Disjoint 候选地址列表（OopEncodingHeapMax 的整数倍）
static uint64_t addresses[] = {
  2 * SIZE_32G,   // 64GB
  3 * SIZE_32G,   // 96GB
  4 * SIZE_32G,   // 128GB
  8 * SIZE_32G,   // 256GB
  // ...
};

// 逐个尝试
while (addresses[i] && (_base == NULL || ...)) {
  char* const attach_point = addresses[i];
  try_reserve_heap(size + noaccess_prefix, alignment, large, attach_point);
  i++;
}

// ★ 最后的兜底：不指定地址，让 OS 随机分配
if (_base == NULL) {
  initialize(size + noaccess_prefix, alignment, large, NULL, false);
}
```

**为什么 Disjoint 候选地址是 32GB 的整数倍？**

因为 `OopEncodingHeapMax = 32GB = 0x0000_0008_0000_0000`。32GB 的整数倍地址（64GB、96GB...）的低 35 位全为 0，而 narrowOop 的有效位在低 32 位，两者完全不重叠，满足 Disjoint 条件。

---

## 第四天：base 和 shift 是怎么最终确定的

### 坑：我以为分配完堆就确定了 base

翻开 `universe.cpp:960-985`，发现 base 和 shift 是在堆分配完成后，根据堆的实际地址范围来确定的：

```cpp
// universe.cpp:960-985
#ifdef _LP64
if (UseCompressedOops) {
  // ★ 判断是否需要 shift
  if ((uint64_t)Universe::heap()->reserved_region().end() > UnscaledOopHeapMax) {
    // 堆的结束地址超过 4GB → 需要 shift（否则 narrowOop 放不下）
    Universe::set_narrow_oop_shift(LogMinObjAlignmentInBytes);  // shift = 3
  }
  // ★ 判断 base 是否可以为 0
  if ((uint64_t)Universe::heap()->reserved_region().end() <= OopEncodingHeapMax) {
    // 堆的结束地址在 32GB 以内 → base = 0（ZeroBased 或 Unscaled）
    Universe::set_narrow_oop_base(0);
  }
  // ...
}
#endif
```

逻辑很清晰：
1. 如果堆结束地址 ≤ 4GB → shift=0，base=0 → **Unscaled 模式**
2. 如果堆结束地址 ≤ 32GB → shift=3，base=0 → **ZeroBased 模式**
3. 如果堆结束地址 > 32GB → shift=3，base≠0 → **Disjoint 或 HeapBased 模式**

注意：`set_narrow_oop_base(0)` 是在 `set_narrow_oop_shift` 之后调用的，所以如果堆在 32GB 以内，base 会被设为 0（覆盖掉之前可能设置的非零值）。

### NarrowPtrStruct：存储 base 和 shift 的结构体

```cpp
// universe.hpp:73-85
struct NarrowPtrStruct {
  address _base;   // 编解码的基地址，NULL 表示 base=0
  int     _shift;  // 移位量，0 或 LogMinObjAlignmentInBytes(=3)
  bool    _use_implicit_null_checks;  // 是否用隐式 null 检查
};

// Universe 中的两个实例
static struct NarrowPtrStruct _narrow_oop;    // 对象引用压缩
static struct NarrowPtrStruct _narrow_klass;  // Klass 指针压缩
static address _narrow_ptrs_base;             // 两者共用的 base（通常相同）
```

`_narrow_oop` 和 `_narrow_klass` 是两个独立的结构体，分别控制对象引用和 Klass 指针的压缩。它们可以独立开关（`UseCompressedOops` vs `UseCompressedClassPointers`）。

---

## 第五天：narrowKlass 的压缩——和 narrowOop 有什么不同

### 坑：我以为 narrowKlass 和 narrowOop 用同一套机制

翻开 `klass.inline.hpp:46-70`，发现 narrowKlass 的编解码和 narrowOop 几乎一样，但 base 和 shift 来自不同的地方：

```cpp
// klass.inline.hpp:46-70
inline narrowKlass Klass::encode_klass_not_null(Klass* v) {
  int    shift = Universe::narrow_klass_shift();  // ★ 注意：narrow_klass_shift，不是 narrow_oop_shift
  uint64_t pd = (uint64_t)(pointer_delta((void*)v, Universe::narrow_klass_base(), 1));
  // ★ 注意：narrow_klass_base，不是 narrow_oop_base
  uint64_t result = pd >> shift;
  return (narrowKlass)result;
}

inline Klass* Klass::decode_klass_not_null(narrowKlass v) {
  int    shift = Universe::narrow_klass_shift();
  Klass* result = (Klass*)(void*)((uintptr_t)Universe::narrow_klass_base() + ((uintptr_t)v << shift));
  return result;
}
```

公式完全一样，但用的是 `narrow_klass_base` 和 `narrow_klass_shift`。

### narrowKlass 的 base 和 shift 在哪里确定？

在 `metaspace.cpp:1023-1062`（`set_narrow_klass_base_and_shift`）：

```cpp
// metaspace.cpp:1023-1062
void Metaspace::set_narrow_klass_base_and_shift(address metaspace_base, address cds_base) {
  address lower_base    = metaspace_base;
  address higher_address = metaspace_base + compressed_class_space_size();

  // ★ 如果 Klass 空间能放进 32GB 以内，base = 0
  uint64_t klass_encoding_max = UnscaledClassSpaceMax << LogKlassAlignmentInBytes;
  // UnscaledClassSpaceMax = 4GB，LogKlassAlignmentInBytes = 3
  // klass_encoding_max = 4GB << 3 = 32GB
  if (higher_address <= (address)klass_encoding_max) {
    lower_base = 0;  // ★ base = 0，ZeroBased 模式
  }

  Universe::set_narrow_klass_base(lower_base);

  // ★ 如果 Klass 空间在 4GB 以内，shift = 0（Unscaled）
  if (!UseSharedSpaces &&
      (uint64_t)(higher_address - lower_base) <= UnscaledClassSpaceMax) {
    Universe::set_narrow_klass_shift(0);
  } else {
    Universe::set_narrow_klass_shift(LogKlassAlignmentInBytes);  // shift = 3
  }
}
```

### narrowOop vs narrowKlass 的关键差异

| 对比项 | narrowOop | narrowKlass |
|--------|-----------|-------------|
| **类型** | `juint`（32 位） | `juint`（32 位） |
| **指向** | Java 堆中的对象 | Metaspace 中的 Klass |
| **base** | `Universe::narrow_oop_base()` | `Universe::narrow_klass_base()` |
| **shift** | `Universe::narrow_oop_shift()`（0 或 3） | `Universe::narrow_klass_shift()`（0 或 3） |
| **最大范围** | 32GB（`OopEncodingHeapMax`） | 32GB（`KlassEncodingMetaspaceMax`） |
| **对齐要求** | 8 字节（`ObjectAlignmentInBytes`） | 8 字节（`KlassAlignmentInBytes`） |
| **开关参数** | `-XX:+UseCompressedOops` | `-XX:+UseCompressedClassPointers` |
| **base 确定时机** | 堆分配后（`Universe::initialize_heap`） | Metaspace 初始化时（`Metaspace::set_narrow_klass_base_and_shift`） |

**为什么 narrowKlass 的 base 通常是 0？**

因为 Metaspace 的 CompressedClassSpace 默认只有 1GB（`-XX:CompressedClassSpaceSize=1g`），远小于 32GB，所以几乎总是能放进 32GB 以内，base = 0。

---

## 第六天：打桩验证

### 验证目标

1. 8GB 堆下，实际走的是哪种压缩模式？
2. `narrow_oop_base` 和 `narrow_oop_shift` 的实际值是多少？
3. narrowKlass 的 base 和 shift 是多少？

### 打桩位置

在 `universe.cpp:1030`（`initialize_heap` 末尾，base/shift 确定之后）插入打桩：

```cpp
// universe.cpp:1030（initialize_heap 末尾）
// ★ PROBE-09: 压缩指针模式验证
#ifdef _LP64
if (UseCompressedOops) {
  ResourceMark rm;
  const char* mode_str = narrow_oop_mode_to_string(narrow_oop_mode());
  tty->print_cr("[PROBE-09] === 压缩指针模式验证 ===");
  tty->print_cr("[PROBE-09] narrow_oop_mode    = %s", mode_str);
  tty->print_cr("[PROBE-09] narrow_oop_base    = " PTR_FORMAT, p2i(narrow_oop_base()));
  tty->print_cr("[PROBE-09] narrow_oop_shift   = %d", narrow_oop_shift());
  tty->print_cr("[PROBE-09] heap.base          = " PTR_FORMAT, p2i(heap()->base()));
  tty->print_cr("[PROBE-09] heap.end           = " PTR_FORMAT, p2i(heap()->reserved_region().end()));
  tty->print_cr("[PROBE-09] heap.size          = " SIZE_FORMAT " MB", heap()->reserved_region().byte_size() / M);
  tty->print_cr("[PROBE-09] UnscaledOopHeapMax = " UINT64_FORMAT " GB", UnscaledOopHeapMax / G);
  tty->print_cr("[PROBE-09] OopEncodingHeapMax = " UINT64_FORMAT " GB", OopEncodingHeapMax / G);
}
if (UseCompressedClassPointers) {
  tty->print_cr("[PROBE-09] narrow_klass_base  = " PTR_FORMAT, p2i(narrow_klass_base()));
  tty->print_cr("[PROBE-09] narrow_klass_shift = %d", narrow_klass_shift());
}
#endif
```

### 验证结果

```
【实际运行】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC -Xint -version
┌────────────────────────────────────────────────────────────────┐
│ [PROBE-09] === 压缩指针模式验证 ===                             │
│ [PROBE-09] narrow_oop_mode    = Zero based                     │
│ [PROBE-09] narrow_oop_base    = 0x0000000000000000 (= 0)       │
│ [PROBE-09] narrow_oop_shift   = 3                              │
│ [PROBE-09] heap.base          = 0x0000000600000000 (= 24GB)    │
│ [PROBE-09] heap.end           = 0x0000000800000000 (= 32GB)    │
│ [PROBE-09] heap.size          = 8192 MB (= 8GB)                │
│ [PROBE-09] UnscaledOopHeapMax = 4 GB                           │
│ [PROBE-09] OopEncodingHeapMax = 32 GB                          │
│ [PROBE-09] narrow_klass_base  = 0x0000000000000000 (= 0)       │
│ [PROBE-09] narrow_klass_shift = 0   ← ★ Unscaled！不是 3      │
└────────────────────────────────────────────────────────────────┘
```

**结果解读**：

8GB 堆下，JVM 走的是 **ZeroBased 模式**：
- `heap.base = 24GB`：堆从 24GB 开始（OS 已占用 4GB~24GB 的地址空间，JVM 只能从 24GB 开始）
- `heap.end = 32GB`：堆结束于 32GB，恰好等于 `OopEncodingHeapMax`，在 32GB 以内 → base = 0
- `narrow_oop_shift = 3`：需要移位（因为堆超过了 4GB）
- `narrow_oop_base = 0`：base = 0（因为堆在 32GB 以内）

**意外发现：narrowKlass 走的是 Unscaled 模式（shift = 0）！**

`narrow_klass_shift = 0` 而不是 3，说明 CompressedClassSpace 被分配在了 **4GB 以内**。回看 `set_narrow_klass_base_and_shift` 的逻辑：

```cpp
// 如果 Klass 空间在 4GB 以内，shift = 0（Unscaled）
if (!UseSharedSpaces &&
    (uint64_t)(higher_address - lower_base) <= UnscaledClassSpaceMax) {  // ≤ 4GB
  Universe::set_narrow_klass_shift(0);  // ★ shift = 0，最快！
}
```

CompressedClassSpace 默认 1GB，OS 把它分配在了 4GB 以内，所以 narrowKlass 连移位都不需要，直接截断 32 位就是 Klass 地址。这是最优情况。

**手动验证编解码（ZeroBased 模式）**：

取一个对象地址 `0x640000000`（约 25GB，在堆范围 24GB~32GB 内）：
```
编码：narrowOop = (0x640000000 - 0) >> 3 = 0xC8000000 = 3,355,443,200
解码：oop = 0xC8000000 << 3 = 0x640000000 ✓
```

base = 0，编解码只需要移位，不需要加减法，性能最优。

---

## 第七天：UseCompressedOops 和 UseCompressedClassPointers 的独立控制

### 坑：我以为两个参数是绑定的

翻开 `arguments.cpp`，发现两个参数可以独立控制：

```
-XX:+UseCompressedOops           控制对象引用压缩（narrowOop）
-XX:+UseCompressedClassPointers  控制 Klass 指针压缩（narrowKlass）
```

但有一个约束：`UseCompressedClassPointers` 依赖 `UseCompressedOops`。如果关闭了 `UseCompressedOops`，`UseCompressedClassPointers` 也会自动关闭。

**为什么？**

因为 Klass 指针存储在对象头里（`oopDesc._metadata._compressed_klass`），如果对象引用本身都不压缩了（64 位宽），那 Klass 指针也没必要压缩——反正对象头已经很大了。

### 关闭压缩指针的场景

| 场景 | 参数 | 效果 |
|------|------|------|
| 堆 > 32GB | 自动关闭 | JVM 检测到堆超过 32GB，自动禁用压缩指针 |
| 手动关闭 | `-XX:-UseCompressedOops` | 所有引用用 8 字节，对象头 16 字节 |
| 只关闭 Klass 压缩 | `-XX:-UseCompressedClassPointers` | Klass 指针用 8 字节，对象头 16 字节 |

关闭压缩指针后，对象头从 12 字节变为 16 字节（markWord 8 + klass 8），每个对象多 4 字节，大堆下内存开销显著增加。

---

## 数据结构关系图

```mermaid
graph TD
    A[Universe 静态类] --> B[NarrowPtrStruct _narrow_oop\n_base / _shift / _use_implicit_null_checks]
    A --> C[NarrowPtrStruct _narrow_klass\n_base / _shift]
    A --> D[address _narrow_ptrs_base\n两者共用的 base]

    E[ReservedHeapSpace::initialize_compressed_heap] -->|三轮尝试| F{堆地址范围}
    F -->|堆结束 ≤ 4GB| G[Unscaled\nbase=0, shift=0]
    F -->|堆结束 ≤ 32GB| H[ZeroBased\nbase=0, shift=3]
    F -->|base 位不重叠| I[DisjointBase\nbase≠0, shift=3, 用|代替+]
    F -->|其他| J[HeapBased\nbase≠0, shift=3]

    K[Universe::initialize_heap] -->|堆分配后| L{heap.end ≤ 4GB?}
    L -->|是| M[shift=0, base=0\nUnscaled]
    L -->|否| N{heap.end ≤ 32GB?}
    N -->|是| O[shift=3, base=0\nZeroBased]
    N -->|否| P[shift=3, base≠0\nDisjoint/HeapBased]

    Q[Metaspace::set_narrow_klass_base_and_shift] -->|Metaspace 初始化后| R{ClassSpace ≤ 32GB?}
    R -->|是| S[klass_base=0, klass_shift=3]
    R -->|否| T[klass_base≠0, klass_shift=3]

    B --> U[CompressedOops::encode/decode\ncompressedOops.inline.hpp]
    C --> V[Klass::encode_klass/decode_klass\nklass.inline.hpp]

    style G fill:#90EE90
    style H fill:#87CEEB
    style I fill:#FFD700
    style J fill:#FFB6C1
    style M fill:#90EE90
    style O fill:#87CEEB
    style P fill:#FFB6C1
```

---

## 尾声：我现在怎么理解压缩指针

以前我以为压缩指针就是"把 64 位指针压成 32 位"，现在我知道这只是表面现象。完整的压缩指针机制有四个层次：

**第一层：数学基础**

32 位 × 8 字节对齐 = 32GB 寻址范围。这是数学，不是魔法。`OopEncodingHeapMax = (2³²) << 3 = 32GB`。

**第二层：四种模式**

JVM 根据堆的实际地址范围，自动选择最优的编解码模式：
- Unscaled（堆 ≤ 4GB）：最快，直接截断
- ZeroBased（堆 ≤ 32GB）：次快，只需移位
- DisjointBase：base 的位与 oop 的位不重叠，用 `|` 代替 `+`
- HeapBased：最慢，需要加减法

**第三层：主动抢占低地址**

JVM 不是被动接受 OS 分配的地址，而是主动尝试把堆放在 4GB 以内（Unscaled）或 32GB 以内（ZeroBased），以获得最优的编解码性能。

**第四层：两套独立机制**

`narrowOop`（对象引用）和 `narrowKlass`（Klass 指针）是两套独立的压缩机制，各有自己的 base 和 shift，分别在堆初始化和 Metaspace 初始化时确定。

---

## 还没搞懂的地方

**1. JIT 编译器如何内联优化编解码**

通用的 `encode/decode` 函数在运行时读取 `narrow_oop_base()` 和 `narrow_oop_shift()`，但 JIT 编译器会把这两个值内联为常量，生成最优的机器码。具体是在哪个阶段内联的？C2 的哪个 pass 处理这个？

**2. GC 移动对象时如何更新 narrowOop**

GC 移动对象后，所有指向该对象的 narrowOop 都需要更新。更新时是先解码成 64 位地址，计算新地址，再编码回 narrowOop 吗？还是有更快的方式？

**3. ZGC 为什么不支持压缩指针**

ZGC 使用染色指针（colored pointers），把 GC 状态信息编码在指针的高位。这和压缩指针的移位操作冲突，所以 ZGC 不支持 `UseCompressedOops`。具体冲突在哪里？

---

## 总结

### 数据结构层面

| 结构 | sizeof | 核心特征 |
|------|--------|---------|
| **NarrowPtrStruct** | 16 字节（address 8 + int 4 + bool 1 + padding 3） | 存储 base/shift/implicit_null_checks，`_narrow_oop` 和 `_narrow_klass` 各一个实例 |
| **narrowOop** | 4 字节（`juint`） | 压缩后的对象引用，存储在对象头和引用字段中 |
| **narrowKlass** | 4 字节（`juint`） | 压缩后的 Klass 指针，存储在对象头 offset=8 处 |

### 算法层面

| 算法 | 核心设计决策 |
|------|-------------|
| **堆地址选择** | 三轮尝试（Unscaled → ZeroBased → Disjoint），主动抢占低地址，优先 base=0 |
| **模式判断** | 堆分配后根据 `heap.end` 与 4GB/32GB 的关系确定 base 和 shift |
| **编码** | `(oop - base) >> shift`，base=0 时退化为纯移位 |
| **解码** | `(narrowOop << shift) + base`，Disjoint 时用 `\|` 代替 `+` |
| **narrowKlass** | 与 narrowOop 公式相同，但 base/shift 独立，在 Metaspace 初始化时确定 |

---

*文档状态：✅ 完成*  
*写作日期：2026-03-10*  
*承接文档：`05-object-layout-HandWritten.md`（遗留问题 3）*  
*核心源码：`universe.cpp:initialize_heap`、`virtualspace.cpp:initialize_compressed_heap`、`compressedOops.inline.hpp`、`klass.inline.hpp`、`metaspace.cpp:set_narrow_klass_base_and_shift`*
