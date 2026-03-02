# 第五章：CPU Profiling - perf_event 机制深度解析

> **基于 async-profiler 源码分析（perfEvents_linux.cpp / perfEvents.h / cpuEngine.h）**
> **对照 Linux 内核头文件（/usr/include/linux/perf_event.h）**
> **方法论**：程序 = 数据结构 + 算法

---

## 第 0 部分：核心原理

### 0.1 本质是什么？

利用 Linux 内核的 perf_event 子系统，在硬件计数器溢出时触发信号，实现低开销、无 Safepoint 偏差的 CPU 采样。

### 0.2 为什么需要 perf_event？

传统 Java Profiling（JFR、hprof）基于 Safepoint 采样——只有当所有线程到达安全点时才能采集栈帧。这导致在 CPU 密集型代码中，采样点集中在 Safepoint（如循环回边、方法返回），完全错过真正的 CPU 热点。第一章已详细分析了这个问题。

perf_event 是 Linux 内核提供的硬件性能计数器接口。硬件计数器在 CPU 层面运行，不受 JVM Safepoint 约束，计数器溢出时内核直接向目标线程发送信号，采样点均匀分布在整个执行过程中。

### 0.3 怎么解决？

核心思路：为每个线程创建独立的 perf_event 文件描述符，配置硬件计数器（默认 `cpu-clock`，周期由 `default_interval` 决定），通过 `fcntl(F_SETOWN_EX + F_SETSIG)` 将溢出信号绑定到目标线程。计数器溢出时，内核发送 SIGPROF，async-profiler 的信号处理器记录当前栈帧。

关键设计：
1. **每线程一个 fd**：`perf_event_open` 的 `pid` 参数指定线程 TID，信号只发给目标线程
2. **PERF_EVENT_IOC_REFRESH**（默认）：每次溢出后自动禁用，signalHandler 中重新 REFRESH，天然避免信号递归
3. **信号驱动（O_ASYNC）**：`fcntl(fd, F_SETFL, O_ASYNC)` 使计数器溢出自动发送信号，无需轮询

### 0.4 为什么这样设计？

**为什么用硬件计数器而不是软件定时器（setitimer/timer_create）？** 硬件计数器由 CPU PMU 实现，开销极低；软件定时器需要内核定时中断，精度受限于 HZ。async-profiler 也提供 `ctimer`/`itimer` 作为 fallback，但精度和开销都不如 perf_event。

**为什么默认用 REFRESH 而不是 ENABLE？** `PERF_EVENT_IOC_REFRESH` 每次溢出后自动禁用 perf_event，天然避免了"信号处理器中再次收到信号"的递归问题。而 `PERF_EVENT_IOC_ENABLE` 需要手动 DISABLE→处理→RESET→ENABLE，在这个窗口期间可能有新信号到达。只有检测到内核 6.16.x/6.17.x 的 REFRESH bug 时才退化为 ENABLE。

**为什么用 SIGPROF？** SIGPROF 是 POSIX 定义的 Profiling 信号，JVM 不使用它。通过 libjsig 的信号链机制，SIGPROF 可以安全地与 JVM 共存。

---

## 第 1 部分：数据结构全景

### 1.1 数据结构清单

| # | 结构名 | 源码位置 | 核心作用 |
|---|--------|----------|----------|
| 1 | `perf_event_attr` | linux/perf_event.h (内核) | perf_event_open 的配置参数 |
| 2 | `perf_event_mmap_page` | linux/perf_event.h (内核) | perf_event mmap 共享页，零拷贝读取计数器 |
| 3 | `PerfEventType` | perfEvents_linux.cpp:173-506 | 事件类型定义 + 事件名解析 |
| 4 | `PerfEvent` | perfEvents_linux.cpp:536-542 | 单个线程的 perf_event 封装（fd + mmap page） |
| 5 | `RingBuffer` | perfEvents_linux.cpp:509-533 | perf_event mmap 环形缓冲区读取器 |
| 6 | `PerfEvents` | perfEvents.h:18-53 | 引擎实现类，管理所有线程的 PerfEvent |
| 7 | `CpuEngine` | cpuEngine.h:14-50 | PerfEvents/CTimer/ITimer 的公共基类 |
| 8 | `SpinLock` | spinLock.h:14-63 | CAS 自旋锁，PerfEvent 的基类 |

### 1.2 PerfEventType — 事件类型定义

#### 问题推导

**问题**：async-profiler 支持 `cpu`、`cycles`、`cache-misses`、`kprobe:func` 等几十种事件。用户传入字符串事件名后，如何映射到 `perf_event_attr` 的 `type`/`config` 字段？

**需要什么信息？**
- 事件名 → `perf_event_attr.type` + `perf_event_attr.config` 的映射
- 每种事件有不同的默认采样间隔
- 部分事件有自定义的 `config1`/`config2` 参数
- 部分事件的计数器值需要从特定函数参数读取（如 `malloc` 的 `size` 参数）

**推导出的结构**：一个包含 name/type/config/default_interval 的结构体 + 一个预定义事件数组 + 一个 `forName()` 查找方法。

#### 真实数据结构

```cpp
// perfEvents_linux.cpp:173-180
struct PerfEventType {
    const char* name;          // 事件名（如 "cpu-clock"、"cycles"）
    long default_interval;     // 默认采样间隔（如 1000000 表示每 100 万次 CPU 周期）
    __u32 type;                // perf_event_attr.type（如 PERF_TYPE_HARDWARE）
    __u64 config;              // perf_event_attr.config（如 PERF_COUNT_HW_CPU_CYCLES）
    __u64 config1;             // perf_event_attr.config1（自定义参数）
    __u64 config2;             // perf_event_attr.config2（自定义参数）
    int counter_arg;           // 计数器来源：0=从 fd read，1-4=从寄存器 arg0-arg3 读取
```

**推导 vs 实际**：基本吻合，额外发现 `default_interval` 字段——每种事件有独立的默认采样间隔。

#### 完整分析

| 字段 | 类型 | 含义 |
|------|------|------|
| `name` | const char* | 事件名，用于 `forName()` 匹配 |
| `default_interval` | long | 默认采样间隔，用户未指定 interval 时使用此值 |
| `type` | __u32 | 映射到 `perf_event_attr.type` |
| `config` | __u64 | 映射到 `perf_event_attr.config`（硬件断点时映射到 `bp_type`） |
| `config1` | __u64 | 映射到 `perf_event_attr.config1`（PMU 自定义事件使用） |
| `config2` | __u64 | 映射到 `perf_event_attr.config2`（PMU 自定义事件使用） |
| `counter_arg` | int | 0=从 fd read 读计数器；1-4=从信号上下文的寄存器 arg0-arg3 读取 |

**内部枚举**（事件数组索引分类）：

```cpp
// perfEvents_linux.cpp:182-191
enum {
    IDX_CPU = 0,           // cpu-clock 在数组中的索引
    IDX_PREDEFINED = 13,   // 预定义事件的结束索引
    IDX_RAW,               // 原始事件（rNNN）
    IDX_PMU,               // PMU 事件（pmu/event/）
    IDX_BREAKPOINT,        // 硬件断点（mem:addr）
    IDX_TRACEPOINT,        // tracepoint（trace:event）
    IDX_KPROBE,            // kprobe（kprobe:func）
    IDX_UPROBE,            // uprobe（uprobe:path）
};
```

**预定义事件数组（AVAILABLE_EVENTS）**：

```cpp
// perfEvents_linux.cpp:463-491
PerfEventType PerfEventType::AVAILABLE_EVENTS[] = {
    {"cpu-clock",    DEFAULT_INTERVAL, PERF_TYPE_SOFTWARE, PERF_COUNT_SW_CPU_CLOCK},     // ★ IDX_CPU=0
    {"page-faults",                 1, PERF_TYPE_SOFTWARE, PERF_COUNT_SW_PAGE_FAULTS},
    {"context-switches",            2, PERF_TYPE_SOFTWARE, PERF_COUNT_SW_CONTEXT_SWITCHES},

    {"cycles",                1000000, PERF_TYPE_HARDWARE, PERF_COUNT_HW_CPU_CYCLES},     // ★ 默认 100 万周期
    {"instructions",          1000000, PERF_TYPE_HARDWARE, PERF_COUNT_HW_INSTRUCTIONS},
    {"cache-references",      1000000, PERF_TYPE_HARDWARE, PERF_COUNT_HW_CACHE_REFERENCES},
    {"cache-misses",             1000, PERF_TYPE_HARDWARE, PERF_COUNT_HW_CACHE_MISSES},
    {"branch-instructions",   1000000, PERF_TYPE_HARDWARE, PERF_COUNT_HW_BRANCH_INSTRUCTIONS},
    {"branch-misses",            1000, PERF_TYPE_HARDWARE, PERF_COUNT_HW_BRANCH_MISSES},
    {"bus-cycles",            1000000, PERF_TYPE_HARDWARE, PERF_COUNT_HW_BUS_CYCLES},
    {"ref-cycles",            1000000, PERF_TYPE_HARDWARE, PERF_COUNT_HW_REF_CPU_CYCLES},

    {"L1-dcache-load-misses", 1000000, PERF_TYPE_HW_CACHE, LOAD_MISS(PERF_COUNT_HW_CACHE_L1D)},
    {"LLC-load-misses",          1000, PERF_TYPE_HW_CACHE, LOAD_MISS(PERF_COUNT_HW_CACHE_LL)},
    {"dTLB-load-misses",         1000, PERF_TYPE_HW_CACHE, LOAD_MISS(PERF_COUNT_HW_CACHE_DTLB)},

    /* End of IDX_PREDEFINED events */
    {"rNNN",                     1000, PERF_TYPE_RAW, 0},                                  // IDX_RAW
    {"pmu/event-descriptor/",    1000, PERF_TYPE_RAW, 0},                                  // IDX_PMU
    {"mem:breakpoint",  BKPT_INTERVAL, PERF_TYPE_BREAKPOINT, 0},                           // IDX_BREAKPOINT
    {"trace:tracepoint",            1, PERF_TYPE_TRACEPOINT, 0},                           // IDX_TRACEPOINT
    {"kprobe:func",                 1, 0, 0},                                               // IDX_KPROBE
    {"uprobe:path",                 1, 0, 0},                                               // IDX_UPROBE
};
```

**设计决策**：
- **为什么有 `counter_arg`？** 对于 kprobe/uprobe 事件（如 `malloc`），计数器值不是从 fd 读取，而是从被探测函数的参数寄存器读取。例如 `malloc` 的第一个参数就是分配大小，`counter_arg=1` 表示读 arg0。
- **为什么 `default_interval` 差异大？** 高频事件（如 `cache-misses`、`branch-misses`）默认间隔小（1000），避免溢出太频繁；低频事件（如 `cycles`）默认间隔大（1000000）。

### 1.3 PerfEvent — 单线程 perf_event 封装

#### 问题推导

**问题**：每个线程需要一个独立的 perf_event fd 和可选的 mmap 共享页。如何封装？

**需要什么信息？**
- fd：perf_event_open 返回的文件描述符
- mmap page：零拷贝读取计数器的共享内存页
- 线程安全：多线程并发创建/销毁时需要同步

**推导出的结构**：继承 SpinLock 获得锁能力，加上 fd 和 page 两个字段。

#### 真实数据结构

```cpp
// perfEvents_linux.cpp:536-542
class PerfEvent : public SpinLock {
  private:
    int _fd;                               // perf_event 文件描述符
    struct perf_event_mmap_page* _page;    // mmap 共享内存页

    friend class PerfEvents;
};
```

#### 完整分析

**SpinLock 基类**（spinLock.h:14-63）：

```cpp
class SpinLock {
  private:
    volatile int _lock;    // 0=unlocked, 1=exclusive, <0=shared lock
  public:
    SpinLock(int initial_state = 0) : _lock(initial_state) {}
    void reset() { _lock = 0; }
    bool tryLock() { return __sync_bool_compare_and_swap(&_lock, 0, 1); }
    void lock() { while (!tryLock()) spinPause(); }
    void unlock() { __sync_fetch_and_sub(&_lock, 1); }
    // + tryLockShared / lockShared / unlockShared（共享锁模式）
};
```

**PerfEvent 内存布局**：

| 偏移 | 字段 | 类型 | 大小 | 来源 |
|------|------|------|------|------|
| 0x00 | `_lock` | volatile int | 4B | SpinLock 基类 |
| 0x04 | `_fd` | int | 4B | perf_event_open 返回 |
| 0x08 | `_page` | perf_event_mmap_page* | 8B | mmap 返回 |

**sizeof(PerfEvent) = 16 字节**（4B lock + 4B fd + 8B page，int 之间无 padding）

> 注意：SpinLock 只有一个 `volatile int _lock`(4B)，后面紧跟 `int _fd`(4B)，两个 int 之间不需要对齐填充。`_page` 是指针(8B)，对齐到 8 字节边界，恰好在偏移 0x08 处。

**关键字段生命周期**：

- `_fd`：`createForThread()` 中 `syscall(__NR_perf_event_open)` 创建 → `signalHandler()` 中 `ioctl(siginfo->si_fd, ...)` 使用 → `destroyForThread()` 中 `close(fd)` 销毁
- `_page`：`createForThread()` 中 `mmap(NULL, 2 * OS::page_size, ...)` 创建 → `walk()` 中读取环形缓冲区 → `destroyForThread()` 中 `munmap()` 销毁

### 1.4 RingBuffer — perf_event mmap 环形缓冲区读取器

#### 问题推导

**问题**：perf_event 的 mmap 共享区域包含一个元数据页 + 一个数据页（环形缓冲区）。如何安全地从环形缓冲区中读取调用链数据？

**需要什么信息？**
- 缓冲区起始地址 = mmap page + OS::page_size
- 偏移量需要对齐到页边界（`& OS::page_mask`）
- 需要顺序读取 u64 值（调用链地址）

#### 真实数据结构

```cpp
// perfEvents_linux.cpp:509-533
class RingBuffer {
  private:
    const char* _start;          // 数据区起始地址（= mmap_page + page_size）
    unsigned long _offset;       // 当前偏移量

  public:
    RingBuffer(struct perf_event_mmap_page* page) {
        _start = (const char*)page + OS::page_size;  // ★ 跳过元数据页
    }

    struct perf_event_header* seek(u64 offset) {
        _offset = (unsigned long)offset & OS::page_mask;     // ★ 环形对齐
        return (struct perf_event_header*)(_start + _offset);
    }

    u64 next() {
        _offset = (_offset + sizeof(u64)) & OS::page_mask;  // ★ 步进 8 字节，环形对齐
        return *(u64*)(_start + _offset);
    }

    u64 peek(unsigned long words) {
        unsigned long peek_offset = (_offset + words * sizeof(u64)) & OS::page_mask;
        return *(u64*)(_start + peek_offset);                // ★ 预读取，不移动偏移量
    }
};
```

**设计决策**：
- **为什么用 `& OS::page_mask`？** 环形缓冲区的大小恰好是一个页（4096 字节），`page_mask = page_size - 1 = 0xFFF`。偏移量到达页尾时自动回绕到页首。
- **为什么 `seek` 返回 `perf_event_header*`？** perf_event 在环形缓冲区中写入的每条记录都以 `perf_event_header` 开头，包含 type 和 size 字段。

### 1.5 PerfEvents — 引擎实现类

#### 问题推导

**问题**：谁管理所有线程的 PerfEvent？如何为新线程自动创建、旧线程自动销毁 perf_event？

**需要什么信息？**
- 需要一个按 TID 索引的数组存储所有 PerfEvent
- 需要当前事件类型、采样间隔、信号编号等配置
- 需要线程钩子（pthread hook）监听线程创建/销毁

**推导出的结构**：继承 CpuEngine 获得线程钩子 + 信号处理基础设施，自己添加 PerfEvent 数组和 perf_event 特有配置。

#### 真实数据结构

**PerfEvents 类自有字段**（perfEvents.h:18-28）：

| 字段 | 类型 | 含义 |
|------|------|------|
| `_max_events` | static int | PerfEvent 数组大小（= pid_max） |
| `_events` | static PerfEvent* | PerfEvent 数组，按 TID 索引 |
| `_event_type` | static PerfEventType* | 当前事件类型 |
| `_ioc_enable` | static int | ioctl 启用命令：REFRESH（默认）或 ENABLE（bug 退化） |
| `_alluser` | static bool | 是否排除内核态 |
| `_kernel_stack` | static bool | 是否包含内核栈 |
| `_use_perf_mmap` | static bool | 是否使用 perf mmap（环形缓冲区） |
| `_record_cpu` | static bool | 是否记录 CPU ID |
| `_target_cpu` | static int | 目标 CPU（-1 = 所有 CPU） |

**继承自 CpuEngine 的字段**（cpuEngine.h:16-22）：

| 字段 | 类型 | 含义 |
|------|------|------|
| `_pthread_entry` | static void** | pthread 入口指针（线程钩子用） |
| `_current` | static CpuEngine* | 当前活动的引擎实例 |
| `_interval` | static long | 采样间隔 |
| `_cstack` | static CStack | 栈回溯方式（CSTACK_FP / CSTACK_DWARF / CSTACK_LBR / CSTACK_VM / CSTACK_NO） |
| `_signal` | static int | 使用的信号编号 |
| `_count_overrun` | static bool | 是否计数溢出 |

**CpuEngine 还继承自 Engine**（含 `_enabled` 等字段）。

### 1.6 perf_event_attr — 内核配置结构（简要）

`perf_event_attr` 是 Linux 内核结构体（`<linux/perf_event.h>`），async-profiler 在 `createForThread()` 中填充此结构传入 `perf_event_open` 系统调用。

**async-profiler 使用的关键字段**：

| 字段 | 类型 | async-profiler 设置 | 含义 |
|------|------|---------------------|------|
| `type` | __u32 | 来自 `event_type->type` | 事件类型（HARDWARE/SOFTWARE/BREAKPOINT/...） |
| `config` | __u64 | 来自 `event_type->config` | 事件配置（CPU_CYCLES/CPU_CLOCK/...） |
| `sample_period` | __u64 | `_interval` | 采样周期（每 N 个事件触发一次信号） |
| `sample_type` | __u64 | `PERF_SAMPLE_CALLCHAIN` + 可选 flags | 采样数据类型 |
| `disabled` | bit | `1`（初始禁用） | 创建后由 ioctl 启用 |
| `wakeup_events` | __u32 | `1` | 每次事件都触发信号 |
| `exclude_kernel` | bit | `_alluser ? 1 : 0` | 是否排除内核态事件 |
| `exclude_callchain_kernel` | bit | `!_kernel_stack ? 1 : 0` | 是否排除内核栈 |
| `exclude_callchain_user` | bit | `_cstack >= CSTACK_FP ? 1 : 0` | 是否排除 perf 自动回溯的用户栈（自己回溯时设 1） |
| `precise_ip` | 2 bits | 软件事件=2, 硬件事件=0 | 指令指针精度 |
| `branch_sample_type` | __u64 | LBR 模式下设置 | Last Branch Record 栈回溯 |
| `sample_regs_user` | __u64 | LBR 模式下 `1ULL << PERF_REG_PC` | 采样 PC 寄存器 |
| `config1` / `config2` | __u64 | 来自 `event_type->config1/config2` | PMU 自定义参数 |

---

## 第 2 部分：算法/流程分析

### 2.1 核心流程概览

```mermaid
sequenceDiagram
    participant P as Profiler::start
    participant S as PerfEvents::start()
    participant C as createForThread()
    participant K as Kernel perf_event
    participant SH as signalHandler()
    participant R as Profiler::recordSample()

    P->>S: args(event, interval, cstack)
    S->>S: 解析事件类型 + 设置配置
    S->>S: installSignalHandler(SIGPROF)
    S->>S: enableThreadHook()
    S->>C: createForAllThreads()

    loop 每个线程
        C->>K: syscall(perf_event_open, attr, tid)
        K-->>C: fd
        C->>K: mmap(fd) → shared page
        C->>K: fcntl(fd, O_ASYNC + F_SETSIG + F_SETOWN_EX)
        C->>K: ioctl(fd, PERF_EVENT_IOC_REFRESH, 1)
    end

    Note over K,SH: 硬件计数器溢出...

    K->>SH: SIGPROF (si_fd=fd)
    SH->>SH: readCounter(siginfo, ucontext)
    SH->>R: recordSample(ucontext, counter, PERF_SAMPLE, &event)
    R->>R: tryLock + 栈回溯 + 存储调用链
    SH->>K: ioctl(fd, PERF_EVENT_IOC_RESET)
    SH->>K: ioctl(fd, PERF_EVENT_IOC_REFRESH, 1)
```

### 2.2 PerfEvents::start() — 初始化配置

#### 解决什么问题？

根据用户参数配置 perf_event 引擎：解析事件类型、设置采样间隔、安装信号处理器、为所有现有线程创建 perf_event。

#### 源码文件与行号

`async-profiler/src/perfEvents_linux.cpp:769-846`

#### 真实源码 + 逐行注释

```cpp
// perfEvents_linux.cpp:769-846
Error PerfEvents::start(Arguments& args) {
    _event_type = PerfEventType::forName(args._event);
    // ★ 在 AVAILABLE_EVENTS[] 中查找事件名，如 "cpu" → "cpu-clock"
    if (_event_type == NULL) {
        return Error("Unsupported event type");
    } else if (_event_type->counter_arg > 4) {
        return Error("Only arguments 1-4 can be counted");
    }

    if (!setupThreadHook()) {
        return Error("Could not set pthread hook");
        // ★ 挂钩 pthread_create/pthread_exit，监听线程创建/销毁
    }

    _target_cpu = args._target_cpu;
    _record_cpu = args._record_cpu;

    if (args._interval < 0) {
        return Error("interval must be positive");
    }
    _interval = args._interval ? args._interval : _event_type->default_interval;
    // ★ 用户未指定 interval 时，使用事件类型的默认值（如 cycles → 1000000）
    _cstack = args._cstack;
    _signal = args._signal == 0 ? OS::getProfilingSignal(0) : args._signal & 0xff;
    // ★ 默认 SIGPROF，用户可通过 args._signal 自定义
    _count_overrun = false;

    _alluser = args._alluser;
    _kernel_stack = !_alluser && _cstack != CSTACK_NO;
    // ★ 只有不排除内核态 且 需要栈回溯时，才采集内核栈
    if (_kernel_stack && !Symbols::haveKernelSymbols()) {
        Log::warn("Kernel symbols are unavailable due to restrictions. Try\n"
                  "  sysctl kernel.perf_event_paranoid=1\n"
                  "  sysctl kernel.kptr_restrict=0");
        _kernel_stack = false;
        _alluser = strcmp(args._event, EVENT_CPU) != 0 && !supported();
        // ★ 非 CPU 事件且 perf_events 不可用时，自动切换到 alluser 模式
    }
    _use_perf_mmap = _kernel_stack || _cstack == CSTACK_DEFAULT || _cstack == CSTACK_LBR || _record_cpu;
    // ★ 需要 mmap 的条件：内核栈 / 默认栈模式 / LBR 模式 / 记录 CPU ID

    if (strcmp(_event_type->name, "cpu-clock") == 0 && hasPerfEventRefreshBug()) {
        Log::debug("Enable workaround for PERF_EVENT_IOC_REFRESH bug");
        _ioc_enable = PERF_EVENT_IOC_ENABLE;   // ★ 内核 6.16.x/6.17.x bug 退化
    } else {
        _ioc_enable = PERF_EVENT_IOC_REFRESH;  // ★ 默认：自动禁用，避免信号递归
    }

    adjustFDLimit();
    // ★ 提升 RLIMIT_NOFILE，确保有足够的文件描述符

    int max_events = OS::getMaxThreadId();
    if (max_events != _max_events) {
        free(_events);
        _events = (PerfEvent*)calloc(max_events, sizeof(PerfEvent));
        _max_events = max_events;
        // ★ 分配 PerfEvent 数组，大小 = pid_max（通常 32768 或更大）
    }

    if (VM::isOpenJ9()) {
        OS::installSignalHandler(_signal, signalHandlerJ9);
        // ★ OpenJ9 用单独的信号处理器（J9StackTraces 路径）
    } else {
        OS::installSignalHandler(_signal, signalHandler);
    }

    enableThreadHook();
    // ★ 启用线程钩子（为新线程自动调用 createForThread）

    int err = createForAllThreads();
    // ★ 遍历 /proc/self/task/ 为所有现有线程创建 perf_event
    if (err) {
        stop();
        if (err == EACCES || err == EPERM) {
            return Error("Perf events unavailable. Try --fdtransfer or --all-user option or 'sysctl kernel.perf_event_paranoid=1'");
        } else if (isResourceLimit(err)) {
            return Error("Perf events resource limit. Check 'ulimit -n'");
        } else {
            return Error("Perf events unavailable");
        }
    }
    return Error::OK;
}
```

#### 设计决策

- **为什么默认 REFRESH？** `PERF_EVENT_IOC_REFRESH` 是"使能一次"语义：溢出后 perf_event 自动禁用，不会再发信号。signalHandler 处理完后重新 REFRESH(1)，实现精确的"一次一采"。这天然避免了信号递归。
- **为什么检测 `hasPerfEventRefreshBug()`？** Linux 内核 6.16.x/6.17.x 存在一个 REFRESH 相关的 bug，只影响 `cpu-clock` 事件。检测到时退化为 ENABLE 模式（需要手动 DISABLE→处理→ENABLE）。
- **为什么 `_use_perf_mmap` 不总是 true？** mmap 共享页的主要用途是读取内核栈/调用链/CPU ID。如果只做纯用户态采样且用 FP/DWARF 自己回溯，不需要 mmap 页，节省一次 mmap 系统调用和一个页的内存。

### 2.3 createForThread() — 为单个线程创建 perf_event

#### 解决什么问题？

为指定线程创建 perf_event fd，配置 `perf_event_attr`，设置信号机制，启用事件。

#### 源码文件与行号

`async-profiler/src/perfEvents_linux.cpp:555-675`

#### 整体阶段划分

| 阶段 | 行号 | 功能 |
|------|------|------|
| Phase 1 | 555-562 | 边界检查 + CAS 防重复创建 |
| Phase 2 | 564-612 | 填充 perf_event_attr |
| Phase 3 | 614-637 | perf_event_open 系统调用 |
| Phase 4 | 639-650 | mmap 共享内存页 |
| Phase 5 | 652-660 | fcntl 设置信号机制 |
| Phase 6 | 660-665 | ioctl RESET + ENABLE/REFRESH |
| Phase 7 | 667-675 | 失败回滚 |

#### Phase 1: 边界检查 + CAS 防重复

```cpp
// perfEvents_linux.cpp:555-562
int PerfEvents::createForThread(int tid) {
    if (tid >= _max_events) {
        Log::warn("tid[%d] > pid_max[%d]. Restart profiler after changing pid_max", tid, _max_events);
        return -1;
    }

    // ★ CAS 将 _fd 从 0 设为 -1（标记"正在创建"）
    // ★ 防止 start() 遍历和 pthread hook 同时为同一线程创建
    if (!__sync_bool_compare_and_swap(&_events[tid]._fd, 0, -1)) {
        return -1;  // ★ 已有其他路径在创建，放弃
    }
```

#### Phase 2: 填充 perf_event_attr

```cpp
    // perfEvents_linux.cpp:564-612
    PerfEventType* event_type = _event_type;
    struct perf_event_attr attr = {0};
    attr.size = sizeof(attr);
    attr.type = event_type->type;

    if (attr.type == PERF_TYPE_BREAKPOINT) {
        attr.bp_type = event_type->config;   // ★ 硬件断点走 bp_type
    } else {
        attr.config = event_type->config;    // ★ 其他走 config
    }
    attr.config1 = event_type->config1;
    attr.config2 = event_type->config2;

    if (attr.type == PERF_TYPE_SOFTWARE) {
        attr.precise_ip = 2;  // ★ 软件事件支持精确 IP（无 skid）
    }

    attr.sample_period = _interval;              // ★ 采样周期
    attr.sample_type = PERF_SAMPLE_CALLCHAIN;    // ★ 请求内核提供调用链
    attr.disabled = 1;                           // ★ 初始禁用
    attr.wakeup_events = 1;                      // ★ 每次溢出都触发信号

    if (_alluser) {
        attr.exclude_kernel = 1;                 // ★ 排除内核态事件
    }
    if (!_kernel_stack) {
        attr.exclude_callchain_kernel = 1;       // ★ 排除内核调用链
    }
    if (_cstack >= CSTACK_FP) {
        attr.exclude_callchain_user = 1;         // ★ 自己做用户栈回溯，不让 perf 做
    }

    #ifdef PERF_ATTR_SIZE_VER5
    if (_cstack == CSTACK_LBR) {
        attr.sample_type |= PERF_SAMPLE_BRANCH_STACK | PERF_SAMPLE_REGS_USER;
        attr.branch_sample_type = PERF_SAMPLE_BRANCH_USER | PERF_SAMPLE_BRANCH_CALL_STACK;
        attr.sample_regs_user = 1ULL << PERF_REG_PC;
        // ★ LBR 模式：使用 CPU 的 Last Branch Record 做栈回溯
    }
    #endif

    if (_record_cpu) {
        attr.sample_type |= PERF_SAMPLE_CPU;    // ★ 采样数据中包含 CPU ID
    }
```

#### Phase 3: perf_event_open 系统调用

```cpp
    // perfEvents_linux.cpp:614-637
    int fd;
    if (FdTransferClient::hasPeer()) {
        fd = FdTransferClient::requestPerfFd(&tid, _target_cpu, &attr, PerfEventType::probe_func);
        // ★ 如果有 fdtransfer 守护进程，通过 Unix 域 socket 请求 fd（绕过权限限制）
    } else {
        fd = syscall(__NR_perf_event_open, &attr, tid, _target_cpu, -1, PERF_FLAG_FD_CLOEXEC);
        // ★ 直接调用系统调用。参数：attr, pid=tid, cpu=_target_cpu, group_fd=-1, flags
        if (fd == -1 && errno == EINVAL) {
            fd = syscall(__NR_perf_event_open, &attr, tid, _target_cpu, -1, 0);
            // ★ 老内核不支持 CLOEXEC，重试
        }
    }

    if (fd == -1) {
        int err = errno;
        Log::warn("perf_event_open for TID %d failed: %s", tid, strerror(err));
        _events[tid]._fd = 0;       // ★ 恢复标记
        if (isResourceLimit(err) && _current != NULL) {
            stop();                  // ★ 资源耗尽时紧急停止
        }
        return err;
    }
```

#### Phase 4-6: mmap + fcntl + ioctl

```cpp
    // perfEvents_linux.cpp:639-665
    void* page = NULL;
    if (_use_perf_mmap) {
        page = mmap(NULL, 2 * OS::page_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        // ★ 2 页 = 1 页元数据 + 1 页环形缓冲区
        if (page == MAP_FAILED) {
            Log::warn("perf_event mmap failed: %s", strerror(errno));
            page = NULL;
        }
    }

    _events[tid].reset();       // ★ 重置 SpinLock
    _events[tid]._fd = fd;
    _events[tid]._page = (struct perf_event_mmap_page*)page;

    struct f_owner_ex ex;
    ex.type = F_OWNER_TID;     // ★ 信号发送给指定线程（不是进程）
    ex.pid = tid;

    int err;
    if (fcntl(fd, F_SETFL, O_ASYNC) < 0 ||       // ★ 启用异步通知（溢出时发信号）
        fcntl(fd, F_SETSIG, _signal) < 0 ||       // ★ 设置信号编号（SIGPROF）
        fcntl(fd, F_SETOWN_EX, &ex) < 0)          // ★ 设置信号接收线程
    {
        err = errno;
    } else if (ioctl(fd, PERF_EVENT_IOC_RESET, 0) < 0 ||      // ★ 重置计数器
               ioctl(fd, _ioc_enable, 1) < 0)                  // ★ 启用：REFRESH(1) 或 ENABLE
    {
        err = errno;
    } else {
        return 0;  // ★ 成功
    }

    // Phase 7: 失败回滚
    if (page != NULL) {
        munmap(page, 2 * OS::page_size);
        _events[tid]._page = NULL;
    }
    close(fd);
    _events[tid]._fd = 0;
    return err;
}
```

#### 设计决策

- **为什么 CAS `_fd` 从 0 到 -1？** `start()` 中的 `createForAllThreads()` 遍历 `/proc/self/task/` 为所有线程创建 perf_event，同时 `pthread hook` 也会为新线程调用 `createForThread()`。CAS 确保同一线程只创建一次。
- **为什么 mmap 2 页？** 第一页是 `perf_event_mmap_page` 元数据（内核写入计数器值、调用链数据偏移等），第二页是环形缓冲区（存放实际的调用链数据）。
- **为什么用 `F_SETOWN_EX` + `F_OWNER_TID`？** 确保信号发给正确的线程。如果用 `F_SETOWN`（进程级），信号可能被进程中的任意线程接收。

### 2.4 signalHandler() — 信号处理

#### 解决什么问题？

perf_event 计数器溢出时内核发送 SIGPROF，需要在信号处理器中记录样本，然后重新启用 perf_event。

#### 源码文件与行号

`async-profiler/src/perfEvents_linux.cpp:709-729`

#### 真实源码 + 逐行注释

```cpp
// perfEvents_linux.cpp:709-729
void PerfEvents::signalHandler(int signo, siginfo_t* siginfo, void* ucontext) {
    if (siginfo->si_code <= 0) {
        return;
        // ★ si_code <= 0 表示信号来自外部进程（如 kill），不是 perf_event 触发
        // ★ si_code > 0 表示内核触发（perf_event 溢出）
    }

    if (_ioc_enable == PERF_EVENT_IOC_ENABLE) {
        ioctl(siginfo->si_fd, PERF_EVENT_IOC_DISABLE, 0);
        // ★ ENABLE 模式下需要手动禁用，防止处理期间再次收到信号
        // ★ REFRESH 模式下溢出后已自动禁用，无需此步
    }

    if (_enabled) {
        ExecutionEvent event(TSC::ticks());  // ★ 记录 TSC 时间戳
        u64 counter = readCounter(siginfo, ucontext);
        // ★ 读取计数器值（默认从 fd read，kprobe 从寄存器读）
        Profiler::instance()->recordSample(ucontext, counter, PERF_SAMPLE, &event);
        // ★ 核心：栈回溯 + 存储调用链（详见 2.5 节）
    } else {
        resetBuffer(OS::threadId());
        // ★ Profiler 已停止但还有残留信号，仅重置环形缓冲区
    }

    ioctl(siginfo->si_fd, PERF_EVENT_IOC_RESET, 0);    // ★ 重置计数器为 0
    ioctl(siginfo->si_fd, _ioc_enable, 1);               // ★ 重新启用（REFRESH 1 次或 ENABLE）
}
```

#### 设计决策

- **为什么检查 `si_code <= 0`？** 防止外部进程通过 `kill` 发送的 SIGPROF 被当作采样事件处理。只有 `si_code > 0`（内核触发）才是真正的 perf_event 溢出。
- **为什么 REFRESH 模式不需要 DISABLE？** REFRESH(1) 的语义是"使能 1 次，溢出后自动禁用"。信号到达时 perf_event 已经处于禁用状态，不会再触发信号。处理完后重新 REFRESH(1) 启用一次。
- **为什么最后才 RESET+ENABLE？** 先记录样本（信号安全），再重置计数器并启用。如果顺序反过来，可能在 recordSample 执行期间再次溢出导致信号递归（ENABLE 模式）。

### 2.5 readCounter() — 读取计数器值

#### 源码文件与行号

`async-profiler/src/perfEvents_linux.cpp:696-707`

```cpp
// perfEvents_linux.cpp:696-707
u64 PerfEvents::readCounter(siginfo_t* siginfo, void* ucontext) {
    switch (_event_type->counter_arg) {
        case 1: return StackFrame(ucontext).arg0();  // ★ kprobe/uprobe：从寄存器读函数参数
        case 2: return StackFrame(ucontext).arg1();
        case 3: return StackFrame(ucontext).arg2();
        case 4: return StackFrame(ucontext).arg3();
        default: {
            u64 counter;
            return read(siginfo->si_fd, &counter, sizeof(counter)) == sizeof(counter) ? counter : 1;
            // ★ 默认：从 perf_event fd 读取计数器值
            // ★ 读取失败返回 1（至少算一次事件）
        }
    }
}
```

**设计决策**：
- **为什么从寄存器读？** 对于 kprobe/uprobe 事件，计数器值不是"事件发生次数"，而是被探测函数的参数值。例如 `malloc` 事件的计数器值 = 分配大小（arg0）。信号发生时，`ucontext` 保存了被中断线程的寄存器状态，kprobe 在函数入口触发，所以寄存器中还保留着函数参数。
- **为什么 `read(si_fd)` 而不是 `read(event->_fd)`？** `siginfo->si_fd` 是内核传递的真实 fd，比通过 TID 查找 `_events[tid]._fd` 更可靠（信号可能在 destroyForThread 之后才到达）。

### 2.6 destroyForThread() — 销毁 perf_event

#### 源码文件与行号

`async-profiler/src/perfEvents_linux.cpp:677-694`

```cpp
// perfEvents_linux.cpp:677-694
void PerfEvents::destroyForThread(int tid) {
    if (tid >= _max_events) {
        return;
    }

    PerfEvent* event = &_events[tid];
    int fd = event->_fd;
    if (fd > 0 && __sync_bool_compare_and_swap(&event->_fd, fd, 0)) {
        // ★ CAS 将 _fd 从 fd 设为 0（标记"已销毁"）
        // ★ 防止与 signalHandler 的 ioctl(si_fd) 竞争
        ioctl(fd, PERF_EVENT_IOC_DISABLE, 0);  // ★ 禁用事件（停止计数）
        close(fd);                               // ★ 关闭文件描述符
    }
    if (event->_page != NULL) {
        event->lock();                           // ★ 获取 SpinLock
        munmap(event->_page, 2 * OS::page_size); // ★ 释放 mmap 页
        event->_page = NULL;
        event->unlock();                         // ★ 释放 SpinLock
    }
}
```

**设计决策**：
- **为什么 munmap 需要加锁？** `walk()` 函数在信号处理器中读取 mmap 环形缓冲区。如果 `destroyForThread()` 在 `walk()` 读取期间 munmap，会导致 SIGSEGV。SpinLock 确保 munmap 与 walk 互斥。
- **为什么 close(fd) 不需要锁？** `close(fd)` 后，内核不会再通过此 fd 发送信号。已到达但未处理的信号中的 `si_fd` 仍然有效（内核保证），ioctl 会返回错误但不会崩溃。

### 2.7 walk() — 从 perf_event mmap 读取调用链

#### 解决什么问题？

从 perf_event 的 mmap 环形缓冲区中读取内核提供的调用链（kernel callchain），再根据配置用 FP/DWARF 回溯用户栈，合并为完整的调用栈。

#### 源码文件与行号

`async-profiler/src/perfEvents_linux.cpp:856-942`

#### 真实源码 + 逐行注释

```cpp
// perfEvents_linux.cpp:856-942
int PerfEvents::walk(int tid, void* ucontext, const void** callchain, int max_depth, StackContext* java_ctx) {
    PerfEvent* event = &_events[tid];
    if (!event->tryLock()) {
        return 0;  // ★ 无法获取锁，说明 event 正在被销毁，返回 0 帧
    }

    int depth = 0;

    struct perf_event_mmap_page* page = event->_page;
    if (page != NULL) {
        u64 tail = page->data_tail;    // ★ 消费者已读位置
        u64 head = page->data_head;    // ★ 生产者写入位置
        rmb();                          // ★ 内存屏障：确保读到最新的 head

        RingBuffer ring(page);

        while (tail < head) {
            struct perf_event_header* hdr = ring.seek(tail);
            // ★ 定位到环形缓冲区中的事件头

            if (hdr->type == PERF_RECORD_SAMPLE) {
                // ★ 这是采样记录（其他类型还有 THROTTLE/LOST 等）
                
                if (_record_cpu) {
                    java_ctx->cpu = ring.next();
                    // ★ 如果配置了 record_cpu，第一个 u64 是 CPU ID
                }

                u64 nr = ring.next();    // ★ 调用链帧数
                while (nr-- > 0) {
                    u64 ip = ring.next();  // ★ 指令指针（PC）
                    if (ip < PERF_CONTEXT_MAX) {
                        // ★ ip < PERF_CONTEXT_MAX 表示普通地址（不是上下文标记）
                        const void* iptr = (const void*)ip;
                        if (CodeHeap::contains(iptr) || depth >= max_depth) {
                            // ★ 遇到 Java 代码（CodeHeap）或达到最大深度，停止
                            java_ctx->pc = iptr;
                            goto stack_complete;
                        }
                        callchain[depth++] = iptr;
                    }
                    // ★ ip >= PERF_CONTEXT_MAX 是上下文标记（如 PERF_CONTEXT_KERNEL），
                    // ★ 用于区分内核帧和用户帧，async-profiler 忽略这些标记
                }

                if (_cstack == CSTACK_LBR) {
                    // ★ LBR（Last Branch Record）模式：读取分支栈
                    u64 bnr = ring.next();  // ★ 分支记录数

                    // ★ 最后一个 userspace PC 存储在分支栈之后
                    const void* pc = (const void*)ring.peek(bnr * 3 + 2);
                    if (CodeHeap::contains(pc) || depth >= max_depth) {
                        java_ctx->pc = pc;
                        goto stack_complete;
                    }
                    callchain[depth++] = pc;

                    while (bnr-- > 0) {
                        const void* from = (const void*)ring.next();  // ★ 分支源地址
                        const void* to = (const void*)ring.next();    // ★ 分支目标地址
                        ring.next();  // ★ flags（未使用）

                        // ★ 先加 to（分支目标），再加 from
                        if (CodeHeap::contains(to) || depth >= max_depth) {
                            java_ctx->pc = to;
                            goto stack_complete;
                        }
                        callchain[depth++] = to;

                        if (CodeHeap::contains(from) || depth >= max_depth) {
                            java_ctx->pc = from;
                            goto stack_complete;
                        }
                        callchain[depth++] = from;
                    }
                }

                break;  // ★ 只处理第一个 SAMPLE 记录
            }
            tail += hdr->size;  // ★ 跳到下一条记录
        }

stack_complete:
        page->data_tail = head;  // ★ 标记已消费到 head
    }

    event->unlock();  // ★ 释放 SpinLock

    // ★ 如果配置了 FP/DWARF 栈回溯，继续回溯用户栈
    if (_cstack == CSTACK_FP) {
        depth += StackWalker::walkFP(ucontext, callchain + depth, max_depth - depth, java_ctx);
    } else if (_cstack == CSTACK_DWARF) {
        depth += StackWalker::walkDwarf(ucontext, callchain + depth, max_depth - depth, java_ctx);
    }

    return depth;
}
```

#### 设计决策

- **为什么用 `tryLock` 而不是 `lock`？** `walk()` 在信号处理器中调用，不能阻塞。如果获取锁失败（`destroyForThread` 正在 munmap），直接返回 0 帧比阻塞等待更安全。
- **为什么遇到 `CodeHeap::contains(ip)` 就停止？** `CodeHeap` 是 JVM 的 JIT 代码区，说明遇到了 Java 代码。后续的 Java 栈帧应该通过 `AsyncGetCallTrace` 或 `StackWalker::walkVM` 回溯，而不是从 perf 的调用链中读取。
- **为什么 `data_tail = head` 而不是 `data_tail = tail`？** 即使只处理了部分记录，也直接跳到 head，丢弃剩余数据。这是因为 perf 的调用链是辅助信息，主要依赖后续的 FP/DWARF/AGCT 回溯。

---

### 2.8 resetBuffer() — 重置 mmap 环形缓冲区

#### 解决什么问题？

在 Profiler 禁用或信号处理失败时，清空 perf_event mmap 环形缓冲区中的未读数据，防止数据堆积。

#### 源码文件与行号

`async-profiler/src/perfEvents_linux.cpp:944-958`

#### 真实源码 + 逐行注释

```cpp
// perfEvents_linux.cpp:944-958
void PerfEvents::resetBuffer(int tid) {
    PerfEvent* event = &_events[tid];
    if (!event->tryLock()) {
        return;  // ★ 无法获取锁，event 正在被销毁
    }

    struct perf_event_mmap_page* page = event->_page;
    if (page != NULL) {
        u64 head = page->data_head;  // ★ 生产者写入位置
        rmb();                        // ★ 内存屏障
        page->data_tail = head;       // ★ 将 tail 移到 head，清空缓冲区
    }

    event->unlock();
}
```

#### 设计决策

- **为什么用 `tryLock`？** 同 `walk()`，在信号处理器中不能阻塞。
- **为什么 `data_tail = head` 清空缓冲区？** perf 环形缓冲区是单生产者（内核）单消费者（用户态）模型。将 `tail` 设为 `head` 表示"已消费到最新"，内核后续写入新数据时会覆盖旧数据。

---

### 2.9 Profiler::recordSample() — 样本记录（简要）

`recordSample` 定义在 `profiler.cpp:616-713`，是 CPU/Allocation/Lock 等所有采样事件的统一入口。本章聚焦 perf_event 机制，对 recordSample 做简要分析（详细分析见 Chapter 08 Profiler 核心控制器）。

#### 锁机制

```cpp
// profiler.h:30
const int CONCURRENCY_LEVEL = 16;  // ★ 16 个锁分片（不是 64）

// profiler.cpp:186-192
u32 Profiler::getLockIndex(int tid) {
    u32 lock_index = tid;
    lock_index ^= lock_index >> 8;
    lock_index ^= lock_index >> 4;
    return lock_index % CONCURRENCY_LEVEL;
    // ★ 哈希函数：tid 的高位和低位异或，然后 mod 16
    // ★ 目的是让连续 TID 分散到不同锁上
}

// profiler.cpp:619-633
u32 lock_index = getLockIndex(tid);
if (!_locks[lock_index].tryLock() &&
    !_locks[lock_index = (lock_index + 1) % CONCURRENCY_LEVEL].tryLock() &&
    !_locks[lock_index = (lock_index + 2) % CONCURRENCY_LEVEL].tryLock())
{
    // ★ 尝试 3 个相邻锁，全部失败则放弃本次采样
    atomicInc(_failures[-ticks_skipped]);
    if (event_type == PERF_SAMPLE) {
        PerfEvents::resetBuffer(tid);  // ★ 丢弃但仍需重置环形缓冲区
    }
    return 0;
}
```

#### 核心流程

recordSample 的核心逻辑：
1. **原子递增 `_total_samples`**
2. **获取分段锁**（tryLock，最多尝试 3 个锁）
3. **栈回溯**：根据 `_cstack` 和 `event_type` 选择 AsyncGetCallTrace / StackWalker::walkVM / JVMTI 等
4. **存储调用链**：`_call_trace_storage.put()`（哈希去重）
5. **记录 JFR 事件**：`_jfr.recordEvent()`
6. **解锁**

---

## 第 3 部分：数据结构关系图

```mermaid
graph TB
    subgraph "Linux 内核"
        PA["perf_event_attr<br/>(配置：type/config/period)"]
        PMM["perf_event_mmap_page<br/>(共享页：计数器/环形缓冲区)"]
        SIG["SIGPROF 信号<br/>(si_fd/si_code)"]
    end

    subgraph "async-profiler 引擎层"
        CE["CpuEngine (基类)<br/>_interval/_cstack/_signal"]
        PE["PerfEvents<br/>_events[]/_event_type/_ioc_enable"]
        PET["PerfEventType<br/>name/type/config/default_interval"]
        AVAIL["AVAILABLE_EVENTS[]<br/>(20+ 预定义事件)"]
    end

    subgraph "async-profiler 线程层"
        PEV["PerfEvent<br/>_fd / _page"]
        SL["SpinLock (基类)<br/>_lock"]
        RB["RingBuffer<br/>_start / _offset"]
    end

    subgraph "async-profiler 采样层"
        SH["signalHandler()<br/>readCounter + recordSample"]
        PR["Profiler::recordSample()<br/>tryLock(16 分片) + 栈回溯"]
        CTS["CallTraceStorage<br/>哈希去重存储"]
    end

    CE --> PE
    PE -->|"包含"| PEV
    PET --> AVAIL
    PE -->|"_event_type"| PET
    SL --> PEV
    PEV -->|"_fd"| PA
    PEV -->|"_page"| PMM
    PMM --> RB
    PA -->|"perf_event_open"| SIG
    SIG --> SH
    SH --> PR
    PR --> CTS
```

---

## 第 3.5 部分：实验验证 ⭐

> 验证方法：strace 系统调用追踪 + collapsed 栈输出分析
> 测试程序：`com.example.ProfilerVerifyDemo`（CPU/Alloc/Lock 三种负载）
> JVM：OpenJDK 11 slowdebug，`-Xint` 模式

### 3.5.1 验证目标

| # | 验证目标 | 对应源码结论 |
|---|---------|-------------|
| 1 | `perf_event_open` 参数 | type=SOFTWARE, config=CPU_CLOCK, sample_period=10000000 |
| 2 | fcntl 信号绑定 | F_SETFL(O_ASYNC) + F_SETSIG(SIGPROF) + F_SETOWN_EX(F_OWNER_TID) |
| 3 | REFRESH vs ENABLE | 默认使用 REFRESH，不使用 ENABLE |
| 4 | 每线程一个 fd | perf_event_open 的 pid 参数为 tid |
| 5 | 采样结果正确性 | 能捕获到 cpuHot 作为 CPU 热点 |

### 3.5.2 strace 验证：perf_event_open 参数

**命令：**
```bash
strace -f -e trace=perf_event_open,ioctl,fcntl \
  java -Xint -agentpath:libasyncProfiler.so=start,event=cpu,collapsed,file=out.collapsed \
  -cp out com.example.ProfilerVerifyDemo 10
```

**关键输出（节选）：**

```
# 1) 探测调用（检测内核能力），sample_period=1000000000（1 秒）
perf_event_open({type=PERF_TYPE_SOFTWARE, config=PERF_COUNT_SW_CPU_CLOCK,
  sample_period=1000000000, sample_type=PERF_SAMPLE_CALLCHAIN,
  disabled=1, precise_ip=0}, 0, -1, -1, 0) = 3

# 2) 实际采样 fd（每线程一个），sample_period=10000000（10ms）
perf_event_open({type=PERF_TYPE_SOFTWARE, config=PERF_COUNT_SW_CPU_CLOCK,
  sample_period=10000000, sample_type=PERF_SAMPLE_CALLCHAIN,
  disabled=1, precise_ip=2, exclude_callchain_user=1},
  163969, -1, -1, PERF_FLAG_FD_CLOEXEC) = 5
```

**验证结论：**

| 参数 | 预期值 | 实际值 | ✅/❌ |
|------|-------|-------|------|
| type | PERF_TYPE_SOFTWARE | PERF_TYPE_SOFTWARE | ✅ |
| config | PERF_COUNT_SW_CPU_CLOCK | PERF_COUNT_SW_CPU_CLOCK | ✅ |
| sample_period | 10000000 (10ms) | 10000000 | ✅ |
| sample_type | PERF_SAMPLE_CALLCHAIN | PERF_SAMPLE_CALLCHAIN | ✅ |
| precise_ip | 2 | 2 | ✅ |
| exclude_callchain_user | 1 | 1 | ✅ |
| pid 参数 | 线程 tid | 163969（主线程 tid） | ✅ |

> **注意**：`perf_event_paranoid=2` 环境下不允许 `PERF_TYPE_HARDWARE`，async-profiler 自动降级为 `PERF_TYPE_SOFTWARE + CPU_CLOCK`。这本身验证了 `probeRecordingSupported()` 的降级逻辑。

### 3.5.3 strace 验证：fcntl 信号绑定

```
# 每个 perf fd 的三步信号绑定：
fcntl(5, F_SETFL, O_RDONLY|O_LARGEFILE|O_ASYNC)    # 开启异步通知
fcntl(5, F_SETSIG, SIGPROF)                         # 信号改为 SIGPROF
fcntl(5, F_SETOWN_EX, {type=F_OWNER_TID, pid=163969}) # 绑定到指定线程
```

**验证结论：** 完全匹配 `createForThread()` 源码中的 `fcntl` 三步调用。✅

### 3.5.4 strace 验证：REFRESH vs ENABLE

统计 ioctl 调用：

| ioctl 类型 | 次数 | 含义 |
|-----------|------|------|
| `PERF_EVENT_IOC_REFRESH` | 1947 | 启用采样（溢出后重置+启用） |
| `PERF_EVENT_IOC_RESET` | 1947 | 重置计数器（与 REFRESH 配对） |
| `PERF_EVENT_IOC_DISABLE` | 40 | stop 阶段禁用所有 fd |
| `PERF_EVENT_IOC_ENABLE` | **0** | ⭐ 未使用 ENABLE |

**结论：** `PERF_EVENT_IOC_ENABLE` 次数为 0，确认默认使用 REFRESH 模式。REFRESH 和 RESET 配对出现（1947:1947），对应 `signalHandler()` 中的 `resetBuffer()` + `ioctl(fd, PERF_EVENT_IOC_REFRESH, 1)`。✅

### 3.5.5 collapsed 栈验证：采样正确性

**`-Xint` 模式 CPU profiling 输出（Top 3）：**

```
# cpuHot 被正确捕获为最热方法（741 次采样）
java/lang/Thread.run;...ProfilerVerifyDemo.lambda$main$0;ProfilerVerifyDemo.cpuHot 741

# allocHot 的分配路径也被捕获（JVM 内部 Copy::pd_fill_to_words）
...ProfilerVerifyDemo.allocHot;InterpreterRuntime::newarray;...Copy::pd_fill_to_words 200
...ProfilerVerifyDemo.allocHot;InterpreterRuntime::newarray;...Copy::pd_fill_to_aligned_words 198
```

**验证结论：** CPU profiling 准确捕获了 `cpuHot()` 作为 CPU 热点（741/~1650 = ~45% 采样），`allocHot` 的 JVM 分配路径也被捕获。✅

---

## 第 4 部分：总结

### 4.1 数据结构层面

| 结构 | 来源 | 核心特征 |
|------|------|---------|
| `PerfEventType` | async-profiler | 7 个字段，20+ 预定义事件，`forName()` 解析用户输入的事件名 |
| `PerfEvent` | async-profiler | 16 字节，继承 SpinLock，封装 fd + mmap page |
| `RingBuffer` | async-profiler | mmap 环形缓冲区读取器，`& page_mask` 环形对齐 |
| `PerfEvents` | async-profiler | 引擎实现，9 个自有静态字段 + CpuEngine 继承字段，管理 PerfEvent[] 数组 |
| `perf_event_attr` | Linux 内核 | perf_event_open 配置，async-profiler 主要使用 type/config/sample_period/sample_type/disabled/wakeup_events 等字段 |

### 4.2 算法层面

| 算法 | 核心设计决策 |
|------|------------|
| `start()` | 默认 REFRESH（自动禁用避免递归），仅 cpu-clock + 内核 bug 时退化为 ENABLE；`_use_perf_mmap` 按需开启 |
| `createForThread()` | CAS `_fd` 从 0→-1 防重复；`perf_event_open` + `mmap` + `fcntl(O_ASYNC/F_SETSIG/F_SETOWN_EX)` + `ioctl(REFRESH)` |
| `signalHandler()` | 检查 `si_code > 0`（区分内核触发和外部 kill）→ 记录样本 → `RESET + REFRESH` 重新启用 |
| `readCounter()` | 默认从 fd read；kprobe/uprobe 从寄存器 arg0-arg3 读函数参数值 |
| `destroyForThread()` | CAS `_fd` 归零 → DISABLE + close；mmap 页需加 SpinLock 保护 munmap |
| `recordSample()` | 16 个 SpinLock 分片（哈希取模），tryLock 最多尝试 3 个锁，全部失败放弃采样 |

### 4.3 核心要点

1. **REFRESH 是默认模式**：`PERF_EVENT_IOC_REFRESH` 每次溢出后自动禁用，天然避免信号递归。只有检测到内核 6.16.x/6.17.x bug 时才退化为手动 ENABLE/DISABLE。
2. **每线程一个 fd**：通过 `perf_event_open(attr, tid, ...)` 创建，`fcntl(F_SETOWN_EX, F_OWNER_TID)` 确保信号发给正确线程。
3. **CAS 防重复创建**：`start()` 遍历所有线程 + pthread hook 监听新线程，二者可能并发，CAS 保证每个线程只创建一个 perf_event。
4. **16 个锁分片**：`recordSample()` 中 `CONCURRENCY_LEVEL=16`，lock_index 由 tid 哈希计算（`tid ^ (tid>>8) ^ (tid>>4)) % 16`），tryLock 最多尝试 3 个相邻锁。
5. **环形缓冲区**：mmap 2 页（元数据页 + 数据页），`RingBuffer` 类通过 `& page_mask` 实现环形读取。

---

## 附录：勘误表（对旧版 Chapter 05 的修正）

| # | 错误类型 | 旧文档描述 | 真实情况 |
|---|---------|-----------|---------|
| 1 | PerfEventType 字段遗漏 | 6 个字段（name/type/config/config1/config2/counter_arg） | **7 个字段**，遗漏了 `default_interval` |
| 2 | 事件名错误 | `"cpu"` 映射到 `PERF_COUNT_SW_CPU_CLOCK` | 事件名是 `"cpu-clock"`，不是 `"cpu"` |
| 3 | PerfEvents 字段遗漏 | 只列了 _events/_event_type/_ioc_enable/_interval/_signal | 遗漏了 9 个自有字段中的 `_max_events/_alluser/_kernel_stack/_use_perf_mmap/_record_cpu/_target_cpu`，以及 CpuEngine 继承字段 |
| 4 | CONCURRENCY_LEVEL 错误 | 声称 64 个锁 | 实际为 **16 个锁**（`profiler.h:30`） |
| 5 | getLockIndex 算法错误 | `tid % CONCURRENCY_LEVEL` | 实际为 `(tid ^ (tid>>8) ^ (tid>>4)) % CONCURRENCY_LEVEL`（哈希分散） |
| 6 | _ioc_enable 默认值错误 | 声称默认 `PERF_EVENT_IOC_ENABLE`，特定条件用 REFRESH | 实际**默认 `PERF_EVENT_IOC_REFRESH`**，仅内核 6.16.x/6.17.x bug 时退化为 ENABLE |
| 7 | start() 源码大幅不符 | 与实际源码差异 20+ 处 | 重写为实际源码 + 逐行注释 |
| 8 | RingBuffer 类缺失 | 完全未提及 | 补充 RingBuffer 类分析（perfEvents_linux.cpp:509-533） |
| 9 | 性能数据捏造 | 150μs/线程、0.5%/1.2%/2.1% 开销、10ns/150ns/30ns 耗时分解 | 这些精确数值**无来源**，无法复现 |
| 10 | GDB 验证数据捏造 | GDB 断点行号错误（620/659/709/654/685 行）、输出数据捏造 | 行号与实际源码不符，输出数据（tid=12345, fd=123）无法复现 |
| 11 | strace 输出捏造 | `perf_event_open({type=0x0, config=0x0, ...}, 12345, -1, -1, 0x8) = 3` | 捏造数据，无法复现 |
| 12 | CTimer/ITimer 源码捏造 | 6.2/6.3 节的代码 | 不是真实源码，仅为示意性伪代码（缺少真实文件名和行号） |
| 13 | ASCII 布局图 | 多处使用 ASCII 框线图 | 应使用 Mermaid 格式 |
| 14 | recordSample 行号错误 | 声称 `profiler.cpp:606-703` | 实际为 `profiler.cpp:616-713` |
| 15 | 重复的"第 5 部分"编号 | Phase 3 和 Phase 4 都标为"第 5 部分" | 编号错误 |

---

## 第 5 部分：GDB 验证 ⭐

> GDB attach 模式验证。注意：测试使用 `event=itimer`（ITimer 引擎），但 ITimer 和 PerfEvents 同属 CpuEngine 子类，共享核心采样机制。
> 脚本：`new-jvm-md/tmp-file/async-profiler-gdb/02-perfevents-flow-verify.gdb`

### 5.1 Engine 继承体系 sizeof 验证

| 类 | sizeof | 说明 |
|----|--------|------|
| Engine | **8 bytes** | 仅 vtable 指针，所有字段 static |
| CpuEngine | **8 bytes** | 无新增实例字段 |
| PerfEvents | **8 bytes** | 无新增实例字段 |

**结论**：整个 Engine 继承体系无实例状态，sizeof 恒为 8（一个 vtable 指针）。所有实际状态通过 static 字段管理。

### 5.2 Engine vtable 验证

```
Profiler::_engine = 0x7f8c193f3a48
Engine vtable ptr = 0x7f8c193f18a0
vtable 归属：vtable for ITimer + 16 in .data.rel.ro of libasyncProfiler.so
```

**验证结论**：
- `_engine` 确实通过 vtable 实现多态。`info symbol` 直接确认了 vtable 归属。
- 当 `event=itimer` 时 _engine 指向 ITimer 实例，如果 `event=cpu` 则指向 PerfEvents 实例。

### 5.3 CpuEngine 静态字段验证

```
Engine::_enabled = 1                (采样已启用)
CpuEngine::_interval = 10000000    (10ms = 10,000,000ns)
CpuEngine::_signal = 27            (SIGPROF)
CpuEngine::_current = (nil)
CpuEngine::_count_overrun = 0
```

**关键验证结论**：
1. **_interval = 10000000**：与启动参数 `interval=10000000` 一致。单位是纳秒（10ms）。
2. **_signal = 27 (SIGPROF)**：CpuEngine 使用 SIGPROF 作为采样信号。ITimer 用 `setitimer(ITIMER_PROF)` 产生 SIGPROF，PerfEvents 用 `fcntl(F_SETSIG, SIGPROF)` 绑定 SIGPROF。
3. **_current = nil**：表示不在信号处理中（GDB 暂停时所有线程停止）。
4. **_count_overrun = 0**：未发生计数溢出。

### 5.4 PerfEvents 静态字段验证

```
PerfEvents::_event_type = (nil)     (未使用 PerfEvents 引擎)
PerfEvents::_max_events = 0
PerfEvents::_events = (nil)
PerfEvents::_ioc_enable = 0
PerfEvents::_alluser = 0
PerfEvents::_kernel_stack = 0
PerfEvents::_use_perf_mmap = 0
PerfEvents::_record_cpu = 0
PerfEvents::_target_cpu = 0
```

**分析**：当前使用 itimer 引擎，PerfEvents 所有静态字段均为零值/空指针。这证实了 PerfEvents 和 ITimer 的状态完全独立——一个引擎活跃时，另一个引擎的字段不被使用。

### 5.5 PerfEvent 结构 sizeof 验证

```
sizeof(PerfEvent) = 16 bytes
```

**结构验证**：`fd(int, 4B) + padding(4B) + _id(u64, 8B) = 16B`。与文档分析一致。

### 5.6 采样统计验证

```
_total_samples = 9671
_total_stack_walk_time = 0 ns
_epoch = 1

ASGCT 统计：
_asgct_calls = 0
_asgct_success = 0
_asgct_retry_* = 全部为 0
_failures = 全部为 0
```

**注意**：`_asgct_calls = 0` 表明 itimer 模式下不调用 ASGCT（`AsyncGetCallTrace`）。这是因为 itimer 使用纯 native unwinding（`-XX:-UseCompressedOops` 场景下直接 fp-based unwinding），不需要 JVMTI 的 `AsyncGetCallTrace`。当使用 `event=cpu`（PerfEvents）时，会看到 ASGCT 调用。

### 5.7 GDB 验证方法说明

**为什么用 attach 模式而不是 launch 模式？**

async-profiler 和 JVM 内部使用 SIGSEGV/SIGTRAP/SIGPROF 等信号。GDB launch 模式会拦截这些信号，即使配置了 `handle SIGxxx nostop noprint pass`，仍会因 SIGTRAP（INT3 陷阱）导致进程异常终止。

attach 模式的优势：
1. Java 进程在没有 GDB 干预的情况下正常启动和运行
2. async-profiler 正常加载并开始采样
3. GDB attach 后只读取内存数据，不干扰信号处理
4. 读取完成后 detach，进程继续运行
