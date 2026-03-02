# 第 13 章：面试专题 — JDK Native I/O 深度问答

> 本章汇聚跨章节综合题、场景设计题、系统调用对比题、生产故障排查题。
> 各章节末尾已有 57 道基础面试题，本章**不重复**，只出**升级版**。

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文是 **第 13 章：面试专题 — JDK Native I/O 深度问答** 的面试准备材料：提炼核心知识点，给出标准答案框架，帮助在面试中清晰、准确地表达 JVM 内部原理。

### 0.2 为什么需要？

面试中的 JVM 问题往往需要在 2-3 分钟内讲清楚复杂机制。没有提前整理，很容易在细节上迷失，无法展示对整体的把握。

### 0.3 怎么解决？

按「本质→为什么→怎么实现→关键细节」的结构组织答案，确保回答既有深度又有条理。

### 0.4 为什么这样设计？

面试答案的设计原则：先给结论，再给理由；先讲整体，再讲细节；用类比帮助面试官理解复杂概念。

---


## 一、NIO 体系综合题（跨 Ch01-Ch07）

### Q1: 从 `channel.write(buffer)` 到数据到达对端网卡，中间经历了哪些步骤？请从 Java 层一直追到内核。

**答**：

```
1. Java 层
   channel.write(ByteBuffer buf)
     → SocketChannelImpl.write(buf)
       → IOUtil.write(fd, buf, ...)
         ├─ buf 是 DirectBuffer → 直接拿 address
         └─ buf 是 HeapBuffer → 从 ThreadLocal 获取临时 DirectBuffer → memcpy 数据
       → SocketDispatcher.write(fd, address, len)
         → FileDispatcherImpl.write0(fd, address, len)  [native]

2. JNI → C
   Java_sun_nio_ch_FileDispatcherImpl_write0()
     → RESTARTABLE(write(fd, buf, len), n)  [POSIX write 系统调用]

3. 内核态
   write(fd, buf, len)
     → sys_write → vfs_write → sock_write_iter
       → tcp_sendmsg()
         → 将数据拷贝到 socket 发送缓冲区 (sk_buff 链表)
         → 如果 Nagle 算法允许或缓冲区满 → tcp_write_xmit()
           → tcp_transmit_skb() → 构造 TCP 段 (添加 TCP/IP 头)
             → ip_queue_xmit() → 路由查找 → IP 头填充
               → dev_queue_xmit() → 网卡驱动 → DMA 到网卡 → 发送
```

**关键细节**：
- HeapBuffer 必须先拷贝到 DirectBuffer（GC 可能移动 byte[]）
- `write` 系统调用只是拷贝到 socket 发送缓冲区，**不等数据真正发出**
- 发送缓冲区满时 `write` 会阻塞（阻塞模式）或返回 0（非阻塞模式）
- Nagle 算法可能延迟发送小包（`TCP_NODELAY` 关闭 Nagle）

---

### Q2: NIO 中为什么需要 DirectByteBuffer？HeapByteBuffer 不行吗？从 native 代码角度解释。

**答**：

核心原因是 **GC 可能在 JNI 调用期间移动堆对象**。

```c
// 如果直接传 HeapBuffer 的 byte[] 地址给系统调用:
jbyte* data = (*env)->GetByteArrayElements(env, array, NULL);
// ↑ 这会 pin 数组（阻止 GC 移动），但:
//   1. G1 GC 下 pin 可能导致整个 Region 无法回收
//   2. 如果用 GetPrimitiveArrayCritical，会阻止所有 GC 直到 Release
//   3. 大缓冲区的 pin 成本高
```

JDK 的实际做法（`IOUtil.java`）：
```java
// 非 DirectBuffer 时的流程:
static int write(FileDescriptor fd, ByteBuffer src, ...) {
    if (src instanceof DirectBuffer) {
        return writeFromNativeBuffer(fd, src, ...);  // 直接用
    }
    // HeapBuffer → 从 ThreadLocal 池获取临时 DirectBuffer
    ByteBuffer bb = Util.getTemporaryDirectBuffer(rem);
    bb.put(src);         // 用户数据 → DirectBuffer (一次 memcpy)
    bb.flip();
    int n = writeFromNativeBuffer(fd, bb, ...);  // 再传给 native
    Util.offerFirstTemporaryDirectBuffer(bb);    // 归还池
}
```

**总结**：DirectBuffer 在 native heap 上（不受 GC 管理），地址稳定，可以安全传给系统调用。HeapBuffer 要先拷贝一次。所以高吞吐场景应直接使用 DirectBuffer 减少一次拷贝。

---

### Q3: epoll 的 ET（边缘触发）和 LT（水平触发）在 JDK 和 Netty 中分别怎么选？为什么？

**答**：

| 框架 | 模式 | 原因 |
|------|------|------|
| **JDK NIO** | LT | 安全：即使用户忘记读完数据，下次 select 还会通知。JDK API 设计面向普通开发者，容错优先 |
| **Netty (Linux)** | ET | 性能：每个事件只通知一次，减少 epoll_wait 返回次数。Netty 保证一次读完（循环读到 EAGAIN） |
| **Netty (macOS)** | kqueue (类 ET) | kqueue 原生更接近 ET 语义 |

**ET 模式的陷阱**（Netty 如何解决）：
```
问题: ET 模式下如果没读完数据, 内核不会再通知
解决: Netty 的 read 循环会一直读到:
  1. 返回 0 (没数据了)
  2. 读了 maxMessagesPerRead 次 (防饥饿)
  3. 分配的 buffer 没读满 (说明数据不多了)
```

**额外加分点**：Netty 4.1 在 Linux 上使用 `EPOLLONESHOT`，每次事件后自动禁用该 fd 的事件通知，处理完后手动 `epoll_ctl(MOD)` 重新启用——避免多线程并发处理同一 fd 的竞态。

---

### Q4: `transferTo` 零拷贝为什么比普通 read+write 快？请画出数据拷贝路径对比。

**答**：

```
【普通 read+write — 4 次拷贝, 4 次上下文切换】

  磁盘 → (DMA) → 内核 PageCache → (CPU) → 用户空间 buffer    [read: 2次拷贝]
  用户空间 buffer → (CPU) → Socket 发送缓冲区 → (DMA) → 网卡  [write: 2次拷贝]

  用户态   ←→ 内核态 ←→ 用户态 ←→ 内核态   = 4 次上下文切换

【sendfile 零拷贝 — 2 次拷贝, 2 次上下文切换】

  磁盘 → (DMA) → 内核 PageCache
                       ↓ (CPU 拷贝, 或 DMA gather 时可省略)
                  Socket 发送缓冲区 → (DMA) → 网卡

  用户态 → 内核态 → 用户态   = 2 次上下文切换
  数据始终在内核态, 不经过用户空间

【sendfile + DMA Scatter/Gather — 几乎 0 CPU 拷贝】

  磁盘 → (DMA) → 内核 PageCache
                       ↓ (只拷贝描述符: 地址+长度, 非数据)
                  Socket 发送缓冲区 (仅存描述符)
                       ↓ (DMA Scatter/Gather 直接从 PageCache 读)
                  网卡
```

JDK 的 `FileChannel.transferTo()` 三级降级：
```
1. sendfile64()            ← 大多数情况走这个
2. mmap + write            ← sendfile 失败时降级
3. read + write (8KB buf)  ← 都不行时走 UnixCopyFile.transfer()
```

---

### Q5: 一个基于 NIO 的服务器，在生产环境中 CPU 占用 100%。可能的原因和排查方法？

**答**：

**最经典的原因——Selector 空轮询 Bug（JDK-6670302）**：

```java
// 现象: select(timeout) 立即返回 0, 但没有任何就绪事件
// 原因: Linux epoll 在某些场景下 (如连接被 RST) 会报告 POLLHUP/POLLERR
//       但 JDK 没有正确处理, 导致 selectedKeys 为空但 select 不阻塞
while (true) {
    int n = selector.select(1000);  // 应该阻塞 1 秒, 实际立即返回 0
    if (n == 0) continue;           // 死循环, CPU 100%
}
```

**Netty 的解决方案**：
```java
// Netty 的 NioEventLoop.select() 中:
long currentTimeNanos = System.nanoTime();
if (selectCnt >= SELECTOR_AUTO_REBUILD_THRESHOLD) {  // 默认 512
    // 短时间内空轮询超过阈值 → 重建 Selector
    rebuildSelector();  // 创建新 Selector, 迁移所有 Channel
}
```

**其他可能原因**：
1. **忘记移除 selectedKeys**：处理完事件后没调用 `iterator.remove()`，下次循环重复处理
2. **OP_WRITE 一直就绪**：socket 发送缓冲区有空间时 OP_WRITE 持续就绪，应只在 write 返回 0 时注册 OP_WRITE
3. **DNS 解析阻塞**：`getaddrinfo()` 在 NIO 线程中调用导致其他 Channel 饥饿（不是 CPU 100%，但表现类似）

**排查方法**：
```bash
# 1. 找到 CPU 100% 的线程
top -H -p <pid>

# 2. jstack 看线程在做什么
jstack <pid> | grep -A 20 "nid=0x<hex_tid>"
# 如果在 sun.nio.ch.EPollSelectorImpl.doSelect → 空轮询

# 3. strace 看系统调用
strace -p <tid> -e trace=epoll_wait
# 如果 epoll_wait 立即返回 0 → 确认空轮询
```

---

## 二、BIO vs NIO 对比题（跨 Ch04/Ch05/Ch08）

### Q6: BIO 和 NIO 在 close 一个有线程阻塞读的 socket 时，处理方式有什么本质区别？

**答**：

**BIO（Ch08）— linux_close.c 的三步协议**：
```
Thread A: socketRead0() → recv() 阻塞中...
Thread B: close(socket)

1. preClose: dup2(marker_fd, socket_fd)
   → socket_fd 现在指向 marker_fd (一个 shutdown 的 socketpair)
   → Thread A 的 recv 在下次检查时会返回 EOF/错误

2. signal: pthread_kill(Thread_A, SIGRTMAX-2)
   → 信号中断 Thread A 的 recv → 返回 EINTR
   → BLOCKING_IO_RETURN_INT 宏检测到 fd 已被关闭 → 不重试, 返回 -1

3. 等待引用计数归零后真正 close(marker_fd 对应的原 fd)
```

**NIO（Ch04）— SocketChannelImpl 的三步协议**：
```
Thread A: IOUtil.read() → read() 阻塞中...
Thread B: channel.close()

1. preClose: nd.preClose(fd)
   → dup2(devnull, fd) → fd 指向 /dev/null
   → Thread A 的 read 在 /dev/null 上返回 0 (EOF)

2. signal: NativeThread.signal(thread)
   → pthread_kill(Thread_A, SIGINT/...) 
   → 中断 read → 返回 EINTR

3. 等待 reader/writer 计数归零后: nd.close(fd) 真正关闭
```

**核心区别**：
| 对比 | BIO | NIO |
|------|-----|-----|
| marker fd | shutdown 的 socketpair（`recv` 返回错误） | `/dev/null`（`read` 返回 0 EOF） |
| 跟踪在飞线程 | `fdEntry_t` 中的线程链表 | `readerThread`/`writerThread` volatile 字段 |
| 引用计数 | `fdUseCount` 原子计数 | `stateLock + state` 状态机 |
| 信号 | `SIGRTMAX-2`（专用信号） | `SIGINT` 或平台信号 |

---

### Q7: 为什么 Java 的 BIO Socket 超时不用 `setsockopt(SO_RCVTIMEO)`？

**答**：

JDK 源码中 `socketRead0` 的超时实现（Ch08）：
```c
// 有超时时:
NET_ReadWithTimeout(env, fd, buf, len, timeout)
  → poll(fd, POLLIN, timeout)     // 第一步: 等待数据到达
  → recv(fd, buf, len, MSG_DONTWAIT)  // 第二步: 非阻塞读

// 无超时时:
NET_Read(fd, buf, len)
  → recv(fd, buf, len, 0)  // 直接阻塞读
```

**不用 `SO_RCVTIMEO` 的原因**：

1. **可移植性**：`SO_RCVTIMEO` 行为在不同内核版本和平台上有差异——有的返回 `EAGAIN`，有的返回 `EWOULDBLOCK`，有的返回 `EINTR`

2. **精度问题**：`SO_RCVTIMEO` 的粒度取决于内核定时器精度（通常 1ms-10ms），而 `poll` 超时精度可达 1ms

3. **可中断性**：`poll` + `MSG_DONTWAIT` 的两步法允许在 `poll` 阶段被信号中断（配合 `linux_close.c` 的 close 协议），`SO_RCVTIMEO` 的 `recv` 阻塞时无法被安全中断

4. **connect 超时**：BIO 的 connect 超时用的也是同样模式（临时非阻塞 + `poll`），统一了超时实现

---

### Q8: 用 Java NIO 写一个 echo 服务器，有哪些常见的坑？

**答（含源码级解释）**：

```java
// 常见错误代码 + 修正
Selector selector = Selector.open();
ServerSocketChannel ssc = ServerSocketChannel.open();
ssc.configureBlocking(false);
ssc.bind(new InetSocketAddress(8080));
ssc.register(selector, SelectionKey.OP_ACCEPT);

while (true) {
    selector.select();  // ❌ 坑1: 空轮询时应 rebuild selector
    
    Iterator<SelectionKey> it = selector.selectedKeys().iterator();
    while (it.hasNext()) {
        SelectionKey key = it.next();
        it.remove();  // ❌ 坑2: 忘记 remove → 重复处理
        
        if (key.isAcceptable()) {
            SocketChannel sc = ssc.accept();
            sc.configureBlocking(false);
            sc.register(selector, SelectionKey.OP_READ);
        }
        
        if (key.isReadable()) {
            SocketChannel sc = (SocketChannel) key.channel();
            ByteBuffer buf = ByteBuffer.allocate(1024);  // ❌ 坑3: 每次新建 buffer
            int n = sc.read(buf);
            if (n == -1) {
                key.cancel();
                sc.close();  // ❌ 坑4: close 前应 cancel
                continue;
            }
            buf.flip();
            sc.write(buf);  // ❌ 坑5: write 可能没写完 (非阻塞模式)
            // 正确做法: 检查 buf.hasRemaining(), 剩余数据注册 OP_WRITE
        }
        
        if (key.isWritable()) {
            // ❌ 坑6: 写完后忘记取消 OP_WRITE → CPU 空转
            // 写完应: key.interestOps(key.interestOps() & ~SelectionKey.OP_WRITE)
        }
    }
}
```

**坑的源码级解释**：

| 坑 | 原因（源码层面） |
|----|-----------------|
| 空轮询 | `EPollSelectorImpl.doSelect` → `epoll_wait` 返回 0 但 `selectedKeys` 为空 |
| 忘 remove | `selectedKeys` 是 `HashSet`，`processEvents` 只添加不删除 |
| 每次 allocate | `ByteBuffer.allocate` → `new byte[]` → GC 压力。应复用或用 DirectBuffer 池 |
| write 不完整 | 非阻塞 `write` 可能只写了部分（socket 发送缓冲区满），返回值 < buf.remaining() |
| OP_WRITE 空转 | socket 发送缓冲区有空间时 `EPOLLOUT` 一直就绪 → `select` 立即返回 → CPU 100% |

---

## 三、系统调用深度题

### Q9: `stat`、`lstat`、`fstat`、`fstatat` 四个系统调用有什么区别？Java 中分别在什么场景下使用？

**答**：

| 系统调用 | 参数 | 符号链接 | TOCTOU 安全 | Java 使用场景 |
|---------|------|---------|------------|-------------|
| `stat(path, buf)` | 路径 | **跟随** | 不安全 | `Files.readAttributes(path)` 默认 |
| `lstat(path, buf)` | 路径 | **不跟随** | 不安全 | `Files.readAttributes(path, NOFOLLOW_LINKS)` |
| `fstat(fd, buf)` | fd | N/A | **安全** | 已打开文件的属性查询 |
| `fstatat(dfd, path, buf, flag)` | 目录fd+相对路径 | flag 控制 | **安全** | `SecureDirectoryStream` 中的安全遍历 |

**TOCTOU 问题**（为什么需要 `*at` 系列）：
```
// 不安全:
stat("/tmp/mydir/file.txt", &buf);  // 检查
open("/tmp/mydir/file.txt", O_RDONLY);  // 使用
// ↑ 两步之间 /tmp/mydir 可能被替换为符号链接 → 打开了错误文件

// 安全:
int dfd = open("/tmp/mydir", O_RDONLY);
fstatat(dfd, "file.txt", &buf, 0);  // 基于目录 fd 操作
openat(dfd, "file.txt", O_RDONLY);   // 同一个目录 fd, 原子性
```

**JDK 的 init() 中通过 `dlsym` 探测 `*at` 系列函数可用性**——如果全部可用才报告 `SUPPORTS_OPENAT`，`SecureDirectoryStream` 才能工作。

---

### Q10: `read` 系统调用为什么需要 `RESTARTABLE` 宏重试 EINTR，而 `readdir` 不需要？

**答**：

**POSIX 规定**：只有"慢"系统调用（可能无限期阻塞的）在被信号中断时才返回 `EINTR`。

```
需要 RESTARTABLE（可能阻塞，有 EINTR 风险）:
  read, write, open, close(AIX), stat, lstat, fstat,
  chmod, chown, access, link, dup, fopen,
  getpwuid_r, getgrgid_r, getpwnam_r, getgrnam_r

不需要 RESTARTABLE（源码注释: "EINTR not listed as a possible error"):
  opendir, closedir, readlink, mkdir, rmdir,
  unlink, rename, symlink, getcwd, realpath, mknod

特殊: readdir 也不需要
  readdir 只读内核缓存的目录项, 不涉及磁盘 I/O, 速度极快
  POSIX 没有为 readdir 定义 EINTR 行为
```

**JDK 源码中的体现**：
```c
// 需要重试的:
RESTARTABLE(stat64(path, &buf), err);        // 第 550 行
RESTARTABLE(read((int)fd, bufp, nbytes), n); // 第 491 行

// 不需要的 (直接调用, 无 RESTARTABLE):
dir = opendir(path);                         // 第 740 行
if (mkdir(path, mode) == -1) ...             // 第 802 行
if (unlink(path) == -1) ...                  // 第 841 行
```

---

### Q11: 为什么 `ioctl(SIOCGIFCONF)` 要调用两次？第一次传 `buf=NULL` 是什么意思？

**答**（来自 Ch11 `NetworkInterface.c`）：

```c
// 第一次: buf=NULL → 内核返回所需缓冲区大小
ifc.ifc_buf = NULL;
ioctl(sock, SIOCGIFCONF, &ifc);
// 返回后 ifc.ifc_len = 所有接口记录的总大小 (如 320 bytes)

// 分配缓冲区
buf = malloc(ifc.ifc_len);

// 第二次: 传入缓冲区 → 内核填充实际数据
ifc.ifc_buf = buf;
ioctl(sock, SIOCGIFCONF, &ifc);
// 返回后 buf 中包含 ifc.ifc_len / sizeof(ifreq) 个接口记录
```

**为什么不能一次搞定？**

1. **接口数量动态变化**：系统可能有 2 个或 200 个接口，事先不知道需要多大缓冲区
2. **`SIOCGIFCOUNT` 不可靠**：某些内核版本/平台不支持该 ioctl（JDK 源码注释: "SIOCGIFCOUNT doesn't work"）
3. **竞态条件**：两次调用之间可能新增接口，但实际中接口变化频率极低，不处理

**替代方案**（BSD）：`getifaddrs()` 一次调用返回所有接口信息（链表），不需要预分配缓冲区——更优雅的 API。

---

## 四、生产故障排查题

### Q12: 线上 Java 服务 DNS 解析偶发超时 20 秒，怎么排查？

**答**：

**根因分析**（基于 Ch10 源码）：

```
getaddrinfo() 是阻塞的, 没有超时参数!
超时完全由 /etc/resolv.conf 控制:
  options timeout:5 attempts:2
  nameserver 10.0.0.1
  nameserver 10.0.0.2

最坏情况: 5s × 2 attempts × 2 nameservers = 20s 阻塞
如果第一个 nameserver 不可达, 每次解析都要等第一个超时
```

**排查步骤**：
```bash
# 1. 确认 DNS 配置
cat /etc/resolv.conf
# 检查 nameserver 顺序, timeout/attempts 设置

# 2. 测试 DNS 延迟
time dig @10.0.0.1 www.example.com  # 测第一个 nameserver
time dig @10.0.0.2 www.example.com  # 测第二个

# 3. strace 确认是 getaddrinfo 阻塞
strace -p <tid> -e trace=network -T
# 看 connect (到 53 端口) 和 poll 的耗时

# 4. 检查 Java DNS 缓存配置
# 无 SecurityManager 时默认 30s TTL
# -Dsun.net.inetaddr.ttl=60  # 可调大减少解析频率
```

**解决方案**：
1. **调整 resolv.conf**：`options timeout:2 attempts:1 rotate`（rotate 轮询 nameserver）
2. **使用异步 DNS 库**：Netty 的 `DnsNameResolver`（基于 UDP，自己实现超时）
3. **本地 DNS 缓存**：部署 `nscd` 或 `dnsmasq` 做本地缓存
4. **调大 Java 缓存 TTL**：`-Dsun.net.inetaddr.ttl=300`
5. **配置 hosts 文件**：核心服务域名写入 `/etc/hosts`，完全绕过 DNS

---

### Q13: 微服务注册时 `InetAddress.getLocalHost()` 返回了 `127.0.0.1`，导致服务不可达。原因和修复？

**答**：

**原因链**（基于 Ch10 + Ch11 源码）：

```
InetAddress.getLocalHost()
  → impl.getLocalHostName()  [native: gethostname()]
    → 返回 hostname, 如 "my-server"
  → getByName("my-server")
    → getaddrinfo("my-server", ...)
      → 先查 /etc/hosts, 再查 DNS

/etc/hosts 内容:
  127.0.0.1   localhost
  127.0.0.1   my-server    ← 问题在这里！hostname 映射到了 127.0.0.1
```

**在 Docker/K8s 中更常见**：容器的 `/etc/hosts` 自动生成，可能把 hostname 映射到 `127.0.0.1`。

**修复方案**（3 种，可靠性递增）：

```java
// 方案 1: 修复 /etc/hosts
// 127.0.0.1   localhost
// 10.0.0.5    my-server    ← 改为真实 IP

// 方案 2: NetworkInterface 遍历 (最可靠)
public static String getLocalIp() {
    Enumeration<NetworkInterface> interfaces = NetworkInterface.getNetworkInterfaces();
    while (interfaces.hasMoreElements()) {
        NetworkInterface ni = interfaces.nextElement();
        if (ni.isLoopback() || !ni.isUp()) continue;
        Enumeration<InetAddress> addrs = ni.getInetAddresses();
        while (addrs.hasMoreElements()) {
            InetAddress addr = addrs.nextElement();
            if (!addr.isLoopbackAddress() && addr instanceof Inet4Address) {
                return addr.getHostAddress();
            }
        }
    }
    return "127.0.0.1";
}

// 方案 3: UDP connect 技巧 (利用内核路由选择)
DatagramSocket socket = new DatagramSocket();
socket.connect(InetAddress.getByName("8.8.8.8"), 10002);
String ip = socket.getLocalAddress().getHostAddress();  // 内核选择出口 IP
socket.close();
```

**底层原理**：方案 3 利用了 UDP `connect` 不真正发包的特性（Ch07 分析过），内核在 `connect` 时查路由表选择出口网卡并绑定本地地址。

---

### Q14: `Files.walk()` 遍历 100 万文件的目录时 OOM，为什么？怎么优化？

**答**：

**原因**（基于 Ch12 源码）：

`Files.walk()` 返回 `Stream<Path>`，底层是 `FileTreeWalker` 递归调用 `opendir/readdir/closedir`。OOM 不是因为 readdir，而是因为：

1. **`Path` 对象积累**：每个文件创建一个 `UnixPath` 对象（包含 byte[] 路径），100 万个 = 几十 MB
2. **DirectoryStream 未关闭**：`FileTreeWalker` 对每个子目录持有 `DirectoryStream`（= 一个 `DIR*`），深层递归时同时打开大量目录流
3. **用户代码收集到 List**：`Files.walk(dir).collect(Collectors.toList())` → 一次性在内存中持有所有 Path

**优化方案**：
```java
// ❌ 错误: 全部收集到内存
List<Path> all = Files.walk(dir).collect(Collectors.toList());

// ✅ 正确: 流式处理, 不积累
try (Stream<Path> stream = Files.walk(dir)) {
    stream.filter(p -> p.toString().endsWith(".log"))
          .forEach(this::processFile);  // 逐个处理, 不收集
}

// ✅ 更好: 限制深度
Files.walk(dir, 2)  // maxDepth=2, 减少遍历量

// ✅ 最佳: 对超大目录用 Files.newDirectoryStream (非递归)
try (DirectoryStream<Path> ds = Files.newDirectoryStream(dir, "*.log")) {
    for (Path p : ds) { processFile(p); }
}
// 底层: 每次 readdir 只返回一个文件名, 内存恒定
```

**文件描述符限制**：深层递归时每个打开的 `DirectoryStream` = 1 个 fd。默认 `ulimit -n 1024`，超过 1024 层递归（极端情况）会报 `EMFILE`。

---

### Q15: K8s Pod 中 `NetworkInterface.getNetworkInterfaces()` 返回了大量 `veth` 接口导致服务启动慢，怎么处理？

**答**：

**原因**（基于 Ch11 源码）：

在 K8s 宿主机上（非容器内），如果 Java 进程运行在 hostNetwork 模式，或者 DaemonSet 挂载了宿主机 /proc，会看到所有容器的 veth 对。几百个容器 = 几百个 veth 接口。

```
enumInterfaces()
  → ioctl(SIOCGIFCONF) → 返回 500+ 个 ifreq 记录
  → 每个接口 3 次额外 ioctl (flags/broadcast/netmask) = 1500+ 次 ioctl
  → 读 /proc/net/if_inet6 → 500+ 行解析
总耗时可达几十毫秒
```

**解决方案**：

```java
// 1. 缓存 NetworkInterface 结果
private static volatile NetworkInterface cachedNi;
private static volatile long cacheTime;
private static final long CACHE_TTL_MS = 60_000;

public static NetworkInterface getMainInterface() {
    if (cachedNi == null || System.currentTimeMillis() - cacheTime > CACHE_TTL_MS) {
        synchronized (MyClass.class) {
            // 双重检查
            cachedNi = findMainInterface();
            cacheTime = System.currentTimeMillis();
        }
    }
    return cachedNi;
}

// 2. 尽早过滤, 不遍历所有接口
private static NetworkInterface findMainInterface() {
    // 优先按已知名称查找
    for (String name : Arrays.asList("eth0", "ens33", "bond0")) {
        NetworkInterface ni = NetworkInterface.getByName(name);
        if (ni != null && ni.isUp() && !ni.isLoopback()) return ni;
    }
    // 降级: 遍历全部
    // ...
}

// 3. 用 UDP connect 技巧获取出口 IP, 完全绕过 NetworkInterface 枚举
```

---

## 五、设计思想题

### Q16: JDK 中有哪些"用信号中断阻塞系统调用"的模式？它们的共同设计是什么？

**答**：

JDK 中至少有三处使用此模式：

| 场景 | 阻塞调用 | 中断信号 | 文件 |
|------|---------|---------|------|
| BIO Socket close | `recv()` 阻塞 | `SIGRTMAX-2` | `linux_close.c` |
| NIO Channel close | `read()` 阻塞 | `NativeThread.signal()` | `SocketChannelImpl.java` |
| Thread.interrupt | `poll/select/sleep` | `pthread_kill` | `os_linux.cpp` |

**共同设计模式**：
```
1. 注册阶段: 阻塞前记录"我在哪个调用上阻塞" (线程 ID/链表)
2. 阻塞阶段: 进入系统调用 (recv/read/poll)
3. 中断阶段: 另一个线程发信号 → 内核中断阻塞 → 返回 EINTR
4. 检查阶段: 返回后检查"是被正常唤醒还是被中断" → 决定重试或退出
5. 清理阶段: 注销"我在阻塞"的记录
```

这是 POSIX 系统上**唯一可靠的**打断阻塞线程的方法。Java 的 `Thread.interrupt()` 在 native 层也是通过 `pthread_kill` + 信号实现的。

---

### Q17: 为什么 JDK 的 native I/O 代码大量使用 `dlsym` 而不是直接链接函数？

**答**：

整个系列中使用 `dlsym` 的场景：

| 文件 | dlsym 查找的函数 | 原因 |
|------|-----------------|------|
| `UnixNativeDispatcher.c` | `openat64`, `fstatat64`, `unlinkat`, `renameat`, `futimesat`, `fdopendir` | POSIX 2008 的 *at 系列，旧内核可能没有 |
| `LinuxNativeDispatcher.c` | `fgetxattr`, `fsetxattr`, `fremovexattr`, `flistxattr` | xattr 在 Linux 2.4 时代不支持 |
| `net_util.c` | `getifaddrs` (某些平台) | 不是所有 Unix 都有 |

**设计理念：运行时能力检测 > 编译时依赖**

```c
// 编译时链接的问题:
// 1. 如果 glibc 版本低 → 链接报错 → 整个 JDK 无法运行
// 2. 即使用 weak symbol, 行为也不可控

// dlsym 的优势:
my_openat64_func = dlsym(RTLD_DEFAULT, "openat64");
if (my_openat64_func != NULL) {
    // 有 openat → 启用 SecureDirectoryStream (TOCTOU 安全)
    capabilities |= SUPPORTS_OPENAT;
} else {
    // 没有 → 降级使用普通 open (功能可用但少了安全保证)
}
```

这是 **优雅降级** 的典范：同一个 JDK 二进制可以在 Linux 2.6（无 *at）和 Linux 5.x（完整支持）上运行，根据运行时环境自动选择最佳路径。

---

### Q18: JDK native 代码中有哪些"性能优化"的模式？请至少列举 5 个。

**答**：

| # | 优化模式 | 位置 | 效果 |
|---|---------|------|------|
| 1 | **JNI 字段 ID 缓存** | `NetworkInterface.init()`、`UnixNativeDispatcher.init()` 所有 init() | 避免每次 `GetFieldID()` 的反射开销 |
| 2 | **连续内存分配** | `NetworkInterface.c` — `netif+name` 一次 malloc | 减少 malloc 次数和内存碎片 |
| 3 | **`fillInStackTrace()` 空操作** | `UnixException.java` | 每个文件操作失败时省去堆栈追踪（JDK 7+ 的 `Throwable.fillInStackTrace` 成本 ~5μs） |
| 4 | **`stat1()` 快速路径** | `UnixNativeDispatcher.c` | `Files.exists()` 只返回 `st_mode` 的 int，不创建 Java 对象 |
| 5 | **ThreadLocal DirectBuffer 池** | `IOUtil.java` / `Util.java` | HeapBuffer→DirectBuffer 拷贝时复用临时缓冲区，避免频繁 malloc/free |
| 6 | **epoll_event 数组用 Unsafe 操作** | `EPollArrayWrapper.java` | 直接在堆外内存操作，epoll_wait 写入后零拷贝读取 |
| 7 | **NativeBuffer 缓存** | `UnixNativeDispatcher.copyToNativeBuffer()` | Path→C 字符串转换的 native 内存复用 |
| 8 | **CHECKED_MALLOC3 宏的 partial result** | `NetworkInterface.c` | OOM 时返回已枚举的接口而非 NULL，部分结果优于无结果 |

---

## 六、系统调用速查表

将全系列涉及的所有系统调用/库函数汇总：

### 网络相关

| 系统调用 | JDK 使用场景 | 章节 |
|---------|------------|------|
| `socket(AF_INET6, SOCK_STREAM/SOCK_DGRAM, 0)` | 创建 TCP/UDP socket | Ch04-Ch09 |
| `connect(fd, addr, len)` | TCP 连接 / UDP 设过滤器 | Ch04,Ch07,Ch08 |
| `bind(fd, addr, len)` + `listen(fd, backlog)` | 服务端绑定+监听 | Ch05 |
| `accept(fd, addr, len)` | 接受新连接 | Ch05 |
| `read/write/recv/send/sendto/recvfrom` | 数据收发 | Ch04-Ch09 |
| `poll(fds, nfds, timeout)` | BIO 超时等待 | Ch08,Ch09 |
| `epoll_create/epoll_ctl/epoll_wait` | NIO Selector | Ch01 |
| `sendfile64(out_fd, in_fd, offset, count)` | 零拷贝文件传输 | Ch06 |
| `mmap/munmap/msync/madvise` | 内存映射文件 | Ch06 |
| `setsockopt/getsockopt` | Socket 选项 | Ch04-Ch09 |
| `getaddrinfo/getnameinfo` | DNS 正查/反查 | Ch10 |
| `gethostname` | 获取主机名 | Ch10 |
| `ioctl(SIOCGIFCONF/SIOCGIFFLAGS/...)` | 网卡信息查询 | Ch11 |
| `pipe(fd[2])` | Selector wakeup 管道 | Ch01 |
| `dup2(old, new)` | BIO close 协议 | Ch08 |
| `pthread_kill(tid, sig)` | 中断阻塞线程 | Ch08 |
| `socketpair(PF_UNIX, SOCK_STREAM, 0, sv)` | BIO marker_fd / WatchService 唤醒 | Ch08,Ch12 |
| `fcntl(fd, F_SETFL, O_NONBLOCK)` | 设置非阻塞 | Ch04,Ch12 |
| `fcntl(fd, F_SETLK64, &flock)` | 文件锁 | Ch06 |
| `shutdown(fd, how)` | 半关闭 | Ch08 |

### 文件系统相关

| 系统调用 | JDK 使用场景 | 章节 |
|---------|------------|------|
| `open/open64/openat` | 打开文件 | Ch12 |
| `close` | 关闭 fd | Ch12 |
| `stat64/lstat64/fstat64/fstatat64` | 文件属性查询 | Ch12 |
| `chmod/fchmod` | 修改权限 | Ch12 |
| `chown/lchown/fchown` | 修改所有者 | Ch12 |
| `link/unlink/unlinkat` | 硬链接/删除文件 | Ch12 |
| `rename/renameat` | 重命名/移动 | Ch12 |
| `symlink/readlink/realpath` | 符号链接操作 | Ch12 |
| `mkdir/rmdir` | 目录创建/删除 | Ch12 |
| `opendir/readdir64/closedir/fdopendir` | 目录遍历 | Ch12 |
| `access` | 权限检查 | Ch12 |
| `utimes/futimesat` | 修改时间戳 | Ch12 |
| `statvfs64` | 磁盘空间查询 | Ch12 |
| `pathconf/fpathconf` | 文件系统配置查询 | Ch12 |
| `mknod` | 创建特殊文件 | Ch12 |
| `getcwd` | 获取当前工作目录 | Ch12 |
| `inotify_init/inotify_add_watch/inotify_rm_watch` | 文件监控 | Ch12 |
| `fgetxattr/fsetxattr/flistxattr/fremovexattr` | 扩展属性 | Ch12 |
| `setmntent/getmntent_r/endmntent` | 挂载点枚举 | Ch12 |

### 用户/进程相关

| 函数 | JDK 使用场景 | 章节 |
|------|------------|------|
| `getpwuid_r/getpwnam_r` | UID↔用户名 | Ch12 |
| `getgrgid_r/getgrnam_r` | GID↔组名 | Ch12 |
| `dlsym(RTLD_DEFAULT, name)` | 运行时函数探测 | Ch12 |
| `sysconf(_SC_GETPW_R_SIZE_MAX)` | 密码记录缓冲区大小 | Ch12 |
| `strerror/gai_strerror` | 错误码转字符串 | Ch10,Ch12 |

---

## 七、总结

本面试专题新增 **18 道深度面试题**，加上各章节的 57 道基础题，整个 Native I/O 系列共计 **75 道面试题**，覆盖：

| 类别 | 题数 | 覆盖范围 |
|------|------|---------|
| 基础概念题 | 57 | 各章节末尾，单一知识点 |
| 跨章节综合题 | 5 | Q1-Q5: NIO 体系全链路 |
| BIO vs NIO 对比题 | 3 | Q6-Q8: close 协议、超时、编程坑 |
| 系统调用深度题 | 3 | Q9-Q11: stat 家族、EINTR、ioctl 两次调用 |
| 生产故障排查题 | 4 | Q12-Q15: DNS 超时、IP 错误、OOM、K8s |
| 设计思想题 | 3 | Q16-Q18: 信号中断、dlsym 降级、性能优化 |
