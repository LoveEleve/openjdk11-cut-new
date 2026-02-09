# C1 编译器完整流水线分析

> 基于 OpenJDK 11 源码 `/data/workspace/openjdk-cut-new/`
> 标准环境: `-Xms8g -Xmx8g -XX:+UseG1GC`
> 分析范围: 65 个源文件（49 shared + 16 x86）

---

## 目录

1. [为什么需要 JIT 编译](#1-为什么需要-jit-编译)
2. [C1 编译器总体架构](#2-c1-编译器总体架构)
3. [编译入口：从 CompileBroker 到 Compilation](#3-编译入口从-compileBroker-到-compilation)
4. [Phase 1: Setup — 初始化编译环境](#4-phase-1-setup--初始化编译环境)
5. [Phase 2: Build HIR — 构建高级中间表示](#5-phase-2-build-hir--构建高级中间表示)
6. [Phase 3: Emit LIR — 生成低级中间表示](#6-phase-3-emit-lir--生成低级中间表示)
7. [Phase 4: Code Emission — 生成机器码](#7-phase-4-code-emission--生成机器码)
8. [Phase 5: Code Installation — 安装到 CodeCache](#8-phase-5-code-installation--安装到-codecache)
9. [核心数据结构](#9-核心数据结构)
10. [Runtime1 运行时桩系统](#10-runtime1-运行时桩系统)
11. [JVM 参数与日志](#11-jvm-参数与日志)
12. [源文件索引](#12-源文件索引)
13. [与其他模块的关联](#13-与其他模块的关联)

---

## 1. 为什么需要 JIT 编译

### 解决什么问题

解释执行（Interpreter）逐条翻译字节码为机器指令，每条字节码都需要经过"取码→解码→分派→执行"的循环。对于热点方法（被频繁调用的方法），这种重复翻译带来巨大的 CPU 开销。

**量化对比**（以简单加法循环为例）：
- 解释执行：每次循环约 10-15 条机器指令（含分派开销）
- C1 编译后：每次循环约 3-5 条机器指令（直接计算 + 循环跳转）

### C1 vs C2 的定位

| 特性 | C1 (Client) | C2 (Server) |
|------|-------------|-------------|
| 编译速度 | 快（毫秒级） | 慢（十毫秒级） |
| 代码质量 | 中等 | 高 |
| 优化力度 | 基础优化 | 激进优化（逃逸分析、循环展开等） |
| IR 类型 | SSA-based HIR → LIR | Sea-of-Nodes |
| 寄存器分配 | Linear Scan | Graph Coloring |
| 适用场景 | 客户端/快速启动 | 服务端/长期运行 |

**分层编译（Tiered Compilation）**下，C1 和 C2 协作：
```
Level 0: 解释执行（收集 Profile）
Level 1: C1 编译，无 Profile
Level 2: C1 编译，带少量 Profile
Level 3: C1 编译，带完整 Profile    ← C1 的主要工作层级
Level 4: C2 编译，基于 Profile 激进优化
```

---

## 2. C1 编译器总体架构

### 2.1 五阶段流水线

```
                           ┌──────────────────────────────────────────────────────┐
                           │                 Compilation 对象                      │
                           │  (栈上创建，编译完成后自动释放)                         │
                           │                                                      │
  Java Bytecode ──→ ┌──────┤  Phase 1: Setup                                     │
                    │      │     └── OopRecorder, DebugInfoRecorder, Dependencies │
                    │      │                                                      │
                    │      │  Phase 2: Build HIR                                  │
                    │      │     ├── GraphBuilder: Bytecode → SSA HIR             │
                    │      │     ├── CE_Eliminator: 条件表达式消除                  │
                    │      │     ├── BlockMerger: 基本块合并                       │
                    │      │     ├── Critical Edge Split: 关键边拆分               │
                    │      │     ├── GVN: 全局值编号                               │
                    │      │     ├── RCE: 范围检查消除                              │
                    │      │     └── NullCheckEliminator: 空检查消除                │
                    │      │                                                      │
                    │      │  Phase 3: Emit LIR                                   │
                    │      │     ├── LIRGenerator: HIR → LIR (虚拟寄存器)          │
                    │      │     └── LinearScan: 寄存器分配 (11 子阶段)             │
                    │      │                                                      │
                    │      │  Phase 4: Code Emission                              │
                    │      │     ├── LIR_Assembler: LIR → 机器码                   │
                    │      │     ├── Slow case stubs                               │
                    │      │     └── Exception/Deopt handlers                      │
                    │      │                                                      │
                    │      │  Phase 5: Code Installation                          │
  Machine Code ←── └──────┤     └── env->register_method() → CodeCache            │
                           └──────────────────────────────────────────────────────┘
```

### 2.2 核心类关系

```
CompileBroker::invoke_compiler_on_method()
    └── Compiler::compile_method()           // c1_Compiler.cpp:238
        └── new Compilation(...)             // 栈上创建，构造函数驱动整个编译
            ├── Compilation::compile_method() // 总控
            │   ├── initialize()
            │   ├── compile_java_method()
            │   │   ├── build_hir()
            │   │   │   ├── new IR() → GraphBuilder
            │   │   │   ├── Optimizer: CE_Eliminator + BlockMerger
            │   │   │   ├── GlobalValueNumbering
            │   │   │   ├── RangeCheckElimination
            │   │   │   └── NullCheckEliminator
            │   │   ├── emit_lir()
            │   │   │   ├── LIRGenerator
            │   │   │   └── LinearScan::do_linear_scan()
            │   │   └── emit_code_body()
            │   │       └── LIR_Assembler::emit_code()
            │   └── install_code()
            │       └── env->register_method()
            └── (析构) 编译完成
```

---

## 3. 编译入口：从 CompileBroker 到 Compilation

### 3.1 触发路径

编译任务由 CompileBroker 分发给编译线程。当 CompilerThread 从编译队列中取出一个 `CompileTask` 后：

```
CompileBroker::invoke_compiler_on_method()
    → comp->compile_method(env, target, entry_bci, directive)
```

`comp` 是 `Compiler`（C1 的 `AbstractCompiler` 子类），每个 CompilerThread 拥有一个实例。

### 3.2 Compiler::compile_method()

**源码位置**: `c1_Compiler.cpp:238`

```cpp
void Compiler::compile_method(ciEnv* env, ciMethod* method, int entry_bci, DirectiveSet* directive) {
    // ...
    BufferBlob* buffer_blob = CompilerThread::current()->get_buffer_blob();
    Compilation compilation(this, env, method, entry_bci, buffer_blob, directive);
}
```

**关键设计**: `Compilation` 对象在**栈上创建**。构造函数完成后整个编译就结束了——构造即编译。

### 3.3 Compilation 构造函数

**源码位置**: `c1_Compilation.cpp:542-598`

构造函数完成以下工作：
1. 初始化所有字段（`_compiler`, `_env`, `_method`, `_osr_bci` 等）
2. 获取当前线程的 `resource_area` 作为 `_arena`
3. 调用 `compile_method()` —— **这就是整个编译的入口**
4. 如果 bailout，记录该方法为不可编译
5. 如果是 profiling 模式，设置 `_would_profile` 标记

```cpp
Compilation::Compilation(...) : _compiler(compiler), _env(env), _method(method), ... {
    PhaseTraceTime timeit(_t_compile);
    _arena = Thread::current()->resource_area();
    _env->set_compiler_data(this);
    _exception_info_list = new ExceptionInfoList();
    
    compile_method();      // ← 整个编译流程在这里完成
    
    if (bailed_out()) {
        _env->record_method_not_compilable(bailout_msg(), !TieredCompilation);
    }
}
```

**内存管理**: 编译过程中分配的所有对象（HIR 节点、LIR 节点、Interval 等）都通过 `Compilation::arena()` 分配，即 `ResourceArea`，随编译线程的 `ResourceMark` 自动释放。

---

## 4. Phase 1: Setup — 初始化编译环境

**源码位置**: `c1_Compilation.cpp:130-138`，由 `compile_method()` 第 431 行调用

```cpp
void Compilation::initialize() {
    OopRecorder* ooprec = new OopRecorder(_env->arena());
    _env->set_oop_recorder(ooprec);
    _env->set_debug_info(new DebugInformationRecorder(ooprec));
    debug_info_recorder()->set_oopmaps(new OopMapSet());
    _env->set_dependencies(new Dependencies(_env));
}
```

创建三个关键对象：

| 对象 | 作用 |
|------|------|
| `OopRecorder` | 记录编译代码中引用的所有 oop（对象指针），GC 时需要更新这些引用 |
| `DebugInformationRecorder` | 记录调试信息（PC ↔ BCI 映射、局部变量值、栈上对象），用于去优化和异常处理 |
| `Dependencies` | 记录编译依赖假设（如"某个类没有子类"），当假设被打破时触发去优化 |

---

## 5. Phase 2: Build HIR — 构建高级中间表示

**源码位置**: `c1_Compilation.cpp:141-250`

这是 C1 编译器最复杂的阶段，包含 **6 个子阶段**。

### 5.1 总览

```cpp
void Compilation::build_hir() {
    // 子阶段 1: 解析字节码，生成 HIR
    { PhaseTraceTime timeit(_t_hir_parse);
      _hir = new IR(this, method(), osr_bci()); }
    
    // 子阶段 2: 条件表达式消除 + 块合并
    if (UseC1Optimizations) {
        PhaseTraceTime timeit(_t_optimize_blocks);
        _hir->optimize_blocks();
    }
    
    // 子阶段 3: 关键边拆分
    _hir->split_critical_edges();
    
    // 子阶段 4: 计算代码顺序 + GVN
    _hir->compute_code();
    if (UseGlobalValueNumbering) {
        PhaseTraceTime timeit(_t_gvn);
        GlobalValueNumbering gvn(_hir);
    }
    
    // 子阶段 5: 范围检查消除
    if (RangeCheckElimination) {
        if (_hir->osr_entry() == NULL) {  // OSR 编译不做 RCE
            PhaseTraceTime timeit(_t_rangeCheckElimination);
            RangeCheckElimination::eliminate(_hir);
        }
    }
    
    // 子阶段 6: 空检查消除
    if (UseC1Optimizations) {
        PhaseTraceTime timeit(_t_optimize_null_checks);
        _hir->eliminate_null_checks();
    }
    
    _hir->compute_use_counts();
}
```

### 5.2 子阶段 1: 字节码解析（GraphBuilder）

**核心类**: `GraphBuilder`（`c1_GraphBuilder.hpp`，428 行）

GraphBuilder 是 C1 前端的核心，将 Java 字节码转换为 SSA 形式的 HIR 图。

#### 工作原理

```
Java Bytecode           GraphBuilder              HIR Graph
┌──────────┐     ┌──────────────────────┐     ┌──────────────────┐
│ iload_1  │     │ 1. 模拟 JVM 操作数栈  │     │ BlockBegin(B0)   │
│ iload_2  │ ──→ │ 2. 每条字节码对应一个  │ ──→ │   Local(1)       │
│ iadd     │     │    HIR 指令生成方法    │     │   Local(2)       │
│ istore_3 │     │ 3. 同时做本地值编号    │     │   ArithmeticOp+  │
│ ireturn  │     │ 4. 处理内联           │     │   Return         │
└──────────┘     └──────────────────────┘     └──────────────────┘
```

#### 关键字段

| 字段 | 作用 |
|------|------|
| `_scope_data` | 内联层级栈（ScopeData 链表），每层内联推入一个新的 ScopeData |
| `_vmap` | `ValueMap*`，用于**本地值编号**（Local CSE），在同一基本块内消除冗余表达式 |
| `_memory` | `MemoryBuffer*`，跟踪内存操作状态，配合 CSE |
| `_instruction_count` | 指令计数器，用于 jsr/ret 病态场景的 bailout 判断 |
| `_block` / `_state` / `_last` | 当前正在处理的基本块、执行状态、最后添加的指令 |

#### 字节码到 HIR 的映射示例

| 字节码 | HIR 指令 | 说明 |
|--------|----------|------|
| `iload_N` | `Local` | 加载局部变量到操作数栈 |
| `iadd` | `ArithmeticOp` | 弹出两个值，压入和 |
| `getfield` | `LoadField` | 读取对象字段 |
| `putfield` | `StoreField` | 写入对象字段 |
| `aaload` | `LoadIndexed` | 数组元素读取 |
| `new` | `NewInstance` | 创建实例 |
| `invokevirtual` | `Invoke` | 方法调用 |
| `if_icmplt` | `If` | 条件分支（块末尾） |
| `goto` | `Goto` | 无条件跳转（块末尾） |
| `ireturn` | `Return` | 方法返回（块末尾） |

#### 内联处理

GraphBuilder 在遇到 `invoke*` 指令时会尝试内联：

```
try_inline()
    ├── try_inline_intrinsics()    // 内建函数直接替换（如 Math.abs → NegateOp + If）
    └── try_inline_full()          // 完整方法内联
        ├── 检查内联深度/代码大小/递归限制
        ├── push_scope(callee_scope_data)
        ├── 在当前图中为被调用方法生成 HIR
        └── pop_scope()
```

内联时通过 `ScopeData` 形成栈式结构，每层维护独立的字节码流和 bci-to-block 映射。

#### 基本块构建

基本块的创建由 `BlockListBuilder`（GraphBuilder 内部使用）在解析前完成，通过扫描字节码中的跳转目标确定块边界。然后 GraphBuilder 按工作列表顺序处理每个块。

### 5.3 HIR 指令体系

HIR 是 C1 的高级中间表示，采用 **SSA（Static Single Assignment）** 形式。

#### 核心设计：指令即值

```cpp
typedef Instruction* Value;
```

每条 HIR 指令**既是操作本身，也是其产生的值**。例如 `ArithmeticOp` 表示加法操作，同时也是加法结果的值。其他指令可以直接引用它作为操作数。

#### Instruction 基类关键字段

| 字段 | 类型 | 作用 |
|------|------|------|
| `_id` | `int` | 唯一 ID，由 Compilation 全局分配 |
| `_type` | `ValueType*` | 指令产生的值的类型 |
| `_next` | `Instruction*` | 块内指令链表的下一条 |
| `_subst` | `Instruction*` | 替代指令（GVN 将冗余指令指向等价指令） |
| `_use_count` | `int` | 被其他指令引用的次数 |
| `_pin_state` | `int` | 钉固原因位掩码（非0 = 不可移动/消除） |
| `_operand` | `LIR_Opr` | LIR 阶段分配的操作数 |
| `_block` | `BlockBegin*` | 所属基本块 |

#### 指令类层次结构（70+ 子类）

```
Instruction (抽象基类)
├── Phi                           ── SSA φ 函数（控制流汇合点合并值）
├── Local                         ── 方法参数/局部变量
├── Constant                      ── 常量
├── AccessField (BASE)            ── 字段访问
│   ├── LoadField                 ── getfield / getstatic
│   └── StoreField                ── putfield / putstatic
├── AccessArray (BASE)            ── 数组访问
│   ├── ArrayLength               ── arraylength
│   └── AccessIndexed (BASE)
│       ├── LoadIndexed           ── aaload / iaload / ...
│       └── StoreIndexed          ── aastore / iastore / ...
├── NegateOp                      ── 一元取反
├── Op2 (BASE)                    ── 二元操作
│   ├── ArithmeticOp              ── +, -, *, /, %
│   ├── ShiftOp                   ── <<, >>, >>>
│   ├── LogicOp                   ── &, |, ^
│   ├── CompareOp                 ── lcmp, fcmpl, fcmpg
│   └── IfOp                      ── 三元条件选择（CE_Eliminator 的产物）
├── Convert                       ── 类型转换 (i2l, f2d 等)
├── NullCheck                     ── 显式空检查
├── StateSplit (BASE)             ── 会分裂 JVM 状态的指令
│   ├── Invoke                    ── 方法调用
│   ├── NewInstance               ── new
│   ├── NewArray (BASE)
│   │   ├── NewTypeArray          ── 基本类型数组
│   │   ├── NewObjectArray        ── 对象数组
│   │   └── NewMultiArray         ── 多维数组
│   ├── TypeCheck (BASE)
│   │   ├── CheckCast             ── checkcast
│   │   └── InstanceOf            ── instanceof
│   ├── AccessMonitor (BASE)
│   │   ├── MonitorEnter          ── monitorenter
│   │   └── MonitorExit           ── monitorexit
│   ├── Intrinsic                 ── 内建函数 (vmIntrinsics)
│   ├── BlockBegin                ── 基本块起始（也是指令！）
│   └── BlockEnd (BASE)           ── 基本块结束
│       ├── Goto                  ── 无条件跳转（1 个后继）
│       ├── If                    ── 条件跳转（2 个后继）
│       ├── TableSwitch           ── tableswitch（N+1 个后继）
│       ├── LookupSwitch          ── lookupswitch（N+1 个后继）
│       ├── Return                ── 方法返回（0 个后继）
│       ├── Throw                 ── 抛出异常（0 个后继）
│       └── Base                  ── 方法入口（指向 std_entry / osr_entry）
├── UnsafeOp (BASE)               ── sun.misc.Unsafe 操作
│   ├── UnsafeGetRaw / UnsafePutRaw
│   ├── UnsafeGetObject / UnsafePutObject
│   └── UnsafeGetAndSetObject     ── CAS / getAndSet
├── ProfileCall / ProfileInvoke / ProfileReturnType  ── Profiling 指令
├── RuntimeCall                   ── 运行时调用
├── MemBar                        ── 内存屏障
└── RangeCheckPredicate           ── 范围检查谓词（RCE 推测优化）
```

#### HIR 图结构

```
IR
└── top_scope (IRScope)
    └── start (BlockBegin)
        └── end = Base
            └── std_entry → BlockBegin(B1)
                              │
        ┌─────────────────────┘
        │
        BlockBegin(B1)                    块内: 单链表
        │  Local(0)                       ───────────────
        │  Local(1)                       BlockBegin → Instruction → ... → BlockEnd
        │  ArithmeticOp(+)                          _next →       _next →
        │  If(cond)     ← BlockEnd
        │   ├── tsux → BlockBegin(B2)     块间: CFG
        │   └── fsux → BlockBegin(B3)     ──────────
        │                                 BlockEnd._sux[] → BlockBegin[]
        BlockBegin(B2)                    BlockBegin._predecessors[]
        │  Constant(1)
        │  Goto         ← BlockEnd        数据流: 直接引用
        │   └── sux → BlockBegin(B4)      ─────────────────
        │                                 ArithmeticOp._x = Local(0)
        BlockBegin(B3)                    ArithmeticOp._y = Local(1)
        │  Constant(0)
        │  Goto
        │   └── sux → BlockBegin(B4)
        │
        BlockBegin(B4)
        │  Phi(B2的值, B3的值)   ← SSA φ 函数
        │  Return
```

#### ValueType 类型系统

C1 自有的类型系统，独立于 JVM 的 `BasicType`：

```
ValueType
├── VoidType       (size=0)
├── IntType        (size=1)  → IntConstant, IntInterval
├── LongType       (size=2)  → LongConstant
├── FloatType      (size=1)  → FloatConstant
├── DoubleType     (size=2)  → DoubleConstant
├── ObjectType     (size=1)  → ObjectConstant, ArrayType, InstanceType
├── MetadataType   (size=1)  → ClassConstant, MethodConstant, MethodDataConstant
├── AddressType    (size=1)  → AddressConstant
└── IllegalType    (size=-1)
```

每种类型有**全局预分配单例**（如 `intType`, `objectType`），常量类型携带具体值。

### 5.4 子阶段 2: 条件表达式消除 + 块合并

**源码位置**: `c1_Optimizer.cpp`

#### CE_Eliminator — 条件表达式消除

将如下 CFG 模式：
```
              If(cond)
             /        \
      t_block          f_block
      [Const_t]        [Const_f]
      Goto             Goto
             \        /
              sux_block
              Phi(t_val, f_val)
```

合并为：
```
              IfOp(cond, t_val, f_val)
              Goto → sux_block
```

**前提条件**:
1. If 操作的是 int 或 object 类型
2. 真/假分支各最多一条 Constant 指令 + Goto
3. 两分支 Goto 汇聚到同一后继
4. 后继起始处恰好一个 Phi 节点
5. 安全点条件匹配

这个优化消除了简单三元表达式的分支开销。

#### BlockMerger — 块合并

将只有单后继 Goto 且后继只有单前驱的相邻块合并：
```
Block A: ... → Goto(B)        合并为        Block AB: A的指令 + B的指令
Block B: (只有A一个前驱)       ────→
```

合并后还尝试进一步简化 `IfOp + If` 为单个 `If`。重复执行直到无法再合并。

### 5.5 子阶段 3: 关键边拆分

**何为关键边**: 从一个有多个后继的块到一个有多个前驱的块的边。

```
拆分前:                      拆分后:
    B1(多后继)                   B1
    /    \                      /    \
   B2    B3(多前驱)            B2    B_new(新块，只含Goto)
          |                           |
         ...                        B3
```

关键边拆分是后续 GVN 和寄存器分配的前提——它确保在边上插入指令时不会影响其他路径。

### 5.6 子阶段 4: 全局值编号（GVN）

**核心类**: `GlobalValueNumbering`（`c1_ValueMap.hpp`）

GVN 在整个 CFG 上消除公共子表达式，同时执行**循环不变代码外提（LICM）**。

#### 工作机制

```
对于每个基本块（按线性扫描顺序）:
    1. 合并所有前驱块的 ValueMap（取交集）
    2. 遍历块内每条指令:
       a. 计算指令的 hash (通过 hash() 方法)
       b. 在 ValueMap 中查找等价指令
       c. 如果找到: 设置 _subst 指向已有指令（替代）
       d. 如果未找到: 插入当前指令到 ValueMap
       e. 对于有副作用的指令: kill 相关 ValueMap 条目
```

#### ValueMap 嵌套哈希表

```cpp
class ValueMap {
    int _nesting;                    // 嵌套层级
    ValueMapEntryArray _entries;     // 哈希桶
    ValueSet _killed_values;         // 被 kill 的值
    int _entry_count;
};
```

- 每层嵌套共享底层条目，高 nesting 条目在前
- `kill_memory()`: 杀死所有内存相关值（Invoke、MonitorEnter 等触发）
- `kill_field(ciField*)`: 杀死特定字段的读取（StoreField 触发）
- `kill_array(ValueType*)`: 杀死特定类型的数组读取（StoreIndexed 触发）

#### LICM（循环不变代码外提）

如果指令的 hash 在循环入口的 ValueMap 中能找到匹配，则该指令是循环不变的，可以外提到循环前（前提是指令没有被 pin）。

### 5.7 子阶段 5: 范围检查消除（RCE）

**核心类**: `RangeCheckEliminator`（`c1_RangeCheckElimination.hpp`）

对于 `arr[i]`，JVM 需要检查 `0 <= i < arr.length`。RCE 试图证明这些检查是冗余的。

#### 三种消除策略

**策略 1: 直接证明**

通过数据流分析追踪变量的边界（Bound 类 = `lower_instr + lower <= value <= upper_instr + upper`），如果能证明索引在数组长度范围内，直接消除。

```java
// 编译器能追踪: i 从 0 开始，每次 +1，到 arr.length 结束
for (int i = 0; i < arr.length; i++) {
    arr[i] = 0;  // 范围检查可以消除
}
```

**策略 2: 块内重排序**

将数组边界检查移到更早的位置，如果前面已有等价或更强的检查，则消除后面的。

**策略 3: 谓词插入（Predicate）**

对于无法在编译时证明的循环，在循环入口插入 `RangeCheckPredicate`：
```
循环入口:
    if (!(0 <= start && end <= arr.length)) goto deoptimize;
    // 循环体内不再需要范围检查
```
如果谓词失败则回退到解释执行（去优化）。

> **注意**: OSR 编译不做 RCE（`_hir->osr_entry() == NULL` 检查），因为 OSR 从循环中间进入，无法保证循环不变量。

### 5.8 子阶段 6: 空检查消除

遍历 HIR 图，基于数据流分析消除冗余的 `NullCheck` 指令。如果能证明某个引用在之前已经被检查过（或已知非空），则后续的空检查可以消除。

---

## 6. Phase 3: Emit LIR — 生成低级中间表示

**源码位置**: `c1_Compilation.cpp:253-282`

```cpp
void Compilation::emit_lir() {
    LIRGenerator gen(this, method());
    { PhaseTraceTime timeit(_t_lirGeneration);
      hir()->iterate_linear_scan_order(&gen); }    // 子阶段 1
    
    { PhaseTraceTime timeit(_t_linearScan);
      LinearScan* allocator = new LinearScan(hir(), &gen, frame_map());
      allocator->do_linear_scan();                  // 子阶段 2
      _max_spills = allocator->max_spills(); }
}
```

### 6.1 子阶段 1: LIRGenerator — HIR → LIR

**核心类**: `LIRGenerator`（`c1_LIRGenerator.hpp`，687 行）

#### 职责

LIRGenerator 继承 `InstructionVisitor`，为每种 HIR 指令实现对应的 `do_Xxx()` 方法，生成 LIR（Low-level Intermediate Representation）指令。

#### 关键区别: HIR vs LIR

| 维度 | HIR | LIR |
|------|-----|-----|
| 抽象级别 | 接近字节码 | 接近机器指令 |
| 寄存器 | 无寄存器概念 | 使用虚拟寄存器 |
| 内存操作 | 隐含（字段访问） | 显式 load/store |
| 操作数 | 指向其他 Instruction | LIR_Opr（寄存器/栈/常量） |
| 控制流 | SSA 图（Phi 函数） | 展平的指令序列 + 分支 |

#### 虚拟寄存器分配

```cpp
LIR_Opr LIRGenerator::new_register(BasicType type) {
    int vreg = _compilation->get_next_id();  // 全局递增
    // 创建虚拟寄存器 operand
    return LIR_OprFact::virtual_register(vreg, type);
}
```

虚拟寄存器编号从 `vreg_base = ConcreteRegisterImpl::number_of_registers` 开始（跳过物理寄存器编号空间）。

#### HIR → LIR 转换示例

以 `ArithmeticOp(+, Local(1), Local(2))` 为例：

```
HIR:                              LIR:
ArithmeticOp(+)                   lir_move  [stack:1] → vreg1     // 加载左操作数
  _x = Local(1)                   lir_move  [stack:2] → vreg2     // 加载右操作数
  _y = Local(2)                   lir_add   vreg1, vreg2 → vreg3  // 执行加法
                                  // vreg3 就是这条 HIR 指令对应的 LIR_Opr
```

#### LIRItem 辅助类

`LIRItem` 封装了 HIR Value → LIR operand 的转换：
- `load_item()`: 确保值在寄存器中
- `load_nonconstant()`: 允许常量内联（不需要加载到寄存器）
- `result()`: 返回对应的 `LIR_Opr`

#### GC 屏障集成

通过 `BarrierSetC1` 接口，`access_store_at()` / `access_load_at()` 在字段/数组读写时自动插入 GC 屏障（如 G1 的 pre-barrier 和 post-barrier）。

#### Phi 函数处理: PhiResolver

SSA 的 Phi 函数在 LIR 层面需要转换为 move 指令。`PhiResolver` 构建 move 图，检测循环依赖并使用临时寄存器打破循环。

### 6.2 LIR 指令体系

#### LIR_Opr — 操作数编码

`LIR_Opr`（实际类型 `LIR_OprDesc*`）使用**指针标记（tagged pointer）**编码，将操作数信息直接编码在指针值中：

```
位域布局（从低位到高位）:
[data | is_xmm | virtual | fpu_stack | last_use | destroys | size(2) | type(4) | kind(3)]
```

五类操作数：
1. **物理 CPU 寄存器**: `kind=cpu_register`, `virtual=0`, data=物理寄存器号
2. **虚拟 CPU 寄存器**: `kind=cpu_register`, `virtual=1`, data=vreg 编号
3. **FPU/XMM 寄存器**: `kind=fpu_register`
4. **栈位置**: `kind=stack_value`, data=栈索引
5. **指针类型**（常量/地址）: `kind=pointer_value`, 指向堆上 `LIR_Const` 或 `LIR_Address`

#### LIR_Op 类层次

```
LIR_Op                    ── 基类 (_result, _code, _info, _id)
├── LIR_Op0               ── 零操作数 (label, nop, membar, build_frame, ...)
├── LIR_Op1               ── 单操作数 (move, return, null_check, safepoint, ...)
│   ├── LIR_OpBranch      ── 分支 (branch, cond_float_branch)
│   ├── LIR_OpConvert     ── 类型转换
│   ├── LIR_OpAllocObj    ── 对象分配
│   └── LIR_OpRoundFP     ── 浮点舍入
├── LIR_Op2               ── 双操作数 (add, sub, mul, div, cmp, shift, logic, ...)
├── LIR_Op3               ── 三操作数 (idiv, irem, fma)
├── LIR_OpCall            ── 调用基类
│   ├── LIR_OpJavaCall    ── Java 调用 (static, virtual, interface, dynamic)
│   └── LIR_OpRTCall      ── 运行时调用
├── LIR_OpArrayCopy       ── System.arraycopy
├── LIR_OpLock            ── monitor enter/exit
├── LIR_OpTypeCheck       ── instanceof, checkcast, store_check
├── LIR_OpCompareAndSwap  ── CAS 操作
└── LIR_OpProfileCall/Type ── Profiling
```

#### LIR 操作码分类

| 类别 | 代表操作码 |
|------|-----------|
| 框架管理 | `lir_std_entry`, `lir_build_frame`, `lir_label`, `lir_nop` |
| 数据移动 | `lir_move`, `lir_push`, `lir_pop`, `lir_leal` |
| 算术 | `lir_add`, `lir_sub`, `lir_mul`, `lir_div`, `lir_rem`, `lir_neg` |
| 逻辑/位移 | `lir_logic_and/or/xor`, `lir_shl`, `lir_shr`, `lir_ushr` |
| 比较/分支 | `lir_cmp`, `lir_branch`, `lir_cmove` |
| 调用 | `lir_static_call`, `lir_virtual_call`, `lir_icvirtual_call`, `lir_dynamic_call` |
| 对象分配 | `lir_alloc_object`, `lir_alloc_array` |
| 类型检查 | `lir_instanceof`, `lir_checkcast`, `lir_store_check` |
| 锁 | `lir_lock`, `lir_unlock` |
| CAS | `lir_cas_int`, `lir_cas_long`, `lir_cas_obj` |
| 内存屏障 | `lir_membar_acquire`, `lir_membar_release`, `lir_membar` |
| 异常 | `lir_throw`, `lir_unwind` |
| 数学 | `lir_sqrt`, `lir_abs`, `lir_tan`, `lir_log10` |
| Profiling | `lir_profile_call`, `lir_profile_type` |

#### LIR_List

每个基本块一个 `LIR_List`，内部维护 `GrowableArray<LIR_Op*>`。提供丰富的便捷方法直接构造并 append 各类 LIR_Op。

### 6.3 子阶段 2: Linear Scan 寄存器分配

**核心类**: `LinearScan`（`c1_LinearScan.hpp`，964 行头文件；`c1_LinearScan.cpp` 约 6800 行实现）

#### 算法概述

Linear Scan 是一种 O(n·log n) 的寄存器分配算法（相比图着色的 NP-hard），C1 选择它是因为编译速度优先。

核心思想：
1. 将每个虚拟寄存器的生命期表示为**区间（Interval）**
2. 按区间起点排序
3. 线性扫描，维护 active/inactive 列表，尝试为每个区间分配物理寄存器
4. 无可用寄存器时，溢出（spill）或分裂（split）某个区间

#### 11 个子阶段

```
LinearScan::do_linear_scan()
│
├── Phase 1: number_instructions()
│   为所有 LIR 指令编号（偶数 ID，奇数留给间隙 move）
│   建立 _lir_ops[] 和 _block_of_op[] 映射
│
├── Phase 2: compute_local_live_sets()
│   对每个基本块独立计算局部活跃集（live_gen / live_kill）
│
├── Phase 3: compute_global_live_sets()
│   反向数据流分析，迭代计算全局 live_in / live_out
│
├── Phase 4: build_intervals()
│   根据活跃性信息构建每个寄存器的 Interval（Range 链表 + use position 列表）
│
├── Phase 5: sort_intervals_before_allocation() + allocate_registers()
│   按 from() 排序，LinearScanWalker 执行核心扫描
│   ┌─ 遍历排序后的 interval
│   │  ├── 检查 active 列表：移除已过期的
│   │  ├── 检查 inactive 列表：移到 active 或移除
│   │  ├── 尝试分配空闲寄存器
│   │  │   └── 扫描所有物理寄存器，选 _use_pos 最远的
│   │  └── 无空闲：选择溢出或分裂
│   │      ├── spill: 将 interval 分配到栈
│   │      └── split: 在最佳位置分裂，部分在寄存器、部分在栈
│   └─
│
├── Phase 6: resolve_data_flow()
│   在基本块边界插入 move，解决分裂导致的位置不一致
│
├── Phase 6b: resolve_exception_handlers()
│   对异常处理器边做类似解析
│
├── Phase 7: eliminate_spill_moves() + assign_reg_num()
│   消除冗余溢出 move，将虚拟寄存器号替换为物理寄存器号
│   同时计算 OopMap 和调试信息
│
├── Phase 8: allocate_fpu_stack()
│   x86 FPU 栈分配（仅 UseSSE < 2 且有浮点寄存器时）
│
├── Phase 9: EdgeMoveOptimizer::optimize()
│   优化基本块边界的 move 指令
│
└── Phase 10: ControlFlowOptimizer::optimize()
    消除空块、优化条件分支
```

#### Interval 类

```
Interval
├── _reg_num          : 寄存器编号（物理/虚拟）
├── _type             : BasicType
├── _first            : Range*      ← 有序不相交的活跃范围链表 (from, to, next)
├── _use_pos_and_kinds: intStack    ← 使用点和使用类型的排序列表
├── _state            : IntervalState  ← unhandled → active ↔ inactive → handled
├── _assigned_reg     : int         ← 分配的物理寄存器
├── _split_parent     : Interval*   ← 分裂的原始 interval
├── _split_children   : IntervalList*
├── _canonical_spill_slot : int     ← 所有分裂部分共享的溢出槽
└── _register_hint    : Interval*   ← 提示分配同一寄存器（减少 move）
```

**IntervalState 四态**:
```
unhandled ──→ active ←──→ inactive
                │              │
                └──→ handled ←─┘
```

**IntervalUseKind 优先级**: `noUse(0)` < `loopEndMarker(1)` < `shouldHaveRegister(2)` < `mustHaveRegister(3)`

`mustHaveRegister` 的使用点（如方法调用的参数）必须在物理寄存器中，不能溢出。

---

## 7. Phase 4: Code Emission — 生成机器码

**源码位置**: `c1_Compilation.cpp:340-367`

```cpp
int Compilation::emit_code_body() {
    setup_code_buffer(code(), allocator()->num_calls());
    code()->initialize_oop_recorder(env()->oop_recorder());
    _masm = new C1_MacroAssembler(code());
    
    LIR_Assembler lir_asm(this);
    lir_asm.emit_code(hir()->code());          // 主体代码
    emit_code_epilog(&lir_asm);                // 附属代码
    generate_exception_handler_table();
    
    return frame_map()->framesize();
}
```

### 7.1 LIR_Assembler

**核心类**: `LIR_Assembler`（`c1_LIRAssembler.hpp`）

LIR_Assembler 将 LIR 指令翻译为实际机器码，是**平台相关**的组件。

#### 代码生成流程

```
LIR_Assembler::emit_code(BlockList* hir)
│
├── 遍历每个 BlockBegin:
│   ├── emit_block(block)
│   │   ├── 输出块标签
│   │   ├── emit_lir_list(block->lir())
│   │   │   └── 遍历 LIR_List 中每条 LIR_Op:
│   │   │       └── op->emit_code(this)
│   │   │           │
│   │   │           ├── LIR_Op0: build_frame, membar, ...
│   │   │           ├── LIR_Op1: move → 分派到 9 种 move 子方法
│   │   │           │   ├── const2reg(), const2stack(), const2mem()
│   │   │           │   ├── reg2reg(), reg2stack(), reg2mem()
│   │   │           │   └── stack2reg(), stack2stack(), mem2reg()
│   │   │           ├── LIR_Op2: arith_op, logic_op, shift_op, comp_op
│   │   │           ├── LIR_OpJavaCall: call + 重定位信息
│   │   │           ├── LIR_OpBranch: jcc / jmp
│   │   │           └── ...
│   │   └── 输出块结尾
│   └──
│
└── 后续（由 emit_code_epilog 执行）:
    ├── emit_slow_case_stubs()           // 慢速路径桩
    ├── emit_exception_entries()          // 异常适配器
    ├── emit_exception_handler()          // 异常处理器
    ├── emit_deopt_handler()              // 去优化处理器
    └── emit_unwind_handler()             // 展开处理器
```

### 7.2 慢速路径桩（Slow Case Stubs）

编译代码通常生成**快速路径 + 慢速路径**结构：

```asm
; 快速路径（内联在主代码流中）
    cmp   rax, 0
    je    slow_null_check          ; 失败则跳到慢速路径
    ; 正常操作...

; ... 主代码继续 ...

; 慢速路径（放在代码末尾，不影响 icache）
slow_null_check:
    call  Runtime1::throw_null_pointer_exception_id
```

这些慢速路径由 `emit_slow_case_stubs()` 在主代码之后统一生成。

### 7.3 CodeBuffer 布局

```
┌──────────────────────────────────────────────────┐
│ insts section:                                    │
│   ├── 方法入口代码 (verified_entry)               │
│   ├── 主体代码（按块顺序）                         │
│   ├── 慢速路径桩                                  │
│   ├── 异常适配器                                  │
│   ├── 异常处理器入口                              │
│   ├── 去优化处理器入口                             │
│   └── 展开处理器入口                              │
├──────────────────────────────────────────────────┤
│ stubs section:                                    │
│   └── call stubs                                  │
├──────────────────────────────────────────────────┤
│ consts section:                                   │
│   └── 常量池                                      │
└──────────────────────────────────────────────────┘
```

---

## 8. Phase 5: Code Installation — 安装到 CodeCache

**源码位置**: `c1_Compilation.cpp:408-426`

```cpp
void Compilation::install_code(int frame_size) {
    _env->register_method(
        method(),                           // 目标方法
        osr_bci(),                          // OSR 入口 BCI（-1 = 正常编译）
        &_offsets,                          // 代码段偏移表
        frame_map()->sp_offset_for_orig_pc(), // 原始 PC 偏移
        code(),                             // CodeBuffer
        frame_map()->framesize_in_bytes() / sizeof(intptr_t),
        debug_info_recorder()->_oopmaps,    // OopMap 集合
        exception_handler_table(),
        implicit_exception_table(),
        compiler(),                         // Compiler 实例
        has_unsafe_access(),
        SharedRuntime::is_wide_vector(max_vector_size())
    );
}
```

`env->register_method()` 最终调用 `nmethod::new_nmethod()`：

1. 从 CodeCache 分配空间（在 `non_nmethods` 或 `non_profiled_nmethods` 段）
2. 复制机器码到 CodeCache
3. 创建 `nmethod` 结构，填充所有元数据
4. 修补重定位信息
5. 将 `nmethod` 安装到 `Method::_code` 字段
6. 通知 ICache 刷新

安装完成后，该方法的后续调用将直接执行编译后的机器码。

---

## 9. 核心数据结构

### 9.1 类关系图

```
                    ┌─────────────────────┐
                    │   AbstractCompiler   │
                    └─────────┬───────────┘
                              │ 继承
                    ┌─────────┴───────────┐
                    │     Compiler (C1)    │ ── 每个 CompilerThread 一个
                    │  compile_method()    │
                    └─────────┬───────────┘
                              │ 创建
                    ┌─────────┴───────────┐
                    │    Compilation       │ ── 单次编译的全部状态
                    │  _hir, _frame_map    │
                    │  _masm, _code        │
                    └──┬──────┬──────┬─────┘
                       │      │      │
            ┌──────────┘      │      └──────────────────┐
            │                 │                         │
    ┌───────┴───────┐  ┌─────┴─────┐           ┌───────┴──────┐
    │      IR       │  │ FrameMap  │           │   CodeBuffer │
    │ _top_scope    │  │ 栈帧布局   │           │ 机器码容器    │
    │ _code (块列表) │  └───────────┘           └──────────────┘
    └───────┬───────┘
            │ 包含
    ┌───────┴───────┐
    │    IRScope     │ ── 每个方法/内联方法一个
    │  _method       │
    │  _start (块)   │
    │  _callees      │ ── 被内联的子作用域
    └───────┬───────┘
            │ 包含
    ┌───────┴───────────┐
    │    BlockBegin      │ ── 基本块（也是 Instruction 子类）
    │  _end (BlockEnd)   │
    │  _lir (LIR_List)   │
    │  _live_in/out      │
    │  _predecessors     │
    │  _successors       │
    └──┬────────────────┘
       │ 包含
    ┌──┴──────────────────┐
    │   Instruction       │ ── HIR 指令（_next 单链表）
    │  _type, _id         │
    │  _subst (GVN替代)   │
    │  _operand (LIR_Opr) │
    └─────────────────────┘
```

### 9.2 数据流转全景

```
字节码               HIR                  LIR                   机器码
─────────        ──────────           ──────────            ──────────
iload_1    →     Local(1)       →     lir_move [s1]→v1  →  mov eax, [rbp-0x10]
iload_2    →     Local(2)       →     lir_move [s2]→v2  →  mov ecx, [rbp-0x18]
iadd       →     ArithmeticOp+  →     lir_add  v1,v2→v3 →  add eax, ecx
istore_3   →     (合并到链)      →     lir_move v3→[s3]  →  mov [rbp-0x20], eax
ireturn    →     Return         →     lir_return v3      →  mov rax, eax; ret
```

---

## 10. Runtime1 运行时桩系统

**核心类**: `Runtime1`（`c1_Runtime1.hpp`，AllStatic）

C1 编译的代码在运行时遇到慢速路径时，需要调用预生成的汇编桩代码。Runtime1 在 JVM 启动时（`Compiler::init_c1_runtime()`）为所有桩生成机器码。

### 全部 33 个 StubID

| # | StubID | 用途 |
|---|--------|------|
| 1 | `dtrace_object_alloc_id` | DTrace 对象分配探针 |
| 2 | `unwind_exception_id` | 异常展开 |
| 3 | `forward_exception_id` | 异常转发 |
| 4 | `throw_range_check_failed_id` | 抛出 ArrayIndexOutOfBoundsException |
| 5 | `throw_index_exception_id` | 抛出 IndexOutOfBoundsException |
| 6 | `throw_div0_exception_id` | 抛出除零异常 |
| 7 | `throw_null_pointer_exception_id` | 抛出 NullPointerException |
| 8 | `register_finalizer_id` | 注册 finalizer |
| 9 | `new_instance_id` | new 对象（通用慢路径） |
| 10 | `fast_new_instance_id` | new 对象（已知大小快速路径） |
| 11 | `fast_new_instance_init_check_id` | new 对象 + 类初始化检查 |
| 12 | `new_type_array_id` | 基本类型数组分配 |
| 13 | `new_object_array_id` | 对象数组分配 |
| 14 | `new_multi_array_id` | 多维数组分配 |
| 15 | `handle_exception_nofpu_id` | 异常处理（不保存 FPU） |
| 16 | `handle_exception_id` | 异常处理 |
| 17 | `handle_exception_from_callee_id` | 来自被调用者的异常 |
| 18 | `throw_array_store_exception_id` | ArrayStoreException |
| 19 | `throw_class_cast_exception_id` | ClassCastException |
| 20 | `throw_incompatible_class_change_error_id` | IncompatibleClassChangeError |
| 21 | `slow_subtype_check_id` | 慢速子类型检查 |
| 22 | `monitorenter_id` | 加锁 |
| 23 | `monitorenter_nofpu_id` | 加锁（不保存 FPU） |
| 24 | `monitorexit_id` | 解锁 |
| 25 | `monitorexit_nofpu_id` | 解锁（不保存 FPU） |
| 26 | `deoptimize_id` | 去优化 |
| 27 | `access_field_patching_id` | 字段访问补丁 |
| 28 | `load_klass_patching_id` | 加载类补丁 |
| 29 | `load_mirror_patching_id` | 加载镜像类补丁 |
| 30 | `load_appendix_patching_id` | 加载附录补丁 |
| 31 | `fpu2long_stub_id` | FPU → long 转换 |
| 32 | `counter_overflow_id` | 计数器溢出（触发重编译） |
| 33 | `predicate_failed_trap_id` | 谓词失败（RCE 去优化） |

### Patching 机制

`access_field_patching_id`、`load_klass_patching_id` 等桩用于**延迟链接**：编译时如果某些引用尚未解析（如类还没加载），生成的代码先调用 patching 桩，桩在运行时完成解析后**回写**机器码，使后续调用直接走快速路径。

---

## 11. JVM 参数与日志

### 11.1 编译日志

| 参数 | 效果 | 输出示例 |
|------|------|---------|
| `-XX:+PrintCompilation` | 打印每次编译事件 | `42 3 com.demo.Main::hot (15 bytes)` |
| `-XX:+CITime` | 打印编译计时总结 | 见下方 |
| `-XX:+CITimeEach` | 每次编译打印计时 | 每个方法的阶段耗时 |
| `-XX:+PrintBailouts` | 打印编译放弃原因 | `compilation bailout: ...` |

`-XX:+CITime` 输出格式（即 `Compilation::print_timers()`）：
```
    C1 Compile Time:        1.234 s
       Setup time:            0.012 s
       Build HIR:             0.456 s
         Parse:                 0.234 s
         Optimize blocks:       0.023 s
         GVN:                   0.089 s
         Null checks elim:      0.034 s
         Range checks elim:     0.045 s
         Other:                 0.031 s
       Emit LIR:              0.345 s
         LIR Gen:               0.123 s
         Linear Scan:           0.222 s
       Code Emission:         0.234 s
       Code Installation:     0.187 s
```

### 11.2 HIR/LIR 调试输出

| 参数 | 效果 |
|------|------|
| `-XX:+PrintCFG` | 打印所有阶段的 CFG |
| `-XX:+PrintCFG0` | 解析后的 CFG |
| `-XX:+PrintCFG1` | 优化后的 CFG |
| `-XX:+PrintCFG2` | 代码生成前的 CFG |
| `-XX:+PrintIR` | 打印所有阶段的 IR |
| `-XX:+PrintIR0` | 解析后的 IR |
| `-XX:+PrintIR1` | 优化后的 IR |
| `-XX:+PrintIR2` | 代码生成前的 IR |
| `-XX:+PrintLIR` | 打印 LIR |
| `-XX:+PrintCFGToFile` | 输出 CFG 到文件（可用 c1visualizer 查看） |

> **注意**: `PrintCFG`/`PrintIR`/`PrintLIR` 仅在 **debug/slowdebug 构建** 中可用。

### 11.3 编译控制

| 参数 | 效果 |
|------|------|
| `-XX:+TieredCompilation` | 开启分层编译（默认开启） |
| `-XX:TieredStopAtLevel=1` | 只使用 C1，不触发 C2 |
| `-XX:+UseC1Optimizations` | 启用 C1 优化（CE 消除、块合并、空检查消除） |
| `-XX:+UseGlobalValueNumbering` | 启用 GVN |
| `-XX:+RangeCheckElimination` | 启用范围检查消除 |
| `-XX:+BailoutAfterHIR` | 构建 HIR 后放弃（调试用） |
| `-XX:+BailoutAfterLIR` | 生成 LIR 后放弃（调试用） |
| `-XX:+BailoutOnExceptionHandlers` | 有异常处理器时放弃 |

---

## 12. 源文件索引

### 12.1 核心文件（编译流水线）

| 文件 | 行数 | 职责 |
|------|------|------|
| `c1_Compiler.cpp/hpp` | 255/67 | C1 入口，AbstractCompiler 子类 |
| `c1_Compilation.cpp/hpp` | 723/~350 | 编译总控，5 阶段调度 |
| `c1_IR.hpp/cpp` | 364/~500 | IR 容器、IRScope、XHandler |
| `c1_GraphBuilder.cpp/hpp` | ~4500/428 | 字节码 → HIR |
| `c1_Instruction.hpp/cpp` | 2633/~1800 | HIR 指令体系 (70+ 类) |
| `c1_ValueType.hpp/cpp` | 519/~200 | 类型系统 |
| `c1_ValueMap.hpp/cpp` | 261/~300 | GVN ValueMap |
| `c1_ValueStack.hpp/cpp` | ~300/~200 | JVM 状态（操作数栈 + 局部变量） |
| `c1_Optimizer.hpp/cpp` | 46/1210 | CE_Eliminator + BlockMerger + NullCheckEliminator |
| `c1_RangeCheckElimination.hpp/cpp` | 244/~1500 | 范围检查消除 |

### 12.2 LIR 与寄存器分配

| 文件 | 行数 | 职责 |
|------|------|------|
| `c1_LIR.hpp/cpp` | 2476/~1200 | LIR 指令体系、LIR_Opr、LIR_List |
| `c1_LIRGenerator.hpp/cpp` | 687/~3500 | HIR → LIR 转换 |
| `c1_LinearScan.hpp/cpp` | 964/~6800 | Linear Scan 寄存器分配 |
| `c1_FrameMap.hpp/cpp` | ~200/~200 | 栈帧布局 |

### 12.3 代码生成（平台相关）

| 文件 | 行数 | 职责 |
|------|------|------|
| `c1_LIRAssembler.hpp/cpp` | 283/~800 | LIR → 机器码（共享部分） |
| `c1_LIRAssembler_x86.cpp` | ~4000 | x86 平台的 LIR 翻译 |
| `c1_MacroAssembler_x86.cpp` | ~500 | x86 宏汇编器 |
| `c1_Runtime1.hpp/cpp` | 203/~1300 | 运行时桩系统 |
| `c1_Runtime1_x86.cpp` | ~1600 | x86 平台桩生成 |
| `c1_CodeStubs.hpp/cpp` | ~600/~400 | 慢速路径桩定义 |
| `c1_CodeStubs_x86.cpp` | ~500 | x86 平台桩实现 |

### 12.4 辅助

| 文件 | 职责 |
|------|------|
| `c1_Canonicalizer.hpp/cpp` | 指令规范化（常量折叠等） |
| `c1_InstructionPrinter.hpp/cpp` | HIR 指令打印 |
| `c1_CFGPrinter.hpp/cpp` | CFG 输出到文件 |
| `c1_Defs.hpp` | 平台相关定义 |
| `c1_globals.hpp` | C1 全局标志 |

---

## 13. 与其他模块的关联

### 13.1 与 CompileBroker 的关系

```
CompileBroker::init_compiler_runtime()
    → Compiler::initialize()
        → Runtime1::initialize() → 生成 33 个桩

CompileBroker::invoke_compiler_on_method()
    → Compiler::compile_method()
        → Compilation(...)
```

详见 `jvm-md/CompileBroker/compileBroker_init.md`。

### 13.2 与 CodeCache 的关系

编译产出的 `nmethod` 安装到 CodeCache 的 `non_profiled_nmethods` 段。CodeCache 的三段式布局：

```
CodeCache
├── non_nmethods:           Runtime1 桩 + StubRoutines + ...
├── profiled_nmethods:      带 Profile 的 nmethod（Level 3）
└── non_profiled_nmethods:  无 Profile 的 nmethod（Level 1, 4）
```

详见 `jvm-md/CodeCache/codeCache_init.md`。

### 13.3 与解释器的关系

- **编译触发**: 解释器通过 `InvocationCounter` 计数，达到阈值后提交编译任务
- **OSR**: 解释器在循环回边检测到热循环，提交 OSR 编译，编译完成后从循环中间切换到编译代码
- **去优化**: 编译代码的依赖假设被打破时，通过 `deoptimize_id` 桩回退到解释执行
- **Profile 数据**: Level 3 编译的代码收集 Profile 数据（`MethodData`），供 C2 使用

### 13.4 与 G1 GC 的关系

LIRGenerator 在生成字段/数组写入代码时，通过 `BarrierSetC1`（G1 对应 `G1BarrierSetC1`）插入：
- **Pre-barrier**: SATB 写前记录旧值
- **Post-barrier**: 标记脏卡

详见 `jvm-md/G1-GC/8.7_G1_Barrier_JIT_Version.md`。

---

## 总结

C1 编译器是一个经典的 **5 阶段编译流水线**，设计目标是**编译速度优先、代码质量适中**：

```
Bytecode → [GraphBuilder] → HIR(SSA)
         → [CE_Elim + GVN + RCE + NullCheck] → 优化后的 HIR
         → [LIRGenerator] → LIR(虚拟寄存器)
         → [LinearScan(11步)] → LIR(物理寄存器)
         → [LIR_Assembler] → 机器码
         → [register_method] → CodeCache
```

**核心设计选择**：
1. **SSA HIR** — 便于优化（GVN、RCE），但比 C2 的 Sea-of-Nodes 更简单
2. **Linear Scan** — O(n·log n) 复杂度，远快于图着色，适合快速编译
3. **栈上 Compilation** — 编译状态随栈帧释放，无需手动清理
4. **Visitor 模式** — LIRGenerator 和 Optimizer 都通过 InstructionVisitor 分派，扩展性好
5. **快慢路径分离** — 快速路径内联，慢速路径放在代码末尾调用 Runtime1 桩

---

*文件: jvm-md/C1Compiler/c1_compilation_pipeline.md*
*创建时间: 2026-02-07*
*源码版本: OpenJDK 11*
