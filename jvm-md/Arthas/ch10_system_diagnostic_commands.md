
# Ch 10 系统诊断命令 — dashboard / thread / jvm / memory / vmoption / sysprop / sysenv / perfcounter / heapdump

> 源文件:
> - `monitor200/DashboardCommand.java` (272行) — 实时面板
> - `monitor200/ThreadCommand.java` (243行) — 线程诊断
> - `monitor200/ThreadSampler.java` (197行) — CPU 采样引擎
> - `monitor200/JvmCommand.java` (201行) — JVM 信息全览
> - `monitor200/MemoryCommand.java` (112行) — 内存信息
> - `monitor200/PerfCounterCommand.java` (115行) — 性能计数器
> - `monitor200/HeapDumpCommand.java` (83行) — 堆转储
> - `basic1000/VMOptionCommand.java` (110行) — VM 诊断选项
> - `basic1000/SystemPropertyCommand.java` (77行) — 系统属性
> - `basic1000/SystemEnvCommand.java` (63行) — 环境变量
> - `util/ThreadUtil.java` (499行) — 线程工具类

---

## 0. 本章概览 — 数据来源全景

### 0.1 核心问题：这些数据从哪来？

Arthas 的系统诊断命令**不需要字节码增强**，它们全部依赖 JDK 提供的标准管理 API：

```
┌────────────────────────── java.lang.management ──────────────────────────┐
│                                                                          │
│  ManagementFactory (工厂入口)                                            │
│  ├── ThreadMXBean         ← dashboard、thread 命令                       │
│  ├── MemoryMXBean         ← dashboard、jvm、memory 命令                  │
│  ├── MemoryPoolMXBean[]   ← memory 命令（各区域详情）                     │
│  ├── GarbageCollectorMXBean[] ← dashboard、jvm 命令                      │
│  ├── RuntimeMXBean        ← dashboard、jvm 命令                          │
│  ├── ClassLoadingMXBean   ← jvm 命令                                     │
│  ├── CompilationMXBean    ← jvm 命令                                     │
│  ├── OperatingSystemMXBean ← dashboard、jvm 命令                         │
│  └── BufferPoolMXBean[]   ← memory 命令（direct/mapped 缓冲区）          │
│                                                                          │
├── com.sun.management.HotSpotDiagnosticMXBean                             │
│  ├── getDiagnosticOptions()  ← vmoption 命令（查看/修改 VM 选项）         │
│  └── dumpHeap()              ← heapdump 命令（堆转储）                    │
│                                                                          │
├── sun.management.HotspotThreadMBean                                      │
│  └── getInternalThreadCpuTimes() ← dashboard、thread（JVM 内部线程）      │
│                                                                          │
├── sun.misc.Perf / jdk.internal.perf.Perf                                 │
│  └── attach() → PerfInstrumentation → perfcounter 命令                    │
│                                                                          │
├── java.lang.System                                                        │
│  ├── getProperties()    ← sysprop 命令                                    │
│  ├── setProperty()      ← sysprop 命令（修改）                            │
│  └── getenv()           ← sysenv 命令                                     │
│                                                                          │
└── java.lang.Thread / ThreadGroup                                          │
   └── enumerate()        ← thread 命令（线程列表）                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### 0.2 命令分类

| 分类 | 命令 | 读/写 | 数据源 | 是否持续输出 |
|------|------|-------|--------|-------------|
| **综合面板** | dashboard | 只读 | 多个 MXBean + Tomcat 内部 API | ✅ 定时刷新 |
| **线程诊断** | thread | 只读 | ThreadMXBean + ThreadGroup | ❌ 单次 |
| **JVM 信息** | jvm | 只读 | 多个 MXBean | ❌ 单次 |
| **内存信息** | memory | 只读 | MemoryPoolMXBean + BufferPoolMXBean | ❌ 单次 |
| **VM 选项** | vmoption | 读/写 | HotSpotDiagnosticMXBean | ❌ 单次 |
| **系统属性** | sysprop | 读/写 | System.getProperties() | ❌ 单次 |
| **环境变量** | sysenv | 只读 | System.getenv() | ❌ 单次 |
| **性能计数器** | perfcounter | 只读 | Perf + PerfInstrumentation | ❌ 单次 |
| **堆转储** | heapdump | **写！** | HotSpotDiagnosticMXBean.dumpHeap() | ❌ 单次 |

---

## 1. dashboard 命令 — 实时综合面板

### 1.1 为什么需要 dashboard？

在排查线上问题时，你首先需要一个"全局视图"：
- CPU 被谁占满了？（线程维度）
- 内存还够吗？哪个区域快满了？（内存维度）
- GC 频不频繁？每次多久？（GC 维度）
- Tomcat 线程池是不是打满了？（应用维度）

dashboard 就是这个"一屏看天下"的命令。

### 1.2 核心架构 — Timer 驱动的定时采样

```
用户输入: dashboard -i 5000 -n 10

DashboardCommand.process()
│
├── 创建 Timer（daemon 线程）
│   → Timer("Timer-for-arthas-dashboard-{sessionId}", true)
│
├── 注册事件处理器
│   ├── interruptHandler → Ctrl-C 时取消 Timer
│   ├── suspendHandler → 暂停时取消 Timer
│   ├── resumeHandler → 恢复时重建 Timer
│   ├── endHandler → 结束时取消 Timer
│   └── stdinHandler → 'q' 键退出
│
└── timer.scheduleAtFixedRate(DashboardTimerTask, 0, 5000ms)
    │
    └── 每 5 秒执行一次 DashboardTimerTask.run()
        │
        ├── ① 线程采样
        │   ThreadUtil.getThreads() → ThreadSampler.sample(threads)
        │   → 计算每个线程的 CPU 使用率
        │
        ├── ② 内存信息
        │   MemoryCommand.memoryInfo()
        │   → 堆/非堆/BufferPool 各区域用量
        │
        ├── ③ GC 信息
        │   ManagementFactory.getGarbageCollectorMXBeans()
        │   → 各 GC 的次数和累计时间
        │
        ├── ④ 运行时信息
        │   osName, javaVersion, systemLoadAverage, processors, uptime
        │
        ├── ⑤ Tomcat 信息（可选）
        │   NetUtils.request("http://localhost:8006/connector/stats")
        │   → QPS、RT、ErrorRate、线程池使用情况
        │
        └── process.appendResult(dashboardModel)
            → 渲染并输出到终端
```

### 1.3 DashboardTimerTask — 每次刷新做了什么

```java
private class DashboardTimerTask extends TimerTask {
    private ThreadSampler threadSampler;  // 复用，保持上一次的 CPU 时间快照

    @Override
    public void run() {
        // ① 执行次数控制
        if (count.get() >= getNumOfExecutions()) {
            timer.cancel();
            process.end(0, "Process ends after N time(s).");
            return;
        }

        DashboardModel model = new DashboardModel();

        // ② 线程采样（最耗时的部分）
        List<ThreadVO> threads = ThreadUtil.getThreads();
        model.setThreads(threadSampler.sample(threads));
        //                ↑ 第一次调用时只记录快照，第二次开始才有 CPU 百分比

        // ③ 内存（调用 MemoryCommand 的静态方法复用）
        model.setMemoryInfo(MemoryCommand.memoryInfo());

        // ④ GC
        addGcInfo(model);

        // ⑤ 运行时
        addRuntimeInfo(model);

        // ⑥ Tomcat（try-catch 保护，失败不影响整体）
        try { addTomcatInfo(model); } catch (Throwable e) { /* ignore */ }

        process.appendResult(model);
        count.getAndIncrement();
    }
}
```

**关键设计**：
1. **ThreadSampler 是成员变量而非局部变量** — 每次采样需要和上次比较，所以必须保持状态
2. **Tomcat 信息用 try-catch 包裹** — 不是所有应用都是 Tomcat，失败不应中断 dashboard
3. **Timer 使用 daemon 线程** — 不会阻止 JVM 退出

### 1.4 Tomcat 信息采集 — 通过 HTTP 内部 API

```
Tomcat 内置了一个管理端口（默认 8006），提供 JSON 格式的运行时信息：

http://localhost:8006/connector/stats    → 连接器统计（请求数、字节数、处理时间）
http://localhost:8006/connector/threadpool → 线程池信息（busy/total）
```

Arthas 用 `SumRateCounter` 计算 QPS 等速率指标：

```java
// SumRateCounter 的巧妙设计：
// 传入的是累积总量（如总请求数），自动计算速率
//
// 数据序列：267, 457, 635, 894, 1398
// 差值序列：    190, 178, 259, 504
// 平均速率：(190 + 178 + 259 + 504) / 4 = 282 req/s

public void update(long value) {
    if (previous == null) {
        previous = value;   // 第一次只记录
        return;
    }
    rateCounter.update(value - previous);  // 存储差值
    previous = value;
}
```

---

## 2. thread 命令 — 线程诊断

### 2.1 四种工作模式

```java
@Override
public void process(CommandProcess process) {
    if (id > 0) {
        processThread(process);           // 模式 1: 查看指定线程栈
    } else if (topNBusy != null) {
        processTopBusyThreads(process);   // 模式 2: CPU 最忙的 N 个线程
    } else if (findMostBlockingThread) {
        processBlockingThread(process);   // 模式 3: 找阻塞最多线程的锁
    } else {
        processAllThreads(process);       // 模式 4: 列出所有线程
    }
}
```

### 2.2 模式 1: 查看指定线程栈 — `thread <id>`

```java
private ExitStatus processThread(CommandProcess process) {
    ThreadInfo[] infos = threadMXBean.getThreadInfo(
        new long[]{id},      // 指定线程 ID
        lockedMonitors,       // 是否包含 Monitor 锁信息
        lockedSynchronizers   // 是否包含 Synchronizer 锁信息
    );
    // → JDK 底层调用 JVMTI GetThreadInfo
    process.appendResult(new ThreadModel(infos[0]));
}
```

### 2.3 模式 2: CPU 最忙线程 — `thread -n 5`

这是排查 CPU 飙高的核心能力：

```
thread -n 5

Step 1: 第一次采样
──────────────────
ThreadSampler.sample(threads)
  → 对每个线程调用 threadMXBean.getThreadCpuTime(id)
  → 记录: {thread1: 50ms, thread2: 30ms, thread3: 80ms, ...}
  → 记录当前时间 T1 = System.nanoTime()

Step 2: 等待采样间隔
──────────────────
Thread.sleep(sampleInterval)   // 默认 200ms

Step 3: 第二次采样
──────────────────
ThreadSampler.sample(threads)
  → 对每个线程调用 threadMXBean.getThreadCpuTime(id)
  → 记录: {thread1: 180ms, thread2: 31ms, thread3: 260ms, ...}
  → 记录当前时间 T2 = System.nanoTime()

Step 4: 计算 CPU 使用率
──────────────────
for each thread:
    delta = cpuTime2 - cpuTime1          // 这段时间内消耗的 CPU 时间
    interval = T2 - T1                    // 实际经过的时间
    cpuUsage = delta / interval * 100%    // CPU 使用率

    // 精度处理：保留两位小数
    cpu = Math.rint(delta * 10000.0 / interval) / 100.0

Step 5: 按 CPU 使用率排序，取 Top N
──────────────────
Collections.sort(threads, by delta descending)
topNThreads = threads.subList(0, 5)

Step 6: 获取线程栈信息
──────────────────
ThreadInfo[] infos = threadMXBean.getThreadInfo(topNTids, lockedMonitors, lockedSynchronizers)
→ 输出每个线程的 CPU% + 完整调用栈
```

**为什么需要两次采样？**

```
ThreadMXBean.getThreadCpuTime(id) 返回的是线程从创建以来的累积 CPU 时间。

如果只看一次：
  thread1 = 50000ms   ← 可能已经运行了很久，但此刻并不繁忙
  thread2 = 100ms     ← 刚创建，但正在疯狂计算

两次采样（间隔 200ms）：
  thread1: 50000ms → 50001ms   delta = 1ms    → CPU 0.5%
  thread2: 100ms → 280ms       delta = 180ms  → CPU 90%
  → 发现 thread2 才是当前的 CPU 热点！
```

### 2.4 模式 3: 找最大阻塞锁 — `thread -b`

```java
public static BlockingLockInfo findMostBlockingLock() {
    // ① dump 所有线程信息（含锁信息）
    ThreadInfo[] infos = threadMXBean.dumpAllThreads(
        threadMXBean.isObjectMonitorUsageSupported(),
        threadMXBean.isSynchronizerUsageSupported()
    );

    // ② 统计每个锁阻塞了多少线程
    Map<Integer, Integer> blockCountPerLock = new HashMap<>();     // 锁hashCode → 阻塞数
    Map<Integer, ThreadInfo> ownerThreadPerLock = new HashMap<>(); // 锁hashCode → 持有者

    for (ThreadInfo info : infos) {
        LockInfo lockInfo = info.getLockInfo();
        if (lockInfo != null) {
            // 这个线程正在等待 lockInfo → 该锁的阻塞计数 +1
            blockCountPerLock.merge(lockInfo.getIdentityHashCode(), 1, Integer::sum);
        }

        // 记录这个线程持有的所有锁
        for (MonitorInfo mi : info.getLockedMonitors()) {
            ownerThreadPerLock.putIfAbsent(mi.getIdentityHashCode(), info);
        }
        for (LockInfo li : info.getLockedSynchronizers()) {
            ownerThreadPerLock.putIfAbsent(li.getIdentityHashCode(), info);
        }
    }

    // ③ 找阻塞数最多的锁
    int maxBlockingCount = 0;
    int mostBlockingLock = 0;
    for (entry : blockCountPerLock) {
        if (entry.getValue() > maxBlockingCount && ownerThreadPerLock.containsKey(entry.getKey())) {
            maxBlockingCount = entry.getValue();
            mostBlockingLock = entry.getKey();
        }
    }

    // ④ 返回结果：持有该锁的线程 + 阻塞数
    return new BlockingLockInfo(ownerThread, lockHashCode, blockCount);
}
```

**算法复杂度**：
- 时间复杂度：O(N) — 只需遍历一次所有线程
- 空间复杂度：O(L) — L 是锁的数量

**使用场景**：大量线程 BLOCKED 时快速定位"罪魁祸首"——持有锁最久、阻塞最多线程的那个线程。

### 2.5 ThreadSampler — CPU 采样核心引擎

```
ThreadSampler 的状态管理
━━━━━━━━━━━━━━━━━━━━━━━━

实例变量：
├── lastCpuTimes: Map<ThreadVO, Long>    ← 上一次采样的 CPU 时间快照
├── lastSampleTimeNanos: long            ← 上一次采样的时钟时间
└── includeInternalThreads: boolean      ← 是否包含 JVM 内部线程

首次调用 sample():
  → lastCpuTimes 为空 → 只记录快照，不计算
  → 按累积 CPU 时间排序返回

后续调用 sample():
  → 与 lastCpuTimes 对比 → 计算 delta 和 CPU%
  → 按 delta 排序返回
```

**JVM 内部线程的特殊处理**：

```java
// 普通 Java 线程：通过 threadMXBean.getThreadCpuTime(id) 获取
// JVM 内部线程（如 GC 线程、Compiler 线程）：通过 HotspotThreadMBean 获取

Map<String, Long> internalThreadCpuTimes = hotspotThreadMBean.getInternalThreadCpuTimes();
// → {"VM Thread": 5230000, "GC Thread#0": 12340000, "C2 CompilerThread0": 89000, ...}
// 这些线程在普通 Thread API 中看不到！
```

---

## 3. jvm 命令 — JVM 信息全览

### 3.1 数据采集源

jvm 命令一次性采集 8 个维度的信息：

```java
@Override
public void process(CommandProcess process) {
    JvmModel model = new JvmModel();

    // ① 运行时信息（RuntimeMXBean）
    addRuntimeInfo(model);
    //  → MACHINE-NAME, JVM-START-TIME, VM-NAME, VM-VERSION
    //  → INPUT-ARGUMENTS, CLASS-PATH, BOOT-CLASS-PATH

    // ② 类加载信息（ClassLoadingMXBean）
    addClassLoading(model);
    //  → LOADED-CLASS-COUNT, TOTAL-LOADED-CLASS-COUNT, UNLOADED-CLASS-COUNT

    // ③ 编译信息（CompilationMXBean）
    addCompilation(model);
    //  → JIT 编译器名称, 总编译时间

    // ④ GC 信息（GarbageCollectorMXBean）
    addGarbageCollectors(model);
    //  → 每个 GC 的 name, collectionCount, collectionTime

    // ⑤ 内存管理器（MemoryManagerMXBean）
    addMemoryManagers(model);
    //  → 每个内存管理器管理的内存池列表

    // ⑥ 内存概览（MemoryMXBean）
    addMemory(model);
    //  → 堆/非堆的 init, used, committed, max
    //  → PENDING-FINALIZE-COUNT（等待 finalize 的对象数）

    // ⑦ 操作系统（OperatingSystemMXBean）
    addOperatingSystem(model);
    //  → OS, ARCH, PROCESSORS-COUNT, LOAD-AVERAGE

    // ⑧ 线程（ThreadMXBean）
    addThread(model);
    //  → COUNT, DAEMON-COUNT, PEAK-COUNT, STARTED-COUNT, DEADLOCK-COUNT

    // ⑨ 文件描述符（反射调用，非标准 API）
    addFileDescriptor(model);
    //  → MAX-FILE-DESCRIPTOR-COUNT, OPEN-FILE-DESCRIPTOR-COUNT

    process.appendResult(model);
    process.end();
}
```

### 3.2 文件描述符 — 反射获取

```java
private long invokeFileDescriptor(OperatingSystemMXBean os, String name) {
    try {
        // com.sun.management.UnixOperatingSystemMXBean 的方法
        // 标准 API 中没有，必须通过反射调用
        final Method method = os.getClass().getDeclaredMethod(name);
        method.setAccessible(true);
        return (Long) method.invoke(os);
    } catch (Exception e) {
        return -1;  // Windows 上不可用
    }
}
```

**为什么要关注文件描述符？**
- Linux 中"一切皆文件"，网络连接也是 FD
- 如果 `OPEN-FILE-DESCRIPTOR-COUNT` 接近 `MAX-FILE-DESCRIPTOR-COUNT`
- → 新连接会被拒绝，出现 "Too many open files" 错误
- 常见于连接泄漏场景

### 3.3 死锁检测

```java
private int getDeadlockedThreadsCount(ThreadMXBean threads) {
    final long[] ids = threads.findDeadlockedThreads();
    // → JDK 底层调用 JVMTI 检测 Monitor 和 ReentrantLock 的死锁环
    return (ids == null) ? 0 : ids.length;
}
```

---

## 4. memory 命令 — 内存详情

### 4.1 三层内存信息

```java
static Map<String, List<MemoryEntryVO>> memoryInfo() {
    // ① 堆内存（heap）
    //    总计 + 各区域（Eden、Survivor、Old Gen 等）
    MemoryUsage heapUsage = ManagementFactory.getMemoryMXBean().getHeapMemoryUsage();
    for (MemoryPoolMXBean pool : memoryPoolMXBeans) {
        if (pool.getType() == MemoryType.HEAP) {
            // → G1 Eden Space, G1 Survivor Space, G1 Old Gen
        }
    }

    // ② 非堆内存（non-heap）
    //    总计 + 各区域（Metaspace、Code Cache、Compressed Class Space）
    MemoryUsage nonHeapUsage = ManagementFactory.getMemoryMXBean().getNonHeapMemoryUsage();
    for (MemoryPoolMXBean pool : memoryPoolMXBeans) {
        if (pool.getType() == MemoryType.NON_HEAP) {
            // → Metaspace, Code Cache, Compressed Class Space
        }
    }

    // ③ 缓冲池（buffer pool）
    //    直接内存和内存映射文件
    List<BufferPoolMXBean> bufferPools = ManagementFactory.getPlatformMXBeans(BufferPoolMXBean.class);
    // → direct, mapped
}
```

**输出示例**：
```
Memory                    used       total      max        usage
heap                      256M       512M       8192M      3.13%
g1_eden_space             64M        256M       -1         25.00%
g1_old_gen                128M       256M       8192M      1.56%
g1_survivor_space         16M        16M        -1         100.00%
nonheap                   48M        52M        -1         92.31%
metaspace                 32M        34M        -1         94.12%
code_cache                8M         8M         240M       3.33%
compressed_class_space    4M         5M         1024M      0.39%
direct                    8M         8M         -          100.00%
mapped                    0K         0K         -          0.00%
```

### 4.2 MemoryUsage 四个关键值

```
           init      used      committed    max
           ───┬───   ───┬───   ────┬────    ──┬──
              │         │          │           │
              ▼         ▼          ▼           ▼
          ┌───┬─────────┬──────────┬───────────┐
内存空间   │   │ ████████ │          │           │
          └───┴─────────┴──────────┴───────────┘
          │   │←─ used ─→│          │           │
          │   │←──── committed ────→│           │
          │←────────────── max ────────────────→│

init:      JVM 向 OS 请求的初始大小
used:      当前实际使用量
committed: JVM 已从 OS 获得的量（可用但不一定都在用）
max:       最大可扩展到的量（-1 表示无上限）
```

---

## 5. vmoption 命令 — 运行时修改 VM 选项

### 5.1 核心实现

```java
HotSpotDiagnosticMXBean mxBean = ManagementFactory.getPlatformMXBean(HotSpotDiagnosticMXBean.class);

// ① 查看所有可诊断选项
mxBean.getDiagnosticOptions()  → List<VMOption>
// → PrintGC, PrintGCDetails, HeapDumpOnOutOfMemoryError, ...

// ② 查看指定选项
mxBean.getVMOption("PrintGC")  → VMOption{name, value, origin, writeable}

// ③ 修改选项
mxBean.setVMOption("PrintGC", "true")
// → 底层调用 HotSpot 的 Flag::set_flag()
// → 等价于 jcmd <pid> VM.set_flag PrintGC true
```

**哪些选项可以运行时修改？**

只有标记为 `manageable` 的 JVM 选项才能修改，典型的有：
```
PrintGC                    → 开启/关闭 GC 日志
PrintGCDetails             → 详细 GC 日志
HeapDumpOnOutOfMemoryError → OOM 时自动 dump
HeapDumpPath               → dump 文件路径
MinHeapFreeRatio           → 堆空闲最小比例
MaxHeapFreeRatio           → 堆空闲最大比例
```

**不能修改的**（需要重启 JVM）：
```
UseG1GC, MaxHeapSize, ThreadStackSize, ...
```

### 5.2 Tab 补全

```java
@Override
public void complete(Completion completion) {
    HotSpotDiagnosticMXBean mxBean = ManagementFactory.getPlatformMXBean(HotSpotDiagnosticMXBean.class);
    List<VMOption> options = mxBean.getDiagnosticOptions();
    List<String> names = new ArrayList<>();
    for (VMOption option : options) {
        names.add(option.getName());
    }
    CompletionUtils.complete(completion, names);
}
// 用户输入 "vmoption Print" 然后按 Tab
// → 自动补全为 PrintGC, PrintGCDetails, PrintGCDateStamps, ...
```

---

## 6. sysprop / sysenv — 简单但实用

### 6.1 sysprop — 系统属性（可修改）

```java
// 查看全部
System.getProperties()
// → file.encoding, java.home, user.dir, os.name, ...

// 查看指定
System.getProperty("file.encoding")
// → "UTF-8"

// ★ 修改（运行时生效！）
System.setProperty("production.mode", "true")
// → 代码中 System.getProperty("production.mode") 立即返回 "true"
```

**使用场景**：
- 动态切换日志级别（如果应用通过 sysprop 读取配置）
- 修改文件编码
- 设置调试标志

### 6.2 sysenv — 环境变量（只读）

```java
// 查看全部
System.getenv()
// → PATH, HOME, JAVA_HOME, LANG, ...

// 查看指定
System.getenv("JAVA_HOME")
// → "/usr/lib/jvm/java-11"
```

**注意**：环境变量在 JVM 启动时就确定了，**不能在运行时修改**（JDK 没有提供 `System.setenv()` 方法）。

---

## 7. perfcounter 命令 — JVM 内部性能计数器

### 7.1 Perf 是什么？

JVM 内部维护了一组性能计数器（PerfCounter），存储在共享内存中（`/tmp/hsperfdata_{user}/{pid}`），这也是 `jps`、`jstat` 等工具读取数据的来源。

### 7.2 实现方式 — 反射调用

```java
private static List<Counter> getPerfCounters() {
    // ① 获取 Perf 实例（JDK 8 vs JDK 11 类名不同）
    String perfClassName = JavaVersionUtils.isLessThanJava9()
        ? "sun.misc.Perf"           // JDK 8
        : "jdk.internal.perf.Perf"; // JDK 9+

    Class<?> perfClass = ClassLoader.getSystemClassLoader().loadClass(perfClassName);
    Method getPerfMethod = perfClass.getDeclaredMethod("getPerf");
    Object perfObject = getPerfMethod.invoke(null);

    // ② attach 到当前进程
    Method attachMethod = perfObject.getClass().getDeclaredMethod("attach", int.class, String.class);
    ByteBuffer buffer = (ByteBuffer) attachMethod.invoke(perfObject, currentPid, "r");

    // ③ 解析性能计数器
    PerfInstrumentation perfInstrumentation = new PerfInstrumentation(buffer);
    return perfInstrumentation.getAllCounters();
    // → java.cls.loadedClasses = 5678
    // → java.gc.collector.0.invocations = 42
    // → java.gc.collector.0.time = 1234567890
    // → sun.gc.generation.0.space.0.used = 67108864
    // → ...
}
```

**为什么要用反射？**
- `sun.misc.Perf` 和 `jdk.internal.perf.Perf` 都是内部 API
- JDK 9+ 的模块系统默认不开放这些包
- 需要添加 `--add-opens` 才能正常工作

### 7.3 perfcounter 的独特价值

```
perfcounter 能看到 jvm 命令看不到的信息：

# GC 详细数据
java.gc.collector.0.name = "G1 Young Generation"
java.gc.collector.0.invocations = 42          ← GC 次数
java.gc.collector.0.lastEntryTime = 123456    ← 上次 GC 开始时间（ticks）
java.gc.collector.0.lastExitTime = 123789     ← 上次 GC 结束时间（ticks）

# 类加载器
java.cls.loadedClasses = 5678
java.cls.unloadedClasses = 23

# SafePoint 统计
sun.rt.safepoints = 156              ← SafePoint 次数
sun.rt.safepointTime = 2345678       ← SafePoint 总时间（ns）
sun.rt.applicationTime = 987654321   ← 应用运行时间（ns）

# 编译统计
java.ci.totalTime = 456789           ← JIT 编译总时间
sun.ci.totalCompiles = 1234          ← 编译方法总数
sun.ci.osrCompiles = 56              ← OSR 编译次数
```

---

## 8. heapdump 命令 — 堆转储

### 8.1 核心实现（极其简单）

```java
@Override
public void process(CommandProcess process) {
    String dumpFile = file;
    if (dumpFile == null || dumpFile.isEmpty()) {
        // 自动生成文件名：heapdump2026-02-10-14-30-live.hprof
        String date = new SimpleDateFormat("yyyy-MM-dd-HH-mm").format(new Date());
        File file = File.createTempFile("heapdump" + date + (live ? "-live" : ""), ".hprof");
        dumpFile = file.getAbsolutePath();
        file.delete();  // 只要路径，先删除空文件
    }

    // ★ 一行代码完成堆转储！
    HotSpotDiagnosticMXBean mxBean = ManagementFactory.getPlatformMXBean(HotSpotDiagnosticMXBean.class);
    mxBean.dumpHeap(dumpFile, live);
    //                        ↑ live = true 时先触发 Full GC，只 dump 存活对象
}
```

### 8.2 --live 参数的影响

```
heapdump                → dump 所有对象（包括垃圾对象）
heapdump --live         → 先 Full GC，再 dump 存活对象

| 维度 | 无 --live | --live |
|------|----------|--------|
| 文件大小 | 更大 | 更小 |
| 停顿时间 | 较短 | 较长（Full GC） |
| 分析价值 | 可看到即将被回收的对象 | 只看存活对象，更干净 |
| 适用场景 | 怀疑 GC 回收策略有问题 | 排查内存泄漏 |
```

**⚠️ 风险提示**：
- heapdump 会导致**长时间 STW**（堆越大停顿越久）
- 8GB 堆的 dump 文件可能达到数 GB
- 生产环境慎用，建议先用 `memory` 命令确认是否真的需要 dump

---

## 9. 命令对比总结

### 9.1 数据源矩阵

```
                  Thread  Memory  Mem    GC     Runtime  OS    Class  Compile  FD   Perf  Lock
命令 ↓ / 维度 →  MXBean  MXBean  Pool   MXBean MXBean   MXBean Load  MXBean        Cnt   Info
─────────────────────────────────────────────────────────────────────────────────────────────
dashboard         ✅      ✅      ✅     ✅     ✅       ✅                              
thread            ✅                                                                   ✅
jvm               ✅      ✅             ✅     ✅       ✅     ✅     ✅      ✅         ✅
memory                    ✅      ✅                                                    
vmoption          (HotSpotDiagnosticMXBean)
sysprop           (System.getProperties)
sysenv            (System.getenv)
perfcounter       (sun.misc.Perf / jdk.internal.perf.Perf)
heapdump          (HotSpotDiagnosticMXBean.dumpHeap)
```

### 9.2 典型排查流程

```bash
# ① 先看全局 — dashboard
$ dashboard
→ 发现 CPU 93%，Old Gen 接近满

# ② 找 CPU 热点 — thread
$ thread -n 3
→ 发现线程 "pool-1-thread-42" CPU 87%
→ 看到栈顶是 com.example.DataProcessor.parse()

# ③ 确认内存状态 — memory
$ memory
→ g1_old_gen: used=7680M, max=8192M (93.75%)
→ 确认快 OOM 了

# ④ 查看 GC 是否频繁 — perfcounter
$ perfcounter -d | grep gc
→ java.gc.collector.1.invocations = 342（老年代 GC 342 次）
→ java.gc.collector.1.time = 156000ms（累计 156 秒）

# ⑤ 开启 GC 日志 — vmoption
$ vmoption PrintGCDetails true
→ 后续可以看到详细 GC 日志

# ⑥ 找到阻塞源 — thread -b
$ thread -b
→ "pool-1-thread-1" 持有锁 0x7f8a1234，阻塞了 47 个线程

# ⑦ 最后手段 — heapdump
$ heapdump --live /tmp/dump.hprof
→ 用 MAT/VisualVM 分析内存泄漏
```

---

## 10. 设计总结

### 10.1 核心设计决策

| # | 决策 | 选择 | 理由 |
|---|------|------|------|
| 1 | CPU 使用率计算方式 | 两次采样差值法 | 获取瞬时 CPU 使用率，而非累积时间 |
| 2 | JVM 内部线程 | HotspotThreadMBean 反射获取 | 标准 API 看不到 GC/Compiler 线程 |
| 3 | dashboard 刷新机制 | Timer + TimerTask | 简单可靠，支持暂停/恢复 |
| 4 | Tomcat 信息采集 | HTTP 内部 API | 不依赖 JMX，直接 HTTP 调用 |
| 5 | Perf 计数器获取 | 反射 + JDK 版本适配 | 跨 JDK 8/9+ 兼容 |
| 6 | heapdump 实现 | HotSpotDiagnosticMXBean | 一行代码，JDK 标准 API |

### 10.2 与 JDK 命令行工具的对应

| Arthas 命令 | 等价 JDK 工具 | Arthas 优势 |
|-------------|-------------|-------------|
| thread -n 5 | `jstack <pid>` + 手动分析 | 自动计算 CPU%，自动排序 |
| thread -b | `jstack <pid>` + 手动找 BLOCKED | O(n) 算法自动找到 |
| jvm | `jcmd <pid> VM.info` | 更结构化的输出 |
| memory | `jcmd <pid> GC.heap_info` | 包含 BufferPool |
| vmoption | `jcmd <pid> VM.set_flag` | Tab 补全，更友好 |
| perfcounter | `jstat -J-Djstat.showUnsupported=true` | 更完整，带详情 |
| heapdump | `jmap -dump:live,format=b <pid>` | 不需要知道 pid |

---

> **下一节**: [Ch 11 profiler/火焰图](ch11_profiler_flame_graph.md) — Arthas 集成 async-profiler 实现 CPU/内存火焰图
