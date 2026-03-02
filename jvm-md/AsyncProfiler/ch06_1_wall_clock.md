# 6.1 WallClock — 全线程采样引擎

> 源文件: `wallClock.cpp` (269行), `wallClock.h` (63行)
> 关联: `os_linux.cpp` (LinuxThreadList/threadCpuTime/sendSignalToThread), `event.h` (WallClockEvent/ExecutionEvent)
> 前置章节: 3.1 Engine 体系, 4.1-4.2 PerfEvents 信号驱动, 5.1 recordSample

---

## 核心问题

**PerfEvents（`event=cpu`）只能采样正在占用 CPU 的线程。如果线程在 sleep/wait/IO 中阻塞，它永远不会被采到。如何看到被阻塞线程的栈？**

答案：WallClock 引擎不依赖 `perf_event_open`，而是创建一个**独立的 timer 线程**，主动遍历进程中所有线程，用 `tgkill` 向每个线程发送信号来中断采样——无论线程是运行还是睡眠。这就是 `--event wall` 模式。

---

## 一、WallClock 在整体架构中的位置

### 1.1 两种 CPU 采样方式的本质差异

```
┌────────────────────────────────────┐
│ PerfEvents (event=cpu)              │
│                                    │
│  perf_event_open(每个线程一个 fd)   │
│      ↓                             │
│  硬件 PMU 溢出 → 内核发 SIGPROF    │
│      ↓                             │
│  只有正在运行的线程能收到信号       │  ← 看不到阻塞线程！
│      ↓                             │
│  signalHandler → recordSample      │
└────────────────────────────────────┘

┌────────────────────────────────────┐
│ WallClock (event=wall)             │
│                                    │
│  timer 线程循环遍历所有线程         │
│      ↓                             │
│  tgkill(tid, SIGVTALRM) 逐个发信号 │
│      ↓                             │
│  所有线程（运行+阻塞）都能收到     │  ← 全覆盖！
│      ↓                             │
│  signalHandler → recordSample      │
└────────────────────────────────────┘
```

### 1.2 使用场景

| 场景 | 用什么 | 为什么 |
|------|--------|--------|
| CPU 密集型瓶颈 | `event=cpu` | 只关心消耗 CPU 的帧 |
| I/O 等待分析 | `event=wall` | 需要看到 sleep/read/write 中的帧 |
| 锁等待分析 | `event=wall` | 需要看到 `Object.wait`、`LockSupport.park` |
| 全景分析 | `event=wall` | 同时看到运行和阻塞的线程 |

---

## 二、WallClock 类设计

### 2.1 继承关系

```
Engine (engine.h)
  ├── PerfEvents       — 基于 perf_event_open
  ├── CTimer           — 基于 timer_create
  ├── ITimer           — 基于 setitimer
  └── WallClock        — 基于 timer 线程 + tgkill  ← 本节
```

### 2.2 关键成员

```cpp
class WallClock : public Engine {
  private:
    enum Mode {
        CPU_ONLY,       // 只采样运行中的线程（event=cpu 的 fallback）
        WALL_BATCH,     // 默认 Wall 模式：空闲线程批量合并
        WALL_LEGACY     // 旧版 Wall 模式：每个采样都发信号
    };

    static long _interval;     // 采样间隔（纳秒）
    static int _signal;        // 使用的信号号
    static Mode _mode;         // 运行模式

    volatile bool _running;    // 控制 timerLoop 退出
    pthread_t _thread;         // timer 线程句柄
};
```

### 2.3 三种模式的选择逻辑

```cpp
Error WallClock::start(Arguments& args) {
    if (args._wall >= 0 || strcmp(args._event, EVENT_WALL) == 0) {
        _mode = args._nobatch ? WALL_LEGACY : WALL_BATCH;  // wall 事件
    } else {
        _mode = CPU_ONLY;  // cpu 事件但 PerfEvents 不可用时的 fallback
    }
}
```

| 条件 | 模式 | 信号 | 典型场景 |
|------|------|------|---------|
| `event=wall` | **WALL_BATCH** | SIGVTALRM (26) | 默认 Wall 模式 |
| `event=wall,nobatch` | WALL_LEGACY | SIGVTALRM (26) | 兼容旧行为 |
| `event=cpu` + 无 perf | CPU_ONLY | SIGVTALRM (26) | 容器/Docker |

### GDB 验证

```
=== WallClock::start (event=wall) ===
mode     = 1 (WALL_BATCH)       ✅ 默认批处理模式
interval = 50,000,000 ns (50ms) ✅ DEFAULT_INTERVAL * 5
signal   = 26 (SIGVTALRM)       ✅ getProfilingSignal(1) 返回
_enabled = 1                    ✅ 事件已启用
_running = 1                    ✅ timer 线程已启动
```

---

## 三、采样间隔设计

### 3.1 默认间隔

```cpp
_interval = args._wall >= 0 ? args._wall : args._interval;
if (_interval == 0) {
    _interval = _mode == CPU_ONLY ? DEFAULT_INTERVAL       // 10ms
                                  : DEFAULT_INTERVAL * 5;  // 50ms
}
```

**为什么 Wall 模式间隔是 CPU 的 5 倍？**

| 维度 | CPU 模式 | Wall 模式 |
|------|---------|----------|
| 采样目标 | 只采运行中的线程 | 采所有线程 |
| 每次采样线程数 | 1（内核定向投递） | 最多 8 个（THREADS_PER_TICK） |
| 每秒信号总量 | 100/线程 × ~3 活跃线程 = ~300 | 100/周期 × ~16 线程 = ~1600 |
| 开销来源 | 栈回溯 | 栈回溯 + `/proc/self/task` 遍历 + `threadCpuTime` 系统调用 |

所以 Wall 模式默认 50ms 间隔以控制开销。

### 3.2 关键常量

```cpp
const int THREADS_PER_TICK = 8;           // 每个 tick 最多向 8 个线程发信号
const long long MIN_INTERVAL = 100000;     // 100μs — tick 间最小休眠
const u64 RUNNABLE_THRESHOLD_NS = 10000;   // 10μs — 空闲判断阈值
const u32 MAX_IDLE_BATCH = 1000;           // 最多合并 1000 次空闲采样
```

---

## 四、信号选择 — 为什么是 SIGVTALRM？

### 4.1 双信号方案

```cpp
_signal = args._signal == 0 ? OS::getProfilingSignal(1)    // Wall 用 mode=1
                             : ((args._signal >> 8) > 0 ? args._signal >> 8 : args._signal);
```

```cpp
// os_linux.cpp
int OS::getProfilingSignal(int mode) {
    static int preferred_signals[2] = {SIGPROF, SIGVTALRM};
    // mode=0 → 从 SIGPROF 开始查找（PerfEvents 用）
    // mode=1 → 从 SIGVTALRM 开始查找（WallClock 用）
    // ...
}
```

**设计意图**：PerfEvents 和 WallClock 可能同时运行（`event=cpu,wall`），它们需要使用**不同的信号**避免冲突：
- PerfEvents → **SIGPROF** (27)
- WallClock → **SIGVTALRM** (26)

### 4.2 信号发送方式

```cpp
// os_linux.cpp
bool OS::sendSignalToThread(int thread_id, int signo) {
    return syscall(__NR_tgkill, processId(), thread_id, signo) == 0;
}
```

**`tgkill`**（Thread Group Kill）是 Linux 特有的系统调用，可以向进程中的**指定线程**发送信号。与 `kill()` 不同，`tgkill` 精确定向，不会被内核随机分派到其他线程。

**注意**：这里直接用 `syscall()` 裸系统调用而非 `pthread_kill()`，因为：
1. `pthread_kill()` 需要 `pthread_t`，但我们只有 `tid`
2. `tgkill` 是 Linux 内核提供的最精确的线程级信号投递接口

---

## 五、timerLoop — 核心循环

### 5.1 启动

```cpp
Error WallClock::start(Arguments& args) {
    // ... 配置 mode, interval, signal ...
    OS::installSignalHandler(_signal, signalHandler);
    _running = true;
    pthread_create(&_thread, NULL, threadEntry, this);  // 创建 timer 线程
}
```

timer 线程是一个普通 pthread，与 JVM 线程完全独立。

### 5.2 线程遍历

```cpp
void WallClock::timerLoop() {
    int self = OS::threadId();                          // timer 线程自己的 TID
    ThreadList* thread_list = OS::listThreads();        // 读取 /proc/self/task/
    // ...

    while (_running) {
        for (int signaled_threads = 0;
             signaled_threads < THREADS_PER_TICK && thread_list->hasNext(); ) {
            int thread_id = thread_list->next();

            // 跳过自己和无效 ID
            if (thread_id == self || thread_id <= 0) continue;

            // ThreadFilter 过滤
            if (thread_filter_enabled && !thread_filter->accept(thread_id)) continue;

            // 根据模式决定是否发信号
            // ... (下节详述)

            if (enabled && OS::sendSignalToThread(thread_id, _signal)) {
                signaled_threads++;
            }
        }
        // ... sleep ...
    }
}
```

### 5.3 LinuxThreadList — /proc/self/task/ 遍历

```cpp
class LinuxThreadList : public ThreadList {
    DIR* _dir;           // /proc/self/task/ 的 DIR 句柄
    int* _thread_array;  // 线程 ID 数组

    void fillThreadArray() {
        rewinddir(_dir);
        struct dirent* entry;
        while ((entry = readdir(_dir)) != NULL) {
            if (entry->d_name[0] != '.') {
                addThread(atoi(entry->d_name));  // "12345" → 12345
            }
        }
    }
};
```

**设计细节**：
1. **构造时**：打开 `/proc/self/task/` 目录，读取所有 TID 到数组
2. **每个周期末**：调用 `update()` 重新读取（线程可能创建/销毁）
3. **遍历方式**：数组随机访问，避免每次 `readdir` 的系统调用开销

### GDB 验证

```
=== timerLoop 入口 ===
self (timer线程 ID)  = 165377
thread_filter_enabled = 0        ← 没有线程过滤
mode                 = 1         ← WALL_BATCH
thread_count         = 16        ← 进程中 16 个线程
THREADS_PER_TICK     = 8         ← 每 tick 采 8 个
→ 16 个线程需要 2 个 tick 完成一个周期
```

---

## 六、三种模式的分派逻辑

### 6.1 CPU_ONLY 模式 — 只采运行线程

```cpp
if (mode == CPU_ONLY) {
    if (!enabled || OS::threadState(thread_id) == THREAD_SLEEPING) {
        continue;  // 跳过睡眠线程
    }
}
```

`OS::threadState()` 的实现：

```cpp
// os_linux.cpp
ThreadState OS::threadState(int thread_id) {
    char buf[512];
    snprintf(buf, sizeof(buf), "/proc/self/task/%d/stat", thread_id);
    int fd = open(buf, O_RDONLY);
    // 读取 /proc/self/task/<tid>/stat
    // 格式: "pid (name) S ..."
    //                   ^ 状态字符
    ThreadState state = THREAD_UNKNOWN;
    if (read(fd, buf, sizeof(buf)) > 0) {
        char* s = strchr(buf, ')');
        state = s != NULL && (s[2] == 'R' || s[2] == 'D')
              ? THREAD_RUNNING : THREAD_SLEEPING;
    }
    close(fd);
    return state;
}
```

**状态映射**：
| `/proc/stat` 字符 | 含义 | 映射 |
|-------------------|------|------|
| `R` | Running（运行/就绪） | THREAD_RUNNING |
| `D` | Disk sleep（不可中断 I/O） | THREAD_RUNNING |
| `S` | Sleeping（可中断睡眠） | THREAD_SLEEPING |
| `T` | Stopped（被 SIGSTOP） | THREAD_SLEEPING |
| 其他 | — | THREAD_SLEEPING |

**注意**：`D` 状态也被视为 RUNNING，因为 disk I/O 是消耗资源的操作，值得采样。

### 6.2 WALL_BATCH 模式 — 空闲线程批量合并（核心创新！）

```cpp
else if (mode == WALL_BATCH) {
    ThreadSleepState& tss = thread_sleep_state[thread_id];
    u64 new_thread_cpu_time = enabled ? OS::threadCpuTime(thread_id) : 0;

    // 判断是否空闲：CPU 时间增量 ≤ 10μs
    if (new_thread_cpu_time != 0 &&
        new_thread_cpu_time - tss.last_cpu_time <= RUNNABLE_THRESHOLD_NS) {
        // 线程空闲！累加计数器，不发信号
        tss.last_time = TSC::ticks();
        if (++tss.counter < MAX_IDLE_BATCH) {
            if (tss.counter == 1) {
                tss.start_time = tss.last_time;
            }
            continue;  // ← 跳过信号发送！
        }
    }

    // 如果之前有积累的空闲采样，批量提交
    if (tss.counter != 0) {
        recordWallClock(tss, THREAD_SLEEPING, thread_id);
        tss.counter = 0;
    }
}
```

#### 6.2.1 设计动机

**问题**：一个典型 Java 应用有 50~200 个线程，但大部分时间只有 3~5 个线程在运行。如果每次采样都向所有线程发信号：
- 50 个 sleeping 线程 × 20 次/秒 = **1000 次/秒** 的无用信号
- 每次信号 = 1 次上下文切换 + 1 次栈回溯 → 显著开销

**解决**：如果线程的 CPU 时间没有增长（即没有执行任何代码），就认为它"还在同一个位置"——不需要再发信号重新采样，而是把**计数器累加**。等到线程恢复运行或达到上限时，再一次性提交所有累积的采样。

#### 6.2.2 threadCpuTime — 每线程 CPU 时间

```cpp
// os_linux.cpp
u64 OS::threadCpuTime(int thread_id) {
    clockid_t thread_cpu_clock;
    if (thread_id) {
        // 通过 TID 构造 per-thread clockid
        thread_cpu_clock = ((~(unsigned int)(thread_id)) << 3) | 6;
        // CPUCLOCK_SCHED | CPUCLOCK_PERTHREAD_MASK
    } else {
        thread_cpu_clock = CLOCK_THREAD_CPUTIME_ID;  // 当前线程
    }

    struct timespec ts;
    if (clock_gettime(thread_cpu_clock, &ts) == 0) {
        return (u64)ts.tv_sec * 1000000000 + ts.tv_nsec;
    }
    return 0;
}
```

**关键技巧**：Linux 的 `clock_gettime` 支持 per-thread CPU clock，可以通过 TID 构造 clock_id。公式：
```
clock_id = (~tid << 3) | 6
         = (~tid << 3) | CPUCLOCK_SCHED | CPUCLOCK_PERTHREAD_MASK
```

这是 Linux 内核的内部约定（`include/uapi/linux/time.h`），不是 POSIX 标准。

#### 6.2.3 GDB 验证 WALL_BATCH 的空闲判断

```
=== WALL_BATCH 空闲检查 ===
tid            = 167420
new_cpu_time   = 7,660,615 ns (7.66ms)
last_cpu_time  = 0 ns (初始值)
delta          = 7,660,615 ns
THRESHOLD      = 10,000 ns (10μs)

delta (7.66ms) >> threshold (10μs) → 线程不是空闲 → 发信号采样
```

#### 6.2.4 ThreadSleepState 状态机

```
struct ThreadSleepState {
    u64 start_time;      // 空闲开始的 TSC 时间
    u64 last_time;       // 最近一次检查的 TSC 时间
    u64 last_cpu_time;   // 上次记录的 CPU 时间
    u32 call_trace_id;   // 空闲时的栈 ID（由信号处理器填入）
    u32 counter;         // 连续空闲采样计数
};
```

状态转换：

```
初始: counter=0, last_cpu_time=0
  │
  │ 发信号采样（线程运行中或首次）
  │ signalHandler 中 _thread_cpu_time_buf.add(trace)
  │ → drain() 更新 last_cpu_time 和 call_trace_id
  │
  ▼
检测空闲: delta ≤ 10μs
  │ counter++, 不发信号
  │ counter=1 时记录 start_time
  ▼
持续空闲: counter < 1000
  │ counter++
  ▼
达到上限: counter == 1000 或 线程恢复运行(delta > 10μs)
  │ recordWallClock(tss, SLEEPING, tid) — 批量提交
  │ counter=0
  ▼
回到初始
```

#### 6.2.5 批量提交

```cpp
void WallClock::recordWallClock(const ThreadSleepState& tss, ThreadState state, int tid) {
    WallClockEvent event;
    event._start_time = tss.start_time;
    event._time_span = tss.last_time - tss.start_time;  // 空闲持续时间
    event._thread_state = state;
    event._samples = tss.counter;                        // 合并的采样数

    Profiler::instance()->recordExternalSamples(
        tss.counter,               // 采样数
        tss.counter * _interval,   // 等效时间 = 次数 × 间隔
        tid,
        tss.call_trace_id,         // 空闲时的栈 ID
        WALL_CLOCK_SAMPLE,
        &event
    );
}
```

**效果**：一个线程 sleep 了 10 秒，间隔 50ms，本来需要 200 次信号+栈回溯。WALL_BATCH 只需要：
- 第 1 次：发信号，回溯栈，记录 call_trace_id
- 后续 199 次：检查 CPU 时间（无信号，无栈回溯），counter 累加
- 线程恢复时：一次 recordWallClock 提交 200 个采样

**开销降低：200 次栈回溯 → 1 次栈回溯 + 199 次 `clock_gettime`**

### 6.3 WALL_LEGACY 模式 — 每次都发信号

```cpp
// WALL_LEGACY: 没有 CPU_ONLY 和 WALL_BATCH 的特殊处理
// 直接走到 sendSignalToThread
```

没有任何条件判断，对每个线程都发信号。这是 v4.0 之前的行为，通过 `--nobatch` 选项可以恢复。

---

## 七、signalHandler — 信号处理器

### 7.1 信号到达目标线程

```cpp
static void signalHandler(int signo, siginfo_t* siginfo, void* ucontext) {
    if (_mode == WALL_BATCH) {
        WallClockEvent event;
        event._start_time = TSC::ticks();
        event._time_span = 0;                              // 单次采样无时间跨度
        event._thread_state = getThreadState(ucontext);    // 从寄存器判断线程状态
        event._samples = 1;                                // 单次采样

        u64 trace = Profiler::instance()->recordSample(
            ucontext, _interval, WALL_CLOCK_SAMPLE, &event);

        // 如果线程在 sleeping 且采样成功，记录 CPU 时间
        if (event._thread_state == THREAD_SLEEPING && trace != 0) {
            _thread_cpu_time_buf.add(trace);
        }
    } else {
        // WALL_LEGACY 或 CPU_ONLY
        ExecutionEvent event(TSC::ticks());
        event._thread_state = _mode == CPU_ONLY ? THREAD_UNKNOWN : getThreadState(ucontext);
        Profiler::instance()->recordSample(ucontext, _interval, EXECUTION_SAMPLE, &event);
    }
}
```

### GDB 验证

```
=== signalHandler 首次触发 ===
signo    = 26 (SIGVTALRM) ✅
mode     = 1 (WALL_BATCH) ✅
Total invocations: 167 次（GDB 断点开销下）
```

### 7.2 getThreadState — 从 ucontext 判断线程状态

**这是 WallClock 最精妙的设计之一**。信号处理器在**目标线程**的上下文中运行，可以直接检查寄存器来判断线程中断前在做什么。

```cpp
ThreadState WallClock::getThreadState(void* ucontext) {
    StackFrame frame(ucontext);
    uintptr_t pc = frame.pc();

    // 检查 1: PC 指向 syscall 指令
    if (StackFrame::isSyscall((instruction_t*)pc)) {
        return THREAD_SLEEPING;
    }

    // 检查 2: PC 指向 syscall 后一条指令，且 errno == EINTR
    uintptr_t prev_pc = pc - SYSCALL_SIZE;
    if ((pc & 0xfff) >= SYSCALL_SIZE ||
        Profiler::instance()->findLibraryByAddress((instruction_t*)prev_pc) != NULL) {
        if (StackFrame::isSyscall((instruction_t*)prev_pc) && frame.checkInterruptedSyscall()) {
            return THREAD_SLEEPING;
        }
    }

    return THREAD_RUNNING;
}
```

#### 7.2.1 isSyscall — x86_64 指令检测

```cpp
// stackFrame_x64.cpp
bool StackFrame::isSyscall(instruction_t* pc) {
    return pc[0] == 0x0f && pc[1] == 0x05;  // syscall 指令 = 0F 05
}
```

**原理**：x86_64 的 `syscall` 指令只有 2 字节（`0x0F 0x05`）。如果信号中断时 PC 正好指向这条指令，说明线程正在执行系统调用（如 `nanosleep`、`futex`、`epoll_wait`）——即线程在 sleeping。

#### 7.2.2 checkInterruptedSyscall — 系统调用被中断

```cpp
bool StackFrame::checkInterruptedSyscall() {
    if (retval() == (uintptr_t)-EINTR) {
        // 系统调用被信号中断，返回 EINTR
        // 检查是否需要手动重启 poll/ppoll/epoll_wait
        uintptr_t pc = this->pc();
        if ((pc & 0xfff) >= 7 && *(instruction_t*)(pc - 7) == 0xb8) {
            int nr = *(int*)(pc - 6);
            if (nr == SYS_ppoll
                || (nr == SYS_poll && (int)REG(RDX, rdx) == -1)
                || (nr == SYS_epoll_wait && (int)REG(R10, r10) == -1)
                || (nr == SYS_epoll_pwait && (int)REG(R10, r10) == -1)) {
                this->pc() = pc - 7;  // 重启 syscall！
            }
        }
        return true;
    }
    return false;
}
```

**两种情况**：
1. **PC 在 `syscall` 指令上**：信号在系统调用执行期间到达（内核尚未返回）
2. **PC 在 `syscall` 后一条指令**：系统调用刚被信号中断并返回 `EINTR`

**重启 poll/ppoll 的 workaround**：这是 [JDK-8237858](https://bugs.openjdk.org/browse/JDK-8237858) 的补丁。Java NIO 的 `poll(timeout=-1)` 被信号中断后返回 `EINTR`，但 JVM 没有重试循环——导致 `Selector.select()` 提前返回。async-profiler 通过**修改 ucontext 的 PC**，让线程从 `mov eax, SYS_poll` 重新执行，手动重启系统调用。

---

## 八、ThreadCpuTimeBuffer — MPSC 环形缓冲区

### 8.1 问题

WALL_BATCH 中，signalHandler 需要告诉 timerLoop "这个线程的栈 ID 是什么"——但 signalHandler 在目标线程上下文中运行，timerLoop 在 timer 线程中运行。这是一个典型的**多生产者-单消费者（MPSC）**通信问题。

### 8.2 设计

```cpp
class ThreadCpuTimeBuffer {
    enum { RINGBUF_SIZE = 256, PAD_SIZE = 128 };

    char _pad0[PAD_SIZE];           // 防止 false sharing
    volatile u32 _write_ptr;        // 多生产者原子递增
    char _pad1[PAD_SIZE - 4];       // 填充
    u32 _read_ptr;                  // 单消费者独占
    char _pad2[PAD_SIZE - 4];       // 填充
    ThreadCpuTime _ringbuf[256];    // 环形缓冲区
};
```

### 8.3 生产者（signalHandler 中的多个线程）

```cpp
void add(u64 trace) {
    // trace 高 32 位 = thread_id, 低 32 位 = call_trace_id
    ThreadCpuTime& t = _ringbuf[atomicInc(_write_ptr) & (RINGBUF_SIZE - 1)];
    t.trace = trace;
    storeRelease(t.cpu_time, OS::threadCpuTime(0));  // 当前线程的 CPU 时间
}
```

**关键**：`atomicInc(_write_ptr)` 是原子操作，保证多个线程（多个 signalHandler 实例同时运行）不会写到同一个 slot。`storeRelease` 保证 `cpu_time` 的写入对消费者可见。

### 8.4 消费者（timerLoop 中的单线程）

```cpp
void drain(ThreadSleepMap& thread_sleep_state) {
    u64 read_limit = _read_ptr + RINGBUF_SIZE;
    do {
        ThreadCpuTime& t = _ringbuf[_read_ptr & (RINGBUF_SIZE - 1)];
        u64 cpu_time = loadAcquire(t.cpu_time);
        if (cpu_time == 0) break;  // 空槽，停止

        u64 trace = t.trace;
        if (__sync_bool_compare_and_swap(&t.cpu_time, cpu_time, 0)) {
            // 成功消费，更新 ThreadSleepState
            int thread_id = trace >> 32;
            ThreadSleepState& tss = thread_sleep_state[thread_id];
            tss.last_cpu_time = cpu_time;
            tss.call_trace_id = (u32)trace;
            tss.counter = 0;          // 重置空闲计数
            _read_ptr++;
        }
    } while (_read_ptr < read_limit);
}
```

### 8.5 False Sharing 防护

```
内存布局:
┌──────────────────┐
│ _pad0 [128 bytes]│  ← 隔离前方数据
├──────────────────┤
│ _write_ptr (4B)  │  ← 多线程写（cache line 独占）
│ _pad1 [124 bytes]│
├──────────────────┤
│ _read_ptr (4B)   │  ← 单线程读（不同 cache line）
│ _pad2 [124 bytes]│
├──────────────────┤
│ _ringbuf[256]    │  ← 数据区
└──────────────────┘
```

128 字节的 padding 确保 `_write_ptr` 和 `_read_ptr` 在不同的 cache line 上（x86_64 cache line = 64B），避免多线程并发时的 false sharing。

---

## 九、时间调度 — 均匀分散信号

### 9.1 问题

如果一次性向 16 个线程发信号，它们会**同时进入** signalHandler，导致 `recordSample()` 中的自旋锁争用。

### 9.2 解决：分 tick + 按比例 sleep

```cpp
while (_running) {
    // 内层循环: 每 tick 最多处理 THREADS_PER_TICK=8 个线程
    for (...) { ... sendSignalToThread ... }

    if (thread_list->hasNext()) {
        // 还有线程没处理完，计算中间休眠
        long long sleep_time = cycle_start_time
            + (u64)_interval * thread_list->index() / thread_list->count()
            - current_time;
        OS::uninterruptibleSleep(sleep_time < MIN_INTERVAL ? MIN_INTERVAL : sleep_time, &_running);
    } else {
        // 一个周期结束，开始下一周期
        cycle_start_time += (u64)_interval;
        long long sleep_time = cycle_start_time - current_time;
        OS::uninterruptibleSleep(sleep_time, &_running);
        thread_list->update();  // 重新读取线程列表
    }

    // 每轮结束后 drain MPSC buffer
    _thread_cpu_time_buf.drain(thread_sleep_state);
}
```

### 9.3 计算示例

```
16 个线程, interval = 50ms, THREADS_PER_TICK = 8

周期 1:
  tick 1: 发信号给 thread[0..7]
          sleep_time = 50ms * 8/16 - elapsed = ~25ms
  tick 2: 发信号给 thread[8..15]
          周期结束, sleep_time = 50ms - elapsed ≈ 25ms
          thread_list->update() 重新读取

周期 2: (同上)
```

**效果**：16 个线程的信号被均匀分散在 50ms 内的两个批次中，而不是一次性全发。

### 9.4 大量线程场景

```
100 个线程, interval = 50ms

tick 数 = ceil(100/8) = 13 个 tick
每 tick sleep = 50ms / 13 ≈ 3.85ms (> MIN_INTERVAL=0.1ms ✓)

→ 每 3.85ms 向 8 个线程发信号
→ 50ms 内完成所有 100 个线程
→ 开销被均匀分散
```

---

## 十、stop — 优雅停止

```cpp
void WallClock::stop() {
    _running = false;
    pthread_kill(_thread, WAKEUP_SIGNAL);  // SIGIO，唤醒 sleep 中的 timer 线程
    pthread_join(_thread, NULL);           // 等待 timer 线程结束
}
```

timerLoop 退出前会 flush 所有剩余的 WALL_BATCH 数据：

```cpp
// timerLoop 退出后
for (auto it = thread_sleep_state.begin(); it != thread_sleep_state.end(); ++it) {
    const ThreadSleepState& tss = it->second;
    if (tss.counter != 0) {
        recordWallClock(tss, THREAD_SLEEPING, it->first);
    }
}
```

---

## 十一、WallClock 完整架构图

```
                                  WallClock Engine
                                       │
                      ┌────────────────┤
                      ▼                ▼
               start()             stop()
               │                    │
               ├─ 选择 Mode         ├─ _running = false
               ├─ 设置 interval     ├─ SIGIO 唤醒 timer
               ├─ 安装 signalHandler└─ pthread_join
               └─ pthread_create
                      │
                      ▼
              ┌──── timerLoop() ────────────────────────────────────┐
              │                                                     │
              │  while(_running):                                   │
              │    ┌──────────────────────────────────────┐         │
              │    │ for each thread (≤8/tick):           │         │
              │    │   ├── skip self, invalid, filtered   │         │
              │    │   │                                  │         │
              │    │   ├── CPU_ONLY:                      │         │
              │    │   │   └── skip if SLEEPING           │         │
              │    │   │                                  │         │
              │    │   ├── WALL_BATCH:                    │         │
              │    │   │   ├── threadCpuTime(tid)         │         │
              │    │   │   ├── delta ≤ 10μs? → idle++     │         │
              │    │   │   └── else → flush batch         │         │
              │    │   │                                  │         │
              │    │   └── tgkill(tid, SIGVTALRM)        │         │
              │    └──────────────────────────────────────┘         │
              │                     │                               │
              │    sleep (按比例分散)                                │
              │                     │                               │
              │    drain MPSC buffer → 更新 ThreadSleepState        │
              │                                                     │
              └─────────────────────────────────────────────────────┘
                                                │
                                    tgkill →    │
                                                ▼
              ┌──── signalHandler (目标线程上下文) ─────────────────┐
              │                                                     │
              │  getThreadState(ucontext):                          │
              │    PC 在 syscall(0F 05) 上?  → SLEEPING             │
              │    PC 在 syscall 后且 EINTR? → SLEEPING             │
              │    其他                      → RUNNING               │
              │                                                     │
              │  WALL_BATCH:                                        │
              │    recordSample(ucontext) → 栈回溯 → trace_id       │
              │    if SLEEPING:                                     │
              │      _thread_cpu_time_buf.add(trace)                │
              │      → timerLoop drain → 更新 last_cpu_time        │
              │                                                     │
              │  WALL_LEGACY / CPU_ONLY:                            │
              │    recordSample(ucontext) → 直接记录                │
              │                                                     │
              └─────────────────────────────────────────────────────┘
```

---

## 十二、WallClock vs PerfEvents — 终极对比

| 维度 | PerfEvents (cpu) | WallClock (wall) |
|------|------------------|------------------|
| **采样驱动** | 硬件 PMU 溢出 → 内核 | timer 线程 + tgkill |
| **信号** | SIGPROF (27) | SIGVTALRM (26) |
| **采样目标** | 只有运行线程 | 所有线程（运行+阻塞） |
| **线程状态** | 无（都在运行） | 精确区分 RUNNING/SLEEPING |
| **默认间隔** | 10ms | 50ms |
| **每线程 fd** | ✅ 每个线程一个 perf fd | ❌ 不需要 fd |
| **空闲优化** | N/A（不采空闲） | WALL_BATCH 批量合并 |
| **信号分散** | 内核自动调度 | timer 线程手动均匀分散 |
| **系统调用重启** | N/A | ✅ poll/ppoll 重启 workaround |
| **线程发现** | perf_event_open 时绑定 | /proc/self/task/ 动态遍历 |
| **新线程处理** | 需要 ThreadStart 回调 | 下个周期 update() 自动发现 |
| **容器兼容** | 需要 `perf_event_open` 权限 | 只需 tgkill 权限 |
| **开销来源** | 栈回溯 | 栈回溯 + /proc 遍历 + clock_gettime |

---

## 十三、面试级知识点

### Q1: WallClock 为什么不直接用 `setitimer`？

**A**: `setitimer` 的 `ITIMER_REAL` 信号（SIGALRM）只会发给进程，内核随机选一个线程投递——无法控制采样哪个线程。而 WallClock 需要**逐个遍历所有线程**，用 `tgkill` 精确投递。

### Q2: WALL_BATCH 如何保证空闲线程的栈是准确的？

**A**: 空闲判断依据是"CPU 时间没有增长"——如果 CPU 时间没变，线程必然还在同一个系统调用中阻塞，栈帧不会改变。所以复用之前采样的 `call_trace_id` 是安全的。

### Q3: 为什么 RUNNABLE_THRESHOLD 是 10μs 而不是 0？

**A**: `clock_gettime` 本身有精度限制（几百纳秒到几微秒），加上线程调度抖动，严格的 `delta == 0` 会产生误判。10μs 是一个保守的阈值——如果一个线程在两次采样间（~50ms）只消耗了 10μs 的 CPU，它实际上就是"空闲"的。

### Q4: ThreadCpuTimeBuffer 为什么不用 mutex？

**A**: signalHandler 在信号上下文中运行，**不能使用任何锁**（死锁风险：目标线程可能持有 mutex，信号处理器再 lock 同一个 mutex → 死锁）。所以用无锁 MPSC ring buffer + 原子操作。

### Q5: checkInterruptedSyscall 为什么要手动重启 poll？

**A**: 这是 JDK-8237858 的 workaround。Java NIO 的 `Selector.select()` 底层调用 `poll(timeout=-1)`。当信号中断 poll 时，内核返回 `EINTR`，但 JVM 没有重试——导致 `select()` 提前返回 0。async-profiler 通过修改 ucontext 的 PC 到 `mov eax, SYS_poll` 指令处，让线程重新执行系统调用。

---

## 十四、总结

### WallClock 的核心设计

1. **独立 timer 线程**：不依赖任何硬件或内核采样机制，纯用户态实现
2. **tgkill 精确投递**：向指定 TID 发信号，信号处理器在目标线程上下文中运行
3. **三种模式**：CPU_ONLY（跳过睡眠）、WALL_BATCH（空闲批量合并）、WALL_LEGACY（兼容旧行为）
4. **指令级状态判断**：检查 PC 是否指向 `syscall` 指令（`0x0F 0x05`），从寄存器判断线程状态
5. **MPSC 环形缓冲区**：信号处理器→timer线程的无锁通信，128B padding 防 false sharing
6. **信号均匀分散**：THREADS_PER_TICK=8 + 按比例 sleep，避免锁争用
7. **系统调用重启**：修改 ucontext PC，workaround JDK-8237858

### GDB 验证关键数据

| 验证项 | 实际值 | 含义 |
|--------|--------|------|
| mode | **1 (WALL_BATCH)** | 默认批处理模式 |
| interval | **50,000,000 ns (50ms)** | DEFAULT_INTERVAL × 5 |
| signal | **26 (SIGVTALRM)** | 与 SIGPROF 不冲突 |
| thread_count | **16** | 进程中 16 个线程 |
| THREADS_PER_TICK | **8** | 每 tick 最多 8 个信号 |
| ticks/cycle | **2** | 16/8 = 2 个 tick |
| signalHandler 次数 | **167**（GDB 下） | 正常运行约几千次 |
| threadCpuTime delta | **7.66ms** | 远超 10μs → 不是空闲 |

### Part 6 在整体架构中的位置

```
Agent 加载（Ch01）
  → VMStructs 初始化（Ch02）
  → Engine 体系（Ch03）
  → PerfEvents 采样（Ch04）    ← event=cpu 的主路径
  → 栈回溯（Ch05）
  → WallClock 采样（本节）      ← event=wall 的主路径
    ├── timerLoop 线程遍历
    ├── tgkill 信号投递
    ├── signalHandler → recordSample（复用 Ch05 的栈回溯）
    └── WALL_BATCH 空闲批处理
```

---

*创建日期: 2026-02-09*
*GDB 验证环境: OpenJDK 11 slowdebug + async-profiler v4.0*
*标准条件: -Xms8g -Xmx8g -XX:+UseG1GC -Xint --event wall*
