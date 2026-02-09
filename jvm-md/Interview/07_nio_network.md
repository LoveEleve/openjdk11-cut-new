# 主题七：NIO 与网络 — 从 EPoll 到零拷贝

> 对应文档: `NativeLibs/ch01~ch13`
> 面试覆盖: EPoll / Selector / BIO vs NIO / 零拷贝 / FileChannel / DNS

---

## Q1: Java NIO 的 Selector 底层用的什么？⭐

### 一句话结论
Linux 上用 **EPoll**（JDK 11 默认），通过 `epoll_create` + `epoll_ctl` + `epoll_wait` 三个系统调用实现 I/O 多路复用。

### 源码级回答

**EPoll 三步曲:**
```
1. epoll_create1(EPOLL_CLOEXEC)  → 创建 epoll 实例，返回 epfd
2. epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &event)  → 注册 fd 及关注的事件
3. epoll_wait(epfd, events[], maxEvents, timeout) → 阻塞等待就绪事件
```

**EPoll 底层原理 (内核层):**
```
1. 红黑树: 管理所有注册的 fd (O(logN) 增删)
2. 就绪链表: 设备驱动通过回调将就绪 fd 加入链表
3. epoll_wait: 只需检查就绪链表是否为空 → O(1) 获取就绪 fd
```

**Selector 到 EPoll 的映射:**
```java
Selector.open()       → EPollSelectorImpl → epoll_create
channel.register(sel) → EPollSelectorImpl.implRegister() → epoll_ctl(ADD)
selector.select()     → EPollSelectorImpl.doSelect() → epoll_wait
```

**EPoll 的 LT vs ET 模式:**
- JDK 默认用 **LT (Level-Triggered)**：只要 fd 就绪就持续通知
- Netty 的 EpollEventLoop 用 **ET (Edge-Triggered)**：只在状态变化时通知一次

> 📖 详细文档: `NativeLibs/ch01_epoll_mechanism.md`

---

## Q2: BIO 和 NIO 的核心区别？从系统调用层面看 ⭐⭐

### 一句话结论
BIO = **一个连接一个线程 + 阻塞 read/write**，NIO = **一个 Selector 管理多个连接 + 非阻塞 I/O + 事件驱动**。

### 源码级回答

| 维度 | BIO (java.net) | NIO (java.nio) |
|------|---------------|-----------------|
| 线程模型 | 1 连接 : 1 线程 | N 连接 : 1 Selector 线程 |
| 阻塞行为 | read() 阻塞直到有数据 | select() 阻塞，read() 非阻塞 |
| 底层系统调用 | read/write (阻塞) | epoll_wait + read/write (非阻塞) |
| fd 模式 | 默认 blocking | `fcntl(fd, F_SETFL, O_NONBLOCK)` |
| Buffer | 无 (流式 InputStream) | ByteBuffer (直接内存或堆内存) |
| 10K 连接时 | 10K 线程 → 资源爆炸 | 1 个 Selector 线程 → 轻量 |

**BIO read() 底层:**
```
Java: InputStream.read(byte[])
  → JNI: socketRead0()
    → recv(fd, buf, len, 0)  // 阻塞! 直到有数据或 EOF
```

**NIO read() 底层:**
```
Java: SocketChannel.read(ByteBuffer)
  → JNI: read0()
    → read(fd, buf, len)  // 非阻塞! 无数据返回 EAGAIN
```

> 📖 详细文档: `NativeLibs/ch04_socketchannel_tcp.md`, `NativeLibs/ch08_bio_socket.md`

---

## Q3: 零拷贝是什么？Java 怎么实现？⭐⭐

### 一句话结论
零拷贝 = 减少用户态与内核态之间的数据拷贝。Java 提供两种: **FileChannel.transferTo()** → `sendfile` 系统调用，**MappedByteBuffer** → `mmap`。

### 源码级回答

**传统 I/O 路径 (4 次拷贝):**
```
磁盘 → 内核缓冲区 → 用户缓冲区 → Socket 缓冲区 → 网卡
       (DMA)        (CPU 拷贝)    (CPU 拷贝)      (DMA)
```

**sendfile 零拷贝 (2 次拷贝):**
```
磁盘 → 内核缓冲区 ──────────────→ Socket 缓冲区 → 网卡
       (DMA)       (内核内零拷贝)                  (DMA)
// 数据不经过用户态!
```

**FileChannel.transferTo() 实现:**
```java
// Java 层
long transferred = fileChannel.transferTo(pos, count, socketChannel);

// JNI 层
FileChannelImpl.c → transferTo0()
  → sendfile64(srcFD, dstFD, &offset, count)  // Linux 系统调用!
  → 如果 sendfile 失败 (不支持的文件系统)
    → 回退到 mmap + write
```

**MappedByteBuffer (mmap):**
```java
MappedByteBuffer buf = fileChannel.map(READ_WRITE, 0, fileSize);
// JNI → mmap64(NULL, len, PROT_READ|PROT_WRITE, MAP_SHARED, fd, off)
// 文件直接映射到进程地址空间
// 访问 buf → 缺页中断 → 内核加载磁盘数据 → 无需 read() 系统调用
```

**DirectByteBuffer vs HeapByteBuffer:**
```
HeapByteBuffer: byte[] 在 Java 堆 → I/O 时需要复制到 native 内存 (GC 可能移动)
DirectByteBuffer: native 内存 (Unsafe.allocateMemory) → 直接传给系统调用，零拷贝!
```

> 📖 详细文档: `NativeLibs/ch06_filechannel_zerocopy.md`

---

## Q4: ServerSocketChannel.accept() 底层做了什么？⭐⭐

### 一句话结论
`accept()` → `accept4(fd, addr, flags)` 系统调用 → 内核创建新 Socket → 返回新 fd → 包装为 `SocketChannel` 对象。

### 源码级回答

```
Java: ServerSocketChannel.accept()
  → ServerSocketChannelImpl.accept()
    → accept0(fd, newfd, isaa)  // JNI
      → accept4(fd, &addr, &len, SOCK_NONBLOCK | SOCK_CLOEXEC)
      // accept4 = accept + 原子设置 NONBLOCK 和 CLOEXEC (一次系统调用)

    → new SocketChannelImpl(newfd)
    → 注册到当前 Selector (如果有)
```

**为什么用 accept4 而非 accept:**
```
accept()  → 返回 fd → fcntl(fd, F_SETFL, O_NONBLOCK) → fcntl(fd, F_SETFD, FD_CLOEXEC)
            3 次系统调用! 有 TOCTOU 竞态风险

accept4() → 返回 fd (已经是 NONBLOCK + CLOEXEC)
            1 次系统调用! 原子操作
```

> 📖 详细文档: `NativeLibs/ch05_serversocketchannel.md`

---

## Q5: DNS 解析在 JVM 里是怎么实现的？⭐⭐

### 一句话结论
`InetAddress.getByName()` → 先查 **JVM 级缓存** → 缓存未命中 → JNI 调用 `getaddrinfo()` (glibc) → OS 解析 (通常走 `/etc/resolv.conf` 配置的 DNS 服务器)。

### 源码级回答

**解析链路:**
```
InetAddress.getByName("www.example.com")
  → InetAddress.getAllByName()
    → 1. 检查地址缓存 (正缓存 + 负缓存)
    → 2. 缓存未命中 → NameService.lookupAllHostAddr()
      → InetAddressImplFactory → Inet4/Inet6AddressImpl
        → JNI: Inet4AddressImpl_lookupAllHostAddr()
          → getaddrinfo(hostname, NULL, &hints, &res)  // glibc 系统调用
```

**JVM DNS 缓存策略:**
```
正缓存 (成功解析):
  networkaddress.cache.ttl = 30  (默认, SecurityManager 下无限)
  → Java 层缓存 30 秒

负缓存 (解析失败):
  networkaddress.cache.negative.ttl = 10  (默认 10 秒)
```

**坑: getaddrinfo 是阻塞调用!**
```
问题: DNS 服务器慢 → getaddrinfo 阻塞线程 → NIO 线程被卡住
解法:
1. 预热 DNS 缓存
2. 异步 DNS (Netty 的 io.netty.resolver.dns)
3. 设置较长的缓存时间
```

> 📖 详细文档: `NativeLibs/ch10_inetaddress_dns.md`

---

## Q6: Selector 的 wakeup() 是怎么实现的？⭐⭐

### 一句话结论
`wakeup()` 向 Selector 内部的 **pipe/eventfd** 写 1 个字节，让 `epoll_wait` 立即返回。

### 源码级回答

```
Selector 初始化时:
  → pipe(fildes)  // 创建管道: fildes[0]=读端, fildes[1]=写端
  → epoll_ctl(epfd, ADD, fildes[0], EPOLLIN)  // 读端注册到 epoll

selector.wakeup():
  → write(fildes[1], 1 byte)  // 向管道写端写 1 字节
  → epoll_wait 检测到 fildes[0] 可读 → 立即返回!

select() 返回后:
  → 读取管道中的字节 (清空)
```

**JDK 11 优化: 用 eventfd 替代 pipe**
```
eventfd(0, EFD_CLOEXEC)  // 只需一个 fd，比 pipe 少一个 fd
→ 更轻量、更快
```

> 📖 详细文档: `NativeLibs/ch02_selector_and_registration.md`

---

## Q7: Netty 的 ByteBuf 和 Java NIO 的 ByteBuffer 有什么区别？⭐⭐

### 一句话结论
ByteBuffer 只有一个 position 指针（读写需 flip 切换），ByteBuf 有**读写双指针** (readerIndex/writerIndex) + **引用计数** + **池化** + **组合 Buffer**。

### 源码级回答

| 维度 | ByteBuffer (JDK) | ByteBuf (Netty) |
|------|------------------|-----------------|
| 读写指针 | 单 position + flip() | readerIndex + writerIndex |
| 内存回收 | GC / Cleaner | 引用计数 (release()) |
| 池化 | 无 | PooledByteBufAllocator (jemalloc 算法) |
| 扩容 | 不支持 | 自动扩容 |
| 组合 | 不支持 | CompositeByteBuf (零拷贝组合) |
| 零拷贝 | DirectByteBuffer | UnpooledUnsafeDirectByteBuf + slice/wrap |

**ByteBuffer 的 flip() 问题:**
```java
buf.put(data);     // 写入
buf.flip();        // 切换为读模式 (position→0, limit→原position)
buf.get();         // 读取
// 忘记 flip() → 读到错误数据!
```

> 📖 详细文档: `NativeLibs/ch13_interview_guide.md`

---

## Q8: 文件系统操作 (NIO.2 Files) 底层是什么？⭐⭐

### 一句话结论
`Files.readAllBytes()` → `UnixNativeDispatcher` → JNI → `open/read/close` 系统调用。NIO.2 通过 `FileSystemProvider` SPI 支持多种文件系统。

### 源码级回答

```
Files.readAllBytes(path)
  → FileChannel.open(path)
    → UnixChannelFactory.newFileChannel()
      → UnixNativeDispatcher.open0()
        → open64(path, O_RDONLY, mode)  // 系统调用
  → channel.read(ByteBuffer)
    → FileChannelImpl.read()
      → pread64(fd, buf, count, offset)  // 系统调用
  → channel.close()
    → close(fd)  // 系统调用
```

**目录遍历:**
```
Files.list(dir)
  → opendir(path)
  → readdir() 循环
  → closedir()

Files.walk(dir)  // 深度优先遍历
  → 递归 opendir/readdir
```

**关键优化 — RESTARTABLE 宏:**
```cpp
#define RESTARTABLE(_cmd, _result) do { \
    _result = _cmd; \
} while (_result == -1 && errno == EINTR)  // 被信号中断自动重试
```

> 📖 详细文档: `NativeLibs/ch12_unixnativedispatcher_filesystem.md`

---

## 🎯 面试话术建议

### 如何展示 NIO 源码功底:

> "我跟过 Java NIO 从 Selector.select() 到内核 epoll_wait 的完整链路。Selector 初始化时创建 eventfd（JDK 11 用 eventfd 替代了 pipe），注册到 epoll。select() 就是 epoll_wait，wakeup() 就是向 eventfd 写 1 个字节让 epoll_wait 立即返回。"

> "零拷贝我看过 FileChannel.transferTo 的 JNI 实现，底层是 sendfile64 系统调用，数据从文件到 Socket 不经过用户态。如果 sendfile 不支持（比如跨文件系统），会回退到 mmap + write。DirectByteBuffer 的堆外内存通过 Cleaner 机制回收，Cleaner 基于 PhantomReference，在 ReferenceHandler 线程中直接执行 clean() 调用 Unsafe.freeMemory()。"

> "DNS 解析有个坑——getaddrinfo 是阻塞的，如果 DNS 服务器慢，会卡住 NIO 的 EventLoop 线程。JVM 有两级缓存：正缓存默认 30 秒，负缓存 10 秒。生产环境建议预热 DNS 或使用 Netty 的异步 DNS resolver。"
