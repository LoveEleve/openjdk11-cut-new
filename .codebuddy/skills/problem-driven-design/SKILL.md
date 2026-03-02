---
name: problem-driven-design
description: "问题驱动的源码分析方法论。分析任何框架/系统源码时，必须从问题出发推导数据结构，而非直接甩出数据结构让读者猜。适用于所有语言（Java/C++/Go/Rust 等）和所有框架（Spring/Netty/gRPC/Linux Kernel 等）。核心流程：提出问题 → 推导设计 → 引出结构 → 完整分析 → 算法流程。"
---

# Problem-Driven Design：问题驱动的源码分析方法论

## 核心教训

**直接甩数据结构 = 读者一脸懵 = 无效分析。**

来自 Arthas 源码分析的实战经验：当文档先列出 `ConcurrentWeakKeyHashMap<ClassLoader, Map<String, List<AdviceListener>>>` 这样的结构时，读者的第一反应是"这是什么？为什么这么复杂？"。但如果先问"同一个方法被多个命令同时 watch，怎么管理这些监听器？"，读者自然能推导出"需要一个双层 Map"。

**根本原理**：数据结构不是凭空冒出来的，它是对问题的回答。先给问题，读者才有理解结构的动机和上下文。

---

## 第一原则：问题驱动，推导出数据结构

### 5 步流程（不可跳步）

```
Step 1: 提出问题（这个模块/组件要解决什么问题？）
    ↓
Step 2: 推导设计（要解决这个问题，需要什么信息？信息怎么组织？）
    ↓
Step 3: 引出数据结构（所以设计者创建了 XXX 结构来存储这些信息）
    ↓
Step 4: 完整分析数据结构（全部字段 + 含义 + 大小 + 生命周期）
    ↓
Step 5: 分析算法流程（引用已分析好的数据结构）
```

**核心检验标准**：读者在看到真实数据结构之前，应该已经能猜到"大概需要什么样的结构"。如果做不到，说明推导不够。

---

## 数据结构引出模板

### 核心结构：完整版模板（主角结构必须遵循）

> 适用于：直接承载核心问题解决方案的主角结构。

```markdown
### X.Y <结构名> — <一句话角色>

#### 问题推导

**问题**：<从上层问题自然引出的子问题>

**需要什么信息？**
- <推导过程第一步>
- <推导过程第二步，逐步收紧>
- <推导过程第三步，自然引出结构形状>

**推导出的结构**：<用自然语言描述结构特征>
- <key 是什么、value 是什么、为什么>
- <读者此时应该能猜到大致形状>

#### 真实数据结构

```<language>
// 文件名:行号
// 推导与实际的对应关系注释
<真实源码>
```

**推导 vs 实际**：<对比推导结果和实际结构，解释差异（如有）>

#### 完整分析
（字段列表 / 大小 / 创建位置 / 生命周期 / 值域图）

#### 设计决策
- **为什么用 X 而不是 Y？** <理由>
```

### 辅助结构：简化版模板

> 适用于：被核心结构引用或包装的配角结构，本身逻辑简单，不需要完整推导。

```markdown
### X.Y <结构名> — <一句话角色>

**为什么存在**：<一句话说明它解决什么子问题，或被谁使用>

**字段列表**：
- `field1`：含义
- `field2`：含义

**sizeof**：? 字节
```

> **判断标准**：如果一个结构的存在理由需要超过 2 句话才能说清楚，就用完整版模板。

---

## 正确示例

### 示例 1：Java 框架（Arthas AdviceListenerManager）

```markdown
### 2.3 AdviceListenerManager — 监听器注册表

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
private static final ConcurrentWeakKeyHashMap<ClassLoader, Map<String, List<AdviceListener>>>
    adviceListenerMap = new ConcurrentWeakKeyHashMap<>();
//  外层 key: ClassLoader（WeakKey 避免阻止类卸载）
//  内层 key: "className#methodName|methodDesc"
//  value: 监听器列表
```

**推导 vs 实际**：完全吻合。额外发现 WeakKey 设计——ClassLoader 被 GC 时自动清理，避免内存泄漏。

#### 设计决策
- **为什么用 WeakKey？** 如果 ClassLoader 被 GC（如 webapp 卸载），对应监听器自动清理
- **为什么用 ConcurrentHashMap 而非 synchronized？** 多线程高频查询，读多写少
```

### 示例 2：C++ 系统（JVM ObjectMonitor WaitSet）

```markdown
### 2.5 ObjectMonitor::_WaitSet — 等待队列

#### 问题推导

**问题**：线程调用 Object.wait() 后，在哪里等待？被 notify 时怎么找到它？

**需要什么信息？**
- 需要一个容器存放所有等待中的线程
- notify() 需要从中取出一个线程唤醒
- notifyAll() 需要取出所有线程
- wait() 需要把自己加入（入队操作）
- 等待是无序的（公平性由 notify 策略决定，不由队列顺序决定）

**推导出的结构**：双向循环链表
- 为什么双向？需要从任意位置移除（被中断的线程需要自我移除）
- 为什么循环？方便遍历 notifyAll，不需要特殊处理首尾

#### 真实数据结构

```cpp
// objectMonitor.hpp:180
ObjectWaiter * volatile _WaitSet;    // ★ 链表头指针
// ObjectWaiter 节点：
//   _next, _prev  → 双向链接
//   TState         → TS_WAIT 表示在 WaitSet 中
//   _thread        → 对应的 JavaThread
```

**推导 vs 实际**：吻合。补充发现 `_WaitSetLock` 自旋锁保护并发访问。
```

### 示例 3：Go 框架（假设分析 gRPC Server 连接管理）

```markdown
### 2.2 Server.conns — 连接追踪表

#### 问题推导

**问题**：gRPC Server 需要优雅关闭，怎么知道当前有哪些活跃连接？

**需要什么信息？**
- 需要追踪所有活跃连接，关闭时逐个 drain
- 新连接来了要加入，断开了要移除
- 关闭时要遍历所有连接
- 需要高效的增删查

**推导出的结构**：map[transport]bool
- key = transport（每个连接一个 transport）
- value = bool（只需要存在性，不需要额外信息）
- 为什么不用 slice？删除 O(n)，map 删除 O(1)

#### 真实数据结构

```go
// server.go:120
type Server struct {
    conns    map[transport.ServerTransport]bool  // 活跃连接集合
    // ...
}
```

**推导 vs 实际**：完全吻合。Go 中 `map[T]bool` 就是 set 的惯用法。
```

---

## 错误示例（禁止）

### 错误 1：上来就甩数据结构

```markdown
### AdviceListenerManager

#### 全部字段
Map<ClassLoader, Map<String, List<AdviceListener>>> adviceListenerMap

#### 含义
外层是 ClassLoader，内层是方法标识...
```

**问题**：读者看到第一行就懵了——为什么是双层 Map？为什么 key 是 ClassLoader？没有动机就没有理解。

### 错误 2：推导过于敷衍

```markdown
**问题**：需要管理监听器
**推导**：用一个 Map 存
**真实结构**：ConcurrentWeakKeyHashMap<ClassLoader, Map<String, List<AdviceListener>>>
```

**问题**：推导太跳跃，从"用一个 Map"到"双层 WeakKey Map"之间的思考过程全丢了。

### 错误 3：先贴源码再解释

```markdown
```java
private static final ConcurrentWeakKeyHashMap<ClassLoader, Map<String, List<AdviceListener>>>
    adviceListenerMap = new ConcurrentWeakKeyHashMap<>();
```
上面这个结构用于管理监听器...
```

**问题**：读者被复杂类型签名砸晕了，然后才被告知"用于管理监听器"，已经丧失了理解的最佳时机。

---

## 推导技巧

### 技巧 1：从"最朴素方案"开始，逐步加约束

```
"需要存储线程列表" → List<Thread>?
  → 但需要快速移除 → LinkedList?
  → 但需要从任意位置移除 → 双向链表
  → 但需要首尾相连方便遍历 → 双向循环链表
  → 实际：ObjectWaiter 双向循环链表 ✓
```

### 技巧 2：从"使用场景"反推结构

```
场景：notify() 取一个，notifyAll() 取所有，wait() 加入，中断线程自我移除
  → 需要头插/头取（notify 取头）→ 链表
  → 需要任意位置删除（中断自移除）→ 双向
  → 需要遍历所有（notifyAll）→ 循环
```

### 技巧 3：用"如果不这样会怎样"验证

```
"为什么用 WeakKey？"
  → 如果用强引用 → ClassLoader 永远不会被 GC → webapp 卸载后内存泄漏
  → 所以必须 WeakKey
```

### 技巧 4：从"边界情况"发现隐藏字段

> 专门用于解释"为什么有这个看起来多余的字段"，在 JVM/系统级源码中极其常见。

```
"为什么 ObjectWaiter 有 _prev 和 _next 两个指针？"
  → 只有 _next 能实现单向链表，已经够用了
  → 但中断时需要从任意位置 O(1) 删除
  → 单向链表删除需要找前驱，O(n)
  → 所以必须有 _prev，实现 O(1) 删除
```

**使用场景**：当你看到一个字段，第一反应是"这个字段好像没必要"时，用这个技巧反推它存在的边界情况。

## 完整性标准

推导出数据结构后，仍需完整分析以下 6 项：

| # | 必须项 | 说明 |
|---|--------|------|
| 1 | **全部字段** | 列出所有字段，★ 标注与当前问题直接相关的核心字段 |
| 2 | **每个字段的含义** | 结合问题上下文解释，不是孤立的字典式定义 |
| 3 | **大小/内存布局** | sizeof（C++）/ shallow size（Java, JOL 验证）/ 估算（Go） |
| 4 | **创建位置** | 谁创建的、什么时机、什么条件 |
| 5 | **关键字段生命周期** | 谁设置 → 何时设置 → 设置什么值 → 谁读取 |
| 6 | **值域图（如适用）** | 一个字段有多种编码/状态时画值域图或状态机图 |

**与直接分析的区别**：字段列表中用 ★ 标注与当前问题直接相关的核心字段，非核心字段仍列出但不展开，降低认知负荷。

---

## 算法描述标准

数据结构分析完成后，算法分析必须：

1. **先讲"解决什么问题"**（与 Step 1 问题呼应），再讲"怎么实现"
2. **引用已分析的数据结构**，不重复描述
3. **禁止伪代码**，使用真实源码 + 逐行注释
4. 每个函数 4 要素：**源码位置** + **解决什么问题** + **真实源码+注释** + **设计决策**

---

## 文档结构模板

```markdown
# <模块名> 深度解析

## 第 0 部分：核心原理
### 0.1 本质是什么？（1 句话）
### 0.2 为什么需要？（从根本问题讲起，2-3 段话）
### 0.3 怎么解决？（核心思路 + 关键设计）
### 0.4 为什么这样设计？（"为什么 X 而不是 Y？"格式）

## 第 1 部分：数据结构全景
### 1.1 数据结构清单（表格）
### 1.2 结构 A（⭐ 问题推导 → 引出结构 → 完整分析）
### 1.3 结构 B（同上）
...

## 第 2 部分：算法/流程分析
### 2.1 核心流程概览（Mermaid 图）
### 2.2 流程 A（真实源码 + 逐行注释 + 设计决策）
...

## 第 3 部分：总结
### 3.1 数据结构层面
### 3.2 算法层面
```

---

## 自检清单

写完数据结构分析后逐项检查：

- [ ] 每个结构都有"问题推导"段落？（问题 → 需要什么 → 推导出的结构）
- [ ] 读者看到真实源码前，能猜到大致形状？
- [ ] 推导过程逐步收紧，没有跳跃？
- [ ] 有"推导 vs 实际"对比，解释差异？
- [ ] 核心字段用 ★ 标注？
- [ ] 有"为什么 X 而不是 Y"的设计决策？
- [ ] 完整 6 项分析都覆盖了？

---

## 适用范围

本方法论**语言无关、框架无关**，适用于：

| 领域 | 示例 |
|------|------|
| Java 框架 | Spring / Netty / Arthas / Dubbo / MyBatis |
| C/C++ 系统 | JVM / Linux Kernel / gRPC / Redis |
| Go 框架 | Kubernetes / etcd / gRPC-Go |
| Rust 系统 | Tokio / tikv |
| 前端框架 | React / Vue 内部实现 |

核心不变：**先问题，后结构。先推导，后源码。**

---

## 与其他 Skills 的关系

- **source-code-depth**：管算法**怎么写**（真实源码+逐行注释）。本 skill 管数据结构**怎么引出**。
- **Doc-DataStructure-First**：管顺序（先数据结构后算法）。本 skill 管数据结构分析的**方法论**。

```
本 skill（问题驱动推导数据结构）
  ↓ 推导出结构后
Doc-DataStructure-First（完整分析 6 项）
  ↓ 分析完数据结构后
source-code-depth（算法用真实源码+逐行注释）
```
