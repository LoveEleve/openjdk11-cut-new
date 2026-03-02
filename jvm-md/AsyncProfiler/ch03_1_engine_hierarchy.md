# 3.1 Engine 继承层次 — 统一采样 / 追踪引擎体系

> 源文件: `engine.h` (58行), `engine.cpp` (17行), `cpuEngine.h` (53行), `cpuEngine.cpp` (133行)
> 关联: `profiler.h`/`profiler.cpp` — 引擎管理, `arguments.h` — 事件掩码与配置
> 前置章节: 1.1~1.3 Agent 加载, 2.1~2.3 VMStructs

## 核心问题

**async-profiler 支持 CPU 采样、内存分配追踪、锁竞争追踪、Wall Clock 等多种 profiling 模式。这些模式底层机制完全不同（信号驱动 vs JVMTI 回调 vs GOT Hook），如何用统一的接口管理？**

答案：**经典的模板方法模式 + 全局静态实例 + 位掩码多事件并行**。

---

## 一、继承层次全景图

```
                        Engine                         ← 基类：type/title/units/start/stop
                       /      \
                      /        \
              CpuEngine          直接子类（5个）
            /    |    \          ├── WallClock        ← 独立采样线程
           /     |     \         ├── AllocTracer      ← SIGTRAP 断点
      PerfEvents CTimer ITimer   ├── LockTracer       ← JVMTI 监视器事件 + JNI Hook
                                 ├── MallocTracer     ← GOT Patching
                                 ├── NativeLockTracer ← GOT Patching
                                 ├── ObjectSampler    ← JVMTI SampledObjectAlloc
                                 └── Instrument       ← 字节码注入
```

### 为什么有 CpuEngine 这个中间层？

PerfEvents、CTimer、ITimer 三个引擎虽然底层机制不同，但有完全相同的**上层行为**：

1. **信号驱动采样**：都通过某种信号（SIGPROF/SIGALRM/自定义）触发采样
2. **线程感知**：都需要 hook `pthread_setspecific` 来感知新线程的创建/销毁
3. **统一信号处理器**：都调用 `Profiler::recordSample()` 记录采样

CpuEngine 把这些共性提取出来，子类只需实现 `createForThread()` 和 `destroyForThread()`。

---

## 二、Engine 基类 — 极简接口

```cpp
class Engine {
  protected:
    static volatile bool _enabled;       // 全局开关，信号处理器中检查

    static bool updateCounter(volatile unsigned long long& counter,
                              unsigned long long value,
                              unsigned long long interval);

  public:
    virtual const char* type()  { return "noop"; }
    virtual const char* title() { return "Flame Graph"; }
    virtual const char* units() { return "total"; }

    virtual Error start(Arguments& args);
    virtual void stop();

    void enableEvents(bool enabled) { _enabled = enabled; }
};
```

### 五个虚方法

| 方法 | 作用 | 使用场景 |
|------|------|---------|
| `type()` | 引擎标识符 | `selectEngine()` 比较、日志输出 |
| `title()` | 火焰图标题 | 输出 HTML/JFR 时的标题 |
| `units()` | 计量单位 | "ns" / "bytes" / "calls" |
| `start()` | 启动引擎 | `Profiler::start()` 调用 |
| `stop()` | 停止引擎 | `Profiler::stop()` 调用 |

### updateCounter — CAS 采样降频

```cpp
static bool updateCounter(volatile unsigned long long& counter,
                          unsigned long long value,
                          unsigned long long interval) {
    if (interval <= 1) {
        return true;  // 每次都采样
    }
    while (true) {
        unsigned long long prev = counter;
        unsigned long long next = prev + value;
        if (next < interval) {
            if (__sync_bool_compare_and_swap(&counter, prev, next)) {
                return false;  // 还没到间隔，不采样
            }
        } else {
            if (__sync_bool_compare_and_swap(&counter, prev, next % interval)) {
                return true;   // 到达间隔，触发采样
            }
        }
    }
}
```

**设计要点**：

1. **CAS 无锁**：多线程并发调用时不需要互斥（信号处理器中不能持锁）
2. **累加而非计数**：`value` 可以是字节数、纳秒数等非整数增量
3. **取模重置**：`next % interval` 把多余的部分带入下一轮，避免丢失计数

**使用场景**：

| 引擎 | counter | value | interval | 含义 |
|------|---------|-------|----------|------|
| AllocTracer | `_allocated_bytes` | `total_size` | `_interval` | 每分配 N 字节采样一次 |
| MallocTracer | `_allocated_bytes` | `size` | `_interval` | 每 malloc N 字节采样一次 |
| LockTracer | `_total_duration` | `duration` | `_interval` | 每等锁 N 纳秒采样一次 |
| NativeLockTracer | `_total_duration` | `duration_ticks` | `_interval` | 每等原生锁 N ticks 采样一次 |

---

## 三、CpuEngine 中间层 — CPU 采样的公共逻辑

### 3.1 线程生命周期 Hook

**问题**：CPU 采样需要为每个线程创建独立的 perf_event_fd 或 timer。新线程创建时必须立即配置，否则漏采。

**方案**：Hook libjvm 中的 `pthread_setspecific`，因为 HotSpot 在线程启动时一定会调用 `pthread_setspecific(tls_key, vmThread)` 来设置 TLS。

```cpp
// cpuEngine.cpp:27-48
static int pthread_setspecific_hook(pthread_key_t key, const void* value) {
    if (key != VMThread::key()) {
        return pthread_setspecific(key, value);  // 不是 JVM 线程，透传
    }
    if (pthread_getspecific(key) == value) {
        return 0;  // 重复设置，忽略
    }

    if (value != NULL) {
        // 线程启动：先设置 TLS，再通知引擎
        int result = pthread_setspecific(key, value);
        CpuEngine::onThreadStart();   // → createForThread(tid)
        return result;
    } else {
        // 线程结束：先通知引擎，再清除 TLS
        CpuEngine::onThreadEnd();     // → destroyForThread(tid)
        return pthread_setspecific(key, value);
    }
}
```

**关键顺序**：
- 启动时：**先设置 TLS 再 hook**——因为 `createForThread()` 可能需要读 TLS 来获取 JavaThread*
- 结束时：**先 hook 再清除 TLS**——因为 `destroyForThread()` 需要线程还活着

### 3.2 GOT Patching 安装 Hook

```cpp
bool CpuEngine::setupThreadHook() {
    if (_pthread_entry != NULL) return true;  // 已安装
    
    // 在 libjvm.so 的 GOT 表中找到 pthread_setspecific 的 PLT 入口
    CodeCache* lib = Profiler::instance()->findJvmLibrary("libj9thr");
    return lib != NULL && 
           (_pthread_entry = lib->findImport(im_pthread_setspecific)) != NULL;
}

void CpuEngine::enableThreadHook() {
    *_pthread_entry = (void*)pthread_setspecific_hook;  // 替换 GOT 表项
    __atomic_store_n(&_current, this, __ATOMIC_RELEASE); // 发布当前引擎
}

void CpuEngine::disableThreadHook() {
    *_pthread_entry = (void*)pthread_setspecific;        // 恢复原始函数
    __atomic_store_n(&_current, NULL, __ATOMIC_RELEASE);
}
```

### GDB 验证 — GOT Hook 前后对比

```
=== Thread Hook ===
_pthread_entry        = 0x7ffff75a97b0       ← libjvm.so GOT 表项地址
*_pthread_entry (前)  = 0x7ffff787c500       ← 原始 pthread_setspecific
*_pthread_entry (后)  = 0x7ffff7b3b57c       ← pthread_setspecific_hook
_current              = 0x7ffff7bf3a08       ← perf_events 实例
```

**`_pthread_entry` 指向哪里？** 它指向 `libjvm.so` 的 `.got.plt` 段中 `pthread_setspecific` 的 GOT 条目。原本这个条目指向 glibc 的 `pthread_setspecific`，hook 后指向 async-profiler 的 hook 函数。

### 3.3 信号处理器

```cpp
void CpuEngine::signalHandler(int signo, siginfo_t* siginfo, void* ucontext) {
    if (!_enabled) return;

    ExecutionEvent event(TSC::ticks());
    u64 total_cpu_time = _count_overrun 
        ? u64(_interval) * (1 + OS::overrun(siginfo))  // 计算累积溢出
        : u64(_interval);
    Profiler::instance()->recordSample(ucontext, total_cpu_time, EXECUTION_SAMPLE, &event);
}
```

**`OS::overrun(siginfo)`**：当系统负载高时，定时器可能触发多次但只收到一个信号。`si_overrun` 字段记录了累积的溢出次数。`_count_overrun` 由 CTimer/ITimer 设置（PerfEvents 不需要，因为它的信号不会合并）。

### 3.4 createForAllThreads — 全量遍历

```cpp
int CpuEngine::createForAllThreads() {
    int result = EPERM;
    ThreadList* thread_list = OS::listThreads();  // 读取 /proc/self/task/
    while (thread_list->hasNext()) {
        int tid = thread_list->next();
        int err = createForThread(tid);    // 子类实现
        if (isResourceLimit(err)) {
            result = err;
            break;                          // EMFILE/ENOMEM 时提前退出
        } else if (result != 0) {
            result = err;
        }
    }
    delete thread_list;
    return result;
}
```

---

## 四、12 个全局引擎实例

```cpp
// profiler.cpp:54-67
static Engine noop_engine;            // 空操作（默认值）
static PerfEvents perf_events;        // perf_event_open 采样
static AllocTracer alloc_tracer;      // TLAB 分配追踪（SIGTRAP）
static MallocTracer malloc_tracer;    // native malloc 追踪（GOT Hook）
static LockTracer lock_tracer;        // Java 锁竞争追踪（JVMTI）
static NativeLockTracer native_lock_tracer;  // pthread_mutex 追踪（GOT Hook）
static ObjectSampler object_sampler;  // JDK 16+ SampledObjectAlloc
static J9ObjectSampler j9_object_sampler;    // OpenJ9 分配采样
static WallClock wall_clock;          // Wall clock 采样（独立线程）
static J9WallClock j9_wall_clock;     // OpenJ9 Wall clock
static CTimer ctimer;                 // CLOCK_THREAD_CPUTIME_ID 定时器
static ITimer itimer;                 // setitimer(ITIMER_PROF) 定时器
static Instrument instrument;         // Java 方法字节码注入
```

### 为什么全部是 static 全局变量？

1. **全局唯一**：每个引擎只需一个实例
2. **生命周期与 SO 一致**：随 `libasyncProfiler.so` 的加载/卸载而创建/销毁
3. **零分配**：不占堆内存，不需要 malloc

### GDB 验证 — 12 个引擎的地址布局

```
noop_engine     = 0x7ffff7bf3a00  type=noop
perf_events     = 0x7ffff7bf3a08  type=perf_events
alloc_tracer    = 0x7ffff7bf3a10  type=alloc_tracer
malloc_tracer   = 0x7ffff7bf3a18  type=malloc_tracer
lock_tracer     = 0x7ffff7bf3a20  type=lock_tracer
ctimer          = 0x7ffff7bf3a40  type=ctimer
itimer          = 0x7ffff7bf3a48  type=itimer
wall_clock      = 0x7ffff7bfc740  type=wall
instrument      = 0x7ffff7bf3a50  type=instrument
```

**观察**：除了 `wall_clock`（它有 `pthread_t` 等大字段），其余引擎都紧密排列在 BSS 段中，每个只占 8 字节（虚表指针）。

---

## 五、selectEngine — 事件名到引擎的路由

```cpp
Engine* Profiler::selectEngine(const char* event_name) {
    if (event_name == NULL) {
        return &noop_engine;                         // 无事件
    } else if (strcmp(event_name, EVENT_CPU) == 0) {  // "cpu"
        if (FdTransferClient::hasPeer() || PerfEvents::supported()) {
            return &perf_events;                     // 首选 perf_events
        } else if (CTimer::supported()) {
            return &ctimer;                          // 退化到 ctimer
        } else {
            return &wall_clock;                      // 最后退化到 wall clock
        }
    } else if (strcmp(event_name, EVENT_WALL) == 0) { // "wall"
        return VM::isOpenJ9() ? &j9_wall_clock : &wall_clock;
    } else if (strcmp(event_name, EVENT_CTIMER) == 0) {
        return &ctimer;
    } else if (strcmp(event_name, EVENT_ITIMER) == 0) {
        return &itimer;
    } else if (strchr(event_name, '.') != NULL && strchr(event_name, ':') == NULL) {
        return &instrument;                          // 包含 '.' 但不含 ':' → 方法名
    } else {
        return &perf_events;                         // 其他 → PMU 事件名
    }
}
```

### CPU 事件的三级降级策略

```
event=cpu
  ├── perf_events 可用？ → PerfEvents (perf_event_open)
  │     ↓ 不可用（容器/权限）
  ├── ctimer 可用？ → CTimer (timer_create + CLOCK_THREAD_CPUTIME_ID)
  │     ↓ 不可用
  └── wall_clock → WallClock (pthread + tkill)
```

**为什么降级到 WallClock 而不是 ITimer？**

因为 WallClock 可以提供 wall-clock 语义的 CPU 使用，而 ITimer 是进程级的（不是线程级），信号只发给一个随机线程，采样不均匀。WallClock 主动遍历所有线程并逐个发信号，覆盖更全面。

### GDB 验证 — event=cpu 的选择

```
args._event = cpu
_event_mask will be = 0x1 (EM_CPU)
selected engine = 0x7ffff7bf3a08, type = perf_events
```

---

## 六、事件掩码 — 多引擎并行

```cpp
enum EventMask {
    EM_CPU          = 1,    // 主 CPU 采样引擎
    EM_ALLOC        = 2,    // 分配追踪
    EM_LOCK         = 4,    // 锁竞争追踪
    EM_WALL         = 8,    // Wall clock
    EM_NATIVEMEM    = 16,   // Native 内存追踪
    EM_NATIVELOCK   = 32,   // Native 锁追踪
    EM_METHOD_TRACE = 64    // Java 方法追踪
};
```

**多事件并行**：JFR 输出模式下可以同时启用多个事件（其他输出格式只能单事件）：

```bash
# 同时采集 CPU + 分配 + 锁，输出到 JFR
asprof start -e cpu --alloc 1m --lock 10ms -f profile.jfr <pid>
# event_mask = EM_CPU | EM_ALLOC | EM_LOCK = 0x7
```

### Profiler::start() 中的多引擎启动链

```
Profiler::start()
  │
  ├── _engine = selectEngine("cpu")          → PerfEvents
  ├── _engine->start(args)                   → perf_event_open for all threads
  │
  ├── (EM_ALLOC?) _alloc_engine->start()     → AllocTracer / ObjectSampler
  ├── (EM_LOCK?)  lock_tracer.start()        → JVMTI MonitorContended
  ├── (EM_WALL?)  wall_clock.start()         → 启动采样线程
  ├── (EM_NATIVEMEM?) malloc_tracer.start()  → GOT Hook malloc/free
  ├── (EM_NATIVELOCK?) native_lock_tracer.start()
  ├── (EM_METHOD_TRACE?) instrument.start()  → 字节码注入
  │
  ├── switchThreadEvents(JVMTI_ENABLE)       → 线程事件通知
  ├── _state = RUNNING
  └── startTimer()                           → 超时/循环定时器
```

### 错误回滚（goto 链）

`start()` 方法使用经典的 **goto 错误回滚** 模式：

```cpp
error = _engine->start(args);       if (error) goto error1;
error = _alloc_engine->start(args); if (error) goto error2;
error = lock_tracer.start(args);    if (error) goto error3;
error = wall_clock.start(args);     if (error) goto error4;
error = malloc_tracer.start(args);  if (error) goto error5;
error = native_lock_tracer.start(); if (error) goto error6;
error = instrument.start(args);     if (error) goto error7;

// 回滚链：
error7: if (EM_NATIVELOCK) native_lock_tracer.stop();
error6: if (EM_NATIVEMEM)  malloc_tracer.stop();
error5: if (EM_WALL)       wall_clock.stop();
error4: if (EM_LOCK)       lock_tracer.stop();
error3: if (EM_ALLOC)      _alloc_engine->stop();
error2: _engine->stop();
error1: uninstallTraps(); switchLibraryTrap(false); _jfr.stop();
```

这保证了：**无论哪个引擎启动失败，已启动的引擎都会被安全停止**。

---

## 七、Profiler 状态机

```
         NEW ──────── Agent_OnLoad / Agent_OnAttach
          │
          │  run("start")
          ↓
        IDLE ←──────── stop()
          │               ↑
          │  start()      │
          ↓               │
       RUNNING ───────── stop()
          │
          │  shutdown()
          ↓
      TERMINATED
```

| 状态 | 含义 | 允许操作 |
|------|------|---------|
| NEW | 刚创建，未初始化 | run() |
| IDLE | 已初始化，空闲 | start(), dump() |
| RUNNING | 正在采样 | stop(), dump(), flushJfr() |
| TERMINATED | JVM 即将退出 | 无 |

### CStack 选择策略

`_cstack` 控制**原生栈（C/C++ 帧）的回溯方式**：

```cpp
if (_cstack == CSTACK_DEFAULT) {
    if (VMStructs::hasStackStructs()) {
        _cstack = CSTACK_VM;        // 首选：使用 VMStructs 做混合模式栈回溯
    } else if (VM::isOpenJ9() && DWARF_SUPPORTED) {
        _cstack = CSTACK_DWARF;     // OpenJ9 没有帧指针，用 DWARF
    }
}
```

| CStack 模式 | 回溯方式 | 适用场景 |
|------------|---------|---------|
| `CSTACK_DEFAULT` | 自动选择 | 默认 |
| `CSTACK_NO` | 不采集原生帧 | 纯 Java 分析 |
| `CSTACK_FP` | Frame Pointer 回溯 | 编译时保留 FP |
| `CSTACK_DWARF` | DWARF unwind info | 无 FP 的库 |
| `CSTACK_LBR` | Last Branch Record | PMU 硬件栈 |
| `CSTACK_VM` | VMStructs 混合模式 | HotSpot 最佳选择 |

### GDB 验证 — CStack 自动选择

```
args._cstack = CSTACK_DEFAULT (0)
→ VMStructs::hasStackStructs() = true
→ 最终选择: CSTACK_VM
```

---

## 八、各引擎的采样/追踪机制对比

| 引擎 | 触发方式 | 信号 | 采样降频 | 线程感知 |
|------|---------|------|---------|---------|
| **PerfEvents** | perf_event_open + mmap | SIGPROF(自定义) | 硬件计数器 | GOT Hook pthread_setspecific |
| **CTimer** | timer_create(CLOCK_THREAD_CPUTIME_ID) | SIGPROF | 定时器溢出 | GOT Hook pthread_setspecific |
| **ITimer** | setitimer(ITIMER_PROF) | SIGPROF | 定时器溢出 | 无（进程级） |
| **WallClock** | 独立 pthread + tkill | WAKEUP/SIGURG | 固定间隔 | 遍历 /proc/self/task |
| **AllocTracer** | TLAB slowpath 断点 | SIGTRAP | updateCounter(bytes) | 不需要（TLAB 本身是线程私有） |
| **ObjectSampler** | JVMTI SampledObjectAlloc | 无（回调） | JVM 内置采样 | JVMTI 事件自动分发 |
| **LockTracer** | JVMTI MonitorContended + JNI Hook | 无（回调） | updateCounter(ns) | JVMTI 事件自动分发 |
| **MallocTracer** | GOT Hook malloc/free | 无（inline） | updateCounter(bytes) | 自动（所有线程共享 GOT） |
| **NativeLockTracer** | GOT Hook pthread_mutex_lock | 无（inline） | updateCounter(ticks) | 自动 |
| **Instrument** | 字节码注入 recordEntry/recordExit | 无（JNI 调用） | 计数取模 | 自动 |

---

## 九、引擎的生命周期管理

### start 阶段（从上到下）

```
1. Profiler::start()
2.   ├── selectEngine() → 选择主引擎
3.   ├── selectAllocEngine() → 选择分配引擎（如果启用）
4.   ├── _engine->start() → 主引擎启动
5.   ├── 按 event_mask 依次启动辅助引擎
6.   ├── switchThreadEvents(ENABLE)
7.   └── _state = RUNNING
```

### stop 阶段（从下到上，逆序停止）

```
1. Profiler::stop()
2.   ├── uninstallTraps()
3.   ├── 按 event_mask 逆序停止辅助引擎
4.   ├── _engine->stop() → 主引擎停止
5.   ├── switchThreadEvents(DISABLE)
6.   ├── stopTimer()
7.   ├── lockAll() → _jfr.stop() → unlockAll()
8.   └── _state = IDLE
```

### shutdown 阶段

```
1. Profiler::shutdown() — JVM 退出时调用
2.   ├── 如果 _nostop → 执行 stop 命令
3.   ├── 最终设置 _state = TERMINATED
4.   └── 此后不接受任何命令
```

---

## 十、总结

### 设计精髓

1. **模板方法模式**：Engine 基类定义 start/stop 骨架，子类实现具体机制
2. **CpuEngine 中间层**：提取 PerfEvents/CTimer/ITimer 的共性（线程 Hook + 信号处理器）
3. **全局静态实例**：零分配、生命周期简单、无所有权问题
4. **位掩码多事件**：单次 profiling 可以同时运行 CPU + Alloc + Lock + Wall
5. **三级降级**：`perf_events → ctimer → wall_clock`，保证在任何环境下都能工作
6. **goto 错误回滚**：C 风格但安全有效的多资源回滚
7. **updateCounter CAS**：信号安全的无锁采样降频

### 在整体架构中的位置

```
Agent 加载（Ch01）
  → VMStructs 初始化（Ch02）
  → 引擎体系（本节）← 你在这里
  → PerfEvents.start()（Ch04）
  → 信号到达 → recordSample（Ch05）
```

---

*创建日期: 2026-02-09*
*GDB 验证环境: OpenJDK 11 slowdebug + async-profiler v4.0*