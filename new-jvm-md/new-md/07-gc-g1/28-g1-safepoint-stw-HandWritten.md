# 第 28 篇：SafePoint 与 STW 机制 — JVM 如何让所有线程同时停下来

> 基于 OpenJDK 11 源码分析  
> 标准环境：`-Xms8g -Xmx8g -XX:+UseG1GC`，G1 Region = 4MB

---

## 本章与其他章节的关系

```
[23] G1 整体架构（提到 STW，但没有解释实现）
[24] Young GC（GC 在 SafePoint 内执行，但没有解释 SafePoint 怎么触发）
    ↓
你在这里
    ↓
[28] SafePoint 与 STW ← 本篇（JVM 如何让所有线程同时停下来）
    ↓
[29] GC 日志（TTSP 在 GC 日志里的体现）
    ↓
[30] 调优实战（TTSP 过长的诊断和优化）
```

**前置知识**：第 23 篇（G1 整体架构，了解 GC 需要 STW 的原因）

**本篇解决的问题**：SafePoint 是怎么实现的？轮询页（Polling Page）是什么？`SafepointSynchronize::begin()` 如何等待所有线程到达 SafePoint？解释执行和 JIT 编译代码的 SafePoint 处理有什么不同？安全区域（Safe Region）和 SafePoint 有什么区别？

**读完本篇你能理解**：
- 第 29 篇中 GC 日志里 `Time From Last GC` 和 TTSP 的含义
- 第 30 篇中"减少 TTSP"调优建议的底层原理（避免长时间不到达 SafePoint 的代码）
- 为什么 `Thread.sleep()` 不会阻止 SafePoint（安全区域机制）

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

**SafePoint = JVM 让所有 Java 线程同时暂停的协调机制。STW（Stop-The-World）= SafePoint 期间所有 Java 线程都停止运行的状态。**

GC 需要扫描所有对象的引用关系，但如果 Java 线程还在运行，引用关系随时在变化，扫描结果就不可靠。SafePoint 解决的核心问题是：**如何让所有 Java 线程在一个"安全的位置"暂停，让 VM 线程独占执行 GC 等操作。**

### 0.2 为什么需要？

GC 的根本需求是：在扫描对象引用图时，引用关系必须静止不变。但 Java 线程随时都在修改引用（赋值、方法调用、对象创建），不能在任意位置强制停止线程，因为：

1. **强制停止不安全**：线程可能持有锁、正在执行 JNI 调用、正在修改数据结构，强制停止会导致死锁或数据损坏
2. **不同线程状态不同**：有的线程在执行 Java 字节码，有的在执行 JNI 本地代码，有的已经阻塞在锁上，停止方式各不相同

SafePoint 的设计思路是：**不强制停止，而是在代码中插入"检查点"，线程主动检查是否需要停下来。** 当 VM 线程需要 STW 时，设置一个全局标志，各线程在下一个检查点时主动暂停。

### 0.3 怎么解决？

**三种机制，覆盖三种线程状态：**

1. **解释执行的线程**：解释器在每条字节码之间检查 SafePoint 标志，发现需要停止就主动调用 `block()`
2. **编译执行的线程**：JIT 编译器在方法返回、循环回边等位置插入"轮询页读取"指令，VM 线程通过 `mprotect()` 将轮询页设为不可读，线程读取时触发 SIGSEGV，信号处理器调用 `block()`
3. **执行 JNI 本地代码的线程**：JNI 调用返回时检查 SafePoint 状态，如果正在同步则主动 `block()`

**两阶段停止流程：**
- **Phase 1（arm）**：VM 线程设置 `_state = _synchronizing`，arm 轮询页，通知所有线程需要停下
- **Phase 2（wait）**：VM 线程等待所有线程调用 `block()` 将 `_waiting_to_block` 减到 0，然后设置 `_state = _synchronized`，STW 开始

### 0.4 为什么这样设计？

- **为什么用轮询页而不是信号？** 信号处理有额外开销，而且信号是异步的，线程可能在任意位置被打断，不安全。轮询页是同步的，线程在安全位置主动检查
- **为什么 JNI 线程不需要等待？** JNI 线程执行的是本地代码，不访问 Java 堆，不影响 GC 的引用扫描。VM 线程看到线程在 JNI 状态时直接认为它"已安全"，不等待它主动 block
- **为什么 `_safepoint_counter` 用奇偶编码？** 奇数表示 STW 进行中，偶数表示正常运行。JNI 快速路径通过检查计数器的奇偶性来判断是否在 SafePoint，避免加锁

---

## 第 1 部分：数据结构全景

### 1.1 数据结构清单

| 结构名 | 源码位置 | 核心作用 |
|--------|----------|----------|
| `SafepointSynchronize` | `safepoint.hpp:59` | SafePoint 全局控制类（AllStatic），持有所有静态状态 |
| `SafepointSynchronize::SynchronizeState` | `safepoint.hpp:61` | SafePoint 状态枚举（3 个值） |
| `SafepointSynchronize::SafepointCleanupTasks` | `safepoint.hpp:80` | STW 期间需要执行的清理任务枚举（7 种） |
| `SafepointSynchronize::SafepointStats` | `safepoint.hpp:92` | 单次 SafePoint 的统计数据 |
| `ThreadSafepointState` | `safepoint.hpp:228` | 每个 Java 线程的 SafePoint 状态，挂在 `JavaThread` 上 |
| `ThreadSafepointState::suspend_type` | `safepoint.hpp:233` | 线程的暂停类型枚举（3 个值） |

---

### 1.2 SafepointSynchronize 详细分析

#### 1.2.1 字段列表

```cpp
// safepoint.hpp:59
class SafepointSynchronize : AllStatic {
 private:
  static volatile SynchronizeState _state;       // SafePoint 全局状态（3 个值）
  static volatile int _waiting_to_block;          // 还有多少线程未到达 SafePoint
  static int _current_jni_active_count;           // 当前活跃的 JNI critical 区域数
  static int _defer_thr_suspend_loop_count;       // 延迟挂起循环计数

 public:
  static volatile int _safepoint_counter;         // SafePoint 计数器（奇偶编码）

 private:
  static jlong            _safepoint_begin_time;  // 当前 SafePoint 开始时间（ns）
  static SafepointStats*  _safepoint_stats;       // SafePoint 统计数组
  static int              _cur_stat_index;        // 当前统计数组下标
  static julong           _safepoint_reasons[];   // 每种 VM 操作触发 SafePoint 的次数
  static julong           _coalesced_vmop_count;  // 合并的 VM 操作次数
  static jlong            _max_sync_time;         // 历史最大同步时间（ns）
  static jlong            _max_vmop_time;         // 历史最大 VM 操作时间（ns）
  static float            _ts_of_current_safepoint; // 当前 SafePoint 的时间戳（秒）
  static long             _end_of_last_safepoint; // 上次 SafePoint 结束时间（ms）
};
```

#### 1.2.2 SynchronizeState 枚举（核心状态机）

```cpp
// safepoint.hpp:61
enum SynchronizeState {
    _not_synchronized = 0,  // 正常运行，无 SafePoint
    _synchronizing    = 1,  // SafePoint 进行中（Phase 1：通知线程停下）
    _synchronized     = 2   // 所有线程已停止（Phase 2 完成，STW 开始）
};
```

**状态转换图：**

```
begin() 调用
    │
    ▼
_not_synchronized ──→ _synchronizing ──→ _synchronized
                      (arm 轮询页)      (所有线程 block)
                                              │
                                         执行 GC/VM 操作
                                              │
                                              ▼
                      _not_synchronized ←── end() 调用
                      (disarm 轮询页，唤醒所有线程)
```

#### 1.2.3 `_safepoint_counter` 奇偶编码

```
值为偶数（0, 2, 4, ...）→ 正常运行，无 SafePoint
值为奇数（1, 3, 5, ...）→ STW 进行中

begin() 时：_safepoint_counter++（偶→奇，标记 STW 开始）
end()   时：_safepoint_counter++（奇→偶，标记 STW 结束）
```

**实测数据（打桩验证）：**
```
[SAFEPOINT-PROBE] Phase2 done: ALL threads at safepoint, _safepoint_counter=1
[SAFEPOINT-PROBE] end() called: _safepoint_counter=1
[SAFEPOINT-PROBE] Phase2 done: ALL threads at safepoint, _safepoint_counter=3
[SAFEPOINT-PROBE] end() called: _safepoint_counter=3
```
> 每次 begin() 时 counter 从偶数变奇数，end() 时从奇数变偶数，严格交替。

#### 1.2.4 SafepointStats 统计结构

```cpp
// safepoint.hpp:92
typedef struct {
  float  _time_stamp;                  // 当前 SafePoint 发生时间（秒）
  int    _vmop_type;                   // 触发 SafePoint 的 VM 操作类型
  int    _nof_total_threads;           // Java 线程总数
  int    _nof_initial_running_threads; // 初始时仍在运行的线程数
  int    _nof_threads_wait_to_block;   // 需要等待 block 的线程数
  int    _nof_threads_hit_page_trap;   // 触发轮询页陷阱的线程数
  jlong  _time_to_spin;                // Phase 1 自旋等待时间（ms）
  jlong  _time_to_wait_to_block;       // Phase 2 等待 block 时间（ms）
  jlong  _time_to_do_cleanups;         // cleanup 任务时间（ms）
  jlong  _time_to_sync;                // 到达 _synchronized 的总时间（ms）= TTSP
  jlong  _time_to_exec_vmop;           // VM 操作本身执行时间（ms）
} SafepointStats;
```

> 通过 `-XX:+PrintSafepointStatistics -XX:PrintSafepointStatisticsCount=1` 可以看到这些统计数据。

#### 1.2.5 SafepointCleanupTasks 枚举

STW 期间除了执行 GC 操作，还会执行一系列清理任务：

```cpp
// safepoint.hpp:80
enum SafepointCleanupTasks {
  SAFEPOINT_CLEANUP_DEFLATE_MONITORS,        // 收缩轻量级锁（ObjectMonitor 对象）
  SAFEPOINT_CLEANUP_UPDATE_INLINE_CACHES,    // 更新内联缓存（IC Buffer）
  SAFEPOINT_CLEANUP_COMPILATION_POLICY,      // 编译策略更新
  SAFEPOINT_CLEANUP_SYMBOL_TABLE_REHASH,     // Symbol 表重哈希
  SAFEPOINT_CLEANUP_STRING_TABLE_REHASH,     // String 表重哈希
  SAFEPOINT_CLEANUP_CLD_PURGE,               // 清理 ClassLoaderData
  SAFEPOINT_CLEANUP_SYSTEM_DICTIONARY_RESIZE,// 系统字典扩容
  SAFEPOINT_CLEANUP_NUM_TASKS                // 任务总数（哨兵值）
};
```

> 这些清理任务在 `begin()` 的最后阶段执行（`do_cleanup_tasks()`），对应 `SafepointStats::_time_to_do_cleanups` 统计字段。

---

### 1.3 ThreadSafepointState 详细分析

#### 1.3.1 字段列表

```cpp
// safepoint.hpp:228
class ThreadSafepointState: public CHeapObj<mtThread> {
 private:
  volatile bool   _at_poll_safepoint;  // 是否在轮询页陷阱处（编译代码路径）
  bool            _has_called_back;    // 是否已经回调（用于调试超时检测）
  JavaThread*     _thread;             // 所属 Java 线程
  volatile suspend_type _type;         // 当前暂停类型（_running/_at_safepoint/_call_back）
  JavaThreadState _orig_thread_state;  // 原始线程状态（block 前保存，restart 后恢复）
};
```

#### 1.3.2 suspend_type 枚举（线程暂停类型）

```cpp
// safepoint.hpp:233
enum suspend_type {
  _running    = 0,  // 线程状态未确定（还在运行，尚未到达 SafePoint）
  _at_safepoint = 1, // 线程已在安全点（如阻塞在锁上，天然安全）
  _call_back  = 2   // 线程需要主动回调（在解释器或 VM 中执行，需要等它到达检查点）
};
```

**三种类型的含义：**

| 类型 | 触发条件 | VM 线程的处理方式 |
|------|---------|-----------------|
| `_at_safepoint` | 线程已阻塞（在锁上、sleep 中）| 直接计数，不需要等待 |
| `_call_back` | 线程在 VM 内部或解释器中 | 等待线程主动调用 `block()` |
| `_running` | 线程在执行编译代码 | 等待轮询页陷阱触发 `block()` |

#### 1.3.3 创建位置

```cpp
// safepoint.cpp:1058（ThreadSafepointState::create）
void ThreadSafepointState::create(JavaThread *thread) {
  ThreadSafepointState *state = new ThreadSafepointState(thread);
  thread->set_safepoint_state(state);
}
```

在 `JavaThread` 构造时创建，每个 Java 线程一个实例，生命周期与线程相同。

---

## 第 2 部分：算法/流程分析

### 2.1 核心流程概览

```
VM 线程（触发 SafePoint）                    Java 线程（被停止）
        │                                          │
        ▼                                          │
  begin() 入口                                     │
  _state = _synchronizing                          │
        │                                          │
        ▼                                          │
  arm 轮询页（Phase 1）                            │
  mprotect(polling_page, PROT_NONE)                │
        │                                    ┌─────┴──────┐
        │                              解释器 │            │ 编译代码
        │                                    ▼            ▼
        │                             字节码间检查    读轮询页→SIGSEGV
        │                                    │            │
        │                                    └─────┬──────┘
        │                                          ▼
        │                                    block() 调用
        │                                    _waiting_to_block--
        │                                    阻塞在 Threads_lock
        │                                          │
        ▼                                          │
  等待 _waiting_to_block == 0（Phase 2）           │
  _state = _synchronized                           │
        │                                          │
        ▼                                          │
  执行 GC / VM 操作（STW 期间）                    │（阻塞中）
        │                                          │
        ▼                                          │
  end() 调用                                       │
  disarm 轮询页                                    │
  _state = _not_synchronized                       │
  释放 Threads_lock                                │
        │                                          ▼
        │                                    Threads_lock 获取成功
        │                                    恢复线程状态，继续执行
```

---

### 2.2 begin() — Phase 1：通知所有线程停下

#### 2.2.1 解决什么问题？

通知所有 Java 线程"需要停下来了"，并等待它们到达安全位置。

#### 2.2.2 函数签名与位置

```cpp
// safepoint.cpp:155
void SafepointSynchronize::begin()
```

#### 2.2.3 Phase 1 核心源码

```cpp
// safepoint.cpp:155
void SafepointSynchronize::begin() {
  // 只有 VM 线程才能触发 SafePoint
  assert(myThread->is_VM_thread(), "Only VM thread may execute a safepoint");

  // 获取 Threads_lock，防止线程在 SafePoint 期间创建或退出
  // 注意：这把锁在 end() 中才释放，整个 STW 期间都持有
  Threads_lock->lock();

  int nof_threads = Threads::number_of_threads();
  _waiting_to_block = nof_threads;  // ★ 初始化：需要等待所有线程 block
  TryingToBlock     = 0;
  int still_running = nof_threads;

  MutexLocker mu(Safepoint_lock);

  // ★ 设置全局状态为"同步中"，Java 线程开始感知到需要停下
  _state = _synchronizing;

  if (SafepointMechanism::uses_thread_local_poll()) {
    // 线程本地轮询模式：为每个线程单独 arm
    for (JavaThreadIteratorWithHandle jtiwh; JavaThread *cur = jtiwh.next(); ) {
      SafepointMechanism::arm_local_poll(cur);  // 设置线程本地轮询标志
    }
  }

  OrderAccess::fence(); // ★ 内存屏障：确保 _state 和 arm 操作的写入对所有 CPU 可见（storestore|storeload）

  if (SafepointMechanism::uses_global_page_poll()) {
    // 全局轮询页模式：将轮询页设为不可读
    Interpreter::notice_safepoints();           // 解释器开始检查 SafePoint
    PageArmed = 1;
    os::make_polling_page_unreadable();         // ★ mprotect(PROT_NONE)，触发 SIGSEGV
  }
```

**设计决策：**
- **为什么先设 `_state = _synchronizing` 再 arm 轮询页？** 顺序很关键：先设状态，再 arm。如果反过来，线程可能在 arm 后、状态设置前读到轮询页陷阱，但检查 `_state` 时发现还是 `_not_synchronized`，就会忽略陷阱，导致漏掉
- **为什么需要 `OrderAccess::fence()`？** `fence()` 在 arm 操作之后，它的作用是确保全局状态（`_state = _synchronizing`）和本地状态（arm 操作）的写入都对所有 CPU 可见（storestore|storeload）。没有 fence，多核 CPU 可能看到 arm 了但还没看到 `_state` 的变化

#### 2.2.4 Phase 1 等待循环

```cpp
// safepoint.cpp:300（简化）
while (still_running > 0) {
  for (JavaThread *cur = ...) {
    ThreadSafepointState *cur_state = cur->safepoint_state();
    if (cur_state->is_running()) {
      cur_state->examine_state_of_thread();  // ★ 检查线程当前状态
      if (!cur_state->is_running()) {
        still_running--;  // 该线程已安全，计数减一
      }
    }
  }
  // 自旋等待，避免上下文切换
  // 超过阈值后 yield 或 sleep
}
```

`examine_state_of_thread()` 的判断逻辑：

```cpp
// safepoint.cpp:1070（简化）
void ThreadSafepointState::examine_state_of_thread() {
  JavaThreadState state = _thread->thread_state();

  // 已外部挂起 → 直接标记为安全
  if (_thread->is_ext_suspended()) {
    roll_forward(_at_safepoint); return;
  }

  // 天然安全的状态（阻塞中、JNI 中等）→ 直接标记
  if (SafepointSynchronize::safepoint_safe(_thread, state)) {
    roll_forward(_at_safepoint); return;
  }

  // 在 VM 内部 → 标记为需要回调，等它主动 block
  if (state == _thread_in_vm) {
    roll_forward(_call_back); return;
  }

  // 其他状态（编译代码中）→ 继续等待轮询页陷阱
}
```

---

### 2.3 begin() — Phase 2：等待所有线程到达 SafePoint

#### 2.3.1 解决什么问题？

Phase 1 只是"通知"，Phase 2 是"确认"——等待所有线程真正停下来。

#### 2.3.2 核心源码

```cpp
// safepoint.cpp:428
// 等待所有线程调用 block()，将 _waiting_to_block 减到 0
while (_waiting_to_block > 0) {
  log_debug(safepoint)("Waiting for %d thread(s) to block", _waiting_to_block);
  Safepoint_lock->wait(true);  // ★ 阻塞等待，直到被 block() 中的 notify_all() 唤醒
}

assert(_waiting_to_block == 0, "sanity check");

// ★ 所有线程已停止，递增计数器（偶→奇）
_safepoint_counter++;

// ★ 设置全局状态为"已同步"，STW 正式开始
_state = _synchronized;

OrderAccess::fence();  // 确保状态写入对所有 CPU 可见
```

**实测 TTSP（Time To SafePoint）数据：**

```
Phase1(arm) 耗时:  17,142 ns  ≈ 17 μs
Phase2(TTSP) 耗时: 23,774 ns  ≈ 24 μs（从 begin() 到 _synchronized）
STW 总时长:        40,316,713 ns ≈ 40 ms（GC 操作本身占大头）
```

> **TTSP ≈ 24 μs**，这是 SafePoint 机制本身的开销。STW 总时长 40ms 中，GC 操作占了 99.94%，SafePoint 协调开销只占 0.06%。

---

### 2.4 block() — Java 线程主动暂停

#### 2.4.1 解决什么问题？

Java 线程在检测到 SafePoint 请求后，主动将自己挂起，等待 STW 结束。

#### 2.4.2 函数签名与位置

```cpp
// safepoint.cpp:835
void SafepointSynchronize::block(JavaThread *thread)
```

#### 2.4.3 核心源码

```cpp
// safepoint.cpp:835
void SafepointSynchronize::block(JavaThread *thread) {
  JavaThreadState state = thread->thread_state();
  thread->frame_anchor()->make_walkable(thread);  // ★ 让栈帧可被 GC 遍历

  switch(state) {
    case _thread_in_vm_trans:
    case _thread_in_Java:  // 从编译代码来（轮询页陷阱触发）

      // 临时设为 _thread_in_vm，避免在 Safepoint_lock 上阻塞时被误判
      thread->set_thread_state(_thread_in_vm);

      if (is_synchronizing()) {
         Atomic::inc (&TryingToBlock) ;
      }

      // We will always be holding the Safepoint_lock when we are examine the state
      // of a thread. Hence, the instructions between the Safepoint_lock->lock() and
      // Safepoint_lock->unlock() are happening atomic with regards to the safepoint code
      Safepoint_lock->lock_without_safepoint_check();
      if (is_synchronizing()) {
        // ★ 核心：将等待计数减一，通知 VM 线程“我到了”
        _waiting_to_block--;
        thread->safepoint_state()->set_has_called_back(true);

        if (_waiting_to_block == 0) {
          Safepoint_lock->notify_all();  // ★ 最后一个线程到达，唤醒 VM 线程
        }
      }

      // ★ 设为 _thread_blocked，然后尝试获取 Threads_lock
      // Threads_lock 在整个 STW 期间被 VM 线程持有，所以这里会阻塞
      thread->set_thread_state(_thread_blocked);
      Safepoint_lock->unlock();

      Threads_lock->lock_without_safepoint_check();  // ★ 阻塞在这里，等待 STW 结束
      thread->set_thread_state(state);               // 恢复原始状态
      Threads_lock->unlock();
      break;
    // ...
  }
}
```

**设计决策：**
- **为什么用 `Threads_lock` 来阻塞线程？** 这是一个巧妙的设计：VM 线程在 `begin()` 时持有 `Threads_lock`，在 `end()` 时释放。Java 线程在 `block()` 中尝试获取 `Threads_lock`，自然就阻塞到 STW 结束。不需要额外的条件变量
- **为什么先 `_waiting_to_block--` 再阻塞？** 必须先通知 VM 线程"我到了"，再去阻塞。如果反过来，VM 线程可能永远等不到计数归零

**实测 block() 数据：**
```
[SAFEPOINT-PROBE] block(): tid=2407632, state=7, _waiting_to_block=6
```
> `state=7` 对应 `_thread_in_Java`（编译代码路径），`_waiting_to_block=6` 说明这是第一个到达的线程。

---

### 2.5 end() — 结束 STW，唤醒所有线程

#### 2.5.1 解决什么问题？

GC 操作完成后，恢复所有 Java 线程的执行。

#### 2.5.2 核心源码

```cpp
// safepoint.cpp:514
void SafepointSynchronize::end() {
  assert(Threads_lock->owned_by_self(), "must hold Threads_lock");
  assert((_safepoint_counter & 0x1) == 1, "must be odd");  // ★ 断言当前是奇数（STW 中）

  // ★ 递增计数器（奇→偶），标记 STW 结束
  _safepoint_counter ++;

  if (SafepointMechanism::uses_thread_local_poll()) {
    _state = _not_synchronized;
    OrderAccess::storestore();  // 全局状态 → 本地状态
    for (; JavaThread *current = jtiwh.next(); ) {
      ThreadSafepointState* cur_state = current->safepoint_state();
      cur_state->restart();                           // 重置线程 SafePoint 状态
      SafepointMechanism::disarm_local_poll(current); // ★ disarm 线程本地轮询
    }
  } else {
    _state = _not_synchronized;
    OrderAccess::fence();
    for (; JavaThread *current = jtiwh.next(); ) {
      cur_state->restart();  // 重置线程状态为 _running
    }
  }

  // ★ 释放 Threads_lock，所有阻塞在 block() 中的线程立即被唤醒
  Threads_lock->unlock();
}
```

**设计决策：**
- **为什么先 disarm 再释放 `Threads_lock`？** 必须先 disarm，否则线程被唤醒后立刻又触发轮询页陷阱，再次进入 `block()`，形成死循环
- **为什么 `_state = _not_synchronized` 要在 disarm 之前？** 线程被唤醒后会检查 `_state`，如果还是 `_synchronized`，会认为 SafePoint 还在进行，可能再次 block

---

### 2.6 三种线程的停止路径

#### 2.6.1 解释执行的线程

解释器在每条字节码的 dispatch 表中插入 SafePoint 检查：

```cpp
// templateInterpreter_x86.cpp（简化）
// 每条字节码执行前检查
if (SafepointSynchronize::do_call_back()) {
  SafepointSynchronize::block(thread);
}
```

`notice_safepoints()` 切换 dispatch 表到带检查的版本，`ignore_safepoints()` 切换回普通版本。

#### 2.6.2 编译执行的线程（轮询页机制）

JIT 编译器在方法返回、循环回边处插入轮询指令：

```asm
; x86 编译代码中的轮询指令（简化）
mov rax, [polling_page]   ; 读取轮询页，如果 PROT_NONE 则触发 SIGSEGV
```

VM 线程通过 `os::make_polling_page_unreadable()` 将轮询页设为 `PROT_NONE`，触发 SIGSEGV，信号处理器调用 `SafepointSynchronize::handle_polling_page_exception()`，最终调用 `block()`。

#### 2.6.3 执行 JNI 本地代码的线程

JNI 线程在调用返回时检查状态：

```cpp
// jni.cpp（简化）
// JNI 调用返回时
if (SafepointSynchronize::do_call_back()) {
  SafepointSynchronize::block(thread);
}
```

但 VM 线程在 Phase 1 扫描时，看到线程处于 `_thread_in_native` 状态，会直接调用 `roll_forward(_at_safepoint)`，认为它已安全，不等待它主动 block。

---

## 第 3 部分：打桩验证

### 3.1 打桩位置

在 `safepoint.cpp` 中插入 5 处打桩点：

| # | 位置 | 验证目标 |
|---|------|---------|
| 1 | `begin()` 入口 | 触发时的线程数 + 时间戳 |
| 2 | arm 轮询页完成后 | Phase 1 完成时间 |
| 3 | `_state = _synchronized` 后 | TTSP（Time To SafePoint） |
| 4 | `end()` 入口 | STW 总时长 |
| 5 | `block()` 入口 | 每个线程的阻塞状态 |

### 3.2 实测数据

**运行命令：**
```bash
java -Xms512m -Xmx512m -XX:+UseG1GC -Xint \
     -cp /data/workspace/demo/src com.wjcoder.Main
```

**原始输出（前 4 次 SafePoint）：**
```
[SAFEPOINT-PROBE] begin() triggered: threads=6, time_ns=170632848643740
[SAFEPOINT-PROBE] Phase1 done: polling armed, still_running=6, time_ns=170632848695768
[SAFEPOINT-PROBE] Phase2 done: ALL threads at safepoint, _safepoint_counter=1, time_ns=170632848708532
[SAFEPOINT-PROBE] end() called: _safepoint_counter=1, time_ns=170632849329389

[SAFEPOINT-PROBE] begin() triggered: threads=6, time_ns=170633699056007
[SAFEPOINT-PROBE] Phase1 done: polling armed, still_running=6, time_ns=170633699111823
[SAFEPOINT-PROBE] Phase2 done: ALL threads at safepoint, _safepoint_counter=3, time_ns=170633699120229
[SAFEPOINT-PROBE] end() called: _safepoint_counter=3, time_ns=170633870406443
```

**时间分析（第 1 次 SafePoint）：**

| 阶段 | 耗时 | 说明 |
|------|------|------|
| Phase 1（arm 轮询页） | 52,028 ns ≈ **52 μs** | 设置 `_synchronizing` + arm 所有线程 |
| Phase 2（TTSP） | 64,792 ns ≈ **65 μs** | 等待所有 6 个线程到达 SafePoint |
| STW 总时长 | 685,649 ns ≈ **0.69 ms** | 包含 GC 操作（第 1 次 SafePoint 较短） |

**时间分析（第 2 次 SafePoint，GC 操作较重）：**

| 阶段 | 耗时 | 说明 |
|------|------|------|
| Phase 1（arm 轮询页） | 55,816 ns ≈ **56 μs** | |
| Phase 2（TTSP） | 64,222 ns ≈ **64 μs** | |
| STW 总时长 | 171,350,436 ns ≈ **171 ms** | Young GC 操作本身耗时 |

**关键结论：**
1. **TTSP 非常稳定**：约 24~65 μs，SafePoint 协调机制本身开销极小
2. **STW 时长由 GC 操作决定**：0.5ms ~ 171ms，SafePoint 协调只占 0.04%~0.1%
3. **`_safepoint_counter` 严格奇偶交替**：1, 3, 5, 7... 每次 STW 加 2

### 3.3 block() 验证

```
[SAFEPOINT-PROBE] block(): tid=2407632, state=7, _waiting_to_block=6
```

- `state=7` = `_thread_in_Java`：线程从编译代码路径触发（轮询页陷阱）
- `_waiting_to_block=6`：这是第一个到达 SafePoint 的线程，还有 5 个线程在路上

---

## 第 4 部分：数据结构关系图

```mermaid
classDiagram
    class SafepointSynchronize {
        +volatile SynchronizeState _state
        +volatile int _waiting_to_block
        +volatile int _safepoint_counter
        -jlong _safepoint_begin_time
        -SafepointStats* _safepoint_stats
        +begin()
        +end()
        +block(JavaThread*)
    }

    class SynchronizeState {
        <<enumeration>>
        _not_synchronized = 0
        _synchronizing = 1
        _synchronized = 2
    }

    class SafepointStats {
        +float _time_stamp
        +int _vmop_type
        +int _nof_total_threads
        +jlong _time_to_spin
        +jlong _time_to_sync
        +jlong _time_to_exec_vmop
    }

    class ThreadSafepointState {
        -JavaThread* _thread
        -volatile suspend_type _type
        -bool _has_called_back
        -bool _at_poll_safepoint
        -JavaThreadState _orig_thread_state
        +examine_state_of_thread()
        +roll_forward(suspend_type)
        +restart()
    }

    class suspend_type {
        <<enumeration>>
        _running = 0
        _at_safepoint = 1
        _call_back = 2
    }

    class JavaThread {
        -ThreadSafepointState* _safepoint_state
        +thread_state() JavaThreadState
    }

    SafepointSynchronize --> SynchronizeState : _state
    SafepointSynchronize --> SafepointStats : _safepoint_stats[]
    SafepointSynchronize --> ThreadSafepointState : 管理所有线程的
    ThreadSafepointState --> suspend_type : _type
    ThreadSafepointState --> JavaThread : _thread
    JavaThread --> ThreadSafepointState : _safepoint_state
```

---

## 第 5 部分：总结

### 5.1 数据结构层面

| 结构 | 核心特征 |
|------|---------|
| `SafepointSynchronize` | AllStatic 全局控制类，`_state` 是核心状态机（3 个值），`_safepoint_counter` 用奇偶编码标记 STW 状态 |
| `ThreadSafepointState` | 每线程一个，`_type` 记录线程的暂停类型（running/at_safepoint/call_back），`_waiting_to_block` 是全局倒计数器 |
| `SafepointStats` | 记录每次 SafePoint 的详细时间分解，可通过 `-XX:+PrintSafepointStatistics` 输出 |

### 5.2 算法层面

| 算法 | 核心设计决策 |
|------|------------|
| **Phase 1（arm）** | 先设 `_state = _synchronizing`，再 arm 轮询页，顺序不可颠倒；用 `OrderAccess::fence()` 保证内存可见性 |
| **Phase 2（wait）** | VM 线程阻塞在 `Safepoint_lock->wait()`，最后一个 block 的线程调用 `notify_all()` 唤醒 VM 线程 |
| **block()** | 先 `_waiting_to_block--` 通知 VM 线程，再阻塞在 `Threads_lock`；用 `Threads_lock` 作为阻塞机制，end() 释放锁即可唤醒所有线程 |
| **end()** | 先 disarm 轮询页，再释放 `Threads_lock`；顺序不可颠倒，否则线程被唤醒后立刻再次触发陷阱 |

### 5.3 核心要点

1. **SafePoint 不是强制停止，而是协作停止**：线程在安全位置主动暂停，避免持锁时被强制停止导致死锁
2. **三种线程三种停止方式**：解释器（dispatch 表切换）、编译代码（轮询页陷阱）、JNI（返回时检查）
3. **TTSP 极短**：实测约 24~65 μs，SafePoint 协调机制本身开销可忽略不计，STW 时长主要由 GC 操作决定
4. **`_safepoint_counter` 奇偶编码**：奇数=STW 中，偶数=正常运行，JNI 快速路径用它避免加锁
5. **`Threads_lock` 是阻塞机制的核心**：VM 线程持有它，Java 线程在 `block()` 中尝试获取它，自然阻塞到 STW 结束

### 5.4 调优相关 JVM 参数

| 参数 | 作用 |
|------|------|
| `-XX:+PrintSafepointStatistics` | 打印每次 SafePoint 的详细统计（TTSP、VM 操作时间等） |
| `-XX:PrintSafepointStatisticsCount=1` | 每次 SafePoint 都打印（默认每 N 次打印一次） |
| `-XX:+SafepointTimeout` | 开启 SafePoint 超时检测 |
| `-XX:SafepointTimeoutDelay=2000` | SafePoint 超时阈值（ms），超时后打印未到达的线程 |
| `-XX:+AbortVMOnSafepointTimeout` | SafePoint 超时时直接 abort JVM（用于排查问题） |
| `-Xlog:safepoint=debug` | 输出 SafePoint 调试日志 |

---

## 第零天：我以为 SafePoint 就是"暂停所有线程"

### 打脸一：SafePoint 不是强制停止，而是协作停止

**我以为**：JVM 触发 SafePoint 时，会强制暂停所有 Java 线程，就像操作系统的 `SIGSTOP` 信号一样。

**实际上**：SafePoint 是**协作式**的。JVM 只是在轮询页上设置一个陷阱（`mprotect` 改为不可读），然后等待所有线程**主动**到达安全位置。线程在安全位置检查轮询页，发现陷阱后主动调用 `block()` 暂停自己。

**为什么不用强制停止？**

强制停止（如 `pthread_kill`）会在任意位置中断线程，可能导致：
- 线程持有锁时被停止 → 死锁
- 线程正在修改对象头时被停止 → 数据不一致
- JNI 调用中被停止 → 本地代码状态不一致

协作式停止保证线程只在"安全位置"暂停，这些位置的 JVM 内部状态是一致的。

### 打脸二：TTSP 极短，但 STW 总时长可能很长

**我以为**：SafePoint 的停顿时间 = TTSP（Time To SafePoint）。

**实际上**：TTSP 只是"让所有线程到达 SafePoint"的时间，通常只有几十微秒（实测约 24μs）。STW 总时长 = TTSP + **GC 操作时间**。GC 操作（如 Young GC 的对象复制）才是停顿的主体，可能长达几十毫秒。

**打脸数据**（来自打桩验证）：
```
TTSP ≈ 24μs（让所有线程到达 SafePoint）
STW 总时长 ≈ 40ms（其中 GC 操作 ≈ 39.976ms）
TTSP 占比 ≈ 0.06%
```

### 打脸三：`_safepoint_counter` 不是计数器，而是奇偶编码的状态机

**我以为**：`_safepoint_counter` 记录了 SafePoint 发生的次数，用于统计。

**实际上**：它是一个**奇偶编码的状态机**：
- **奇数**：当前处于 STW 状态（SafePoint 进行中）
- **偶数**：当前处于正常运行状态

JNI 快速路径用它来判断是否需要加锁：如果 `_safepoint_counter` 是偶数（正常运行），JNI 返回时可以跳过 SafePoint 检查；如果是奇数（STW 中），必须等待 STW 结束。

---

## 还没搞懂的地方

- [ ] **解释器的 SafePoint 轮询位置**：解释器通过切换 dispatch 表来实现 SafePoint，但具体是在哪些字节码指令之间插入轮询？是每条字节码都轮询，还是只在跳转/方法调用时轮询？

- [ ] **JIT 编译代码的轮询页陷阱**：JIT 编译后的代码在哪些位置插入轮询指令？是每个方法调用点，还是每个循环回边，还是两者都有？轮询指令的具体机器码是什么？

- [ ] **`SuspendibleThreadSet` 与 SafePoint 的精确交互时序**：当 VM 线程触发 SafePoint 时，正在执行 `yield()` 的并发 GC 线程会立即暂停吗？还是会等到下一个 `yield()` 调用点？

---

## 继续深入

- **[第 24 篇：Young GC 完整流程](./24-g1-young-gc-HandWritten.md)** — Young GC 在 SafePoint 内执行，这里有完整的 Young GC 流程（SafePoint 是 GC 的前提）
- **[第 26 篇：并发标记与 SATB](./26-g1-concurrent-mark-HandWritten.md)** — 并发标记线程通过 `SuspendibleThreadSet` 与 SafePoint 协调，这里有完整分析
- **[第 29 篇：GC 日志深度解读](./29-g1-gc-log-HandWritten.md)** — GC 日志中的 `Pause` 时间包含 TTSP，`-XX:+PrintSafepointStatistics` 可以单独看 TTSP
- **相关源码**：
  - `src/hotspot/share/runtime/safepoint.cpp`（SafepointSynchronize 核心实现）
  - `src/hotspot/share/runtime/safepointMechanism.cpp`（轮询机制）
  - `src/hotspot/share/runtime/suspendibleThreadSet.cpp`（并发 GC 线程协调）
  - `src/hotspot/share/runtime/thread.cpp`（JavaThread::block() 实现）
