# 5.1 recordSample() 总入口 — 信号处理器里的核心逻辑

> 源文件: `profiler.cpp` (1918行 — 大文件), `profiler.h` (258行), `event.h` (115行)
> 关联: `perfEvents_linux.cpp::signalHandler`, `cpuEngine.cpp::signalHandler`, `stackWalker.cpp`
> 前置章节: 4.1 perf_event_open 配置 + 信号驱动

## 核心问题

**当 SIGPROF 信号到达被采样线程后，async-profiler 在信号处理器中具体做了哪些事情？如何在"不能 malloc、不能持锁、不能阻塞"的严格约束下完成栈采集、帧标注和存储？**

答案：**`recordSample()` 是所有采样引擎的汇聚点**——无论是 PerfEvents、CTimer、ITimer、WallClock 还是 AllocTracer，最终都调用它。它在信号安全约束下完成"采栈→编码→去重→写 JFR"四步操作。

---

## 一、调用来源 — 谁调用 recordSample？

```
PerfEvents::signalHandler()    → recordSample(ucontext, counter, PERF_SAMPLE, &event)
CpuEngine::signalHandler()     → recordSample(ucontext, total_cpu_time, EXECUTION_SAMPLE, &event)
WallClock::signalHandler()     → recordSample(ucontext, 1, WALL_CLOCK_SAMPLE, &event)
AllocTracer::trapHandler()     → recordSample(ucontext, total_size, ALLOC_SAMPLE, &event)
MallocTracer::malloc_hook()    → recordSample(NULL, size, MALLOC_SAMPLE, &event)
NativeLockTracer::lock_hook()  → recordSample(NULL, duration, NATIVE_LOCK_SAMPLE, &event)
```

**所有采样最终汇聚到同一个函数**，唯一的区别是 `event_type` 和 `counter` 参数。

---

## 二、EventType 枚举 — 事件类型的排序很重要

```cpp
enum EventType {
    PERF_SAMPLE,          // 0 — perf_event_open 采样
    EXECUTION_SAMPLE,     // 1 — CTimer/ITimer 采样
    WALL_CLOCK_SAMPLE,    // 2 — Wall Clock 采样
    NATIVE_LOCK_SAMPLE,   // 3 — pthread_mutex 追踪
    MALLOC_SAMPLE,        // 4 — malloc 追踪
    INSTRUMENTED_METHOD,  // 5 — 方法插桩
    METHOD_TRACE,         // 6 — 方法追踪
    ALLOC_SAMPLE,         // 7 — TLAB 分配
    ALLOC_OUTSIDE_TLAB,   // 8 — TLAB 外分配
    LIVE_OBJECT,          // 9 — 存活对象
    LOCK_SAMPLE,          // 10 — Java 锁
    PARK_SAMPLE,          // 11 — LockSupport.park
    PROFILING_WINDOW,     // 12 — 窗口事件
    USER_EVENT,           // 13 — 用户自定义
};
```

**枚举顺序有意义**：代码中大量使用 `event_type <= MALLOC_SAMPLE`、`event_type >= ALLOC_SAMPLE` 等范围判断来决定走哪个栈采集路径。

---

## 三、recordSample 完整流程

### 3.1 签名

```cpp
u64 Profiler::recordSample(void* ucontext, u64 counter, EventType event_type, Event* event);
// 参数:
//   ucontext — 被中断时的寄存器上下文（信号处理器提供）
//   counter  — 计数值（CPU 纳秒 / 分配字节 / 等待时间等）
//   event_type — 事件类型
//   event    — 事件附加数据（时间戳、类 ID 等）
// 返回值: (tid << 32) | call_trace_id
```

### 3.2 完整流程图

```
recordSample(ucontext, counter, event_type, event)
  │
  ├── Step 1: 原子递增 _total_samples
  │
  ├── Step 2: 获取并发锁（tryLock × 3）
  │     ├── lock_index = hash(tid) % 16
  │     ├── 尝试 lock[i], lock[i+1], lock[i+2]
  │     └── 全部失败 → atomicInc(_failures[skipped]) → return 0
  │
  ├── Step 3: 构建事件帧（可选）
  │     └── 如果 _add_event_frame && ALLOC/LOCK 事件 → 添加 class_id 帧
  │
  ├── Step 4: 采集原生栈（C/C++ 帧）
  │     ├── hasNativeStack(event_type) == true?
  │     │   ├── PERF_SAMPLE → PerfEvents::walk() (ring buffer 读内核栈)
  │     │   ├── CSTACK_DWARF → StackWalker::walkDwarf()
  │     │   ├── CSTACK_FP → StackWalker::walkFP()
  │     │   └── CSTACK_VM → return 0 (由 walkVM 统一处理)
  │     └── convertNativeTrace() → 帧标记 + 去重
  │
  ├── Step 5: 采集 Java 栈 — 三条路径
  │     ├── 路径 A: _features.mixed → StackWalker::walkVM() (混合模式)
  │     ├── 路径 B: event <= MALLOC_SAMPLE
  │     │   ├── CSTACK_VM → StackWalker::walkVM()           ← 我们的标准路径
  │     │   └── 其他 → getJavaTraceAsync() (ASGCT)
  │     ├── 路径 C: ALLOC 事件 + AllocTracer
  │     │   ├── hasStackStructs → walkVM()
  │     │   └── 否则 → getJavaTraceAsync()
  │     └── 路径 D: LOCK/INSTRUMENT 事件
  │         └── getJavaTraceJvmti() (同步 JVMTI API)
  │
  ├── Step 6: 补充特殊帧
  │     ├── num_frames == 0 → 添加 "no_Java_frame" 错误帧
  │     ├── _add_thread_frame → 添加 BCI_THREAD_ID 帧
  │     ├── _add_sched_frame → 添加调度策略帧
  │     └── _add_cpu_frame → 添加 CPU ID 帧（PERF_SAMPLE）
  │
  ├── Step 7: 存储 + 录制
  │     ├── call_trace_id = _call_trace_storage.put(num_frames, frames, counter)
  │     └── _jfr.recordEvent(lock_index, tid, call_trace_id, event_type, event)
  │
  └── Step 8: 释放锁 + 返回
        └── return (tid << 32) | call_trace_id
```

---

## 四、Step 2: 并发锁 — 16 路 SpinLock

### 4.1 为什么需要并发控制？

多个线程可能同时收到采样信号，同时进入 `recordSample`。每个调用需要：
- 一个 `CallTraceBuffer`（存放帧数据）
- 一个 JFR 写入槽位

这些资源是**预分配**的，不能在信号处理器中 malloc。所以用 16 个 SpinLock 保护 16 个预分配的缓冲区。

### 4.2 锁获取策略

```cpp
u32 lock_index = getLockIndex(tid);  // hash(tid) % 16
if (!_locks[lock_index].tryLock() &&
    !_locks[lock_index = (lock_index + 1) % 16].tryLock() &&
    !_locks[lock_index = (lock_index + 2) % 16].tryLock())
{
    // 3 次都失败 → 丢弃这个采样
    atomicInc(_failures[-ticks_skipped]);
    return 0;
}
```

**设计要点**：
1. **tryLock 不阻塞**：信号处理器中绝不能阻塞等待
2. **3 次探测**：hash + 线性探测(+1, +2)，降低冲突概率
3. **丢弃而非等待**：宁可少一个采样，也不能死锁

### 4.3 getLockIndex — hash 函数

```cpp
u32 getLockIndex(int tid) {
    u32 lock_index = tid;
    lock_index ^= lock_index >> 8;
    lock_index ^= lock_index >> 4;
    return lock_index % CONCURRENCY_LEVEL;  // % 16
}
```

简单的位混洗，把 TID 的高位信息混入低位，然后对 16 取模。

### GDB 验证

```
tid = 99166 → lock_index = hash(99166) % 16 = 10
→ 尝试 _locks[10], _locks[11], _locks[12]
→ 成功获取 lock[10]
```

---

## 五、Step 4: 原生栈采集

### 5.1 hasNativeStack — 位掩码判断

```cpp
static inline int hasNativeStack(EventType event_type) {
    const int events_with_native_stack =
        (1 << PERF_SAMPLE)        |  // 0
        (1 << EXECUTION_SAMPLE)   |  // 1
        (1 << WALL_CLOCK_SAMPLE)  |  // 2
        (1 << NATIVE_LOCK_SAMPLE) |  // 3
        (1 << MALLOC_SAMPLE)      |  // 4
        (1 << ALLOC_SAMPLE)       |  // 7
        (1 << ALLOC_OUTSIDE_TLAB);   // 8
    return (1 << event_type) & events_with_native_stack;
}
```

**LOCK_SAMPLE/PARK_SAMPLE/INSTRUMENTED_METHOD 没有原生栈**：因为这些事件发生在 Java 层面，原生栈不提供有用信息（全是 JVM 内部的 runtime 帧）。

### 5.2 getNativeTrace 的 4 种路由

```cpp
int Profiler::getNativeTrace(...) {
    if (event_type == PERF_SAMPLE) {
        return PerfEvents::walk(tid, ucontext, callchain, MAX_NATIVE_FRAMES, java_ctx);
        // → 从 mmap ring buffer 读取内核调用链（4.1 节已详述）
    } else if (_cstack == CSTACK_VM) {
        return 0;   // ← walkVM 会自己处理原生帧
    } else if (_cstack == CSTACK_DWARF) {
        return StackWalker::walkDwarf(ucontext, callchain, MAX_NATIVE_FRAMES, java_ctx);
    } else {
        return StackWalker::walkFP(ucontext, callchain, MAX_NATIVE_FRAMES, java_ctx);
    }
}
```

### GDB 验证

```
event_type = 0 (PERF_SAMPLE)
→ 走 PerfEvents::walk()
→ 返回内核栈帧 → convertNativeTrace 转换为 ASGCT_CallFrame 格式

_cstack = 5 (CSTACK_VM)
但 event_type == PERF_SAMPLE，所以先走 PerfEvents::walk 获取内核栈
然后 Step 5 中走 walkVM 获取用户态混合栈
```

### 5.3 convertNativeTrace — 帧标记与过滤

```cpp
int Profiler::convertNativeTrace(int native_frames, const void** callchain,
                                  ASGCT_CallFrame* frames, EventType event_type) {
    for (int i = 0; i < native_frames; i++) {
        const char* name = findNativeMethod(callchain[i]);  // PC→符号名
        char mark = NativeFunc::mark(name);                  // 检查特殊标记

        if (mark == MARK_VM_RUNTIME && event_type >= ALLOC_SAMPLE) {
            depth = 0;           // 分配事件：跳过 VM runtime 之上的所有帧
        } else if (mark == MARK_INTERPRETER) {
            return depth;        // 遇到解释器帧：停止（后续由 Java 栈回溯接管）
        } else if (mark == MARK_COMPILER_ENTRY && _features.comp_task) {
            // 插入编译任务伪帧
            frames[depth++] = {0, getCurrentCompileTask()};
        }

        frames[depth].bci = BCI_NATIVE_FRAME;     // bci = -10
        frames[depth].method_id = (jmethodID)name; // 符号名作为 method_id
        depth++;
    }
}
```

**帧标记机制**：某些符号名有特殊前缀标记（在 `findNativeMethod` 查找时打上），告诉 convertNativeTrace 怎么处理：
- `MARK_VM_RUNTIME`：JVM 运行时入口（如 `SharedRuntime::*`），分配事件时跳过它之上的帧
- `MARK_INTERPRETER`：解释器入口，原生栈在此终止
- `MARK_COMPILER_ENTRY`：编译器线程入口，插入正在编译的方法

---

## 六、Step 5: Java 栈采集 — 三条核心路径

这是 `recordSample` 中**最复杂的部分**，根据不同条件走不同路径：

### 6.1 路径选择决策树

```
_features.mixed?
  ├── Yes → 路径 A: walkVM() （混合模式：原生+Java 在一次遍历中完成）
  │
  └── No
       │
       ├── event_type <= MALLOC_SAMPLE (0~4)?
       │   ├── _cstack == CSTACK_VM? → 路径 B1: walkVM()     ← 标准路径
       │   └── 否则 → 路径 B2: getJavaTraceAsync() (ASGCT)
       │
       ├── ALLOC 事件 + AllocTracer?
       │   ├── hasStackStructs? → 路径 C1: walkVM()
       │   └── 否则 → 路径 C2: getJavaTraceAsync()
       │
       └── LOCK/INSTRUMENT 事件 (>=INSTRUMENTED_METHOD 且 <ALLOC)
           └── 路径 D: getJavaTraceJvmti()  (同步 JVMTI)
```

### 6.2 路径 B1: walkVM — 我们的标准路径（GDB 验证确认）

```cpp
if (_cstack == CSTACK_VM) {
    num_frames += StackWalker::walkVM(ucontext, frames + num_frames,
                                       _max_stack_depth, lock_index, _features, event_type);
}
```

**walkVM 做什么？** 利用 VMStructs 推断的偏移量，直接遍历 JVM 内部的栈帧结构，同时处理：
- 解释器帧（Interpreter Frame）
- JIT 编译帧（Compiled Frame）
- 原生帧（Native Frame）
- Entry 帧（Java↔Native 过渡）
- Stub 帧（Runtime Stub）

**为什么 walkVM 优于 ASGCT？**
1. walkVM 能处理 ASGCT 无法处理的帧（如 `_thread_in_vm` 状态）
2. walkVM 可以同时输出 Java 帧和原生帧（混合栈）
3. walkVM 有 `setjmp/longjmp` 崩溃保护
4. walkVM 理解 ScopeDesc，能正确展开内联方法

### GDB 验证 — 标准路径确认

```
=== recordSample ===
_cstack = 5 (CSTACK_VM)
event_type = 0 (PERF_SAMPLE)

→ getNativeTrace: event_type=0 → PerfEvents::walk() → 内核栈
→ walkVM(ucontext, ...) → Java + 原生混合栈

结果: num_frames = 32
  frame[0..~15]:  bci=-10 → BCI_NATIVE_FRAME (C/C++ 帧)
  frame[16..31]:  bci=0x0100XXXX → FRAME_INTERPRETED + BCI (Java 帧)
```

### 6.3 路径 B2: getJavaTraceAsync — ASGCT 路径

当 `_cstack != CSTACK_VM` 时走这条路径（例如 `--cstack fp` 或 `--cstack dwarf`）：

```cpp
int java_frames = getJavaTraceAsync(ucontext, frames + num_frames, _max_stack_depth, &java_ctx);
```

`getJavaTraceAsync` 的内部流程（简化）：

```
getJavaTraceAsync(ucontext, frames, max_depth, java_ctx)
  │
  ├── VMThread::current() → 获取 JavaThread*
  │   └── pthread_getspecific(_tls_index=0)
  │
  ├── vm_thread->jni() → JNIEnv*
  │
  ├── VM::_asyncGetCallTrace(&trace, max_depth, ucontext) → 调 ASGCT
  │
  ├── 如果成功 (trace.num_frames > 0) → 直接返回
  │
  ├── 如果失败 → 根据错误码尝试恢复：
  │   ├── unknown_Java / not_walkable_Java:
  │   │   ├── 尝试 unwindStub() → 重试 ASGCT
  │   │   └── 尝试从 NMethod 直接获取方法 ID
  │   │
  │   ├── unknown_not_Java:
  │   │   ├── 读取 JavaFrameAnchor → 修复 lastJavaPC
  │   │   └── 重试 ASGCT
  │   │
  │   └── GC_active:
  │       └── 如果有 Java 帧 → 返回 "GC_active" 帧
  │
  └── 如果恢复也失败 → 返回错误帧 (BCI_ERROR)
```

### 6.4 路径 D: getJavaTraceJvmti — 同步 JVMTI

锁事件和插桩事件可以安全调用同步 API（因为它们**不在信号处理器中**——LockTracer 在 JVMTI 回调中，Instrument 在 JNI 方法中）：

```cpp
num_frames += getJavaTraceJvmti(jvmti_frames, frames, start_depth, _max_stack_depth);
// start_depth: INSTRUMENTED_METHOD → 1 (跳过 recordSample 自己)
//              METHOD_TRACE → 2 (跳过 recordSample + recordEntry)
//              其他 → 0
```

---

## 七、帧类型编码 — BCI 字段的多重含义

`ASGCT_CallFrame.bci` 字段被复用为多种信息的载体：

### 7.1 特殊 BCI 值

| BCI 值 | 常量 | 含义 | method_id 的含义 |
|--------|------|------|-----------------|
| -10 | `BCI_NATIVE_FRAME` | C/C++ 原生帧 | 符号名指针 |
| -9 | `BCI_ERROR` | 错误/状态帧 | 错误信息字符串 |
| -8 | `BCI_ALLOC` | 分配事件帧 | class_id (u32) |
| -7 | `BCI_THREAD_ID` | 线程 ID 帧 | tid (int) |
| -6 | `BCI_ADDRESS` | PC 地址帧 | PC 地址 |
| -5 | `BCI_CPU` | CPU ID 帧 | cpu_id | 0x8000 |
| ≥ 0 | 正常 BCI | Java 帧 | jmethodID |

### 7.2 FrameType 编码（Java 帧）

```cpp
// 高 8 位编码帧类型，低 24 位保留原始 BCI
static jint encode(FrameTypeId type, jint bci) {
    return (type << 24) | (bci & 0xFFFFFF);
}

enum FrameTypeId {
    FRAME_INTERPRETED  = 1,   // 0x01000000
    FRAME_JIT_COMPILED = 2,   // 0x02000000
    FRAME_INLINED      = 3,   // 0x03000000
    FRAME_C1_COMPILED  = 4,   // 0x04000000
};
```

### GDB 验证 — 帧编码解码

```
frame[0]:  bci=-10 (BCI_NATIVE_FRAME)  method_id=0x7ffff0e17874 → libjvm.so 中的符号名
frame[20]: bci=0x01000012 → FRAME_INTERPRETED(1) + original_bci=18
frame[30]: bci=0x0100005d → FRAME_INTERPRETED(1) + original_bci=93

分析：-Xint 模式下所有 Java 帧都标记为 FRAME_INTERPRETED ✅
```

### 7.3 fillFrameTypes — 帧类型标注

```cpp
void Profiler::fillFrameTypes(ASGCT_CallFrame* frames, int num_frames, NMethod* nmethod) {
    if (nmethod->isNMethod() && nmethod->isAlive()) {
        jmethodID current = nmethod->method()->id();
        // 找到当前编译方法 → 标记 JIT_COMPILED
        // 它之上的帧 → 标记 INLINED
        for (int i = 0; i < num_frames; i++) {
            if (frames[i].method_id == current) {
                frames[i].bci = FrameType::encode(
                    level >= 1 && level <= 3 ? FRAME_C1_COMPILED : FRAME_JIT_COMPILED,
                    frames[i].bci);
                for (int j = 0; j < i; j++) {
                    frames[j].bci = FrameType::encode(FRAME_INLINED, frames[j].bci);
                }
                break;
            }
        }
    } else if (nmethod->isInterpreter()) {
        // 第一个 Java 帧标记为 INTERPRETED
        frames[i].bci = FrameType::encode(FRAME_INTERPRETED, frames[i].bci);
    }
}
```

**逻辑**：ASGCT 返回的帧按"从顶到底"的顺序排列。在 JIT 编译方法中，内联方法排在前面，被内联的宿主方法排在后面。找到宿主方法后，它之上的帧就是内联帧。

---

## 八、Step 7: 存储与录制

### 8.1 CallTraceStorage::put — 调用栈去重

```cpp
u32 call_trace_id = _call_trace_storage.put(num_frames, frames, counter);
```

`CallTraceStorage` 是一个**哈希表**，key 是帧数组的 hash，value 是 `{CallTrace, samples, counter}`。

**为什么要去重？** 同一个代码路径可能被采样数万次，只需要存储一份调用栈，然后累加计数。这大幅减少了内存使用。

### 8.2 FlightRecorder::recordEvent — JFR 写入

```cpp
_jfr.recordEvent(lock_index, tid, call_trace_id, event_type, event);
```

把采样事件写入 JFR 缓冲区。`lock_index` 用于选择哪个 JFR 写入槽位（避免并发）。

### GDB 验证

```
recordSample returned: (99166 << 32) | 35116 = 425914726910252
  tid = 99166
  call_trace_id = 35116  → 哈希表中的槽位号
```

---

## 九、StackContext — 原生栈与 Java 栈的桥梁

```cpp
class StackContext {
  public:
    const void* pc;  // 内核栈中遇到的第一个 Java PC
    uintptr_t sp;    // 对应的 SP
    uintptr_t fp;    // 对应的 FP
    int cpu;         // CPU ID（从 ring buffer 读取）
};
```

**工作方式**：

```
PerfEvents::walk() 读 ring buffer
  ├── 遍历内核调用链
  ├── 遇到 CodeHeap 中的 PC → 保存到 java_ctx
  │     java_ctx->pc = CodeHeap_PC
  └── 返回内核帧深度

getJavaTraceAsync() 使用 java_ctx
  ├── 如果 vm_thread->inJava() && java_ctx->sp != 0
  │     → frame.restore(java_ctx->pc, java_ctx->sp, java_ctx->fp)
  │     → 从已知的 Java PC 开始，用 ASGCT 回溯
  └── 这样 ASGCT 从"安全的"Java 帧开始，成功率更高
```

---

## 十、_calltrace_buffer — 预分配的帧缓冲区

```cpp
CallTraceBuffer* _calltrace_buffer[CONCURRENCY_LEVEL];  // 16 个

// 分配: start() 中
size_t nelem = _max_stack_depth + MAX_NATIVE_FRAMES + RESERVED_FRAMES;
//           = 2048             + 128              + 10
//           = 2186

_calltrace_buffer[i] = (CallTraceBuffer*)calloc(nelem, sizeof(CallTraceBuffer));
```

**每个缓冲区可以容纳 2186 帧**（2048 Java 帧 + 128 原生帧 + 10 保留帧）。16 个缓冲区 = 16 个并发槽位。

---

## 十一、不同事件类型的完整对比

| 事件类型 | 原生栈 | Java 栈路径 | counter 含义 | 触发方式 |
|---------|--------|------------|-------------|---------|
| PERF_SAMPLE(0) | PerfEvents::walk | walkVM | CPU ns | perf_event 信号 |
| EXECUTION_SAMPLE(1) | walkFP/walkDwarf | walkVM / ASGCT | CPU ns | timer 信号 |
| WALL_CLOCK_SAMPLE(2) | walkFP/walkDwarf | walkVM / ASGCT | 1 | tkill 信号 |
| NATIVE_LOCK_SAMPLE(3) | walkFP/walkDwarf | walkVM / ASGCT | duration ns | inline hook |
| MALLOC_SAMPLE(4) | walkFP/walkDwarf | walkVM / ASGCT | alloc bytes | inline hook |
| ALLOC_SAMPLE(7) | walkFP/walkDwarf | walkVM / ASGCT | total bytes | SIGTRAP |
| LOCK_SAMPLE(10) | 无 | JVMTI 同步 | duration ns | JVMTI 回调 |
| INSTRUMENTED_METHOD(5) | 无 | JVMTI 同步 | 1 | JNI 调用 |

---

## 十二、并发安全性总结

`recordSample` 运行在**信号处理器**上下文中（对于 CPU/Wall/Alloc 事件），有以下严格约束：

| 约束 | 解决方案 |
|------|---------|
| 不能 malloc | 预分配 `_calltrace_buffer[16]` |
| 不能持 mutex | SpinLock + tryLock × 3 |
| 不能阻塞 | tryLock 失败直接丢弃 |
| 不能调 JVM API | VMStructs 偏移量 + TLS |
| 不能崩溃 | SafeAccess + setjmp/longjmp |
| 多线程并发 | 16 路并发 + CAS 原子操作 |

---

## 十三、总结

### recordSample 的核心设计

1. **汇聚点**：所有引擎的采样最终都进入同一个函数，统一处理
2. **16 路并发**：预分配 16 个缓冲区 + 16 个 SpinLock，支持高并发
3. **4 种栈回溯策略**：walkVM / ASGCT / JVMTI / PerfEvents::walk，根据事件类型和 cstack 配置选择
4. **帧类型编码**：BCI 字段复用，用高 8 位标识帧类型（解释/JIT/内联）
5. **去重存储**：相同调用栈只存一份，累加计数
6. **信号安全**：整个函数链不 malloc、不持 mutex、不阻塞

### GDB 验证的关键数据

| 验证项 | 实际值 | 含义 |
|--------|--------|------|
| event_type | 0 (PERF_SAMPLE) | perf_event 采样 |
| counter | ~10,000,000 ns | 约 10ms 一次 |
| _cstack | 5 (CSTACK_VM) | VMStructs 栈回溯 |
| _max_stack_depth | 2048 | 最大 Java 帧深度 |
| lock_index | 10 | hash(tid) % 16 |
| num_frames | 32 | 15 原生帧 + 17 Java 帧 |
| frame[0].bci | -10 | BCI_NATIVE_FRAME |
| frame[20].bci | 0x01000012 | INTERPRETED + bci=18 |
| call_trace_id | 35116 | 哈希表槽位 |
| _add_event_frame | 0 | JFR 输出不加事件帧 |

### 在整体架构中的位置

```
Agent 加载（Ch01）
  → VMStructs 初始化（Ch02）
  → Engine 体系 + selectEngine（Ch03）
  → perf_event_open + 信号驱动（Ch04）
  → 信号到达 → recordSample()（本节）  ← 你在这里
    ├── getNativeTrace → PerfEvents::walk / walkFP / walkDwarf
    ├── getJavaTraceAsync → ASGCT（Ch05.2）
    └── walkVM → 混合模式栈回溯（Ch05.5）
```

---

*创建日期: 2026-02-09*
*GDB 验证环境: OpenJDK 11 slowdebug + async-profiler v4.0*
