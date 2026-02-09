# Ch04: Parker/ParkEvent 同步原语 + 线程退出/销毁全链路

> **标准环境**: `-Xms8g -Xmx8g -XX:+UseG1GC`, 16 核, Region 4MB
> **前置文档**: `Thread/ch01_thread_start_complete_flow.md`（线程创建）、`Thread/ch02_thread_interrupt_mechanism.md`（中断机制）
> **核心源码**: `park.hpp/cpp`（Parker/ParkEvent）、`os_posix.cpp`（POSIX 实现）、`unsafe.cpp`（JNI 入口）、`thread.cpp`（线程退出）

---

## 1. 解决什么问题？

### 1.1 线程阻塞/唤醒的需求

Java 并发编程中，线程需要在特定条件下**阻塞等待**并在条件满足时被**唤醒**。JVM 内部有两套阻塞/唤醒机制：

| 使用场景 | Java API | HotSpot 实现 |
|----------|----------|-------------|
| **JSR-166 并发工具** | `LockSupport.park/unpark` | **Parker** |
| **JVM 内部 Monitor** | `synchronized` / `Object.wait` | **ParkEvent** |

**为什么需要两套？**

这是历史演进的结果。ParkEvent 早于 Parker 存在，最初服务于 `synchronized`。JDK 5 引入 JSR-166（`java.util.concurrent`）时，Doug Lea 需要一个更轻量的 park/unpark 原语，于是新增了 Parker。源码注释（`park.hpp:47`）明确说：

> "In the future we'll want to think about eliminating Parker and using ParkEvent instead."

两者的核心差异：
- **Parker**：带有 **permit（许可证）** 语义，`unpark()` 预存一个许可，下次 `park()` 消耗它立即返回
- **ParkEvent**：带有 **event count** 语义，用于 JVM 内部的条件等待（ObjectMonitor 的 enter/exit/wait/notify）

### 1.2 线程退出的需求

当 Java 线程的 `run()` 方法返回或抛出未捕获异常时，需要一套**安全的退出流程**来清理线程资源。这包括：
- 调用 `Thread.exit()` Java 方法通知 ThreadGroup
- 设置线程状态为 TERMINATED
- 通知 `Thread.join()` 等待者
- 释放持有的锁
- 归还 TLAB、JNI Handle、GC 屏障缓冲区
- 从全局线程列表移除
- 回收 Parker/ParkEvent 到空闲列表

---

## 2. Parker — LockSupport.park/unpark 的底层实现

### 2.1 类继承体系

```
CHeapObj<mtSynchronizer>
  └── PlatformParker (os_posix.hpp:205)
       └── Parker (park.hpp:48)
```

### 2.2 PlatformParker — POSIX 平台层

```cpp
// os_posix.hpp:205
class PlatformParker : public CHeapObj<mtSynchronizer> {
protected:
  enum { REL_INDEX = 0, ABS_INDEX = 1 };
  int _cur_index;             // 当前使用哪个 cond: -1(无), 0(相对时间), 1(绝对时间)
  pthread_mutex_t _mutex[1];  // 互斥锁（40 bytes）
  pthread_cond_t  _cond[2];   // 两个条件变量（各 48 bytes）
                              // [0] = 相对时间, [1] = 绝对时间
};
```

**为什么有两个 `pthread_cond_t`？**

因为 `pthread_cond_timedwait()` 对相对时间和绝对时间使用不同的时钟源：
- `_cond[REL_INDEX]`：使用 `CLOCK_MONOTONIC`（单调递增，不受系统时间调整影响）
- `_cond[ABS_INDEX]`：使用默认时钟 `CLOCK_REALTIME`（绝对时间，可能被 NTP 调整）

`LockSupport.parkNanos()` 用相对时间，`LockSupport.parkUntil()` 用绝对时间。

### 2.3 Parker — JSR-166 层

```cpp
// park.hpp:48
class Parker : public os::PlatformParker {
private:
  volatile int _counter;        // 许可证计数: 0 或 1
  Parker * FreeNext;            // 空闲链表指针
  JavaThread * AssociatedWith;  // 关联的线程（生命周期绑定）

public:
  void park(bool isAbsolute, jlong time);  // 阻塞
  void unpark();                            // 唤醒

  static Parker * Allocate(JavaThread * t);  // 从空闲列表分配
  static void Release(Parker * e);            // 归还到空闲列表

private:
  static Parker * volatile FreeList;  // 全局空闲链表
  static volatile int ListLock;       // 保护空闲链表的自旋锁
};
```

### 2.4 GDB 验证 — sizeof

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
┌────────────────────────────────────────────────────────────────────┐
│ sizeof(Parker)          = 176 bytes                                │
│ sizeof(PlatformParker)  = 152 bytes                                │
│ sizeof(pthread_mutex_t) = 40 bytes                                 │
│ sizeof(pthread_cond_t)  = 48 bytes                                 │
│                                                                    │
│ Parker 内存布局:                                                   │
│   PlatformParker:       152 bytes                                  │
│     _cur_index:         4 bytes (int)                              │
│     [padding]:          4 bytes                                    │
│     _mutex[1]:          40 bytes (pthread_mutex_t)                 │
│     _cond[2]:           96 bytes (2 × pthread_cond_t)              │
│   _counter:             4 bytes (volatile int)                     │
│   [padding]:            4 bytes                                    │
│   FreeNext:             8 bytes (Parker*)                          │
│   AssociatedWith:       8 bytes (JavaThread*)                      │
│   总计:                 176 bytes                                  │
└────────────────────────────────────────────────────────────────────┘
```

### 2.5 核心算法：park()

```cpp
// os_posix.cpp:2158
void Parker::park(bool isAbsolute, jlong time) {

  // ① 快速路径：如果有许可证，直接消耗返回
  if (Atomic::xchg(0, &_counter) > 0) return;
  //   Atomic::xchg(0, &_counter): 原子地将 _counter 设为 0，返回旧值
  //   如果旧值 > 0（有许可），直接返回，不阻塞

  JavaThread *jt = (JavaThread *)Thread::current();

  // ② 检查中断：如果已被中断，直接返回（不消耗中断状态）
  if (Thread::is_interrupted(thread, false)) {
    return;
  }

  // ③ 时间参数处理
  struct timespec absTime;
  if (time < 0 || (isAbsolute && time == 0)) return;  // 不等待
  if (time > 0) {
    to_abstime(&absTime, time, isAbsolute);  // 转换为绝对时间
  }

  // ④ 进入 Safepoint 安全区域（关键！）
  ThreadBlockInVM tbivm(jt);
  //   这里会执行线程状态转换: _thread_in_vm → _thread_blocked
  //   使 Safepoint 机制知道这个线程"安全"了
  //   如果此时有 Safepoint 请求，会先处理 Safepoint

  // ⑤ 再次检查中断 + 尝试获取锁
  if (Thread::is_interrupted(thread, false) ||
      pthread_mutex_trylock(_mutex) != 0) {
    return;
    // trylock 失败说明 unpark 正在持锁（意味着有人在 unpark 我）
    // 直接返回即可
  }

  // ⑥ 持锁后再次检查许可证
  if (_counter > 0) {
    _counter = 0;
    pthread_mutex_unlock(_mutex);
    OrderAccess::fence();
    return;
  }

  // ⑦ 真正阻塞：pthread_cond_wait / pthread_cond_timedwait
  OSThreadWaitState osts(thread->osthread(), false);
  jt->set_suspend_equivalent();  // 设置挂起等价标记

  if (time == 0) {
    _cur_index = REL_INDEX;  // 无限期等待
    pthread_cond_wait(&_cond[_cur_index], _mutex);
  } else {
    _cur_index = isAbsolute ? ABS_INDEX : REL_INDEX;
    pthread_cond_timedwait(&_cond[_cur_index], _mutex, &absTime);
  }
  _cur_index = -1;  // 标记不再等待

  // ⑧ 被唤醒后：清理
  _counter = 0;
  pthread_mutex_unlock(_mutex);
  OrderAccess::fence();

  // ⑨ 如果在等待期间被外部挂起，执行自挂起
  if (jt->handle_special_suspend_equivalent_condition()) {
    jt->java_suspend_self();
  }
}
```

**关键设计要点**：

1. **permit 语义**：`_counter` 只有 0 和 1 两种状态。`unpark()` 设为 1（预存许可），`park()` 先检查是否有许可再决定是否阻塞
2. **先 CAS 后 lock**：快速路径用 `Atomic::xchg`（无锁），慢路径才加 `pthread_mutex`
3. **ThreadBlockInVM**：将线程状态切换为 `_thread_blocked`，使 Safepoint 不需要等待这个线程
4. **多重检查**：中断检查 × 2 + 许可检查 × 2（无锁一次 + 持锁一次），避免不必要的阻塞
5. **trylock 而非 lock**：如果锁被占用（说明有 unpark 正在执行），直接返回

### 2.6 核心算法：unpark()

```cpp
// os_posix.cpp:2256
void Parker::unpark() {
  // ① 加锁
  int status = pthread_mutex_lock(_mutex);

  // ② 保存旧的 _counter，设新值为 1（给予许可）
  const int s = _counter;
  _counter = 1;

  // ③ 记录当前 cond index（必须在解锁前捕获）
  int index = _cur_index;

  // ④ 解锁（先解锁再 signal，避免 futile wakeup）
  status = pthread_mutex_unlock(_mutex);

  // ⑤ 如果旧 counter == 0 且线程确实在等待，signal 唤醒
  if (s < 1 && index != -1) {
    status = pthread_cond_signal(&_cond[index]);
  }
}
```

**为什么先 unlock 再 signal？**

这是一个经典优化：**先解锁再发信号**（signal-after-unlock），避免"futile wakeup"——如果先 signal 再 unlock，被唤醒的线程会立即尝试获取锁，但锁还没释放，导致白白醒来又立即阻塞。

### 2.7 Parker 时序图

```
LockSupport.park()                          LockSupport.unpark(thread)
      │                                            │
      ▼                                            ▼
  Unsafe_Park()                              Unsafe_Unpark()
      │                                            │
      ▼                                            ▼
  Parker::park()                             Parker::unpark()
      │                                            │
      │  ① xchg(0, &_counter)                      │
      │     旧值==0 (无许可)                         │
      │                                            │
      │  ② is_interrupted? No                       │
      │                                            │
      │  ③ ThreadBlockInVM → _thread_blocked        │
      │                                            │
      │  ④ trylock(_mutex) → 成功                   │
      │                                            │
      │  ⑤ _counter==0, 需要等待                     │
      │                                            │
      │  ⑥ _cur_index=0                             │
      │     pthread_cond_wait(阻塞...)              │  ① lock(_mutex)
      │         │                                  │  ② _counter=1, index=0
      │         │                                  │  ③ unlock(_mutex)
      │         │    ◀──── cond_signal ─────────── │  ④ cond_signal(&cond[0])
      │         │                                  │
      │  ⑦ 醒来: _counter=0                         │
      │     unlock(_mutex)                          │
      │     fence()                                 │
      ▼                                            ▼
   返回                                          返回
```

### 2.8 JNI 入口：Unsafe_Park / Unsafe_Unpark

```cpp
// unsafe.cpp:939
UNSAFE_ENTRY(void, Unsafe_Park(JNIEnv *env, jobject unsafe, jboolean isAbsolute, jlong time)) {
  HOTSPOT_THREAD_PARK_BEGIN(...);     // DTrace 探针
  EventThreadPark event;              // JFR 事件
  JavaThreadParkedState jtps(thread, time != 0);  // 设置线程状态 PARKED/PARKED_TIMED
  thread->parker()->park(isAbsolute != 0, time);  // ← 核心调用
  if (event.should_commit()) {
    post_thread_park_event(&event, ...);  // JFR 记录
  }
  HOTSPOT_THREAD_PARK_END(...);
} UNSAFE_END

UNSAFE_ENTRY(void, Unsafe_Unpark(JNIEnv *env, jobject unsafe, jobject jthread)) {
  Parker* p = NULL;
  if (jthread != NULL) {
    ThreadsListHandle tlh;  // 线程安全地访问线程列表
    JavaThread* thr = NULL;
    oop java_thread = NULL;
    (void) tlh.cv_internal_thread_to_JavaThread(jthread, &thr, &java_thread);
    if (thr != NULL) {
      p = thr->parker();  // 获取目标线程的 Parker
    }
  }
  // p 指向 type-stable 内存：即使目标线程已退出，Parker 仍有效
  // （新的线程可能复用了这个 Parker，收到 spurious unpark 是安全的）
  if (p != NULL) {
    p->unpark();
  }
} UNSAFE_END
```

**关键细节**：`Unsafe_Unpark` 中使用 `ThreadsListHandle` 保护线程列表访问。即使目标线程在 unpark 期间退出，Parker 的**类型稳定性（type-stability）**保证了不会访问到无效内存。


---

## 3. ParkEvent — JVM 内部 Monitor 的阻塞/唤醒

### 3.1 类继承体系

```
CHeapObj<mtSynchronizer>
  └── PlatformEvent (os_posix.hpp:170)
       └── ParkEvent (park.hpp:118)
```

### 3.2 PlatformEvent — POSIX 平台层

```cpp
// os_posix.hpp:170
class PlatformEvent : public CHeapObj<mtSynchronizer> {
private:
  double cachePad[4];           // 32 bytes 缓存行填充
  volatile int _event;          // 事件计数: -1, 0, 1
  volatile int _nParked;        // 是否有线程在等待: 0 或 1
  pthread_mutex_t _mutex[1];    // 互斥锁
  pthread_cond_t  _cond[1];     // 条件变量（只有 1 个，不区分相对/绝对时间）
  double postPad[2];            // 16 bytes 后缓存行填充

public:
  void park();                  // 无限期等待
  int  park(jlong millis);      // 超时等待
  void unpark();                // 唤醒
  void reset() { _event = 0; }
};
```

**与 PlatformParker 的对比**：
- PlatformEvent 只有 **1 个 cond**（不区分时钟源），PlatformParker 有 **2 个 cond**
- PlatformEvent 有 **缓存行填充**（cachePad/postPad），PlatformParker 没有
- PlatformEvent 的 `_event` 支持 **三态**（-1, 0, 1），Parker 的 `_counter` 只有 **两态**（0, 1）

### 3.3 ParkEvent — 平台无关层

```cpp
// park.hpp:118
class ParkEvent : public os::PlatformEvent {
private:
  ParkEvent * FreeNext;               // 空闲链表指针
  Thread * AssociatedWith;            // 关联的线程

public:
  ParkEvent * volatile ListNext;      // MCS-CLH 链表节点
  volatile intptr_t OnList;           // 是否在某个队列中
  volatile int TState;                // 临时状态
  volatile int Notified;              // 是否已被 notify

  static ParkEvent * Allocate(Thread * t);
  static void Release(ParkEvent * e);

private:
  static ParkEvent * volatile FreeList;
  static volatile int ListLock;
};
```

**注意**：ParkEvent 比 Parker 多了 `ListNext`、`OnList`、`TState`、`Notified` 字段，这些用于 ObjectMonitor 的 **cxq/EntryList/WaitSet** 队列管理。

### 3.4 PlatformEvent::park() — 三态 event 协议

```cpp
// os_posix.cpp:1996
void os::PlatformEvent::park() {       // AKA "down()"
  // _event 状态转换:
  //   -1 => -1 : 非法（不可能）
  //    1 =>  0 : 有许可，直接消耗返回
  //    0 => -1 : 阻塞等待

  int v;
  // ① 原子递减 _event
  for (;;) {
    v = _event;
    if (Atomic::cmpxchg(v - 1, &_event, v) == v) break;
  }
  // v 是递减前的旧值

  if (v == 0) {
    // ② v==0 意味着 _event 变成了 -1，需要真正阻塞
    pthread_mutex_lock(_mutex);
    ++_nParked;

    while (_event < 0) {
      pthread_cond_wait(_cond, _mutex);
      // 可能 spurious wakeup，必须循环检查
    }

    --_nParked;
    _event = 0;  // 重置为初始态
    pthread_mutex_unlock(_mutex);
    OrderAccess::fence();
  }
  // v==1 意味着 _event 变成了 0（消耗了一个许可），直接返回
}
```

### 3.5 PlatformEvent::unpark()

```cpp
// os_posix.cpp:2104
void os::PlatformEvent::unpark() {
  // _event 状态转换:
  //    0 => 1 : 给予许可
  //    1 => 1 : 已有许可，无操作
  //   -1 => 0 或 1 : 线程正在等待，唤醒它

  // ① 原子设 _event = 1
  if (Atomic::xchg(1, &_event) >= 0) return;
  //   旧值 >= 0 说明没有线程在等待（0 或 1），直接返回

  // ② 旧值 == -1：有线程在等待
  pthread_mutex_lock(_mutex);
  int anyWaiters = _nParked;
  pthread_mutex_unlock(_mutex);

  // ③ 先解锁再 signal（同 Parker 的优化）
  if (anyWaiters != 0) {
    pthread_cond_signal(_cond);
  }
}
```

### 3.6 三态 vs 两态对比

```
Parker (_counter):   0 ──── park() ────→ 阻塞
                     1 ──── park() ────→ 消耗许可，立即返回
                            unpark() → _counter = 1

PlatformEvent (_event):
                     1 ──── park() ────→ _event = 0，立即返回
                     0 ──── park() ────→ _event = -1，阻塞
                    -1 ──── unpark() ──→ _event = 1，signal 唤醒

三态的好处：
  - _event = -1 明确表示"有线程正在等待"
  - unpark() 可以通过 Atomic::xchg 的旧值判断是否需要 signal
  - 避免了 Parker 中需要检查 _cur_index 的额外判断
```

### 3.7 GDB 验证 — 每个 JavaThread 的 3 个 ParkEvent

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
┌────────────────────────────────────────────────────────────────────┐
│ sizeof(ParkEvent)      = 192 bytes                                 │
│ sizeof(PlatformEvent)  = 152 bytes                                 │
│                                                                    │
│ 每个 JavaThread 持有:                                              │
│   _parker:     0x7ffff0021b50  ← Parker (LockSupport 用)          │
│   _SleepEvent: 0x7ffff0021500  ← ParkEvent (Thread.sleep 用)      │
│   _ParkEvent:  0x7ffff0021300  ← ParkEvent (ObjectMonitor 用)     │
│   _MuxEvent:   0x7ffff0021900  ← ParkEvent (内部 Mutex/Monitor)   │
│                                                                    │
│ 所有 _event 初始值: 0                                              │
│ parker->_counter 初始值: 0                                         │
│ parker->_cur_index 初始值: -1 (未在等待)                           │
│ parker->AssociatedWith: 指向自身 JavaThread                        │
│                                                                    │
│ 每线程同步原语开销:                                                 │
│   1 × Parker (176B) + 3 × ParkEvent (3 × 192B) = 752 bytes       │
└────────────────────────────────────────────────────────────────────┘
```

---

## 4. 类型稳定性（Type-Stability）与空闲列表

### 4.1 为什么需要类型稳定性？

这是 Parker/ParkEvent 最巧妙的设计之一。

**问题场景**：
1. 线程 A 持有线程 B 的 Parker 引用 `p`
2. 线程 B 退出并被销毁，`p` 变成野指针
3. 线程 A 调用 `p->unpark()`，**访问已释放内存 → crash**

**JVM 的解决方案**：**Parker/ParkEvent 永远不释放（immortal）**。

```cpp
// park.hpp:63
~Parker() { ShouldNotReachHere(); }  // 析构函数永远不会被调用！

// park.hpp:149
~ParkEvent() { guarantee(0, "invariant"); }  // 同上
```

### 4.2 空闲列表回收

线程退出时，Parker/ParkEvent 不是被 `delete`，而是被**归还到全局空闲列表**：

```cpp
// park.cpp:108 - Parker::Release
void Parker::Release(Parker * p) {
  p->AssociatedWith = NULL;  // 解除关联

  Thread::SpinAcquire(&ListLock, "ParkerFreeListRelease");
  {
    p->FreeNext = FreeList;  // 头插法
    FreeList = p;
  }
  Thread::SpinRelease(&ListLock);
}
```

新线程创建时，**优先从空闲列表分配**：

```cpp
// park.cpp:92 - Parker::Allocate
Parker * Parker::Allocate(JavaThread * t) {
  Parker * p;

  Thread::SpinAcquire(&ListLock, "ParkerFreeListAllocate");
  {
    p = FreeList;
    if (p != NULL) {
      FreeList = p->FreeNext;  // 从链表头部取
    }
  }
  Thread::SpinRelease(&ListLock);

  if (p != NULL) {
    guarantee(p->AssociatedWith == NULL, "invariant");
  } else {
    p = new Parker();  // 链表为空时才分配新的
  }
  p->AssociatedWith = t;
  p->FreeNext = NULL;
  return p;
}
```

### 4.3 ParkEvent 的 256 字节对齐

ParkEvent 更特殊——它强制 **256 字节对齐**：

```cpp
// park.cpp:80
void * ParkEvent::operator new(size_t sz) throw() {
  return (void*)((intptr_t(AllocateHeap(sz + 256, mtInternal, CALLER_PC)) + 256) & -256);
}
```

**为什么？**  
因为 ParkEvent 的地址最低 8 位固定为 0（256 = 2^8），这使得可以**在指针的低位存储标志位**。ObjectMonitor 利用这一特性来编码额外信息。

### 4.4 空闲列表生命周期图

```
线程 A 创建         线程 A 退出          线程 C 创建
   │                    │                    │
   ▼                    ▼                    ▼
Parker::Allocate()   Parker::Release()   Parker::Allocate()
   │                    │                    │
   │ FreeList 为空       │ 归还到 FreeList     │ 从 FreeList 取
   │ → new Parker()     │ → 头插法            │ → 复用旧 Parker
   │                    │                    │
   ▼                    ▼                    ▼
 Parker@0x100         FreeList:            Parker@0x100
 .AssociatedWith=A    [0x100] → NULL      .AssociatedWith=C
                                          (同一个 Parker 对象!)

注意：如果线程 B 在线程 A 退出前持有 Parker@0x100 的引用
      线程 B 调用 unpark() → 会唤醒线程 C
      这是一个 "spurious unpark"，是安全的
      因为 park/unpark 语义本身就允许虚假唤醒
```

---

## 5. Thread.sleep() 实现

### 5.1 调用链

```
Thread.sleep(millis)
  └── JVM_Sleep(millis)          [jvm.cpp:3123]
       ├── 检查 millis < 0 → IllegalArgumentException
       ├── 检查中断 → InterruptedException
       ├── millis == 0 → os::naked_yield()  // 让出 CPU 时间片
       └── millis > 0 → os::sleep(thread, millis, true)
            └── ParkEvent::park(millis)   // 用 SleepEvent
```

### 5.2 JVM_Sleep 源码

```cpp
// jvm.cpp:3123
JVM_ENTRY(void, JVM_Sleep(JNIEnv *env, jclass threadClass, jlong millis))
  if (millis < 0) {
    THROW_MSG(vmSymbols::java_lang_IllegalArgumentException(), "timeout value is negative");
  }

  // ① 检查中断（清除中断标志）
  if (Thread::is_interrupted(THREAD, true) && !HAS_PENDING_EXCEPTION) {
    THROW_MSG(vmSymbols::java_lang_InterruptedException(), "sleep interrupted");
  }

  // ② 设置线程状态为 SLEEPING
  JavaThreadSleepState jtss(thread);

  if (millis == 0) {
    // ③ sleep(0) → 让出时间片
    os::naked_yield();
  } else {
    // ④ 实际睡眠
    thread->osthread()->set_state(SLEEPING);
    if (os::sleep(thread, millis, true) == OS_INTRPT) {
      // 被中断唤醒 → 抛 InterruptedException
      if (!HAS_PENDING_EXCEPTION) {
        THROW_MSG(vmSymbols::java_lang_InterruptedException(), "sleep interrupted");
      }
    }
    thread->osthread()->set_state(old_state);
  }
JVM_END
```

**关键区别**：`Thread.sleep()` 使用的是 `_SleepEvent`（ParkEvent），而不是 `_parker`（Parker）。`LockSupport.park()` 才使用 `_parker`。

---

## 6. Parker vs ParkEvent 完整对比

| 维度 | Parker | ParkEvent |
|------|--------|-----------|
| **用途** | JSR-166: `LockSupport.park/unpark` | JVM 内部: `ObjectMonitor`, `Thread.sleep` |
| **sizeof** | 176 bytes | 192 bytes |
| **许可语义** | `_counter`: 0 或 1 | `_event`: -1, 0, 1（三态） |
| **条件变量** | 2 个（相对/绝对时间） | 1 个 |
| **缓存行填充** | 无 | 有（前32B + 后16B） |
| **队列字段** | 无 | ListNext/OnList/TState/Notified |
| **关联线程** | JavaThread* (只能关联 Java 线程) | Thread* (可关联任意线程) |
| **内存对齐** | 默认 | 256 字节对齐 |
| **每线程数量** | 1 个 (_parker) | 3 个 (_SleepEvent + _ParkEvent + _MuxEvent) |
| **Java 层使用者** | ReentrantLock, CountDownLatch, Semaphore... | synchronized, Object.wait, Thread.sleep |
| **总开销/每线程** | 176 bytes | 576 bytes (3 × 192) |
| **合计/每线程** | 752 bytes (1 Parker + 3 ParkEvent) | — |


---

## 7. JavaThread::exit() — 线程退出全链路

### 7.1 触发条件

| 退出方式 | exit_type | destroy_vm | 触发位置 |
|----------|-----------|-----------|---------|
| `Thread.run()` 正常返回 | `jni_detach` | false | `JavaMain() → DestroyJavaVM()` → JNI DetachCurrentThread |
| `System.exit()` 导致主线程退出 | `normal_exit` | true | `Threads::destroy_vm()` |
| 未捕获异常 | `jni_detach` | false | 异常传播到 `Thread.run()` |
| JNI DetachCurrentThread | `jni_detach` | false | 显式调用 |

### 7.2 四阶段退出流程

```
JavaThread::exit(destroy_vm, exit_type)
┌──────────────────────────────────────────────────────────────────────────┐
│ Phase 1: Java 层清理                                                     │
│ ─────────────────────────────────────────────                            │
│ ① 处理未捕获异常                                                         │
│    Thread.dispatchUncaughtException(uncaught_exception)                  │
│    → 调用 UncaughtExceptionHandler                                       │
│                                                                          │
│ ② 调用 Thread.exit()（最多 3 次，防止 Thread.stop 干扰）                  │
│    → 从 ThreadGroup 移除自己                                              │
│    → 清理 ThreadGroup（如果是最后一个 daemon 线程）                        │
│                                                                          │
│ ③ JVMTI 通知                                                             │
│    JvmtiExport::post_thread_end(this)                                    │
│                                                                          │
│ ④ 设置 terminated = _thread_exiting                                      │
│    ThreadService::current_thread_exiting(this)                           │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│ Phase 2: 通知 join() 等待者                                              │
│ ─────────────────────────────────────────────                            │
│ ensure_join(this):                                                       │
│ ⑤ 锁住 Java Thread 对象（ObjectLocker）                                  │
│ ⑥ set_thread_status(TERMINATED)                                          │
│ ⑦ java_lang_Thread::set_thread(NULL)  // isAlive() → false              │
│ ⑧ lock.notify_all()  // 唤醒所有 Thread.join() 等待者                    │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│ Phase 3: Native 资源清理                                                  │
│ ─────────────────────────────────────────────                            │
│ ⑨ 释放持有的 Java Monitor（如果是 jni_detach 退出）                       │
│    ObjectSynchronizer::release_monitors_owned_by_thread(this)            │
│                                                                          │
│ ⑩ JFR 通知                                                               │
│    Jfr::on_thread_exit(this)                                             │
│                                                                          │
│ ⑪ 释放 JNI Handle Block                                                  │
│    JNIHandleBlock::release_block(active_handles())                       │
│    JNIHandleBlock::release_block(free_handle_block())                    │
│                                                                          │
│ ⑫ 移除栈保护页                                                           │
│    remove_stack_guard_pages()                                             │
│                                                                          │
│ ⑬ 退还 TLAB                                                              │
│    tlab().make_parsable(true)  // 使 TLAB 对 GC 可解析                    │
│                                                                          │
│ ⑭ JVMTI 清理                                                             │
│    JvmtiExport::cleanup_thread(this)                                     │
│                                                                          │
│ ⑮ GC 屏障清理（G1 特有）                                                 │
│    BarrierSet::barrier_set()->on_thread_detach(this)                     │
│    → 冲刷 SATB buffer 和 dirty card queue                                │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│ Phase 4: 从全局列表移除                                                   │
│ ─────────────────────────────────────────────                            │
│ ⑯ Threads::remove(this, daemon)                                          │
│    → ObjectSynchronizer::omFlush(this)  // 回收 ObjectMonitor             │
│    → MutexLocker(Threads_lock)                                           │
│    → ThreadsSMRSupport::remove_thread(this)  // SMR 安全移除              │
│    → 从 _thread_list 链表删除                                             │
│    → _number_of_threads--                                                 │
│    → if (!daemon) _number_of_non_daemon_threads--                         │
│    → if (non_daemon == 1) Threads_lock->notify_all()                     │
│      // 只剩 main 线程 → 唤醒 DestroyJavaVM 等待                         │
│    → set_terminated(_thread_terminated)  // 最终状态                      │
└──────────────────────────────────────────────────────────────────────────┘
```

### 7.3 ensure_join — Thread.join() 的底层通知

```cpp
// thread.cpp:1986
static void ensure_join(JavaThread *thread) {
  Handle threadObj(thread, thread->threadObj());
  ObjectLocker lock(threadObj, thread);  // ← 锁住 Java Thread 对象

  thread->clear_pending_exception();

  // ① 设置 thread status = TERMINATED
  java_lang_Thread::set_thread_status(threadObj(), java_lang_Thread::TERMINATED);

  // ② 清除 native 线程引用 → isAlive() 返回 false
  java_lang_Thread::set_thread(threadObj(), NULL);

  // ③ 通知所有 join() 等待者
  lock.notify_all(thread);

  thread->clear_pending_exception();
}
```

**Thread.join() 的等待/唤醒机制**：

```java
// Thread.java
public final synchronized void join(long millis) throws InterruptedException {
    while (isAlive()) {
        wait(millis);  // ← 等待在 Thread 对象的 Monitor 上
    }
}
```

`join()` 在 Java 层调用 `wait()`，等待在**目标线程的 Java Thread 对象**上。
`ensure_join()` 在 C++ 层调用 `notify_all()`，唤醒所有等待者。
当 `isAlive()` 返回 false（因为 `set_thread(NULL)` 清除了 native 线程引用），循环退出。

### 7.4 Threads::remove — 从全局列表安全移除

```cpp
// thread.cpp:4708
void Threads::remove(JavaThread *p, bool is_daemon) {
  // ① 回收 ObjectMonitor
  ObjectSynchronizer::omFlush(p);

  {
    MutexLocker ml(Threads_lock);

    // ② SMR 安全移除（Hazard Pointer 机制）
    ThreadsSMRSupport::remove_thread(p);

    // ③ 从链表删除
    JavaThread *current = _thread_list;
    JavaThread *prev = NULL;
    while (current != p) {
      prev = current;
      current = current->next();
    }
    if (prev) prev->set_next(current->next());
    else _thread_list = p->next();

    // ④ 计数
    _number_of_threads--;
    if (!is_daemon) {
      _number_of_non_daemon_threads--;
      // 只剩 1 个非 daemon 线程（main）→ 通知 DestroyJavaVM
      if (number_of_non_daemon_threads() == 1) {
        Threads_lock->notify_all();
      }
    }

    // ⑤ 设置最终状态（Safepoint 不再关注此线程）
    p->set_terminated_value();
  }
}
```

### 7.5 GDB 验证 — JavaThread::exit 运行时数据

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
┌────────────────────────────────────────────────────────────────────┐
│ JavaThread::exit #1 (Attach 线程退出)                              │
│   this: 0x7ffff001f000                                             │
│   destroy_vm: false                                                │
│   exit_type: 1 (jni_detach)                                       │
│   parker->_counter: 0                                              │
│   parker->_cur_index: -1                                           │
│   parker->AssociatedWith: 0x7ffff001f000 (= this)                 │
│   _SleepEvent->_event: 0                                           │
│   _ParkEvent->_event: 0                                            │
│                                                                    │
│ JavaThread::exit #2 (主线程退出)                                    │
│   this: 0x7ffff001f000 (同一个线程)                                 │
│   destroy_vm: true                                                 │
│   exit_type: 0 (normal_exit)                                       │
│                                                                    │
│ 观察: 主线程的 exit 被调用了两次:                                    │
│   第一次: jni_detach — JavaMain() 中 DetachCurrentThread            │
│   第二次: normal_exit + destroy_vm — Threads::destroy_vm()          │
└────────────────────────────────────────────────────────────────────┘
```

---

## 8. 完整线程生命周期总结

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Java 线程完整生命周期                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐                  │
│  │  创建阶段     │    │  运行阶段     │    │  退出阶段     │                  │
│  │              │    │              │    │              │                  │
│  │ new Thread() │───▶│ Thread.start()│───▶│ run() 返回   │                  │
│  │              │    │              │    │ / 异常       │                  │
│  └──────────────┘    └──────────────┘    └──────────────┘                  │
│        │                    │                    │                          │
│        ▼                    ▼                    ▼                          │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐                  │
│  │ HotSpot 层    │    │ HotSpot 层    │    │ HotSpot 层    │                  │
│  │              │    │              │    │              │                  │
│  │ JavaThread   │    │ Parker       │    │ exit()       │                  │
│  │ ::allocate() │    │ .park()      │    │ 4 阶段:       │                  │
│  │              │    │ .unpark()    │    │ Java清理      │                  │
│  │ Parker       │    │              │    │ ensure_join   │                  │
│  │ ::Allocate() │    │ ParkEvent    │    │ Native清理    │                  │
│  │              │    │ .park()      │    │ Threads::     │                  │
│  │ ParkEvent    │    │ .unpark()    │    │ remove()      │                  │
│  │ ::Allocate() │    │              │    │              │                  │
│  │ ×3           │    │ Thread.sleep │    │ Parker       │                  │
│  │              │    │ Object.wait  │    │ ::Release()  │                  │
│  │ 752 bytes    │    │ LockSupport  │    │ ParkEvent    │                  │
│  │ 同步原语     │    │ .park()      │    │ ::Release()  │                  │
│  └──────────────┘    └──────────────┘    └──────────────┘                  │
│                                                                             │
│  同步原语分配:                         同步原语回收:                          │
│  Parker::Allocate(t) → _parker        Parker::Release() → FreeList         │
│  ParkEvent::Allocate(t) → _SleepEvent  ParkEvent::Release() → FreeList     │
│  ParkEvent::Allocate(t) → _ParkEvent   (类型稳定，永不 delete)              │
│  ParkEvent::Allocate(t) → _MuxEvent                                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 9. 面试 Q&A

### Q1: LockSupport.park/unpark 和 Object.wait/notify 的区别？

**回答要点**：

它们在 HotSpot 中使用不同的底层同步原语：

1. **LockSupport.park/unpark** 使用 `Parker`（`_counter` 两态，permit 语义）
   - unpark 可以**先于** park 调用（预存许可证，下次 park 直接返回）
   - 不需要持有任何 Monitor 锁
   - 不释放已持有的 synchronized 锁

2. **Object.wait/notify** 使用 `ParkEvent`（`_event` 三态）+ ObjectMonitor
   - 必须先获取对象的 synchronized 锁
   - wait 会释放 Monitor 锁
   - notify 只能在 synchronized 块内调用

底层都是 `pthread_mutex + pthread_cond`，但协议不同。Parker 的 permit 机制更灵活，这就是为什么 `java.util.concurrent` 包全部基于 LockSupport 而不是 wait/notify。

GDB 验证：每个 JavaThread 有 1 个 Parker（176B）+ 3 个 ParkEvent（3×192B = 576B），总计 752 bytes 同步原语开销。

### Q2: 为什么 Parker 有两个 pthread_cond_t？

**回答要点**：

因为 `LockSupport.parkNanos()` 和 `LockSupport.parkUntil()` 需要不同的时钟源：

- `parkNanos(nanos)`：**相对时间**，使用 `CLOCK_MONOTONIC`（单调递增，不受 NTP 调整影响）
- `parkUntil(deadline)`：**绝对时间**，使用 `CLOCK_REALTIME`（系统时间）

`pthread_cond_timedwait()` 的超时时间必须与创建时设置的时钟源匹配。所以 Parker 初始化时创建两个 `pthread_cond_t`：
- `_cond[REL_INDEX=0]`：`condattr_setclock(CLOCK_MONOTONIC)` 
- `_cond[ABS_INDEX=1]`：默认 `CLOCK_REALTIME`

ParkEvent 只有 1 个 `pthread_cond_t`，因为它主要用于 `Object.wait(millis)` 这种明确的超时场景。

### Q3: Parker/ParkEvent 为什么永远不删除（type-stability）？

**回答要点**：

核心原因是**避免野指针访问**。

场景：线程 A 持有线程 B 的 Parker 引用 p，线程 B 退出。如果 Parker 被 delete，线程 A 调用 `p->unpark()` 就会访问已释放内存。

JVM 的解决方案：Parker/ParkEvent 是**不朽的（immortal）**——它们的析构函数被标记为 `ShouldNotReachHere()`，永远不会被调用。线程退出时只是将 Parker 归还到全局 FreeList，新线程创建时优先从 FreeList 复用。

这使得 `p->unpark()` 永远是安全的：
- 如果 Parker 仍属于线程 B → 正常唤醒
- 如果 Parker 已归还 FreeList 并被线程 C 复用 → spurious unpark，线程 C 被虚假唤醒，但 park/unpark 语义本身就允许虚假唤醒，所以是安全的

代价是内存永不回收（但 Parker 只有 176B，ParkEvent 192B，可以忽略）。

### Q4: Thread.sleep 和 LockSupport.park 的底层有什么区别？

**回答要点**：

两者使用**不同的同步原语**：
- `Thread.sleep(millis)` → `JVM_Sleep()` → `os::sleep()` → **`_SleepEvent->park(millis)`**（ParkEvent）
- `LockSupport.park()` → `Unsafe_Park()` → **`_parker->park()`**（Parker）

关键区别：
1. `sleep` 会清除中断标志并抛 `InterruptedException`；`park` 不抛异常，只是返回
2. `sleep(0)` 等价于 `Thread.yield()`（让出时间片）；`park` 没有这个特殊处理
3. `sleep` 使用 ParkEvent（三态事件），`park` 使用 Parker（两态许可证）
4. 两者都会将线程状态切换为 `_thread_blocked`（Safepoint 安全）

### Q5: JavaThread::exit 的四个阶段分别做什么？

**回答要点**：

1. **Phase 1 — Java 层清理**：处理未捕获异常 → 调用 `Thread.exit()`（最多重试 3 次，防止 Thread.stop 干扰）→ JVMTI 通知 → 设状态 `_thread_exiting`

2. **Phase 2 — 通知 join 等待者**：`ensure_join()` 锁住 Java Thread 对象 → 设 status=TERMINATED → 设 nativeThread=NULL（使 `isAlive()` 返回 false）→ `notify_all()` 唤醒所有 `join()` 等待者

3. **Phase 3 — Native 资源清理**：释放持有的 Monitor → JFR 通知 → 释放 JNI Handle Block → 移除栈保护页 → 归还 TLAB → JVMTI 清理 → G1 屏障清理（冲刷 SATB buffer + dirty card queue）

4. **Phase 4 — 从全局列表移除**：`Threads::remove()` → 回收 ObjectMonitor → SMR 安全移除 → 从链表删除 → 递减线程计数 → 如果只剩 1 个非 daemon 线程则唤醒 `DestroyJavaVM` → 设最终状态 `_thread_terminated`

GDB 验证：main 线程的 exit 被调用两次——第一次 jni_detach（JavaMain 中 DetachCurrentThread），第二次 normal_exit + destroy_vm（Threads::destroy_vm）。

### Q6: Thread.join() 的底层实现原理是什么？

**回答要点**：

`Thread.join()` 的实现非常巧妙——它利用了 **Java Thread 对象本身的 Monitor**：

```java
// Java 层
public final synchronized void join(long millis) {
    while (isAlive()) {
        wait(millis);  // 等待在 Thread 对象的 Monitor 上
    }
}
```

底层唤醒发生在 `ensure_join()` 中：
1. `ObjectLocker` 锁住 Java Thread 对象（等同于 `synchronized(threadObj)`）
2. `set_thread(NULL)` → `isAlive()` 返回 false
3. `notify_all()` → 唤醒所有在 `threadObj.wait()` 上等待的线程

当被唤醒的线程重新检查 `isAlive()` 时，因为 native 线程引用已被清除，`isAlive()` 返回 false，循环退出，`join()` 返回。

### Q7: 线程退出时 G1 的 on_thread_detach 做了什么？

**回答要点**：

`BarrierSet::barrier_set()->on_thread_detach(this)` 对 G1 来说非常重要：

1. **冲刷 SATB Mark Queue**：线程在并发标记期间积累的 SATB（Snapshot-At-The-Beginning）引用需要被并发标记处理
2. **冲刷 Dirty Card Queue**：线程写屏障产生的脏卡引用需要被 Refinement 线程处理

如果不做这一步，这些 GC 相关的缓冲区数据就会丢失，导致：
- SATB 漏标：并发标记可能遗漏存活对象
- 脏卡丢失：跨 Region 引用可能不被记录到 RememberedSet

---

## 10. GDB 验证脚本

### 10.1 Parker/ParkEvent 数据结构验证

```gdb
# 文件: jvm-md/tmp-file/parker-exit/gdb_exit2.txt

set pagination off
set print pretty on

b JavaThread::exit
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

printf "\n--- Parker ---\n"
printf "parker: %p, _counter: %d, _cur_index: %d\n", this->_parker, this->_parker->_counter, this->_parker->_cur_index

printf "\n--- ParkEvent ---\n"
printf "SleepEvent: %p, _event: %d\n", this->_SleepEvent, this->_SleepEvent->_event
printf "ParkEvent: %p, _event: %d\n", this->_ParkEvent, this->_ParkEvent->_event
printf "MuxEvent: %p\n", this->_MuxEvent

printf "\n--- sizeof ---\n"
printf "sizeof(Parker)=%lu sizeof(ParkEvent)=%lu\n", sizeof(Parker), sizeof(ParkEvent)
printf "sizeof(PlatformParker)=%lu sizeof(PlatformEvent)=%lu\n", sizeof(os::PlatformParker), sizeof(os::PlatformEvent)
printf "sizeof(pthread_mutex_t)=%lu sizeof(pthread_cond_t)=%lu\n", sizeof(pthread_mutex_t), sizeof(pthread_cond_t)

delete breakpoints
c
quit
```

---

## 11. 源码索引

| 文件 | 路径 | 关键内容 |
|------|------|---------|
| park.hpp | `runtime/park.hpp` | Parker/ParkEvent 类定义 |
| park.cpp | `runtime/park.cpp` | Parker::Allocate/Release, ParkEvent::Allocate/Release, 空闲列表 |
| os_posix.hpp | `os/posix/os_posix.hpp:170` | PlatformEvent 定义（pthread 字段） |
| os_posix.hpp | `os/posix/os_posix.hpp:205` | PlatformParker 定义（2 个 cond） |
| os_posix.cpp | `os/posix/os_posix.cpp:2158` | Parker::park() POSIX 实现 |
| os_posix.cpp | `os/posix/os_posix.cpp:2256` | Parker::unpark() POSIX 实现 |
| os_posix.cpp | `os/posix/os_posix.cpp:1996` | PlatformEvent::park() 实现 |
| os_posix.cpp | `os/posix/os_posix.cpp:2104` | PlatformEvent::unpark() 实现 |
| unsafe.cpp | `prims/unsafe.cpp:939` | Unsafe_Park / Unsafe_Unpark JNI 入口 |
| jvm.cpp | `prims/jvm.cpp:3123` | JVM_Sleep 实现 |
| thread.cpp | `runtime/thread.cpp:1986` | ensure_join() — join 通知 |
| thread.cpp | `runtime/thread.cpp:2009` | JavaThread::exit() — 4 阶段退出 |
| thread.cpp | `runtime/thread.cpp:4708` | Threads::remove() — 全局列表移除 |
| thread.hpp | `runtime/thread.hpp:858` | WorkerThread 基类定义 |

---

*最后更新: 2026-02-09*
*GDB 验证环境: OpenJDK 11, -Xms8g -Xmx8g -XX:+UseG1GC, 16 核*
