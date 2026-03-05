# 第 11 章：Handshake 机制 — 探针验证

> 基于 OpenJDK 11 源码插桩验证
> 标准环境：`-Xms512m -Xmx512m -XX:+UseG1GC -Xint`

---

## 11.1 核心问题

**Handshake 比全局 Safepoint 快多少？**

全局 Safepoint 需要所有线程都停下来，而 Handshake 只需要目标线程响应。
理论上 Handshake 应该快得多——本章用插桩数据量化这个差距。

---

## 11.2 插桩位置

| 探针 | 源码位置 | 捕获内容 |
|------|---------|---------|
| `[PROBE][Handshake] OneThread 完成` | `handshake.cpp:254`，`VM_HandshakeOneThread::doit()` 末尾 | 单线程 Handshake 耗时、处理方式（VMThread代处理/目标线程自处理）、当前线程数 |
| `[PROBE][Handshake] AllThreads 完成` | `handshake.cpp:337`，`VM_HandshakeAllThreads::doit()` 末尾 | 全线程 Handshake 耗时、目标线程数、VMThread代处理数 vs 自处理数 |
| `[PROBE][Handshake] 目标线程自处理` | `handshake.cpp:449`，`HandshakeState::process_self_inner()` | 目标线程自处理路径确认 |

关键观察：`VM_HandshakeOneThread` 和 `VM_HandshakeAllThreads` 的 `需要Safepoint=NO`，
这是 Handshake 与普通 VM_Operation 的本质区别。

---

## 11.3 验证程序

```java
// HandshakeDemo.java
// 触发方式：WhiteBox.handshakeWalkStack()
// 运行参数：-XX:+UnlockDiagnosticVMOptions -XX:+WhiteBoxAPI
//           -Xbootclasspath/a:/tmp/wb.jar

// 测试1：单线程 Handshake（针对 worker-0）
WB.handshakeWalkStack(workers[0], false);  // 单线程

// 测试2：全线程 Handshake
WB.handshakeWalkStack(null, true);         // 全线程

// 测试3：全局 Safepoint 对比
System.gc();
```

---

## 11.4 实测数据

### 11.4.1 单线程 Handshake（针对 1 个线程）

```
[PROBE][VMThread] 执行VM_Operation #2: HandshakeOneThread  需要Safepoint=NO
[PROBE][Handshake] OneThread 完成: op=WB_TraceSelf, target_tid=66492
  耗时=249 us (249388 ns)
  处理方式=VMThread代为处理
  当前Java线程数=10
  第1次 Handshake(单线程): Java层耗时=427 us

[PROBE][Handshake] OneThread 完成: op=WB_TraceSelf, target_tid=66492
  耗时=217 us (217178 ns)
  处理方式=VMThread代为处理
  当前Java线程数=10
  第2次 Handshake(单线程): Java层耗时=329 us

[PROBE][Handshake] OneThread 完成: op=WB_TraceSelf, target_tid=66492
  耗时=130 us (130255 ns)
  处理方式=VMThread代为处理
  当前Java线程数=10
  第3次 Handshake(单线程): Java层耗时=216 us
```

**单线程 Handshake 耗时：130 ~ 249 us（C++ 层），216 ~ 427 us（Java 层含调用开销）**

### 11.4.2 全线程 Handshake（10 个线程）

```
[PROBE][Handshake] AllThreads 完成: op=WB_TraceSelf
  耗时=1196 us (1196881 ns)
  目标线程数=10, VMThread代处理=6, 自处理=4
  第1次 Handshake(全线程): Java层耗时=1264 us

[PROBE][Handshake] AllThreads 完成: op=WB_TraceSelf
  耗时=978 us (978580 ns)
  目标线程数=10, VMThread代处理=7, 自处理=3
  第2次 Handshake(全线程): Java层耗时=1048 us

[PROBE][Handshake] AllThreads 完成: op=WB_TraceSelf
  耗时=972 us (972730 ns)
  目标线程数=10, VMThread代处理=6, 自处理=4
  第3次 Handshake(全线程): Java层耗时=1046 us
```

**全线程 Handshake 耗时：972 ~ 1196 us（10 个线程）**

### 11.4.3 全局 Safepoint（System.gc()）对比

```
  第1次 System.gc(): Java层耗时=95379 us
  第2次 System.gc(): Java层耗时=79001 us
  第3次 System.gc(): Java层耗时=61516 us
```

**全局 Safepoint（含 GC）耗时：61516 ~ 95379 us**

---

## 11.5 数据分析

### 11.5.1 耗时对比表

| 操作 | 目标线程数 | C++ 层耗时 | Java 层耗时 | 备注 |
|------|-----------|-----------|------------|------|
| 单线程 Handshake | 1 | 130 ~ 249 us | 216 ~ 427 us | 需要Safepoint=NO |
| 全线程 Handshake | 10 | 972 ~ 1196 us | 1046 ~ 1264 us | 需要Safepoint=NO |
| 全局 Safepoint (GC) | 全部 | — | 61516 ~ 95379 us | 需要Safepoint=YES |

### 11.5.2 倍数关系

```
单线程 Handshake vs 全局 Safepoint：
  61516 us / 200 us ≈ 307 倍

全线程 Handshake vs 全局 Safepoint（同等线程数）：
  61516 us / 1046 us ≈ 59 倍
```

**结论：单线程 Handshake 比全局 Safepoint 快约 300 倍，全线程 Handshake 快约 60 倍。**

### 11.5.3 处理方式分析

从探针数据可以看到两种处理路径：

**路径 A：VMThread 代为处理**（单线程 Handshake 全部走这条路）
```
处理方式=VMThread代为处理
```
- 目标线程处于 `_thread_blocked`（sleeping）状态
- VMThread 直接代替目标线程执行 HandshakeClosure
- 不需要等待目标线程响应，速度更快

**路径 B：目标线程自处理**（全线程 Handshake 混合两种路径）
```
[PROBE][Handshake] 目标线程自处理: tid=66493
[PROBE][Handshake] 目标线程自处理: tid=66495
[PROBE][Handshake] 目标线程自处理: tid=66492
[PROBE][Handshake] 目标线程自处理: tid=66494
```
- 目标线程处于运行状态，在 safepoint poll 时自己处理
- 全线程 Handshake 中：VMThread代处理 6~7 个，自处理 3~4 个

### 11.5.4 为什么单线程 Handshake 全部走 VMThread 代处理？

worker-0 线程在 `Thread.sleep(1)` 中处于 `_thread_blocked` 状态：
```
"worker-0" #7 daemon prio=5 os_prio=0 cpu=6.78ms elapsed=0.50s
   java.lang.Thread.State: TIMED_WAITING (sleeping)
   JavaThread state: _thread_blocked
```

当目标线程处于 `_thread_blocked` 时，VMThread 可以直接代为处理，
不需要等待目标线程到达 safepoint poll 点，因此耗时更短（130 us）。

---

## 11.6 关键机制确认

### 11.6.1 Handshake 不需要全局 Safepoint

```
[PROBE][VMThread] 执行VM_Operation #2: HandshakeOneThread  需要Safepoint=NO
[PROBE][VMThread] 执行VM_Operation #5: HandshakeAllThreads  需要Safepoint=NO
```

`需要Safepoint=NO` 是 Handshake 的核心优势：
- 普通 VM_Operation（如 GC）需要所有线程停止
- Handshake 只需要目标线程响应，其他线程继续运行

### 11.6.2 两种处理路径的触发条件

```cpp
// handshake.cpp
// VMThread 代处理：目标线程处于 _thread_blocked 状态
bool HandshakeState::try_process_by_vmThread(HandshakeClosure* op) {
    // 检查目标线程是否处于安全状态（blocked/in_native）
    // 如果是，VMThread 直接执行 op
}

// 目标线程自处理：线程在 safepoint poll 点检测到 handshake 请求
void HandshakeState::process_self_inner(HandshakeClosure* op) {
    // [PROBE][11.3] 目标线程自处理
}
```

---

## 11.7 总结

### 数据层面

| 指标 | 数值 |
|------|------|
| 单线程 Handshake 耗时 | **130 ~ 249 us** |
| 全线程 Handshake 耗时（10线程） | **972 ~ 1196 us** |
| 全局 Safepoint 耗时（含GC） | **61516 ~ 95379 us** |
| 单线程 Handshake vs Safepoint | **快约 300 倍** |
| 全线程 Handshake vs Safepoint | **快约 60 倍** |

### 机制层面

1. **Handshake 不需要全局 Safepoint**：`需要Safepoint=NO`，其他线程继续运行
2. **两种处理路径**：VMThread 代处理（目标线程 blocked 时）vs 目标线程自处理（目标线程运行时）
3. **VMThread 代处理更快**：不需要等待目标线程响应，直接执行
4. **全线程 Handshake 是混合模式**：部分线程 VMThread 代处理，部分线程自处理，并发执行

### 设计意义

Handshake 是 JDK 11 引入的重要优化（JEP 312），将很多原本需要全局 Safepoint 的操作
（如偏向锁撤销、栈 trace）改为只停目标线程，大幅降低了 STW 时间。
