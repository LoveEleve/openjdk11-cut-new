# SafepointSynchronize::begin() — 逐行深度分析

> **目标**: 深入理解 STW（Stop-The-World）的完整实现细节
> **源码**: `src/hotspot/share/runtime/safepoint.cpp:155-500`
> **标准环境**: `-Xms8g -Xmx8g -XX:+UseG1GC`, Region = 4MB
> **前置知识**: 已读 SafepointMechanism_init.md、SafepointSynchronize.md、SafepointMechanism.md

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文是对 **SafepointSynchronize::begin() — 逐行深度分析** 的深度源码分析：从数据结构到算法流程，逐层剖析其实现原理，并通过 GDB 验证关键结论。

### 0.2 为什么需要？

深入理解 JVM 内部实现，不仅能帮助排查生产问题，更能建立对 JVM 行为的精确预测能力——知道『为什么』比知道『是什么』更重要。

### 0.3 怎么解决？

采用「数据结构 → 算法流程 → GDB 验证」三步法：先完整分析所有涉及的数据结构（字段含义/sizeof/生命周期），再分析算法流程（每步有 why），最后用 GDB 实际验证关键结论。

### 0.4 为什么这样设计？

JVM 的每个设计决策都有其历史背景和性能考量。本文在分析每个关键设计时，都会解释「为什么这样而不是那样」，帮助读者建立设计直觉。

---


## 一句话总结

`SafepointSynchronize::begin()` 是 JVM 实现 STW 的核心函数，由 VMThread 调用，负责将所有 JavaThread "停下来"——通过 arm polling page、切换 dispatch table、修改全局状态，然后 spin + block 等待所有线程到达安全点，最后执行 7 项 cleanup 任务。

---

## 1. 设计哲学：为什么需要 Safepoint？

### 1.1 核心问题

GC 需要移动对象、修改引用，如果应用线程同时在读写这些引用，就会出现数据不一致。因此 GC（以及其他需要全局一致视图的操作）需要一个机制：**让所有 Java 线程暂停在一个"安全"的位置**，此时：

- 所有 Java 线程的栈帧可遍历（walkable）
- 没有线程正在修改 Java 堆上的引用
- OopMap 信息准确，GC 可以精确找到所有 GC roots

### 1.2 设计权衡

| 设计选择 | 优点 | 缺点 |
|----------|------|------|
| 抢占式暂停（OS signal 强制暂停） | 立即停止 | 可能停在不安全的位置（持有锁、部分更新对象） |
| **协作式暂停（Safepoint polling）** ✅ | 线程只在安全位置停下 | 需要等待线程主动检查（TTSP 可能较长） |

JVM 选择了**协作式**：通过在特定位置插入 polling 检查，让线程自己"发现"需要停下来。

---

## 2. begin() 整体流程骨架

```
SafepointSynchronize::begin()           // 仅 VMThread 调用
│
├── 阶段0: 准备 ─────────────────────────
│   ├── assert(myThread->is_VM_thread())         // 只有 VMThread 才能发起
│   ├── Universe::heap()->safepoint_synchronize_begin()  // 通知 GC
│   ├── Threads_lock->lock()                     // 锁住线程列表，禁止创建/销毁线程
│   ├── _waiting_to_block = nof_threads          // 初始化等待计数
│   └── MutexLocker mu(Safepoint_lock)           // 获取 Safepoint 锁
│
├── 阶段1: 通知所有线程 ──────────────────
│   ├── _state = _synchronizing                  // 全局状态：正在同步
│   │
│   ├── [Thread-Local Poll 模式] ★ JDK11 默认
│   │   ├── OrderAccess::storestore()            // 屏障：确保 _state 先写入
│   │   └── for 每个 JavaThread:
│   │       └── arm_local_poll(cur)              // 设置线程的 polling_page 为 armed 值
│   │
│   ├── OrderAccess::fence()                     // 全屏障
│   ├── os::serialize_thread_states()            // (仅 !UseMembar) 序列化内存
│   │
│   └── [Global Page Poll 模式] (旧模式)
│       ├── Interpreter::notice_safepoints()     // 切换解释器 dispatch table
│       └── os::make_polling_page_unreadable()   // mprotect(PROT_NONE)
│
├── 阶段2: Spin 等待 ──────────────────────
│   └── while(still_running > 0):
│       ├── for 每个 JavaThread:
│       │   └── examine_state_of_thread()        // 检查线程状态
│       │       ├── _thread_in_native → _at_safepoint（安全，直接计数）
│       │       ├── _thread_blocked   → _at_safepoint（安全，直接计数）
│       │       ├── _thread_in_vm     → _call_back（等线程回调）
│       │       └── _thread_in_Java   → 继续等（等 polling 触发）
│       │
│       ├── 超时检测: SafepointTimeout
│       └── Spin 策略:
│           ├── steps < 2000    → SpinPause() (MP-Polite spin)
│           ├── steps < 4000    → os::naked_yield()
│           └── steps >= 4000   → os::naked_short_sleep(1)
│
├── 阶段3: Block 等待 ──────────────────────
│   └── while(_waiting_to_block > 0):
│       └── Safepoint_lock->wait()               // 等待最后几个线程 block
│
├── 阶段4: 进入 Safepoint ──────────────────
│   ├── _safepoint_counter++                     // 奇数 = safepoint 中
│   ├── _state = _synchronized                   // 所有线程已停
│   ├── GCLocker::set_jni_lock_count()           // 设置 JNI critical 计数
│   └── RuntimeService::record_safepoint_synchronized()
│
└── 阶段5: Cleanup Tasks ──────────────────
    └── do_cleanup_tasks()
        ├── DEFLATE_MONITORS              — Monitor 缩减
        ├── UPDATE_INLINE_CACHES          — IC 更新
        ├── COMPILATION_POLICY            — 编译策略调整
        ├── SYMBOL_TABLE_REHASH           — SymbolTable rehash
        ├── STRING_TABLE_REHASH           — StringTable rehash
        ├── CLD_PURGE                     — ClassLoaderData 清理
        └── SYSTEM_DICTIONARY_RESIZE      — SystemDictionary 重大小
```

---

## 3. 阶段0: 准备阶段 — 源码逐行分析

```cpp
// safepoint.cpp:155
void SafepointSynchronize::begin() {
  EventSafepointBegin begin_event;   // JFR 事件记录
  Thread* myThread = Thread::current();
  assert(myThread->is_VM_thread(), "Only VM thread may execute a safepoint");
```

**关键点**：只有 VMThread 才能调用 `begin()`。这是一个硬性约束——所有需要 STW 的操作都必须提交 `VM_Operation` 给 VMThread。

```cpp
  Universe::heap()->safepoint_synchronize_begin();
```

通知 GC 堆即将进入 safepoint。对于 G1，这会做一些准备工作（如暂停并发精炼线程）。

```cpp
  // 获取 Threads_lock，防止线程创建/销毁
  Threads_lock->lock();
```

**为什么要锁 Threads_lock？** 如果在遍历线程列表时有线程被创建或销毁，计数就会出错。这个锁会**一直持有到 end()** 才释放——所以在 safepoint 期间，没有线程可以被创建或销毁。

```cpp
  int nof_threads = Threads::number_of_threads();
  MutexLocker mu(Safepoint_lock);

  _current_jni_active_count = 0;       // 重置 JNI critical 计数
  _waiting_to_block = nof_threads;     // 需要等待的线程数
  TryingToBlock     = 0;
  int still_running = nof_threads;     // 仍在运行的线程数
```

注意这里有**两个计数器**：
- `still_running`：Spin 阶段用，每次 `examine_state_of_thread()` 判定线程安全后递减
- `_waiting_to_block`：Block 阶段用，每次线程调用 `block()` 后递减

---

## 4. 阶段1: 通知所有线程 — 两种 Polling 模式

### 4.1 Thread-Local Poll 模式（JDK11 默认） ★

```cpp
  _state = _synchronizing;  // 全局状态切换！

  if (SafepointMechanism::uses_thread_local_poll()) {
    log_trace(safepoint)("Setting thread local yield flag for threads");
    OrderAccess::storestore();  // 确保 _state 写入对其他线程可见
    for (JavaThreadIteratorWithHandle jtiwh; JavaThread *cur = jtiwh.next(); ) {
      SafepointMechanism::arm_local_poll(cur);  // 核心！
    }
  }
  OrderAccess::fence();  // storestore|storeload 全屏障
```

**`arm_local_poll(cur)` 做了什么？**

```cpp
// safepointMechanism.inline.hpp:67
void SafepointMechanism::arm_local_poll(JavaThread* thread) {
  thread->set_polling_page(poll_armed_value());
}
```

将线程的 `_polling_page` 从 disarmed 值改为 armed 值：

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
┌──────────────────────────────────────────────────────┐
│ _poll_armed_value    = 0x7ffff7fbd008               │
│ _poll_disarmed_value = 0x7ffff7fbe000               │
│ _poll_bit            = 8                             │
│                                                      │
│ armed   地址 = bad_page  基址 | 0x8 → 指向不可读页面 │
│ disarmed 地址 = good_page 基址     → 指向可读页面     │
└──────────────────────────────────────────────────────┘
```

**核心设计**：armed/disarmed 通过**一个 bit 位**区分——`_poll_bit = 8`。armed 值的 bit 3 = 1，disarmed 值的 bit 3 = 0。这意味着：

1. **JIT 编译代码**：执行 `test [polling_page], eax`，如果是 armed（不可读页面），触发 **SIGSEGV** → 信号处理器 → `block()`
2. **判断是否 armed**：只需 `(intptr_t)polling_page & 8`

### 4.2 Global Page Poll 模式（旧模式，兼容）

```cpp
  if (SafepointMechanism::uses_global_page_poll()) {
    Interpreter::notice_safepoints();         // 切换解释器 dispatch table
    PageArmed = 1;
    os::make_polling_page_unreadable();       // mprotect(polling_page, PROT_NONE)
  }
```

**`Interpreter::notice_safepoints()` 做了什么？**

```cpp
// templateInterpreter.cpp:293
void TemplateInterpreter::notice_safepoints() {
  if (!_notice_safepoints) {
    _notice_safepoints = true;
    // 将 _safept_table 复制到 _active_table
    copy_table((address*)&_safept_table, (address*)&_active_table, sizeof(_active_table) / sizeof(address));
  }
}
```

将解释器的 dispatch table 从 `_normal_table` 切换为 `_safept_table`。`_safept_table` 中每条字节码的 handler 入口都会在执行完字节码后跳转到 `SafepointSynchronize::block()`。

**注意**：在 Thread-Local Poll 模式下（JDK11 默认），`notice_safepoints()` **不会被调用**，因为 Thread-Local Poll 不依赖全局 dispatch table 切换。

---

## 5. 阶段2: Spin 等待 — 线程状态检查核心

### 5.1 Spin 循环整体结构

```cpp
  int steps = 0;
  while(still_running > 0) {
    jtiwh.rewind();
    for (; JavaThread *cur = jtiwh.next(); ) {
      ThreadSafepointState *cur_state = cur->safepoint_state();
      if (cur_state->is_running()) {
        cur_state->examine_state_of_thread();  // 核心！
        if (!cur_state->is_running()) {
          still_running--;
        }
      }
    }
    // ... spin 策略
    iterations++;
  }
```

VMThread 不断遍历所有 JavaThread，检查每个线程是否已到达安全点。

### 5.2 examine_state_of_thread() — 核心状态判定

```cpp
// safepoint.cpp:1045
void ThreadSafepointState::examine_state_of_thread() {
  JavaThreadState state = _thread->thread_state();
  _orig_thread_state = state;  // 保存原始状态（end() 时恢复）

  // 1. 如果线程被外部挂起（ext_suspended），直接标记为安全
  bool is_suspended = _thread->is_ext_suspended();
  if (is_suspended) {
    roll_forward(_at_safepoint);
    return;
  }

  // 2. 如果线程状态本身就是安全的（native / blocked）
  if (SafepointSynchronize::safepoint_safe(_thread, state)) {
    SafepointSynchronize::check_for_lazy_critical_native(_thread, state);
    roll_forward(_at_safepoint);
    return;
  }

  // 3. 线程在 VM 代码中 → 设为 _call_back，等线程自己回调
  if (state == _thread_in_vm) {
    roll_forward(_call_back);
    return;
  }

  // 4. 其他状态（_thread_in_Java 等）→ 继续等
  //    线程会在下一次 polling 检查点自行 block
  return;
}
```

### 5.3 safepoint_safe() — 哪些状态是"天然安全"的？

```cpp
// safepoint.cpp:760
bool SafepointSynchronize::safepoint_safe(JavaThread *thread, JavaThreadState state) {
  switch(state) {
  case _thread_in_native:
    // native 线程安全的条件：没有 Java 栈帧，或栈可遍历
    return !thread->has_last_Java_frame() || thread->frame_anchor()->walkable();

  case _thread_blocked:
    // 阻塞线程一定安全（已经不再操作 Java 堆）
    return true;

  default:
    return false;
  }
}
```

**为什么 `_thread_in_native` 是安全的？**

- Native 代码不直接操作 Java 堆上的对象引用（只通过 JNI handle 间接持有）
- GC 可以安全移动对象，只要之后更新 JNI handle 指向的地址
- 但前提是栈必须是 walkable 的（GC 需要遍历栈找 roots）

**为什么 `_thread_blocked` 是安全的？**

- 线程阻塞在锁上时，不执行任何 Java 代码，栈帧稳定
- `assert(!thread->has_last_Java_frame() || thread->frame_anchor()->walkable())` 确认

### 5.4 roll_forward() — 推进线程状态

```cpp
void ThreadSafepointState::roll_forward(suspend_type type) {
  _type = type;
  switch(_type) {
    case _at_safepoint:
      SafepointSynchronize::signal_thread_at_safepoint();  // _waiting_to_block--
      if (_thread->in_critical()) {
        SafepointSynchronize::increment_jni_active_count();
      }
      break;
    case _call_back:
      set_has_called_back(false);  // 等待线程回调
      break;
  }
}
```

关键：当线程被判定为 `_at_safepoint` 时，`_waiting_to_block` 会递减。

### 5.5 五种 JavaThreadState 的处理策略

| JavaThreadState | 含义 | VMThread 的处理 | 线程如何到达安全点 |
|----------------|------|----------------|------------------|
| `_thread_in_Java` | 执行 Java 字节码或 JIT 代码 | 继续等待（不改 type） | 解释执行：下一条字节码时检查 dispatch table 跳转到 safept_entry；JIT：polling page 触发 SIGSEGV |
| `_thread_in_native` | 执行 JNI/Native 代码 | 直接标记 `_at_safepoint` | 无需主动停止；从 native 返回时，`transition_from_native()` 中检查并 block |
| `_thread_blocked` | 阻塞在锁/wait 上 | 直接标记 `_at_safepoint` | 无需主动停止；被唤醒时，检查 safepoint 状态并继续等待 |
| `_thread_in_vm` | 执行 VM 内部代码 | 标记 `_call_back` | 线程离开 VM 时（transition 到其他状态），检查并 block |
| `_thread_new` | 新建但未启动 | 归入默认分支，继续等 | 线程启动时的 transition 中会检查 |

### 5.6 Spin 策略：三阶段退避

```
Spin 策略（基于 steps 计数）:
┌───────────────────────────────────────────────────────────────────┐
│                                                                   │
│  steps < 2000         → SpinPause()                              │
│  (safepoint_spin_      CPU 级别的短暂停（PAUSE 指令）              │
│   before_yield)        ~10ns，不让出 CPU                          │
│                                                                   │
│  2000 ≤ steps < 4000  → os::naked_yield()                       │
│  (_defer_thr_suspend_  让出 CPU 时间片，但不保证其他线程运行        │
│   loop_count)          延迟约 ~微秒级                             │
│                                                                   │
│  steps ≥ 4000         → os::naked_short_sleep(1)                 │
│                        无条件 sleep 1ms                           │
│                        OS 可能 round up 到 10ms                   │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

**为什么不直接 sleep？**

大多数情况下，线程在几次 spin 内就能到达安全点。SpinPause 的开销极低（一条 PAUSE 指令），避免了上下文切换。只有当线程长时间不响应时，才逐步升级到 yield 和 sleep。

---

## 6. 阶段3: Block 等待

```cpp
  while (_waiting_to_block > 0) {
    if (!SafepointTimeout || timeout_error_printed) {
      Safepoint_lock->wait(true);  // 无条件等待
    } else {
      jlong remaining_time = safepoint_limit_time - os::javaTimeNanos();
      if (remaining_time < 0 || Safepoint_lock->wait(true, remaining_time / MICROUNITS)) {
        print_safepoint_timeout(_blocking_timeout);  // 超时报告
      }
    }
  }
```

此时 Spin 阶段已经结束（`still_running == 0` 意味着所有线程的状态已被检查），但 `_waiting_to_block` 可能还大于 0——这些是被标记为 `_call_back` 的线程（`_thread_in_vm`），它们还没有实际调用 `block()`。

VMThread 在 `Safepoint_lock` 上等待，直到所有线程都调用了 `block()`（block() 中会做 `_waiting_to_block--`，到 0 时 `notify_all()`）。

---

## 7. 阶段4: 进入 Safepoint

```cpp
  _safepoint_counter++;       // 变为奇数，表示在 safepoint 中
  _state = _synchronized;     // 所有线程已停
  OrderAccess::fence();
```

**`_safepoint_counter` 的意义**：

- **偶数** = 不在 safepoint 中
- **奇数** = 在 safepoint 中
- 用于 JNI fast path：JNI 函数可以快速检查 `if (_safepoint_counter & 1) == 0` 来判断是否安全

```cpp
  GCLocker::set_jni_lock_count(_current_jni_active_count);
```

如果有线程在 JNI critical region 中（`GetPrimitiveArrayCritical` 等），GCLocker 会阻止 GC 进行——因为 JNI critical 直接持有堆对象的裸指针。

---

## 8. 阶段5: Cleanup Tasks — 7 项"搭便车"任务

既然已经 STW 了，何不趁机做一些需要全局一致状态的清理工作？

```cpp
void SafepointSynchronize::do_cleanup_tasks() {
  DeflateMonitorCounters deflate_counters;
  ObjectSynchronizer::prepare_deflate_idle_monitors(&deflate_counters);

  // 尝试使用 GC 线程池并行执行
  WorkGang* cleanup_workers = Universe::heap()->get_safepoint_workers();
  if (cleanup_workers != NULL) {
    ParallelSPCleanupTask cleanup(num_cleanup_workers, &deflate_counters);
    cleanup_workers->run_task(&cleanup);
  } else {
    // 串行执行
    ParallelSPCleanupTask cleanup(1, &deflate_counters);
    cleanup.work(0);
  }
  ObjectSynchronizer::finish_deflate_idle_monitors(&deflate_counters);
}
```

### 7 项 Cleanup Task 详解

| # | 任务 | 做什么 | 为什么需要 STW |
|---|------|--------|---------------|
| 1 | **DEFLATE_MONITORS** | 缩减（deflate）空闲的 ObjectMonitor | Monitor 膨胀后不会自动缩回，需要定期回收避免内存浪费 |
| 2 | **UPDATE_INLINE_CACHES** | 更新 Inline Cache 缓冲区 | IC transition 需要原子性，STW 保证没有线程正在执行被修改的代码 |
| 3 | **COMPILATION_POLICY** | 调整编译策略（热度衰减等） | 需要一致的采样数据 |
| 4 | **SYMBOL_TABLE_REHASH** | 对 SymbolTable 进行 rehash | rehash 会移动 entry，需要保证无并发访问 |
| 5 | **STRING_TABLE_REHASH** | 对 StringTable 进行 rehash | 同上 |
| 6 | **CLD_PURGE** | 清理 ClassLoaderDataGraph | 删除已卸载的 ClassLoader 数据 |
| 7 | **SYSTEM_DICTIONARY_RESIZE** | 调整 SystemDictionary 大小 | resize 需要全局一致性 |

---

## 9. SafepointSynchronize::end() — 恢复所有线程

`end()` 是 `begin()` 的逆过程，核心任务：disarm polling、恢复线程状态、释放 Threads_lock。

### 9.1 流程骨架

```
SafepointSynchronize::end()
│
├── _safepoint_counter++                     // 变回偶数 → 不在 safepoint
│
├── [Global Page Poll 模式]
│   ├── os::make_polling_page_readable()     // mprotect(PROT_READ)
│   └── Interpreter::ignore_safepoints()     // 切回 normal_table
│
├── _state = _not_synchronized               // 全局状态恢复
│
├── [Thread-Local Poll 模式]
│   └── for 每个 JavaThread:
│       ├── cur_state->restart()             // TSS._type = _running
│       └── disarm_local_poll(current)       // polling_page → disarmed 值
│
├── [Global Page Poll 模式]
│   └── for 每个 JavaThread:
│       └── cur_state->restart()
│
├── RuntimeService::record_safepoint_end()
├── Threads_lock->unlock()                   // 释放线程锁！
│
└── Universe::heap()->safepoint_synchronize_end()
```

### 9.2 关键源码解读

```cpp
// safepoint.cpp:505
void SafepointSynchronize::end() {
  assert(Threads_lock->owned_by_self(), "must hold Threads_lock");
  assert((_safepoint_counter & 0x1) == 1, "must be odd");  // 当前在 safepoint 中

  _safepoint_counter++;  // 变回偶数

  if (PageArmed) {
    os::make_polling_page_readable();
    PageArmed = 0;
  }
  if (SafepointMechanism::uses_global_page_poll()) {
    Interpreter::ignore_safepoints();  // 切回 normal dispatch table
  }

  // 核心恢复逻辑
  if (SafepointMechanism::uses_thread_local_poll()) {
    _state = _not_synchronized;
    OrderAccess::storestore();
    for (JavaThread *current = jtiwh.next(); ) {
      ThreadSafepointState* cur_state = current->safepoint_state();
      cur_state->restart();                         // _type = _running
      SafepointMechanism::disarm_local_poll(current); // polling_page = disarmed
    }
  } else {
    _state = _not_synchronized;
    OrderAccess::fence();
    for (JavaThread *current = jtiwh.next(); ) {
      cur_state->restart();
    }
  }

  Threads_lock->unlock();  // 释放线程锁——阻塞在 block() 中的线程将被唤醒
}
```

**关键点**：

1. **`Threads_lock->unlock()` 是唤醒线程的关键**。`block()` 中的线程最后会 `Threads_lock->lock_without_safepoint_check()`，这个锁在 `end()` 释放时，所有等待的线程都会被唤醒。

2. **Thread-Local vs Global 的恢复差异**：
   - Thread-Local：先改 `_state`，再逐个 disarm
   - Global：先改 `_state`，再 mprotect 恢复可读

---

## 10. SafepointSynchronize::block() — 线程如何"停下来"

### 10.1 谁调用 block()？

| 路径 | 触发方式 | 调用链 |
|------|----------|--------|
| 解释执行 | safept_entry dispatch | `InterpreterRuntime::at_safepoint()` → `block()` |
| JIT 代码 | polling page SIGSEGV | 信号处理 → `handle_polling_page_exception()` → `block()` |
| Native 返回 | 状态转换检查 | `transition_from_native()` → `check_safepoint_and_suspend_for_native_trans()` → `block()` |
| VM 代码退出 | 状态转换检查 | `transition()` → `block_if_requested()` → `block()` |

### 10.2 block() 核心逻辑

```cpp
// safepoint.cpp:816
void SafepointSynchronize::block(JavaThread *thread) {
  JavaThreadState state = thread->thread_state();
  thread->frame_anchor()->make_walkable(thread);  // 确保栈可遍历

  switch(state) {
    case _thread_in_vm_trans:
    case _thread_in_Java:
      // 假装还在 VM 中（避免被误认为已停）
      thread->set_thread_state(_thread_in_vm);

      // 获取 Safepoint_lock
      Safepoint_lock->lock_without_safepoint_check();
      if (is_synchronizing()) {
        _waiting_to_block--;             // 递减等待计数
        thread->safepoint_state()->set_has_called_back(true);
        if (_waiting_to_block == 0) {
          Safepoint_lock->notify_all();  // 唤醒 VMThread！
        }
      }

      thread->set_thread_state(_thread_blocked);
      Safepoint_lock->unlock();

      // 关键：阻塞在 Threads_lock 上
      // Threads_lock 被 VMThread 持有，直到 end() 才释放
      Threads_lock->lock_without_safepoint_check();
      thread->set_thread_state(state);   // 恢复原始状态
      Threads_lock->unlock();
      break;

    case _thread_in_native_trans:
    case _thread_blocked_trans:
    case _thread_new_trans:
      // 过渡状态的线程直接阻塞在 Threads_lock
      thread->set_thread_state(_thread_blocked);
      Threads_lock->lock_without_safepoint_check();
      thread->set_thread_state(state);
      Threads_lock->unlock();
      break;
  }
}
```

### 10.3 block() 的精妙设计

**两把锁的配合**：

```
时间线：

VMThread:                          JavaThread:
─────────────────                  ─────────────────
begin()
 ├─ Threads_lock->lock()
 ├─ _state = _synchronizing
 ├─ arm polling
 ├─ spin + examine                  发现 safepoint:
 │                                   ├─ Safepoint_lock->lock()
 ├─ Block 阶段:                     ├─ _waiting_to_block--
 │  Safepoint_lock->wait() ◄────────├─ if (==0) notify_all()
 │                                   ├─ Safepoint_lock->unlock()
 ├─ _state = _synchronized          │
 ├─ do_cleanup_tasks()               │
 ├─ [VMThread 执行 VM_Operation]     ├─ Threads_lock->lock() ──┐
 │  (GC / Deopt / ...)               │  (阻塞！等待释放)      │
 │                                    │                        │ 阻塞
end()                                 │                        │ 期间
 ├─ _state = _not_synchronized        │                        │
 ├─ disarm polling                    │                        │
 └─ Threads_lock->unlock() ──────────▶ (被唤醒，继续执行)     │
                                      └─ thread->set_state()   ┘
```

**为什么用 Threads_lock 阻塞？**

`Threads_lock` 是一个大锁，在整个 safepoint 期间被 VMThread 持有。所有调用 `block()` 的线程最终都阻塞在 `Threads_lock->lock_without_safepoint_check()` 上。当 `end()` 释放这个锁时，所有线程同时被唤醒——这比逐个 `notify` 高效得多。

---

## 11. 四条线程响应 Safepoint 的路径

### 路径 A: 解释执行中的线程

```
字节码执行循环
│
├── [Global Page Poll 模式]
│   ├── VMThread 切换 dispatch table: _active_table = _safept_table
│   └── 线程执行下一条字节码 → dispatch 到 safept_entry
│       └── InterpreterRuntime::at_safepoint()
│           └── SafepointSynchronize::block(thread)
│
└── [Thread-Local Poll 模式] ★
    ├── VMThread 设置 thread->_polling_page = armed
    ├── 解释器在特定位置（方法返回、后向跳转）检查 polling page
    │   └── SafepointMechanism::poll(thread)
    │       └── local_poll_armed(thread) → true
    │           └── block_if_requested(thread)
    │               └── block_if_requested_slow(thread)
    │                   └── SafepointSynchronize::block(thread)
    └── 注意：Thread-Local 模式下，解释器不切换 dispatch table
```

### 路径 B: JIT 编译代码中的线程

```
JIT 编译后的机器码执行
│
├── JIT 编译时在以下位置插入 polling 指令：
│   ├── 方法返回前
│   ├── 循环回边（back-edge）
│   └── (C1/C2 各有不同策略)
│
├── x86 Polling 指令：
│   └── test dword ptr [polling_page_addr], eax
│       // 如果 polling_page 不可读 → SIGSEGV
│
├── 触发 SIGSEGV 信号
│   └── OS 信号处理器（JVM 注册）
│       └── JVM_handle_linux_signal()
│           └── 识别为 polling page 异常
│               └── SafepointSynchronize::handle_polling_page_exception(thread)
│                   └── state->handle_polling_page_exception()
│                       ├── 区分 poll_return vs poll
│                       ├── SafepointMechanism::block_if_requested(thread)
│                       └── 如果有异步异常 → deoptimize
│
└── 关键：JIT 编译代码中的 safepoint poll 是最常见的 TTSP 延迟源
    - C2 会对 counted loop 省略 safepoint poll（优化）
    - 这就是为什么长循环会导致 TTSP 过长
```

### 路径 C: 执行 Native 代码的线程

```
线程在 JNI native 方法中
│
├── 进入 native 前：thread_state = _thread_in_native
│
├── Safepoint 触发时：
│   └── VMThread 检查：state == _thread_in_native → 视为安全
│       └── roll_forward(_at_safepoint) → _waiting_to_block--
│       (Native 线程不需要主动停下！)
│
├── 线程从 native 返回时：
│   └── ThreadInVMfromNative 析构 → transition_from_native()
│       │
│       │  // interfaceSupport.inline.hpp:167
│       ├── thread->set_thread_state(_thread_in_native_trans)  // 过渡状态
│       ├── InterfaceSupport::serialize_thread_state()         // 内存屏障
│       ├── if (SafepointMechanism::poll(thread) || is_suspend_after_native)
│       │   └── check_safepoint_and_suspend_for_native_trans(thread)
│       │       └── SafepointSynchronize::block(thread)
│       └── thread->set_thread_state(to)  // → _thread_in_vm
│
└── 安全协议的关键：
    VMThread 看到 _thread_in_native → 视为安全，不等待
    线程返回时先设 _thread_in_native_trans（过渡态）
    过渡态的线程会检查 safepoint 并阻塞
    这个顺序保证不会"漏掉"任何线程
```

### 路径 D: 阻塞/等待中的线程

```
线程在 synchronized / Object.wait() / LockSupport.park() 上
│
├── 状态：_thread_blocked
│
├── Safepoint 触发时：
│   └── VMThread 检查：state == _thread_blocked → 直接安全
│       └── roll_forward(_at_safepoint)
│
├── 线程被唤醒时：
│   └── 离开 blocked 状态前的 transition
│       └── ThreadBlockInVM 析构 → trans_and_fence(_thread_blocked, _thread_in_vm)
│           └── transition_and_fence():
│               ├── set_thread_state(_thread_blocked_trans)  // 过渡态
│               ├── serialize_thread_state()
│               ├── block_if_requested()  // 检查 safepoint
│               └── set_thread_state(_thread_in_vm)
│
└── 关键：blocked 线程不需要做任何事就是安全的
    因为它已经不执行 Java 代码，栈帧是稳定的
```

---

## 12. ThreadSafepointState 数据结构

### 12.1 内存布局

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
┌──────────────────────────────────────────────────────────────────┐
│ sizeof(ThreadSafepointState) = 32 bytes                          │
├──────────────────────────────────────────────────────────────────┤
│ 偏移    字段名               大小    说明                         │
│ ─────────────────────────────────────────────────────────────── │
│ 0x00   [CHeapObj vtable?]    8      CHeapObj 基类（可能无 vtable）│
│ 0x08   _at_poll_safepoint    1      volatile bool                │
│ 0x09   _has_called_back      1      bool                         │
│ 0x0A   [padding]             6      对齐到 8 字节                 │
│ 0x10   _thread               8      JavaThread*                  │
│ 0x18   _type                 4      volatile suspend_type (enum) │
│ 0x1C   _orig_thread_state    4      JavaThreadState (enum)       │
├──────────────────────────────────────────────────────────────────┤
│ 总计: 32 bytes                                                    │
└──────────────────────────────────────────────────────────────────┘
```

### 12.2 字段详解

| 字段 | 类型 | 作用 | 谁读/谁写 |
|------|------|------|----------|
| `_at_poll_safepoint` | `volatile bool` | 线程是否在 poll 点（而非 poll return）被停下 | VMThread 读，JavaThread 在 `handle_polling_page_exception()` 中写 |
| `_has_called_back` | `bool` | 线程是否已回调（debug 用） | VMThread 在 `roll_forward()` 中写 false，JavaThread 在 `block()` 中写 true |
| `_thread` | `JavaThread*` | 所属线程 | 构造时设置，只读 |
| `_type` | `volatile suspend_type` | 当前状态（_running/_at_safepoint/_call_back） | VMThread 在 `examine` 中写，`end()` 中重置为 _running |
| `_orig_thread_state` | `JavaThreadState` | 进入 safepoint 时的原始线程状态 | VMThread 在 `examine` 中写，用于 `end()` 时恢复 |

### 12.3 状态转换图

```
                    examine:
                    _thread_in_native 或
                    _thread_blocked
    ┌─────────────────────────────────────┐
    │                                     ▼
┌───────────┐    examine:          ┌──────────────┐
│ _running  │    _thread_in_vm     │ _at_safepoint│
│           │───────────────┐      │              │
│ 初始状态  │               │      │ 已到达安全点  │
└───────────┘               ▼      └──────────────┘
                     ┌────────────┐       ▲
                     │ _call_back │       │
                     │            │───────┘
                     │ 等待回调   │  block() 调用后
                     └────────────┘  _waiting_to_block--

                     ─── end() 后全部重置 ──→ _running
```

---

## 13. VM_Operation 体系与 Safepoint 联动

### 13.1 VMThread 调度循环

```
VMThread::loop()
│
├── while(true):
│   │
│   ├── _cur_vm_operation = _vm_queue->remove_next()  // 取一个 VM_Operation
│   │
│   ├── if (队列为空 && 超过 GuaranteedSafepointInterval)
│   │   └── 发起"空" safepoint（只做 cleanup，不执行任何 VMOp）
│   │
│   ├── if (op->evaluate_at_safepoint()):
│   │   ├── safepoint_ops = drain_at_safepoint_priority()  // 批量取同优先级 ops
│   │   ├── SafepointSynchronize::begin()      // ← STW 开始！
│   │   ├── evaluate_operation(op)              // 执行主操作（如 GC）
│   │   ├── do { 执行 coalesced ops } while()  // 批量执行合并的操作
│   │   └── SafepointSynchronize::end()        // ← STW 结束！
│   │
│   └── else:  // 不需要 safepoint
│       └── evaluate_operation(op)              // 直接执行
│
└── VMOperationRequest_lock->notify_all()       // 通知等待的 JavaThread
```

### 13.2 GuaranteedSafepointInterval — 保底 Safepoint

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
┌──────────────────────────────────────────────┐
│ GuaranteedSafepointInterval = 1000 (ms)      │
│                                              │
│ 含义：即使没有 VM_Operation 需要执行，       │
│ 每隔 1000ms 也会发起一次"空" safepoint       │
│ 目的：执行 cleanup tasks（deflate monitor等）│
└──────────────────────────────────────────────┘
```

### 13.3 VM_Operation 执行模式

| Mode | 含义 | 需要 STW？ | 示例 |
|------|------|-----------|------|
| `_safepoint` | 阻塞式，需要 safepoint | ✅ | `VM_G1CollectForAllocation`（Young GC） |
| `_no_safepoint` | 阻塞式，不需要 safepoint | ❌ | 极少使用 |
| `_concurrent` | 非阻塞式，不需要 safepoint | ❌ | 某些 JFR 操作 |
| `_async_safepoint` | 非阻塞式，需要 safepoint | ✅ | `VM_ThreadStop`、`VM_ScavengeMonitors` |

### 13.4 需要 Safepoint 的典型操作

| 类别 | VM_Operation | 作用 | 为什么需要 STW |
|------|-------------|------|---------------|
| **GC** | `VM_G1CollectForAllocation` | G1 Young GC | 需要移动对象，更新引用 |
| **GC** | `VM_G1CollectFull` | G1 Full GC | 全堆整理 |
| **偏向锁** | `VM_RevokeBias` | 单个偏向锁撤销 | 需要修改对象头的所有线程可见 |
| **偏向锁** | `VM_BulkRevokeBias` | 批量偏向锁撤销 | 同上 |
| **反优化** | `VM_Deoptimize` | JIT 去优化 | 需要修改所有线程的栈帧 |
| **类重定义** | `VM_RedefineClasses` | Hotswap | 需要全局一致的类视图 |
| **诊断** | `VM_PrintThreads` | jstack 输出 | 需要稳定的线程状态 |
| **诊断** | `VM_HeapDumper` | jmap dump | 需要堆的一致快照 |
| **IC** | `VM_ICBufferFull` | IC 缓冲区满 | 需要 STW 来刷新 |
| **Monitor** | `VM_ScavengeMonitors` | 清理 Monitor | 需要无并发访问 |
| **强制** | `VM_ForceSafepoint` | 空操作，仅触发 cleanup | 保底清理 |

### 13.5 Operation 合并（Coalescing）

VMThread 在进入 safepoint 后，会尝试**批量执行**同优先级的 operations：

```cpp
// vmThread.cpp:543
SafepointSynchronize::begin();
evaluate_operation(_cur_vm_operation);
// 批量执行合并的 safepoint ops
do {
  _cur_vm_operation = safepoint_ops;
  if (_cur_vm_operation != NULL) {
    do {
      VM_Operation* next = _cur_vm_operation->next();
      evaluate_operation(_cur_vm_operation);
      _cur_vm_operation = next;
    } while (_cur_vm_operation != NULL);
  }
  // 再检查一次队列
  safepoint_ops = peek_and_drain_if_needed();
} while(safepoint_ops != NULL);
SafepointSynchronize::end();
```

这样可以**减少 safepoint 次数**：一次 STW 执行多个操作，比多次 STW 各执行一个更高效。

---

## 14. GDB 验证数据汇总

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
┌──────────────────────────────────────────────────────────────────────┐
│ === SafepointSynchronize 静态变量 ===                                │
│ _state 地址:                  0x7ffff7662fc0                        │
│ _state 初始值:                0 (_not_synchronized)                 │
│ _waiting_to_block 初始值:     0                                     │
│ _safepoint_counter 初始值:    0                                     │
│ _defer_thr_suspend_loop_count: 4000                                 │
│                                                                      │
│ === SafepointMechanism ===                                           │
│ _polling_type:                1 (_thread_local_poll) ★ JDK11 默认    │
│ _poll_armed_value:            0x7ffff7fbd008 (bad page | 0x8)       │
│ _poll_disarmed_value:         0x7ffff7fbe000 (good page)            │
│ _poll_bit:                    8                                      │
│                                                                      │
│ === ThreadSafepointState 内存布局 ===                                │
│ sizeof:                       32 bytes                               │
│ _at_poll_safepoint 偏移:      8                                     │
│ _has_called_back 偏移:        9                                     │
│ _thread 偏移:                 16                                    │
│ _type 偏移:                   24                                    │
│ _orig_thread_state 偏移:      28                                    │
│                                                                      │
│ === 关键参数 ===                                                     │
│ GuaranteedSafepointInterval:  1000 (ms)                             │
│ SafepointTimeout:             false                                  │
│ SafepointTimeoutDelay:        10000 (ms)                            │
│ ThreadLocalHandshakes:        true                                   │
│ UseMembar:                    true                                   │
│                                                                      │
│ === sizeof 统计 ===                                                  │
│ sizeof(ThreadSafepointState):                  32 bytes              │
│ sizeof(SafepointSynchronize::SafepointStats):  64 bytes              │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 15. Safepoint 超时诊断机制

### 15.1 超时检测

```cpp
// safepoint.cpp:286
if (SafepointTimeout)
  safepoint_limit_time = os::javaTimeNanos() + (jlong)SafepointTimeoutDelay * MICROUNITS;
```

当 `-XX:+SafepointTimeout` 启用时：
- `SafepointTimeoutDelay`（默认 10000ms = 10秒）定义了超时阈值
- Spin 阶段和 Block 阶段都会检测超时

### 15.2 超时时的行为

```cpp
void SafepointSynchronize::print_safepoint_timeout(SafepointTimeoutReason reason) {
  tty->print_cr("# SafepointSynchronize::begin: Timeout detected:");
  if (reason == _spinning_timeout) {
    tty->print_cr("# Timed out while spinning to reach a safepoint.");
  } else {
    tty->print_cr("# Timed out while waiting for threads to stop.");
  }

  // 打印未到达安全点的线程列表
  for (JavaThread *cur_thread : all_threads) {
    if (cur_state->is_running() || !cur_state->has_called_back()) {
      cur_thread->print();  // 打印问题线程信息
    }
  }

  // 如果配置了 AbortVMOnSafepointTimeout：
  if (AbortVMOnSafepointTimeout) {
    // 向问题线程发送 SIGILL 信号，触发 crash dump
    os::signal_thread(cur_thread, SIGILL, "blocking a safepoint");
    fatal("Safepoint sync time longer than %dms", SafepointTimeoutDelay);
  }
}
```

### 15.3 诊断参数汇总

| 参数 | 默认值 | 作用 |
|------|--------|------|
| `-XX:+SafepointTimeout` | false | 启用超时检测 |
| `-XX:SafepointTimeoutDelay=N` | 10000 (ms) | 超时阈值 |
| `-XX:+AbortVMOnSafepointTimeout` | false | 超时时 crash dump |
| `-XX:GuaranteedSafepointInterval=N` | 1000 (ms) | 保底 safepoint 间隔 |
| `-XX:+PrintSafepointStatistics` | false | 打印统计 |
| `-XX:PrintSafepointStatisticsCount=N` | 300 | 统计缓冲区大小 |
| `-XX:PrintSafepointStatisticsTimeout=N` | -1 | 超时才打印（ms） |
| `-XX:+SafepointALot` | false (debug) | 频繁触发（测试用） |

### 15.4 Unified Logging（JDK11 推荐）

```bash
# 查看 safepoint 基本信息
-Xlog:safepoint

# 查看 safepoint 详细信息（包括 cleanup）
-Xlog:safepoint*=debug

# 查看 safepoint + cleanup 耗时
-Xlog:safepoint,safepoint+cleanup=info

# 输出示例:
# [0.456s][info][safepoint] Entering safepoint region: G1CollectForAllocation
# [0.456s][info][safepoint,cleanup] safepoint cleanup tasks (0.12ms)
# [0.456s][info][safepoint,cleanup]   deflating idle monitors (0.05ms)
# [0.456s][info][safepoint,cleanup]   updating inline caches (0.03ms)
# [0.457s][info][safepoint] Leaving safepoint region
```

---

## 16. SafepointSynchronize 完整状态机

```
                              begin()
    ┌──────────────────────────────────────────────────┐
    │                                                  │
    ▼                                                  │
┌───────────────────┐    _state = _synchronizing   ┌───┴──────────────┐
│ _not_synchronized │  ─────────────────────────▶  │ _synchronizing   │
│                   │                              │                  │
│ 正常运行          │                              │ 正在同步:        │
│ counter = 偶数    │                              │ spin + block     │
│                   │  ◀─────────────────────────  │ arm polling      │
└───────────────────┘    _state = _not_synced      └──────────────────┘
         ▲                    end()                         │
         │                                                  │ _state = _synchronized
         │                                                  ▼
         │                                         ┌──────────────────┐
         │                                         │ _synchronized    │
         │                                         │                  │
         │                                         │ 所有线程已停:    │
         │                                         │ counter = 奇数   │
         │                                         │ 执行 VMOp        │
         │                                         │ cleanup tasks    │
         └─────────────────────────────────────────┘
                           end()
```

---

## 17. 常见面试问题解答

### Q1: STW 是怎么实现的？所有线程怎么停下来的？

**答**: JVM 使用**协作式** safepoint 机制。VMThread 通过以下方式通知所有线程停下来：
1. 设置全局 `_state = _synchronizing`
2. 对每个 JavaThread arm 其 polling page（Thread-Local Poll 模式）
3. 线程在安全点位置（方法返回、循环回边、字节码间隔）检查 polling 状态
4. 发现 armed 后调用 `block()`，阻塞在 `Threads_lock` 上
5. 对于 native/blocked 线程，VMThread 直接视为安全，不等待

### Q2: 安全点和安全区域有什么区别？

| 特征 | Safepoint（安全点） | Safe Region（安全区域） |
|------|---------------------|------------------------|
| 粒度 | 代码中的特定位置（插入 polling 的点） | 一段连续的代码区域 |
| 典型场景 | 方法返回、循环回边 | `_thread_blocked`、`_thread_in_native` |
| 线程行为 | 主动检查并 block | 进入时标记，离开时检查 |
| 对 GC 的意义 | 栈帧在该点可遍历 | 整个区域内栈帧稳定 |

### Q3: 为什么 GC 需要 Stop-The-World？

**答**: GC 需要一致的堆快照。如果 GC 在移动对象时，其他线程同时修改引用，会导致：
1. 悬挂引用（dangling pointer）
2. OopMap 不准确（无法精确找到 GC roots）
3. 对象图不一致

### Q4: TTSP（Time-To-Safepoint）过长怎么排查？

**答**:
1. 启用诊断：`-Xlog:safepoint*=debug`
2. 常见原因：
   - C2 的 counted loop 优化省略了 safepoint poll → 用 `-XX:+UseCountedLoopSafepoints` 修复
   - 大量 native 代码执行，返回后才检查 → 缩短 native 调用时间
   - 大量 monitor deflation → 减少锁竞争
3. 使用 `-XX:+SafepointTimeout -XX:SafepointTimeoutDelay=1000` 定位问题线程
4. 使用 JFR 的 `SafepointBegin` 事件分析

### Q5: 偏向锁撤销为什么需要 STW？

**答**: 偏向锁的撤销需要修改对象头（Mark Word），这个修改必须对所有线程原子可见。如果不 STW，其他线程可能正在读取 Mark Word 做锁判断，导致数据竞争。所以偏向锁撤销通过 `VM_RevokeBias` 提交给 VMThread，在 safepoint 中执行。

### Q6: _safepoint_counter 为什么用奇偶？

**答**: 这是一个高性能的**无锁**判断机制。JNI fast path 在调用 `GetPrimitiveArrayCritical` 等函数时，需要快速判断是否在 safepoint 中：
- 读一次 counter（偶数 = 安全，可继续）
- 执行 JNI 操作
- 再读一次 counter（如果变了，说明期间发生了 safepoint）
- 两次读取的值相同且为偶数 → fast path 成功

---

## 18. 源码文件索引

| 文件 | 关键内容 | 行号范围 |
|------|---------|---------|
| `safepoint.cpp` | `begin()` | 155-500 |
| `safepoint.cpp` | `end()` | 505-595 |
| `safepoint.cpp` | `do_cleanup_tasks()` | 731-755 |
| `safepoint.cpp` | `safepoint_safe()` | 760-775 |
| `safepoint.cpp` | `block()` | 816-940 |
| `safepoint.cpp` | `handle_polling_page_exception()` | 950-965 |
| `safepoint.cpp` | `ThreadSafepointState::examine_state_of_thread()` | 1045-1100 |
| `safepoint.cpp` | `roll_forward()` | 1105-1130 |
| `safepoint.cpp` | `handle_polling_page_exception()` (TSS) | 1160-1240 |
| `safepoint.hpp` | `SafepointSynchronize` 类定义 | 60-215 |
| `safepoint.hpp` | `ThreadSafepointState` 类定义 | 220-282 |
| `safepointMechanism.hpp` | `SafepointMechanism` 类定义 | 34-95 |
| `safepointMechanism.inline.hpp` | `arm/disarm/poll` 内联方法 | 35-80 |
| `safepointMechanism.cpp` | `default_initialize()` | 45-95 |
| `vmOperations.hpp` | `VM_Operation` 基类 + 子类 | 134-535 |
| `vmThread.hpp` | `VMThread` + `VMOperationQueue` | 35-190 |
| `vmThread.cpp` | `VMThread::loop()` | 457-640 |
| `interfaceSupport.inline.hpp` | `ThreadStateTransition` 状态转换 | 110-200 |
| `interfaceSupport.inline.hpp` | `transition_from_native()` | 167-180 |
| `templateInterpreter.cpp` | `notice_safepoints()` / `ignore_safepoints()` | 293-320 |

---

## 19. 完成后模块进度

```
完成前:
  Safepoint         ████████████████████████░░░░░░░░░░░░░░░░░░  60%  96KB

完成后 (ch01):
  Safepoint         ██████████████████████████████████░░░░░░░░░  82%  ~160KB
                                                     ^^^^^^^^
                                                     新增 ~64KB

剩余:
  - ch06: GDB 实战完整验证（观察一次完整 Young GC STW）→ 85%
  - ch07: 高级诊断与 JFR 集成 → 88%
  - Counted Loop Safepoint 省略（C2 特有）→ 90%
```

---

*创建时间: 2026-02-09*
*GDB 验证环境: OpenJDK 11, -Xms8g -Xmx8g -XX:+UseG1GC*
