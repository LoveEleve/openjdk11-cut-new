# 编译器 (Compiler) 重要文件

> **源码路径**：`src/hotspot/share/c1/`, `src/hotspot/share/opto/`, `src/hotspot/share/ci/`, `src/hotspot/share/compiler/`  
> **重要程度**：⭐⭐⭐⭐⭐

---

## 编译器框架

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `compiler/compileBroker.cpp` | ⭐⭐⭐⭐⭐ | 编译请求分发和管理 |
| `compiler/compileBroker.hpp` | ⭐⭐⭐⭐⭐ | 编译代理接口 |
| `compiler/compilationPolicy.cpp` | ⭐⭐⭐⭐⭐ | 编译策略决策 |
| `compiler/compilationPolicy.hpp` | ⭐⭐⭐⭐⭐ | 编译策略接口 |
| `compiler/methodLiveness.cpp` | ⭐⭐⭐⭐ | 方法活跃性分析 |

---

## C1 编译器 (Client JIT)

### 核心

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `c1/c1_Compiler.cpp` | ⭐⭐⭐⭐⭐ | C1 编译器入口 |
| `c1/c1_Compiler.hpp` | ⭐⭐⭐⭐⭐ | C1 编译器接口 |
| `c1/c1_Compilation.cpp` | ⭐⭐⭐⭐⭐ | C1 编译过程管理 |
| `c1/c1_Compilation.hpp` | ⭐⭐⭐⭐⭐ | 编译过程接口 |
| `c1/c1_CompilationUnit.cpp` | ⭐⭐⭐⭐ | 编译单元 |

### IR 构建

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `c1/c1_GraphBuilder.cpp` | ⭐⭐⭐⭐⭐ | IR 图构建 |
| `c1/c1_GraphBuilder.hpp` | ⭐⭐⭐⭐⭐ | 图构建器接口 |
| `c1/c1_Representation.cpp` | ⭐⭐⭐⭐ | 中间表示 |

### LIR 生成

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `c1/c1_LIRGenerator.cpp` | ⭐⭐⭐⭐⭐ | LIR 生成 |
| `c1/c1_LIRGenerator.hpp` | ⭐⭐⭐⭐⭐ | LIR 生成器接口 |
| `c1/c1_LIR.cpp` | ⭐⭐⭐⭐⭐ | LIR 表示和操作 |
| `c1/c1_LIR.hpp` | ⭐⭐⭐⭐⭐ | LIR 接口 |
| `c1/c1_LIROperands.cpp` | ⭐⭐⭐⭐ | LIR 操作数 |

### LIR 汇编

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `c1/c1_LIRAssembler.cpp` | ⭐⭐⭐⭐⭐ | LIR 汇编（生成机器码） |
| `c1/c1_LIRAssembler.hpp` | ⭐⭐⭐⭐⭐ | LIR 汇编器接口 |
| `c1/c1_MacroAssembler.cpp` | ⭐⭐⭐⭐ | C1 宏汇编器 |

### 寄存器分配

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `c1/c1_LinearScan.cpp` | ⭐⭐⭐⭐⭐ | 线性扫描寄存器分配 |
| `c1/c1_LinearScan.hpp` | ⭐⭐⭐⭐⭐ | 线性扫描接口 |

### 优化

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `c1/c1_Optimizer.cpp` | ⭐⭐⭐⭐ | C1 优化 passes |
| `c1/c1_Canonicalizer.cpp` | ⭐⭐⭐⭐ | 规范化优化 |
| `c1/c1_RangeCheckElimination.cpp` | ⭐⭐⭐⭐ | 范围检查消除 |
| `c1/c1_ValueMap.cpp` | ⭐⭐⭐⭐ | 值映射优化 |
| `c1/c1_CodePeephole.cpp` | ⭐⭐⭐⭐ | 窥孔优化 |

### 运行时支持

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `c1/c1_Runtime1.cpp` | ⭐⭐⭐⭐⭐ | C1 运行时支持 |
| `c1/c1_Runtime1.hpp` | ⭐⭐⭐⭐⭐ | C1 运行时接口 |

### IR 表示

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `c1/c1_Instruction.cpp` | ⭐⭐⭐⭐ | C1 指令定义 |
| `c1/c1_Instruction.hpp` | ⭐⭐⭐⭐ | 指令接口 |
| `c1/c1_BlockBegin.cpp` | ⭐⭐⭐⭐ | 基本块开始 |
| `c1/c1_ValueStack.cpp` | ⭐⭐⭐⭐ | 值栈 |

---

## C2 编译器 (Server JIT)

### 核心

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `opto/compile.cpp` | ⭐⭐⭐⭐⭐ | C2 编译核心，编译过程管理 |
| `opto/compile.hpp` | ⭐⭐⭐⭐⭐ | 编译接口 |
| `opto/c2compiler.cpp` | ⭐⭐⭐⭐⭐ | C2 编译器入口 |
| `opto/c2compiler.hpp` | ⭐⭐⭐⭐⭐ | C2 接口 |

### IR 构建

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `opto/graphKit.cpp` | ⭐⭐⭐⭐⭐ | IR 图构建工具集 |
| `opto/graphKit.hpp` | ⭐⭐⭐⭐⭐ | 图构建器接口 |
| `opto/parse1.cpp` | ⭐⭐⭐⭐⭐ | 字节码解析生成 IR (part 1) |
| `opto/parse2.cpp` | ⭐⭐⭐⭐⭐ | 字节码解析生成 IR (part 2) |
| `opto/parse3.cpp` | ⭐⭐⭐⭐⭐ | 字节码解析生成 IR (part 3) |

### 节点定义

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `opto/node.hpp` | ⭐⭐⭐⭐⭐ | 节点基类定义 |
| `opto/callnode.cpp` | ⭐⭐⭐⭐⭐ | 调用节点定义 |
| `opto/callnode.hpp` | ⭐⭐⭐⭐⭐ | 调用节点接口 |
| `opto/cfgnode.cpp` | ⭐⭐⭐⭐⭐ | 控制流图节点 |
| `opto/cfgnode.hpp` | ⭐⭐⭐⭐⭐ | CFG 节点接口 |
| `opto/memnode.cpp` | ⭐⭐⭐⭐⭐ | 内存操作节点 |
| `opto/memnode.hpp` | ⭐⭐⭐⭐⭐ | 内存节点接口 |
| `opto/addnode.cpp` | ⭐⭐⭐⭐⭐ | 加法节点 |
| `opto/mulnode.cpp` | ⭐⭐⭐⭐⭐ | 乘法节点 |
| `opto/divnode.cpp` | ⭐⭐⭐⭐⭐ | 除法节点 |
| `opto/ifnode.cpp` | ⭐⭐⭐⭐⭐ | 条件分支节点 |

### 循环优化

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `opto/loopnode.cpp` | ⭐⭐⭐⭐⭐ | 循环优化 |
| `opto/loopnode.hpp` | ⭐⭐⭐⭐⭐ | 循环节点接口 |
| `opto/loopTransform.cpp` | ⭐⭐⭐⭐⭐ | 循环变换 |
| `opto/loopPredicate.cpp` | ⭐⭐⭐⭐⭐ | 循环谓词分发 |
| `opto/loopopts.cpp` | ⭐⭐⭐⭐⭐ | 循环优化 |
| `opto/idealLoop.cpp` | ⭐⭐⭐⭐⭐ | 理想循环分析 |

### 寄存器分配

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `opto/chaitin.cpp` | ⭐⭐⭐⭐⭐ | 寄存器分配（Chaitin 算法） |
| `opto/chaitin.hpp` | ⭐⭐⭐⭐⭐ | 寄存器分配接口 |
| `opto/regalloc.cpp` | ⭐⭐⭐⭐⭐ | 寄存器分配器 |

### 指令匹配

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `opto/matcher.cpp` | ⭐⭐⭐⭐⭐ | 指令匹配 |
| `opto/matcher.hpp` | ⭐⭐⭐⭐⭐ | 匹配器接口 |
| `opto/machnode.cpp` | ⭐⭐⭐⭐⭐ | 机器码节点 |
| `opto/machnode.hpp` | ⭐⭐⭐⭐⭐ | 机器节点接口 |
| `opto/mach理想.cpp` | ⭐⭐⭐⭐ | 理想机器节点 |

### 优化

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `opto/escape.cpp` | ⭐⭐⭐⭐⭐ | 逃逸分析 |
| `opto/escape.hpp` | ⭐⭐⭐⭐⭐ | 逃逸分析接口 |
| `opto/gcm.cpp` | ⭐⭐⭐⭐⭐ | 全局代码移动优化 |
| `opto/superword.cpp` | ⭐⭐⭐⭐⭐ | SIMD 向量化优化 |
| `opto/library_call.cpp` | ⭐⭐⭐⭐⭐ | intrinsics 实现 |
| `opto/ifconv.cpp` | ⭐⭐⭐⭐ | 条件转换优化 |

### 类型系统

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `opto/type.cpp` | ⭐⭐⭐⭐⭐ | 类型系统实现 |
| `opto/type.hpp` | ⭐⭐⭐⭐⭐ | 类型接口 |
| `opto/typeArrayOop.cpp` | ⭐⭐⭐⭐ | 类型数组操作 |

### 机器码生成

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `opto/output.cpp` | ⭐⭐⭐⭐⭐ | 机器码输出 |
| `opto/output.hpp` | ⭐⭐⭐⭐⭐ | 输出接口 |
| `opto/machPrologUEP.cpp` | ⭐⭐⭐⭐ | 函数序言 |
| `opto/machEpilog.cpp` | ⭐⭐⭐⭐ | 函数尾声 |

### 运行时支持

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `opto/runtime.cpp` | ⭐⭐⭐⭐⭐ | C2 运行时支持 |
| `opto/runtime.hpp` | ⭐⭐⭐⭐⭐ | C2 运行时接口 |

---

## 编译器接口 (CI)

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `ci/ciEnv.cpp` | ⭐⭐⭐⭐⭐ | 编译器环境接口 |
| `ci/ciEnv.hpp` | ⭐⭐⭐⭐⭐ | CI 环境接口 |
| `ci/ciMethod.cpp` | ⭐⭐⭐⭐⭐ | 方法的编译器视图 |
| `ci/ciMethod.hpp` | ⭐⭐⭐⭐⭐ | CI 方法接口 |
| `ci/ciMethodData.cpp` | ⭐⭐⭐⭐⭐ | 方法 profiling 数据 |
| `ci/ciMethodData.hpp` | ⭐⭐⭐⭐⭐ | CI 方法数据接口 |
| `ci/ciInstanceKlass.cpp` | ⭐⭐⭐⭐⭐ | 类在编译器中的表示 |
| `ci/ciInstanceKlass.hpp` | ⭐⭐⭐⭐⭐ | CI 类接口 |
| `ci/ciObjectFactory.cpp` | ⭐⭐⭐⭐ | CI 对象工厂 |
| `ci/ciTypeFlow.cpp` | ⭐⭐⭐⭐ | 类型流分析 |
| `ci/bcEscapeAnalyzer.cpp` | ⭐⭐⭐⭐ | 字节码逃逸分析 |
| `ci/ciReplay.cpp` | ⭐⭐⭐⭐ | 编译重放实现 |
| `ci/ciStreams.cpp` | ⭐⭐⭐⭐ | CI 字节码流 |
| `ci/ciConstant.cpp` | ⭐⭐⭐⭐ | CI 常量 |

---

## 核心调用链

### C1 编译流程
```
CompileBroker::compile_method()
  → C1Compiler::compile_method()
    → Compilation::Compilation()
      → GraphBuilder::build_graph()
        → LIRGenerator::generate()
          → LinearScan::allocate_registers()
            → LIRAssembler::emit_code()
              → CodeBuffer::finalize()
```

### C2 编译流程
```
CompileBroker::compile_method()
  → C2Compiler::compile_method()
    → Compile::Compile()
      → Parse::Parse()  // 构建 Ideal IR
        → PhaseIdealLoop::loop_optimize()  // 循环优化
          → PhaseRegAlloc::register_allocate()  // 寄存器分配
            → Matcher::match()  // 指令匹配
              → PhaseOutput::output()  // 机器码输出
```

---

## 编译决策

### 热点检测
```
method invocation counter++ 
  → counter > CompileThreshold 
    → CompilationRequest
      → CompileBroker::compile_method()
        → 选择 C1 或 C2
```

### OSR (On-Stack Replacement)
```
loop counter++ 
  → loop > OnStackReplaceThreshold 
    → generate_osr_entry()
      → Compilation::compile_method()
        → 生成 OSR 代码
```

---

## 学习建议

1. **C1 优先级**：c1_Compiler.cpp, c1_Compilation.cpp, c1_GraphBuilder.cpp, c1_LinearScan.cpp
2. **C2 优先级**：compile.cpp, parse1.cpp, node.hpp, loopnode.cpp, escape.cpp, matcher.cpp
3. **CI 优先级**：ciEnv.cpp, ciMethod.cpp, ciMethodData.cpp

---

*C2 编译器是 JVM 最复杂的模块之一，理解 C2 的 IR 和优化是成为 JVM 专家的关键。*
