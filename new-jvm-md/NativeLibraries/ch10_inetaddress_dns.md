# 第 10 章：InetAddress — DNS 解析

> 源码基线：OpenJDK 11，Linux x86_64
> 核心文件：`Inet6AddressImpl.c` (729行) + `Inet4AddressImpl.c` (518行) + `InetAddress.java` (1793行)

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **第 10 章：InetAddress — DNS 解析**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 10.1 本章定位

`InetAddress.getByName("www.google.com")` 是 Java 中最基础的网络操作之一——域名解析。看似一个简单的方法调用，背后涉及：

1. **Java 层缓存机制**：`ConcurrentHashMap` + `ConcurrentSkipListSet` 实现的两级缓存，正向/负向独立 TTL
2. **双栈实现选择**：`InetAddressImplFactory` 在 JVM 启动时决定用 `Inet4AddressImpl` 还是 `Inet6AddressImpl`
3. **Native DNS 解析**：`getaddrinfo()` — glibc 的 DNS resolver，这是一个 **阻塞调用**
4. **ICMP/TCP 可达性检测**：`isReachable()` 的 ICMP ping + TCP echo fallback 双重策略
5. **反向 DNS + 防欺骗验证**：`getHostName()` 反查后还要正查验证

**为什么重要？**

- DNS 解析是 **线上故障高发点**：DNS 超时会导致连接池耗尽、服务雪崩
- `getaddrinfo()` 是 **阻塞的**，没有超时参数——这是 Java DNS 解析的致命缺陷
- 缓存策略直接影响连接到 CDN/负载均衡器的流量分布

---

## 10.2 类继承体系

```
                        ┌─────────────────────┐
                        │  InetAddressImpl     │  (接口, 49行)
                        │  ─────────────────── │
                        │  getLocalHostName()  │
                        │  lookupAllHostAddr() │
                        │  getHostByAddr()     │
                        │  isReachable()       │
                        │  anyLocalAddress()   │
                        │  loopbackAddress()   │
                        └──────────┬──────────┘
                                   │ implements
                    ┌──────────────┴──────────────┐
                    ▼                             ▼
         ┌───────────────────┐         ┌───────────────────┐
         │ Inet4AddressImpl  │         │ Inet6AddressImpl  │
         │ (75行 Java)       │         │ (122行 Java)      │
         │ + native 方法     │         │ + native 方法     │
         └────────┬──────────┘         └────────┬──────────┘
                  │ JNI                          │ JNI
                  ▼                              ▼
         ┌───────────────────┐         ┌───────────────────┐
         │Inet4AddressImpl.c │         │Inet6AddressImpl.c │
         │ (518行)           │         │ (729行)           │
         │ getaddrinfo(IPv4) │         │ getaddrinfo(IPv4  │
         │ getnameinfo(IPv4) │         │          + IPv6)  │
         │ ping4 (ICMP)      │         │ getnameinfo(dual) │
         │ tcp_ping4 (TCP)   │         │ ping6 (ICMPv6)    │
         └───────────────────┘         │ tcp_ping6 (TCP)   │
                                       │ lookupIfLocalhost  │
                                       │   (macOS fallback) │
                                       └───────────────────┘

         ┌─────────────────────────────────────────────┐
         │             InetAddress.java (1793行)        │
         │  ─────────────────────────────────────────── │
         │  static impl = InetAddressImplFactory.create()│
         │  static nameService (PlatformNameService      │
         │                     / HostsFileNameService)   │
         │  static cache (ConcurrentHashMap)             │
         │  static expirySet (ConcurrentSkipListSet)     │
         │  getByName() → getAllByName() → getAllByName0()│
         │  → getAddressesFromNameService()              │
         │    → nameService.lookupAllHostAddr()          │
         │      → impl.lookupAllHostAddr() [native]     │
         └─────────────────────────────────────────────┘

         ┌─────────────────────────────────────────────┐
         │         InetAddressImplFactory               │
         │  (定义在 InetAddress.java 末尾, 9行)         │
         │  ─────────────────────────────────────────── │
         │  create(): isIPv6Supported() ?               │
         │    → Inet6AddressImpl : Inet4AddressImpl     │
         │  native isIPv6Supported()                    │
         │    → ipv6_available()                        │
         │      → IPv6_supported() & !preferIPv4Stack   │
         └─────────────────────────────────────────────┘
```

**在现代 Linux 上，几乎总是使用 `Inet6AddressImpl`**，因为：
- Linux 默认启用 IPv6 双栈（`IPv6_supported()` 返回 true）
- 除非显式设置 `-Djava.net.preferIPv4Stack=true`
- `Inet6AddressImpl` 处理 IPv4 和 IPv6 地址，通过 `hints.ai_family = AF_UNSPEC`

---

## 10.3 libnet.so 加载与字段 ID 初始化

### 10.3.1 库加载触发链

```
InetAddress 类加载 → static 初始化块
  → System.loadLibrary("net")               // 加载 libnet.so
  → InetAddress.init()                      // native: 缓存 JNI 字段 ID
  → InetAddressImplFactory.create()         // 选择 Inet4/Inet6 实现
  → createNameService()                     // 创建 DNS 服务
```

`InetAddress.java` 的 static 块（第 306-342 行）做了三件事：

1. **读取 `java.net.preferIPv6Addresses` 属性**：决定返回结果中 IPv4 和 IPv6 的排序
   - `"true"` → `PREFER_IPV6_VALUE` (1)：IPv6 地址排在前面
   - `"false"` 或 null → `PREFER_IPV4_VALUE` (0)：IPv4 地址排在前面
   - `"system"` → `PREFER_SYSTEM_VALUE` (2)：保持 OS 返回的原始顺序

2. **`System.loadLibrary("net")`**：触发 `net_util.c` 的 `JNI_OnLoad()`
3. **`init()`**：native 方法，缓存所有 JNI 字段 ID

### 10.3.2 JNI_OnLoad — libnet.so 初始化

`net_util.c` 第 46-79 行：

```
JNI_OnLoad(JavaVM *vm)
  → 读取 java.net.preferIPv4Stack 属性
  → IPv6_available = IPv6_supported() & (!preferIPv4Stack)
  → REUSEPORT_available = reuseport_supported()
  → platformInit()                  // Linux: 空操作; AIX: aix_close_init()
  → parseExclusiveBindProperty()    // Solaris 独占绑定
```

`IPv6_supported()` 的判断逻辑（定义在 `net_util_md.c`）：尝试 `socket(AF_INET6, SOCK_STREAM, 0)`，成功则 IPv6 可用。

### 10.3.3 InetAddress.init() — JNI 字段 ID 缓存

`InetAddress.c` 第 52-77 行缓存了 7 个关键字段 ID：

| 全局变量 | 缓存的字段 | 用途 |
|---------|-----------|------|
| `ia_class` | `InetAddress.class` 的全局引用 | 创建数组时指定类型 |
| `iac_class` | `InetAddress$InetAddressHolder.class` | 访问 holder 内部字段 |
| `ia_holderID` | `InetAddress.holder` | 获取 holder 对象 |
| `ia_preferIPv6AddressID` | `InetAddress.preferIPv6Address` | 判断地址排序偏好 |
| `iac_addressID` | `InetAddressHolder.address` | 设置 IPv4 地址（int） |
| `iac_familyID` | `InetAddressHolder.family` | 设置地址族（1=IPv4, 2=IPv6） |
| `iac_hostNameID` | `InetAddressHolder.hostName` | 设置主机名 |
| `iac_origHostNameID` | `InetAddressHolder.originalHostName` | 保留原始主机名 |

**`initInetAddressIDs()`** 是所有 DNS 相关 JNI 方法的入口守卫：

```c
// net_util.c 第 83-93 行
JNIEXPORT void JNICALL initInetAddressIDs(JNIEnv *env) {
    if (!initialized) {
        Java_java_net_InetAddress_init(env, 0);     // InetAddress 字段
        Java_java_net_Inet4Address_init(env, 0);     // Inet4Address 字段
        Java_java_net_Inet6Address_init(env, 0);     // Inet6Address 字段
        initialized = 1;
    }
}
```

每个 `lookupAllHostAddr()` 和 `getHostByAddr()` 的 JNI 实现都以 `initInetAddressIDs(env)` 开头，确保字段 ID 已经缓存。

---

## 10.4 Java 层 DNS 解析完整链路

### 10.4.1 入口：getByName() → getAllByName()

```java
// InetAddress.java 第 1254-1257 行
public static InetAddress getByName(String host) throws UnknownHostException {
    return InetAddress.getAllByName(host)[0];  // 取第一个结果
}
```

`getAllByName()` 的处理流程（第 1309-1379 行）：

```
getAllByName(host, reqAddr)
  ├── host == null || empty → 返回 loopback (127.0.0.1 或 ::1)
  ├── host 以 "[" 开头 → IPv6 字面量解析 (去掉方括号)
  ├── host 首字符是数字或 ":" → IP 字面量解析
  │   ├── 先尝试 IPv4: IPAddressUtil.validateNumericFormatV4()
  │   ├── 再尝试 IPv6: IPAddressUtil.textToNumericFormatV6()
  │   │   └── 处理 %zone_id (scope ID)
  │   └── 直接构造 Inet4Address/Inet6Address，不查 DNS
  └── 否则 → getAllByName0(host, reqAddr, true, true)  // 进入 DNS 查找
```

**关键设计**：IP 字面量（如 `"192.168.1.1"` 或 `"::1"`）**不会触发 DNS 查找**，直接在 Java 层解析为 byte 数组并构造对象返回。

### 10.4.2 核心：getAllByName0() — 缓存查找 + DNS 解析

第 1453-1520 行，这是 InetAddress 缓存体系的核心：

```
getAllByName0(host, reqAddr, check, useCache)
  │
  ├── 1. SecurityManager 检查
  │
  ├── 2. 清理过期缓存
  │   └── 遍历 expirySet (ConcurrentSkipListSet, 按过期时间排序)
  │       └── 比较 (expiryTime - now) < 0 → 从 expirySet + cache 中移除
  │
  ├── 3. 查缓存
  │   ├── useCache=true → cache.get(host)
  │   └── useCache=false → cache.remove(host)  // getLocalHost() 用
  │
  ├── 4. 缓存未命中
  │   └── cache.putIfAbsent(host, new NameServiceAddresses(host, reqAddr))
  │       └── CAS 竞争：输了就用赢家的 Addresses 对象
  │
  └── 5. addrs.get().clone()  // 触发实际查找或返回缓存
```

### 10.4.3 缓存体系详解

InetAddress 的缓存由两个并发数据结构组成：

```
┌─────────────────────────────────────────────────────────────┐
│  cache: ConcurrentHashMap<String, Addresses>                │
│  ─────────────────────────────────────────                  │
│  key = hostname (如 "www.google.com")                       │
│  value = Addresses (两种实现):                               │
│    ├── NameServiceAddresses: 正在查找/首次查找               │
│    └── CachedAddresses: 已缓存结果                          │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  expirySet: ConcurrentSkipListSet<CachedAddresses>          │
│  ─────────────────────────────────────────                  │
│  按 expiryTime 排序的有序集合                                │
│  只包含有限 TTL 的条目 (不包含 FOREVER)                      │
│  每次 DNS 查找前扫描前缀，清理过期条目                       │
└─────────────────────────────────────────────────────────────┘
```

**`NameServiceAddresses.get()` — 单次 DNS 查找的完整流程**（第 828-885 行）：

```
synchronized (this) {
    // 1. 重新检查 cache 中是否还是自己（可能被其他线程替换了）
    addresses = cache.putIfAbsent(host, this);
    if (addresses == this) {
        // 2. 真正执行 DNS 查找
        inetAddresses = getAddressesFromNameService(host, reqAddr);
        cachePolicy = InetAddressCachePolicy.get();
        
        // 3. 根据缓存策略处理结果
        if (cachePolicy == NEVER) {
            cache.remove(host, this);                    // 不缓存
        } else {
            CachedAddresses cached = new CachedAddresses(
                host, inetAddresses,
                cachePolicy == FOREVER ? 0L              // 永不过期
                    : System.nanoTime() + 1_000_000_000L * cachePolicy  // TTL
            );
            cache.replace(host, this, cached);           // 替换为缓存条目
            if (cachePolicy != FOREVER) {
                expirySet.add(cached);                   // 注册到过期集
            }
        }
        return inetAddresses;
    }
}
// 其他线程已替换，委托给新的 Addresses 对象
return addresses.get();
```

**关键设计点**：

1. **单 host 单线程查找**：`synchronized (this)` 保证同一个 host 只有一个线程执行 DNS 查找，其他线程等待
2. **CAS + synchronized 组合**：先 `cache.putIfAbsent()` 竞争，赢家进入 synchronized 块执行查找
3. **结果替换**：查找完成后用 `cache.replace()` 原子替换 `NameServiceAddresses` → `CachedAddresses`

### 10.4.4 缓存策略 — InetAddressCachePolicy

| 属性 | 默认值 | 作用 |
|------|--------|------|
| `networkaddress.cache.ttl` | 有 SecurityManager: `-1` (永久)<br>无 SecurityManager: `30` (秒) | 成功解析的缓存时间 |
| `networkaddress.cache.negative.ttl` | `10` (秒) | 解析失败的缓存时间 |
| `sun.net.inetaddr.ttl` | (回退属性) | 同上，优先级低 |

读取优先级：`Security.getProperty()` → `System.getProperty()` → 默认值

**生产环境影响**：
- **有 SecurityManager（如 Tomcat 默认开启）**：DNS 结果永久缓存，服务器 IP 变更后 Java 进程不会感知
- **无 SecurityManager**：30 秒缓存，每 30 秒重新解析一次
- **设为 0 (NEVER)**：每次连接都做 DNS 查找，性能差但适合 CDN 场景

### 10.4.5 getAddressesFromNameService() — 委托给 NameService

第 1522-1565 行：

```java
static InetAddress[] getAddressesFromNameService(String host, InetAddress reqAddr) {
    InetAddress[] addresses = nameService.lookupAllHostAddr(host);
    
    // reqAddr 优化：如果调用方指定了偏好地址，将其旋转到数组首位
    if (reqAddr != null && addresses.length > 1 && !addresses[0].equals(reqAddr)) {
        // 找到 reqAddr 的位置，旋转数组使其排在第一位
    }
    return addresses;
}
```

`nameService` 有两种实现：

| 实现 | 选择条件 | 底层 |
|------|---------|------|
| `PlatformNameService` | 默认 | 委托给 `impl.lookupAllHostAddr()` → native `getaddrinfo()` |
| `HostsFileNameService` | 设置了 `jdk.net.hosts.file` | 读取指定的 hosts 文件解析 |

**`-Djdk.net.hosts.file=/etc/hosts`**：可用于测试环境，绕过 DNS 直接用 hosts 文件。

---

## 10.5 lookupAllHostAddr() — DNS 正向解析核心

### 10.5.1 Inet6AddressImpl 版本（标准路径）

`Inet6AddressImpl.c` 第 224-411 行，这是大多数 Linux 系统实际走的路径：

```
lookupAllHostAddr(hostname)
  │
  ├── 1. initInetAddressIDs(env)          // 确保 JNI 字段 ID 已缓存
  │
  ├── 2. 设置 hints
  │   hints.ai_flags = AI_CANONNAME       // 请求规范名
  │   hints.ai_family = AF_UNSPEC         // ★ 同时返回 IPv4 和 IPv6
  │
  ├── 3. getaddrinfo(hostname, NULL, &hints, &res)  // ★ 核心系统调用
  │   ├── 成功 → 遍历 res 链表
  │   └── 失败 → macOS: 尝试 lookupIfLocalhost()
  │              其他: NET_ThrowUnknownHostExceptionWithGaiError()
  │
  ├── 4. 去重：构建 resNew 链表，跳过重复地址
  │   ├── IPv4: 比较 sin_addr.s_addr (4 字节)
  │   └── IPv6: 逐字节比较 sin6_addr.s6_addr[0..15] (16 字节)
  │
  ├── 5. 按 preferIPv6Address 排序结果数组
  │   ├── PREFER_IPV6_VALUE → IPv6 在前，IPv4 在后
  │   ├── PREFER_IPV4_VALUE → IPv4 在前，IPv6 在后
  │   └── PREFER_SYSTEM_VALUE → 保持 getaddrinfo 返回的原始顺序
  │
  ├── 6. 构造 Java 对象数组
  │   ├── IPv4 → new Inet4Address + setInetAddress_addr(ntohl(addr))
  │   └── IPv6 → new Inet6Address + setInet6Address_ipaddress(16 bytes)
  │              + setInet6Address_scopeid(scope_id) // 仅非零时设置
  │
  └── 7. 清理
      ├── JNU_ReleaseStringPlatformChars()
      ├── free(resNew 链表每个节点)
      └── freeaddrinfo(res)
```

### 10.5.2 getaddrinfo() — DNS 解析的真正执行者

```c
int getaddrinfo(const char *hostname,    // 要查找的主机名
                const char *service,     // 服务名/端口 (这里是 NULL)
                const struct addrinfo *hints,  // 过滤条件
                struct addrinfo **res);  // [out] 结果链表
```

**关键参数**：
- `AI_CANONNAME`：请求返回规范名称（CNAME 解析后的最终名）
- `AF_UNSPEC`：同时查询 A 记录（IPv4）和 AAAA 记录（IPv6）
- `service = NULL`：不查端口，纯域名解析

**返回值**：
- `0` = 成功
- 非零 = 错误码，用 `gai_strerror()` 转为可读字符串

**`getaddrinfo()` 是阻塞的，且没有超时参数！** 这意味着：
- DNS 服务器无响应时，`getaddrinfo()` 可能挂起 **30 秒甚至更久**（取决于 `/etc/resolv.conf` 的 timeout 和 attempts 配置）
- 默认：timeout=5s, attempts=2, ndots=1 → 最坏情况可能等 5*2*2=20 秒（考虑 search domain）
- **Java 没有提供 DNS 超时设置**，只能通过操作系统配置

### 10.5.3 去重逻辑

`getaddrinfo()` 可能返回重复地址（特别是多个 DNS 服务器配置时）。JDK 用一个简单的 O(n²) 去重：

```c
while (iterator != NULL) {
    int skip = 0;
    struct addrinfo *iteratorNew = resNew;
    while (iteratorNew != NULL) {
        if (iterator->ai_family == iteratorNew->ai_family &&
            iterator->ai_addrlen == iteratorNew->ai_addrlen) {
            if (iteratorNew->ai_family == AF_INET) {
                // IPv4: 比较 4 字节地址
                if (addr1->sin_addr.s_addr == addr2->sin_addr.s_addr) skip = 1;
            } else {
                // IPv6: 逐字节比较 16 字节地址
                for (t = 0; t < 16; t++) {
                    if (addr1->sin6_addr.s6_addr[t] != addr2->sin6_addr.s6_addr[t]) break;
                }
                if (t == 16) skip = 1;
            }
        }
        iteratorNew = iteratorNew->ai_next;
    }
    // 不重复则 malloc 新节点加入 resNew 链表
}
```

去重后的地址存入 `resNew` 链表（每个节点 `malloc(sizeof(struct addrinfo))` 单独分配），用于后续构造 Java 对象。原始 `res` 链表最后通过 `freeaddrinfo(res)` 一次性释放。

### 10.5.4 地址排序 — preferIPv6Address

`Inet6AddressImpl` 的 `lookupAllHostAddr` 根据 `preferIPv6Address` 字段决定排序：

```c
int addressPreference = (*env)->GetStaticIntField(env, ia_class, ia_preferIPv6AddressID);

if (addressPreference == PREFER_IPV6_VALUE) {
    inetIndex = inet6Count;     // IPv4 从 inet6Count 开始放
    inet6Index = 0;             // IPv6 从 0 开始放
} else if (addressPreference == PREFER_IPV4_VALUE) {
    inetIndex = 0;              // IPv4 从 0 开始放
    inet6Index = inetCount;     // IPv6 从 inetCount 开始放
} else { /* PREFER_SYSTEM_VALUE */
    inetIndex = inet6Index = originalIndex = 0;  // 保持原始顺序
}
```

**PREFER_SYSTEM_VALUE** 模式下，使用 `originalIndex++` 递增，IPv4 和 IPv6 按 `getaddrinfo` 返回顺序交替放置。

### 10.5.5 Inet4AddressImpl 版本

`Inet4AddressImpl.c` 第 104-216 行，结构类似但更简单：

- `hints.ai_family = AF_INET`：只查 IPv4
- 去重只比较 `sin_addr.s_addr`（4 字节）
- 结果全部是 `Inet4Address`，无排序问题

**只在 `java.net.preferIPv4Stack=true` 时使用。**

### 10.5.6 macOS lookupIfLocalhost() 降级

`Inet6AddressImpl.c` 第 93-217 行，macOS 专属 fallback：

当 `getaddrinfo()` 解析本机主机名失败时（bug 8170910），降级到 `getifaddrs()` 枚举所有网卡地址：

```
lookupIfLocalhost(hostname, includeV6)
  ├── gethostname(myhostname)
  ├── strcmp(myhostname, hostname) != 0 → return NULL (非本机查找)
  ├── getifaddrs(&ifa) → 枚举所有网络接口地址
  ├── 统计 IPv4/IPv6/loopback 数量
  ├── 如果只有 loopback → includeLoopback = true
  └── 遍历接口，用 NET_SockaddrToInetAddress() 构造 Java 对象
```

**Linux 不需要这个 fallback**，因为 Linux 的 `getaddrinfo` 对本机名解析总是正确的。

---

## 10.6 getHostByAddr() — 反向 DNS 解析

### 10.6.1 Inet6AddressImpl 版本

`Inet6AddressImpl.c` 第 423-462 行：

```
getHostByAddr(addrArray)
  │
  ├── 1. 判断地址长度
  │   ├── 4 字节 → 构造 sockaddr_in (AF_INET)
  │   └── 16 字节 → 构造 sockaddr_in6 (AF_INET6)
  │
  ├── 2. getnameinfo(&sa, len, host, sizeof(host), NULL, 0, NI_NAMEREQD)
  │   ├── 成功 → NewStringUTF(host) 返回主机名
  │   └── 失败 → throw UnknownHostException
  │
  └── NI_NAMEREQD 标志：要求必须返回域名，如果反向记录不存在则报错
```

### 10.6.2 getnameinfo() 系统调用

```c
int getnameinfo(const struct sockaddr *sa,  // IP 地址
                socklen_t salen,
                char *host,                 // [out] 主机名
                size_t hostlen,
                char *serv,                 // [out] 服务名 (传 NULL)
                size_t servlen,
                int flags);                 // NI_NAMEREQD
```

- 查询 DNS PTR 记录（反向解析）
- `NI_NAMEREQD`：如果没有 PTR 记录，返回错误而不是 IP 字符串
- 也是 **阻塞调用**

### 10.6.3 反向解析 + 防欺骗验证

当用户调用 `InetAddress.getHostName()` 时，Java 层还有一层防欺骗检查：

```java
// InetAddress.java 第 655-697 行
private static String getHostFromNameService(InetAddress addr, boolean check) {
    // 1. 反向解析：IP → hostname
    host = nameService.getHostByAddr(addr.getAddress());
    
    // 2. 安全检查
    if (check) sec.checkConnect(host, -1);
    
    // 3. ★ 防欺骗：hostname → IP[]，验证其中包含原始 IP
    InetAddress[] arr = InetAddress.getAllByName0(host, check);
    boolean ok = false;
    for (int i = 0; !ok && i < arr.length; i++) {
        ok = addr.equals(arr[i]);
    }
    
    // 4. 如果验证失败（可能被 DNS 欺骗），返回 IP 字符串
    if (!ok) {
        host = addr.getHostAddress();
    }
    return host;
}
```

**为什么需要防欺骗？**

攻击者可以设置恶意 PTR 记录：`1.2.3.4 → trusted.example.com`。如果 JDK 不做正查验证，应用可能错误信任这个主机名。防欺骗步骤确保：反向查出的 hostname 正查回来时必须包含原始 IP。

---

## 10.7 isReachable() — 可达性检测

### 10.7.1 双重策略

`isReachable0()` 采用 **ICMP 优先 + TCP fallback** 策略：

```
isReachable0(addrArray, timeout, ifArray, ttl)
  │
  ├── Inet6AddressImpl: 如果是 4 字节地址 → 直接委托给 Inet4AddressImpl
  │
  ├── 尝试创建 RAW socket
  │   fd = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)
  │   ├── 成功 (root 权限) → ping4() / ping6()  // ICMP ECHO
  │   └── 失败 (EPERM)    → tcp_ping4() / tcp_ping6()  // TCP 端口 7
  │
  └── Inet6AddressImpl.isReachable0 额外参数: scope, if_scope
```

### 10.7.2 ICMP ping 实现 — ping4()

`Inet4AddressImpl.c` 第 353-461 行：

```
ping4(fd, sa, netif, timeout, ttl)
  │
  ├── setsockopt(SO_RCVBUF, 60*1024)     // 接收缓冲区 60KB
  ├── setsockopt(IP_TTL, ttl)             // 设置 TTL
  ├── bind(fd, netif)                     // 绑定出口网卡（如指定）
  ├── SET_NONBLOCKING(fd)
  │
  └── 每秒发送一次 ICMP ECHO，直到超时或收到回复：
      do {
          // 构造 ICMP 报文
          icmp->icmp_type = ICMP_ECHO
          icmp->icmp_code = 0
          icmp->icmp_id = htons(pid)       // 用进程 PID 标记
          icmp->icmp_seq = htons(seq++)
          memcpy(icmp->icmp_data, &tv)     // 时间戳
          icmp->icmp_cksum = in_cksum()    // 手动计算校验和
          
          sendto(fd, sendbuf, plen, 0, sa)
          
          // 等待回复 (最多 1 秒)
          tmout2 = min(timeout, 1000)
          do {
              tmout2 = NET_Wait(fd, NET_WAIT_READ, tmout2)
              n = recvfrom(fd, recvbuf, ...)
              
              // 验证回复
              ip = (struct ip *)recvbuf
              hlen = ip->ip_hl << 2        // IP 头长度
              icmp = (struct icmp *)(recvbuf + hlen)
              
              if (icmp->icmp_type == ICMP_ECHOREPLY &&
                  ntohs(icmp->icmp_id) == pid &&
                  sa->sin_addr == sa_recv.sin_addr) {
                  return JNI_TRUE;          // ★ 可达！
              }
          } while (tmout2 > 0);
          timeout -= 1000;
      } while (timeout > 0);
      return JNI_FALSE;
```

**ICMP 报文结构**：
```
┌──────────┬──────────┬──────────────────┐
│ type (1B)│ code (1B)│  checksum (2B)   │
├──────────┴──────────┼──────────────────┤
│     id (2B)         │    seq (2B)      │
├─────────────────────┴──────────────────┤
│              data (timestamp)          │
└────────────────────────────────────────┘
plen = ICMP_ADVLENMIN + sizeof(struct timeval)
```

**为什么每秒发一次？**
网络可能丢包。如果只发一个 ICMP 包就等全部超时，会导致明明只是偶尔丢包的主机被判断为不可达。每秒重试给更多机会。

### 10.7.3 ICMPv6 ping — ping6()

`Inet6AddressImpl.c` 第 557-666 行，与 ping4 类似但有两个关键差异：

1. **Linux 需要显式设置校验和偏移**：
   ```c
   #if defined(__linux__)
   int csum_offset = 2;
   setsockopt(fd, SOL_RAW, IPV6_CHECKSUM, &csum_offset, sizeof(int));
   #endif
   ```
   Linux 内核不会自动计算 ICMPv6 校验和（IPv4 的 ICMP 会自动算），需要通过 `IPV6_CHECKSUM` 选项告诉内核校验和字段在报文中的偏移位置（第 2 字节）。

2. **ICMPv6 报文直接从 recvbuf 开始**：
   IPv6 不像 IPv4 那样在 raw socket 接收时包含 IP 头。所以 `icmp6 = (struct icmp6_hdr *)recvbuf` 直接从头开始，不需要跳过 IP 头。

3. **使用 `IPV6_UNICAST_HOPS` 而非 `IP_TTL`**。

### 10.7.4 TCP ping — tcp_ping4() / tcp_ping6()

当没有 root 权限（大多数情况），无法创建 RAW socket 发送 ICMP，降级为 TCP 连接端口 7（Echo 服务）：

```
tcp_ping4(sa, netif, timeout, ttl)
  │
  ├── socket(AF_INET, SOCK_STREAM, 0)
  ├── setsockopt(IP_TTL, ttl)
  ├── bind(netif)                         // 绑定出口
  ├── SET_NONBLOCKING(fd)
  ├── sa->sin_port = htons(7)             // ★ Echo 端口
  ├── NET_Connect(fd, sa)
  │   ├── connect_rv == 0 → return TRUE   // 立即连上
  │   ├── errno == ECONNREFUSED → TRUE    // ★ 拒绝也算可达！
  │   ├── EINPROGRESS → 等待...
  │   ├── ENETUNREACH/EAFNOSUPPORT → FALSE
  │   └── 其他 → throw ConnectException
  │
  ├── NET_Wait(fd, NET_WAIT_CONNECT, timeout)
  │   ├── timeout >= 0 → getsockopt(SO_ERROR)
  │   │   ├── 0 → TRUE
  │   │   └── ECONNREFUSED → TRUE         // ★ 拒绝也算可达
  │   └── timeout < 0 → FALSE
  │
  └── close(fd)
```

**为什么 ECONNREFUSED 也返回 true？**

`isReachable()` 测的是 **网络可达性**，不是端口是否开放。主机在线但端口 7 没开是正常的——RST 回复证明 IP 栈是活跃的。

**TCP ping 的局限**：
- 端口 7 (Echo) 在现代服务器上几乎都是关闭的
- 防火墙可能丢弃 SYN 包（不回 RST），导致和 ICMP 一样超时
- 无法穿越只允许特定端口的防火墙

### 10.7.5 IPv6 isReachable0 的 IPv4 委托

`Inet6AddressImpl.c` 第 691-696 行：

```c
sz = (*env)->GetArrayLength(env, addrArray);
if (sz == 4) {
    return Java_java_net_Inet4AddressImpl_isReachable0(env, this,
                                                       addrArray, timeout,
                                                       ifArray, ttl);
}
```

当 `Inet6AddressImpl.isReachable0()` 收到 4 字节地址（IPv4），直接委托给 `Inet4AddressImpl` 的实现。因为 IPv4-mapped IPv6 地址在 ICMP 层不工作——必须用真正的 IPv4 ICMP。

---

## 10.8 getLocalHostName() — 获取本机主机名

两个实现版本几乎相同：

```c
// Inet4AddressImpl.c / Inet6AddressImpl.c
char hostname[NI_MAXHOST + 1];
if (gethostname(hostname, sizeof(hostname)) != 0) {
    strcpy(hostname, "localhost");           // 失败则返回 "localhost"
} else {
    hostname[NI_MAXHOST] = '\0';             // 确保 null-terminated
    // Solaris: 额外通过 getaddrinfo + getnameinfo 解析为 FQDN
    // Linux/其他: 直接用 gethostname 的结果
}
return NewStringUTF(hostname);
```

`NI_MAXHOST` 在 Linux 上是 1025。

**Inet4AddressImpl** 用 `hints.ai_family = AF_INET`，**Inet6AddressImpl** 用 `AF_UNSPEC`（Solaris FQDN 解析部分）。

`InetAddress.getLocalHost()` 调用这个方法，然后对返回的主机名做一次 DNS 查找。结果缓存 5 秒（`CachedLocalHost.expiryTime = nanoTime + 5_000_000_000L`）。

---

## 10.9 错误处理 — gai_error → Java 异常

### 10.9.1 NET_ThrowUnknownHostExceptionWithGaiError

`net_util_md.c` 第 419-445 行：

```c
void NET_ThrowUnknownHostExceptionWithGaiError(JNIEnv *env,
                                               const char* hostname,
                                               int gai_error)
{
    const char *error_string = gai_strerror(gai_error);
    // 格式: "hostname: error_string"
    sprintf(buf, "%s: %s", hostname, error_string);
    // 抛出 java.net.UnknownHostException
    JNU_NewObjectByName(env, "java/net/UnknownHostException", "(Ljava/lang/String;)V", s);
}
```

**常见 gai_error 码**：

| 错误码 | gai_strerror() | 含义 |
|--------|---------------|------|
| `EAI_NONAME` | "Name or service not known" | 域名不存在 |
| `EAI_AGAIN` | "Temporary failure in name resolution" | DNS 服务器暂时不可用 |
| `EAI_FAIL` | "Non-recoverable failure in name resolution" | DNS 服务器永久错误 |
| `EAI_NODATA` | "No address associated with hostname" | 域名存在但无 A/AAAA 记录 |
| `EAI_MEMORY` | "Memory allocation failure" | 内存不足 |
| `EAI_SYSTEM` | (检查 errno) | 系统级错误 |

### 10.9.2 isReachable 的 errno 处理

| errno | 含义 | isReachable 行为 |
|-------|------|-----------------|
| `ECONNREFUSED` | 连接被拒 | **返回 true**（主机可达但端口关闭） |
| `EINPROGRESS` | 连接进行中 | 等待超时 |
| `ENETUNREACH` | 网络不可达 | 返回 false |
| `EAFNOSUPPORT` | 地址族不支持 | 返回 false |
| `EADDRNOTAVAIL` | 地址不可用 | 返回 false |
| `EINVAL` (Linux) | 绑定回环时的特殊错误 | 返回 false（不抛异常） |
| `EHOSTUNREACH` (Linux) | 无路由到主机 | 返回 false（不抛异常） |
| 其他 | - | 抛出 ConnectException |

---

## 10.10 Inet4AddressImpl vs Inet6AddressImpl 对比

| 维度 | Inet4AddressImpl | Inet6AddressImpl |
|------|-----------------|-----------------|
| **源码行数** | 518 行 | 729 行 |
| **选择条件** | `preferIPv4Stack=true` 或 IPv6 不可用 | 默认（IPv6 可用时） |
| **getaddrinfo hints** | `ai_family = AF_INET` | `ai_family = AF_UNSPEC` |
| **返回地址类型** | 仅 Inet4Address | Inet4Address + Inet6Address |
| **去重比较** | 4 字节 `s_addr` | 4 字节或 16 字节逐字节 |
| **排序** | 无（全是 IPv4） | 按 preferIPv6Address 排序 |
| **ICMP 类型** | ICMP_ECHO | ICMP6_ECHO_REQUEST |
| **ICMP socket** | `SOCK_RAW, IPPROTO_ICMP` | `SOCK_RAW, IPPROTO_ICMPV6` |
| **TTL 选项** | `IP_TTL` | `IPV6_UNICAST_HOPS` |
| **TCP ping 族** | `AF_INET` | `AF_INET6` |
| **macOS 本机降级** | `lookupIfLocalhost(includeV6=false)` | `lookupIfLocalhost(includeV6=true)` |
| **ICMPv6 校验和** | 内核自动 | Linux 需手动 `setsockopt(IPV6_CHECKSUM)` |
| **IPv4 委托** | N/A | `isReachable0` 收到 4 字节地址时委托给 Inet4Impl |
| **recvbuf 解析** | 跳过 IP 头 (`ip->ip_hl << 2`) | 无 IP 头（IPv6 RAW socket 特性） |

---

## 10.11 NameService 双实现

### 10.11.1 PlatformNameService（默认）

```java
private static final class PlatformNameService implements NameService {
    public InetAddress[] lookupAllHostAddr(String host) throws UnknownHostException {
        return impl.lookupAllHostAddr(host);  // 直接委托给 native
    }
    public String getHostByAddr(byte[] addr) throws UnknownHostException {
        return impl.getHostByAddr(addr);      // 直接委托给 native
    }
}
```

纯代理，无额外逻辑。

### 10.11.2 HostsFileNameService

通过 `-Djdk.net.hosts.file=/path/to/hosts` 激活：

- **`lookupAllHostAddr(host)`**：扫描文件每一行，匹配 hostname，提取 IP 地址
- **`getHostByAddr(addr)`**：扫描文件每一行，匹配 IP 地址，提取 hostname
- 文件格式同 `/etc/hosts`：`IP_ADDRESS hostname [alias...]`
- 以 `#` 开头的行是注释
- 每次调用都重新打开文件（无缓存），适合测试

**用途**：
- 集成测试中模拟 DNS 解析结果
- 避免测试依赖外部 DNS 服务器
- 容器环境中覆盖 DNS 行为

---

## 10.12 InetAddressHolder — 地址存储内部类

`InetAddress` 的实际数据存储在 `InetAddressHolder` 内部类中：

```java
static class InetAddressHolder {
    String originalHostName;    // 原始主机名（SSL 端点验证用）
    String hostName;            // 主机名
    int address;                // IPv4 地址（32位 int）
    int family;                 // 地址族：1=IPv4, 2=IPv6
}
```

**为什么用 holder 模式？**

历史原因：早期版本 `address`/`family`/`hostName` 是 `InetAddress` 的直接字段。后来为了序列化兼容性和内部重构，移到了 holder 中。C 代码通过 `ia_holderID` 先获取 holder 对象，再访问具体字段。

C 层的 accessor 函数（`net_util.c`）封装了这一层间接访问：

```c
void setInetAddress_addr(JNIEnv *env, jobject iaObj, int address) {
    jobject holder = GetObjectField(iaObj, ia_holderID);    // 获取 holder
    SetIntField(holder, iac_addressID, address);            // 设置 address
}
```

---

## 10.13 in_cksum() — ICMP 校验和计算

`net_util.c` 第 307-327 行实现了标准的 Internet 校验和算法（RFC 1071）：

```c
unsigned short in_cksum(unsigned short *addr, int len) {
    int nleft = len, sum = 0;
    unsigned short *w = addr, answer = 0;
    
    // 每次取 2 字节累加
    while (nleft > 1) {
        sum += *w++;
        nleft -= 2;
    }
    
    // 如果剩余 1 字节，补零后加入
    if (nleft == 1) {
        *(unsigned char *)(&answer) = *(unsigned char *)w;
        sum += answer;
    }
    
    // 折叠进位
    sum = (sum >> 16) + (sum & 0xffff);
    sum += (sum >> 16);
    answer = ~sum;              // 取反
    return answer;
}
```

**IPv4 ICMP** 需要手动计算校验和。**IPv6 ICMPv6** 的校验和由内核计算（Linux 通过 `IPV6_CHECKSUM` socket 选项指示偏移）。

---

## 10.14 生产环境关键问题

### 10.14.1 DNS 超时导致服务不可用

**问题**：`getaddrinfo()` 没有超时参数。当 DNS 服务器宕机时：

```
默认 /etc/resolv.conf:
  options timeout:5 attempts:2
  nameserver 10.0.0.1
  nameserver 10.0.0.2

最坏场景：5s × 2次 × 2个nameserver = 20s 阻塞
如果有 search domain：可能翻倍
```

**解决方案**：
1. 优化 `resolv.conf`：`options timeout:1 attempts:1 rotate`
2. 使用非阻塞 DNS 库（如 Netty 的 `DnsAddressResolverGroup`）
3. 本地 DNS 缓存（如 nscd/dnsmasq/coredns）

### 10.14.2 永久缓存导致流量不切换

**问题**：有 SecurityManager 时，默认 `networkaddress.cache.ttl = -1`（永久缓存）

```
部署时 CDN IP = 1.1.1.1
CDN 切换后 IP = 2.2.2.2
Java 进程永远使用 1.1.1.1 → 流量黑洞
```

**解决方案**：
```
# java.security 或启动参数
networkaddress.cache.ttl=30
# 或
-Dsun.net.inetaddr.ttl=30
```

### 10.14.3 isReachable() 不可靠

**问题**：`isReachable()` 在非 root 环境下只能用 TCP ping 端口 7

```java
InetAddress.getByName("8.8.8.8").isReachable(1000);
// root: ICMP ping → true
// 非 root: TCP connect 端口 7 → 大概率 false（防火墙丢包）
```

**解决方案**：不要用 `isReachable()` 做生产环境的健康检查，改用应用层协议探测。

---

## 10.15 面试高频问题

**Q1：`InetAddress.getByName()` 是否线程安全？**

是。缓存用 `ConcurrentHashMap`，过期集用 `ConcurrentSkipListSet`，每个 hostname 的 DNS 查找通过 `synchronized(NameServiceAddresses)` 保证单线程执行。但注意 `getaddrinfo()` 本身是线程安全的（POSIX 要求），所以不同 hostname 的查找可以并行。

**Q2：DNS 解析结果在 Java 中会缓存多久？**

取决于是否有 SecurityManager：
- 有 SecurityManager（Tomcat 等）：永久缓存（`-1`），除非设置 `networkaddress.cache.ttl`
- 无 SecurityManager：30 秒
- 解析失败：默认 10 秒（`networkaddress.cache.negative.ttl`）

**Q3：为什么 Java DNS 解析没有超时设置？**

因为底层 `getaddrinfo()` 是 POSIX/libc 函数，没有超时参数。超时由 `resolv.conf` 控制。Java 17 引入了 `jdk.net.hosts.file` 可以绕过，但仍无原生超时支持。

**Q4：`isReachable()` 为什么不准确？**

非 root 环境无法发送 ICMP，降级为 TCP connect 端口 7。现代服务器不开端口 7，防火墙也可能丢包。因此 `isReachable()`  返回 false 不代表主机不可达。

**Q5：`getHostName()` 为什么要做两次 DNS 查找？**

防 DNS 欺骗。先反查（IP → hostname），再正查（hostname → IP[]），验证正查结果包含原始 IP。这确保攻击者不能通过伪造 PTR 记录冒充合法主机。

**Q6：`preferIPv6Address` 有什么影响？**

影响 `getaddrinfo()` 返回结果的排序。`getByName()` 返回数组第一个元素，所以排序直接决定了用 IPv4 还是 IPv6 地址连接。在双栈环境中，`-Djava.net.preferIPv6Addresses=true` 会让应用优先使用 IPv6。

---

## 10.16 源码文件交叉引用

| 文件 | 路径 | 行数 | 角色 |
|------|------|------|------|
| `Inet6AddressImpl.c` | `unix/native/libnet/` | 729 | 核心 JNI（标准路径）：lookupAllHostAddr→getaddrinfo(AF_UNSPEC)+去重+按preferIPv6排序 / getHostByAddr→getnameinfo(dual-stack) / isReachable0→ICMP6 ping6+tcp_ping6 / getLocalHostName→gethostname / macOS lookupIfLocalhost→getifaddrs |
| `Inet4AddressImpl.c` | `unix/native/libnet/` | 518 | IPv4-only JNI：lookupAllHostAddr→getaddrinfo(AF_INET) / getHostByAddr→getnameinfo(AF_INET) / isReachable0→ICMP ping4+tcp_ping4 / getLocalHostName→gethostname |
| `InetAddress.java` | `share/classes/java/net/` | 1793 | 顶层 API + 两级缓存(ConcurrentHashMap+ConcurrentSkipListSet) + NameServiceAddresses/CachedAddresses + PlatformNameService/HostsFileNameService + InetAddressImplFactory + getByName→getAllByName→getAllByName0→getAddressesFromNameService调用链 + getHostFromNameService反向+防欺骗验证 + getLocalHost(5秒缓存) |
| `InetAddressImpl.java` | `share/classes/java/net/` | 49 | 接口定义：getLocalHostName/lookupAllHostAddr/getHostByAddr/isReachable/anyLocalAddress/loopbackAddress |
| `Inet4AddressImpl.java` | `share/classes/java/net/` | 75 | IPv4 实现：native方法声明 + anyLocalAddress(0.0.0.0) + loopbackAddress(127.0.0.1) + isReachable过滤IPv4网卡地址 |
| `Inet6AddressImpl.java` | `share/classes/java/net/` | 122 | 双栈实现：native方法声明 + anyLocalAddress(::或0.0.0.0按偏好) + loopbackAddress(::1或127.0.0.1按偏好) + isReachable匹配地址族+scope_id |
| `InetAddress.c` | `share/native/libnet/` | 78 | InetAddress.init()：缓存7个JNI字段ID(ia_class/iac_class/ia_holderID/ia_preferIPv6AddressID/iac_addressID/iac_familyID/iac_hostNameID/iac_origHostNameID) |
| `InetAddressImplFactory.c` | `unix/native/libnet/` | 47 | isIPv6Supported()→ipv6_available()→IPv6_supported()&!preferIPv4Stack |
| `net_util.c` | `share/native/libnet/` | 328 | JNI_OnLoad(IPv6/REUSEPORT检测+platformInit) + initInetAddressIDs(三init合一) + 地址accessor(setInetAddress_addr/setInet6Address_ipaddress等) + NET_SockaddrToInetAddress + in_cksum(ICMP校验和) |
| `net_util_md.c` | `unix/native/libnet/` | 1102 | NET_ThrowUnknownHostExceptionWithGaiError(gai_strerror→UnknownHostException) + IPv6_supported(尝试socket(AF_INET6)) + platformInit |
| `InetAddressCachePolicy.java` | `share/classes/sun/net/` | 220 | 缓存策略：FOREVER(-1)/NEVER(0)/DEFAULT_POSITIVE(30s) + networkaddress.cache.ttl/negative.ttl读取 + 有SecurityManager默认FOREVER |
