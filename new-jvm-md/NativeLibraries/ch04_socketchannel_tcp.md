# 第 4 章：SocketChannel — TCP 客户端全链路分析

> **源码版本**：OpenJDK 11  
> **标准环境**：Linux x86_64  
> **前置依赖**：[第 1 章 epoll 底层机制](ch01_epoll_mechanism.md) / [第 2 章 Selector 继承体系](ch02_selector_and_registration.md)

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文对 **第 4 章：SocketChannel — TCP 客户端全链路分析** 进行源码级分析：追踪关键函数的执行路径，分析涉及的数据结构，解释每个设计决策的原因。

### 0.2 为什么需要？

仅靠文档和注释无法完全理解 JVM 的行为——很多关键细节只存在于源码中。源码级分析能建立对 JVM 行为的精确理解。

### 0.3 怎么解决？

从入口函数出发，自顶向下追踪调用链；对每个关键函数，分析其输入/输出/副作用；对每个数据结构，分析其字段含义和生命周期。

### 0.4 为什么这样设计？

分析过程中重点关注「为什么」：为什么选择这个数据结构？为什么这样处理边界情况？这些问题的答案往往揭示了 JVM 设计的精髓。

---


## 1. 问题引入

### 1.1 核心问题

当你写下这段 NIO 代码时，底层到底发生了什么？

```java
SocketChannel channel = SocketChannel.open();
channel.configureBlocking(false);
channel.connect(new InetSocketAddress("10.0.0.1", 8080));
channel.register(selector, SelectionKey.OP_CONNECT);
if (channel.finishConnect()) {
    channel.register(selector, SelectionKey.OP_READ);
}
channel.read(buffer);
channel.write(buffer);
channel.close();
```

这短短十来行 Java 代码，涉及以下系统调用链：

```
SocketChannel.open()       → socket(AF_INET6, SOCK_STREAM, 0)
configureBlocking(false)   → fcntl(fd, F_SETFL, O_NONBLOCK)
connect()                  → connect(fd, &sa, len)  → EINPROGRESS
finishConnect()            → poll(fd, POLLOUT, 0) + getsockopt(SO_ERROR)
read()                     → read(fd, buf, len)
write()                    → write(fd, buf, len)
close()                    → shutdown(fd, SHUT_WR) + close(fd)
```

### 1.2 本章要回答的问题

1. `SocketChannel.open()` 创建的是什么类型的 socket？IPv4 还是 IPv6？
2. 非阻塞 `connect()` 返回 `EINPROGRESS` 后，JDK 怎么处理？
3. `finishConnect()` 怎么通过 `poll(POLLOUT) + getsockopt(SO_ERROR)` 判断连接成功？
4. `read()/write()` 经过几层调用才到系统调用？DirectBuffer vs HeapBuffer 有什么区别？
5. 6 个状态（`ST_UNCONNECTED → ST_KILLED`）是怎么流转的？
6. `channel.close()` 在有线程阻塞在 `read()` 时怎么安全关闭？
7. 3 把锁（`readLock / writeLock / stateLock`）各保护什么？

---

## 2. SocketChannelImpl 类概览

### 2.1 类层次

```
java.nio.channels.SocketChannel (抽象类)
  │ extends AbstractSelectableChannel → SelectableChannel → AbstractInterruptibleChannel
  │ implements ReadableByteChannel, WritableByteChannel, ScatteringByteChannel, GatheringByteChannel
  └── sun.nio.ch.SocketChannelImpl (实际实现)
        implements SelChImpl (Selector 可识别的 Channel 接口)
```

> **源码位置**：`java.base/share/classes/sun/nio/ch/SocketChannelImpl.java`（1130 行）

### 2.2 核心字段

| 字段 | 类型 | 作用 | 线程安全 |
|------|------|------|---------|
| `nd` | `static NativeDispatcher` | I/O 操作委托者（`= new SocketDispatcher()`） | static final |
| `fd` | `final FileDescriptor` | socket 的文件描述符 | final 不可变 |
| `fdVal` | `final int` | fd 的 int 值缓存 | final 不可变 |
| `readLock` | `ReentrantLock` | 保护 read/connect 操作 | 锁本身线程安全 |
| `writeLock` | `ReentrantLock` | 保护 write 操作 | 锁本身线程安全 |
| `stateLock` | `Object` | 保护 state/address/thread 等状态 | synchronized |
| `isInputClosed` | `volatile boolean` | shutdownInput 标记 | volatile |
| `isOutputClosed` | `volatile boolean` | shutdownOutput 标记 | volatile |
| `state` | `volatile int` | 状态机（需 stateLock 修改） | volatile 读 + lock 写 |
| `readerThread` | `long` | 阻塞在读操作上的 pthread_t | stateLock 保护 |
| `writerThread` | `long` | 阻塞在写操作上的 pthread_t | stateLock 保护 |
| `localAddress` | `InetSocketAddress` | 本地绑定地址 | stateLock 保护 |
| `remoteAddress` | `InetSocketAddress` | 远端地址 | stateLock 保护 |

### 2.3 状态机

```
ST_UNCONNECTED (0)  ──connect()──→  ST_CONNECTIONPENDING (1)
                                          │
                                    finishConnect()
                                          │
                                          ▼
                                    ST_CONNECTED (2)  ──close()──→  ST_CLOSING (3)
                                                                          │
                                                                   等待阻塞线程退出
                                                                          │
                                                                          ▼
                                                                   ST_KILLPENDING (4)
                                                                          │
                                                                       kill()
                                                                          │
                                                                          ▼
                                                                    ST_KILLED (5)
```

**关键设计**：状态值**单调递增**。可以安全地用 `state < ST_CONNECTED` 判断"还没连接"，用 `state > ST_CONNECTED` 判断"已关闭"。

---

## 3. Socket 创建：`SocketChannel.open()`

### 3.1 完整调用链

```
SocketChannel.open()
  └─ SelectorProvider.provider().openSocketChannel()
      └─ new SocketChannelImpl(this)
          └─ this.fd = Net.socket(true)         // true = SOCK_STREAM (TCP)
              └─ Net.socket(UNSPEC, true)
                  └─ IOUtil.newFD(socket0(preferIPv6=true, stream=true, reuse=false, fastLoopback=false))
                      └─ socket(AF_INET6, SOCK_STREAM, 0)  [系统调用]
                         + setsockopt(IPV6_V6ONLY, 0)       [禁用 V6ONLY → 双栈]
```

### 3.2 Net.socket0() — JNI 核心

```c
// Net.c L194-277
JNIEXPORT jint JNICALL
Java_sun_nio_ch_Net_socket0(JNIEnv *env, jclass cl, jboolean preferIPv6,
                            jboolean stream, jboolean reuse, jboolean ignored) {
    int type = (stream ? SOCK_STREAM : SOCK_DGRAM);
    int domain = (ipv6_available() && preferIPv6) ? AF_INET6 : AF_INET;

    fd = socket(domain, type, 0);  // ★ 创建 socket

    // 禁用 IPV6_V6ONLY → 一个 IPv6 socket 同时处理 IPv4/IPv6 连接
    if (domain == AF_INET6) {
        int arg = 0;
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &arg, sizeof(int));
    }
    return fd;
}
```

**为什么默认创建 IPv6 socket？** 设置 `IPV6_V6ONLY=0` 后，一个 IPv6 socket 可以同时处理 IPv4 和 IPv6 连接（双栈 Dual-Stack），无需创建两个 socket。IPv4 地址以 `::ffff:x.x.x.x` 形式呈现。

---

## 4. 非阻塞 connect

### 4.1 connect() 完整调用链

```
SocketChannelImpl.connect(sa)
  ├─ Net.checkAddress(sa) → InetSocketAddress
  ├─ readLock.lock() → writeLock.lock()
  │   ├─ beginConnect(blocking, isa)
  │   │   └─ state = ST_CONNECTIONPENDING       // ★ 状态: 0→1
  │   │       remoteAddress = isa
  │   ├─ Net.connect(fd, ia, port)               // 核心调用
  │   │   └─ connect0()  [JNI]
  │   │       └─ connect(fdval, &sa, sa_len)     // [系统调用]
  │   │           ├─ 返回 0 → 连接成功 (n=1)
  │   │           ├─ EINPROGRESS → IOS_UNAVAILABLE (-2)  非阻塞连接进行中
  │   │           └─ EINTR → IOS_INTERRUPTED (-3)
  │   └─ endConnect(blocking, n > 0)
  │       └─ [n > 0 时] state = ST_CONNECTED     // 状态: 1→2
  ├─ return n > 0    // true=已连接, false=连接中
  └─ [异常时] close() + throw
```

### 4.2 connect0() — JNI 层

```c
// Net.c L305-327
JNIEXPORT jint JNICALL
Java_sun_nio_ch_Net_connect0(JNIEnv *env, jclass clazz, jboolean preferIPv6,
                             jobject fdo, jobject iao, jint port) {
    SOCKETADDRESS sa;
    int sa_len = 0;
    NET_InetAddressToSockaddr(env, iao, port, &sa, &sa_len, preferIPv6);

    int rv = connect(fdval(env, fdo), &sa.sa, sa_len);  // ★ connect 系统调用
    if (rv != 0) {
        if (errno == EINPROGRESS) return IOS_UNAVAILABLE;  // -2: 非阻塞连接进行中
        if (errno == EINTR)       return IOS_INTERRUPTED;  // -3: 被信号中断
        return handleSocketError(env, errno);
    }
    return 1;  // 连接立即成功
}
```

**非阻塞 connect 行为**：socket 为非阻塞时，`connect()` 发送 SYN 后立即返回 `EINPROGRESS`，三次握手在内核后台继续。Java 层 `connect()` 返回 `false`，用户注册 `OP_CONNECT` 到 Selector 等待。

---

## 5. finishConnect — 检查连接完成

### 5.1 checkConnect() — 核心 JNI 方法

```c
// SocketChannelImpl.c L48-88
JNIEXPORT jint JNICALL
Java_sun_nio_ch_SocketChannelImpl_checkConnect(JNIEnv *env, jobject this,
                                               jobject fdo, jboolean block) {
    int error = 0;
    socklen_t n = sizeof(int);
    jint fd = fdval(env, fdo);
    struct pollfd poller;

    // 步骤 1：poll 检查 socket 是否可写（连接完成 → fd 变为可写）
    poller.fd = fd;
    poller.events = POLLOUT;
    poller.revents = 0;
    result = poll(&poller, 1, block ? -1 : 0);   // block=true 无限等, false 立即返回

    if (result < 0) {
        if (errno == EINTR) return IOS_INTERRUPTED;
        JNU_ThrowIOExceptionWithLastError(env, "poll failed");
        return IOS_THROWN;
    }
    if (!block && (result == 0)) return IOS_UNAVAILABLE;  // 连接还未完成

    // 步骤 2：getsockopt 检查连接结果
    if (result > 0) {
        errno = 0;
        result = getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &n);
        if (result < 0) return handleSocketError(env, errno);
        if (error)      return handleSocketError(env, error);   // 如 ECONNREFUSED
        if ((poller.revents & POLLHUP) != 0)
            return handleSocketError(env, ENOTCONN);
        return 1;  // ★ 连接成功
    }
    return 0;
}
```

**为什么需要 poll + getsockopt 两步？** 因为连接**失败也会触发 POLLOUT**！必须用 `getsockopt(SO_ERROR)` 区分成功（error=0）和失败（error=ECONNREFUSED/ETIMEDOUT 等）。

---

## 6. Read/Write 数据传输

### 6.1 read() 完整调用链

```
SocketChannelImpl.read(buf)
  ├─ readLock.lock()
  ├─ ensureOpenAndConnected()
  ├─ beginRead(blocking) → begin() + readerThread = NativeThread.current()
  ├─ [isInputClosed] → return EOF
  ├─ IOUtil.read(fd, buf, -1, nd)
  │   ├─ [DirectBuffer] → readIntoNativeBuffer()
  │   │   └─ nd.read(fd, address, rem)
  │   │       └─ SocketDispatcher.read() → FileDispatcherImpl.read0()  [JNI]
  │   │           └─ read(fd, buf, len)  [POSIX 系统调用]
  │   └─ [HeapBuffer] → 创建临时 DirectBuffer → read → dst.put(tmp) 拷贝
  ├─ [阻塞模式] while (n == INTERRUPTED && isOpen()) 重试
  ├─ endRead(blocking, n > 0)
  └─ return IOStatus.normalize(n)
```

### 6.2 DirectBuffer vs HeapBuffer

```
路径 1: DirectBuffer（1 次拷贝）
  内核 socket 缓冲区 ──read()──→ 堆外内存(DirectBuffer)

路径 2: HeapBuffer（2 次拷贝）
  内核 socket 缓冲区 ──read()──→ 临时 DirectBuffer ──put()──→ 堆内 byte[]
```

**HeapBuffer 为什么不能直接传给 read 系统调用？** 因为 GC 可能移动 Java 堆中的 `byte[]` 地址。`read()` 阻塞期间地址失效会导致数据写入错误位置。DirectBuffer 分配在堆外，地址固定。

### 6.3 NativeDispatcher 委托链（Unix）

```
SocketDispatcher.read(fd, addr, len)
  → FileDispatcherImpl.read0(fd, addr, len)  [JNI]
    → read(fd, buf, len)  [POSIX 系统调用]
```

Unix 上 SocketDispatcher 直接委托给 FileDispatcherImpl，因为 Unix 中 socket fd 和 file fd 使用相同的 `read/write` 系统调用（"Everything is a file"）。Windows 不同：socket 用 `recv/send`（Winsock）。

### 6.4 IOStatus 常量

| 常量 | 值 | 含义 | normalize 后 |
|------|-----|------|-------------|
| `EOF` | -1 | 对端关闭 | -1 |
| `UNAVAILABLE` | -2 | 非阻塞无数据 | 0 |
| `INTERRUPTED` | -3 | 被信号中断 | -3（循环重试） |
| `THROWN` | -4 | 已抛异常 | -4 |

### 6.5 Scatter/Gather I/O

```java
// 一次系统调用读到多个 buffer
channel.read(new ByteBuffer[]{header, body});  // → readv(fd, iov, 2)

// 一次系统调用写出多个 buffer
channel.write(new ByteBuffer[]{header, body}); // → writev(fd, iov, 2)
```

减少系统调用次数，适合 HTTP 响应等场景。

---

## 7. 关闭：implCloseSelectableChannel

### 7.1 问题：为什么关闭这么复杂？

```
线程 A：阻塞在 channel.read() → 底层 read(fd) 挂起
线程 B：调用 channel.close()
```

如果直接 `close(fd)`：fd 编号被释放 → 另一个线程 `open()` 复用该 fd → 线程 A 的 `read()` 读到别的文件数据！

### 7.2 preClose + signal + wait 协议

```java
// SocketChannelImpl.java L816-898 简化逻辑
protected void implCloseSelectableChannel() throws IOException {
    // 1. 状态 → ST_CLOSING
    synchronized (stateLock) { state = ST_CLOSING; }

    // 2. [阻塞模式] 安全关闭
    if (blocking) {
        synchronized (stateLock) {
            if (readerThread != 0 || writerThread != 0) {
                nd.preClose(fd);                      // ★ dup2(devnull, fd) 使 fd "半失效"
                if (readerThread != 0)
                    NativeThread.signal(readerThread); // ★ pthread_kill(SIGRTMAX-2)
                if (writerThread != 0)
                    NativeThread.signal(writerThread);
                while (readerThread != 0 || writerThread != 0)
                    stateLock.wait();                  // 等待阻塞线程退出
            }
        }
    } else {
        // 非阻塞模式：获取锁确保 I/O 完成即可
        readLock.lock(); writeLock.lock(); writeLock.unlock(); readLock.unlock();
    }

    // 3. 状态 → ST_KILLPENDING
    synchronized (stateLock) {
        if (connected && isRegistered()) {
            Net.shutdown(fd, SHUT_WR);               // 发 FIN，对端读到 EOF
        }
        state = ST_KILLPENDING;
    }

    // 4. 如果没注册 Selector，直接 kill
    if (!isRegistered()) kill();                      // state → ST_KILLED, nd.close(fd)
}
```

### 7.3 时序图

```
线程A (read)              线程B (close)
──────────────            ──────────────
read(fd, ...)  [阻塞]     state = ST_CLOSING
                          nd.preClose(fd) → dup2(/dev/null, fd)
                          NativeThread.signal(A) → pthread_kill(SIGRTMAX-2)
read() 返回 EINTR ←───────┘
isOpen()==false → 退出循环
endRead():
  readerThread = 0
  stateLock.notifyAll() ──→ 唤醒线程B
                          state = ST_KILLPENDING
                          kill() → nd.close(fd)  ★ 真正关闭
```

**preClose 的关键**：`dup2(devnull, fd)` 使 fd 指向 `/dev/null`。这样：
- 正在阻塞的 `read(fd)` 收到信号返回 `EINTR`
- 如果信号在 read 返回后才到达，再次 `read(fd)` 读到 `/dev/null` → EOF
- fd 编号不会被释放，不会被其他 `open()` 复用

### 7.4 NativeThread.signal() 底层

```c
// NativeThread.c (Unix)
// 初始化时安装空信号处理器（改变默认"终止进程"行为为"中断系统调用"）
static void nullHandler(int sig) { }
sigaction(INTERRUPT_SIGNAL, &sa, &osa);  // INTERRUPT_SIGNAL = SIGRTMAX - 2

// signal 方法
void Java_sun_nio_ch_NativeThread_signal(JNIEnv *env, jclass cl, jlong thread) {
    pthread_kill((pthread_t)thread, INTERRUPT_SIGNAL);  // 发送信号使 read 返回 EINTR
}
```

---

## 8. configureBlocking — 阻塞模式切换

```java
// 需同时持有 readLock + writeLock + stateLock
protected void implConfigureBlocking(boolean block) throws IOException {
    readLock.lock();
    try { writeLock.lock();
        try { synchronized (stateLock) {
            ensureOpen();
            IOUtil.configureBlocking(fd, block);  // ★ JNI
        }} finally { writeLock.unlock(); }
    } finally { readLock.unlock(); }
}
```

```c
// IOUtil.c — Native 实现
static int configureBlocking(int fd, jboolean blocking) {
    int flags = fcntl(fd, F_GETFL);
    int newflags = blocking ? (flags & ~O_NONBLOCK) : (flags | O_NONBLOCK);
    return (flags == newflags) ? 0 : fcntl(fd, F_SETFL, newflags);
}
```

---

## 9. bind / shutdown

### 9.1 bind

```
channel.bind(local)
  → Net.bind(fd, addr, port) → bind0() [JNI]
    → NET_Bind(fd, &sa, sa_len) → bind(fd, &sa, sa_len)  [系统调用]
  → localAddress = Net.localAddress(fd)  // 获取内核分配的实际地址
```

### 9.2 shutdown — 半关闭

```java
shutdownInput()  → Net.shutdown(fd, SHUT_RD)  // 后续 read 返回 EOF
shutdownOutput() → Net.shutdown(fd, SHUT_WR)  // 发送 FIN，对端 read 返回 EOF
```

```c
// Net.c L709-716
void Java_sun_nio_ch_Net_shutdown(JNIEnv *env, jclass cl, jobject fdo, jint jhow) {
    int how = (jhow == SHUT_RD) ? SHUT_RD : (jhow == SHUT_WR) ? SHUT_WR : SHUT_RDWR;
    if ((shutdown(fdval(env, fdo), how) < 0) && (errno != ENOTCONN))
        handleSocketError(env, errno);
}
```

**shutdown vs close**：`shutdown` 只改变通信状态（半关闭），不释放 fd。`close` 释放 fd 和所有资源。

---

## 10. Socket 选项

### 10.1 支持的选项

| 选项 | 系统调用 | 默认值 | 作用 |
|------|---------|--------|------|
| `TCP_NODELAY` | `setsockopt(IPPROTO_TCP, TCP_NODELAY)` | false | 禁用 Nagle 算法，降低延迟 |
| `SO_KEEPALIVE` | `setsockopt(SOL_SOCKET, SO_KEEPALIVE)` | false | TCP 保活探测（默认 2h） |
| `SO_RCVBUF` | `setsockopt(SOL_SOCKET, SO_RCVBUF)` | ~128KB | 接收缓冲区 |
| `SO_SNDBUF` | `setsockopt(SOL_SOCKET, SO_SNDBUF)` | ~128KB | 发送缓冲区 |
| `SO_LINGER` | `setsockopt(SOL_SOCKET, SO_LINGER)` | off | close 时是否等待数据发完 |
| `SO_REUSEADDR` | `setsockopt(SOL_SOCKET, SO_REUSEADDR)` | false | 允许绑定 TIME_WAIT 地址 |
| `SO_REUSEPORT` | `setsockopt(SOL_SOCKET, SO_REUSEPORT)` | false | 多进程绑定同一端口（Linux 3.9+） |

### 10.2 设置流程

```
channel.setOption(TCP_NODELAY, true)
  → SocketOptionRegistry.findOption(TCP_NODELAY, UNSPEC) → OptionKey(IPPROTO_TCP, 1)
    → setIntOption0(fd, true, IPPROTO_TCP, TCP_NODELAY, 1, false)  [JNI]
      → setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &1, 4)  [系统调用]
```

---

## 11. handleSocketError — errno 到 Java 异常映射

```c
// Net.c L782-814
jint handleSocketError(JNIEnv *env, jint errorValue) {
    char *xn;
    switch (errorValue) {
        case EINPROGRESS:     return 0;                             // 不抛异常
        case ECONNREFUSED:
        case ETIMEDOUT:
        case ENOTCONN:        xn = "ConnectException";     break;
        case EHOSTUNREACH:    xn = "NoRouteToHostException"; break;
        case EADDRINUSE:
        case EADDRNOTAVAIL:   xn = "BindException";        break;
        case EPROTO:          xn = "ProtocolException";    break;
        default:              xn = "SocketException";      break;
    }
    JNU_ThrowByNameWithLastError(env, xn, "NioSocketError");
    return IOS_THROWN;
}
```

---

## 12. SocketChannelImpl.c — sendOutOfBandData

```c
// SocketChannelImpl.c L90-96
JNIEXPORT jint JNICALL
Java_sun_nio_ch_SocketChannelImpl_sendOutOfBandData(JNIEnv* env, jclass this,
                                                    jobject fdo, jbyte b) {
    int n = send(fdval(env, fdo), (const void*)&b, 1, MSG_OOB);
    return convertReturnVal(env, n, JNI_FALSE);
}
```

通过 TCP URG 标志发送 1 字节带外数据。实际使用极少。

---

## 13. 并发模型与锁设计

### 13.1 三把锁的职责

| 锁 | 类型 | 保护对象 | 特点 |
|----|------|---------|------|
| `readLock` | `ReentrantLock` | read / connect / finishConnect | 读操作互斥 |
| `writeLock` | `ReentrantLock` | write | 写操作互斥 |
| `stateLock` | `Object` (synchronized) | state / address / thread IDs | 持有时**禁止**阻塞 I/O |

**加锁顺序**（防死锁）：`readLock → writeLock → stateLock`

**read 和 write 可以并发**：TCP 是全双工协议，读写使用不同的内核缓冲区。

### 13.2 begin/end 模式

所有可能阻塞的 I/O 操作都遵循：

```java
beginXxx(blocking) {
    begin();                               // 注册 Thread.interrupt → wakeup 钩子
    synchronized (stateLock) {
        ensureOpen();
        xxxThread = NativeThread.current(); // 记录线程
    }
}
try { /* I/O */ }
finally {
    endXxx(blocking, completed) {
        synchronized (stateLock) {
            xxxThread = 0;                 // 清除线程
            if (state == ST_CLOSING)
                stateLock.notifyAll();     // 通知 close 等待者
        }
        end(completed);                    // 移除中断钩子
    }
}
```

---

## 14. Selector 事件翻译

### 14.1 translateInterestOps — Java → Native

| Java 事件 | 值 | Native 事件 | 值 |
|-----------|-----|------------|-----|
| `OP_READ` | 1 | `POLLIN` | 1 |
| `OP_WRITE` | 4 | `POLLOUT` | 4 |
| `OP_CONNECT` | 8 | `POLLCONN` = **`POLLOUT`** | 4 |

**OP_CONNECT 和 OP_WRITE 映射到同一个 native 事件！**

### 14.2 translateReadyOps — 如何区分 OP_CONNECT 和 OP_WRITE？

```java
// POLLOUT 事件到达时：
if (POLLCONN就绪 && 注册了OP_CONNECT && isConnectionPending())
    → 翻译为 OP_CONNECT    // 连接完成

if (POLLOUT就绪 && 注册了OP_WRITE && isConnected())
    → 翻译为 OP_WRITE      // 可以写
```

靠 **Channel 的 state 字段**区分，不靠 native 事件类型。这就是状态机设计的价值。

---

## 15. 面试常见问题

### Q1：SocketChannel.open() 创建的是 IPv4 还是 IPv6 socket？

默认创建 **IPv6 socket**（`AF_INET6`），设置 `IPV6_V6ONLY=0` 启用双栈，同时处理 IPv4/IPv6。  
源码：`Net.socket0()` 中 `domain = (ipv6_available() && preferIPv6) ? AF_INET6 : AF_INET`。

### Q2：非阻塞 connect 的完整流程？

1. `configureBlocking(false)` → `fcntl(O_NONBLOCK)`
2. `connect()` → `connect()` 系统调用返回 `EINPROGRESS`，Java 返回 `false`
3. 注册 `OP_CONNECT` → Selector 实际监听 `EPOLLOUT`
4. `select()` → `epoll_wait()` 返回 `EPOLLOUT`（三次握手完成）
5. `finishConnect()` → `poll(POLLOUT) + getsockopt(SO_ERROR)` 确认成功
6. state: `UNCONNECTED → CONNECTIONPENDING → CONNECTED`

### Q3：HeapBuffer 为什么不能直接传给 read 系统调用？

GC 可能移动 Java 堆中的 `byte[]` 地址。`read()` 阻塞期间地址失效会导致数据写入错误位置。JDK 的做法：先 read 到临时 DirectBuffer，再 `dst.put(tmp)` 拷贝到 HeapBuffer。

### Q4：close() 时有线程阻塞在 read() 怎么处理？

使用 **preClose + signal + wait** 三步协议：
1. `preClose(fd)` → `dup2(/dev/null, fd)` 使 fd "半失效"（不释放 fd 编号）
2. `NativeThread.signal(reader)` → `pthread_kill(SIGRTMAX-2)` 使 `read()` 返回 `EINTR`
3. 等待阻塞线程在 `endRead()` 中 `notifyAll`
4. 最后 `kill()` → `close(fd)` 真正关闭

### Q5：POLLCONN == POLLOUT，OP_CONNECT 和 OP_WRITE 怎么区分？

在内核层面是同一个事件（socket 可写）。JDK 在 `translateReadyOps()` 中根据 **Channel 的 state** 区分：
- `state == ST_CONNECTIONPENDING` → `OP_CONNECT`
- `state == ST_CONNECTED` → `OP_WRITE`

---

## 16. 源码文件交叉引用

| 文件 | 路径 | 行数 | 角色 |
|------|------|------|------|
| `SocketChannelImpl.java` | `share/classes/sun/nio/ch/` | 1130 | 核心实现 |
| `SocketChannelImpl.c` | `unix/native/libnio/ch/` | 97 | checkConnect + sendOOB |
| `Net.java` | `share/classes/sun/nio/ch/` | 682 | 网络操作 Java 层 |
| `Net.c` | `unix/native/libnio/ch/` | 815 | socket/bind/connect/poll 等 |
| `IOUtil.java` | `share/classes/sun/nio/ch/` | 450 | read/write/configureBlocking |
| `IOUtil.c` | `unix/native/libnio/ch/` | 231 | configureBlocking native |
| `SocketDispatcher.java` | `unix/classes/sun/nio/ch/` | 62 | Unix I/O 分发器 |
| `NativeDispatcher.java` | `share/classes/sun/nio/ch/` | 81 | 抽象 I/O 分发器 |
| `FileDispatcherImpl.java` | `unix/classes/sun/nio/ch/` | 186 | read0/write0 Java 声明 |
| `FileDispatcherImpl.c` | `unix/native/libnio/ch/` | 374 | read/write 系统调用 |
| `NativeThread.java` | `unix/classes/sun/nio/ch/` | 62 | current()/signal() |
| `NativeThread.c` | `unix/native/libnio/ch/` | 105 | pthread_self/pthread_kill |
| `IOStatus.java` | `share/classes/sun/nio/ch/` | 85 | EOF/UNAVAILABLE/INTERRUPTED |
| `SelChImpl.java` | `share/classes/sun/nio/ch/` | 72 | translateOps 接口 |
