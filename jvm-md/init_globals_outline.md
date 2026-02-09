# init_globals() 初始化大纲

> 源码位置: `src/hotspot/share/runtime/init.cpp:104`
> 
> 本大纲涵盖 `init_globals()` 中**所有**初始化方法，包括 `universe_init()` 之前和之后的部分。
> 已完成的部分用 ✅ 标记，待分析的部分用 ⬜ 标记。

---

## 整体调用流程图

```
init_globals()
│
├── [Phase 1: 基础设施初始化]
│   ├── management_init()         ─── JMX 管理接口
│   ├── bytecodes_init()          ─── 字节码表初始化
│   ├── classLoader_init1()       ─── 类加载器初始化(第一阶段)
│   ├── compilationPolicy_init()  ─── 编译策略初始化
│   ├── codeCache_init()          ─── 代码缓存初始化
│   ├── VM_Version_init()         ─── CPU 特性检测
│   ├── os_init_globals()         ─── OS 全局初始化(空)
│   └── stubRoutines_init1()      ─── 桩代码生成(第一阶段)
│
├── [Phase 2: 核心数据结构初始化]
│   └── universe_init() ✅        ─── 堆/元空间/符号表等核心结构
│
├── [Phase 3: 解释器与运行时初始化]
│   ├── gc_barrier_stubs_init()   ─── GC 屏障桩代码
│   ├── interpreter_init()        ─── 解释器初始化 (核心!)
│   ├── invocationCounter_init()  ─── 调用计数器
│   ├── accessFlags_init()        ─── 访问标志初始化
│   ├── templateTable_init()      ─── 模板表初始化 (字节码→机器码模板)
│   ├── InterfaceSupport_init()   ─── 接口支持初始化
│   ├── VMRegImpl::set_regName()  ─── 寄存器名称设置
│   └── SharedRuntime::generate_stubs() ─── 运行时桩代码生成
│
├── [Phase 4: 类系统初始化]
│   ├── universe2_init()          ─── 原始类加载 (genesis)
│   └── javaClasses_init()        ─── Java 类偏移量计算
│
├── [Phase 5: 引用处理与JNI]
│   ├── referenceProcessor_init() ─── 引用处理器初始化
│   └── jni_handles_init()        ─── JNI 句柄初始化
│
├── [Phase 6: 调试与诊断]
│   └── vmStructs_init()          ─── VM 结构信息(调试用)
│
├── [Phase 7: 方法调用支持]
│   ├── vtableStubs_init()        ─── 虚表桩代码初始化
│   └── InlineCacheBuffer_init()  ─── 内联缓存缓冲区
│
├── [Phase 8: JIT 编译器初始化]
│   ├── compilerOracle_init()     ─── 编译器命令/指令
│   ├── dependencyContext_init()  ─── 依赖上下文
│   └── compileBroker_init()      ─── 编译代理初始化 (C1/C2)
│
├── [Phase 9: 后初始化]
│   ├── universe_post_init() ✅  ─── 预分配异常对象
│   ├── stubRoutines_init2()      ─── 桩代码生成(第二阶段)
│   └── MethodHandles::generate_adapters() ─── MethodHandle 适配器
│
└── return JNI_OK
```

---

## Phase 1: 基础设施初始化

### 1.1 management_init() ⬜

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/services/management.cpp:84` |
| 依赖 | 无 |
| 被依赖 | 无 |

**主要功能**：初始化 JMX (Java Management Extensions) 管理接口

**调用的子函数**：
```cpp
void management_init() {
    Management::init();        // JMX 核心初始化
    ThreadService::init();     // 线程监控服务
    RuntimeService::init();    // 运行时服务
    ClassLoadingService::init(); // 类加载监控
}
```

**关键数据结构**：
- `Management` - JMX 核心管理类
- `ThreadService` - java.lang.management.ThreadMXBean 实现
- `RuntimeService` - java.lang.management.RuntimeMXBean 实现
- `ClassLoadingService` - java.lang.management.ClassLoadingMXBean 实现

**待分析子节点**：
- [ ] Management::init() - 创建 VM 时间戳计数器
- [ ] ThreadService::init() - 线程峰值/daemon 计数器
- [ ] RuntimeService::init() - safepoint 计数器
- [ ] ClassLoadingService::init() - 类加载/卸载计数器

**相关 JVM 参数**：
- `-Dcom.sun.management.jmxremote` - 启用远程 JMX
- `-XX:+UsePerfData` - 启用性能数据

---

### 1.2 bytecodes_init() ✅ → [Bytecodes/bytecodes_init.md](Bytecodes/bytecodes_init.md)

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/interpreter/bytecodes.cpp:561` |
| 依赖 | 无 |
| 被依赖 | interpreter_init |
| **详细文档** | **[Bytecodes/bytecodes_init.md](Bytecodes/bytecodes_init.md)** |
| **GDB 脚本** | **[Bytecodes/gdb_bytecodes_init.txt](Bytecodes/gdb_bytecodes_init.txt)** |

**主要功能**：初始化 JVM 字节码表（203 个标准 + 36 个 HotSpot 扩展）

**调用的子函数**：
```cpp
void bytecodes_init() {
    Bytecodes::initialize();  // 初始化 239 个字节码属性表
}
```

**GDB 验证结果**（-Xms256m -Xmx256m -XX:+UseG1GC）：
```
=== Bytecodes Info ===
_is_initialized: 1                    ← 初始化完成 ✅
number_of_codes: 239                  ← HotSpot 11 总字节码数 ✅
number_of_java_codes: 203             ← 标准 Java 字节码数 ✅

=== Sample Bytecodes ===
iconst_0 (0x03): name=iconst_0, depth=1      ← 压入 1 个 int ✅
iadd (0x60): name=iadd, depth=-1              ← 弹 2 压 1 = -1 ✅
invokevirtual (0xb6): name=invokevirtual, depth=-1  ← 依赖方法签名 ✅
```

**关键数据结构**：
| 数组 | 用途 | 示例 |
|------|------|------|
| `_name[]` | 指令名称 | `_name[0x60] = "iadd"` |
| `_result_type[]` | 结果类型 | `_result_type[0x60] = T_INT` |
| `_depth[]` | 栈变化 | `_depth[0x60] = -1` |
| `_lengths[]` | 指令长度 | 低 4 位=普通, 高 4 位=wide |
| `_java_code[]` | 原始字节码 | `_java_code[_fast_igetfield] = _getfield` |
| `_flags[]` | 格式标志 | `_bc_can_trap`, `_fmt_has_j` |

**字节码分类**：
| 类别 | 数量 | 示例 |
|------|------|------|
| 常量入栈 | 21 | iconst_0, ldc |
| 局部变量加载/存储 | 50 | iload, astore_0 |
| 数组操作 | 16 | iaload, aastore |
| 栈操作 | 9 | pop, dup, swap |
| 算术/位运算 | 36 | iadd, lshl |
| 类型转换 | 15 | i2l, d2f |
| 比较/跳转 | 26 | ifeq, goto |
| 方法调用 | 5 | invokevirtual, invokedynamic |
| 对象操作 | 12 | new, getfield |
| HotSpot 扩展 | 36 | _fast_igetfield, _invokehandle |

**已分析内容**：
- ✅ 203 个标准字节码完整分类
- ✅ 36 个 HotSpot 扩展字节码
- ✅ 格式字符串详解
- ✅ 栈深度计算规则
- ✅ 字节码重写机制
- ✅ def() 函数实现
- ✅ 面试高频问题

**已完成分析** ✅
- [ ] Bytecodes::def() - 单个字节码定义
- [ ] 标准字节码 (0x00-0xCA) vs 内部字节码 (0xCB-0xE5)
- [ ] 字节码属性: can_trap, store, load, branch, call, return

**字节码分类**：
| 类型 | 范围 | 数量 | 示例 |
|------|------|------|------|
| 标准字节码 | 0x00-0xCA | 203 | iconst_0, aload, invokevirtual |
| 内部字节码 | 0xCB-0xE5 | 26 | _fast_agetfield, _fast_invokevfinal |

---

### 1.3 classLoader_init1() ⬜

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/classfile/classLoader.cpp:1840` |
| 依赖 | 无 |
| 被依赖 | universe_init |

**主要功能**：类加载器第一阶段初始化（当前基本为空方法）

**调用的子函数**：
```cpp
void classLoader_init1() {
    ClassLoader::initialize();  // 基本为空
}
```

**说明**：真正的类加载器初始化在 `classLoader_init2()` 中完成（在 `Threads::create_vm()` 后期调用）

**待分析子节点**：
- [ ] ClassLoader::initialize() - 为何是空方法
- [ ] ClassLoader::classLoader_init2() - 真正的初始化（对比分析）

---

### 1.4 compilationPolicy_init() ⬜

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/runtime/compilationPolicy.cpp:61` |
| 依赖 | 无 |
| 被依赖 | compileBroker_init |

**主要功能**：初始化编译策略（决定何时/如何将热点代码 JIT 编译）

**调用的子函数**：
```cpp
void compilationPolicy_init() {
    CompilationPolicy::set_in_vm_startup(DelayCompilationDuringStartup);
    switch(CompilationPolicyChoice) {
        case 0: CompilationPolicy::set_policy(new SimpleCompPolicy()); break;
        case 1: CompilationPolicy::set_policy(new StackWalkCompPolicy()); break;
        case 2: CompilationPolicy::set_policy(new TieredThresholdPolicy()); break;
    }
}
```

**关键数据结构**：
- `CompilationPolicy` - 编译策略基类
- `SimpleCompPolicy` - 简单策略（仅 C1 或 C2）
- `StackWalkCompPolicy` - 栈扫描策略（仅 C2）
- `TieredThresholdPolicy` - 分层编译策略（默认）

**编译策略对比**：
| 策略 | CompilationPolicyChoice | 编译器 | 特点 |
|------|-------------------------|--------|------|
| SimpleCompPolicy | 0 | C1 或 C2 | 单一编译器 |
| StackWalkCompPolicy | 1 | 仅 C2 | 基于栈扫描 |
| TieredThresholdPolicy | 2 | C1 + C2 | 分层编译（默认） |

**待分析子节点**：
- [ ] TieredThresholdPolicy 分层编译阈值
- [ ] 编译级别 (Level 0-4)
- [ ] CompileThreshold 参数

**相关 JVM 参数**：
- `-XX:CompilationPolicyChoice=N` - 选择编译策略
- `-XX:TieredCompilation` - 启用分层编译（默认开启）
- `-XX:CompileThreshold=N` - 编译阈值

---

### 1.5 codeCache_init() ✅ ⭐重要 → [CodeCache/codeCache_init.md](CodeCache/codeCache_init.md)

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/code/codeCache.cpp:1128` |
| 依赖 | 无 |
| 被依赖 | universe_init, stubRoutines_init1, interpreter_init |
| **详细文档** | **[CodeCache/codeCache_init.md](CodeCache/codeCache_init.md)** |
| **GDB 脚本** | **[CodeCache/gdb_codeCache_init.txt](CodeCache/gdb_codeCache_init.txt)** |

**主要功能**：初始化代码缓存（存储 JIT 编译后的机器码）

**调用的子函数**：
```cpp
void codeCache_init() {
    CodeCache::initialize();  // 核心初始化
    AOTLoader::initialize();  // AOT 加载器（默认不开启）
}
```

**关键数据结构**：
- `CodeCache` - 代码缓存管理器（静态类）
- `CodeHeap` - 代码堆（实际存储区域）
- `CodeBlob` - 代码块基类
- `nmethod` - 编译后的方法
- `BufferBlob` - 缓冲区代码块

**GDB 验证结果（-Xms8g -Xmx8g）**：
| 属性 | 值 |
|------|-----|
| _low_bound | 0x7fffe1000000 |
| _high_bound | 0x7ffff0000000 |
| 总大小 | 240 MB |
| _heaps->length() | 3 |
| SegmentedCodeCache | true |

**CodeCache 分区（分层编译模式）**：
| 分区名称 | 存储内容 | GDB 验证大小 |
|----------|----------|--------------|
| Non-nmethods | 运行时桩、适配器 (永不回收) | ~7 MB |
| Profiled | C1 编译代码 (Level 2,3) | ~116 MB |
| Non-profiled | C2 编译代码 (Level 1,4) | ~116 MB |

**数据结构大小**：
| 结构 | 大小 |
|------|------|
| sizeof(CodeHeap) | 344 bytes |
| sizeof(CodeBlob) | 120 bytes |
| sizeof(HeapBlock) | 16 bytes |
| sizeof(FreeBlock) | 24 bytes |

**相关 JVM 参数**：
- `-XX:ReservedCodeCacheSize=N` - 代码缓存大小（默认 240MB）
- `-XX:InitialCodeCacheSize=N` - 初始大小（默认 2.5MB）
- `-XX:CodeCacheExpansionSize=N` - 扩展大小（默认 64KB）
- `-XX:+SegmentedCodeCache` - 分段模式（默认 true）
- `-XX:+PrintCodeCache` - 打印代码缓存信息

**已完成分析** ✅

---

### 1.6 VM_Version_init() ⬜

| 属性 | 值 |
|------|-----|
| 源码位置 | 平台相关 `src/hotspot/cpu/x86/vm_version_x86.cpp` |
| 依赖 | 无 |
| 被依赖 | stubRoutines_init1, 所有 SIMD 优化 |

**主要功能**：检测 CPU 特性（SIMD 指令集、缓存大小等）

**检测的 CPU 特性**：
| 特性 | 用途 |
|------|------|
| SSE/SSE2/SSE3/SSSE3/SSE4.1/SSE4.2 | SIMD 向量化 |
| AVX/AVX2/AVX-512 | 高级向量化 |
| AES-NI | AES 加密加速 |
| CLMUL | CRC32/多项式乘法 |
| BMI1/BMI2 | 位操作指令 |
| ADX | 大整数加法 |

**待分析子节点**：
- [ ] CPUID 指令调用
- [ ] 特性标志位设置
- [ ] 缓存行大小检测

**相关 JVM 参数**：
- `-XX:+UseSSE42Intrinsics` - 使用 SSE4.2 内部函数
- `-XX:+UseAVX` - 使用 AVX 指令
- `-XX:+UseAESIntrinsics` - 使用 AES-NI

---

### 1.7 stubRoutines_init1() ✅ ⭐重要 → [StubRoutines/stubRoutines_init1.md](StubRoutines/stubRoutines_init1.md)

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/runtime/stubRoutines.cpp:410` |
| 依赖 | codeCache_init, VM_Version_init |
| 被依赖 | universe_init |
| **详细文档** | **[StubRoutines/stubRoutines_init1.md](StubRoutines/stubRoutines_init1.md)** |
| **GDB 脚本** | **[StubRoutines/gdb_stubRoutines_init1.txt](StubRoutines/gdb_stubRoutines_init1.txt)** |

**主要功能**：生成 JVM 运行时需要的**第一批**汇编桩代码（Stub）

**调用的子函数**：
```cpp
void stubRoutines_init1() {
    StubRoutines::initialize1();
}
```

**生成的桩代码（第一阶段）**：
| 桩代码名称 | 入口变量 | 功能 |
|------------|----------|------|
| call_stub | `_call_stub_entry` | C++ 调用 Java 方法入口 ★最重要 |
| catch_exception | `_catch_exception_entry` | 异常捕获 |
| forward_exception | `_forward_exception_entry` | 异常转发 |
| atomic_xchg | `_atomic_xchg_entry` | 原子交换 (32位) |
| atomic_cmpxchg | `_atomic_cmpxchg_entry` | CAS 比较交换 |
| atomic_cmpxchg_long | `_atomic_cmpxchg_long_entry` | CAS (64位) |
| atomic_add | `_atomic_add_entry` | 原子加法 |
| fence | `_fence_entry` | 内存屏障 |
| throw_StackOverflowError | `_throw_StackOverflowError_entry` | 栈溢出异常 |

**GDB 验证结果（-Xms256m -Xmx256m）**：
```
=== StubRoutines Code Blocks ===
_code1 = (BufferBlob *) 0x7fffed000b90    ← 第一阶段代码块
_code2 = (BufferBlob *) 0x0               ← 第二阶段尚未初始化

=== Core Stub Entries ===
_call_stub_entry          = 0x7fffed000c9e
_catch_exception_entry    = 0x7fffed000e50
_forward_exception_entry  = 0x7fffed000c20

=== Atomic Stubs ===
_atomic_cmpxchg_entry = 0x7fffed000f14

=== Disassemble atomic_cmpxchg (仅 3 条指令！) ===
0x7fffed000f14:  mov    %edx,%eax           ; rax = compare_value
0x7fffed000f16:  lock cmpxchg %edi,(%rsi)   ; 原子 CAS
0x7fffed000f1a:  ret
```

**StubRoutines (1) vs (2) 对比**：
| 阶段 | 时机 | 内容 |
|------|------|------|
| stubRoutines_init1 | universe_init 之前 | 基础桩 (call_stub, 异常处理, 原子操作) |
| stubRoutines_init2 | universe_post_init 之后 | 高级桩 (arraycopy, 加解密) |

**已完成分析** ✅

---

## Phase 2: 核心数据结构初始化

### 2.1 universe_init() ✅ 已完成

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/memory/universe.cpp:774` |
| 依赖 | codeCache_init, stubRoutines_init1 |
| 被依赖 | gc_barrier_stubs_init |

**详细分析**：见 `jvm-md/Universe/` 目录下的系列文档

**已完成的子节点**：
- ✅ 3.1-3.4 堆初始化 (create_heap, initialize, TLAB, 压缩指针)
- ✅ 4. OopStorage
- ✅ 5. Metaspace
- ✅ 6. 性能计数器
- ✅ 9. ClassLoaderData
- ✅ 10. LatestMethodCache
- ✅ 11. SymbolTable
- ✅ 12. StringTable
- ✅ 13. ResolvedMethodTable

---

## Phase 3: 解释器与运行时初始化

### 3.1 gc_barrier_stubs_init() ✅

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/gc/shared/barrierSet.cpp:47` |
| 依赖 | universe_init |
| 被依赖 | interpreter_init |

**主要功能**：初始化 GC 屏障桩代码

**调用的子函数**：
```cpp
void gc_barrier_stubs_init() {
    BarrierSet* bs = BarrierSet::barrier_set();
    BarrierSetAssembler* bs_assembler = bs->barrier_set_assembler();
    bs_assembler->barrier_stubs_init();
}
```

**重要说明**：
- **G1 的 `barrier_stubs_init()` 是空实现！**
- G1 的写屏障代码（SATB 前置屏障、dirty card 后置屏障）不是独立的 stub
- 而是在**解释器字节码模板生成时内联**到 `putfield`、`aastore` 等字节码中
- 同样在 C1/C2 编译器生成代码时内联

**G1 屏障汇编的真正位置**：
```
src/hotspot/cpu/x86/gc/g1/g1BarrierSetAssembler_x86.cpp

g1_write_barrier_pre()   → SATB 前置屏障
g1_write_barrier_post()  → dirty card 后置屏障
oop_store_at()           → 完整的引用存储操作
```

> **详细分析见**: [Interpreter/G1-Barrier-Assembly.md](Interpreter/G1-Barrier-Assembly.md) - G1 屏障 x86-64 汇编实现

**ZGC/Shenandoah 的情况不同**：
- ZGC 的 `barrier_stubs_init()` 会生成 load barrier stub
- Shenandoah 会生成 SATB barrier stub

---

### 3.2 interpreter_init() ✅ ⭐⭐⭐核心 → [Interpreter/interpreter_init.md](Interpreter/interpreter_init.md)

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/interpreter/interpreter.cpp:115` |
| 依赖 | gc_barrier_stubs_init |
| 被依赖 | universe2_init |
| **详细大纲** | **[Interpreter/interpreter_init_outline.md](Interpreter/interpreter_init_outline.md)** |
| **详细分析** | **[Interpreter/interpreter_init.md](Interpreter/interpreter_init.md)** |
| **GDB 脚本** | **[Interpreter/gdb_interpreter_init.txt](Interpreter/gdb_interpreter_init.txt)** |

**主要功能**：初始化 JVM 解释器（字节码解释执行的核心）

**调用的子函数**：
```cpp
void interpreter_init() {
    Interpreter::initialize();  // 生成解释器代码
    if (TraceBytecodes) BytecodeTracer::set_closure(...);
    Forte::register_stub("Interpreter", ...);
    if (JvmtiExport::should_post_dynamic_code_generated()) {
        JvmtiExport::post_dynamic_code_generated("Interpreter", ...);
    }
}
```

**关键数据结构**：
- `Interpreter` - 解释器类
- `InterpreterCodelet` - 解释器代码片段
- `TemplateInterpreter` - 模板解释器（默认）
- `DispatchTable` - 字节码调度表（256 × 10 种栈顶状态）

**解释器代码组成**：
| 组件 | 功能 | 数量 |
|------|------|------|
| 方法入口点 | 不同类型方法的入口 | ~30 种 |
| 字节码模板 | 每个字节码的机器码 | 256 个 |
| 调度表 | 字节码→本地代码映射 | 3 个（normal/safept/active）|
| 异常处理点 | 异常分发 | 若干 |
| safepoint 检查点 | 安全点检查 | 若干 |

**GDB 验证结果（-Xms256m -Xmx256m）**：
```
=== Interpreter Code ===
code total space: 127 KB

=== Method Entry Points ===
zerolocals:      0x7fffed010c00
zerolocals_sync: 0x7fffed010ea0
native:          0x7fffed011a80
empty:           0x7fffed010c00  ← 与 zerolocals 共用入口
abstract:        0x7fffed0113a0

=== Dispatch Table (iadd=0x60) ===
entry[itos][iadd]: 0x7fffed018087

=== Disasm zerolocals entry (普通方法入口) ===
0x7fffed010c00:  mov    0x10(%rbx),%rdx  ; Method* → ConstMethod*
0x7fffed010c04:  movzwl 0x34(%rdx),%ecx  ; 获取 max_stack
0x7fffed010c08:  movzwl 0x32(%rdx),%edx  ; 获取 size_of_parameters
0x7fffed010c0c:  sub    %ecx,%edx        ; 计算局部变量数
0x7fffed010c0e:  cmp    $0x1f5,%edx      ; 检查栈大小限制 (501)
```

**已完成子节点** (详见 [interpreter_init_outline.md](Interpreter/interpreter_init_outline.md))：
- ✅ generate_normal_entry - 普通方法入口详细流程
- ✅ generate_fixed_frame - 栈帧创建
- ✅ 字节码模板生成 (TemplateTable::initialize) → [4.0-bytecode-templates.md](Interpreter/4.0-bytecode-templates.md)
- ✅ G1 屏障汇编实现 → [G1-Barrier-Assembly.md](Interpreter/G1-Barrier-Assembly.md)
- ✅ 方法调用类字节码 → [5.0-invoke-bytecodes.md](Interpreter/5.0-invoke-bytecodes.md)
- ✅ **invokedynamic** → [7.0-invokedynamic-deep-dive.md](Interpreter/7.0-invokedynamic-deep-dive.md) ⭐⭐Lambda 和现代 Java 特性的基础

**相关 JVM 参数**：
- `-Xint` - 仅解释执行
- `-XX:+PrintInterpreter` - 打印解释器代码

**已完成分析** ✅

---

### 3.3 invocationCounter_init() ✅ → [InvocationCounter/invocationCounter_init.md](InvocationCounter/invocationCounter_init.md)

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/interpreter/invocationCounter.cpp:169` |
| 依赖 | 无 |
| 被依赖 | 方法执行 |
| **详细文档** | **[InvocationCounter/invocationCounter_init.md](InvocationCounter/invocationCounter_init.md)** |
| **GDB 脚本** | **[InvocationCounter/gdb_invocationCounter_init.txt](InvocationCounter/gdb_invocationCounter_init.txt)** |

**主要功能**：初始化调用计数器（用于热点检测）

**调用的子函数**：
```cpp
void invocationCounter_init() {
    InvocationCounter::reinitialize(DelayCompilationDuringStartup);
}
```

**关键数据结构**：
- `InvocationCounter` - 调用计数器（32位：[29位计数][1位carry][2位状态]）
- `MethodCounters` - 每方法的计数器存储结构
- `InvocationCounter::State` - 计数器状态（wait_for_nothing / wait_for_compile）

**GDB 验证结果**（-Xms256m -Xmx256m）：
```
=== Computed Limits ===
CompileThreshold: 10000
InterpreterInvocationLimit: 80000 (raw) / 10000 (actual)
InterpreterProfileLimit: 26400 (raw) / 3300 (actual)
InterpreterBackwardBranchLimit: 112000
```

**计数器阈值**：
| 阈值 | 计算公式 | 默认值 | 用途 |
|------|----------|--------|------|
| InterpreterInvocationLimit | CompileThreshold << 3 | 80000 | 触发 JIT 编译 |
| InterpreterProfileLimit | CompileThreshold * 33% << 3 | 26400 | 开始收集 profile |
| InterpreterBackwardBranchLimit | (CompileThreshold * 140%) << 3 | 112000 | 触发 OSR 编译 |

**已分析内容**：
- ✅ 计数器状态机 (wait_for_nothing, wait_for_compile)
- ✅ 衰减机制 (decay)
- ✅ 分层编译计数器
- ✅ 解释器中的计数器增加逻辑

**相关 JVM 参数**：
- `-XX:CompileThreshold=N` - 编译阈值（默认 10000）
- `-XX:OnStackReplacePercentage=N` - OSR 百分比（默认 140）
- `-XX:InterpreterProfilePercentage=N` - profiling 百分比（默认 33）

**已完成分析** ✅

---

### 3.4 accessFlags_init() ⬜

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/utilities/accessFlags.cpp:74` |
| 依赖 | 无 |
| 被依赖 | 无 |

**主要功能**：验证访问标志大小（简单检查）

**调用的子函数**：
```cpp
void accessFlags_init() {
    assert(sizeof(AccessFlags) == sizeof(jint), "just checking size of flags");
}
```

**AccessFlags 位布局**（32位）：
| 位范围 | 用途 |
|--------|------|
| 0-15 | JVM 规范定义的标志 (ACC_PUBLIC, ACC_FINAL...) |
| 16-31 | HotSpot 内部标志 |

---

### 3.5 templateTable_init() ✅ → [TemplateTable/templateTable_init.md](TemplateTable/templateTable_init.md)

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/interpreter/templateTable.cpp:547` |
| 依赖 | interpreter_init |
| 被依赖 | 无 |
| **详细文档** | **[TemplateTable/templateTable_init.md](TemplateTable/templateTable_init.md)** |
| **GDB 脚本** | **[TemplateTable/gdb_templateTable_init.txt](TemplateTable/gdb_templateTable_init.txt)** |

**主要功能**：初始化字节码模板表（字节码→机器码模板的映射）

**调用的子函数**：
```cpp
void templateTable_init() {
    TemplateTable::initialize();
}
```

**关键数据结构**：
- `TemplateTable` - 模板表（256 个普通 + 256 个 wide 模板）
- `Template` - 单个字节码模板（32 bytes）
- `InterpreterMacroAssembler` - 解释器汇编器

**GDB 验证结果**（-Xms256m -Xmx256m）：
```
=== Sample Templates ===
nop (0x00): flags=0, tos_in=vtos(9), tos_out=vtos(9)
iadd (0x60): flags=0, tos_in=itos(4), tos_out=itos(4)
invokevirtual (0xb6): flags=7 (ubcp|disp|clvm), tos_in=vtos, tos_out=vtos
new (0xbb): flags=5 (ubcp|clvm), tos_in=vtos, tos_out=atos
```

**模板表结构**：
```cpp
class Template {
    int       _flags;     // 标志位 (ubcp|disp|clvm|iswd)
    TosState  _tos_in;    // 输入栈顶状态
    TosState  _tos_out;   // 输出栈顶状态
    generator _gen;       // 代码生成函数指针
    int       _arg;       // 生成器参数
};
```

**TosState（栈顶状态）**：
| 状态 | 值 | 含义 |
|------|-----|------|
| vtos | 9 | void (空) |
| atos | 8 | 对象引用 |
| itos | 4 | int |
| ltos | 5 | long |
| ftos | 6 | float |
| dtos | 7 | double |

**已分析内容**：
- ✅ 标准字节码模板定义（256 个）
- ✅ 快速字节码模板（~30 个）
- ✅ TosState 转换规则
- ✅ Wide 字节码模板
- ✅ 典型字节码详解（iadd, invokevirtual, new）

**已完成分析** ✅

---

### 3.6 InterfaceSupport_init() ⬜

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/runtime/interfaceSupport.cpp:264` |
| 依赖 | 无 |
| 被依赖 | 无 |

**主要功能**：初始化接口支持（主要用于调试）

**调用的子函数**：
```cpp
void InterfaceSupport_init() {
#ifdef ASSERT
    if (ScavengeALot || FullGCALot) {
        srand(ScavengeALotInterval * FullGCALotInterval);
    }
#endif
}
```

**相关 JVM 参数**（调试用）：
- `-XX:+ScavengeALot` - 频繁 GC（调试）
- `-XX:+FullGCALot` - 频繁 Full GC（调试）

---

### 3.7 VMRegImpl::set_regName() ⬜

| 属性 | 值 |
|------|-----|
| 源码位置 | 平台相关 `src/hotspot/cpu/x86/vmreg_x86.cpp` |
| 依赖 | 无 |
| 被依赖 | SharedRuntime::generate_stubs |

**主要功能**：设置寄存器名称（用于调试输出 OopMap）

---

### 3.8 SharedRuntime::generate_stubs() ✅ ⭐重要 → [SharedRuntime/SharedRuntime_generate_stubs.md](SharedRuntime/SharedRuntime_generate_stubs.md)

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/runtime/sharedRuntime.cpp:100` |
| 依赖 | VMRegImpl::set_regName |
| 被依赖 | universe2_init |
| **详细文档** | **[SharedRuntime/SharedRuntime_generate_stubs.md](SharedRuntime/SharedRuntime_generate_stubs.md)** |
| **GDB 脚本** | **[SharedRuntime/gdb_SharedRuntime_generate_stubs.txt](SharedRuntime/gdb_SharedRuntime_generate_stubs.txt)** |

**主要功能**：生成方法调用解析、内联缓存、反优化和安全点处理的核心运行时桩代码

**调用的子函数**：
```cpp
void SharedRuntime::generate_stubs() {
    // 第一组：方法调用解析桩
    _wrong_method_blob = generate_resolve_blob(..., "wrong_method_stub");
    _wrong_method_abstract_blob = generate_resolve_blob(..., "wrong_method_abstract_stub");
    _ic_miss_blob = generate_resolve_blob(..., "ic_miss_stub");
    _resolve_opt_virtual_call_blob = generate_resolve_blob(..., "resolve_opt_virtual_call");
    _resolve_virtual_call_blob = generate_resolve_blob(..., "resolve_virtual_call");
    _resolve_static_call_blob = generate_resolve_blob(..., "resolve_static_call");
    
    // 第二组：安全点处理桩
    _polling_page_safepoint_handler_blob = generate_handler_blob(..., POLL_AT_LOOP);
    _polling_page_return_handler_blob = generate_handler_blob(..., POLL_AT_RETURN);
    
    // 第三组：反优化桩
    generate_deopt_blob();
    
#ifdef COMPILER2
    generate_uncommon_trap_blob();
#endif
}
```

**生成的桩代码**：
| 桩代码类型 | 数量 | 存储类型 | 作用 |
|------------|------|----------|------|
| 方法解析桩 | 6 | RuntimeStub | 首次调用方法时解析目标 |
| 安全点桩 | 2-3 | SafepointBlob | 响应 GC、偏向锁等 VM 操作 |
| 反优化桩 | 1 | DeoptimizationBlob | 从编译代码回退到解释器 |
| 不常见陷阱桩 | 1 | UncommonTrapBlob | C2 推测性优化失败处理 |

**GDB 验证结果（-Xms256m -Xmx256m）**：
```
=== Method Resolution Stubs ===
_wrong_method_blob         = 0x7fffed008190
_ic_miss_blob              = 0x7fffed114090
_resolve_static_call_blob  = 0x7fffed113790
_resolve_virtual_call_blob = 0x7fffed113a90

=== Safepoint Handler Blobs ===
_polling_page_safepoint_handler_blob = 0x7fffed112a90
_polling_page_return_handler_blob    = 0x7fffed112790

=== Deopt Blob ===
_deopt_blob = 0x7fffed113090

=== Disasm resolve_static_call entry (RegisterSaver::save_live_registers) ===
0x7fffed113820:  push   %rbp              ; 保存帧指针
0x7fffed113821:  mov    %rsp,%rbp         ; 建立新帧
0x7fffed113824:  pushf                    ; 保存标志寄存器
0x7fffed11382e:  sub    $0x80,%rsp        ; 分配 128 字节保存寄存器
0x7fffed113835:  mov    %rax,0x78(%rsp)   ; 开始保存寄存器
```

**相关 JVM 参数**：
- `-XX:+TraceDeoptimization` - 跟踪反优化
- `-XX:+PrintDeoptimizationDetails` - 打印反优化详情

**已完成分析** ✅

---

## Phase 4: 类系统初始化

### 4.1 universe2_init() ✅ ⭐⭐核心 → [universe2_init.md](./Universe/universe2_init.md)

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/memory/universe.cpp:1200` |
| 依赖 | codeCache_init, stubRoutines_init1 |
| 被依赖 | javaClasses_init |
| **详细文档** | **[Universe/universe2_init.md](./Universe/universe2_init.md)** |
| **GDB 脚本** | **[Universe/gdb_universe2_init.txt](./Universe/gdb_universe2_init.txt)** |

**主要功能**：调用 `Universe::genesis()` 加载原始类（"创世纪"）

**调用的子函数**：
```cpp
void universe2_init() {
    EXCEPTION_MARK;
    Universe::genesis(CATCH);
}
```

**Universe::genesis() 执行内容**：
```cpp
void Universe::genesis(TRAPS) {
    // 1. 创建基本类型数组 Klass (8个)
    _boolArrayKlassObj = TypeArrayKlass::create_klass(T_BOOLEAN, ...);
    _charArrayKlassObj = TypeArrayKlass::create_klass(T_CHAR, ...);
    // ... int, long, short, byte, float, double
    
    // 2. 初始化 vmSymbols
    vmSymbols::initialize(CHECK);
    
    // 3. 初始化 SystemDictionary (加载核心类)
    SystemDictionary::initialize(CHECK);
    
    // 4. 创建 "null" 和 "-2147483648" 字符串
    _the_null_string = StringTable::intern("null", CHECK);
    _the_min_jint_string = StringTable::intern("-2147483648", CHECK);
    
    // 5. 设置数组接口 (Cloneable, Serializable)
    _the_array_interfaces_array->at_put(0, Cloneable_klass());
    _the_array_interfaces_array->at_put(1, Serializable_klass());
    
    // 6. 初始化基本类型 Klass 的继承关系 (super = Object)
    initialize_basic_type_klass(boolArrayKlassObj(), CHECK);
    // ...
    
    // 7. 创建 objectArrayKlass
    _objectArrayKlassObj = Object_klass()->array_klass(1, CHECK);
}
```

**创建的数据结构**：
| 数据结构 | 说明 |
|----------|------|
| TypeArrayKlass (8个) | boolean[], char[], float[], double[], byte[], short[], int[], long[] |
| vmSymbols | 预定义符号表 (~500 个符号) |
| SystemDictionary | 系统类字典 (Object, Class, Cloneable, Serializable...) |
| objectArrayKlass | Object[] Klass |
| 特殊字符串 | "null", "-2147483648", "<null_sentinel>" |

**GDB 验证结果（-Xms256m -Xmx256m）**：
```
=== TypeArrayKlass (8个) ===
_boolArrayKlassObj   = 0x100000040     ← boolean[] Klass
_charArrayKlassObj   = 0x100000240     ← char[] Klass
_intArrayKlassObj    = 0x100000c40     ← int[] Klass
_longArrayKlassObj   = 0x100000e40     ← long[] Klass

=== objectArrayKlass ===
_objectArrayKlassObj = 0x100013778     ← Object[] Klass

=== Special Strings ===
_the_null_string     = 0xfff049e0      ← "null"
_the_min_jint_string = 0xfff04a10      ← "-2147483648"

=== Bootstrap Status ===
Universe::_bootstrapping = false       ← genesis() 已完成
```

**已完成分析** ✅

---

### 4.2 javaClasses_init() ✅ ⭐重要 → [javaClasses_init.md](./Universe/javaClasses_init.md)

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/classfile/javaClasses.cpp:4598` |
| 依赖 | universe2_init (vtable 必须已初始化) |
| 被依赖 | referenceProcessor_init |
| **详细文档** | **[Universe/javaClasses_init.md](./Universe/javaClasses_init.md)** |
| **GDB 脚本** | **[Universe/gdb_javaClasses_init.txt](./Universe/gdb_javaClasses_init.txt)** |

**主要功能**：计算 Java 核心类的字段偏移量

**调用的子函数**：
```cpp
void javaClasses_init() {
    JavaClasses::compute_offsets();  // 计算 PART2 的 28 个类偏移量
    JavaClasses::check_offsets();    // 验证硬编码偏移量（仅 DEBUG）
    FilteredFieldsMap::initialize(); // 初始化过滤字段映射（反射用）
}
```

**计算偏移量的核心类（PART2）**：
| 分类 | 类 | 关键字段 |
|------|-----|----------|
| 线程 | java.lang.Thread | eetop, tid, threadStatus, name, priority |
| 类加载 | java.lang.ClassLoader | parent, loaderData |
| 异常 | java.lang.Throwable | backtrace, detailMessage, cause |
| 方法句柄 | java.lang.invoke.MethodHandle | type, form |
| | java.lang.invoke.MemberName | clazz, name, type, flags, method |
| 反射 | java.lang.reflect.Method | clazz, slot, override |
| | java.lang.reflect.Field | clazz, slot, type |
| 引用 | java.lang.ref.SoftReference | 软引用时间戳 |
| NIO | java.nio.Buffer | address, capacity, limit |

**GDB 验证结果（-Xms256m -Xmx256m）**：
| 字段 | 偏移量 |
|------|--------|
| Thread._eetop_offset | 16 |
| Thread._tid_offset | 32 |
| Thread._name_offset | 48 |
| String.value_offset | 12 |
| MethodHandle._type_offset | 16 |
| MemberName._flags_offset | 12 |

**已完成分析** ✅

---

## Phase 5: 引用处理与 JNI

### 5.1 referenceProcessor_init() ✅ → [ReferenceProcessor/referenceProcessor_init.md](ReferenceProcessor/referenceProcessor_init.md)

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/gc/shared/referenceProcessor.cpp:46` |
| 依赖 | javaClasses_init |
| 被依赖 | GC |
| **详细文档** | **[ReferenceProcessor/referenceProcessor_init.md](ReferenceProcessor/referenceProcessor_init.md)** |
| **GDB 脚本** | **[ReferenceProcessor/gdb_referenceProcessor_init.txt](ReferenceProcessor/gdb_referenceProcessor_init.txt)** |

**主要功能**：初始化引用处理器（处理软/弱/虚引用和 Finalizer）

**调用的子函数**：
```cpp
void referenceProcessor_init() {
    ReferenceProcessor::init_statics();
}

void ReferenceProcessor::init_statics() {
    _soft_ref_timestamp_clock = os::javaTimeNanos() / NANOSECS_PER_MILLISEC;
    java_lang_ref_SoftReference::set_clock(_soft_ref_timestamp_clock);
    
    _always_clear_soft_ref_policy = new AlwaysClearPolicy();  // OOM 时使用
    _default_soft_ref_policy = new LRUMaxHeapPolicy();        // Server 模式
}
```

**GDB 验证结果**（-Xms256m -Xmx256m -XX:+UseG1GC）：
```
=== Soft Ref Timestamp Clock ===
_soft_ref_timestamp_clock: 308659272 ms    ← 当前时间戳 ✅

=== Reference Policies ===
_always_clear_soft_ref_policy: 0x7ffff02025a0    ← AlwaysClearPolicy ✅
_default_soft_ref_policy: 0x7ffff02025e0         ← LRUMaxHeapPolicy ✅

=== JVM Parameters ===
SoftRefLRUPolicyMSPerMB: 1000                    ← 默认值 ✅
```

**四种引用类型（面试高频）**：
| 引用类型 | 清理时机 | get() 返回 | 典型场景 |
|---------|---------|-----------|---------|
| 强引用 | 永不 | 对象 | 普通变量 |
| 软引用 | 内存不足时 | 对象 | 缓存 |
| 弱引用 | 下次 GC | 对象 | WeakHashMap |
| 虚引用 | 对象回收后 | null | 资源清理通知 |

**软引用清理策略**：
```
max_interval = (MaxHeapSize - used) / M × SoftRefLRUPolicyMSPerMB
如果 (当前时间 - 上次访问时间) > max_interval → 清理
```

**GC 引用处理四阶段**：
```
Phase 1: process_soft_ref_reconsider()  → 软引用策略筛选
Phase 2: process_soft_weak_final_refs() → 处理 Soft/Weak/Final
Phase 3: process_final_keep_alive()     → Final 保持存活（支持 finalize()）
Phase 4: process_phantom_refs()         → 处理 Phantom
```

**已分析内容**：
- ✅ 四种引用类型和强度对比
- ✅ 软引用 LRU 清理策略详解
- ✅ GC 引用处理四阶段流程
- ✅ FinalReference 与 finalize() 机制
- ✅ PhantomReference 与 Cleaner 机制
- ✅ Pending 队列与 ReferenceHandler 线程
- ✅ 面试高频问题总结

**已完成分析** ✅

---

### 5.2 jni_handles_init() ✅ → [JNIHandles/jni_handles_init.md](JNIHandles/jni_handles_init.md)

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/runtime/jniHandles.cpp:341` |
| 依赖 | 无 |
| 被依赖 | JNI 代码 |
| **详细文档** | **[JNIHandles/jni_handles_init.md](JNIHandles/jni_handles_init.md)** |
| **GDB 脚本** | **[JNIHandles/gdb_jni_handles_init.txt](JNIHandles/gdb_jni_handles_init.txt)** |

**主要功能**：初始化 JNI 句柄（本地代码持有 Java 对象）

**调用的子函数**：
```cpp
void jni_handles_init() {
    JNIHandles::initialize();
}

void JNIHandles::initialize() {
    _global_handles = new OopStorage("JNI Global", ...);
    _weak_global_handles = new OopStorage("JNI Weak", ...);
}
```

**GDB 验证结果**（-Xms256m -Xmx256m -XX:+UseG1GC）：
```
=== JNI Global Handles ===
_global_handles: 0x7ffff02025c0         ← 全局引用存储 ✅
_weak_global_handles: 0x7ffff0202770    ← 弱全局引用存储 ✅

=== JNIHandleBlock Stats ===
_blocks_allocated: 4                     ← 已分配 4 个块 ✅
_block_free_list: (nil)                  ← 空闲列表为空 ✅
```

**JNI 句柄类型（面试高频）**：
| 类型 | 存储位置 | 生命周期 | GC 行为 |
|------|----------|----------|---------|
| Local Reference | JNIHandleBlock | 方法返回自动释放 | 阻止回收 |
| Global Reference | OopStorage | 手动释放 | 阻止回收 |
| Weak Global Reference | OopStorage | 手动释放 | 不阻止回收 |

**JNIHandleBlock 内存布局**：
```
Thread->active_handles ──→ JNIHandleBlock
                            ├── _handles[0..31]  ← 32 槽位数组
                            ├── _top = 下一个空闲位置
                            └── _next ──→ 扩展块
```

**已分析内容**：
- ✅ 三种 JNI Handle 类型详解
- ✅ Local Handle 两级缓存机制
- ✅ Global Handle OopStorage 存储
- ✅ Weak Global Handle 低位标记机制
- ✅ GC 集成（Root 扫描）
- ✅ PushLocalFrame/PopLocalFrame
- ✅ 内存泄漏诊断

**已完成分析** ✅

---

## Phase 6: 调试与诊断

### 6.1 vmStructs_init() ⬜

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/runtime/vmStructs.cpp:3207` |
| 依赖 | 无 |
| 被依赖 | SA (Serviceability Agent) |

**主要功能**：初始化 VM 结构信息（供调试工具使用）

**调用的子函数**：
```cpp
void vmStructs_init() {
    debug_only(VMStructs::init());
}
```

**用途**：
- Serviceability Agent (SA) 使用
- jmap/jstack/jinfo 等工具
- 调试器 (gdb) 集成

---

## Phase 7: 方法调用支持

### 7.1 vtableStubs_init() ✅ → [VtableStubs/vtableStubs_init.md](VtableStubs/vtableStubs_init.md)

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/code/vtableStubs.cpp:296` |
| 依赖 | 无 |
| 被依赖 | 虚方法调用 |
| **详细文档** | **[VtableStubs/vtableStubs_init.md](VtableStubs/vtableStubs_init.md)** |
| **GDB 脚本** | **[VtableStubs/gdb_vtableStubs_init.txt](VtableStubs/gdb_vtableStubs_init.txt)** |

**主要功能**：初始化虚表桩代码（VtableStubs）管理器

**调用的子函数**：
```cpp
void vtableStubs_init() {
    VtableStubs::initialize();
}
```

**关键数据结构**：
- `VtableStub` - 虚表桩代码（头部 24B + 机器代码）
- `VtableStubs::_table[256]` - 哈希表缓存所有桩代码
- `_receiver_location` - 接收者寄存器位置

**GDB 验证结果**（-Xms256m -Xmx256m）：
```
=== VtableStubs Basic Info ===
_number_of_vtable_stubs: 0    ← 懒加载，初始为 0
_vtab_stub_size: 0
_itab_stub_size: 0
_receiver_location: 0xc       ← VMReg 编码（rdi 寄存器）

=== Hash Table ===
_table[0..255]: all NULL      ← 初始状态
```

**虚表调用流程**：
```
invokevirtual → IC miss → VtableStubs::find_vtable_stub(index)
                              │
                              ├── lookup(hash) → 找到 → 返回 entry_point
                              │
                              └── create_vtable_stub(index)
                                    │
                                    └── load_klass → lookup_virtual_method → jmp
```

**已分析内容**：
- ✅ VtableStubs 哈希表结构
- ✅ VtableStub 对象布局
- ✅ x86_64 vtable stub 汇编代码生成
- ✅ x86_64 itable stub 汇编代码生成
- ✅ 异常处理（NPE/AME）
- ✅ 内存管理（Chunk 分配）

**已完成分析** ✅

---

### 7.2 InlineCacheBuffer_init() ✅ → [InlineCacheBuffer/InlineCacheBuffer_init.md](InlineCacheBuffer/InlineCacheBuffer_init.md)

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/code/icBuffer.cpp:167` |
| 依赖 | 无 |
| 被依赖 | 内联缓存更新 |
| **详细文档** | **[InlineCacheBuffer/InlineCacheBuffer_init.md](InlineCacheBuffer/InlineCacheBuffer_init.md)** |
| **GDB 脚本** | **[InlineCacheBuffer/gdb_InlineCacheBuffer_init.txt](InlineCacheBuffer/gdb_InlineCacheBuffer_init.txt)** |

**主要功能**：初始化内联缓存缓冲区，用于 IC 状态转换时的过渡桩存储

**调用的子函数**：
```cpp
void InlineCacheBuffer_init() {
    InlineCacheBuffer::initialize();
}

void InlineCacheBuffer::initialize() {
    _buffer = new StubQueue(new ICStubInterface, 10*K, InlineCacheBuffer_lock, "InlineCacheBuffer");
    init_next_stub();  // 初始化哨兵桩
}
```

**GDB 验证结果**（-Xms256m -Xmx256m）：
```
=== StubQueue Info ===
_buffer_limit: 10240 bytes    ← 10KB 缓冲区
_number_of_stubs: 1           ← 哨兵桩

=== ICStub Info ===
_next_stub->_size: 64 bytes   ← 单个桩大小
_next_stub->_ic_site: (nil)   ← 空桩（哨兵）
```

**内联缓存 (IC) 状态转换**：
```
Clean (null) ←→ Monomorphic (Klass*) ←→ Megamorphic (CompiledICHolder*)
                     │                        │
                     └──→ Interpreted ←──────┘
```

**已分析内容**：
- ✅ StubQueue 缓冲区结构
- ✅ ICStub 过渡桩机制
- ✅ IC 状态转换流程
- ✅ x86_64 汇编代码生成
- ✅ 延迟释放 CompiledICHolder

**已完成分析** ✅

---

## Phase 8: JIT 编译器初始化

### 8.1 compilerOracle_init() ⬜

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/compiler/compilerOracle.cpp:767` |
| 依赖 | 无 |
| 被依赖 | compileBroker_init |

**主要功能**：解析编译器命令/指令

**调用的子函数**：
```cpp
void compilerOracle_init() {
    CompilerOracle::parse_from_string(CompileCommand, ...);
    CompilerOracle::parse_from_string(CompileOnly, ...);
    if (CompilerOracle::has_command_file()) {
        CompilerOracle::parse_from_file();
    }
}
```

**编译器命令示例**：
```
-XX:CompileCommand=exclude,java/lang/String.hashCode
-XX:CompileCommand=print,*::*
-XX:CompileCommand=inline,java/lang/Math.*
-XX:CompileOnly=java/lang/String.*
```

**支持的命令**：
| 命令 | 功能 |
|------|------|
| exclude | 排除编译 |
| compileonly | 仅编译指定方法 |
| inline | 强制内联 |
| dontinline | 禁止内联 |
| print | 打印编译信息 |
| log | 记录日志 |
| break | 设置断点 |

---

### 8.2 dependencyContext_init() ⬜

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/code/dependencyContext.cpp:39` |
| 依赖 | 无 |
| 被依赖 | compileBroker_init |

**主要功能**：初始化依赖上下文（跟踪编译代码的依赖关系）

**调用的子函数**：
```cpp
void dependencyContext_init() {
    DependencyContext::init();
}

void DependencyContext::init() {
    if (UsePerfData) {
        _perf_total_buckets_allocated_count = PerfDataManager::create_counter(...);
        _perf_total_buckets_deallocated_count = PerfDataManager::create_counter(...);
    }
}
```

**依赖类型**：
| 依赖类型 | 含义 |
|----------|------|
| evol_method | 方法可能被重定义 |
| leaf_type | 类没有子类 |
| abstract_with_unique_concrete_subtype | 抽象类只有一个具体实现 |
| unique_concrete_method | 唯一的具体方法实现 |

---

### 8.3 compileBroker_init() ✅ ⭐重要 → [CompileBroker/compileBroker_init.md](CompileBroker/compileBroker_init.md)

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/compiler/compileBroker.cpp:261` |
| 依赖 | compilerOracle_init, dependencyContext_init |
| 被依赖 | universe_post_init |
| **详细文档** | **[CompileBroker/compileBroker_init.md](CompileBroker/compileBroker_init.md)** |
| **GDB 脚本** | **[CompileBroker/gdb_compileBroker_init.txt](CompileBroker/gdb_compileBroker_init.txt)** |

**主要功能**：初始化编译代理（管理 JIT 编译）

**调用的子函数**：
```cpp
bool compileBroker_init() {
    if (LogEvents) {
        _compilation_log = new CompilationLog();
    }
    DirectivesStack::init();  // 初始化编译指令栈
    if (DirectivesParser::has_file()) {
        return DirectivesParser::parse_from_flag();
    }
    return true;
}
```

**关键数据结构**：
- `CompileBroker` - 编译代理
- `CompileQueue` - 编译队列
- `CompileTask` - 编译任务
- `CompilerThread` - 编译线程

**GDB 验证结果（-Xms8g -Xmx8g）**：
| 属性 | 值 |
|------|-----|
| _initialized | true |
| _compilers[0] (C1) | 0x7ffff0dbda40 |
| _compilers[1] (C2) | 0x7ffff0ddbe60 |
| _c1_count | 4 |
| _c2_count | 8 |
| DirectivesStack::_depth | 1 (默认指令) |
| TieredCompilation | true |

**编译线程配置**：
| 参数 | GDB 验证值 | 含义 |
|------|------------|------|
| CICompilerCount | 12 | 编译线程总数 |
| C1 threads max | 4 | C1 编译线程最大数 |
| C2 threads max | 8 | C2 编译线程最大数 |
| UseDynamicNumberOfCompilerThreads | true | 动态调整线程数 |

**相关 JVM 参数**：
- `-XX:CICompilerCount=N` - 编译线程数
- `-XX:+BackgroundCompilation` - 后台编译
- `-XX:CompileThreshold=N` - 编译阈值
- `-XX:+TieredCompilation` - 分层编译
- `-XX:TieredStopAtLevel=N` - 最高编译级别

**已完成分析** ✅

---

## Phase 9: 后初始化

### 9.1 universe_post_init() ✅ ⭐重要 → [universe_post_init.md](./Universe/universe_post_init.md)

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/memory/universe.cpp:1210` |
| 依赖 | compileBroker_init |
| 被依赖 | stubRoutines_init2 |

**主要功能**：
1. 预分配异常对象
2. 初始化 LatestMethodCache
3. 堆后初始化

**调用的子函数**：
```cpp
bool universe_post_init() {
    Universe::_fully_initialized = true;
    
    // 1. 初始化解释器入口点
    Interpreter::initialize();
    
    // 2. 重新初始化 vtable
    if (!UseSharedSpaces) {
        Universe::reinitialize_vtable_of(SystemDictionary::Object_klass(), CHECK_false);
        Universe::reinitialize_itables(CHECK_false);
    }
    
    // 3. 预分配空 Class 数组
    _the_empty_class_klass_array = oopFactory::new_objArray(Class_klass(), 0, CHECK_false);
    
    // 4. 预分配 OutOfMemoryError (6 个)
    _out_of_memory_error_java_heap = ik->allocate_instance(CHECK_false);
    _out_of_memory_error_metaspace = ik->allocate_instance(CHECK_false);
    _out_of_memory_error_class_metaspace = ik->allocate_instance(CHECK_false);
    _out_of_memory_error_array_size = ik->allocate_instance(CHECK_false);
    _out_of_memory_error_gc_overhead_limit = ik->allocate_instance(CHECK_false);
    _out_of_memory_error_realloc_objects = ik->allocate_instance(CHECK_false);
    
    // 5. 预分配 NullPointerException
    _null_ptr_exception_instance = ...;
    
    // 6. 预分配 ArithmeticException
    _arithmetic_exception_instance = ...;
    
    // 7. 预分配 VirtualMachineError
    _virtual_machine_error_instance = ...;
    
    // 8. 预分配带 backtrace 的 OOM 数组
    _preallocated_out_of_memory_error_array = ...;
    
    // 9. 初始化 LatestMethodCache (6 个)
    Universe::initialize_known_methods(CHECK_false);
    
    // 10. 更新堆信息
    Universe::update_heap_info_at_gc();
    
    // 11. 堆后初始化
    Universe::heap()->post_initialize();
    
    // 12. 添加 Metaspace 内存池
    MemoryService::add_metaspace_memory_pools();
    
    return true;
}
```

**预分配的异常对象**：
| 异常类型 | 变量名 | 消息 |
|----------|--------|------|
| OutOfMemoryError | _out_of_memory_error_java_heap | "Java heap space" |
| OutOfMemoryError | _out_of_memory_error_metaspace | "Metaspace" |
| OutOfMemoryError | _out_of_memory_error_class_metaspace | "Compressed class space" |
| OutOfMemoryError | _out_of_memory_error_array_size | "Requested array size exceeds VM limit" |
| OutOfMemoryError | _out_of_memory_error_gc_overhead_limit | "GC overhead limit exceeded" |
| OutOfMemoryError | _out_of_memory_error_realloc_objects | "Java heap space: failed reallocation..." |
| NullPointerException | _null_ptr_exception_instance | 无 |
| ArithmeticException | _arithmetic_exception_instance | "/ by zero" |
| VirtualMachineError | _virtual_machine_error_instance | 无 |

**LatestMethodCache（6 个）**：
| 缓存名称 | 方法 |
|----------|------|
| _finalizer_register_cache | Finalizer.register(Object) |
| _loader_addClass_cache | ClassLoader.addClass(Class) |
| _throw_illegal_access_error_cache | Unsafe.throwIllegalAccessError() |
| _throw_no_such_method_error_cache | Unsafe.throwNoSuchMethodError() |
| _do_stack_walk_cache | StackWalker.doStackWalk() |
| _is_substitutable_cache | ValueBootstrapMethods.isSubstitutable() |

**待分析子节点**：
- [ ] 预分配异常的使用场景
- [ ] heap()->post_initialize() 内容
- [ ] MemoryService 内存池

---

### 9.2 stubRoutines_init2() ✅ ⭐重要 → [StubRoutines/stubRoutines_init2.md](StubRoutines/stubRoutines_init2.md)

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/runtime/stubRoutines.cpp:411` |
| 依赖 | universe_post_init |
| 被依赖 | MethodHandles::generate_adapters |
| **详细文档** | **[StubRoutines/stubRoutines_init2.md](StubRoutines/stubRoutines_init2.md)** |
| **GDB 脚本** | **[StubRoutines/gdb_stubRoutines_init2.txt](StubRoutines/gdb_stubRoutines_init2.txt)** |

**主要功能**：生成第二批桩代码（数组拷贝、加密等高级桩）

**调用的子函数**：
```cpp
void stubRoutines_init2() {
    StubRoutines::initialize2();
}

void StubRoutines::initialize2() {
    _code2 = BufferBlob::create("StubRoutines (2)", code_size2);
    CodeBuffer buffer(_code2);
    StubGenerator_generate(&buffer, true);
}
```

**生成的桩代码（第二阶段）**：
| 桩代码 | 功能 | GDB 验证地址 |
|--------|------|--------------|
| jbyte_arraycopy | byte 数组拷贝 | 0x7fffed093800 |
| jshort_arraycopy | short 数组拷贝 | 0x7fffed093a20 |
| jint_arraycopy | int 数组拷贝 | 0x7fffed093c00 |
| jlong_arraycopy | long 数组拷贝 | 0x7fffed093dc0 |
| oop_arraycopy | 对象数组拷贝（带写屏障） | 0x7fffed094100 |
| checkcast_arraycopy | 带类型检查的数组拷贝 | 0x7fffed094740 |
| unsafe_arraycopy | Unsafe 数组拷贝 | 0x7fffed094d20 |
| generic_arraycopy | 通用数组拷贝 | 0x7fffed094d80 |
| aescrypt_encryptBlock | AES 加密（使用 AES-NI） | 0x7fffed095420 |
| aescrypt_decryptBlock | AES 解密 | 0x7fffed095540 |
| cipherBlockChaining_* | CBC 模式加解密 | 0x7fffed095660 |
| sha1_implCompress | SHA1 哈希 | 0x7fffed097300 |
| sha256_implCompress | SHA256 哈希 | 0x7fffed097840 |
| sha512_implCompress | SHA512 哈希 | 0x7fffed097f20 |
| multiplyToLen | BigInteger 乘法 | 0x7fffed09a0c0 |
| squareToLen | BigInteger 平方 | 0x7fffed09a300 |
| safefetch32/N | 安全内存读取 | 0x7fffed09a0aa |

**代码缓冲区大小**：
| 阶段 | BufferBlob 名称 | 大小 |
|------|-----------------|------|
| init1 | StubRoutines (1) | 30,144 bytes |
| init2 | StubRoutines (2) | 46,448 bytes |

**已完成分析** ✅

---

### 9.3 MethodHandles::generate_adapters() ✅ → [MethodHandles/MethodHandles_generate_adapters.md](MethodHandles/MethodHandles_generate_adapters.md)

| 属性 | 值 |
|------|-----|
| 源码位置 | `src/hotspot/share/prims/methodHandles.cpp:75` |
| 依赖 | stubRoutines_init2 |
| 被依赖 | 无（最后一步） |
| **详细文档** | **[MethodHandles/MethodHandles_generate_adapters.md](MethodHandles/MethodHandles_generate_adapters.md)** |
| **GDB 脚本** | **[MethodHandles/gdb_MethodHandles_generate_adapters.txt](MethodHandles/gdb_MethodHandles_generate_adapters.txt)** |

**主要功能**：生成 MethodHandle 适配器代码（Lambda/invokedynamic 底层）

**调用的子函数**：
```cpp
void MethodHandles::generate_adapters() {
    _adapter_code = MethodHandlesAdapterBlob::create(adapter_code_size);
    CodeBuffer code(_adapter_code);
    MethodHandlesAdapterGenerator g(&code);
    g.generate();  // 为 6 种签名多态方法生成入口
}
```

**GDB 验证结果**（-Xms256m -Xmx256m -XX:+UseG1GC）：
```
=== MethodHandles Adapter Info ===
_adapter_code: 0x7fffe1065e90    ← MethodHandlesAdapterBlob 已创建 ✅
_enabled: 0                      ← 尚未启用（需要 Java 代码完成链接）✅
```

**6 种签名多态方法**：
| 方法 | 用途 | 调用方式 |
|------|------|----------|
| `invokeGeneric` | 用户级 invoke() | 通过 Java 适配 |
| `invokeBasic` | 内部调用 | jump_to_lambda_form() |
| `linkToVirtual` | 虚方法 | vtable 查找 |
| `linkToStatic` | 静态方法 | 直接调用 |
| `linkToSpecial` | private/super | 直接调用 |
| `linkToInterface` | 接口方法 | itable 查找 |

**调用链图解**：
```
mh.invoke(args)
    ↓
解释器入口（generate_adapters 生成）
    ↓
invokeBasic: MH → form → vmentry → method → Method*
linkTo*:     receiver + MemberName → vtable/itable → Method*
    ↓
目标方法
```

**与 Lambda 的关系**：
```
Lambda 表达式 → invokedynamic
    ↓
LambdaMetafactory.metafactory()
    ↓
生成 Lambda 类 + CallSite + MethodHandle
    ↓
后续调用通过 generate_adapters() 生成的入口
```

**已分析内容**：
- ✅ MethodHandle 架构和 LambdaForm
- ✅ 6 种签名多态方法详解
- ✅ x86_64 汇编代码生成
- ✅ jump_to_lambda_form() 实现
- ✅ 与 Lambda 表达式的关系
- ✅ 与 invokedynamic 的关系
- ✅ MemberName 结构详解
- ✅ 面试高频问题

**已完成分析** ✅

---

## 依赖关系图

```
                    ┌─────────────────┐
                    │ management_init │
                    └────────┬────────┘
                             ↓
                    ┌─────────────────┐
                    │ bytecodes_init  │
                    └────────┬────────┘
                             ↓
                    ┌──────────────────┐
                    │ classLoader_init1│
                    └────────┬─────────┘
                             ↓
                    ┌───────────────────────┐
                    │ compilationPolicy_init│
                    └────────┬──────────────┘
                             ↓
                    ┌─────────────────┐
                    │ codeCache_init  │ ←────┐
                    └────────┬────────┘      │
                             ↓               │
                    ┌─────────────────┐      │
                    │ VM_Version_init │      │
                    └────────┬────────┘      │
                             ↓               │
                    ┌──────────────────┐     │
                    │stubRoutines_init1│ ←───┤
                    └────────┬─────────┘     │
                             ↓               │
              ┌──────────────────────────────┤
              │        universe_init ✅       │
              └──────────────┬───────────────┘
                             ↓
              ┌──────────────────────────────┐
              │     gc_barrier_stubs_init    │
              └──────────────┬───────────────┘
                             ↓
              ┌──────────────────────────────┐
              │       interpreter_init       │
              └──────────────┬───────────────┘
                             ↓
    ┌────────────────────────┼────────────────────────┐
    ↓                        ↓                        ↓
┌──────────────┐   ┌─────────────────┐   ┌────────────────┐
│invocationCtr │   │ accessFlags_init│   │templateTbl_init│
└──────────────┘   └─────────────────┘   └────────────────┘
                             ↓
              ┌──────────────────────────────┐
              │    InterfaceSupport_init     │
              └──────────────┬───────────────┘
                             ↓
              ┌──────────────────────────────┐
              │  VMRegImpl::set_regName()    │
              └──────────────┬───────────────┘
                             ↓
              ┌──────────────────────────────┐
              │SharedRuntime::generate_stubs │
              └──────────────┬───────────────┘
                             ↓
              ┌──────────────────────────────┐
              │       universe2_init         │ (genesis)
              └──────────────┬───────────────┘
                             ↓
              ┌──────────────────────────────┐
              │       javaClasses_init       │
              └──────────────┬───────────────┘
                             ↓
    ┌────────────────────────┼────────────────────────┐
    ↓                                                 ↓
┌──────────────────┐                       ┌─────────────────┐
│referenceProc_init│                       │ jni_handles_init│
└──────────────────┘                       └─────────────────┘
                             ↓
              ┌──────────────────────────────┐
              │       vmStructs_init         │
              └──────────────┬───────────────┘
                             ↓
    ┌────────────────────────┼────────────────────────┐
    ↓                                                 ↓
┌──────────────────┐                       ┌─────────────────────┐
│ vtableStubs_init │                       │InlineCacheBuffer_init│
└──────────────────┘                       └─────────────────────┘
                             ↓
              ┌──────────────────────────────┐
              │     compilerOracle_init      │
              └──────────────┬───────────────┘
                             ↓
              ┌──────────────────────────────┐
              │    dependencyContext_init    │
              └──────────────┬───────────────┘
                             ↓
              ┌──────────────────────────────┐
              │      compileBroker_init      │
              └──────────────┬───────────────┘
                             ↓
              ┌──────────────────────────────┐
              │      universe_post_init ✅   │
              └──────────────┬───────────────┘
                             ↓
              ┌──────────────────────────────┐
              │      stubRoutines_init2      │
              └──────────────┬───────────────┘
                             ↓
              ┌──────────────────────────────┐
              │MethodHandles::generate_adapters│
              └──────────────────────────────┘
```

---

## 学习顺序建议

### 第一优先级（核心路径）
1. ⭐⭐⭐ `interpreter_init()` - 解释器是 JVM 执行引擎的核心
2. ⭐⭐⭐ `universe2_init()` - 加载原始类，理解类系统
3. ⭐⭐ `codeCache_init()` - 代码缓存是 JIT 的基础
4. ⭐⭐ `compileBroker_init()` - JIT 编译管理

### 第二优先级（运行时支持）
5. ⭐ `stubRoutines_init1/2()` - 运行时桩代码
6. ⭐ `SharedRuntime::generate_stubs()` - 方法调用桩
7. ⭐ `templateTable_init()` - 字节码模板
8. ⭐ `javaClasses_init()` - Java 类偏移量

### 第三优先级（辅助功能）
9. `gc_barrier_stubs_init()` - GC 屏障
10. `vtableStubs_init()` - 虚表桩
11. `InlineCacheBuffer_init()` - 内联缓存
12. `referenceProcessor_init()` - 引用处理

### 第四优先级（监控/诊断）
13. `management_init()` - JMX
14. `bytecodes_init()` - 字节码定义
15. `compilerOracle_init()` - 编译指令
16. 其他

---

## 相关文档链接

- universe_init() 详细分析: `jvm-md/Universe/`
- 堆初始化: `jvm-md/Universe/3.1-create_heap_outline.md`
- Metaspace: `jvm-md/Universe/5-Metaspace.md`
- SymbolTable: `jvm-md/Universe/11-SymbolTable.md`
- StringTable: `jvm-md/Universe/12-StringTable.md`
