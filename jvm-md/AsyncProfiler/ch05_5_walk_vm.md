# 5.5 walkVM — JVM 内部栈回溯（混合模式）

> 源文件: `stackWalker.cpp` (walkVM: 行 210~449), `vmStructs.h` (NMethod/ScopeDesc/InterpreterFrame), `stackFrame_x64.cpp` (unwindStub/unwindCompiled/unwindPrologue/unwindEpilogue)
> 关联: 5.1 recordSample, 5.3 walkFP, 5.4 walkDwarf
> 前置章节: 2.1~2.3 VMStructs, 5.1 recordSample

## 核心问题

**walkFP 和 walkDwarf 都只能回溯原生帧，到 CodeHeap 边界就停了。如何在同一次采样中产出 Native + Java 混合栈？**

答案：walkVM **同时承担两个角色**——在原生代码区域用 DWARF 回溯（和 walkDwarf 一样），在 CodeHeap 区域用 VMStructs 偏移量直接解析 JVM 的 5 种帧类型。它是 async-profiler 默认的栈回溯算法（`--cstack vm`），也是最复杂的一个。

---

## 一、walkVM 在整体架构中的位置

### 1.1 调用入口（来自 5.1）

```
recordSample() → getNativeTrace()
                    ├── CSTACK_FP    → walkFP()    → callchain[]（只有原生帧）
                    ├── CSTACK_DWARF → walkDwarf()  → callchain[]（只有原生帧）
                    └── CSTACK_VM    → return 0（不走 getNativeTrace）
                 → walkVM()                        → frames[]（混合帧！）
```

**关键差异**：walkFP/walkDwarf 的输出是 `const void** callchain`（PC 指针数组），而 walkVM 的输出是 `ASGCT_CallFrame* frames`（包含帧类型、BCI、方法 ID 的结构化数组）。walkVM 直接产出最终帧数据，不需要后续再调 ASGCT。

### 1.2 何时用 walkVM？

```
--cstack vm    → 默认值，最全面
--cstack dwarf → 只产原生帧，再配合 ASGCT 产 Java 帧
--cstack fp    → 同上，但用 FP 链
--cstack no    → 不采原生栈
```

---

## 二、函数签名与参数分析

```cpp
int StackWalker::walkVM(
    void* ucontext,              // 信号中断时的寄存器上下文
    ASGCT_CallFrame* frames,     // 输出：帧数组（类型 + BCI + 方法ID）
    int max_depth,               // 最大深度（2048）
    int lock_index,              // 并发槽索引（用于 setjmp/longjmp）
    StackWalkFeatures features,  // 特性标志（mixed/vtable_target/comp_task）
    EventType event_type         // 事件类型（PERF_SAMPLE/MALLOC_SAMPLE/...）
);
```

### GDB 验证

```
=== walkVM ===
max_depth = 2048             ← MAX_NATIVE_FRAMES + MAX_JAVA_FRAMES
lock_index = 3~13            ← 并发槽（CONCURRENCY_LEVEL = 16）
event_type = PERF_SAMPLE (0) ← CPU 采样
features.mixed = 0           ← 非混合模式（默认 cpu 事件不需要）
```

---

## 三、setjmp/longjmp 崩溃保护

### 3.1 问题

walkVM 直接解引用 JVM 内部数据结构（NMethod、VMMethod、解释器帧的 BCP 等），这些指针可能在信号处理期间变为无效（GC 移动、JIT 卸载、线程销毁）。**walkFP/walkDwarf 用 SafeAccess（SEGV 跳过单条指令）保护**，但 walkVM 需要更强的保护——它可能在任意深层嵌套调用中崩溃。

### 3.2 解决方案

```cpp
// 全局数组：每个并发槽一个 jmp_buf 指针
static jmp_buf* crash_protection_ctx[CONCURRENCY_LEVEL];

// walkVM 入口
jmp_buf current_ctx;
crash_protection_ctx[lock_index] = &current_ctx;  // 注册本次的恢复点

volatile int depth = 0;  // volatile！setjmp/longjmp 要求

if (setjmp(current_ctx) != 0) {
    // ← 如果 longjmp 跳回来，走这里
    crash_protection_ctx[lock_index] = NULL;
    fillFrame(frames[depth++], BCI_ERROR, "break_not_walkable");
    return depth;  // 返回已收集的帧 + 一个错误帧
}

// 正常的栈回溯逻辑...

crash_protection_ctx[lock_index] = NULL;  // 正常结束，取消注册
return depth;
```

### 3.3 谁调用 longjmp？

```cpp
// checkFault() — 在 SEGV 信号处理器中被调用
void StackWalker::checkFault() {
    // 在 crash_protection_ctx[] 中找到最近的（栈距离最短的）jmp_buf
    jmp_buf* nearest_ctx = NULL;
    uintptr_t stack_distance = 32768;
    const uintptr_t current_sp = (uintptr_t)&nearest_ctx;

    for (int i = 0; i < CONCURRENCY_LEVEL; i++) {
        jmp_buf* ctx = crash_protection_ctx[i];
        if ((uintptr_t)ctx - current_sp < stack_distance) {
            nearest_ctx = ctx;
            stack_distance = (uintptr_t)ctx - current_sp;
        }
    }

    if (nearest_ctx != NULL) {
        longjmp(*nearest_ctx, 1);  // 跳回 setjmp 处，返回 1
    }
}
```

### 3.4 设计亮点

1. **`volatile int depth`**：C 标准要求 `setjmp/longjmp` 之间修改的局部变量必须为 `volatile`，否则 longjmp 后值不确定
2. **就近匹配**：一个线程可能同时被多个引擎的信号中断（如 cpu + wall），所以用栈距离找最近的 jmp_buf
3. **32768 限制**：栈距离超过 32KB 说明不是同一个栈帧链上的，避免误匹配

### GDB 验证

```
checkFault hit!  ← 确实在运行中被触发过，说明 walkVM 确实会遇到无效内存
```

---

## 四、初始化阶段

### 4.1 寄存器上下文提取（与 walkFP/walkDwarf 相同）

```cpp
StackFrame frame(ucontext ? ucontext : &empty_ucontext);
if (ucontext == NULL) {
    pc = callerPC();  fp = callerFP();  sp = callerSP();
} else {
    pc = frame.pc();  fp = frame.fp();  sp = frame.sp();
}
```

### 4.2 JavaFrameAnchor 获取

```cpp
JavaFrameAnchor* anchor = NULL;
VMThread* vm_thread = VMThread::current();      // 通过 TLS 获取当前线程的 VMThread
if (vm_thread != NULL && vm_thread->isJavaThread()) {
    if (details) {
        anchor = vm_thread->anchor();            // 保存 anchor 供后续使用
    } else if (!vm_thread->anchor()->restoreFrame(pc, sp, fp)) {
        return 0;                                // 非 Java 线程 → 直接返回
    }
}
```

**JavaFrameAnchor** 是 JVM 在 Java↔Native 转换时保存的"锚点"，记录最后一个 Java 帧的 SP/FP/PC。anchor 有两个用途：
1. **修正**：当 walkVM 通过 DWARF 回溯到 CodeHeap 边界时，anchor 提供可靠的 SP/FP（信号可能中断在任意位置，SP/FP 可能还没完全构建好）
2. **跳转**：当 DWARF 回溯到死胡同时，直接跳到 anchor 位置重新开始

### GDB 验证

```
vm_thread  = 0x7ffff17cb800
anchor     = 0x7ffff17cbb78
anchor->lastJavaSP = 0x7ffff7808b60
anchor->lastJavaPC = 0x7fffec81f87d  ← CodeHeap 中（Interpreter 入口）
anchor->lastJavaFP = 0x7ffff7808bb0
CodeHeap::contains(anchor->lastJavaPC()) = 1  ✅
```

### 4.3 `details` 标志

```cpp
bool details = event_type <= MALLOC_SAMPLE || features.mixed;
```

`details = true` 时，walkVM 会输出：
- 原生帧的函数名（`BCI_NATIVE_FRAME`）
- C1/C2 编译层级区分
- Stub 帧名称
- 内联帧标记

`details = false` 时（如纯分配追踪），跳过原生帧细节以提升性能。

---

## 五、核心循环 — 帧类型分派

walkVM 的核心是一个巨大的 while 循环，根据 PC 所在位置分派到不同的帧处理逻辑：

```
while (depth < max_depth) {
    ├── 安全检查: sp 范围 + 对齐
    │
    ├── if CodeHeap::contains(pc)  ← PC 在 JVM 代码堆中
    │   ├── findNMethod(pc) → nm
    │   ├── JavaFrameAnchor 修正（只在第一次）
    │   │
    │   ├── nm->isNMethod()        → [A] 编译帧（C1/C2/JIT）
    │   ├── nm->isInterpreter()    → [B] 解释帧
    │   ├── nm->isEntryFrame(pc)   → [C] Entry 帧（Java↔Native 边界）
    │   └── else                   → [D] Stub 帧
    │
    └── else                       ← PC 在原生库中
        → [E] 原生帧 + DWARF 回溯
}
```

---

## 六、[A] 编译帧处理 — isNMethod

### 6.1 核心流程

```cpp
if (nm->isNMethod()) {
    int level = nm->level();
    // level 1~3 = C1 编译; level 0/4 = C2/AOT
    FrameTypeId type = details && level >= 1 && level <= 3 ? FRAME_C1_COMPILED : FRAME_JIT_COMPILED;
    fillFrame(frames[depth++], type, 0, nm->method()->id());

    if (nm->isFrameCompleteAt(pc)) {
        // ─── 帧已完整构建 ───

        // 1. Epilogue 检查（ret/pop rbp 附近）
        if (depth == 1 && frame.unwindEpilogue(nm, pc, sp, fp)) continue;

        // 2. ScopeDesc 内联展开
        int scope_offset = nm->findScopeOffset(pc);
        if (scope_offset > 0) {
            depth--;  // 回退，用 ScopeDesc 重新填充
            ScopeDesc scope(nm);
            do {
                scope_offset = scope.decode(scope_offset);
                type = scope_offset > 0 ? FRAME_INLINED : ...; // 中间帧 = INLINED
                fillFrame(frames[depth++], type, scope.bci(), scope.method()->id());
            } while (scope_offset > 0 && depth < max_depth);
        }

        // 3. 标准帧推进
        sp += nm->frameSize() * sizeof(void*);
        fp = ((uintptr_t*)sp)[-FRAME_PC_SLOT - 1];   // *(SP - 16) = saved FP
        pc = ((const void**)sp)[-FRAME_PC_SLOT];      // *(SP - 8) = return address
        continue;
    } else if (frame.unwindPrologue(nm, pc, sp, fp)) {
        // ─── 帧还没构建完（在 prologue 中被中断）───
        continue;
    }

    // 无法回溯 → 错误帧
    fillFrame(frames[depth++], BCI_ERROR, "break_compiled");
    break;
}
```

### 6.2 isFrameCompleteAt — 帧完整性判断

```cpp
bool isFrameCompleteAt(const void* pc) {
    return pc >= code() + frameCompleteOffset();
}
```

JVM 在每个 NMethod 中记录了 `frame_complete_offset`——从入口到帧完全构建完毕的偏移。如果 PC 在此偏移之后，说明帧已完整（push rbp + sub rsp 都执行完了），可以用 `frameSize()` 计算调用者的 SP。

### 6.3 ScopeDesc 内联展开

JIT 编译器可能把多个 Java 方法内联到一个 NMethod 中。`findScopeOffset` 通过二分查找 PC → PcDesc → scope_offset，然后 `ScopeDesc::decode` 沿 sender 链展开：

```
ScopeDesc 链:
  [最内层] method=A, bci=15 → sender_offset=42
  [中间层] method=B, bci=7  → sender_offset=28
  [最外层] method=C, bci=3  → sender_offset=0（终止）

输出帧序列:
  frames[0] = {FRAME_INLINED, bci=15, A}      ← 最内层
  frames[1] = {FRAME_INLINED, bci=7,  B}      ← 中间层
  frames[2] = {FRAME_JIT_COMPILED, bci=3, C}   ← 最外层（实际编译的方法）
```

### 6.4 unwindEpilogue / unwindPrologue（x86_64 实现）

这些函数通过**指令模式匹配**来处理信号恰好中断在 prologue/epilogue 中的情况：

```cpp
// unwindEpilogue: 信号在函数退出时中断
bool StackFrame::unwindEpilogue(NMethod* nm, uintptr_t& pc, uintptr_t& sp, uintptr_t& fp) {
    instruction_t* ip = (instruction_t*)pc;
    if (*ip == 0xc3 || isPollReturn(ip)) {  // ret 指令
        pc = ((uintptr_t*)sp)[0] - 1;       // 返回地址在栈顶
        sp += 8;
        return true;
    } else if (*ip == 0x5d) {               // pop rbp
        fp = ((uintptr_t*)sp)[0];
        pc = ((uintptr_t*)sp)[1] - 1;
        sp += 16;
        return true;
    }
    return false;
}

// unwindPrologue: 信号在函数进入时中断
bool StackFrame::unwindPrologue(NMethod* nm, uintptr_t& pc, uintptr_t& sp, uintptr_t& fp) {
    instruction_t* ip = (instruction_t*)pc;
    if (ip <= entry || *ip == 0x55 || nm->frameSize() == 0) {
        // 还没执行 push rbp → 返回地址在栈顶
        pc = ((uintptr_t*)sp)[0] - 1;
        sp += 8;
        return true;
    } else if (ip[-1] == 0x55) {
        // 刚执行完 push rbp → 返回地址在 SP+8
        pc = ((uintptr_t*)sp)[1] - 1;
        sp += 16;
        return true;
    }
    // ... 更多情况 ...
    return false;
}
```

**设计思想**：JIT 编译的帧没有 DWARF 信息（CodeHeap 动态生成），所以只能通过 NMethod 元数据 + 指令模式匹配来回溯。

---

## 七、[B] 解释帧处理 — isInterpreter

### 7.1 解释器帧布局

```
高地址 (栈底)
┌──────────────────────┐
│ ...上一帧...          │
├──────────────────────┤ ← sender SP = fp[-1] (offset = -1)
│ return address       │  fp[FRAME_PC_SLOT] = fp[1]
├──────────────────────┤
│ saved FP (prev)      │  *fp
├──────────────────────┤ ← fp
│ ...                  │
│ locals               │
│ BCP (bytecode ptr)   │  fp[bcp_offset]  (offset = -7 典型值)
│ VMMethod*            │  fp[-3] (method_offset = -3)
│ sender SP            │  fp[-1] (sender_sp_offset = -1)
│ ...表达式栈...        │
├──────────────────────┤ ← sp
低地址 (栈顶)
```

### 7.2 核心逻辑

```cpp
if (nm->isInterpreter()) {
    // 反优化检查
    if (vm_thread != NULL && vm_thread->inDeopt()) {
        fillFrame(frames[depth++], BCI_ERROR, "break_deopt");
        break;
    }

    // 合理性检查：FP 是否像一个解释器帧？
    bool is_plausible_interpreter_frame =
        !inDeadZone((const void*)fp) && aligned(fp)
        && sp > fp - MAX_INTERPRETER_FRAME_SIZE   // 帧不能太大 (4KB)
        && sp < fp + bcp_offset * sizeof(void*);  // SP 在 BCP 之下

    if (is_plausible_interpreter_frame) {
        VMMethod* method = ((VMMethod**)fp)[InterpreterFrame::method_offset];  // fp[-3]
        jmethodID method_id = getMethodId(method);
        if (method_id != NULL) {
            // 从 BCP 计算 BCI
            const char* bytecode_start = method->bytecode();
            const char* bcp = ((const char**)fp)[bcp_offset];
            int bci = (bytecode_start == NULL || bcp < bytecode_start) ? 0 : bcp - bytecode_start;
            fillFrame(frames[depth++], FRAME_INTERPRETED, bci, method_id);

            // 帧推进
            sp = ((uintptr_t*)fp)[InterpreterFrame::sender_sp_offset];  // fp[-1]
            pc = stripPointer(((void**)fp)[FRAME_PC_SLOT]);             // fp[1]
            fp = *(uintptr_t*)fp;                                       // *fp
            continue;
        }
    }

    // 第一帧的特殊处理（从 ucontext 的 RBX 获取 method）
    if (depth == 0) {
        VMMethod* method = (VMMethod*)frame.method();   // RBX 寄存器
        jmethodID method_id = getMethodId(method);
        if (method_id != NULL) {
            fillFrame(frames[depth++], FRAME_INTERPRETED, 0, method_id);
            // ... 特殊帧推进 ...
            continue;
        }
    }

    fillFrame(frames[depth++], BCI_ERROR, "break_interpreted");
    break;
}
```

### 7.3 关键细节

1. **`method_offset = -3`**：解释器帧中 VMMethod* 保存在 `FP - 3*8 = FP - 24`
2. **`bcp_offset`**：通过 VMStructs 在启动时推断（`_interpreter_frame_bcp_offset`），典型值为 -7
3. **BCI 计算**：`bci = BCP - bytecode_start`，即当前字节码指针 - 方法字节码起始地址
4. **depth == 0 的特殊处理**：如果信号恰好中断在解释器调度循环的内部，FP 可能还没指向有效的解释器帧，但 RBX 寄存器保存了当前执行的 VMMethod*（x86_64 HotSpot 约定）

---

## 八、[C] Entry 帧处理 — isEntryFrame

### 8.1 什么是 Entry 帧？

Entry 帧是 Java↔Native 的过渡帧。当 JVM 从 C++ 代码调用 Java 方法时（如 `JavaCalls::call`），会建立一个 Entry 帧。Entry 帧中保存了一个 `JavaCallWrapper`，里面有下一段 Java 栈的 `JavaFrameAnchor`。

```
栈布局:
  [Java 帧 N]
  [Java 帧 N-1]
  ...
  [Java 帧 1]
  [Entry 帧]  ← call_stub_return 地址
  [C++ 帧]    ← JavaCalls::call()
  ...
  [Entry 帧]  ← 更深层的 Java↔Native 转换
  [Java 帧 M]
  ...
```

### 8.2 核心逻辑

```cpp
if (nm->isEntryFrame(pc) && !features.mixed) {
    JavaFrameAnchor* next_anchor = JavaFrameAnchor::fromEntryFrame(fp);
    if (next_anchor == NULL) {
        fillFrame(frames[depth++], BCI_ERROR, "break_entry_frame");
        break;
    }
    if (!next_anchor->getFrame(pc, sp, fp)) {
        // Java 栈结束
        break;
    }
    continue;  // 跳到下一段 Java 栈
}
```

**`fromEntryFrame`** 从 FP 偏移取出 `JavaCallWrapper*`，再从 wrapper 取出 anchor：

```cpp
static JavaFrameAnchor* fromEntryFrame(uintptr_t fp) {
    const char* call_wrapper = *(const char**)(fp + _entry_frame_call_wrapper_offset);
    if (!goodPtr(call_wrapper) || (uintptr_t)call_wrapper - fp > 512) {
        return NULL;  // 安全检查
    }
    return (JavaFrameAnchor*)(call_wrapper + _call_wrapper_anchor_offset);
}
```

---

## 九、[D] Stub 帧处理

### 9.1 什么是 Stub？

JVM 运行时有许多生成的代码桩：
- `StubRoutines::*` — 运行时辅助函数
- `vtable chunks` — 虚方法分派
- `itable stubs` — 接口方法分派
- `InlineCacheBuffer` — 内联缓存
- `SafepointBlob` — Safepoint 轮询

### 9.2 核心逻辑

```cpp
else {
    // VTable stub 特殊处理：获取接收者类名
    if (features.vtable_target && nm->isVTableStub() && depth == 0) {
        uintptr_t receiver = frame.jarg0();   // RSI（第二个参数 = Java this）
        if (receiver != 0) {
            VMSymbol* symbol = VMKlass::fromOop(receiver)->name();
            u32 class_id = profiler->classMap()->lookup(symbol->body(), symbol->length());
            fillFrame(frames[depth++], BCI_ALLOC, class_id);
        }
    }

    // 查找 stub 名称
    CodeBlob* stub = profiler->findRuntimeStub(pc);
    const char* name = stub != NULL ? stub->_name : nm->name();

    if (details) {
        fillFrame(frames[depth++], BCI_NATIVE_FRAME, name);
    }

    // 尝试 unwindStub
    if (frame.unwindStub((instruction_t*)start, name, pc, sp, fp)) {
        continue;
    }

    // Fallback: 用 frameSize 跳过
    if (depth > 1 && nm->frameSize() > 0) {
        sp += nm->frameSize() * sizeof(void*);
        fp = ((uintptr_t*)sp)[-FRAME_PC_SLOT - 1];
        pc = ((const void**)sp)[-FRAME_PC_SLOT];
        continue;
    }
}
```

### 9.3 unwindStub（x86_64 实现）

```cpp
bool StackFrame::unwindStub(instruction_t* entry, const char* name, uintptr_t& pc, uintptr_t& sp, uintptr_t& fp) {
    instruction_t* ip = (instruction_t*)pc;

    // Case 1: 在 stub 入口 或 ret 指令处 或 vtable/itable/ICBuffer
    if (ip == entry || *ip == 0xc3 || strncmp(name, "itable", 6) == 0 || ...) {
        pc = ((uintptr_t*)sp)[0] - 1;  // 返回地址在栈顶
        sp += 8;
        return true;
    }

    // Case 2: stub 以 push rbp; mov rbp, rsp 开始
    if (entry != NULL && *(unsigned int*)entry == 0xec8b4855) {
        if (ip == entry + 1) {
            // 刚执行完 push rbp
            pc = ((uintptr_t*)sp)[1] - 1;
            sp += 16;
            return true;
        } else if (withinCurrentStack(fp)) {
            // 标准 FP-based 帧
            sp = fp + 16;
            fp = ((uintptr_t*)sp)[-2];
            pc = ((uintptr_t*)sp)[-1] - 1;
            return true;
        }
    }
    return false;
}
```

---

## 十、[E] 原生帧处理 — 不在 CodeHeap 中

### 10.1 核心逻辑

```cpp
else {
    // PC 不在 CodeHeap → 原生库中的代码

    // 特殊标记处理
    const char* method_name = profiler->findNativeMethod(pc);
    char mark;
    if (method_name != NULL && (mark = NativeFunc::mark(method_name)) != 0) {
        if (mark == MARK_ASYNC_PROFILER && (event_type == MALLOC_SAMPLE || event_type == NATIVE_LOCK_SAMPLE)) {
            depth = 0;  // 丢弃 profiler 内部帧
        } else if (mark == MARK_COMPILER_ENTRY && features.comp_task && vm_thread != NULL) {
            VMMethod* method = vm_thread->compiledMethod();
            jmethodID method_id = method != NULL ? method->id() : NULL;
            if (method_id != NULL) {
                fillFrame(frames[depth++], FRAME_JIT_COMPILED, 0, method_id);
            }
        }
    }
    fillFrame(frames[depth++], BCI_NATIVE_FRAME, method_name);
}

// DWARF 回溯（与 walkDwarf 相同的代码）
CodeCache* cc = profiler->findLibraryByAddress(pc);
FrameDesc* f = cc != NULL ? cc->findFrameDesc(pc) : &FrameDesc::default_frame;
// ... CFA 计算、FP/PC 恢复 ...
```

### 10.2 特殊标记（Mark）

| Mark | 值 | 含义 | 处理方式 |
|------|---|------|---------|
| `MARK_VM_RUNTIME` | 1 | JVM 运行时代码（如 GC） | 无特殊处理 |
| `MARK_INTERPRETER` | 2 | 解释器入口 | 无特殊处理 |
| `MARK_COMPILER_ENTRY` | 3 | JIT 编译器入口 | 插入当前编译任务的方法帧 |
| `MARK_ASYNC_PROFILER` | 4 | profiler 内部（如 hook 函数） | malloc/lock 事件时清空内部帧 |

**MARK_COMPILER_ENTRY 的作用**：当 CPU 采样恰好命中 C2 编译线程时，普通栈回溯只能看到编译器的 C++ 帧。通过 `vm_thread->compiledMethod()` 获取当前正在编译的 Java 方法，插入一个伪帧，让用户知道"这段 CPU 时间花在编译方法 X 上了"。

---

## 十一、Anchor Fallback — goto unwind_loop

### 11.1 问题

当信号中断在纯原生代码（libc、libpthread 等深处），DWARF 回溯可能无法走到 CodeHeap——要么遇到无 DWARF 信息的帧，要么 FP 链断了。此时已收集的帧全是原生帧（`method_id == NULL`），没有 Java 帧。

### 11.2 解决方案

```cpp
// 循环结束后
if (anchor != NULL && anchor->getFrame(pc, sp, fp)) {
    anchor = NULL;
    // 弹出无用的未知帧
    while (depth > 0 && frames[depth - 1].method_id == NULL) depth--;
    goto unwind_loop;  // 从 anchor 位置重新开始！
}
```

**效果**：
1. 先尝试正常 DWARF 回溯
2. 如果走到死胡同但 anchor 还有值 → 跳到 anchor 保存的 Java 帧位置
3. 弹出之前收集的无意义原生帧
4. 从 Java 帧位置重新开始循环

### 11.3 执行流示意

```
信号中断点: libc::nanosleep (深层原生代码)

Phase 1 (DWARF 回溯):
  [0] libc::nanosleep
  [1] libc::__clock_nanosleep
  [2] Thread::sleep
  [3] JVM_Sleep
  → DWARF 走到头了（没法到 CodeHeap）

Phase 2 (anchor fallback):
  anchor->getFrame() → 跳到 Interpreter 帧
  弹出 [0]~[3]
  goto unwind_loop

Phase 3 (从 anchor 继续):
  [0] libc::nanosleep     ← 被弹出了
  [1] libc::...            ← 被弹出了
  → 重新开始：
  [0] Thread.sleep (INTERPRETED)
  [1] MyClass.run (INTERPRETED)
  [2] Thread.run (INTERPRETED)
```

等等——上面的例子不完全准确。实际上 anchor fallback 发生时，DWARF 已经把原生帧收集了，弹出的只是 `method_id == NULL` 的帧。但如果 `details = true`（默认 cpu 事件），原生帧是有 `method_name` 的（虽然 `method_id` 是 `char*` 而非 `jmethodID`，但不是 NULL），所以不会被弹出。

实际的 fallback 更常见于 `details = false` 的场景（如分配追踪），此时原生帧不被记录。

---

## 十二、walkVM 完整流程图

```
                    walkVM(ucontext, frames[], max_depth, ...)
                            │
                    ┌───────┴───────┐
                    │  setjmp 设置  │ ← SEGV 恢复点
                    │  崩溃保护     │
                    └───────┬───────┘
                            │
                    ┌───────┴───────┐
                    │ 提取 pc/fp/sp │
                    │ 获取 anchor   │
                    └───────┬───────┘
                            │
                    ┌───────▼───────┐
            ┌─── unwind_loop: ◄────────────────────────────┐
            │       │                                       │
            │  ┌────▼─────┐                                 │
            │  │ sp 安全检查│                                │
            │  └────┬─────┘                                 │
            │       │                                       │
            │  ┌────▼──────────────────────┐                │
            │  │ CodeHeap::contains(pc) ?  │                │
            │  └────┬──────────┬───────────┘                │
            │       │YES       │NO                          │
            │  ┌────▼─────┐  ┌─▼──────────┐                │
            │  │findNMethod│  │ 原生帧 [E] │                │
            │  └────┬─────┘  │ fillFrame   │                │
            │       │        │ DWARF unwind│                │
            │  ┌────▼────┐   └──────┬──────┘                │
            │  │ anchor   │         │                       │
            │  │ 修正?    │    ┌────▼────┐                  │
            │  └────┬────┘    │ continue │──────────────┐   │
            │       │         └─────────┘               │   │
            │  ┌────▼──────────────────┐                │   │
            │  │ nm 类型分派           │                │   │
            │  ├── isNMethod [A]       │                │   │
            │  │   fillFrame(JIT/C1)   │                │   │
            │  │   ScopeDesc 展开内联  │                │   │
            │  │   sp += frameSize()   │──── continue ──┤   │
            │  │                       │                │   │
            │  ├── isInterpreter [B]   │                │   │
            │  │   fp[-3] → method     │                │   │
            │  │   fp[bcp] → BCI       │                │   │
            │  │   sp = fp[-1]         │──── continue ──┤   │
            │  │                       │                │   │
            │  ├── isEntryFrame [C]    │                │   │
            │  │   fromEntryFrame(fp)  │                │   │
            │  │   → next anchor       │──── continue ──┤   │
            │  │                       │                │   │
            │  └── else (Stub) [D]     │                │   │
            │      unwindStub()        │──── continue ──┘   │
            │      or frameSize()      │                    │
            └──────────────────────────┘                    │
                            │                               │
                    ┌───────▼──────────┐                    │
                    │ anchor fallback? │                    │
                    │ goto unwind_loop │────────────────────┘
                    └───────┬──────────┘
                            │
                    ┌───────▼────────┐
                    │ return depth   │
                    └────────────────┘
```

---

## 十三、walkVM vs walkFP vs walkDwarf — 终极对比

| 维度 | walkFP | walkDwarf | walkVM |
|------|--------|-----------|--------|
| **输出格式** | `const void** callchain` | `const void** callchain` | `ASGCT_CallFrame* frames` |
| **输出内容** | 只有原生帧 PC | 只有原生帧 PC | 混合帧（类型+BCI+方法ID） |
| **需要 ASGCT?** | ✅ 是 | ✅ 是 | ❌ 不需要 |
| **Java 帧处理** | 到 CodeHeap 停，交给 ASGCT | 同左 | 自己解析所有 JVM 帧类型 |
| **原生帧回溯** | FP 链 | DWARF CFI | DWARF CFI（同 walkDwarf） |
| **编译帧支持** | ❌ | ❌ | ✅ ScopeDesc + 内联展开 |
| **解释帧支持** | ❌ | ❌ | ✅ FP 偏移 + BCP→BCI |
| **Entry 帧穿越** | ❌ | ❌ | ✅ 多段 Java 栈 |
| **Stub 帧支持** | ❌ | ❌ | ✅ 指令模式匹配 |
| **Prologue/Epilogue** | ❌ | ❌ | ✅ 特殊处理 |
| **崩溃保护** | SafeAccess | 范围检查 | **setjmp/longjmp** |
| **VMStructs 依赖** | CodeHeap::contains | CodeHeap::contains | **几乎全部偏移量** |
| **代码复杂度** | ~20 行循环 | ~50 行循环 | **~250 行循环** |
| **适用场景** | debug 构建 | C++ 性能分析 | **通用（默认）** |

---

## 十四、错误帧类型汇总

walkVM 在遇到无法回溯的情况时，会插入错误帧而非直接停止。这些错误帧在火焰图中显示为 `[break_xxx]`：

| 错误帧名 | 含义 | 触发条件 |
|---------|------|---------|
| `break_not_walkable` | setjmp 恢复后 | walkVM 过程中发生 SEGV |
| `break_stack_range` | SP 范围异常 | sp < prev_sp 或 sp >= bottom |
| `unknown_nmethod` | CodeHeap 中找不到 NMethod | 代码被卸载？地址计算错误？ |
| `break_compiled` | 编译帧无法回溯 | 帧不完整且 unwindPrologue 失败 |
| `break_interpreted` | 解释帧无法回溯 | FP 不像解释器帧且 method 无效 |
| `break_deopt` | 正在反优化 | vm_thread->inDeopt() = true |
| `break_entry_frame` | Entry 帧无法穿越 | JavaCallWrapper 无效 |

---

## 十五、InterpreterFrame 偏移量常量

```cpp
class InterpreterFrame : VMStructs {
  public:
    enum {
        sender_sp_offset = -1,  // fp[-1] = 调用者的 SP
        method_offset = -3      // fp[-3] = VMMethod*
    };

    static int bcp_offset() {
        return _interpreter_frame_bcp_offset;  // 运行时通过 VMStructs 推断
    }
};
```

**为什么 method_offset = -3 而不是通过 VMStructs 推断？**

因为 HotSpot 解释器帧的布局在 x86_64 上从 JDK 8 到 JDK 21 都没有变过——method 在 FP 下方第 3 个 slot。但 bcp_offset 在不同版本间变化过，所以需要动态推断。

---

## 十六、总结

### walkVM 的核心设计

1. **一个循环统一所有帧类型**：不像 JVM 内部的 `vframe` 框架那样用多态和迭代器，walkVM 在一个 while 循环中通过 `if-else if` 分派处理 5 种帧类型，追求信号安全和最小开销

2. **三层安全网**：
   - 每步 SP 范围 + 对齐检查
   - 指针有效性检查（`inDeadZone`、`aligned`、`goodPtr`）
   - setjmp/longjmp 作为最后防线

3. **Anchor 双重角色**：
   - 初次进入 CodeHeap 时，修正不可靠的 SP/FP
   - DWARF 回溯失败时，作为 fallback 跳转点

4. **指令模式匹配**：对 prologue/epilogue/stub 的处理不依赖 DWARF，而是直接检查 x86 指令字节（如 `0xc3=ret`、`0x55=push rbp`、`0x5d=pop rbp`）

5. **ScopeDesc 内联展开**：JIT 编译帧可能包含多个 Java 方法的内联帧，walkVM 通过 NMethod 的 scopes 数据完整展开

### GDB 验证关键数据

| 验证项 | 实际值 | 含义 |
|--------|--------|------|
| max_depth | **2048** | 远大于 walkFP/walkDwarf 的 128 |
| lock_index | 3~13 | CONCURRENCY_LEVEL = 16 个槽 |
| event_type | PERF_SAMPLE (0) | CPU 采样 |
| vm_thread | 0x7ffff17cb800 | 通过 TLS 获取 |
| anchor->lastJavaPC | 0x7fffec81f87d | CodeHeap 中 Interpreter |
| details | true | 显示原生帧名和编译层级 |
| walkVM 返回帧数 | **30~31**（Java 线程） | 混合帧 |
| walkVM 返回帧数 | 1~10（VM 线程） | 纯原生帧 |
| checkFault 触发 | ✅ 是 | 运行中确实遇到 SEGV |

### Part 5 栈回溯章节总结

| 小节 | 算法 | 输出 | 复杂度 | 使用场景 |
|------|------|------|--------|---------|
| 5.1 | recordSample | 调度入口 | — | — |
| 5.2 | ASGCT | Java 帧 | 中等 | 配合 walkFP/walkDwarf |
| 5.3 | walkFP | 原生帧 (FP链) | 极低 | debug 构建 |
| 5.4 | walkDwarf | 原生帧 (DWARF) | 中等 | C++ 分析 |
| **5.5** | **walkVM** | **混合帧** | **很高** | **默认模式** |

### 在整体架构中的位置

```
Agent 加载（Ch01）
  → VMStructs 初始化（Ch02）
  → Engine 体系（Ch03）
  → perf_event_open + 信号驱动（Ch04）
  → 信号到达 → recordSample()（Ch05.1）
    ├── getNativeTrace（Ch05.1）
    │   ├── CSTACK_FP → walkFP（Ch05.3）
    │   └── CSTACK_DWARF → walkDwarf（Ch05.4）
    ├── getJavaTraceAsync → ASGCT（Ch05.2）
    └── CSTACK_VM → walkVM（本节）  ← Part 5 完成！
```

---

*创建日期: 2026-02-09*
*GDB 验证环境: OpenJDK 11 slowdebug + async-profiler v4.0*
*标准条件: -Xms8g -Xmx8g -XX:+UseG1GC -Xint --cstack vm (默认)*
