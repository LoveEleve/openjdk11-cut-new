# Chapter 08: JavaCalls 调用框架 — C++ ↔ Java 的桥梁

> **源码版本**: OpenJDK 11  
> **标准环境**: `-Xms8g -Xmx8g -XX:+UseG1GC -Xint`  
> **核心文件**: `runtime/javaCalls.hpp`, `runtime/javaCalls.cpp`, `cpu/x86/stubGenerator_x86_64.cpp`  
> **与其他章节关系**: 串联反射(ch07)、异常处理(ch06)、锁(ch03)、类初始化(ClassLoading)、线程启动(Thread/ch01)

---

## 1. 设计哲学：为什么需要 JavaCalls？

### 1.1 核心问题

JVM 是一个 **C++ 运行时**，但它需要频繁调用 **Java 方法**。这种跨语言调用面临三大挑战：

| 挑战 | 具体问题 | JavaCalls 如何解决 |
|------|---------|-------------------|
| **栈帧管理** | C++ 栈和 Java 栈格式不同，GC 需要遍历 Java 栈 | `JavaCallWrapper` 保存/恢复 `JavaFrameAnchor`，建立栈帧链 |
| **线程状态** | GC（Safepoint）需要知道线程在哪（VM/Java/Native） | 状态转换 `_thread_in_vm → _thread_in_Java` |
| **句柄管理** | Java 对象引用在 GC 时可能被移动 | `JNIHandleBlock` 分配新句柄块，保护 oop 不被遗漏 |

### 1.2 如果没有 JavaCalls 会怎样？

- **GC 无法工作**：Safepoint 时无法遍历 Java 栈帧，找不到所有 GC Root
- **栈不可遍历**：异常处理、JFR 采样、jstack 全部失效
- **对象泄漏**：参数中的 oop 在 GC 时被移动但指针未更新

### 1.3 一句话总结

> **JavaCalls 是 JVM 中所有 C++ → Java 调用的唯一合法入口。它负责：建立 entry frame → 保存帧锚点 → 切换线程状态 → 通过 call_stub 跳入解释器/编译代码 → 返回后恢复一切状态。**

---

## 2. 整体架构

```
┌──────────────────────────────────────────────────────────────────────┐
│                         调用者 (C++ 层)                              │
│                                                                      │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌────────────┐  │
│  │ Thread.start │ │ Reflection   │ │ JNI Call     │ │ <clinit>   │  │
│  │ initPhase1/2 │ │ Method.invoke│ │ CallXXXMethod│ │ 类初始化    │  │
│  └──────┬───────┘ └──────┬───────┘ └──────┬───────┘ └─────┬──────┘  │
│         │                │                │               │          │
│         ▼                ▼                ▼               ▼          │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │              JavaCalls::call_virtual / call_special / call_static│ │
│  │                     (高层 API — 方法解析)                        │ │
│  └────────────────────────────┬────────────────────────────────────┘ │
│                               │ LinkResolver 解析完毕                 │
│                               ▼                                      │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │                    JavaCalls::call()                             │ │
│  │                  (低层 API — 异常保护)                            │ │
│  └────────────────────────────┬────────────────────────────────────┘ │
│                               │ os::os_exception_wrapper()           │
│                               ▼                                      │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │               JavaCalls::call_helper()                          │ │
│  │    ┌─────────────────────────────────────────────────┐          │ │
│  │    │ 1. 参数验证 (verify)                            │          │ │
│  │    │ 2. CompilationPolicy::compile_if_required       │          │ │
│  │    │ 3. 选择 entry_point                             │          │ │
│  │    │ 4. 栈溢出检查                                    │          │ │
│  │    │ 5. ★ 构造 JavaCallWrapper (栈上)                │          │ │
│  │    │ 6. ★ 调用 StubRoutines::call_stub()             │          │ │
│  │    │ 7. 保存返回值                                    │          │ │
│  │    └─────────────────────────────────────────────────┘          │ │
│  └────────────────────────────┬────────────────────────────────────┘ │
│                               │                                      │
└───────────────────────────────┼──────────────────────────────────────┘
                                │ call_stub (汇编生成)
                                ▼
┌──────────────────────────────────────────────────────────────────────┐
│                    call_stub (x86_64 汇编)                           │
│                                                                      │
│  1. 保存 callee-saved 寄存器 (rbx,r12-r15)                          │
│  2. 加载 r15_thread (线程寄存器)                                      │
│  3. 将参数逐个 push 到栈上                                            │
│  4. mov rbx, method (Method* → rbx)                                  │
│  5. mov r13, rsp (sender sp)                                         │
│  6. call entry_point ──────────► 解释器 / i2c adapter → 编译代码     │
│  7. 保存返回值 (rax/xmm0)                                            │
│  8. 恢复 callee-saved 寄存器                                          │
│  9. ret                                                              │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 3. 核心类：JavaCalls

### 3.1 类定义与职责

`JavaCalls` 是一个 `AllStatic` 纯静态类，**所有 C++ → Java 的调用都必须经过它**。

```
class JavaCalls: AllStatic
├── call_virtual()    ── 虚方法调用（运行时多态，如 toString()）
├── call_special()    ── 特殊调用（私有方法、构造函数 <init>、super 调用）
├── call_static()     ── 静态方法调用（如 initPhase1/2/3、Thread.run()）
├── call()            ── 低层接口（已有 methodHandle，直接调用）
├── construct_new_instance() ── 对象分配 + <init> 一体化
└── call_helper()     ── 【private】核心实现，所有路径汇聚于此
```

### 3.2 三种高层 API 的差异

| API | 方法解析方式 | 典型场景 |
|-----|------------|---------|
| `call_virtual` | `LinkResolver::resolve_virtual_call` → vtable/itable 查找 | `thread_obj.run()`、`obj.toString()` |
| `call_special` | `LinkResolver::resolve_special_call` → 直接绑定 | `<init>` 构造函数、`super.method()` |
| `call_static` | `LinkResolver::resolve_static_call` → 直接绑定 | `initPhase1()`、`System.initPhase2()` |

三者最终都调用 `JavaCalls::call(result, method, args, CHECK)`。

### 3.3 construct_new_instance：对象创建便捷 API

```cpp
Handle JavaCalls::construct_new_instance(InstanceKlass* klass, ...) {
    klass->initialize(CHECK_NH);                // 1. 确保类已初始化
    Handle obj = klass->allocate_instance_handle(CHECK_NH);  // 2. 分配对象
    JavaValue void_result(T_VOID);
    args->set_receiver(obj);                    // 3. 设置 receiver = 新对象
    JavaCalls::call_special(&void_result, klass,
        vmSymbols::object_initializer_name(),   // "<init>"
        constructor_signature, args, CHECK_NH); // 4. 调用构造函数
    return obj;
}
```

等价于 Java 的 `new Klass(args...)`。

---

## 4. 核心流程：call_helper() 逐步分析

`call_helper()` 是所有 JavaCalls 的汇聚点。位于 `javaCalls.cpp:350`。

### 4.1 完整调用链

```
JavaCalls::call_virtual/call_special/call_static
    │
    ├── LinkResolver::resolve_xxx_call()  ← 方法解析
    │
    └── JavaCalls::call(result, method, args, CHECK)
            │
            └── os::os_exception_wrapper(call_helper, ...)  ← OS 异常保护
                    │
                    └── call_helper(result, method, args, THREAD)
                            │
                            ├── [1] args->verify(method)         ← 参数校验
                            ├── [2] compile_if_required(method)  ← JIT 触发
                            ├── [3] entry_point = method->from_interpreted_entry()
                            ├── [4] stack_shadow_pages_available ← 栈溢出检查
                            ├── [5] JavaCallWrapper link(method, receiver, result)
                            │       │
                            │       ├── JNIHandleBlock::allocate_block()
                            │       ├── transition(vm → Java)
                            │       ├── _anchor.copy(thread->frame_anchor())
                            │       ├── thread->frame_anchor()->clear()
                            │       └── thread->set_active_handles(new_handles)
                            │
                            ├── [6] StubRoutines::call_stub()(link, result_val, ...)
                            │       │
                            │       └── 汇编 call_stub → entry_point → Java 代码
                            │
                            └── [7] ~JavaCallWrapper()
                                    │
                                    ├── transition(Java → vm)
                                    ├── thread->frame_anchor()->copy(&_anchor)
                                    └── JNIHandleBlock::release_block()
```

### 4.2 七个关键步骤详解

#### 步骤 1：参数校验 (Debug Only)

```cpp
if (CheckJNICalls) {
    args->verify(method, result->get_type());
}
```

通过 `SignatureChekker` 遍历方法签名，逐个检查：
- 基本类型参数的 `value_state` 必须是 `value_state_primitive`
- oop 参数必须是 `value_state_handle` 或 `value_state_jobject`
- 参数数量必须与签名一致

#### 步骤 2：JIT 编译触发

```cpp
CompilationPolicy::compile_if_required(method, CHECK);
```

仅在 `-Xcomp` 模式下触发（强制编译）。正常模式下靠调用计数器在解释器中触发。

#### 步骤 3：选择入口点

```cpp
address entry_point = method->from_interpreted_entry();
```

`from_interpreted_entry()` 返回的值取决于方法是否已编译：
- **未编译**：`_i2i_entry`（直接进入解释器的 normal_entry）
- **已编译**：`_adapter->i2c_entry()`（通过 i2c adapter 跳转到编译代码）

> 公式：`_from_interpreted_entry = _code ? _adapter->i2c_entry() : _i2i_entry`

**为什么叫 "from_interpreted"？** 因为 call_stub 的设计模拟了**解释器的调用约定**：`rbx = Method*`, `r13 = sender_sp`。所以即使从 C++ 进来，也走解释器入口协议。

#### 步骤 4：栈溢出检查

```cpp
address sp = os::current_stack_pointer();
if (!os::stack_shadow_pages_available(THREAD, method, sp)) {
    Exceptions::throw_stack_overflow_exception(...);
    return;
}
```

检查当前栈指针是否还有足够的 shadow pages（红/黄/保留区），防止进入 Java 代码后栈溢出。

#### 步骤 5：构造 JavaCallWrapper（核心！）

这是 **整个 JavaCalls 最关键的一步**。`JavaCallWrapper` 是栈上分配的 RAII 对象。

**构造函数做的 6 件事：**

```
JavaCallWrapper::JavaCallWrapper(callee_method, receiver, result, THREAD)
│
├── 1. JNIHandleBlock::allocate_block(thread)      ← 分配新句柄块
│      （必须在状态转换前，因为可能阻塞分配）
│
├── 2. ThreadStateTransition::transition(vm → Java) ← 线程状态切换
│      （此后线程对 Safepoint 可见为 "in Java"）
│
├── 3. handle_special_runtime_exit_condition()      ← 检查异步异常/挂起
│
├── 4. _callee_method = callee_method()             ← 保存裸 Method*
│      _receiver = receiver()                       ← 保存裸 oop
│      （状态转换后才能保存，因为转换可能触发 GC）
│
├── 5. _anchor.copy(thread->frame_anchor())         ← ★ 保存旧 anchor
│      thread->frame_anchor()->clear()              ← ★ 清空当前 anchor
│      （下一次设置 anchor 将在 call_stub 汇编中完成）
│
└── 6. thread->set_active_handles(new_handles)      ← 安装新句柄块
       thread->clear_pending_exception()            ← 清除待处理异常
```

**析构函数做的逆操作：**

```
~JavaCallWrapper()
│
├── 1. JNIHandleBlock* _old_handles = thread->active_handles()
│      thread->set_active_handles(_handles)         ← 恢复旧句柄块
│
├── 2. thread->frame_anchor()->zap()                ← 清空当前 anchor
│
├── 3. ThreadStateTransition::transition_from_java(Java → vm)
│      （回到 VM 状态）
│
├── 4. thread->frame_anchor()->copy(&_anchor)       ← ★ 恢复旧 anchor
│
└── 5. JNIHandleBlock::release_block(_old_handles)  ← 释放用过的句柄块
```

#### 步骤 6：调用 call_stub

```cpp
StubRoutines::call_stub()(
    (address)&link,           // JavaCallWrapper* (call_stub 通过它找到 thread)
    result_val_address,       // 返回值地址
    result_type,              // 返回值类型 (T_INT/T_LONG/T_FLOAT/T_DOUBLE/T_OBJECT)
    method(),                 // Method* 裸指针
    entry_point,              // 解释器/i2c 入口地址
    parameter_address,        // 参数数组
    args->size_of_parameters(), // 参数个数
    CHECK
);
```

`call_stub()` 返回一个函数指针 `CallStub`，其签名为：

```cpp
typedef void (*CallStub)(
    address   link,           // JavaCallWrapper*
    intptr_t* result,         // 返回值存放地址
    BasicType result_type,    // 返回值类型
    Method*   method,         // 目标方法
    address   entry_point,    // 入口地址
    intptr_t* parameters,     // 参数数组
    int       size_of_parameters, // 参数数量
    TRAPS                     // Thread*
);
```

#### 步骤 7：保存返回值

```cpp
if (oop_result_flag) {
    thread->set_vm_result((oop) result->get_jobject());
}
// ... 退出 JavaCallWrapper 作用域（触发析构）...
if (oop_result_flag) {
    result->set_jobject((jobject)thread->vm_result());
    thread->set_vm_result(NULL);
}
```

对于 oop 类型返回值，通过 `thread->_vm_result` 跨 GC 安全点保护，因为 JavaCallWrapper 析构可能触发 GC（释放句柄块）。

---

## 5. call_stub 汇编实现（x86_64 Linux）

### 5.1 栈帧布局

```
call_stub 栈帧布局 (Linux x86_64):

     高地址
     ┌────────────────────────────┐
  +3 │ thread (Thread*)           │  ← 第 8 个参数（栈传递）
  +2 │ parameter_size (int)       │  ← 第 7 个参数（栈传递）
  +1 │ return address             │  ← call 指令压入
     ├────────────────────────────┤
   0 │ saved rbp                  │  ← rbp 指向这里
  -1 │ parameters (intptr_t*)     │  ← 保存 c_rarg5
  -2 │ entry_point (address)      │  ← 保存 c_rarg4
  -3 │ method (Method*)           │  ← 保存 c_rarg3
  -4 │ result_type (BasicType)    │  ← 保存 c_rarg2
  -5 │ result (intptr_t*)         │  ← 保存 c_rarg1
  -6 │ call_wrapper (address)     │  ← 保存 c_rarg0 (JavaCallWrapper*)
  -7 │ saved rbx                  │
  -8 │ saved r12                  │
  -9 │ saved r13                  │
 -10 │ saved r14                  │
 -11 │ saved r15                  │
 -12 │ mxcsr_save / rsp_after_call│  ← rsp_after_call 位置
     ├────────────────────────────┤
     │ argument word n            │  ← Java 方法参数（push 到栈上）
     │ ...                        │
     │ argument word 1            │
     │ [return_from_Java]         │  ← rsp（call entry_point 时）
     └────────────────────────────┘
     低地址
```

Linux x86_64 调用约定：前 6 个整数参数通过 `rdi(c_rarg0)`, `rsi(c_rarg1)`, `rdx(c_rarg2)`, `rcx(c_rarg3)`, `r8(c_rarg4)`, `r9(c_rarg5)` 传递，第 7、8 个参数通过栈传递。

### 5.2 关键汇编逻辑

```asm
# 1. 建立栈帧
enter                               # push rbp; mov rbp, rsp
sub rsp, 12 * wordSize              # 分配局部空间

# 2. 保存参数到栈帧
mov [rbp + parameters_off],   c_rarg5  # parameters
mov [rbp + entry_point_off],  c_rarg4  # entry_point
mov [rbp + method_off],       c_rarg3  # method
mov [rbp + result_type_off],  c_rarg2  # result_type
mov [rbp + result_off],       c_rarg1  # result
mov [rbp + call_wrapper_off], c_rarg0  # call_wrapper

# 3. 保存 callee-saved 寄存器
mov [rbp + rbx_off], rbx
mov [rbp + r12_off], r12
mov [rbp + r13_off], r13
mov [rbp + r14_off], r14
mov [rbp + r15_off], r15

# 4. 加载线程寄存器（全局约定 r15 = JavaThread*）
mov r15_thread, [rbp + thread_off]
reinit_heapbase                     # 重设堆基址寄存器

# 5. 推送 Java 方法参数
mov c_rarg3, [rbp + parameter_size_off]  # 参数个数
test c_rarg3, c_rarg3
jz parameters_done
mov c_rarg2, [rbp + parameters_off]      # 参数数组指针
loop:
    mov rax, [c_rarg2]              # 取一个参数
    add c_rarg2, 8                  # 下一个
    dec c_rarg3
    push rax                        # push 到 Java 栈
    jnz loop

# 6. ★ 调用 Java 方法入口
parameters_done:
    mov rbx, [rbp + method_off]     # rbx = Method* (解释器约定)
    mov c_rarg1, [rbp + entry_point_off]
    mov r13, rsp                    # r13 = sender sp (解释器约定)
    call c_rarg1                    # 跳转到 entry_point!

# 7. 返回后 — 存储结果
call_stub_return_address:           # ← _call_stub_return_address 指向这里
    mov c_rarg0, [rbp + result_off] # result 地址
    mov c_rarg1, [rbp + result_type_off]
    # 根据 result_type 存储 rax (int/long/object) 或 xmm0 (float/double)
    cmp c_rarg1, T_OBJECT → movq [c_rarg0], rax
    cmp c_rarg1, T_LONG   → movq [c_rarg0], rax
    cmp c_rarg1, T_FLOAT  → movss [c_rarg0], xmm0
    cmp c_rarg1, T_DOUBLE → movsd [c_rarg0], xmm0
    default (T_INT)       → movl [c_rarg0], eax

# 8. 恢复并返回
    lea rsp, [rbp + rsp_after_call_off]   # 弹出参数
    mov r15, [rbp + r15_off]              # 恢复寄存器
    mov r14, [rbp + r14_off]
    mov r13, [rbp + r13_off]
    mov r12, [rbp + r12_off]
    mov rbx, [rbp + rbx_off]
    ldmxcsr [rbp + mxcsr_off]             # 恢复 MXCSR
    add rsp, 12 * wordSize                # 释放局部空间
    vzeroupper                            # 清 AVX 上半
    pop rbp
    ret
```

### 5.3 关键约定

| 寄存器 | 用途 | 设置者 |
|--------|------|--------|
| `rbx` | `Method*`（当前方法指针） | call_stub 从栈帧加载 |
| `r13` | sender sp（调用者栈顶） | call_stub 在 call 前设置 `mov r13, rsp` |
| `r15` | `JavaThread*`（当前线程） | call_stub 从参数加载 |
| `r12` | heap base（压缩指针基址） | `reinit_heapbase` |

这些约定与**解释器**完全一致。所以 call_stub 模拟的是 "一个解释器帧调用另一个方法"。

---

## 6. JavaCallWrapper 内存布局

### 6.1 结构定义

```cpp
class JavaCallWrapper: StackObj {       // 栈上分配！
    JavaThread*      _thread;           // +8:  调用线程
    JNIHandleBlock*  _handles;          // +16: 保存的旧句柄块
    Method*          _callee_method;    // +24: 被调用方法（裸指针，GC 需要）
    oop              _receiver;         // +32: 接收者对象（裸 oop，GC 需要）
    JavaFrameAnchor  _anchor;           // +40: 保存的旧帧锚点
    JavaValue*       _result;           // +64: 返回值指针
};
```

### 6.2 GDB 验证数据

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC -Xint
┌─────────────────────────────────────────────────────────────┐
│ sizeof(JavaCallWrapper)  = 72 bytes                         │
│ sizeof(JavaFrameAnchor)  = 24 bytes                         │
│ sizeof(JavaCallArguments) = 136 bytes                       │
│ sizeof(JavaValue)        = 16 bytes                         │
├─────────────────────────────────────────────────────────────┤
│ JavaCallWrapper 偏移量:                                      │
│   _thread:        +8                                        │
│   _handles:       +16                                       │
│   _callee_method: +24                                       │
│   _receiver:      +32                                       │
│   _anchor:        +40  (包含 sp+8, pc+8, fp+8 = 24 bytes)   │
│   _result:        +64                                       │
├─────────────────────────────────────────────────────────────┤
│ JavaFrameAnchor 偏移量:                                      │
│   _last_Java_sp:  +0                                        │
│   _last_Java_pc:  +8                                        │
│   _last_Java_fp:  +16                                       │
├─────────────────────────────────────────────────────────────┤
│ StubRoutines 入口:                                           │
│   _call_stub_entry:          0x7fffed000c9e                  │
│   _call_stub_return_address: 0x7fffed000d4a                  │
├─────────────────────────────────────────────────────────────┤
│ 首次调用 (initPhase1 之前):                                   │
│   thread_state: 6 (_thread_in_vm)                            │
│   has_last_Java_frame: false (sp=NULL, pc=NULL, fp=NULL)     │
│   from_interpreted_entry == _i2i_entry (未编译, _code=NULL)  │
│   JavaCallWrapper 分配在栈上: 0x7ffff780a320                  │
└─────────────────────────────────────────────────────────────┘
```

### 6.3 内存布局图

```
JavaCallWrapper (72 bytes, 栈上分配)
偏移    字段名              大小    说明
───────────────────────────────────────────────
0x00   [vtable ptr]        8      StackObj 的虚表指针
0x08   _thread             8      JavaThread*
0x10   _handles            8      保存的旧 JNIHandleBlock*
0x18   _callee_method      8      Method* (GC root)
0x20   _receiver           8      oop (GC root, 非静态调用)
0x28   _anchor             24     保存的旧 JavaFrameAnchor
  0x28   ._last_Java_sp    8       intptr_t* volatile
  0x30   ._last_Java_pc    8       volatile address
  0x38   ._last_Java_fp    8       intptr_t* volatile
0x40   _result             8      JavaValue*
───────────────────────────────────────────────
总计: 72 bytes
```

---

## 7. JavaFrameAnchor：帧锚点机制

### 7.1 解决什么问题？

当线程从 Java 代码进入 C++ 代码时，GC 需要能够遍历 Java 栈帧。但 C++ 代码的栈帧格式与 Java 不同，GC 无法直接遍历。

**解决方案**：在 `JavaThread` 中维护一个 `JavaFrameAnchor`，记录最后一个 Java 帧的 sp/pc/fp。GC 从这个锚点开始，就能遍历所有 Java 帧。

### 7.2 锚点链式保存

```
第一次 C++ → Java 调用（如 initPhase1）:
    anchor = {sp=NULL, pc=NULL, fp=NULL}   ← 首次调用，没有旧帧
    
进入 Java 代码后，anchor 被 call_stub 设置:
    anchor = {sp=entry_frame_sp, pc=..., fp=...}

Java 代码中又回调 C++（如 JNI），再次 C++ → Java:
    JavaCallWrapper 保存当前 anchor 到 _anchor 字段
    thread->frame_anchor()->clear()
    进入第二层 Java 代码
    call_stub 设置新的 anchor
    
    返回时:
    ~JavaCallWrapper 恢复旧 anchor
```

这形成了一个 **anchor 保存链**，与 Java 的栈帧链平行。

### 7.3 is_first_frame() 判断

```cpp
bool is_first_frame() const { return _anchor.last_Java_sp() == NULL; }
```

如果保存的旧 anchor 的 sp 为 NULL，说明这是**第一次** C++ → Java 调用（线程还没有 Java 帧）。

---

## 8. 线程状态转换

### 8.1 状态转换时序

```
                    JavaCallWrapper 构造            call_stub         JavaCallWrapper 析构
                          │                          │                       │
线程状态:  _thread_in_vm ──┤── _thread_in_Java ───────┤── (Java 代码) ────────┤── _thread_in_vm
                          │                          │                       │
                    transition(vm→Java)        (解释/编译代码)      transition_from_java(→vm)
                          │                          │                       │
Safepoint 可见性:  VM中(安全) │  Java中(需要检查poll) │  Java中                │  VM中(安全)
```

### 8.2 为什么要在构造函数中转换？

`ThreadStateTransition::transition(_thread_in_vm, _thread_in_Java)` 做三件事：

1. **设置过渡态**：`_thread_state = _thread_in_vm_trans` (= vm + 1 = 7)
2. **内存序列化**：`OrderAccess::fence()` 或写 serialize page
3. **Safepoint 检查**：`SafepointMechanism::block_if_requested(thread)` — 如果有 Safepoint 请求，在这里阻塞
4. **设置最终态**：`_thread_state = _thread_in_Java`

> **关键不变量**：线程只有在 `_thread_in_vm` 态才能安全操作 C++ 数据结构；只有在 `_thread_in_Java` 态 GC 才能正确遍历其栈帧。

---

## 9. JavaCallArguments：参数封装

### 9.1 设计动机

避免使用 C 的 `va_args`（不安全、不可遍历）。`JavaCallArguments` 提供类型安全的参数封装。

### 9.2 内存布局

```
JavaCallArguments (136 bytes)
├── _value_buffer[9]       (9 × 8 = 72 bytes)  ← 内联数组，存放参数值
├── _value_state_buffer[9] (9 × 1 = 9 bytes)   ← 内联数组，标记每个参数类型
├── [padding]              (7 bytes)
├── _value                 (8 bytes) ← 指向 _value_buffer[1]
├── _value_state           (8 bytes) ← 指向 _value_state_buffer[1]
├── _size                  (4 bytes) ← 当前参数数量
├── _max_size              (4 bytes) ← 最大容量（默认8）
├── _start_at_zero         (1 byte)  ← 是否已设置 receiver
└── [padding]              (7 bytes)
```

### 9.3 三种参数状态

| value_state | 值 | 含义 |
|------------|-----|------|
| `value_state_primitive` | 0 | 基本类型（int/long/float/double） |
| `value_state_handle` | 2 | Handle 引用（安全的 oop 间接引用） |
| `value_state_jobject` | 3 | JNI jobject（需要 JNIHandles::resolve） |
| `value_state_oop` | 1 | 已解析的裸 oop（仅在 `parameters()` 调用后） |

### 9.4 延迟解析机制

```
push_oop(Handle h)  → 存储 Handle 的地址，标记为 value_state_handle
                         （此时不暴露裸 oop，GC 安全）

parameters()        → 遍历所有参数，将 handle/jobject 解析为裸 oop
                         （在 call_stub 即将被调用前，此时 GC 不会发生）
```

**为什么这样设计？** 在参数准备阶段（push_oop 时），可能发生 GC（分配句柄块等）。如果此时已经暴露裸 oop，GC 移动对象后指针就失效了。延迟到 `parameters()` 才解析，确保 GC 安全。

---

## 10. 调用场景大全

### 10.1 GDB 验证的调用统计

```
【GDB 验证】一次完整 JVM 启动 + 执行 "hello jvm" 的调用统计：
┌─────────────────────────────────────────────────────────────┐
│ JavaCalls::call_helper 总次数:  887                          │
│                                                              │
│ 按调用类型分:                                                 │
│   call_static:   224 次 (25.3%)  ← 最多！                    │
│   call_special:   33 次 (3.7%)                               │
│   call_virtual:   27 次 (3.0%)                               │
│   call (低层):   888 次 (100%)   ← 所有高层API + 直接调用     │
│                                                              │
│ 注: call(低层) > call_helper 是因为 call_helper 内部           │
│     有些空方法直接返回不计入断点                                │
│ total (高层 API): 284 次                                     │
│ total (含反射/JNI 直接 call): 888 次                          │
└─────────────────────────────────────────────────────────────┘
```

### 10.2 主要调用场景分类

#### （A）JVM 初始化阶段（call_static 为主，~200+ 次）

| 场景 | 调用方式 | 目标方法 |
|------|---------|---------|
| initPhase1 | `call_static` | `System.initPhase1()` |
| initPhase2 | `call_static` | `System.initPhase2()` |
| initPhase3 | `call_static` | `System.initPhase3()` |
| 类初始化 `<clinit>` | `call(低层)` | 每个类的静态初始化器 |
| ThreadGroup 创建 | `call_special` | `ThreadGroup.<init>()` |

**源码位置**：`thread.cpp:3766-3808`

```cpp
JavaCalls::call_static(&result, klass, vmSymbols::initPhase1_name(), ...);
JavaCalls::call_static(&result, klass, vmSymbols::initPhase2_name(), ...);
JavaCalls::call_static(&result, klass, vmSymbols::initPhase3_name(), ...);
```

#### （B）线程生命周期（call_special / call_static）

| 场景 | 调用方式 | 目标方法 |
|------|---------|---------|
| 线程启动 | `call_special` | `Thread.<init>()` |
| 线程执行 | `call_virtual` | `Thread.run()` (多态) 或 `call_static → target.run()` |
| 线程异常处理 | `call_virtual` | `dispatchUncaughtException()` |
| 线程退出 | `call_virtual` | `Thread.exit()` |

**源码位置**：`thread.cpp:1206-1374`

#### （C）反射调用（call 低层）

| 场景 | 调用方式 | 目标方法 |
|------|---------|---------|
| `Method.invoke()` | `call(低层)` | 任意 Java 方法 |
| `Constructor.newInstance()` | `construct_new_instance` | 分配 + `<init>` |

**源码位置**：`reflection.cpp:1232`

```cpp
JavaCalls::call(&result, method, &java_args, THREAD);
```

这正是 ch07 反射文档中分析的 `Reflection::invoke_method()` 最终汇聚点。

#### （D）JNI 方法调用

| 场景 | 调用方式 | 目标方法 |
|------|---------|---------|
| `CallStaticXXXMethod` | `call_static` | 静态方法 |
| `CallVoidMethod` 等 | `call_virtual` | 虚方法 |
| `CallNonvirtualXXXMethod` | `call_special` | 非虚方法 |
| `NewObject` | `construct_new_instance` | 构造函数 |

**源码位置**：`jni.cpp:1126,1189`

#### （E）类初始化 `<clinit>`

| 场景 | 调用方式 | 目标方法 |
|------|---------|---------|
| `InstanceKlass::call_class_initializer` | `call(低层)` | `<clinit>` |

**源码位置**：`instanceKlass.cpp:1334`

```cpp
JavaCalls::call(&result, h_method, &args, CHECK); // Static call (no args)
```

---

## 11. 与其他模块的关系

### 11.1 架构关系图

```
┌─────────────────────────────────────────────────────────────────────┐
│                      JVM 运行时系统                                  │
│                                                                     │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────────┐   │
│  │ 反射(ch07)│  │ JNI(ch14)│  │ 线程(ch01)│  │ 类初始化(ch08)   │   │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────────┬─────────┘   │
│       │              │             │                  │             │
│       ▼              ▼             ▼                  ▼             │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                   JavaCalls (本章)                            │  │
│  │          C++ ↔ Java 调用的唯一合法桥梁                        │  │
│  └───────────────────────┬──────────────────────────────────────┘  │
│                          │                                         │
│       ┌──────────────────┼──────────────────┐                      │
│       ▼                  ▼                  ▼                      │
│  ┌──────────┐  ┌──────────────┐  ┌──────────────────┐             │
│  │ Safepoint │  │ 异常处理(ch06)│  │ 锁优化(ch03)     │             │
│  │ (状态转换) │  │(catch_exception│  │(entry frame中的  │             │
│  │           │  │ stub)         │  │ monitor enter)   │             │
│  └──────────┘  └──────────────┘  └──────────────────┘             │
│       ▲                  ▲                                         │
│       │                  │                                         │
│  ┌──────────┐  ┌──────────────┐                                    │
│  │ 对象分配  │  │ 解释器/编译器 │                                    │
│  │ (ch02)   │  │ entry point  │                                    │
│  └──────────┘  └──────────────┘                                    │
└─────────────────────────────────────────────────────────────────────┘
```

### 11.2 具体关联

| 模块 | 与 JavaCalls 的关系 |
|------|-------------------|
| **反射 (ch07)** | `Reflection::invoke_method()` → `JavaCalls::call()` 是反射的最终执行层 |
| **异常处理 (ch06)** | call_stub 中如果 Java 抛出异常，走 `catch_exception` stub → 设置 `pending_exception` |
| **锁优化 (ch03)** | `call_special` 调用 `<init>` 时，如果方法是 synchronized，解释器会先 `lock_object` |
| **对象分配 (ch02)** | `construct_new_instance` 先 `allocate_instance_handle`（ch02 的 TLAB 分配），再调 `<init>` |
| **Safepoint (ch01-02)** | JavaCallWrapper 的线程状态转换 `_thread_in_vm → _thread_in_Java` 是 Safepoint 感知的 |
| **线程 (Thread/ch01)** | 新线程的 `thread_main_inner()` 通过 `JavaCalls::call_virtual()` 调用 `Thread.run()` |
| **类加载 (ClassLoading)** | `InstanceKlass::call_class_initializer()` 通过 `JavaCalls::call()` 执行 `<clinit>` |
| **解释器** | call_stub 设置 `rbx=Method*`, `r13=sender_sp`，完全模拟解释器调用约定 |
| **编译器** | `from_interpreted_entry` 可能指向 i2c adapter，透明跳转到编译代码 |

---

## 12. 面试 Q&A

### Q1: JVM 中 C++ 代码如何调用 Java 方法？

**A**: JVM 中所有 C++ → Java 的调用都通过 `JavaCalls` 框架完成。流程分为三层：

1. **高层 API**：`call_virtual/call_special/call_static` — 通过 `LinkResolver` 解析目标方法
2. **核心层**：`call_helper` — 构造 `JavaCallWrapper`（保存帧锚点、切换线程状态 vm→Java、分配新句柄块）
3. **汇编层**：`call_stub` — 在汇编中设置解释器约定的寄存器（rbx=Method*, r15=Thread*），将参数 push 到栈上，然后 call 目标方法的 entry_point

关键设计是 `JavaCallWrapper` 作为 RAII 对象在栈上分配，构造时保存旧状态、析构时恢复，确保异常安全。

### Q2: JavaCallWrapper 解决了什么问题？

**A**: 解决三个核心问题：
- **GC 栈遍历**：通过 `JavaFrameAnchor` 的链式保存，GC 总能从 `thread->frame_anchor()` 找到最近的 Java 帧开始遍历
- **Safepoint 配合**：线程状态从 `_thread_in_vm` 切换到 `_thread_in_Java`，Safepoint 才能正确分类线程
- **句柄隔离**：每次 Java 调用分配新的 `JNIHandleBlock`，调用结束后释放，防止句柄泄漏

### Q3: call_stub 为什么要模拟解释器的调用约定？

**A**: 因为 `from_interpreted_entry` 是所有方法的统一入口。这个入口期望：
- `rbx` = `Method*`（当前方法）
- `r13` = sender sp（调用者栈顶）
- `r15` = `JavaThread*`

这样做的好处是：**call_stub 不需要关心目标方法是解释执行还是已编译**。如果方法已编译，`from_interpreted_entry` 会指向 `i2c adapter`，自动跳转到编译代码。如果未编译，直接进入解释器。对 call_stub 完全透明。

### Q4: 参数中的 oop 如何保证 GC 安全？

**A**: `JavaCallArguments` 使用**延迟解析**策略：
1. `push_oop(Handle h)` 时只存储 Handle 的地址，标记为 `value_state_handle`，不暴露裸 oop
2. 在即将进入 call_stub 前，调用 `parameters()` 将所有 Handle 解析为裸 oop
3. 解析后立即传给 call_stub 使用，此时不会发生 GC

构造函数中也采用类似策略：先完成状态转换（可能触发 GC），再保存 `_callee_method` 和 `_receiver` 的裸指针。

### Q5: 一个简单的 "hello jvm" 程序，JVM 内部调用了多少次 JavaCalls？

**A**: 根据 GDB 实测，一个简单的 `System.out.println("hello jvm")` 程序：
- `call_helper` 被调用 **887 次**
- 其中 `call_static` 224 次（主要是 initPhase1/2/3 + 各种类的 `<clinit>`）
- `call_special` 33 次（构造函数）
- `call_virtual` 27 次（虚方法调用）
- 直接 `call` 888 次（包括反射和类初始化的低层调用）

绝大多数调用发生在 JVM 初始化阶段，用户代码只贡献了极少数调用。

### Q6: JavaFrameAnchor 的 clear/copy 为什么有特殊的顺序要求？

**A**: 关键不变量是：**当 `_last_Java_sp != NULL` 时，其他字段必须有效**。这是因为 profiler 和 GC 会随时检查 `has_last_Java_frame()`。

所以：
- **清除时**：先清 `_last_Java_sp`（此时 `has_last_frame()` 变为 false），再清其他字段
- **复制时**：如果 sp 要变化，先清 `_last_Java_sp`，再更新 fp/pc，最后设置 `_last_Java_sp`

这保证了在任何时刻查看 anchor，要么看到完全有效的状态，要么看到 "没有 Java 帧"。

### Q7: construct_new_instance 和 Java 的 new 有什么不同？

**A**: `construct_new_instance` 等价于 Java 的 `new Klass(args...)`，但更底层：
1. 先调用 `klass->initialize()`（确保类已初始化，可能触发 `<clinit>`)
2. 调用 `allocate_instance_handle()` 分配对象（走 TLAB → G1 分配）
3. 通过 `call_special` 调用 `<init>` 构造函数

与字节码 `new` 的区别：字节码 `new` 在解释器中先分配对象（ch02），然后**分开**执行 `invokespecial <init>`。`construct_new_instance` 把这两步合成了一个原子操作。

---

## 13. 诊断与调试

### 13.1 JVM 参数

| 参数 | 作用 |
|------|------|
| `-Xlog:jni+resolve=debug` | 显示 JNI 方法解析过程 |
| `-XX:+CheckJNICalls` | 启用 JavaCallArguments 参数验证（Debug 版本默认开启） |
| `-Xcomp` | 强制编译所有方法（触发 `compile_if_required`） |
| `-Xint` | 纯解释执行（`from_interpreted_entry` 总是指向 `_i2i_entry`） |

### 13.2 GDB 断点建议

```gdb
# 观察所有 C++ → Java 调用
b JavaCalls::call_helper

# 观察特定类型的调用
b JavaCalls::call_virtual
b JavaCalls::call_special
b JavaCalls::call_static

# 观察 JavaCallWrapper 生命周期
b JavaCallWrapper::JavaCallWrapper
b JavaCallWrapper::~JavaCallWrapper

# 观察 call_stub 入口（汇编级）
b *StubRoutines::_call_stub_entry

# 观察 entry_point 选择
b javaCalls.cpp:394   # entry_point = method->from_interpreted_entry()
```

---

## 14. 源码索引

| 文件 | 说明 |
|------|------|
| `runtime/javaCalls.hpp` | JavaCalls/JavaCallWrapper/JavaCallArguments 类定义 |
| `runtime/javaCalls.cpp` | 核心实现：call/call_helper/call_virtual/call_special/call_static |
| `runtime/javaFrameAnchor.hpp` | JavaFrameAnchor 基类（sp/pc） |
| `cpu/x86/javaFrameAnchor_x86.hpp` | x86_64 特化（添加 fp 字段） |
| `cpu/x86/stubGenerator_x86_64.cpp:209` | `generate_call_stub()` — call_stub 汇编生成 |
| `runtime/stubRoutines.hpp:257` | CallStub 函数指针类型定义 |
| `runtime/interfaceSupport.inline.hpp` | `ThreadStateTransition` — 线程状态转换 |
| `runtime/compilationPolicy.cpp:123` | `compile_if_required()` — JIT 触发检查 |
| `oops/method.hpp:113` | `_from_interpreted_entry` 缓存字段 |
| `runtime/thread.cpp:1206-3808` | 线程启动/initPhase 中的 JavaCalls 使用 |
| `runtime/reflection.cpp:1232` | 反射 `invoke_method()` 中的 `JavaCalls::call()` |
| `oops/instanceKlass.cpp:1334` | 类初始化 `<clinit>` 中的 `JavaCalls::call()` |
| `prims/jni.cpp:1126` | JNI `CallXXXMethod` 中的 `JavaCalls::call()` |

---

*最后更新: 2026-02-09*
