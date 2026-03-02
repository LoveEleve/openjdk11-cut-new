
# Ch 1.3 ArthasBootstrap 服务启动

> 源文件:
> - `core/server/ArthasBootstrap.java` (703行) — 核心服务启动器
> - `core/shell/impl/ShellServerImpl.java` (263行) — Shell 服务器实现
> - `core/command/BuiltinCommandPack.java` (126行) — 内置命令注册
> - `core/shell/ShellServerOptions.java` (126行) — Shell 服务选项
> - `core/shell/term/impl/httptelnet/HttpTelnetTermServer.java` (93行) — Telnet+HTTP 复合端口
> - `core/shell/term/impl/HttpTermServer.java` (89行) — HTTP WebSocket 端口
> - `core/advisor/TransformerManager.java` (97行) — 字节码转换管理器
> - `core/security/SecurityAuthenticatorImpl.java` (100行) — 安全认证
> - `tunnel-client/TunnelClient.java` — Tunnel 客户端

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **Ch 1.3 ArthasBootstrap 服务启动**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 1. 先回答"为什么"

### 1.1 ArthasBootstrap 要解决什么问题？

上一节分析了 `AgentBootstrap.agentmain()` 如何创建 ArthasClassloader 并通过反射调用 `ArthasBootstrap.getInstance()`。现在进入目标 JVM 内部的**真正核心**——ArthasBootstrap 需要在目标 JVM 中建立一个**完整的诊断服务基础设施**：

| 需求 | 解决方案 |
|------|---------|
| 用户需要通过 Telnet/浏览器连接 | 启动 Netty 监听端口 |
| 用户需要输入命令 | 建立 Shell 交互框架 |
| 命令需要识别和执行 | 注册 46+ 内置命令 |
| watch/trace 需要修改字节码 | 初始化 TransformerManager |
| SpyAPI 需要可用 | 将 spy.jar 加入 BootstrapCL |
| 叛逆 ClassLoader 找不到 SpyAPI | 增强 ClassLoader.loadClass() |
| 远程连接需求 | 启动 TunnelClient |
| 配置参数需要管理 | ArthasEnvironment 多源配置 |
| 安全性保障 | SecurityAuthenticator 认证 |

### 1.2 ArthasBootstrap 在整体架构中的位置

```
AgentBootstrap.agentmain(args, inst)
    └→ bind(inst, agentLoader, agentArgs)           ← 上一节
        └→ ArthasBootstrap.getInstance(inst, args)  ← 本节
            │
            ├── 构造函数: 6 步初始化
            │   ├── Step 0: initFastjson()
            │   ├── Step 1: initSpy()           [Ch 1.2 已分析]
            │   ├── Step 2: initArthasEnvironment()
            │   ├── Step 3: initLogger()
            │   ├── Step 4: enhanceClassLoader() [Ch 1.2 已分析]
            │   ├── Step 5: initBeans()
            │   └── Step 6: bind(configure)     ← 本节重点
            │
            └── 后置初始化
                ├── executorService (命令执行线程池)
                ├── TransformerManager (字节码转换管理)
                └── shutdownHook (优雅关闭)
```

---

## 2. getInstance() — 单例 + 参数预处理

```java
public synchronized static ArthasBootstrap getInstance(Instrumentation instrumentation, String args) 
        throws Throwable {
    if (arthasBootstrap != null) {
        return arthasBootstrap;  // 单例：只初始化一次
    }
    // 参数字符串解析为 Map
    Map<String, String> argsMap = FeatureCodec.DEFAULT_COMMANDLINE_CODEC.toMap(args);
    // 给所有配置项加 "arthas." 前缀
    Map<String, String> mapWithPrefix = new HashMap<>(argsMap.size());
    for (Entry<String, String> entry : argsMap.entrySet()) {
        mapWithPrefix.put("arthas." + entry.getKey(), entry.getValue());
    }
    return getInstance(instrumentation, mapWithPrefix);
}
```

参数流转过程：

```
Arthas.java 拼装:
  "arthas-core.jar;telnetPort=3658;httpPort=8563;ip=127.0.0.1;..."
                    ↓
AgentBootstrap 提取 ";" 后面:
  "telnetPort=3658;httpPort=8563;ip=127.0.0.1;..."
                    ↓
FeatureCodec.toMap():
  {"telnetPort":"3658", "httpPort":"8563", "ip":"127.0.0.1", ...}
                    ↓
加 "arthas." 前缀:
  {"arthas.telnetPort":"3658", "arthas.httpPort":"8563", "arthas.ip":"127.0.0.1", ...}
                    ↓
传入 ArthasBootstrap 构造函数
```

**为什么要加 `arthas.` 前缀？**

因为 `ArthasEnvironment` 支持多数据源（命令行、System Properties、System Env、arthas.properties），加前缀可以避免与目标应用的 System Properties 冲突。比如 `telnetPort` 可能和其他框架冲突，但 `arthas.telnetPort` 就不会。

---

## 3. 构造函数 6 步初始化

```java
private ArthasBootstrap(Instrumentation instrumentation, Map<String, String> args) throws Throwable {
    this.instrumentation = instrumentation;

    initFastjson();              // Step 0: JSON 配置
    initSpy();                   // Step 1: SpyAPI → BootstrapCL [已分析]
    initArthasEnvironment(args); // Step 2: 配置环境
    // outputPath 创建
    loggerContext = LogUtil.initLogger(arthasEnvironment); // Step 3: 日志
    enhanceClassLoader();        // Step 4: 增强 ClassLoader [已分析]
    initBeans();                 // Step 5: Bean 初始化
    bind(configure);             // Step 6: 启动服务 [本节重点]
    
    // 后置初始化
    executorService = Executors.newScheduledThreadPool(1, ...);
    transformerManager = new TransformerManager(instrumentation);
    Runtime.getRuntime().addShutdownHook(shutdown);
}
```

### 3.1 Step 0: initFastjson()

```java
private void initFastjson() {
    JSON.config(JSONWriter.Feature.IgnoreErrorGetter, JSONWriter.Feature.WriteNonStringKeyAsString);
}
```

两个配置项解决的实际问题：
- **IgnoreErrorGetter**：目标应用的某些对象 getter 可能抛异常（如懒加载未初始化），序列化时忽略而不是报错。这是 GitHub Issue #1661 的修复。
- **WriteNonStringKeyAsString**：Map 的 key 可能是非 String 类型（如 Integer），强制转为 String 避免 JSON 格式错误。

### 3.2 Step 2: initArthasEnvironment() — 多源配置体系

```java
private void initArthasEnvironment(Map<String, String> argsMap) throws IOException {
    arthasEnvironment = new ArthasEnvironment();
    
    MapPropertySource mapPropertySource = new MapPropertySource("args", copyMap);
    arthasEnvironment.addFirst(mapPropertySource);  // 命令行参数放在最前面（最高优先级）
    
    tryToLoadArthasProperties();  // 尝试加载 arthas.properties
    
    configure = new Configure();
    BinderUtils.inject(arthasEnvironment, configure);  // 注入到 Configure 对象
}
```

**配置优先级**（从高到低）：

```
┌──────────────────────────────────────────────────────────┐
│  优先级 1: 命令行参数 (args)                              │
│    arthas.telnetPort=3658, arthas.httpPort=8563, ...     │
├──────────────────────────────────────────────────────────┤
│  优先级 2: System Environment (systemEnvironment)        │
│    ARTHAS_TELNET_PORT=3658, ...                          │
├──────────────────────────────────────────────────────────┤
│  优先级 3: System Properties (systemProperties)          │
│    -Darthas.telnetPort=3658                              │
├──────────────────────────────────────────────────────────┤
│  优先级 4: arthas.properties 文件                         │
│    ${arthasHome}/arthas.properties                       │
│    (可通过 arthas.config.overrideAll=true 提升到最高)     │
└──────────────────────────────────────────────────────────┘
```

`ArthasEnvironment` 的设计借鉴了 **Spring Environment**（PropertySources 有序列表 + PropertyResolver 占位符解析），但做了大幅简化——只保留了核心的属性查找和占位符替换能力。

**arthas.properties 的特殊机制**：`arthas.config.overrideAll=true` 可以让配置文件的优先级提升到最高（`addFirst`），这在运维场景中很有用——通过修改配置文件覆盖所有默认值，而不需要修改启动脚本。

### 3.3 Configure 对象 — 核心配置容器

`BinderUtils.inject()` 将 ArthasEnvironment 中的属性注入到 `Configure` 对象中。Configure 的关键字段：

| 字段 | 默认值 | 作用 |
|------|--------|------|
| `ip` | 127.0.0.1 | 监听 IP |
| `telnetPort` | 3658 | Telnet 端口（Telnet + WebSocket 复合） |
| `httpPort` | 8563 | HTTP 端口（Web Console + HTTP API） |
| `javaPid` | 当前进程 | 目标 Java 进程 PID |
| `sessionTimeout` | 1800 (30min) | Session 超时秒数 |
| `tunnelServer` | null | Tunnel Server 地址 |
| `agentId` | null | Agent ID（Tunnel 中标识自己） |
| `username` | null | 认证用户名 |
| `password` | null | 认证密码 |
| `enhanceLoaders` | "java.lang.ClassLoader" | 需要增强的 ClassLoader |
| `disabledCommands` | null | 禁用的命令列表 |
| `mcpEndpoint` | null | MCP Server 端点（4.x 新增） |
| `localConnectionNonAuth` | true | 本地连接免认证 |

### 3.4 Step 5: initBeans()

```java
private void initBeans() {
    this.resultViewResolver = new ResultViewResolver();
    this.historyManager = new HistoryManagerImpl();
}
```

两个简单但重要的对象：
- **ResultViewResolver**：命令结果到文本的渲染器。每个命令产出一个 `ResultModel`，由对应的 `ResultView` 渲染为文本输出。这是 **Model-View 分离**的关键（后续 Part 4 详细分析）。
- **HistoryManagerImpl**：命令历史管理，支持 `history` 命令和方向键回溯。

---

## 4. bind() — 服务启动的核心（重点）

`bind()` 方法是 ArthasBootstrap 中最长也最重要的方法（约 150 行），它完成了从"初始化完毕"到"对外提供服务"的跨越。让我们逐段分析：

### 4.1 幂等保护 + 随机端口

```java
private void bind(Configure configure) throws Throwable {
    long start = System.currentTimeMillis();
    
    // CAS 保护：只能 bind 一次
    if (!isBindRef.compareAndSet(false, true)) {
        throw new IllegalStateException("already bind");
    }
    
    // 端口为 0 时分配随机可用端口
    if (configure.getTelnetPort() != null && configure.getTelnetPort() == 0) {
        int newTelnetPort = SocketUtils.findAvailableTcpPort();
        configure.setTelnetPort(newTelnetPort);
    }
    // httpPort 同理...
```

**为什么支持随机端口？**

在容器化环境（Docker/K8s）中，多个 Arthas 实例可能运行在同一台机器上，固定端口容易冲突。设置端口为 0 让 Arthas 自动选择可用端口，配合 Tunnel Server 就可以实现无端口冲突的远程管理。

### 4.2 TunnelClient 启动

```java
try {
    if (configure.getTunnelServer() != null) {
        tunnelClient = new TunnelClient();
        tunnelClient.setAppName(configure.getAppName());
        tunnelClient.setId(configure.getAgentId());
        tunnelClient.setTunnelServerUrl(configure.getTunnelServer());
        tunnelClient.setVersion(ArthasBanner.version());
        ChannelFuture channelFuture = tunnelClient.start();
        channelFuture.await(10, TimeUnit.SECONDS);  // 等待最多 10 秒
    }
} catch (Throwable t) {
    logger().error("start tunnel client error", t);
    // 注意：Tunnel 连接失败不影响本地服务启动
}
```

**TunnelClient 的作用**：

```
┌──────────────────────┐         ┌──────────────────┐         ┌─────────────┐
│  远程浏览器/客户端     │ ──────→ │  Tunnel Server    │ ──────→ │  目标 JVM    │
│  (可能在不同网络)      │  HTTP   │  (公网代理)       │ WebSocket│  TunnelClient│
└──────────────────────┘         └──────────────────┘         └─────────────┘
```

TunnelClient 主动向 TunnelServer 建立 WebSocket 长连接，注册自己的 agentId。远程用户通过 Tunnel Server 的 Web Console，指定 agentId 就可以连接到任意目标 JVM——即使目标 JVM 在防火墙后面、只有出网能力。

TunnelClient 的 `start()` 方法内部使用 Netty 的 `Bootstrap.connect()` 建立连接，并支持自动重连（`reconnectDelay` 默认 5 秒）。

### 4.3 安全认证

```java
this.httpSessionManager = new HttpSessionManager();

if (IPUtils.isAllZeroIP(configure.getIp()) && StringUtils.isBlank(configure.getPassword())) {
    // 监听 0.0.0.0 + 无密码 = 极度危险！
    AnsiLog.error("Listening on 0.0.0.0 is very dangerous! ...");
    configure.setPassword(StringUtils.randomString(64));  // 自动生成 64 位密码
    AnsiLog.error("Generated arthas password: " + configure.getPassword());
}

this.securityAuthenticator = new SecurityAuthenticatorImpl(configure.getUsername(), configure.getPassword());
```

**安全设计**：

| 场景 | 行为 |
|------|------|
| 默认（127.0.0.1 + 无密码） | 无需认证，只有本机能连 |
| 0.0.0.0 + 无密码 | **强制生成随机密码**，打印到控制台和日志 |
| 配置了 username + password | 需要 `auth` 命令认证 |
| 只配了 password | username 默认为 "arthas" |
| 只配了 username | **自动生成随机密码** |

`SecurityAuthenticatorImpl` 支持三种认证方式：
1. **BasicPrincipal**：用户名 + 密码（Telnet `auth` 命令）
2. **BearerPrincipal**：Token 认证（HTTP API 的 `Authorization: Bearer` header）
3. **LocalConnectionPrincipal**：本地连接免认证（当 `localConnectionNonAuth=true`）

### 4.4 ShellServer 创建 + 命令注册

```java
ShellServerOptions options = new ShellServerOptions()
    .setInstrumentation(instrumentation)
    .setPid(PidUtils.currentLongPid())
    .setWelcomeMessage(ArthasBanner.welcome());
if (configure.getSessionTimeout() != null) {
    options.setSessionTimeout(configure.getSessionTimeout() * 1000); // 秒→毫秒
}

shellServer = new ShellServerImpl(options);
```

**ShellServerOptions 默认值**：

| 选项 | 默认值 | 作用 |
|------|--------|------|
| `sessionTimeout` | 30 分钟 | 无操作 Session 超时时间 |
| `reaperInterval` | 60 秒 | Session 清理器检查间隔 |
| `connectionTimeout` | 6 秒 | TermServer 启动超时 |
| `welcomeMessage` | Arthas Logo + 版本信息 | 连接时展示的欢迎消息 |

#### ShellServerImpl 内部结构

```java
public ShellServerImpl(ShellServerOptions options) {
    this.termServers = new ArrayList<TermServer>();        // 注册的 TermServer
    this.sessions = new ConcurrentHashMap<>();             // 活跃的 Shell Session
    this.resolvers = new CopyOnWriteArrayList<>();         // 命令解析器列表
    this.commandManager = new InternalCommandManager(resolvers); // 命令管理器
    this.jobController = new GlobalJobControllerImpl();     // 全局 Job 控制器
    
    resolvers.add(new BuiltinCommandResolver());           // 注册内建命令
}
```

**两层命令解析器**：

```
┌─────────────────────────────────────────────────┐
│  resolvers (CopyOnWriteArrayList)                │
│                                                  │
│  [0] BuiltinCommandPack  ← 46个用户命令          │
│       HelpCommand, WatchCommand, TraceCommand...  │
│                                                  │
│  [1] BuiltinCommandResolver ← 9个内建命令        │
│       exit, quit, jobs, fg, bg, kill,            │
│       plaintext, grep, wc                        │
└─────────────────────────────────────────────────┘
```

注意 `BuiltinCommandPack` 通过 `registerCommandResolver` 被插入到 `[0]` 位置（`resolvers.add(0, resolver)`），优先级高于内建命令。

#### BuiltinCommandPack — 46个用户命令

```java
private void initCommands(List<String> disabledCommands) {
    List<Class<? extends AnnotatedCommand>> commandClassList = new ArrayList<>(33);
    commandClassList.add(HelpCommand.class);      // help
    commandClassList.add(AuthCommand.class);       // auth（认证）
    commandClassList.add(SearchClassCommand.class); // sc
    commandClassList.add(SearchMethodCommand.class);// sm
    commandClassList.add(ClassLoaderCommand.class); // classloader
    commandClassList.add(JadCommand.class);         // jad（反编译）
    commandClassList.add(MonitorCommand.class);     // monitor
    commandClassList.add(StackCommand.class);       // stack
    commandClassList.add(ThreadCommand.class);      // thread
    commandClassList.add(TraceCommand.class);       // trace
    commandClassList.add(WatchCommand.class);       // watch
    commandClassList.add(TimeTunnelCommand.class);  // tt
    commandClassList.add(OgnlCommand.class);        // ognl
    commandClassList.add(RedefineCommand.class);    // redefine
    commandClassList.add(RetransformCommand.class); // retransform
    commandClassList.add(DashboardCommand.class);   // dashboard
    commandClassList.add(ProfilerCommand.class);    // profiler
    commandClassList.add(VmToolCommand.class);      // vmtool
    commandClassList.add(StopCommand.class);        // stop
    // ... 共 46 个
    
    // JFR 命令需要 JDK 11+ 才注册
    if (ClassLoader.getSystemClassLoader().getResource("jdk/jfr/Recording.class") != null) {
        commandClassList.add(JFRCommand.class);
    }
    
    // 过滤掉被禁用的命令
    for (Class<? extends AnnotatedCommand> clazz : commandClassList) {
        Name name = clazz.getAnnotation(Name.class);
        if (name != null && disabledCommands.contains(name.value())) {
            continue;  // 跳过被禁用的命令
        }
        commands.add(Command.create(clazz));  // 反射创建命令对象
    }
}
```

**命令分类体系**（按包名的数字后缀）：

| 包名 | 数字含义 | 命令类型 | 示例 |
|------|---------|---------|------|
| `basic1000` | 优先级 1000（最低） | 基础工具命令 | help, cat, grep, pwd, echo, history, options, reset, stop |
| `klass100` | 优先级 100（中等） | 类操作命令 | sc, sm, jad, dump, redefine, retransform, ognl, classloader |
| `monitor200` | 优先级 200（高） | 监控增强命令 | watch, trace, monitor, stack, tt, dashboard, thread, profiler, vmtool |
| `logger` | — | 日志命令 | logger |
| `hidden` | — | 隐藏命令 | july, thanks |

#### BuiltinCommandResolver — 9个内建命令

这些命令不通过 `AnnotatedCommand` 注解定义，而是直接通过 `CommandBuilder` 构建：

```java
class BuiltinCommandResolver implements CommandResolver {
    public List<Command> commands() {
        return Arrays.asList(
            CommandBuilder.command("exit").processHandler(handler).build(),
            CommandBuilder.command("quit").processHandler(handler).build(),
            CommandBuilder.command("jobs").processHandler(handler).build(),
            CommandBuilder.command("fg").processHandler(handler).build(),
            CommandBuilder.command("bg").processHandler(handler).build(),
            CommandBuilder.command("kill").processHandler(handler).build(),
            CommandBuilder.command(PlainTextHandler.NAME).processHandler(handler).build(), // plaintext
            CommandBuilder.command(GrepHandler.NAME).processHandler(handler).build(),      // grep
            CommandBuilder.command(WordCountHandler.NAME).processHandler(handler).build()   // wc
        );
    }
}
```

这些内建命令的 `processHandler` 都是 `NoOpHandler`（空实现），因为它们在 Shell 的 `ShellLineHandler` 中被**提前拦截处理**，不走标准的命令执行流程。特别是 `grep`、`plaintext`、`wc` 是**管道命令**，作为命令链的后处理器使用。

### 4.5 Netty 网络层启动

```java
// 创建 Netty worker 线程组
workerGroup = new NioEventLoopGroup(new DefaultThreadFactory("arthas-TermServer", true));

// 端口 3658: Telnet + HTTP + WebSocket 复合服务
if (configure.getTelnetPort() != null && configure.getTelnetPort() > 0) {
    shellServer.registerTermServer(new HttpTelnetTermServer(
        configure.getIp(), configure.getTelnetPort(),
        options.getConnectionTimeout(), workerGroup, httpSessionManager));
}

// 端口 8563: 纯 HTTP + WebSocket 服务
if (configure.getHttpPort() != null && configure.getHttpPort() > 0) {
    shellServer.registerTermServer(new HttpTermServer(
        configure.getIp(), configure.getHttpPort(),
        options.getConnectionTimeout(), workerGroup, httpSessionManager));
}
```

**两个端口的分工**：

```
端口 3658 (HttpTelnetTermServer)          端口 8563 (HttpTermServer)
┌──────────────────────────────┐         ┌──────────────────────────┐
│  同时支持:                    │         │  只支持:                  │
│  ✓ Telnet 协议（CLI 客户端）  │         │  ✓ HTTP API              │
│  ✓ HTTP 协议（Web Console）   │         │  ✓ WebSocket（Web Console）│
│  ✓ WebSocket（Web Console）   │         │                          │
│                              │         │  用途：                   │
│  实现方式：                   │         │  纯 HTTP/WS 服务         │
│  Netty Pipeline 自动检测     │         │  适合作为 API 端点         │
│  第一个字节是不是 HTTP 请求   │         │                          │
│  来决定走 Telnet 还是 HTTP   │         │                          │
└──────────────────────────────┘         └──────────────────────────┘
```

**HttpTelnetTermServer 的协议自动检测**：

这是一个有趣的设计——端口 3658 同时支持 Telnet 和 HTTP 两种协议。实现方式是通过 Netty Pipeline 中的 **协议检测器**：读取连接的第一个字节，如果是 HTTP 请求的特征（如 "G" for GET, "P" for POST），则走 HTTP pipeline；否则走 Telnet pipeline。这样用户既可以用 `telnet 127.0.0.1 3658` 连接，也可以用浏览器打开 `http://127.0.0.1:3658`。

#### TermServer 的启动流程

```java
// ShellServerImpl.listen()
public ShellServer listen(final Handler<Future<Void>> listenHandler) {
    AtomicInteger count = new AtomicInteger(toStart.size());  // 计数器
    Handler<Future<TermServer>> handler = new TermServerListenHandler(this, listenHandler, toStart);
    
    for (TermServer termServer : toStart) {
        termServer.termHandler(new TermServerTermHandler(this));  // 连接回调
        termServer.listen(handler);                                // 启动监听
    }
}
```

`TermServerListenHandler` 用 `AtomicInteger` 计数器实现了**等待所有 TermServer 都启动成功**的逻辑：

```java
// TermServerListenHandler.handle()
public void handle(Future<TermServer> ar) {
    if (ar.failed()) {
        failed.set(true);
    }
    if (count.decrementAndGet() == 0) {  // 所有 TermServer 都回调了
        if (failed.get()) {
            listenHandler.handle(Future.failedFuture(ar.cause()));
            for (TermServer termServer : toStart) {
                termServer.close();  // 一个失败则全部关闭
            }
        } else {
            shellServer.setClosed(false);  // 标记服务已启动
            shellServer.setTimer();        // 启动 Session 清理定时器
            listenHandler.handle(Future.succeededFuture());
        }
    }
}
```

**关键设计**：如果任意一个 TermServer 启动失败（比如端口被占用），**所有 TermServer 都会关闭**，不允许"部分启动"。

### 4.6 新连接到达时的处理

当一个 Telnet 或 WebSocket 连接到达时，通过 `TermServerTermHandler` 回调到 `ShellServerImpl.handleTerm()`：

```java
public void handleTerm(Term term) {
    // 1. 创建 ShellImpl（一个 Session）
    ShellImpl session = createShell(term);
    
    // 2. 设置欢迎消息（包含 Tunnel ID 如果有的话）
    tryUpdateWelcomeMessage();
    session.setWelcome(welcomeMessage);
    
    // 3. 注册关闭回调
    session.closedFuture.setHandler(new SessionClosedHandler(this, session));
    
    // 4. 初始化 Session（设置信号处理器等）
    session.init();
    
    // 5. 注册到 sessions Map
    sessions.put(session.id, session);
    
    // 6. 开始读取用户输入
    session.readline();
}
```

这里的关键是 **Session = Shell + Term + JobController**：

```
┌────────────────────────────────────────────────────┐
│  ShellImpl (一个用户连接)                            │
│                                                     │
│  Term (终端抽象)                                    │
│  ├── 输入：readline()                               │
│  └── 输出：write()                                  │
│                                                     │
│  InternalCommandManager (命令查找)                   │
│  ├── BuiltinCommandPack (46 个用户命令)              │
│  └── BuiltinCommandResolver (9 个内建命令)           │
│                                                     │
│  JobController (任务管理)                            │
│  ├── 前台 Job：当前正在执行的命令                     │
│  └── 后台 Job：通过 & 或 Ctrl+Z 放入后台的命令       │
│                                                     │
│  Instrumentation (字节码操作权限)                    │
│  pid (目标进程 ID)                                   │
└────────────────────────────────────────────────────┘
```

### 4.7 SessionManager + HttpApiHandler

```java
// HTTP API 会话管理器（与 Shell Session 独立）
sessionManager = new SessionManagerImpl(options, shellServer.getCommandManager(), 
                                        shellServer.getJobController());
// HTTP API 处理器
httpApiHandler = new HttpApiHandler(historyManager, sessionManager);
```

Arthas 有**两套 Session 管理**：

| 会话类型 | 管理器 | 用途 | 生命周期 |
|---------|--------|------|---------|
| Shell Session | `ShellServerImpl.sessions` | Telnet/WebSocket 交互连接 | 连接断开或超时 |
| HTTP API Session | `SessionManagerImpl.sessions` | REST API 调用 | 主动关闭或超时 |

`HttpApiHandler` 处理来自 `http://host:8563/api` 的 HTTP REST 请求，支持以下 API：

```
POST /api
{
    "action": "exec",
    "command": "watch com.example.MyService doSomething",
    "sessionId": "xxx"
}
```

### 4.8 MCP Server（4.x 新增）

```java
String mcpEndpoint = configure.getMcpEndpoint();
if (mcpEndpoint != null && !mcpEndpoint.trim().isEmpty()) {
    CommandExecutor commandExecutor = new CommandExecutorImpl(sessionManager);
    ArthasMcpBootstrap arthasMcpBootstrap = new ArthasMcpBootstrap(commandExecutor, mcpEndpoint);
    this.mcpRequestHandler = arthasMcpBootstrap.start().getMcpRequestHandler();
}
```

**MCP (Model Context Protocol)** 是 Arthas 4.x 新增的能力，允许 AI 工具（如 Cursor、Claude）通过 MCP 协议直接调用 Arthas 命令。这是 Arthas 向 AI 辅助诊断方向的探索。

### 4.9 SpyAPI.init() — 最后一步

```java
try {
    SpyAPI.init();
} catch (Throwable e) {
    // ignore
}
logger().info("as-server started in {} ms", System.currentTimeMillis() - start);
```

`SpyAPI.init()` 设置 `INITED = true`，标志着 Arthas 完全启动。回顾 Ch 1.2 中分析的幂等保护——只有这一步执行后，下次 `AgentBootstrap.agentmain()` 才会被拦截。

**时机设计的精妙之处**：`SpyAPI.init()` 放在 `bind()` 的最后一步（而不是 `initSpy()` 中），确保只有 Shell Server 完全启动、端口绑定成功后，才标记为"已初始化"。如果启动过程中端口绑定失败，`INITED` 仍然是 false，下次 attach 可以重试。

---

## 5. 后置初始化

### 5.1 TransformerManager — 字节码转换中枢

```java
transformerManager = new TransformerManager(instrumentation);
```

TransformerManager 是 Arthas 字节码增强的**中枢管理器**。它在构造函数中向 JVM 注册了一个**聚合 Transformer**：

```java
public TransformerManager(Instrumentation instrumentation) {
    this.instrumentation = instrumentation;
    
    classFileTransformer = new ClassFileTransformer() {
        @Override
        public byte[] transform(ClassLoader loader, String className, 
                Class<?> classBeingRedefined, ProtectionDomain protectionDomain,
                byte[] classfileBuffer) throws IllegalClassFormatException {
            // 1. 先执行 reTransformers（retransform 命令的 Transformer）
            for (ClassFileTransformer tf : reTransformers) {
                byte[] result = tf.transform(..., classfileBuffer);
                if (result != null) classfileBuffer = result;
            }
            // 2. 再执行 watchTransformers（watch/monitor/stack/tt 命令的 Transformer）
            for (ClassFileTransformer tf : watchTransformers) {
                byte[] result = tf.transform(..., classfileBuffer);
                if (result != null) classfileBuffer = result;
            }
            // 3. 最后执行 traceTransformers（trace 命令的 Transformer）
            for (ClassFileTransformer tf : traceTransformers) {
                byte[] result = tf.transform(..., classfileBuffer);
                if (result != null) classfileBuffer = result;
            }
            return classfileBuffer;
        }
    };
    instrumentation.addTransformer(classFileTransformer, true);  // true = 支持 retransform
}
```

**三层 Transformer 链**：

```
字节码输入 (原始 classfileBuffer)
    │
    ▼
┌─ reTransformers ──────────────────┐
│  retransform 命令的 Transformer    │  ← 最先执行
│  优先级最高，用于热替换字节码        │
└──────────────┬────────────────────┘
               │
               ▼
┌─ watchTransformers ───────────────┐
│  watch/monitor/stack/tt 命令      │  ← 然后执行
│  插入 SpyAPI.atEnter/atExit       │
└──────────────┬────────────────────┘
               │
               ▼
┌─ traceTransformers ───────────────┐
│  trace 命令                       │  ← 最后执行
│  插入 SpyAPI.atBeforeInvoke 等     │
└──────────────┬────────────────────┘
               │
               ▼
字节码输出 (增强后的 classfileBuffer)
```

**为什么 trace 要在 watch 后面？**

因为 trace 会在方法内部**每个子调用处**插入拦截代码，产生的字节码变化更多。如果 trace 先执行，watch 再基于 trace 修改后的字节码做增强，可能会影响 trace 插入的代码位置。让 watch 先执行（结构变化较小），trace 后执行（在已增强的基础上继续增强），稳定性更好。

**CopyOnWriteArrayList 的选择**：三个 Transformer 列表都用 `CopyOnWriteArrayList`，因为：
- **读多写少**：每次类加载/重定义都会遍历列表（读），但添加/删除 Transformer（写）只发生在用户执行/取消命令时
- **线程安全**：类加载可能在任意线程发生，必须保证遍历时不会 ConcurrentModificationException

### 5.2 ShutdownHook

```java
shutdown = new Thread("as-shutdown-hooker") {
    @Override
    public void run() {
        ArthasBootstrap.this.destroy();
    }
};
Runtime.getRuntime().addShutdownHook(shutdown);
```

当目标 JVM 正常关闭时，ShutdownHook 确保 Arthas 能**优雅清理**——关闭网络连接、移除 Transformer、恢复字节码、清理 SpyAPI 引用。

---

## 6. destroy() — 优雅关闭

```java
public void destroy() {
    shellServer.close();           // 1. 关闭 Shell Server（断开所有 Session）
    sessionManager.close();        // 2. 关闭 HTTP API Session
    httpSessionManager.stop();     // 3. 关闭 HTTP Session
    timer.cancel();                // 4. 取消定时器
    tunnelClient.stop();           // 5. 断开 Tunnel 连接
    executorService.shutdownNow(); // 6. 关闭线程池
    transformerManager.destroy();  // 7. 移除所有增强 Transformer
    instrumentation.removeTransformer(classLoaderInstrumentTransformer); // 8. 移除 CL 增强
    cleanUpSpyReference();         // 9. 清理 Spy 引用
    shutdownWorkGroup();           // 10. 关闭 Netty worker
    UserStatUtil.destroy();        // 11. 停止统计上报
    Runtime.getRuntime().removeShutdownHook(shutdown); // 12. 移除 ShutdownHook
    loggerContext.stop();          // 13. 关闭日志
}
```

**关闭顺序的讲究**：

```
1-3: 先断开用户连接（不再接受新命令）
  ↓
4-6: 停止内部任务
  ↓
7-8: 移除字节码增强（恢复目标类原始字节码）
  ↓
9:   清理 SpyAPI（增强后的代码调用 SpyAPI 不再有副作用）
  ↓
10-13: 释放底层资源
```

核心原则：**先停止入口，再清理增强，最后释放资源**。特别重要的是第 7 步——`transformerManager.destroy()` 会清空所有 Transformer 列表并从 JVM 移除聚合 Transformer。但注意：**已经增强的类不会自动恢复**，需要在 destroy 之前调用 `reset()` 来触发 `retransformClasses` 恢复原始字节码。

### cleanUpSpyReference() 回顾

```java
private void cleanUpSpyReference() {
    SpyAPI.setNopSpy();   // spyInstance → NOPSPY（空实现）
    SpyAPI.destroy();     // INITED = false
    
    // 通过反射重置 AgentBootstrap 的 ClassLoader 引用
    Class<?> clazz = ClassLoader.getSystemClassLoader()
        .loadClass("com.taobao.arthas.agent334.AgentBootstrap");
    Method method = clazz.getDeclaredMethod("resetArthasClassLoader");
    method.invoke(null);  // arthasClassLoader = null
}
```

**为什么不直接调用 `AgentBootstrap.resetArthasClassLoader()`？**

因为 `ArthasBootstrap`（当前类）在 ArthasClassloader 中，而 `AgentBootstrap` 在系统 ClassLoader 中。跨 ClassLoader 不能直接引用，只能通过反射。

---

## 7. Session 生命周期管理

### 7.1 Session 超时清理

```java
// ShellServerImpl
private void evictSessions() {
    long now = System.currentTimeMillis();
    for (ShellImpl session : sessions.values()) {
        // 超时 + 没有正在运行的 Job → 清理
        if (now - session.lastAccessedTime() > timeoutMillis && session.jobs().size() == 0) {
            toClose.add(session);
        }
    }
    for (ShellImpl session : toClose) {
        session.close("session is inactive for " + timeOutInMinutes + " min(s).");
    }
}
```

**不清理有运行 Job 的 Session**：如果用户执行了 `trace` 命令并在等待触发条件，Session 可能长时间没有新输入，但不应该被清理。只有**无 Job + 超时**才会被清理。

### 7.2 Session 关闭时的资源清理

```java
// ShellServerImpl.removeSession()
public void removeSession(ShellImpl shell) {
    Job job = shell.getForegroundJob();
    if (job != null) {
        job.terminate();  // 终止前台 Job → 触发 reset（恢复字节码增强）
    }
    sessions.remove(shell.id);
    shell.close("network error");
}
```

当网络断开（如 Telnet 连接中断），会触发 `removeSession`，自动终止正在运行的命令并恢复字节码。

---

## 8. 完整初始化时序图

```
ArthasBootstrap 构造函数执行时序
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

 时间  │  操作                              │  涉及组件
───────┼────────────────────────────────────┼──────────────────────
 T0    │  new ArthasBootstrap(inst, args)   │
       │                                    │
 T1    │  initFastjson()                    │  fastjson2
       │    配置 IgnoreErrorGetter          │
       │                                    │
 T2    │  initSpy()                         │  spy.jar → BootstrapCL
       │    appendToBootstrapCLSearch()     │  Instrumentation
       │                                    │
 T3    │  initArthasEnvironment(args)       │  ArthasEnvironment
       │    args → MapPropertySource        │  Configure
       │    arthas.properties → PropertiesPS│
       │    inject → Configure 对象         │
       │                                    │
 T4    │  LogUtil.initLogger()              │  Logback
       │    → ~/logs/arthas/arthas.log      │
       │                                    │
 T5    │  enhanceClassLoader()              │  bytekit + ASM
       │    修改 ClassLoader.loadClass()    │  Instrumentation
       │    retransformClasses(CL.class)    │
       │                                    │
 T6    │  initBeans()                       │
       │    new ResultViewResolver()        │
       │    new HistoryManagerImpl()         │
       │                                    │
 T7    │  bind(configure)                   │
       │  ├─ CAS: isBindRef false→true      │  AtomicBoolean
       │  ├─ 随机端口分配（如果 port=0）     │  SocketUtils
       │  ├─ TunnelClient.start()           │  Netty WebSocket
       │  │   └─ 连接 Tunnel Server         │
       │  ├─ 安全认证初始化                  │  SecurityAuthenticator
       │  │   └─ 0.0.0.0 → 强制生成密码    │
       │  ├─ new ShellServerImpl(options)   │  ShellServer
       │  ├─ BuiltinCommandPack(46个命令)   │  注册用户命令
       │  ├─ NioEventLoopGroup              │  Netty worker
       │  ├─ HttpTelnetTermServer(:3658)    │  Telnet+HTTP
       │  ├─ HttpTermServer(:8563)          │  HTTP+WebSocket
       │  ├─ shellServer.listen()           │  绑定端口
       │  │   └─ 等待所有 TermServer 启动   │  AtomicInteger 计数
       │  ├─ SessionManagerImpl             │  HTTP API 会话
       │  ├─ HttpApiHandler                 │  REST API 处理
       │  ├─ ArthasMcpBootstrap (如果配置) │  MCP Server
       │  ├─ UserStatUtil.arthasStart()     │  启动统计上报
       │  └─ SpyAPI.init()                  │  INITED = true ★
       │                                    │
 T8    │  executorService = newScheduled...  │  命令执行线程池
       │                                    │
 T9    │  TransformerManager(inst)          │  聚合 Transformer
       │    addTransformer(aggregated, true) │  注册到 JVM
       │                                    │
 T10   │  addShutdownHook(destroy)          │  优雅关闭钩子
       │                                    │
       │  ═══════════════════════════════   │
       │  ArthasBootstrap 初始化完成！       │
       │  as-server started in XXX ms       │
       │  ═══════════════════════════════   │
```

---

## 9. 关键设计决策总结

| 设计决策 | 原因 | 替代方案的缺点 |
|----------|------|-----------------|
| 两个端口（3658+8563） | 分离 Telnet 交互和 HTTP API | 单端口：协议检测更复杂，功能耦合 |
| 3658 端口复合 Telnet+HTTP | 兼容老版本 Telnet 客户端 + 新版 Web Console | 分开：多占用一个端口 |
| 共享 NioEventLoopGroup | 减少线程数 | 独立线程组：资源浪费 |
| 三层 Transformer 链 | re > watch > trace 的执行顺序保证 | 单一列表：无法控制增强顺序 |
| CopyOnWriteArrayList | 读多写少的 Transformer 列表 | synchronized：每次类加载都加锁 |
| Session 清理忽略有 Job 的 | 防止误杀正在等待条件的 trace/watch | 一刀切超时：用户体验差 |
| 0.0.0.0 强制生成密码 | 防止线上安全事故 | 不处理：远程任意连接 |
| SpyAPI.init() 放在 bind() 最后 | 确保端口绑定成功才标记已初始化 | 提前设置：启动失败仍被标记为已启动 |
| MCP Server（4.x 新增） | AI 辅助诊断能力 | 无：跟不上 AI 时代 |

---

## 10. 小结

```
ArthasBootstrap 启动后，目标 JVM 内部的状态：

┌─────────────────────────────── 目标 JVM ──────────────────────────────────┐
│                                                                           │
│  BootstrapClassLoader                                                     │
│  ├── SpyAPI (INITED=true, spyInstance=SpyImpl)                           │
│  └── ClassLoader.loadClass() (已增强，能转发 java.arthas.*)               │
│                                                                           │
│  ArthasClassloader                                                        │
│  ├── ArthasBootstrap (单例)                                               │
│  │   ├── Configure (telnetPort=3658, httpPort=8563, ...)                 │
│  │   ├── ShellServer                                                     │
│  │   │   ├── HttpTelnetTermServer (:3658 监听中)                         │
│  │   │   ├── HttpTermServer (:8563 监听中)                               │
│  │   │   ├── BuiltinCommandPack (46 个命令就绪)                          │
│  │   │   └── Sessions (等待用户连接)                                      │
│  │   ├── TransformerManager                                              │
│  │   │   └── 聚合 ClassFileTransformer (已注册到 JVM)                    │
│  │   ├── TunnelClient (连接 Tunnel Server，如果配置了)                    │
│  │   ├── SecurityAuthenticator (认证器)                                   │
│  │   ├── HttpApiHandler (REST API 处理器)                                │
│  │   ├── McpServer (MCP 服务器，如果配置了)                               │
│  │   └── ShutdownHook (优雅关闭注册)                                      │
│  └── SpyImpl, Enhancer, WatchCommand, ... (所有核心类)                    │
│                                                                           │
│  Netty 线程:                                                              │
│  ├── arthas-TermServer-1 (boss, 接受新连接)                              │
│  ├── arthas-TermServer-2 (worker, 处理 I/O)                             │
│  └── ...                                                                  │
│                                                                           │
│  Arthas 线程:                                                             │
│  ├── arthas-command-execute (命令执行)                                     │
│  ├── arthas-shell-server (Session 清理定时器)                             │
│  └── arthas-timer (通用定时器)                                            │
│                                                                           │
│  目标应用线程 (未受影响):                                                  │
│  ├── main                                                                 │
│  ├── 业务线程...                                                          │
│  └── (直到用户执行 watch/trace，才会通过 SpyAPI 产生交互)                  │
│                                                                           │
└───────────────────────────────────────────────────────────────────────────┘
```

**核心理解**：

1. **ArthasBootstrap 是 Arthas 在目标 JVM 内的"大脑"**——持有 Instrumentation 权限、管理所有子组件的生命周期
2. **bind() 方法是从"就绪"到"服务"的关键跳跃**——网络层（Netty）、会话层（ShellServer）、命令层（BuiltinCommandPack）、安全层（SecurityAuthenticator）在这里全部组装完成
3. **TransformerManager 是字节码增强的中枢**——所有增强命令（watch/trace/monitor/stack/tt）的 Transformer 都在这里统一管理和有序执行
4. **destroy() 必须按顺序清理**——先断连接、再移增强、后释资源，确保目标应用不受影响
5. **SpyAPI.init() 的时机精心设计**——只有一切就绪后才标记"已启动"，保证了启动失败时的可重试性

---

> **下一节预告**: [Ch 2.1 ArthasClassloader 设计](ch02_1_arthas_classloader.md) — 虽然 Ch 1.2 已经分析了 ArthasClassloader 的基本原理，Part 2 将从更深的维度分析 ClassLoader 隔离体系：多 ClassLoader 场景下的类可见性问题、Spy 桩机制的设计权衡、以及 ClassLoader 泄漏的排查方法。
