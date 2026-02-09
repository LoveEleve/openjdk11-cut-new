# Ch06: 异常处理机制深度分析 — 从 athrow 到栈展开

> **标准环境**: `-Xms8g -Xmx8g -XX:+UseG1GC`, G1 Region = 4MB
> **源码版本**: OpenJDK 11
> **核心源码**: `interpreterRuntime.cpp`, `sharedRuntime.cpp`, `method.cpp`, `exceptions.cpp`, `os_linux_x86.cpp`

---

## 一、为什么要深入理解异常处理机制？

**一句话**：异常处理是 JVM 中唯一不按"顺序执行"走的控制流，涉及字节码解释器、编译器、操作系统信号、栈帧管理四个维度的协作。

面试高频问题：
- "try-catch 有性能开销吗？" — 零成本异常表模型
- "NullPointerException 是怎么产生的？" — SIGSEGV 信号转换
- "异常找不到 handler 怎么办？" — 栈展开（stack unwinding）
- "编译代码和解释器的异常处理有什么区别？" — ExceptionHandlerTable vs ExceptionTableElement

---

## 二、异常表结构 — 字节码级别

### 2.1 ExceptionTableElement — 异常表条目

> 源码：`constMethod.hpp:109-115`

每个 Java 方法的 Code 属性包含一张异常表，每个条目由 4 个 `u2` 字段组成：

```cpp
class ExceptionTableElement {
 public:
  u2 start_pc;          // try 块起始 BCI（字节码索引），包含
  u2 end_pc;            // try 块结束 BCI，不包含
  u2 handler_pc;        // catch 处理器起始 BCI
  u2 catch_type_index;  // 常量池中的异常类型索引（0 = catch-all/finally）
};
```

这直接对应 JVM 规范中 Class 文件格式的 `exception_table` 结构。核心语义：**当 `[start_pc, end_pc)` 范围内抛出的异常类型是 `catch_type_index` 指定类（或其子类）时，跳转到 `handler_pc` 执行。**

### 2.2 异常表在 ConstMethod 中的存储

异常表**内联嵌入**在 ConstMethod 对象的末尾，通过标志位 `_has_exception_table` (0x0008) 判断是否存在：

```
ConstMethod 内存布局:
┌─────────────────────────────┐
│ ConstMethod 固定字段         │
├─────────────────────────────┤
│ 字节码数据                   │
├─────────────────────────────┤
│ 压缩行号表                   │
├─────────────────────────────┤
│ 局部变量表 + 长度            │ ← 可选
├─────────────────────────────┤
│ ExceptionTableElement[] + 长度│ ← 可选，标志位 0x0008
├─────────────────────────────┤
│ 已检查异常 + 长度            │ ← 可选
├─────────────────────────────┤
│ 方法参数 + 长度              │ ← 可选
├─────────────────────────────┤
│ 泛型签名索引                 │ ← 可选
├─────────────────────────────┤
│ 注解数组指针                 │ ← 可选
└─────────────────────────────┘
```

访问方法：

```cpp
bool has_exception_handler() const { return (_flags & _has_exception_table) != 0; }
int exception_table_length() const;
ExceptionTableElement* exception_table_start() const;
```

### 2.3 ExceptionTable — 轻量封装类

> 源码：`method.hpp:1128-1187`

```cpp
class ExceptionTable : public StackObj {
 private:
  ExceptionTableElement* _table;
  u2  _length;
 public:
  ExceptionTable(const Method* m) {
    if (m->has_exception_handler()) {
      _table = m->exception_table_start();
      _length = m->exception_table_length();
    } else {
      _table = NULL; _length = 0;
    }
  }
  int length() const { return _length; }
  u2 start_pc(int idx) const    { return _table[idx].start_pc; }
  u2 end_pc(int idx) const      { return _table[idx].end_pc; }
  u2 handler_pc(int idx) const  { return _table[idx].handler_pc; }
  u2 catch_type_index(int idx) const { return _table[idx].catch_type_index; }
};
```

栈上分配（StackObj），零成本创建。

### 2.4 Java 示例 → 异常表对应

```java
void example() {
    try {                          // start_pc=0
        riskyMethod();             // bci=2
    } catch (IOException e) {      // end_pc=5, handler_pc=8, catch_type=IOException
        handleIO(e);
    } catch (Exception e) {        // end_pc=5, handler_pc=15, catch_type=Exception
        handleGeneral(e);
    } finally {                    // end_pc=5, handler_pc=22, catch_type=0 (any)
        cleanup();
    }
}
```

对应异常表（异常表顺序就是匹配优先级）：

```
Nr  start_pc  end_pc  handler_pc  catch_type
 0       0       5         8      IOException
 1       0       5        15      Exception
 2       0       5        22      0 (any = finally)
```

---

## 三、异常表查找算法 — fast_exception_handler_bci_for

> 源码：`method.cpp:200-235`

这是异常处理机制的**核心查找函数**，解释器和编译器都使用它：

```cpp
int Method::fast_exception_handler_bci_for(const methodHandle& mh, 
    Klass* ex_klass, int throw_bci, TRAPS) {
  ExceptionTable table(mh());
  int length = table.length();
  constantPoolHandle pool(THREAD, mh->constants());
  
  for (int i = 0; i < length; i++) {
    // 注意：每次迭代重新获取 table（GC 可能移动了 Method 对象）
    ExceptionTable table(mh());
    int beg_bci = table.start_pc(i);
    int end_bci = table.end_pc(i);
    
    // Step 1: 范围检查 — 抛出点是否在 [start_pc, end_pc) 内
    if (beg_bci <= throw_bci && throw_bci < end_bci) {
      int handler_bci = table.handler_pc(i);
      int klass_index = table.catch_type_index(i);
      
      // Step 2: 类型匹配
      if (klass_index == 0) {
        return handler_bci;        // catch_type=0 → finally/catch-all，匹配一切
      } else if (ex_klass == NULL) {
        return handler_bci;        // 异常类未知时匹配任何 handler
      } else {
        // 可能触发类加载！pool->klass_at 会解析常量池中的类引用
        Klass* k = pool->klass_at(klass_index, CHECK_(handler_bci));
        if (ex_klass->is_subtype_of(k)) {
          return handler_bci;      // 异常类 instanceof catch 类型 → 匹配
        }
      }
    }
  }
  return -1;  // 未找到匹配的 handler
}
```

**关键设计要点**：

1. **顺序扫描**：按异常表中的顺序逐条检查，**第一个匹配的就是目标 handler**（与 JVM 规范 §2.10 一致）
2. **范围检查**：左闭右开 `[start_pc, end_pc)`
3. **catch-all 优先**：`catch_type_index == 0` 匹配一切异常，对应 finally 块和 `catch (Throwable)`
4. **可能触发类加载**：`pool->klass_at()` 解析 catch 类型时可能需要加载该类，这就是为什么函数签名有 `TRAPS` 参数
5. **GC 安全**：每次循环迭代都重新构造 `ExceptionTable`（因为 `klass_at` 可能触发 GC 导致 Method 对象移动）

---

## 四、athrow 字节码 — 显式抛出异常

### 4.1 模板注册

> 源码：`templateTable.cpp:452`

```cpp
def(Bytecodes::_athrow, ____|disp|____|____, atos, vtos, athrow, _);
```

- 输入 TOS：`atos`（异常对象引用在 rax）
- 输出 TOS：`vtos`（无返回值，控制流转向异常处理）
- `disp` 标志：改变控制流，不 fall-through

### 4.2 x86 模板实现

> 源码：`templateTable_x86.cpp:4331-4335`

```cpp
void TemplateTable::athrow() {
  transition(atos, vtos);
  __ null_check(rax);                                      // ① 检查异常对象非 null
  __ jump(ExternalAddress(Interpreter::throw_exception_entry()));  // ② 跳转到异常分发入口
}
```

就两条指令。`null_check(rax)` 如果 rax==NULL 会触发 SIGSEGV → NullPointerException（"null 也是异常对象"这种情况也会被正确处理）。

### 4.3 throw_exception_entry — 异常分发入口

> 源码：`templateInterpreterGenerator_x86.cpp:1519-1535`

```
_throw_exception_entry:
  ① verify_oop(rax)                    — 验证异常是有效 oop
  ② mov c_rarg1, rax                   — 异常对象作为参数
  ③ empty_expression_stack()           — 清空操作数栈
  ④ call_VM(rdx, InterpreterRuntime::exception_handler_for_exception, c_rarg1)
     ↓ 返回值:
     rax = handler 入口地址（dispatch_table entry 或 remove_activation_entry）
     rdx = 异常对象（通过 vm_result 传回）
  ⑤ push_ptr(rdx)                     — 异常对象入栈（handler 期望它在栈顶）
  ⑥ jmp(rax)                          — 跳转到 handler
```

**核心**在 Step ④：调用 `InterpreterRuntime::exception_handler_for_exception` 查找当前方法的异常表。返回结果有两种可能：
- **找到 handler** → rax 指向 handler 字节码对应的 dispatch entry，跳过去继续解释执行
- **没找到 handler** → rax = `Interpreter::remove_activation_entry()`，触发栈展开

---

## 五、exception_handler_for_exception — 解释器核心异常分派

> 源码：`interpreterRuntime.cpp:470-611`

这是解释器异常处理的**大脑**，完整流程如下：

```
exception_handler_for_exception(JavaThread* thread, oopDesc* exception)
│
├── Step 1: 获取上下文
│   h_method = 当前方法
│   current_bci = 当前字节码位置
│   h_exception = Handle(exception)
│
├── Step 2: 特殊情况快速退出
│   ├── frames_to_pop_failed_realloc > 0
│   │   （标量替换失败，无条件弹出帧）
│   │   → return Interpreter::remove_activation_entry()
│   └── do_not_unlock_if_synchronized == true
│       （方法尚未正式进入 synchronized 块）
│       → return Interpreter::remove_activation_entry()
│
├── Step 3: 异常表查找（可重试循环）
│   do {
│     should_repeat = false;
│     handler_bci = Method::fast_exception_handler_bci_for(
│                       h_method, h_exception->klass(), current_bci, THREAD);
│
│     if (HAS_PENDING_EXCEPTION) {
│       // 查找过程中触发了新异常（如加载 catch 类型失败）
│       h_exception = Handle(PENDING_EXCEPTION);
│       CLEAR_PENDING_EXCEPTION;
│       if (handler_bci >= 0) {
│         current_bci = handler_bci;  // 从引发二次异常的 handler 位置重新搜索
│         should_repeat = true;
│       }
│     }
│   } while (should_repeat);
│
├── Step 4: JVMTI 通知
│   if (JvmtiExport::can_post_on_exceptions()) {
│     JvmtiExport::post_exception_throw(thread, ...);
│   }
│
├── Step 5a: 找到 handler (handler_bci >= 0)
│   handler_pc = h_method->code_base() + handler_bci;
│   set_bcp_and_mdp(handler_pc, thread);
│   // 从 dispatch_table 获取 handler 字节码的入口点
│   continuation = Interpreter::dispatch_table(vtos)[*handler_pc];
│   // 异常对象通过 vm_result 传回，调用方会 push 到栈顶
│   thread->set_vm_result(h_exception());
│   return continuation;
│
└── Step 5b: 没找到 handler (handler_bci < 0)
    // 或者 reguard_stack 失败
    continuation = Interpreter::remove_activation_entry();
    thread->set_vm_result(h_exception());
    return continuation;
```

**关键设计**：

1. **二次异常重试**：在查找 catch(SomeException e) 时，加载 SomeException 类可能触发新异常（比如 ClassNotFoundException），此时用新异常在已有 handler 位置重新搜索
2. **handler 入口选择**：通过 `dispatch_table(vtos)[*handler_pc]` 跳转。`vtos` 表示此时栈顶状态是 void（异常对象另外通过 push 放入），`*handler_pc` 是 handler 处的第一条字节码操作码
3. **remove_activation_entry**：如果没找到 handler，返回这个入口，在汇编层执行栈展开

---

## 六、栈展开 — remove_activation_entry

### 6.1 remove_activation_entry 入口

> 源码：`templateInterpreterGenerator_x86.cpp:1699-1729`

当前方法找不到 handler 时执行此代码，将异常传递给调用方：

```
_remove_activation_entry:
  ① pop_ptr(rax)                       — 恢复异常对象
  ② mov [thread + vm_result], rax      — 暂存异常对象到线程局部
  
  ③ remove_activation(vtos, rdx,       — 移除当前解释器帧:
       throw_monitor=false,            —   不抛 monitor 异常
       install_monitor=true,           —   安装 IllegalMonitorStateException
       notify_jvmdi=false)             —   不通知 JVMDI
  
  ④ get_vm_result(rax)                 — 从线程恢复异常对象
  ⑤ push(rax)                          — 保存异常
  ⑥ push(rdx)                          — 保存返回地址
  
  ⑦ call SharedRuntime::exception_handler_for_return_address(thread, rdx)
     // 根据返回地址确定调用方的类型和异常入口
  
  ⑧ mov rbx, rax                       — rbx = 调用方的异常处理入口
  ⑨ pop rdx                            — 恢复返回地址
  ⑩ pop rax                            — 恢复异常
  ⑪ jmp rbx                            — 跳转到调用方的异常处理入口
```

### 6.2 remove_activation — 帧移除细节

> 源码：`interp_masm_x86.cpp:953-1059`

移除一个解释器帧时要做的事：

1. **检查 `_do_not_unlock_if_synchronized` 标志**（方法没正式进入，不解锁）
2. **解锁 synchronized 方法的隐式 monitor**（如果有的话）
3. **检查所有 monitor 都已解锁**：遍历所有 `BasicObjectLock`，发现未解锁的会安装 `IllegalMonitorStateException`
4. **恢复调用者帧**：重置 rbp、rsp

### 6.3 跨帧类型的异常路由

> 源码：`sharedRuntime.cpp:455-516`

`exception_handler_for_return_address` 是关键路由函数——根据返回地址（调用者的代码类型）决定异常去哪里：

```
raw_exception_handler_for_return_address(thread, return_address)
  │
  ├── return_address 在编译代码中 (nmethod)
  │   ├── 是 deopt pc → deopt_blob()->unpack_with_exception()
  │   └── 正常       → nm->exception_begin()
  │
  ├── return_address 在 call_stub 中
  │   └── StubRoutines::catch_exception_entry()
  │       → 回到 JavaCalls::call_helper 的 CHECK 宏
  │
  └── return_address 在解释器代码中
      └── Interpreter::rethrow_exception_entry()
          → 在调用者的解释器帧中重新执行异常分派
```

**这就是递归展开的关键**：如果调用者也是解释器帧，会跳到 `rethrow_exception_entry`，重新执行 `exception_handler_for_exception` 在调用者的方法中查找 handler。如果还是没找到，再 `remove_activation` 继续向上展开。如此递归直到找到 handler 或回到 call_stub（JNI 边界）。

### 6.4 栈展开过程图示

```
        栈（高地址→低地址）                   异常传播方向
        
┌──────────────────────────────┐
│    call_stub 帧               │  ← 如果异常传到这里：
│    (JavaCalls::call_helper)   │     catch_exception_entry → 
│                              │     设置 pending_exception → 
│                              │     return 到 C++ (CHECK 宏检查)
├──────────────────────────────┤
│    解释器帧 A (main方法)      │  ← 第二次查找：
│    ExceptionTable: [...]     │     exception_handler_for_exception
│    locals, stack, bcp        │     找到 handler → 跳到 handler_pc
├──────────────────────────────┤     没找到 → remove_activation ↗
│    解释器帧 B (foo方法)       │  ← 第一次查找：
│    ExceptionTable: [空]      │     exception_handler_for_exception
│    locals, stack, bcp        │     没找到 → remove_activation → 
├──────────────────────────────┤     exception_handler_for_return_address
│    解释器帧 C (bar方法)       │     → rethrow_exception_entry ↗
│    ← 异常在这里抛出            │
│    ExceptionTable: [...]     │  ← 最初查找：
│                              │     exception_handler_for_exception
└──────────────────────────────┘     没找到 → remove_activation
```

---

## 七、隐式异常 — SIGSEGV 信号转 NullPointerException

这是整个异常机制中**最精妙的优化**：利用操作系统的内存保护机制实现**零成本的空指针检查**。

### 7.1 原理

```
内存布局:
地址 0x0000_0000 ~ 0x0000_0FFF (4KB)  →  零页，不可读写（OS 保护）

Java 代码: obj.field   (obj == null)
编译后:     mov rax, [rax + field_offset]   (rax == 0)
           → 实际访问: mov rax, [0 + field_offset]
           → 如果 field_offset < 4096，地址在零页内
           → CPU 触发 Page Fault
           → 内核发送 SIGSEGV 信号
           → JVM 信号处理器拦截
           → 转换为 NullPointerException
```

**关键判断**：只有当 field_offset < page_size (通常 4096) 时，才能利用隐式检查。否则需要显式检查。

### 7.2 needs_explicit_null_check — 判断是否需要显式检查

> 源码：`assembler.cpp:300-317`

```cpp
bool MacroAssembler::needs_explicit_null_check(intptr_t offset) {
    // 偏移量在 [0, page_size) 范围内 → 访问 NULL+offset 仍在零页保护区
    // 不需要显式检查，OS 会自动产生 SIGSEGV
    return offset < 0 || os::vm_page_size() <= offset;
}
```

- offset ∈ [0, 4096) → 隐式检查（零成本）
- offset < 0 或 ≥ 4096 → 需要显式 `cmpptr(rax, Address(reg, 0))`

> **实际效果**：Java 对象的绝大多数字段偏移量都小于 4096 字节（一个对象通常不会有上百个字段），所以**绝大多数空指针检查是零成本的**。

### 7.3 null_check 汇编生成

> 源码：`macroAssembler_x86.cpp:3614-3627`

```cpp
void MacroAssembler::null_check(Register reg, int offset) {
  if (needs_explicit_null_check(offset)) {
    // 偏移量超出零页保护区 → 显式检查
    // 通过读取 [reg+0] 来触发 SIGSEGV（如果 reg==NULL）
    cmpptr(rax, Address(reg, 0));
  } else {
    // 什么都不生成！后续的 [reg + offset] 访问
    // 如果 reg==NULL，会自然触发 SIGSEGV → NPE
  }
}
```

**隐式路径完全不生成任何指令**——这就是"零成本"的含义。

### 7.4 SIGSEGV 信号处理完整路径

> 源码：`os_linux_x86.cpp:269-487`

```
CPU: mov rax, [NULL + offset]
  ↓
硬件: Page Fault (地址 0~4095 在零页)
  ↓
Linux 内核: 发送 SIGSEGV
  ↓
JVM_handle_linux_signal(sig=SIGSEGV, info, ucVoid)
  │
  ├── 提取信息:
  │   pc = ucontext_get_pc(uc)        // 故障指令的 PC
  │   addr = info->si_addr             // 故障地址 (0 ~ 4095)
  │
  ├── 检查 1: 栈溢出?
  │   if (thread->on_local_stack(addr))
  │     → 栈溢出处理 (disable_stack_yellow_reserved_zone)
  │
  ├── 检查 2: Safepoint polling?
  │   if (os::is_poll_address(addr))
  │     → SafePoint 处理
  │
  ├── 检查 3: 隐式空指针?
  │   if (!needs_explicit_null_check((intptr_t)addr))
  │     // addr < page_size → 这是 NULL+小偏移 → 空指针解引用！
  │     stub = SharedRuntime::continuation_for_implicit_exception(
  │                thread, pc, IMPLICIT_NULL);
  │
  └── 修改 ucontext:
      ucontext_set_pc(uc, stub);       // 信号返回后跳到 stub
      return true;                      // 信号已处理
```

### 7.5 continuation_for_implicit_exception — 信号到异常的路由

> 源码：`sharedRuntime.cpp:797-964`

```
continuation_for_implicit_exception(thread, pc, IMPLICIT_NULL)
  │
  ├── PC 在解释器代码中:
  │   return Interpreter::throw_NullPointerException_entry()
  │   → generate_exception_handler("java/lang/NullPointerException", NULL)
  │   → InterpreterRuntime::create_exception(...)
  │   → Exceptions::new_exception() 创建 NPE 对象
  │   → jump(throw_exception_entry)
  │   → 走正常的异常分派流程
  │
  ├── PC 在 vtable stub 中:
  │   return StubRoutines::throw_NullPointerException_at_call_entry()
  │
  ├── PC 在 inline-cache 检查中:
  │   return StubRoutines::throw_NullPointerException_at_call_entry()
  │
  └── PC 在编译代码中:
      target_pc = nmethod::continuation_for_implicit_exception(pc)
      → 查 ImplicitExceptionTable
      → 返回编译代码中的异常处理 stub
```

### 7.6 ImplicitExceptionTable — 编译代码的隐式异常映射

> 源码：`exceptionHandlerTable.hpp:132-164`

编译器为每个可能触发隐式异常的指令生成一个 `<故障PC偏移, 续接PC偏移>` 映射：

```cpp
class ImplicitExceptionTable {
  uint _size, _len;
  implicit_null_entry *_data;
  // 存储: [长度] [故障偏移1, 续接偏移1] [故障偏移2, 续接偏移2] ...
public:
  uint at(uint exec_off) const;  // 根据故障PC偏移查找续接PC偏移
};
```

`nmethod::continuation_for_implicit_exception(pc)` (`nmethod.cpp:1983-2009`) 用故障 PC 查找此表，返回续接地址（通常是抛 NPE 的 stub）。

---

## 八、解释器异常类型特定入口点

> 源码：`templateInterpreterGenerator.cpp:175-182`

解释器预先生成了 6 种常见异常的专用入口点：

```cpp
Interpreter::_throw_ArrayIndexOutOfBoundsException_entry = generate_ArrayIndexOutOfBounds_handler();
Interpreter::_throw_ArrayStoreException_entry            = generate_klass_exception_handler("java/lang/ArrayStoreException");
Interpreter::_throw_ArithmeticException_entry            = generate_exception_handler("java/lang/ArithmeticException", "/ by zero");
Interpreter::_throw_ClassCastException_entry             = generate_ClassCastException_handler();
Interpreter::_throw_NullPointerException_entry           = generate_exception_handler("java/lang/NullPointerException", NULL);
Interpreter::_throw_StackOverflowError_entry             = generate_StackOverflowError_handler();
```

每个入口点的通用逻辑：
1. `empty_expression_stack()` — 清空操作数栈
2. 调用 `InterpreterRuntime::create_exception()` / `throw_XXX()` 创建异常对象
3. `jump(throw_exception_entry)` — 跳到统一异常分派入口

### 特殊处理：StackOverflowError

> 源码：`interpreterRuntime.cpp:386-393`

```cpp
IRT_ENTRY(void, InterpreterRuntime::throw_StackOverflowError(JavaThread* thread))
  Handle exception = get_preinitialized_exception(
      SystemDictionary::StackOverflowError_klass(), CHECK);
  Atomic::inc(&Exceptions::_stack_overflow_errors);
  THROW_HANDLE(exception);
IRT_END
```

**使用预分配实例**：因为栈已经溢出，不能再调用构造函数创建新对象，所以 JVM 在启动时预分配了 StackOverflowError 实例。

---

## 九、编译代码的异常处理

### 9.1 编译异常表 — ExceptionHandlerTable

> 源码：`exceptionHandlerTable.hpp:43-129`

编译后代码使用与字节码不同的异常表结构：

```cpp
class HandlerTableEntry {
  int _bci;           // handler 的 BCI（或子表长度）
  int _pco;           // 编译后 handler 的 PC 偏移（相对 nmethod 起始）
  int _scope_depth;   // 内联作用域深度
};
```

组织为子表结构：

```
table    = { subtable }
subtable = header entry { entry }
header   = (条目数, catch_pco, [unused])
entry    = (handler_bci, handler_pco, scope_depth)
```

**查找方法** (`exceptionHandlerTable.cpp:110-120`)：

```cpp
HandlerTableEntry* ExceptionHandlerTable::entry_for(
    int catch_pco, int handler_bci, int scope_depth) const {
  HandlerTableEntry* t = subtable_for(catch_pco);  // 先按 catch_pco 定位子表
  if (t != NULL) {
    int l = t->len();
    while (l-- > 0) {
      t++;
      if (t->bci() == handler_bci && t->scope_depth() == scope_depth)
        return t;  // 匹配!
    }
  }
  return NULL;
}
```

### 9.2 compute_compiled_exc_handler — 编译代码异常查找

> 源码：`sharedRuntime.cpp:633-735`

编译代码的异常查找比解释器复杂，因为需要处理**方法内联**：

```
compute_compiled_exc_handler(nm, ret_pc, exception, ...)
  │
  ├── sd = nm->scope_desc_at(ret_pc)       // 获取作用域描述符
  │   bci = sd->bci()                       // 当前 BCI
  │   scope_depth = 0
  │
  ├── 循环: 遍历内联的作用域链
  │   do {
  │     handler_bci = Method::fast_exception_handler_bci_for(mh, ek, bci, THREAD)
  │     // ↑ 使用同一个查找算法！
  │     
  │     if (handler_bci < 0 && !top_frame_only) {
  │       sd = sd->sender()     // 沿内联链向外走
  │       bci = sd->bci()
  │       scope_depth++
  │     }
  │   } while (handler_bci < 0 && sd != NULL)
  │
  ├── 在 ExceptionHandlerTable 中查找编译后的 handler PC
  │   t = table.entry_for(catch_pco, handler_bci, scope_depth)
  │   return nm->code_begin() + t->pco()
  │
  └── C1 后备:
      if (t == NULL && nm->is_compiled_by_c1())
        return nm->unwind_handler_begin()   // C1 的展开代码
```

**关键差异**：
- **内联处理**：通过 ScopeDesc 链遍历多层内联作用域，用 `scope_depth` 区分不同层次
- **两级查找**：先用字节码级的 `fast_exception_handler_bci_for` 找到逻辑 handler，再用 `ExceptionHandlerTable::entry_for` 映射到机器码偏移

### 9.3 C2 的异常缓存优化

> 源码：`runtime.cpp:1269-1381`

C2 编译器额外维护**异常缓存**来加速热点异常路径：

```cpp
// OptoRuntime::handle_exception_C_helper
handler_address = nm->handler_for_exception_and_pc(exception, pc);

if (handler_address == NULL) {
  // 缓存未命中 → 完整查找
  handler_address = SharedRuntime::compute_compiled_exc_handler(nm, pc, exception, ...);
  // 缓存结果
  nm->add_handler_for_exception_and_pc(exception, pc, handler_address);
}
```

这意味着**同一位置抛出相同类型的异常，第二次开始就能命中缓存**，省去了异常表查找的开销。

### 9.4 ExceptionBlob — C2 异常处理 Blob

> 源码：`sharedRuntime_x86_64.cpp:3903-4005`

C2 编译代码的异常入口点（`nm->exception_begin()` 跳到这里）：

```
ExceptionBlob:
  ① 保存 exception oop 和 pc 到线程:
     mov [r15_thread + exception_oop_offset], rax
     mov [r15_thread + exception_pc_offset], rdx
  
  ② 调用 OptoRuntime::handle_exception_C(thread)
     → 查异常缓存 / 计算 handler / 缓存结果
  
  ③ 从线程取回 exception_oop 和 exception_pc
  
  ④ jmp handler_address
```

---

## 十、C++ 层的异常机制 — THROW 宏与 CHECK 宏

### 10.1 为什么不使用 C++ 异常？

`exceptions.hpp` 注释（第 34-35 行）：

> *"We do not use C++ exceptions to avoid compiler dependencies and unpredictable performance."*

HotSpot 选择自己实现异常传播，原因：
1. C++ 异常的性能不可预测（不同编译器实现差异很大）
2. 避免编译器依赖（Itanium ABI vs SJLJ vs SEH）
3. HotSpot 需要精确控制栈展开过程（GC、JIT 反优化等需要参与）

### 10.2 ThreadShadow — 异常状态的存储

> 源码：`exceptions.hpp:60-95`

```cpp
class ThreadShadow: public CHeapObj<mtThread> {
 protected:
  oop  _pending_exception;       // 待处理的异常对象
  const char* _exception_file;   // 抛出异常的源文件（调试用）
  int         _exception_line;   // 抛出异常的行号（调试用）
 public:
  bool has_pending_exception() const { return _pending_exception != NULL; }
  void set_pending_exception(oop exception, const char* file, int line);
  void clear_pending_exception();
};
```

`ThreadShadow` 是 `Thread` 的基类，所有 JVM 线程都携带 `_pending_exception` 字段。

### 10.3 编译代码专用：_exception_oop / _exception_pc

> 源码：`thread.hpp:1115-1121`

```cpp
volatile oop     _exception_oop;            // 编译代码中抛出的异常对象
volatile address _exception_pc;             // 异常发生的 PC
volatile address _exception_handler_pc;     // handler 的 PC
volatile int     _is_method_handle_return;  // 是否 MethodHandle 调用点
```

注释明确说明：**`_exception_oop` 不是 `_pending_exception`**。它仅用于编译代码运行时异常处理过程中，在 stub 和运行时函数之间临时传递值。

### 10.4 THROW 宏体系

> 源码：`exceptions.hpp:241-294`

```cpp
#define THROW_OOP(e)                 \
  { Exceptions::_throw_oop(THREAD_AND_LOCATION, e); return; }

#define THROW(name)                  \
  { Exceptions::_throw_msg(THREAD_AND_LOCATION, name, NULL); return; }

#define THROW_MSG(name, message)     \
  { Exceptions::_throw_msg(THREAD_AND_LOCATION, name, message); return; }

#define THROW_MSG_0(name, message)   \
  { Exceptions::_throw_msg(THREAD_AND_LOCATION, name, message); return 0; }
```

**核心设计**：每个 THROW 宏包含 `return`。先调用 `Exceptions::_throw_xxx` 设置 `_pending_exception`，然后**强制当前函数返回**。

### 10.5 CHECK 宏 — 异常传播的关键

> 源码：`exceptions.hpp:220-226`

```cpp
#define CHECK       THREAD); if (HAS_PENDING_EXCEPTION) return       ; (void)(0
#define CHECK_(r)   THREAD); if (HAS_PENDING_EXCEPTION) return r     ; (void)(0
#define CHECK_0     CHECK_(0)
#define CHECK_NULL  CHECK_(NULL)
```

**工作方式**：在函数调用 `foo(arg1, arg2, CHECK)` 中展开后变成：

```cpp
foo(arg1, arg2, THREAD); if (HAS_PENDING_EXCEPTION) return; (void)(0)
```

即：将 THREAD 作为最后一个参数传给 foo，然后检查异常。如果有异常，**立即返回**（不执行后续代码）。

这就是 HotSpot C++ 层异常传播的核心机制：**不是 throw/catch，而是 set pending + check + return**。

### 10.6 Exceptions::_throw — 核心实现

> 源码：`exceptions.cpp:133-170`

```cpp
void Exceptions::_throw(Thread* thread, const char* file, int line, 
                        Handle h_exception, const char* message) {
  // 1. 日志追踪
  log_info(exceptions)("Exception <%s> thrown [%s, line %d]", ...);
  
  // 2. AbortVMOnException 检查（调试参数）
  Exceptions::debug_check_abort(h_exception, message);
  
  // 3. 特殊处理（VM 线程/不能调用 Java 的线程）
  if (special_exception(thread, file, line, h_exception)) return;
  
  // 4. OOM/LinkageError 统计
  if (h_exception->is_a(SystemDictionary::OutOfMemoryError_klass()))
    count_out_of_memory_exceptions(h_exception);
  
  // 5. *** 核心：设置 pending exception ***
  thread->set_pending_exception(h_exception(), file, line);
  
  // 6. 事件日志
  Events::log_exception(thread, ...);
}
```

### 10.7 Exceptions::new_exception — 创建异常对象

> 源码：`exceptions.cpp:257-284`

```
new_exception(thread, name, message, cause, loader, protection_domain)
  ↓
  ① SystemDictionary::resolve_or_fail(name, ...)  — 解析异常类
  ② JavaCalls::construct_new_instance(klass, signature, args, thread)
     — 分配实例 + 调用 <init> 构造方法
  ③ 如果构造过程中发生了另一个异常，使用那个异常
  ④ return h_exception
```

---

## 十一、StubRoutines 异常转发

### 11.1 generate_forward_exception

> 源码：`stubGenerator_x86_64.cpp:495-551`

当 JNI 调用或运行时 stub 返回后发现有 pending exception 时执行：

```
forward_exception_entry:
  ① movptr(c_rarg0, Address(rsp, 0))     — 取返回地址 (= throwing pc)
  ② call SharedRuntime::exception_handler_for_return_address(thread, c_rarg0)
     → 确定应该跳到哪个异常处理器
  ③ mov rbx, rax                          — handler address
  ④ pop rdx                               — throwing pc
  ⑤ movptr(rax, [thread + pending_exception])  — 取异常对象
  ⑥ movptr([thread + pending_exception], NULL)  — 清除 pending_exception
  ⑦ jmp rbx                               — 跳到处理器
```

### 11.2 generate_catch_exception — call_stub 异常捕获

> 源码：`stubGenerator_x86_64.cpp:440-482`

当 Java 方法抛出未捕获的异常，传播到 call_stub 的返回地址时：

```
catch_exception_entry:
  ① movptr([thread + pending_exception], rax)  — 设置 pending_exception
  ② lea(rscratch1, ExternalAddress(__FILE__))
     movptr([thread + exception_file], rscratch1)
     movl([thread + exception_line], __LINE__)    — 设置调试信息
  ③ jump(StubRoutines::_call_stub_return_address) — 回到 call_stub 返回点
```

这样异常就从汇编 stub 传回了 `JavaCalls::call_helper` 的 CHECK 宏处，C++ 代码检测到 `has_pending_exception() == true`，函数返回。

---

## 十二、零成本异常处理模型 — try-catch 到底有没有性能开销？

### 12.1 异常表驱动 vs setjmp/longjmp

HotSpot 采用 **table-driven** 异常处理模型：

| 方面 | Table-driven (HotSpot) | setjmp/longjmp |
|------|------------------------|----------------|
| try 块进入 | **零成本**：无任何额外指令 | 每次进入调用 setjmp 保存寄存器 |
| 正常路径 | **零成本**：异常表是纯元数据 | setjmp 返回值检查 |
| 异常路径 | 查表 + 栈展开（较慢） | longjmp 恢复上下文（较快） |
| 内存开销 | 异常表 + handler 表占 nmethod 空间 | setjmp buffer 占栈空间 |

**结论**：正常路径（没有异常抛出）**完全零成本**。异常表是静态数据，正常执行时不被访问。代价全部转移到了异常路径上。

### 12.2 各层的实际开销

| 场景 | 开销 |
|------|------|
| try 块进入，无异常 | **0**。没有任何指令 |
| try 块进入，有异常 | 异常表扫描 O(n)，n = catch 子句数 |
| 空指针检查（隐式） | **0**。不生成检查指令 |
| 空指针异常（触发） | SIGSEGV → 信号处理 → 异常创建 → 表查找（**很慢**，约 ~10μs） |
| CHECK 宏检查 | 1 个条件分支（分支预测准确率 > 99.99%，接近零） |
| 编译代码二次异常查找 | **0**（命中异常缓存） |

### 12.3 面试结论

> **try-catch 本身没有运行时开销**。JVM 采用异常表驱动的零成本模型，try 块的进入和退出不产生任何指令。性能开销只在**抛出异常时**才存在，包括：异常对象创建（涉及栈帧遍历填充 stackTrace）、异常表查找、可能的栈展开。因此，**不应该用异常来控制正常的业务逻辑流**（如 Effective Java 条款 69），但 try-catch 包裹正常代码不会有任何性能影响。

---

## 十三、JVM 参数与日志

### 13.1 异常相关日志

```bash
# 查看所有异常的抛出（包括被 catch 的）
-Xlog:exceptions=info
# 输出示例:
# [info][exceptions] Exception <java.io.FileNotFoundException: /tmp/test.txt (No such file or directory)>
#  thrown [/data/.../os_linux.cpp, line 2648]

# 查看异常创建详情
-Xlog:exceptions=debug

# 如果异常太多，只看特定类型
-Xlog:exceptions=info -XX:AbortVMOnException=java.lang.StackOverflowError
# ↑ 当指定异常被抛出时 abort VM（调试用）
```

### 13.2 隐式异常相关参数

```bash
# 关闭隐式空检查（强制所有空检查都用显式指令）
-XX:-ImplicitNullChecks
# 默认开启。关闭后每次字段访问都会生成 test + jz 指令

# 查看 SIGSEGV 信号处理日志
-XX:+TraceTraps
```

---

## 十四、面试高频问题

### Q1: try-catch 有性能开销吗？

**答**：try-catch 块本身**没有任何运行时开销**。HotSpot 采用异常表驱动（table-driven）的零成本异常处理模型。异常表是方法元数据的一部分，try 块的进入和退出不生成任何指令。

性能开销只在**抛出异常时**才存在：
1. 异常对象创建：`new XXXException()` 会遍历栈帧填充 `stackTrace`（约 1-10μs）
2. 异常表查找：O(n) 扫描，n = catch 子句数
3. 栈展开：如果当前方法没有 handler，需要逐帧回退

### Q2: NullPointerException 是怎么产生的？

**答**：分两种路径：

**隐式路径（99% 的情况）**：当 `obj == null` 且字段偏移 < 4096 时，访问 `obj.field` 实际上是访问 `[0 + offset]`，落入操作系统的零页保护区。CPU 触发 Page Fault，内核发送 SIGSEGV 信号。JVM 的信号处理器 `JVM_handle_linux_signal` 拦截该信号，判断 `si_addr < page_size`，通过修改 ucontext 中的 PC 让信号返回后跳到 `throw_NullPointerException_entry`，创建 NPE 对象并进入正常异常分派流程。

**显式路径**：当字段偏移 ≥ 4096 或需要强制检查时，编译器生成 `cmpptr rax, [reg+0]` 指令，如果 reg==NULL 也会触发 SIGSEGV 走同样的路径。

### Q3: 异常找不到 catch 怎么办？

**答**：当前帧的异常表没有匹配的 handler → `remove_activation_entry` → 释放当前帧（解锁 monitor、恢复 caller 帧）→ `SharedRuntime::exception_handler_for_return_address` 根据返回地址判断 caller 类型 → 跳到 caller 的异常处理入口。如果 caller 是解释器帧，就在 caller 方法中重新查异常表。如此递归，直到找到 handler 或回到 `call_stub`（JNI 边界）。

### Q4: 编译代码和解释器的异常处理有什么区别？

**答**：核心查找算法相同（都用 `Method::fast_exception_handler_bci_for`），但编译代码额外增加了三个维度：
1. **内联处理**：通过 ScopeDesc 链遍历内联的多层作用域（解释器没有内联）
2. **两级映射**：先找到逻辑 handler BCI，再通过 ExceptionHandlerTable 映射到机器码偏移
3. **异常缓存**：C2 缓存 `<异常类型, PC> → handler` 映射，相同异常第二次命中直接返回

### Q5: finally 块是如何实现的？

**答**：在字节码层面，finally 块通过 `catch_type_index = 0` 的异常表条目实现——匹配所有异常类型。Java 编译器（javac）会把 finally 块的代码复制到 try 块正常退出路径和所有 catch 块的末尾，并额外生成一个 catch-all（catch_type=0）条目来处理未被 catch 的异常。catch-all handler 中会先执行 finally 代码，然后 `athrow` 重新抛出异常。

---

## 十五、源文件索引

### 异常表结构

| 文件 | 行号 | 关键内容 |
|------|------|---------|
| `share/oops/constMethod.hpp` | 109-115 | ExceptionTableElement 结构定义（start_pc/end_pc/handler_pc/catch_type_index） |
| `share/oops/method.hpp` | 1128-1187 | ExceptionTable 封装类 |
| `share/oops/method.cpp` | 200-235 | fast_exception_handler_bci_for 查找算法 |
| `share/code/exceptionHandlerTable.hpp` | 43-129 | HandlerTableEntry + ExceptionHandlerTable（编译代码异常表） |
| `share/code/exceptionHandlerTable.hpp` | 132-164 | ImplicitExceptionTable（隐式异常映射表） |
| `share/code/exceptionHandlerTable.cpp` | 110-120 | entry_for 查找实现 |

### athrow 字节码与解释器异常处理

| 文件 | 行号 | 关键内容 |
|------|------|---------|
| `share/interpreter/templateTable.cpp` | 452 | athrow 模板注册 |
| `cpu/x86/templateTable_x86.cpp` | 4331-4335 | athrow x86 实现（null_check + jump） |
| `share/interpreter/bytecodeInterpreter.cpp` | 2734-2740 | athrow C++ 解释器实现 |
| `share/interpreter/interpreterRuntime.cpp` | 470-611 | exception_handler_for_exception 核心分派 |
| `share/interpreter/interpreterRuntime.cpp` | 386-393 | throw_StackOverflowError（预分配实例） |
| `share/interpreter/interpreterRuntime.cpp` | 406-460 | create_exception, throw_ArrayIndexOutOfBounds, throw_ClassCastException |
| `share/interpreter/templateInterpreterGenerator.cpp` | 175-182 | 6 种异常入口点注册 |

### 解释器汇编入口点

| 文件 | 行号 | 关键内容 |
|------|------|---------|
| `cpu/x86/templateInterpreterGenerator_x86.cpp` | 1509 | _rethrow_exception_entry |
| `cpu/x86/templateInterpreterGenerator_x86.cpp` | 1519 | _throw_exception_entry |
| `cpu/x86/templateInterpreterGenerator_x86.cpp` | 1699 | _remove_activation_entry |
| `cpu/x86/interp_masm_x86.cpp` | 953-1059 | remove_activation 帧移除 |

### 信号处理与隐式异常

| 文件 | 行号 | 关键内容 |
|------|------|---------|
| `os_cpu/linux_x86/os_linux_x86.cpp` | 269-487 | JVM_handle_linux_signal（SIGSEGV → NPE） |
| `os/linux/os_linux.cpp` | 631, 5421 | SIGSEGV 信号安装 |
| `share/runtime/sharedRuntime.cpp` | 797-964 | continuation_for_implicit_exception |
| `cpu/x86/macroAssembler_x86.cpp` | 3614-3627 | null_check 汇编生成 |
| `share/asm/assembler.cpp` | 300-317 | needs_explicit_null_check 判断逻辑 |
| `share/code/nmethod.cpp` | 1983-2009 | nmethod::continuation_for_implicit_exception |

### 编译代码异常处理

| 文件 | 行号 | 关键内容 |
|------|------|---------|
| `share/runtime/sharedRuntime.cpp` | 455-516 | raw_exception_handler_for_return_address（跨帧路由） |
| `share/runtime/sharedRuntime.cpp` | 633-735 | compute_compiled_exc_handler（内联作用域遍历） |
| `share/opto/runtime.cpp` | 1269-1423 | handle_exception_C（C2 异常入口 + 缓存） |
| `cpu/x86/sharedRuntime_x86_64.cpp` | 3903-4005 | ExceptionBlob 生成 |

### C++ 层异常机制

| 文件 | 行号 | 关键内容 |
|------|------|---------|
| `share/utilities/exceptions.hpp` | 60-95 | ThreadShadow（_pending_exception） |
| `share/utilities/exceptions.hpp` | 220-226 | CHECK / CHECK_NULL 宏 |
| `share/utilities/exceptions.hpp` | 241-294 | THROW / THROW_MSG 宏 |
| `share/utilities/exceptions.cpp` | 133-170 | Exceptions::_throw 核心实现 |
| `share/utilities/exceptions.cpp` | 257-284 | Exceptions::new_exception 创建异常对象 |
| `share/runtime/thread.hpp` | 1115-1121 | _exception_oop/_exception_pc（编译代码专用） |
| `share/runtime/javaCalls.cpp` | 339-473 | JavaCalls::call / call_helper |

### StubRoutines 异常转发

| 文件 | 行号 | 关键内容 |
|------|------|---------|
| `cpu/x86/stubGenerator_x86_64.cpp` | 440-482 | generate_catch_exception（call_stub 异常捕获） |
| `cpu/x86/stubGenerator_x86_64.cpp` | 495-551 | generate_forward_exception（异常转发 stub） |

---

*最后更新: 2026-02-08*
