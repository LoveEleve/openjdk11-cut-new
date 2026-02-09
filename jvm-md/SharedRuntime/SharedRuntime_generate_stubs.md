# SharedRuntime::generate_stubs() 详细分析

> 文档位置：`jvm-md/SharedRuntime/SharedRuntime_generate_stubs.md`
> 源码位置：`src/hotspot/share/runtime/sharedRuntime.cpp:100`

---

## 1. 功能定位

### 1.1 一句话总结

**`SharedRuntime::generate_stubs()` 是 JVM 的"方法调用调度中心"** —— 它生成处理方法调用解析、内联缓存失效、反优化（deoptimization）和安全点轮询的核心运行时桩代码。

### 1.2 为什么需要这些桩代码？

在 JIT 编译代码的执行过程中，会遇到以下情况需要特殊处理：

| 问题场景 | 需要的桩代码 | 作用 |
|----------|--------------|------|
| **首次方法调用** | `resolve_*_call_blob` | 解析目标方法，填充调用站点 |
| **内联缓存失效** | `ic_miss_blob`, `wrong_method_blob` | 处理多态调用、方法重编译 |
| **编译代码失效** | `deopt_blob` | 从编译代码回退到解释执行 |
| **安全点触发** | `polling_page_*_handler_blob` | 响应 GC、偏向锁撤销等 VM 操作 |

### 1.3 在启动流程中的位置

```
init_globals()
├── codeCache_init()          ← 代码缓存
├── stubRoutines_init1()      ← 基础桩代码
├── universe_init()           ← 创建堆/符号表
├── interpreter_init()        ← 解释器
├── VMRegImpl::set_regName()  ← 寄存器名称（打印 OopMap 需要）
├── SharedRuntime::generate_stubs() ← 【当前分析】方法调用桩
├── universe2_init()          ← 加载原始类
├── javaClasses_init()        ← 字段偏移量
├── ...
└── stubRoutines_init2()      ← 高级桩代码
```

---

## 2. 源码解读

### 2.1 generate_stubs() 完整实现

```cpp
// src/hotspot/share/runtime/sharedRuntime.cpp:100-124
void SharedRuntime::generate_stubs() {
  // ===== 第一组：方法调用解析桩 =====
  _wrong_method_blob = generate_resolve_blob(
      CAST_FROM_FN_PTR(address, SharedRuntime::handle_wrong_method),
      "wrong_method_stub");
      
  _wrong_method_abstract_blob = generate_resolve_blob(
      CAST_FROM_FN_PTR(address, SharedRuntime::handle_wrong_method_abstract),
      "wrong_method_abstract_stub");
      
  _ic_miss_blob = generate_resolve_blob(
      CAST_FROM_FN_PTR(address, SharedRuntime::handle_wrong_method_ic_miss),
      "ic_miss_stub");
      
  _resolve_opt_virtual_call_blob = generate_resolve_blob(
      CAST_FROM_FN_PTR(address, SharedRuntime::resolve_opt_virtual_call_C),
      "resolve_opt_virtual_call");
      
  _resolve_virtual_call_blob = generate_resolve_blob(
      CAST_FROM_FN_PTR(address, SharedRuntime::resolve_virtual_call_C),
      "resolve_virtual_call");
      
  _resolve_static_call_blob = generate_resolve_blob(
      CAST_FROM_FN_PTR(address, SharedRuntime::resolve_static_call_C),
      "resolve_static_call");
      
  _resolve_static_call_entry = _resolve_static_call_blob->entry_point();

  // ===== 第二组：安全点处理桩 =====
#if COMPILER2_OR_JVMCI
  // 向量寄存器保存版本（AVX-512）
  bool support_wide = is_wide_vector(MaxVectorSize);
  if (support_wide) {
    _polling_page_vectors_safepoint_handler_blob = generate_handler_blob(
        CAST_FROM_FN_PTR(address, SafepointSynchronize::handle_polling_page_exception),
        POLL_AT_VECTOR_LOOP);
  }
#endif
  
  _polling_page_safepoint_handler_blob = generate_handler_blob(
      CAST_FROM_FN_PTR(address, SafepointSynchronize::handle_polling_page_exception),
      POLL_AT_LOOP);
      
  _polling_page_return_handler_blob = generate_handler_blob(
      CAST_FROM_FN_PTR(address, SafepointSynchronize::handle_polling_page_exception),
      POLL_AT_RETURN);

  // ===== 第三组：反优化桩 =====
  generate_deopt_blob();

#ifdef COMPILER2
  generate_uncommon_trap_blob();
#endif
}
```

---

## 3. 生成的桩代码详解

### 3.1 桩代码总览

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                     SharedRuntime::generate_stubs() 生成的桩代码              │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                    方法调用解析桩 (RuntimeStub)                      │    │
│  │  ┌───────────────────┬───────────────────────────────────────────┐ │    │
│  │  │ wrong_method_blob │ 处理编译代码调用了错误的方法（重编译后）   │ │    │
│  │  ├───────────────────┼───────────────────────────────────────────┤ │    │
│  │  │ wrong_method_abstract │ 调用了抽象方法                        │ │    │
│  │  ├───────────────────┼───────────────────────────────────────────┤ │    │
│  │  │ ic_miss_blob      │ 内联缓存失效（多态调用）                   │ │    │
│  │  ├───────────────────┼───────────────────────────────────────────┤ │    │
│  │  │ resolve_opt_virtual │ 解析可静态绑定的虚方法                   │ │    │
│  │  ├───────────────────┼───────────────────────────────────────────┤ │    │
│  │  │ resolve_virtual   │ 解析普通虚方法                             │ │    │
│  │  ├───────────────────┼───────────────────────────────────────────┤ │    │
│  │  │ resolve_static    │ 解析静态方法                               │ │    │
│  │  └───────────────────┴───────────────────────────────────────────┘ │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                   安全点处理桩 (SafepointBlob)                       │    │
│  │  ┌───────────────────────────┬───────────────────────────────────┐ │    │
│  │  │ polling_page_safepoint    │ 循环中触发安全点                   │ │    │
│  │  ├───────────────────────────┼───────────────────────────────────┤ │    │
│  │  │ polling_page_return       │ 方法返回时触发安全点               │ │    │
│  │  ├───────────────────────────┼───────────────────────────────────┤ │    │
│  │  │ polling_page_vectors      │ 向量循环中触发（需宽向量支持）     │ │    │
│  │  └───────────────────────────┴───────────────────────────────────┘ │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                    反优化桩 (DeoptimizationBlob)                     │    │
│  │  ┌───────────────────┬───────────────────────────────────────────┐ │    │
│  │  │ deopt_blob        │ 从编译代码反优化回解释器                   │ │    │
│  │  └───────────────────┴───────────────────────────────────────────┘ │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                   不常见陷阱桩 (UncommonTrapBlob) - 仅 C2            │    │
│  │  ┌───────────────────┬───────────────────────────────────────────┐ │    │
│  │  │ uncommon_trap_blob│ 处理 C2 推测性优化失败                     │ │    │
│  │  └───────────────────┴───────────────────────────────────────────┘ │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 方法解析桩 (generate_resolve_blob)

**作用**：当编译代码首次调用某个方法时，调用站点包含一个到 resolve 桩的跳转。这个桩负责：
1. 保存所有寄存器
2. 调用 C++ 运行时解析目标方法
3. 将调用站点修补为直接调用目标方法
4. 跳转到目标方法

**x86_64 实现** (`sharedRuntime_x86_64.cpp:3533`):

```cpp
RuntimeStub* SharedRuntime::generate_resolve_blob(address destination, const char* name) {
  assert(StubRoutines::forward_exception_entry() != NULL, "must be generated before");

  ResourceMark rm;
  CodeBuffer buffer(name, 1000, 512);
  MacroAssembler* masm = new MacroAssembler(&buffer);
  
  OopMapSet *oop_maps = new OopMapSet();
  OopMap* map = NULL;
  int frame_size_in_words;

  // ===== Step 1: 保存所有活跃寄存器 =====
  map = RegisterSaver::save_live_registers(masm, 0, &frame_size_in_words, false);

  // ===== Step 2: 设置 last_Java_frame =====
  __ set_last_Java_frame(noreg, noreg, NULL);

  // ===== Step 3: 调用 C++ 运行时 =====
  __ mov(c_rarg0, r15_thread);          // 参数: JavaThread*
  __ call(RuntimeAddress(destination)); // 调用 resolve_*_call_C()

  // 设置 OopMap（GC 用于扫描栈）
  oop_maps->add_gc_map(__ offset() - start, map);

  // ===== Step 4: 清理并检查异常 =====
  __ reset_last_Java_frame(false);
  
  Label pending;
  __ cmpptr(Address(r15_thread, Thread::pending_exception_offset()), (int32_t)NULL_WORD);
  __ jcc(Assembler::notEqual, pending);

  // ===== Step 5: 获取解析结果并跳转 =====
  // rax = 目标方法入口点
  // rbx = 目标 Method*
  __ get_vm_result_2(rbx, r15_thread);
  __ movptr(Address(rsp, RegisterSaver::rbx_offset_in_bytes()), rbx);
  __ movptr(Address(rsp, RegisterSaver::rax_offset_in_bytes()), rax);

  RegisterSaver::restore_live_registers(masm);
  
  __ jmp(rax);  // 跳转到目标方法！

  // ===== 异常处理路径 =====
  __ bind(pending);
  RegisterSaver::restore_live_registers(masm);
  __ movptr(rax, Address(r15_thread, Thread::pending_exception_offset()));
  __ jump(RuntimeAddress(StubRoutines::forward_exception_entry()));

  return RuntimeStub::new_runtime_stub(name, &buffer, frame_complete, frame_size_in_words, oop_maps, true);
}
```

**执行流程图**：

```
编译代码调用站点
        │
        │ 首次调用（未解析）
        ▼
┌───────────────────────────────────────────────────┐
│           resolve_*_call_blob                      │
│  ┌─────────────────────────────────────────────┐  │
│  │ 1. save_live_registers()                    │  │
│  │    └── 保存 rax, rbx, rcx, rdx, rsi, rdi,   │  │
│  │        r8-r14, xmm0-xmm15                   │  │
│  ├─────────────────────────────────────────────┤  │
│  │ 2. set_last_Java_frame()                    │  │
│  │    └── 设置栈帧信息供 GC 使用               │  │
│  ├─────────────────────────────────────────────┤  │
│  │ 3. call resolve_*_call_C()                  │  │
│  │    └── 进入 VM 运行时解析目标方法           │  │
│  │    └── 修补调用站点                         │  │
│  ├─────────────────────────────────────────────┤  │
│  │ 4. reset_last_Java_frame()                  │  │
│  ├─────────────────────────────────────────────┤  │
│  │ 5. restore_live_registers()                 │  │
│  ├─────────────────────────────────────────────┤  │
│  │ 6. jmp rax (目标方法入口)                   │  │
│  └─────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────┘
        │
        ▼
   目标方法执行
```

### 3.3 C++ 运行时解析函数

```cpp
// 解析虚方法调用
JRT_BLOCK_ENTRY(address, SharedRuntime::resolve_virtual_call_C(JavaThread *thread))
  methodHandle callee_method;
  JRT_BLOCK
    // 核心：调用 resolve_helper 解析方法
    callee_method = SharedRuntime::resolve_helper(thread, 
                                                   true,    // is_virtual
                                                   false,   // is_optimized
                                                   CHECK_NULL);
    thread->set_vm_result_2(callee_method());  // 存储 Method*
  JRT_BLOCK_END
  
  // 返回编译代码入口点
  return callee_method->verified_code_entry();
JRT_END

// 解析静态调用
JRT_BLOCK_ENTRY(address, SharedRuntime::resolve_static_call_C(JavaThread *thread))
  methodHandle callee_method;
  JRT_BLOCK
    callee_method = SharedRuntime::resolve_helper(thread, 
                                                   false,   // is_virtual
                                                   false,   // is_optimized
                                                   CHECK_NULL);
    thread->set_vm_result_2(callee_method());
  JRT_BLOCK_END
  
  return callee_method->verified_code_entry();
JRT_END
```

### 3.4 内联缓存（IC）桩

**什么是内联缓存？**

内联缓存是优化虚方法调用的技术：

```
                     未优化的虚方法调用
                     
调用站点 ──────► 查找 vtable ──────► 目标方法
                    │
                    │ 每次都要查表，慢！
                    ▼
                    
                     内联缓存优化
                     
调用站点 ──────► [缓存: 上次接收者类型 → 目标方法]
    │                    │
    │ 类型匹配？         │ 匹配：直接调用
    │                    │ 不匹配：ic_miss
    ▼                    ▼
```

**IC 状态转换**：

```
┌─────────────┐     首次调用      ┌─────────────┐
│  未初始化   │  ─────────────►  │   单态      │
│ (clean)     │                  │ (monomorphic)│
└─────────────┘                  └──────┬──────┘
                                        │
                              类型改变  │
                                        ▼
                                 ┌─────────────┐
                                 │   多态      │
                                 │(polymorphic)│
                                 └──────┬──────┘
                                        │
                              类型过多  │
                                        ▼
                                 ┌─────────────┐
                                 │   巨态      │
                                 │(megamorphic)│
                                 └─────────────┘
```

**IC Miss 处理**：

```cpp
// ic_miss_blob 调用此函数
methodHandle SharedRuntime::handle_ic_miss_helper(JavaThread *thread, TRAPS) {
  ResourceMark rm(thread);
  CallInfo call_info;
  Bytecodes::Code bc;

  // 查找被调用的方法信息
  Handle receiver = find_callee_info(thread, bc, call_info, CHECK_(methodHandle()));
  
  // 如果方法可以静态绑定，转换为优化调用
  if (call_info.resolved_method()->can_be_statically_bound()) {
    methodHandle callee_method = SharedRuntime::reresolve_call_site(thread, CHECK_(methodHandle()));
    return callee_method;
  }
  
  // 否则更新 IC 或转为巨态调用
  // ...
}
```

### 3.5 反优化桩 (deopt_blob)

**什么时候需要反优化？**

1. **类型推测失败**：C2 假设某个变量是特定类型，结果不是
2. **方法重编译**：代码被替换，需要回退
3. **异常发生**：编译代码中抛出异常
4. **调试触发**：调试器需要单步执行

**反优化流程**：

```
编译代码执行
      │
      │ 触发反优化
      ▼
┌───────────────────────────────────────────────────┐
│                   deopt_blob                       │
│  ┌─────────────────────────────────────────────┐  │
│  │ 1. save_live_registers()                    │  │
│  │    └── 保存所有寄存器状态                   │  │
│  ├─────────────────────────────────────────────┤  │
│  │ 2. fetch_unroll_info()                      │  │
│  │    └── 获取栈展开信息                       │  │
│  │    └── 确定需要创建几个解释器栈帧           │  │
│  ├─────────────────────────────────────────────┤  │
│  │ 3. 弹出编译帧，推入解释器帧                 │  │
│  │    └── 可能需要创建多个帧（内联方法）       │  │
│  ├─────────────────────────────────────────────┤  │
│  │ 4. unpack_frames()                          │  │
│  │    └── 填充解释器帧的局部变量和表达式栈     │  │
│  ├─────────────────────────────────────────────┤  │
│  │ 5. 跳转到解释器继续执行                     │  │
│  └─────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────┘
      │
      ▼
 解释器继续执行
```

**反优化入口点**：

```cpp
// x86_64 deopt_blob 有多个入口点
address start = __ pc();           // 常规反优化入口

int reexecute_offset = ...;        // 重执行入口（重新执行当前 bytecode）

int exception_offset = ...;        // 异常反优化入口

int exception_in_tls_offset = ...; // 异常在 TLS 中的入口
```

### 3.6 安全点处理桩 (polling_page_*_handler_blob)

**安全点轮询机制**：

```
编译代码中:
      │
      │ 循环回边 / 方法返回
      ▼
┌──────────────────────────────────────┐
│  test rax, [polling_page]            │  ← 读取轮询页
│                                      │
│  如果 polling_page 可读：继续执行     │
│  如果 polling_page 不可读：触发 SIGSEGV │
└──────────────────────────────────────┘
      │
      │ SIGSEGV
      ▼
┌──────────────────────────────────────┐
│  信号处理器                          │
│  └── 跳转到 polling_page_handler     │
└──────────────────────────────────────┘
      │
      ▼
┌──────────────────────────────────────┐
│  polling_page_safepoint_handler_blob │
│  ├── save_live_registers()           │
│  ├── call SafepointSynchronize::     │
│  │        handle_polling_page_exception│
│  ├── restore_live_registers()        │
│  └── 返回继续执行                    │
└──────────────────────────────────────┘
```

**三种安全点处理桩的区别**：

| 桩名称 | 触发位置 | 特点 |
|--------|----------|------|
| `polling_page_safepoint_handler` | 循环回边 | 需要保存循环变量 |
| `polling_page_return_handler` | 方法返回 | 需要保存返回值 |
| `polling_page_vectors_safepoint_handler` | 向量循环 | 需要保存宽向量寄存器 |

---

## 4. 类继承关系

```
CodeBlob (代码块基类)
├── BufferBlob          ← I2C/C2I 适配器
├── RuntimeStub         ← resolve_*_blob, ic_miss_blob, wrong_method_blob
├── SingletonBlob
│   ├── DeoptimizationBlob  ← deopt_blob
│   ├── SafepointBlob       ← polling_page_*_handler_blob
│   └── UncommonTrapBlob    ← uncommon_trap_blob (C2 only)
└── CompiledMethod
    └── nmethod         ← JIT 编译的方法
```

---

## 5. 静态变量一览

```cpp
// src/hotspot/share/runtime/sharedRuntime.hpp:53-68
class SharedRuntime: AllStatic {
  // 方法调用解析桩
  static RuntimeStub*        _wrong_method_blob;
  static RuntimeStub*        _wrong_method_abstract_blob;
  static RuntimeStub*        _ic_miss_blob;
  static RuntimeStub*        _resolve_opt_virtual_call_blob;
  static RuntimeStub*        _resolve_virtual_call_blob;
  static RuntimeStub*        _resolve_static_call_blob;
  static address             _resolve_static_call_entry;

  // 反优化桩
  static DeoptimizationBlob* _deopt_blob;

  // 安全点处理桩
  static SafepointBlob*      _polling_page_vectors_safepoint_handler_blob;
  static SafepointBlob*      _polling_page_safepoint_handler_blob;
  static SafepointBlob*      _polling_page_return_handler_blob;

#ifdef COMPILER2
  static UncommonTrapBlob*   _uncommon_trap_blob;
#endif
};
```

---

## 6. GDB 验证

### 6.1 实际 GDB 验证结果

【GDB 验证】条件：-Xms256m -Xmx256m -Xint

```
=== Method Resolution Stubs ===
_wrong_method_blob         = 0x7fffed008190
_ic_miss_blob              = 0x7fffed114090
_resolve_static_call_blob  = 0x7fffed113790
_resolve_virtual_call_blob = 0x7fffed113a90

=== Safepoint Handler Blobs ===
_polling_page_safepoint_handler_blob = 0x7fffed112a90
_polling_page_return_handler_blob    = 0x7fffed112790

=== Deopt Blob ===
_deopt_blob = 0x7fffed113090

=== Disasm resolve_static_call entry ===
0x7fffed113820:  push   %rbp
0x7fffed113821:  mov    %rsp,%rbp
0x7fffed113824:  pushf                          ← 保存标志寄存器
0x7fffed113825:  sub    $0x8,%rsp
0x7fffed113829:  mov    %rsp,-0x28(%rsp)
0x7fffed11382e:  sub    $0x80,%rsp              ← 分配 128 字节栈空间
0x7fffed113835:  mov    %rax,0x78(%rsp)         ← 保存 rax
0x7fffed11383a:  mov    %rcx,0x70(%rsp)         ← 保存 rcx
0x7fffed11383f:  mov    %rdx,0x68(%rsp)         ← 保存 rdx
0x7fffed113844:  mov    %rbx,0x60(%rsp)         ← 保存 rbx
```

### 6.2 验证分析

**关键观察**：

1. **桩代码地址分布**：
   - 所有桩代码都在 `0x7fffed...` 地址范围（CodeCache 区域）
   - `_wrong_method_blob` (0x7fffed008190) 在较低地址
   - 其他桩在 0x7fffed112xxx - 0x7fffed114xxx 范围

2. **resolve_static_call 入口点分析**：
   ```asm
   push   %rbp              ; 保存帧指针
   mov    %rsp,%rbp         ; 建立新帧
   pushf                    ; 保存标志寄存器
   sub    $0x80,%rsp        ; 分配 128 字节保存寄存器
   mov    %rax,0x78(%rsp)   ; 开始保存寄存器
   ```
   这是 `RegisterSaver::save_live_registers()` 生成的代码！

3. **桩代码大小估算**：
   - resolve_static_call: 约 1KB (0x7fffed113790)
   - resolve_virtual_call: 约 1KB (0x7fffed113a90)
   - ic_miss: 约 1KB (0x7fffed114090)
   - deopt_blob: 较大，约 3-4KB

### 6.3 验证脚本

```gdb
# jvm-md/SharedRuntime/gdb_SharedRuntime_generate_stubs.txt

set pagination off
set print pretty on

# 断点设在 generate_stubs 完成后
b init.cpp:132
run -Xms256m -Xmx256m -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# === 方法解析桩 ===
printf "\n========== Method Resolution Stubs ==========\n"
printf "_wrong_method_blob:           %p\n", SharedRuntime::_wrong_method_blob
printf "_wrong_method_abstract_blob:  %p\n", SharedRuntime::_wrong_method_abstract_blob
printf "_ic_miss_blob:                %p\n", SharedRuntime::_ic_miss_blob
printf "_resolve_opt_virtual_call_blob: %p\n", SharedRuntime::_resolve_opt_virtual_call_blob
printf "_resolve_virtual_call_blob:   %p\n", SharedRuntime::_resolve_virtual_call_blob
printf "_resolve_static_call_blob:    %p\n", SharedRuntime::_resolve_static_call_blob
printf "_resolve_static_call_entry:   %p\n", SharedRuntime::_resolve_static_call_entry

# === 安全点处理桩 ===
printf "\n========== Safepoint Handler Blobs ==========\n"
printf "_polling_page_safepoint_handler_blob:  %p\n", SharedRuntime::_polling_page_safepoint_handler_blob
printf "_polling_page_return_handler_blob:     %p\n", SharedRuntime::_polling_page_return_handler_blob
printf "_polling_page_vectors_safepoint_handler_blob: %p\n", SharedRuntime::_polling_page_vectors_safepoint_handler_blob

# === 反优化桩 ===
printf "\n========== Deoptimization Blob ==========\n"
printf "_deopt_blob: %p\n", SharedRuntime::_deopt_blob

# === 不常见陷阱桩 (C2) ===
printf "\n========== Uncommon Trap Blob (C2) ==========\n"
printf "_uncommon_trap_blob: %p\n", SharedRuntime::_uncommon_trap_blob

# === 反汇编 resolve_static_call 入口 ===
printf "\n========== Disasm resolve_static_call entry ==========\n"
x/15i SharedRuntime::_resolve_static_call_entry

quit
```

### 6.2 执行方式

```bash
cd /data/workspace/openjdk-cut-new
gdb -x jvm-md/SharedRuntime/gdb_SharedRuntime_generate_stubs.txt \
    ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java
```

---

## 7. 与其他组件的关系

### 7.1 依赖关系图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        SharedRuntime::generate_stubs()                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│                              依赖                                           │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────────┐      │
│  │ CodeCache    │    │StubRoutines  │    │ VMRegImpl::set_regName() │      │
│  │  (代码缓存)  │    │(forward_     │    │   (寄存器名称)           │      │
│  │              │    │ exception)   │    │                          │      │
│  └──────┬───────┘    └──────┬───────┘    └────────────┬─────────────┘      │
│         │                   │                         │                     │
│         └───────────────────┴─────────────────────────┘                     │
│                             │                                               │
│                             ▼                                               │
│                  SharedRuntime::generate_stubs()                            │
│                             │                                               │
│         ┌───────────────────┼───────────────────┐                          │
│         │                   │                   │                          │
│         ▼                   ▼                   ▼                          │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐                 │
│  │ JIT 编译代码 │    │  解释器      │    │ 信号处理器    │                 │
│  │  (nmethod)   │    │              │    │              │                 │
│  │              │    │              │    │              │                 │
│  │ 调用 resolve │    │ 调用 IC miss │    │ 调用 polling │                 │
│  │    桩        │    │    桩        │    │   page 桩    │                 │
│  └──────────────┘    └──────────────┘    └──────────────┘                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 7.2 方法调用流程

```
Java 方法调用
      │
      │ 首次调用（调用站点未解析）
      ▼
┌──────────────────────────────────────────────────────────────────┐
│  调用站点: call resolve_static_call_blob                         │
│                                                                  │
│  resolve_static_call_blob:                                       │
│    1. save_live_registers()                                      │
│    2. call resolve_static_call_C()  ←── 解析目标方法             │
│       └── 修补调用站点为 call target_method                      │
│    3. restore_live_registers()                                   │
│    4. jmp target_method                                          │
└──────────────────────────────────────────────────────────────────┘
      │
      │ 后续调用（调用站点已修补）
      ▼
┌──────────────────────────────────────────────────────────────────┐
│  调用站点: call target_method  ←── 直接调用，无需再解析          │
└──────────────────────────────────────────────────────────────────┘
```

---

## 8. 设计思考

### 8.1 为什么使用桩代码而不是直接调用 C++ 函数？

| 直接调用 C++ | 使用桩代码 |
|--------------|------------|
| 简单但慢 | 复杂但快 |
| 每次调用都要保存/恢复寄存器 | 只在首次/异常时才保存 |
| 无法修补调用站点 | 可以自我修改，变成直接调用 |
| 需要完整的 C 调用约定 | 可以优化寄存器使用 |

### 8.2 为什么解析桩和 IC 桩是分开的？

- **resolve 桩**：处理首次调用，修补站点后不再使用
- **IC 桩**：处理多态调用，可能被反复调用

### 8.3 为什么有多种安全点处理桩？

不同的安全点位置有不同的寄存器状态：
- 循环中：需要保存循环变量
- 返回时：需要保存返回值
- 向量循环：需要保存 512 位向量寄存器

---

## 9. 总结

### 9.1 核心流程

```
SharedRuntime::generate_stubs()
    │
    ├── [1] 生成方法调用解析桩 (6 个)
    │   ├── wrong_method_blob          ← 处理错误方法调用
    │   ├── wrong_method_abstract_blob ← 处理抽象方法调用
    │   ├── ic_miss_blob               ← 处理内联缓存失效
    │   ├── resolve_opt_virtual_call   ← 解析可静态绑定虚方法
    │   ├── resolve_virtual_call       ← 解析普通虚方法
    │   └── resolve_static_call        ← 解析静态方法
    │
    ├── [2] 生成安全点处理桩 (2-3 个)
    │   ├── polling_page_safepoint_handler   ← 循环中安全点
    │   ├── polling_page_return_handler      ← 返回时安全点
    │   └── polling_page_vectors_handler     ← 向量循环安全点 (可选)
    │
    ├── [3] 生成反优化桩
    │   └── deopt_blob                 ← 从编译代码回退到解释器
    │
    └── [4] 生成不常见陷阱桩 (仅 C2)
        └── uncommon_trap_blob         ← 处理 C2 推测失败
```

### 9.2 生成的桩代码汇总

| 桩代码类型 | 数量 | 存储类型 | 作用 |
|------------|------|----------|------|
| 方法解析桩 | 6 | RuntimeStub | 首次调用方法时解析目标 |
| 安全点桩 | 2-3 | SafepointBlob | 响应 GC、偏向锁等 VM 操作 |
| 反优化桩 | 1 | DeoptimizationBlob | 从编译代码回退到解释器 |
| 不常见陷阱桩 | 1 | UncommonTrapBlob | C2 推测性优化失败处理 |

### 9.3 与前后步骤的关系

```
interpreter_init()                → 解释器就绪
      ↓
VMRegImpl::set_regName()          → 寄存器名称（打印 OopMap 需要）
      ↓
SharedRuntime::generate_stubs()   → 方法调用桩就绪 【当前】
      ↓
universe2_init()                  → 加载原始类
      ↓
JIT 编译                          → 使用这些桩处理调用
```

---

## 10. 下一步建议

1. **深入 generate_deopt_blob()**：理解反优化的完整流程
2. **分析 AdapterHandlerLibrary**：理解 I2C/C2I 适配器
3. **研究 InlineCacheBuffer**：理解内联缓存的修改机制
4. **GDB 验证**：运行脚本验证各桩代码地址

---

> 📅 分析时间：2026-02-06
> 📁 源码版本：OpenJDK 11
