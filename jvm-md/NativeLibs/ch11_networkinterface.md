# 第 11 章：NetworkInterface — 网卡枚举

> 源码基线：OpenJDK 11，Linux x86_64
> 核心文件：`NetworkInterface.c` (2173行) + `NetworkInterface.java` (639行)

---

## 11.1 本章定位

`NetworkInterface.getNetworkInterfaces()` 是 Java 中获取本机网络接口信息的唯一标准 API。看似简单的一个调用，背后涉及：

1. **双协议栈枚举**：先 `ioctl(SIOCGIFCONF)` 枚举所有 IPv4 接口，再读 `/proc/net/if_inet6` 获取 IPv6 地址
2. **虚拟子接口处理**：`eth0:1` 这种冒号记法的逻辑接口，需要拆分为父子关系树
3. **C→Java 对象构建**：C 层的 `netif` 链表转换为 Java 层的 `NetworkInterface[]` 数组
4. **MAC 地址获取**：`ioctl(SIOCGIFHWADDR)` 获取硬件地址
5. **跨平台差异**：Linux/AIX/Solaris/BSD 四套完全不同的实现

**为什么重要？**

- 服务发现（如 Dubbo/Eureka 注册本机 IP）的底层依赖
- 容器/K8s 环境下网卡枚举异常是常见故障
- `InetAddress.getLocalHost()` 内部也依赖网卡枚举做 DNS 解析
- MAC 地址常用于生成分布式 ID（如 Snowflake 的 workerId）

---

## 11.2 Java 层类结构

```
NetworkInterface (java.net)
├── name: String          // 接口名, 如 "eth0"
├── displayName: String   // 显示名, Linux 上 = name
├── index: int            // 接口索引, 如 2
├── addrs: InetAddress[]  // 该接口绑定的所有 IP 地址
├── bindings: InterfaceAddress[]  // 地址+子网掩码+广播地址
├── childs: NetworkInterface[]    // 虚拟子接口, 如 eth0:1
├── parent: NetworkInterface      // 父接口引用
├── virtual: boolean              // 是否虚拟子接口
└── defaultIndex: static int      // 默认接口索引

InterfaceAddress (java.net)
├── address: InetAddress          // IP 地址
├── broadcast: Inet4Address       // 广播地址 (仅 IPv4)
└── maskLength: short             // 子网掩码长度, 如 24
```

**核心 native 方法一览：**

```java
// NetworkInterface.java 中声明的 native 方法
private static native NetworkInterface[] getAll();           // 枚举所有接口
private static native NetworkInterface getByName0(String name);  // 按名称查找
private static native NetworkInterface getByIndex0(int index);   // 按索引查找
private static native NetworkInterface getByInetAddress0(InetAddress addr); // 按地址查找

private static native boolean isUp0(String name, int ind);             // 是否启用
private static native boolean isLoopback0(String name, int ind);       // 是否回环
private static native boolean supportsMulticast0(String name, int ind); // 是否支持多播
private static native boolean isP2P0(String name, int ind);            // 是否点对点
private static native byte[] getMacAddr0(byte[] inAddr, String name, int ind); // MAC 地址
private static native int getMTU0(String name, int ind);               // MTU 值
```

---

## 11.3 C 层核心数据结构

`NetworkInterface.c` 定义了两个 C 结构体，它们是整个网卡枚举的核心：

### 11.3.1 `netaddr` — 地址节点

```c
// NetworkInterface.c 第 79-85 行
typedef struct _netaddr {
    struct sockaddr *addr;       // IP 地址 (sockaddr_in 或 sockaddr_in6)
    struct sockaddr *brdcast;    // 广播地址 (仅 IPv4, IPv6 为 NULL)
    short mask;                  // 子网前缀长度, 如 24
    int family;                  // AF_INET 或 AF_INET6
    struct _netaddr *next;       // 链表下一个地址
} netaddr;
```

### 11.3.2 `netif` — 接口节点

```c
// NetworkInterface.c 第 87-94 行
typedef struct _netif {
    char *name;                  // 接口名 (指向 netif 结构体尾部)
    int index;                   // 接口索引 (来自 ioctl SIOCGIFINDEX)
    char virtual;                // 是否虚拟子接口 (0 或 1)
    netaddr *addr;               // 地址链表 (一个接口可绑定多个 IP)
    struct _netif *childs;       // 虚拟子接口链表 (如 eth0:1, eth0:2)
    struct _netif *next;         // 下一个接口
} netif;
```

### 11.3.3 内存布局

这两个结构体的内存分配策略非常巧妙——都采用**一次 malloc 连续分配**：

```
┌─────────────────────────────────────────────────────┐
│ netif 节点的内存布局 (sizeof(netif) + IFNAMESIZE)    │
│                                                      │
│ ┌──────────────────────────────────────┐             │
│ │ netif 结构体 (约 40 bytes on x86_64) │             │
│ │  name ──────────────┐                │             │
│ │  index              │                │             │
│ │  virtual            │                │             │
│ │  addr → netaddr链表  │               │             │
│ │  childs → 子接口链表  │               │             │
│ │  next → 下一个接口    │               │             │
│ └──────────────────────┼───────────────┘             │
│ ┌──────────────────────▼───────────────┐             │
│ │ name 字符串 (IFNAMESIZE = 16 bytes)  │             │
│ │ "eth0\0..."                          │             │
│ └──────────────────────────────────────┘             │
└─────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────┐
│ netaddr 节点的内存布局                                │
│ (sizeof(netaddr) + 2 * addr_size)                    │
│                                                       │
│ ┌──────────────────────────────────────┐              │
│ │ netaddr 结构体 (约 32 bytes)         │              │
│ │  addr ──────────────────┐            │              │
│ │  brdcast ───────────────┼───┐        │              │
│ │  mask                   │   │        │              │
│ │  family                 │   │        │              │
│ │  next                   │   │        │              │
│ └─────────────────────────┼───┼────────┘              │
│ ┌─────────────────────────▼───┼────────┐              │
│ │ sockaddr_in (16B) 或        │        │              │
│ │ sockaddr_in6 (28B)          │        │              │
│ │ → IP 地址                   │        │              │
│ └─────────────────────────────┼────────┘              │
│ ┌─────────────────────────────▼────────┐              │
│ │ sockaddr_in (16B) 或                  │              │
│ │ sockaddr_in6 (28B)                    │              │
│ │ → 广播地址 (IPv4) / 未使用 (IPv6)     │              │
│ └──────────────────────────────────────┘              │
└──────────────────────────────────────────────────────┘
```

对应源码：

```c
// netif 分配: NetworkInterface.c 第 959-960 行
CHECKED_MALLOC3(currif, netif *, sizeof(netif) + IFNAMESIZE);
currif->name = (char *)currif + sizeof(netif);  // name 指向结构体尾部

// netaddr 分配: NetworkInterface.c 第 910-912 行
addr_size = (family == AF_INET) ? sizeof(struct sockaddr_in)
                                : sizeof(struct sockaddr_in6);
CHECKED_MALLOC3(addrP, netaddr *, sizeof(netaddr) + 2 * addr_size);
addrP->addr = (struct sockaddr *)((char *)addrP + sizeof(netaddr));  // addr 紧跟结构体
```

**为什么这样设计？** 减少 `malloc` 调用次数。一个典型系统有 5-10 个接口，每个接口有 2-3 个地址，如果每个指针字段单独 malloc 就需要 30+ 次分配。这种"结构体 + 尾部数据"的模式在 JVM/Linux 内核中非常常见。

### 11.3.4 `CHECKED_MALLOC3` 宏

```c
// NetworkInterface.c 第 70-77 行
#define CHECKED_MALLOC3(_pointer, _type, _size) \
    do { \
        _pointer = (_type)malloc(_size); \
        if (_pointer == NULL) { \
            JNU_ThrowOutOfMemoryError(env, "Native heap allocation failed"); \
            return ifs; /* return untouched list — 不丢弃已枚举的接口 */ \
        } \
    } while(0)
```

注意 OOM 时 `return ifs` 而非 `return NULL`——这是**部分结果优于无结果**的设计理念。

---

## 11.4 JNI 字段 ID 缓存 — init()

`NetworkInterface.init()` 在类加载时被调用，一次性缓存所有 JNI 字段 ID。这是 JNI 编程的标准模式，避免每次调用 `GetFieldID()` 的反射开销。

```c
// NetworkInterface.c 第 161-209 行
JNIEXPORT void JNICALL Java_java_net_NetworkInterface_init(JNIEnv *env, jclass cls) {
    // NetworkInterface 类 — 9 个字段
    ni_class         // 全局引用
    ni_nameID        // "name"         : String
    ni_indexID       // "index"        : int
    ni_descID        // "displayName"  : String
    ni_addrsID       // "addrs"        : InetAddress[]
    ni_bindsID       // "bindings"     : InterfaceAddress[]
    ni_virutalID     // "virtual"      : boolean  ← 注意源码中的拼写错误！
    ni_childsID      // "childs"       : NetworkInterface[]
    ni_parentID      // "parent"       : NetworkInterface
    ni_ctrID         // "<init>"()V    : 构造方法
    ni_defaultIndexID // "defaultIndex" : static int

    // InterfaceAddress 类 — 4 个字段
    ni_ibcls          // 全局引用
    ni_ibctrID        // "<init>"()V   : 构造方法
    ni_ibaddressID    // "address"     : InetAddress
    ni_ib4broadcastID // "broadcast"   : Inet4Address
    ni_ib4maskID      // "maskLength"  : short

    // 最后调用 initInetAddressIDs(env) 初始化 InetAddress 相关字段
}
```

**共计 16 个 JNI ID**（11 个 NetworkInterface + 5 个 InterfaceAddress），加上 `initInetAddressIDs()` 继续缓存 `InetAddress`/`Inet4Address`/`Inet6Address` 的字段。

> 源码中 `ni_virutalID` 拼写为 "virtu**a**l" 而非 "virtu**a**l"——这是一个未修复的 typo（变量名写成了 virut**al**，但字段名 `"virtual"` 是正确的）。

---

## 11.5 枚举核心 — enumInterfaces()

**这是整个文件最核心的函数**，所有查询方法（`getAll`、`getByName0`、`getByIndex0`、`getByInetAddress0`）都以它为起点。

### 11.5.1 总体流程

```c
// NetworkInterface.c 第 816-854 行
static netif *enumInterfaces(JNIEnv *env) {
    netif *ifs = NULL;
    int sock;

    // 阶段一：枚举 IPv4 接口
    sock = openSocket(env, AF_INET);
    ifs = enumIPv4Interfaces(env, sock, NULL);  // ifs 初始为 NULL
    close(sock);

    // 阶段二：枚举 IPv6 接口（仅当 IPv6 可用时）
    if (ipv6_available()) {
        sock = openSocket(env, AF_INET6);
        ifs = enumIPv6Interfaces(env, sock, ifs);  // 传入阶段一的结果！
        close(sock);
    }

    return ifs;
}
```

**关键设计**：两阶段枚举，IPv6 阶段把 IPv4 阶段的结果传入。这意味着同一个物理接口（如 `eth0`）上的 IPv4 和 IPv6 地址会被合并到**同一个 `netif` 节点**中。

```
调用链路图：
enumInterfaces()
  │
  ├─ openSocket(AF_INET)        → socket(AF_INET, SOCK_DGRAM, 0)
  ├─ enumIPv4Interfaces(sock, NULL)
  │   ├─ ioctl(SIOCGIFCONF, NULL)  → 获取缓冲区大小
  │   ├─ ioctl(SIOCGIFCONF, buf)   → 获取所有 IPv4 接口
  │   └─ 遍历 ifreq[] → addif() 每个接口
  ├─ close(sock)
  │
  ├─ openSocket(AF_INET6)       → socket(AF_INET6, SOCK_DGRAM, 0)
  ├─ enumIPv6Interfaces(sock, ifs)  ← 传入 IPv4 结果
  │   ├─ fopen("/proc/net/if_inet6")
  │   └─ fscanf 逐行解析 → addif() 每个地址
  └─ close(sock)
```

### 11.5.2 enumIPv4Interfaces — Linux 实现

```c
// NetworkInterface.c 第 1134-1211 行
static netif *enumIPv4Interfaces(JNIEnv *env, int sock, netif *ifs) {
    struct ifconf ifc;

    // 第一次 ioctl: ifc_buf=NULL → 内核返回所需缓冲区大小到 ifc_len
    ifc.ifc_buf = NULL;
    ioctl(sock, SIOCGIFCONF, &ifc);

    // 分配缓冲区, 第二次 ioctl: 获取实际数据
    buf = malloc(ifc.ifc_len);
    ifc.ifc_buf = buf;
    ioctl(sock, SIOCGIFCONF, &ifc);

    // 遍历 ifreq 数组 (每个元素 = 一个接口的一个 IPv4 地址)
    for (i = 0; i < ifc.ifc_len / sizeof(struct ifreq); i++) {
        // 1. 过滤: 只处理 AF_INET
        if (ifreqP->ifr_addr.sa_family != AF_INET) continue;

        // 2. 保存地址 (因为后续 ioctl 会覆盖 ifr_addr 联合体)
        memcpy(&addr, &ifreqP->ifr_addr, sizeof(struct sockaddr));

        // 3. 获取 flags, 判断是否支持广播
        ioctl(sock, SIOCGIFFLAGS, ifreqP);
        if (ifreqP->ifr_flags & IFF_BROADCAST) {
            // 恢复地址 (ioctl 修改了联合体), 再获取广播地址
            memcpy(&ifreqP->ifr_addr, &addr, sizeof(struct sockaddr));
            ioctl(sock, SIOCGIFBRDADDR, ifreqP);
        }

        // 4. 恢复地址, 获取子网掩码 → 转为前缀长度
        memcpy(&ifreqP->ifr_addr, &addr, sizeof(struct sockaddr));
        ioctl(sock, SIOCGIFNETMASK, ifreqP);
        prefix = translateIPv4AddressToPrefix(&ifreqP->ifr_netmask);

        // 5. 调用 addif() 加入链表
        ifs = addif(env, sock, ifreqP->ifr_name, ifs, &addr, broadaddrP, AF_INET, prefix);
    }
    return ifs;
}
```

**ifreq 联合体陷阱**：`struct ifreq` 中的 `ifr_addr`、`ifr_flags`、`ifr_broadaddr`、`ifr_netmask` 共享同一个联合体（union）。每次 ioctl 会覆盖之前的数据，所以代码中反复 `memcpy` 保存/恢复地址——这是 ioctl 编程的经典陷阱。

**每个接口需要 4 次 ioctl**：

| ioctl | 参数 | 获取内容 |
|-------|------|---------|
| `SIOCGIFCONF` × 2 | `ifconf` | 所有接口的 IPv4 地址列表 |
| `SIOCGIFFLAGS` | `ifreq` | 接口标志位（UP/BROADCAST/LOOPBACK...） |
| `SIOCGIFBRDADDR` | `ifreq` | 广播地址 |
| `SIOCGIFNETMASK` | `ifreq` | 子网掩码 |

### 11.5.3 enumIPv6Interfaces — Linux 实现

IPv6 枚举与 IPv4 完全不同——**不用 ioctl**，而是直接读取 `/proc/net/if_inet6` 文件：

```c
// NetworkInterface.c 第 1216-1252 行
static netif *enumIPv6Interfaces(JNIEnv *env, int sock, netif *ifs) {
    FILE *f;
    char devname[21], addr6p[8][5];
    int prefix, scope, dad_status, if_idx;

    f = fopen("/proc/net/if_inet6", "r");
    while (fscanf(f, "%4s%4s%4s%4s%4s%4s%4s%4s %08x %02x %02x %02x %20s\n",
                  addr6p[0]..addr6p[7],
                  &if_idx, &prefix, &scope, &dad_status, devname) != EOF) {

        // 拼接 IPv6 地址字符串, 如 "fe80:0000:0000:0000:0215:5dff:fe00:1234"
        sprintf(addr6, "%s:%s:%s:%s:%s:%s:%s:%s", addr6p[0]..addr6p[7]);

        // 解析为 sockaddr_in6
        inet_pton(AF_INET6, addr6, &addr.sin6_addr);
        addr.sin6_scope_id = if_idx;  // scope ID = 接口索引

        // 加入链表 (注意: ifs 是 IPv4 阶段的结果, IPv6 地址会合并进去)
        ifs = addif(env, sock, devname, ifs, &addr, NULL, AF_INET6, prefix);
    }
    fclose(f);
    return ifs;
}
```

**`/proc/net/if_inet6` 文件格式**：

```
# 格式: addr6(32hex) if_idx prefix scope dad_status devname
00000000000000000000000000000001 01 80 10 80       lo
fe800000000000000215500ffe010001 02 40 20 80     eth0
```

| 字段 | 含义 | 示例 |
|------|------|------|
| addr6 | IPv6 地址 (32 个十六进制字符) | `fe80...0001` |
| if_idx | 接口索引 | `02` |
| prefix | 前缀长度 | `40` (= /64) |
| scope | 作用域 (link=20, host=10) | `20` |
| dad_status | 重复地址检测状态 | `80` |
| devname | 接口名称 | `eth0` |

**为什么 IPv6 不用 ioctl?** Linux 的 `SIOCGIFCONF` ioctl 只返回 IPv4 地址（`AF_INET`）。IPv6 地址要么通过 netlink socket 获取（复杂），要么直接读 `/proc`（简单）。OpenJDK 选择了后者。

### 11.5.4 openSocket — 创建 ioctl 用途的 socket

```c
// NetworkInterface.c 第 1086-1100 行
static int openSocket(JNIEnv *env, int proto) {
    int sock;
    if ((sock = socket(proto, SOCK_DGRAM, 0)) < 0) {
        if (errno != EPROTONOSUPPORT) {
            // 只有非协议不支持的错误才抛异常
            JNU_ThrowByNameWithMessageAndLastError(...);
        }
        return -1;
    }
    return sock;
}
```

**为什么用 `SOCK_DGRAM`（UDP）而不是 `SOCK_STREAM`（TCP）？** 因为 socket 纯粹用来做 ioctl 查询，不需要建立连接。DGRAM 创建成本最低，不需要三次握手。

### 11.5.5 openSocketWithFallback — 带降级的 socket 创建

```c
// NetworkInterface.c 第 1109-1129 行 (Linux)
static int openSocketWithFallback(JNIEnv *env, const char *ifname) {
    int sock;
    if ((sock = socket(AF_INET, SOCK_DGRAM, 0)) < 0) {
        if (errno == EPROTONOSUPPORT) {
            // IPv4 不支持, 降级尝试 IPv6
            sock = socket(AF_INET6, SOCK_DGRAM, 0);
        }
    }
    // Linux 2.6+ 内核允许用任意协议族的 socket 做 ioctl 查询
    // 不管接口是 IPv4 还是 IPv6 的
    return sock;
}
```

这个函数被 `getMTU0`、`getFlags0`、`getMacAddr0` 使用。

---

## 11.6 addif() — 核心合并与虚拟接口处理

`addif()` 是整个文件最复杂的函数，负责将一个地址加入到接口链表中，并处理虚拟子接口。

### 11.6.1 完整流程

```c
// NetworkInterface.c 第 882-1022 行
static netif *addif(JNIEnv *env, int sock, const char *if_name, netif *ifs,
                    struct sockaddr *ifr_addrP, struct sockaddr *ifr_broadaddrP,
                    int family, short prefix) {

    // 步骤 1: 分配 netaddr (地址+广播地址 连续分配)
    addr_size = (family == AF_INET) ? sizeof(sockaddr_in) : sizeof(sockaddr_in6);
    CHECKED_MALLOC3(addrP, netaddr *, sizeof(netaddr) + 2 * addr_size);
    addrP->addr = (sockaddr *)((char *)addrP + sizeof(netaddr));
    memcpy(addrP->addr, ifr_addrP, addr_size);
    // IPv4 且有广播: brdcast 紧跟 addr 之后
    if (family == AF_INET && ifr_broadaddrP != NULL) {
        addrP->brdcast = (sockaddr *)((char *)addrP + sizeof(netaddr) + addr_size);
        memcpy(addrP->brdcast, ifr_broadaddrP, addr_size);
    }

    // 步骤 2: 检测虚拟接口 (如 eth0:1)
    name_colonP = strchr(name, ':');
    if (name_colonP != NULL) {
        *name_colonP = '\0';  // 截断: "eth0:1" → "eth0"
        // 尝试获取父接口 flags
        if (getFlags(sock, name, &flags) >= 0) {
            // 保存完整虚拟名到 vname: "eth0:1"
        } else {
            // 无法访问父接口, 标记为虚拟但无父
            isVirtual = 1;
        }
    }

    // 步骤 3: 在现有链表中查找同名接口
    while (currif != NULL) {
        if (strcmp(name, currif->name) == 0) break;
        currif = currif->next;
    }

    // 步骤 4: 如果不存在, 创建新 netif 并插入链表头部
    if (currif == NULL) {
        CHECKED_MALLOC3(currif, netif *, sizeof(netif) + IFNAMESIZE);
        currif->name = (char *)currif + sizeof(netif);
        strncpy(currif->name, name, IFNAMESIZE);
        currif->index = getIndex(sock, name);
        currif->next = ifs;  // 头插法
        ifs = currif;
    }

    // 步骤 5: 将地址插入接口的地址链表头部
    addrP->next = currif->addr;
    currif->addr = addrP;

    // 步骤 6: 如果是虚拟接口, 复制地址到子接口
    if (vname[0]) {
        parent = currif;

        // 在 parent->childs 中查找
        currif = parent->childs;
        while (currif != NULL) {
            if (strcmp(vname, currif->name) == 0) break;
            currif = currif->next;
        }

        // 不存在则创建子接口
        if (currif == NULL) {
            CHECKED_MALLOC3(currif, netif *, sizeof(netif) + IFNAMESIZE);
            currif->name = (char *)currif + sizeof(netif);
            strncpy(currif->name, vname, IFNAMESIZE);
            currif->virtual = 1;
            currif->next = parent->childs;
            parent->childs = currif;  // 头插法插入子接口链表
        }

        // 复制地址到子接口 (独立的 malloc, 因为释放时分别 free)
        CHECKED_MALLOC3(tmpaddr, netaddr *, sizeof(netaddr) + 2 * addr_size);
        memcpy(tmpaddr, addrP, sizeof(netaddr));
        // 重新设置 addr/brdcast 指针 (指向 tmpaddr 内部)
        tmpaddr->addr = ...;
        memcpy(tmpaddr->addr, addrP->addr, addr_size);
        // ...类似处理 brdcast...

        tmpaddr->next = currif->addr;
        currif->addr = tmpaddr;
    }

    return ifs;
}
```

### 11.6.2 虚拟接口的父子关系

Linux 支持给物理接口添加别名（虚拟接口），语法是 `ifconfig eth0:1 192.168.1.100`。在 JDK 中：

```
netif 链表 (ifs):
  ┌─────────┐     ┌─────────┐     ┌──────┐
  │ eth0    │────▶│ docker0 │────▶│ lo   │──▶ NULL
  │ idx=2   │     │ idx=3   │     │ idx=1│
  │ addr:   │     │ addr:   │     │ addr:│
  │ 10.0.0.1│     │172.17.0.│     │127.0.│
  │ fe80::1 │     │ 1       │     │ 0.1  │
  │         │     └─────────┘     │ ::1  │
  │ childs: │                     └──────┘
  │ ┌───────┴──┐   ┌──────────┐
  │ │ eth0:1   │──▶│ eth0:2   │──▶ NULL
  │ │192.168.  │   │192.168.  │
  │ │ 1.100    │   │ 2.100    │
  └─┴──────────┘   └──────────┘
```

**关键规则**：
1. 虚拟接口的地址**同时存在于**父接口和子接口的地址链表中
2. 是两份独立的 `netaddr` 拷贝（各自 malloc），释放时不会冲突
3. 虚拟接口通过接口名中的 `:` 检测，不依赖任何 ioctl flag

---

## 11.7 createNetworkInterface() — C→Java 对象构建

这个函数把 C 层的 `netif` 链表节点转换为 Java 的 `NetworkInterface` 对象：

```c
// NetworkInterface.c 第 659-811 行
static jobject createNetworkInterface(JNIEnv *env, netif *ifs) {
    // 1. 创建 NetworkInterface 对象, 设置基本属性
    netifObj = NewObject(ni_class, ni_ctrID);
    SetObjectField(netifObj, ni_nameID, NewStringUTF(ifs->name));
    SetObjectField(netifObj, ni_descID, name);  // Linux 上 displayName = name
    SetIntField(netifObj, ni_indexID, ifs->index);
    SetBooleanField(netifObj, ni_virutalID, ifs->virtual);

    // 2. 计算地址数量, 创建 InetAddress[] 和 InterfaceAddress[]
    addr_count = count(ifs->addr);
    addrArr = NewObjectArray(addr_count, ia_class, NULL);
    bindArr = NewObjectArray(addr_count, ni_ibcls, NULL);

    // 3. 遍历地址链表, 构建 Java 对象
    while (addrP != NULL) {
        if (addrP->family == AF_INET) {
            iaObj = new Inet4Address();
            setInetAddress_addr(iaObj, htonl(sockaddr_in->sin_addr.s_addr));

            ibObj = new InterfaceAddress();
            ibObj.address = iaObj;
            if (addrP->brdcast) {
                ibObj.broadcast = new Inet4Address(广播地址);
            }
            ibObj.maskLength = addrP->mask;
        }

        if (addrP->family == AF_INET6) {
            iaObj = new Inet6Address();
            setInet6Address_ipaddress(iaObj, sin6_addr);
            if (scope != 0) {
                setInet6Address_scopeid(iaObj, scope);
                setInet6Address_scopeifname(iaObj, netifObj);  // 设置 scope 接口引用
            }

            ibObj = new InterfaceAddress();
            ibObj.address = iaObj;
            ibObj.maskLength = addrP->mask;
            // 注意: IPv6 没有广播地址, broadcast 字段为 null
        }

        addrArr[index] = iaObj;
        bindArr[index] = ibObj;
    }

    // 4. 递归创建子接口
    child_count = count(ifs->childs);
    childArr = NewObjectArray(child_count, ni_class, NULL);
    childP = ifs->childs;
    while (childP) {
        tmp = createNetworkInterface(env, childP);  // 递归！
        tmp.parent = netifObj;  // 设置父引用
        childArr[index] = tmp;
        childP = childP->next;
    }

    // 5. 设置数组字段
    netifObj.addrs = addrArr;
    netifObj.bindings = bindArr;
    netifObj.childs = childArr;

    return netifObj;
}
```

**注意事项**：
- `htonl()` 转换：`sockaddr_in.sin_addr.s_addr` 是网络字节序，`setInetAddress_addr` 期望主机字节序，所以需要 `htonl()`（其实是字节反转，从网络序到主机序用 `ntohl`，但这里因为 JDK 内部 `address` 字段存的是网络字节序整数，实际效果等价）
- IPv6 的 `scope_id` 如果非零，会同时设置 `scopeid`（数字）和 `scopeifname`（接口对象引用）
- 子接口通过**递归调用** `createNetworkInterface()` 创建

---

## 11.8 四种查询方法

所有查询方法都遵循同一模式：**调用 `enumInterfaces()` 全量枚举 → 在链表中搜索 → `createNetworkInterface()` 转换 → `freeif()` 释放链表**。

### 11.8.1 getAll() — 获取所有接口

```c
// NetworkInterface.c 第 422-473 行
JNIEXPORT jobjectArray JNICALL Java_java_net_NetworkInterface_getAll(JNIEnv *env, jclass cls) {
    ifs = enumInterfaces(env);        // 全量枚举
    ifCount = count(ifs);             // 计数
    netIFArr = NewObjectArray(ifCount, cls, NULL);  // 创建数组
    while (curr != NULL) {
        netifObj = createNetworkInterface(env, curr);  // 逐个转换
        SetObjectArrayElement(netIFArr, index++, netifObj);
        curr = curr->next;
    }
    freeif(ifs);                      // 释放 C 链表
    return netIFArr;
}
```

### 11.8.2 getByName0() — 按名称查找（支持虚拟接口）

```c
// NetworkInterface.c 第 216-282 行
// 两级搜索: 先找父接口, 再找子接口
strncpy(searchName, name_utf, IFNAMESIZE);
colonP = strchr(searchName, ':');
if (colonP != NULL) {
    *colonP = '\0';  // "eth0:1" → "eth0"
}

// 第一级: 在主链表中按截断名 "eth0" 搜索
while (curr != NULL) {
    if (strcmp(searchName, curr->name) == 0) break;
    curr = curr->next;
}

// 第二级: 如果原名有冒号, 在 childs 中按完整名 "eth0:1" 搜索
if (colonP != NULL && curr != NULL) {
    curr = curr->childs;
    while (curr != NULL) {
        if (strcmp(name_utf, curr->name) == 0) break;
        curr = curr->next;
    }
}
```

### 11.8.3 getByIndex0() — 按索引查找

```c
// NetworkInterface.c 第 289-322 行
// 简单线性搜索, 只搜主链表 (不搜子接口)
while (curr != NULL) {
    if (index == curr->index) break;
    curr = curr->next;
}
```

### 11.8.4 getByInetAddress0() — 按 IP 地址查找

```c
// NetworkInterface.c 第 329-415 行
// 双层遍历: 外层遍历接口, 内层遍历地址链表
while (curr != NULL) {
    netaddr *addrP = curr->addr;
    while (addrP != NULL) {
        if (family == AF_INET) {
            // 比较 4 字节 IPv4 地址
            address1 = htonl(sockaddr_in->sin_addr.s_addr);
            address2 = getInetAddress_addr(env, iaObj);
            if (address1 == address2) match = true;
        } else if (family == AF_INET6) {
            // 比较 16 字节 IPv6 地址 + scope_id
            getInet6Address_ipaddress(env, iaObj, caddr);
            scopeid = getInet6Address_scopeid(env, iaObj);
            // scope_id 非零时必须匹配
            if (scopeid != 0 && scopeid != sin6_scope_id) break;
            // 逐字节比较 16 bytes
            for (i = 0; i < 16; i++) { if (caddr[i] != bytes[i]) break; }
        }
    }
}
```

**性能特征**：每次查询都会**全量枚举**所有接口。没有缓存。在接口数量少（通常 < 10）的情况下不是问题，但在高频调用场景下应该在 Java 层做缓存。

---

## 11.9 属性查询方法

### 11.9.1 接口标志位 — IFF_* 常量

所有标志位查询共用一个 `getFlags0()` 函数：

```c
// NetworkInterface.c 第 618-652 行
static int getFlags0(JNIEnv *env, jstring name) {
    sock = openSocketWithFallback(env, name_utf);
    ret = getFlags(sock, name_utf, &flags);
    close(sock);
    return flags;
}

// 底层: ioctl(SIOCGIFFLAGS)
// NetworkInterface.c 第 1321-1337 行
static int getFlags(int sock, const char *ifname, int *flags) {
    struct ifreq if2;
    strncpy(if2.ifr_name, ifname, sizeof(if2.ifr_name));
    ioctl(sock, SIOCGIFFLAGS, &if2);

    // 处理 short 到 int 的符号扩展问题
    if (sizeof(if2.ifr_flags) == sizeof(short)) {
        *flags = (if2.ifr_flags & 0xffff);  // 截断高位避免符号扩展
    } else {
        *flags = if2.ifr_flags;
    }
    return 0;
}
```

各方法与 IFF 标志的映射：

| Java 方法 | 检查的 IFF 标志 | 含义 |
|-----------|----------------|------|
| `isUp0()` | `IFF_UP && IFF_RUNNING` | 接口已启用**且**物理链路正常 |
| `isLoopback0()` | `IFF_LOOPBACK` | 回环接口 (lo) |
| `isP2P0()` | `IFF_POINTOPOINT` | 点对点链路 (PPP/VPN) |
| `supportsMulticast0()` | `IFF_MULTICAST` | 支持多播 |

**`isUp0` 的双重检查**：

```c
// NetworkInterface.c 第 484 行
return ((ret & IFF_UP) && (ret & IFF_RUNNING)) ? JNI_TRUE : JNI_FALSE;
```

- `IFF_UP`：管理员设置的接口启用标志（`ifconfig eth0 up`）
- `IFF_RUNNING`：驱动层报告的物理链路状态

两个都为 true 才算"接口可用"。这意味着网线拔了但接口没 down 的情况，`isUp()` 返回 `false`。

### 11.9.2 MAC 地址 — getMacAddress()

```c
// NetworkInterface.c 第 1275-1305 行 (Linux)
static int getMacAddress(JNIEnv *env, const char *ifname,
                         const struct in_addr *addr, unsigned char *buf) {
    struct ifreq ifr;
    sock = openSocketWithFallback(env, ifname);

    strncpy(ifr.ifr_name, ifname, sizeof(ifr.ifr_name) - 1);
    ioctl(sock, SIOCGIFHWADDR, &ifr);  // 获取硬件地址

    close(sock);
    memcpy(buf, &ifr.ifr_hwaddr.sa_data, IFHWADDRLEN);  // IFHWADDRLEN = 6

    // 全 0 表示没有硬件地址 (如 loopback 接口)
    for (i = 0; i < IFHWADDRLEN; i++) {
        if (buf[i] != 0) return IFHWADDRLEN;  // 返回 6
    }
    return -1;  // 无 MAC 地址
}
```

**JNI 入口** `getMacAddr0` 额外处理了 IPv4 地址参数：

```c
// NetworkInterface.c 第 528-576 行
if (!IS_NULL(addrArray)) {
    // 从 Java byte[] 提取 IPv4 地址 (用于 Solaris 的 ARP 表查询)
    addr = ((caddr[0]<<24) & 0xff000000) | ...;
    iaddr.s_addr = htonl(addr);
    len = getMacAddress(env, name_utf, &iaddr, mac);
} else {
    len = getMacAddress(env, name_utf, NULL, mac);
}
```

Linux 上 `addr` 参数实际不使用（`getMacAddress` 实现中直接用接口名查），但 Solaris 的实现会用它从 ARP 表查 MAC。

### 11.9.3 MTU — getMTU()

```c
// NetworkInterface.c 第 1307-1319 行
static int getMTU(JNIEnv *env, int sock, const char *ifname) {
    struct ifreq if2;
    strncpy(if2.ifr_name, ifname, sizeof(if2.ifr_name) - 1);
    ioctl(sock, SIOCGIFMTU, &if2);
    return if2.ifr_mtu;
}
```

典型值：以太网 = 1500，loopback = 65536，Jumbo Frame = 9000。

### 11.9.4 接口索引 — getIndex()

```c
// NetworkInterface.c 第 1257-1268 行
static int getIndex(int sock, const char *name) {
    struct ifreq if2;
    strncpy(if2.ifr_name, name, sizeof(if2.ifr_name));
    ioctl(sock, SIOCGIFINDEX, &if2);
    return if2.ifr_ifindex;
}
```

接口索引是内核分配的唯一标识符，`lo` 通常是 1，`eth0` 通常是 2。

---

## 11.10 前缀长度转换

### 11.10.1 IPv4 子网掩码 → 前缀长度

```c
// NetworkInterface.c 第 1027-1039 行
static short translateIPv4AddressToPrefix(struct sockaddr_in *addr) {
    short prefix = 0;
    unsigned int mask = ntohl(addr->sin_addr.s_addr);
    while (mask) {
        mask <<= 1;
        prefix++;
    }
    return prefix;
}
```

例如：`255.255.255.0` → `0xFFFFFF00` → 左移 24 次变为 0 → 返回 24。

**注意**：这个算法假设掩码是合法的连续 1-bit（如 `255.255.255.0`），对于非标准掩码（如 `255.255.128.128`）会返回错误结果。但实际中非标准掩码极其罕见。

### 11.10.2 IPv6 前缀长度计算

```c
// NetworkInterface.c 第 1044-1081 行
static short translateIPv6AddressToPrefix(struct sockaddr_in6 *addr) {
    short prefix = 0;
    u_char *addrBytes = &addr->sin6_addr;

    // 阶段 1: 跳过全 0xFF 的字节 (每个 = 8 bit)
    for (byte = 0; byte < 16; byte++, prefix += 8) {
        if (addrBytes[byte] != 0xff) break;
    }

    // 阶段 2: 处理部分字节, 从最高位开始计数
    if (byte != 16) {
        for (bit = 7; bit != 0; bit--, prefix++) {
            if (!(addrBytes[byte] & (1 << bit))) break;
        }

        // 验证: 第一个 0 之后不能再有 1
        for (; bit != 0; bit--) {
            if (addrBytes[byte] & (1 << bit)) {
                prefix = 0; break;  // 非法掩码, 返回 0
            }
        }

        // 验证: 后续字节必须全为 0
        for (byte++; byte < 16; byte++) {
            if (addrBytes[byte]) { prefix = 0; }
        }
    }
    return prefix;
}
```

IPv6 版本比 IPv4 严格得多——会**验证**掩码的合法性（1 必须连续），发现非法掩码返回 0。

---

## 11.11 内存释放 — freeif()

```c
// NetworkInterface.c 第 859-880 行
static void freeif(netif *ifs) {
    netif *currif = ifs;

    while (currif != NULL) {
        // 释放所有地址节点
        netaddr *addrP = currif->addr;
        while (addrP != NULL) {
            netaddr *next = addrP->next;
            free(addrP);  // 一次 free 释放 netaddr + addr + brdcast (连续分配)
            addrP = next;
        }

        // 递归释放子接口
        if (currif->childs != NULL) {
            freeif(currif->childs);  // 递归！
        }

        ifs = currif->next;
        free(currif);  // 一次 free 释放 netif + name (连续分配)
        currif = ifs;
    }
}
```

因为 `netif + name` 和 `netaddr + addr + brdcast` 都是连续分配的，每个节点只需要一次 `free()`。释放顺序：先地址链表 → 递归释放子接口 → 最后释放接口本身。

---

## 11.12 跨平台实现对比

`NetworkInterface.c` 的后半部分（第 1103-2173 行）是四个平台的条件编译实现。以下是关键差异：

### 11.12.1 枚举接口

| 操作 | Linux | AIX | Solaris | BSD/macOS |
|------|-------|-----|---------|-----------|
| 枚举 IPv4 | `ioctl(SIOCGIFCONF)` | `ioctl(CSIOCGIFCONF)` | `ioctl(SIOCGLIFCONF)` + LIFC_NOXMIT | `getifaddrs()` |
| 枚举 IPv6 | 读 `/proc/net/if_inet6` | 读 `/etc/ifinet6` | `ioctl(SIOCGLIFCONF)` (统一) | `getifaddrs()` |
| 获取缓冲区大小 | `SIOCGIFCONF(buf=NULL)` | `SIOCGSIZIFCONF` | `SIOCGLIFNUM` 计数 | 不需要 |
| ifreq 结构 | `struct ifreq` | `struct ifreq` (变长!) | `struct lifreq` | 不需要 |

**AIX 的特殊性**：AIX 的 `SIOCGIFCONF` 返回的 `ifreq` 是**变长记录**（每条记录的地址部分可能不是 16 字节），所以 JDK 使用 `CSIOCGIFCONF`（"C" 代表 "compatible"），确保每条记录大小固定为 `sizeof(struct ifreq)`。

**Solaris 的特殊性**：Solaris 使用 `lifreq`（"l" = "large"，支持更长的接口名），IPv4 和 IPv6 用同一个 `SIOCGLIFCONF` 接口，通过 `lifconf.lifc_family` 选择。设置 `LIFC_NOXMIT` 过滤掉不能发包的接口。

**BSD/macOS 的优雅方案**：使用 `getifaddrs()` 函数，一次调用返回所有接口的所有地址（IPv4+IPv6+link层），是最现代的 API。

### 11.12.2 获取 MAC 地址

| 平台 | 方法 | 备注 |
|------|------|------|
| **Linux** | `ioctl(SIOCGIFHWADDR)` | 最直接，一次 ioctl |
| **AIX** | `getkerninfo(KINFO_NDD)` | 扫描内核 NDD 表，匹配接口名 |
| **Solaris** | `ioctl(SIOCGLIFHWADDR)` → `getMacFromDevice()` (DLPI) → `ioctl(SIOCGARP)` | 三级降级！需要 root 权限做 DLPI |
| **BSD/macOS** | `getifaddrs()` + `AF_LINK` + `sockaddr_dl` | 从 link 层地址条目提取 |

**Solaris 的三级降级**最为复杂：

```
1. ioctl(SIOCGLIFHWADDR)  ← Solaris 11+ 才有
   ↓ 失败
2. getMacFromDevice("/dev/" + ifname)  ← DLPI 协议, 需要 root
   ↓ 失败
3. ioctl(SIOCGARP)  ← 从 ARP 表查, 需要该接口有 IPv4 地址
```

### 11.12.3 AIX 的 getkerninfo 获取 MAC

```c
// NetworkInterface.c AIX 部分 (简化)
static int getMacAddress(JNIEnv *env, const char *ifname,
                         const struct in_addr *addr, unsigned char *buf) {
    int size = getkerninfo(KINFO_NDD, 0, 0, 0);  // 获取 NDD 表大小
    nddp = malloc(size);
    getkerninfo(KINFO_NDD, nddp, &size, 0);

    // 遍历 NDD 表, 查找接口名匹配的条目
    while ((char *)nddp < end) {
        if (!strcmp(nddp->ndd_alias, ifname) || !strcmp(nddp->ndd_name, ifname)) {
            memcpy(buf, nddp->ndd_addr, 6);
            return 6;
        }
        nddp++;
    }
    return -1;
}
```

### 11.12.4 BSD 的 getifaddrs

```c
// NetworkInterface.c BSD 部分 (简化)
static netif *enumIPv4Interfaces(JNIEnv *env, int sock, netif *ifs) {
    struct ifaddrs *ifa, *origifa;
    getifaddrs(&origifa);

    for (ifa = origifa; ifa != NULL; ifa = ifa->ifa_next) {
        if (ifa->ifa_addr->sa_family != AF_INET) continue;

        // ifa 结构自带所有信息: name, addr, netmask, broadaddr, flags
        prefix = translateIPv4AddressToPrefix(ifa->ifa_netmask);
        broadaddrP = (ifa->ifa_flags & IFF_BROADCAST) ? ifa->ifa_broadaddr : NULL;
        ifs = addif(env, sock, ifa->ifa_name, ifs, ifa->ifa_addr, broadaddrP, AF_INET, prefix);
    }
    freeifaddrs(origifa);
    return ifs;
}

// BSD 获取 MAC 地址: 从 AF_LINK 条目提取
static int getMacAddress(JNIEnv *env, const char *ifname, ...) {
    struct ifaddrs *ifa;
    getifaddrs(&ifa);
    while (ifa != NULL) {
        if (ifa->ifa_addr->sa_family == AF_LINK && strcmp(ifname, ifa->ifa_name) == 0) {
            struct sockaddr_dl *sadl = (struct sockaddr_dl *)ifa->ifa_addr;
            // sadl 中包含: sdl_type(硬件类型), sdl_alen(地址长度), LLADDR()(MAC 地址)
            int len = cycleCount = sadl->sdl_alen;
            memcpy(buf, LLADDR(sadl), len);
            freeifaddrs(origifa);
            return len;
        }
        ifa = ifa->ifa_next;
    }
}
```

`getifaddrs()` 的优势：一次调用获取所有信息（地址、掩码、广播地址、flags），不需要反复 ioctl。BSD 系统甚至把 link 层（MAC 地址）作为 `AF_LINK` 类型的地址条目返回，无需额外调用。

---

## 11.13 数据流全景图

```
┌─────────────────────────── Java 层 ─────────────────────────────┐
│                                                                  │
│  NetworkInterface.getNetworkInterfaces()                         │
│    → getAll()  [native]                                          │
│                                                                  │
│  NetworkInterface.getByName("eth0")                              │
│    → getByName0("eth0")  [native]                                │
│                                                                  │
│  NetworkInterface.getByInetAddress(InetAddress.getByName("x"))   │
│    → getByInetAddress0(iaObj)  [native]                          │
│                                                                  │
│  ni.isUp() / isLoopback() / getMTU() / getHardwareAddress()      │
│    → isUp0/isLoopback0/getMTU0/getMacAddr0 [native]              │
└──────────────────────────────┬───────────────────────────────────┘
                               │ JNI
                               ▼
┌─────────────────────── C 层 (NetworkInterface.c) ───────────────┐
│                                                                  │
│  enumInterfaces()                                                │
│    │                                                             │
│    ├─ Phase 1: enumIPv4Interfaces()                              │
│    │   ├─ socket(AF_INET, SOCK_DGRAM)                            │
│    │   ├─ ioctl(SIOCGIFCONF) × 2   → ifreq[] (IPv4 地址列表)     │
│    │   ├─ for each ifreq:                                        │
│    │   │   ├─ ioctl(SIOCGIFFLAGS)   → IFF_BROADCAST?             │
│    │   │   ├─ ioctl(SIOCGIFBRDADDR) → 广播地址                    │
│    │   │   ├─ ioctl(SIOCGIFNETMASK) → 子网掩码→前缀长度           │
│    │   │   └─ addif() → netif/netaddr 链表                       │
│    │   └─ close(sock)                                            │
│    │                                                             │
│    └─ Phase 2: enumIPv6Interfaces()                              │
│        ├─ socket(AF_INET6, SOCK_DGRAM)                           │
│        ├─ fopen("/proc/net/if_inet6")                            │
│        ├─ fscanf → inet_pton → addif() → 合并到现有链表          │
│        └─ close(sock)                                            │
│                                                                  │
│  查询: getFlags0/getMTU0/getMacAddr0                              │
│    ├─ openSocketWithFallback() → socket(AF_INET | AF_INET6)      │
│    ├─ ioctl(SIOCGIFFLAGS/SIOCGIFMTU/SIOCGIFHWADDR)              │
│    └─ close(sock)                                                │
│                                                                  │
│  createNetworkInterface()                                        │
│    ├─ new NetworkInterface → 设置 name/index/virtual              │
│    ├─ 遍历 netaddr → new Inet4Address/Inet6Address               │
│    │                → new InterfaceAddress                        │
│    ├─ 递归创建 childs → 设置 parent 引用                          │
│    └─ return Java NetworkInterface 对象                           │
│                                                                  │
│  freeif()                                                        │
│    ├─ 释放 netaddr 链表 (free: netaddr+addr+brdcast)             │
│    ├─ 递归 freeif(childs)                                        │
│    └─ 释放 netif (free: netif+name)                              │
└──────────────────────────────┬───────────────────────────────────┘
                               │ 系统调用
                               ▼
┌─────────────────────── Linux 内核 ──────────────────────────────┐
│                                                                  │
│  socket(AF_INET/AF_INET6, SOCK_DGRAM, 0)                        │
│  ioctl(fd, SIOCGIFCONF, &ifconf)    → 返回所有 IPv4 接口         │
│  ioctl(fd, SIOCGIFFLAGS, &ifreq)    → 接口标志位                 │
│  ioctl(fd, SIOCGIFBRDADDR, &ifreq)  → 广播地址                   │
│  ioctl(fd, SIOCGIFNETMASK, &ifreq)  → 子网掩码                   │
│  ioctl(fd, SIOCGIFINDEX, &ifreq)    → 接口索引                   │
│  ioctl(fd, SIOCGIFHWADDR, &ifreq)   → MAC 地址                   │
│  ioctl(fd, SIOCGIFMTU, &ifreq)      → MTU                       │
│  /proc/net/if_inet6                  → 所有 IPv6 地址             │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## 11.14 性能与生产注意事项

### 14.1 每次查询都是全量枚举

```java
// 每调用一次 getByName, 都会 enumInterfaces → 枚举所有接口
NetworkInterface ni = NetworkInterface.getByName("eth0");
```

**没有缓存！** 每次调用都会：
1. 创建 socket
2. 执行多次 ioctl
3. 读 `/proc/net/if_inet6`
4. 构建完整的 C 链表
5. 遍历搜索
6. 构建 Java 对象
7. 释放 C 链表

**优化建议**：如果需要频繁查询（如健康检查），应该在 Java 层缓存 `NetworkInterface` 对象，设置合理的刷新间隔。

### 14.2 容器环境下的坑

Docker/K8s 环境中常见问题：

1. **`getNetworkInterfaces()` 可能返回大量 veth 接口**：Docker 网桥模式下，每个容器对应一个 `veth` 对。如果宿主机跑了几百个容器，枚举会很慢。

2. **虚拟子接口 `:` 记法 vs 现代 `ip addr add`**：`ip addr add 192.168.1.100/24 dev eth0` 添加的辅助地址**不会**创建 `eth0:1`，它们直接出现在 `eth0` 的地址列表中。只有 `ifconfig eth0:1` 才会创建冒号式虚拟接口。

3. **`getByName("eth0")` 在容器中可能返回 null**：容器内可能没有 `eth0`，而是 `eth0@if123` 或其他名字。

### 14.3 ioctl vs netlink

JDK 使用的 `ioctl(SIOCGIFCONF)` 是旧式 API，现代 Linux 推荐使用 **netlink socket**（`AF_NETLINK`, `NETLINK_ROUTE`）。netlink 的优势：

- 支持异步通知（接口变化时回调）
- 不需要轮询
- 更完整的信息（如路由表、邻居缓存）

但 `ioctl` 的优势是简单、跨平台，JDK 为了兼容性选择了 `ioctl`。

### 14.4 socket 开销

每次属性查询（`isUp()`、`getMTU()` 等）都会 `openSocketWithFallback()` + `close()`——即**每次查询创建和销毁一个 socket**。如果连续查询同一接口的多个属性：

```java
NetworkInterface ni = ...;
ni.isUp();           // open socket → ioctl → close
ni.isLoopback();     // open socket → ioctl → close  (又开一次!)
ni.getMTU();         // open socket → ioctl → close  (又开一次!)
ni.getHardwareAddress(); // open socket → ioctl → close
```

四次属性查询 = 四次 socket 创建/销毁 + 四次 ioctl。JDK 没有做 socket 复用。

---

## 11.15 面试常见问题

### Q1: Java 中如何获取本机 IP 地址？有什么坑？

**答**：
```java
// 方法 1: InetAddress.getLocalHost() — 最常用但最坑
InetAddress.getLocalHost().getHostAddress();
// 坑: 依赖 hostname → DNS 解析, 如果 /etc/hosts 没配好会返回 127.0.0.1 或超时

// 方法 2: NetworkInterface 遍历 — 最可靠
Enumeration<NetworkInterface> interfaces = NetworkInterface.getNetworkInterfaces();
while (interfaces.hasMoreElements()) {
    NetworkInterface ni = interfaces.nextElement();
    if (ni.isLoopback() || !ni.isUp()) continue;
    Enumeration<InetAddress> addrs = ni.getInetAddresses();
    while (addrs.hasMoreElements()) {
        InetAddress addr = addrs.nextElement();
        if (addr instanceof Inet4Address) {
            return addr.getHostAddress(); // 第一个非回环的 IPv4 地址
        }
    }
}

// 方法 3: UDP 连接技巧 — 最巧妙
DatagramSocket socket = new DatagramSocket();
socket.connect(InetAddress.getByName("8.8.8.8"), 10002);
String ip = socket.getLocalAddress().getHostAddress();
socket.close();
// 原理: UDP connect 不真正发包, 但内核会选择出口网卡并绑定本地地址
```

### Q2: `isUp()` 为什么要同时检查 `IFF_UP` 和 `IFF_RUNNING`？

**答**：`IFF_UP` 是管理标志（`ifconfig up` 设置），`IFF_RUNNING` 是驱动层报告的物理链路状态。拔网线后 `IFF_RUNNING` 变 0 但 `IFF_UP` 不变。只检查 `IFF_UP` 会误判网线断开的接口为可用。

### Q3: 为什么 Linux 上 IPv6 枚举要读 `/proc` 而不用 ioctl？

**答**：Linux 的 `ioctl(SIOCGIFCONF)` 只返回 IPv4 地址（历史原因，`struct ifreq` 设计时没考虑 IPv6）。获取 IPv6 地址要么用 netlink socket（复杂），要么读 `/proc/net/if_inet6`（简单）。JDK 选择后者，因为更简单且跨 Linux 版本兼容性好。Solaris 用的 `lifreq`/`SIOCGLIFCONF` 从设计上就同时支持 IPv4/IPv6。

### Q4: `NetworkInterface.getHardwareAddress()` 返回 null 可能的原因？

**答**：
1. **loopback 接口**：`lo` 没有 MAC 地址，`getMacAddress()` 检测全零后返回 -1
2. **非 root 权限**（Solaris 特有）：DLPI 需要 root
3. **虚拟接口**：某些虚拟设备（如 tun/tap）可能没有 MAC
4. **`SecurityManager` 限制**：Java 层 `getHardwareAddress()` 会检查 `NetPermission("getNetworkInformation")`

### Q5: `getNetworkInterfaces()` 的性能如何？

**答**：每次调用都是全量枚举（无缓存），包括：2 次 socket 创建/销毁、2+ 次 ioctl（`SIOCGIFCONF`）+ 每接口 3 次 ioctl（flags/broadcast/netmask）+ 读一次 `/proc` 文件 + 构建 C 链表 + 转换为 Java 对象 + 释放 C 链表。在典型 5-10 个接口的场景下约 100-500μs。但如果宿主机有几百个 veth（Docker 场景），可能达到毫秒级。高频调用场景应在 Java 层做缓存。

---

## 11.16 源码文件交叉引用

| 文件路径 | 行数 | 角色 |
|---------|------|------|
| `java.base/unix/native/libnet/NetworkInterface.c` | 2173 | **核心实现**：所有 JNI 方法 + 四平台条件编译 |
| `java.base/share/classes/java/net/NetworkInterface.java` | 639 | Java 层 API + native 方法声明 + `getNetworkInterfaces()` |
| `java.base/share/classes/java/net/InterfaceAddress.java` | ~80 | `InterfaceAddress` (address + broadcast + maskLength) |
| `java.base/share/native/libnet/net_util.c` | 328 | `initInetAddressIDs()` + IPv6 可用性检测 |
| `java.base/share/native/libnet/net_util.h` | 207 | `netif`/`netaddr` 未声明（在 .c 中），但 `InetAddress` 相关宏在此 |
| `java.base/share/native/libnet/InetAddress.c` | 78 | `InetAddress.init()` — 缓存 `InetAddress` 字段 ID |
| `java.base/share/native/libnet/Inet4Address.c` | 55 | `Inet4Address.init()` — 缓存 `ia4_class`/`ia4_ctrID` |
| `java.base/share/native/libnet/Inet6Address.c` | 75 | `Inet6Address.init()` — 缓存 `ia6_class`/`ia6_ctrID` |
| `java.base/windows/native/libnet/NetworkInterface.c` | ~1500 | Windows 实现: `GetAdaptersAddresses()` API |
| `java.base/windows/native/libnet/NetworkInterface.h` | 86 | Windows `netif`/`netaddr` 结构定义 |

---

## 11.17 本章总结

`NetworkInterface.c` 是 libnet.so 中最大的单个文件（2173 行），核心设计：

1. **两阶段枚举**：先 IPv4（`ioctl SIOCGIFCONF`）→ 再 IPv6（`/proc/net/if_inet6`），合并到同一 `netif` 链表
2. **`addif()` 一函数三职责**：创建 netaddr、合并到 netif、处理虚拟子接口的父子关系
3. **连续内存分配**：`netif + name` 和 `netaddr + addr + brdcast` 各一次 malloc，减少碎片
4. **全量枚举无缓存**：每次查询都从头枚举所有接口，简单但性能受接口数量影响
5. **四平台四实现**：Linux(ioctl+/proc) / AIX(ioctl+getkerninfo) / Solaris(lifreq+DLPI) / BSD(getifaddrs)

Linux 实现涉及的系统调用/内核接口：

```
socket(AF_INET/AF_INET6, SOCK_DGRAM, 0)  — 创建查询用 socket
ioctl(SIOCGIFCONF)    — 枚举所有 IPv4 接口
ioctl(SIOCGIFFLAGS)   — 获取 IFF_* 标志位
ioctl(SIOCGIFBRDADDR) — 获取广播地址
ioctl(SIOCGIFNETMASK) — 获取子网掩码
ioctl(SIOCGIFINDEX)   — 获取接口索引
ioctl(SIOCGIFHWADDR)  — 获取 MAC 地址
ioctl(SIOCGIFMTU)     — 获取 MTU
/proc/net/if_inet6    — 读取所有 IPv6 地址
```
