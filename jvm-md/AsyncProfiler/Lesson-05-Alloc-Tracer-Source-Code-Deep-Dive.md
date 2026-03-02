# Lesson 5: AllocTracer 源码深度解析

> 验证驱动学习：先验证，后原理讲解

---

## 1. 核心问题

**AllocTracer 如何实现对 Java 对象分配的采样？**

回答这个问题需要理解：
1. **Trap 断点机制**：如何"钩住"JVM 的分配函数
2. **参数读取**：如何从 CPU 寄存器获取 Klass、对象地址、大小
3. **返回模拟**：如何让被中断的函数继续执行
4. **类名解析**：如何从 Klass 指针获取类名

---

## 2. 验证结果回顾

先看 GDB 验证结论（详见 `Lesson-05-Alloc-Tracer-Verification-Driven.md`）：

### 验证 1：断点指令
```
# 在 send_allocation_in_new_tlab 入口处
0x00007fffd8c9a860: 0xcc  <-- INT3 断点指令
0x00007fffd8c9a861: 0x48  <-- 原始指令被"覆盖"
```

### 验证 2：参数传递（x86_64 SysV ABI）
```
# 调用 send_allocation_in_new_tlab(klass, obj, tlab_size, alloc_size, thread)
# 参数传递：RDI=klass, RSI=obj, RDX=tlab_size, RCX=alloc_size, R8=thread
```

### 验证 3：trapHandler 执行流程
```
Breakpoint hit → SIGTRAP signal → trapHandler() → read args → ret() → continue
```

这些验证结果如何对应到源码？下面逐一解析。

---

## 3. 源码解析

### 3.1 Trap 断点机制

**文件**: `trap.h`

```cpp
class Trap {
  private:
    int _id;
    bool _unprotect;
    bool _protect;
    uintptr_t _entry;                    // 目标函数入口地址
    instruction_t _breakpoint_insn;      // 断点指令 (0xCC = INT3)
    instruction_t _saved_insn;          // 保存的原始指令

    bool patch(instruction_t insn);     // 写入指令

  public:
    void assign(const void* address, uintptr_t offset = BREAKPOINT_OFFSET);
    void pair(Trap& second);

    bool install() {
        return _entry == 0 || patch(_breakpoint_insn);  // 写入 INT3
    }

    bool uninstall() {
        return _entry == 0 || patch(_saved_insn);      // 恢复原始指令
    }

    bool covers(uintptr_t pc) {
        // PC 指向断点指令或下一条指令
        return pc - _entry <= sizeof(instruction_t);
    }
};
```

**关键设计**：
- `_entry` = JVM 分配函数的入口地址（如 `send_allocation_in_new_tlab`）
- `install()` 时：用 `INT3`（0xCC）替换入口处的指令
- `uninstall()` 时：恢复原始指令

**断点原理**：
```
原始代码:    send_allocation_in_new_tlab:
            0x55         push   %rbp           <-- 原始指令
            0x48 0x89    mov    %rsp,%rbp

安装断点后:  send_allocation_in_new_tlab:
            0xcc         int3                   <-- 触发 SIGTRAP
            0x48 0x89    mov    %rsp,%rbp        <-- 被覆盖但仍执行
```

### 3.2 AllocTracer 初始化

**文件**: `allocTracer.cpp`

```cpp
int AllocTracer::_trap_kind;
Trap AllocTracer::_in_new_tlab(0);      // TLAB 内分配
Trap AllocTracer::_outside_tlab(1);    // TLAB 外分配

Error AllocTracer::initialize() {
    CodeCache* libjvm = VMStructs::libjvm();
    const void* ne;  // send_allocation_in_new_tlab 符号
    const void* oe;  // send_allocation_outside_tlab 符号

    // JDK 10+ : _ZN11AllocTracer27send_allocation_in_new_tlab
    if ((ne = libjvm->findSymbolByPrefix("_ZN11AllocTracer27send_allocation_in_new_tlab")) != NULL &&
        (oe = libjvm->findSymbolByPrefix("_ZN11AllocTracer28send_allocation_outside_tlab")) != NULL) {
        _trap_kind = 1;
    }
    // JDK 8u262+ : _ZN11AllocTracer33send_allocation_in_new_tlab_event...
    // JDK 7-9 : _ZN11AllocTracer33send_allocation_in_new_tlab_event...
    
    _in_new_tlab.assign(ne);
    _outside_tlab.assign(oe);
    _in_new_tlab.pair(_outside_tlab);  // 配对两个 Trap

    return Error::OK;
}
```

**JDK 版本兼容**：
- `_trap_kind = 1` (JDK 8u262+): 参数含 Thread*
- `_trap_kind = 2` (JDK 7-9): 参数不含 Thread*

### 3.3 trapHandler 信号处理

这是 AllocTracer 的核心。分析 `trapHandler`：

```cpp
void AllocTracer::trapHandler(int signo, siginfo_t* siginfo, void* ucontext) {
    StackFrame frame(ucontext);                    // ① 构造栈帧
    EventType event_type;
    uintptr_t total_size;
    uintptr_t instance_size;

    // ② 判断是哪个断点被触发
    if (_in_new_tlab.covers(frame.pc())) {
        // TLAB 内分配
        event_type = ALLOC_SAMPLE;
        total_size = _trap_kind == 1 ? frame.arg2() : frame.arg1();
        instance_size = _trap_kind == 1 ? frame.arg3() : frame.arg2();
    } else if (_outside_tlab.covers(frame.pc())) {
        // TLAB 外分配
        event_type = ALLOC_OUTSIDE_TLAB;
        total_size = _trap_kind == 1 ? frame.arg2() : frame.arg1();
        instance_size = 0;
    } else {
        // 不是我们的断点，转发
        Profiler::instance()->trapHandler(signo, siginfo, ucontext);
        return;
    }

    // ③ 读取 Klass 参数
    uintptr_t klass = frame.arg0();

    // ④ 模拟返回，让被中断的函数继续执行
    frame.ret();

    // ⑤ 记录分配事件
    if (_enabled && updateCounter(_allocated_bytes, total_size, _interval)) {
        recordAllocation(ucontext, event_type, klass, total_size, instance_size);
    }
}
```

**分步解析**：

#### 步骤 1：构造 StackFrame

```cpp
StackFrame frame(ucontext);  // ucontext = 信号处理器的 void* ucontext 参数
```

从信号上下文中提取 PC、SP、寄存器等信息。

#### 步骤 2：判断断点类型

```cpp
if (_in_new_tlab.covers(frame.pc())) { ... }
```

`covers()` 检查 PC 是否在断点地址附近（断点指令或下一条指令）。

#### 步骤 3：读取函数参数

**x86_64 SysV ABI 调用约定**：
- 第1个参数：RDI
- 第2个参数：RSI
- 第3个参数：RDX
- 第4个参数：RCX
- 第5个参数：R8
- 第6个参数：R9

**StackFrame 实现**（`stackFrame_x64.cpp`）：

```cpp
uintptr_t StackFrame::arg0() {
    return (uintptr_t)REG(RDI, rdi);   // 读取 RDI 寄存器
}

uintptr_t StackFrame::arg1() {
    return (uintptr_t)REG(RSI, rsi);   // 读取 RSI 寄存器
}

uintptr_t StackFrame::arg2() {
    return (uintptr_t)REG(RDX, rdx);   // 读取 RDX 寄存器
}
```

**JDK 10+ 函数签名**：

```cpp
// send_allocation_in_new_tlab(Klass* klass, HeapWord* obj, 
//                              size_t tlab_size, size_t alloc_size, Thread* thread)
frame.arg0() -> klass      (RDI)
frame.arg1() -> obj        (RSI)
frame.arg2() -> tlab_size  (RDX)
frame.arg3() -> alloc_size (RCX)
frame.arg4() -> thread     (R8)
```

#### 步骤 4：模拟返回 (ret)

为什么需要模拟返回？因为我们用 INT3 中断了函数执行，必须手动恢复执行流。

```cpp
void StackFrame::ret() {
    pc() = stackAt(0);   // 从栈上读取返回地址
    sp() += 8;           // 栈指针上移（弹出返回地址）
}
```

**原理**：

```
调用 send_allocation_in_new_tlab 前的栈布局：
+------------------+
| 返回地址         |  <- SP 指向这里
+------------------+
| 保存的 RBP       |
+------------------+

frame.ret() 执行后：
pc() = 返回地址      // 设置 PC 指向返回地址
sp() += 8           // SP 上移，指向保存的 RBP

CPU 继续执行时，会从"返回地址"处开始执行
send_allocation_in_new_tlab 的原始代码被"跳过"了！
```

**为什么能工作**？

因为 INT3 断点通常用于调试器。调试器在断点处暂停后，需要：
1. 读取寄存器/内存
2. 恢复执行

`frame.ret()` 就是让函数"正常返回"，跳转到调用者的下一条指令。

#### 步骤 5：记录分配事件

```cpp
void AllocTracer::recordAllocation(void* ucontext, EventType event_type, 
                                   uintptr_t rklass, uintptr_t total_size, 
                                   uintptr_t instance_size) {
    AllocEvent event;
    event._start_time = TSC::ticks();
    event._class_id = 0;
    event._total_size = total_size;
    event._instance_size = instance_size;

    // 从 Klass 获取类名
    if (VMStructs::hasClassNames()) {
        VMSymbol* symbol = VMKlass::fromHandle(rklass)->name();
        event._class_id = Profiler::instance()->classMap()->lookup(
            symbol->body(), symbol->length());
    }

    Profiler::instance()->recordSample(ucontext, total_size, event_type, &event);
}
```

**类名解析流程**：
1. `rklass` 是指向 `Klass` 结构的指针（JVM 内部表示类元数据的 C++ 对象）
2. `VMKlass::fromHandle(rklass)` 转换句柄
3. `->name()` 获取 `Symbol*`（JVM 内部字符串表示）
4. `symbol->body()` 获取字符数组
5. `classMap()->lookup()` 将类名加入映射表，返回 ID

---

## 4. 完整流程图

```
Java 代码执行: new Object()
                    │
                    v
┌─────────────────────────────────────────────────────────────┐
│ JVM 内部: ObjectAllocator::allocate()                       │
│                                                             │
│   1. 检查是否需要触发 AllocationTracer                      │
│   2. 调用 send_allocation_in_new_tlab(klass, obj, ...)     │
│      ↓                                                      │
│   3. 执行到函数入口: INT3 (0xcc) 触发 SIGTRAP               │
│      ↓                                                      │
│   4. OS 调用 trapHandler (信号处理函数)                     │
└─────────────────────────────────────────────────────────────┘
                    │
                    v
┌─────────────────────────────────────────────────────────────┐
│ AllocTracer::trapHandler()                                  │
│                                                             │
│   StackFrame frame(ucontext)     // 提取寄存器上下文         │
│                                                             │
│   if (_in_new_tlab.covers(pc))  // 判断断点类型             │
│       klass = frame.arg0()      // RDI = Klass*            │
│       size = frame.arg2()       // RDX = alloc_size         │
│                                                             │
│   frame.ret()                    // 模拟返回                │
│       pc = stackAt(0)           // 从栈读取返回地址         │
│       sp += 8                   │                          │
│                                                             │
│   recordAllocation(...)          // 记录采样事件            │
│       class_id = lookup(symbol) // 类名解析                │
│       recordSample()             // 写入 Ring Buffer        │
└─────────────────────────────────────────────────────────────┘
                    │
                    v
┌─────────────────────────────────────────────────────────────┐
│ 继续执行: send_allocation_in_new_tlab 返回                  │
│                                                             │
│ (TLAB 分配继续完成，对象正常使用)                            │
└─────────────────────────────────────────────────────────────┘
```

---

## 5. 关键技术点总结

### 5.1 断点 vs Hook

| 方式 | 优点 | 缺点 |
|-----|------|-----|
| **INT3 断点** | 简单，无需修改调用 | 每次触发都有中断开销 |
| **Inline Hook** | 可完全控制执行流 | 复杂，需要复制指令 |
| **PLIC (Patchable Landing Pad)** | 更灵活 | 需要内核支持 |

AsyncProfiler 选择 INT3 是因为：
1. **简单可靠**：操作系统原生支持
2. **采样开销可接受**：只有采样到的分配才触发中断
3. **可恢复**：不影响正常分配流程

### 5.2 为什么"模拟返回"不会丢失数据？

关键在于 `send_allocation_in_new_tlab` 是一个**通知函数**：
- 它的主要目的是触发 AllocationTracer
- **实际的内存分配已经在函数调用前完成**
- 函数本身只是"通知" profiler 有一次分配发生

所以"跳过"函数体不会影响分配结果。

### 5.3 类名解析的安全性

```cpp
VMSymbol* symbol = VMKlass::fromHandle(rklass)->name();
event._class_id = Profiler::instance()->classMap()->lookup(
    symbol->body(), symbol->length());
```

这里直接读取 JVM 内部的 `Klass` 结构。需要：
1. JVM debug symbols（`libjvm.so` 调试符号）
2. 正确的 VMStructs 偏移

这就是为什么 Lesson 2 要验证 `gHotSpotVMStructs` 符号。

---

## 6. GDB 验证对照

| GDB 验证点 | 源码对应 | 说明 |
|-----------|---------|------|
| `0xcc` 在函数入口 | `patch(BREAKPOINT_INS)` | 安装断点 |
| RDI=klass | `frame.arg0()` | x86_64 参数传递 |
| PC=trap_address | `covers(pc)` | 判断断点类型 |
| ret 后 PC=call_next | `frame.ret()` | 模拟返回 |

---

## 7. 下一步学习

- **Lesson 6**: LockTracer（锁竞争采样）
- **Lesson 7**: 性能优化与调参

---

## 8. 参考资料

- `trap.h`: Trap 类定义
- `allocTracer.cpp`: AllocTracer 实现
- `stackFrame_x64.cpp`: x86_64 栈帧操作
- `man 2 sigaction`: 信号处理
- `man 2 ptrace`: 进程跟踪（断点原理）
