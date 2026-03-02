# AsyncProfiler 实战案例：从问题定位到性能优化

## 一、实战目标

通过一个完整的性能分析案例，掌握 AsyncProfiler 的实战使用方法：

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      实战分析流程                                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   1. 问题发现        2. 数据采集        3. 火焰图分析                   │
│  ┌─────────┐      ┌─────────┐      ┌─────────────┐                    │
│  │应用慢了  │ ──▶ │CPU/Alloc │ ──▶ │ 热点定位     │                    │
│  │内存高了  │      │ Lock采样 │      │ 调用栈分析   │                    │
│  └─────────┘      └─────────┘      └─────────────┘                    │
│       │                │                   │                           │
│       ▼                ▼                   ▼                           │
│  ┌─────────┐      ┌─────────┐      ┌─────────────┐                    │
│  │监控告警  │      │火焰图    │      │ 根因定位     │                    │
│  │用户反馈  │      │JFR 录制  │      │ 优化方案     │                    │
│  └─────────┘      └─────────┘      └─────────────┘                    │
│                                                                         │
│   4. 优化实施        5. 效果验证        6. 文档沉淀                     │
│  ┌─────────┐      ┌─────────┐      ┌─────────────┐                    │
│  │代码修改  │ ──▶ │性能对比  │ ──▶ │ 经验总结     │                    │
│  │配置调优  │      │回归测试  │      │ 最佳实践     │                    │
│  └─────────┘      └─────────┘      └─────────────┘                    │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 二、测试程序设计

### 2.1 性能问题模拟程序

我们设计一个包含多种性能问题的 Java 程序：

```java
// /data/workspace/demo/src/com/example/PerformanceDemo.java
package com.example;

import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.locks.*;

/**
 * 性能问题演示程序，包含：
 * 1. CPU 热点：频繁的字符串拼接
 * 2. 内存分配热点：大量临时对象
 * 3. 锁竞争：多线程竞争同一把锁
 * 4. 低效算法：O(n²) 查找
 */
public class PerformanceDemo {
    
    // ============== 问题 1：CPU 热点 ==============
    // 频繁的字符串拼接，导致大量 StringBuilder 创建
    
    public static class StringConcatProblem {
        public String buildReport(List<DataItem> items) {
            String result = "";  // 反模式！
            for (DataItem item : items) {
                result += item.toString() + "\n";  // 每次循环创建新 String
            }
            return result;
        }
    }
    
    // ============== 问题 2：内存分配热点 ==============
    // 大量临时对象创建，增加 GC 压力
    
    public static class MemoryAllocationProblem {
        private static final int CHUNK_SIZE = 1024;
        
        public byte[] processData(byte[] input) {
            // 每次调用创建多个临时数组
            byte[] temp1 = new byte[input.length];
            byte[] temp2 = new byte[input.length];
            byte[] result = new byte[input.length];
            
            // 多次中间转换
            System.arraycopy(input, 0, temp1, 0, input.length);
            transform1(temp1, temp2);
            transform2(temp2, result);
            
            return result;
        }
        
        private void transform1(byte[] src, byte[] dst) {
            for (int i = 0; i < src.length; i++) {
                dst[i] = (byte)(src[i] ^ 0xFF);
            }
        }
        
        private void transform2(byte[] src, byte[] dst) {
            for (int i = 0; i < src.length; i++) {
                dst[i] = (byte)(src[i] + 1);
            }
        }
    }
    
    // ============== 问题 3：锁竞争 ==============
    // 多线程竞争同一把锁
    
    public static class LockContentionProblem {
        private final Object lock = new Object();
        private int counter = 0;
        private final Map<String, Integer> cache = new HashMap<>();
        
        public void increment() {
            synchronized (lock) {  // 粗粒度锁，所有操作都竞争
                counter++;
                try {
                    // 模拟耗时操作
                    Thread.sleep(1);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }
        }
        
        public int getFromCache(String key) {
            synchronized (lock) {  // 同一把锁，读写都阻塞
                if (!cache.containsKey(key)) {
                    cache.put(key, expensiveCompute(key));
                }
                return cache.get(key);
            }
        }
        
        private int expensiveCompute(String key) {
            return key.hashCode() % 1000;
        }
    }
    
    // ============== 问题 4：低效算法 ==============
    // O(n²) 查找算法
    
    public static class InefficientAlgorithmProblem {
        public List<DataItem> findDuplicates(List<DataItem> items) {
            List<DataItem> duplicates = new ArrayList<>();
            
            // O(n²) 嵌套循环
            for (int i = 0; i < items.size(); i++) {
                for (int j = i + 1; j < items.size(); j++) {
                    if (items.get(i).getId() == items.get(j).getId()) {
                        duplicates.add(items.get(i));
                        break;
                    }
                }
            }
            
            return duplicates;
        }
    }
    
    // ============== 数据结构 ==============
    
    public static class DataItem {
        private final int id;
        private final String name;
        private final double value;
        
        public DataItem(int id, String name, double value) {
            this.id = id;
            this.name = name;
            this.value = value;
        }
        
        public int getId() { return id; }
        public String getName() { return name; }
        public double getValue() { return value; }
        
        @Override
        public String toString() {
            return String.format("DataItem{id=%d, name='%s', value=%.2f}", id, name, value);
        }
    }
    
    // ============== 主程序 ==============
    
    public static void main(String[] args) throws Exception {
        System.out.println("Performance Demo Started");
        System.out.println("PID: " + ProcessHandle.current().pid());
        
        // 初始化测试数据
        List<DataItem> items = generateTestData(10000);
        byte[] largeData = new byte[1024 * 1024]; // 1MB
        new Random().nextBytes(largeData);
        
        // 创建问题实例
        StringConcatProblem stringProblem = new StringConcatProblem();
        MemoryAllocationProblem memoryProblem = new MemoryAllocationProblem();
        LockContentionProblem lockProblem = new LockContentionProblem();
        InefficientAlgorithmProblem algoProblem = new InefficientAlgorithmProblem();
        
        // 线程池
        ExecutorService executor = Executors.newFixedThreadPool(8);
        
        // 持续运行，模拟负载
        while (true) {
            // 问题 1：CPU 热点
            executor.submit(() -> {
                stringProblem.buildReport(items.subList(0, 1000));
            });
            
            // 问题 2：内存分配热点
            executor.submit(() -> {
                memoryProblem.processData(largeData);
            });
            
            // 问题 3：锁竞争
            for (int i = 0; i < 4; i++) {
                executor.submit(() -> {
                    for (int j = 0; j < 100; j++) {
                        lockProblem.increment();
                    }
                });
            }
            
            // 问题 4：低效算法
            executor.submit(() -> {
                algoProblem.findDuplicates(items);
            });
            
            Thread.sleep(100);
        }
    }
    
    private static List<DataItem> generateTestData(int count) {
        List<DataItem> items = new ArrayList<>();
        Random random = new Random();
        for (int i = 0; i < count; i++) {
            items.add(new DataItem(
                random.nextInt(count / 10), // 故意产生重复 ID
                "Item-" + i,
                random.nextDouble() * 1000
            ));
        }
        return items;
    }
}
```

### 2.2 编译和运行

```bash
# 编译
cd /data/workspace/demo/src
javac -d ../out com/example/PerformanceDemo.java

# 运行（后台运行）
java -cp ../out com.example.PerformanceDemo &

# 记录 PID
echo $! > /tmp/demo.pid
```

---

## 三、问题一分析：CPU 热点

### 3.1 数据采集

```bash
# 使用 AsyncProfiler 进行 CPU 采样
./profiler.sh -d 30 -f cpu_profile.html $(cat /tmp/demo.pid)

# 参数说明：
# -d 30     ：采样 30 秒
# -f cpu_profile.html：输出到 HTML 文件
# $(cat /tmp/demo.pid)：目标进程 PID
```

### 3.2 火焰图解读

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      CPU 火焰图分析                                      │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  典型火焰图结构：                                                        │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                    java.lang.Thread.run                         │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                              │                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │           java.util.concurrent.ThreadPoolExecutor.runWorker     │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                              │                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                    com.example.PerformanceDemo                   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                              │                                          │
│         ┌────────────────────┼────────────────────┐                    │
│         │                    │                    │                    │
│  ┌──────────────┐   ┌────────────────┐   ┌────────────────┐           │
│  │buildReport() │   │processData()   │   │increment()     │           │
│  │  35% ████████│   │  25% ██████    │   │  20% █████     │           │
│  └──────────────┘   └────────────────┘   └────────────────┘           │
│         │                    │                                          │
│  ┌──────────────┐   ┌────────────────┐                                 │
│  │StringBuilder │   │  byte[] copy   │                                 │
│  │  append()    │   │  System.arraycopy│                               │
│  └──────────────┘   └────────────────┘                                 │
│                                                                         │
│  颜色说明：                                                              │
│  🟢 绿色：Java compiled (JIT 编译)                                      │
│  🟡 黄色：Java interpreted (解释执行)                                    │
│  🔵 蓝色：Inlined (内联方法)                                             │
│  🔴 红色：Native/C++ (JVM 内部)                                          │
│  🟠 橙色：Kernel (内核态)                                                │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.3 热点定位

**问题分析：**

```java
// 原始代码（问题代码）
public String buildReport(List<DataItem> items) {
    String result = "";  // 每次拼接创建新 String
    for (DataItem item : items) {
        result += item.toString() + "\n";  // 编译器优化为 StringBuilder，但每次循环创建新的
    }
    return result;
}

// 编译器实际生成的代码：
public String buildReport(List<DataItem> items) {
    String result = "";
    for (DataItem item : items) {
        result = new StringBuilder()
                    .append(result)
                    .append(item.toString())
                    .append("\n")
                    .toString();  // 每次循环创建 StringBuilder + String
    }
    return result;
}
```

**性能开销分析：**

```
┌────────────────────────────────────────────────────────────────────────┐
│  循环次数 │ StringBuilder 创建 │ String 创建 │ 总内存分配 │ CPU 时间    │
├────────────────────────────────────────────────────────────────────────┤
│  1000     │ 1000              │ 1000       │ ~500KB     │ ~5ms        │
│  10000    │ 10000             │ 10000      │ ~50MB      │ ~500ms      │
│  100000   │ 100000            │ 100000     │ ~5GB       │ ~50s        │
└────────────────────────────────────────────────────────────────────────┘

时间复杂度：O(n²)，因为每次拼接都需要复制之前的所有字符
```

### 3.4 优化方案

```java
// 优化方案 1：使用 StringBuilder（推荐）
public String buildReportOptimized1(List<DataItem> items) {
    StringBuilder sb = new StringBuilder(items.size() * 50);  // 预分配容量
    for (DataItem item : items) {
        sb.append(item.toString()).append("\n");
    }
    return sb.toString();
}

// 优化方案 2：使用 String.join（Java 8+）
public String buildReportOptimized2(List<DataItem> items) {
    return items.stream()
                .map(DataItem::toString)
                .collect(Collectors.joining("\n"));
}

// 优化方案 3：使用 StringWriter（适合大文本）
public String buildReportOptimized3(List<DataItem> items) throws IOException {
    StringWriter sw = new StringWriter(items.size() * 50);
    PrintWriter pw = new PrintWriter(sw);
    for (DataItem item : items) {
        pw.println(item.toString());
    }
    return sw.toString();
}
```

### 3.5 优化效果验证

```bash
# 使用 JMH 进行基准测试
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.MILLISECONDS)
@State(Scope.Benchmark)
public class StringConcatBenchmark {
    
    private List<DataItem> items;
    
    @Setup
    public void setup() {
        items = generateTestData(10000);
    }
    
    @Benchmark
    public String original() {
        return buildReport(items);  // 原始方法
    }
    
    @Benchmark
    public String optimized() {
        return buildReportOptimized1(items);  // 优化方法
    }
}

// 结果：
// Benchmark                   Mode  Cnt   Score   Error  Units
// StringConcatBenchmark.original    avgt    5  458.234 ± 12.345  ms
// StringConcatBenchmark.optimized   avgt    5    2.156 ±  0.089  ms
// 
// 性能提升：~200 倍
```

---

## 四、问题二分析：内存分配热点

### 4.1 数据采集

```bash
# 使用 AsyncProfiler 进行内存分配采样
./profiler.sh -d 30 -e alloc -f alloc_profile.html $(cat /tmp/demo.pid)

# 参数说明：
# -e alloc：采样内存分配事件
```

### 4.2 火焰图解读

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    内存分配火焰图                                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  火焰图 X 轴：分配的内存大小（不是时间）                                  │
│  火焰图 Y 轴：调用栈深度                                                 │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                    processData()  3MB per call                   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                              │                                          │
│         ┌────────────────────┼────────────────────┐                    │
│         │                    │                    │                    │
│  ┌──────────────┐   ┌────────────────┐   ┌────────────────┐           │
│  │new byte[1MB] │   │new byte[1MB]   │   │new byte[1MB]   │           │
│  │  temp1       │   │  temp2         │   │  result        │           │
│  └──────────────┘   └────────────────┘   └────────────────┘           │
│                                                                         │
│  特殊标记：                                                              │
│  _[k] = TLAB 外分配（大对象或 TLAB 满）                                 │
│  _[i] = TLAB 内分配（正常情况）                                          │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.3 问题分析

```java
// 原始代码（问题代码）
public byte[] processData(byte[] input) {
    // 每次调用创建 3 个临时数组，总共 3 倍输入大小
    byte[] temp1 = new byte[input.length];    // 1MB
    byte[] temp2 = new byte[input.length];    // 1MB
    byte[] result = new byte[input.length];   // 1MB
    
    System.arraycopy(input, 0, temp1, 0, input.length);
    transform1(temp1, temp2);
    transform2(temp2, result);
    
    return result;
}

// 如果每秒调用 100 次，每秒分配：100 × 3MB = 300MB
// 这会导致 Young GC 频繁触发
```

**GC 影响分析：**

```
┌────────────────────────────────────────────────────────────────────────┐
│  分配速率 │ Young GC 频率 │ GC 暂停时间 │ 应用吞吐量                    │
├────────────────────────────────────────────────────────────────────────┤
│  50MB/s   │ ~1 次/秒      │ ~10ms       │ 99%                          │
│  300MB/s  │ ~6 次/秒      │ ~60ms       │ 94%                          │
│  1GB/s    │ ~20 次/秒     │ ~200ms      │ 80%                          │
└────────────────────────────────────────────────────────────────────────┘
```

### 4.4 优化方案

```java
// 优化方案 1：原地修改（零额外分配）
public void processDataInPlace(byte[] data) {
    for (int i = 0; i < data.length; i++) {
        data[i] = (byte)((data[i] ^ 0xFF) + 1);  // 合并两次转换
    }
}

// 优化方案 2：复用缓冲区（对象池）
public class DataProcessor {
    private byte[] buffer1;
    private byte[] buffer2;
    
    public DataProcessor(int bufferSize) {
        this.buffer1 = new byte[bufferSize];
        this.buffer2 = new byte[bufferSize];
    }
    
    public byte[] processData(byte[] input) {
        System.arraycopy(input, 0, buffer1, 0, input.length);
        transform1(buffer1, buffer2);
        transform2(buffer2, buffer1);
        return Arrays.copyOf(buffer1, input.length);
    }
}

// 优化方案 3：使用 ByteBuffer（直接内存，避开 GC）
public ByteBuffer processDataDirect(ByteBuffer input) {
    ByteBuffer output = ByteBuffer.allocateDirect(input.remaining());
    while (input.hasRemaining()) {
        output.put((byte)((input.get() ^ 0xFF) + 1));
    }
    output.flip();
    return output;
}
```

### 4.5 优化效果

```bash
# 优化前：每秒分配 300MB
# 优化后：每秒分配 < 10MB

# GC 日志对比
# 优化前：
[GC (Allocation Failure) [PSYoungGen: 2048000K->204800K(2304000K)] 2048000K->2048200K(8028160K), 0.0152345 secs]

# 优化后：
[GC (Allocation Failure) [PSYoungGen: 512000K->51200K(614400K)] 512000K->512100K(8028160K), 0.0034567 secs]

# GC 频率：6 次/秒 → 0.5 次/秒
# GC 暂停：15ms → 3ms
# 吞吐量提升：6% → 2%
```

---

## 五、问题三分析：锁竞争

### 5.1 数据采集

```bash
# 使用 AsyncProfiler 进行锁采样
./profiler.sh -d 30 -e lock -f lock_profile.html $(cat /tmp/demo.pid)

# 参数说明：
# -e lock：采样锁等待事件
```

### 5.2 火焰图解读

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      锁竞争火焰图                                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  火焰图 X 轴：锁等待时间                                                 │
│  火焰图 Y 轴：调用栈深度                                                 │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │              LockContentionProblem.increment()                   │   │
│  │                     等待时间：2500ms                              │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                              │                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │               Object.wait() - 线程阻塞等待锁                      │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                              │                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │               synchronized(lock) 竞争激烈                         │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  颜色说明：                                                              │
│  🟠 橙色：锁对象类（java.lang.Object）                                   │
│  🔵 蓝色：等待的线程                                                     │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 5.3 问题分析

```java
// 原始代码（问题代码）
public class LockContentionProblem {
    private final Object lock = new Object();  // 单一锁
    private int counter = 0;
    private final Map<String, Integer> cache = new HashMap<>();
    
    public void increment() {
        synchronized (lock) {  // 所有操作竞争同一把锁
            counter++;
            try {
                Thread.sleep(1);  // 模拟耗时操作，加剧锁竞争
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
    }
    
    public int getFromCache(String key) {
        synchronized (lock) {  // increment 和 getFromCache 相互阻塞
            // ...
        }
    }
}
```

**锁竞争分析：**

```
┌────────────────────────────────────────────────────────────────────────┐
│  线程数 │ 锁等待时间 │ 吞吐量（ops/s） │ CPU 利用率                     │
├────────────────────────────────────────────────────────────────────────┤
│  1      │ 0ms        │ 1000           │ 100%（单线程）                 │
│  4      │ ~75%       │ 250            │ 25%（大部分时间在等待）         │
│  8      │ ~87%       │ 125            │ 12.5%（竞争更激烈）             │
│  16     │ ~94%       │ 62             │ 6.25%（几乎全部等待）           │
└────────────────────────────────────────────────────────────────────────┘

Amdahl 定律：锁竞争严重的代码，增加线程数反而降低吞吐量
```

### 5.4 优化方案

```java
// 优化方案 1：减少锁粒度
public class LockContentionOptimized1 {
    private final Object counterLock = new Object();  // 细粒度锁
    private final Object cacheLock = new Object();
    private int counter = 0;
    private final Map<String, Integer> cache = new HashMap<>();
    
    public void increment() {
        synchronized (counterLock) {  // 只锁计数器
            counter++;
            try {
                Thread.sleep(1);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
    }
    
    public int getFromCache(String key) {
        synchronized (cacheLock) {  // 只锁缓存
            // ...
        }
    }
}

// 优化方案 2：使用 AtomicInteger（无锁）
public class LockContentionOptimized2 {
    private final AtomicInteger counter = new AtomicInteger(0);
    private final ConcurrentHashMap<String, Integer> cache = new ConcurrentHashMap<>();
    
    public void increment() {
        counter.incrementAndGet();  // CAS 操作，无锁
        try {
            Thread.sleep(1);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
    
    public int getFromCache(String key) {
        return cache.computeIfAbsent(key, k -> expensiveCompute(k));
    }
}

// 优化方案 3：使用 LongAdder（高并发计数）
public class LockContentionOptimized3 {
    private final LongAdder counter = new LongAdder();
    
    public void increment() {
        counter.increment();  // 分散热点，极度高并发下优于 AtomicInteger
    }
    
    public long getCounter() {
        return counter.sum();
    }
}

// 优化方案 4：读写锁
public class LockContentionOptimized4 {
    private final ReentrantReadWriteLock lock = new ReentrantReadWriteLock();
    private final Map<String, Integer> cache = new HashMap<>();
    
    public int getFromCache(String key) {
        lock.readLock().lock();  // 读操作可以并发
        try {
            Integer value = cache.get(key);
            if (value != null) return value;
        } finally {
            lock.readLock().unlock();
        }
        
        lock.writeLock().lock();  // 只有写入需要独占
        try {
            return cache.computeIfAbsent(key, k -> expensiveCompute(k));
        } finally {
            lock.writeLock().unlock();
        }
    }
}
```

### 5.5 优化效果

```bash
# JMH 基准测试结果

Benchmark                           Mode  Cnt     Score    Error  Units
LockBenchmark.original              avgt    5  4000.123 ± 50.234  ms
LockBenchmark.fineGrainedLock       avgt    5  1000.456 ± 20.123  ms  # 4x 提升
LockBenchmark.concurrentHashMap     avgt    5   100.789 ±  5.456  ms  # 40x 提升
LockBenchmark.longAdder             avgt    5    50.123 ±  2.345  ms  # 80x 提升
```

---

## 六、问题四分析：低效算法

### 6.1 数据采集

```bash
# CPU 采样可以看到算法热点
./profiler.sh -d 30 -f algo_profile.html $(cat /tmp/demo.pid)
```

### 6.2 问题分析

```java
// 原始代码（O(n²) 算法）
public List<DataItem> findDuplicates(List<DataItem> items) {
    List<DataItem> duplicates = new ArrayList<>();
    
    // 嵌套循环：O(n²)
    for (int i = 0; i < items.size(); i++) {
        for (int j = i + 1; j < items.size(); j++) {
            if (items.get(i).getId() == items.get(j).getId()) {
                duplicates.add(items.get(i));
                break;
            }
        }
    }
    
    return duplicates;
}
```

**时间复杂度分析：**

```
┌────────────────────────────────────────────────────────────────────────┐
│  数据规模 │ 比较次数    │ 执行时间（估计）│ 内存使用                      │
├────────────────────────────────────────────────────────────────────────┤
│  1000     │ 500K       │ ~5ms            │ 低                           │
│  10000    │ 50M        │ ~500ms          │ 低                           │
│  100000   │ 5B         │ ~50s            │ 低                           │
│  1000000  │ 500B       │ ~5000s（83分钟）│ 低                           │
└────────────────────────────────────────────────────────────────────────┘

算法复杂度：O(n²)，数据规模翻倍，时间增加 4 倍
```

### 6.3 优化方案

```java
// 优化方案 1：使用 HashSet（O(n)）
public List<DataItem> findDuplicatesOptimized1(List<DataItem> items) {
    Set<Integer> seen = new HashSet<>();
    List<DataItem> duplicates = new ArrayList<>();
    
    for (DataItem item : items) {
        if (!seen.add(item.getId())) {  // O(1) 查找
            duplicates.add(item);
        }
    }
    
    return duplicates;
}

// 优化方案 2：使用 Stream（Java 8+）
public List<DataItem> findDuplicatesOptimized2(List<DataItem> items) {
    return items.stream()
                .collect(Collectors.groupingBy(DataItem::getId))
                .values().stream()
                .filter(list -> list.size() > 1)
                .map(list -> list.get(0))
                .collect(Collectors.toList());
}

// 优化方案 3：并行处理（大数据量）
public List<DataItem> findDuplicatesParallel(List<DataItem> items) {
    return items.parallelStream()
                .collect(Collectors.groupingByConcurrent(DataItem::getId))
                .values().parallelStream()
                .filter(list -> list.size() > 1)
                .map(list -> list.get(0))
                .collect(Collectors.toList());
}
```

### 6.4 优化效果

```bash
# JMH 基准测试

Benchmark                       (size)  Mode  Cnt     Score    Error  Units
AlgoBenchmark.original           10000  avgt    5   500.234 ± 10.234  ms
AlgoBenchmark.optimizedHashSet   10000  avgt    5     2.156 ±  0.089  ms  # 230x
AlgoBenchmark.original          100000  avgt    5 50000.123 ±1000.234  ms
AlgoBenchmark.optimizedHashSet  100000  avgt    5    25.789 ±  1.456  ms  # 1900x
```

---

## 七、综合优化效果

### 7.1 优化前后对比

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     综合性能对比                                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  指标                优化前         优化后         提升                  │
│  ─────────────────────────────────────────────────────────────          │
│  CPU 使用率          95%           45%           -50%                   │
│  内存分配速率        300MB/s       10MB/s        -97%                   │
│  Young GC 频率       6次/秒        0.5次/秒      -92%                   │
│  GC 暂停时间         15ms          3ms           -80%                   │
│  锁等待时间          2500ms        100ms         -96%                   │
│  吞吐量              1000 ops/s    50000 ops/s   +50x                   │
│  响应时间（P99）     500ms         5ms           -99%                   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 7.2 优化总结

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      性能优化最佳实践                                    │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  1. CPU 热点优化：                                                      │
│     ✅ 使用 StringBuilder 替代字符串拼接                               │
│     ✅ 预分配容量避免扩容                                               │
│     ✅ 批量处理减少循环次数                                             │
│                                                                         │
│  2. 内存优化：                                                          │
│     ✅ 减少临时对象创建                                                 │
│     ✅ 复用缓冲区/对象池                                                │
│     ✅ 使用直接内存（DirectBuffer）避开 GC                              │
│                                                                         │
│  3. 锁优化：                                                            │
│     ✅ 减小锁粒度（细粒度锁）                                           │
│     ✅ 使用无锁数据结构（Atomic/Concurrent）                            │
│     ✅ 读写分离（ReadWriteLock）                                        │
│     ✅ 避免在锁内执行耗时操作                                           │
│                                                                         │
│  4. 算法优化：                                                          │
│     ✅ 选择合适的数据结构（HashSet O(1) vs List O(n)）                  │
│     ✅ 降低时间复杂度（O(n²) → O(n log n) → O(n)）                      │
│     ✅ 大数据量使用并行处理                                             │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 八、AsyncProfiler 使用技巧

### 8.1 常用命令

```bash
# 1. CPU 采样（默认）
./profiler.sh -d 30 -f cpu.html <pid>

# 2. 内存分配采样
./profiler.sh -d 30 -e alloc -f alloc.html <pid>

# 3. 锁竞争采样
./profiler.sh -d 30 -e lock -f lock.html <pid>

# 4. Wall Clock 采样（包含阻塞时间）
./profiler.sh -d 30 -e wall -f wall.html <pid>

# 5. 同时采样多种事件
./profiler.sh -d 30 -e cpu,alloc,lock -f multi.html <pid>

# 6. 输出 JFR 格式
./profiler.sh -d 60 -f output.jfr <pid>

# 7. 指定采样间隔
./profiler.sh -d 30 -i 1ms -f cpu.html <pid>  # 每 1ms 采样一次

# 8. 只采样特定线程
./profiler.sh -d 30 -t "worker-*" -f cpu.html <pid>

# 9. 包含/排除特定包
./profiler.sh -d 30 -I "com.example.*" -f cpu.html <pid>
./profiler.sh -d 30 -X "java.*" -f cpu.html <pid>
```

### 8.2 火焰图交互技巧

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     火焰图交互操作                                       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  鼠标操作：                                                              │
│  • 单击：放大选中帧                                                     │
│  • 双击：复制帧名到剪贴板                                               │
│  • Alt+单击：移除选中帧及其子帧                                         │
│  • 鼠标悬停：显示详细信息                                               │
│                                                                         │
│  键盘快捷键：                                                            │
│  • I：翻转火焰图（icicle 图）                                           │
│  • 0：重置缩放                                                          │
│  • Ctrl+F：搜索                                                         │
│  • N：下一个匹配项                                                      │
│  • Shift+N：上一个匹配项                                                │
│  • Esc：取消搜索                                                        │
│                                                                         │
│  颜色解读：                                                              │
│  🟢 绿色：Java compiled（JIT 编译的代码）                               │
│  🟡 黄色：Java interpreted（解释执行的代码）                             │
│  🔵 蓝色：Inlined（内联方法）                                            │
│  🟠 橙色：Native（Native 方法）                                          │
│  🔴 红色：C++/VM（JVM 内部代码）                                         │
│  🟤 棕色：Kernel（内核态代码）                                           │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 8.3 常见问题排查

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     问题排查决策树                                       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  问题：CPU 使用率高                                                     │
│  ├── 采样：CPU profiling                                                │
│  ├── 分析：查看顶部热点帧                                               │
│  └── 优化：算法优化 / 减少计算量                                        │
│                                                                         │
│  问题：频繁 GC / 内存占用高                                             │
│  ├── 采样：Alloc profiling                                              │
│  ├── 分析：找出分配最多的对象类型                                       │
│  └── 优化：减少临时对象 / 对象池                                        │
│                                                                         │
│  问题：响应时间长 / 吞吐量低                                            │
│  ├── 采样：Lock profiling                                               │
│  ├── 分析：找出竞争激烈的锁                                             │
│  └── 优化：细粒度锁 / 无锁结构                                          │
│                                                                         │
│  问题：线程阻塞 / 死锁                                                  │
│  ├── 采样：Wall Clock profiling                                         │
│  ├── 分析：查看阻塞状态线程的调用栈                                     │
│  └── 优化：减少阻塞操作 / 异步化                                        │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 九、总结

### 实战要点

1. **先测量，后优化**：不要凭直觉优化，用数据说话
2. **关注主要矛盾**：优化占 80% 时间的那 20% 代码
3. **验证优化效果**：每次优化后都要重新测量
4. **权衡取舍**：性能优化可能有副作用（如代码复杂度增加）

### 工具推荐

| 工具 | 用途 | 特点 |
|------|------|------|
| AsyncProfiler | CPU/内存/锁采样 | 低开销，火焰图 |
| JFR | 全面事件记录 | JDK 内置，JMC 分析 |
| JMH | 基准测试 | 微基准测试标准工具 |
| Arthas | 在线诊断 | 无需重启，实时分析 |

---

**通过本实战案例，你已经掌握了使用 AsyncProfiler 进行性能分析的完整流程！**
