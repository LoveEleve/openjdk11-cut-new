# 主题三：synchronized 锁机制 — 从偏向到重量级

> 对应文档: `Runtime/ch03_lock_optimization.md`, `Phase3/3.8_objectmonitor_analysis.md`, `Runtime/ch01_object_header_markword.md`
> 面试覆盖: 锁升级 / ObjectMonitor / 自旋 / wait-notify / 锁消除 / 锁粗化

---

## Q1: synchronized 的锁升级过程是什么？⭐

### 一句话结论
无锁 → ~~偏向锁~~ → **轻量级锁(CAS)** → **重量级锁(ObjectMonitor)**，逐级升级不可降级（重量级锁可在 STW 时 deflate）。

### 源码级回答

> **注意: JDK 15+ 默认关闭偏向锁，JDK 11 仍有但有延迟。以下分析基于无偏向锁的路径。**

```
┌─────────── 无锁 (lock bits = 01) ──────────────┐
│ markWord = [hash:31 | age:4 | 0 | 01]          │
└──────────────────┬─────────────────────────────┘
                   │ 第一次 synchronized
                   ▼
┌─────────── 轻量级锁 (lock bits = 00) ──────────┐
│ 1. 在栈帧中创建 BasicLock                        │
│ 2. CAS(markWord → BasicLock 地址)               │
│ 3. 成功: markWord = [BasicLock* | 00]           │
│ 4. BasicLock._displaced_header = 原始 markWord   │
└──────────────────┬─────────────────────────────┘
                   │ CAS 失败 (有竞争)
                   ▼
┌─────────── 重量级锁 (lock bits = 10) ──────────┐
│ 1. inflate() 创建/获取 ObjectMonitor             │
│ 2. markWord = [ObjectMonitor* | 10]             │
│ 3. ObjectMonitor::enter()                        │
│    → CAS _owner → 自适应自旋 → park() 阻塞      │
└────────────────────────────────────────────────┘
```

**轻量级锁的本质:**
- **不阻塞线程**，用 CAS 竞争
- 适用于"交替执行"的场景（无真正并发竞争）
- 竞争 → 膨胀为重量级锁

> 📖 详细文档: `Runtime/ch03_lock_optimization.md`

---

## Q2: ObjectMonitor 的核心数据结构是什么？⭐⭐

### 一句话结论
ObjectMonitor 包含 **_owner**(持锁线程)、**_EntryList**(阻塞队列)、**_cxq**(竞争队列)、**_WaitSet**(wait 队列)，三个队列配合实现 synchronized 语义。

### 源码级回答

```cpp
class ObjectMonitor {
    volatile markOop _header;     // 保存的原始 markWord (displaced header)
    volatile void*   _object;     // 关联的 Java 对象

    // === 核心锁状态 ===
    void* volatile   _owner;      // 当前持锁线程 (Thread* 或 BasicLock*)
    volatile int     _recursions;  // 重入次数

    // === 三个队列 ===
    ObjectWaiter* volatile _cxq;       // 竞争栈 (LIFO，新来的线程入栈)
    ObjectWaiter* volatile _EntryList; // 入口列表 (FIFO，等待获锁的线程)
    ObjectWaiter* volatile _WaitSet;   // wait 队列 (调用 wait() 的线程)

    // === 自旋相关 ===
    volatile int _SpinDuration;    // 自适应自旋次数 (初始 0，最大 5000)
};
```

**三个队列的关系:**
```
            synchronized 竞争
                  │
                  ▼
               _cxq (栈, LIFO)
                  │
                  │ enter() 失败后
                  ▼
            _EntryList (链表)
                  │
                  │ exit() 唤醒
                  ▼
              获得 _owner
                  │
                  │ wait()
                  ▼
             _WaitSet (双向环形链表)
                  │
                  │ notify()/notifyAll()
                  ▼
          移回 _EntryList 或 _cxq
```

> 📖 详细文档: `Phase3/3.8_objectmonitor_analysis.md`

---

## Q3: ObjectMonitor::enter() 的详细流程是什么？⭐⭐⭐

### 一句话结论
**CAS 快速路径 → 递归检测 → 自适应自旋 → EnterI 慢速路径(park 循环)**，层层递进，尽量避免线程阻塞。

### 源码级回答

```cpp
void ObjectMonitor::enter(TRAPS) {
    // === 1. CAS 快速路径 ===
    if (Atomic::cmpxchg(_owner, NULL, Self) == NULL) {
        return;  // 成功! 无竞争
    }

    // === 2. 递归检测 ===
    if (_owner == Self) {
        _recursions++;
        return;  // 重入
    }

    // === 3. 自适应自旋 (TrySpin) ===
    if (TrySpin(Self) > 0) {
        return;  // 自旋成功获锁
    }

    // === 4. EnterI 慢速路径 ===
    EnterI(THREAD);
}

void ObjectMonitor::EnterI(TRAPS) {
    // 4.1 创建 ObjectWaiter 节点
    ObjectWaiter node(Self);

    // 4.2 CAS 入 _cxq 栈
    for (;;) {
        node._next = _cxq;
        if (Atomic::cmpxchg(&_cxq, node._next, &node) == node._next)
            break;
    }

    // 4.3 park 循环
    for (;;) {
        TryLock(Self);       // 再试一次
        if (_owner == Self) break;

        park(Self);          // 阻塞! 等待被唤醒

        TryLock(Self);       // 被唤醒后再试
        if (_owner == Self) break;
    }
}
```

> 📖 详细文档: `Runtime/ch03_lock_optimization.md`

---

## Q4: 自适应自旋是怎么实现的？⭐⭐⭐

### 一句话结论
**TATAS 协议 + 指数退避 + 奖惩机制**：自旋成功 → 增加下次自旋次数，自旋失败 → 减少或归零。

### 源码级回答

**TrySpin 自适应算法:**
```
1. 读 _SpinDuration (初始 0，首次自旋由 Knob_FixedSpin=0 决定)
2. 自旋循环:
   for (i = SpinDuration; i > 0; i--) {
       if (_owner == NULL) {
           CAS(_owner, NULL, Self);
           if 成功 → 奖励: _SpinDuration = MIN(_SpinDuration + Knob_BonusB, Knob_SpinLimit)
           return;
       }
       SpinPause();  // x86: rep nop (PAUSE 指令，降低功耗 + 避免流水线惩罚)
   }
3. 自旋失败 → 惩罚: _SpinDuration = MAX(_SpinDuration - Knob_Penalty, 0)
```

**关键参数:**
```
Knob_SpinLimit  = 5000   // 最大自旋次数
Knob_BonusB     = 100    // 成功奖励增量
Knob_Penalty    = 200    // 失败惩罚减量
Knob_FixedSpin  = 0      // 初始自旋次数
```

**为什么是自适应?**
- 锁持有时间短 → 自旋成功概率高 → 奖励增加自旋次数
- 锁持有时间长 → 自旋浪费 CPU → 惩罚减少自旋次数
- 最终 `_SpinDuration` 会收敛到一个合适的值

> 📖 详细文档: `Runtime/ch03_lock_optimization.md`

---

## Q5: wait() 和 notify() 的底层实现是什么？⭐⭐

### 一句话结论
`wait()` = **释放锁 + 进入 WaitSet + park 阻塞**，`notify()` = **从 WaitSet 取一个 → 移到 EntryList/cxq → unpark**。

### 源码级回答

**Object.wait() 流程:**
```cpp
void ObjectMonitor::wait(jlong millis, TRAPS) {
    // 1. 创建 ObjectWaiter 节点
    ObjectWaiter node(Self);

    // 2. 加入 WaitSet (双向环形链表)
    AddWaiter(&node);

    // 3. 保存递归次数，释放锁
    intx save = _recursions;
    _recursions = 0;
    _owner = NULL;
    exit(true, Self);  // 完全释放锁!

    // 4. park 阻塞
    if (millis == 0) {
        park(Self);          // 无限等待
    } else {
        park(Self, millis);  // 超时等待
    }

    // 5. 被唤醒后，重新获取锁
    enter(Self);            // 可能再次竞争!

    // 6. 恢复递归次数
    _recursions = save;
}
```

**Object.notify() 流程:**
```cpp
void ObjectMonitor::notify(TRAPS) {
    // 从 WaitSet 取队头
    ObjectWaiter* iterator = DequeueWaiter();
    if (iterator == NULL) return;  // WaitSet 空

    // 按 Policy 决定放到哪里:
    // Policy 0: 放到 _EntryList 头部
    // Policy 1: 放到 _EntryList 尾部
    // Policy 2: 放到 _cxq 头部 (默认)
    // 不立即唤醒! 等当前线程释放锁时才 unpark
}
```

**关键点:**
- `wait()` 必须**完全释放锁**（包括重入次数）
- `notify()` 不会立即让等待线程运行，只是移到竞争队列
- 被 `notify()` 的线程还要和新来的线程竞争锁

> 📖 详细文档: `Runtime/ch03_lock_optimization.md`

---

## Q6: inflate() 膨胀过程是什么？markWord 怎么变化？⭐⭐⭐

### 一句话结论
`inflate()` 分配一个 `ObjectMonitor`，将原始 markWord 保存到 `_header`，然后将对象的 markWord **CAS 替换为 ObjectMonitor 指针**（lock bits = 10）。

### 源码级回答

**四种进入 inflate 的 case:**
```cpp
ObjectMonitor* ObjectSynchronizer::inflate(Thread* self, oop obj) {
    for (;;) {
        markOop mark = obj->mark();

        // Case 1: 已经膨胀 (mark 指向 ObjectMonitor)
        if (mark->has_monitor()) {
            return mark->monitor();  // 直接返回
        }

        // Case 2: 正在膨胀 (INFLATING 中间态)
        if (mark == markOopDesc::INFLATING()) {
            spin_wait();  // 自旋等待其他线程完成膨胀
            continue;
        }

        // Case 3: 轻量级锁 → 膨胀
        if (mark->has_locker()) {
            ObjectMonitor* m = new ObjectMonitor();
            // 先 CAS 设为 INFLATING 占位
            if (CAS(mark, INFLATING)) {
                m->_header = mark->displaced_header();
                m->_owner = mark->locker();  // 当前持锁者
                obj->set_mark(markOopDesc::encode(m));  // lock:10
                return m;
            }
            continue;
        }

        // Case 4: 无锁 → 膨胀
        ObjectMonitor* m = new ObjectMonitor();
        m->_header = mark;  // 保存原始 markWord
        if (CAS(obj->mark_addr(), mark, markOopDesc::encode(m))) {
            return m;
        }
    }
}
```

**markWord 变化:**
```
无锁:   [hashcode:31 | age:4 | 0 | 01] → [ObjectMonitor* | 10]
轻量级: [BasicLock*         | 00] → [INFLATING | 00] → [ObjectMonitor* | 10]
```

**INFLATING 中间态:**
- 防止多线程同时膨胀同一个对象
- 其他线程看到 INFLATING 就自旋等待
- 类似于一个微型的 CAS-spin 协议

> 📖 详细文档: `Runtime/ch03_lock_optimization.md`

---

## Q7: ObjectMonitor::exit() 怎么唤醒后继者？⭐⭐⭐

### 一句话结论
`exit()` 释放 `_owner` 后，按 **QMode 策略** 从 _cxq/_EntryList 中选一个线程 unpark 唤醒，策略影响公平性和吞吐量。

### 源码级回答

```cpp
void ObjectMonitor::exit(bool not_suspended, TRAPS) {
    // 1. 递归退出
    if (_recursions > 0) { _recursions--; return; }

    // 2. 释放 _owner
    _owner = NULL;
    OrderAccess::release();  // StoreLoad 屏障

    // 3. 快速检查: 没人等 → 直接返回
    if (_cxq == NULL && _EntryList == NULL) return;

    // 4. QMode 策略选择后继者
    // QMode = 2 (默认): 优先从 _cxq 取
    if (QMode == 2 && _cxq != NULL) {
        ObjectWaiter* w = _cxq;
        // CAS 弹出 _cxq 头
        ExitEpilog(Self, w);  // unpark(w->_thread)
        return;
    }

    // 5. _cxq 转移到 _EntryList
    // 然后从 _EntryList 取队头
    ObjectWaiter* w = _EntryList;
    ExitEpilog(Self, w);  // unpark
}
```

**QMode 策略:**
| QMode | 行为 | 特点 |
|-------|------|------|
| 0 | _cxq 反转后放入 _EntryList | 近似 FIFO |
| 2 | 优先 _cxq 头部 (默认) | 偏向最近到达的线程 |
| 3 | _cxq 直接拼到 _EntryList 尾部 | 严格 FIFO |
| 4 | _cxq 直接拼到 _EntryList 头部 | LIFO |

> 📖 详细文档: `Runtime/ch03_lock_optimization.md`

---

## Q8: synchronized 和 ReentrantLock 的区别？从 JVM 层面看 ⭐⭐

### 一句话结论
`synchronized` 是 JVM 内置的 ObjectMonitor 实现，`ReentrantLock` 是 Java 层 AQS 框架。底层都用 `park/unpark`，但 synchronized 有 JIT 锁优化（锁消除/粗化/自适应自旋）。

### 源码级回答

| 维度 | synchronized | ReentrantLock |
|------|-------------|---------------|
| 实现层 | JVM C++ (ObjectMonitor) | Java (AbstractQueuedSynchronizer) |
| 锁升级 | 轻量级→重量级 | 无升级，直接 CAS + park |
| 自旋 | 自适应 (TATAS + 奖惩) | tryAcquire CAS 一次 |
| 等待队列 | _cxq + _EntryList + _WaitSet | CLH 变体队列 |
| 条件变量 | wait/notify (单条件) | Condition (多条件) |
| 公平性 | 非公平 (QMode 策略) | 可选公平/非公平 |
| 中断 | 不支持中断获锁 | lockInterruptibly() |
| 超时 | 不支持 | tryLock(timeout) |
| JIT 优化 | ✅ 锁消除/粗化/偏向锁 | ❌ 不做锁层面优化 |
| 阻塞原语 | os::PlatformEvent::park (pthread_cond) | LockSupport.park (也是 pthread_cond) |

**两者最终都落到:**
```cpp
// os_linux.cpp
os::PlatformEvent::park() {
    pthread_mutex_lock(&_mutex);
    while (_event <= 0) {
        pthread_cond_wait(&_cond, &_mutex);
    }
    _event = 0;
    pthread_mutex_unlock(&_mutex);
}
```

> 📖 详细文档: `Runtime/ch03_lock_optimization.md`, `Thread/ch04_parker_thread_exit.md`

---

## Q9: 什么是锁消除？什么是锁粗化？⭐⭐

### 一句话结论
**锁消除**: 逃逸分析发现锁对象不逃逸 → 移除 synchronized。**锁粗化**: 循环内多次加锁解锁 → 合并为循环外一次加锁。

### 源码级回答

**锁消除 (C2 EliminateLocks):**
```java
// 源码
void foo() {
    Object lock = new Object();  // 不逃逸!
    synchronized (lock) {        // 逃逸分析: lock 是 NoEscape
        counter++;
    }
}

// 锁消除后 (C2 编译)
void foo() {
    counter++;  // synchronized 完全移除
}
```

**锁粗化 (C2 编译器):**
```java
// 源码 — 循环内反复加锁
for (int i = 0; i < 100; i++) {
    synchronized (this) {
        list.add(i);
    }
}

// 锁粗化后
synchronized (this) {
    for (int i = 0; i < 100; i++) {
        list.add(i);
    }
}
```

**JVM 参数:**
```
-XX:+EliminateLocks      # 锁消除 (默认开)
-XX:+DoEscapeAnalysis    # 逃逸分析 (锁消除前提)
```

> 📖 详细文档: `C2Compiler/escape_analysis.md`, `Runtime/ch03_lock_optimization.md`

---

## Q10: wait() 为什么必须在 synchronized 块内调用？⭐

### 一句话结论
`wait()` 需要**释放 ObjectMonitor 的 _owner**，如果不在 synchronized 块内，没有持有 Monitor，释放什么？JVM 会直接抛出 `IllegalMonitorStateException`。

### 源码级回答

```cpp
void ObjectMonitor::wait(jlong millis, TRAPS) {
    // 第一行就检查!
    if (Self != _owner) {
        THROW(vmSymbols::java_lang_IllegalMonitorStateException());
    }
    // ... 释放锁 + park
}
```

**更深层的原因 — 避免 lost wakeup:**
```java
// 如果 wait/notify 不需要锁:
// Thread A:
if (!condition) {
    // ← Thread B 在这里执行 notify()，但 A 还没 wait!
    wait();  // A 永远等不到 notify → 丢失唤醒!
}

// 有锁保护:
synchronized (lock) {
    while (!condition) {  // while 循环防止虚假唤醒
        lock.wait();      // 释放锁，原子地进入等待
    }
}
```

> 📖 详细文档: `Runtime/ch03_lock_optimization.md`

---

## Q11: notify() 和 notifyAll() 有什么区别？JVM 里怎么实现？⭐

### 一句话结论
`notify()` 从 WaitSet 取**一个**线程移到竞争队列，`notifyAll()` 将 WaitSet **全部**移到竞争队列。被移动的线程不会立即执行，还要重新竞争锁。

### 源码级回答

```cpp
// notify: 取一个
void ObjectMonitor::notify(TRAPS) {
    ObjectWaiter* w = DequeueWaiter();  // 取 WaitSet 头
    // 放入 _EntryList 或 _cxq (按 Policy)
}

// notifyAll: 全部移动
void ObjectMonitor::notifyAll(TRAPS) {
    for (;;) {
        ObjectWaiter* w = DequeueWaiter();
        if (w == NULL) break;
        // 逐个放入 _EntryList 或 _cxq
    }
}
```

**为什么推荐 notifyAll?**
- notify 只唤醒一个 → 如果这个线程不关心当前条件 → 条件没人处理
- notifyAll 唤醒所有 → 每个线程都检查条件 → 至少有一个能处理

> 📖 详细文档: `Runtime/ch03_lock_optimization.md`

---

## 🎯 面试话术建议

### 如何展示锁机制的源码功底:

> "我看过 HotSpot 的 ObjectMonitor 源码。enter() 的流程是先 CAS `_owner`，失败后做自适应自旋——TrySpin 用的是 TATAS 协议加指数退避，自旋次数有奖惩机制，成功+100，失败-200，上限 5000。自旋也失败就走 EnterI，创建 ObjectWaiter 节点 CAS 入 `_cxq` 栈，然后 park 循环等待被 unpark。"

> "exit() 释放锁后按 QMode 策略选后继者。默认 QMode=2 优先从 _cxq 取，这意味着最新到达的线程更容易拿到锁——非公平但吞吐高。wait() 是释放锁后进入 WaitSet 双向环形链表，notify() 把节点移回竞争队列，不是立即唤醒。"

> "inflate() 膨胀过程有个巧妙的 INFLATING 中间态——先 CAS 把 markWord 设为 INFLATING 占位，然后安全地初始化 ObjectMonitor，最后替换为 Monitor 指针。这防止了多线程同时膨胀同一个对象。"
