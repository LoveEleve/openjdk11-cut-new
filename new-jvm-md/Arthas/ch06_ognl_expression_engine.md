
# Ch 6 OGNL 表达式引擎 — watch/trace 的灵魂

> 源文件:
> - `core/command/express/OgnlExpress.java` (66行) — 表达式求值核心
> - `core/command/express/Express.java` (52行) — 表达式接口
> - `core/command/express/ExpressFactory.java` (31行) — ThreadLocal 工厂
> - `core/command/express/DefaultMemberAccess.java` (111行) — private 字段访问控制
> - `core/command/express/CustomClassResolver.java` (44行) — 上下文感知的类解析
> - `core/command/express/ClassLoaderClassResolver.java` (42行) — 指定 ClassLoader 的类解析
> - `core/command/express/ArthasObjectPropertyAccessor.java` (23行) — strict 模式拦截
> - `core/advisor/Advice.java` (146行) — OGNL root 对象
> - `core/advisor/AdviceListenerAdapter.java` (157行) — OGNL 的核心调用者
> - `core/command/klass100/OgnlCommand.java` (117行) — ognl 独立命令

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **Ch 6 OGNL 表达式引擎 — watch/trace 的灵魂**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 0. 先回答"为什么"

字节码增强引擎（Ch5）负责在方法入口/出口/异常处插入 SpyAPI 调用，但**插桩只是获取了回调时机**。用户真正想要的是：

- **条件过滤**：`watch ... '#cost > 100'` — 只在方法耗时超过 100ms 时输出
- **数据提取**：`watch ... '{params[0], returnObj}'` — 只看第一个参数和返回值
- **对象操作**：`watch ... 'target.userCache.size()'` — 直接调用目标对象的方法

这些灵活的表达能力，都来自 **OGNL（Object-Graph Navigation Language）表达式引擎**。

本章解答的核心问题：

1. OGNL 表达式**在哪里被求值**？求值的输入和输出是什么？
2. 用户写的 `params`、`returnObj`、`#cost` 是**怎么绑定到实际值**的？
3. OGNL 怎么**跨越 ClassLoader 边界**访问目标应用的类？
4. OGNL 怎么能**访问 private 字段**？安全性如何保障？

---

## 1. 整体架构——六个类的协作

```
                    用户输入                              内部流程
                    ──────                              ──────
          watch com.example.MyService                 AdviceListenerAdapter
          doSomething                                        │
          '{params, returnObj}'  ← 数据表达式                 │
          '#cost > 100'         ← 条件表达式                  │
                                                             ▼
┌─────────────────────────── OGNL 求值层 ──────────────────────────────────┐
│                                                                          │
│  ExpressFactory                                                          │
│  ┌───────────────────────────────┐                                       │
│  │ ThreadLocal<Express>           │  每个线程一个 OgnlExpress 实例        │
│  │ threadLocalExpress(advice)     │  → reset() → bind(advice) → 返回     │
│  └───────────────┬───────────────┘                                       │
│                  │                                                        │
│                  ▼                                                        │
│  OgnlExpress                                                             │
│  ┌───────────────────────────────┐                                       │
│  │ bindObject = Advice 对象       │  ← OGNL root（params/returnObj等）   │
│  │ context.put("cost", 耗时)      │  ← OGNL 变量（#cost）               │
│  │                               │                                       │
│  │ get(express)                   │  → Ognl.getValue(expr, ctx, root)    │
│  │ is(conditionExpress)           │  → get() + 转 Boolean               │
│  └───────────────┬───────────────┘                                       │
│                  │                                                        │
│      ┌───────────┼───────────┬────────────────────┐                      │
│      ▼           ▼           ▼                    ▼                      │
│  MemberAccess  ClassResolver PropertyAccessor  OgnlContext               │
│  ┌───────────┐ ┌───────────┐ ┌─────────────┐ ┌──────────────┐           │
│  │Default    │ │Custom     │ │ArthasObject │ │OgnlContext   │           │
│  │MemberAcces│ │ClassResolv│ │PropertyAcces│ │(OGNL 标准)   │           │
│  │           │ │           │ │             │ │              │           │
│  │允许 private│ │TCCL 优先  │ │strict 模式  │ │变量存储       │           │
│  │字段访问    │ │+ 缓存     │ │属性写入拦截  │ │#cost 等      │           │
│  └───────────┘ └───────────┘ └─────────────┘ └──────────────┘           │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

**六个类的职责分工**：

| 类 | 职责 | 关键行为 |
|----|------|---------|
| `Express` | 接口定义 | get/is/bind/reset |
| `OgnlExpress` | 求值核心 | 调用 OGNL 库的 getValue |
| `ExpressFactory` | ThreadLocal 工厂 | 每个线程复用一个 OgnlExpress |
| `DefaultMemberAccess` | 访问控制 | 允许 private/protected 字段访问 |
| `CustomClassResolver` | 类名解析 | 用 TCCL（Thread Context ClassLoader）加载类 |
| `ArthasObjectPropertyAccessor` | 属性写入拦截 | strict 模式下禁止修改对象属性 |

---

## 2. OgnlExpress — 求值核心（66 行）

### 2.1 构造函数——三个全局组件的装配

```java
public class OgnlExpress implements Express {
    // ① 全局单例——所有 OgnlExpress 实例共享
    private static final MemberAccess MEMBER_ACCESS = new DefaultMemberAccess(true);
    private static final ArthasObjectPropertyAccessor OBJECT_PROPERTY_ACCESSOR = new ArthasObjectPropertyAccessor();

    // ② 实例字段
    private Object bindObject;           // OGNL root 对象（Advice）
    private final OgnlContext context;   // OGNL 上下文（存储 #变量）

    public OgnlExpress(ClassResolver classResolver) {
        // ③ 注册全局 PropertyAccessor——对所有 Object 类生效
        OgnlRuntime.setPropertyAccessor(Object.class, OBJECT_PROPERTY_ACCESSOR);

        // ④ 创建 OgnlContext，装配三个组件
        context = new OgnlContext(MEMBER_ACCESS, classResolver, null, null);
        //                       ^^^^^^^^^^^    ^^^^^^^^^^^^^
        //                       访问控制器      类名解析器
    }
}
```

**OgnlContext 的四个参数**：

| 参数 | 作用 | Arthas 传入 |
|------|------|------------|
| `memberAccess` | 控制是否可以访问 private/protected 成员 | `DefaultMemberAccess(true)` — 允许所有访问 |
| `classResolver` | OGNL 中引用类名时如何解析（如 `@System@out`） | `CustomClassResolver` — 用 TCCL |
| `typeConverter` | 类型转换器 | `null` — 用默认 |
| `propertyAccessor` | 属性访问器（不是这里注册的） | `null` |

### 2.2 get() — 表达式求值

```java
@Override
public Object get(String express) throws ExpressException {
    try {
        return Ognl.getValue(express, context, bindObject);
        //     ^^^^^^^^^^^^^
        //     OGNL 库的静态方法
        //     express = "{params, returnObj}"
        //     context = OgnlContext（包含 #cost 等变量）
        //     bindObject = Advice 对象（OGNL 的 root）
    } catch (Exception e) {
        logger.error("Error during evaluating the expression:", e);
        throw new ExpressException(express, e);
    }
}
```

`Ognl.getValue()` 做了什么：
1. **解析**：将字符串表达式编译成 OGNL AST（抽象语法树）
2. **求值**：遍历 AST，对 root 对象（Advice）执行属性访问、方法调用
3. **返回**：求值结果

### 2.3 is() — 条件判断

```java
@Override
public boolean is(String express) throws ExpressException {
    final Object ret = get(express);
    return ret instanceof Boolean && (Boolean) ret;
}
```

简单封装：调用 `get()` 求值，然后检查结果是否为 `true`。

**关键细节**：如果表达式结果**不是 Boolean 类型**（比如返回了一个 String），`is()` 返回 `false`——不会抛异常，只是静默认为条件不满足。

### 2.4 bind() 和 reset() — 变量绑定

```java
// 绑定 root 对象（Advice）
@Override
public Express bind(Object object) {
    this.bindObject = object;
    return this;
}

// 绑定上下文变量（#cost 等）
@Override
public Express bind(String name, Object value) {
    context.put(name, value);
    return this;
}

// 重置（清除所有变量绑定）
@Override
public Express reset() {
    context.clear();
    return this;
}
```

**链式调用**：所有 bind/reset 方法返回 `this`，支持 `express.reset().bind(advice).bind("cost", cost).get(expr)` 。

---

## 3. Advice — OGNL 的 root 对象

当用户写 `watch ... '{params, returnObj}'` 时，`params` 和 `returnObj` 是怎么被解析的？

答案：Advice 是 OGNL 的 **root 对象**，OGNL 会自动调用 root 对象的 getter 方法。

```java
public class Advice {
    private final ClassLoader loader;     // ognl: loader
    private final Class<?> clazz;         // ognl: clazz
    private final ArthasMethod method;    // ognl: method
    private final Object target;          // ognl: target
    private final Object[] params;        // ognl: params
    private final Object returnObj;       // ognl: returnObj
    private final Throwable throwExp;     // ognl: throwExp
    private final boolean isBefore;       // ognl: isBefore
    private final boolean isThrow;        // ognl: isThrow （注意：isAfterThrowing()）
    private final boolean isReturn;       // ognl: isReturn （注意：isAfterReturning()）
}
```

### 3.1 OGNL 表达式 → Advice getter 的映射

| OGNL 表达式 | 实际调用 | 含义 |
|-------------|---------|------|
| `params` | `advice.getParams()` | 方法参数数组 |
| `params[0]` | `advice.getParams()[0]` | 第一个参数 |
| `returnObj` | `advice.getReturnObj()` | 返回值 |
| `throwExp` | `advice.getThrowExp()` | 抛出的异常 |
| `target` | `advice.getTarget()` | this 对象（静态方法为 null） |
| `target.name` | `advice.getTarget().getName()` | this 对象的 name 字段 |
| `clazz` | `advice.getClazz()` | 方法所在的 Class 对象 |
| `clazz.name` | `advice.getClazz().getName()` | 类名 |
| `method.name` | `advice.getMethod().getName()` | 方法名 |
| `isBefore` | `advice.isBefore()` | 是否在方法入口 |
| `isReturn` | `advice.isAfterReturning()` | 是否正常返回 |
| `isThrow` | `advice.isAfterThrowing()` | 是否异常返回 |
| `#cost` | `context.get("cost")` | 方法耗时（ms）— **#号变量** |

### 3.2 #号变量 vs 普通变量

OGNL 区分两种变量：

- **普通变量**（无 # 前缀）：从 root 对象（Advice）的 getter 获取
  - `params` → `root.getParams()`
  - `target.name` → `root.getTarget().getName()`

- **#号变量**（# 前缀）：从 OgnlContext 的 map 获取
  - `#cost` → `context.get("cost")`
  - `#root` → root 对象本身（OGNL 内置）

### 3.3 Advice 的三种创建场景

```java
// 方法入口（SpyAPI.atEnter 回调时）
Advice.newForBefore(loader, clazz, method, target, args)
→ returnObj=null, throwExp=null, access=BEFORE

// 方法正常返回（SpyAPI.atExit 回调时）
Advice.newForAfterReturning(loader, clazz, method, target, args, returnObj)
→ throwExp=null, access=AFTER_RETURNING

// 方法异常返回（SpyAPI.atExceptionExit 回调时）
Advice.newForAfterThrowing(loader, clazz, method, target, args, throwExp)
→ returnObj=null, access=AFTER_THROWING
```

这意味着：
- 在 `-b`（before）观测点，`returnObj` 和 `throwExp` **都是 null**
- 在 `-s`（success）观测点，只有 `returnObj` 有值
- 在 `-e`（exception）观测点，只有 `throwExp` 有值

---

## 4. AdviceListenerAdapter — OGNL 的核心调用者

### 4.1 isConditionMet() — 条件过滤

```java
protected boolean isConditionMet(String conditionExpress, Advice advice, double cost) 
        throws ExpressException {
    return StringUtils.isEmpty(conditionExpress)   // 没有条件 → 直接通过
            || ExpressFactory.threadLocalExpress(advice)    // 获取 ThreadLocal Express
                    .bind(Constants.COST_VARIABLE, cost)    // 绑定 #cost
                    .is(conditionExpress);                  // 求值条件表达式
}
```

**调用链**：

```
WatchAdviceListener.watching()
  → isConditionMet("#cost > 100", advice, 150.3)
    → ExpressFactory.threadLocalExpress(advice)
      → expressRef.get()                       // ThreadLocal 获取 OgnlExpress
      → .reset()                               // 清除上次的变量
      → .bind(advice)                          // 绑定 root = Advice
    → .bind("cost", 150.3)                     // context["cost"] = 150.3
    → .is("#cost > 100")                       // 求值: 150.3 > 100 → true
      → .get("#cost > 100")                    // OGNL: context["cost"] > 100
        → Ognl.getValue("#cost > 100", context, advice)
        → 返回 Boolean.TRUE
      → true
```

### 4.2 getExpressionResult() — 数据提取

```java
protected Object getExpressionResult(String express, Advice advice, double cost) 
        throws ExpressException {
    return ExpressFactory.threadLocalExpress(advice)
            .bind(Constants.COST_VARIABLE, cost)
            .get(express);
}
```

和条件求值几乎一样，只是调用 `get()` 而不是 `is()`。

### 4.3 在 WatchAdviceListener 中的实际使用

```java
private void watching(Advice advice) {
    try {
        double cost = threadLocalWatch.costInMillis();       // ① 计算耗时

        // ② 条件过滤
        boolean conditionResult = isConditionMet(
            command.getConditionExpress(),  // 如 "#cost > 100"
            advice,                         // Advice 对象
            cost                            // 如 150.3 (ms)
        );

        if (conditionResult) {
            // ③ 数据提取
            Object value = getExpressionResult(
                command.getExpress(),  // 如 "{params, returnObj}"
                advice, cost
            );

            // ④ 构建输出模型
            WatchModel model = new WatchModel();
            model.setValue(new ObjectVO(value, command.getExpand()));  // -x 展开深度
            process.appendResult(model);

            // ⑤ 次数限制
            process.times().incrementAndGet();
            if (isLimitExceeded(command.getNumberOfLimit(), process.times().get())) {
                abortProcess(process, command.getNumberOfLimit());  // 达到 -n 次数，终止
            }
        }
    } catch (Throwable e) {
        // 表达式求值失败，终止命令
        process.end(-1, "watch failed, condition is: " + command.getConditionExpress()
            + ", express is: " + command.getExpress() + ", " + e.getMessage());
    }
}
```

**watch 命令的完整数据流**：

```
用户输入: watch com.example.MyService doSomething '{params, returnObj}' '#cost > 100' -x 2

方法被调用时:
  SpyAPI.atExit()
    → SpyImpl.atExit()
      → AdviceListenerManager.queryAdviceListeners()
        → [WatchAdviceListener]
          → listener.afterReturning(loader, clazz, method, target, args, returnObj)
            → Advice.newForAfterReturning(...)
              → advice = Advice{params=[arg1,arg2], returnObj=result, ...}
            → watching(advice)
              → cost = 150.3ms
              → isConditionMet("#cost > 100", advice, 150.3)
                → OGNL: #cost > 100 → true
              → getExpressionResult("{params, returnObj}", advice, 150.3)
                → OGNL: {advice.getParams(), advice.getReturnObj()}
                → [Object[]{arg1, arg2}, result]
              → ObjectVO(value, expand=2) → 深度展开到 2 层
              → process.appendResult(watchModel) → 输出到终端
```

---

## 5. ExpressFactory — ThreadLocal 复用设计

### 5.1 为什么用 ThreadLocal？

```java
public class ExpressFactory {
    private static final ThreadLocal<Express> expressRef = new ThreadLocal<Express>() {
        @Override
        protected Express initialValue() {
            return new OgnlExpress();
        }
    };

    public static Express threadLocalExpress(Object object) {
        return expressRef.get().reset().bind(object);
    }
}
```

**问题**：watch/trace 等命令的回调发生在**目标应用的线程**中（不是 Arthas 自己的线程）。如果每次回调都 `new OgnlExpress()`，开销太大——OgnlExpress 构造需要创建 OgnlContext、注册 PropertyAccessor 等。

**解决**：ThreadLocal 复用——每个线程只创建一个 OgnlExpress 实例，通过 `reset().bind()` 重置后复用。

**调用模式**：`expressRef.get()` → `reset()` → `bind(advice)` → `bind("cost", cost)` → `get(expr)` / `is(expr)`

### 5.2 unpooledExpress() — 非池化模式

```java
public static Express unpooledExpress(ClassLoader classloader) {
    if (classloader == null) {
        classloader = ClassLoader.getSystemClassLoader();
    }
    return new OgnlExpress(new ClassLoaderClassResolver(classloader));
}
```

**使用场景**：`ognl` 独立命令（不是通过增强回调触发的，而是用户直接执行）。

**区别**：
| 特性 | threadLocalExpress | unpooledExpress |
|------|--------------------|-----------------|
| 复用 | ✅ ThreadLocal 复用 | ❌ 每次新建 |
| ClassResolver | CustomClassResolver（TCCL） | ClassLoaderClassResolver（指定 CL） |
| 使用场景 | watch/trace/monitor/stack/tt 回调 | ognl 独立命令 |
| 类加载器 | 自动使用当前线程的 TCCL | 用户通过 `-c hashcode` 指定 |

---

## 6. ClassLoader 感知——跨越隔离边界

### 6.1 核心问题

OGNL 表达式中可能引用目标应用的类，例如：

```bash
watch ... '@com.example.AppConfig@getInstance().getTimeout()'
```

这里的 `com.example.AppConfig` 是目标应用的类，由 AppClassLoader 加载。但 OGNL 引擎运行在 ArthasClassloader 中。**如何跨越 ClassLoader 边界找到这个类？**

### 6.2 CustomClassResolver — TCCL 策略

```java
public class CustomClassResolver implements ClassResolver {
    // 全局单例（供 ThreadLocal Express 使用）
    public static final CustomClassResolver customClassResolver = new CustomClassResolver();

    // 类名缓存（避免重复加载）
    private Map<String, Class<?>> classes = new ConcurrentHashMap<>(101);

    @Override
    public Class classForName(String className, Map context) throws ClassNotFoundException {
        Class<?> result = null;

        // ① 缓存查找
        if ((result = classes.get(className)) == null) {
            try {
                // ② 优先使用 TCCL（Thread Context ClassLoader）
                ClassLoader classLoader = Thread.currentThread().getContextClassLoader();
                if (classLoader != null) {
                    result = classLoader.loadClass(className);
                } else {
                    // ③ 兜底：Class.forName（使用调用者的 ClassLoader）
                    result = Class.forName(className);
                }
            } catch (ClassNotFoundException ex) {
                // ④ 短类名支持：自动加 java.lang. 前缀
                if (className.indexOf('.') == -1) {
                    result = Class.forName("java.lang." + className);
                    classes.put("java.lang." + className, result);
                }
            }
            // ⑤ 放入缓存
            classes.put(className, result);
        }
        return result;
    }
}
```

**为什么 TCCL 能找到目标应用的类？**

关键在于 SpyAPI 的回调发生在**目标应用的线程**中：

```
目标应用线程（AppCL）
  → MyService.doSomething()              ← AppCL 加载的方法
    → SpyAPI.atExit()                    ← BootstrapCL
      → SpyImpl.atExit()                ← ArthasCL
        → WatchAdviceListener.watching() ← ArthasCL
          → OGNL 求值                    ← ArthasCL
            → CustomClassResolver.classForName("com.example.AppConfig")
              → Thread.currentThread().getContextClassLoader()
              → 返回的是 AppCL！         ← 因为当前线程是目标应用的线程
              → AppCL.loadClass("com.example.AppConfig")
              → 成功找到类 ✓
```

TCCL 的值在线程创建时被设置为创建线程的 ClassLoader，对于目标应用的线程，TCCL 就是 AppClassLoader。这是 Java EE 时代的标准做法，被 Arthas 巧妙利用。

### 6.3 ClassLoaderClassResolver — 指定 ClassLoader

```java
public class ClassLoaderClassResolver implements ClassResolver {
    private ClassLoader classLoader;  // 用户指定的 ClassLoader

    @Override
    public Class classForName(String className, Map context) throws ClassNotFoundException {
        // 直接用指定的 ClassLoader 加载
        result = classLoader.loadClass(className);
    }
}
```

**使用场景**：`ognl` 独立命令通过 `-c hashcode` 指定 ClassLoader：

```bash
ognl -c 5d113a51 '@com.example.AppConfig@getInstance()'
```

因为 `ognl` 命令不在目标线程中执行（在 Arthas 的 Shell 线程中），TCCL 不是 AppClassLoader，所以需要用户显式指定。

### 6.4 两种 ClassResolver 的对比

```
                           watch/trace 等增强命令             ognl 独立命令
                           ─────────────────────             ─────────────
执行线程                    目标应用线程                      Arthas Shell 线程
TCCL                       AppClassLoader ✓                  ArthasClassLoader ✗
ClassResolver              CustomClassResolver               ClassLoaderClassResolver
类解析方式                  TCCL.loadClass() ← 自动           指定CL.loadClass() ← 手动
用户操作                    无需指定 ClassLoader               需要 -c hashcode
```

---

## 7. DefaultMemberAccess — 访问 private 字段

### 7.1 问题

默认情况下，OGNL 只能访问 public 成员。但诊断场景中，用户经常需要查看 private 字段：

```bash
watch ... 'target.internalCache'  # internalCache 是 private 的
```

### 7.2 实现

```java
public class DefaultMemberAccess implements MemberAccess {
    public boolean allowPrivateAccess = false;
    public boolean allowProtectedAccess = false;
    public boolean allowPackageProtectedAccess = false;

    public DefaultMemberAccess(boolean allowAllAccess) {
        // Arthas 传入 true → 允许所有访问级别
        this(allowAllAccess, allowAllAccess, allowAllAccess);
    }
```

**setup/restore 模式**：

```java
// 在访问 private 成员前调用
@Override
public Object setup(Map context, Object target, Member member, String propertyName) {
    Object result = null;
    if (isAccessible(context, target, member, propertyName)) {
        AccessibleObject accessible = (AccessibleObject) member;
        if (!accessible.isAccessible()) {
            result = Boolean.TRUE;             // 记录原始状态
            accessible.setAccessible(true);     // 临时打开访问权限
        }
    }
    return result;  // 返回"需要恢复"的标记
}

// 访问完成后调用
@Override
public void restore(Map context, Object target, Member member, String propertyName, Object state) {
    if (state != null) {
        ((AccessibleObject) member).setAccessible((Boolean) state);  // 恢复原始权限
    }
}
```

**流程**：OGNL 访问对象属性时的调用序列：

```
OGNL 需要访问 target.privateField
  → memberAccess.isAccessible(member)  → true（Arthas 允许所有访问）
  → memberAccess.setup(member)         → setAccessible(true)
  → Field.get(target)                  → 获取 private 字段值
  → memberAccess.restore(member)       → setAccessible(false)（恢复）
```

**安全性考虑**：这是诊断工具的必要能力——如果不能访问 private 字段，很多诊断场景就无法完成。Arthas 运行在目标 JVM 中，本身就有完全的访问权限，`setAccessible` 只是显式声明。

---

## 8. ArthasObjectPropertyAccessor — strict 模式

### 8.1 问题

OGNL 表达式不仅能**读取**属性，还能**写入**属性：

```bash
ognl 'target.timeout = 5000'  # 危险！修改了目标对象的状态
```

在诊断场景中，意外修改对象状态可能导致严重后果。

### 8.2 实现

```java
public class ArthasObjectPropertyAccessor extends ObjectPropertyAccessor {
    @Override
    public Object setPossibleProperty(Map context, Object target, String name, Object value) 
            throws OgnlException {
        if (GlobalOptions.strict) {
            throw new IllegalAccessError(GlobalOptions.STRICT_MESSAGE);
            // "By default, strict mode is true, not allowed to set object properties.
            //  Want to set object properties, execute `options strict false`"
        }
        return super.setPossibleProperty(context, target, name, value);
    }
}
```

**默认行为**：`GlobalOptions.strict = true`，所有属性写入操作被拦截并抛出异常。

**解除限制**：用户需要显式执行 `options strict false`，才能通过 OGNL 修改对象属性。

### 8.3 updateOnglStrict() — Unsafe 修改 OGNL 内部状态

```java
public static void updateOnglStrict(boolean strict) {
    try {
        Field field = OgnlRuntime.class.getDeclaredField("_useStricterInvocation");
        field.setAccessible(true);
        Object staticFieldBase = UnsafeUtils.UNSAFE.staticFieldBase(field);
        long staticFieldOffset = UnsafeUtils.UNSAFE.staticFieldOffset(field);
        UnsafeUtils.UNSAFE.putBoolean(staticFieldBase, staticFieldOffset, strict);
    } catch (NoSuchFieldException | SecurityException e) {
        // ignore
    }
}
```

**为什么用 Unsafe？** OGNL 库内部有一个 `_useStricterInvocation` 字段，控制是否允许"危险"方法调用。这个字段在 OGNL 新版本中改为 `final` 了，用普通反射无法修改，只能用 `Unsafe.putBoolean` 直接改内存。

---

## 9. ognl 独立命令 — 不依赖增强的表达式求值

### 9.1 与 watch 表达式的区别

| 特性 | watch 中的表达式 | ognl 命令的表达式 |
|------|-----------------|-----------------|
| 触发时机 | 方法被调用时 | 用户手动执行 |
| root 对象 | Advice（包含 params/returnObj 等） | `new Object()`（空对象） |
| 可用变量 | params/returnObj/throwExp/target/#cost | 无预定义变量 |
| ClassResolver | CustomClassResolver（TCCL） | ClassLoaderClassResolver（指定 CL） |
| Express 复用 | ThreadLocal 复用 | 每次新建 |
| 典型用法 | 观测方法运行时状态 | 执行静态方法、读取静态字段 |

### 9.2 OgnlCommand 的核心流程

```java
@Override
public void process(CommandProcess process) {
    // ① ClassLoader 选择（三种方式）
    ClassLoader classLoader = null;
    if (hashCode != null) {
        // 方式一：-c hashcode 指定
        classLoader = ClassLoaderUtils.getClassLoader(inst, hashCode);
    } else if (classLoaderClass != null) {
        // 方式二：--classLoaderClass 指定
        classLoader = ClassLoaderUtils.getClassLoaderByClassName(inst, classLoaderClass);
    } else {
        // 方式三：默认 SystemClassLoader
        classLoader = ClassLoader.getSystemClassLoader();
    }

    // ② 创建非池化 Express（每次新建，使用指定 CL）
    Express unpooledExpress = ExpressFactory.unpooledExpress(classLoader);

    // ③ 求值
    Object value = unpooledExpress.bind(new Object()).get(express);
    //                             ^^^^^^^^^^^^^^^^
    //                             root 是一个空 Object（不是 Advice）
}
```

**实际示例**：

```bash
# 调用静态方法
ognl '@java.lang.System@getProperty("java.home")'
# OGNL 解析: 找到 System 类，调用 getProperty 静态方法

# 获取单例对象
ognl -c 5d113a51 '@com.example.AppConfig@getInstance().getTimeout()'
# OGNL 解析: 通过指定的 CL 加载 AppConfig，调用 getInstance()，再调用 getTimeout()

# 多表达式组合
ognl '#v1=@System@getProperty("java.home"), #v2=@System@getProperty("java.runtime.name"), {#v1, #v2}'
# OGNL 解析: 定义两个临时变量，组合成 List 返回
```

---

## 10. 耗时统计 — ThreadLocalWatch

OGNL 条件中最常用的内置变量是 `#cost`（方法耗时），它的值来自 ThreadLocalWatch：

```java
public class ThreadLocalWatch {
    private final ThreadLocal<LongStack> timestampRef = ...;

    public long start() {
        final long timestamp = System.nanoTime();    // 纳秒级计时
        timestampRef.get().push(timestamp);           // 入栈
        return timestamp;
    }

    public double costInMillis() {
        return (System.nanoTime() - timestampRef.get().pop()) / 1000000.0;  // 出栈 + 计算
    }
}
```

### 10.1 为什么用栈而不是单个变量？

因为方法可能**嵌套调用**：

```
A.method() → before()  → push(T1)
  B.method() → before()  → push(T2)
  B.method() → after()   → pop(T2) → cost = now - T2
A.method() → after()   → pop(T1) → cost = now - T1
```

栈结构保证了嵌套调用时，每次 `pop` 取到的是**最近一次 `push`** 的时间戳。

### 10.2 LongStack 的循环设计

```java
static class LongStack {
    private long[] array;
    private int pos = 0;
    private int cap;  // 默认 4096

    public void push(long value) {
        if (pos < cap) {
            array[pos++] = value;
        } else {
            pos = 0;               // 到达容量上限 → 重置，循环覆盖
            array[pos++] = value;
        }
    }
}
```

**为什么不用 ArrayList？**

1. **固定大小**：避免内存泄漏。push/pop 可能不成对（方法被中断时 pop 不会执行），如果用 ArrayList 会一直增长
2. **循环覆盖**：到达容量上限后从头开始写。极端情况下统计数据不准确，但不会 OOM
3. **基本类型数组**：`long[]` 比 `Long[]` 少一层装箱，性能更好

---

## 11. 小结

```
                      OGNL 表达式引擎全景

   用户命令                    数据流                       OGNL 内部
   ──────                    ──────                       ─────────
   watch ... '{params}'     SpyAPI.atExit()               OgnlExpress
   '#cost > 100'             → WatchAdviceListener          │
       │                       → watching(advice)           │
       │                          │                         ▼
       │              ┌───────────┼────────────┐     Ognl.getValue(
       │              │           │            │       expr,
       │              ▼           ▼            ▼       context, ← #cost 等
       │         isConditionMet  getExpressionResult   advice)  ← root
       │              │           │                      │
       │              │           │                      ▼
       │              │           │               ┌──────────────┐
       │              │           │               │CustomClassRes│
       │              │           │               │→ TCCL.load() │
       │              │           │               └──────────────┘
       │              │           │               ┌──────────────┐
       │              │           │               │DefaultMember │
       │              │           │               │→ setAccessibl│
       │              │           │               └──────────────┘
       │              │           │               ┌──────────────┐
       │              │           │               │ArthasProperty│
       │              │           │               │→ strict 检查  │
       │              │           │               └──────────────┘
       ▼              ▼           ▼
   ognl 命令      条件: true/false  值: Object       
   → unpooled      ↓               ↓
   → 指定 CL      过滤             渲染输出
```

### 设计决策总结

| 设计决策 | 实现方式 | 解决的问题 |
|----------|---------|-----------|
| ThreadLocal 复用 | `ExpressFactory.threadLocalExpress()` | 避免每次回调创建 OgnlExpress |
| TCCL 策略 | `CustomClassResolver` 优先用 TCCL | 自动找到目标应用的类 |
| 指定 CL 策略 | `ClassLoaderClassResolver` + `-c hashcode` | ognl 命令手动指定 |
| 允许 private 访问 | `DefaultMemberAccess(true)` + setAccessible | 诊断需要查看所有字段 |
| strict 模式 | `ArthasObjectPropertyAccessor` 拦截写入 | 防止意外修改对象状态 |
| Unsafe 修改 OGNL 内部 | `updateOnglStrict()` | OGNL 新版 final 字段无法反射 |
| Advice 作为 root | 包含 params/returnObj/target 等 9 个字段 | 用户直接引用而无需前缀 |
| #cost 变量 | OgnlContext.put("cost", value) | 耗时过滤是最常用的条件 |
| 循环栈计时 | ThreadLocalWatch.LongStack | 嵌套调用 + 防内存泄漏 |
| 短类名支持 | 自动加 `java.lang.` 前缀 | `String` 不用写全名 |

> **与 Spring AOP 的对比**：Spring AOP 使用 SpEL（Spring Expression Language）做条件过滤，而 Arthas 使用 OGNL。两者都能访问方法参数和返回值，但 OGNL 在对象图导航方面更强（支持静态方法调用、类名引用 `@Class@method` 等），更适合诊断场景。

---

> **下一节**: [Ch 7 核心增强命令](ch07_watch_trace_monitor_stack.md) — watch/trace/monitor/stack 的完整实现
