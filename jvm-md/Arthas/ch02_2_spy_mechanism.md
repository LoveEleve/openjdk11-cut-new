
# Ch 2.2 Spy 机制 — BootstrapClassLoader 中的桥梁

> 源文件:
> - `spy/SpyAPI.java` (133行) — 放入 BootstrapCL 的拦截桩
> - `core/advisor/SpyImpl.java` (187行) — SpyAPI 的真实实现
> - `core/advisor/SpyInterceptors.java` (114行) — ASM 字节码插入模板
> - `core/advisor/AdviceListenerManager.java` (236行) — 监听器注册与分发中心
> - `core/advisor/AdviceListener.java` (72行) — 监听器接口定义
> - `core/advisor/InvokeTraceable.java` (60行) — trace 子调用跟踪接口
> - `core/server/instrument/ClassLoader_Instrument.java` (24行) — ClassLoader 增强补丁

---

## 0. 先回答"为什么需要 Spy"

### 0.1 核心矛盾

上一节 [Ch 2.1](ch02_1_arthas_classloader.md) 分析了 ArthasClassloader 的隔离设计——它把 Arthas 的代码和目标应用完全隔离。但这产生了一个新问题：

**当 Arthas 增强了目标类的方法后，增强代码中需要调用 Arthas 的回调函数。增强代码运行在目标类的 ClassLoader 中——它看不到 ArthasClassloader 中的任何类！**

具体来说：

```java
// 目标类（由 AppClassLoader 加载）
public class MyService {
    public String doSomething(int a) {
        // Arthas 想在这里插入回调：
        // SpyImpl.atEnter(...)   ← SpyImpl 在 ArthasClassloader 中
        //                          AppClassLoader 看不到！编译/加载都失败！
        return "result";
    }
}
```

### 0.2 三层架构的解决方案

Arthas 的解决方案是设计一个**三层桥接架构**：

```
┌──────────────────────────────────────────────────────────────────┐
│  层 1: BootstrapClassLoader                                      │
│                                                                  │
│  SpyAPI（桩）                                                    │
│    static atEnter() → 转发给 spyInstance                         │
│    spyInstance = ???                                              │
│                                                                  │
│  所有 ClassLoader 都能看到这一层 ✓                                │
└─────────────────────────────────┬────────────────────────────────┘
                                  │ 引用（多态）
┌─────────────────────────────────▼────────────────────────────────┐
│  层 2: ArthasClassloader                                         │
│                                                                  │
│  SpyImpl extends AbstractSpy（真实实现）                          │
│    atEnter() → AdviceListenerManager.query... → listener.before()│
│                                                                  │
│  只有 ArthasClassloader 能直接访问这一层                          │
└──────────────────────────────────────────────────────────────────┘
                                  ↑ 回调
┌──────────────────────────────────────────────────────────────────┐
│  层 3: 目标类的 ClassLoader (AppCL / WebappCL / 自定义CL)        │
│                                                                  │
│  增强后的 MyService.doSomething():                               │
│    SpyAPI.atEnter(MyService.class, ...)  ← 调用层1的桩           │
│                                                                  │
│  目标类能看到 BootstrapCL 的类 ✓                                 │
│  不能看到 ArthasClassloader 的类 ✗（但不需要）                    │
└──────────────────────────────────────────────────────────────────┘
```

**关键洞察**：SpyAPI 是 BootstrapClassLoader 中的一个"通信中继站"。增强后的目标类通过它间接调用 ArthasClassloader 中的 SpyImpl——**目标类不需要知道 SpyImpl 的存在**。

---

## 1. SpyAPI 详解

### 1.1 包名的玄机

```java
package java.arthas;  // ← 注意这个包名！
```

SpyAPI 的包名以 `java.` 开头。这是**刻意为之**的——它暗示了这个类的加载位置。

在 JVM 中，`java.*` 包的类**只能由 BootstrapClassLoader 加载**。SpyAPI 的包名选择就是在"宣告"：这个类必须被放入 BootstrapClassLoader。

spy.jar 的结构极其简单，只有两个 class 文件：
```
spy.jar
└── java/arthas/
    ├── SpyAPI.class
    └── SpyAPI$AbstractSpy.class
    └── SpyAPI$NopSpy.class
```

### 1.2 注入 BootstrapClassLoader 的时机

在 `ArthasBootstrap.initSpy()` 中：

```java
private void initSpy() throws Throwable {
    // 1. 先检查是否已经在 BootstrapCL 中
    ClassLoader parent = ClassLoader.getSystemClassLoader().getParent();
    Class<?> spyClass = null;
    if (parent != null) {
        try {
            spyClass = parent.loadClass("java.arthas.SpyAPI");
        } catch (Throwable e) {
            // ignore — 还没加载
        }
    }

    // 2. 如果没有，用 Instrumentation API 添加
    if (spyClass == null) {
        CodeSource codeSource = ArthasBootstrap.class.getProtectionDomain().getCodeSource();
        File arthasCoreJarFile = new File(codeSource.getLocation().toURI().getSchemeSpecificPart());
        File spyJarFile = new File(arthasCoreJarFile.getParentFile(), ARTHAS_SPY_JAR);
        instrumentation.appendToBootstrapClassLoaderSearch(new JarFile(spyJarFile));
    }
}
```

**关键 API**：`instrumentation.appendToBootstrapClassLoaderSearch(new JarFile(spyJarFile))`

这个 Instrumentation API 的作用是**向 BootstrapClassLoader 的搜索路径中追加 JAR 文件**。调用后，BootstrapClassLoader 在加载类时，除了在 `$JAVA_HOME/lib/modules` 中查找外，还会在 `spy.jar` 中查找。

注意它只是**追加搜索路径**，不会立即加载 SpyAPI。SpyAPI 的实际加载发生在第一次 `Class.forName("java.arthas.SpyAPI")` 或增强后的代码第一次调用 `SpyAPI.atEnter()` 时。

### 1.3 策略模式（Strategy Pattern）

SpyAPI 的核心设计是**策略模式**：

```java
public class SpyAPI {
    public static final AbstractSpy NOPSPY = new NopSpy();     // 空策略
    private static volatile AbstractSpy spyInstance = NOPSPY;   // 当前策略

    // 增强后的目标类调用的静态方法
    public static void atEnter(Class<?> clazz, String methodInfo, Object target, Object[] args) {
        spyInstance.atEnter(clazz, methodInfo, target, args);  // 委托给策略实例
    }
}
```

两个策略实现：

| 策略 | 位置 | 何时激活 | 行为 |
|------|------|---------|------|
| `NopSpy` | BootstrapCL (SpyAPI 内部类) | Arthas 未启动 / 已停止 | 空方法体，什么都不做 |
| `SpyImpl` | ArthasClassloader (core 包) | Arthas 运行中 | 查找 AdviceListener 并回调 |

**生命周期状态转换**：

```
                Arthas attach
NOPSPY ─────────────────────────→ SpyImpl
  ↑                                  │
  │        Arthas destroy            │
  └──────────────────────────────────┘
```

### 1.4 六个拦截点

SpyAPI 定义了 6 个静态方法，对应 6 种字节码插入位置：

```
┌─────────────────────── 方法级拦截（3个）───────────────────────┐
│                                                                │
│  public void doSomething(int a) {                              │
│      SpyAPI.atEnter(...)          ← ① 方法入口                │
│                                                                │
│      // 原始逻辑                                               │
│      int b = helper(a);           ← 子调用                    │
│      return process(b);                                        │
│                                                                │
│      SpyAPI.atExit(...)           ← ② 方法正常返回             │
│  } catch (Throwable t) {                                       │
│      SpyAPI.atExceptionExit(...)  ← ③ 方法抛出异常             │
│      throw t;                                                  │
│  }                                                             │
│                                                                │
└────────────────────────────────────────────────────────────────┘

┌────────────────── 调用级拦截（3个，trace 专用）────────────────┐
│                                                                │
│  public void doSomething(int a) {                              │
│      SpyAPI.atEnter(...)                                       │
│                                                                │
│      SpyAPI.atBeforeInvoke(...)   ← ④ 子调用之前              │
│      int b = helper(a);                                        │
│      SpyAPI.atAfterInvoke(...)    ← ⑤ 子调用正常返回后         │
│      // 或                                                     │
│      SpyAPI.atInvokeException(...)← ⑥ 子调用抛异常后           │
│                                                                │
│      SpyAPI.atExit(...)                                        │
│  }                                                             │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

| # | 拦截点 | 使用者 | 参数 |
|---|--------|--------|------|
| ① | `atEnter` | watch -b / trace / monitor / stack / tt | clazz, methodInfo, target, args |
| ② | `atExit` | watch -s / trace / monitor / tt | clazz, methodInfo, target, args, returnObject |
| ③ | `atExceptionExit` | watch -e / trace / monitor / tt | clazz, methodInfo, target, args, throwable |
| ④ | `atBeforeInvoke` | trace（子调用计时开始） | clazz, invokeInfo, target |
| ⑤ | `atAfterInvoke` | trace（子调用计时结束） | clazz, invokeInfo, target |
| ⑥ | `atInvokeException` | trace（子调用异常） | clazz, invokeInfo, target, throwable |

方法级拦截（①②③）被 **watch/monitor/stack/tt** 使用，调用级拦截（④⑤⑥）只被 **trace** 使用。

### 1.5 AbstractSpy 的跨 ClassLoader 桥接

```java
public static abstract class AbstractSpy {
    public abstract void atEnter(Class<?> clazz, String methodInfo, Object target, Object[] args);
    // ... 6 个抽象方法
}
```

`AbstractSpy` 是 SpyAPI 的内部抽象类，也在 BootstrapClassLoader 中。而 `SpyImpl extends AbstractSpy` 在 ArthasClassloader 中。

**跨 ClassLoader 引用的合法性**：

```
BootstrapCL:  SpyAPI.spyInstance: AbstractSpy  ← 声明类型
                                      ↑ extends
ArthasCL:     SpyImpl (实现类)        ← 运行时类型
```

这合法的原因是：
1. ArthasClassloader 的 parent 链包含 BootstrapCL
2. SpyImpl 加载时，JVM 会沿 parent 链找到 AbstractSpy（在 BootstrapCL 中）
3. `spyInstance` 的声明类型是 `AbstractSpy`（BootstrapCL 可见），赋值为 `SpyImpl`（多态）
4. **跨 ClassLoader 引用规则：子 CL 可以引用父 CL 的类型，反之不行**

### 1.6 NopSpy — 零开销的"关闭状态"

```java
static class NopSpy extends AbstractSpy {
    @Override
    public void atEnter(Class<?> clazz, String methodInfo, Object target, Object[] args) { }
    // ... 全部是空方法体
}
```

当 Arthas 未启动或已停止时，`spyInstance = NOPSPY`。增强后的目标类仍然会调用 `SpyAPI.atEnter()`，但 NopSpy 什么都不做。

**性能影响分析**：
- 一次 `SpyAPI.atEnter()` 调用 = 一次静态方法调用 + 一次读 volatile 字段 + 一次虚方法调用（空方法体）
- JIT 编译器可以将空方法内联为 no-op
- 最坏情况：约 2-5ns 额外开销（远小于方法调用本身的开销）

> **对比 async-profiler**：async-profiler 使用 JVMTI 的 MethodEntry/Exit 事件或 perf_events 采样，不在字节码中插入任何调用——完全零开销（未采样时）。但 async-profiler 不能实现条件过滤和表达式求值。

### 1.7 volatile 语义

```java
private static volatile AbstractSpy spyInstance = NOPSPY;
public static volatile boolean INITED;
```

两个 volatile 字段保证了**多线程可见性**：
- 当 Arthas 在 binding 线程中 `SpyAPI.setSpy(new SpyImpl())` 后，目标应用的所有业务线程立即能看到新的 spyInstance
- 当 Arthas destroy 后 `SpyAPI.setNopSpy()`，业务线程立即停止回调

不需要更强的同步（如 synchronized），因为：
- `setSpy` 只在 Arthas 启动时调用一次
- `setNopSpy` 只在 Arthas 停止时调用一次
- 中间稳定运行期，`spyInstance` 不会变化

---

## 2. SpyImpl 详解 — 真实的回调分发

### 2.1 atEnter 流程

```java
@Override
public void atEnter(Class<?> clazz, String methodInfo, Object target, Object[] args) {
    ClassLoader classLoader = clazz.getClassLoader();                    // ① 获取目标类的 CL

    String[] info = StringUtils.splitMethodInfo(methodInfo);              // ② 解析 "methodName|methodDesc"
    String methodName = info[0];
    String methodDesc = info[1];

    List<AdviceListener> listeners = AdviceListenerManager                // ③ 查找所有监听器
            .queryAdviceListeners(classLoader, clazz.getName(), methodName, methodDesc);

    if (listeners != null) {
        for (AdviceListener adviceListener : listeners) {                // ④ 逐个回调
            try {
                if (skipAdviceListener(adviceListener)) {                // ⑤ 跳过已停止的命令
                    continue;
                }
                adviceListener.before(clazz, methodName, methodDesc, target, args);  // ⑥ 回调！
            } catch (Throwable e) {
                logger.error("class: {}, methodInfo: {}", clazz.getName(), methodInfo, e);  // ⑦ 异常隔离
            }
        }
    }
}
```

**关键设计点**：

**① ClassLoader 作为查询维度**：为什么需要？

因为同一个全限定名的类可能被不同 ClassLoader 加载。例如在 Tomcat 中，`com.example.UserService` 可能同时存在于 webapp-1 和 webapp-2 中，分别由不同的 WebappClassLoader 加载。用户执行 `watch com.example.UserService doSomething` 时，应该只匹配到自己关心的那个。

**⑤ skipAdviceListener**：

```java
private static boolean skipAdviceListener(AdviceListener adviceListener) {
    if (adviceListener instanceof ProcessAware) {
        ProcessAware processAware = (ProcessAware) adviceListener;
        ExecStatus status = processAware.getProcess().status();
        if (status.equals(ExecStatus.TERMINATED) || status.equals(ExecStatus.STOPPED)) {
            return true;
        }
    }
    return false;
}
```

当用户 `Ctrl+C` 中断 watch 命令后，对应的 Job 状态变为 TERMINATED/STOPPED，但增强字节码**还在**（需要 `reset` 才会恢复）。skipAdviceListener 确保已中断的命令不再回调——避免无意义的计算和输出。

**⑦ catch Throwable**：这是一个**安全网**。监听器的异常**绝对不能传播到目标方法**！否则：
- 正常业务逻辑会被 Arthas 的 bug 中断
- 用户调试反而制造了新 bug

### 2.2 atBeforeInvoke — trace 专用路径

```java
@Override
public void atBeforeInvoke(Class<?> clazz, String invokeInfo, Object target) {
    ClassLoader classLoader = clazz.getClassLoader();
    String[] info = StringUtils.splitInvokeInfo(invokeInfo);   // "owner|methodName|methodDesc|lineNumber"
    String owner = info[0];
    String methodName = info[1];
    String methodDesc = info[2];

    List<AdviceListener> listeners = AdviceListenerManager
            .queryTraceAdviceListeners(classLoader, clazz.getName(), owner, methodName, methodDesc);

    if (listeners != null) {
        for (AdviceListener adviceListener : listeners) {
            try {
                if (skipAdviceListener(adviceListener)) { continue; }
                final InvokeTraceable listener = (InvokeTraceable) adviceListener;   // 强转！
                listener.invokeBeforeTracing(classLoader, owner, methodName, methodDesc,
                        Integer.parseInt(info[3]));   // 行号
            } catch (Throwable e) {
                logger.error("class: {}, invokeInfo: {}", clazz.getName(), invokeInfo, e);
            }
        }
    }
}
```

与 `atEnter` 的差异：
- 使用 `queryTraceAdviceListeners`（不同的 key 生成策略）
- 强转为 `InvokeTraceable`——只有实现了此接口的 listener 才能处理 trace 事件
- 多了 `owner`（被调用方法的所属类）和 `lineNumber`（调用行号）

### 2.3 方法级 vs 调用级拦截对比

```
方法级（atEnter/atExit/atExceptionExit）：
  → 在"被观测的方法"的入口/出口插入
  → 参数是"被观测的方法"的信息
  → methodInfo = "doSomething|(ILjava/lang/String;)Ljava/lang/String;"

调用级（atBeforeInvoke/atAfterInvoke/atInvokeException）：
  → 在"被观测的方法内部的每个子调用"前后插入
  → 参数是"子调用"的信息
  → invokeInfo = "com/example/Helper|compute|(I)I|42"
```

形象地说：
- 方法级拦截 = 在房间的**门口**装了摄像头
- 调用级拦截 = 在房间**内部每个工位**装了摄像头

---

## 3. SpyInterceptors — 字节码插入模板

`SpyInterceptors.java` 定义了 ASM 字节码增强的**模板**。Arthas 使用 bytekit 框架，通过注解声明增强行为：

### 3.1 方法级拦截模板

```java
public static class SpyInterceptor1 {
    @AtEnter(inline = true)
    public static void atEnter(
            @Binding.This Object target,           // 目标对象（this）
            @Binding.Class Class<?> clazz,         // 目标类
            @Binding.MethodInfo String methodInfo,  // 方法描述
            @Binding.Args Object[] args) {          // 方法参数
        SpyAPI.atEnter(clazz, methodInfo, target, args);
    }
}
```

**`inline = true` 的含义**：bytekit 会将 `SpyAPI.atEnter(...)` 调用**直接内联**到目标方法的字节码中，而不是插入一个方法调用。这意味着增强后的字节码等效于：

```java
// 增强前
public String doSomething(int a, String b) {
    return doWork(a, b);
}

// 增强后（inline = true，直接内联）
public String doSomething(int a, String b) {
    SpyAPI.atEnter(MyService.class, "doSomething|(ILjava/lang/String;)Ljava/lang/String;",
                   this, new Object[]{Integer.valueOf(a), b});
    // ... 原始逻辑
    Object __returnObj = doWork(a, b);
    SpyAPI.atExit(MyService.class, "doSomething|...", this, new Object[]{Integer.valueOf(a), b}, __returnObj);
    return (String) __returnObj;
}
```

### 3.2 调用级拦截模板（trace 专用）

```java
public static class SpyTraceInterceptor1 {
    @AtInvoke(name = "", inline = true, whenComplete = false,
              excludes = {"java.arthas.SpyAPI", "java.lang.Byte", "java.lang.Boolean",
                          "java.lang.Short", "java.lang.Character", "java.lang.Integer",
                          "java.lang.Float", "java.lang.Long", "java.lang.Double"})
    public static void onInvoke(
            @Binding.This Object target,
            @Binding.Class Class<?> clazz,
            @Binding.InvokeInfo String invokeInfo) {
        SpyAPI.atBeforeInvoke(clazz, invokeInfo, target);
    }
}
```

**excludes 列表的作用**：

trace 会在目标方法内部的**每个 INVOKE 指令前后**插入拦截。但有些调用不应该拦截：

| 排除项 | 原因 |
|--------|------|
| `java.arthas.SpyAPI` | 避免递归！SpyAPI 自己的调用不能再被拦截 |
| `java.lang.Integer` 等包装类 | 自动装箱（`Integer.valueOf()`）产生的调用，太频繁且无意义 |

### 3.3 跳过 JDK 的 trace 变体

```java
public static class SpyTraceExcludeJDKInterceptor1 {
    @AtInvoke(name = "", inline = true, whenComplete = false, excludes = "java.**")
    public static void onInvoke(...) {
        SpyAPI.atBeforeInvoke(clazz, invokeInfo, target);
    }
}
```

当用户使用 `trace --skipJDKMethod true`（默认行为）时，使用 `SpyTraceExcludeJDK*` 拦截器，排除所有 `java.**` 包的调用。

**性能考量**：一个方法内部可能有数十个 INVOKE 指令，每个都插入拦截会显著降低性能。跳过 JDK 方法可以减少 70-90% 的拦截次数。

---

## 4. AdviceListenerManager — 监听器注册中心

### 4.1 数据结构

```
AdviceListenerManager（静态类，全局唯一）
│
├── adviceListenerMap: ConcurrentWeakKeyHashMap<ClassLoader, ClassLoaderAdviceListenerManager>
│     │
│     ├── key: WebappCL-1 → value: ClassLoaderAdviceListenerManager
│     │     └── map: ConcurrentHashMap<String, List<AdviceListener>>
│     │           ├── "com.example.MyServicedoSomething(I)V" → [WatchAdviceListener]
│     │           └── "com.example.MyServiceprocess(Ljava/lang/String;)V" → [TraceAdviceListener]
│     │
│     ├── key: WebappCL-2 → value: ClassLoaderAdviceListenerManager
│     │     └── map: ...
│     │
│     └── key: FakeBootstrapClassLoader → value: ClassLoaderAdviceListenerManager
│           └── map: ... (BootstrapCL 加载的类用 Fake 代替 null)
│
└── FAKEBOOTSTRAPCLASSLOADER: 替代 null（BootstrapCL）的占位符
```

### 4.2 为什么用 ConcurrentWeakKeyHashMap？

`ConcurrentWeakKeyHashMap` 的 key 是 **WeakReference\<ClassLoader\>**。

**WeakReference 的作用**：当目标应用的某个 ClassLoader 被卸载（如 Tomcat 的 WebApp 热部署），对应的 WeakReference 会被 GC 清理，相关的 AdviceListener 也随之释放——**避免 ClassLoader 泄漏**。

如果用普通 HashMap，Arthas 持有了目标 ClassLoader 的强引用，会阻止其 GC，导致：
- Metaspace 不断增长
- 旧 WebApp 的类无法卸载
- 最终 OOM

### 4.3 FakeBootstrapClassLoader

```java
private static final FakeBootstrapClassLoader FAKEBOOTSTRAPCLASSLOADER = new FakeBootstrapClassLoader();

private static ClassLoader wrap(ClassLoader classLoader) {
    if (classLoader != null) {
        return classLoader;
    }
    return FAKEBOOTSTRAPCLASSLOADER;
}

private static class FakeBootstrapClassLoader extends ClassLoader { }
```

BootstrapClassLoader 在 Java 中表示为 `null`，不能作为 HashMap 的 key。所以用一个 `FakeBootstrapClassLoader` 实例作为占位符。

当 `clazz.getClassLoader()` 返回 null（表示类由 BootstrapCL 加载）时，`wrap(null)` 返回 FAKEBOOTSTRAPCLASSLOADER。

### 4.4 注册流程

```java
// 当用户执行 watch com.example.MyService doSomething 时
// EnhancerCommand → Enhancer.enhance() → AdviceListenerManager.registerAdviceListener()

public static void registerAdviceListener(ClassLoader classLoader, String className,
        String methodName, String methodDesc, AdviceListener listener) {
    classLoader = wrap(classLoader);                           // null → Fake
    className = className.replace('/', '.');                   // 内部名 → 标准名

    ClassLoaderAdviceListenerManager manager = adviceListenerMap.get(classLoader);
    if (manager == null) {
        manager = new ClassLoaderAdviceListenerManager();
        adviceListenerMap.put(classLoader, manager);           // 按 ClassLoader 分组
    }
    manager.registerAdviceListener(className, methodName, methodDesc, listener);
}
```

key 的生成：

```java
// ClassLoaderAdviceListenerManager 内部
private String key(String className, String methodName, String methodDesc) {
    return className + methodName + methodDesc;
    // 例如: "com.example.MyServicedoSomething(I)V"
}

private String keyForTrace(String className, String owner, String methodName, String methodDesc) {
    return className + owner + methodName + methodDesc;
    // 例如: "com.example.MyServicecom/example/Helpercompute(I)I"
}
```

> **设计说明**：key 是简单字符串拼接，没有分隔符。这在大多数情况下不会冲突（因为类名、方法名、描述符的字符集不重叠）。但理论上极端情况可能冲突，不过概率极低，Arthas 选择了简洁性。

### 4.5 查询流程（运行时热路径）

```java
public static List<AdviceListener> queryAdviceListeners(ClassLoader classLoader,
        String className, String methodName, String methodDesc) {
    classLoader = wrap(classLoader);
    className = className.replace('/', '.');
    ClassLoaderAdviceListenerManager manager = adviceListenerMap.get(classLoader);  // 1次 HashMap 查找
    if (manager != null) {
        return manager.queryAdviceListeners(className, methodName, methodDesc);    // 1次 HashMap 查找
    }
    return null;
}
```

**性能分析**：

每次目标方法被调用，都会触发这个查询。查询路径：
1. `wrap(classLoader)` — null 判断，O(1)
2. `adviceListenerMap.get(classLoader)` — ConcurrentHashMap 查找，O(1)
3. `manager.map.get(key)` — ConcurrentHashMap 查找，O(1)

总开销：**~50ns**（两次 HashMap 查找 + 字符串拼接）。对于大多数业务方法（执行时间在微秒到毫秒级），这个开销可以忽略。

> **源码中的 TODO 注释**：`// TODO listener 只用查一次，放到 thread local里保存起来就可以了！` — 作者考虑过用 ThreadLocal 缓存来避免重复查找，但目前没有实现。

### 4.6 自动清理

```java
static {
    ArthasBootstrap.getInstance().getScheduledExecutorService()
        .scheduleWithFixedDelay(new Runnable() {
            @Override
            public void run() {
                // 遍历所有 ClassLoader 的 AdviceListenerManager
                for (Entry<ClassLoader, ClassLoaderAdviceListenerManager> entry : adviceListenerMap.entrySet()) {
                    ClassLoaderAdviceListenerManager adviceListenerManager = entry.getValue();
                    synchronized (adviceListenerManager) {
                        for (Entry<String, List<AdviceListener>> eee : adviceListenerManager.map.entrySet()) {
                            List<AdviceListener> listeners = eee.getValue();
                            List<AdviceListener> newResult = new ArrayList<>();
                            for (AdviceListener listener : listeners) {
                                if (listener instanceof ProcessAware) {
                                    Process process = ((ProcessAware) listener).getProcess();
                                    if (process != null && !process.status().equals(ExecStatus.TERMINATED)) {
                                        newResult.add(listener);    // 只保留未终止的
                                    }
                                }
                            }
                            if (newResult.size() != listeners.size()) {
                                adviceListenerManager.map.put(eee.getKey(), newResult);  // 替换
                            }
                        }
                    }
                }
            }
        }, 3, 3, TimeUnit.SECONDS);   // 每 3 秒清理一次
}
```

**用途**：用户 `Ctrl+C` 中断 watch 命令后，对应的 Job 状态变为 TERMINATED。清理任务每 3 秒移除这些已终止的 listener。

**为什么需要定时清理？**

`skipAdviceListener` 已经在运行时跳过了已终止的 listener，为什么还需要清理？因为：
1. 不清理的话，listener list 会无限增长（用户反复 watch 同一个方法）
2. listener 引用了 ProcessAware→Process→Job→Session 等对象链，不清理会内存泄漏

---

## 5. ClassLoader_Instrument — 修补叛逆 ClassLoader

### 5.1 问题场景

虽然 SpyAPI 在 BootstrapClassLoader 中，标准 ClassLoader 都能找到它。但某些"叛逆"的 ClassLoader 不走标准委派：

| 叛逆者 | 原因 | 后果 |
|--------|------|------|
| **OSGi ClassLoader** | 每个 Bundle 有独立可见性规则 | 可能看不到 BootstrapCL 的 `java.arthas.*` |
| **覆写 loadClass 的自定义 CL** | 不正确的委派实现 | 直接在自己的路径中找，找不到就报错 |
| **Spring DevTools RestartClassLoader** | 热重启时替换 CL | 新 CL 可能不正确地委派 |

### 5.2 解决方案

Arthas 增强了 `java.lang.ClassLoader.loadClass()` 本身：

```java
@Instrument(Class = "java.lang.ClassLoader")
public abstract class ClassLoader_Instrument {
    public Class<?> loadClass(String name) throws ClassNotFoundException {
        if (name.startsWith("java.arthas.")) {
            ClassLoader extClassLoader = ClassLoader.getSystemClassLoader().getParent();
            if (extClassLoader != null) {
                return extClassLoader.loadClass(name);    // 强制委派给 ExtCL
            }
        }
        Class clazz = InstrumentApi.invokeOrigin();       // 调用原始 loadClass
        return clazz;
    }
}
```

**这是对 JVM 核心类的修改**！效果是：

```
所有 ClassLoader 的 loadClass("java.arthas.SpyAPI") 调用

修改前：走各自的委派逻辑（可能找不到）
修改后：直接走 ExtCL → BootstrapCL（一定能找到）
```

### 5.3 增强时机和方式

在 `ArthasBootstrap.enhanceClassLoader()` 中：

```java
void enhanceClassLoader() {
    // 1. 读取 ClassLoader_Instrument 的字节码（作为模板）
    byte[] classBytes = IOUtils.getBytes(ArthasBootstrap.class.getClassLoader()
            .getResourceAsStream(ClassLoader_Instrument.class.getName().replace('.', '/') + ".class"));

    // 2. 构建 InstrumentTransformer
    SimpleClassMatcher matcher = new SimpleClassMatcher(loaders);   // loaders = {"java.lang.ClassLoader"}
    InstrumentConfig instrumentConfig = new InstrumentConfig(AsmUtils.toClassNode(classBytes), matcher);
    classLoaderInstrumentTransformer = new InstrumentTransformer(instrumentParseResult);

    // 3. 注册 Transformer 并触发重转换
    instrumentation.addTransformer(classLoaderInstrumentTransformer, true);
    instrumentation.retransformClasses(ClassLoader.class);   // 触发 JVM 重新加载 ClassLoader
}
```

注意这里调用了 `instrumentation.retransformClasses(ClassLoader.class)`——让 JVM 重新转换 `java.lang.ClassLoader` 类。JVM 会调用已注册的 ClassFileTransformer，将 `ClassLoader_Instrument` 中定义的增强逻辑**合并到 `ClassLoader.loadClass()` 方法中**。

### 5.4 `InstrumentApi.invokeOrigin()` 的魔法

```java
Class clazz = InstrumentApi.invokeOrigin();
```

这不是普通的方法调用！`InstrumentApi.invokeOrigin()` 是 bytekit 框架的特殊指令，在 ASM 处理阶段会被替换为**对原始方法的调用**。最终字节码等效于：

```java
// 增强后的 java.lang.ClassLoader.loadClass()（伪代码）
public Class<?> loadClass(String name) throws ClassNotFoundException {
    if (name.startsWith("java.arthas.")) {
        ClassLoader extClassLoader = ClassLoader.getSystemClassLoader().getParent();
        if (extClassLoader != null) {
            return extClassLoader.loadClass(name);
        }
    }
    // 原始 loadClass 逻辑（双亲委派等）
    return originalLoadClass(name);
}
```

---

## 6. 完整的 Spy 调用链时序图

```
用户执行: watch com.example.MyService doSomething '{params}'

                    注册阶段
                    ────────
WatchCommand.enhance()
    │
    ├─ AdviceListenerManager.registerAdviceListener(
    │       appClassLoader,
    │       "com.example.MyService",
    │       "doSomething",
    │       "(I)V",
    │       watchAdviceListener)
    │
    └─ Enhancer.enhance() → retransformClasses(MyService.class)
        → ASM 在 doSomething() 中插入:
            SpyAPI.atEnter(...)     ← 入口
            SpyAPI.atExit(...)      ← 出口
            SpyAPI.atExceptionExit(...)  ← 异常

                    运行时阶段（每次方法被调用）
                    ──────────────────────────
MyService.doSomething(42)
    │
    ├─ SpyAPI.atEnter(MyService.class, "doSomething|(I)V", this, [42])
    │       │                              [BootstrapCL]
    │       ▼
    │   spyInstance.atEnter(...)    ← volatile 读取
    │       │                         spyInstance 实际类型是 SpyImpl
    │       ▼                              [ArthasCL]
    │   SpyImpl.atEnter():
    │       │
    │       ├─ classLoader = MyService.class.getClassLoader()  → AppClassLoader
    │       ├─ splitMethodInfo("doSomething|(I)V") → ["doSomething", "(I)V"]
    │       │
    │       ├─ AdviceListenerManager.queryAdviceListeners(
    │       │       appCL, "com.example.MyService", "doSomething", "(I)V")
    │       │   ├─ wrap(appCL) → appCL
    │       │   ├─ adviceListenerMap.get(appCL) → manager
    │       │   └─ manager.map.get("com.example.MyServicedoSomething(I)V")
    │       │       → [WatchAdviceListener]
    │       │
    │       └─ for listener in [WatchAdviceListener]:
    │           ├─ skipAdviceListener(listener) → false (命令还在运行)
    │           └─ listener.before(MyService.class, "doSomething", "(I)V", this, [42])
    │               └─ WatchAdviceListener.before():
    │                   └─ 如果是 watch -b 模式，用 OGNL 求值并输出
    │
    ├─ // 原始 doSomething 逻辑执行 ...
    │
    └─ SpyAPI.atExit(MyService.class, "doSomething|(I)V", this, [42], returnValue)
            │
            ▼
        SpyImpl.atExit():
            └─ WatchAdviceListener.afterReturning():
                └─ OgnlExpress.get("{params}") → [42]
                └─ ObjectView.render([42], expand=1)
                └─ 输出到 Shell 终端
```

---

## 7. Enhancer 中的 SpyAPI 检查

在增强目标类之前，Enhancer 会先检查目标类的 ClassLoader 是否能加载 SpyAPI：

```java
// Enhancer.transform() 中
try {
    if (inClassLoader != null) {
        inClassLoader.loadClass(SpyAPI.class.getName());
    }
} catch (Throwable e) {
    logger.error("the classloader can not load SpyAPI, ignore it. classloader: {}, className: {}",
            inClassLoader.getClass().getName(), className, e);
    return null;   // 放弃增强这个类
}
```

如果目标类的 ClassLoader 无法加载 SpyAPI，增强后的代码调用 `SpyAPI.atEnter()` 时会抛 `NoClassDefFoundError`，直接导致目标方法崩溃。所以 Enhancer 在增强前做了**预检查**，如果检查失败就放弃增强（return null）。

但如果 `enhanceClassLoader()` 已经增强了 `ClassLoader.loadClass()`，这个检查几乎不会失败——因为所有 ClassLoader 都会被增强后的逻辑"修正"为能找到 SpyAPI。

---

## 8. 小结 — Spy 机制的设计精髓

```
                              设计问题与解决方案对应
                              ━━━━━━━━━━━━━━━━━━━━

问题: 增强后的目标类（任意 CL）怎么调用 Arthas 的回调（ArthasCL）？
      ┌─────────┐         ┌──────────────┐
      │ 目标类   │  ──?──→ │ SpyImpl      │
      │ (AppCL)  │         │ (ArthasCL)   │
      └─────────┘         └──────────────┘
           看不到对方 ✗

解决: 在 BootstrapCL 中放一个桥梁
      ┌─────────┐    ①    ┌──────────────┐    ②    ┌──────────────┐
      │ 目标类   │ ──────→ │ SpyAPI       │ ──────→ │ SpyImpl      │
      │ (AppCL)  │         │ (BootstrapCL)│         │ (ArthasCL)   │
      └─────────┘         └──────────────┘         └──────────────┘
      ① 所有 CL 都能看到 BootstrapCL ✓
      ② 通过 volatile + 多态（AbstractSpy → SpyImpl）桥接 ✓

问题: 某些叛逆 CL 可能连 BootstrapCL 的类都找不到？
解决: 增强 ClassLoader.loadClass()，强制 java.arthas.* 走 ExtCL 委派

问题: Arthas 未启动/已停止时，增强后的代码还在调用 SpyAPI？
解决: NopSpy（空实现），零开销

问题: 多命令同时增强同一方法？
解决: AdviceListenerManager 用 List<AdviceListener> 支持多监听器

问题: ClassLoader 卸载导致泄漏？
解决: ConcurrentWeakKeyHashMap 用弱引用持有 ClassLoader

问题: 已中断命令的 listener 残留？
解决: 定时清理任务（每 3 秒）+ skipAdviceListener 跳过
```

**核心理解**：Spy 机制本质上是一个**跨 ClassLoader 的发布-订阅系统**：
- **发布者**：增强后的目标类，通过 SpyAPI 发布事件（方法进入/退出/异常）
- **中继站**：SpyAPI（BootstrapCL），接收事件并转发给 SpyImpl
- **订阅者**：AdviceListenerManager 中注册的各种 AdviceListener
- **隔离保证**：发布者和订阅者互不知道对方的存在，通过 BootstrapCL 的桥梁通信

---

> **Part 2 完成！** 下一步进入 [Part 3: Shell 交互框架](ch03_1_shell_server_session.md) — ShellServer 怎么管理连接？命令怎么从输入到输出？
