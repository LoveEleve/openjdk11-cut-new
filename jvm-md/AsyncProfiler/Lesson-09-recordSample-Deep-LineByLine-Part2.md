# Lesson 9 续：recordSample() 深度逐行解析（栈回溯与存储部分）

> 继续对 `recordSample()` 的栈回溯和存储部分进行深度解析。

---

## 7. getNativeTrace() - Native 栈回溯

### 第 315-331 行：getNativeTrace() 函数

```cpp
// 文件: profiler.cpp 第 315-331 行
int Profiler::getNativeTrace(void* ucontext, ASGCT_CallFrame* frames, EventType event_type, int tid, StackContext* java_ctx) {
    const void* callchain[MAX_NATIVE_FRAMES];
    int native_frames;

    if (event_type == PERF_SAMPLE) {
        native_frames = PerfEvents::walk(tid, ucontext, callchain, MAX_NATIVE_FRAMES, java_ctx);
    } else if (_cstack == CSTACK_VM) {
        return 0;
    } else if (_cstack == CSTACK_DWARF) {
        native_frames = StackWalker::walkDwarf(ucontext, callchain, MAX_NATIVE_FRAMES, java_ctx);
    } else {
        native_frames = StackWalker::walkFP(ucontext, callchain, MAX_NATIVE_FRAMES, java_ctx);
    }

    return convertNativeTrace(native_frames, callchain, frames, event_type);
}
```

#### 7.1 功能定位

**一句话说明**：根据配置选择 Native 栈回溯方式，返回 PC 地址数组，然后转换为帧格式。

**解决什么问题？**
- Native 代码（C/C++）没有像 Java 那样的统一栈格式
- 不同场景需要不同的回溯策略：性能 vs 准确性

#### 7.2 展开栈回溯策略选择

```cpp
// 展开步骤 1: 理解四种栈回溯方式

// [方式 1] PerfEvents::walk() - perf_event 专用
//   触发条件: event_type == PERF_SAMPLE
//   原理: 内核已经记录了完整的调用栈（使用 PERF_SAMPLE_STACK_USER）
//   优点: 
//     - 最准确（内核在信号触发时记录）
//     - 支持 LBR（Last Branch Record）
//   缺点:
//     - 只能用于 perf_event 采样
//     - 需要额外的 ring buffer 空间

// [方式 2] CSTACK_VM - 不回溯 Native 栈
//   触发条件: _cstack == CSTACK_VM
//   原理: 完全依赖 VMStructs，忽略 Native 帧
//   优点:
//     - 最快（无 Native 回溯开销）
//     - 与 JVM 内部帧处理一致
//   缺点:
//     - 丢失 Native 调用信息

// [方式 3] StackWalker::walkDwarf() - DWARF CFI 回溯
//   触发条件: _cstack == CSTACK_DWARF
//   原理: 使用 .eh_frame 段的 DWARF 调用帧信息
//   优点:
//     - 适用于无 Frame Pointer 的代码
//     - 支持所有优化级别
//   缺点:
//     - 需要解析 DWARF 信息（启动时预计算）
//     - 更复杂

// [方式 4] StackWalker::walkFP() - Frame Pointer 回溯
//   触发条件: 默认方式
//   原理: 遍历 rbp 链（Frame Pointer Chain）
//   优点:
//     - 最简单、最快
//     - 无需额外信息
//   缺点:
//     - 需要 -fno-omit-frame-pointer 编译
//     - 优化代码可能丢失帧
```

#### 7.3 六层面分析

| 层面 | 分析 |
|------|------|
| **设计原理** | 为什么有四种方式？<br>不同场景需要不同的权衡：<br>- PerfEvents: 内核已经记录，直接用<br>- DWARF: 无 Frame Pointer 时必需<br>- FP: 最快，适用于调试构建<br>- VM: 只关心 Java 帧 |
| **边界条件** | 栈溢出/无效帧如何处理？<br>每种 walk 函数都有边界检查：<br>- `fp < sp`: 栈向低地址增长，FP 不能小于 SP<br>- `fp >= sp + MAX_FRAME_SIZE`: 帧大小限制<br>- `inDeadZone(pc)`: PC 指针有效性检查 |
| **并发安全** | 所有 walk 函数只读不写，线程安全。 |
| **JVM 交互** | `StackContext* java_ctx` 记录第一个 Java 帧的位置，传递给后续的 Java 栈回溯。 |
| **性能影响** | FP 回溯: ~50 周期/帧<br>DWARF 回溯: ~100-200 周期/帧<br>PerfEvents: 已由内核完成，~0 周期 |
| **替代方案** | 使用 libunwind？<br>问题：libunwind 在信号处理器中使用可能不安全。<br>AsyncProfiler 自己实现，更可控。 |

---

## 8. StackWalker::walkFP() - Frame Pointer 回溯实现

### 第 65-113 行：walkFP() 函数

```cpp
// 文件: stackWalker.cpp 第 65-113 行
int StackWalker::walkFP(void* ucontext, const void** callchain, int max_depth, StackContext* java_ctx) {
    const void* pc;
    uintptr_t fp;
    uintptr_t sp;
    uintptr_t bottom = (uintptr_t)&sp + MAX_WALK_SIZE;

    StackFrame frame(ucontext);
    if (ucontext == NULL) {
        pc = callerPC();
        fp = (uintptr_t)callerFP();
        sp = (uintptr_t)callerSP();
    } else {
        pc = (const void*)frame.pc();
        fp = frame.fp();
        sp = frame.sp();
    }

    int depth = 0;

    while (depth < max_depth) {
        // [检查 1] 是否到达 Java 代码
        if (CodeHeap::contains(pc) && !(depth == 0 && frame.unwindAtomicStub(pc))) {
            java_ctx->set(pc, sp, fp);
            break;
        }

        callchain[depth++] = pc;

        // [检查 2] FP 是否有效
        if (fp < sp || fp >= sp + MAX_FRAME_SIZE || fp >= bottom) {
            break;
        }

        // [检查 3] 对齐检查
        if (!aligned(fp)) {
            break;
        }

        // [核心操作] 获取上一帧
        pc = stripPointer(SafeAccess::load((void**)fp + FRAME_PC_SLOT));
        if (inDeadZone(pc)) {
            break;
        }

        sp = fp + (FRAME_PC_SLOT + 1) * sizeof(void*);
        fp = *(uintptr_t*)fp;
    }

    return depth;
}
```

#### 8.1 核心算法展开

```cpp
// 展开步骤 1: StackFrame 类定义
// 文件: stackFrame.h
class StackFrame {
  private:
    ucontext_t* _ucontext;
    
  public:
    StackFrame(void* ucontext) : _ucontext((ucontext_t*)ucontext) {}
    
    // x86_64 实现
    uintptr_t& pc() {
        return (uintptr_t&)_ucontext->uc_mcontext.gregs[REG_RIP];
    }
    uintptr_t& sp() {
        return (uintptr_t&)_ucontext->uc_mcontext.gregs[REG_RSP];
    }
    uintptr_t& fp() {
        return (uintptr_t&)_ucontext->uc_mcontext.gregs[REG_RBP];
    }
};

// 展开步骤 2: Frame Pointer 链的内存布局
//
// 栈内存布局（高地址在上）：
// 
//    +-----------------+
//    | 返回地址 (PC)   |  <- fp + 8 (FRAME_PC_SLOT = 1)
//    +-----------------+
//    | 上一帧 RBP      |  <- fp
//    +-----------------+
//    | 局部变量        |
//    | ...             |
//    +-----------------+
//    | 返回地址        |
//    +-----------------+
//    | 上一帧 RBP      |  <- 新 fp
//    +-----------------+
//
// 展开步骤 3: 关键宏定义
// 文件: arch.h 第 58 行
const int FRAME_PC_SLOT = 1;  // PC 在 RBP 上方 1 个槽位
//   即: PC = *(RBP + 8)
//   上一帧 RBP = *RBP
//   上一帧 SP = RBP + 16

// 展开步骤 4: SafeAccess::load 的作用
// 文件: safeAccess.h
template<typename T>
static inline T load(T* addr) {
    // 使用信号处理器安全的读取方式
    // 如果 addr 无效，不会崩溃，而是返回 0
    T value;
    if (likely(__builtin_memcpy(&value, addr, sizeof(T)) == 0)) {
        return value;
    }
    return T();
}
```

#### 8.2 六层面分析

| 层面 | 分析 |
|------|------|
| **设计原理** | 为什么用 Frame Pointer 链？<br>这是 x86/x64 的标准调用约定。编译器在函数入口保存旧 RBP 到栈，结束时恢复。形成链式结构。 |
| **边界条件** | 1. `fp < sp`: 栈向低地址增长，FP 不可能小于当前 SP<br>2. `fp >= sp + MAX_FRAME_SIZE`: 单帧不可能超过 256KB<br>3. `fp >= bottom`: 不能超过栈顶<br>4. `!aligned(fp)`: RBP 必须 8 字节对齐 |
| **并发安全** | 只读取栈内存，不修改。信号处理器中执行时，栈是线程私有的，无竞争。 |
| **JVM 交互** | `CodeHeap::contains(pc)` 检查 PC 是否在 JIT 代码区域。如果是，记录位置给 Java 栈回溯使用。 |
| **性能影响** | 每帧约 10-20 CPU 周期（内存访问）。100 帧约 1-2 微秒。 |
| **替代方案** | DWARF 回溯更准确，但更慢。FP 回溯是最快的方案，适合生产环境。 |

---

## 9. convertNativeTrace() - Native 帧转换

### 第 333-375 行

```cpp
// 文件: profiler.cpp 第 333-375 行
int Profiler::convertNativeTrace(int native_frames, const void** callchain, ASGCT_CallFrame* frames, EventType event_type) {
    int depth = 0;
    jmethodID prev_method = NULL;

    for (int i = 0; i < native_frames; i++) {
        const char* current_method_name = findNativeMethod(callchain[i]);
        char mark;
        
        // [步骤 1] 检查特殊标记
        if (current_method_name != NULL && (mark = NativeFunc::mark(current_method_name)) != 0) {
            if (mark == MARK_VM_RUNTIME && event_type >= ALLOC_SAMPLE) {
                // 分配采样：跳过 VM 运行时入口以上的所有帧
                depth = 0;
                continue;
            } else if (mark == MARK_ASYNC_PROFILER && 
                       (event_type == MALLOC_SAMPLE || event_type == NATIVE_LOCK_SAMPLE)) {
                // Native 内存/锁采样：跳过 async-profiler 内部帧
                depth = 0;
            } else if (mark == MARK_INTERPRETER) {
                // 解释器帧：后续帧由 AGCT 返回，终止扫描
                return depth;
            } else if (mark == MARK_COMPILER_ENTRY && _features.comp_task) {
                // 编译器入口：插入编译任务作为伪 Java 帧
                jmethodID compile_task = getCurrentCompileTask();
                if (compile_task != NULL) {
                    frames[depth].bci = 0;
                    frames[depth].method_id = compile_task;
                    depth++;
                }
            }
        }

        // [步骤 2] 添加帧
        jmethodID current_method = (jmethodID)current_method_name;
        if (current_method == prev_method && _cstack == CSTACK_LBR) {
            // LBR 可能有重复帧
            prev_method = NULL;
        } else {
            frames[depth].bci = BCI_NATIVE_FRAME;
            frames[depth].method_id = prev_method = current_method;
            depth++;
        }
    }

    return depth;
}
```

#### 9.1 特殊标记的意义

```
Native 函数标记系统：

┌─────────────────────────────────────────────────────────────────┐
│ 标记类型              │ 触发条件                    │ 处理方式  │
├─────────────────────────────────────────────────────────────────┤
│ MARK_VM_RUNTIME = 1   │ JVM 运行时入口              │ 分配采样时跳过 │
│ MARK_INTERPRETER = 2  │ C++ 解释器帧                │ 终止扫描  │
│ MARK_COMPILER_ENTRY=3 │ JIT 编译器入口              │ 插入编译任务 │
│ MARK_ASYNC_PROFILER=4 │ async-profiler 内部函数     │ 跳过      │
└─────────────────────────────────────────────────────────────────┘

标记存储在 NativeFunc 结构中：

struct NativeFunc {
    short _lib_index;   // 库索引
    char _mark;         // 标记（这里）
    char _name[0];      // 函数名
};

示例：

函数名: "_ZN12JavaCallsT7callEP6JavaCall..."
标记过程:
  1. 解析符号时检测函数名前缀
  2. 如果匹配 "JavaCalls::", 标记为 MARK_VM_RUNTIME
  3. NativeFunc::mark(name) 返回这个标记
```

#### 9.2 为什么分配采样要跳过 VM_RUNTIME 以上的帧？

```
问题场景：

线程调用栈：
  main()
    └── createObject()
          └── JVM_NewObject()        <- Native 方法
                └── JVM_Entry()      <- VM_RUNTIME 标记
                      └── ObjAllocator()
                            └── allocate()  <- 分配发生在这里
                                  └── trapHandler()  <- INT3 触发

如果不跳过：
  - 火焰图会显示大量 "JVM_Entry" 帧
  - 用户真正关心的是 "createObject()" 这个应用代码

跳过后：
  - 从 VM_RUNTIME 标记处重新开始计数
  - 火焰图只显示应用层调用栈
```

---

## 10. getJavaTraceAsync() - Java 异步栈回溯

### 第 377-425 行

```cpp
// 文件: profiler.cpp 第 377-425 行
int Profiler::getJavaTraceAsync(void* ucontext, ASGCT_CallFrame* frames, int max_depth, StackContext* java_ctx) {
    // [步骤 1] 获取 VMThread
    VMThread* vm_thread = VMThread::current();
    if (vm_thread == NULL) {
        return 0;  // 不是 Java 线程
    }

    // [步骤 2] 获取 JNIEnv
    JNIEnv* jni = vm_thread->jni();
    if (jni == NULL) {
        return 0;  // 不是 Java 线程
    }

    // [步骤 3] 保存寄存器状态
    StackFrame frame(ucontext);
    uintptr_t saved_pc, saved_sp, saved_fp;
    if (ucontext != NULL) {
        saved_pc = frame.pc();
        saved_sp = frame.sp();
        saved_fp = frame.fp();
    }

    // [步骤 4] 处理 inJava 状态
    if (_features.unwind_native && vm_thread->inJava()) {
        // 如果线程在 Java 状态，可能需要手动展开
        if (saved_pc >= (uintptr_t)_call_stub_begin && saved_pc < (uintptr_t)_call_stub_end) {
            // call_stub 区域不安全，直接返回错误
            frames->bci = BCI_ERROR;
            frames->method_id = (jmethodID)"call_stub";
            return 1;
        }
        if (DWARF_SUPPORTED && java_ctx->sp != 0) {
            // 使用 Native 栈回溯的结果，恢复到 Java 帧
            frame.restore((uintptr_t)java_ctx->pc, java_ctx->sp, java_ctx->fp);
        }
    }

    // [步骤 5] 调用 AsyncGetCallTrace
    JitWriteProtection jit(false);  // 禁用写保护（某些平台需要）
    ASGCT_CallTrace trace = {jni, 0, frames};
    VM::_asyncGetCallTrace(&trace, max_depth, ucontext);

    // [步骤 6] 处理成功情况
    if (trace.num_frames > 0) {
        frame.restore(saved_pc, saved_sp, saved_fp);
        return trace.num_frames;
    }
    // ... 后续错误处理 ...
}
```

#### 10.1 VMThread::current() 展开

```cpp
// 展开步骤 1: VMThread::current() 实现
// 文件: vmStructs.cpp
VMThread* VMThread::current() {
    // 方法 1: 使用 pthread TLS
    if (_tls_index >= 0) {
        return (VMThread*)pthread_getspecific(_tls_index);
    }
    
    // 方法 2: 使用 JVM 内部 TLS（如果可用）
    // ...
    
    return NULL;
}

// 展开步骤 2: pthread_getspecific 实现
// glibc 实现：
int pthread_getspecific(pthread_key_t key) {
    // 从线程本地存储读取值
    // 通常是一个数组查找
    struct pthread *self = THREAD_SELF;
    return self->specific[key];
}

// 展开步骤 3: 编译优化后的汇编
//   mov rax, fs:[0]           ; 获取 TLS 基址（FS 段）
//   mov rax, [rax + key*8]    ; 查找键值
//   ; 返回值在 rax
```

#### 10.2 AsyncGetCallTrace 展开

```cpp
// 展开步骤 1: AsyncGetCallTrace 声明
// JVM 导出的函数
void AsyncGetCallTrace(ASGCT_CallTrace* trace, jint depth, void* ucontext);

// 展开步骤 2: ASGCT_CallTrace 结构
typedef struct {
    JNIEnv* env;           // JNIEnv 指针
    jint num_frames;       // 帧数量（成功为正，失败为负）
    ASGCT_CallFrame* frames; // 帧数组
} ASGCT_CallTrace;

// 展开步骤 3: JVM 内部实现（简化）
void AsyncGetCallTrace(ASGCT_CallTrace* trace, jint depth, void* ucontext) {
    // 1. 检查线程状态
    JavaThread* thread = JavaThread::current();
    if (thread == NULL || !thread->is_Java_thread()) {
        trace->num_frames = ticks_unknown_not_Java;
        return;
    }
    
    // 2. 检查是否在 Safepoint
    if (SafepointSynchronize::is_at_safepoint()) {
        trace->num_frames = ticks_safepoint;
        return;
    }
    
    // 3. 检查 GC 状态
    if (Universe::heap()->is_gc_active()) {
        trace->num_frames = ticks_GC_active;
        return;
    }
    
    // 4. 从 PC 开始回溯
    frame fr = frame::find_frame(ucontext);
    if (!fr.is_java_frame()) {
        trace->num_frames = ticks_unknown_not_Java;
        return;
    }
    
    // 5. 遍历 Java 帧
    int count = 0;
    while (count < depth && fr.is_java_frame()) {
        Method* method = fr.method();
        trace->frames[count].method_id = method->method_holder()->jmethod_id();
        trace->frames[count].bci = fr.bci();
        
        fr = fr.java_sender();
        count++;
    }
    
    trace->num_frames = count;
}
```

#### 10.3 六层面分析

| 层面 | 分析 |
|------|------|
| **设计原理** | 为什么用 AsyncGetCallTrace？<br>1. 它是 JVM 提供的专门用于信号处理器的 API<br>2. 不需要获取锁，可以在任意上下文调用<br>3. 使用 ucontext 恢复寄存器状态 |
| **边界条件** | 失败时返回负数错误码：<br>- `ticks_unknown_Java`: 未知 Java 帧<br>- `ticks_not_walkable_Java`: 不可遍历<br>- `ticks_GC_active`: GC 中<br>- `ticks_safepoint`: Safepoint 中 |
| **并发安全** | AsyncGetCallTrace 是无锁的。只读取线程私有数据。 |
| **JVM 交互** | 这是 JVM 专门为 profiler 提供的接口。JVM 保证在任意上下文（包括信号处理器）中安全调用。 |
| **性能影响** | 成功时约 100-500 周期/帧。失败时约 50 周期返回错误。 |
| **替代方案** | 1. GetStackTrace (JVMTI): 需要获取锁，不能在信号处理器中使用<br>2. 自己遍历帧: 复杂，且与 JVM 版本耦合<br>**结论**: AsyncGetCallTrace 是唯一可行的方案。 |

---

## 11. CallTraceStorage::put() - 调用栈存储

### 第 233-281 行

```cpp
// 文件: callTraceStorage.cpp 第 233-281 行
u32 CallTraceStorage::put(int num_frames, ASGCT_CallFrame* frames, u64 counter) {
    // [步骤 1] 计算哈希
    u64 hash = calcHash(num_frames, frames);

    // [步骤 2] 获取哈希表
    LongHashTable* table = _current_table;
    u64* keys = table->keys();
    u32 capacity = table->capacity();
    u32 slot = hash & (capacity - 1);  // 初始槽位
    u32 step = 0;

    // [步骤 3] 开放寻址查找
    while (keys[slot] != hash) {
        if (keys[slot] == 0) {
            // [步骤 3.1] 空槽位，尝试插入
            if (!__sync_bool_compare_and_swap(&keys[slot], 0, hash)) {
                continue;  // CAS 失败，重试
            }

            // [步骤 3.2] 检查扩容
            if (table->incSize() == capacity * 3 / 4) {
                LongHashTable* new_table = LongHashTable::allocate(table, capacity * 2);
                if (new_table != NULL) {
                    __sync_bool_compare_and_swap(&_current_table, table, new_table);
                }
            }

            // [步骤 3.3] 存储调用栈
            CallTrace* trace = table->prev() == NULL ? NULL : findCallTrace(table->prev(), hash);
            if (trace == NULL) {
                trace = storeCallTrace(num_frames, frames);
            }
            table->values()[slot].setTrace(trace);
            break;
        }

        // [步骤 3.4] 线性探测
        if (++step >= capacity) {
            atomicInc(_overflow);
            return OVERFLOW_TRACE_ID;
        }
        slot = (slot + step) & (capacity - 1);  // 改进的线性探测
    }

    // [步骤 4] 更新计数器
    if (counter != 0) {
        CallTraceSample& s = table->values()[slot];
        atomicInc(s.samples);
        atomicInc(s.counter, counter);
    }

    // [步骤 5] 返回 ID
    return capacity - (INITIAL_CAPACITY - 1) + slot;
}
```

#### 11.1 calcHash() 展开

```cpp
// 展开步骤 1: calcHash 实现
// 文件: callTraceStorage.cpp 第 170-199 行
u64 CallTraceStorage::calcHash(int num_frames, ASGCT_CallFrame* frames) {
    const u64 M = 0xc6a4a7935bd1e995ULL;  // MurmurHash 魔数
    const int R = 47;

    int len = num_frames * sizeof(ASGCT_CallFrame);
    u64 h = len * M;

    const u64* data = (const u64*)frames;
    const u64* end = data + len / 8;

    while (data != end) {
        u64 k = *data++;
        k *= M;
        k ^= k >> R;
        k *= M;
        h ^= k;
        h *= M;
    }

    if (len & 4) {
        h ^= *(u32*)data;
        h *= M;
    }

    h ^= h >> R;
    h *= M;
    h ^= h >> R;

    return h;
}

// 展开步骤 2: 为什么用 MurmurHash？
// 1. 分布均匀：减少哈希冲突
// 2. 计算快速：无除法，只有乘法和异或
// 3. 确定性：相同输入产生相同输出
```

#### 11.2 开放寻址展开

```
开放寻址法工作原理：

初始状态（capacity = 8）：
槽位: [0] [1] [2] [3] [4] [5] [6] [7]
哈希: [A] [ ] [B] [ ] [ ] [C] [ ] [ ]

查找 D（hash(D) = 2）：
1. slot = 2, keys[2] = B ≠ D
2. step = 1, slot = 3, keys[3] = 0 → 插入

改进的线性探测：
  slot = (slot + step) & (capacity - 1)
  
  step = 1: slot = (2 + 1) % 8 = 3
  step = 2: slot = (3 + 2) % 8 = 5
  step = 3: slot = (5 + 3) % 8 = 0
  
为什么是 "slot + step" 而不是 "slot + 1"？
  - step = 1, 2, 3, ...
  - 跳跃距离递增，避免聚集
  - 更好地利用缓存局部性
```

#### 11.3 六层面分析

| 层面 | 分析 |
|------|------|
| **设计原理** | 为什么用开放寻址而不是链表？<br>1. 缓存友好：所有数据连续存储<br>2. 内存效率：无指针开销<br>3. 查找快速：平均 O(1) |
| **边界条件** | 表满时怎么办？<br>1. 负载因子达到 0.75 时扩容<br>2. 扩容失败时返回 OVERFLOW_TRACE_ID |
| **并发安全** | 使用 CAS 原子操作插入。无锁设计，多线程安全。 |
| **JVM 交互** | 不涉及 JVM，纯 Native 数据结构。 |
| **性能影响** | 哈希计算: ~50 周期<br>查找/插入: ~20-100 周期<br>扩容: O(n)，但摊销到每次操作 |
| **替代方案** | 1. std::unordered_map：锁竞争严重<br>2. ConcurrentHashMap：更复杂，收益有限<br>**结论**: 当前无锁开放寻址最优。 |

---

## 12. 完整执行流程图（含时间估算）

```
recordSample() 完整执行流程（续）：

时间点   操作                              耗时(估算)
────────────────────────────────────────────────────────────
T8      getNativeTrace()                  500-2000 周期
        ├── StackFrame 构造               ~10 周期
        ├── walkFP() 循环                 ~50 周期/帧 × N
        │   ├── pc = stripPointer()       ~5 周期
        │   ├── aligned(fp) 检查          ~5 周期
        │   ├── SafeAccess::load()        ~20 周期（内存访问）
        │   └── fp = *fp                  ~20 周期
        └── convertNativeTrace()          ~20 周期/帧
            ├── findNativeMethod()        ~100 周期（二分查找）
            └── 帧填充                    ~5 周期
────────────────────────────────────────────────────────────
T9      getJavaTraceAsync()               1000-5000 周期
        ├── VMThread::current()           ~50 周期（TLS 访问）
        ├── vm_thread->jni()              ~20 周期
        ├── StackFrame 构造               ~10 周期
        ├── AsyncGetCallTrace()           ~100-500 周期/帧
        │   ├── 线程状态检查              ~50 周期
        │   ├── Safepoint 检查            ~20 周期
        │   ├── GC 状态检查               ~20 周期
        │   └── 帧遍历                    ~100 周期/帧
        └── 错误恢复处理                  0-500 周期（如果需要）
────────────────────────────────────────────────────────────
T11     CallTraceStorage::put()           100-200 周期
        ├── calcHash()                    ~50 周期
        │   └── MurmurHash64A             (乘法+异或)
        ├── 开放寻址查找                  ~20-50 周期
        │   └── CAS 重试                  (可能多次)
        ├── storeCallTrace()              ~100 周期（新栈）
        │   └── LinearAllocator::alloc()  ~20 周期
        └── atomicInc 计数器              ~20 周期 × 2
────────────────────────────────────────────────────────────

总耗时估算（典型场景）：
  - 短调用栈（10 帧），已有哈希：~3000 周期 ≈ 1 微秒
  - 典型调用栈（50 帧），新哈希：~8000 周期 ≈ 2.7 微秒
  - 长调用栈（100+ 帧）：~15000 周期 ≈ 5 微秒

开销分布：
  - 栈回溯：60-70%
  - 哈希计算：10-15%
  - 存储：10-15%
  - 其他：5-10%
```

---

## 13. GDB 验证脚本（完整版）

### 13.1 验证 walkFP()

```gdb
# 文件: jvm-md/tmp-file/async-profiler/gdb_walkFP.txt

set pagination off
set print pretty on

break StackWalker::walkFP

commands
    printf "\n========== StackWalker::walkFP() ==========\n"
    printf "ucontext: %p\n", $arg0
    printf "max_depth: %d\n", $arg2
    
    # 单步到循环开始
    break stackWalker.cpp:85
    commands
        printf "depth=%d, pc=%p, fp=0x%lx, sp=0x%lx\n", $depth, $pc, $fp, $sp
        continue
    end
    
    continue
end

run
```

### 13.2 验证 AsyncGetCallTrace

```gdb
# 文件: jvm-md/tmp-file/async-profiler/gdb_asgct.txt

set pagination off

# 在 recordSample 中调用 AsyncGetCallTrace 前后设置断点
break profiler.cpp:420

commands
    printf "\n========== 调用 AsyncGetCallTrace 前 ==========\n"
    printf "jni: %p\n", $jni
    printf "max_depth: %d\n", $max_depth
    
    # 执行 AsyncGetCallTrace
    step
    
    printf "\n========== AsyncGetCallTrace 返回后 ==========\n"
    printf "num_frames: %d\n", $trace.num_frames
    
    if $trace.num_frames > 0
        printf "成功获取 %d 帧\n", $trace.num_frames
        # 打印前 5 帧
        set $i = 0
        while $i < 5 && $i < $trace.num_frames
            printf "  [%d] bci=%d, method_id=%p\n", $i, $trace.frames[$i].bci, $trace.frames[$i].method_id
            set $i = $i + 1
        end
    else
        printf "失败，错误码: %d\n", $trace.num_frames
    end
    
    continue
end

run
```

---

**本课完整分析了 recordSample() 的栈回溯和存储部分。下一课将分析错误恢复策略（如 unwindStub、probe_SP）以及输出格式。**
