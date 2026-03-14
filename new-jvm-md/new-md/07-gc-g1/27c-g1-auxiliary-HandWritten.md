# 27c · G1 辅助机制 — Humongous 对象、字符串去重、类卸载

> 接上篇 [27b-g1-full-gc-HandWritten.md](./27b-g1-full-gc-HandWritten.md)  
> 基于 OpenJDK 11 源码，`-Xms8g -Xmx8g -XX:+UseG1GC -Xint`

---

## 写在前面

前几篇讲了 G1 的核心机制：Young GC、RSet、并发标记、Mixed GC、Full GC。

这篇讲几个"辅助机制"——它们不是 G1 的核心，但在实际使用中经常遇到，不了解会踩坑。

---

## 第一部分：Humongous 对象 — 大对象的特殊处理

### 什么是 Humongous 对象？

对象大小 > Region 大小的 50%，就是 Humongous 对象。

```
8GB 堆，Region 大小 = 4MB
Humongous 阈值 = 4MB × 50% = 2MB

对象大小 < 2MB → 普通对象，在 Eden 分配
对象大小 ≥ 2MB → Humongous 对象，特殊处理
```

---

### Humongous 对象的分配

**普通对象的分配路径**：

```
new Object() → TLAB → Eden Region → Young GC → Survivor → Old
```

**Humongous 对象的分配路径**：

```
new byte[3MB] → 直接在 Old 区分配连续的 Humongous Region
```

**为什么直接分配到 Old 区？**

Humongous 对象太大，无法放入 TLAB（TLAB 通常只有几十 KB）。也无法放入 Eden Region（Eden Region 只有 4MB，对象就有 3MB，放进去后 Eden 很快就满了）。

所以 G1 直接在 Old 区找连续的空闲 Region 来存放 Humongous 对象。

---

### Humongous 对象的内存布局

一个 3MB 的 Humongous 对象（Region 大小 4MB）：

```
Region 100（HumongousStart）：
  [对象头 + 前 4MB 数据]

Region 101（HumongousContinues）：
  [剩余数据（约 3MB - 4MB = 不够一个 Region）]
  [内部碎片（约 1MB 浪费）]
```

**内部碎片**：Humongous 对象的最后一个 Region 通常不会被完全填满，剩余空间浪费了。

---

### Humongous 对象的回收

**我以为**：Humongous 对象在 Young GC 时回收。

**实际上**：Humongous 对象有两种回收时机：

**时机 1：Young GC 时（OpenJDK 8u60+ 引入）**

如果 Humongous 对象没有被任何 Old Region 引用（只被年轻代或 GC Roots 引用），Young GC 时可以直接回收。

**时机 2：Cleanup 阶段（并发标记后）**

并发标记完成后，Cleanup 阶段会统计每个 Region 的存活率。如果 Humongous Region 的存活率为 0（对象已经死了），直接回收。

**什么情况下 Humongous 对象无法被 Young GC 回收？**

如果有 Old Region 引用了这个 Humongous 对象，Young GC 时无法确定它是否存活（需要扫描整个 Old 区），所以不回收，等待并发标记。

---

### Humongous 对象的常见问题

**问题 1：频繁分配 Humongous 对象导致 Old 区快速填满**

```
每次分配 3MB 的 Humongous 对象：
  → 占用 1 个 HumongousStart Region + 1 个 HumongousContinues Region
  → 浪费约 1MB（内部碎片）
  → Old 区快速填满 → 触发并发标记 → 触发 Mixed GC
```

**问题 2：Humongous 分配失败触发 Full GC**

如果 Old 区没有足够的连续空闲 Region，Humongous 对象分配失败，触发 Full GC 来整理内存。

**GC 日志里的体现**：

```
[1.234s] GC(5) Pause Young (G1 Humongous Allocation) 456M->234M(8192M) 45.6ms
         ↑ 因为 Humongous 分配失败触发了 Young GC
```

---

### 如何避免 Humongous 对象问题

**方案 1：增大 Region 大小**

```bash
-XX:G1HeapRegionSize=8m  # 把 Region 大小从 4MB 增大到 8MB
                          # Humongous 阈值从 2MB 增大到 4MB
                          # 原来的 3MB 对象不再是 Humongous 对象
```

**方案 2：减少大对象分配**

- 分页加载大数据（不要一次性加载整个大数组）
- 使用流式处理代替全量加载
- 对象池化复用大对象

**方案 3：使用堆外内存**

```java
// 大缓存使用堆外内存，不占用 Java 堆
ByteBuffer directBuffer = ByteBuffer.allocateDirect(100 * 1024 * 1024);
```

---

## 第二部分：字符串去重（String Deduplication）

### 什么是字符串去重？

Java 中，字符串是不可变的，但同样内容的字符串可能有多个对象：

```java
String a = new String("hello");
String b = new String("hello");
// a 和 b 是两个不同的对象，但内容相同
// 它们各自有一个 char[] 数组，内容相同但占用两份内存
```

**字符串去重**：G1 在 GC 时，检测到内容相同的字符串，让它们共享同一个 `char[]` 数组，释放重复的内存。

---

### 如何开启？

```bash
-XX:+UseStringDeduplication  # 开启字符串去重（默认关闭）
-XX:StringDeduplicationAgeThreshold=3  # 字符串存活 3 次 GC 后才考虑去重（默认 3）
```

**为什么默认关闭？**

字符串去重需要额外的 CPU 开销（计算哈希、比较内容）。只有在字符串重复率很高的应用中才值得开启。

---

### 什么时候有效？

字符串去重对以下场景有效：
- 大量重复的字符串（比如从数据库读取的重复字段值）
- 字符串缓存（比如 HTTP 请求头的字段名）

对以下场景无效：
- 字符串常量池（`String.intern()` 已经共享了）
- 短命字符串（还没来得及去重就死了）

---

## 第三部分：类卸载（Class Unloading）

### G1 什么时候卸载类？

G1 在并发标记的 Cleanup 阶段可以卸载不再使用的类（Class Unloading）。

**触发条件**：
- 类加载器（ClassLoader）不再被引用
- 该类加载器加载的所有类都不再被引用

**为什么需要类卸载？**

动态生成类的框架（比如 Spring AOP、Groovy、JRuby）会在运行时生成大量类。如果这些类不再使用但无法卸载，Metaspace 会持续增长，最终触发 Full GC。

---

### 如何控制类卸载？

```bash
-XX:+ClassUnloadingWithConcurrentMark  # 并发标记期间卸载类（默认开启）
-XX:-ClassUnloading                    # 完全禁止类卸载（调试用）
```

---

## 第四部分：G1 的参数速查

### 常用参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-XX:G1HeapRegionSize` | 自动计算 | Region 大小（1MB-32MB，必须是 2 的幂） |
| `-XX:MaxGCPauseMillis` | 200ms | 目标最大停顿时间（不是保证） |
| `-XX:G1NewSizePercent` | 5% | 年轻代最小占比 |
| `-XX:G1MaxNewSizePercent` | 60% | 年轻代最大占比 |
| `-XX:InitiatingHeapOccupancyPercent` | 45% | 触发并发标记的堆占用阈值（IHOP） |
| `-XX:G1HeapWastePercent` | 5% | 停止 Mixed GC 的可回收空间阈值 |
| `-XX:G1MixedGCLiveThresholdPercent` | 85% | Old Region 存活率阈值（超过不回收） |
| `-XX:G1MixedGCCountTarget` | 8 | 目标 Mixed GC 次数 |
| `-XX:ConcGCThreads` | 自动计算 | 并发标记线程数 |
| `-XX:ParallelGCThreads` | 自动计算 | 并行 GC 线程数 |
| `-XX:+UseStringDeduplication` | false | 字符串去重 |
| `-XX:+DisableExplicitGC` | false | 禁止显式 GC |

---

### 参数调优思路

**停顿时间太长？**

```
1. 检查 Young GC 停顿：
   → 年轻代太大？降低 G1MaxNewSizePercent
   → RSet 扫描太慢？检查跨代引用是否过多

2. 检查 Mixed GC 停顿：
   → CSet 太大？降低 G1OldCSetRegionThresholdPercent
   → 存活对象太多？检查是否有内存泄漏

3. 检查 Full GC：
   → 疏散失败？增大堆或降低 IHOP
   → Humongous 分配失败？增大 G1HeapRegionSize
```

**Full GC 太频繁？**

```
1. 检查触发原因（GC 日志）
2. 疏散失败 → 增大堆
3. 并发标记失败 → 降低 IHOP（提前触发并发标记）
4. Humongous 分配失败 → 增大 G1HeapRegionSize
5. System.gc() → 启用 DisableExplicitGC
```

---

## 尾声：G1 模块总结

到这里，G1 的核心模块都讲完了：

| 文章 | 内容 |
|------|------|
| [23-g1-overview](./23-g1-overview-HandWritten.md) | G1 整体架构、Region 设计、辅助数据结构 |
| [24-g1-young-gc](./24-g1-young-gc-HandWritten.md) | Young GC 完整流程、并行疏散 |
| [25-g1-rset](./25-g1-rset-HandWritten.md) | RSet 三级存储、写屏障、并发精化 |
| [26-g1-concurrent-mark](./26-g1-concurrent-mark-HandWritten.md) | 三色标记、SATB、并发标记四个阶段 |
| [27-g1-mixed-gc](./27-g1-mixed-gc-HandWritten.md) | Mixed GC、G1Policy 预测模型 |
| [27b-g1-full-gc](./27b-g1-full-gc-HandWritten.md) | Full GC 触发条件、四个阶段、JDK 10 并行化 |
| [27c-g1-auxiliary](./27c-g1-auxiliary-HandWritten.md) | Humongous 对象、字符串去重、类卸载 |

---

*写于 2026-03-08*  
*参考文档：`../G1GC/Troubleshooting-Series/04-Humongous-Object-Case-Study.md`*
