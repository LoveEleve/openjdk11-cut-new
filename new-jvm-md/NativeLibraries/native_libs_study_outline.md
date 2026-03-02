# Native Libraries 完整学习大纲

> 面向 PerfMa 岗位（JVM 开发专家 + 性能优化专家）
> 创建日期：2026-02-09
> 总计 38 个 .so，已分析 4 个（libjava + libnio + libnet + libjvm 间接），本大纲覆盖剩余重要 .so

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **Native Libraries 完整学习大纲**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 全局概览

### 源码规模统计

| .so 库 | 源码行数 | 涉及 HotSpot 代码 | 合计 | 分析状态 |
|--------|---------|-------------------|------|---------|
| libjvm.so | ~250,000 | — | 250K | ✅ 其他模块大量覆盖 |
| libjava.so | ~15,000 | — | 15K | ✅ ch14 已完成 |
| libnio.so + libnet.so | ~12,000 | — | 12K | ✅ ch01-ch13 已完成 |
| **libinstrument.so** | **5,792** | JVMTI 26,505 | **~32K** | ❌ 待分析 |
| **libattach.so** | **2,067** | AttachListener 1,259 | **~3.3K** | ❌ 待分析 |
| **libmanagement*.so** (3个) | **5,048** | services/ 20,012 | **~25K** | ❌ 待分析 |
| **libjli.so** | **9,879** | — | **~10K** | ❌ 待分析 |
| **libverify.so** | **4,661** | — | **~4.7K** | ⏭️ 跳过（面试不考/生产不用） |
| **libzip.so** | **16,835** | — | **~17K** | ✅ ch24 已完成 |
| **libjimage.so** | **2,823** | — | **~2.8K** | ✅ ch24 已完成 |
| **libjdwp.so** + libdt_socket.so | **26,881 + 2,016** | — | **~29K** | ❌ 待分析 |
| **libsaproc.so** | **10,263** | — | **~10K** | ❌ 待分析 |

### 学习顺序总览（按 PerfMa 面试价值排序）

```
┌──────────────────────────────────────────────────────────────────────┐
│                     Native Libraries 学习路线                        │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  模块 A: libinstrument.so — Java Agent / Instrumentation    ⭐⭐⭐⭐⭐  │
│  ┊ PerfMa 产品核心技术栈底层                                         │
│  ┊ 预计 4 篇文档 ~200KB                                              │
│  ┊                                                                   │
│  模块 B: libattach.so — Attach API                          ⭐⭐⭐⭐⭐  │
│  ┊ Arthas/async-profiler 运行时 attach 底层                          │
│  ┊ 预计 2 篇文档 ~90KB                                               │
│  ┊                                                                   │
│  模块 C: libmanagement*.so — JMX/MBean/诊断命令              ⭐⭐⭐⭐   │
│  ┊ 性能监控产品的基础设施                                             │
│  ┊ 预计 3 篇文档 ~140KB                                              │
│  ┊                                                                   │
│  模块 D: libjli.so — JVM 启动链路                            ⭐⭐⭐⭐   │
│  ┊ 补齐 CreateVM 之前 "java 命令→JVM" 的空白                        │
│  ┊ 预计 2 篇文档 ~90KB                                               │
│  ┊                                                                   │
│  模块 E: libzip + libjimage                                  ⭐⭐⭐    │
│  ┊ 类加载全链路补齐（读文件）✅ 已完成                                │
│  ┊ libverify 跳过（面试不考/生产不用）                                │
│  ┊                                                                   │
│  模块 F: libjdwp + libsaproc — 调试/诊断                    ⭐⭐⭐    │
│  ┊ 远程调试 + SA 进程分析                                            │
│  ┊ 预计 2 篇文档 ~90KB（选学）                                       │
│  ┊                                                                   │
│  ────────── 以下为低优先级，按需了解 ──────────                       │
│  libextnet / libsctp / librmi / libprefs                    ⭐⭐      │
│  libj2gss / libj2pkcs11 / libsunec / libjaas               ⭐       │
│  libawt* / libjsound / libsplashscreen / libjavajpeg        ⭐       │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 模块 A: libinstrument.so — Java Agent & Instrumentation ⭐⭐⭐⭐⭐

> **为什么最高优先级？**
> - PerfMa 的 XSea 线上诊断产品底层就是 Java Agent + Instrumentation + retransform
> - PerfMa 面试必问："你知道 Java Agent 底层是怎么实现的吗？retransformClasses 触发后 JVM 内部做了什么？"
> - 与你已有的 Rewriter/CPCache/Method::link_method/类加载系统 知识完美串联

### 源码清单

```
Native 层 (5,792 行):
├── share/native/libinstrument/
│   ├── JPLISAgent.c          — 核心！JPLIS Agent 完整实现
│   ├── JPLISAgent.h          — JPLISAgent 数据结构
│   ├── InvocationAdapter.c   — Agent 加载入口（premain/agentmain）
│   ├── InstrumentationImplNativeMethods.c — Instrumentation JNI 方法
│   ├── JavaExceptions.c/h    — JNI 异常处理
│   ├── JarFacade.c/h         — Agent jar 清单读取
│   ├── Reentrancy.c/h        — 重入保护
│   └── Utilities.c/h         — 工具函数
└── unix/native/libinstrument/
    └── FileSystemSupport_md.c

Java 层 (2,476 行):
├── java.lang.instrument.Instrumentation     — 顶层 API 接口
├── java.lang.instrument.ClassFileTransformer — 字节码转换器接口
├── java.lang.instrument.ClassDefinition      — 重定义类描述
├── sun.instrument.InstrumentationImpl        — Instrumentation 实现类
└── sun.instrument.TransformerManager         — Transformer 管理器

HotSpot JVMTI 层 (26,505 行，选读核心):
├── prims/jvmtiEnv.cpp           — JVMTI 函数实现入口
├── prims/jvmtiRedefineClasses.cpp — retransform/redefine 核心！
├── prims/jvmtiExport.cpp         — 事件回调分发
├── prims/jvmtiClassFileReconstituter.cpp — 类文件重建
└── prims/jvmtiImpl.cpp           — JVMTI 实现细节
```

### 章节划分

#### Ch15: Java Agent 机制 — 从 -javaagent 到 premain() (~50KB)

**问题驱动**：`java -javaagent:xxx.jar` 启动后，Agent 是怎么被加载和调用的？

| 小节 | 内容 | 源码文件 | 与已有知识串联 |
|------|------|---------|--------------|
| 15.1 Agent 加载总览 | 四种 Agent 类型对比（premain/agentmain/native agent/启动阶段 vs 运行时） | — | CreateVM 流程 |
| 15.2 启动阶段 Agent 加载 | `java.c` 中 `-javaagent` 参数解析 → `AddApplicationOptions()` → MANIFEST.MF 读取 `Premain-Class` | libjli/java.c | 补齐 libjli 启动链路 |
| 15.3 JPLIS Agent 初始化 | `Agent_OnLoad()` → `createNewJPLISAgent()` → JVMTI 环境获取 → 事件回调注册（`VMInit`/`ClassFileLoadHook`） | InvocationAdapter.c, JPLISAgent.c | JVMTI 事件体系 |
| 15.4 premain() 调用链路 | `VMInit` 回调 → `eventHandlerVMInit()` → `processJavaStart()` → JNI 反射调用 `premain(String, Instrumentation)` | JPLISAgent.c | JavaCalls 框架 (ch08) |
| 15.5 ClassFileLoadHook 钩子 | 类加载时 JVMTI 回调 → `transformClassFile()` → 遍历 TransformerManager → 调用用户的 `ClassFileTransformer.transform()` | JPLISAgent.c, jvmtiExport.cpp | ClassFileParser (ch08 defineClass) |
| 15.6 Instrumentation 能力协商 | `Can-Retransform-Classes`/`Can-Redefine-Classes` → JVMTI capabilities → 影响哪些 API 可用 | JPLISAgent.c | — |

**GDB 验证计划**：
- 断点 `Agent_OnLoad` 观察 Agent 加载时机
- 断点 `eventHandlerVMInit` 观察 premain 调用
- 断点 `eventHandlerClassFileLoadHook` 观察类加载拦截

---

#### Ch16: Instrumentation API 实现 — retransformClasses 完整链路 (~55KB)

**问题驱动**：`Instrumentation.retransformClasses(Class<?>...)` 调用后，JVM 内部做了什么？字节码是怎么被替换的？已编译的代码怎么办？

| 小节 | 内容 | 源码文件 | 与已有知识串联 |
|------|------|---------|--------------|
| 16.1 retransformClasses Java→JNI | `InstrumentationImpl.retransformClasses0()` → native `Java_sun_instrument_InstrumentationImplretransformClasses0` | InstrumentationImplNativeMethods.c | — |
| 16.2 JNI→JVMTI 桥接 | `retransformClasses()` → `jvmtiEnv::RetransformClasses()` → 参数校验 → 进入 VM 操作 | jvmtiEnv.cpp | VM_Operation 体系 (Safepoint ch01) |
| 16.3 VM_RedefineClasses 核心流程 | **最关键！** 8 步 doit_prologue + 8 步 doit：类文件重建 → ClassFileLoadHook 回调 → 新类解析 → 字段/方法比较 → 方法替换 → CPCache 调整 | jvmtiRedefineClasses.cpp | **Rewriter/CPCache/Method::link_method** |
| 16.4 方法替换细节 | `transfer_old_native_function_registrations()` → `ConstMethod` 替换策略 → `Method::set_code()` → entry point 更新 | jvmtiRedefineClasses.cpp | **解释器 entry points (ch3.3-3.6)** |
| 16.5 nmethod 失效 | `mark_dependent_nmethods()` → deoptimization → 编译代码如何回退到解释执行 | jvmtiRedefineClasses.cpp | **编译系统 / deopt_entry (ch8.0)** |
| 16.6 常量池合并 | `merge_cp_and_rewrite()` → old CP + new CP → merged CP → 字节码中常量池索引重写 | jvmtiRedefineClasses.cpp | **CPCache / Rewriter** |
| 16.7 retransform vs redefine 对比 | 两者的实现差异：redefine 直接替换 vs retransform 从原始字节码重新走 transform | jvmtiRedefineClasses.cpp | — |
| 16.8 限制与陷阱 | 不能增删字段/方法/改继承 → 为什么？(InstanceKlass 布局已固定/vtable/itable) | — | **klass_hierarchy.md** |

**GDB 验证计划**：
- 写一个简单的 retransform Agent，断点 `VM_RedefineClasses::doit()` 跟踪完整流程
- 观察 `ConstMethod` 替换前后的指针变化
- 观察 nmethod 失效 + deoptimization 触发

---

#### Ch17: JVMTI 事件体系 — 从 Agent 到 JVM 内部回调 (~45KB)

**问题驱动**：JVMTI 事件（如 ClassFileLoadHook, GarbageCollectionStart, MethodEntry）是怎么注册和分发的？

| 小节 | 内容 | 源码文件 | 与已有知识串联 |
|------|------|---------|--------------|
| 17.1 JVMTI 架构总览 | JVMTI 接口表 → JvmtiEnv 环境 → JvmtiEventController → 事件启用/禁用 | jvmtiEnv.cpp, jvmtiEventController.cpp | — |
| 17.2 事件注册与分发 | `SetEventNotificationMode()` → per-thread / global → `JvmtiExport::post_*()` 调用点分布 | jvmtiExport.cpp | 你在源码中到处看到的 `JvmtiExport::post_*` |
| 17.3 关键事件深入 | ClassFileLoadHook / ClassPrepare / VMObjectAlloc / GarbageCollectionStart-Finish / MethodEntry-Exit | jvmtiExport.cpp | G1 GC / 类加载 / 解释器 |
| 17.4 JVMTI 与 Safepoint | 哪些 JVMTI 操作需要 Safepoint？为什么 GetStackTrace 不需要但 RetransformClasses 需要？ | jvmtiEnvBase.cpp | **Safepoint 机制** |
| 17.5 JVMTI 开销分析 | 启用不同事件对 JVM 性能的影响：MethodEntry（极大开销） vs ClassFileLoadHook（轻量） | — | 性能调优视角 |

---

#### Ch18: Java Agent 高级话题 — agentmain + 动态 Attach Agent (~45KB)

**问题驱动**：Arthas 是怎么在运行时连上目标 JVM 并加载 Agent 的？

| 小节 | 内容 | 源码文件 | 与已有知识串联 |
|------|------|---------|--------------|
| 18.1 agentmain 加载流程 | VirtualMachine.loadAgent() → Attach API → `load` 命令 → `Agent_OnAttach()` → agentmain() | InvocationAdapter.c | **模块 B: libattach** |
| 18.2 premain vs agentmain 对比 | 加载时机/权限差异/capabilities 差异/MANIFEST.MF 属性 | JPLISAgent.c | — |
| 18.3 Native Agent (JVMTI Agent) | `-agentlib` / `-agentpath` → `Agent_OnLoad()` 直接入 JVMTI，无 JPLIS 层 | — | CreateVM 流程 |
| 18.4 多 Agent 共存 | Agent 加载顺序/TransformerManager 链式调用/ClassFileLoadHook 多 Agent 字节码传递 | TransformerManager.java | — |
| 18.5 面试专题 | 15 道 Java Agent + JVMTI 面试题（源码级回答） | — | — |

---

## 模块 B: libattach.so — Attach API ⭐⭐⭐⭐⭐

> **为什么最高优先级？**
> - Arthas / async-profiler / JVisualVM / jmap / jstack 运行时连接目标 JVM 的底层
> - PerfMa 面试标准问题："你知道 Arthas 是怎么连上目标 JVM 的吗？"
> - 源码量很小（~3.3K 行），性价比极高

### 源码清单

```
libattach 客户端 (2,067 行):
├── linux/native/libattach/VirtualMachineImpl.c  — Linux 实现（核心！）
└── (其他平台忽略)

HotSpot 服务端 (1,259 行):
├── share/services/attachListener.cpp   — AttachListener 抽象层
├── share/services/attachListener.hpp   — AttachOperation 定义
└── os/linux/attachListener_linux.cpp   — Linux Unix Domain Socket 实现

Java 层:
├── com.sun.tools.attach.VirtualMachine        — 顶层 API
├── sun.tools.attach.VirtualMachineImpl        — Linux 实现
└── com.sun.tools.attach.spi.AttachProvider    — SPI 发现
```

### 章节划分

#### Ch19: Attach API — 从 VirtualMachine.attach() 到 Unix Socket 通信 (~50KB)

**问题驱动**：`VirtualMachine.attach(pid)` 到底做了什么？Arthas 连接目标 JVM 的完整过程是什么？

| 小节 | 内容 | 源码文件 | 与已有知识串联 |
|------|------|---------|--------------|
| 19.1 Attach 机制总览 | 客户端-服务端架构 / Unix Domain Socket / .attach_pid 信号文件 / SIGQUIT 触发 | — | — |
| 19.2 客户端流程 | `VirtualMachine.attach(pid)` → `createAttachFile(/proc/pid/cwd/.attach_pid)` → `kill(SIGQUIT)` → 等待 `/tmp/.java_pidXXX` socket → `connect()` | VirtualMachineImpl.c (libattach) | — |
| 19.3 服务端启动 | `SIGQUIT` 信号 → `AttachListener::is_init_trigger()` → 创建 `AttachListener` 线程 → `socket()` + `bind(/tmp/.java_pidXXX)` + `listen()` | attachListener_linux.cpp | **线程系统** |
| 19.4 命令处理循环 | `AttachListener::dequeue()` → `accept()` → 读取命令（load/properties/jcmd/...） → 执行 → 返回结果 | attachListener.cpp | VMThread/VM_Operation |
| 19.5 load 命令 — Agent 加载 | `attach_listener_load_agent()` → `os::dll_load()` → `Agent_OnAttach()` | attachListener.cpp | **串联模块 A Ch18** |
| 19.6 Attach 操作汇总 | 所有支持的命令：load/properties/jcmd/datadump/threaddump/dumpheap/... | attachListener.cpp | — |
| 19.7 安全机制 | `.attach_pid` 文件权限检查 / `/tmp/.java_pidXXX` socket 权限 / 同一用户限制 | attachListener_linux.cpp | — |

---

#### Ch20: Attach 实战 — Arthas/jmap/jstack 底层原理 (~40KB)

**问题驱动**：jmap -histo、jstack、Arthas 的 trace/watch 命令，底层都是怎么到达 JVM 的？

| 小节 | 内容 | 源码文件 | 与已有知识串联 |
|------|------|---------|--------------|
| 20.1 jmap/jstack/jcmd 实现原理 | 都是通过 Attach API 发送命令 → AttachListener 处理 | — | — |
| 20.2 Arthas 启动流程拆解 | `arthas-boot.jar` → `VirtualMachine.attach()` → `loadAgent(arthas-agent.jar)` → `agentmain()` → `InstrumentationImpl` | — | **Ch18 agentmain** |
| 20.3 async-profiler attach 流程 | `AsyncProfiler.getInstance()` → `VirtualMachine.loadAgentPath(libasyncProfiler.so)` → `Agent_OnAttach()` → JVMTI 环境 | — | JVMTI 事件 |
| 20.4 JFR 动态启动 | `jcmd <pid> JFR.start` → Attach → DiagnosticCommand | — | — |
| 20.5 面试专题 | 10 道 Attach 相关面试题 | — | — |

---

## 模块 C: libmanagement*.so — JMX / MBean / 诊断 ⭐⭐⭐⭐

> **为什么高优先级？**
> - PerfMa 性能监控产品的底层数据来源就是 JMX MBean
> - GC 通知、内存池、线程 dump、VM 参数查询都走 libmanagement
> - 面试："JMX 监控数据是怎么从 JVM 内部获取的？"

### 源码清单

```
libmanagement.so (java.management 模块, ~2,500 行):
├── management.c           — JNI 注册 + JVM 连接
├── VMManagementImpl.c     — VM 指标获取
├── MemoryPoolImpl.c       — 内存池（Eden/Survivor/Old/Metaspace）
├── MemoryManagerImpl.c    — 内存管理器（GC 名称）
├── MemoryImpl.c           — 内存使用/GC 通知
├── GarbageCollectorImpl.c — GC 计数/耗时
├── ThreadImpl.c           — 线程 dump / deadlock 检测
├── ClassLoadingImpl.c     — 类加载计数
└── HotspotThread.c        — HotSpot 内部线程

libmanagement_ext.so (jdk.management 模块, ~1,600 行):
├── management_ext.c       — 注册
├── Flag.c                 — VM 参数查询/修改
├── DiagnosticCommandImpl.c — jcmd 诊断命令
├── GcInfoBuilder.c        — GC 详细信息
├── GarbageCollectorExtImpl.c — GC 扩展信息
├── HotSpotDiagnostic.c    — 堆 dump / VM 参数
└── OperatingSystemImpl.c  — OS 指标（CPU/内存）

libmanagement_agent.so (~300 行):
└── FileSystemImpl.c       — 配置文件权限检查

HotSpot services/ 层 (选读核心, ~20,000 行):
├── management.cpp/hpp     — JMX 初始化 + 指标收集
├── gcNotifier.cpp         — GC 通知 → JMX
├── lowMemoryDetector.cpp  — 内存阈值告警
├── heapDumper.cpp         — 堆 dump 实现
├── diagnosticCommand.cpp  — jcmd 命令注册
└── diagnosticFramework.cpp — 诊断框架
```

### 章节划分

#### Ch21: JMX 底层实现 — 从 MBean 到 JVM 内部数据 (~50KB)

**问题驱动**：`ManagementFactory.getGarbageCollectorMXBeans()` 返回的 GC 信息是怎么从 HotSpot 内部获取的？

| 小节 | 内容 | 源码文件 | 与已有知识串联 |
|------|------|---------|--------------|
| 21.1 JMX 架构总览 | Platform MBean → MBeanServer → JMX Agent → 远程连接（RMI/REST） | — | — |
| 21.2 Management 初始化 | `management.cpp::Management::initialize()` → 注册内存池/GC/线程 MBean | management.cpp | CreateVM 流程 |
| 21.3 内存池 MXBean | MemoryPoolMXBean → MemoryPoolImpl.c → `jmm_GetMemoryPoolUsage()` → G1 各区域使用量 | MemoryPoolImpl.c, management.cpp | **G1 GC 系统** |
| 21.4 GC MXBean | GarbageCollectorMXBean → `getCollectionCount()/Time()` → jmm 接口 → G1 内部计数器 | GarbageCollectorImpl.c | **G1Policy/G1Analytics** |
| 21.5 GC 通知机制 | `GCNotifier::pushNotification()` → `GarbageCollectionNotificationInfo` → JMX 事件 → 用户监听器 | gcNotifier.cpp | **Young GC/Mixed GC 流程** |
| 21.6 线程 MXBean | ThreadMXBean → `ThreadImpl.c` → `Thread.getStackTrace()` / deadlock 检测 → jmm 接口 | ThreadImpl.c | **线程系统** |
| 21.7 低内存检测 | LowMemoryDetector → 阈值检查 → 通知 → MemoryPoolMXBean.setUsageThreshold() | lowMemoryDetector.cpp | G1 内存管理 |

---

#### Ch22: 诊断命令与堆 Dump — jcmd / jmap 底层 (~45KB)

**问题驱动**：`jcmd <pid> GC.heap_dump` 是怎么生成 .hprof 文件的？

| 小节 | 内容 | 源码文件 | 与已有知识串联 |
|------|------|---------|--------------|
| 22.1 DiagnosticCommand 框架 | `DCmdFactory` → 命令注册 → `DCmd::execute()` → Attach/jcmd 触发 | diagnosticCommand.cpp, diagnosticFramework.cpp | **模块 B: Attach** |
| 22.2 jcmd 命令实现 | GC.run / GC.heap_info / Thread.print / VM.flags / VM.info / Compiler.codecache | diagnosticCommand.cpp | 各已有模块 |
| 22.3 堆 Dump 实现 | `HeapDumper::dump()` → 遍历 GC roots → 遍历堆对象 → HPROF 格式写入 → 压缩支持 | heapDumper.cpp | **G1 堆布局/对象头** |
| 22.4 VM Flag 动态修改 | `Flag.c` → `JVMFlag::find_flag()` → `JVMFlag::set_*()` → manageable 标志 → 哪些参数能在线改 | Flag.c, management.cpp | Arguments 解析 |
| 22.5 OS 指标采集 | OperatingSystemMXBean → `/proc/stat` CPU / `/proc/meminfo` 内存 → JVM 进程指标 | OperatingSystemImpl.c | Linux 系统 |

---

#### Ch23: JMX 面试专题 + 监控实战 (~40KB)

| 小节 | 内容 |
|------|------|
| 23.1 面试 Q&A | 12 道 JMX/监控 相关面试题 |
| 23.2 自定义 MBean 示例 | 如何注册自定义 MBean 监控业务指标 |
| 23.3 JMX Remote 安全配置 | RMI/SSL/认证 |
| 23.4 JMX vs JVMTI vs Attach | 三种诊断手段对比 |

---

## 模块 D: libjli.so — JVM 启动链路 ⭐⭐⭐⭐

> **为什么高优先级？**
> - 补齐 CreateVM 之前的"java 命令怎么变成 JVM 进程"的空白
> - 面试："输入 `java -jar xxx.jar` 回车后发生了什么？"
> - 与你已有的 CreateVM 系列完美衔接

### 源码清单

```
libjli.so (9,879 行):
├── share/native/libjli/
│   ├── java.c              — 核心！main()→JLI_Launch()→JavaMain()
│   ├── java.h              — 函数声明
│   ├── args.c              — @argfile 参数文件解析
│   ├── parse_manifest.c    — MANIFEST.MF 解析（Main-Class 等）
│   ├── manifest_info.h     — Manifest 结构
│   ├── wildcard.c          — classpath 通配符展开
│   ├── splashscreen_stubs.c — 启动画面（忽略）
│   └── emessages.h         — 错误消息
└── unix/native/libjli/
    ├── java_md_solinux.c   — Linux 平台: JVM 路径查找/dlopen
    ├── java_md_common.c    — 公共平台代码
    └── java_md_solinux.h
```

### 章节划分

#### Ch24: JVM 启动全链路 — 从 `java` 命令到 CreateJavaVM() (~50KB)

**问题驱动**：输入 `java -Xmx8g -jar app.jar` 回车后，操作系统到 JVM 创建之间发生了什么？

| 小节 | 内容 | 源码文件 | 与已有知识串联 |
|------|------|---------|--------------|
| 24.1 总览：启动 10 步 | execve → libjli → 查找 libjvm → dlopen → JNI_CreateJavaVM → JavaMain | java.c | — |
| 24.2 main()→JLI_Launch() | 参数解析 → JRE 版本选择 → 重新 execv 自身 | java.c | — |
| 24.3 JVM 路径查找 | `GetJREPath()` → `GetJVMPath()` → `{jre}/lib/server/libjvm.so` → 路径拼接策略 | java_md_solinux.c | — |
| 24.4 dlopen libjvm.so | `LoadJavaVM()` → `dlopen(libjvm.so)` → `dlsym("JNI_CreateJavaVM")` + `dlsym("JNI_GetDefaultJavaVMInitArgs")` | java_md_solinux.c | — |
| 24.5 JavaMain() 线程 | `ContinueInNewThread()` → `pthread_create()` → `JavaMain()` → `InitializeJVM()` → `JNI_CreateJavaVM()` | java.c | **→串联 CreateVM 系列** |
| 24.6 Main-Class 查找 | `GetMainClassName()` → Manifest 解析 / 命令行类名 → `LoadMainClass()` → `FindClass()` | java.c, parse_manifest.c | **类加载系统** |
| 24.7 main() 方法调用 | `(*env)->GetStaticMethodID("main")` → `(*env)->CallStaticVoidMethod()` → Java 程序启动 | java.c | **JavaCalls (ch08)** |
| 24.8 JVM 退出 | `LEAVE()` → `(*vm)->DestroyJavaVM()` → `Threads::destroy_vm()` → 等待所有非守护线程 | java.c | 线程系统 |

---

#### Ch25: 参数处理与多 JVM 支持 (~35KB)

| 小节 | 内容 | 源码文件 | 与已有知识串联 |
|------|------|---------|--------------|
| 25.1 @argfile 展开 | `args.c` → 文件参数展开 → 引号/转义处理 | args.c | — |
| 25.2 -X/-XX 参数传递 | libjli 如何将参数传给 `JNI_CreateJavaVM` → `JavaVMInitArgs` 结构 | java.c | **Arguments::parse()** |
| 25.3 classpath 处理 | -cp / -classpath / CLASSPATH 环境变量 / 通配符展开 | wildcard.c | 类加载系统 |
| 25.4 -javaagent 处理 | `AddApplicationOptions()` → 转为 `-Djavax.tools.javaagent=...` | java.c | **串联模块 A** |
| 25.5 面试专题 | 8 道启动链路面试题 | — | — |

---

## 模块 E: libzip + libjimage — 类加载基础设施 ⭐⭐⭐ ✅ 已完成

> **覆盖内容**：
> - Ch24 已完成 libzip.so（深入）+ libjimage.so（轻量覆盖）
> - libverify.so **跳过**（字节码验证规则检查，面试不考、生产不用、源码重复模式多）

### 已完成章节

#### Ch24: libzip.so + libjimage.so — 类路径资源读取 ✅

已输出到 `NativeLibs/ch24_libzip_libjimage_class_resource.md`，覆盖：
- ZIP 格式基础（LOC/CEN/END）+ jzfile/jzentry/jzcell 核心数据结构
- ZIP_Open → readCEN → 哈希表构建 + mmap CEN 优化
- ZIP_GetEntry2 哈希链遍历 + ZIP_ReadEntry 读取/解压
- libjimage 6 API + Perfect Hash O(1) 查找 + ImageLocation 属性压缩流
- ClassPathEntry 三级继承 + ClassLoader::load_class 三级搜索 + 函数指针 dlsym 绑定
- 面试 Q&A（6 题）

---

## 模块 F: libjdwp.so + libsaproc.so — 调试与诊断（选学）⭐⭐⭐

> 优先级较低，但如果时间允许，这两个对理解诊断工具链很有价值

### 章节划分

#### Ch29: libjdwp.so — JDWP 调试协议 (~45KB)（选学）

| 小节 | 内容 |
|------|------|
| 29.1 JDWP 架构 | Front-end (IDE) ↔ Transport (dt_socket) ↔ Back-end (JDWP) ↔ JVMTI |
| 29.2 传输层 | libdt_socket.so → TCP 连接 → 数据包格式 |
| 29.3 命令处理 | 断点设置/单步/变量查看/线程控制 → JVMTI 调用 |
| 29.4 远程调试配置 | `-agentlib:jdwp=transport=dt_socket,server=y,...` 参数解析 |

#### Ch30: libsaproc.so — Serviceability Agent (~40KB)（选学）

| 小节 | 内容 |
|------|------|
| 30.1 SA 架构 | 进程外分析：ptrace attach → 读取目标进程内存 → 重建 JVM 数据结构 |
| 30.2 jhsdb 工具 | `jhsdb clhsdb` / `jhsdb jmap` / `jhsdb jstack` → 底层都是 SA |
| 30.3 核心 dump 分析 | SA 分析 core dump 文件 → 离线诊断 |

---

## 时间估算与里程碑

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        学习计划时间线                                      │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  模块 A: libinstrument (4 篇)                                             │
│  ├── Ch15: Java Agent 机制          预计 1 次对话  ────── 🎯 里程碑 1     │
│  ├── Ch16: retransformClasses 链路  预计 1-2 次对话 ────── 🎯 里程碑 2    │
│  ├── Ch17: JVMTI 事件体系           预计 1 次对话   ─┐                    │
│  └── Ch18: agentmain + 高级话题     预计 1 次对话   ─┤── 🎯 里程碑 3     │
│                                                                          │
│  模块 B: libattach (2 篇)                                                 │
│  ├── Ch19: Attach API 完整链路      预计 1 次对话  ────── 🎯 里程碑 4     │
│  └── Ch20: Attach 实战             预计 1 次对话  ────── 🎯 里程碑 5     │
│                                                                          │
│  -------- 到这里可面试 PerfMa 诊断类问题（Agent + Attach 闭环）--------    │
│                                                                          │
│  模块 C: libmanagement (3 篇)                                             │
│  ├── Ch21: JMX 底层实现             预计 1 次对话  ────── 🎯 里程碑 6     │
│  ├── Ch22: 诊断命令与堆 Dump        预计 1 次对话  ─┐                     │
│  └── Ch23: JMX 面试专题             预计 1 次对话  ─┤── 🎯 里程碑 7      │
│                                                                          │
│  模块 D: libjli (2 篇)                                                    │
│  ├── Ch24: 启动全链路               预计 1 次对话  ────── 🎯 里程碑 8     │
│  └── Ch25: 参数处理                 预计 1 次对话  ────── 🎯 里程碑 9     │
│                                                                          │
│  -------- 到这里 CreateVM 从命令行到 main() 全部打通 --------              │
│                                                                          │
│  模块 E: libverify + libzip + libjimage (3 篇)                            │
│  ├── Ch26: 字节码验证器             预计 1 次对话  ────── 🎯 里程碑 10    │
│  ├── Ch27: 类文件读取               预计 1 次对话  ─┐                     │
│  └── Ch28: 全链路总结               预计 1 次对话  ─┤── 🎯 里程碑 11     │
│                                                                          │
│  -------- 到这里类加载从文件到内存全部打通 --------                        │
│                                                                          │
│  模块 F: libjdwp + libsaproc (2 篇，选学)                                 │
│  ├── Ch29: JDWP 调试协议           预计 1 次对话  ─┐                     │
│  └── Ch30: SA 进程分析             预计 1 次对话  ─┤── 🎯 里程碑 12     │
│                                                                          │
│  总计: 16 篇文档 / ~740KB / 约 12-16 次对话                               │
│  完成后 Native Libraries 覆盖率: 38% → ~85%                               │
└──────────────────────────────────────────────────────────────────────────┘
```

## 完成后的知识体系串联

```
                     java -javaagent:agent.jar -jar app.jar
                                    │
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
              [Ch24: libjli]  [Ch15: Agent]   [Ch25: args]
              启动链路         Agent 加载       参数处理
                    │               │               │
                    └───────┬───────┘               │
                            ▼                       │
                    [CreateVM 系列: 已有]  ◄─────────┘
                    init_globals / universe
                            │
                    ┌───────┼───────┐
                    ▼       ▼       ▼
              [Ch27:zip]  [Ch27:jimage]  [Ch26:verify]
              读 jar       读模块镜像     字节码验证
                    │       │               │
                    └───────┤───────────────┘
                            ▼
                    [ClassFileParser: 已有]
                    解析 → 链接 → 初始化
                            │
                    ┌───────┼───────┐
                    ▼       ▼       ▼
              [解释器: 已有]  [C1/C2: 已有]  [Ch16: retransform]
              字节码执行       JIT 编译        运行时字节码替换
                            │
                    ┌───────┼───────┐
                    ▼       ▼       ▼
              [Ch21: JMX]  [Ch22: dump]  [Ch19: Attach]
              监控数据       堆 dump        运行时连接
                    │       │               │
                    └───────┤───────────────┘
                            ▼
                    [Arthas / async-profiler / PerfMa XSea]
                           生产诊断
```

---

*该大纲将随学习进展持续更新*
