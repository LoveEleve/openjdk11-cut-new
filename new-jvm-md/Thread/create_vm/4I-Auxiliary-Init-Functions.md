# 4I: init_globals() 辅助初始化函数合集

> **一句话总结**：本文覆盖 `init_globals()` 中 4A-4H 未详述的 12 个辅助函数，按重要度分三档介绍。
> **源码**：`share/runtime/init.cpp:104-168`
> **标准环境**：`-Xms8g -Xmx8g -XX:+UseG1GC -Xint`

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文分析 **4I: init_globals() 辅助初始化函数合集** 的初始化过程：JVM 启动时该组件如何被创建、配置和激活，以及初始化顺序的约束关系。

### 0.2 为什么需要？

JVM 初始化顺序有严格的依赖关系——某些组件必须在其他组件之前初始化。理解初始化顺序有助于排查启动失败问题，也能理解各组件的设计约束。

### 0.3 怎么解决？

追踪初始化函数的调用链，分析每个初始化步骤的前置条件和后置效果，识别关键的初始化顺序约束。

### 0.4 为什么这样设计？

初始化顺序的设计原则：「被依赖的先初始化」。例如内存管理必须在 GC 之前初始化，GC 必须在类加载之前初始化。

---


## 一、总览

`init_globals()` 共调用约 30 个初始化函数。4A-4H 已详细覆盖了核心函数（Bytecodes、CodeCache、Interpreter、StubRoutines、Universe 三阶段、SharedRuntime、javaClasses）。本文补全剩余 12 个函数。

```
init_globals() 30 个函数覆盖状态
├─ 4A+4B: codeCache_init()           ✅
├─ 4A+4C: interpreter_init()          ✅
├─ 4A+4C: templateTable_init()        ✅
├─ 4A+4D: stubRoutines_init1/2()      ✅
├─ 4A+4E: universe2_init()            ✅
├─ 4A+4F: universe_post_init()        ✅
├─ 4A+4G: SharedRuntime::generate_stubs() ✅
├─ 4H:    javaClasses_init()          ✅
├─ 4A:    bytecodes_init()            ✅
├─ 4A:    compilationPolicy_init()    ✅
├─ 4A:    universe_init()             ✅
├─ 4A:    jni_handles_init()          ✅
├─ 4A:    vtableStubs_init()          ✅
├─ 4A:    InlineCacheBuffer_init()    ✅
├─ 4A:    compilerOracle_init()       ✅
├─ 4A:    compileBroker_init()        ✅
│
├─ ▶ 本文 4I 覆盖以下 12 个 ◀
├─ 第一档（高）: VM_Version_init()
├─ 第一档（高）: classLoader_init1()
├─ 第一档（高）: referenceProcessor_init()
├─ 第一档（高）: MethodHandles::generate_adapters()
├─ 第二档（中）: management_init()
├─ 第二档（中）: gc_barrier_stubs_init()
├─ 第二档（中）: invocationCounter_init()
├─ 第三档（低）: VMRegImpl::set_regName()
├─ 第三档（低）: dependencyContext_init()
├─ 第三档（低）: accessFlags_init()
├─ 第三档（低）: InterfaceSupport_init()
└─ 第三档（低）: vmStructs_init()
```

---

## 二、第一档：高重要度（4 个）

### 2.1 VM_Version_init() — CPU 特性检测 ⭐⭐⭐

> **源码**：`share/runtime/vm_version.cpp:33-44`、`cpu/x86/vm_version_x86.cpp:1728-1747`
> **解决什么问题**：JVM 需要知道当前 CPU 支持哪些指令集（SSE/AVX/AES-NI 等），才能生成最优化的机器码。

```cpp
void VM_Version_init() {
  VM_Version::initialize();     // 平台相关，x86 实现在 vm_version_x86.cpp
  // 打印 CPU 信息日志
  if (log_is_enabled(Info, os, cpu)) { ... }
}
```

**x86 平台的 `VM_Version::initialize()` 做 3 件事：**

1. **生成 CPUID 桩代码**：创建一个 `BufferBlob("VM_Version stub")`，生成执行 `CPUID` 指令的汇编代码
2. **调用 `get_processor_features()`**：解析 CPUID 返回的特性位，设置全局标志
3. **检测虚拟化**：如果运行在虚拟机上，检测虚拟化类型

**检测的主要 CPU 特性：**

| 特性 | 影响 |
|------|------|
| SSE/SSE2/SSE3/SSE4.1/SSE4.2 | 向量化操作、CRC32 指令 |
| AVX/AVX2/AVX-512 | StubRoutines Phase 2 的 arraycopy、字符串操作 |
| AES-NI | `_aescrypt_encryptBlock` 等加密桩 |
| CLMUL | GHASH 操作 |
| BMI1/BMI2 | 位操作优化 |
| ADX | 大数乘法优化 |
| SHA | SHA 哈希桩 |
| TSC | 高精度时间戳 |

**JVM 参数**：使用 `-Xlog:os+cpu=info` 可以查看检测到的 CPU 特性。

**为什么在 `codeCache_init()` 之后、`stubRoutines_init1()` 之前？** 因为检测 CPU 特性需要在 CodeCache 中分配 BufferBlob 来存放 CPUID 桩代码，而 StubRoutines Phase 1 生成桩时需要知道 CPU 支持哪些指令集（例如是否用 AVX 版本的拷贝）。

---

### 2.2 classLoader_init1() — Bootstrap ClassLoader 初始化 ⭐⭐⭐

> **源码**：`share/classfile/classLoader.cpp:1840-1842` → `ClassLoader::initialize()` (L1681-1752)
> **解决什么问题**：Bootstrap ClassLoader 没有 Java 类表示，完全在 C++ 中实现。需要初始化性能计数器、加载 zip 库、设置引导类搜索路径。

```cpp
void classLoader_init1() {
    ClassLoader::initialize();
}
```

**`ClassLoader::initialize()` 做 3 件事：**

**① 创建大量 PerfData 性能计数器**（约 30 个）：

| 计数器 | 说明 |
|--------|------|
| `sun.cls.time` | 累计类加载时间 |
| `sun.cls.classInitTime` | 类初始化时间 |
| `sun.cls.classVerifyTime` | 类验证时间 |
| `sun.cls.classLinkedTime` | 类链接时间 |
| `sun.cls.parseClassTime` | 类解析时间 |
| `sun.cls.appClassLoadCount` | 应用类加载次数 |
| `sun.cls.sysClassBytes` | 系统类字节数 |

这些计数器可通过 `jcmd <pid> PerfCounter.print | grep sun.cls` 查看，也存储在 `/tmp/hsperfdata_<user>/<pid>` 文件中。

**② 加载 zip 库**：`load_zip_library()` 加载 `libzip.so`，后续读取 `rt.jar`（JDK 8）或 `modules` 文件需要 zip 解压能力。

**③ 设置引导类搜索路径**：`setup_bootstrap_search_path()` 解析 `-Xbootclasspath` 和默认的 JDK 模块路径，构建 `ClassPathEntry` 链表。

---

### 2.3 referenceProcessor_init() — 引用处理器初始化 ⭐⭐⭐

> **源码**：`share/gc/shared/referenceProcessor.cpp:46-72`
> **解决什么问题**：GC 处理 Soft/Weak/Final/Phantom 引用时需要策略来决定何时清除软引用。

```cpp
void referenceProcessor_init() {
    ReferenceProcessor::init_statics();
}
```

**`init_statics()` 做 3 件事：**

**① 初始化软引用时间戳时钟**：

```cpp
_soft_ref_timestamp_clock = os::javaTimeNanos() / NANOSECS_PER_MILLISEC;
java_lang_ref_SoftReference::set_clock(_soft_ref_timestamp_clock);
```

这个时钟记录了 JVM 启动时刻。之后每次 GC 会更新它。软引用的 `timestamp` 字段记录了上次访问时间，GC 通过比较两者差值决定是否清除。

**② 创建两种引用清理策略**：

| 策略 | 使用场景 | 清除规则 |
|------|---------|---------|
| `AlwaysClearPolicy` | 内存紧张时（Full GC） | 无条件清除所有软引用 |
| `LRUMaxHeapPolicy` | Server 模式默认 | 基于最大堆空闲空间的 LRU 策略 |
| `LRUCurrentHeapPolicy` | Client 模式默认 | 基于当前堆空闲空间的 LRU 策略 |

我们的环境是 Server 模式，所以默认策略是 `LRUMaxHeapPolicy`。

**LRU 策略核心**：`_max_interval` = 空闲堆内存(MB) × `SoftRefLRUPolicyMSPerMB`（默认 1000ms/MB）。如果软引用的上次访问距今超过 `_max_interval`，就清除它。8GB 堆全空闲时，软引用可存活 8000 秒 ≈ 2.2 小时。

**③ 验证引用发现策略**：确保 `RefDiscoveryPolicy` 是 `ReferenceBasedDiscovery` 或 `ReferentBasedDiscovery` 之一。

**策略类层次**：

```
ReferencePolicy (CHeapObj<mtGC>)
  ├─ NeverClearPolicy      — 永不清除
  ├─ AlwaysClearPolicy     — 总是清除
  ├─ LRUCurrentHeapPolicy  — 基于当前堆空闲的 LRU
  └─ LRUMaxHeapPolicy      — 基于最大堆空闲的 LRU
```

---

### 2.4 MethodHandles::generate_adapters() — MethodHandle 适配器生成 ⭐⭐⭐

> **源码**：`share/prims/methodHandles.cpp:75-105`
> **解决什么问题**：Java 的 MethodHandle、Lambda 表达式需要解释器入口点来执行。
> **在 `init_globals()` 中的位置**：倒数第二个，在 `stubRoutines_init2()` 之后。

```cpp
void MethodHandles::generate_adapters() {
    _adapter_code = MethodHandlesAdapterBlob::create(adapter_code_size);
    CodeBuffer code(_adapter_code);
    MethodHandlesAdapterGenerator g(&code);
    g.generate();  // 生成所有 MethodHandle 解释器入口
}
```

**做 3 件事：**

1. **创建 `MethodHandlesAdapterBlob`**：在 CodeCache 中分配一块内存，是 `BufferBlob` 的子类
2. **遍历所有 MethodHandle invoke 种类**：从 `method_handle_invoke_FIRST` 到 `method_handle_invoke_LAST`
3. **为每种生成解释器入口点**：调用 `generate_method_handle_interpreter_entry()` 生成汇编代码，然后 `Interpreter::set_entry_for_kind(mk, entry)` 注册入口

**MethodHandle invoke 种类**（对应 `vmIntrinsics::ID`）：

| 种类 | 对应 Java 方法 | 说明 |
|------|--------------|------|
| `_invokeBasic` | `MethodHandle.invokeBasic()` | 基础调用 |
| `_linkToVirtual` | `MethodHandle.linkToVirtual()` | 链接虚调用 |
| `_linkToStatic` | `MethodHandle.linkToStatic()` | 链接静态调用 |
| `_linkToSpecial` | `MethodHandle.linkToSpecial()` | 链接特殊调用 |
| `_linkToInterface` | `MethodHandle.linkToInterface()` | 链接接口调用 |

**JVM 参数**：使用 `-XX:+PrintMethodHandleStubs` 可以在生成时打印每个桩的汇编代码。

**在 CodeCache 中的位置**：`MethodHandlesAdapterBlob` 位于 CodeCache 末尾附近（在 `_code2` 和 SharedRuntime blobs 之后）。

---

## 三、第二档：中等重要度（3 个）

### 3.1 management_init() — JMX 管理子系统 ⭐⭐

> **源码**：`share/services/management.cpp:84-123`
> **解决什么问题**：初始化 Java Management Extensions（JMX）所需的底层服务。

```cpp
void management_init() {
    Management::init();           // JMX 核心：创建 PerfData 时间戳
    ThreadService::init();        // 线程监控服务
    RuntimeService::init();       // 运行时服务
    ClassLoadingService::init();  // 类加载监控
}
```

**`Management::init()` 创建 3 个关键时间戳**：

| PerfData 变量 | 说明 |
|---------------|------|
| `sun.rt.createVmBeginTime` | VM 创建开始时间 |
| `sun.rt.createVmEndTime` | VM 创建结束时间 |
| `sun.rt.vmInitDoneTime` | VM 初始化完成时间 |

可通过 `jcmd <pid> PerfCounter.print | grep -E "createVm|vmInit"` 查看。

还设置了 `_optional_support` 位域，告诉 Java 层哪些监控功能可用（低内存检测、编译时间监控、线程竞争监控等）。

**为什么是第一个被调用的？** 因为 `management_init()` 创建的时间戳需要尽早记录 VM 创建开始时间。

---

### 3.2 gc_barrier_stubs_init() — GC 屏障桩代码 ⭐⭐

> **源码**：`share/gc/shared/barrierSet.cpp:47-53`
> **解决什么问题**：某些 GC 需要在 CodeCache 中生成屏障桩代码（汇编级别的读写屏障入口）。

```cpp
void gc_barrier_stubs_init() {
    BarrierSet* bs = BarrierSet::barrier_set();
    BarrierSetAssembler* bs_assembler = bs->barrier_set_assembler();
    bs_assembler->barrier_stubs_init();
}
```

**在我们的 G1 环境中**：`barrier_stubs_init()` 的实现为**空操作**。G1 的写屏障代码不在这里生成，而是由解释器模板和 JIT 编译器内联生成。

**位置要求**：在 `universe_init()` 之后（需要 BarrierSet 已创建）、`interpreter_init()` 之前（解释器生成代码时需要屏障桩就绪）。

---

### 3.3 invocationCounter_init() — 编译阈值设置 ⭐⭐

> **源码**：`share/interpreter/invocationCounter.cpp:138-171`
> **解决什么问题**：设置解释器的编译阈值——方法执行多少次后触发 JIT 编译。

```cpp
void invocationCounter_init() {
    InvocationCounter::reinitialize(DelayCompilationDuringStartup);
}
```

**`reinitialize()` 做 2 件事：**

**① 定义调用计数器状态机**：

| 状态 | 初始值 | 动作 | 说明 |
|------|--------|------|------|
| `wait_for_nothing` | 0 | `do_nothing`（设 carry） | 计数器已满载 |
| `wait_for_compile` | 0 | `do_decay`（启动期延迟）/ `dummy_overflow` | 等待编译 |

启动期间（`DelayCompilationDuringStartup=true`），`wait_for_compile` 使用 `do_decay` 动作——让计数器衰减而不是立即编译，避免启动时大量方法同时触发编译。

**② 计算编译阈值**：

```cpp
InterpreterInvocationLimit = CompileThreshold << number_of_noncount_bits;
InterpreterBackwardBranchLimit = (CompileThreshold * (OnStackReplacePercentage - InterpreterProfilePercentage)) / 100;
```

默认参数下（`CompileThreshold=10000`，`OnStackReplacePercentage=140`）：

| 阈值 | 公式 | 默认值 |
|------|------|--------|
| `InterpreterInvocationLimit` | `10000 << 3 = 80000` | 方法调用编译阈值 |
| `InterpreterBackwardBranchLimit` | `10000 × (140-33) / 100 = 10700` | OSR 回边编译阈值 |
| `InterpreterProfileLimit` | `10000 × 33 / 100 << 3 = 26400` | Profile 阈值 |

**注意**：在 `-Xint` 模式下，这些阈值仍然会被设置，但因为没有编译器，永远不会触发编译。

---

## 四、第三档：低重要度（5 个）

### 4.1 VMRegImpl::set_regName() — 寄存器名数组 ⭐

> **源码**：`cpu/x86/vmreg_x86.cpp:31-69`

填充全局 `regName[]` 数组，为所有硬件寄存器建立名称映射。按顺序填充：

```
GPR (rax, rbx, ... r15) → 每个占 2 slot (AMD64)
FPR (st0-st7)          → 每个占 2 slot
XMM (xmm0-xmm31)      → 每个占 max_slots_per_register slot
K   (k0-k7)            → AVX-512 掩码寄存器
剩余 slot              → "NON-GPR-FPR-XMM-KREG"
```

**用途**：OopMap 打印、调试信息中显示寄存器名称。在 `SharedRuntime::generate_stubs()` 之前必须完成（生成桩代码时打印 oop map 需要寄存器名）。

### 4.2 dependencyContext_init() — 依赖追踪计数器 ⭐

> **源码**：`share/code/dependencyContext.cpp:39-55`

仅创建 4 个 PerfData 计数器，用于监控 nmethod 依赖桶的分配和释放统计：

| 计数器 | 说明 |
|--------|------|
| `sun.ci.nmethodBucketsAllocated` | 分配的依赖桶数 |
| `sun.ci.nmethodBucketsDeallocated` | 释放的依赖桶数 |
| `sun.ci.nmethodBucketsStale` | 过期的依赖桶数 |
| `sun.ci.nmethodBucketsStaleAccumulated` | 累计过期桶数 |

### 4.3 accessFlags_init() — 极简 ⭐

> **源码**：`share/utilities/accessFlags.cpp:74`

```cpp
void accessFlags_init() {
    assert(googbye(sizeof(googbye_format)) == googbye_expected, "");
}
```

仅包含一个 `sizeof` 断言，验证 `AccessFlags` 的内存大小正确。**零运行时开销**。

### 4.4 InterfaceSupport_init() — 极简 ⭐

> **源码**：`share/runtime/interfaceSupport.cpp:264`

```cpp
void InterfaceSupport_init() {
#ifdef ASSERT
    srand(seed);
#endif
}
```

仅在 debug 版本中调用 `srand()`，为后续的 `StressDerivedPointers` 等随机化测试设置种子。

### 4.5 vmStructs_init() — Debug-only ⭐

> **源码**：`share/runtime/vmStructs.cpp:3207`

```cpp
void vmStructs_init() {
#ifndef PRODUCT
    VMStructs::init();  // 验证 SA (Serviceability Agent) 使用的结构体布局
#endif
}
```

仅在非 Product 版本中运行，验证 Serviceability Agent（SA）使用的 C++ 结构体偏移量是否与运行时一致。SA 是 JDK 自带的诊断工具，需要知道 JVM 内部数据结构的布局。

---

## 五、调用顺序与依赖关系

```
init_globals() 完整调用顺序（标注依赖和覆盖文档）
─────────────────────────────────────────────────
 1. management_init()              [4I] JMX 时间戳
 2. bytecodes_init()               [4A] 字节码定义
 3. classLoader_init1()            [4I] Bootstrap ClassLoader
 4. compilationPolicy_init()       [4A] 编译策略
 5. codeCache_init()               [4B] CodeHeap
 6. VM_Version_init()              [4I] CPU 特性 → 需要 CodeCache
 7. os_init_globals()              [空] 
 8. stubRoutines_init1()           [4D] Phase 1 桩 → 需要 CPU 特性
 9. universe_init()                [5]  堆+元空间 → 需要 Phase 1 桩
10. gc_barrier_stubs_init()        [4I] GC 屏障桩 → 需要 universe
11. interpreter_init()             [4C] 解释器 → 需要 GC 屏障桩
12. invocationCounter_init()       [4I] 编译阈值
13. accessFlags_init()             [4I] sizeof 断言
14. templateTable_init()           [4C] 模板表
15. InterfaceSupport_init()        [4I] srand
16. VMRegImpl::set_regName()       [4I] 寄存器名 → SharedRuntime 前置
17. SharedRuntime::generate_stubs()[4G] 11 个 Blob
18. universe2_init()               [4E] Genesis
19. javaClasses_init()             [4H] 偏移量 → 需要 vtable 初始化后
20. referenceProcessor_init()      [4I] 引用策略 → 需要 javaClasses
21. jni_handles_init()             [4A] JNI 引用
22. vmStructs_init()               [4I] SA 验证
23. vtableStubs_init()             [4A] vtable 桩
24. InlineCacheBuffer_init()       [4A] IC 缓冲
25. compilerOracle_init()          [4A] 编译指令
26. dependencyContext_init()       [4I] 依赖计数器
27. compileBroker_init()           [4A] 编译调度
28. universe_post_init()           [4F] 预分配异常
29. stubRoutines_init2()           [4D] Phase 2 桩
30. MethodHandles::generate_adapters() [4I] MH 适配器 → 最后生成
```

---

## 六、关键数字

| 项目 | 值 |
|------|-----|
| init_globals() 总函数数 | 30 |
| 4A-4H 已详细覆盖 | 18 |
| 本文 4I 覆盖 | 12 |
| 总覆盖率 | **30/30 (100%)** |
| management_init PerfData 数 | 3 个时间戳 + optional_support |
| ClassLoader::initialize PerfData 数 | ~30 个计数器 |
| invocationCounter 默认编译阈值 | 10000 |
| 引用策略（Server） | LRUMaxHeapPolicy |
| MethodHandle invoke 种类数 | 5 |
| VMRegImpl::set_regName 填充 | GPR+FPR+XMM+K 全部寄存器 |

---

## 七、源文件索引

| 源文件 | 函数 |
|--------|------|
| `share/runtime/vm_version.cpp` | `VM_Version_init()` |
| `cpu/x86/vm_version_x86.cpp` | `VM_Version::initialize()` |
| `share/classfile/classLoader.cpp` | `classLoader_init1()`, `ClassLoader::initialize()` |
| `share/gc/shared/referenceProcessor.cpp` | `referenceProcessor_init()`, `ReferenceProcessor::init_statics()` |
| `share/gc/shared/referencePolicy.hpp` | `ReferencePolicy` 类层次 |
| `share/prims/methodHandles.cpp` | `MethodHandles::generate_adapters()` |
| `share/prims/methodHandles.hpp` | `MethodHandles` 类声明 |
| `share/services/management.cpp` | `management_init()`, `Management::init()` |
| `share/gc/shared/barrierSet.cpp` | `gc_barrier_stubs_init()` |
| `share/interpreter/invocationCounter.cpp` | `invocationCounter_init()`, `InvocationCounter::reinitialize()` |
| `cpu/x86/vmreg_x86.cpp` | `VMRegImpl::set_regName()` |
| `share/code/dependencyContext.cpp` | `dependencyContext_init()` |
| `share/utilities/accessFlags.cpp` | `accessFlags_init()` |
| `share/runtime/interfaceSupport.cpp` | `InterfaceSupport_init()` |
| `share/runtime/vmStructs.cpp` | `vmStructs_init()` |
