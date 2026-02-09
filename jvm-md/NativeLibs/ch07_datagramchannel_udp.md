# 第 7 章：DatagramChannel — UDP

> **源码基线**：OpenJDK 11 / Linux x86_64
> **核心源文件**：`DatagramChannelImpl.java` (1341行) + `DatagramChannelImpl.c` (240行) + `DatagramDispatcher.java` (78行) + `DatagramDispatcher.c` (120行)

---

## 1. 问题引入

TCP 是可靠的字节流协议，但很多场景不需要这么"重"的保障：
- **DNS 查询**：发一个小请求，收一个小响应，超时重发就行
- **视频/语音通话**：丢几帧无所谓，但延迟要低
- **游戏状态同步**：快速广播位置信息，旧数据丢了不影响
- **组播/广播**：一对多分发，TCP 做不到

UDP（User Datagram Protocol）是无连接、不可靠、基于数据报的协议。`DatagramChannel` 是 JDK NIO 对 UDP 的封装，提供非阻塞 + Selector 集成的 UDP I/O 能力。

**本章核心问题**：
1. `send()/receive()` 底层用的什么系统调用？和 TCP 的 `read()/write()` 有什么区别？
2. UDP 的 `connect()` 是什么意思？不是说 UDP 是"无连接"的吗？
3. 组播（multicast）怎么加入/离开组？底层用的什么 socket 选项？

---

## 2. 类总览

### 2.1 核心字段

```java
class DatagramChannelImpl extends DatagramChannel implements SelChImpl {
    private static NativeDispatcher nd = new DatagramDispatcher(); // I/O 调度器
    private final ProtocolFamily family;                 // INET 或 INET6
    private final FileDescriptor fd;
    private final int fdVal;

    // 发送者地址缓存（receive0 回填）
    private InetAddress cachedSenderInetAddress;
    private int cachedSenderPort;

    // 三锁模型（与 SocketChannel 相同）
    private final ReentrantLock readLock = new ReentrantLock();
    private final ReentrantLock writeLock = new ReentrantLock();
    private final Object stateLock = new Object();

    // 状态（5 态）
    private static final int ST_UNCONNECTED = 0;
    private static final int ST_CONNECTED = 1;
    private static final int ST_CLOSING = 2;
    private static final int ST_KILLPENDING = 3;
    private static final int ST_KILLED = 4;
    private int state;

    // 阻塞线程跟踪
    private long readerThread;
    private long writerThread;

    // 地址
    private InetSocketAddress localAddress;
    private InetSocketAddress remoteAddress;

    // 组播注册表
    private MembershipRegistry registry;
}
```

### 2.2 与 SocketChannel 的关键区别

| 特性 | DatagramChannel | SocketChannel |
|------|----------------|---------------|
| 协议 | UDP (SOCK_DGRAM) | TCP (SOCK_STREAM) |
| 连接 | 可选（`connect` 只是设过滤器） | 必须（三次握手） |
| 数据边界 | 保留（一个 send = 一个 receive） | 不保留（字节流） |
| 状态数 | 5 态（无 CONNECTIONPENDING） | 6 态（有 CONNECTIONPENDING） |
| I/O 方法 | `send()/receive()` + `read()/write()` | `read()/write()` 只 |
| 组播 | ✅ `join()/drop()` | ❌ |
| NativeDispatcher | `DatagramDispatcher`（recv/send/recvmsg/sendmsg） | `SocketDispatcher`→`FileDispatcherImpl`（read/write） |
| ECONNREFUSED | 可能收到（ICMP port unreachable） | 不会（TCP 层处理） |

### 2.3 状态机

```
ST_UNCONNECTED(0) ──connect()──→ ST_CONNECTED(1) ──disconnect()──→ ST_UNCONNECTED(0)
        │                              │
        └──close()──→ ST_CLOSING(2) ──→ ST_KILLPENDING(3) ──→ ST_KILLED(4)
                            ↑
                            └──close()─┘
```

**注意**：与 SocketChannel 不同，DatagramChannel 的状态**不是单调递增**的！`disconnect()` 可以从 ST_CONNECTED 回到 ST_UNCONNECTED。这是因为 UDP 的"连接"只是在内核设了个地址过滤器，随时可以取消。

---

## 3. 创建 — socket(AF_INET6, SOCK_DGRAM, 0)

```java
public DatagramChannelImpl(SelectorProvider sp) throws IOException {
    super(sp);
    ResourceManager.beforeUdpCreate();     // UDP fd 数量限制
    this.family = Net.isIPv6Available()
            ? StandardProtocolFamily.INET6
            : StandardProtocolFamily.INET;
    this.fd = Net.socket(family, false);   // false = 非流式 = SOCK_DGRAM
    this.fdVal = IOUtil.fdVal(fd);
}
```

与 SocketChannel 的区别在于 `Net.socket(family, false)`：
- `stream=true` → `socket(AF_INET6, SOCK_STREAM, 0)` — TCP
- `stream=false` → `socket(AF_INET6, SOCK_DGRAM, 0)` — UDP

**ResourceManager.beforeUdpCreate()**：JDK 对 UDP socket 数量有限制（`sun.net.maxDatagramSockets`，默认 25），防止大量 DatagramSocket 泄漏占用 fd。超过限制抛 SocketException。TCP 没有此限制。

---

## 4. receive — recvfrom 接收数据报

### 4.1 Java 层完整流程

```java
public SocketAddress receive(ByteBuffer dst) throws IOException {
    readLock.lock();
    try {
        boolean blocking = isBlocking();
        SocketAddress remote = beginRead(blocking, false); // false = 不要求已连接
        boolean connected = (remote != null);

        // 两条路径
        if (connected || (sm == null)) {
            // 已连接或无 SecurityManager：直接接收
            do {
                n = receive(fd, dst, connected);
            } while ((n == IOStatus.INTERRUPTED) && isOpen());
            if (n == IOStatus.UNAVAILABLE) return null; // 非阻塞无数据
        } else {
            // 未连接 + 有 SecurityManager：先收到临时 buffer，检查权限后再拷贝
            bb = Util.getTemporaryDirectBuffer(dst.remaining());
            for (;;) {
                n = receive(fd, bb, connected);
                // 检查 sm.checkAccept(sender) 权限
                // 不通过则忽略该数据报，继续接收
                bb.flip();
                dst.put(bb);
                break;
            }
        }
        return sender;  // sender 由 receive0 native 方法回填
    } finally {
        readLock.unlock();
    }
}
```

**关键设计**：`SecurityManager` 路径需要先接收数据报再检查发送者地址是否被允许。如果直接接收到用户 buffer 然后检查不通过，数据就泄漏了。所以先收到临时 buffer，检查通过后再拷贝到目标 buffer。

### 4.2 receive0 — JNI 层 recvfrom

```c
JNIEXPORT jint JNICALL
Java_sun_nio_ch_DatagramChannelImpl_receive0(JNIEnv *env, jobject this,
                                             jobject fdo, jlong address,
                                             jint len, jboolean connected) {
    jint fd = fdval(env, fdo);
    void *buf = (void *)jlong_to_ptr(address);
    SOCKETADDRESS sa;
    socklen_t sa_len = sizeof(SOCKETADDRESS);

    if (len > MAX_PACKET_LEN) len = MAX_PACKET_LEN;

    do {
        retry = JNI_FALSE;
        n = recvfrom(fd, buf, len, 0, &sa.sa, &sa_len);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return IOS_UNAVAILABLE;
            if (errno == EINTR) return IOS_INTERRUPTED;
            if (errno == ECONNREFUSED) {
                if (connected == JNI_FALSE) {
                    retry = JNI_TRUE;     // 未连接时忽略 ICMP 错误，继续接收
                } else {
                    throw PortUnreachableException;
                }
            }
        }
    } while (retry == JNI_TRUE);
```

**ECONNREFUSED 处理**：
- UDP 是无连接的，但如果你向一个没有监听的端口发送数据报，对方内核会回复 ICMP "port unreachable"
- 如果 socket 已 `connect()`（即 connected=true），内核会把这个 ICMP 错误通过下次 `recvfrom()` 返回 ECONNREFUSED → JDK 抛 `PortUnreachableException`
- 如果 socket 未连接（connected=false），这个错误可能是来自之前发给某个不存在端口的数据报的延迟回复，与当前接收无关 → **忽略并重试**

### 4.3 发送者地址缓存

receive0 在获取 recvfrom 的源地址后做了一个优化：

```c
// 检查缓存的发送者地址是否匹配
senderAddr = (*env)->GetObjectField(env, this, dci_senderAddrID);
if (senderAddr != NULL) {
    if (!NET_SockaddrEqualsInetAddress(env, &sa, senderAddr)) {
        senderAddr = NULL;  // 地址不匹配，需要创建新对象
    } else {
        jint port = (*env)->GetIntField(env, this, dci_senderPortID);
        if (port != NET_GetPortFromSockaddr(&sa)) {
            senderAddr = NULL;  // 端口不匹配
        }
    }
}
if (senderAddr == NULL) {
    // 创建新的 InetSocketAddress 对象
    jobject ia = NET_SockaddrToInetAddress(env, &sa, &port);
    jobject isa = (*env)->NewObject(env, isa_class, isa_ctorID, ia, port);
    // 更新缓存
    (*env)->SetObjectField(env, this, dci_senderAddrID, ia);
    (*env)->SetIntField(env, this, dci_senderPortID, port);
    (*env)->SetObjectField(env, this, dci_senderID, isa);
}
```

**优化思路**：如果连续收到同一个发送者的数据报（很常见，比如对端持续发送），就不需要每次都创建新的 `InetAddress` 和 `InetSocketAddress` 对象。通过比较 `cachedSenderInetAddress` 和 `cachedSenderPort`，命中缓存时直接复用之前的对象。这避免了大量短生命周期对象给 GC 带来的压力。

### 4.4 自动绑定

在 `beginRead()` 中：

```java
private SocketAddress beginRead(boolean blocking, boolean mustBeConnected) {
    synchronized (stateLock) {
        ensureOpen();
        if (localAddress == null)
            bindInternal(null);  // 自动绑定到 0.0.0.0:0（随机端口）
        if (blocking)
            readerThread = NativeThread.current();
    }
}
```

如果 receive/send 前没有手动 `bind()`，JDK 自动绑定到通配地址和随机端口。这与 TCP 不同 — TCP 的 `connect()` 由内核自动绑定，而 UDP 的 `send()/receive()` 需要 JDK 主动调用 `bind()`。

---

## 5. send — sendto 发送数据报

### 5.1 Java 层两条路径

```java
public int send(ByteBuffer src, SocketAddress target) throws IOException {
    writeLock.lock();
    try {
        SocketAddress remote = beginWrite(blocking, false);
        if (remote != null) {
            // 已连接：检查目标地址必须与连接地址一致
            if (!target.equals(remote))
                throw new AlreadyConnectedException();
            // 已连接模式：用 IOUtil.write → DatagramDispatcher.write0 → send()
            do {
                n = IOUtil.write(fd, src, -1, nd);
            } while ((n == IOStatus.INTERRUPTED) && isOpen());
        } else {
            // 未连接模式：用 send0 → sendto()
            do {
                n = send(fd, src, isa);
            } while ((n == IOStatus.INTERRUPTED) && isOpen());
        }
    }
}
```

**两条路径的区别**：
- **已连接**：直接用 `IOUtil.write()` → `DatagramDispatcher.write0()` → `send(fd, buf, len, 0)`。不需要指定目标地址，因为内核已经记住了
- **未连接**：用 `send0()` → `sendto(fd, buf, len, 0, &sa, sa_len)`。每次发送都要指定目标地址

### 5.2 send0 — JNI 层 sendto

```c
JNIEXPORT jint JNICALL
Java_sun_nio_ch_DatagramChannelImpl_send0(JNIEnv *env, jobject this,
                                          jboolean preferIPv6, jobject fdo,
                                          jlong address, jint len,
                                          jobject destAddress, jint destPort) {
    jint fd = fdval(env, fdo);
    void *buf = (void *)jlong_to_ptr(address);
    SOCKETADDRESS sa;
    int sa_len = 0;

    if (len > MAX_PACKET_LEN) len = MAX_PACKET_LEN;

    // Java InetAddress → C struct sockaddr
    NET_InetAddressToSockaddr(env, destAddress, destPort, &sa, &sa_len, preferIPv6);

    n = sendto(fd, buf, len, 0, &sa.sa, sa_len);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return IOS_UNAVAILABLE;
        if (errno == EINTR)        return IOS_INTERRUPTED;
        if (errno == ECONNREFUSED) throw PortUnreachableException;
    }
    return n;
}
```

**MAX_PACKET_LEN**：UDP 数据报最大 65507 字节（65535 - 8 字节 UDP 头 - 20 字节 IP 头）。JNI 层做了截断保护。

### 5.3 PortUnreachableException 在 send 中的处理

```java
private int sendFromNativeBuffer(FileDescriptor fd, ByteBuffer bb,
                                 InetSocketAddress target) {
    try {
        written = send0(preferIPv6, fd, address + pos, rem, target.getAddress(), target.getPort());
    } catch (PortUnreachableException pue) {
        if (isConnected())
            throw pue;       // 已连接：抛异常
        written = rem;       // 未连接：假装发送成功
    }
}
```

**为什么未连接时忽略 PortUnreachableException？** 因为对于未连接的 UDP socket，ECONNREFUSED 可能是之前某次 send 的延迟 ICMP 回复，与当前这次 send 无关。如果抛出异常会误导调用者。JDK 选择忽略并返回"发送成功"。

---

## 6. read/write — 已连接模式

`read()` 和 `write()` 只能在已连接（`connect()` 后）的 DatagramChannel 上使用。

### 6.1 read 调用链

```java
public int read(ByteBuffer buf) throws IOException {
    readLock.lock();
    try {
        beginRead(blocking, true);  // true = 必须已连接，否则 NotYetConnectedException
        do {
            n = IOUtil.read(fd, buf, -1, nd);  // nd = DatagramDispatcher
        } while ((n == IOStatus.INTERRUPTED) && isOpen());
    }
}
```

`IOUtil.read()` → `DatagramDispatcher.read()` → `read0()` → JNI:

```c
JNIEXPORT jint JNICALL
Java_sun_nio_ch_DatagramDispatcher_read0(JNIEnv *env, jclass clazz,
                         jobject fdo, jlong address, jint len) {
    jint fd = fdval(env, fdo);
    void *buf = (void *)jlong_to_ptr(address);
    int result = recv(fd, buf, len, 0);     // 用 recv 而不是 read！
    if (result < 0 && errno == ECONNREFUSED) {
        JNU_ThrowByName(env, "PortUnreachableException", 0);
        return -2;
    }
    return convertReturnVal(env, result, JNI_TRUE);
}
```

**关键区别**：`DatagramDispatcher.read0` 使用 `recv()` 而不是 `read()`。虽然对于已连接的 UDP socket 两者语义相同，但 `recv()` 在收到 ICMP port unreachable 时能返回 ECONNREFUSED，而 `read()` 在某些平台上不会。

### 6.2 write 调用链

```c
JNIEXPORT jint JNICALL
Java_sun_nio_ch_DatagramDispatcher_write0(JNIEnv *env, jclass clazz,
                              jobject fdo, jlong address, jint len) {
    jint fd = fdval(env, fdo);
    void *buf = (void *)jlong_to_ptr(address);
    int result = send(fd, buf, len, 0);    // 用 send 而不是 write！
    if (result < 0 && errno == ECONNREFUSED) {
        JNU_ThrowByName(env, "PortUnreachableException", 0);
        return -2;
    }
    return convertReturnVal(env, result, JNI_FALSE);
}
```

同样用 `send()` 而不是 `write()`，原因相同：更好的 ECONNREFUSED 错误传递。

### 6.3 readv/writev — Scatter/Gather UDP

```c
// readv0 — 用 recvmsg 实现散列读
JNIEXPORT jlong JNICALL
Java_sun_nio_ch_DatagramDispatcher_readv0(JNIEnv *env, jclass clazz,
                              jobject fdo, jlong address, jint len) {
    jint fd = fdval(env, fdo);
    struct iovec *iov = (struct iovec *)jlong_to_ptr(address);
    struct msghdr m;
    memset(&m, 0, sizeof(m));
    m.msg_iov = iov;
    m.msg_iovlen = len;
    result = recvmsg(fd, &m, 0);     // recvmsg 而不是 readv
}

// writev0 — 用 sendmsg 实现聚集写
JNIEXPORT jlong JNICALL
Java_sun_nio_ch_DatagramDispatcher_writev0(...) {
    struct msghdr m;
    memset(&m, 0, sizeof(m));
    m.msg_iov = iov;
    m.msg_iovlen = len;
    result = sendmsg(fd, &m, 0);     // sendmsg 而不是 writev
}
```

**为什么用 recvmsg/sendmsg 而不是 readv/writev？**
- `readv/writev` 是通用文件 I/O 调用，不处理 socket 特有的错误（如 ECONNREFUSED）
- `recvmsg/sendmsg` 是 socket 专用调用，能正确传递 ICMP 错误
- 还可以通过 `msghdr.msg_control` 传递辅助数据（如接收接口信息），虽然 JDK 这里没用

### 6.4 DatagramDispatcher vs FileDispatcherImpl 对比

| 方法 | DatagramDispatcher | FileDispatcherImpl | 原因 |
|------|-------------------|-------------------|------|
| read | `recv()` | `read()` | UDP 需要 ECONNREFUSED 检测 |
| write | `send()` | `write()` | 同上 |
| readv | `recvmsg()` | `readv()` | 同上 |
| writev | `sendmsg()` | `writev()` | 同上 |
| close | `FileDispatcherImpl.close0()` | `close0()` | 共享实现 |
| preClose | `FileDispatcherImpl.preClose0()` | `preClose0()` | 共享实现 |

---

## 7. connect/disconnect — UDP 的"连接"语义

### 7.1 connect — 设地址过滤器

UDP 的 `connect()` 不像 TCP 那样建立连接（没有三次握手）。它做的事情：
1. **内核记住目标地址**：后续 `send/write` 不需要再指定地址
2. **内核设置源过滤**：只接收来自该地址的数据报，其他来源的直接丢弃
3. **启用 ICMP 错误传递**：发送到不存在端口时，ECONNREFUSED 会传递给应用

```java
public DatagramChannel connect(SocketAddress sa) throws IOException {
    readLock.lock();
    try {
        writeLock.lock();
        try {
            synchronized (stateLock) {
                ensureOpen();
                if (state == ST_CONNECTED)
                    throw new AlreadyConnectedException();

                int n = Net.connect(family, fd, isa.getAddress(), isa.getPort());
                // UDP connect 总是同步完成（不会 EINPROGRESS）

                remoteAddress = isa;
                state = ST_CONNECTED;
                localAddress = Net.localAddress(fd);

                // ★ 关键：刷掉连接前收到的所有数据报
                boolean blocking = isBlocking();
                if (blocking)
                    IOUtil.configureBlocking(fd, false);
                try {
                    ByteBuffer buf = ByteBuffer.allocate(100);
                    while (receive(buf) != null) {
                        buf.clear();
                    }
                } finally {
                    if (blocking)
                        IOUtil.configureBlocking(fd, true);
                }
            }
        }
    }
}
```

**连接后刷数据的原因**：在 `connect()` 之前，socket 可能已经收到了来自其他地址的数据报（在接收缓冲区中等待）。`connect()` 设置过滤器后，这些旧数据报不应该被后续 `read()` 读取（它们来自非连接地址）。所以 JDK 在连接后临时切到非阻塞模式，用 `receive()` 读走所有缓存的数据报并丢弃。

### 7.2 disconnect — 移除过滤器

```java
public DatagramChannel disconnect() throws IOException {
    synchronized (stateLock) {
        if (!isOpen() || (state != ST_CONNECTED))
            return this;
        boolean isIPv6 = (family == StandardProtocolFamily.INET6);
        disconnect0(fd, isIPv6);
        remoteAddress = null;
        state = ST_UNCONNECTED;
        localAddress = Net.localAddress(fd);
    }
}
```

JNI 实现（Linux 路径）：

```c
JNIEXPORT void JNICALL
Java_sun_nio_ch_DatagramChannelImpl_disconnect0(JNIEnv *env, jobject this,
                                                jobject fdo, jboolean isIPv6) {
    jint fd = fdval(env, fdo);
    SOCKETADDRESS sa;
    memset(&sa, 0, sizeof(sa));

#if defined(__linux__)  // 非 BSD
    sa.sa.sa_family = AF_UNSPEC;  // 用 AF_UNSPEC 断开
#elif defined(_ALLBSD_SOURCE) && !defined(__APPLE__)
    sa.sa.sa_family = isIPv6 ? AF_INET6 : AF_INET;  // BSD 用原始协议族
#elif defined(__APPLE__)
    rv = disconnectx(fd, SAE_ASSOCID_ANY, SAE_CONNID_ANY); // macOS 专用 API
#endif

    socklen_t len = isIPv6 ? sizeof(struct sockaddr_in6) : sizeof(struct sockaddr_in);
    rv = connect(fd, &sa.sa, len);
}
```

**UDP disconnect 的跨平台差异**：
- **Linux**：`connect(fd, {AF_UNSPEC}, sizeof)` — 用 AF_UNSPEC 表示"取消连接"
- **BSD**：`connect(fd, {AF_INET6/AF_INET}, sizeof)` — 用原始协议族 + 零地址
- **macOS**：使用专用的 `disconnectx()` API
- **Solaris**：`connect(fd, 0, 0)` — 传空地址

这是典型的 POSIX 标准在各平台上实现不统一的例子。JDK 用 `#if defined(...)` 处理每个平台的差异。

---

## 8. 组播（Multicast）

### 8.1 概念

组播允许一个发送者向一组接收者同时发送数据。组播地址范围：
- **IPv4**：224.0.0.0 ~ 239.255.255.255
- **IPv6**：ff00::/8

### 8.2 join — 加入组播组

```java
public MembershipKey join(InetAddress group, NetworkInterface interf) {
    return innerJoin(group, interf, null);
}

private MembershipKey innerJoin(InetAddress group, NetworkInterface interf,
                                InetAddress source) {
    synchronized (stateLock) {
        // 检查 MembershipRegistry 避免重复加入
        if (registry == null) registry = new MembershipRegistry();
        MembershipKey key = registry.checkMembership(group, interf, source);
        if (key != null) return key;

        if (family == INET6 && (group instanceof Inet6Address || canJoin6WithIPv4Group())) {
            // IPv6 路径
            byte[] groupAddress = Net.inet6AsByteArray(group);
            byte[] sourceAddress = (source == null) ? null : Net.inet6AsByteArray(source);
            int n = Net.join6(fd, groupAddress, index, sourceAddress);
            key = new MembershipKeyImpl.Type6(...);
        } else {
            // IPv4 路径
            int groupAddress = Net.inet4AsInt(group);
            int targetAddress = Net.inet4AsInt(target);
            int n = Net.join4(fd, groupAddress, targetAddress, sourceAddress);
            key = new MembershipKeyImpl.Type4(...);
        }
        registry.add(key);
        return key;
    }
}
```

### 8.3 joinOrDrop4 — JNI 层 setsockopt

```c
JNIEXPORT jint JNICALL
Java_sun_nio_ch_Net_joinOrDrop4(JNIEnv *env, jobject this,
                                jboolean join, jobject fdo,
                                jint group, jint interf, jint source) {
    if (source == 0) {
        // 无源过滤 — 普通加入/离开
        struct ip_mreq mreq;
        mreq.imr_multiaddr.s_addr = htonl(group);
        mreq.imr_interface.s_addr = htonl(interf);
        opt = join ? IP_ADD_MEMBERSHIP : IP_DROP_MEMBERSHIP;
        optval = &mreq;
        optlen = sizeof(mreq);
    } else {
        // 有源过滤 — SSM (Source-Specific Multicast)
        struct ip_mreq_source mreq_source;
        mreq_source.imr_multiaddr.s_addr = htonl(group);
        mreq_source.imr_sourceaddr.s_addr = htonl(source);
        mreq_source.imr_interface.s_addr = htonl(interf);
        opt = join ? IP_ADD_SOURCE_MEMBERSHIP : IP_DROP_SOURCE_MEMBERSHIP;
        optval = &mreq_source;
        optlen = sizeof(mreq_source);
    }

    n = setsockopt(fdval(env,fdo), IPPROTO_IP, opt, optval, optlen);
}
```

**核心 socket 选项**：

| 操作 | socket option | 结构体 |
|------|--------------|--------|
| 加入组 | `IP_ADD_MEMBERSHIP` | `ip_mreq{multiaddr, interface}` |
| 离开组 | `IP_DROP_MEMBERSHIP` | `ip_mreq` |
| SSM 加入 | `IP_ADD_SOURCE_MEMBERSHIP` | `ip_mreq_source{multiaddr, sourceaddr, interface}` |
| SSM 离开 | `IP_DROP_SOURCE_MEMBERSHIP` | `ip_mreq_source` |
| 阻止源 | `IP_BLOCK_SOURCE` | `ip_mreq_source` |
| 解除阻止 | `IP_UNBLOCK_SOURCE` | `ip_mreq_source` |

### 8.4 SSM (Source-Specific Multicast)

普通组播（ASM）接收来自该组所有发送者的数据。SSM 允许只接收来自特定源的组播数据：

```java
// 只接收来自 sourceAddr 发到 groupAddr 的组播数据
MembershipKey key = channel.join(groupAddr, networkInterface, sourceAddr);
```

也可以先加入组，再阻止特定源：

```java
MembershipKey key = channel.join(groupAddr, networkInterface);
key.block(badSource);  // 阻止来自 badSource 的数据
```

### 8.5 MembershipRegistry

Java 层的 `MembershipRegistry` 维护了所有已加入的组播组信息，用于：
1. **避免重复加入**：`checkMembership()` 检查是否已经在同一组/接口/源上注册过
2. **Channel 关闭时批量清理**：`invalidateAll()` 在 `implCloseSelectableChannel()` 中调用

---

## 9. close — 关闭机制

```java
protected void implCloseSelectableChannel() throws IOException {
    synchronized (stateLock) {
        state = ST_CLOSING;
        // 失效所有组播 key
        if (registry != null) registry.invalidateAll();
    }

    if (blocking) {
        synchronized (stateLock) {
            long reader = readerThread;
            long writer = writerThread;
            if (reader != 0 || writer != 0) {
                nd.preClose(fd);                     // dup2(preCloseFD, fd)
                if (reader != 0) NativeThread.signal(reader);
                if (writer != 0) NativeThread.signal(writer);
                // 等待阻塞线程退出
                while (readerThread != 0 || writerThread != 0) {
                    stateLock.wait();
                }
            }
        }
    } else {
        // 非阻塞模式：获取读写锁确保没有进行中的操作
        readLock.lock();
        try { writeLock.lock(); writeLock.unlock(); }
        finally { readLock.unlock(); }
    }

    state = ST_KILLPENDING;
    if (!isRegistered()) kill();
}

public void kill() throws IOException {
    synchronized (stateLock) {
        if (state == ST_KILLPENDING) {
            state = ST_KILLED;
            nd.close(fd);
            ResourceManager.afterUdpClose();  // 递减 UDP 计数器
        }
    }
}
```

关闭流程与 SocketChannel 几乎一致：preClose + signal + wait 协议。唯一区别：
- 额外调用 `registry.invalidateAll()` 清理组播注册
- `kill()` 调用 `ResourceManager.afterUdpClose()` 释放 UDP fd 配额

---

## 10. Selector 事件翻译

### 10.1 translateInterestOps

```java
public int translateInterestOps(int ops) {
    int newOps = 0;
    if ((ops & SelectionKey.OP_READ) != 0)    newOps |= Net.POLLIN;
    if ((ops & SelectionKey.OP_WRITE) != 0)   newOps |= Net.POLLOUT;
    if ((ops & SelectionKey.OP_CONNECT) != 0) newOps |= Net.POLLIN;  // ★
    return newOps;
}
```

**注意**：`OP_CONNECT` 被映射到 `POLLIN` 而不是 `POLLOUT`！这与 SocketChannel 不同（SocketChannel 把 OP_CONNECT 映射到 POLLOUT/POLLCONN）。这是因为 UDP 的"连接"不是真连接，没有"连接就绪"事件。这个映射实际上不太有意义，DatagramChannel 通常不注册 OP_CONNECT。

### 10.2 translateReadyOps

```java
public boolean translateReadyOps(int ops, int initialOps, SelectionKeyImpl ski) {
    int intOps = ski.nioInterestOps();
    int newOps = initialOps;

    if ((ops & (Net.POLLERR | Net.POLLHUP)) != 0) {
        newOps = intOps;  // 错误/挂起时所有感兴趣的事件都就绪
        return (newOps & ~oldOps) != 0;
    }

    if (((ops & Net.POLLIN) != 0) && ((intOps & SelectionKey.OP_READ) != 0))
        newOps |= SelectionKey.OP_READ;

    if (((ops & Net.POLLOUT) != 0) && ((intOps & SelectionKey.OP_WRITE) != 0))
        newOps |= SelectionKey.OP_WRITE;

    return (newOps & ~oldOps) != 0;
}
```

比 SocketChannel 简单得多：没有 POLLCONN/OP_CONNECT 的特殊处理，纯粹的 POLLIN↔OP_READ、POLLOUT↔OP_WRITE 映射。

---

## 11. initIDs — JNI 字段缓存

```c
JNIEXPORT void JNICALL
Java_sun_nio_ch_DatagramChannelImpl_initIDs(JNIEnv *env, jclass clazz) {
    // 缓存 InetSocketAddress 类和构造器
    isa_class = (*env)->NewGlobalRef(env, FindClass("java/net/InetSocketAddress"));
    isa_ctorID = (*env)->GetMethodID(env, clazz, "<init>", "(Ljava/net/InetAddress;I)V");

    // 缓存 DatagramChannelImpl 的字段 ID
    dci_senderID     = GetFieldID("sender", "Ljava/net/SocketAddress;");
    dci_senderAddrID = GetFieldID("cachedSenderInetAddress", "Ljava/net/InetAddress;");
    dci_senderPortID = GetFieldID("cachedSenderPort", "I");
}
```

与 ServerSocketChannelImpl.initIDs 模式一致：类加载时调用一次，缓存 field ID 和 method ID。注意 `isa_class` 使用 `NewGlobalRef` 防止类被 GC 卸载。

---

## 12. 面试常见问题

### Q1: UDP 的 connect() 做了什么？不是说 UDP 是无连接的吗？

UDP 的 `connect()` 不建立连接（没有三次握手），只是在内核为 socket 设置了一个目标地址过滤器。效果：
1. `send/write` 不需要每次指定地址
2. 只接收来自该地址的数据报
3. 发送到不存在端口时能收到 ICMP 错误（ECONNREFUSED）
4. 可以通过 `disconnect()` 随时取消

### Q2: DatagramDispatcher 为什么用 recv/send 而不是 read/write？

为了正确处理 ECONNREFUSED 错误。UDP 在发送到不存在端口时，对端内核回复 ICMP port unreachable。`recv/send` 能把这个错误传递给应用（返回 ECONNREFUSED），而 `read/write` 在某些平台上不会。DatagramDispatcher 还用 `recvmsg/sendmsg` 替代 `readv/writev`，原因相同。

### Q3: receive() 中为什么有 SecurityManager 路径要用临时 buffer？

未连接 + 有 SecurityManager 时，需要先接收数据报再检查发送者地址是否被安全策略允许。如果直接接收到用户 buffer 然后安全检查不通过，数据就已经暴露给应用了。所以先收到 JDK 内部的临时 DirectBuffer，检查通过后再拷贝到用户 buffer。

### Q4: connect() 后为什么要刷掉缓冲区中的数据报？

`connect()` 前 socket 可能已经收到来自各个地址的数据报。虽然 `connect()` 后内核会过滤新到达的数据报，但已经在接收缓冲区中的旧数据报不会被移除。JDK 通过临时切到非阻塞模式 `receive()` 循环读取来清空缓冲区。

### Q5: IPv4 组播的核心 socket 选项是什么？

`setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq))` 加入组播组，其中 `mreq.imr_multiaddr` 是组播地址，`mreq.imr_interface` 是网卡地址。离开用 `IP_DROP_MEMBERSHIP`。SSM（Source-Specific Multicast）用 `IP_ADD_SOURCE_MEMBERSHIP` 额外指定源地址。

---

## 13. 源码文件交叉引用

| 文件 | 路径 | 行数 | 角色 |
|------|------|------|------|
| `DatagramChannelImpl.java` | `share/classes/sun/nio/ch/` | 1341 | 核心实现：receive/send/read/write/connect/disconnect/join/drop |
| `DatagramChannelImpl.c` | `unix/native/libnio/ch/` | 240 | JNI：receive0→recvfrom / send0→sendto / disconnect0 / initIDs |
| `DatagramDispatcher.java` | `unix/classes/sun/nio/ch/` | 78 | NativeDispatcher：read→recv / write→send / readv→recvmsg / writev→sendmsg |
| `DatagramDispatcher.c` | `unix/native/libnio/ch/` | 120 | JNI：read0→recv / write0→send / readv0→recvmsg / writev0→sendmsg + ECONNREFUSED |
| `Net.java` | `share/classes/sun/nio/ch/` | 682 | 组播API：join4/join6/drop4/drop6/block4/block6/unblock4/unblock6 |
| `Net.c` | `unix/native/libnio/ch/` | 815 | 组播JNI：joinOrDrop4→setsockopt(IP_ADD_MEMBERSHIP) / joinOrDrop6→setsockopt(IPV6_ADD_MEMBERSHIP) |
| `MembershipRegistry.java` | `share/classes/sun/nio/ch/` | — | 组播注册表：checkMembership/add/remove/invalidateAll |
| `MembershipKeyImpl.java` | `share/classes/sun/nio/ch/` | — | 组播键：Type4(IPv4)/Type6(IPv6)，持有组播参数 |
| `IOUtil.java` | `share/classes/sun/nio/ch/` | 449 | read/write 共用逻辑（已连接模式） |
| `FileDispatcherImpl.c` | `unix/native/libnio/ch/` | 374 | close0/preClose0 共享实现 |
