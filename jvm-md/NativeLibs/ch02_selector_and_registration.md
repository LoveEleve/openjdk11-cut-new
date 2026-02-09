# 第 2 章：Selector 继承体系与 Channel 注册机制

> **源码版本**：OpenJDK 11  
> **标准环境**：Linux x86_64  
> **前置依赖**：[第 1 章 epoll 底层机制](ch01_epoll_mechanism.md)

---

## 1. 问题引入

### 1.1 本章要回答的问题

1. `Selector.open()` 怎么在 Linux 上返回 `EPollSelectorImpl`？（Provider 机制）
2. `channel.register(selector, OP_READ)` 到底做了什么？从 Java 到 `epoll_ctl` 的完整链路？
3. `key.interestOps(OP_WRITE)` 修改感兴趣事件后，什么时候真正调用 `epoll_ctl(MOD)`？
4. `key.cancel()` 后怎么从 epoll 中移除 fd？
5. Java 的 `OP_READ/OP_WRITE/OP_CONNECT/OP_ACCEPT` 怎么翻译成内核的 `EPOLLIN/EPOLLOUT`？
6. 三个 key 集合（`keys` / `selectedKeys` / `cancelledKeys`）各自的职责和生命周期？

---

## 2. 类继承体系全景图

### 2.1 Selector 侧

```
java.nio.channels.Selector (抽象类)
  │
  │ 定义: open() / select() / wakeup() / keys() / selectedKeys()
  │
  └─→ java.nio.channels.spi.AbstractSelector (抽象类)
        │
        │ 新增: cancelledKeys 集合, begin()/end() 中断支持, cancel()/deregister()
        │
        └─→ sun.nio.ch.SelectorImpl (抽象类)
              │
              │ 新增: keys/selectedKeys 集合, lockAndDoSelect() 锁机制,
              │       processReadyEvents() 事件翻译, processDeregisterQueue()
              │       register() 创建 SelectionKeyImpl
              │
              ├─→ sun.nio.ch.EPollSelectorImpl (Linux)
              │     具体实现: epfd, pollArray, wakeup pipe, doSelect()/processUpdateQueue()
              │
              └─→ sun.nio.ch.PollSelectorImpl (通用 Unix fallback)
                    使用 poll() 系统调用
```

### 2.2 Channel 侧

```
java.nio.channels.Channel (接口)
  │
  └─→ java.nio.channels.SelectableChannel (抽象类)
        │
        │ 定义: register() / validOps() / configureBlocking()
        │
        └─→ java.nio.channels.spi.AbstractSelectableChannel (抽象类)
              │
              │ 新增: keys[] 数组管理, regLock/keyLock, register() 实现
              │
              ├─→ java.nio.channels.SocketChannel → SocketChannelImpl
              │     validOps() = OP_READ | OP_WRITE | OP_CONNECT
              │
              ├─→ java.nio.channels.ServerSocketChannel → ServerSocketChannelImpl
              │     validOps() = OP_ACCEPT
              │
              └─→ java.nio.channels.DatagramChannel → DatagramChannelImpl
                    validOps() = OP_READ | OP_WRITE
```

### 2.3 SelectionKey 侧

```
java.nio.channels.SelectionKey (抽象类)
  │
  │ 定义: OP_READ(1) / OP_WRITE(4) / OP_CONNECT(8) / OP_ACCEPT(16)
  │       interestOps() / readyOps() / attach() / cancel()
  │
  └─→ java.nio.channels.spi.AbstractSelectionKey
        │
        │ 新增: valid 标志, cancel() → selector.cancel(this)
        │
        └─→ sun.nio.ch.SelectionKeyImpl (final)
              │
              │ 新增: VarHandle INTERESTOPS (原子更新)
              │       registeredEvents (内核中注册的事件)
              │       translateInterestOps() / translateReadyOps()
              │       channel (SelChImpl) / selector (SelectorImpl)
              │
              └── 桥接: SelectionKeyImpl 持有 SelChImpl(channel) + SelectorImpl(selector)
```

### 2.4 桥接接口 SelChImpl

```java
// SelChImpl.java — Channel 与 Selector 交互的桥梁
public interface SelChImpl extends Channel {
    FileDescriptor getFD();
    int getFDVal();

    // native 事件 → Java readyOps
    boolean translateAndUpdateReadyOps(int ops, SelectionKeyImpl ski);
    boolean translateAndSetReadyOps(int ops, SelectionKeyImpl ski);

    // Java interestOps → native 事件
    int translateInterestOps(int ops);

    void kill() throws IOException;
}
```

**每个 Channel 实现类（SocketChannelImpl / ServerSocketChannelImpl / DatagramChannelImpl）都实现了 `SelChImpl` 接口**，提供自己的事件翻译逻辑。

---

## 3. Provider 机制 — Selector.open() 的创建链路

### 3.1 完整调用链

```
Selector.open()                                      // java.nio.channels.Selector
  │
  └→ SelectorProvider.provider()                     // java.nio.channels.spi.SelectorProvider
       │
       │  synchronized(lock)
       │  ① 检查系统属性 java.nio.channels.spi.SelectorProvider → 未设置
       │  ② ServiceLoader 查找 → 未找到
       │  ③ DefaultSelectorProvider.create()         // 平台特定
       │     └→ new EPollSelectorProvider()          // Linux
       │
       └→ provider.openSelector()                    // EPollSelectorProvider
            └→ new EPollSelectorImpl(this)           // 见第 1 章 §3.5
```

### 3.2 SelectorProviderImpl — Channel 工厂

```java
// SelectorProviderImpl.java — 所有平台的 Channel 创建共用此基类
public abstract class SelectorProviderImpl extends SelectorProvider {
    public DatagramChannel openDatagramChannel() throws IOException {
        return new DatagramChannelImpl(this);
    }
    public Pipe openPipe() throws IOException {
        return new PipeImpl(this);
    }
    public abstract AbstractSelector openSelector() throws IOException;  // 子类实现
    public ServerSocketChannel openServerSocketChannel() throws IOException {
        return new ServerSocketChannelImpl(this);
    }
    public SocketChannel openSocketChannel() throws IOException {
        return new SocketChannelImpl(this);
    }
}
```

| 方法 | 返回类型 | 实际创建 |
|------|---------|---------|
| `openSelector()` | AbstractSelector | `EPollSelectorImpl`（Linux）/ `KQueueSelectorImpl`（macOS） |
| `openSocketChannel()` | SocketChannel | `SocketChannelImpl`（所有平台共用） |
| `openServerSocketChannel()` | ServerSocketChannel | `ServerSocketChannelImpl`（所有平台共用） |
| `openDatagramChannel()` | DatagramChannel | `DatagramChannelImpl`（所有平台共用） |

**设计要点**：Selector 的创建是平台特定的（epoll/kqueue/poll），但 Channel 的创建是平台无关的。不同平台只是底层的 fd 操作（read/write/connect）不同，通过 `NativeDispatcher` 抽象解决。

---

## 4. Channel 注册流程 — register() 完整链路

### 4.1 用户代码

```java
// 典型用法
SocketChannel channel = SocketChannel.open();
channel.configureBlocking(false);          // 必须非阻塞
channel.connect(new InetSocketAddress("host", 80));
channel.register(selector, SelectionKey.OP_CONNECT);
```

### 4.2 AbstractSelectableChannel.register() — 注册入口

**源码文件**：`java/nio/channels/spi/AbstractSelectableChannel.java` L200-226

```java
// AbstractSelectableChannel.java L200-226
public final SelectionKey register(Selector sel, int ops, Object att)
    throws ClosedChannelException
{
    if ((ops & ~validOps()) != 0)                    // 检查 ops 是否在 validOps 范围内
        throw new IllegalArgumentException();
    if (!isOpen())
        throw new ClosedChannelException();
    synchronized (regLock) {                          // 锁 ①: 注册锁（阻塞模式变更也用此锁）
        if (isBlocking())
            throw new IllegalBlockingModeException(); // 必须非阻塞模式
        synchronized (keyLock) {                      // 锁 ②: key 数组锁
            if (!isOpen())
                throw new ClosedChannelException();
            SelectionKey k = findKey(sel);            // 在 channel 的 keys[] 中查找此 selector
            if (k != null) {
                // ---- 已注册：更新 ----
                k.attach(att);
                k.interestOps(ops);                   // 更新 interest ops → 触发 setEventOps
            } else {
                // ---- 新注册 ----
                k = ((AbstractSelector)sel).register(this, ops, att);  // 委托给 Selector
                addKey(k);                            // 加入 channel 的 keys[] 数组
            }
            return k;
        }
    }
}
```

#### 逐行注释表

| 行号 | 源码 | 行为 |
|------|------|------|
| L203 | `(ops & ~validOps()) != 0` | 校验：SocketChannel 的 validOps = `OP_READ\|OP_WRITE\|OP_CONNECT`(13)，如果传入 `OP_ACCEPT`(16) 就报错 |
| L207 | `synchronized(regLock)` | 注册锁：防止注册和 `configureBlocking()` 并发执行 |
| L208 | `isBlocking()` 检查 | **必须先调用 `configureBlocking(false)`**，否则抛 `IllegalBlockingModeException` |
| L210 | `synchronized(keyLock)` | key 数组锁：保护 `keys[]` 的并发修改 |
| L214 | `findKey(sel)` | 遍历 `keys[]` 找到 selector 对应的 key。一个 Channel 可以注册到多个 Selector |
| L216-217 | `k.attach(att); k.interestOps(ops)` | 已注册的情况：更新 attachment 和 interest ops |
| L220 | `sel.register(this, ops, att)` | **新注册**：委托给 Selector 的 register 方法 |
| L221 | `addKey(k)` | 将新 key 加入 channel 的 `keys[]` 数组 |

### 4.3 SelectorImpl.register() — 创建 SelectionKeyImpl

**源码文件**：`sun/nio/ch/SelectorImpl.java` L198-224

```java
// SelectorImpl.java L198-224
@Override
protected final SelectionKey register(AbstractSelectableChannel ch,
                                      int ops,
                                      Object attachment)
{
    if (!(ch instanceof SelChImpl))
        throw new IllegalSelectorException();
    SelectionKeyImpl k = new SelectionKeyImpl((SelChImpl)ch, this);   // 创建 key
    k.attach(attachment);

    // register (if needed) before adding to key set
    implRegister(k);                        // 子类可覆盖（EPollSelectorImpl 不覆盖，用默认的 ensureOpen）

    // add to the selector's key set
    keys.add(k);                            // 加入 Selector 的 keys 集合（ConcurrentHashMap.newKeySet）
    try {
        k.interestOps(ops);                 // 设置 interest ops → 触发 setEventOps
    } catch (ClosedSelectorException e) {
        assert ch.keyFor(this) == null;
        keys.remove(k);
        k.cancel();
        throw e;
    }
    return k;
}
```

#### 关键步骤分析

| 步骤 | 做什么 | 详细说明 |
|------|--------|---------|
| ① 创建 SelectionKeyImpl | `new SelectionKeyImpl(ch, this)` | key 持有 channel 和 selector 的引用 |
| ② implRegister | 默认实现：`ensureOpen()` | EPollSelectorImpl 没有覆盖此方法，不做额外操作 |
| ③ 加入 keys 集合 | `keys.add(k)` | keys 是 `ConcurrentHashMap.newKeySet()`，线程安全 |
| ④ 设置 interestOps | `k.interestOps(ops)` | 这一步触发 `setEventOps()`，将 key 加入 `updateKeys` 队列 |

### 4.4 SelectionKeyImpl.interestOps() — 触发延迟注册

```java
// SelectionKeyImpl.java L100-112
@Override
public SelectionKey interestOps(int ops) {
    ensureValid();
    if ((ops & ~channel().validOps()) != 0)
        throw new IllegalArgumentException();
    int oldOps = (int) INTERESTOPS.getAndSet(this, ops);   // CAS 原子更新 interestOps
    if (ops != oldOps) {
        selector.setEventOps(this);                         // ★ 通知 Selector
    }
    return this;
}
```

```java
// EPollSelectorImpl.java L242-247
@Override
public void setEventOps(SelectionKeyImpl ski) {
    ensureOpen();
    synchronized (updateLock) {
        updateKeys.addLast(ski);           // 加入待更新队列（不立即调用 epoll_ctl）
    }
}
```

**关键设计**：`interestOps()` 的修改不会立即调用 `epoll_ctl`，而是将 key 放入 `updateKeys` 队列。真正的 `epoll_ctl` 发生在下次 `select()` 调用时的 `processUpdateQueue()` 中（见第 1 章 §7.3）。

### 4.5 注册的完整时序图

```
用户线程                          Selector 内部                         Linux 内核
─────────                        ───────────                          ─────────

channel.register(selector, OP_READ, att)
  │
  ├→ AbstractSelectableChannel.register()
  │     synchronized(regLock)
  │     synchronized(keyLock)
  │     findKey(sel) → null (新注册)
  │
  ├→ SelectorImpl.register(ch, OP_READ, att)
  │     new SelectionKeyImpl(ch, this)       // 创建 key 对象
  │     keys.add(k)                          // 加入 keys 集合
  │     k.interestOps(OP_READ)
  │       │
  │       └→ INTERESTOPS.getAndSet(this, 1)  // CAS 设置 interestOps = 1
  │          selector.setEventOps(this)
  │            │
  │            └→ updateKeys.addLast(ski)     // 放入延迟队列
  │
  └→ return key                              // 此时 epoll_ctl 尚未调用！
                                              // fd 还没注册到内核的 epoll 红黑树中

... (稍后)

另一线程或同一线程:
selector.select()
  │
  └→ EPollSelectorImpl.doSelect()
       │
       ├→ processUpdateQueue()
       │     while ((ski = updateKeys.pollFirst()) != null)
       │       newEvents = translateInterestOps(OP_READ) → EPOLLIN (0x1)
       │       registeredEvents == 0 (首次注册)
       │       EPoll.ctl(epfd, EPOLL_CTL_ADD, fd, EPOLLIN)  ──→  epoll_ctl()  ✓ 注册到内核
       │       ski.registeredEvents(EPOLLIN)
       │
       └→ EPoll.wait(...)                    ──→  epoll_wait()  阻塞等待
```

> **注意**：从 `register()` 返回到 `epoll_ctl` 真正执行之间有时间间隔。在这个间隔内，fd 没有被内核监听。这就是为什么 register 后必须调用 `select()` 才能开始接收事件。

---

## 5. 三个 Key 集合的职责

### 5.1 集合定义

```java
// SelectorImpl 构造函数
protected SelectorImpl(SelectorProvider sp) {
    super(sp);
    keys = ConcurrentHashMap.newKeySet();               // ① key 集合
    selectedKeys = new HashSet<>();                      // ② selected-key 集合
    publicKeys = Collections.unmodifiableSet(keys);      // ③ 对外只读视图
    publicSelectedKeys = Util.ungrowableSet(selectedKeys); // ④ 对外：可 remove 不可 add
}

// AbstractSelector
private final Set<SelectionKey> cancelledKeys = new HashSet<>();  // ⑤ cancelled-key 集合
```

### 5.2 生命周期与状态转换

```
                          register()
                    ┌──────────────────┐
                    │                  ▼
               ┌─────────┐      ┌──────────┐
               │ (不存在) │      │   keys   │ ← 所有已注册的 key
               └─────────┘      └────┬─────┘
                                     │
                              select() 发现就绪
                                     │
                                     ▼
                              ┌──────────────┐
                              │ selectedKeys │ ← 有事件就绪的 key
                              └──────┬───────┘
                                     │
                              用户 iterator.remove()
                              或 selectedKeys.clear()
                                     │
                                     ▼
                              (从 selectedKeys 移除，
                               但仍在 keys 中)
                                     │
                              key.cancel()
                                     │
                                     ▼
                              ┌───────────────┐
                              │ cancelledKeys │ ← 已取消等待清理的 key
                              └───────┬───────┘
                                      │
                              下次 select() 时
                              processDeregisterQueue()
                                      │
                                      ▼
                              (从所有集合中移除，
                               epoll_ctl(DEL))
```

### 5.3 各集合详细说明

| 集合 | 类型 | 线程安全 | 写入时机 | 移除时机 |
|------|------|---------|---------|---------|
| `keys` | `ConcurrentHashMap.newKeySet()` | 是 | `register()` 时 `keys.add(k)` | `processDeregisterQueue()` 中 `keys.remove(ski)` |
| `selectedKeys` | `HashSet` | 否（需锁） | `processReadyEvents()` 中 `selectedKeys.add(ski)` | 用户手动 `iterator.remove()` 或 `processDeregisterQueue()` |
| `cancelledKeys` | `HashSet` | synchronized | `key.cancel()` → `selector.cancel(this)` | `processDeregisterQueue()` 中 `i.remove()` |

> **重要**：`selectedKeys` 不是线程安全的！用户代码遍历 `selectedKeys` 时如果其他线程修改了它，会抛 `ConcurrentModificationException`。必须在 `synchronized(selector)` 或者单线程中操作。

---

## 6. SelectionKey 的 Interest Ops 与 Ready Ops

### 6.1 四个操作常量

```java
// SelectionKey.java
public static final int OP_READ    = 1 << 0;   // 1   (0x01)  可读
public static final int OP_WRITE   = 1 << 2;   // 4   (0x04)  可写
public static final int OP_CONNECT = 1 << 3;   // 8   (0x08)  连接完成
public static final int OP_ACCEPT  = 1 << 4;   // 16  (0x10)  有新连接
```

**为什么跳过 `1 << 1` (2)？** 这是 Java 1.4 NIO 设计时预留的位置，可能是为了将来扩展（但从未使用过）。

### 6.2 每种 Channel 的 validOps

| Channel 类型 | validOps() | 含义 |
|-------------|-----------|------|
| `SocketChannel` | `OP_READ \| OP_WRITE \| OP_CONNECT` = 13 | TCP 客户端：读、写、连接 |
| `ServerSocketChannel` | `OP_ACCEPT` = 16 | TCP 服务端：接受新连接 |
| `DatagramChannel` | `OP_READ \| OP_WRITE` = 5 | UDP：读、写 |

### 6.3 interestOps 与 readyOps 的关系

- **interestOps**：用户告诉 Selector "我对这个 Channel 的哪些事件感兴趣"
- **readyOps**：Selector 告诉用户 "这个 Channel 的哪些事件已经就绪"
- **readyOps 永远是 interestOps 的子集**：只有用户感兴趣的事件才会报告

```
interestOps = OP_READ | OP_WRITE     (用户设置)
                 ↓
         translateInterestOps()
                 ↓
epoll events = EPOLLIN | EPOLLOUT    (注册到内核)
                 ↓
         epoll_wait() 返回
                 ↓
native events = EPOLLIN              (内核报告：只有可读)
                 ↓
         translateReadyOps()
                 ↓
readyOps = OP_READ                   (返回给用户)
```

### 6.4 SelectionKeyImpl 中的原子更新

```java
// SelectionKeyImpl.java
private static final VarHandle INTERESTOPS =
        ConstantBootstraps.fieldVarHandle(
                MethodHandles.lookup(),
                "interestOps",
                VarHandle.class,
                SelectionKeyImpl.class, int.class);

private volatile int interestOps;       // 用户设置的感兴趣事件（volatile + VarHandle 原子操作）
private volatile int readyOps;          // Selector 设置的就绪事件

private int registeredEvents;           // 当前在内核 epoll 中注册的事件（非 volatile，只在 Selector 锁内访问）
```

**三个 ops 的区别**：

| 字段 | 谁写 | 谁读 | 线程安全 | 含义 |
|------|------|------|---------|------|
| `interestOps` | 用户线程（CAS） | select 线程 | volatile + VarHandle | 用户想监听什么事件 |
| `readyOps` | select 线程 | 用户线程 | volatile | 内核报告了什么事件 |
| `registeredEvents` | select 线程 | select 线程 | 不需要（锁保护） | 内核 epoll 中实际注册的事件 |

---

## 7. 事件翻译机制 — Java ↔ Native 双向映射

### 7.1 POLL 常量的来源

```java
// Net.java — poll 事件常量
public static final short POLLIN;       // 通过 JNI 获取
public static final short POLLOUT;
public static final short POLLERR;
public static final short POLLHUP;
public static final short POLLNVAL;
public static final short POLLCONN;

static {
    IOUtil.load();
    initIDs();
    POLLIN     = pollinValue();     // → Net.c → return POLLIN;   (Linux: 0x01)
    POLLOUT    = polloutValue();    // → Net.c → return POLLOUT;  (Linux: 0x04)
    POLLERR    = pollerrValue();    // → Net.c → return POLLERR;  (Linux: 0x08)
    POLLHUP    = pollhupValue();    // → Net.c → return POLLHUP;  (Linux: 0x10)
    POLLNVAL   = pollnvalValue();   // → Net.c → return POLLNVAL; (Linux: 0x20)
    POLLCONN   = pollconnValue();   // → Net.c → return POLLOUT;  (= POLLOUT!)
}
```

**关键发现**：`POLLCONN` 的值就是 `POLLOUT`！在 `Net.c` 中：

```c
// Net.c L773-777
JNIEXPORT jshort JNICALL
Java_sun_nio_ch_Net_pollconnValue(JNIEnv *env, jclass this)
{
    return (jshort)POLLOUT;    // POLLCONN == POLLOUT
}
```

**原因**：TCP 非阻塞 `connect()` 完成时，内核通过 POLLOUT 事件通知（socket 变为可写 = 连接建立完成）。所以 `POLLCONN` 本质上就是 `POLLOUT`。

### 7.2 translateInterestOps — Java → Native

每个 Channel 实现提供自己的翻译逻辑：

#### SocketChannel（TCP 客户端）

```java
// SocketChannelImpl.java L1057-1066
public int translateInterestOps(int ops) {
    int newOps = 0;
    if ((ops & SelectionKey.OP_READ) != 0)      // 1
        newOps |= Net.POLLIN;                   // 0x01
    if ((ops & SelectionKey.OP_WRITE) != 0)     // 4
        newOps |= Net.POLLOUT;                  // 0x04
    if ((ops & SelectionKey.OP_CONNECT) != 0)   // 8
        newOps |= Net.POLLCONN;                 // 0x04 (= POLLOUT)
    return newOps;
}
```

#### ServerSocketChannel（TCP 服务端）

```java
// ServerSocketChannelImpl.java L488-493
public int translateInterestOps(int ops) {
    int newOps = 0;
    if ((ops & SelectionKey.OP_ACCEPT) != 0)    // 16
        newOps |= Net.POLLIN;                   // 0x01
    return newOps;
}
```

#### DatagramChannel（UDP）

```java
// DatagramChannelImpl.java L1301-1307
public int translateInterestOps(int ops) {
    int newOps = 0;
    if ((ops & SelectionKey.OP_READ) != 0)      // 1
        newOps |= Net.POLLIN;                   // 0x01
    if ((ops & SelectionKey.OP_WRITE) != 0)     // 4
        newOps |= Net.POLLOUT;                  // 0x04
    return newOps;
}
```

#### 映射汇总表

| Java 常量 | 值 | SocketChannel | ServerSocketChannel | DatagramChannel | 对应 epoll 事件 |
|----------|---|:---:|:---:|:---:|---|
| `OP_READ` | 1 | `POLLIN`(0x01) | — | `POLLIN`(0x01) | `EPOLLIN` |
| `OP_WRITE` | 4 | `POLLOUT`(0x04) | — | `POLLOUT`(0x04) | `EPOLLOUT` |
| `OP_CONNECT` | 8 | `POLLCONN`(0x04) | — | — | `EPOLLOUT` |
| `OP_ACCEPT` | 16 | — | `POLLIN`(0x01) | — | `EPOLLIN` |

> **易混淆点**：`OP_CONNECT` 和 `OP_WRITE` 都映射到 `EPOLLOUT`，`OP_ACCEPT` 和 `OP_READ` 都映射到 `EPOLLIN`。区分它们靠的是反向翻译时的 Channel 状态判断。

### 7.3 translateReadyOps — Native → Java

当 `epoll_wait` 返回后，需要把 native 事件翻译回 Java 的 readyOps。

#### SocketChannel 的翻译逻辑

```java
// SocketChannelImpl.java L1011-1044
public boolean translateReadyOps(int ops, int initialOps, SelectionKeyImpl ski) {
    int intOps = ski.nioInterestOps();     // 用户感兴趣的事件
    int oldOps = ski.nioReadyOps();        // 之前的 readyOps
    int newOps = initialOps;               // 初始值（Set=0, Update=oldOps）

    // ---- 异常情况 ----
    if ((ops & Net.POLLNVAL) != 0)         // fd 无效
        return false;

    if ((ops & (Net.POLLERR | Net.POLLHUP)) != 0) {  // 错误或对端关闭
        newOps = intOps;                   // 所有感兴趣的事件都标记就绪
        ski.nioReadyOps(newOps);           // (这样用户任何操作都会发现错误)
        return (newOps & ~oldOps) != 0;
    }

    // ---- 正常情况 ----
    boolean connected = isConnected();

    if (((ops & Net.POLLIN) != 0) &&       // 内核报告可读
        ((intOps & SelectionKey.OP_READ) != 0) &&  // 用户关心读
        connected)                          // 且已连接
        newOps |= SelectionKey.OP_READ;

    if (((ops & Net.POLLCONN) != 0) &&     // 内核报告 POLLOUT
        ((intOps & SelectionKey.OP_CONNECT) != 0) && // 用户关心连接
        isConnectionPending())              // 且正在连接中
        newOps |= SelectionKey.OP_CONNECT;

    if (((ops & Net.POLLOUT) != 0) &&      // 内核报告可写
        ((intOps & SelectionKey.OP_WRITE) != 0) && // 用户关心写
        connected)                          // 且已连接
        newOps |= SelectionKey.OP_WRITE;

    ski.nioReadyOps(newOps);
    return (newOps & ~oldOps) != 0;        // 是否有新增的就绪事件
}
```

**区分 OP_CONNECT 和 OP_WRITE 的关键**：虽然两者都对应 `EPOLLOUT`，但翻译时通过 Channel 状态区分：
- `isConnectionPending()` = true → `OP_CONNECT`（连接建立完成）
- `isConnected()` = true → `OP_WRITE`（可以写数据了）

#### ServerSocketChannel 的翻译逻辑

```java
// ServerSocketChannelImpl.java L451-493
// 更简单：POLLIN → OP_ACCEPT
if (((ops & Net.POLLIN) != 0) &&
    ((intOps & SelectionKey.OP_ACCEPT) != 0))
    newOps |= SelectionKey.OP_ACCEPT;
```

### 7.4 翻译流程汇总图

```
epoll_wait 返回 events:

native events        Channel 状态             Java readyOps
─────────────        ─────────────            ─────────────

EPOLLIN  ─────┬── SocketChannel + connected ──→ OP_READ
              │
              └── ServerSocketChannel ────────→ OP_ACCEPT

EPOLLOUT ─────┬── SocketChannel + pending ────→ OP_CONNECT
              │
              └── SocketChannel + connected ──→ OP_WRITE

EPOLLERR ─────── 任意 Channel ────────────────→ intOps (全部标记就绪)
EPOLLHUP ─────── 任意 Channel ────────────────→ intOps (全部标记就绪)
```

---

## 8. Key 取消与反注册

### 8.1 cancel() 流程

```java
// AbstractSelectionKey.java L66-76
public final void cancel() {
    synchronized (this) {              // 防止多线程重复 cancel
        if (valid) {
            valid = false;             // 标记为无效
            ((AbstractSelector)selector()).cancel(this);  // 加入 cancelledKeys
        }
    }
}

// AbstractSelector.java
void cancel(SelectionKey k) {
    synchronized (cancelledKeys) {
        cancelledKeys.add(k);          // 放入取消集合（不立即处理）
    }
}
```

### 8.2 processDeregisterQueue() — 真正的反注册

```java
// SelectorImpl.java L244-271
protected final void processDeregisterQueue() throws IOException {
    assert Thread.holdsLock(this);
    assert Thread.holdsLock(publicSelectedKeys);

    Set<SelectionKey> cks = cancelledKeys();
    synchronized (cks) {
        if (!cks.isEmpty()) {
            Iterator<SelectionKey> i = cks.iterator();
            while (i.hasNext()) {
                SelectionKeyImpl ski = (SelectionKeyImpl)i.next();
                i.remove();                      // 从 cancelledKeys 移除

                implDereg(ski);                   // ★ 子类实现：从 epoll 移除 fd

                selectedKeys.remove(ski);         // 从 selectedKeys 移除
                keys.remove(ski);                 // 从 keys 移除

                deregister(ski);                  // 从 channel 的 keys[] 中移除

                SelectableChannel ch = ski.channel();
                if (!ch.isOpen() && !ch.isRegistered())
                    ((SelChImpl)ch).kill();        // channel 已关闭且无注册 → 清理资源
            }
        }
    }
}
```

### 8.3 EPollSelectorImpl.implDereg() — 调用 epoll_ctl(DEL)

```java
// EPollSelectorImpl.java L226-239
@Override
protected void implDereg(SelectionKeyImpl ski) throws IOException {
    assert !ski.isValid();
    assert Thread.holdsLock(this);

    int fd = ski.getFDVal();
    if (fdToKey.remove(fd) != null) {          // 从 fd→key 映射表移除
        if (ski.registeredEvents() != 0) {
            EPoll.ctl(epfd, EPOLL_CTL_DEL, fd, 0);  // ★ 从 epoll 移除
            ski.registeredEvents(0);
        }
    } else {
        assert ski.registeredEvents() == 0;
    }
}
```

### 8.4 取消注册的完整时序

```
用户线程                          Selector 内部                     Linux 内核
─────────                        ───────────                      ─────────

key.cancel()
  │
  ├→ valid = false
  └→ cancelledKeys.add(key)       // 放入取消集合
                                  // 此时 fd 仍在 epoll 中！

... (稍后)

selector.select()
  │
  └→ doSelect()
       ├→ processDeregisterQueue()
       │     ski = cancelledKeys.next()
       │     implDereg(ski)
       │       fdToKey.remove(fd)
       │       EPoll.ctl(epfd, EPOLL_CTL_DEL, fd, 0) ──→ epoll_ctl(DEL) ✓ 从内核移除
       │       ski.registeredEvents(0)
       │     selectedKeys.remove(ski)
       │     keys.remove(ski)
       │     deregister(ski)           // 从 channel.keys[] 移除
       │
       ├→ EPoll.wait(...)              // 此时 fd 已不在 epoll 中
       │
       └→ processDeregisterQueue()     // 再处理一次（阻塞期间可能有新取消）
```

---

## 9. begin()/end() — 中断机制

### 9.1 问题

线程阻塞在 `selector.select()` 中（即 `epoll_wait` 中），如果其他线程调用 `thread.interrupt()`，如何让 select 返回？

### 9.2 AbstractSelector.begin()

```java
// AbstractSelector.java
private Interruptible interruptor = null;

protected final void begin() {
    if (interruptor == null) {
        interruptor = new Interruptible() {
            public void interrupt(Thread ignore) {
                AbstractSelector.this.wakeup();     // 中断 → wakeup
            }
        };
    }
    AbstractInterruptibleChannel.blockedOn(interruptor);  // 注册中断回调
    Thread me = Thread.currentThread();
    if (me.isInterrupted())
        interruptor.interrupt(me);                  // 如果已经被中断，立即 wakeup
}

protected final void end() {
    AbstractInterruptibleChannel.blockedOn(null);   // 取消中断回调
}
```

**机制**：
1. `begin()` 注册一个中断回调：当线程被 `interrupt()` 时，自动调用 `selector.wakeup()`
2. `wakeup()` 向 pipe 写 1 字节 → `epoll_wait` 返回
3. `end()` 取消中断回调

```
线程 A (select)                     线程 B
─────────────                      ─────────
begin()
  → 注册 interruptor
epoll_wait(...)
  ← 阻塞中                         thread_A.interrupt()
                                     │
                                     └→ interruptor.interrupt()
                                          └→ selector.wakeup()
                                               └→ write(fd1, 1 byte)
  ← epoll_wait 返回 (pipe 可读)
end()
  → 取消 interruptor
```

---

## 10. 并发模型总结

### 10.1 锁的层次

```
锁获取顺序（必须严格遵循，否则死锁）：
  ① selector (this)
  ② publicSelectedKeys
  ③ cancelledKeys
  ④ updateLock
  ⑤ interruptLock
  ⑥ channel.regLock
  ⑦ channel.keyLock
```

### 10.2 哪些操作是线程安全的

| 操作 | 线程安全 | 说明 |
|------|---------|------|
| `selector.select()` | 不支持并发 | `synchronized(this)` + `inSelect` 标志禁止重入 |
| `selector.wakeup()` | 安全 | `synchronized(interruptLock)` + 去重标志 |
| `key.interestOps(ops)` | 安全 | VarHandle CAS 原子更新 + updateKeys 队列 |
| `key.readyOps()` | 安全 | volatile 读 |
| `key.cancel()` | 安全 | `synchronized(this)` + cancelledKeys 队列 |
| `channel.register()` | 安全 | `synchronized(regLock)` + `synchronized(keyLock)` |
| `keys()` 遍历 | 安全 | ConcurrentHashMap.newKeySet() |
| `selectedKeys()` 遍历 | **不安全** | 普通 HashSet，必须用户自己同步 |

### 10.3 生产者-消费者模型

```
生产者（任意线程）              队列                消费者（select 线程）
───────────────              ────                ──────────────────

key.interestOps(ops)                             doSelect()
  → setEventOps(ski)                               processUpdateQueue()
    → updateKeys.addLast(ski) ─→ updateKeys ─→      updateKeys.pollFirst()
                                                    EPoll.ctl(ADD/MOD/DEL)

key.cancel()                                     doSelect()
  → cancelledKeys.add(k) ──→ cancelledKeys ──→     processDeregisterQueue()
                                                    EPoll.ctl(DEL)
```

---

## 11. 面试常见问题

### Q1: channel.register(selector, OP_READ) 时，fd 是否立即注册到 epoll？

**答**：不是。`register()` 只创建 `SelectionKeyImpl` 对象并加入 `updateKeys` 队列。真正的 `epoll_ctl(EPOLL_CTL_ADD)` 发生在下次 `select()` 调用的 `processUpdateQueue()` 中。这是一种延迟注册的设计，好处是：
1. 避免在 `register()` 调用线程中直接调用系统调用
2. 可以批量合并多次注册/修改操作
3. 避免 `epoll_ctl` 和 `epoll_wait` 的并发问题

### Q2: 为什么 OP_CONNECT 和 OP_WRITE 都对应 EPOLLOUT？怎么区分？

**答**：在 Linux 内核层面，TCP 非阻塞 `connect()` 完成时触发 EPOLLOUT（socket 变为可写）。JDK 在翻译时通过 Channel 状态区分：
- `isConnectionPending()` = true → 映射为 `OP_CONNECT`（连接刚建立）
- `isConnected()` = true → 映射为 `OP_WRITE`（已连接，可以写）

### Q3: selector.selectedKeys() 为什么不是线程安全的？

**答**：`selectedKeys` 是普通 `HashSet`，不是线程安全集合。设计者认为 `selectedKeys` 只在 `select()` 调用期间（持有 `synchronized(publicSelectedKeys)` 锁）和用户处理事件时访问，不需要并发支持。用户如果需要多线程访问 `selectedKeys`，需要自己加 `synchronized(selector.selectedKeys())` 同步。

### Q4: 一个 Channel 可以注册到多个 Selector 吗？

**答**：可以。`AbstractSelectableChannel` 内部维护一个 `SelectionKey[] keys` 数组，每个 Selector 对应一个 key。调用 `findKey(sel)` 在数组中查找。但实际使用中很少这样做，因为一个 Channel 在多个 Selector 之间共享会增加复杂度。

### Q5: key.cancel() 后 fd 是否立即从 epoll 移除？

**答**：不是。`cancel()` 只把 key 加入 `cancelledKeys` 集合并标记为无效。真正的 `epoll_ctl(EPOLL_CTL_DEL)` 发生在下次 `select()` 的 `processDeregisterQueue()` 中。在此期间，fd 仍然在内核的 epoll 红黑树中，可能还会收到事件。

---

## 12. 涉及的源码文件清单

| 文件 | 路径 | 作用 |
|------|------|------|
| `Selector.java` | `java/nio/channels/Selector.java` | 顶层抽象类，定义 open()/select()/wakeup() |
| `AbstractSelector.java` | `java/nio/channels/spi/AbstractSelector.java` | cancelledKeys 集合，begin()/end() 中断机制 |
| `SelectorImpl.java` | `sun/nio/ch/SelectorImpl.java` | keys/selectedKeys 集合，锁机制，processReadyEvents |
| `EPollSelectorImpl.java` | `sun/nio/ch/EPollSelectorImpl.java` | epoll 封装，doSelect/processUpdateQueue/implDereg |
| `SelectorProvider.java` | `java/nio/channels/spi/SelectorProvider.java` | provider() 查找机制 |
| `SelectorProviderImpl.java` | `sun/nio/ch/SelectorProviderImpl.java` | Channel 工厂基类 |
| `EPollSelectorProvider.java` | `sun/nio/ch/EPollSelectorProvider.java` | Linux 平台：openSelector → EPollSelectorImpl |
| `DefaultSelectorProvider.java` | `sun/nio/ch/DefaultSelectorProvider.java` | Linux 平台绑定 |
| `SelectableChannel.java` | `java/nio/channels/SelectableChannel.java` | Channel 抽象基类 |
| `AbstractSelectableChannel.java` | `java/nio/channels/spi/AbstractSelectableChannel.java` | register() 实现，keys[] 管理 |
| `SelectionKey.java` | `java/nio/channels/SelectionKey.java` | OP_READ/WRITE/CONNECT/ACCEPT 常量 |
| `AbstractSelectionKey.java` | `java/nio/channels/spi/AbstractSelectionKey.java` | valid 标志，cancel() |
| `SelectionKeyImpl.java` | `sun/nio/ch/SelectionKeyImpl.java` | interestOps/readyOps/registeredEvents，VarHandle CAS |
| `SelChImpl.java` | `sun/nio/ch/SelChImpl.java` | Channel↔Selector 桥接接口 |
| `SocketChannelImpl.java` | `sun/nio/ch/SocketChannelImpl.java` | translateInterestOps/translateReadyOps |
| `ServerSocketChannelImpl.java` | `sun/nio/ch/ServerSocketChannelImpl.java` | OP_ACCEPT → POLLIN 翻译 |
| `DatagramChannelImpl.java` | `sun/nio/ch/DatagramChannelImpl.java` | OP_READ/WRITE 翻译 |
| `Net.java` | `sun/nio/ch/Net.java` | POLLIN/POLLOUT/POLLCONN 常量（JNI 获取） |
| `Net.c` | `unix/native/libnio/ch/Net.c` | pollinValue()/pollconnValue() 等 native 实现 |
| `EPoll.java` | `sun/nio/ch/EPoll.java` | epoll 系统调用 Java 包装 |
