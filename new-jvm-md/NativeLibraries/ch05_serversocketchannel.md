# 第 5 章：ServerSocketChannel — TCP 服务端全链路分析

> **源码版本**：OpenJDK 11  
> **标准环境**：Linux x86_64  
> **前置依赖**：[第 4 章 SocketChannel](ch04_socketchannel_tcp.md)

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文对 **第 5 章：ServerSocketChannel — TCP 服务端全链路分析** 进行源码级分析：追踪关键函数的执行路径，分析涉及的数据结构，解释每个设计决策的原因。

### 0.2 为什么需要？

仅靠文档和注释无法完全理解 JVM 的行为——很多关键细节只存在于源码中。源码级分析能建立对 JVM 行为的精确理解。

### 0.3 怎么解决？

从入口函数出发，自顶向下追踪调用链；对每个关键函数，分析其输入/输出/副作用；对每个数据结构，分析其字段含义和生命周期。

### 0.4 为什么这样设计？

分析过程中重点关注「为什么」：为什么选择这个数据结构？为什么这样处理边界情况？这些问题的答案往往揭示了 JVM 设计的精髓。

---


## 1. 问题引入

### 1.1 核心问题

```java
ServerSocketChannel ssc = ServerSocketChannel.open();
ssc.bind(new InetSocketAddress(8080), 128);
ssc.configureBlocking(false);
ssc.register(selector, SelectionKey.OP_ACCEPT);

// Selector 循环
while (true) {
    selector.select();
    for (SelectionKey key : selector.selectedKeys()) {
        if (key.isAcceptable()) {
            SocketChannel client = ssc.accept();  // ★ 核心
            client.configureBlocking(false);
            client.register(selector, SelectionKey.OP_READ);
        }
    }
}
```

这段经典的 NIO 服务端代码，底层发生了什么？

```
ServerSocketChannel.open()  → socket(AF_INET6, SOCK_STREAM, 0) + SO_REUSEADDR
bind(addr, 128)             → bind(fd, &sa, len) + listen(fd, 128)
configureBlocking(false)    → fcntl(fd, F_SETFL, O_NONBLOCK)
accept()                    → accept(fd, &sa, &len)
                              → [非阻塞] EAGAIN → return null
                              → [有连接]  返回新 fd → new SocketChannelImpl(newfd)
```

### 1.2 本章要回答的问题

1. `ServerSocketChannel.open()` 和 `SocketChannel.open()` 创建的 socket 有什么区别？
2. `bind()` 方法为什么同时做了 `bind + listen`？backlog 参数怎么处理？
3. `accept()` 在非阻塞模式下返回 `null` 是怎么实现的？
4. `accept0()` 为什么要用 `for(;;)` 循环忽略 `ECONNABORTED`？
5. 新连接的 fd 怎么包装成 `SocketChannelImpl`？状态直接是 `ST_CONNECTED`？
6. 状态机只有 4 个状态（比 SocketChannel 少 2 个），为什么？
7. `initIDs()` 的 JNI 字段缓存模式是什么？

---

## 2. ServerSocketChannelImpl 类概览

### 2.1 类层次

```
java.nio.channels.ServerSocketChannel (抽象类)
  │ extends AbstractSelectableChannel → SelectableChannel → AbstractInterruptibleChannel
  │ validOps() = OP_ACCEPT (仅支持 accept 操作)
  │
  └── sun.nio.ch.ServerSocketChannelImpl (实际实现)
        implements SelChImpl
```

> **源码位置**：`java.base/share/classes/sun/nio/ch/ServerSocketChannelImpl.java`（556 行）

### 2.2 核心字段

| 字段 | 类型 | 作用 |
|------|------|------|
| `nd` | `static NativeDispatcher` | `= new SocketDispatcher()`，用于 close/preClose |
| `fd` | `final FileDescriptor` | 监听 socket 的 fd |
| `fdVal` | `final int` | fd 的 int 值缓存 |
| `acceptLock` | `ReentrantLock` | 保护 accept 操作（只有一把，不像 SocketChannel 有 read+write 两把） |
| `stateLock` | `Object` | 保护状态字段 |
| `state` | `int` | 4 个状态，单调递增 |
| `thread` | `long` | 阻塞在 accept 上的 pthread_t |
| `localAddress` | `InetSocketAddress` | 监听地址，null 表示未绑定 |
| `isReuseAddress` | `boolean` | SO_REUSEADDR 模拟标记（Windows exclusive bind） |
| `socket` | `ServerSocket` | BIO 适配器，按需创建 |

### 2.3 与 SocketChannelImpl 的对比

| 特性 | ServerSocketChannelImpl | SocketChannelImpl |
|------|------------------------|-------------------|
| 状态数 | **4** (INUSE→CLOSING→KILLPENDING→KILLED) | **6** (+CONNECTIONPENDING, +CONNECTED) |
| 锁数 | **2** (acceptLock + stateLock) | **3** (readLock + writeLock + stateLock) |
| I/O 操作 | 只有 accept | read + write + connect |
| validOps | OP_ACCEPT | OP_READ \| OP_WRITE \| OP_CONNECT |
| 线程记录 | 1 个 (thread) | 2 个 (readerThread + writerThread) |
| Socket 创建 | `Net.serverSocket(true)` 带 SO_REUSEADDR | `Net.socket(true)` 不带 |

### 2.4 状态机

```
ST_INUSE (0)  ──close()──→  ST_CLOSING (1)  ──→  ST_KILLPENDING (2)  ──kill()──→  ST_KILLED (3)
```

比 SocketChannel 简单得多：
- **没有 `CONNECTIONPENDING`**：服务端不需要主动连接
- **没有 `CONNECTED`**：监听 socket 本身不存在"已连接"状态
- **`ST_INUSE` 替代了 `ST_UNCONNECTED`**：语义更准确——"正在使用中"

---

## 3. Socket 创建：`ServerSocketChannel.open()`

### 3.1 完整调用链

```
ServerSocketChannel.open()
  └─ SelectorProvider.provider().openServerSocketChannel()
      └─ new ServerSocketChannelImpl(this)
          └─ this.fd = Net.serverSocket(true)           // true = SOCK_STREAM
              └─ IOUtil.newFD(socket0(isIPv6Available(), true, true, fastLoopback))
                                                         //              ^^^^
                                                         //              reuse=true ★
                  └─ socket(AF_INET6, SOCK_STREAM, 0)   [系统调用]
                     + setsockopt(IPV6_V6ONLY, 0)        [双栈]
                     + setsockopt(SO_REUSEADDR, 1)       [地址重用] ★
```

### 3.2 与 SocketChannel 创建的关键区别

```java
// Net.java
static FileDescriptor socket(boolean stream) {            // SocketChannel 用这个
    return socket(UNSPEC, stream);
    // → socket0(preferIPv6, stream, reuse=false, ...)     reuse=false
}

static FileDescriptor serverSocket(boolean stream) {      // ServerSocketChannel 用这个
    return IOUtil.newFD(socket0(isIPv6Available(), stream, true, fastLoopback));
    //                                                     reuse=true ★
}
```

| 差异 | SocketChannel | ServerSocketChannel |
|------|---------------|---------------------|
| 调用方法 | `Net.socket(true)` | `Net.serverSocket(true)` |
| `reuse` 参数 | `false` | **`true`** |
| SO_REUSEADDR | 不设置 | **自动设置** |
| `preferIPv6` 计算 | `isIPv6Available() && (family != INET)` | `isIPv6Available()` |

**为什么 ServerSocket 默认启用 SO_REUSEADDR？**

服务端重启时，之前的监听端口可能处于 `TIME_WAIT` 状态（TCP 规范要求等待 2×MSL）。没有 `SO_REUSEADDR` 的话，`bind()` 会返回 `EADDRINUSE`，导致服务无法立即重启。这是服务端的标准实践。

---

## 4. bind — 绑定并监听

### 4.1 完整调用链

```java
// ServerSocketChannelImpl.java L214-232
public ServerSocketChannel bind(SocketAddress local, int backlog) throws IOException {
    synchronized (stateLock) {
        ensureOpen();
        if (localAddress != null)
            throw new AlreadyBoundException();              // 不能重复绑定

        InetSocketAddress isa = (local == null)
            ? new InetSocketAddress(0)                      // null → 绑定 0.0.0.0:随机端口
            : Net.checkAddress(local);

        SecurityManager sm = System.getSecurityManager();
        if (sm != null) sm.checkListen(isa.getPort());

        NetHooks.beforeTcpBind(fd, isa.getAddress(), isa.getPort());
        Net.bind(fd, isa.getAddress(), isa.getPort());      // ★ bind 系统调用
        Net.listen(fd, backlog < 1 ? 50 : backlog);         // ★ listen 系统调用
        localAddress = Net.localAddress(fd);                 // 获取实际绑定地址
    }
    return this;
}
```

### 4.2 关键设计点

**bind 和 listen 合并在一个方法中**：

Java API 设计上把 `bind` 和 `listen` 合并了。用户调用一次 `ssc.bind(addr, backlog)` 就完成了两步系统调用：

```
Net.bind(fd, addr, port)  →  bind(fd, &sa, sa_len)     [绑定地址]
Net.listen(fd, backlog)   →  listen(fd, backlog)        [开始监听]
```

**backlog 参数处理**：

```java
Net.listen(fd, backlog < 1 ? 50 : backlog);
// backlog ≤ 0 → 默认 50
// backlog > 0 → 使用用户指定值
```

`backlog` 控制内核中**已完成三次握手但未被 accept 的连接队列**（accept queue）的大小。Linux 内核可能会对这个值做进一步调整（受 `net.core.somaxconn` 限制，默认 128）。

### 4.3 listen() — JNI 层

```c
// Net.c L298-303
JNIEXPORT void JNICALL
Java_sun_nio_ch_Net_listen(JNIEnv *env, jclass cl, jobject fdo, jint backlog) {
    if (listen(fdval(env, fdo), backlog) < 0)
        handleSocketError(env, errno);
}
```

直接调用 POSIX `listen()` 系统调用，失败时通过 `handleSocketError` 映射为 Java 异常。

---

## 5. accept — 接受连接（核心）

### 5.1 Java 层流程

```java
// ServerSocketChannelImpl.java L273-316
public SocketChannel accept() throws IOException {
    acceptLock.lock();
    try {
        int n = 0;
        FileDescriptor newfd = new FileDescriptor();       // 用于接收新 fd
        InetSocketAddress[] isaa = new InetSocketAddress[1]; // 用于接收远端地址

        boolean blocking = isBlocking();
        try {
            begin(blocking);                                // 注册中断钩子 + 记录线程
            do {
                n = accept(this.fd, newfd, isaa);           // ★ JNI 调用
            } while (n == IOStatus.INTERRUPTED && isOpen()); // 信号中断重试
        } finally {
            end(blocking, n > 0);
            assert IOStatus.check(n);
        }

        if (n < 1)
            return null;                                    // ★ 非阻塞模式无连接 → null

        // 新连接默认设为阻塞模式
        IOUtil.configureBlocking(newfd, true);              // ★ fcntl(newfd, ~O_NONBLOCK)

        InetSocketAddress isa = isaa[0];
        // 包装为 SocketChannelImpl，state 直接是 ST_CONNECTED
        SocketChannel sc = new SocketChannelImpl(provider(), newfd, isa);

        // 安全检查
        SecurityManager sm = System.getSecurityManager();
        if (sm != null) {
            try {
                sm.checkAccept(isa.getAddress().getHostAddress(), isa.getPort());
            } catch (SecurityException x) {
                sc.close();
                throw x;
            }
        }
        return sc;
    } finally {
        acceptLock.unlock();
    }
}
```

### 5.2 accept0() — JNI 层（完整源码分析）

```c
// ServerSocketChannelImpl.c L76-121
JNIEXPORT jint JNICALL
Java_sun_nio_ch_ServerSocketChannelImpl_accept0(JNIEnv *env, jobject this,
                                                jobject ssfdo, jobject newfdo,
                                                jobjectArray isaa)
{
    jint ssfd = (*env)->GetIntField(env, ssfdo, fd_fdID);   // 获取监听 fd
    jint newfd;
    SOCKETADDRESS sa;
    socklen_t sa_len = sizeof(SOCKETADDRESS);
    jobject remote_ia = 0;
    jobject isa;
    jint remote_port = 0;

    // ★ 关键：for(;;) 循环忽略 ECONNABORTED
    for (;;) {
        newfd = accept(ssfd, &sa.sa, &sa_len);              // accept 系统调用
        if (newfd >= 0) {
            break;                                           // 成功
        }
        if (errno != ECONNABORTED) {
            break;                                           // 其他错误退出循环
        }
        // ECONNABORTED → 继续循环重试
    }

    // 错误处理
    if (newfd < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return IOS_UNAVAILABLE;                          // -2: 非阻塞无连接
        if (errno == EINTR)
            return IOS_INTERRUPTED;                          // -3: 被信号中断
        JNU_ThrowIOExceptionWithLastError(env, "Accept failed");
        return IOS_THROWN;
    }

    // 成功：设置新 fd + 构造远端地址
    (*env)->SetIntField(env, newfdo, fd_fdID, newfd);        // 写入新 fd 值
    remote_ia = NET_SockaddrToInetAddress(env, &sa, (int *)&remote_port);
    CHECK_NULL_RETURN(remote_ia, IOS_THROWN);
    // 创建 InetSocketAddress(remoteAddr, remotePort)
    isa = (*env)->NewObject(env, isa_class, isa_ctorID, remote_ia, remote_port);
    CHECK_NULL_RETURN(isa, IOS_THROWN);
    (*env)->SetObjectArrayElement(env, isaa, 0, isa);        // 写入 isaa[0]
    return 1;                                                // 成功
}
```

### 5.3 为什么要循环忽略 ECONNABORTED？

```
┌─────────────────────────────────────────────────────────────────┐
│              ECONNABORTED 场景                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  时间线：                                                       │
│  1. 客户端发起连接 → 三次握手完成 → 连接进入 accept queue      │
│  2. 客户端立即发送 RST（如调用 close with SO_LINGER=0）         │
│  3. 服务端调用 accept() → 内核发现连接已重置                    │
│     → 返回 -1, errno = ECONNABORTED                            │
│                                                                 │
│  这是一个合法的竞态条件：连接在 accept queue 中等待时被重置。   │
│  JDK 的做法：忽略它，重试 accept。                              │
│  如果不忽略，会抛出异常中断整个 accept 循环，影响其他正常连接。 │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 5.4 非阻塞 accept 的返回值

| 返回值 | 含义 | Java 层行为 |
|--------|------|------------|
| `1` | 成功接受连接 | 包装为 SocketChannelImpl 返回 |
| `IOS_UNAVAILABLE (-2)` | 非阻塞模式下无待接受连接 | `n < 1` → `return null` |
| `IOS_INTERRUPTED (-3)` | 被信号中断 | 循环重试 |
| `IOS_THROWN (-4)` | 已抛 Java 异常 | 异常传播 |

**关键**：非阻塞模式下 `accept()` 返回 `null` 不是错误，而是正常行为——"当前没有待接受的连接"。

### 5.5 新连接的包装

```java
// accept 成功后：
IOUtil.configureBlocking(newfd, true);   // 1. 新 fd 设为阻塞模式
SocketChannel sc = new SocketChannelImpl(provider(), newfd, isa);  // 2. 包装
```

调用的是 SocketChannelImpl 的第三个构造器：

```java
// SocketChannelImpl.java L140-151
SocketChannelImpl(SelectorProvider sp, FileDescriptor fd, InetSocketAddress isa)
    throws IOException {
    super(sp);
    this.fd = fd;
    this.fdVal = IOUtil.fdVal(fd);
    synchronized (stateLock) {
        this.localAddress = Net.localAddress(fd);
        this.remoteAddress = isa;
        this.state = ST_CONNECTED;    // ★ 直接设为已连接状态！
    }
}
```

**关键点**：
- 新连接的 SocketChannel **默认是阻塞模式**（`configureBlocking(newfd, true)`）
- state 直接设为 `ST_CONNECTED`（跳过 UNCONNECTED 和 CONNECTIONPENDING）
- 用户需要手动 `client.configureBlocking(false)` 再注册到 Selector

### 5.6 为什么新连接默认阻塞？

注释原文："newly accepted socket is initially in blocking mode"。

原因：
1. **兼容性**：Java 的 `Socket` 类（BIO）默认是阻塞的
2. **安全性**：如果用户不用 Selector，阻塞模式更直观
3. **明确性**：让用户自己决定是否切换到非阻塞模式

而监听 socket 本身可能是非阻塞的（注册到 Selector），但 `accept()` 返回的新 fd 和监听 socket 的阻塞模式无关——它是一个全新的 fd。

---

## 6. initIDs — JNI 字段缓存模式

### 6.1 完整源码

```c
// ServerSocketChannelImpl.c L49-74
static jfieldID fd_fdID;         // java.io.FileDescriptor.fd 字段 ID
static jclass isa_class;         // java.net.InetSocketAddress 的全局引用
static jmethodID isa_ctorID;     // InetSocketAddress(InetAddress, int) 构造器 ID

JNIEXPORT void JNICALL
Java_sun_nio_ch_ServerSocketChannelImpl_initIDs(JNIEnv *env, jclass c) {
    jclass cls;

    // 缓存 FileDescriptor.fd 字段 ID
    cls = (*env)->FindClass(env, "java/io/FileDescriptor");
    CHECK_NULL(cls);
    fd_fdID = (*env)->GetFieldID(env, cls, "fd", "I");
    CHECK_NULL(fd_fdID);

    // 缓存 InetSocketAddress 类引用和构造器 ID
    cls = (*env)->FindClass(env, "java/net/InetSocketAddress");
    CHECK_NULL(cls);
    isa_class = (*env)->NewGlobalRef(env, cls);    // ★ 全局引用，防止 GC 回收
    if (isa_class == NULL) {
        JNU_ThrowOutOfMemoryError(env, NULL);
        return;
    }
    isa_ctorID = (*env)->GetMethodID(env, cls, "<init>",
                                     "(Ljava/net/InetAddress;I)V");
    CHECK_NULL(isa_ctorID);
}
```

### 6.2 为什么要缓存？

JNI 的 `FindClass/GetFieldID/GetMethodID` 是相对昂贵的操作（涉及字符串查找和类加载）。在高频调用的 `accept0()` 中每次都查找会造成性能损失。

**缓存模式**：
1. 在 `initIDs()`（类加载时调用一次）中查找并缓存
2. 后续 `accept0()` 直接使用缓存的 ID
3. 类引用用 `NewGlobalRef` 防止被 GC 回收（局部引用在 native 方法返回后失效）

**`accept0()` 中的使用**：
```c
(*env)->GetIntField(env, ssfdo, fd_fdID);                    // 用缓存的字段 ID 读取 fd
(*env)->NewObject(env, isa_class, isa_ctorID, remote_ia, remote_port);  // 用缓存的类+构造器
```

---

## 7. 关闭：implCloseSelectableChannel

### 7.1 关闭流程

与 SocketChannel 的模式完全一致，但更简单（只有一个阻塞线程 thread，不需要区分 reader/writer）：

```java
// ServerSocketChannelImpl.java L344-396 简化
protected void implCloseSelectableChannel() throws IOException {
    // 1. 状态 → ST_CLOSING
    synchronized (stateLock) {
        state = ST_CLOSING;
        blocking = isBlocking();
    }

    // 2. [阻塞模式] 安全关闭
    if (blocking) {
        synchronized (stateLock) {
            long th = thread;
            if (th != 0) {
                nd.preClose(fd);              // dup2(/dev/null, fd)
                NativeThread.signal(th);      // pthread_kill(SIGRTMAX-2)
                while (thread != 0)
                    stateLock.wait();          // 等待 accept 退出
            }
        }
    } else {
        acceptLock.lock();                    // 非阻塞：获取锁确保 accept 完成
        acceptLock.unlock();
    }

    // 3. 状态 → ST_KILLPENDING
    synchronized (stateLock) { state = ST_KILLPENDING; }

    // 4. 如果没注册 Selector，直接 kill
    if (!isRegistered()) kill();              // state → ST_KILLED, nd.close(fd)
}
```

**注意**：ServerSocket 关闭时**不需要 shutdown(SHUT_WR)**——因为监听 socket 没有数据传输，不需要发送 FIN。

---

## 8. Selector 事件翻译

### 8.1 translateInterestOps — Java → Native

```java
// ServerSocketChannelImpl.java L488-493
public int translateInterestOps(int ops) {
    int newOps = 0;
    if ((ops & SelectionKey.OP_ACCEPT) != 0)
        newOps |= Net.POLLIN;                // OP_ACCEPT → POLLIN
    return newOps;
}
```

| Java 事件 | 值 | Native 事件 | 值 | 含义 |
|-----------|-----|------------|-----|------|
| `OP_ACCEPT` | 16 | `POLLIN` | 1 | 监听 socket 上有新连接到达 |

**为什么 OP_ACCEPT 映射到 POLLIN？** 因为在内核看来，新连接到达 = 监听 socket 上"有数据可读"。`accept()` 就是从 accept queue 中"读取"一个连接。

### 8.2 translateReadyOps — Native → Java

```java
// ServerSocketChannelImpl.java L451-475
public boolean translateReadyOps(int ops, int initialOps, SelectionKeyImpl ski) {
    int intOps = ski.nioInterestOps();
    int oldOps = ski.nioReadyOps();
    int newOps = initialOps;

    if ((ops & Net.POLLNVAL) != 0) return false;

    if ((ops & (Net.POLLERR | Net.POLLHUP)) != 0) {
        newOps = intOps;
        ski.nioReadyOps(newOps);
        return (newOps & ~oldOps) != 0;
    }

    // POLLIN + 注册了 OP_ACCEPT → 翻译为 OP_ACCEPT
    if (((ops & Net.POLLIN) != 0) &&
        ((intOps & SelectionKey.OP_ACCEPT) != 0))
        newOps |= SelectionKey.OP_ACCEPT;

    ski.nioReadyOps(newOps);
    return (newOps & ~oldOps) != 0;
}
```

比 SocketChannel 简单得多——只需要处理一种事件 `POLLIN → OP_ACCEPT`。

### 8.3 与 SocketChannel 的事件翻译对比

| Channel 类型 | 支持的操作 | POLLIN 映射 | POLLOUT 映射 |
|-------------|-----------|------------|-------------|
| ServerSocketChannel | OP_ACCEPT | → OP_ACCEPT | (不使用) |
| SocketChannel | OP_READ, OP_WRITE, OP_CONNECT | → OP_READ (已连接时) | → OP_CONNECT (连接中) / OP_WRITE (已连接) |

---

## 9. pollAccept — 带超时的 accept 等待

```java
// ServerSocketChannelImpl.java L430-446
boolean pollAccept(long timeout) throws IOException {
    assert Thread.holdsLock(blockingLock()) && isBlocking();
    acceptLock.lock();
    try {
        boolean polled = false;
        try {
            begin(true);
            int events = Net.poll(fd, Net.POLLIN, timeout);   // poll(fd, POLLIN, timeout)
            polled = (events != 0);
        } finally {
            end(true, polled);
        }
        return polled;
    } finally {
        acceptLock.unlock();
    }
}
```

这个方法供 `ServerSocketAdaptor`（BIO 适配器）使用，实现 `ServerSocket.accept()` 的超时功能。底层使用 `Net.poll()` → `poll(fd, POLLIN, timeout)` 系统调用。

---

## 10. begin/end 模式

### 10.1 与 SocketChannel 的对比

ServerSocketChannel 只有一个 `thread` 字段（只做 accept 操作），所以 begin/end 更简单：

```java
// begin
private void begin(boolean blocking) throws ClosedChannelException {
    if (blocking)
        begin();                          // 中断钩子
    synchronized (stateLock) {
        ensureOpen();
        if (localAddress == null)
            throw new NotYetBoundException();  // ★ 额外检查：必须已 bind
        if (blocking)
            thread = NativeThread.current();
    }
}

// end
private void end(boolean blocking, boolean completed) throws AsynchronousCloseException {
    if (blocking) {
        synchronized (stateLock) {
            thread = 0;
            if (state == ST_CLOSING)
                stateLock.notifyAll();    // 通知 close 等待者
        }
        end(completed);
    }
}
```

**与 SocketChannel begin 的区别**：增加了 `localAddress == null` 检查——accept 前必须已经 bind。

---

## 11. 完整时序图

```
┌─────────────────────────────────────────────────────────────────────────┐
│             ServerSocketChannel 典型 NIO 服务端时序                      │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ServerSocketChannel.open()                                             │
│  ┌────────────┐    ┌────────────────────────────────────┐              │
│  │ new Impl   │───→│ socket(AF_INET6, SOCK_STREAM, 0)  │              │
│  │            │    │ setsockopt(IPV6_V6ONLY, 0)         │              │
│  │            │    │ setsockopt(SO_REUSEADDR, 1) ★      │              │
│  └────────────┘    └────────────────────────────────────┘              │
│                                                                         │
│  ssc.bind(addr, 128)                                                    │
│  ┌────────────┐    ┌────────────────────────────────────┐              │
│  │ Net.bind   │───→│ bind(fd, &sa, sa_len)              │              │
│  │ Net.listen │───→│ listen(fd, 128)                    │              │
│  └────────────┘    └────────────────────────────────────┘              │
│                                                                         │
│  ssc.configureBlocking(false)                                           │
│  ┌────────────┐    ┌────────────────────────────────────┐              │
│  │ IOUtil     │───→│ fcntl(fd, F_SETFL, O_NONBLOCK)    │              │
│  └────────────┘    └────────────────────────────────────┘              │
│                                                                         │
│  ssc.register(selector, OP_ACCEPT)                                      │
│  → processUpdateQueue → epoll_ctl(ADD, EPOLLIN)                         │
│                                                                         │
│  客户端发起连接 → 三次握手完成 → 连接进入 accept queue                  │
│                                                                         │
│  selector.select()                                                      │
│  → epoll_wait() 返回 EPOLLIN ← accept queue 非空                       │
│  → translateReadyOps: POLLIN → OP_ACCEPT                                │
│                                                                         │
│  ssc.accept()                                                           │
│  ┌────────────┐    ┌────────────────────────────────────┐              │
│  │ accept0    │───→│ accept(ssfd, &sa, &sa_len)         │              │
│  │ [JNI]     │    │ → newfd = 已连接的 socket fd        │              │
│  └────────────┘    │ → sa = 客户端地址                   │              │
│                    └──────────────┬─────────────────────┘              │
│                                   │                                     │
│  configureBlocking(newfd, true)   │ 新连接默认阻塞                      │
│                                   │                                     │
│  new SocketChannelImpl(sp, newfd, isa)                                  │
│  └─ state = ST_CONNECTED          │ 直接已连接状态                      │
│                                   │                                     │
│  client.configureBlocking(false)  │ 用户手动切非阻塞                    │
│  client.register(selector, OP_READ)                                     │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 12. 面试常见问题

### Q1：ServerSocketChannel.open() 和 SocketChannel.open() 有什么区别？

两者都调用 `socket(AF_INET6, SOCK_STREAM, 0)` 创建 TCP socket。关键区别：
- ServerSocketChannel 额外设置 `SO_REUSEADDR=1`（通过 `reuse=true` 参数），确保服务重启时可以立即绑定 TIME_WAIT 状态的端口
- ServerSocketChannel 在 `bind()` 中调用 `listen()`，使 socket 进入监听状态

### Q2：accept() 在非阻塞模式下怎么工作？

非阻塞模式下，`accept()` 系统调用如果 accept queue 为空，返回 `-1`，`errno = EAGAIN`。JDK 将其翻译为 `IOS_UNAVAILABLE(-2)`，Java 层 `accept()` 返回 `null`。这是正常行为，不是错误。

### Q3：为什么 accept0 要忽略 ECONNABORTED？

因为在 `accept()` 系统调用之前，客户端可能已经发送 RST 重置了连接。此时 accept 返回 `ECONNABORTED`。这是一个合法的竞态条件，JDK 选择忽略并重试，避免影响其他正常连接的接受。

### Q4：新连接的 SocketChannel 为什么默认是阻塞模式？

1. **兼容性**：与 `ServerSocket.accept()` 返回的 `Socket` 行为一致
2. **安全性**：不用 Selector 时阻塞模式更直观
3. **独立性**：新 fd 的阻塞模式与监听 socket 无关，是独立的设置

用户需要手动 `client.configureBlocking(false)` 后再注册到 Selector。

### Q5：backlog 参数到底控制什么？

控制内核 accept queue 的大小——即已完成三次握手但尚未被 `accept()` 取走的连接数。
- JDK 默认值：`backlog < 1 ? 50 : backlog`（传入 0 或负数 → 50）
- Linux 上限：`min(backlog, net.core.somaxconn)`（默认 128）
- 超出 backlog 的新连接会被内核丢弃（RST）或排队（取决于 `tcp_abort_on_overflow` 设置）

---

## 13. 源码文件交叉引用

| 文件 | 路径 | 行数 | 角色 |
|------|------|------|------|
| `ServerSocketChannelImpl.java` | `share/classes/sun/nio/ch/` | 556 | 核心实现 |
| `ServerSocketChannelImpl.c` | `unix/native/libnio/ch/` | 122 | accept0 + initIDs |
| `Net.java` | `share/classes/sun/nio/ch/` | 682 | serverSocket() / bind() / listen() |
| `Net.c` | `unix/native/libnio/ch/` | 815 | bind0 / listen / handleSocketError |
| `SocketChannelImpl.java` | `share/classes/sun/nio/ch/` | 1130 | 新连接包装为此类 |
| `IOUtil.java` | `share/classes/sun/nio/ch/` | 450 | configureBlocking |
| `NativeThread.java` | `unix/classes/sun/nio/ch/` | 62 | current() / signal() |
| `SocketDispatcher.java` | `unix/classes/sun/nio/ch/` | 62 | nd: close / preClose |
| `ServerSocketAdaptor.java` | `share/classes/sun/nio/ch/` | — | BIO 适配器，用 pollAccept |
| `SelChImpl.java` | `share/classes/sun/nio/ch/` | 72 | translateOps 接口 |
