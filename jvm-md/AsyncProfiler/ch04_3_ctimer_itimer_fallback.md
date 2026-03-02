# 4.3 CTimer / ITimer — CPU 引擎的降级方案

> 源文件: `ctimer_linux.cpp` (128行), `itimer.cpp` (49行), `cpuEngine.cpp/h` (133行/53行)
> 关联: `profiler.cpp::selectEngine()` — 引擎选择, `os_linux.cpp::overrun()` — 信号溢出补偿
> 前置章节: 4.1 perf_event_open 配置

## 核心问题

**当 perf_events 不可用时（容器、seccomp、perf_event_paranoid≥3），async-profiler 怎么做 CPU 采样？**

答案：**三级降级**——PerfEvents → CTimer → ITimer（最终兜底到 WallClock）。每种方案用不同的内核 API 实现"每隔 N 纳秒 CPU 时间发一个信号"，精度逐级递减。

---

## 一、三级降级选择逻辑

### 1.1 selectEngine 的决策树

```cpp
Engine* Profiler::selectEngine(const char* event_name) {
    if (strcmp(event_name, "cpu") == 0) {
        if (FdTransferClient::hasPeer() || PerfEvents::supported()) {
            return &perf_events;        // 第一级：perf_events
        } else if (CTimer::supported()) {
            return &ctimer;             // 第二级：timer_create
        } else {
            return &wall_clock;         // 最终兜底：WallClock（挂钟时间）
        }
    } else if (strcmp(event_name, "itimer") == 0) {
        return &itimer;                 // 显式指定 itimer
    } else if (strcmp(event_name, "ctimer") == 0) {
        return &ctimer;                 // 显式指定 ctimer
    }
    ...
}
```

### GDB 验证 — 自动选择过程

```
PerfEvents::supported() = 1   ← 尝试创建 dummy perf_event 成功
→ selectEngine("cpu") 返回 &perf_events
```

**`PerfEvents::supported()` 做了什么？**

```cpp
bool PerfEvents::supported() {
    struct perf_event_attr attr = {0};
    attr.type = PERF_TYPE_SOFTWARE;
    attr.config = PERF_COUNT_SW_CPU_CLOCK;
    attr.sample_period = 1000000000;       // 1秒（足够大，不会真的采样）
    attr.sample_type = PERF_SAMPLE_CALLCHAIN;
    attr.disabled = 1;

    int fd = syscall(__NR_perf_event_open, &attr, 0, -1, -1, 0);
    if (fd == -1) return false;            // 不可用
    close(fd);
    return true;                           // 可用
}
```

它创建一个 **dummy perf_event**（disabled=1，永远不会触发），只是测试系统调用是否成功。失败原因可能是：
- `perf_event_paranoid >= 3`
- seccomp 禁止了 `perf_event_open`
- 没有 `CAP_PERFMON` / `CAP_SYS_ADMIN`

### 1.2 流程图

```
用户指定 -e cpu
  │
  ├── PerfEvents::supported()? ──Yes──→ PerfEvents（最佳）
  │   ├── 创建 dummy perf_event 测试
  │   └── 需要内核允许 perf_event_open
  │
  No
  │
  ├── CTimer::supported()? ──Yes──→ CTimer（次优）
  │   └── Linux 上永远返回 true
  │
  No（非 Linux 平台）
  │
  └── WallClock（兜底）
       └── 挂钟时间，不是 CPU 时间
```

**注意**：ITimer 不在自动降级链中！必须显式 `-e itimer` 才使用。原因是 ITimer 有公平性问题。

---

## 二、CTimer — timer_create 方案

### 2.1 核心 API

CTimer 使用 POSIX `timer_create()` API（通过原始系统调用绕过 libc 限制）：

```cpp
// 每个线程的 CPU 时钟
static inline clockid_t thread_cpu_clock(unsigned int tid) {
    return ((~tid) << 3) | 6;  // CPUCLOCK_SCHED | CPUCLOCK_PERTHREAD_MASK
}
```

### 2.2 clockid 编码详解

```
thread_cpu_clock(tid) = ((~tid) << 3) | 6

低3位 = 6 = 0b110:
  ├── bit 2 (CPUCLOCK_PERTHREAD_MASK=4): 这是线程级时钟（不是进程级）
  ├── bit 1 (CPUCLOCK_SCHED=2):          使用调度器时钟（CLOCK_THREAD_CPUTIME_ID）
  └── bit 0 = 0:                          实际 CPU 运行时间（不含等待时间）

高29位 = ~tid:
  └── 线程 ID 的位反码（Linux 内核的 make_thread_cpuclock() 编码方式）
```

### GDB 验证 — clockid 交叉验证

```
tid = 91062:
  thread_cpu_clock(91062) = ((~91062) << 3) | 6
                           = (-91063) << 3 | 6
                           = -728498
                           = 4294238798 (unsigned 32-bit)

GDB 输出: clockid = 4294238798  ✅ 完全匹配
```

**为什么用原始系统调用而不是 libc 的 timer_create？**

因为 libc 只允许预定义的 clockid（`CLOCK_REALTIME`、`CLOCK_MONOTONIC` 等），不支持这种 per-thread CPU 时钟的编码。必须用 `syscall(__NR_timer_create, ...)` 绕过 libc。

### 2.3 createForThread 完整流程

```
CTimer::createForThread(tid)
  │
  ├── 1. 构造 sigevent
  │     ├── sigev_notify = SIGEV_THREAD_ID (4)   ← 信号发给指定线程
  │     ├── sigev_signo = 27 (SIGPROF)           ← 和 PerfEvents 用同一个信号
  │     └── (&sigev_notify)[1] = tid             ← hack：直接写 _tid 字段
  │
  ├── 2. timer_create(thread_cpu_clock(tid), &sev, &timer)
  │     └── 返回 timer_id（内核分配）
  │
  ├── 3. CAS 防重复
  │     __sync_bool_compare_and_swap(&_timers[tid], 0, timer + 1)
  │     ├── 成功 → 继续
  │     └── 失败 → timer_delete + return -1
  │
  └── 4. timer_settime(timer, 0, {interval, interval}, NULL)
        ├── it_value = 10ms     ← 首次触发时间
        └── it_interval = 10ms  ← 周期间隔
```

### GDB 验证 — timer_create 系统调用

```
=== CTimer::createForThread tid=91062 ===
=== timer_create syscall ===
clockid      = 4294238798   ← thread_cpu_clock(91062)
sigev_signo  = 27           ← SIGPROF
sigev_notify = 4            ← SIGEV_THREAD_ID（信号发给指定线程）

=== CTimer::createForThread tid=91066 ===
clockid      = 4294238766   ← thread_cpu_clock(91066)，不同线程不同 clockid
sigev_signo  = 27
sigev_notify = 4
```

### 2.4 _timers 数组 — timer_id 到 TID 的映射

```cpp
int* _timers;        // calloc(pid_max, sizeof(int))
int _max_timers;     // = pid_max

// _timers[tid] 的状态:
// 0          → 未创建
// timer + 1  → 已创建（+1 是因为 timer_id 可能为 0）
```

**为什么 `timer + 1`？** 内核分配的 timer_id 从 0 开始，但 `_timers[tid] = 0` 表示"空槽位"。加 1 避免歧义。对应地，`destroyForThread` 中先减 1：

```cpp
void CTimer::destroyForThread(int tid) {
    int timer = _timers[tid];
    if (timer != 0 && __sync_bool_compare_and_swap(&_timers[tid], timer--, 0)) {
        syscall(__NR_timer_delete, timer);  // timer 已经减了 1
    }
}
```

### 2.5 overrun 补偿机制

CTimer 设置 `_count_overrun = true`，信号处理器中的公式：

```cpp
u64 total_cpu_time = _count_overrun
    ? u64(_interval) * (1 + OS::overrun(siginfo))   // CTimer: 补偿丢失的采样
    : u64(_interval);                                 // PerfEvents/ITimer: 不补偿
```

**什么是 overrun？**

当定时器到期但信号还没处理完（比如上一个信号处理器还在执行），新的到期事件会排队。`si_overrun` 记录了"信号排队期间又到期了几次"。

```
时间线:
  T    T+10ms  T+20ms  T+30ms  T+40ms
  |______|______|______|______|
  ↑ 信号到达           ↑ 信号处理器终于执行
  si_overrun = 2（T+20ms 和 T+30ms 到期了但没处理）
  total_cpu_time = 10ms * (1 + 2) = 30ms
```

### GDB 验证

```
=== CpuEngine::signalHandler ===
_count_overrun = 1       ← CTimer 开启了 overrun 补偿
overrun = 0              ← 当前无丢失（低负载）
→ total_cpu_time = 10,000,000 * (1 + 0) = 10,000,000 ns = 10ms
```

### 2.6 为什么 PerfEvents 不需要 overrun？

因为 PerfEvents 使用 **REFRESH 模式**：溢出后自动禁用，不可能有 overrun。而 CTimer 是**周期定时器**（`it_interval`），不会自动停止。

---

## 三、ITimer — setitimer 方案

### 3.1 核心 API

```cpp
Error ITimer::start(Arguments& args) {
    _interval = args._interval ? args._interval : DEFAULT_INTERVAL;  // 10ms
    _cstack = args._cstack;
    _signal = SIGPROF;             // 固定为 SIGPROF
    _count_overrun = false;        // 不补偿 overrun

    OS::installSignalHandler(SIGPROF, signalHandler);

    time_t sec = _interval / 1000000000;          // 0
    suseconds_t usec = (_interval % 1000000000) / 1000;  // 10000
    struct itimerval tv = {{sec, usec}, {sec, usec}};

    setitimer(ITIMER_PROF, &tv, NULL);   // 进程级 CPU 计时器
}
```

### 3.2 ITimer 的根本限制

```
                     setitimer(ITIMER_PROF)
                            │
                            ▼
                  ┌────────────────────┐
                  │  整个进程一个定时器  │
                  │  10ms CPU 时间后    │
                  │  发 SIGPROF 给进程  │
                  └────────────────────┘
                            │
                   内核选择一个线程
                   （不一定公平）
                            │
              ┌─────────┬───┴────┬─────────┐
              ▼         ▼        ▼         ▼
           Thread1   Thread2  Thread3   Thread4
```

**关键问题**：
1. **整个进程只有一个定时器**：所有线程共享 10ms 配额
2. **信号分发不公平**：内核把信号发给"当前正在运行的线程"，可能偏向某些线程
3. **精度受限于 jiffy**：10ms 或 4ms（取决于 HZ=100 或 250）

### GDB 验证 — setitimer 参数

```
=== ITimer::start ===
args._interval = 0 → 使用默认 10,000,000 ns

=== setitimer ===
which = 2 (ITIMER_PROF)
it_value.tv_sec     = 0,  it_value.tv_usec     = 10000  ← 首次 10ms 后触发
it_interval.tv_sec  = 0,  it_interval.tv_usec  = 10000  ← 周期 10ms

=== signalHandler ===
signo          = 27 (SIGPROF)
_count_overrun = 0              ← ITimer 不补偿 overrun
_interval      = 10,000,000 ns
```

### 3.3 stop — 清零定时器

```cpp
void ITimer::stop() {
    struct itimerval tv = {{0, 0}, {0, 0}};  // 全零 = 停止
    setitimer(ITIMER_PROF, &tv, NULL);
}
```

简单到极致：把定时器设为零即停止。

---

## 四、三种引擎的深度对比

### 4.1 配置差异

| 特性 | PerfEvents | CTimer | ITimer |
|------|-----------|--------|--------|
| **内核 API** | `perf_event_open()` | `timer_create()` | `setitimer()` |
| **粒度** | 每线程 | 每线程 | 进程级 |
| **计时器** | 硬件 PMU 或内核 hrtimer | 内核 hrtimer（受 HZ 限制）| 内核 scheduler 时钟 |
| **精度** | 纳秒级 | jiffy（4~10ms） | jiffy（4~10ms） |
| **信号递送** | F_SETOWN_EX(fd, tid) | SIGEV_THREAD_ID(tid) | 内核选择 |
| **内核栈** | ✅ ring buffer | ❌ 无 | ❌ 无 |
| **overrun 补偿** | ❌ 不需要（REFRESH 模式）| ✅ si_overrun | ❌ 不补偿 |
| **fd 消耗** | 每线程 1 个 | 无 fd | 无 fd |
| **容器兼容** | 需要 CAP/paranoid | ✅ 开箱即用 | ✅ 开箱即用 |
| **平台支持** | Linux only | Linux only | Linux + macOS |

### 4.2 信号处理器的差异

三种引擎共用 **同一个** `CpuEngine::signalHandler`：

```cpp
void CpuEngine::signalHandler(int signo, siginfo_t* siginfo, void* ucontext) {
    if (!_enabled) return;

    ExecutionEvent event(TSC::ticks());
    u64 total_cpu_time = _count_overrun
        ? u64(_interval) * (1 + OS::overrun(siginfo))  // CTimer
        : u64(_interval);                               // PerfEvents、ITimer
    Profiler::instance()->recordSample(ucontext, total_cpu_time, EXECUTION_SAMPLE, &event);
}
```

**唯一差异**：`_count_overrun` 标志。CTimer=true，PerfEvents/ITimer=false。

**PerfEvents 用自己的 signalHandler**，不走这里（它需要额外处理 ring buffer 和 ioctl REFRESH）。

### 4.3 为什么 ITimer 不补偿 overrun？

因为 ITimer 是**进程级**定时器，overrun 的含义不同：
- CTimer 的 overrun：某个**线程**的信号处理器执行太慢，该线程的定时器多次到期
- ITimer 的 overrun：进程的定时器多次到期，但信号可能发给了**不同的线程**

ITimer 无法知道"这个信号本应发给谁"，所以 overrun 补偿没有意义。

### 4.4 为什么 ITimer 不在自动降级链中？

```cpp
// selectEngine 的逻辑:
if (PerfEvents::supported()) → PerfEvents
else if (CTimer::supported()) → CTimer
else → WallClock

// ITimer 必须显式指定:
else if (strcmp(event_name, "itimer") == 0) → ITimer
```

原因：CTimer 在所有方面都优于 ITimer（per-thread、信号精确递送），唯一的例外是 macOS（CTimer 不支持 macOS）。所以在 Linux 上自动降级跳过 ITimer，直接到 CTimer。

---

## 五、CpuEngine — 共同的基础设施

### 5.1 pthread_setspecific_hook

三种引擎共用同一套线程感知 Hook（详见 3.1 节），核心逻辑：

```cpp
static int pthread_setspecific_hook(pthread_key_t key, const void* value) {
    if (key != VMThread::key()) {
        return pthread_setspecific(key, value);  // 不是 VMThread TLS → 透传
    }

    if (value != NULL) {
        // 新线程启动：先设 TLS，再通知引擎
        int result = pthread_setspecific(key, value);
        CpuEngine::onThreadStart();     // → current->createForThread(tid)
        return result;
    } else {
        // 线程结束：先通知引擎，再清 TLS
        CpuEngine::onThreadEnd();       // → current->destroyForThread(tid)
        return pthread_setspecific(key, value);
    }
}
```

**设计细节**：启动时 **先 set 再 notify**（确保引擎看到 TLS 已就绪），结束时 **先 notify 再 clear**（确保引擎在 TLS 清除前完成清理）。

### 5.2 createForAllThreads

```cpp
int CpuEngine::createForAllThreads() {
    ThreadList* thread_list = OS::listThreads();  // 遍历 /proc/self/task/
    while (thread_list->hasNext()) {
        int tid = thread_list->next();
        int err = createForThread(tid);
        if (isResourceLimit(err)) {
            result = err;
            break;              // 资源不足立即停止
        }
    }
    delete thread_list;
    return result;
}
```

三种引擎的 `createForThread` 是虚函数，各自实现：
- PerfEvents → `perf_event_open()` + `mmap()` + `fcntl()`
- CTimer → `timer_create()` + `timer_settime()`
- ITimer → 无（进程级，不需要 per-thread 资源）

---

## 六、总结

### 降级全景图

```
用户: -e cpu
  │
  ├── PerfEvents::supported()? ──→ 创建 dummy perf_event 测试
  │   │
  │   ├── Yes → PerfEvents
  │   │   ├── per-thread fd + mmap ring buffer
  │   │   ├── 纳秒级精度
  │   │   ├── 支持内核栈
  │   │   └── REFRESH 一次性模式
  │   │
  │   └── No → CTimer::supported()? (Linux 上永远 true)
  │       │
  │       ├── Yes → CTimer
  │       │   ├── per-thread timer_create
  │       │   ├── jiffy 精度（4~10ms）
  │       │   ├── 无内核栈
  │       │   ├── overrun 补偿
  │       │   └── 不消耗 fd
  │       │
  │       └── No → WallClock（兜底）
  │
  ├── 用户: -e itimer → ITimer
  │   ├── 进程级 setitimer
  │   ├── 信号分发不公平
  │   ├── 无 overrun 补偿
  │   └── 跨平台（macOS 支持）
  │
  └── 用户: -e ctimer → CTimer（强制）
```

### 核心设计精髓

1. **透明降级**：用户只说 `-e cpu`，async-profiler 自动选择最佳方案，用户无感知
2. **共享信号处理器**：CTimer 和 ITimer 共用 `CpuEngine::signalHandler`，通过 `_count_overrun` 开关区分行为
3. **per-thread 设计贯穿始终**：PerfEvents 和 CTimer 都为每个线程创建独立资源，保证信号精确发给被采样线程
4. **clockid 编码黑科技**：CTimer 用 `((~tid) << 3) | 6` 直接构造 per-thread CPU 时钟 ID，绕过 libc 限制
5. **启动/结束顺序严格**：`set TLS → notify engine`（启动）、`notify engine → clear TLS`（结束），避免竞态

### 在整体架构中的位置

```
Agent 加载（Ch01）
  → VMStructs 初始化（Ch02）
  → Engine 体系 + selectEngine（Ch03）
  → perf_event_open 配置 + 信号驱动（Ch04.1-4.2）
  → CTimer/ITimer 降级方案（本节）              ← 你在这里
  → 信号到达 → recordSample（Ch05）
```

---

*创建日期: 2026-02-09*
*GDB 验证环境: OpenJDK 11 slowdebug + async-profiler v4.0*
