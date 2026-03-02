# MonitorCommand 深度解析

> 基于 Arthas 4.1.2 源码分析
> 方法论：程序 = 数据结构 + 算法

---

## 第 0 部分：核心原理

### 0.1 本质是什么？

MonitorCommand 是 Arthas 的**方法执行统计命令**，通过字节码增强拦截目标方法的每次调用，在内存中累积统计数据（调用次数、成功率、平均耗时），并按周期输出聚合结果。

### 0.2 为什么需要？

watch/trace 命令输出的是每次调用的实时数据，适合调试。但生产环境更常见的需求是**趋势监控**：这个方法最近的平均耗时是多少？成功率有没有下降？调用量有没有异常增长？monitor 通过周期性聚合统计满足这类需求。

### 0.3 怎么解决？

核心思路：**字节码增强 + ConcurrentHashMap 原子累加 + Timer 周期性输出**。

1. 与 watch 命令复用相同的字节码增强流程（继承 EnhancerCommand）
2. 在 `before()` 记录时间戳，在 `afterReturning/afterThrowing` 计算耗时并更新 `ConcurrentHashMap<Key, MonitorData>`
3. `Timer` 定时任务每 `cycle` 秒读取并输出统计数据，然后清零

### 0.4 为什么这样设计？

- **为什么用 ConcurrentHashMap 而不是 synchronized？** 多线程同时调用目标方法时，ConcurrentHashMap 的分段锁机制比全局 synchronized 并发性能更好。
- **为什么用 Timer 而不是 ScheduledExecutorService？** Timer 足以满足单任务定时需求，且 Arthas 对定时精度要求不高。Timer 代码更简洁，且支持 daemon 线程。
- **为什么统计周期默认 60 秒？** 太短（如 1 秒）在低流量场景数据量不足以有统计意义；太长（如 10 分钟）实时性差。60 秒在大多数场景下是合理的默认值。

---

## 第 1 部分：宏观理解

### 1.1 解决什么问题

monitor 命令用于**统计方法执行情况**，按周期输出方法的调用次数、成功率、平均耗时等信息。与 watch/trace 不同，monitor 更关注**聚合统计**而非每次调用的详细信息。

### 1.2 与 watch/trace 的区别

| 特性 | watch | trace | monitor |
|------|-------|-------|---------|
| 输出内容 | 单次调用详情 | 调用树 | 聚合统计 |
| 时间维度 | 实时输出 | 实时输出 | 周期性输出 |
| 统计维度 | - | - | 次数/耗时/成功率 |
| 适用场景 | 调试特定调用 | 分析调用链路 | 监控性能指标 |

### 1.3 总体调用链（Mermaid 图）

```mermaid
flowchart TD
    A[用户输入 monitor 命令] --> B[EnhancerCommand.process]
    B --> C[MonitorCommand.getClassNameMatcher]
    B --> D[MonitorCommand.getMethodNameMatcher]
    B --> E[MonitorCommand.getAdviceListener]
    E --> F[创建 MonitorAdviceListener]
    F --> G[create() 启动定时器]
    G --> H[enhance 执行字节码增强]
    H --> I[业务方法被调用]
    I --> J[MonitorAdviceListener.before]
    I --> K[MonitorAdviceListener.afterReturning]
    I --> L[MonitorAdviceListener.afterThrowing]
    J --> M[计算耗时]
    K --> N[finishing 更新统计数据]
    L --> N
    N --> O[ConcurrentHashMap 原子更新]
    O --> P{周期性定时器触发}
    P --> Q[MonitorTimer.run 输出统计]
    Q --> R[渲染 MonitorModel]
    R --> S[输出到终端]
```

### 1.4 涉及的数据结构清单

| 结构名 | 源码位置 | 核心作用 |
|--------|----------|----------|
| **MonitorCommand** | monitor200/MonitorCommand.java:31 | monitor 命令入口 |
| **MonitorAdviceListener** | monitor200/MonitorAdviceListener.java:67 | 统计回调处理 |
| **MonitorData** | monitor200/MonitorData.java:10 | 单个方法的统计数据 |
| **MonitorTimer** | monitor200/MonitorAdviceListener.java:181 | 周期性输出定时器 |
| **MonitorModel** | command/model/MonitorModel.java | 统计结果模型 |
| **Key** | monitor200/MonitorAdviceListener.java:233 | 统计数据的 key (类名+方法名) |

---

## 二、数据结构全景 ⭐

### 2.1 MonitorCommand（完整 6 项分析）

#### 问题推导

**问题**：monitor 命令需要什么参数来完成"周期性统计方法调用"的任务？

**需要什么信息？**
- **哪个类的哪个方法** → classPattern + methodPattern
- **多久输出一次统计** → cycle（周期，默认 60 秒）
- 需要**过滤条件**吗 → conditionExpress（可选）
- 需要**限制输出次数**吗 → numberOfLimit

**推导出的结构**：继承 EnhancerCommand（复用类/方法匹配逻辑），新增 cycle、conditionExpress 等参数字段。

#### 2.1.1 字段列表

```java
// MonitorCommand.java:31-40
public class MonitorCommand extends EnhancerCommand {

    private String classPattern;       // 类名模式
    private String methodPattern;      // 方法名模式
    private String conditionExpress;   // 条件表达式
    private int cycle = 60;          // 统计周期（秒）
    private boolean isRegEx = false;  // 是否正则匹配
    private int numberOfLimit = 100; // 执行次数限制
    private boolean isBefore = false; // 是否在方法执行前判断条件
}
```

#### 2.1.2 每个字段的含义

| 字段 | 类型 | 含义 | 使用场景 | 核心 |
|------|------|------|----------|------|
| `classPattern` | String | 要监控的类名模式 | 第一个位置参数 | ★ |
| `methodPattern` | String | 要监控的方法名模式 | 第二个位置参数 | ★ |
| `conditionExpress` | String | 条件过滤表达式 | 只统计满足条件的调用 | |
| `cycle` | int | 统计周期（秒） | `-c` 参数，默认 60 秒 | ★ |
| `isRegEx` | boolean | 是否使用正则匹配 | `-E` 参数 | |
| `numberOfLimit` | int | 最多输出次数 | `-n` 参数，默认 100 | |
| `isBefore` | boolean | 是否在方法执行前判断条件 | `-b` 参数 | |

#### 2.1.3 值域图

`cycle` 参数的值域：

```
┌─────────────────────────────────────────────────────────┐
│                    cycle 值域                            │
├─────────────────────────────────────────────────────────┤
│                                                         │
│   [1] ──────► [60] ──────► [300] ──────► [N]         │
│    ↑            ↑             ↑            ↑            │
│    │            │             │            │            │
│  最小值      默认值        5分钟        自定义           │
│                                                         │
│  周期越短，数据越实时但输出越频繁                         │
│  周期越长，数据更聚合但实时性降低                        │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

---

### 2.2 MonitorAdviceListener 详细分析

#### 问题推导

**问题**：高频方法每秒被调用上万次，怎么在不阻塞业务的情况下收集统计数据并周期性输出？

**需要什么信息？**
- 需要**累积统计**（调用次数、成功/失败次数、耗时）→ 需要线程安全的计数容器
- 需要**按方法分组**统计 → Key (类名+方法名) → MonitorData 的 Map
- 需要**周期性输出**而非每次调用都输出 → 需要 Timer 定时器
- 需要**计时**计算方法耗时 → ThreadLocalWatch（线程本地计时器）

**推导出的结构**：持有 Timer + ConcurrentHashMap<Key, AtomicReference<MonitorData>> + ThreadLocalWatch 的监听器。

#### 2.2.1 字段列表

```java
// MonitorAdviceListener.java:67-82
class MonitorAdviceListener extends AdviceListenerAdapter {
    
    // 定时器：用于周期性输出统计
    private Timer timer;
    
    // 监控数据存储：Key -> AtomicReference<MonitorData>
    // 使用 ConcurrentHashMap 保证线程安全
    private ConcurrentHashMap<Key, AtomicReference<MonitorData>> monitorData 
        = new ConcurrentHashMap<Key, AtomicReference<MonitorData>>();
    
    // 线程本地计时器
    private final ThreadLocalWatch threadLocalWatch = new ThreadLocalWatch();
    
    // 条件判断结果（用于 -b 参数）
    private final ThreadLocal<Boolean> conditionResult = new ThreadLocal<Boolean>();
    
    // 关联对象
    private MonitorCommand command;
    private CommandProcess process;
}
```

#### 2.2.2 每个字段的含义

| 字段 | 类型 | 含义 | 使用场景 | 核心 |
|------|------|------|----------|------|
| `timer` | Timer | 周期性输出定时器 | create() 时创建，destroy() 时取消 | ★ |
| `monitorData` | ConcurrentHashMap | 统计数据存储 | Key (类名+方法名) → MonitorData | ★ |
| `threadLocalWatch` | ThreadLocalWatch | 线程本地计时器 | 计算方法执行耗时 | ★ |
| `conditionResult` | ThreadLocal<Boolean> | 条件判断结果 | -b 参数时在 before 中设置 | |
| `command` | MonitorCommand | 命令对象 | 获取参数 | |
| `process` | CommandProcess | 命令进程 | 输出结果 | |

#### 2.2.3 sizeof 与内存布局

> 详见 `31-Object-Memory-Layout-Analysis.md`

继承链：`MonitorAdviceListener → AdviceListenerAdapter → Object`

**注意**：`logger` 是 `static` 字段，不计入对象布局。MonitorAdviceListener 有自己的 `process`(CommandProcess)，与父类 `process`(Process) 是两个不同字段。

```
MonitorAdviceListener 对象内存布局（CompressedOops ON）
┌──────────────────────────────────────┐ 偏移 0
│ mark word              (8 bytes)     │
├──────────────────────────────────────┤ 偏移 8
│ compressed klass ptr   (4 bytes)     │
├──────────────────────────────────────┤ 偏移 12
│ [父] process (Process) (4 bytes)     │  ★ 引用填入间隙
├──────────────────────────────────────┤ 偏移 16
│ [父] id               (8 bytes)      │
├──────────────────────────────────────┤ 偏移 24
│ [父] verbose (1) + padding (3)       │  4 bytes
├──────────────────────────────────────┤ 偏移 28
│ timer                  (4 bytes)     │
├──────────────────────────────────────┤ 偏移 32
│ monitorData            (4 bytes)     │
├──────────────────────────────────────┤ 偏移 36
│ threadLocalWatch       (4 bytes)     │
├──────────────────────────────────────┤ 偏移 40
│ conditionResult        (4 bytes)     │
├──────────────────────────────────────┤ 偏移 44
│ command                (4 bytes)     │
├──────────────────────────────────────┤ 偏移 48
│ process (CommandProcess)(4 bytes)    │
├──────────────────────────────────────┤ 偏移 52
│ padding                (4 bytes)     │  ★ 对齐到 8 的倍数
└──────────────────────────────────────┘ 偏移 56

MonitorAdviceListener shallow size = 56 bytes
```

---

### 2.3 MonitorData 详细分析

#### 问题推导

**问题**：每个方法需要统计哪些指标？怎么做到线程安全且低开销？

**需要什么信息？**
- 需要统计 **total（总调用）、success（成功）、failed（失败）、cost（总耗时）** → 4 个数值字段
- 需要知道**是哪个方法的统计** → className + methodName
- 使用 `AtomicReference<MonitorData>` + CAS 更新 → MonitorData 本身可以是**不可变**的（每次 CAS 创建新实例）

**推导出的结构**：包含 className + methodName + 4 个统计字段的简单 POJO。

#### 2.3.1 字段列表

```java
// MonitorData.java:10-17
public class MonitorData {
    private String className;       // 类名
    private String methodName;      // 方法名
    private int total;             // 总调用次数
    private int success;           // 成功次数
    private int failed;            // 失败次数
    private double cost;           // 总耗时（毫秒）
    private LocalDateTime timestamp; // 时间戳
}
```

#### 2.3.2 sizeof 与内存布局

> 详见 `31-Object-Memory-Layout-Analysis.md`

```
MonitorData 对象内存布局（CompressedOops ON）
┌──────────────────────────────────────┐ 偏移 0
│ mark word              (8 bytes)     │
├──────────────────────────────────────┤ 偏移 8
│ compressed klass ptr   (4 bytes)     │
├──────────────────────────────────────┤ 偏移 12
│ total                  (4 bytes)     │  ★ int 填入间隙
├──────────────────────────────────────┤ 偏移 16
│ cost                   (8 bytes)     │  ★ double 对齐到 8
├──────────────────────────────────────┤ 偏移 24
│ success                (4 bytes)     │
├──────────────────────────────────────┤ 偏移 28
│ failed                 (4 bytes)     │
├──────────────────────────────────────┤ 偏移 32
│ className              (4 bytes)     │
├──────────────────────────────────────┤ 偏移 36
│ methodName             (4 bytes)     │
├──────────────────────────────────────┤ 偏移 40
│ timestamp              (4 bytes)     │
├──────────────────────────────────────┤ 偏移 44
│ padding                (4 bytes)     │  ★ 对齐到 8 的倍数
└──────────────────────────────────────┘ 偏移 48

MonitorData shallow size = 48 bytes
```

**关键设计影响**：MonitorAdviceListener 在每次回调中通过 CAS 创建**新的 MonitorData**（不可变语义），旧对象成为垃圾。在高频方法（10000 次/秒）下，每秒产生约 480KB 的 MonitorData 垃圾。

#### 2.3.3 统计指标计算

| 指标 | 字段 | 计算公式 |
|------|------|----------|
| 总调用次数 | `total` | 每次调用 +1 |
| 成功次数 | `success` | afterReturning 时 +1 |
| 失败次数 | `failed` | afterThrowing 时 +1 |
| 平均耗时 | `cost / total` | 总耗时 / 总次数 |
| 失败率 | `failed / total` | 失败次数 / 总次数 |

---

### 2.4 Key 类（统计数据的 key）

#### 问题推导

**问题**：ConcurrentHashMap 的 key 需要什么属性才能正确索引？

**需要什么信息？**
- 用 `className + methodName` 唯一标识一个方法 → 两个 String 字段
- 作为 HashMap 的 key → 必须正确实现 `hashCode()` + `equals()`

**推导出的结构**：持有 className + methodName，重写 hashCode/equals 的内部类。

#### 2.4.1 设计原理

```java
// MonitorAdviceListener.java:233-263
private static class Key {
    private final String className;   // 不可变
    private final String methodName;  // 不可变
    
    // hashCode 和 equals 基于 className + methodName
    // 用于 ConcurrentHashMap 的 key
}
```

**设计决策**：
- 使用不可变字段（final），确保在多线程环境下的安全性
- hashCode/equals 用于正确查找和去重

---

## 第 3 部分：算法/流程分析

### 3.1 create() 启动定时器

#### 3.1.1 解决什么问题？

在监听器创建时启动周期性定时器，按 `--cycle` 参数指定的间隔输出统计信息。

#### 3.1.2 真实源码 + 逐行注释

```java
// MonitorAdviceListener.java:89-96
@Override
public synchronized void create() {
    // ★ 首次创建时初始化定时器
    if (timer == null) {
        // ★ 创建 Timer 线程，守护线程
        // 线程名格式：Timer-for-arthas-monitor-{sessionId}
        timer = new Timer("Timer-for-arthas-monitor-" + process.session().getSessionId(), true);
        
        // ★ 注册周期性任务
        // 参数1: MonitorTimer 任务
        // 参数2: 首次执行延迟（0，立即执行）
        // 参数3: 执行间隔（cycle * 1000 毫秒）
        timer.scheduleAtFixedRate(
            new MonitorTimer(monitorData, process, command.getNumberOfLimit()),
            0, 
            command.getCycle() * 1000L);
    }
}
```

**设计决策**：
- **守护线程**：timer 使用 `new Timer(..., true)`，确保 JVM 退出时定时器也会停止
- **scheduleAtFixedRate**：固定频率执行，保证周期性输出的稳定性

---

### 3.2 before() 方法执行前处理

#### 3.2.1 解决什么问题？

在方法执行前开始计时，并且如果设置了 `-b` 参数，则在执行前判断条件表达式。

#### 3.2.2 真实源码 + 逐行注释

```java
// MonitorAdviceListener.java:106-117
@Override
public void before(ClassLoader loader, Class<?> clazz, ArthasMethod method, Object target, Object[] args)
        throws Throwable {
    // ★ 开始计时
    threadLocalWatch.start();
    
    // ★ 如果设置了 -b 参数（isBefore）
    // 在方法执行前判断条件表达式
    if (!StringUtils.isEmpty(this.command.getConditionExpress()) && command.isBefore()) {
        // ★ 创建 Advice 上下文
        Advice advice = Advice.newForBefore(loader, clazz, method, target, args);
        
        // ★ 计算条件表达式耗时（不计入方法耗时）
        long cost = threadLocalWatch.cost();
        
        // ★ 判断条件是否满足，结果存入 ThreadLocal
        this.conditionResult.set(isConditionMet(this.command.getConditionExpress(), advice, cost));
        
        // ★ 重新开始计时（排除条件判断的耗时）
        threadLocalWatch.start();
    }
}
```

---

### 3.3 finishing() 核心统计逻辑

#### 3.3.1 解决什么问题？

这是 monitor 命令的**核心算法**，负责：
1. 条件判断
2. 原子更新统计数据
3. 计算聚合指标

#### 3.3.2 整体流程（4 个阶段）

```
Phase 1: 条件判断
Phase 2: 构建 Key
Phase 3: CAS 原子更新
Phase 4: 完成
```

#### 3.3.3 Phase 1: 条件判断

```java
// MonitorAdviceListener.java:131-149
private void finishing(Class<?> clazz, ArthasMethod method, boolean isThrowing, Advice advice) {
    // ★ Phase 1: 计算方法耗时
    double cost = threadLocalWatch.costInMillis();

    // ★ 判断是否使用前置条件判断
    if (command.isBefore()) {
        // -b 参数：在方法执行前判断条件
        if (!this.conditionResult.get()) {
            return;  // 条件不满足，不纳入统计
        }
    } else {
        // 默认：在方法返回后判断条件
        try {
            if (!isConditionMet(this.command.getConditionExpress(), advice, cost)) {
                return;  // 条件不满足，不纳入统计
            }
        } catch (ExpressException e) {
            logger.warn("monitor execute condition-express failed.", e);
            return;  // 表达式执行错误，不纳入统计
        }
    }
```

#### 3.3.4 Phase 2-3: 原子更新统计

```java
    // ★ Phase 2: 构建 Key（类名 + 方法名）
    final Key key = new Key(clazz.getName(), method.getName());

    // ★ Phase 3: CAS 原子更新
    // 使用 while 循环 + CAS 保证原子性
    while (true) {
        // 从 Map 中获取当前统计值
        AtomicReference<MonitorData> value = monitorData.get(key);
        if (null == value) {
            // 首次调用，创建新的 MonitorData
            monitorData.putIfAbsent(key, new AtomicReference<MonitorData>(new MonitorData()));
            continue;  // 重新获取
        }

        // CAS 更新：创建新对象 -> 修改 -> compareAndSet
        while (true) {
            MonitorData oData = value.get();   // 旧数据
            MonitorData nData = new MonitorData();  // 新数据
            
            // 累加耗时
            nData.setCost(oData.getCost() + cost);
            nData.setTimestamp(LocalDateTime.now());
            
            // 根据成功/失败更新计数
            if (isThrowing) {
                nData.setFailed(oData.getFailed() + 1);
                nData.setSuccess(oData.getSuccess());
            } else {
                nData.setFailed(oData.getFailed());
                nData.setSuccess(oData.getSuccess() + 1);
            }
            nData.setTotal(oData.getTotal() + 1);
            
            // ★ CAS 更新：如果值没变，则更新成功
            if (value.compareAndSet(oData, nData)) {
                break;
            }
            // 如果值被其他线程修改了，重试
        }
        break;
    }
}
```

**设计决策**：
- **为什么使用 CAS？** 多线程环境下多个方法调用可能同时触发 finishing，需要保证原子性
- **为什么创建新对象？** MonitorData 是不可变的，CAS 失败后可以安全重试
- **为什么用 while 双重循环？** 外层处理 Key 不存在的情况，内层处理 CAS 竞争

#### 3.3.5 CAS 原子更新机制深度解析

**Compare-And-Swap (CAS) 原理**：

CAS 是一种无锁并发控制机制，其核心思想是：**只有当内存值与预期值相同时，才执行更新操作**。

```
┌─────────────────────────────────────────────────────────────────┐
│                  CAS 工作流程                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   线程 A                           内存                          │
│     │                               │                           │
│     │  读取当前值 oData ────────────►│  value = MonitorData@1   │
│     │                               │                           │
│     │  创建新值 nData               │                           │
│     │  (基于 oData 计算)            │                           │
│     │                               │                           │
│     │  compareAndSet(oData, nData)  │                           │
│     │  ────────────────────────────►│  检查: value == oData?    │
│     │                               │                           │
│     │                        ┌──────┴──────┐                    │
│     │                        │             │                    │
│     │                      是│           否│                    │
│     │                        │             │                    │
│     │                   更新成功      value 被其他线程改了       │
│     │                   返回 true     返回 false                │
│     │                        │             │                    │
│     │                        ▼             ▼                    │
│     │                      break      重试（重新读取）           │
│     │                                     │                    │
│     │                               ┌─────┘                    │
│     │                               │                          │
│     │  重新读取当前值 ──────────────►│  value = MonitorData@2  │
│     │  (此时是新的值)                │  (其他线程已更新)         │
│     │                               │                          │
│     │  再次尝试 CAS ────────────────►│                          │
│     │                               │                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Java AtomicReference.compareAndSet() 实现**：

```java
// AtomicReference.java - JDK 源码
public final boolean compareAndSet(V expect, V update) {
    // 调用 Unsafe 类的本地方法
    // 这是一个原子操作，由 CPU 硬件保证
    return unsafe.compareAndSwapObject(this, valueOffset, expect, update);
}
```

**关键点**：
1. **原子性保证**：compareAndSwapObject 是 native 方法，由 JVM 调用 CPU 的 CAS 指令（x86 的 cmpxchg）
2. **无锁设计**：不需要获取锁，避免了锁竞争的开销
3. **乐观策略**：假设没有竞争，失败时重试而非阻塞

**Monitor 中的 CAS 使用模式**：

```java
// 典型的 CAS 更新模式
while (true) {
    MonitorData oldData = value.get();       // 1. 读取当前值
    MonitorData newData = copyAndModify(oldData);  // 2. 创建修改后的新值
    if (value.compareAndSet(oldData, newData)) {  // 3. CAS 更新
        break;  // 成功则退出
    }
    // 失败则重试（重新读取）
}
```

**为什么不用 synchronized？**

| 方案 | 优点 | 缺点 |
|------|------|------|
| **synchronized** | 简单，语义清晰 | 获取锁有开销，可能阻塞，高并发下性能差 |
| **CAS** | 无锁，不阻塞，高并发性能好 | 需要重试逻辑，可能 ABA 问题 |
| **Monitor 选择** | CAS | 方法调用非常频繁，性能优先 |

---

### 3.4 MonitorTimer.run() 周期性输出

#### 3.4.1 解决什么问题？

定时器触发时，收集并输出当前周期的统计数据。

#### 3.4.2 真实源码 + 逐行注释

```java
// MonitorAdviceListener.java:192-224
@Override
public void run() {
    // ★ 检查是否有数据
    if (monitorData.isEmpty()) {
        return;
    }
    
    // ★ 检查是否达到输出次数限制
    if (process.times().getAndIncrement() >= limit) {
        this.cancel();      // 取消定时器
        abortProcess(process, limit);  // 终止命令
        return;
    }

    // ★ 收集统计数据
    List<MonitorData> monitorDataList = new ArrayList<MonitorData>(monitorData.size());
    for (Map.Entry<Key, AtomicReference<MonitorData>> entry : monitorData.entrySet()) {
        final AtomicReference<MonitorData> value = entry.getValue();

        MonitorData data;
        while (true) {
            data = value.get();
            // ★ 交换数据：使用新对象替换旧对象
            // 这样可以实现"清零"效果：每次输出后重置计数
            if (value.compareAndSet(data, new MonitorData())) {
                break;
            }
        }

        if (null != data) {
            data.setClassName(entry.getKey().getClassName());
            data.setMethodName(entry.getKey().getMethodName());
            monitorDataList.add(data);
        }
    }
    
    // ★ 输出结果
    process.appendResult(new MonitorModel(monitorDataList));
}
```

**设计决策**：
- **交换数据而非清零**：使用 compareAndSet 交换成新的 MonitorData 对象，实现"清零"效果
- **为什么用新对象？** 避免在输出过程中修改数据

---

## 四、数据结构关系图（Mermaid）

```mermaid
classDiagram
    direction TB
    
    <<class>> MonitorCommand
    <<class>> MonitorAdviceListener
    <<class>> MonitorData
    <<class>> MonitorTimer
    <<class>> MonitorModel
    <<class>> Key
    
    MonitorCommand --> MonitorAdviceListener : creates
    
    MonitorAdviceListener --> MonitorData : manages via ConcurrentHashMap
    MonitorAdviceListener --> MonitorTimer : schedules
    MonitorAdviceListener --> Key : uses as map key
    
    MonitorTimer --> MonitorModel : produces
    
    class MonitorCommand {
        +classPattern: String
        +methodPattern: String
        +conditionExpress: String
        +cycle: int
        +numberOfLimit: int
        +isBefore: boolean
    }
    
    class MonitorAdviceListener {
        -timer: Timer
        -monitorData: ConcurrentHashMap
        -threadLocalWatch: ThreadLocalWatch
        -conditionResult: ThreadLocal
        +create()
        +destroy()
        +before()
        +afterReturning()
        +afterThrowing()
        +finishing()
    }
    
    class MonitorData {
        -className: String
        -methodName: String
        -total: int
        -success: int
        -failed: int
        -cost: double
        -timestamp: LocalDateTime
    }
    
    class Key {
        -className: String
        -methodName: String
        +hashCode()
        +equals()
    }
    
    class MonitorTimer {
        +run()
    }
```

---

## 第 5 部分：总结

### 5.1 数据结构层面

| 结构 | 核心特征 |
|------|----------|
| **MonitorCommand** | 命令参数封装，cycle 参数控制输出周期 |
| **MonitorAdviceListener** | 核心监听器，create() 启动定时器，finishing() 原子更新统计 |
| **MonitorData** | 统计单元，total/success/failed/cost 四个字段 |
| **MonitorTimer** | 定时任务，run() 收集并输出统计 |
| **Key** | 统计数据的 key，使用 className + methodName |

### 5.2 算法层面

| 算法 | 核心设计决策 |
|------|-------------|
| **定时输出** | Timer + scheduleAtFixedRate 固定频率执行 |
| **条件判断** | 支持 -b 参数（方法执行前判断）或默认（方法返回后判断）|
| **原子更新** | ConcurrentHashMap + CAS，确保多线程安全 |
| **数据交换** | compareAndSet 交换成新对象，实现"清零"效果 |
| **性能统计** | 总耗时 / 调用次数 = 平均耗时 |

### 5.3 核心要点

1. **monitor 是聚合统计**，不同于 watch/trace 的单次输出
2. **周期性输出**通过 Timer 实现，周期由 `-c` 参数控制（默认 60 秒）
3. **线程安全**使用 ConcurrentHashMap + CAS，无锁设计高性能
4. **数据交换**通过 compareAndSet 实现，每次输出后自动清零重新统计
5. **支持条件过滤**通过 condition-express，可以只统计满足条件的调用
6. **前后判断**通过 -b 参数控制条件判断时机（方法执行前 vs 返回后）
