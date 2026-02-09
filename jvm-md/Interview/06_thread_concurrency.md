# 主题六：线程与并发 — 从创建到 Safepoint

> 对应文档: `Thread/ch01~ch04`, `Phase3/`, `Safepoint/`, `Handshake/`, `VMThread/`
> 面试覆盖: 线程创建 / 线程状态 / Safepoint / Handshake / Parker / 线程退出

---

## Q1: Thread.start() 底层做了什么？⭐⭐

### 一句话结论
`Thread.start()` → JNI → 创建 `JavaThread` C++ 对象 → `os::create_thread()` → `pthread_create()` → 新线程进入 `thread_native_entry` → 最终 `JavaCalls::call` 调用 `Thread.run()`。

### 源码级回答

```
Java: thread.start()
  → JVM_StartThread (JNI)
    → new JavaThread(&thread_entry)  // C++ JavaThread 对象
    → os::create_thread(thread)
      → pthread_attr_setstack(stackSize)  // 设置栈大小
      → pthread_create(thread_native_entry)  // 创建 OS 线程!
    → Thread::start(thread)
      → os::start_thread()
        → pd_start_thread()
          → monitor->notify()  // 唤醒新线程

新线程执行:
  thread_native_entry()  // pthread 入口
    → thread->run()      // JavaThread::run()
      → thread_main_inner()
        → entry_point()  // = thread_entry
          → JavaCalls::call_virtual()
            → java.lang.Thread.run()  // 调用 Java 的 run() 方法!
```

**线程栈大小:**
```
-Xss 或 -XX:ThreadStackSize (默认 1MB on Linux x86_64)
实际包括: guard page (8KB) + shadow zone + Java 栈 + native 栈
```

> 📖 详细文档: `Thread/ch01_thread_start_complete_flow.md`

---

## Q2: Java 线程状态和 OS 线程状态的对应关系？⭐⭐

### 一句话结论
JVM 有**两套线程状态**: Java 层 `Thread.State`（6 种）和 JVM 内部 `JavaThreadState`（5 种），两者不是简单对应关系。

### 源码级回答

**Java 层 Thread.State:**
```
NEW         → 创建但未 start()
RUNNABLE    → 正在运行或就绪
BLOCKED     → 等待 synchronized 锁
WAITING     → wait()/join()/park() 无超时
TIMED_WAITING → wait(timeout)/sleep()/park(timeout)
TERMINATED  → 线程结束
```

**JVM 内部 JavaThreadState (线程转换用):**
```
_thread_new          → 刚创建
_thread_in_Java      → 执行 Java 字节码
_thread_in_vm        → 执行 JVM C++ 代码
_thread_in_native    → 执行 JNI native 代码
_thread_blocked      → 被阻塞 (等锁/safepoint)
```

**映射关系:**
```
Thread.State   │ JavaThreadState        │ OS 状态
───────────────┼────────────────────────┼──────────
RUNNABLE       │ _thread_in_Java        │ Running/Ready
RUNNABLE       │ _thread_in_native      │ Running (native)
BLOCKED        │ _thread_blocked        │ Sleeping (futex)
WAITING        │ _thread_blocked        │ Sleeping (futex)
TIMED_WAITING  │ _thread_blocked        │ Sleeping (futex)
```

**注意:** 执行 native I/O 的线程在 Java 层是 **RUNNABLE**，即使它在 OS 层面被 epoll_wait 阻塞了!

> 📖 详细文档: `Phase3/3.2_thread_state_analysis.md`

---

## Q3: 什么是 Safepoint？为什么需要它？⭐⭐

### 一句话结论
Safepoint = **所有 Java 线程暂停在已知安全点**的状态，是 GC、反优化、线程 dump 等操作的前提条件。"安全"指线程的引用关系对 GC 可见。

### 源码级回答

**为什么需要 Safepoint:**
```
问题: GC 需要准确知道所有对象引用的位置
      但线程正在执行代码，引用关系不断变化
      → 如果不暂停线程，GC 可能漏标或错标

解法: 让所有线程停在 "引用关系确定" 的安全位置
      → GC 可以安全地遍历 OopMap 找到所有引用
```

**哪些位置是 Safepoint:**
```
解释执行: 每条字节码之间 (dispatch 时检查 safepoint flag)
C1 编译: 回边位置 + 方法返回前 (编译时插入 safepoint poll)
C2 编译: 回边位置 + 方法返回前 (counted loop 除外!)
native 代码: 从 native 返回 Java 时检查
```

**Safepoint Poll 机制 (x86_64):**
```
// 编译代码中插入的检查:
test rax, [polling_page]  // 读 polling page
// 正常: polling_page 可读 → 继续执行
// 需要 STW: polling_page 被 mprotect 设为不可读
//            → SIGSEGV → 信号处理 → block_if_requested()
```

> 📖 详细文档: `Safepoint/ch01_safepoint_begin_deep_dive.md`, `Safepoint/SafepointMechanism.md`

---

## Q4: Safepoint 是怎么让所有线程停下来的？⭐⭐⭐

### 一句话结论
`SafepointSynchronize::begin()` arm Safepoint poll → 等待所有线程到达安全点（5 种策略对应 5 种线程状态）→ 执行 VM_Operation → `end()` 恢复。

### 源码级回答

**begin() 5 步流程:**
```
1. arm_safepoint()
   → 设置每个线程的 polling_page 为不可读 (mprotect)
   → 设置 _state = _synchronizing

2. 等待所有线程响应:
   分 5 种情况:
   ┌────────────────────┬─────────────────────────────────────────┐
   │ 线程状态            │ 如何停止                                │
   ├────────────────────┼─────────────────────────────────────────┤
   │ _thread_in_Java    │ 执行到 safepoint poll → SIGSEGV → block │
   │ _thread_in_native  │ 不需要停! 返回 Java 时自动检查          │
   │ _thread_blocked    │ 已经停了，不做任何事                     │
   │ _thread_in_vm      │ 在转换点检查 safepoint flag             │
   │ _thread_new        │ 还没开始执行，跳过                      │
   └────────────────────┴─────────────────────────────────────────┘

3. 所有线程到达 → _state = _synchronized

4. 执行 VM_Operation (如 GC)

5. end() → disarm_safepoint → 唤醒所有线程
```

**关键性能指标:**
- TTSP (Time To Safepoint): 从 begin() 到所有线程到达的时间
- 慢的原因通常: counted loop 没有 safepoint poll

> 📖 详细文档: `Safepoint/ch01_safepoint_begin_deep_dive.md`, `Safepoint/ch02_safepoint_gdb_practice.md`

---

## Q5: Counted Loop 为什么不插入 Safepoint Poll？怎么解决？⭐⭐⭐

### 一句话结论
C2 默认不在 counted loop (int 循环) 中插入 safepoint poll 以提高性能，但这会导致**长循环阻塞 Safepoint**。JDK 10+ 通过 **Loop Strip Mining** 解决。

### 源码级回答

**问题:**
```java
for (int i = 0; i < 1_000_000_000; i++) {
    // C2 不插入 safepoint poll
    // 这个循环执行几秒钟
    // 其间 GC 的 STW 请求无法生效!
    // → TTSP 暴涨 → 应用停顿
}
```

**Loop Strip Mining 解决方案:**
```java
// C2 自动变换为:
int i = 0;
while (i < 1_000_000_000) {
    // 外层循环: 有 safepoint poll!
    for (int j = 0; j < 1000 && i < 1_000_000_000; j++, i++) {
        // 内层循环: 无 safepoint poll (保持性能)
    }
    // 每 1000 次迭代检查一次 safepoint
}
```

**相关参数:**
```
-XX:+UseCountedLoopSafepoints  # 在 counted loop 中插入 safepoint
                                # G1/ZGC/Shenandoah 默认开启!
-XX:LoopStripMiningIter=1000   # strip mining 内层迭代数
```

> 📖 详细文档: `Safepoint/ch03_counted_loop_safepoint.md`

---

## Q6: 什么是 Handshake？和 Safepoint 有什么区别？⭐⭐⭐

### 一句话结论
Handshake 是**针对单个线程**的安全操作，不需要让所有线程都停下来。比 Safepoint 更轻量，适用于只需要与一个线程交互的场景。

### 源码级回答

| 维度 | Safepoint | Handshake |
|------|-----------|-----------|
| 影响范围 | **所有** Java 线程 | **单个**线程 |
| STW | 全局 STW | 无全局 STW |
| 适用场景 | GC、反优化 | 获取线程栈帧、偏向锁撤销 |
| 实现 | polling page 全局 arm | per-thread handshake state |
| 延迟 | 高 (等最慢线程) | 低 (只等一个线程) |

**Handshake 流程:**
```
发起者:
  → 设置目标线程的 HandshakeState
  → 如果目标线程在 native → 直接在发起者线程执行操作
  → 如果目标线程在 Java → 等目标线程到达 poll 点

目标线程:
  → 到达 safepoint poll (与 safepoint 共享检查点!)
  → 检查 handshake flag
  → 执行 handshake operation
  → 清除 flag
```

> 📖 详细文档: `Handshake/Handshake.md`

---

## Q7: LockSupport.park/unpark 底层是什么？⭐⭐

### 一句话结论
底层是 `Parker` 对象 (每个线程一个)，封装了 `pthread_mutex` + `pthread_cond`，park = `pthread_cond_wait`，unpark = `pthread_cond_signal`。

### 源码级回答

```cpp
class Parker {
    volatile int _counter;     // 许可: 0 或 1
    pthread_mutex_t _mutex;    // 互斥锁
    pthread_cond_t  _cond;     // 条件变量
};

void Parker::park() {
    if (_counter > 0) {        // 已有许可 → 消耗许可，直接返回
        _counter = 0;
        return;
    }
    pthread_mutex_lock(&_mutex);
    if (_counter > 0) {        // double-check
        _counter = 0;
        pthread_mutex_unlock(&_mutex);
        return;
    }
    pthread_cond_wait(&_cond, &_mutex);  // 阻塞!
    _counter = 0;
    pthread_mutex_unlock(&_mutex);
}

void Parker::unpark() {
    pthread_mutex_lock(&_mutex);
    int old = _counter;
    _counter = 1;              // 设置许可
    pthread_mutex_unlock(&_mutex);
    if (old < 1) {
        pthread_cond_signal(&_cond);  // 唤醒!
    }
}
```

**Parker vs PlatformEvent:**
```
Parker         → LockSupport.park/unpark 用
PlatformEvent  → ObjectMonitor 内部用 (wait/notify)
两者底层都是 pthread_mutex + pthread_cond
```

> 📖 详细文档: `Thread/ch04_parker_thread_exit.md`

---

## Q8: 线程中断机制怎么实现的？⭐⭐

### 一句话结论
`Thread.interrupt()` → 设置 `_interrupted` 标志位 + unpark 线程（如果线程在 park/sleep/wait 中则额外抛异常或返回）。

### 源码级回答

```cpp
void Thread::interrupt(Thread* thread) {
    // 1. 设置中断标志
    thread->set_interrupted(true);
    OrderAccess::fence();  // 内存屏障确保可见性

    // 2. 唤醒阻塞操作
    ParkEvent* ev = thread->_SleepEvent;
    if (ev != NULL) ev->unpark();     // 唤醒 Thread.sleep()

    Parker* p = thread->_parker;
    if (p != NULL) p->unpark();       // 唤醒 LockSupport.park()

    ParkEvent* ev2 = thread->_ParkEvent;
    if (ev2 != NULL) ev2->unpark();   // 唤醒 Object.wait()
}
```

**中断对不同操作的影响:**
| 操作 | 中断效果 |
|------|---------|
| `Thread.sleep()` | 抛出 InterruptedException，清除中断标志 |
| `Object.wait()` | 抛出 InterruptedException，清除中断标志 |
| `LockSupport.park()` | 立即返回（不抛异常），不清除中断标志 |
| 纯 CPU 计算 | 无效果，需要手动检查 `Thread.interrupted()` |
| `synchronized` | 无效果，不可中断 |

> 📖 详细文档: `Thread/ch02_thread_interrupt_mechanism.md`

---

## Q9: VMThread 是什么？VM_Operation 是怎么执行的？⭐⭐

### 一句话结论
VMThread 是 JVM 内部的**专用线程**，负责执行需要 Safepoint 的 VM_Operation（如 GC）。它从 VMOperationQueue 取任务，先触发 Safepoint，再执行操作。

### 源码级回答

```
VMThread::loop() {
    while (true) {
        // 1. 从队列取 VM_Operation
        VM_Operation* op = queue->remove_next();

        if (op->evaluate_at_safepoint()) {
            // 2. 需要 Safepoint → 触发 STW
            SafepointSynchronize::begin();

            // 3. 执行操作
            op->evaluate();  // 如 VM_G1CollectForAllocation::doit()

            // 4. 恢复
            SafepointSynchronize::end();
        } else {
            // 不需要 Safepoint → 直接执行
            op->evaluate();
        }
    }
}
```

**常见 VM_Operation:**
| 类名 | 功能 | 需要 Safepoint |
|------|------|---------------|
| VM_G1CollectForAllocation | Young/Mixed GC | ✅ |
| VM_G1CollectFull | Full GC | ✅ |
| VM_ThreadDump | 线程 dump | ✅ |
| VM_PrintThreads | 打印线程信息 | ✅ |
| VM_RedefineClasses | 热替换 | ✅ |
| VM_HeapDumper | 堆 dump | ✅ |

> 📖 详细文档: `VMThread/VMThread.md`, `Safepoint/ch01_safepoint_begin_deep_dive.md`

---

## Q10: 线程退出时 JVM 做了什么清理？⭐⭐

### 一句话结论
线程退出 → `JavaThread::exit()` → **释放所有持有的锁 + 执行 ThreadDeathEvent + 从线程链表移除 + 释放栈内存 + 通知等待 join() 的线程**。

### 源码级回答

```cpp
void JavaThread::exit(bool destroy_vm, ExitType exit_type) {
    // 1. 确保 Java 层的 uncaughtExceptionHandler 被调用

    // 2. 处理线程持有的锁
    ensure_join(this);   // 通知等待 join() 的线程

    // 3. JVMTI ThreadEnd 事件

    // 4. 从线程链表移除
    Threads::remove(this);

    // 5. 释放 JNIHandleBlock

    // 6. 刷新 TLAB (归还给 Eden)
    tlab().retire();

    // 7. 释放线程栈
    // pthread_exit() → OS 回收栈内存
}
```

**join() 的等待机制:**
```
thread.join()
  → 底层是 Object.wait()，等在 Thread 对象本身上
  → 线程退出时调用 notifyAll() 唤醒所有 join() 等待者
```

> 📖 详细文档: `Thread/ch04_parker_thread_exit.md`

---

## 🎯 面试话术建议

### 如何展示线程与 Safepoint 的源码功底:

> "Safepoint 的核心在 SafepointSynchronize::begin()。它分 5 种线程状态处理：_thread_in_Java 的线程通过 polling page 的 SIGSEGV 信号停下来；_thread_in_native 的线程不需要停——它们返回 Java 时会自动检查 safepoint flag；_thread_blocked 的已经停了。我用 GDB 观察过一次 Young GC 的完整 STW 生命周期，看到 _safepoint_counter 从偶数变奇数（进入 Safepoint）再变偶数（退出）。"

> "Counted loop 不插入 safepoint poll 是性能考虑，但会导致 TTSP 暴涨。G1 默认开启 UseCountedLoopSafepoints，实际用的是 Loop Strip Mining——C2 把 counted loop 拆成内外两层，内层保持无 poll 的性能，外层每 1000 次迭代检查一次。"

> "Thread.start() 的完整链路我跟过：JVM_StartThread 创建 JavaThread 对象，os::create_thread 调 pthread_create，新线程从 thread_native_entry 开始，最终通过 JavaCalls::call_virtual 调到 Java 的 Thread.run()。线程栈默认 1MB，包含 guard page 和 shadow zone。"
