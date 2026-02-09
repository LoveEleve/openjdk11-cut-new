# Handshake 机制详解

## 📌 功能定位

**一句话说明**：Handshake 是 JDK 10 引入的**单线程安全操作机制**，允许对**单个**目标线程执行操作，而无需让**所有**线程都进入安全点（STW），从而显著减少停顿时间。

**核心价值**：
- **传统 Safepoint**：需要等待所有 Java 线程到达安全点，才能执行操作
- **Handshake**：只需等待目标线程到达安全点，其他线程继续运行

**形象比喻**：
```
┌─────────────────────────────────────────────────────────────────────────────────┐
│  传统 Safepoint（全班同学起立）                                                   │
│  ═══════════════════════════════════════════════════════════════════════════    │
│                                                                                  │
│  老师：全班起立！                                                                │
│  学生1、学生2、学生3 ... 学生100：（都停下来站起来）                               │
│  老师：小明，你来回答问题                                                        │
│  学生1、学生2、学生3 ... 学生100：（继续等待...）                                 │
│  小明：回答完毕                                                                  │
│  老师：好，全班坐下                                                              │
│                                                                                  │
│  问题：99个学生白白等待！                                                        │
├─────────────────────────────────────────────────────────────────────────────────┤
│  Handshake（握手机制）                                                           │
│  ═══════════════════════════════════════════════════════════════════════════    │
│                                                                                  │
│  老师：（走到小明身边拍拍肩膀）小明，我有个问题问你                               │
│  小明：（暂停手头工作）请说                                                      │
│  学生1、学生2 ... 学生99：（继续学习，不受影响）                                 │
│  小明：回答完毕（继续学习）                                                      │
│                                                                                  │
│  优点：只打断一个人！                                                            │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 🏛️ 设计哲学

### 为什么需要 Handshake？

| 场景 | 传统 Safepoint | Handshake |
|------|---------------|-----------|
| **偏向锁撤销** | 全部线程 STW | 只暂停持有锁的那个线程 |
| **获取单线程栈** | 全部线程 STW | 只暂停目标线程 |
| **线程采样** | 全部线程 STW | 只采样目标线程 |
| **Deoptimization** | 全部线程 STW | 只反优化相关线程 |

### 性能收益

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                      Safepoint vs Handshake 性能对比                             │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  假设：1000 个 Java 线程，需要对 Thread-42 执行操作                              │
│                                                                                  │
│  ┌──────────────────────────────────────────────────────────────────┐           │
│  │  Safepoint 方式                                                  │           │
│  │                                                                  │           │
│  │  等待时间 = max(线程1到达时间, 线程2到达时间, ..., 线程1000)       │           │
│  │           = 取决于最慢的那个线程！                                │           │
│  │                                                                  │           │
│  │  影响范围 = 1000 个线程全部暂停                                   │           │
│  └──────────────────────────────────────────────────────────────────┘           │
│                                                                                  │
│  ┌──────────────────────────────────────────────────────────────────┐           │
│  │  Handshake 方式                                                  │           │
│  │                                                                  │           │
│  │  等待时间 = Thread-42 的到达时间                                  │           │
│  │           = 只取决于目标线程！                                    │           │
│  │                                                                  │           │
│  │  影响范围 = 1 个线程暂停                                          │           │
│  └──────────────────────────────────────────────────────────────────┘           │
│                                                                                  │
│  典型收益：从 10ms 降低到 < 1ms                                                  │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 🔄 Handshake 与 Safepoint 的关系

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                   Handshake 与 Safepoint 的层次关系                              │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│                     ┌─────────────────────────────┐                             │
│                     │  SafepointMechanism         │                             │
│                     │  (底层轮询机制)              │                             │
│                     │                             │                             │
│                     │  • polling page             │                             │
│                     │  • arm/disarm               │                             │
│                     │  • Thread Local Poll        │                             │
│                     └──────────┬──────────────────┘                             │
│                                │                                                 │
│                                │ 共享                                            │
│                ┌───────────────┼───────────────┐                                │
│                │               │               │                                │
│                ▼               ▼               ▼                                │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐                  │
│  │  Safepoint      │  │   Handshake     │  │  (未来扩展...)   │                  │
│  │  (全局同步)     │  │  (单线程同步)   │  │                  │                  │
│  │                 │  │                 │  │                  │                  │
│  │  所有线程 arm   │  │  单个线程 arm   │  │                  │                  │
│  │  STW            │  │  非 STW         │  │                  │                  │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘                  │
│                                                                                  │
│  关键洞察：                                                                      │
│  ──────────────────────────────────────────────────────────────────────────     │
│  Handshake 基于 Thread Local Poll 实现，复用了 Safepoint 的轮询基础设施，         │
│  但只对单个线程设置 poll armed 状态，实现"定点打击"而非"全面轰炸"                │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 📋 核心类结构

### 类关系图

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          Handshake 类关系                                        │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  ┌──────────────────────────────┐                                               │
│  │  HandshakeClosure            │  ← 用户定义的回调                              │
│  │  (继承 ThreadClosure)        │                                               │
│  ├──────────────────────────────┤                                               │
│  │ + name(): const char*        │  返回操作名称                                  │
│  │ + do_thread(Thread*): void   │  在目标线程上执行的操作                        │
│  └──────────────────────────────┘                                               │
│               │                                                                  │
│               │ 使用                                                             │
│               ▼                                                                  │
│  ┌──────────────────────────────┐                                               │
│  │  Handshake (AllStatic)       │  ← 对外接口                                    │
│  ├──────────────────────────────┤                                               │
│  │ + execute(HandshakeClosure*) │  对所有线程执行                                │
│  │ + execute(HandshakeClosure*, │                                               │
│  │           JavaThread*)       │  对单个线程执行                                │
│  └──────────────────────────────┘                                               │
│               │                                                                  │
│               │ 内部使用                                                         │
│               ▼                                                                  │
│  ┌──────────────────────────────┐      ┌──────────────────────────────┐         │
│  │  HandshakeOperation          │      │  VM_HandshakeOneThread       │         │
│  │  (操作封装)                   │      │  VM_HandshakeAllThreads      │         │
│  ├──────────────────────────────┤      │  (VM 操作实现)                │         │
│  │ + do_handshake(JavaThread*)  │      └──────────────────────────────┘         │
│  └──────────────────────────────┘                                               │
│               │                                                                  │
│               │ 关联                                                             │
│               ▼                                                                  │
│  ┌──────────────────────────────┐                                               │
│  │  HandshakeState              │  ← 每个 JavaThread 内嵌                        │
│  │  (每线程状态)                 │                                               │
│  ├──────────────────────────────┤                                               │
│  │ - _operation: HandshakeOp*   │  当前待执行的操作                              │
│  │ - _semaphore: Semaphore      │  保护并发访问                                  │
│  │ + set_operation()            │  设置操作并 arm poll                           │
│  │ + process_by_self()          │  目标线程自己处理                              │
│  │ + try_process_by_vmThread()  │  VMThread 代为处理                            │
│  └──────────────────────────────┘                                               │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### HandshakeState::ProcessResult 枚举

```cpp
// handshake.hpp:88
enum ProcessResult {
    _no_operation = 0,   // 没有待处理的操作（线程已自己处理）
    _not_safe,           // 线程不在安全状态，无法代为处理
    _state_busy,         // 信号量被占用，无法获取
    _success,            // VMThread 成功代为执行
    _number_states       // 状态数量（用于数组大小）
};
```

---

## 🔄 执行流程详解

### 单线程 Handshake 完整流程

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│            Handshake::execute(HandshakeClosure*, JavaThread* target)            │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  调用者                          VMThread                  目标线程 (target)     │
│     │                              │                           │                │
│     │                              │                           │ 正常执行       │
│     │  Handshake::execute(cl, target)                          │                │
│     │─────────────────────────────→│                           │                │
│     │                              │                           │                │
│     │        创建 VM_HandshakeOneThread                        │                │
│     │        VMThread::execute(&handshake)                     │                │
│     │                              │                           │                │
│     │                              ├── 1. set_handshake(target)│                │
│     │                              │      │                    │                │
│     │                              │      └── target->_handshake_state          │
│     │                              │             .set_operation(op)             │
│     │                              │             │                              │
│     │                              │             └── arm_local_poll(target)     │
│     │                              │                    │                       │
│     │                              │                    └── 只 arm 目标线程！   │
│     │                              │                                            │
│     │                              │                           │                │
│     │                              │                           │ 检测到 armed!  │
│     │                              │                           │      │         │
│     │                              │                           │      ▼         │
│     │                              │                   block_if_requested()     │
│     │                              │                           │                │
│     │                              │                   has_handshake()?         │
│     │                              │                           │ Yes            │
│     │                              │                           ▼                │
│     │                              │                   process_by_self()        │
│     │                              │                           │                │
│     │                              │                           ├── 获取 semaphore
│     │                              │                           │                │
│     │                              │                           ├── op->do_handshake(this)
│     │                              │                           │    执行 HandshakeClosure
│     │                              │                           │                │
│     │                              │                           ├── clear_handshake()
│     │                              │                           │    disarm_local_poll
│     │                              │                           │                │
│     │                              │                           └── _done.signal()
│     │                              │                                            │
│     │                              ├── 2. 循环 poll_for_completed_thread()      │
│     │                              │      │                                     │
│     │                              │      └── _done.trywait() == true           │
│     │                              │          操作完成！                         │
│     │                              │                                            │
│     │←─────────────────────────────┤                                            │
│     │        返回 true (thread_alive)                          │                │
│     │                              │                           │                │
│     ▼                              ▼                           ▼ 继续执行      │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 两种完成方式

Handshake 操作可以由两种角色完成：

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                   Handshake 操作的两种执行者                                     │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  方式 1: 目标线程自己执行 (Self-Processing)                                      │
│  ═══════════════════════════════════════════════════════════════════════════    │
│                                                                                  │
│  适用场景：目标线程处于活跃状态，能检测到 poll armed                             │
│                                                                                  │
│  Target Thread                                                                   │
│     │                                                                            │
│     │ 检测到 poll armed                                                          │
│     │      │                                                                     │
│     │      ▼                                                                     │
│     │ SafepointMechanism::block_if_requested()                                  │
│     │      │                                                                     │
│     │      ├── has_handshake()? → Yes                                           │
│     │      │                                                                     │
│     │      └── HandshakeState::process_by_self()                                │
│     │               │                                                            │
│     │               ├── _semaphore.trywait() // 获取锁                           │
│     │               ├── op->do_handshake(this) // 执行                          │
│     │               ├── clear_handshake() // 清理                               │
│     │               └── _done.signal() // 通知完成                              │
│     │                                                                            │
│     ▼ 继续执行                                                                   │
│                                                                                  │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  方式 2: VMThread 代为执行 (VMThread-Processing)                                 │
│  ═══════════════════════════════════════════════════════════════════════════    │
│                                                                                  │
│  适用场景：目标线程处于阻塞状态，无法自己检测 poll                               │
│                                                                                  │
│  VMThread                          Target Thread (Blocked)                      │
│     │                                   │                                        │
│     │ 检测到 target 处于安全状态          │ (在 wait/sleep/blocked)              │
│     │      │                             │                                        │
│     │      ▼                             │                                        │
│     │ try_process_by_vmThread(target)    │                                        │
│     │      │                             │                                        │
│     │      ├── possibly_vmthread_can_process_handshake()                         │
│     │      │   │                         │                                        │
│     │      │   ├── target->is_blocked()? → Yes                                   │
│     │      │   └── return true           │                                        │
│     │      │                             │                                        │
│     │      ├── claim_handshake_for_vmthread()                                    │
│     │      │   └── _semaphore.trywait() // 获取锁                                │
│     │      │                             │                                        │
│     │      ├── op->do_handshake(target) // VMThread 代为执行                     │
│     │      │                             │                                        │
│     │      ├── clear_handshake(target) // 清理                                   │
│     │      │                             │                                        │
│     │      └── _semaphore.signal()       │                                        │
│     │                                    │                                        │
│     ▼                                    ▼ (唤醒后继续)                           │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 安全状态判断

VMThread 代为处理前，必须确认目标线程处于安全状态：

```cpp
// handshake.cpp:451
bool HandshakeState::vmthread_can_process_handshake(JavaThread* target) {
  // 条件1: SafepointSynchronize 认为安全
  return SafepointSynchronize::safepoint_safe(target, target->thread_state()) ||
         // 条件2: 被外部挂起
         target->is_ext_suspended() ||
         // 条件3: 已终止
         target->is_terminated();
}

// handshake.cpp:459 (快速预检查)
static bool possibly_vmthread_can_process_handshake(JavaThread* target) {
  if (target->is_ext_suspended()) return true;
  if (target->is_terminated()) return true;
  
  switch (target->thread_state()) {
  case _thread_in_native:
    // native 线程：如果没有 Java 栈或栈可遍历，则安全
    return !target->has_last_Java_frame() || target->frame_anchor()->walkable();
  case _thread_blocked:
    // 阻塞状态：安全
    return true;
  default:
    return false;
  }
}
```

---

## 🔧 Semaphore 保护机制

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    Semaphore 互斥保护                                            │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  问题场景：VMThread 和目标线程可能同时尝试执行 Handshake 操作                    │
│                                                                                  │
│  VMThread                                      Target Thread                    │
│     │                                              │                             │
│     │ try_process_by_vmThread()                    │ process_by_self()           │
│     │     │                                        │     │                       │
│     │     ├── claim_handshake_for_vmthread()       │     ├── _semaphore.trywait()│
│     │     │        │                               │     │        │              │
│     │     │        ▼                               │     │        ▼              │
│     │     │   _semaphore.trywait()                 │     │   (竞争同一信号量)     │
│     │     │        │                               │     │        │              │
│     └─────┼────────┼───────────────────────────────┼─────┼────────┘              │
│           │        │                               │     │                       │
│           │        └──────────┐    ┌───────────────┘     │                       │
│           │                   │    │                     │                       │
│           │                   ▼    ▼                     │                       │
│           │            ┌─────────────────┐               │                       │
│           │            │   Semaphore(1)  │               │                       │
│           │            │   (初始值为1)    │               │                       │
│           │            └─────────────────┘               │                       │
│           │                   │    │                     │                       │
│           │    获取成功───────┘    └───────获取失败       │                       │
│           │        │                          │          │                       │
│           │        ▼                          ▼          │                       │
│           │   执行操作                  等待/放弃        │                       │
│           │        │                                     │                       │
│           │        ▼                                     │                       │
│           │   _semaphore.signal() // 释放                │                       │
│           │                                              │                       │
│                                                                                  │
│  保证：同一时刻只有一个执行者能执行 Handshake 操作                               │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 📊 使用场景示例

### 1. 自定义 HandshakeClosure

```cpp
// 获取单个线程的栈信息
class GetStackTraceClosure : public HandshakeClosure {
  JavaThread* _target;
  StackTraceElement* _result;
  
public:
  GetStackTraceClosure(JavaThread* target) 
    : HandshakeClosure("GetStackTrace"), _target(target), _result(NULL) {}
  
  void do_thread(Thread* thread) override {
    JavaThread* jt = (JavaThread*)thread;
    // 在目标线程的安全点执行，可以安全遍历栈
    _result = get_stack_trace_elements(jt);
  }
  
  StackTraceElement* result() { return _result; }
};

// 使用
GetStackTraceClosure closure(target_thread);
bool thread_alive = Handshake::execute(&closure, target_thread);
if (thread_alive) {
  StackTraceElement* trace = closure.result();
  // 处理栈信息...
}
```

### 2. ZGC 中的使用

```cpp
// gc/z/zMark.cpp:367
class ZMarkFlushAndFreeStacksClosure : public HandshakeClosure {
  ZMark* const _mark;
  
public:
  ZMarkFlushAndFreeStacksClosure(ZMark* mark) 
    : HandshakeClosure("ZMarkFlushAndFreeStacks"), _mark(mark) {}
  
  void do_thread(Thread* thread) override {
    // 刷新线程本地的标记栈
    _mark->flush_and_free_worker_stack(thread);
  }
};

// 使用：对所有线程执行
ZMarkFlushAndFreeStacksClosure cl(this);
Handshake::execute(&cl);
```

### 3. Shenandoah GC 中的使用

```cpp
// gc/shenandoah/shenandoahConcurrentMark.cpp:415
class ShenandoahFlushSATBHandshakeClosure : public HandshakeClosure {
public:
  ShenandoahFlushSATBHandshakeClosure() 
    : HandshakeClosure("Shenandoah Flush SATB Handshake") {}
  
  void do_thread(Thread* thread) override {
    // 刷新 SATB 缓冲区
    if (thread->is_Java_thread()) {
      SATBMarkQueue& queue = ((JavaThread*)thread)->satb_mark_queue();
      queue.flush();
    }
  }
};
```

---

## 🆚 Safepoint vs Handshake 对比总结

| 特性 | Safepoint | Handshake |
|------|-----------|-----------|
| **停顿范围** | 所有 Java 线程 | 仅目标线程 |
| **触发方式** | VMThread 修改全局 polling page | 设置单个线程的 _operation |
| **等待时间** | 取决于最慢的线程 | 取决于目标线程 |
| **吞吐影响** | 大（全部暂停） | 小（其他线程继续） |
| **适用场景** | GC、代码反优化等全局操作 | 偏向锁撤销、获取栈信息等单线程操作 |
| **JDK 版本** | 一直存在 | JDK 10+ |
| **配置开关** | - | `-XX:+ThreadLocalHandshakes` (默认开启) |

---

## ⚙️ JVM 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `ThreadLocalHandshakes` | true (JDK 11+) | 启用线程本地轮询和 Handshake |
| `HandshakeTimeout` | 0 | Handshake 超时时间(ms)，0 表示无限等待 |

---

## 🎤 面试必背

### 1. 什么是 Handshake 机制？

> **答**：Handshake 是 JDK 10 引入的单线程安全操作机制。它允许对单个目标线程执行操作，而无需让所有线程进入安全点（STW）。核心思想是只 arm 目标线程的 polling page，让目标线程自己或 VMThread 代为执行操作。

### 2. Handshake 和 Safepoint 有什么区别？

> **答**：
> - **范围**：Safepoint 暂停所有线程，Handshake 只暂停目标线程
> - **等待**：Safepoint 等待最慢的线程，Handshake 只等待目标线程
> - **场景**：Safepoint 用于 GC 等全局操作，Handshake 用于偏向锁撤销等单线程操作
> - **性能**：Handshake 大幅减少停顿时间

### 3. Handshake 的执行者有哪些？

> **答**：有两种执行者：
> 1. **目标线程自己** (Self-Processing)：线程活跃时，检测到 poll armed 后自己执行
> 2. **VMThread 代为执行** (VMThread-Processing)：线程阻塞时，VMThread 在确认安全后代为执行

### 4. Handshake 如何保证线程安全？

> **答**：通过 `Semaphore` 保护。每个线程的 `HandshakeState` 包含一个信号量，初始值为 1。无论是目标线程自己执行还是 VMThread 代为执行，都需要先获取信号量，保证同一时刻只有一个执行者。

### 5. Handshake 有什么典型应用场景？

> **答**：
> - **偏向锁撤销**：只需暂停持有锁的线程
> - **获取单线程栈**：jstack、async-profiler 等
> - **ZGC/Shenandoah 标记栈刷新**：刷新线程本地的标记数据
> - **线程采样**：性能分析工具采样

---

## 📊 源码位置速查

| 内容 | 文件 | 行号 |
|------|------|------|
| HandshakeClosure 定义 | `handshake.hpp` | 40 |
| Handshake::execute | `handshake.cpp` | 381, 392 |
| HandshakeState 定义 | `handshake.hpp` | 63 |
| set_operation | `handshake.cpp` | 407 |
| process_by_self | `handshake.cpp` | 418 |
| try_process_by_vmThread | `handshake.cpp` | 483 |
| vmthread_can_process_handshake | `handshake.cpp` | 442 |
| VM_HandshakeOneThread | `handshake.cpp` | 199 |
| VM_HandshakeAllThreads | `handshake.cpp` | 253 |

---

## 🔬 GDB 验证脚本

见 [gdb_handshake.txt](./gdb_handshake.txt)

---

## ✅ 验证结果

### JVM 参数验证

```bash
$ java -XX:+PrintFlagsFinal -version | grep -i "ThreadLocalHandshakes\|HandshakeTimeout"

     uint HandshakeTimeout                         = 0                   {diagnostic} {default}
     bool ThreadLocalHandshakes                    = true                {pd product} {default}
```

| 参数 | 值 | 说明 |
|------|-----|------|
| `ThreadLocalHandshakes` | ✅ true | JDK 11 默认启用线程本地轮询和 Handshake |
| `HandshakeTimeout` | 0 | 无限等待（0 表示禁用超时检测） |

### 关键实现确认

```
【源码验证】
┌─────────────────────────────────────────────────────────────────────────────────┐
│ 1. Handshake::execute() 入口检查 ThreadLocalHandshakes:                          │
│    if (ThreadLocalHandshakes) {                                                  │
│        // 使用 VM_HandshakeOneThread 或 VM_HandshakeAllThreads                   │
│    } else {                                                                      │
│        // 回退到 VM_HandshakeFallbackOperation (走 Safepoint)                    │
│    }                                                                             │
│                                                                                  │
│ 2. set_operation() 会调用 arm_local_poll():                                      │
│    void HandshakeState::set_operation(JavaThread* target, HandshakeOperation* op)│
│    {                                                                             │
│        _operation = op;                                                          │
│        SafepointMechanism::arm_local_poll_release(target);  // 只 arm 目标线程  │
│    }                                                                             │
│                                                                                  │
│ 3. 清除时调用 disarm_local_poll():                                               │
│    void HandshakeState::clear_handshake(JavaThread* target) {                    │
│        _operation = NULL;                                                        │
│        SafepointMechanism::disarm_local_poll_release(target);                   │
│    }                                                                             │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 核心结论

| 验证项 | 结果 | 说明 |
|--------|------|------|
| ✅ 机制启用 | `ThreadLocalHandshakes=true` | JDK 11 默认 |
| ✅ 复用 SafepointMechanism | `arm_local_poll` / `disarm_local_poll` | 共享底层轮询基础设施 |
| ✅ 单线程粒度 | `set_operation(target, op)` | 只设置目标线程的 _operation |
| ✅ Semaphore 互斥 | `_semaphore` 初始值 1 | 保证 VMThread 和目标线程互斥执行 |

---

**下一步建议**: 继续学习 **偏向锁实现**（Handshake 的典型应用场景）？ 🚀
