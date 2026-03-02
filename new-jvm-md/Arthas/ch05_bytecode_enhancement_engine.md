
# Ch 5 字节码增强引擎 — Arthas 的核心武器

> 源文件:
> - `core/advisor/Enhancer.java` (518行) — 字节码增强的 ClassFileTransformer
> - `core/advisor/TransformerManager.java` (98行) — 三层 Transformer 管理器
> - `core/command/monitor200/EnhancerCommand.java` (239行) — 增强命令的公共基座
> - `core/advisor/SpyInterceptors.java` (114行) — bytekit 增强模板
> - `core/advisor/AdviceListener.java` (72行) — 监听器接口
> - `core/advisor/AdviceWeaver.java` (78行) — 监听器注册中心（by adviceId）
> - `core/advisor/AdviceListenerManager.java` (236行) — 监听器分发中心（by ClassLoader+方法）
> - `core/util/SearchUtils.java` (144行) — 类/方法搜索

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **Ch 5 字节码增强引擎 — Arthas 的核心武器**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 0. 先回答"为什么"

Arthas 最核心的能力是：**在不修改源码、不重启 JVM 的情况下，观测任意方法的运行时行为**。

实现这个能力的关键技术就是**字节码增强**——在目标方法的入口、出口、异常处，动态插入 SpyAPI 调用，让 Arthas 在方法执行时获得回调。

本章解答的核心问题：

1. 增强的**完整流程**是什么？（从用户输入命令到字节码被修改）
2. 字节码**具体被改成了什么样**？
3. 多个命令**同时增强同一个方法**怎么处理？
4. `reset` 怎么**恢复原始字节码**？

---

## 1. 增强全流程——从命令到字节码

以 `watch com.example.MyService doSomething '{params}'` 为例：

```
                用户输入命令
                    │
                    ▼
┌─ Step 1: EnhancerCommand.enhance() ────────────────────────────────┐
│                                                                     │
│  ① session.tryLock()                  ← 互斥锁，同一时间只允许一个增强│
│  ② getAdviceListenerWithId(process)   ← 创建 WatchAdviceListener    │
│  ③ new Enhancer(listener, isTracing,  ← 创建 Enhancer               │
│        skipJDKTrace, classMatcher,       （ClassFileTransformer）    │
│        excludeMatcher, methodMatcher)                               │
│  ④ process.register(listener, enhancer) ← 注册到 CommandProcess     │
│  ⑤ enhancer.enhance(inst, maxMatch)   ← 开始增强（见 Step 2-4）     │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
                    │
                    ▼
┌─ Step 2: Enhancer.enhance() — 搜索目标类 ──────────────────────────┐
│                                                                     │
│  ⑥ SearchUtils.searchClass(inst, classNameMatcher)                  │
│     → inst.getAllLoadedClasses()  ← 遍历 JVM 中所有已加载的类       │
│     → 对每个类名做 WildcardMatcher.matching()                       │
│     → 得到 matchingClasses = {MyService.class}                      │
│                                                                     │
│  ⑦ SearchUtils.searchSubClass(inst, matchingClasses)                │
│     → 如果 isDisableSubClass=false，还搜索所有子类                   │
│     → isAssignableFrom() 判断继承关系                               │
│                                                                     │
│  ⑧ filter(matchingClasses) — 过滤不可增强的类                       │
│     → isSelf()           排除 Arthas 自己的类                       │
│     → isUnsafeClass()    排除 BootstrapCL 的类（除非 options unsafe）│
│     → isUnsupportedClass() 排除 Lambda/接口/Integer/Class/数组      │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
                    │
                    ▼
┌─ Step 3: TransformerManager.addTransformer() — 注册 ───────────────┐
│                                                                     │
│  ⑨ TransformerManager.addTransformer(enhancer, isTracing)           │
│     → isTracing ? traceTransformers.add : watchTransformers.add     │
│     → watch/monitor/stack/tt → watchTransformers                    │
│     → trace → traceTransformers                                     │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
                    │
                    ▼
┌─ Step 4: inst.retransformClasses() — 触发 JVM 重新加载 ────────────┐
│                                                                     │
│  ⑩ inst.retransformClasses(MyService.class)                         │
│     → JVM 内部调用 ClassFileTransformer.transform()                 │
│     → TransformerManager 的聚合 Transformer 被调用                   │
│       → 依次执行 reTransformers → watchTransformers → traceTransformers│
│       → 其中包含我们的 Enhancer.transform()                          │
│     → Enhancer.transform() 返回修改后的字节码                        │
│     → JVM 用新字节码替换旧的                                         │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. Enhancer.transform() — 字节码改造核心

这是整个增强引擎**最核心的方法**，当 JVM 调用 `retransformClasses()` 时，会把目标类的原始字节码传给这个方法，Enhancer 返回修改后的字节码。

### 2.1 完整流程

```java
transform(ClassLoader inClassLoader, String className, Class<?> classBeingRedefined,
          ProtectionDomain protectionDomain, byte[] classfileBuffer)
```

```
输入: classfileBuffer（目标类的原始字节码）
输出: enhanceClassByteArray（增强后的字节码）或 null（不增强）

Step 1: 前置检查
  ├─ inClassLoader.loadClass("java.arthas.SpyAPI")   ← 能加载 SpyAPI 吗？
  │   失败 → return null（放弃增强）
  └─ matchingClasses.contains(classBeingRedefined)     ← 是目标类吗？
      不是 → return null

Step 2: 解析字节码
  ├─ ClassNode classNode = AsmUtils.toClassNode(classfileBuffer)   ← 用 ASM 解析
  └─ AsmUtils.removeJSRInstructions(classNode)  ← 移除过时的 JSR 指令（JDK 1.4-）

Step 3: 构建增强处理器
  ├─ 解析 SpyInterceptor1/2/3       ← 方法级（atEnter/atExit/atExceptionExit）
  └─ 如果 isTracing:
     ├─ skipJDKTrace=false: 解析 SpyTraceInterceptor1/2/3     ← 跟踪所有子调用
     └─ skipJDKTrace=true:  解析 SpyTraceExcludeJDKInterceptor1/2/3 ← 跳过 java.*

Step 4: 筛选目标方法
  ├─ 遍历 classNode.methods
  └─ isIgnore(methodNode) 排除:
     ├─ abstract 方法（没有方法体）
     ├─ <clinit>（类初始化器，增强有风险）
     └─ 不匹配 methodNameMatcher 的方法

Step 5: 幂等检查（GroupLocationFilter）
  ├─ 检查字节码中是否已经有 SpyAPI.atEnter 调用
  └─ 如果已有 → 不重复插入字节码，只注册新的 AdviceListener

Step 6: 增强字节码（核心！）
  ├─ 如果方法已被增强过（含 atBeforeInvoke）:
  │   → 只遍历方法中的 INVOKE 指令
  │   → 对每个子调用注册 traceAdviceListener（不修改字节码）
  │
  └─ 如果方法未被增强过:
     ├─ new MethodProcessor(classNode, methodNode, groupLocationFilter)
     ├─ for interceptor in interceptorProcessors:
     │     interceptor.process(methodProcessor)  ← bytekit 插入字节码
     │     → 在方法入口插入 SpyAPI.atEnter()
     │     → 在方法出口插入 SpyAPI.atExit()
     │     → 在异常出口插入 SpyAPI.atExceptionExit()
     │     → (trace) 在每个 INVOKE 前后插入 atBeforeInvoke/atAfterInvoke/atInvokeException
     └─ 注册 AdviceListener

Step 7: 注册监听器
  ├─ AdviceListenerManager.registerAdviceListener(CL, class, method, desc, listener)
  └─ AdviceListenerManager.registerTraceAdviceListener(CL, class, owner, method, desc, listener)

Step 8: 生成字节码
  ├─ AsmUtils.toBytes(classNode, inClassLoader, classReader)
  ├─ classBytesCache.put(classBeingRedefined, ...)  ← 记录已增强的类
  ├─ dumpClassIfNecessary(...)  ← 如果 options dump=true，写入文件
  └─ return enhanceClassByteArray
```

### 2.2 增强后的字节码长什么样

以下是增强前后的对比：

```java
// ========= 增强前 =========
public String doSomething(int a, String b) {
    String result = helper(a);
    return result + b;
}

// ========= 增强后（watch 命令，非 trace）=========
public String doSomething(int a, String b) {
    try {
        // ① 方法入口拦截
        SpyAPI.atEnter(
            MyService.class,                                       // clazz
            "doSomething|(ILjava/lang/String;)Ljava/lang/String;", // methodInfo
            this,                                                   // target
            new Object[]{Integer.valueOf(a), b}                    // args（装箱）
        );

        // 原始逻辑
        String result = helper(a);
        Object __returnObj = result + b;

        // ② 方法正常返回拦截
        SpyAPI.atExit(
            MyService.class,
            "doSomething|(ILjava/lang/String;)Ljava/lang/String;",
            this,
            new Object[]{Integer.valueOf(a), b},
            __returnObj                                             // 返回值
        );

        return (String) __returnObj;
    } catch (Throwable __throwable) {
        // ③ 方法异常拦截
        SpyAPI.atExceptionExit(
            MyService.class,
            "doSomething|(ILjava/lang/String;)Ljava/lang/String;",
            this,
            new Object[]{Integer.valueOf(a), b},
            __throwable                                             // 异常对象
        );
        throw __throwable;
    }
}

// ========= 增强后（trace 命令，含子调用跟踪）=========
public String doSomething(int a, String b) {
    try {
        SpyAPI.atEnter(...);

        // ④ 子调用前
        SpyAPI.atBeforeInvoke(
            MyService.class,
            "com/example/Helper|doHelp|(I)Ljava/lang/String;|42",  // owner|name|desc|lineNo
            this
        );
        String result = helper(a);
        // ⑤ 子调用后
        SpyAPI.atAfterInvoke(
            MyService.class,
            "com/example/Helper|doHelp|(I)Ljava/lang/String;|42",
            this
        );

        Object __returnObj = result + b;
        SpyAPI.atExit(...);
        return (String) __returnObj;
    } catch (Throwable __throwable) {
        SpyAPI.atExceptionExit(...);
        throw __throwable;
    }
}
```

### 2.3 参数装箱（Boxing）

注意增强代码中的 `new Object[]{Integer.valueOf(a), b}`：

原始参数是 `int a`（基本类型），但 SpyAPI 的参数是 `Object[]`。ASM 在构造 `Object[]` 时会自动将基本类型**装箱**：
- `int` → `Integer.valueOf(int)`
- `long` → `Long.valueOf(long)`
- `boolean` → `Boolean.valueOf(boolean)`
- ...

这就是为什么 SpyTraceInterceptor 的 `excludes` 列表中包含了 `java.lang.Integer`、`java.lang.Long` 等包装类——trace 不应该跟踪这些装箱调用，否则每个方法的 trace 结果都会充满 `Integer.valueOf` 的噪声。

---

## 3. TransformerManager — 三层管道

### 3.1 为什么需要三层？

TransformerManager 只向 JVM 注册了**一个** ClassFileTransformer，但内部管理**三层**：

```
JVM 调用 transform()
    │
    ▼
┌─ reTransformers ────────────────────────────────────────┐
│  用途: retransform 命令（用户上传的自定义 Transformer）  │
│  特点: 最先执行，可以完全替换字节码                      │
│  场景: retransform /tmp/MyService.class                  │
│                                                          │
│  byte[] result1 = reTransformer.transform(classfileBuffer)│
│  if (result1 != null) classfileBuffer = result1;         │
└──────────────────────────┬───────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────┐
│  watchTransformers                                        │
│  用途: watch / monitor / stack / tt 命令                  │
│  特点: 插入方法级拦截（atEnter/atExit/atExceptionExit）  │
│  场景: watch com.example.MyService doSomething            │
│                                                          │
│  byte[] result2 = watchTransformer.transform(classfileBuffer)│
│  if (result2 != null) classfileBuffer = result2;         │
└──────────────────────────┬───────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────┐
│  traceTransformers                                        │
│  用途: trace 命令                                         │
│  特点: 插入调用级拦截（atBeforeInvoke/atAfterInvoke）    │
│  场景: trace com.example.MyService doSomething            │
│                                                          │
│  byte[] result3 = traceTransformer.transform(classfileBuffer)│
│  if (result3 != null) classfileBuffer = result3;         │
└──────────────────────────┬───────────────────────────────┘
                           │
                           ▼
                   返回最终字节码给 JVM
```

**执行顺序的设计原因**：

1. **reTransformers 最先**：retransform 命令是"替换整个类"，必须在所有增强之前，否则增强代码会被覆盖
2. **watchTransformers 中间**：方法级拦截先插入，保证 atEnter/atExit 框架就位
3. **traceTransformers 最后**：trace 在方法内部的每个 INVOKE 前后插入拦截，需要在 watch 增强之后执行

### 3.2 CopyOnWriteArrayList 的使用

```java
private List<ClassFileTransformer> watchTransformers = new CopyOnWriteArrayList<>();
```

三层都用 `CopyOnWriteArrayList`——**读多写少**的最佳选择：
- **读**（每次 retransformClasses 时遍历 Transformer 列表）：无锁，直接遍历数组
- **写**（用户新增/移除命令时）：复制整个数组，开销较大但频率极低

### 3.3 多命令同时增强同一方法

```
场景: 先执行 watch，再执行 trace，都针对 MyService.doSomething()

第一次增强（watch）:
  watchTransformers = [Enhancer-A]
  traceTransformers = []
  → 字节码中插入: atEnter + atExit + atExceptionExit
  → 注册: AdviceListenerManager[MyService.doSomething] = [WatchAdviceListener]

第二次增强（trace）:
  watchTransformers = [Enhancer-A]
  traceTransformers = [Enhancer-B]
  → retransformClasses(MyService.class) 重新触发所有 Transformer

  Enhancer-A.transform():
    → 检查: 字节码已有 SpyAPI.atEnter → GroupLocationFilter 阻止重复插入
    → 但仍然注册新的 AdviceListener
    → 注册: AdviceListenerManager[MyService.doSomething] = [WatchAdviceListener]

  Enhancer-B.transform():
    → 检查: 字节码没有 atBeforeInvoke → 插入调用级拦截
    → 插入: atBeforeInvoke + atAfterInvoke + atInvokeException
    → 注册: AdviceListenerManager[MyService.doSomething] = [WatchAdviceListener, TraceAdviceListener]

结果: 字节码中同时有方法级和调用级拦截，两个命令的 Listener 都被注册
```

**幂等检查的关键代码**：

```java
// Enhancer.transform() 中
if (AsmUtils.containsMethodInsnNode(methodNode, Type.getInternalName(SpyAPI.class), "atBeforeInvoke")) {
    // 已经有 trace 增强了 → 不修改字节码，只注册 listener
    for (AbstractInsnNode insnNode : methodNode.instructions) {
        if (insnNode instanceof MethodInsnNode) {
            MethodInsnNode min = (MethodInsnNode) insnNode;
            AdviceListenerManager.registerTraceAdviceListener(..., min.owner, min.name, min.desc, listener);
        }
    }
} else {
    // 还没有增强 → 执行字节码修改
    MethodProcessor methodProcessor = new MethodProcessor(classNode, methodNode, groupLocationFilter);
    for (InterceptorProcessor interceptor : interceptorProcessors) {
        interceptor.process(methodProcessor);  // bytekit 插入字节码
    }
}
```

这就是"**字节码只改一次，Listener 可以注册多次**"的设计。

---

## 4. EnhancerCommand — 增强命令的公共基座

watch、trace、monitor、stack、tt 这五个命令都继承自 `EnhancerCommand`：

```
                    EnhancerCommand (抽象类)
                    ┌──────────────────────┐
                    │ - excludeClassPattern │
                    │ - classNameMatcher    │
                    │ - methodNameMatcher   │
                    │ - maxNumOfMatchedClass│
                    │                       │
                    │ + process()           │ → 统一入口
                    │ + enhance()           │ → 搜索类 + 创建 Enhancer + retransform
                    │                       │
                    │ # getClassNameMatcher()│ → 抽象，子类实现
                    │ # getMethodNameMatcher()│→ 抽象，子类实现
                    │ # getAdviceListener()  │→ 抽象，子类实现
                    └───────────┬───────────┘
                                │ extends
            ┌───────────────────┼───────────────────┬─────────────────┐
            ▼                   ▼                   ▼                 ▼
    WatchCommand        TraceCommand        MonitorCommand    StackCommand
    │                   │                   │                 │
    │getAdviceListener  │getAdviceListener  │getAdviceListener│getAdviceListener
    │→ WatchAdvice..    │→ TraceAdvice..    │→ MonitorAdvice..│→ StackAdvice..
    │                   │                   │                 │
    └───────────────────┴───────────────────┴─────────────────┘
                                │ extends
                         TimeTunnelCommand
                         │getAdviceListener
                         │→ TimeTunnelAdvice..
```

### 4.1 enhance() 方法的核心流程

```java
protected void enhance(CommandProcess process) {
    // ① 互斥锁
    if (!session.tryLock()) { ... return; }

    // ② 创建 AdviceListener（由子类实现）
    AdviceListener listener = getAdviceListenerWithId(process);

    // ③ 判断是否 trace
    boolean skipJDKTrace = false;
    if (listener instanceof AbstractTraceAdviceListener) {
        skipJDKTrace = ((AbstractTraceAdviceListener) listener).getCommand().isSkipJDKTrace();
    }

    // ④ 创建 Enhancer
    Enhancer enhancer = new Enhancer(listener,
        listener instanceof InvokeTraceable,   // 只有 trace 的 listener 实现了 InvokeTraceable
        skipJDKTrace,
        getClassNameMatcher(), getClassNameExcludeMatcher(), getMethodNameMatcher());

    // ⑤ 注册到 CommandProcess（用于 Ctrl+C 时清理）
    process.register(listener, enhancer);

    // ⑥ 执行增强
    effect = enhancer.enhance(inst, this.maxNumOfMatchedClass);

    // ⑦ 检查结果
    if (effect.cCnt() == 0 || effect.mCnt() == 0) {
        // 没有匹配到类/方法，输出提示
    }
}
```

### 4.2 session.tryLock() — 增强互斥

```java
if (!session.tryLock()) {
    "someone else is enhancing classes, pls. wait."
}
```

**为什么需要互斥？**

`retransformClasses()` 会触发所有已注册 Transformer 的 `transform()` 方法。如果两个命令同时执行增强，它们的 Enhancer 可能会交叉执行 `transform()`，导致字节码被不正确地多次修改。

锁的粒度是 **Session 级别**——同一个 Arthas 连接同一时间只能有一个增强操作。不同 Session 之间**不互斥**（实际上 TransformerManager 和 AdviceListenerManager 是全局的，多 Session 也不会冲突）。

### 4.3 `listener instanceof InvokeTraceable` — trace 判断

```java
new Enhancer(listener, listener instanceof InvokeTraceable, ...)
```

`InvokeTraceable` 接口定义了三个方法：

```java
public interface InvokeTraceable {
    void invokeBeforeTracing(ClassLoader classLoader, String owner, String method, String desc, int lineNumber);
    void invokeAfterTracing(ClassLoader classLoader, String owner, String method, String desc, int lineNumber);
    void invokeThrowTracing(ClassLoader classLoader, String owner, String method, String desc, int lineNumber);
}
```

只有 `TraceAdviceListener` 实现了这个接口。所以 `listener instanceof InvokeTraceable` 等价于"当前命令是 trace"。

---

## 5. 类搜索——怎么找到目标类

### 5.1 SearchUtils.searchClass()

```java
public static Set<Class<?>> searchClass(Instrumentation inst, Matcher<String> classNameMatcher, int limit) {
    final Set<Class<?>> matches = new HashSet<>();
    for (Class<?> clazz : inst.getAllLoadedClasses()) {  // ← 遍历 JVM 所有已加载的类
        if (classNameMatcher.matching(clazz.getName())) {
            matches.add(clazz);
        }
        if (matches.size() >= limit) break;
    }
    return matches;
}
```

`inst.getAllLoadedClasses()` 返回 JVM 中**所有已加载的类**（可能有数万个）。搜索过程是线性遍历 + 通配符匹配。

**通配符匹配规则**（WildcardMatcher）：
- `*` 匹配任意字符序列：`com.example.*` 匹配 `com.example.MyService`
- `?` 匹配单个字符
- 不区分 `.` 和 `/`（统一转换为 `.`）

### 5.2 searchSubClass() — 子类搜索

```java
public static Set<Class<?>> searchSubClass(Instrumentation inst, Set<Class<?>> classSet) {
    for (Class<?> clazz : inst.getAllLoadedClasses()) {
        for (Class<?> superClass : classSet) {
            if (superClass.isAssignableFrom(clazz)) {  // 判断继承关系
                matches.add(clazz);
            }
        }
    }
}
```

当 `options disableSubClass=false`（默认）时，watch/trace 会自动包含目标类的所有子类。例如 watch 一个接口的方法，所有实现类的对应方法都会被增强。

**性能影响**：两层遍历（所有类 × 匹配的父类），在类很多时可能较慢。这就是 `-m 50`（最大匹配 50 个类）默认限制的原因。

---

## 6. 过滤机制——哪些类不能增强

```java
private List<Pair<Class<?>, String>> filter(Set<Class<?>> classes) {
    ...
    if (isSelf(clazz)) { ... }            // Arthas 自己的类
    if (isUnsafeClass(clazz)) { ... }     // BootstrapCL 的类
    if (isExclude(clazz)) { ... }         // 用户指定排除
    if (isUnsupportedClass(clazz)) { ... } // Lambda/接口/特殊类
    ...
}
```

| 过滤条件 | 原因 | 解决方案 |
|----------|------|---------|
| `isSelf(clazz)` — ArthasCL 加载的类 | 增强 Arthas 自己会导致死循环 | 无法绕过 |
| `isUnsafeClass(clazz)` — BootstrapCL 的类 | 增强 JDK 核心类有风险 | `options unsafe true` |
| `isExclude(clazz)` — 用户排除 | 用户通过 `--exclude-class-pattern` 指定 | — |
| Lambda 类 | 匿名类，增强意义不大 | 无法绕过 |
| `java.lang.Integer` | 被 SpyAPI 参数装箱使用，增强会死循环 | 无法绕过 |
| `java.lang.Class` | 增强会影响整个类加载体系 | 无法绕过 |
| `java.lang.reflect.Method` | 反射核心类，增强风险极高 | 无法绕过 |
| 数组类 | 没有可增强的方法 | 无法绕过 |
| 接口（JDK 7 以下） | 没有 default method | JDK 8+ 自动支持 |

### 6.1 Integer 不能增强的深层原因

为什么 `java.lang.Integer` 特别危险？因为增强代码中**到处都在用它**：

```java
// 增强后的代码
SpyAPI.atEnter(clazz, methodInfo, this, new Object[]{Integer.valueOf(a), b});
//                                       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
//                                       参数装箱会调用 Integer.valueOf()
```

如果 Integer.valueOf() 本身也被增强了：

```
Integer.valueOf(42)
  → SpyAPI.atEnter(Integer.class, "valueOf|...", null, new Object[]{Integer.valueOf(42)})
                                                       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
                                                       又调用了 Integer.valueOf() → 递归！
```

**无限递归 → StackOverflowError → JVM 崩溃**。

---

## 7. reset — 恢复原始字节码

```java
public static synchronized EnhancerAffect reset(Instrumentation inst, Matcher classNameMatcher) {
    // ① 从缓存中找到被增强过的类
    Set<Class<?>> enhanceClassSet = new HashSet<>();
    for (Class<?> classInCache : classBytesCache.keySet()) {
        if (classNameMatcher.matching(classInCache.getName())) {
            enhanceClassSet.add(classInCache);
        }
    }

    // ② 重新 retransformClasses
    inst.retransformClasses(classArray);

    // ③ 清理缓存
    for (Class<?> resetClass : enhanceClassSet) {
        classBytesCache.remove(resetClass);
    }
}
```

**reset 是怎么恢复的？**

关键在于 `retransformClasses()` 的工作机制：

1. JVM 会把类的**原始字节码**（首次加载时的版本）传给所有注册的 ClassFileTransformer
2. 如果所有 Transformer 都返回 null（不修改），JVM 就用原始字节码替换当前字节码

所以 reset 的流程是：
1. 移除对应的 Enhancer（通过 `TransformerManager.removeTransformer()`）
2. 调用 `retransformClasses()`
3. 此时没有 Enhancer 了，所有 Transformer 返回 null
4. JVM 恢复到原始字节码 ✓

> **注意**：`classBytesCache` 使用 `WeakHashMap<Class<?>, Object>`——如果类被 GC 卸载了，缓存自动清理，不会内存泄漏。

---

## 8. AdviceListener 生命周期

```
┌──────────────────── 创建阶段 ─────────────────────┐
│                                                     │
│  EnhancerCommand.enhance()                          │
│    → getAdviceListener(process)                     │
│      → new WatchAdviceListener(process, ...)        │
│    → AdviceWeaver.reg(listener)                     │
│      → listener.create()          ← 初始化         │
│      → advices.put(id, listener)  ← 全局注册       │
│                                                     │
└─────────────────────────────────────────────────────┘
                    │
                    ▼
┌──────────────────── 运行阶段 ─────────────────────┐
│                                                     │
│  目标方法每次被调用时:                               │
│    SpyAPI.atEnter() → SpyImpl.atEnter()             │
│      → AdviceListenerManager.queryAdviceListeners() │
│        → [WatchAdviceListener]                      │
│      → listener.before(clazz, method, ...)          │
│                                                     │
│    SpyAPI.atExit() → SpyImpl.atExit()               │
│      → listener.afterReturning(clazz, method, ...)  │
│                                                     │
└─────────────────────────────────────────────────────┘
                    │
                    ▼
┌──────────────────── 销毁阶段 ─────────────────────┐
│                                                     │
│  用户 Ctrl+C 或命令超时:                            │
│    → process.end()                                  │
│      → AdviceWeaver.unReg(listener)                 │
│        → advices.remove(id)                         │
│        → listener.destroy()      ← 清理            │
│      → TransformerManager.removeTransformer(enhancer)│
│      → inst.retransformClasses() ← 恢复字节码      │
│                                                     │
└─────────────────────────────────────────────────────┘
```

### 两套注册中心的分工

```
AdviceWeaver (按 adviceId 注册):
  作用: 管理 AdviceListener 的生命周期
  key: long adviceId → AdviceListener
  用途: process.register/unregister, 复用已有 listener (--listenerId)

AdviceListenerManager (按 ClassLoader+方法 注册):
  作用: 运行时快速查找该方法的所有 listener
  key: ClassLoader → className+methodName+desc → List<AdviceListener>
  用途: SpyImpl 中的运行时回调分发
```

---

## 9. 小结

```
                         字节码增强引擎全景

用户命令                          内部流程                        字节码
────────                        ──────────                      ──────
watch/trace/                    EnhancerCommand.enhance()
monitor/stack/tt                       │
        │                              ▼
        │                    SearchUtils.searchClass()         目标类的
        │                    → inst.getAllLoadedClasses()       原始字节码
        │                    → WildcardMatcher/RegexMatcher    ──────────
        │                    → filter() 过滤不可增强的类             │
        │                              │                            │
        │                              ▼                            ▼
        │                    new Enhancer(listener, isTracing)     ASM
        │                    TransformerManager.addTransformer()  ClassReader
        │                              │                            │
        │                              ▼                            ▼
        │                    inst.retransformClasses()        MethodProcessor
        │                              │                     InterceptorProcessor
        │                              ▼                            │
        │                    Enhancer.transform()                   ▼
        │                    → SpyInterceptors 模板          增强后的字节码
        │                    → bytekit 插入 SpyAPI 调用      ──────────────
        │                    → AdviceListenerManager 注册     SpyAPI.atEnter
        │                              │                     SpyAPI.atExit
        │                              ▼                     SpyAPI.atException
        └──── Ctrl+C ──→ reset()                             SpyAPI.atBeforeInvoke
                         → removeTransformer()               SpyAPI.atAfterInvoke
                         → retransformClasses()
                         → JVM 恢复原始字节码
```

| 设计决策 | 实现方式 | 解决的问题 |
|----------|---------|-----------|
| 只用一个 ClassFileTransformer | TransformerManager 聚合三层 | JVM 只允许有限的 Transformer |
| 三层执行顺序 | re → watch → trace | retransform 不被覆盖，trace 在 watch 之后 |
| 幂等增强 | GroupLocationFilter 检查 + 已有桩时只注册 | 多命令不重复插入字节码 |
| 字节码安全 | 排除 Integer/Class/Lambda 等 | 避免递归和 JVM 崩溃 |
| 增强互斥 | session.tryLock() | 避免并发 retransform 导致字节码错乱 |
| WeakHashMap 缓存 | classBytesCache | 类卸载后自动释放 |
| 子类自动增强 | searchSubClass + isAssignableFrom | watch 接口自动覆盖所有实现类 |

> **与 async-profiler 的对比**：async-profiler 使用 JVMTI + perf_events 采样，**完全不修改字节码**，零运行时开销。Arthas 的字节码增强能实现条件过滤和表达式求值，但有一定运行时开销。两者互补。

---

> **下一节**: [Ch 6 OGNL 表达式引擎](ch06_1_ognl_express.md) — watch/trace 中的 `'{params,returnObj}'` 怎么被求值？
