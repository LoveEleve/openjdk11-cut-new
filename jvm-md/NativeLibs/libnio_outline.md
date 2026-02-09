# libnio.so + libnet.so 源码分析大纲

> 标准环境：Linux x86_64, OpenJDK 11
> 源码根目录：`/data/workspace/openjdk-cut-new/src/java.base/`

---

## 总览

libnio.so 和 libnet.so 是 Java 网络 I/O 的两大 native 支柱：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Java 网络 I/O 全景                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  用户代码层                                                                 │
│  ├── ServerSocket / Socket / DatagramSocket      (java.net — 传统 BIO)     │
│  ├── SocketChannel / ServerSocketChannel          (java.nio — NIO)         │
│  ├── Selector / SelectionKey                      (java.nio — I/O 多路复用) │
│  └── AsynchronousSocketChannel                    (java.nio — AIO)         │
│                                                                             │
│  JDK 内部实现层 (sun.nio.ch / sun.nio.fs)                                  │
│  ├── EPollSelectorImpl → EPoll.java               (Linux epoll 封装)       │
│  ├── FileChannelImpl → FileDispatcherImpl          (文件 I/O)              │
│  ├── SocketChannelImpl → Net.java                  (Socket 操作)           │
│  └── UnixNativeDispatcher                          (文件系统操作)           │
│                                                                             │
│  Native 层 (.so)                                                            │
│  ├── libnio.so (46 个 .c 文件, 350+ JNI 方法)                              │
│  │   ├── ch/ — Channel/Selector 实现                                       │
│  │   └── fs/ — 文件系统操作                                                │
│  └── libnet.so (24 个 .c 文件, 67 JNI 方法)                                │
│      └── 传统 Socket/DatagramSocket/NetworkInterface                       │
│                                                                             │
│  系统调用层 (Linux Kernel)                                                  │
│  ├── epoll_create / epoll_ctl / epoll_wait         (I/O 多路复用)          │
│  ├── socket / bind / listen / accept / connect      (TCP/UDP)              │
│  ├── read / write / readv / writev / sendfile       (数据传输)             │
│  ├── mmap / munmap                                   (内存映射)             │
│  └── stat / chmod / readdir / inotify               (文件系统)             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 源码文件清单

### libnio.so（Linux 平台相关文件）

| 目录 | 文件数 | 核心文件 |
|------|--------|---------|
| `share/native/libnio/` | 3 | `nio_util.c`, `ch/nio.h` |
| `unix/native/libnio/ch/` | 14 | `IOUtil.c`, `FileChannelImpl.c`, `FileDispatcherImpl.c`, `Net.c`, `ServerSocketChannelImpl.c`, `SocketChannelImpl.c`, `DatagramChannelImpl.c`, `DatagramDispatcher.c`, `NativeThread.c`, `PollSelectorImpl.c`, `InheritedChannel.c` |
| `unix/native/libnio/fs/` | 2 | `UnixNativeDispatcher.c` (1245行, 49个native方法), `UnixCopyFile.c` |
| `unix/native/libnio/` | 1 | `MappedByteBuffer.c` |
| `linux/native/libnio/ch/` | 1 | **`EPoll.c`** (epoll 核心) |
| `linux/native/libnio/fs/` | 2 | `LinuxNativeDispatcher.c`, `LinuxWatchService.c` |
| **合计** | **23** | — |

### libnet.so（Linux 平台相关文件）

| 目录 | 文件数 | 核心文件 |
|------|--------|---------|
| `share/native/libnet/` | 8 | `InetAddress.c`, `Inet4Address.c`, `Inet6Address.c`, `DatagramPacket.c`, `net_util.c/.h` |
| `unix/native/libnet/` | 15 | `PlainSocketImpl.c` (1039行), `PlainDatagramSocketImpl.c` (2222行), `NetworkInterface.c` (1832行), `Inet4AddressImpl.c`, `Inet6AddressImpl.c`, `SocketInputStream.c`, `SocketOutputStream.c` |
| `linux/native/libnet/` | 1 | `linux_close.c` (451行, 异步安全 socket close) |
| **合计** | **24** | — |

---

## 分析计划（12 章）

### 第一部分：NIO 核心 — I/O 多路复用（面试高频 + 性能调优）

#### 第 1 章：epoll 底层机制 ⭐⭐⭐⭐⭐

> **解决什么问题**：Selector.select() 到底怎么调到 epoll_wait 的？

**源码文件**：
- Java: `linux/classes/sun/nio/ch/EPoll.java` (123行)
- Java: `linux/classes/sun/nio/ch/EPollSelectorImpl.java` (271行)
- Native: `linux/native/libnio/ch/EPoll.c`

**分析内容**：
1. `epoll_event` 结构体在 Java 中的内存布局（Unsafe 直接操作）
2. `EPoll.create()` → `epoll_create()` 系统调用
3. `EPoll.ctl()` → `epoll_ctl()` 注册/修改/删除事件
4. `EPoll.wait()` → `epoll_wait()` 等待事件
5. `EPollSelectorImpl.doSelect()` 完整流程：
   - `processUpdateQueue()` — interest ops → epoll_ctl
   - `epoll_wait()` — 阻塞等待
   - `processEvents()` — native event → Java SelectionKey
6. wakeup 机制（pipe fd0/fd1）
7. **epoll 水平触发(LT) vs 边缘触发(ET)**：JDK 默认用哪个？为什么？

**对比**：epoll vs poll vs select 的性能差异（O(1) vs O(n)）

---

#### 第 2 章：Selector 继承体系与 Provider 机制

> **解决什么问题**：`Selector.open()` 怎么在 Linux 上返回 EPollSelectorImpl？

**源码文件**：
- `share/classes/java/nio/channels/Selector.java`
- `share/classes/java/nio/channels/spi/AbstractSelector.java`
- `share/classes/sun/nio/ch/SelectorImpl.java` (312行)
- `linux/classes/sun/nio/ch/EPollSelectorProvider.java`
- `unix/classes/sun/nio/ch/PollSelectorImpl.java` (386行)

**分析内容**：
1. `Selector.open()` → `SelectorProvider.provider()` → `EPollSelectorProvider` 的加载链路
2. `SelectorImpl` 的核心字段：`selectedKeys` / `keys` / `cancelledKeys`
3. `SelChImpl` 接口：Channel 与 Selector 交互的桥梁
4. `SelectionKey` 的 interest ops ↔ ready ops 翻译机制
5. PollSelectorImpl 作为 fallback 的角色

---

#### 第 3 章：Channel 注册与事件分发

> **解决什么问题**：`channel.register(selector, OP_READ)` 到底做了什么？

**源码文件**：
- `share/classes/sun/nio/ch/SelectionKeyImpl.java`
- `share/classes/sun/nio/ch/SelChImpl.java`
- `linux/classes/sun/nio/ch/EPollSelectorImpl.java`

**分析内容**：
1. `register()` → `implRegister()` → `EPollSelectorImpl.processUpdateQueue()` → `EPoll.ctl(ADD)`
2. `translateInterestOps()` / `translateReadyOps()` — Java OP_READ ↔ EPOLLIN 映射
3. 取消注册：`cancel()` → `implDereg()` → `EPoll.ctl(DEL)`
4. fd → SelectionKey 的映射表

---

### 第二部分：NIO Channel — 数据传输

#### 第 4 章：SocketChannel — TCP 客户端 ⭐⭐⭐⭐⭐

> **解决什么问题**：NIO 的 `SocketChannel.open().connect()` 底层做了什么？

**源码文件**：
- Java: `share/classes/sun/nio/ch/SocketChannelImpl.java`
- Native: `unix/native/libnio/ch/SocketChannelImpl.c`
- Native: `unix/native/libnio/ch/Net.c` (最大文件, 30个native方法)

**分析内容**：
1. `SocketChannel.open()` → `socket(AF_INET, SOCK_STREAM, 0)` 系统调用
2. 非阻塞 `connect()` → `connect()` + `EINPROGRESS` + `finishConnect()` + `poll(POLLOUT)`
3. `Net.socket0()` / `Net.bind0()` / `Net.connect0()` / `Net.listen()` 逐一分析
4. socket 选项设置：`Net.setIntOption0()` → `setsockopt()`
5. `configureBlocking(false)` → `fcntl(fd, F_SETFL, O_NONBLOCK)`

---

#### 第 5 章：ServerSocketChannel — TCP 服务端

> **解决什么问题**：`ServerSocketChannel.accept()` 怎么做到非阻塞的？

**源码文件**：
- Java: `share/classes/sun/nio/ch/ServerSocketChannelImpl.java`
- Native: `unix/native/libnio/ch/ServerSocketChannelImpl.c`

**分析内容**：
1. `accept0()` → `accept()` / `accept4()` 系统调用
2. 非阻塞模式下返回 null vs 阻塞模式下等待
3. 新连接的 fd 如何包装成 `SocketChannelImpl`

---

#### 第 6 章：FileChannel — 文件 I/O 与零拷贝 ⭐⭐⭐⭐⭐

> **解决什么问题**：`FileChannel.transferTo()` 的零拷贝到底怎么实现的？

**源码文件**：
- Java: `share/classes/sun/nio/ch/FileChannelImpl.java`
- Native: `unix/native/libnio/ch/FileChannelImpl.c`
- Native: `unix/native/libnio/ch/FileDispatcherImpl.c` (最全的文件操作, 17个native方法)

**分析内容**：
1. `read()/write()` → `FileDispatcherImpl.read0/write0` → `pread/pwrite` 系统调用
2. `readv()/writev()` — Scatter/Gather I/O 实现
3. **`transferTo0()`** → `sendfile()` 系统调用（零拷贝核心）
4. **`map0()`** → `mmap()` 内存映射文件
5. `force0()` → `fsync/fdatasync` 刷盘
6. `lock0()/release0()` → `fcntl(F_SETLK)` 文件锁
7. `MappedByteBuffer.isLoaded0()` → `mincore()` — 检查页是否在内存

**内存布局图**：`sendfile` vs 传统 `read+write` 的数据拷贝路径对比

---

#### 第 7 章：DatagramChannel — UDP

> **解决什么问题**：UDP 的 `send/receive` 底层怎么实现？

**源码文件**：
- Native: `unix/native/libnio/ch/DatagramChannelImpl.c`
- Native: `unix/native/libnio/ch/DatagramDispatcher.c`

**分析内容**：
1. `send0()` → `sendto()` / `receive0()` → `recvfrom()`
2. `connect0()` / `disconnect0()` — UDP 的"连接"语义
3. 组播：`Net.joinOrDrop4/6` → `setsockopt(IP_ADD_MEMBERSHIP)`

---

### 第三部分：传统 BIO — libnet.so

#### 第 8 章：Socket — 传统阻塞 I/O ⭐⭐⭐⭐

> **解决什么问题**：`new Socket("host", 80)` 底层的系统调用链是什么？

**源码文件**：
- Native: `unix/native/libnet/PlainSocketImpl.c` (1039行, 12个native方法)
- Native: `unix/native/libnet/SocketInputStream.c`
- Native: `unix/native/libnet/SocketOutputStream.c`

**分析内容**：
1. `socketCreate()` → `socket(AF_INET/AF_INET6, SOCK_STREAM, 0)`
2. `socketConnect()` → `connect()` + 超时处理（poll 循环）
3. `socketBind()` / `socketListen()` / `socketAccept()`
4. `socketRead0()` → `recv()` / `socketWrite0()` → `send()`
5. `socketSetOption0()` → `setsockopt(SO_TIMEOUT/SO_REUSEADDR/TCP_NODELAY/...)`
6. **`linux_close.c` 异步安全关闭机制**：为什么 Linux 上关闭 socket 这么复杂？
   - 问题：线程 A 阻塞在 `read(fd)`, 线程 B 调用 `close(fd)` 会怎样？
   - 解决：`dup2` + `self-pipe trick` + 信号通知

---

#### 第 9 章：DatagramSocket — UDP 传统 I/O

> **解决什么问题**：`DatagramSocket.send/receive` 的底层实现

**源码文件**：
- Native: `unix/native/libnet/PlainDatagramSocketImpl.c` (2222行, 19个native方法)

**分析内容**：
1. `send0()` → `sendto()` / `receive0()` → `recvfrom()`
2. UDP 组播：`join()` / `leave()` → `setsockopt(IP_ADD_MEMBERSHIP/IP_DROP_MEMBERSHIP)`
3. `setTimeToLive()` → `setsockopt(IP_MULTICAST_TTL)`
4. `peek()` → `recvfrom(MSG_PEEK)` — 不取出数据只看一眼

---

#### 第 10 章：InetAddress 与 DNS 解析 ⭐⭐⭐⭐

> **解决什么问题**：`InetAddress.getByName("www.google.com")` 怎么解析域名？

**源码文件**：
- Native: `unix/native/libnet/Inet4AddressImpl.c` / `Inet6AddressImpl.c`
- Native: `share/native/libnet/InetAddress.c`

**分析内容**：
1. `lookupAllHostAddr()` → `getaddrinfo()` 系统调用（DNS 解析核心）
2. `getHostByAddr()` → `getnameinfo()` 反向解析
3. `isReachable0()` → `connect()` (TCP) / `ICMP echo`（需要 root 权限）
4. InetAddress 缓存机制：正向缓存 vs 负向缓存 vs TTL
5. 字段缓存初始化：`InetAddress.init()` → `initIDs()`（JNI 字段 ID 缓存模式）

---

#### 第 11 章：NetworkInterface — 网卡枚举

> **解决什么问题**：`NetworkInterface.getNetworkInterfaces()` 怎么获取所有网卡？

**源码文件**：
- Native: `unix/native/libnet/NetworkInterface.c` (1832行, 11个native方法)

**分析内容**：
1. `getAll()` → `ioctl(SIOCGIFCONF)` 枚举网卡列表
2. `getByName0()` → `if_nametoindex()`
3. `getMacAddr0()` → `ioctl(SIOCGIFHWADDR)` 获取 MAC 地址
4. `isUp0()` → `ioctl(SIOCGIFFLAGS)` 检查 IFF_UP
5. IPv6 地址枚举：读取 `/proc/net/if_inet6`

---

### 第四部分：文件系统 NIO.2

#### 第 12 章：UnixNativeDispatcher — 文件系统操作

> **解决什么问题**：`Files.copy/move/delete/readAttributes` 底层怎么实现？

**源码文件**：
- Native: `unix/native/libnio/fs/UnixNativeDispatcher.c` (1245行, 49个native方法)
- Native: `linux/native/libnio/fs/LinuxNativeDispatcher.c`
- Native: `linux/native/libnio/fs/LinuxWatchService.c`

**分析内容**：
1. 文件属性：`stat0/lstat0/fstat` → `stat/lstat/fstat` 系统调用
2. 文件操作：`mkdir0/rmdir0/rename0/link0/symlink0/unlink0`
3. 目录遍历：`opendir0/readdir/closedir`
4. 权限管理：`chmod0/chown0/access0`
5. 扩展属性(xattr)：`fgetxattr0/fsetxattr0` (Linux 特有)
6. **inotify 文件监控**：`LinuxWatchService.c` → `inotify_init/inotify_add_watch`
7. 挂载点信息：`setmntent0/getmntent0/endmntent`

---

## 章节依赖图

```
                    ┌───────────────────┐
                    │ 第 2 章 Selector  │
                    │   继承体系/Provider │
                    └────────┬──────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
      ┌──────────────┐ ┌─────────┐ ┌──────────────┐
      │ 第 1 章 epoll │ │ 第 3 章 │ │ 第 5 章      │
      │  底层机制     │ │ 注册/分发│ │ ServerSocket │
      └──────┬───────┘ └────┬────┘ │ Channel      │
             │              │      └──────┬───────┘
             ▼              ▼             │
      ┌──────────────┐                    │
      │ 第 4 章      │◄───────────────────┘
      │ SocketChannel│
      └──────────────┘

      ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
      │ 第 6 章      │  │ 第 7 章      │  │ 第 12 章     │
      │ FileChannel  │  │ Datagram     │  │ 文件系统     │
      │ 零拷贝/mmap  │  │ Channel(UDP) │  │ NIO.2        │
      └──────────────┘  └──────────────┘  └──────────────┘

      ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
      │ 第 8 章      │  │ 第 9 章      │  │ 第 10 章     │
      │ BIO Socket   │  │ BIO Datagram │  │ InetAddress  │
      │ (libnet.so)  │  │ (libnet.so)  │  │ DNS 解析     │
      └──────────────┘  └──────────────┘  └──────────────┘

                         ┌──────────────┐
                         │ 第 11 章     │
                         │ NetworkIface │
                         └──────────────┘
```

---

## 分析标准

每章分析遵循以下结构：

1. **问题引入**：这个组件解决什么问题？不存在会怎样？
2. **Java → Native 调用链**：从 Java API 追踪到系统调用
3. **完整 C 源码 + 逐行注释表**：每个核心 native 方法的完整源码
4. **系统调用解释**：涉及的 Linux 系统调用的参数和返回值
5. **内存布局 / 数据流图**：数据在用户态和内核态之间的流动
6. **性能关键点**：零拷贝、非阻塞、epoll 等设计的性能意义
7. **面试常见问题**：每章结尾列出相关面试题及答案

---

## 关键调用链路速查

```
【NIO Selector — epoll】
Selector.select()
  → SelectorImpl.lockAndDoSelect()
    → EPollSelectorImpl.doSelect()
      → EPoll.wait(epfd, addr, n, timeout)         [native]
        → epoll_wait(epfd, events, maxevents, timeout) [syscall]

【NIO SocketChannel — connect】
SocketChannel.open()
  → Net.socket0(IPv4, STREAM, false)               [native]
    → socket(AF_INET, SOCK_STREAM, 0)              [syscall]
channel.connect(addr)
  → Net.connect0(fd, addr, port)                    [native]
    → connect(fd, &sa, len)                         [syscall, returns EINPROGRESS]
channel.finishConnect()
  → SocketChannelImpl.checkConnect(fd, false)       [native]
    → poll(fd, POLLOUT) + getsockopt(SO_ERROR)      [syscall]

【NIO FileChannel — 零拷贝】
fileChannel.transferTo(pos, count, socketChannel)
  → FileChannelImpl.transferTo0(srcFD, pos, count, dstFD) [native]
    → sendfile(dstFD, srcFD, &offset, count)        [syscall, 零拷贝!]

【NIO FileChannel — 内存映射】
fileChannel.map(READ_WRITE, 0, size)
  → FileChannelImpl.map0(MAP_RW, pos, size)         [native]
    → mmap(0, size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, pos) [syscall]

【BIO Socket — connect】
new Socket("host", 80)
  → PlainSocketImpl.socketConnect(addr, port, timeout) [native]
    → connect(fd, &sa, len) + poll(fd, POLLOUT, timeout) [syscall]

【DNS 解析】
InetAddress.getByName("www.google.com")
  → Inet6AddressImpl.lookupAllHostAddr(host)        [native]
    → getaddrinfo(host, NULL, &hints, &res)         [libc → DNS resolver]

【NIO.2 文件属性】
Files.readAttributes(path, BasicFileAttributes.class)
  → UnixFileAttributes.get(path, followLinks)
    → UnixNativeDispatcher.stat0(pathAddr, attrs)    [native]
      → stat64(path, &buf)                           [syscall]

【NIO.2 目录遍历】
Files.list(dir)
  → UnixDirectoryStream.iterator()
    → UnixNativeDispatcher.opendir0(pathAddr)        [native → opendir()]
    → 循环: readdir(DIR*)                            [native → readdir64()]
    → UnixNativeDispatcher.closedir(DIR*)            [native → closedir()]

【NIO.2 文件监控 (Linux)】
dir.register(watchService, ENTRY_CREATE, ...)
  → LinuxWatchService.register()
    → inotify_add_watch(ifd, path, mask)             [syscall]
watchService.take()
  → poll(inotify_fd, socketpair_fd)                  [syscall → 阻塞等待]
  → read(inotify_fd) → 解析 inotify_event            [syscall]
```

---

## 推荐阅读顺序

```
第 1 章 (epoll)          ← 最核心，面试必考
  ↓
第 2 章 (Selector 体系)   ← 理解 Java 层抽象
  ↓
第 4 章 (SocketChannel)   ← NIO 网络编程核心
  ↓
第 6 章 (FileChannel)     ← 零拷贝/mmap，性能调优必备
  ↓
第 8 章 (BIO Socket)      ← 对比 NIO，理解为什么需要 NIO
  ↓
第 10 章 (DNS)            ← 网络问题排查利器
  ↓
其余章节按需阅读
```
