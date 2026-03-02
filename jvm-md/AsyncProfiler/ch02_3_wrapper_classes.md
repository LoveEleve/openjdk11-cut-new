# 2.3 VMKlass/VMMethod/NMethod 包装类 — 信号安全的 JVM 元数据访问

> 源文件: `vmStructs.h` (718行), `vmStructs.cpp` (757行), `safeAccess.cpp` (86行), `stackWalker.cpp` (513行)
> 前置章节: 2.1 VMStructs 设计哲学, 2.2 关键偏移量详解

## 核心问题

**async-profiler 在信号处理器中读取 JVM 内部数据结构，既不能持锁、也不能调用 JVM API、还不能崩溃。它是怎么做到的？**

答案：**包装类 + 偏移量 + SafeAccess + setjmp/longjmp 三层保护**。

---

## 一、整体架构：三层安全保护

```
层级              机制                     保护范围
─────────────────────────────────────────────────────────
L1 指针检查      goodPtr() + NULL 判断     过滤明显无效指针
L2 SafeAccess    SIGSEGV → 跳过故障指令    安全读取可疑指针
L3 setjmp/longjmp crash_protection_ctx    整个栈回溯的最后防线
```

**为什么需要三层？**

- **L1**：99% 的非法指针在这里被过滤（开销最低：一次比较 + 一次与运算）
- **L2**：极少数通过 L1 的指针可能指向已释放/重映射的内存，SafeAccess 能安全返回默认值
- **L3**：如果上述两层都没拦住（比如指针链中间某个节点在读取瞬间被另一个线程释放），longjmp 直接终止整个栈回溯

---

## 二、L1 — goodPtr() 指针检查

```cpp
// vmStructs.h
static bool goodPtr(const void* ptr) {
    return (uintptr_t)ptr >= 0x1000 && ((uintptr_t)ptr & (sizeof(uintptr_t) - 1)) == 0;
}
```

### 两个条件

1. **`>= 0x1000`**：排除 NULL 和低地址（内核不会映射 0x0~0xFFF 页），这些一定不是合法的堆指针
2. **`& 7 == 0`**：64 位对齐检查。JVM 中所有对象/结构体指针都是 8 字节对齐的

### 使用频率

`goodPtr()` 被调用的地方：

| 调用位置 | 被检查的指针 | 目的 |
|---------|-----------|------|
| `VMMethod::id()` L664 | `const_method` | ConstMethod* 可能是垃圾值 |
| `VMMethod::id()` L671 | `cpool` | ConstantPool* 指针链第二级 |
| `VMMethod::id()` L673 | `holder` | InstanceKlass* 指针链第三级 |
| `VMMethod::validatedId()` L686 | `method_id` | jmethodID 可能已过期 |
| `JavaFrameAnchor::fromEntryFrame()` L370 | `call_wrapper` | Entry 帧中读到的指针 |
| `getMethodId()` L61（stackWalker.cpp）| `method` | 解释器帧中的 Method* |

### 为什么不用 `SafeAccess` 替代 `goodPtr`？

**性能**。`goodPtr()` 是纯算术运算（2条指令），而 `SafeAccess::load` 需要函数调用 + 内联汇编（即使正常执行也有 ~20 条指令的开销）。在信号处理器中每次栈回溯要走数十帧，每帧可能检查 3-5 个指针，加起来上百次指针检查，用 SafeAccess 的开销太大。

---

## 三、L2 — SafeAccess：SIGSEGV 保护的安全内存读取

### 设计思想

如果一个指针通过了 `goodPtr()` 检查但实际上指向了已释放/未映射的内存，解引用会触发 SIGSEGV。SafeAccess 的做法是：**让这条 SIGSEGV 可恢复——跳过故障指令，返回默认值**。

### 实现（x86_64）

```cpp
// safeAccess.cpp
NOINLINE
void* SafeAccess::load(void** ptr, void* default_value) {
    void* ret;
    asm volatile("mov (%1), %0" : "=a"(ret) : "r"(ptr), "S"(default_value));
    //            ^^^^^^^^^^^^ 这条指令可能触发 SIGSEGV
    //                                         "r"(ptr) → rdi/某GPR
    //                                                    "S"(default_value) → RSI
    LABEL(load_end);  // ← 导出为全局符号
    return ret;
}
```

### GDB 反汇编验证

```asm
SafeAccess::load:
  +0:   push   %rbp
  +1:   mov    %rsp,%rbp
  +4:   mov    %rdi,-0x18(%rbp)      # 保存 ptr
  +8:   mov    %rsi,-0x20(%rbp)      # 保存 default_value
  +12:  mov    -0x18(%rbp),%rax      # rax = ptr
  +16:  mov    -0x20(%rbp),%rdx
  +20:  mov    %rdx,%rsi             # rsi = default_value (约束 "S")
  +23:  mov    (%rax),%rax           # ← 关键指令！可能 SIGSEGV
  +26:  mov    %rax,-0x8(%rbp)       # ret = loaded value
load_end:                             # ← +30 处的标签
  +30:  mov    -0x8(%rbp),%rax
  +34:  pop    %rbp
  +35:  ret
```

**关键观察**：偏移 +23 的 `mov (%rax),%rax` 是唯一的内存读取指令。如果它触发 SIGSEGV，信号处理器需要做两件事：
1. 跳过这条指令（PC += 3 字节，因为 `mov rax,[rax]` 是 REX.W 前缀 + 操作码 = 3 字节）
   - 等等，实际上看反汇编，偏移 +23 的 `mov (%rax),%rax` 只有 2 字节（`8b 00`），因为没有 REX 前缀
2. 把 `rax`（返回值）设为 `rsi`（default_value）

### checkFault — SIGSEGV 恢复逻辑

```cpp
// safeAccess.cpp:67
bool SafeAccess::checkFault(StackFrame& frame) {
    instruction_t* pc = (instruction_t*)frame.pc();
    
    // 检查故障 PC 是否在 SafeAccess::load 或 load32 的范围内
    if (!(pc >= (void*)load && pc < load_end) &&
        !(pc >= (void*)load32 && pc < load32_end)) {
        return false;  // 不是我们的故障
    }

    // x86_64 恢复逻辑:
    // mov eax, [reg] = 2 字节 (opcode 0x8b)
    // mov rax, [reg] = 3 字节 (REX + opcode)
    frame.pc() += pc[0] == 0x8b ? 2 : 3;  // 跳过故障指令
    frame.retval() = frame.arg1();          // rax = rsi (default_value)
    
    return true;
}
```

### SafeAccess 在信号处理器中的集成

```
SIGPROF / SIGSEGV 信号到达
  ↓
signalHandler()
  ↓ 检查是否是 SIGSEGV
  ↓ 是 → SafeAccess::checkFault(frame)
  ↓       ├── PC 在 load/load32 范围内 → 跳过指令, 返回 default_value, return true
  ↓       └── PC 不在范围内 → return false → 继续走 StackWalker::checkFault()
  ↓
  ↓ 不是 SIGSEGV → 正常的采样信号处理
```

### GDB 验证 SafeAccess 地址范围

```
SafeAccess::load()  : 0x7ffff7b6979a - 0x7ffff7b697b8 (30 bytes)
SafeAccess::load32(): 0x7ffff7b697be - 0x7ffff7b697d7 (25 bytes)
```

这两个函数紧紧相邻（只隔 6 字节），位于 `libasyncProfiler.so` 的 `.text` 段。

---

## 四、L3 — setjmp/longjmp：最后的防线

### 问题

SafeAccess 只保护**单条指令**的内存读取。但栈回溯过程中有大量的**裸指针解引用**（没用 SafeAccess），例如：

```cpp
// stackWalker.cpp:291 — 解释器帧中读取方法指针
VMMethod* method = ((VMMethod**)fp)[InterpreterFrame::method_offset];

// stackWalker.cpp:358 — 从 NMethod 读取帧大小
sp += nm->frameSize() * sizeof(void*);
```

这些位置如果碰到已释放的内存，会直接崩溃。SafeAccess 无法保护它们，因为无法为每个解引用都加 SafeAccess。

### 解决方案：setjmp/longjmp

```cpp
// stackWalker.cpp:232-240
static jmp_buf* crash_protection_ctx[CONCURRENCY_LEVEL];

int StackWalker::walkVM(..., int lock_index, ...) {
    jmp_buf current_ctx;
    crash_protection_ctx[lock_index] = &current_ctx;

    volatile int depth = 0;  // volatile: 确保 longjmp 后值正确

    if (setjmp(current_ctx) != 0) {
        // longjmp 跳回这里 → 栈回溯遇到了不可恢复的故障
        crash_protection_ctx[lock_index] = NULL;
        if (depth < max_depth) {
            fillFrame(frames[depth++], BCI_ERROR, "break_not_walkable");
        }
        return depth;  // 返回已采集到的帧（部分结果好于完全丢失）
    }
    
    // ... 正常的栈回溯循环 ...
    
    crash_protection_ctx[lock_index] = NULL;
    return depth;
}
```

### checkFault — longjmp 恢复

```cpp
// stackWalker.cpp:491
void StackWalker::checkFault() {
    // 在当前线程栈上搜索最近的 crash_protection_ctx
    jmp_buf* nearest_ctx = NULL;
    uintptr_t stack_distance = 32768;  // 最大允许的栈距离
    const uintptr_t current_sp = (uintptr_t)&nearest_ctx;

    for (int i = 0; i < CONCURRENCY_LEVEL; i++) {
        jmp_buf* ctx = crash_protection_ctx[i];
        if ((uintptr_t)ctx - current_sp < stack_distance) {
            nearest_ctx = ctx;
            stack_distance = (uintptr_t)ctx - current_sp;
        }
    }

    if (nearest_ctx != NULL) {
        longjmp(*nearest_ctx, 1);  // 跳回 setjmp，返回非零值
    }
}
```

### 为什么用 CONCURRENCY_LEVEL 个 ctx？

因为多个线程可能同时在做栈回溯（多个采样引擎并行），每个线程用不同的 `lock_index`。`checkFault()` 需要在 `crash_protection_ctx[]` 数组中找到**属于当前线程**的那个 ctx。

判断方法很巧妙：**栈距离**。`jmp_buf` 是分配在调用者栈帧上的局部变量，所以当前线程的 ctx 一定在当前 SP 附近（栈距离最小）。

### 三层保护的完整调用链

```
SIGSEGV 信号到达
  ↓
OS 信号处理器 → profiler signalHandler
  ↓
1. SafeAccess::checkFault(frame)
   ├── PC 在 SafeAccess::load/load32 范围内
   │   → 跳过故障指令，返回 default_value
   │   → 信号处理器正常返回，程序继续执行
   │   → 不会进入 longjmp
   └── PC 不在范围内 → return false
       ↓
2. StackWalker::checkFault()
   ├── 找到最近的 crash_protection_ctx
   │   → longjmp 跳回 setjmp
   │   → 返回部分结果 + "break_not_walkable" 帧
   └── 没找到 → 真正的崩溃（不可恢复）
```

---

## 五、包装类详解

### 5.1 VMThread — 线程标识与状态查询

```cpp
class VMThread : VMStructs {
    // 继承 VMStructs 的 at() 和所有偏移量
};
```

**核心方法**：

| 方法 | 实现 | 信号安全性 |
|------|------|----------|
| `current()` | `pthread_getspecific(_tls_index=0)` | ✅ 信号安全（TLS 读取是原子的） |
| `isJavaThread()` | vtable[1,3,5] 三选二匹配 | ✅ 只读虚表指针 |
| `jni()` | `(JNIEnv*) at(_env_offset=920)` | ✅ 固定偏移量 |
| `inJava()` | `state() == 8` | ✅ 单次内存读取 |
| `inDeopt()` | `_vframe_array_head != NULL` | ✅ 单次内存读取 |
| `anchor()` | `at(_thread_anchor_offset=888)` | ✅ 指针算术 |
| `compiledMethod()` | 三级指针链 | ⚠️ 需要三次解引用 |

### isJavaThread() — vtable 三选二匹配

```cpp
bool isJavaThread() {
    const void** vtbl = vtable();
    return (vtbl[1] == _java_thread_vtbl[1]) +    // Thread::print_value_on
           (vtbl[3] == _java_thread_vtbl[3]) +    // JavaThread::~JavaThread
           (vtbl[5] == _java_thread_vtbl[5]) >= 2; // JavaThread::run
}
```

**为什么三选二而不是直接比较全部？**

JVM 的 debug/release 版本、不同版本可能调整 vtable 某些入口。三选二提供了容错能力——即使某一个 vtable 入口因版本差异而不同，只要另外两个匹配就能正确识别。

**GDB 验证**（JDK 11 slowdebug）：
```
_java_thread_vtbl[1] = 0x7ffff69217f2  → Thread::print_value_on
_java_thread_vtbl[3] = 0x7ffff692405a  → JavaThread::~JavaThread
_java_thread_vtbl[5] = 0x7ffff6924318  → JavaThread::run
```

### 5.2 VMMethod — 方法元数据访问

```cpp
class VMMethod : VMStructs {};
```

**核心方法**：

#### id() — 安全地获取 jmethodID

这是包装类中最复杂也最精巧的方法，因为它涉及 **6 级指针解引用**，每一级都可能遇到无效指针：

```cpp
jmethodID VMMethod::id() {
    // 第 1 级: SafeAccess 保护（最容易出错）
    const char* const_method = (const char*) SafeAccess::load(
        (void**) at(_method_constmethod_offset));  // +16
    if (!goodPtr(const_method)) return NULL;        // L1 检查
    
    // 第 2 级: 裸解引用（靠 L3 保护）
    const char* cpool = *(const char**)(const_method + 8);  // +8
    unsigned short num = *(unsigned short*)(const_method + 46);  // +46
    if (goodPtr(cpool)) {                           // L1 检查
    
        // 第 3 级: 裸解引用
        VMKlass* holder = *(VMKlass**)(cpool + 32);  // +32
        if (goodPtr(holder)) {                       // L1 检查
        
            // 第 4 级: 原子加载
            jmethodID* ids = holder->jmethodIDs();   // atomic_load
            if (ids != NULL && num < (size_t)ids[0]) {
                // 第 5 级: 数组索引
                return ids[num + 1];
            }
        }
    }
    return NULL;
}
```

**安全策略分析**：

| 级别 | 被读取字段 | 保护方式 | 为什么？ |
|:---:|---------|--------|--------|
| 1 | `Method::_constMethod` | SafeAccess | NMethod 可能是垃圾值，Method* 指针完全不可信 |
| 2 | `ConstMethod::_constants` | goodPtr | 如果 ConstMethod* 有效，_constants 通常也有效 |
| 3 | `ConstantPool::_pool_holder` | goodPtr | 同上 |
| 4 | `InstanceKlass::_jmethod_ids` | atomic_load | 可能被并发修改 |
| 5 | `ids[num+1]` | 范围检查 | 确保 idnum 在数组范围内 |

**为什么只有第 1 级用 SafeAccess？**

因为在信号处理器中，NMethod 的有效性最不确定——它可能是通过 CodeHeap segmap 找到的，而在此期间编译器线程可能正在释放/替换 NMethod。一旦 Method* 指针有效，后续的 ConstMethod、ConstantPool 等都是通过 GC root 关联的稳定结构，几乎不会被独立释放。

#### validatedId() — 额外的反向验证

```cpp
jmethodID VMMethod::validatedId() {
    jmethodID method_id = id();
    // JDK 8-16: jmethodID 是指向 Method* 的指针
    // 反向验证: *method_id == this ?
    if (!_can_dereference_jmethod_id || (goodPtr(method_id) && *(VMMethod**)method_id == this)) {
        return method_id;
    }
    return NULL;
}
```

**什么时候用 `id()`，什么时候用 `validatedId()`？**

- `id()`：用在正常的 NMethod → Method 路径（NMethod 已经过 findNMethod 确认）
- `validatedId()`：用在**不完整帧**中读到的 Method*，例如解释器帧的 FP 偏移处

### 5.3 NMethod — 编译方法的全能包装

**关键设计：正负号编码**

```cpp
// 正值: 字段存储的是相对偏移量（int offset）
// 负值: 字段存储的是绝对指针（void*）

const char* code() {
    if (_code_offset > 0) {
        return at(*(int*) at(_code_offset));       // 新版: nmethod_base + offset
    } else {
        return *(const char**) at(-_code_offset);  // 旧版: 直接指针
    }
}

const void* entry() {
    if (_nmethod_entry_offset > 0) {
        return at(*(int*)at(_code_offset) + *(unsigned short*)at(_nmethod_entry_offset));
    } else {
        return *(void**)at(-_nmethod_entry_offset);  // JDK 11: _verified_entry_point 是指针
    }
}
```

**JDK 版本差异表**：

| 字段 | JDK 11 | JDK 23+ |
|------|--------|---------|
| `_code_begin` | `void*` 绝对指针 | `int` 相对偏移 |
| `_verified_entry_point` | `void*` 绝对指针 | `unsigned short` 相对偏移 |
| `_scopes_data_begin` | `void*` 绝对指针 | `int` 相对偏移 + immutable data |

**在 JDK 11 上**（`_nmethod_entry_offset = -272`），`entry()` 走 else 分支：
```cpp
return *(void**) at(272);  // 直接读 _verified_entry_point 指针
```

**NMethod 的关键方法及使用场景**：

| 方法 | 值/逻辑 | 使用场景 |
|------|--------|---------|
| `isNMethod()` | `strcmp(name(), "nmethod") == 0` | 区分编译方法 vs 解释器/stub |
| `isInterpreter()` | `strcmp(name(), "Interpreter") == 0` | 识别解释器帧 |
| `isStub()` | `strncmp(name(), "StubRoutines", 12)` | 识别 stub 帧 |
| `isVTableStub()` | `strcmp(name(), "vtable chunks")` | VTable 分发帧 |
| `isAlive()` | `state() >= 0 && state() <= 1` | 0=in_use, 1=not_entrant |
| `isFrameCompleteAt(pc)` | `pc >= code() + frameCompleteOffset()` | 栈帧是否完整建立 |
| `isEntryFrame(pc)` | `pc == _call_stub_return` | 是否在 call_stub 返回点 |
| `findScopeOffset(pc)` | 二分搜索 PcDesc | 找到内联方法的 scope |

### 5.4 VMKlass — 类型标识

#### fromOop() — 对象头解码

```cpp
static VMKlass* fromOop(uintptr_t oop) {
    if (_narrow_klass_shift >= 0) {
        // 压缩 Klass 模式（JDK 11 默认）
        if (_compact_object_headers) {
            // Lilliput: klass 编码在 mark word 中
            uintptr_t mark = *(uintptr_t*)oop;
            if (mark & MONITOR_BIT) {
                mark = *(uintptr_t*)(mark ^ MONITOR_BIT);
            }
            narrow_klass = mark >> _markword_klass_shift;
        } else {
            // 标准压缩: 从 _metadata 字段读取 narrow klass
            narrow_klass = *(unsigned int*)(oop + _oop_klass_offset);
        }
        return (VMKlass*)(_narrow_klass_base + (narrow_klass << _narrow_klass_shift));
    } else {
        // 非压缩模式
        return *(VMKlass**)(oop + _oop_klass_offset);
    }
}
```

**GDB 验证**（JDK 11）：
```
_narrow_klass_shift = 0     // 压缩 klass，但 shift=0（UseCompressedClassPointers+base非零）
_narrow_klass_base = 0x800000000
_compact_object_headers = false
_oop_klass_offset = 8
```

解码公式: `klass = 0x800000000 + narrow_klass * 1`（shift=0 意味着不移位）

### 5.5 JavaFrameAnchor — 帧锚读取与修复

```cpp
// 获取帧（标准路径）
bool getFrame(const void*& pc, uintptr_t& sp, uintptr_t& fp) {
    if (lastJavaPC() == NULL || lastJavaSP() == 0) return false;
    pc = lastJavaPC();
    sp = lastJavaSP();
    fp = lastJavaFP();
    return true;
}

// 恢复帧（部分保存的情况）
bool restoreFrame(const void*& pc, uintptr_t& sp, uintptr_t& fp) {
    if (lastJavaSP() == 0) return false;
    sp = lastJavaSP();
    if ((fp = lastJavaFP()) == 0) fp = sp;         // FP 可能没保存
    if ((pc = lastJavaPC()) == NULL) pc = ((const void**)sp)[-1];  // 从栈上推断 PC
    return true;
}
```

**`getFrame` vs `restoreFrame` 的区别**：

| | `getFrame` | `restoreFrame` |
|--|-----------|---------------|
| 场景 | Entry 帧过渡 | 非 Java 状态下恢复 |
| PC 要求 | 必须非 NULL | 可以为 NULL（从栈推断） |
| FP 要求 | 直接读取 | 可以为 0（用 SP 替代） |
| 使用者 | walkVM Entry 帧处理 | 非 mixed 模式快速恢复 |

### 5.6 CodeHeap — 三堆查找

```cpp
static NMethod* findNMethod(const void* pc) {
    if (contains(_code_heap[0], pc)) return findNMethod(_code_heap[0], pc);
    if (contains(_code_heap[1], pc)) return findNMethod(_code_heap[1], pc);
    if (contains(_code_heap[2], pc)) return findNMethod(_code_heap[2], pc);
    return NULL;
}
```

**JDK 11 的三个 CodeHeap**（`_code_heap[0..2]`）：

| 索引 | 名称 | 存放内容 | GDB 验证 |
|:---:|------|---------|---------|
| 0 | non-profiled nmethods | C2 编译方法 | `0x7ffff17db680` ✅ |
| 1 | profiled nmethods | C1 编译方法（含 MDO） | `0x0`（Xint 模式下无） |
| 2 | non-nmethods | 解释器/Stub/适配器 | `0x0`（在 `_code_heap[0]` 中） |

**注意**：在 `-Xint`（纯解释模式）下，只有 `_code_heap[0]` 有值，因为所有 CodeBlob 都在同一个 heap 中。如果用 `-XX:-SegmentedCodeCache`（JDK 11 默认关闭分段），三个 heap 会合并为一个。

### 5.7 ScopeDesc — 内联方法展开

```cpp
class ScopeDesc : VMStructs {
    const unsigned char* _scopes;   // nmethod->scopes() 的基地址
    VMMethod** _metadata;           // nmethod->metadata() 的方法数组
    const unsigned char* _stream;   // 当前解码位置

    int decode(int offset) {
        _stream = _scopes + offset;
        int sender_offset = readInt();    // 调用者的 scope offset
        _method_offset = readInt();       // 方法在 metadata 中的索引
        _bci = readInt() - 1;             // bytecode index (0-based)
        return sender_offset;             // >0 表示还有上层调用者
    }
};
```

**readInt() — unsigned5 变长编码**：

```cpp
int ScopeDesc::readInt() {
    unsigned char c = *_stream++;
    unsigned int n = c - _unsigned5_base;  // _unsigned5_base = 1 (JDK 11)
    if (c >= 192) {
        for (int shift = 6; ; shift += 6) {
            c = *_stream++;
            n += (c - _unsigned5_base) << shift;
            if (c < 192 || shift >= 24) break;
        }
    }
    return n;
}
```

这是 JVM 的 UNSIGNED5 编码：小于 191 的值用 1 字节，192-255 表示后续还有字节。

**使用场景**（stackWalker.cpp:282-296）：

```
NMethod 的 PC 对应一个内联链:
  callsite A → inlined method B → inlined method C → actual code at PC

PcDesc 记录: {pc_offset, scope_offset, ...}
  → scope_offset 指向 scopes_data 中的 ScopeDesc 链
  → decode(scope_offset) → sender_offset → decode(sender_offset) → ...
  → 直到 sender_offset == 0（最外层方法）
```

### 5.8 CollectedHeap 与 JVMFlag

**CollectedHeap**：用于判断一个地址是否在 Java 堆范围内。

```cpp
static CollectedHeap* heap() { return (CollectedHeap*)_collected_heap; }
uintptr_t start() { return *(uintptr_t*) at(_region_start_offset); }
uintptr_t size()  { return (*(uintptr_t*) at(_region_size_offset)) * sizeof(uintptr_t); }
```

**JVMFlag**：用于查询和修改 JVM 运行时参数。

```cpp
static JVMFlag* find(const char* name) {
    for (int i = 0; i < _flag_count; i++) {
        JVMFlag* f = (JVMFlag*)(_flags_addr + i * _flag_size);
        if (strcmp(f->name(), name) == 0) return f;
    }
    return NULL;
}
```

在 1.3 节中我们已经看过它被用来设置 `DebugNonSafepoints=true`。

---

## 六、包装类 vs JVM 原生类 — 对照表

| 特性 | JVM 原生类（Klass/Method/...） | async-profiler 包装类 |
|------|------------------------------|---------------------|
| 头文件 | 几十个 `.hpp` 互相依赖 | 一个 `vmStructs.h` 自包含 |
| 字段访问 | `this->_field` 编译时确定 | `at(offset)` 运行时确定 |
| 线程安全 | 需要持锁 / SafepointSynchronize | 无锁，靠 goodPtr + SafeAccess |
| 空指针保护 | assert / guarantee | goodPtr + SafeAccess + longjmp |
| 版本兼容 | 单版本编译 | 运行时适配 JDK 8-25 |
| 性能 | 零开销 | 每次 `at()` 有一次加法 |

---

## 七、GDB 验证总结

### 包装类关键参数验证（在 Profiler::run 断点处）

```
_tls_index             = 0                    // TLS key = 0
_env_offset            = 920                  // JNIEnv* 在 JavaThread 中
_java_thread_vtbl[1]   = Thread::print_value_on
_java_thread_vtbl[3]   = JavaThread::~JavaThread
_java_thread_vtbl[5]   = JavaThread::run

_has_class_names       = true     ← 可以解析类名
_has_method_structs    = true     ← 可以解析方法
_has_compiler_structs  = true     ← 可以获取编译任务
_has_stack_structs     = true     ← 可以做 VM 栈回溯
_has_native_thread_id  = true     ← 可以获取 OS 线程 ID
_has_class_loader_data = false    ← 不走 CLD 优化

_can_dereference_jmethod_id = true  ← validatedId 可以反向验证

_narrow_klass_shift    = 0
_narrow_klass_base     = 0x800000000
_compact_object_headers= false
_call_stub_return      = 0x7fffec7ffd4a

SafeAccess::load()     = [0x7ffff7b6979a, 0x7ffff7b697b8)  // 30 bytes
SafeAccess::load32()   = [0x7ffff7b697be, 0x7ffff7b697d7)  // 25 bytes
```

---

## 八、总结

### 设计哲学

async-profiler 的包装类实现了一个**无锁、信号安全、版本兼容**的 JVM 元数据访问层：

1. **无锁**：不调用任何 JVM API，不触发 SafePoint，不获取任何锁
2. **信号安全**：三层保护（goodPtr → SafeAccess → setjmp/longjmp）确保永远不会崩溃
3. **版本兼容**：正负号编码 + 运行时推断偏移量，一套代码覆盖 JDK 8-25

### 关键洞察

- **SafeAccess 只用在最不可信的第一步**（NMethod → Method*），后续靠 goodPtr + longjmp
- **vtable 三选二**是一个在"精确性"和"鲁棒性"之间的工程权衡
- **setjmp 是最后防线**：宁可返回不完整的栈（"break_not_walkable"），也不崩溃
- **volatile int depth** 是必须的：longjmp 可能跳过 depth 的寄存器缓存值

---

*创建日期: 2026-02-09*
*GDB 验证环境: OpenJDK 11 slowdebug + async-profiler v4.0 (git 00a0a12)*