# OpenJDK 11 手写学习路线建议

> 目标：通过"手抄 + 讲解 + 吃透"的方式，系统性地掌握 OpenJDK 11 / HotSpot JVM 源码。

---

## 核心思路：沿"JVM 启动 → 第一行 Java 代码执行"这条主线切入

OpenJDK 11 的 hotspot 模块众多，但它们**不是平行的**，而是有严格的依赖顺序。
随机挑一个模块开始，会发现到处是不认识的数据结构，寸步难行。

**正确做法：沿着"JVM 启动 → 第一行 Java 代码执行"这条主线，按依赖顺序逐层吃透。**

---

## 推荐学习路线（7 个阶段）

```
阶段 1：基础设施层
  utilities/ + memory/ 基础
  Arena、链表、哈希表、OS 抽象
        ↓
阶段 2：对象模型层  ⭐ 最重要
  oops/
  oop、Klass、InstanceKlass、Method
        ↓
阶段 3：VM 启动
  runtime/thread.cpp
  Threads::create_vm()
        ↓
阶段 4：类加载
  classfile/
  ClassFileParser → InstanceKlass
        ↓
阶段 5：解释器
  interpreter/
  模板解释器、字节码分发
        ↓
阶段 6：内存管理 / GC
  memory/ + gc/g1/
  对象分配、G1 GC
        ↓
阶段 7：JIT 编译（可选）
  c1/ + opto/
  C1/C2 编译流程
```

---

## 各阶段详细说明

### 阶段 1：基础设施（1-2 周）

**为什么先学？** 后面所有代码都用这些基础结构，不认识 `Arena`、`GrowableArray`、`ResourceMark` 就看不懂任何代码。

| 文件 | 核心内容 |
|------|---------|
| `utilities/globalDefinitions.hpp` | JVM 的基本类型定义（`jint`、`jlong`、`oop` 等） |
| `utilities/growableArray.hpp` | 动态数组，JVM 里到处用 |
| `memory/arena.cpp` | Arena 内存分配器，理解 JVM 的内存管理哲学 |
| `memory/resourceArea.cpp` | ResourceMark/ResourceArea，临时内存管理 |
| `utilities/hashtable.hpp` | 哈希表，类加载器用它存类 |

**起点文件**：`utilities/globalDefinitions.hpp`（~1000 行，全是类型定义，非常适合入门）

---

### 阶段 2：对象模型（2-3 周）⭐ 最重要，建议从这里开始

**为什么先学？** JVM 里一切都是对象，`oop`/`Klass`/`Method` 是整个 JVM 的"骨架"，不懂这个，类加载、GC、解释器全看不懂。

| 文件 | 核心内容 |
|------|---------|
| `oops/oop.hpp` | Java 对象在 JVM 内部的表示 |
| `oops/klass.hpp` | 类的元数据基类 |
| `oops/instanceKlass.hpp` | 普通 Java 类的元数据（最重要！） |
| `oops/method.hpp` | 方法的元数据 |
| `oops/constantPool.hpp` | 常量池 |

**起点文件**：`oops/oop.hpp`（先搞清楚一个 Java 对象在内存里长什么样）

> **当前建议**：你已有 ObjectMonitor、ClassLoading、G1GC 的文档积累，
> 建议从阶段 2 重新系统地过一遍，把 `oops/` 目录吃透，
> 它是所有其他模块的基础，吃透后看其他模块会快很多。

---

### 阶段 3：VM 启动（1-2 周）

**为什么学？** 这是整个 JVM 的"main 函数"，把前两个阶段的所有数据结构串起来。

| 文件 | 核心内容 |
|------|---------|
| `runtime/thread.cpp` | `Threads::create_vm()` —— JVM 启动的总入口 |
| `runtime/vm_operations.cpp` | VM 操作框架 |
| `runtime/init.cpp` | 各子系统初始化顺序 |

**起点函数**：`Threads::create_vm()`

---

### 阶段 4：类加载（2-3 周）

**为什么学？** 类加载是 JVM 把 `.class` 文件变成 `InstanceKlass` 的过程，是阶段 2 对象模型的"生产线"。

| 文件 | 核心内容 |
|------|---------|
| `classfile/classFileParser.cpp` | 解析 `.class` 文件（260KB，最大的文件之一！） |
| `classfile/classLoader.cpp` | 类加载器实现 |
| `classfile/systemDictionary.cpp` | 类的全局注册表 |

**起点函数**：`ClassFileParser::parse_stream()`

---

### 阶段 5：解释器（2-3 周）

**为什么学？** 解释器是 Java 字节码执行的核心，理解它才能理解 Java 代码是怎么"跑起来"的。

| 文件 | 核心内容 |
|------|---------|
| `interpreter/templateInterpreter.cpp` | 模板解释器框架 |
| `cpu/x86/templateInterpreterGenerator_x86.cpp` | x86 字节码处理器生成 |
| `cpu/x86/templateTable_x86.cpp` | 每条字节码的实现（141KB！） |

**起点**：先理解"模板解释器"的设计思想（为什么不用 switch-case，而是生成机器码？）

---

### 阶段 6：内存管理 + G1 GC（3-4 周）

**为什么学？** 已有 G1 GC 的文档积累，这是自然的延伸。

| 文件 | 核心内容 |
|------|---------|
| `gc/g1/g1CollectedHeap.cpp` | G1 堆的核心实现 |
| `gc/g1/g1HeapRegion.cpp` | Region 管理 |
| `memory/allocation.cpp` | 对象分配快慢路径 |

---

### 阶段 7：JIT 编译（4+ 周，可选）

这是最复杂的部分，建议最后学，或者根据兴趣选择性学习。

| 文件 | 核心内容 |
|------|---------|
| `c1/c1_Compilation.cpp` | C1 编译器入口 |
| `opto/compile.cpp` | C2 编译器入口 |
| `compiler/compileBroker.cpp` | 编译任务调度 |

---

## 学习方法（每抄一个文件按此顺序）

```
1. 先问"这个文件解决什么问题？"（不要直接看代码）
2. 看头文件（.hpp），理解数据结构
3. 看实现文件（.cpp），理解算法
4. 用 GDB 验证关键数据结构的 sizeof 和字段偏移
5. 写文档（按 new-jvm-md/ 下的文档格式）
```

> **不要试图一次性看完一个大文件**（比如 `classFileParser.cpp` 有 260KB），
> 要按功能切片，每次只看一个"问题"的解决方案。

---

## 当前已有积累

| 文档 | 位置 | 对应阶段 |
|------|------|---------|
| ObjectMonitor 深度解析 | `new-jvm-md/JVM-Core-Objects/05-ObjectMonitor-Deep-Dive.md` | 阶段 2/3 |
| ClassLoading 时间线 | `new-jvm-md/JVM-Core-Objects/06-ClassLoading-Timeline.md` | 阶段 4 |
| G1 GC 数据结构全景 | `new-jvm-md/G1GC/0-G1-DataStructure-Map.md` | 阶段 6 |
| GC Trigger 分析 | `new-jvm-md/G1GC/0_1_GC_Trigger.md` | 阶段 6 |

---

## 下一步行动

**立即可以开始的第一个文件**：`oops/oop.hpp`

目标：搞清楚"一个 Java 对象在 JVM 内存里长什么样"，包括：
- `markWord`（对象头）的结构
- `Klass*`（类型指针）的作用
- 对象的内存布局（header + fields）
- 压缩指针（CompressedOops）的影响
