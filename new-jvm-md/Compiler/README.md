# Compiler 目录文档索引

> 基于 OpenJDK 11 源码，标准环境：`-Xms8g -Xmx8g -XX:+UseG1GC`

---

## 主文档（推荐阅读）

| 文件 | 主题 | 状态 |
|------|------|------|
| `1-Compilation-Trigger-Hot-Method-Detection.md` | 编译触发与热点方法检测（InvocationCounter/MethodCounters/TieredThresholdPolicy） | ✅ 完整 |
| `2-CompileBroker-Compilation-Dispatch.md` | CompileBroker 编译请求分发（CompileQueue/CompileTask/CompilerThread） | ✅ 完整 |
| `3-C1-Compilation-Pipeline.md` | C1 编译管道（HIR→LIR→机器码，5 阶段） | ✅ 完整 |
| `4-C2-Ideal-Graph.md` | C2 Sea-of-Nodes IR（Node/Type/IGVN） | ✅ 完整 |
| `5-C2-Core-Optimizations.md` | C2 核心优化（循环优化/CCP/宏节点展开） | ✅ 完整 |
| `6-OSR-On-Stack-Replacement.md` | OSR 栈上替换（热循环编译/帧转换） | ✅ 完整 |
| `7-Deoptimization.md` | 去优化（vframeArray/UnrollBlock/帧重建） | ✅ 完整 |
| `8-Escape-Analysis-Scalar-Replacement.md` | 逃逸分析与标量替换（ConnectionGraph/BCEscapeAnalyzer） | ✅ 完整 |
| `compileBroker_init.md` | compileBroker_init() 初始化流程（Phase 1 预初始化） | ✅ 完整 |

---

## 冗余文档（内容已被主文档覆盖）

| 文件 | 与哪个主文档重叠 | 说明 |
|------|----------------|------|
| `c1_compilation_pipeline.md` | `3-C1-Compilation-Pipeline.md` | 早期版本，内容更详细（含 Runtime1 桩系统、源文件索引），但缺少第 0 节核心原理；已补充第 0 节和数据结构完整分析 |
| `ch01_c2_compilation_pipeline_and_optimizations.md` | `4-C2-Ideal-Graph.md` + `5-C2-Core-Optimizations.md` | 早期版本，内容更全面（含完整优化管道），但缺少第 0 节核心原理；已补充第 0 节和 Node 数据结构完整分析 |
| `escape_analysis.md` | `8-Escape-Analysis-Scalar-Replacement.md` | 早期版本，内容更详细（含 GDB 验证指南、面试题），但缺少第 0 节核心原理；已补充第 0 节和数据结构完整分析 |

> **建议**：阅读主文档（1-8 号）获取规范化内容；如需更多细节（如 Runtime1 桩系统、完整优化管道），参考对应的早期版本文档。

---

## 阅读顺序

```
编译触发 → CompileBroker 初始化 → CompileBroker 分发
    ↓
C1 编译管道（L1-L3）
    ↓
C2 Ideal Graph → C2 核心优化 → 逃逸分析
    ↓
OSR 栈上替换 → 去优化
```

*最后更新: 2026-03-02*
