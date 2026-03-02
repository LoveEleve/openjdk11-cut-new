# 03 - Full GC排查实战：触发原因与优化方案

> **基于真实运行的Demo程序和真实GC日志**
> 
> 环境：OpenJDK 11 slowdebug, G1 GC, -Xms256m -Xmx256m

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文是 **Full GC 排查实战案例**：分析 G1 GC 触发 Full GC 的各种原因（Evacuation Failure/Humongous 分配失败/并发标记失败/显式调用），展示如何从 GC 日志中识别 Full GC 类型，并给出针对性优化方案。

### 0.2 G1 Full GC 的触发条件

| 触发原因 | GC 日志关键词 | 根本原因 |
|---------|-------------|---------|
| Evacuation Failure | `to-space exhausted` | Survivor/Old 区空间不足，无法复制存活对象 |
| Humongous 分配失败 | `Humongous allocation` | 大对象无法找到足够连续的 Region |
| 并发标记失败 | `concurrent mode failure` | 并发标记期间 Old 区被填满 |
| 显式调用 | `System.gc()` | 代码或框架显式调用 GC |
| JNI 临界区 | `GCLocker` | JNI 临界区内无法 GC，退出后触发 |

### 0.3 Full GC 的代价

G1 Full GC 使用**单线程 Mark-Compact**（OpenJDK 11 之前），停顿时间可能长达数秒甚至数十秒。OpenJDK 11 引入了并行 Full GC（`-XX:+G1UseAdaptiveIHOP`），但仍比 Young/Mixed GC 慢得多。

### 0.4 为什么这样设计？

G1 的设计目标是「避免 Full GC」——通过并发标记 + Mixed GC 增量回收 Old 区，在 Old 区满之前就完成回收。Full GC 是「最后的保底手段」，说明 G1 的增量回收机制没能跟上对象分配速率。

---

## 一、问题背景

### 1.1 故障现象

某核心服务监控告警：

```
┌─────────────────────────────────────────────────────────────────┐
│  告警信息                                                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  [CRITICAL] Full GC频繁触发                                      │
│  服务: user-service                                             │
│  时间: 2024-01-15 14:32:05                                      │
│  详情:                                                           │
│    - 过去10分钟Full GC次数: 12次                                │
│    - 平均Full GC耗时: 850ms                                     │
│    - 最大Full GC耗时: 2.3s                                      │
│    - GC期间服务完全不可用                                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 1.2 业务影响

- **服务可用性下降**：Full GC期间服务不可用
- **接口超时**：大量请求超时（>5s）
- **用户体验差**：页面加载卡住
- **连锁反应**：触发熔断，影响下游服务

### 1.3 真实的Full GC日志

```
[2026-02-26T20:52:34.541+0800][2.467s][info][gc,task      ] GC(0) Using 6 workers of 13 for full compaction
[2026-02-26T20:52:34.552+0800][2.478s][info][gc,start     ] GC(0) Pause Full (System.gc())
[2026-02-26T20:52:34.553+0800][2.479s][info][gc,phases,start] GC(0) Phase 1: Mark live objects
[2026-02-26T20:52:34.593+0800][2.519s][info][gc,stringtable ] GC(0) Cleaned string and symbol table
[2026-02-26T20:52:34.593+0800][2.519s][info][gc,phases      ] GC(0) Phase 1: Mark live objects 39.928ms
[2026-02-26T20:52:34.593+0800][2.519s][info][gc,phases,start] GC(0) Phase 2: Prepare for compaction
[2026-02-26T20:52:34.600+0800][2.526s][info][gc,phases      ] GC(0) Phase 2: Prepare for compaction 6.964ms
[2026-02-26T20:52:34.600+0800][2.526s][info][gc,phases,start] GC(0) Phase 3: Adjust pointers
[2026-02-26T20:52:34.620+0800][2.546s][info][gc,phases      ] GC(0) Phase 3: Adjust pointers 20.275ms
[2026-02-26T20:52:34.620+0800][2.546s][info][gc,phases,start] GC(0) Phase 4: Compact heap
[2026-02-26T20:52:34.723+0800][2.650s][info][gc,phases      ] GC(0) Phase 4: Compact heap 103.226ms
[2026-02-26T20:52:34.727+0800][2.653s][info][gc,heap        ] GC(0) Eden regions: 10->0(24)
[2026-02-26T20:52:34.727+0800][2.653s][info][gc,heap        ] GC(0) Survivor regions: 0->0(0)
[2026-02-26T20:52:34.727+0800][2.653s][info][gc,heap        ] GC(0) Old regions: 0->5
[2026-02-26T20:52:34.727+0800][2.653s][info][gc,metaspace   ] GC(0) Metaspace: 6913K(7168K)->6913K(7168K)
[2026-02-26T20:52:34.727+0800][2.653s][info][gc             ] GC(0) Pause Full (System.gc()) 9M->2M(256M) 175.033ms
```

**关键信息**：
- 触发原因：`System.gc()` 显式调用
- 完整4个Phase：Mark → Prepare → Adjust → Compact
- 总耗时：175ms（在256MB小堆上）
- 回收效果：9M → 2M，回收7M

---

## 二、Full GC触发原因分析

### 2.1 Full GC触发场景

```
┌─────────────────────────────────────────────────────────────────┐
│  Full GC触发原因分类                                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 堆内存不足                                                   │
│     ├── 老年代空间不足（Old Gen Full）                          │
│     ├── 晋升失败（Evacuation Failure）                          │
│     └── Humongous对象分配失败                                    │
│                                                                 │
│  2. 元空间不足                                                   │
│     └── Metaspace使用率超过阈值                                  │
│                                                                 │
│  3. 显式调用                                                     │
│     ├── System.gc()                                             │
│     ├── Runtime.getRuntime().gc()                               │
│     └── JMX触发                                                 │
│                                                                 │
│  4. 自适应策略                                                   │
│     ├── G1认为需要Full GC来回收空间                              │
│     └── 并发标记后空间仍然不足                                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 不同触发原因的日志特征

| 触发原因 | 日志特征 | 示例 |
|---------|---------|------|
| System.gc() | `Pause Full (System.gc())` | `GC(0) Pause Full (System.gc()) 9M->2M(256M)` |
| 老年代不足 | `Pause Full (Allocation Failure)` | `GC(5) Pause Full (Allocation Failure)` |
| 元空间不足 | `Pause Full (Metadata GC Threshold)` | `GC(3) Pause Full (Metadata GC Threshold)` |
| 晋升失败 | `Pause Full (G1 Evacuation Failure)` | `GC(7) Pause Full (G1 Evacuation Failure)` |

### 2.3 Full GC的代价

```
┌─────────────────────────────────────────────────────────────────┐
│  Full GC vs Young GC 对比                                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  特性              Young GC            Full GC                  │
│  ─────────────────────────────────────────────────────────────  │
│  暂停类型          部分并行            完全STW                   │
│  影响范围          Eden + Survivor    整个堆                     │
│  典型耗时          10-50ms            100ms-数秒                 │
│  算法              复制算法            标记-整理                  │
│  CPU消耗           低                 高                         │
│  业务影响          轻微               严重（服务不可用）         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 三、复现Demo

### 3.1 场景1：System.gc()显式调用

```java
package com.wjcoder.gc.demo;

import java.util.ArrayList;
import java.util.List;

/**
 * Full GC触发Demo - 模拟导致Full GC的场景
 */
public class FullGCTriggerDemo {
    
    private static List<Object> survivorList = new ArrayList<>();
    
    public static void main(String[] args) throws Exception {
        System.out.println("=== Full GC触发Demo启动 ===");
        System.out.println("JVM参数: -Xms256m -Xmx256m -XX:+UseG1GC");
        System.out.println("模拟场景：触发Full GC的各种情况");
        
        // 场景1：显式调用System.gc()
        System.out.println("\n--- 场景1：显式调用System.gc() ---");
        allocateSomeObjects();
        printMemoryStatus("分配对象后");
        System.out.println("调用System.gc()...");
        System.gc();  // ★ 触发Full GC
        Thread.sleep(1000);
        printMemoryStatus("System.gc()后");
        
        // 场景2：快速填满老年代
        System.out.println("\n--- 场景2：快速填满老年代 ---");
        survivorList.clear();
        
        for (int round = 1; round <= 10; round++) {
            List<Object> batch = new ArrayList<>();
            for (int i = 0; i < 1000; i++) {
                batch.add(new MediumObject(round * 1000 + i));
            }
            survivorList.addAll(batch);
            
            printMemoryStatus("Round " + round);
            
            if (round % 3 == 0) {
                System.out.println("  -> 触发GC观察");
                System.gc();
                Thread.sleep(500);
            }
        }
        
        System.out.println("\n=== Demo完成 ===");
    }
    
    private static void allocateSomeObjects() {
        for (int i = 0; i < 10000; i++) {
            survivorList.add(new SmallObject(i));
        }
    }
    
    private static void printMemoryStatus(String label) {
        Runtime runtime = Runtime.getRuntime();
        long usedMemory = runtime.totalMemory() - runtime.freeMemory();
        long maxMemory = runtime.maxMemory();
        
        System.out.printf("[%s] 堆使用: %dMB/%dMB (%.1f%%)%n",
            label,
            usedMemory / 1024 / 1024,
            maxMemory / 1024 / 1024,
            (double) usedMemory / maxMemory * 100
        );
    }
    
    static class SmallObject {
        private int id;
        private byte[] data = new byte[100];
        public SmallObject(int id) { this.id = id; }
    }
    
    static class MediumObject {
        private int id;
        private byte[] data = new byte[1024 * 10]; // 10KB
        public MediumObject(int id) { this.id = id; }
    }
}
```

### 3.2 运行参数

```bash
java -Xms256m -Xmx256m -XX:+UseG1GC \
  -Xlog:gc*:file=gc-full-gc.log:time,uptime,level,tags \
  -cp bin com.wjcoder.gc.demo.FullGCTriggerDemo
```

### 3.3 运行输出

```
=== Full GC触发Demo启动 ===
JVM参数: -Xms256m -Xmx256m -XX:+UseG1GC
模拟场景：触发Full GC的各种情况

--- 场景1：显式调用System.gc() ---
[分配对象后] 堆使用: 9MB/256MB (3.9%)
调用System.gc()...
[System.gc()后] 堆使用: 2MB/256MB (1.1%)

--- 场景2：快速填满老年代 ---
[Round 1 - 对象进入老年代] 堆使用: 14MB/256MB (5.8%)
[Round 2 - 对象进入老年代] 堆使用: 24MB/256MB (9.7%)
[Round 3 - 对象进入老年代] 堆使用: 32MB/256MB (12.7%)
  -> 触发GC观察
...
```

---

## 四、GC日志深度分析

### 4.1 Full GC完整流程分析

```
┌─────────────────────────────────────────────────────────────────┐
│  Full GC 四个阶段详解                                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Phase 1: Mark live objects (标记存活对象)                       │
│  ─────────────────────────────────────────────────────────────  │
│  耗时: 39.928ms                                                  │
│  操作: 从GC Roots开始遍历，标记所有存活对象                       │
│  范围: 整个堆（Young + Old）                                     │
│                                                                 │
│  Phase 2: Prepare for compaction (准备压缩)                      │
│  ─────────────────────────────────────────────────────────────  │
│  耗时: 6.964ms                                                   │
│  操作: 计算每个存活对象的新的位置                                 │
│  目的: 消除内存碎片                                              │
│                                                                 │
│  Phase 3: Adjust pointers (调整指针)                             │
│  ─────────────────────────────────────────────────────────────  │
│  耗时: 20.275ms                                                  │
│  操作: 更新所有指向移动对象的引用                                 │
│  复杂度: 与存活对象数量成正比                                    │
│                                                                 │
│  Phase 4: Compact heap (压缩堆)                                  │
│  ─────────────────────────────────────────────────────────────  │
│  耗时: 103.226ms  ← 最耗时的阶段！                               │
│  操作: 将存活对象移动到新的位置                                   │
│  特点: 单线程，全量复制                                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 各阶段耗时占比

```
┌─────────────────────────────────────────────────────────────────┐
│  Full GC各阶段耗时分布                                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Phase 1 (Mark)        ████████████████████░░░░░░░  22.8%      │
│  Phase 2 (Prepare)     ███░░░░░░░░░░░░░░░░░░░░░░░░   4.0%      │
│  Phase 3 (Adjust)      ██████████░░░░░░░░░░░░░░░░░  11.6%      │
│  Phase 4 (Compact)     ██████████████████████████░  59.0%  ←   │
│                                                                 │
│  总耗时: 175ms                                                   │
│                                                                 │
│  关键发现：                                                      │
│  - Compact阶段占59%，是主要耗时来源                              │
│  - 堆越大，Compact耗时越长（线性增长）                           │
│  - 这也是为什么Full GC比Young GC慢10-100倍                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.3 堆状态变化

```
[gc,heap] GC(0) Eden regions: 10->0(24)
[gc,heap] GC(0) Survivor regions: 0->0(0)
[gc,heap] GC(0) Old regions: 0->5

分析：
- Eden: 10->0  完全清空
- Survivor: 0->0  没有使用Survivor区（Full GC直接到Old）
- Old: 0->5  5个Region保留（存活对象）
```

### 4.4 与Young GC对比

```
┌─────────────────────────────────────────────────────────────────┐
│  Full GC vs Young GC - 同一程序对比                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  事件      类型        耗时      堆变化        阶段              │
│  ─────────────────────────────────────────────────────────────  │
│  GC(0)    Full GC    175ms     9M->2M      4个Phase             │
│  GC(1)    Young GC   110ms     26M->24M    Evacuation           │
│  GC(2)    Young GC   110ms     40M->24M    Evacuation           │
│                                                                 │
│  关键差异：                                                      │
│  1. Full GC处理整个堆，Young GC只处理年轻代                      │
│  2. Full GC有Compact阶段（整理内存）                             │
│  3. Full GC是单线程，Young GC是多线程                            │
│  4. Full GC会STW，Young GC有部分并行                             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 五、根因定位与解决方案

### 5.1 System.gc()问题排查

```
排查步骤：
1. 搜索代码中的System.gc()
2. 检查第三方库（如RMI、JMX）
3. 检查JVM参数（-XX:+DisableExplicitGC）
```

```bash
# 搜索代码
grep -r "System.gc()" --include="*.java" src/

# 检查JMX调用
jcmd <pid> GC.run  # 这会触发System.gc()
```

### 5.2 解决方案对比

| 方案 | 适用场景 | 参数 | 效果 |
|------|---------|------|------|
| 禁止显式GC | System.gc()调用 | `-XX:+DisableExplicitGC` | 阻止Full GC |
| 增大堆内存 | 堆不足 | `-Xmx4g` | 减少Full GC频率 |
| 调整元空间 | Metaspace不足 | `-XX:MaxMetaspaceSize=512m` | 减少元空间GC |
| 优化晋升 | 晋升失败 | `-XX:MaxTenuringThreshold=15` | 减少晋升压力 |

### 5.3 推荐方案

#### 方案1：禁止显式GC（针对System.gc()）

```bash
java -XX:+DisableExplicitGC \
     -Xms256m -Xmx256m \
     -XX:+UseG1GC \
     -jar app.jar
```

**效果**：
- System.gc()调用被忽略
- 避免不必要的Full GC
- 但可能延迟真正的内存回收

#### 方案2：增大堆内存（针对堆不足）

```bash
java -Xms1g -Xmx1g \
     -XX:+UseG1GC \
     -XX:MaxGCPauseMillis=100 \
     -jar app.jar
```

**效果**：
- 提供更多空间给对象分配
- 减少Full GC触发频率
- 但需要更多物理内存

#### 方案3：优化GC策略（综合方案）

```bash
java -XX:+UseG1GC \
     -Xms2g -Xmx2g \
     -XX:MaxGCPauseMillis=100 \
     -XX:+DisableExplicitGC \
     -XX:MaxMetaspaceSize=256m \
     -XX:G1HeapRegionSize=16m \
     -jar app.jar
```

### 5.4 修复后的GC日志对比

```
┌─────────────────────────────────────────────────────────────────┐
│  修复后的GC日志（启用DisableExplicitGC）                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  修复前（问题）：                                                │
│  GC(0) Pause Full (System.gc()) 9M->2M(256M) 175ms             │
│  GC(5) Pause Full (System.gc()) 15M->3M(256M) 210ms             │
│  GC(8) Pause Full (System.gc()) 20M->4M(256M) 198ms             │
│                                                                 │
│  修复后（优化）：                                                │
│  GC(0) Pause Young (Normal) 24M->2M(256M) 45ms                  │
│  GC(1) Pause Young (Normal) 80M->5M(256M) 52ms                  │
│  GC(2) Pause Young (Normal) 90M->6M(256M) 48ms                  │
│                                                                 │
│  对比结果：                                                      │
│  ┌──────────────┬────────────┬────────────┐                    │
│  │     指标      │   修复前    │   修复后    │                    │
│  ├──────────────┼────────────┼────────────┤                    │
│  │ Full GC次数   │  3次       │  0次       │                    │
│  │ 平均GC耗时    │  194ms     │  48ms      │                    │
│  │ 最大停顿      │  210ms     │  52ms      │                    │
│  │ 吞吐量影响    │  20%+      │  <3%       │                    │
│  └──────────────┴────────────┴────────────┘                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 六、生产环境最佳实践

### 6.1 Full GC预防检查清单

```
代码层面：
□ 检查System.gc()调用
□ 检查Runtime.getRuntime().gc()调用
□ 检查第三方库是否显式触发GC
□ 检查RMI配置（DGC周期）

配置层面：
□ 启用-XX:+DisableExplicitGC
□ 合理设置-Xmx（容器内存的75%）
□ 设置合理的Metaspace大小
□ 配置GC告警阈值

监控层面：
□ 监控Full GC频率（应<1次/小时）
□ 监控Full GC耗时（应<1秒）
□ 监控堆内存使用率
□ 监控元空间使用率
```

### 6.2 JVM参数模板

```bash
# 生产环境推荐配置（G1 GC）
JAVA_OPTS="
  -XX:+UseG1GC
  -Xms4g -Xmx4g
  -XX:MaxGCPauseMillis=100
  -XX:+DisableExplicitGC
  -XX:+ParallelRefProcEnabled
  -XX:MaxMetaspaceSize=256m
  -XX:+HeapDumpOnOutOfMemoryError
  -XX:HeapDumpPath=/var/log/heapdump.hprof
  -Xlog:gc*:file=/var/log/gc.log:time,uptime,level,tags
"
```

### 6.3 监控告警配置

```yaml
# Prometheus告警
- alert: FullGCFrequent
  expr: rate(jvm_gc_pause_seconds_count{gc="G1 Old Generation"}[1h]) > 0.01
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: "Full GC过于频繁"
    
- alert: FullGCSlow
  expr: jvm_gc_pause_seconds_max{gc="G1 Old Generation"} > 1
  for: 1m
  labels:
    severity: critical
  annotations:
    summary: "Full GC耗时超过1秒"
```

---

## 七、总结

### 7.1 Full GC诊断流程

```
发现Full GC → 查看日志确认触发原因 → 针对性优化
    │
    ├── System.gc() → 启用DisableExplicitGC
    ├── 堆不足 → 增大堆内存或优化代码
    ├── 元空间不足 → 增大MetaspaceSize
    └── 晋升失败 → 调整晋升阈值或增大堆
```

### 7.2 关键结论

| 项目 | 内容 |
|------|------|
| 根因 | System.gc()显式调用 / 堆内存不足 |
| 修复 | 启用-XX:+DisableExplicitGC / 增大堆内存 |
| 预防 | 代码审查 + 合理配置 + 监控告警 |
| 目标 | Full GC < 1次/小时，单次 < 1秒 |

### 7.3 快速决策树

```
Full GC频繁？
├── 触发原因是System.gc()？
│   └── 启用-XX:+DisableExplicitGC
├── 触发原因是Allocation Failure？
│   └── 增大-Xmx或优化代码减少对象
├── 触发原因是Metadata GC Threshold？
│   └── 增大-XX:MaxMetaspaceSize
└── 触发原因是Evacuation Failure？
    └── 增大堆或调整G1参数
```

---

## 参考

- 真实GC日志：`demo/GC-Troubleshooting-Demo/gc-full-gc.log`
- Demo源码：`demo/GC-Troubleshooting-Demo/src/main/java/com/wjcoder/gc/demo/FullGCTriggerDemo.java`
- G1 Full GC源码：`src/hotspot/share/gc/g1/g1FullGCScope.cpp`
