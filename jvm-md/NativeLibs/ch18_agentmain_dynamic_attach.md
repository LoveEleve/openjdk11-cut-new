# Ch18: agentmain 与动态 Attach Agent — 从 VirtualMachine.attach() 到 agentmain()

> 基于 OpenJDK 11 源码 | libinstrument + libattach + AttachListener 深度分析
> 模块 A（第 4 篇 / 共 4 篇，收官）| PerfMa 面试价值：⭐⭐⭐⭐⭐

---

## 18.1 总览：动态 Agent 解决什么问题？

### 核心场景

`-javaagent` 是启动时加载 Agent（Ch15 已分析），但很多场景需要**运行中动态加载**：

- **Arthas**：`java -jar arthas-boot.jar <pid>` 连上一个正在运行的 JVM
- **PerfMa XSea**：attach 到线上 JVM，注入诊断逻辑
- **async-profiler**：运行时挂载采样器
- **jcmd / jstack / jmap**：通过 Attach API 发送命令

### premain vs agentmain

| 维度 | premain（Ch15） | agentmain（本章） |
|------|----------------|------------------|
| 加载时机 | JVM 启动时（`-javaagent`） | JVM 运行中（Attach API） |
| MANIFEST 属性 | `Premain-Class` | `Agent-Class` |
| HotSpot 入口 | `Agent_OnLoad` | `Agent_OnAttach` |
| JVMTI Phase | ONLOAD → 等到 LIVE 才调用 premain | 直接在 LIVE Phase |
| 是否需要 VMInit 回调 | 是（两阶段加载） | 否（直接一步到位） |
| 方法签名 | `premain(String, Instrumentation)` | `agentmain(String, Instrumentation)` |

### 完整调用链全景

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       动态 Agent 加载全链路                                   │
│                                                                             │
│ 【客户端进程】                       【目标 JVM 进程】                          │
│                                                                             │
│ VirtualMachine.attach(pid)                                                  │
│ ├── 1. 创建 .attach_pid<pid> 文件                                           │
│ ├── 2. sendQuitTo(pid) → SIGQUIT                                           │
│ │                         ──────────────────►                               │
│ │                                    Signal Dispatcher 线程                  │
│ │                                    ├── 检查 .attach_pid 文件              │
│ │                                    ├── AttachListener::is_init_trigger()  │
│ │                                    └── AttachListener::init()             │
│ │                                         ├── 创建 Attach Listener 线程     │
│ │                                         ├── 创建 Unix Domain Socket       │
│ │                                         │   /tmp/.java_pid<pid>           │
│ │                                         └── 进入 accept() 循环            │
│ │                                                                           │
│ ├── 3. 等待 .java_pid<pid> 出现                                             │
│ ├── 4. connect(socket_path)                                                 │
│ └── 5. 验证连接成功                                                          │
│                                                                             │
│ vm.loadAgent("agent.jar")                                                   │
│ ├── loadAgentLibrary("instrument", "agent.jar=options")                     │
│ └── execute("load", "instrument", "false", args)                            │
│     ├── connect → write 请求                                                │
│     │   "1\0load\0instrument\0false\0agent.jar=options\0"                    │
│     │                         ──────────────────►                            │
│     │                                    Attach Listener 线程               │
│     │                                    ├── dequeue() → accept()           │
│     │                                    ├── read_request()                 │
│     │                                    ├── 查找 "load" → load_agent()     │
│     │                                    │                                  │
│     │                                    │  ┌─ load_agent() ─────────────┐  │
│     │                                    │  │                            │  │
│     │                                    │  │ 加载 java.instrument 模块  │  │
│     │                                    │  │                            │  │
│     │                                    │  │ JvmtiExport::              │  │
│     │                                    │  │  load_agent_library()      │  │
│     │                                    │  │  ├── dlopen(libinstrument) │  │
│     │                                    │  │  ├── 找 Agent_OnAttach     │  │
│     │                                    │  │  └── (*on_attach_entry)()  │  │
│     │                                    │  │                            │  │
│     │                                    │  └──────────────────────────┘   │
│     │                                    │                                  │
│     │                                    │  ┌─ Agent_OnAttach ──────────┐  │
│     │                                    │  │ (libinstrument.so)        │  │
│     │                                    │  │                           │  │
│     │                                    │  │ createNewJPLISAgent()     │  │
│     │                                    │  │ readAttributes(MANIFEST)  │  │
│     │                                    │  │ → Agent-Class             │  │
│     │                                    │  │ appendClassPath(jar)      │  │
│     │                                    │  │ convertCapabilities()     │  │
│     │                                    │  │ createInstrumentationImpl │  │
│     │                                    │  │ setLivePhaseEventHandlers │  │
│     │                                    │  │ startJavaAgent(           │  │
│     │                                    │  │   agentClass,             │  │
│     │                                    │  │   agent->mAgentmainCaller)│  │
│     │                                    │  │  ├── JNI CallVoidMethod   │  │
│     │                                    │  │  │  loadClassAndCall      │  │
│     │                                    │  │  │   Agentmain()          │  │
│     │                                    │  │  │  ├── loadClass()       │  │
│     │                                    │  │  │  ├── 找 agentmain()    │  │
│     │                                    │  │  │  └── m.invoke()        │  │
│     │                                    │  │  │      → 用户代码执行    │  │
│     │                                    │  │  └── 返回 success/fail    │  │
│     │                                    │  └──────────────────────────┘   │
│     │                                    │                                  │
│     │                    ◄──────────────────                                │
│     └── 读取 "return code: 0"                                               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 18.2 客户端：VirtualMachine.attach() — SIGQUIT 握手协议

### 类继承关系

```
com.sun.tools.attach.VirtualMachine (abstract)
└── sun.tools.attach.HotSpotVirtualMachine (abstract)
    └── sun.tools.attach.VirtualMachineImpl (平台相关，Linux 实现)
```

### 18.2.1 VirtualMachineImpl 构造函数 — attach 握手

**文件**：`src/jdk.attach/linux/classes/sun/tools/attach/VirtualMachineImpl.java`

```
VirtualMachineImpl(provider, vmid):
│
├── pid = Integer.parseInt(vmid)
│
├── ns_pid = getNamespacePid(pid)
│   └── 读取 /proc/<pid>/status 中的 NSpid 字段
│       → 如果目标在 namespace 中，获取内部 PID
│       → 支持容器场景（Docker/K8s）
│
├── socket_file = findSocketFile(pid, ns_pid)
│   → /proc/<pid>/root/tmp/.java_pid<ns_pid>
│   → 通过 procfs 访问目标进程的文件系统（支持不同 mount namespace）
│
├── if (!socket_file.exists()):
│   │
│   ├── ★ 创建 attach 触发文件 ★
│   │   f = createAttachFile(pid, ns_pid)
│   │   → 尝试 /proc/<pid>/cwd/.attach_pid<ns_pid>
│   │   → 失败则 /proc/<pid>/root/tmp/.attach_pid<ns_pid>
│   │
│   ├── ★ 发送 SIGQUIT ★
│   │   sendQuitTo(pid)  ← native: kill(pid, SIGQUIT)
│   │
│   ├── 轮询等待 socket 文件出现
│   │   delay = 100ms, 递增, 最长 attachTimeout (默认 10s)
│   │   中途再发一次 SIGQUIT（half timeout）
│   │
│   └── f.delete()  ← 清理触发文件
│
├── checkPermissions(socket_path)  ← 检查文件权限
│
└── ★ 验证连接 ★
    s = socket()  ← 创建 Unix Domain Socket
    connect(s, socket_path)
    close(s)
```

### 18.2.2 为什么用 SIGQUIT？

Linux 上 JVM 默认注册了 SIGQUIT (signal 3) 的处理器。Signal Dispatcher 线程收到 SIGQUIT 后：

1. 检查 `.attach_pid<pid>` 文件是否存在
2. 如果存在，说明有客户端请求 attach → 初始化 AttachListener
3. 如果不存在，执行默认行为（打印线程 dump）

这个设计的巧妙之处在于：**不需要目标 JVM 提前开启 Attach**。任何运行中的 JVM 都可以被 attach（除非设置了 `-XX:+DisableAttachMechanism`）。

---

## 18.3 目标 JVM：SIGQUIT → AttachListener 初始化

### 18.3.1 Signal Dispatcher 线程处理

**文件**：`src/hotspot/share/runtime/os.cpp` (line 365)

```
signal_thread_entry():
│
├── 收到 SIGBREAK (= SIGQUIT on Linux)
│
├── if (!DisableAttachMechanism):
│   │
│   ├── cur_state = AttachListener::transit_state(AL_INITIALIZING, AL_NOT_INITIALIZED)
│   │   └── CAS 操作：NOT_INITIALIZED → INITIALIZING
│   │
│   ├── if (cur_state == AL_NOT_INITIALIZED):
│   │   └── AttachListener::is_init_trigger()
│   │       │
│   │       ├── 检查 .attach_pid<pid> 文件是否存在
│   │       │   → 先检查工作目录：.attach_pid<pid>
│   │       │   → 再检查 /tmp/.attach_pid<pid>
│   │       │
│   │       ├── 检查文件所有者（uid 必须匹配）
│   │       │   → 安全性：防止其他用户 attach
│   │       │
│   │       └── 如果文件存在且权限正确：
│   │           AttachListener::init()
│   │           → 创建 Attach Listener 线程（见下文）
│   │           return true
│   │
│   └── if (cur_state == AL_INITIALIZED && !socket_file_exists):
│       └── 重新初始化（socket 文件被删除的恢复机制）
│
└── 如果不是 attach 触发：打印线程 dump（正常 SIGQUIT 行为）
```

### 18.3.2 AttachListener::init() — 创建 Attach Listener 线程

**文件**：`src/hotspot/share/services/attachListener.cpp` (line 410)

```
AttachListener::init():
│
├── 创建 Java Thread 对象
│   thread_oop = new Thread("Attach Listener")
│   → 加入 system threadGroup
│
├── 创建 native JavaThread
│   listener_thread = new JavaThread(&attach_listener_thread_entry)
│   → 入口函数：attach_listener_thread_entry
│
├── 设置为 daemon 线程
│   java_lang_Thread::set_daemon(thread_oop)
│
└── Thread::start(listener_thread)
```

### 18.3.3 attach_listener_thread_entry — 主循环

**文件**：`src/hotspot/share/services/attachListener.cpp` (line 343)

```
attach_listener_thread_entry(thread):
│
├── os::set_priority(thread, NearMaxPriority)
│   → Attach Listener 线程优先级接近最高
│
├── AttachListener::pd_init()
│   → Linux: LinuxAttachListener::init()
│   │
│   ├── path = /tmp/.java_pid<pid>
│   │
│   ├── listener = socket(PF_UNIX, SOCK_STREAM, 0)
│   │   → 创建 Unix Domain Socket
│   │
│   ├── bind(listener, path.tmp)
│   │   → 先绑定 .java_pid<pid>.tmp
│   │
│   ├── listen(listener, 5)
│   │   → 允许 5 个待处理连接
│   │
│   ├── chmod(path.tmp, S_IREAD|S_IWRITE)
│   │   → 权限 600（仅所有者读写）
│   │
│   ├── chown(path.tmp, euid, egid)
│   │   → 确保文件所有者正确
│   │
│   └── rename(path.tmp, path)
│       → 原子重命名 → 这就是客户端等待的 socket 文件
│       → 客户端此时能看到文件，开始连接
│
├── AttachListener::set_initialized()
│
└── ★ 主循环 ★
    for (;;):
    │
    ├── op = AttachListener::dequeue()
    │   → Linux: LinuxAttachListener::dequeue()
    │   │
    │   ├── accept(listener)  ← 阻塞等待客户端连接
    │   │
    │   ├── getsockopt(SO_PEERCRED)  ← 获取连接方的 uid/gid
    │   │   → 安全检查：uid 必须匹配（或 root）
    │   │
    │   └── read_request(s)
    │       → 读取协议：<ver>\0<cmd>\0<arg0>\0<arg1>\0<arg2>\0
    │       → 例如："1\0load\0instrument\0false\0agent.jar=options\0"
    │       → 创建 LinuxAttachOperation 对象
    │
    ├── 查找并执行命令
    │   funcs[] 命令表：
    │   ├── "agentProperties" → get_agent_properties
    │   ├── "datadump"        → data_dump
    │   ├── "dumpheap"        → dump_heap
    │   ├── "load"            → load_agent      ← 加载 Agent 走这里
    │   ├── "properties"      → get_system_properties
    │   ├── "threaddump"      → thread_dump
    │   ├── "inspectheap"     → heap_inspection
    │   ├── "setflag"         → set_flag
    │   ├── "printflag"       → print_flag
    │   └── "jcmd"            → jcmd
    │
    └── op->complete(res, &st)
        → 写回结果：先写 "<return_code>\n"，再写输出数据
        → shutdown + close socket
```

---

## 18.4 load_agent — 从 "load" 命令到 Agent_OnAttach

### 18.4.1 load_agent 函数

**文件**：`src/hotspot/share/services/attachListener.cpp` (line 121)

```
load_agent(op, out):
│
├── agent = op->arg(0)     → "instrument"
│   absParam = op->arg(1)  → "false"
│   options = op->arg(2)   → "agent.jar=options"
│
├── ★ 特殊处理 instrument agent ★
│   if (strcmp(agent, "instrument") == 0):
│   │
│   │   // 必须先确保 java.instrument 模块已加载
│   │   JavaCalls::call_static(
│   │     Modules.loadModule("java.instrument"))
│   │   → 否则 libinstrument.so 的 JNI native 方法无法注册
│   │   → 这是 JDK 9+ 模块化带来的要求
│   │
│
└── JvmtiExport::load_agent_library(agent, absParam, options, out)
```

### 18.4.2 JvmtiExport::load_agent_library

**文件**：`src/hotspot/share/prims/jvmtiExport.cpp` (line 2634)

```
load_agent_library(agent, absParam, options, st):
│
├── is_absolute_path = (absParam == "true")
├── agent_lib = new AgentLibrary(agent, options, is_absolute_path)
│
├── ★ 查找库 ★
│   if (!os::find_builtin_agent(agent_lib)):
│   │   → 检查是否是静态链接的 agent
│   │
│   ├── if (is_absolute_path):
│   │   library = os::dll_load(agent)  ← 绝对路径直接加载
│   │
│   └── else:
│       ├── os::dll_locate_lib(dll_dir, agent)
│       │   → 尝试 JDK lib 目录下找 libinstrument.so
│       │   → 路径: $JAVA_HOME/lib/libinstrument.so
│       │
│       └── 如果找不到：
│           os::dll_build_name(agent)
│           → 尝试系统默认库路径
│
├── ★ 查找 Agent_OnAttach 函数 ★
│   on_attach_entry = os::find_agent_function(
│     agent_lib, AGENT_ONATTACH_SYMBOLS)
│   → Linux: "Agent_OnAttach" 或 "Agent_OnAttach_instrument"
│
├── ★ 调用 Agent_OnAttach ★
│   JvmtiThreadEventMark jem(THREAD)
│   JvmtiJavaThreadEventTransition jet(THREAD)
│   result = (*on_attach_entry)(&main_vm, (char*)options, NULL)
│   │
│   │  ← 这就进入了 libinstrument.so 的 Agent_OnAttach
│   │
│
├── if (result == JNI_OK):
│   Arguments::add_loaded_agent(agent_lib)  ← 添加到已加载列表
│   st->print_cr("return code: 0")
│
└── else:
    delete agent_lib
    st->print_cr("return code: %d", result)
```

---

## 18.5 Agent_OnAttach — libinstrument.so 的动态 Agent 入口

**文件**：`src/java.instrument/share/native/libinstrument/InvocationAdapter.c` (line 251)

这是 Ch18 的**核心入口**。与 `Agent_OnLoad`（Ch15）相比，`Agent_OnAttach` 的设计哲学是**一步到位**——不需要等待 VMInit，因为 JVM 已经在 LIVE Phase。

```
DEF_Agent_OnAttach(vm, args, reserved):
│
├── result = (*vm)->GetEnv(vm, &jni_env, JNI_VERSION_1_2)
│   → 获取 JNIEnv（当前线程已经是 JavaThread）
│   → 注意：Agent_OnLoad 时不需要 JNIEnv，因为还在 OnLoad Phase
│
├── initerror = createNewJPLISAgent(vm, &agent)
│   │
│   │   ★ 关键差异 1：LIVE Phase 跳过 VMInit 事件注册 ★
│   │   → initializeJPLISAgent() 中：
│   │     phase = GetPhase(jvmtienv) → JVMTI_PHASE_LIVE
│   │     if (phase == JVMTI_PHASE_LIVE):
│   │       return JPLIS_INIT_ERROR_NONE
│   │       → 直接返回！不注册 VMInit 回调！
│   │       → 对比 Agent_OnLoad：phase == ONLOAD → 注册 VMInit 回调
│   │
│
├── parseArgumentTail(args, &jarfile, &options)
│   → 解析 "agent.jar=options" 为 jarfile 和 options
│
├── attributes = readAttributes(jarfile)
│   → 读取 JAR 的 MANIFEST.MF
│
├── ★ 关键差异 2：读取 Agent-Class（不是 Premain-Class）★
│   agentClass = getAttribute(attributes, "Agent-Class")
│   → Agent_OnLoad 读取 "Premain-Class"
│   → Agent_OnAttach 读取 "Agent-Class"
│   → 如果没有 Agent-Class 属性 → 返回 AGENT_ERROR_BADJAR (100)
│
├── ★ 关键差异 3：直接 appendClassPath ★
│   appendClassPath(agent, jarfile)
│   → 通过 JVMTI AddToSystemClassLoaderSearch
│   → Agent_OnLoad 时：在 VMInit 回调中才 appendClassPath
│   → Agent_OnAttach 时：直接调用（LIVE Phase 可用）
│   → 如果失败 → 返回 AGENT_ERROR_NOTONCP (101)
│
├── UTF-8 → Modified UTF-8 转换（同 Agent_OnLoad）
│
├── bootClassPath 处理（同 Agent_OnLoad）
│
├── convertCapabilityAttributes(attributes, agent)
│   → 读取 Can-Redefine-Classes / Can-Retransform-Classes
│   → 设置 JVMTI 能力
│
├── ★ 关键差异 4：直接创建 Instrumentation 对象 ★
│   createInstrumentationImpl(jni_env, agent)
│   → Agent_OnLoad 时：在 processJavaStart() 的 VMInit 回调中才创建
│   → Agent_OnAttach 时：直接创建
│   │
│   │  创建内容（同 Ch15 分析）：
│   │  ├── FindClass("sun/instrument/InstrumentationImpl")
│   │  ├── new InstrumentationImpl(nativeAgent, redefine, prefix)
│   │  ├── 获取 mPremainCaller = getMethodID("loadClassAndCallPremain")
│   │  ├── 获取 mAgentmainCaller = getMethodID("loadClassAndCallAgentmain")
│   │  └── 获取 mTransform = getMethodID("transform")
│   │
│
├── ★ 关键差异 5：直接设置 ClassFileLoadHook ★
│   setLivePhaseEventHandlers(agent)
│   → 注册 ClassFileLoadHook 回调
│   → 关闭 VMInit 事件（虽然在 LIVE Phase 这是 no-op）
│
├── ★ 关键差异 6：调用 agentmain（不是 premain）★
│   startJavaAgent(agent, jni_env, agentClass, options, agent->mAgentmainCaller)
│   │
│   │  注意最后一个参数：
│   │  Agent_OnLoad: agent->mPremainCaller → "loadClassAndCallPremain"
│   │  Agent_OnAttach: agent->mAgentmainCaller → "loadClassAndCallAgentmain"
│   │
│   ├── commandStringIntoJavaStrings(classname, options)
│   │   → 创建 Java String 对象
│   │
│   └── invokeJavaAgentMainMethod(impl, agentmainCaller, className, options)
│       → JNI CallVoidMethod(instrumentationImpl, mAgentmainCaller, ...)
│       → 调用 InstrumentationImpl.loadClassAndCallAgentmain()
│
└── if (!success): return AGENT_ERROR_STARTFAIL (102)
    else: return JNI_OK (0)
```

---

## 18.6 Java 层：loadClassAndCallAgentmain

**文件**：`src/java.instrument/share/classes/sun/instrument/InstrumentationImpl.java`

### 方法入口

```java
// WARNING: the native code knows the name & signature of this method
private void loadClassAndCallAgentmain(String classname, String optionsString)
        throws Throwable {
    loadClassAndStartAgent(classname, "agentmain", optionsString);
}
```

### loadClassAndStartAgent — 反射查找 agentmain

```
loadClassAndStartAgent(classname, "agentmain", optionsString):
│
├── mainAppLoader = ClassLoader.getSystemClassLoader()
├── javaAgentClass = mainAppLoader.loadClass(classname)
│
├── ★ 四级优先级查找 agentmain 方法 ★
│   （与 premain 完全相同的查找逻辑，只是方法名不同）
│
│   优先级 1: javaAgentClass.getDeclaredMethod("agentmain",
│               String.class, Instrumentation.class)
│   → 本类声明的 2 参数版本
│
│   优先级 2: javaAgentClass.getDeclaredMethod("agentmain",
│               String.class)
│   → 本类声明的 1 参数版本
│
│   优先级 3: javaAgentClass.getMethod("agentmain",
│               String.class, Instrumentation.class)
│   → 继承的 2 参数版本
│
│   优先级 4: javaAgentClass.getMethod("agentmain",
│               String.class)
│   → 继承的 1 参数版本
│
│   → 都找不到：抛出第一个 NoSuchMethodException
│
├── setAccessible(m, true)
│   → agentmain 不要求 public
│
└── m.invoke(null, optionsString [, this])
    → 如果是 2 参数版本：传入 Instrumentation 实例
    → 如果是 1 参数版本：只传 options
    → ★ 用户的 agentmain 代码在这里执行 ★
```

---

## 18.7 Agent_OnLoad vs Agent_OnAttach — 六大关键差异汇总

| 差异点 | Agent_OnLoad (premain) | Agent_OnAttach (agentmain) |
|--------|----------------------|---------------------------|
| **Phase** | `JVMTI_PHASE_ONLOAD` | `JVMTI_PHASE_LIVE` |
| **需要 JNIEnv** | 否（OnLoad Phase 无 JNI） | 是（`GetEnv` 获取） |
| **VMInit 回调** | 注册 → 等待 VMInit 才创建 Instrumentation | 不需要 → 直接创建 |
| **MANIFEST** | `Premain-Class` | `Agent-Class` |
| **appendClassPath** | 在 VMInit 回调中执行 | 直接执行 |
| **调用方法** | `mPremainCaller` → premain() | `mAgentmainCaller` → agentmain() |

### 两阶段 vs 一步到位

```
premain（两阶段）：
  Phase ONLOAD                    Phase LIVE
  ─────────────                   ──────────
  Agent_OnLoad:                   VMInit callback:
    createNewJPLISAgent             appendClassPath
    readManifest                    createInstrumentationImpl
    convertCapabilities             setLivePhaseEventHandlers
    register VMInit callback        startJavaAgent → premain()
    recordCommandLineData

agentmain（一步到位）：
  Phase LIVE
  ──────────
  Agent_OnAttach:
    createNewJPLISAgent (跳过 VMInit 注册)
    readManifest
    appendClassPath        ← 直接
    convertCapabilities
    createInstrumentationImpl  ← 直接
    setLivePhaseEventHandlers  ← 直接
    startJavaAgent → agentmain()  ← 直接
```

---

## 18.8 安全机制

### 三层安全保障

| 层次 | 机制 | 实现位置 |
|------|------|---------|
| **L1: 文件权限** | `.java_pid<pid>` 权限 600（仅所有者读写） | `LinuxAttachListener::init()` 中 `chmod(S_IREAD\|S_IWRITE)` |
| **L2: UID 匹配** | 连接时检查客户端的 euid 必须匹配目标进程 | `dequeue()` 中 `getsockopt(SO_PEERCRED)` |
| **L3: 触发文件** | `.attach_pid<pid>` 文件的 uid 必须匹配 | `is_init_trigger()` 中 `matches_effective_uid_or_root()` |

### 关闭 Attach 机制

```
-XX:+DisableAttachMechanism
→ AttachListener::is_attach_supported() 返回 false
→ Signal Dispatcher 收到 SIGQUIT 时不检查 attach 文件
→ 目标 JVM 永远不会创建 Attach Listener
```

### JDK 11 新增：EnableDynamicAgentLoading

```
-XX:-EnableDynamicAgentLoading  （默认启用）
→ Attach Listener 仍然运行
→ 但 "load" 命令会被拒绝
→ 其他命令（threaddump/dumpheap/jcmd）仍然可用
→ 只禁止动态 Agent 加载，不禁止管理命令
```

---

## 18.9 Launcher-Agent-Class — 第三种 Agent 加载方式

**文件**：`src/java.instrument/share/native/libinstrument/InvocationAdapter.c` (line 365)

JDK 9+ 引入了 `Launcher-Agent-Class`：main JAR 的 MANIFEST 中可以指定 Agent 类，JVM 启动时自动加载。

```
jint loadAgent(JNIEnv* env, jstring path):
│
├── createNewJPLISAgent(vm, &agent)
│
├── readAttributes(jarfile)
│   → 读取 Launcher-Agent-Class（不是 Premain-Class 或 Agent-Class）
│
├── convertCapabilityAttributes()
│
├── createInstrumentationImpl()
│
├── setLivePhaseEventHandlers()
│
└── startJavaAgent(agent, env, agentClass, "", agent->mAgentmainCaller)
    → 注意：也使用 agentmain，不是 premain
```

### 三种 Agent 对比

| 维度 | -javaagent (premain) | Attach API (agentmain) | Launcher-Agent-Class |
|------|---------------------|----------------------|---------------------|
| 触发方式 | 命令行参数 | 远程 attach | main JAR 的 MANIFEST |
| MANIFEST 属性 | Premain-Class | Agent-Class | Launcher-Agent-Class |
| 加载入口 | Agent_OnLoad | Agent_OnAttach | loadAgent() |
| 调用的用户方法 | premain() | agentmain() | agentmain() |
| Phase | ONLOAD → LIVE | LIVE | LIVE |

---

## 18.10 通信协议详解

### 请求格式

```
客户端 → 目标 JVM（通过 Unix Domain Socket）

<version>\0<command>\0<arg0>\0<arg1>\0<arg2>\0

字段说明：
  version: 协议版本，目前为 "1"
  command: 命令名（最长 16 字节）
  arg0-arg2: 最多 3 个参数（每个最长 1024 字节）
  \0: 每个字段以 null 字节分隔

load 命令的参数：
  arg0 = agent library name（如 "instrument"）
  arg1 = "true" 或 "false"（是否绝对路径）
  arg2 = options（如 "agent.jar=options"）

例如加载 Java Agent 的完整请求：
  "1\0load\0instrument\0false\0/path/to/agent.jar=some_option\0"
```

### 响应格式

```
目标 JVM → 客户端

<return_code>\n<output_data>

return_code: 0 表示成功，非 0 表示失败
output_data: 命令输出（如 thread dump、properties 等）

load 命令的响应：
  "0\nreturn code: 0\n"  ← 成功
  "0\nreturn code: 102\n" ← Agent_OnAttach 返回 102
```

---

## 18.11 Arthas attach 的完整链路

结合 Ch15-Ch18 的知识，分析 Arthas 连接目标 JVM 的完整链路：

```
arthas-boot.jar:
│
├── 1. VirtualMachine.attach(pid)
│   ├── 创建 .attach_pid<pid>
│   ├── SIGQUIT → 目标 JVM
│   ├── 等待 .java_pid<pid>
│   └── connect 验证
│
├── 2. vm.loadAgent("arthas-agent.jar")
│   │
│   │   HotSpotVirtualMachine.loadAgent():
│   │   → loadAgentLibrary("instrument", "arthas-agent.jar")
│   │   → execute("load", "instrument", "false", "arthas-agent.jar")
│   │
│   │   目标 JVM 中：
│   │   ├── Attach Listener 收到 "load" 命令
│   │   ├── load_agent() → 加载 java.instrument 模块
│   │   ├── load_agent_library("instrument")
│   │   │   → dlopen(libinstrument.so)
│   │   │   → Agent_OnAttach(&main_vm, "arthas-agent.jar", NULL)
│   │   │
│   │   ├── Agent_OnAttach:
│   │   │   ├── createNewJPLISAgent()
│   │   │   ├── readManifest → Agent-Class: com.taobao.arthas.agent.AgentBootstrap
│   │   │   ├── appendClassPath(arthas-agent.jar)
│   │   │   ├── createInstrumentationImpl()
│   │   │   ├── setLivePhaseEventHandlers()
│   │   │   └── startJavaAgent → loadClassAndCallAgentmain()
│   │   │       → AgentBootstrap.agentmain(args, instrumentation)
│   │   │           → Arthas 启动逻辑
│   │   │           → 绑定端口、创建 ClassFileTransformer
│   │   │           → 准备接受用户命令
│   │   │
│   │   └── 返回 "return code: 0"
│   │
│
├── 3. Arthas 客户端连接 Arthas Server
│   → 用户输入 trace/watch/stack 等命令
│
├── 4. 命令执行（如 trace com.xxx.MyClass myMethod）
│   ├── Instrumentation.retransformClasses(MyClass)  ← Ch16 链路
│   ├── ClassFileLoadHook → Transformer 修改字节码  ← Ch15 链路
│   ├── JVMTI ClassFileLoadHook 事件分发           ← Ch17 链路
│   └── 新字节码被安装 → 方法调用时触发 trace 逻辑
│
└── 5. 清理
    Instrumentation.retransformClasses(MyClass)
    → 恢复原始字节码
```

---

## 18.12 面试专题

### Q1: Arthas 是怎么连上目标 JVM 的？

**回答**（源码级）：

Arthas 通过 Java Attach API 连接目标 JVM，完整流程：

1. **握手阶段**：`VirtualMachine.attach(pid)` → 创建 `.attach_pid<pid>` 触发文件 → 发送 SIGQUIT → 目标 JVM 的 Signal Dispatcher 线程检测到触发文件 → `AttachListener::init()` 创建 Attach Listener 线程 → 创建 Unix Domain Socket `/tmp/.java_pid<pid>` → 客户端连接验证

2. **Agent 加载**：`vm.loadAgent("arthas-agent.jar")` → 发送 `load instrument false arthas-agent.jar` 命令 → Attach Listener 线程收到 → `load_agent()` → 确保 `java.instrument` 模块加载 → `JvmtiExport::load_agent_library("instrument")` → `dlopen(libinstrument.so)` → `Agent_OnAttach()`

3. **agentmain 调用**：`Agent_OnAttach` 中 `createNewJPLISAgent()` → 读取 MANIFEST 的 `Agent-Class` → `appendClassPath` → `createInstrumentationImpl()` → `setLivePhaseEventHandlers()` → `startJavaAgent()` → JNI 调用 `loadClassAndCallAgentmain()` → 反射查找 `agentmain(String, Instrumentation)` → `m.invoke()`

4. **安全保障**：三层安全——文件权限 600、SO_PEERCRED uid 匹配、触发文件 uid 匹配

### Q2: 为什么 Attach 用 SIGQUIT 而不是 SIGINT 或其他信号？

**回答**：

- SIGQUIT 在 JVM 中的默认行为是打印线程 dump，已经有 Signal Dispatcher 线程在监听
- 利用现有基础设施（不需要额外线程）
- SIGQUIT 不会终止进程（与 SIGKILL/SIGTERM 不同）
- 如果不是 attach 触发（没有 `.attach_pid` 文件），仍然执行默认行为（打印线程 dump），不影响正常功能
- SIGINT 已被终端使用（Ctrl+C），不适合

### Q3: premain 和 agentmain 能同时存在吗？

**回答**：

可以，而且推荐同时提供。一个 Agent JAR 的 MANIFEST.MF 可以同时包含 `Premain-Class` 和 `Agent-Class`（可以是同一个类或不同类）：

```
Premain-Class: com.example.MyAgent
Agent-Class: com.example.MyAgent
Can-Retransform-Classes: true
```

- 通过 `-javaagent` 启动时，JVM 读取 `Premain-Class` 调用 `premain()`
- 通过 Attach API 动态加载时，JVM 读取 `Agent-Class` 调用 `agentmain()`

每次加载都会创建独立的 `JPLISAgent` 和 `JvmtiEnv`，互不干扰。

### Q4: 动态加载 Agent 对性能有什么影响？

**回答**：

1. **加载过程**：一次性开销——dlopen、创建 JVMTI 环境、类加载。通常在毫秒级
2. **ClassFileLoadHook**：如果 Agent 注册了 Transformer，后续每次类加载都会触发回调。但如果没有 Transformer，ClassFileLoadHook 事件未启用（`should_post_class_file_load_hook = false`），零开销
3. **retransform**：调用 `retransformClasses` 时，需要在 Safepoint 下替换类定义、反优化 JIT 代码。频繁调用会有性能影响
4. **Attach Listener 线程**：常驻但阻塞在 accept()，不消耗 CPU

### Q5: 容器环境下 Attach 有什么特殊处理？

**回答**：

OpenJDK 11 的 `VirtualMachineImpl` 支持 Linux PID namespace：

1. **PID 映射**：通过读取 `/proc/<pid>/status` 中的 `NSpid` 字段获取容器内部 PID
2. **Socket 路径**：通过 `/proc/<pid>/root/tmp/.java_pid<ns_pid>` 访问目标进程的文件系统（穿越 mount namespace）
3. **Attach 文件**：创建在 `/proc/<pid>/cwd/` 或 `/proc/<pid>/root/tmp/` 下

这使得 Arthas 可以从宿主机 attach 到容器内的 JVM。

### Q6: Attach Listener 线程是一直存在的吗？

**回答**：

不是。Attach Listener 线程是**按需创建**的：

- 默认不启动（`init_at_startup()` 返回 false，除非 `+ReduceSignalUsage`）
- 第一次收到 attach 请求（SIGQUIT + `.attach_pid` 文件）时才创建
- 一旦创建就常驻（daemon 线程，不阻止 JVM 退出）
- Socket 文件被删除时会重新初始化（`check_socket_file()` 恢复机制）

---

## 18.13 模块 A 总结：libinstrument.so 闭环

四章内容形成完整闭环：

```
Ch15: Java Agent 机制
  → -javaagent 参数解析 → Agent_OnLoad → VMInit → premain()
  → ClassFileLoadHook 事件 → Transformer 链式调用

Ch16: retransformClasses 完整链路
  → Instrumentation API → JVMTI RetransformClasses → VM_RedefineClasses
  → 常量池合并 → 方法替换 → 反优化

Ch17: JVMTI 事件体系
  → 四层启用数据结构 → recompute_enabled → should_post_xxx
  → 两种分发模式 → interp_only_mode → Phase 控制

Ch18: agentmain 与动态 Attach（本章）
  → VirtualMachine.attach → SIGQUIT → AttachListener
  → load 命令 → Agent_OnAttach → agentmain()
  → 完整串联 Arthas/PerfMa 产品链路
```

### PerfMa 面试可覆盖的问题

| 问题 | 可用章节 |
|------|---------|
| Java Agent 怎么工作的？ | Ch15 |
| retransformClasses 底层做了什么？ | Ch16 |
| Arthas trace 命令底层原理？ | Ch15 + Ch16 |
| JVMTI 事件怎么分发的？ | Ch17 |
| 为什么调试模式会变慢？ | Ch17 (interp_only_mode) |
| Arthas 怎么连上目标 JVM？ | Ch18 |
| premain 和 agentmain 的区别？ | Ch15 + Ch18 |
| 动态 Agent 的安全机制？ | Ch18 |

---

*分析文件*：`src/java.instrument/share/native/libinstrument/InvocationAdapter.c` (Agent_OnAttach 入口)
*分析文件*：`src/java.instrument/share/native/libinstrument/JPLISAgent.c` (JPLISAgent 创建与初始化)
*分析文件*：`src/java.instrument/share/native/libinstrument/JPLISAgent.h` (方法名常量定义)
*分析文件*：`src/java.instrument/share/classes/sun/instrument/InstrumentationImpl.java` (loadClassAndCallAgentmain)
*分析文件*：`src/hotspot/share/services/attachListener.cpp` (AttachListener 初始化与命令分发)
*分析文件*：`src/hotspot/share/services/attachListener.hpp` (AttachOperation 定义)
*分析文件*：`src/hotspot/os/linux/attachListener_linux.cpp` (Unix Domain Socket 实现)
*分析文件*：`src/hotspot/share/prims/jvmtiExport.cpp` (load_agent_library)
*分析文件*：`src/hotspot/share/runtime/os.cpp` (SIGQUIT 处理)
*分析文件*：`src/jdk.attach/share/classes/sun/tools/attach/HotSpotVirtualMachine.java` (loadAgent → loadAgentLibrary)
*分析文件*：`src/jdk.attach/linux/classes/sun/tools/attach/VirtualMachineImpl.java` (SIGQUIT 握手 + 通信协议)
