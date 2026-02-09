# Phase 2: SafepointMechanism 安全点机制

## 📌 功能定位

**一句话说明**：SafepointMechanism 是 JVM 实现 "Stop-The-World" (STW) 的核心机制，通过 Polling Page 让所有 Java 线程在安全点暂停，以便 VMThread 执行 GC、偏向锁撤销等操作。

**在整体流程中的位置**：
```
Threads::create_vm()
│
├── Phase 2: 安全点机制初始化 ← 【当前分析重点】
│   ├── SafepointMechanism::initialize()
│   ├── Polling Page 创建
│   └── 内存序列化页创建
│
├── Phase 3: JavaThread 创建
│
├── Phase 5: VMThread 创建
│   └── VMThread::loop() 中发起 Safepoint
│
└── Phase 6: Java 类初始化
```

**如果没有它会怎样？**
- GC 无法安全执行（对象可能在移动时被访问）
- 偏向锁撤销无法进行
- 类重定义 (hot swap) 无法实现
- jstack/jmap 等诊断工具无法获取一致快照

---

## 🏛️ 设计哲学

### 核心问题：为什么需要安全点？

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                        安全点存在的必要性                                        │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  问题场景：GC 要移动对象                                                         │
│                                                                                  │
│  Thread-1                    Thread-2                    GC Thread              │
│     │                           │                           │                   │
│     │  oop obj = load(ref);     │                           │                   │
│     │     │                     │                           │                   │
│     │     │              ┌──────┤                           │                   │
│     │     │              │      │     发起 GC               │                   │
│     │     │              │      │        │                  │                   │
│     │     │              │      │        ▼                  │                   │
│     │     │              │      │   移动对象 obj            │                   │
│     │     │              │      │   旧地址 → 新地址         │                   │
│     │     ▼              │      │                           │                   │
│     │  use(obj);  ← 访问旧地址，CRASH! ← 问题就在这里        │                   │
│     │                    └──────┘                           │                   │
│                                                                                  │
│  解决方案：在 GC 之前，让所有线程暂停在 "安全点"                                  │
│  安全点 = 线程不持有任何堆引用的瞬间（或引用已被记录在 OopMap 中）                │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 设计决策

| 决策 | JDK 8 及之前 | JDK 11+ | 原因 |
|------|------------|---------|------|
| **轮询方式** | 全局页 (Global Page Poll) | 线程本地轮询 (Thread Local Poll) | 支持更细粒度的 Handshake |
| **轮询检测** | 读不可读页触发 SIGSEGV | 检查线程本地标志 + Polling Page | 兼容两种方式 |
| **内存屏障** | Memory Serialize Page | UseMembar=true 可关闭 | 优化 JNI 调用性能 |

---

## 🔄 两种轮询方式对比

### 1. 全局页轮询 (Global Page Poll) - 传统方式

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                      Global Page Poll 工作原理                                   │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  正常状态：Polling Page 可读                                                     │
│  ┌──────────────────────────────────────────┐                                   │
│  │         Polling Page                      │                                   │
│  │         [PROT_READ]                       │                                   │
│  │              │                            │                                   │
│  │   Thread-1   │   Thread-2   Thread-3      │                                   │
│  │      │       │      │          │          │                                   │
│  │      ▼       ▼      ▼          ▼          │                                   │
│  │    读取成功，继续执行                      │                                   │
│  └──────────────────────────────────────────┘                                   │
│                                                                                  │
│  进入 Safepoint：VMThread 将页设为不可读                                         │
│  ┌──────────────────────────────────────────┐                                   │
│  │         Polling Page                      │                                   │
│  │         [PROT_NONE] ← os::make_polling_page_unreadable()                     │
│  │              │                            │                                   │
│  │   Thread-1   │   Thread-2   Thread-3      │                                   │
│  │      │       │      │          │          │                                   │
│  │      ▼       ▼      ▼          ▼          │                                   │
│  │    SIGSEGV! SIGSEGV! SIGSEGV!             │                                   │
│  │      │       │      │          │          │                                   │
│  │      └───────┴──────┴──────────┘          │                                   │
│  │              │                            │                                   │
│  │              ▼                            │                                   │
│  │    信号处理: handle_polling_page_exception()                                 │
│  │              │                            │                                   │
│  │              ▼                            │                                   │
│  │    SafepointSynchronize::block()         │                                   │
│  └──────────────────────────────────────────┘                                   │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 2. 线程本地轮询 (Thread Local Poll) - JDK 11+ 默认

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                     Thread Local Poll 工作原理                                   │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  每个线程有自己的 polling_page 指针                                              │
│                                                                                  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                              │
│  │  Thread-1   │  │  Thread-2   │  │  Thread-3   │                              │
│  │ _polling_page│  │ _polling_page│  │ _polling_page│                           │
│  │      │       │  │      │       │  │      │       │                           │
│  │      ▼       │  │      ▼       │  │      ▼       │                           │
│  │  good_page   │  │  good_page   │  │  good_page   │                           │
│  │  [PROT_READ] │  │  [PROT_READ] │  │  [PROT_READ] │                           │
│  └─────────────┘  └─────────────┘  └─────────────┘                              │
│                                                                                  │
│  进入 Safepoint：arm_local_poll() 修改每个线程的指针                             │
│                                                                                  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                              │
│  │  Thread-1   │  │  Thread-2   │  │  Thread-3   │                              │
│  │ _polling_page│  │ _polling_page│  │ _polling_page│                           │
│  │      │       │  │      │       │  │      │       │                           │
│  │      ▼       │  │      ▼       │  │      ▼       │                           │
│  │  bad_page    │  │  bad_page    │  │  bad_page    │                           │
│  │  [PROT_NONE] │  │  [PROT_NONE] │  │  [PROT_NONE] │                           │
│  └─────────────┘  └─────────────┘  └─────────────┘                              │
│                                                                                  │
│  优势：                                                                          │
│  1. 可以只 arm 单个线程（用于 Handshake）                                        │
│  2. 不需要修改全局页保护属性                                                     │
│  3. 更高效，减少 mprotect 系统调用                                               │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 内存布局

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                     Thread Local Poll 内存布局                                   │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│                        Polling Page 内存区域 (2 * page_size)                     │
│                                                                                  │
│    低地址                                                 高地址                 │
│    ┌────────────────────────────────────────────────────────────┐               │
│    │                           │                                │               │
│    │       bad_page            │         good_page              │               │
│    │      [PROT_NONE]          │        [PROT_READ]             │               │
│    │                           │                                │               │
│    │  poll_armed_value 指向这里 │  poll_disarmed_value 指向这里  │               │
│    │                           │                                │               │
│    └───────────────────────────┴────────────────────────────────┘               │
│    │◄──────── page_size ───────►│◄──────── page_size ───────────►│              │
│                                                                                  │
│    poll_armed_value   = bad_page  | poll_bit (0x8)                              │
│    poll_disarmed_value = good_page | 0                                          │
│                                                                                  │
│    poll_bit 用于快速判断是否 armed：                                             │
│    if (poll_word & poll_bit) → armed                                            │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 🔍 核心类与方法

### 类关系图

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          Safepoint 相关类关系                                    │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  ┌─────────────────────────┐      ┌─────────────────────────┐                   │
│  │  SafepointMechanism     │      │ SafepointSynchronize    │                   │
│  │  (轮询机制抽象)          │      │ (同步协调)              │                   │
│  ├─────────────────────────┤      ├─────────────────────────┤                   │
│  │ + initialize()          │      │ + begin()               │                   │
│  │ + poll()                │      │ + end()                 │                   │
│  │ + block_if_requested()  │───→  │ + block()               │                   │
│  │ + arm_local_poll()      │      │ + is_at_safepoint()     │                   │
│  │ + disarm_local_poll()   │      │ - _state                │                   │
│  │                         │      │ - _safepoint_counter    │                   │
│  └─────────────────────────┘      └───────────┬─────────────┘                   │
│                                               │                                  │
│                                               │ 使用                             │
│                                               ▼                                  │
│                               ┌─────────────────────────────┐                   │
│                               │  ThreadSafepointState       │                   │
│                               │  (每线程的安全点状态)        │                   │
│                               ├─────────────────────────────┤                   │
│                               │ + examine_state_of_thread() │                   │
│                               │ + roll_forward()            │                   │
│                               │ + restart()                 │                   │
│                               │ - _type: suspend_type       │                   │
│                               │ - _at_poll_safepoint        │                   │
│                               └─────────────────────────────┘                   │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### SafepointSynchronize 状态机

```cpp
// safepoint.hpp:61
enum SynchronizeState {
    _not_synchronized = 0,   // 正常运行，无安全点
    _synchronizing    = 1,   // 正在同步，等待所有线程到达
    _synchronized     = 2    // 所有线程已暂停，可执行 VM 操作
};
```

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    SynchronizeState 状态转换                                     │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│                                                                                  │
│    ┌────────────────────────┐                                                   │
│    │  _not_synchronized (0) │  ← 正常状态                                        │
│    │  (所有线程正常运行)     │                                                   │
│    └───────────┬────────────┘                                                   │
│                │                                                                 │
│                │ VMThread 调用 begin()                                           │
│                ▼                                                                 │
│    ┌────────────────────────┐                                                   │
│    │   _synchronizing (1)   │  ← 正在同步                                        │
│    │  (等待线程到达安全点)   │                                                   │
│    │                        │                                                   │
│    │  - arm polling pages   │                                                   │
│    │  - 循环检查线程状态     │                                                   │
│    │  - 等待 _waiting_to_block == 0                                             │
│    └───────────┬────────────┘                                                   │
│                │                                                                 │
│                │ 所有线程已到达                                                   │
│                ▼                                                                 │
│    ┌────────────────────────┐                                                   │
│    │    _synchronized (2)   │  ← 已同步（STW）                                   │
│    │  (执行 VM 操作)         │                                                   │
│    │                        │                                                   │
│    │  - GC、偏向锁撤销等     │                                                   │
│    │  - 此时只有 VMThread 运行                                                   │
│    └───────────┬────────────┘                                                   │
│                │                                                                 │
│                │ VMThread 调用 end()                                             │
│                ▼                                                                 │
│    ┌────────────────────────┐                                                   │
│    │  _not_synchronized (0) │  ← 恢复正常                                        │
│    │  (唤醒所有线程)         │                                                   │
│    └────────────────────────┘                                                   │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 📋 SafepointMechanism::initialize() 流程

```cpp
// safepointMechanism.cpp:115
void SafepointMechanism::initialize() {
  pd_initialize();           // 平台相关初始化，创建 Polling Page
  initialize_serialize_page(); // 创建内存序列化页
}
```

### 初始化流程图

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                   SafepointMechanism::initialize() 流程                          │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  initialize()                                                                    │
│       │                                                                          │
│       ├──→ pd_initialize()                                                       │
│       │         │                                                                │
│       │         ├──→ default_initialize()                                        │
│       │         │         │                                                      │
│       │         │         ├── if (ThreadLocalHandshakes)                        │
│       │         │         │        │                                             │
│       │         │         │        ├── set_uses_thread_local_poll()             │
│       │         │         │        │                                             │
│       │         │         │        ├── 分配 2 * page_size 内存                   │
│       │         │         │        │   polling_page = reserve_memory(2*page)    │
│       │         │         │        │                                             │
│       │         │         │        ├── bad_page = polling_page                   │
│       │         │         │        │   good_page = polling_page + page_size     │
│       │         │         │        │                                             │
│       │         │         │        ├── protect_memory(bad_page, PROT_NONE)      │
│       │         │         │        │   protect_memory(good_page, PROT_READ)     │
│       │         │         │        │                                             │
│       │         │         │        └── _poll_armed_value = bad_page | poll_bit  │
│       │         │         │            _poll_disarmed_value = good_page | 0     │
│       │         │         │                                                      │
│       │         │         └── else (Global Page Poll)                            │
│       │         │                  │                                             │
│       │         │                  ├── 分配 1 * page_size 内存                   │
│       │         │                  └── protect_memory(polling_page, PROT_READ)  │
│       │         │                                                                │
│       │         └──────────────────────────────────────────────────────────────  │
│       │                                                                          │
│       └──→ initialize_serialize_page()                                           │
│                 │                                                                │
│                 └── if (!UseMembar)                                              │
│                          │                                                       │
│                          └── 分配内存序列化页                                     │
│                              用于 JNI 调用时的内存屏障优化                        │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 🔄 Safepoint 完整流程

### begin() → 执行 VM 操作 → end()

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                      Safepoint 完整执行流程                                      │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  VMThread                           Java Threads (1,2,3...)                     │
│     │                                    │ │ │                                   │
│     │                                    │ │ │ 正常执行                          │
│     │                                    │ │ │                                   │
│  ═══════════════════ SafepointSynchronize::begin() ═══════════════════          │
│     │                                    │ │ │                                   │
│     ├── 1. Threads_lock->lock()          │ │ │                                   │
│     │                                    │ │ │                                   │
│     ├── 2. _state = _synchronizing       │ │ │                                   │
│     │                                    │ │ │                                   │
│     ├── 3. arm_local_poll(all threads)   │ │ │                                   │
│     │       └── 设置 _polling_page        │ │ │                                   │
│     │           = poll_armed_value       │ │ │                                   │
│     │                                    │ │ │                                   │
│     │                                    ▼ ▼ ▼                                   │
│     │                              检测到 armed!                                 │
│     │                                    │ │ │                                   │
│     │                              block_if_requested()                          │
│     │                                    │ │ │                                   │
│     │                              SafepointSynchronize::block()                │
│     │                                    │ │ │                                   │
│     │                              等待在 Safepoint_lock                         │
│     │                                    │ │ │                                   │
│     ├── 4. 循环检查 still_running        │ │ │                                   │
│     │       while(still_running > 0)     │ │ │                                   │
│     │         examine_state_of_thread()  │ │ │                                   │
│     │                                    │ │ │                                   │
│     ├── 5. _state = _synchronized        │ │ │ (阻塞中)                          │
│     │                                    │ │ │                                   │
│  ═══════════════════ 执行 VM 操作（如 GC） ════════════════════════              │
│     │                                    │ │ │                                   │
│     │   VM_Operation::doit()             │ │ │                                   │
│     │   (此时只有 VMThread 运行)          │ │ │                                   │
│     │                                    │ │ │                                   │
│  ═══════════════════ SafepointSynchronize::end() ══════════════════════         │
│     │                                    │ │ │                                   │
│     ├── 1. os::make_polling_page_readable()                                     │
│     │                                    │ │ │                                   │
│     ├── 2. _state = _not_synchronized    │ │ │                                   │
│     │                                    │ │ │                                   │
│     ├── 3. disarm_local_poll(all threads)│ │ │                                   │
│     │       └── 设置 _polling_page        │ │ │                                   │
│     │           = poll_disarmed_value    │ │ │                                   │
│     │                                    │ │ │                                   │
│     ├── 4. Threads_lock->unlock()        │ │ │                                   │
│     │                                    │ │ │                                   │
│     │                                    ▼ ▼ ▼                                   │
│     │                              被唤醒，继续执行                              │
│     │                                    │ │ │                                   │
│     ▼                                    ▼ ▼ ▼                                   │
│  继续下一个 VM 操作                    正常执行                                   │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 📊 不同线程状态的处理

### Java 线程在不同状态下如何到达安全点

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                   不同线程状态的安全点处理                                        │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  线程状态                  如何到达安全点                                         │
│  ═════════════════════════════════════════════════════════════════════════      │
│                                                                                  │
│  1. Running Interpreted (解释执行)                                               │
│     └── 解释器在字节码之间检查 safepoint                                         │
│         DispatchTable 被修改，跳转到安全点检查代码                               │
│         Interpreter::notice_safepoints()                                        │
│                                                                                  │
│  2. Running Compiled Code (JIT 编译代码)                                         │
│     └── 读取 Polling Page，触发 SIGSEGV                                          │
│         JIT 在方法返回点、循环回边插入读取指令:                                   │
│         test [polling_page], eax                                                 │
│                                                                                  │
│  3. Running in Native (执行 native 方法)                                         │
│     └── 不等待！native 代码不持有堆引用                                          │
│         返回 Java 时检查 safepoint 状态                                          │
│         在 JavaThreadState 从 _thread_in_native 转换时检查                       │
│                                                                                  │
│  4. Blocked (阻塞状态)                                                           │
│     └── 已经安全！阻塞时不执行代码                                               │
│         VMThread 检查到 blocked 状态，直接计入已到达                             │
│                                                                                  │
│  5. In VM / Transitioning (执行 VM 代码/状态转换中)                              │
│     └── 在状态转换时检查 trans 状态                                              │
│         通过 _thread_xxx_trans 状态完成同步                                      │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### JIT 生成的轮询代码

```asm
# JIT 在方法返回前插入的代码 (x86_64)
# 
# 正常时：读取 good_page，无事发生
# safepoint 时：读取 bad_page (PROT_NONE)，触发 SIGSEGV

mov    rax, [thread + polling_page_offset]  # 获取当前线程的 polling_page
test   DWORD PTR [rax], eax                 # 尝试读取，如果是 bad_page 则触发 SIGSEGV
```

---

## 🔧 信号处理流程

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                   Polling Page 异常处理流程                                      │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  JIT Code                                                                        │
│     │                                                                            │
│     │ test [bad_page], eax                                                       │
│     │         │                                                                  │
│     │         ▼                                                                  │
│     │     SIGSEGV !                                                              │
│     │         │                                                                  │
│     │         ▼                                                                  │
│  Linux Kernel: 触发信号                                                          │
│     │         │                                                                  │
│     │         ▼                                                                  │
│  JVM_handle_linux_signal() (os_linux_x86.cpp)                                    │
│     │         │                                                                  │
│     │         ├── 检查: os::is_poll_address(info->si_addr)                       │
│     │         │         是 polling_page 地址吗?                                  │
│     │         │                                                                  │
│     │         │   是 → stub = SharedRuntime::get_poll_stub(pc)                   │
│     │         │              │                                                   │
│     │         │              ▼                                                   │
│     │         │   polling_page_safepoint_handler_blob->entry_point()             │
│     │         │              │                                                   │
│     │         │              ▼                                                   │
│     │         │   SafepointSynchronize::handle_polling_page_exception()          │
│     │         │              │                                                   │
│     │         │              ▼                                                   │
│     │         │   ThreadSafepointState::handle_polling_page_exception()          │
│     │         │              │                                                   │
│     │         │              ▼                                                   │
│     │         │   SafepointSynchronize::block(thread)                            │
│     │         │              │                                                   │
│     │         │              ▼                                                   │
│     │         │   等待 Safepoint 结束...                                          │
│     │         │              │                                                   │
│     │         │              ▼                                                   │
│     │         │   返回 JIT 代码继续执行                                           │
│     │         │                                                                  │
│     │         │   否 → 真正的段错误，crash                                       │
│     │                                                                            │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 🎤 面试必背

### 1. 什么是 Safepoint？为什么需要它？

> **答**：Safepoint 是 JVM 中所有 Java 线程暂停的同步点。需要它的原因：
> - **GC 安全**：GC 可能移动对象，需要暂停线程防止访问野指针
> - **一致性快照**：jstack/jmap 需要获取一致的线程栈/堆快照
> - **偏向锁撤销**：需要暂停持有偏向锁的线程
> - **代码反优化**：替换栈上的编译代码需要线程暂停

### 2. Safepoint 是怎么实现的？

> **答**：核心是 **Polling Page 机制**：
> 1. JIT 编译器在方法返回点、循环回边插入读取 polling page 的指令
> 2. 正常时 polling page 可读，读取成功，继续执行
> 3. 需要 safepoint 时，VMThread 将 polling page 设为不可读 (PROT_NONE)
> 4. 线程读取时触发 SIGSEGV，信号处理函数让线程阻塞
> 5. 所有线程阻塞后，VMThread 执行 VM 操作
> 6. 完成后恢复 polling page 为可读，唤醒所有线程

### 3. Thread Local Poll 和 Global Page Poll 有什么区别？

> **答**：
> | 特性 | Global Page Poll | Thread Local Poll (JDK 11+) |
> |------|-----------------|---------------------------|
> | 轮询地址 | 全局唯一 | 每线程独立 |
> | arm 方式 | mprotect 修改页属性 | 修改线程的指针 |
> | 粒度 | 只能 STW | 支持单线程 Handshake |
> | 效率 | 每次 mprotect 系统调用 | 只修改内存变量 |

### 4. 为什么执行 native 方法的线程不需要等待？

> **答**：
> - Native 代码不直接持有 Java 堆对象引用（通过 JNI Handle）
> - GC 移动对象时，JNI Handle 会被更新
> - 线程从 native 返回时会检查 safepoint 状态
> - 这是性能优化，避免频繁的 JNI 调用阻塞

### 5. Safepoint 延迟的常见原因？

> **答**：
> 1. **大循环无回边**：counted loop 没有 safepoint 检查（JDK bug，后来修复）
> 2. **长 native 调用**：native 代码不响应 safepoint
> 3. **内存分配失败**：等待内存导致的延迟
> 4. **大量线程**：等待所有线程到达的时间增加
> 
> **诊断**：`-Xlog:safepoint=debug` 或 `-XX:+PrintSafepointStatistics`

---

## 📊 源码位置速查

| 内容 | 文件 | 行号 |
|------|------|------|
| SafepointMechanism 类定义 | `safepointMechanism.hpp` | 34 |
| SafepointMechanism::initialize() | `safepointMechanism.cpp` | 115 |
| default_initialize() | `safepointMechanism.cpp` | 44 |
| SafepointSynchronize 类定义 | `safepoint.hpp` | 56 |
| SafepointSynchronize::begin() | `safepoint.cpp` | 158 |
| SafepointSynchronize::end() | `safepoint.cpp` | 500 |
| handle_polling_page_exception | `safepoint.cpp` | 951 |
| ThreadSafepointState | `safepoint.hpp` | 207 |

---

## 🔬 GDB 验证脚本

见 [gdb_safepoint.txt](./gdb_safepoint.txt)

---

## ✅ GDB 验证结果

### 验证环境
```
【GDB 验证】标准条件：-Xms256m -Xmx256m -XX:+UseG1GC
工作目录：/data/workspace/openjdk-cut-new
```

### 关键执行点捕获

#### 1. SafepointMechanism::default_initialize() 调用链

```
#0  SafepointMechanism::default_initialize () at safepointMechanism.cpp:43
#1  SafepointMechanism::pd_initialize () at safepointMechanism.hpp:57
#2  SafepointMechanism::initialize () at safepointMechanism.cpp:116
#3  Threads::create_vm () at thread.cpp:3965        ← 在 create_vm 中初始化
#4  JNI_CreateJavaVM_inner () at jni.cpp:4010
#5  JNI_CreateJavaVM () at jni.cpp:4115
#6  InitializeJVM () at java.c:1626
#7  JavaMain () at java.c:509
```

#### 2. Polling Page 地址设置

```
os::set_polling_page(page=0x7ffff7fbd000)

Polling Page 内存布局 (Thread Local Poll 模式):
┌────────────────────────────────────────────────────────────────────┐
│  0x7ffff7fbd000  │  bad_page  [PROT_NONE]  │  poll_armed_value     │
│  0x7ffff7fbe000  │  good_page [PROT_READ]  │  poll_disarmed_value  │
└────────────────────────────────────────────────────────────────────┘
```

#### 3. 验证结论

| 验证项 | 结果 | 说明 |
|--------|------|------|
| ✅ 初始化时机 | `Threads::create_vm()` 中调用 | 早于线程创建 |
| ✅ 轮询方式 | Thread Local Poll | JDK 11 默认 |
| ✅ Polling Page 分配 | 2 * page_size (8KB) | bad_page + good_page |
| ✅ 地址 | `0x7ffff7fbd000` | 内存映射区域 |

---

**下一步建议**: 继续学习 **Handshake 机制**（基于 Thread Local Poll 的改进）？ 🚀
