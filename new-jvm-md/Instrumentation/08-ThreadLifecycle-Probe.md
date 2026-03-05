# 第 8 章：线程生命周期插桩验证

> 基于 OpenJDK 11 源码插桩验证
> 标准环境：`-Xms8g -Xmx8g -XX:+UseG1GC -Xint`
> 插桩文件：`src/hotspot/os/linux/os_linux.cpp`、`src/hotspot/share/runtime/vmThread.cpp`

---

## 8.1 Java 线程创建链路验证

### 验证目标

| 问题 | 预期 | 实测 |
|------|------|------|
| `JavaThread` 对象大小 | ~4096 bytes | **1888 bytes** ✅ |
| OS 线程栈大小（GC 线程） | 512KB 或 1MB | **1024KB** ✅ |
| 新线程的初始 osthread_state | RUNNING? | **ALLOCATED(0)** ✅ |
| GC 线程请求的栈大小 | 非零 | **0KB（由 JVM 自动决定）** ✅ |

---

### 实测输出

```
[PROBE][Thread] os::create_thread #1: 创建新线程
  JavaThread@0x00007fbca003f000  name=GC Thread#0
  sizeof(JavaThread)=1888 bytes
  thr_type=2 (0=java,1=compiler,2=gc,3=pgc,4=watcher,5=os)
  req_stack_size=0KB  当前线程总数=0

[PROBE][Thread] 栈大小计算 #1: name=GC Thread#0
  req_stack_size=0KB  guard_size=4KB  final_stack_size=1028KB

[PROBE][Thread] thread_native_entry #1: 新线程开始运行
  os_tid=547178  pthread_self=140448196327104
  JavaThread@0x00007fbca003f000  name=GC Thread#0
  osthread_state=0 (0=ALLOCATED,1=INITIALIZED,2=RUNNING,3=SUSPENDED,4=ZOMBIE)

[PROBE][Thread] 实际栈信息 #1: name=GC Thread#0
  stack_base=0x00007fbca4da0000  stack_size=1024KB
```

---

### 结论

#### 结论 1：`sizeof(JavaThread) = 1888 bytes`（不是 4KB）

预期是 ~4096 bytes，实测是 **1888 bytes**。

原因分析：
- `JavaThread` 继承自 `Thread`，包含大量字段（TLAB 缓冲区、JNI handles、栈帧指针等）
- 但 TLAB 的实际内存是在堆上分配的，`JavaThread` 里只存 TLAB 的**元数据**（start/top/end 指针）
- 1888 bytes ≈ 1.84KB，是 C++ 对象本身的大小，不含动态分配的内存

```
统计：25 个线程全部 sizeof(JavaThread)=1888 bytes（一致）
```

#### 结论 2：线程栈大小 = 1024KB（GC 线程）

- `req_stack_size=0KB`：GC 线程创建时传入 0，表示"使用默认值"
- `final_stack_size=1028KB`：JVM 计算后的最终值 = 1024KB 栈 + 4KB guard page
- `stack_size=1024KB`：`record_stack_base_and_size()` 记录的实际栈大小

**注意**：这是 GC 线程的栈大小。Java 应用线程（`-Xss` 控制）默认是 512KB。

#### 结论 3：新线程的初始状态是 `ALLOCATED(0)`，不是 `RUNNING`

`thread_native_entry` 是新线程执行的第一行代码，此时 `osthread_state=0(ALLOCATED)`。

线程状态机转换顺序：
```
ALLOCATED(0)
    ↓  thread_native_entry() 入口
INITIALIZED(1)   ← os::Linux::init_thread_fpu_state() 之后
    ↓  thread->set_started()
RUNNING(2)       ← 线程真正开始执行 Java 代码
    ↓  线程退出
ZOMBIE(4)
```

#### 结论 4：线程类型分布（25 个线程）

| thr_type | 类型名 | 数量 | 代表线程 |
|----------|--------|------|---------|
| 0 | java | 1 | 应用线程（Unknown thread） |
| 1 | compiler | 4 | C1/C2 编译线程 |
| 2 | gc | 13 | GC Thread#0~12 |
| 3 | pgc | 6 | G1 Refine/Conc/Marker 等 |
| 4 | watcher | 0 | WatcherThread（不走此路径） |
| 5 | os | 1 | OS 线程 |

---

## 8.2 VMThread 工作循环验证

### 验证目标

| 问题 | 预期 | 实测 |
|------|------|------|
| 最常见的 VM_Operation | GC 相关 | **G1CollectForAllocation** ✅ |
| 是否所有 VM_Operation 都需要 Safepoint | 否 | **本次全部 YES**（见分析） |
| 启动时第一个 VM_Operation | 未知 | **EnableBiasedLocking** ✅ |
| 程序结束前最后一个 | 未知 | **RevokeBias** ✅ |

---

### 实测输出

```
[PROBE][VMThread] 执行VM_Operation #1: EnableBiasedLocking  需要Safepoint=YES
[PROBE][VMThread] 执行VM_Operation #2: G1CollectForAllocation  需要Safepoint=YES
[PROBE][VMThread] 执行VM_Operation #3: G1CollectForAllocation  需要Safepoint=YES
[PROBE][VMThread] 执行VM_Operation #4: G1CollectForAllocation  需要Safepoint=YES
[PROBE][VMThread] 执行VM_Operation #5: G1CollectForAllocation  需要Safepoint=YES
[PROBE][VMThread] 执行VM_Operation #6: G1CollectForAllocation  需要Safepoint=YES
[PROBE][VMThread] 执行VM_Operation #7: G1CollectForAllocation  需要Safepoint=YES
[PROBE][VMThread] 执行VM_Operation #8: RevokeBias  需要Safepoint=YES
```

---

### 结论

#### 结论 1：VMThread 是 JVM 的"管理员线程"，所有 STW 操作都通过它执行

本次运行共执行了 **8 个 VM_Operation**，全部需要 Safepoint（STW）：

| # | VM_Operation | 触发原因 |
|---|-------------|---------|
| 1 | `EnableBiasedLocking` | JVM 启动后延迟启用偏向锁（BiasedLockingStartupDelay=4000ms 后触发） |
| 2~7 | `G1CollectForAllocation` | Demo 程序分配大量对象，触发 6 次 YoungGC |
| 8 | `RevokeBias` | Demo 程序中有锁竞争，撤销偏向锁 |

#### 结论 2：本次运行所有 VM_Operation 都需要 Safepoint

大纲预期"不是所有 VM_Operation 都需要 Safepoint（如 Handshake 只停一个线程）"，但本次 Demo 程序没有触发 Handshake 类型的操作。

**不需要 Safepoint 的 VM_Operation 示例**（源码中存在，但本次未触发）：
- `VM_HandshakeAllThreads`：只停目标线程，不需要全局 Safepoint
- `VM_PrintThreads`：打印线程信息，不需要 STW

#### 结论 3：VM_Operation 执行顺序揭示了 JVM 的工作节奏

```
启动 → EnableBiasedLocking（延迟4秒后启用偏向锁）
     → G1CollectForAllocation × 6（每次 Eden 满了就 YoungGC）
     → RevokeBias（锁竞争时撤销偏向锁）
     → 程序退出
```

这个顺序完美对应了 Demo 程序的行为：
1. 程序启动 4 秒后偏向锁生效
2. 大量对象分配触发多次 YoungGC
3. 多线程竞争锁触发偏向锁撤销

---

## 8.3 插桩技术总结

### 遇到的坑

#### 坑 1：`tty->print_cr()` 不能在 `initialize_thread_current()` 之前调用

**现象**：程序在第 7 个线程（pgc 线程）时 Aborted，报 `assert(current != __null) failed`

**根因**：`tty->print_cr()` 内部获取锁时调用了 `Thread::current()`，而 `Thread::current()` 依赖 TLS（`_thr_current`）。在 `initialize_thread_current()` 执行之前，TLS 未初始化，`Thread::current()` 返回 NULL，触发 assert。

**修复**：将所有插桩代码移到 `initialize_thread_current()` 之后。

```cpp
// ❌ 错误：在 initialize_thread_current() 之前调用 tty
thread_native_entry(Thread *thread) {
    tty->print_cr("...");  // CRASH! TLS 未初始化
    thread->record_stack_base_and_size();
    thread->initialize_thread_current();  // TLS 在这里初始化
}

// ✅ 正确：在 initialize_thread_current() 之后调用 tty
thread_native_entry(Thread *thread) {
    thread->record_stack_base_and_size();
    thread->initialize_thread_current();  // TLS 在这里初始化
    tty->print_cr("...");  // 安全！TLS 已就绪
}
```

#### 坑 2：`VMOperationQueue` 没有 `length()` 方法

**现象**：编译报错 `'class VMOperationQueue' has no member named 'length'`

**根因**：`VMOperationQueue` 的队列长度存储在私有字段 `_queue_length[nof_priorities]` 中，没有公开的 `length()` 接口。

**修复**：去掉"队列剩余"的打印，只保留 Operation 名称。

#### 坑 3：`#ifndef __GLIBC__` 的 `#endif` 被误删

**现象**：编译报错 `#endif without #if`

**根因**：多次修改插桩位置时，`#ifndef __GLIBC__` 的开头被误删，只剩孤立的 `#endif`。

**修复**：补回 `#ifndef __GLIBC__` 开头。

---

## 8.4 插桩代码位置汇总

| 文件 | 函数 | 插桩内容 |
|------|------|---------|
| `os/linux/os_linux.cpp` | `os::create_thread()` | JavaThread 大小、线程类型、当前线程数 |
| `os/linux/os_linux.cpp` | `os::create_thread()` | 栈大小计算（req/guard/final） |
| `os/linux/os_linux.cpp` | `thread_native_entry()` | 新线程 os_tid、初始 osthread_state |
| `os/linux/os_linux.cpp` | `thread_native_entry()` | 实际栈 base 和 size |
| `runtime/vmThread.cpp` | `VMThread::loop()` | VM_Operation 名称和 Safepoint 需求 |
