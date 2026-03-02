# AsyncProfiler 源码学习：Lesson 4 - 栈回溯深入（Java 帧处理）

> **学习目标**：深入理解 walkVM 如何处理 Java 栈帧，包括 JIT 编译帧、解释帧、Native 帧和内联方法展开。

---

## 1. walkVM 核心流程概览

### 1.1 函数签名

```cpp
int StackWalker::walkVM(void* ucontext, ASGCT_CallFrame* frames, int max_depth,
                        int lock_index, StackWalkFeatures features, EventType event_type)
```

**参数**：
- `ucontext`：线程上下文（PC/SP/FP）
- `frames`：输出数组，存储调用栈
- `max_depth`：最大深度（默认 2048）
- `lock_index`：崩溃保护索引
- `features`：栈回溯特性（mixed、vtable_target 等）
- `event_type`：事件类型（PERF_SAMPLE、MALLOC_SAMPLE 等）

**返回值**：实际栈帧深度

---

### 1.2 整体流程

```
┌─────────────────────────────────────────────────────────────┐
│                    walkVM 核心流程                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. 初始化                                                   │
│     ├─ 获取 PC/SP/FP                                        │
│     ├─ 设置崩溃保护（setjmp/longjmp）                       │
│     └─ 获取 JavaFrameAnchor                                 │
│                                                             │
│  2. 主循环（遍历栈帧）                                       │
│     while (depth < max_depth) {                             │
│       ├─ 检查 SP 合法性                                     │
│       ├─ 判断 PC 所在区域：                                 │
│       │   ├─ CodeHeap（JIT 编译代码或解释器）               │
│       │   │   ├─ NMethod（JIT 编译帧）                      │
│       │   │   ├─ Interpreter（解释帧）                      │
│       │   │   ├─ Entry Frame（JNI 边界）                    │
│       │   │   └─ Stub（运行时存根）                         │
│       │   └─ Native 代码                                    │
│       │       └─ 使用 DWARF CFI 回溯                        │
│       └─ 恢复上一帧（PC/SP/FP）                             │
│     }                                                       │
│                                                             │
│  3. 错误处理                                                 │
│     ├─ 崩溃保护触发：fillFrame(BCI_ERROR)                   │
│     └─ 栈范围检查失败：break                                │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. 初始化阶段详解

### 2.1 获取 PC/SP/FP

**源码**：`stackWalker.cpp:207-221`

```cpp
const void* pc;
uintptr_t fp;
uintptr_t sp;

StackFrame frame(ucontext ? ucontext : &empty_ucontext);
if (ucontext == NULL) {
    // 从当前函数调用上下文获取
    pc = callerPC();
    fp = (uintptr_t)callerFP();
    sp = (uintptr_t)callerSP();
} else {
    // 从信号处理函数的上下文获取
    pc = (const void*)frame.pc();
    fp = frame.fp();
    sp = frame.sp();
}
```

**关键点**：
- `ucontext == NULL`：从当前函数调用上下文获取（如 AsyncGetCallTrace）
- `ucontext != NULL`：从信号处理函数获取（如 SIGPROF 信号）

---

### 2.2 崩溃保护机制

**源码**：`stackWalker.cpp:226-238`

```cpp
jmp_buf current_ctx;
crash_protection_ctx[lock_index] = &current_ctx;

volatile int depth = 0;

if (setjmp(current_ctx) != 0) {
    // 崩溃后恢复
    crash_protection_ctx[lock_index] = NULL;
    if (depth < max_depth) {
        fillFrame(frames[depth++], BCI_ERROR, "break_not_walkable");
    }
    return depth;
}
```

**工作原理**：
1. `setjmp` 保存当前上下文
2. 栈回溯过程中访问非法内存触发 SIGSEGV
3. `checkFault()` 捕获信号，调用 `longjmp` 恢复
4. 记录错误帧，继续执行

---

### 2.3 JavaFrameAnchor 获取

**源码**：`stackWalker.cpp:243-253`

```cpp
JavaFrameAnchor* anchor = NULL;
VMThread* vm_thread = VMThread::current();
if (vm_thread != NULL && vm_thread->isJavaThread()) {
    if (details) {
        anchor = vm_thread->anchor();  // 保存锚点，后续用于修正
    } else if (!vm_thread->anchor()->restoreFrame(pc, sp, fp)) {
        return 0;  // 简单栈回溯失败
    }
}
```

**JavaFrameAnchor 的作用**：
- 记录最后一个 Java 栈帧的位置（`_last_Java_sp/fp/pc`）
- 从 Native 代码进入 Java 代码时，用于精确定位 Java 栈起点
- 在栈回溯过程中用于修正栈帧位置

---

## 3. NMethod（JIT 编译帧）处理

### 3.1 判断 PC 是否在 CodeHeap 中

**源码**：`stackWalker.cpp:265-273`

```cpp
if (CodeHeap::contains(pc)) {
    NMethod* nm = CodeHeap::findNMethod(pc);
    if (nm == NULL) {
        if (anchor == NULL) {
            fillFrame(frames[depth++], BCI_ERROR, "unknown_nmethod");
        }
        break;
    }
```

**CodeHeap 范围检查**：
```cpp
bool CodeHeap::contains(const void* pc) {
    return _memory.contains(pc);
}

bool CodeHeap::contains(const void* p) const {
    return _low_boundary <= p && p < _high;
}
```

**NMethod 查找**：
```cpp
NMethod* CodeHeap::findNMethod(const void* pc) {
    // 在 CodeCache 的 nmethod 表中查找
    // 根据 PC 找到对应的 NMethod
}
```

---

### 3.2 栈帧完整性检查

**源码**：`stackWalker.cpp:291`

```cpp
if (nm->isFrameCompleteAt(pc)) {
    // 栈帧完整，可以安全回溯
    ...
} else {
    // 栈帧不完整（在 prologue/epilogue 中）
    if (frame.unwindPrologue(nm, (uintptr_t&)pc, sp, fp)) {
        continue;
    }
    fillFrame(frames[depth++], BCI_ERROR, "break_compiled");
    break;
}
```

**isFrameCompleteAt 原理**：
- JIT 编译时记录 `_frame_complete_offset`
- 如果 PC > `_frame_complete_offset`，表示栈帧已建立
- 栈帧完整 = FP/SP 已正确设置，可以安全回溯

**验证脚本**：`jvm-md/tmp-file/lesson04/verify_nmethod.gdb`

---

### 3.3 内联方法展开

**源码**：`stackWalker.cpp:296-308`

```cpp
int scope_offset = nm->findScopeOffset(pc);
if (scope_offset > 0) {
    depth--;  // 撤销外层方法帧
    ScopeDesc scope(nm);
    do {
        scope_offset = scope.decode(scope_offset);
        FrameTypeId type = scope_offset > 0 ? FRAME_INLINED : FRAME_JIT_COMPILED;
        fillFrame(frames[depth++], type, scope.bci(), scope.method()->id());
    } while (scope_offset > 0 && depth < max_depth);
}
```

**ScopeDesc 结构**：
```cpp
class ScopeDesc {
    NMethod* _nm;           // 所属 NMethod
    VMMethod* _method;      // 对应的 Java 方法
    int _bci;               // 字节码索引
    int _decode_offset;     // 解码偏移
};
```

**内联展开示例**：

```
源代码：
  public void foo() {
      bar();  // 内联方法
  }

NMethod：
  - foo() 被编译
  - bar() 内联到 foo() 中

ScopeDesc 表：
  [0] scope_offset = 100, method = foo, bci = 5
  [1] scope_offset = 50,  method = bar, bci = 0  ← 内联方法
  [2] scope_offset = 0,   method = foo, bci = 0  ← 最外层

展开后调用栈：
  foo() bci=0    ← FRAME_JIT_COMPILED
  bar() bci=0    ← FRAME_INLINED
  foo() bci=5    ← FRAME_INLINED
```

---

### 3.4 栈帧大小计算

**源码**：`stackWalker.cpp:313-315`

```cpp
sp += nm->frameSize() * sizeof(void*);
fp = ((uintptr_t*)sp)[-FRAME_PC_SLOT - 1];
pc = ((const void**)sp)[-FRAME_PC_SLOT];
```

**frameSize() 实现**：
```cpp
int NMethod::frameSize() {
    return _frame_size;  // 单位：字（word）
}
```

**栈帧布局**：
```
┌─────────────────────────────────┐
│  Caller PC（返回地址）          │ ← sp + frame_size * 8
│  Caller FP（保存的帧指针）      │ ← sp + frame_size * 8 - 8
│  ...                            │
│  Local Variables                │
│  ...                            │
│  Saved Registers                │
│  ...                            │
└─────────────────────────────────┘
```

**回溯公式**：
- 新 SP = 旧 SP + frameSize * sizeof(void*)
- 新 FP = *(新 SP - 16)
- 新 PC = *(新 SP - 8)

---

## 4. InterpreterFrame（解释帧）处理

### 4.1 解释帧布局

**源码**：`stackWalker.cpp:323-346`

```
┌─────────────────────────────────────────────────────────────┐
│                InterpreterFrame 布局                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  高地址                                                     │
│  ┌──────────────────────────────────────────────────┐      │
│  │  Monitor（锁对象）                                │      │
│  └──────────────────────────────────────────────────┘      │
│  ┌──────────────────────────────────────────────────┐      │
│  │  Operand Stack（操作数栈）                        │      │
│  └──────────────────────────────────────────────────┘      │
│  ┌──────────────────────────────────────────────────┐      │
│  │  Locals（局部变量表）                             │      │
│  └──────────────────────────────────────────────────┘      │
│  ┌──────────────────────────────────────────────────┐      │
│  │  Method*（方法对象）        ← FP + method_offset │      │
│  │  BCP（字节码指针）          ← FP + bcp_offset    │      │
│  │  ...                                             │      │
│  │  Sender SP（调用者 SP）     ← FP + sender_sp_offset │   │
│  │  Return Address（返回地址） ← FP + 8             │      │
│  │  Saved FP（保存的 FP）      ← FP                 │      │
│  └──────────────────────────────────────────────────┘      │
│  ← SP                                                       │
│  低地址                                                     │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

### 4.2 关键偏移量

**源码**：`vmStructs.cpp`（通过 gHotSpotVMStructs 推断）

```cpp
class InterpreterFrame {
    static int method_offset;    // Method* 偏移
    static int bcp_offset;       // BCP 偏移
    static int sender_sp_offset; // Sender SP 偏移
};
```

**验证脚本**：`jvm-md/tmp-file/lesson04/verify_interpreter_frame.gdb`（待创建）

---

### 4.3 解释帧回溯代码

**源码**：`stackWalker.cpp:334-346`

```cpp
VMMethod* method = ((VMMethod**)fp)[InterpreterFrame::method_offset];
jmethodID method_id = getMethodId(method);
if (method_id != NULL) {
    // 获取字节码位置
    const char* bytecode_start = method->bytecode();
    const char* bcp = ((const char**)fp)[bcp_offset];
    int bci = bytecode_start == NULL || bcp < bytecode_start ? 0 : bcp - bytecode_start;

    fillFrame(frames[depth++], FRAME_INTERPRETED, bci, method_id);

    // 回溯到上一帧
    sp = ((uintptr_t*)fp)[InterpreterFrame::sender_sp_offset];
    pc = stripPointer(((void**)fp)[FRAME_PC_SLOT]);
    fp = *(uintptr_t*)fp;
    continue;
}
```

**关键步骤**：
1. 从 FP 读取 `Method*` 对象
2. 从 FP 读取 BCP（字节码指针）
3. 计算 BCI = BCP - bytecode_start
4. 记录解释帧
5. 回溯：从 FP 读取 sender_sp、return address、saved fp

---

## 5. Entry Frame 与 JavaFrameAnchor 修正

### 5.1 Entry Frame 检测

**源码**：`stackWalker.cpp:369-379`

```cpp
else if (nm->isEntryFrame(pc) && !features.mixed) {
    JavaFrameAnchor* next_anchor = JavaFrameAnchor::fromEntryFrame(fp);
    if (next_anchor == NULL) {
        fillFrame(frames[depth++], BCI_ERROR, "break_entry_frame");
        break;
    }
    if (!next_anchor->getFrame(pc, sp, fp)) {
        break;  // Java 栈结束
    }
    continue;
}
```

**Entry Frame 的作用**：
- JNI 调用的边界帧
- 包含 `JavaFrameAnchor`，记录最后一个 Java 栈帧位置
- 用于从 Native 代码进入 Java 代码时精确定位

---

### 5.2 JavaFrameAnchor 结构

```cpp
class JavaFrameAnchor {
    uintptr_t _last_Java_sp;   // 最后一个 Java 帧 SP
    uintptr_t _last_Java_fp;   // 最后一个 Java 帧 FP
    const void* _last_Java_pc; // 最后一个 Java 帧 PC
};
```

**修正逻辑**：
```cpp
bool JavaFrameAnchor::getFrame(const void*& pc, uintptr_t& sp, uintptr_t& fp) {
    if (_last_Java_sp != 0) {
        sp = _last_Java_sp;
        fp = _last_Java_fp;
        pc = _last_Java_pc;
        return true;
    }
    return false;
}
```

---

## 6. Native 帧处理

### 6.1 Native 方法查找

**源码**：`stackWalker.cpp:410-425`

```cpp
const char* method_name = profiler->findNativeMethod(pc);
char mark;
if (method_name != NULL && (mark = NativeFunc::mark(method_name)) != 0) {
    if (mark == MARK_ASYNC_PROFILER && (event_type == MALLOC_SAMPLE || event_type == NATIVE_LOCK_SAMPLE)) {
        // 跳过 async-profiler 内部帧
        depth = 0;
    } else if (mark == MARK_COMPILER_ENTRY && features.comp_task && vm_thread != NULL) {
        // 插入编译任务作为伪 Java 帧
        VMMethod* method = vm_thread->compiledMethod();
        jmethodID method_id = method != NULL ? method->id() : NULL;
        if (method_id != NULL) {
            fillFrame(frames[depth++], FRAME_JIT_COMPILED, 0, method_id);
        }
    }
}
fillFrame(frames[depth++], BCI_NATIVE_FRAME, method_name);
```

**Native 帧标记**：
- `MARK_ASYNC_PROFILER`：async-profiler 内部函数
- `MARK_COMPILER_ENTRY`：JIT 编译器入口

---

### 6.2 DWARF CFI 回溯

**源码**：`stackWalker.cpp:428-477`

```cpp
CodeCache* cc = profiler->findLibraryByAddress(pc);
FrameDesc* f = cc != NULL ? cc->findFrameDesc(pc) : &FrameDesc::default_frame;

u8 cfa_reg = (u8)f->cfa;
int cfa_off = f->cfa >> 8;
if (cfa_reg == DW_REG_SP) {
    sp = sp + cfa_off;
} else if (cfa_reg == DW_REG_FP) {
    sp = fp + cfa_off;
}

// ... 恢复 FP 和 PC
```

**详细分析**：参考 Lesson 3 的 walkDwarf 部分

---

## 7. 错误处理

### 7.1 常见错误类型

| 错误类型 | 含义 | 原因 |
|---------|------|------|
| `break_not_walkable` | 栈不可回溯 | 崩溃保护触发 |
| `break_stack_range` | 栈范围错误 | SP 越界 |
| `unknown_nmethod` | 未知的 NMethod | NMethod 查找失败 |
| `break_compiled` | 编译帧回溯失败 | 栈帧不完整 |
| `break_deopt` | 正在反优化 | Deopt 状态 |
| `break_interpreted` | 解释帧回溯失败 | FP 非法 |
| `break_entry_frame` | Entry Frame 错误 | JavaFrameAnchor 缺失 |

---

### 7.2 栈范围检查

**源码**：`stackWalker.cpp:259-262`

```cpp
if (sp < prev_sp || sp >= bottom || !aligned(sp)) {
    fillFrame(frames[depth++], BCI_ERROR, "break_stack_range");
    break;
}
```

**检查项**：
1. `sp < prev_sp`：SP 必须向高地址增长
2. `sp >= bottom`：SP 不能超出栈底
3. `!aligned(sp)`：SP 必须对齐（8 字节）

---

## 8. 实战验证

### 验证环境

**标准环境**：
```bash
JVM=/data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java
ASYNC_PROFILER=/data/workspace/async-profiler/build/lib/libasyncProfiler.so
```

---

### 验证项 1：NMethod 栈帧结构

**目标**：验证 NMethod 的 frameSize、isFrameCompleteAt、findScopeOffset

**方法**：GDB attach

**验证脚本**：`jvm-md/tmp-file/lesson04/verify_nmethod.gdb`

**验证状态**：⬜ 待验证

---

### 验证项 2：InterpreterFrame 布局

**目标**：验证 method_offset、bcp_offset、sender_sp_offset

**方法**：GDB attach

**验证脚本**：⬜ 待创建

**验证状态**：⬜ 待验证

---

### 验证项 3：JavaFrameAnchor 修正

**目标**：验证 Entry Frame 的 JavaFrameAnchor 修正逻辑

**方法**：GDB attach

**验证脚本**：⬜ 待创建

**验证状态**：⬜ 待验证

---

### 验证项 4：内联方法展开

**目标**：验证 ScopeDesc::decode 内联展开

**方法**：GDB attach + 特定 Java 程序

**验证脚本**：⬜ 待创建

**验证状态**：⬜ 待验证

---

## 9. 学习检查点

完成本课后，你应该能够：

- [ ] 能解释 walkVM 的整体流程
- [ ] 能说明 NMethod 栈帧的判断和回溯方法
- [ ] 能描述 InterpreterFrame 的布局和关键偏移
- [ ] 能理解 JavaFrameAnchor 的修正机制
- [ ] 能解释内联方法展开的原理
- [ ] 能列举常见的错误类型和原因

---

## 10. 下一步

**下一课预告**：高级采样引擎——AllocTracer 和 LockTracer

**学习内容**：
- 内存分配采样：如何 hook malloc/free
- 锁竞争采样：如何 hook pthread_mutex_lock
- AsyncGetCallTrace 的使用和陷阱

**准备**：
- 阅读 `/data/workspace/async-profiler/src/allocTracer.cpp`
- 阅读 `/data/workspace/async-profiler/src/lockTracer.cpp`
- 了解 JVM AsyncGetCallTrace API

---

**文档版本**：v1.0
**最后更新**：2026-02-12
**作者**：JVM Mastery Skill
**字数**：~15,000 字
