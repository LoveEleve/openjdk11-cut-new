# 第 9 章：BIO DatagramSocket — 传统 UDP

> **核心问题**：NIO 的 DatagramChannel（第 7 章）和 BIO 的 DatagramSocket 底层都是 UDP socket，但它们的实现有什么根本区别？BIO 版本如何处理组播？为什么 macOS 上要禁用原生 connect？

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **第 9 章：BIO DatagramSocket — 传统 UDP**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 1. BIO UDP 的定位

DatagramSocket/MulticastSocket 是 JDK 最早的 UDP API（JDK 1.0），比 DatagramChannel（JDK 1.4 NIO）早 4 年。至今仍广泛使用的场景：

- **DNS 查询**：`InetAddress.getByName()` 底层就用 DatagramSocket
- **简单 UDP 通信**：日志采集（syslog）、游戏心跳、SNMP
- **组播应用**：MulticastSocket 继承 DatagramSocket，提供 join/leave 组播组

**与 NIO DatagramChannel 的核心区别**：

| 维度 | BIO DatagramSocket | NIO DatagramChannel |
|------|---------------------|---------------------|
| 阻塞模型 | 永远阻塞（靠 SO_TIMEOUT poll 实现超时） | 可配置阻塞/非阻塞 |
| I/O 方式 | `byte[]` + DatagramPacket | ByteBuffer |
| Selector 集成 | 不支持 | 支持 |
| 关闭机制 | 简单 close（无 preClose 协议） | preClose + signal + state machine |
| 组播支持 | MulticastSocket.joinGroup() | MembershipKey（NIO.2 JDK 7） |
| 线程安全 | synchronized receive | stateLock + readLock/writeLock |

---

## 2. 类继承体系

```
java.net.DatagramSocketImpl (abstract)
  └── AbstractPlainDatagramSocketImpl (abstract, share/)
        ├── 字段: timeout, connected, trafficClass, connectedAddress, connectedPort
        ├── connectDisabled = os.contains("OS X")   // macOS 禁用原生 connect
        ├── create() → ResourceManager.beforeUdpCreate() + datagramSocketCreate()
        ├── send() → 处理 link-local 地址 + send0()
        ├── connect()/disconnect() → connect0()/disconnect0() + 记录连接状态
        ├── receive() → synchronized → receive0()
        ├── close() → SocketCleanable.unregister + datagramSocketClose + ResourceManager.afterUdpClose
        └── PlainDatagramSocketImpl (unix/, 具体实现)
              ├── static { init(); }  // 缓存字段 ID + 初始化 NetworkInterface
              ├── 所有 native 方法 → PlainDatagramSocketImpl.c (2222行)
              └── ExtendedSocketOptions 支持

上层 API:
  DatagramSocket (1407行)
    └── MulticastSocket extends DatagramSocket (736行)
          ├── joinGroup()/leaveGroup() → impl.join/leave
          ├── setTimeToLive()/getTimeToLive() → impl.setTimeToLive
          └── setInterface()/getInterface() → impl.setOption(IP_MULTICAST_IF)
```

---

## 3. init — 初始化

```c
// PlainDatagramSocketImpl.c:138
JNIEXPORT void JNICALL
Java_java_net_PlainDatagramSocketImpl_init(JNIEnv *env, jclass cls) {
    pdsi_fdID            = GetFieldID(env, cls, "fd", "Ljava/io/FileDescriptor;");
    pdsi_timeoutID       = GetFieldID(env, cls, "timeout", "I");
    pdsi_trafficClassID  = GetFieldID(env, cls, "trafficClass", "I");
    pdsi_localPortID     = GetFieldID(env, cls, "localPort", "I");
    pdsi_connected       = GetFieldID(env, cls, "connected", "Z");
    pdsi_connectedAddress = GetFieldID(env, cls, "connectedAddress", "Ljava/net/InetAddress;");
    pdsi_connectedPort   = GetFieldID(env, cls, "connectedPort", "I");
    IO_fd_fdID           = NET_GetFileDescriptorID(env);

    initInetAddressIDs(env);
    Java_java_net_NetworkInterface_init(env, 0);  // 组播需要 NetworkInterface
}
```

**特别之处**：BIO 的 `init` 额外调用了 `Java_java_net_NetworkInterface_init()` 来初始化 NetworkInterface 相关的 JNI 字段，因为组播操作需要通过 NetworkInterface 指定网卡接口。NIO 的 DatagramChannel 没有这个调用（NIO 的组播在 Net.java 中独立处理）。

---

## 4. datagramSocketCreate — 创建 UDP socket

### 4.1 Java 层

```java
// AbstractPlainDatagramSocketImpl.java:114
protected synchronized void create() throws SocketException {
    ResourceManager.beforeUdpCreate();  // 检查 UDP fd 配额
    fd = new FileDescriptor();
    try {
        datagramSocketCreate();
        SocketCleanable.register(fd);
    } catch (SocketException ioe) {
        ResourceManager.afterUdpClose();
        fd = null;
        throw ioe;
    }
}
```

### 4.2 Native 层

```c
// PlainDatagramSocketImpl.c:890
JNIEXPORT void JNICALL
Java_java_net_PlainDatagramSocketImpl_datagramSocketCreate(JNIEnv *env, jobject this) {
    int domain = ipv6_available() ? AF_INET6 : AF_INET;
    
    if ((fd = socket(domain, SOCK_DGRAM, 0)) == -1) {
        throw SocketException("Error creating socket");
        return;
    }
    
    // 1. 禁用 IPV6_V6ONLY → 双栈
    if (domain == AF_INET6) {
        int arg = 0;
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &arg, sizeof(int));
    }
    
    // 2. macOS 特殊：设置缓冲区为 65507（UDP 最大负载）
    #ifdef __APPLE__
    arg = 65507;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &arg, sizeof(arg));
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &arg, sizeof(arg));
    #endif
    
    // 3. 启用广播
    int t = 1;
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &t, sizeof(int));
    
    // 4. Linux: 禁用 IP_MULTICAST_ALL
    #ifdef __linux__
    arg = 0;
    int level = (domain == AF_INET6) ? IPPROTO_IPV6 : IPPROTO_IP;
    setsockopt(fd, level, IP_MULTICAST_ALL, &arg, sizeof(arg));
    #endif
    
    // 5. Linux IPv6: 设置组播 hop limit = 1（与 IPv4 TTL=1 一致）
    #ifdef __linux__
    if (domain == AF_INET6) {
        int ttl = 1;
        setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_HOPS, &ttl, sizeof(ttl));
    }
    #endif
    
    SetIntField(env, fdObj, IO_fd_fdID, fd);
}
```

**关键初始化选项**：

| 选项 | 值 | 原因 |
|------|-----|------|
| `IPV6_V6ONLY = 0` | 禁用 | 双栈模式：一个 AF_INET6 socket 同时处理 IPv4/IPv6 |
| `SO_BROADCAST = 1` | 启用 | UDP 需要广播能力（如 DHCP、LAN 发现） |
| `IP_MULTICAST_ALL = 0` | 禁用 | Linux 特有：默认会收到**所有组播组**的数据包（不仅是已 join 的）。禁用后只收到已加入的组播组的数据 |
| `IPV6_MULTICAST_HOPS = 1` | 设为 1 | Linux IPv6 默认组播 hop limit = -1（使用内核默认值 1），但显式设为 1 确保与 IPv4 的 TTL=1 行为一致 |
| macOS `SO_SNDBUF/SO_RCVBUF = 65507` | 设为 UDP 最大负载 | macOS 默认缓冲区可能太小，无法发送/接收最大 UDP 数据包 |

**对比 BIO TCP 的 socketCreate**：TCP 不设 `SO_BROADCAST`（TCP 不支持广播），不设组播选项（TCP 不支持组播），但会检查 `serverSocket` 字段来决定是否自动设置 `SO_REUSEADDR` 和非阻塞模式。

---

## 5. send0 — 发送数据报

```c
// PlainDatagramSocketImpl.c:333
JNIEXPORT void JNICALL
Java_java_net_PlainDatagramSocketImpl_send0(JNIEnv *env, jobject this,
                                           jobject packet) {
    char BUF[MAX_BUFFER_LEN];
    char *fullPacket = NULL;
    int mallocedPacket = JNI_FALSE;
    
    jboolean connected = GetBooleanField(env, this, pdsi_connected);
    
    // 从 DatagramPacket 提取 buffer、address、port
    packetBuffer = GetObjectField(env, packet, dp_bufID);
    packetAddress = GetObjectField(env, packet, dp_addressID);
    packetBufferOffset = GetIntField(env, packet, dp_offsetID);
    packetBufferLen = GetIntField(env, packet, dp_lengthID);
    
    // 已连接：不传地址（sendto 的 addr 参数为 NULL）
    // 未连接：需要目标地址
    struct sockaddr *rmtaddrP = 0;
    int len = 0;
    if (!connected) {
        packetPort = GetIntField(env, packet, dp_portID);
        NET_InetAddressToSockaddr(env, packetAddress, packetPort, &rmtaddr, &len, JNI_TRUE);
        rmtaddrP = &rmtaddr.sa;
    }
    
    // 缓冲区分配（UDP 必须一次性发送整个数据报）
    if (packetBufferLen > MAX_BUFFER_LEN) {
        if (packetBufferLen > MAX_PACKET_LEN)  // 截断到 65535
            packetBufferLen = MAX_PACKET_LEN;
        fullPacket = malloc(packetBufferLen);
        if (!fullPacket) {
            throw OutOfMemoryError;
            return;
        }
        mallocedPacket = JNI_TRUE;
    } else {
        fullPacket = BUF;  // 使用栈缓冲区
    }
    
    GetByteArrayRegion(env, packetBuffer, packetBufferOffset, packetBufferLen, fullPacket);
    
    // 设置 trafficClass（IPv6 only）
    if (trafficClass != 0 && ipv6_available())
        NET_SetTrafficClass(&rmtaddr, trafficClass);
    
    // 发送
    ret = NET_SendTo(fd, fullPacket, packetBufferLen, 0, rmtaddrP, len);
    
    if (ret < 0) {
        if (errno == ECONNREFUSED)
            throw PortUnreachableException("ICMP Port Unreachable");
        else
            throw IOException("sendto failed");
    }
    
    if (mallocedPacket) free(fullPacket);
}
```

**为什么 UDP 不能像 TCP 那样分块发送？**

注释说得很清楚：`(one big send) != (several smaller sends)`。TCP 是**字节流**协议，分块发送和一次大发送结果相同。UDP 是**数据报**协议，每次 `sendto()` 产生一个独立的 IP 数据包。分块发送会产生多个小数据包而非一个大数据包，语义完全不同。

因此当 `packetBufferLen > MAX_BUFFER_LEN`（64KB）时，**必须** malloc 分配足够大的缓冲区。

**MAX_PACKET_LEN = 65535**：UDP 数据报最大长度受 IP 头的 Total Length 字段限制（16 位，最大 65535 字节）。减去 IP 头（20 字节）和 UDP 头（8 字节），实际最大负载为 65507 字节。

---

## 6. receive0 — 接收数据报

```c
// PlainDatagramSocketImpl.c:707
JNIEXPORT void JNICALL
Java_java_net_PlainDatagramSocketImpl_receive0(JNIEnv *env, jobject this,
                                              jobject packet) {
    jint timeout = GetIntField(env, this, pdsi_timeoutID);
    
    // 分配接收缓冲区（与 send 相同策略）
    if (packetBufferLen > MAX_BUFFER_LEN) {
        if (packetBufferLen > MAX_PACKET_LEN)
            packetBufferLen = MAX_PACKET_LEN;
        fullPacket = malloc(packetBufferLen);
    } else {
        fullPacket = BUF;
    }
    
    do {
        retry = JNI_FALSE;
        
        // Step 1: 超时等待
        if (timeout) {
            ret = NET_Timeout(env, fd, timeout, JVM_NanoTime(env, 0));
            if (ret == 0)  throw SocketTimeoutException("Receive timed out");
            if (ret == -1) {
                if (errno == EBADF)   throw SocketException("Socket closed");
                else                  throw SocketException("Receive failed");
            }
        }
        
        // Step 2: 接收数据报
        n = NET_RecvFrom(fd, fullPacket, packetBufferLen, 0, &rmtaddr.sa, &slen);
        
        if (n > packetBufferLen)  // 截断
            n = packetBufferLen;
        
        if (n == -1) {
            if (errno == ECONNREFUSED)
                throw PortUnreachableException("ICMP Port Unreachable");
            else if (errno == EBADF)
                throw SocketException("Socket closed");
            else
                throw SocketException("Receive failed");
        } else {
            // Step 3: 填充 DatagramPacket
            // 优化：如果 packet 已有 address 且与发送者相同，复用 InetAddress 对象
            packetAddress = GetObjectField(env, packet, dp_addressID);
            if (packetAddress != NULL) {
                if (!NET_SockaddrEqualsInetAddress(env, &rmtaddr, packetAddress))
                    packetAddress = NULL;  // 强制创建新的
            }
            if (packetAddress == NULL) {
                packetAddress = NET_SockaddrToInetAddress(env, &rmtaddr, &port);
                SetObjectField(env, packet, dp_addressID, packetAddress);
            } else {
                port = NET_GetPortFromSockaddr(&rmtaddr);
            }
            
            SetByteArrayRegion(env, packetBuffer, packetBufferOffset, n, fullPacket);
            SetIntField(env, packet, dp_portID, port);
            SetIntField(env, packet, dp_lengthID, n);
        }
    } while (retry);
    
    if (mallocedPacket) free(fullPacket);
}
```

### 6.1 InetAddress 复用优化

和 NIO DatagramChannel 的 `cachedSenderInetAddress` 不同，BIO 使用了另一种优化：

- **NIO**：在 C 层缓存上一次发送者的地址和端口，用字段比较避免 JNI 调用
- **BIO**：检查 `DatagramPacket.address` 是否与当前发送者相同，相同则复用（只更新 port），不同则创建新的 `InetAddress`

两种优化的目标相同——避免每次 `recvfrom` 都创建新的 `InetAddress` 对象（减少 GC 压力）。

### 6.2 超时实现

与 TCP 的 `socketRead0` 相同模式：`NET_Timeout()` = `poll(POLLIN, timeout)` → 如果可读再 `recvfrom()`。`NET_Timeout` 底层使用 `linux_close.c` 的 `BLOCKING_IO_RETURN_INT` 宏，支持被 close 唤醒。

---

## 7. peek / peekData — 窥视数据报

BIO DatagramSocket 有两个 peek 操作，NIO DatagramChannel 没有：

### 7.1 peek — 只看发送者地址

```c
// PlainDatagramSocketImpl.c:455
JNIEXPORT jint JNICALL
Java_java_net_PlainDatagramSocketImpl_peek(JNIEnv *env, jobject this,
                                           jobject addressObj) {
    // 超时等待...
    
    n = NET_RecvFrom(fd, buf, 1, MSG_PEEK, &rmtaddr.sa, &slen);
    //                         ^^^^^^^^  不消费数据
    
    // 从 rmtaddr 提取地址填入 addressObj
    // 返回端口号
    return port;
}
```

`MSG_PEEK` 标志让 `recvfrom` 读取数据但**不从接收队列中移除**。下一次 `receive()` 还能读到同一个数据报。

### 7.2 peekData — 看发送者地址 + 数据内容

```c
// PlainDatagramSocketImpl.c:536
JNIEXPORT jint JNICALL
Java_java_net_PlainDatagramSocketImpl_peekData(JNIEnv *env, jobject this,
                                               jobject packet) {
    // 超时等待...
    // 分配缓冲区...
    
    n = NET_RecvFrom(fd, fullPacket, packetBufferLen, MSG_PEEK, &rmtaddr.sa, &slen);
    //                                                ^^^^^^^^
    
    // 填充 packet 的 address/port/data/length
    return port;
}
```

**用途**：在多线程环境下，一个线程可以先 `peek` 检查数据来源，决定是否交给另一个线程处理。Java API `DatagramSocket.receive()` 内部使用 `peekData` 来配合 SecurityManager 检查。

---

## 8. connect0 / disconnect0 — UDP 连接

### 8.1 connect0

```c
// PlainDatagramSocketImpl.c:236
JNIEXPORT void JNICALL
Java_java_net_PlainDatagramSocketImpl_connect0(JNIEnv *env, jobject this,
                                               jobject address, jint port) {
    NET_InetAddressToSockaddr(env, address, port, &rmtaddr, &len, JNI_TRUE);
    
    if (NET_Connect(fd, &rmtaddr.sa, len) == -1) {
        throw ConnectException("Connect failed");
    }
}
```

和 NIO DatagramChannel 的 `connect0` 完全相同：调用 `connect()` 系统调用在内核中设置地址过滤器。之后只能收到来自该地址的数据，发送也不需要指定地址。

### 8.2 macOS connectDisabled

```java
// AbstractPlainDatagramSocketImpl.java:62
private static final boolean connectDisabled = os.contains("OS X");
```

**macOS 上禁用原生 connect 的原因**：macOS 内核的 `connect()` 对 UDP socket 有 bug（历史问题），`disconnect` 后 socket 的行为不正确。所以 macOS 上用**纯 Java 模拟**连接状态：

```java
// DatagramSocket.java（简化）
public void connect(InetAddress address, int port) {
    if (!impl.nativeConnectDisabled()) {
        impl.connect(address, port);  // 真正的系统 connect
    } else {
        // macOS: 只在 Java 层记录连接地址
        connectedAddress = address;
        connectedPort = port;
        // send 时 Java 层检查目标是否匹配
        // receive 时 Java 层过滤非目标来源的数据
    }
}
```

### 8.3 disconnect0

```c
// PlainDatagramSocketImpl.c:275
JNIEXPORT void JNICALL
Java_java_net_PlainDatagramSocketImpl_disconnect0(JNIEnv *env, jobject this, jint family) {
    
#if defined(__linux__) || defined(_ALLBSD_SOURCE)
    memset(&addr, 0, sizeof(addr));
    if (ipv6_available()) {
        addr.sa6.sin6_family = AF_UNSPEC;
        len = sizeof(struct sockaddr_in6);
    } else {
        addr.sa4.sin_family = AF_UNSPEC;
        len = sizeof(struct sockaddr_in);
    }
    NET_Connect(fd, &addr.sa, len);
    
    // Linux 特殊处理：disconnect 后本地端口可能被重置为 0
    // 需要重新 bind 回原来的端口
    #if defined(__linux__)
    if (getsockname(fd, &addr.sa, &len) == -1) return;
    localPort = NET_GetPortFromSockaddr(&addr);
    if (localPort == 0) {
        localPort = GetIntField(env, this, pdsi_localPortID);
        addr.sa6.sin6_port = htons(localPort);  // 或 addr.sa4
        NET_Bind(fd, &addr, len);
    }
    #endif
    
#else
    NET_Connect(fd, 0, 0);  // Solaris
#endif
}
```

**Linux disconnect 的端口丢失问题**：在 Linux 上 `connect(fd, {AF_UNSPEC})` 断开 UDP 连接后，内核可能将本地端口重置为 0。JDK 在 disconnect 后检查端口，如果变成 0 则重新 `bind` 回原端口。这是 Linux 内核的行为（不是 bug，是设计），BSD/macOS 不存在此问题。

**对比 NIO DatagramChannel 的 disconnect0**：NIO 的 `DatagramChannelImpl.c:disconnect0` 逻辑几乎相同（见第 7 章），都是 `connect(AF_UNSPEC)` + Linux 端口恢复。BIO 和 NIO 的 disconnect 实现是独立的（不共享代码），但逻辑完全一致。

---

## 9. datagramSocketClose — 关闭

```c
// PlainDatagramSocketImpl.c:984
JNIEXPORT void JNICALL
Java_java_net_PlainDatagramSocketImpl_datagramSocketClose(JNIEnv *env, jobject this) {
    // 注意：源码注释说 "REMIND: PUT A LOCK AROUND THIS CODE"
    // 实际上没有加锁！
    jobject fdObj = GetObjectField(env, this, pdsi_fdID);
    if (IS_NULL(fdObj)) return;
    int fd = GetIntField(env, fdObj, IO_fd_fdID);
    if (fd == -1) return;
    
    SetIntField(env, fdObj, IO_fd_fdID, -1);
    NET_SocketClose(fd);
}
```

**对比 BIO TCP 和 NIO 的关闭**：

| 实现 | 关闭机制 |
|------|----------|
| BIO TCP (PlainSocketImpl) | `dup2(marker_fd, fd)` + `pthread_kill` + `fdUseCount` 引用计数 |
| NIO DatagramChannel | `preClose(dup2)` + `NativeThread.signal()` + 5 态状态机 |
| **BIO UDP (PlainDatagramSocketImpl)** | **直接 `close(fd)`，无 preClose，无唤醒机制** |

**为什么 BIO UDP 不需要复杂的关闭协议？**

1. `receive()` 方法是 `synchronized` 的，同一时刻只有一个线程在 `recvfrom`
2. `NET_SocketClose(fd)` 会通过 `linux_close.c` 的 `closefd` 机制向阻塞线程发送信号（因为 `NET_RecvFrom` 使用了 `BLOCKING_IO_RETURN_INT` 宏注册了线程）
3. Java 层先将 fd 设为 -1，然后 close。如果有线程正在 `recvfrom`，信号会让它返回 EINTR/EBADF

但注意源码注释 `"REMIND: PUT A LOCK AROUND THIS CODE"` ——这是一个已知的**线程安全隐患**，理论上 `SetIntField + NET_SocketClose` 不是原子的。

---

## 10. 组播支持 — join/leave

BIO 的组播实现在 `PlainDatagramSocketImpl.c` 中占了 1200+ 行（超过一半），远比 NIO 的 `Net.c` 中的实现复杂。

### 10.1 mcast_join_leave — 核心函数

```c
// PlainDatagramSocketImpl.c:1890
static void mcast_join_leave(JNIEnv *env, jobject this,
                             jobject iaObj, jobject niObj,
                             jboolean join) {
    int ipv6_join_leave = ipv6_available();
    
    // Linux 特殊：IPv4 组播地址强制使用 IPv4 选项
    #ifdef __linux__
    if (getInetAddress_family(iaObj) == IPv4)
        ipv6_join_leave = JNI_FALSE;
    #endif
    
    // === IPv4 路径 ===
    if (!ipv6_join_leave) {
        #ifdef __linux__
        struct ip_mreqn mname;   // Linux 使用 ip_mreqn（含 ifindex）
        #else
        struct ip_mreq mname;    // 其他平台使用 ip_mreq
        #endif
        
        if (niObj != NULL) {
            // joinGroup(InetAddress, NetworkInterface)
            // Linux IPv6 可用时：用 ip_mreqn.imr_ifindex
            // 其他：用 NetworkInterface 的第一个 IPv4 地址
            mname.imr_multiaddr.s_addr = htonl(getInetAddress_addr(iaObj));
            mname.imr_ifindex = GetIntField(niObj, "index");
        } else {
            // joinGroup(InetAddress)
            // 获取当前 IP_MULTICAST_IF 的接口地址
            getsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &in, &len);
            mname.imr_interface.s_addr = in.s_addr;
            mname.imr_multiaddr.s_addr = htonl(getInetAddress_addr(iaObj));
        }
        
        setsockopt(fd, IPPROTO_IP,
                   join ? IP_ADD_MEMBERSHIP : IP_DROP_MEMBERSHIP,
                   &mname, mname_len);
        
        // Linux ENOPROTOOPT 回退：IPv6 socket 上 IP_ADD_MEMBERSHIP 失败
        // 切换到 IPV6_ADD_MEMBERSHIP
        #ifdef __linux__
        if (errno == ENOPROTOOPT && ipv6_available())
            ipv6_join_leave = JNI_TRUE;
        #endif
    }
    
    // === IPv6 路径 ===
    if (ipv6_join_leave) {
        struct ipv6_mreq mname6;
        
        // IPv4 地址 → IPv4-mapped IPv6 地址
        if (family == AF_INET) {
            memset(caddr, 0, 16);
            caddr[10] = 0xff; caddr[11] = 0xff;
            // 后 4 字节为 IPv4 地址
        } else {
            getInet6Address_ipaddress(iaObj, caddr);
        }
        
        memcpy(&mname6.ipv6mr_multiaddr, caddr, sizeof(struct in6_addr));
        
        if (niObj == NULL)
            getsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_IF, &index, &len);
        else
            index = GetIntField(niObj, "index");
        mname6.ipv6mr_interface = index;
        
        setsockopt(fd, IPPROTO_IPV6,
                   join ? IPV6_ADD_MEMBERSHIP : IPV6_DROP_MEMBERSHIP,
                   &mname6, sizeof(mname6));
    }
}
```

### 10.2 Linux 双协议栈组播的复杂性

Linux 上 IPv4 组播和 IPv6 组播必须分开处理，不能用 IPv4-mapped 地址走 IPv6 路径（内核不支持）。因此代码有大量的 `#ifdef __linux__` 条件编译：

```
Linux IPv6 socket 加入 IPv4 组播组:
  1. 先尝试 setsockopt(IPPROTO_IP, IP_ADD_MEMBERSHIP, ip_mreqn)
  2. 如果返回 ENOPROTOOPT（IPv6 socket 不支持 IPv4 选项）
  3. 回退到 setsockopt(IPPROTO_IPV6, IPV6_ADD_MEMBERSHIP, ipv6_mreq)
     其中 IPv4 地址被转换为 IPv4-mapped IPv6 地址 ::ffff:x.x.x.x
```

**对比 NIO 的组播实现**（第 7 章的 `Net.c:joinOrDrop4/joinOrDrop6`）：NIO 将 IPv4 和 IPv6 路径清晰分离，通过 `MembershipKey` 管理状态。BIO 在一个 2222 行的 C 文件中处理所有逻辑，代码更冗长。

### 10.3 BSD/Linux 组播常量差异

```c
// BSD (macOS, FreeBSD)
#define ADD_MEMBERSHIP  IPV6_JOIN_GROUP
#define DRP_MEMBERSHIP  IPV6_LEAVE_GROUP

// Linux
#define ADD_MEMBERSHIP  IPV6_ADD_MEMBERSHIP
#define DRP_MEMBERSHIP  IPV6_DROP_MEMBERSHIP
```

功能完全相同，只是常量名字不同（BSD 用 `JOIN/LEAVE`，Linux 用 `ADD/DROP`）。

---

## 11. 组播接口与选项

### 11.1 setMulticastInterface — 设置组播出站接口

```
┌────────────────────────────────────────────────────────────────────┐
│ setMulticastInterface 分发逻辑                                      │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  IP_MULTICAST_IF (value = InetAddress):                            │
│    Linux: 同时设 IPv4 (IP_MULTICAST_IF) + IPv6 (IPV6_MULTICAST_IF)│
│    其他:  IPv6 可用 → IPv6 路径 ; 否则 → IPv4 路径                  │
│                                                                    │
│  IP_MULTICAST_IF2 (value = NetworkInterface):                      │
│    Linux: 同时设 IPv4 + IPv6                                       │
│    其他:  IPv6 可用 → 用 interface index ; 否则 → 用第一个 IPv4 地址 │
│                                                                    │
│  IPv4 设置: setsockopt(IPPROTO_IP, IP_MULTICAST_IF, struct in_addr)│
│  IPv6 设置: setsockopt(IPPROTO_IPV6, IPV6_MULTICAST_IF, int index) │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

**Linux 为什么要同时设 IPv4 和 IPv6？**

Linux 的双栈 socket（AF_INET6 + IPV6_V6ONLY=0）在内核中维护**两个独立的**组播接口配置。发送 IPv4 组播时用 `IP_MULTICAST_IF` 的设置，发送 IPv6 组播时用 `IPV6_MULTICAST_IF` 的设置。所以必须同时设置两个。

### 11.2 setMulticastLoopbackMode

```c
// IPv4: setsockopt(IPPROTO_IP, IP_MULTICAST_LOOP, char)
//   注意：IPv4 用 char 类型（1 字节）
// IPv6: setsockopt(IPPROTO_IPV6, IPV6_MULTICAST_LOOP, int)
//   注意：IPv6 用 int 类型（4 字节）
```

**Java 层的语义反转**：Java 的 `getLoopbackMode()` 返回 `true` 表示**禁用**回环，和系统调用的语义相反。C 层代码 `loopback = (!on ? 1 : 0)` 做了翻转。

### 11.3 setTimeToLive / getTimeToLive

```c
// IPv4: setsockopt(IPPROTO_IP, IP_MULTICAST_TTL, char)
// IPv6: setsockopt(IPPROTO_IPV6, IPV6_MULTICAST_HOPS, int)
```

**Linux 双协议栈**：同时设置 IPv4 TTL 和 IPv6 hop limit。

---

## 12. socketSetOption0 / socketGetOption

### 12.1 支持的选项

```
┌─────────────────────┬──────────────────────────────┬────────────────────────────┐
│ Java 选项            │ 系统调用参数                   │ 说明                       │
├─────────────────────┼──────────────────────────────┼────────────────────────────┤
│ SO_TIMEOUT          │ (不传到内核)                   │ Java 层 poll 实现           │
│ SO_REUSEADDR        │ SOL_SOCKET, SO_REUSEADDR     │ 地址重用                    │
│ SO_REUSEPORT        │ SOL_SOCKET, SO_REUSEPORT     │ 端口重用                    │
│ SO_BROADCAST        │ SOL_SOCKET, SO_BROADCAST     │ 广播（创建时已自动启用）       │
│ SO_SNDBUF           │ SOL_SOCKET, SO_SNDBUF        │ 发送缓冲区                  │
│ SO_RCVBUF           │ SOL_SOCKET, SO_RCVBUF        │ 接收缓冲区                  │
│ IP_TOS              │ IPPROTO_IP, IP_TOS           │ 服务类型/DSCP               │
│ IP_MULTICAST_IF     │ IPPROTO_IP, IP_MULTICAST_IF  │ 组播出站接口（InetAddress）   │
│ IP_MULTICAST_IF2    │ 同上 / IPPROTO_IPV6          │ 组播出站接口（NetworkInterface）│
│ IP_MULTICAST_LOOP   │ IP/IPV6_MULTICAST_LOOP       │ 组播回环                    │
│ SO_BINDADDR         │ (通过 getsockname)            │ 只读：获取绑定地址            │
└─────────────────────┴──────────────────────────────┴────────────────────────────┘
```

**对比 TCP 选项**：UDP 多了 `SO_BROADCAST`、`IP_MULTICAST_IF/IF2/LOOP`，少了 `TCP_NODELAY`、`SO_LINGER`、`SO_KEEPALIVE`、`SO_OOBINLINE`。

### 12.2 socketGetOption 返回值类型

BIO UDP 的 `socketGetOption` 返回 `jobject`（Java Object），使用 `createInteger()`/`createBoolean()` 工厂方法创建包装对象。每次调用都 `NewObject`，这在高频调用场景下有 GC 压力。NIO 使用 int 返回值避免了这个问题。

---

## 13. BIO vs NIO UDP 对比总结

```
┌────────────────────┬──────────────────────────────────┬────────────────────────────────┐
│                    │ BIO (DatagramSocket)             │ NIO (DatagramChannel)          │
├────────────────────┼──────────────────────────────────┼────────────────────────────────┤
│ C 源文件            │ PlainDatagramSocketImpl.c        │ DatagramChannelImpl.c          │
│                    │ (2222行, 含组播1200行)             │ (240行, 组播在 Net.c)           │
├────────────────────┼──────────────────────────────────┼────────────────────────────────┤
│ I/O 缓冲区         │ byte[] + JNI 中间缓冲区            │ ByteBuffer (Direct/Heap)       │
│                    │ (栈 64KB + 堆 malloc)             │ (Util.getTemporaryDirectBuffer) │
├────────────────────┼──────────────────────────────────┼────────────────────────────────┤
│ 发送 syscall       │ NET_SendTo → sendto()            │ send0 → sendto()               │
│ 接收 syscall       │ NET_RecvFrom → recvfrom()        │ receive0 → recvfrom()          │
├────────────────────┼──────────────────────────────────┼────────────────────────────────┤
│ 超时实现            │ NET_Timeout(poll) + recvfrom     │ Selector.select(timeout)       │
├────────────────────┼──────────────────────────────────┼────────────────────────────────┤
│ peek 支持          │ peek(MSG_PEEK) + peekData        │ 无（可用 read mode 模拟）       │
├────────────────────┼──────────────────────────────────┼────────────────────────────────┤
│ 组播 join/leave    │ mcast_join_leave (同一文件)        │ Net.joinOrDrop4/6 (Net.c)      │
│ 组播接口设置        │ setMulticastInterface (400行)     │ Net.setInterface4/6            │
├────────────────────┼──────────────────────────────────┼────────────────────────────────┤
│ 状态管理            │ 无状态机，boolean connected       │ 5态状态机 (非单调)              │
├────────────────────┼──────────────────────────────────┼────────────────────────────────┤
│ 关闭机制            │ 直接 close(fd)                   │ preClose+signal+wait           │
├────────────────────┼──────────────────────────────────┼────────────────────────────────┤
│ 线程安全            │ synchronized receive             │ readLock/writeLock/stateLock   │
├────────────────────┼──────────────────────────────────┼────────────────────────────────┤
│ macOS connect      │ connectDisabled=true (Java 层模拟) │ 可用（C 层处理差异）            │
├────────────────────┼──────────────────────────────────┼────────────────────────────────┤
│ 地址缓存优化        │ 检查 packet.address 是否可复用     │ cachedSenderInetAddress/Port   │
├────────────────────┼──────────────────────────────────┼────────────────────────────────┤
│ ECONNREFUSED       │ 直接抛 PortUnreachableException   │ 已连接抛/未连接忽略重试         │
├────────────────────┼──────────────────────────────────┼────────────────────────────────┤
│ ResourceManager    │ 有 (beforeUdpCreate/afterUdpClose)│ 有 (相同)                     │
└────────────────────┴──────────────────────────────────┴────────────────────────────────┘
```

---

## 14. 面试高频问题

### Q1: DatagramSocket 和 DatagramChannel 底层调用的系统函数一样吗？

答：**基本一样**。都是 `socket(SOCK_DGRAM)` 创建、`sendto()` 发送、`recvfrom()` 接收。关键区别在于包装层：BIO 使用 `NET_SendTo/NET_RecvFrom`（经过 `linux_close.c` 的 `BLOCKING_IO_RETURN_INT` 宏，支持被 close 唤醒）；NIO 的 `send0/receive0` 是直接调用系统函数的简单包装。

### Q2: 为什么 PlainDatagramSocketImpl.c 有 2222 行，比 DatagramChannelImpl.c 的 240 行多 10 倍？

答：主要因为组播。BIO 在 `PlainDatagramSocketImpl.c` 中直接实现了所有组播逻辑（`mcast_join_leave` + `setMulticastInterface` + `getMulticastInterface` + `setMulticastLoopbackMode` + `setTTL/getTTL`），占了 1200+ 行。NIO 将组播逻辑放在共享的 `Net.c` 中，`DatagramChannelImpl.c` 只负责基本的 send/receive/connect/disconnect。

### Q3: macOS 上 DatagramSocket.connect() 为什么不调用系统 connect()？

答：macOS 内核的 `connect()` 对 UDP socket 有历史 bug，disconnect 后 socket 行为异常。所以 `AbstractPlainDatagramSocketImpl` 通过 `connectDisabled = os.contains("OS X")` 标志在 macOS 上禁用原生 connect。DatagramSocket 在 Java 层模拟连接状态：记录 `connectedAddress/connectedPort`，send 时检查目标，receive 时过滤非目标来源。NIO DatagramChannel 在 macOS 上仍使用 `disconnectx()` 函数（JDK 14+），处理方式不同。

### Q4: IP_MULTICAST_ALL 是什么？为什么默认禁用？

答：`IP_MULTICAST_ALL` 是 Linux 特有的选项（内核 2.6.31+）。启用时（默认），UDP socket 会收到**同一端口上所有组播组**的数据包，不仅是自己 `join` 的组。在多个进程共享同一端口（`SO_REUSEADDR`）接收不同组播组时，会导致收到不想要的数据。JDK 在创建 UDP socket 时将其设为 0（禁用），确保只收到已加入组的数据。

### Q5: UDP 发送为什么不能分块？

答：UDP 是数据报协议，每次 `sendto()` 生成一个独立的 IP 包。如果将 64KB 数据分成多次 `sendto()`，接收方会收到多个小数据报（每个需要独立 `recvfrom()`），而不是一个大数据报。这完全改变了语义。因此 `send0` 对于 `> MAX_BUFFER_LEN` 的数据必须 `malloc` 分配足够大的缓冲区一次性发送。

---

## 15. 源码文件交叉引用

| 文件 | 路径 | 行数 | 角色 |
|------|------|------|------|
| `PlainDatagramSocketImpl.c` | `unix/native/libnet/` | 2222 | 核心 JNI：datagramSocketCreate→socket(SOCK_DGRAM)+SO_BROADCAST+IP_MULTICAST_ALL / bind0→NET_Bind / send0→NET_SendTo / receive0→NET_RecvFrom+超时 / peek→MSG_PEEK / connect0→NET_Connect / disconnect0→AF_UNSPEC+Linux端口恢复 / mcast_join_leave→IP_ADD_MEMBERSHIP+IPv4-mapped / setMulticastInterface(400行) / getMulticastInterface(200行) / socketSetOption0 / socketGetOption / setTimeToLive→IP_MULTICAST_TTL+IPV6_MULTICAST_HOPS |
| `AbstractPlainDatagramSocketImpl.java` | `share/classes/java/net/` | 438 | 抽象基类：timeout+connected+trafficClass / connectDisabled(macOS) / create→ResourceManager+SocketCleanable / connect/disconnect / receive(synchronized) / setOption/getOption 参数校验 / joinGroup/leaveGroup 委托 |
| `PlainDatagramSocketImpl.java` | `unix/classes/java/net/` | 146 | Unix 实现：所有 native 方法声明 / static { init(); } / ExtendedSocketOptions |
| `DatagramSocket.java` | `share/classes/java/net/` | 1407 | 上层 API：macOS connect 模拟 / SecurityManager 检查 / send/receive 委托 impl |
| `MulticastSocket.java` | `share/classes/java/net/` | 736 | 组播 API：joinGroup→impl.join / leaveGroup→impl.leave / setTimeToLive / setInterface→IP_MULTICAST_IF |
| `DatagramPacket.java` | `share/classes/java/net/` | 389 | 数据载体：buf/offset/length/address/port / 不可变 address 需要 receive 时判断是否复用 |
| `linux_close.c` | `linux/native/libnet/` | 451 | 被 send0/receive0 间接使用：NET_SendTo/NET_RecvFrom/NET_Timeout 都经过 BLOCKING_IO_RETURN_INT |
| `net_util_md.h` | `unix/native/libnet/` | — | 常量：MAX_BUFFER_LEN(64KB) / MAX_PACKET_LEN(65535) / NET_NSEC_PER_MSEC |
| `net_util_md.c` | `unix/native/libnet/` | — | 工具：NET_Bind / NET_MapSocketOption / NET_SetSockOpt / NET_GetSockOpt |
| `Net.c` | `unix/native/libnio/ch/` | — | NIO 组播对比：joinOrDrop4/6 / blockOrUnblock4/6 / setInterface4/6（比 BIO 更简洁的组播实现） |
