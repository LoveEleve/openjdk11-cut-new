# 第 1 章：epoll 底层机制 — 从 Selector.select() 到 epoll_wait()

> **源码版本**：OpenJDK 11  
> **标准环境**：Linux x86_64  
> **源码根目录**：`/data/workspace/openjdk-cut-new/src/java.base/`

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **第 1 章：epoll 底层机制 — 从 Selector.select() 到 epoll_wait()**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 1. 问题引入

### 1.1 为什么需要 epoll？

假设你写了一个 Java 网络服务器，需要同时处理 10000 个客户端连接。有三种方案：

| 方案 | 做法 | 问题 |
|------|------|------|
| **一连接一线程** | 每个连接一个线程，线程阻塞在 `read()` | 10000 个线程，上下文切换爆炸，内存占用 ~10GB（每线程 1MB 栈） |
| **select/poll** | 一个线程轮询所有 fd | 每次 `select()` 都要把 10000 个 fd 从用户态拷贝到内核态，O(n) 遍历 |
| **epoll** | 内核维护就绪列表，只返回有事件的 fd | O(1) 注册，O(活跃连接数) 返回，无需拷贝 fd 集合 |

**epoll 解决的核心问题**：在海量连接中高效找到"哪些连接有数据可读/可写"。

### 1.2 本章要回答的问题

1. Java 的 `Selector.select()` 怎么一步步调到 Linux 的 `epoll_wait()` 系统调用？
2. `epoll_event` 结构体在 Java 中是怎么表示的？（Unsafe 直接操作 native 内存）
3. Channel 注册到 Selector 时，底层做了什么 `epoll_ctl` 调用？
4. wakeup 机制是怎么实现的？（pipe 自唤醒）
5. JDK 用的是水平触发(LT)还是边缘触发(ET)？为什么？

---

## 2. 完整调用链概览

```
用户代码: selector.select()
  │
  ▼
Selector.java (抽象类)
  select() → select(-1)                              // timeout=0 表示永久阻塞，内部转为 -1
  │
  ▼
SelectorImpl.java (基类)
  select(long timeout) → lockAndDoSelect(null, -1)
    │
    │  synchronized(this)                             // Selector 级别的锁
    │    synchronized(publicSelectedKeys)              // selectedKeys 级别的锁
    │
    ▼
  doSelect(action, timeout)                           // 抽象方法，由子类实现
  │
  ▼
EPollSelectorImpl.java (Linux 实现)
  doSelect(action, timeout)
    ├── processUpdateQueue()                          // 1. 处理 pending 的注册/修改
    │     └── EPoll.ctl(epfd, ADD/MOD/DEL, fd, events) → epoll_ctl() 系统调用
    ├── processDeregisterQueue()                      // 2. 处理取消的 key
    ├── EPoll.wait(epfd, addr, n, timeout)            // 3. 核心：阻塞等待事件
    │     └── epoll_wait() 系统调用
    ├── processDeregisterQueue()                      // 4. 再次处理取消的 key
    └── processEvents(numEntries, action)             // 5. 将 native 事件转为 Java SelectionKey
          └── EPoll.getDescriptor() / EPoll.getEvents()  // Unsafe 读取 native 内存
```

---

## 3. Selector 的创建链路：从 open() 到 epoll_create()

### 3.1 Java 层创建链路

用户代码 `Selector.open()` 的完整调用链：

```
Selector.open()
  → SelectorProvider.provider()                 // 获取平台默认 Provider
    → DefaultSelectorProvider.create()          // Linux 平台特定
      → new EPollSelectorProvider()
  → provider.openSelector()
    → EPollSelectorProvider.openSelector()
      → new EPollSelectorImpl(this)             // 创建 epoll 实例
```

### 3.2 SelectorProvider.provider() — Provider 选择机制

**源码文件**：`java/nio/channels/spi/SelectorProvider.java`

```java
// SelectorProvider.java L171-L187
public static SelectorProvider provider() {
    synchronized (lock) {
        if (provider != null)
            return provider;
        return AccessController.doPrivileged(
            new PrivilegedAction<>() {
                public SelectorProvider run() {
                        if (loadProviderFromProperty())
                            return provider;
                        if (loadProviderAsService())
                            return provider;
                        provider = sun.nio.ch.DefaultSelectorProvider.create();
                        return provider;
                    }
                });
    }
}
```

| 步骤 | 行为 | 标准条件下 |
|------|------|-----------|
| ① 检查系统属性 | 查找 `java.nio.channels.spi.SelectorProvider` 属性 | 未设置，跳过 |
| ② ServiceLoader | 查找 `META-INF/services/java.nio.channels.spi.SelectorProvider` | 无此文件，跳过 |
| ③ 平台默认 | 调用 `DefaultSelectorProvider.create()` | **走这条路径** |

### 3.3 DefaultSelectorProvider — Linux 平台绑定

**源码文件**：`linux/classes/sun/nio/ch/DefaultSelectorProvider.java`

```java
// DefaultSelectorProvider.java (Linux 版本)
public class DefaultSelectorProvider {
    private DefaultSelectorProvider() { }

    public static SelectorProvider create() {
        return new EPollSelectorProvider();
    }
}
```

> **关键设计**：不同操作系统有不同的 `DefaultSelectorProvider.java`：
> - **Linux**：返回 `EPollSelectorProvider`（基于 epoll）
> - **macOS**：返回 `KQueueSelectorProvider`（基于 kqueue）
> - **Solaris**：返回 `DevPollSelectorProvider`（基于 /dev/poll）
> - **通用 Unix**：返回 `PollSelectorProvider`（基于 poll，作为 fallback）

### 3.4 EPollSelectorProvider.openSelector()

**源码文件**：`linux/classes/sun/nio/ch/EPollSelectorProvider.java`

```java
// EPollSelectorProvider.java
public class EPollSelectorProvider extends SelectorProviderImpl {
    public AbstractSelector openSelector() throws IOException {
        return new EPollSelectorImpl(this);
    }

    public Channel inheritedChannel() throws IOException {
        return InheritedChannel.getChannel();
    }
}
```

只有一个职责：`new EPollSelectorImpl(this)`。

### 3.5 EPollSelectorImpl 构造函数 — 核心初始化

**源码文件**：`linux/classes/sun/nio/ch/EPollSelectorImpl.java` L50-94

```java
// EPollSelectorImpl.java L50-94
class EPollSelectorImpl extends SelectorImpl {

    // maximum number of events to poll in one call to epoll_wait
    private static final int NUM_EPOLLEVENTS = Math.min(IOUtil.fdLimit(), 1024);

    // epoll file descriptor
    private final int epfd;

    // address of poll array when polling with epoll_wait
    private final long pollArrayAddress;

    // file descriptors used for interrupt
    private final int fd0;
    private final int fd1;

    // maps file descriptor to selection key, synchronize on selector
    private final Map<Integer, SelectionKeyImpl> fdToKey = new HashMap<>();

    // pending new registrations/updates, queued by setEventOps
    private final Object updateLock = new Object();
    private final Deque<SelectionKeyImpl> updateKeys = new ArrayDeque<>();

    // interrupt triggering and clearing
    private final Object interruptLock = new Object();
    private boolean interruptTriggered;

    EPollSelectorImpl(SelectorProvider sp) throws IOException {
        super(sp);

        this.epfd = EPoll.create();
        this.pollArrayAddress = EPoll.allocatePollArray(NUM_EPOLLEVENTS);

        try {
            long fds = IOUtil.makePipe(false);
            this.fd0 = (int) (fds >>> 32);
            this.fd1 = (int) fds;
        } catch (IOException ioe) {
            EPoll.freePollArray(pollArrayAddress);
            FileDispatcherImpl.closeIntFD(epfd);
            throw ioe;
        }

        // register one end of the socket pair for wakeups
        EPoll.ctl(epfd, EPOLL_CTL_ADD, fd0, EPOLLIN);
    }
```

#### 逐行注释表

| 行号 | 源码 | 行为 |
|------|------|------|
| L53 | `NUM_EPOLLEVENTS = Math.min(IOUtil.fdLimit(), 1024)` | `fdLimit()` 通过 `getrlimit(RLIMIT_NOFILE)` 获取进程最大 fd 数（通常 1048576），取 min 后 = **1024**。每次 `epoll_wait` 最多返回 1024 个事件 |
| L56 | `private final int epfd` | epoll 实例的文件描述符，由 `epoll_create()` 返回 |
| L59 | `private final long pollArrayAddress` | native 内存地址，存放 `epoll_event[]` 数组。用 `Unsafe.allocateMemory()` 分配 |
| L62-63 | `private final int fd0; private final int fd1` | pipe 的读端(fd0)和写端(fd1)，用于 wakeup 机制 |
| L66 | `fdToKey = new HashMap<>()` | fd → SelectionKey 的映射表。epoll_wait 返回 fd 后，通过此表找到对应的 Java 对象 |
| L69-70 | `updateLock` / `updateKeys` | 多线程安全队列：其他线程修改 interest ops 时，先放入队列，下次 select 时统一处理 |
| L73-74 | `interruptLock` / `interruptTriggered` | wakeup 的去重标志：多次 wakeup 只写一次 pipe |
| L78 | `this.epfd = EPoll.create()` | **系统调用 ①**：`epoll_create(256)` → 内核创建 epoll 实例，返回 epfd |
| L79 | `this.pollArrayAddress = EPoll.allocatePollArray(NUM_EPOLLEVENTS)` | 分配 native 内存：`1024 × sizeof(epoll_event)` = 1024 × 12 = **12288 字节** |
| L82 | `long fds = IOUtil.makePipe(false)` | **系统调用 ②**：`pipe(fd)` → 创建非阻塞 pipe。高 32 位 = 读端 fd0，低 32 位 = 写端 fd1 |
| L83 | `this.fd0 = (int) (fds >>> 32)` | 提取 pipe 读端 fd |
| L84 | `this.fd1 = (int) fds` | 提取 pipe 写端 fd |
| L93 | `EPoll.ctl(epfd, EPOLL_CTL_ADD, fd0, EPOLLIN)` | **系统调用 ③**：`epoll_ctl(epfd, EPOLL_CTL_ADD, fd0, {EPOLLIN, fd0})`。把 pipe 读端注册到 epoll，监听可读事件。当调用 `wakeup()` 时，向 fd1 写入 1 字节，fd0 变为可读，epoll_wait 就会返回 |

**构造完成后的状态**：

```
EPollSelectorImpl
├── epfd = 3          (epoll_create 返回的 fd)
├── pollArrayAddress → [native 内存, 12KB, 存 1024 个 epoll_event]
├── fd0 = 4           (pipe 读端, 已注册到 epoll, 监听 EPOLLIN)
├── fd1 = 5           (pipe 写端, wakeup 时写入 1 字节)
├── fdToKey = {}      (空，尚无 Channel 注册)
├── updateKeys = []   (空，尚无待处理的注册)
└── interruptTriggered = false
```

**涉及的系统调用汇总**：

| 系统调用 | 参数 | 作用 |
|---------|------|------|
| `epoll_create(256)` | 256 (hint，现代内核忽略) | 创建 epoll 实例 |
| `pipe(fd[2])` | — | 创建 pipe 用于 wakeup |
| `fcntl(fd[0], F_SETFL, O_NONBLOCK)` | — | pipe 读端设为非阻塞 |
| `fcntl(fd[1], F_SETFL, O_NONBLOCK)` | — | pipe 写端设为非阻塞 |
| `epoll_ctl(epfd, EPOLL_CTL_ADD, fd0, {EPOLLIN})` | — | 注册 pipe 读端到 epoll |

---

## 4. epoll_event 内存布局 — Java 如何操作 C 结构体

### 4.1 Linux 内核中的 epoll_event 定义

```c
// /usr/include/sys/epoll.h
typedef union epoll_data {
    void    *ptr;
    int      fd;
    uint32_t u32;
    uint64_t u64;
} epoll_data_t;

struct epoll_event {
    uint32_t     events;      // epoll 事件 (EPOLLIN, EPOLLOUT, ...)
    epoll_data_t data;        // 用户数据 (JDK 中存 fd)
};
```

### 4.2 内存布局图

```
struct epoll_event (x86_64, sizeof = 12 bytes):
┌────────────────────────────────────────────────────┐
│ offset 0:  events (uint32_t, 4 bytes)              │  ← EPOLLIN=0x1, EPOLLOUT=0x4 等
├────────────────────────────────────────────────────┤
│ offset 4:  data.fd (int, 4 bytes)                  │  ← JDK 只用 fd 字段
├────────────────────────────────────────────────────┤
│ offset 8:  data 的剩余部分 (4 bytes padding)        │  ← epoll_data 是 union，共 8 字节
└────────────────────────────────────────────────────┘

注意：在 x86_64 上 sizeof(struct epoll_event) = 12，不是 16！
这是因为 struct epoll_event 使用了 __attribute__((packed)) 编译属性。
```

> **为什么是 12 字节不是 16 字节？** `epoll_event` 在 x86_64 Linux 上被定义为 packed 结构体（`__attribute__((packed))`），所以 `events`(4 bytes) + `data`(8 bytes) = 12 bytes，没有 padding。

### 4.3 EPoll.java — 用 Unsafe 操作 native 内存

**源码文件**：`linux/classes/sun/nio/ch/EPoll.java`

```java
// EPoll.java (完整源码)
class EPoll {
    private EPoll() { }

    private static final Unsafe unsafe = Unsafe.getUnsafe();

    // --- 以下三个常量通过 JNI 从 C 获取，保证与内核结构体一致 ---
    private static final int SIZEOF_EPOLLEVENT   = eventSize();    // = 12
    private static final int OFFSETOF_EVENTS     = eventsOffset(); // = 0
    private static final int OFFSETOF_FD         = dataOffset();   // = 4

    // opcodes (与 <sys/epoll.h> 中的宏一致)
    static final int EPOLL_CTL_ADD  = 1;   // 注册新 fd
    static final int EPOLL_CTL_DEL  = 2;   // 删除 fd
    static final int EPOLL_CTL_MOD  = 3;   // 修改已注册 fd 的事件

    // events (与 <sys/epoll.h> 中的宏一致)
    static final int EPOLLIN   = 0x1;      // 可读
    static final int EPOLLOUT  = 0x4;      // 可写

    // flags
    static final int EPOLLONESHOT   = (1 << 30);  // 一次性触发

    /**
     * 分配 native 内存，存放 count 个 epoll_event
     * 每个 12 字节，1024 个 = 12288 字节 = 12KB
     */
    static long allocatePollArray(int count) {
        return unsafe.allocateMemory(count * SIZEOF_EPOLLEVENT);
    }

    static void freePollArray(long address) {
        unsafe.freeMemory(address);
    }

    /**
     * 返回第 i 个 epoll_event 的地址
     * 地址计算：base + i × 12
     */
    static long getEvent(long address, int i) {
        return address + (SIZEOF_EPOLLEVENT * i);
    }

    /**
     * 从 native 内存读取 event->data.fd
     * 等价于 C 代码：((struct epoll_event*)addr)->data.fd
     */
    static int getDescriptor(long eventAddress) {
        return unsafe.getInt(eventAddress + OFFSETOF_FD);       // offset 4
    }

    /**
     * 从 native 内存读取 event->events
     * 等价于 C 代码：((struct epoll_event*)addr)->events
     */
    static int getEvents(long eventAddress) {
        return unsafe.getInt(eventAddress + OFFSETOF_EVENTS);   // offset 0
    }

    // --- Native 方法 ---
    private static native int eventSize();
    private static native int eventsOffset();
    private static native int dataOffset();
    static native int create() throws IOException;
    static native int ctl(int epfd, int opcode, int fd, int events);
    static native int wait(int epfd, long pollAddress, int numfds, int timeout)
        throws IOException;

    static {
        IOUtil.load();    // 加载 libnio.so
    }
}
```

#### 关键设计解析

**为什么不用 JNI 结构体，而用 Unsafe 直接操作内存？**

| 方案 | 做法 | 问题 |
|------|------|------|
| JNI 对象 | 每个 epoll_event 包装为一个 Java 对象 | 1024 个事件 = 1024 个对象 → GC 压力大 |
| ByteBuffer | 用 DirectByteBuffer 存放事件数组 | 额外的 bounds checking，API 笨拙 |
| **Unsafe** | 直接 `allocateMemory` + `getInt` | **零 GC 压力、零对象创建、直接内存访问** |

这是 JDK 内部代码才能用的"黑魔法"——通过 `Unsafe` 直接在堆外分配一块 native 内存，当作 C 的 `struct epoll_event[]` 使用。`epoll_wait` 直接把结果写入这块内存，Java 代码通过偏移量直接读取字段。

**pollArray 内存布局**：

```
pollArrayAddress (12KB native 内存)
│
├── event[0]  (+0):   events(4B) + data.fd(4B) + pad(4B) = 12B
├── event[1]  (+12):  events(4B) + data.fd(4B) + pad(4B) = 12B
├── event[2]  (+24):  events(4B) + data.fd(4B) + pad(4B) = 12B
│   ...
└── event[1023] (+12276): events(4B) + data.fd(4B) + pad(4B) = 12B
```

---

## 5. EPoll.c — Native 层完整源码分析

**源码文件**：`linux/native/libnio/ch/EPoll.c`

### 5.1 完整源码

```c
// EPoll.c (去除 license 头)

#include <dlfcn.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/epoll.h>

#include "jni.h"
#include "jni_util.h"
#include "jvm.h"
#include "jlong.h"
#include "nio.h"
#include "nio_util.h"

#include "sun_nio_ch_EPoll.h"

JNIEXPORT jint JNICALL
Java_sun_nio_ch_EPoll_eventSize(JNIEnv* env, jclass clazz)
{
    return sizeof(struct epoll_event);
}

JNIEXPORT jint JNICALL
Java_sun_nio_ch_EPoll_eventsOffset(JNIEnv* env, jclass clazz)
{
    return offsetof(struct epoll_event, events);
}

JNIEXPORT jint JNICALL
Java_sun_nio_ch_EPoll_dataOffset(JNIEnv* env, jclass clazz)
{
    return offsetof(struct epoll_event, data);
}

JNIEXPORT jint JNICALL
Java_sun_nio_ch_EPoll_create(JNIEnv *env, jclass clazz) {
    /* size hint not used in modern kernels */
    int epfd = epoll_create(256);
    if (epfd < 0) {
        JNU_ThrowIOExceptionWithLastError(env, "epoll_create failed");
    }
    return epfd;
}

JNIEXPORT jint JNICALL
Java_sun_nio_ch_EPoll_ctl(JNIEnv *env, jclass clazz, jint epfd,
                          jint opcode, jint fd, jint events)
{
    struct epoll_event event;
    int res;

    event.events = events;
    event.data.fd = fd;

    res = epoll_ctl(epfd, (int)opcode, (int)fd, &event);
    return (res == 0) ? 0 : errno;
}

JNIEXPORT jint JNICALL
Java_sun_nio_ch_EPoll_wait(JNIEnv *env, jclass clazz, jint epfd,
                           jlong address, jint numfds, jint timeout)
{
    struct epoll_event *events = jlong_to_ptr(address);
    int res = epoll_wait(epfd, events, numfds, timeout);
    if (res < 0) {
        if (errno == EINTR) {
            return IOS_INTERRUPTED;
        } else {
            JNU_ThrowIOExceptionWithLastError(env, "epoll_wait failed");
            return IOS_THROWN;
        }
    }
    return res;
}
```

### 5.2 逐函数注释表

#### 5.2.1 eventSize / eventsOffset / dataOffset — 结构体布局探测

```c
Java_sun_nio_ch_EPoll_eventSize(JNIEnv* env, jclass clazz) {
    return sizeof(struct epoll_event);      // x86_64 上返回 12
}

Java_sun_nio_ch_EPoll_eventsOffset(JNIEnv* env, jclass clazz) {
    return offsetof(struct epoll_event, events);  // 返回 0
}

Java_sun_nio_ch_EPoll_dataOffset(JNIEnv* env, jclass clazz) {
    return offsetof(struct epoll_event, data);    // 返回 4
}
```

| 函数 | 返回值(x86_64) | 作用 |
|------|---------------|------|
| `eventSize()` | **12** | `sizeof(struct epoll_event)` = 12 字节 |
| `eventsOffset()` | **0** | `events` 字段在结构体的偏移量 |
| `dataOffset()` | **4** | `data` 字段在结构体的偏移量（即 `data.fd` 的偏移量） |

**为什么用 C 函数获取而不是 Java 硬编码？** 因为不同平台、不同架构（x86 vs ARM vs MIPS）上结构体布局可能不同。通过 JNI 在编译时获取真实的 `sizeof` 和 `offsetof`，保证 Java 层的 Unsafe 操作与 C 结构体完全一致。

#### 5.2.2 create — 创建 epoll 实例

```c
Java_sun_nio_ch_EPoll_create(JNIEnv *env, jclass clazz) {
    int epfd = epoll_create(256);
    if (epfd < 0) {
        JNU_ThrowIOExceptionWithLastError(env, "epoll_create failed");
    }
    return epfd;
}
```

| 行 | 源码 | 行为 |
|----|------|------|
| `epoll_create(256)` | 系统调用 | 参数 256 是 size hint，Linux 2.6.8+ 已忽略此参数（内核使用动态数据结构）。返回 epoll 实例的 fd |
| `epfd < 0` | 错误处理 | 失败场景：`EMFILE`（进程 fd 上限）、`ENFILE`（系统 fd 上限）、`ENOMEM`（内存不足） |
| `JNU_ThrowIOExceptionWithLastError` | 抛 Java 异常 | 读取 `errno` 并转换为 `java.io.IOException` |

> **epoll_create vs epoll_create1**：现代 Linux 还提供 `epoll_create1(EPOLL_CLOEXEC)` 可以在创建时设置 close-on-exec 标志，但 JDK 11 仍使用 `epoll_create`。

#### 5.2.3 ctl — 注册/修改/删除事件

```c
Java_sun_nio_ch_EPoll_ctl(JNIEnv *env, jclass clazz, jint epfd,
                          jint opcode, jint fd, jint events)
{
    struct epoll_event event;
    int res;

    event.events = events;
    event.data.fd = fd;

    res = epoll_ctl(epfd, (int)opcode, (int)fd, &event);
    return (res == 0) ? 0 : errno;
}
```

| 行 | 源码 | 行为 |
|----|------|------|
| `struct epoll_event event` | 栈上分配 | 12 字节的临时结构体 |
| `event.events = events` | 设置事件类型 | 例如 `EPOLLIN`(0x1)、`EPOLLOUT`(0x4)、`EPOLLIN\|EPOLLOUT`(0x5) |
| `event.data.fd = fd` | 设置关联 fd | 当 epoll_wait 返回时，通过 `data.fd` 知道是哪个连接的事件 |
| `epoll_ctl(epfd, opcode, fd, &event)` | **核心系统调用** | opcode: 1=ADD, 2=DEL, 3=MOD |
| `return (res == 0) ? 0 : errno` | 返回错误码 | 成功返回 0，失败返回 errno（如 `EEXIST`=fd 已注册、`ENOENT`=fd 不存在） |

> **注意**：`ctl` 方法返回 `errno` 而不抛异常，由 Java 层判断是否需要处理。这是因为某些 epoll_ctl 失败是正常的（比如 fd 已关闭）。

**epoll_ctl 的三种 opcode**：

| opcode | 值 | 含义 | 使用场景 |
|--------|---|------|---------|
| `EPOLL_CTL_ADD` | 1 | 注册新 fd | Channel 首次注册到 Selector |
| `EPOLL_CTL_DEL` | 2 | 删除 fd | Channel 取消注册或 interest ops 变为 0 |
| `EPOLL_CTL_MOD` | 3 | 修改已注册 fd 的事件 | interest ops 变化（如从 OP_READ 改为 OP_READ\|OP_WRITE） |

#### 5.2.4 wait — 等待事件（核心）

```c
Java_sun_nio_ch_EPoll_wait(JNIEnv *env, jclass clazz, jint epfd,
                           jlong address, jint numfds, jint timeout)
{
    struct epoll_event *events = jlong_to_ptr(address);
    int res = epoll_wait(epfd, events, numfds, timeout);
    if (res < 0) {
        if (errno == EINTR) {
            return IOS_INTERRUPTED;     // = -3
        } else {
            JNU_ThrowIOExceptionWithLastError(env, "epoll_wait failed");
            return IOS_THROWN;          // = -5
        }
    }
    return res;
}
```

| 行 | 源码 | 行为 |
|----|------|------|
| `jlong_to_ptr(address)` | 宏展开 | 将 Java 的 `long` 转为 C 指针。`address` 就是 `EPollSelectorImpl.pollArrayAddress` |
| `epoll_wait(epfd, events, numfds, timeout)` | **核心系统调用** | 阻塞等待事件。`events` 指向预分配的 native 内存，`numfds` = 1024，`timeout` = 毫秒（-1 = 永久阻塞） |
| `res < 0` + `EINTR` | 被信号中断 | 返回 `IOS_INTERRUPTED`(-3)，Java 层会重试 |
| 其他错误 | 真正的错误 | 抛出 `IOException` |
| `return res` | 正常返回 | 返回就绪事件数（0 = 超时，>0 = 有事件） |

**epoll_wait 参数说明**：

| 参数 | 类型 | 含义 | 标准条件下的值 |
|------|------|------|-------------|
| `epfd` | int | epoll 实例 fd | 3（通常） |
| `events` | struct epoll_event* | 输出缓冲区 | pollArrayAddress（12KB native 内存） |
| `maxevents` | int | 缓冲区最多容纳的事件数 | 1024 |
| `timeout` | int | 超时毫秒数 | -1（永久阻塞）/ 0（立即返回）/ >0（指定毫秒） |

**返回值含义**：

| 返回值 | 含义 |
|--------|------|
| > 0 | 就绪事件数，结果写入 `events` 数组 |
| 0 | 超时，没有就绪事件 |
| -1 + EINTR | 被信号中断 |
| -1 + 其他 | 错误 |

---

## 6. IOUtil.c 关键函数 — pipe 和 wakeup 基础设施

### 6.1 makePipe — 创建非阻塞 pipe

**源码文件**：`unix/native/libnio/ch/IOUtil.c`

```c
// IOUtil.c
JNIEXPORT jlong JNICALL
Java_sun_nio_ch_IOUtil_makePipe(JNIEnv *env, jobject this, jboolean blocking)
{
    int fd[2];

    if (pipe(fd) < 0) {
        JNU_ThrowIOExceptionWithLastError(env, "Pipe failed");
        return 0;
    }
    if (blocking == JNI_FALSE) {
        if ((configureBlocking(fd[0], JNI_FALSE) < 0)
            || (configureBlocking(fd[1], JNI_FALSE) < 0)) {
            JNU_ThrowIOExceptionWithLastError(env, "Configure blocking failed");
            close(fd[0]);
            close(fd[1]);
            return 0;
        }
    }
    return ((jlong) fd[0] << 32) | (jlong) fd[1];
}
```

| 行 | 行为 |
|----|------|
| `pipe(fd)` | 创建管道，fd[0] = 读端，fd[1] = 写端 |
| `configureBlocking(fd[0], JNI_FALSE)` | 设为非阻塞：`fcntl(fd, F_SETFL, flags \| O_NONBLOCK)` |
| `((jlong) fd[0] << 32) \| (jlong) fd[1]` | 把两个 int 打包到一个 long 中返回 |

### 6.2 write1 — wakeup 写入 1 字节

```c
JNIEXPORT jint JNICALL
Java_sun_nio_ch_IOUtil_write1(JNIEnv *env, jclass cl, jint fd, jbyte b)
{
    char c = (char)b;
    return convertReturnVal(env, write(fd, &c, 1), JNI_FALSE);
}
```

向 pipe 写端写入 1 个字节（值为 0），使 pipe 读端变为可读，从而唤醒阻塞在 `epoll_wait` 上的线程。

### 6.3 drain — 清空 pipe

```c
JNIEXPORT jboolean JNICALL
Java_sun_nio_ch_IOUtil_drain(JNIEnv *env, jclass cl, jint fd)
{
    char buf[16];
    int tn = 0;

    for (;;) {
        int n = read(fd, buf, sizeof(buf));
        tn += n;
        if ((n < 0) && (errno != EAGAIN && errno != EWOULDBLOCK))
            JNU_ThrowIOExceptionWithLastError(env, "Drain");
        if (n == (int)sizeof(buf))
            continue;
        return (tn > 0) ? JNI_TRUE : JNI_FALSE;
    }
}
```

循环读取 pipe 直到没有数据（`EAGAIN`），清除 wakeup 信号。

---

## 7. doSelect() — Selector.select() 的核心实现

### 7.1 调用前的锁结构

在进入 `doSelect()` 之前，`SelectorImpl.lockAndDoSelect()` 已经获取了两把锁：

```java
// SelectorImpl.java L114-L130
private int lockAndDoSelect(Consumer<SelectionKey> action, long timeout)
    throws IOException
{
    synchronized (this) {                      // 锁 ①：Selector 实例锁
        ensureOpen();
        if (inSelect)
            throw new IllegalStateException("select in progress");
        inSelect = true;
        try {
            synchronized (publicSelectedKeys) {  // 锁 ②：selectedKeys 集合锁
                return doSelect(action, timeout);
            }
        } finally {
            inSelect = false;
        }
    }
}
```

| 锁 | 作用 |
|----|------|
| `synchronized(this)` | 防止多线程同时调用 select |
| `synchronized(publicSelectedKeys)` | 防止 select 过程中 selectedKeys 被并发修改 |
| `inSelect` 标志 | 防止重入（不允许在 select 的 action 回调中再次 select） |

### 7.2 doSelect 完整源码分析

**源码文件**：`linux/classes/sun/nio/ch/EPollSelectorImpl.java` L101-138

```java
// EPollSelectorImpl.java L101-138
@Override
protected int doSelect(Consumer<SelectionKey> action, long timeout)
    throws IOException
{
    assert Thread.holdsLock(this);

    // epoll_wait timeout is int
    int to = (int) Math.min(timeout, Integer.MAX_VALUE);
    boolean blocking = (to != 0);
    boolean timedPoll = (to > 0);

    int numEntries;
    processUpdateQueue();           // 步骤 1: 处理待注册/修改的事件
    processDeregisterQueue();       // 步骤 2: 处理已取消的 key
    try {
        begin(blocking);            // 步骤 3: 标记阻塞开始（支持线程中断）

        do {
            long startTime = timedPoll ? System.nanoTime() : 0;
            numEntries = EPoll.wait(epfd, pollArrayAddress, NUM_EPOLLEVENTS, to);
                                    // 步骤 4: ★ 调用 epoll_wait 系统调用 ★
            if (numEntries == IOStatus.INTERRUPTED && timedPoll) {
                // timed poll interrupted so need to adjust timeout
                long adjust = System.nanoTime() - startTime;
                to -= TimeUnit.MILLISECONDS.convert(adjust, TimeUnit.NANOSECONDS);
                if (to <= 0) {
                    // timeout expired so no retry
                    numEntries = 0;
                }
            }
        } while (numEntries == IOStatus.INTERRUPTED);
                                    // 步骤 5: 被信号中断则重试
        assert IOStatus.check(numEntries);

    } finally {
        end(blocking);              // 步骤 6: 标记阻塞结束
    }
    processDeregisterQueue();       // 步骤 7: 再次处理取消的 key
    return processEvents(numEntries, action);
                                    // 步骤 8: 将 native 事件转为 Java SelectionKey
}
```

#### 逐步骤解析

| 步骤 | 方法 | 做什么 | 详细说明 |
|------|------|--------|---------|
| 1 | `processUpdateQueue()` | 批量处理注册/修改 | 遍历 `updateKeys` 队列，对每个 key 调用 `epoll_ctl(ADD/MOD/DEL)` |
| 2 | `processDeregisterQueue()` | 处理取消的 key | 遍历 `cancelledKeys`，调用 `epoll_ctl(DEL)` 移除，从 fdToKey 中删除 |
| 3 | `begin(blocking)` | 标记阻塞 | 如果是阻塞模式，注册中断回调（线程被 interrupt 时调用 wakeup） |
| 4 | `EPoll.wait(...)` | **epoll_wait** | 系统调用，阻塞等待事件。结果写入 pollArrayAddress 指向的 native 内存 |
| 5 | EINTR 重试 | 处理信号中断 | 如果是超时模式，重新计算剩余时间；如果是无限等待模式，直接重试 |
| 6 | `end(blocking)` | 标记阻塞结束 | 与 begin 配对 |
| 7 | `processDeregisterQueue()` | 再次处理取消 | 阻塞期间可能有新的 cancel 请求 |
| 8 | `processEvents()` | 转换事件 | 遍历 native 事件数组，通过 fd → SelectionKey 映射，设置 readyOps |

### 7.3 processUpdateQueue — 延迟注册机制

```java
// EPollSelectorImpl.java L143-175
private void processUpdateQueue() {
    assert Thread.holdsLock(this);

    synchronized (updateLock) {
        SelectionKeyImpl ski;
        while ((ski = updateKeys.pollFirst()) != null) {
            if (ski.isValid()) {
                int fd = ski.getFDVal();
                // add to fdToKey if needed
                SelectionKeyImpl previous = fdToKey.putIfAbsent(fd, ski);
                assert (previous == null) || (previous == ski);

                int newEvents = ski.translateInterestOps();
                int registeredEvents = ski.registeredEvents();
                if (newEvents != registeredEvents) {
                    if (newEvents == 0) {
                        // remove from epoll
                        EPoll.ctl(epfd, EPOLL_CTL_DEL, fd, 0);
                    } else {
                        if (registeredEvents == 0) {
                            // add to epoll
                            EPoll.ctl(epfd, EPOLL_CTL_ADD, fd, newEvents);
                        } else {
                            // modify events
                            EPoll.ctl(epfd, EPOLL_CTL_MOD, fd, newEvents);
                        }
                    }
                    ski.registeredEvents(newEvents);
                }
            }
        }
    }
}
```

| 行为 | 详细说明 |
|------|---------|
| `updateKeys.pollFirst()` | 从双端队列中取出一个待更新的 key |
| `ski.translateInterestOps()` | 将 Java 的 `OP_READ`(1)/`OP_WRITE`(4)/`OP_CONNECT`(8)/`OP_ACCEPT`(16) 翻译为 native 的 `EPOLLIN`(0x1)/`EPOLLOUT`(0x4)/`EPOLLCONN` |
| `registeredEvents == 0` + `newEvents != 0` | **首次注册**：`EPOLL_CTL_ADD` |
| `registeredEvents != 0` + `newEvents != 0` | **修改事件**：`EPOLL_CTL_MOD` |
| `newEvents == 0` | **取消监听**：`EPOLL_CTL_DEL` |

**translateInterestOps 映射表**（以 SocketChannel 为例）：

```java
// SocketChannelImpl.java L1057-1066
public int translateInterestOps(int ops) {
    int newOps = 0;
    if ((ops & SelectionKey.OP_READ) != 0)     // Java: 1 (0x01)
        newOps |= Net.POLLIN;                  // Native: EPOLLIN = 0x1
    if ((ops & SelectionKey.OP_WRITE) != 0)    // Java: 4 (0x04)
        newOps |= Net.POLLOUT;                 // Native: EPOLLOUT = 0x4
    if ((ops & SelectionKey.OP_CONNECT) != 0)  // Java: 8 (0x08)
        newOps |= Net.POLLCONN;                // Native: EPOLLOUT = 0x4 (connect 用 POLLOUT)
    return newOps;
}
```

| Java SelectionKey 常量 | 值 | 对应 epoll 事件 | 值 |
|----------------------|---|--------------|---|
| `OP_READ` | 1 | `EPOLLIN` | 0x1 |
| `OP_WRITE` | 4 | `EPOLLOUT` | 0x4 |
| `OP_CONNECT` | 8 | `EPOLLOUT` | 0x4 |
| `OP_ACCEPT` | 16 | `EPOLLIN` | 0x1 |

> **注意**：`OP_CONNECT` 和 `OP_WRITE` 都映射到 `EPOLLOUT`，`OP_ACCEPT` 和 `OP_READ` 都映射到 `EPOLLIN`。这是因为在 Linux 内核层面，连接建立完成会触发 EPOLLOUT，新连接到达会触发 EPOLLIN。

### 7.4 processEvents — 从 native 事件到 Java SelectionKey

```java
// EPollSelectorImpl.java L181-207
private int processEvents(int numEntries, Consumer<SelectionKey> action)
    throws IOException
{
    assert Thread.holdsLock(this);

    boolean interrupted = false;
    int numKeysUpdated = 0;
    for (int i = 0; i < numEntries; i++) {
        long event = EPoll.getEvent(pollArrayAddress, i);  // 计算第 i 个事件的地址
        int fd = EPoll.getDescriptor(event);                // 读取 data.fd
        if (fd == fd0) {
            interrupted = true;                             // 是 wakeup pipe 的事件
        } else {
            SelectionKeyImpl ski = fdToKey.get(fd);         // fd → SelectionKey
            if (ski != null) {
                int rOps = EPoll.getEvents(event);          // 读取 events
                numKeysUpdated += processReadyEvents(rOps, ski, action);
            }
        }
    }

    if (interrupted) {
        clearInterrupt();                                   // 清空 pipe
    }

    return numKeysUpdated;
}
```

**数据流图**：

```
epoll_wait 返回后的 pollArray 内存内容：
┌──────────────────────────────────────────────┐
│ event[0]: events=EPOLLIN(0x1), data.fd=6     │ → fdToKey.get(6) → ski_A → readyOps |= OP_READ
│ event[1]: events=EPOLLOUT(0x4), data.fd=8    │ → fdToKey.get(8) → ski_B → readyOps |= OP_WRITE
│ event[2]: events=EPOLLIN(0x1), data.fd=4     │ → fd == fd0 (wakeup pipe!) → clearInterrupt()
└──────────────────────────────────────────────┘

processReadyEvents() 调用 translateReadyOps()：
  EPOLLIN  → 如果 interestOps 包含 OP_READ  → readyOps |= OP_READ
  EPOLLOUT → 如果 interestOps 包含 OP_WRITE → readyOps |= OP_WRITE
```

### 7.5 processReadyEvents — 事件翻译与 selectedKeys 更新

```java
// SelectorImpl.java L279-304
protected final int processReadyEvents(int rOps,
                                       SelectionKeyImpl ski,
                                       Consumer<SelectionKey> action) {
    if (action != null) {
        // ---- 模式 A: Action 回调模式 (Java 11 新增) ----
        ski.translateAndSetReadyOps(rOps);                    // 清空再设置 readyOps
        if ((ski.nioReadyOps() & ski.nioInterestOps()) != 0) {
            action.accept(ski);                               // 调用用户回调
            ensureOpen();
            return 1;
        }
    } else {
        // ---- 模式 B: 传统 selectedKeys 模式 ----
        assert Thread.holdsLock(publicSelectedKeys);
        if (selectedKeys.contains(ski)) {
            // key 已在 selectedKeys 中：OR 合并 readyOps
            if (ski.translateAndUpdateReadyOps(rOps)) {
                return 1;
            }
        } else {
            // key 不在 selectedKeys 中：设置 readyOps，加入 selectedKeys
            ski.translateAndSetReadyOps(rOps);
            if ((ski.nioReadyOps() & ski.nioInterestOps()) != 0) {
                selectedKeys.add(ski);
                return 1;
            }
        }
    }
    return 0;
}
```

**两种模式的区别**：

| 模式 | 调用方式 | 行为 |
|------|---------|------|
| 传统模式 | `selector.select()` 后遍历 `selectedKeys()` | readyOps 是 OR 累积的，需要用户手动 remove |
| Action 模式 | `selector.select(action)` (Java 11+) | 每次 select 前清空 readyOps，直接调用回调 |

**translateAndSetReadyOps vs translateAndUpdateReadyOps**：

| 方法 | 行为 | 使用场景 |
|------|------|---------|
| `translateAndSetReadyOps` | `initialOps = 0`，清空后设置 | 新 key 首次进入 selectedKeys / Action 模式 |
| `translateAndUpdateReadyOps` | `initialOps = ski.nioReadyOps()`，OR 累积 | key 已在 selectedKeys 中，可能有新事件 |

**translateReadyOps 详解**（以 SocketChannel 为例）：

```java
// SocketChannelImpl.java L1011-1044
public boolean translateReadyOps(int ops, int initialOps, SelectionKeyImpl ski) {
    int intOps = ski.nioInterestOps();
    int oldOps = ski.nioReadyOps();
    int newOps = initialOps;

    if ((ops & Net.POLLNVAL) != 0)       // fd 无效
        return false;

    if ((ops & (Net.POLLERR | Net.POLLHUP)) != 0) {  // 错误或对端关闭
        newOps = intOps;                  // 所有感兴趣的事件都标记为就绪
        ski.nioReadyOps(newOps);
        return (newOps & ~oldOps) != 0;
    }

    if (((ops & Net.POLLIN) != 0) &&
        ((intOps & SelectionKey.OP_READ) != 0) && isConnected())
        newOps |= SelectionKey.OP_READ;

    if (((ops & Net.POLLCONN) != 0) &&
        ((intOps & SelectionKey.OP_CONNECT) != 0) && isConnectionPending())
        newOps |= SelectionKey.OP_CONNECT;

    if (((ops & Net.POLLOUT) != 0) &&
        ((intOps & SelectionKey.OP_WRITE) != 0) && isConnected())
        newOps |= SelectionKey.OP_WRITE;

    ski.nioReadyOps(newOps);
    return (newOps & ~oldOps) != 0;      // 返回：是否有新增的就绪事件
}
```

**翻译规则**：

| native 事件 | 条件 | Java readyOps |
|------------|------|---------------|
| `POLLERR \| POLLHUP` | 任意 | interestOps 全部标记就绪 |
| `POLLIN` | interestOps 包含 OP_READ 且已连接 | `OP_READ` |
| `POLLCONN (=POLLOUT)` | interestOps 包含 OP_CONNECT 且连接中 | `OP_CONNECT` |
| `POLLOUT` | interestOps 包含 OP_WRITE 且已连接 | `OP_WRITE` |

---

## 8. Wakeup 机制 — 如何唤醒阻塞的 select

### 8.1 问题

线程 A 阻塞在 `selector.select()` → `epoll_wait(-1)` 中，线程 B 想要：
- 关闭 Selector
- 注册新 Channel
- 强制 select 返回

如何唤醒线程 A？

### 8.2 解决方案：pipe 自唤醒

```
构造时：
  pipe(fd) → fd0(读端), fd1(写端)
  epoll_ctl(EPOLL_CTL_ADD, fd0, EPOLLIN)   // 把读端注册到 epoll

wakeup() 时：
  write(fd1, 1 字节)                        // 向写端写 1 字节
  → fd0 变为可读                            // 读端有数据了
  → epoll_wait 返回                          // 检测到 fd0 可读事件
  → processEvents 发现 fd == fd0             // 是 wakeup 信号，不是用户 Channel
  → clearInterrupt() → drain(fd0)            // 读走管道中的数据，清除标志
```

### 8.3 wakeup() 源码

```java
// EPollSelectorImpl.java L249-262
@Override
public Selector wakeup() {
    synchronized (interruptLock) {
        if (!interruptTriggered) {
            try {
                IOUtil.write1(fd1, (byte)0);     // 向 pipe 写端写 1 字节
            } catch (IOException ioe) {
                throw new InternalError(ioe);
            }
            interruptTriggered = true;           // 标记已触发，防止重复写入
        }
    }
    return this;
}
```

| 行为 | 说明 |
|------|------|
| `synchronized(interruptLock)` | 防止多线程并发 wakeup |
| `!interruptTriggered` 检查 | **去重**：多次 wakeup 只写一次 pipe。避免 pipe 缓冲区被填满 |
| `IOUtil.write1(fd1, (byte)0)` | 写 1 字节到 pipe 写端 → 底层 `write(fd, &c, 1)` |
| `interruptTriggered = true` | 标记已唤醒 |

### 8.4 clearInterrupt() 源码

```java
// EPollSelectorImpl.java L264-269
private void clearInterrupt() throws IOException {
    synchronized (interruptLock) {
        IOUtil.drain(fd0);                  // 读走 pipe 中所有数据
        interruptTriggered = false;         // 重置标志
    }
}
```

### 8.5 wakeup 时序图

```
线程 A (select)                    线程 B (wakeup)
     │                                  │
     │  epoll_wait(epfd, ..., -1)       │
     │  ← 阻塞中 ──────────────────     │
     │                                  │
     │                                  │  wakeup()
     │                                  │    synchronized(interruptLock)
     │                                  │    write(fd1, 1 byte)
     │  ← epoll_wait 返回               │    interruptTriggered = true
     │  numEntries = 1                  │
     │  event[0].fd == fd0 (pipe!)      │
     │  interrupted = true              │
     │                                  │
     │  clearInterrupt()                │
     │    drain(fd0)                    │
     │    interruptTriggered = false    │
     │                                  │
     │  return numKeysUpdated           │
     ▼                                  ▼
```

---

## 9. implClose() — Selector 关闭

```java
// EPollSelectorImpl.java L210-223
@Override
protected void implClose() throws IOException {
    assert Thread.holdsLock(this);

    // prevent further wakeup
    synchronized (interruptLock) {
        interruptTriggered = true;             // 阻止后续 wakeup 写 pipe
    }

    FileDispatcherImpl.closeIntFD(epfd);       // 关闭 epoll fd
    EPoll.freePollArray(pollArrayAddress);      // 释放 native 内存（12KB）

    FileDispatcherImpl.closeIntFD(fd0);        // 关闭 pipe 读端
    FileDispatcherImpl.closeIntFD(fd1);        // 关闭 pipe 写端
}
```

**关闭顺序的重要性**：
1. 先设置 `interruptTriggered = true`，防止关闭后还有线程调用 wakeup 写已关闭的 pipe
2. 关闭 epfd → 内核释放 epoll 实例及其红黑树和就绪链表
3. 释放 pollArray native 内存
4. 关闭 pipe 的两端

---

## 10. IOStatus 常量 — native 返回值约定

**源码文件**：`sun/nio/ch/IOStatus.java`

```java
public final class IOStatus {
    public static final int EOF = -1;              // 读到文件末尾
    public static final int UNAVAILABLE = -2;      // 非阻塞模式下无数据（EAGAIN）
    public static final int INTERRUPTED = -3;      // 被信号中断（EINTR）
    public static final int UNSUPPORTED = -4;      // 操作不支持
    public static final int THROWN = -5;           // JNI 代码中抛了异常
    public static final int UNSUPPORTED_CASE = -6; // 此 case 不支持
}
```

对应 C 层（`nio.h`）：

```c
#define IOS_EOF              (-1)    // sun_nio_ch_IOStatus_EOF
#define IOS_UNAVAILABLE      (-2)    // sun_nio_ch_IOStatus_UNAVAILABLE
#define IOS_INTERRUPTED      (-3)    // sun_nio_ch_IOStatus_INTERRUPTED
#define IOS_UNSUPPORTED      (-4)    // sun_nio_ch_IOStatus_UNSUPPORTED
#define IOS_THROWN           (-5)    // sun_nio_ch_IOStatus_THROWN
#define IOS_UNSUPPORTED_CASE (-6)    // sun_nio_ch_IOStatus_UNSUPPORTED_CASE
```

---

## 11. 水平触发(LT) vs 边缘触发(ET)

### 11.1 JDK 使用哪种模式？

**JDK 11 使用水平触发（Level-Triggered, LT）模式**。

证据：在 `EPoll.ctl()` 调用时，传入的 `events` 参数是 `EPOLLIN`(0x1) 或 `EPOLLOUT`(0x4)，**没有设置 `EPOLLET`(0x80000000) 标志位**。

```java
// EPollSelectorImpl.processUpdateQueue()
EPoll.ctl(epfd, EPOLL_CTL_ADD, fd, newEvents);  // newEvents = EPOLLIN 或 EPOLLOUT
                                                  // 没有 | EPOLLET
```

### 11.2 LT vs ET 的区别

| 特性 | 水平触发 (LT) | 边缘触发 (ET) |
|------|-------------|-------------|
| 触发条件 | 只要满足条件就触发（如：缓冲区有数据就一直通知 EPOLLIN） | 状态变化时触发一次（如：从"无数据"变为"有数据"时通知一次） |
| 数据处理 | 可以分多次 read，每次 select 都会再次报告 | 必须一次读完（循环读直到 EAGAIN），否则丢失通知 |
| 编程难度 | 简单，不会丢事件 | 复杂，必须配合非阻塞 I/O + 循环读写 |
| 性能 | 可能有多余的 epoll_wait 返回 | 减少系统调用次数 |

### 11.3 JDK 为什么选择 LT？

1. **安全性**：LT 模式下，即使用户没有一次读完数据，下次 select 还会通知。ET 模式下如果漏读，数据会"丢失"（实际在内核缓冲区，但不再通知）。
2. **兼容性**：Java NIO 的 API 设计（selectedKeys 集合模型）天然适合 LT。用户不需要在一次回调中读完所有数据。
3. **简单性**：JDK 是通用框架，需要兼顾所有使用场景。ET 模式的性能收益在框架层面不如在应用层面（如 Netty）明显。

> **Netty 怎么做的？** Netty 在 Linux 上使用自己的 `EpollEventLoop`（通过 JNI 直接调用 epoll 系统调用），使用 **ET 模式 + EPOLLONESHOT**，避开了 JDK NIO 的限制。这是 Netty 在 Linux 上性能优于 JDK NIO 的原因之一。

---

## 12. 完整数据流图

### 12.1 Selector.select() 完整流程

```
用户代码                    JDK Java 层                     JDK Native 层 (libnio.so)         Linux 内核
────────                   ──────────                      ────────────────────────          ──────────
                                                                                           
selector.select()                                                                          
  │                                                                                        
  ├─→ SelectorImpl.lockAndDoSelect(null, -1)                                               
  │     synchronized(this)                                                                 
  │     synchronized(publicSelectedKeys)                                                   
  │                                                                                        
  ├─→ EPollSelectorImpl.doSelect()                                                         
  │                                                                                        
  │   ┌─ processUpdateQueue() ──────────────────────────────────────────────────┐           
  │   │  遍历 updateKeys 队列                                                    │           
  │   │  for each key:                                                          │           
  │   │    newEvents = translateInterestOps(OP_READ)                            │           
  │   │           → EPOLLIN (0x1)                                               │           
  │   │    EPoll.ctl(epfd, EPOLL_CTL_ADD, fd, EPOLLIN) ──JNI──→ EPoll.c        │           
  │   │                                                   │                     │           
  │   │                                      event.events = EPOLLIN;            │           
  │   │                                      event.data.fd = fd;                │           
  │   │                                      epoll_ctl(epfd, 1, fd, &event) ──→ │  内核：将 fd 
  │   │                                                                         │  加入红黑树
  │   └─────────────────────────────────────────────────────────────────────────┘           
  │                                                                                        
  │   ┌─ EPoll.wait(epfd, pollArrayAddress, 1024, -1) ──JNI──→ EPoll.c ───────┐           
  │   │                                                                        │           
  │   │  struct epoll_event *events = jlong_to_ptr(address);                   │           
  │   │  int res = epoll_wait(epfd, events, 1024, -1) ──────────────────────→  │  内核：检查
  │   │                                                                        │  就绪链表
  │   │  ← 阻塞，直到：                                                        │           
  │   │    1. 某 fd 有事件（数据到达/连接建立/...）                               │  ← 网卡中断
  │   │    2. wakeup() 写了 pipe                                               │  ← pipe 可读
  │   │    3. 超时                                                              │  ← 定时器
  │   │    4. 被信号中断                                                        │  ← EINTR
  │   │                                                                        │           
  │   │  返回 res = 就绪事件数                                                  │           
  │   │  pollArray 已被内核填充：                                                │           
  │   │    event[0] = {events=EPOLLIN, data.fd=6}                              │           
  │   │    event[1] = {events=EPOLLOUT, data.fd=8}                             │           
  │   └────────────────────────────────────────────────────────────────────────┘           
  │                                                                                        
  │   ┌─ processEvents(2, null) ────────────────────────────────────────────────┐           
  │   │  for i in 0..1:                                                         │           
  │   │    event_addr = pollArrayAddress + i * 12                               │           
  │   │    fd = Unsafe.getInt(event_addr + 4)    // data.fd                     │           
  │   │    events = Unsafe.getInt(event_addr + 0) // events                     │           
  │   │                                                                         │           
  │   │    if fd == fd0 → wakeup 信号，标记 interrupted                          │           
  │   │    else:                                                                │           
  │   │      ski = fdToKey.get(fd)                                              │           
  │   │      rOps = events                                                      │           
  │   │      processReadyEvents(rOps, ski, null)                                │           
  │   │        → ski.translateAndSetReadyOps(EPOLLIN)                           │           
  │   │           → readyOps |= OP_READ                                        │           
  │   │        → selectedKeys.add(ski)                                          │           
  │   └─────────────────────────────────────────────────────────────────────────┘           
  │                                                                                        
  └─→ return numKeysUpdated (= 2)                                                          
                                                                                           
用户代码：                                                                                  
  Set<SelectionKey> keys = selector.selectedKeys();                                         
  for (SelectionKey key : keys) {                                                           
      if (key.isReadable()) { channel.read(buf); }                                          
      if (key.isWritable()) { channel.write(buf); }                                         
  }                                                                                         
```

---

## 13. 性能关键点

### 13.1 epoll 的 O(1) vs O(n)

| 操作 | select/poll | epoll |
|------|-----------|-------|
| 注册 fd | 每次 select 重新传入全部 fd（O(n) 拷贝） | `epoll_ctl` 一次注册，内核记住（O(1)） |
| 等待事件 | 内核遍历全部 fd 检查状态（O(n)） | 内核维护就绪链表，callback 驱动（O(1)） |
| 返回结果 | 返回全部 fd 的状态数组，用户遍历（O(n)） | 只返回就绪的 fd（O(就绪数)） |

### 13.2 JDK 中的性能优化设计

| 优化 | 位置 | 效果 |
|------|------|------|
| native 内存 + Unsafe | `EPoll.allocatePollArray` | 避免 Java 对象创建和 GC |
| 延迟批量处理 | `updateKeys` 队列 | 多个 interest ops 变更合并为一次 processUpdateQueue |
| wakeup 去重 | `interruptTriggered` 标志 | 多次 wakeup 只写一次 pipe |
| fd → key 映射 | `HashMap<Integer, SelectionKeyImpl>` | O(1) 查找 |
| 结构体常量预计算 | `SIZEOF_EPOLLEVENT` / `OFFSETOF_*` | 避免每次调用时计算偏移 |

### 13.3 NUM_EPOLLEVENTS = 1024 的含义

```java
private static final int NUM_EPOLLEVENTS = Math.min(IOUtil.fdLimit(), 1024);
```

- `IOUtil.fdLimit()` 通过 `getrlimit(RLIMIT_NOFILE)` 获取进程能打开的最大 fd 数（如 1048576）
- 取 min 后 = 1024，即每次 `epoll_wait` 最多返回 1024 个就绪事件
- 如果就绪事件超过 1024，下次 `select()` 调用会继续处理剩余事件
- **为什么是 1024？** 这是经验值：平衡内存占用（12KB）和批处理效率。过大浪费内存，过小需要更多次系统调用

---

## 14. 面试常见问题

### Q1: Java NIO 中 Selector.select() 的底层原理是什么？

**答**：在 Linux 上，`Selector.select()` 最终调用 `epoll_wait()` 系统调用。创建 Selector 时会 `epoll_create()` 创建 epoll 实例，注册 Channel 时通过 `epoll_ctl(EPOLL_CTL_ADD)` 将 fd 加入监听，`select()` 时调用 `epoll_wait()` 阻塞等待就绪事件。返回后遍历 native 内存中的 `epoll_event` 数组，通过 `fd → SelectionKey` 映射将 native 事件翻译为 Java 的 readyOps。

### Q2: Selector.wakeup() 是怎么实现的？

**答**：Selector 构造时创建了一个 pipe（`pipe()` 系统调用），pipe 读端注册到 epoll 监听 EPOLLIN。`wakeup()` 时向 pipe 写端写入 1 字节，使读端可读，`epoll_wait()` 检测到读端事件而返回。有 `interruptTriggered` 去重标志，多次 wakeup 只写一次。

### Q3: epoll 的水平触发(LT)和边缘触发(ET)有什么区别？JDK 用的是哪种？

**答**：LT 模式下只要条件满足就持续通知（缓冲区有数据就一直报 EPOLLIN），ET 模式下仅在状态变化时通知一次（从"无数据"变"有数据"时通知一次）。JDK 11 使用 LT 模式，因为更安全（不会漏事件）且与 Java NIO 的 selectedKeys 模型兼容。Netty 在 Linux 上使用 ET + EPOLLONESHOT 以获得更好性能。

### Q4: 为什么 JDK 中 epoll_event 数组用 Unsafe 而不是普通 Java 对象？

**答**：`epoll_wait()` 需要直接向用户态内存写入 `struct epoll_event` 数组。使用 `Unsafe.allocateMemory()` 分配堆外内存，`epoll_wait` 直接写入，Java 用 `Unsafe.getInt()` 按偏移量读取。避免了：1) 1024 个 Java 对象的创建和 GC 压力；2) JNI 边界的数据拷贝；3) bounds checking 开销。

### Q5: 为什么 Selector 使用延迟注册（updateKeys 队列）而不是立即 epoll_ctl？

**答**：因为 `channel.register()` 或 `key.interestOps()` 可能在任意线程调用，而 `epoll_ctl` 和 `epoll_wait` 的并发行为在某些内核版本上可能有问题。延迟到 `doSelect()` 开头统一处理（`processUpdateQueue()`），既保证线程安全，又能批量合并多次修改，减少系统调用次数。

---

## 15. 涉及的源码文件清单

| 文件 | 路径 | 作用 |
|------|------|------|
| `Selector.java` | `share/classes/java/nio/channels/Selector.java` | 抽象基类，定义 select/wakeup API |
| `SelectorProvider.java` | `share/classes/java/nio/channels/spi/SelectorProvider.java` | Provider 查找机制 |
| `DefaultSelectorProvider.java` | `linux/classes/sun/nio/ch/DefaultSelectorProvider.java` | Linux 平台返回 EPollSelectorProvider |
| `EPollSelectorProvider.java` | `linux/classes/sun/nio/ch/EPollSelectorProvider.java` | 创建 EPollSelectorImpl |
| `SelectorImpl.java` | `share/classes/sun/nio/ch/SelectorImpl.java` | Selector 基类，实现锁机制和 selectedKeys 管理 |
| `EPollSelectorImpl.java` | `linux/classes/sun/nio/ch/EPollSelectorImpl.java` | **核心**：epoll 封装，doSelect/wakeup/processEvents |
| `EPoll.java` | `linux/classes/sun/nio/ch/EPoll.java` | epoll 系统调用 Java 包装 + Unsafe 内存操作 |
| `EPoll.c` | `linux/native/libnio/ch/EPoll.c` | epoll 系统调用 JNI 实现 |
| `SelectionKeyImpl.java` | `share/classes/sun/nio/ch/SelectionKeyImpl.java` | SelectionKey 实现，存储 interestOps/readyOps |
| `SelChImpl.java` | `share/classes/sun/nio/ch/SelChImpl.java` | Channel ↔ Selector 桥接接口 |
| `IOUtil.java` | `share/classes/sun/nio/ch/IOUtil.java` | NIO 工具类：makePipe/write1/drain/fdLimit |
| `IOUtil.c` | `unix/native/libnio/ch/IOUtil.c` | pipe/configureBlocking/drain 的 JNI 实现 |
| `IOStatus.java` | `share/classes/sun/nio/ch/IOStatus.java` | I/O 状态常量（EOF/UNAVAILABLE/INTERRUPTED/THROWN） |
| `nio.h` | `share/native/libnio/ch/nio.h` | C 层 IOS_* 宏定义 |
| `nio_util.h` | `unix/native/libnio/ch/nio_util.h` | RESTARTABLE 宏、fdval/convertReturnVal 声明 |
| `SocketChannelImpl.java` | `share/classes/sun/nio/ch/SocketChannelImpl.java` | translateInterestOps/translateReadyOps 实现 |
