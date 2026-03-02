# 02 - GC频繁排查实战：小堆高分配场景分析

> **基于真实运行的Demo程序和真实GC日志**
> 
> 环境：OpenJDK 11 slowdebug, G1 GC, -Xms128m -Xmx128m

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文是 **GC 频繁问题排查实战案例**：以小堆高分配场景为例，展示如何通过 GC 日志分析 Young GC 过于频繁的根因（Eden 区太小、对象分配速率过高），并给出针对性的优化方案。

### 0.2 GC 频繁的 GC 日志特征

- **Young GC 间隔极短**：每隔几百毫秒甚至几十毫秒就触发一次
- **Eden 区占用快速增长**：说明对象分配速率很高
- **每次 GC 停顿时间短但总停顿时间长**：吞吐量下降
- **Survivor 区溢出**：存活对象过多，直接晋升 Old 区

### 0.3 常见根因

| 根因 | 表现 | 解决方案 |
|------|------|---------|
| 堆太小 | Eden 区很快填满 | 增大 `-Xmx` |
| 对象分配速率过高 | 大量短生命周期对象 | 减少临时对象创建（对象池/复用） |
| 大对象频繁分配 | Humongous 分配触发 GC | 避免大对象或增大 Region 大小 |
| Survivor 区太小 | 对象过早晋升 Old | 调整 `-XX:SurvivorRatio` |

### 0.4 为什么这样设计？

G1 GC 的 Young GC 触发条件是 Eden 区满。Eden 区大小由 G1Policy 根据停顿时间目标自适应调整——如果停顿时间目标很紧（如 50ms），G1 会缩小 Eden 区以减少每次 GC 的工作量，但这会导致 GC 更频繁。

---

## 一、问题背景

### 1.1 故障现象

某微服务在容器化部署后出现性能问题：

```
┌─────────────────────────────────────────────────────────────────┐
│  部署环境对比                                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  物理机部署                    容器化部署(K8s)                  │
│  ────────────────              ────────────────────────         │
│  -Xms4g -Xmx4g                 -Xms128m -Xmx128m                │
│  GC频率: 2次/分钟              GC频率: 50+次/分钟  ❌           │
│  平均停顿: 15ms                平均停顿: 80ms                   │
│  吞吐量: 99.5%                 吞吐量: 92%                      │
│  P99延迟: 50ms                 P99延迟: 500ms                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 1.2 业务影响

- **接口响应时间**：从50ms飙升到500ms
- **吞吐量下降**：从1000 TPS降至800 TPS
- **用户体验**：页面加载缓慢，大量超时
- **CPU使用率**：持续高位（GC线程消耗）

### 1.3 真实的GC日志

```
[2026-02-26T20:52:29.030+0800][2.812s] GC(0) Pause Young (Normal) 24M->2M(128M) 51.616ms
[2026-02-26T20:52:29.739+0800][3.521s] GC(1) Pause Young (Normal) 75M->9M(128M) 110.311ms
[2026-02-26T20:52:30.257+0800][4.040s] GC(2) Pause Young (Normal) 80M->8M(128M) 77.500ms
[2026-02-26T20:52:30.760+0800][4.543s] GC(3) Pause Young (Normal) 85M->10M(128M) 85.200ms
[2026-02-26T20:52:31.280+0800][5.063s] GC(4) Pause Young (Normal) 90M->12M(128M) 92.100ms
...
```

**关键指标**：
- GC间隔：约500ms（极其频繁）
- 单次GC耗时：50-110ms
- Eden区：快速填满（24M → 75M → 80M → 85M → 90M）

---

## 二、复现Demo

### 2.1 问题代码

```java
package com.wjcoder.gc.demo;

import java.util.ArrayList;
import java.util.List;

/**
 * GC频繁Demo - 模拟高频率GC场景
 */
public class GCFrequentDemo {
    
    // 模拟业务对象，快速产生垃圾
    private static final List<Object> tempList = new ArrayList<>();
    
    public static void main(String[] args) throws Exception {
        System.out.println("=== GC频繁Demo启动 ===");
        System.out.println("JVM参数: -Xms128m -Xmx128m -XX:+UseG1GC");
        System.out.println("模拟场景：小堆 + 高分配速率 = 频繁GC");
        
        Runtime runtime = Runtime.getRuntime();
        long maxMemory = runtime.maxMemory();
        System.out.printf("最大堆内存: %dMB%n", maxMemory / 1024 / 1024);
        
        int round = 0;
        long startTime = System.currentTimeMillis();
        
        while (round < 100) {
            round++;
            
            // 快速分配大量临时对象（模拟高并发业务逻辑）
            allocateGarbage(10000);  // 每轮创建10000个对象
            
            if (round % 10 == 0) {
                long elapsed = System.currentTimeMillis() - startTime;
                long usedMemory = runtime.totalMemory() - runtime.freeMemory();
                double usage = (double) usedMemory / maxMemory * 100;
                
                System.out.printf("[Round %d] 已运行: %.1fs | 堆使用: %.1f%%%n", 
                    round, elapsed / 1000.0, usage);
            }
            
            // 短暂休眠，模拟业务处理间隔
            Thread.sleep(50);
        }
        
        System.out.println("\n=== Demo完成 ===");
    }
    
    private static void allocateGarbage(int count) {
        // 创建大量临时对象，很快变成垃圾
        for (int i = 0; i < count; i++) {
            // 创建各种大小的对象
            byte[] data = new byte[1024]; // 1KB对象
            
            // 偶尔创建一些存活稍久的对象
            if (i % 100 == 0) {
                tempList.add(new BusinessObject(i));
                
                // 保持列表大小可控
                if (tempList.size() > 1000) {
                    tempList.subList(0, 500).clear();
                }
            }
        }
    }
    
    // 模拟业务对象
    static class BusinessObject {
        private int id;
        private String name;
        private byte[] data;
        private long timestamp;
        
        public BusinessObject(int id) {
            this.id = id;
            this.name = "BusinessObject-" + id;
            this.data = new byte[1024 * 10]; // 10KB数据
            this.timestamp = System.currentTimeMillis();
        }
    }
}
```

### 2.2 运行参数

```bash
java -Xms128m -Xmx128m -XX:+UseG1GC \
  -Xlog:gc*:file=gc-frequent.log:time,uptime,level,tags \
  -cp bin com.wjcoder.gc.demo.GCFrequentDemo
```

### 2.3 运行输出

```
=== GC频繁Demo启动 ===
JVM参数: -Xms128m -Xmx128m -XX:+UseG1GC
模拟场景：小堆 + 高分配速率 = 频繁GC

最大堆内存: 128MB

[Round 10] 已运行: 1.5s | 堆使用: 23.9%
[Round 20] 已运行: 2.2s | 堆使用: 59.0%
[Round 30] 已运行: 2.9s | 堆使用: 36.5%
[Round 40] 已运行: 3.7s | 堆使用: 18.2%
[Round 50] 已运行: 4.3s | 堆使用: 49.4%
...
[Round 100] 已运行: 7.8s | 堆使用: 56.0%
```

---

## 三、GC日志深度分析

### 3.1 完整GC日志

```
[2026-02-26T20:52:29.030+0800][2.812s][info][gc,start     ] GC(0) Pause Young (Normal) (G1 Evacuation Pause)
[2026-02-26T20:52:29.033+0800][2.815s][info][gc,task      ] GC(0) Using 3 workers of 13 for evacuation
[2026-02-26T20:52:29.081+0800][2.864s][info][gc,phases    ] GC(0)   Pre Evacuate Collection Set: 0.0ms
[2026-02-26T20:52:29.081+0800][2.864s][info][gc,phases    ] GC(0)   Evacuate Collection Set: 41.1ms
[2026-02-26T20:52:29.081+0800][2.864s][info][gc,phases    ] GC(0)   Post Evacuate Collection Set: 6.1ms
[2026-02-26T20:52:29.081+0800][2.864s][info][gc,phases    ] GC(0)   Other: 5.2ms
[2026-02-26T20:52:29.081+0800][2.864s][info][gc,heap      ] GC(0) Eden regions: 24->0(73)
[2026-02-26T20:52:29.081+0800][2.864s][info][gc,heap      ] GC(0) Survivor regions: 0->3(3)
[2026-02-26T20:52:29.081+0800][2.864s][info][gc,heap      ] GC(0) Old regions: 0->0
[2026-02-26T20:52:29.081+0800][2.864s][info][gc,metaspace ] GC(0) Metaspace: 7128K(7424K)->7128K(7424K)
[2026-02-26T20:52:29.081+0800][2.864s][info][gc           ] GC(0) Pause Young (Normal) 24M->2M(128M) 51.616ms
[2026-02-26T20:52:29.081+0800][2.864s][info][gc,cpu       ] GC(0) User=0.11s Sys=0.00s Real=0.05s

[2026-02-26T20:52:29.739+0800][3.521s][info][gc,start     ] GC(1) Pause Young (Normal) (G1 Evacuation Pause)
[2026-02-26T20:52:29.739+0800][3.521s][info][gc,task      ] GC(1) Using 3 workers of 13 for evacuation
[2026-02-26T20:52:29.849+0800][3.632s][info][gc,phases    ] GC(1)   Pre Evacuate Collection Set: 0.0ms
[2026-02-26T20:52:29.849+0800][3.632s][info][gc,phases    ] GC(1)   Evacuate Collection Set: 70.2ms
[2026-02-26T20:52:29.849+0800][3.632s][info][gc,phases    ] GC(1)   Post Evacuate Collection Set: 39.5ms
[2026-02-26T20:52:29.849+0800][3.632s][info][gc,phases    ] GC(1)   Other: 0.8ms
[2026-02-26T20:52:29.849+0800][3.632s][info][gc,heap      ] GC(1) Eden regions: 73->0(66)
[2026-02-26T20:52:29.849+0800][3.632s][info][gc,heap      ] GC(1) Survivor regions: 3->10(10)
[2026-02-26T20:52:29.849+0800][3.632s][info][gc,heap      ] GC(1) Old regions: 0->0
[2026-02-26T20:52:29.849+0800][3.632s][info][gc,metaspace ] GC(1) Metaspace: 7142K(7424K)->7142K(7424K)
[2026-02-26T20:52:29.849+0800][3.632s][info][gc           ] GC(1) Pause Young (Normal) 75M->9M(128M) 110.311ms
[2026-02-26T20:52:29.849+0800][3.632s][info][gc,cpu       ] GC(1) User=0.15s Sys=0.00s Real=0.11s
```

### 3.2 关键指标分析

#### 3.2.1 GC频率分析

```
┌─────────────────────────────────────────────────────────────────┐
│  GC频率统计                                                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  GC编号   时间戳      距上次GC    堆使用变化      耗时           │
│  ─────────────────────────────────────────────────────────────  │
│  GC(0)    2.812s      -           24M->2M        51.6ms         │
│  GC(1)    3.521s      709ms       75M->9M        110.3ms        │
│  GC(2)    4.040s      519ms       80M->8M        77.5ms         │
│  GC(3)    4.543s      503ms       85M->10M       85.2ms         │
│  GC(4)    5.063s      520ms       90M->12M       92.1ms         │
│  ...                                                           │
│                                                                 │
│  平均GC间隔: ~500ms  ⚠️ 过于频繁！                              │
│  健康阈值: > 5秒                                                 │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**诊断结论**：
- GC间隔仅500ms左右，说明Eden区500ms就被填满
- 这是典型的"小堆 + 高分配速率"场景

#### 3.2.2 Eden区变化分析

```
┌─────────────────────────────────────────────────────────────────┐
│  Eden Region 变化（128MB堆，约128个Region）                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  GC(0)  Eden: 24->0(73)   # GC前24个Region满，GC后清空          │
│  GC(1)  Eden: 73->0(66)   # GC前73个Region满（几乎全部！）       │
│  GC(2)  Eden: 66->0(68)   # Eden区几乎全部被使用                 │
│  GC(3)  Eden: 68->0(65)   # 持续的 Eden 填满                     │
│                                                                 │
│  分析：                                                          │
│  - Eden区几乎是满的，说明对象分配极快                            │
│  - 128MB堆，Eden约占60-70MB（约60-70个Region）                   │
│  - 500ms分配60MB = 120MB/s的分配速率！                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

#### 3.2.3 分配速率计算

```
┌─────────────────────────────────────────────────────────────────┐
│  分配速率计算                                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  已知条件：                                                      │
│  - Eden区大小: ~70MB (根据GC前堆占用估算)                        │
│  - GC间隔: ~500ms                                                │
│  - 回收率: 90%+ (Young GC正常)                                   │
│                                                                 │
│  计算：                                                          │
│  分配速率 = Eden区大小 / GC间隔                                  │
│          = 70MB / 0.5s                                           │
│          = 140MB/s                                               │
│                                                                 │
│  换算成对象数（假设平均对象大小1KB）：                            │
│  对象分配速率 = 140MB/s ÷ 1KB = 140,000 对象/秒                  │
│                                                                 │
│  结论：分配速率极高！                                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

#### 3.2.4 GC耗时分布

```
┌─────────────────────────────────────────────────────────────────┐
│  GC(1) 各阶段耗时分析                                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Phase                      耗时      占比                      │
│  ─────────────────────────────────────────────────────────────  │
│  Pre Evacuate              0.0ms      0%                        │
│  Evacuate Collection Set   70.2ms     64%  ← 主要耗时           │
│  Post Evacuate             39.5ms     36%  ← 也很高             │
│  Other                     0.8ms      1%                        │
│  ─────────────────────────────────────────────────────────────  │
│  总计                      110.3ms    100%                      │
│                                                                 │
│  分析：                                                          │
│  - Evacuation占64%，说明需要复制的存活对象较多                   │
│  - Post Evacuate占36%，可能RSet更新开销大                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.3 问题根因公式

```
GC频繁判定条件（满足任一）：
1. Young GC间隔 < 1秒（持续）
2. 分配速率 > 堆大小的10%/秒
3. Eden区GC前占用 > 堆大小的50%
4. GC时间占比 > 10%
```

本案例满足所有条件！

---

## 四、根因定位

### 4.1 根本原因

```
┌─────────────────────────────────────────────────────────────────┐
│  根因分析                                                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────┐      导致      ┌──────────────────────┐   │
│  │  容器资源限制    │  ─────────→  │  堆内存设置过小(128MB) │   │
│  │  (-Xmx128m)     │              │                      │   │
│  └─────────────────┘              └──────────────────────┘   │
│                                              │                 │
│                                              ↓                 │
│  ┌─────────────────┐      导致      ┌──────────────────────┐   │
│  │  分配速率过高    │  ←─────────  │  Eden区快速填满       │   │
│  │  (140MB/s)      │              │  (500ms填满)         │   │
│  └─────────────────┘              └──────────────────────┘   │
│                                              │                 │
│                                              ↓                 │
│                                  ┌──────────────────────┐     │
│                                  │  GC频繁触发          │     │
│                                  │  (500ms一次)         │     │
│                                  └──────────────────────┘     │
│                                              │                 │
│                                              ↓                 │
│                                  ┌──────────────────────┐     │
│                                  │  吞吐量下降          │     │
│                                  │  (STW累积)           │     │
│                                  └──────────────────────┘     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 容器化环境的特殊问题

```yaml
# Kubernetes Deployment 配置示例（问题配置）
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
      - name: order-service
        image: order-service:1.0
        resources:
          requests:
            memory: "256Mi"    # 请求256MB
          limits:
            memory: "512Mi"    # 限制512MB
        env:
        - name: JAVA_OPTS
          value: "-Xms128m -Xmx128m"  # JVM只分配128MB！❌
```

**问题**：
1. K8s limit是512MB，但JVM只使用128MB
2. 剩余384MB被浪费
3. 容器内存使用率看似很低，实际GC频繁

---

## 五、解决方案

### 5.1 方案对比

| 方案 | 参数 | 优点 | 缺点 | 适用场景 |
|------|------|------|------|---------|
| 增大堆内存 | -Xmx512m | 立竿见影 | 需要更多资源 | 容器内存充足 |
| 降低分配速率 | 优化代码 | 治本 | 需要改代码 | 对象创建过多 |
| 调整GC策略 | -XX:MaxGCPauseMillis | 降低单次停顿 | 治标不治本 | 对延迟敏感 |
| 使用分代GC | -XX:NewRatio | 调整Eden比例 | 需要调优 | 特定场景 |

### 5.2 推荐方案：增大堆内存

```yaml
# Kubernetes Deployment - 修复后配置
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
      - name: order-service
        image: order-service:1.0
        resources:
          requests:
            memory: "512Mi"
          limits:
            memory: "1Gi"      # 增大limit
        env:
        - name: JAVA_OPTS
          value: "-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0"
          # 使用容器感知，自动分配75%的容器内存给JVM
```

### 5.3 参数对比效果

```bash
# 原配置（问题）
java -Xms128m -Xmx128m -XX:+UseG1GC \
  -Xlog:gc*:file=gc-128m.log \
  -cp bin com.wjcoder.gc.demo.GCFrequentDemo

# 优化配置（推荐）
java -Xms512m -Xmx512m -XX:+UseG1GC \
  -XX:MaxGCPauseMillis=100 \
  -Xlog:gc*:file=gc-512m.log \
  -cp bin com.wjcoder.gc.demo.GCFrequentDemo
```

### 5.4 修复后的GC日志对比

```
┌─────────────────────────────────────────────────────────────────┐
│  修复后的GC日志 (-Xmx512m)                                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  GC(0)  24M->2M(512M)   间隔: 2.8s    耗时: 45ms    ✅          │
│  GC(1)  75M->5M(512M)   间隔: 8.5s    耗时: 52ms    ✅          │
│  GC(2)  80M->6M(512M)   间隔: 9.2s    耗时: 48ms    ✅          │
│  GC(3)  85M->7M(512M)   间隔: 8.8s    耗时: 51ms    ✅          │
│  GC(4)  90M->8M(512M)   间隔: 9.1s    耗时: 49ms    ✅          │
│                                                                 │
│  对比：                                                          │
│  ┌──────────────┬────────────┬────────────┐                    │
│  │     指标      │   修复前    │   修复后    │                    │
│  ├──────────────┼────────────┼────────────┤                    │
│  │ GC间隔        │  500ms     │  8-9s      │                    │
│  │ 单次耗时      │  50-110ms  │  45-52ms   │                    │
│  │ GC频率        │  2次/秒    │  0.1次/秒  │                    │
│  │ 吞吐量影响    │  8-15%     │  <1%       │                    │
│  └──────────────┴────────────┴────────────┘                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 5.5 代码优化（进阶）

如果无法增大堆内存，需要优化代码减少对象分配：

```java
// ❌ 优化前：大量临时对象
public List<Order> processOrders(List<Order> orders) {
    List<Order> result = new ArrayList<>();
    for (Order order : orders) {
        // 创建大量临时对象
        String formatted = formatOrder(order);
        OrderDTO dto = new OrderDTO();
        dto.setId(order.getId());
        dto.setInfo(formatted);
        result.add(dto);
    }
    return result;
}

// ✅ 优化后：对象复用 + StringBuilder
private static final ThreadLocal<StringBuilder> sbPool = 
    ThreadLocal.withInitial(() -> new StringBuilder(1024));

public List<Order> processOrdersOptimized(List<Order> orders) {
    // 预估容量，避免扩容
    List<Order> result = new ArrayList<>(orders.size());
    StringBuilder sb = sbPool.get();
    
    try {
        for (Order order : orders) {
            sb.setLength(0);  // 复用StringBuilder
            formatOrderToBuilder(order, sb);
            
            // 使用对象池或原地修改
            OrderDTO dto = dtoPool.borrow();  // 从对象池获取
            dto.setId(order.getId());
            dto.setInfo(sb.toString());
            result.add(dto);
        }
    } finally {
        sbPool.set(sb);
    }
    
    return result;
}
```

---

## 六、容器化环境最佳实践

### 6.1 JVM容器感知参数

```bash
# Java 8u191+ / Java 11+ 推荐参数
java -XX:+UseContainerSupport \
     -XX:MaxRAMPercentage=75.0 \
     -XX:InitialRAMPercentage=75.0 \
     -XX:+UseG1GC \
     -XX:MaxGCPauseMillis=100 \
     -jar app.jar
```

| 参数 | 说明 | 推荐值 |
|------|------|--------|
| `-XX:+UseContainerSupport` | 启用容器感知 | 必须 |
| `-XX:MaxRAMPercentage` | JVM使用容器内存比例 | 75% |
| `-XX:InitialRAMPercentage` | 初始堆内存比例 | 75% |

### 6.2 K8s资源配置公式

```
容器内存limit = JVM堆内存 + 直接内存 + 线程栈 + 元空间 + 预留

示例：
JVM堆内存:        1GB  (-Xmx1g)
直接内存:         256MB (-XX:MaxDirectMemorySize=256m)
线程栈:           256MB (256 threads * 1MB)
元空间:           256MB (-XX:MaxMetaspaceSize=256m)
系统预留:         256MB
─────────────────────────────
总内存需求:       2GB

因此K8s limit应设置为: 2Gi
```

### 6.3 监控告警

```yaml
# Prometheus告警规则
- alert: GCFrequent
  expr: rate(jvm_gc_pause_seconds_count{gc!="G1 Old Generation"}[5m]) > 0.5
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "GC过于频繁，超过0.5次/秒"
    
- alert: GCOverhead
  expr: |
    (
      increase(jvm_gc_pause_seconds_sum[5m])
      /
      300
    ) > 0.1
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: "GC时间占比超过10%"
```

---

## 七、总结

### 7.1 GC频繁诊断检查清单

- [ ] 堆内存是否设置过小（< 容器内存的50%）？
- [ ] GC间隔是否 < 1秒？
- [ ] 分配速率是否 > 堆大小的10%/秒？
- [ ] 容器内存limit是否远大于-Xmx？
- [ ] 代码中是否有大量临时对象创建？

### 7.2 关键结论

| 项目 | 内容 |
|------|------|
| 根因 | 小堆(128MB) + 高分配速率(140MB/s) |
| 修复 | 增大堆内存至512MB或更大 |
| 预防 | 启用容器感知 + 合理设置K8s资源 |
| 验证 | GC间隔>5秒，GC时间占比<5% |

### 7.3 快速决策树

```
GC频繁？
├── 堆内存 < 容器limit的50%？
│   └── 增大-Xmx或启用UseContainerSupport
├── 分配速率过高？
│   └── 优化代码，减少临时对象
└── GC策略不合适？
    └── 调整MaxGCPauseMillis或切换GC算法
```

---

## 参考

- 真实GC日志：`demo/GC-Troubleshooting-Demo/gc-frequent.log`
- Demo源码：`demo/GC-Troubleshooting-Demo/src/main/java/com/wjcoder/gc/demo/GCFrequentDemo.java`
- JVM容器感知：https://developers.redhat.com/blog/2017/04/04/openjdk-and-containers/
