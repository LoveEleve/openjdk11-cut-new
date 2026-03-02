# Ch03: Counted Loop Safepoint — C2 长循环中的安全点插入

> **标准环境**: `-Xms8g -Xmx8g -XX:+UseG1GC`, 16 核, Region 4MB
> **前置文档**: `Safepoint/SafepointMechanism.md`（整体机制）、`Safepoint/ch01_safepoint_begin_deep_dive.md`（STW 流程）
> **核心源码**: `loopnode.cpp`（Loop Strip Mining）、`g1Arguments.cpp`（G1 默认参数）、`compilerDefinitions.cpp`（参数关联）

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **Ch03: Counted Loop Safepoint — C2 长循环中的安全点插入**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 1. 解决什么问题？

### 1.1 Counted Loop 陷阱

在 C2 编译器优化后，**counted loop**（for 循环等已知迭代次数的循环）默认不包含 Safepoint Poll。这是因为：

1. C2 在后向跳转（backedge）处**删除了 Safepoint Poll**，以追求循环性能
2. 如果循环体不包含方法调用（无 call → 无自然的 Safepoint），整个循环期间线程都不响应 Safepoint

**后果**：JVM 需要进入 STW（如 GC、偏向锁撤销、JIT 编译），但拥有长循环的线程**不响应 Safepoint**，导致所有其他线程等待，STW 时间被无限拉长。

```
问题场景:
  线程 A: 执行 C2 编译的 for(int i=0; i<10000000; i++) { 纯计算; }
  线程 B: 触发 GC → safepoint_begin()

  VMThread: arm safepoint, 等待所有线程响应...
            线程 A 没有 poll → 一直不响应
            其他线程全部阻塞等待
            → STW 时间 = 线程 A 循环剩余时间（可能几百毫秒甚至秒级）
```

### 1.2 解决方案: Loop Strip Mining

JDK 10 引入 **Loop Strip Mining**（循环条带挖掘）：将一个长循环**拆成外层+内层双重循环**，在外层循环的每次迭代之间插入 Safepoint Poll。

```
原始循环:                         Strip Mining 后:
for (i = 0; i < N; i++) {        outer: for (j = 0; j < N; j += 1000) {
    body(i);                          inner: for (i = j; i < min(j+1000,N); i++) {
}                                         body(i);
                                      }
                                      <Safepoint Poll>  ← 每 1000 次迭代检查一次
                                  }
```

**效果**：循环语义完全不变，但每 1000 次迭代就有一次 Safepoint 机会。STW 最大延迟从"循环总时间"降低为"1000 次迭代的时间"。

---

## 2. 核心参数

### 2.1 参数定义

```cpp
// c2_globals.hpp:219
product(bool, UseCountedLoopSafepoints, false,  // 全局默认 false
    "Force counted loops to keep a safepoint")

// c2_globals.hpp:755
product(uintx, LoopStripMiningIter, 0,          // 全局默认 0
    "Number of iterations in strip mined counted loops")
```

### 2.2 G1 默认值覆盖

```cpp
// g1Arguments.cpp:167
#ifdef COMPILER2
  // G1 强制开启 Counted Loop Safepoint
  if (FLAG_IS_DEFAULT(UseCountedLoopSafepoints)) {
    FLAG_SET_DEFAULT(UseCountedLoopSafepoints, true);
    if (FLAG_IS_DEFAULT(LoopStripMiningIter)) {
      FLAG_SET_DEFAULT(LoopStripMiningIter, 1000);
    }
  }
#endif
```

**标准条件下**（`-XX:+UseG1GC`）：
- `UseCountedLoopSafepoints = true`（G1 强制开启）
- `LoopStripMiningIter = 1000`（每 1000 次迭代一个 Safepoint）

### 2.3 参数一致性检查

```cpp
// compilerDefinitions.cpp:338
if (UseCountedLoopSafepoints && LoopStripMiningIter == 0) {
    // 开启了安全点但迭代数为 0 → 强制设为 1
    LoopStripMiningIter = 1;
} else if (!UseCountedLoopSafepoints && LoopStripMiningIter > 0) {
    // 关闭了安全点但迭代数 > 0 → 强制设为 0
    LoopStripMiningIter = 0;
}
```

两个参数必须一致：UseCountedLoopSafepoints=true ↔ LoopStripMiningIter > 0。

### 2.4 各 GC 的默认值

| GC 收集器 | UseCountedLoopSafepoints 默认 | LoopStripMiningIter 默认 |
|-----------|------------------------------|--------------------------|
| G1 | **true** | **1000** |
| ZGC | **true** | **1000** |
| Shenandoah | **true** | **1000** |
| Epsilon | **true** | **1000** |
| Serial/Parallel | false (全局默认) | 0 |

**观察**：所有并发/低延迟 GC 都强制开启 Counted Loop Safepoint。这是因为并发 GC 对 STW 延迟更敏感。

---

## 3. C2 IR 中的实现

### 3.1 Loop Strip Mining 的 IR 变换

```
C2 优化流程:
  parse.cpp: add_safepoint() → 在后向跳转处插入 SafePointNode
  ↓
  PhaseIdealLoop::is_counted_loop()
  ↓
  条件: LoopStripMiningIter > 1 && loop->_child == NULL && !loop->_has_call
  ↓
  create_outer_strip_mined_loop() → 将循环拆分为外层 + 内层
  ↓
  SafePointNode 从内层循环移动到外层循环
  ↓
  内层循环: 最多 LoopStripMiningIter 次迭代, 无 Safepoint（高性能）
  外层循环: 每次迭代执行 1 个 Safepoint Poll（保证响应性）
```

### 3.2 关键源码

```cpp
// loopnode.cpp:830
// 条件: 迭代数 > 1 && 没有子循环 && 循环体内有 SafePoint && 循环体无 call
bool strip_mine_loop = LoopStripMiningIter > 1 && loop->_child == NULL &&
    sfpt2->Opcode() == Op_SafePoint && !loop->_has_call;

if (strip_mine_loop) {
    // 创建外层循环（OuterStripMinedLoopNode）
    outer_ilt = create_outer_strip_mined_loop(test, cmp, init_control, loop,
                                              cl_prob, le->_fcnt, entry_control,
                                              iffalse);
}

// 将内层的 SafePoint 移动到外层
if (strip_mine_loop) {
    Node* outer_le = outer_ilt->_tail->in(0);
    Node* sfpt = sfpt2->clone();       // 克隆 SafePoint 到外层
    sfpt->set_req(0, iffalse);
    outer_le->set_req(0, sfpt);        // 外层循环的入口连接 SafePoint
    register_control(sfpt, outer_ilt, iffalse);
}
// 从内层删除 SafePoint
lazy_replace(sfpt2, sfpt2->in(TypeFunc::Control));
```

### 3.3 调整外层循环迭代数

```cpp
// loopnode.cpp:1369 (OuterStripMinedLoopNode::adjust_strip_mined_loop)
int stride = inner_cl->stride_con();  // 循环步长
jlong scaled_iters_long = ((jlong)LoopStripMiningIter) * ABS(stride);
// = 1000 × |stride|

// 如果循环总迭代数太少，移除外层循环（不值得拆分）
if (iter_estimate <= short_scaled_iters) {
    // 移除外层循环和 safepoint
    inner_cl->clear_strip_mined();
    return;
}

// 如果只会走一次外层循环，去掉外层但保留 safepoint
if (iter_estimate <= scaled_iters_long) {
    inner_cl->clear_strip_mined();
    return;
}
```

---

## 4. Safepoint Poll 在不同执行模式下的完整总结

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│               JVM 中 Safepoint Poll 的所有插入位置                               │
├───────────────────┬──────────────────────────────────────────────────────────────┤
│ 执行模式           │ Safepoint Poll 位置                                         │
├───────────────────┼──────────────────────────────────────────────────────────────┤
│ 解释器执行         │ ① 每条字节码的 dispatch 末尾检查                              │
│                   │   (InterpreterMacroAssembler::dispatch_base)                │
│                   │ → 每条字节码都有机会响应 Safepoint                            │
├───────────────────┼──────────────────────────────────────────────────────────────┤
│ C1 编译代码        │ ② 方法返回处 (method return)                                 │
│                   │ ③ 后向跳转 (backedge) — 循环中保留 poll                       │
│                   │ ④ 方法调用点 (call site) 的 debug info                       │
│                   │ → 循环中每次迭代都可响应                                       │
├───────────────────┼──────────────────────────────────────────────────────────────┤
│ C2 编译代码        │ ⑤ 方法返回处 (method return)                                 │
│ (无 strip mining)  │ ⑥ 后向跳转的 SafePoint **被删除** (追求性能)                 │
│                   │ ⑦ 方法调用 (call site)                                       │
│                   │ → 纯计算循环可能长时间不响应！                                 │
├───────────────────┼──────────────────────────────────────────────────────────────┤
│ C2 编译代码        │ ⑧ 内层循环: SafePoint 被删除                                 │
│ (有 strip mining)  │ ⑨ 外层循环: 每 1000 次迭代一次 SafePoint Poll               │
│                   │ → 最大延迟 = 1000 次循环迭代的时间                            │
├───────────────────┼──────────────────────────────────────────────────────────────┤
│ Native 代码执行    │ ⑩ Native 代码期间无 poll（被视为安全状态）                    │
│                   │ ⑪ JNI 返回时 (transition _thread_in_native → _thread_in_vm)  │
│                   │ → GC 可以安全扫描 Native 线程的栈                             │
├───────────────────┼──────────────────────────────────────────────────────────────┤
│ Blocked 状态       │ ⑫ 阻塞线程被视为安全（_thread_blocked）                      │
│                   │    Parker::park → ThreadBlockInVM → Safepoint 不等待         │
│                   │    Object.wait → Monitor::wait → 同上                        │
│                   │ → 无需 poll，本身就安全                                       │
└───────────────────┴──────────────────────────────────────────────────────────────┘
```

### 4.1 解释器 vs C1 vs C2 的 Safepoint 响应延迟

```
执行模式         最坏情况 Safepoint 延迟     原因
──────────────────────────────────────────────────────────────
解释器           ~1 字节码时间 (微秒级)      每条字节码都检查
C1 编译代码       ~1 次循环迭代 (微秒级)      backedge 保留 poll
C2 无 strip mine  可能无限 (秒级!)           循环内无 poll
C2 有 strip mine  ~1000 次迭代 (毫秒级)      strip mining
Native 执行       JNI 返回时 (不确定)         取决于 native 代码时长
Blocked          立即 (0)                   已是安全状态
```

---

## 5. 面试 Q&A

### Q1: 为什么 C2 编译的长循环会导致 GC 停顿变长？

**回答要点**：

C2 为了追求循环性能，会**删除 counted loop 中后向跳转处的 Safepoint Poll**。如果循环体不包含方法调用（纯计算循环），整个循环期间线程都不响应 Safepoint。

当 JVM 需要 STW（如 GC）时，VMThread 必须等待所有线程到达 Safepoint。有长循环的线程不响应 → 其他所有线程都阻塞等待 → STW 时间 = 长循环的剩余执行时间。

JDK 10 引入 Loop Strip Mining 解决了这个问题：将长循环拆成外层（有 Safepoint）+ 内层（无 Safepoint，最多 1000 次迭代），保证 Safepoint 最大延迟在毫秒级。

G1/ZGC/Shenandoah 默认开启 `UseCountedLoopSafepoints=true` + `LoopStripMiningIter=1000`。

### Q2: Loop Strip Mining 是怎么实现的？对性能有影响吗？

**回答要点**：

将原始循环 `for(i=0; i<N; i++)` 拆分为：
```
outer: for(j=0; j<N; j+=1000) {
    inner: for(i=j; i<min(j+1000,N); i++) {
        body(i);
    }
    <safepoint poll>
}
```

对性能的影响**非常小**：
1. 内层循环仍然可以被 C2 完全优化（向量化、循环展开等）
2. 外层的 Safepoint Poll 只是一次内存读取（polling page test），如果没有 Safepoint 请求，cost ≈ 一次 L1 cache hit
3. 如果循环总迭代数很少（< LoopStripMiningIterShortLoop），C2 会自动**跳过 strip mining**

trade-off 是：极少的运行时开销 换取 Safepoint 响应性的巨大改善（从秒级 → 毫秒级）。

### Q3: 哪些 GC 默认开启 Counted Loop Safepoint？为什么？

**回答要点**：

G1、ZGC、Shenandoah、Epsilon 都默认开启。Serial 和 Parallel GC 不开启。

原因：G1/ZGC/Shenandoah 都是低延迟 GC，核心卖点是**低 STW 停顿**。如果长循环阻塞 Safepoint，低延迟目标就无法实现。所以这些 GC 在 `*Arguments::initialize()` 中强制设置 `UseCountedLoopSafepoints=true`。

Serial/Parallel GC 不追求低延迟（追求吞吐量），长循环阻塞影响不大，所以默认不开启以保留最大循环性能。

---

## 6. 源码索引

| 文件 | 路径 | 关键内容 |
|------|------|---------|
| c2_globals.hpp:219 | `opto/c2_globals.hpp` | UseCountedLoopSafepoints 定义 |
| c2_globals.hpp:755 | `opto/c2_globals.hpp` | LoopStripMiningIter 定义 |
| g1Arguments.cpp:167 | `gc/g1/g1Arguments.cpp` | G1 设置 UseCountedLoopSafepoints=true |
| compilerDefinitions.cpp:338 | `compiler/compilerDefinitions.cpp` | 参数一致性检查 |
| loopnode.cpp:830 | `opto/loopnode.cpp` | strip_mine_loop 条件判断 |
| loopnode.cpp:854 | `opto/loopnode.cpp` | SafePoint 从内层移到外层 |
| loopnode.cpp:1353 | `opto/loopnode.cpp` | adjust_strip_mined_loop 调整迭代数 |
| parse1.cpp:2232 | `opto/parse1.cpp` | Parse::add_safepoint() 初始插入 |
| callnode.hpp:323 | `opto/callnode.hpp` | SafePointNode 类定义 |

---

*最后更新: 2026-02-09*
*GDB 验证环境: OpenJDK 11, -Xms8g -Xmx8g -XX:+UseG1GC, 16 核*
