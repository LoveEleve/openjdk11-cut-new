# 主题五：JIT 编译优化 — 从解释到编译

> 对应文档: `C1Compiler/`, `C2Compiler/`, `CompileBroker/`, `CodeCache/`, `InvocationCounter/`
> 面试覆盖: C1/C2 流水线 / 方法内联 / 逃逸分析 / OSR / 反优化 / CodeCache

---

## Q1: JIT 编译的触发条件是什么？⭐

### 一句话结论
方法调用计数器 + 回边计数器超过阈值时触发编译。C1 阈值约 **1500~2000 次**，C2 约 **10000 次**（分层编译下）。

### 源码级回答

**分层编译 5 个级别 (-XX:+TieredCompilation, 默认开):**
```
Tier 0: 解释执行
Tier 1: C1 编译，无 profiling
Tier 2: C1 编译，有限 profiling (invocation/backedge counters)
Tier 3: C1 编译，完全 profiling (branch/type/call profiling) ← 最常见
Tier 4: C2 编译 ← 性能最优
```

**典型升级路径:**
```
Tier 0 → Tier 3 → Tier 4
     解释 →  C1   →  C2
```

**触发阈值 (InvocationCounter):**
```cpp
// 方法调用计数器
invocation_counter += 1;  // 每次方法调用

// 回边计数器 (循环回跳)
backedge_counter += 1;   // 每次循环迭代

// 触发条件: 任一计数器 >= CompileThreshold
// 分层编译下由 AdvancedThresholdPolicy 动态计算
// 考虑: 当前编译队列长度 + 方法热度 + 可用编译线程
```

**关键参数:**
```
-XX:CompileThreshold=10000      # 非分层编译阈值
-XX:Tier3InvocationThreshold=200 # C1 编译阈值
-XX:Tier4InvocationThreshold=5000 # C2 编译阈值
```

> 📖 详细文档: `InvocationCounter/invocationCounter_init.md`, `CompileBroker/compileBroker_init.md`

---

## Q2: C1 和 C2 编译器有什么区别？⭐⭐

### 一句话结论
C1 = **快速编译 + 轻度优化**（适合启动阶段），C2 = **慢速编译 + 深度优化**（适合稳态性能）。

### 源码级回答

| 维度 | C1 (Client Compiler) | C2 (Server Compiler) |
|------|---------------------|---------------------|
| IR 格式 | HIR (High-level) + LIR (Low-level) | Sea-of-Nodes (Ideal Graph) |
| 优化深度 | 内联、常量折叠、null check 消除 | + 逃逸分析、循环优化、向量化、CCP |
| 编译速度 | 快 (~1ms) | 慢 (~10-100ms) |
| 代码质量 | 一般 (2-5x 解释器) | 优秀 (10-30x 解释器) |
| 寄存器分配 | Linear Scan | Chaitin-Briggs (图着色) |
| 内联策略 | 简单深度限制 | should_inline/should_not_inline 正负过滤 |

**C1 流水线:**
```
字节码 → HIR 构建 → HIR 优化 (inline/null_check/CE) → LIR 生成
→ Linear Scan 寄存器分配 → Code 生成 → nmethod
```

**C2 流水线:**
```
字节码 → Parse (构建 Ideal Graph) → Optimize:
  → Iterative GVN (IGVN)
  → Escape Analysis
  → Loop Optimizations (5 轮)
  → CCP (条件常量传播)
  → Macro Expansion
→ Matcher (BURS 指令选择) → Scheduler (全局代码调度)
→ Register Allocation (Chaitin-Briggs) → Peephole → Output
```

> 📖 详细文档: `C1Compiler/c1_compilation_pipeline.md`, `C2Compiler/ch01_c2_compilation_pipeline_and_optimizations.md`

---

## Q3: 方法内联是什么？JVM 怎么决定要不要内联？⭐⭐

### 一句话结论
方法内联 = 把被调用方法的代码**直接嵌入**调用者，省去调用开销。C2 用 **should_inline (正面列表) + should_not_inline (负面列表)** 双重过滤决策。

### 源码级回答

**内联效果:**
```java
// 内联前
int result = computeArea(w, h);  // 方法调用开销: 栈帧创建/参数传递/返回

// 内联后
int result = w * h;  // 直接计算，零调用开销
```

**C2 内联决策 (should_inline):**
```
1. 方法字节码大小 < MaxInlineSize (35 bytes) → 内联
2. 方法字节码大小 < FreqInlineSize (325 bytes) 且调用频繁 → 内联
3. @ForceInline 注解 → 强制内联
4. Intrinsic 方法 → 特殊处理
```

**C2 拒绝内联 (should_not_inline):**
```
1. 方法太大 (> InlineSmallCode, 2000 bytes compiled)
2. 调用深度超过 MaxInlineLevel (9)
3. 内联节点数超过 DesiredMethodLimit (8000)
4. native 方法 (除 Intrinsic)
5. @DontInline 注解
```

**关键参数:**
```
-XX:MaxInlineSize=35          # 无条件内联的字节码上限
-XX:FreqInlineSize=325        # 热点方法内联的字节码上限
-XX:MaxInlineLevel=9          # 最大内联深度
-XX:+PrintInlining            # 打印内联决策
```

> 📖 详细文档: `C2Compiler/ch01_c2_compilation_pipeline_and_optimizations.md`

---

## Q4: 什么是 OSR (On-Stack Replacement)？⭐⭐

### 一句话结论
OSR = **在循环执行过程中**，将正在运行的解释器帧替换为编译后的代码，不需要等方法结束重新进入。解决"长循环方法一直解释执行"的问题。

### 源码级回答

**问题场景:**
```java
void longLoop() {
    for (int i = 0; i < 1000000; i++) {
        // 这个循环会触发回边计数器超标
        // 但方法 longLoop() 本身只调用一次
        // 如果等方法结束再编译 → 循环已经跑完了，没用!
    }
}
```

**OSR 触发:**
```
1. 解释执行循环 → 回边计数器 >= 阈值
2. 触发 OSR 编译请求 (bci = 回边位置)
3. C1/C2 编译整个方法 (以回边位置为入口)
4. 编译完成后，下次到达回边 →
   从解释器帧提取局部变量和操作数栈
   → 构造编译器帧
   → 跳转到编译后代码的 OSR 入口
```

**对应的字节码模板 (goto 回边):**
```
goto → 检查回边计数器 → 超标? → 调用 InterpreterRuntime::frequency_counter_overflow
     → SharedRuntime::OSR_migration_begin()
     → 替换栈帧 → 跳转到 nmethod OSR 入口
```

> 📖 详细文档: `Interpreter/6.0-control-field-array-bytecodes.md`, `CompileBroker/compileBroker_init.md`

---

## Q5: CodeCache 是什么？有什么结构？⭐⭐

### 一句话结论
CodeCache 是存放 JIT 编译代码 (nmethod) 和 Stub 代码的**堆外内存区域**，JDK 11 分为三个堆: NonNMethod/Profiled/NonProfiled。

### 源码级回答

**三堆结构 (Segmented CodeCache):**
```
┌─────────────── CodeCache ─────────────────────┐
│                                                │
│ ┌──────────────────────────────────────┐       │
│ │ NonNMethod Heap (~5MB)               │       │
│ │ → Stub 代码、Adapter、Runtime 调用    │       │
│ └──────────────────────────────────────┘       │
│                                                │
│ ┌──────────────────────────────────────┐       │
│ │ Profiled Heap (~122MB)               │       │
│ │ → C1 编译代码 (带 profiling data)     │       │
│ │ → 可被 C2 替换后回收                  │       │
│ └──────────────────────────────────────┘       │
│                                                │
│ ┌──────────────────────────────────────┐       │
│ │ NonProfiled Heap (~122MB)            │       │
│ │ → C2 编译代码 (最终优化版)            │       │
│ │ → 长期驻留                           │       │
│ └──────────────────────────────────────┘       │
└────────────────────────────────────────────────┘
```

**为什么分三堆?**
1. **减少碎片**: C1 代码(短命) 和 C2 代码(长命) 分开
2. **sweep 效率**: 只扫描 Profiled 堆回收 C1 代码
3. **性能**: NonProfiled 堆的 I-Cache 更友好

**CodeCache 满了会怎样?**
```
→ 停止 JIT 编译! 所有新方法只能解释执行
→ 打印警告: "CodeCache is full. Compiler has been disabled."
→ 解决: -XX:ReservedCodeCacheSize=512m (增大)
```

> 📖 详细文档: `CodeCache/codeCache_init.md`

---

## Q6: 什么是反优化 (Deoptimization)？什么时候会发生？⭐⭐

### 一句话结论
反优化 = **从编译后的代码回退到解释执行**，当编译时的假设不再成立时触发（如类层次变化、uncommon trap）。

### 源码级回答

**触发场景:**
| 场景 | 原因 | 例子 |
|------|------|------|
| Uncommon Trap | 编译器假设某分支不走 | `if (obj instanceof Foo)` 假设总是 Foo，突然来了 Bar |
| Class Hierarchy Change | 虚方法优化失效 | 单一实现内联，新加载了一个子类 |
| retransform/redefine | Agent 修改了字节码 | Arthas trace 修改了已编译方法 |
| Not Entrant | 方法被标记为不可进入 | 新版本编译完成，旧版本废弃 |

**反优化过程:**
```
1. 编译代码执行到 uncommon trap
2. 构造解释器帧 (从编译器帧提取变量)
3. 通过 deopt_entry 进入解释器
4. 继续解释执行
5. 如果反复反优化 → 重新 profiling → 重新编译
```

**关键概念:**
- **Uncommon Trap**: 编译器在不常见路径上插入的陷阱
- **Not Entrant**: 方法的编译版本被标记为不可进入，新调用走解释器
- **Zombie**: 编译版本没有活跃帧了，可以被回收

> 📖 详细文档: `Interpreter/8.0-deopt_entry.md`, `C2Compiler/ch01_c2_compilation_pipeline_and_optimizations.md`

---

## Q7: C2 的 Sea-of-Nodes IR 是什么？⭐⭐⭐

### 一句话结论
Sea-of-Nodes 是 C2 的核心中间表示，**没有显式的基本块**，而是用 **数据流边 + 控制流边** 构成一个图，节点是操作，边是依赖关系。

### 源码级回答

**与传统 IR 的区别:**
```
传统 IR (如 C1): 基本块 → 指令列表 → 有序执行
Sea-of-Nodes (C2): 只有节点和边，调度顺序在后端决定
```

**四大类节点:**
| 分类 | 代表 | 作用 |
|------|------|------|
| 数据节点 | AddI, MulL, LoadP | 计算 |
| 控制节点 | Region, IfTrue, IfFalse | 控制流 |
| 内存节点 | Store, Load, MemBar | 内存访问 |
| 投影节点 | Proj | 多输出节点的某个输出 |

**三大优化钩子 (每个 Node 虚方法):**
```cpp
class Node {
    virtual Node* Ideal(PhaseGVN*, bool);  // 返回优化后的替代节点
    virtual const Type* Value(PhaseGVN*);  // 返回计算的类型/值
    virtual Node* Identity(PhaseGVN*);     // 返回等价的已有节点
};
```

**IGVN 工作列表循环:**
```
while (worklist not empty) {
    node = worklist.pop();
    new_node = node->Ideal(this);     // 尝试优化
    if (new_node != node) {
        replace(node, new_node);
        add_affected_to_worklist();    // 受影响的节点加入工作列表
    }
}
→ 迭代到不动点 (没有更多优化可做)
```

> 📖 详细文档: `C2Compiler/ch01_c2_compilation_pipeline_and_optimizations.md`

---

## Q8: C2 做了哪些循环优化？⭐⭐⭐

### 一句话结论
C2 做 **5 轮循环优化**: 循环展开、循环剥离、范围检查消除、谓词化、SuperWord 向量化，通过 `build_and_optimize` 编排。

### 源码级回答

| 优化 | 效果 | 适用场景 |
|------|------|---------|
| 循环展开 (Unrolling) | 减少分支跳转 + 指令级并行 | 短循环体 |
| 循环剥离 (Peeling) | 第一次迭代特殊处理 | 首次迭代有 null check |
| 范围检查消除 (RCE) | 移除数组越界检查 | 循环内数组访问 |
| 谓词化 (Predication) | 检查提前到循环外 | 循环不变的条件检查 |
| SuperWord 向量化 | SIMD 指令 (AVX/SSE) | 相邻元素相同操作 |

**循环展开示例:**
```java
// 展开前
for (int i = 0; i < 100; i++) {
    a[i] = b[i] + c[i];
}

// 展开 4 次后
for (int i = 0; i < 100; i += 4) {
    a[i]   = b[i]   + c[i];
    a[i+1] = b[i+1] + c[i+1];
    a[i+2] = b[i+2] + c[i+2];
    a[i+3] = b[i+3] + c[i+3];
}
```

> 📖 详细文档: `C2Compiler/ch01_c2_compilation_pipeline_and_optimizations.md`

---

## Q9: CompileBroker 编译线程是怎么工作的？⭐⭐

### 一句话结论
CompileBroker 维护 **C1 和 C2 两个编译队列**，由独立的编译线程消费。编译请求通过 `compile_method()` 入队，编译线程循环取任务执行。

### 源码级回答

```
应用线程:
  → 方法调用/回边计数器超标
  → CompileBroker::compile_method()
  → 检查是否已编译/正在编译
  → 创建 CompileTask 入队

编译线程:
┌───────── C1 编译线程 (×N) ──────┐  ┌───────── C2 编译线程 (×N) ──────┐
│ loop:                           │  │ loop:                           │
│   task = _c1_compile_queue.get()│  │   task = _c2_compile_queue.get()│
│   C1Compiler::compile(task)     │  │   C2Compiler::compile(task)     │
│   → 生成 nmethod               │  │   → 生成 nmethod               │
│   → 安装到 Method              │  │   → 安装到 Method              │
│   → 唤醒等待者                   │  │   → 唤醒等待者                   │
└─────────────────────────────────┘  └─────────────────────────────────┘
```

**编译线程数:**
```
C1 线程数 = 调整后约 1~3
C2 线程数 = 调整后约 2~4 (CPU 核数相关)
总数 = -XX:CICompilerCount (默认约 4)
```

**编译队列优先级:**
- blocking 编译请求 (同步等待结果) 优先级高
- 正常请求按 invocation_count 排序

> 📖 详细文档: `CompileBroker/compileBroker_init.md`

---

## 🎯 面试话术建议

### 如何展示 JIT 编译的源码功底:

> "我看过 C2 编译器的完整流水线。C2 用 Sea-of-Nodes IR，核心优化循环是 IGVN——每个节点有 Ideal/Value/Identity 三个虚方法做变换，工作列表迭代到不动点。内联决策用 should_inline 正面过滤加 should_not_inline 负面过滤，关键参数是 MaxInlineSize=35 和 FreqInlineSize=325。"

> "循环优化我看过 build_and_optimize 的五轮调度：展开、剥离、RCE、谓词化、SuperWord 向量化。范围检查消除特别有意思——它分析循环变量的范围，证明数组访问一定在 bounds 内，就把 ArrayIndexOutOfBoundsException 的检查移到循环外或直接消除。"

> "CodeCache 在 JDK 11 分成三堆，最关键的原因是 C1 编译代码是短命的（会被 C2 替换），放在 Profiled 堆方便回收，C2 代码放 NonProfiled 堆长期驻留，I-Cache 友好。CodeCache 满了会停止编译——我在生产环境见过这个问题，扩大 ReservedCodeCacheSize 就好了。"
