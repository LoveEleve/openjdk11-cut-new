# universe_init() 完整逐行源码分析

> 源码文件：`src/hotspot/share/memory/universe.cpp` L681-874
> 标准条件：`-Xms8g -Xmx8g -XX:+UseG1GC`，Region=4MB，2048 Regions

---

## 一、概述

`universe_init()` 被称为 **Genesis（创世纪）**，是 JVM 启动过程中最核心的初始化函数之一。它负责创建 JVM 运行所需的全部基础设施——Java 堆、元空间、符号表、字符串常量池等。

**为什么叫"Genesis"？** 就像创世纪创造了天地万物，这个函数创造了 JVM 运行所需的"宇宙"。

### 在 JVM 启动流程中的位置

```
main()
 └─▶ JNI_CreateJavaVM()
      └─▶ Threads::create_vm()
           └─▶ init_globals()             [Java 主线程执行]
                ├─ codeCache_init()
                ├─ stubRoutines_init1()
                │
                ├─▶ universe_init()        ← 【当前分析目标】
                │
                ├─ interpreter_init()
                ├─ universe2_init()
                └─ universe_post_init()
```

### 完整调用链总览

```
universe_init()                                          [universe.cpp:681]
│
├─① assert × 4                                          ← 不变量断言 (L683-688)
├─② TraceTime timer("Genesis", ...)                      ← 计时开始 (L690)
├─③ JavaClasses::compute_hard_coded_offsets()            ← 计算 Java 字段偏移量 (L692)
│
├─④ Universe::initialize_heap()                          ← 【核心】初始化 Java 堆 (L694)
│   ├─ create_heap() → new G1CollectedHeap()
│   ├─ _collectedHeap->initialize()
│   ├─ ThreadLocalAllocBuffer::set_max_size(2MB)
│   ├─ 设置压缩对象指针 (base/shift)
│   ├─ AOTLoader::set_narrow_oop_shift()
│   └─ ThreadLocalAllocBuffer::startup_initialization()
│
├─  if (status != JNI_OK) return status;                 ← 错误检查 (L695-697)
│
├─⑤ SystemDictionary::initialize_oop_storage()           ← VM 弱引用容器 (L729)
├─⑥ Metaspace::global_initialize()                       ← 初始化元空间 (L746)
│   ├─ MetaspaceGC::initialize()
│   ├─ [CDS 分支: DumpSharedSpaces / UseSharedSpaces]
│   ├─ allocate_metaspace_compressed_klass_ptrs()
│   ├─ new VirtualSpaceList(8MB)
│   ├─ new ChunkManager()
│   └─ new MetaspaceTracer()
│
├─⑦ MetaspaceCounters::initialize_performance_counters() ← 4个 PerfData (L792)
├─⑧ CompressedClassSpaceCounters::initialize_performance_counters() ← 4个 PerfData (L793)
│
├─⑨ AOTLoader::universe_init()                           ← AOT 验证+堆创建 (L795)
├─⑩ JVMFlagConstraintList::check_constraints(AfterMemoryInit) (L798-800)
├─  if (!check_constraints) return JNI_EINVAL;           ← 错误检查
│
├─⑪ ClassLoaderData::init_null_class_loader_data()       ← Bootstrap CLD (L812)
├─⑫ new LatestMethodCache() × 6                          ← 方法缓存 (L832-837)
│
├─⑬ [CDS 分支] UseSharedSpaces:                          (L839-848)
│   ├─ MetaspaceShared::initialize_shared_spaces()
│   └─ StringTable::create_table()
├─  [非 CDS 分支]:                                        (L850-860)
│   ├─ SymbolTable::create_table()
│   ├─ StringTable::create_table()
│   └─ [CDS] DumpSharedSpaces: MetaspaceShared::prepare_for_dumping()
│
├─⑭ if (VerifySubSet) Universe::initialize_verify_flags() (L861-863)
├─⑮ ResolvedMethodTable::create_table()                  (L871)
│
└─  return JNI_OK;                                       (L873)
```

---

## 二、逐行分析

### 2.1 函数签名与断言检查 (L681-688)

```cpp
// universe.cpp:681
jint universe_init() {
  assert(!Universe::_fully_initialized, "called after initialize_vtables");
  guarantee(1 << LogHeapWordSize == sizeof(HeapWord),
         "LogHeapWordSize is incorrect.");
  guarantee(sizeof(oop) >= sizeof(HeapWord), "HeapWord larger than oop?");
  guarantee(sizeof(oop) % sizeof(HeapWord) == 0,
            "oop size is not not a multiple of HeapWord size");
```

**逐行解释：**

| 行号 | 代码 | 说明 |
|------|------|------|
| L681 | `jint universe_init()` | 返回 `jint`（等同 `int`），`JNI_OK=0` 表示成功，`JNI_EINVAL=-6` 表示失败 |
| L683 | `assert(!Universe::_fully_initialized, ...)` | **调试断言**（`#ifdef ASSERT` 才有效）：确保 `universe_init()` 在 `_fully_initialized` 被设为 true 之前调用。`_fully_initialized` 直到 `universe_post_init()` 末尾才设为 true，所以这里必为 false |
| L684-685 | `guarantee(1 << LogHeapWordSize == sizeof(HeapWord), ...)` | **生产断言**（始终有效）：验证 `LogHeapWordSize` 常量与 `sizeof(HeapWord)` 一致。在 64 位系统中，`HeapWord` = 8 字节，`LogHeapWordSize` = 3，`1 << 3 = 8` ✓ |
| L686 | `guarantee(sizeof(oop) >= sizeof(HeapWord), ...)` | 验证 oop（对象指针）不小于 HeapWord。64 位系统：`sizeof(oop)` = 8，`sizeof(HeapWord)` = 8 ✓ |
| L687-688 | `guarantee(sizeof(oop) % sizeof(HeapWord) == 0, ...)` | 验证 oop 大小是 HeapWord 的整数倍。8 % 8 = 0 ✓ |

> **`assert` vs `guarantee` 的区别**：
> - `assert`：仅在 `#ifdef ASSERT`（即 debug/slowdebug 构建）中有效，生产构建被编译器移除
> - `guarantee`：始终有效，即使在 product 构建中也会检查，失败则终止 JVM

**这些断言解决什么问题？** JVM 内部大量代码依赖 HeapWord 和 oop 的大小关系进行指针运算和内存对齐。如果这些假设不成立（例如移植到新架构时配置错误），整个内存管理会崩溃。在启动最早期就检查这些不变量，可以把问题暴露在最容易定位的地方。

---

### 2.2 Genesis 计时 (L690)

```cpp
// universe.cpp:690
  TraceTime timer("Genesis", TRACETIME_LOG(Info, startuptime));
```

创建一个 `TraceTime` 对象，在构造时记录开始时间，在 `universe_init()` 函数结束（对象析构）时自动计算并输出耗时。

**JVM 参数**：`-Xlog:startuptime`

**输出示例**：
```
[0.089s][info][startuptime] Genesis: 89.123ms
```

---

### 2.3 JavaClasses::compute_hard_coded_offsets() (L692)

```cpp
// universe.cpp:692
  JavaClasses::compute_hard_coded_offsets();
```

**源码位置**：`src/hotspot/share/classfile/javaClasses.cpp:4462-4473`

```cpp
void JavaClasses::compute_hard_coded_offsets() {
  // java_lang_boxing_object
  java_lang_boxing_object::value_offset      = member_offset(java_lang_boxing_object::hc_value_offset);
  java_lang_boxing_object::long_value_offset  = align_up(member_offset(java_lang_boxing_object::hc_value_offset), BytesPerLong);

  // java_lang_ref_Reference
  java_lang_ref_Reference::referent_offset    = member_offset(java_lang_ref_Reference::hc_referent_offset);
  java_lang_ref_Reference::queue_offset       = member_offset(java_lang_ref_Reference::hc_queue_offset);
  java_lang_ref_Reference::next_offset        = member_offset(java_lang_ref_Reference::hc_next_offset);
  java_lang_ref_Reference::discovered_offset  = member_offset(java_lang_ref_Reference::hc_discovered_offset);
}
```

**解决什么问题？**

JVM 的 C++ 代码需要**直接**读写某些 Java 对象的字段（不走 Java 反射），比如：
- GC 需要直接读取 `Reference.referent` 来判断引用的目标对象是否存活
- 拆箱操作需要直接读取 `Integer.value` 来获取 int 值

这些字段在对象内存中的偏移量取决于对象头大小和是否开启压缩指针，所以需要动态计算。

**逐行解释：**

| 行号 | 代码 | 计算结果（标准条件） |
|------|------|---------------------|
| L4465 | `value_offset = member_offset(hc_value_offset)` | `hc_value_offset=0`，`member_offset(0) = 0*heapOopSize + instanceOopDesc::base_offset_in_bytes() = 0*4 + 12 = 12` |
| L4466 | `long_value_offset = align_up(member_offset(hc_value_offset), BytesPerLong)` | `align_up(12, 8) = 16`，因为 long 需要 8 字节对齐 |
| L4469 | `referent_offset = member_offset(hc_referent_offset)` | `hc_referent_offset=0`，结果 = 12 |
| L4470 | `queue_offset = member_offset(hc_queue_offset)` | `hc_queue_offset=1`，结果 = `1*4 + 12 = 16` |
| L4471 | `next_offset = member_offset(hc_next_offset)` | `hc_next_offset=2`，结果 = `2*4 + 12 = 20` |
| L4472 | `discovered_offset = member_offset(hc_discovered_offset)` | `hc_discovered_offset=3`，结果 = `3*4 + 12 = 24` |

**`member_offset()` 的计算公式**：
```
offset = hardcoded_field_index × heapOopSize + instanceOopDesc::base_offset_in_bytes()
```
- `heapOopSize` = 4（开启压缩指针时 oop 占 4 字节）
- `instanceOopDesc::base_offset_in_bytes()` = 12（对象头 = markOop 8B + compressed klass 4B）

**为什么叫"hard coded"？** 因为这些偏移量是硬编码在 C++ 里的字段序号（0, 1, 2, 3），而不是通过反射动态查找。这要求 JDK 源码中这些 Java 类的字段顺序不能随意改变，否则 JVM 会读到错误的字段。

**内存布局（以 Integer 为例）**：
```
Integer 对象内存布局（压缩指针模式）
┌──────────────────────────────────────┐
│ offset 0:  markOop (8 bytes)         │ ← 对象头：锁状态、GC年龄等
├──────────────────────────────────────┤
│ offset 8:  compressed klass (4 bytes)│ ← 指向 Integer 的 Klass
├──────────────────────────────────────┤
│ offset 12: int value (4 bytes)       │ ← value_offset = 12 ★
└──────────────────────────────────────┘
  总大小 = 16 bytes
```

**内存布局（以 Reference 为例）**：
```
Reference 对象内存布局
┌──────────────────────────────────────┐
│ offset 0:  markOop (8 bytes)         │
├──────────────────────────────────────┤
│ offset 8:  compressed klass (4 bytes)│
├──────────────────────────────────────┤
│ offset 12: referent (4 bytes, oop)   │ ← hc_referent_offset=0, offset=12
├──────────────────────────────────────┤
│ offset 16: queue (4 bytes, oop)      │ ← hc_queue_offset=1, offset=16
├──────────────────────────────────────┤
│ offset 20: next (4 bytes, oop)       │ ← hc_next_offset=2, offset=20
├──────────────────────────────────────┤
│ offset 24: discovered (4 bytes, oop) │ ← hc_discovered_offset=3, offset=24
└──────────────────────────────────────┘
  总大小 = 32 bytes (含对齐)
```

---

### 2.4 Universe::initialize_heap() (L694-697)

```cpp
// universe.cpp:694-697
  jint status = Universe::initialize_heap();
  if (status != JNI_OK) {
    return status;
  }
```

这是 `universe_init()` 的**核心操作**，负责创建整个 Java 堆。如果堆初始化失败（如内存不足），直接返回错误码，JVM 启动终止。

#### 2.4.1 initialize_heap() 完整源码分析

**源码位置**：`src/hotspot/share/memory/universe.cpp:924-1009`

```cpp
jint Universe::initialize_heap() {
  _collectedHeap = create_heap();                           // L926
  jint status = _collectedHeap->initialize();               // L928
  if (status != JNI_OK) {                                   // L929
    return status;                                          // L930
  }                                                         // L931
  log_info(gc)("Using %s", _collectedHeap->name());         // L932
  ThreadLocalAllocBuffer::set_max_size(Universe::heap()->max_tlab_size()); // L958

#ifdef _LP64                                                // L960
  if (UseCompressedOops) {                                  // L961
    if ((uint64_t)Universe::heap()->reserved_region().end() > UnscaledOopHeapMax) {  // L968
      Universe::set_narrow_oop_shift(LogMinObjAlignmentInBytes);  // L970
    }
    if ((uint64_t)Universe::heap()->reserved_region().end() <= OopEncodingHeapMax) { // L972
      Universe::set_narrow_oop_base(0);                     // L974
    }
    AOTLoader::set_narrow_oop_shift();                      // L976
    Universe::set_narrow_ptrs_base(Universe::narrow_oop_base()); // L978

    LogTarget(Info, gc, heap, coops) lt;                    // L980
    if (lt.is_enabled()) {                                  // L981
      ResourceMark rm;                                      // L982
      LogStream ls(lt);                                     // L983
      Universe::print_compressed_oops_mode(&ls);            // L984
    }

    Arguments::PropertyList_add(new SystemProperty("java.vm.compressedOopsMode",
                                                   narrow_oop_mode_to_string(narrow_oop_mode()),
                                                   false));  // L988-990
  }
  assert((intptr_t)Universe::narrow_oop_base() <= (intptr_t)(Universe::heap()->base() -
         os::vm_page_size()) ||
         Universe::narrow_oop_base() == NULL, "invalid value");  // L993-995
  assert(Universe::narrow_oop_shift() == LogMinObjAlignmentInBytes ||
         Universe::narrow_oop_shift() == 0, "invalid value");    // L996-997
#endif                                                      // L998

  if (UseTLAB) {                                            // L1003
    assert(Universe::heap()->supports_tlab_allocation(),
           "Should support thread-local allocation buffers"); // L1004-1005
    ThreadLocalAllocBuffer::startup_initialization();        // L1006
  }
  return JNI_OK;                                            // L1008
}
```

**逐行解释：**

**L926: `_collectedHeap = create_heap()`**

调用 `Universe::create_heap()`（L876-878），内部通过 `GCConfig::arguments()->create_heap()` 根据 GC 策略创建对应的堆实现。在标准条件（`-XX:+UseG1GC`）下，创建 `G1CollectedHeap` 对象。此时只是在 C 堆上 `new` 了一个 C++ 对象，**还没有分配堆内存**。

**L928: `status = _collectedHeap->initialize()`**

调用 `G1CollectedHeap::initialize()`，这是真正分配 8GB 堆内存的地方。内部通过 `mmap` 系统调用映射 8GB 虚拟地址空间（从 `0x600000000` 开始），并初始化 2048 个 HeapRegion、RememberedSet、CardTable 等 G1 GC 所需的辅助数据结构。这是整个 `universe_init()` 中最耗时的操作。

**L929-931: 错误检查**

如果 `initialize()` 返回非 `JNI_OK`（比如 `mmap` 失败，内存不足），直接返回错误码，`universe_init()` 的调用方会终止 JVM。

**L932: `log_info(gc)("Using %s", _collectedHeap->name())`**

输出正在使用的 GC 类型。通过 `-Xlog:gc` 可看到：
```
[0.012s][info][gc] Using G1
```

**L958: `ThreadLocalAllocBuffer::set_max_size(Universe::heap()->max_tlab_size())`**

设置 TLAB 的最大尺寸上限。对于 G1 GC，`max_tlab_size() = region_size / 2 = 4MB / 2 = 2MB`（262144 words）。

**为什么是 Region 的一半？** TLAB 必须完整放入单个 Region。而 G1 中，对象 > `region_size/2` 会被视为 Humongous 对象，走特殊分配路径。TLAB 内的对象不应触发 Humongous 逻辑，所以 TLAB 本身必须 < Humongous 阈值。

#### 2.4.2 压缩对象指针设置 (L960-998)

这段代码被 `#ifdef _LP64` 包裹，只在 64 位系统上编译。

```cpp
#ifdef _LP64
  if (UseCompressedOops) {
```

`UseCompressedOops` 在 64 位 JVM 中默认为 true。压缩指针将 64 位对象指针压缩为 32 位，节省大量内存。

**L968-971: 判断是否需要 shift**

```cpp
    if ((uint64_t)Universe::heap()->reserved_region().end() > UnscaledOopHeapMax) {
      Universe::set_narrow_oop_shift(LogMinObjAlignmentInBytes);
    }
```

- `UnscaledOopHeapMax` = `4GB` (`(uint64_t(max_juint) + 1)`)
- 堆末尾地址 = `0x800000000`（32GB）> 4GB → 条件成立
- `LogMinObjAlignmentInBytes` = 3（Java 对象 8 字节对齐，`log2(8) = 3`）
- 所以设置 `_narrow_oop._shift = 3`

**含义**：堆超出 4GB 范围，不能用 UnscaledNarrowOop 模式（直接用 32 位值表示地址），需要左移 3 位才能编码到 32GB 范围。

**L972-975: 判断是否可以 ZeroBased**

```cpp
    if ((uint64_t)Universe::heap()->reserved_region().end() <= OopEncodingHeapMax) {
      Universe::set_narrow_oop_base(0);
    }
```

- `OopEncodingHeapMax` = `32GB` (`(uint64_t(max_juint) + 1) << LogMinObjAlignmentInBytes`)
- 堆末尾 = `0x800000000` = 32GB ≤ 32GB → 条件成立
- 设置 `_narrow_oop._base = 0`（NULL）

**含义**：堆在 32GB 范围内，可以用 ZeroBased 模式，base = 0，解码公式简化为 `oop = narrow_oop << 3`。

**最终压缩指针配置：**
```
ZeroBased 模式:
  _narrow_oop._base  = NULL (0)
  _narrow_oop._shift = 3
  编码: narrow_oop = address >> 3
  解码: address    = narrow_oop << 3
```

**L976: `AOTLoader::set_narrow_oop_shift()`**

如果有 AOT 库加载，将当前 shift 值同步到 AOT 库的配置。标准条件下 `UseAOT = false`，此调用内部直接跳过。

**L978: `Universe::set_narrow_ptrs_base(Universe::narrow_oop_base())`**

设置 `_narrow_ptrs_base`，这是给汇编代码（Stub/编译代码）使用的基地址。这样生成的机器码可以通过全局变量快速获取 base，不需要每次都从 Universe 对象中读取。

**L980-985: 日志输出**

```cpp
    LogTarget(Info, gc, heap, coops) lt;
    if (lt.is_enabled()) {
      ResourceMark rm;
      LogStream ls(lt);
      Universe::print_compressed_oops_mode(&ls);
    }
```

**JVM 参数**：`-Xlog:gc+heap+coops=info`

**输出示例**：
```
[0.015s][info][gc,heap,coops] Heap address: 0x0000000600000000, size: 8192 MB, Compressed Oops mode: Zero based, Oop shift amount: 3
```

**L988-990: 设置系统属性**

```cpp
    Arguments::PropertyList_add(new SystemProperty("java.vm.compressedOopsMode",
                                                   narrow_oop_mode_to_string(narrow_oop_mode()),
                                                   false));
```

将压缩指针模式注册为系统属性 `java.vm.compressedOopsMode`。值为 `"Zero based"`。`false` 参数表示这个属性是 internal 的，不对外公开。可供测试框架验证当前 JVM 使用的压缩指针模式。

**L993-997: 后置断言**

```cpp
  assert((intptr_t)Universe::narrow_oop_base() <= (intptr_t)(Universe::heap()->base() -
         os::vm_page_size()) ||
         Universe::narrow_oop_base() == NULL, "invalid value");
  assert(Universe::narrow_oop_shift() == LogMinObjAlignmentInBytes ||
         Universe::narrow_oop_shift() == 0, "invalid value");
```

- 第一个断言：base 要么是 NULL（ZeroBased/Unscaled 模式），要么必须小于堆起始地址减一页（HeapBased 模式需要保留一页用于隐式空检查）
- 第二个断言：shift 只能是 3 或 0，不允许其他值

**L1003-1007: TLAB 启动初始化**

```cpp
  if (UseTLAB) {
    assert(Universe::heap()->supports_tlab_allocation(),
           "Should support thread-local allocation buffers");
    ThreadLocalAllocBuffer::startup_initialization();
  }
```

- `UseTLAB` 默认为 true
- 断言验证堆实现支持 TLAB（G1 当然支持）
- `startup_initialization()` 初始化 TLAB 全局配置（详见下文完整源码）

#### 2.4.3 ThreadLocalAllocBuffer::startup_initialization() 完整源码（threadLocalAllocBuffer.cpp:254-333）

```cpp
void ThreadLocalAllocBuffer::startup_initialization() {                      // L254

  _target_refills = 100 / (2 * TLABWasteTargetPercent);                      // L258
  _target_refills = MAX2(_target_refills, 2U);                               // L261

  _global_stats = new GlobalTLABStats();                                     // L273

#ifdef COMPILER2                                                             // L301
  if (is_server_compilation_mode_vm()) {                                     // L318
    int lines = MAX2(AllocatePrefetchLines, AllocateInstancePrefetchLines) + 2;// L319
    _reserve_for_allocation_prefetch = (AllocatePrefetchDistance +            // L320
        AllocatePrefetchStepSize * lines) / (int)HeapWordSize;
  }                                                                          // L322
#endif                                                                       // L323

  guarantee(Thread::current()->is_Java_thread(),                             // L327
            "tlab initialization thread not Java thread");
  Thread::current()->tlab().initialize();                                     // L329

  log_develop_trace(gc, tlab)("TLAB min: " SIZE_FORMAT                       // L331
      " initial: " SIZE_FORMAT " max: " SIZE_FORMAT,
      min_size(), Thread::current()->tlab().initial_desired_size(), max_size());
}                                                                            // L333
```

| 行号 | 源码 | 标准条件下的行为 |
|------|------|-----------------|
| L258 | `_target_refills = 100 / (2 * TLABWasteTargetPercent)` | `TLABWasteTargetPercent=1` → `100 / 2` = **50** |
| L261 | `_target_refills = MAX2(_target_refills, 2U)` | `MAX2(50, 2)` = **50**（至少 2 次，避免启动期 GC） |
| L273 | `_global_stats = new GlobalTLABStats()` | C 堆分配全局 TLAB 统计收集器（记录所有线程的 TLAB 使用情况） |
| L301 | `#ifdef COMPILER2` | C2 编译器存在，条件成立 |
| L318 | `if (is_server_compilation_mode_vm())` | Server 模式 = **true** |
| L319 | `int lines = MAX2(AllocatePrefetchLines, AllocateInstancePrefetchLines) + 2` | 计算预取缓存行数 |
| L320-321 | `_reserve_for_allocation_prefetch = (Distance + StepSize * lines) / HeapWordSize` | 计算 TLAB 尾部保留空间，防止 C2 预取指令越界访问未映射内存 |
| L327 | `guarantee(Thread::current()->is_Java_thread(), ...)` | 确保当前线程是 Java 主线程 |
| L329 | `Thread::current()->tlab().initialize()` | **重新初始化主线程的 TLAB**（主线程在堆初始化前创建，此时堆已就绪需要重新设置 TLAB） |
| L331-332 | `log_develop_trace(gc, tlab)(...)` | `-Xlog:gc+tlab=trace`（仅 debug 构建）输出 TLAB min/initial/max 大小 |

**设计要点**：`_target_refills = 50` 意味着每个 GC 周期，每个线程期望重填 TLAB 50 次。TLAB 初始大小 = Eden / (线程数 × 50)。这个值会在运行时根据实际分配速率动态调整。

**压缩指针模式判定流程图：**

```
堆末尾地址 end
    │
    ├─ end ≤ 4GB ──→ Unscaled: base=0, shift=0
    │                 解码: oop = narrow_oop
    │
    ├─ 4GB < end ≤ 32GB ──→ ZeroBased: base=0, shift=3  ★ 标准 8GB 走这里
    │                        解码: oop = narrow_oop << 3
    │
    └─ end > 32GB ──→ HeapBased: base=heap_base-page, shift=3
                       解码: oop = base + (narrow_oop << 3)
```

---

### 2.5 SystemDictionary::initialize_oop_storage() (L729)

```cpp
// universe.cpp:729
  SystemDictionary::initialize_oop_storage();
```

**源码位置**：`src/hotspot/share/classfile/systemDictionary.cpp:3045-3075`

```cpp
void SystemDictionary::initialize_oop_storage() {
  _vm_weak_oop_storage =
    new OopStorage("VM Weak Oop Handles",
                   VMWeakAlloc_lock,
                   VMWeakActive_lock);
}
```

#### OopStorage 构造函数完整源码（oopStorage.cpp:720-739）

```cpp
OopStorage::OopStorage(const char* name,                                     // L720
                       Mutex* allocation_mutex,
                       Mutex* active_mutex) :
  _name(dup_name(name)),                                                     // L723
  _active_array(ActiveArray::create(initial_active_array_size)),             // L724
  _allocation_list(),                                                        // L725
  _deferred_updates(NULL),                                                   // L726
  _allocation_mutex(allocation_mutex),                                       // L727
  _active_mutex(active_mutex),                                               // L728
  _allocation_count(0),                                                      // L729
  _concurrent_iteration_active(false)                                        // L730
{                                                                            // L731
  _active_array->increment_refcount();                                       // L732
  assert(_active_mutex->rank() < _allocation_mutex->rank(),                  // L733
         "%s: active_mutex must have lower rank than allocation_mutex", _name);
  assert(_active_mutex->_safepoint_check_required != Mutex::_safepoint_check_always,// L735
         "%s: active mutex requires safepoint check", _name);
  assert(_allocation_mutex->_safepoint_check_required != Mutex::_safepoint_check_always,// L737
         "%s: allocation mutex requires safepoint check", _name);
}                                                                            // L739
```

| 行号 | 源码 | 说明 |
|------|------|------|
| L723 | `_name(dup_name(name))` | 在 C 堆上复制名称字符串 `"VM Weak Oop Handles"` |
| L724 | `_active_array(ActiveArray::create(8))` | 创建初始容量为 8 的活跃 Block 指针数组（`initial_active_array_size=8`） |
| L725 | `_allocation_list()` | 空的分配链表（有空闲 slot 的 Block 双向链表） |
| L726 | `_deferred_updates(NULL)` | 延迟更新队列为空（无锁 CAS 链，用于并发添加/删除） |
| L727 | `_allocation_mutex(allocation_mutex)` | `VMWeakAlloc_lock` — 保护 slot 分配/释放 |
| L728 | `_active_mutex(active_mutex)` | `VMWeakActive_lock` — 保护 ActiveArray 修改 |
| L729 | `_allocation_count(0)` | 已分配 oop slot 数 = 0 |
| L730 | `_concurrent_iteration_active(false)` | 没有 GC 在并发遍历 |
| L732 | `_active_array->increment_refcount()` | 增加引用计数，防止并发迭代期间被释放 |
| L733-738 | 3 个 assert | 验证：active 锁 rank < allocation 锁 rank（锁序防死锁）；两把锁都不要求 safepoint 检查 |

**解决什么问题？**

JVM 内部有很多地方需要持有对 Java 对象的弱引用，比如：
- JNI 弱全局引用
- JVMTI 标记的对象
- MethodHandle 解析缓存中的 ResolvedMethodName

这些弱引用散落在 JVM 各处，GC 无法统一遍历。`OopStorage` 把它们集中存放，GC 可以一次性扫描所有弱引用，清除指向已回收对象的引用。

**"Weak"的含义**：弱引用不会阻止 GC 回收对象。如果一个对象只有弱引用指向它，GC 可以回收该对象，之后弱引用会被清除为 NULL。

**OopStorage 内部结构**：

```
OopStorage "VM Weak Oop Handles"
┌─────────────────────────────────────────────────────────────┐
│  _active_array (活动块数组)                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Block* │ Block* │ Block* │ Block* │ ... │           │   │
│  └────┼───┴────┼───┴────┼───┴────┼───┴─────┘           │   │
│       │        │        │        │                       │   │
│       ▼        ▼        ▼        ▼                       │   │
│   ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐                   │   │
│   │Block0│ │Block1│ │Block2│ │Block3│ ...               │   │
│   │ oop[]│ │ oop[]│ │ oop[]│ │ oop[]│                   │   │
│   │bitmap│ │bitmap│ │bitmap│ │bitmap│                   │   │
│   └──────┘ └──────┘ └──────┘ └──────┘                   │   │
│                                                          │   │
│  VMWeakActive_lock: 保护 _active_array 的修改            │   │
│  VMWeakAlloc_lock:  保护单个 Block 内的分配/释放          │   │
└─────────────────────────────────────────────────────────────┘
```

两把锁分离的好处：GC 遍历时只需要 active_lock，分配/释放只需要 alloc_lock，减少锁竞争。

---

### 2.6 Metaspace::global_initialize() (L746)

```cpp
// universe.cpp:746
  Metaspace::global_initialize();
```

**源码位置**：`src/hotspot/share/memory/metaspace.cpp:1384-1485`

Metaspace（元空间）是 JVM 存储类元数据的内存区域，包括类结构信息、方法字节码、常量池等。为什么不放在 Java 堆里？因为类元数据的生命周期与 Java 对象不同——类通常长期存在，放在堆里会增加 GC 负担。

#### 2.6.1 global_initialize() 完整源码（metaspace.cpp:1384-1485）

```cpp
void Metaspace::global_initialize() {                                        // L1384
  MetaspaceGC::initialize();                                                 // L1386

#if INCLUDE_CDS                                                              // L1389
  if (DumpSharedSpaces) {                                                    // L1390
    MetaspaceShared::initialize_dumptime_shared_and_meta_spaces();           // L1391
  }                                                                          // L1392
  else if (UseSharedSpaces) {                                                // L1393
    MetaspaceShared::initialize_runtime_shared_and_meta_spaces();            // L1398
  }                                                                          // L1399

  if (!DumpSharedSpaces && !UseSharedSpaces)                                 // L1401
#endif // INCLUDE_CDS                                                        // L1402
  {                                                                          // L1403
#ifdef _LP64                                                                 // L1404
    if (using_class_space()) {                                               // L1409
      char* base = (char*)align_up(Universe::heap()->reserved_region().end(),// L1410
                                    _reserve_alignment);
      allocate_metaspace_compressed_klass_ptrs(base, 0);                     // L1412
    }                                                                        // L1413
#endif // _LP64                                                              // L1414
  }                                                                          // L1415

  _first_chunk_word_size = InitialBootClassLoaderMetaspaceSize / BytesPerWord;// L1452
  _first_chunk_word_size = align_word_size_up(_first_chunk_word_size);        // L1453

  _first_class_chunk_word_size = MIN2((size_t)MediumChunk*6,                 // L1457
                                     (CompressedClassSpaceSize/BytesPerWord)*2);
  _first_class_chunk_word_size = align_word_size_up(_first_class_chunk_word_size);// L1459

  size_t word_size = VIRTUALSPACEMULTIPLIER * _first_chunk_word_size;         // L1463
  word_size = align_up(word_size, Metaspace::reserve_alignment_words());      // L1464

  _space_list = new VirtualSpaceList(word_size);                              // L1467
  _chunk_manager_metadata = new ChunkManager(false/*metaspace*/);             // L1468

  if (!_space_list->initialization_succeeded()) {                             // L1470
    vm_exit_during_initialization("Unable to setup metadata virtual space list.", NULL);// L1471
  }                                                                           // L1472

  _tracer = new MetaspaceTracer();                                            // L1481

  _initialized = true;                                                        // L1483
}                                                                             // L1485
```

#### 逐行注释表

| 行号 | 源码 | 标准条件下的行为 |
|------|------|-----------------|
| L1384 | `void Metaspace::global_initialize()` | 入口，无参数无返回值 |
| L1386 | `MetaspaceGC::initialize()` | 设 `_capacity_until_GC = MaxMetaspaceSize` ≈ 18EB（启动期不触发 Metaspace GC） |
| L1389 | `#if INCLUDE_CDS` | CDS 编译开关，默认打开 |
| L1390 | `if (DumpSharedSpaces)` | **false** — 不是在执行 `java -Xshare:dump` |
| L1393 | `else if (UseSharedSpaces)` | **默认 true**，但如 CDS 归档不可用会被置 false。标准分析假设非 CDS 路径 |
| L1401 | `if (!DumpSharedSpaces && !UseSharedSpaces)` | **true（标准条件）**→ 进入下面的代码块 |
| L1404 | `#ifdef _LP64` | 64 位系统，条件成立 |
| L1409 | `if (using_class_space())` | `using_class_space()` = `UseCompressedClassPointers` = **true** |
| L1410 | `char* base = (char*)align_up(heap->reserved_region().end(), _reserve_alignment)` | `align_up(0x800000000, 4MB)` = **`0x800000000`**（堆末尾已经 4MB 对齐） |
| L1412 | `allocate_metaspace_compressed_klass_ptrs(base, 0)` | 在 `0x800000000` 分配 1GB 压缩类空间，设置 `_narrow_klass` 编码参数（详见下文 2.6.2） |
| L1452 | `_first_chunk_word_size = InitialBootClassLoaderMetaspaceSize / BytesPerWord` | `4MB / 8 = 524288 words` = **4MB**（Bootstrap ClassLoader 首个数据 Chunk） |
| L1453 | `_first_chunk_word_size = align_word_size_up(...)` | 4MB 已对齐，无变化 |
| L1457-1458 | `_first_class_chunk_word_size = MIN2(MediumChunk*6, (CompressedClassSpaceSize/BytesPerWord)*2)` | `MIN2(4096*6, 268435456)` = **24576 words = 192KB**（首个类 Chunk） |
| L1459 | `_first_class_chunk_word_size = align_word_size_up(...)` | 192KB 已对齐，无变化 |
| L1463 | `size_t word_size = VIRTUALSPACEMULTIPLIER * _first_chunk_word_size` | `2 × 524288 = 1048576 words` = **8MB** |
| L1464 | `word_size = align_up(word_size, reserve_alignment_words())` | 8MB 已对齐到 4MB 边界，无变化 |
| L1467 | `_space_list = new VirtualSpaceList(word_size)` | mmap 预留 **8MB** 虚拟内存作为数据元空间 |
| L1468 | `_chunk_manager_metadata = new ChunkManager(false)` | 创建空闲 Chunk 管理器，`false` = 管理数据 Chunk（非 class） |
| L1470-1472 | `if (!_space_list->initialization_succeeded())` | 检查 VirtualSpaceList 是否成功初始化，失败则 `vm_exit` |
| L1481 | `_tracer = new MetaspaceTracer()` | C 堆分配一个空壳对象，运行时向 JFR 报告 Metaspace 事件 |
| L1483 | `_initialized = true` | 标记 Metaspace 初始化完成 |
| L1485 | `}` | 函数结束 |

> **为什么启动期 `_capacity_until_GC` 设为"无限大"？** JVM 启动时要加载大量核心类（java.lang.Object、java.lang.String 等），不希望因为 Metaspace 满而触发 GC。启动完成后，`Metaspace::post_initialize()` 会将阈值重新设为已使用量 + 少量余量。

> **为什么首个类 Chunk（192KB）要比 MediumChunk（32KB）大？** 避免被放入 Medium 空闲链表，而是作为 Humongous Chunk 单独管理，效率更高。

> **为什么数据元空间初始预留 2 倍首个 Chunk（8MB）？** `VIRTUALSPACEMULTIPLIER = 2`，预留增长空间，避免频繁扩展虚拟内存。

#### 2.6.2 allocate_metaspace_compressed_klass_ptrs() 完整源码（metaspace.cpp:1080-1232）

```cpp
void Metaspace::allocate_metaspace_compressed_klass_ptrs(                    // L1080
    char* requested_addr, address cds_base) {
  assert(!DumpSharedSpaces, "compress klass space is allocated by MetaspaceShared class.");// L1081
  assert(using_class_space(), "called improperly");                          // L1082
  assert(UseCompressedClassPointers, "Only use with CompressedKlassPtrs");   // L1083
  assert(compressed_class_space_size() < KlassEncodingMetaspaceMax,          // L1084
         "Metaspace size is too big");
  assert_is_aligned(requested_addr, _reserve_alignment);                     // L1086
  assert_is_aligned(cds_base, _reserve_alignment);                           // L1087
  assert_is_aligned(compressed_class_space_size(), _reserve_alignment);      // L1088

  // Don't use large pages for the class space.
  bool large_pages = false;                                                  // L1091

#if !(defined(AARCH64) || defined(PPC64))                                    // L1093
  ReservedSpace metaspace_rs = ReservedSpace(compressed_class_space_size(),  // L1095
                                             _reserve_alignment,
                                             large_pages,
                                             requested_addr);
#else // AARCH64 || PPC64                                                    // L1099
  ReservedSpace metaspace_rs;                                                // L1101

  if ((uint64_t)requested_addr + compressed_class_space_size() < 4*G) {     // L1105
    metaspace_rs = ReservedSpace(compressed_class_space_size(),              // L1106
                                 _reserve_alignment,
                                 large_pages,
                                 requested_addr);
  }                                                                          // L1110

  if (! metaspace_rs.is_reserved()) {                                        // L1112
    size_t increment = AARCH64_ONLY(4*)G;                                    // L1125
    for (char *a = align_up(requested_addr, increment);                      // L1126
         a < (char*)(1024*G);
         a += increment) {
      if (a == (char *)(32*G)) {                                             // L1129
        increment = 4*G;                                                     // L1131
      }

#if INCLUDE_CDS                                                              // L1134
      if (UseSharedSpaces                                                    // L1135
          && ! can_use_cds_with_metaspace_addr(a, cds_base)) {
        metaspace_rs = ReservedSpace(compressed_class_space_size(),          // L1139
                                     _reserve_alignment,
                                     large_pages,
                                     requested_addr);
        break;                                                               // L1143
      }
#endif                                                                       // L1145

      metaspace_rs = ReservedSpace(compressed_class_space_size(),            // L1147
                                   _reserve_alignment,
                                   large_pages,
                                   a);
      if (metaspace_rs.is_reserved())                                        // L1151
        break;
    }                                                                        // L1153
  }                                                                          // L1154

#endif // AARCH64 || PPC64                                                   // L1156

  if (!metaspace_rs.is_reserved()) {                                         // L1158
#if INCLUDE_CDS                                                              // L1159
    if (UseSharedSpaces) {                                                   // L1160
      size_t increment = align_up(1*G, _reserve_alignment);                  // L1161
      char *addr = requested_addr;                                           // L1166
      while (!metaspace_rs.is_reserved() && (addr + increment > addr) &&     // L1168
             can_use_cds_with_metaspace_addr(addr + increment, cds_base)) {
        addr = addr + increment;                                             // L1170
        metaspace_rs = ReservedSpace(compressed_class_space_size(),          // L1172
                                     _reserve_alignment, large_pages, addr);
      }                                                                      // L1174
    }                                                                        // L1175
#endif                                                                       // L1176
    if (!metaspace_rs.is_reserved()) {                                       // L1183
      metaspace_rs = ReservedSpace(compressed_class_space_size(),            // L1185
                                   _reserve_alignment, large_pages);
      if (!metaspace_rs.is_reserved()) {                                     // L1187
        vm_exit_during_initialization(err_msg("Could not allocate metaspace: "// L1188
                                              SIZE_FORMAT " bytes",
                                              compressed_class_space_size()));
      }                                                                      // L1190
    }                                                                        // L1191
  }                                                                          // L1192

  MemTracker::record_virtual_memory_type((address)metaspace_rs.base(), mtClass);// L1195

#if INCLUDE_CDS                                                              // L1197
  if (UseSharedSpaces && !can_use_cds_with_metaspace_addr(                   // L1199
      metaspace_rs.base(), cds_base)) {
    FileMapInfo::stop_sharing_and_unmap(                                      // L1200
        "Could not allocate metaspace at a compatible address");
  }                                                                          // L1202
#endif                                                                       // L1203

  set_narrow_klass_base_and_shift((address)metaspace_rs.base(),              // L1221
                                  UseSharedSpaces ? (address)cds_base : 0);
  initialize_class_space(metaspace_rs);                                      // L1224

  LogTarget(Trace, gc, metaspace) lt;                                        // L1226
  if (lt.is_enabled()) {                                                     // L1227
    ResourceMark rm;                                                         // L1228
    LogStream ls(lt);                                                        // L1229
    print_compressed_class_space(&ls, requested_addr);                       // L1230
  }                                                                          // L1231
}                                                                            // L1232
```

#### 逐行注释表

| 行号 | 源码 | 标准条件下的行为 |
|------|------|-----------------|
| L1080 | `allocate_metaspace_compressed_klass_ptrs(requested_addr, cds_base)` | 参数: `requested_addr=0x800000000`, `cds_base=0` |
| L1081-1088 | 6 个 assert | 调试断言：验证非 DumpSharedSpaces、使用压缩类指针、空间大小 < 4GB、地址对齐到 4MB |
| L1091 | `bool large_pages = false` | 压缩类空间不使用大页（与 Java 堆不同） |
| L1093 | `#if !(defined(AARCH64) \|\| defined(PPC64))` | **x86_64 走这个分支** |
| L1095-1098 | `ReservedSpace metaspace_rs = ReservedSpace(1GB, 4MB, false, 0x800000000)` | **核心操作**：通过 `mmap(0x800000000, 1GB, ...)` 在指定地址预留 1GB 虚拟内存 |
| L1099-1156 | `#else // AARCH64 \|\| PPC64` ... `#endif` | **x86_64 跳过整个 else 分支**。AArch64/PPC64 需要额外的地址搜索逻辑 |
| L1158 | `if (!metaspace_rs.is_reserved())` | 检查分配是否成功。**标准条件下一次就成功，跳过整个 fallback** |
| L1159-1191 | CDS fallback + 任意地址 fallback | 标准条件不进入。仅在首次 mmap 失败时，尝试 CDS 兼容地址或任意地址 |
| L1195 | `MemTracker::record_virtual_memory_type(..., mtClass)` | 向 NMT（Native Memory Tracking）记录该内存区域类型为 `mtClass` |
| L1199-1202 | `if (UseSharedSpaces && !can_use_cds_with_metaspace_addr(...))` | CDS 兼容性检查，标准非 CDS 条件跳过 |
| L1221-1222 | `set_narrow_klass_base_and_shift(0x800000000, 0)` | **关键**：设置 `_narrow_klass._base = 0x800000000`, `_narrow_klass._shift = 0`（1GB < 4GB 不需要 shift） |
| L1224 | `initialize_class_space(metaspace_rs)` | 用分配好的 ReservedSpace 初始化压缩类空间的 VirtualSpaceList 和 ChunkManager |
| L1226-1231 | 日志输出 | `-Xlog:gc+metaspace=trace` 可看到 `Narrow klass base/shift` 和空间地址 |

**标准条件下的执行路径总结（x86_64，非 CDS）**：

```
L1095: mmap(0x800000000, 1GB) → 成功
L1195: NMT 记录
L1221: _narrow_klass._base = 0x800000000, _narrow_klass._shift = 0
L1224: 初始化类空间 VirtualSpaceList + ChunkManager
```

压缩类指针编解码公式：
```
编码: narrow_klass = (klass_address - 0x800000000) >> 0
解码: klass_address = 0x800000000 + (narrow_klass << 0)

示例：Klass 位于 0x800001000
  narrow_klass = (0x800001000 - 0x800000000) >> 0 = 0x1000 = 4096
  对象头中存储 4 字节值 4096
  解码: 0x800000000 + (4096 << 0) = 0x800001000 ✓
```

#### 2.6.3 MetaspaceGC::initialize() 完整源码（metaspace.cpp:185-197）

```cpp
void MetaspaceGC::initialize() {                                             // L185
  // Set the high-water mark to MaxMetapaceSize during VM initializaton since
  // we can't do a GC during initialization.
  _capacity_until_GC = MaxMetaspaceSize;                                     // L196
}                                                                            // L197
```

| 行号 | 源码 | 标准条件下的行为 |
|------|------|-----------------|
| L196 | `_capacity_until_GC = MaxMetaspaceSize` | MaxMetaspaceSize 默认约 18EB（`max_uintx`），启动期不触发 Metaspace GC |

**Metaspace 初始化后的内存布局：**

```
JVM 虚拟地址空间布局
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  0x600000000  ┌───────────────────────────────────────────┐     │
│               │              Java 堆 (8 GB)               │     │
│               │         0x600000000 ~ 0x800000000         │     │
│  0x800000000  ├───────────────────────────────────────────┤     │
│               │         压缩类空间 (1 GB)                  │     │
│               │         0x800000000 ~ 0x840000000         │     │
│               │       存储 Klass 结构（类元数据）          │     │
│  0x840000000  └───────────────────────────────────────────┘     │
│                                                                 │
│                           ... 中间有空隙 ...                    │
│                                                                 │
│  0x7fffc29f0000  ┌───────────────────────────────────────┐     │
│                  │         数据元空间 (8 MB)               │     │
│                  │     存储 Method、ConstantPool 等        │     │
│  0x7fffc31f0000  └───────────────────────────────────────┘     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

### 2.7 MetaspaceCounters::initialize_performance_counters() (L792)

```cpp
// universe.cpp:792
  MetaspaceCounters::initialize_performance_counters();
```

**源码位置**：`src/hotspot/share/memory/metaspaceCounters.cpp:83-94`

```cpp
void MetaspaceCounters::initialize_performance_counters() {
  if (UsePerfData) {
    assert(_perf_counters == NULL, "Should only be initialized once");
    size_t min_capacity = 0;
    _perf_counters = new MetaspacePerfCounters("metaspace",
                                               min_capacity,     // = 0
                                               capacity(),       // MetaspaceUtils::committed_bytes()
                                               max_capacity(),   // MetaspaceUtils::reserved_bytes()
                                               used());          // MetaspaceUtils::used_bytes()
  }
}
```

**`UsePerfData`** 默认为 true（除非 `-XX:-UsePerfData` 关闭）。

`MetaspacePerfCounters` 构造函数（L51-60）创建 4 个 PerfData 计数器：

| 计数器路径 | 类型 | 初始值 | 说明 |
|-----------|------|--------|------|
| `sun.gc.metaspace.minCapacity` | 常量 | 0 | 最小容量（固定不变） |
| `sun.gc.metaspace.capacity` | 变量 | `committed_bytes()` | 已提交容量 |
| `sun.gc.metaspace.maxCapacity` | 变量 | `reserved_bytes()` ≈ 1032MB | 最大容量（预留总量） |
| `sun.gc.metaspace.used` | 变量 | `used_bytes()` | 已使用量 |

这些计数器存储在共享内存映射文件 `/tmp/hsperfdata_<user>/<pid>` 中，`jstat`、`jconsole`、`VisualVM` 等外部工具通过读取该文件获取监控数据，无需与 JVM 通信。

---

### 2.8 CompressedClassSpaceCounters::initialize_performance_counters() (L793)

```cpp
// universe.cpp:793
  CompressedClassSpaceCounters::initialize_performance_counters();
```

**源码位置**：`src/hotspot/share/memory/metaspaceCounters.cpp:126-140`

```cpp
void CompressedClassSpaceCounters::initialize_performance_counters() {
  if (UsePerfData) {
    assert(_perf_counters == NULL, "Should only be initialized once");
    const char* ns = "compressedclassspace";

    if (UseCompressedClassPointers) {
      size_t min_capacity = 0;
      _perf_counters = new MetaspacePerfCounters(ns, min_capacity, capacity(),
                                                 max_capacity(), used());
    } else {
      _perf_counters = new MetaspacePerfCounters(ns, 0, 0, 0, 0);
    }
  }
}
```

逻辑与上一个类似，但命名空间为 `compressedclassspace`，创建 4 个计数器：

| 计数器路径 | 标准条件初始值 |
|-----------|---------------|
| `sun.gc.compressedclassspace.minCapacity` | 0 |
| `sun.gc.compressedclassspace.capacity` | `committed_bytes(ClassType)` |
| `sun.gc.compressedclassspace.maxCapacity` | 1073741824 (1GB) |
| `sun.gc.compressedclassspace.used` | `used_bytes(ClassType)` |

注意 `UseCompressedClassPointers` 为 false 的分支：创建全 0 的计数器（占位，但值无意义）。

**查看方式**：
```bash
jstat -gc <pid>
# MC   - Metaspace Capacity (已提交)
# MU   - Metaspace Used (已使用)
# CCSC - Compressed Class Space Capacity
# CCSU - Compressed Class Space Used
```

---

### 2.9 AOTLoader::universe_init() (L795)

```cpp
// universe.cpp:795
  AOTLoader::universe_init();
```

**源码位置**：`src/hotspot/share/aot/aotLoader.cpp:171-210`

```cpp
void AOTLoader::universe_init() {
  if (UseAOT && libraries_count() > 0) {
    if (UseCompressedOops && AOTLib::narrow_oop_shift_initialized()) {
      int oop_shift = Universe::narrow_oop_shift();
      FOR_ALL_AOT_LIBRARIES(lib) {
        (*lib)->verify_flag((*lib)->config()->_narrowOopShift, oop_shift, "Universe::narrow_oop_shift");
      }
      if (UseCompressedClassPointers) {
        int klass_shift = Universe::narrow_klass_shift();
        FOR_ALL_AOT_LIBRARIES(lib) {
          (*lib)->verify_flag((*lib)->config()->_narrowKlassShift, klass_shift, "Universe::narrow_klass_shift");
        }
      }
    }
    // Create heaps for all valid libraries
    FOR_ALL_AOT_LIBRARIES(lib) {
      if ((*lib)->is_valid()) {
        AOTCodeHeap* heap = new AOTCodeHeap(*lib);
        {
          MutexLockerEx mu(CodeCache_lock, Mutex::_no_safepoint_check_flag);
          add_heap(heap);
          CodeCache::add_heap(heap);
        }
      } else {
        os::dll_unload((*lib)->dl_handle());
      }
    }
  }
  if (heaps_count() == 0) {
    if (FLAG_IS_DEFAULT(UseAOT)) {
      FLAG_SET_DEFAULT(UseAOT, false);
    }
  }
}
```

**标准条件下**：`UseAOT` 默认为 false（JDK 11 中 AOT 是实验性功能），所以第一个 `if` 不进入。进入 `heaps_count() == 0` 分支，由于 `UseAOT` 是默认值（`FLAG_IS_DEFAULT` 为 true），将其显式设为 false。

**如果 `UseAOT = true` 的完整逻辑：**

1. **验证压缩指针参数一致性**：AOT 编译的库在编译时记录了 `narrowOopShift` 和 `narrowKlassShift`，运行时必须一致，否则 AOT 代码中硬编码的指针操作会出错
2. **为每个有效的 AOT 库创建 `AOTCodeHeap`**：这是一种特殊的 CodeHeap，存储预编译的机器码。需要持有 `CodeCache_lock` 来修改 CodeCache 的堆列表
3. **卸载无效库**：AOT 库如果配置不兼容（比如 GC 类型不匹配），标记为 invalid，在这里卸载

---

### 2.10 JVMFlagConstraintList::check_constraints(AfterMemoryInit) (L798-800)

```cpp
// universe.cpp:798-800
  if (!JVMFlagConstraintList::check_constraints(JVMFlagConstraint::AfterMemoryInit)) {
    return JNI_EINVAL;
  }
```

**源码位置**：`src/hotspot/share/runtime/flags/jvmFlagConstraintList.cpp:356-367`

```cpp
bool JVMFlagConstraintList::check_constraints(JVMFlagConstraint::ConstraintType type) {
  guarantee(type > _validating_type, "Constraint check is out of order.");
  _validating_type = type;

  bool status = true;
  for (int i=0; i<length(); i++) {
    JVMFlagConstraint* constraint = at(i);
    if (type != constraint->type()) continue;
    if (constraint->apply(true) != JVMFlag::SUCCESS) status = false;
  }
  return status;
}
```

**解决什么问题？**

JVM 参数之间存在复杂的约束关系，有些约束只有在堆初始化之后才能检查。例如：
- `MaxHeapSize` 必须 ≥ `MinHeapSize`
- `HeapRegionSize` 必须满足特定的范围
- 某些 GC 参数与堆大小有关联

约束检查分多个阶段：
- `AtParse`：参数解析时就检查
- `AfterErgo`：人体工程学调整后检查
- `AfterMemoryInit`：**堆初始化后检查** ← 当前阶段
- `AfterParsing`：所有初始化完成后检查

`guarantee(type > _validating_type, ...)` 确保检查阶段严格递增，不会重复或乱序。

遍历所有已注册的约束，只处理当前阶段的约束。如果任何约束失败，返回 false，`universe_init()` 返回 `JNI_EINVAL`，JVM 启动失败。

---

### 2.11 ClassLoaderData::init_null_class_loader_data() (L812)

```cpp
// universe.cpp:812
  ClassLoaderData::init_null_class_loader_data();
```

**源码位置**：`src/hotspot/share/classfile/classLoaderData.cpp:140-159`

```cpp
void ClassLoaderData::init_null_class_loader_data() {
  assert(_the_null_class_loader_data == NULL, "cannot initialize twice");
  assert(ClassLoaderDataGraph::_head == NULL, "cannot initialize twice");

  _the_null_class_loader_data = new ClassLoaderData(Handle(), false);
  ClassLoaderDataGraph::_head = _the_null_class_loader_data;
  assert(_the_null_class_loader_data->is_the_null_class_loader_data(), "Must be");

  LogTarget(Debug, class, loader, data) lt;
  if (lt.is_enabled()) {
    ResourceMark rm;
    LogStream ls(lt);
    ls.print("create ");
    _the_null_class_loader_data->print_value_on(&ls);
    ls.cr();
  }
}
```

#### ClassLoaderData 构造函数完整源码（classLoaderData.cpp:206-258）

```cpp
ClassLoaderData::ClassLoaderData(Handle h_class_loader, bool is_anonymous) : // L206
  _is_anonymous(is_anonymous),                                               // L207
  _keep_alive((is_anonymous || h_class_loader.is_null()) ? 1 : 0),          // L211
  _metaspace(NULL), _unloading(false), _klasses(NULL),                       // L212
  _modules(NULL), _packages(NULL), _unnamed_module(NULL), _dictionary(NULL), // L213
  _claimed(0), _modified_oops(true), _accumulated_modified_oops(false),      // L214
  _jmethod_ids(NULL), _handles(), _deallocate_list(NULL),                    // L215
  _next(NULL),                                                               // L216
  _class_loader_klass(NULL),                                                 // L217
  _name(NULL),                                                               // L218
  _name_and_id(NULL),                                                        // L219
  _metaspace_lock(new Mutex(Monitor::leaf+1, "Metaspace allocation lock",    // L221
                            true, Monitor::_safepoint_check_never)) {
                                                                             // L223
  if (!h_class_loader.is_null()) {                                           // L225
    _class_loader = _handles.add(h_class_loader());                          // L226
    _class_loader_klass = h_class_loader->klass();                           // L227
  }                                                                          // L228

  if (!is_anonymous) {                                                       // L230
    initialize_holder(h_class_loader);                                       // L233

    _packages = new PackageEntryTable(PackageEntryTable::_packagetable_entry_size);// L238
    if (h_class_loader.is_null()) {                                          // L239
      _unnamed_module = ModuleEntry::create_boot_unnamed_module(this);       // L241
    } else {                                                                 // L242
      _unnamed_module = ModuleEntry::create_unnamed_module(this);            // L244
    }                                                                        // L245
    _dictionary = create_dictionary();                                       // L250
  }                                                                          // L251

  NOT_PRODUCT(_dependency_count = 0);                                        // L255
  JFR_ONLY(INIT_ID(this);)                                                   // L257
}                                                                            // L258
```

| 行号 | 源码 | 标准条件下的行为（Bootstrap ClassLoader, `Handle()=null`, `is_anonymous=false`） |
|------|------|-----------------|
| L207 | `_is_anonymous(is_anonymous)` | `false` — 不是匿名类加载器 |
| L211 | `_keep_alive((is_anonymous \|\| h_class_loader.is_null()) ? 1 : 0)` | `h_class_loader.is_null()=true` → **`_keep_alive = 1`**（永不被 GC 卸载） |
| L212 | `_metaspace(NULL), _unloading(false), _klasses(NULL)` | 元空间懒初始化；未卸载；尚无已加载类 |
| L213 | `_modules(NULL), _packages(NULL), _unnamed_module(NULL), _dictionary(NULL)` | 后续在构造函数体中初始化 |
| L214 | `_claimed(0), _modified_oops(true), _accumulated_modified_oops(false)` | GC 标记初始状态 |
| L221 | `_metaspace_lock(new Mutex(..., _safepoint_check_never))` | 创建 Metaspace 分配锁，不需要 safepoint 检查 |
| L225-228 | `if (!h_class_loader.is_null())` | `h_class_loader` 为 null → **跳过**，Bootstrap 没有 Java ClassLoader 对象 |
| L230 | `if (!is_anonymous)` | `false` → **进入**，Bootstrap 不是匿名类加载器 |
| L233 | `initialize_holder(h_class_loader)` | 为 null loader 创建 WeakHandle，控制 CLD 的 GC 可达性 |
| L238 | `_packages = new PackageEntryTable(109)` | 创建包入口表，质数 109 作为哈希表大小 |
| L239-241 | `if (h_class_loader.is_null())` → `create_boot_unnamed_module(this)` | **走这里**：为 Bootstrap 创建未命名模块 |
| L250 | `_dictionary = create_dictionary()` | 创建类字典（Dictionary），存储已解析的 InstanceKlass |
| L255 | `NOT_PRODUCT(_dependency_count = 0)` | 调试构建：初始化依赖计数 |
| L257 | `JFR_ONLY(INIT_ID(this))` | JFR：初始化跟踪 ID |

**解决什么问题？**

Bootstrap ClassLoader（启动类加载器）是 JVM 中最特殊的类加载器：
- 它用 C++ 实现，没有对应的 Java 对象
- 在 Java 代码中，`ClassLoader.getClassLoader()` 返回 `null` 表示 Bootstrap ClassLoader
- 它负责加载 JDK 核心类（`java.lang.*`、`java.util.*` 等）

但 JVM 内部需要一个 `ClassLoaderData` 来管理 Bootstrap ClassLoader 加载的所有类的元数据。`_the_null_class_loader_data` 就是为这个"null 类加载器"创建的 `ClassLoaderData` 对象。

**逐行解释：**

| 行号 | 代码 | 说明 |
|------|------|------|
| L141 | `assert(_the_null_class_loader_data == NULL, ...)` | 确保只初始化一次 |
| L142 | `assert(ClassLoaderDataGraph::_head == NULL, ...)` | 确保全局链表为空 |
| L146 | `new ClassLoaderData(Handle(), false)` | `Handle()` = null handle（表示没有 Java ClassLoader），`false` = 非匿名类加载器 |
| L148 | `ClassLoaderDataGraph::_head = ...` | 设为全局链表的头节点。后续所有 ClassLoaderData 都会插入到这个链表中 |
| L149 | `assert(...is_the_null_class_loader_data(), ...)` | 验证确实是 null class loader data |
| L151-158 | 日志输出 | Debug 级别日志 |

**JVM 参数**：`-Xlog:class+loader+data=debug`

**输出示例**：
```
[0.020s][debug][class,loader,data] create loader data 0x7ffff0c8e040 for null class loader
```

**`ClassLoaderDataGraph` 链表结构**：

```
ClassLoaderDataGraph::_head
         │
         ▼
┌─────────────────────┐    ┌─────────────────────┐    ┌─────────────────────┐
│ ClassLoaderData      │───▶│ ClassLoaderData      │───▶│ ClassLoaderData      │
│ (Bootstrap/null)     │    │ (ExtClassLoader)     │    │ (AppClassLoader)     │
│ _class_loader=NULL   │    │ _class_loader=oop    │    │ _class_loader=oop    │
│ _klasses → ...       │    │ _klasses → ...       │    │ _klasses → ...       │
└─────────────────────┘    └─────────────────────┘    └─────────────────────┘
      ↑ 此时创建                    后续创建                    后续创建
```

---

### 2.12 创建 6 个 LatestMethodCache (L832-837)

```cpp
// universe.cpp:832-837
  Universe::_finalizer_register_cache = new LatestMethodCache();
  Universe::_loader_addClass_cache    = new LatestMethodCache();
  Universe::_pd_implies_cache         = new LatestMethodCache();
  Universe::_throw_illegal_access_error_cache = new LatestMethodCache();
  Universe::_throw_no_such_method_error_cache = new LatestMethodCache();
  Universe::_do_stack_walk_cache = new LatestMethodCache();
```

**LatestMethodCache 定义**（`universe.hpp:48-68`）：

```cpp
class LatestMethodCache : public CHeapObj<mtClass> {
 private:
  Klass*  _klass;
  int     _method_idnum;
 public:
  LatestMethodCache()   { _klass = NULL; _method_idnum = -1; }
  ~LatestMethodCache()  { _klass = NULL; _method_idnum = -1; }
  void   init(Klass* k, Method* m);
  Klass* klass() const           { return _klass; }
  int    method_idnum() const    { return _method_idnum; }
  Method* get_method();
  void serialize(SerializeClosure* f) { f->do_ptr((void**)&_klass); }
};
```

**构造函数只做一件事**：`_klass = NULL`, `_method_idnum = -1`，创建一个"空壳"对象。真正的初始化在后续 `universe_post_init()` 中调用 `Universe::initialize_known_methods()` 完成。

**为什么不直接缓存 `Method*`？** 因为类可以被重定义（JVMTI RedefineClasses），重定义后 `Method*` 指针会失效。通过存储 `_klass` + `_method_idnum`，可以在 `get_method()` 时动态获取最新的 Method*，兼容热替换。

| 缓存名 | 对应 Java 方法 | 用途 | 调用场景 |
|--------|---------------|------|----------|
| `_finalizer_register_cache` | `Finalizer.register(Object)` | 注册有 finalizer 的对象 | 对象分配后，如果类重写了 `finalize()` |
| `_loader_addClass_cache` | `ClassLoader.addClass(Class)` | 记录已加载的类 | 每次类加载完成后 |
| `_pd_implies_cache` | `ProtectionDomain.impliesCreateAccessControlContext()` | 安全检查 | 权限检查时 |
| `_throw_illegal_access_error_cache` | 抛出 `IllegalAccessError` | 非法访问异常 | 方法解析失败时 |
| `_throw_no_such_method_error_cache` | 抛出 `NoSuchMethodError` | 方法不存在异常 | 方法查找失败时 |
| `_do_stack_walk_cache` | `AbstractStackWalker.doStackWalk(...)` | 栈遍历回调 | `StackWalker` API 调用时 |

**内存布局**：
```
LatestMethodCache (分配在 C 堆, mtClass 标签)
sizeof = 16 bytes (不含 malloc 头)
┌───────────────────────────────┐
│ _klass = NULL       (8 bytes) │  offset 0
├───────────────────────────────┤
│ _method_idnum = -1  (4 bytes) │  offset 8
│ [padding]           (4 bytes) │  offset 12
└───────────────────────────────┘
```

---

### 2.13 CDS 分支：SymbolTable / StringTable / MetaspaceShared (L839-860)

```cpp
// universe.cpp:839-860
#if INCLUDE_CDS
  if (UseSharedSpaces) {
    MetaspaceShared::initialize_shared_spaces();
    StringTable::create_table();
  } else
#endif
  {
    SymbolTable::create_table();
    StringTable::create_table();

#if INCLUDE_CDS
    if (DumpSharedSpaces) {
      MetaspaceShared::prepare_for_dumping();
    }
#endif
  }
```

这段代码有三个分支：

#### 分支 A：`UseSharedSpaces = true`（使用 CDS 共享归档）

**MetaspaceShared::initialize_shared_spaces()**（metaspaceShared.cpp:2106-2162）：

从共享归档文件（`lib/server/classes.jsa`）中读取预处理的数据结构：

```cpp
void MetaspaceShared::initialize_shared_spaces() {
  FileMapInfo *mapinfo = FileMapInfo::current_info();
  _cds_i2i_entry_code_buffers = mapinfo->cds_i2i_entry_code_buffers();        // CDS 解释器适配器代码
  _cds_i2i_entry_code_buffers_size = mapinfo->cds_i2i_entry_code_buffers_size();
  _core_spaces_size = mapinfo->core_spaces_size();
  char* buffer = mapinfo->misc_data_patching_start();
  clone_cpp_vtables((intptr_t*)buffer);                                        // 恢复 C++ 虚表指针

  buffer = mapinfo->read_only_tables_start();
  int sharedDictionaryLen = *(intptr_t*)buffer;                                // 读取共享字典长度
  buffer += sizeof(intptr_t);
  int number_of_entries = *(intptr_t*)buffer;
  buffer += sizeof(intptr_t);
  SystemDictionary::set_shared_dictionary((HashtableBucket<mtClass>*)buffer,   // 设置共享字典
                                          sharedDictionaryLen,
                                          number_of_entries);
  buffer += sharedDictionaryLen;

  int len = *(intptr_t*)buffer;                                                // 跳过字典条目
  buffer += sizeof(intptr_t);
  buffer += len;

  buffer = HeapShared::read_archived_subgraph_infos(buffer);                   // 读取归档堆子图

  intptr_t* array = (intptr_t*)buffer;
  ReadClosure rc(&array);
  serialize(&rc);                                                              // 反序列化符号表等

  SymbolTable::create_table();                                                 // 创建符号表（从归档恢复）
  mapinfo->patch_archived_heap_embedded_pointers();                            // 修补归档堆中的嵌入指针
  mapinfo->close();                                                            // 关闭映射文件

  if (PrintSharedArchiveAndExit) {                                             // 特殊调试模式
    if (PrintSharedDictionary) {
      tty->print_cr("\nShared classes:\n");
      SystemDictionary::print_shared(tty);
    }
    if (_archive_loading_failed) {
      tty->print_cr("archive is invalid");
      vm_exit(1);
    } else {
      tty->print_cr("archive is valid");
      vm_exit(0);
    }
  }
}
```

然后创建 StringTable（CDS 分支中 SymbolTable 已在 `serialize()` 中恢复，只需创建 StringTable）。

#### 分支 B：非 CDS 模式（标准条件走这里）

**SymbolTable::create_table()**（symbolTable.hpp:222-237）：

```cpp
static void create_table() {
  assert(_the_table == NULL, "One symbol table allowed.");
  _the_table = new SymbolTable();
  initialize_symbols(symbol_alloc_arena_size);
}
```

1. `new SymbolTable()`：创建哈希表，内部调用基类 `Hashtable` 构造函数：
   - 分配 20011 个 `HashtableBucket`，每个 8 字节
   - 总大小 = 20011 × 8 = 160,088 字节 ≈ **156KB**
   - 所有 bucket 初始化为 NULL

2. `initialize_symbols(symbol_alloc_arena_size)`：创建一个 `Arena`，大小 = **360KB** (`symbol_alloc_arena_size = 360*1024`)。Arena 用于分配 Symbol 对象，避免频繁的 malloc/free。

**StringTable::create_table()**（stringTable.hpp:107-110）：

```cpp
static void create_table() {
  assert(_the_table == NULL, "One string table allowed.");
  _the_table = new StringTable();
}
```

创建一个新的 `StringTable` 对象。注意 JDK 11 的 StringTable 使用了 ConcurrentHashTable（与 SymbolTable 不同的实现），支持并发读写和无锁查找。初始 bucket 数由 `-XX:StringTableSize=60013` 控制。

#### 分支 C：`DumpSharedSpaces = true`（生成 CDS 归档）

**MetaspaceShared::prepare_for_dumping()**（metaspaceShared.cpp:1631-1634）：

```cpp
void MetaspaceShared::prepare_for_dumping() {
  Arguments::check_unsupported_dumping_properties();
  ClassLoader::initialize_shared_path();
}
```

检查不兼容的属性设置，初始化共享路径。只在 `java -Xshare:dump` 时执行。

---

### 2.14 Universe::initialize_verify_flags() (L861-863)

```cpp
// universe.cpp:861-863
  if (strlen(VerifySubSet) > 0) {
    Universe::initialize_verify_flags();
  }
```

**源码位置**：`src/hotspot/share/memory/universe.cpp:1361-1398`

```cpp
void Universe::initialize_verify_flags() {
  verify_flags = 0;
  const char delimiter[] = " ,";

  size_t length = strlen(VerifySubSet);
  char* subset_list = NEW_C_HEAP_ARRAY(char, length + 1, mtInternal);
  strncpy(subset_list, VerifySubSet, length + 1);
  char* save_ptr;

  char* token = strtok_r(subset_list, delimiter, &save_ptr);
  while (token != NULL) {
    if (strcmp(token, "threads") == 0) {
      verify_flags |= Verify_Threads;
    } else if (strcmp(token, "heap") == 0) {
      verify_flags |= Verify_Heap;
    } else if (strcmp(token, "symbol_table") == 0) {
      verify_flags |= Verify_SymbolTable;
    } else if (strcmp(token, "string_table") == 0) {
      verify_flags |= Verify_StringTable;
    } else if (strcmp(token, "codecache") == 0) {
      verify_flags |= Verify_CodeCache;
    } else if (strcmp(token, "dictionary") == 0) {
      verify_flags |= Verify_SystemDictionary;
    } else if (strcmp(token, "classloader_data_graph") == 0) {
      verify_flags |= Verify_ClassLoaderDataGraph;
    } else if (strcmp(token, "metaspace") == 0) {
      verify_flags |= Verify_MetaspaceUtils;
    } else if (strcmp(token, "jni_handles") == 0) {
      verify_flags |= Verify_JNIHandles;
    } else if (strcmp(token, "codecache_oops") == 0) {
      verify_flags |= Verify_CodeCacheOops;
    } else {
      vm_exit_during_initialization(err_msg("VerifySubSet: \'%s\' memory sub-system is unknown, please correct it", token));
    }
    token = strtok_r(NULL, delimiter, &save_ptr);
  }
  FREE_C_HEAP_ARRAY(char, subset_list);
}
```

**标准条件下**：`VerifySubSet` 默认为空字符串 `""`，`strlen("") = 0`，条件不成立，**不会执行** `initialize_verify_flags()`。

**如果使用的话**：`-XX:VerifySubSet=heap,threads` 可以在 `-XX:+VerifyBeforeGC` / `-XX:+VerifyAfterGC` 时只验证指定的子系统，而不是全部验证（全部验证非常慢）。

**支持的子系统名称（10个）**：

| 名称 | 位掩码 | 验证内容 |
|------|--------|----------|
| `threads` | `Verify_Threads` | 所有线程栈和局部变量 |
| `heap` | `Verify_Heap` | 整个 Java 堆 |
| `symbol_table` | `Verify_SymbolTable` | 符号表完整性 |
| `string_table` | `Verify_StringTable` | 字符串常量池完整性 |
| `codecache` | `Verify_CodeCache` | 代码缓存完整性 |
| `dictionary` | `Verify_SystemDictionary` | 系统字典完整性 |
| `classloader_data_graph` | `Verify_ClassLoaderDataGraph` | ClassLoaderData 链表 |
| `metaspace` | `Verify_MetaspaceUtils` | 元空间完整性 |
| `jni_handles` | `Verify_JNIHandles` | JNI 引用完整性 |
| `codecache_oops` | `Verify_CodeCacheOops` | 代码缓存中的 oop 引用 |

如果传入未知的子系统名称，JVM 直接退出并报错。解析完成后释放临时分配的字符串缓冲区。

---

### 2.15 ResolvedMethodTable::create_table() (L871)

```cpp
// universe.cpp:871
  ResolvedMethodTable::create_table();
```

**源码位置**：`src/hotspot/share/prims/resolvedMethodTable.hpp:84-87`

```cpp
static void create_table() {
  assert(_the_table == NULL, "One symbol table allowed.");
  _the_table = new ResolvedMethodTable();
}
```

创建 `ResolvedMethodTable` 哈希表，用于存储已解析的方法引用（`ResolvedMethodName` 对象）。

**解决什么问题？**

1. **MethodHandle/反射支持**：`java.lang.invoke.MethodHandle` 和反射调用需要将符号引用解析为直接方法引用（`Method*`）。解析结果缓存在 `ResolvedMethodTable` 中，避免重复解析。

2. **类重定义支持（JVMTI）**：当 `RedefineClasses` 热替换类时，旧 `Method*` 失效。JVM 需要遍历所有 `ResolvedMethodName`，将它们更新为新的 `Method*`。`ResolvedMethodTable` 提供了这个遍历能力。

3. **弱引用管理**：`ResolvedMethodName` 是 Java 对象，可以被 GC 回收。表中使用弱引用跟踪它们，GC 时清除已回收的条目。

4. **去重**：同一个 `Method*` 只需要一个 `ResolvedMethodName` 对象，避免重复创建。

---

### 2.16 返回 JNI_OK (L873)

```cpp
// universe.cpp:873
  return JNI_OK;
```

所有初始化成功，返回 `JNI_OK (= 0)`，表示 `universe_init()` 执行完毕。

---

## 三、GDB 验证数据

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          universe_init() 创建的核心数据                          │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  1. G1CollectedHeap                                                             │
│     地址: 0x7ffff0032660                                                        │
│     堆起始: 0x600000000 (≈ 24GB 位置)                                           │
│     堆大小: 8192 MB = 1,073,741,824 words                                      │
│     Region 数量: 2048                                                           │
│                                                                                 │
│  2. 压缩对象指针 (NarrowOop) - ZeroBased 模式                                  │
│     _narrow_oop._base = NULL (0)                                                │
│     _narrow_oop._shift = 3                                                      │
│     解码公式: oop = narrow_oop << 3                                             │
│                                                                                 │
│  3. 压缩类指针 (NarrowKlass)                                                    │
│     _narrow_klass._base = 0x800000000 (32GB)                                    │
│     _narrow_klass._shift = 0                                                    │
│     解码公式: klass = 0x800000000 + narrow_klass                                │
│                                                                                 │
│  4. SymbolTable                                                                 │
│     bucket 数: 20011                                                            │
│     Arena 大小: 360KB                                                           │
│     初始 entries: 0                                                             │
│                                                                                 │
│  5. LatestMethodCache × 6                                                       │
│     sizeof = 16 bytes (不含 malloc 头)                                          │
│     初始状态: _klass = NULL, _method_idnum = -1                                 │
│                                                                                 │
│  6. HeapRegion 配置                                                             │
│     GrainBytes = 4,194,304 (4MB)                                                │
│     CardsPerRegion = 8,192                                                      │
│                                                                                 │
│  7. TLAB 配置                                                                   │
│     max_size = 262,144 words = 2MB                                              │
│                                                                                 │
│  8. Metaspace                                                                   │
│     压缩类空间: 0x800000000 ~ 0x840000000 (1GB)                                │
│     数据元空间: 初始虚拟空间 8MB                                                │
│     first_chunk_word_size: 524288 words = 4MB                                   │
│     first_class_chunk_word_size: 24576 words = 192KB                            │
│     GC 阈值: MaxMetaspaceSize (近乎无限)                                        │
│                                                                                 │
│  9. PerfData 计数器 (共 8 个)                                                   │
│     sun.gc.metaspace: minCapacity/capacity/maxCapacity/used                     │
│     sun.gc.compressedclassspace: minCapacity/capacity/maxCapacity/used           │
│                                                                                 │
│ 10. ClassLoaderData (Bootstrap)                                                 │
│     地址: _the_null_class_loader_data                                           │
│     _class_loader = NULL (表示 Bootstrap ClassLoader)                           │
│     ClassLoaderDataGraph::_head 指向此对象                                      │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 四、相关 JVM 参数汇总

| 参数 | 作用 | 默认值/在本函数中的影响 |
|------|------|------------------------|
| `-Xlog:startuptime` | 查看 Genesis 耗时 | 输出 `Genesis: Xms` |
| `-Xlog:gc` | 查看 GC 类型 | 输出 `Using G1` |
| `-Xlog:gc+heap+coops=info` | 查看压缩指针模式 | 输出 `Compressed Oops mode: Zero based` |
| `-Xlog:class+loader+data=debug` | ClassLoaderData 创建日志 | 输出 `create loader data ...` |
| `-XX:SymbolTableSize=N` | 符号表 bucket 数 | 20011 |
| `-XX:StringTableSize=N` | 字符串表 bucket 数 | 60013 |
| `-XX:+/-UsePerfData` | 是否创建性能计数器 | true |
| `-XX:+/-UseCompressedOops` | 压缩对象指针 | true (64位) |
| `-XX:+/-UseCompressedClassPointers` | 压缩类指针 | true (64位) |
| `-XX:+/-UseTLAB` | 使用线程本地分配缓冲区 | true |
| `-XX:+/-UseAOT` | AOT 编译 | false (JDK 11 默认) |
| `-XX:+/-UseSharedSpaces` | CDS 共享空间 | true (但可能失败后关闭) |
| `-XX:+/-DumpSharedSpaces` | 生成 CDS 归档 | false |
| `-XX:VerifySubSet=X` | 只验证指定子系统 | "" (空) |
| `-XX:CompressedClassSpaceSize=N` | 压缩类空间大小 | 1GB |
| `-XX:InitialBootClassLoaderMetaspaceSize=N` | 首个元空间 Chunk | 4MB |

---

## 五、三阶段初始化对比

| 维度 | universe_init() | universe2_init() | universe_post_init() |
|------|----------------|-------------------|---------------------|
| **调用位置** | init_globals() 第 3 个 | init_globals() 第 7 个 | init_globals() 最后 |
| **主要职责** | 基础设施创建 | 基本类型 Klass 创建 | 异常对象创建 + 方法缓存填充 |
| **创建的核心对象** | G1堆、Metaspace、SymbolTable、StringTable | boolean[]、int[]、Object[] 等 TypeArrayKlass | OOM、StackOverflow、NPE 异常实例 |
| **是否需要类加载** | 否 | 否（内部创建） | 是（需要解析 Java 类） |
| **是否需要解释器** | 否 | 否 | 是 |
| **状态变化** | 无 | 无 | `_fully_initialized = true` |

---

## 六、总结

`universe_init()` 完成了 JVM "创世纪"的工作，按顺序创建了以下核心组件：

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                       universe_init() 创建的完整组件清单                         │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  【内存子系统】                                                                 │
│  ├─ G1CollectedHeap (8GB, 2048 Regions × 4MB)                                  │
│  ├─ Metaspace (数据元空间 8MB + 压缩类空间 1GB)                                │
│  ├─ TLAB 配置 (max_size = 2MB)                                                 │
│  └─ 压缩指针 (oop: ZeroBased shift=3, klass: base=32GB shift=0)               │
│                                                                                 │
│  【表/缓存结构】                                                                │
│  ├─ SymbolTable (20011 buckets + 360KB Arena)                                   │
│  ├─ StringTable (ConcurrentHashTable)                                           │
│  ├─ ResolvedMethodTable (方法解析缓存)                                          │
│  └─ LatestMethodCache × 6 (空壳，后续填充)                                     │
│                                                                                 │
│  【管理结构】                                                                   │
│  ├─ OopStorage "VM Weak Oop Handles" (VM 弱引用容器)                            │
│  ├─ ClassLoaderData (Bootstrap ClassLoader)                                     │
│  ├─ MetaspaceTracer (JFR 追踪器)                                                │
│  └─ PerfData 计数器 × 8 (Metaspace + CompressedClassSpace)                     │
│                                                                                 │
│  【验证/配置】                                                                  │
│  ├─ JVMFlag 约束检查 (AfterMemoryInit)                                         │
│  ├─ AOT 验证与堆创建 (标准条件下跳过)                                           │
│  └─ VerifySubSet 标志解析 (标准条件下跳过)                                      │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

这些组件为后续的类加载、对象分配、GC 运行奠定了基础。在 `universe_init()` 之后，JVM 就有了"宇宙"——一个可以运行 Java 程序的世界。

---

## 七、核心对象内部属性详解

> 前面的逐行分析侧重"做了什么"，这一节补充每个初始化对象的**完整字段列表、内存布局、继承关系**，确保对每个对象都有结构级别的理解。

### 7.1 G1CollectedHeap

**继承链**：`G1CollectedHeap → CollectedHeap → CHeapObj<mtInternal>`

`G1CollectedHeap` 是整个 Java 堆的管理对象，在 `create_heap()` 中通过 `new G1CollectedHeap()` 在 C 堆上创建，然后通过 `initialize()` 分配真正的 8GB 堆内存。

**核心字段**（只列出在 `universe_init` 阶段赋值的关键字段）：

| 字段 | 类型 | 作用 | 初始值（标准条件） |
|------|------|------|-------------------|
| `_reserved` | `MemRegion` | 堆的保留地址范围 | `[0x600000000, 0x800000000)` |
| `_hrm` | `HeapRegionManager` | 管理 2048 个 HeapRegion | 含 `_regions` 数组 |
| `_card_table` | `G1CardTable*` | 卡表，512B 一个 card | 覆盖整个堆 |
| `_rem_set` | `G1RemSet*` | 记忆集，跨 Region 引用追踪 | — |
| `_cm` | `G1ConcurrentMark*` | 并发标记管理器 | — |
| `_bot` | `G1BlockOffsetTable` | 块偏移表，加速 card → object 查找 | — |
| `_g1_policy` | `G1Policy*` | GC 策略决策器 | — |
| `_allocator` | `G1Allocator*` | 内存分配器（Eden/Survivor） | — |
| `_num_humongous_objects` | `uint` | 巨型对象数量 | 0 |
| `_max_heap_capacity` | `size_t` | 堆最大容量 | 8GB |

**G1CollectedHeap 与子组件关系**：

```
G1CollectedHeap
├─ _hrm (HeapRegionManager)
│   └─ _regions[0..2047] (HeapRegion*)
│       ├─ HeapRegion._bottom / _top / _end
│       ├─ HeapRegion._type (Eden/Survivor/Old/Humongous/Free)
│       └─ HeapRegion._rem_set (HeapRegionRemSet)
├─ _card_table (G1CardTable)
│   └─ _byte_map[0..16M] (每个 byte 对应 512B 堆空间)
├─ _rem_set (G1RemSet)
├─ _cm (G1ConcurrentMark)
├─ _bot (G1BlockOffsetTable)
├─ _g1_policy (G1Policy)
│   └─ _analytics (G1Analytics) → 预测 GC 耗时
└─ _allocator (G1Allocator)
    ├─ _mutator_alloc_region (Eden 分配)
    └─ _survivor_gc_alloc_region (Survivor 分配)
```

> 注：`G1CollectedHeap::initialize()` 的详细分析见 `jvm-md/G1-GC/G1CollectedHeap_initialize_analysis.md`，此处只列出与 `universe_init` 相关的字段。

---

### 7.2 NarrowPtrStruct（压缩指针配置）

**定义位置**：`universe.hpp`，Universe 中有两个静态实例：

```cpp
struct NarrowPtrStruct {
  address _base;                      // 基地址 (8 bytes)
  int     _shift;                     // 移位量 0 或 3 (4 bytes)
  bool    _use_implicit_null_checks;  // 隐式空检查 (1 byte)
  // [padding 3 bytes]
};
// sizeof = 16 bytes

static NarrowPtrStruct _narrow_oop;    // 压缩对象指针
static NarrowPtrStruct _narrow_klass;  // 压缩类指针
```

| 实例 | `_base` | `_shift` | `_use_implicit_null_checks` | 设置位置 |
|------|---------|----------|---------------------------|---------|
| `_narrow_oop` | `0`（NULL） | `3` | `true` | `initialize_heap()` L968-974 |
| `_narrow_klass` | `0x800000000` | `0` | `true` | `allocate_metaspace_compressed_klass_ptrs()` |

**关系**：`_narrow_oop` 影响所有对象引用的编解码；`_narrow_klass` 影响对象头中 Klass 指针的编解码。两者独立配置，但都在 `universe_init` 中确定。

---

### 7.3 OopStorage "VM Weak Oop Handles"

**继承链**：`OopStorage → CHeapObj<mtGC>`

**定义位置**：`gc/shared/oopStorage.hpp`

**完整字段列表**：

| 字段 | 类型 | 作用 |
|------|------|------|
| `_name` | `const char*` | 名称 = `"VM Weak Oop Handles"` |
| `_active_array` | `ActiveArray*` | 所有活跃 Block 的数组，GC 遍历用 |
| `_allocation_list` | `AllocationList` | 有空闲 slot 的 Block 双向链表，分配用 |
| `_deferred_updates` | `Block* volatile` | 延迟更新队列（无锁 CAS 链） |
| `_allocation_mutex` | `Mutex*` | `VMWeakAlloc_lock` — 保护分配/释放 |
| `_active_mutex` | `Mutex*` | `VMWeakActive_lock` — 保护 ActiveArray |
| `_allocation_count` | `volatile size_t` | 已分配的 oop slot 数 |
| `_protect_active` | `SingleWriterSynchronizer` | 读写同步器，保护 ActiveArray 替换 |
| `_concurrent_iteration_active` | `mutable bool` | 是否有 GC 正在并发遍历 |

**内存布局**：

```
OopStorage "VM Weak Oop Handles" (C 堆分配)
┌─────────────────────────────────────────────────────────┐
│ _name = "VM Weak Oop Handles"               (8 bytes)  │
│ _active_array → ActiveArray                 (8 bytes)  │
│   └─ 内部: Block*[] 数组                               │
│ _allocation_list                                        │
│   ├─ _head = NULL                           (8 bytes)  │
│   └─ _tail = NULL                           (8 bytes)  │
│ _deferred_updates = NULL                    (8 bytes)  │
│ _allocation_mutex = VMWeakAlloc_lock        (8 bytes)  │
│ _active_mutex = VMWeakActive_lock           (8 bytes)  │
│ _allocation_count = 0                       (8 bytes)  │
│ _protect_active (SingleWriterSynchronizer)             │
│ _concurrent_iteration_active = false        (1 byte)   │
└─────────────────────────────────────────────────────────┘
```

**谁使用它？** 后续 `universe_post_init()` 和运行时会通过 `SystemDictionary::vm_weak_oop_storage()` 获取此对象，存储 VM 内部弱引用（如 ResolvedMethodName、JVMTI 标记等）。GC 通过遍历 `_active_array` 清理已死对象的弱引用。

---

### 7.4 VirtualSpaceList（数据元空间虚拟空间列表）

**继承链**：`VirtualSpaceList → CHeapObj<mtClass>`

**定义位置**：`memory/metaspace/virtualSpaceList.hpp`

**完整字段列表**：

| 字段 | 类型 | 作用 | 初始值 |
|------|------|------|--------|
| `_virtual_space_list` | `VirtualSpaceNode*` | 链表头（第一个虚拟空间节点） | 指向首个 8MB 节点 |
| `_current_virtual_space` | `VirtualSpaceNode*` | 当前正在分配 Chunk 的节点 | 同上 |
| `_is_class` | `bool` | 是否用于压缩类空间 | `false`（数据元空间） |
| `_reserved_words` | `size_t` | 已保留虚拟内存总字数 | 8MB / 8 = 1M words |
| `_committed_words` | `size_t` | 已提交物理内存总字数 | 视需要 |
| `_virtual_space_count` | `size_t` | 虚拟空间节点数 | 1 |
| `_envelope_lo` | `address` | 地址范围下界（快速排除） | 首个节点起始地址 |
| `_envelope_hi` | `address` | 地址范围上界（快速排除） | 首个节点结束地址 |

**作用**：管理数据元空间的虚拟内存分配。初始预留 8MB，存储 Method、ConstantPool、Bytecode 等类元数据（非 Klass 指针）。当空间不足时，会创建新的 VirtualSpaceNode 追加到链表。

---

### 7.5 ChunkManager（数据元空间 Chunk 管理器）

**继承链**：`ChunkManager → CHeapObj<mtInternal>`

**定义位置**：`memory/metaspace/chunkManager.hpp`

**完整字段列表**：

| 字段 | 类型 | 作用 | 初始值 |
|------|------|------|--------|
| `_free_chunks[NumberOfFreeLists]` | `ChunkList` (即 `FreeList<Metachunk>`) | 空闲 Chunk 链表，按大小分类 | 3 个空链表 |
| `_is_class` | `const bool` | 是否为 class chunk manager | `false` |
| `_humongous_dictionary` | `ChunkTreeDictionary` | 巨型 Chunk 的二叉搜索树字典 | 空树 |
| `_free_chunks_total` | `size_t` | 所有空闲 Chunk 的总字数 | 0 |
| `_free_chunks_count` | `size_t` | 空闲 Chunk 总数 | 0 |

**空闲链表分类**（3 级 + 巨型）：

| 级别 | 大小 | 用途 |
|------|------|------|
| Specialized | 128 words (1KB) | 小对象元数据 |
| Small | 512 words (4KB) | 中等元数据 |
| Medium | 4096 words (32KB) | 较大元数据 |
| Humongous | > Medium | 超大元数据（存放在 `_humongous_dictionary` 二叉树中） |

**与 VirtualSpaceList 的关系**：`VirtualSpaceList` 管理虚拟内存，从中切出 `Metachunk`；`ChunkManager` 管理已释放的空闲 Chunk 的回收和复用。类加载器卸载时，其占用的 Chunk 归还到 `ChunkManager`。

---

### 7.6 ClassLoaderData（Bootstrap ClassLoader 的数据容器）

**继承链**：`ClassLoaderData → CHeapObj<mtClass>`

**定义位置**：`classfile/classLoaderData.hpp`

**核心字段列表**（只列出在 `init_null_class_loader_data()` 时相关的）：

| 字段 | 类型 | 作用 | 初始值 |
|------|------|------|--------|
| `_class_loader` | `OopHandle` | 对应的 Java ClassLoader 对象 | **NULL**（Bootstrap 没有 Java 对象） |
| `_holder` | `WeakHandle<vm_class_loader_data>` | 控制生命周期的弱引用 | — |
| `_metaspace` | `ClassLoaderMetaspace* volatile` | 该类加载器的私有元空间 | 懒初始化（首次加载类时创建） |
| `_metaspace_lock` | `Mutex*` | 保护元空间分配 | 新创建的锁 |
| `_unloading` | `bool` | 是否正在卸载 | `false` |
| `_is_anonymous` | `bool` | 是否匿名类加载器 | `false` |
| `_klasses` | `Klass* volatile` | 该类加载器已加载的类链表 | `NULL` |
| `_packages` | `PackageEntryTable* volatile` | 包表 | `NULL`（后续创建） |
| `_modules` | `ModuleEntryTable* volatile` | 模块表 | `NULL`（后续创建） |
| `_unnamed_module` | `ModuleEntry*` | 未命名模块 | — |
| `_dictionary` | `Dictionary*` | 已解析类字典 | `NULL`（后续创建） |
| `_jmethod_ids` | `JNIMethodBlock*` | JNI 方法 ID 块 | `NULL` |
| `_deallocate_list` | `GrowableArray<Metadata*>*` | 待回收元数据列表 | `NULL` |
| `_next` | `ClassLoaderData*` | 链表下一个节点 | `NULL` |
| `_keep_alive` | `s2` | 是否强制保持存活 | 0 |
| `_claimed` | `volatile int` | GC 追踪标志 | 0 |

**与 Metaspace 的关系**：

```
ClassLoaderData (Bootstrap)
│
├─ _class_loader = NULL (Bootstrap 没有 Java 对象)
│
├─ _metaspace → ClassLoaderMetaspace (懒初始化)
│                ├─ _vsm → SpaceManager (数据元空间分配器)
│                │   └─ 从 Metaspace::_space_list (VirtualSpaceList) 中获取 Chunk
│                └─ _class_vsm → SpaceManager (类元空间分配器)
│                    └─ 从压缩类空间中获取 Chunk
│
├─ _klasses → Klass1 → Klass2 → ... (后续加载的类)
│
└─ _next → NULL (此时只有 Bootstrap 一个节点)
```

---

### 7.7 SymbolTable

**继承链**：`SymbolTable → RehashableHashtable<Symbol*, mtSymbol> → Hashtable → BasicHashtable`

**定义位置**：`classfile/symbolTable.hpp`

**关键字段**：

| 字段 | 来源 | 类型 | 作用 | 初始值 |
|------|------|------|------|--------|
| `_the_table` | SymbolTable (static) | `SymbolTable*` | 全局唯一实例 | `new SymbolTable()` |
| `_needs_rehashing` | SymbolTable (static) | `bool` | 是否需要重哈希 | `false` |
| `_lookup_shared_first` | SymbolTable (static) | `bool` | 是否优先查找共享表 | CDS 相关 |
| `_shared_table` | SymbolTable (static) | `CompactHashtable` | CDS 共享符号表 | 空 |
| `_symbols_removed` | SymbolTable (static) | `int` | 已删除符号计数 | 0 |
| `_symbols_counted` | SymbolTable (static) | `int` | 已计数符号数 | 0 |
| `_table_size` | BasicHashtable | `int` | bucket 数量 | **20011** |
| `_buckets` | BasicHashtable | `HashtableBucket*` | bucket 数组 | 20011 × 8B ≈ 156KB |
| `_number_of_entries` | BasicHashtable | `int` | 当前条目数 | 0 |
| `_first_free_entry` / `_end_block` | BasicHashtable | `HashtableEntry*` | 批量分配的条目管理 | — |

**与 Arena 的关系**：

`create_table()` 中调用 `initialize_symbols(360*1024)` 创建了一个 `Arena`：

```
SymbolTable (C 堆)
│
├─ _buckets[0..20010] (C 堆分配, 156KB)
│   每个 bucket → HashtableEntry* → HashtableEntry* → ... (链表)
│                      │
│                      └─ _literal → Symbol* (指向 Arena 中分配的 Symbol)
│
└─ _arena (Arena, 360KB)
    ├─ 分配 Symbol 对象
    └─ Symbol { _length, _identity_hash, _refcount, _body[] }
```

**为什么用 Arena 而不是 malloc？** Symbol 对象非常小（通常 30-50 字节）且生命周期长（几乎不删除）。Arena 批量分配内存，避免每个 Symbol 都 malloc 的开销（malloc 有 ~16 字节头部开销，对小对象浪费严重）。

---

### 7.8 StringTable

**继承链**：`StringTable → CHeapObj<mtSymbol>`

**定义位置**：`classfile/stringTable.hpp`

> 注意：JDK 11 的 StringTable 与 SymbolTable 使用了**不同的哈希表实现**。StringTable 用 `ConcurrentHashTable`（无锁并发），SymbolTable 用传统的 `Hashtable`（链表+锁）。

**完整字段列表**：

| 字段 | 类型 | 作用 | 初始值 |
|------|------|------|--------|
| `_the_table` (static) | `StringTable*` | 全局唯一实例 | `new StringTable()` |
| `_shared_table` (static) | `CompactHashtable<oop, char>` | CDS 共享字符串表 | 空 |
| `_shared_string_mapped` (static) | `bool` | CDS 共享字符串是否已映射 | `false` |
| `_alt_hash` (static) | `bool` | 是否使用替代哈希 | `false` |
| `_local_table` | `StringTableHash*` | 本地并发哈希表 | 新创建 |
| `_current_size` | `size_t` | 当前 bucket 数 | 由 `StringTableSize` 决定（默认 60013） |
| `_has_work` | `volatile bool` | 是否有清理工作待做 | `false` |
| `_needs_rehashing` | `volatile bool` | 是否需要重哈希 | `false` |
| `_weak_handles` | `OopStorage*` | 弱引用存储 | 新创建的 OopStorage |
| `_items` | `volatile size_t` | 当前条目数 | 0 |
| `_uncleaned_items` | `volatile size_t` | 未清理条目数 | 0 |

**为什么 StringTable 用 OopStorage？** 因为 String 是 Java 对象，存在于堆中。StringTable 持有对这些对象的引用。为了让 GC 能正确处理这些引用（标记/移动/回收），需要通过 `OopStorage` 来管理。而 SymbolTable 的 Symbol 是 C++ 对象（分配在 Arena），不受 GC 管理，所以不需要 OopStorage。

---

### 7.9 ResolvedMethodTable

**继承链**：`ResolvedMethodTable → Hashtable<ClassLoaderWeakHandle, mtClass> → BasicHashtable`

**定义位置**：`prims/resolvedMethodTable.hpp`

**完整字段列表**：

| 字段 | 类型 | 作用 | 初始值 |
|------|------|------|--------|
| `_the_table` (static) | `ResolvedMethodTable*` | 全局唯一实例 | `new ResolvedMethodTable()` |
| `_oops_removed` (static) | `int` | GC 后移除的条目数 | 0 |
| `_oops_counted` (static) | `int` | GC 时扫描的条目数 | 0 |
| `_table_size` (继承) | `int` | bucket 数量 | **1007** |
| `_buckets` (继承) | `HashtableBucket*` | bucket 数组 | 1007 × 8B ≈ 8KB |
| `_number_of_entries` (继承) | `int` | 当前条目数 | 0 |

**为什么 bucket 数是 1007？** 远小于 SymbolTable 的 20011。因为 MethodHandle/反射调用远比符号引用少，不需要大表。1007 是质数，减少哈希冲突。

---

### 7.10 ThreadLocalAllocBuffer (TLAB) — 静态初始化

**继承链**：`ThreadLocalAllocBuffer → CHeapObj<mtThread>`

**定义位置**：`gc/shared/threadLocalAllocBuffer.hpp`

TLAB 是每个线程一个的实例对象（嵌入在 `Thread` 中），但 `universe_init()` 只设置了静态配置。

**静态字段**（在 `universe_init` 中设置的）：

| 字段 | 类型 | 作用 | 设置位置 | 初始值 |
|------|------|------|---------|--------|
| `_max_size` | `static size_t` | 所有 TLAB 的最大尺寸上限 | `set_max_size()` | **262144 words = 2MB** |
| `_target_refills` | `static unsigned` | 每 GC 周期期望的 TLAB 重填次数 | `startup_initialization()` | **50** |
| `_reserve_for_allocation_prefetch` | `static int` | C2 编译器预取保留空间 | `startup_initialization()` | 与 CPU 缓存行相关 |
| `_global_stats` | `static GlobalTLABStats*` | 全局 TLAB 统计收集器 | `startup_initialization()` | `new GlobalTLABStats()` |

**实例字段**（每个线程一份，此时尚未创建）：

| 字段 | 类型 | 作用 |
|------|------|------|
| `_start` | `HeapWord*` | TLAB 起始地址 |
| `_top` | `HeapWord*` | 下一个分配位置 |
| `_end` | `HeapWord*` | 分配结束位置（可能是采样点） |
| `_allocation_end` | `HeapWord*` | 真实 TLAB 结束地址 |
| `_desired_size` | `size_t` | 期望大小（动态调整） |
| `_refill_waste_limit` | `size_t` | 浪费上限（超过此值就重填） |
| `_number_of_refills` | `unsigned` | 重填次数 |
| `_fast_refill_waste` | `unsigned` | 快速路径浪费 |
| `_slow_refill_waste` | `unsigned` | 慢速路径浪费 |
| `_gc_waste` | `unsigned` | GC 时 TLAB 剩余浪费 |
| `_slow_allocations` | `unsigned` | 慢分配次数 |
| `_allocation_fraction` | `AdaptiveWeightedAverage` | Eden 中 TLAB 分配的比例 |

**`startup_initialization()` 完整源码见 Section 2.4.3**（threadLocalAllocBuffer.cpp:254-333），此处不重复。

**设计要点**：`_target_refills = 50` 意味着每个 GC 周期，每个线程期望重填 TLAB 50 次。TLAB 初始大小 = Eden / (线程数 × 50)。这个值会在运行时根据实际分配速率动态调整。

---

### 7.11 MetaspacePerfCounters

**继承链**：`MetaspacePerfCounters → CHeapObj<mtInternal>`

**定义位置**：`memory/metaspaceCounters.cpp`（注意是 .cpp 内部类，不在头文件中）

**完整字段列表**：

| 字段 | 类型 | 作用 |
|------|------|------|
| `_capacity` | `PerfVariable*` | 已提交容量计数器 |
| `_used` | `PerfVariable*` | 已使用量计数器 |
| `_max_capacity` | `PerfVariable*` | 最大容量计数器 |

这 3 个 `PerfVariable*` 指向 PerfData 共享内存区域中的变量。加上构造函数中创建的 1 个 `PerfConstant`（minCapacity），每个 `MetaspacePerfCounters` 实例关联 4 个 PerfData 条目。

universe_init 中创建了 2 个 MetaspacePerfCounters：
- `MetaspaceCounters::_perf_counters`（命名空间 `metaspace`）
- `CompressedClassSpaceCounters::_perf_counters`（命名空间 `compressedclassspace`）

---

## 八、对象关系全景图

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                    universe_init() 创建的所有对象及其关系                          │
└──────────────────────────────────────────────────────────────────────────────────┘

Universe (静态类，全局唯一)
│
├── _collectedHeap ──→ G1CollectedHeap
│                       ├── _hrm (HeapRegionManager)
│                       │    └── HeapRegion[0..2047] (每个 4MB)
│                       ├── _card_table (G1CardTable)
│                       ├── _rem_set (G1RemSet)
│                       ├── _cm (G1ConcurrentMark)
│                       └── _allocator (G1Allocator)
│
├── _narrow_oop ──→ NarrowPtrStruct { base=0, shift=3 }
│                       │
│                       └── 影响所有 oop 编解码
│
├── _narrow_klass ──→ NarrowPtrStruct { base=0x800000000, shift=0 }
│                       │
│                       └── 影响所有对象头中 Klass 指针编解码
│
├── 6 × LatestMethodCache (空壳，universe_post_init 中填充)
│   ├── _finalizer_register_cache
│   ├── _loader_addClass_cache
│   ├── _pd_implies_cache
│   ├── _throw_illegal_access_error_cache
│   ├── _throw_no_such_method_error_cache
│   └── _do_stack_walk_cache
│
├── SystemDictionary::_vm_weak_oop_storage ──→ OopStorage "VM Weak Oop Handles"
│                                               ├── _allocation_mutex = VMWeakAlloc_lock
│                                               └── _active_mutex = VMWeakActive_lock
│
├── Metaspace (静态类)
│   ├── _space_list ──→ VirtualSpaceList (8MB, 数据元空间)
│   │                    └── VirtualSpaceNode → (mmap 分配的虚拟内存)
│   │
│   ├── _chunk_manager_metadata ──→ ChunkManager
│   │                               ├── _free_chunks[3] (Specialized/Small/Medium)
│   │                               └── _humongous_dictionary (巨型 Chunk 树)
│   │
│   ├── 压缩类空间 (1GB, 0x800000000 ~ 0x840000000)
│   │   └── 由 _narrow_klass 编码管理
│   │
│   ├── _tracer ──→ MetaspaceTracer (JFR 事件追踪)
│   │
│   └── MetaspaceGC::_capacity_until_GC = MaxMetaspaceSize
│
├── MetaspaceCounters::_perf_counters ──→ MetaspacePerfCounters
│   └── sun.gc.metaspace.{minCapacity,capacity,maxCapacity,used}
│       └── 存储在 /tmp/hsperfdata_<user>/<pid> 共享内存
│
├── CompressedClassSpaceCounters::_perf_counters ──→ MetaspacePerfCounters
│   └── sun.gc.compressedclassspace.{minCapacity,capacity,maxCapacity,used}
│
├── ClassLoaderData::_the_null_class_loader_data ──→ ClassLoaderData (Bootstrap)
│   ├── _class_loader = NULL (Bootstrap 无 Java 对象)
│   ├── _metaspace = NULL (懒初始化)
│   │                ↓ (首次加载类时)
│   │   ClassLoaderMetaspace
│   │   ├── 从 Metaspace::_space_list 获取数据 Chunk
│   │   └── 从压缩类空间获取类 Chunk
│   ├── _klasses = NULL → 后续加载的所有 Bootstrap 类
│   └── _next = NULL
│
├── ClassLoaderDataGraph::_head ──→ 指向上面的 ClassLoaderData
│
├── SymbolTable::_the_table ──→ SymbolTable
│   ├── _buckets[0..20010] (156KB)
│   │   └── HashtableEntry → Symbol (在 Arena 中)
│   └── _arena (360KB, 分配 Symbol 对象)
│
├── StringTable::_the_table ──→ StringTable
│   ├── _local_table → ConcurrentHashTable
│   │   └── bucket 数: 60013 (默认)
│   └── _weak_handles ──→ OopStorage (String 是 Java 对象,需要 GC 管理)
│
├── ResolvedMethodTable::_the_table ──→ ResolvedMethodTable
│   ├── _buckets[0..1006] (8KB)
│   └── 弱引用 → ResolvedMethodName (Java 对象)
│
└── ThreadLocalAllocBuffer (静态配置)
    ├── _max_size = 262144 words (2MB)
    ├── _target_refills = 50
    └── _global_stats ──→ GlobalTLABStats

┌──────────────────────────────────────────────────────────────────────────────────┐
│                          跨对象关键关系                                           │
├──────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  G1CollectedHeap ←──使用──→ NarrowPtrStruct._narrow_oop                         │
│    (堆地址范围决定了压缩指针的 base/shift)                                       │
│                                                                                  │
│  Metaspace 压缩类空间 ←──紧邻──→ G1CollectedHeap                                │
│    (类空间 0x800000000 紧接堆末尾 0x800000000)                                  │
│                                                                                  │
│  ClassLoaderData ←──分配于──→ VirtualSpaceList + ChunkManager                   │
│    (加载类时从元空间申请 Chunk)                                                  │
│                                                                                  │
│  StringTable ←──存储弱引用──→ OopStorage                                         │
│    (String 对象的引用由 OopStorage 管理, GC 可扫描)                              │
│                                                                                  │
│  OopStorage "VM Weak" ←──GC 遍历──→ G1CollectedHeap                             │
│    (GC 标记阶段遍历 OopStorage 中的弱引用)                                      │
│                                                                                  │
│  TLAB._max_size ←──受限于──→ G1CollectedHeap.region_size                        │
│    (max_tlab_size = region_size / 2 = 2MB)                                      │
│                                                                                  │
│  MetaspacePerfCounters ←──查询──→ MetaspaceUtils (Metaspace 统计)                │
│    (计数器的值来自 Metaspace 的 committed/reserved/used)                         │
│                                                                                  │
│  SymbolTable + StringTable ←──被查询──→ 后续类加载/字符串intern                  │
│    (类加载时查找符号; String.intern() 查找/插入字符串表)                          │
│                                                                                  │
│  LatestMethodCache ←──后续填充──→ universe_post_init()                           │
│    (此时是空壳，post_init 中通过 init(Klass*, Method*) 填充)                    │
│                                                                                  │
│  ResolvedMethodTable ←──弱引用──→ Java 堆中的 ResolvedMethodName 对象            │
│    (GC 回收后自动清理条目)                                                       │
│                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

### 内存地址空间布局图

```
虚拟地址空间（低→高）

0x000000000  ┌─────────────────────────────┐
             │  ... (程序代码/数据/栈等) ...│
             │                             │
0x600000000  ├─────────────────────────────┤ ← G1CollectedHeap._reserved.start
             │                             │
             │      Java 堆 (8 GB)          │   由 G1CollectedHeap 管理
             │      2048 个 Region × 4MB    │   NarrowOop 编码范围
             │                             │
0x800000000  ├─────────────────────────────┤ ← NarrowKlass._base
             │                             │
             │    压缩类空间 (1 GB)          │   由 Metaspace 管理
             │    存储 Klass 结构体          │   NarrowKlass 编码范围
             │                             │
0x840000000  ├─────────────────────────────┤
             │  ... (未使用) ...            │
             │                             │
~0x7fffc29f  ├─────────────────────────────┤
             │    数据元空间 (初始 8 MB)      │   由 VirtualSpaceList 管理
             │    Method/ConstantPool/...   │   ChunkManager 管理空闲 Chunk
~0x7fffc31f  ├─────────────────────────────┤
             │                             │
             │  C 堆 (malloc) 分配的对象:    │
             │  ├─ G1CollectedHeap 本体     │
             │  ├─ OopStorage               │
             │  ├─ ClassLoaderData          │
             │  ├─ LatestMethodCache × 6    │
             │  ├─ SymbolTable + Arena      │
             │  ├─ StringTable              │
             │  ├─ ResolvedMethodTable      │
             │  ├─ ChunkManager             │
             │  ├─ MetaspaceTracer          │
             │  ├─ MetaspacePerfCounters ×2 │
             │  └─ GlobalTLABStats          │
             │                             │
             │  PerfData 共享内存:           │
             │  /tmp/hsperfdata_<user>/<pid>│
             │  └─ 8 个 Metaspace 计数器    │
             │                             │
0x7fffffffffff └─────────────────────────────┘
```
