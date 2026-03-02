# Lesson 9: Profiler 核心控制器深度逐行解析（方法内联展开）

> 本文档对 profiler.cpp (1917 行) 的核心实现进行深度解析，包括状态管理、采样记录、栈回溯调度、引擎选择等。

---

## 1. Profiler 类结构概览

### 1.1 核心成员变量

```cpp
// 文件: profiler.h 第 49-95 行

class Profiler {
  private:
    // ==================== 状态管理 ====================
    Mutex _state_lock;          // 状态锁
    State _state;               // NEW -> IDLE -> RUNNING -> TERMINATED
    
    // ==================== Trap 机制 ====================
    Trap _begin_trap;           // 开始断点
    Trap _end_trap;             // 结束断点
    bool _nostop;               // 不停止标志
    
    // ==================== 线程管理 ====================
    Mutex _thread_names_lock;   // 线程名锁
    std::map<int, std::string> _thread_names;   // tid -> 线程名
    std::map<int, jlong> _thread_ids;           // tid -> Java Thread ID
    ThreadFilter _thread_filter;                 // 线程过滤器
    
    // ==================== 数据存储 ====================
    Dictionary _class_map;              // 类名映射
    CallTraceStorage _call_trace_storage; // 调用栈存储
    FlightRecorder _jfr;                // JFR 输出器
    
    // ==================== 引擎管理 ====================
    Engine* _engine;        // 主采样引擎
    Engine* _alloc_engine;  // 分配追踪引擎
    int _event_mask;        // 事件类型掩码
    
    // ==================== 时间统计 ====================
    u64 _start_time;        // 开始时间
    u64 _stop_time;         // 停止时间
    u64 _loop_time;         // 循环时间
    int _epoch;             // 轮次（每次 start 递增）
    u32 _gc_id;             // GC ID
    
    // ==================== 统计信息 ====================
    u64 _total_samples;         // 总采样数
    u64 _total_stack_walk_time; // 总栈回溯时间
    u64 _failures[ASGCT_FAILURE_TYPES]; // 各类失败计数
    
    // ==================== 并发控制 ====================
    SpinLock _locks[CONCURRENCY_LEVEL];   // 自旋锁数组（16 个）
    CallTraceBuffer* _calltrace_buffer[CONCURRENCY_LEVEL]; // 调用栈缓冲区
    
    // ==================== 栈回溯配置 ====================
    int _max_stack_depth;       // 最大栈深度
    StackWalkFeatures _features; // 栈回溯特性
    CStack _cstack;             // C 栈回溯方式
    
    // ==================== 帧配置 ====================
    bool _add_event_frame;  // 添加事件帧
    bool _add_thread_frame; // 添加线程帧
    bool _add_sched_frame;  // 添加调度帧
    bool _add_cpu_frame;    // 添加 CPU 帧
    
    // ==================== 符号管理 ====================
    SpinLock _stubs_lock;       // Stub 锁
    CodeCache _runtime_stubs;   // 运行时 Stub
    CodeCacheArray _native_libs; // Native 库数组
    const void* _call_stub_begin; // call_stub 起始地址
    const void* _call_stub_end;   // call_stub 结束地址
};
```

### 1.2 状态机

```
状态转换图：

     Agent_OnLoad/Agent_OnAttach
              │
              v
           [NEW]
              │
              │ start()
              v
          [IDLE] ←──────────────┐
              │                  │
              │ start()          │ stop()
              v                  │
        [RUNNING] ───────────────┘
              │
              │ shutdown()
              v
      [TERMINATED]
```

---

## 2. 全局静态对象

### 2.1 单例模式

```cpp
// 文件: profiler.cpp 第 45-47 行

// The instance is not deleted on purpose, since profiler structures
// can be still accessed concurrently during VM termination
Profiler* const Profiler::_instance = new Profiler();
```

**为什么不用析构？**

```
问题场景：
  1. JVM 关闭时，可能有信号处理器还在执行
  2. 如果 delete _instance，信号处理器访问已释放的内存
  3. 导致 crash

解决方案：
  1. 静态分配，永不释放
  2. JVM 退出时，操作系统会回收所有内存
  3. 避免了复杂的同步问题
```

### 2.2 全局引擎实例

```cpp
// 文件: profiler.cpp 第 55-68 行

static Engine noop_engine;          // 空引擎
static PerfEvents perf_events;      // perf_event 采样
static AllocTracer alloc_tracer;    // 对象分配追踪
static MallocTracer malloc_tracer;  // Native 内存追踪
static LockTracer lock_tracer;      // Java 锁追踪
static NativeLockTracer native_lock_tracer; // Native 锁追踪
static ObjectSampler object_sampler; // JVMTI 对象采样
static J9ObjectSampler j9_object_sampler;  // J9 对象采样
static WallClock wall_clock;        // Wall Clock 采样
static J9WallClock j9_wall_clock;   // J9 Wall Clock
static CTimer ctimer;               // CTimer 采样
static ITimer itimer;               // ITimer 采样
static Instrument instrument;       // 字节码插桩
```

**为什么用静态全局？**

```
优点：
  1. 避免动态内存分配
  2. 生命周期贯穿整个程序
  3. 减少构造/析构开销
  4. 简化并发控制

设计决策：
  - 引擎数量固定，运行时不会变化
  - 引擎状态由 Profiler 管理
  - 引擎可以复用（多次 start/stop）
```

---

## 3. recordSample() - 采样记录核心

### 3.1 函数签名

```cpp
// 文件: profiler.cpp 第 606-703 行

u64 Profiler::recordSample(void* ucontext, u64 counter, EventType event_type, Event* event) {
```

**参数解析**：

```
ucontext: 信号上下文（包含寄存器状态）
          - 从信号处理器传入
          - 用于栈回溯

counter: 计数值
         - CPU 采样：通常是 1（每个采样算 1 次）
         - 分配采样：分配的字节数
         - 锁采样：等待时间（纳秒）

event_type: 事件类型
         - PERF_SAMPLE: perf_event CPU 采样
         - EXECUTION_SAMPLE: 执行采样
         - WALL_CLOCK_SAMPLE: Wall Clock 采样
         - ALLOC_SAMPLE: TLAB 内分配
         - ALLOC_OUTSIDE_TLAB: TLAB 外分配
         - LOCK_SAMPLE: 锁争用

event: 事件详情
       - 对于 ALLOC_SAMPLE，包含 class_id
       - 对于 LOCK_SAMPLE，包含锁地址
```

### 3.2 完整逐行解析

```cpp
// 文件: profiler.cpp 第 606-703 行

u64 Profiler::recordSample(void* ucontext, u64 counter, EventType event_type, Event* event) {
    // ==================== [1] 原子增加采样计数 ====================
    atomicInc(_total_samples);
    // atomicInc 展开为：
    // __sync_fetch_and_add(&_total_samples, 1);
    
    // ==================== [2] 获取线程 ID 和锁索引 ====================
    int tid = OS::threadId();
    // Linux 上展开为：syscall(SYS_gettid)
    
    u32 lock_index = getLockIndex(tid);
    // getLockIndex 展开为：
    // {
    //     u32 lock_index = tid;
    //     lock_index ^= lock_index >> 8;
    //     lock_index ^= lock_index >> 4;
    //     return lock_index % CONCURRENCY_LEVEL;  // % 16
    // }
    // 目的：将 tid 均匀分散到 16 个槽位
    
    // ==================== [3] 尝试获取锁 ====================
    if (!_locks[lock_index].tryLock() &&
        !_locks[lock_index = (lock_index + 1) % CONCURRENCY_LEVEL].tryLock() &&
        !_locks[lock_index = (lock_index + 2) % CONCURRENCY_LEVEL].tryLock())
    {
        // 所有 3 个锁都获取失败，说明并发信号太多
        atomicInc(_failures[-ticks_skipped]);
        // 记录跳过计数

        if (event_type == PERF_SAMPLE) {
            // 需要重置 perf_events ring buffer，否则会丢失数据
            PerfEvents::resetBuffer(tid);
        }
        return 0;
    }
    
    // ==================== [4] 记录栈回溯开始时间 ====================
    u64 stack_walk_begin = _features.stats ? OS::nanotime() : 0;
    // OS::nanotime() 展开为 clock_gettime(CLOCK_MONOTONIC)
    
    // ==================== [5] 获取帧缓冲区 ====================
    ASGCT_CallFrame* frames = _calltrace_buffer[lock_index]->_asgct_frames;
    jvmtiFrameInfo* jvmti_frames = _calltrace_buffer[lock_index]->_jvmti_frames;
    // 每个 lock_index 对应一个独立的缓冲区
    // 避免多线程竞争同一缓冲区
    
    // ==================== [6] 添加事件帧 ====================
    int num_frames = 0;
    if (_add_event_frame && event_type >= ALLOC_SAMPLE && event_type <= PARK_SAMPLE) {
        u32 class_id = ((EventWithClassId*)event)->_class_id;
        if (class_id != 0) {
            // 转换 event_type 到 frame_type
            // ALLOC_SAMPLE -> BCI_ALLOC
            // ALLOC_OUTSIDE_TLAB -> BCI_ALLOC_OUTSIDE_TLAB
            // LOCK_SAMPLE -> BCI_LOCK
            // PARK_SAMPLE -> BCI_PARK
            jint frame_type = BCI_ALLOC - (event_type - ALLOC_SAMPLE);
            num_frames = makeFrame(frames, frame_type, class_id);
        }
    }
    // makeFrame 展开为：
    // {
    //     frames[0].bci = type;
    //     frames[0].method_id = id;
    //     return 1;
    // }
    
    // ==================== [7] 获取 Native 栈 ====================
    StackContext java_ctx = {0};
    if (hasNativeStack(event_type)) {
        // hasNativeStack 检查事件类型是否需要 Native 栈：
        // PERF_SAMPLE, EXECUTION_SAMPLE, WALL_CLOCK_SAMPLE, 
        // NATIVE_LOCK_SAMPLE, MALLOC_SAMPLE, ALLOC_SAMPLE
        
        if (_features.pc_addr && event_type <= WALL_CLOCK_SAMPLE) {
            // 添加 PC 地址帧（调试用）
            num_frames += makeFrame(frames + num_frames, BCI_ADDRESS, StackFrame(ucontext).pc());
        }
        
        if (_cstack != CSTACK_NO) {
            num_frames += getNativeTrace(ucontext, frames + num_frames, event_type, tid, &java_ctx);
        }
    }
    
    // ==================== [8] 获取 Java 栈 ====================
    if (_features.mixed) {
        // mixed 模式：使用 VMStructs 统一栈回溯
        num_frames += StackWalker::walkVM(ucontext, frames + num_frames, _max_stack_depth, lock_index, _features, event_type);
    } else if (event_type <= MALLOC_SAMPLE) {
        if (_cstack == CSTACK_VM) {
            // VMStructs 栈回溯
            num_frames += StackWalker::walkVM(ucontext, frames + num_frames, _max_stack_depth, lock_index, _features, event_type);
        } else {
            // 异步栈回溯（AsyncGetCallTrace）
            int java_frames = getJavaTraceAsync(ucontext, frames + num_frames, _max_stack_depth, &java_ctx);
            if (java_frames > 0 && java_ctx.pc != NULL && VMStructs::hasMethodStructs()) {
                NMethod* nmethod = CodeHeap::findNMethod(java_ctx.pc);
                if (nmethod != NULL) {
                    fillFrameTypes(frames + num_frames, java_frames, nmethod);
                }
            }
            num_frames += java_frames;
        }
    } else if (event_type >= ALLOC_SAMPLE && event_type <= ALLOC_OUTSIDE_TLAB && _alloc_engine == &alloc_tracer) {
        // 分配采样：优先使用 VMStructs 栈回溯
        if (VMStructs::hasStackStructs()) {
            StackWalkFeatures no_features{};
            num_frames += StackWalker::walkVM(ucontext, frames + num_frames, _max_stack_depth, lock_index, no_features, event_type);
        } else {
            num_frames += getJavaTraceAsync(ucontext, frames + num_frames, _max_stack_depth, &java_ctx);
        }
    } else {
        // 锁事件和插桩事件：可以使用同步 JVMTI 栈回溯
        int start_depth = event_type == INSTRUMENTED_METHOD ? 1 : event_type == METHOD_TRACE ? 2 : 0;
        num_frames += getJavaTraceJvmti(jvmti_frames + num_frames, frames + num_frames, start_depth, _max_stack_depth);
    }
    
    // ==================== [9] 处理空栈 ====================
    if (num_frames == 0) {
        num_frames += makeFrame(frames + num_frames, BCI_ERROR, "no_Java_frame");
    }
    
    // ==================== [10] 添加附加帧 ====================
    if (_add_thread_frame) {
        num_frames += makeFrame(frames + num_frames, BCI_THREAD_ID, tid);
    }
    if (_add_sched_frame) {
        num_frames += makeFrame(frames + num_frames, BCI_ERROR, OS::schedPolicy(0));
        // OS::schedPolicy 获取调度策略：SCHED_OTHER/SCHED_FIFO/SCHED_RR
    }
    if (_add_cpu_frame && event_type == PERF_SAMPLE) {
        num_frames += makeFrame(frames + num_frames, BCI_CPU, java_ctx.cpu | 0x8000);
        // 记录 CPU 编号
    }
    
    // ==================== [11] 记录栈回溯时间 ====================
    if (stack_walk_begin != 0) {
        u64 stack_walk_end = OS::nanotime();
        atomicInc(_total_stack_walk_time, stack_walk_end - stack_walk_begin);
    }
    
    // ==================== [12] 存储调用栈 ====================
    u32 call_trace_id = _call_trace_storage.put(num_frames, frames, counter);
    // put() 内部：
    // 1. 计算哈希
    // 2. 查找/插入哈希表
    // 3. 存储 CallTrace 结构
    
    // ==================== [13] 记录 JFR 事件 ====================
    _jfr.recordEvent(lock_index, tid, call_trace_id, event_type, event);

    // ==================== [14] 释放锁并返回 ====================
    _locks[lock_index].unlock();
    return (u64)tid << 32 | call_trace_id;
    // 返回值：高 32 位是 tid，低 32 位是 call_trace_id
}
```

### 3.3 执行流程图

```
recordSample() 执行流程：

┌─────────────────────────────────────────────────────────────────┐
│                      信号处理器触发                              │
│                  (SIGPROF/SIGTRAP/...)                          │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         v
┌─────────────────────────────────────────────────────────────────┐
│ [1] atomicInc(_total_samples)                                   │
│     原子增加采样计数                                             │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         v
┌─────────────────────────────────────────────────────────────────┐
│ [2] tid = OS::threadId()                                        │
│     lock_index = getLockIndex(tid)                              │
│     计算锁索引（tid % 16）                                       │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         v
┌─────────────────────────────────────────────────────────────────┐
│ [3] tryLock() 尝试获取锁                                         │
│     失败：尝试下一个锁（最多 3 次）                              │
│     全失败：记录跳过，返回 0                                     │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         v
┌─────────────────────────────────────────────────────────────────┐
│ [4-6] 初始化帧缓冲区，添加事件帧                                 │
│     frames = _calltrace_buffer[lock_index]                      │
│     添加类 ID 帧（如果是分配事件）                               │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         v
┌─────────────────────────────────────────────────────────────────┐
│ [7] getNativeTrace() 获取 Native 栈                             │
│     ├─ PerfEvents::walk() - perf_event 采样                     │
│     ├─ StackWalker::walkDwarf() - DWARF 回溯                    │
│     └─ StackWalker::walkFP() - Frame Pointer 回溯               │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         v
┌─────────────────────────────────────────────────────────────────┐
│ [8] 获取 Java 栈                                                │
│     ├─ StackWalker::walkVM() - VMStructs 回溯                   │
│     ├─ getJavaTraceAsync() - AsyncGetCallTrace                  │
│     └─ getJavaTraceJvmti() - 同步 JVMTI 回溯                    │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         v
┌─────────────────────────────────────────────────────────────────┐
│ [9-10] 添加附加帧                                               │
│     ├─ 线程 ID 帧                                               │
│     ├─ 调度策略帧                                               │
│     └─ CPU 编号帧                                               │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         v
┌─────────────────────────────────────────────────────────────────┐
│ [12] _call_trace_storage.put()                                  │
│     存储调用栈，返回 call_trace_id                              │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         v
┌─────────────────────────────────────────────────────────────────┐
│ [13] _jfr.recordEvent()                                         │
│     记录 JFR 事件                                               │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         v
┌─────────────────────────────────────────────────────────────────┐
│ [14] unlock() 并返回 (tid << 32 | call_trace_id)                │
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. getJavaTraceAsync() - 异步栈回溯

### 4.1 完整逐行解析

```cpp
// 文件: profiler.cpp 第 377-546 行

int Profiler::getJavaTraceAsync(void* ucontext, ASGCT_CallFrame* frames, int max_depth, StackContext* java_ctx) {
    // ==================== [1] 获取 VMThread ====================
    VMThread* vm_thread = VMThread::current();
    // VMThread::current() 展开为：
    // {
    //     // 从 TLS 获取 VMThread
    //     int key = VMStructs::_thread_local_storage_offset;
    //     return (VMThread*)pthread_getspecific(key);
    // }
    
    if (vm_thread == NULL) {
        return 0;  // 不是 Java 线程
    }

    // ==================== [2] 获取 JNIEnv ====================
    JNIEnv* jni = vm_thread->jni();
    // jni() 展开为：
    // {
    //     // 从 VMThread 结构体中获取 _jni 字段
    //     return *(JNIEnv**)((char*)vm_thread + VMStructs::_jni_offset);
    // }
    
    if (jni == NULL) {
        return 0;  // 不是 Java 线程
    }

    // ==================== [3] 保存寄存器状态 ====================
    StackFrame frame(ucontext);
    uintptr_t saved_pc, saved_sp, saved_fp;
    if (ucontext != NULL) {
        saved_pc = frame.pc();
        saved_sp = frame.sp();
        saved_fp = frame.fp();
        // StackFrame 展开为：
        // pc() -> _ucontext->uc_mcontext.gregs[REG_RIP]
        // sp() -> _ucontext->uc_mcontext.gregs[REG_RSP]
        // fp() -> _ucontext->uc_mcontext.gregs[REG_RBP]
    }

    // ==================== [4] 处理 inJava 状态 ====================
    if (_features.unwind_native && vm_thread->inJava()) {
        // 如果线程在 Java 状态，手动展开到最后的 Java 帧
        if (saved_pc >= (uintptr_t)_call_stub_begin && saved_pc < (uintptr_t)_call_stub_end) {
            // call_stub 是危险的，不能回溯
            frames->bci = BCI_ERROR;
            frames->method_id = (jmethodID)"call_stub";
            return 1;
        }
        if (DWARF_SUPPORTED && java_ctx->sp != 0) {
            // 使用 DWARF 信息展开
            frame.restore((uintptr_t)java_ctx->pc, java_ctx->sp, java_ctx->fp);
        }
    }

    // ==================== [5] 调用 AsyncGetCallTrace ====================
    JitWriteProtection jit(false);
    // JitWriteProtection 是一个 RAII 类，暂时禁用 JIT 写保护
    
    ASGCT_CallTrace trace = {jni, 0, frames};
    VM::_asyncGetCallTrace(&trace, max_depth, ucontext);
    // _asyncGetCallTrace 是 JVM 导出的函数：
    // void AsyncGetCallTrace(ASGCT_CallTrace* trace, jint depth, void* ucontext)
    
    // ==================== [6] 处理成功情况 ====================
    if (trace.num_frames > 0) {
        frame.restore(saved_pc, saved_sp, saved_fp);
        return trace.num_frames;
    }

    // ==================== [7] 处理各种错误情况 ====================
    
    // [7.1] ticks_unknown_Java / ticks_not_walkable_Java
    if ((trace.num_frames == ticks_unknown_Java || trace.num_frames == ticks_not_walkable_Java) 
        && _features.unknown_java && ucontext != NULL) {
        
        // 尝试找到 Runtime Stub
        CodeBlob* stub = NULL;
        _stubs_lock.lockShared();
        if (_runtime_stubs.contains((const void*)frame.pc())) {
            stub = findRuntimeStub((const void*)frame.pc());
        }
        _stubs_lock.unlockShared();

        if (stub != NULL) {
            // 处理 vtable stub
            if (_features.vtable_target && isVTableStub(stub->_name)) {
                uintptr_t receiver = frame.jarg0();
                // jarg0() 获取第一个参数（RDI 寄存器）
                if (receiver != 0) {
                    VMSymbol* symbol = VMKlass::fromOop(receiver)->name();
                    u32 class_id = classMap()->lookup(symbol->body(), symbol->length());
                    max_depth -= makeFrame(trace.frames++, BCI_ALLOC, class_id);
                }
            }
            
            // 添加 stub 帧
            max_depth -= makeFrame(trace.frames++, BCI_NATIVE_FRAME, stub->_name);
            
            // 尝试展开 stub
            if (_features.unwind_stub && frame.unwindStub((instruction_t*)stub->_start, stub->_name)
                    && isAddressInCode((const void*)frame.pc())) {
                java_ctx->pc = (const void*)frame.pc();
                VM::_asyncGetCallTrace(&trace, max_depth, ucontext);
            }
        } else if (VMStructs::hasMethodStructs()) {
            // 尝试找到 nmethod
            NMethod* nmethod = CodeHeap::findNMethod((const void*)frame.pc());
            if (nmethod != NULL && nmethod->isNMethod() && nmethod->isAlive()) {
                VMMethod* method = nmethod->method();
                if (method != NULL) {
                    jmethodID method_id = method->id();
                    if (method_id != NULL) {
                        max_depth -= makeFrame(trace.frames++, 0, method_id);
                    }
                    
                    // 尝试展开编译帧
                    if (_features.unwind_comp && frame.unwindCompiled(nmethod)
                            && isAddressInCode((const void*)frame.pc())) {
                        VM::_asyncGetCallTrace(&trace, max_depth, ucontext);
                    }
                    
                    // 尝试探测 SP
                    if (_features.probe_sp && trace.num_frames < 0) {
                        if (method_id != NULL) {
                            trace.frames--;
                        }
                        for (int i = 0; trace.num_frames < 0 && i < PROBE_SP_LIMIT; i++) {
                            frame.sp() += sizeof(void*);
                            VM::_asyncGetCallTrace(&trace, max_depth, ucontext);
                        }
                    }
                }
            }
        }
    }
    // [7.2] ticks_unknown_not_Java
    else if (trace.num_frames == ticks_unknown_not_Java && _features.java_anchor) {
        JavaFrameAnchor* anchor = vm_thread->anchor();
        uintptr_t sp = anchor->lastJavaSP();
        const void* pc = anchor->lastJavaPC();
        
        if (sp != 0 && pc == NULL) {
            // 有 last Java frame anchor，但不可 walkable
            // 尝试让它变得 walkable
            pc = ((const void**)sp)[-1];  // 从栈中获取返回地址
            anchor->setLastJavaPC(pc);

            NMethod* m = CodeHeap::findNMethod(pc);
            if (m != NULL) {
                // 修复 frame_complete_offset
                if (!m->isNMethod() && m->frameSize() > 0 && m->frameCompleteOffset() == -1) {
                    m->setFrameCompleteOffset(0);
                }
                VM::_asyncGetCallTrace(&trace, max_depth, ucontext);
            } else if (findLibraryByAddress(pc) != NULL) {
                VM::_asyncGetCallTrace(&trace, max_depth, ucontext);
            }

            anchor->setLastJavaPC(NULL);  // 恢复
        }
    }
    // [7.3] ticks_not_walkable_not_Java
    else if (trace.num_frames == ticks_not_walkable_not_Java && _features.java_anchor) {
        JavaFrameAnchor* anchor = vm_thread->anchor();
        uintptr_t sp = anchor->lastJavaSP();
        const void* pc = anchor->lastJavaPC();
        
        if (sp != 0 && pc != NULL) {
            NMethod* m = CodeHeap::findNMethod(pc);
            if (m != NULL && !m->isNMethod() && m->frameSize() > 0 && m->frameCompleteOffset() == -1) {
                m->setFrameCompleteOffset(0);
                VM::_asyncGetCallTrace(&trace, max_depth, ucontext);
            }
        }
    }
    // [7.4] ticks_GC_active
    else if (trace.num_frames == ticks_GC_active && _features.gc_traces) {
        if (vm_thread->anchor()->lastJavaSP() == 0) {
            // 没有Java帧的线程（如 Compiler 线程）
            frame.restore(saved_pc, saved_sp, saved_fp);
            return 0;
        }
    }

    // ==================== [8] 恢复寄存器状态 ====================
    frame.restore(saved_pc, saved_sp, saved_fp);

    // ==================== [9] 处理最终结果 ====================
    if (trace.num_frames > 0) {
        return trace.num_frames + (trace.frames - frames);
    }

    const char* err_string = asgctError(trace.num_frames);
    if (err_string == NULL) {
        return 0;  // 不是错误，只是不在 Java 上下文
    }

    // 记录错误
    atomicInc(_failures[-trace.num_frames]);
    trace.frames->bci = BCI_ERROR;
    trace.frames->method_id = (jmethodID)err_string;
    return trace.frames - frames + 1;
}
```

### 4.2 AsyncGetCallTrace 错误码

```cpp
// 文件: profiler.cpp 第 155-185 行

const char* Profiler::asgctError(int code) {
    switch (code) {
        case ticks_no_Java_frame:
        case ticks_unknown_not_Java:
            // 完全不在 Java 上下文，不是错误
            return NULL;
            
        case ticks_thread_exit:
            // 线程正在退出，最后的 Java 帧已弹出
            return NULL;
            
        case ticks_GC_active:
            // GC 活动中
            return "GC_active";
            
        case ticks_unknown_Java:
            // 未知的 Java 帧
            return "unknown_Java";
            
        case ticks_not_walkable_Java:
            // Java 帧不可遍历
            return "not_walkable_Java";
            
        case ticks_not_walkable_not_Java:
            // Native 帧不可遍历
            return "not_walkable_not_Java";
            
        case ticks_deopt:
            // 正在反优化
            return "deoptimization";
            
        case ticks_safepoint:
            // 在 Safepoint
            return "safepoint";
            
        case ticks_skipped:
            // 被跳过
            return "skipped";
            
        case ticks_unknown_state:
            // 未知状态（Zing 可能返回）
            return "unknown_state";
            
        default:
            return "unexpected_state";
    }
}
```

---

## 5. start() - 启动采样

### 5.1 完整逐行解析

```cpp
// 文件: profiler.cpp 第 1051-1291 行

Error Profiler::start(Arguments& args, bool reset) {
    // ==================== [1] 状态检查 ====================
    MutexLocker ml(_state_lock);
    if (_state > IDLE) {
        return Error("Profiler already started");
    }
    // _state > IDLE 表示 RUNNING 状态
    
    // ==================== [2] 尝试附加到 JVM ====================
    if (!VM::loaded()) {
        VM::tryAttach();
        // 尝试通过 Attach API 连接到运行中的 JVM
    }

    // ==================== [3] 检查 JVM 能力 ====================
    Error error = checkJvmCapabilities();
    if (error) {
        return error;
    }
    // checkJvmCapabilities 检查：
    // - Thread ID 字段是否存在
    // - VMThread bridge 是否可用
    // - dlopen hook 是否可设置

    // ==================== [4] 解析事件掩码 ====================
    _event_mask = args.eventMask();
    // eventMask 返回：
    // EM_CPU (1) - CPU 采样
    // EM_ALLOC (2) - 分配采样
    // EM_LOCK (4) - 锁采样
    // EM_WALL (8) - Wall Clock
    // EM_NATIVEMEM (16) - Native 内存
    // EM_NATIVELOCK (32) - Native 锁

    if (_event_mask == 0) {
        return Error("No profiling events specified");
    } else if ((_event_mask & (_event_mask - 1)) && args._output != OUTPUT_JFR) {
        // 多个事件类型，但输出格式不是 JFR
        return Error("Only JFR output supports multiple events");
    }

    // ==================== [5] 初始化数据结构 ====================
    if (reset || _start_time == 0) {
        _total_samples = 0;
        _total_stack_walk_time = 0;
        memset(_failures, 0, sizeof(_failures));

        lockAll();
        _class_map.clear();
        _thread_filter.clear();
        _call_trace_storage.clear();
        _add_event_frame = args._output != OUTPUT_JFR;
        _add_thread_frame = args._threads && args._output != OUTPUT_JFR;
        _add_sched_frame = args._sched;
        _add_cpu_frame = args._record_cpu;
        unlockAll();
    }

    // ==================== [6] 分配帧缓冲区 ====================
    if (_max_stack_depth != args._jstackdepth) {
        _max_stack_depth = args._jstackdepth;
        size_t nelem = _max_stack_depth + MAX_NATIVE_FRAMES + RESERVED_FRAMES;
        // MAX_NATIVE_FRAMES = 128
        // RESERVED_FRAMES = 10

        for (int i = 0; i < CONCURRENCY_LEVEL; i++) {
            free(_calltrace_buffer[i]);
            _calltrace_buffer[i] = (CallTraceBuffer*)calloc(nelem, sizeof(CallTraceBuffer));
            if (_calltrace_buffer[i] == NULL) {
                return Error("Not enough memory to allocate stack trace buffers");
            }
        }
    }

    // ==================== [7] 设置特性标志 ====================
    _features = args._features;
    if (VM::hotspot_version() < 8) {
        _features.java_anchor = 0;
        _features.gc_traces = 0;
    }

    // ==================== [8] 选择引擎 ====================
    _engine = selectEngine(args._event);
    // selectEngine 根据 event_name 返回对应引擎：
    // "cpu" -> perf_events / ctimer / wall_clock
    // "wall" -> wall_clock / j9_wall_clock
    // "itimer" -> itimer
    // 包含 "." -> instrument
    
    // ==================== [9] 检查 C 栈回溯方式 ====================
    _cstack = args._cstack;
    if (_cstack == CSTACK_DWARF && !DWARF_SUPPORTED) {
        return Error("DWARF unwinding is not supported on this platform");
    }
    
    if (_cstack == CSTACK_DEFAULT) {
        if (VMStructs::hasStackStructs()) {
            _cstack = CSTACK_VM;  // 优先使用 VMStructs
        } else if (VM::isOpenJ9() && DWARF_SUPPORTED) {
            _cstack = CSTACK_DWARF;
        }
    }

    // ==================== [10] 更新符号表 ====================
    updateSymbols(_engine == &perf_events && !args._alluser);
    // 解析所有 native 库的符号

    // ==================== [11] 安装 Trap ====================
    error = installTraps(args._begin, args._end, args._nostop);
    if (error) {
        return error;
    }
    switchLibraryTrap(true);
    // 启用 dlopen hook

    // ==================== [12] 启动 JFR ====================
    if (args._output == OUTPUT_JFR) {
        error = _jfr.start(args, reset);
        if (error) {
            uninstallTraps();
            switchLibraryTrap(false);
            return error;
        }
    }

    // ==================== [13] 启动主引擎 ====================
    error = _engine->start(args);
    if (error) {
        goto error1;
    }

    // ==================== [14] 启动附加引擎 ====================
    if (_event_mask & EM_ALLOC) {
        _alloc_engine = selectAllocEngine(args._alloc, args._live);
        error = _alloc_engine->start(args);
        if (error) goto error2;
    }
    
    if (_event_mask & EM_LOCK) {
        error = lock_tracer.start(args);
        if (error) goto error3;
    }
    
    if (_event_mask & EM_WALL) {
        error = wall_clock.start(args);
        if (error) goto error4;
    }
    
    if (_event_mask & EM_NATIVEMEM) {
        error = malloc_tracer.start(args);
        if (error) goto error5;
    }
    
    if (_event_mask & EM_NATIVELOCK) {
        error = native_lock_tracer.start(args);
        if (error) goto error6;
    }
    
    if (_event_mask & EM_METHOD_TRACE) {
        error = instrument.start(args);
        if (error) goto error7;
    }

    // ==================== [15] 启用线程事件 ====================
    switchThreadEvents(JVMTI_ENABLE);

    // ==================== [16] 更新状态 ====================
    _state = RUNNING;
    _start_time = OS::micros();
    _epoch++;

    // ==================== [17] 启动定时器 ====================
    if (args._timeout != 0 || args._loop != 0 || args._output == OUTPUT_JFR) {
        _loop_time = addTimeout(_start_time, args._loop);
        _stop_time = addTimeout(_start_time, args._timeout);
        startTimer();
    }

    return Error::OK;

    // ==================== [错误处理] ====================
error7:
    if (_event_mask & EM_NATIVELOCK) native_lock_tracer.stop();
error6:
    if (_event_mask & EM_NATIVEMEM) malloc_tracer.stop();
error5:
    if (_event_mask & EM_WALL) wall_clock.stop();
error4:
    if (_event_mask & EM_LOCK) lock_tracer.stop();
error3:
    if (_event_mask & EM_ALLOC) _alloc_engine->stop();
error2:
    _engine->stop();
error1:
    uninstallTraps();
    switchLibraryTrap(false);
    lockAll();
    _jfr.stop();
    unlockAll();
    FdTransferClient::closePeer();
    return error;
}
```

### 5.2 start() 流程图

```
start() 执行流程：

┌─────────────────────────────────────────────────────────────────┐
│ [1] 状态检查：_state <= IDLE ?                                  │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         v
┌─────────────────────────────────────────────────────────────────┐
│ [2-3] 尝试附加到 JVM，检查 JVM 能力                             │
│       - Thread ID 字段存在？                                    │
│       - VMThread bridge 可用？                                  │
│       - dlopen hook 可设置？                                    │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         v
┌─────────────────────────────────────────────────────────────────┐
│ [4-6] 解析事件掩码，初始化数据结构                               │
│       - 重置计数器                                              │
│       - 分配帧缓冲区                                            │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         v
┌─────────────────────────────────────────────────────────────────┐
│ [7-9] 设置特性标志，选择引擎，配置 C 栈回溯                      │
│       _engine = selectEngine(event)                             │
│       _cstack = CSTACK_VM / CSTACK_DWARF / CSTACK_FP            │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         v
┌─────────────────────────────────────────────────────────────────┐
│ [10-11] 更新符号表，安装 Trap                                   │
│         updateSymbols()                                         │
│         installTraps()                                          │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         v
┌─────────────────────────────────────────────────────────────────┐
│ [12] 启动 JFR（如果需要）                                       │
│      _jfr.start()                                               │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         v
┌─────────────────────────────────────────────────────────────────┐
│ [13] 启动主引擎                                                 │
│      _engine->start()                                           │
│      ├─ perf_events->start() - CPU 采样                         │
│      ├─ wall_clock->start() - Wall Clock                        │
│      └─ instrument->start() - 字节码插桩                        │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         v
┌─────────────────────────────────────────────────────────────────┐
│ [14] 启动附加引擎                                               │
│      ├─ alloc_engine->start() - 分配采样                        │
│      ├─ lock_tracer.start() - 锁采样                            │
│      ├─ wall_clock.start() - Wall Clock（作为附加）             │
│      ├─ malloc_tracer.start() - Native 内存                     │
│      ├─ native_lock_tracer.start() - Native 锁                  │
│      └─ instrument.start() - 方法追踪                           │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         v
┌─────────────────────────────────────────────────────────────────┐
│ [15-17] 启用线程事件，更新状态，启动定时器                       │
│         _state = RUNNING                                        │
│         startTimer() - 启动后台定时线程                         │
└─────────────────────────────────────────────────────────────────┘
```

---

## 6. 引擎选择机制

### 6.1 selectEngine()

```cpp
// 文件: profiler.cpp 第 969-995 行

Engine* Profiler::selectEngine(const char* event_name) {
    if (event_name == NULL) {
        return &noop_engine;
    } 
    else if (strcmp(event_name, EVENT_CPU) == 0) {
        // EVENT_CPU = "cpu"
        if (FdTransferClient::hasPeer() || PerfEvents::supported()) {
            return &perf_events;
        } else if (CTimer::supported()) {
            return &ctimer;
        } else {
            return &wall_clock;  // 最后的 fallback
        }
    } 
    else if (strcmp(event_name, EVENT_WALL) == 0) {
        // EVENT_WALL = "wall"
        if (VM::isOpenJ9()) {
            return &j9_wall_clock;
        } else {
            return &wall_clock;
        }
    } 
    else if (strcmp(event_name, EVENT_CTIMER) == 0) {
        return &ctimer;
    } 
    else if (strcmp(event_name, EVENT_ITIMER) == 0) {
        return &itimer;
    } 
    else if (strchr(event_name, '.') != NULL && strchr(event_name, ':') == NULL) {
        // 包含 '.' 但不包含 ':'，认为是 Java 方法名
        // 如 "com/example.MyClass.myMethod"
        return &instrument;
    } 
    else {
        // 其他情况，尝试作为 perf 事件
        return &perf_events;
    }
}
```

### 6.2 selectAllocEngine()

```cpp
// 文件: profiler.cpp 第 997-1005 行

Engine* Profiler::selectAllocEngine(long alloc_interval, bool live) {
    if (VM::addSampleObjectsCapability()) {
        // JVM 支持 JVMTI SampledObjectAlloc
        return &object_sampler;
    } 
    else if (VM::isOpenJ9()) {
        return &j9_object_sampler;
    } 
    else {
        // 使用 INT3 Trap 机制
        return &alloc_tracer;
    }
}
```

### 6.3 引擎优先级

```
CPU 采样引擎选择优先级：

1. perf_events (首选)
   - 硬件性能计数器
   - 最低开销
   - 需要 Linux perf_event_open 支持

2. ctimer (备选)
   - 基于 CPU 时钟的计时器
   - 需要 CTimer 支持

3. wall_clock (最后备选)
   - 轮询所有线程
   - 开销较高
   - 总是可用

分配追踪引擎选择优先级：

1. object_sampler (首选)
   - JVMTI SampledObjectAlloc
   - JVM 内置采样
   - 最低开销

2. j9_object_sampler (OpenJ9 专用)
   - OpenJ9 的对象采样机制

3. alloc_tracer (备选)
   - INT3 Trap 机制
   - 需要注入断点
   - 开销较高
```

---

## 7. 输出格式

### 7.1 dumpFlameGraph()

```cpp
// 文件: profiler.cpp 第 1474-1539 行

void Profiler::dumpFlameGraph(Writer& out, Arguments& args, bool tree) {
    // [1] 设置标题
    char title[64];
    if (args._title == NULL) {
        Engine* active_engine = activeEngine();
        if (args._counter == COUNTER_SAMPLES) {
            strcpy(title, active_engine->title());
        } else {
            snprintf(title, sizeof(title), "%s (%s)", 
                     active_engine->title(), active_engine->units());
        }
    }

    // [2] 创建 FlameGraph 对象
    FlameGraph flamegraph(args._title == NULL ? title : args._title, 
                          args._counter, args._minwidth, args._reverse, args._inverted);

    // [3] 收集所有调用栈
    FrameName fn(args, args._style & ~STYLE_ANNOTATE, _epoch, _thread_names_lock, _thread_names);
    std::vector<CallTraceSample*> samples;
    _call_trace_storage.collectSamples(samples);

    // [4] 构建火焰图树
    for (std::vector<CallTraceSample*>::const_iterator it = samples.begin(); 
         it != samples.end(); ++it) {
        
        CallTrace* trace = (*it)->acquireTrace();
        if (trace == NULL || fn.excludeTrace(trace)) continue;

        u64 counter = args._counter == COUNTER_SAMPLES ? 
                      (*it)->samples : (*it)->counter;
        if (counter == 0) continue;

        int num_frames = trace->num_frames;
        Trie* f = flamegraph.root();

        if (args._reverse) {
            // 反向：从根到底
            for (int j = 0; j < num_frames; j++) {
                const char* frame_name = fn.name(trace->frames[j]);
                FrameTypeId frame_type = fn.type(trace->frames[j]);
                f = flamegraph.addChild(f, frame_name, frame_type, counter);
            }
        } else {
            // 正向：从底到根
            for (int j = num_frames - 1; j >= 0; j--) {
                const char* frame_name = fn.name(trace->frames[j]);
                FrameTypeId frame_type = fn.type(trace->frames[j]);
                f = flamegraph.addChild(f, frame_name, frame_type, counter);
            }
        }
        
        f->_total += counter;
        f->_self += counter;
    }

    // [5] 输出火焰图
    flamegraph.dump(out, tree);
}
```

### 7.2 dumpText()

```cpp
// 文件: profiler.cpp 第 1541-1628 行

void Profiler::dumpText(Writer& out, Arguments& args) {
    FrameName fn(args, args._style | STYLE_DOTTED, _epoch, _thread_names_lock, _thread_names);
    
    // [1] 收集样本
    std::vector<CallTraceSample> samples;
    u64 total_counter = 0;
    {
        std::map<u64, CallTraceSample> map;
        _call_trace_storage.collectSamples(map);
        samples.reserve(map.size());
        
        for (std::map<u64, CallTraceSample>::const_iterator it = map.begin(); 
             it != map.end(); ++it) {
            // ...
        }
    }

    // [2] 打印摘要
    snprintf(buf, sizeof(buf) - 1,
            "--- Execution profile ---\n"
            "Total samples       : %lld\n",
            _total_samples);
    out << buf;

    // [3] 打印错误统计
    for (int i = 1; i < ASGCT_FAILURE_TYPES; i++) {
        const char* err_string = asgctError(-i);
        if (err_string != NULL && _failures[i] > 0) {
            snprintf(buf, sizeof(buf), "%-20s: %lld (%.2f%%)\n", 
                     err_string, _failures[i], _failures[i] * spercent);
            out << buf;
        }
    }

    // [4] 打印 Top 调用栈
    if (args._dump_traces > 0) {
        std::sort(samples.begin(), samples.end(), 
                  [](const CallTraceSample& a, const CallTraceSample& b) {
                      return a.counter > b.counter;
                  });
        
        for (auto& sample : samples) {
            // 打印每个调用栈
        }
    }

    // [5] 打印 Top 方法
    if (args._dump_flat > 0) {
        std::map<std::string, MethodSample> histogram;
        for (auto& sample : samples) {
            const char* frame_name = fn.name(sample.trace->frames[0]);
            histogram[frame_name].add(sample.samples, sample.counter);
        }
        // 排序并打印
    }
}
```

---

## 8. 定时器机制

### 8.1 timerLoop()

```cpp
// 文件: profiler.cpp 第 1713-1741 行

void Profiler::timerLoop(void* timer_id) {
    u64 current_micros = OS::micros();
    u64 loop_limit = std::min(_stop_time, _loop_time);
    u64 sleep_until = _jfr.active() ? current_micros + 1000000 : loop_limit;

    while (true) {
        {
            // 释放锁后睡眠，避免与 stop() 死锁
            MutexLocker ml(_timer_lock);
            while (_timer_id == timer_id && !_timer_lock.waitUntil(sleep_until)) {
                // 超时未到达，继续等待
            }
            if (_timer_id != timer_id) return;  // 被停止
        }

        // 检查是否到达时间限制
        if ((current_micros = OS::micros()) >= loop_limit) {
            expire(_global_args, current_micros < _stop_time);
            return;
        }

        // JFR 定时刷新
        bool need_switch_chunk = _jfr.timerTick(current_micros, _gc_id);
        if (need_switch_chunk) {
            flushJfr();
        }

        sleep_until = current_micros + 1000000;  // 1 秒
    }
}
```

---

## 9. 完整架构图

```
Profiler 核心架构：

┌─────────────────────────────────────────────────────────────────────────┐
│                           Profiler (单例)                                │
├─────────────────────────────────────────────────────────────────────────┤
│  状态管理                                                                │
│  ├─ _state_lock: Mutex                                                  │
│  ├─ _state: NEW -> IDLE -> RUNNING -> TERMINATED                        │
│  └─ _epoch: 轮次计数                                                    │
├─────────────────────────────────────────────────────────────────────────┤
│  引擎管理                                                                │
│  ├─ _engine: Engine* (主采样引擎)                                        │
│  │    ├─ PerfEvents: CPU 采样 (perf_event_open)                         │
│  │    ├─ WallClock: 轮询采样                                            │
│  │    ├─ ITimer: SIGPROF 定时器                                         │
│  │    └─ Instrument: 字节码插桩                                          │
│  │                                                                      │
│  ├─ _alloc_engine: Engine* (分配追踪)                                   │
│  │    ├─ ObjectSampler: JVMTI SampledObjectAlloc                        │
│  │    └─ AllocTracer: INT3 Trap                                         │
│  │                                                                      │
│  └─ 附加引擎: LockTracer, MallocTracer, NativeLockTracer               │
├─────────────────────────────────────────────────────────────────────────┤
│  栈回溯                                                                  │
│  ├─ _cstack: CSTACK_VM / CSTACK_DWARF / CSTACK_FP / CSTACK_LBR          │
│  ├─ StackWalker::walkVM(): VMStructs 统一回溯                           │
│  ├─ getJavaTraceAsync(): AsyncGetCallTrace                              │
│  └─ getJavaTraceJvmti(): 同步 JVMTI 栈遍历                              │
├─────────────────────────────────────────────────────────────────────────┤
│  数据存储                                                                │
│  ├─ _call_trace_storage: CallTraceStorage                               │
│  │    ├─ LinearAllocator: 线性分配器                                    │
│  │    └─ LongHashTable: 哈希表                                          │
│  │                                                                      │
│  ├─ _jfr: FlightRecorder                                                │
│  │    └─ Buffer: JFR 二进制缓冲区                                       │
│  │                                                                      │
│  └─ _class_map / _thread_names / _thread_ids                           │
├─────────────────────────────────────────────────────────────────────────┤
│  并发控制                                                                │
│  ├─ _locks[16]: SpinLock 数组                                           │
│  ├─ _calltrace_buffer[16]: 帧缓冲区数组                                 │
│  └─ getLockIndex(tid): 哈希到锁索引                                     │
├─────────────────────────────────────────────────────────────────────────┤
│  符号管理                                                                │
│  ├─ _native_libs: CodeCacheArray (所有 Native 库)                       │
│  ├─ _runtime_stubs: CodeCache (JVM Runtime Stub)                        │
│  └─ findNativeMethod(): 查找 Native 方法符号                            │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 10. 性能分析

### 10.1 并发设计

```
锁设计：

1. 全局状态锁 (_state_lock)
   - 保护 _state 变量
   - start/stop 时持有
   - 采样时不持有

2. 自旋锁数组 (_locks[16])
   - 每个信号处理器获取一个锁
   - 通过 tid 哈希到锁索引
   - 避免全局竞争

3. 线程名锁 (_thread_names_lock)
   - 保护 _thread_names / _thread_ids
   - 仅在更新线程名时持有

4. Stub 锁 (_stubs_lock)
   - 保护 _runtime_stubs
   - 读多写少，使用读写锁

帧缓冲区设计：

- 16 个独立缓冲区 (_calltrace_buffer[16])
- 每个缓冲区大小 = max_stack_depth + 128 + 10
- 每个 lock_index 对应一个缓冲区
- 避免多线程竞争同一缓冲区
```

### 10.2 热路径分析

```
recordSample() 热路径：

1. atomicInc(_total_samples)
   - 约 10-20 CPU 周期

2. getLockIndex(tid)
   - 约 5-10 CPU 周期

3. tryLock()
   - 无竞争：约 10 CPU 周期
   - 有竞争：可能自旋等待

4. 栈回溯 (最耗时部分)
   - Native 栈：100-1000 CPU 周期/帧
   - Java 栈：取决于 AGCT 实现

5. _call_trace_storage.put()
   - 哈希计算：约 50-100 CPU 周期
   - CAS 插入：约 20-50 CPU 周期

6. _jfr.recordEvent()
   - 变长编码写入：约 50-100 CPU 周期

总耗时估算：
- 短调用栈 (< 10 帧)：约 1-5 微秒
- 长调用栈 (> 100 帧)：约 10-50 微秒
```
