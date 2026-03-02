---
name: source-code-depth
description: "源码深度分析规范。当分析 JVM 或 C/C++ 源码项目时，确保算法描述达到源码级深度而非伪代码级别。此 skill 源自 Day 34 同步机制文档的返工教训：第一版用伪代码描述算法被批评为'没有深度'，第三版用 19 个函数的完整源码+逐行注释替代后获得认可。"
---

# Source-Code-Depth：源码级深度分析规范

## 核心教训（来自 Day 34 同步机制文档的返工）

**用伪代码/自然语言概括算法流程 = 没有深度 = 必然返工。**

Day 34 文档经历了三个阶段：

| 阶段 | 做法 | 结果 |
|------|------|------|
| 第一版 | 数据结构完整 + 算法用伪代码描述 | ❌ 用户批评"没有深度" |
| 第二版要求 | "先不要 GDB，把所有源码先分析清楚，**深度深度深度**！" | 要求推翻重写 |
| 第三版 | 19 个函数全部**真实源码** + **逐行注释** + **设计解释** | ✅ 通过 |

**根本问题**：用伪代码描述 `wait()` 的 7 行概括 vs 真实源码 200+ 行带注释，信息量差 30 倍。伪代码本质上是在**偷懒**，牺牲了真正的深度。

---

## 硬性规则

### 规则 1：算法描述必须使用真实源码（禁止伪代码）

**禁止**的做法：
```
function ObjectMonitor::wait(millis, interruptable, TRAPS):
    // 验证当前线程是 owner
    // 创建 ObjectWaiter 节点，设 TState = TS_WAIT
    // 加入 _WaitSet
    // 保存 _recursions，然后 exit()（完全释放锁）
    // park()  ← 挂起等待 notify
    // 被唤醒后通过 ReenterI() 重新竞争锁
    // 恢复 _recursions
```

**正确**的做法：
```cpp
// objectMonitor.cpp:1416  ← 标注源码文件和行号
void ObjectMonitor::wait(jlong millis, bool interruptible, TRAPS) {
  Thread * const Self = THREAD;
  DeferredInitialize();       // 确保 Knob_* 已初始化  ← 每行有注释
  CHECK_OWNER();              // 验证当前线程是 owner，否则抛 IMSX

  // 检查 pending interrupt（wait 之前就被中断了）
  if (interruptible && Thread::is_interrupted(Self, true) && !HAS_PENDING_EXCEPTION) {
    THROW(vmSymbols::java_lang_InterruptedException());  // 直接抛异常，不进入 wait
    return;
  }

  ObjectWaiter node(Self);         // 构造函数设 _thread=Self, _event=Self->_ParkEvent
  node.TState = ObjectWaiter::TS_WAIT;
  Self->_ParkEvent->reset();       // 清除之前残留的 unpark 信号
  // ...（继续完整源码）
```

### 规则 2：每个函数必须包含的 4 个要素

对每个分析的函数，**必须**包含：

| # | 要素 | 说明 | 反例（禁止） |
|---|------|------|-------------|
| 1 | **源码文件:行号** | `objectMonitor.cpp:1416-1641` | 不标注位置 |
| 2 | **解决什么问题** | 一句话：为什么需要这个函数 | 直接贴代码不解释 |
| 3 | **真实源码 + 逐行注释** | 关键行全部有中文注释 | 伪代码或只贴源码不注释 |
| 4 | **设计决策解释** | 为什么这样而不是那样 | 只说"做了什么"不说"为什么" |

### 规则 3：源码裁剪标准

并非要贴 100% 的源码。裁剪标准是：

**保留**：
- 核心逻辑代码
- 关键条件判断
- CAS/atomic 操作
- 状态转换代码
- 内存屏障 (fence/release_store)

**省略**（用 `// ... 省略：XXX` 标注）：
- JVMTI 事件通知代码
- DTRACE 探针代码
- PerfData 统计代码
- 纯 assert/guarantee（除非说明重要不变量）
- 日志/调试输出

**禁止省略**：
- 竞态条件处理代码（CAS 循环、双重检查锁等）
- 内存屏障和 ordering 代码
- 错误/异常处理的**分支逻辑**（虽然可以省略具体处理）

### 规则 4：长函数的分段描述

对于超过 100 行的函数：

1. 先给出**整体阶段划分**（一个表格或编号列表，不超过 10 行）
2. 然后**逐阶段**贴源码 + 注释
3. 每个阶段之间用 `#### 4.X.Y Phase N: 名称` 分隔
4. 阶段与阶段之间说清楚**衔接关系**

示例：
```markdown
#### 4.12.1 整体流程（7 个阶段）

Phase 1: 前置检查（owner 验证 + 中断检查）
Phase 2: 创建 ObjectWaiter 节点
Phase 3: 加入 WaitSet + 释放锁
Phase 4: park() 挂起
Phase 5: 醒来后从 WaitSet 自我移除（双重检查锁）
Phase 6: 重新竞争锁（enter 或 ReenterI）
Phase 7: 恢复 recursions + 中断检查

#### 4.12.2 Phase 1-2：前置检查 + 创建节点
（源码...）

#### 4.12.3 Phase 3：加入 WaitSet + 完全释放锁
（源码...）
```

### 规则 5：对比表和策略表是加分项

当函数有多种策略/模式时，**必须**用对比表总结：

```markdown
| Policy | 目标队列 | 位置 | TState | 特点 | 默认？ |
|--------|---------|------|--------|------|--------|
| 0 | _EntryList | 头部 | TS_ENTER | 优先竞争 | |
| **2** | _EntryList/cxq | 头部 | TS_ENTER/CXQ | 兼顾效率和公平 | **✅** |
```

当两个相似函数有差异时，**必须**用对比表说清：

```markdown
| | EnterI() | ReenterI() |
|---|-----------|-------------|
| ObjectWaiter 来源 | 自己创建并 CAS 插入 | 已在队列上 |
| _Responsible 选举 | 有 | **无** |
```

### 规则 6：源码级深度的检查清单

写完算法分析后，逐项检查：

- [ ] 每个函数都标注了源码文件和行号范围？
- [ ] 每个函数都用真实源码（不是伪代码）？
- [ ] 关键行都有逐行注释？
- [ ] 每个函数都先说"解决什么问题"？
- [ ] CAS/内存屏障/状态转换代码都保留了？
- [ ] 有多种策略时画了对比表？
- [ ] 长函数有阶段划分？
- [ ] 没有用 `~~伪代码~~` 或 `~~大意如下~~` 的模糊描述？

---

## 反模式清单（Day 34 第一版的错误）

| 反模式 | 问题 | 正确做法 |
|--------|------|---------|
| `function X(): // 做了 A, B, C` | 伪代码，信息量为零 | 贴真实源码 + 逐行注释 |
| "然后调用了 XXX 函数" | 只说调了什么，不说怎么调、为什么调 | 贴调用处源码 + 解释参数选择 |
| "wait 会释放锁" | 正确但无深度 | 解释"保存 _recursions → 清零 → exit(true) → guarantee(_owner != Self)" |
| 一个节点覆盖多个函数 | 每个函数草草几行 | 每个函数独立一节，充分展开 |
| "核心逻辑如上所示" | 贴 50 行源码不注释 | 源码 + 逐行注释 + 阶段划分 |

---

## 深度层级量表

用于自我评估算法描述的深度：

| 层级 | 描述 | 示例 | 是否达标 |
|------|------|------|---------|
| L1 | 自然语言概括 | "wait 释放锁并挂起" | ❌ |
| L2 | 伪代码流程 | `function wait(): save_recursions; exit(); park()` | ❌ |
| L3 | 真实源码 + 少量注释 | 贴源码，只注释几个关键行 | ⚠️ 勉强 |
| **L4** | **真实源码 + 逐行注释 + 设计解释** | 每个关键行有注释 + 解释为什么 | **✅ 标准** |
| L5 | L4 + 对比表 + 状态机图 + 操作顺序表 | 完整分析 | ✅✅ 优秀 |

**目标**：所有算法描述达到 **L4 或 L5**。

---

## 与其他规则的关系

- **Doc-DataStructure-First**：先数据结构后算法。本规则管的是算法**怎么写**。
- **Source-Analysis-Loop**：管的是整体工作流程（5 轮迭代）。本规则管的是每一步的**深度标准**。
- **JVM-GDB-Script**：GDB 验证是独立环节。本规则管的是**源码分析环节**的深度，GDB 验证可以后做。

关系图：
```
Source-Analysis-Loop（整体流程）
  ├── 第一轮：宏观理解
  ├── 第二轮：数据结构全景 ← Doc-DataStructure-First
  ├── 第三轮：算法/流程分析 ← ★ Source-Code-Depth（本规则）
  ├── 第四轮：GDB 验证 ← JVM-GDB-Script / JVM-GDB-Breakpoint
  └── 第五轮：查漏补缺
```
