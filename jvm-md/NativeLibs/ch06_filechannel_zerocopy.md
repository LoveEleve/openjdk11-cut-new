# 第 6 章：FileChannel — 文件 I/O 与零拷贝

> **源码基线**：OpenJDK 11 / Linux x86_64
> **核心源文件**：`FileChannelImpl.java` (1215行) + `FileChannelImpl.c` (247行) + `FileDispatcherImpl.c` (374行) + `MappedByteBuffer.c` (128行)

---

## 1. 问题引入

假设你要把一个大文件通过网络发送出去，最朴素的写法：

```java
byte[] buf = new byte[8192];
while ((n = fileIn.read(buf)) > 0) {
    socketOut.write(buf, 0, n);
}
```

这段代码执行时数据经历 **4 次拷贝 + 4 次用户态/内核态切换**：

```
磁盘 → 内核页缓存(PageCache) → 用户空间buf → 内核Socket缓冲区 → 网卡
        read() 拷贝1          read() 拷贝2   write() 拷贝3       DMA 拷贝4
```

每次 `read()/write()` 系统调用都需要从用户态切到内核态再切回来。对于 10GB 的文件，这些额外拷贝和上下文切换带来巨大开销。

**FileChannel 提供了两个关键武器来解决这个问题**：
- **`transferTo()` → `sendfile()` 系统调用**：数据在内核态直接从文件传到 Socket，完全绕过用户空间 — **零拷贝**
- **`map()` → `mmap()` 系统调用**：把文件直接映射到进程地址空间，读写文件就像读写内存 — **内存映射**

本章从源码层面完整追踪这两个机制的实现。

---

## 2. 类总览

### 2.1 FileChannelImpl 核心字段

```java
public class FileChannelImpl extends FileChannel {
    private final FileDispatcher nd;           // I/O 操作委托者
    private final FileDescriptor fd;           // 文件描述符
    private final boolean writable;            // 是否可写
    private final boolean readable;            // 是否可读
    private final Object parent;               // 创建它的流 (FileInputStream/FileOutputStream)
    private final String path;                 // 文件路径
    private final NativeThreadSet threads;     // 线程集合（用于中断阻塞I/O）
    private final Object positionLock;         // 保护位置相关操作的锁
    private volatile boolean uninterruptible;  // 阻塞操作是否不可中断
    private final boolean direct;              // DirectIO 模式
    private final int alignment;               // DirectIO 对齐值
    private final Cleanable closer;            // GC 时自动关闭 fd
    private static final long allocationGranularity; // 页大小（mmap 对齐）
}
```

**关键设计**：
- **没有状态机**：与 SocketChannel 的 6 态状态机不同，FileChannel 没有连接/关闭状态的概念。它的生命周期就是 open → 使用 → close，通过 `ensureOpen()` + `AbstractInterruptibleChannel.isOpen()` 检查即可
- **`positionLock`**：文件有"当前位置"概念（`lseek`），多线程并发读写需要保护位置一致性
- **`NativeThreadSet`**：不是 SocketChannel 的 `NativeThread`，而是一个线程集合，支持同时有多个线程在做 I/O。`signalAndWait()` 可以中断所有阻塞线程

### 2.2 创建方式

FileChannel 不直接 `new`，而是通过传统 I/O 流获取：

```java
// 三种获取方式
FileChannel ch1 = new FileInputStream("data.bin").getChannel();   // 只读
FileChannel ch2 = new FileOutputStream("data.bin").getChannel();  // 只写
FileChannel ch3 = new RandomAccessFile("data.bin", "rw").getChannel(); // 读写
```

底层都调用：

```java
public static FileChannel open(FileDescriptor fd, String path,
                               boolean readable, boolean writable,
                               boolean direct, Object parent) {
    return new FileChannelImpl(fd, path, readable, writable, direct, parent);
}
```

**注意 `parent` 参数**：如果 FileChannel 是从 FileInputStream 获取的，`parent = FileInputStream`。关闭时优先通过 `parent.close()` 来关闭 fd，而不是自己直接关闭。如果 parent 为 null（直接通过 `FileChannel.open()` 创建），则注册 `Cleaner` 在 GC 时自动关闭。

### 2.3 与 SocketChannel 的关键区别

| 特性 | FileChannel | SocketChannel |
|------|-------------|---------------|
| 注册到 Selector | ❌ 不支持（不继承 SelectableChannel） | ✅ 支持 |
| 非阻塞模式 | ❌ 不支持 | ✅ `configureBlocking(false)` |
| 状态机 | 无 | 6 态 |
| 位置语义 | `lseek` 维护的文件位置 | 无位置概念（流式） |
| 零拷贝 | ✅ `transferTo/transferFrom` | ❌ |
| 内存映射 | ✅ `map()` | ❌ |
| 线程中断 | `NativeThreadSet`（多线程集合） | `NativeThread`（单线程读/写） |
| 文件锁 | ✅ `lock()/tryLock()` | ❌ |

---

## 3. read/write — 基础文件 I/O

### 3.1 单缓冲区 read 完整调用链

```
FileChannelImpl.read(ByteBuffer dst)
  → synchronized(positionLock)               // 保护文件位置
    → IOUtil.read(fd, dst, -1, nd)           // position=-1 表示使用当前位置
      → [分支1: DirectBuffer]
         readIntoNativeBuffer(fd, dst, -1, nd)
           → nd.read(fd, address+pos, rem)     // FileDispatcherImpl.read()
             → read0(fd, address, len)         [native]
               → read(fd, buf, len)            [POSIX syscall]
      → [分支2: HeapBuffer]
         bb = Util.getTemporaryDirectBuffer(rem) // 从缓存池获取临时 DirectBuffer
         readIntoNativeBuffer(fd, bb, -1, nd)    // 先读到临时 DirectBuffer
         dst.put(bb)                              // 再拷贝到 HeapBuffer
         Util.offerFirstTemporaryDirectBuffer(bb) // 归还临时 DirectBuffer
```

**position 参数的含义**：
- `position == -1`：使用 `nd.read()` → POSIX `read()`，使用并自动更新内核维护的文件位置
- `position >= 0`：使用 `nd.pread()` → POSIX `pread64()`，从指定位置读取，**不改变文件位置**

对应 JNI 实现：

```c
// FileDispatcherImpl.c — read0
JNIEXPORT jint JNICALL
Java_sun_nio_ch_FileDispatcherImpl_read0(JNIEnv *env, jclass clazz,
                             jobject fdo, jlong address, jint len) {
    jint fd = fdval(env, fdo);
    void *buf = (void *)jlong_to_ptr(address);
    return convertReturnVal(env, read(fd, buf, len), JNI_TRUE);
}

// pread0 — 带位置的读取
JNIEXPORT jint JNICALL
Java_sun_nio_ch_FileDispatcherImpl_pread0(JNIEnv *env, jclass clazz, jobject fdo,
                            jlong address, jint len, jlong offset) {
    jint fd = fdval(env, fdo);
    void *buf = (void *)jlong_to_ptr(address);
    return convertReturnVal(env, pread64(fd, buf, len, offset), JNI_TRUE);
}
```

**`pread64` vs `read` 的关键区别**：`pread64` 是原子操作 — 读取数据 + 不移动位置在一次系统调用中完成，多线程可以安全地并发从不同位置读取同一文件。而 `read` 会移动文件位置，必须在 `positionLock` 保护下执行。

### 3.2 HeapBuffer 为什么需要两次拷贝？

为什么不能把 `byte[]` 的地址直接传给 `read()` 系统调用？

**原因：GC 可能在系统调用阻塞期间移动 byte[] 的内存位置。**

`read(fd, buf, len)` 是个阻塞调用，如果 buf 指向堆上的 `byte[]`，在 `read()` 阻塞等待磁盘数据期间，GC 可能发生并移动这个数组。内核写入数据时用的还是旧地址，导致数据写入错误位置。

DirectBuffer 分配在堆外（off-heap），地址固定不会被 GC 移动，所以可以安全传给系统调用。

**临时 DirectBuffer 缓存池**：`Util.getTemporaryDirectBuffer(rem)` 不是每次都 malloc，而是从 `ThreadLocal<BufferCache>` 中获取之前用过的 buffer，用完后放回。这避免了频繁的 `malloc/free`。

### 3.3 write 流程

write 与 read 对称：

```java
// IOUtil.writeFromNativeBuffer()
if (position != -1) {
    written = nd.pwrite(fd, address + pos, rem, position); // pwrite64 — 带位置写
} else {
    written = nd.write(fd, address + pos, rem);             // write — 使用当前位置
}
```

对应 JNI：

```c
// write0 → POSIX write()
return convertReturnVal(env, write(fd, buf, len), JNI_FALSE);

// pwrite0 → POSIX pwrite64()
return convertReturnVal(env, pwrite64(fd, buf, len, offset), JNI_FALSE);
```

### 3.4 EINTR 重试循环

FileChannelImpl 的每个 I/O 操作都有 EINTR 重试：

```java
do {
    n = IOUtil.read(fd, dst, -1, direct, alignment, nd);
} while ((n == IOStatus.INTERRUPTED) && isOpen());
```

文件 I/O 可能被信号中断（比如 `close()` 发送的 `pthread_kill`），此时系统调用返回 `EINTR`，`convertReturnVal` 将其转换为 `IOStatus.INTERRUPTED(-3)`，Java 层捕获后重试。

---

## 4. readv/writev — Scatter/Gather I/O

### 4.1 解决什么问题？

假设你的文件格式是 "4字节头 + 1024字节体 + 2字节校验"，用普通 read 需要 3 次系统调用或一次大 read 然后手动拆分。Scatter I/O 允许一次系统调用读到多个不连续的缓冲区：

```java
ByteBuffer header = ByteBuffer.allocate(4);
ByteBuffer body   = ByteBuffer.allocate(1024);
ByteBuffer crc    = ByteBuffer.allocate(2);
channel.read(new ByteBuffer[]{header, body, crc});  // 一次系统调用
```

### 4.2 调用链

```
FileChannelImpl.read(ByteBuffer[] dsts, offset, length)
  → IOUtil.read(fd, dsts, offset, length, nd)
    → IOVecWrapper.get(length)           // 获取 iovec 数组包装器
    → 遍历每个 ByteBuffer，填充 iovec:
        vec.putBase(i, address + pos)     // iov_base = 缓冲区地址
        vec.putLen(i, rem)                // iov_len  = 缓冲区剩余空间
    → nd.readv(fd, vec.address, iov_len)  // FileDispatcherImpl.readv()
      → readv0(fd, address, len)          [native]
        → readv(fd, iov, len)             [POSIX syscall]
```

JNI 实现：

```c
JNIEXPORT jlong JNICALL
Java_sun_nio_ch_FileDispatcherImpl_readv0(JNIEnv *env, jclass clazz,
                              jobject fdo, jlong address, jint len) {
    jint fd = fdval(env, fdo);
    struct iovec *iov = (struct iovec *)jlong_to_ptr(address);
    return convertLongReturnVal(env, readv(fd, iov, len), JNI_TRUE);
}
```

**`struct iovec`**：POSIX 定义的散列/聚集 I/O 向量，每个元素包含 `iov_base`（缓冲区地址）和 `iov_len`（长度）。`readv` 一次系统调用按顺序填充所有向量。

**IOV_MAX 限制**：`IOUtil.IOV_MAX` = `iovMax()` → `sysconf(_SC_IOV_MAX)`，Linux 上通常为 1024。超过此数量的缓冲区需要分批处理。

### 4.3 Shadow Buffer 机制

如果 ByteBuffer 数组中有 HeapBuffer，IOUtil 会为其分配 "shadow"（影子）DirectBuffer：

```java
if (!(buf instanceof DirectBuffer)) {
    ByteBuffer shadow = Util.getTemporaryDirectBuffer(rem);
    vec.setShadow(iov_len, shadow);    // 记录影子关系
    buf = shadow;                       // 用影子 buffer 的地址填 iovec
}
```

读取完成后，从 shadow 拷贝回原始 HeapBuffer：

```java
shadow.limit(shadow.position() + n);
buf.put(shadow);  // shadow → 原始 HeapBuffer
```

writev 的 shadow 处理方向相反：先从 HeapBuffer 拷贝到 shadow，然后用 shadow 地址做 writev。

---

## 5. transferTo — 零拷贝 ⭐⭐⭐⭐⭐

### 5.1 三级降级策略

`transferTo()` 采用三级降级，优先尝试最高性能的方式：

```java
public long transferTo(long position, long count, WritableByteChannel target) {
    // 参数检查和边界计算...
    int icount = (int)Math.min(count, Integer.MAX_VALUE);

    // 第 1 级：sendfile — 内核态零拷贝
    if ((n = transferToDirectly(position, icount, target)) >= 0)
        return n;

    // 第 2 级：mmap + write — 用户态一次拷贝
    if ((n = transferToTrustedChannel(position, icount, target)) >= 0)
        return n;

    // 第 3 级：read + write — 用户态两次拷贝（最慢）
    return transferToArbitraryChannel(position, icount, target);
}
```

### 5.2 第 1 级：transferToDirectly → sendfile()

**前置条件检查**：

```java
private long transferToDirectly(long position, int icount, WritableByteChannel target) {
    if (!transferSupported)      return UNSUPPORTED;      // 内核不支持 sendfile
    
    // 获取目标 fd
    FileDescriptor targetFD = null;
    if (target instanceof FileChannelImpl) {
        if (!fileSupported)      return UNSUPPORTED_CASE; // sendfile 到文件不支持
        targetFD = ((FileChannelImpl)target).fd;
    } else if (target instanceof SelChImpl) {
        if ((target instanceof SinkChannelImpl) && !pipeSupported)
            return UNSUPPORTED_CASE;                       // sendfile 到 pipe 不支持
        targetFD = ((SelChImpl)target).getFD();
    }
    
    if (targetFD == null)        return UNSUPPORTED;      // 不认识的 Channel 类型
    if (thisFDVal == targetFDVal) return UNSUPPORTED;     // 不能自己传给自己
    
    return transferToDirectlyInternal(position, icount, target, targetFD);
}
```

**核心 JNI — Linux sendfile64**：

```c
JNIEXPORT jlong JNICALL
Java_sun_nio_ch_FileChannelImpl_transferTo0(JNIEnv *env, jobject this,
                                            jobject srcFDO, jlong position,
                                            jlong count, jobject dstFDO) {
    jint srcFD = fdval(env, srcFDO);
    jint dstFD = fdval(env, dstFDO);

#if defined(__linux__)
    off64_t offset = (off64_t)position;
    jlong n = sendfile64(dstFD, srcFD, &offset, (size_t)count);
    if (n < 0) {
        if (errno == EAGAIN)      return IOS_UNAVAILABLE;      // 非阻塞，目标fd暂不可写
        if ((errno == EINVAL) && ((ssize_t)count >= 0))
            return IOS_UNSUPPORTED_CASE;                        // 不支持此fd组合
        if (errno == EINTR)       return IOS_INTERRUPTED;
        JNU_ThrowIOExceptionWithLastError(env, "Transfer failed");
        return IOS_THROWN;
    }
    return n;
```

**sendfile64 系统调用详解**：

```c
ssize_t sendfile64(int out_fd, int in_fd, off64_t *offset, size_t count);
```

- `out_fd`：目标文件描述符（通常是 socket）
- `in_fd`：源文件描述符（必须支持 mmap，即普通文件或块设备）
- `offset`：源文件的起始偏移，调用后自动更新为新偏移
- `count`：要传输的字节数
- 返回值：实际传输的字节数

**数据流路径对比**：

```
【传统 read + write — 4 次拷贝】
磁盘 ──DMA──→ PageCache ──CPU──→ 用户buf ──CPU──→ Socket缓冲区 ──DMA──→ 网卡
                 拷贝1              拷贝2             拷贝3              拷贝4

【sendfile — 2 次拷贝（内核 2.6.33+，支持 scatter-gather DMA）】
磁盘 ──DMA──→ PageCache ─────────────────→ 网卡
                 拷贝1         DMA gather 拷贝2
              (只拷贝描述符到 Socket 缓冲区，不拷贝数据)

【sendfile — 3 次拷贝（旧内核或不支持 scatter-gather DMA）】
磁盘 ──DMA──→ PageCache ──CPU──→ Socket缓冲区 ──DMA──→ 网卡
                 拷贝1              拷贝2                拷贝3
```

**关键**：即使在 3 次拷贝的情况下，数据也**完全不经过用户空间**，避免了 2 次上下文切换和 1 次无意义的拷贝。

### 5.3 自适应降级机制

sendfile 并非所有 fd 组合都支持。JDK 用三个 `static volatile boolean` 标志做自适应降级：

```java
private static volatile boolean transferSupported = true; // sendfile 系统调用本身
private static volatile boolean pipeSupported = true;     // sendfile 到 pipe
private static volatile boolean fileSupported = true;     // sendfile 到文件
```

当 `transferTo0` 返回 `IOS_UNSUPPORTED(-6)` 或 `IOS_UNSUPPORTED_CASE(-5)` 时：

```java
if (n == IOStatus.UNSUPPORTED_CASE) {
    if (target instanceof SinkChannelImpl) pipeSupported = false;
    if (target instanceof FileChannelImpl) fileSupported = false;
}
if (n == IOStatus.UNSUPPORTED) {
    transferSupported = false;  // 再也不尝试 sendfile
}
```

这些标志是 class 级别的（static），一旦某个 FileChannel 实例发现不支持，所有后续实例都直接跳过 sendfile 尝试。

### 5.4 第 2 级：transferToTrustedChannel → mmap + write

当 sendfile 不可用但目标是"可信 Channel"（FileChannelImpl 或 SelChImpl）时：

```java
private long transferToTrustedChannel(long position, long count,
                                      WritableByteChannel target) {
    long remaining = count;
    while (remaining > 0L) {
        long size = Math.min(remaining, MAPPED_TRANSFER_SIZE);  // 每次最多 8MB
        MappedByteBuffer dbb = map(MapMode.READ_ONLY, position, size); // mmap 源文件
        try {
            int n = target.write(dbb);  // 写入目标
            remaining -= n;
            position += n;
        } finally {
            unmap(dbb);                 // 立即解除映射
        }
    }
    return count - remaining;
}
```

**MAPPED_TRANSFER_SIZE = 8MB**：不一次映射整个文件，而是分 8MB 块映射。原因：
1. mmap 会在进程虚拟地址空间中分配连续区域，太大可能 ENOMEM
2. 每次映射后立即 unmap，避免长期占用地址空间
3. 8MB 是经验值，足够大以减少系统调用次数，又不会太大导致浪费

**数据流**：

```
磁盘 ──DMA──→ PageCache ←──映射──→ MappedByteBuffer(用户空间虚拟地址)
                                    │
                                    └──write()──→ 目标 Channel
```

MappedByteBuffer 虽然在用户空间有虚拟地址，但数据可能是按需加载（page fault 时从 PageCache 或磁盘读取），不是一次性全部拷贝到用户空间。

### 5.5 第 3 级：transferToArbitraryChannel — 朴素 read + write

对于不认识的 Channel 类型（比如自定义的 WritableByteChannel 实现），降级到最简单的方式：

```java
private long transferToArbitraryChannel(long position, int icount,
                                        WritableByteChannel target) {
    int c = Math.min(icount, TRANSFER_SIZE);  // TRANSFER_SIZE = 8192
    ByteBuffer bb = ByteBuffer.allocate(c);    // HeapBuffer，不是 DirectBuffer！
    long tw = 0;
    long pos = position;
    while (tw < icount) {
        bb.limit(Math.min((int)(icount - tw), TRANSFER_SIZE));
        int nr = read(bb, pos);    // pread 从文件读
        bb.flip();
        int nw = target.write(bb); // 写到目标
        tw += nw;
        if (nw != nr) break;       // 短写则停止
        pos += nw;
        bb.clear();
    }
    return tw;
}
```

**注意**：这里用 `ByteBuffer.allocate(c)` 创建的是 HeapBuffer，经过 IOUtil.read 内部会再转成 DirectBuffer，所以实际是 3 次拷贝（磁盘→PageCache→DirectBuffer→HeapBuffer→目标）。性能最差但兼容性最好。

### 5.6 transferFrom — 反向传输

`transferFrom` 从其他 Channel 读数据写到当前 FileChannel。它只有两级：

```java
public long transferFrom(ReadableByteChannel src, long position, long count) {
    if (src instanceof FileChannelImpl)
        return transferFromFileChannel((FileChannelImpl)src, position, count);
    return transferFromArbitraryChannel(src, position, count);
}
```

**注意**：`transferFrom` 没有 sendfile 路径！因为 `sendfile(out_fd, in_fd, ...)` 要求 `in_fd` 是文件，而 `transferFrom` 的源可能是 socket。Linux 4.5+ 有 `copy_file_range()` 可以做文件到文件的零拷贝，但 JDK 11 没有用。

`transferFromFileChannel` 使用 mmap 策略：

```java
private long transferFromFileChannel(FileChannelImpl src, long position, long count) {
    synchronized (src.positionLock) {
        long pos = src.position();
        while (remaining > 0L) {
            MappedByteBuffer bb = src.map(MapMode.READ_ONLY, p, size);
            long n = write(bb, position);  // pwrite 到当前文件
            unmap(bb);
        }
        src.position(pos + nwritten);  // 更新源文件位置
    }
}
```

---

## 6. map — 内存映射文件 ⭐⭐⭐⭐⭐

### 6.1 三种映射模式

```java
private static final int MAP_RO = 0;  // READ_ONLY
private static final int MAP_RW = 1;  // READ_WRITE
private static final int MAP_PV = 2;  // PRIVATE (写时拷贝)
```

对应 mmap 参数：

| MapMode | prot | flags | 语义 |
|---------|------|-------|------|
| READ_ONLY | `PROT_READ` | `MAP_SHARED` | 只读共享，多进程可见 |
| READ_WRITE | `PROT_READ\|PROT_WRITE` | `MAP_SHARED` | 读写共享，修改写回文件且多进程可见 |
| PRIVATE | `PROT_READ\|PROT_WRITE` | `MAP_PRIVATE` | 写时拷贝(COW)，修改不影响文件和其他进程 |

### 6.2 map() Java 层完整流程

```java
public MappedByteBuffer map(MapMode mode, long position, long size) {
    ensureOpen();
    // 参数校验：size 不能超过 Integer.MAX_VALUE (约 2GB)
    if (size > Integer.MAX_VALUE)
        throw new IllegalArgumentException("Size exceeds Integer.MAX_VALUE");

    long addr = -1;
    synchronized (positionLock) {
        // 1. 如果文件不够大，先扩展
        long filesize = nd.size(fd);
        if (filesize < position + size) {
            if (!writable) throw new IOException("Channel not open for writing");
            nd.truncate(fd, position + size);  // ftruncate64 扩展文件
        }

        // 2. size==0 特殊处理：返回空的 MappedByteBuffer
        if (size == 0) {
            return Util.newMappedByteBuffer(0, 0, new FileDescriptor(), null);
        }

        // 3. 计算页对齐偏移
        int pagePosition = (int)(position % allocationGranularity);
        long mapPosition = position - pagePosition;  // 向下对齐到页边界
        long mapSize = size + pagePosition;           // 实际映射大小

        // 4. 调用 mmap
        addr = map0(imode, mapPosition, mapSize);
    }

    // 5. 创建 MappedByteBuffer
    int isize = (int)size;
    Unmapper um = new Unmapper(addr, mapSize, isize, mfd);
    return Util.newMappedByteBuffer(isize, addr + pagePosition, mfd, um);
}
```

**页对齐处理**：mmap 要求 offset 必须是页大小的整数倍。如果用户请求 `map(mode, 100, 200)`，而页大小是 4096：
- `mapPosition = 100 - (100 % 4096) = 0`（向下对齐到 0）
- `mapSize = 200 + 100 = 300`（多映射前面的 100 字节）
- `pagePosition = 100`
- 最终返回 `addr + 100`，用户看到的起始地址正好是 offset=100 的位置

**`allocationGranularity`** 在静态初始化时通过 `initIDs()` 获取：

```c
JNIEXPORT jlong JNICALL
Java_sun_nio_ch_FileChannelImpl_initIDs(JNIEnv *env, jclass clazz) {
    jlong pageSize = sysconf(_SC_PAGESIZE);   // Linux 上通常是 4096
    chan_fd = (*env)->GetFieldID(env, clazz, "fd", "Ljava/io/FileDescriptor;");
    return pageSize;
}
```

### 6.3 map0 — JNI 层 mmap

```c
JNIEXPORT jlong JNICALL
Java_sun_nio_ch_FileChannelImpl_map0(JNIEnv *env, jobject this,
                                     jint prot, jlong off, jlong len) {
    void *mapAddress = 0;
    jobject fdo = (*env)->GetObjectField(env, this, chan_fd);
    jint fd = fdval(env, fdo);
    int protections = 0;
    int flags = 0;

    // 映射模式转换
    if (prot == MAP_RO) {
        protections = PROT_READ;
        flags = MAP_SHARED;
    } else if (prot == MAP_RW) {
        protections = PROT_WRITE | PROT_READ;
        flags = MAP_SHARED;
    } else if (prot == MAP_PV) {
        protections = PROT_WRITE | PROT_READ;
        flags = MAP_PRIVATE;     // 写时拷贝
    }

    mapAddress = mmap64(
        0,                    // addr: 让 OS 选择映射地址
        len,                  // length: 映射字节数
        protections,          // prot: 读/写/执行权限
        flags,                // flags: SHARED 或 PRIVATE
        fd,                   // fd: 文件描述符
        off);                 // offset: 文件偏移（已页对齐）

    if (mapAddress == MAP_FAILED) {
        if (errno == ENOMEM) {
            JNU_ThrowOutOfMemoryError(env, "Map failed");
            return IOS_THROWN;
        }
        return handle(env, -1, "Map failed");
    }

    return ((jlong) (unsigned long) mapAddress);
}
```

### 6.4 OOM 重试机制

Java 层在 `map0` 抛出 `OutOfMemoryError` 时有一次重试：

```java
try {
    addr = map0(imode, mapPosition, mapSize);
} catch (OutOfMemoryError x) {
    System.gc();                       // 强制 GC，释放已 unmap 但未 GC 的映射
    Thread.sleep(100);                 // 等待 GC 完成
    addr = map0(imode, mapPosition, mapSize); // 重试一次
}
```

**为什么可能 OOM？** mmap 不是分配物理内存，而是分配虚拟地址空间。虚拟地址空间用完了（32 位系统或大量映射）就会 `ENOMEM`。通过 GC 触发 Unmapper 的清理（munmap），释放虚拟地址空间后重试。

### 6.5 Unmapper — 自动解除映射

```java
private static class Unmapper implements Runnable {
    private volatile long address;
    private final long size;
    private final int cap;
    private final FileDescriptor fd;

    // 统计信息
    static volatile int count;          // 当前活跃映射数
    static volatile long totalSize;     // 当前映射总大小
    static volatile long totalCapacity; // 当前映射总容量

    public void run() {
        if (address == 0) return;
        unmap0(address, size);          // munmap 解除映射
        address = 0;
        if (fd.valid()) nd.close(fd);   // 关闭复制的 fd（Unix 上是无效 fd，不需要关闭）
        // 更新统计
        synchronized (Unmapper.class) {
            count--;
            totalSize -= size;
            totalCapacity -= cap;
        }
    }
}
```

Unmapper 通过 `Cleaner` 机制注册：当 MappedByteBuffer 变成 phantom reachable 时，GC 自动调用 `Unmapper.run()` 执行 `munmap`。也可以通过 `FileChannelImpl.unmap(bb)` 手动触发。

**unmap0 JNI**：

```c
JNIEXPORT jint JNICALL
Java_sun_nio_ch_FileChannelImpl_unmap0(JNIEnv *env, jobject this,
                                       jlong address, jlong len) {
    void *a = (void *)jlong_to_ptr(address);
    return handle(env, munmap(a, (size_t)len), "Unmap failed");
}
```

### 6.6 duplicateForMapping — Unix vs Windows 差异

```java
// Unix: 不需要保持 fd 打开
FileDescriptor duplicateForMapping(FileDescriptor fd) {
    return new FileDescriptor();  // 返回无效 fd！
}
```

Unix 上 mmap 后即使 close(fd)，映射仍然有效（因为内核维护了文件的引用计数）。所以 Unix 版本返回一个无效的 FileDescriptor 占位。Windows 上则需要通过 `DuplicateHandle` 复制 handle 并在 unmap 后关闭。

---

## 7. MappedByteBuffer 操作

### 7.1 isLoaded — mincore 检查页面驻留状态

```java
// MappedByteBuffer.java
public final boolean isLoaded() {
    long offset = mappingOffset();
    long length = mappingLength(offset);
    return isLoaded0(mappingAddress(offset), length, Bits.pageCount(length));
}
```

JNI 实现：

```c
JNIEXPORT jboolean JNICALL
Java_java_nio_MappedByteBuffer_isLoaded0(JNIEnv *env, jobject obj,
                                         jlong address, jlong len, jint numPages) {
    void *a = (void *) jlong_to_ptr(address);
    mincore_vec_t* vec = (mincore_vec_t*) malloc(numPages + 1);

    vec[numPages] = '\x7f';                        // 哨兵字节
    result = mincore(a, (size_t)len, vec);         // 查询每页驻留状态
    assert(vec[numPages] == '\x7f');               // 验证哨兵

    for (i = 0; i < numPages; i++) {
        if (vec[i] == 0) {   // 0 = 不在物理内存
            loaded = JNI_FALSE;
            break;
        }
    }
    free(vec);
    return loaded;
}
```

**`mincore()` 系统调用**：对于给定的地址范围，返回每个页面是否在物理内存中（即是否在 PageCache 中）。每个页面对应 vec 中的一个字节，最低位为 1 表示在内存中。

**哨兵字节设计**：在 vec 末尾写 `0x7f`，调用后断言它没变。这是为了检测 mincore 是否写越界（防御性编程）。

### 7.2 load — madvise 预加载

```c
JNIEXPORT void JNICALL
Java_java_nio_MappedByteBuffer_load0(JNIEnv *env, jobject obj,
                                     jlong address, jlong len) {
    char *a = (char *)jlong_to_ptr(address);
    int result = madvise((caddr_t)a, (size_t)len, MADV_WILLNEED);
}
```

`madvise(addr, len, MADV_WILLNEED)` 告诉内核"这段地址范围的数据马上会用到"，内核会异步地将数据从磁盘预读到 PageCache。

但仅调用 `madvise` 不够！JDK 还在 Java 层遍历每个页面读一个字节：

```java
Unsafe unsafe = Unsafe.getUnsafe();
int ps = Bits.pageSize();
long a = mappingAddress(offset);
byte x = 0;
for (int i = 0; i < count; i++) {
    x ^= unsafe.getByte(a);  // 触发 page fault，确保页面真的加载了
    a += ps;
}
```

**为什么需要手动触发 page fault？** `madvise(MADV_WILLNEED)` 只是建议，内核可能来不及预读或忽略。手动读每页字节确保所有页面在 `load()` 返回时都已在内存中。

`x ^= unsafe.getByte(a)` 用 XOR 累积是为了防止编译器优化掉循环（dead code elimination）。最后 `if (unused != 0) unused = x;` 确保 x 的值被"使用"。

### 7.3 force — msync 刷盘

```c
JNIEXPORT void JNICALL
Java_java_nio_MappedByteBuffer_force0(JNIEnv *env, jobject obj, jobject fdo,
                                      jlong address, jlong len) {
    void* a = (void *)jlong_to_ptr(address);
    int result = msync(a, (size_t)len, MS_SYNC);
}
```

`msync(addr, len, MS_SYNC)` 将映射区域的修改同步写回文件。`MS_SYNC` 是同步的，函数返回时数据已写入磁盘。还有 `MS_ASYNC` 选项只是标记脏页，由内核后台异步写回。

**与 FileChannel.force() 的区别**：
- `FileChannel.force(metaData)` → 调用 `fsync(fd)` 或 `fdatasync(fd)`，刷的是通过 `write()` 写入的数据
- `MappedByteBuffer.force()` → 调用 `msync(addr, len, MS_SYNC)`，刷的是通过 mmap 写入的数据

两者针对不同的写入路径。

---

## 8. force — FileChannel 层的刷盘

```java
public void force(boolean metaData) throws IOException {
    ensureOpen();
    int rv = -1;
    do {
        rv = nd.force(fd, metaData);
    } while ((rv == IOStatus.INTERRUPTED) && isOpen());
}
```

JNI 实现（Linux 路径）：

```c
JNIEXPORT jint JNICALL
Java_sun_nio_ch_FileDispatcherImpl_force0(JNIEnv *env, jobject this,
                                          jobject fdo, jboolean md) {
    jint fd = fdval(env, fdo);
    int result = 0;

    if (md == JNI_FALSE) {
        result = fdatasync(fd);   // 只刷数据，不刷元数据
    } else {
        result = fsync(fd);       // 刷数据 + 元数据（mtime, size 等）
    }
    return handle(env, result, "Force failed");
}
```

**`fsync` vs `fdatasync`**：
- `fsync(fd)`：确保所有数据 + 元数据（文件大小、修改时间、权限等）写到磁盘
- `fdatasync(fd)`：只确保数据写到磁盘，元数据可能不刷（除非元数据变化影响数据读取，比如文件大小变了）

`fdatasync` 更快因为少了一次 inode 写入。如果你只关心数据不丢失而不关心精确的修改时间，用 `force(false)`（即 fdatasync）更高效。

**macOS 特殊处理**：
```c
#ifdef MACOSX
    result = fcntl(fd, F_FULLFSYNC);   // macOS 的"真" fsync
    if (result == -1 && errno == ENOTSUP)
        result = fsync(fd);             // 降级
#endif
```

macOS 上 `fsync()` 不保证写到物理磁盘（可能只到磁盘的 write cache），需要用 `F_FULLFSYNC` 才能确保。

---

## 9. lock/release — 文件锁

### 9.1 lock() — 阻塞获取锁

```java
public FileLock lock(long position, long size, boolean shared) {
    FileLockImpl fli = new FileLockImpl(this, position, size, shared);
    FileLockTable flt = fileLockTable();
    flt.add(fli);
    int n;
    do {
        n = nd.lock(fd, true, position, size, shared); // block=true
    } while ((n == FileDispatcher.INTERRUPTED) && isOpen());

    if (n == FileDispatcher.RET_EX_LOCK) {
        // 请求了共享锁但系统返回排他锁（某些文件系统不支持共享锁）
        fli2 = new FileLockImpl(this, position, size, false);
        flt.replace(fli, fli2);
    }
}
```

JNI 实现：

```c
JNIEXPORT jint JNICALL
Java_sun_nio_ch_FileDispatcherImpl_lock0(JNIEnv *env, jobject this, jobject fdo,
                                      jboolean block, jlong pos, jlong size,
                                      jboolean shared) {
    jint fd = fdval(env, fdo);
    struct flock64 fl;

    fl.l_whence = SEEK_SET;
    fl.l_start  = (off64_t)pos;
    fl.l_len    = (size == Long.MAX_VALUE) ? 0 : (off64_t)size; // 0 = 锁到文件末尾
    fl.l_type   = shared ? F_RDLCK : F_WRLCK;

    int cmd = block ? F_SETLKW64 : F_SETLK64;
    lockResult = fcntl(fd, cmd, &fl);

    if (lockResult < 0) {
        if ((cmd == F_SETLK64) && (errno == EAGAIN || errno == EACCES))
            return NO_LOCK;       // tryLock 发现已被锁定
        if (errno == EINTR)
            return INTERRUPTED;
    }
    return 0;  // 成功
}
```

**`fcntl` 文件锁说明**：
- `F_SETLKW64`：阻塞等待直到获得锁
- `F_SETLK64`：非阻塞，如果无法立即获得锁则返回 EAGAIN
- `F_RDLCK`：共享锁（多个进程可同时持有）
- `F_WRLCK`：排他锁（独占）
- `l_len = 0`：从 `l_start` 锁到文件末尾（即使文件后续增长也覆盖）

**重要**：POSIX 文件锁是**进程级别**的，不是线程级别。同一进程内的不同线程 lock 同一区域不会阻塞（POSIX 语义）。JDK 通过 `FileLockTable` 在 JVM 层面做了额外的线程间互斥检查。

### 9.2 tryLock() — 非阻塞尝试

与 `lock()` 的区别仅在于 `block=false`：

```java
result = nd.lock(fd, false, position, size, shared);
if (result == FileDispatcher.NO_LOCK)
    return null;  // 锁被占用，返回 null
```

### 9.3 release() — 释放锁

```c
JNIEXPORT void JNICALL
Java_sun_nio_ch_FileDispatcherImpl_release0(JNIEnv *env, jobject this,
                                         jobject fdo, jlong pos, jlong size) {
    struct flock64 fl;
    fl.l_whence = SEEK_SET;
    fl.l_start  = (off64_t)pos;
    fl.l_len    = (size == Long.MAX_VALUE) ? 0 : (off64_t)size;
    fl.l_type   = F_UNLCK;              // 解锁
    fcntl(fd, F_SETLK64, &fl);
}
```

---

## 10. position/size/truncate — 位置和大小操作

### 10.1 position — lseek64

```c
JNIEXPORT jlong JNICALL
Java_sun_nio_ch_FileDispatcherImpl_seek0(JNIEnv *env, jclass clazz,
                                         jobject fdo, jlong offset) {
    jint fd = fdval(env, fdo);
    off64_t result;
    if (offset < 0) {
        result = lseek64(fd, 0, SEEK_CUR);   // offset<0: 查询当前位置
    } else {
        result = lseek64(fd, offset, SEEK_SET); // offset>=0: 设置位置
    }
    return handle(env, (jlong)result, "lseek64 failed");
}
```

Java 层用 `offset=-1` 作为"查询模式"的标记：

```java
public long position() {
    boolean append = fdAccess.getAppend(fd);
    p = (append) ? nd.size(fd) : nd.seek(fd, -1); // append 模式下位置永远在末尾
}
```

### 10.2 size — fstat64

```c
JNIEXPORT jlong JNICALL
Java_sun_nio_ch_FileDispatcherImpl_size0(JNIEnv *env, jobject this, jobject fdo) {
    jint fd = fdval(env, fdo);
    struct stat64 fbuf;
    if (fstat64(fd, &fbuf) < 0)
        return handle(env, -1, "Size failed");

#ifdef BLKGETSIZE64
    if (S_ISBLK(fbuf.st_mode)) {           // 块设备（如 /dev/sda）
        uint64_t size;
        ioctl(fd, BLKGETSIZE64, &size);     // 用 ioctl 获取块设备大小
        return (jlong)size;
    }
#endif
    return fbuf.st_size;                    // 普通文件：直接返回 st_size
}
```

对块设备的特殊处理：`stat.st_size` 对块设备返回 0，需要用 `ioctl(BLKGETSIZE64)` 获取真实大小。

### 10.3 truncate — ftruncate64

```c
JNIEXPORT jint JNICALL
Java_sun_nio_ch_FileDispatcherImpl_truncate0(JNIEnv *env, jobject this,
                                             jobject fdo, jlong size) {
    return handle(env, ftruncate64(fdval(env, fdo), size), "Truncation failed");
}
```

Java 层的 `truncate()` 还需要调整位置：

```java
public FileChannel truncate(long newSize) {
    long size = nd.size(fd);
    if (newSize < size) {
        nd.truncate(fd, newSize);     // 缩小文件
    }
    long p = nd.seek(fd, -1);         // 获取当前位置
    if (p > newSize)
        nd.seek(fd, newSize);         // 如果位置超出新大小，调整到末尾
}
```

---

## 11. close — 关闭机制

FileChannel 的关闭比 SocketChannel 简单（没有 preClose + signal 的复杂协议），但仍有几个要点：

```java
protected void implCloseChannel() throws IOException {
    if (!fd.valid()) return;

    // 1. 释放所有文件锁
    if (fileLockTable != null) {
        for (FileLock fl : fileLockTable.removeAll()) {
            nd.release(fd, fl.position(), fl.size());
            ((FileLockImpl)fl).invalidate();
        }
    }

    // 2. 通知所有阻塞在此 Channel 上的线程
    threads.signalAndWait();

    // 3. 关闭 fd
    if (parent != null) {
        ((java.io.Closeable)parent).close();  // 通过父流关闭
    } else if (closer != null) {
        closer.clean();                        // 通过 Cleaner 关闭
    } else {
        fdAccess.close(fd);                    // 直接关闭
    }
}
```

**`threads.signalAndWait()`**：NativeThreadSet 遍历所有注册的线程，调用 `NativeThread.signal(thread)` → `pthread_kill(pthread_t, SIGRTMAX-2)`，使阻塞在 `read/write` 上的线程收到 EINTR 返回。然后等待所有线程从 threads 集合中 remove 自己后才继续关闭 fd。

**三种关闭路径**：
1. **有 parent**（从 FileInputStream/FileOutputStream 获取的 Channel）：调用 parent 的 close()。parent 会反过来调用 Channel 的 close()，但 `isOpen()` 检查会防止重入
2. **有 closer**（直接 FileChannel.open() 创建的）：调用 Cleaner 的 clean()，执行 `fdAccess.close(fd)`
3. **两者都没有**：直接 `fdAccess.close(fd)`

---

## 12. preClose — 初始化机制

FileDispatcherImpl 在静态初始化时创建 preClose 用的 fd：

```c
static int preCloseFD = -1;

JNIEXPORT void JNICALL
Java_sun_nio_ch_FileDispatcherImpl_init(JNIEnv *env, jclass cl) {
    int sp[2];
    if (socketpair(PF_UNIX, SOCK_STREAM, 0, sp) < 0) {
        JNU_ThrowIOExceptionWithLastError(env, "socketpair failed");
        return;
    }
    preCloseFD = sp[0];   // 保留读端
    close(sp[1]);         // 关闭写端 — 读端永远 EOF
}
```

`preClose0` 的作用：`dup2(preCloseFD, fd)` 把目标 fd 重定向到一个永远 EOF 的 socket。这样任何在该 fd 上阻塞的 read 会立即返回 0（EOF），write 会返回 EPIPE。

```c
JNIEXPORT void JNICALL
Java_sun_nio_ch_FileDispatcherImpl_preClose0(JNIEnv *env, jclass clazz, jobject fdo) {
    jint fd = fdval(env, fdo);
    if (preCloseFD >= 0) {
        if (dup2(preCloseFD, fd) < 0)
            JNU_ThrowIOExceptionWithLastError(env, "dup2 failed");
    }
}
```

**注意**：FileChannel 自身的 `implCloseChannel` 没有调用 `preClose`，而是直接用 `signalAndWait()` 中断线程。preClose 主要用于 SocketChannel/ServerSocketChannel 的关闭。但 FileDispatcherImpl 作为共享的 native dispatcher，也服务于这些 Channel。

---

## 13. DirectIO 模式

Java 11 新增了 DirectIO 支持，绕过 PageCache 直接读写磁盘：

```java
// 启用 DirectIO
FileChannel ch = FileChannel.open(path,
    StandardOpenOption.READ, ExtendedOpenOption.DIRECT);
```

JNI 实现：

```c
JNIEXPORT jint JNICALL
Java_sun_nio_ch_FileDispatcherImpl_setDirect0(JNIEnv *env, jclass clazz, jobject fdo) {
    jint fd = fdval(env, fdo);

#ifdef O_DIRECT
    jint orig_flag = fcntl(fd, F_GETFL);
    result = fcntl(fd, F_SETFL, orig_flag | O_DIRECT);  // 添加 O_DIRECT 标志
#endif

    // 获取文件系统的对齐要求
    struct statvfs64 file_stat;
    fstatvfs64(fd, &file_stat);
    return (int)file_stat.f_frsize;  // 返回基本块大小作为对齐值
}
```

**`O_DIRECT` 的含义**：数据不经过 PageCache，直接在用户缓冲区和磁盘之间传输。要求：
- 用户缓冲区地址必须对齐到文件系统块大小（通常 512B 或 4KB）
- 传输大小必须是块大小的整数倍
- 文件偏移必须对齐

**适用场景**：数据库系统（如 MySQL InnoDB）自己管理缓存，不需要 OS 的 PageCache。用 DirectIO 避免数据在 PageCache 和用户 buffer pool 之间双重缓存。

---

## 14. 并发模型

### 14.1 锁设计

FileChannel 只有一把锁：

```java
private final Object positionLock = new Object();
```

所有涉及文件位置的操作（read、write、position、size、truncate）都需要持有 `positionLock`。这意味着**同一个 FileChannel 实例上不能并发 read 和 write**（除非使用带 position 参数的版本且 `needsPositionLock()` 返回 false）。

**带 position 参数的 read/write**（pread/pwrite）的特殊处理：

```java
public int read(ByteBuffer dst, long position) {
    if (nd.needsPositionLock()) {
        synchronized (positionLock) {
            return readInternal(dst, position);
        }
    } else {
        return readInternal(dst, position);  // 不需要锁！
    }
}
```

Unix 上 `needsPositionLock()` 返回 `false`，因为 `pread64/pwrite64` 是原子操作，不影响文件位置。所以**带 position 参数的 read/write 可以多线程并发执行**。

### 14.2 NativeThreadSet — 多线程 I/O 中断

```java
private final NativeThreadSet threads = new NativeThreadSet(2);
```

与 SocketChannel 的单线程 `readerThread/writerThread` 不同，FileChannel 使用 `NativeThreadSet` 跟踪所有正在做 I/O 的线程。因为 FileChannel 支持多个线程并发 pread/pwrite（带 position 参数的版本）。

```java
// 每次 I/O 操作
ti = threads.add();       // 注册当前线程
try {
    // ... do I/O ...
} finally {
    threads.remove(ti);    // 注销
}
```

关闭时 `threads.signalAndWait()` 会中断所有注册的线程。

---

## 15. 完整时序图：transferTo 零拷贝

```
  应用线程                FileChannelImpl              JNI                     Linux 内核
     │                        │                        │                         │
     │  transferTo(pos,cnt,   │                        │                         │
     │    socketChannel)      │                        │                         │
     │───────────────────────>│                        │                         │
     │                        │                        │                         │
     │                        │ transferToDirectly()   │                         │
     │                        │  检查 transferSupported│                         │
     │                        │  获取 targetFD         │                         │
     │                        │                        │                         │
     │                        │ transferTo0(srcFD,     │                         │
     │                        │   pos,cnt,dstFD)       │                         │
     │                        │───────────────────────>│                         │
     │                        │                        │                         │
     │                        │                        │ sendfile64(dstFD,       │
     │                        │                        │   srcFD,&offset,count)  │
     │                        │                        │────────────────────────>│
     │                        │                        │                         │
     │                        │                        │           ┌─────────────┤
     │                        │                        │           │ 磁盘→PageCache│
     │                        │                        │           │ PageCache→网卡│
     │                        │                        │           │ (全在内核态)  │
     │                        │                        │           └─────────────┤
     │                        │                        │                         │
     │                        │                        │         n = 已传输字节数 │
     │                        │                        │<────────────────────────│
     │                        │   n                    │                         │
     │                        │<───────────────────────│                         │
     │                        │                        │                         │
     │                        │ [如果 UNSUPPORTED]     │                         │
     │                        │ transferToTrusted()    │                         │
     │                        │   map() + write()      │                         │
     │                        │                        │                         │
     │                        │ [如果也不支持]         │                         │
     │                        │ transferToArbitrary()  │                         │
     │                        │   read() + write()     │                         │
     │                        │                        │                         │
     │      返回传输字节数     │                        │                         │
     │<───────────────────────│                        │                         │
```

---

## 16. 面试常见问题

### Q1: Java 的零拷贝是怎么实现的？

FileChannel.transferTo() 在 Linux 上调用 sendfile64() 系统调用，数据直接从源文件的 PageCache 传输到目标 socket 的缓冲区，完全不经过用户空间。如果网卡支持 scatter-gather DMA，数据甚至不需要从 PageCache 拷贝到 socket 缓冲区，只传描述符，实现真正的"零"拷贝（只有 2 次 DMA 拷贝，没有 CPU 拷贝）。

### Q2: sendfile 有什么限制？

- 源必须是文件（支持 mmap），不能是 socket
- 目标通常是 socket，到 pipe 或另一个文件可能不支持（取决于内核版本）
- JDK 通过三个 static volatile boolean 标志（transferSupported/pipeSupported/fileSupported）做自适应降级

### Q3: mmap 的优势和劣势？

**优势**：
- 避免用户态/内核态之间的数据拷贝（进程直接通过虚拟地址访问 PageCache）
- 多进程可以映射同一文件，通过 PageCache 共享数据
- 适合随机访问大文件（按需 page fault 加载）

**劣势**：
- 映射大小受虚拟地址空间限制（32 位系统约 2GB，64 位无此问题）
- MappedByteBuffer 不能超过 Integer.MAX_VALUE（约 2GB），因为 ByteBuffer.capacity() 是 int
- unmap 依赖 GC，不能精确控制释放时机（虽然可以通过反射调用 Cleaner）
- 不适合顺序写大量小数据（page fault 开销 > write 系统调用）

### Q4: fsync 和 fdatasync 的区别？

`fsync` 刷数据+元数据（包括 inode 的 mtime、size 等），`fdatasync` 只刷数据（除非文件大小变了）。对于频繁写入的场景（如数据库 WAL），用 `fdatasync`（即 `force(false)`）可以减少一次磁盘写入。

### Q5: FileChannel 为什么不能注册到 Selector？

FileChannel 不继承 SelectableChannel。根本原因是 Linux 上文件 I/O 不能用 epoll 监控（普通文件的 fd 总是"就绪"状态，epoll_ctl 对它返回 EPERM）。文件 I/O 要实现异步需要 Linux AIO（io_submit/io_getevents）或 io_uring，JDK 的 AsynchronousFileChannel 使用线程池模拟异步而非真正的内核 AIO。

### Q6: POSIX 文件锁有什么陷阱？

- 进程级别：同一进程内不同线程 lock 同一文件不互斥
- 进程退出或 close(fd) 自动释放所有锁
- `close(fd)` 释放的是整个文件上该进程持有的所有锁，即使通过 dup/fork 有多个 fd 指向同一文件
- NFS 上的文件锁不可靠

---

## 17. 源码文件交叉引用

| 文件 | 路径 | 行数 | 角色 |
|------|------|------|------|
| `FileChannelImpl.java` | `share/classes/sun/nio/ch/` | 1215 | 核心实现：read/write/transferTo/map/lock |
| `FileChannelImpl.c` | `unix/native/libnio/ch/` | 247 | map0(mmap)/unmap0(munmap)/transferTo0(sendfile)/initIDs |
| `FileDispatcherImpl.java` | `unix/classes/sun/nio/ch/` | 186 | Java 层调度器：read/pread/write/pwrite/readv/writev/force/seek/lock/release |
| `FileDispatcherImpl.c` | `unix/native/libnio/ch/` | 374 | JNI 实现：read→read/pread→pread64/writev→writev/force→fsync+fdatasync/lock→fcntl/preClose→dup2/setDirect→O_DIRECT |
| `FileDispatcher.java` | `share/classes/sun/nio/ch/` | 72 | 抽象基类：定义锁常量(NO_LOCK/LOCKED/RET_EX_LOCK) |
| `MappedByteBuffer.java` | `share/classes/java/nio/` | 283 | 内存映射缓冲区：isLoaded/load/force |
| `MappedByteBuffer.c` | `unix/native/libnio/` | 128 | isLoaded0→mincore/load0→madvise(WILLNEED)/force0→msync |
| `IOUtil.java` | `share/classes/sun/nio/ch/` | 449 | 读写核心逻辑：DirectBuffer直通 vs HeapBuffer中转；Scatter/Gather IOVecWrapper |
| `NativeThreadSet.java` | `share/classes/sun/nio/ch/` | 112 | 线程集合：add/remove/signalAndWait 用于中断阻塞I/O |
| `NativeDispatcher.java` | `share/classes/sun/nio/ch/` | 81 | 抽象基类：read/write/pread/pwrite/readv/writev |
