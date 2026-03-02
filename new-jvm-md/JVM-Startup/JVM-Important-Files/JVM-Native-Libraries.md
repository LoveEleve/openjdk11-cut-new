# JVM 原生库 (SO 动态库) 重要文件

> **源码根目录**：`src/java.base/`  
> **重要程度**：⭐⭐⭐⭐⭐

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文是 **JVM 原生库 (SO 动态库) 重要文件** 的源码导航地图：列出该模块最重要的源码文件，说明每个文件的核心职责，帮助快速定位关键代码。

### 0.2 为什么需要？

JVM 源码体量庞大（HotSpot 约 200 万行），直接阅读容易迷失。有一份「重要文件地图」，能让学习者快速找到核心代码，避免在次要代码上浪费时间。

### 0.3 怎么解决？

按功能模块分类整理源码文件，标注每个文件的重要程度（⭐ 数量）和核心职责，并指出文件间的依赖关系。

### 0.4 为什么这样设计？

优先级排序基于「对理解 JVM 核心行为的贡献度」：直接影响 GC/JIT/类加载等核心机制的文件优先级最高。

---


## 核心引擎 (Tier 1)

### libjvm.so - JVM 核心

| 源码目录 | 核心文件 |
|---------|---------|
| `src/hotspot/share/` | 所有 HotSpot C++ 源码 |

### libjsig.so - 信号处理

| 源码目录 | 核心文件 |
|---------|---------|
| `src/java.base/unix/native/libjsig/` | `jsig.c`, `java_signal_md.c` |

| 文件名 | 核心功能 |
|-------|---------|
| `jsig.c` | 信号链实现，捕获所有信号并转发 |
| `java_signal_md.c` | 平台特定信号处理 |

### libattach.so - Attach 机制

| 源码目录 | 核心文件 |
|---------|---------|
| `src/java.base/unix/native/libattach/` | `AttachProvider_linux.c`, `AttachListener_linux.c`, `VirtualMachineImpl.c` |

---

## 基础服务 (Tier 2)

### libjava.so - 核心 Java 类

| 源码目录 | 核心文件 |
|---------|---------|
| `src/java.base/unix/native/libjava/` | `ProcessImpl_md.c`, `FileDescriptor_md.c`, `java_props_md.c` |

| 文件名 | 核心功能 |
|-------|---------|
| `ProcessImpl_md.c` | 进程创建和管理 |
| `FileDescriptor_md.c` | 文件描述符操作 |
| `java_props_md.c` | Java 系统属性 |
| `ObjectInputStream.c` | 对象序列化 native |
| `RuntimeImpl.c` | Runtime native |

### libnio.so - NIO

| 源码目录 | 核心文件 |
|---------|---------|
| `src/java.base/unix/native/libnio/ch/` | `EPollArrayWrapper.c`, `EPollPort.c`, `PollArrayWrapper.c` |
| `src/java.base/unix/native/libnio/linux/` | `LinuxNativeDispatcher.c`, `NativeThread.c` |

| 文件名 | 核心功能 |
|-------|---------|
| `EPollArrayWrapper.c` | epoll 数组封装 |
| `EPollPort.c` | epoll 多路复用 |
| `PollArrayWrapper.c` | poll 封装 |
| `LinuxNativeDispatcher.c` | Linux 原生调用 |
| `NativeThread.c` | 原生线程 |

### libnet.so - 网络

| 源码目录 | 核心文件 |
|---------|---------|
| `src/java.base/unix/native/libnet/` | `PlainSocketImpl.c`, `PlainDatagramSocketImpl.c`, `InetAddress.c` |

| 文件名 | 核心功能 |
|-------|---------|
| `PlainSocketImpl.c` | TCP Socket 实现 |
| `PlainDatagramSocketImpl.c` | UDP Socket 实现 |
| `InetAddress.c` | IP 地址处理 |
| `NetworkInterface.c` | 网络接口 |

### libzip.so - ZIP 压缩

| 源码目录 | 核心文件 |
|---------|---------|
| `src/java.base/share/native/libzip/` | `zlib-encoder.c`, `zlib-decoder.c`, `ZipFile.c` |

| 文件名 | 核心功能 |
|-------|---------|
| `zlib-encoder.c` | GZIP 编码 |
| `zlib-decoder.c` | GZIP 解码 |
| `ZipFile.c` | ZIP 文件读取 |

---

## 管理与安全 (Tier 3)

### libmanagement.so - JMX 管理

| 源码目录 | 核心文件 |
|---------|---------|
| `src/java.management/share/native/libmanagement/` | `management.c`, `memory.c`, `thread.c`, `gc.c` |

| 文件名 | 核心功能 |
|-------|---------|
| `management.c` | JMX 框架实现 |
| `memory.c` | 内存管理接口 |
| `thread.c` | 线程管理接口 |
| `gc.c` | GC 接口 |

### libj2gss.so - GSSAPI 安全

| 源码目录 | 核心文件 |
|---------|---------|
| `src/java.security.jgss/share/native/libj2gss/` | `GSSLibInit.c`, `NativeUtil.c` |

### libj2pcsc.so - 智能卡

| 源码目录 | 核心文件 |
|---------|---------|
| `src/java.smartcardio/share/native/libj2pcsc/` | `pcsc_md.c` |

---

## 启动与工具 (Tier 4)

### libjli.so - JVM 启动器

| 源码目录 | 核心文件 |
|---------|---------|
| `src/java.base/share/native/libjli/` | `java.c`, `java_md.c`, `jli_util.c` |
| `src/java.base/unix/native/libjli/` | `java_md_solinux.c` |

| 文件名 | 核心功能 |
|-------|---------|
| `java.c` | main 入口，参数解析 |
| `java_md.c` | JVM 加载逻辑 |
| `java_md_solinux.c` | Linux 特定启动代码 |
| `jli_util.c` | 工具函数 |

### libverify.so - 类验证

| 源码目录 | 核心文件 |
|---------|---------|
| `src/java.base/share/native/libverify/` | `verify.c`, `bytecode.c`, "alloc.c" |

| 文件名 | 核心功能 |
|-------|---------|
| `verify.c` | 字节码验证 native |
| `bytecode.c` | 字节码操作 |

### libinstrument.so - Java Agent

| 源码目录 | 核心文件 |
|---------|---------|
| `src/java.instrument/share/native/libinstrument/` | `JavaAgent.c`, `JPLISAgent.c`, `InvocationAdapter.c` |

| 文件名 | 核心功能 |
|-------|---------|
| `JavaAgent.c` | Agent 加载 |
| `JPLISAgent.c` | Java Agent 生命周期 |
| `InvocationAdapter.c` | 方法调用适配 |

### libsaproc.so - Serviceability Agent

| 源码目录 | 核心文件 |
|---------|---------|
| `src/jdk.hotspot.agent/share/native/libsaproc/` | `ps_core.c`, `ps_proc.c`, `ps_memory.c` |

| 文件名 | 核心功能 |
|-------|---------|
| `ps_core.c` | 进程核心文件读取 |
| `ps_proc.c` | 进程信息读取 |
| `ps_memory.c` | 内存读取 |

### libjimage.so - JDK 镜像

| 源码目录 | 核心文件 |
|---------|---------|
| `src/java.base/share/native/libjimage/` | `jimage.cpp`, `jimageFile.cpp`, `imageDecompressor.cpp` |

---

## SO 库依赖关系

```
┌──────────────────────────────────────────────────────────────┐
│                        用户代码                               │
└──────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────┐
│  libjli.so (启动器)                                         │
│  - 解析参数，加载 libjvm.so                                   │
└──────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────┐
│  libjvm.so (HotSpot)                                        │
│  - 执行引擎 (解释器/JIT)                                      │
│  - 内存管理 (GC)                                             │
│  - 线程管理                                                  │
│  - 信号处理 ← libjsig.so                                    │
│  - Attach  ← libattach.so                                   │
└──────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────┐
│  Java 核心类库                                              │
│  - libjava.so (Object, Thread, System, ...)                 │
│  - libnet.so (网络)                                         │
│  - libnio.so (NIO, epoll)                                  │
│  - libzip.so (压缩)                                         │
│  - libmanagement.so (JMX)                                   │
│  - libinstrument.so (Agent)                                 │
└──────────────────────────────────────────────────────────────┘
```

---

## 学习建议

| 优先级 | 库 | 核心文件 |
|--------|-----|---------|
| P0 | libjli.so | java.c, java_md_solinux.c |
| P0 | libinstrument.so | JPLISAgent.c |
| P0 | libnio.so | EPollArrayWrapper.c |
| P1 | libjava.so | ProcessImpl_md.c |
| P1 | libnet.so | PlainSocketImpl.c |
| P1 | libjsig.so | jsig.c |
| P2 | libmanagement.so | management.c |
