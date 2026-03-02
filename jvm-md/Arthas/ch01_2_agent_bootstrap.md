
# Ch 1.2 Agent 加载入口 — AgentBootstrap + ArthasClassloader

> 源文件:
> - `agent/AgentBootstrap.java` (199行) — Agent 入口，premain/agentmain
> - `agent/ArthasClassloader.java` (36行) — 自定义 ClassLoader，打破双亲委派
> - `spy/SpyAPI.java` (133行) — 放入 BootstrapClassLoader 的拦截桩
> - `core/server/ArthasBootstrap.java` (703行) — 核心服务启动器
> - `core/advisor/SpyImpl.java` (187行) — SpyAPI 的真实实现
> - `core/server/instrument/ClassLoader_Instrument.java` (22行) — ClassLoader 增强

---

## 0. 关于验证方式的说明

Arthas 是纯 Java 项目（除 vmtool 模块有 ~230 行 C++ JNI 代码外），**不适合用 GDB 调试**。本系列采用以下替代验证方式：

| 验证方式 | 适用场景 | 示例 |
|----------|---------|------|
| **Arthas 自诊断** | Arthas attach 到自己，用 sc/jad/classloader 命令验证 | `classloader -t` 查看 ClassLoader 树 |
| **JVM 日志** | 通过 `-verbose:class` 观察类加载顺序 | 确认 SpyAPI 被 BootstrapCL 加载 |
| **arthas.log** | Arthas 自身的日志文件 `~/logs/arthas/arthas.log` | 观察启动流程 |
| **源码推理** | 对照 Java 语言规范和 JVM 规范推导 | ClassLoader 委派链分析 |
| **断点调试** | IDE (IntelliJ) Remote Debug attach 到目标 JVM | 验证分支走向 |
| **jad 反编译** | 用 Arthas 的 jad 命令验证增强后的字节码 | `jad java.lang.ClassLoader loadClass` |

---

## 1. 先回答"为什么"

### 1.1 Agent 入口要解决什么问题？

上一节分析了 Arthas 如何通过 `VirtualMachine.loadAgent()` 将 `arthas-agent.jar` 注入目标 JVM。现在 Agent 已经进入了目标 JVM，但它面临三个关键问题：

**问题 1：如何不污染目标应用？**

Arthas 自带大量第三方依赖（ASM、Netty、Logback、fastjson2 等）。如果把这些类直接加载到目标应用的 ClassLoader 中，可能导致：
- 版本冲突（目标应用可能用了不同版本的 Netty）
- 类空间污染（目标应用能看到 Arthas 的内部类）
- 清理困难（Arthas detach 后，类仍然残留）

**解决方案**：创建 **ArthasClassloader**，自定义类加载策略，与目标应用完全隔离。

**问题 2：如何让增强后的目标类能调用 Arthas 的回调？**

Arthas 通过 ASM 在目标方法的入口/出口处插入 `SpyAPI.atEnter()` 等调用。但目标类可能被任意 ClassLoader 加载（AppCL、自定义 CL、OSGi CL 等），它怎么能"看到" SpyAPI？

**解决方案**：将 SpyAPI 放入 **BootstrapClassLoader**——这是 Java 类加载体系的根，所有 ClassLoader 都能看到它。

**问题 3：如何防止重复初始化？**

用户可能多次执行 `as.sh` 或 `arthas-boot.jar`，导致 `agentmain` 被多次调用。需要**幂等性**保护。

**解决方案**：用 `SpyAPI.isInited()` 作为**全局锁标志**，防止重复初始化。

### 1.2 四个关键组件的协作关系

```
┌─────────────────── BootstrapClassLoader ───────────────────┐
│                                                             │
│  java.arthas.SpyAPI          ← 通过 appendToBootstrapCL    │
│    spyInstance ────────────────────────────────────┐        │
│    INITED (volatile boolean)                       │引用     │
│    atEnter()  ─→ spyInstance.atEnter()            │        │
│    atExit()   ─→ spyInstance.atExit()             │        │
│    ...                                            │        │
└───────────────────────────────────────────────────┼────────┘
                                                    │
┌─────────────────── ArthasClassloader ─────────────┼────────┐
│  (parent = ExtClassLoader，打破双亲委派)            │        │
│                                                    ▼        │
│  SpyImpl extends AbstractSpy  ←── 真实实现         │        │
│    atEnter() → AdviceListenerManager.query...      │        │
│    atExit()  → AdviceListenerManager.query...      │        │
│                                                             │
│  ArthasBootstrap                                            │
│    initSpy() → appendToBootstrapClassLoaderSearch(spy.jar)  │
│    → SpyAPI 被 BootstrapCL 加载                              │
│    → SpyAPI.setSpy(new SpyImpl()) ← 桥接                    │
│                                                             │
│  Enhancer, ShellServer, WatchCommand ...                    │
└─────────────────────────────────────────────────────────────┘
                    │
                    │ 通过反射调用
                    ▼
┌─────────────────── 系统 ClassLoader (AppCL) ────────────────┐
│                                                              │
│  AgentBootstrap (agent 包)                                   │
│    agentmain(args, inst)                                     │
│    → new ArthasClassloader(core.jar)                         │
│    → agentLoader.loadClass("ArthasBootstrap")                │
│    → ArthasBootstrap.getInstance(inst, args) ← 反射调用      │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## 2. AgentBootstrap.java 逐段分析

### 2.1 入口方法：premain vs agentmain

```java
public static void premain(String args, Instrumentation inst) {
    main(args, inst);
}

public static void agentmain(String args, Instrumentation inst) {
    main(args, inst);
}
```

两个入口**统一转到 `main()`**。区别只在于调用时机：

| 入口 | 调用时机 | 调用方 |
|------|---------|--------|
| `premain` | JVM 启动时，`-javaagent:arthas-agent.jar` | JVM 自身 |
| `agentmain` | 运行时，`VirtualMachine.loadAgent()` | Arthas attach 进程 |

实际使用中，**agentmain 是主路径**（运行时 Attach）。premain 通常只在嵌入式场景（Spring Boot Starter）中使用。

### 2.2 重复 Attach 的幂等保护

`main()` 方法的第一件事是检查 Arthas 是否已经在运行：

```java
private static synchronized void main(String args, final Instrumentation inst) {
    // 尝试判断arthas是否已在运行
    try {
        Class.forName("java.arthas.SpyAPI"); // 加载不到会抛异常
        if (SpyAPI.isInited()) {
            ps.println("Arthas server already stared, skip attach.");
            ps.flush();
            return;           // ← 直接返回，幂等
        }
    } catch (Throwable e) {
        // ignore — 说明是第一次加载，SpyAPI 还不存在
    }
```

**为什么用 `Class.forName()` 而不是直接 `SpyAPI.isInited()`？**

因为 `AgentBootstrap` 运行在系统 ClassLoader 中，而 `SpyAPI` 在 BootstrapClassLoader 中。如果是**第一次 attach**，spy.jar 还没有被添加到 BootstrapCL，直接调用 `SpyAPI` 会抛 `NoClassDefFoundError`。所以先用 `Class.forName()` 试探——如果抛异常，说明是首次；如果不抛异常，再检查 `isInited()`。

> **设计精妙之处**：`SpyAPI.INITED` 是 `public static volatile boolean`，放在 BootstrapCL 中，**全局唯一**，天然适合做"Arthas 是否已启动"的标志。

### 2.3 参数解析

```java
args = decodeArg(args);   // URL 解码（对应 Arthas.java 中的 encodeArg）

String arthasCoreJar;
final String agentArgs;
int index = args.indexOf(';');
if (index != -1) {
    arthasCoreJar = args.substring(0, index);  // 分号前：arthas-core.jar 路径
    agentArgs = args.substring(index);          // 分号后（含分号）：配置参数
} else {
    arthasCoreJar = "";
    agentArgs = args;
}
```

参数格式回顾（来自上一节 `Arthas.java` 的拼装）：

```
/path/to/arthas-core.jar;arthas.telnetPort=3658;arthas.httpPort=8563;arthas.ip=127.0.0.1;...
```

### 2.4 arthas-core.jar 的降级查找

```java
File arthasCoreJarFile = new File(arthasCoreJar);
if (!arthasCoreJarFile.exists()) {
    // 降级策略：从 agent JAR 所在目录查找
    CodeSource codeSource = AgentBootstrap.class.getProtectionDomain().getCodeSource();
    if (codeSource != null) {
        File arthasAgentJarFile = new File(codeSource.getLocation().toURI().getSchemeSpecificPart());
        arthasCoreJarFile = new File(arthasAgentJarFile.getParentFile(), ARTHAS_CORE_JAR);
    }
}
```

这是一个**防御性设计**：即使参数中的 arthas-core.jar 路径不对（比如文件被移动），也能通过 agent JAR 的位置推测出 core JAR 的位置（因为它们总是在同一目录下部署）。

### 2.5 创建 ArthasClassloader 并启动绑定线程

```java
final ClassLoader agentLoader = getClassLoader(inst, arthasCoreJarFile);

Thread bindingThread = new Thread() {
    @Override
    public void run() {
        try {
            bind(inst, agentLoader, agentArgs);
        } catch (Throwable throwable) {
            throwable.printStackTrace(ps);
        }
    }
};

bindingThread.setName("arthas-binding-thread");
bindingThread.start();
bindingThread.join();   // ← 等待绑定完成
```

**为什么要用独立线程？**

注释写了：`Use a dedicated thread to run the binding logic to prevent possible memory leak. #195`

这是因为 `agentmain` 的调用线程是 JVM 的 **Attach Listener** 线程。如果在这个线程上执行大量初始化（Netty 启动、ClassLoader 创建等），会导致：

1. **ThreadLocal 泄漏**：Netty 等框架会在 ThreadLocal 中缓存数据，Attach Listener 线程不会被销毁，这些 ThreadLocal 永远不会被清理
2. **上下文类加载器问题**：Attach Listener 线程的 ContextClassLoader 是系统 ClassLoader，可能影响某些框架的类查找

用独立线程 + `join()` 等待，既保证了**同步语义**（attach 完成后才返回），又避免了线程上下文污染。

### 2.6 bind() — 反射调用 ArthasBootstrap

```java
private static void bind(Instrumentation inst, ClassLoader agentLoader, String args) throws Throwable {
    Class<?> bootstrapClass = agentLoader.loadClass(ARTHAS_BOOTSTRAP);
    Object bootstrap = bootstrapClass.getMethod(GET_INSTANCE, Instrumentation.class, String.class)
                                     .invoke(null, inst, args);
    boolean isBind = (Boolean) bootstrapClass.getMethod(IS_BIND).invoke(bootstrap);
    if (!isBind) {
        throw new RuntimeException("Arthas server port binding failed!");
    }
}
```

**为什么要用反射而不是直接 `new ArthasBootstrap()`？**

因为 `AgentBootstrap`（在 `agent` 模块）和 `ArthasBootstrap`（在 `core` 模块）被**不同的 ClassLoader** 加载：

- `AgentBootstrap` → 系统 ClassLoader（随 arthas-agent.jar 一起被 `loadAgent` 加载）
- `ArthasBootstrap` → ArthasClassloader（自定义 CL，加载 arthas-core.jar）

跨 ClassLoader 的类**不能直接引用**，只能通过反射调用。这正是 ClassLoader 隔离的代价。

等效于：
```java
// 如果不需要隔离，代码会是这样（但实际不行）：
ArthasBootstrap bootstrap = ArthasBootstrap.getInstance(inst, args);
boolean isBind = bootstrap.isBind();
```

---

## 3. ArthasClassloader.java — 打破双亲委派

这个类只有 36 行，但每一行都有深意：

```java
public class ArthasClassloader extends URLClassLoader {
    public ArthasClassloader(URL[] urls) {
        super(urls, ClassLoader.getSystemClassLoader().getParent());  // ← 关键！
    }

    @Override
    protected synchronized Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
        final Class<?> loadedClass = findLoadedClass(name);
        if (loadedClass != null) {
            return loadedClass;
        }

        // 优先从parent（SystemClassLoader）里加载系统类
        if (name != null && (name.startsWith("sun.") || name.startsWith("java."))) {
            return super.loadClass(name, resolve);
        }
        try {
            Class<?> aClass = findClass(name);   // ← 优先自己找！
            if (resolve) {
                resolveClass(aClass);
            }
            return aClass;
        } catch (Exception e) {
            // ignore
        }
        return super.loadClass(name, resolve);    // ← 找不到才委派给 parent
    }
}
```

### 3.1 构造函数的 parent 参数

```java
super(urls, ClassLoader.getSystemClassLoader().getParent());
```

标准 ClassLoader 层次：
```
BootstrapClassLoader (加载 java.* 等核心类)
    └→ ExtClassLoader / PlatformClassLoader (加载 javax.* 等扩展类)
        └→ AppClassLoader (加载 classpath 上的应用类)
```

`ClassLoader.getSystemClassLoader()` 返回 AppClassLoader。`.getParent()` 返回 ExtClassLoader。

所以 ArthasClassloader 的 parent 是 **ExtClassLoader**，跳过了 AppClassLoader！

```
BootstrapClassLoader
    └→ ExtClassLoader
        ├→ AppClassLoader (目标应用)  ← Arthas 看不到这里
        └→ ArthasClassloader (Arthas) ← 目标应用也看不到这里
```

**效果**：ArthasClassloader 和目标应用的 AppClassLoader 是**兄弟关系**，互相不可见。

### 3.2 打破双亲委派

标准的双亲委派模型是：**先问 parent，parent 找不到才自己找**。

ArthasClassloader 反过来了：**先自己找（`findClass`），找不到才问 parent**。

```
标准双亲委派:  loadClass → parent.loadClass → findClass
ArthasClassloader: loadClass → findClass → parent.loadClass
```

为什么要打破？

假设 Arthas 依赖了 `netty-4.1.x`，目标应用依赖了 `netty-4.0.x`。如果走标准双亲委派：
1. ArthasClassloader.loadClass("io.netty.xxx")
2. → parent (ExtClassLoader).loadClass → 找不到
3. → 注意：ExtClassLoader 也找不到 Netty
4. → 最终 findClass 从 arthas-core.jar 加载 ← 这种情况下没问题

但如果 Arthas 和目标应用用了相同全限定名但不同版本的类呢？**打破双亲委派确保 Arthas 永远优先加载自己 JAR 中的类**，不受目标应用影响。

### 3.3 对 `java.*` 和 `sun.*` 的特殊处理

```java
if (name != null && (name.startsWith("sun.") || name.startsWith("java."))) {
    return super.loadClass(name, resolve);
}
```

`java.*` 和 `sun.*` 包下的类**必须由 BootstrapClassLoader 或 ExtClassLoader 加载**，这是 JVM 安全机制的强制要求。如果自定义 ClassLoader 试图 `defineClass("java.xxx", ...)`，JVM 会直接抛 `SecurityException`。

### 3.4 ArthasClassloader 的生命周期

```java
// AgentBootstrap.java
private static volatile ClassLoader arthasClassLoader;  // 全局持有

public static void resetArthasClassLoader() {
    arthasClassLoader = null;  // Arthas 停止时清空
}
```

ArthasClassloader 的生命周期：
1. **创建**：首次 attach 时，`loadOrDefineClassLoader()` 创建
2. **复用**：如果 arthasClassLoader 不为 null，复用已有的（避免重复加载）
3. **销毁**：Arthas destroy 时，通过 `resetArthasClassLoader()` 清空引用

> **注意**：清空引用后，ArthasClassloader 及其加载的所有类**不会立即被卸载**。它们要等到：
> 1. 没有任何对象引用这些类的实例
> 2. 这些类的 ClassLoader 不可达
> 3. GC 收集
> 
> 这就是为什么多次 attach/detach 可能导致 Metaspace 增长。

---

## 4. SpyAPI — BootstrapClassLoader 中的桩

### 4.1 为什么需要 SpyAPI？

这是 Arthas 架构中**最精巧的设计**之一。让我们从问题出发：

**场景**：用户执行 `watch com.example.MyService doSomething`，Arthas 需要在 `doSomething()` 的入口处插入一段代码来捕获参数。

ASM 增强后的代码等效于：
```java
// 原始 MyService.doSomething()
public String doSomething(int a, String b) {
    // ... 原始逻辑
}

// 增强后
public String doSomething(int a, String b) {
    SpyAPI.atEnter(MyService.class, "doSomething|(ILjava/lang/String;)Ljava/lang/String;",
                   this, new Object[]{a, b});   // ← 插入的代码
    // ... 原始逻辑
    SpyAPI.atExit(..., returnValue);            // ← 插入的代码
}
```

问题来了：`MyService` 由 AppClassLoader 加载，`SpyAPI` 在哪里？

- 如果 SpyAPI 在 ArthasClassloader 中 → AppClassLoader **看不到** ArthasClassloader 的类 → `NoClassDefFoundError`！
- 如果 SpyAPI 在 AppClassLoader 中 → 污染目标应用！
- 如果 SpyAPI 在 BootstrapClassLoader 中 → **所有 ClassLoader 都能看到** ✓

这就是为什么 SpyAPI 的**包名是 `java.arthas`**——以 `java.` 开头，暗示它被加载到 BootstrapClassLoader 中。

### 4.2 SpyAPI 怎么被放入 BootstrapClassLoader？

在 `ArthasBootstrap.initSpy()` 中：

```java
private void initSpy() throws Throwable {
    // 1. 先检查 SpyAPI 是否已经在 BootstrapCL 中
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

这是 `java.lang.instrument.Instrumentation` 提供的能力——**向 BootstrapClassLoader 的搜索路径中追加 JAR 文件**。调用后，`spy.jar` 中的类（只有 `java.arthas.SpyAPI` 及其内部类）就可以被 BootstrapClassLoader 加载了。

> 验证方法：使用 Arthas 的 `classloader` 命令
> ```
> arthas> classloader -c null
> # 或
> arthas> sc java.arthas.SpyAPI -d
> # 查看 classLoaderHash 是否为 null（BootstrapCL）
> ```

### 4.3 SpyAPI 的策略模式

SpyAPI 使用了**策略模式**：

```java
public class SpyAPI {
    public static final AbstractSpy NOPSPY = new NopSpy();     // 空实现
    private static volatile AbstractSpy spyInstance = NOPSPY;   // 默认空

    // 增强后的目标类调用这些静态方法
    public static void atEnter(Class<?> clazz, String methodInfo, Object target, Object[] args) {
        spyInstance.atEnter(clazz, methodInfo, target, args);  // 委托给 spyInstance
    }
    
    public static void atExit(Class<?> clazz, String methodInfo, Object target, Object[] args, Object returnObject) {
        spyInstance.atExit(clazz, methodInfo, target, args, returnObject);
    }

    public static void atExceptionExit(Class<?> clazz, String methodInfo, Object target, Object[] args, Throwable throwable) {
        spyInstance.atExceptionExit(clazz, methodInfo, target, args, throwable);
    }
    
    // trace 专用：方法内部调用前/后/异常
    public static void atBeforeInvoke(Class<?> clazz, String invokeInfo, Object target) { ... }
    public static void atAfterInvoke(Class<?> clazz, String invokeInfo, Object target) { ... }
    public static void atInvokeException(Class<?> clazz, String invokeInfo, Object target, Throwable throwable) { ... }
}
```

SpyAPI 定义了 **6 个拦截点**：

| 拦截点 | 触发时机 | 用途 |
|--------|---------|------|
| `atEnter` | 方法入口 | watch -b、trace 入口计时 |
| `atExit` | 方法正常返回 | watch -s、trace 出口计时 |
| `atExceptionExit` | 方法抛出异常 | watch -e、异常统计 |
| `atBeforeInvoke` | 方法内部调用某个方法**之前** | trace 子调用入口 |
| `atAfterInvoke` | 方法内部调用某个方法**之后** | trace 子调用出口 |
| `atInvokeException` | 方法内部调用某个方法**抛异常** | trace 子调用异常 |

前三个用于 **方法级**拦截（watch/monitor/stack/tt），后三个用于 **调用级**拦截（trace 追踪子调用链）。

### 4.4 NopSpy — 空实现的妙用

```java
static class NopSpy extends AbstractSpy {
    @Override
    public void atEnter(Class<?> clazz, String methodInfo, Object target, Object[] args) { }
    @Override
    public void atExit(...) { }
    // ... 所有方法都是空实现
}
```

当 Arthas **没有启动** 或 **已经停止**时，`spyInstance` 指向 NopSpy。增强后的目标类仍然会调用 `SpyAPI.atEnter()`，但 NopSpy 什么都不做——**零开销**（只是一次虚方法调用 + 空方法体，JIT 可以内联优化掉）。

**生命周期**：
```
SpyAPI.spyInstance 的值变化：

   首次加载（BootstrapCL）
        │
        ▼
   NOPSPY (空实现)
        │
   ArthasBootstrap 启动
   SpyAPI.setSpy(new SpyImpl())
        │
        ▼
   SpyImpl (真实实现)
        │
   Arthas destroy
   SpyAPI.setNopSpy()
        │
        ▼
   NOPSPY (恢复空实现)
```

### 4.5 跨 ClassLoader 的桥接

这里有一个经典的**跨 ClassLoader 引用**问题：

- `SpyAPI` 在 BootstrapClassLoader 中
- `SpyImpl` 在 ArthasClassloader 中
- `SpyAPI.spyInstance = new SpyImpl()` 能工作吗？

答案是**可以的**，因为：

1. `SpyAPI.AbstractSpy` 是 SpyAPI 的**内部抽象类**，也在 BootstrapClassLoader 中
2. `SpyImpl extends AbstractSpy` — SpyImpl 的父类在 BootstrapClassLoader 中
3. ArthasClassloader 的 parent 链中包含 BootstrapClassLoader（所有 ClassLoader 都能访问 BootstrapCL 的类）
4. `spyInstance` 的类型声明是 `AbstractSpy`（在 BootstrapCL 中），赋值为 `SpyImpl` 实例（多态）

**跨 ClassLoader 引用的方向**：**子可以引用父，父不能引用子**。

```
BootstrapCL:  AbstractSpy (抽象类)  ← spyInstance 的声明类型
                    ↑ extends
ArthasCL:     SpyImpl (实现类)      ← spyInstance 的运行时类型
```

这是合法的，因为 SpyImpl 加载时会触发加载其父类 AbstractSpy，而 ArthasClassloader 会委派给 BootstrapCL 来加载 AbstractSpy。

---

## 5. SpyImpl — 真实的回调分发

`SpyImpl` 是 SpyAPI 的具体实现，它做的事情很清晰——**查找监听器并逐个回调**：

```java
@Override
public void atEnter(Class<?> clazz, String methodInfo, Object target, Object[] args) {
    ClassLoader classLoader = clazz.getClassLoader();

    // 1. 解析方法信息："methodName|methodDesc"
    String[] info = StringUtils.splitMethodInfo(methodInfo);
    String methodName = info[0];
    String methodDesc = info[1];

    // 2. 查找关注这个方法的所有监听器
    List<AdviceListener> listeners = AdviceListenerManager.queryAdviceListeners(
            classLoader, clazz.getName(), methodName, methodDesc);

    // 3. 逐个回调
    if (listeners != null) {
        for (AdviceListener adviceListener : listeners) {
            try {
                if (skipAdviceListener(adviceListener)) {
                    continue;  // 跳过已停止的命令
                }
                adviceListener.before(clazz, methodName, methodDesc, target, args);
            } catch (Throwable e) {
                logger.error("class: {}, methodInfo: {}", clazz.getName(), methodInfo, e);
            }
        }
    }
}
```

关键设计点：

1. **ClassLoader 作为查询键**：`queryAdviceListeners` 的第一个参数是 `clazz.getClassLoader()`。因为同一个全限定名的类可能被不同 ClassLoader 加载（比如 Tomcat 的多个 webapp），需要区分。

2. **多监听器并发**：同一个方法可能同时被 `watch` 和 `trace` 监听，所以返回的是 List。

3. **skipAdviceListener**：如果对应的命令已经被用户中断（`Ctrl+C`），跳过回调。

4. **catch Throwable**：监听器的异常**绝不能传播到目标方法**，否则会影响业务逻辑。

### 5.1 atBeforeInvoke / atAfterInvoke — trace 专用

这三个方法（atBeforeInvoke、atAfterInvoke、atInvokeException）是 `trace` 命令专用的。它们追踪的不是目标方法本身，而是**目标方法内部调用的子方法**：

```java
@Override
public void atBeforeInvoke(Class<?> clazz, String invokeInfo, Object target) {
    // invokeInfo 格式: "owner|methodName|methodDesc|lineNumber"
    String[] info = StringUtils.splitInvokeInfo(invokeInfo);
    String owner = info[0];
    String methodName = info[1];
    String methodDesc = info[2];

    List<AdviceListener> listeners = AdviceListenerManager.queryTraceAdviceListeners(
            classLoader, clazz.getName(), owner, methodName, methodDesc);

    if (listeners != null) {
        for (AdviceListener adviceListener : listeners) {
            final InvokeTraceable listener = (InvokeTraceable) adviceListener;
            listener.invokeBeforeTracing(classLoader, owner, methodName, methodDesc,
                    Integer.parseInt(info[3]));   // 行号
        }
    }
}
```

注意这里强转为 `InvokeTraceable`——只有实现了 `InvokeTraceable` 接口的 AdviceListener 才能处理 trace 事件（如 `TraceAdviceListener`）。

---

## 6. ClassLoader_Instrument — 修补 ClassLoader 的盲区

### 6.1 问题：某些 ClassLoader 找不到 SpyAPI

虽然 SpyAPI 在 BootstrapClassLoader 中，但某些"叛逆"的 ClassLoader 不走标准双亲委派。比如：

- **OSGi ClassLoader**：每个 Bundle 有自己的可见性规则
- **自定义 ClassLoader**：覆写了 `loadClass()` 但没正确委派
- **热部署 ClassLoader**：如 Spring DevTools 的 RestartClassLoader

这些 ClassLoader 在加载增强后的目标类时，可能找不到 `java.arthas.SpyAPI`，导致 `NoClassDefFoundError`。

### 6.2 解决方案：增强 ClassLoader.loadClass()

```java
@Instrument(Class = "java.lang.ClassLoader")
public abstract class ClassLoader_Instrument {
    public Class<?> loadClass(String name) throws ClassNotFoundException {
        if (name.startsWith("java.arthas.")) {
            ClassLoader extClassLoader = ClassLoader.getSystemClassLoader().getParent();
            if (extClassLoader != null) {
                return extClassLoader.loadClass(name);
            }
        }
        Class clazz = InstrumentApi.invokeOrigin();  // 调用原始方法
        return clazz;
    }
}
```

这段代码通过 **bytekit**（Arthas 使用的字节码增强框架）修改了 `java.lang.ClassLoader` 的 `loadClass` 方法：

- 如果请求的类名以 `java.arthas.` 开头（即 SpyAPI），**强制委派给 ExtClassLoader**
- ExtClassLoader 的 parent 是 BootstrapClassLoader，所以能找到 SpyAPI
- 其他类名走原始逻辑（`InstrumentApi.invokeOrigin()`）

**这是 Arthas 对 JVM 自身的类进行增强**！`java.lang.ClassLoader` 是 BootstrapClassLoader 加载的核心类。Arthas 使用 `Instrumentation.retransformClasses(ClassLoader.class)` 来触发增强。

### 6.3 增强的触发时机

在 `ArthasBootstrap.enhanceClassLoader()` 中：

```java
void enhanceClassLoader() throws IOException, UnmodifiableClassException {
    if (configure.getEnhanceLoaders() == null) {
        return;
    }
    // ... 准备 InstrumentTransformer ...
    
    instrumentation.addTransformer(classLoaderInstrumentTransformer, true);

    if (loaders.size() == 1 && loaders.contains(ClassLoader.class.getName())) {
        instrumentation.retransformClasses(ClassLoader.class);
    } else {
        InstrumentationUtils.trigerRetransformClasses(instrumentation, loaders);
    }
}
```

默认配置下 `enhanceLoaders = "java.lang.ClassLoader"`，只增强 `java.lang.ClassLoader` 一个类。

---

## 7. ArthasBootstrap 初始化流程总结

现在把 `ArthasBootstrap` 构造函数中的 6 个步骤串起来：

```java
private ArthasBootstrap(Instrumentation instrumentation, Map<String, String> args) throws Throwable {
    this.instrumentation = instrumentation;

    initFastjson();         // 0. JSON 配置（忽略 getter 错误）

    initSpy();              // 1. ★ 将 spy.jar 加入 BootstrapCL
    initArthasEnvironment(args);  // 2. 解析配置参数
    // ...
    enhanceClassLoader();   // 4. ★ 修改 ClassLoader.loadClass
    initBeans();            // 5. 初始化 ResultViewResolver、HistoryManager
    bind(configure);        // 6. ★ 启动 Shell Server
    
    transformerManager = new TransformerManager(instrumentation);
    Runtime.getRuntime().addShutdownHook(shutdown);
}
```

```
┌────────────────────────────────────────────────────────────────────┐
│  ArthasBootstrap 初始化流程（在目标 JVM 内部执行）                   │
│                                                                    │
│  Step 0: initFastjson()                                           │
│    → 配置 JSON 序列化选项                                          │
│                                                                    │
│  Step 1: initSpy()                                                │
│    → 检查 SpyAPI 是否已在 BootstrapCL                              │
│    → 如果没有: inst.appendToBootstrapClassLoaderSearch(spy.jar)    │
│    → SpyAPI 现在可以被任何 ClassLoader 访问                         │
│                                                                    │
│  Step 2: initArthasEnvironment(args)                              │
│    → 解析参数字符串 → Map                                          │
│    → 配置优先级: 命令行 > System Env > System Props > arthas.props │
│    → 创建 Configure 对象                                          │
│                                                                    │
│  Step 3: initLogger()                                             │
│    → 初始化 Logback，输出到 ~/logs/arthas/arthas.log              │
│                                                                    │
│  Step 4: enhanceClassLoader()                                     │
│    → 用 bytekit 增强 ClassLoader.loadClass()                      │
│    → 确保所有 ClassLoader 都能找到 java.arthas.SpyAPI             │
│    → inst.retransformClasses(ClassLoader.class)                   │
│                                                                    │
│  Step 5: initBeans()                                              │
│    → ResultViewResolver (命令结果 → 文本渲染)                      │
│    → HistoryManager (命令历史)                                     │
│                                                                    │
│  Step 6: bind(configure)                                          │
│    → 初始化 SecurityAuthenticator                                 │
│    → 创建 ShellServer                                             │
│    → 注册 BuiltinCommandPack (所有内置命令)                        │
│    → 创建 NioEventLoopGroup (Netty worker)                        │
│    → 注册 HttpTelnetTermServer (:3658)                            │
│    → 注册 HttpTermServer (:8563)                                  │
│    → shellServer.listen()                                         │
│    → 创建 SessionManager + HttpApiHandler                         │
│    → 启动 TunnelClient (如果配置了)                                │
│    → 启动 McpServer (如果配置了)                                   │
│    → SpyAPI.init()  → INITED = true                               │
│    → 完成！                                                       │
│                                                                    │
│  Post: new TransformerManager(instrumentation)                    │
│  Post: Runtime.addShutdownHook(destroy)                           │
└────────────────────────────────────────────────────────────────────┘
```

### SpyAPI.init() 的时机

注意 `SpyAPI.init()` 是在 `bind()` 方法的**最后**调用的（第 495 行），而不是在 `initSpy()` 中。这意味着：

- `initSpy()` 只负责把 spy.jar 加入 BootstrapCL（**物理可用**）
- `SpyAPI.init()` 设置 `INITED = true`（**逻辑启用**）

只有 Shell Server 完全启动后，INITED 才变为 true。如果启动过程中出错，INITED 仍然是 false，下次 attach 时不会被幂等保护拦截。

---

## 8. destroy() — 清理流程

```java
public void destroy() {
    shellServer.close();           // 关闭 Shell Server
    sessionManager.close();        // 关闭所有会话
    httpSessionManager.stop();     // 关闭 HTTP 会话
    timer.cancel();                // 取消定时器
    tunnelClient.stop();           // 断开 Tunnel 连接
    executorService.shutdownNow(); // 关闭线程池
    transformerManager.destroy();  // 移除所有 Transformer
    instrumentation.removeTransformer(classLoaderInstrumentTransformer); // 移除 CL 增强
    cleanUpSpyReference();         // ★ 清理 Spy
    shutdownWorkGroup();           // 关闭 Netty worker
    loggerContext.stop();          // 关闭日志
}
```

### cleanUpSpyReference() — 跨 ClassLoader 清理

```java
private void cleanUpSpyReference() {
    try {
        SpyAPI.setNopSpy();   // spyInstance → NOPSPY
        SpyAPI.destroy();     // INITED = false
    } catch (Throwable e) {
        // ignore
    }
    // 通过反射重置 AgentBootstrap 的 ClassLoader 引用
    try {
        Class<?> clazz = ClassLoader.getSystemClassLoader()
                .loadClass("com.taobao.arthas.agent334.AgentBootstrap");
        Method method = clazz.getDeclaredMethod("resetArthasClassLoader");
        method.invoke(null);   // arthasClassLoader = null
    } catch (Throwable e) {
        // ignore
    }
}
```

为什么要通过反射调用 `resetArthasClassLoader()`？

因为 `ArthasBootstrap` 在 ArthasClassloader 中，`AgentBootstrap` 在系统 ClassLoader 中。只能通过反射跨 ClassLoader 通信。清空 `arthasClassLoader` 引用后，下次 attach 会重新创建 ClassLoader。

---

## 9. 完整调用链时序图

```
目标 JVM 内部
━━━━━━━━━━━━

JVM AttachListener 线程
    │
    │ 调用 AgentBootstrap.agentmain(args, inst)
    ▼
AgentBootstrap.main(args, inst)    [synchronized, 系统 CL]
    │
    ├── 1. Class.forName("java.arthas.SpyAPI")
    │       → 第一次: ClassNotFoundException → 继续
    │       → 已存在且 INITED: 直接 return（幂等）
    │
    ├── 2. decodeArg(args)
    │       → "arthas-core.jar路径;参数..." 
    │
    ├── 3. getClassLoader(inst, arthasCoreJarFile)
    │       → new ArthasClassloader([arthas-core.jar])
    │       → parent = ExtClassLoader (跳过 AppCL)
    │
    ├── 4. new Thread("arthas-binding-thread")
    │       → bind(inst, agentLoader, agentArgs)
    │
    │   arthas-binding-thread
    │   ━━━━━━━━━━━━━━━━━━━━
    │       │
    │       ├── agentLoader.loadClass("ArthasBootstrap")
    │       │   → ArthasClassloader 从 arthas-core.jar 加载
    │       │
    │       ├── ArthasBootstrap.getInstance(inst, args)  [反射调用]
    │       │   │
    │       │   ├── new ArthasBootstrap(inst, argsMap)
    │       │   │   │
    │       │   │   ├── initSpy()
    │       │   │   │   → inst.appendToBootstrapCLSearch(spy.jar)
    │       │   │   │   → SpyAPI 进入 BootstrapCL
    │       │   │   │
    │       │   │   ├── initArthasEnvironment(args)
    │       │   │   │   → 配置解析、优先级排序
    │       │   │   │
    │       │   │   ├── enhanceClassLoader()
    │       │   │   │   → 增强 ClassLoader.loadClass()
    │       │   │   │   → retransformClasses(ClassLoader.class)
    │       │   │   │
    │       │   │   ├── bind(configure)
    │       │   │   │   → ShellServer 启动
    │       │   │   │   → 监听 :3658 (Telnet) + :8563 (HTTP)
    │       │   │   │   → SpyAPI.init() → INITED = true
    │       │   │   │
    │       │   │   └── TransformerManager 初始化
    │       │   │
    │       │   └── return arthasBootstrap (单例)
    │       │
    │       └── bootstrap.isBind() → true
    │
    ├── bindingThread.join()  ← 等待完成
    │
    └── return  → agentmain 返回
                → loadAgent 调用返回
                → Arthas attach 进程退出
```

---

## 10. 关键设计决策总结

| 设计决策 | 原因 | 替代方案的缺点 |
|----------|------|---------------|
| SpyAPI 放入 BootstrapCL | 所有 ClassLoader 可见 | 放 AppCL：只有 AppCL 及其子 CL 可见；放 ArthasCL：没有 CL 可见 |
| ArthasClassloader 的 parent = ExtCL | 与 AppCL 隔离 | parent = AppCL：会看到目标应用的类，可能版本冲突 |
| 打破双亲委派 | Arthas 优先加载自己的类 | 标准委派：如果 ExtCL 碰巧有同名类，会加载错误版本 |
| 独立 binding thread | 防止 ThreadLocal 泄漏 | 直接在 Attach 线程中执行：可能泄漏 |
| 反射调用 ArthasBootstrap | 跨 ClassLoader 通信 | 直接引用：编译不过（不在同一个 ClassLoader） |
| SpyAPI.INITED 幂等标志 | 防止重复初始化 | 无标志：多次 attach 创建多个 ShellServer，端口冲突 |
| NopSpy 空实现 | Arthas 未启动时零开销 | null 检查：每次调用多一次 null 判断 |
| 增强 ClassLoader.loadClass | 修补叛逆 ClassLoader | 不增强：OSGi 等场景下 NoClassDefFoundError |

---

## 11. 小结

```
                              Agent 加载后的类空间分布
                              ━━━━━━━━━━━━━━━━━━━━

    BootstrapClassLoader
    ┌──────────────────────────────────────────────────────┐
    │  java.lang.ClassLoader (被增强，loadClass 加了判断)   │
    │  java.arthas.SpyAPI (spy.jar)                        │
    │  java.arthas.SpyAPI$AbstractSpy                      │
    │  java.arthas.SpyAPI$NopSpy                           │
    │  + 所有 java.*/javax.*/sun.* 核心类                  │
    └──────────────────────────────────────────────────────┘
              │ parent
    ExtClassLoader
    ┌──────────────────────────────────────────────────────┐
    │  javax.crypto.* / javax.xml.* 等扩展类               │
    └──────────────────────────────────────────────────────┘
         │ parent              │ parent
    AppClassLoader         ArthasClassloader
    ┌──────────────────┐   ┌──────────────────────────────┐
    │  目标应用的类      │   │  arthas-core.jar 中的所有类   │
    │  com.example.*    │   │  SpyImpl, Enhancer, ...      │
    │  (被增强的类会     │   │  ShellServer, WatchCommand   │
    │   调用 SpyAPI)    │   │  Netty, ASM, Logback, ...    │
    └──────────────────┘   └──────────────────────────────┘
    
    两者互不可见，只通过 BootstrapCL 中的 SpyAPI 桥接
```

**核心理解**：

1. **AgentBootstrap** 是目标 JVM 内部的"着陆点"——接收 Instrumentation 权限令牌，创建隔离 ClassLoader
2. **ArthasClassloader** 通过"parent = ExtCL + 打破双亲委派"实现了与目标应用的**双向隔离**
3. **SpyAPI** 通过放入 BootstrapCL 解决了"全局可见"问题，通过策略模式（NopSpy/SpyImpl）解决了"零开销"问题
4. **ClassLoader_Instrument** 通过增强 `ClassLoader.loadClass()` 修补了"叛逆 ClassLoader"的盲区
5. 整个 Agent 加载链使用**反射**跨越 ClassLoader 边界，用 **volatile + synchronized** 保证线程安全和幂等性

---

> **下一节预告**: [Ch 1.3 ArthasBootstrap 服务启动](ch01_3_arthas_bootstrap.md) — 深入分析 `bind()` 方法：ShellServer 怎么启动、Netty 怎么初始化、命令怎么注册、Tunnel 怎么连接。
