# 8.1 锁争用追踪 — LockTracer (Java 锁) + NativeLockTracer (原生锁)

> 源文件: `lockTracer.cpp` (272行), `nativeLockTracer.cpp` (153行)
> 关联: `codeCache.cpp` (patchImport/GOT hook), `event.h` (LockEvent/NativeLockEvent), `incbin.h` (字节码嵌入)
> 前置章节: 3.1 Engine 体系, 5.1 recordSample, 7.1 分配追踪

---

## 核心问题

**Java 应用的性能瓶颈除了 CPU 和 GC，还有一个常被忽视的杀手——锁争用（Lock Contention）。线程因为等待锁而阻塞，既不消耗 CPU 也不触发 GC，CPU profiler 和 Alloc profiler 都看不到它。如何追踪"线程在哪里等锁、等了多久"？**

async-profiler 提供**两个锁追踪引擎**，分别处理不同层级的锁：

| 引擎 | 追踪目标 | hook 机制 | 事件类型 |
|------|---------|----------|---------|
| **LockTracer** | Java `synchronized` + `ReentrantLock` | JVMTI 回调 + JNI RegisterNatives | LOCK_SAMPLE / PARK_SAMPLE |
| **NativeLockTracer** | `pthread_mutex_lock` + `pthread_rwlock` | GOT/PLT 表 patch | NATIVE_LOCK_SAMPLE |

---

## 一、LockTracer — Java 锁争用追踪

### 1.1 设计思路

Java 有两类锁：
1. **`synchronized`**：基于 JVM 的 ObjectMonitor，有标准的 JVMTI 事件（`MONITOR_CONTENDED_ENTER/ENTERED`）
2. **`ReentrantLock`**：基于 `AbstractQueuedSynchronizer`（AQS），通过 `Unsafe.park()` 阻塞，**没有 JVMTI 事件**

LockTracer 需要同时追踪两种锁。

### 1.2 synchronized 锁的追踪

#### JVMTI 事件对

JVM 在 `ObjectMonitor::enter()` 中，发现锁被其他线程持有时（争用），会发送两个 JVMTI 事件：

```
ObjectMonitor::enter()
  │
  ├── CAS 尝试获取锁 → 成功? → 直接返回（无事件）
  │
  └── CAS 失败（争用发生）
       │
       ├── post_monitor_contended_enter(thread, monitor)  ← 开始等锁
       │     └── → LockTracer::MonitorContendedEnter()    【记录开始时间】
       │
       ├── EnterI(THREAD)  // 真正的阻塞等待
       │
       └── post_monitor_contended_entered(thread, monitor) ← 成功获取锁
             └── → LockTracer::MonitorContendedEntered()   【计算等待时长】
```

#### MonitorContendedEnter — 记录争用开始时间

```cpp
void JNICALL LockTracer::MonitorContendedEnter(jvmtiEnv* jvmti, JNIEnv* env,
                                                jthread thread, jobject object) {
    const u64 enter_time = TSC::ticks();   // 高精度时间戳
    if (CAN_USE_TLS && lock_tracer_tls) {
        pthread_setspecific(lock_tracer_tls, (void*)enter_time);  // 64位: 存 TLS
    } else {
        jvmti->SetTag(thread, enter_time);                        // 32位: 存 JVMTI tag
    }
}
```

**时间存储优化**：在 64 位平台上，`void*` 有 8 字节，可以直接存放 `u64` 时间戳到 pthread TLS 中，比 JVMTI `SetTag/GetTag` 快得多。

#### MonitorContendedEntered — 计算等待时长并采样

```cpp
void JNICALL LockTracer::MonitorContendedEntered(jvmtiEnv* jvmti, JNIEnv* env,
                                                  jthread thread, jobject object) {
    if (!_enabled) return;

    const u64 entered_time = TSC::ticks();
    u64 enter_time = (u64)pthread_getspecific(lock_tracer_tls);

    // 忽略 profiling 开始前就在等的锁
    if (enter_time < _start_time) return;

    // 基于时长的采样：当累积争用时长超过 _interval 时采样
    const u64 duration = entered_time - enter_time;
    if (updateCounter(_total_duration, duration, _interval)) {
        char* lock_name = getLockName(jvmti, env, object);
        recordContendedLock(LOCK_SAMPLE, enter_time, entered_time, lock_name, object, 0);
        jvmti->Deallocate((unsigned char*)lock_name);
    }
}
```

**关键设计**：
1. **时长采样**而非次数采样：不是每 N 次争用记录一次，而是**当累积争用时长超过 `_interval`（默认 10μs）时才记录**。这样高频但短暂的争用不会被过度采样，低频但长时间的争用一定会被捕获
2. **`_start_time` 保护**：`start()` 之前已经在等锁的线程不记录，因为它们的 enter_time 没有被正确初始化

### GDB 验证 — synchronized 争用路径

```
=== JVMTI post_monitor_contended_enter ===                           ✅
  #0 JvmtiExport::post_monitor_contended_enter(thread, obj_mntr)
  #1 ObjectMonitor::enter()                     ← CAS 失败，发现争用
  #2 ObjectSynchronizer::slow_enter()           ← 慢速路径
  #3 ObjectSynchronizer::fast_enter()           ← 入口

=== JVMTI post_monitor_contended_entered ===                         ✅
  #0 JvmtiExport::post_monitor_contended_entered(thread, obj_mntr)
  #1 ObjectMonitor::enter()                     ← 成功获取锁后
  #2 ObjectSynchronizer::slow_enter()

→ 两个事件在同一个 ObjectMonitor::enter() 函数中配对触发
```

---

### 1.3 ReentrantLock 的追踪 — Unsafe.park Hook

#### 为什么需要特殊处理？

`ReentrantLock` 不走 `ObjectMonitor`，它的阻塞路径是：

```
ReentrantLock.lock()
  → AQS.acquire()
    → AQS.parkAndCheckInterrupt()
      → LockSupport.park(blocker)
        → Unsafe.park(false, 0L)           ← JNI native 方法
          → Unsafe_Park()                  ← C++ 实现
            → os::PlatformEvent::park()    ← pthread_cond_wait
```

JVMTI 没有针对 `Unsafe.park` 的事件，所以 async-profiler 需要 **hook `Unsafe.park()` 这个 JNI native 方法**。

#### Hook 安装过程 — 一个精妙的三步曲

**问题**：`Unsafe.park` 是 JVM 内部的 JNI 方法，不能通过普通的 `RegisterNatives` 直接替换——JDK 有安全检查，只允许"受信任的"调用者注册 native 方法。

**解决方案**：三步走

```
Step 1: 找到 Unsafe.park() 的原始 C++ 地址
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
方法：Hook JNI 函数表中的 RegisterNatives，
      然后触发 Unsafe.registerNatives()，
      在 hook 中截获 park 方法的函数指针

  JNI 函数表:
  ┌────────────────────────────┐
  │ RegisterNatives → Hook     │ ← 临时替换
  └────────────────────────────┘
        │
  Unsafe.registerNatives()
        │
  RegisterNativesHook 被调用:
    for method in methods:
      if name == "park" && sig == "(ZJ)V":
        _orig_unsafe_park = method.fnPtr   ← 捕获！

Step 2: 注入 LockTracer Java 帮助类
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
方法：通过 DefineClass 将编译好的 LockTracer.class
      字节码直接注入 JVM（字节码通过 INCBIN 嵌入 .so）

  one.profiler.LockTracer (Java):
  ┌─────────────────────────────────────┐
  │ static void setEntry(long entry) {  │
  │     setEntry0(entry);               │ ← JDK-8238460 的 workaround
  │ }                                   │ ← 需要两层 bootstrap 类帧
  │ static native void setEntry0(long); │ → C++ setEntry0()
  └─────────────────────────────────────┘

Step 3: 通过帮助类替换 park 入口
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  setUnsafeParkEntry(env, UnsafeParkHook):
    env->CallStaticVoidMethod(_LockTracer, _setEntry, entry)
      → LockTracer.setEntry(entry)
        → LockTracer.setEntry0(entry)          // Java 调用 native
          → setEntry0(env, cls, entry):        // C++ 实现
              RegisterNatives(Unsafe, {"park", "(ZJ)V", entry})
                                       ↑
                              用 UnsafeParkHook 替换原始 Unsafe.park！
```

**为什么需要 LockTracer.java 帮助类？**

直接从 native 调 `RegisterNatives` 注册 `Unsafe.park` 会触发 JDK-8238460 的 warning——JDK 要求 `RegisterNatives` 的 Java 调用栈中至少有两个属于 bootstrap ClassLoader 的帧。`LockTracer` 类通过 `DefineClass(NULL)` 被注入到 bootstrap ClassLoader 中，`setEntry() → setEntry0()` 提供了两层 bootstrap 帧。

#### UnsafeParkHook — 拦截 ReentrantLock 争用

```cpp
void JNICALL LockTracer::UnsafeParkHook(JNIEnv* env, jobject instance,
                                        jboolean isAbsolute, jlong time) {
    while (_enabled) {
        // 1. 获取当前线程的 parkBlocker 字段
        jobject park_blocker = getParkBlocker(jvmti, env);
        if (park_blocker == NULL) break;   // 不是锁相关的 park

        // 2. 获取锁类名并过滤
        char* lock_name = getLockName(jvmti, env, park_blocker);
        if (!isConcurrentLock(lock_name)) break;  // 只追踪特定类型的锁

        // 3. 计时 + 调用原始 park
        u64 park_start_time = TSC::ticks();
        _orig_unsafe_park(env, instance, isAbsolute, time);   // 真正阻塞
        u64 park_end_time = TSC::ticks();

        // 4. 基于时长采样
        const u64 duration = park_end_time - park_start_time;
        if (updateCounter(_total_duration, duration, _interval)) {
            recordContendedLock(PARK_SAMPLE, park_start_time, park_end_time,
                                lock_name, park_blocker, time);
        }
        return;
    }

    // 不追踪：直接调用原始 park
    _orig_unsafe_park(env, instance, isAbsolute, time);
}
```

**关键设计**：

1. **parkBlocker 过滤**：`Thread.parkBlocker` 字段记录了当前线程 park 的原因。只有当 parkBlocker 是 `ReentrantLock`、`ReentrantReadWriteLock` 或 `Semaphore` 时才追踪：

```cpp
bool LockTracer::isConcurrentLock(const char* lock_name) {
    return strncmp(lock_name, "Ljava/util/concurrent/locks/Reentrant", 37) == 0 ||
           strncmp(lock_name, "Ljava/util/concurrent/Semaphore", 31) == 0;
}
```

**为什么要过滤？** 因为 `Unsafe.park` 不仅被锁使用，还被 `ThreadPoolExecutor`（worker 等待任务）、`CompletableFuture`、`CountDownLatch` 等使用。这些"等待"不是真正的锁争用，不应该被记录。

2. **`while(_enabled) { ... break; }` 模式**：这不是循环，而是一个 **"break-on-any-failure"** 模式——用 `while + break` 代替 `if-else-if` 嵌套，任何一步检查失败都跳出，最终执行原始 park。

### GDB 验证 — Unsafe.park Hook

```
=== Unsafe_Park called ===                                           ✅
  #0 Unsafe_Park(env, unsafe, isAbsolute=0, time=0)       ← JVM 原始函数
  #1 LockTracer::UnsafeParkHook(env, instance, 0, 0)      ← async-profiler hook
  #2 0x00007fffec810f59                                    ← Java 字节码解释器

→ Hook 成功拦截：UnsafeParkHook 包裹了原始 Unsafe_Park
→ isAbsolute=0, time=0 表示无限期等待（ReentrantLock.lock() 的典型参数）
```

---

### 1.4 recordContendedLock — 记录采样

```cpp
void LockTracer::recordContendedLock(EventType event_type, u64 start_time, u64 end_time,
                                     const char* lock_name, jobject lock, jlong timeout) {
    LockEvent event;
    event._class_id = 0;
    event._start_time = start_time;
    event._end_time = end_time;
    event._address = *(uintptr_t*)lock;    // 锁对象的第一个字（mark word）
    event._timeout = timeout;

    // 将锁类名（如 "Ljava/util/concurrent/locks/ReentrantLock;"）
    // 映射为 class_id
    if (lock_name != NULL) {
        if (lock_name[0] == 'L') {
            // 去掉开头的 'L' 和结尾的 ';'
            event._class_id = Profiler::instance()->classMap()->lookup(
                lock_name + 1, strlen(lock_name) - 2);
        }
    }

    u64 duration_nanos = (u64)((end_time - start_time) * _ticks_to_nanos);
    Profiler::instance()->recordSample(NULL, duration_nanos, event_type, &event);
}
```

**LockEvent 结构**：

```
class LockEvent : public EventWithClassId {
    u32 _class_id;          // 锁类名的 ID
    u64 _start_time;        // 开始等锁的 TSC 时间
    u64 _end_time;          // 获取锁的 TSC 时间
    uintptr_t _address;     // 锁对象地址（mark word）
    long long _timeout;     // park 超时参数（0=无限期）
};
```

**units = "ns"**：锁追踪的采样权重是**纳秒**（等待时长），不像 CPU profiler 的"次数"或 alloc profiler 的"字节"。火焰图中宽度越大，表示**在该栈帧上等待锁的累计时间越长**。

---

### 1.5 start / stop 生命周期

```cpp
Error LockTracer::start(Arguments& args) {
    // TSC → 纳秒的转换系数
    _ticks_to_nanos = 1e9 / TSC::frequency();
    // 采样间隔从纳秒转为 TSC ticks
    _interval = (u64)(args._lock * (TSC::frequency() / 1e9));
    _total_duration = 0;

    // 首次：初始化（查找 Unsafe.park、注入帮助类等）
    if (!_initialized) {
        Error error = initialize(jvmti, env);
        // ...
        _initialized = true;
    }

    // 启用 JVMTI Monitor 事件
    jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_MONITOR_CONTENDED_ENTER, NULL);
    jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_MONITOR_CONTENDED_ENTERED, NULL);
    _start_time = TSC::ticks();

    // 安装 Unsafe.park hook
    setUnsafeParkEntry(env, UnsafeParkHook);
    return Error::OK;
}

void LockTracer::stop() {
    // 禁用 JVMTI Monitor 事件
    jvmti->SetEventNotificationMode(JVMTI_DISABLE, JVMTI_EVENT_MONITOR_CONTENDED_ENTER, NULL);
    jvmti->SetEventNotificationMode(JVMTI_DISABLE, JVMTI_EVENT_MONITOR_CONTENDED_ENTERED, NULL);

    // 注意：不重置 Unsafe.park hook (JDK-8369219)
    // hook 通过 _enabled 标志控制是否采样
}
```

**stop() 不恢复 park hook** 是有意设计——`RegisterNatives` 在某些 JDK 版本中有并发问题（JDK-8369219），频繁替换可能导致崩溃。hook 函数通过检查 `_enabled` 标志来决定是否采样。

---

## 二、NativeLockTracer — 原生锁争用追踪

### 2.1 设计思路

**问题**：JVM 内部大量使用 `pthread_mutex_lock`（如 SafepointSynchronize、ChunkPool、CodeCache 等）。这些原生锁的争用对 Java 应用的性能有直接影响，但 JVMTI 完全无法感知。

**方案**：通过修改 ELF 共享库的 **GOT（Global Offset Table）表**，将 `pthread_mutex_lock` 的函数指针替换为 async-profiler 的 hook 函数。

### 2.2 GOT/PLT Hook 原理

#### ELF 动态链接基础

当 libjvm.so 调用 `pthread_mutex_lock` 时，不是直接调用，而是通过 PLT（Procedure Linkage Table）间接跳转：

```
libjvm.so 代码段:
  call pthread_mutex_lock@plt
       │
       ▼
PLT 条目:
  jmp *GOT[pthread_mutex_lock]    ← 间接跳转
       │
       ▼
GOT 条目 (可写数据段):
  ┌──────────────────────────┐
  │ 0x7ffff78786f0           │ ← pthread_mutex_lock 的真实地址
  └──────────────────────────┘
```

**Hook 方法**：修改 GOT 表中的地址，指向 hook 函数：

```
BEFORE patch:                           AFTER patch:
GOT[pthread_mutex_lock]:                GOT[pthread_mutex_lock]:
┌──────────────────────────┐            ┌──────────────────────────┐
│ 0x7ffff78786f0 (真实)     │     →     │ 0x7ffff7b55191 (hook)    │
└──────────────────────────┘            └──────────────────────────┘
```

### GDB 验证 — GOT patch

```
=== GOT patch verification ===                                       ✅
pthread_mutex_lock_hook addr = 0x7ffff7b55191   (libasyncProfiler.so)
pthread_mutex_lock (real)   = 0x7ffff78786f0    (libpthread.so)

→ GOT 表已被 patch，libjvm.so 中所有 pthread_mutex_lock 调用
  都会先经过 async-profiler 的 hook 函数
```

### 2.3 patchImport 实现

```cpp
void CodeCache::patchImport(ImportId id, void* hook_func) {
    // 1. 确保 GOT 表可写
    if (!_imports_patchable && !makeImportsPatchable()) {
        return;
    }

    // 2. 替换 GOT 表条目（最多有 PRIMARY 和 SECONDARY 两个）
    for (int ty = 0; ty < NUM_IMPORT_TYPES; ty++) {
        void** entry = _imports[id][ty];
        if (entry != NULL) {
            *entry = hook_func;   // 直接写入 hook 函数地址
        }
    }
}
```

#### makeImportsPatchable — 让 GOT 表可写

```cpp
bool CodeCache::makeImportsPatchable() {
    // 找到所有 import 条目的地址范围
    void** min_import = (void**)-1;
    void** max_import = NULL;
    for (int i = 0; i < NUM_IMPORTS; i++) {
        for (int j = 0; j < NUM_IMPORT_TYPES; j++) {
            void** entry = _imports[i][j];
            if (entry == NULL) continue;
            if (entry < min_import) min_import = entry;
            if (entry > max_import) max_import = entry;
        }
    }

    // mprotect 覆盖所有 import 条目的页面
    uintptr_t patch_start = (uintptr_t)min_import & ~OS::page_mask;
    uintptr_t patch_end = (uintptr_t)max_import & ~OS::page_mask;
    OS::mprotect((void*)patch_start,
                 patch_end - patch_start + OS::page_size,
                 PROT_READ | PROT_WRITE);

    _imports_patchable = true;
    return true;
}
```

**注意**：GOT 表通常在 `.got.plt` 段中，这个段在程序加载后默认是 **只读的**（`RELRO` 保护）。`mprotect` 将其改为可写，才能修改 GOT 条目。

#### ImportId 枚举 — 所有可 hook 的函数

```cpp
enum ImportId {
    im_dlopen,              // 动态库加载
    im_pthread_create,      // 线程创建
    im_pthread_exit,        // 线程退出
    im_pthread_mutex_lock,  // 互斥锁
    im_pthread_rwlock_rdlock,  // 读写锁（读）
    im_pthread_rwlock_wrlock,  // 读写锁（写）
    im_pthread_setspecific, // TLS 设置
    im_poll,                // I/O 等待
    im_malloc,              // 内存分配
    im_calloc,
    im_realloc,
    im_free,
    im_posix_memalign,
    im_aligned_alloc,
    NUM_IMPORTS             // = 14
};
```

GOT hook 不仅用于锁追踪，还用于 malloc 追踪、线程管理、符号加载等——它是 async-profiler 的**通用 hook 基础设施**。

### 2.4 三个 hook 函数

#### pthread_mutex_lock_hook

```cpp
extern "C" int pthread_mutex_lock_hook(pthread_mutex_t* mutex) {
    if (!NativeLockTracer::running()) {
        return pthread_mutex_lock(mutex);    // profiling 未启动，直接转发
    }

    // 先尝试 trylock（无争用快速路径）
    if (pthread_mutex_trylock(mutex) == 0) {
        return 0;                            // 无争用，零开销
    }

    // 有争用：计时 + 阻塞
    u64 start_time = TSC::ticks();
    int ret = pthread_mutex_lock(mutex);
    u64 end_time = TSC::ticks();

    if (ret == 0) {
        NativeLockTracer::recordNativeLock(mutex, start_time, end_time);
    }
    return ret;
}
```

**精妙的 trylock 优化**：

```
无争用场景（99%）:
  pthread_mutex_trylock(mutex) → 0 (成功)
  → 直接返回，零额外开销！

有争用场景（1%）:
  pthread_mutex_trylock(mutex) → EBUSY (失败)
  → 记录开始时间
  → pthread_mutex_lock(mutex)     // 真正阻塞
  → 记录结束时间
  → recordNativeLock()            // 采样
```

**设计洞察**：绝大多数锁获取是无争用的（99%+），`trylock` 只是一个原子 CAS 操作（几纳秒），对无争用场景几乎无性能影响。只有真正争用时才启用完整的计时逻辑。

#### pthread_rwlock_rdlock_hook / pthread_rwlock_wrlock_hook

结构完全相同，只是把 `trylock` 换成了 `tryrdlock` / `trywrlock`：

```cpp
extern "C" int pthread_rwlock_rdlock_hook(pthread_rwlock_t* rwlock) {
    if (!NativeLockTracer::running()) return pthread_rwlock_rdlock(rwlock);
    if (pthread_rwlock_tryrdlock(rwlock) == 0) return 0;

    u64 start_time = TSC::ticks();
    int ret = pthread_rwlock_rdlock(rwlock);
    u64 end_time = TSC::ticks();

    if (ret == 0) NativeLockTracer::recordNativeLock(rwlock, start_time, end_time);
    return ret;
}
```

### GDB 验证 — pthread_mutex_lock_hook 拦截

```
=== pthread_mutex_lock_hook ===                                      ✅
mutex = 0x7ffff7687f60 <tc_mutex>

  #0 pthread_mutex_lock_hook(mutex=0x7ffff7687f60)  ← hook 拦截
  #1 ThreadCritical::ThreadCritical()                ← JVM 内部锁
  #2 ChunkPool::allocate(bytes=1016)                 ← 内存池分配

→ JVM 内部的 pthread_mutex_lock 调用被成功拦截
→ tc_mutex = Thread Critical mutex，JVM 用于保护全局内存池
```

### 2.5 recordNativeLock — 采样记录

```cpp
void NativeLockTracer::recordNativeLock(void* address, u64 start_time, u64 end_time) {
    const u64 duration_ticks = end_time - start_time;
    if (updateCounter(_total_duration, duration_ticks, _interval)) {
        u64 duration_nanos = (u64)(duration_ticks * _ticks_to_nanos);
        NativeLockEvent event;
        event._start_time = start_time;
        event._end_time = end_time;
        event._address = (uintptr_t)address;  // mutex 指针地址

        Profiler::instance()->recordSample(NULL, duration_nanos, NATIVE_LOCK_SAMPLE, &event);
    }
}
```

**NativeLockEvent** 比 LockEvent 简单，没有 class_id（原生锁没有 Java 类信息），只有 mutex 地址和时间：

```
class NativeLockEvent : public Event {
    u64 _start_time;       // 开始等锁时间
    u64 _end_time;         // 获取锁时间
    uintptr_t _address;    // mutex 指针地址（用于区分不同的锁实例）
};
```

### 2.6 MARK_ASYNC_PROFILER — 栈帧过滤

```cpp
void NativeLockTracer::initialize() {
    CodeCache* lib = Profiler::instance()->findLibraryByAddress(
        (void*)NativeLockTracer::initialize);

    lib->mark(
        [](const char* s) -> bool {
            return strcmp(s, "pthread_mutex_lock_hook") == 0
                || strcmp(s, "pthread_rwlock_rdlock_hook") == 0
                || strcmp(s, "pthread_rwlock_wrlock_hook") == 0;
        },
        MARK_ASYNC_PROFILER);
}
```

**为什么要标记？** 栈回溯时，`pthread_mutex_lock_hook` 会出现在调用栈中。但这是 async-profiler 自己的代码，用户不关心它——需要在栈回溯阶段跳过这些帧：

```cpp
// stackWalker.cpp
if (mark == MARK_ASYNC_PROFILER &&
    (event_type == MALLOC_SAMPLE || event_type == NATIVE_LOCK_SAMPLE)) {
    // 跳过 async-profiler 自己的帧，只显示用户代码
}
```

### 2.7 patchLibraries — 增量 patch

```cpp
void NativeLockTracer::patchLibraries() {
    MutexLocker ml(_patch_lock);

    CodeCacheArray* native_libs = Profiler::instance()->nativeLibs();
    int native_lib_count = native_libs->count();

    while (_patched_libs < native_lib_count) {
        CodeCache* cc = (*native_libs)[_patched_libs++];

        // 跳过 async-profiler 自身
        if (cc->contains((const void*)NativeLockTracer::initialize)) continue;

        UnloadProtection handle(cc);
        if (!handle.isValid()) continue;

        cc->patchImport(im_pthread_mutex_lock, (void*)pthread_mutex_lock_hook);
        cc->patchImport(im_pthread_rwlock_rdlock, (void*)pthread_rwlock_rdlock_hook);
        cc->patchImport(im_pthread_rwlock_wrlock, (void*)pthread_rwlock_wrlock_hook);
    }
}
```

**增量 patch 设计**：`_patched_libs` 记录已经 patch 了多少个库，新加载的库（通过 `dlopen_hook` 检测）会自动被 patch——调用 `NativeLockTracer::installHooks()`。

---

## 三、采样策略 — 基于时长的 updateCounter

### 3.1 为什么是时长采样？

| 方案 | 采样标准 | 问题 |
|------|---------|------|
| 每次争用都记录 | 次数 | 高频短争用产生海量数据，淹没真正重要的长争用 |
| 每 N 次记录 | 次数 | 10μs 的争用和 10s 的争用被同等对待 |
| **累积时长超过阈值** | **时长** | **重要的长争用一定被捕获，频繁的短争用被合理抑制** |

### 3.2 updateCounter 的工作方式

```
默认 _interval = 10000 纳秒 (10μs)

争用序列：
  T1: 锁等待 3μs  → counter: 0 + 3 = 3μs   (< 10μs, 不采样)
  T2: 锁等待 5μs  → counter: 3 + 5 = 8μs   (< 10μs, 不采样)
  T3: 锁等待 4μs  → counter: 8 + 4 = 12μs  (≥ 10μs, 采样！→ counter = 12 % 10 = 2μs)
  T4: 锁等待 1ms  → counter: 2μs + 1ms     (≥ 10μs, 采样！→ counter = ...)

→ 1ms 的长争用一定会被采样到
→ 3μs 的短争用需要累积多次才触发一次采样
```

### 3.3 并发安全

`_total_duration` 是 `volatile u64`，多个线程可能同时调用 `updateCounter`：

```cpp
while (true) {
    u64 prev = counter;
    u64 next = prev + value;
    if (next < interval) {
        if (__sync_bool_compare_and_swap(&counter, prev, next)) return false;
    } else {
        if (__sync_bool_compare_and_swap(&counter, prev, next % interval)) return true;
    }
}
```

CAS 自旋确保原子性——失败时重试，不用锁。

---

## 四、完整流程图

### 4.1 LockTracer 流程

```
┌──────────────────────────────────────────────────────────────────────┐
│                       LockTracer 流程                                │
│                                                                      │
│  synchronized 争用路径:                                              │
│  ═══════════════════                                                 │
│    monitorenter 字节码                                               │
│      → ObjectSynchronizer::fast_enter()                              │
│        → ObjectMonitor::enter()                                      │
│          → CAS 失败（争用！）                                         │
│            ├── JVMTI post_monitor_contended_enter                    │
│            │     └── MonitorContendedEnter:                          │
│            │           enter_time = TSC::ticks()                     │
│            │           TLS[enter_time] = enter_time                  │
│            │                                                         │
│            ├── EnterI() → 阻塞等待 → 获取锁                          │
│            │                                                         │
│            └── JVMTI post_monitor_contended_entered                  │
│                  └── MonitorContendedEntered:                        │
│                        duration = TSC::ticks() - enter_time          │
│                        updateCounter(duration) → recordSample        │
│                                                                      │
│  ReentrantLock 争用路径:                                             │
│  ═══════════════════════                                             │
│    ReentrantLock.lock()                                              │
│      → AQS.acquire()                                                │
│        → LockSupport.park(blocker)                                   │
│          → Unsafe.park(false, 0)                                     │
│            → UnsafeParkHook:                                         │
│                ├── getParkBlocker() → "ReentrantLock"?               │
│                │     └── No  → _orig_unsafe_park() → 直接返回        │
│                │     └── Yes ↓                                       │
│                ├── park_start = TSC::ticks()                         │
│                ├── _orig_unsafe_park()    // 真正阻塞                │
│                ├── park_end = TSC::ticks()                           │
│                └── updateCounter(duration) → recordSample            │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 4.2 NativeLockTracer 流程

```
┌──────────────────────────────────────────────────────────────────────┐
│                     NativeLockTracer 流程                             │
│                                                                      │
│  start():                                                            │
│    ├── initialize():                                                 │
│    │     └── mark(hook 函数, MARK_ASYNC_PROFILER)                    │
│    ├── _running = true                                               │
│    └── patchLibraries():                                             │
│          for lib in native_libs:                                     │
│            ├── skip(async-profiler 自身)                              │
│            ├── makeImportsPatchable():                                │
│            │     └── mprotect(GOT 表页, PROT_READ|WRITE)             │
│            └── patchImport():                                        │
│                  GOT[pthread_mutex_lock] = hook                      │
│                  GOT[pthread_rwlock_rdlock] = hook                   │
│                  GOT[pthread_rwlock_wrlock] = hook                   │
│                                                                      │
│  运行时:                                                             │
│    libjvm.so 调用 pthread_mutex_lock(mutex)                         │
│      → GOT → pthread_mutex_lock_hook(mutex)                         │
│           ├── trylock(mutex) → 成功? → return 0 (零开销)             │
│           └── trylock 失败（争用）:                                   │
│                 start = TSC::ticks()                                 │
│                 pthread_mutex_lock(mutex)  // 真正阻塞               │
│                 end = TSC::ticks()                                   │
│                 recordNativeLock(mutex, start, end)                  │
│                   → updateCounter(duration) → recordSample           │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 五、INCBIN — 字节码嵌入技术

### 5.1 问题

async-profiler 需要在运行时向 JVM 注入 Java 帮助类（如 `one.profiler.LockTracer`），但 `.so` 文件不方便携带 `.class` 文件。

### 5.2 解决方案

使用 GCC 内联汇编的 `.incbin` 指令，在编译时将 `.class` 文件的字节码**直接嵌入到 `.so` 的只读数据段**：

```cpp
// incbin.h
#define INCBIN(NAME, FILE) \
    extern "C" const char NAME[];      \
    extern "C" const char NAME##_END[];\
    asm(".section \".rodata\", \"a\"\n" \
        ".globl " #NAME "\n"           \
        #NAME ":\n"                    \
        ".incbin \"" FILE "\"\n"       \
        ".globl " #NAME "_END\n"       \
        #NAME "_END:\n"                \
        ".byte 0x00\n"                 \
        ".previous\n"                  \
    );

// lockTracer.cpp
INCLUDE_HELPER_CLASS(LOCK_TRACER_NAME, LOCK_TRACER_CLASS, "one/profiler/LockTracer")
// 等价于：
//   const char* LOCK_TRACER_NAME = "one/profiler/LockTracer";
//   INCBIN(LOCK_TRACER_CLASS, "src/helper/one/profiler/LockTracer.class")
```

**使用**：

```cpp
jclass cls = env->DefineClass(
    LOCK_TRACER_NAME,                // "one/profiler/LockTracer"
    NULL,                            // classloader = bootstrap
    (const jbyte*)LOCK_TRACER_CLASS, // 字节码数据（嵌入 .so 中）
    INCBIN_SIZEOF(LOCK_TRACER_CLASS) // 字节码长度
);
```

**优势**：不需要临时文件、不需要 ClassLoader、不需要 jar 包——`.class` 字节码直接内嵌在 native 库中。

---

## 六、LockTracer vs NativeLockTracer — 完整对比

| 维度 | LockTracer | NativeLockTracer |
|------|-----------|------------------|
| **追踪目标** | Java `synchronized` + `ReentrantLock` | `pthread_mutex` + `pthread_rwlock` |
| **事件类型** | LOCK_SAMPLE / PARK_SAMPLE | NATIVE_LOCK_SAMPLE |
| **hook 方式** | JVMTI 回调 + JNI RegisterNatives | GOT/PLT 表 patch |
| **争用检测** | JVMTI 事件 / park 前后计时 | trylock + 阻塞计时 |
| **无争用开销** | Monitor: 零 / Park: 函数调用 | trylock (几纳秒 CAS) |
| **锁类型过滤** | 只追踪 Reentrant*/Semaphore | 无过滤（所有 mutex） |
| **采样权重** | 等待时长（纳秒） | 等待时长（纳秒） |
| **默认间隔** | 10000 ns (10μs) | 10000 ns (10μs) |
| **栈获取** | recordSample(NULL) → ASGCT | recordSample(NULL) → ASGCT |
| **帧过滤** | 无（JVMTI 回调不在栈上） | 跳过 hook 函数帧 (MARK_ASYNC_PROFILER) |

---

## 七、面试级知识点

### Q1: async-profiler 追踪 synchronized 锁争用的开销是什么？

**A**: **几乎为零**。JVMTI 的 `MONITOR_CONTENDED_ENTER/ENTERED` 事件只在**争用发生时**才触发（JVM 内部通过 `should_post_monitor_contended_enter()` 标志判断）。如果锁没有争用（CAS 直接成功），完全不触发任何回调。而且回调中用 TSC（`RDTSC` 指令，几纳秒）获取时间，用 TLS 存储（`pthread_setspecific`，几纳秒），开销极小。

### Q2: 为什么 NativeLockTracer 用 trylock 而不是直接在 lock 前后计时？

**A**: 性能关键。如果直接 `start=ticks(); lock(); end=ticks(); record()`，即使无争用也需要两次 `RDTSC`（各约 20ns）。而 trylock 在无争用时几乎与原始 lock 等价（一次 CAS），且成功后直接返回——**99%+ 的无争用场景只多了一次 CAS，没有 RDTSC 开销**。

### Q3: Unsafe.park hook 为什么不追踪 CountDownLatch 和 ThreadPool？

**A**: 因为 `CountDownLatch.await()` 和 `ThreadPoolExecutor` worker 的 `park` 不是**锁争用**——它们是**条件等待**。线程是主动等待某个条件满足，不是因为锁被其他线程持有。将这些混入"锁争用"数据会产生噪音，误导诊断。通过 `isConcurrentLock` 过滤，只保留真正的锁争用：`ReentrantLock`、`ReentrantReadWriteLock`、`Semaphore`。

### Q4: GOT patch 在 RELRO (Read-Only Relocation) 启用时还能工作吗？

**A**: 可以。RELRO 分为 **Partial RELRO**（默认）和 **Full RELRO**。
- Partial RELRO：GOT 表中的延迟绑定条目仍可写，`mprotect` 可以让全部 GOT 可写
- Full RELRO：GOT 在 `ld.so` 解析完后变为只读——但 `mprotect` 仍然可以强制修改权限

`makeImportsPatchable` 中的 `mprotect(PROT_READ | PROT_WRITE)` 可以覆盖 RELRO 保护。唯一的例外是 **SELinux 或 W^X 强制策略**阻止了 `mprotect`。

### Q5: 为什么 stop() 不恢复 Unsafe.park 的原始入口？

**A**: 两个原因：
1. **JDK-8369219**：某些 JDK 版本中，`RegisterNatives` 在并发调用时有 bug，频繁替换可能导致 JVM 崩溃
2. **设计安全**：hook 函数通过 `_enabled` 标志控制是否采样。stop 后 `_enabled = false`，hook 函数会直接转发给原始 `_orig_unsafe_park`，行为与未 hook 时完全一致

---

## 八、总结

### LockTracer 的核心创新

1. **双通道追踪**：JVMTI 回调追踪 `synchronized`，Unsafe.park hook 追踪 `ReentrantLock`，全覆盖 Java 锁
2. **三步 hook 安装**：通过 hook `RegisterNatives` → 触发 `Unsafe.registerNatives()` → 截获 park 地址，绕过 JDK 安全限制
3. **INCBIN 字节码嵌入**：将 Java 帮助类字节码直接编译进 `.so`，无需额外文件
4. **JDK bug workaround**：`LockTracer.java` 提供两层 bootstrap 帧，绕过 JDK-8238460

### NativeLockTracer 的核心创新

1. **GOT/PLT hook**：修改 ELF 的 GOT 表实现函数拦截，不修改代码段
2. **trylock 优化**：无争用场景零 TSC 开销，只有一次额外 CAS
3. **增量 patch**：新加载的库自动被 hook，通过 `dlopen_hook` 触发
4. **MARK_ASYNC_PROFILER**：标记 hook 函数，栈回溯时自动跳过

### GDB 验证关键数据

| 验证项 | 结果 | 含义 |
|--------|------|------|
| JVMTI post_monitor_contended_enter | ✅ 触发 | synchronized 争用检测正常 |
| JVMTI post_monitor_contended_entered | ✅ 触发 | 争用结束检测正常 |
| UnsafeParkHook → Unsafe_Park | ✅ 拦截 | ReentrantLock park hook 工作正常 |
| pthread_mutex_lock_hook | ✅ 拦截 | GOT patch 工作正常 |
| hook addr (0x7ffff7b55191) ≠ real addr (0x7ffff78786f0) | ✅ 不同 | GOT 表确实被修改 |
| DEFAULT_LOCK_INTERVAL | 10000 ns (10μs) | 默认采样间隔 |

---

*创建日期: 2026-02-09*
*GDB 验证环境: OpenJDK 11 slowdebug + async-profiler v4.0*
*标准条件: -Xms8g -Xmx8g -XX:+UseG1GC -Xint --event lock/nativelock*
*测试程序: LockTestDemo.java (4 线程 synchronized + ReentrantLock 争用)*
