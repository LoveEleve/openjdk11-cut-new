# Arthas 4.1.2 源码深度分析大纲 (v2)

> 版本: v4.1.2 | 源码位置: `/data/workspace/arthas-4.1.2/arthas/`
> 依赖 JDK: `/data/workspace/openjdk-cut-new/` (OpenJDK 11 slowdebug)
> 总代码量: ~79,000 行 Java + ~230 行 C++ (JNI/JVMTI)
> **规则**: 每章输出独立 md 文件；核心章节必须分析到**方法级别**，覆盖关键分支和边界情况

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文是对 **Arthas 4.1.2 源码深度分析大纲 (v2)** 的深度源码分析：从数据结构到算法流程，逐层剖析其实现原理，并通过 GDB 验证关键结论。

### 0.2 为什么需要？

深入理解 JVM 内部实现，不仅能帮助排查生产问题，更能建立对 JVM 行为的精确预测能力——知道『为什么』比知道『是什么』更重要。

### 0.3 怎么解决？

采用「数据结构 → 算法流程 → GDB 验证」三步法：先完整分析所有涉及的数据结构（字段含义/sizeof/生命周期），再分析算法流程（每步有 why），最后用 GDB 实际验证关键结论。

### 0.4 为什么这样设计？

JVM 的每个设计决策都有其历史背景和性能考量。本文在分析每个关键设计时，都会解释「为什么这样而不是那样」，帮助读者建立设计直觉。

---


## 项目全景——模块、代码量与技术栈

### 模块矩阵

```
┌──────────────────────────────────────────────────────────────────────────┐
│                              Arthas 4.1.2 模块全景                       │
│                                                                          │
│  ┌─ 用户入口 ──────────────────────────────────────────────────────────┐ │
│  │  boot (1672行, 3文件)     client (6506行, 28文件)  as.sh/as.bat     │ │
│  │  → 进程发现+Attach         → Telnet CLI 客户端       → Shell 脚本   │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                 ↓ Attach API                             │
│  ┌─ Agent 入口 ────────────────────────────────────────────────────────┐ │
│  │  agent (235行, 2文件)     spy (133行, 1文件)                         │ │
│  │  → premain/agentmain       → SpyAPI (放入 BootstrapCL 的桩)        │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                 ↓ 反射加载                               │
│  ┌─ Core 核心层 (47,874行, 439文件) ───────────────────────────────────┐ │
│  │                                                                      │ │
│  │  ┌── server/ (727行) ──┐  ┌── shell/ (10,110行) ──────────────────┐ │ │
│  │  │ ArthasBootstrap     │  │ ShellServer + Term + Session + Job     │ │ │
│  │  │ ClassLoader_Instr.  │  │ 交互框架（基于 Vert.x Term 改造）     │ │ │
│  │  └─────────────────────┘  └────────────────────────────────────────┘ │ │
│  │                                                                      │ │
│  │  ┌── advisor/ (1,855行, 12文件) ──── 核心中的核心 ────────────────┐ │ │
│  │  │ Enhancer (518行)           → ASM 字节码增强 ClassFileTransformer│ │ │
│  │  │ SpyImpl (187行)            → SpyAPI 的真实实现                  │ │ │
│  │  │ SpyInterceptors (114行)    → bytekit 增强模板（6 组拦截器）    │ │ │
│  │  │ TransformerManager (98行)  → 三层 Transformer 管道              │ │ │
│  │  │ AdviceListenerManager(236行)→ 运行时回调分发中心                │ │ │
│  │  │ AdviceWeaver (78行)        → 监听器注册中心（by adviceId）      │ │ │
│  │  │ AdviceListenerAdapter(157行)→ 监听器适配器（模板方法模式）      │ │ │
│  │  │ Advice (146行)             → 方法调用上下文封装                  │ │ │
│  │  │ ArthasMethod (167行)       → 方法反射信息缓存                   │ │ │
│  │  │ InvokeTraceable (60行)     → trace 专用接口                     │ │ │
│  │  │ AccessPoint (21行)         → 增强点枚举(BEFORE/RETURN/THROW)    │ │ │
│  │  └────────────────────────────────────────────────────────────────┘ │ │
│  │                                                                      │ │
│  │  ┌── command/ (20,859行, 206文件) ────────────────────────────────┐ │ │
│  │  │                                                                │ │ │
│  │  │  monitor200/ (30文件, 最核心的增强类命令)                        │ │ │
│  │  │  ├─ EnhancerCommand (239行)  → 增强命令公共基座                │ │ │
│  │  │  ├─ WatchCommand (204行) + WatchAdviceListener (117行)         │ │ │
│  │  │  ├─ TraceCommand (192行) + AbstractTraceAdviceListener (125行) │ │ │
│  │  │  │  + TraceAdviceListener(41行) + PathTraceAdviceListener(13行)│ │ │
│  │  │  │  + TraceEntity(29行)                                        │ │ │
│  │  │  ├─ MonitorCommand (155行) + MonitorAdviceListener (266行)     │ │ │
│  │  │  │  + MonitorData (77行)                                       │ │ │
│  │  │  ├─ StackCommand (117行) + StackAdviceListener (77行)          │ │ │
│  │  │  ├─ TimeTunnelCommand (545行) + TimeTunnelAdviceListener (159行)│ │ │
│  │  │  │  + TimeTunnelTable (212行) + TimeFragment (33行)            │ │ │
│  │  │  ├─ DashboardCommand (272行) + ThreadSampler (198行)           │ │ │
│  │  │  ├─ ThreadCommand (243行)                                      │ │ │
│  │  │  ├─ ProfilerCommand (1006行) ← 最大的单文件                    │ │ │
│  │  │  ├─ VmToolCommand (357行)                                      │ │ │
│  │  │  ├─ MBeanCommand (497行) + HeapDumpCommand (83行)              │ │ │
│  │  │  ├─ MemoryCommand (111行) + JvmCommand (201行)                 │ │ │
│  │  │  ├─ PerfCounterCommand (115行)                                 │ │ │
│  │  │  └─ GroovyScriptCommand (96行) + GroovyAdviceListener (76行)   │ │ │
│  │  │                                                                │ │ │
│  │  │  klass100/ (11文件, 类操作命令)                                  │ │ │
│  │  │  ├─ JadCommand (255行) + ClassDumpTransformer (95行)           │ │ │
│  │  │  ├─ DumpClassCommand (194行)                                   │ │ │
│  │  │  ├─ RedefineCommand (182行)                                    │ │ │
│  │  │  ├─ RetransformCommand (502行)                                 │ │ │
│  │  │  ├─ SearchClassCommand (182行) + SearchMethodCommand (195行)   │ │ │
│  │  │  ├─ ClassLoaderCommand (729行) ← klass100 中最大的              │ │ │
│  │  │  ├─ OgnlCommand (117行) + GetStaticCommand (208行)             │ │ │
│  │  │  └─ MemoryCompilerCommand (168行)                              │ │ │
│  │  │                                                                │ │ │
│  │  │  basic1000/ (20文件, 基础命令)                                   │ │ │
│  │  │  ├─ JFRCommand (427行) + OptionsCommand (237行)                │ │ │
│  │  │  ├─ GrepCommand (173行) + CatCommand (109行) + Base64Cmd(178行)│ │ │
│  │  │  ├─ ResetCommand (60行) + StopCommand (42行)                   │ │ │
│  │  │  ├─ HelpCommand (162行) + HistoryCommand (89行)                │ │ │
│  │  │  ├─ SystemPropertyCommand (77行) + SystemEnvCommand (63行)     │ │ │
│  │  │  ├─ VMOptionCommand (110行) + AuthCommand (109行)              │ │ │
│  │  │  └─ SessionCommand (53行) + 其他小命令                         │ │ │
│  │  │                                                                │ │ │
│  │  │  logger/ (6文件, 日志级别动态修改)                               │ │ │
│  │  │  ├─ LoggerCommand (383行)                                      │ │ │
│  │  │  ├─ Log4j2Helper (194行) + LogbackHelper (165行)               │ │ │
│  │  │  └─ Log4jHelper (168行) + AsmRenameUtil (42行)                 │ │ │
│  │  │                                                                │ │ │
│  │  │  express/ (8文件, OGNL 表达式引擎)                               │ │ │
│  │  │  ├─ OgnlExpress (66行) + Express接口 (52行)                    │ │ │
│  │  │  ├─ ExpressFactory (31行)  → ThreadLocal<Express>              │ │ │
│  │  │  ├─ DefaultMemberAccess (110行) → 绕过 private 访问限制        │ │ │
│  │  │  ├─ CustomClassResolver (44行) → ClassLoader 感知的类解析      │ │ │
│  │  │  ├─ ClassLoaderClassResolver (42行)                            │ │ │
│  │  │  └─ ArthasObjectPropertyAccessor (23行)                        │ │ │
│  │  │                                                                │ │ │
│  │  │  model/ (~80文件) + view/ (~45文件)                             │ │ │
│  │  │  → Model-View 分离: 命令结果的数据模型 + 终端渲染视图           │ │ │
│  │  │                                                                │ │ │
│  │  │  hidden/ (2文件)                                                │ │ │
│  │  │  └─ JulyCommand (105行) + ThanksCommand (24行) → 彩蛋命令     │ │ │
│  │  └────────────────────────────────────────────────────────────────┘ │ │
│  │                                                                      │ │
│  │  ┌── util/ (6,538行, 43文件) ─────────────────────────────────────┐ │ │
│  │  │ SearchUtils (144行) → 类/方法搜索                               │ │ │
│  │  │ ThreadUtil (499行)  → 线程信息采集（dashboard/thread 核心）     │ │ │
│  │  │ ObjectUtils (654行) → 对象深度渲染（watch -x 的实现）          │ │ │
│  │  │ ClassUtils (237行)  → 类信息提取                                │ │ │
│  │  │ ClassLoaderUtils (185行) → ClassLoader 工具方法                 │ │ │
│  │  │ ArthasBanner (193行) → 启动 Banner + 版本信息                   │ │ │
│  │  │ EnhancerAffect (162行) → 增强结果统计                          │ │ │
│  │  └────────────────────────────────────────────────────────────────┘ │ │
│  │                                                                      │ │
│  │  ┌── 其他子包 ────────────────────────────────────────────────────┐ │ │
│  │  │ env/ (2,785行)       → ArthasEnvironment 四级配置体系          │ │ │
│  │  │ view/ (2,515行)      → TableView/TreeView/ObjectView 通用视图  │ │ │
│  │  │ distribution/ (747行)→ 结果分发（Term/HTTP/Sharing 三通道）    │ │ │
│  │  │ config/ (661行)      → Configure 配置管理                      │ │ │
│  │  │ security/ (356行)    → 认证（Basic/Bearer/Local 三种方式）     │ │ │
│  │  └────────────────────────────────────────────────────────────────┘ │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  ┌─ Native 扩展层 ─────────────────────────────────────────────────────┐ │
│  │  arthas-vmtool (203行Java + 230行C++)                                │ │
│  │  → JVMTI: getInstances/forceGc/interruptThread/setSingleStep         │ │
│  │  memorycompiler (908行, 9文件) → JSR 199 内存编译                    │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  ┌─ 远程连接层 ────────────────────────────────────────────────────────┐ │
│  │  tunnel-client (927行) + tunnel-server (1,855行) + common (190行)   │ │
│  │  → WebSocket 代理，支持远程诊断                                      │ │
│  │  arthas-spring-boot-starter (339行)  → 嵌入式集成                   │ │
│  │  arthas-agent-attach (195行)         → Spring 自动 Attach            │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### 关键技术栈

| 技术 | 作用 | 深度分析要求 | 涉及章节 |
|------|------|------------|---------|
| **Java Agent** (Instrumentation API) | 运行时 Attach + 类转换 + 重定义 | 精读 JDK 源码中 Agent 加载链路 | 1, 2 |
| **ASM 字节码框架** | 解析/修改字节码（ClassReader/ClassWriter/ClassNode） | 理解到指令级别，对比增强前后字节码 | 5 |
| **bytekit-core** (alibaba) | ASM 上层封装，简化方法拦截插桩 | 理解 MethodProcessor + InterceptorProcessor | 5 |
| **OGNL 表达式** | watch/trace 中的条件过滤和数据提取 | 表达式编译、ClassLoader 隔离、变量绑定 | 6 |
| **JVMTI** (via JNI, C++) | vmtool: 堆遍历、强制 GC、类重定义 | 精读 C++ 代码，对比 JDK JVMTI 接口 | 11 |
| **JSR 199** (javax.tools.JavaCompiler) | mc 命令: 内存中编译 Java 源码 | DynamicCompiler 实现 | 13 |
| **CFR 反编译器** | jad: 字节码→Java 源码 | 集成方式 + ClassLoader 选择 | 9 |
| **Netty** | HTTP/WebSocket/Telnet 统一传输层 | 双端口设计 + Tunnel 代理 | 3, 14 |
| **ThreadMXBean/JMX** | dashboard/thread 线程+CPU 数据 | CPU 时间采样算法 | 10 |
| **HotSpotDiagnosticMXBean** | heapdump 命令 | MBean 调用链 | 13 |
| **async-profiler** | profiler 命令底层 | 参数映射 + 输出格式 | 12 |

---

## 详细章节目录

> 💡 编号规则: 章节号.小节号，如 5.3 表示第 5 章第 3 节
> 📌 每节产出一个独立 .md 文件
> 🔥 标注 = 核心章节，必须深入到方法级别
> ⭐ 标注 = 重要但可适度简化
> 📎 标注 = 可选/扩展阅读

---

### Part 1: 启动流程 — 三级火箭

| # | 标题 | 源文件 | 行数 | 核心分析点 | 产出 |
|---|------|--------|------|-----------|------|
| 1.1 | Boot 启动器 + Attach 机制 ⭐ | boot/{Bootstrap,ProcessUtils}.java | ~1700 | ① as.sh 到 Boot.main 的参数传递<br>② ProcessUtils 进程发现(JPS/ps 双方案)<br>③ arthasHome 四级降级查找<br>④ startArthasCore 子进程方案的设计原因<br>⑤ VirtualMachine.attach + loadAgent 完整调用链<br>⑥ JDK 版本兼容处理（JDK9+ module 问题） | ch01_1_boot_and_attach.md |
| 1.2 | Agent 加载 — 从 JVM 到 Core ⭐ | agent/{AgentBootstrap,ArthasClassloader}.java | ~235 | ① premain vs agentmain 差异<br>② SpyAPI.isInited 幂等保护机制<br>③ ArthasClassloader 创建时机和 parent 选择<br>④ binding 独立线程的原因<br>⑤ 反射调用 ArthasBootstrap.getInstance 的设计<br>⑥ Agent_OnAttach → agentmain 在 HotSpot 中的实现路径 | ch01_2_agent_bootstrap.md |
| 1.3 | ArthasBootstrap 服务启动 ⭐ | core/server/ArthasBootstrap.java | 703 | ① 构造函数 6 步初始化详解<br>② bind() 方法 10 个关键步骤<br>③ 随机端口分配（容器化场景）<br>④ TunnelClient 启动流程<br>⑤ 安全认证初始化（0.0.0.0 强制密码）<br>⑥ ShellServer 命令注册(46个命令)<br>⑦ Netty 双端口(3658+8563)设计<br>⑧ destroy() 优雅关闭 7 步顺序 | ch01_3_arthas_bootstrap.md |

### Part 2: ClassLoader 隔离 — Arthas 的生存之道

| # | 标题 | 源文件 | 行数 | 核心分析点 | 产出 |
|---|------|--------|------|-----------|------|
| 2.1 | ArthasClassloader 设计 🔥 | agent/ArthasClassloader.java + AgentBootstrap | ~235 | ① 36 行代码的三大设计目标（隔离/自主/兼容）<br>② parent=ExtClassLoader 的深层原因<br>③ 打破双亲委派: loadClass→findClass 优先自己<br>④ java.*/javax.* 的安全处理<br>⑤ 与 Tomcat/OSGi ClassLoader 的对比<br>⑥ 类卸载与 GC 交互 | ch02_1_arthas_classloader.md |
| 2.2 | Spy 机制 — 跨 ClassLoader 桥梁 🔥 | spy/SpyAPI.java + core/advisor/SpyImpl.java + AdviceListenerManager | ~556 | ① SpyAPI 为什么必须在 BootstrapCL<br>② SpyAPI → SpyImpl 的单向桥接设计<br>③ AdviceListenerManager 的 ConcurrentWeakKeyHashMap<br>④ 三级查找: ClassLoader→className→methodDesc→List\<Listener\><br>⑤ 监听器清理机制(3秒定时器)<br>⑥ 与 Java SPI 的设计对比 | ch02_2_spy_mechanism.md |
| 2.3 | ClassLoader_Instrument — java.lang.ClassLoader 增强 ⭐ | server/instrument/ClassLoader_Instrument.java + Enhancer | 24+相关 | ① 为什么要增强 ClassLoader.loadClass()<br>② 强制委派 java.arthas.* 的实现方式<br>③ 在 JDK9+ module 系统中的兼容处理<br>④ 这个增强与普通 watch/trace 增强的区别 | ch02_3_classloader_instrument.md |

### Part 3: Shell 交互框架 (可选，非核心)

| # | 标题 | 源文件 | 行数 | 核心分析点 | 产出 |
|---|------|--------|------|-----------|------|
| 3.1 | ShellServer + Session 管理 📎 | shell/impl/ShellServerImpl.java + session/ | ~800 | ShellServer 多连接管理、Session 生命周期、Telnet vs WebSocket 统一抽象 | ch03_1_shell_server.md |
| 3.2 | Term 终端 + 命令解析 📎 | shell/term/ + shell/cli/ | ~4600 | 终端 IO 处理、命令行 tokenize、Tab 补全、Netty 双端口架构 | ch03_2_term_and_cli.md |
| 3.3 | Job 系统 + 命令执行管道 📎 | shell/system/ + shell/handlers/ | ~2600 | 前台/后台 Job、一条命令的完整执行流转、管道(grep/tee) | ch03_3_job_system.md |
| 3.4 | 命令框架 + Model-View 📎 | command/AnnotatedCommand + model/ + view/ | ~6400 | 注解式命令注册、ResultModel→ResultView 转换、分发通道 | ch03_4_command_framework.md |

### Part 5: 字节码增强引擎 — Arthas 的核心武器 🔥🔥🔥

| # | 标题 | 源文件 | 行数 | 核心分析点 | 产出 |
|---|------|--------|------|-----------|------|
| 5.1 | Enhancer — ASM 字节码改造核心 🔥 | advisor/Enhancer.java | 518 | ① transform() 方法逐行分析<br>② ASM ClassNode→MethodNode 操作<br>③ SpyInterceptor1/2/3 字节码模板详解<br>④ SpyTraceInterceptor 调用级拦截<br>⑤ skipJDKTrace 排除 java.* 调用<br>⑥ GroupLocationFilter 幂等检查<br>⑦ 增强前后字节码 diff 展示<br>⑧ 参数装箱(int→Integer)的字节码<br>⑨ classBytesCache WeakHashMap 设计<br>⑩ dumpClass 调试功能 | ch05_1_enhancer.md |
| 5.2 | TransformerManager — 三层管道 🔥 | advisor/TransformerManager.java | 98 | ① 为什么只注册一个 ClassFileTransformer 给 JVM<br>② re→watch→trace 三层执行顺序的原因<br>③ CopyOnWriteArrayList 读多写少场景<br>④ 多命令同时增强同一方法的协作机制<br>⑤ 与 JDK Instrumentation.addTransformer 的交互 | ch05_2_transformer_manager.md |
| 5.3 | SpyInterceptors — bytekit 增强模板 🔥 | advisor/SpyInterceptors.java | 114 | ① 6 组拦截器的设计<br>② SpyInterceptor1/2/3: atEnter/atExit/atExceptionExit<br>③ SpyTraceInterceptor1/2/3: atBeforeInvoke/atAfterInvoke/atInvokeException<br>④ SpyTraceExcludeJDKInterceptor: 排除 java.* 调用<br>⑤ bytekit @AtEnter/@AtExit/@AtExceptionExit 注解工作原理<br>⑥ @Binding.This/@Binding.Class/@Binding.Args 参数绑定 | ch05_3_spy_interceptors.md |
| 5.4 | AdviceListener 体系 — 运行时回调链 🔥 | advisor/{AdviceListener,AdviceListenerAdapter,AdviceWeaver,AdviceListenerManager}.java | ~550 | ① AdviceListener 接口(before/afterReturning/afterThrowing)<br>② AdviceListenerAdapter 模板方法模式<br>③ isConditionMet → OGNL 条件求值<br>④ isLimitExceeded + abortProcess 次数限制<br>⑤ AdviceWeaver: adviceId→Listener 全局注册<br>⑥ AdviceListenerManager: ClassLoader+方法→List\<Listener\><br>⑦ 两套注册中心的分工与协作<br>⑧ Listener 生命周期: create→运行→destroy | ch05_4_advice_listener.md |
| 5.5 | Advice 对象 — 方法调用上下文 ⭐ | advisor/Advice.java + ArthasMethod.java | ~313 | ① Advice 封装的 8 个字段<br>② ArthasMethod 反射信息缓存（避免重复查找）<br>③ Advice.isBefore/isReturn/isThrow 的使用场景<br>④ 与 AOP Alliance 的 MethodInvocation 对比 | ch05_5_advice_context.md |
| 5.6 | 搜索与过滤 — 找到目标类 ⭐ | util/SearchUtils.java + Enhancer.filter() | ~660 | ① searchClass: getAllLoadedClasses + WildcardMatcher<br>② searchSubClass: isAssignableFrom 继承遍历<br>③ 七层过滤: isSelf/isUnsafe/isExclude/Lambda/Integer/Class/Array<br>④ 为什么 Integer 不能增强(装箱递归)<br>⑤ options unsafe=true 的风险 | ch05_6_search_and_filter.md |
| 5.7 | reset — 恢复原始字节码 ⭐ | Enhancer.reset() + EnhancerCommand | ~200 | ① reset 流程: 移除 Transformer → retransformClasses<br>② JVM 如何恢复原始字节码（null 返回机制）<br>③ classBytesCache 清理<br>④ reset 命令 vs Ctrl+C 的区别<br>⑤ 增强残留问题和解决方案 | ch05_7_reset.md |

### Part 6: OGNL 表达式引擎

| # | 标题 | 源文件 | 行数 | 核心分析点 | 产出 |
|---|------|--------|------|-----------|------|
| 6.1 | OgnlExpress — 表达式求值核心 🔥 | express/{OgnlExpress,ExpressFactory,Express}.java | ~150 | ① OgnlExpress.get() 求值流程<br>② OgnlExpress.is() 条件判断<br>③ ExpressFactory.threadLocalExpress 线程安全<br>④ Advice 对象作为 OGNL root 的变量绑定<br>⑤ #cost/#clazz/#method 等内置变量<br>⑥ 表达式缓存(OgnlCache) | ch06_1_ognl_express.md |
| 6.2 | ClassLoader 感知 + 安全访问 ⭐ | express/{CustomClassResolver,ClassLoaderClassResolver,DefaultMemberAccess,ArthasObjectPropertyAccessor}.java | ~219 | ① 为什么 OGNL 需要感知 ClassLoader<br>② CustomClassResolver: 优先目标 CL 再 ArthasCL<br>③ DefaultMemberAccess: 绕过 private 的安全机制<br>④ ArthasObjectPropertyAccessor: 属性访问拦截 | ch06_2_ognl_classloader.md |

### Part 7: 核心增强命令 — watch/trace/monitor/stack 🔥

| # | 标题 | 源文件 | 行数 | 核心分析点 | 产出 |
|---|------|--------|------|-----------|------|
| 7.0 | EnhancerCommand — 增强命令公共基座 🔥 | monitor200/EnhancerCommand.java | 239 | ① enhance() 完整流程<br>② session.tryLock 互斥设计<br>③ getAdviceListenerWithId 模板方法<br>④ listener instanceof InvokeTraceable 判断<br>⑤ maxNumOfMatchedClass 限制<br>⑥ --listenerId 复用机制<br>⑦ process.register 用于 Ctrl+C 清理 | ch07_0_enhancer_command.md |
| 7.1 | watch — 方法数据观测 🔥 | monitor200/{WatchCommand,WatchAdviceListener}.java | ~321 | ① -b/-e/-s/-f 四个观测点的实现<br>② -x 展开深度 ObjectUtils.render<br>③ conditionExpress 条件过滤<br>④ express 表达式求值(params/returnObj/throwExp/target)<br>⑤ -n 次数限制 + 自动终止<br>⑥ 完整示例: 从命令输入到结果输出的全链路 | ch07_1_watch.md |
| 7.2 | trace — 方法调用链追踪 🔥 | monitor200/{TraceCommand,TraceAdviceListener,AbstractTraceAdviceListener,PathTraceAdviceListener,TraceEntity}.java | ~400 | ① trace 与 watch 在增强层面的本质区别<br>② TraceEntity 的 ThreadLocal 传递设计<br>③ TraceTree 调用树构建(deep++ / deep--)<br>④ invokeBeforeTracing/invokeAfterTracing 耗时统计<br>⑤ 多层 trace (--skipJDKTrace)<br>⑥ PathTrace: 多方法链路追踪<br>⑦ #cost > 100 条件过滤的实现<br>⑧ TraceView 树形渲染 | ch07_2_trace.md |
| 7.3 | monitor — 方法性能统计 ⭐ | monitor200/{MonitorCommand,MonitorAdviceListener,MonitorData}.java | ~498 | ① 周期性统计(默认120秒)的定时器实现<br>② MonitorData: 成功/失败/耗时/RT的原子累加<br>③ 与 watch 共享 EnhancerCommand 基座<br>④ -c 参数(统计周期)的实现 | ch07_3_monitor.md |
| 7.4 | stack — 调用来源追踪 ⭐ | monitor200/{StackCommand,StackAdviceListener}.java | ~194 | ① Thread.currentThread().getStackTrace() 获取调用栈<br>② 与 jstack 的区别（方法级触发 vs 全局快照）<br>③ conditionExpress 条件过滤<br>④ 实际应用: "这个方法被谁调用了" | ch07_4_stack.md |

### Part 8: tt 命令 — 时间隧道

| # | 标题 | 源文件 | 行数 | 核心分析点 | 产出 |
|---|------|--------|------|-----------|------|
| 8.1 | TimeTunnel 录制 ⭐ | monitor200/{TimeTunnelCommand,TimeTunnelAdviceListener,TimeTunnelTable,TimeFragment}.java | ~949 | ✅ 已完成(合并版) | ch08_time_tunnel.md |
| 8.2 | TimeTunnel 回放 ⭐ | TimeTunnelCommand.doPlay() | ~200 | ✅ 已完成(合并版) | ch08_time_tunnel.md |

### Part 9: 类操作命令 — jad/redefine/retransform

| # | 标题 | 源文件 | 行数 | 核心分析点 | 产出 |
|---|------|--------|------|-----------|------|
| 9.1 | jad 反编译 + dump 导出 🔥 | klass100/{JadCommand,DumpClassCommand,ClassDumpTransformer}.java | ~544 | ✅ 已完成(合并版) | ch09_jad_redefine_retransform.md |
| 9.2 | redefine + retransform — 热替换 🔥 | klass100/{RedefineCommand,RetransformCommand}.java | ~684 | ✅ 已完成(合并版) | ch09_jad_redefine_retransform.md |
| 9.3 | sc/sm/classloader — 类信息查询 ⭐ | klass100/{SearchClassCommand,SearchMethodCommand,ClassLoaderCommand}.java | ~1106 | ✅ 已完成(合并版) | ch09_jad_redefine_retransform.md |

### Part 10: 系统诊断命令

| # | 标题 | 源文件 | 行数 | 核心分析点 | 产出 |
|---|------|--------|------|-----------|------|
| 10.1 | dashboard — 实时监控面板 ⭐ | monitor200/{DashboardCommand,ThreadSampler}.java + util/ThreadUtil.java | ~969 | ✅ 已完成(合并版) | ch10_system_diagnostic_commands.md |
| 10.2 | thread — 线程分析 ⭐ | monitor200/ThreadCommand.java + util/ThreadUtil.java | ~742 | ✅ 已完成(合并版) | ch10_system_diagnostic_commands.md |
| 10.3 | jvm/memory/perfcounter 📎 | monitor200/{JvmCommand,MemoryCommand,PerfCounterCommand}.java | ~427 | ✅ 已完成(合并版) | ch10_system_diagnostic_commands.md |

### Part 11: vmtool — JVMTI Native 直通车 🔥

| # | 标题 | 源文件 | 行数 | 核心分析点 | 产出 |
|---|------|--------|------|-----------|------|
| 11.1 | VmToolCommand 命令 ⭐ | monitor200/VmToolCommand.java | 357 | ✅ 已完成(合并版) | ch11_vmtool_jvmti.md |
| 11.2 | JNI C++ 实现 🔥 | arthas-vmtool/src/main/native/src/jni-library.cpp | 230 | ✅ 已完成(合并版) | ch11_vmtool_jvmti.md |

### Part 12: profiler 命令 + async-profiler 集成

| # | 标题 | 源文件 | 行数 | 核心分析点 | 产出 |
|---|------|--------|------|-----------|------|
| 12.1 | ProfilerCommand 详解 ⭐ | monitor200/ProfilerCommand.java | 1006 | ✅ 已完成 | ch12_profiler_command.md |

### Part 13: 内存编译 + 其他命令

| # | 标题 | 源文件 | 行数 | 核心分析点 | 产出 |
|---|------|--------|------|-----------|------|
| 13.1 | mc — 内存编译器 ⭐ | klass100/MemoryCompilerCommand.java + memorycompiler/(908行) | ~1076 | ✅ 已完成(合并版) | ch13_memory_compiler_and_others.md |
| 13.2 | heapdump/ognl/getstatic/logger 📎 | 各自命令文件 | ~791 | ✅ 已完成(合并版) | ch13_memory_compiler_and_others.md |
| 13.3 | JFR 命令 📎 | basic1000/JFRCommand.java | 427 | ✅ 已完成(合并版) | ch13_memory_compiler_and_others.md |

### Part 14: Tunnel 远程连接

| # | 标题 | 源文件 | 行数 | 核心分析点 | 产出 |
|---|------|--------|------|-----------|------|
| 14.1 | Tunnel 架构 📎 | tunnel-client + tunnel-server + tunnel-common | ~2970 | Agent 注册、WebSocket 代理、浏览器远程连接、Redis 集群模式 | ch14_1_tunnel.md |
| 14.2 | Spring Boot Starter 📎 | arthas-spring-boot-starter + arthas-agent-attach | ~534 | 嵌入式集成、自动 Attach、配置属性 | ch14_2_spring_boot.md |

---

## 进度追踪

| # | 标题 | 状态 | 完成日期 |
|---|------|------|----------|
| 1.1 | Boot 启动器 + Attach 机制 | ✅ 已完成 | 2026-02-10 |
| 1.2 | Agent 加载入口 | ✅ 已完成 | 2026-02-10 |
| 1.3 | ArthasBootstrap 服务启动 | ✅ 已完成 | 2026-02-10 |
| 2.1 | ArthasClassloader 设计 | ✅ 已完成 | 2026-02-10 |
| 2.2 | Spy 机制 | ✅ 已完成 | 2026-02-10 |
| 2.3 | ClassLoader_Instrument | ⬜ 未开始 | — |
| 3.1-3.4 | Shell 交互框架 | ⏭️ 跳过（非核心） | — |
| 5.1 | Enhancer ASM 字节码改造 | ✅ 已完成(合并版) | 2026-02-10 |
| 5.2 | TransformerManager | ✅ 已完成(合并版) | 2026-02-10 |
| 5.3 | SpyInterceptors | ✅ 已完成(合并版) | 2026-02-10 |
| 5.4 | AdviceListener 体系 | ✅ 已完成(合并版) | 2026-02-10 |
| 5.5 | Advice 上下文 | ⬜ 未开始 | — |
| 5.6 | 搜索与过滤 | ✅ 已完成(合并版) | 2026-02-10 |
| 5.7 | reset 恢复 | ✅ 已完成(合并版) | 2026-02-10 |
| 6.1 | OgnlExpress 表达式引擎 | ✅ 已完成(合并版) | 2026-02-10 |
| 6.2 | OGNL ClassLoader 感知 | ✅ 已完成(合并版) | 2026-02-10 |
| 7.0 | EnhancerCommand 公共基座 | ✅ 已完成(合并版) | 2026-02-10 |
| 7.1 | watch 命令 | ✅ 已完成(合并版) | 2026-02-10 |
| 7.2 | trace 命令 | ✅ 已完成(合并版) | 2026-02-10 |
| 7.3 | monitor 命令 | ✅ 已完成(合并版) | 2026-02-10 |
| 7.4 | stack 命令 | ✅ 已完成(合并版) | 2026-02-10 |
| 8.1 | tt 录制 | ✅ 已完成(合并版) | 2026-02-10 |
| 8.2 | tt 回放 | ✅ 已完成(合并版) | 2026-02-10 |
| 9.1 | jad 反编译 | ✅ 已完成(合并版) | 2026-02-10 |
| 9.2 | redefine/retransform | ✅ 已完成(合并版) | 2026-02-10 |
| 9.3 | sc/sm/classloader | ✅ 已完成(合并版) | 2026-02-10 |
| 10.1 | dashboard | ✅ 已完成(合并版) | 2026-02-10 |
| 10.2 | thread | ✅ 已完成(合并版) | 2026-02-10 |
| 10.3 | jvm/memory/perfcounter/heapdump | ✅ 已完成(合并版) | 2026-02-10 |
| 11.1 | vmtool 命令 | ✅ 已完成(合并版) | 2026-02-10 |
| 11.2 | vmtool JNI C++ | ✅ 已完成(合并版) | 2026-02-10 |
| 12.1 | profiler + async-profiler | ✅ 已完成 | 2026-02-10 |
| 13.1 | mc 内存编译 | ✅ 已完成(合并版) | 2026-02-10 |
| 13.2 | 其他命令 | ✅ 已完成(合并版) | 2026-02-10 |
| 13.3 | JFR 命令 | ✅ 已完成(合并版) | 2026-02-10 |
| 14.1 | Tunnel | ⏭️ 跳过（选读） | — |
| 14.2 | Spring Boot Starter | ✅ 已完成 | 2026-02-10 |

---

## 推荐学习路线

### 精简路线（聚焦核心机制，约 25 节）

```
第 1 阶段: 基础设施（已完成 ✅）
  1.1 → 1.2 → 1.3 → 2.1 → 2.2 (→ 2.3 可选)
  目标：理解 Arthas 如何连接目标 JVM、ClassLoader 隔离、Spy 桥梁

第 2 阶段: 增强引擎 + 表达式（最核心 🔥）
  5.1 → 5.2 → 5.3 → 5.4 → 5.6 → 5.7 → 6.1 → 6.2
  目标：理解 ASM 字节码增强、三层 Transformer 管道、OGNL 表达式引擎

第 3 阶段: 核心命令实现（增强的落地 🔥）
  7.0 → 7.1 → 7.2 → 7.3 → 7.4 → 8.1 → 8.2
  目标：理解 watch/trace/monitor/stack/tt 的完整实现

第 4 阶段: 类操作 + Native 能力
  9.1 → 9.2 → 9.3 → 11.1 → 11.2
  目标：理解 jad/redefine/retransform/vmtool

第 5 阶段: 高级特性（扩展阅读）
  10.1 → 10.2 → 12.1 → 13.1
  目标：dashboard/thread/profiler/mc
```

### 完整路线（全部 40 节）

```
1.1→1.2→1.3→2.1→2.2→2.3→3.1→3.2→3.3→3.4
→5.1→5.2→5.3→5.4→5.5→5.6→5.7→6.1→6.2
→7.0→7.1→7.2→7.3→7.4→8.1→8.2
→9.1→9.2→9.3→10.1→10.2→10.3
→11.1→11.2→12.1→13.1→13.2→13.3→14.1→14.2
```

---

## 与已有知识体系的交叉引用

### 与 OpenJDK 源码分析的交叉

| Arthas 机制 | 对应 OpenJDK 实现 | 深度关联 |
|-------------|------------------|---------|
| Attach API | HotSpot AttachListener + Signal handler | Agent 如何被加载 |
| Instrumentation.retransformClasses | VM_RedefineClasses + JvmtiClassFileReconstituter | 字节码替换在 JVM 内部的实现 |
| ClassLoader 双亲委派 | java.lang.ClassLoader + SystemDictionary | ArthasCL 打破委派的底层机制 |
| BootstrapClassLoader | SystemDictionary::resolve_or_null | SpyAPI 能被所有 CL 看到的原因 |
| JVMTI IterateOverInstancesOfClass | jvmtiEnv::IterateOverInstancesOfClass → ObjectHeap::iterate | vmtool 堆遍历的 JVM 实现 |
| ThreadMXBean.getThreadCpuTime | os::thread_cpu_time → /proc/self/task/\<tid\>/stat | dashboard CPU 数据来源 |

### 与 async-profiler 源码分析的交叉

| Arthas 概念 | 对应 async-profiler 章节 | 对比要点 |
|-------------|------------------------|---------|
| ProfilerCommand | 全部 12 章 | Arthas 是 async-profiler 的 Java 封装 |
| JVMTI Agent_OnAttach | Ch01 Agent 加载 | 两者都用 JVMTI，但使用方式不同 |
| vmtool C++ | Ch01-12 C++ 实现 | 两者都通过 JNI 调用 JVMTI |
| 字节码增强(ASM) vs 采样(perf_events) | Ch02 采样引擎 | Arthas=侵入式增强, AP=非侵入采样 |
| ClassLoader 隔离 | Ch01 Agent 加载 | Arthas 需要隔离, AP 直接 native |

---

## 代码量统计

| 部分 | 章节数 | 代码行数 | 分析深度 |
|------|--------|---------|---------|
| Part 1-2: 启动+ClassLoader | 6 | ~2,900 | ⭐⭐⭐ 精读 |
| Part 3: Shell 框架 | 4 | ~14,000 | 📎 选读 |
| **Part 5-6: 增强引擎+OGNL** | **9** | **~2,500** | **🔥🔥🔥 逐行** |
| **Part 7-8: 增强命令实现** | **7** | **~2,500** | **🔥🔥 精读** |
| Part 9: 类操作命令 | 3 | ~2,300 | ⭐⭐ 精读 |
| Part 10: 系统诊断 | 3 | ~1,700 | ⭐ 精读 |
| Part 11: vmtool | 2 | ~590 | 🔥🔥 逐行(C++) |
| Part 12-13: profiler+mc+其他 | 4 | ~2,300 | ⭐ 精读 |
| Part 14: Tunnel | 2 | ~3,500 | 📎 选读 |
| **总计** | **39** | **~79,000** | — |
| **精读核心** | **~25** | **~12,000** | — |

---

*创建日期: 2026-02-10*
*最后更新: 2026-02-10 (v2 - 详细版)*