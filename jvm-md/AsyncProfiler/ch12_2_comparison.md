# 12.2 async-profiler vs JFR vs jstack — 三者采样原理深度对比

> 前置: 12.1 完整采样流程时序图
> 目标: 理解三种 profiling 方案的本质差异

---

## 核心问题

Java 世界有三大 profiling 手段：
1. **async-profiler**：信号驱动 + AsyncGetCallTrace
2. **JDK Flight Recorder (JFR)**：JVM 内置 + Safepoint 采样
3. **jstack / ThreadMXBean**：手动 dump + Safepoint

它们到底有什么区别？为什么 async-profiler 能看到 jstack 看不到的东西？

---

## 一、总览对比

| 维度 | async-profiler | JDK JFR | jstack/ThreadMXBean |
|------|---------------|---------|---------------------|
| **采样触发** | SIGPROF (硬件/软件中断) | Safepoint 采样 | 手动触发 / 定时器 |
| **需要 Safepoint？** | ❌ **不需要** | ✅ 需要 | ✅ 需要 |
| **获取栈的方式** | AsyncGetCallTrace | JVM 内部 API | GetAllStackTraces |
| **Native 帧** | ✅ 完整 (walkFP/Dwarf/VM) | ❌ 仅 Java 帧 | ❌ 仅 Java 帧 |
| **混合帧** | ✅ Java + Native 混合 | ❌ 分离的 | ❌ 仅 Java |
| **安全点偏差** | ❌ 无偏差 | ✅ 有偏差 | ✅ 有偏差 |
| **额外事件** | CPU/Wall/Alloc/Lock/Malloc/NativeLock | CPU/Alloc/Lock/IO/… | 无 |
| **开销** | ~1-2% | ~1-2% | 高 (STW) |
| **输出格式** | JFR/HTML/Collapsed/Text | JFR | 文本 |
| **是否需要 Agent** | ✅ (JVMTI Agent) | ❌ (内置) | ❌ (内置) |
| **最低 JDK 版本** | JDK 8+ | JDK 11+ (开源) | JDK 1.5+ |

---

## 二、Safepoint 偏差 — 最关键的差异

### 2.1 什么是 Safepoint 偏差？

```
JVM Safepoint 机制：
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

JFR/jstack 采样流程:
  采样定时器触发
      │
      ▼
  VMThread: 设置 Safepoint 请求
      │
      ▼
  所有 Java 线程: 到达 Safepoint
      │  ← 这里有延迟！线程可能正在执行：
      │     - 长循环（需要等到循环回边检查点）
      │     - Native 代码（需要等到返回 Java）
      │     - I/O 阻塞（需要等到 I/O 返回）
      │
      ▼
  遍历所有线程的栈
      │
      ▼
  释放 Safepoint
```

**问题**：JFR/jstack 看到的栈帧，是线程**到达 Safepoint 后**的状态，而不是**采样时刻**的状态。

**async-profiler 的差异**：

```
async-profiler 采样流程:
  perf_event overflow → SIGPROF
      │
      ▼
  目标线程: 立即中断，无论在做什么
      │  ← 即时！不需要等待任何检查点
      │     - 正在循环中 → 看到循环内的帧
      │     - 正在 Native 代码中 → 看到 Native 帧
      │     - 正在 I/O 中 → 看到系统调用帧
      │
      ▼
  AsyncGetCallTrace → 直接读取当前线程的栈
      │
      ▼
  返回，线程继续执行
```

### 2.2 Safepoint 偏差的具体影响

```
真实代码执行分布:              JFR 看到的分布:
━━━━━━━━━━━━━━━━━            ━━━━━━━━━━━━━━━━━
hotLoop()    70%              hotLoop()    30%   ← 被低估！
helper()     20%              helper()     50%   ← 被高估！
setup()      10%              setup()      20%   ← 被高估！

原因: hotLoop() 是紧密循环，Safepoint 检查点少，
      线程往往在离开 hotLoop() 之后才到达 Safepoint，
      此时 JFR 看到的是 helper() 或 setup() 的栈帧。
```

**经典案例**：`counted loop`（已知迭代次数的循环）在 C2 编译后**不插入 Safepoint 检查**（JDK 11）。这意味着 JFR 永远看不到线程在该循环内的状态。

### 2.3 async-profiler 如何避免偏差？

| 技术 | 说明 |
|------|------|
| **信号中断** | SIGPROF 可以中断任何指令（包括 counted loop 内部） |
| **AsyncGetCallTrace** | 不需要线程在 Safepoint，直接读取栈帧 |
| **Per-thread perf_event** | 每个线程独立的硬件计数器，精确度高 |
| **无 STW** | 不暂停其他线程，不影响应用行为 |

---

## 三、采样原理深度对比

### 3.1 async-profiler 的 CPU 采样

```
                    Linux Kernel
                   ┌─────────────┐
                   │ perf_event  │
                   │ subsystem   │
                   │             │
Thread A ──────────┤ fd_A ───────├──→ overflow → SIGPROF → Thread A 的信号处理器
Thread B ──────────┤ fd_B ───────├──→ overflow → SIGPROF → Thread B 的信号处理器
Thread C ──────────┤ fd_C ───────├──→ overflow → SIGPROF → Thread C 的信号处理器
                   └─────────────┘

每个线程独立的 perf_event fd
→ 信号直接投递到目标线程
→ 无需全局同步
→ 无 Safepoint
```

### 3.2 JDK JFR 的 CPU 采样

```
                    JVM 内部
                   ┌──────────────────┐
                   │ JfrThreadSampler │ ← 独立的采样线程
                   │                  │
                   │ 定时触发          │
                   │      │           │
                   │      ▼           │
                   │ VMThread:        │
                   │  request_safepoint│
                   │      │           │
                   │      ▼           │
Thread A ──────────┤ 到达 safepoint   │
Thread B ──────────┤ 到达 safepoint   │← 所有线程暂停
Thread C ──────────┤ 到达 safepoint   │
                   │      │           │
                   │      ▼           │
                   │ 遍历每个线程的栈  │
                   │      │           │
                   │      ▼           │
                   │ 释放 safepoint   │
                   └──────────────────┘

全局 STW → 采样所有线程
→ 线程必须在安全点才能被采样
→ Safepoint 偏差不可避免
```

**注意**：JDK 17+ 引入了 `JfrThreadSampling` 的改进，不再需要全局 STW，而是使用 `AsyncGetCallTrace` 或 Thread-local handshake。但 JDK 11 仍然使用 Safepoint 采样。

### 3.3 jstack 的采样

```
外部进程 (jstack)
     │
     ├── Attach API → UNIX socket → JVM
     │
     ▼
JVM 内部:
     ├── VMThread: request_safepoint (STW)
     ├── 遍历所有线程
     │   └── print_stack_trace()
     ├── 释放 safepoint
     └── 返回文本结果

→ 完全的 STW
→ 开销极大（毫秒级）
→ 不适合频繁采样
```

---

## 四、事件类型对比

| 事件 | async-profiler | JDK JFR | jstack |
|------|---------------|---------|--------|
| **CPU 采样** | ✅ perf_event / ctimer / itimer | ✅ JfrThreadSampler | ❌ |
| **Wall Clock** | ✅ WallClock timerLoop | ❌ (需 JFR streaming) | ❌ |
| **内存分配** | ✅ AllocTracer (Trap) / ObjectSampler (JVMTI) | ✅ jdk.ObjectAllocationInNewTLAB | ❌ |
| **锁争用** | ✅ LockTracer (JVMTI + JNI hook) | ✅ jdk.JavaMonitorEnter | ❌ |
| **原生锁** | ✅ NativeLockTracer (GOT patch) | ❌ | ❌ |
| **原生内存** | ✅ MallocTracer (GOT patch) | ❌ (NMT 不同) | ❌ |
| **方法追踪** | ✅ Instrument (字节码插桩) | ✅ (需手动配置) | ❌ |
| **GC 活动** | ✅ (通过 JVMTI GC 回调) | ✅ (40+ 种 GC 事件) | ❌ |
| **I/O** | ❌ (可通过 Wall+Native 间接看) | ✅ jdk.FileRead/Write | ❌ |
| **线程状态** | ✅ WallClock 的 isSyscall | ✅ jdk.ThreadSleep 等 | ✅ (线程状态) |
| **内核函数** | ✅ (/proc/kallsyms) | ❌ | ❌ |

---

## 五、Native 帧支持对比

这是 async-profiler 最大的优势：

```
async-profiler 看到的栈:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[kernel] __schedule_[k]
[kernel] schedule_[k]
[libc] __nanosleep
[libjvm] os::sleep
[libjvm] JVM_Sleep
java.lang.Thread.sleep                    ← Java 帧
com.example.MyApp.processRequest          ← Java 帧
com.example.MyApp.main                    ← Java 帧

JFR / jstack 看到的栈:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
java.lang.Thread.sleep                    ← Java 帧
com.example.MyApp.processRequest          ← Java 帧
com.example.MyApp.main                    ← Java 帧

→ JFR/jstack 丢失了全部 Native 帧！
→ 无法区分是 sleep 还是 I/O 导致的阻塞
→ 无法看到 JVM 内部函数（如 os::sleep, JVM_Sleep）
```

**为什么 JFR 没有 Native 帧？** JFR 使用 JVM 内部的 `vframeStream` 遍历 Java 帧，它不知道如何解析 Native C/C++ 帧。async-profiler 使用 walkFP/walkDwarf/walkVM 解析 Native 帧，再用 ASGCT/walkVM 解析 Java 帧，最终混合输出。

---

## 六、开销对比

### 6.1 CPU 采样开销

| 工具 | 采样开销/次 | 10ms 间隔开销率 | 对应用的影响 |
|------|-----------|---------------|-------------|
| async-profiler | ~5-20μs | ~0.05-0.2% | 几乎无感 |
| JDK JFR (JDK 11) | ~100-500μs (STW) | ~1-5% | 可感知的停顿 |
| JDK JFR (JDK 17+) | ~10-50μs | ~0.1-0.5% | 接近无感 |
| jstack | ~10-50ms (STW) | N/A (手动) | 明显停顿 |

### 6.2 内存开销

| 工具 | 常驻内存 | 增长模式 |
|------|---------|---------|
| async-profiler | ~16MB (LinearAllocator 2 chunks) | 按需增长 |
| JDK JFR | ~10MB (per-thread buffer) | 固定 |
| jstack | ~0 (仅临时) | 无 |

---

## 七、何时选择哪个工具

### 7.1 async-profiler 最佳场景

1. **CPU 热点分析**：需要精确到函数级别，无 Safepoint 偏差
2. **Native 代码瓶颈**：需要看 libc/libjvm/内核函数
3. **锁争用分析**：支持 Java 锁 + 原生锁
4. **内存泄漏定位**：malloc/free 追踪
5. **火焰图生成**：直接输出交互式 HTML

### 7.2 JDK JFR 最佳场景

1. **生产环境持续监控**：低开销，内置支持
2. **GC 详细分析**：40+ 种 GC 事件
3. **I/O 瓶颈分析**：FileRead/Write/SocketRead 等
4. **线程生命周期**：ThreadStart/End/Sleep/Park
5. **已有 JMC 工具链**：JDK Mission Control 原生支持

### 7.3 jstack 最佳场景

1. **快速诊断死锁**：一次性 dump 所有线程状态
2. **线程状态概览**：快速看所有线程在干什么
3. **无需安装 Agent**：紧急情况下的最低成本诊断

---

## 八、架构差异图

```
async-profiler 架构:
┌──────────────────────────────────────────────────────┐
│                    用户空间                           │
│  ┌──────────┐   ┌──────────┐   ┌─────────────────┐  │
│  │JVMTI     │   │信号处理器│   │输出层            │  │
│  │Agent     │──→│(per-thread)──→│JFR/HTML/Text    │  │
│  │(vmEntry) │   │recordSample│  │(stop时生成)     │  │
│  └──────────┘   └──────────┘   └─────────────────┘  │
│       ↑              ↑                               │
│       │              │ SIGPROF                        │
├───────│──────────────│───────────────────────────────┤
│       │         ┌────┴─────┐      内核空间            │
│       │         │perf_event│                          │
│       └─────────│subsystem │                          │
│                 └──────────┘                          │
└──────────────────────────────────────────────────────┘

JDK JFR 架构:
┌──────────────────────────────────────────────────────┐
│                    JVM 内部                            │
│  ┌──────────┐   ┌──────────┐   ┌─────────────────┐  │
│  │JfrThread │   │Safepoint │   │JfrChunkWriter   │  │
│  │Sampler   │──→│(全局STW) │──→│(持续写入)       │  │
│  │(定时线程)│   │遍历所有栈│   │.jfr 文件        │  │
│  └──────────┘   └──────────┘   └─────────────────┘  │
│                                                      │
│  → 所有操作在 JVM 内部完成，不需要外部 Agent           │
│  → 但受 Safepoint 约束                                │
└──────────────────────────────────────────────────────┘

jstack 架构:
┌────────────┐        ┌──────────────────────────────┐
│ jstack     │ Attach │        JVM 内部               │
│ (外部进程) │───────→│  VMThread: request_safepoint  │
│            │  API   │  全线程 STW → dump → 释放     │
│            │←───────│  返回文本                      │
└────────────┘        └──────────────────────────────┘
```

---

## 九、三者的 "AsyncGetCallTrace" 关系

```
AsyncGetCallTrace (ASGCT) 是一个非标准的 JVM 内部 API:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

来源: Sun/Oracle 为 Forte Developer (后来的 Sun Studio) 开发
位置: hotspot/share/prims/forte.cpp
特点: 
  1. 不需要 Safepoint —— 可以在信号处理器中安全调用
  2. 通过 dlsym("AsyncGetCallTrace") 动态发现
  3. 不是 JVMTI 标准 API —— 但几乎所有 HotSpot 实现都支持

使用情况:
  ┌─────────────────┐   ┌──────────┐   ┌────────────┐
  │ async-profiler   │   │ JDK JFR  │   │ jstack     │
  │                 │   │ (≥17)    │   │            │
  │ ✅ 核心依赖     │   │ ✅ 可选   │   │ ❌ 不使用   │
  │ (信号处理器中)   │   │ (优化)   │   │ (用 vframe)│
  └─────────────────┘   └──────────┘   └────────────┘
```

---

## 十、async-profiler + JFR 联合使用

async-profiler 支持 `jfrsync` 模式，与 JDK 内置 JFR 联合录制：

```
asprof start --jfrsync default -f /tmp/profile.jfr <pid>

效果:
  JDK JFR: 录制 I/O 事件、GC 事件、线程生命周期事件（JFR 擅长的）
  async-profiler: 录制 CPU 采样、内存分配、锁争用（async-profiler 擅长的）
  
  → 两者的事件写入同一个 .jfr 文件
  → 用 JMC 打开可以看到所有事件
  → 最佳实践！
```

---

*创建日期: 2026-02-10*
