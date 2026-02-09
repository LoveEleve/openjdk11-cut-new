# 第 8 章：Socket — 传统阻塞 I/O (BIO)

> **核心问题**：NIO 的 SocketChannel 已经很强大了，为什么 JDK 还保留传统的 `Socket`/`ServerSocket` BIO 模型？BIO 模型下，一个线程阻塞在 `read()` 上，另一个线程调用 `close()`，底层是怎么安全地唤醒阻塞线程的？

---

## 1. 为什么还需要 BIO？

NIO 虽然性能高，但有两个代价：

1. **编程复杂度高**：Selector + Channel + Buffer 三件套，事件驱动模型需要状态机，对简单场景（如 JDBC 驱动、RMI、LDAP 客户端）是过度设计
2. **SO_TIMEOUT 语义不同**：BIO 的 `Socket.setSoTimeout()` 可以精确控制单次 `read()` 的超时，而 NIO 需要自己用 `Selector.select(timeout)` 模拟

**BIO 的定位**：简单的请求-响应模式，一个连接一个线程，代码直观。传统 Java EE 的 `ServerSocket` + 线程池模型至今仍广泛使用。

---

## 2. 类继承体系

```
java.net.SocketImpl (abstract)
  └── AbstractPlainSocketImpl (abstract, share/)
        ├── 字段: timeout, fdUseCount, fdLock, closePending, connectionReset
        ├── 模板方法: create(), connect(), bind(), listen(), accept(), close()
        ├── FD 引用计数: acquireFD() / releaseFD()
        ├── 抽象 native: socketCreate/socketConnect/socketBind/socketListen/
        │                 socketAccept/socketClose0/socketSetOption0/socketGetOption
        └── PlainSocketImpl (unix/, 具体实现)
              ├── static { initProto(); }  // 缓存字段 ID + 创建 marker_fd
              ├── 所有抽象方法 → native 实现 (PlainSocketImpl.c)
              └── ExtendedSocketOptions 支持 (TCP_KEEPIDLE 等)

I/O 流:
  SocketInputStream extends FileInputStream
    └── native socketRead0() → SocketInputStream.c → NET_Read()/NET_ReadWithTimeout()

  SocketOutputStream extends FileOutputStream
    └── native socketWrite0() → SocketOutputStream.c → NET_Send()
```

**关键设计**：`AbstractPlainSocketImpl` 持有 `fdLock` + `fdUseCount` + `closePending` 三元组，构成线程安全的 "延迟关闭" 协议。这和 NIO 的 `begin()/end()` 机制解决同一个问题——"一个线程在阻塞 I/O，另一个线程要关闭 fd"。

---

## 3. initProto — 初始化与 marker_fd

PlainSocketImpl 类加载时执行 `initProto()`：

```c
// PlainSocketImpl.c:114
JNIEXPORT void JNICALL
Java_java_net_PlainSocketImpl_initProto(JNIEnv *env, jclass cls) {
    psi_fdID       = GetFieldID(env, cls, "fd", "Ljava/io/FileDescriptor;");
    psi_addressID  = GetFieldID(env, cls, "address", "Ljava/net/InetAddress;");
    psi_portID     = GetFieldID(env, cls, "port", "I");
    psi_localportID = GetFieldID(env, cls, "localport", "I");
    psi_timeoutID  = GetFieldID(env, cls, "timeout", "I");
    psi_trafficClassID = GetFieldID(env, cls, "trafficClass", "I");
    psi_serverSocketID = GetFieldID(env, cls, "serverSocket", "Ljava/net/ServerSocket;");
    psi_fdLockID   = GetFieldID(env, cls, "fdLock", "Ljava/lang/Object;");
    psi_closePendingID = GetFieldID(env, cls, "closePending", "Z");
    IO_fd_fdID     = NET_GetFileDescriptorID(env);

    initInetAddressIDs(env);

    /* 创建 marker fd，用于 dup2 延迟关闭 */
    marker_fd = getMarkerFD();
}
```

### 3.1 marker_fd 的创建

```c
// PlainSocketImpl.c:73
static int getMarkerFD() {
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == -1) {
        return -1;
    }
    shutdown(sv[0], 2);  // 双向 shutdown：读到 EOF，写报错
    close(sv[1]);        // 关闭对端
    return sv[0];        // 保留这一端作为 marker
}
```

**为什么需要 marker_fd？**

当线程 A 阻塞在 `recv(fd)` 上，线程 B 要关闭这个 socket 时，不能直接 `close(fd)`——因为 fd 编号会被内核回收复用，线程 A 可能继续在一个**完全不相关的新 fd** 上阻塞。

解决方案：`dup2(marker_fd, fd)` —— 用 marker_fd 的内容覆盖 fd，让原 fd 指向一个已 shutdown 的 socketpair。线程 A 的 `recv()` 会立刻返回 EOF（或错误），同时 **fd 编号不释放**，避免了 fd 复用问题。

> **对比 NIO**：NIO 的 `FileDispatcherImpl.init()` 用 `socketpair` + 只关闭 write 端 的方式创建 preCloseFD，原理相同，但实现细节略有不同（NIO 不做 shutdown，直接 close write 端让 read 端返回 EOF）。

---

## 4. socketCreate — 创建 socket

### 4.1 Java 层入口

```java
// AbstractPlainSocketImpl.java:129
protected synchronized void create(boolean stream) throws IOException {
    this.stream = stream;
    if (!stream) {
        ResourceManager.beforeUdpCreate();  // UDP 有 fd 配额限制
        fd = new FileDescriptor();
        try {
            socketCreate(false);
            SocketCleanable.register(fd);   // 注册 Cleaner 防泄漏
        } catch (IOException ioe) {
            ResourceManager.afterUdpClose();
            fd = null;
            throw ioe;
        }
    } else {
        fd = new FileDescriptor();
        socketCreate(true);                 // TCP 无配额限制
        SocketCleanable.register(fd);
    }
}
```

**注意**：TCP socket 没有 `ResourceManager` 配额限制，只有 UDP 有（默认 25 个，由 `sun.net.maxDatagramSockets` 控制）。

### 4.2 Native 层实现

```c
// PlainSocketImpl.c:158
JNIEXPORT void JNICALL
Java_java_net_PlainSocketImpl_socketCreate(JNIEnv *env, jobject this,
                                           jboolean stream) {
    int fd;
    int type = (stream ? SOCK_STREAM : SOCK_DGRAM);
    int domain = ipv6_available() ? AF_INET6 : AF_INET;

    // 提前缓存 SocketException 类引用，防止 fd 用尽时无法加载异常类
    if (socketExceptionCls == NULL) {
        jclass c = FindClass(env, "java/net/SocketException");
        socketExceptionCls = NewGlobalRef(env, c);
    }

    if ((fd = socket(domain, type, 0)) == -1) {
        NET_ThrowNew(env, errno, "can't create socket");
        return;
    }

    // 关闭 IPV6_V6ONLY，启用双栈
    if (domain == AF_INET6) {
        int arg = 0;
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &arg, sizeof(int));
    }

    // 如果是 ServerSocket，自动启用 SO_REUSEADDR + 非阻塞模式
    ssObj = GetObjectField(env, this, psi_serverSocketID);
    if (ssObj != NULL) {
        int arg = 1;
        SET_NONBLOCKING(fd);
        NET_SetSockOpt(fd, SOL_SOCKET, SO_REUSEADDR, &arg, sizeof(arg));
    }

    SetIntField(env, fdObj, IO_fd_fdID, fd);
}
```

**关键点**：

| 行为 | 原因 |
|------|------|
| `socketExceptionCls` 提前缓存 | fd 耗尽时 `FindClass` 需要分配内存打开 .class 文件，可能因 fd 不足而失败，抛出 `NoClassDefFoundError` 而非 `SocketException` |
| `IPV6_V6ONLY = 0` | 启用双栈：一个 AF_INET6 socket 同时处理 IPv4 和 IPv6 连接 |
| ServerSocket 自动 `SO_REUSEADDR` | 避免 TIME_WAIT 状态下重启服务绑定失败 |
| ServerSocket 设为非阻塞 | 因为 `accept()` 的超时实现依赖 `poll() + accept()` 两步操作。如果 `poll` 返回可读但 `accept` 时连接已被 RST（ECONNABORTED），阻塞模式下会一直等待下一个连接而超过用户设定的 timeout |

---

## 5. socketConnect — 带超时的连接

这是 BIO 模型中最复杂的 native 方法，因为需要在**阻塞语义**下实现**超时控制**。

### 5.1 timeout == 0（无超时）

```c
// PlainSocketImpl.c:270
if (timeout <= 0) {
    connect_rv = NET_Connect(fd, &sa.sa, len);
    // Solaris 特殊处理：EINPROGRESS 在阻塞模式下也可能出现（信号中断）
    // 需要 poll(POLLOUT) 等待连接完成
}
```

`NET_Connect` 的定义在 `linux_close.c` 中（见第 8 节），它包装了 `connect()` 系统调用，处理了 EINTR 重试和线程注册。

### 5.2 timeout > 0（带超时）

```
┌──────────────────────────────────────────────────────────────────┐
│ socketConnect 带超时流程                                          │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. SET_NONBLOCKING(fd)           ← 临时切非阻塞                  │
│  2. connect(fd, addr, len)        ← 立即返回 EINPROGRESS          │
│  3. while (timeout > 0):                                         │
│       poll(fd, POLLOUT, remaining_timeout)                       │
│       if poll == 0 → SocketTimeoutException                      │
│       if poll > 0  → break (连接完成或失败)                        │
│       if EINTR     → 调整 timeout 继续                            │
│  4. getsockopt(SO_ERROR) → 检查真正的连接结果                      │
│  5. SET_BLOCKING(fd)              ← 恢复阻塞                     │
│                                                                  │
│  超时后的善后:                                                     │
│    SET_BLOCKING(fd)                                              │
│    shutdown(fd, 2)    ← 确保半建立的连接被清理                      │
│    throw SocketTimeoutException                                  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

核心代码：

```c
// PlainSocketImpl.c:317-401
SET_NONBLOCKING(fd);
connect_rv = connect(fd, &sa.sa, len);

if (connect_rv != 0) {
    if (errno != EINPROGRESS) {
        // 立即失败（如 ENETUNREACH）
        SET_BLOCKING(fd);
        throw ConnectException;
        return;
    }
    
    // poll 等待连接完成
    while (1) {
        struct pollfd pfd = { .fd = fd, .events = POLLOUT };
        connect_rv = NET_Poll(&pfd, 1, nanoTimeout / NET_NSEC_PER_MSEC);
        
        if (connect_rv >= 0) break;       // 完成或超时
        if (errno != EINTR) break;         // 非中断错误
        
        // EINTR：重算剩余超时
        newNanoTime = JVM_NanoTime(env, 0);
        nanoTimeout -= (newNanoTime - prevNanoTime);
        if (nanoTimeout < NET_NSEC_PER_MSEC) {
            connect_rv = 0;  // 视为超时
            break;
        }
        prevNanoTime = newNanoTime;
    }
    
    if (connect_rv == 0) {
        // 超时
        SET_BLOCKING(fd);
        shutdown(fd, 2);  // 清理半连接
        throw SocketTimeoutException("connect timed out");
        return;
    }
    
    // 检查连接是否真正成功
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &connect_rv, &optlen);
}

SET_BLOCKING(fd);  // 恢复阻塞模式
```

### 5.3 错误码 → 异常映射

```
┌─────────────────────────┬───────────────────────────────────────────────┐
│ errno                   │ Java 异常                                     │
├─────────────────────────┼───────────────────────────────────────────────┤
│ ECONNREFUSED            │ ConnectException("Connection refused")        │
│ ETIMEDOUT               │ ConnectException("Connection timed out")      │
│ EHOSTUNREACH            │ NoRouteToHostException("Host unreachable")    │
│ EADDRNOTAVAIL           │ NoRouteToHostException("Address not available")│
│ EISCONN / EBADF         │ SocketException("Socket closed")             │
│ EPROTO                  │ ProtocolException("Protocol error")          │
│ EINVAL (Linux only)     │ SocketException("Invalid argument...")       │
│ 其他                     │ SocketException("connect failed")            │
└─────────────────────────┴───────────────────────────────────────────────┘
```

**Linux 特殊处理**：`EINVAL` 在 Linux 上可能意味着 `EADDRNOTAVAIL`（绑定到 loopback 地址后 connect 外部地址），这是 Linux 内核的 bug（返回了错误的 errno），JDK 在此做了兼容处理。

### 5.4 连接成功后的收尾

```c
// 设置远端地址和端口到 Java 字段
SetObjectField(env, this, psi_addressID, iaObj);
SetIntField(env, this, psi_portID, port);

// 如果之前没有 bind，获取系统分配的本地端口
if (localport == 0) {
    getsockname(fd, &sa.sa, &slen);
    localport = NET_GetPortFromSockaddr(&sa);
    SetIntField(env, this, psi_localportID, localport);
}
```

---

## 6. socketBind / socketListen / socketAccept

### 6.1 socketBind

```c
// PlainSocketImpl.c:484
JNIEXPORT void JNICALL
Java_java_net_PlainSocketImpl_socketBind(JNIEnv *env, jobject this,
                                         jobject iaObj, jint localport) {
    NET_InetAddressToSockaddr(env, iaObj, localport, &sa, &len, JNI_TRUE);
    
    if (NET_Bind(fd, &sa, len) < 0) {
        if (errno == EADDRINUSE || errno == EADDRNOTAVAIL ||
            errno == EPERM || errno == EACCES) {
            throw BindException("Bind failed");
        } else {
            throw SocketException("Bind failed");
        }
    }
    
    // 端口 0 → 获取系统分配的端口
    if (localport == 0) {
        getsockname(fd, &sa.sa, &slen);
        localport = NET_GetPortFromSockaddr(&sa);
    }
    SetIntField(env, this, psi_localportID, localport);
}
```

**注意**：`EADDRINUSE`（地址已被使用）和 `EACCES`（端口 < 1024 无权限）都映射到 `BindException`，帮助用户区分绑定失败的原因。

### 6.2 socketListen

```c
// PlainSocketImpl.c:551
JNIEXPORT void JNICALL
Java_java_net_PlainSocketImpl_socketListen(JNIEnv *env, jobject this, jint count) {
    // Solaris 2.6 bug 兼容：Integer.MAX_VALUE 减 1
    if (count == 0x7fffffff)
        count -= 1;
    
    if (listen(fd, count) == -1) {
        throw SocketException("Listen failed");
    }
}
```

直接调用 POSIX `listen()`，backlog 参数直传。

### 6.3 socketAccept — 最复杂的服务端操作

```c
// PlainSocketImpl.c:587
JNIEXPORT void JNICALL
Java_java_net_PlainSocketImpl_socketAccept(JNIEnv *env, jobject this,
                                           jobject socket) {
    jint timeout = GetIntField(env, this, psi_timeoutID);
    
    for (;;) {
        // Step 1: 等待可读事件（有新连接到达）
        if (timeout <= 0) {
            ret = NET_Timeout(env, fd, -1, 0);      // 无限等待
        } else {
            ret = NET_Timeout(env, fd, nanoTimeout / NET_NSEC_PER_MSEC, prevNanoTime);
        }
        if (ret == 0) throw SocketTimeoutException("Accept timed out");
        if (ret == -1) throw SocketException(...);
        
        // Step 2: accept 新连接
        newfd = NET_Accept(fd, &sa.sa, &slen);
        
        if (newfd >= 0) {
            SET_BLOCKING(newfd);   // 新 socket 强制设为阻塞模式
            break;
        }
        
        // Step 3: 忽略 ECONNABORTED/EWOULDBLOCK/EAGAIN
        if (!(errno == ECONNABORTED || errno == EWOULDBLOCK || errno == EAGAIN)) {
            break;  // 真正的错误，退出循环
        }
        
        // Step 4: 调整超时后继续
        if (nanoTimeout >= NET_NSEC_PER_MSEC) {
            nanoTimeout -= (currNanoTime - prevNanoTime);
            if (nanoTimeout < NET_NSEC_PER_MSEC) {
                throw SocketTimeoutException("Accept timed out");
            }
            prevNanoTime = currNanoTime;
        }
    }
    
    // Step 5: 填充新 socket 的信息
    socketAddressObj = NET_SockaddrToInetAddress(env, &sa, &port);
    SetIntField(env, socketFdObj, IO_fd_fdID, newfd);
    SetObjectField(env, socket, psi_addressID, socketAddressObj);
    SetIntField(env, socket, psi_portID, port);
    // 新 socket 的 localport 等于 ServerSocket 的 localport
    SetIntField(env, socket, psi_localportID,
                GetIntField(env, this, psi_localportID));
}
```

**为什么需要 for 循环忽略 ECONNABORTED？**

操作系统可能在 `poll()` 返回可读和 `accept()` 调用之间，就已经收到了客户端的 RST。此时 `accept()` 返回 `ECONNABORTED`（"连接被对方中断"）。这不是服务端的错误，应该忽略并重新等待下一个连接。

**EWOULDBLOCK/EAGAIN** 出现的原因：ServerSocket 在 `socketCreate` 中被设为非阻塞模式，如果 `poll` 和 `accept` 之间连接被取消，`accept` 可能返回 EWOULDBLOCK。

**newfd == -2 的含义**：`NET_Accept` 被唤醒信号中断后返回 -2（来自 `linux_close.c` 的 `closefd` 机制），映射到 `InterruptedIOException`。

---

## 7. socketRead0 — 读数据

### 7.1 Java 层：SocketInputStream

```java
// SocketInputStream.java:143
int read(byte b[], int off, int length, int timeout) throws IOException {
    if (eof) return -1;
    if (impl.isConnectionReset()) throw new SocketException("Connection reset");
    
    FileDescriptor fd = impl.acquireFD();  // ++fdUseCount
    try {
        n = socketRead(fd, b, off, length, timeout);
        if (n > 0) return n;
    } catch (ConnectionResetException rstExc) {
        impl.setConnectionReset();
    } finally {
        impl.releaseFD();  // --fdUseCount, 可能触发 socketClose
    }
    
    if (impl.isClosedOrPending()) throw new SocketException("Socket closed");
    if (impl.isConnectionReset()) throw new SocketException("Connection reset");
    eof = true;
    return -1;
}
```

**acquireFD/releaseFD** 协议确保 `socketRead0` 期间 fd 不会被真正关闭（只会被 dup2 替换为 marker_fd）。

### 7.2 Native 层：两种路径

```c
// SocketInputStream.c:90
JNIEXPORT jint JNICALL
Java_java_net_SocketInputStream_socketRead0(JNIEnv *env, jobject this,
                                            jobject fdObj, jbyteArray data,
                                            jint off, jint len, jint timeout) {
    char BUF[MAX_BUFFER_LEN];   // 栈上缓冲区：64位系统 64KB
    char *bufP;
    
    // 缓冲区选择策略
    if (len > MAX_BUFFER_LEN) {         // > 64KB
        if (len > MAX_HEAP_BUFFER_LEN)  // 截断到 128KB
            len = MAX_HEAP_BUFFER_LEN;
        bufP = malloc(len);
        if (bufP == NULL) {             // malloc 失败退回栈缓冲区
            bufP = BUF;
            len = MAX_BUFFER_LEN;
        }
    } else {
        bufP = BUF;                     // 使用栈缓冲区
    }
    
    if (timeout) {
        nread = NET_ReadWithTimeout(env, fd, bufP, len, timeout);  // 有超时
    } else {
        nread = NET_Read(fd, bufP, len);                           // 无超时
    }
    
    if (nread > 0) {
        SetByteArrayRegion(env, data, off, nread, bufP);  // 拷贝到 Java 数组
    }
    
    if (bufP != BUF) free(bufP);
    return nread;
}
```

#### 缓冲区大小常量（Linux 64 位）

```c
// net_util_md.h
#ifdef _LP64
#define MAX_BUFFER_LEN      65536   // 64KB 栈缓冲区
#define MAX_HEAP_BUFFER_LEN 131072  // 128KB 堆上限
#else
#define MAX_BUFFER_LEN      8192    // 32位: 8KB
#define MAX_HEAP_BUFFER_LEN 65536   // 32位: 64KB
#endif
```

**为什么需要中间缓冲区？**

JNI 的 `GetByteArrayRegion/SetByteArrayRegion` 在操作 Java 数组时需要一段**固定地址**的 C 缓冲区。Java 数组地址可能因 GC 移动，不能直接传给 `recv()`。这和 NIO 中 HeapBuffer 需要中间 DirectBuffer 的原因一样。

#### 有超时的读取：NET_ReadWithTimeout

```c
// SocketInputStream.c:50
static int NET_ReadWithTimeout(JNIEnv *env, int fd, char *bufP,
                                int len, long timeout) {
    jlong nanoTimeout = (jlong) timeout * NET_NSEC_PER_MSEC;
    
    while (nanoTimeout >= NET_NSEC_PER_MSEC) {
        // Step 1: poll 等待可读
        result = NET_Timeout(env, fd, nanoTimeout / NET_NSEC_PER_MSEC, prevNanoTime);
        if (result <= 0) {
            if (result == 0)  throw SocketTimeoutException("Read timed out");
            if (errno == EBADF) throw SocketException("Socket closed");
            return -1;
        }
        
        // Step 2: 非阻塞读取
        result = NET_NonBlockingRead(fd, bufP, len);
        
        if (result == -1 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            // poll 说可读，但 recv(MSG_DONTWAIT) 返回 EAGAIN
            // 可能是虚假唤醒，重新调整超时后继续
            nanoTimeout -= (newtNanoTime - prevNanoTime);
            continue;
        }
        break;  // 成功读到数据或真正的错误
    }
    return result;
}
```

**为什么 poll 可读后 recv 还会返回 EAGAIN？**

这是一个竞态条件：
1. `poll()` 返回 POLLIN（有数据可读）
2. 在调用 `recv()` 之前，另一个线程（或内核）消费了数据
3. `recv(MSG_DONTWAIT)` 发现缓冲区空了，返回 EAGAIN

所以需要循环 + 重新 poll。

#### 无超时的读取：NET_Read

```c
// linux_close.c:368
int NET_Read(int s, void* buf, size_t len) {
    BLOCKING_IO_RETURN_INT(s, recv(s, buf, len, 0));
}
```

`NET_Read` 用 `recv()` 而不是 `read()`，因为 `recv()` 是 socket 专用的系统调用，语义更明确。

### 7.3 错误码 → 异常映射

```c
// SocketInputStream.c:138
switch (errno) {
    case ECONNRESET:
    case EPIPE:
        throw ConnectionResetException("Connection reset");
        break;
    case EBADF:
        throw SocketException("Socket closed");
        break;
    case EINTR:
        throw InterruptedIOException("Operation interrupted");
        break;
    default:
        throw SocketException("Read failed");
}
```

**ECONNRESET** 会被 Java 层捕获并转换：`ConnectionResetException` (sun.net 包) → `impl.setConnectionReset()` → 后续 `read()` 直接抛 `SocketException("Connection reset")`。这种两阶段处理确保一旦检测到连接重置，所有后续读取都立即失败，不再尝试系统调用。

---

## 8. socketWrite0 — 写数据

### 8.1 Java 层：SocketOutputStream

```java
// SocketOutputStream.java:97
private void socketWrite(byte b[], int off, int len) throws IOException {
    FileDescriptor fd = impl.acquireFD();
    try {
        socketWrite0(fd, b, off, len);
    } catch (SocketException se) {
        if (impl.isClosedOrPending())
            throw new SocketException("Socket closed");  // 替换为更清晰的错误消息
        else
            throw se;
    } finally {
        impl.releaseFD();
    }
}
```

### 8.2 Native 层：分块发送

```c
// SocketOutputStream.c:56
JNIEXPORT void JNICALL
Java_java_net_SocketOutputStream_socketWrite0(JNIEnv *env, jobject this,
                                              jobject fdObj,
                                              jbyteArray data,
                                              jint off, jint len) {
    char BUF[MAX_BUFFER_LEN];
    char *bufP;
    int buflen;
    
    // 缓冲区选择（和 read 相同策略）
    if (len <= MAX_BUFFER_LEN) {
        bufP = BUF;
        buflen = MAX_BUFFER_LEN;
    } else {
        buflen = min(MAX_HEAP_BUFFER_LEN, len);
        bufP = malloc(buflen);
        if (bufP == NULL) { bufP = BUF; buflen = MAX_BUFFER_LEN; }
    }
    
    // 外层循环：分块从 Java 数组拷贝
    while (len > 0) {
        int chunkLen = min(buflen, len);
        GetByteArrayRegion(env, data, off, chunkLen, bufP);
        
        // 内层循环：确保当前块完全发送
        int loff = 0, llen = chunkLen;
        while (llen > 0) {
            int n = NET_Send(fd, bufP + loff, llen, 0);
            if (n > 0) {
                llen -= n;
                loff += n;
                continue;
            }
            // n <= 0: 发送失败
            throw SocketException("Write failed");
            return;
        }
        
        len -= chunkLen;
        off += chunkLen;
    }
    
    if (bufP != BUF) free(bufP);
}
```

**双层循环的原因**：

| 循环层 | 职责 | 原因 |
|--------|------|------|
| 外层 `while(len > 0)` | Java 数组按 buflen 分块拷贝到 C 缓冲区 | JNI 中间缓冲区大小有限（最多 128KB） |
| 内层 `while(llen > 0)` | 确保当前块完全发送 | TCP `send()` 可能短写（内核缓冲区满时只写入部分数据） |

**对比 read vs write**：
- `socketRead0` 只读一次就返回（即使没读满），因为 TCP 是流式协议，不保证一次读到所有数据
- `socketWrite0` 必须全部写完才返回，内层循环处理了 `send()` 的短写问题

---

## 9. socketSetOption0 / socketGetOption — Socket 选项

### 9.1 支持的选项

```c
// PlainSocketImpl.c:826
JNIEXPORT void JNICALL
Java_java_net_PlainSocketImpl_socketSetOption0(JNIEnv *env, jobject this,
                                                jint cmd, jboolean on, jobject value) {
    // SO_TIMEOUT 在 Unix 上是 NOOP（超时由 Java 层 poll 实现）
    if (cmd == java_net_SocketOptions_SO_TIMEOUT) {
        return;
    }
    
    // 通过 NET_MapSocketOption 映射到系统级选项
    NET_MapSocketOption(cmd, &level, &optname);
    
    switch (cmd) {
        case SO_SNDBUF:   // → SOL_SOCKET, SO_SNDBUF
        case SO_RCVBUF:   // → SOL_SOCKET, SO_RCVBUF
        case IP_TOS:      // → IPPROTO_IP, IP_TOS
            optval.i = GetIntField(env, value, fid);
            break;
        case SO_LINGER:   // → SOL_SOCKET, SO_LINGER (struct linger)
            if (on) {
                optval.ling.l_onoff = 1;
                optval.ling.l_linger = GetIntField(env, value, fid);
            } else {
                optval.ling.l_onoff = 0;
                optval.ling.l_linger = 0;
            }
            break;
        default:          // TCP_NODELAY, SO_KEEPALIVE, SO_REUSEADDR, SO_OOBINLINE
            optval.i = (on ? 1 : 0);
    }
    
    NET_SetSockOpt(fd, level, optname, &optval, optlen);
}
```

### 9.2 SO_TIMEOUT 为什么是 NOOP？

在 Unix/Linux 上，`SO_TIMEOUT` 不是通过 `setsockopt` 设置到内核的，而是存储在 Java 层的 `timeout` 字段中，由 `NET_ReadWithTimeout` 使用 `poll()` 来实现。这是因为：

1. POSIX 没有 `SO_RCVTIMEO` 的统一语义（不同系统行为不同）
2. JDK 需要精确区分"超时"和"关闭"，`poll` 模式更可控

### 9.3 Java 层选项映射表

```
┌─────────────────────┬───────────────────────┬───────────────────────────┐
│ Java 选项            │ 系统调用参数            │ 说明                      │
├─────────────────────┼───────────────────────┼───────────────────────────┤
│ SO_TIMEOUT          │ (不传到内核)            │ Java 层 poll 实现          │
│ TCP_NODELAY         │ IPPROTO_TCP, TCP_NODELAY│ 禁用 Nagle 算法          │
│ SO_REUSEADDR        │ SOL_SOCKET, SO_REUSEADDR│ 地址重用                 │
│ SO_REUSEPORT        │ SOL_SOCKET, SO_REUSEPORT│ 端口重用 (Linux 3.9+)    │
│ SO_KEEPALIVE        │ SOL_SOCKET, SO_KEEPALIVE│ TCP 保活探测              │
│ SO_SNDBUF           │ SOL_SOCKET, SO_SNDBUF  │ 发送缓冲区大小             │
│ SO_RCVBUF           │ SOL_SOCKET, SO_RCVBUF  │ 接收缓冲区大小             │
│ SO_LINGER           │ SOL_SOCKET, SO_LINGER  │ 关闭时等待未发数据          │
│ SO_OOBINLINE        │ SOL_SOCKET, SO_OOBINLINE│ OOB 数据内联到普通流      │
│ IP_TOS              │ IPPROTO_IP, IP_TOS     │ 服务类型/DSCP             │
│ SO_BINDADDR         │ (通过 getsockname)      │ 只读：获取绑定地址          │
└─────────────────────┴───────────────────────┴───────────────────────────┘
```

---

## 10. socketClose0 — 延迟关闭

### 10.1 Java 层：两阶段关闭

```java
// AbstractPlainSocketImpl.java:565
protected void close() throws IOException {
    synchronized (fdLock) {
        if (fd != null) {
            if (fdUseCount == 0) {
                // 没有线程在使用 fd → 立即关闭
                closePending = true;
                try {
                    socketPreClose();   // Phase 1: dup2(marker_fd, fd)
                } finally {
                    socketClose();      // Phase 2: close(fd)
                }
                fd = null;
            } else {
                // 有线程正在使用 fd → 延迟关闭
                closePending = true;
                fdUseCount--;            // 提前减 1
                socketPreClose();        // Phase 1: 唤醒阻塞线程
                // Phase 2 由最后一个 releaseFD() 执行
            }
        }
    }
}
```

### 10.2 acquireFD / releaseFD 引用计数

```java
FileDescriptor acquireFD() {
    synchronized (fdLock) {
        fdUseCount++;
        return fd;
    }
}

void releaseFD() {
    synchronized (fdLock) {
        fdUseCount--;
        if (fdUseCount == -1) {    // 触发条件：close() 中减了 1，最后一个线程再减 1
            if (fd != null) {
                try { socketClose(); } catch (IOException e) {}
                finally { fd = null; }
            }
        }
    }
}
```

**fdUseCount 的值变化示例**：

```
初始状态: fdUseCount = 0

线程 A: acquireFD()  → fdUseCount = 1   (进入 socketRead0)
线程 B: acquireFD()  → fdUseCount = 2   (进入 socketRead0)
线程 C: close()      → fdUseCount = 1   (减 1，执行 socketPreClose)
                                          ← A、B 的 recv() 被唤醒返回 EBADF
线程 A: releaseFD()  → fdUseCount = 0   (不触发 close)
线程 B: releaseFD()  → fdUseCount = -1  (触发 socketClose, fd = null)
```

### 10.3 Native 层

```c
// PlainSocketImpl.c:768
JNIEXPORT void JNICALL
Java_java_net_PlainSocketImpl_socketClose0(JNIEnv *env, jobject this,
                                          jboolean useDeferredClose) {
    if (fd != -1) {
        if (useDeferredClose && marker_fd >= 0) {
            NET_Dup2(marker_fd, fd);       // Phase 1: dup2，不释放 fd
        } else {
            SetIntField(env, fdObj, IO_fd_fdID, -1);
            NET_SocketClose(fd);           // Phase 2: 真正 close
        }
    }
}
```

`NET_Dup2` 和 `NET_SocketClose` 的实现在 `linux_close.c` 中，这是整个 BIO 关闭机制的核心。

---

## 11. linux_close.c — 异步安全关闭机制（核心）

这是 BIO 模型中最精巧的一段代码，解决了 **"一个线程阻塞在 I/O 上，另一个线程要关闭 fd"** 的经典并发问题。

### 11.1 数据结构

```c
// linux_close.c:46
typedef struct threadEntry {
    pthread_t thr;           // 当前线程
    struct threadEntry *next; // 链表下一个节点
    int intr;                // 是否被中断
} threadEntry_t;

typedef struct {
    pthread_mutex_t lock;    // 每个 fd 一把锁
    threadEntry_t *threads;  // 阻塞在此 fd 上的线程链表
} fdEntry_t;
```

### 11.2 fdTable — 文件描述符表

```c
static fdEntry_t* fdTable = NULL;          // 基础表：覆盖 fd < 4096
static const int fdTableMaxSize = 0x1000;  // 4096
static int fdTableLen = 0;

static fdEntry_t** fdOverflowTable = NULL; // 溢出表：覆盖 fd >= 4096
static const int fdOverflowTableSlabSize = 0x10000; // 每个 slab 64K 条目
```

**为什么需要两级表？**

大多数程序的 fd 值 < 4096，用一个平坦数组 `fdTable[fd]` 即可 O(1) 查找。但高并发服务器可能有数十万个 fd（`ulimit -n` 很大），为避免预分配大量内存，大 fd 值使用按需分配的 slab 数组。

```
┌─────────────────────────────────────────────────────────────────┐
│ fdTable (flat array)                                            │
│ [0] [1] [2] ... [4095]                                         │
│  ↑                                                              │
│  每个元素: { pthread_mutex_t lock; threadEntry_t *threads; }     │
├─────────────────────────────────────────────────────────────────┤
│ fdOverflowTable (sparse 2D array)                               │
│ [0] → slab[0..65535]   (fd 4096~69631)                         │
│ [1] → slab[0..65535]   (fd 69632~135167)                       │
│ [2] → NULL             (按需分配)                                │
│ ...                                                             │
└─────────────────────────────────────────────────────────────────┘
```

### 11.3 init — 库加载时初始化

```c
// linux_close.c:106
static void __attribute((constructor)) init() {
    // 1. 获取 fd 上限
    getrlimit(RLIMIT_NOFILE, &nbr_files);
    fdLimit = nbr_files.rlim_max;  // 硬上限
    
    // 2. 分配基础表
    fdTableLen = min(fdLimit, 4096);
    fdTable = calloc(fdTableLen, sizeof(fdEntry_t));
    for (i = 0; i < fdTableLen; i++)
        pthread_mutex_init(&fdTable[i].lock, NULL);
    
    // 3. 分配溢出表（如果需要）
    if (fdLimit > 4096) {
        fdOverflowTableLen = (fdLimit - 4096) / 65536 + 1;
        fdOverflowTable = calloc(fdOverflowTableLen, sizeof(fdEntry_t*));
    }
    
    // 4. 设置唤醒信号处理器
    sa.sa_handler = sig_wakeup;  // 空处理器
    sa.sa_flags = 0;             // 不设 SA_RESTART → 系统调用被中断后不自动重试
    sigaction(WAKEUP_SIGNAL, &sa, NULL);  // SIGRTMAX - 2
    
    // 5. 确保唤醒信号未被屏蔽
    sigprocmask(SIG_UNBLOCK, &sigset, NULL);
}
```

**`__attribute__((constructor))`** 意味着 `init()` 在 `libnet.so` 被 `dlopen` 加载时自动执行（比 `JNI_OnLoad` 更早）。

**WAKEUP_SIGNAL = SIGRTMAX - 2**：使用实时信号而非标准信号，因为实时信号不会丢失（可以排队），且不与其他库冲突。

**sig_wakeup 是空函数**：信号处理器不需要做任何事，唯一的作用是让阻塞的系统调用返回 `EINTR`。关键是 `sa_flags = 0`（没有 `SA_RESTART`），这保证 `recv/send/poll/accept/connect` 在收到信号后**不会自动重启**。

### 11.4 BLOCKING_IO_RETURN_INT — 核心宏

```c
// linux_close.c:352
#define BLOCKING_IO_RETURN_INT(FD, FUNC) {      \
    int ret;                                    \
    threadEntry_t self;                         \
    fdEntry_t *fdEntry = getFdEntry(FD);        \
    if (fdEntry == NULL) {                      \
        errno = EBADF;                          \
        return -1;                              \
    }                                           \
    do {                                        \
        startOp(fdEntry, &self);                \
        ret = FUNC;                             \
        endOp(fdEntry, &self);                  \
    } while (ret == -1 && errno == EINTR);      \
    return ret;                                 \
}
```

这个宏包装了所有阻塞 I/O 操作，核心逻辑是三步：

```
1. startOp: 注册当前线程到 fd 的线程链表
2. 执行系统调用（可能阻塞）
3. endOp: 从链表移除，检查是否被 close 中断
```

#### startOp

```c
static inline void startOp(fdEntry_t *fdEntry, threadEntry_t *self) {
    self->thr = pthread_self();
    self->intr = 0;
    
    pthread_mutex_lock(&fdEntry->lock);
    self->next = fdEntry->threads;  // 头插法
    fdEntry->threads = self;
    pthread_mutex_unlock(&fdEntry->lock);
}
```

#### endOp

```c
static inline void endOp(fdEntry_t *fdEntry, threadEntry_t *self) {
    int orig_errno = errno;  // 保存原始 errno
    
    pthread_mutex_lock(&fdEntry->lock);
    // 从链表中移除自己
    // 如果 self->intr == 1，说明被 closefd 中断
    if (curr->intr) {
        orig_errno = EBADF;  // 覆盖 errno
    }
    pthread_mutex_unlock(&fdEntry->lock);
    
    errno = orig_errno;
}
```

**关键细节**：如果线程被 `closefd` 中断，`endOp` 将 errno 改为 `EBADF`。此时外层的 `while (ret == -1 && errno == EINTR)` 循环**不会重试**（因为 errno 不是 EINTR 而是 EBADF），从而退出阻塞。

### 11.5 closefd — 关闭 fd 并唤醒所有阻塞线程

```c
// linux_close.c:275
static int closefd(int fd1, int fd2) {
    fdEntry_t *fdEntry = getFdEntry(fd2);
    
    pthread_mutex_lock(&fdEntry->lock);
    {
        // Step 1: 关闭或替换 fd
        if (fd1 < 0) {
            rv = close(fd2);           // 真正关闭
        } else {
            do {
                rv = dup2(fd1, fd2);   // 用 marker_fd 替换
            } while (rv == -1 && errno == EINTR);
        }
        
        // Step 2: 唤醒所有阻塞在此 fd 上的线程
        threadEntry_t *curr = fdEntry->threads;
        while (curr != NULL) {
            curr->intr = 1;                          // 标记中断
            pthread_kill(curr->thr, WAKEUP_SIGNAL);  // 发送信号
            curr = curr->next;
        }
    }
    pthread_mutex_unlock(&fdEntry->lock);
    return rv;
}
```

### 11.6 完整时序图

```
线程 A (读取)                    线程 B (关闭)
    │                                │
    │  startOp(fdEntry, &self)       │
    │  ← 注册到 threads 链表         │
    │                                │
    │  recv(fd, buf, len, 0)         │
    │  ↓ 阻塞...                     │
    │                                │
    │                                │  socketClose0(true)
    │                                │  ← useDeferredClose=true
    │                                │
    │                                │  NET_Dup2(marker_fd, fd)
    │                                │  → closefd(marker_fd, fd)
    │                                │     lock(fdEntry)
    │                                │     dup2(marker_fd, fd)
    │                                │     ← fd 现在指向已 shutdown 的 socketpair
    │                                │     self.intr = 1
    │                                │     pthread_kill(A, SIGRTMAX-2)
    │                                │     unlock(fdEntry)
    │                                │
    │  ← recv 被信号中断              │
    │  返回 -1, errno = EINTR        │
    │                                │
    │  endOp(fdEntry, &self)         │
    │  ← self.intr == 1             │
    │  ← errno 改为 EBADF            │
    │                                │
    │  while 循环：errno != EINTR     │
    │  ← 不重试，返回 -1             │
    │                                │
    │  Java 层：                      │
    │  ConnectionResetException 或    │
    │  SocketException("Socket closed")│
    │                                │
    │  releaseFD()                    │
    │  ← fdUseCount 变 -1 时         │
    │     socketClose0(false)         │
    │     → NET_SocketClose(fd)       │
    │     → closefd(-1, fd)           │
    │     → close(fd)  ← 真正释放     │
    │                                │
```

### 11.7 包装的系统调用

`linux_close.c` 为所有网络 I/O 系统调用提供了包装版本：

```c
int NET_Read(int s, void* buf, size_t len) {
    BLOCKING_IO_RETURN_INT(s, recv(s, buf, len, 0));
}
int NET_NonBlockingRead(int s, void* buf, size_t len) {
    BLOCKING_IO_RETURN_INT(s, recv(s, buf, len, MSG_DONTWAIT));
}
int NET_RecvFrom(int s, void *buf, int len, unsigned int flags,
                 struct sockaddr *from, socklen_t *fromlen) {
    BLOCKING_IO_RETURN_INT(s, recvfrom(s, buf, len, flags, from, fromlen));
}
int NET_Send(int s, void *msg, int len, unsigned int flags) {
    BLOCKING_IO_RETURN_INT(s, send(s, msg, len, flags));
}
int NET_SendTo(int s, const void *msg, int len, unsigned int flags,
               const struct sockaddr *to, int tolen) {
    BLOCKING_IO_RETURN_INT(s, sendto(s, msg, len, flags, to, tolen));
}
int NET_Accept(int s, struct sockaddr *addr, socklen_t *addrlen) {
    BLOCKING_IO_RETURN_INT(s, accept(s, addr, addrlen));
}
int NET_Connect(int s, struct sockaddr *addr, int addrlen) {
    BLOCKING_IO_RETURN_INT(s, connect(s, addr, addrlen));
}
int NET_Poll(struct pollfd *ufds, unsigned int nfds, int timeout) {
    BLOCKING_IO_RETURN_INT(ufds[0].fd, poll(ufds, nfds, timeout));
}
```

每个包装函数都：
1. 注册当前线程到 fd 的线程链表
2. 执行原始系统调用
3. EINTR 自动重试（除非是 close 唤醒导致的 EINTR）
4. 从链表注销

### 11.8 NET_Timeout — 带唤醒支持的 poll

```c
// linux_close.c:407
int NET_Timeout(JNIEnv *env, int s, long timeout, jlong nanoTimeStamp) {
    jlong nanoTimeout = (jlong)timeout * NET_NSEC_PER_MSEC;
    fdEntry_t *fdEntry = getFdEntry(s);
    
    for (;;) {
        struct pollfd pfd = { .fd = s, .events = POLLIN | POLLERR };
        threadEntry_t self;
        
        startOp(fdEntry, &self);
        rv = poll(&pfd, 1, nanoTimeout / NET_NSEC_PER_MSEC);
        endOp(fdEntry, &self);
        
        if (rv < 0 && errno == EINTR) {
            // 被中断（可能是 close 唤醒或其他信号）
            // 如果 endOp 把 errno 改成了 EBADF，这里不会进来
            nanoTimeout -= (newNanoTime - prevNanoTime);
            if (nanoTimeout < NET_NSEC_PER_MSEC) return 0;  // 超时
            prevNanoTime = newNanoTime;
        } else {
            return rv;
        }
    }
}
```

---

## 12. socketAvailable — 查询可读字节数

```c
// PlainSocketImpl.c:737
JNIEXPORT jint JNICALL
Java_java_net_PlainSocketImpl_socketAvailable(JNIEnv *env, jobject this) {
    jint ret = -1;
    // NET_SocketAvailable → ioctl(fd, FIONREAD, &ret)
    if (NET_SocketAvailable(fd, &ret) == 0) {
        if (errno == ECONNRESET)
            throw ConnectionResetException("");
        else
            throw SocketException("ioctl FIONREAD failed");
    }
    return ret;
}
```

底层使用 `ioctl(FIONREAD)` 查询接收缓冲区中有多少字节可读。当 `ECONNRESET` 时抛出 `ConnectionResetException`。

---

## 13. socketShutdown / socketSendUrgentData

### 13.1 shutdown

```c
// PlainSocketImpl.c:797
JNIEXPORT void JNICALL
Java_java_net_PlainSocketImpl_socketShutdown(JNIEnv *env, jobject this,
                                             jint howto) {
    shutdown(fd, howto);  // howto: 0=SHUT_RD, 1=SHUT_WR, 2=SHUT_RDWR
}
```

直接调用 POSIX `shutdown()`。Java 层在 `shutdownInput()` 中还会设置 `shut_rd = true` 和 `socketInputStream.setEOF(true)` 来避免后续无效的 read 调用。

### 13.2 sendUrgentData

```c
// PlainSocketImpl.c:1012
JNIEXPORT void JNICALL
Java_java_net_PlainSocketImpl_socketSendUrgentData(JNIEnv *env, jobject this,
                                                    jint data) {
    unsigned char d = data & 0xFF;
    n = NET_Send(fd, (char *)&d, 1, MSG_OOB);  // 发送带外数据
}
```

TCP 紧急数据（URG）只发送 1 字节，通过 `MSG_OOB` 标志。接收端需要设置 `SO_OOBINLINE` 才能在普通流中读到 OOB 数据，否则需要用 `recv(MSG_OOB)` 读取。

---

## 14. BIO vs NIO：关闭机制对比

BIO 和 NIO 都面临同一个问题——安全关闭正在被其他线程使用的 fd——但采用了不同的解决方案：

```
┌────────────────────┬──────────────────────────────┬──────────────────────────────┐
│                    │ BIO (Socket)                 │ NIO (SocketChannel)          │
├────────────────────┼──────────────────────────────┼──────────────────────────────┤
│ 关闭协调           │ fdLock + fdUseCount           │ stateLock + state 状态机       │
│                    │ + closePending                │ + readerThread/writerThread  │
├────────────────────┼──────────────────────────────┼──────────────────────────────┤
│ preClose 实现      │ dup2(marker_fd, fd)           │ dup2(preCloseFD, fd)         │
│                    │ marker: shutdown的socketpair  │ preClose: 关闭write端的pair   │
├────────────────────┼──────────────────────────────┼──────────────────────────────┤
│ 唤醒阻塞线程       │ pthread_kill(SIGRTMAX-2)     │ pthread_kill(SIGINT-like)    │
│                    │ + 线程链表遍历                 │ + NativeThread.signal()      │
├────────────────────┼──────────────────────────────┼──────────────────────────────┤
│ 线程注册方式       │ fdEntry_t.threads 链表        │ readerThread/writerThread    │
│                    │ (per-fd, 多线程)              │ (per-channel, 单线程)         │
├────────────────────┼──────────────────────────────┼──────────────────────────────┤
│ 真正 close 时机    │ fdUseCount == -1             │ state == ST_KILLPENDING 且   │
│                    │                              │ 无阻塞线程时                   │
├────────────────────┼──────────────────────────────┼──────────────────────────────┤
│ 关键文件           │ linux_close.c (451行)         │ NativeThread.c + nd_close()  │
├────────────────────┼──────────────────────────────┼──────────────────────────────┤
│ 中断信号           │ SIGRTMAX - 2                 │ 平台相关 (__SIGRTMAX)        │
├────────────────────┼──────────────────────────────┼──────────────────────────────┤
│ fd 全局表          │ 有 (fdTable, 按 fd 索引)      │ 无 (每个 Channel 独立管理)    │
└────────────────────┴──────────────────────────────┴──────────────────────────────┘
```

**为什么 BIO 需要 fdTable 而 NIO 不需要？**

BIO 的 `NET_Read/NET_Send` 等函数只接收 `int fd` 参数，没有 Channel 对象引用，因此需要一个全局的 `fdTable[fd]` 来查找该 fd 上阻塞的线程。NIO 的 `SocketChannelImpl` 对象本身就持有 `readerThread/writerThread` 字段，不需要全局查找。

---

## 15. 面试高频问题

### Q1: BIO 的 Socket.setSoTimeout() 是怎么实现的？

答：并**不是**通过 `setsockopt(SO_RCVTIMEO)` 实现的。Java 层将 timeout 存储在 `AbstractPlainSocketImpl.timeout` 字段中，当调用 `socketRead0` 时，如果 timeout > 0，则先用 `poll(fd, POLLIN, timeout)` 等待数据到达，超时则抛 `SocketTimeoutException`；如果 poll 返回可读，再调用 `recv(fd, buf, len, MSG_DONTWAIT)` 非阻塞读取。

### Q2: 一个线程阻塞在 Socket.read()，另一个线程调用 Socket.close()，会发生什么？

答：
1. `close()` 发现 `fdUseCount > 0`（有线程在用），执行 `socketClose0(true)` → `NET_Dup2(marker_fd, fd)`
2. `dup2` 将 fd 指向一个已 shutdown 的 socketpair，并对阻塞线程发送 `SIGRTMAX-2` 信号
3. 阻塞在 `recv()` 的线程被信号中断，`BLOCKING_IO_RETURN_INT` 中的 `endOp` 将 errno 改为 EBADF
4. `socketRead0` 返回 -1，Java 层检测到 `closePending=true`，抛出 `SocketException("Socket closed")`
5. `releaseFD()` 使 `fdUseCount` 降为 -1，触发 `socketClose0(false)` → 真正 `close(fd)`

### Q3: 为什么不能直接 close(fd) 而要用 dup2 + signal？

答：如果直接 `close(fd)` 释放了 fd 编号，内核可能立刻将这个编号分配给新创建的 socket。此时阻塞在旧 `recv(fd)` 上的线程会开始从一个**完全不相关的新 socket** 上读取数据，导致数据串流。`dup2(marker_fd, fd)` 保持 fd 编号不被释放（指向 marker），同时让阻塞的 I/O 返回错误。

### Q4: BIO 的 connect 超时是怎么实现的？

答：临时将 socket 切换为非阻塞模式，`connect()` 立即返回 `EINPROGRESS`，然后用 `poll(POLLOUT, timeout)` 等待连接完成。poll 返回后用 `getsockopt(SO_ERROR)` 检查连接是否成功。最后恢复阻塞模式。如果超时，还需要 `shutdown(fd, 2)` 清理半建立的连接。

### Q5: ServerSocket 的 fd 为什么要设为非阻塞？

答：因为 `accept()` 的超时实现依赖 `poll() + accept()` 两步操作。如果 ServerSocket 的 fd 是阻塞的，`poll` 返回可读后但 `accept` 调用前连接被 RST（ECONNABORTED），阻塞模式的 `accept` 会一直等待下一个连接，而不是返回错误让 Java 层重新检查超时。非阻塞模式下 `accept` 会返回 EWOULDBLOCK/EAGAIN，允许 Java 层正确调整超时。

---

## 16. 源码文件交叉引用

| 文件 | 路径 | 行数 | 角色 |
|------|------|------|------|
| `PlainSocketImpl.c` | `unix/native/libnet/` | 1039 | 核心 JNI：socketCreate→socket / socketConnect→connect+poll / socketBind / socketListen / socketAccept→poll+accept / socketClose0→dup2 / socketSetOption0 / socketGetOption / socketSendUrgentData→MSG_OOB |
| `SocketInputStream.c` | `unix/native/libnet/` | 171 | 读 JNI：socketRead0→NET_Read/NET_ReadWithTimeout→recv；栈/堆双缓冲区策略(64KB/128KB) |
| `SocketOutputStream.c` | `unix/native/libnet/` | 127 | 写 JNI：socketWrite0→NET_Send→send；双层循环(分块拷贝+完整发送) |
| `linux_close.c` | `linux/native/libnet/` | 451 | 异步安全关闭核心：fdTable/fdEntry_t/threadEntry_t；BLOCKING_IO_RETURN_INT 宏；startOp/endOp 线程注册；closefd→dup2+pthread_kill(SIGRTMAX-2)；NET_Read/NET_Send/NET_Accept/NET_Connect/NET_Poll/NET_Timeout 全部包装 |
| `AbstractPlainSocketImpl.java` | `share/classes/java/net/` | 759 | 抽象基类：fdLock+fdUseCount+closePending 延迟关闭协议；acquireFD/releaseFD 引用计数；两阶段 close(socketPreClose+socketClose)；setOption/getOption 参数校验 |
| `PlainSocketImpl.java` | `unix/classes/java/net/` | 153 | Unix 实现：所有 native 方法声明；static { initProto(); }；ExtendedSocketOptions 支持 |
| `SocketInputStream.java` | `share/classes/java/net/` | 270 | 输入流：acquireFD/releaseFD 包装；ConnectionResetException 两阶段处理；EOF 标记 |
| `SocketOutputStream.java` | `share/classes/java/net/` | 182 | 输出流：acquireFD/releaseFD 包装；closePending→"Socket closed" 错误消息替换 |
| `net_util_md.h` | `unix/native/libnet/` | — | 常量定义：MAX_BUFFER_LEN(64KB) / MAX_HEAP_BUFFER_LEN(128KB) / NET_NSEC_PER_MSEC(1000000) |
| `net_util_md.c` | `unix/native/libnet/` | — | 工具函数：NET_MapSocketOption / NET_SetSockOpt / NET_GetSockOpt / NET_Bind / NET_SocketAvailable(ioctl FIONREAD) |
