# 9.1 GOT/PLT Hook 统一框架 + MallocTracer + Instrument 字节码插桩

> 源文件: `hooks.cpp` (201行), `mallocTracer.cpp` (255行), `instrument.cpp` (1280行)
> 关联: `codeCache.cpp/h` (GOT patch 基础设施), `event.h` (MallocEvent/MethodTraceEvent), `incbin.h`
> 前置章节: 8.1 LockTracer (GOT patch 原理已介绍)

---

## 核心问题

async-profiler 需要拦截多种系统级函数：`pthread_create/exit`、`dlopen`、`malloc/free`、`pthread_mutex_lock` 等。这些函数分布在不同的共享库中（glibc、libpthread），且 async-profiler 可能以两种方式加载——`-agentpath`（attach 模式）和 `LD_PRELOAD`（预加载模式）。

**问题**：如何设计一套统一的 hook 框架，支持两种加载模式，覆盖所有已加载和将来加载的共享库？

---

## 一、Hooks 框架 — 统一 Hook 调度器

### 1.1 两种 Hook 模式

| 模式 | 加载方式 | Hook 机制 | 覆盖范围 |
|------|---------|----------|---------|
| **GOT Patch** | `-agentpath` (attach) | 修改 GOT 表条目 | 已加载的所有 .so |
| **LD_PRELOAD** | `LD_PRELOAD=libasyncProfiler.so` | 符号覆盖（link-time） | 所有 .so（包括未来的） |

async-profiler 同时支持两种模式，且**两者可以共存**。

### 1.2 LD_PRELOAD 模式 — 符号覆盖

当 `LD_PRELOAD` 加载 libasyncProfiler.so 时，动态链接器会优先使用它导出的同名函数：

```cpp
// 通过 WEAK + DLLEXPORT 导出，覆盖 libc 中的同名函数
extern "C" WEAK DLLEXPORT
int pthread_create(pthread_t* thread, const pthread_attr_t* attr,
                   ThreadFunc start_routine, void* arg) {
    if (_orig_pthread_create == NULL) {
        _orig_pthread_create = ADDRESS_OF(pthread_create);  // 查找真实的 pthread_create
    }
    if (Hooks::initialized()) {
        return pthread_create_hook(thread, attr, start_routine, arg);
    }
    return _orig_pthread_create(thread, attr, start_routine, arg);
}
```

**ADDRESS_OF 宏**：

```cpp
#define ADDRESS_OF(sym) ({ \
    void* addr = dlsym(RTLD_NEXT, #sym); \
    addr != NULL ? (sym##_t)addr : sym;  \
})
```

- `dlsym(RTLD_NEXT, "pthread_create")` → 查找**下一个**同名符号（跳过当前 .so，找到 libpthread 中的真实函数）
- 如果 `dlsym` 失败（不是 LD_PRELOAD 模式），回退到直接引用

**设计要点**：
- `WEAK` 属性：允许同名符号被其他库覆盖（不会链接冲突）
- `Hooks::initialized()` 检查：在 async-profiler 完成初始化前，直接转发给原始函数
- 三个函数被覆盖：`pthread_create`、`pthread_exit`、`dlopen`

### 1.3 GOT Patch 模式 — 修改 GOT 表

当通过 `-agentpath` 加载时（attach 模式），不能使用 LD_PRELOAD，需要修改已加载库的 GOT 表：

```cpp
void Hooks::patchLibraries() {
    MutexLocker ml(_patch_lock);

    CodeCacheArray* native_libs = Profiler::instance()->nativeLibs();
    int native_lib_count = native_libs->count();

    while (_patched_libs < native_lib_count) {
        CodeCache* cc = (*native_libs)[_patched_libs++];
        UnloadProtection handle(cc);
        if (!handle.isValid()) continue;

        if (!cc->contains((const void*)Hooks::init)) {
            // 跳过 libasyncProfiler 自身 — 它需要使用原始 dlopen
            cc->patchImport(im_dlopen, (void*)dlopen_hook);
        }
        cc->patchImport(im_pthread_create, (void*)pthread_create_hook);
        cc->patchImport(im_pthread_exit, (void*)pthread_exit_hook);
    }
}
```

**增量 patch**：`_patched_libs` 记录已处理的库数量。新库通过 `dlopen_hook` 检测到后自动 patch。

### 1.4 Hooks::init — 初始化入口

```cpp
bool Hooks::init(bool attach) {
    // CAS 保证只初始化一次
    if (!__sync_bool_compare_and_swap(&_initialized, false, true)) {
        return false;
    }

    Profiler::setupSignalHandlers();

    if (attach) {
        // attach 模式：需要主动发现符号和 patch 库
        Profiler::instance()->updateSymbols(false);
        _orig_pthread_create = ADDRESS_OF(pthread_create);
        _orig_pthread_exit = ADDRESS_OF(pthread_exit);
        _orig_dlopen = ADDRESS_OF(dlopen);
        patchLibraries();
    }

    atexit(shutdown);  // 进程退出时清理
    return true;
}
```

### 1.5 dlopen_hook — 新库自动 Hook

```cpp
static void* dlopen_hook_impl(const char* filename, int flags, bool patch) {
    void* result = _orig_dlopen(filename, flags);
    if (result != NULL && filename != NULL) {
        Profiler::instance()->updateSymbols(false);  // 加载新库的符号
        if (patch) {
            Hooks::patchLibraries();           // patch 新库的 GOT
        }
        MallocTracer::installHooks();          // 如果 malloc 追踪开启，patch 新库
        NativeLockTracer::installHooks();      // 如果锁追踪开启，patch 新库
    }
    return result;
}
```

**为什么区分 `patch` 参数？** GOT patch 模式的 `dlopen_hook` 传 `true`（需要 patch 新库），LD_PRELOAD 模式的 `dlopen` 传 `false`（符号覆盖自动生效，不需要 patch）。

### 1.6 thread_start_wrapper — 线程管理

```cpp
static void* thread_start_wrapper(void* e) {
    ThreadEntry* entry = (ThreadEntry*)e;
    ThreadFunc start_routine = entry->start_routine;
    void* arg = entry->arg;
    free(entry);

    unblock_signals();                    // 确保信号未被屏蔽
    CpuEngine::onThreadStart();           // 通知 CPU 引擎新线程启动
    void* result = start_routine(arg);    // 执行用户的线程函数
    CpuEngine::onThreadEnd();             // 通知 CPU 引擎线程结束
    return result;
}
```

**为什么要 hook `pthread_create`？** 两个原因：
1. **信号解屏蔽**：某些库会屏蔽 `SIGPROF`/`SIGVTALRM`，导致 CPU profiler 的定时器信号无法送达新线程
2. **线程生命周期感知**：`CpuEngine` 需要为每个线程安装/卸载定时器

### 1.7 GOT Patch 基础设施完整流程

```
                          ELF 共享库加载
                               │
                    ┌──────────┴──────────┐
                    ▼                     ▼
            Symbols::parseLibrary     addImport(entry, name)
            (解析 ELF 符号表)          (识别 GOT 中的 import)
                    │                     │
                    ▼                     ▼
            CodeCache._blobs[]     CodeCache._imports[id][type]
            (代码符号数组)          (GOT 条目指针数组)
                    │                     │
                    └──────────┬──────────┘
                               ▼
                       patchLibraries()
                               │
                    ┌──────────┴──────────┐
                    ▼                     ▼
           makeImportsPatchable()     patchImport(id, hook)
           (mprotect 让 GOT 可写)     (*entry = hook_func)

GOT 表:
  BEFORE:  GOT[im_malloc]     → 0x7ffff7885bb0 (glibc malloc)
  AFTER:   GOT[im_malloc]     → 0x7ffff7b55xxx (malloc_hook)
```

#### ImportId 全量枚举（14 个可 hook 函数）

```
im_dlopen              → dlopen_hook          (库加载检测)
im_pthread_create      → pthread_create_hook  (线程创建)
im_pthread_exit        → pthread_exit_hook    (线程退出)
im_pthread_mutex_lock  → NativeLockTracer     (互斥锁)
im_pthread_rwlock_rdlock → NativeLockTracer   (读锁)
im_pthread_rwlock_wrlock → NativeLockTracer   (写锁)
im_pthread_setspecific → (TLS 追踪，保留)
im_poll                → (I/O 等待追踪，保留)
im_malloc              → malloc_hook          (内存分配)
im_calloc              → calloc_hook          (内存分配)
im_realloc             → realloc_hook         (内存重分配)
im_free                → free_hook            (内存释放)
im_posix_memalign      → posix_memalign_hook  (对齐分配)
im_aligned_alloc       → aligned_alloc_hook   (对齐分配)
```

---

## 二、MallocTracer — 原生内存追踪引擎

### 2.1 设计思路

**问题**：Java 应用的内存不仅在 JVM 堆上分配，还通过 `malloc`（JNI、DirectByteBuffer、JVM 内部数据结构）分配 native 内存。当出现 RSS 持续增长但 Java 堆使用正常时，通常是 native 内存泄漏。

**方案**：通过 GOT patch 拦截所有 `malloc/calloc/realloc/free/posix_memalign/aligned_alloc`，记录分配大小和调用栈。

### 2.2 六个 Hook 函数

#### malloc_hook — 核心 hook

```cpp
extern "C" void* malloc_hook(size_t size) {
    void* ret = _orig_malloc(size);
    if (MallocTracer::running() && ret && size) {
        MallocTracer::recordMalloc(ret, size);
    }
    return ret;
}
```

**设计**：先调用原始 `malloc` 获取内存地址，再记录。不是在分配前记录——如果分配失败就不记录。

#### realloc_hook — 重分配（= free + malloc）

```cpp
extern "C" void* realloc_hook(void* addr, size_t size) {
    void* ret = _orig_realloc(addr, size);
    if (MallocTracer::running() && ret) {
        if (addr && !MallocTracer::nofree()) {
            MallocTracer::recordFree(addr);    // 先记录释放旧地址
        }
        if (size) {
            MallocTracer::recordMalloc(ret, size);  // 再记录分配新地址
        }
    }
    return ret;
}
```

#### free_hook — 释放追踪

```cpp
extern "C" void free_hook(void* addr) {
    _orig_free(addr);
    if (MallocTracer::running() && !MallocTracer::nofree() && addr) {
        MallocTracer::recordFree(addr);
    }
}
```

**`_nofree` 模式**：当 `--nofree` 参数指定时，不追踪 `free`，只追踪 `malloc`。这适用于只关心"谁分配了最多内存"而不关心泄漏的场景。

### 2.3 detectNestedMalloc — musl libc 兼容

**问题**：在 musl libc 中，`calloc()` 内部会调用 `malloc()`。如果两者都被 hook，同一次分配会被记录两次（double-accounting）。

**检测方法**：

```cpp
static void detectNestedMalloc() {
    CodeCache* libc = Profiler::instance()->findLibraryByAddress((void*)_orig_calloc);

    // 临时把 libc 的 GOT[malloc] 指向检测函数
    libc->patchImport(im_malloc, (void*)nested_malloc_hook);

    _current_thread = pthread_self();
    free(_orig_calloc(1, 1));       // 调一次 calloc，看会不会触发 nested_malloc_hook
    _current_thread = pthread_t(0);
}
```

如果 `_nested_malloc == true`，说明 `calloc` 会内部调用 `malloc`，需要用 `calloc_hook_dummy` 替代 `calloc_hook`：

```cpp
// Dummy hook：不记录分配（让 malloc_hook 记录）
extern "C" NO_OPTIMIZE
void* calloc_hook_dummy(size_t num, size_t size) {
    return _orig_calloc(num, size);
}
```

**NO_OPTIMIZE** 属性：防止编译器将 dummy 函数优化为尾调用（tail call），这会破坏调用栈中的帧链接。

### GDB 验证 — detectNestedMalloc

```
=== MallocTracer::initialize ===                                     ✅
_orig_malloc addr  = 0x7ffff7885bb0    (glibc malloc)
_orig_calloc addr  = 0x7ffff7886c90    (glibc calloc)
_orig_free addr    = 0x7ffff78862e0    (glibc free)
_nested_malloc     = 0                  ← glibc 的 calloc 不调 malloc

→ 在 glibc 环境下，calloc 和 malloc 是独立的
→ 使用完整的 calloc_hook（不是 dummy）
```

### 2.4 resolveMallocSymbols — 强制 GOT 解析

```cpp
static void resolveMallocSymbols() {
    static volatile intptr_t sink;
    void* p0 = malloc(1);
    void* p1 = realloc(p0, 2);
    void* p2 = calloc(1, 1);
    void* p3 = aligned_alloc(1, 1);
    void* p4 = NULL;
    if (posix_memalign(&p4, sizeof(void*), sizeof(void*)) == 0) free(p4);
    free(p3); free(p2); free(p1);
    sink = (intptr_t)p1 + (intptr_t)p2 + (intptr_t)p3 + (intptr_t)p4;
}
```

**为什么要调一遍所有函数？** 因为 ELF 的延迟绑定（lazy binding）——GOT 表中的函数指针初始指向 PLT stub，只有**第一次调用**后才会被动态链接器解析为真实地址。`SAVE_IMPORT` 需要读取已解析的 GOT 条目，所以必须先触发一次延迟绑定。

`sink` 变量用 `volatile` 防止编译器优化掉这些"无用"的调用。

### 2.5 SAVE_IMPORT — 从自身 GOT 表获取原始地址

```cpp
#define SAVE_IMPORT(FUNC) \
    _orig_##FUNC = (decltype(_orig_##FUNC))*lib->findImport(im_##FUNC)
```

- `lib` = libasyncProfiler.so 自身的 CodeCache
- `findImport(im_malloc)` → 返回 libasyncProfiler.so 的 GOT 表中 `malloc` 条目的指针
- `*entry` → 读取该条目的值（即 glibc `malloc` 的真实地址）

**为什么从自身 GOT 表读？** 因为 libasyncProfiler.so 在加载时也链接了 `malloc`，它的 GOT 表中存储着 glibc `malloc` 的地址——这是获取原始函数地址最可靠的方式。

### 2.6 recordMalloc / recordFree

```cpp
void MallocTracer::recordMalloc(void* address, size_t size) {
    if (updateCounter(_allocated_bytes, size, _interval)) {
        MallocEvent event;
        event._start_time = TSC::ticks();
        event._address = (uintptr_t)address;
        event._size = size;
        Profiler::instance()->recordSample(NULL, size, MALLOC_SAMPLE, &event);
    }
}

void MallocTracer::recordFree(void* address) {
    MallocEvent event;
    event._start_time = TSC::ticks();
    event._address = (uintptr_t)address;
    event._size = 0;                          // size=0 表示 free
    Profiler::instance()->recordEventOnly(MALLOC_SAMPLE, &event);
}
```

**关键区别**：
- `recordMalloc` 使用 `updateCounter` 采样（累积分配量超过 `_interval` 才记录）
- `recordFree` **每次都记录**（使用 `recordEventOnly`，不走采样逻辑）

**为什么 free 不采样？** 因为 **泄漏检测**需要精确配对 malloc/free。如果 free 被采样跳过，配对会失败，误报泄漏。

### GDB 验证 — malloc_hook 拦截

```
=== malloc_hook called ===                                           ✅
size = 72

  #0 malloc_hook(size=72)
  #1 os::malloc(size=24, memflags=mtInternal)     ← JVM 的 os::malloc
  #2 AllocateHeap(size=24, flags=mtInternal)      ← JVM 堆外分配
  #3 AllocateHeap(size=24, flags=mtInternal)

→ Hook 成功拦截了 JVM 内部的 native 内存分配
→ os::malloc 请求 24 字节，但传给 glibc 的是 72 字节（含 NMT header）
```

### 2.7 patchLibraries — 增量 patch

```cpp
void MallocTracer::patchLibraries() {
    MutexLocker ml(_patch_lock);

    while (_patched_libs < native_lib_count) {
        CodeCache* cc = (*native_libs)[_patched_libs++];

        cc->patchImport(im_malloc, (void*)malloc_hook);
        cc->patchImport(im_realloc, (void*)realloc_hook);
        cc->patchImport(im_free, (void*)free_hook);
        cc->patchImport(im_aligned_alloc, (void*)aligned_alloc_hook);

        if (_nested_malloc) {
            // musl: calloc 内部调 malloc，用 dummy 防止 double-accounting
            cc->patchImport(im_calloc, (void*)calloc_hook_dummy);
            cc->patchImport(im_posix_memalign, (void*)posix_memalign_hook_dummy);
        } else {
            // glibc: calloc 独立实现，正常 hook
            cc->patchImport(im_calloc, (void*)calloc_hook);
            cc->patchImport(im_posix_memalign, (void*)posix_memalign_hook);
        }
    }
}
```

### 2.8 MallocEvent 结构

```
class MallocEvent : public Event {
    u64 _start_time;       // 分配/释放的 TSC 时间戳
    uintptr_t _address;    // 分配的内存地址
    u64 _size;             // 分配大小（0 表示 free）
};
```

**units = "bytes"**：火焰图中宽度代表**累计分配的字节数**。

---

## 三、Instrument — Java 字节码插桩引擎

### 3.1 设计思路

**问题**：用户想追踪特定 Java 方法的调用——"这个方法被调了几次？每次耗时多少？"。CPU profiler 只能采样到方法"在执行"，无法精确统计"调用了几次"和"每次耗时多少"。

**方案**：通过 JVMTI 的 `ClassFileLoadHook` 事件，在类加载/重定义时修改字节码，在目标方法的入口和每个出口处插入调用 `Instrument.recordEntry()` / `Instrument.recordExit()`。

### 3.2 两种追踪模式

| 模式 | 触发参数 | 插入代码 | 事件类型 | 单位 |
|------|---------|---------|---------|------|
| **方法计数** | `-e ClassName.methodName` | 入口: `recordEntry()` | INSTRUMENTED_METHOD | calls |
| **方法延迟** | `--trace ClassName.methodName` | 入口: `nanoTime() → lstore` + 出口: `recordExit(startTime, latency)` | METHOD_TRACE | ns |

### 3.3 Instrument.java 帮助类

```java
public class Instrument {
    // 方法入口：直接调 native
    public static native void recordEntry();

    // 方法出口（带延迟阈值）：Java 层面做快速过滤
    public static void recordExit(long startTimeNs, long minLatency) {
        if (System.nanoTime() - startTimeNs >= minLatency) {
            recordExit0(startTimeNs);    // 只有超过阈值才调 native
        }
    }

    // 方法出口（无阈值）
    public static void recordExit(long startTimeNs) {
        recordExit0(startTimeNs);
    }

    public static native void recordExit0(long startTimeNs);
}
```

**延迟过滤在 Java 层面完成**：`System.nanoTime() - startTimeNs >= minLatency` 这个比较在 Java 层面执行，只有超过阈值的调用才跨 JNI 调用 `recordExit0`。这避免了每次方法返回都经过 JNI 的开销。

### 3.4 Native 回调实现

#### recordEntry — 方法入口

```cpp
void JNICALL Instrument::recordEntry(JNIEnv* jni, jobject unused) {
    if (!_enabled) return;

    if (shouldRecordSample()) {
        ExecutionEvent event(TSC::ticks());
        Profiler::instance()->recordSample(NULL, _interval, INSTRUMENTED_METHOD, &event);
    }
}
```

**shouldRecordSample** 使用原子计数器实现 1/N 采样：

```cpp
static bool shouldRecordSample() {
    return _interval <= 1 || ((atomicInc(_calls) + 1) % _interval) == 0;
}
```

当 `_interval == 1` 时，每次调用都记录。

#### recordExit0 — 方法出口（带延迟计算）

```cpp
void JNICALL Instrument::recordExit0(JNIEnv* jni, jobject unused, jlong startTimeNs) {
    if (!_enabled) return;

    if (shouldRecordSample()) {
        u64 now_ticks = TSC::ticks();
        u64 duration_ns = OS::nanotime() - (u64)startTimeNs;
        // 将纳秒转为 TSC ticks
        u64 duration_ticks = (u64)((double)duration_ns * TSC::frequency() / NANOTIME_FREQ);
        MethodTraceEvent event(now_ticks - duration_ticks, duration_ticks);
        Profiler::instance()->recordSample(NULL, duration_ns, METHOD_TRACE, &event);
    }
}
```

**时间转换**：Java 层面用 `System.nanoTime()`，C++ 层面用 `TSC::ticks()`。两者需要转换——`duration_ticks = duration_ns * TSC::frequency() / NANOTIME_FREQ`。

### 3.5 BytecodeRewriter — 字节码改写引擎

这是 instrument.cpp 最核心的类（约 900 行），完整的 Java class 文件解析器和改写器。

#### 工作原理

```
原始字节码:
┌─────────────────────────────────────────┐
│ public void targetMethod() {            │
│    0: aload_0                           │
│    1: invokevirtual #42  // doWork()    │
│    4: ireturn                           │
│ }                                       │
└─────────────────────────────────────────┘
                    │
            BytecodeRewriter
                    │
                    ▼
改写后字节码 (方法计数模式, latency == NO_LATENCY):
┌─────────────────────────────────────────┐
│ public void targetMethod() {            │
│    0: invokestatic #N   // recordEntry()│  ← 插入
│    3: nop                               │  ← 对齐填充
│    4: aload_0                           │  ← 原始代码
│    5: invokevirtual #42  // doWork()    │
│    8: ireturn                           │
│ }                                       │
└─────────────────────────────────────────┘

改写后字节码 (方法延迟模式, latency >= 0):
┌─────────────────────────────────────────┐
│ public void targetMethod() {            │
│    0: invokestatic #M   // nanoTime()   │  ← 记录开始时间
│    3: lstore <new_local>                │  ← 存到新局部变量
│    5: nop; nop; nop                     │  ← 对齐填充
│    8: aload_0                           │  ← 原始代码
│    9: invokevirtual #42  // doWork()    │
│   12: lload <new_local>                 │  ← 取出开始时间
│   14: ldc2_w #latency                   │  ← 加载延迟阈值
│   17: invokestatic #P   // recordExit() │  ← 插入
│   20: ireturn                           │  ← 原始 return
│ }                                       │
└─────────────────────────────────────────┘
```

#### 关键设计

**1. NOP 对齐填充**

```cpp
put8(JVM_OPC_nop);  // nop ensures that tableswitch/lookupswitch needs no realignment
```

`tableswitch` 和 `lookupswitch` 指令要求操作数按 4 字节对齐。插入新字节码会改变后续指令的偏移，可能破坏对齐。通过在入口插入精确数量的 NOP，确保原始代码的偏移量变化是 **4 的倍数**（EXTRA_BYTECODES_ENTRY = 8），避免重新对齐。

**2. Relocation Table — 偏移重定位**

```
relocation_table[i] = 原始字节码位置 i 在改写后的偏移增量

例如：
  原始位置 0 → 改写后位置 8  → relocation_table[0] = 8
  原始位置 4 → 改写后位置 12 → relocation_table[4] = 8
  原始位置 8 (有 return) → 改写后位置 24 → relocation_table[8] = 16
```

**3. 跳转修复（两遍扫描）**

```
第一遍扫描：
  - 复制字节码，在 return 前插入 recordExit
  - 记录所有跳转指令的位置到 jumps 向量
  - 构建 relocation_table

第二遍扫描（只处理跳转）：
  for jump in jumps:
    old_offset = code[jump]
    old_target = jump_base + old_offset
    new_target = old_target + relocation_table[old_target]
    new_offset = new_target - new_jump_base
    write(new_offset)
```

**4. 局部变量索引调整**

延迟模式引入了一个新的 `long` 局部变量（`startTime`，占 2 个 slot）。所有原始代码中索引 ≥ `new_local_index` 的局部变量需要 +2：

```cpp
// iload/aload/istore/astore 指令
if (index >= start_time_loc_index) {
    index += 2;
    _dst[_dst_len - 1] = index;
}

// iload_0~astore_3 短形式指令
if (index >= start_time_loc_index) {
    index += 2;
    if (index <= 3) {
        // 还能用短形式
        _dst[_dst_len - 1] = opcode + 2;
    } else {
        // 超出短形式范围，转为长形式 + NOP 填充
        _dst[_dst_len - 1] = new_opcode;
        put8(index);
        put8(JVM_OPC_nop); put8(JVM_OPC_nop); put8(JVM_OPC_nop);
        current_relocation += EXTRA_BYTECODES_INDEXED;
    }
}
```

**5. StackMapTable 改写**

Java 验证器要求每个分支目标都有 StackMapFrame。插入代码改变了偏移量，需要同步更新：

```cpp
Result BytecodeRewriter::rewriteStackMapTable(...) {
    // 延迟模式：在入口处新增一个 append_frame，声明新的 long 局部变量
    if (latency_profiling_ok) {
        put16(number_of_entries + 1);     // 帧数 +1
        put8(252);                        // append_frame (1 个额外 local)
        put16(current_frame_new);         // 偏移
        put8(JVM_ITEM_Long);             // 新 local 的类型
    }

    // 更新所有已有帧的 offset_delta
    for (each frame) {
        u16 new_delta = updateCurrentFrame(old_frame, new_frame, old_delta, relocation_table);
        // 写入新的 delta
    }
}
```

#### 常量池扩展

BytecodeRewriter 在常量池末尾追加 19+ 个常量：

```
原始常量池:
  [1..N]

追加的常量:
  [N+0]  Methodref → Instrument.recordEntry()V
  [N+1]  Class → one/profiler/Instrument
  [N+2]  NameAndType → recordEntry:()V
  [N+3]  Utf8 → "one/profiler/Instrument"
  [N+4]  Utf8 → "recordEntry"
  [N+5]  Utf8 → "()V"
  [N+6]  Methodref → Instrument.recordExit(JJ)V
  [N+7]  NameAndType → recordExit:(JJ)V
  [N+8]  Utf8 → "recordExit"
  [N+9]  Utf8 → "(JJ)V"
  [N+10] Methodref → Instrument.recordExit(J)V
  [N+11] NameAndType → recordExit:(J)V
  [N+12] Utf8 → "(J)V"
  [N+13] Methodref → System.nanoTime()J
  [N+14] Class → java/lang/System
  [N+15] NameAndType → nanoTime:()J
  [N+16] Utf8 → "java/lang/System"
  [N+17] Utf8 → "nanoTime"
  [N+18] Utf8 → "()J"
  [N+19..] Long 常量（延迟阈值）
```

### 3.6 ClassFileLoadHook — JVMTI 回调入口

```cpp
void JNICALL Instrument::ClassFileLoadHook(jvmtiEnv* jvmti, JNIEnv* jni,
                                           jclass class_being_redefined, jobject loader,
                                           const char* name, ...) {
    if (!_running) return;

    if (name == NULL) {
        // 匿名类：尝试从常量池中匹配
        BytecodeRewriter rewriter(class_data, class_data_len, &_targets, nullptr);
        rewriter.rewrite(new_class_data, new_class_data_len);
        return;
    }

    // 查找是否匹配目标类
    const MethodTargets* method_targets = findMethodTargets(&_targets, name, strlen(name));
    if (method_targets != nullptr) {
        BytecodeRewriter rewriter(class_data, class_data_len, nullptr, method_targets);
        rewriter.rewrite(new_class_data, new_class_data_len);
    }
}
```

### 3.7 Target 解析 — 支持多种格式

```
支持的格式：
  com.example.MyClass.myMethod                          → 所有签名
  com.example.MyClass.myMethod(Ljava/lang/String;)V     → 精确签名
  com.example.MyClass.myMethod:50ms                     → 只追踪 ≥50ms 的调用
  com.example.MyClass.*                                 → 通配符（所有方法）
```

### 3.8 start / stop 生命周期

```cpp
Error Instrument::start(Arguments& args) {
    Error error = initialize();          // 加载 Instrument.class
    error = setupTargetClassAndMethod(args);  // 解析目标

    _running = true;

    // 启用类文件加载钩子
    jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_CLASS_FILE_LOAD_HOOK, NULL);
    // 对已加载的匹配类进行重转换
    retransformMatchedClasses(jvmti);

    return Error::OK;
}

void Instrument::stop() {
    _running = false;
    retransformMatchedClasses(jvmti);  // 重新触发 ClassFileLoadHook，但 _running=false → 不插桩 → 恢复原始字节码
    jvmti->SetEventNotificationMode(JVMTI_DISABLE, JVMTI_EVENT_CLASS_FILE_LOAD_HOOK, NULL);
}
```

**stop() 的恢复机制**：调用 `RetransformClasses` 重新触发 `ClassFileLoadHook`，但此时 `_running == false`，回调函数直接返回不修改字节码——JVM 使用原始字节码重新定义类，**自动恢复**。

### GDB 验证 — Instrument 字节码插桩

```
=== ClassFileLoadHook ===                                            ✅
class_name = sun/launcher/LauncherHelper, data_len = 32231

  #0 Instrument::ClassFileLoadHook(name="sun/launcher/LauncherHelper")
  #1 JvmtiClassFileLoadHookPoster::post_to_env()
  #2 JvmtiClassFileLoadHookPoster::post_all_envs()

→ JVMTI 在类加载时回调 ClassFileLoadHook
→ 该类不匹配目标（InstrumentDemo.slowMethod），不会被插桩

=== recordEntry ===                                                  ✅
  #0 Instrument::recordEntry(jni, unused)
  #1 0x00007fffec810f59                    ← Java 解释器
  #2 0x00007ffff780a730                    ← Java 栈帧

→ recordEntry 被成功调用！
→ #1 是 Java 解释器，说明 slowMethod 的字节码已被成功修改
→ 插入的 invokestatic 指令调用了 Instrument.recordEntry()
```

---

## 四、三大引擎的 Hook 架构总览

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        async-profiler Hook 架构                          │
│                                                                          │
│  加载方式                                                                │
│  ═══════                                                                 │
│  LD_PRELOAD ─────→ 符号覆盖 (pthread_create/exit, dlopen)                │
│  -agentpath ─────→ Hooks::init(attach=true) → patchLibraries()          │
│                                                                          │
│  GOT Patch 基础设施 (codeCache.cpp)                                      │
│  ═══════════════════════════════════                                      │
│  ELF 解析 → addImport() → _imports[14][2]                               │
│       ↓                         ↓                                        │
│  makeImportsPatchable()    patchImport(id, hook)                         │
│  (mprotect PROT_RW)       (*GOT_entry = hook_func)                      │
│                                                                          │
│  Hook 消费者                                                             │
│  ═══════════                                                             │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐                   │
│  │   Hooks      │  │ MallocTracer │  │NativeLockTracer│                  │
│  │ (核心框架)    │  │ (内存追踪)    │  │ (锁追踪)       │                  │
│  ├─────────────┤  ├──────────────┤  ├───────────────┤                   │
│  │ dlopen      │  │ malloc       │  │ pthread_mutex │                   │
│  │ pthread_*   │  │ calloc       │  │ pthread_rw*   │                   │
│  │             │  │ realloc      │  │               │                   │
│  │             │  │ free         │  │               │                   │
│  │             │  │ *memalign    │  │               │                   │
│  │             │  │ aligned_alloc│  │               │                   │
│  └─────────────┘  └──────────────┘  └───────────────┘                   │
│       3 个              6 个               3 个                          │
│                                                                          │
│  字节码插桩 (instrument.cpp)                                             │
│  ═══════════════════════════                                             │
│  JVMTI ClassFileLoadHook → BytecodeRewriter                             │
│       ↓                          ↓                                       │
│  类加载/重定义时          解析 class 文件 → 修改目标方法字节码            │
│       ↓                          ↓                                       │
│  Instrument.recordEntry()  Instrument.recordExit(startTime, latency)     │
│       ↓                          ↓                                       │
│  recordSample(INSTRUMENTED_METHOD)  recordSample(METHOD_TRACE)           │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 五、面试级知识点

### Q1: GOT patch 和 LD_PRELOAD 各自的优缺点？

| 维度 | LD_PRELOAD | GOT Patch |
|------|-----------|----------|
| **覆盖范围** | 全局（所有库自动生效） | 需要逐库 patch |
| **加载时机** | 必须在进程启动前设置 | 可以运行时 attach |
| **新加载的库** | 自动生效 | 需要 dlopen_hook 检测 |
| **可逆性** | 不可逆 | 理论上可恢复 GOT 条目 |
| **影响范围** | 影响整个进程 | 可以选择性 patch 特定库 |
| **兼容性** | 某些安全环境禁止 LD_PRELOAD | 需要 mprotect 权限 |

### Q2: MallocTracer 为什么 recordFree 不采样？

因为 **泄漏检测（leak detector）** 需要精确追踪每个分配地址的生命周期。如果 free 被采样跳过，地址 A 的 malloc 被记录但 free 被跳过，泄漏检测器会误认为 A 仍然存活——这是误报。而 `recordMalloc` 可以采样是因为未被采样到的分配不会出现在结果中（被遗漏但不会误报）。

### Q3: BytecodeRewriter 为什么需要两遍扫描？

**第一遍**构建 `relocation_table`（每个位置的偏移增量），同时复制代码。但跳转指令的目标偏移依赖 `relocation_table[target]`——如果跳转目标在当前位置之后（前向跳转），第一遍时该目标的 relocation 还未计算。所以需要**第二遍**专门修复所有跳转偏移。

### Q4: 为什么 Instrument 的 stop() 能恢复原始字节码？

JVMTI 的 `RetransformClasses` 会重新触发 `ClassFileLoadHook`，但传入的 `class_data` 是**类最初加载时的原始字节码**（不是上次修改后的）。当 `_running == false` 时，hook 函数不修改字节码——JVM 就用原始字节码重新定义类，自动完成恢复。

### Q5: resolveMallocSymbols 为什么需要调用每个函数？

ELF 的**延迟绑定（lazy binding）**机制：GOT 表中的函数指针初始值指向 PLT stub（`ld.so` 的解析代码），只有第一次调用后才被替换为真实地址。`SAVE_IMPORT` 从 GOT 表读取原始函数地址，如果函数从未被调用过，读到的是 PLT stub 的地址——保存它作为 `_orig_malloc` 会导致后续调用陷入死循环（PLT stub → dlsym → malloc → PLT stub...）。

---

## 六、总结

### Hooks 框架的核心创新

1. **双模式支持**：LD_PRELOAD（全局符号覆盖）和 GOT Patch（运行时 attach）两种模式无缝切换
2. **增量 patch**：通过 `_patched_libs` 计数器实现只 patch 新加载的库
3. **dlopen 联动**：hook dlopen 确保新加载的库自动被 patch

### MallocTracer 的核心创新

1. **6 函数全覆盖**：malloc/calloc/realloc/free/posix_memalign/aligned_alloc
2. **musl 兼容**：`detectNestedMalloc` 自动检测 calloc 是否内部调 malloc，避免 double-accounting
3. **泄漏检测友好**：malloc 可采样，free 必须全量记录
4. **延迟绑定安全**：`resolveMallocSymbols` 确保 GOT 已解析

### Instrument 的核心创新

1. **完整的字节码改写**：解析整个 class 文件，修改常量池/Code/LineNumberTable/LocalVariableTable/StackMapTable
2. **两种模式**：方法计数（入口 hook）和方法延迟（入口+出口 hook，带阈值过滤）
3. **零侵入恢复**：stop() 通过 RetransformClasses 自动恢复原始字节码
4. **NOP 对齐**：确保 tableswitch/lookupswitch 指令的操作数对齐不被破坏

### GDB 验证关键数据

| 验证项 | 结果 | 含义 |
|--------|------|------|
| malloc_hook 拦截 os::malloc | ✅ size=72 | GOT patch 工作正常 |
| _orig_malloc | 0x7ffff7885bb0 (glibc) | 原始函数地址正确保存 |
| _nested_malloc | 0 (false) | glibc calloc 独立于 malloc |
| ClassFileLoadHook 回调 | ✅ | JVMTI 类文件钩子工作 |
| Instrument::recordEntry 被调用 | ✅ 从 Java 解释器 | 字节码插桩成功 |

---

*创建日期: 2026-02-10*
*GDB 验证环境: OpenJDK 11 slowdebug + async-profiler v4.0*
*标准条件: -Xms8g -Xmx8g -XX:+UseG1GC -Xint*
*测试程序: InstrumentDemo.java (slowMethod + fastMethod)*
