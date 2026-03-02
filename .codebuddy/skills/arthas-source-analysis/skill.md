# Arthas 源码分析 Skill

## 本地源码路径（重要！分析时必须使用本地源码）

| 项目 | 本地路径 | 版本 | 说明 |
|------|----------|------|------|
| **Arthas** | `/data/workspace/arthas-4.1.2/arthas/core/src/main/java/` | 4.1.2 | JavaAgent 诊断工具 |
| **async-profiler** | `/data/workspace/async-profiler/src/` | 2.9 | C++ 性能分析器 |
| **OpenJDK** | `/data/workspace/openjdk-cut-new/src/hotspot/share/` | 11 | JVM 源码 |

**关键源码文件位置**：

```
/data/workspace/arthas-4.1.2/arthas/core/src/main/java/com/taobao/arthas/core/
├── server/ArthasBootstrap.java              # 启动入口
├── command/monitor200/ProfilerCommand.java  # 性能分析命令
├── command/klass100/ClassLoaderCommand.java # 类加载器命令
├── command/monitor200/ThreadCommand.java    # 线程分析命令
├── advisor/Enhancer.java                    # 字节码增强核心
└── advisor/SpyAPI.java                      # Spy 拦截器

/data/workspace/async-profiler/src/
├── profiler.cpp        # 采样器核心
├── profiler.h          # 采样器头文件
├── perfEvents_linux.cpp # Linux perf_events 实现
├── stackWalker.cpp     # 栈回溯实现
└── flameGraph.cpp      # 火焰图生成

/data/workspace/openjdk-cut-new/src/hotspot/share/
├── runtime/           # 运行时核心
├── gc/g1/             # G1 GC 实现
├── oops/              # 对象头、Klass 等
└── classfile/         # 类文件加载
```

## 适用场景
- 分析 Arthas 字节码增强原理
- 分析 Arthas 各类诊断命令实现
- 理解 JavaAgent + Instrumentation 机制
- 分析 async-profiler 采样原理
- 面试准备：性能诊断工具相关
- **必须基于本地源码分析，禁止 Web 搜索**

## 核心方法论

### ⭐ 第一原则：问题驱动，推导出数据结构

**分析任何模块/机制时，必须按以下顺序：**

```
Step 1: 提出问题（这个模块要解决什么问题？）
    ↓
Step 2: 推导设计（要解决这个问题，需要什么信息？信息怎么组织？）
    ↓
Step 3: 引出数据结构（所以设计者创建了 XXX 结构来存储这些信息）
    ↓
Step 4: 完整分析数据结构（全部字段 + 含义 + sizeof + 生命周期）
    ↓
Step 5: 分析算法流程（引用已分析好的数据结构）
```

**核心理念**：读者应该在看到数据结构之前，已经能猜到"大概需要什么样的结构"。数据结构不是凭空冒出来的，而是从问题中自然推导出来的。

#### 正确示例

```markdown
### AdviceListenerManager — 监听器注册表

#### 问题推导

**问题**：同一个方法可能被多个命令同时 watch/trace，怎么管理这些监听器？

**需要什么信息？**
- 需要一个注册表：给定一个方法，能快速找到所有监听它的 Listener
- 方法的唯一标识是什么？类名 + 方法名 + 方法描述符
- 但等等——同名类可能被不同 ClassLoader 加载（如 Tomcat 多 webapp）
- 所以需要加一层隔离：ClassLoader → (方法标识 → 监听器列表)

**推导出的结构**：双层 Map
- 外层 key = ClassLoader（隔离不同类加载器）
- 内层 key = "className#methodName|methodDesc"（方法唯一标识）
- value = List<AdviceListener>（同一方法的多个监听器）

#### 真实数据结构

```java
// AdviceListenerManager.java:25-30
// 推导与实际完全吻合：
private static final ConcurrentWeakKeyHashMap<ClassLoader, Map<String, List<AdviceListener>>>
    adviceListenerMap = new ConcurrentWeakKeyHashMap<>();
//  外层 key: ClassLoader（WeakKey 避免阻止类卸载）
//  内层 key: "className#methodName|methodDesc"
//  value: 监听器列表
```

**为什么用 WeakKey？** 如果 ClassLoader 被 GC（如 webapp 卸载），对应的所有监听器自动清理，避免内存泄漏。
```

#### 错误示例（禁止）

```markdown
### AdviceListenerManager

#### 全部字段
Map<ClassLoader, Map<String, List<AdviceListener>>> adviceListenerMap

#### 含义
外层是 ClassLoader，内层是方法标识...
```

↑ 这种"先甩数据结构再解释"的写法，读者看到第一行就懵了：为什么是双层 Map？为什么 key 是 ClassLoader？没有动机就没有理解。

### 源码使用原则

**必须基于本地源码分析**：
- ✅ 所有分析结论必须从本地源码得出
- ✅ 使用 `read_file` 工具读取本地文件
- ✅ 引用真实源码文件路径和行号
- ❌ 禁止通过网络搜索获取信息
- ❌ 禁止使用"简化示意"代替真实源码

### 数据结构分析的完整性标准

推导出数据结构后，仍然需要完整分析以下 6 项：

| # | 必须项 | 说明 |
|---|--------|------|
| 1 | **全部字段** | 列出所有字段，标注 ★ 表示核心字段（与当前问题直接相关的） |
| 2 | **每个字段的含义** | 结合问题上下文解释，不是孤立的字典式定义 |
| 3 | **sizeof** | 精确内存布局（CompressedOops ON） |
| 4 | **创建位置** | 谁创建的、什么时机 |
| 5 | **关键字段生命周期** | 谁设置 → 何时设置 → 设置什么值 → 谁读取 |
| 6 | **值域图（如适用）** | 一个字段有多种编码时画值域图 |

**与旧规范的区别**：字段列表中用 ★ 标注与当前问题直接相关的核心字段，非核心字段仍然列出但不展开，降低认知负荷。

### 算法描述标准

禁止伪代码，必须真实源码 + 逐行注释 + 设计决策。每个函数 4 要素：
1. **源码文件:行号**
2. **解决什么问题**（一句话，与 Step 1 的问题呼应）
3. **真实源码 + 逐行注释**
4. **设计决策**（为什么这样做而不是那样做）

## 文档结构规范

```markdown
# <模块名> 深度解析

## 第 0 部分：核心原理
### 0.1 本质是什么？（1 句话）
### 0.2 为什么需要？（根本问题，2-3 段话，不堆砌场景列表）
### 0.3 怎么解决？（核心思路 + 关键设计，不堆砌图表）
### 0.4 为什么这样设计？（"为什么 X 而不是 Y？"格式）

## 第 1 部分：数据结构全景
### 1.1 数据结构清单（表格）
### 1.2 结构 A（⭐ 问题推导 → 引出结构 → 完整分析）
### 1.3 结构 B（同上）
...

## 第 2 部分：算法/流程分析
### 2.1 核心流程概览（Mermaid 流程图）
### 2.2 流程 A 详细分析（真实源码 + 逐行注释）
...

## 第 3 部分：总结
### 3.1 数据结构层面
### 3.2 算法层面
```

### 数据结构引出模板（每个结构必须遵循）

```markdown
### X.Y 结构名 — 一句话角色

#### 问题推导
**问题**：<从上层问题自然引出的子问题>
**需要什么信息？** <推导过程，让读者自己能想到大概需要什么>
**推导出的结构**：<用自然语言描述结构特征，读者此时应该能猜到大致形状>

#### 真实数据结构
```java
// 文件名:行号
// 推导与实际的对应关系
```

#### 完整分析（6 项）
... sizeof / 创建位置 / 生命周期 ...

#### 设计决策
- 为什么用 X 而不是 Y？
```

## 图表规范

**必须使用 Mermaid**，禁止 ASCII 艺术线条。

| 类型 | 用途 |
|------|------|
| `flowchart` | 方法执行流程、初始化流程 |
| `sequenceDiagram` | 调用链路、交互过程 |
| `classDiagram` | 数据结构关系、继承关系 |
| `stateDiagram` | 生命周期、状态转换 |

## 已完成分析文档

文档位于 `/data/workspace/openjdk-cut-new/new-jvm-md/Arthas-new/`，共 31 篇。
详见 `00-Arthas-Complete-Outline.md` 总索引。

## 相关 Skills

- `source-code-depth` - 算法描述源码级深度
- `jvm-mastery` - JVM 源码分析
