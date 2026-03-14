# 44b · JVM 异常处理（进阶篇）— 三个没讲完的故事

> 接上篇 [44-exception-handling-HandWritten.md](./44-exception-handling-HandWritten.md)  
> 基于 OpenJDK 11 源码，`-Xms8g -Xmx8g -XX:+UseG1GC -Xint`

---

## 写在前面

上篇讲完了 JVM 异常处理的主干。但有三个地方我故意跳过了，因为当时讲会打断节奏。

现在来补上。

这三个故事分别是：

1. **TRAPS/CHECK/THROW 宏** — JVM 内部的 C++ 代码是怎么"抛异常"的？
2. **ImplicitExceptionTable** — SIGSEGV 发生后，JVM 怎么知道该跳到哪里？
3. **`forward_exception_entry`** — VM 函数返回后，`_pending_exception` 怎么"回到"解释器？

---

---

## 故事一：TRAPS/CHECK/THROW — JVM 内部的"手动异常传播"

### 先问你一个问题

上篇说了：JVM 不用 C++ 异常，而是用 `_pending_exception` 变量手动传播。

但"手动传播"是什么意思？

想象一下：JVM 内部有几千个 C++ 函数，调用链可能深达几十层。如果最底层的函数设置了 `_pending_exception`，上面几十层函数怎么知道"有异常了，我要立刻返回"？

**难道每个函数都要写这样的代码？**

```cpp
int result = some_function(args);
if (thread->has_pending_exception()) return -1;  // 手动检查
```

**想一想，再往下看。**

---

### 答案：是的，每个函数都要检查——但用宏来简化

JVM 确实在每个可能抛异常的函数调用后都检查 `_pending_exception`。但不是手写，而是用三个宏家族：

**`TRAPS` — "我是一个可能抛异常的函数"**

```cpp
// exceptions.hpp
#define THREAD __the_thread__
#define TRAPS  Thread* THREAD   // 展开为：Thread* __the_thread__
```

每个可能抛异常的函数，最后一个参数必须是 `TRAPS`：

```cpp
// 声明时：
int resolve_field(ConstantPool* pool, int index, TRAPS);

// 展开后实际签名：
int resolve_field(ConstantPool* pool, int index, Thread* __the_thread__);
```

**为什么要传 Thread 指针？** 因为 `Thread::current()` 需要从 TLS 读取，有几十纳秒的开销。JVM 内部调用链很深，如果每个函数都调 `Thread::current()`，累积开销可观。通过参数传递，只需一次 TLS 访问，后续全部用参数——**零额外开销**。

---

**`CHECK` — "调用完就检查，有异常就立刻 return"**

```cpp
#define CHECK       THREAD); if (HAS_PENDING_EXCEPTION) return       ; (void)(0
#define CHECK_0     THREAD); if (HAS_PENDING_EXCEPTION) return 0     ; (void)(0
#define CHECK_NULL  THREAD); if (HAS_PENDING_EXCEPTION) return NULL  ; (void)(0
```

使用时：

```cpp
int result = resolve_field(pool, index, CHECK_0);
```

展开后：

```cpp
int result = resolve_field(pool, index, __the_thread__);
if (__the_thread__->has_pending_exception()) return 0;
(void)(0);
```

**等等，`CHECK_0` 宏里有一个右括号 `)`，这语法不对啊？**

这是一个精妙的宏技巧。调用方写的是：

```cpp
resolve_field(pool, index, CHECK_0)
```

展开后变成：

```cpp
resolve_field(pool, index, __the_thread__); if (...) return 0; (void)(0)
```

`CHECK_0` 的第一个 token 是 `THREAD)`，它和调用方的 `(` 配对，形成完整的函数调用。接着 `;` 结束语句，`if (...)` 是新语句。

**这个技巧让调用方的写法极其自然——看起来就像 `CHECK_0` 是一个普通参数。**

---

**`THROW` — "设置异常 + 立刻 return"**

```cpp
#define THROW_MSG(name, message) \
  { Exceptions::_throw_msg(THREAD_AND_LOCATION, name, message); return; }
```

`Exceptions::_throw_msg()` 做了什么？

```
1. 检查 VM 是否初始化完成
   → 没有 → 直接 fatal exit（VM 还没起来，没法创建 Java 对象）

2. 加载异常类 + 调 Java <init> 构造函数
   → 创建真正的 Java 异常对象

3. 打印日志（如果开了 -Xlog:exceptions=info）

4. thread->set_pending_exception(exception)  ← 核心操作
```

---

### 完整的调用链长什么样？

```
Java: throw new RuntimeException("oops")
    ↓
athrow 字节码
    ↓
throw_exception_entry（解释器 stub）
    ↓
InterpreterRuntime::exception_handler_for_exception(thread, exception)
    ↓
Method::fast_exception_handler_bci_for(method, ex_klass, bci, CHECK_(-1))
    ↓
pool->klass_at(klass_index, CHECK_(handler_bci))  ← 可能触发类加载
    ↓
如果类加载失败：
  THROW_MSG(vmSymbols::java_lang_ClassNotFoundException(), ...)
  → set_pending_exception(ClassNotFoundException)
  → return
    ↓
CHECK_(handler_bci) 检测到 pending_exception → return handler_bci
    ↓
回到 exception_handler_for_exception：
  HAS_PENDING_EXCEPTION = true
  → 用 ClassNotFoundException 替换 RuntimeException
  → 重新查异常表（do-while 循环）
```

**这就是上篇"插曲"里那个 `do-while` 循环的完整原因。**

---

### 一句话总结

TRAPS/CHECK/THROW 宏体系 = **用宏把"手动检查 `_pending_exception`"这件事自动化**。

每个可能抛异常的函数：
- 声明时加 `TRAPS`（接收 Thread 指针）
- 调用后加 `CHECK`（自动检查 + 自动 return）
- 需要抛异常时用 `THROW`（设置 `_pending_exception` + 自动 return）

整个 JVM 内部的异常传播，就靠这三个宏撑起来。

---

---

## 故事二：ImplicitExceptionTable — "SIGSEGV 发生后，跳到哪里？"

### 先回顾一下上篇讲的

上篇说：C2 编译后，`obj.field` 的 null 检查变成了：

```asm
movl eax, [rdi + 12]   ; 直接读，没有 null 检查
```

如果 `rdi == null`，CPU 报 SIGSEGV，JVM 信号处理器接住，创建 NPE，正常分派。

**但我跳过了一个关键问题：信号处理器怎么知道"这个 SIGSEGV 是 null 检查触发的，应该跳到哪里继续执行"？**

---

### 问题的本质

SIGSEGV 发生时，信号处理器知道两件事：
1. **故障地址**（`info->si_addr`）：比如 `0x0C`（null + 12）
2. **故障 PC**（`uc->uc_mcontext.gregs[REG_RIP]`）：比如 `0x7f1234abcd`（那条 `movl` 指令的地址）

信号处理器需要回答：**"这个 PC 对应的 null 检查，应该跳到哪里处理？"**

这个映射关系，就存在 `ImplicitExceptionTable` 里。

---

### ImplicitExceptionTable 的结构

```cpp
// exceptionHandlerTable.hpp:143
class ImplicitExceptionTable {
  uint  _size;    // 已分配容量
  uint  _len;     // 实际条目数
  uint* _data;    // 平铺数组：[exec_off_0, cont_off_0, exec_off_1, cont_off_1, ...]
};
```

每条记录是一对数字：

```
(exec_offset, cont_offset)
    ↑                ↑
SIGSEGV 发生处     应该跳到这里继续
的 PC 偏移         的 PC 偏移
（相对 nmethod 起始地址）
```

**举个例子：**

```
nmethod 起始地址：0x7f1234ab0000

ImplicitExceptionTable:
  (0xcd, 0x1a0)   → 偏移 0xcd 处发生 SIGSEGV → 跳到偏移 0x1a0 处
  (0x1f2, 0x2b0)  → 偏移 0x1f2 处发生 SIGSEGV → 跳到偏移 0x2b0 处
  ...
```

---

### 查找过程

信号处理器调用：

```cpp
// sharedRuntime.cpp:797
address SharedRuntime::continuation_for_implicit_exception(
    JavaThread* thread, address pc, ImplicitExceptionKind exception_kind) {

  if (cb->is_compiled()) {
    CompiledMethod* nm = (CompiledMethod*)cb;
    // 查 ImplicitExceptionTable
    uint cont_offset = nm->continuation_for_implicit_null_check(pc);
    if (cont_offset != 0) {
      return nm->code_begin() + cont_offset;  // 返回跳转目标地址
    }
  }
}
```

`continuation_for_implicit_null_check(pc)` 的实现：

```cpp
// exceptionHandlerTable.cpp:179
uint ImplicitExceptionTable::at(uint exec_off) const {
  for (uint i = 0; i < _len; i++)
    if (*adr(i) == exec_off)          // 线性扫描
      return *(adr(i) + 1);           // 返回 cont_offset
  return 0;  // 未找到
}
```

**为什么用线性扫描？** 和异常表一样：大多数 nmethod 的隐式 null 检查点很少（通常几个到十几个），线性扫描比哈希表更简单、更紧凑。而且这个查找只在 SIGSEGV 发生后才执行——**异常路径，不是热路径**。

---

### 信号处理器修改 PC

找到 `cont_offset` 后，信号处理器做了一件很"魔法"的事：

```cpp
// os_linux_x86.cpp:483
stub = SharedRuntime::continuation_for_implicit_exception(thread, pc, ...);
// ...
os::Linux::ucontext_set_pc(uc, stub);  // 修改 CPU 上下文里的 PC
return 1;  // 信号已处理
```

**修改 CPU 上下文里的 PC！**

当 `sigreturn` 恢复 CPU 上下文时，PC 已经被改成了 handler 的地址。CPU 从 handler 继续执行，就好像什么都没发生过一样。

**整个过程对 Java 代码完全透明——它只知道拿到了一个 NullPointerException。**

---

### 什么时候不能用隐式检查？

```cpp
// assembler.cpp:300
bool MacroAssembler::needs_explicit_null_check(intptr_t offset) {
  return offset < 0 || os::vm_page_size() <= offset;
}
```

- `offset ∈ [0, 4096)` → **不需要**显式检查（null + offset 落在 zero page，一定触发 SIGSEGV）
- `offset >= 4096` → **必须**显式检查（null + 4096 可能越过 zero page，落到合法内存）
- `offset < 0` → **必须**显式检查（null + 负数 = 巨大地址，不在 zero page）

**什么时候 offset >= 4096？**

一个有几百个 int 字段的超大类，后面的字段 offset 可能超过 4096。或者数组的大索引访问：`array[1000]` 的 offset 可以远大于 4096。

这些情况下必须用显式检查：

```asm
; 显式 null 检查（offset >= 4096 时）
testq rdi, rdi          ; 检查 obj 是否为 null
jz    throw_npe         ; 是 null → 跳到 NPE handler
movl  eax, [rdi + 5000] ; 不是 null → 读字段
```

---

### 一句话总结

`ImplicitExceptionTable` = **一张"SIGSEGV 发生在哪里 → 跳到哪里"的映射表**。

C2 编译时，每次选择隐式 null 检查，就往这张表里加一条记录。SIGSEGV 发生后，信号处理器查这张表，找到跳转目标，修改 CPU 的 PC，`sigreturn` 后 CPU 从 handler 继续执行。

---

---

## 故事三：`forward_exception_entry` — "VM 函数返回后，异常去哪了？"

### 先问你一个问题

上篇说了：JVM 用 `_pending_exception` 传播异常。

但有一个场景我没讲：**解释器调用 VM runtime 函数时，如果 VM 函数里设置了 `_pending_exception`，解释器怎么知道？**

解释器调用 VM 函数的代码大概是这样：

```asm
; 解释器调用 VM runtime 函数
call  InterpreterRuntime::some_function
; 函数返回后，解释器继续执行下一条字节码
; ...但如果 some_function 里设置了 _pending_exception 怎么办？
```

**想一想，再往下看。**

---

### 答案：`call_VM` 宏 + `forward_exception_entry`

解释器不是直接 `call` VM 函数，而是通过 `call_VM` 汇编宏。这个宏在 VM 函数返回后，**自动检查 `_pending_exception`**：

```asm
; call_VM 宏展开后（简化版）
call  InterpreterRuntime::some_function

; ★ 关键：VM 函数返回后立刻检查
cmpptr [r15 + pending_exception_offset], NULL  ; r15 = 当前线程
jne   forward_exception_entry                  ; 有异常 → 跳到转发入口
; 没有异常 → 继续正常执行
```

**`r15 + 8` 就是 `_pending_exception` 的地址。** 这就是上篇讲的"空虚函数固定偏移"的用武之地——汇编代码硬编码了偏移 `8`。

---

### `forward_exception_entry` 做了什么？

```
forward_exception_entry:
  1. 从栈取出 return_address（VM 函数调用前压栈的返回地址）
  2. 调用 SharedRuntime::exception_handler_for_return_address(thread, return_address)
     → 根据 return_address 判断调用者类型
     → 返回对应的异常处理入口地址
  3. 取出 _pending_exception → rax（异常对象）
  4. 清空 _pending_exception
  5. jmp 找到的 handler 入口
```

**`exception_handler_for_return_address` 根据 return_address 分发：**

| return_address 所在区域 | 返回的 handler | 场景 |
|------------------------|---------------|------|
| **解释器** | `Interpreter::rethrow_exception_entry()` | 调用者是解释器帧 → 回到解释器重新处理 |
| **nmethod**（编译代码） | `nm->exception_begin()` | 调用者是编译帧 → 走编译代码异常处理 |
| **nmethod** 的 deopt PC | `deopt_blob->unpack_with_exception()` | 调用者已被反优化 → 走反优化路径 |
| **call_stub** | `StubRoutines::catch_exception_entry()` | 到达 JNI 边界 → 传回 native 层 |

---

### 为什么需要这个"转发"机制？

**因为 VM 函数不知道自己的调用者是谁。**

VM 函数（比如 `InterpreterRuntime::exception_handler_for_exception`）可能被解释器调用，也可能被编译代码调用。它只知道"我设置了 `_pending_exception`，然后 return"。

`forward_exception_entry` 是一个**通用的转发器**：它根据 return_address 判断调用者类型，然后把异常"转发"到正确的处理入口。

**这就是"解耦"的体现：VM 函数不需要知道调用者是谁，只需要设置 `_pending_exception`，剩下的交给 `forward_exception_entry`。**

---

### 完整的流程图

```
解释器执行字节码
    ↓
遇到需要 VM 帮助的操作（比如类加载、方法解析）
    ↓
call_VM(InterpreterRuntime::some_function)
    ↓
VM 函数执行
    ├── 正常完成 → return
    └── 出错 → THROW_MSG(...) → set_pending_exception → return
    ↓
call_VM 宏检查 _pending_exception
    ├── 为 null → 继续执行下一条字节码
    └── 不为 null → jmp forward_exception_entry
                        ↓
                    取出 return_address
                        ↓
                    exception_handler_for_return_address
                        ↓
                    ┌── 解释器调用者 → rethrow_exception_entry
                    ├── 编译代码调用者 → nm->exception_begin()
                    └── JNI 边界 → catch_exception_entry
```

---

### 一句话总结

`forward_exception_entry` = **VM 函数和调用者之间的"异常转发器"**。

VM 函数只管设置 `_pending_exception`，`forward_exception_entry` 负责根据调用者类型，把异常"转发"到正确的处理入口。

---

---

## 三个故事的关系

现在把三个故事串起来：

```
Java 代码抛异常
    ↓
athrow → throw_exception_entry
    ↓
InterpreterRuntime::exception_handler_for_exception(TRAPS)
    ↓
Method::fast_exception_handler_bci_for(method, ex_klass, bci, CHECK_(-1))
    ↓
pool->klass_at(klass_index, CHECK_(handler_bci))
    ↓
如果类加载失败：
  THROW_MSG → set_pending_exception → return  ← 故事一：TRAPS/CHECK/THROW
    ↓
CHECK_(handler_bci) 检测到 pending_exception → return handler_bci
    ↓
回到 exception_handler_for_exception：do-while 重新查找
    ↓
找到 handler → 跳过去 ✅

---

C2 编译代码执行 obj.field（obj=null）
    ↓
movl eax, [rdi + 12]（rdi=0）
    ↓
CPU: SIGSEGV（地址 0x0C）
    ↓
JVM 信号处理器：查 ImplicitExceptionTable  ← 故事二：ImplicitExceptionTable
    ↓
找到 cont_offset → 修改 CPU 的 PC
    ↓
sigreturn → CPU 从 throw_NPE_entry 继续执行
    ↓
创建 NPE → 正常异常分派 ✅

---

解释器调用 VM 函数（比如类加载）
    ↓
VM 函数内部：THROW_MSG → set_pending_exception → return
    ↓
call_VM 宏检测到 _pending_exception
    ↓
jmp forward_exception_entry  ← 故事三：forward_exception_entry
    ↓
根据 return_address 找到正确的异常处理入口
    ↓
跳过去 ✅
```

---

## 数据结构速查（补充）

| 结构 | 大小 | 用途 | 在哪里 |
|------|------|------|--------|
| `ImplicitExceptionTable` | 每条记录 8B（两个 uint） | 隐式 null 检查的 SIGSEGV → 跳转目标映射 | nmethod 内 |
| `TRAPS` 宏 | 0B（编译期展开） | 传递 Thread 指针，避免重复 TLS 访问 | 函数参数 |
| `CHECK` 宏 | 0B（编译期展开） | 自动检查 `_pending_exception` + return | 函数调用后 |
| `forward_exception_entry` | 一段汇编代码 | VM 函数返回后的异常转发器 | StubRoutines |

---

## 还没搞懂的地方（留给下次）

1. `rethrow_exception_entry` 和 `throw_exception_entry` 的区别是什么？（上篇也留了这个问题）
2. `@ReservedStackAccess` 的完整实现：JVM 怎么检测到当前在执行这个注解的方法？
3. C1 和 C2 的异常处理路径有什么不同？C1 的"简化异常表"（`bci=-1, scope_depth=0`）具体是怎么工作的？
4. `ExceptionMark` 是什么？它在 debug 模式下怎么断言"没有未处理的异常"？

---

## 深入阅读

如果你想看完整的源码分析（包含所有字段、sizeof、GDB 验证），看这里：

- **[完整源码分析](../ExceptionHandling/1-Exception-Handling-Deep-Dive.md)** — 所有数据结构的完整字段分析、算法流程的真实源码+逐行注释
- **[GDB 验证](../ExceptionHandling/2-Exception-Handling-GDB-Verification.md)** — 用 GDB 实际验证 ThreadShadow 偏移、栈保护区布局、异常表内容

---

*写于 2026-03-06*
