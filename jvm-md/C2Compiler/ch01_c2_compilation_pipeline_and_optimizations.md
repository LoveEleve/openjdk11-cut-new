# C2 编译优化完整深度分析

> 源码目录: `src/hotspot/share/opto/`
> 核心文件: `compile.cpp` (5006行), `node.hpp`, `phaseX.cpp`, `loopnode.cpp`, `c2compiler.cpp`
> 标准环境: `-Xms8g -Xmx8g -XX:+UseG1GC`

---

## 1. 为什么需要 C2？解决什么问题？

C1 编译器（Client Compiler）追求**快速编译**，生成的代码质量中等。而 C2（Server Compiler，又叫 Opto）追求**极致运行时性能**，编译耗时较长但生成的机器码质量远优于 C1。

**分层编译（TieredCompilation）下的分工：**

```
解释执行 → C1 Level 1 (无 Profiling)
         → C1 Level 2 (有限 Profiling)
         → C1 Level 3 (完整 Profiling)    ← 收集分支概率/类型 profile
         → C2 Level 4 (激进优化)          ← 利用 profile 做投机优化
```

**C2 比 C1 多做了什么？**

| 优化类型 | C1 | C2 |
|---------|----|----|
| 方法内联 | ✅ 基础内联 | ✅ 深度内联 + profile 指导 |
| 逃逸分析 | ❌ | ✅ 标量替换/锁消除 |
| 循环优化 | ❌ | ✅ 展开/剥离/谓词化/向量化 |
| GVN | ❌ | ✅ 迭代 GVN + CCP |
| 指令选择 | 简单模式匹配 | BURS 树匹配（ADLC 生成） |
| 寄存器分配 | 线性扫描 | 图着色（Chaitin-Briggs） |

---

## 2. Sea-of-Nodes IR：C2 的核心数据结构

### 2.1 什么是 Sea-of-Nodes？

传统编译器 IR（如 LLVM IR）使用 **基本块 + SSA 形式**，数据流和控制流分开表示。C2 使用了 Cliff Click 博士论文（1995 年）提出的 **Sea-of-Nodes** 表示，它的革命性在于：

> **不存在基本块！数据节点和控制节点在同一个图中，通过边连接。**

**核心设计哲学：**
- 数据节点"漂浮"在"节点之海"中，不绑定到任何特定的基本块
- 一个节点的合法位置 = 支配其所有输入的最早点 ~ 所有使用者的最晚公共祖先
- 优化自然发生：节点可以自由移动到最优位置（code motion 自动完成）

### 2.2 Node 基类

> 源码: `src/hotspot/share/opto/node.hpp:210`

```cpp
class Node {
  friend class VMStructs;
protected:
  Node **_in;       // 输入边数组（use-def 引用）
  Node **_out;      // 输出边数组（def-use 引用）
  
  node_idx_t _cnt;     // 必需输入边数量
  node_idx_t _max;     // 输入数组实际长度
  node_idx_t _outcnt;  // 输出边数量
  node_idx_t _outmax;  // 输出数组实际长度
  
public:
  const node_idx_t _idx;  // 全局唯一的节点编号
  
  // 核心访问方法
  uint req() const { return _cnt; }  // 必需输入数量
  Node* in(uint i) const;             // 第 i 个输入
  uint outcnt() const;                // 使用者数量
};
```

**输入边的两类：**
- **必需边**（Required，0 到 `_cnt-1`）：语义正确性要求的，顺序有意义，允许 NULL
- **优先边**（Precedence，`_cnt` 到 `_max-1`）：调度顺序辅助，无序不重复

**内存管理：**
- 节点从 `node_arena` 分配（`Amalloc_D`），不走常规 C++ new/delete
- `operator delete` 是空操作（NOP），节点通过 `destruct()` 回收编号

### 2.3 四大类节点

Sea-of-Nodes 中所有节点分为四大类，通过 `in(0)` 的约定来区分：

```
┌──────────────────────────────────────────────────────────────────┐
│                     Node 节点分类                                 │
├──────────────┬───────────────────────────────────────────────────┤
│ 控制流节点    │ in(0) = 控制前驱                                   │
│ (Region,If,  │ 表示控制流转移关系                                  │
│  Loop,Return)│ 类似传统 CFG 的边                                  │
├──────────────┼───────────────────────────────────────────────────┤
│ 数据节点      │ in(0) = 控制依赖（可选 NULL=不绑定）               │
│ (Add,Mul,    │ in(1..n) = 数据输入                                │
│  Load,Store) │ 纯计算节点可以"漂浮"                               │
├──────────────┼───────────────────────────────────────────────────┤
│ 内存节点      │ 有专门的内存状态输入边                              │
│ (Load,Store, │ 通过 MergeMemNode 合并内存状态                     │
│  MemBar)     │ Alias 类型区分不同的内存切片                        │
├──────────────┼───────────────────────────────────────────────────┤
│ Phi 节点      │ in(0) = 对应的 RegionNode                         │
│              │ in(i) = 从第 i 条控制路径来的值                     │
│              │ 是 SSA 的"合并点"                                  │
└──────────────┴───────────────────────────────────────────────────┘
```

### 2.4 三大优化钩子虚方法

每个 Node 子类可以通过覆盖三个虚方法参与优化：

#### Identity（恒等变换）

> 源码: `node.hpp:977`

```cpp
// 返回一个已存在的节点（通常是某个输入），计算与 this 完全相同
virtual Node* Identity(PhaseGVN* phase);
```

**语义**：如果 `this` 节点和某个已有节点计算结果一样，返回那个节点。
- 例：`AddI(x, 0)` → 返回 `x`
- 例：`MulI(x, 1)` → 返回 `x`

#### Value（值推断）

> 源码: `node.hpp:980`

```cpp
// 返回这个节点在运行时可能取的值的集合
virtual const Type* Value(PhaseGVN* phase) const;
```

**语义**：根据输入的类型，推断输出的类型范围。
- 例：`AddI(TypeInt::INT, TypeInt::con(5))` → `TypeInt::INT`
- 例：`AddI(TypeInt::con(3), TypeInt::con(5))` → `TypeInt::con(8)`（常量折叠！）

#### Ideal（图变换）

> 源码: `node.hpp:985`

```cpp
// 返回一个更"理想"的节点来替换 this
virtual Node *Ideal(PhaseGVN *phase, bool can_reshape);
```

**语义**：对子图进行代数变换、规范化、强度削减等。
- 返回 `this`：表示修改了自身的输入边（原地变换）
- 返回新节点：替换整棵子树
- 返回 `NULL`：无优化可做

**典型示例 — AddNode::Ideal：**

```
优化1: (x + 1) + 2 → x + (1 + 2) → x + 3     // 常量折叠
优化2: (x + 1) + y → (x + y) + 1               // 常量下推
优化3: (x + y) + 1 → 同上变体                    // 表达式规范化
```

> 源码: `addnode.cpp:111`

```cpp
Node *AddNode::Ideal(PhaseGVN *phase, bool can_reshape) {
  // 先尝试交换操作数（常量放右边）
  if( commute(this, con_left, con_right) ) return this;
  
  // (x + C1) + C2 → x + (C1 + C2)  常量折叠
  if( con_right && add1_op == this_op ) {
    const Type *t12 = phase->type( add1->in(2) );
    if( t12->singleton() ) {
      Node *x1 = add1->in(1);
      Node *x2 = phase->makecon( add1->as_Add()->add_ring(t2, t12) );
      set_req(1, x1);
      set_req(2, x2);
      progress = this;
    }
  }
  // ... 更多变换
}
```

### 2.5 GVN：优化钩子的调度引擎

> 源码: `phaseX.cpp:1210`

IGVN（Iterative Global Value Numbering）是驱动 Identity/Value/Ideal 三个钩子反复运行的**工作列表循环**：

```
┌─────────────────────────────────────────────┐
│         PhaseIterGVN::optimize()            │
│                                             │
│  while (worklist 不为空) {                   │
│    n = worklist.pop();                      │
│    if (n 有使用者) {                         │
│      nn = transform_old(n);  ←─── 核心      │
│    } else {                                 │
│      remove_dead_node(n);                   │
│    }                                        │
│  }                                          │
└─────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────┐
│        transform_old(n)                     │
│                                             │
│  loop {                                     │
│    ① i = apply_ideal(n)   ← Ideal 变换     │
│    ② if (i != NULL) {                       │
│         add_users_to_worklist(n);           │
│         if (i != n) subsume_node(n, i);     │
│         n = i; continue;                    │
│       }                                     │
│    ③ t = n->Value(this)   ← 类型推断       │
│    ④ if (t 变了) {                          │
│         set_type(n, t);                     │
│         add_users_to_worklist(n);           │
│       }                                     │
│    ⑤ if (t.singleton()) {  ← 常量折叠      │
│         con = makecon(t);                   │
│         subsume_node(n, con);               │
│         return con;                         │
│       }                                     │
│    ⑥ i = apply_identity(n) ← Identity 变换 │
│    ⑦ if (i != n) {                          │
│         subsume_node(n, i);                 │
│         return i;                           │
│       }                                     │
│    ⑧ 最后将 n 放入哈希表（值编号去重）      │
│  }                                          │
└─────────────────────────────────────────────┘
```

**关键点：**
- `subsume_node(old, new)` = 全局替换：所有使用 old 的地方都改为使用 new
- `add_users_to_worklist(n)` = 将 n 的所有使用者放入工作列表，传播变化
- 工作列表循环最多迭代 `K * live_nodes()` 次（K 是安全系数），防止死循环

---

## 3. C2 编译完整流水线

### 3.1 入口：C2Compiler::compile_method()

> 源码: `c2compiler.cpp:97`

```cpp
void C2Compiler::compile_method(ciEnv* env, ciMethod* target, 
                                 int entry_bci, DirectiveSet* directive) {
  bool subsume_loads = SubsumeLoads;          // 合并内存操作
  bool do_escape_analysis = DoEscapeAnalysis; // 逃逸分析
  bool eliminate_boxing = EliminateAutoBox;    // 自动拆装箱消除
  bool do_locks_coarsening = EliminateLocks;  // 锁粗化
  
  while (!env->failing()) {
    // 核心：创建 Compile 对象 = 完整编译一个方法
    Compile C(env, this, target, entry_bci, 
              subsume_loads, do_escape_analysis,
              eliminate_boxing, do_locks_coarsening, directive);
    
    // 失败重试策略（渐进降级）
    if (C.failure_reason() != NULL) {
      if (C.failure_reason_is(retry_no_subsuming_loads())) {
        subsume_loads = false; continue;    // 关闭 load 合并重试
      }
      if (C.failure_reason_is(retry_no_escape_analysis())) {
        do_escape_analysis = false; continue; // 关闭 EA 重试
      }
      if (C.failure_reason_is(retry_no_locks_coarsening())) {
        do_locks_coarsening = false; continue; // 关闭锁粗化重试
      }
      // ...
    }
    break;
  }
}
```

**重试策略的设计哲学**：C2 的优化非常激进，某些优化可能导致编译失败（如内存溢出、节点数过多）。此时 C2 不是直接放弃，而是逐步关闭高级优化，用更保守的方式重试。

### 3.2 Compile 构造函数：编译主控流程

> 源码: `compile.cpp:646-955`

Compile 的构造函数是整个 C2 编译的主控流程，分为 **前端**（字节码→IR）、**中端**（优化）、**后端**（IR→机器码）三大阶段：

```
┌─────────────────────────────────────────────────────────────────┐
│                    C2 编译完整流水线                              │
│                                                                 │
│  ┌─────────────┐                                                │
│  │  前端 Parse  │  字节码 → Sea-of-Nodes IR                     │
│  │  (parse.hpp) │  包括方法内联 + 初始 GVN                       │
│  └──────┬──────┘                                                │
│         ▼                                                       │
│  ┌─────────────────────────────────────────────────────┐        │
│  │                 中端 Optimize()                      │        │
│  │                                                     │        │
│  │  ① IGVN #1 — 迭代全局值编号                         │        │
│  │  ② Incremental Inline — 增量内联                    │        │
│  │  ③ Boxing Inline — 装箱方法内联                      │        │
│  │  ④ Remove Speculative Types — 移除推测类型           │        │
│  │  ⑤ Escape Analysis — 逃逸分析                       │        │
│  │  ⑥ Macro Eliminate — 标量替换/锁消除                │        │
│  │  ⑦ IdealLoop #1 — 循环优化第一轮（全功能）          │        │
│  │  ⑧ IdealLoop #2 — partial peeling 后补充            │        │
│  │  ⑨ IdealLoop #3 — CCP 前的循环展开                  │        │
│  │  ⑩ CCP — 条件常量传播                               │        │
│  │  ⑪ IGVN #2 — 再次迭代 GVN                          │        │
│  │  ⑫ IdealLoop #4+ — 后续循环优化                     │        │
│  │  ⑬ Macro Expand — 宏节点展开                        │        │
│  │  ⑭ Final Graph Reshaping — 最终图重塑               │        │
│  └──────┬──────────────────────────────────────────────┘        │
│         ▼                                                       │
│  ┌─────────────────────────────────────────────────────┐        │
│  │                 后端 Code_Gen()                      │        │
│  │                                                     │        │
│  │  ① Matcher — 指令选择（Ideal→Mach 节点）           │        │
│  │  ② PhaseCFG — 构建 CFG + 全局代码调度              │        │
│  │  ③ PhaseChaitin — 寄存器分配（图着色）              │        │
│  │  ④ Block Ordering — 基本块排序                      │        │
│  │  ⑤ Peephole — 窥孔优化                              │        │
│  │  ⑥ Output — 生成机器码                              │        │
│  └──────┬──────────────────────────────────────────────┘        │
│         ▼                                                       │
│  ┌─────────────┐                                                │
│  │  安装 nmethod │  注册到 CodeCache                             │
│  └─────────────┘                                                │
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. 前端：Parse（字节码 → IR）

### 4.1 解析流程

> 源码: `compile.cpp:790-840`

```cpp
{ // Parse 阶段
  TracePhase tp("parse", &timers[_t_parser]);
  
  // 1. 初始化类型函数和 StartNode
  init_tf(TypeFunc::make(method()));
  StartNode* s = new StartNode(root(), tf()->domain());
  init_start(s);
  
  // 2. 创建 CallGenerator 并执行内联解析
  cg = CallGenerator::for_inline(method(), expected_uses);
  jvms = cg->generate(jvms);  // 递归解析字节码→节点
  
  // 3. 处理返回值和异常
  return_values(kit.jvms());
  rethrow_exceptions(kit.transfer_exceptions_into_jvms());
  
  // 4. 字符串优化（StringBuilder 链式调用优化）
  if (has_stringbuilder()) {
    inline_string_calls(true);
  }
  
  // 5. 移除无用节点
  PhaseRemoveUseless pru(initial_gvn(), &for_igvn);
}
```

### 4.2 方法内联决策

方法内联是 C2 最重要的优化之一——只有内联后才能跨方法边界做优化。

> 源码: `bytecodeInfo.cpp`

**内联决策采用"正面过滤 + 负面过滤"两阶段：**

#### 正面过滤 `should_inline()`：

| 条件 | 行为 |
|------|------|
| CompileCommand 指定 `inline` | 强制内联 |
| `@ForceInline` 注解 | 强制内联 |
| `throws` 多（`> InlineThrowCount`）且代码不大 | 提升内联优先级 |
| 调用频率高（`freq >= InlineFrequencyRatio`） | 放宽大小限制到 `FreqInlineSize`（325字节）|
| 是拆箱方法 / 构造器（EA 开启时） | 放宽大小限制 |
| 代码大小 ≤ `MaxInlineSize`（35字节） | 正常内联 |

#### 负面过滤 `should_not_inline()`：

| 条件 | 行为 |
|------|------|
| abstract 方法 | 拒绝 |
| native 方法 | 拒绝 |
| `@DontInline` 注解 | 拒绝 |
| 已编译且代码 > `InlineSmallCode`（2000字节） | 拒绝（大方法） |
| 异常类的方法（调用者不是异常类时） | 拒绝 |
| 从未执行过 | 拒绝 |
| 代码 ≤ `MaxTrivialSize`（6字节） | 不拒绝（极小方法总是内联） |

**关键 JVM 参数：**

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-XX:MaxInlineSize` | 35 | 常规方法内联大小上限（字节码字节数） |
| `-XX:FreqInlineSize` | 325 | 热点方法内联大小上限 |
| `-XX:MaxTrivialSize` | 6 | 极小方法（总是内联） |
| `-XX:InlineSmallCode` | 2000 | 已编译方法代码大小上限 |
| `-XX:MaxInlineLevel` | 9 | 最大内联深度 |
| `-XX:MaxRecursiveInlineLevel` | 1 | 递归方法最大内联层数 |
| `-XX:InlineFrequencyRatio` | 20 | 热点调用频率比 |

---

## 5. 中端：Optimize() — 核心优化 Pass 详解

### 5.1 IGVN #1（迭代全局值编号）

> 源码: `compile.cpp:2252-2260`

```cpp
PhaseIterGVN igvn(initial_gvn());
igvn.optimize();  // 工作列表循环：Ideal + Value + Identity
```

**做了什么？**
- 常量折叠：`3 + 5` → `8`
- 代数简化：`x + 0` → `x`，`x * 1` → `x`
- 强度削减：`x * 2` → `x << 1`
- 公共子表达式消除（通过哈希表值编号）
- 死代码消除（`outcnt == 0` 的节点移除）
- 条件简化：`if (true)` → 消除分支

### 5.2 增量内联（Incremental Inline）

> 源码: `compile.cpp:2264`

```cpp
inline_incrementally(igvn);
```

Parse 阶段可能延迟了某些内联决策（例如 MethodHandle 调用、虚方法调用需要 profile 信息确认类型后才能内联）。增量内联在 IGVN 之后重新检查这些延迟的内联点。

### 5.3 逃逸分析（Escape Analysis）

> 源码: `compile.cpp:2315-2340`

```cpp
if (_do_escape_analysis && ConnectionGraph::has_candidates(this)) {
  // 先做一轮循环优化清理图
  PhaseIdealLoop ideal_loop(igvn, LoopOptsNone);
  // 执行逃逸分析
  ConnectionGraph::do_analysis(this, &igvn);
  igvn.optimize();
  
  // 标量替换 + 锁消除
  if (congraph() != NULL && macro_count() > 0) {
    PhaseMacroExpand mexp(igvn);
    mexp.eliminate_macro_nodes();
    igvn.optimize();
  }
}
```

已有详细文档 → [escape_analysis.md](/data/workspace/openjdk-cut-new/jvm-md/C2Compiler/escape_analysis.md)

核心成果：
- **标量替换**：`new Point(x, y)` → 直接用 `x, y` 两个局部变量
- **同步消除**：对象不逃逸 → 去掉 `synchronized`
- **栈上分配**：JDK 11 实际未实现真正的栈上分配，通过标量替换达到类似效果

### 5.4 循环优化（PhaseIdealLoop）

> 源码: `compile.cpp:2343-2400`, `loopnode.cpp:2862-3253`

循环优化是 C2 最复杂的优化 Pass，在 Optimize() 中被调用**多达 4 次以上**：

```
IdealLoop #1: LoopOptsDefault    — 全功能循环优化
IdealLoop #2: LoopOptsSkipSplitIf — partial peeling 后补充（跳过 split-if）
IdealLoop #3: LoopOptsSkipSplitIf — CCP 前的循环展开
(CCP 之后)
IdealLoop #4+: LoopOptsDefault   — 后续循环优化
IdealLoop #5: LoopOptsLastRound  — 最后一轮
```

**循环优化 build_and_optimize() 内部流程：**

```
build_and_optimize()
├── build_loop_tree()           — 识别所有循环，构建循环树
├── beautify_loops()            — 规范化循环结构（插入 landing pad）
├── Dominators()                — 构建支配树
├── build_loop_early()          — 计算每个节点最早放置位置
├── counted_loop()              — 识别计数循环（CountedLoop）
├── build_loop_late()           — 计算每个节点最晚放置位置
├── eliminate_useless_predicates() — 清理无用的循环谓词
├── ReassociateInvariants       — 循环不变量重结合
├── split_if_with_blocks()      — Split-If 优化
├── loop_predication()          — 循环谓词化（将范围检查移到循环外）
├── iteration_split()           — 迭代分裂（展开/剥离/预循环/主循环/后循环）
│   ├── do_peeling()            — 循环剥离
│   ├── do_unroll()             — 循环展开
│   ├── do_range_check()        — 范围检查消除
│   └── do_maximally_unroll()   — 最大展开（小循环完全展开）
└── SuperWord::transform_loop() — 向量化（SLP 超级字）
```

#### 5.4.1 循环识别与计数循环

C2 将循环分为多种类型：

```cpp
// loopnode.hpp
class LoopNode : public RegionNode {
  enum LoopFlags {
    Normal   = 0,      // 普通循环
    Pre      = 1,      // 预循环（处理对齐/首次迭代）
    Main     = 2,      // 主循环（优化后的主体）
    Post     = 4,      // 后循环（处理剩余迭代）
    PreMainPostFlagsMask = Pre | Main | Post,
    HasNeverBranch = 8, // 包含永不执行的分支
    // ...
  };
};
```

**计数循环（CountedLoop）** 是最重要的循环类型——只有被识别为计数循环的才能做展开/向量化等高级优化：

```java
// 这种循环会被识别为 CountedLoop:
for (int i = 0; i < n; i++) {
  array[i] = i * 2;
}
// 条件: 归纳变量为 int、步长为常量、上界不溢出
```

#### 5.4.2 循环展开（Loop Unrolling）

**目的**：减少循环控制开销（比较+跳转），增加指令级并行度。

展开前：
```java
for (int i = 0; i < 100; i++) {
  a[i] = b[i] + c[i];
}
```

展开 4 次后（概念）：
```java
for (int i = 0; i < 100; i += 4) {
  a[i]   = b[i]   + c[i];
  a[i+1] = b[i+1] + c[i+1];
  a[i+2] = b[i+2] + c[i+2];
  a[i+3] = b[i+3] + c[i+3];
}
```

**展开因子决策（默认 LoopUnrollLimit=60）**：
- 循环体节点数 < `LoopUnrollLimit` 时才展开
- 展开因子 = min(LoopUnrollLimit / body_size, 实际可展开次数)

#### 5.4.3 范围检查消除（Range Check Elimination）

> 源码: `loopTransform.cpp`

Java 数组访问 `a[i]` 必须检查 `0 <= i < a.length`。在循环内每次迭代都检查非常浪费。

C2 的策略：
```
原始循环: for (i=0; i<n; i++) { a[i] = ... }
    ↓
分裂为三段:
  Pre-loop:  for (i=0;     i<min(n,a.length); i++) { a[i] = ... }  // 有范围检查
  Main-loop: for (i=...;   i<safe_limit;      i++) { a[i] = ... }  // 无范围检查!
  Post-loop: for (i=...;   i<n;               i++) { a[i] = ... }  // 有范围检查
```

Main-loop 中已经保证 `i` 在安全范围内，可以完全去掉范围检查。

#### 5.4.4 循环谓词化（Loop Predication）

> 源码: `loopPredicate.cpp`

将循环内的不变条件检查提到循环外面：

```
循环前: if (!invariant_condition) goto deoptimize;
循环体: for (...) {
  // 不再需要检查 invariant_condition
}
```

#### 5.4.5 向量化（SuperWord / SLP）

> 源码: `superword.cpp` (161KB，非常复杂)

SLP（Superword Level Parallelism）将标量操作打包为 SIMD 向量操作：

```
// 标量版本:
a[i]   = b[i]   + c[i];
a[i+1] = b[i+1] + c[i+1];
a[i+2] = b[i+2] + c[i+2];
a[i+3] = b[i+3] + c[i+3];

// 向量化后 (SSE/AVX):
__m128i va = _mm_load_si128(b + i);
__m128i vb = _mm_load_si128(c + i);
_mm_store_si128(a + i, _mm_add_epi32(va, vb));  // 4个int一次算完
```

### 5.5 CCP（条件常量传播）

> 源码: `phaseX.cpp:1943`

CCP 比 GVN 更强——它能利用控制流信息做常量传播。

**IGVN 做不到但 CCP 能做到的例子：**

```java
if (x == 5) {
  y = x + 3;  // CCP 能推断：在此分支中 x==5，所以 y=8
}
```

CCP 算法：
1. **初始化**：所有节点类型设为 `Type::TOP`（乐观假设）
2. **传播**：从 Root 开始，沿输出边传播类型信息。遇到分支时，只沿可达路径传播
3. **收敛**：直到没有类型变化

```cpp
void PhaseCCP::do_transform() {
  C->set_root( transform(C->root())->as_Root() );
}

Node *PhaseCCP::transform_once(Node *n) {
  const Type* t = n->Value(this);  // 用 CCP 信息推断类型
  // 如果是常量，直接替换
  if (t->singleton()) {
    Node* nn = makecon(t);
    // ...替换
  }
}
```

### 5.6 宏节点展开（Macro Expand）

> 源码: `macro.cpp`

C2 在前端将某些高级操作表示为"宏节点"（如 `AllocateNode`, `LockNode`, `ArrayCopyNode`），延迟到所有优化完成后再展开为具体实现。

**好处**：优化器看到的是语义清晰的宏节点，可以做更多优化（如逃逸分析判断 Allocate 可以标量替换）。

宏节点类型：
- `AllocateNode` → 展开为 TLAB 分配 + 慢路径 Runtime 调用
- `LockNode / UnlockNode` → 展开为 CAS + 锁膨胀慢路径
- `ArrayCopyNode` → 展开为高效的内存拷贝代码

### 5.7 最终图重塑（Final Graph Reshaping）

> 源码: `compile.cpp` 中的 `final_graph_reshaping()`

在所有优化完成后进行最后的清理：
- 替换 `Bool + CmpI` 模式为更高效的条件码形式
- 处理 narrow oop 编码/解码
- 处理 `MachNode` 特殊约束
- 清理 Barrier 节点

---

## 6. 后端：Code_Gen() — IR → 机器码

> 源码: `compile.cpp:2478-2593`

### 6.1 指令选择（Matcher）

> 源码: `matcher.cpp` (103KB)

Matcher 将 Ideal 节点映射为平台相关的 Mach 节点。

**工作原理：BURS（Bottom-Up Rewriting System）树匹配**

Mach 节点的匹配规则由 **ADLC**（Architecture Description Language Compiler）从 `.ad` 文件（如 `x86_64.ad`）编译生成：

```
// x86_64.ad 中的指令定义示例（伪代码）
instruct addI_rReg(rRegI dst, rRegI src, rFlagsReg cr) %{
  match(Set dst (AddI dst src));   // 匹配 AddI 节点
  effect(KILL cr);                  // 副作用：修改 FLAGS
  format %{ "addl    $dst, $src" %}
  ins_encode %{ __ addl($dst$$Register, $src$$Register); %}
%}
```

Matcher 对 Ideal 图做**自底向上**遍历，为每棵子树找到代价最低的机器指令匹配。

### 6.2 全局代码调度（PhaseCFG）

> 源码: `gcm.cpp`

这一步将"漂浮"的 Sea-of-Nodes 重新组织为传统的 **基本块 + CFG** 形式：
1. **全局代码移动（GCM）**：将每个节点放置到最优的基本块中
2. **局部调度（LCM）**：在基本块内排列指令顺序（最小化延迟）

### 6.3 寄存器分配（PhaseChaitin）

> 源码: `chaitin.cpp` (88KB)

C2 使用 **Chaitin-Briggs 图着色**算法做寄存器分配，这是最高质量的寄存器分配算法之一：

```
Chaitin-Briggs 流程:
┌───────────┐
│ Build IFG  │  构建干涉图（冲突的变量不能分配同一寄存器）
└─────┬─────┘
      ▼
┌───────────┐
│ Coalesce   │  合并拷贝相关的变量（减少 move 指令）
└─────┬─────┘
      ▼
┌───────────┐
│ Simplify   │  简化图（低度数节点先移除）
└─────┬─────┘
      ▼
┌───────────┐
│ Select     │  选择寄存器（弹出节点，分配颜色）
└─────┬─────┘
      ▼
┌───────────┐
│ Spill?     │  如果分配失败，选择溢出候选→重新开始
└───────────┘
```

### 6.4 基本块排序（Block Ordering）

基于执行频率对基本块排序，将热路径排列在一起：
- 减少分支跳转
- 提高指令缓存命中率

### 6.5 窥孔优化（Peephole）

> 源码: `peep.cpp`

在机器码级别做局部优化：
- 消除冗余的 mov 指令
- 合并连续的内存操作
- 替换为更高效的指令变体

### 6.6 输出（Output）

最终将 MachNode 序列编码为机器码字节，填入 CodeBuffer，然后创建 nmethod 注册到 CodeCache。

---

## 7. 完整编译阶段与 Phase 枚举对照

> 源码: `phase.hpp`

| Phase 枚举 | Timer ID | 对应操作 |
|-----------|----------|---------|
| `_t_parser` | parse | 字节码解析 → Ideal 图 |
| `_t_optimizer` | optimizer | 优化总计时 |
| `_t_escapeAnalysis` | EA | 逃逸分析 |
| `_t_iterGVN` | iterGVN | 第一轮 IGVN |
| `_t_incrInline` | incrInline | 增量内联 |
| `_t_idealLoop` | idealLoop | 循环优化（多轮） |
| `_t_ccp` | ccp | 条件常量传播 |
| `_t_iterGVN2` | iterGVN2 | 第二轮 IGVN |
| `_t_macroExpand` | macroExpand | 宏节点展开 |
| `_t_graphReshaping` | graphReshape | 最终图重塑 |
| `_t_matcher` | matcher | 指令选择 |
| `_t_scheduler` | scheduler | 全局代码调度 |
| `_t_registerAllocation` | regalloc | 寄存器分配 |
| `_t_blockOrdering` | blockOrdering | 基本块排序 |
| `_t_peephole` | peephole | 窥孔优化 |
| `_t_output` | output | 机器码输出 |
| `_t_registerMethod` | install_code | 安装到 CodeCache |

---

## 8. 核心优化效果示例

### 8.1 一个简单方法的完整优化过程

```java
public static int sum(int[] a) {
  int s = 0;
  for (int i = 0; i < a.length; i++) {
    s += a[i];
  }
  return s;
}
```

**Parse 后（未优化 IR）：**
```
每次迭代:
  Load a.length → CmpI i < length → If
  Load a[i] → AddI s + a[i]
  RangeCheck: CmpU i < a.length → If → 可能抛 ArrayIndexOutOfBoundsException
  i++ → 回到循环头
```

**IGVN 后：**
```
a.length 只加载一次（循环不变量提升）
简化冗余类型检查
```

**循环优化后：**
```
Pre-loop:  处理前几次迭代（带范围检查）
Main-loop: 展开 4 次，无范围检查，可能向量化
  s += a[i]; s += a[i+1]; s += a[i+2]; s += a[i+3];
Post-loop: 处理剩余迭代
```

**向量化后（如果硬件支持）：**
```
Main-loop: 使用 SIMD 指令一次加 4/8 个元素
  movdqu xmm0, [rax + rdi*4]     // 加载 4 个 int
  paddd  xmm1, xmm0              // 向量加法
```

**CCP 后：**
```
如果 a.length 是常量（如 a = new int[100]），
编译期确定循环次数，可能完全展开小循环
```

**寄存器分配后：**
```
变量 s → eax, i → ecx, a → rdi
a.length → 常驻寄存器（不需要每次加载）
```

### 8.2 逃逸分析 + 标量替换

```java
public static int distance(int x1, int y1, int x2, int y2) {
  Point p1 = new Point(x1, y1);  // 不逃逸
  Point p2 = new Point(x2, y2);  // 不逃逸
  return p1.distanceTo(p2);
}
```

**优化后等价于：**
```java
public static int distance(int x1, int y1, int x2, int y2) {
  int dx = x1 - x2;
  int dy = y1 - y2;
  return (int) Math.sqrt(dx * dx + dy * dy);
  // 零分配！Point 对象被完全消除
}
```

---

## 9. JVM 参数与诊断

### 9.1 观察 C2 编译活动

```bash
# 查看编译日志
-XX:+PrintCompilation

# 查看内联决策
-XX:+PrintInlining

# 查看 Ideal 图（需要 debug 版 JVM）
-XX:+PrintIdeal

# 输出到 IGV（IdealGraphVisualizer）
-XX:PrintIdealGraphLevel=4
-XX:PrintIdealGraphFile=ideal.xml

# 查看各阶段耗时
-XX:+CITime

# 查看汇编
-XX:+PrintOptoAssembly   # debug 版
-XX:+PrintAssembly       # 需要 hsdis
```

### 9.2 控制优化行为

```bash
# 关闭逃逸分析
-XX:-DoEscapeAnalysis

# 关闭循环展开
-XX:LoopUnrollLimit=0

# 关闭向量化
-XX:-UseSuperWord

# 关闭锁消除
-XX:-EliminateLocks

# 关闭自动装箱消除
-XX:-EliminateAutoBox

# 控制内联
-XX:MaxInlineSize=35        # 默认
-XX:FreqInlineSize=325      # 热方法
-XX:MaxInlineLevel=9        # 最大深度

# 控制编译阈值
-XX:CompileThreshold=10000  # 解释执行多少次后触发编译

# 节点数限制
-XX:MaxNodeLimit=80000      # 超过则放弃编译
```

### 9.3 PrintCompilation 输出解读

```
  1234   4       4       java.util.Arrays::sort (7 bytes)
  │      │       │       │                       │
  │      │       │       方法名                   字节码大小
  │      │       编译级别: 4=C2
  │      编译ID
  时间戳(ms)

标志说明:
  %  → OSR 编译
  s  → synchronized 方法
  !  → 有异常处理
  b  → 阻塞编译（应用线程等待）
  n  → native wrapper
```

---

## 10. 面试高频 Q&A

### Q1: C2 的 Sea-of-Nodes 和 LLVM 的 SSA 有什么区别？

**回答**：
传统 SSA（如 LLVM IR）使用"基本块 + Phi 函数"组织 IR，数据流和控制流分开。C2 的 Sea-of-Nodes 将数据节点和控制节点放在同一个图中，**没有显式的基本块**。

核心区别：在 SSA 中，每条指令有固定的基本块位置；在 Sea-of-Nodes 中，纯计算节点"漂浮"在图中，只要满足依赖关系就可以放在任何位置。这使得代码移动（code motion）成为图的自然属性，不需要单独的优化 Pass。

直到后端 `PhaseCFG` 阶段才重新构建传统 CFG。

### Q2: C2 的 IGVN 工作列表循环是如何保证收敛的？

**回答**：
`PhaseIterGVN::optimize()` 维护一个工作列表，每次弹出一个节点调用 `transform_old()` 做 Ideal/Value/Identity 变换。如果节点变化了，将其使用者重新加入工作列表。

收敛保证：循环次数有上限 `K * C->live_nodes()`，超过就认为是死循环并放弃编译。实际上由于每次变换要么减少节点数（消除冗余），要么降低类型格（Type Lattice），迭代一定收敛。

### Q3: C2 如何做范围检查消除？

**回答**：
C2 将计数循环分裂为 Pre-Main-Post 三段。通过数学推导计算出 Main-loop 中归纳变量的安全范围 `[safe_lo, safe_hi]`，在此范围内 `0 <= i < a.length` 恒成立。Pre-loop 处理从 0 到 safe_lo 的迭代（带检查），Main-loop 处理安全范围（无检查），Post-loop 处理剩余部分（带检查）。

这样 Main-loop（占绝大多数迭代）完全去掉了数组边界检查。

### Q4: C2 编译失败会怎样？

**回答**：
C2 有渐进降级策略。编译失败时依次关闭高级优化重试：
1. 先关闭 load 合并（SubsumeLoads）
2. 再关闭逃逸分析（DoEscapeAnalysis）
3. 再关闭锁粗化（EliminateLocks）
4. 再关闭装箱消除（EliminateAutoBox）

如果全部关闭仍失败，则标记该方法不可编译，回退到 C1 代码或解释执行。

### Q5: 什么情况下 C2 编译的代码反而变慢（反优化 deoptimization）？

**回答**：
C2 做了大量投机优化，如果运行时违反了投机假设就需要反优化：
1. **类型推测失败**：profile 显示某虚方法调用总是 ClassA，C2 直接内联 ClassA 的实现。运行时出现 ClassB → 反优化
2. **异常路径**：C2 假设某些 null check 不会触发，用隐式异常（SEGV 信号）处理。如果频繁触发 → 反优化回退到显式检查
3. **类卸载/重定义**：JVMTI retransform 改变了被内联方法的字节码 → 反优化

反优化后回到解释执行，重新收集 profile，等待重新编译。

### Q6: C2 循环向量化的条件是什么？

**回答**：
1. 必须是计数循环（CountedLoop）
2. 循环体中没有控制流分支（或者可以谓词化）
3. 数据类型相同且支持 SIMD 操作
4. 内存访问必须是连续的（stride = 1 或 stride = -1）
5. 没有循环携带依赖（或者依赖距离 ≥ 向量宽度）
6. 硬件支持对应的 SIMD 指令

向量宽度取决于 CPU：SSE=128bit（4个int），AVX2=256bit（8个int），AVX-512=512bit（16个int）。

---

## 11. 源码索引

| 文件 | 大小 | 核心内容 |
|------|------|---------|
| `compile.cpp` | 175KB | 编译主控：Compile 构造函数、Optimize()、Code_Gen() |
| `compile.hpp` | 65KB | Compile 类定义（所有编译状态） |
| `node.hpp` | 64KB | Node 基类（Sea-of-Nodes 核心数据结构） |
| `node.cpp` | 87KB | Node 基类实现 |
| `phaseX.cpp` | 78KB | PhaseGVN / PhaseIterGVN / PhaseCCP 实现 |
| `phaseX.hpp` | 25KB | GVN 相关类定义 |
| `phase.hpp` | 5KB | Phase 基类 + 枚举定义 |
| `c2compiler.cpp` | 24KB | C2 编译入口 + Intrinsic 支持列表 |
| `loopnode.cpp` | 174KB | PhaseIdealLoop 主控 + 循环识别 |
| `loopTransform.cpp` | 150KB | 循环展开/剥离/预循环 |
| `loopPredicate.cpp` | 59KB | 循环谓词化 |
| `loopopts.cpp` | 127KB | Split-If / 循环不变量提升 |
| `superword.cpp` | 162KB | SLP 向量化 |
| `addnode.cpp` | 41KB | 加法节点 Ideal 变换示例 |
| `bytecodeInfo.cpp` | 27KB | 方法内联决策 |
| `matcher.cpp` | 103KB | 指令选择（BURS 树匹配） |
| `chaitin.cpp` | 89KB | Chaitin-Briggs 寄存器分配 |
| `macro.cpp` | 109KB | 宏节点展开（Allocate/Lock） |
| `escape.cpp` | 138KB | 逃逸分析 |
| `doCall.cpp` | 49KB | 方法调用处理 |
| `graphKit.cpp` | 161KB | 图构建工具 |
| `output.cpp` | 106KB | 机器码输出 |

---

*最后更新: 2026-02-09*
