# JVM 原生库（so 库）全景研究路线图

> **研究目标**：全面掌握 JVM 原生库体系，为 Arthas/Async-Profiler 二次开发打下基础  
> **研究范围**：OpenJDK 11 所有核心 so 库的源码、机制、交互关系  
> **预计周期**：40-60 小时，分 4 个阶段逐步攻克

---

## 目录

1. [JVM 原生库全景图](#1-jvm-原生库全景图)
2. [四大类库梳理](#2-四大类库梳理)
3. [学习路线图（4阶段）](#3-学习路线图4阶段)
4. [详细学习大纲](#4-详细学习大纲)
5. [实战应用场景](#5-实战应用场景)

---

## 1. JVM 原生库全景图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          JVM 原生库全景架构                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   启动层 (Bootstrap)                                                         │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │  libjli.so       Java Launcher Interface                           │  │
│   │  ├─ 解析命令行参数                                                   │  │
│   │  ├─ 选择 JVM 类型 (client/server)                                  │  │
│   │  └─ 加载 libjvm.so                                                  │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                              │                                              │
│                              ▼                                              │
│   核心层 (Core Engine)       ┌─────────────────────────────────────────┐   │
│   ┌──────────────────────┐   │  libjvm.so                              │   │
│   │  libjsig.so          │◄──┤  ├─ 虚拟机引擎（解释器/JIT）            │   │
│   │  ├─ 信号链机制       │   │  ├─ GC (垃圾回收器)                      │   │
│   │  └─ 信号处理转发     │   │  ├─ 内存管理 (堆/元空间)                 │   │
│   └──────────────────────┘   │  ├─ 线程管理                             │   │
│                              │  ├─ 类加载子系统                         │   │
│   ┌──────────────────────┐   │  ├─ JVMTI (工具接口)                     │   │
│   │  libattach.so        │◄──┤  ├─ Attach 机制                          │   │
│   │  ├─ Unix Socket      │   │  ├─ 编译器 (C1/C2)                       │   │
│   │  └─ 动态 Attach      │   │  └─ 运行时服务                           │   │
│   └──────────────────────┘   └─────────────────────────────────────────┘   │
│                                                                             │
│   基础层 (Foundation)                                                        │
│   ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐    │
│   │ libjava.so   │ │ libnio.so    │ │ libnet.so    │ │ libzip.so    │    │
│   │ ├─ Object    │ │ ├─ FileChnl  │ │ ├─ Socket    │ │ ├─ Inflate   │    │
│   │ ├─ System    │ │ ├─ DirectBuf │ │ ├─ NetAddr   │ │ ├─ Deflate   │    │
│   │ ├─ ClassLd   │ │ ├─ MmapFile  │ │ └─ IOUtil    │ │ └─ ZIP_Crypt │    │
│   │ └─ Thread    │ │ └─ EPoll     │ │              │ │              │    │
│   └──────────────┘ └──────────────┘ └──────────────┘ └──────────────┘    │
│                                                                             │
│   管理层 (Management)                                                        │
│   ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐          │
│   │ libmanagement.so │ │ libj2pcsc.so     │ │ libj2gss.so      │          │
│   │ ├─ JMX Native    │ │ ├─ 智能卡        │ │ ├─ Kerberos      │          │
│   │ ├─ MemoryPool    │ │ └─ PC/SC         │ │ └─ GSS-API       │          │
│   │ └─ GC Notifier   │ │                  │ │                  │          │
│   └──────────────────┘ └──────────────────┘ └──────────────────┘          │
│                                                                             │
│   扩展层 (Extension)                                                         │
│   ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐    │
│   │ libawt.so    │ │ libfontmgr.so│ │ libjpeg.so   │ │ libjsound.so │    │
│   │ (GUI)        │ │ (字体)        │ │ (图像)        │ │ (音频)        │    │
│   └──────────────┘ └──────────────┘ └──────────────┘ └──────────────┘    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 四大类库梳理

### 2.1 核心引擎类（Tier 1 - 必须精通）

| 库名 | 路径 | 源码位置 | 重要度 | Arthas/Async-Profiler 关联 |
|------|------|----------|--------|---------------------------|
| **libjvm.so** | `lib/server/libjvm.so` | `src/hotspot/` | ⭐⭐⭐⭐⭐ | JVMTI、Attach、VMStructs、符号表 |
| **libjsig.so** | `lib/libjsig.so` | `src/hotspot/os/posix/jvm_posix.cpp` | ⭐⭐⭐⭐ | 信号链，perf_event 信号处理 |
| **libattach.so** | `lib/libattach.so` | `src/jdk.attach/linux/native/` | ⭐⭐⭐⭐ | Unix Socket，Attach 协议 |

### 2.2 基础服务类（Tier 2 - 重要）

| 库名 | 路径 | 源码位置 | 重要度 | 关键功能 |
|------|------|----------|--------|----------|
| **libjava.so** | `lib/libjava.so` | `src/java.base/share/native/libjava/` | ⭐⭐⭐⭐ | Object、System、ClassLoader |
| **libnio.so** | `lib/libnio.so` | `src/java.base/share/native/libnio/` | ⭐⭐⭐ | FileChannel、DirectBuffer、EPoll |
| **libnet.so** | `lib/libnet.so` | `src/java.base/unix/native/libnet/` | ⭐⭐⭐ | Socket、NetworkInterface |
| **libzip.so** | `lib/libzip.so` | `src/java.base/share/native/libzip/` | ⭐⭐⭐ | Inflate/Deflate、ZIP 解压 |

### 2.3 管理层类（Tier 3 - 了解）

| 库名 | 路径 | 功能 | 重要度 |
|------|------|------|--------|
| **libmanagement.so** | `lib/libmanagement.so` | JMX、内存池监控 | ⭐⭐⭐ |
| **libmanagement_agent.so** | `lib/libmanagement_agent.so` | JMX Agent | ⭐⭐ |
| **libj2pcsc.so** | `lib/libj2pcsc.so` | 智能卡支持 | ⭐ |
| **libj2gss.so** | `lib/libj2gss.so` | Kerberos/GSS | ⭐ |

### 2.4 启动与辅助类（Tier 4 - 了解）

| 库名 | 路径 | 功能 | 重要度 |
|------|------|------|--------|
| **libjli.so** | `bin/../lib/libjli.so` | Java 启动器 | ⭐⭐⭐ |
| **libverify.so** | `lib/libverify.so` | 字节码验证 | ⭐⭐ |
| **libinstrument.so** | `lib/libinstrument.so` | Java Agent 支持 | ⭐⭐⭐ |

---

## 3. 学习路线图（4阶段）

### 阶段一：核心引擎（10-15 小时）

```
目标：深入理解 libjvm.so 核心机制

1. libjvm.so 整体架构
   ├── JVM 启动流程（已分析）
   ├── 内存管理子系统（已分析 G1）
   ├── 线程管理系统（已分析 VMThread 等）
   └── 类加载子系统

2. JVMTI 机制深度分析
   ├── JVMTI 接口定义
   ├── Agent 加载流程
   ├── 事件回调机制
   └── 与 Arthas 的交互

3. Attach 机制深度分析（已完成）
   ├── Unix Domain Socket
   ├── AttachListener
   └── 命令分发

4. VMStructs 与符号表
   ├── VMStructs 数据结构
   ├── 类型映射机制
   └── Async-Profiler 如何读取
```

### 阶段二：信号与监控（8-12 小时）

```
目标：掌握信号链和性能监控机制

1. libjsig.so - 信号链机制
   ├── Unix 信号基础
   ├── 信号链（Signal Chaining）
   ├── HotSpot 信号处理
   │   ├── SIGSEGV → NullPointerException
   │   ├── SIGBUS → StackOverflowError
   │   └── SIGILL → 分发到 Safepoint
   └── Async-Profiler 的信号处理

2. perf_event 机制
   ├── perf_event_open 系统调用
   ├── 硬件计数器（PMC）
   ├── 软件事件
   └── ring buffer 数据读取

3. AsyncGetCallTrace
   ├── 栈帧遍历原理
   ├── 与标准 unwind 的区别
   └── 安全点问题
```

### 阶段三：基础服务库（10-15 小时）

```
目标：理解基础 native 方法实现

1. libjava.so - Java 基础
   ├── Object.hashCode() native 实现
   ├── System.arraycopy() 优化
   ├── ClassLoader native 方法
   └── Thread 线程操作

2. libnio.so - NIO 核心
   ├── FileChannel 内存映射
   ├── DirectBuffer 管理
   │   ├── 堆外内存分配
   │   ├── Cleaner 机制
   │   └── 内存泄漏风险
   ├── EPollSelector 实现
   └── 零拷贝（sendfile）

3. libnet.so - 网络编程
   ├── Socket 原生方法
   ├── 非阻塞 IO 支持
   └── 网络接口枚举

4. libzip.so - 压缩库
   ├── Inflate/Deflate
   ├── JAR 文件解压优化
   └── 启动加速（类预加载）
```

### 阶段四：实战与工具（10-15 小时）

```
目标：整合知识，深入 Arthas/Async-Profiler 原理

1. Arthas 原理剖析
   ├── Agent 注入机制
   ├── Instrument 字节码增强
   ├── Ognl 表达式解析
   ├── JMX 数据采集
   └── 命令实现详解
       ├── trace（方法追踪）
       ├── profiler（性能分析）
       ├── jad（反编译）
       └── redefine（热更新）

2. Async-Profiler 原理
   ├── 多模式采样
   │   ├── cpu（itimer/perf_event）
   │   ├── alloc（TLAB 追踪）
   │   ├── lock（竞争分析）
   │   └── wall-clock
   ├── 栈回溯算法
   │   ├── FP-based（帧指针）
   │   ├── DWARF-based
   │   └── 混合模式
   ├── 火焰图生成
   └── 与 Arthas 集成

3. 动手实践
   ├── 编写简单 JVMTI Agent
   ├── 实现自定义 profiler
   └── 修改 Arthas 源码
```

---

## 4. 详细学习大纲

### 文档 1：libjvm.so 全景分析（Tier 1）

**章节大纲：**
```
第 1 章：libjvm.so 架构概览
  1.1 动态库结构分析
  1.2 导出符号表解读
  1.3 与 Java 层的交互边界

第 2 章：JVMTI 深度剖析
  2.1 JVMTI 架构与生命周期
  2.2 Agent 加载流程（OnLoad）
  2.3 事件机制（Event Callbacks）
  2.4 类文件转换（ClassFileLoadHook）
  2.5 内存与线程监控

第 3 章：Attach 机制全解析
  3.1 Unix Domain Socket 通信
  3.2 Attach 协议详解
  3.3 命令分发与执行
  3.4 安全机制

第 4 章：VMStructs 与符号表
  4.1 VMStructs 数据结构
  4.2 类型安全映射
  4.3 Async-Profiler 读取实现
  4.4 HSDB（HotSpot Debugger）原理

第 5 章：运行时服务
  5.1 JNI 调用约定
  5.2 异常处理机制
  5.3 安全点（Safepoint）协作
```

### 文档 2：libjsig.so 与信号处理（Tier 1-2）

**章节大纲：**
```
第 1 章：Unix 信号基础
  1.1 信号概念与类型
  1.2 信号处理函数（sigaction）
  1.3 信号掩码与阻塞

第 2 章：信号链（Signal Chaining）
  2.1 为什么需要信号链
  2.2 libjsig.so 实现原理
  2.3 信号转发机制
  2.4 与 libjvm.so 的协作

第 3 章：HotSpot 信号处理
  3.1 SIGSEGV → NullPointerException
  3.2 SIGBUS → StackOverflowError
  3.3 SIGILL/SIGFPE 处理
  3.4 用户信号（SIGUSR1/SIGUSR2）

第 4 章：Async-Profiler 信号机制
  4.1 perf_event 信号处理
  4.2 信号频率控制
  4.3 信号安全（Signal Safety）
  4.4 避免死锁与递归
```

### 文档 3：基础服务库群（Tier 2）

**章节大纲：**
```
第 1 章：libjava.so - Java 基础
  1.1 Object native 方法
  1.2 System 类实现
  1.3 ClassLoader native 支持
  1.4 Thread 线程管理

第 2 章：libnio.so - NIO 核心
  2.1 FileChannel 与内存映射
  2.2 DirectBuffer 堆外内存管理
  2.3 Cleaner 替代 Finalize
  2.4 EPollSelector 实现
  2.5 零拷贝技术

第 3 章：libnet.so - 网络编程
  3.1 Socket 原生封装
  3.2 非阻塞 IO 支持
  3.3 网络接口操作

第 4 章：libzip.so - 压缩库
  4.1 Inflate/Deflate 算法
  4.2 JAR 文件优化
  4.3 启动加速（CDS）
```

### 文档 4：Arthas 原理与实战（整合应用）

**章节大纲：**
```
第 1 章：Arthas 整体架构
  1.1 启动与 Attach 流程
  1.2 Agent 加载与初始化
  1.3 命令分发机制
  1.4 数据传输协议

第 2 章：字节码增强（Instrumentation）
  2.1 Java Agent 基础
  2.2 ClassFileTransformer
  2.3 ASM 字节码操作
  2.4 方法注入技巧

第 3 章：核心命令实现
  3.1 trace（方法追踪）
  3.2 watch（数据观测）
  3.3 profiler（性能分析）
  3.4 jad（反编译）
  3.5 redefine（热更新）

第 4 章：Async-Profiler 集成
  4.1 多模式采样原理
  4.2 栈回溯实现
  4.3 火焰图生成
  4.4 与 Arthas 的协作

第 5 章：实战与定制
  5.1 编写自定义命令
  5.2 扩展 Arthas 功能
  5.3 源码修改与编译
```

---

## 5. 实战应用场景

### 场景 1：性能调优

```
问题：应用 CPU 飙高，如何定位？

使用库：
├── libjvm.so (JIT 编译、GC)
├── libnio.so (IO 瓶颈)
├── libjsig.so (信号采样)
└── Async-Profiler (perf_event)

分析流程：
1. Async-Profiler cpu 采样 → 火焰图
2. 识别热点方法
3. 结合 JIT 编译日志（libjvm）
4. 检查 NIO 阻塞（libnio EPoll）
```

### 场景 2：内存泄漏排查

```
问题：堆外内存泄漏（DirectBuffer）

使用库：
├── libnio.so (DirectBuffer 分配)
├── libjava.so (Cleaner 机制)
├── libjvm.so (堆外内存统计)
└── Arthas (内存分析)

分析流程：
1. Arthas memory 命令查看 DirectBuffer
2. pmap 查看进程内存分布
3. 分析 Cleaner 队列长度
4. 定位未释放的 DirectBuffer
```

### 场景 3：疑难 Crash 分析

```
问题：JVM 崩溃，生成 hs_err_pid.log

使用库：
├── libjvm.so (VMError)
├── libjsig.so (信号处理)
└── libjava.so (异常传播)

分析流程：
1. 分析 hs_err_pid.log
2. 查看信号类型（SIGSEGV/SIGBUS）
3. 检查栈回溯（libjsig 信号链）
4. 使用 HSDB 分析 core dump
```

### 场景 4：Agent 开发

```
目标：开发自定义监控 Agent

涉及库：
├── libjvm.so (JVMTI)
├── libinstrument.so (Java Agent)
└── libattach.so (动态 Attach)

开发流程：
1. 编写 Agent_OnLoad
2. 注册 JVMTI 事件回调
3. 字节码增强（ClassFileLoadHook）
4. 数据上报
```

---

## 附录：重要数据结构速查

### libjvm.so 关键导出符号

```c
// JVMTI
JNIEXPORT jint JNICALL Agent_OnLoad(JavaVM *vm, char *options, void *reserved);
JNIEXPORT jint JNICALL JNI_GetDefaultJavaVMInitArgs(void *args);
JNIEXPORT jint JNICALL JNI_CreateJavaVM(JavaVM **pvm, JNIEnv **penv, void *args);

// Attach
JNIEXPORT jint JNICALL JVM_AttachCurrentThread(JavaVM *vm, void **penv, void *args);

// 内部符号（通过 VMStructs 访问）
struct VMStructEntry {
    const char* typeName;
    const char* fieldName;
    void* address;
};
```

### 常用调试命令

```bash
# 查看 so 库导出符号
nm -D $JAVA_HOME/lib/server/libjvm.so | grep JVMTI

# 查看进程加载的 so
cat /proc/<pid>/maps | grep '\.so'

# 使用 ltrace 追踪库调用
ltrace -e getenv java -version

# 使用 strace 追踪系统调用
strace -f -e trace=network java MyApp

# 查看动态链接依赖
readelf -d $JAVA_HOME/bin/java | grep NEEDED
```

---

**制定完成时间**：2025年2月  
**建议启动阶段**：阶段一（libjvm.so 核心机制）

**你想从哪个阶段开始？** 我可以立即开始撰写对应的详细分析文档。