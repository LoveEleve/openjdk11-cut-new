# Chapter 3: 锁优化与升级链路 — 从轻量级锁到重量级锁

> **系列**：Runtime System — 对象生命周期  
> **环境**：OpenJDK 11, `-Xms8g -Xmx8g -XX:+UseG1GC -XX:-UseBiasedLocking`, LP64  
> **约定**：本文全部分析**排除偏向锁**（JDK 15 废弃, JDK 18 默认关闭, JDK 25 移除）

---

## 1. 问题引入：为什么需要锁优化？

Java 的 `synchronized` 最终依赖操作系统的互斥量（mutex），涉及用户态→内核态切换，代价约几微秒。但实际应用中：

- **绝大多数锁没有竞争** — 一个线程反复进出同一个 synchronized 块
- **竞争短暂** — 即使有竞争，持锁时间通常很短，自旋等一下就能拿到
- **真正长时间排队的场景很少** — 只有高竞争才需要 OS 级阻塞

因此 HotSpot 设计了**三级锁模型**（去掉偏向锁后为两级），用最小开销处理最常见场景：

```
┌──────────────────────┐     竞争出现      ┌──────────────────────┐
│   轻量级锁 (00)      │ ──────────────→ │   重量级锁 (10)      │
│   CAS + 栈上 BasicLock│                  │   ObjectMonitor      │
│   ~10ns, 无系统调用   │                  │   自适应自旋 + park   │
└──────────────────────┘                  └──────────────────────┘
          ↑                                        │
  mark == 01 (无锁)                     safepoint 时 deflate 回无锁
```

关键设计原则：**膨胀是单向的**（轻量→重量），**缩回只能在 safepoint**。

---

## 2. 锁状态编码回顾

> 源码：`src/hotspot/share/oops/markOop.hpp`

64-bit mark word 的最低 2 bit 编码锁状态：

| lock bits | 状态 | mark word 含义 |
|-----------|------|----------------|
| `01` | 无锁 (neutral) | `unused:25 | hash:31 | cms:1 | age:4 | 0:1 | 01` |
| `00` | 轻量级锁 (stack-locked) | `ptr_to_BasicLock:62 | 00` |
| `10` | 重量级锁 (monitor) | `ptr_to_ObjectMonitor:62 | 10` |
| `11` | GC 标记 (marked) | 转发指针 |

无锁状态的 prototype 值为 `0x0000000000000001`（只有最低 bit 为 1）。

---

## 3. 轻量级锁：解释器快速路径

### 3.1 monitorenter 的 x86 汇编快速路径

> 源码：`src/hotspot/cpu/x86/interp_masm_x86.cpp:1152-1234` — `lock_object()`

当解释器执行 `monitorenter` 字节码时，调用 `InterpreterMacroAssembler::lock_object()`。排除偏向锁后，核心逻辑只有 **4 步**：

**步骤 1：准备 displaced header**

```cpp
// 将 1 加载到 swap_reg (rax)
movl(swap_reg, (int32_t)1);
// 用 OR 计算 (object->mark() | 1)，确保最低 bit 为 1（无锁态标志）
orptr(swap_reg, Address(obj_reg, oopDesc::mark_offset_in_bytes()));
// 将 (mark | 1) 保存到 BasicLock 的 displaced_header 字段
movptr(Address(lock_reg, mark_offset), swap_reg);
```

为什么 `mark | 1`？因为无锁态的 mark 最低 bit 本就是 1（`lock:01`），OR 1 是个恒等操作，相当于直接复制 mark word。但如果 mark 恰好是其他状态，OR 1 可以确保 displaced header 看起来像无锁态。

**步骤 2：CAS 尝试加锁**

```cpp
// lock cmpxchg: 原子地尝试将对象头的 mark word 替换为指向 BasicLock 的指针
if (os::is_MP()) lock();
cmpxchgptr(lock_reg, Address(obj_reg, oopDesc::mark_offset_in_bytes()));
jcc(Assembler::zero, done);  // CAS 成功 → 加锁完成
```

CAS 成功意味着：对象的 mark word 从 `原始mark(末尾01)` 变成了 `指向BasicLock的指针(末尾00)`，锁状态从无锁变为轻量级锁。

**步骤 3：CAS 失败 — 检查是否递归**

```cpp
// CAS 失败后，rax 中是 mark word 的旧值（CAS 返回值）
// 检查这个旧值是否指向当前线程的栈帧（即递归加锁）
subptr(swap_reg, rsp);
andptr(swap_reg, zero_bits - os::vm_page_size());
// 如果结果为 0，说明 mark 指向的 BasicLock 在当前栈帧范围内 → 递归
movptr(Address(lock_reg, mark_offset), swap_reg);  // 递归时存 0
jcc(Assembler::zero, done);
```

递归检测的巧妙之处：`(mark - rsp) & (7 - page_size)` 检查 mark 值是否在当前栈指针附近。如果 mark 指向当前线程栈上的某个 BasicLock，差值很小，AND 操作后为 0。递归时将 displaced_header 设为 **NULL (0)**，表示"这是一个递归锁记录"。

**步骤 4：都失败 → 慢速路径**

```cpp
bind(slow_case);
call_VM(noreg, CAST_FROM_FN_PTR(address, InterpreterRuntime::monitorenter), lock_reg);
```

### 3.2 monitorenter 慢速路径：slow_enter

> 源码：`src/hotspot/share/runtime/synchronizer.cpp:339-368`

当汇编快速路径失败时，进入 C++ 慢速路径：

```cpp
void ObjectSynchronizer::slow_enter(Handle obj, BasicLock* lock, TRAPS) {
  markOop mark = obj->mark();

  if (mark->is_neutral()) {
    // 情况 1：无锁态 → 再试一次 CAS
    lock->set_displaced_header(mark);
    if (mark == obj()->cas_set_mark((markOop) lock, mark)) {
      return;  // 成功
    }
    // CAS 失败 → fall through 到 inflate
  } else if (mark->has_locker() &&
             THREAD->is_lock_owned((address)mark->locker())) {
    // 情况 2：已被当前线程轻量级锁定 → 递归
    lock->set_displaced_header(NULL);  // 递归标记
    return;
  }

  // 情况 3：存在竞争 → 膨胀为重量级锁
  lock->set_displaced_header(markOopDesc::unused_mark());  // 0x3
  ObjectSynchronizer::inflate(THREAD, obj(), inflate_cause_monitor_enter)->enter(THREAD);
}
```

注意 `unused_mark()` 的值是 `0x3`（即 `lock:11`），它既不是 NULL（递归标记）也不是合法的 mark word，表示"这个 BasicLock 从未持有过轻量级锁"。

### 3.3 monitorexit 的 x86 汇编快速路径

> 源码：`src/hotspot/cpu/x86/interp_masm_x86.cpp:1249-1308` — `unlock_object()`

解锁是加锁的逆过程，同样分快/慢两路：

```cpp
// 从 BasicLock 读取 displaced header
movptr(header_reg, Address(swap_reg, BasicLock::displaced_header_offset_in_bytes()));

// 如果 displaced header 为 NULL → 递归解锁，直接返回
testptr(header_reg, header_reg);
jcc(Assembler::zero, done);

// CAS：尝试将 displaced header 换回对象头
if (os::is_MP()) lock();
cmpxchgptr(header_reg, Address(obj_reg, oopDesc::mark_offset_in_bytes()));
jcc(Assembler::zero, done);  // 成功 → 解锁完成

// CAS 失败 → 慢速路径（锁已膨胀）
call_VM(noreg, CAST_FROM_FN_PTR(address, InterpreterRuntime::monitorexit), lock_reg);
```

### 3.4 monitorexit 慢速路径：fast_exit

> 源码：`src/hotspot/share/runtime/synchronizer.cpp:282-332`

```cpp
void ObjectSynchronizer::fast_exit(oop object, BasicLock* lock, TRAPS) {
  markOop dhw = lock->displaced_header();
  
  if (dhw == NULL) {
    return;  // 递归解锁 — 什么都不用做
  }

  markOop mark = object->mark();
  if (mark == (markOop) lock) {
    // 对象仍是轻量级锁定，CAS 换回原始 mark
    if (object->cas_set_mark(dhw, mark) == mark) {
      return;
    }
  }

  // CAS 失败或已膨胀 → inflate + exit
  ObjectSynchronizer::inflate(THREAD, object, inflate_cause_vm_internal)->exit(true, THREAD);
}
```

---

## 4. 锁膨胀：inflate()

### 4.1 什么时候触发膨胀？

膨胀发生在以下场景：
1. **轻量级锁竞争** — `slow_enter()` 中 CAS 失败且不是递归
2. **解锁时发现已膨胀** — `fast_exit()` 中 CAS 失败
3. **调用 hashCode()** — 轻量级锁定的对象没有 hash 存储空间，必须膨胀到 ObjectMonitor 的 `_header` 中存储
4. **调用 wait()/notify()** — 这些操作需要 ObjectMonitor 的 WaitSet

### 4.2 inflate() 四种 case

> 源码：`src/hotspot/share/runtime/synchronizer.cpp:1387-1583`

`inflate()` 是一个无限循环，每次迭代根据 mark word 的状态分四种情况：

**Case 1：已膨胀（has_monitor）— 直接返回**

```cpp
if (mark->has_monitor()) {
    ObjectMonitor * inf = mark->monitor();
    return inf;
}
```

**Case 2：正在膨胀（INFLATING = 0）— 自旋等待**

```cpp
if (mark == markOopDesc::INFLATING()) {
    ReadStableMark(object);  // 自旋/yield/park 等待膨胀完成
    continue;
}
```

`ReadStableMark()` 的策略：先自旋 10000 次，然后交替 yield 和 muxAcquire（相当于 park）。

**Case 3：轻量级锁定（has_locker）— 执行膨胀**

这是最复杂的 case，包含一个精妙的两阶段协议：

```
阶段 1: CAS 将 mark word 设为 INFLATING (0)
阶段 2: 配置 ObjectMonitor → release_set_mark 安装 monitor 指针
```

具体流程：

```cpp
ObjectMonitor * m = omAlloc(Self);       // 预先分配 monitor
m->Recycle();
m->_SpinDuration = Knob_SpinLimit;       // 初始自旋次数 = 5000

// 阶段 1：CAS 安装 INFLATING 标记
markOop cmp = object->cas_set_mark(markOopDesc::INFLATING(), mark);
if (cmp != mark) {
    omRelease(Self, m, true);            // CAS 失败，释放 monitor，重试
    continue;
}

// 阶段 2：此时只有本线程能完成膨胀
markOop dmw = mark->displaced_mark_helper();  // 从 BasicLock 获取原始 mark
m->set_header(dmw);                            // 保存原始 mark 到 monitor._header
m->set_owner(mark->locker());                  // 设置 owner 为 BasicLock 地址
m->set_object(object);                         // 反向指针
object->release_set_mark(markOopDesc::encode(m));  // 安装 monitor 指针
```

**为什么需要 INFLATING(0) 这个中间状态？** 考虑这个竞态：

- 线程 A 持有轻量级锁，mark 指向 A 的 BasicLock
- 线程 B 尝试膨胀，如果直接 CAS mark 到 monitor 指针...
- 线程 A 此时执行 monitorexit，尝试 CAS 将 displaced header 换回 mark
- 如果 B 的 CAS 先完成，A 的 CAS 会失败（预期值变了），A 会走慢速路径
- 但如果 B 还没把 displaced header 复制到 monitor._header，hashCode 就会丢失！

INFLATING(0) 解决了这个问题：
- B 先 CAS 安装 0，此时 A 的 CAS 一定失败（0 ≠ BasicLock 指针）
- A 走慢速路径进入 inflate()，发现 mark == INFLATING，调用 ReadStableMark() 等待
- B 安全地完成复制，然后安装最终的 monitor 指针
- A 重新读取 mark，发现已膨胀，返回 monitor

**Case 4：无锁态（neutral）— 直接膨胀**

```cpp
ObjectMonitor * m = omAlloc(Self);
m->set_header(mark);     // 保存原始 mark
m->set_owner(NULL);      // 无 owner（还没人持锁）
m->set_object(object);

if (object->cas_set_mark(markOopDesc::encode(m), mark) != mark) {
    // CAS 失败，释放 monitor，重试
    omRelease(Self, m, true);
    continue;
}
return m;
```

无锁态膨胀比轻量级锁态简单：不需要 INFLATING 中间状态，因为没有 owner 会同时修改 mark。

### 4.3 日志参数

```
-Xlog:monitorinflation=debug
```

输出示例：
```
[debug][monitorinflation] Inflating object 0x00000007156a7480 , mark 0x00007f4c6c0096ba , type java.lang.Object
[debug][monitorinflation] Deflating object 0x00000007156a7480 , mark 0x00000007156a74ba , type java.lang.Object
```

---

## 5. 重量级锁：ObjectMonitor::enter()

### 5.1 enter() 整体结构

> 源码：`src/hotspot/share/runtime/objectMonitor.cpp:265-419`

`enter()` 是获取重量级锁的入口，按照最常见到最少见的顺序排列检查：

```
enter() 流程图：
  │
  ├─ CAS _owner: NULL → Self         [最快路径: 无竞争]
  │    成功 → return
  │
  ├─ _owner == Self ?                 [递归]
  │    是 → _recursions++ → return
  │
  ├─ is_lock_owned(cur) ?             [owner 是栈上 BasicLock]
  │    是 → _owner = Self → return    [从 BasicLock 转换为 Thread*]
  │
  ├─ TrySpin(Self) > 0 ?              [自旋: 竞争可能很短]
  │    成功 → return
  │
  └─ 真正的竞争 → 进入 EnterI()       [需要 park]
       ├─ Atomic::inc(&_count)        [防止 deflate]
       ├─ 设置线程状态为 blocked
       ├─ for (;;) { EnterI(THREAD); }
       └─ Atomic::dec(&_count)
```

**第一步：CAS 抢锁**

```cpp
void * cur = Atomic::cmpxchg(Self, &_owner, (void*)NULL);
if (cur == NULL) {
    return;  // 无竞争，最快路径
}
```

**第二步：递归检查**

```cpp
if (cur == Self) {
    _recursions++;
    return;
}
```

**第三步：BasicLock 转换**

```cpp
if (Self->is_lock_owned((address)cur)) {
    _recursions = 1;
    _owner = Self;  // 从 BasicLock* 转换为 Thread*
    return;
}
```

这发生在轻量级锁刚膨胀时——`inflate()` 设置 `_owner = mark->locker()`（BasicLock 地址），第一次通过 enter() 时需要转换为 Thread 指针。

**第四步：早期自旋**

```cpp
if (Knob_SpinEarly && TrySpin(Self) > 0) {
    Self->_Stalled = 0;
    return;
}
```

`Knob_SpinEarly` 默认为 1，所以在排队之前先尝试自旋。

**第五步：进入 EnterI() 阻塞路径**

注意 `_count++` 的作用：防止 monitor 在竞争期间被 `deflate_idle_monitors()` 回收。

### 5.2 EnterI()：阻塞等待核心

> 源码：`src/hotspot/share/runtime/objectMonitor.cpp:442-665`

EnterI 是重量级锁竞争的核心，包含三个阶段：入队、等待、出队。

**阶段 1：再试一次**

```cpp
if (TryLock(Self) > 0) return;  // TATAS: Test-And-Test-And-Set
if (TrySpin(Self) > 0) return;  // 最后一次自旋机会
```

**阶段 2：入队到 _cxq**

```cpp
ObjectWaiter node(Self);
Self->_ParkEvent->reset();
node.TState = ObjectWaiter::TS_CXQ;

// CAS push 到 _cxq 头部（LIFO 栈）
for (;;) {
    node._next = nxt = _cxq;
    if (Atomic::cmpxchg(&node, &_cxq, nxt) == nxt) break;
    // CAS 失败时顺便再试一次 TryLock
    if (TryLock(Self) > 0) return;
}
```

`_cxq` 是一个**单链表 LIFO 栈**，使用 CAS push 实现无锁入队，支持多线程并发入队。

入队后检查是否需要成为 **Responsible 线程**：

```cpp
if (nxt == NULL && _EntryList == NULL) {
    Atomic::replace_if_null(Self, &_Responsible);
}
```

Responsible 线程使用 **定时 park** 而非无限 park，目的是检测"stranding"问题——某个线程释放锁时可能因为没有执行 MEMBAR 而导致等待线程永远不被唤醒。

**阶段 3：park/unpark 循环**

```cpp
for (;;) {
    if (TryLock(Self) > 0) break;

    // Responsible 线程用定时 park，其他线程用无限 park
    if (_Responsible == Self || (SyncFlags & 1)) {
        Self->_ParkEvent->park((jlong) recheckInterval);
        recheckInterval *= 8;  // 指数退避: 1ms → 8ms → 64ms → ... → MAX
        if (recheckInterval > MAX_RECHECK_INTERVAL) {
            recheckInterval = MAX_RECHECK_INTERVAL;
        }
    } else {
        Self->_ParkEvent->park();  // 无限等待，直到被 unpark
    }

    if (TryLock(Self) > 0) break;

    // 被唤醒后还可以再自旋一轮
    if ((Knob_SpinAfterFutile & 1) && TrySpin(Self) > 0) break;

    // 清理 _succ 标记
    if (_succ == Self) _succ = NULL;
    OrderAccess::fence();
}
```

**阶段 4：出队（获得锁后）**

```cpp
UnlinkAfterAcquire(Self, &node);
if (_succ == Self) _succ = NULL;
if (_Responsible == Self) {
    _Responsible = NULL;
    OrderAccess::fence();  // Dekker 协议的关键点
}
```

`UnlinkAfterAcquire()` 根据节点所在队列执行不同操作：
- 在 `_EntryList` 上：O(1) 的双链表删除
- 在 `_cxq` 上：可能需要 CAS（如果在头部）或线性扫描（如果在内部）

---

## 6. 重量级锁解锁：ObjectMonitor::exit()

### 6.1 exit() 整体结构

> 源码：`src/hotspot/share/runtime/objectMonitor.cpp:905-1229`

```
exit() 流程图：
  │
  ├─ _owner != Self ?
  │    ├─ is_lock_owned(_owner) → 转换 BasicLock → Thread*
  │    └─ 否则 → 非法状态，return
  │
  ├─ _recursions != 0 ?
  │    是 → _recursions-- → return        [递归解锁]
  │
  └─ for (;;) {                           [真正释放锁]
       ├─ release_store(&_owner, NULL)     [释放锁]
       ├─ storeload() fence               [确保可见性]
       ├─ 检查 _EntryList|_cxq == 0 或 _succ != NULL
       │    是 → return                    [无人等待 或 有接班人]
       │
       ├─ CAS 重新获取锁                   [需要唤醒后继者]
       │    失败 → return                  [其他线程抢到了]
       │
       └─ 根据 QMode 策略选择后继者 → ExitEpilog()
     }
```

### 6.2 ExitPolicy 0（默认策略）

默认 `Knob_ExitPolicy == 0`：

```cpp
// 先释放锁
OrderAccess::release_store(&_owner, (void*)NULL);
OrderAccess::storeload();

// 检查是否需要唤醒
if ((intptr_t(_EntryList)|intptr_t(_cxq)) == 0 || _succ != NULL) {
    return;  // 没人等，或者已有接班人 → 直接走
}

// 有人等待且无接班人 → 重新获取锁来唤醒后继者
if (!Atomic::replace_if_null(THREAD, &_owner)) {
    return;  // 其他线程已经抢到锁
}
```

**为什么释放后又要重新获取？** 因为操作 `_EntryList`/`_cxq` 需要持有锁的保护。只有 monitor owner 才能安全地修改 EntryList。

### 6.3 QMode 策略

QMode 决定如何从 `_cxq` 和 `_EntryList` 中选择后继者：

| QMode | 策略 | 效果 |
|-------|------|------|
| **0** (默认) | 先看 EntryList，空则 drain cxq 到 EntryList（保持 LIFO 顺序） | 后来的线程先唤醒 |
| **1** | drain cxq 到 EntryList，但**反转顺序**（LIFO → FIFO） | 先来的线程先唤醒 |
| **2** | cxq 优先于 EntryList，直接从 cxq 唤醒 | 最近到达的线程优先 |
| **3** | 把 cxq **追加**到 EntryList 末尾 | 先来先服务 |
| **4** | 把 cxq **前置**到 EntryList 头部 | 最近到达的线程优先 |

默认 QMode=0 的完整流程：

1. 检查 `_EntryList`：非空 → `ExitEpilog(Self, w)` 唤醒头节点
2. `_EntryList` 为空 → 检查 `_cxq`：也为空 → 循环顶部重试
3. `_cxq` 非空 → CAS detach 整个 `_cxq` → 转换为双链表设为 `_EntryList`
4. 如果 `_succ != NULL`（有自旋线程），则 `continue` 让自旋线程先拿
5. 最终从 `_EntryList` 头部取一个节点 → `ExitEpilog()`

### 6.4 ExitEpilog()：唤醒后继者

> 源码：`src/hotspot/share/runtime/objectMonitor.cpp:1282-1312`

```cpp
void ObjectMonitor::ExitEpilog(Thread * Self, ObjectWaiter * Wakee) {
    // 1. 设置 _succ（接班人），减少无效唤醒
    _succ = Knob_SuccEnabled ? Wakee->_thread : NULL;
    ParkEvent * Trigger = Wakee->_event;
    
    Wakee = NULL;  // 安全性：释放锁后不能再访问 Wakee

    // 2. 释放锁
    OrderAccess::release_store(&_owner, (void*)NULL);
    OrderAccess::fence();
    
    // 3. 唤醒后继者
    Trigger->unpark();
}
```

`_succ` 的作用是**无效唤醒节流 (Futile Wakeup Throttling)**：如果 `_succ` 非空，说明已经有一个"准接班人"被唤醒了，exit() 就不需要再唤醒另一个线程。这避免了多个线程同时被唤醒又只有一个能拿到锁的浪费。

---

## 7. 自适应自旋：TrySpin()

### 7.1 为什么需要自适应自旋？

固定次数的自旋有两个问题：
- 次数太少 → 本来再转几圈就能拿到锁，却去 park 了（代价几微秒）
- 次数太多 → 白白浪费 CPU

自适应自旋根据**历史成功率**动态调整自旋次数：成功多了就多转，失败多了就少转。

### 7.2 TrySpin() 完整解析

> 源码：`src/hotspot/share/runtime/objectMonitor.cpp:1869-2086`

TrySpin 的结构分为三部分：准入控制、自旋循环、结果反馈。

**Part 1：PreSpin（预热阶段）**

```cpp
for (ctr = Knob_PreSpin + 1; --ctr >= 0;) {   // Knob_PreSpin = 10
    if (TryLock(Self) > 0) {
        // 成功 → 奖励
        int x = _SpinDuration;
        if (x < Knob_SpinLimit) {               // Knob_SpinLimit = 5000
            if (x < Knob_Poverty) x = Knob_Poverty;  // Knob_Poverty = 1000
            _SpinDuration = x + Knob_BonusB;    // Knob_BonusB = 100
        }
        return 1;
    }
    SpinPause();  // x86 上是 PAUSE 指令
}
```

PreSpin 是短暂的预热自旋（10 次），即使 `_SpinDuration == 0` 也会执行，防止 `_SpinDuration` 变成"吸收态"——一旦为 0 就永远不自旋了。

**Part 2：准入控制**

```cpp
ctr = _SpinDuration;
if (ctr < Knob_SpinBase) ctr = Knob_SpinBase;  // Knob_SpinBase = 0
if (ctr <= 0) return 0;                         // _SpinDuration 太小，放弃

if (Knob_SuccRestrict && _succ != NULL) return 0;  // 已有接班人
if (Knob_OState && NotRunnable(Self, _owner)) return 0;  // owner 不在运行 → 别等了

if (MaxSpin >= 0 && _Spinner > MaxSpin) return 0;  // 自旋线程太多
Adjust(&_Spinner, 1);  // 注册为自旋线程
```

关键优化：如果锁的 owner 线程当前不在 CPU 上运行（OFFPROC），自旋是白费的，直接放弃。

**Part 3：自旋循环（TATAS + 指数退避）**

```cpp
while (--ctr >= 0) {
    // 每 256 次检查 safepoint
    if ((ctr & 0xFF) == 0) {
        if (SafepointMechanism::poll(Self)) goto Abort;
    }
    
    // 指数退避：减少缓存一致性流量
    if (ctr & msk) continue;
    ++hits;
    if ((hits & 0xF) == 0) {
        msk = ((msk << 2)|3) & BackOffMask;
    }
    
    // TATAS: 先读 _owner，非空则继续自旋
    Thread * ox = (Thread *) _owner;
    if (ox == NULL) {
        // 锁空闲 → CAS 尝试获取
        ox = (Thread*)Atomic::cmpxchg(Self, &_owner, (void*)NULL);
        if (ox == NULL) {
            // 成功！奖励 _SpinDuration
            _SpinDuration = min(x + Knob_Bonus, Knob_SpinLimit);
            return 1;
        }
        // CAS 失败 → 惩罚
        ctr -= caspty;
    }
    
    // owner 变了 → 惩罚
    if (ox != prv && prv != NULL) {
        ctr -= oxpty;
    }
    
    // owner 不在 CPU 上 → 放弃
    if (Knob_OState && NotRunnable(Self, ox)) goto Abort;
}
```

**TATAS (Test-And-Test-And-Set)** 的核心思想：先用普通读检查 `_owner` 是否为 NULL（不产生缓存一致性流量），只有看到 NULL 时才执行 CAS（产生写请求）。这大大减少了多核系统上的缓存 line 竞争。

**Part 4：结果反馈**

```cpp
// 自旋失败 → 惩罚 _SpinDuration
int x = _SpinDuration;
if (x > 0) {
    x -= Knob_Penalty;          // Knob_Penalty = 200
    if (x < 0) x = 0;
    _SpinDuration = x;
}
```

### 7.3 自适应参数总结

| 参数 | 默认值 | 含义 |
|------|--------|------|
| `Knob_SpinLimit` | 5000 | `_SpinDuration` 上限 |
| `Knob_Poverty` | 1000 | `_SpinDuration` 最低起步值（奖励时） |
| `Knob_Bonus` | 100 | 主循环自旋成功时的奖励增量 |
| `Knob_BonusB` | 100 | PreSpin 成功时的奖励增量 |
| `Knob_Penalty` | 200 | 自旋失败时的惩罚减量 |
| `Knob_PreSpin` | 10 | PreSpin 次数（固定） |
| `Knob_CASPenalty` | -1 | CAS 失败惩罚（-1 = abort） |
| `Knob_OXPenalty` | -1 | owner 变化惩罚（-1 = abort） |

自适应的核心机制：

```
自旋成功 → _SpinDuration += Bonus (100), 最大 SpinLimit (5000)
自旋失败 → _SpinDuration -= Penalty (200), 最小 0
CAS 失败 → 直接 abort (Knob_CASPenalty = -1)
Owner 切换 → 直接 abort (Knob_OXPenalty = -1)
```

每个 ObjectMonitor 维护自己的 `_SpinDuration`，新膨胀的 monitor 初始值为 `Knob_SpinLimit (5000)`。

---

## 8. Object.wait() / notify() / notifyAll()

### 8.1 wait() 完整流程

> 源码：`src/hotspot/share/runtime/objectMonitor.cpp:1416-1639`

`wait()` 的核心操作：释放锁 → 进入 WaitSet 等待 → 被通知后重新获取锁。

```
wait() 流程：
  │
  ├─ CHECK_OWNER()                         验证当前线程是 owner
  ├─ 检查中断：已中断 → throw InterruptedException
  │
  ├─ 创建 ObjectWaiter (TState = TS_WAIT)
  ├─ SpinAcquire(_WaitSetLock)             获取 WaitSet 自旋锁
  ├─ AddWaiter(&node)                      加入 WaitSet（循环双链表）
  ├─ SpinRelease(_WaitSetLock)
  │
  ├─ save = _recursions                    保存递归计数
  ├─ _waiters++
  ├─ _recursions = 0
  ├─ exit(true, Self)                      ← 完全释放锁！
  │
  ├─ park() / park(millis)                 ← 线程阻塞在这里
  │
  ├─ 被唤醒后：
  │    ├─ 如果仍在 WaitSet (TS_WAIT)       超时/中断唤醒
  │    │    └─ DequeueSpecificWaiter()     从 WaitSet 移除
  │    │
  │    ├─ 如果已被 notify 移到 EntryList/cxq
  │    │    └─ TState 已是 TS_ENTER/TS_CXQ
  │    │
  │    └─ 重新获取锁：
  │         ├─ TS_RUN → enter(Self)         直接竞争
  │         └─ TS_ENTER/TS_CXQ → ReenterI() 已在队列中，等待被唤醒
  │
  ├─ _recursions = save                    恢复递归计数
  ├─ _waiters--
  │
  └─ 如果不是被 notify 唤醒 且 被中断
       → throw InterruptedException
```

关键细节：

1. **WaitSet 由 `_WaitSetLock` 保护**：这是一个简单的自旋锁（`volatile int`），因为竞争极少——通常只有 owner 线程操作 WaitSet。

2. **exit() 完全释放锁**：将 `_recursions` 清零再 exit，不管当前递归了多少层。唤醒后恢复 `_recursions`。

3. **重入方式取决于 notify 策略**：
   - 如果 notify 设置 TState = TS_RUN（policy 4），wait 线程直接调 `enter()` 从零开始竞争
   - 如果 notify 把节点放到 EntryList/cxq（policy 0-3），wait 线程调 `ReenterI()` 复用已有的队列位置

### 8.2 notify() / INotify()

> 源码：`src/hotspot/share/runtime/objectMonitor.cpp:1649-1800`

`notify()` 从 WaitSet 取出**一个**线程，按策略转移到竞争队列：

```cpp
void ObjectMonitor::notify(TRAPS) {
    CHECK_OWNER();
    if (_WaitSet == NULL) return;  // 无人等待
    INotify(THREAD);
}
```

`INotify()` 的五种策略（由 `Knob_MoveNotifyee` 控制，默认值 **2**）：

| policy | 操作 | 效果 |
|--------|------|------|
| 0 | 前置到 EntryList 头部 | 被通知者优先获锁 |
| 1 | 追加到 EntryList 尾部 | 先来先服务 |
| **2** (默认) | 推入 cxq 前端 | 类似入队，和新到达的竞争者混合 |
| 3 | 追加到 cxq 尾部 | 先来先服务（含竞争者） |
| 4 | 直接 unpark，设为 TS_RUN | 最积极：立即唤醒 |

默认 policy=2 的特殊处理：

```cpp
if (policy == 2) {
    if (list == NULL) {
        // EntryList 为空 → 直接放入 EntryList（最优化）
        iterator->_next = iterator->_prev = NULL;
        _EntryList = iterator;
    } else {
        // EntryList 非空 → CAS 推入 _cxq 前端
        iterator->TState = ObjectWaiter::TS_CXQ;
        for (;;) {
            ObjectWaiter * front = _cxq;
            iterator->_next = front;
            if (Atomic::cmpxchg(iterator, &_cxq, front) == front) break;
        }
    }
}
```

**notifyAll()** 就是循环调用 INotify()：

```cpp
void ObjectMonitor::notifyAll(TRAPS) {
    CHECK_OWNER();
    while (_WaitSet != NULL) {
        INotify(THREAD);
    }
}
```

---

## 9. 三个队列的关系

ObjectMonitor 维护三个线程队列，它们之间的关系如下：

```
                      ┌──────────────────────────────────────────────┐
                      │              ObjectMonitor                    │
                      ├──────────────────────────────────────────────┤
                      │                                              │
  新到达的竞争线程 ──→ │  _cxq (单链表 LIFO)                          │
  (CAS push)          │    ┌───┐ → ┌───┐ → ┌───┐ → NULL            │
                      │    │ C │   │ B │   │ A │                     │
                      │    └───┘   └───┘   └───┘                     │
                      │       │                                      │
                      │  exit() 时 drain ↓                            │
                      │                                              │
                      │  _EntryList (双链表)                          │
                      │    ┌───┐ ⇄ ┌───┐ ⇄ ┌───┐                   │
                      │    │ D │   │ E │   │ F │                     │
                      │    └───┘   └───┘   └───┘                     │
                      │       │                                      │
                      │  ExitEpilog() unpark ↓ 头节点                 │
                      │                                              │
                      │  _WaitSet (循环双链表)                        │
                      │    ┌───┐ ⇄ ┌───┐ ⇄ ┌───┐                   │
                      │    │ G │   │ H │   │ I │  ──→ 回到 G        │
                      │    └───┘   └───┘   └───┘                     │
                      │       │                                      │
                      │  notify()/INotify() → 转移到 EntryList/cxq   │
                      └──────────────────────────────────────────────┘
```

**三个队列的特征**：

| 队列 | 数据结构 | 入队方式 | 出队方式 | 保护机制 |
|------|----------|----------|----------|----------|
| `_cxq` | 单链表 LIFO | CAS push（多线程并发） | owner detach（单线程） | CAS 无锁 |
| `_EntryList` | 双链表 DLL | owner 从 cxq drain | owner 取头节点 | monitor 自身 |
| `_WaitSet` | 循环双链表 CDLL | wait() 加入 | notify() 取出 | _WaitSetLock 自旋锁 |

**为什么需要两个竞争队列 (_cxq + _EntryList)？**

核心原因是**降低 monitor 元数据操作的开销**：
- `_cxq` 只需要支持 CAS push（单链表即可），让新线程以最低开销入队
- `_EntryList` 是双链表，支持 O(1) 的任意位置删除（获取锁后需要从中移除自己）
- owner 在 exit() 时将 `_cxq` 批量转移到 `_EntryList`，分摊了链表维护开销

---

## 10. Monitor 缩减：deflate_idle_monitors()

### 10.1 触发条件

> 源码：`src/hotspot/share/runtime/synchronizer.cpp:1586-1663`

Monitor 缩减发生在每个 **safepoint**，遍历所有 in-use monitor，将空闲的回收到全局 free list。

### 10.2 判断空闲的条件：is_busy()

```cpp
intptr_t is_busy() const {
    return _count | _waiters | intptr_t(_owner) | intptr_t(_cxq) | intptr_t(_EntryList);
}
```

只要以下任一条件成立，monitor 就算"忙碌"：
- `_count != 0` — 有线程正在 enter() 的竞争路径中
- `_waiters != 0` — 有线程在 wait()
- `_owner != NULL` — 有人持锁
- `_cxq != NULL` — 有新到达的竞争者
- `_EntryList != NULL` — 有排队的竞争者

### 10.3 缩减操作

```cpp
bool ObjectSynchronizer::deflate_monitor(ObjectMonitor* mid, oop obj, ...) {
    if (mid->is_busy()) {
        return false;  // 还在使用
    }
    
    // 恢复对象头为原始 mark word
    obj->release_set_mark(mid->header());
    mid->clear();
    
    // 将 monitor 放入 free list
    *freeTailp->FreeNext = mid;
    *freeTailp = mid;
    return true;
}
```

缩减后对象的 mark word 恢复为无锁态（`01`），包含原始的 hashCode 和 age。

---

## 11. 完整的锁升级场景

下面用一个完整的例子展示从无锁到重量级锁的全过程：

```java
Object lock = new Object();

// 场景：线程 A 和 B 竞争同一个锁
// 线程 A:
synchronized (lock) {    // ① 轻量级锁
    // 此时线程 B 也尝试进入 ↓
    Thread.sleep(100);   // ③ 持锁期间 B 在等
}                        // ⑤ 解锁（已膨胀，走 ObjectMonitor::exit）

// 线程 B:
synchronized (lock) {    // ② CAS 失败 → slow_enter → inflate → enter
    // ...               // ⑥ B 获得锁
}
```

**时间线**：

```
时间 →

线程 A:  [new Object]     [monitorenter]          [sleep]          [monitorexit]
         mark=0x1(无锁)   mark→BasicLock_A(00)                    inflate→exit
                                                                   唤醒 B
线程 B:                                   [monitorenter]
                                          CAS 失败
                                          slow_enter()
                                          inflate() → Case 3(栈锁)
                                          INFLATING → copy displaced header
                                          mark→ObjectMonitor(10)
                                          ObjectMonitor::enter()
                                          CAS _owner 失败
                                          TrySpin() 失败
                                          EnterI() → push to _cxq → park()
                                                                          [被唤醒]
                                                                          TryLock 成功
                                                                          [获得锁]
```

---

## 12. 性能层级总结

| 操作 | 指令数 | 延迟 | 涉及系统调用 |
|------|--------|------|-------------|
| 轻量级锁加锁 | ~10 条 x86 | ~10ns | 无 |
| 轻量级锁解锁 | ~8 条 x86 | ~8ns | 无 |
| 重量级锁无竞争 enter | 1 次 CAS | ~20ns | 无 |
| 重量级锁自旋成功 | N × (LD + CAS) | ~1-50μs | 无 |
| 重量级锁 park/unpark | futex 系统调用 | ~5-10μs | 有（内核态切换） |
| 锁膨胀 | omAlloc + 2×CAS | ~100ns-1μs | 无 |

---

## 13. GDB 验证指南

### 13.1 观察锁状态变化

```bash
# 编译测试程序
cat > /data/workspace/demo/src/com/wjcoder/Main.java << 'EOF'
package com.wjcoder;
public class Main {
    static Object lock = new Object();
    public static void main(String[] args) throws Exception {
        // 制造竞争
        Thread t = new Thread(() -> {
            synchronized (lock) {
                try { Thread.sleep(5000); } catch (Exception e) {}
            }
        });
        t.start();
        Thread.sleep(100); // 确保 t 先拿到锁
        synchronized (lock) {
            System.out.println("Got lock");
        }
    }
}
EOF
```

### 13.2 观察 ObjectMonitor 字段

```gdb
# 在 inflate 完成后断点
break ObjectSynchronizer::inflate
commands
  silent
  printf "inflate called, cause=%d\n", cause
  continue
end

# 在 ObjectMonitor::enter 断点
break ObjectMonitor::enter
commands
  silent
  printf "enter: _owner=%p, _recursions=%ld, _count=%d\n", _owner, _recursions, _count
  printf "  _cxq=%p, _EntryList=%p, _succ=%p\n", _cxq, _EntryList, _succ
  printf "  _SpinDuration=%d, _Spinner=%d\n", _SpinDuration, _Spinner
  continue
end

# 在 exit 断点
break ObjectMonitor::exit
commands
  silent
  printf "exit: _owner=%p, _recursions=%ld\n", _owner, _recursions
  printf "  _EntryList=%p, _cxq=%p, _succ=%p\n", _EntryList, _cxq, _succ
  continue
end
```

### 13.3 观察自旋行为

```gdb
# 在 TrySpin 入口/出口断点
break ObjectMonitor::TrySpin
commands
  silent
  set $spin_enter_duration = _SpinDuration
  printf "TrySpin enter: _SpinDuration=%d\n", _SpinDuration
  continue
end

# 在 TrySpin return 1 处
break objectMonitor.cpp:2023
commands
  silent
  printf "TrySpin SUCCESS: _SpinDuration %d -> %d\n", $spin_enter_duration, _SpinDuration
  continue
end
```

### 13.4 打印 ObjectMonitor 内存布局

```gdb
# 假设已获得一个 ObjectMonitor 地址 $mon
set $mon = (ObjectMonitor*)0x<address>
printf "_header:       %p (offset 0)\n", $mon->_header
printf "_object:       %p (offset 8)\n", $mon->_object
printf "FreeNext:      %p (offset 16)\n", $mon->FreeNext
# 注意: _owner 在 cache line padding 之后
printf "_owner:        %p\n", $mon->_owner
printf "_recursions:   %ld\n", $mon->_recursions
printf "_EntryList:    %p\n", $mon->_EntryList
printf "_cxq:          %p\n", $mon->_cxq
printf "_succ:         %p\n", $mon->_succ
printf "_Responsible:  %p\n", $mon->_Responsible
printf "_SpinDuration: %d\n", $mon->_SpinDuration
printf "_count:        %d\n", $mon->_count
printf "_WaitSet:      %p\n", $mon->_WaitSet
printf "_waiters:      %d\n", $mon->_waiters
```

---

## 14. JVM 参数速查

| 参数 | 默认值 | 用途 |
|------|--------|------|
| `-XX:+UseHeavyMonitors` | false | 跳过轻量级锁，直接用重量级锁 |
| `-XX:-UseBiasedLocking` | true (JDK11) | 关闭偏向锁 |
| `-Xlog:monitorinflation=debug` | — | 打印膨胀/缩减日志 |
| `-XX:+PrintConcurrentLocks` | false | jstack 显示并发锁信息 |
| `SyncFlags` | 0 (内部) | 同步子系统调试标志位 |

---

## 15. 面试高频问题预览

**Q: synchronized 的锁升级过程是什么？（排除偏向锁）**

A: 两级升级：无锁 `01` → 轻量级锁 `00` → 重量级锁 `10`。

- **无锁 → 轻量级锁**：在当前栈帧分配 BasicLock，复制 mark word 到 displaced header，CAS 将对象头指向 BasicLock。只需一条 `lock cmpxchg`，约 10ns。

- **轻量级锁 → 重量级锁**：当 CAS 失败（竞争出现），调用 `inflate()` 分配 ObjectMonitor，将原始 mark word 保存到 `monitor._header`，CAS 将对象头指向 ObjectMonitor（编码后末尾 `10`）。膨胀是不可逆的，缩回只能在 safepoint。

**Q: ObjectMonitor 的 _cxq 和 _EntryList 有什么区别？**

A: 两者共同构成竞争线程队列。`_cxq` 是 LIFO 单链表，支持多线程并发 CAS push，接收新到达的线程。`_EntryList` 是 DLL 双链表，只由 owner 操作，支持 O(1) 删除。owner 在 exit 时将 `_cxq` 批量 drain 到 `_EntryList`，从 `_EntryList` 头部唤醒后继者。分成两个队列是为了减少锁元数据操作的竞争和开销。

**Q: 什么是自适应自旋？**

A: 每个 ObjectMonitor 维护一个 `_SpinDuration` 计数器。自旋成功时 `+= 100`（最大 5000），失败时 `-= 200`（最小 0）。新 monitor 初始值 5000。自旋采用 TATAS 策略（先读后 CAS），并在 CAS 失败或 owner 切换时直接 abort。同时检查 owner 是否在 CPU 上运行，避免无效自旋。

**Q: wait() 内部做了什么？**

A: ① 验证 owner 身份 → ② 保存递归计数，创建 ObjectWaiter(TS_WAIT) → ③ 加入 WaitSet → ④ 完全释放锁（exit()）→ ⑤ park 阻塞 → ⑥ 被 notify/超时/中断唤醒 → ⑦ 根据状态选择 enter() 或 ReenterI() 重新获取锁 → ⑧ 恢复递归计数。

**Q: notify() 和 notifyAll() 的区别不只是唤醒个数？**

A: 对。`notify()` 从 WaitSet 取一个节点转移到 EntryList/cxq（默认 policy=2 推入 cxq）。`notifyAll()` 循环调用 `INotify()` 转移所有节点。在 prepend 模式下，notifyAll 会**反转** WaitSet 中的顺序。而且 notify 只是转移队列位置，实际的 unpark 在 exit() 的 ExitEpilog 中执行。
