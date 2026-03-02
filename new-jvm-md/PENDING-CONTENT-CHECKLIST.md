# JVM 文档待补充内容清单

> 创建日期: 2026-02-28
> 用途：统一管理所有待补充文档，后续按优先级逐步完善

---

## 一、P0 优先级（面试高频 + 核心概念）

### 1.1 跨模块综合文档 (Integration/)

| 文档路径 | 主题 | 核心内容大纲 | 预计行数 | 依赖模块 |
|----------|------|-------------|---------|---------|
| `Integration/1-Object-Complete-Lifecycle.md` | 一个对象的完整生命周期 | 类加载→分配→初始化→使用→GC→回收 | ~500 | ClassLoading, ObjectModel, G1GC |
| `Integration/2-Method-Invocation-Full-Path.md` | 一次方法调用的完整路径 | 解释执行→编译执行→去优化 | ~400 | Interpreter, Compiler |
| `Integration/3-Young-GC-Full-Stack-View.md` | 一次 Young GC 的全栈视角 | Safepoint→RootScan→Evacuation→RSet | ~500 | Safepoint, G1GC |
| `Integration/4-Thread-Creation-JVM-OS-View.md` | 线程创建的 JVM+OS 视角 | Thread.start→JavaThread→OSThread→pthread | ~400 | Thread |
| `Integration/5-NIO-Network-Request-Full-Path.md` | 一次 NIO 网络请求全路径 | Java NIO→libnio→epoll→内核 | ~400 | NativeLibraries |

### 1.2 实战诊断案例集 (RealWorld-Cases/)

| 文档路径 | 主题 | 核心内容大纲 | 预计行数 | 依赖工具 |
|----------|------|-------------|---------|---------|
| `RealWorld-Cases/01-CPU-High-Case-Study.md` | CPU 100% 排查 | 问题现象 + 工具链 + 根因 + 解决方案 | ~300 | AsyncProfiler, Arthas |
| `RealWorld-Cases/02-Memory-Leak-Case-Study.md` | 内存泄漏排查 | 问题现象 + 工具链 + 根因 + 解决方案 | ~300 | jmap, MAT, Arthas |
| `RealWorld-Cases/03-Lock-Contention-Case-Study.md` | 锁竞争排查 | 问题现象 + 工具链 + 根因 + 解决方案 | ~300 | AsyncProfiler lock, Arthas thread |
| `RealWorld-Cases/04-GC-Troubleshooting-Case-Study.md` | GC 问题排查 | 问题现象 + 工具链 + 根因 + 解决方案 | ~400 | GC 日志, GCEasy |
| `RealWorld-Cases/05-ClassLoading-Issue-Case-Study.md` | 类加载问题排查 | 问题现象 + 工具链 + 根因 + 解决方案 | ~250 | Arthas classloader, sc, jad |
| `RealWorld-Cases/06-Native-Memory-Leak-Case-Study.md` | Native 内存泄漏 | 问题现象 + 工具链 + 根因 + 解决方案 | ~300 | NMT, pmap, gdb |

### 1.3 面试冲刺模块扩展 (Interview/)

| 文档路径 | 主题 | 核心内容大纲 | 预计行数 |
|----------|------|-------------|---------|
| `Interview/3-GC-G1GC-Interview-Guide.md` | G1 GC 面试指南 | 30+ 面试题 + 源码级答案 | ~400 |
| `Interview/4-JIT-Compiler-Interview-Guide.md` | JIT 编译面试指南 | 20+ 面试题 + 源码级答案 | ~350 |
| `Interview/5-ClassLoading-Metaspace-Interview-Guide.md` | 类加载面试指南 | 25+ 面试题 + 源码级答案 | ~350 |
| `Interview/6-JMM-Volatile-Synchronized-Interview-Guide.md` | JMM 面试指南 | 30+ 面试题 + 源码级答案 | ~400 |
| `Interview/7-Performance-Troubleshooting-Interview-Guide.md` | 性能排查面试指南 | 20+ 面试题 + 实战案例 | ~350 |

---

## 二、P1 优先级（进阶深度）

### 2.1 编译器深入 (Compiler/)

| 文档路径 | 主题 | 核心内容大纲 | 预计行数 | 关键源码 |
|----------|------|-------------|---------|---------|
| `Compiler/11-C2-Ideal-Graph-Deep-Dive.md` | C2 Ideal Graph 详细分析 | IR 节点类型、图构建、优化 pass | ~600 | opto/*.cpp |
| `Compiler/12-C2-Register-Allocation.md` | C2 寄存器分配 | 图着色算法、活跃性分析、spill | ~500 | opto/regalloc*.cpp |
| `Compiler/13-Deoptimization-Uncommon-Trap-Deep-Dive.md` | Deoptimization 深入 | 触发条件、栈帧重建、vframeArray | ~500 | deoptimization.cpp |

### 2.2 其他 GC 对比 (Other-GCs/)

| 文档路径 | 主题 | 核心内容大纲 | 预计行数 |
|----------|------|-------------|---------|
| `Other-GCs/1-GC-Overview-and-Comparison.md` | GC 概览与对比 | Serial/Parallel/CMS/G1/ZGC/Shenandoah 对比 | ~400 |
| `Other-GCs/2-ZGC-Overview.md` | ZGC 概览 | 并发整理、colored pointers、load barrier | ~350 |
| `Other-GCs/3-Shenandoah-Overview.md` | Shenandoah 概览 | 并发压缩、brooks pointer | ~350 |

### 2.3 运行时补充 (Runtime/)

| 文档路径 | 主题 | 核心内容大纲 | 预计行数 | 关键源码 |
|----------|------|-------------|---------|---------|
| ~~`Runtime/1-String-StringTable-Deep-Dive.md`~~ | ~~String/StringTable 深入~~ | ~~intern 机制、compact strings~~ | ✅ 已完成 (2026-03-02) | stringTable.cpp, javaClasses.cpp |
| ~~`Runtime/2-Native-Method-Invocation.md`~~ | ~~Native 方法调用框架~~ | ~~JNI wrapper、调用链路~~ | ✅ 已完成 (2026-03-02) | sharedRuntime.cpp, jni*.cpp |
| ~~`Runtime/3-JVMTI-Deep-Dive.md`~~ | ~~JVMTI 深入~~ | ~~事件通知、类转换、agent 接口~~ | ✅ 已完成 (2026-03-02) | jvmti*.cpp |

---

## 三、P2 优先级（完整性）

### 3.1 JVM 启动补充 (JVM-Startup/)

| 文档路径 | 主题 | 核心内容大纲 | 预计行数 |
|----------|------|-------------|---------|
| `JVM-Startup/Phase7-VMThread-Complete.md` | Phase 7：VMThread 完整分析 | 创建、运行、VMOperationQueue | ~400 |
| `JVM-Startup/Phase8-Java-Classes-Init.md` | Phase 8：Java 类初始化 | java.lang.Class/String/Thread | ~350 |
| `JVM-Startup/Phase9-CompilerThread.md` | Phase 9：编译线程启动 | CompileBroker、CompilerThread | ~300 |
| `JVM-Startup/Phase10-Signal-Dispatcher.md` | Phase 10：信号分发器 | Signal Thread、信号处理 | ~300 |

### 3.2 类加载补充 (ClassLoading/)

| 文档路径 | 主题 | 核心内容大纲 | 预计行数 |
|----------|------|-------------|---------|
| `ClassLoading/ConstantPool-Lazy-Resolution.md` | 常量池延迟解析 | resolve_constant_at_impl、符号引用解析 | ~400 |
| `ClassLoading/Bytecode-Verifier.md` | 字节码验证器 | 验证阶段、类型检查、安全性 | ~350 |
| `ClassLoading/ClassLoaderData-Lifecycle.md` | ClassLoaderData 生命周期 | 创建、使用、卸载 | ~300 |

### 3.3 工具进阶 (Tools-Advanced/)

| 文档路径 | 主题 | 核心内容大纲 | 预计行数 |
|----------|------|-------------|---------|
| `Tools-Advanced/1-GDB-Advanced-Techniques.md` | GDB 高级技巧 | 条件断点、脚本、远程调试 | ~350 |
| `Tools-Advanced/2-JITWatch-Usage-Guide.md` | JITWatch 使用指南 | 安装、配置、使用、分析 JIT | ~300 |
| `Tools-Advanced/3-JFR-Production-Monitoring.md` | JFR 生产监控 | 事件配置、数据分析 | ~350 |
| `Tools-Advanced/4-hsdis-Disassembly-Guide.md` | hsdis 反汇编工具 | 安装、使用、分析 JIT 代码 | ~250 |

### 3.4 Metaspace 补充 (Metaspace/)

| 文档路径 | 主题 | 核心内容大纲 | 预计行数 |
|----------|------|-------------|---------|
| `Metaspace/ChunkManager-Deep-Dive.md` | ChunkManager 深入 | 内存块管理、分配策略 | ~400 |
| `Metaspace/SpaceManager-Deep-Dive.md` | SpaceManager 深入 | 空间管理器、类卸载 | ~350 |

---

## 四、统计汇总

### 4.1 按优先级统计

| 优先级 | 文档数 | 预计总行数 | 预计总字数 |
|--------|--------|-----------|-----------|
| P0 | 16 | ~5,800 | ~120,000 |
| P1 | 11 | ~4,850 | ~100,000 |
| P2 | 13 | ~4,200 | ~85,000 |
| **合计** | **40** | **~14,850** | **~305,000** |

### 4.2 按目录统计

| 目录 | 文档数 | 预计行数 |
|------|--------|---------|
| Integration/ | 5 | ~2,200 |
| RealWorld-Cases/ | 6 | ~1,850 |
| Interview/ | 5 | ~1,850 |
| Compiler/ | 3 | ~1,600 |
| Other-GCs/ | 3 | ~1,100 |
| Runtime/ | 3 | ~1,300 |
| JVM-Startup/ | 4 | ~1,350 |
| ClassLoading/ | 3 | ~1,050 |
| Tools-Advanced/ | 4 | ~1,250 |
| Metaspace/ | 2 | ~750 |

---

## 五、执行计划

### 5.1 Week 1（P0 - Integration）

```
Day 1-2: Integration/1-Object-Complete-Lifecycle.md
Day 3:   Integration/2-Method-Invocation-Full-Path.md
Day 4:   Integration/3-Young-GC-Full-Stack-View.md
Day 5:   Integration/4-Thread-Creation-JVM-OS-View.md
Day 6:   Integration/5-NIO-Network-Request-Full-Path.md
Day 7:   补充 Integration/README.md
```

### 5.2 Week 2（P0 - RealWorld-Cases）

```
Day 1-2: RealWorld-Cases/01-CPU-High-Case-Study.md
Day 3:   RealWorld-Cases/02-Memory-Leak-Case-Study.md
Day 4:   RealWorld-Cases/03-Lock-Contention-Case-Study.md
Day 5:   RealWorld-Cases/04-GC-Troubleshooting-Case-Study.md
Day 6:   RealWorld-Cases/05-ClassLoading-Issue-Case-Study.md
Day 7:   RealWorld-Cases/06-Native-Memory-Leak-Case-Study.md
```

### 5.3 Week 3（P0 - Interview 扩展）

```
Day 1: Interview/3-GC-G1GC-Interview-Guide.md
Day 2: Interview/4-JIT-Compiler-Interview-Guide.md
Day 3: Interview/5-ClassLoading-Metaspace-Interview-Guide.md
Day 4: Interview/6-JMM-Volatile-Synchronized-Interview-Guide.md
Day 5: Interview/7-Performance-Troubleshooting-Interview-Guide.md
Day 6-7: 补充 Review
```

### 5.4 Week 4-6（P1 内容）

按顺序完成 Compiler、Other-GCs、Runtime 文档

### 5.5 Week 7-9（P2 内容）

按顺序完成 JVM-Startup、ClassLoading、Tools-Advanced、Metaspace 文档

---

## 六、质量标准

每篇文档必须满足：

- [ ] 遵循 `JVM-Mechanism-Deep-Dive` 规范结构
- [ ] 遵循 `Doc-DataStructure-First` 规则（先数据结构后算法）
- [ ] 遵循 `Source-Code-Depth` 规则（L4+ 级别深度）
- [ ] 包含 Mermaid 图表（至少 2 个）
- [ ] 包含 GDB 验证脚本或理论预期输出
- [ ] 基于本地源码 `/data/workspace/openjdk-cut-new/src/hotspot/`
- [ ] 包含面试级 Q&A（至少 3 个）

---

## 七、更新记录

| 日期 | 操作 | 内容 |
|------|------|------|
| 2026-02-28 | 创建 | 统一待补充内容清单，共 40 篇文档 |

---

## 八、进度跟踪

### P0 进度

| 文档 | 状态 | 完成日期 |
|------|------|---------|
| Integration/1-Object-Complete-Lifecycle.md | ✅ 已完成 | 2026-03-01 |
| Integration/2-Method-Invocation-Full-Path.md | ✅ 已完成 | 2026-03-01 |
| Integration/3-Young-GC-Full-Stack-View.md | ✅ 已完成 | 2026-03-01 |
| Integration/4-Thread-Creation-JVM-OS-View.md | ✅ 已完成 | 2026-03-01 |
| Integration/5-NIO-Network-Request-Full-Path.md | ✅ 已完成 | 2026-03-01 |
| RealWorld-Cases/01-CPU-High-Case-Study.md | ✅ 已完成 | 2026-03-02 |
| RealWorld-Cases/02-Memory-Leak-Case-Study.md | ✅ 已完成 | 2026-03-02 |
| RealWorld-Cases/03-Lock-Contention-Case-Study.md | ✅ 已完成 | 2026-03-02 |
| RealWorld-Cases/04-GC-Troubleshooting-Case-Study.md | ✅ 已完成 | 2026-03-02 |
| RealWorld-Cases/05-ClassLoading-Issue-Case-Study.md | ✅ 已完成 | 2026-03-02 |
| RealWorld-Cases/06-Native-Memory-Leak-Case-Study.md | ✅ 已完成 | 2026-03-02 |
| Interview/3-GC-G1GC-Interview-Guide.md | ✅ 已完成 | 2026-03-01 |
| Interview/4-JIT-Compiler-Interview-Guide.md | ✅ 已完成 | 2026-03-01 |
| Interview/5-ClassLoading-Metaspace-Interview-Guide.md | ✅ 已完成 | 2026-03-01 |
| Interview/6-JMM-Volatile-Synchronized-Interview-Guide.md | ✅ 已完成 | 2026-03-01 |
| Interview/7-Performance-Troubleshooting-Interview-Guide.md | ✅ 已完成 | 2026-03-02 |

### P1 进度

| 文档 | 状态 | 完成日期 |
|------|------|---------|
| Compiler/11-C2-Ideal-Graph-Deep-Dive.md | ⬜ 待开始 | - |
| Compiler/12-C2-Register-Allocation.md | ⬜ 待开始 | - |
| Compiler/13-Deoptimization-Uncommon-Trap-Deep-Dive.md | ⬜ 待开始 | - |
| Other-GCs/1-GC-Overview-and-Comparison.md | ✅ 已完成 | 2026-03-02 |
| Other-GCs/2-ZGC-Overview.md | ✅ 已完成 | 2026-03-02 |
| Other-GCs/3-Shenandoah-Overview.md | ✅ 已完成 | 2026-03-02 |
| Runtime/1-String-StringTable-Deep-Dive.md | ✅ 已完成 | 2026-03-02 |
| Runtime/2-Native-Method-Invocation.md | ✅ 已完成 | 2026-03-02 |
| Runtime/3-JVMTI-Deep-Dive.md | ✅ 已完成 | 2026-03-02 |
| ~~JVM-Startup/Phase7-VMThread-Complete.md~~ | ✅ 已完成 | 2026-03-02 |
| ~~JVM-Startup/Phase8-Java-Classes-Init.md~~ | ✅ 已完成（审查升级） | 2026-03-02 |

### P2 进度

（略，见上方清单）
