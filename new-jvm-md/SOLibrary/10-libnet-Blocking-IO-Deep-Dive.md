# libnet.so — 传统阻塞 I/O 完整深度剖析

> **文件位置**：
> - `src/java.base/unix/native/libnet/SocketInputStream.c` (Socket 读取)
> - `src/java.base/unix/native/libnet/SocketOutputStream.c` (Socket 写入)
> - `src/java.base/unix/native/libnet/PlainSocketImpl.c` (Socket 实现)
> - `src/java.base/unix/native/libnet/net_util_md.c` (网络工具函数)
> 
> **方法论**：程序 = 数据结构 + 算法
> **遵循规范**：Source-Code-Depth L5（真实源码 + 逐行注释 + 设计解释 + 对比表）
> **标准环境**：-Xms8g -Xmx8g -XX:+UseG1GC

---

## 第 0 部分：核心原理

### 0.1 本质是什么？

**一句话概括**：libnet.so 是 Java 传统阻塞 I/O 的 native 层实现，核心是 **socket() + bind() + listen() + accept() + connect() + read()/recv() + write()/send()** 的阻塞式系统调用封装。

### 0.2 为什么需要 libnet？

| 问题 | 场景 | libnet 方案 | 局限 |
|------|------|------------|------|
| 客户端连接服务器 | 简单客户端 | `socket() + connect()` | 阻塞等待 |
| 服务端接受连接 | 传统服务端 | `socket() + bind() + listen() + accept()` | 每连接一线程 |
| 读写数据 | 简单通信 | `read()/write()` | 阻塞等待 |
| 超时控制 | 简单超时 | `poll() + 非阻塞` | 每次操作需切换 |

### 0.3 与 libnio 的核心区别

| 维度 | libnet (传统 I/O) | libnio (NIO) |
|------|------------------|--------------|
| I/O 模型 | 阻塞 | 非阻塞 |
| 多路复用 | 无 | poll/epoll |
| 零拷贝 | 无 | mmap + sendfile |
| 线程模型 | 一连接一线程 | 单线程多连接 |
| 缓冲区 | 堆内存 byte[] | DirectByteBuffer |
| 适用场景 | 连接数少 | 高并发 |

### 0.4 为什么这样设计？

**为什么用阻塞 I/O？**
- 简单直观，编程模型清晰
- JDK 1.0 时代就存在，兼容性好
- 连接数少时性能足够

**为什么不淘汰？**
- 简单场景用 libnet 更直观
- NIO 编程复杂度高
- 两者可共存，各司其职

---

## 一、数据结构全景 ⭐⭐⭐

### 1.1 SOCKETADDRESS — 通用地址结构（复用）

**源码位置**：`src/java.base/unix/native/libnet/net_util.h`

```c
// net_util.h
typedef union {
    struct sockaddr     sa;      /* 通用地址 */
    struct sockaddr_in  sa4;     /* IPv4 地址 */
    struct sockaddr_in6 sa6;     /* IPv6 地址 */
} SOCKETADDRESS;
```

**sizeof 分析**：

```
sizeof(SOCKETADDRESS) = 28 bytes (IPv4) / 128 bytes (IPv6)

IPv4 (sockaddr_in):
┌────────────────────────────────────────────┐ 偏移 0
│ sin_family : sa_family_t (2 bytes)         │ AF_INET
├────────────────────────────────────────────┤ 偏移 2
│ sin_port   : in_port_t  (2 bytes)          │ 端口号（网络序）
├────────────────────────────────────────────┤ 偏移 4
│ sin_addr   : struct in_addr (4 bytes)      │ IPv4 地址
├────────────────────────────────────────────┤ 偏移 8
│ sin_zero   : char[8]                        │ 填充
└────────────────────────────────────────────┘ 偏移 16

IPv6 (sockaddr_in6):
┌────────────────────────────────────────────┐ 偏移 0
│ sin6_family   : sa_family_t (2 bytes)      │ AF_INET6
├────────────────────────────────────────────┤ 偏移 2
│ sin6_port     : in_port_t  (2 bytes)       │ 端口号（网络序）
├────────────────────────────────────────────┤ 偏移 4
│ sin6_flowinfo : uint32_t   (4 bytes)       │ 流标签
├────────────────────────────────────────────┤ 偏移 8
│ sin6_addr     : struct in6_addr (16 bytes) │ IPv6 地址
├────────────────────────────────────────────┤ 偏移 24
│ sin6_scope_id : uint32_t   (4 bytes)       │ 作用域 ID
└────────────────────────────────────────────┘ 偏移 28
```

---

### 1.2 PlainSocketImpl 字段 ID 缓存

**源码位置**：`PlainSocketImpl.c:37-48`

```c
// PlainSocketImpl.c
static jfieldID IO_fd_fdID;

jfieldID psi_fdID;
jfieldID psi_addressID;
jfieldID psi_ipaddressID;
jfieldID psi_portID;
jfieldID psi_localportID;
jfieldID psi_timeoutID;
jfieldID psi_trafficClassID;
jfieldID psi_serverSocketID;
jfieldID psi_fdLockID;
jfieldID psi_closePendingID;
```

**用途**：缓存 Java 对象的字段 ID，避免每次调用 JNI GetFieldID。

| 字段 ID | Java 字段 | 类型 | 用途 |
|---------|-----------|------|------|
| `psi_fdID` | `fd` | FileDescriptor | Socket 文件描述符 |
| `psi_addressID` | `address` | InetAddress | 远程地址 |
| `psi_portID` | `port` | int | 远程端口 |
| `psi_localportID` | `localport` | int | 本地端口 |
| `psi_timeoutID` | `timeout` | int | 超时时间（毫秒） |
| `psi_serverSocketID` | `serverSocket` | ServerSocket | 服务端 Socket 标识 |

---

## 二、核心函数 1：socketCreate() — 创建 Socket ⭐⭐⭐⭐

### 2.1 解决什么问题？

**如何创建一个 TCP/UDP Socket？**

### 2.2 完整源码 + 逐行注释

```c
// PlainSocketImpl.c:158-216
JNIEXPORT void JNICALL
Java_java_net_PlainSocketImpl_socketCreate(JNIEnv *env, jobject this,
                                           jboolean stream)
{
    jobject fdObj, ssObj;
    int fd;
    // ★ 根据 stream 参数选择 Socket 类型
    // stream = JNI_TRUE  → SOCK_STREAM (TCP)
    // stream = JNI_FALSE → SOCK_DGRAM  (UDP)
    int type = (stream ? SOCK_STREAM : SOCK_DGRAM);
    
    // ★ 选择地址族：优先 IPv6（双栈模式）
    // ipv6_available() 检测系统是否支持 IPv6
    int domain = ipv6_available() ? AF_INET6 : AF_INET;

    // ★ 预加载 SocketException 类（防止 fd 耗尽时无法加载异常类）
    if (socketExceptionCls == NULL) {
        jclass c = (*env)->FindClass(env, "java/net/SocketException");
        CHECK_NULL(c);
        socketExceptionCls = (jclass)(*env)->NewGlobalRef(env, c);
        CHECK_NULL(socketExceptionCls);
    }
    
    fdObj = (*env)->GetObjectField(env, this, psi_fdID);

    if (fdObj == NULL) {
        (*env)->ThrowNew(env, socketExceptionCls, "null fd object");
        return;
    }

    // ★★★ 核心：调用 socket 系统调用 ★★★
    // socket(domain, type, protocol)
    // - domain: AF_INET (IPv4) 或 AF_INET6 (IPv6)
    // - type: SOCK_STREAM (TCP) 或 SOCK_DGRAM (UDP)
    // - protocol: 0（自动选择）
    // 返回：文件描述符（>= 0）或 -1（失败）
    if ((fd = socket(domain, type, 0)) == -1) {
        // ★ 如果 fd 耗尽，可能连异常类都加载不了
        NET_ThrowNew(env, errno, "can't create socket");
        return;
    }

    // ★ 禁用 IPV6_V6ONLY，启用双栈模式
    // 双栈模式：IPv6 Socket 可以同时处理 IPv4 和 IPv6 连接
    if (domain == AF_INET6) {
        int arg = 0;
        if (setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, (char*)&arg,
                       sizeof(int)) < 0) {
            NET_ThrowNew(env, errno, "cannot set IPPROTO_IPV6");
            close(fd);
            return;
        }
    }

    /*
     * ★ 如果是 ServerSocket，自动设置：
     * 1. SO_REUSEADDR：允许重用 TIME_WAIT 状态的端口
     * 2. O_NONBLOCK：非阻塞模式（用于 accept 超时）
     */
    ssObj = (*env)->GetObjectField(env, this, psi_serverSocketID);
    if (ssObj != NULL) {
        int arg = 1;
        // ★ 设置非阻塞（用于 NET_Timeout 实现 accept 超时）
        SET_NONBLOCKING(fd);
        
        // ★ 设置 SO_REUSEADDR
        if (NET_SetSockOpt(fd, SOL_SOCKET, SO_REUSEADDR, (char*)&arg,
                       sizeof(arg)) < 0) {
            NET_ThrowNew(env, errno, "cannot set SO_REUSEADDR");
            close(fd);
            return;
        }
    }

    // ★ 将 fd 设置到 Java 的 FileDescriptor 对象
    (*env)->SetIntField(env, fdObj, IO_fd_fdID, fd);
}
```

### 2.3 设计决策解释

**为什么要预加载 SocketException 类？**

```
场景：系统 fd 耗尽

不预加载的后果：
  1. socket() 返回 -1
  2. 调用 FindClass("java/net/SocketException")
  3. FindClass 需要打开 jar 文件
  4. 打开文件需要 fd
  5. fd 已耗尽 → NoClassDefFoundError
  6. 用户看到的是 NoClassDefFoundError 而不是 SocketException

预加载的效果：
  1. 类加载时预先加载 SocketException 类
  2. 保存全局引用
  3. fd 耗尽时直接使用缓存的类
  4. 用户看到正确的 SocketException
```

**为什么 ServerSocket 要设置 O_NONBLOCK？**

```
ServerSocket.accept() 需要支持超时：

实现方式：
  1. ServerSocket 创建时设置 O_NONBLOCK
  2. accept() 调用前先用 poll() 等待连接
  3. poll() 可以设置超时
  4. 超时后抛出 SocketTimeoutException
  5. 有连接时再调用 accept()（立即返回）

如果不设置非阻塞：
  accept() 会一直阻塞，无法实现超时
```

**为什么设置 SO_REUSEADDR？**

```
问题：TCP 连接关闭后进入 TIME_WAIT 状态（持续 2MSL）

不设置 SO_REUSEADDR：
  - 立即重启服务器会失败
  - "Address already in use" 错误
  - 需要等待 TIME_WAIT 消失

设置 SO_REUSEADDR：
  - 允许重用 TIME_WAIT 状态的端口
  - 立即重启服务器成功
  - 生产环境必备
```

---

## 三、核心函数 2：socketConnect() — 连接服务器 ⭐⭐⭐⭐⭐

### 3.1 解决什么问题？

**如何连接远程服务器？如何实现连接超时？**

### 3.2 完整源码 + 逐行注释

```c
// PlainSocketImpl.c:226-477
JNIEXPORT void JNICALL
Java_java_net_PlainSocketImpl_socketConnect(JNIEnv *env, jobject this,
                                            jobject iaObj, jint port,
                                            jint timeout)
{
    jint localport = (*env)->GetIntField(env, this, psi_localportID);
    int len = 0;
    jobject fdObj = (*env)->GetObjectField(env, this, psi_fdID);
    jclass clazz = (*env)->GetObjectClass(env, this);
    jobject fdLock;
    jint trafficClass = (*env)->GetIntField(env, this, psi_trafficClassID);
    jint fd;
    SOCKETADDRESS sa;
    int connect_rv = -1;

    if (IS_NULL(fdObj)) {
        JNU_ThrowByName(env, JNU_JAVANETPKG "SocketException", "Socket closed");
        return;
    } else {
        fd = (*env)->GetIntField(env, fdObj, IO_fd_fdID);
    }
    if (IS_NULL(iaObj)) {
        JNU_ThrowNullPointerException(env, "inet address argument null.");
        return;
    }

    // ★ 1. 将 Java InetAddress 转换为 C 的 sockaddr
    if (NET_InetAddressToSockaddr(env, iaObj, port, &sa, &len,
                                  JNI_TRUE) != 0) {
        return;
    }

    // ★ 2. 设置 IPv6 流标签（QoS）
    if (trafficClass != 0 && ipv6_available()) {
        NET_SetTrafficClass(&sa, trafficClass);
    }

    // ★★★ 分支 1：无超时（阻塞连接）★★★
    if (timeout <= 0) {
        // ★ 直接调用 connect（阻塞直到连接成功或失败）
        connect_rv = NET_Connect(fd, &sa.sa, len);
        
        // ★ Solaris 特殊处理：阻塞连接被信号中断
        #ifdef __solaris__
        if (connect_rv == -1 && errno == EINPROGRESS) {
            // ★ 被信号中断后用 poll 等待连接完成
            while (1) {
                struct pollfd pfd;
                pfd.fd = fd;
                pfd.events = POLLOUT;  // ★ 等待可写

                connect_rv = NET_Poll(&pfd, 1, -1);

                if (connect_rv == -1) {
                    if (errno == EINTR) {
                        continue;  // ★ 被信号中断，继续等待
                    } else {
                        break;
                    }
                }
                if (connect_rv > 0) {
                    socklen_t optlen;
                    // ★ 检查连接是否成功
                    optlen = sizeof(connect_rv);
                    if (getsockopt(fd, SOL_SOCKET, SO_ERROR,
                                   (void*)&connect_rv, &optlen) < 0) {
                        connect_rv = errno;
                    }

                    if (connect_rv != 0) {
                        errno = connect_rv;
                        connect_rv = -1;
                    }
                    break;
                }
            }
        }
        #endif
        
    // ★★★ 分支 2：有超时（非阻塞连接）★★★
    } else {
        // ★ 1. 设置非阻塞模式
        SET_NONBLOCKING(fd);

        // ★ 2. 发起连接（非阻塞，立即返回）
        connect_rv = connect(fd, &sa.sa, len);

        // ★ 3. 如果连接未立即建立
        if (connect_rv != 0) {
            socklen_t optlen;
            jlong nanoTimeout = (jlong) timeout * NET_NSEC_PER_MSEC;
            jlong prevNanoTime = JVM_NanoTime(env, 0);

            // ★ EINPROGRESS 表示连接正在进行（正常情况）
            if (errno != EINPROGRESS) {
                NET_ThrowByNameWithLastError(env, JNU_JAVANETPKG "ConnectException",
                             "connect failed");
                SET_BLOCKING(fd);  // ★ 恢复阻塞模式
                return;
            }

            // ★★★ 核心：用 poll 等待连接建立或超时 ★★★
            while (1) {
                jlong newNanoTime;
                struct pollfd pfd;
                pfd.fd = fd;
                pfd.events = POLLOUT;  // ★ 等待可写（连接建立）

                errno = 0;
                connect_rv = NET_Poll(&pfd, 1, nanoTimeout / NET_NSEC_PER_MSEC);

                if (connect_rv >= 0) {
                    break;  // ★ 有结果（成功或失败）
                }
                if (errno != EINTR) {
                    break;  // ★ 非 EINTR 错误
                }

                // ★ 被 EINTR 中断，调整剩余超时时间
                newNanoTime = JVM_NanoTime(env, 0);
                nanoTimeout -= (newNanoTime - prevNanoTime);
                if (nanoTimeout < NET_NSEC_PER_MSEC) {
                    connect_rv = 0;  // ★ 超时
                    break;
                }
                prevNanoTime = newNanoTime;
            }

            // ★ 处理超时
            if (connect_rv == 0) {
                JNU_ThrowByName(env, JNU_JAVANETPKG "SocketTimeoutException",
                            "connect timed out");

                // ★ 关键：超时但连接可能仍在进行
                // 必须关闭 socket，否则连接可能后来成功
                SET_BLOCKING(fd);
                shutdown(fd, 2);
                return;
            }

            // ★ 检查连接是否成功
            optlen = sizeof(connect_rv);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, (void*)&connect_rv,
                           &optlen) < 0) {
                connect_rv = errno;
            }
        }

        // ★ 4. 恢复阻塞模式
        SET_BLOCKING(fd);

        // ★ 5. 恢复 errno
        if (connect_rv != 0) {
            errno = connect_rv;
            connect_rv = -1;
        }
    }

    // ★ 错误处理
    if (connect_rv < 0) {
        // ★ 根据不同 errno 抛出不同异常
        if (errno == ECONNREFUSED) {
            NET_ThrowByNameWithLastError(env, JNU_JAVANETPKG "ConnectException",
                           "Connection refused");
        } else if (errno == ETIMEDOUT) {
            NET_ThrowByNameWithLastError(env, JNU_JAVANETPKG "ConnectException",
                           "Connection timed out");
        } else if (errno == EHOSTUNREACH) {
            NET_ThrowByNameWithLastError(env, JNU_JAVANETPKG "NoRouteToHostException",
                           "Host unreachable");
        } else if (errno == EADDRNOTAVAIL) {
            NET_ThrowByNameWithLastError(env, JNU_JAVANETPKG "NoRouteToHostException",
                             "Address not available");
        } else if ((errno == EISCONN) || (errno == EBADF)) {
            JNU_ThrowByName(env, JNU_JAVANETPKG "SocketException",
                            "Socket closed");
        } else {
            JNU_ThrowByNameWithMessageAndLastError
                (env, JNU_JAVANETPKG "SocketException", "connect failed");
        }
        return;
    }

    // ★ 成功：更新 Java 对象字段
    (*env)->SetIntField(env, fdObj, IO_fd_fdID, fd);
    (*env)->SetObjectField(env, this, psi_addressID, iaObj);
    (*env)->SetIntField(env, this, psi_portID, port);

    // ★ 获取本地端口
    if (localport == 0) {
        socklen_t slen = sizeof(SOCKETADDRESS);
        if (getsockname(fd, &sa.sa, &slen) == -1) {
            JNU_ThrowByNameWithMessageAndLastError
                (env, JNU_JAVANETPKG "SocketException", "Error getting socket name");
        } else {
            localport = NET_GetPortFromSockaddr(&sa);
            (*env)->SetIntField(env, this, psi_localportID, localport);
        }
    }
}
```

### 3.3 设计决策解释

**为什么要切换非阻塞模式实现超时？**

```
阻塞 connect 的问题：
  connect(fd, addr, len) 会一直阻塞直到连接成功或失败
  无法实现超时控制

解决方案：
  1. 设置 O_NONBLOCK
  2. connect() 立即返回（errno = EINPROGRESS）
  3. 用 poll() 等待可写事件
  4. poll() 可以设置超时
  5. 超时后抛出 SocketTimeoutException

为什么超时后要 shutdown？
  如果只恢复阻塞模式，连接可能后来成功
  但 Java 层认为超时了，socket 应该关闭
  shutdown 确保连接被中断
```

**为什么用 getsockopt(SO_ERROR) 检查连接结果？**

```
poll 返回 POLLOUT 不代表连接成功：

情况 1：连接成功
  poll 返回 POLLOUT
  getsockopt(SO_ERROR) 返回 0

情况 2：连接失败
  poll 返回 POLLOUT
  getsockopt(SO_ERROR) 返回错误码（如 ECONNREFUSED）

必须用 getsockopt 检查真实结果
```

---

## 四、核心函数 3：socketAccept() — 接受连接 ⭐⭐⭐⭐⭐

### 4.1 解决什么问题？

**如何接受客户端连接？如何实现 accept 超时？**

### 4.2 完整源码 + 逐行注释

```c
// PlainSocketImpl.c:586-729
JNIEXPORT void JNICALL
Java_java_net_PlainSocketImpl_socketAccept(JNIEnv *env, jobject this,
                                           jobject socket)
{
    int port;
    jint timeout = (*env)->GetIntField(env, this, psi_timeoutID);
    jlong prevNanoTime = 0;
    jlong nanoTimeout = (jlong) timeout * NET_NSEC_PER_MSEC;
    jobject fdObj = (*env)->GetObjectField(env, this, psi_fdID);
    jobject socketFdObj;
    jobject socketAddressObj;
    jint fd;
    jint newfd;
    SOCKETADDRESS sa;
    socklen_t slen = sizeof(SOCKETADDRESS);

    if (IS_NULL(fdObj)) {
        JNU_ThrowByName(env, JNU_JAVANETPKG "SocketException",
                        "Socket closed");
        return;
    } else {
        fd = (*env)->GetIntField(env, fdObj, IO_fd_fdID);
    }
    if (IS_NULL(socket)) {
        JNU_ThrowNullPointerException(env, "socket is null");
        return;
    }

    // ★★★ 核心：循环 accept 直到成功或超时 ★★★
    for (;;) {
        int ret;
        jlong currNanoTime;

        // ★ 记录开始时间（用于计算剩余超时）
        if (prevNanoTime == 0 && nanoTimeout > 0) {
            prevNanoTime = JVM_NanoTime(env, 0);
        }

        // ★★★ 分支 1：无限等待 ★★★
        if (timeout <= 0) {
            ret = NET_Timeout(env, fd, -1, 0);  // -1 表示无限等待
        } else {
            // ★★★ 分支 2：有超时 ★★★
            ret = NET_Timeout(env, fd, nanoTimeout / NET_NSEC_PER_MSEC, prevNanoTime);
        }
        
        // ★ 超时
        if (ret == 0) {
            JNU_ThrowByName(env, JNU_JAVANETPKG "SocketTimeoutException",
                            "Accept timed out");
            return;
        } else if (ret == -1) {
            // ★ 错误
            if (errno == EBADF) {
               JNU_ThrowByName(env, JNU_JAVANETPKG "SocketException", "Socket closed");
            } else if (errno == ENOMEM) {
               JNU_ThrowOutOfMemoryError(env, "NET_Timeout native heap allocation failed");
            } else {
               JNU_ThrowByNameWithMessageAndLastError
                   (env, JNU_JAVANETPKG "SocketException", "Accept failed");
            }
            return;
        }

        // ★★★ 核心：调用 accept 系统调用 ★★★
        // accept(fd, addr, addrlen)
        // - fd: ServerSocket 的 fd
        // - addr: 输出，客户端地址
        // - addrlen: 输入输出，地址结构长度
        // 返回：新 socket 的 fd（>= 0）或 -1（失败）
        newfd = NET_Accept(fd, &sa.sa, &slen);

        // ★ 成功接受连接
        if (newfd >= 0) {
            SET_BLOCKING(newfd);  // ★ 新 socket 设置为阻塞模式
            break;
        }

        // ★ 非 ECONNABORTED/EWOULDBLOCK/EAGAIN 错误
        if (!(errno == ECONNABORTED || errno == EWOULDBLOCK || errno == EAGAIN)) {
            break;
        }

        // ★ ECONNABORTED/EWOULDBLOCK/EAGAIN：调整超时并重试
        if (nanoTimeout >= NET_NSEC_PER_MSEC) {
            currNanoTime = JVM_NanoTime(env, 0);
            nanoTimeout -= (currNanoTime - prevNanoTime);
            if (nanoTimeout < NET_NSEC_PER_MSEC) {
                JNU_ThrowByName(env, JNU_JAVANETPKG "SocketTimeoutException",
                        "Accept timed out");
                return;
            }
            prevNanoTime = currNanoTime;
        }
    }

    // ★ 错误处理
    if (newfd < 0) {
        if (newfd == -2) {
            JNU_ThrowByName(env, JNU_JAVAIOPKG "InterruptedIOException",
                            "operation interrupted");
        } else {
            if (errno == EINVAL) {
                errno = EBADF;
            }
            if (errno == EBADF) {
                JNU_ThrowByName(env, JNU_JAVANETPKG "SocketException", "Socket closed");
            } else {
                JNU_ThrowByNameWithMessageAndLastError
                    (env, JNU_JAVANETPKG "SocketException", "Accept failed");
            }
        }
        return;
    }

    // ★ 将 sockaddr 转换为 Java 的 InetAddress
    socketAddressObj = NET_SockaddrToInetAddress(env, &sa, &port);
    if (socketAddressObj == NULL) {
        close(newfd);
        return;
    }

    // ★ 设置新 Socket 的字段
    socketFdObj = (*env)->GetObjectField(env, socket, psi_fdID);
    (*env)->SetIntField(env, socketFdObj, IO_fd_fdID, newfd);

    (*env)->SetObjectField(env, socket, psi_addressID, socketAddressObj);
    (*env)->SetIntField(env, socket, psi_portID, port);
    
    // ★ 设置本地端口
    port = (*env)->GetIntField(env, this, psi_localportID);
    (*env)->SetIntField(env, socket, psi_localportID, port);
}
```

### 4.3 NET_Timeout() 实现原理

```c
// net_util_md.c (简化版)
int NET_Timeout(JNIEnv *env, int fd, long timeout, jlong prevNanoTime) {
    struct pollfd pfd;
    int result;
    
    pfd.fd = fd;
    pfd.events = POLLIN;  // ★ 等待可读（有连接到来）
    
    // ★ 调用 poll 系统调用
    result = poll(&pfd, 1, timeout);
    
    // ★ poll 返回值：
    // > 0：有事件发生
    // = 0：超时
    // = -1：错误（检查 errno）
    
    return result;
}
```

**为什么 ServerSocket 创建时设置 O_NONBLOCK？**

```
流程：
  1. ServerSocket 创建时设置 O_NONBLOCK
  2. socketAccept() 先调用 NET_Timeout(poll)
  3. poll 等待连接或超时
  4. 有连接时调用 accept()
  5. accept() 立即返回（因为是非阻塞且有连接）

如果不设置非阻塞：
  accept() 可能阻塞，无法实现超时
```

---

## 五、核心函数 4：socketRead0() — 阻塞读取 ⭐⭐⭐⭐⭐

### 5.1 解决什么问题？

**如何从 Socket 读取数据？如何实现读取超时？**

### 5.2 完整源码 + 逐行注释

```c
// SocketInputStream.c:90-170
JNIEXPORT jint JNICALL
Java_java_net_SocketInputStream_socketRead0(JNIEnv *env, jobject this,
                                            jobject fdObj, jbyteArray data,
                                            jint off, jint len, jint timeout)
{
    char BUF[MAX_BUFFER_LEN];  // ★ 栈缓冲区（避免频繁 malloc）
    char *bufP;
    jint fd, nread;

    if (IS_NULL(fdObj)) {
        JNU_ThrowByName(env, "java/net/SocketException",
                        "Socket closed");
        return -1;
    }
    fd = (*env)->GetIntField(env, fdObj, IO_fd_fdID);
    if (fd == -1) {
        JNU_ThrowByName(env, "java/net/SocketException", "Socket closed");
        return -1;
    }

    // ★★★ 缓冲区选择策略 ★★★
    // 1. 小数据（<= MAX_BUFFER_LEN）：用栈缓冲区
    // 2. 中等数据：用堆缓冲区（malloc）
    // 3. 大数据（> MAX_HEAP_BUFFER_LEN）：截断
    if (len > MAX_BUFFER_LEN) {
        if (len > MAX_HEAP_BUFFER_LEN) {
            len = MAX_HEAP_BUFFER_LEN;
        }
        bufP = (char *)malloc((size_t)len);
        if (bufP == NULL) {
            // ★ malloc 失败，回退到栈缓冲区
            bufP = BUF;
            len = MAX_BUFFER_LEN;
        }
    } else {
        bufP = BUF;
    }
    
    // ★★★ 分支 1：有超时 ★★★
    if (timeout) {
        nread = NET_ReadWithTimeout(env, fd, bufP, len, timeout);
        if ((*env)->ExceptionCheck(env)) {
            if (bufP != BUF) {
                free(bufP);
            }
            return nread;
        }
    } else {
        // ★★★ 分支 2：无超时（阻塞读取）★★★
        // NET_Read 底层调用 read() 或 recv()
        nread = NET_Read(fd, bufP, len);
    }

    // ★ 错误处理
    if (nread <= 0) {
        if (nread < 0) {
            switch (errno) {
                case ECONNRESET:
                case EPIPE:
                    // ★ 连接被对方重置
                    JNU_ThrowByName(env, "sun/net/ConnectionResetException",
                        "Connection reset");
                    break;

                case EBADF:
                    JNU_ThrowByName(env, "java/net/SocketException",
                        "Socket closed");
                    break;

                case EINTR:
                    // ★ 被信号中断
                    JNU_ThrowByName(env, "java/io/InterruptedIOException",
                           "Operation interrupted");
                     break;
                default:
                    JNU_ThrowByNameWithMessageAndLastError
                        (env, "java/net/SocketException", "Read failed");
            }
        }
    } else {
        // ★ 成功：将数据拷贝到 Java 数组
        (*env)->SetByteArrayRegion(env, data, off, nread, (jbyte *)bufP);
    }

    if (bufP != BUF) {
        free(bufP);
    }
    return nread;
}
```

### 5.3 NET_ReadWithTimeout() 实现原理

```c
// SocketInputStream.c:50-83
static int NET_ReadWithTimeout(JNIEnv *env, int fd, char *bufP, int len, long timeout) {
    int result = 0;
    jlong prevNanoTime = JVM_NanoTime(env, 0);
    jlong nanoTimeout = (jlong) timeout * NET_NSEC_PER_MSEC;
    
    while (nanoTimeout >= NET_NSEC_PER_MSEC) {
        // ★ 1. 用 poll 等待数据到达
        result = NET_Timeout(env, fd, nanoTimeout / NET_NSEC_PER_MSEC, prevNanoTime);
        
        if (result <= 0) {
            if (result == 0) {
                // ★ 超时
                JNU_ThrowByName(env, "java/net/SocketTimeoutException", "Read timed out");
            } else if (result == -1) {
                // ★ 错误
                if (errno == EBADF) {
                    JNU_ThrowByName(env, "java/net/SocketException", "Socket closed");
                } else if (errno == ENOMEM) {
                    JNU_ThrowOutOfMemoryError(env, "NET_Timeout native heap allocation failed");
                } else {
                    JNU_ThrowByNameWithMessageAndLastError
                            (env, "java/net/SocketException", "select/poll failed");
                }
            }
            return -1;
        }
        
        // ★ 2. 数据到达，非阻塞读取
        result = NET_NonBlockingRead(fd, bufP, len);
        
        if (result == -1 && ((errno == EAGAIN) || (errno == EWOULDBLOCK))) {
            // ★ 假唤醒（数据被其他线程读走了），调整超时并重试
            jlong newtNanoTime = JVM_NanoTime(env, 0);
            nanoTimeout -= newtNanoTime - prevNanoTime;
            if (nanoTimeout >= NET_NSEC_PER_MSEC) {
                prevNanoTime = newtNanoTime;
            }
        } else {
            break;  // ★ 成功或错误
        }
    }
    return result;
}
```

### 5.4 设计决策解释

**为什么要用栈缓冲区？**

```
性能优化：
  1. 小数据（< 8KB）频繁读取
  2. malloc/free 有性能开销
  3. 栈分配快，无堆碎片
  4. 函数返回自动释放

策略：
  - len <= MAX_BUFFER_LEN：栈缓冲区
  - len > MAX_BUFFER_LEN：堆缓冲区（malloc）
  - malloc 失败：回退到栈缓冲区
```

**为什么超时读取要用非阻塞模式？**

```
流程：
  1. poll() 等待数据到达（可设置超时）
  2. poll() 返回后立即读取
  3. 如果是假唤醒（EAGAIN），重试

如果不设置非阻塞：
  read() 可能阻塞，poll 超时无效
```

---

## 六、核心函数 5：socketWrite0() — 阻塞写入 ⭐⭐⭐⭐

### 6.1 完整源码 + 逐行注释

```c
// SocketOutputStream.c:56-126
JNIEXPORT void JNICALL
Java_java_net_SocketOutputStream_socketWrite0(JNIEnv *env, jobject this,
                                              jobject fdObj,
                                              jbyteArray data,
                                              jint off, jint len) {
    char *bufP;
    char BUF[MAX_BUFFER_LEN];
    int buflen;
    int fd;

    if (IS_NULL(fdObj)) {
        JNU_ThrowByName(env, "java/net/SocketException", "Socket closed");
        return;
    } else {
        fd = (*env)->GetIntField(env, fdObj, IO_fd_fdID);
        if (fd == -1) {
            JNU_ThrowByName(env, "java/net/SocketException", "Socket closed");
            return;
        }
    }

    // ★ 缓冲区选择（与 socketRead0 类似）
    if (len <= MAX_BUFFER_LEN) {
        bufP = BUF;
        buflen = MAX_BUFFER_LEN;
    } else {
        buflen = min(MAX_HEAP_BUFFER_LEN, len);
        bufP = (char *)malloc((size_t)buflen);

        if (bufP == NULL) {
            bufP = BUF;
            buflen = MAX_BUFFER_LEN;
        }
    }

    // ★★★ 核心：循环发送直到所有数据发送完毕 ★★★
    while(len > 0) {
        int loff = 0;
        int chunkLen = min(buflen, len);  // ★ 本次发送的块大小
        int llen = chunkLen;
        
        // ★ 从 Java 数组拷贝数据
        (*env)->GetByteArrayRegion(env, data, off, chunkLen, (jbyte *)bufP);

        if ((*env)->ExceptionCheck(env)) {
            break;
        } else {
            // ★★★ 内层循环：确保本次块完整发送 ★★★
            while(llen > 0) {
                // ★ NET_Send 底层调用 send()
                // send(fd, buf, len, flags)
                // - fd: Socket fd
                // - buf: 发送缓冲区
                // - len: 数据长度
                // - flags: 通常为 0
                // 返回：实际发送的字节数（可能 < len！）
                int n = NET_Send(fd, bufP + loff, llen, 0);
                
                if (n > 0) {
                    llen -= n;   // ★ 剩余未发送
                    loff += n;   // ★ 已发送偏移
                    continue;
                }
                
                // ★ 发送失败
                JNU_ThrowByNameWithMessageAndLastError
                    (env, "java/net/SocketException", "Write failed");
                if (bufP != BUF) {
                    free(bufP);
                }
                return;
            }
            len -= chunkLen;  // ★ 总剩余数据
            off += chunkLen;  // ★ Java 数组偏移
        }
    }

    if (bufP != BUF) {
        free(bufP);
    }
}
```

### 6.2 设计决策解释

**为什么要分块发送？**

```
问题：send() 可能只发送部分数据

场景：
  - 发送缓冲区已满
  - TCP 滑动窗口限制
  - send() 返回值 < len

解决方案：
  1. 大数据分块（每块 <= buflen）
  2. 内层循环确保块完整发送
  3. 外层循环发送所有块

示例：
  要发送 100KB 数据
  1. 分成 25 块（每块 4KB）
  2. 每块可能需要多次 send()
  3. 直到所有数据发送完毕
```

---

## 七、系统调用总结 ⭐⭐⭐

| 系统调用 | 功能 | libnet 用途 | 返回值 |
|----------|------|------------|--------|
| `socket()` | 创建 Socket | socketCreate() | fd |
| `bind()` | 绑定地址 | socketBind() | 0/-1 |
| `listen()` | 监听连接 | socketListen() | 0/-1 |
| `accept()` | 接受连接 | socketAccept() | 新 fd |
| `connect()` | 连接服务器 | socketConnect() | 0/-1 |
| `read()/recv()` | 读取数据 | socketRead0() | 字节数 |
| `write()/send()` | 写入数据 | socketWrite0() | 字节数 |
| `close()` | 关闭 Socket | socketClose0() | 0/-1 |
| `shutdown()` | 关闭连接 | socketShutdown() | 0/-1 |
| `getsockopt()` | 获取选项 | socketGetOption() | 0/-1 |
| `setsockopt()` | 设置选项 | socketSetOption0() | 0/-1 |
| `getsockname()` | 获取本地地址 | socketBind/Connect | 0/-1 |
| `poll()` | 多路复用 | NET_Timeout() | 就绪数量 |
| `fcntl()` | 设置标志 | SET_NONBLOCKING | 0/-1 |
| `ioctl()` | I/O 控制 | socketAvailable() | 0/-1 |

---

## 八、libnet vs libnio 对比 ⭐⭐⭐⭐⭐

### 8.1 I/O 模型对比

| 维度 | libnet | libnio |
|------|--------|--------|
| 模型 | 阻塞 I/O | 非阻塞 I/O |
| 系统调用 | `read()/write()` 直接阻塞 | `poll()` + 非阻塞读写 |
| 线程模型 | 一连接一线程 | 单线程多连接 |
| 上下文切换 | 多（线程切换） | 少（单线程） |

### 8.2 零拷贝对比

| 维度 | libnet | libnio |
|------|--------|--------|
| 文件读取 | `read()` → 用户态 | `mmap()` → 零拷贝 |
| 文件传输 | `read()` + `write()` | `sendfile()` → 零拷贝 |
| 缓冲区 | 堆内存 byte[] | DirectByteBuffer |

### 8.3 多路复用对比

| 维度 | libnet | libnio |
|------|--------|--------|
| 多路复用 | 仅用于超时 | 核心机制 |
| 就绪通知 | 无 | poll/epoll |
| 连接数限制 | 线程数限制 | 几乎无限制 |

### 8.4 代码对比：读取数据

**libnet 实现**：

```c
// libnet: 阻塞读取
nread = NET_Read(fd, bufP, len);  // 直接阻塞
```

**libnio 实现**：

```c
// libnio: 非阻塞读取
n = recvfrom(fd, buf, len, 0, &sa.sa, &sa_len);
if (errno == EAGAIN || errno == EWOULDBLOCK) {
    return IOS_UNAVAILABLE;  // 无数据，稍后重试
}
```

---

## 九、GDB 验证

### 9.1 strace 跟踪 Socket 操作

```bash
# 跟踪 Socket 相关系统调用
strace -e trace=socket,bind,listen,accept,connect,read,write,close,fcntl,poll \
    java -cp . SocketExample

# 示例输出
socket(AF_INET6, SOCK_STREAM, IPPROTO_IP) = 4
fcntl(4, F_SETFL, O_RDONLY|O_NONBLOCK)   = 0
setsockopt(4, SOL_SOCKET, SO_REUSEADDR, [1], 4) = 0
bind(4, {sa_family=AF_INET6, sin6_port=htons(8080), ...}, 28) = 0
listen(4, 50)                             = 0
poll([{fd=4, events=POLLIN}], 1, -1)      = 1
accept(4, {sa_family=AF_INET6, ...}, [28]) = 5
read(5, "hello", 5)                       = 5
write(5, "world", 5)                      = 5
close(5)                                  = 0
```

### 9.2 GDB 打印数据结构

```gdb
# 打印 SOCKETADDRESS
(gdb) p sizeof(SOCKETADDRESS)
$1 = 28  # IPv4

(gdb) p sa.sa4.sin_port
$2 = 8080

# 打印 pollfd
(gdb) p sizeof(struct pollfd)
$3 = 8

(gdb) p pfd
$4 = {fd = 4, events = 1, revents = 0}
```

---

## 十、核心文件清单

| 文件 | 核心函数 | 功能 |
|------|----------|------|
| `PlainSocketImpl.c` | socketCreate, socketConnect, socketAccept, socketBind, socketListen | Socket 核心操作 |
| `SocketInputStream.c` | socketRead0 | 阻塞读取 |
| `SocketOutputStream.c` | socketWrite0 | 阻塞写入 |
| `net_util_md.c` | NET_Timeout, NET_Read, NET_Send | 网络工具函数 |
| `PlainDatagramSocketImpl.c` | socketCreate, send, receive | UDP 操作 |
| `Inet4AddressImpl.c` | lookupAllHostAddr | DNS 解析 |

---

## 十一、总结

### 11.1 libnet 核心特点

| 特点 | 优势 | 劣势 |
|------|------|------|
| 阻塞 I/O | 编程简单 | 线程资源消耗大 |
| 无零拷贝 | 兼容性好 | 性能受限 |
| 无多路复用 | 理解容易 | 高并发受限 |

### 11.2 与 libnio 的关系

```
libnet = 传统阻塞 I/O（简单、兼容）
libnio = 现代 NIO（高性能、高并发）

libnet 不是过时产品，而是不同场景的选择：
  - 简单客户端：libnet
  - 高并发服务端：libnio
  - 文件传输：libnio（零拷贝）
  - 短连接：libnet
```

### 11.3 关键设计模式

| 模式 | 应用 |
|------|------|
| 工厂模式 | InetAddressImplFactory |
| 适配器模式 | InetAddress ↔ sockaddr 转换 |
| 缓存模式 | fieldID 缓存 |
| 栈缓冲区优化 | 小数据用栈，大数据用堆 |

---

## 附录：参考资料

- `man 2 socket` - Socket 创建
- `man 2 bind` - 地址绑定
- `man 2 listen` - 监听连接
- `man 2 accept` - 接受连接
- `man 2 connect` - 连接服务器
- `man 2 send` - 发送数据
- `man 2 recv` - 接收数据
- `man 2 poll` - 多路复用
- `man 2 fcntl` - 文件控制
- `man 2 ioctl` - I/O 控制
