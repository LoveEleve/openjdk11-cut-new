
# Ch 1.1 Boot 启动器 + Attach 机制

> 源文件:
> - `boot/Bootstrap.java` (526行) — Java 启动器入口
> - `boot/ProcessUtils.java` (370行) — 进程发现 + Attach 辅助
> - `core/Arthas.java` (168行) — Attach 执行器
> - `bin/as.sh` (1106行) — Shell 启动脚本
> - OpenJDK: `jdk.attach/HotSpotVirtualMachine.java` — JVM 端 Attach API

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **Ch 1.1 Boot 启动器 + Attach 机制**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 1. 先回答"为什么"

### 1.1 Arthas 面临的核心问题

一个 Java 诊断工具，要解决的第一个问题是：**怎么把自己的代码注入到一个已经在运行的目标 JVM 中？**

传统方式（如 jconsole、jvisualvm）是通过 JMX 远程连接，但只能读取信息，不能修改字节码。而 Arthas 需要的是更深层的能力——在目标 JVM 中**插入字节码**、**拦截方法调用**、**实时修改类定义**。

这就需要 **Java Agent + Attach API**：

| 技术 | 作用 | 时机 |
|------|------|------|
| `premain` Agent | JVM 启动时通过 `-javaagent:` 参数加载 | 启动前 |
| `agentmain` Agent | 通过 Attach API 动态注入到运行中的 JVM | 运行时 |
| `Instrumentation` | Agent 获得的"权限令牌"，可以转换/重定义类 | Agent 加载后 |

Arthas 主要使用 **`agentmain` 模式**——因为它的典型场景是：应用已经在线上跑了，出了问题，才需要 Attach 上去诊断。

### 1.2 启动流程的两种入口

Arthas 提供了两种启动方式，最终殊途同归：

```
方式 1: as.sh（Shell 脚本）
  → 发现 Java 进程 → 找到 JAVA_HOME → 启动 arthas-core.jar → Attach → 连接 Telnet

方式 2: java -jar arthas-boot.jar（推荐）
  → 发现 Java 进程 → 找到 arthasHome → 启动 arthas-core.jar → Attach → 连接 Telnet
```

两者的核心区别在于：`as.sh` 直接用 Shell 编排流程，而 `arthas-boot.jar` 用 Java 代码实现同样的逻辑，并且有更好的跨平台支持和版本管理。

---

## 2. 完整启动流程

### 2.1 宏观调用链

```
                用户执行
                  │
    ┌─────────────┤─────────────┐
    ▼                           ▼
  as.sh                  arthas-boot.jar
  (Shell脚本)            (Bootstrap.main)
    │                           │
    │  1.发现Java进程            │  1.发现Java进程
    │    call_jps               │    ProcessUtils.select()
    │  2.找JAVA_HOME            │  2.找arthasHome
    │    find_java_home()       │    verifyArthasHome()
    │  3.启动arthas-core.jar    │  3.启动arthas-core.jar
    │    attach_jvm()           │    ProcessUtils.startArthasCore()
    │                           │
    └─────────────┬─────────────┘
                  │
                  ▼
        ┌─ 新子进程 ─────────────────────────┐
        │  java -jar arthas-core.jar          │
        │       -pid <目标PID>                │
        │       -core arthas-core.jar         │
        │       -agent arthas-agent.jar       │
        │                                     │
        │  Arthas.main()                      │
        │    └→ parse(args) → Configure       │
        │    └→ attachAgent(configure)         │
        │         │                           │
        │         ▼                           │
        │  VirtualMachine.attach(pid)  ←─── Attach API │
        │  vm.loadAgent(                      │
        │     "arthas-agent.jar",             │
        │     "arthas-core.jar;配置参数")     │
        │  vm.detach()                        │
        └─────────────────┬───────────────────┘
                          │
                          ▼ (目标 JVM 内部)
        ┌─────────────────────────────────────┐
        │  JVM AttachListener 线程收到命令      │
        │    → load_agent("instrument", ...)  │
        │    → 加载 java.instrument 模块       │
        │    → 读取 Agent-Class MANIFEST       │
        │    → 调用 AgentBootstrap.agentmain() │
        │         │                           │
        │         ▼                           │
        │  AgentBootstrap.main(args, inst)    │
        │    → 解析 arthasCoreJar 路径         │
        │    → new ArthasClassloader(core.jar)│
        │    → 新线程: bind(inst, agentLoader)│
        │        → ArthasBootstrap.getInstance│
        │           → initSpy()               │
        │           → initEnvironment()       │
        │           → enhanceClassLoader()    │
        │           → bind(configure)         │
        │              → 启动 Shell Server    │
        │              → 监听 Telnet/HTTP 端口 │
        └─────────────────────────────────────┘
                          │
                          ▼ (回到用户进程)
        ┌─────────────────────────────────────┐
        │  arthas-boot / as.sh                │
        │    → 启动 arthas-client.jar         │
        │    → Telnet 连接 127.0.0.1:3658     │
        │    → 进入交互式命令行                 │
        │                                     │
        │  arthas>                            │
        └─────────────────────────────────────┘
```

这个流程涉及 **三个 JVM 进程**：

| 进程 | 角色 | 生命周期 |
|------|------|---------|
| arthas-boot (或 as.sh) | 启动器，负责发现进程、触发 Attach | 短暂：Attach 完成后退出 |
| arthas-core (子进程) | Attach 执行器，调用 `VirtualMachine.attach()` | 极短暂：Agent 加载后立即退出 |
| 目标 JVM | 被诊断的应用 + 注入的 Arthas Agent | 长期运行 |

---

## 3. Bootstrap.java 启动器详解

`Bootstrap.java` 是 `arthas-boot.jar` 的入口类，它的 `main()` 方法做了以下事情（按执行顺序）：

### 3.1 参数解析

```java
Bootstrap bootstrap = new Bootstrap();
CLI cli = CLIConfigurator.define(Bootstrap.class);
CommandLine commandLine = cli.parse(Arrays.asList(args));
CLIConfigurator.inject(commandLine, bootstrap);
```

Arthas 使用了一套自己的 CLI 框架（`com.taobao.middleware.cli`），通过 `@Option`、`@Argument` 注解来声明命令行参数。`Bootstrap` 类本身就是一个"参数容器"，每个 setter 方法对应一个命令行选项。

关键参数及其默认值：

| 参数 | 默认值 | 作用 |
|------|--------|------|
| `--telnet-port` | 3658 | Arthas Telnet 监听端口 |
| `--http-port` | 8563 | Arthas HTTP 监听端口 |
| `--target-ip` | 127.0.0.1 | 目标 IP |
| `--session-timeout` | 1800 (30min) | Session 超时 |
| `--arthas-home` | null | Arthas 安装目录 |
| `--use-version` | null | 指定版本号 |
| `--attach-only` | false | 只 Attach 不连接 |
| `-c` / `--command` | null | 批量执行命令 |
| `--select` | null | 按类名/JAR名筛选进程 |
| `--tunnel-server` | null | 远程 Tunnel 服务地址 |

### 3.2 端口冲突检测

```java
telnetPortPid = SocketUtils.findTcpListenProcess(bootstrap.getTelnetPortOrDefault());
httpPortPid = SocketUtils.findTcpListenProcess(bootstrap.getHttpPortOrDefault());
```

在 Attach 之前，先检查 Telnet 端口（默认 3658）和 HTTP 端口（默认 8563）是否已被占用。如果被别的进程占用，会报错退出；如果被目标进程自己占用（说明已有 Arthas 实例），则跳过 Attach 直接连接。

### 3.3 进程选择

```java
pid = ProcessUtils.select(bootstrap.isVerbose(), telnetPortPid, bootstrap.getSelect());
```

如果用户没有直接指定 PID，则调用 `ProcessUtils.select()` 让用户交互式选择。

### 3.4 Arthas Home 发现（四级降级策略）

寻找 Arthas 安装目录是一个**四级降级**的过程：

```
优先级 1: 用户显式指定 --arthas-home
    ↓ 找不到
优先级 2: --use-version 指定版本 → ~/.arthas/lib/{version}/arthas/
    ↓ 找不到（本地无此版本）→ 从远程仓库下载
优先级 3: arthas-boot.jar 所在目录
    ↓ 找不到
优先级 4: 从远程仓库下载最新版本 → ~/.arthas/lib/{latest}/arthas/
```

找到目录后，会验证其中必须包含三个核心 JAR：

```java
String[] fileList = { "arthas-core.jar", "arthas-agent.jar", "arthas-spy.jar" };
```

这三个 JAR 就是 Arthas 在目标 JVM 中运行的全部物料。

### 3.5 启动 Attach 子进程

```java
ProcessUtils.startArthasCore(pid, attachArgs);
```

这是最关键的一步——它**不是在当前进程中调用 Attach API**，而是**启动一个新的 Java 子进程**来执行 Attach。

为什么要这样做？因为 Attach API 要求调用方的 JDK 版本必须和目标 JVM 匹配。arthas-boot.jar 可能运行在任意 JDK 上，所以需要找到**目标 JVM 同版本的 java** 来执行 Attach。

---

## 4. ProcessUtils.startArthasCore() — 启动 Attach 子进程

```java
public static void startArthasCore(long targetPid, List<String> attachArgs) {
    String javaHome = findJavaHome();
    File javaPath = findJava(javaHome);
    File toolsJar = findToolsJar(javaHome);

    List<String> command = new ArrayList<String>();
    command.add(javaPath.getAbsolutePath());

    if (toolsJar != null && toolsJar.exists()) {
        command.add("-Xbootclasspath/a:" + toolsJar.getAbsolutePath());
    }
    command.addAll(attachArgs);

    ProcessBuilder pb = new ProcessBuilder(command);
    pb.environment().put("JAVA_TOOL_OPTIONS", "");
    final Process proc = pb.start();
    // ... 重定向 stdout/stderr，等待子进程结束
}
```

最终拼装的命令行等效于：

```bash
${JAVA_HOME}/bin/java \
    -Xbootclasspath/a:${JAVA_HOME}/lib/tools.jar \   # JDK 8 需要，JDK 9+ 不需要
    -jar arthas-core.jar \
    -pid ${TARGET_PID} \
    -core arthas-core.jar \
    -agent arthas-agent.jar \
    -telnet-port 3658 \
    -http-port 8563 \
    # ... 其他参数
```

### findJavaHome() 的查找策略

```
1. System.getProperty("java.home")
2. 如果 JDK ≤ 8：查找 tools.jar（java.home/lib/ 或 ../lib/）
3. 如果找不到：尝试环境变量 JAVA_HOME
4. 如果 JDK ≥ 9：直接使用 java.home（不需要 tools.jar）
```

> **为什么 JDK 8 需要 tools.jar？**
>
> Attach API 的实现类 `com.sun.tools.attach.VirtualMachine` 在 JDK 8 及以下版本中位于 `tools.jar`，不在标准 classpath 中。JDK 9+ 将其模块化为 `jdk.attach` 模块，自动可用。

### 清除 JAVA_TOOL_OPTIONS

```java
pb.environment().put("JAVA_TOOL_OPTIONS", "");
```

这一行看起来不起眼，但非常重要。`JAVA_TOOL_OPTIONS` 环境变量会被 JVM 自动读取并作为启动参数。如果目标环境设置了诸如 `-javaagent:someAgent.jar` 这样的值，会干扰 Arthas 的 Attach 子进程。因此需要清空。

---

## 5. Arthas.java — Attach 执行器

`arthas-core.jar` 的 Main-Class 是 `com.taobao.arthas.core.Arthas`。它只做两件事：**解析参数** 和 **执行 Attach**。

### 5.1 attachAgent() 核心流程

```java
private void attachAgent(Configure configure) throws Exception {
    // 1. 通过 VirtualMachine.list() 找到目标 JVM 描述符
    VirtualMachineDescriptor virtualMachineDescriptor = null;
    for (VirtualMachineDescriptor descriptor : VirtualMachine.list()) {
        if (descriptor.id().equals(Long.toString(configure.getJavaPid()))) {
            virtualMachineDescriptor = descriptor;
            break;
        }
    }

    VirtualMachine virtualMachine = null;
    try {
        // 2. Attach 到目标 JVM
        if (virtualMachineDescriptor == null) {
            virtualMachine = VirtualMachine.attach("" + configure.getJavaPid());
        } else {
            virtualMachine = VirtualMachine.attach(virtualMachineDescriptor);
        }

        // 3. 版本检查（警告但不阻止）
        Properties targetSystemProperties = virtualMachine.getSystemProperties();
        // ... 检查 java version 是否一致

        // 4. 加载 Agent 到目标 JVM（核心！！！）
        virtualMachine.loadAgent(arthasAgentPath,
                configure.getArthasCore() + ";" + configure.toString());
    } finally {
        // 5. 断开 Attach 连接
        if (virtualMachine != null) {
            virtualMachine.detach();
        }
    }
}
```

这里的关键调用是第 4 步：`vm.loadAgent(agentJarPath, args)`。

参数说明：
- **agentJarPath**: `arthas-agent.jar` 的绝对路径
- **args**: 用 `;` 分隔的两段——`arthas-core.jar路径;配置参数字符串`

### 5.2 loadAgent() 在 JVM 内部的执行链

当 `vm.loadAgent()` 被调用后，发生了以下跨进程交互：

```
Arthas 子进程 (Attach 调用方)              目标 JVM (被 Attach 方)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━             ━━━━━━━━━━━━━━━━━━━━━━━━
                                          
HotSpotVirtualMachine.loadAgent()         
  │                                       
  │  // loadAgent 翻译为 loadAgentLibrary("instrument", args)
  │  // 其中 args = "agentJar=options"
  ▼                                       
execute("load",                           
        "instrument",                     
        "false",                          
        args)                             
  │                                       
  │  // Linux: 通过 Unix Domain Socket    
  │  //   写入: "1\0load\0instrument\0false\0args\0"
  │                                       
  └─────────────── Socket ───────────────→ AttachListener 线程
                                            │
                                            ▼
                                          load_agent(op, out)
                                            │ agent = "instrument"
                                            │
                                            ▼
                                          // 加载 java.instrument 模块
                                          Modules.loadModule("java.instrument")
                                            │
                                            ▼
                                          JvmtiExport::load_agent_library(
                                              "instrument", false, args, out)
                                            │
                                            ▼
                                          // 加载 libinstrument.so
                                          // 调用 Agent_OnAttach()
                                            │
                                            ▼
                                          InstrumentationImpl:
                                            1. 读取 arthas-agent.jar 的 MANIFEST
                                            2. 找到 Agent-Class: AgentBootstrap
                                            3. 调用 AgentBootstrap.agentmain(args, inst)
```

**核心理解**：`vm.loadAgent(jarPath)` 并不是把整个 JAR 发送过去。它实际上是：
1. 告诉目标 JVM："请加载 `instrument` 库（libinstrument.so）"
2. `instrument` 库读取 agentJar 的 `MANIFEST.MF` 中的 `Agent-Class` 属性
3. 调用该类的 `agentmain(String args, Instrumentation inst)` 方法

Arthas 的 Agent MANIFEST 声明了：

```
Premain-Class: com.taobao.arthas.agent334.AgentBootstrap
Agent-Class: com.taobao.arthas.agent334.AgentBootstrap
Can-Redefine-Classes: true
Can-Retransform-Classes: true
```

因此目标 JVM 会调用 `AgentBootstrap.agentmain()`，并传入两个参数：
- **args**: 之前拼装的 `arthas-core.jar路径;配置参数`
- **inst**: `Instrumentation` 实例——这就是 Arthas 进行字节码增强的"权限令牌"

---

## 6. ProcessUtils.select() — 进程发现

### 6.1 发现策略

```
优先策略: jps -l（列出所有 Java 进程）
降级策略: jcmd -l（JDK 9+ 推荐方式）
```

`jps` 和 `jcmd` 都是 JDK 自带的工具，它们通过读取 `/tmp/hsperfdata_<username>/` 目录下的文件来发现本机的 Java 进程。

### 6.2 交互式选择

```
Found existing java process, please choose one and input the serial number of the process, eg : 1.
* [1]: 12345 com.example.MyApplication
  [2]: 12346 org.apache.catalina.startup.Bootstrap
  [3]: 12347 demo.jar
```

注意：
- 已经占用 Arthas 端口的进程会被**排在第一位**（标记 `*`）
- 当前 boot 进程自身（PID = `PidUtils.currentPid()`）会被排除
- jps/jcmd 自身也会被排除

### 6.3 --select 自动匹配

```bash
./as.sh --select math-game
```

当使用 `--select` 选项时，如果恰好只有一个进程的描述匹配（`entry.getValue().contains(select)`），则自动选中，不需要交互。

---

## 7. as.sh 与 arthas-boot.jar 的差异对比

| 对比维度 | as.sh | arthas-boot.jar |
|----------|-------|-----------------|
| 实现语言 | Bash Shell | Java |
| 跨平台 | Linux/Mac（Cygwin 部分支持） | 全平台 |
| 进程发现 | `jps -l` | `jps -l` → `jcmd -l`（降级） |
| JAVA_HOME | Shell 变量 + 多级降级查找 | `System.getProperty("java.home")` |
| 版本管理 | `~/.arthas/lib/{version}/` | 同左 |
| 远程下载 | `curl` | Java HTTP |
| 安全检查 | `ps` 检查进程所有者 | 无（交给 JVM） |
| Attach 方式 | 启动 `java -jar arthas-core.jar` | 启动子进程 `ProcessBuilder` |
| 客户端连接 | `telnet` 或 `arthas-client.jar` | 反射调用 `TelnetConsole.main` |

两者**最终执行路径完全一致**：都是启动 `arthas-core.jar` 作为子进程来调用 Attach API。

---

## 8. 关键设计决策

### 8.1 为什么要三个进程？

```
arthas-boot  →  arthas-core(子进程)  →  目标 JVM
   用户入口        Attach 执行器           Agent 运行
```

**为什么不直接在 arthas-boot 进程中调用 Attach API？**

答案：**JDK 版本兼容性**。

arthas-boot.jar 可能运行在 JDK 8 上，但目标 JVM 可能是 JDK 11。Attach API 要求调用方和被调用方使用**兼容的 JDK 版本**，否则通信协议可能不匹配。所以 `ProcessUtils.startArthasCore()` 会找到**和目标 JVM 相同的 java** 来启动 arthas-core.jar，确保 Attach 成功。

### 8.2 为什么 Agent 参数用 `;` 拼接？

```java
vm.loadAgent(arthasAgentPath, configure.getArthasCore() + ";" + configure.toString());
```

因为 `loadAgent()` 的第二个参数只接受一个 String。Arthas 需要传递两部分信息：
1. `arthas-core.jar` 的路径（Agent 需要用它创建 ClassLoader）
2. 完整的配置参数（端口、IP、tunnel 等）

所以用 `;` 作为分隔符，在 `AgentBootstrap.main()` 中再拆分。

### 8.3 为什么 URL 编码参数？

```java
configure.setArthasAgent(encodeArg(arthasAgentPath));
configure.setArthasCore(encodeArg(configure.getArthasCore()));
```

路径中可能包含空格、中文等特殊字符。Attach API 底层通过 Socket 传输参数字符串，某些特殊字符可能导致解析失败。URL 编码后在 Agent 端 decode，确保路径完整传递。

### 8.4 端口冲突的 Double-Check

Bootstrap.java 中有一个有趣的 **double-check** 逻辑：

```java
// 第一次检查：通过 lsof/ss 检查端口占用
telnetPortPid = SocketUtils.findTcpListenProcess(bootstrap.getTelnetPortOrDefault());

// ... 选择目标 PID 后 ...

// 第二次检查：通过 arthas-client 连接目标端口，执行 session 命令获取 JAVA_PID
telnetPortPid = findProcessByTelnetClient(arthasHomeDir, bootstrap.getTelnetPortOrDefault());
```

为什么需要两次？
- 第一次是**系统级**检查（lsof），快但可能权限不足看不到
- 第二次是**应用级**检查（Telnet 连接），确认端口上运行的确实是 Arthas，并获取对应 PID

---

## 9. 完整时序图

```
┌────────┐          ┌────────────┐          ┌─────────────┐       ┌──────────────┐
│  用户   │          │arthas-boot │          │arthas-core  │       │  目标 JVM     │
│        │          │  进程       │          │  子进程      │       │              │
└───┬────┘          └─────┬──────┘          └──────┬──────┘       └──────┬───────┘
    │                     │                        │                     │
    │ java -jar           │                        │                     │
    │ arthas-boot.jar     │                        │                     │
    │ <pid>               │                        │                     │
    │────────────────────→│                        │                     │
    │                     │                        │                     │
    │                     │ 1. 解析参数              │                     │
    │                     │ 2. 检查端口占用           │                     │
    │                     │ 3. 发现 Java 进程         │                     │
    │                     │ 4. 找到 arthasHome        │                     │
    │                     │                        │                     │
    │                     │ ProcessBuilder          │                     │
    │                     │ startArthasCore()       │                     │
    │                     │───────────────────────→│                     │
    │                     │                        │                     │
    │                     │                        │ Arthas.main()       │
    │                     │                        │  parse(args)        │
    │                     │                        │  attachAgent()      │
    │                     │                        │                     │
    │                     │                        │ VirtualMachine      │
    │                     │                        │  .attach(pid)       │
    │                     │                        │────────────────────→│
    │                     │                        │                     │ AttachListener
    │                     │                        │     连接建立          │ 创建 Socket
    │                     │                        │←────────────────────│
    │                     │                        │                     │
    │                     │                        │ vm.loadAgent(       │
    │                     │                        │   agent.jar, args)  │
    │                     │                        │────────────────────→│
    │                     │                        │                     │ load_agent()
    │                     │                        │                     │ loadModule("java.instrument")
    │                     │                        │                     │ load libinstrument.so
    │                     │                        │                     │ Agent_OnAttach()
    │                     │                        │                     │ 读取 MANIFEST
    │                     │                        │                     │ AgentBootstrap
    │                     │                        │                     │  .agentmain(args,inst)
    │                     │                        │                     │   │
    │                     │                        │                     │   ▼
    │                     │                        │                     │ ArthasClassloader
    │                     │                        │                     │ ArthasBootstrap
    │                     │                        │                     │  .getInstance()
    │                     │                        │                     │   initSpy()
    │                     │                        │                     │   bind()
    │                     │                        │                     │   listen :3658/:8563
    │                     │                        │                     │
    │                     │                        │  loadAgent返回       │
    │                     │                        │←────────────────────│
    │                     │                        │                     │
    │                     │                        │ vm.detach()         │
    │                     │                        │ exit(0)             │
    │                     │ 子进程退出               │                     │
    │                     │←───────────────────────│                     │
    │                     │                        ×                     │
    │                     │                                              │
    │                     │ 启动 arthas-client.jar                        │
    │                     │ Telnet 127.0.0.1:3658                        │
    │                     │─────────────────────────────────────────────→│
    │                     │                                              │
    │  arthas>            │              交互式命令行                      │
    │←────────────────────│←─────────────────────────────────────────────│
    │                     │                                              │
```

---

## 10. 小结

| 组件 | 职责 | 关键技术 |
|------|------|---------|
| `as.sh` / `Bootstrap.java` | 用户入口：进程发现、版本管理、启动 Attach | CLI 解析、jps/jcmd |
| `ProcessUtils` | 进程列表、JAVA_HOME 发现、启动子进程 | ProcessBuilder、tools.jar |
| `Arthas.java` | Attach 执行器：连接目标 JVM、加载 Agent | VirtualMachine.attach/loadAgent |
| JVM `AttachListener` | 接收 Attach 请求、加载 Agent | Unix Domain Socket、JVMTI |
| `AgentBootstrap` | Agent 入口：创建 ClassLoader、初始化核心 | agentmain、Instrumentation |

**核心理解**：Arthas 的启动本质上是**三级火箭**：
1. **第一级**（arthas-boot）：找到目标、准备物料
2. **第二级**（arthas-core 子进程）：调用 Attach API 将 Agent 注入目标
3. **第三级**（目标 JVM 内的 Agent）：初始化 Arthas 核心服务

第一级和第二级用完即弃，只有第三级在目标 JVM 中长期运行。

---

> **下一节预告**: [Ch 1.2 Agent 加载入口](ch01_2_agent_bootstrap.md) — 深入分析 `AgentBootstrap.agentmain()` 的完整执行流程，以及 `ArthasClassloader` 的隔离设计。
