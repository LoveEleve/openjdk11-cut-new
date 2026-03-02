
# Ch 2.1 ArthasClassloader 设计 — 自定义 ClassLoader 的隔离艺术

> 源文件:
> - `agent/ArthasClassloader.java` (36行) — 自定义 ClassLoader，打破双亲委派
> - `agent/AgentBootstrap.java` (199行) — 创建和管理 ArthasClassloader
> - OpenJDK: `java.lang.ClassLoader` — 标准双亲委派模型
> - OpenJDK: `java.net.URLClassLoader` — ArthasClassloader 的父类

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **Ch 2.1 ArthasClassloader 设计 — 自定义 ClassLoader 的隔离艺术**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 0. 先回答"为什么"

### 0.1 Java Agent 的 ClassLoader 困境

当 Arthas 的 Agent 代码进入目标 JVM 后，它面临一个根本性的问题：

**问题**：Arthas 自身有大量依赖（Netty、ASM、Logback、fastjson2、OGNL 等），这些依赖怎么和目标应用的依赖隔离？

不隔离会怎样？三种典型灾难：

| 灾难场景 | 原因 | 后果 |
|----------|------|------|
| **版本冲突** | 目标应用用 Netty 4.0，Arthas 用 Netty 4.1 | `NoSuchMethodError`、`ClassCastException` |
| **类污染** | 目标应用能 `Class.forName` 到 Arthas 内部类 | 安全风险 + 不可预测行为 |
| **清理困难** | Arthas detach 后，类残留在 AppClassLoader 中 | Metaspace 泄漏 + 影响 hotswap |

### 0.2 业界解决方案对比

| 框架 | 隔离方案 | 优点 | 缺点 |
|------|---------|------|------|
| **Arthas** | 自定义 ClassLoader（parent=ExtCL） | 简单、轻量、隔离彻底 | 跨 CL 通信需要反射 |
| **SkyWalking** | 自定义 AgentClassLoader | 类似 Arthas 思路 | 多了插件 CL 机制 |
| **ByteBuddy Agent** | 同进程、Boot CL 注入 | 性能好 | 隔离性较差 |
| **OSGi** | 完整的模块化 CL 体系 | 隔离最彻底 | 过于复杂 |
| **async-profiler** | Native 代码，不走 Java CL | 完全无冲突 | 只能 C++ 实现 |

Arthas 选择了**最简洁的方案**——一个 36 行的自定义 ClassLoader。

---

## 1. Java ClassLoader 体系回顾

在分析 ArthasClassloader 之前，必须先理解标准的 ClassLoader 体系：

### 1.1 三层 ClassLoader 结构

```
┌─────────────────────────────────────────────────────────────┐
│  Bootstrap ClassLoader (C++ 实现，Java 中表示为 null)         │
│                                                              │
│  加载：java.*, javax.*, sun.*, jdk.* 等核心类                │
│  来源：$JAVA_HOME/lib/modules（JDK 9+）或 rt.jar（JDK 8）   │
│                                                              │
│  特点：所有 ClassLoader 都能访问它加载的类                     │
│        是 JVM 的"根"，不受任何 Java 级别的控制                │
└───────────────────────────┬─────────────────────────────────┘
                            │ parent
┌───────────────────────────▼─────────────────────────────────┐
│  ExtClassLoader / PlatformClassLoader                        │
│                                                              │
│  JDK 8: sun.misc.Launcher$ExtClassLoader                     │
│  JDK 9+: jdk.internal.loader.ClassLoaders$PlatformClassLoader│
│                                                              │
│  加载：javax.crypto.*, javax.xml.* 等扩展类                   │
│  来源：$JAVA_HOME/lib/ext/ (JDK 8) 或模块（JDK 9+）         │
└───────────────────────────┬─────────────────────────────────┘
                            │ parent
┌───────────────────────────▼─────────────────────────────────┐
│  AppClassLoader (系统 ClassLoader)                            │
│                                                              │
│  JDK 8: sun.misc.Launcher$AppClassLoader                     │
│  JDK 9+: jdk.internal.loader.ClassLoaders$AppClassLoader     │
│                                                              │
│  加载：classpath 上的所有应用类                                │
│  来源：-cp / -classpath / CLASSPATH                           │
│                                                              │
│  通过 ClassLoader.getSystemClassLoader() 获取                 │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 标准双亲委派模型

```java
// java.lang.ClassLoader.loadClass() 的核心逻辑
protected Class<?> loadClass(String name, boolean resolve) {
    // 1. 检查是否已经加载过
    Class<?> c = findLoadedClass(name);
    if (c == null) {
        // 2. 委派给 parent 先加载
        if (parent != null) {
            c = parent.loadClass(name, false);
        } else {
            c = findBootstrapClassOrNull(name);  // Bootstrap CL
        }
        // 3. parent 找不到，才自己加载
        if (c == null) {
            c = findClass(name);
        }
    }
    return c;
}
```

**关键规则**：`parent → self`（先委派给父加载器，父找不到才自己找）

### 1.3 为什么双亲委派不适合 Arthas？

假设 Arthas 的 ClassLoader 走标准双亲委派，parent = AppClassLoader：

```
场景：目标应用有 Netty 4.0，Arthas 需要 Netty 4.1

ArthasClassloader.loadClass("io.netty.channel.Channel")
  → AppClassLoader.loadClass("io.netty.channel.Channel")
    → ExtClassLoader → 找不到
    → AppClassLoader.findClass → 找到 Netty 4.0 的 Channel ← 错误！
  → 返回 Netty 4.0 的 Channel
  → Arthas 用 Netty 4.1 的 API 调用 → NoSuchMethodError！
```

即使 parent = ExtClassLoader（不走 AppCL），标准双亲委派仍然是"先问 parent"。如果 ExtClassLoader 碰巧能加载到某个同名类（虽然概率很低），也会加载错误版本。

**所以 Arthas 必须打破双亲委派：先自己加载，找不到才委派**。

---

## 2. ArthasClassloader 逐行分析

完整源码只有 36 行，但每一行都有设计考量：

```java
package com.taobao.arthas.agent;                            // 行 1

import java.net.URL;                                         // 行 3
import java.net.URLClassLoader;                              // 行 4

public class ArthasClassloader extends URLClassLoader {      // 行 9
    public ArthasClassloader(URL[] urls) {                   // 行 10
        super(urls, ClassLoader.getSystemClassLoader().getParent());  // 行 11
    }

    @Override
    protected synchronized Class<?> loadClass(String name, boolean resolve)  // 行 15
            throws ClassNotFoundException {
        final Class<?> loadedClass = findLoadedClass(name);  // 行 16
        if (loadedClass != null) {                           // 行 17
            return loadedClass;                              // 行 18
        }

        // 优先从parent（SystemClassLoader）里加载系统类      // 行 21
        if (name != null && (name.startsWith("sun.") || name.startsWith("java."))) {  // 行 22
            return super.loadClass(name, resolve);           // 行 23
        }
        try {
            Class<?> aClass = findClass(name);               // 行 26
            if (resolve) {
                resolveClass(aClass);                        // 行 28
            }
            return aClass;                                   // 行 30
        } catch (Exception e) {
            // ignore                                        // 行 32
        }
        return super.loadClass(name, resolve);               // 行 34
    }
}
```

### 2.1 构造函数：选择 parent

```java
super(urls, ClassLoader.getSystemClassLoader().getParent());
```

这是整个类**最关键的一行**。分解来看：

1. `ClassLoader.getSystemClassLoader()` → 返回 AppClassLoader
2. `.getParent()` → 返回 ExtClassLoader（JDK 8）/ PlatformClassLoader（JDK 9+）
3. `super(urls, extClassLoader)` → ArthasClassloader 的 parent 设为 ExtClassLoader

效果：

```
BootstrapClassLoader
    └→ ExtClassLoader
        ├→ AppClassLoader ────── 目标应用的类
        └→ ArthasClassloader ── Arthas 的类
```

**AppClassLoader 和 ArthasClassloader 成为"兄弟"**，互相不可见：
- 目标应用通过 AppCL 加载的类，看不到 ArthasClassloader 中的类
- Arthas 通过 ArthasClassloader 加载的类，看不到 AppCL 中的类
- 两者**共享 BootstrapCL 和 ExtCL 的类**（java.*、sun.* 等）

### 2.2 为什么不用 AppClassLoader 做 parent？

```java
// ❌ 如果这样写
super(urls, ClassLoader.getSystemClassLoader());  // parent = AppCL
```

结果：ArthasClassloader 变成 AppCL 的**子类加载器**。走标准双亲委派时，AppCL 会先加载——目标应用的类对 Arthas "可见"，破坏隔离。

```java
// ❌ 如果这样写
super(urls, null);  // parent = null → 直接用 BootstrapCL
```

结果：看不到 ExtClassLoader 的类（如 `javax.crypto.*`）。虽然 Arthas 可能不直接需要这些，但某些第三方库可能间接依赖。

```java
// ✅ 最佳选择
super(urls, ClassLoader.getSystemClassLoader().getParent());  // parent = ExtCL
```

既跳过了 AppCL（隔离），又保留了 ExtCL 和 BootstrapCL（基础类可用）。

### 2.3 loadClass()：反转委派顺序

标准双亲委派：`parent → self`
ArthasClassloader：**`self → parent`**

```
标准流程:           loadClass → parent.loadClass → findClass(自己)
Arthas 流程:        loadClass → findClass(自己) → parent.loadClass
```

具体步骤：

```
Step 1: findLoadedClass(name)
  → 检查此 CL 是否已经加载过该类
  → 已加载直接返回（缓存命中）

Step 2: 系统类判断
  → name.startsWith("sun.") || name.startsWith("java.")
  → 是：走标准委派（super.loadClass → parent → Bootstrap）
  → 否：继续

Step 3: findClass(name)   ← 先自己找！
  → 在 arthas-core.jar 中查找该类
  → 找到：返回
  → 找不到：抛 ClassNotFoundException → catch 忽略

Step 4: super.loadClass(name, resolve)  ← 找不到才委派
  → ExtCL → BootstrapCL
  → 仍然找不到：抛 ClassNotFoundException
```

### 2.4 对 `java.*` 和 `sun.*` 的特殊处理

```java
if (name != null && (name.startsWith("sun.") || name.startsWith("java."))) {
    return super.loadClass(name, resolve);
}
```

这不是"优化"，而是**JVM 安全机制的强制要求**。

JVM 规定：`java.*` 包下的类只能由 BootstrapClassLoader 定义（defineClass）。如果自定义 ClassLoader 试图 `defineClass("java.xxx", bytes)`，JVM 会直接抛出 `SecurityException: Prohibited package name: java`。

同理，`sun.*` 包下的类也有类似限制（虽然不如 `java.*` 严格，但尝试自定义加载通常会引发问题）。

> **注意**：这里的判断条件可能**不够完整**。JDK 9+ 的模块系统中，`javax.*`、`jdk.*` 等包也有类似限制。但 Arthas 的 arthas-core.jar 中不会打包这些包的类，所以实际上不会触发问题。

### 2.5 synchronized 的作用

```java
protected synchronized Class<?> loadClass(String name, boolean resolve) {
```

`loadClass` 加了 `synchronized`，意味着**同一时刻只有一个线程能通过此 ClassLoader 加载类**。

为什么需要？

考虑这个场景：两个线程同时通过 ArthasClassloader 加载 `io.netty.channel.Channel`：

```
线程 A:  findLoadedClass → null → findClass → 开始从 JAR 读取字节码...
线程 B:  findLoadedClass → null → findClass → 也开始从 JAR 读取字节码...
```

如果没有同步，两个线程都会调用 `defineClass()`，第二个会抛出 `LinkageError: attempted duplicate class definition`。

> **性能影响**：`synchronized` 在类加载阶段可能成为瓶颈，但 Arthas 的类加载集中在启动阶段（加载 arthas-core.jar 中的几百个类），之后就命中 `findLoadedClass` 缓存。所以实际影响很小。

---

## 3. ArthasClassloader 的生命周期

### 3.1 创建

```java
// AgentBootstrap.java
private static volatile ClassLoader arthasClassLoader;

private static ClassLoader loadOrDefineClassLoader(File arthasCoreJarFile) throws Throwable {
    if (arthasClassLoader == null) {
        arthasClassLoader = new ArthasClassloader(new URL[]{arthasCoreJarFile.toURI().toURL()});
    }
    return arthasClassLoader;
}
```

- `arthasClassLoader` 是 **static volatile**——全局唯一，线程安全可见
- `loadOrDefineClassLoader` 在 `main()` 的 synchronized 块中调用，保证不会并发创建

创建时传入的 URL 只有一个：**arthas-core.jar**。Arthas 把所有核心依赖都打包到了这一个 fat JAR 中（通过 maven-assembly-plugin）。

### 3.2 复用（重复 Attach）

```java
if (arthasClassLoader == null) {      // 如果还没创建
    arthasClassLoader = new ArthasClassloader(...);  // 创建新的
}
return arthasClassLoader;              // 否则复用已有的
```

第二次 attach 时（例如 Arthas 进程异常退出后重新 attach），如果 `arthasClassLoader` 不为 null，会**复用**之前的 ClassLoader。这意味着 `ArthasBootstrap.getInstance()` 返回的是同一个单例——不会重复初始化。

### 3.3 销毁

```java
// AgentBootstrap.java
public static void resetArthasClassLoader() {
    arthasClassLoader = null;
}
```

```java
// ArthasBootstrap.destroy() 中通过反射调用
private void cleanUpSpyReference() {
    // ... 清理 Spy ...
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

**为什么要用反射调用 `resetArthasClassLoader()`？**

因为 `ArthasBootstrap`（在 ArthasClassloader 中）和 `AgentBootstrap`（在系统 ClassLoader 中）处于**不同的 ClassLoader**。`ArthasBootstrap` 不能直接引用 `AgentBootstrap`（编译期看不到），只能通过反射。

### 3.4 ClassLoader 卸载的条件

将 `arthasClassLoader` 设为 null 后，ArthasClassloader 及其加载的所有类**并不会立即被卸载**。JVM 卸载类的条件很严格：

```
ClassLoader 可以被 GC 回收的条件（必须同时满足）：
1. 该 ClassLoader 实例不可达（没有任何引用指向它）
2. 该 ClassLoader 加载的所有类的 Class 对象不可达
3. 这些类的所有实例都不可达
```

在 Arthas 中：
- `resetArthasClassLoader()` 清除了全局引用 ✓
- `SpyAPI.setNopSpy()` 清除了 SpyImpl 实例引用 ✓
- `transformerManager.destroy()` 移除了所有 Transformer ✓
- ShellServer/SessionManager 等组件都已 close ✓

理论上，在下次 GC 时，旧的 ArthasClassloader 可以被回收。但如果有任何**遗漏的引用**（比如某个线程的 ContextClassLoader 仍然指向它），就会导致泄漏。

> **实际观察**：多次 attach/detach 后，Metaspace 可能缓慢增长，这就是 ClassLoader 未完全卸载的表现。

---

## 4. 加载了哪些类？

ArthasClassloader 的 URL 只有 arthas-core.jar，但这是一个 **fat JAR**，包含了所有核心代码和依赖：

```
arthas-core.jar 内部结构（部分）：

com/taobao/arthas/core/         ← Arthas 核心代码
  ├── server/ArthasBootstrap    
  ├── advisor/Enhancer          
  ├── advisor/SpyImpl           
  ├── advisor/SpyInterceptors   
  ├── command/monitor200/WatchCommand
  ├── shell/impl/ShellServerImpl
  └── ...

com/alibaba/arthas/deps/        ← 依赖（重命名了包名！）
  ├── org/slf4j/                ← Logback（重命名避免冲突）
  ├── ch/qos/logback/           ← Logback
  ├── io/netty/                 ← Netty
  └── ...

com/alibaba/bytekit/            ← bytekit 字节码增强框架
com/alibaba/fastjson2/          ← JSON 序列化
org/objectweb/asm/              ← ASM 字节码框架
ognl/                           ← OGNL 表达式引擎
```

**关键设计**：Arthas 的某些依赖（如 Logback）被**重命名了包名**（shade），从 `org.slf4j` 变成了 `com.alibaba.arthas.deps.org.slf4j`。这是为了进一步避免冲突——即使 ClassLoader 隔离失败（比如某些反射场景），包名不同也不会冲突。

---

## 5. 与目标应用的类交互

虽然 ArthasClassloader 和 AppClassLoader 互相隔离，但 Arthas 在某些场景下**必须访问目标应用的类**：

### 5.1 OGNL 表达式求值

当用户执行 `watch com.example.MyService doSomething '{params}'` 时，OGNL 需要访问目标类的实例和方法。

**解决方案**：OGNL 求值时，临时设置 ClassLoader 上下文：

```java
// OgnlExpress.java（简化）
public Object get(String express, Object context, ClassLoader classLoader) {
    // 使用目标类的 ClassLoader 来解析 OGNL 表达式
    OgnlContext ctx = new OgnlContext();
    ctx.setClassResolver(new CustomClassResolver(classLoader));
    return Ognl.getValue(express, ctx, context);
}
```

### 5.2 Enhancer 增强目标类

Enhancer 需要读取目标类的字节码并用 ASM 修改。但 Enhancer 本身在 ArthasClassloader 中。

**解决方案**：通过 `Instrumentation.retransformClasses()` 触发增强。JVM 会将目标类的原始字节码传给 `ClassFileTransformer.transform()` 方法——这个方法的参数中包含了 `ClassLoader inClassLoader`（目标类的 ClassLoader）和 `byte[] classfileBuffer`（原始字节码）。Enhancer 不需要自己加载目标类，JVM 主动"送上门来"。

### 5.3 SpyAPI 桥接

增强后的目标类（在 AppCL 中）需要调用 SpyImpl（在 ArthasCL 中）——这个问题由 SpyAPI（在 BootstrapCL 中）作为中间桥梁解决，详见下一节 [Ch 2.2 Spy 机制](ch02_2_spy_mechanism.md)。

---

## 6. 完整的 ClassLoader 交互图

```
                              JVM 类加载体系
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                         │
│  BootstrapClassLoader (C++ / null)                                      │
│  ┌────────────────────────────────────────────────────────────────┐     │
│  │  java.lang.ClassLoader  (被 Arthas 增强，加了 java.arthas.* 判断) │     │
│  │  java.arthas.SpyAPI      (spy.jar，Arthas 桩)                    │     │
│  │  java.arthas.SpyAPI$AbstractSpy                                  │     │
│  │  java.arthas.SpyAPI$NopSpy                                       │     │
│  │  java.lang.*, javax.*, sun.*, jdk.* 等核心类                     │     │
│  └────────────────────────────────────────────────────────────────┘     │
│         │ parent                                                        │
│  ExtClassLoader                                                         │
│  ┌────────────────────────────────────────────────────────────────┐     │
│  │  javax.crypto.*, javax.xml.* 等扩展类                           │     │
│  └────────────────────────────────────────────────────────────────┘     │
│         │ parent                │ parent                                │
│         ▼                       ▼                                       │
│  AppClassLoader            ArthasClassloader                            │
│  ┌──────────────────┐     ┌──────────────────────────────────────┐     │
│  │ 目标应用的类       │     │ arthas-core.jar (fat JAR)             │     │
│  │                   │     │                                      │     │
│  │ com.example.      │     │ SpyImpl → AdviceListenerManager     │     │
│  │  MyService (增强后)│─────│──→ 通过 BootstrapCL 的 SpyAPI 桥接   │     │
│  │   ↓调用           │  ①  │                                      │     │
│  │ SpyAPI.atEnter()  │     │ Enhancer → ClassFileTransformer     │     │
│  │   ↑在 BootstrapCL │     │   ↑ 通过 Instrumentation API 增强    │     │
│  │                   │     │     目标类，不需要直接加载目标类       │     │
│  │                   │     │                                      │     │
│  │                   │     │ OgnlExpress                          │     │
│  │   ②               │     │   ← 求值时使用目标类的 ClassLoader    │     │
│  │ 目标类实例 ────────│─────│──→ CustomClassResolver(targetCL)     │     │
│  │                   │     │                                      │     │
│  │                   │     │ Netty, ASM, Logback (shade后包名)    │     │
│  └──────────────────┘     └──────────────────────────────────────┘     │
│                                                                         │
│  ① 增强后的目标类调用 SpyAPI（在 BootstrapCL 中，全局可见）              │
│  ② OGNL 表达式求值时，通过传入的 classLoader 参数访问目标类              │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 7. 潜在问题与边界场景

### 7.1 JDK 9+ 模块系统的影响

JDK 9 引入了 JPMS（Java Platform Module System），`ExtClassLoader` 被替换为 `PlatformClassLoader`。但 `ClassLoader.getSystemClassLoader().getParent()` 仍然返回 `PlatformClassLoader`——Arthas 的代码不需要修改。

但模块系统增加了**强封装**：某些 `sun.*`、`jdk.*` 包下的类默认不对外暴露。如果 Arthas 需要反射访问这些类，可能需要添加 `--add-opens` 参数。Arthas 通过 `Instrumentation.redefineModule()` 在运行时打开模块访问。

### 7.2 Thread ContextClassLoader 问题

Java 的某些框架（如 JNDI、JAXB、SPI）会通过 `Thread.currentThread().getContextClassLoader()` 获取 ClassLoader。

当 Arthas 的 binding 线程执行代码时，它的 ContextClassLoader 默认继承自创建它的线程（Attach Listener 线程），通常是系统 ClassLoader。如果 Arthas 在 binding 线程中需要加载自己的类（通过 SPI 等机制），可能会从错误的 ClassLoader 加载。

**Arthas 的应对**：大部分操作在独立线程中，且直接使用 ArthasClassloader 加载类（通过反射），不依赖 ContextClassLoader。

### 7.3 多 ClassLoader 场景（Web 容器）

在 Tomcat/Jetty 等 Web 容器中，每个 WebApp 有独立的 ClassLoader：

```
BootstrapCL
  └→ ExtCL
      ├→ AppCL (Tomcat 启动类)
      │   └→ SharedCL
      │       ├→ WebappCL-1 (应用 A)
      │       └→ WebappCL-2 (应用 B)
      └→ ArthasClassloader
```

当用户 `watch` 应用 A 的类时，增强后的代码由 WebappCL-1 加载。调用 `SpyAPI.atEnter(clazz, ...)` 时，`clazz.getClassLoader()` 返回的是 WebappCL-1。SpyImpl 通过这个 ClassLoader 来区分不同 WebApp 的监听器。

---

## 8. 验证方法

### 8.1 用 Arthas 自诊断验证 ClassLoader 树

```bash
# 启动 Arthas 后执行
arthas> classloader -t
```

预期输出：
```
+-BootstrapClassLoader
+-sun.misc.Launcher$ExtClassLoader@xxxx
  +-com.taobao.arthas.agent.ArthasClassloader@yyyy    ← Arthas 的 ClassLoader
  +-sun.misc.Launcher$AppClassLoader@zzzz
    +-... (应用的 ClassLoader)
```

### 8.2 验证 SpyAPI 的 ClassLoader

```bash
arthas> sc -d java.arthas.SpyAPI
```

预期输出中 `classLoaderHash` 应该为 `null`（表示 BootstrapClassLoader）。

### 8.3 验证隔离性

```bash
# 在目标应用中尝试加载 Arthas 内部类（应该失败）
arthas> ognl '@Thread@currentThread().getContextClassLoader().loadClass("com.taobao.arthas.core.server.ArthasBootstrap")'
# 预期：ClassNotFoundException（因为 AppCL 看不到 ArthasCL 的类）
```

---

## 9. 小结

| 设计决策 | 实现方式 | 解决的问题 |
|----------|---------|-----------|
| parent = ExtCL | `ClassLoader.getSystemClassLoader().getParent()` | 与 AppCL 隔离（兄弟关系） |
| 打破双亲委派 | `findClass → super.loadClass` | Arthas 优先加载自己的类 |
| java.*/sun.* 特殊处理 | 提前委派给 parent | JVM 安全限制 |
| static volatile 全局持有 | `arthasClassLoader` 字段 | 复用 CL，避免重复创建 |
| fat JAR + shade | 所有依赖打入一个 JAR | 减少 URL 数量 + 避免包名冲突 |
| 反射跨 CL 通信 | `agentLoader.loadClass(...).getMethod(...).invoke(...)` | 跨越 ClassLoader 边界 |

**核心理解**：ArthasClassloader 的 36 行代码实现了三个目标：

1. **隔离**：通过 parent = ExtCL，与目标应用互不可见
2. **自主**：通过打破双亲委派，优先加载自己的类
3. **兼容**：通过 java.*/sun.* 白名单，确保核心类由 JVM 正确加载

---

> **下一节**: [Ch 2.2 Spy 机制 — BootstrapClassLoader 中的桥梁](ch02_2_spy_mechanism.md) — SpyAPI 如何解决"增强后的目标类怎么调用 Arthas 回调"这个核心问题。
