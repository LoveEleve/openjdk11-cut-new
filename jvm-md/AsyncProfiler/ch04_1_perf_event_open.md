# 4.1 perf_event_open — 内核性能计数器的配置与使用

> 源文件: `perfEvents_linux.cpp` (988行), `perfEvents.h` (84行)
> 关联: `cpuEngine.h/cpp` — CpuEngine 基类, `os_linux.cpp` — 系统调用封装
> 前置章节: 3.1 Engine 继承层次 + selectEngine 路由

## 核心问题

**async-profiler 的 CPU 采样是怎么工作的？它如何让 Linux 内核在 CPU 执行了 N 个时钟周期后，精确地中断目标线程并回调到用户空间？**

答案：**perf_event_open 系统调用 + 异步信号通知 + mmap 共享内存 ring buffer**。这是 Linux 性能监控子系统（perf）的标准接口，async-profiler 只是它最精妙的用户之一。

---

## 一、perf_event_open 系统调用概述

### 1.1 调用签名

```c
int perf_event_open(struct perf_event_attr *attr,
                    pid_t pid,       // 目标线程 TID（-1 = 所有线程）
                    int cpu,         // 目标 CPU（-1 = 所有 CPU）
                    int group_fd,    // 事件组（-1 = 独立）
                    unsigned long flags);
```

### 1.2 async-profiler 的调用方式

每个 Java 线程一个 fd：

```
                   ┌─────────────────────────────┐
   Thread 1 (tid=84976) ──→ perf_event_open() ──→ fd=7
   Thread 2 (tid=84978) ──→ perf_event_open() ──→ fd=8
   Thread 3 (tid=84980) ──→ perf_event_open() ──→ fd=9
   ...                                           ...
                   └─────────────────────────────┘
                      每个 fd 独立监控一个线程
```

**为什么不用一个 fd 监控所有线程？**

因为信号需要发给**被采样的那个线程**（在该线程上下文中才能采集它的栈）。一个 fd 只能 `F_SETOWN_EX` 到一个 TID。

---

## 二、PerfEventType — 20 种事件的统一描述

### 2.1 预定义事件表

```cpp
PerfEventType PerfEventType::AVAILABLE_EVENTS[] = {
    // 软件事件
    {"cpu-clock",          10000000, PERF_TYPE_SOFTWARE, PERF_COUNT_SW_CPU_CLOCK},
    {"page-faults",               1, PERF_TYPE_SOFTWARE, PERF_COUNT_SW_PAGE_FAULTS},
    {"context-switches",          2, PERF_TYPE_SOFTWARE, PERF_COUNT_SW_CONTEXT_SWITCHES},

    // 硬件 PMU 事件
    {"cycles",              1000000, PERF_TYPE_HARDWARE, PERF_COUNT_HW_CPU_CYCLES},
    {"instructions",        1000000, PERF_TYPE_HARDWARE, PERF_COUNT_HW_INSTRUCTIONS},
    {"cache-references",    1000000, PERF_TYPE_HARDWARE, PERF_COUNT_HW_CACHE_REFERENCES},
    {"cache-misses",           1000, PERF_TYPE_HARDWARE, PERF_COUNT_HW_CACHE_MISSES},
    {"branch-instructions", 1000000, PERF_TYPE_HARDWARE, PERF_COUNT_HW_BRANCH_INSTRUCTIONS},
    {"branch-misses",          1000, PERF_TYPE_HARDWARE, PERF_COUNT_HW_BRANCH_MISSES},
    {"bus-cycles",          1000000, PERF_TYPE_HARDWARE, PERF_COUNT_HW_BUS_CYCLES},
    {"ref-cycles",          1000000, PERF_TYPE_HARDWARE, PERF_COUNT_HW_REF_CPU_CYCLES},

    // 缓存事件（HW_CACHE 编码: cache_id | op<<8 | result<<16）
    {"L1-dcache-load-misses", 1000000, PERF_TYPE_HW_CACHE, LOAD_MISS(PERF_COUNT_HW_CACHE_L1D)},
    {"LLC-load-misses",          1000, PERF_TYPE_HW_CACHE, LOAD_MISS(PERF_COUNT_HW_CACHE_LL)},
    {"dTLB-load-misses",         1000, PERF_TYPE_HW_CACHE, LOAD_MISS(PERF_COUNT_HW_CACHE_DTLB)},

    // 动态事件（运行时解析）
    {"rNNN",                     1000, PERF_TYPE_RAW, 0},           // 原始 PMU 寄存器
    {"pmu/event-descriptor/",    1000, PERF_TYPE_RAW, 0},           // PMU 设备事件
    {"mem:breakpoint",    BKPT_INTERVAL, PERF_TYPE_BREAKPOINT, 0},  // 硬件断点
    {"trace:tracepoint",            1, PERF_TYPE_TRACEPOINT, 0},    // 内核 tracepoint
    {"kprobe:func",                 1, 0, 0},                       // kprobe
    {"uprobe:path",                 1, 0, 0},                       // uprobe
};
```

### 2.2 default_interval 的含义

| 事件 | default_interval | 含义 |
|------|-----------------|------|
| cpu-clock | 10,000,000 ns = 10ms | 每 10ms 采样一次 |
| cycles | 1,000,000 | 每 100 万个 CPU 周期采样一次（≈0.5ms @ 2GHz） |
| cache-misses | 1,000 | 每 1000 次 cache miss 采样一次 |
| page-faults | 1 | 每次 page fault 都采样 |
| breakpoint | 1 (x86) / 2 (ARM64) | 每次命中都采样 |

### 2.3 forName — 事件名解析的 8 级瀑布

```cpp
PerfEventType* PerfEventType::forName(const char* name) {
    // 1. "cpu" → cpu-clock（alias）
    if (strcmp(name, EVENT_CPU) == 0)
        return &AVAILABLE_EVENTS[IDX_CPU];

    // 2. 预定义事件表匹配
    for (int i = 0; i <= IDX_PREDEFINED; i++) ...

    // 3. "mem:xxx" → 硬件断点
    if (strncmp(name, "mem:", 4) == 0) ...

    // 4. "trace:NNN" → raw tracepoint
    if (strncmp(name, "trace:", 6) == 0) ...

    // 5. "kprobe:func" / "uprobe:path" → 动态探针
    if (strncmp(name, "kprobe:", 7) == 0) ...
    if (strncmp(name, "uprobe:", 7) == 0) ...

    // 6. "rNNN" → 原始 PMU 寄存器
    if (name[0] == 'r' && name[1] >= '0') ...

    // 7. "pmu/event/" → PMU 设备描述符
    if (s > name && s[1] != 0 && s[strlen(s)-1] == '/') ...

    // 8. "name:id" → debugfs tracepoint
    s = strchr(name, ':');
    if (s != NULL && s[1] != ':') ...

    // 9. 兜底：当作函数名 → 执行断点
    return getBreakpoint(name, HW_BREAKPOINT_X, sizeof(long));
}
```

**重要设计**：最后的兜底意味着你可以直接写 `asprof -e malloc ...` 来 profile malloc 函数调用，async-profiler 会自动在 malloc 上设置硬件断点。

---

## 三、createForThread — 核心流程（逐步拆解）

### 3.1 完整流程图

```
createForThread(tid)
  │
  ├── 1. CAS 防重复
  │     __sync_bool_compare_and_swap(&_events[tid]._fd, 0, -1)
  │
  ├── 2. 构造 perf_event_attr
  │     ├── type = PERF_TYPE_SOFTWARE (cpu-clock)
  │     ├── config = PERF_COUNT_SW_CPU_CLOCK (0)
  │     ├── sample_period = 10,000,000 (10ms)
  │     ├── sample_type = PERF_SAMPLE_CALLCHAIN
  │     ├── disabled = 1 (创建时不启用)
  │     ├── wakeup_events = 1
  │     ├── precise_ip = 2 (软件事件最高精度)
  │     └── exclude_callchain_user = 1 (由 asprof 自己回溯用户栈)
  │
  ├── 3. perf_event_open(attr, tid, -1, -1, PERF_FLAG_FD_CLOEXEC)
  │     → 返回 fd
  │
  ├── 4. mmap(fd, 2 pages) → ring buffer
  │     ├── page 0: perf_event_mmap_page (元数据)
  │     └── page 1: 数据区（内核写入 PERF_RECORD_SAMPLE）
  │
  ├── 5. 配置异步信号通知
  │     ├── fcntl(fd, F_SETFL, O_ASYNC)      ← 开启异步 IO
  │     ├── fcntl(fd, F_SETSIG, 27)          ← 信号改为 SIGPROF
  │     └── fcntl(fd, F_SETOWN_EX, {TID})    ← 信号发给指定线程
  │
  └── 6. 启用计数器
        ├── ioctl(fd, PERF_EVENT_IOC_RESET, 0)    ← 清零计数器
        └── ioctl(fd, PERF_EVENT_IOC_REFRESH, 1)  ← 启用，溢出后自动禁用
```

### 3.2 GDB 验证 — perf_event_attr 的实际值

```
=== perf_event_open syscall (第一个线程) ===
attr.type              = 1          ← PERF_TYPE_SOFTWARE
attr.size              = 136        ← sizeof(perf_event_attr)
attr.config            = 0          ← PERF_COUNT_SW_CPU_CLOCK
attr.sample_period     = 10000000   ← 10ms（default_interval）
attr.sample_type       = 32         ← PERF_SAMPLE_CALLCHAIN (0x20)
attr.disabled          = 1          ← 创建时禁用
attr.wakeup_events     = 1          ← 每个样本唤醒一次
attr.exclude_kernel    = 0          ← 包含内核态
attr.exclude_callchain_kernel = 0   ← 内核调用链也采集
attr.exclude_callchain_user   = 1   ← 用户调用链由 asprof 自己回溯
attr.precise_ip        = 2          ← 请求最高精度 IP
pid(tid)               = 84976      ← 目标线程
cpu                    = -1         ← 不绑定 CPU
group_fd               = -1         ← 独立事件
flags                  = 8          ← PERF_FLAG_FD_CLOEXEC
```

### 3.3 关键参数详解

#### `sample_type = PERF_SAMPLE_CALLCHAIN (0x20)`

告诉内核在每次采样时，自动回溯**内核态调用链**并写入 ring buffer。

**为什么不让内核也回溯用户态？**

因为内核不懂 JIT 代码。内核的 `perf_callchain_user()` 走的是 `fp` 链（frame pointer），但 JVM 的 JIT 代码不保留 frame pointer（除非 `-XX:+PreserveFramePointer`），所以内核回溯的用户栈是错误的。

async-profiler 的做法是：
- 让内核负责内核态栈（`exclude_callchain_kernel=0`）
- 自己负责用户态栈（`exclude_callchain_user=1`），使用 `AsyncGetCallTrace` + `walkVM/walkDwarf/walkFP`

#### `precise_ip = 2`

| 值 | 含义 |
|----|------|
| 0 | 任意 skid |
| 1 | 常数 skid |
| 2 | 请求零 skid |
| 3 | 必须零 skid |

"Skid" 是指采样点和实际触发点之间的指令偏移。`precise_ip=2` 请求最高精度，但不强制。软件事件（cpu-clock）可以精确到触发点，硬件事件（cycles）可能有几条指令的偏移。

#### `disabled = 1` + `PERF_EVENT_IOC_REFRESH`

**为什么要 disabled=1？**

因为要在 `fcntl` 配置信号递送之后才启用。否则在 `perf_event_open` 返回后、`fcntl` 之前，计数器就可能溢出但信号无法递送给正确的线程。

**REFRESH vs ENABLE 的区别**：

```
PERF_EVENT_IOC_REFRESH(1):
  ├── 启用计数器
  ├── 计数器溢出时自动禁用（"one-shot"模式）
  └── 发送信号

PERF_EVENT_IOC_ENABLE:
  ├── 启用计数器
  ├── 计数器溢出时不禁用（持续运行）
  └── 发送信号
```

async-profiler 默认使用 **REFRESH 模式**：溢出后自动禁用 → 发信号 → 信号处理器采样完毕 → 再次 REFRESH 启用。这样保证信号处理器执行期间不会被重入。

**例外**：Linux 6.16/6.17 有 bug 会导致 REFRESH 挂起整个系统，此时退化到 ENABLE 模式（手动 DISABLE/ENABLE）。

---

## 四、CAS 防重复 — 竞态处理

```cpp
if (!__sync_bool_compare_and_swap(&_events[tid]._fd, 0, -1)) {
    return -1;  // Lost race
}
```

**为什么需要 CAS？**

因为 `createForThread` 有两个调用来源，可能同时执行：

```
来源1: PerfEvents::start() → createForAllThreads()
  遍历 /proc/self/task/ 下所有线程

来源2: pthread_setspecific_hook → onThreadStart()
  新线程刚启动时的 GOT Hook 回调
```

如果一个线程恰好在 `createForAllThreads()` 遍历期间启动，两个路径都会尝试为它创建 perf_event。CAS 保证只有一个成功。

**`_fd` 的三态**：
- `0` = 未创建
- `-1` = 正在创建（占位）
- `>0` = 已创建（真实 fd 值）

---

## 五、mmap Ring Buffer — 零拷贝内核栈传递

### 5.1 内存布局

```
mmap(NULL, 2 * page_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)

  ┌──────────────────────────────┐ offset = 0
  │  struct perf_event_mmap_page │ ← 元数据页
  │  ├── data_head (内核更新)     │
  │  ├── data_tail (用户更新)     │
  │  └── ...                     │
  ├──────────────────────────────┤ offset = page_size (4096)
  │  Ring Buffer 数据区           │ ← 只有一页（4096 字节）
  │  ├── perf_event_header        │
  │  │   └── PERF_RECORD_SAMPLE   │
  │  │       ├── [cpu]            │  (if _record_cpu)
  │  │       ├── nr (调用链深度)   │
  │  │       ├── ip[0] 内核帧     │
  │  │       ├── ip[1] 内核帧     │
  │  │       └── ...              │
  │  └──────────────────────────  │
  └──────────────────────────────┘
```

**为什么只分配 2 页（8KB）？**

因为 async-profiler 只需要内核调用链（通常 10-30 帧），一个 PERF_RECORD_SAMPLE 通常只有几百字节。一页的数据区足够了。

### 5.2 _use_perf_mmap 的条件

```cpp
_use_perf_mmap = _kernel_stack          // 需要内核栈
              || _cstack == CSTACK_DEFAULT   // 默认模式
              || _cstack == CSTACK_LBR       // LBR 需要通过 mmap 读取
              || _record_cpu;                 // 需要 CPU ID
```

**什么时候不 mmap？** 当 `--all-user` 且 `--cstack no` 时，不需要内核栈也不需要 CPU ID，就不 mmap。

### 5.3 GDB 验证 — Ring Buffer 实际状态

```
=== PerfEvents::walk ===
tid=85849  max_depth=128
_events[tid]._fd   = 7              ← 有效 fd
_events[tid]._page = 0x7ffff7b09000 ← mmap 地址
page->data_head    = 16             ← 内核已写入 16 字节
page->data_tail    = 0              ← 用户尚未消费
_cstack            = 5 (CSTACK_VM)  ← 使用 VMStructs 回溯用户栈
walk returned depth = 0             ← 没有内核帧（内核态栈为空，说明中断发生在用户态）
```

---

## 六、信号驱动采样机制

### 6.1 信号配置链

```
perf_event_open(attr, tid) → fd
  │
  ├── fcntl(fd, F_SETFL, O_ASYNC)
  │     含义: 当 fd 有数据可读时（计数器溢出），发送信号
  │
  ├── fcntl(fd, F_SETSIG, 27)
  │     含义: 把默认的 SIGIO(29) 改为信号 27
  │     27 = SIGPROF（由 OS::getProfilingSignal(0) 选择）
  │
  └── fcntl(fd, F_SETOWN_EX, {F_OWNER_TID, tid})
        含义: 信号发给指定的线程（而非进程的随机线程）
```

### 6.2 信号选择策略

```cpp
int OS::getProfilingSignal(int mode) {
    static int preferred_signals[2] = {SIGPROF, SIGVTALRM};
    // mode=0 → 首选 SIGPROF(27)
    // mode=1 → 首选 SIGVTALRM(26)（WallClock 使用）

    // 从首选信号开始，如果已被占用则遍历允许列表：
    // SIGPROF | SIGVTALRM | SIGSTKFLT | SIGPWR | SIGRT32~63
    // 跳过已被其他模式占用的信号
    // 步长 53（与 64 互质）保证遍历所有信号
}
```

### GDB 验证 — 信号处理器实际行为

```
=== signalHandler hit ===
signo           = 27          ← SIGPROF
si_code         = 6           ← POLL_HUP (fd 可读)
_enabled        = 1           ← 采样开启
_ioc_enable     = 0x2402      ← PERF_EVENT_IOC_REFRESH
tid             = 85415       ← 被采样的线程
```

### 6.3 signalHandler 完整流程

```cpp
void PerfEvents::signalHandler(int signo, siginfo_t* siginfo, void* ucontext) {
    // 1. 过滤外部信号
    if (siginfo->si_code <= 0) return;
    //    si_code > 0 → 内核产生的信号
    //    si_code <= 0 → kill/tkill 发的信号

    // 2. 如果使用 ENABLE 模式（非 REFRESH），手动禁用
    if (_ioc_enable == PERF_EVENT_IOC_ENABLE) {
        ioctl(siginfo->si_fd, PERF_EVENT_IOC_DISABLE, 0);
    }

    // 3. 采样核心
    if (_enabled) {
        ExecutionEvent event(TSC::ticks());         // 记录 TSC 时间戳
        u64 counter = readCounter(siginfo, ucontext); // 读取计数器值
        Profiler::instance()->recordSample(ucontext, counter, PERF_SAMPLE, &event);
    } else {
        resetBuffer(OS::threadId());                // 禁用时只清空 ring buffer
    }

    // 4. 重新启用
    ioctl(siginfo->si_fd, PERF_EVENT_IOC_RESET, 0);     // 重置计数器
    ioctl(siginfo->si_fd, _ioc_enable, 1);               // 重新启用
}
```

**关键点**：信号处理器在被采样线程的上下文中执行。所以 `ucontext` 包含的是**被中断时的寄存器状态**，可以从中获取 PC、SP、FP 等用于栈回溯。

### 6.4 readCounter — 读取性能计数器的值

```cpp
u64 PerfEvents::readCounter(siginfo_t* siginfo, void* ucontext) {
    switch (_event_type->counter_arg) {
        case 1: return StackFrame(ucontext).arg0();  // 函数第1个参数
        case 2: return StackFrame(ucontext).arg1();  // 函数第2个参数
        case 3: return StackFrame(ucontext).arg2();  // 函数第3个参数
        case 4: return StackFrame(ucontext).arg3();  // 函数第4个参数
        default: {
            u64 counter;
            return read(siginfo->si_fd, &counter, sizeof(counter)) == sizeof(counter)
                ? counter : 1;
        }
    }
}
```

**counter_arg 的用途**：

对于硬件断点事件（如 `asprof -e malloc`），`counter_arg=1` 表示用函数的第一个参数作为计数值。malloc 的第一个参数是 `size`，所以火焰图上的值就是**分配的字节数**而不是调用次数。

```
asprof -e malloc → 断点在 malloc 入口 → 信号到达时正好在 malloc 栈帧
  → arg0() 读取 rdi 寄存器 → 就是 malloc(size) 的 size
```

KNOWN_FUNCTIONS 表定义了常见函数的计数参数：

| 函数 | counter_arg | 读取的参数 | 含义 |
|------|------------|-----------|------|
| malloc | 1 | arg0 = size | 分配大小 |
| mmap | 2 | arg1 = length | 映射大小 |
| read/write | 3 | arg2 = count | 读写字节数 |
| send/recv | 3 | arg2 = len | 发送/接收字节数 |

---

## 七、_events 数组 — 线程到 fd 的映射

### 7.1 分配策略

```cpp
int max_events = OS::getMaxThreadId();  // 读 /proc/sys/kernel/pid_max
if (max_events != _max_events) {
    free(_events);
    _events = (PerfEvent*)calloc(max_events, sizeof(PerfEvent));
    _max_events = max_events;
}
```

### GDB 验证

```
_max_events = 4194304   ← pid_max = 4MB
sizeof(PerfEvent) = 16  ← fd(4) + padding(4) + *page(8)
总内存 = 4M × 16 = 64MB
```

**为什么用 TID 直接索引数组，而不是用 HashMap？**

因为 `signalHandler` 和 `walk` 都在信号处理器中调用，不能做任何可能死锁的操作（malloc、mutex）。直接索引 O(1) 且完全无锁。代价是 64MB 内存（大部分是 0，不会真正分配物理页——Linux 的 lazy allocation）。

### 7.2 destroyForThread

```cpp
void PerfEvents::destroyForThread(int tid) {
    PerfEvent* event = &_events[tid];
    int fd = event->_fd;
    if (fd > 0 && __sync_bool_compare_and_swap(&event->_fd, fd, 0)) {
        ioctl(fd, PERF_EVENT_IOC_DISABLE, 0);  // 先禁用
        close(fd);                               // 再关闭
    }
    if (event->_page != NULL) {
        event->lock();           // SpinLock 保护
        munmap(event->_page, 2 * OS::page_size);
        event->_page = NULL;
        event->unlock();
    }
}
```

**为什么 munmap 需要 SpinLock 但 close 不需要？**

因为 `close(fd)` 是原子的（CAS 已保证只有一个线程执行），但 `munmap` 可能和 `walk()` 并发——`walk()` 正在读 ring buffer 时不能 munmap。所以 `walk()` 和 `destroyForThread()` 共享同一个 SpinLock。

---

## 八、PerfEvents::start — 完整启动流程

```cpp
Error PerfEvents::start(Arguments& args) {
    // 1. 解析事件类型
    _event_type = PerfEventType::forName(args._event);  // "cpu" → cpu-clock

    // 2. 检查 pthread hook
    if (!setupThreadHook()) return Error;

    // 3. 配置参数
    _interval = args._interval ? args._interval : _event_type->default_interval;
    //   用户没指定 → 使用默认 10,000,000 ns (10ms)
    _signal = args._signal == 0 ? OS::getProfilingSignal(0) : args._signal & 0xff;
    //   默认 → SIGPROF(27)

    // 4. 内核栈配置
    _alluser = args._alluser;
    _kernel_stack = !_alluser && _cstack != CSTACK_NO;
    //   检查 /proc/kallsyms 是否可读
    if (_kernel_stack && !Symbols::haveKernelSymbols()) {
        _kernel_stack = false;
        // 非 CPU 事件自动切换到 alluser
    }

    // 5. IOC 模式选择
    _ioc_enable = hasPerfEventRefreshBug()
        ? PERF_EVENT_IOC_ENABLE      // Linux 6.16/6.17 workaround
        : PERF_EVENT_IOC_REFRESH;    // 正常模式

    // 6. 调整 fd 上限
    adjustFDLimit();  // setrlimit(RLIMIT_NOFILE, max)

    // 7. 分配 _events 数组
    _events = calloc(pid_max, sizeof(PerfEvent));

    // 8. 安装信号处理器
    OS::installSignalHandler(_signal, signalHandler);

    // 9. 启用线程 Hook
    enableThreadHook();  // GOT patch pthread_setspecific

    // 10. 为所有现有线程创建 perf_event
    int err = createForAllThreads();
    //   遍历 /proc/self/task/ → createForThread(tid) × N
}
```

### GDB 验证 — start 的实际参数

```
args._event      = cpu
args._interval   = 0     → 使用默认 10000000
args._cstack     = 5     → CSTACK_VM（3.1 中 selectEngine 后自动推断）
args._signal     = 0     → 使用默认 SIGPROF(27)
args._alluser    = 0     → 包含内核态
args._target_cpu = -1    → 不绑定 CPU
```

### 启动后的关键状态

```
_signal        = 27 (SIGPROF)
_interval      = 10,000,000 (10ms)
_ioc_enable    = 0x2402 (PERF_EVENT_IOC_REFRESH)
_use_perf_mmap = 1 (开启 ring buffer)
_kernel_stack  = 1 (采集内核栈)
_alluser       = 0 (包含内核态)
_max_events    = 4,194,304
```

---

## 九、walk — 从 Ring Buffer 读取内核调用链

### 9.1 完整逻辑

```cpp
int PerfEvents::walk(int tid, void* ucontext, const void** callchain,
                     int max_depth, StackContext* java_ctx) {
    PerfEvent* event = &_events[tid];
    if (!event->tryLock()) return 0;   // 防止和 destroyForThread 竞争

    int depth = 0;
    struct perf_event_mmap_page* page = event->_page;

    if (page != NULL) {
        u64 tail = page->data_tail;    // 用户上次读到的位置
        u64 head = page->data_head;    // 内核最新写入位置
        rmb();                          // 读屏障：确保先读 head 再读数据

        RingBuffer ring(page);
        while (tail < head) {
            struct perf_event_header* hdr = ring.seek(tail);
            if (hdr->type == PERF_RECORD_SAMPLE) {
                u64 nr = ring.next();          // 调用链帧数
                while (nr-- > 0) {
                    u64 ip = ring.next();       // 每一帧的 IP
                    if (ip < PERF_CONTEXT_MAX) {
                        const void* iptr = (const void*)ip;
                        if (CodeHeap::contains(iptr)) {
                            // 遇到 JIT 代码 → 停止（后续由 ASGCT 接管）
                            java_ctx->pc = iptr;
                            goto stack_complete;
                        }
                        callchain[depth++] = iptr;
                    }
                    // ip >= PERF_CONTEXT_MAX → 上下文标记
                    // （如 PERF_CONTEXT_KERNEL / PERF_CONTEXT_USER）
                }
                break;
            }
            tail += hdr->size;
        }

stack_complete:
        page->data_tail = head;  // 标记已消费
    }

    event->unlock();

    // 补充用户态原生栈回溯
    if (_cstack == CSTACK_FP) {
        depth += StackWalker::walkFP(...);
    } else if (_cstack == CSTACK_DWARF) {
        depth += StackWalker::walkDwarf(...);
    }
    // CSTACK_VM 不在这里处理，由 Profiler::recordSample → StackWalker::walkVM 处理

    return depth;
}
```

### 9.2 RingBuffer 环形缓冲区

```cpp
class RingBuffer {
    const char* _start;           // 数据区起始地址
    unsigned long _offset;        // 当前偏移

    RingBuffer(perf_event_mmap_page* page) {
        _start = (const char*)page + OS::page_size;  // 跳过元数据页
    }

    perf_event_header* seek(u64 offset) {
        _offset = (unsigned long)offset & OS::page_mask;  // 环形取模
        return (perf_event_header*)(_start + _offset);
    }

    u64 next() {
        _offset = (_offset + sizeof(u64)) & OS::page_mask;
        return *(u64*)(_start + _offset);
    }
};
```

**`& OS::page_mask`** — 因为数据区只有一页（4096 字节），`page_mask = 4095 = 0xFFF`，用位与代替取模实现环形。

### 9.3 内核帧和 Java 帧的边界检测

```
内核 ring buffer 中的调用链：
  [PERF_CONTEXT_KERNEL]
  ip: 0xffffffff81234567   ← 内核帧（sys_read）
  ip: 0xffffffff81234888   ← 内核帧（vfs_read）
  [PERF_CONTEXT_USER]
  ip: 0x7ffff7654321       ← 用户帧（libc）
  ip: 0x7fffec801234       ← 落在 CodeHeap 中！→ Java JIT 代码
```

`CodeHeap::contains(ip)` 检测到 IP 在 JVM CodeHeap 范围内时，说明已经到达 Java 帧的边界。此时停止读取内核调用链，把这个 PC 保存到 `java_ctx->pc`，后续由 `AsyncGetCallTrace` 从这个 PC 继续回溯 Java 栈。

---

## 十、总结

### 关键数据流

```
Linux 内核 perf 子系统
  ├── 配置: perf_event_open(attr, tid) → fd
  ├── 计数: CPU 执行 → 硬件/软件计数器递增
  ├── 溢出: counter >= sample_period → 写入 ring buffer + 发信号
  │
  └── 信号到达目标线程 (SIGPROF)
        │
        └── PerfEvents::signalHandler()
              ├── readCounter() → 读取计数值
              ├── Profiler::recordSample()
              │     ├── PerfEvents::walk() → 从 ring buffer 读内核栈
              │     ├── AsyncGetCallTrace() → Java 栈
              │     └── StackWalker::walkVM() → 混合模式栈
              ├── ioctl(RESET) → 重置计数器
              └── ioctl(REFRESH) → 重新启用
```

### 设计精髓

1. **每线程一个 fd**：信号精确发给被采样线程，获取正确的 ucontext
2. **REFRESH 自动禁用**：避免信号处理器重入
3. **mmap ring buffer**：零拷贝传递内核调用链
4. **CAS 防重复**：`createForAllThreads()` 和 `pthread_hook` 并发安全
5. **TID 直接索引**：O(1) 无锁查找，信号安全
6. **内核栈 + 用户栈分离**：内核回溯内核帧，asprof 回溯用户帧（因为 JIT 代码无 frame pointer）
7. **函数参数计数**：硬件断点事件可以用函数参数作为权重（如 malloc 的 size）
8. **8 级事件名解析**：统一处理 PMU/tracepoint/kprobe/uprobe/breakpoint

### 在整体架构中的位置

```
Agent 加载（Ch01）
  → VMStructs 初始化（Ch02）
  → Engine 体系 + selectEngine（Ch03）
  → perf_event_open 配置 + 信号驱动（本节）← 你在这里
  → 信号到达 → walk() 读 ring buffer（4.2）
  → recordSample → ASGCT + 栈回溯（Ch05）
```

---

*创建日期: 2026-02-09*
*GDB 验证环境: OpenJDK 11 slowdebug + async-profiler v4.0*
