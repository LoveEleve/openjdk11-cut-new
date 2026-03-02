# Lesson 7: WallClock 深度逐行解析（方法内联展开）

> 本文档对 WallClock 的每一行代码进行深度解析，所有被调用的方法都展开到最底层实现。

---

## 1. WallClock 核心概念

### 1.1 Wall Clock vs CPU 采样

| 特性 | CPU 采样 | Wall Clock 采样 |
|-----|---------|----------------|
| **采样对象** | 只有运行态线程 | 所有线程（运行+阻塞） |
| **触发方式** | perf_event 硬件中断 | 定时器线程发送信号 |
| **线程选择** | 被中断的线程 | 遍历所有线程 |
| **适用场景** | CPU 热点分析 | 整体性能分析（含阻塞） |
| **开销** | 较低 | 较高（需要遍历线程） |

### 1.2 三种模式

```cpp
enum Mode {
    CPU_ONLY,      // 只采样运行态线程
    WALL_BATCH,    // Wall Clock 批量模式（优化阻塞线程）
    WALL_LEGACY    // Wall Clock 传统模式
};
```

---

## 2. 源码逐行解析（深度优先展开）

### 2.1 常量定义

```cpp
// 文件: wallClock.cpp 第 15-30 行

const int THREADS_PER_TICK = 8;
```

**解析**：每次循环最多采样 8 个线程。

**为什么限制？**
- 避免一次性发送太多信号导致开销过高
- 减少对 `Profiler::recordSample()` 中自旋锁的竞争

---

```cpp
const long long MIN_INTERVAL = 100000;
```

**解析**：最小采样间隔 100,000 纳秒 = 100 微秒。

**为什么有最小间隔？**
- 间隔太小会导致采样开销过高
- 100us 是实际可用的下限

---

```cpp
const u64 RUNNABLE_THRESHOLD_NS = 10000;
```

**解析**：判断线程是否"可运行"的阈值 = 10 微秒 CPU 时间。

**用途**：
- 线程被采样为"阻塞"后，如果后续 CPU 时间增量 > 10us
- 说明线程已经唤醒，不再是纯粹的阻塞状态

---

```cpp
const u32 MAX_IDLE_BATCH = 1000;
```

**解析**：单次 WallClock 事件最多合并 1000 个阻塞样本。

---

### 2.2 数据结构

```cpp
struct ThreadSleepState {
    u64 start_time;      // 开始阻塞的时间
    u64 last_time;       // 最后一次采样的时间
    u64 last_cpu_time;   // 最后一次 CPU 时间
    u32 call_trace_id;   // 调用栈 ID
    u32 counter;         // 阻塞样本计数
};
```

**内存布局**：

```
ThreadSleepState (40 bytes):
┌────────────────────────────────────────────────────┐
│ u64 start_time      (offset 0,  8 bytes)          │
│ u64 last_time       (offset 8,  8 bytes)          │
│ u64 last_cpu_time   (offset 16, 8 bytes)          │
│ u32 call_trace_id   (offset 24, 4 bytes)          │
│ u32 counter         (offset 28, 4 bytes)          │
│ [padding]           (offset 32, 8 bytes)          │
└────────────────────────────────────────────────────┘
```

---

```cpp
struct ThreadCpuTime {
    u64 cpu_time;        // CPU 时间
    u64 trace;           // (tid << 32) | call_trace_id
};
```

---

### 2.3 ThreadCpuTimeBuffer（MPSC 环形缓冲区）

```cpp
// 文件: wallClock.cpp 第 48-99 行

class ThreadCpuTimeBuffer {
  private:
    enum {
        RINGBUF_SIZE = 256,   // 环形缓冲区大小
        PAD_SIZE = 128        // 缓存行填充大小
    };

    char _pad0[PAD_SIZE];  // protection against false sharing
    volatile u32 _write_ptr;
    char _pad1[PAD_SIZE - sizeof(u32)];
    u32 _read_ptr;
    char _pad2[PAD_SIZE - sizeof(u32)];
    ThreadCpuTime _ringbuf[RINGBUF_SIZE];
```

**内存布局（防止伪共享）**：

```
┌─────────────────────────────────────────────────────────────┐
│ _pad0 (128 bytes)                                           │
│ 防止 _write_ptr 与其他变量在同一个缓存行                     │
├─────────────────────────────────────────────────────────────┤
│ volatile u32 _write_ptr                                     │
│ 写指针（生产者线程更新）                                      │
├─────────────────────────────────────────────────────────────┤
│ _pad1 (124 bytes)                                           │
│ 防止 _write_ptr 和 _read_ptr 在同一个缓存行                  │
├─────────────────────────────────────────────────────────────┤
│ u32 _read_ptr                                               │
│ 读指针（消费者线程更新）                                      │
├─────────────────────────────────────────────────────────────┤
│ _pad2 (124 bytes)                                           │
├─────────────────────────────────────────────────────────────┤
│ ThreadCpuTime _ringbuf[256]                                 │
│ 实际数据区                                                   │
└─────────────────────────────────────────────────────────────┘
```

**伪共享（False Sharing）问题**：

```
CPU 缓存行大小：64 bytes

如果没有填充：
┌─────────────────────────────────────────────────┐
│ _write_ptr (4B) | _read_ptr (4B) | ...          │
│     ↑                 ↑                         │
│   Core 0          Core 1                         │
│   写 _write_ptr   读 _read_ptr                   │
│                                                  │
│ 问题：两个核心写同一个缓存行的不同位置           │
│       导致缓存行反复失效，性能下降               │
└─────────────────────────────────────────────────┘

有填充后：
┌─────────────────────────────────────────────────┐
│ _pad0 (128B)                                    │
│ 缓存行 0-1                                      │
├─────────────────────────────────────────────────┤
│ _write_ptr (4B)                                 │
│ 缓存行 2                                        │
│ Core 0 独占                                      │
├─────────────────────────────────────────────────┤
│ _pad1 (124B)                                    │
├─────────────────────────────────────────────────┤
│ _read_ptr (4B)                                  │
│ 缓存行 4                                        │
│ Core 1 独占                                      │
└─────────────────────────────────────────────────┘
```

---

```cpp
  public:
    ThreadCpuTimeBuffer() : _ringbuf(), _write_ptr(0), _read_ptr(0) {
    }

    void reset() {
        memset(_ringbuf, 0, sizeof(_ringbuf));
        _read_ptr = 0;
        __atomic_store_n(&_write_ptr, 0, __ATOMIC_RELEASE);
    }
```

**展开 __atomic_store_n**：

```cpp
// GCC 内置原子操作
void __atomic_store_n(volatile u32* ptr, u32 value, int memorder);

// 编译为 x86_64 汇编：
//   mov [ptr], value
//   mfence  ; __ATOMIC_RELEASE 需要内存屏障
```

---

```cpp
    void add(u64 trace) {
        ThreadCpuTime& t = _ringbuf[atomicInc(_write_ptr) & (RINGBUF_SIZE - 1)];
        t.trace = trace;
        storeRelease(t.cpu_time, OS::threadCpuTime(0));
    }
```

**展开 atomicInc(_write_ptr)**：

```cpp
// 文件: arch.h 第 30-32 行
static inline u64 atomicInc(volatile u64& var, u64 increment = 1) {
    return __sync_fetch_and_add(&var, increment);
}
```

**展开 __sync_fetch_and_add**：

```cpp
// GCC 内置函数，编译为 x86_64 指令：
//   lock xadd [ptr], increment
// 返回旧值

// 示例：
// _write_ptr = 0
// atomicInc(_write_ptr) 返回 0，_write_ptr 变成 1
// 下一个线程调用返回 1，_write_ptr 变成 2
```

**索引计算**：

```
_write_ptr = 0, 返回 0, 索引 = 0 & 255 = 0
_write_ptr = 1, 返回 1, 索引 = 1 & 255 = 1
_write_ptr = 256, 返回 256, 索引 = 256 & 255 = 0  // 回绕
_write_ptr = 257, 返回 257, 索引 = 257 & 255 = 1
```

---

**展开 storeRelease**：

```cpp
// 文件: arch.h 第 46-48 行
static inline void storeRelease(u64& var, u64 value) {
    return __atomic_store_n(&var, value, __ATOMIC_RELEASE);
}
```

**展开 OS::threadCpuTime(0)**：

```cpp
// 文件: os_linux.cpp 第 224-237 行
u64 OS::threadCpuTime(int thread_id) {
    clockid_t thread_cpu_clock;
    if (thread_id) {
        // 为指定线程构造 clockid
        thread_cpu_clock = ((~(unsigned int)(thread_id)) << 3) | 6;
        //                    └─────────┬─────────┘       └─┬─┘
        //                           取反 tid           CPUCLOCK_SCHED | PERTHREAD_MASK
    } else {
        // thread_id = 0 表示当前线程
        thread_cpu_clock = CLOCK_THREAD_CPUTIME_ID;
    }

    struct timespec ts;
    if (clock_gettime(thread_cpu_clock, &ts) == 0) {
        return (u64)ts.tv_sec * 1000000000 + ts.tv_nsec;
    }
    return 0;
}
```

**clockid_t 构造原理**：

```c
// Linux 内核定义：
// clockid_t = (pid << 3) | CPUCLOCK_PERTHREAD_MASK | CPUCLOCK_WHICH

// CPUCLOCK_PERTHREAD_MASK = 4 (bit 2 = 1 表示线程)
// CPUCLOCK_SCHED = 2 (bit 1 = 1 表示调度时间)

// 对于线程 CPU 时间：
// clockid = (~tid << 3) | 6
//         = (~tid << 3) | (4 | 2)
//         = (~tid << 3) | CPUCLOCK_PERTHREAD_MASK | CPUCLOCK_SCHED

// 为什么用 ~tid？
// 正数 PID/TID 可能与常量冲突
// 取反后保证高位为 1，不会冲突
```

**clock_gettime 展开**：

```c
// glibc 包装
int clock_gettime(clockid_t clk_id, struct timespec *tp);

// 系统调用号：__NR_clock_gettime = 228 (x86_64)
// 返回：tp->tv_sec = 秒, tp->tv_nsec = 纳秒
```

---

```cpp
    void drain(ThreadSleepMap& thread_sleep_state) {
        u64 read_limit = _read_ptr + RINGBUF_SIZE;
        do {
            ThreadCpuTime& t = _ringbuf[_read_ptr & (RINGBUF_SIZE - 1)];
            u64 cpu_time = loadAcquire(t.cpu_time);
            if (cpu_time == 0) {
                break;  // 空槽位，退出
            }

            u64 trace = t.trace;
            if (__sync_bool_compare_and_swap(&t.cpu_time, cpu_time, 0)) {
                int thread_id = trace >> 32;
                ThreadSleepState& tss = thread_sleep_state[thread_id];
                tss.last_cpu_time = cpu_time;
                tss.call_trace_id = (u32)trace;
                tss.counter = 0;
                _read_ptr++;
            }
        } while (_read_ptr < read_limit);
    }
```

**展开 loadAcquire**：

```cpp
// 文件: arch.h 第 42-44 行
static inline u64 loadAcquire(u64& var) {
    return __atomic_load_n(&var, __ATOMIC_ACQUIRE);
}
```

**MPSC 模式**：

```
生产者（多个信号处理器线程）：
  add(trace):
    1. atomicInc(_write_ptr) 获取槽位索引
    2. 写入 trace
    3. storeRelease(cpu_time) 标记完成

消费者（定时器线程）：
  drain():
    1. loadAcquire(cpu_time) 检查是否有数据
    2. CAS(cpu_time, old, 0) 原子取走数据
    3. 如果 CAS 成功，处理数据
```

---

### 2.4 getThreadState()（判断线程状态）

```cpp
// 文件: wallClock.cpp 第 108-127 行

ThreadState WallClock::getThreadState(void* ucontext) {
    StackFrame frame(ucontext);
    uintptr_t pc = frame.pc();
```

**展开 StackFrame::pc()**（已在 Lesson 5 解析）：
- 返回 `_ucontext->uc_mcontext.gregs[REG_RIP]`

---

```cpp
    // Consider a thread sleeping, if it has been interrupted in the middle of syscall execution,
    // either when PC points to the syscall instruction, or if syscall has just returned with EINTR
    if (StackFrame::isSyscall((instruction_t*)pc)) {
        return THREAD_SLEEPING;
    }
```

**展开 StackFrame::isSyscall**：

```cpp
// 文件: stackFrame_x64.cpp 第 318-320 行
bool StackFrame::isSyscall(instruction_t* pc) {
    return pc[0] == 0x0f && pc[1] == 0x05;
}
```

**syscall 指令**：

```asm
; x86_64 syscall 指令
; 操作码：0x0F 0x05（2 字节）

syscall    ; 执行系统调用
; RAX = 系统调用号
; RDI, RSI, RDX, R10, R8, R9 = 参数
; 返回值在 RAX
```

**为什么 PC 指向 syscall 指令说明线程在阻塞？**

```
系统调用执行流程：
┌─────────────────────────────────────────────────┐
│ 用户态                                           │
│   ...                                           │
│   mov rax, SYS_read                             │
│   syscall  <-- PC 指向这里，说明刚进入内核        │
│   ...    <-- 如果在这里，说明已返回              │
└─────────────────────────────────────────────────┘
        │
        v
┌─────────────────────────────────────────────────┐
│ 内核态                                           │
│   系统调用处理                                   │
│   ...                                           │
│   如果是阻塞调用（read/recv/poll 等）            │
│   线程会被挂起等待                               │
│   ...                                           │
└─────────────────────────────────────────────────┘

当信号打断系统调用时：
1. 如果还在内核中等待：PC 指向 syscall 指令
2. 如果刚返回：PC 指向 syscall 后的指令
```

---

```cpp
    // Make sure the previous instruction address is readable
    uintptr_t prev_pc = pc - SYSCALL_SIZE;
    if ((pc & 0xfff) >= SYSCALL_SIZE || Profiler::instance()->findLibraryByAddress((instruction_t*)prev_pc) != NULL) {
        if (StackFrame::isSyscall((instruction_t*)prev_pc) && frame.checkInterruptedSyscall()) {
            return THREAD_SLEEPING;
        }
    }

    return THREAD_RUNNING;
}
```

**展开 SYSCALL_SIZE**：

```cpp
// 文件: arch.h 第 57 行
const int SYSCALL_SIZE = 2;  // syscall 指令 2 字节
```

**检查前一条指令**：

```
情况 1：PC 指向 syscall 后的指令
   prev_pc = pc - 2
   
   地址布局：
   0x1000: syscall (0x0f 0x05)
   0x1002: mov rbx, rax  <-- PC 指向这里
   
   检查 0x1000 处是否是 syscall 指令

情况 2：PC 指向 syscall 指令本身
   prev_pc = pc - 2 = syscall 前的指令
   这个检查会失败
```

**地址可读性检查**：

```cpp
(pc & 0xfff) >= SYSCALL_SIZE
// 检查 PC 是否在页边界附近
// 如果 pc & 0xfff >= 2，说明 prev_pc = pc - 2 还在同一页
// 否则可能跨页，需要检查是否可读
```

---

**展开 frame.checkInterruptedSyscall()**：

```cpp
// 文件: stackFrame_x64.cpp 第 284-316 行
bool StackFrame::checkInterruptedSyscall() {
    if (retval() == (uintptr_t)-EINTR) {
        // Workaround for JDK-8237858: restart the interrupted poll() manually.
        // Check if the previous instruction is mov eax, SYS_poll with infinite timeout or
        // mov eax, SYS_ppoll with any timeout (ppoll adjusts timeout automatically)
        uintptr_t pc = this->pc();
        if ((pc & 0xfff) >= 7 && *(instruction_t*)(pc - 7) == 0xb8) {
            int nr = *(int*)(pc - 6);
            if (nr == SYS_ppoll
                || (nr == SYS_poll && (int)REG(RDX, rdx) == -1)
                || (nr == SYS_epoll_wait && (int)REG(R10, r10) == -1)
                || (nr == SYS_epoll_pwait && (int)REG(R10, r10) == -1)) {
                this->pc() = pc - 7;  // 重启系统调用
            }
        }
        return true;
    }
    return false;
}
```

**判断系统调用是否被信号打断**：

```
返回值 = -EINTR 表示系统调用被信号打断

EINTR = 4 (Linux)

当阻塞的系统调用被信号打断时：
  - 返回 -EINTR
  - 用户需要手动重启系统调用
```

**JDK-8237858 Workaround**：

```
某些 JVM 版本的 poll() 实现有 bug：
  - poll() 被信号打断后没有自动重启
  - 导致性能问题

AsyncProfiler 的 workaround：
  - 检测被打断的 poll/ppoll/epoll_wait
  - 如果是无超时调用，修改 PC 重启系统调用
```

---

### 2.5 signalHandler()（信号处理函数）

```cpp
// 文件: wallClock.cpp 第 129-145 行

void WallClock::signalHandler(int signo, siginfo_t* siginfo, void* ucontext) {
    if (_mode == WALL_BATCH) {
        WallClockEvent event;
        event._start_time = TSC::ticks();
        event._time_span = 0;
        event._thread_state = getThreadState(ucontext);
        event._samples = 1;
        u64 trace = Profiler::instance()->recordSample(ucontext, _interval, WALL_CLOCK_SAMPLE, &event);
        if (event._thread_state == THREAD_SLEEPING && trace != 0) {
            _thread_cpu_time_buf.add(trace);
        }
    } else {
        ExecutionEvent event(TSC::ticks());
        event._thread_state = _mode == CPU_ONLY ? THREAD_UNKNOWN : getThreadState(ucontext);
        Profiler::instance()->recordSample(ucontext, _interval, EXECUTION_SAMPLE, &event);
    }
}
```

**WallClockEvent 结构**：

```cpp
// 文件: event.h 第 56-62 行
class WallClockEvent : public Event {
  public:
    u64 _start_time;      // 开始时间
    u64 _time_span;       // 时间跨度（用于批量合并）
    ThreadState _thread_state;  // 线程状态
    u32 _samples;         // 样本数量（批量合并时 > 1）
};
```

**WALL_BATCH 模式**：

```
1. 记录单次采样
2. 如果线程是阻塞状态（THREAD_SLEEPING）：
   - 将 trace 信息加入 _thread_cpu_time_buf
   - 后续可以获取 CPU 时间判断线程是否真的在阻塞
```

**CPU_ONLY 模式**：

```
1. 不区分线程状态（THREAD_UNKNOWN）
2. 简单记录 ExecutionEvent
```

---

### 2.6 timerLoop()（定时器主循环）

```cpp
// 文件: wallClock.cpp 第 188-269 行

void WallClock::timerLoop() {
    int self = OS::threadId();
    ThreadFilter* thread_filter = Profiler::instance()->threadFilter();
    bool thread_filter_enabled = thread_filter->enabled();
    Mode mode = _mode;

    ThreadSleepMap thread_sleep_state;
    ThreadList* thread_list = OS::listThreads();
    _thread_cpu_time_buf.reset();
    u64 cycle_start_time = OS::nanotime();
```

**展开 OS::threadId()**：

```cpp
// 文件: os_linux.cpp
int OS::threadId() {
    return syscall(SYS_gettid);
}
```

**展开 OS::listThreads()**：

```cpp
// 文件: os_linux.cpp 第 239-241 行
ThreadList* OS::listThreads() {
    return new LinuxThreadList();
}
```

**展开 LinuxThreadList 构造函数**：

```cpp
// 文件: os_linux.cpp 第 66-71 行
LinuxThreadList() : ThreadList() {
    _dir = opendir("/proc/self/task");  // 打开 /proc/self/task 目录
    _capacity = 128;
    _thread_array = (int*)malloc(_capacity * sizeof(int));
    fillThreadArray();
}
```

**fillThreadArray()**：

```cpp
// 文件: os_linux.cpp 第 53-63 行
void fillThreadArray() {
    if (_dir != NULL) {
        rewinddir(_dir);
        struct dirent* entry;
        while ((entry = readdir(_dir)) != NULL) {
            if (entry->d_name[0] != '.') {
                addThread(atoi(entry->d_name));
            }
        }
    }
}
```

**/proc/self/task 目录**：

```
/proc/self/task/
├── 12345/     <- 线程 12345
├── 12346/     <- 线程 12346
├── 12347/     <- 线程 12347
└── ...

目录名就是线程 ID (TID)
```

---

```cpp
    while (_running) {
        bool enabled = _enabled;

        for (int signaled_threads = 0; signaled_threads < THREADS_PER_TICK && thread_list->hasNext(); ) {
            int thread_id = thread_list->next();
            if (thread_id == self || thread_id <= 0) {
                // On macOS, task_threads() may sporadically return 0 or -1 among thread IDs
                continue;
            }
            if (thread_filter_enabled && !thread_filter->accept(thread_id)) {
                continue;
            }
```

**主循环结构**：

```
while (_running) {
    遍历线程列表，每次最多处理 THREADS_PER_TICK (8) 个线程：
    
    for (最多 8 个线程) {
        获取线程 ID
        
        跳过：
          - 自己（采样线程）
          - 无效线程 ID (<= 0)
          - 被过滤的线程
        
        处理：
          - 检查线程状态
          - 发送信号
    }
    
    睡眠一段时间
}
```

---

```cpp
            if (mode == CPU_ONLY) {
                if (!enabled || OS::threadState(thread_id) == THREAD_SLEEPING) {
                    continue;
                }
```

**展开 OS::threadState()**：

```cpp
// 文件: os_linux.cpp 第 206-222 行
ThreadState OS::threadState(int thread_id) {
    char buf[512];
    snprintf(buf, sizeof(buf), "/proc/self/task/%d/stat", thread_id);
    int fd = open(buf, O_RDONLY);
    if (fd == -1) {
        return THREAD_UNKNOWN;
    }

    ThreadState state = THREAD_UNKNOWN;
    if (read(fd, buf, sizeof(buf)) > 0) {
        char* s = strchr(buf, ')');
        state = s != NULL && (s[2] == 'R' || s[2] == 'D') ? THREAD_RUNNING : THREAD_SLEEPING;
    }

    close(fd);
    return state;
}
```

**/proc/self/task/<tid>/stat 格式**：

```
12345 (java) R 12344 12345 12344 34816 12345 4194304 12345678 0 0 0 ...

字段：
1. PID: 12345
2. 进程名: (java)
3. 状态: R (Running) / S (Sleeping) / D (Disk sleep) / ...

只需要检查第三个字段：
  'R' = Running
  'D' = Disk sleep (也算阻塞)
  其他 = Sleeping
```

---

```cpp
            } else if (mode == WALL_BATCH) {
                ThreadSleepState& tss = thread_sleep_state[thread_id];
                u64 new_thread_cpu_time = enabled ? OS::threadCpuTime(thread_id) : 0;
                if (new_thread_cpu_time != 0 && new_thread_cpu_time - tss.last_cpu_time <= RUNNABLE_THRESHOLD_NS) {
                    tss.last_time = TSC::ticks();
                    if (++tss.counter < MAX_IDLE_BATCH) {
                        if (tss.counter == 1) {
                            tss.start_time = tss.last_time;
                        }
                        continue;  // 跳过，不发送信号
                    }
                }
                if (tss.counter != 0) {
                    recordWallClock(tss, THREAD_SLEEPING, thread_id);
                    tss.counter = 0;
                }
            }
```

**WALL_BATCH 优化逻辑**：

```
对于阻塞线程的优化：

1. 获取线程 CPU 时间
2. 如果 CPU 时间增量 <= 10us (RUNNABLE_THRESHOLD_NS)：
   - 线程还在阻塞
   - 不发送信号，只增加 counter
   - counter 记录连续阻塞的采样次数

3. 如果 CPU 时间增量 > 10us：
   - 线程已经唤醒
   - 记录之前的阻塞批次
   - 发送信号采样

优势：
  - 阻塞线程不会被频繁打断
  - 多次阻塞采样合并为一次 WallClockEvent
  - 减少 overhead
```

**图解**：

```
时间线：
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│ 0 │ 1 │ 2 │ 3 │ 4 │ 5 │ 6 │ 7 │ 8 │ 9 │10 │11 │ 采样周期
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘

CPU_ONLY 模式：
  只采样运行态线程（跳过阻塞线程）

WALL_BATCH 模式：
  周期 0-5：线程阻塞
    - CPU 时间几乎不变
    - counter 累加：1, 2, 3, 4, 5, 6
    - 不发送信号

  周期 6：线程唤醒
    - CPU 时间增量 > 10us
    - 记录阻塞批次：counter = 6, time_span = 6 个周期
    - 发送信号采样

结果：
  - 阻塞期间只记录一次 WallClockEvent
  - samples = 6, time_span = 总阻塞时间
```

---

```cpp
            if (enabled && OS::sendSignalToThread(thread_id, _signal)) {
                signaled_threads++;
            }
        }
```

**展开 OS::sendSignalToThread()**：

```cpp
// 文件: os_linux.cpp 第 311-313 行
bool OS::sendSignalToThread(int thread_id, int signo) {
    return syscall(__NR_tgkill, processId(), thread_id, signo) == 0;
}
```

**展开 tgkill 系统调用**：

```c
// man 2 tgkill
int tgkill(pid_t tgid, pid_t tid, int sig);

// 参数：
//   tgid: 线程组 ID（进程 ID）
//   tid: 线程 ID
//   sig: 信号编号

// 返回：0 成功，-1 失败

// 与 kill/tkill 的区别：
//   kill(pid, sig): 发送给进程/进程组
//   tkill(tid, sig): 发送给线程（已废弃）
//   tgkill(tgid, tid, sig): 发送给指定线程（推荐）
```

**为什么用 tgkill 而不是 pthread_kill？**

```
pthread_kill(pthread_t thread, int sig):
  - 参数是 pthread_t，需要 pthread_t 到 tid 的转换
  - 某些情况下不可靠

tgkill(tgid, tid, sig):
  - 参数是数字 tid
  - 直接指定线程，更可靠
  - 可以向任意线程发送信号
```

---

```cpp
        u64 current_time = OS::nanotime();
        if (thread_list->hasNext()) {
            // Try to keep interval stable regardless of the number of profiled threads
            long long sleep_time = cycle_start_time + (u64)_interval * thread_list->index() / thread_list->count() - current_time;
            OS::uninterruptibleSleep(sleep_time < MIN_INTERVAL ? MIN_INTERVAL : sleep_time, &_running);
        } else {
            // Cycle has ended: prepare for the next cycle
            cycle_start_time += (u64)_interval;
            long long sleep_time = cycle_start_time - current_time;
            if (sleep_time < MIN_INTERVAL) {
                cycle_start_time = current_time + MIN_INTERVAL;
                sleep_time = MIN_INTERVAL;
            }
            OS::uninterruptibleSleep(sleep_time, &_running);
            thread_list->update();
        }
```

**睡眠时间计算**：

```
场景：100 个线程，采样间隔 10ms

方法 1（简单）：
  每轮遍历所有线程，然后睡眠 10ms
  问题：如果遍历花费 5ms，实际间隔变成 15ms

方法 2（AsyncProfiler 采用）：
  计算均匀分布的睡眠时间
  sleep_time = cycle_start_time + interval * index / count - current_time

  示例：
    cycle_start_time = 0
    interval = 10ms
    count = 100
    index = 0:  sleep = 0 + 10 * 0 / 100 = 0
    index = 50: sleep = 0 + 10 * 50 / 100 = 5ms
    index = 99: sleep = 0 + 10 * 99 / 100 = 9.9ms

  每个线程采样间隔仍然约为 10ms
```

**展开 OS::uninterruptibleSleep**：

```cpp
// 文件: os_linux.cpp
void OS::uninterruptibleSleep(u64 nanos, volatile bool* flag) {
    // 使用 nanosleep，但被信号打断后继续睡眠
    struct timespec req = {(time_t)(nanos / 1000000000), (long)(nanos % 1000000000)};
    struct timespec rem;
    while (nanosleep(&req, &rem) == -1 && errno == EINTR && *flag) {
        req = rem;
    }
}
```

---

```cpp
        // Sync thread CPU times updated since the previous iteration
        _thread_cpu_time_buf.drain(thread_sleep_state);
    }

    delete thread_list;

    // Flush remaining WallClock batches
    for (ThreadSleepMap::const_iterator it = thread_sleep_state.begin(); it != thread_sleep_state.end(); ++it) {
        const ThreadSleepState& tss = it->second;
        if (tss.counter != 0) {
            recordWallClock(tss, THREAD_SLEEPING, it->first);
        }
    }
}
```

**停止时刷新剩余批次**：

```
采样停止时，可能有未提交的阻塞批次：
  - counter > 0 的线程
  - 需要最后一次提交
```

---

### 2.7 recordWallClock()

```cpp
// 文件: wallClock.cpp 第 147-154 行

void WallClock::recordWallClock(const ThreadSleepState& tss, ThreadState state, int tid) {
    WallClockEvent event;
    event._start_time = tss.start_time;
    event._time_span = tss.last_time - tss.start_time;
    event._thread_state = state;
    event._samples = tss.counter;
    Profiler::instance()->recordExternalSamples(tss.counter, tss.counter * _interval, tid, tss.call_trace_id, WALL_CLOCK_SAMPLE, &event);
}
```

**recordExternalSamples 的作用**：
- 用于批量记录已合并的样本
- 参数：样本数量、总权重、线程 ID、调用栈 ID、事件类型、事件数据

---

## 3. 完整执行流程图

### 3.1 CPU_ONLY 模式

```
┌─────────────────────────────────────────────────────────────┐
│ 定时器线程                                                   │
│                                                             │
│ while (_running) {                                          │
│   for (最多 8 个线程) {                                      │
│     thread_id = thread_list->next()                         │
│                                                             │
│     [1] OS::threadState(thread_id)                          │
│         └─ 读取 /proc/self/task/<tid>/stat                  │
│         └─ 判断状态：R/D = Running，其他 = Sleeping          │
│                                                             │
│     [2] if (state == SLEEPING) continue                     │
│         └─ 跳过阻塞线程                                      │
│                                                             │
│     [3] OS::sendSignalToThread(thread_id, _signal)          │
│         └─ syscall(tgkill, pid, tid, signo)                 │
│         └─ 发送信号到目标线程                                │
│   }                                                         │
│                                                             │
│   sleep(interval)                                           │
│ }                                                           │
└─────────────────────────────────────────────────────────────┘
                          │
                          v
┌─────────────────────────────────────────────────────────────┐
│ 目标线程（被信号中断）                                        │
│                                                             │
│ signalHandler(signo, siginfo, ucontext) {                   │
│   [1] ExecutionEvent event(TSC::ticks())                    │
│       └─ 创建执行事件                                        │
│                                                             │
│   [2] event._thread_state = THREAD_UNKNOWN                  │
│       └─ CPU_ONLY 模式不区分状态                             │
│                                                             │
│   [3] Profiler::recordSample(ucontext, interval, ...)       │
│       └─ 记录采样                                            │
│ }                                                           │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 WALL_BATCH 模式

```
┌─────────────────────────────────────────────────────────────┐
│ 定时器线程                                                   │
│                                                             │
│ while (_running) {                                          │
│   for (最多 8 个线程) {                                      │
│     thread_id = thread_list->next()                         │
│                                                             │
│     [1] OS::threadCpuTime(thread_id)                        │
│         └─ syscall(clock_gettime, thread_cpu_clock)         │
│                                                             │
│     [2] if (cpu_time_delta <= 10us) {                       │
│           counter++                                          │
│           continue  // 不发送信号                            │
│         }                                                    │
│                                                             │
│     [3] if (counter > 0) {                                  │
│           recordWallClock()  // 提交批量阻塞事件             │
│           counter = 0                                        │
│         }                                                    │
│                                                             │
│     [4] OS::sendSignalToThread(thread_id, _signal)          │
│   }                                                         │
│                                                             │
│   [5] _thread_cpu_time_buf.drain()                          │
│       └─ 更新线程 CPU 时间状态                               │
│                                                             │
│   sleep(interval)                                           │
│ }                                                           │
└─────────────────────────────────────────────────────────────┘
                          │
                          v
┌─────────────────────────────────────────────────────────────┐
│ 目标线程（被信号中断）                                        │
│                                                             │
│ signalHandler(signo, siginfo, ucontext) {                   │
│   [1] getThreadState(ucontext)                              │
│       ├─ 检查 PC 是否指向 syscall 指令                       │
│       └─ 检查是否是被信号打断的系统调用                       │
│                                                             │
│   [2] WallClockEvent event                                  │
│       event._thread_state = state                           │
│       event._samples = 1                                     │
│                                                             │
│   [3] Profiler::recordSample(...)                           │
│       └─ 返回 trace = (tid << 32) | call_trace_id           │
│                                                             │
│   [4] if (state == SLEEPING && trace != 0) {                │
│         _thread_cpu_time_buf.add(trace)                     │
│         └─ 记录 CPU 时间，用于后续判断是否还在阻塞            │
│       }                                                      │
│ }                                                           │
└─────────────────────────────────────────────────────────────┘
```

---

## 4. 与 CPU 采样的对比

| 特性 | perf_event (CPU) | WallClock |
|-----|-----------------|-----------|
| **中断源** | 硬件性能计数器 | 定时器线程发送信号 |
| **采样触发** | CPU 周期/指令数 | 时间间隔 |
| **线程选择** | 当前运行的线程 | 遍历所有线程 |
| **阻塞线程** | 不会被采样 | 会被采样 |
| **开销** | 低（硬件支持） | 中（需要遍历线程） |
| **精度** | 高 | 中（受线程数量影响） |

---

## 5. 关键系统调用总结

| 系统调用 | 用途 | 文件 |
|---------|------|------|
| `tgkill(pid, tid, sig)` | 向指定线程发送信号 | `os_linux.cpp:312` |
| `clock_gettime(clockid, ts)` | 获取线程 CPU 时间 | `os_linux.cpp:233` |
| `gettid()` | 获取当前线程 ID | `os_linux.cpp` |
| `nanosleep(req, rem)` | 高精度睡眠 | `os_linux.cpp` |

---

## 6. 性能考虑

### 6.1 THREADS_PER_TICK 的选择

```
假设：
  线程数量 = 100
  采样间隔 = 10ms
  THREADS_PER_TICK = 8

每轮采样：
  时间 = 100 / 8 * 10ms = 125ms
  每个线程被采样的实际间隔 ≈ 125ms

如果 THREADS_PER_TICK = 100：
  每轮采样时间可能很长
  导致实际间隔不稳定
```

### 6.2 WALL_BATCH 优化效果

```
假设线程阻塞 1 秒：
  
WALL_LEGACY 模式：
  采样次数 = 1000ms / 10ms = 100 次
  信号处理次数 = 100 次
  记录事件数 = 100 个

WALL_BATCH 模式：
  信号处理次数 = 1 次（线程唤醒时）
  记录事件数 = 1 个
  samples = 100, time_span = 1000ms

优化效果：
  - 减少 99% 的信号处理
  - 减少 99% 的存储开销
```
