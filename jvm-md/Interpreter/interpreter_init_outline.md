# interpreter_init() 详细大纲

> 源码位置: `src/hotspot/share/interpreter/interpreter.cpp:115`
>
> 解释器是 JVM 执行引擎的核心，负责逐条解释执行 Java 字节码。
> HotSpot 默认使用**模板解释器** (Template Interpreter)，将每个字节码预编译为机器码模板。

---

## 整体调用流程

```
interpreter_init()
│
├── Interpreter::initialize()
│   └── TemplateInterpreterGenerator::generate_all() ⭐核心
│       │
│       ├── [1] 基础桩代码生成
│       │   ├── slow_signature_handler     ─ 慢速签名处理
│       │   ├── error_exits               ─ 错误退出点
│       │   ├── return_entry[]            ─ 返回入口点 (6组)
│       │   ├── invoke_return_entry[]     ─ 调用返回入口
│       │   ├── earlyret_entry            ─ 提前返回入口 (JVMTI)
│       │   ├── native_abi_to_tosca[]     ─ 本地ABI转换
│       │   ├── safept_entry              ─ 安全点入口 (10种TosState)
│       │   ├── throw_exception           ─ 异常抛出
│       │   └── throw_*_entry (6个)       ─ 具体异常入口
│       │
│       ├── [2] 方法入口点生成 (30+种)
│       │   ├── zerolocals                ─ 普通 Java 方法
│       │   ├── zerolocals_synchronized   ─ 同步方法
│       │   ├── native                    ─ 本地方法
│       │   ├── native_synchronized       ─ 同步本地方法
│       │   ├── empty                     ─ 空方法 (只有 return)
│       │   ├── accessor                  ─ getter 方法
│       │   ├── abstract                  ─ 抽象方法
│       │   ├── java_lang_math_*          ─ Math 内部函数 (11种)
│       │   ├── java_lang_ref_reference_get ─ Reference.get()
│       │   ├── java_util_zip_CRC32_*     ─ CRC32 内部函数 (5种)
│       │   └── java_lang_Float/Double_*  ─ 位转换内部函数 (4种)
│       │
│       ├── [3] 字节码模板生成 (202个) ⭐核心
│       │   └── set_entry_points_for_all_bytes()
│       │       └── 为每个字节码生成机器码模板
│       │
│       ├── [4] 安全点设置
│       │   └── set_safepoints_for_all_bytes()
│       │
│       └── [5] 反优化入口点
│           └── deopt_entry[] (7组)
│
├── BytecodeTracer::set_closure() (调试用)
│
├── Forte::register_stub("Interpreter", ...)
│
└── JvmtiExport::post_dynamic_code_generated() (JVMTI 通知)
```

---

## 1. 解释器架构概述

### 1.1 模板解释器 vs C++ 解释器

| 特性 | 模板解释器 (TemplateInterpreter) | C++ 解释器 (CppInterpreter/Zero) |
|------|----------------------------------|----------------------------------|
| 实现方式 | 预生成机器码模板 | C++ 循环解释 |
| 性能 | 快（直接执行机器码） | 慢（函数调用开销） |
| 使用场景 | 默认 (x86, ARM...) | Zero VM (无 JIT 的平台) |
| 代码位置 | `templateInterpreter*.cpp` | `bytecodeInterpreter.cpp` |

### 1.2 InterpreterCodelet 结构

解释器代码被组织为多个 **Codelet**（代码片段）：

```cpp
class InterpreterCodelet : public Stub {
    const char* _description;     // 描述信息 (如 "iconst_0")
    Bytecodes::Code _bytecode;    // 对应的字节码 (如 0x03)
    // 后面紧跟机器码...
};
```

**Codelet 存储在 StubQueue 中**：

```
+------------------+------------------+------------------+-----+
|   Codelet #1     |   Codelet #2     |   Codelet #3     | ... |
| (slow_sig_hdlr)  | (error_exit)     | (return_entry)   |     |
+------------------+------------------+------------------+-----+
```

### 1.3 关键数据结构

| 结构 | 位置 | 说明 |
|------|------|------|
| `AbstractInterpreter::_code` | StubQueue* | 存储所有 Codelet |
| `TemplateInterpreter::_entry_table[]` | address[] | 方法入口点表 |
| `TemplateInterpreter::_normal_table` | DispatchTable | 字节码分发表 |
| `TemplateTable::_template_table[]` | Template[] | 字节码模板定义 |

---

## 2. 基础桩代码生成

### 2.1 slow_signature_handler ✅

| 属性 | 值 |
|------|-----|
| 源码 | `templateInterpreterGenerator.cpp:58` |
| 功能 | 处理复杂方法签名（参数传递） |
| **详细分析** | **[2.1-slow_signature_handler.md](./2.1-slow_signature_handler.md)** |

**GDB 验证数据**：
```
地址: 0x7fffe1008c60
大小: 672 字节 (Header 64B + Code 608B)
_bytecode = -1 (无关联字节码)
```

---

### 2.2 error_exits ✅

| 属性 | 值 |
|------|-----|
| 源码 | `templateInterpreterGenerator.cpp:62` |
| 功能 | 错误退出点 |
| **详细分析** | **[2.2-error_exits.md](./2.2-error_exits.md)** |

**GDB 验证数据**：
```
地址: 0x7fffe1008ec0
大小: 128 字节 (Header 64B + Code 64B)
包含: _unimplemented_bytecode, _illegal_bytecode_sequence
```

**生成的入口**：
- `_unimplemented_bytecode` - 未实现的字节码
- `_illegal_bytecode_sequence` - 非法字节码序列

---

### 2.3 return_entry[] (返回入口点) ✅

| 属性 | 值 |
|------|-----|
| 源码 | `templateInterpreterGenerator.cpp:86` |
| 数量 | 6 组（按 invoke 指令长度） |
| **详细分析** | **[2.3-return_entry.md](./2.3-return_entry.md)** |

**GDB 验证数据**：
```
地址: 0x7fffe1008f80 - 0x7fffe1009ac0
大小: 2880 bytes
每组 10 种 TosState 入口，优化: btos/ztos/ctos/stos 共享 itos
```

**每组包含 10 种 TosState 入口**：

| TosState | 说明 |
|----------|------|
| btos | byte 栈顶 |
| ztos | boolean 栈顶 |
| ctos | char 栈顶 |
| stos | short 栈顶 |
| atos | 对象引用栈顶 |
| itos | int 栈顶 |
| ltos | long 栈顶 |
| ftos | float 栈顶 |
| dtos | double 栈顶 |
| vtos | void (空栈顶) |

**返回入口的作用**：
```
callee 方法返回
    ↓
根据返回值类型选择对应 TosState 的 return_entry
    ↓
恢复 caller 的栈帧
    ↓
继续执行 caller 的下一条字节码
```

---

### 2.4 invoke_return_entry[] ⬜

| 属性 | 值 |
|------|-----|
| 源码 | `templateInterpreterGenerator.cpp:107` |
| 功能 | 不同 invoke 指令的返回入口 |

**三种 invoke 返回入口**：
| 入口 | 对应指令 | 指令长度 |
|------|----------|----------|
| `_invoke_return_entry[]` | invokestatic, invokespecial, invokevirtual | 3 |
| `_invokeinterface_return_entry[]` | invokeinterface | 5 |
| `_invokedynamic_return_entry[]` | invokedynamic | 5 |

---

### 2.5 safept_entry (安全点入口) ⬜

| 属性 | 值 |
|------|-----|
| 源码 | `templateInterpreterGenerator.cpp:154` |
| 数量 | 10 种（每种 TosState） |

**安全点检查时机**：
- 后向跳转 (backward branch)
- 方法返回
- 方法调用

**安全点入口的作用**：
```cpp
// 伪代码
if (SafepointSynchronize::is_synchronizing()) {
    // 需要暂停，跳转到安全点入口
    goto safept_entry[current_tos_state];
}
// 继续执行
```

---

### 2.6 throw_exception ✅ → [2.6-throw_exception.md](./2.6-throw_exception.md)

| 属性 | 值 |
|------|-----|
| 源码 | `templateInterpreterGenerator_x86.cpp:1506` |
| 功能 | 异常抛出统一入口 |
| PrintInterpreter | `exception handling [0x00007f8c9d00f040, 0x00007f8c9d010860] 6176 bytes` |

**生成的 4 个入口点**：
| 入口 | 用途 |
|------|------|
| `_rethrow_exception_entry` | 从被调用帧返回，重新抛出异常 |
| `_throw_exception_entry` | 在解释器代码内抛出新异常 |
| `_remove_activation_preserving_args_entry` | JVMTI PopFrame 支持 |
| `_remove_activation_entry` | 当前帧无法处理，移除并传播 |

**核心调用**：`InterpreterRuntime::exception_handler_for_exception` - 查找异常处理器

---

### 2.7 具体异常入口点 ✅ → [2.7-throw_exception_entrypoints.md](./2.7-throw_exception_entrypoints.md)

| 属性 | 值 |
|------|-----|
| 源码 | `templateInterpreterGenerator.cpp:175` |
| PrintInterpreter | `throw exception entrypoints [0x00007f8c9d0108a0, 0x00007f8c9d011120] 2176 bytes` |

**6 种异常入口点**：
| 入口 | 异常类型 | 触发场景 |
|------|----------|----------|
| `_throw_ArrayIndexOutOfBoundsException_entry` | AIOOBE | 数组越界 |
| `_throw_ArrayStoreException_entry` | ASE | 数组存储类型不匹配 |
| `_throw_ArithmeticException_entry` | AE | 整数除零 |
| `_throw_ClassCastException_entry` | CCE | checkcast 失败 |
| `_throw_NullPointerException_entry` | NPE | 空指针解引用 |
| `_throw_StackOverflowError_entry` | SOE | 栈溢出 |

---

## 3. 方法入口点生成 ⭐核心

### 3.1 MethodKind 枚举（30+ 种）

```cpp
// src/hotspot/share/interpreter/abstractInterpreter.hpp:59
enum MethodKind {
    // 基本类型
    zerolocals,                    // 普通 Java 方法
    zerolocals_synchronized,       // 同步 Java 方法
    native,                        // 本地方法
    native_synchronized,           // 同步本地方法
    empty,                         // 空方法 (只有 return)
    accessor,                      // getter 方法
    abstract,                      // 抽象方法
    
    // MethodHandle (多个)
    method_handle_invoke_FIRST,
    method_handle_invoke_LAST,
    
    // Math 内部函数 (11种)
    java_lang_math_sin,
    java_lang_math_cos,
    java_lang_math_tan,
    java_lang_math_abs,
    java_lang_math_sqrt,
    java_lang_math_log,
    java_lang_math_log10,
    java_lang_math_pow,
    java_lang_math_exp,
    java_lang_math_fmaF,
    java_lang_math_fmaD,
    
    // Reference.get()
    java_lang_ref_reference_get,
    
    // CRC32 内部函数 (5种)
    java_util_zip_CRC32_update,
    java_util_zip_CRC32_updateBytes,
    java_util_zip_CRC32_updateByteBuffer,
    java_util_zip_CRC32C_updateBytes,
    java_util_zip_CRC32C_updateDirectByteBuffer,
    
    // 位转换 (4种)
    java_lang_Float_intBitsToFloat,
    java_lang_Float_floatToRawIntBits,
    java_lang_Double_longBitsToDouble,
    java_lang_Double_doubleToRawLongBits,
    
    number_of_method_entries
};
```

---

### 3.2 zerolocals (普通方法入口) ✅ ⭐⭐⭐

| 属性 | 值 |
|------|-----|
| 源码 | `templateInterpreterGenerator_x86.cpp:1335` |
| 函数 | `generate_normal_entry(false)` |
| **详细分析** | **[generate_normal_entry.md](./generate_normal_entry.md)** |

**这是最重要的方法入口点**，所有普通 Java 方法都通过这里进入解释器执行。

#### 入口点执行流程

```
generate_normal_entry(synchronized=false)
│
├── 1. 获取参数大小
│   ├── movptr(rdx, constMethod)
│   └── load_unsigned_short(rcx, size_of_parameters)
│
├── 2. 计算额外本地变量
│   ├── load_unsigned_short(rdx, size_of_locals)
│   └── subl(rdx, rcx)  // 额外本地变量 = locals - parameters
│
├── 3. 栈溢出检查
│   └── generate_stack_overflow_check()
│
├── 4. 分配本地变量空间
│   └── 循环 push NULL 初始化每个本地变量槽
│
├── 5. 创建解释器栈帧 ⭐
│   └── generate_fixed_frame(false)
│
├── 6. 递增调用计数器
│   └── generate_counter_incr()
│       ├── 如果达到阈值 → 触发 JIT 编译
│       └── 如果需要 profiling → 创建 MethodData
│
├── 7. 栈 banging (shadow pages)
│   └── bang_stack_shadow_pages(false)
│
├── 8. 如果是同步方法 → 获取锁
│   └── lock_method()
│
├── 9. JVMTI 方法进入通知
│   └── notify_method_entry()
│
└── 10. 开始字节码分发
    └── dispatch_next(vtos)
```

#### 解释器栈帧布局 (x86-64)

```
    高地址
    ┌─────────────────────────────┐
    │     caller's frame         │
    ├─────────────────────────────┤ ← rbp + 8 (return address)
    │     return address         │
    ├─────────────────────────────┤ ← rbp (saved rbp)
    │     saved rbp              │
    ├─────────────────────────────┤ ← rbp - 8
    │     sender sp              │  interpreter_frame_sender_sp_offset
    ├─────────────────────────────┤ ← rbp - 16
    │     last_sp (NULL)         │  interpreter_frame_last_sp_offset
    ├─────────────────────────────┤ ← rbp - 24
    │     Method*                │  interpreter_frame_method_offset
    ├─────────────────────────────┤ ← rbp - 32
    │     mirror (Class oop)     │  interpreter_frame_mirror_offset (GC root)
    ├─────────────────────────────┤ ← rbp - 40
    │     mdp (MethodData ptr)   │  interpreter_frame_mdp_offset
    ├─────────────────────────────┤ ← rbp - 48
    │     ConstantPoolCache*     │  interpreter_frame_cache_offset
    ├─────────────────────────────┤ ← rbp - 56
    │     locals pointer         │  interpreter_frame_locals_offset
    ├─────────────────────────────┤ ← rbp - 64
    │     bcp (bytecode pointer) │  interpreter_frame_bcp_offset
    ├─────────────────────────────┤ ← rbp - 72
    │     expression stack bottom│  interpreter_frame_initial_sp_offset
    ├═════════════════════════════┤
    │                             │
    │     expression stack        │  (从底部向上增长)
    │          ↑                  │
    │                             │
    ├─────────────────────────────┤ ← rsp (当前栈顶)
    低地址
```

**关键寄存器约定** (x86-64):

| 寄存器 | 用途 |
|--------|------|
| `rbp` | 栈帧基址 |
| `rsp` | 栈顶指针 |
| `rbx` | Method* |
| `r13` | bcp (bytecode pointer) |
| `r14` | locals pointer |
| `r15` | 线程指针 (Thread*) |

---

### 3.3 zerolocals_synchronized (同步方法入口) ✅ → [3.3-zerolocals_synchronized.md](./3.3-zerolocals_synchronized.md)

| 属性 | 值 |
|------|-----|
| 源码 | `generate_normal_entry(true)` |
| PrintInterpreter | `method entry point (kind = zerolocals_synchronized) [0x00007f8c9d011960, 0x00007f8c9d012380] 2592 bytes` |
| 与 zerolocals 区别 | 多调用 `lock_method()` |

**lock_method() 功能**：
1. 确定锁对象（实例方法=this，静态方法=Class）
2. 分配 BasicObjectLock (16字节)
3. 调用 lock_object() 获取监视器锁

---

### 3.4 native (本地方法入口) ✅ → [3.4-native_entry.md](./3.4-native_entry.md) ⭐⭐

| 属性 | 值 |
|------|-----|
| 源码 | `templateInterpreterGenerator_x86.cpp:784` |
| PrintInterpreter | `native [0x00007f8c9d012aa0, 0x00007f8c9d013980] 3808 bytes` |

**核心特性**：
- 线程状态转换：`_thread_in_Java` → `_thread_in_native` → `_thread_in_native_trans` → `_thread_in_Java`
- JNI 参数准备：通过 signature_handler 转换
- 安全点协调：从 native 返回时检查 safepoint

**执行流程**（简化）：
```
1. 创建栈帧 (含 result_handler + oop_temp 槽位)
2. 获取/调用 signature_handler (参数转换)
3. 设置 JNIEnv* 作为第一个参数
4. _thread_in_native → call 本地方法
5. _thread_in_native_trans → safepoint 检查
6. _thread_in_Java → 处理返回值 → 返回
```

---

### 3.5 empty (空方法入口) ✅ → [3.5-3.6-empty-accessor.md](./3.5-3.6-empty-accessor.md)

| 属性 | 值 |
|------|-----|
| 条件 | `code_size() == 1 && *code_base() == Bytecodes::_return` |
| 实际入口 | **复用 zerolocals** (Template 解释器不生成特殊入口) |

---

### 3.6 accessor (getter 方法入口) ✅ → [3.5-3.6-empty-accessor.md](./3.5-3.6-empty-accessor.md)

| 属性 | 值 |
|------|-----|
| 条件 | `code_size() == 5 && aload_0; getfield; return` |
| 实际入口 | **复用 zerolocals** (Template 解释器不生成特殊入口) |

---

### 3.7 abstract (抽象方法入口) ✅

| 属性 | 值 |
|------|-----|
| 源码 | `templateInterpreterGenerator_x86.cpp:1313` |
| PrintInterpreter | `method entry point (kind = abstract) [0x00007f8c9d0123c0, 0x00007f8c9d012540] 384 bytes` |
| 功能 | 抛出 AbstractMethodError |

**实现（仅 15 行）**：
```cpp
address TemplateInterpreterGenerator::generate_abstract_entry(void) {
    address entry_point = __ pc();
    
    __ empty_expression_stack();
    __ restore_bcp();
    __ restore_locals();
    
    // 抛出 AbstractMethodError
    __ call_VM(noreg, CAST_FROM_FN_PTR(address, 
               InterpreterRuntime::throw_AbstractMethodErrorWithMethod), rbx);
    __ should_not_reach_here();
    
    return entry_point;
}
```

---

### 3.8 java_lang_math_* (Math 内部函数) ✅

| 属性 | 值 |
|------|-----|
| 源码 | `templateInterpreterGenerator_x86_64.cpp:338` |
| 数量 | 11 种 |
| 优化 | 直接使用 CPU 指令或 StubRoutines |
| PrintInterpreter | 每个入口约 32 bytes |

**实现方式**：
| 方法 | 实现 |
|------|------|
| Math.sqrt() | `sqrtsd` 指令 |
| Math.abs() | `fabs` 指令 |
| Math.fma() | `vfmadd` 指令 (需要 UseFMA) |
| Math.sin/cos/tan/log/exp/pow | StubRoutines 或 SharedRuntime |

**代码结构**：
```cpp
address generate_math_entry(AbstractInterpreter::MethodKind kind) {
    if (!InlineIntrinsics) return NULL;  // 返回 zerolocals
    
    // 从栈加载参数到 xmm0
    __ movdbl(xmm0, Address(rsp, wordSize));
    
    // 根据 kind 调用对应实现
    if (kind == Interpreter::java_lang_math_sqrt) {
        __ sqrtsd(xmm0, xmm0);  // 直接 CPU 指令
    } else if (kind == Interpreter::java_lang_math_sin) {
        __ call(StubRoutines::dsin());  // Stub 例程
    }
    // ...
    
    // 返回：结果在 xmm0
    __ pop(rax);       // 返回地址
    __ mov(rsp, r13);  // 恢复栈
    __ jmp(rax);       // 返回
}
```

**特点**：
- 不创建完整解释器栈帧
- 不需要安全点检查（不是虚方法）
- 直接使用 xmm0 返回 double 结果

---

### 3.9 java_lang_ref_reference_get ✅

| 属性 | 值 |
|------|-----|
| 源码 | `templateInterpreterGenerator_x86.cpp:698` |
| PrintInterpreter | `method entry point (kind = java_lang_ref_reference_get) [0x00007f8c9d0129a0, 0x00007f8c9d012a60] 192 bytes` |
| 功能 | Reference.get() 特殊处理（需要读屏障） |

**为什么需要特殊入口**：
- `Reference.get()` 需要使用 **ON_WEAK_OOP_REF** 装饰器加载
- 确保 G1 SATB 并发标记期间弱引用对象被正确处理

**实现逻辑**：
```cpp
address generate_Reference_get_entry(void) {
    // 1. 检查 receiver 是否为 null
    __ movptr(rax, Address(rsp, wordSize));  // 加载 this
    __ testptr(rax, rax);
    __ jcc(Assembler::zero, slow_path);  // null → 走普通路径抛 NPE
    
    // 2. 使用 ON_WEAK_OOP_REF 加载 referent 字段 ⭐
    const Address field_address(rax, referent_offset);
    __ load_heap_oop(rax, field_address, rbx, rdx, ON_WEAK_OOP_REF);
    
    // 3. 直接返回（不创建完整栈帧）
    __ pop(rdi);            // 返回地址
    __ mov(rsp, r13);       // 恢复栈
    __ jmp(rdi);
    
    // slow_path → 跳转到 zerolocals 入口
}
```

**ON_WEAK_OOP_REF 的作用**：
- 触发 G1 SATB 前置屏障
- 确保弱引用对象在并发标记期间不会被错误回收

---

### 3.10 CRC32/Float/Double 内部函数 ✅

| 类型 | 方法 | 优化 | PrintInterpreter |
|------|------|------|------------------|
| CRC32 | update | 使用 CRC32 指令 | 64 bytes |
| CRC32 | updateBytes/updateByteBuffer | 批量 CRC32 | 96 bytes |
| CRC32C | updateBytes/updateDirectByteBuffer | CRC32C 指令 | - |
| Float | intBitsToFloat | 寄存器移动 | (x86_64 复用 native) |
| Float | floatToRawIntBits | 寄存器移动 | (x86_64 复用 native) |
| Double | longBitsToDouble | 寄存器移动 | (x86_64 复用 native) |
| Double | doubleToRawLongBits | 寄存器移动 | (x86_64 复用 native) |

**注意**：在 x86-64 上，Float/Double 的位转换方法复用 native 入口，只在 IA32 上有特殊实现。

---

## 4. 字节码模板生成 ⭐⭐⭐核心

### 4.1 概述

```cpp
void TemplateInterpreterGenerator::set_entry_points_for_all_bytes() {
    for (int i = 0; i < DispatchTable::length; i++) {
        Bytecodes::Code code = (Bytecodes::Code)i;
        if (Bytecodes::is_defined(code)) {
            set_entry_points(code);  // 为每个字节码生成机器码
        } else {
            set_unimplemented(i);
        }
    }
}
```

### 4.2 字节码分类与数量

| 类别 | 范围 | 数量 | 示例 |
|------|------|------|------|
| 标准字节码 | 0x00-0xCA | 203 | iconst_0, aload, invokevirtual |
| wide 前缀 | 0xC4 | 1 | wide iload, wide istore |
| 内部字节码 | 0xCB-0xE5 | 26 | _fast_agetfield, _fast_invokevfinal |

### 4.3 Template 结构

```cpp
class Template {
    int       _flags;      // 标志位
    TosState  _tos_in;     // 输入栈顶状态
    TosState  _tos_out;    // 输出栈顶状态
    generator _gen;        // 生成器函数指针
    int       _arg;        // 生成器参数
};
```

**标志位**：
| 标志 | 含义 |
|------|------|
| `uses_bcp` | 需要 bcp 指向字节码 |
| `does_dispatch` | 自己负责分发下一个字节码 |
| `calls_vm` | 调用 VM 运行时 |
| `wide` | wide 指令版本 |

### 4.4 TosState (栈顶状态)

字节码执行前后的栈顶值类型：

| TosState | 含义 | 示例字节码 |
|----------|------|------------|
| vtos | void (空) | nop, pop |
| atos | 对象引用 | aload, areturn |
| itos | int | iconst, iadd |
| ltos | long | lconst, ladd |
| ftos | float | fconst, fadd |
| dtos | double | dconst, dadd |
| btos | byte | (内部使用) |
| ctos | char | (内部使用) |
| stos | short | (内部使用) |

### 4.5 字节码模板定义 (TemplateTable)

位置: `src/hotspot/share/interpreter/templateTable.cpp`

```cpp
void TemplateTable::initialize() {
    // 常量入栈
    def(Bytecodes::_nop,        ____|____|____|____, vtos, vtos, nop,        _);
    def(Bytecodes::_aconst_null,____|____|____|____, vtos, atos, aconst_null,_);
    def(Bytecodes::_iconst_m1,  ____|____|____|____, vtos, itos, iconst,    -1);
    def(Bytecodes::_iconst_0,   ____|____|____|____, vtos, itos, iconst,     0);
    // ...
    
    // 加载指令
    def(Bytecodes::_iload,      ubcp|____|clvm|____, vtos, itos, iload,      _);
    def(Bytecodes::_aload,      ubcp|____|clvm|____, vtos, atos, aload,      _);
    // ...
    
    // 存储指令  
    def(Bytecodes::_istore,     ubcp|____|clvm|____, itos, vtos, istore,     _);
    def(Bytecodes::_astore,     ubcp|____|clvm|____, atos, vtos, astore,     _);
    // ...
    
    // 数组操作
    def(Bytecodes::_aaload,     ____|____|____|____, itos, atos, aaload,     _);
    def(Bytecodes::_aastore,    ____|____|____|____, vtos, vtos, aastore,    _);  // G1屏障
    // ...
    
    // 算术运算
    def(Bytecodes::_iadd,       ____|____|____|____, itos, itos, iop2, add);
    def(Bytecodes::_isub,       ____|____|____|____, itos, itos, iop2, sub);
    // ...
    
    // 字段访问
    def(Bytecodes::_getfield,   ubcp|____|clvm|____, vtos, vtos, getfield,  f1_byte);
    def(Bytecodes::_putfield,   ubcp|____|clvm|____, vtos, vtos, putfield,  f2_byte);  // G1屏障
    // ...
    
    // 方法调用
    def(Bytecodes::_invokevirtual,  ubcp|disp|clvm|____, vtos, vtos, invokevirtual,  f2_byte);
    def(Bytecodes::_invokespecial,  ubcp|disp|clvm|____, vtos, vtos, invokespecial,  f1_byte);
    def(Bytecodes::_invokestatic,   ubcp|disp|clvm|____, vtos, vtos, invokestatic,   f1_byte);
    def(Bytecodes::_invokeinterface,ubcp|disp|clvm|____, vtos, vtos, invokeinterface,f1_byte);
    def(Bytecodes::_invokedynamic,  ubcp|disp|clvm|____, vtos, vtos, invokedynamic,  f1_byte);
    // ...
    
    // 返回指令
    def(Bytecodes::_ireturn,    ____|disp|____|____, itos, itos, _return,    itos);
    def(Bytecodes::_areturn,    ____|disp|____|____, atos, atos, _return,    atos);
    def(Bytecodes::_return,     ____|disp|____|____, vtos, vtos, _return,    vtos);
    // ...
}
```

---

## 5. 关键字节码详细分析

### 5.1 常量加载类 ⬜

| 字节码 | 操作 | TosState 变化 |
|--------|------|---------------|
| iconst_0 | 将 0 压入栈 | vtos → itos |
| aconst_null | 将 null 压入栈 | vtos → atos |
| ldc | 从常量池加载 | vtos → 取决于类型 |
| ldc2_w | 加载 long/double | vtos → ltos/dtos |

---

### 5.2 局部变量加载类 ⬜

| 字节码 | 操作 | TosState 变化 |
|--------|------|---------------|
| iload | 加载 int 局部变量 | vtos → itos |
| aload | 加载引用局部变量 | vtos → atos |
| iload_0 | 加载槽 0 的 int | vtos → itos |
| aload_0 | 加载槽 0 的引用 (通常是 this) | vtos → atos |

---

### 5.3 局部变量存储类 ⬜

| 字节码 | 操作 | TosState 变化 |
|--------|------|---------------|
| istore | 存储 int 到局部变量 | itos → vtos |
| astore | 存储引用到局部变量 | atos → vtos |

---

### 5.4 数组操作类 ⬜ ⭐G1屏障

#### aaload (数组加载)

```cpp
void TemplateTable::aaload() {
    // 栈: ..., arrayref, index
    __ movl(rcx, at_tos());      // index
    __ movptr(rax, at_tos_p1()); // arrayref
    index_check(rax, rcx);       // 越界检查
    
    // 使用 access_load_at 加载（可能触发 G1 读屏障）
    __ access_load_at(T_OBJECT, IN_HEAP | IS_ARRAY, ...);
    // 栈: ..., value
}
```

#### aastore (数组存储) ⭐⭐⭐

```cpp
void TemplateTable::aastore() {
    // 栈: ..., arrayref, index, value
    __ movptr(rax, at_tos());    // value
    __ movl(rcx, at_tos_p1());   // index
    __ movptr(rdx, at_tos_p2()); // arrayref
    
    // 1. 越界检查
    index_check_without_pop(rdx, rcx);
    
    // 2. null 检查
    __ testptr(rax, rax);
    __ jcc(Assembler::zero, is_null);
    
    // 3. 类型检查 (ArrayStoreException)
    __ gen_subtype_check(rbx, ok_is_subtype);
    
    // 4. 存储（带 G1 写屏障）⭐
    do_oop_store(_masm, element_address, rax, IS_ARRAY);
}
```

**G1 写屏障在 aastore 中的调用链**：
```
aastore
  └── do_oop_store(_masm, addr, val, IS_ARRAY)
        └── __ access_store_at(T_OBJECT, IN_HEAP | IS_ARRAY, ...)
              └── G1BarrierSetAssembler::store_at()
                    ├── g1_write_barrier_pre()   // SATB 前置屏障
                    ├── 实际存储
                    └── g1_write_barrier_post()  // dirty card 后置屏障
```

---

### 5.5 字段访问类 ⬜ ⭐G1屏障

#### getfield

```cpp
void TemplateTable::getfield(int byte_no) {
    getfield_or_static(byte_no, false);
}

void TemplateTable::getfield_or_static(int byte_no, bool is_static) {
    // 1. 解析字段（首次调用时）
    resolve_cache_and_index(byte_no, cache, index, sizeof(u2));
    
    // 2. 加载字段偏移和标志
    load_field_cp_cache_entry(obj, cache, index, off, flags, is_static);
    
    // 3. 根据字段类型加载
    switch (field_type) {
        case atos:  // 对象引用
            __ access_load_at(T_OBJECT, IN_HEAP, field, ...);
            break;
        case itos:  // int
            __ access_load_at(T_INT, IN_HEAP, field, ...);
            break;
        // ...
    }
}
```

#### putfield ⭐⭐⭐

```cpp
void TemplateTable::putfield(int byte_no) {
    putfield_or_static(byte_no, false);
}

void TemplateTable::putfield_or_static(int byte_no, bool is_static) {
    // 1. 解析字段
    resolve_cache_and_index(byte_no, cache, index, sizeof(u2));
    
    // 2. 加载字段偏移和标志
    load_field_cp_cache_entry(obj, cache, index, off, flags, is_static);
    
    // 3. 根据字段类型存储
    switch (field_type) {
        case atos:  // 对象引用 → 需要 G1 写屏障
            do_oop_store(_masm, field, rax);  // ⭐带屏障
            break;
        case itos:  // int → 不需要屏障
            __ access_store_at(T_INT, IN_HEAP, field, rax, ...);
            break;
        // ...
    }
}
```

**G1 写屏障在 putfield 中的调用链**：
```
putfield (atos类型)
  └── do_oop_store(_masm, field, rax)
        └── __ access_store_at(T_OBJECT, IN_HEAP, ...)
              └── G1BarrierSetAssembler::store_at()
                    ├── g1_write_barrier_pre()   // SATB 前置屏障
                    ├── 实际存储
                    └── g1_write_barrier_post()  // dirty card 后置屏障
```

---

### 5.6 方法调用类 ⬜ ⭐⭐重要

#### invokevirtual

```cpp
void TemplateTable::invokevirtual(int byte_no) {
    // 1. 准备调用信息
    prepare_invoke(byte_no, rbx, noreg, rcx, rdx);
    // rbx = vtable index 或 Method*
    // rcx = receiver
    // rdx = flags
    
    // 2. 执行虚方法调用
    invokevirtual_helper(rbx, rcx, rdx);
}

void TemplateTable::invokevirtual_helper(Register index, Register recv, Register flags) {
    // 1. 空指针检查
    __ null_check(recv);
    
    // 2. 获取接收者的 Klass
    __ load_klass(rax, recv);
    
    // 3. 查找 vtable 获取目标 Method*
    // method = klass->vtable[vtable_index]
    
    // 4. 跳转到目标方法
    __ jump_from_interpreted(method, rax);
}
```

#### invokeinterface

```cpp
void TemplateTable::invokeinterface(int byte_no) {
    // 1. 准备调用信息
    prepare_invoke(byte_no, rax, rbx, rcx, rdx);
    // rax = interface Klass
    // rbx = itable index
    // rcx = receiver
    // rdx = flags
    
    // 2. 空指针检查
    __ null_check(rcx);
    
    // 3. 获取接收者的 Klass
    __ load_klass(rdx, rcx);
    
    // 4. 在 itable 中查找方法
    // 这比 vtable 查找更复杂，需要遍历 itable
    
    // 5. 跳转到目标方法
    __ jump_from_interpreted(method, rax);
}
```

#### invokedynamic ✅ → [7.0-invokedynamic-deep-dive.md](./7.0-invokedynamic-deep-dive.md) ⭐⭐重要

| 属性 | 值 |
|------|-----|
| 源码 | `templateTable_x86.cpp:3964` |
| 功能 | 动态方法调用（Lambda、方法引用的基础） |
| **详细分析** | **[7.0-invokedynamic-deep-dive.md](./7.0-invokedynamic-deep-dive.md)** |

**核心概念**：
- **CallSite** - 调用点，持有目标 MethodHandle
- **Bootstrap Method** - 首次执行时调用，创建 CallSite
- **MethodHandle** - 类型安全的方法引用

```cpp
void TemplateTable::invokedynamic(int byte_no) {
    // 1. 准备调用（解析 CP Cache，获取 CallSite 和目标方法）
    prepare_invoke(byte_no, rbx_method, rax_callsite);
    
    // 此时:
    // rax: CallSite 对象
    // rbx: MH.linkToCallSite 方法
    
    // 2. profile 调用信息
    __ profile_call(rbcp);
    
    // 3. 跳转到目标方法
    __ jump_from_interpreted(rbx_method, rdx);
}
```

---

### 5.7 返回指令类 ⬜

```cpp
void TemplateTable::_return(TosState state) {
    // 1. 安全点检查
    __ dispatch_via(vtos, Interpreter::_safept_table.table_for(vtos));
    
    // 2. 如果是同步方法 → 释放锁
    if (method is synchronized) {
        unlock_object(lock_reg);
    }
    
    // 3. JVMTI 方法退出通知
    __ notify_method_exit(...);
    
    // 4. 恢复调用者栈帧
    __ leave();
    
    // 5. 返回
    __ ret(0);
}
```

---

### 5.8 控制流类 ⬜

#### if_icmp (整数比较跳转)

```cpp
void TemplateTable::if_icmp(Condition cc) {
    // 栈: ..., value1, value2
    __ pop_i(rdx);  // value2
    __ pop_i(rax);  // value1
    __ cmpl(rax, rdx);
    branch(cc);  // 条件跳转
}
```

#### goto

```cpp
void TemplateTable::_goto() {
    branch(false, false);  // 无条件跳转
}
```

**后向跳转安全点检查**：
```cpp
void TemplateTable::branch(bool is_jsr, bool is_wide) {
    // 计算跳转偏移
    if (offset < 0) {  // 后向跳转
        // 安全点检查！
        __ dispatch_via(vtos, Interpreter::_safept_table.table_for(vtos));
    }
    // 跳转到目标地址
}
```

---

## 6. G1 屏障集成详解 ⭐⭐⭐

> **详细分析见**: [G1-Barrier-Assembly.md](./G1-Barrier-Assembly.md) - G1 屏障 x86-64 汇编实现完整分析

### 6.1 屏障触发点

| 字节码 | 触发条件 | 屏障类型 |
|--------|----------|----------|
| `aastore` | 存储对象到数组 | 前置 + 后置 |
| `putfield` (引用类型) | 存储对象到字段 | 前置 + 后置 |
| `putstatic` (引用类型) | 存储对象到静态字段 | 前置 + 后置 |

### 6.2 do_oop_store 实现

位置: `src/hotspot/cpu/x86/templateTable_x86.cpp`

```cpp
static void do_oop_store(InterpreterMacroAssembler* _masm,
                         Address dst,
                         Register val,
                         DecoratorSet decorators = 0) {
    __ access_store_at(T_OBJECT, IN_HEAP | decorators, dst, val, ...);
}
```

### 6.3 G1BarrierSetAssembler::store_at

位置: `src/hotspot/cpu/x86/gc/g1/g1BarrierSetAssembler_x86.cpp`

```cpp
void G1BarrierSetAssembler::store_at(MacroAssembler* masm,
                                      DecoratorSet decorators,
                                      BasicType type,
                                      Address dst, Register val,
                                      Register tmp1, Register tmp2) {
    if (type == T_OBJECT || type == T_ARRAY) {
        // 1. SATB 前置屏障
        g1_write_barrier_pre(masm, dst.base(), val, ...);
        
        // 2. 实际存储
        BarrierSetAssembler::store_at(masm, decorators, type, dst, val, ...);
        
        // 3. dirty card 后置屏障
        g1_write_barrier_post(masm, dst, val, ...);
    } else {
        // 非引用类型，不需要屏障
        BarrierSetAssembler::store_at(...);
    }
}
```

### 6.4 g1_write_barrier_pre (SATB 前置屏障)

```cpp
void G1BarrierSetAssembler::g1_write_barrier_pre(MacroAssembler* masm,
                                                  Register obj,
                                                  Register pre_val,
                                                  Register thread,
                                                  Register tmp,
                                                  bool tosca_live,
                                                  bool expand_call) {
    // 伪代码
    // if (SATB marking active) {
    //     old_value = *dst;
    //     if (old_value != NULL) {
    //         enqueue(old_value);  // 加入 SATB 队列
    //     }
    // }
    
    // 1. 检查 SATB 是否激活
    Address in_progress(thread, G1ThreadLocalData::satb_mark_queue_active_offset());
    __ cmpb(in_progress, 0);
    __ jcc(Assembler::equal, done);  // 未激活则跳过
    
    // 2. 读取旧值
    __ movptr(tmp, Address(obj, 0));
    
    // 3. 如果旧值非空，加入 SATB 队列
    __ testptr(tmp, tmp);
    __ jcc(Assembler::zero, done);
    
    // 4. 入队
    // G1ThreadLocalData::satb_mark_queue 操作
    // ...
}
```

### 6.5 g1_write_barrier_post (dirty card 后置屏障)

```cpp
void G1BarrierSetAssembler::g1_write_barrier_post(MacroAssembler* masm,
                                                   Register store_addr,
                                                   Register new_val,
                                                   Register thread,
                                                   Register tmp,
                                                   Register tmp2) {
    // 伪代码
    // if (new_val != NULL) {
    //     if (cross_region(store_addr, new_val)) {
    //         card = card_table[store_addr >> 9];
    //         if (card != dirty) {
    //             card = dirty;
    //             enqueue(card);  // 加入 dirty card 队列
    //         }
    //     }
    // }
    
    // 1. 如果存储的是 NULL，跳过
    __ testptr(new_val, new_val);
    __ jcc(Assembler::zero, done);
    
    // 2. 检查是否跨 Region
    __ xorptr(store_addr, new_val);
    __ shrptr(store_addr, HeapRegion::LogOfHRGrainBytes);
    __ jcc(Assembler::zero, done);  // 同一 Region 则跳过
    
    // 3. 计算 card 地址
    __ shrptr(store_addr, CardTable::card_shift);
    __ addptr(store_addr, card_table_base);
    
    // 4. 检查 card 是否已脏
    __ cmpb(Address(store_addr, 0), CardTable::dirty_card_val());
    __ jcc(Assembler::equal, done);  // 已脏则跳过
    
    // 5. 标记为脏并入队
    __ movb(Address(store_addr, 0), CardTable::dirty_card_val());
    // 入队到 dirty card queue
    // ...
}
```

---

## 7. 字节码分发机制

### 7.1 dispatch_next

执行完当前字节码后，分发到下一个字节码：

```cpp
void InterpreterMacroAssembler::dispatch_next(TosState state, int step) {
    // 1. 更新 bcp (字节码指针)
    __ addptr(rbcp, step);
    
    // 2. 读取下一个字节码
    __ load_unsigned_byte(rbx, Address(rbcp, 0));
    
    // 3. 查表获取入口地址
    // entry = dispatch_table[state][bytecode]
    
    // 4. 跳转到入口
    __ jmp(entry);
}
```

### 7.2 DispatchTable 结构

```cpp
class DispatchTable {
    static const int length = 1 << BitsPerByte;  // 256
    address _table[number_of_states][length];    // [TosState][bytecode]
};
```

**分发表示意**：
```
                    bytecode
                0x00  0x01  0x02  ...  0xFF
              +-----+-----+-----+-----+-----+
    vtos (0)  | nop |iconst_m1|...| ... | ... |
              +-----+-----+-----+-----+-----+
    itos (1)  |  X  |  X  |iadd | ... | ... |
              +-----+-----+-----+-----+-----+
    atos (2)  |  X  |  X  |  X  | ... | ... |
              +-----+-----+-----+-----+-----+
      ...     | ... | ... | ... | ... | ... |
```

---

## 8. 反优化入口 (deopt_entry)

### 8.1 用途

当 JIT 编译的代码需要**反优化** (deoptimization) 时，执行流需要返回到解释器：

```
JIT 编译代码
    ↓
检测到需要反优化（如类加载、异常...）
    ↓
Deoptimization::unpack_frames()
    ↓
跳转到 deopt_entry[tos_state]
    ↓
继续在解释器中执行
```

### 8.2 生成

```cpp
// 为每种 TosState 生成反优化入口
for (int i = 0; i < number_of_deopt_entries; i++) {
    Interpreter::_deopt_entry[i] = EntryPoint(
        generate_deopt_entry_for(btos, i),
        generate_deopt_entry_for(ztos, i),
        // ...
        generate_deopt_entry_for(vtos, i)
    );
}
```

---

## 9. 相关 JVM 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-Xint` | - | 仅使用解释器执行 |
| `-XX:+PrintInterpreter` | false | 打印解释器代码 |
| `-XX:+TraceBytecodes` | false | 追踪字节码执行 |
| `-XX:+CountBytecodes` | false | 统计字节码执行次数 |
| `-XX:+PrintBytecodeHistogram` | false | 打印字节码执行直方图 |

---

## 10. 进度统计

### 已完成 ✅
- [x] **1.0 StubQueue-Layout** - 271 个 Codelet 整体布局
- [x] **2.1 slow_signature_handler** - 慢速签名处理
- [x] **2.2 error_exits** - 错误退出点
- [x] **2.3 return_entry** - 返回入口点
- [x] **2.4 invoke_return_entry** - 调用返回入口
- [x] **2.5 safept_entry** - 安全点入口
- [x] **2.6 throw_exception** - 异常处理
- [x] **2.7 throw_exception_entrypoints** - 6种异常入口
- [x] **3.2 zerolocals (generate_normal_entry)** - 普通方法入口
- [x] **3.3 zerolocals_synchronized** - 同步方法入口
- [x] **3.4 native** - 本地方法入口
- [x] **3.5-3.6 empty/accessor** - 复用 zerolocals
- [x] **3.7 abstract** - 抛出 AbstractMethodError
- [x] **3.8 java_lang_math_*** - Math 内部函数
- [x] **3.9 java_lang_ref_reference_get** - 弱引用处理
- [x] **3.10 CRC32/Float/Double** - 内部函数
- [x] **G1-Barrier-Assembly** - G1 屏障汇编实现

### 新完成 ✅
- [x] **4. 字节码模板生成** → [4.0-bytecode-templates.md](./4.0-bytecode-templates.md)
- [x] **5. 方法调用字节码** → [5.0-invoke-bytecodes.md](./5.0-invoke-bytecodes.md)
- [x] **7. invokedynamic 深入分析** → [7.0-invokedynamic-deep-dive.md](./7.0-invokedynamic-deep-dive.md) ⭐⭐Lambda 和现代 Java 特性的基础
- [x] **8. 反优化入口 (deopt_entry)** → [8.0-deopt_entry.md](./8.0-deopt_entry.md)

---

## 11. 依赖关系

```
gc_barrier_stubs_init()  ──→  interpreter_init()
                               │
codeCache_init() ─────────────→│
                               │
stubRoutines_init1() ─────────→│
                               │
bytecodes_init() ─────────────→│
                               │
                               ↓
                        templateTable_init()
                               │
                               ↓
                        universe2_init()
```

---

## 12. 文件位置索引

| 文件 | 内容 |
|------|------|
| `interpreter/interpreter.cpp` | interpreter_init() |
| `interpreter/templateInterpreter.cpp` | 模板解释器框架 |
| `interpreter/templateInterpreterGenerator.cpp` | generate_all() |
| `cpu/x86/templateInterpreterGenerator_x86.cpp` | x86 方法入口生成 |
| `interpreter/templateTable.cpp` | 字节码模板定义 |
| `cpu/x86/templateTable_x86.cpp` | x86 字节码模板实现 |
| `cpu/x86/gc/g1/g1BarrierSetAssembler_x86.cpp` | G1 屏障汇编 |
| `cpu/x86/frame_x86.hpp` | 栈帧布局定义 |
