
# Ch 7 核心增强命令 — watch / trace / monitor / stack

> 源文件:
> - `monitor200/EnhancerCommand.java` (239行) — 增强命令公共基座
> - `monitor200/WatchCommand.java` (204行) + `WatchAdviceListener.java` (117行)
> - `monitor200/TraceCommand.java` (192行) + `AbstractTraceAdviceListener.java` (125行)
>   + `TraceAdviceListener.java` (41行) + `PathTraceAdviceListener.java` (13行)
>   + `TraceEntity.java` (29行) + `model/TraceTree.java` (132行)
> - `monitor200/MonitorCommand.java` (155行) + `MonitorAdviceListener.java` (266行)
>   + `MonitorData.java` (77行)
> - `monitor200/StackCommand.java` (117行) + `StackAdviceListener.java` (77行)
> - `advisor/AdviceListenerAdapter.java` (157行) — 所有 Listener 的公共模板

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **Ch 7 核心增强命令 — watch / trace / monitor / stack**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 0. 先回答"为什么"

Ch5 讲了字节码增强引擎**怎么插桩**，Ch6 讲了 OGNL 表达式**怎么求值**。但这两个引擎本身不直接面对用户——用户面对的是 `watch`、`trace`、`monitor`、`stack` 这些**命令**。

本章解答的核心问题：

1. 四个命令共享了什么？差异在哪里？
2. watch 的 `-b/-e/-s/-f` 四个观测点分别怎么实现？
3. trace 的调用树（TraceTree）是怎么构建的？`deep` 计数器有什么用？
4. monitor 的定时统计怎么实现？如何保证并发安全？
5. stack 怎么获取调用栈？和 `jstack` 的区别是什么？

---

## 1. EnhancerCommand — 公共基座

### 1.1 继承体系

```
AnnotatedCommand (CLI 注解框架)
    └── EnhancerCommand (增强命令公共基座)
            ├── WatchCommand
            ├── TraceCommand
            ├── MonitorCommand
            ├── StackCommand
            └── TimeTunnelCommand (下一章)
```

五个命令**共享**以下行为（由 EnhancerCommand 统一实现）：

| 共享行为 | 实现位置 | 具体内容 |
|----------|---------|---------|
| 增强流程 | `enhance(process)` | 搜索类→创建 Enhancer→retransformClasses |
| 互斥锁 | `session.tryLock()` | 同一时间只允许一个增强 |
| Ctrl+C 支持 | `process.interruptHandler()` | 中断时自动 reset |
| Tab 补全 | `complete()` | 自动补全类名(第1参数)、方法名(第2参数) |
| 排除类 | `--exclude-class-pattern` | 指定不增强的类 |
| 最大匹配 | `-m 50` | 最多增强 50 个类 |
| listenerId | `--listenerId` | 复用已有的 AdviceListener |
| verbose | `-v` | 打印详细信息（条件表达式结果等） |

五个命令**各自实现**（模板方法模式）：

| 抽象方法 | 职责 | 子类差异 |
|----------|------|---------|
| `getClassNameMatcher()` | 类名匹配器 | trace 有 PathTrace 的 GroupMatcher |
| `getMethodNameMatcher()` | 方法名匹配器 | trace 的 PathTrace 用 TrueMatcher |
| `getAdviceListener()` | 创建监听器 | 每个命令创建不同的 Listener |

### 1.2 enhance() 方法——核心流程

```java
protected void enhance(CommandProcess process) {
    Session session = process.session();

    // ① 互斥锁——同一 Session 同一时间只允许一个增强
    if (!session.tryLock()) {
        process.end(-1, "someone else is enhancing classes, pls. wait.");
        return;
    }
    int lock = session.getLock();  // 记录锁版本号

    try {
        Instrumentation inst = session.getInstrumentation();

        // ② 获取 AdviceListener（由子类实现）
        AdviceListener listener = getAdviceListenerWithId(process);

        // ③ 判断是否 trace（InvokeTraceable 标记接口）
        boolean skipJDKTrace = false;
        if (listener instanceof AbstractTraceAdviceListener) {
            skipJDKTrace = ((AbstractTraceAdviceListener) listener).getCommand().isSkipJDKTrace();
        }

        // ④ 创建 Enhancer（ClassFileTransformer）
        Enhancer enhancer = new Enhancer(
            listener,
            listener instanceof InvokeTraceable,  // 只有 TraceAdviceListener 实现了
            skipJDKTrace,
            getClassNameMatcher(),
            getClassNameExcludeMatcher(),
            getMethodNameMatcher()
        );

        // ⑤ 注册到 CommandProcess（Ctrl+C 时自动清理）
        process.register(listener, enhancer);

        // ⑥ 执行增强！
        effect = enhancer.enhance(inst, this.maxNumOfMatchedClass);

        // ⑦ 结果检查
        if (effect.cCnt() == 0 || effect.mCnt() == 0) {
            // 没有匹配到类/方法 → 输出提示信息（6 种可能原因）
        }

        // ⑧ 补偿检查：如果 enhance 期间 unLock 被调用了
        if (session.getLock() == lock) {
            process.echoTips("Press Q or Ctrl+C to abort.\n");
        }

        // 到这里 enhance() 就返回了——注意！命令还没结束！
        // 命令的结束是在 AdviceListener 中触发的（异步）
    } finally {
        if (session.getLock() == lock) {
            process.session().unLock();
        }
    }
}
```

**关键洞察**：`enhance()` 方法执行完后，命令**并没有结束**。此时字节码已被增强，AdviceListener 已注册，方法会继续运行在增强后的字节码上。每次目标方法被调用，都会触发 Listener 回调。命令的结束有两种方式：

```
命令结束的触发方式:
  ① 用户 Ctrl+C → CommandInterruptHandler → process.end() → 清理 Listener/Enhancer → reset
  ② 达到次数限制（-n） → abortProcess() → process.end() → 清理
```

### 1.3 getAdviceListenerWithId() — listenerId 复用

```java
AdviceListener getAdviceListenerWithId(CommandProcess process) {
    if (listenerId != 0) {
        AdviceListener listener = AdviceWeaver.listener(listenerId);
        if (listener != null) {
            return listener;  // 复用已有的 Listener！
        }
    }
    return getAdviceListener(process);  // 正常创建新 Listener
}
```

**使用场景**：当已经有一个命令在监听某个方法，新的命令可以通过 `--listenerId` 复用那个 Listener，避免重复增强。

---

## 2. watch — 方法数据观测

### 2.1 命令参数

```bash
watch <class-pattern> <method-pattern> [express] [condition-express]
      [-b] [-e] [-s] [-f]                 # 四个观测点
      [-x <expand>]                       # 展开深度（默认 1）
      [-n <limits>]                       # 次数限制（默认 100）
      [-M <sizeLimit>]                    # 输出大小限制（默认 10MB）
      [-E]                                # 正则匹配
      [-v]                                # 详细模式
```

| 观测点 | 选项 | 触发时机 | Advice 内容 |
|--------|------|---------|------------|
| before | `-b` | 方法入口 | params ✓, target ✓, returnObj ✗, throwExp ✗ |
| success | `-s` | 方法正常返回 | params ✓, target ✓, returnObj ✓, throwExp ✗ |
| exception | `-e` | 方法异常返回 | params ✓, target ✓, returnObj ✗, throwExp ✓ |
| finish | `-f` | 方法结束（正常+异常）| 根据是否异常决定 |
| **默认** | 无选项 | 等价于 `-f` | 方法结束时触发 |

### 2.2 WatchAdviceListener — 四个观测点的实现

```java
class WatchAdviceListener extends AdviceListenerAdapter {

    private final ThreadLocalWatch threadLocalWatch = new ThreadLocalWatch();
    
    // ========= 方法入口回调 =========
    @Override
    public void before(ClassLoader loader, Class<?> clazz, ArthasMethod method,
                       Object target, Object[] args) throws Throwable {
        threadLocalWatch.start();          // ① 开始计时
        if (command.isBefore()) {
            watching(Advice.newForBefore(...));  // ② 如果有 -b 选项，在入口就触发
        }
    }

    // ========= 正常返回回调 =========
    @Override
    public void afterReturning(ClassLoader loader, Class<?> clazz, ArthasMethod method,
                               Object target, Object[] args, Object returnObject) throws Throwable {
        Advice advice = Advice.newForAfterReturning(...);
        if (command.isSuccess()) {
            watching(advice);              // ③ 如果有 -s 选项，正常返回触发
        }
        finishing(advice);                 // ④ finish 检查
    }

    // ========= 异常返回回调 =========
    @Override
    public void afterThrowing(ClassLoader loader, Class<?> clazz, ArthasMethod method,
                              Object target, Object[] args, Throwable throwable) {
        Advice advice = Advice.newForAfterThrowing(...);
        if (command.isException()) {
            watching(advice);              // ⑤ 如果有 -e 选项，异常返回触发
        }
        finishing(advice);                 // ⑥ finish 检查
    }

    // ========= finish 判断逻辑 =========
    private boolean isFinish() {
        return command.isFinish()                      // 显式 -f
            || !command.isBefore()                     // 没有指定任何 -b/-e/-s
            && !command.isException()                  // ↓
            && !command.isSuccess();                   // → 默认行为 = -f
    }

    private void finishing(Advice advice) {
        if (isFinish()) {
            watching(advice);              // ⑦ 方法结束时触发
        }
    }
}
```

**默认行为的逻辑**：如果用户没有指定任何 `-b/-e/-s/-f`，则 `isFinish()` 返回 `true`——等价于 `-f`（方法结束时触发）。这是最常用的场景：观察方法的入参和返回值。

### 2.3 watching() — 数据采集核心

```java
private void watching(Advice advice) {
    try {
        double cost = threadLocalWatch.costInMillis();      // ① 耗时（ms）

        // ② OGNL 条件过滤（Ch6 详述）
        boolean conditionResult = isConditionMet(command.getConditionExpress(), advice, cost);

        if (conditionResult) {
            // ③ OGNL 数据提取
            Object value = getExpressionResult(command.getExpress(), advice, cost);

            // ④ 构建结果模型
            WatchModel model = new WatchModel();
            model.setTs(LocalDateTime.now());              // 时间戳
            model.setCost(cost);                           // 耗时
            model.setValue(new ObjectVO(value, command.getExpand()));  // 展开到 -x 层
            model.setSizeLimit(command.getSizeLimit());     // 输出大小限制
            model.setClassName(advice.getClazz().getName());
            model.setMethodName(advice.getMethod().getName());

            // ⑤ 标记观测点
            if (advice.isBefore()) {
                model.setAccessPoint("before");
            } else if (advice.isAfterReturning()) {
                model.setAccessPoint("after-returning");
            } else if (advice.isAfterThrowing()) {
                model.setAccessPoint("after-throwing");
            }

            // ⑥ 输出到终端
            process.appendResult(model);

            // ⑦ 次数限制
            process.times().incrementAndGet();
            if (isLimitExceeded(command.getNumberOfLimit(), process.times().get())) {
                abortProcess(process, command.getNumberOfLimit());  // 达到 -n 次数 → 停止
            }
        }
    } catch (Throwable e) {
        // ⑧ 表达式错误 → 终止命令
        process.end(-1, "watch failed, condition is: ... express is: ...");
    }
}
```

### 2.4 watch 完整数据流

```
用户输入: watch com.example.MyService doSomething '{params[0], returnObj}' '#cost>100' -x 2 -n 5

                        编译时（enhance 阶段）
                        ──────────────────────
EnhancerCommand.enhance()
  → new WatchAdviceListener(command, process)
  → new Enhancer(listener, isTracing=false, ...)
  → SearchUtils.searchClass("com.example.MyService")
  → Enhancer.transform()
    → 在 doSomething() 的入口/出口/异常处插入 SpyAPI 调用
  → AdviceListenerManager.register(CL, "MyService", "doSomething", listener)
  → "Affect(class count: 1, method count: 1)"

                        运行时（每次方法被调用）
                        ──────────────────────

目标应用线程:
  MyService.doSomething(arg1)
    → SpyAPI.atEnter(MyService.class, "doSomething|...", this, new Object[]{arg1})
      → SpyImpl.atEnter()
        → AdviceListenerManager.queryAdviceListeners()
          → [WatchAdviceListener]
            → listener.before(loader, clazz, method, this, args)
              → threadLocalWatch.start()         ← 开始计时
              → command.isBefore() == false       ← 没有 -b 选项，跳过

    → ... doSomething 执行原始逻辑 ...
    → return result

    → SpyAPI.atExit(MyService.class, "doSomething|...", this, args, result)
      → SpyImpl.atExit()
        → listener.afterReturning(loader, clazz, method, this, args, result)
          → Advice = {params=[arg1], returnObj=result, ...}
          → command.isSuccess() == false          ← 没有 -s 选项，跳过
          → finishing(advice)
            → isFinish() == true                  ← 默认 = -f
            → watching(advice)
              → cost = 150.3ms
              → isConditionMet("#cost>100", advice, 150.3)
                → OGNL: 150.3 > 100 → true ✓
              → getExpressionResult("{params[0], returnObj}", advice, 150.3)
                → OGNL: [arg1, result]
              → new WatchModel(ts, cost=150.3, value=[arg1, result], expand=2)
              → process.appendResult(model)        ← 输出到终端
              → times = 1
              → isLimitExceeded(5, 1) → false      ← 还没到 -n 5 次

终端输出:
  method=com.example.MyService.doSomething location=AtExit
  ts=2026-02-10 13:29:18; [cost=150.3ms]
  @ArrayList[
      @String[arg1],
      @String[result],
  ]
```

---

## 3. trace — 方法调用链追踪

### 3.1 trace 与 watch 的本质区别

| 维度 | watch | trace |
|------|-------|-------|
| **增强层面** | 只在方法入口/出口插入 SpyAPI | 在方法入口/出口 **+ 每个子调用前后** 插入 |
| **isTracing** | `false` | `true` |
| **InvokeTraceable** | 不实现 | `TraceAdviceListener implements InvokeTraceable` |
| **TransformerManager** | 注册到 `watchTransformers` | 注册到 `traceTransformers` |
| **数据结构** | 平面的 Advice | **树形的 TraceTree** |
| **输出格式** | 单行（参数+返回值） | **树形结构**（每个子调用的耗时） |
| **性能开销** | 较低（只拦截入口/出口） | 较高（拦截所有子调用） |

### 3.2 Listener 继承体系

```
AdviceListenerAdapter
    └── AbstractTraceAdviceListener           ← 核心逻辑：TraceTree 构建 + finishing
            ├── TraceAdviceListener            ← 普通 trace（实现 InvokeTraceable）
            │     ↑ implements InvokeTraceable ← 标记接口：告诉 Enhancer 需要跟踪子调用
            └── PathTraceAdviceListener        ← 多方法链路 trace（不实现 InvokeTraceable）
```

**关键区别**：
- `TraceAdviceListener` 实现了 `InvokeTraceable` → Enhancer 在每个子调用前后插入 SpyAPI.atBeforeInvoke/atAfterInvoke
- `PathTraceAdviceListener` **不实现** `InvokeTraceable` → 只拦截方法入口/出口，不跟踪子调用

### 3.3 TraceEntity — ThreadLocal 传递容器

```java
public class TraceEntity {
    protected TraceTree tree;   // 调用树
    protected int deep;         // 当前嵌套深度

    public TraceEntity(ClassLoader loader) {
        this.tree = new TraceTree(ThreadUtil.getThreadNode(loader, Thread.currentThread()));
        this.deep = 0;
    }
}
```

**为什么需要 ThreadLocal？**

trace 的回调发生在目标方法内部——方法可能调用其他方法，形成多层嵌套。同一个线程中，所有层级的 `before/after` 回调需要共享**同一棵调用树**和**同一个深度计数器**。

```
线程 T1:
  A.method() → before()     → TraceEntity{deep=0} → deep=1
    B.method() → before()   → TraceEntity{deep=1} → deep=2
    B.method() → after()    → TraceEntity{deep=2} → deep=1
    C.method() → before()   → TraceEntity{deep=1} → deep=2
    C.method() → after()    → TraceEntity{deep=2} → deep=1
  A.method() → after()      → TraceEntity{deep=1} → deep=0 → 输出！
```

**deep == 0 是输出时机**：只有当 deep 回到 0 时，才表示**最外层**方法执行完毕，此时输出整棵调用树。

### 3.4 AbstractTraceAdviceListener — 核心逻辑

```java
public class AbstractTraceAdviceListener extends AdviceListenerAdapter {
    protected final ThreadLocal<TraceEntity> threadBoundEntity = new ThreadLocal<>();

    // ========= 方法入口 =========
    @Override
    public void before(ClassLoader loader, Class<?> clazz, ArthasMethod method,
                       Object target, Object[] args) throws Throwable {
        TraceEntity traceEntity = threadLocalTraceEntity(loader);  // 获取/创建 ThreadLocal
        traceEntity.tree.begin(clazz.getName(), method.getName(), -1, false);  // 树中添加节点
        traceEntity.deep++;                                        // 深度 +1
        threadLocalWatch.start();                                  // 开始计时
    }

    // ========= 方法正常返回 =========
    @Override
    public void afterReturning(...) throws Throwable {
        threadLocalTraceEntity(loader).tree.end();                 // 节点结束，记录耗时
        finishing(loader, Advice.newForAfterReturning(...));
    }

    // ========= 方法异常返回 =========
    @Override
    public void afterThrowing(...) throws Throwable {
        // 异常时还要记录异常信息和行号
        int lineNumber = throwable.getStackTrace()[0].getLineNumber();
        threadLocalTraceEntity(loader).tree.end(throwable, lineNumber);
        finishing(loader, Advice.newForAfterThrowing(...));
    }

    // ========= 结束判断 =========
    private void finishing(ClassLoader loader, Advice advice) {
        TraceEntity traceEntity = threadLocalTraceEntity(loader);
        if (traceEntity.deep >= 1) {
            traceEntity.deep--;                                    // 深度 -1
        }
        if (traceEntity.deep == 0) {                              // 最外层方法执行完毕！
            double cost = threadLocalWatch.costInMillis();
            try {
                // OGNL 条件过滤
                boolean conditionResult = isConditionMet(command.getConditionExpress(), advice, cost);
                if (conditionResult) {
                    process.times().incrementAndGet();
                    process.appendResult(traceEntity.getModel());  // 输出整棵调用树！

                    if (isLimitExceeded(command.getNumberOfLimit(), process.times().get())) {
                        abortProcess(process, command.getNumberOfLimit());
                    }
                }
            } finally {
                threadBoundEntity.remove();                        // 清理 ThreadLocal
            }
        }
    }
}
```

### 3.5 TraceAdviceListener — 子调用跟踪

```java
public class TraceAdviceListener extends AbstractTraceAdviceListener
        implements InvokeTraceable {  // ← 标记接口！

    // 子调用前（SpyAPI.atBeforeInvoke 回调）
    @Override
    public void invokeBeforeTracing(ClassLoader classLoader, String tracingClassName,
            String tracingMethodName, String tracingMethodDesc, int tracingLineNumber) {
        threadLocalTraceEntity(classLoader).tree.begin(
            tracingClassName, tracingMethodName, tracingLineNumber, true);
        //                                                         ^^^^ isInvoking=true
    }

    // 子调用后（SpyAPI.atAfterInvoke 回调）
    @Override
    public void invokeAfterTracing(ClassLoader classLoader, String tracingClassName,
            String tracingMethodName, String tracingMethodDesc, int tracingLineNumber) {
        threadLocalTraceEntity(classLoader).tree.end();
    }

    // 子调用异常（SpyAPI.atInvokeException 回调）
    @Override
    public void invokeThrowTracing(ClassLoader classLoader, String tracingClassName,
            String tracingMethodName, String tracingMethodDesc, int tracingLineNumber) {
        threadLocalTraceEntity(classLoader).tree.end(true);  // 标记异常
    }
}
```

### 3.6 TraceTree — 调用树的构建

```java
public class TraceTree {
    private TraceNode root;     // 根节点（ThreadNode）
    private TraceNode current;  // 当前节点（指针）
    private int nodeCount = 0;

    // 开始一个新的方法调用
    public void begin(String className, String methodName, int lineNumber, boolean isInvoking) {
        // ① 查找是否已有相同的子节点（避免重复创建）
        TraceNode child = findChild(current, className, methodName, lineNumber);
        if (child == null) {
            child = new MethodNode(className, methodName, lineNumber, isInvoking);
            current.addChild(child);     // 添加为当前节点的子节点
        }
        child.begin();                   // 记录开始时间
        current = child;                 // 指针下移
        nodeCount++;
    }

    // 结束当前方法调用
    public void end() {
        current.end();                   // 记录结束时间 → 计算耗时
        if (current.parent() != null) {
            current = current.parent();  // 指针上移
        }
    }
}
```

**调用树的构建过程**（以 trace A.method() 为例）：

```
A.method() 中调用了 B.doSomething() 和 C.doAnother()

Step 1: before(A.method)
  tree.begin("A", "method", -1, false)
  current = MethodNode("A.method")      deep = 1
  
  ThreadNode(root)
    └── MethodNode("A.method") ← current

Step 2: invokeBeforeTracing(B.doSomething)
  tree.begin("B", "doSomething", 42, true)
  current = MethodNode("B.doSomething")

  ThreadNode(root)
    └── MethodNode("A.method")
        └── MethodNode("B.doSomething") ← current

Step 3: invokeAfterTracing(B.doSomething)
  tree.end()
  current = MethodNode("A.method")      cost = 50ms

  ThreadNode(root)
    └── MethodNode("A.method") ← current
        └── MethodNode("B.doSomething") [50ms]

Step 4: invokeBeforeTracing(C.doAnother)
  tree.begin("C", "doAnother", 55, true)

  ThreadNode(root)
    └── MethodNode("A.method")
        ├── MethodNode("B.doSomething") [50ms]
        └── MethodNode("C.doAnother") ← current

Step 5: invokeAfterTracing(C.doAnother)
  tree.end()                             cost = 30ms

Step 6: afterReturning(A.method)
  tree.end()                             deep = 0 → 输出！

最终输出:
  `---ts=2026-02-10 13:29:18;thread_name=main;
      `---[150ms] A.method()
          +---[50ms] B.doSomething() #42
          `---[30ms] C.doAnother() #55
```

### 3.7 PathTrace — 多方法链路追踪

```bash
trace -p com.example.ServiceA methodA  \
      -p com.example.ServiceB methodB  \
      -p com.example.ServiceC methodC
```

PathTrace 的特殊之处：
1. **classNameMatcher** 使用 `GroupMatcher.Or`——匹配任一指定的类
2. **methodNameMatcher** 使用 `TrueMatcher`——匹配所有方法
3. 创建 `PathTraceAdviceListener`——**不实现 InvokeTraceable**
4. 因此只有方法级拦截，没有子调用跟踪

**效果**：跨多个类的方法链路追踪，但不跟踪每个方法内部的子调用。适合跟踪"请求从 Controller → Service → DAO"的调用链。

### 3.8 --skipJDKMethod 参数

```java
@Option(longName = "skipJDKMethod")
@DefaultValue("true")   // 默认跳过 JDK 方法！
public void setSkipJDKTrace(boolean skipJDKTrace) {
    this.skipJDKTrace = skipJDKTrace;
}
```

当 `skipJDKTrace = true`（默认）时，Enhancer 使用 `SpyTraceExcludeJDKInterceptor` 而不是 `SpyTraceInterceptor`——在字节码层面就排除了 `java.*` 包的子调用跟踪，避免 trace 结果充满 `String.valueOf`、`Integer.intValue` 等噪声。

---

## 4. monitor — 方法性能统计

### 4.1 与 watch/trace 的本质区别

| 维度 | watch/trace | monitor |
|------|-------------|---------|
| **输出模式** | 每次调用都输出 | **定时周期性输出**（默认 60 秒） |
| **数据粒度** | 单次调用的详细数据 | **一段时间的统计聚合** |
| **核心数据** | 参数/返回值/调用树 | **total/success/failed/avgRT/failRate** |
| **实现关键** | OGNL 表达式求值 | **ConcurrentHashMap + AtomicReference + Timer** |

### 4.2 MonitorAdviceListener 架构

```
MonitorAdviceListener
├── monitorData: ConcurrentHashMap<Key, AtomicReference<MonitorData>>
│     Key = (className, methodName)
│     MonitorData = {total, success, failed, cost, timestamp}
│
├── timer: Timer（定时任务）
│     └── MonitorTimer: 每 cycle 秒执行一次
│           → swap(monitorData) → 输出 → 清零
│
└── conditionResult: ThreadLocal<Boolean>
      → -b 选项时，在 before 阶段求值条件
```

### 4.3 数据采集——无锁 CAS 设计

```java
private void finishing(Class<?> clazz, ArthasMethod method, boolean isThrowing, Advice advice) {
    double cost = threadLocalWatch.costInMillis();

    // 条件过滤
    if (!isConditionMet(...)) return;

    final Key key = new Key(clazz.getName(), method.getName());

    // ① 外层循环：确保 key 被注册
    while (true) {
        AtomicReference<MonitorData> value = monitorData.get(key);
        if (null == value) {
            monitorData.putIfAbsent(key, new AtomicReference<>(new MonitorData()));
            continue;                          // 可能被其他线程抢先，重新获取
        }

        // ② 内层循环：CAS 更新统计数据
        while (true) {
            MonitorData oData = value.get();
            MonitorData nData = new MonitorData();  // 创建新的数据对象
            nData.setCost(oData.getCost() + cost);  // 累加耗时
            nData.setTotal(oData.getTotal() + 1);   // 总次数 +1
            if (isThrowing) {
                nData.setFailed(oData.getFailed() + 1);
                nData.setSuccess(oData.getSuccess());
            } else {
                nData.setSuccess(oData.getSuccess() + 1);
                nData.setFailed(oData.getFailed());
            }
            if (value.compareAndSet(oData, nData)) {
                break;                              // CAS 成功 → 更新完成
            }
            // CAS 失败 → 有其他线程同时更新 → 重试
        }
        break;
    }
}
```

**为什么用 CAS 而不用锁？**

monitor 的数据采集发生在**目标应用线程**中——如果使用 synchronized，会阻塞目标方法的执行。CAS 是非阻塞的，最坏情况只是多重试几次，不会阻塞业务线程。

**为什么每次都 new MonitorData？**

AtomicReference 的 CAS 比较的是引用（不是值）。如果直接修改 oData 的字段，CAS 的 expected 值和 actual 值是同一个对象，compareAndSet 会永远成功——但多线程同时修改同一个对象的字段会丢失更新。创建新对象（copy-on-write 思想）才是正确的。

### 4.4 定时输出——MonitorTimer

```java
class MonitorTimer extends TimerTask {
    @Override
    public void run() {
        if (monitorData.isEmpty()) return;

        // 次数限制
        if (process.times().getAndIncrement() >= limit) {
            this.cancel();
            abortProcess(process, limit);
            return;
        }

        List<MonitorData> monitorDataList = new ArrayList<>();
        for (Map.Entry<Key, AtomicReference<MonitorData>> entry : monitorData.entrySet()) {
            AtomicReference<MonitorData> value = entry.getValue();

            MonitorData data;
            while (true) {
                data = value.get();
                // CAS swap：用空的 MonitorData 替换当前数据
                if (value.compareAndSet(data, new MonitorData())) {
                    break;
                }
            }

            data.setClassName(entry.getKey().getClassName());
            data.setMethodName(entry.getKey().getMethodName());
            monitorDataList.add(data);
        }

        process.appendResult(new MonitorModel(monitorDataList));
    }
}
```

**CAS swap 的精妙之处**：定时器执行时，用一个空的 MonitorData 原子地替换当前数据。这保证了：
1. swap 前累积的数据**完整输出**
2. swap 后新的调用重新从零开始累积
3. **不需要锁**——采集线程和定时器线程通过 CAS 无锁协作

### 4.5 -b 选项——在 before 阶段求值条件

```java
@Override
public void before(ClassLoader loader, Class<?> clazz, ArthasMethod method,
                   Object target, Object[] args) throws Throwable {
    threadLocalWatch.start();
    if (!StringUtils.isEmpty(command.getConditionExpress()) && command.isBefore()) {
        Advice advice = Advice.newForBefore(loader, clazz, method, target, args);
        long cost = threadLocalWatch.cost();
        this.conditionResult.set(isConditionMet(command.getConditionExpress(), advice, cost));
        // 重新计时！排除条件表达式求值的耗时
        threadLocalWatch.start();
    }
}
```

**为什么重新计时？** 条件表达式求值（OGNL）本身有耗时。如果不重新 `start()`，最终统计的 RT 会包含 OGNL 求值时间，导致数据不准确。

---

## 5. stack — 调用来源追踪

### 5.1 与其他命令的区别

| 维度 | watch | trace | stack |
|------|-------|-------|-------|
| **回答的问题** | 方法的参数和返回值是什么？ | 方法内部调用了哪些子方法？ | **这个方法是被谁调用的？** |
| **数据来源** | SpyAPI 拦截 + OGNL | SpyAPI 拦截 + TraceTree | **Thread.getStackTrace()** |
| **方向** | 水平（数据观测） | 向下（子调用） | **向上（调用者）** |

### 5.2 StackAdviceListener — 极简实现

```java
public class StackAdviceListener extends AdviceListenerAdapter {

    @Override
    public void before(ClassLoader loader, Class<?> clazz, ArthasMethod method,
                       Object target, Object[] args) throws Throwable {
        threadLocalWatch.start();          // 计时（用于 #cost 条件过滤）
    }

    @Override
    public void afterReturning(...) throws Throwable {
        finishing(Advice.newForAfterReturning(...));
    }

    @Override
    public void afterThrowing(...) throws Throwable {
        finishing(Advice.newForAfterThrowing(...));
    }

    private void finishing(Advice advice) {
        double cost = threadLocalWatch.costInMillis();
        boolean conditionResult = isConditionMet(command.getConditionExpress(), advice, cost);

        if (conditionResult) {
            // 核心！调用 ThreadUtil.getThreadStackModel()
            StackModel stackModel = ThreadUtil.getThreadStackModel(
                advice.getLoader(), Thread.currentThread());
            stackModel.setTs(LocalDateTime.now());
            process.appendResult(stackModel);

            // 次数限制
            process.times().incrementAndGet();
            if (isLimitExceeded(command.getNumberOfLimit(), process.times().get())) {
                abortProcess(process, command.getNumberOfLimit());
            }
        }
    }
}
```

**核心就一行**：`ThreadUtil.getThreadStackModel(loader, Thread.currentThread())`

这个方法内部调用 `Thread.currentThread().getStackTrace()` 获取当前线程的完整调用栈，然后封装成 StackModel 输出。

### 5.3 stack vs jstack

| 维度 | stack 命令 | jstack / thread 命令 |
|------|-----------|---------------------|
| 触发方式 | **方法被调用时**自动触发 | 用户手动执行，获取**瞬时快照** |
| 精度 | 精确到**某个方法被调用的那一刻** | 采样某个**时间点**所有线程的状态 |
| 条件过滤 | 支持 `#cost > 100` 条件过滤 | 不支持 |
| 性能开销 | 每次方法调用都有开销 | 一次性采样 |
| 使用场景 | "这个方法到底被谁调用了？" | "现在有哪些线程在做什么？" |

---

## 6. 四个命令的对比总结

### 6.1 Listener 对比

```
                  AdviceListenerAdapter (公共模板)
                  ├── isConditionMet()      — OGNL 条件过滤
                  ├── getExpressionResult() — OGNL 数据提取
                  ├── isLimitExceeded()     — 次数限制
                  └── abortProcess()        — 终止命令
                          │
        ┌─────────────────┼─────────────────┬─────────────────┐
        ▼                 ▼                 ▼                 ▼
  WatchAdvice       AbstractTraceAdvice   MonitorAdvice    StackAdvice
  Listener          Listener              Listener         Listener
  ───────────       ───────────────       ──────────       ──────────
  watching()        finishing()           finishing()      finishing()
  │                 │ deep 管理           │ CAS 累加       │ getStackTrace
  │                 │ TraceTree 构建       │ Timer 输出     │
  │                 │                     │                │
  ↓                 ↓                     ↓                ↓
  每次调用输出      deep==0 时输出树       周期性聚合输出    每次调用输出栈
```

### 6.2 完整对比表

| 维度 | watch | trace | monitor | stack |
|------|-------|-------|---------|-------|
| **回答什么** | 参数/返回值是什么 | 内部调了哪些方法 | 调用统计(次数/RT) | 被谁调用的 |
| **增强类型** | 方法级 | 方法级+调用级 | 方法级 | 方法级 |
| **isTracing** | false | true | false | false |
| **Transformer** | watchTransformers | traceTransformers | watchTransformers | watchTransformers |
| **数据结构** | Advice → OGNL | TraceTree(树) | MonitorData(map) | StackTrace(数组) |
| **输出时机** | 每次调用 | deep==0 | 每 cycle 秒 | 每次调用 |
| **OGNL 表达式** | ✅ 数据+条件 | 条件 only | 条件 only | 条件 only |
| **并发设计** | 无（单次输出） | ThreadLocal | CAS+AtomicRef | 无（单次输出） |
| **-n 限制** | 输出次数 | 输出次数 | Timer 执行次数 | 输出次数 |
| **性能开销** | 低 | 高（子调用拦截） | 低（只累加数字） | 低 |

### 6.3 公共流程图

```
              用户输入命令
                  │
                  ▼
        EnhancerCommand.process()
                  │
                  ▼
        enhance(process)
        ├─ session.tryLock()               ← 互斥
        ├─ getAdviceListener(process)      ← 子类创建各自的 Listener
        ├─ new Enhancer(listener, ...)     ← isTracing 决定增强方式
        ├─ process.register(listener)      ← Ctrl+C 清理钩子
        └─ enhancer.enhance(inst, maxMatch)← 搜索+增强+retransform
                  │
                  ▼
           命令进入"等待"状态
           （字节码已增强，Listener 已注册）
                  │
                  ▼
        ┌─── 每次目标方法被调用 ───┐
        │                          │
        │  SpyAPI.atEnter()        │
        │    → listener.before()   │
        │                          │
        │  SpyAPI.atExit()         │
        │    → listener.after()    │
        │                          │
        │  ├─ watch: watching()    │ ← 每次输出
        │  ├─ trace: deep-- ?      │ ← deep==0 时输出
        │  ├─ monitor: CAS 累加   │ ← 定时器输出
        │  └─ stack: getStackTrace│ ← 每次输出
        │                          │
        └──────────────────────────┘
                  │
        Ctrl+C 或 -n 达到上限
                  │
                  ▼
        process.end()
        ├─ removeTransformer()
        ├─ retransformClasses()   ← 恢复原始字节码
        └─ listener.destroy()     ← 清理 ThreadLocal 等
```

---

> **下一节**: [Ch 8 tt 命令 — 时间隧道](ch08_time_tunnel.md) — 录制方法调用快照 + 重放
