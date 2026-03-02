# 7.1 分配追踪 — AllocTracer (Trap) + ObjectSampler (JVMTI)

> 源文件: `allocTracer.cpp` (123行), `trap.cpp` (65行), `objectSampler.cpp` (194行)
> 关联: `arch.h` (BREAKPOINT/instruction_t), `engine.h` (updateCounter), `profiler.cpp` (selectAllocEngine/setupSignalHandlers)
> 前置章节: 3.1 Engine 体系, 5.1 recordSample

---

## 核心问题

**CPU/Wall 采样只告诉你"代码在哪里花了时间"，但对于 Java 应用最常见的性能问题——GC 压力——根本原因是"代码在哪里分配了对象"。如何追踪每一次对象分配并记录分配栈？**

async-profiler 提供了**两种分配追踪引擎**，根据 JDK 版本自动选择：

| JDK 版本 | 引擎 | 机制 | 核心技术 |
|---------|------|------|---------|
| JDK 7~10 | **AllocTracer** | 在 JVM 代码中植入 INT3 断点 | mprotect + 指令替换 |
| JDK 11+ | **ObjectSampler** | JVMTI 原生回调 | SetHeapSamplingInterval |

---

## 一、引擎选择 — selectAllocEngine

### 1.1 选择逻辑

```cpp
// profiler.cpp
Engine* Profiler::selectAllocEngine(long alloc_interval, bool live) {
    if (VM::addSampleObjectsCapability()) {
        return &object_sampler;       // JDK 11+: JVMTI 原生支持
    } else if (VM::isOpenJ9()) {
        return &j9_object_sampler;    // OpenJ9: 扩展事件
    } else {
        return &alloc_tracer;         // JDK 7~10: Trap 方式
    }
}
```

**关键判断**：`VM::addSampleObjectsCapability()` 检查 JVMTI 是否支持 `can_generate_sampled_object_alloc_events` 能力（JDK 11 引入的 JEP 331）。

### GDB 验证

```
=== JDK 11 环境下 ===
命中断点: ObjectSampler::start    ✅ 走 JVMTI 路径
未命中:   AllocTracer::start      ✅ 不走 Trap 路径

→ JDK 11 自动选择 ObjectSampler，不安装 INT3 断点
```

---

## 二、AllocTracer — Trap 断点植入（JDK 7~10 路径）

### 2.1 设计思路

**问题**：JDK 7~10 没有 `SampledObjectAlloc` 回调，如何拦截对象分配？

**关键洞察**：JVM 每次分配对象后，都会调用 `AllocTracer::send_allocation_in_new_tlab()` 或 `send_allocation_outside_tlab()` 来发送 JFR 事件。这两个函数就是天然的 hook 点。

**方案**：在这两个函数的入口处，用 **INT3 断点指令（`0xCC`）** 替换原始指令。当 JVM 执行到此处时触发 `SIGTRAP`，async-profiler 的信号处理器接管，提取参数信息后模拟 `ret` 返回。

### 2.2 JVM 中的原始函数

```cpp
// hotspot/share/gc/shared/allocTracer.cpp (JVM 源码)
void AllocTracer::send_allocation_in_new_tlab(
    Klass* klass,       // arg0 (RDI): 分配对象的类
    HeapWord* obj,      // arg1 (RSI): 对象地址
    size_t tlab_size,   // arg2 (RDX): 新 TLAB 的大小
    size_t alloc_size,  // arg3 (RCX): 实际分配大小
    Thread* thread)     // arg4 (R8):  线程
{
    // 发送 JFR 事件
    EventObjectAllocationInNewTLAB event;
    if (event.should_commit()) {
        event.set_objectClass(klass);
        event.set_allocationSize(alloc_size);
        event.set_tlabSize(tlab_size);
        event.commit();
    }
}
```

**调用时机**：

```
对象分配 (MemAllocator::allocate)
  └── Allocation::notify_allocation()
      └── notify_allocation_jfr_sampler()
          ├── 如果 TLAB 被重填: send_allocation_in_new_tlab(klass, obj, tlab_size, alloc_size, thread)
          └── 如果在 TLAB 外分配: send_allocation_outside_tlab(klass, obj, alloc_size, thread)
```

### GDB 验证 — 原始函数入口

```
=== 正常 JVM（无 profiler）===
send_allocation_in_new_tlab at 0x7ffff5b69fa4:
  0x7ffff5b69fa4:  push   %rbp          ← 字节: 0x55 0x48 0x89 0xe5
  0x7ffff5b69fa5:  mov    %rsp,%rbp
  0x7ffff5b69fa8:  sub    $0x90,%rsp
  
send_allocation_outside_tlab at 0x7ffff5b69f12:
  0x7ffff5b69f12:  push   %rbp          ← 字节: 0x55 0x48 0x89 0xe5
  0x7ffff5b69f13:  mov    %rsp,%rbp

参数验证（首次触发）：
  klass     = 0x800000c40 (某个 Klass 指针)
  obj       = 0x7ffc00000 (HeapWord*)
  tlab_size = 2,097,152 (2MB — 约半个 4MB Region)
  alloc_size= 16 bytes (最小对象)
```

### 2.3 符号查找

```cpp
Error AllocTracer::initialize() {
    CodeCache* libjvm = VMStructs::libjvm();
    const void* ne;
    const void* oe;

    // 按 C++ mangled name 查找函数地址
    if ((ne = libjvm->findSymbolByPrefix("_ZN11AllocTracer27send_allocation_in_new_tlab")) != NULL &&
        (oe = libjvm->findSymbolByPrefix("_ZN11AllocTracer28send_allocation_outside_tlab")) != NULL) {
        _trap_kind = 1;  // JDK 10+: 参数从 arg2 开始读 size
    } else if (...) {
        _trap_kind = 2;  // JDK 7-9: 参数从 arg1 开始读 size
    }
}
```

**`_trap_kind` 的作用**：不同 JDK 版本的函数签名不同，参数位置不同：

| JDK 版本 | 函数签名 | tlab_size 位置 | alloc_size 位置 |
|---------|---------|---------------|----------------|
| JDK 10+ | `send_allocation_in_new_tlab(Klass*, HeapWord*, size_t, size_t, Thread*)` | arg2 (RDX) | arg3 (RCX) |
| JDK 7-9 | `send_allocation_in_new_tlab_event(KlassHandle, size_t, size_t)` | arg1 (RSI) | arg2 (RDX) |

---

## 三、Trap 类 — 断点植入的核心

### 3.1 内存布局

```cpp
class Trap {
    int _id;                       // Trap 编号 (0 或 1)
    bool _unprotect;               // install 时是否需要 mprotect W+X
    bool _protect;                 // install 后是否恢复 R+X
    uintptr_t _entry;              // 断点植入地址
    instruction_t _breakpoint_insn; // 断点指令 (x86_64: 0xCC)
    instruction_t _saved_insn;     // 被替换的原始指令 (通常是 0x55 = push %rbp)
};
```

### 3.2 各平台断点指令

| 架构 | `instruction_t` 类型 | `BREAKPOINT` 值 | 含义 |
|-----|---------------------|-----------------|------|
| **x86_64** | `unsigned char` (1字节) | `0xCC` | INT3 |
| ARM | `unsigned int` (4字节) | `0xe7f001f0` | UDF |
| AArch64 | `unsigned int` (4字节) | `0xd4200000` | BRK #0 |
| PPC64le | `unsigned int` (4字节) | `0x7fe00008` | trap |
| RISC-V | `unsigned int` (2/4字节) | `0x9002` / `0x00100073` | EBREAK |

**x86_64 的优势**：INT3 只有 1 字节，替换 `push %rbp`（也是 1 字节）非常精确，不需要处理指令对齐问题。

### 3.3 assign — 记录目标地址

```cpp
void Trap::assign(const void* address, uintptr_t offset) {
    _entry = (uintptr_t)address + offset;  // x86_64: offset=0（函数最开头）
    _saved_insn = *(instruction_t*)_entry;  // 保存原始指令 (0x55)
    _page_start[_id] = _entry & -OS::page_size;  // 记录所在页的起始地址
}
```

### 3.4 pair — 页面优化

```cpp
void Trap::pair(Trap& second) {
    // 两个 Trap 可能在同一个内存页上
    if (_page_start[_id] == _page_start[second._id]) {
        _protect = false;        // 第一个 Trap: install 后不恢复保护
        second._unprotect = false; // 第二个 Trap: install 前不需要去保护
    }
}
```

**设计意图**：`mprotect` 是昂贵的系统调用。如果两个 Trap 目标在同一个页面内，只需要一次 `mprotect(W)` → 修改两处 → 一次 `mprotect(R+X)`。

### 3.5 install — 植入断点

```cpp
bool Trap::patch(instruction_t insn) {
    // 1. 让目标页面可写
    if (_unprotect) {
        int prot = WX_MEMORY ? (PROT_READ | PROT_WRITE)
                             : (PROT_READ | PROT_WRITE | PROT_EXEC);
        OS::mprotect((void*)(_entry & -OS::page_size), OS::page_size, prot);
    }

    // 2. 替换指令
    *(instruction_t*)_entry = insn;   // 写入 0xCC (INT3)

    // 3. 刷新 CPU 指令缓存
    flushCache(_entry);
    // x86_64: asm volatile("mfence; clflush (%0); mfence")

    // 4. 恢复页面保护
    if (_protect) {
        OS::mprotect((void*)(_entry & -OS::page_size), OS::page_size, PROT_READ | PROT_EXEC);
    }
    return true;
}
```

**完整流程图**：

```
install():
┌─────────────────────────────────────────────┐
│ 原始内存: ... 55 48 89 e5 ...               │
│                ^                            │
│                │ push %rbp                  │
│                                             │
│ 1. mprotect(page, PROT_READ|WRITE|EXEC)    │
│                                             │
│ 2. *(instruction_t*)entry = 0xCC            │
│                                             │
│ 修改后:  ... CC 48 89 e5 ...               │
│                ^                            │
│                │ INT3 (trap!)               │
│                                             │
│ 3. mfence; clflush; mfence                  │
│                                             │
│ 4. mprotect(page, PROT_READ|EXEC)           │
└─────────────────────────────────────────────┘

uninstall():
  *(instruction_t*)entry = 0x55  → 恢复 push %rbp
```

### 3.6 WX_MEMORY — Apple Silicon 特殊处理

```cpp
#if defined(__aarch64__) && defined(__APPLE__)
#  define WX_MEMORY  true    // Apple M1: 内存要么可写要么可执行，不能同时
#else
#  define WX_MEMORY  false   // Linux: 可以 W+X 共存
#endif
```

在 Apple Silicon 上，`mprotect` 不允许同时设置 `PROT_WRITE | PROT_EXEC`（W^X 策略），所以需要先去掉 X 权限写入，再恢复 X 去掉 W。

---

## 四、trapHandler — SIGTRAP 信号处理

### 4.1 信号路由

```
setupSignalHandlers():
  OS::installSignalHandler(SIGTRAP, AllocTracer::trapHandler)
                                       │
JVM 执行到 INT3 (0xCC)                 │
  → 内核发送 SIGTRAP                   │
  → AllocTracer::trapHandler ──────────┘
       │
       ├── _in_new_tlab.covers(pc)?    → 处理 TLAB 内分配
       ├── _outside_tlab.covers(pc)?   → 处理 TLAB 外分配
       └── else                        → 转发给 Profiler::trapHandler
                                          (处理 begin/end profiling window)
```

### 4.2 covers — PC 匹配

```cpp
bool covers(uintptr_t pc) {
    return pc - _entry <= sizeof(instruction_t);
}
```

**为什么是 `<=` 而不是 `==`？**

因为 x86_64 的 INT3 触发后，`RIP` 可能指向：
- **0xCC 指令本身**（`pc == _entry`）：某些内核版本
- **0xCC 之后的下一条指令**（`pc == _entry + 1`）：大多数内核版本

所以用 `pc - _entry <= 1`（`sizeof(instruction_t)` 在 x86_64 上 = 1）来覆盖两种情况。

### 4.3 参数提取

```cpp
void AllocTracer::trapHandler(int signo, siginfo_t* siginfo, void* ucontext) {
    StackFrame frame(ucontext);

    if (_in_new_tlab.covers(frame.pc())) {
        event_type = ALLOC_SAMPLE;
        total_size = _trap_kind == 1 ? frame.arg2() : frame.arg1();     // tlab_size
        instance_size = _trap_kind == 1 ? frame.arg3() : frame.arg2();  // alloc_size
    } else if (_outside_tlab.covers(frame.pc())) {
        event_type = ALLOC_OUTSIDE_TLAB;
        total_size = _trap_kind == 1 ? frame.arg2() : frame.arg1();     // alloc_size
        instance_size = 0;
    }
    // ...
}
```

**x86_64 SysV ABI 参数寄存器映射**：

| 方法 | 寄存器 | JDK 10+ send_allocation_in_new_tlab |
|------|-------|-------------------------------------|
| `arg0()` | RDI | `Klass* klass` |
| `arg1()` | RSI | `HeapWord* obj` |
| `arg2()` | RDX | `size_t tlab_size` |
| `arg3()` | RCX | `size_t alloc_size` |

### 4.4 模拟 ret — 跳过被 hook 的函数

```cpp
// 提取 klass 参数
uintptr_t klass = frame.arg0();

// 模拟 "ret" 指令: 弹出返回地址到 PC，SP+8
frame.ret();
```

```cpp
// stackFrame_x64.cpp
void StackFrame::ret() {
    pc() = stackAt(0);  // PC = [RSP]（栈顶是返回地址）
    sp() += 8;          // RSP += 8（弹出返回地址）
}
```

**效果**：INT3 触发时，函数还没有执行（`push %rbp` 被替换了）。`frame.ret()` 直接修改 ucontext 中的 RIP 和 RSP，相当于让 CPU 认为函数已经 return 了。信号处理器返回后，线程从调用点的下一条指令继续执行。

```
正常调用流: call send_allocation_in_new_tlab
            push %rbp        ← 被 INT3 替换
            mov %rsp, %rbp
            ... 函数体 ...
            ret

Trap 调用流: call send_allocation_in_new_tlab
            INT3 (0xCC)      ← 触发 SIGTRAP
                              ↓
            trapHandler:
              提取 klass, tlab_size, alloc_size
              frame.ret()    → 修改 RIP=[RSP], RSP+=8
                              ↓
            返回调用点下一条指令   ← 函数被完全跳过！
```

### 4.5 采样计数器

```cpp
if (_enabled && updateCounter(_allocated_bytes, total_size, _interval)) {
    recordAllocation(ucontext, event_type, klass, total_size, instance_size);
}
```

`updateCounter` 是一个无锁的 CAS 计数器：

```cpp
static bool updateCounter(volatile u64& counter, u64 value, u64 interval) {
    if (interval <= 1) return true;  // 全采样
    
    while (true) {
        u64 prev = counter;
        u64 next = prev + value;
        if (next < interval) {
            // 还没达到阈值，只累加
            if (__sync_bool_compare_and_swap(&counter, prev, next)) return false;
        } else {
            // 达到阈值！记录采样
            if (__sync_bool_compare_and_swap(&counter, prev, next % interval)) return true;
        }
    }
}
```

**效果**：如果 `_interval = 524287`（512KB-1），则大约每分配 512KB 数据记录一次采样。`next % interval` 确保超额的部分不丢失，累积到下一个周期。

**CAS 自旋**：多个线程可能同时分配对象、同时触发 trap，所以用原子 CAS 避免锁。

---

## 五、ObjectSampler — JVMTI 原生采样（JDK 11+）

### 5.1 为什么 JDK 11+ 不需要 Trap？

JDK 11 引入了 **JEP 331: Low-Overhead Heap Profiling**，在 JVMTI 中增加了 `SampledObjectAlloc` 事件和 `SetHeapSamplingInterval` API。JVM 自己在分配路径中内置了采样逻辑，不再需要外部 hook。

### 5.2 启动

```cpp
Error ObjectSampler::start(Arguments& args) {
    _interval = args._alloc > 0 ? args._alloc : DEFAULT_ALLOC_INTERVAL;  // 默认 524287 (≈512KB)
    
    initLiveRefs(args._live);  // 如果需要追踪存活对象
    
    jvmtiEnv* jvmti = VM::jvmti();
    jvmti->SetHeapSamplingInterval(_interval);  // 告诉 JVM 每隔多少字节采样一次
    jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_SAMPLED_OBJECT_ALLOC, NULL);
    jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_GARBAGE_COLLECTION_START, NULL);
    
    return Error::OK;
}
```

### GDB 验证

```
=== ObjectSampler::start (JDK 11) ===
_interval = 524287 (DEFAULT_ALLOC_INTERVAL ≈ 512KB)  ✅
_alloc    = 0 (用户未指定，用默认值)                   ✅
_live     = false                                      ✅
→ 调用 SetHeapSamplingInterval(524287)
→ 调用 SetEventNotificationMode(ENABLE, SAMPLED_OBJECT_ALLOC)
→ 调用 SetEventNotificationMode(ENABLE, GC_START)
```

### 5.3 回调处理

```cpp
void ObjectSampler::SampledObjectAlloc(jvmtiEnv* jvmti, JNIEnv* jni, jthread thread,
                                       jobject object, jclass object_klass, jlong size) {
    if (_enabled) {
        recordAllocation(jvmti, jni, ALLOC_SAMPLE, object, object_klass, size);
    }
}

void ObjectSampler::recordAllocation(jvmtiEnv* jvmti, JNIEnv* jni, EventType event_type,
                                     jobject object, jclass object_klass, jlong size) {
    AllocEvent event;
    event._start_time = TSC::ticks();
    event._total_size = size > _interval ? size : _interval;  // 至少为 interval
    event._instance_size = size;
    event._class_id = lookupClassId(jvmti, object_klass);
    
    u64 trace = Profiler::instance()->recordSample(NULL, event._total_size, event_type, &event);
    
    if (_live && trace != 0) {
        live_refs.add(jni, object, size, trace);  // 追踪存活对象
    }
}
```

**与 AllocTracer 的关键差异**：
1. **ucontext = NULL**：JVMTI 回调不在信号上下文中，没有 ucontext。`recordSample(NULL, ...)` 会使用 `AsyncGetCallTrace` 获取栈（而非 custom 栈回溯）
2. **size 保底**：`event._total_size = size > _interval ? size : _interval` — 确保大对象不被低估，小对象至少算 interval 字节

### 5.4 Live Object 追踪

ObjectSampler 独有的能力 — 追踪**仍然存活的对象**：

```cpp
class LiveRefs {
    enum { MAX_REFS = 1024 };
    SpinLock _lock;
    jweak _refs[MAX_REFS];         // Weak 引用数组
    struct {
        jlong size;
        u64 trace;                 // 高32位=tid, 低32位=call_trace_id
        u64 time;
    } _values[MAX_REFS];
};
```

**原理**：
1. 每次采样时，创建对象的 `WeakGlobalRef`
2. GC 时检查 weak ref 是否被回收（`collected(w)` 检查对象头是否为 NULL）
3. dump 时，只输出**仍然存活**的对象 → 精确定位内存泄漏

```
alloc → add(object, size, trace)
            ↓
    _refs[i] = jni->NewWeakGlobalRef(object)
    _values[i] = {size, trace, time}
            ↓
    GC 发生 → gc() → _full = false (允许新增)
            ↓
    dump() → 遍历 _refs
        ├── NewLocalRef(weak) != NULL → 对象存活 → recordExternalSamples
        └── NewLocalRef(weak) == NULL → 对象已回收 → 跳过
```

---

## 六、AllocTracer vs ObjectSampler — 完整对比

| 维度 | AllocTracer (Trap) | ObjectSampler (JVMTI) |
|------|-------------------|----------------------|
| **适用版本** | JDK 7~10 | JDK 11+ |
| **hook 方式** | mprotect + INT3 指令替换 | JVMTI SetEventNotificationMode |
| **采样控制** | 自己的 CAS 计数器 | JVM 内置 SetHeapSamplingInterval |
| **栈获取** | 信号 ucontext → custom 栈回溯 | JVMTI → AsyncGetCallTrace |
| **信号** | SIGTRAP | 无（JVMTI 回调） |
| **Live 追踪** | ❌ 不支持 | ✅ WeakGlobalRef |
| **侵入性** | 高（修改 JVM 代码段） | 低（标准 JVMTI API） |
| **安全性** | 有风险（指令缓存、W^X） | 安全（JVM 原生支持） |
| **精度** | 每次 TLAB 重填时触发 | JVM 精确控制采样间隔 |
| **默认间隔** | 自定义 (alloc > 0) 或全采 | 524287 bytes (≈512KB) |

---

## 七、TLAB 与分配追踪的关系

### 7.1 为什么 Trap 只在 TLAB 边界触发？

```
对象分配快速路径 (Thread Local Allocation Buffer):
  top += size     // 指针碰撞，无任何调用
  if (top <= end) return obj  ← 99% 的分配走这里，无 trap

TLAB 慢速路径:
  top > end  →  需要新 TLAB
    ├── 向 GC 申请新 TLAB
    ├── send_allocation_in_new_tlab(klass, obj, tlab_size, alloc_size)  ← TRAP 在这里
    └── 在新 TLAB 中分配

超大对象:
  size > TLAB 剩余 → 直接堆上分配
    └── send_allocation_outside_tlab(klass, obj, alloc_size)  ← TRAP 在这里
```

**所以 AllocTracer 不是每次分配都采样**，而是在 **TLAB 重填**或**TLAB 外分配**时才触发。TLAB 默认大小约 64KB~2MB，这意味着大约每分配几百 KB 到几 MB 才触发一次——天然就是一种采样。

### 7.2 ObjectSampler 的采样时机

JDK 11+ 的 `SetHeapSamplingInterval` 在 TLAB 内部实现了精确采样——通过在 TLAB 的 end 指针上设置 "sample end"，使得当分配达到阈值时触发慢速路径，进入 JVMTI 回调。

```
TLAB 布局:
┌────────────────────────────────────────────┐
│ start       top    sample_end          end │
│   │          │         │                │  │
│   ├──已分配──┤  可用  │  ← 到这里触发  │  │
│   │          │         │    采样回调     │  │
└────────────────────────────────────────────┘
```

---

## 八、信号处理器链 — SIGTRAP 的路由

### 8.1 setupSignalHandlers

```cpp
void Profiler::setupSignalHandlers() {
    // 安装 SIGTRAP 处理器
    SigAction prev_handler = OS::installSignalHandler(SIGTRAP, AllocTracer::trapHandler);
    
    if (prev_handler != SIG_DFL && prev_handler != SIG_IGN) {
        orig_trapHandler = prev_handler;  // 保存原始处理器
    }
    
    // 安装 SIGSEGV/SIGBUS 崩溃处理器
    SigAction prev_segv_handler = OS::installSignalHandler(SIGSEGV, Profiler::crashHandler);
    // ...
}
```

### 8.2 SIGTRAP 分发链

```
SIGTRAP 到达
  → AllocTracer::trapHandler
      │
      ├── _in_new_tlab.covers(pc)?  → 处理分配采样
      │
      ├── _outside_tlab.covers(pc)? → 处理分配采样
      │
      └── else → Profiler::trapHandler
                    │
                    ├── _begin_trap.covers(pc)? → 开始 profiling window
                    │
                    ├── _end_trap.covers(pc)?   → 结束 profiling window
                    │
                    └── else → orig_trapHandler (JVM 原始处理器)
```

---

## 九、完整架构图

```
┌──────────────────────────────────────────────────────────────────┐
│                     async-profiler 分配追踪                       │
│                                                                  │
│  selectAllocEngine()                                             │
│     │                                                            │
│     ├── JDK 11+: addSampleObjectsCapability() == true            │
│     │       │                                                    │
│     │       ▼                                                    │
│     │   ObjectSampler                                            │
│     │     ├── SetHeapSamplingInterval(524287)                    │
│     │     ├── JVMTI_EVENT_SAMPLED_OBJECT_ALLOC → callback        │
│     │     │     └── recordAllocation → recordSample(NULL, ...)   │
│     │     └── Live 追踪: WeakGlobalRef + GC 回调                 │
│     │                                                            │
│     └── JDK 7~10: addSampleObjectsCapability() == false          │
│             │                                                    │
│             ▼                                                    │
│         AllocTracer                                              │
│           ├── initialize():                                      │
│           │   ├── findSymbolByPrefix("send_allocation_*")        │
│           │   ├── Trap::assign(func_addr)                        │
│           │   └── Trap::pair(second_trap)                        │
│           │                                                      │
│           ├── start():                                           │
│           │   ├── Trap::install()                                │
│           │   │   ├── mprotect(PROT_READ|WRITE|EXEC)             │
│           │   │   ├── *entry = 0xCC (INT3)                       │
│           │   │   ├── clflush (刷新指令缓存)                     │
│           │   │   └── mprotect(PROT_READ|EXEC)                   │
│           │   └── installSignalHandler(SIGTRAP, trapHandler)     │
│           │                                                      │
│           ├── JVM 执行到 INT3:                                   │
│           │   → SIGTRAP → trapHandler                            │
│           │     ├── covers(pc)? → 提取 klass, tlab_size          │
│           │     ├── frame.ret() → 跳过原始函数                   │
│           │     └── updateCounter → recordAllocation              │
│           │                                                      │
│           └── stop():                                            │
│               └── Trap::uninstall() → 恢复 0x55 (push %rbp)     │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## 十、面试级知识点

### Q1: async-profiler 的 AllocTracer 为什么不用 JVMTI ObjectAlloc 事件？

**A**: JVMTI 的 `VMObjectAlloc` 事件只能追踪**非 TLAB 分配**（太少了），而 `ObjectAlloc` 回调在 JDK 8~10 上需要开启 `-XX:+ExtendedDTraceProbes` 或类似选项，开销巨大。async-profiler 直接 hook JFR 的通知函数，开销极小——只在 TLAB 边界触发。

### Q2: INT3 指令替换为什么是安全的？

**A**: 四重保障：
1. `mprotect` + `clflush` 保证指令修改在所有 CPU 核心可见
2. `covers()` 用 `pc - entry <= sizeof(instruction_t)` 容忍不同内核的 PC 行为
3. `pair()` 减少 `mprotect` 次数，降低竞态窗口
4. `uninstall()` 在 `stop()` 时恢复原始指令，不留痕迹

### Q3: frame.ret() 模拟返回后，被 hook 的函数完全不执行了？

**A**: 是的。`send_allocation_in_new_tlab` 原本只是发送 JFR 事件——这个 JFR 事件对 JVM 功能没有影响（纯诊断）。async-profiler 用自己的记录逻辑替代了 JFR 事件。

### Q4: updateCounter 为什么用 CAS 而不是 `__sync_add_and_fetch`？

**A**: 因为不是简单累加——需要在达到阈值时重置（`next % interval`）。这是一个 **read-modify-write** 操作，需要原子性地完成"判断是否超过阈值 + 决定新值"这个复合操作。CAS 自旋是最轻量的选择。

### Q5: 为什么 ObjectSampler 的 total_size 用 `max(size, interval)`？

**A**: 如果一个对象实际大小 = 100 字节，但 interval = 512KB，那么这个对象被采样到的概率本来就很低。一旦被采样到，它"代表"的不只是自己，而是这 512KB 窗口内所有未被采样的分配。所以用 `max(size, interval)` 作为权重，保证统计意义上的正确性。

---

## 十一、总结

### AllocTracer 的核心创新

1. **指令级 hook**：用 1 字节的 INT3 替换 `push %rbp`，零额外内存开销
2. **利用 JFR 通知点**：hook JVM 本来就有的分配通知函数，而不是修改分配器本身
3. **frame.ret() 函数跳过**：不执行原始函数，从寄存器提取参数后直接返回
4. **page pair 优化**：减少 mprotect 系统调用次数

### ObjectSampler 的优势

1. **标准 JVMTI API**：无需 hack JVM 代码段
2. **精确采样间隔**：JVM 在 TLAB 内部实现字节级精度
3. **Live 追踪**：WeakGlobalRef + GC 回调，精确定位内存泄漏
4. **安全可靠**：不涉及 mprotect、指令修改、指令缓存刷新

### GDB 验证关键数据

| 验证项 | 值 | 含义 |
|--------|---|------|
| 选中引擎 | ObjectSampler | JDK 11 自动选择 JVMTI 路径 |
| DEFAULT_ALLOC_INTERVAL | 524287 (≈512KB) | 默认每 512KB 采样一次 |
| BREAKPOINT (x86_64) | 0xCC (INT3) | 1 字节断点指令 |
| 原始指令 | 0x55 (push %rbp) | Trap 替换的目标 |
| send_allocation_in_new_tlab | 0x7ffff5b69fa4 | JVM 中的 hook 目标 |
| 首次分配参数 | tlab_size=2MB, alloc_size=16B | TLAB 重填时触发 |

---

*创建日期: 2026-02-09*
*GDB 验证环境: OpenJDK 11 slowdebug + async-profiler v4.0*
*标准条件: -Xms8g -Xmx8g -XX:+UseG1GC -Xint --event alloc*
