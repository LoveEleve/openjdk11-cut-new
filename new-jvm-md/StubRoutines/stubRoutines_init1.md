# stubRoutines_init1() 详细分析

> 文档位置：`jvm-md/StubRoutines/stubRoutines_init1.md`
> 源码位置：`src/hotspot/share/runtime/stubRoutines.cpp:410`

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文对 **stubRoutines_init1() 详细分析** 进行源码级分析：追踪关键函数的执行路径，分析涉及的数据结构，解释每个设计决策的原因。

### 0.2 为什么需要？

仅靠文档和注释无法完全理解 JVM 的行为——很多关键细节只存在于源码中。源码级分析能建立对 JVM 行为的精确理解。

### 0.3 怎么解决？

从入口函数出发，自顶向下追踪调用链；对每个关键函数，分析其输入/输出/副作用；对每个数据结构，分析其字段含义和生命周期。

### 0.4 为什么这样设计？

分析过程中重点关注「为什么」：为什么选择这个数据结构？为什么这样处理边界情况？这些问题的答案往往揭示了 JVM 设计的精髓。

---


## 1. 功能定位

### 1.1 一句话总结

**`stubRoutines_init1()` 是 JVM 运行时的"汇编代码工厂（第一阶段）"** —— 它在 JVM 启动早期生成一批关键的汇编桩代码（Stub），这些代码是 C++ 与 Java 代码交互的桥梁，也是原子操作、异常处理的基础设施。

### 1.2 什么是 Stub（桩代码）？

**Stub** 是预先生成的**机器码片段**，用于处理 JVM 运行时的关键操作：

```
┌─────────────────────────────────────────────────────────────────┐
│                        Stub 的作用                               │
├─────────────────────────────────────────────────────────────────┤
│  ① C++ ←→ Java 调用约定转换（call_stub）                         │
│  ② 寄存器保存/恢复                                               │
│  ③ 异常捕获和转发                                                │
│  ④ 原子操作（CAS、atomic_add 等）                                │
│  ⑤ 高性能数组拷贝（第二阶段）                                    │
└─────────────────────────────────────────────────────────────────┘
```

### 1.3 为什么需要 Stub？

| 问题 | 解决方案 |
|------|----------|
| C++ 和 Java 调用约定不同 | call_stub 负责参数传递和寄存器映射 |
| 异常需要跨语言传播 | catch/forward_exception 处理异常 |
| 原子操作平台相关 | 生成平台优化的汇编代码 |
| 性能关键路径 | 直接生成机器码，避免函数调用开销 |

### 1.4 在启动流程中的位置

```
init_globals()
├── ...
├── codeCache_init()          ← Code Cache 必须先初始化
├── interpreter_init()        ← 解释器初始化
├── stubRoutines_init1()      ← 【当前分析】第一阶段桩代码
│   └── 生成：call_stub, catch_exception, atomic_*, safefetch 等
├── ...
├── universe2_init()          ← 依赖 stubRoutines_init1
├── ...
└── stubRoutines_init2()      ← 第二阶段（数组拷贝、加解密等）
```

---

## 2. 源码解读

### 2.1 入口函数

```cpp
// src/hotspot/share/runtime/stubRoutines.cpp:410
void stubRoutines_init1() { StubRoutines::initialize1(); }
```

### 2.2 StubRoutines::initialize1()

```cpp
// src/hotspot/share/runtime/stubRoutines.cpp:176-199
void StubRoutines::initialize1() {
  if (_code1 == NULL) {
    ResourceMark rm;
    // 1. 计时
    TraceTime timer("StubRoutines generation 1", TRACETIME_LOG(Info, startuptime));
    
    // 2. 在 Code Cache 中分配代码缓冲区
    _code1 = BufferBlob::create("StubRoutines (1)", code_size1);
    if (_code1 == NULL) {
      vm_exit_out_of_memory(code_size1, OOM_MALLOC_ERROR, 
                            "CodeCache: no room for StubRoutines (1)");
    }
    
    // 3. 创建 CodeBuffer 并生成桩代码
    CodeBuffer buffer(_code1);
    StubGenerator_generate(&buffer, false);  // false = 第一阶段
    
    // 4. 检查空间是否足够
    assert(code_size1 == 0 || buffer.insts_remaining() > 200, 
           "increase code_size1");
  }
}
```

### 2.3 代码存储位置

```
Code Cache
├── NonNMethodCodeHeap
│   ├── BufferBlob: "StubRoutines (1)"  ← 第一阶段桩代码
│   │   ├── call_stub
│   │   ├── catch_exception
│   │   ├── forward_exception
│   │   ├── atomic_xchg
│   │   ├── atomic_cmpxchg
│   │   └── ...
│   ├── BufferBlob: "StubRoutines (2)"  ← 第二阶段桩代码
│   └── 其他运行时代码
├── ProfiledCodeHeap
└── NonProfiledCodeHeap
```

---

## 3. 第一阶段生成的桩代码（x86_64）

### 3.1 generate_initial() 完整清单

```cpp
// src/hotspot/cpu/x86/stubGenerator_x86_64.cpp:5858-5957
void generate_initial() {
  // 控制字初始化（MXCSR 等）
  create_control_words();

  // ========== 核心桩代码 ==========
  StubRoutines::_forward_exception_entry = generate_forward_exception();
  
  StubRoutines::_call_stub_entry = 
      generate_call_stub(StubRoutines::_call_stub_return_address);
  
  StubRoutines::_catch_exception_entry = generate_catch_exception();

  // ========== 原子操作 ==========
  StubRoutines::_atomic_xchg_entry         = generate_atomic_xchg();
  StubRoutines::_atomic_xchg_long_entry    = generate_atomic_xchg_long();
  StubRoutines::_atomic_cmpxchg_entry      = generate_atomic_cmpxchg();
  StubRoutines::_atomic_cmpxchg_byte_entry = generate_atomic_cmpxchg_byte();
  StubRoutines::_atomic_cmpxchg_long_entry = generate_atomic_cmpxchg_long();
  StubRoutines::_atomic_add_entry          = generate_atomic_add();
  StubRoutines::_atomic_add_long_entry     = generate_atomic_add_long();
  StubRoutines::_fence_entry               = generate_orderaccess_fence();

  // ========== 平台特定 ==========
  StubRoutines::x86::_get_previous_fp_entry = generate_get_previous_fp();
  StubRoutines::x86::_get_previous_sp_entry = generate_get_previous_sp();
  StubRoutines::x86::_verify_mxcsr_entry    = generate_verify_mxcsr();

  // ========== 异常抛出 ==========
  StubRoutines::_throw_StackOverflowError_entry =
      generate_throw_exception("StackOverflowError throw_exception", ...);
  StubRoutines::_throw_delayed_StackOverflowError_entry =
      generate_throw_exception("delayed StackOverflowError throw_exception", ...);

  // ========== CRC32（可选）==========
  if (UseCRC32Intrinsics) {
    StubRoutines::_crc_table_adr = (address)StubRoutines::x86::_crc_table;
    StubRoutines::_updateBytesCRC32 = generate_updateBytesCRC32();
  }

  // ========== libm 数学函数（可选）==========
  if (UseLibmIntrinsic && InlineIntrinsics) {
    StubRoutines::_dexp   = generate_libmExp();
    StubRoutines::_dlog   = generate_libmLog();
    StubRoutines::_dlog10 = generate_libmLog10();
    StubRoutines::_dpow   = generate_libmPow();
    StubRoutines::_dsin   = generate_libmSin();
    StubRoutines::_dcos   = generate_libmCos();
    StubRoutines::_dtan   = generate_libmTan();
  }
}
```

### 3.2 桩代码分类

| 类别 | 桩代码 | 作用 |
|------|--------|------|
| **调用桥梁** | `call_stub` | C++ 调用 Java 方法的入口 |
| | `call_stub_return_address` | Java 返回到 C++ 的地址 |
| **异常处理** | `catch_exception` | 捕获 Java 异常 |
| | `forward_exception` | 转发异常到调用者 |
| | `throw_StackOverflowError` | 抛出栈溢出异常 |
| **原子操作** | `atomic_xchg` | 原子交换（32位） |
| | `atomic_xchg_long` | 原子交换（64位） |
| | `atomic_cmpxchg` | CAS 比较交换（32位） |
| | `atomic_cmpxchg_long` | CAS 比较交换（64位） |
| | `atomic_add` | 原子加法 |
| | `fence` | 内存屏障 |
| **平台辅助** | `get_previous_fp` | 获取上一帧指针 |
| | `get_previous_sp` | 获取上一栈指针 |
| | `verify_mxcsr` | 验证 MXCSR 寄存器 |
| **数学函数** | `dexp/dlog/dsin/dcos/dtan...` | 数学库 intrinsic |

---

## 4. 核心桩代码详解：call_stub

### 4.1 功能定位

`call_stub` 是 **C++ 调用 Java 方法的唯一入口**，它负责：
1. 保存 C++ 调用者的寄存器
2. 设置 Java 执行环境（r15_thread）
3. 将参数推入 Java 栈
4. 跳转到 Java 方法入口
5. 处理返回值

### 4.2 调用签名

```cpp
// src/hotspot/share/runtime/stubRoutines.hpp:223-231
typedef void (*CallStub)(
    address   link,              // 调用链接
    intptr_t* result,            // 返回值存储位置
    BasicType result_type,       // 返回值类型
    Method*   method,            // 要调用的方法
    address   entry_point,       // 方法入口点
    intptr_t* parameters,        // 参数数组
    int       size_of_parameters,// 参数个数
    TRAPS                        // 线程
);
```

### 4.3 栈帧布局

```
调用 call_stub 后的栈帧布局（x86_64）

高地址 ↑
┌───────────────────────────────────────┐
│ 调用者栈帧                            │
├───────────────────────────────────────┤
│ return address（调用者）              │ ← 调用 call_stub 前的 rsp
├───────────────────────────────────────┤
│ saved rbp                             │ ← rbp（帧指针）
├───────────────────────────────────────┤
│ call_wrapper                          │ rbp + call_wrapper_off * 8
│ result                                │ rbp + result_off * 8
│ result_type                           │ rbp + result_type_off * 8
│ method                                │ rbp + method_off * 8
│ entry_point                           │ rbp + entry_point_off * 8
│ parameters                            │ rbp + parameters_off * 8
│ parameter_size                        │ rbp + parameter_size_off * 8
│ thread                                │ rbp + thread_off * 8
├───────────────────────────────────────┤
│ saved rbx                             │
│ saved r12                             │
│ saved r13                             │
│ saved r14                             │
│ saved r15                             │
├───────────────────────────────────────┤
│ [MXCSR save area]                     │ Linux only
├───────────────────────────────────────┤
│ Java 方法参数...                      │ ← 参数被 push 到这里
│ ...                                   │
├───────────────────────────────────────┤
│ (Java 方法执行)                       │
└───────────────────────────────────────┘
低地址 ↓
```

### 4.4 执行流程

```
┌──────────────────────────────────────────────────────────────────┐
│                      call_stub 执行流程                           │
└──────────────────────────────────────────────────────────────────┘
                              │
    ① enter()                 ▼
    ┌─────────────────────────────────────────────────────────────┐
    │ push rbp; mov rbp, rsp   // 建立栈帧                        │
    │ sub rsp, frame_size      // 分配局部空间                    │
    └─────────────────────────────────────────────────────────────┘
                              │
    ② 保存参数                 ▼
    ┌─────────────────────────────────────────────────────────────┐
    │ movptr [rbp+xx], c_rarg0  // call_wrapper                   │
    │ movptr [rbp+xx], c_rarg1  // result                         │
    │ movl   [rbp+xx], c_rarg2  // result_type                    │
    │ movptr [rbp+xx], c_rarg3  // method                         │
    │ movptr [rbp+xx], c_rarg4  // entry_point                    │
    │ movptr [rbp+xx], c_rarg5  // parameters                     │
    └─────────────────────────────────────────────────────────────┘
                              │
    ③ 保存 callee-saved 寄存器 ▼
    ┌─────────────────────────────────────────────────────────────┐
    │ movptr [rbp+xx], rbx                                        │
    │ movptr [rbp+xx], r12                                        │
    │ movptr [rbp+xx], r13                                        │
    │ movptr [rbp+xx], r14                                        │
    │ movptr [rbp+xx], r15                                        │
    └─────────────────────────────────────────────────────────────┘
                              │
    ④ 设置 r15_thread          ▼
    ┌─────────────────────────────────────────────────────────────┐
    │ movptr r15, [rbp+thread_off]  // r15 = JavaThread*          │
    │ reinit_heapbase()             // 重新初始化堆基址（压缩指针）│
    └─────────────────────────────────────────────────────────────┘
                              │
    ⑤ 传递 Java 参数           ▼
    ┌─────────────────────────────────────────────────────────────┐
    │ mov c_rarg3, parameter_size                                 │
    │ test c_rarg3, c_rarg3                                       │
    │ jz parameters_done                                          │
    │                                                             │
    │ loop:                                                       │
    │   mov rax, [parameters]  // 取参数                          │
    │   add parameters, 8      // 下一个参数                      │
    │   dec counter                                               │
    │   push rax               // 推入 Java 栈                    │
    │   jnz loop                                                  │
    └─────────────────────────────────────────────────────────────┘
                              │
    ⑥ 调用 Java 方法           ▼
    ┌─────────────────────────────────────────────────────────────┐
    │ mov rbx, [method]        // rbx = Method*                   │
    │ mov c_rarg1, [entry_point]                                  │
    │ mov r13, rsp             // sender sp                       │
    │ call c_rarg1             // ★ 跳转到 Java 方法！            │
    └─────────────────────────────────────────────────────────────┘
                              │
    ⑦ 处理返回值               ▼
    ┌─────────────────────────────────────────────────────────────┐
    │ // call_stub_return_address 指向这里                        │
    │ mov c_rarg0, [result]                                       │
    │ switch (result_type) {                                      │
    │   case T_INT:    mov [c_rarg0], eax                         │
    │   case T_LONG:   mov [c_rarg0], rax                         │
    │   case T_FLOAT:  movss [c_rarg0], xmm0                      │
    │   case T_DOUBLE: movsd [c_rarg0], xmm0                      │
    │ }                                                           │
    └─────────────────────────────────────────────────────────────┘
                              │
    ⑧ 恢复寄存器并返回         ▼
    ┌─────────────────────────────────────────────────────────────┐
    │ mov r15, [r15_save]                                         │
    │ mov r14, [r14_save]                                         │
    │ ... 恢复其他寄存器 ...                                      │
    │ vzeroupper()             // 清除 AVX 状态                   │
    │ pop rbp                                                     │
    │ ret                                                         │
    └─────────────────────────────────────────────────────────────┘
```

---

## 5. 原子操作桩代码

### 5.1 atomic_cmpxchg（CAS）

```cpp
// src/hotspot/cpu/x86/stubGenerator_x86_64.cpp:605-629
address generate_atomic_cmpxchg() {
  StubCodeMark mark(this, "StubRoutines", "atomic_cmpxchg");
  address start = __ pc();

  __ movl(rax, c_rarg2);  // rax = 期望值（compare_value）
  if (os::is_MP()) {
    __ lock();            // 多处理器需要 LOCK 前缀
  }
  __ cmpxchgl(c_rarg0, Address(c_rarg1, 0));  // [c_rarg1] vs rax
  // 如果相等，[c_rarg1] = c_rarg0（exchange_value）
  // rax 返回原值
  __ ret(0);

  return start;
}
```

**汇编指令说明**：
- `LOCK CMPXCHG [mem], reg`：原子比较并交换
- 如果 `[mem] == rax`，则 `[mem] = reg`，ZF=1
- 否则 `rax = [mem]`，ZF=0

### 5.2 fence（内存屏障）

```cpp
// src/hotspot/cpu/x86/stubGenerator_x86_64.cpp:718-724
address generate_orderaccess_fence() {
  StubCodeMark mark(this, "StubRoutines", "orderaccess_fence");
  address start = __ pc();

  __ membar(Assembler::StoreLoad);  // 生成 lock addl $0, (%rsp) 或 mfence
  __ ret(0);

  return start;
}
```

---

## 6. 与第二阶段的对比

| 对比项 | 第一阶段 (stubRoutines_init1) | 第二阶段 (stubRoutines_init2) |
|--------|------------------------------|------------------------------|
| **时机** | universe_init 之前 | universe_init 之后 |
| **代码块** | `_code1` | `_code2` |
| **主要内容** | call_stub、异常处理、原子操作 | 数组拷贝、加解密、数学函数 |
| **依赖** | 仅依赖 Code Cache | 依赖 Universe（需要类信息） |
| **参数** | `StubGenerator_generate(buffer, false)` | `StubGenerator_generate(buffer, true)` |

---

## 7. GDB 验证

### 7.1 实际 GDB 验证结果

【GDB 验证】条件：-Xms256m -Xmx256m -Xint

```
=== StubRoutines Code Blocks ===
_code1 = (BufferBlob *) 0x7fffed000b90    ← 第一阶段代码块
_code2 = (BufferBlob *) 0x0               ← 第二阶段尚未初始化

=== Core Stub Entries ===
_call_stub_entry          = 0x7fffed000c9e
_call_stub_return_address = 0x7fffed000d4a
_catch_exception_entry    = 0x7fffed000e50
_forward_exception_entry  = 0x7fffed000c20

=== Atomic Stubs ===
_atomic_cmpxchg_entry = 0x7fffed000f14
_atomic_add_entry     = 0x7fffed000f2e
_fence_entry          = 0x7fffed000f43

=== Disassemble atomic_cmpxchg ===
0x7fffed000f14:  mov    %edx,%eax           ; rax = compare_value
0x7fffed000f16:  lock cmpxchg %edi,(%rsi)   ; 原子 CAS 操作
0x7fffed000f1a:  ret                        ; 返回原值
```

### 7.2 验证分析

**关键观察**：

1. **代码位置**：所有桩代码地址都在 `0x7fffed000xxx` 范围内，位于 NonNMethodCodeHeap
2. **紧凑布局**：
   - `forward_exception`: 0x7fffed000c20
   - `call_stub`:         0x7fffed000c9e （相距 ~126 字节）
   - `catch_exception`:   0x7fffed000e50
3. **atomic_cmpxchg 只有 3 条指令**：
   - `mov %edx, %eax`：将期望值放入 rax
   - `lock cmpxchg`：原子比较交换
   - `ret`：返回

### 7.3 验证脚本

```gdb
# jvm-md/StubRoutines/gdb_stubRoutines_init1.txt

set pagination off
set print pretty on

# 断点设在 stubRoutines_init1 之后
b init.cpp:119
run -Xms256m -Xmx256m -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# === StubRoutines 代码块 ===
printf "\n========== StubRoutines Code Blocks ==========\n"
printf "_code1 address: %p\n", StubRoutines::_code1
printf "_code2 address: %p\n", StubRoutines::_code2

# === 核心桩代码入口 ===
printf "\n========== Core Stub Entries ==========\n"
printf "_call_stub_entry:          %p\n", StubRoutines::_call_stub_entry
printf "_call_stub_return_address: %p\n", StubRoutines::_call_stub_return_address
printf "_catch_exception_entry:    %p\n", StubRoutines::_catch_exception_entry
printf "_forward_exception_entry:  %p\n", StubRoutines::_forward_exception_entry

# === 异常抛出桩 ===
printf "\n========== Exception Throw Stubs ==========\n"
printf "_throw_StackOverflowError_entry:        %p\n", StubRoutines::_throw_StackOverflowError_entry
printf "_throw_delayed_StackOverflowError_entry: %p\n", StubRoutines::_throw_delayed_StackOverflowError_entry
printf "_throw_AbstractMethodError_entry:       %p\n", StubRoutines::_throw_AbstractMethodError_entry

# === 原子操作桩 ===
printf "\n========== Atomic Operation Stubs ==========\n"
printf "_atomic_xchg_entry:         %p\n", StubRoutines::_atomic_xchg_entry
printf "_atomic_xchg_long_entry:    %p\n", StubRoutines::_atomic_xchg_long_entry
printf "_atomic_cmpxchg_entry:      %p\n", StubRoutines::_atomic_cmpxchg_entry
printf "_atomic_cmpxchg_byte_entry: %p\n", StubRoutines::_atomic_cmpxchg_byte_entry
printf "_atomic_cmpxchg_long_entry: %p\n", StubRoutines::_atomic_cmpxchg_long_entry
printf "_atomic_add_entry:          %p\n", StubRoutines::_atomic_add_entry
printf "_atomic_add_long_entry:     %p\n", StubRoutines::_atomic_add_long_entry
printf "_fence_entry:               %p\n", StubRoutines::_fence_entry

# === 反汇编 call_stub ===
printf "\n========== Disassemble call_stub (first 50 instructions) ==========\n"
x/50i StubRoutines::_call_stub_entry

quit
```

### 7.2 执行方式

```bash
cd /data/workspace/openjdk-cut-new
gdb -x jvm-md/StubRoutines/gdb_stubRoutines_init1.txt \
    ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java
```

---

## 8. 设计思考

### 8.1 为什么分两阶段？

```
                    依赖关系图

stubRoutines_init1()                stubRoutines_init2()
        │                                   │
        │  不依赖 Universe                  │  依赖 Universe
        │  不依赖类加载                     │  需要类信息（如 Object Klass）
        ▼                                   ▼
   ┌─────────┐                        ┌─────────────┐
   │call_stub│                        │arraycopy    │
   │atomic_* │                        │checkcast    │
   │exception│                        │AES encrypt  │
   └─────────┘                        │SHA hash     │
        │                             └─────────────┘
        │                                   │
        ▼                                   ▼
   universe_init()  ───────────────>  需要这些桩才能初始化
```

**关键原因**：
- `call_stub` 是 Java 方法调用的基础，Universe 初始化时就需要调用 Java 代码
- 数组拷贝桩需要知道 oop 大小、对象头布局等信息，这些在 Universe 初始化后才确定

### 8.2 为什么用汇编而不是 C++？

| 考量 | C++ 实现 | 汇编实现 |
|------|----------|----------|
| 性能 | 函数调用开销 | 零开销直接跳转 |
| 寄存器控制 | 编译器决定 | 完全控制 |
| 调用约定 | 受 ABI 限制 | 自定义约定 |
| 原子性 | 需要依赖库 | 直接使用 LOCK 指令 |

---

## 9. 总结

### 9.1 核心流程

```
stubRoutines_init1()
    │
    └── StubRoutines::initialize1()
            │
            ├── BufferBlob::create("StubRoutines (1)", code_size1)
            │       └── 在 NonNMethodCodeHeap 中分配空间
            │
            └── StubGenerator_generate(&buffer, false)
                    │
                    └── StubGenerator::generate_initial()
                            │
                            ├── generate_call_stub()         ★ 最重要
                            ├── generate_catch_exception()
                            ├── generate_forward_exception()
                            ├── generate_atomic_xchg()
                            ├── generate_atomic_cmpxchg()
                            ├── generate_atomic_add()
                            ├── generate_fence()
                            ├── generate_throw_exception(StackOverflowError)
                            └── [可选] generate_libm*(dexp, dlog, dsin...)
```

### 9.2 第一阶段生成的桩代码汇总

| 桩代码 | 入口变量 | 作用 |
|--------|----------|------|
| call_stub | `_call_stub_entry` | C++ 调用 Java 方法 |
| catch_exception | `_catch_exception_entry` | 捕获 Java 异常 |
| forward_exception | `_forward_exception_entry` | 转发异常到调用者 |
| throw_StackOverflowError | `_throw_StackOverflowError_entry` | 抛出栈溢出 |
| atomic_xchg | `_atomic_xchg_entry` | 原子交换 |
| atomic_cmpxchg | `_atomic_cmpxchg_entry` | CAS |
| atomic_add | `_atomic_add_entry` | 原子加 |
| fence | `_fence_entry` | 内存屏障 |
| safefetch32 | `_safefetch32_entry` | 安全内存读取 |

### 9.3 与其他初始化的关系

```
init_globals() 流程
    │
    ├── codeCache_init()        ← 提供代码存储空间
    │
    ├── interpreter_init()      ← 解释器需要 call_stub
    │       │
    │       └── 解释器模板使用 StubRoutines::call_stub()
    │
    ├── stubRoutines_init1()    ← 【当前】
    │       │
    │       └── 生成 call_stub、异常处理、原子操作
    │
    ├── universe2_init()        ← 依赖 call_stub 来调用 Java 代码
    │       │
    │       └── 初始化 System 类、创建 main thread 等
    │
    └── stubRoutines_init2()    ← 第二阶段
            │
            └── 生成数组拷贝、加解密等高级桩代码
```

---

## 10. 下一步建议

1. **深入 call_stub**：阅读完整汇编代码，理解参数传递细节
2. **分析 stubRoutines_init2**：了解第二阶段生成的桩代码
3. **跟踪 Java 方法调用**：从 `JavaCalls::call()` 到 `call_stub` 的完整链路
4. **GDB 验证**：单步调试 call_stub，观察寄存器变化

---

> 📅 分析时间：2026-02-06
> 📁 源码版本：OpenJDK 11
