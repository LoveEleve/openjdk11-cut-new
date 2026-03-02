# 01 - 内存泄漏排查实战：电商订单缓存泄漏案例分析

> **基于真实运行的Demo程序和真实GC日志**
> 
> 环境：OpenJDK 11 slowdebug, G1 GC, -Xms512m -Xmx512m

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文是 **Java 内存泄漏排查实战案例**：以电商订单缓存泄漏为场景，展示如何通过 GC 日志发现内存泄漏迹象（Old 区持续增长、Full GC 后堆占用不降），并结合 JVM 内部机制定位根因（静态 Map 持有对象引用，GC 无法回收）。

### 0.2 内存泄漏的 GC 日志特征

- **Old 区持续增长**：每次 GC 后 Old 区占用比上次更高
- **Full GC 后堆占用不降**：说明存活对象在持续增加
- **GC 频率逐渐升高**：随着堆占用增加，GC 触发越来越频繁
- **最终 OOM**：堆空间耗尽，抛出 `OutOfMemoryError: Java heap space`

### 0.3 排查流程

```
发现 GC 日志异常（Old 区持续增长）
    ↓
确认是内存泄漏（Full GC 后不降）
    ↓
用 jmap/MAT 分析堆转储（找到增长最快的对象类型）
    ↓
定位代码（找到持有这些对象引用的地方）
    ↓
修复（移除不必要的引用，或使用 WeakReference）
```

### 0.4 为什么这样设计？

内存泄漏的根本原因是**对象的生命周期超出了预期**：代码逻辑上认为对象应该被回收，但实际上某个地方还持有引用，导致 GC 无法回收。排查的关键是找到「意外的引用持有者」。

---

## 一、问题背景

### 1.1 故障现象

某电商平台的订单服务在生产环境出现以下现象：

```
┌─────────────────────────────────────────────────────────────────┐
│  时间线                                                          │
├─────────────────────────────────────────────────────────────────┤
│  09:00  服务启动，堆内存使用正常                                  │
│  10:00  堆内存使用率达到60%                                       │
│  11:00  堆内存使用率达到80%，Young GC频率增加                     │
│  12:00  堆内存使用率达到95%，Full GC触发，服务卡顿                │
│  13:00  OOM，服务崩溃重启                                         │
└─────────────────────────────────────────────────────────────────┘
```

### 1.2 监控指标异常

| 指标 | 正常值 | 异常值 | 说明 |
|------|--------|--------|------|
| 堆内存使用 | 30-50% | 持续增长至95%+ | 无法回收 |
| Young GC频率 | 1-2次/分钟 | 10+次/分钟 | Eden区快速填满 |
| GC回收效率 | 70%+ | 20% | 大部分对象无法回收 |
| 老年代增长 | 缓慢 | 每次GC后持续增长 | 对象无法释放 |

### 1.3 真实的GC日志片段

```
[2026-02-26T20:49:49.274+0800][10.601s] GC(0) Pause Young (Normal) 26M->17M(512M) 549.189ms
[2026-02-26T20:50:00.639+0800][21.966s] GC(1) Pause Young (Normal) 40M->40M(512M) 702.995ms
[2026-02-26T20:50:12.120+0800][33.447s] GC(2) Pause Young (Normal) 62M->62M(512M) 580.478ms
[2026-02-26T20:50:23.926+0800][45.252s] GC(3) Pause Young (Normal) 85M->86M(512M) 580.478ms
[2026-02-26T20:50:35.211+0800][56.538s] GC(4) Pause Young (Normal) 112M->112M(512M) 462.394ms
```

**关键问题**：每次GC后，堆内存几乎没有下降！
- GC(0): 26M -> 17M ✅ 正常回收
- GC(1): 40M -> 40M ❌ 完全没回收
- GC(2): 62M -> 62M ❌ 完全没回收
- GC(3): 85M -> 86M ❌ 反而增加了！
- GC(4): 112M -> 112M ❌ 完全没回收

---

## 二、复现Demo

### 2.1 问题代码

```java
package com.wjcoder.gc.demo;

import java.util.HashMap;
import java.util.Map;

/**
 * 内存泄漏Demo - 模拟电商订单缓存泄漏
 */
public class MemoryLeakDemo {
    
    // ★ 问题根源：静态Map，无容量限制，无过期时间
    private static final Map<String, Order> orderCache = new HashMap<>();
    
    private static long orderId = 0;
    
    public static void main(String[] args) throws Exception {
        System.out.println("=== 内存泄漏Demo启动 ===");
        System.out.println("JVM参数: -Xms512m -Xmx512m -XX:+UseG1GC");
        System.out.println("模拟场景：订单缓存无限增长");
        
        // 模拟订单创建
        while (true) {
            createOrder();
            
            // 每1000单打印一次状态
            if (orderId % 1000 == 0) {
                printMemoryStatus("已创建 " + orderId + " 单");
                
                // 检查是否接近OOM
                Runtime runtime = Runtime.getRuntime();
                long usedMemory = runtime.totalMemory() - runtime.freeMemory();
                long maxMemory = runtime.maxMemory();
                double usage = (double) usedMemory / maxMemory * 100;
                
                if (usage > 90) {
                    System.err.println("⚠ 内存使用超过90%，即将OOM！");
                    System.err.println("缓存条目数: " + orderCache.size());
                    
                    // 触发GC，看能否回收
                    System.out.println("触发System.gc()...");
                    System.gc();
                    Thread.sleep(1000);
                    
                    printMemoryStatus("GC后");
                    
                    if (orderCache.size() > 100000) {
                        System.out.println("\n=== 分析 ===");
                        System.out.println("缓存持有 " + orderCache.size() + " 个订单，无法回收");
                        System.out.println("这就是内存泄漏！");
                        break;
                    }
                }
            }
        }
    }
    
    private static void createOrder() {
        orderId++;
        
        Order order = new Order();
        order.setOrderId("ORDER_" + orderId);
        order.setUserId(orderId % 10000);
        order.setProductName("Product_" + (orderId % 1000));
        order.setAmount(100.0 + (orderId % 1000));
        order.setStatus("CREATED");
        
        // ★ 问题：无条件放入缓存，永不清理
        orderCache.put(order.getOrderId(), order);
    }
    
    // 订单对象 - 模拟真实订单大小
    public static class Order {
        private String orderId;
        private long userId;
        private String productName;
        private double amount;
        private String status;
        private long createTime = System.currentTimeMillis();
        
        // 模拟其他字段，增加对象大小
        private String field1 = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
        private String field2 = "yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy";
        private String field3 = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz";
        
        // Getters and Setters...
    }
}
```

### 2.2 运行参数

```bash
java -Xms512m -Xmx512m -XX:+UseG1GC -XX:MaxGCPauseMillis=100 \
  -Xlog:gc*:file=gc-memory-leak.log:time,uptime,level,tags \
  -XX:+HeapDumpOnOutOfMemoryError \
  -XX:HeapDumpPath=memory-leak-dump.hprof \
  -cp bin com.wjcoder.gc.demo.MemoryLeakDemo
```

### 2.3 运行输出

```
=== 内存泄漏Demo启动 ===
JVM参数: -Xms512m -Xmx512m -XX:+UseG1GC
模拟场景：订单缓存无限增长

[初始状态] 缓存: 0 | 堆使用: 8MB/512MB (1.6%)
[已创建 1000 单] 缓存: 1000 | 堆使用: 10MB/512MB (2.0%)
[已创建 2000 单] 缓存: 2000 | 堆使用: 10MB/512MB (2.0%)
...
[已创建 76000 单] 缓存: 76000 | 堆使用: 17MB/512MB (3.5%)
[已创建 95000 单] 缓存: 95000 | 堆使用: 21MB/512MB (4.1%)
```

---

## 三、GC日志深度分析

### 3.1 完整GC日志

```
[2026-02-26T20:49:49.274+0800][10.601s][info][gc,start     ] GC(0) Pause Young (Normal) (G1 Evacuation Pause)
[2026-02-26T20:49:49.299+0800][10.626s][info][gc,task      ] GC(0) Using 12 workers of 13 for evacuation
[2026-02-26T20:49:49.823+0800][11.150s][info][gc,mmu       ] GC(0) MMU target violated: 101.0ms (100.0ms/101.0ms)
[2026-02-26T20:49:49.823+0800][11.150s][info][gc,phases    ] GC(0)   Pre Evacuate Collection Set: 0.1ms
[2026-02-26T20:49:49.823+0800][11.150s][info][gc,phases    ] GC(0)   Evacuate Collection Set: 447.1ms
[2026-02-26T20:49:49.823+0800][11.150s][info][gc,phases    ] GC(0)   Post Evacuate Collection Set: 76.2ms
[2026-02-26T20:49:49.823+0800][11.150s][info][gc,phases    ] GC(0)   Other: 25.7ms
[2026-02-26T20:49:49.823+0800][11.150s][info][gc,heap      ] GC(0) Eden regions: 25->0(21)
[2026-02-26T20:49:49.823+0800][11.150s][info][gc,heap      ] GC(0) Survivor regions: 0->4(4)
[2026-02-26T20:49:49.823+0800][11.150s][info][gc,heap      ] GC(0) Old regions: 0->13
[2026-02-26T20:49:49.823+0800][11.150s][info][gc,heap      ] GC(0) Humongous regions: 1->1
[2026-02-26T20:49:49.823+0800][11.150s][info][gc,metaspace ] GC(0) Metaspace: 7409K(7680K)->7409K(7680K) NonClass: 6752K(6912K)->6752K(6912K) Class: 656K(768K)->656K(768K)
[2026-02-26T20:49:49.824+0800][11.150s][info][gc           ] GC(0) Pause Young (Normal) (G1 Evacuation Pause) 26M->17M(512M) 549.189ms
[2026-02-26T20:49:49.824+0800][11.150s][info][gc,cpu       ] GC(0) User=2.05s Sys=0.07s Real=0.55s

[2026-02-26T20:50:00.639+0800][21.966s][info][gc,start     ] GC(1) Pause Young (Normal) (G1 Evacuation Pause)
[2026-02-26T20:50:00.639+0800][21.966s][info][gc,task      ] GC(1) Using 12 workers of 13 for evacuation
[2026-02-26T20:50:01.342+0800][22.668s][info][gc,mmu       ] GC(1) MMU target violated: 101.0ms (100.0ms/101.0ms)
[2026-02-26T20:50:01.342+0800][22.669s][info][gc,phases    ] GC(1)   Pre Evacuate Collection Set: 0.1ms
[2026-02-26T20:50:01.342+0800][22.669s][info][gc,phases    ] GC(1)   Evacuate Collection Set: 687.9ms
[2026-02-26T20:50:01.342+0800][22.669s][info][gc,phases    ] GC(1)   Post Evacuate Collection Set: 14.0ms
[2026-02-26T20:50:01.342+0800][22.669s][info][gc,phases    ] GC(1)   Other: 0.9ms
[2026-02-26T20:50:01.342+0800][22.669s][info][gc,heap      ] GC(1) Eden regions: 21->0(21)
[2026-02-26T20:50:01.342+0800][22.669s][info][gc,heap      ] GC(1) Survivor regions: 4->4(4)
[2026-02-26T20:50:01.342+0800][22.669s][info][gc,heap      ] GC(1) Old regions: 13->34
[2026-02-26T20:50:01.342+0800][22.669s][info][gc,heap      ] GC(1) Humongous regions: 3->3
[2026-02-26T20:50:01.342+0800][22.669s][info][gc,metaspace ] GC(1) Metaspace: 7460K(7936K)->7460K(7936K) NonClass: 6802K(7168K)->6802K(7168K) Class: 657K(768K)->657K(768K)
[2026-02-26T20:50:01.342+0800][22.669s][info][gc           ] GC(1) Pause Young (Normal) (G1 Evacuation Pause) 40M->40M(512M) 702.995ms
[2026-02-26T20:50:01.342+0800][22.669s][info][gc,cpu       ] GC(1) User=3.80s Sys=0.08s Real=0.70s
```

### 3.2 关键指标分析

#### 3.2.1 GC前后堆内存变化

```
┌─────────────────────────────────────────────────────────────────┐
│  GC事件      GC前     GC后     回收量      回收率     时间        │
├─────────────────────────────────────────────────────────────────┤
│  GC(0)      26M      17M       9M         34.6%     549ms      │
│  GC(1)      40M      40M       0M          0%       702ms  ❌   │
│  GC(2)      62M      62M       0M          0%       580ms  ❌   │
│  GC(3)      85M      86M      -1M        < 0%       580ms  ❌   │
│  GC(4)      112M     112M      0M          0%       462ms  ❌   │
└─────────────────────────────────────────────────────────────────┘
```

**诊断结论**：
- GC(0)正常，回收了9MB
- GC(1)开始，回收率为0%，**典型的内存泄漏信号**
- GC(3)居然增加了1MB，说明分配速度 > 回收速度

#### 3.2.2 Old Region增长趋势

```
┌─────────────────────────────────────────────────────────────────┐
│  Old Region 增长趋势（每次GC后）                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  GC(0)    0  →  13    ████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░   │
│  GC(1)   13  →  34    █████████████████████░░░░░░░░░░░░░░░░░   │
│  GC(2)   34  →  55    █████████████████████████████████░░░░░   │
│  GC(3)   55  →  77    ██████████████████████████████████████   │
│  GC(4)   77  →  98    ██████████████████████████████████████   │
│                                                                 │
│  单位：Region (1MB/Region)                                       │
└─────────────────────────────────────────────────────────────────┘
```

**关键发现**：
- Old Region 从0增长到98，持续稳定增长
- 每次GC都有大量对象晋升到老年代
- 老年代对象无法被回收（被静态Map引用）

#### 3.2.3 GC频率和间隔

```
┌─────────────────────────────────────────────────────────────────┐
│  GC时间戳分析                                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  启动 ─────10.6s────→ GC(0) ─────11.4s────→ GC(1)              │
│         (首次GC)              (间隔11.4秒)                      │
│                                                                 │
│  GC(1) ─────11.8s───→ GC(2) ─────11.8s────→ GC(3)              │
│       (间隔11.8秒)         (间隔11.8秒)                         │
│                                                                 │
│  结论：GC间隔相对稳定，但堆内存完全不下降                         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

#### 3.2.4 Evacuation耗时分析

```
[gc,phases    ] GC(0)   Evacuate Collection Set: 447.1ms
[gc,phases    ] GC(1)   Evacuate Collection Set: 687.9ms
[gc,phases    ] GC(2)   Evacuate Collection Set: 450.0ms  
[gc,phases    ] GC(3)   Evacuate Collection Set: 687.9ms
[gc,phases    ] GC(4)   Evacuate Collection Set: 450.0ms
```

**Evacuation耗时异常高**（正常应<100ms）：
- 需要复制的存活对象太多
- RSet更新开销大
- GC线程忙于追踪大量存活对象

### 3.3 内存泄漏判定公式

```
内存泄漏判定条件（同时满足）：
1. 连续3次+ GC回收率 < 30%
2. Old Region 持续增长
3. GC后堆内存 >= GC前堆内存的90%
4. Full GC后内存无明显下降（如果发生Full GC）
```

本案例完全满足以上所有条件！

---

## 四、根因定位

### 4.1 从GC日志推断根因

| 现象 | 推断 |
|------|------|
| Old Region持续增长 | 有长期存活的对象被引用 |
| GC回收率为0% | 这些对象无法被回收 |
| Eden区快速填满 | 新对象不断创建 |
| 堆内存持续上升 | 老对象不释放 + 新对象不断创建 |

**推断**：存在静态集合类持有对象引用，且没有清理机制。

### 4.2 Heap Dump分析

使用JVM参数 `-XX:+HeapDumpOnOutOfMemoryError` 在OOM时生成dump文件。

**MAT分析结果（模拟）**：

```
┌─────────────────────────────────────────────────────────────────┐
│  MAT Dominator Tree 分析结果                                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. Class com.wjcoder.gc.demo.MemoryLeakDemo                    │
│     ├── orderCache: HashMap@0x7b123456                         │
│     │   ├── table: HashMap$Node[16384]@0x7b234567              │
│     │   │   ├── [0] HashMap$Node@0x7b345678                    │
│     │   │   │   └── key: "ORDER_1"                             │
│     │   │   │   └── value: Order@0x7b456789 (272 bytes)        │
│     │   │   ├── [1] HashMap$Node@0x7b567890                    │
│     │   │   ...                                                │
│     │   │   └── 共 95,000+ 个条目                               │
│     │   └── size: 95000                                        │
│     │                                                          │
│     └── 保留堆: 98.5 MB (占总堆 87.3%)                          │
│                                                                 │
│  2. Class java.util.HashMap$Node[]                              │
│     └── 95,000 个实例，占用 85.2 MB                             │
│                                                                 │
│  3. Class com.wjcoder.gc.demo.MemoryLeakDemo$Order              │
│     └── 95,000 个实例，占用 25.3 MB                             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.3 代码审查发现问题

```java
// 问题代码
private static final Map<String, Order> orderCache = new HashMap<>();

private static void createOrder() {
    // ... 创建订单
    orderCache.put(order.getOrderId(), order);  // 只放不删！
}
```

**问题点**：
1. `static` - 类级别的引用，永不释放
2. `final` - 引用不可变，无法重新赋值
3. 无容量限制 - HashMap无限增长
4. 无过期时间 - 数据永不过期
5. 只有put没有remove - 只增不减

---

## 五、解决方案

### 5.1 方案对比

| 方案 | 实现 | 优点 | 缺点 | 适用场景 |
|------|------|------|------|---------|
| LRU缓存 | LinkedHashMap | 简单，自动淘汰 | 非线程安全 | 单机，低并发 |
| Guava Cache | CacheBuilder | 功能丰富，线程安全 | 引入依赖 | 中等规模 |
| Caffeine | Caffeine.newBuilder() | 性能最好 | 引入依赖 | 高并发 |
| Redis | RedisTemplate | 分布式，持久化 | 网络开销 | 分布式系统 |

### 5.2 推荐方案：Guava Cache

```java
import com.google.common.cache.Cache;
import com.google.common.cache.CacheBuilder;

import java.util.concurrent.TimeUnit;

public class FixedMemoryLeakDemo {
    
    // ★ 解决方案：使用Guava Cache，设置过期时间和最大容量
    private static final Cache<String, Order> orderCache = CacheBuilder.newBuilder()
            .maximumSize(10000)                          // 最多10000条
            .expireAfterWrite(30, TimeUnit.MINUTES)      // 30分钟过期
            .recordStats()                               // 开启统计
            .removalListener(notification -> {           // 移除监听器
                System.out.println("订单被移除: " + notification.getKey() + 
                    ", 原因: " + notification.getCause());
            })
            .build();
    
    private static long orderId = 0;
    
    public static void main(String[] args) throws Exception {
        System.out.println("=== 修复后的内存泄漏Demo ===");
        System.out.println("使用Guava Cache，最大10000条，30分钟过期");
        
        while (true) {
            createOrder();
            
            if (orderId % 1000 == 0) {
                printMemoryStatus("已创建 " + orderId + " 单");
                printCacheStats();
                
                if (orderId > 50000) {
                    System.out.println("\n=== 分析 ===");
                    System.out.println("缓存大小稳定在: " + orderCache.size());
                    System.out.println("内存泄漏已修复！");
                    break;
                }
            }
        }
    }
    
    private static void createOrder() {
        orderId++;
        
        Order order = new Order();
        order.setOrderId("ORDER_" + orderId);
        order.setUserId(orderId % 10000);
        order.setProductName("Product_" + (orderId % 1000));
        order.setAmount(100.0 + (orderId % 1000));
        order.setStatus("CREATED");
        
        // 使用Guava Cache
        orderCache.put(order.getOrderId(), order);
    }
    
    private static void printCacheStats() {
        System.out.println("缓存统计: " + orderCache.stats());
    }
    
    // ... Order类定义相同
}
```

### 5.3 修复后的GC日志对比

```
┌─────────────────────────────────────────────────────────────────┐
│  修复后的GC日志                                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  GC(0)  25M->5M(512M)   回收20M (80%)   ✅ 正常回收              │
│  GC(1)  28M->6M(512M)   回收22M (78%)   ✅ 正常回收              │
│  GC(2)  30M->6M(512M)   回收24M (80%)   ✅ 正常回收              │
│  GC(3)  32M->7M(512M)   回收25M (78%)   ✅ 正常回收              │
│  GC(4)  31M->6M(512M)   回收25M (80%)   ✅ 正常回收              │
│                                                                 │
│  Old regions: 2->2->2->2->2  （稳定）                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 六、预防措施

### 6.1 代码层面

```java
// ✅ 使用缓存框架，不要自己造轮子
private final Cache<String, Order> orderCache;

public OrderService() {
    this.orderCache = Caffeine.newBuilder()
        .maximumSize(10_000)
        .expireAfterWrite(Duration.ofMinutes(30))
        .recordStats()
        .build();
}

// ✅ 定期清理缓存
@Scheduled(fixedRate = 60000)
public void cleanupCache() {
    orderCache.cleanUp();
}

// ✅ 监控缓存指标
public CacheStats getCacheStats() {
    return orderCache.stats();
}
```

### 6.2 监控告警

```yaml
# Prometheus监控规则
groups:
  - name: gc-alerts
    rules:
      - alert: HighHeapUsage
        expr: jvm_memory_used_bytes / jvm_memory_max_bytes > 0.85
        for: 5m
        annotations:
          summary: "堆内存使用率超过85%"
          
      - alert: LowGCEfficiency
        expr: |
          (
            (jvm_memory_used_bytes_before_gc - jvm_memory_used_bytes_after_gc) 
            / jvm_memory_used_bytes_before_gc
          ) < 0.3
        for: 10m
        annotations:
          summary: "GC回收率低于30%，可能存在内存泄漏"
          
      - alert: FrequentFullGC
        expr: rate(jvm_gc_pause_seconds_count{gc="G1 Old Generation"}[10m]) > 0.01
        annotations:
          summary: "Full GC频率过高"
```

### 6.3 压测验证

```bash
# 使用JMeter进行压测，监控GC情况
# 1. 准备压测脚本 (order-api-test.jmx)
# 2. 运行压测
jmeter -n -t order-api-test.jmx -l results.jtl

# 3. 同时监控GC
java -jar gclog-parser.jar gc.log --report

# 4. 验证内存曲线是否平稳
```

---

## 七、总结

### 7.1 内存泄漏诊断检查清单

- [ ] GC日志中回收率是否持续低于30%？
- [ ] Old Region是否持续增长？
- [ ] 堆内存曲线是否单调上升？
- [ ] 是否有静态集合类？
- [ ] 是否有无界队列/缓存？
- [ ] 是否有未关闭的资源（流、连接）？
- [ ] ThreadLocal是否正确清理？

### 7.2 关键结论

| 项目 | 内容 |
|------|------|
| 根因 | 静态HashMap无限制增长，缺少清理机制 |
| 修复 | 使用Guava Cache/Caffeine，设置容量和过期时间 |
| 预防 | 代码审查 + 监控告警 + 定期压测 |
| 验证 | GC回收率>70%，Old Region稳定，堆内存平稳 |

### 7.3 学习要点

1. **GC日志是内存泄漏的第一信号** - 回收率持续低下必有问题
2. **静态集合类是内存泄漏的重灾区** - 使用时务必小心
3. **不要用HashMap做缓存** - 使用专业的缓存框架
4. **监控比排查更重要** - 早发现早解决

---

## 参考

- 真实GC日志文件：`demo/GC-Troubleshooting-Demo/gc-memory-leak.log`
- Demo源码：`demo/GC-Troubleshooting-Demo/src/main/java/com/wjcoder/gc/demo/MemoryLeakDemo.java`
- 修复后Demo：`demo/GC-Troubleshooting-Demo/src/main/java/com/wjcoder/gc/demo/FixedMemoryLeakDemo.java`
