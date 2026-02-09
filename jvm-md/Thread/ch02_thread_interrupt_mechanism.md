# 第二章：线程中断机制完整分析

> 基于 OpenJDK 11 源码 | 标准环境: `-Xms8g -Xmx8g -XX:+UseG1GC` | Region 4MB

---

## 1. 为什么要深入理解中断机制

### 1.1 中断是 Java 线程协作停止的唯一标准方式

Java 没有提供强制终止线程的安全方式（`Thread.stop()` 已废弃），中断机制是唯一推荐的**协作式停止协议**：

```
线程 A                              线程 B
  │                                   │
  │── thread.interrupt() ──────────→  │ (设置中断标志)
  │                                   │
  │                                   ├─ 正在 sleep? → 抛 InterruptedException
  │                                   ├─ 正在 wait?  → 抛 InterruptedException
  │                                   ├─ 正在 park?  → 立即返回
  │                                   ├─ 正在 NIO?   → 关闭 Channel，抛 ClosedByInterruptException
  │                                   └─ 正在运行?   → 啥也不发生，需要自己检查
```

### 1.2 面试极高频

- `interrupted()` vs `isInterrupted()` 的区别？
- `sleep` 被中断和 `wait` 被中断有什么区别？
- 如果同时 `notify` 和 `interrupt`，谁优先？
- `LockSupport.park()` 被中断后不抛异常，为什么？
- NIO 的中断是怎么实现"关闭 Channel"的？

### 1.3 本章与 ch01 的关联

ch01 分析了线程如何创建和启动，本章分析线程如何**优雅停止**。start/interrupt/join 构成线程生命周期的"三大件"。

---

## 2. 完整调用链总览

### 2.1 设置中断

```
Java: Thread.interrupt()
  │
  ├─ if (blocker != null)  →  interrupt0() + b.interrupt(this)  // NIO 路径
  └─ else                  →  interrupt0()                       // 常规路径
      │
      JNI: JVM_Interrupt (jvm.cpp:3203)
        │
        Thread::interrupt(receiver)  (thread.cpp:928)
          │
          os::interrupt(thread)  (os_posix.cpp:748)
            │
            ├── osthread->set_interrupted(true)     // ① 设标志
            ├── OrderAccess::fence()                 // ② 内存屏障
            ├── _SleepEvent->unpark()                // ③ 唤醒 sleep
            ├── parker()->unpark()                   // ④ 唤醒 LockSupport.park
            └── _ParkEvent->unpark()                 // ⑤ 唤醒 Object.wait
```

### 2.2 查询中断

```
Java: Thread.interrupted()         →  isInterrupted(true)   // 清除标志
Java: thread.isInterrupted()       →  isInterrupted(false)  // 不清除标志
  │
  JNI: JVM_IsInterrupted (jvm.cpp:3216)
    │
    Thread::is_interrupted(receiver, clear)  (thread.cpp:933)
      │
      os::is_interrupted(thread, clear)  (os_posix.cpp:771)
        │
        └── osthread->interrupted()  →  返回 _interrupted 字段
            if (clear && interrupted) → set_interrupted(false)
```

### 2.3 一张图看清全貌

```
                         ┌──────────────────────────────────────────┐
                         │        os::interrupt(thread)              │
                         │                                          │
                         │  ① set_interrupted(true)                 │
                         │  ② OrderAccess::fence()                  │
                         │                                          │
                         │  ③ _SleepEvent->unpark() ─────┐         │
                         │  ④ parker()->unpark()    ─────┤         │
                         │  ⑤ _ParkEvent->unpark()  ─────┤         │
                         └──────────────────────────────┼─────────┘
                                                         │
                    ┌────────────────────────────────────┘
                    ▼
  ┌─────────────┬─────────────────┬──────────────────────┐
  │ Thread.sleep│ LockSupport.park│ Object.wait          │
  │             │                 │                       │
  │ _SleepEvent │ Parker._counter │ _ParkEvent            │
  │ os::sleep() │ Parker::park()  │ ObjectMonitor::wait() │
  │             │                 │                       │
  │ 循环中检查   │ 入口检查        │ 三次检查              │
  │ is_interrupted│ is_interrupted│ is_interrupted        │
  │ (clear=true)│ (clear=false)  │ (时机不同)            │
  │             │                 │                       │
  │ → throw IE  │ → 直接返回     │ → throw IE            │
  │   (清除标志) │   (保留标志)    │   (仅非notify时)     │
  └─────────────┴─────────────────┴──────────────────────┘
```

---

## 3. Java 层：三个方法的精确语义

### 3.1 Thread.interrupt() — 设置中断

```java
// Thread.java:979-996
public void interrupt() {
    if (this != Thread.currentThread()) {
        checkAccess();                          // 安全检查

        // NIO 路径：线程可能阻塞在 I/O 操作
        synchronized (blockerLock) {
            Interruptible b = blocker;
            if (b != null) {
                interrupt0();                   // 先设中断标志
                b.interrupt(this);              // 再关闭 Channel
                return;
            }
        }
    }

    interrupt0();                               // 常规路径
}
```

**关键点**：
- 中断自己不需要 `checkAccess()`
- NIO 路径**先设标志再关 Channel**（顺序很重要）
- `interrupt0()` 是 native 方法，映射到 `JVM_Interrupt`

### 3.2 Thread.interrupted() — 静态方法，清除标志

```java
// Thread.java:1015-1017
public static boolean interrupted() {
    return currentThread().isInterrupted(true);   // clear = true
}
```

**注意**：`interrupted()` 是**静态方法**，只能检查**当前线程**的中断状态，且**清除标志**。

### 3.3 Thread.isInterrupted() — 实例方法，不清除标志

```java
// Thread.java:1032-1034
public boolean isInterrupted() {
    return isInterrupted(false);                  // clear = false
}
```

### 3.4 底层 native 方法

```java
// Thread.java:1041-1042
@HotSpotIntrinsicCandidate
private native boolean isInterrupted(boolean ClearInterrupted);
```

`@HotSpotIntrinsicCandidate` 注解意味着 JIT 可以将其替换为**内联的机器码**，直接读取 `_interrupted` 字段，跳过 JNI 调用开销。

### 3.5 三个方法对比

| 方法 | 类型 | 检查谁 | 清除标志 | 线程死亡时 |
|------|------|--------|---------|-----------|
| `interrupt()` | 实例 | 目标线程 | — | 静默忽略 |
| `interrupted()` | **静态** | **当前线程** | **是** | 返回 false |
| `isInterrupted()` | 实例 | 目标线程 | **否** | 返回 false |

**常见陷阱**：

```java
// 错误用法：检查别人的中断状态但意外清除了自己的
if (Thread.interrupted()) { ... }  // 这检查的是 currentThread

// 正确用法：检查目标线程
if (targetThread.isInterrupted()) { ... }  // 检查目标，不清除
```

---

## 4. JVM 层：JVM_Interrupt 与 JVM_IsInterrupted

### 4.1 JVM_Interrupt — 设置中断

```cpp
// jvm.cpp:3203-3213
JVM_ENTRY(void, JVM_Interrupt(JNIEnv * env, jobject jthread))
    JVMWrapper("JVM_Interrupt");

    ThreadsListHandle tlh(thread);                        // 安全遍历
    JavaThread *receiver = NULL;
    bool is_alive = tlh.cv_internal_thread_to_JavaThread(
        jthread, &receiver, NULL);                        // oop → JavaThread*
    if (is_alive) {
        Thread::interrupt(receiver);                      // 只中断活着的线程
    }
JVM_END
```

**关键设计**：
- 使用 `ThreadsListHandle`（Hazard Pointer SMR）安全地获取 JavaThread 指针
- 线程死亡时（`!is_alive`）中断操作**静默忽略**，不报错
- `cv_internal_thread_to_JavaThread` 从 Java 的 `Thread` 对象找到 C++ 的 `JavaThread*`

### 4.2 JVM_IsInterrupted — 查询中断

```cpp
// jvm.cpp:3216-3228
JVM_QUICK_ENTRY(jboolean, JVM_IsInterrupted(JNIEnv * env, jobject jthread,
                                            jboolean clear_interrupted))
    JVMWrapper("JVM_IsInterrupted");

    ThreadsListHandle tlh(thread);
    JavaThread *receiver = NULL;
    bool is_alive = tlh.cv_internal_thread_to_JavaThread(
        jthread, &receiver, NULL);
    if (is_alive) {
        return (jboolean) Thread::is_interrupted(receiver,
                                                  clear_interrupted != 0);
    } else {
        return JNI_FALSE;                                 // 已死线程 = 未中断
    }
JVM_END
```

**注意**：使用 `JVM_QUICK_ENTRY` 而非 `JVM_ENTRY` — 这是快速路径，省略了 `HandleMark` 等开销，因为该方法不分配任何 oop handle。

### 4.3 Thread::interrupt 和 Thread::is_interrupted

```cpp
// thread.cpp:928-931
void Thread::interrupt(Thread * thread) {
    debug_only(check_for_dangling_thread_pointer(thread);)
    os::interrupt(thread);
}

// thread.cpp:933-942
bool Thread::is_interrupted(Thread * thread, bool clear_interrupted) {
    debug_only(check_for_dangling_thread_pointer(thread);)
    return os::is_interrupted(thread, clear_interrupted);
}
```

纯粹的委托层，所有真正的逻辑在 `os::interrupt` / `os::is_interrupted`。

---

## 5. 核心实现：os::interrupt() — 五步唤醒

这是整个中断机制最核心的 22 行代码：

```cpp
// os_posix.cpp:748-769
void os::interrupt(Thread* thread) {
    debug_only(Thread::check_for_dangling_thread_pointer(thread);)

    OSThread* osthread = thread->osthread();

    // ─── 第一部分：设标志 + 唤醒 sleep ───
    if (!osthread->interrupted()) {           // ① 只在未中断时设标志
        osthread->set_interrupted(true);      //    设置 _interrupted = 1
        OrderAccess::fence();                 // ② 内存屏障：确保标志对其他线程可见
        ParkEvent * const slp = thread->_SleepEvent;
        if (slp != NULL) slp->unpark();       // ③ 唤醒 Thread.sleep
    }

    // ─── 第二部分：唤醒 park (JSR166 要求无条件) ───
    if (thread->is_Java_thread())
        ((JavaThread*)thread)->parker()->unpark();  // ④ 唤醒 LockSupport.park

    // ─── 第三部分：唤醒 wait ───
    ParkEvent * ev = thread->_ParkEvent;
    if (ev != NULL) ev->unpark();             // ⑤ 唤醒 Object.wait
}
```

### 5.1 五步操作逐一分析

| 步骤 | 操作 | 条件 | 作用 |
|------|------|------|------|
| ① | `set_interrupted(true)` | `!interrupted()` | 设中断标志（只做一次） |
| ② | `OrderAccess::fence()` | 同上 | 保证 ① 的写对后续 unpark 的目标线程可见 |
| ③ | `_SleepEvent->unpark()` | 同上 | 唤醒 `Thread.sleep()` 中的线程 |
| ④ | `parker()->unpark()` | **无条件**（JSR166） | 唤醒 `LockSupport.park()` 中的线程 |
| ⑤ | `_ParkEvent->unpark()` | **无条件** | 唤醒 `Object.wait()` 中的线程 |

### 5.2 为什么 ④ 和 ⑤ 无条件执行？

**④ parker()->unpark() 无条件**：JSR166 规范要求。`LockSupport.park()` 的许可证（permit）模型规定 unpark 必须总是设置 permit。如果已经中断过（标志已经是 true），线程可能在中断后又调用了 park，需要再次唤醒。

**⑤ _ParkEvent->unpark() 无条件**：同理，`Object.wait()` 的线程可能在中断后重新进入 wait。

**③ _SleepEvent->unpark() 有条件**：`os::sleep()` 在进入循环前会调用 `_SleepEvent->reset()` 清空事件，且每次循环都检查 `is_interrupted(true)`（清除标志），所以重复 unpark 无意义。

### 5.3 内存屏障的必要性

```
线程 A（中断者）                        线程 B（被中断者）
    │                                      │
    │ set_interrupted(true)  ──STORE──     │
    │ OrderAccess::fence()   ──MFENCE──    │
    │ slp->unpark()         ──STORE──      │ is_interrupted() ──LOAD──
```

如果没有 fence，CPU 可能重排序，导致 B 先看到 `_SleepEvent` 的唤醒信号，但读 `_interrupted` 时还是 false — 导致错过中断。

---

## 6. 中断标志的存储：OSThread._interrupted

### 6.1 字段定义

```cpp
// osThread.hpp:56-93
class OSThread: public CHeapObj<mtThread> {
 private:
    OSThreadStartFunc _start_proc;
    void* _start_parm;
    volatile ThreadState _state;
    volatile jint _interrupted;         // ← 中断标志

    // Note: _interrupted must be jint, so that Java intrinsics can access it.
    // The value stored there must be either 0 or 1. It must be possible
    // for Java to emulate Thread.currentThread().isInterrupted() by performing
    // the double indirection Thread::current()->_osthread->_interrupted.

 public:
    volatile bool interrupted() const     { return _interrupted != 0; }
    void set_interrupted(bool z)          { _interrupted = z ? 1 : 0; }

    // For java intrinsics:
    static ByteSize interrupted_offset()  { return byte_offset_of(OSThread, _interrupted); }
};
```

### 6.2 设计要点

**为什么是 `volatile jint` 而不是 `volatile bool`？**

1. **JIT 内联访问**：`@HotSpotIntrinsicCandidate` 标记的 `isInterrupted()` 会被 JIT 编译为直接内存读取。JIT 需要已知大小和对齐的类型，`jint`（4 字节）比 `bool`（实现定义大小）更安全
2. **双重间接寻址**：JIT 生成的机器码做的是 `Thread::current()->_osthread->_interrupted`，也就是先通过 TLS 拿到当前线程，再取 `_osthread` 指针，再偏移到 `_interrupted`
3. **值只有 0 或 1**：虽然是 jint，但 `set_interrupted(bool z)` 保证只存 0 或 1

### 6.3 JIT 内联的效果

```x86asm
; 未优化（JNI 调用）：
; call JVM_IsInterrupted
; ... 几十条指令 ...

; JIT 内联后（约 3 条指令）：
mov    rax, QWORD PTR [r15 + osthread_offset]     ; r15 = JavaThread*
mov    eax, DWORD PTR [rax + interrupted_offset]   ; 直接读 _interrupted
test   eax, eax
```

性能差距：JNI 调用 ~100ns，JIT 内联 ~1ns。对于 `while (!Thread.currentThread().isInterrupted())` 这种热循环，差 100 倍。

### 6.4 为什么没有锁？

```cpp
// os_posix.cpp:778-789 注释翻译：
// 注意：因为 interrupt 和 is_interrupted 操作之间没有"锁"，
// 有可能中断标志为 false 但底层事件已经处于 signaled 状态。
// 这是有意为之的。效果是 Object.wait() 和 LockSupport.park()
// 会出现虚假唤醒（spurious wakeup），这是允许的且无害的，
// 而且这种可能性极罕见，不值得为此增加另一个锁的复杂性。
// 对于 sleep 事件，在 os::sleep 入口处有显式 reset，
// 所以不会有提前返回。
```

这是一个经典的**在正确性和性能之间做权衡**的例子：放弃严格的原子性，换取零锁开销。

---

## 7. 三种事件对象的架构

每个线程在创建时分配 4 个 ParkEvent（实际使用 3 个）：

```cpp
// thread.cpp:313-316
_ParkEvent   = ParkEvent::Allocate(this);    // synchronized / Object.wait
_SleepEvent  = ParkEvent::Allocate(this);    // Thread.sleep
_MutexEvent  = ParkEvent::Allocate(this);    // native 内部 Mutex/Monitor
_MuxEvent    = ParkEvent::Allocate(this);    // 低级 muxAcquire-muxRelease
```

另外还有一个 `Parker`（注意不是 ParkEvent），用于 JSR166 的 `LockSupport.park()`：

```
┌──────────────────────────────────────────────────────────┐
│                    JavaThread                             │
├──────────────────────────────────────────────────────────┤
│  _ParkEvent  ──→ PlatformEvent { _event, _nParked,      │
│                                   pthread_mutex,          │
│                                   pthread_cond }          │
│                                                          │
│  _SleepEvent ──→ PlatformEvent { ... }                   │
│                                                          │
│  _MutexEvent ──→ PlatformEvent { ... }                   │
│                                                          │
│  _MuxEvent   ──→ PlatformEvent { ... }                   │
│                                                          │
│  _parker     ──→ Parker { _counter,                      │
│                           PlatformParker {                │
│                             _cur_index,                   │
│                             pthread_mutex,                │
│                             pthread_cond[2] }  }          │
├──────────────────────────────────────────────────────────┤
│  _osthread   ──→ OSThread { _interrupted }               │
└──────────────────────────────────────────────────────────┘
```

### 7.1 PlatformEvent vs Parker — 两套并行机制

| 特性 | PlatformEvent | Parker |
|------|---------------|--------|
| 用途 | synchronized, sleep, native mutex | LockSupport.park/unpark |
| 状态模型 | `_event`: -1 (parked) / 0 (neutral) / 1 (signaled) | `_counter`: 0 (no permit) / 1 (has permit) |
| 条件变量 | 1 个 `pthread_cond` | **2 个** `pthread_cond`（相对/绝对时间各一个） |
| park 语义 | 减 1（CAS 循环） | 消费 permit（xchg） |
| unpark 语义 | 设 1 + signal（仅当从 -1 唤醒） | 设 _counter=1 + signal（仅当线程确实 parked） |
| 回收策略 | 类型稳定（immortal），线程死后回收到 FreeList | 同样 immortal，回收到 FreeList |

### 7.2 为什么 Parker 有两个条件变量？

```cpp
// os_posix.hpp:205-220
class PlatformParker : public CHeapObj<mtSynchronizer> {
 protected:
    enum { REL_INDEX = 0, ABS_INDEX = 1 };
    int _cur_index;              // -1 = 未 parked, 0 = 相对时间, 1 = 绝对时间
    pthread_mutex_t _mutex[1];
    pthread_cond_t  _cond[2];    // cond[0] 用 CLOCK_MONOTONIC，cond[1] 用 CLOCK_REALTIME
};
```

原因：`pthread_cond_timedwait` 对相对超时和绝对超时需要不同的时钟类型：
- **相对时间**（`LockSupport.parkNanos`）：用 `CLOCK_MONOTONIC`，不受系统时间调整影响
- **绝对时间**（`LockSupport.parkUntil`）：用 `CLOCK_REALTIME`，与 Java 的 `System.currentTimeMillis()` 一致

### 7.3 为什么不合并 PlatformEvent 和 Parker？

源码中的注释已经承认了冗余：

```cpp
// park.hpp:42-44
// In the future we'll want to think about eliminating Parker and using
// ParkEvent instead.  There's considerable duplication between the two
// services.
```

没有合并的原因：Parker 使用了**快速路径**（`Atomic::xchg` 消费 permit），这打破了 PlatformEvent 的封装。历史遗留 + 两个系统的语义细微差异（permit 模型 vs 事件计数模型），合并工作量大收益小。

---

## 8. Thread.sleep 的中断路径

### 8.1 JVM_Sleep — 入口

```cpp
// jvm.cpp:3123-3166
JVM_ENTRY(void, JVM_Sleep(JNIEnv * env, jclass threadClass, jlong millis))
    if (millis < 0) {
        THROW_MSG(vmSymbols::java_lang_IllegalArgumentException(),
                  "timeout value is negative");
    }

    // ─── 入口中断检查 ───
    if (Thread::is_interrupted(THREAD, true) && !HAS_PENDING_EXCEPTION) {
        THROW_MSG(vmSymbols::java_lang_InterruptedException(),
                  "sleep interrupted");                     // 还没 sleep 就已经中断了
    }

    JavaThreadSleepState jtss(thread);                      // 设置 SLEEPING 状态

    if (millis == 0) {
        os::naked_yield();                                  // sleep(0) = yield
    } else {
        ThreadState old_state = thread->osthread()->get_state();
        thread->osthread()->set_state(SLEEPING);
        if (os::sleep(thread, millis, true) == OS_INTRPT) { // ← 核心
            if (!HAS_PENDING_EXCEPTION) {
                THROW_MSG(vmSymbols::java_lang_InterruptedException(),
                          "sleep interrupted");             // sleep 过程中被中断
            }
        }
        thread->osthread()->set_state(old_state);
    }
JVM_END
```

**两个抛 InterruptedException 的时机**：
1. **入口检查**（第 3130 行）：还没进入 sleep 就已经被中断 → `is_interrupted(true)` 清除标志 → 抛异常
2. **sleep 返回检查**（第 3146-3157 行）：`os::sleep` 返回 `OS_INTRPT` → 抛异常

### 8.2 os::sleep — 核心循环

```cpp
// os_posix.cpp:657-703
int os::sleep(Thread* thread, jlong millis, bool interruptible) {
    ParkEvent * const slp = thread->_SleepEvent;
    slp->reset();                   // ← 重置事件状态为 0
    OrderAccess::fence();           // ← 确保 reset 对其他线程可见

    if (interruptible) {
        jlong prevtime = javaTimeNanos();

        for (;;) {
            // ─── 每次循环都检查中断 ───
            if (os::is_interrupted(thread, true)) {      // clear = true
                return OS_INTRPT;                        // 被中断了
            }

            // ─── 计算剩余时间 ───
            jlong newtime = javaTimeNanos();
            millis -= (newtime - prevtime) / NANOSECS_PER_MILLISEC;

            if (millis <= 0) {
                return OS_OK;                            // 时间到了
            }

            prevtime = newtime;

            {
                JavaThread *jt = (JavaThread *) thread;
                ThreadBlockInVM tbivm(jt);               // 线程状态 → _thread_blocked
                OSThreadWaitState osts(jt->osthread(),
                                       false);           // 不是 Object.wait

                jt->set_suspend_equivalent();

                slp->park(millis);                       // ← 实际阻塞点

                jt->check_and_wait_while_suspended();
            }
        }
    }
    // ... non-interruptible 路径省略
}
```

### 8.3 sleep 中断的完整时序

```
                  线程 B (sleeping)                    线程 A (中断者)
                      │                                     │
 JVM_Sleep 入口检查 ──┤                                     │
 is_interrupted(true) │                                     │
   = false, 继续      │                                     │
                      │                                     │
 _SleepEvent.reset()  │                                     │
 OrderAccess::fence() │                                     │
                      │                                     │
 os::sleep() 进入循环 │                                     │
 is_interrupted(true) │                                     │
   = false            │                                     │
                      │                                     │
 slp->park(millis)    │ ←── 阻塞在 pthread_cond_timedwait   │
      .               │                                     │
      .               │                   os::interrupt(B) ─┤
      .               │                   set_interrupted(true)
      .               │                   fence()
      .               │                   _SleepEvent->unpark() ──→ signal
      .               │                                     │
 park() 返回 ─────────┤                                     │
                      │                                     │
 下次循环:            │                                     │
 is_interrupted(true) │                                     │
   = true             │                                     │
 set_interrupted(false)│  ← 清除标志                        │
 return OS_INTRPT     │                                     │
                      │                                     │
 JVM_Sleep:           │                                     │
 throw InterruptedException                                 │
```

### 8.4 关键细节

1. **sleep 被中断后清除标志**：`is_interrupted(thread, true)` — clear=true。这意味着 catch 到 `InterruptedException` 后，中断标志已经是 false 了
2. **sleep(0) = yield**：不走 `os::sleep`，直接 `os::naked_yield()`
3. **_SleepEvent.reset()**：在 sleep 入口重置事件状态。这就是为什么 `os::interrupt` 中 `_SleepEvent->unpark()` 在 `if (!interrupted())` 条件内 — 因为 sleep 会 reset
4. **虚假唤醒安全**：`park()` 可能因虚假唤醒返回，但外层循环会重新检查时间和中断标志

---

## 9. LockSupport.park 的中断路径

### 9.1 Java 层

```java
// LockSupport.java:191-196 (简化)
public static void park(Object blocker) {
    Thread t = Thread.currentThread();
    setBlocker(t, blocker);                      // 设置 parkBlocker（诊断用）
    U.park(false, 0L);                           // Unsafe.park
    setBlocker(t, null);                         // 清除 parkBlocker
}

// LockSupport.java:322-324
public static void park() {
    U.park(false, 0L);
}

// LockSupport.java:158-161
public static void unpark(Thread thread) {
    if (thread != null) U.unpark(thread);
}
```

### 9.2 Unsafe_Park — JVM 入口

```cpp
// unsafe.cpp:939-958
UNSAFE_ENTRY(void, Unsafe_Park(JNIEnv *env, jobject unsafe,
                                jboolean isAbsolute, jlong time)) {
    JavaThreadParkedState jtps(thread, time != 0);
    thread->parker()->park(isAbsolute != 0, time);     // ← 核心
} UNSAFE_END
```

### 9.3 Parker::park — permit 消费模型

```cpp
// os_posix.cpp:2158-2241
void Parker::park(bool isAbsolute, jlong time) {

    // ─── 快速路径：已有 permit ───
    if (Atomic::xchg(0, &_counter) > 0) return;        // 消费 permit 后立即返回

    Thread* thread = Thread::current();
    JavaThread *jt = (JavaThread *)thread;

    // ─── 中断检查（不清除标志！）───
    if (Thread::is_interrupted(thread, false)) {        // clear = false
        return;                                         // 已中断，直接返回
    }

    // ─── 超时参数处理 ───
    struct timespec absTime;
    if (time < 0 || (isAbsolute && time == 0)) return;
    if (time > 0) to_abstime(&absTime, time, isAbsolute);

    // ─── 进入 safepoint 安全区域 ───
    ThreadBlockInVM tbivm(jt);

    // ─── 再次检查中断 + 尝试获取锁 ───
    if (Thread::is_interrupted(thread, false) ||
        pthread_mutex_trylock(_mutex) != 0) {           // trylock 失败 = 有人 unpark
        return;
    }

    // ─── 持锁后再检查 permit ───
    if (_counter > 0) {
        _counter = 0;
        status = pthread_mutex_unlock(_mutex);
        OrderAccess::fence();
        return;
    }

    // ─── 真正的阻塞 ───
    OSThreadWaitState osts(thread->osthread(), false);
    jt->set_suspend_equivalent();

    if (time == 0) {
        _cur_index = REL_INDEX;                         // 选择条件变量
        status = pthread_cond_wait(&_cond[_cur_index], _mutex);
    } else {
        _cur_index = isAbsolute ? ABS_INDEX : REL_INDEX;
        status = pthread_cond_timedwait(&_cond[_cur_index], _mutex, &absTime);
    }
    _cur_index = -1;                                    // 标记：不再 parked

    _counter = 0;                                       // 消费 permit
    status = pthread_mutex_unlock(_mutex);
    OrderAccess::fence();

    if (jt->handle_special_suspend_equivalent_condition()) {
        jt->java_suspend_self();
    }
}
```

### 9.4 Parker::unpark — permit 发放

```cpp
// os_posix.cpp:2243-2266
void Parker::unpark() {
    int status = pthread_mutex_lock(_mutex);
    const int s = _counter;
    _counter = 1;                                       // 发放 permit
    int index = _cur_index;                             // 捕获当前阻塞的 cond index
    status = pthread_mutex_unlock(_mutex);

    // 在释放锁之后才 signal — 避免 futile wakeup
    if (s < 1 && index != -1) {                         // 线程确实在 parked
        status = pthread_cond_signal(&_cond[index]);
    }
}
```

### 9.5 park 中断的关键特性

**park 被中断后不抛异常，不清除标志**：

```
os::interrupt()           Parker::park()
    │                         │
    │ set_interrupted(true)   │
    │ parker()->unpark()      │
    │   _counter = 1          │
    │   signal()              │
    │                         │ ← pthread_cond_wait 返回
    │                         │ _counter = 0  (消费 permit)
    │                         │ return        (正常返回，无异常)
    │                         │
    │                         │ 此时 _interrupted 仍然是 true
```

**使用者必须自己检查中断**：

```java
// 正确的 park 使用模式（以 ReentrantLock 为例）
while (!canAcquire()) {
    LockSupport.park(this);
    if (Thread.interrupted()) {      // ← 必须手动检查
        throw new InterruptedException();
    }
}
```

### 9.6 park 的四道防线

Parker::park 有 4 个提前返回点，层层递进：

| 防线 | 代码位置 | 检查内容 | 目的 |
|------|---------|---------|------|
| 1 | `Atomic::xchg(0, &_counter) > 0` | permit 已就绪 | 零锁开销快速路径 |
| 2 | `is_interrupted(false)` | 中断标志（锁外） | 避免不必要的加锁 |
| 3 | `is_interrupted(false) \|\| trylock fail` | 中断+锁竞争（进入 safepoint 后） | 检测 unpark 竞争 |
| 4 | `_counter > 0` | permit（持锁后） | 锁保护下的最终确认 |

只有全部 4 道防线都没命中，才会真正 `pthread_cond_wait` 阻塞。

---

## 10. Object.wait 的中断路径 — 三次中断检查

Object.wait 是最复杂的场景，有**三个不同时机**的中断检查，且涉及与 notify 的优先级问题。

### 10.1 wait 的完整流程

```
synchronized (obj) {           // 已持有 ObjectMonitor
    obj.wait(millis);          // → ObjectMonitor::wait()
}

ObjectMonitor::wait() 内部流程：

  ┌─── 第 1 次中断检查 ───────────────────────────────────────┐
  │ if (is_interrupted(Self, true))                            │
  │     throw InterruptedException  → 不进 WaitSet，不释放锁  │
  └────────────────────────────────────────────────────────────┘
         │ (没中断)
         ▼
  创建 ObjectWaiter node
  _ParkEvent->reset()
  fence()
  SpinAcquire(&_WaitSetLock)
  AddWaiter(&node)              ← 加入 WaitSet
  SpinRelease(&_WaitSetLock)
  exit(monitor)                 ← 释放锁
         │
         ▼
  ┌─── 第 2 次中断检查 ───────────────────────────────────────┐
  │ ThreadBlockInVM 转换后:                                    │
  │ if (is_interrupted(THREAD, false) || HAS_PENDING_EXCEPTION)│
  │     // Intentionally empty — 跳过 park，不抛异常          │
  │ else if (node._notified == 0)                              │
  │     _ParkEvent->park(millis)   ← 真正阻塞                 │
  └────────────────────────────────────────────────────────────┘
         │ (park 返回，可能被 interrupt/notify/timeout 唤醒)
         ▼
  如果 node.TState == TS_WAIT:
      从 WaitSet 中移除 node     ← 只有中断/超时才需要自己移除
                                    （notify 已经移走了）
  WasNotified = node._notified
  重新竞争锁 (enter 或 ReenterI)
         │
         ▼
  ┌─── 第 3 次中断检查 ───────────────────────────────────────┐
  │ if (!WasNotified) {                                        │
  │     // 不是被 notify 唤醒的                                │
  │     if (is_interrupted(Self, true) && !HAS_PENDING_EXCEPTION)│
  │         throw InterruptedException                         │
  │ }                                                          │
  │ // 如果 WasNotified == 1 → 即使被中断也不抛异常           │
  │ // → notify 优先于 interrupt                               │
  └────────────────────────────────────────────────────────────┘
```

### 10.2 三次检查的源码

**第 1 次：进入 WaitSet 之前**

```cpp
// objectMonitor.cpp:1428-1450
if (interruptible && Thread::is_interrupted(Self, true) && !HAS_PENDING_EXCEPTION) {
    // ... JVMTI 事件处理 ...
    THROW(vmSymbols::java_lang_InterruptedException());     // 直接抛，不进 WaitSet
    return;
}
```

- `clear = true`：清除中断标志
- **不释放锁**：异常直接抛出，monitor 仍由当前线程持有
- **最高效**：避免了 WaitSet 入队 / 锁释放 / 重新竞争锁的全部开销

**第 2 次：park 之前**

```cpp
// objectMonitor.cpp:1503-1511
if (interruptible && (Thread::is_interrupted(THREAD, false) || HAS_PENDING_EXCEPTION)) {
    // Intentionally empty                                  // 不阻塞，直接 fall through
} else if (node._notified == 0) {
    if (millis <= 0) {
        Self->_ParkEvent->park();                           // 无限等待
    } else {
        ret = Self->_ParkEvent->park(millis);               // 限时等待
    }
}
```

- `clear = false`：**不清除标志**！只是"窥探"一下
- 如果已中断 → 跳过 park → 直接进入后续的锁重新竞争
- 为什么不在这里就抛异常？因为**必须先重新获得锁**才能抛

**第 3 次：重新获得锁之后**

```cpp
// objectMonitor.cpp:1630-1637
if (!WasNotified) {
    if (interruptible && Thread::is_interrupted(Self, true) && !HAS_PENDING_EXCEPTION) {
        THROW(vmSymbols::java_lang_InterruptedException());
    }
}
```

- `clear = true`：清除中断标志
- **只有非 notify 唤醒时才检查**：`!WasNotified` 是关键条件
- `WasNotified` 来自 `node._notified`，由 `INotify` 设置

### 10.3 notify 优先于 interrupt — 核心设计

```cpp
// objectMonitor.cpp:1639-1640 注释
// NOTE: Spurious wake up will be consider as timeout.
// Monitor notify has precedence over thread interrupt.
```

**场景**：线程 B 在 wait，线程 A 调 notify，线程 C 同时调 interrupt

```
时间线:

线程 A (notify)              线程 C (interrupt)           线程 B (waiting)
    │                             │                            │
    │ INotify()                   │                            │ park() 中
    │   node._notified = 1        │                            │
    │   move to EntryList         │ os::interrupt(B)           │
    │   ev->unpark()              │   set_interrupted(true)    │
    │                             │   _ParkEvent->unpark()     │
    │                             │                            │ park() 返回
    │                             │                            │
    │                             │                            │ WasNotified = node._notified = 1
    │                             │                            │ 重新竞争锁
    │                             │                            │ if (!WasNotified) ← false
    │                             │                            │ // 不抛异常！
    │                             │                            │ // 正常返回 wait()
    │                             │                            │ // 中断标志仍然是 true
```

**结果**：
- `wait()` 正常返回，不抛 `InterruptedException`
- 中断标志**保留** — 调用者可以后续检查
- 这是 Java 规范要求的行为

### 10.4 ObjectWaiter 节点结构

```cpp
// objectMonitor.hpp:42-60
class ObjectWaiter : public StackObj {
 public:
    enum TStates { TS_UNDEF, TS_READY, TS_RUN, TS_WAIT, TS_ENTER, TS_CXQ };

    ObjectWaiter * volatile _next;
    ObjectWaiter * volatile _prev;
    Thread*       _thread;
    jlong         _notifier_tid;    // 谁 notify 了我（JFR 用）
    ParkEvent *   _event;           // = _thread->_ParkEvent
    volatile int  _notified;        // 0 = 未 notify, 1 = 已 notify
    volatile TStates TState;        // 状态迁移
};
```

**状态迁移**：

```
                 AddWaiter()
  创建 ──────→  TS_WAIT  ──────→  TS_ENTER (EntryList)
                   │                   │
                   │              或 TS_CXQ (cxq)
                   │                   │
                   └───────────────────┘
                          │
                   (超时/中断时)
                          ▼
                       TS_RUN
```

### 10.5 INotify — notify 的内部实现

```cpp
// objectMonitor.cpp:1649-1752
void ObjectMonitor::INotify(Thread * Self) {
    const int policy = Knob_MoveNotifyee;        // 默认 = 2

    Thread::SpinAcquire(&_WaitSetLock, "WaitSet - notify");
    ObjectWaiter * iterator = DequeueWaiter();   // 从 WaitSet 头部取出
    if (iterator != NULL) {
        iterator->_notified = 1;                 // ← 标记为已 notify
        iterator->_notifier_tid = JFR_THREAD_ID(Self);

        if (policy == 0)      // prepend to EntryList
            ...
        else if (policy == 1) // append to EntryList
            ...
        else if (policy == 2) // prepend to cxq ← 默认策略
            ...
        else if (policy == 3) // append to cxq
            ...
        else /* policy == 4 */
            ev->unpark();     // 直接唤醒，不入队
    }
    Thread::SpinRelease(&_WaitSetLock);
}
```

**默认策略 (policy=2)**：被 notify 的 waiter 从 WaitSet 移到 **cxq 头部**，而非直接唤醒。waiter 要等到 notify 的线程释放锁后，在 `exit()` 中才会被真正唤醒。这减少了无效的上下文切换。

---

## 11. NIO 的中断路径

### 11.1 问题：普通 I/O 阻塞不响应中断

```java
// 传统 BIO：
socket.getInputStream().read(buf);    // 阻塞在内核态的 read()
// 中断无效！因为 read() 不检查 Java 中断标志
```

JDK 的 NIO 通过**关闭 Channel**来实现"可中断的 I/O"。

### 11.2 AbstractInterruptibleChannel — 框架

```java
// AbstractInterruptibleChannel.java:152-203

// ─── I/O 操作前调用 ───
protected final void begin() {
    if (interruptor == null) {
        interruptor = new Interruptible() {
            public void interrupt(Thread target) {
                synchronized (closeLock) {
                    if (closed) return;
                    closed = true;
                    interrupted = target;
                    try {
                        AbstractInterruptibleChannel.this.implCloseChannel();
                        //      ↑ 关闭底层 fd，导致阻塞的 I/O 立即返回
                    } catch (IOException x) { }
                }
            }
        };
    }
    blockedOn(interruptor);                      // 注册到 Thread.blocker 字段
    Thread me = Thread.currentThread();
    if (me.isInterrupted())                      // 检查：可能在注册之前就已中断
        interruptor.interrupt(me);               // 立即关闭 Channel
}

// ─── I/O 操作后调用 ───
protected final void end(boolean completed) throws AsynchronousCloseException {
    blockedOn(null);                             // 取消注册
    Thread interrupted = this.interrupted;
    if (interrupted != null && interrupted == Thread.currentThread()) {
        this.interrupted = null;
        throw new ClosedByInterruptException();  // ← 这就是 NIO 中断的异常
    }
    if (!completed && closed)
        throw new AsynchronousCloseException();  // 其他线程关闭了 Channel
}
```

### 11.3 Thread.interrupt() 与 NIO 的交互

回看 `Thread.interrupt()` 的源码：

```java
public void interrupt() {
    if (this != Thread.currentThread()) checkAccess();

    synchronized (blockerLock) {
        Interruptible b = blocker;
        if (b != null) {
            interrupt0();           // ① 先设中断标志（JVM 层 os::interrupt 5 步）
            b.interrupt(this);      // ② 再调用 blocker 的 interrupt → implCloseChannel()
            return;
        }
    }
    interrupt0();
}
```

### 11.4 完整时序

```
线程 B (NIO 阻塞)                          线程 A (中断者)
    │                                           │
    │ channel.read(buf) 内部:                    │
    │   begin()                                  │
    │     blockedOn(interruptor)                 │  ← 注册 blocker
    │     isInterrupted() = false                │
    │   native read() → 阻塞在内核              │
    │       .                                    │
    │       .                   A: thread.interrupt()
    │       .                     synchronized(blockerLock)
    │       .                     b = blocker ≠ null
    │       .                     interrupt0()   ← 设中断标志
    │       .                     b.interrupt(B) ← 关闭 Channel
    │       .                       implCloseChannel()
    │       .                         close(fd)  ← 关闭文件描述符
    │       .                                    │
    │   native read() 返回 -1 或 EBADF          │
    │   end(false)                               │
    │     blockedOn(null)                        │  ← 取消注册
    │     interrupted == currentThread           │
    │     throw ClosedByInterruptException       │
```

### 11.5 blockedOn 的桥接机制

`Thread.blockedOn(Interruptible)` 是包私有方法，NIO 通过 `SharedSecrets` 桥接访问：

```java
// Thread.java:230-235
static void blockedOn(Interruptible b) {
    Thread me = Thread.currentThread();
    synchronized (me.blockerLock) {
        me.blocker = b;
    }
}

// System.java:2114-2116 (JavaLangAccess 实现)
public void blockedOn(Interruptible b) {
    Thread.blockedOn(b);
}

// AbstractInterruptibleChannel.java:207-209
static void blockedOn(Interruptible intr) {
    SharedSecrets.getJavaLangAccess().blockedOn(intr);
}
```

### 11.6 为什么是"关闭 Channel"而不是"发信号"？

1. **跨平台性**：不同 OS 对阻塞 I/O 的信号处理不一致（Linux 的 `SA_RESTART` 可能自动重试）
2. **语义清晰**：关闭 Channel 后，后续所有操作都会失败，符合"中断 = 停止"的语义
3. **确定性**：`close(fd)` 保证让阻塞的 `read(fd)` 返回，而信号可能被吞掉

### 11.7 两种 I/O 中断异常对比

| 异常 | 触发场景 | 含义 |
|------|---------|------|
| `ClosedByInterruptException` | `thread.interrupt()` 导致 Channel 关闭 | 线程被中断 |
| `AsynchronousCloseException` | 其他线程直接 `channel.close()` | Channel 被外部关闭 |

两者的区别在 `end()` 方法中：

```java
if (interrupted != null && interrupted == Thread.currentThread())
    throw new ClosedByInterruptException();     // 中断导致
if (!completed && closed)
    throw new AsynchronousCloseException();     // 外部关闭
```

---

## 12. PlatformEvent 的实现细节

### 12.1 PlatformEvent::park() — 无限等待

```cpp
// os_posix.cpp:1996-2036
void os::PlatformEvent::park() {
    // 状态转换: 1→0 (pass) 或 0→-1 (block)

    int v;
    for (;;) {
        v = _event;
        if (Atomic::cmpxchg(v - 1, &_event, v) == v) break;    // CAS 减 1
    }
    guarantee(v >= 0, "invariant");

    if (v == 0) {                               // 需要阻塞
        int status = pthread_mutex_lock(_mutex);
        guarantee(_nParked == 0, "invariant");
        ++_nParked;
        while (_event < 0) {                    // 循环等待（防虚假唤醒）
            status = pthread_cond_wait(_cond, _mutex);
        }
        --_nParked;
        _event = 0;                             // 消费信号
        status = pthread_mutex_unlock(_mutex);
        OrderAccess::fence();
    }
    // v == 1: 已有信号，CAS 后变 0，直接返回（快速路径）
}
```

### 12.2 PlatformEvent::park(millis) — 限时等待

```cpp
// os_posix.cpp:2038-2096
int os::PlatformEvent::park(jlong millis) {
    int v;
    for (;;) {
        v = _event;
        if (Atomic::cmpxchg(v - 1, &_event, v) == v) break;
    }

    if (v == 0) {
        struct timespec abst;
        to_abstime(&abst, millis * (NANOUNITS / MILLIUNITS), false);

        int ret = OS_TIMEOUT;
        int status = pthread_mutex_lock(_mutex);
        ++_nParked;

        while (_event < 0) {
            status = pthread_cond_timedwait(_cond, _mutex, &abst);
            if (!FilterSpuriousWakeups) break;
            if (status == ETIMEDOUT) break;
        }
        --_nParked;

        if (_event >= 0) ret = OS_OK;
        _event = 0;
        status = pthread_mutex_unlock(_mutex);
        OrderAccess::fence();
        return ret;
    }
    return OS_OK;
}
```

### 12.3 PlatformEvent::unpark()

```cpp
// os_posix.cpp:2098-2137
void os::PlatformEvent::unpark() {
    // 状态转换: 0→1 (return) / 1→1 (return) / -1→1 (signal)

    if (Atomic::xchg(1, &_event) >= 0) return;     // 快速路径：不是 -1 就不需要 signal

    // _event 之前是 -1 → 线程正在 parked
    int status = pthread_mutex_lock(_mutex);
    int anyWaiters = _nParked;
    status = pthread_mutex_unlock(_mutex);

    // signal 在释放锁之后 — 避免 futile wakeup
    if (anyWaiters != 0) {
        status = pthread_cond_signal(_cond);
    }
}
```

### 12.4 PlatformEvent 状态机

```
         unpark()               park()
  ┌───────────────┐   ┌────────────────────┐
  │               ▼   ▼                    │
  │             ┌───┐               ┌────┐ │
  │  unpark()   │ 1 │   park()     │ 0  │ │
  │  ────→      │ ↑ │   ────→      │    │ │
  │  (no-op)    └─┬─┘   (返回)     └──┬─┘ │
  │               │                    │   │
  │               │     park()         │   │
  │               │     ────→          ▼   │
  │               │              ┌────────┐│
  │               │              │   -1   ││
  │               └──────────────│ parked ││
  │                  unpark()    │(signal)││
  │                  ────→       └────────┘│
  └────────────────────────────────────────┘
```

---

## 13. Unsafe_Unpark 的特殊处理

```cpp
// unsafe.cpp:960-984
UNSAFE_ENTRY(void, Unsafe_Unpark(JNIEnv *env, jobject unsafe, jobject jthread)) {
    Parker* p = NULL;

    if (jthread != NULL) {
        ThreadsListHandle tlh;
        JavaThread* thr = NULL;
        oop java_thread = NULL;
        (void) tlh.cv_internal_thread_to_JavaThread(jthread, &thr, &java_thread);
        if (java_thread != NULL) {
            if (thr != NULL) {
                p = thr->parker();              // 线程活着 → 获取 Parker
            }
        }
    }
    // ThreadsListHandle 在此销毁

    // p 指向类型稳定的内存（immortal）
    // 即使目标线程在此期间终止，Parker 也不会被释放
    // 新线程重用此 Parker 会收到一次虚假 unpark — 完全安全
    if (p != NULL) {
        p->unpark();
    }
} UNSAFE_END
```

**类型稳定性保证**：

```
ThreadsListHandle 保护期间:       →    保护期外:
  thr → JavaThread → Parker          thr 可能已死
        ↓                            但 Parker 是 immortal
        p = thr->parker()            p 仍然有效
                                     unpark(p) 安全
```

这就是 Parker 和 ParkEvent 都设计为**不可删除（immortal）**的原因。

---

## 14. JVM 参数与日志

### 14.1 查看线程中断相关日志

虽然中断操作本身没有专门的日志标签，但可以通过以下参数观察相关行为：

**查看线程状态变化**：

```bash
-Xlog:os+thread=debug
```

输出示例：
```
[0.234s][debug][os,thread] Thread started (pthread id: 0x7f1234567000, 
    attributes: stacksize: 1024k, guardsize: 4k, detached)
```

**查看 Monitor wait/notify**：

```bash
-Xlog:monitorinflation=trace
```

**查看 safepoint（与 ThreadBlockInVM 相关）**：

```bash
-Xlog:safepoint=debug
```

### 14.2 GDB 验证中断标志

```bash
# 启动 GDB
gdb --args /data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
    -Xms8g -Xmx8g -XX:+UseG1GC -Xint \
    -cp /data/workspace/demo/src com.wjcoder.Main

# 在 os::interrupt 设断点
(gdb) b os::interrupt
(gdb) r

# 命中后查看参数
(gdb) p thread
(gdb) p thread->osthread()->_interrupted     # 中断前应为 0
(gdb) n                                       # 执行 set_interrupted(true)
(gdb) p thread->osthread()->_interrupted     # 中断后应为 1

# 查看三个事件对象
(gdb) p thread->_SleepEvent
(gdb) p thread->_SleepEvent->_event
(gdb) p thread->_ParkEvent
(gdb) p thread->_ParkEvent->_event
(gdb) p ((JavaThread*)thread)->parker()
(gdb) p ((JavaThread*)thread)->parker()->_counter
```

### 14.3 GDB 验证 Object.wait 中断

```bash
# 在三个检查点设断点
(gdb) b objectMonitor.cpp:1429    # 第 1 次检查
(gdb) b objectMonitor.cpp:1503    # 第 2 次检查
(gdb) b objectMonitor.cpp:1633    # 第 3 次检查

# 命中第 3 次检查时
(gdb) p WasNotified                # 0=非 notify, 1=被 notify
(gdb) p node._notified
(gdb) p node.TState                # TS_RUN / TS_ENTER / TS_CXQ
```

---

## 15. 各场景中断行为对比总结

### 15.1 总对比表

| 阻塞方式 | 使用的事件 | 中断后行为 | 清除标志 | 异常 |
|----------|-----------|-----------|---------|------|
| `Thread.sleep()` | `_SleepEvent` | 返回 OS_INTRPT → 抛异常 | **是** | `InterruptedException` |
| `Object.wait()` | `_ParkEvent` | 重新竞争锁后判断 | **是**（仅非 notify 时） | `InterruptedException` |
| `LockSupport.park()` | `Parker._counter` | 直接返回 | **否** | 无 |
| `NIO Channel.read()` | 无（kernel I/O） | 关闭 Channel | **否**（interrupt0 不清除） | `ClosedByInterruptException` |
| 纯 CPU 运行 | 无 | **什么都不发生** | — | 无 |
| `Thread.join()` | `_ParkEvent`（wait 内部） | 同 Object.wait | **是** | `InterruptedException` |

### 15.2 中断标志生命周期

```
                    interrupt()
                    set_interrupted(true)
                         │
    ┌────────────────────┼─────────────────────────┐
    │                    │                          │
    ▼                    ▼                          ▼
 Thread.sleep()    Object.wait()              LockSupport.park()
 is_interrupted    is_interrupted              is_interrupted
 (clear=true)      (clear=true)               (clear=false)
    │              (仅非notify时)                   │
    │                    │                          │
    ▼                    ▼                          ▼
 标志 → false         标志 → false             标志仍 true
 抛 IE                抛 IE                    正常返回
    │                    │                          │
    │                    │                          │
    └────────────────────┴──────────────────────────┘
                                                    │
                                                    ▼
                                              调用者必须:
                                              Thread.interrupted()
                                              手动清除标志
```

### 15.3 谁负责清除中断标志？

| 场景 | 清除者 | 时机 |
|------|--------|------|
| `Thread.sleep()` | JVM（`os::is_interrupted(true)`） | 检测到中断，准备抛异常前 |
| `Object.wait()` | JVM（`Thread::is_interrupted(true)`） | 重新获得锁后检测到中断 |
| `LockSupport.park()` | **调用者** | park 返回后，调用者调 `Thread.interrupted()` |
| NIO | **Java 代码** | 根据需要手动清除 |

---

## 16. 设计哲学总结

### 16.1 协作式 vs 抢占式

Java 选择协作式中断（设标志 + 检查），而非抢占式（发信号强制中断），原因：

1. **安全性**：抢占式中断可能在任意代码点打断，导致数据不一致（`Thread.stop()` 就是这个问题）
2. **可控性**：线程自己决定何时、如何响应中断
3. **清理机会**：线程可以在退出前清理资源、保存状态

### 16.2 "三把不同的钥匙"

同一个 `os::interrupt()` 发出信号，但三种场景用三种不同的事件对象，互不干扰：

```
os::interrupt()
    │
    ├── _SleepEvent  → 只影响 sleep
    ├── Parker       → 只影响 park
    └── _ParkEvent   → 只影响 wait/monitor
```

这样设计的好处：
- sleep 的 reset 不影响 wait
- park 的 permit 模型独立于 wait 的事件模型
- 各自可以独立优化（Parker 有快速路径，PlatformEvent 有 CAS 快速路径）

### 16.3 "宁可虚假唤醒，不可死锁"

JVM 的设计哲学是**允许虚假唤醒但绝不死锁**：
- `os::interrupt` 和 `os::is_interrupted` 之间无锁 → 可能虚假唤醒
- `Parker::unpark` 在释放锁后才 signal → 可能虚假唤醒
- 所有 park 的调用者都在循环中 → 虚假唤醒安全

---

## 17. 面试题精选

### Q1: interrupted() 和 isInterrupted() 的区别？

**答**：
- `Thread.interrupted()` 是**静态方法**，检查**当前线程**，**清除**中断标志
- `thread.isInterrupted()` 是**实例方法**，检查**目标线程**，**不清除**中断标志
- 底层都调用 `isInterrupted(boolean ClearInterrupted)` native 方法
- `interrupted()` 连续调第二次一定返回 false（除非两次之间又被中断了）

### Q2: sleep 被中断和 wait 被中断有什么不同？

**答**：
- **sleep**：只有一次检查时机（循环入口），被中断直接返回 `OS_INTRPT`，清除标志，抛 `InterruptedException`
- **wait**：有三次检查时机（进入前/park 前/重获锁后），必须重新获得锁后才能抛异常，且如果同时被 notify 和 interrupt，**notify 优先**（不抛异常，但保留中断标志）
- **共同点**：都清除中断标志后抛 `InterruptedException`

### Q3: 如果同时 notify 和 interrupt，会怎样？

**答**：**notify 优先**。源码在 `objectMonitor.cpp:1630`：

```cpp
if (!WasNotified) {  // 只有没被 notify 时才检查中断
    if (is_interrupted(Self, true))
        throw InterruptedException;
}
```

如果 `_notified == 1`，wait 正常返回，不抛异常，但中断标志仍然是 true，调用者可以后续检查。

### Q4: LockSupport.park() 被中断后为什么不抛异常？

**答**：
- park/unpark 是**低级原语**，设计为 `synchronized/wait/notify` 的替代品
- 它提供的是 **permit 模型**（0/1），语义极简
- JSR166（`java.util.concurrent`）的锁实现（ReentrantLock 等）需要自己决定如何处理中断：
  - `lock()` 不响应中断
  - `lockInterruptibly()` 手动检查后抛异常
- 如果 park 自动抛异常，`lock()` 就无法实现了

### Q5: Thread.interrupt() 内部做了哪几件事？

**答**：调用 `os::interrupt(thread)` 做了 5 步：
1. 设置 `OSThread._interrupted = 1`
2. `OrderAccess::fence()` 内存屏障
3. `_SleepEvent->unpark()` 唤醒 sleep（仅当首次设置标志）
4. `Parker->unpark()` 唤醒 LockSupport.park（**无条件，JSR166 要求**）
5. `_ParkEvent->unpark()` 唤醒 Object.wait（**无条件**）

### Q6: 为什么 _interrupted 是 volatile jint 而不是 bool？

**答**：
- JIT 需要内联 `isInterrupted()` → 直接读取内存 → 需要确定的大小和对齐
- JIT 做的是双重间接寻址：`Thread::current()->_osthread->_interrupted`
- `jint`（4 字节）在所有平台上大小确定，`bool` 的大小是实现定义的
- `@HotSpotIntrinsicCandidate` 注解告诉 JIT 可以将 JNI 调用替换为 ~3 条指令

### Q7: 如何正确处理 InterruptedException？

**答**：

```java
// ❌ 错误：吞掉异常
try { Thread.sleep(1000); }
catch (InterruptedException e) { }  // 中断标志已被清除，丢失了中断信息

// ✅ 正确方案 1：重新设置中断标志
try { Thread.sleep(1000); }
catch (InterruptedException e) {
    Thread.currentThread().interrupt();  // 恢复中断标志
}

// ✅ 正确方案 2：向上传播
void myMethod() throws InterruptedException {
    Thread.sleep(1000);  // 直接让异常传播
}
```

### Q8: NIO 的中断为什么要关闭 Channel？

**答**：
- 传统 I/O 阻塞在内核态的 `read()/write()` 系统调用，Java 的中断标志对内核无效
- 信号（SIGINT 等）在不同 OS 上行为不一致（Linux 的 `SA_RESTART` 会自动重试）
- `close(fd)` 是唯一能**跨平台、确定性地**让阻塞的 I/O 操作返回的方法
- 通过 `AbstractInterruptibleChannel.begin()/end()` 框架，将"关闭 Channel"包装为中断语义

---

## 18. 源码文件索引

| 文件 | 关键内容 |
|------|---------|
| `java/lang/Thread.java:979-1042` | interrupt()/interrupted()/isInterrupted() Java 层 |
| `java/lang/Thread.java:220-235` | blocker/blockerLock/blockedOn() NIO 桥接 |
| `java/nio/channels/spi/AbstractInterruptibleChannel.java:140-209` | begin()/end() NIO 中断框架 |
| `java/util/concurrent/locks/LockSupport.java:158-324` | park/unpark/parkNanos/parkUntil |
| `hotspot/share/prims/jvm.cpp:3123-3228` | JVM_Sleep/JVM_Interrupt/JVM_IsInterrupted |
| `hotspot/share/prims/unsafe.cpp:939-984` | Unsafe_Park/Unsafe_Unpark |
| `hotspot/share/runtime/thread.cpp:928-942` | Thread::interrupt/is_interrupted 委托层 |
| `hotspot/share/runtime/thread.cpp:305-316` | ParkEvent 四件套分配 |
| `hotspot/share/runtime/thread.hpp:732-735` | _ParkEvent/_SleepEvent/_MutexEvent/_MuxEvent 声明 |
| `hotspot/share/runtime/osThread.hpp:56-93` | OSThread::_interrupted 字段和 JIT offset |
| `hotspot/os/posix/os_posix.cpp:657-728` | os::sleep() 核心循环 |
| `hotspot/os/posix/os_posix.cpp:748-796` | os::interrupt()/os::is_interrupted() 核心实现 |
| `hotspot/os/posix/os_posix.cpp:1996-2137` | PlatformEvent::park()/unpark() |
| `hotspot/os/posix/os_posix.cpp:2152-2266` | Parker::park()/unpark() |
| `hotspot/os/posix/os_posix.hpp:170-220` | PlatformEvent/PlatformParker 类定义 |
| `hotspot/share/runtime/park.hpp:48-164` | Parker/ParkEvent 类定义 |
| `hotspot/share/runtime/objectMonitor.cpp:1416-1800` | wait()/INotify()/notify()/notifyAll() |
| `hotspot/share/runtime/objectMonitor.hpp:42-60` | ObjectWaiter 结构 |

---

*完成于 2026-02-08 | 基于 OpenJDK 11 源码逐行分析*
