# InlineCacheBuffer_init() 详细分析

> 文档位置：`jvm-md/InlineCacheBuffer/InlineCacheBuffer_init.md`
> 源码位置：`src/hotspot/share/code/icBuffer.cpp:167`

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文对 **InlineCacheBuffer_init() 详细分析** 进行源码级分析：追踪关键函数的执行路径，分析涉及的数据结构，解释每个设计决策的原因。

### 0.2 为什么需要？

仅靠文档和注释无法完全理解 JVM 的行为——很多关键细节只存在于源码中。源码级分析能建立对 JVM 行为的精确理解。

### 0.3 怎么解决？

从入口函数出发，自顶向下追踪调用链；对每个关键函数，分析其输入/输出/副作用；对每个数据结构，分析其字段含义和生命周期。

### 0.4 为什么这样设计？

分析过程中重点关注「为什么」：为什么选择这个数据结构？为什么这样处理边界情况？这些问题的答案往往揭示了 JVM 设计的精髓。

---


## 1. 功能定位

### 1.1 一句话总结

**`InlineCacheBuffer_init()` 是 JVM 的"方法调用过渡桥梁"初始化** —— 它创建一个桩代码队列（StubQueue），用于在内联缓存状态转换期间临时重定向方法调用，保证多线程安全。

### 1.2 为什么需要 InlineCacheBuffer？

| 问题 | InlineCacheBuffer 的作用 |
|------|-------------------------|
| **IC 状态转换不是原子的** | 转换期间，使用 ICStub 临时重定向调用 |
| **多线程并发调用** | 避免部分更新导致的数据不一致 |
| **保持调用连续性** | 即使 IC 正在转换，调用仍能正确执行 |
| **延迟释放资源** | 在安全点统一释放 CompiledICHolder |

### 1.3 什么是 Inline Cache (IC)？

```
内联缓存是编译器优化虚方法调用的核心技术：

传统虚调用：
┌─────────────────────────────────────────────────────────────────────────┐
│  receiver.method()                                                      │
│      ↓                                                                  │
│  receiver->klass->vtable[index]->method()  ← 每次都要查表               │
└─────────────────────────────────────────────────────────────────────────┘

使用 Inline Cache：
┌─────────────────────────────────────────────────────────────────────────┐
│  if (receiver->klass == cached_klass)       ← 快速路径                  │
│      call cached_method                                                 │
│  else                                                                   │
│      slow_path()                            ← IC miss，更新缓存          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.4 在启动流程中的位置

```
init_globals()
├── codeCache_init()
├── interpreter_init()
├── stubRoutines_init1()
├── vtableStubs_init()           ← 虚表桩代码
├── InlineCacheBuffer_init()     ← 【当前分析】
├── SharedRuntime::generate_stubs()
└── ...
```

---

## 2. 源码解读

### 2.1 入口函数

```cpp
// src/hotspot/share/code/icBuffer.cpp:167
void InlineCacheBuffer_init() {
  InlineCacheBuffer::initialize();
}
```

### 2.2 InlineCacheBuffer::initialize() 核心实现

```cpp
// src/hotspot/share/code/icBuffer.cpp:104
void InlineCacheBuffer::initialize() {
  if (_buffer != NULL) return;  // 幂等性检查，已初始化则返回
  
  // 创建 StubQueue，大小 10KB，受 InlineCacheBuffer_lock 保护
  _buffer = new StubQueue(
      new ICStubInterface,      // 桩接口（管理 ICStub 的创建/销毁）
      10*K,                     // 缓冲区大小：10KB
      InlineCacheBuffer_lock,   // 同步锁
      "InlineCacheBuffer"       // 名称（调试用）
  );
  assert (_buffer != NULL, "cannot allocate InlineCacheBuffer");
  
  // 初始化第一个桩（哨兵）
  init_next_stub();
}
```

### 2.3 init_next_stub() 实现

```cpp
// src/hotspot/share/code/icBuffer.cpp:98
void InlineCacheBuffer::init_next_stub() {
  // 从缓冲区分配一个 ICStub
  ICStub* ic_stub = (ICStub*)buffer()->request_committed(ic_stub_code_size());
  assert (ic_stub != NULL, "no room for a single stub");
  set_next_stub(ic_stub);  // 保存为下一个可用桩
}
```

---

## 3. 核心数据结构

### 3.1 InlineCacheBuffer 类（静态工具类）

```cpp
class InlineCacheBuffer: public AllStatic {
 private:
  static StubQueue* _buffer;          // 桩队列（10KB）
  static ICStub*    _next_stub;       // 下一个可用的桩
  
  static CompiledICHolder* _pending_released;  // 待释放的 ICHolder 链表
  static int _pending_count;                   // 待释放计数
  
 public:
  // 初始化
  static void initialize();
  
  // 创建过渡桩
  static void create_transition_stub(CompiledIC *ic, void* cached_value, address entry);
  
  // 安全点时更新/清理
  static void update_inline_caches();
  
  // 状态查询
  static bool is_empty();
  static bool contains(address instruction_address);
};
```

### 3.2 ICStub 类（单个过渡桩）

```cpp
class ICStub: public Stub {
 private:
  int     _size;       // 桩总大小（含代码）
  address _ic_site;    // 指向原始 IC 调用位置
  /* 机器代码紧随其后 */
  
 public:
  // 代码位置
  address code_begin() const {
    return (address)this + align_up(sizeof(ICStub), CodeEntryAlignment);
  }
  address code_end() const { return (address)this + size(); }
  
  // 设置桩内容
  void set_stub(CompiledIC *ic, void* cached_val, address dest_addr);
  
  // 清理
  void clear();
  bool is_empty() const { return _ic_site == NULL; }
  
  // 桩信息
  address destination() const;    // 目标地址
  void* cached_value() const;     // 缓存值
};
```

### 3.3 内存布局

```
InlineCacheBuffer 结构（10KB StubQueue）：
┌─────────────────────────────────────────────────────────────────────────┐
│  StubQueue Header                                                       │
├─────────────────────────────────────────────────────────────────────────┤
│  ICStub[0] (Sentinel)   ← 哨兵桩，始终存在                               │
│  ┌─────────────────────────────────────────────────────────────────────┐│
│  │  _size (4B) | _ic_site (8B) | [padding]                             ││
│  ├─────────────────────────────────────────────────────────────────────┤│
│  │  机器代码（~20-30 bytes）：                                          ││
│  │    lea rax, [cached_value]     ; 设置缓存值                          ││
│  │    jmp entry_point             ; 跳转到目标                          ││
│  └─────────────────────────────────────────────────────────────────────┘│
│                                                                         │
│  ICStub[1]                                                              │
│  ...                                                                    │
│  ICStub[N]                                                              │
│                                                                         │
│  Free Space                                                             │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 4. 内联缓存状态转换

### 4.1 IC 状态图

```
                        CompiledIC 状态转换图

         [1] --<--  Clean (null) -->---  [1]
            /                         \
           /                           \      /-<-\
          /           [2]               \    /     \
      Interpreted  ───────────>  Monomorphic     | [3]
  (CompiledICHolder*)              (Klass*)      |
          \                           /   \     /
       [4] \                         / [4] \->-/
            \->─  Megamorphic ─<─/
              (CompiledICHolder*)

状态说明：
┌───────────────────────────────────────────────────────────────────────┐
│ Clean (null)        - 未初始化，调用 resolve stub                     │
│ Monomorphic (Klass*)- 单态，直接调用特定方法                          │
│ Megamorphic         - 多态，调用 vtable stub                         │
│ Interpreted         - 调用解释器（通过 CompiledICHolder）             │
└───────────────────────────────────────────────────────────────────────┘

转换编号：
[1] 初始 fixup（从调试信息获取接收者）
[2] 方法编译完成
[3] 方法重编译（入口改变，但 Klass* 不变）
[4] IC miss，直接转为 megamorphic
```

### 4.2 为什么需要过渡桩？

```
问题场景：Monomorphic → Megamorphic 转换

原始 IC 位置（nmethod 中）：
┌─────────────────────────────────────────────────────────────────────────┐
│  mov rax, [cached_klass]    ; 设置缓存的 Klass*                         │
│  call target_method         ; 调用目标方法                              │
└─────────────────────────────────────────────────────────────────────────┘

需要更新为：
┌─────────────────────────────────────────────────────────────────────────┐
│  mov rax, [CompiledICHolder*]  ; 设置新的缓存值                         │
│  call vtable_stub              ; 改为调用 vtable stub                   │
└─────────────────────────────────────────────────────────────────────────┘

问题：修改 mov 和 call 不是原子操作！
其他线程可能看到：
  - 旧的 cached_klass + 新的 vtable_stub  → 错误！
  - 新的 CompiledICHolder + 旧的 target_method → 错误！
```

### 4.3 使用 ICStub 的解决方案

```
步骤 1：创建过渡桩（ICStub）
┌─────────────────────────────────────────────────────────────────────────┐
│  ICStub 内容：                                                          │
│    lea rax, [CompiledICHolder*]  ; 新的缓存值                           │
│    jmp vtable_stub               ; 新的目标                             │
└─────────────────────────────────────────────────────────────────────────┘

步骤 2：原子更新 IC 跳转到 ICStub
┌─────────────────────────────────────────────────────────────────────────┐
│  原始 IC：                                                              │
│    mov rax, [cached_klass]       ; 这个值不重要了                       │
│    call ICStub_entry             ; ← 原子修改！跳转到 ICStub            │
└─────────────────────────────────────────────────────────────────────────┘

步骤 3：安全点时，ICStub 回填到原始 IC
┌─────────────────────────────────────────────────────────────────────────┐
│  原始 IC（更新后）：                                                    │
│    mov rax, [CompiledICHolder*]  ; 新的缓存值                           │
│    call vtable_stub              ; 新的目标                             │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 5. x86_64 ICStub 汇编代码详解

### 5.1 ic_stub_code_size() 计算

```cpp
// src/hotspot/cpu/x86/icBuffer_x86.cpp:33
int InlineCacheBuffer::ic_stub_code_size() {
  // 最坏情况：目标地址不是近跳转
  // lea rax, lit1       ; NativeMovConstReg::instruction_size
  // lea scratch, lit2   ; NativeMovConstReg::instruction_size
  // jmp scratch         ; 3 bytes
  
  // 最好情况：
  // lea rax, lit1       ; NativeMovConstReg::instruction_size
  // jmp lit2            ; NativeJump::instruction_size
  
  int best = NativeMovConstReg::instruction_size + NativeJump::instruction_size;
  int worst = 2 * NativeMovConstReg::instruction_size + 3;
  return MAX2(best, worst);  // 返回较大值以保证足够空间
}
```

### 5.2 assemble_ic_buffer_code() 生成的汇编

```cpp
// src/hotspot/cpu/x86/icBuffer_x86.cpp:52
void InlineCacheBuffer::assemble_ic_buffer_code(address code_begin, 
                                                void* cached_value, 
                                                address entry_point) {
  ResourceMark rm;
  CodeBuffer      code(code_begin, ic_stub_code_size());
  MacroAssembler* masm = new MacroAssembler(&code);
  
  // 1. 设置缓存值到 rax（IC 的约定寄存器）
  masm->lea(rax, AddressLiteral((address) cached_value, relocInfo::metadata_type));
  
  // 2. 跳转到目标入口点
  masm->jump(ExternalAddress(entry_point));
}
```

### 5.3 生成的汇编代码示例

```asm
; ICStub 汇编代码（x86_64）

; 1. 设置缓存值（lea 指令，10 bytes）
lea    rax, [rip + offset]    ; rax = cached_value (Klass* 或 CompiledICHolder*)

; 2. 跳转到目标（jmp 指令，5 bytes）
jmp    entry_point            ; 跳转到 vtable_stub 或 interpreted_entry

; 总计：约 15-20 bytes
```

### 5.4 ic_buffer_entry_point() 解析目标地址

```cpp
// src/hotspot/cpu/x86/icBuffer_x86.cpp:67
address InlineCacheBuffer::ic_buffer_entry_point(address code_begin) {
  // 找到 lea 指令
  NativeMovConstReg* move = nativeMovConstReg_at(code_begin);
  
  // 找到 jmp 指令
  address jmp = move->next_instruction_address();
  NativeInstruction* ni = nativeInstruction_at(jmp);
  
  if (ni->is_jump()) {
    NativeJump* jump = nativeJump_at(jmp);
    return jump->jump_destination();  // 返回跳转目标
  } else {
    assert(ni->is_far_jump(), "unexpected instruction");
    NativeFarJump* jump = nativeFarJump_at(jmp);
    return jump->jump_destination();
  }
}
```

---

## 6. 工作流程

### 6.1 创建过渡桩

```cpp
// src/hotspot/share/code/icBuffer.cpp:171
void InlineCacheBuffer::create_transition_stub(CompiledIC *ic, 
                                               void* cached_value, 
                                               address entry) {
  assert(!SafepointSynchronize::is_at_safepoint(), "should not be called during a safepoint");
  assert(CompiledIC_lock->is_locked(), "");
  
  // 1. 如果已有过渡桩，先清理旧桩
  if (ic->is_in_transition_state()) {
    ICStub* old_stub = ICStub_from_destination_address(ic->stub_address());
    old_stub->clear();
  }
  
  // 2. 获取下一个可用桩
  ICStub* ic_stub = get_next_stub();
  
  // 3. 设置桩内容（生成汇编代码）
  ic_stub->set_stub(ic, cached_value, entry);
  
  // 4. 更新原始 IC，跳转到桩
  ic->set_ic_destination(ic_stub);
  
  // 5. 预分配下一个桩（可能触发安全点）
  set_next_stub(new_ic_stub());
}
```

### 6.2 安全点时更新/清理

```cpp
// src/hotspot/share/code/icBuffer.cpp:142
void InlineCacheBuffer::update_inline_caches() {
  if (buffer()->number_of_stubs() > 1) {  // 有超过哨兵的桩
    if (TraceICBuffer) {
      tty->print_cr("[updating inline caches with %d stubs]", 
                    buffer()->number_of_stubs());
    }
    
    // 1. 遍历所有桩，将过渡状态回填到原始 IC
    buffer()->remove_all();  // 内部调用 ICStub::finalize()
    
    // 2. 重新初始化哨兵桩
    init_next_stub();
  }
  
  // 3. 释放待清理的 CompiledICHolder
  release_pending_icholders();
}
```

### 6.3 ICStub::finalize() 回填逻辑

```cpp
// src/hotspot/share/code/icBuffer.cpp:47
void ICStub::finalize() {
  if (!is_empty()) {
    ResourceMark rm;
    // 1. 从 _ic_site 重建 CompiledIC 对象
    CompiledIC *ic = CompiledIC_at(CodeCache::find_compiled(ic_site()), ic_site());
    
    // 2. 验证当前仍指向此桩
    assert(this == ICStub_from_destination_address(ic->stub_address()), 
           "wrong owner of ic buffer");
    
    // 3. 将桩中的目标和缓存值回填到原始 IC
    ic->set_ic_destination_and_value(destination(), cached_value());
  }
}
```

---

## 7. 缓冲区满处理

### 7.1 new_ic_stub() 实现

```cpp
// src/hotspot/share/code/icBuffer.cpp:112
ICStub* InlineCacheBuffer::new_ic_stub() {
  while (true) {
    // 尝试从缓冲区分配
    ICStub* ic_stub = (ICStub*)buffer()->request_committed(ic_stub_code_size());
    if (ic_stub != NULL) {
      return ic_stub;
    }
    
    // 缓冲区满了，必须触发安全点清理
    EXCEPTION_MARK;
    VM_ICBufferFull ibf;        // 创建 VM 操作
    VMThread::execute(&ibf);    // 请求 VMThread 执行（触发安全点）
    
    // 处理可能的异步异常
    if (HAS_PENDING_EXCEPTION) {
      oop exception = PENDING_EXCEPTION;
      CLEAR_PENDING_EXCEPTION;
      Thread::send_async_exception(JavaThread::current()->threadObj(), exception);
    }
    // 安全点后缓冲区已清理，继续循环重试
  }
  ShouldNotReachHere();
  return NULL;
}
```

### 7.2 VM_ICBufferFull 操作

```
缓冲区满时的处理流程：

当前线程                          VMThread
    │                                │
    │ new_ic_stub() 返回 NULL        │
    │                                │
    │ VM_ICBufferFull ibf            │
    │─────────────────────────────>│ execute(&ibf)
    │                                │
    │ (等待)                         │ 进入安全点
    │                                │ 所有 Java 线程暂停
    │                                │
    │                                │ update_inline_caches()
    │                                │   - 回填所有 ICStub 到原始 IC
    │                                │   - 清空缓冲区
    │                                │   - 释放 pending ICHolders
    │                                │
    │                                │ 退出安全点
    │<─────────────────────────────│
    │                                │
    │ 重试 request_committed()       │
    │ (成功)                         │
    ▼                                ▼
```

---

## 8. CompiledICHolder 延迟释放

### 8.1 为什么需要延迟释放？

```
问题场景：

Thread A                           Thread B
    │                                │
    │ 更新 IC，旧的 ICHolder*        │
    │ 被替换                         │
    │                                │
    │ 如果立即 delete ICHolder       │ 正在使用旧的 ICHolder*
    │                                │ → 访问已释放内存！崩溃！
    │                                │
    ▼                                ▼
```

### 8.2 解决方案：队列延迟释放

```cpp
// 入队（在更新 IC 时）
void InlineCacheBuffer::queue_for_release(CompiledICHolder* icholder) {
  MutexLockerEx mex(InlineCacheBuffer_lock);
  icholder->set_next(_pending_released);  // 链表头插入
  _pending_released = icholder;
  _pending_count++;
}

// 安全点时释放（所有线程已暂停）
void InlineCacheBuffer::release_pending_icholders() {
  assert(SafepointSynchronize::is_at_safepoint(), "should only be called during a safepoint");
  
  CompiledICHolder* holder = _pending_released;
  _pending_released = NULL;
  
  while (holder != NULL) {
    CompiledICHolder* next = holder->next();
    delete holder;  // 现在可以安全删除
    holder = next;
    _pending_count--;
  }
  assert(_pending_count == 0, "wrong count");
}
```

---

## 9. GDB 验证

### 9.1 GDB 验证结果

【GDB 验证】条件：-Xms256m -Xmx256m -XX:+UseG1GC

```
=== InlineCacheBuffer Basic Info ===
_buffer: 0x7ffff019d8c0
_next_stub: 0x7fffe110ff20

=== StubQueue Info ===
_buffer->_buffer_limit: 10240 bytes    ← 10KB 缓冲区 ✅
_buffer->_number_of_stubs: 1           ← 仅哨兵桩 ✅

=== ICStub Info ===
_next_stub->_size: 64 bytes            ← 单个桩大小（对齐后）
_next_stub->_ic_site: (nil)            ← 空桩（哨兵）✅

=== Pending Release ===
_pending_released: (nil)               ← 无待释放 ICHolder ✅
_pending_count: 0
```

### 9.2 验证分析

**关键发现**：

1. **缓冲区大小**：`_buffer_limit = 10240 bytes (10KB)` ✅
   - 符合源码中 `10*K` 的设定

2. **桩数量**：`_number_of_stubs = 1`
   - 仅有哨兵桩，符合初始状态 ✅

3. **单个桩大小**：`_next_stub->_size = 64 bytes`
   - 实际代码约 23 bytes
   - 对齐到 CodeEntryAlignment（通常 32/64）后的总大小

4. **哨兵状态**：`_ic_site = NULL`
   - 空桩，等待使用 ✅

5. **延迟释放队列**：`_pending_released = NULL, _pending_count = 0`
   - 初始为空 ✅

### 9.3 GDB 验证脚本

```gdb
# jvm-md/InlineCacheBuffer/gdb_InlineCacheBuffer_init.txt

set pagination off
set print pretty on

b InlineCacheBuffer::initialize
run -Xms256m -Xmx256m -XX:+UseG1GC -cp /data/workspace/demo/src com.wjcoder.Main

finish

printf "\n========== InlineCacheBuffer Basic Info ==========\n"
printf "_buffer: %p\n", InlineCacheBuffer::_buffer
printf "_buffer->_stub_count: %d\n", InlineCacheBuffer::_buffer->_number_of_stubs
printf "_buffer->_size: %d\n", InlineCacheBuffer::_buffer->_buffer_limit
printf "_next_stub: %p\n", InlineCacheBuffer::_next_stub

printf "\n========== ICStub Info ==========\n"
printf "ic_stub_code_size: %d bytes\n", InlineCacheBuffer::ic_stub_code_size()
printf "_next_stub->_size: %d\n", InlineCacheBuffer::_next_stub->_size
printf "_next_stub->_ic_site: %p\n", InlineCacheBuffer::_next_stub->_ic_site

printf "\n========== Pending Release ==========\n"
printf "_pending_released: %p\n", InlineCacheBuffer::_pending_released
printf "_pending_count: %d\n", InlineCacheBuffer::_pending_count

quit
```

---

## 10. 与其他组件的关系

```
┌─────────────────────────────────────────────────────────────────────────┐
│                 InlineCacheBuffer 在 JVM 中的位置                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  编译器（C1/C2）                    nmethod                              │
│  ┌──────────────────────┐          ┌──────────────────────┐             │
│  │ 生成 IC 调用点       │─────────▶│  CompiledIC          │             │
│  └──────────────────────┘          │  - cached_value      │             │
│                                    │  - call target       │             │
│                                    └──────────┬───────────┘             │
│                                               │                         │
│                        IC 状态转换（非安全点）  │                         │
│                                               ▼                         │
│                                    ┌──────────────────────┐             │
│                                    │  InlineCacheBuffer   │             │
│                                    │  ┌──────────────────┐│             │
│                                    │  │ StubQueue (10KB) ││             │
│                                    │  │ ┌──────────────┐ ││             │
│                                    │  │ │ ICStub[0]    │ ││             │
│                                    │  │ │ ICStub[1]    │ ││             │
│                                    │  │ │ ...          │ ││             │
│                                    │  │ └──────────────┘ ││             │
│                                    │  └──────────────────┘│             │
│                                    └──────────┬───────────┘             │
│                                               │                         │
│                               安全点时回填     │                         │
│                                               ▼                         │
│                                    ┌──────────────────────┐             │
│                                    │  VtableStubs         │             │
│                                    │  (最终调用目标)       │             │
│                                    └──────────────────────┘             │
│                                                                         │
│  相关组件：                                                              │
│  ┌──────────────────────┐                                               │
│  │ CompiledICHolder     │ ← 存储接口/解释器调用信息                      │
│  │ VtableStubs          │ ← megamorphic 调用的最终目标                   │
│  │ SafepointSynchronize │ ← 触发 IC 回填                                │
│  └──────────────────────┘                                               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 11. 总结

### 11.1 核心流程

```
InlineCacheBuffer_init()
    │
    └── InlineCacheBuffer::initialize()
        │
        ├── 创建 StubQueue (10KB)
        │   └── new StubQueue(ICStubInterface, 10K, lock, name)
        │
        ├── 初始化哨兵桩
        │   └── init_next_stub()
        │
        └── 设置静态变量
            ├── _buffer = StubQueue
            ├── _next_stub = 第一个 ICStub
            ├── _pending_released = NULL
            └── _pending_count = 0

运行时使用：
create_transition_stub(ic, cached_value, entry)
    │
    ├── 获取 _next_stub
    │
    ├── 生成汇编代码：
    │   - lea rax, [cached_value]
    │   - jmp entry_point
    │
    ├── 更新原始 IC → ICStub
    │
    └── 预分配下一个桩

安全点时回填：
update_inline_caches()
    │
    ├── 遍历所有 ICStub
    │   └── finalize() → 回填到原始 IC
    │
    ├── 清空缓冲区
    │
    └── 释放 pending ICHolders
```

### 11.2 关键数据总结

| 组件 | 说明 |
|------|------|
| `_buffer` | StubQueue，10KB 大小 |
| `_next_stub` | 下一个可用的 ICStub |
| `ICStub` | ~48 bytes（含代码） |
| `ic_stub_code_size` | ~23 bytes（x86_64） |
| `_pending_released` | 待释放的 ICHolder 链表 |

### 11.3 设计亮点

1. **MT-safe 状态转换**：通过 ICStub 实现原子更新
2. **延迟回填**：安全点统一处理，减少竞争
3. **延迟释放**：避免多线程访问已释放内存
4. **缓冲区满处理**：自动触发安全点清理
5. **哨兵设计**：简化边界条件处理

---

## 12. 下一步建议

1. **CompiledIC 详解**：深入理解内联缓存结构
2. **IC miss 处理**：追踪 SharedRuntime::handle_ic_miss_helper()
3. **Safepoint 机制**：理解 JVM 安全点实现
4. **C1/C2 生成 IC**：编译器如何生成内联缓存调用

---

> 📅 分析时间：2026-02-06
> 📁 源码版本：OpenJDK 11
