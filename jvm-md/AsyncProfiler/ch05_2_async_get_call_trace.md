# 5.2 AsyncGetCallTrace (ASGCT) 详解

> 源文件: `profiler.cpp::getJavaTraceAsync` (async-profiler), `forte.cpp::AsyncGetCallTrace` (OpenJDK)
> 关联: `vmEntry.h` (ASGCT 结构体), `vmStructs.h` (VMThread), `stackFrame_x64.cpp` (unwindStub/unwindCompiled)
> 前置章节: 5.1 recordSample 总入口

## 核心问题

**JVM 没有公开的、信号安全的栈回溯 API。AsyncGetCallTrace (ASGCT) 是一个隐藏的、未文档化的 JVM 私有接口——它是怎么工作的？为什么 async-profiler 不需要 Safepoint 就能获取 Java 调用栈？当 ASGCT 失败时，async-profiler 如何做恢复？**

---

## 一、ASGCT 是什么？

### 1.1 历史与地位

ASGCT 全称 `AsyncGetCallTrace`，是 Sun Microsystems 为 Forte Performance Tools 设计的内部函数，自 JDK 1.4 起存在于 HotSpot 中。

**它不是 JVM TI 的一部分，不在任何官方规范中**，但它是唯一一个可以在信号处理器中安全调用的 Java 栈回溯函数。

### 1.2 为什么不能用 JVMTI GetStackTrace？

| 特性 | JVMTI GetStackTrace | ASGCT |
|------|-------------------|-------|
| 调用条件 | 需要线程在 Safepoint 或 JVMTI 回调中 | **可在信号处理器中直接调用** |
| 是否阻塞 | 可能触发 Safepoint 等待 | 不阻塞 |
| 调用者 | 任意线程 | **必须是被采样线程自己** |
| 性能影响 | Stop-The-World | 只影响当前线程 |
| 文档 | 官方标准 | 未文档化 |

### 1.3 函数签名

```cpp
// OpenJDK: src/hotspot/share/prims/forte.cpp
extern "C" void AsyncGetCallTrace(ASGCT_CallTrace* trace, jint depth, void* ucontext);
```

三个参数：
- `trace` — 输出结构体（含 JNIEnv* 和帧数组）
- `depth` — 最大帧深度
- `ucontext` — 信号处理器提供的寄存器上下文

---

## 二、ASGCT 数据结构

### 2.1 核心结构体（vmEntry.h）

```cpp
typedef struct {
    jint bci;                // 字节码索引（Java 帧）或特殊值（原生帧）
    LP64_ONLY(jint padding;) // 64 位对齐
    jmethodID method_id;     // Java 方法 ID
} ASGCT_CallFrame;

typedef struct {
    JNIEnv* env_id;           // 标识目标线程的 JNI 环境
    jint num_frames;          // 帧数（>0 成功，<0 错误码）
    ASGCT_CallFrame* frames;  // 帧数组（调用者提供缓冲区）
} ASGCT_CallTrace;
```

### 2.2 返回码体系

```cpp
enum ASGCT_Failure {
    ticks_no_Java_frame         =  0,   // 当前不在 Java 上下文中（正常）
    ticks_no_class_load         = -1,   // 没有启用 CLASS_LOAD 事件
    ticks_GC_active             = -2,   // GC 正在进行
    ticks_unknown_not_Java      = -3,   // 非 Java 状态，无法获取帧
    ticks_not_walkable_not_Java = -4,   // 非 Java 状态，帧不可遍历
    ticks_unknown_Java          = -5,   // Java 状态，无法获取帧
    ticks_not_walkable_Java     = -6,   // Java 状态，帧不可遍历
    ticks_unknown_state         = -7,   // 未知线程状态
    ticks_thread_exit           = -8,   // 线程正在退出
    ticks_deopt                 = -9,   // 正在反优化
    ticks_safepoint             = -10,  // Safepoint 中
};
```

---

## 三、JVM 侧的 ASGCT 实现（forte.cpp）

### 3.1 入口流程

```
AsyncGetCallTrace(trace, depth, ucontext)
  │
  ├── 验证 env_id → 找到 JavaThread*
  │     └── 失败 → num_frames = -8 (thread_exit)
  │
  ├── 检查 in_deopt_handler()
  │     └── 是 → num_frames = -9 (deopt)
  │
  ├── 检查 JvmtiExport::should_post_class_load()
  │     └── 否 → num_frames = -1 (no_class_load)
  │
  ├── 检查 Universe::heap()->is_gc_active()
  │     └── 是 → num_frames = -2 (GC_active)
  │
  ├── 设置 thread->set_in_asgct(true)
  │
  └── 根据 thread_state 分派：
        │
        ├── _thread_new / _thread_uninitialized → num_frames = 0
        │
        ├── _thread_in_native / _thread_blocked / _thread_in_vm
        │     ├── pd_get_top_frame_for_signal_handler(isInJava=false)
        │     │     └── 失败 → num_frames = -3 (unknown_not_Java)
        │     ├── 没有 last_Java_frame → num_frames = 0
        │     └── forte_fill_call_trace_given_top() → 遍历帧
        │
        ├── _thread_in_Java / _thread_in_Java_trans
        │     ├── pd_get_top_frame_for_signal_handler(isInJava=true)
        │     │     └── 失败 → num_frames = -5 (unknown_Java)
        │     └── forte_fill_call_trace_given_top() → 遍历帧
        │
        └── default → num_frames = -7 (unknown_state)
```

### 3.2 关键：不需要 Safepoint 的原因

ASGCT **不需要 Safepoint** 的核心原因：

1. **被采样线程自己调用**：ASGCT 断言 `JavaThread::current() == thread`，即调用者必须是被中断的线程本身。这意味着线程状态是"冻结"的——信号处理器中线程不会改变状态。

2. **不获取任何 JVM 锁**：整个 `forte_fill_call_trace_given_top` 不持有任何 mutex。它直接读取栈上的原始数据。

3. **GC 检查前置**：如果 GC 正在进行，直接返回 -2，不尝试遍历（因为对象可能在被移动）。

4. **接受部分失败**：如果帧不可遍历，返回负数而不是阻塞等待。

### 3.3 forte_fill_call_trace_given_top — 帧遍历核心

```cpp
forte_fill_call_trace_given_top(thd, trace, depth, top_frame)
  │
  ├── find_initial_Java_frame() → 找第一个可解码的 Java 帧
  │     ├── 如果是解释器帧 → is_decipherable_interpreted_frame()
  │     ├── 如果是编译帧 → is_decipherable_compiled_frame()
  │     └── 否则 → sender() 往上爬，直到找到 Java 帧
  │
  └── vframeStreamForte 循环遍历
        └── 每帧：读取 method_id + bci，写入 trace->frames[]
```

**vframeStreamForte** 是 `vframeStreamCommon` 的子类，专为 ASGCT 设计：
- `forte_next()` 调用 `fill_from_frame()` 解析每一帧
- 对于编译帧，通过 `PcDesc` 查找 scope 信息（包含内联方法）
- 对于解释器帧，通过 BCP（bytecode pointer）计算 BCI

### GDB 验证 — JVM 侧 ASGCT 调用

```
=== AsyncGetCallTrace (JVM) ===
trace->env_id = 0x7ffff17cbb98 (JNIEnv* of target thread)
depth = 2048
→ trace->num_frames = 14 (成功返回 14 帧)

=== AsyncGetCallTrace (JVM) === (第二次)
trace->env_id = 0x7ffff17cbb98
depth = 2048
→ trace->num_frames = 13 (成功返回 13 帧)
```

---

## 四、async-profiler 侧的 ASGCT 封装（getJavaTraceAsync）

### 4.1 为什么不直接调 ASGCT？

直接调 ASGCT 有很多问题：
1. **JNIEnv 获取不安全**：JDK 9+ 的 `GetEnv()` 不是信号安全的
2. **ASGCT 经常失败**：在各种 JVM 状态下返回负数
3. **缺少帧类型信息**：ASGCT 不区分解释帧、JIT 帧、内联帧
4. **不处理 Runtime Stub**：ASGCT 遇到 Stub 帧直接放弃

`getJavaTraceAsync` 解决了所有这些问题。

### 4.2 完整流程

```
getJavaTraceAsync(ucontext, frames, max_depth, java_ctx)
  │
  ├── Step 1: 获取 VMThread（绕过 GetEnv）
  │     └── VMThread::current() → pthread_getspecific(_tls_index)
  │         → 直接读 TLS，不调任何 JVM API
  │
  ├── Step 2: 获取 JNIEnv（绕过 GetEnv）
  │     └── vm_thread->jni()
  │         → 通过 VMStructs 偏移量直接读取内存
  │
  ├── Step 3: 保存原始 PC/SP/FP
  │     └── StackFrame frame(ucontext)
  │         → saved_pc, saved_sp, saved_fp
  │
  ├── Step 4: 原生帧展开（可选）
  │     └── 如果 unwind_native && inJava()
  │         → 从 java_ctx 恢复到最后已知的 Java 帧
  │
  ├── Step 5: 第一次调用 ASGCT
  │     └── JitWriteProtection jit(false)  ← Apple Silicon 专用
  │         VM::_asyncGetCallTrace(&trace, max_depth, ucontext)
  │
  ├── Step 6: 成功? → 恢复 PC/SP/FP，返回
  │
  └── Step 7: 失败? → 根据错误码尝试恢复
        │
        ├── unknown_Java (-5) / not_walkable_Java (-6)
        │   ├── 查找 Runtime Stub → unwindStub()
        │   │     → 修改 ucontext 中的 PC/SP/FP
        │   │     → 重试 ASGCT
        │   │
        │   ├── 查找 NMethod → 提取 jmethodID
        │   │     → unwindCompiled() → 重试 ASGCT
        │   │
        │   └── probe_sp → 逐步调整 SP，反复重试
        │
        ├── unknown_not_Java (-3)
        │   └── 读取 JavaFrameAnchor
        │       → anchor->lastJavaSP() 有值但 lastJavaPC() == NULL
        │       → 从栈上恢复 PC: pc = ((void**)sp)[-1]
        │       → anchor->setLastJavaPC(pc)
        │       → 重试 ASGCT
        │       → anchor->setLastJavaPC(NULL) ← 恢复原状
        │
        ├── not_walkable_not_Java (-4)
        │   └── 读取 JavaFrameAnchor
        │       → 检查是否有 Runtime Stub 的 _frame_complete_offset == -1
        │       → 如果有，setFrameCompleteOffset(0) → 重试 ASGCT
        │
        └── GC_active (-2)
            └── 如果 gc_traces 特性启用 → 返回 "GC_active" 错误帧
```

### GDB 验证 — async-profiler 侧

```
=== getJavaTraceAsync ===
ucontext = 0x7ffff7808040
max_depth = 2048
VMThread::current() = 0x7ffff17cb800  ← 通过 TLS 获取

→ ASGCT 第一次调用，trace.num_frames = 14 → 成功
→ getJavaTraceAsync 返回 17 帧（包含恢复帧 + ASGCT 帧）

第二次采样:
→ ASGCT 第一次调用就成功，trace.num_frames = 13
→ getJavaTraceAsync 返回 10 帧
```

---

## 五、ASGCT 恢复机制详解

### 5.1 问题：为什么 ASGCT 会失败？

ASGCT 在以下场景下几乎必然失败：

| 场景 | 错误码 | 原因 |
|------|--------|------|
| 线程执行原生代码（JNI 调用） | -3 | `pd_get_top_frame_for_signal_handler` 无法获取帧 |
| JIT 编译的方法正在执行 prologue/epilogue | -5/-6 | PC 不在任何 PcDesc 描述的范围内 |
| 线程在 Runtime Stub 中（SafePoint polling） | -5/-6 | Stub 帧结构不标准 |
| GC 正在运行 | -2 | 对象地址可能已变 |
| 线程正在反优化 | -9 | 栈帧正在被重写 |
| 帧结构不完整（_frame_complete_offset = -1） | -4 | JVM bug：某些 Stub 没有正确设置 |

### 5.2 恢复策略 A：unwindStub — Runtime Stub 展开

当线程停在 Runtime Stub（如 `resolve_virtual_call`、SafePoint polling stub 等）中时：

```cpp
if (_runtime_stubs.contains((const void*)frame.pc())) {
    stub = findRuntimeStub((const void*)frame.pc());
}
if (stub != NULL && _features.unwind_stub) {
    frame.unwindStub((instruction_t*)stub->_start, stub->_name);
    // 修改 ucontext 中的 PC/SP/FP → 跳过 Stub 帧
    VM::_asyncGetCallTrace(&trace, max_depth, ucontext);
    // 再试一次
}
```

**x86_64 的 unwindStub 逻辑**（stackFrame_x64.cpp）：

```cpp
bool StackFrame::unwindStub(instruction_t* entry, const char* name,
                            uintptr_t& pc, uintptr_t& sp, uintptr_t& fp) {
    instruction_t* ip = (instruction_t*)pc;
    if (ip == entry || *ip == 0xc3  // ret 指令
        || strncmp(name, "itable", 6) == 0
        || strncmp(name, "vtable", 6) == 0
        || strcmp(name, "InlineCacheBuffer") == 0) {
        // 简单情况：返回地址在栈顶
        pc = ((uintptr_t*)sp)[0] - 1;
        sp += 8;
        return true;
    } else if (entry != NULL && *(unsigned int*)entry == 0xec8b4855) {
        // push rbp; mov rbp, rsp — 标准帧
        // 从 RBP 恢复
        sp = fp + 16;
        fp = ((uintptr_t*)sp)[-2];
        pc = ((uintptr_t*)sp)[-1] - 1;
        return true;
    }
    return false;
}
```

### 5.3 恢复策略 B：NMethod 方法提取

如果线程不在 Stub 中，而是在 JIT 编译方法的 prologue/epilogue（ASGCT 无法识别的位置）：

```cpp
NMethod* nmethod = CodeHeap::findNMethod((const void*)frame.pc());
if (nmethod != NULL && nmethod->isNMethod() && nmethod->isAlive()) {
    VMMethod* method = nmethod->method();
    jmethodID method_id = method->id();
    if (method_id != NULL) {
        // 至少记录当前方法（即使不能遍历完整栈）
        makeFrame(trace.frames++, 0, method_id);
    }
    if (_features.unwind_comp) {
        frame.unwindCompiled(nmethod);  // 手动展开编译帧
        VM::_asyncGetCallTrace(&trace, max_depth, ucontext);  // 重试
    }
}
```

### 5.4 恢复策略 C：JavaFrameAnchor 修复

当线程在 `_thread_in_vm` 状态（执行 VM 运行时代码）时，ASGCT 返回 -3。此时 `JavaFrameAnchor` 可能**部分保存**——有 SP 但没有 PC：

```cpp
JavaFrameAnchor* anchor = vm_thread->anchor();
uintptr_t sp = anchor->lastJavaSP();
const void* pc = anchor->lastJavaPC();

if (sp != 0 && pc == NULL) {
    // Anchor 有 SP 但没 PC → 手动恢复 PC
    pc = ((const void**)sp)[-1];  // 从栈上读取返回地址
    anchor->setLastJavaPC(pc);    // 临时设置 PC

    // 重试 ASGCT
    VM::_asyncGetCallTrace(&trace, max_depth, ucontext);

    // 恢复原始状态（不能永久修改 Anchor）
    anchor->setLastJavaPC(NULL);
}
```

**为什么要恢复原状？** 因为 ASGCT 运行在信号处理器中，信号处理器返回后线程会继续执行。如果我们永久修改了 Anchor，可能会影响 JVM 的正确性（例如 GC 可能用错误的 Anchor 做栈扫描）。

### 5.5 恢复策略 D：probe_sp — 暴力搜索

如果 unwindCompiled 也不行（极少数情况），async-profiler 会暴力调整 SP：

```cpp
if (_features.probe_sp && trace.num_frames < 0) {
    for (int i = 0; trace.num_frames < 0 && i < PROBE_SP_LIMIT; i++) {
        frame.sp() += sizeof(void*);  // 每次 SP + 8
        VM::_asyncGetCallTrace(&trace, max_depth, ucontext);
    }
}
```

每次将 SP 向上移一个 slot，直到 ASGCT 成功或达到上限。这是"最后的手段"。

---

## 六、VMThread::current() — 如何在信号处理器中找到当前线程

### 6.1 问题

信号处理器中不能调用 `GetEnv()`（JDK 9+ 中可能死锁）。那怎么找到当前的 JavaThread？

### 6.2 解决方案：TLS

```cpp
VMThread* VMThread::current() {
    return _tls_index >= 0
        ? (VMThread*)pthread_getspecific((pthread_key_t)_tls_index)
        : NULL;
}
```

`_tls_index` 是在 `VMStructs::initTLS()` 中发现的——async-profiler 通过分析 HotSpot 的 `Thread::current()` 函数的机器码，提取出 `pthread_getspecific` 使用的 key。

### 6.3 JNIEnv 的获取

```cpp
JNIEnv* VMThread::jni() {
    if (_env_offset < 0) {
        return VM::jni();  // fallback
    }
    return isJavaThread() ? (JNIEnv*) at(_env_offset) : NULL;
}
```

直接通过内存偏移量读取 JavaThread 结构体中的 `_jni_environment` 字段，完全不需要调 JVM API。

### GDB 验证

```
VMThread::current() = 0x7ffff17cb800
→ 通过 pthread_getspecific(0) 获取
→ 然后 jni() 读取偏移量处的 JNIEnv*
→ ASGCT 调用: trace->env_id = 0x7ffff17cbb98
```

---

## 七、ASGCT 的函数指针获取

### 7.1 问题

`AsyncGetCallTrace` 不在任何头文件或链接库中导出，如何获取它的地址？

### 7.2 解决方案：dlsym

```cpp
// vmEntry.cpp (VM::init)
_asyncGetCallTrace = (AsyncGetCallTrace)dlsym(RTLD_DEFAULT, "AsyncGetCallTrace");
```

async-profiler 在 Agent_OnLoad 时通过 `dlsym(RTLD_DEFAULT, "AsyncGetCallTrace")` 在已加载的 libjvm.so 中查找这个符号。由于 ASGCT 用 `extern "C"` 导出（无 name mangling），dlsym 可以直接找到。

### 7.3 为什么用函数指针

```cpp
class VM {
  public:
    static AsyncGetCallTrace _asyncGetCallTrace;
};

// 调用方式
VM::_asyncGetCallTrace(&trace, max_depth, ucontext);
```

使用函数指针而非直接链接，因为：
1. ASGCT 不在任何公开头文件中
2. 非 HotSpot JVM（如 OpenJ9）可能没有这个函数
3. 可以在运行时检查是否可用

---

## 八、JitWriteProtection — Apple Silicon 特殊处理

```cpp
JitWriteProtection jit(false);  // 在 ASGCT 调用前
VM::_asyncGetCallTrace(&trace, max_depth, ucontext);
```

在 Apple Silicon（ARM64 macOS）上，JIT 代码页默认设为"可执行不可写"（W^X）。ASGCT 在遍历栈时可能需要读取 JIT 代码页（例如查找 PcDesc），此时如果页面处于"只执行"模式会导致 SEGFAULT。

`JitWriteProtection(false)` 临时将 JIT 页切换为可读模式。在 Linux/x86_64 上这是一个 no-op。

---

## 九、FrameType::encode/decode — 帧类型标注（修正版）

### 9.1 编码规则（vmEntry.h）

```cpp
static inline int encode(int type, int bci) {
    return (1 << 24) | (type << 25) | (bci & 0xffffff);
}

static inline FrameTypeId decode(int bci) {
    return (bci >> 24) > 0 ? (FrameTypeId)(bci >> 25) : FRAME_JIT_COMPILED;
}
```

| 编码位 | 含义 |
|-------|------|
| bit 24 | **标记位**：恒为 1，表示"已标注帧类型" |
| bit 25-31 | 帧类型 ID |
| bit 0-23 | 原始 BCI（最大 16M） |

### 9.2 FrameTypeId 枚举

```cpp
enum FrameTypeId {
    FRAME_INTERPRETED  = 0,   // 解释执行
    FRAME_JIT_COMPILED = 1,   // C2/Graal JIT 编译
    FRAME_INLINED      = 2,   // 被内联的方法
    FRAME_NATIVE       = 3,   // 原生代码（C/asm）
    FRAME_CPP          = 4,   // C++/Rust/Objective-C
    FRAME_KERNEL       = 5,   // 内核帧
    FRAME_C1_COMPILED  = 6,   // C1 编译
};
```

### 9.3 GDB 验证的编码解码

```
encode(INTERPRETED, bci=18) = 0x01000012
  bit 24 = 1 (已标注)
  type = 0x01000012 >> 25 = 0 (INTERPRETED)
  bci = 0x01000012 & 0xFFFFFF = 18

encode(JIT_COMPILED, bci=42) = 0x0300002A
  type = 0x0300002A >> 25 = 1 (JIT_COMPILED)
  bci = 42

encode(INLINED, bci=10) = 0x0500000A
  type = 0x0500000A >> 25 = 2 (INLINED)
  bci = 10

未标注帧: bci >> 24 == 0 → decode 默认返回 JIT_COMPILED
```

---

## 十、fillFrameTypes — ASGCT 后的帧类型标注

ASGCT 本身**不区分帧类型**（所有帧的 bci 都是原始 BCI）。async-profiler 在 ASGCT 返回后调用 `fillFrameTypes` 补充帧类型信息：

```cpp
if (java_frames > 0 && java_ctx.pc != NULL && VMStructs::hasMethodStructs()) {
    NMethod* nmethod = CodeHeap::findNMethod(java_ctx.pc);
    if (nmethod != NULL) {
        fillFrameTypes(frames + num_frames, java_frames, nmethod);
    }
}
```

**fillFrameTypes 的逻辑**：

```
fillFrameTypes(frames, num_frames, nmethod)
  │
  ├── nmethod->isNMethod() && isAlive()?
  │     ├── 获取当前 JIT 编译方法的 jmethodID
  │     ├── 在帧数组中找到这个方法
  │     │     └── 标记为 JIT_COMPILED（或 C1_COMPILED，根据 level）
  │     └── 它之上的所有帧 → 标记为 INLINED
  │
  └── nmethod->isInterpreter()?
        └── 第一个 Java 帧 → 标记为 INTERPRETED
```

**核心洞察**：ASGCT 返回的帧按"从内到外"排列。在 JIT 编译方法中，被内联的方法排在前面（调用栈顶部），宿主方法排在后面。找到宿主方法后，它前面的就是内联帧。

---

## 十一、ASGCT vs walkVM 对比

| 特性 | ASGCT | walkVM |
|------|-------|--------|
| 实现位置 | JVM 内部 (forte.cpp) | async-profiler (stackWalker.cpp) |
| 帧类型标注 | 无（需 fillFrameTypes 补充） | 有（直接标注） |
| 原生帧 | 不包含 | 包含（混合模式） |
| 失败率 | 较高（多种 -N 错误码） | 较低（有 setjmp 保护） |
| 恢复机制 | async-profiler 的 getJavaTraceAsync | 内置崩溃保护 |
| 内联展开 | 自动（通过 vframeStream） | 手动（通过 ScopeDesc） |
| 信号安全 | 是（设计目标） | 是（更安全） |
| 默认使用 | --cstack fp/dwarf | --cstack vm（**默认**） |

**为什么 async-profiler 默认用 walkVM 而不是 ASGCT？**
1. walkVM 的失败率更低
2. walkVM 直接输出混合栈（Java + Native）
3. walkVM 不需要额外的 fillFrameTypes 步骤
4. walkVM 有 setjmp/longjmp 崩溃保护

---

## 十二、StackContext — ASGCT 的"提示信息"

```cpp
class StackContext {
  public:
    const void* pc;   // 最后已知的 Java PC
    uintptr_t sp;     // 对应的 SP
    uintptr_t fp;     // 对应的 FP
    int cpu;          // CPU ID
};
```

**工作流程**：

```
PerfEvents::walk() 遍历内核调用链
  └── 遇到 CodeHeap 中的 PC → 保存到 java_ctx

getJavaTraceAsync() 使用 java_ctx
  └── 如果 unwind_native && inJava() && java_ctx->sp != 0
        → frame.restore(java_ctx->pc, java_ctx->sp, java_ctx->fp)
        → ASGCT 从已知的 Java PC 开始，成功率更高
```

**为什么有用？** 当 PerfEvents 提供了内核视角的调用链，其中可能包含 Java CodeHeap 中的 PC。这个 PC 比 ucontext 中的 PC 更"安全"——因为它一定对应一个有效的 Java 帧。从这里开始遍历，ASGCT 的成功率显著提高。

---

## 十三、ASGCT 失败的统计

async-profiler 会统计每种 ASGCT 失败的次数：

```cpp
atomicInc(_failures[-trace.num_frames]);
```

在 `dumpText()` 输出中可以看到：
```
--- Execution profile ---
Total samples       : 16
unknown_Java        : 2 (0.12%)
not_walkable_Java   : 1 (0.06%)
GC_active           : 3 (0.18%)
```

在我们的 `-Xint` 测试中几乎没有失败，因为解释执行模式下帧结构非常规整。JIT 编译模式下失败率会高得多（prologue/epilogue/deopt）。

---

## 十四、总结

### ASGCT 在 async-profiler 中的地位

```
采样信号到达
  │
  └── recordSample()
        │
        ├── _cstack == CSTACK_VM → walkVM()（默认路径，不走 ASGCT）
        │
        └── _cstack == CSTACK_FP/DWARF
              │
              ├── getNativeTrace() → walkFP/walkDwarf → 原生帧
              │
              └── getJavaTraceAsync()
                    │
                    ├── VMThread::current() → TLS
                    ├── vm_thread->jni() → 偏移量
                    ├── ASGCT 第一次尝试
                    │     ├── 成功 → fillFrameTypes → 返回
                    │     └── 失败 → 恢复策略 A/B/C/D → 重试
                    └── 最终失败 → 返回错误帧
```

### 核心设计思想

1. **ASGCT 是底线，不是首选**：async-profiler 优先使用 walkVM，ASGCT 是 fallback
2. **绝不阻塞**：所有恢复策略都是"尽力而为"，失败就返回错误帧
3. **临时修改，必须恢复**：修改 JavaFrameAnchor 或 ucontext 后必须恢复原状
4. **帧类型是后标注的**：ASGCT 不提供帧类型信息，async-profiler 通过 NMethod 信息补充
5. **多层防御**：unwindStub → unwindCompiled → NMethod 直接提取 → probe_sp

### GDB 验证关键数据

| 验证项 | 实际值 | 含义 |
|--------|--------|------|
| VMThread::current() | 0x7ffff17cb800 | 通过 TLS(key=0) 获取 |
| trace->env_id | 0x7ffff17cbb98 | 偏移量直接读取的 JNIEnv* |
| depth | 2048 | _max_stack_depth |
| trace->num_frames | 14 / 13 | ASGCT 成功返回帧数 |
| 编码 INTERPRETED+bci=18 | 0x01000012 | (1<<24)\|(0<<25)\|18 |
| 编码 JIT_COMPILED+bci=42 | 0x0300002A | (1<<24)\|(1<<25)\|42 |

---

### 在整体架构中的位置

```
Agent 加载（Ch01）
  → VMStructs 初始化（Ch02）
  → Engine 体系 + selectEngine（Ch03）
  → perf_event_open + 信号驱动（Ch04）
  → recordSample 总入口（Ch05.1）
    → AsyncGetCallTrace 详解（本节）  ← 你在这里
    → walkFP（Ch05.3）
    → walkDwarf（Ch05.4）
    → walkVM（Ch05.5）
```

---

*创建日期: 2026-02-09*
*GDB 验证环境: OpenJDK 11 slowdebug + async-profiler v4.0*
*验证模式: --cstack fp + --event ctimer（强制走 ASGCT 路径）*
