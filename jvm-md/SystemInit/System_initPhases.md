# Phase 6.4/6.6/6.7: System 初始化三阶段详解 ⭐⭐⭐⭐

> **源码位置**: 
> - JVM 层: `src/hotspot/share/runtime/thread.cpp`
> - Java 层: `src/java.base/share/classes/java/lang/System.java`
> - VM 状态: `src/java.base/share/classes/jdk/internal/misc/VM.java`

---

## 📊 三阶段总览

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                              System 初始化三阶段完整流程                                     │
├─────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                               │
│  ┌─────────────────────────────────────────────────────────────────────────────────────────┐│
│  │  Phase 1: initPhase1()  ⭐⭐⭐⭐                                                         ││
│  │  ───────────────────────────────                                                        ││
│  │  • 初始化系统属性 (Properties)                                                           ││
│  │  • 初始化标准流 (System.in/out/err)                                                      ││
│  │  • 设置 Java 信号处理器                                                                  ││
│  │  • 将主线程添加到 main 线程组                                                            ││
│  │  • 设置 SharedSecrets (跨包访问)                                                         ││
│  │  • VM.initLevel(1)                                                                       ││
│  │                                                                                          ││
│  │  【完成后】可以使用 System.out.println() 了！                                            ││
│  └─────────────────────────────────────────────────────────────────────────────────────────┘│
│                                              ↓                                               │
│  ┌─────────────────────────────────────────────────────────────────────────────────────────┐│
│  │  Phase 2: initPhase2()  ⭐⭐⭐⭐                                                         ││
│  │  ───────────────────────────────                                                        ││
│  │  • 初始化模块系统 (JPMS - Java Platform Module System)                                   ││
│  │  • ModuleBootstrap.boot() 创建 boot Layer                                               ││
│  │  • VM.initLevel(2)                                                                       ││
│  │                                                                                          ││
│  │  【完成后】可以加载 -Xbootclasspath/a 中的类了！                                          ││
│  └─────────────────────────────────────────────────────────────────────────────────────────┘│
│                                              ↓                                               │
│  ┌─────────────────────────────────────────────────────────────────────────────────────────┐│
│  │  Phase 3: initPhase3()  ⭐⭐⭐                                                           ││
│  │  ───────────────────────────────                                                        ││
│  │  • 设置 SecurityManager (如果配置了 java.security.manager)                               ││
│  │  • 初始化系统类加载器 (AppClassLoader)                                                   ││
│  │  • 设置线程上下文类加载器 (TCCL)                                                         ││
│  │  • VM.initLevel(3) → VM.initLevel(4)                                                     ││
│  │                                                                                          ││
│  │  【完成后】VM 完全启动，可以加载应用类了！                                                ││
│  └─────────────────────────────────────────────────────────────────────────────────────────┘│
│                                                                                               │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 📈 VM 初始化级别状态机

```
┌───────────────────────────────────────────────────────────────────────────────────────────┐
│                            VM 初始化级别 (initLevel) 状态机                                │
├───────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                            │
│  initLevel = 0 ─────► initLevel = 1 ─────► initLevel = 2 ─────► initLevel = 3 ───────►   │
│      │                    │                    │                    │                      │
│      │ (初始状态)         │ initPhase1        │ initPhase2        │ initPhase3            │
│      │                    │ 完成后            │ 完成后            │ 中期                   │
│      ▼                    ▼                    ▼                    ▼                      │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                │
│  │ VM 刚启动   │    │ 系统属性    │    │ 模块系统    │    │ 系统类加载器│                │
│  │ 最小功能    │    │ 标准流可用  │    │ 已初始化    │    │ 初始化中    │                │
│  └─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘                │
│                                                                      │                     │
│                                                                      ▼                     │
│                                                              initLevel = 4                │
│                                                                      │                     │
│                                                                      │ initPhase3         │
│                                                                      │ 完成后             │
│                                                                      ▼                     │
│                                                          ┌─────────────────────────┐      │
│                                                          │ SYSTEM_BOOTED           │      │
│                                                          │ VM 完全启动             │      │
│                                                          │ VM.isBooted() = true    │      │
│                                                          └─────────────────────────┘      │
│                                                                      │                     │
│                                                                      ▼                     │
│                                                              initLevel = 5                │
│                                                          ┌─────────────────────────┐      │
│                                                          │ SYSTEM_SHUTDOWN         │      │
│                                                          │ VM 关闭中               │      │
│                                                          └─────────────────────────┘      │
│                                                                                            │
├───────────────────────────────────────────────────────────────────────────────────────────┤
│  源码定义 (VM.java):                                                                       │
│                                                                                            │
│  private static final int JAVA_LANG_SYSTEM_INITED    = 1;  // initPhase1 完成            │
│  private static final int MODULE_SYSTEM_INITED       = 2;  // initPhase2 完成            │
│  private static final int SYSTEM_LOADER_INITIALIZING = 3;  // initPhase3 进行中          │
│  private static final int SYSTEM_BOOTED              = 4;  // initPhase3 完成，VM 就绪   │
│  private static final int SYSTEM_SHUTDOWN            = 5;  // VM 关闭                    │
│                                                                                            │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 🔍 Phase 1: initPhase1() 详解

### 源码分析

```java
// 文件: src/java.base/share/classes/java/lang/System.java:1937
private static void initPhase1() {
    // ═══════════════════════════════════════════════════════════════════════
    // Step 1: 初始化系统属性
    // ═══════════════════════════════════════════════════════════════════════
    // 创建 Properties 对象，初始容量 84（优化过的大小）
    props = new Properties(84);
    
    // 由 JVM 本地方法填充系统属性
    // 包括: java.home, user.name, user.home, os.name, file.separator 等
    initProperties(props);  // native 方法，由 VM 调用

    // ═══════════════════════════════════════════════════════════════════════
    // Step 2: 保存私有副本并移除内部属性
    // ═══════════════════════════════════════════════════════════════════════
    // 移除不对外公开的内部属性，如:
    // - sun.nio.MaxDirectMemorySize (用于 DirectByteBuffer)
    // - java.lang.Integer.IntegerCache.high (用于整数缓存)
    VM.saveAndRemoveProperties(props);

    // ═══════════════════════════════════════════════════════════════════════
    // Step 3: 初始化静态属性
    // ═══════════════════════════════════════════════════════════════════════
    lineSeparator = props.getProperty("line.separator");  // \n 或 \r\n
    StaticProperty.javaHome();   // 缓存 java.home
    VersionProps.init();         // 初始化版本信息

    // ═══════════════════════════════════════════════════════════════════════
    // Step 4: 初始化标准流 ⭐⭐⭐⭐⭐ (重要！)
    // ═══════════════════════════════════════════════════════════════════════
    // FileDescriptor.in/out/err 是在 FileDescriptor 类初始化时由 JVM 设置的
    FileInputStream fdIn = new FileInputStream(FileDescriptor.in);
    FileOutputStream fdOut = new FileOutputStream(FileDescriptor.out);
    FileOutputStream fdErr = new FileOutputStream(FileDescriptor.err);
    
    // 包装成 BufferedInputStream/PrintStream
    setIn0(new BufferedInputStream(fdIn));
    setOut0(newPrintStream(fdOut, props.getProperty("sun.stdout.encoding")));
    setErr0(newPrintStream(fdErr, props.getProperty("sun.stderr.encoding")));
    
    // 【此时 System.out.println() 可用了！】

    // ═══════════════════════════════════════════════════════════════════════
    // Step 5: 设置信号处理器
    // ═══════════════════════════════════════════════════════════════════════
    // 处理 SIGHUP, SIGTERM, SIGINT 信号（优雅关闭）
    Terminator.setup();

    // ═══════════════════════════════════════════════════════════════════════
    // Step 6: 初始化 OS 特定设置
    // ═══════════════════════════════════════════════════════════════════════
    // Windows: 设置进程错误模式
    // Linux/Mac: 通常是空操作
    VM.initializeOSEnvironment();

    // ═══════════════════════════════════════════════════════════════════════
    // Step 7: 将主线程添加到线程组 ⭐⭐⭐
    // ═══════════════════════════════════════════════════════════════════════
    // 注意：主线程在创建时没有通过正常的 Thread() 构造函数添加到线程组
    // 因此必须在这里手动添加
    Thread current = Thread.currentThread();
    current.getThreadGroup().add(current);  // 添加到 main 线程组

    // ═══════════════════════════════════════════════════════════════════════
    // Step 8: 注册 SharedSecrets (跨包访问机制)
    // ═══════════════════════════════════════════════════════════════════════
    // 允许 jdk.internal 包访问 java.lang 包的内部方法
    setJavaLangAccess();

    // ═══════════════════════════════════════════════════════════════════════
    // Step 9: 初始化本地库路径
    // ═══════════════════════════════════════════════════════════════════════
    ClassLoader.initLibraryPaths();

    // ═══════════════════════════════════════════════════════════════════════
    // Step 10: 设置初始化级别为 1 (必须是最后一步！)
    // ═══════════════════════════════════════════════════════════════════════
    VM.initLevel(1);  // JAVA_LANG_SYSTEM_INITED
}
```

### 关键点：标准流初始化

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                           标准流初始化流程                                               │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│  JVM 启动时:                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────────────────────┐│
│  │  FileDescriptor.in  = new FileDescriptor(0);  // stdin  - fd 0                      ││
│  │  FileDescriptor.out = new FileDescriptor(1);  // stdout - fd 1                      ││
│  │  FileDescriptor.err = new FileDescriptor(2);  // stderr - fd 2                      ││
│  └─────────────────────────────────────────────────────────────────────────────────────┘│
│                                              ↓                                           │
│  initPhase1():                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────────────────────┐│
│  │  System.in  ← BufferedInputStream ← FileInputStream ← FileDescriptor.in             ││
│  │  System.out ← PrintStream ← BufferedOutputStream ← FileOutputStream ← FD.out        ││
│  │  System.err ← PrintStream ← BufferedOutputStream ← FileOutputStream ← FD.err        ││
│  └─────────────────────────────────────────────────────────────────────────────────────┘│
│                                                                                          │
│  为什么 System.out 是 PrintStream 而不是 BufferedOutputStream?                           │
│  ─────────────────────────────────────────────────────────────                           │
│  • PrintStream 支持 println()、printf() 等便捷方法                                       │
│  • PrintStream 内部包含 BufferedOutputStream (autoFlush = true)                         │
│  • 默认每次 println() 后自动 flush                                                       │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 🔍 Phase 2: initPhase2() 详解

### 源码分析

```java
// 文件: src/java.base/share/classes/java/lang/System.java:2008
private static int initPhase2(boolean printToStderr, boolean printStackTrace) {
    try {
        // ═══════════════════════════════════════════════════════════════════
        // 核心：初始化模块系统，创建 boot Layer
        // ═══════════════════════════════════════════════════════════════════
        // ModuleBootstrap.boot() 执行以下操作：
        // 1. 解析 --module-path 指定的模块
        // 2. 解析 --add-modules 指定的模块
        // 3. 构建模块图
        // 4. 创建 boot Layer (所有 java.base 模块所在的层)
        bootLayer = ModuleBootstrap.boot();
        
    } catch (Exception | Error e) {
        // 模块初始化失败，打印错误信息
        logInitException(printToStderr, printStackTrace,
                         "Error occurred during initialization of boot layer", e);
        return -1;  // JNI_ERR
    }

    // 模块系统初始化完成
    VM.initLevel(2);  // MODULE_SYSTEM_INITED

    return 0;  // JNI_OK
}
```

### JVM 层调用

```cpp
// 文件: src/hotspot/share/runtime/thread.cpp:3783
static void call_initPhase2(TRAPS) {
    TraceTime timer("Initialize module system", TRACETIME_LOG(Info, startuptime));

    Klass *klass = SystemDictionary::resolve_or_fail(vmSymbols::java_lang_System(), true, CHECK);

    JavaValue result(T_INT);
    JavaCallArguments args;
    args.push_int(DisplayVMOutputToStderr);      // 是否输出到 stderr
    args.push_int(log_is_enabled(Debug, init));  // 是否打印堆栈
    
    JavaCalls::call_static(&result, klass, vmSymbols::initPhase2_name(),
                           vmSymbols::boolean_boolean_int_signature(), &args, CHECK);
    
    if (result.get_jint() != JNI_OK) {
        vm_exit_during_initialization();  // 模块初始化失败，退出
    }

    // 通知 Universe 模块系统已初始化
    universe_post_module_init();
}
```

### 模块系统初始化流程

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                         ModuleBootstrap.boot() 执行流程                                  │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│  Step 1: 解析命令行选项                                                                  │
│  ┌─────────────────────────────────────────────────────────────────────────────────────┐│
│  │  --module-path / -p        → 应用模块路径                                            ││
│  │  --upgrade-module-path     → 升级模块路径                                            ││
│  │  --add-modules             → 额外要加载的模块                                        ││
│  │  --limit-modules           → 限制可观察的模块                                        ││
│  │  --patch-module            → 模块补丁                                                ││
│  └─────────────────────────────────────────────────────────────────────────────────────┘│
│                                              ↓                                           │
│  Step 2: 创建 ModuleFinder                                                               │
│  ┌─────────────────────────────────────────────────────────────────────────────────────┐│
│  │  • systemModuleFinder  → 系统模块 ($JAVA_HOME/jmods)                                ││
│  │  • upgradeModuleFinder → 升级模块路径                                                ││
│  │  • appModuleFinder     → 应用模块路径                                                ││
│  └─────────────────────────────────────────────────────────────────────────────────────┘│
│                                              ↓                                           │
│  Step 3: 解析模块依赖                                                                    │
│  ┌─────────────────────────────────────────────────────────────────────────────────────┐│
│  │  • 从 "java.base" 开始                                                               ││
│  │  • 解析 requires 声明                                                                ││
│  │  • 构建模块依赖图                                                                    ││
│  └─────────────────────────────────────────────────────────────────────────────────────┘│
│                                              ↓                                           │
│  Step 4: 创建 Configuration                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────────────────┐│
│  │  • 验证模块图的一致性                                                                ││
│  │  • 检查 exports/opens 声明                                                           ││
│  │  • 检查 provides/uses 声明                                                           ││
│  └─────────────────────────────────────────────────────────────────────────────────────┘│
│                                              ↓                                           │
│  Step 5: 创建 boot Layer                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────────────────┐│
│  │  • 创建模块层 (ModuleLayer)                                                          ││
│  │  • 每个模块关联到对应的 ClassLoader                                                  ││
│  │  • java.* 模块 → BootstrapClassLoader (null)                                        ││
│  │  • jdk.* 模块  → PlatformClassLoader                                                ││
│  │  • 应用模块     → AppClassLoader                                                     ││
│  └─────────────────────────────────────────────────────────────────────────────────────┘│
│                                                                                          │
│  【完成后】-Xbootclasspath/a 中的类可以被加载了                                          │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 🔍 Phase 3: initPhase3() 详解

### 源码分析

```java
// 文件: src/java.base/share/classes/java/lang/System.java:2042
private static void initPhase3() {
    // ═══════════════════════════════════════════════════════════════════════
    // Step 1: 设置 SecurityManager (如果配置了)
    // ═══════════════════════════════════════════════════════════════════════
    String cn = System.getProperty("java.security.manager");
    if (cn != null) {
        if (cn.isEmpty() || "default".equals(cn)) {
            // 使用默认的 SecurityManager
            System.setSecurityManager(new SecurityManager());
        } else {
            // 加载自定义的 SecurityManager
            // 注意：此时 AppClassLoader 还没初始化，使用 BuiltinAppClassLoader
            Class<?> c = Class.forName(cn, false, ClassLoader.getBuiltinAppClassLoader());
            Constructor<?> ctor = c.getConstructor();
            ctor.setAccessible(true);  // 可能是非导出包中的类
            SecurityManager sm = (SecurityManager) ctor.newInstance();
            System.setSecurityManager(sm);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Step 2: 设置初始化级别为 3 (系统类加载器初始化中)
    // ═══════════════════════════════════════════════════════════════════════
    VM.initLevel(3);  // SYSTEM_LOADER_INITIALIZING

    // ═══════════════════════════════════════════════════════════════════════
    // Step 3: 初始化系统类加载器 ⭐⭐⭐⭐⭐
    // ═══════════════════════════════════════════════════════════════════════
    ClassLoader scl = ClassLoader.initSystemClassLoader();

    // ═══════════════════════════════════════════════════════════════════════
    // Step 4: 设置线程上下文类加载器 (TCCL)
    // ═══════════════════════════════════════════════════════════════════════
    // 主线程的 TCCL 设置为系统类加载器
    Thread.currentThread().setContextClassLoader(scl);

    // ═══════════════════════════════════════════════════════════════════════
    // Step 5: 设置初始化级别为 4 (VM 完全启动)
    // ═══════════════════════════════════════════════════════════════════════
    VM.initLevel(4);  // SYSTEM_BOOTED
}
```

### 系统类加载器初始化

```java
// 文件: src/java.base/share/classes/java/lang/ClassLoader.java:1958
static synchronized ClassLoader initSystemClassLoader() {
    // 必须在 initLevel = 3 时调用
    if (VM.initLevel() != 3) {
        throw new InternalError("system class loader cannot be set at initLevel " +
                                VM.initLevel());
    }

    // 获取内置的 AppClassLoader
    ClassLoader builtinLoader = getBuiltinAppClassLoader();

    // 检查是否配置了自定义系统类加载器
    String cn = System.getProperty("java.system.class.loader");
    if (cn != null) {
        // 加载自定义类加载器
        // 要求：public 类，有一个接受 ClassLoader 参数的构造函数
        Constructor<?> ctor = Class.forName(cn, false, builtinLoader)
                                   .getDeclaredConstructor(ClassLoader.class);
        // 创建实例，parent = builtinLoader
        scl = (ClassLoader) ctor.newInstance(builtinLoader);
    } else {
        // 使用内置的 AppClassLoader
        scl = builtinLoader;
    }
    
    return scl;
}
```

### 类加载器层次结构

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                        initPhase3 完成后的类加载器层次结构                                │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│  ┌───────────────────────────────────────────────────────────────────────────────────┐  │
│  │  Bootstrap ClassLoader (null)                                                      │  │
│  │  ├── 由 JVM C++ 实现，在 Java 中表示为 null                                        │  │
│  │  ├── 加载 java.base 等核心模块                                                     │  │
│  │  └── 搜索路径: $JAVA_HOME/lib/modules 中的 java.* 模块                            │  │
│  └───────────────────────────────────────────────────────────────────────────────────┘  │
│                                              │                                           │
│                                              │ parent                                    │
│                                              ↓                                           │
│  ┌───────────────────────────────────────────────────────────────────────────────────┐  │
│  │  Platform ClassLoader (原 ExtClassLoader)                                          │  │
│  │  ├── jdk.internal.loader.ClassLoaders$PlatformClassLoader                         │  │
│  │  ├── 加载 jdk.* 平台模块                                                           │  │
│  │  └── 可加载 -Xbootclasspath/a 中的类                                              │  │
│  └───────────────────────────────────────────────────────────────────────────────────┘  │
│                                              │                                           │
│                                              │ parent                                    │
│                                              ↓                                           │
│  ┌───────────────────────────────────────────────────────────────────────────────────┐  │
│  │  App ClassLoader (原 AppClassLoader / System ClassLoader)                          │  │
│  │  ├── jdk.internal.loader.ClassLoaders$AppClassLoader                              │  │
│  │  ├── 加载应用类 (-classpath / --module-path)                                       │  │
│  │  ├── ClassLoader.getSystemClassLoader() 返回此实例                                 │  │
│  │  └── 主线程的 TCCL 设置为此实例                                                    │  │
│  └───────────────────────────────────────────────────────────────────────────────────┘  │
│                                              │                                           │
│                                              │ parent (用户自定义类加载器)               │
│                                              ↓                                           │
│  ┌───────────────────────────────────────────────────────────────────────────────────┐  │
│  │  User ClassLoader (可选)                                                           │  │
│  │  ├── 通过 -Djava.system.class.loader=xxx 指定                                     │  │
│  │  └── 必须有 public ClassLoader(ClassLoader parent) 构造函数                        │  │
│  └───────────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 🎯 面试高频问题

### Q1: VM.isBooted() 什么时候返回 true？

**答案**：
```
当 VM.initLevel() >= 4 (SYSTEM_BOOTED) 时返回 true。

时间点：initPhase3() 完成后，具体是：
1. SecurityManager 设置完成
2. 系统类加载器初始化完成
3. 主线程的 TCCL 设置完成
4. VM.initLevel(4) 被调用

在此之前，某些操作会被阻塞或降级处理。例如：
- Finalizer 线程会等待 VM.awaitInitLevel(1) 才开始工作
- 某些服务提供者的加载会检查 VM.isBooted()
```

### Q2: System.out.println() 什么时候可以使用？

**答案**：
```
initPhase1() 完成后（initLevel >= 1）才能使用。

原因：
1. System.out/err/in 在 initPhase1() 中被初始化
2. 初始化过程：
   - FileDescriptor.in/out/err 由 JVM 在启动时设置
   - initPhase1() 将它们包装成 BufferedInputStream/PrintStream
   - 调用 setIn0/setOut0/setErr0 native 方法设置 System.in/out/err

在 initPhase1() 之前：
- System.out 是 null
- 调用会导致 NullPointerException
```

### Q3: 为什么 initPhase2 要在编译器初始化之后执行？

**答案**：
```
因为模块系统初始化会执行大量 Java 代码，需要 JIT 编译优化。

源码注释说明（thread.cpp:3777-3780）：
"Call System.initPhase2 after the compiler initialization and jsr292 
classes get initialized because module initialization runs a lot of java 
code, that for performance reasons, should be compiled."

时间线：
1. 先初始化 JIT 编译器
2. 先初始化 jsr292 (MethodHandle/invokedynamic)
3. 再执行 initPhase2()

这样模块初始化中的热点代码可以被 JIT 编译，提升启动性能。
```

### Q4: 主线程为什么需要手动添加到线程组？

**答案**：
```
因为主线程的创建过程是特殊的，没有走正常的 Thread() 构造函数流程。

正常线程创建：
Thread t = new Thread(group, name);
// 构造函数内部会调用 group.add(this)

主线程创建：
1. JVM 直接分配 Thread 对象内存
2. 手动设置 eetop 和 _threadObj 绑定
3. 调用 Thread.<init>(group, name) 构造函数
4. 但此时 ThreadGroup.add() 还没被调用！

原因分析：
- main 线程在 ThreadGroup 类初始化之前就存在了
- 为了避免循环依赖，创建时跳过了某些步骤

因此 initPhase1() 中需要：
Thread current = Thread.currentThread();
current.getThreadGroup().add(current);  // 补上这一步
```

### Q5: 三个阶段的主要产物是什么？

**答案**：
```
┌──────────────┬────────────────────────────────────────────────┐
│    阶段      │                   主要产物                      │
├──────────────┼────────────────────────────────────────────────┤
│ initPhase1   │ • System Properties 可用                       │
│ (initLevel=1)│ • System.in/out/err 可用                       │
│              │ • 信号处理器已设置                              │
│              │ • SharedSecrets 已注册                          │
├──────────────┼────────────────────────────────────────────────┤
│ initPhase2   │ • 模块系统已初始化                              │
│ (initLevel=2)│ • boot Layer 已创建                            │
│              │ • -Xbootclasspath/a 中的类可加载               │
│              │ • ModuleFinder 可用                             │
├──────────────┼────────────────────────────────────────────────┤
│ initPhase3   │ • SecurityManager 已设置（如果配置）            │
│ (initLevel=4)│ • AppClassLoader 已初始化                      │
│              │ • TCCL 已设置为 AppClassLoader                 │
│              │ • VM.isBooted() = true                         │
│              │ • 应用类可以被加载                              │
└──────────────┴────────────────────────────────────────────────┘
```

---

## 📊 各阶段能做什么的总结

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                           各 initLevel 阶段的能力对比                                    │
├──────────────┬──────────────┬──────────────┬──────────────┬─────────────────────────────┤
│    能力      │  Level 0    │  Level 1    │  Level 2    │  Level 4 (Booted)            │
├──────────────┼──────────────┼──────────────┼──────────────┼─────────────────────────────┤
│ System.out   │      ✗      │      ✓      │      ✓      │      ✓                      │
├──────────────┼──────────────┼──────────────┼──────────────┼─────────────────────────────┤
│ 系统属性     │      ✗      │      ✓      │      ✓      │      ✓                      │
├──────────────┼──────────────┼──────────────┼──────────────┼─────────────────────────────┤
│ 信号处理     │      ✗      │      ✓      │      ✓      │      ✓                      │
├──────────────┼──────────────┼──────────────┼──────────────┼─────────────────────────────┤
│ 模块 API     │      ✗      │      ✗      │      ✓      │      ✓                      │
├──────────────┼──────────────┼──────────────┼──────────────┼─────────────────────────────┤
│ bootpath/a   │      ✗      │      ✗      │      ✓      │      ✓                      │
├──────────────┼──────────────┼──────────────┼──────────────┼─────────────────────────────┤
│ AppClassLoader│     ✗      │      ✗      │      ✗      │      ✓                      │
├──────────────┼──────────────┼──────────────┼──────────────┼─────────────────────────────┤
│ 应用类加载   │      ✗      │      ✗      │      ✗      │      ✓                      │
├──────────────┼──────────────┼──────────────┼──────────────┼─────────────────────────────┤
│SecurityManager│     ✗      │      ✗      │      ✗      │      ✓                      │
└──────────────┴──────────────┴──────────────┴──────────────┴─────────────────────────────┘
```

---

## ✅ 本节小结

| 阶段 | 核心职责 | 完成后标志 | 面试频率 |
|-----|---------|-----------|---------|
| **initPhase1** | 系统属性 + 标准流 | System.out 可用 | ⭐⭐⭐⭐ |
| **initPhase2** | 模块系统 (JPMS) | boot Layer 创建 | ⭐⭐⭐⭐ |
| **initPhase3** | 类加载器 + TCCL | VM.isBooted()=true | ⭐⭐⭐ |

---

## 🔬 GDB 实战验证

### 验证环境

```
【GDB 验证】标准条件：-Xms256m -Xmx256m -XX:+UseG1GC
工作目录：/data/workspace/openjdk-cut-new
测试程序：-cp /data/workspace/demo/src com.wjcoder.Main
```

### 验证脚本

```bash
cd /data/workspace/openjdk-cut-new
gdb -x jvm-md/SystemInit/gdb_system_initphases.txt \
    ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java
```

### 验证结果

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                          System 三阶段初始化 GDB 验证结果                                │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│  ═══════════════════════════════════════════════════════════════════════════════════    │
│  断点 1: call_initPhase1() 触发                                                         │
│  ═══════════════════════════════════════════════════════════════════════════════════    │
│  位置: thread.cpp:3764                                                                   │
│  调用链:                                                                                 │
│    #0 call_initPhase1()                                                                 │
│    #1 Threads::initialize_java_lang_classes()  (thread.cpp:3847)                       │
│    #2 Threads::create_vm()                     (thread.cpp:4130)                       │
│                                                                                          │
│  _init_completed: 0  ← 此时 VM 初始化尚未完成 ✅                                         │
│                                                                                          │
│  ═══════════════════════════════════════════════════════════════════════════════════    │
│  断点 2: set_init_completed() 触发                                                       │
│  ═══════════════════════════════════════════════════════════════════════════════════    │
│  位置: init.cpp:196                                                                      │
│                                                                                          │
│  _init_completed: 0 → 1  ← 标记 VM 初始化完成 ✅                                         │
│                                                                                          │
│  时机分析：                                                                               │
│  • set_init_completed() 在 initPhase1 之后、initPhase2 之前调用                         │
│  • 位于 create_vm() 第 4139 行                                                          │
│                                                                                          │
│  ═══════════════════════════════════════════════════════════════════════════════════    │
│  断点 3: call_initPhase2() 触发                                                         │
│  ═══════════════════════════════════════════════════════════════════════════════════    │
│  位置: thread.cpp:3781                                                                   │
│  调用链:                                                                                 │
│    #0 call_initPhase2()                                                                 │
│    #1 Threads::create_vm()                     (thread.cpp:4212)                       │
│    #2 JNI_CreateJavaVM_inner()                 (jni.cpp:4010)                          │
│                                                                                          │
│  _init_completed: 1  ← 此时 VM 已标记为初始化完成 ✅                                     │
│                                                                                          │
│  ═══════════════════════════════════════════════════════════════════════════════════    │
│  断点 4: call_initPhase3() 触发                                                         │
│  ═══════════════════════════════════════════════════════════════════════════════════    │
│  位置: thread.cpp:3806                                                                   │
│  调用链:                                                                                 │
│    #0 call_initPhase3()                                                                 │
│    #1 Threads::create_vm()                     (thread.cpp:4224)                       │
│    #2 JNI_CreateJavaVM_inner()                 (jni.cpp:4010)                          │
│    #3 JNI_CreateJavaVM()                       (jni.cpp:4115)                          │
│    #4 InitializeJVM()                          (java.c:1626)                           │
│                                                                                          │
│  _init_completed: 1  ← 保持不变 ✅                                                       │
│                                                                                          │
│  ═══════════════════════════════════════════════════════════════════════════════════    │
│  最终结果: hello jvm                                                                     │
│  ═══════════════════════════════════════════════════════════════════════════════════    │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

### 关键发现

| 时间点 | 事件 | `_init_completed` | 说明 |
|-------|------|-------------------|------|
| T1 | call_initPhase1() | 0 | 系统属性/标准流初始化开始 |
| T2 | set_init_completed() | 0 → 1 | VM 核心初始化完成标记 |
| T3 | call_initPhase2() | 1 | 模块系统初始化 |
| T4 | call_initPhase3() | 1 | 类加载器初始化 |
| T5 | main() 执行 | 1 | 应用程序运行 |

### 调用顺序验证

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Threads::create_vm() 中的三阶段调用顺序                                  │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  thread.cpp:4130  │  Threads::initialize_java_lang_classes()            │
│                   │      └── call_initPhase1()                          │
│                   │                                                      │
│  thread.cpp:4139  │  set_init_completed()  ← _init_completed = true     │
│                   │                                                      │
│  thread.cpp:4212  │  call_initPhase2()                                  │
│                   │                                                      │
│  thread.cpp:4224  │  call_initPhase3()                                  │
│                   │                                                      │
└──────────────────────────────────────────────────────────────────────────┘
```

### 验证结论

1. **三阶段调用顺序正确**：initPhase1 → initPhase2 → initPhase3 ✅
2. **_init_completed 设置时机**：在 initPhase1 之后、initPhase2 之前 ✅
3. **调用栈一致**：均由 `Threads::create_vm()` 统一调度 ✅
4. **应用程序输出**：`hello jvm` 正常打印，证明初始化完成 ✅

---

**下一步建议**: 继续学习 **6.5 异常类预初始化** (理解 OOM 时如何抛异常) ？ 🚀
