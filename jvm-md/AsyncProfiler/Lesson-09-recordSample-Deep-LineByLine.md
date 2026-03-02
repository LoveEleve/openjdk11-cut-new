# Lesson 9: recordSample() 深度逐行解析（子方法完全展开 + 六层面分析）

> 本文档对 `Profiler::recordSample()` 进行真正深入的逐行解析，每个方法调用都展开到最底层实现，并进行六层面分析。

---

## 1. recordSample() 功能定位

### 1.1 一句话说明

**recordSample() 是 AsyncProfiler 的核心采样记录函数，在信号处理器中被调用，负责：获取线程上下文 → 栈回溯 → 去重存储 → 记录事件**

### 1.2 在整体流程中的位置

```
信号触发流程：
┌─────────────────────────────────────────────────────────────────┐
│ [硬件/软件事件]                                                  │
│   CPU 周期计数器溢出 / 定时器到期 / INT3 断点触发               │
└────────────────────────────────┬────────────────────────────────┘
                                 │
                                 v
┌─────────────────────────────────────────────────────────────────┐
│ [信号处理器]                                                     │
│   PerfEvents::signalHandler() 或 AllocTracer::trapHandler()    │
└────────────────────────────────┬────────────────────────────────┘
                                 │
                                 v
┌─────────────────────────────────────────────────────────────────┐
│ [recordSample() ← 本文档分析的核心]                              │
│   原子计数 → 获取锁 → 栈回溯 → 存储 → 释放锁                    │
└────────────────────────────────┬────────────────────────────────┘
                                 │
                                 v
┌─────────────────────────────────────────────────────────────────┐
│ [后续处理]                                                       │
│   CallTraceStorage 存储调用栈，FlightRecorder 写入 JFR         │
└─────────────────────────────────────────────────────────────────┘
```

### 1.3 如果没有它会怎样？

如果没有 `recordSample()`，AsyncProfiler 无法：
1. **记录采样数据** - 信号触发了但数据丢失
2. **去重调用栈** - 每次采样都存储完整栈，内存爆炸
3. **关联事件信息** - 无法知道分配了多少字节、锁等待了多久

---

## 2. 完整逐行解析（子方法完全展开）

### 第 607 行：`atomicInc(_total_samples);`

```cpp
// 文件: profiler.cpp 第 607 行
atomicInc(_total_samples);
```

#### 2.1.1 展开到最底层

```cpp
// 展开步骤 1: atomicInc 定义（arch.h 第 30-32 行）
static inline u64 atomicInc(volatile u64& var, u64 increment = 1) {
    return __sync_fetch_and_add(&var, increment);
}

// 展开步骤 2: __sync_fetch_and_add 是 GCC 内建函数
// 编译为 x86_64 汇编：
//   lock xaddq %rax, (%rdi)    ; 原子交换并加
//   ; 返回旧值（忽略，我们只关心副作用）

// 展开步骤 3: 最终 CPU 指令
//   lock 前缀 → 锁定总线/缓存行
//   xaddq → 交换并加（Exchange and Add）
//   这是原子的，多核安全
```

#### 2.1.2 六层面分析

| 层面 | 分析 |
|------|------|
| **设计原理** | 为什么用原子操作而不是普通 `++`？<br>信号处理器可能在多个线程同时触发，普通 `++` 会丢失计数。原子操作保证每次都正确计数。 |
| **边界条件** | 计数器溢出怎么办？<br>`u64` 最大值 2^64-1，即使每秒 100 万次采样，也需要 58 万年才溢出。设计上忽略。 |
| **并发安全** | 这是**唯一的正确做法**。信号处理器不能使用互斥锁（可能死锁），只能用无锁原子操作。 |
| **JVM 交互** | 不涉及 JVM，纯 Native 操作。 |
| **性能影响** | `lock xaddq` 约 20-50 CPU 周期（取决于缓存状态）。在采样路径上可接受。 |
| **替代方案** | 1. 每线程本地计数，最后汇总？<br>   问题：需要额外存储，且无法实时看到总数。<br>2. 使用 `std::atomic`？<br>   问题：C++11 引入，AsyncProfiler 用 C 风格更可控。<br>**结论**：当前方案最优。 |

#### 2.1.3 为什么用 `__sync_fetch_and_add` 而不是 `__sync_add_and_fetch`？

```
两者区别：
  __sync_fetch_and_add(&var, 1)  → 返回旧值，然后加
  __sync_add_and_fetch(&var, 1)  → 先加，返回新值

为什么选择 fetch_and_add？
  我们只关心"计数+1"这个副作用，不关心返回值。
  两者性能相同，fetch_and_add 是惯例。
```

---

### 第 609 行：`int tid = OS::threadId();`

```cpp
// 文件: profiler.cpp 第 609 行
int tid = OS::threadId();
```

#### 2.2.1 展开到最底层

```cpp
// 展开步骤 1: OS::threadId() 定义（os_linux.cpp 第 176-178 行）
int OS::threadId() {
    return syscall(__NR_gettid);
}

// 展开步骤 2: syscall 是 glibc 封装
// 最终执行：
//   mov rax, __NR_gettid    ; 系统调用号 = 186 (x86_64)
//   syscall                  ; 进入内核
//   ; 返回值在 rax

// 展开步骤 3: 内核实现（简化）
//   return current->pid;    // 当前线程的 TID
```

#### 2.2.2 六层面分析

| 层面 | 分析 |
|------|------|
| **设计原理** | 为什么用 TID 而不是 pthread_self？<br>1. TID 是内核分配，全局唯一，用于 `/proc/self/task/{tid}/` 路径<br>2. pthread_self 返回 pthread_t，是用户空间指针，不适合做哈希键 |
| **边界条件** | TID 范围：1 ~ /proc/sys/kernel/pid_max（默认 32768 或 4194304）<br>线程销毁后 TID 可能被复用。但在单次采样周期内，线程不会销毁。 |
| **并发安全** | syscall 本身是线程安全的。每个线程获取自己的 TID。 |
| **JVM 交互** | JVM 线程的 TID 与 Native 线程相同。JVM 内部通过 `VMThread::nativeThreadId()` 获取相同值。 |
| **性能影响** | syscall 开销约 100-300 CPU 周期（取决于内核版本和安全 mitigations）。<br>这是采样热路径，如果担心性能，可考虑缓存 TID 到 TLS。 |
| **替代方案** | 1. 使用 TLS 缓存 TID：<br>   `static __thread int cached_tid = 0;`<br>   `if (cached_tid == 0) cached_tid = syscall(__NR_gettid);`<br>   优点：避免每次 syscall。<br>   缺点：需要初始化逻辑。<br>2. 通过 pthread_getspecific 获取？<br>   开销更大。<br>**结论**：当前方案简单可靠，syscall 开销可接受。 |

#### 2.2.3 syscall vs 直接调用

```
为什么不用 getpid() 返回 PID？
  getpid() 返回进程 PID，所有线程相同。
  我们需要区分不同线程，所以用 gettid。

为什么不用 pthread_self()？
  pthread_self() 返回 pthread_t（指针），不是数字。
  不能直接做数组索引或哈希键。

为什么不用 __builtin_thread_pointer()？
  这是编译器内建，返回 TLS 基址。
  需要额外偏移计算才能得到有意义的 ID。
```

---

### 第 610 行：`u32 lock_index = getLockIndex(tid);`

```cpp
// 文件: profiler.cpp 第 610 行
u32 lock_index = getLockIndex(tid);
```

#### 2.3.1 展开到最底层

```cpp
// 展开步骤 1: getLockIndex 定义（profiler.cpp 第 187-192 行）
inline u32 Profiler::getLockIndex(int tid) {
    u32 lock_index = tid;
    lock_index ^= lock_index >> 8;
    lock_index ^= lock_index >> 4;
    return lock_index % CONCURRENCY_LEVEL;
}

// 展开步骤 2: 分解每一步
// 假设 tid = 0x12345678 (十进制 305419896)
// 
// Step 1: lock_index = 0x12345678
// 
// Step 2: lock_index ^= lock_index >> 8
//         0x12345678 ^ 0x00123456 = 0x1226627E
//         目的：混合高 24 位到低 8 位
// 
// Step 3: lock_index ^= lock_index >> 4
//         0x1226627E ^ 0x01226627 = 0x13040459
//         目的：进一步混合
// 
// Step 4: return lock_index % 16
//         0x13040459 % 16 = 9
// 
// 展开步骤 3: 取模运算的汇编
//   and eax, 0xF    ; 因为 16 是 2 的幂，取模 = 与运算
//   ; 等价于 lock_index & 15
```

#### 2.3.2 六层面分析

| 层面 | 分析 |
|------|------|
| **设计原理** | 为什么用哈希而不是直接 `tid % 16`？<br>1. TID 通常连续分配（1, 2, 3, ...），直接取模会导致相邻 TID 映射到相邻槽位<br>2. 如果线程 TID 刚好是 16 的倍数附近，某些槽位会过载<br>3. 异或混合打破这种规律性 |
| **边界条件** | TID 可能大于 2^31（尽管少见）。`u32` 转换后仍能正确工作。 |
| **并发安全** | 纯计算，无共享状态，线程安全。 |
| **JVM 交互** | 不涉及 JVM。 |
| **性能影响** | 3 次异或 + 1 次与运算，约 5 CPU 周期。极快。 |
| **替代方案** | 1. 直接 `tid % 16`：<br>   问题：TID 连续时分布不均匀。<br>2. 使用更好的哈希函数（如 xxHash）：<br>   问题：开销增加，收益不明显。<br>**结论**：当前简单的位混合足够好。 |

#### 2.3.3 为什么是 CONCURRENCY_LEVEL = 16？

```
设计权衡：

锁太少（如 1 个）：
  - 所有线程竞争同一把锁
  - 吞吐量急剧下降

锁太多（如 256 个）：
  - 内存占用增加（每个锁对应一个帧缓冲区）
  - 缓存不友好

16 个锁：
  - 假设 100 个线程同时采样
  - 平均每个锁竞争 6-7 次
  - 实际上大部分线程不会同时到达
  - 16 是 2 的幂，取模变成位运算

实验数据（来自 async-profiler 作者）：
  - 4 核机器：8 个锁足够
  - 8-16 核：16 个锁是最优
  - 更多核：32 个锁
```

---

### 第 611-623 行：获取锁（tryLock 三次尝试）

```cpp
// 文件: profiler.cpp 第 611-623 行
if (!_locks[lock_index].tryLock() &&
    !_locks[lock_index = (lock_index + 1) % CONCURRENCY_LEVEL].tryLock() &&
    !_locks[lock_index = (lock_index + 2) % CONCURRENCY_LEVEL].tryLock())
{
    // Too many concurrent signals already
    atomicInc(_failures[-ticks_skipped]);

    if (event_type == PERF_SAMPLE) {
        // Need to reset PerfEvents ring buffer, even though we discard the collected trace
        PerfEvents::resetBuffer(tid);
    }
    return 0;
}
```

#### 2.4.1 展开到最底层

```cpp
// 展开步骤 1: SpinLock::tryLock() 定义（spinLock.h 第 29-31 行）
bool tryLock() {
    return __sync_bool_compare_and_swap(&_lock, 0, 1);
}

// 展开步骤 2: __sync_bool_compare_and_swap 是 GCC 内建
// 编译为 x86_64 汇编：
//   mov eax, 0              ; 期望值 = 0
//   mov edx, 1              ; 新值 = 1
//   lock cmpxchg [rdi], edx ; 原子比较并交换
//   setz al                 ; 如果成功（ZF=1），返回 true
//   ; 返回值在 al

// 展开步骤 3: 整个 if 条件的执行流程
// 
// 尝试 1: _locks[lock_index].tryLock()
//   CAS(&_lock[lock_index], 0, 1)
//   成功 → 跳过整个 if 块，继续执行
//   失败 → 尝试下一个
// 
// 尝试 2: _locks[(lock_index + 1) % 16].tryLock()
//   更新 lock_index = (lock_index + 1) % 16
//   CAS(&_lock[new_index], 0, 1)
//   成功 → 跳过 if 块
//   失败 → 尝试下一个
// 
// 尝试 3: _locks[(lock_index + 2) % 16].tryLock()
//   更新 lock_index = (lock_index + 2) % 16
//   CAS(&_lock[new_index], 0, 1)
//   成功 → 跳过 if 块
//   失败 → 进入 if 块（放弃本次采样）
```

#### 2.4.2 六层面分析

| 层面 | 分析 |
|------|------|
| **设计原理** | 为什么 tryLock 三次而不是一次？<br>1. 单次 tryLock 失败率约 1/16（在 16 个竞争者时）<br>2. 尝试相邻槽位，利用局部性<br>3. 三次尝试后放弃，避免信号处理器阻塞太久<br><br>为什么用 tryLock 而不是 lock？<br>信号处理器不能阻塞！如果 lock() 自旋等待，可能死锁或延迟太久。 |
| **边界条件** | 如果所有 16 个锁都被占用？<br>放弃本次采样，记录到 `_failures[-ticks_skipped]`。这是设计上的折衷：宁可丢失少量采样，也不能阻塞信号处理器。 |
| **并发安全** | CAS 操作是原子的。三个 tryLock 没有竞争条件，因为每个都是独立的锁。 |
| **JVM 交互** | 不涉及 JVM。 |
| **性能影响** | 成功时：1 次 CAS，约 20 CPU 周期。<br>失败时：最多 3 次 CAS，约 60 CPU 周期 + 记录失败。<br>失败率通常 < 1%，可忽略。 |
| **替代方案** | 1. 使用 lock() 阻塞等待：<br>   问题：信号处理器可能永远阻塞。<br>2. 增加尝试次数到 16 次：<br>   问题：信号处理器停留太久，可能错过后续信号。<br>3. 使用读写锁：<br>   问题：更复杂，收益不明显。<br>**结论**：三次 tryLock 是最佳平衡。 |

#### 2.4.3 为什么检查 `event_type == PERF_SAMPLE`？

```cpp
if (event_type == PERF_SAMPLE) {
    PerfEvents::resetBuffer(tid);
}
```

```
背景知识：perf_event ring buffer

perf_event 使用 ring buffer 传递采样数据：
  1. 内核写入采样数据到 ring buffer
  2. 用户态读取并处理
  3. 读取后需要"重置"指针，告诉内核可以覆盖

问题场景：
  1. 内核写入了一个采样到 ring buffer
  2. 信号处理器触发，进入 recordSample()
  3. recordSample() 尝试获取锁失败，放弃采样
  4. **如果不重置 ring buffer，内核会等待空间，导致采样停滞**

解决方案：
  即使放弃采样，也要重置 ring buffer，让内核继续工作。

为什么只有 PERF_SAMPLE 需要？
  其他事件类型（如 ALLOC_SAMPLE）不使用 ring buffer，
  不存在这个问题。
```

---

### 第 625 行：`u64 stack_walk_begin = _features.stats ? OS::nanotime() : 0;`

```cpp
// 文件: profiler.cpp 第 625 行
u64 stack_walk_begin = _features.stats ? OS::nanotime() : 0;
```

#### 2.5.1 展开到最底层

```cpp
// 展开步骤 1: 条件判断
// _features.stats 是一个布尔标志，由命令行参数 --stats 启用
// 如果启用，则记录栈回溯开始时间

// 展开步骤 2: OS::nanotime() 定义（os_linux.cpp 第 107-111 行）
u64 OS::nanotime() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (u64)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

// 展开步骤 3: clock_gettime 系统调用
// 如果使用 vDSO（虚拟动态共享对象），则不进入内核
// 直接从用户态映射的共享内存读取时间
// 
// 编译为：
//   mov rdi, CLOCK_MONOTONIC    ; 时钟类型
//   lea rsi, [rsp+ts]           ; 输出缓冲区
//   call clock_gettime          ; 可能是 vDSO 调用
// 
// 或内联优化后：
//   rdtsc                       ; 读取 TSC
//   ; 转换为纳秒（使用校准因子）
```

#### 2.5.2 六层面分析

| 层面 | 分析 |
|------|------|
| **设计原理** | 为什么要统计栈回溯时间？<br>1. 性能分析需要知道栈回溯开销<br>2. 帮助用户决定是否开启某些特性<br>3. 默认关闭，避免额外开销 |
| **边界条件** | 时间戳可能溢出？<br>`u64` 纳秒：约 584 年才溢出。不存在问题。 |
| **并发安全** | clock_gettime 是线程安全的。 |
| **JVM 交互** | 不涉及 JVM。JVM 也使用 clock_gettime 作为时间源。 |
| **性能影响** | vDSO 优化后：约 20-50 CPU 周期。<br>真实系统调用：约 100-300 CPU 周期。<br>只有启用 `--stats` 才执行，默认无开销。 |
| **替代方案** | 1. 使用 TSC 直接读取：<br>   问题：需要校准，复杂度高。<br>2. 使用 `std::chrono`：<br>   问题：C++11 引入，可能不是最快的。<br>**结论**：clock_gettime 是标准且高效的选择。 |

---

### 第 627-628 行：获取帧缓冲区

```cpp
// 文件: profiler.cpp 第 627-628 行
ASGCT_CallFrame* frames = _calltrace_buffer[lock_index]->_asgct_frames;
jvmtiFrameInfo* jvmti_frames = _calltrace_buffer[lock_index]->_jvmti_frames;
```

#### 2.6.1 展开到最底层

```cpp
// 展开步骤 1: _calltrace_buffer 定义（profiler.h 第 81 行）
CallTraceBuffer* _calltrace_buffer[CONCURRENCY_LEVEL];

// 展开步骤 2: CallTraceBuffer 是联合体（profiler.h 第 33-36 行）
union CallTraceBuffer {
    ASGCT_CallFrame _asgct_frames[1];  // 用于 AsyncGetCallTrace
    jvmtiFrameInfo _jvmti_frames[1];   // 用于 JVMTI GetStackTrace
};

// 展开步骤 3: 数组访问
// _calltrace_buffer[lock_index] 返回 CallTraceBuffer*
// ->_asgct_frames 返回 ASGCT_CallFrame 数组首地址

// 展开步骤 4: ASGCT_CallFrame 结构
typedef struct {
    jint bci;           // 字节码索引，或特殊帧类型
    jmethodID method_id;// 方法 ID，或 Native 函数名指针
} ASGCT_CallFrame;

// 展开步骤 5: jvmtiFrameInfo 结构
typedef struct {
    jmethodID method;   // 方法 ID
    jlocation location; // 字节码位置
} jvmtiFrameInfo;
```

#### 2.6.2 六层面分析

| 层面 | 分析 |
|------|------|
| **设计原理** | 为什么用联合体？<br>1. 同一块内存可用于两种不同格式<br>2. 节省内存（16 个缓冲区 × 最大栈深度 × 两种格式会很大）<br>3. 同一时间只用一种格式，不会冲突 |
| **边界条件** | 缓冲区大小在 start() 时分配：`max_stack_depth + 128 + 10`<br>如果栈深度超过，会被截断。设计上可接受。 |
| **并发安全** | 每个 lock_index 对应独立缓冲区。只要锁获取成功，缓冲区独占使用。 |
| **JVM 交互** | ASGCT_CallFrame 是 AsyncGetCallTrace 的返回格式。<br>jvmtiFrameInfo 是 JVMTI GetStackTrace 的格式。 |
| **性能影响** | 纯指针运算，无开销。 |
| **替代方案** | 1. 分开两个数组：<br>   问题：内存翻倍。<br>2. 使用 std::variant：<br>   问题：C++17 引入，开销增加。<br>**结论**：联合体是最优解。 |

---

## 3. GDB 验证脚本

### 3.1 验证脚本

```gdb
# 文件: jvm-md/tmp-file/async-profiler/gdb_recordSample.txt
# 用法: gdb -x gdb_recordSample.txt --args java -agentpath:... -cp ... Main

set pagination off
set print pretty on

# 在 recordSample 入口设置断点
break Profiler::recordSample

commands
    printf "\n========== recordSample() 被调用 ==========\n"
    
    # 打印参数
    printf "ucontext: %p\n", $arg0
    printf "counter: %llu\n", $arg1
    printf "event_type: %d\n", $arg2
    
    # 单步执行第一行
    step
    
    # 打印 _total_samples（原子操作后）
    printf "_total_samples: %llu\n", _total_samples
    
    # 单步执行获取 tid
    step
    printf "tid: %d\n", $rax
    
    # 单步执行获取 lock_index
    step
    printf "lock_index: %u\n", $eax
    
    # 继续执行
    continue
end

run
```

### 3.2 验证 SpinLock 实现

```gdb
# 文件: jvm-md/tmp-file/async-profiler/gdb_spinlock.txt

set pagination off

break SpinLock::tryLock

commands
    printf "\n========== SpinLock::tryLock() ==========\n"
    printf "_lock 地址: %p\n", &$rdi->_lock
    printf "_lock 当前值: %d\n", $rdi->_lock
    
    # 执行 CAS
    stepi
    
    # 检查结果
    printf "CAS 结果: %d\n", $rax
    printf "_lock 新值: %d\n", $rdi->_lock
    
    continue
end

run
```

---

## 4. 完整执行流程图（含时间估算）

```
recordSample() 完整执行流程（标准 CPU 采样场景）：

时间点   操作                              耗时(估算)
────────────────────────────────────────────────────────────
T0      进入 recordSample()               0
T1      atomicInc(_total_samples)         20-50 周期
T2      tid = OS::threadId()              100-300 周期（syscall）
T3      lock_index = getLockIndex(tid)    5 周期
T4      tryLock() 尝试 1                  20 周期（成功）
        └── 成功，继续                    ─────────────
T5      stack_walk_begin = nanotime()     20-50 周期（如果启用）
T6      获取帧缓冲区指针                  5 周期
T7      添加事件帧（如果需要）            10-20 周期
T8      getNativeTrace()                  500-2000 周期
        ├── PerfEvents::walk()            (内核栈回溯)
        └── convertNativeTrace()          (符号解析)
T9      getJavaTraceAsync()               1000-5000 周期
        ├── VMThread::current()           (TLS 访问)
        ├── AsyncGetCallTrace()           (JVM 栈回溯)
        └── fillFrameTypes()              (填充帧类型)
T10     添加附加帧                        20-50 周期
        ├── 线程帧
        ├── 调度帧
        └── CPU 帧
T11     _call_trace_storage.put()         100-200 周期
        ├── calcHash()                    (MurmurHash)
        ├── LongHashTable 查找/插入       (开放寻址)
        └── LinearAllocator::alloc()      (CAS 分配)
T12     _jfr.recordEvent()                50-100 周期
        └── 写入 JFR buffer               (变长编码)
T13     _locks[lock_index].unlock()       20 周期
T14     return (tid << 32 | call_trace_id) 5 周期
────────────────────────────────────────────────────────────

总耗时估算：
  - 最快路径（已有调用栈、哈希命中）：约 2000-3000 CPU 周期
  - 典型路径（完整栈回溯、新调用栈）：约 5000-10000 CPU 周期
  - 最慢路径（DWARF 栈回溯、哈希冲突）：约 20000+ CPU 周期

注意：以上是 CPU 周期估算，实际时间取决于 CPU 频率。
      在 3GHz CPU 上，1000 周期 ≈ 333 纳秒
```

---

## 5. 设计亮点总结

### 5.1 无锁数据结构

```
设计目标：
  - 信号处理器不能使用互斥锁
  - 必须使用无锁或无等待算法

解决方案：
  1. SpinLock + tryLock()：非阻塞获取
  2. CAS 原子操作：原子计数、原子分配
  3. 每线程缓冲区：避免共享竞争
```

### 5.2 批量重试策略

```
三次 tryLock 的智慧：
  1. 避免单点竞争：相邻槽位分散负载
  2. 快速放弃：不阻塞信号处理器
  3. 记录失败：方便性能分析
```

### 5.3 联合体复用内存

```
CallTraceBuffer 联合体：
  - 同一块内存两种用途
  - 节省 50% 内存
  - 零运行时开销
```

---

## 6. 潜在问题与改进建议

### 6.1 syscall 开销

```cpp
// 当前实现
int tid = OS::threadId();  // syscall

// 改进建议：TLS 缓存
static __thread int cached_tid = 0;
if (unlikely(cached_tid == 0)) {
    cached_tid = syscall(__NR_gettid);
}
int tid = cached_tid;

// 收益：避免每次采样的 syscall 开销
// 风险：线程创建时需要初始化
```

### 6.2 锁竞争统计

```cpp
// 当前：只记录放弃次数
atomicInc(_failures[-ticks_skipped]);

// 改进建议：记录每次 tryLock 的结果
atomicInc(_lock_attempts);  // 总尝试次数
atomicInc(_lock_success[try_count]);  // 第 N 次成功

// 收益：更精细的性能分析
```

---

**本课到此结束。下一课将深入分析 `getJavaTraceAsync()` 的完整实现，包括 AsyncGetCallTrace 的调用细节和各种错误恢复策略。**
