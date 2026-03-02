# Lesson 5: AllocTracer 真正逐行解析（方法内联展开）

> 本文档对 AllocTracer 的每一行代码进行深度解析，**所有被调用的方法都展开到最底层实现**。

---

## 1. 核心执行流程（方法调用链）

从 `trapHandler` 开始，追踪每个方法调用的内部实现：

```
trapHandler()
├─ StackFrame::StackFrame(ucontext)           // 构造函数
│  └─ _ucontext = (ucontext_t*)ucontext       // 只是保存指针
├─ StackFrame::pc()                            // 读取 PC
│  └─ REG(RIP, rip)                           // 展开为宏
│     └─ _ucontext->uc_mcontext.gregs[REG_RIP]  // 最终实现
├─ Trap::covers(pc)                           // 判断断点类型
│  └─ pc - _entry <= sizeof(instruction_t)    // 直接比较
├─ StackFrame::arg0/1/2/3()                   // 读取参数
│  └─ REG(RDI/RSI/RDX/RCX, ...)              // 展开为宏
│     └─ _ucontext->uc_mcontext.gregs[REG_XXX]  // 最终实现
├─ StackFrame::ret()                          // 模拟返回
│  ├─ pc() = stackAt(0)                       // 设置 PC
│  │  ├─ stackAt(0)                          // 读取栈顶
│  │  │  └─ ((uintptr_t*)sp())[0]           // 最终实现
│  │  └─ pc()                                // 返回 PC 引用
│  │     └─ REG(RIP, rip)                   // 最终实现
│  └─ sp() += 8                              // 弹出返回地址
│     └─ REG(RSP, rsp)                       // 最终实现
├─ updateCounter()                            // CAS 采样判断
│  └─ __sync_bool_compare_and_swap()         // 编译器内联原子操作
├─ recordAllocation()                         // 记录分配
│  ├─ TSC::ticks()                           // 读取时间戳
│  │  └─ __builtin_ia32_rdtsc()             // RDTSC 指令
│  ├─ VMKlass::fromHandle()                  // 转换 Klass 指针
│  │  └─ (VMKlass*)handle                    // 直接转换
│  ├─ VMKlass::name()                        // 获取类名
│  │  └─ *(VMSymbol**) at(_klass_name_offset)  // 读取字段
│  ├─ VMSymbol::body()                       // 获取字符串
│  │  └─ (char*) at(_symbol_body_offset)    // 读取字段
│  ├─ VMSymbol::length()                     // 获取长度
│  │  └─ *(u16*) at(_symbol_length_offset)  // 读取字段
│  ├─ Dictionary::lookup()                   // 类名映射
│  │  ├─ hash()                              // FNV-1a 哈希
│  │  ├─ CAS 插入/查找                       // 并发安全
│  │  └─ 返回 class_id                       // 
│  └─ Profiler::recordSample()               // 记录采样
│     ├─ OS::threadId()                      // 获取线程 ID
│     │  └─ syscall(SYS_gettid)             // 系统调用
│     ├─ getLockIndex()                      // 计算锁索引
│     │  └─ tid % CONCURRENCY_LEVEL         // 哈希
│     ├─ SpinLock::tryLock()                 // 尝试获取锁
│     │  └─ __sync_bool_compare_and_swap()  // CAS
│     ├─ StackWalker::walkVM()              // 栈回溯
│     │  └─ [复杂流程，见后文]              // 
│     ├─ CallTraceStorage::put()            // 存储调用栈
│     │  ├─ calcHash()                      // MurmurHash64A
│     │  ├─ 哈希表查找/插入                 // 
│     │  ├─ storeCallTrace()                // 存储帧
│     │  │  └─ LinearAllocator::alloc()    // 线性分配
│     │  └─ 返回 call_trace_id              // 
│     └─ 返回 trace_id（用于 --live）       // 
```

---

## 2. trapHandler 逐行解析（方法内联展开）

```cpp
// 文件: allocTracer.cpp 第 49-81 行

void AllocTracer::trapHandler(int signo, siginfo_t* siginfo, void* ucontext) {
```

**参数解析**：
- `signo`：信号编号，值为 `SIGTRAP (5)`
- `siginfo`：信号信息结构体，包含触发原因
- `ucontext`：用户上下文，包含所有寄存器状态

**ucontext 结构**（Linux x86_64）：

```c
// /usr/include/sys/ucontext.h
typedef struct ucontext_t {
    unsigned long int uc_flags;
    struct ucontext_t *uc_link;
    stack_t uc_stack;
    mcontext_t uc_mcontext;  // <-- 关键：包含寄存器
    sigset_t uc_sigmask;
    struct _libc_fpstate __fpregs_mem;
} ucontext_t;

// mcontext_t 定义：
typedef struct {
    gregset_t gregs;  // 通用寄存器数组
    fpregset_t fpregs;
    unsigned long __reserved1 [8];
} mcontext_t;

// gregset_t 定义：
typedef long int gregset_t[23];  // 23 个通用寄存器

// 寄存器索引：
#define REG_R8    0
#define REG_R9    1
#define REG_R10   2
// ...
#define REG_RIP   16  // <-- PC
#define REG_RSP   19  // <-- SP
// ...
#define REG_RDI   12  // <-- 第 1 个参数
#define REG_RSI   13  // <-- 第 2 个参数
#define REG_RDX   14  // <-- 第 3 个参数
#define REG_RCX   15  // <-- 第 4 个参数
```

---

```cpp
    StackFrame frame(ucontext);
```

**展开 StackFrame 构造函数**：

```cpp
// 文件: stackFrame.h 第 27-29 行
StackFrame(void* ucontext) {
    _ucontext = (ucontext_t*)ucontext;
}
```

**解析**：构造函数只是保存 `ucontext` 指针，不进行任何计算。

---

```cpp
    EventType event_type;
    uintptr_t total_size;
    uintptr_t instance_size;
```

**解析**：声明局部变量，存储稍后读取的数据。

---

```cpp
    if (_in_new_tlab.covers(frame.pc())) {
```

**展开 frame.pc()**：

```cpp
// 文件: stackFrame_x64.cpp 第 22-24 行
uintptr_t& StackFrame::pc() {
    return (uintptr_t&)REG(RIP, rip);
}
```

**展开 REG 宏**：

```cpp
// 文件: stackFrame_x64.cpp 第 15-19 行
#ifdef __APPLE__
#  define REG(l, m)  _ucontext->uc_mcontext->__ss.__##m
#else
#  define REG(l, m)  _ucontext->uc_mcontext.gregs[REG_##l]
#endif
```

**在 Linux 上展开为**：

```cpp
// _ucontext->uc_mcontext.gregs[REG_RIP]
// 等价于：
_ucontext->uc_mcontext.gregs[16]  // REG_RIP = 16
```

**展开 Trap::covers()**：

```cpp
// 文件: trap.h 第 37-40 行
bool covers(uintptr_t pc) {
    // PC points either to BREAKPOINT instruction or to the next one
    return pc - _entry <= sizeof(instruction_t);
}
```

**解析**：
- `_entry` 是断点地址（函数入口）
- `sizeof(instruction_t)` 在 x86_64 上是 1（INT3 是 1 字节）
- 检查 PC 是否在 `_entry` 或 `_entry + 1`

**为什么 PC 可能在 `_entry + 1`？**

```
INT3 指令执行后，有两种可能：
1. PC 指向 INT3 的地址（_entry）：某些内核版本
2. PC 指向 INT3 后的下一条指令（_entry + 1）：其他内核版本

AsyncProfiler 兼容两种情况。
```

---

```cpp
        // send_allocation_in_new_tlab(Klass* klass, HeapWord* obj, size_t tlab_size, size_t alloc_size, Thread* thread)
        // send_allocation_in_new_tlab_event(KlassHandle klass, size_t tlab_size, size_t alloc_size)
        event_type = ALLOC_SAMPLE;
        total_size = _trap_kind == 1 ? frame.arg2() : frame.arg1();
        instance_size = _trap_kind == 1 ? frame.arg3() : frame.arg2();
```

**展开 frame.arg0/1/2/3()**：

```cpp
// 文件: stackFrame_x64.cpp 第 43-57 行
uintptr_t StackFrame::arg0() {
    return (uintptr_t)REG(RDI, rdi);
    // Linux: _ucontext->uc_mcontext.gregs[REG_RDI]
    // 即：_ucontext->uc_mcontext.gregs[12]
}

uintptr_t StackFrame::arg1() {
    return (uintptr_t)REG(RSI, rsi);
    // Linux: _ucontext->uc_mcontext.gregs[REG_RSI]
    // 即：_ucontext->uc_mcontext.gregs[13]
}

uintptr_t StackFrame::arg2() {
    return (uintptr_t)REG(RDX, rdx);
    // Linux: _ucontext->uc_mcontext.gregs[REG_RDX]
    // 即：_ucontext->uc_mcontext.gregs[14]
}

uintptr_t StackFrame::arg3() {
    return (uintptr_t)REG(RCX, rcx);
    // Linux: _ucontext->uc_mcontext.gregs[REG_RCX]
    // 即：_ucontext->uc_mcontext.gregs[15]
}
```

**解析 x86_64 SysV ABI 调用约定**：

| 参数位置 | 寄存器 | gregs 索引 | 用途 |
|---------|-------|-----------|------|
| 第 1 个 | RDI | 12 | `Klass* klass` |
| 第 2 个 | RSI | 13 | `HeapWord* obj` |
| 第 3 个 | RDX | 14 | `size_t tlab_size` |
| 第 4 个 | RCX | 15 | `size_t alloc_size` |
| 第 5 个 | R8 | 0 | `Thread* thread` |

**JDK 版本差异**：

```cpp
// JDK 10+ (_trap_kind = 1):
// send_allocation_in_new_tlab(Klass* klass, HeapWord* obj, 
//                              size_t tlab_size, size_t alloc_size, Thread* thread)
total_size = frame.arg2();     // RDX = tlab_size
instance_size = frame.arg3();  // RCX = alloc_size

// JDK 7-9 (_trap_kind = 2):
// send_allocation_in_new_tlab_event(KlassHandle klass, size_t tlab_size, size_t alloc_size)
total_size = frame.arg1();     // RSI = tlab_size
instance_size = frame.arg2();  // RDX = alloc_size
```

---

```cpp
    } else if (_outside_tlab.covers(frame.pc())) {
        // send_allocation_outside_tlab(Klass* klass, HeapWord* obj, size_t alloc_size, Thread* thread)
        // send_allocation_outside_tlab_event(KlassHandle klass, size_t alloc_size);
        event_type = ALLOC_OUTSIDE_TLAB;
        total_size = _trap_kind == 1 ? frame.arg2() : frame.arg1();
        instance_size = 0;
    } else {
        // Not our trap
        Profiler::instance()->trapHandler(signo, siginfo, ucontext);
        return;
    }
```

**解析**：
- 如果 PC 不在已知断点范围内，转发给父类处理
- 可能是其他组件设置的断点

---

```cpp
    // Leave the trapped function by simulating "ret" instruction
    uintptr_t klass = frame.arg0();
    frame.ret();
```

**展开 frame.ret()**：

```cpp
// 文件: stackFrame_x64.cpp 第 71-74 行
void StackFrame::ret() {
    pc() = stackAt(0);
    sp() += 8;
}
```

**展开 stackAt(0)**：

```cpp
// 文件: stackFrame.h 第 39-41 行
uintptr_t stackAt(int slot) {
    return ((uintptr_t*)sp())[slot];
}
```

**展开 sp()**：

```cpp
// 文件: stackFrame_x64.cpp 第 26-28 行
uintptr_t& StackFrame::sp() {
    return (uintptr_t&)REG(RSP, rsp);
    // Linux: _ucontext->uc_mcontext.gregs[REG_RSP]
    // 即：_ucontext->uc_mcontext.gregs[19]
}
```

**完整展开 ret()**：

```cpp
void StackFrame::ret() {
    // 1. 读取栈顶的返回地址
    uintptr_t return_addr = ((uintptr_t*)_ucontext->uc_mcontext.gregs[REG_RSP])[0];
    
    // 2. 设置 PC = 返回地址
    _ucontext->uc_mcontext.gregs[REG_RIP] = return_addr;
    
    // 3. 弹出返回地址
    _ucontext->uc_mcontext.gregs[REG_RSP] += 8;
}
```

**栈布局图解**：

```
调用 send_allocation_in_new_tlab 前的栈：

高地址
│
│  +---------------------------+
│  | 调用者的栈帧               |
│  +---------------------------+
│  | 第 6 个参数（如果在栈上）  |  <- RSP + 48
│  +---------------------------+
│  | ...                       |
│  +---------------------------+
│  | 第 5 个参数（如果在栈上）  |  <- RSP + 8
│  +---------------------------+
│  | 返回地址                   |  <- RSP (stackAt(0))
│  +---------------------------+  <- 栈顶
│
低地址

ret() 执行后：

高地址
│
│  +---------------------------+
│  | 调用者的栈帧               |
│  +---------------------------+
│  | 第 6 个参数（如果在栈上）  |  <- RSP + 40
│  +---------------------------+
│  | ...                       |
│  +---------------------------+
│  | 第 5 个参数（如果在栈上）  |  <- RSP
│  +---------------------------+  <- 新的栈顶
│
低地址

PC = 返回地址（指向调用者的代码）
```

---

```cpp
    if (_enabled && updateCounter(_allocated_bytes, total_size, _interval)) {
        recordAllocation(ucontext, event_type, klass, total_size, instance_size);
    }
}
```

**展开 updateCounter()**：

```cpp
// 文件: engine.h 第 16-34 行
static bool updateCounter(volatile u64& counter, u64 value, u64 interval) {
    if (interval <= 1) {
        return true;  // 无条件采样
    }

    while (true) {
        u64 prev = counter;
        u64 next = prev + value;
        if (next < interval) {
            // 未达到间隔，CAS 更新
            if (__sync_bool_compare_and_swap(&counter, prev, next)) {
                return false;  // 不采样
            }
            // CAS 失败，重试
        } else {
            // 达到间隔，CAS 更新并采样
            if (__sync_bool_compare_and_swap(&counter, prev, next % interval)) {
                return true;  // 采样
            }
            // CAS 失败，重试
        }
    }
}
```

**展开 __sync_bool_compare_and_swap**：

```cpp
// 这是 GCC 内置函数，编译为 x86_64 的 CMPXCHG 指令：

bool __sync_bool_compare_and_swap(u64* ptr, u64 expected, u64 desired) {
    // 等价的汇编：
    //   lock cmpxchg [ptr], desired
    //   setz al
    //   movzx eax, al
    
    // CMPXCHG 指令：
    // - 比较 *ptr 和 RAX（expected）
    // - 如果相等，设置 ZF=1，*ptr = desired
    // - 如果不等，清除 ZF，RAX = *ptr
    
    // lock 前缀：
    // - 锁定总线，保证原子性
    // - 在多核 CPU 上确保缓存一致性
}
```

---

## 3. recordAllocation 逐行解析（方法内联展开）

```cpp
// 文件: allocTracer.cpp 第 83-97 行

void AllocTracer::recordAllocation(void* ucontext, EventType event_type, uintptr_t rklass,
                                   uintptr_t total_size, uintptr_t instance_size) {
    AllocEvent event;
    event._start_time = TSC::ticks();
```

**展开 TSC::ticks()**：

```cpp
// 文件: tsc.h
static u64 ticks() {
    u64 lo, hi;
    __asm__ __volatile__ ("rdtsc" : "=a" (lo), "=d" (hi));
    return (hi << 32) | lo;
}
```

**解析 RDTSC 指令**：

```
RDTSC (Read Time-Stamp Counter):
- 读取 CPU 时间戳计数器
- 将 64 位结果存入 EDX:EAX
  - EDX = 高 32 位
  - EAX = 低 32 位
- 在现代 CPU 上，这是一个常量频率计数器
- 用于高精度计时（不随 CPU 频率变化）
```

---

```cpp
    event._class_id = 0;
    event._total_size = total_size;
    event._instance_size = instance_size;

    if (VMStructs::hasClassNames()) {
        VMSymbol* symbol = VMKlass::fromHandle(rklass)->name();
```

**展开 VMKlass::fromHandle()**：

```cpp
// 文件: vmStructs.h 第 262-269 行
static VMKlass* fromHandle(uintptr_t handle) {
    if (_has_perm_gen) {
        // JDK 7: KlassHandle 是指向 klassOop 的指针
        return (VMKlass*)(*(uintptr_t**)handle + 2);
    } else {
        // JDK 8+: KlassHandle 直接是 Klass*
        return (VMKlass*)handle;
    }
}
```

**JDK 7 vs JDK 8+ 内存模型**：

```
JDK 7 (有 PermGen):
  KlassHandle handle
      │
      v
  klassOop (oopDesc*)        // 在 Java 堆中
      │
      +---> mark word (8 bytes)
      +---> _metadata._klass (8 bytes)
      │
      v
  Klass (实际元数据)         // 在 PermGen 中

JDK 8+ (有 Metaspace):
  KlassHandle handle
      │
      v
  Klass (直接指向元数据)      // 在 Metaspace 中
```

---

**展开 VMKlass::name()**：

```cpp
// 文件: vmStructs.h 第 289-291 行
VMSymbol* name() {
    return *(VMSymbol**) at(_klass_name_offset);
}
```

**展开 at()**：

```cpp
// at() 是 VMStructs 的辅助方法
uintptr_t at(int offset) {
    return *(uintptr_t*)((char*)this + offset);
}
```

**完整展开**：

```cpp
VMSymbol* VMKlass::name() {
    // 1. 计算字段地址
    char* field_addr = (char*)this + _klass_name_offset;
    
    // 2. 解引用，读取 VMSymbol*
    return *(VMSymbol**)field_addr;
}
```

**Klass 结构布局**：

```cpp
// hotspot/share/oops/klass.hpp
class Klass : public Metadata {
  private:
    Klass* _super;              // offset 0
    Array<Method*>* _methods;   // offset 8
    // ...
    Symbol* _name;              // offset ? (_klass_name_offset)
    // ...
};
```

---

```cpp
        event._class_id = Profiler::instance()->classMap()->lookup(symbol->body(), symbol->length());
    }
```

**展开 VMSymbol::body() 和 length()**：

```cpp
// 文件: vmStructs.h (VMSymbol 类)
char* body() {
    return (char*) at(_symbol_body_offset);
}

u16 length() {
    if (_symbol_length_and_refcount_offset >= 0) {
        // JDK 11+: 使用 _length_and_refcount 字段
        u32 len_ref = *(u32*) at(_symbol_length_and_refcount_offset);
        return len_ref >> 16;  // 高 16 位是长度
    } else {
        // JDK 8: 使用 _length 字段
        return *(u16*) at(_symbol_length_offset);
    }
}
```

**Symbol 结构布局**：

```cpp
// hotspot/share/oops/symbol.hpp
class Symbol : public MetaspaceObj {
  private:
    u16 _length;           // 字符串长度
    // 或 JDK 11+:
    u32 _length_and_refcount;  // 高 16 位：长度，低 16 位：引用计数
    
    char _body[1];         // 字符数组（变长）
};
```

---

**展开 Dictionary::lookup()**：

```cpp
// 文件: dictionary.cpp 第 82-112 行
unsigned int Dictionary::lookup(const char* key, size_t length) {
    DictTable* table = _table;
    unsigned int h = hash(key, length);  // 步骤 1: 计算哈希

    while (true) {
        DictRow* row = &table->rows[h % ROWS];  // 步骤 2: 计算行号
        for (int c = 0; c < CELLS; c++) {       // 步骤 3: 遍历单元格
            if (row->keys[c] == NULL) {
                // 单元格为空，尝试插入
                char* new_key = allocateKey(key, length);
                if (__sync_bool_compare_and_swap(&row->keys[c], NULL, new_key)) {
                    // 插入成功，返回 ID
                    return table->index(h % ROWS, c);
                }
                // CAS 失败（其他线程先插入了），释放内存
                free(new_key);
            }
            if (keyEquals(row->keys[c], key, length)) {
                // 找到匹配，返回 ID
                return table->index(h % ROWS, c);
            }
        }

        // 当前行已满，尝试扩展到下一层表
        if (row->next == NULL) {
            DictTable* new_table = (DictTable*)calloc(1, sizeof(DictTable));
            new_table->base_index = __sync_add_and_fetch(&_base_index, TABLE_CAPACITY);
            if (!__sync_bool_compare_and_swap(&row->next, NULL, new_table)) {
                free(new_table);  // 其他线程已创建
            }
        }

        table = row->next;
        h = (h >> ROW_BITS) | (h << (32 - ROW_BITS));  // 重新哈希
    }
}
```

**展开 hash()**：

```cpp
// 文件: dictionary.cpp 第 70-76 行
unsigned int Dictionary::hash(const char* key, size_t length) {
    unsigned int h = 2166136261U;  // FNV-1a 初始值
    for (size_t i = 0; i < length; i++) {
        h = (h ^ key[i]) * 16777619;  // FNV-1a 混合
    }
    return h;
}
```

**Dictionary 数据结构**：

```
Dictionary 是一个多级哈希表：

DictTable (level 0):
┌─────────────────────────────────────┐
│ DictRow[0]:                         │
│   keys[0] = "java/lang/Object"      │ -> class_id = 1
│   keys[1] = "java/lang/String"      │ -> class_id = 2
│   keys[2] = "[B"                    │ -> class_id = 3
│   next = NULL or DictTable(level 1) │
├─────────────────────────────────────┤
│ DictRow[1]:                         │
│   keys[0] = ...                     │
│   keys[1] = ...                     │
│   keys[2] = ...                     │
│   next = ...                        │
├─────────────────────────────────────┤
│ ... (128 rows)                      │
└─────────────────────────────────────┘

当某行满了（3 个单元格都有值），创建新表，
并通过 next 指针链接。
```

---

```cpp
    Profiler::instance()->recordSample(ucontext, total_size, event_type, &event);
}
```

**展开 Profiler::recordSample()**：

```cpp
// 文件: profiler.cpp 第 606-703 行
u64 Profiler::recordSample(void* ucontext, u64 counter, EventType event_type, Event* event) {
    atomicInc(_total_samples);  // 步骤 1: 增加总采样数

    int tid = OS::threadId();   // 步骤 2: 获取线程 ID
```

**展开 OS::threadId()**：

```cpp
// 文件: os_linux.cpp
int OS::threadId() {
    return syscall(SYS_gettid);  // 调用 gettid 系统调用
}
```

**系统调用开销**：
- `SYS_gettid`：~50 cycles（快速系统调用）
- 不涉及用户态/内核态切换（vDSO 优化）

---

```cpp
    u32 lock_index = getLockIndex(tid);
    if (!_locks[lock_index].tryLock() &&
        !_locks[lock_index = (lock_index + 1) % CONCURRENCY_LEVEL].tryLock() &&
        !_locks[lock_index = (lock_index + 2) % CONCURRENCY_LEVEL].tryLock())
    {
        // Too many concurrent signals already
        atomicInc(_failures[-ticks_skipped]);

        if (event_type == PERF_SAMPLE) {
            PerfEvents::resetBuffer(tid);
        }
        return 0;
    }
```

**展开 getLockIndex()**：

```cpp
// 文件: profiler.cpp 第 187-192 行
inline u32 Profiler::getLockIndex(int tid) {
    u32 lock_index = tid;
    lock_index ^= lock_index >> 8;
    lock_index ^= lock_index >> 4;
    return lock_index % CONCURRENCY_LEVEL;  // CONCURRENCY_LEVEL = 16
}
```

**解析**：简单的哈希函数，将线程 ID 映射到 16 个锁之一。

**展开 SpinLock::tryLock()**：

```cpp
// 文件: spinLock.h
bool tryLock() {
    return __sync_bool_compare_and_swap(&_state, 0, 1);
    // _state 初始为 0，加锁后为 1
}
```

**为什么尝试 3 次？**
- 避免某个锁竞争过高
- 尝试 3 个不同的锁，提高成功率

---

```cpp
    u64 stack_walk_begin = _features.stats ? OS::nanotime() : 0;

    ASGCT_CallFrame* frames = _calltrace_buffer[lock_index]->_asgct_frames;
    jvmtiFrameInfo* jvmti_frames = _calltrace_buffer[lock_index]->_jvmti_frames;
```

**解析**：
- `_calltrace_buffer` 是预分配的缓冲区数组
- 每个锁对应一个缓冲区，避免竞争

---

```cpp
    int num_frames = 0;
    if (_add_event_frame && event_type >= ALLOC_SAMPLE && event_type <= PARK_SAMPLE) {
        u32 class_id = ((EventWithClassId*)event)->_class_id;
        if (class_id != 0) {
            jint frame_type = BCI_ALLOC - (event_type - ALLOC_SAMPLE);
            num_frames = makeFrame(frames, frame_type, class_id);
        }
    }
```

**展开 makeFrame()**：

```cpp
// 文件: profiler.cpp 第 104-108 行
static inline int makeFrame(ASGCT_CallFrame* frames, jint type, jmethodID id) {
    frames[0].bci = type;       // BCI (Bytecode Index) 或特殊标记
    frames[0].method_id = id;   // 方法 ID 或类 ID
    return 1;
}
```

**解析**：在调用栈顶部插入一个"事件帧"，表示这是什么类型的事件。

---

```cpp
    StackContext java_ctx = {0};
    if (hasNativeStack(event_type)) {
        if (_features.pc_addr && event_type <= WALL_CLOCK_SAMPLE) {
            num_frames += makeFrame(frames + num_frames, BCI_ADDRESS, StackFrame(ucontext).pc());
        }
        if (_cstack != CSTACK_NO) {
            num_frames += getNativeTrace(ucontext, frames + num_frames, event_type, tid, &java_ctx);
        }
    }
```

**展开 hasNativeStack()**：

```cpp
// 文件: profiler.cpp 第 88-98 行
static inline int hasNativeStack(EventType event_type) {
    const int events_with_native_stack =
        (1 << PERF_SAMPLE)        |
        (1 << EXECUTION_SAMPLE)   |
        (1 << WALL_CLOCK_SAMPLE)  |
        (1 << NATIVE_LOCK_SAMPLE) |
        (1 << MALLOC_SAMPLE)      |
        (1 << ALLOC_SAMPLE)       |      // <-- AllocTracer
        (1 << ALLOC_OUTSIDE_TLAB);       // <-- AllocTracer
    return (1 << event_type) & events_with_native_stack;
}
```

**getNativeTrace()** 是栈回溯的核心，涉及复杂的 DWARF 解析，这里不展开。

---

```cpp
    if (_features.mixed) {
        num_frames += StackWalker::walkVM(ucontext, frames + num_frames, _max_stack_depth, lock_index, _features, event_type);
    } else if (event_type <= MALLOC_SAMPLE) {
        // ... 其他分支
    }
```

**StackWalker::walkVM()** 是 JVM 栈回溯的核心，涉及：
- 解释器帧解析
- JIT 编译帧解析
- 内联帧处理
这需要单独的文档深入分析。

---

```cpp
    if (num_frames == 0) {
        num_frames += makeFrame(frames + num_frames, BCI_ERROR, "no_Java_frame");
    }
```

**解析**：如果栈回溯失败，插入错误帧。

---

```cpp
    u32 call_trace_id = _call_trace_storage.put(num_frames, frames, counter);
    _jfr.recordEvent(lock_index, tid, call_trace_id, event_type, event);

    _locks[lock_index].unlock();
    return (u64)tid << 32 | call_trace_id;
}
```

**展开 CallTraceStorage::put()**：

```cpp
// 文件: callTraceStorage.cpp 第 233-281 行
u32 CallTraceStorage::put(int num_frames, ASGCT_CallFrame* frames, u64 counter) {
    // 步骤 1: 计算调用栈哈希
    u64 hash = calcHash(num_frames, frames);

    LongHashTable* table = _current_table;
    u64* keys = table->keys();
    u32 capacity = table->capacity();
    u32 slot = hash & (capacity - 1);  // 步骤 2: 计算槽位
    u32 step = 0;

    while (keys[slot] != hash) {
        if (keys[slot] == 0) {
            // 槽位为空，尝试插入
            if (!__sync_bool_compare_and_swap(&keys[slot], 0, hash)) {
                continue;  // CAS 失败，重试
            }

            // 步骤 3: 检查是否需要扩展哈希表
            if (table->incSize() == capacity * 3 / 4) {
                LongHashTable* new_table = LongHashTable::allocate(table, capacity * 2);
                if (new_table != NULL) {
                    __sync_bool_compare_and_swap(&_current_table, table, new_table);
                }
            }

            // 步骤 4: 存储调用栈
            CallTrace* trace = table->prev() == NULL ? NULL : findCallTrace(table->prev(), hash);
            if (trace == NULL) {
                trace = storeCallTrace(num_frames, frames);
            }
            table->values()[slot].setTrace(trace);
            break;
        }

        // 步骤 5: 线性探测
        if (++step >= capacity) {
            atomicInc(_overflow);
            return OVERFLOW_TRACE_ID;
        }
        slot = (slot + step) & (capacity - 1);
    }

    // 步骤 6: 更新计数器
    if (counter != 0) {
        CallTraceSample& s = table->values()[slot];
        atomicInc(s.samples);
        atomicInc(s.counter, counter);
    }

    return capacity - (INITIAL_CAPACITY - 1) + slot;
}
```

**展开 calcHash()**：

```cpp
// 文件: callTraceStorage.cpp 第 170-199 行
u64 CallTraceStorage::calcHash(int num_frames, ASGCT_CallFrame* frames) {
    // MurmurHash64A 算法
    const u64 M = 0xc6a4a7935bd1e995ULL;
    const int R = 47;

    int len = num_frames * sizeof(ASGCT_CallFrame);
    u64 h = len * M;

    const u64* data = (const u64*)frames;
    const u64* end = data + len / 8;

    while (data != end) {
        u64 k = *data++;
        k *= M;
        k ^= k >> R;
        k *= M;
        h ^= k;
        h *= M;
    }

    if (len & 4) {
        h ^= *(u32*)data;
        h *= M;
    }

    h ^= h >> R;
    h *= M;
    h ^= h >> R;

    return h;
}
```

---

## 4. 完整执行流程图（包含方法内部）

```
Java 分配: new byte[1024]
          │
          v
    JVM 分配内存（已完成）
          │
          v
    调用 send_allocation_in_new_tlab(...)
          │
          v
    ┌─────────────────────────────────────────────────────────┐
    │ 执行 INT3 (0xCC)                                         │
    │ CPU 触发 SIGTRAP 信号                                    │
    │ OS 保存寄存器到 ucontext                                 │
    └─────────────────────────────────────────────────────────┘
          │
          v
    ┌─────────────────────────────────────────────────────────┐
    │ AllocTracer::trapHandler(signo, siginfo, ucontext)      │
    │                                                         │
    │ [1] StackFrame frame(ucontext)                          │
    │     └─ _ucontext = (ucontext_t*)ucontext                │
    │                                                         │
    │ [2] frame.pc()                                          │
    │     └─ _ucontext->uc_mcontext.gregs[REG_RIP]            │
    │                                                         │
    │ [3] _in_new_tlab.covers(pc)                             │
    │     └─ pc - _entry <= 1                                 │
    │                                                         │
    │ [4] frame.arg0/1/2/3()                                  │
    │     └─ _ucontext->uc_mcontext.gregs[REG_RDI/RSI/RDX/RCX]│
    │                                                         │
    │ [5] frame.ret()                                         │
    │     ├─ return_addr = *(uintptr_t*)sp()                  │
    │     ├─ pc() = return_addr                               │
    │     └─ sp() += 8                                        │
    │                                                         │
    │ [6] updateCounter()                                     │
    │     └─ CAS(_allocated_bytes, prev, next)                │
    │                                                         │
    │ [7] recordAllocation()                                  │
    │     ├─ TSC::ticks() -> __asm__("rdtsc")                 │
    │     ├─ VMKlass::fromHandle(rklass)                      │
    │     │   └─ (VMKlass*)handle                             │
    │     ├─ VMKlass::name()                                  │
    │     │   └─ *(VMSymbol**)(klass + _klass_name_offset)    │
    │     ├─ VMSymbol::body()                                 │
    │     │   └─ (char*)(symbol + _symbol_body_offset)        │
    │     ├─ VMSymbol::length()                               │
    │     │   └─ *(u16*)(symbol + _symbol_length_offset)      │
    │     ├─ Dictionary::lookup()                             │
    │     │   ├─ FNV-1a hash                                  │
    │     │   └─ CAS 插入/查找                                │
    │     └─ Profiler::recordSample()                         │
    └─────────────────────────────────────────────────────────┘
          │
          v
    ┌─────────────────────────────────────────────────────────┐
    │ Profiler::recordSample()                                │
    │                                                         │
    │ [1] OS::threadId()                                      │
    │     └─ syscall(SYS_gettid)                              │
    │                                                         │
    │ [2] getLockIndex(tid)                                   │
    │     └─ tid % 16                                         │
    │                                                         │
    │ [3] SpinLock::tryLock()                                 │
    │     └─ CAS(_state, 0, 1)                                │
    │                                                         │
    │ [4] StackWalker::walkVM()                               │
    │     ├─ 解释器帧解析                                     │
    │     ├─ JIT 编译帧解析                                   │
    │     └─ 内联帧处理                                       │
    │                                                         │
    │ [5] CallTraceStorage::put()                             │
    │     ├─ MurmurHash64A 哈希                               │
    │     ├─ 哈希表查找/插入                                  │
    │     ├─ LinearAllocator::alloc()                         │
    │     └─ 返回 call_trace_id                               │
    │                                                         │
    │ [6] 返回 trace_id = (tid << 32) | call_trace_id         │
    └─────────────────────────────────────────────────────────┘
          │
          v
    CPU 从 ucontext 恢复寄存器
    PC = 返回地址（跳过 send_allocation_in_new_tlab）
    继续执行 Java 代码
```

---

## 5. 关键数据结构（内存布局）

### 5.1 ucontext_t（Linux x86_64）

```c
struct ucontext_t {
    unsigned long uc_flags;        // offset 0
    struct ucontext_t *uc_link;    // offset 8
    stack_t uc_stack;              // offset 16 (24 bytes)
    // ...
    mcontext_t uc_mcontext;        // offset ~128
};

struct mcontext_t {
    gregset_t gregs;  // long gregs[23]
    // gregs[0] = R8
    // gregs[1] = R9
    // ...
    // gregs[12] = RDI
    // gregs[13] = RSI
    // gregs[14] = RDX
    // gregs[15] = RCX
    // gregs[16] = RIP
    // ...
    // gregs[19] = RSP
};
```

### 5.2 Klass（JVM 内部）

```cpp
// hotspot/share/oops/klass.hpp
class Klass : public Metadata {
    Klass* _super;                    // offset 0
    Array<Method*>* _methods;         // offset 8
    Array<Method*>* _default_methods; // offset 16
    // ...
    Symbol* _name;                    // offset ? (_klass_name_offset)
    // ...
};
```

### 5.3 Symbol（JVM 内部）

```cpp
// hotspot/share/oops/symbol.hpp
class Symbol : public MetaspaceObj {
    u16 _length;                      // offset 0
    char _body[1];                    // offset 2 (变长)
};
```

### 5.4 CallTrace（AsyncProfiler）

```cpp
struct CallTrace {
    int num_frames;                   // 帧数量
    ASGCT_CallFrame frames[1];        // 帧数组（变长）
};

struct ASGCT_CallFrame {
    jint bci;                         // 字节码索引或特殊标记
    jmethodID method_id;              // 方法 ID 或类 ID
};
```

---

## 6. 总结

本文档深入到每个方法的最底层实现，展示了：

1. **寄存器访问**：`_ucontext->uc_mcontext.gregs[REG_XXX]`
2. **栈操作**：`((uintptr_t*)sp())[slot]`
3. **原子操作**：`__sync_bool_compare_and_swap()`
4. **系统调用**：`syscall(SYS_gettid)`
5. **CPU 指令**：`RDTSC`, `CMPXCHG`
6. **哈希算法**：FNV-1a, MurmurHash64A
7. **内存布局**：ucontext, Klass, Symbol, CallTrace

每一行代码都追踪到最终的实现，包括编译器内联函数、CPU 指令和系统调用。
