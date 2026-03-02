# 5.3 walkFP — Frame Pointer 栈回溯

> 源文件: `stackWalker.cpp::walkFP` (第 66~112 行), `stackFrame_x64.cpp` (平台实现)
> 关联: `arch.h` (平台常量), `safeAccess.cpp` (安全内存读取), `stackFrame.h` (StackFrame 类)
> 前置章节: 5.1 recordSample 总入口, 5.2 ASGCT 详解

## 核心问题

**Frame Pointer (FP) 栈回溯是最古老、最简单的栈遍历方式。它是怎么工作的？为什么「一个指针就能追踪整个调用栈」？为什么现代编译器默认关闭 FP，以及这对 async-profiler 有什么影响？**

---

## 一、FP 栈回溯的原理

### 1.1 x86_64 调用约定与 FP 链

在 x86_64 上，每次函数调用会在栈上留下一个 **标准帧结构**（Standard Frame Layout）：

```
高地址（栈底方向）
┌──────────────────────────────┐
│         caller's locals      │
│         ...                  │
├──────────────────────────────┤ ← caller's SP (= current FP + 16)
│ return address (8 bytes)     │  [FP + 8]   ← FRAME_PC_SLOT = 1
├──────────────────────────────┤
│ saved FP (8 bytes)           │  [FP + 0]   ← 指向上一帧的 FP
├──────────────────────────────┤ ← current FP (= RBP)
│ current frame locals         │
│ ...                          │
├──────────────────────────────┤ ← current SP (= RSP)
低地址（栈顶方向）
```

**FP 链** 就是一条单向链表：每个帧的 FP 位置存着上一帧的 FP 地址，FP+8 存着返回地址。沿着这条链一直往上走，就能还原整个调用栈。

### 1.2 walkFP 的核心循环

```
walkFP(ucontext, callchain, max_depth, java_ctx)
  │
  ├── 从 ucontext 提取初始 PC/FP/SP
  │     pc = ucontext->rip
  │     fp = ucontext->rbp
  │     sp = ucontext->rsp
  │
  └── while (depth < max_depth):
        │
        ├── 1. CodeHeap::contains(pc)?
        │     ├── Yes → 找到 Java 帧！
        │     │   java_ctx->set(pc, sp, fp)
        │     │   break  ← 停止原生栈回溯
        │     └── No → 继续
        │
        ├── 2. callchain[depth++] = pc  ← 记录当前 PC
        │
        ├── 3. 安全检查:
        │     ├── fp < sp? → break（FP 不能在 SP 之下）
        │     ├── fp >= sp + 256KB? → break（帧太大）
        │     ├── fp >= bottom? → break（超出栈范围）
        │     └── !aligned(fp)? → break（FP 必须 8 字节对齐）
        │
        ├── 4. 读取返回地址（安全读）:
        │     pc = SafeAccess::load((void**)fp + 1)
        │     ├── 成功 → 得到返回地址
        │     └── SEGV → 返回 NULL → inDeadZone(NULL) = true → break
        │
        ├── 5. inDeadZone(pc)? → break（PC 在 NULL 或 -1 附近）
        │
        └── 6. 帧推进:
              sp = fp + 16          ← 新 SP = 旧 FP + 16
              fp = *(uintptr_t*)fp  ← 沿 FP 链向上一帧
```

### GDB 验证 — 初始状态

```
=== walkFP entry ===
After init:
  pc     = 0x7ffff6205356  (libjvm.so 中 — 信号中断了 JVM C++ 代码)
  fp     = 0x7ffff7808420
  sp     = 0x7ffff78083f0
  bottom = 0x7ffff7907898  (sp + 1MB)

  fp - sp = 48 bytes (当前帧大小: 合理)
  fp aligned: true

→ walkFP 返回 19 帧（原生 C/C++ 帧）
→ java_ctx.pc = 0x7fffec81ec61 (CodeHeap 中的 Interpreter 入口)
```

---

## 二、5 种终止条件详解

walkFP 必须在**各种异常情况下安全终止**，不能崩溃：

### 2.1 条件 1: CodeHeap::contains(pc) — 遇到 Java 帧

```cpp
if (CodeHeap::contains(pc) && !(depth == 0 && frame.unwindAtomicStub(pc))) {
    java_ctx->set(pc, sp, fp);
    break;
}
```

**这是最重要的终止条件**：当 FP 链追踪到一个 PC 落在 JVM CodeHeap（存放解释器、JIT 代码、Stub 的内存区域）中时，说明已经到达了 Java 帧的边界。此时：

1. 把当前 `(pc, sp, fp)` 保存到 `java_ctx`
2. 停止 walkFP
3. 后续由 `getJavaTraceAsync()` 使用 `java_ctx` 作为提示，从这个位置开始 ASGCT

**`unwindAtomicStub` 的例外**：如果是栈顶第一帧（depth==0）且 PC 指向原子操作 Stub（如 `Unsafe.compareAndSwap` 的 native 实现），不算作 Java 帧——因为 Atomic Stub 虽然在 CodeHeap 中，但它本质是原生代码。在 x86_64 上 `unwindAtomicStub` 始终返回 false（不需要特殊处理）。

### 2.2 条件 2: FP 范围检查

```cpp
if (fp < sp || fp >= sp + MAX_FRAME_SIZE || fp >= bottom) {
    break;
}
```

| 检查 | 阈值 | 原因 |
|------|------|------|
| `fp < sp` | — | FP 不能在当前 SP 之下（帧必须在栈上往上生长） |
| `fp >= sp + 256KB` | `MAX_FRAME_SIZE = 0x40000` | 单个帧不可能这么大 |
| `fp >= bottom` | `sp + 1MB` | 超出安全遍历范围（防止越界到其他线程的栈） |

### 2.3 条件 3: 对齐检查

```cpp
if (!aligned(fp)) {
    break;
}
```

x86_64 上指针必须 8 字节对齐。如果 FP 不对齐，说明 FP 链已经被破坏。

### 2.4 条件 4: SafeAccess + inDeadZone

```cpp
pc = stripPointer(SafeAccess::load((void**)fp + FRAME_PC_SLOT));
if (inDeadZone(pc)) {
    break;
}
```

**SafeAccess::load**：一个自定义的"安全内存读取"函数。普通的 `*(ptr)` 如果 ptr 无效会触发 SEGV 导致进程崩溃。`SafeAccess::load` 的实现用内联汇编确保：如果 SEGV 发生在这条 `mov` 指令上，SEGV 处理器会跳过该指令并返回默认值（NULL）。

```cpp
// safeAccess.cpp — x86_64 实现
NOINLINE void* SafeAccess::load(void** ptr, void* default_value) {
    void* ret;
    asm volatile("mov (%1), %0" : "=a"(ret) : "r"(ptr), "S"(default_value));
    LABEL(load_end);  // 标记指令边界
    return ret;
}
```

SEGV 处理器通过检查 PC 是否在 `load ~ load_end` 范围内来判断是否是 SafeAccess 触发的错误，如果是则跳过 `mov` 指令并将 `default_value` 写入返回值。

**inDeadZone**：检查指针是否在 `[0, 0x1000)` 或 `(-0x1000, -1]` 范围内（NULL 页或最高地址页附近），这些地址一定是无效的。

### 2.5 条件 5: max_depth

```cpp
while (depth < max_depth) {
```

`max_depth = MAX_NATIVE_FRAMES = 128`，防止无限循环。

---

## 三、FRAME_PC_SLOT — 返回地址的位置

### 3.1 平台差异

```cpp
// arch.h
const int FRAME_PC_SLOT = 1;  // x86_64, AArch64, RISC-V, LoongArch
const int FRAME_PC_SLOT = 2;  // PPC64LE
```

| 平台 | FRAME_PC_SLOT | 返回地址位置 | 原因 |
|------|:------------:|------------|------|
| x86_64 | 1 | FP + 8 | `call` 指令把返回地址 push 到栈上，然后 `push rbp` |
| AArch64 | 1 | FP + 8 | STP x29, x30, [sp, #-16]! 保存 FP+LR |
| PPC64LE | 2 | FP + 16 | ABI 要求 LR 保存在 FP+16（FP+8 是 CR 保存区）|

### 3.2 在 walkFP 中的使用

```cpp
// 读取返回地址
pc = SafeAccess::load((void**)fp + FRAME_PC_SLOT);  // fp + 1*8 = fp + 8

// 计算新 SP
sp = fp + (FRAME_PC_SLOT + 1) * sizeof(void*);       // fp + 2*8 = fp + 16
```

---

## 四、StackFrame 类 — ucontext 的抽象

### 4.1 寄存器映射

```cpp
// stackFrame_x64.cpp
uintptr_t& StackFrame::pc() { return (uintptr_t&)_ucontext->uc_mcontext.gregs[REG_RIP]; }
uintptr_t& StackFrame::sp() { return (uintptr_t&)_ucontext->uc_mcontext.gregs[REG_RSP]; }
uintptr_t& StackFrame::fp() { return (uintptr_t&)_ucontext->uc_mcontext.gregs[REG_RBP]; }
```

**返回引用**：`pc()` 返回 `uintptr_t&`，这意味着可以**直接修改** ucontext 中的 PC/SP/FP。这在 ASGCT 恢复机制中被大量使用（修改 ucontext 然后重试 ASGCT）。

### 4.2 其他寄存器

| 方法 | 寄存器 | 用途 |
|------|--------|------|
| `arg0()` | RDI | 第一个 C 参数 |
| `arg1()` | RSI | 第二个 C 参数 |
| `jarg0()` | RSI | 第一个 Java 参数（= C 的第二个参数，因为 RDI 是 JNIEnv*）|
| `method()` | RBX | HotSpot 解释器用 RBX 保存当前 Method* |
| `senderSP()` | R13 | HotSpot 解释器用 R13 保存 sender SP |
| `retval()` | RAX | 函数返回值 |
| `link()` | 0 | x86 没有链接寄存器（AArch64 用 LR=x30）|

### 4.3 callerPC/callerFP/callerSP — 无 ucontext 时的回退

```cpp
#define callerPC()  __builtin_return_address(0)       // 获取调用者的返回地址
#define callerFP()  __builtin_frame_address(1)        // 获取调用者的 FP
#define callerSP()  ((void**)__builtin_frame_address(0) + 2)  // 当前 FP + 16 = 调用者 SP
```

当 `ucontext == NULL` 时（例如 malloc hook 中没有信号上下文），walkFP 使用 GCC 内置函数从当前栈帧获取起始点。

---

## 五、walkFP 与 Java 栈的协作

### 5.1 工作模型

walkFP **只负责原生栈**（C/C++ 帧），遇到 Java 帧就停止。Java 帧由单独的机制处理：

```
信号处理器
  │
  ├── getNativeTrace()
  │     └── walkFP(ucontext, callchain, 128, &java_ctx)
  │           ├── 追踪 FP 链 → 收集 C/C++ 帧的 PC
  │           └── 遇到 CodeHeap PC → 保存到 java_ctx → break
  │
  └── getJavaTraceAsync(ucontext, frames, 2048, &java_ctx)
        ├── 如果 java_ctx.sp != 0 且线程在 Java 中
        │     → frame.restore(java_ctx.pc, java_ctx.sp, java_ctx.fp)
        │     → 从 java_ctx 位置开始 ASGCT（更可靠）
        │
        └── VM::_asyncGetCallTrace(&trace, max_depth, ucontext)
              → 返回 Java 帧
```

### 5.2 为什么要传递 java_ctx？

ASGCT 默认从 ucontext（信号中断点）开始遍历。但如果信号中断了 JVM 内部的 C++ 代码（很常见），ucontext 中的 PC/SP/FP 不在 Java 帧上，ASGCT 需要先穿过所有 C++ 帧才能到达 Java 帧——这个过程容易失败。

**walkFP 提供了捷径**：它已经沿着 FP 链走到了 Java 帧的边界（`java_ctx.pc` 在 CodeHeap 中），这个位置一定是一个有效的 Java 帧。从这里开始 ASGCT，成功率显著提高。

### GDB 验证 — java_ctx 的设置

```
walkFP 返回后:
  java_ctx.pc = 0x7fffec81ec61  ← CodeHeap 中的解释器代码
  java_ctx.sp = 0x7ffff7808c30
  java_ctx.fp = 0x7ffff7808c90

→ getJavaTraceAsync 使用 java_ctx 作为 ASGCT 的起始点
→ ASGCT 从安全的 Java 帧开始，返回 17 帧 ✅
```

---

## 六、walkFP 的局限性 — -fomit-frame-pointer 问题

### 6.1 问题

现代编译器（GCC/Clang -O2 及以上）默认启用 `-fomit-frame-pointer`，将 RBP 释放为通用寄存器：

```
未优化 (-O0, -fno-omit-frame-pointer):    优化 (-O2, -fomit-frame-pointer):
  push rbp                                   (无 push rbp)
  mov rbp, rsp                               (RBP 被用作普通寄存器)
  sub rsp, 0x30                              sub rsp, 0x30
  ...                                        ...
  leave                                      add rsp, 0x30
  ret                                        ret
```

没有 FP 链 → walkFP **无法追踪**。FP 看起来是个随机值（上一帧的 RBP 没有被保存），walkFP 会在范围检查或对齐检查时终止。

### 6.2 在 JVM 中的影响

| 代码区域 | FP 可用? | 原因 |
|---------|---------|------|
| libjvm.so (debug 构建) | ✅ | slowdebug 默认 -O0 |
| libjvm.so (release 构建) | ❌ | -O2 -fomit-frame-pointer |
| 解释器代码 | ✅ | 解释器总是维护 FP（RBP 是 interpreter FP） |
| JIT 编译代码 | ✅ | HotSpot JIT 总是在帧中保存 RBP |
| libc / libpthread | ❌ | 通常 -O2 编译 |
| 应用的 JNI 库 | ❓ | 取决于编译选项 |

**结论**：在 release JVM 上，walkFP 可能在进入 libjvm.so 内部后就断链了，只能采到很浅的原生栈。这就是为什么 async-profiler 提供了 `--cstack dwarf` 选项——DWARF unwind 不依赖 FP。

### 6.3 三种 cstack 模式对比

| | walkFP (--cstack fp) | walkDwarf (--cstack dwarf) | walkVM (--cstack vm, 默认) |
|---|---|---|---|
| **依赖** | FP 链 | .eh_frame 段 | VMStructs 偏移量 |
| **速度** | 最快 | 中等 | 最快 |
| **原生帧完整度** | 低（-O2 断链）| 高 | 混合 |
| **Java 帧** | 需要 ASGCT | 需要 ASGCT | 内置 |
| **信号安全** | ✅ | ✅ | ✅ |
| **崩溃风险** | 低 | 低 | 有 setjmp 保护 |
| **适用场景** | debug 构建 | 需要完整原生栈 | 通用（默认） |

---

## 七、SafeAccess 机制详解

### 7.1 问题

walkFP 在信号处理器中运行，读取的 FP 可能指向无效内存（帧被破坏、线程正在退出等）。直接解引用会导致 SEGV → 进程崩溃。

### 7.2 解决方案

```cpp
// safeAccess.cpp (x86_64)
NOINLINE void* SafeAccess::load(void** ptr, void* default_value) {
    void* ret;
    asm volatile("mov (%1), %0" : "=a"(ret) : "r"(ptr), "S"(default_value));
    LABEL(load_end);
    return ret;
}
```

关键设计：
1. **内联汇编**确保 `mov` 指令是**一条独立指令**，可以精确定位
2. **`LABEL(load_end)`** 在 `mov` 后放一个全局标签
3. **SEGV 处理器**检查 `faulting PC ∈ [load, load_end)`
4. 如果匹配，跳过 `mov`，返回 `default_value`（通过 RSI 传入）

```
正常路径:
  mov (%rdi), %rax    ← 读取成功
  load_end:
  ret                 → 返回 %rax

SEGV 路径:
  mov (%rdi), %rax    ← SEGV！
  → SEGV handler:
    pc 在 [load, load_end) 中 → 是 SafeAccess 触发的
    pc += 3 (跳过 mov 指令)
    rax = rsi (= default_value)
    return from signal handler
  load_end:
  ret                 → 返回 default_value
```

### 7.3 checkFault — SEGV 恢复

```cpp
bool SafeAccess::checkFault(StackFrame& frame) {
    instruction_t* pc = (instruction_t*)frame.pc();
    // 检查是否在 SafeAccess::load 或 load32 的范围内
    if (!(pc >= (void*)load && pc < load_end) &&
        !(pc >= (void*)load32 && pc < load32_end)) {
        return false;
    }
    // 跳过 mov 指令（2 或 3 字节）
    frame.pc() += pc[0] == 0x8b ? 2 : 3;
    // 把 default_value (RSI) 写入 RAX
    frame.retval() = frame.arg1();
    return true;
}
```

---

## 八、stripPointer — ARM64 PAC 支持

```cpp
// arch.h
#ifdef __aarch64__
const unsigned long PAC_MASK = WX_MEMORY ? 0x7fffffffffffUL : 0xffffffffffffUL;
static inline const void* stripPointer(const void* p) {
    return (const void*) ((unsigned long)p & PAC_MASK);
}
#else
#  define stripPointer(p)  (p)  // x86_64: no-op
#endif
```

ARM64 的 **Pointer Authentication Code (PAC)** 会在指针的高位嵌入签名。在遍历栈时，返回地址可能带有 PAC 签名，必须用 `stripPointer` 清除高位才能得到真实的 PC 地址。

在 x86_64 上 `stripPointer` 是一个 no-op（空操作）。

---

## 九、常量总览

| 常量 | 值 | 含义 |
|------|------|------|
| `MAX_WALK_SIZE` | 0x100000 (1MB) | 栈遍历的最大距离 |
| `MAX_FRAME_SIZE` | 0x40000 (256KB) | 单帧最大大小 |
| `DEAD_ZONE` | 0x1000 (4KB) | NULL 页范围 |
| `MAX_NATIVE_FRAMES` | 128 | 最大原生帧数 |
| `FRAME_PC_SLOT` | 1 (x86_64) | 返回地址相对 FP 的 slot 偏移 |
| `EMPTY_FRAME_SIZE` | 8 (x86_64) | 空帧的最小大小（ret addr）|

---

## 十、walkFP vs -fomit-frame-pointer 的深层原因

### 10.1 为什么编译器要省掉 FP？

```
保留 FP 的代价:
  push rbp       ← 1 条指令（保存）
  mov rbp, rsp   ← 1 条指令（建立帧）
  ...
  pop rbp        ← 1 条指令（恢复）

= 每个函数调用 3 条额外指令 + 占用 1 个通用寄存器(RBP)
```

在 x86_64 上只有 16 个通用寄存器，少一个 RBP 意味着编译器需要更多的 spill/reload（把寄存器值暂存到栈上），对性能敏感的代码影响可达 1-2%。

### 10.2 async-profiler 的应对策略

async-profiler 的 **默认模式是 `--cstack vm`**，根本不使用 walkFP！walkFP 只在用户显式指定 `--cstack fp` 时使用。

默认的 walkVM 模式使用 VMStructs 偏移量 + DWARF unwind 信息来遍历栈，不依赖 FP 链。这是 async-profiler 比其他 profiler（如 perf）的优势之一——perf 的 `PERF_SAMPLE_CALLCHAIN` 也依赖 FP。

---

## 十一、总结

### walkFP 的核心设计

```
  信号中断
    │
    └── ucontext → PC/FP/SP
          │
          ├── FP 链循环：
          │   ┌──────────────────────────┐
          │   │ 1. PC 在 CodeHeap?       │
          │   │    → 保存 java_ctx, break │
          │   │                          │
          │   │ 2. 记录 PC               │
          │   │                          │
          │   │ 3. 检查 FP 范围          │
          │   │                          │
          │   │ 4. SafeAccess 读返回地址 │
          │   │                          │
          │   │ 5. 帧推进:              │
          │   │    pc = *(FP+8)          │
          │   │    sp = FP + 16          │
          │   │    fp = *FP              │
          │   └──────────────────────────┘
          │
          └── 原生帧 → convertNativeTrace
              Java 帧 → getJavaTraceAsync(java_ctx)
```

### 设计精髓

1. **极简算法**：核心循环只有 ~30 行代码，3 个指针运算
2. **5 层安全网**：CodeHeap 检测 → FP 范围检查 → 对齐检查 → SafeAccess → inDeadZone
3. **不修改任何全局状态**：纯读取，信号安全
4. **输出 java_ctx 作为 ASGCT 的提示**：大幅提高 ASGCT 成功率
5. **平台适配**：通过 FRAME_PC_SLOT 和 stripPointer 适配不同架构

### GDB 验证关键数据

| 验证项 | 实际值 | 含义 |
|--------|--------|------|
| _cstack | 2 (CSTACK_FP) | --cstack fp 模式 |
| max_depth | 128 | MAX_NATIVE_FRAMES |
| 初始 PC | 0x7ffff6205356 | libjvm.so 中的 C++ 代码 |
| 初始 FP | 0x7ffff7808420 | 信号帧的 RBP |
| 初始 SP | 0x7ffff78083f0 | 信号帧的 RSP |
| fp - sp | 48 bytes | 当前帧大小（合理） |
| bottom | sp + 1MB | 安全遍历上界 |
| walkFP 返回 | 19 / 37 / 6 帧 | 不同采样点深度不同 |
| java_ctx.pc | 0x7fffec81ec61 | CodeHeap 中的解释器入口 |

### 在整体架构中的位置

```
Agent 加载（Ch01）
  → VMStructs 初始化（Ch02）
  → Engine 体系 + selectEngine（Ch03）
  → perf_event_open + 信号驱动（Ch04）
  → recordSample 总入口（Ch05.1）
    → ASGCT 详解（Ch05.2）
    → walkFP（本节）                    ← 你在这里
    → walkDwarf（Ch05.4）
    → walkVM（Ch05.5）
```

---

*创建日期: 2026-02-09*
*GDB 验证环境: OpenJDK 11 slowdebug + async-profiler v4.0*
*验证模式: --cstack fp + --event ctimer*
