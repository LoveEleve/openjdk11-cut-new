# SafepointSynchronize 深度分析

> **源码位置**: `src/hotspot/share/runtime/safepoint.cpp`
> **重要程度**: ⭐⭐⭐⭐⭐ (GC STW 核心实现)
> **调用链路**: `VMThread` → `SafepointSynchronize::begin()/end()`

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文是对 **SafepointSynchronize 深度分析** 的深度源码分析：从数据结构到算法流程，逐层剖析其实现原理，并通过 GDB 验证关键结论。

### 0.2 为什么需要？

深入理解 JVM 内部实现，不仅能帮助排查生产问题，更能建立对 JVM 行为的精确预测能力——知道『为什么』比知道『是什么』更重要。

### 0.3 怎么解决？

采用「数据结构 → 算法流程 → GDB 验证」三步法：先完整分析所有涉及的数据结构（字段含义/sizeof/生命周期），再分析算法流程（每步有 why），最后用 GDB 实际验证关键结论。

### 0.4 为什么这样设计？

JVM 的每个设计决策都有其历史背景和性能考量。本文在分析每个关键设计时，都会解释「为什么这样而不是那样」，帮助读者建立设计直觉。

---


## 1. 设计哲学：为什么需要 SafepointSynchronize？

### 1.1 核心问题

**GC 需要所有 Java 线程暂停，但线程状态各不相同，如何协调？**

问题清单：
- 线程正在执行字节码（解释模式）
- 线程正在执行 JIT 编译后的机器码
- 线程正在执行 native 代码
- 线程已经被阻塞（等待锁）
- 线程正在 VM 中执行

如何让所有这些状态的线程都安全地停下来？

### 1.2 解决方案：状态机 + 协作式暂停

```
┌─────────────────────────────────────────────────────────────────┐
│                SafepointSynchronize 核心思想                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ 1. VMThread 发起安全点同步                                │    │
│  │                                                          │    │
│  │   SafepointSynchronize::begin()                          │    │
│  │       │                                                  │    │
│  │       ▼                                                  │    │
│  │   _state = _synchronizing  ← 全局状态变更                │    │
│  │       │                                                  │    │
│  │       ├── Thread Local Poll 模式:                        │    │
│  │       │   遍历所有线程 → arm_local_poll(thread)          │    │
│  │       │   (设置 polling_page = bad_page)                 │    │
│  │       │                                                  │    │
│  │       └── Global Page Poll 模式:                         │    │
│  │           make_polling_page_unreadable()                 │    │
│  │       │                                                  │    │
│  │       ▼                                                  │    │
│  │   等待所有线程到达安全点                                  │    │
│  │       │                                                  │    │
│  │       ├── 解释执行线程: dispatch table 检查 _state       │    │
│  │       ├── 编译执行线程: 访问 polling page 触发 SIGSEGV   │    │
│  │       ├── Native 线程: 返回时检查 _state                 │    │
│  │       └── 已阻塞线程: 自动视为已到达安全点               │    │
│  │       │                                                  │    │
│  │       ▼                                                  │    │
│  │   _state = _synchronized  ← 所有线程已暂停               │    │
│  │                                                          │    │
│  └─────────────────────────────────────────────────────────┘    │
│                              │                                   │
│                              ▼                                   │
│                      [执行 GC 操作]                              │
│                              │                                   │
│                              ▼                                   │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ 2. VMThread 结束安全点同步                                │    │
│  │                                                          │    │
│  │   SafepointSynchronize::end()                            │    │
│  │       │                                                  │    │
│  │       ├── 恢复 polling page 可读                          │    │
│  │       │                                                  │    │
│  │       └── 唤醒所有线程                                    │    │
│  │           disarm_local_poll(thread)                      │    │
│  │           cur_state->restart()                           │    │
│  │       │                                                  │    │
│  │       ▼                                                  │    │
│  │   _state = _not_synchronized                             │    │
│  │                                                          │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 1.3 五种线程状态的处理方式

```
┌─────────────────────────────────────────────────────────────────┐
│                     五种线程状态处理                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. 解释执行 (Running interpreted)                               │
│     ─────────────────────────────                                │
│     机制: 修改 interpreter dispatch table                        │
│     操作: notice_safepoints() 插入安全点检查                     │
│     检查: 每次字节码分发前检查 _state                            │
│                                                                  │
│  2. 执行 Native 代码 (Running native)                            │
│     ─────────────────────────────                                │
│     机制: 返回时检查 safepoint _state                            │
│     操作: 不等待，标记后跳过                                     │
│     原因: Native 代码不操作 Java 堆，安全                       │
│                                                                  │
│  3. 编译执行 (Running compiled)                                  │
│     ─────────────────────────────                                │
│     机制: Polling Page + SIGSEGV                                 │
│     操作: arm_local_poll() → 访问 bad_page → 触发异常          │
│     位置: 方法返回、循环回边处插入轮询代码                       │
│                                                                  │
│  4. 已阻塞 (Blocked)                                             │
│     ─────────────────                                            │
│     机制: 自动视为已到达安全点                                   │
│     原因: 阻塞线程不执行 Java 代码，安全                        │
│                                                                  │
│  5. VM 中执行 (In VM)                                            │
│     ─────────────────                                            │
│     机制: 等待线程自行阻塞                                       │
│     操作: 状态转换时检查 safepoint                               │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. 源码分析

### 2.1 状态机定义

```cpp
class SafepointSynchronize : AllStatic {
 public:
  enum SynchronizeState {
      _not_synchronized = 0,   // 未同步，正常运行
      _synchronizing    = 1,   // 同步中，等待线程到达
      _synchronized     = 2    // 已同步，所有线程暂停
  };
  
 private:
  static volatile SynchronizeState _state;  // 当前状态
  static volatile int _waiting_to_block;     // 还需等待的线程数
};
```

### 2.2 begin() - 开始安全点同步

```cpp
void SafepointSynchronize::begin() {
    // 1. 只能是 VMThread 调用
    assert(Thread::current()->is_VM_thread(), 
           "Only VM thread may execute a safepoint");
    
    // 2. 通知堆准备安全点
    Universe::heap()->safepoint_synchronize_begin();
    
    // 3. 获取 Threads_lock，防止线程创建/销毁
    Threads_lock->lock();
    
    // 4. 初始状态检查
    assert(_state == _not_synchronized, 
           "trying to safepoint synchronize with wrong state");
    
    // 5. 获取线程数
    int nof_threads = Threads::number_of_threads();
    _waiting_to_block = nof_threads;
    int still_running = nof_threads;
    
    // 6. 设置状态为同步中
    _state = _synchronizing;
    
    // 7. 根据 Polling 模式采取行动
    if (SafepointMechanism::uses_thread_local_poll()) {
        // ===== Thread Local Poll 模式 =====
        // 遍历所有线程，设置 armed 状态
        for (JavaThreadIteratorWithHandle jtiwh; 
             JavaThread *cur = jtiwh.next(); ) {
            SafepointMechanism::arm_local_poll(cur);
            // cur->polling_page = bad_page (不可读)
        }
    }
    
    if (SafepointMechanism::uses_global_page_poll()) {
        // ===== Global Page Poll 模式 =====
        // 修改解释器 dispatch table
        Interpreter::notice_safepoints();
        
        // 保护 polling page（设为不可读）
        PageArmed = 1;
        os::make_polling_page_unreadable();
    }
    
    // 8. 内存屏障：确保状态变更对所有 CPU 可见
    OrderAccess::fence();
    
    // 9. 等待所有线程到达安全点
    while (still_running > 0) {
        for (JavaThread *cur = jtiwh.next(); ) {
            ThreadSafepointState *cur_state = cur->safepoint_state();
            
            if (cur_state->is_running()) {
                // 检查线程当前状态
                cur_state->examine_state_of_thread();
                
                if (!cur_state->is_running()) {
                    still_running--;
                }
            }
        }
        
        // 检查是否超时
        if (SafepointTimeout && safepoint_limit_time > 0) {
            check_for_timeout(still_running);
        }
    }
    
    // 10. 所有线程已暂停，标记为同步完成
    _state = _synchronized;
}
```

**关键步骤详解**：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | VMThread 检查 | 只有 VMThread 能触发安全点 |
| 3 | Threads_lock | 防止安全点期间线程创建/销毁 |
| 7 | arm_local_poll | 设置 polling page 为 bad_page |
| 9 | 等待循环 | 轮询检查所有线程状态 |
| 10 | _synchronized | 确认所有线程已暂停 |

### 2.3 end() - 结束安全点同步

```cpp
void SafepointSynchronize::end() {
    // 1. 只能是 VMThread 调用
    assert(Thread::current()->is_VM_thread(), 
           "Only VM thread can execute a safepoint");
    
    // 2. Global Page 模式：恢复 polling page 可读
    if (PageArmed) {
        os::make_polling_page_readable();
        PageArmed = 0;
    }
    
    // 3. Global Page 模式：恢复解释器
    if (SafepointMechanism::uses_global_page_poll()) {
        Interpreter::ignore_safepoints();
    }
    
    // 4. 设置状态为未同步
    _state = _not_synchronized;
    OrderAccess::fence();
    
    // 5. 唤醒所有线程
    if (SafepointMechanism::uses_thread_local_poll()) {
        // Thread Local 模式：逐个 disarm
        for (JavaThread *current = jtiwh.next(); ) {
            ThreadSafepointState* cur_state = current->safepoint_state();
            cur_state->restart();  // 重置状态为 running
            SafepointMechanism::disarm_local_poll(current);
            // cur->polling_page = good_page (可读)
        }
    } else {
        // Global 模式：统一唤醒
        for (JavaThread *current = jtiwh.next(); ) {
            ThreadSafepointState* cur_state = current->safepoint_state();
            cur_state->restart();
        }
    }
    
    // 6. 释放 Threads_lock
    Threads_lock->unlock();
    
    // 7. 通知堆安全点结束
    Universe::heap()->safepoint_synchronize_end();
}
```

### 2.4 ThreadSafepointState - 线程安全点状态

```cpp
class ThreadSafepointState : public CHeapObj<mtThread> {
 public:
  enum suspend_type {
    _running      = 0,   // 运行中，未到达安全点
    _at_safepoint = 1,   // 已到达安全点（如阻塞在锁上）
    _call_back    = 2    // 等待回调（解释/编译代码中）
  };
  
  // 检查线程当前状态
  void examine_state_of_thread();
  
  // 重启线程
  void restart();
};

void ThreadSafepointState::examine_state_of_thread() {
    switch (_thread->thread_state()) {
        case _thread_in_vm:
        case _thread_in_Java:
            // 还在运行，继续等待
            break;
            
        case _thread_blocked:
        case _thread_in_native:
            // 已阻塞或在 native，视为已到达安全点
            set_at_safepoint();
            break;
            
        case _thread_new:
        case _thread_uninitialized:
            // 新线程，不计入
            set_at_safepoint();
            break;
    }
}
```

---

## 3. 完整 GC STW 流程

```
┌─────────────────────────────────────────────────────────────────┐
│                     GC STW 完整流程                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  VMThread                                                       │
│      │                                                          │
│      ▼                                                          │
│  SafepointSynchronize::begin()                                  │
│      │                                                          │
│      ├── _state = _synchronizing                                │
│      │                                                          │
│      ├── Thread Local Poll 模式:                                │
│      │   for each JavaThread:                                   │
│      │       SafepointMechanism::arm_local_poll(thread)         │
│      │       thread->polling_page = bad_page (不可读)           │
│      │                                                          │
│      ├── OrderAccess::fence()  // 内存屏障                      │
│      │                                                          │
│      ├── 等待所有线程到达安全点:                                 │
│      │   while (still_running > 0):                             │
│      │       for each thread:                                   │
│      │           examine_state_of_thread()                      │
│      │                                                          │
│      └── _state = _synchronized                                 │
│                      │                                          │
│                      ▼                                          │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              所有 Java 线程已暂停                          │   │
│  │                                                          │   │
│  │   Java Thread 1 (编译执行)                               │   │
│  │      │ 执行到轮询点                                      │   │
│  │      ▼                                                   │   │
│  │   mov rax, [r15 + polling_page_offset]                   │   │
│  │      │ 尝试读取 bad_page                                 │   │
│  │      ▼                                                   │   │
│  │   SIGSEGV 触发                                           │   │
│  │      │                                                   │   │
│  │      ▼                                                   │   │
│  │   JVM_handle_linux_signal()                              │   │
│  │      │                                                   │   │
│  │      └── 地址是 polling_page?                            │   │
│  │              │                                           │   │
│  │              ▼                                           │   │
│  │          SafepointSynchronize::block()                   │   │
│  │              │                                           │   │
│  │              ▼                                           │   │
│  │          block_if_requested()                            │   │
│  │              │ 等待 _state = _not_synchronized           │   │
│  │              ▼                                           │   │
│  │          [线程暂停，等待唤醒]                             │   │
│  │                                                          │   │
│  │   Java Thread 2, 3, ... (同样流程)                       │   │
│  │                                                          │   │
│  └─────────────────────────────────────────────────────────┘   │
│                      │                                          │
│                      ▼                                          │
│  [执行 GC: 标记、清除、整理]                                     │
│                      │                                          │
│                      ▼                                          │
│  SafepointSynchronize::end()                                    │
│      │                                                          │
│      ├── _state = _not_synchronized                             │
│      │                                                          │
│      ├── for each JavaThread:                                   │
│      │       SafepointMechanism::disarm_local_poll(thread)      │
│      │       thread->polling_page = good_page (可读)            │
│      │       cur_state->restart()                               │
│      │                                                          │
│      └── Threads_lock->unlock()                                 │
│                      │                                          │
│                      ▼                                          │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                所有 Java 线程恢复执行                      │   │
│  │                                                          │   │
│  │   Java Thread 1 (从信号处理返回)                          │   │
│  │      │                                                   │   │
│  │      └── 继续执行 mov rax, [r15 + ...]                   │   │
│  │              这次读取 good_page，成功                     │   │
│  │                                                          │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. 性能优化

### 4.1 为什么 Thread Local Poll 更高效？

```
Global Page Poll (传统):
┌─────────────────────────────────────────────────────────┐
│  SafepointSynchronize::begin()                           │
│       │                                                  │
│       └── os::make_polling_page_unreadable()             │
│               │                                          │
│               ▼                                          │
│       [系统调用] mprotect(PROT_NONE)  ← 全局操作，慢     │
│               │                                          │
│               └── 影响所有 CPU 的 TLB                    │
│                                                          │
└─────────────────────────────────────────────────────────┘

Thread Local Poll (JDK11+ 默认):
┌─────────────────────────────────────────────────────────┐
│  SafepointSynchronize::begin()                           │
│       │                                                  │
│       └── for each thread:                               │
│               SafepointMechanism::arm_local_poll(thread) │
│               thread->polling_page = bad_page            │
│               │                                          │
│               ▼                                          │
│       [内存写入] 仅修改线程本地变量，快                   │
│       无系统调用，无 TLB 刷新                            │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

### 4.2 关键性能指标

| 指标 | Global Page | Thread Local |
|------|-------------|--------------|
| armed 操作 | mprotect (系统调用) | 内存写入 |
| TLB 影响 | 全局刷新 | 无 |
| 支持单个线程暂停 | 否 | 是 (Handshake) |
| 延迟 | ~10-100μs | ~1μs |

---

## 5. 相关 JVM 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-XX:+ThreadLocalHandshakes` | true (JDK11+) | 使用线程本地轮询 |
| `-XX:+SafepointTimeout` | false | 启用安全点超时检查 |
| `-XX:SafepointTimeoutDelay` | 10000 (ms) | 安全点超时时间 |
| `-XX:+PrintSafepointStatistics` | false | 打印安全点统计 |

---

## 6. 总结

### 核心要点

1. **作用**: 协调所有 Java 线程在 GC 时安全暂停

2. **核心方法**:
   - `begin()`: 设置 armed 状态，等待所有线程到达安全点
   - `end()`: 设置 disarmed 状态，唤醒所有线程

3. **线程状态处理**:
   - 解释执行: dispatch table 检查
   - 编译执行: Polling Page 触发 SIGSEGV
   - Native: 返回时检查
   - 阻塞: 自动视为已到达

4. **状态机**:
   - `_not_synchronized` → `_synchronizing` → `_synchronized`

5. **性能优化**:
   - Thread Local Poll 避免系统调用
   - 只在关键位置插入轮询代码

### 与 SafepointMechanism 的关系

```
SafepointSynchronize (协调者)
        │
        ├── 调用 SafepointMechanism::arm_local_poll()     (设置 armed)
        ├── 调用 SafepointMechanism::disarm_local_poll()  (设置 disarmed)
        │
        └── 依赖信号处理器 (os::init_2() 中安装)
                │
                └── SIGSEGV → JVM_handle_linux_signal()
                                    │
                                    └── 识别 polling page
                                            │
                                            └── block_if_requested()
                                                    │
                                                    └── 等待 _state 变更
```

---

## 7. 下一步学习建议

基于当前分析，我推荐下一步学习：

### 推荐选项 A: `VMThread`（虚拟机线程，建议首选）
- **原因**: 实际调用 SafepointSynchronize 的线程，GC 的执行者
- **内容**: VMOperationQueue、GC 触发流程、VM_Operation 执行
- **重要性**: ⭐⭐⭐⭐⭐
- **关联性**: SafepointSynchronize 的调用方

### 推荐选项 B: `JVM_handle_linux_signal()`（信号处理细节）
- **原因**: Safepoint 机制的核心，SIGSEGV 如何转换为线程暂停
- **内容**: ucontext_t 解析、Polling Page 识别、异常转换
- **重要性**: ⭐⭐⭐⭐
- **关联性**: SafepointMechanism 的底层实现

### 推荐选项 C: `Handshake`（线程级安全点）
- **原因**: Thread Local Poll 支持的新特性，单个线程暂停
- **内容**: Handshake 操作、线程状态同步
- **重要性**: ⭐⭐⭐⭐
- **关联性**: Thread Local Handshakes 的具体实现

**请问想继续分析哪一个？**
