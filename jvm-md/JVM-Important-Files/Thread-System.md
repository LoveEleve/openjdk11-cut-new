# 线程系统 (Thread System) 重要文件

> **源码路径**：`src/hotspot/share/runtime/`  
> **重要程度**：⭐⭐⭐⭐⭐

---

## 核心文件

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `thread.cpp` | ⭐⭐⭐⭐⭐ | JavaThread 和 NonJavaThread 的核心实现，管理线程生命周期、状态转换、栈操作 |
| `thread.hpp` | ⭐⭐⭐⭐⭐ | 线程类的核心定义，包含线程状态、优先级、JavaThread 接口声明 |
| `thread.inline.hpp` | ⭐⭐⭐⭐ | 线程内联函数，包括快速路径操作 |
| `threadSMR.cpp` | ⭐⭐⭐⭐ | Safe Memory Reclamation 实现，管理线程退出时的资源回收 |
| `threadLocalStorage.cpp` | ⭐⭐⭐⭐ | 线程本地存储 (TLS) 的实现 |
| `threadLocalStorage.hpp` | ⭐⭐⭐⭐ | 线程本地存储接口定义 |
| `osThread.cpp` | ⭐⭐⭐⭐⭐ | 操作系统线程的抽象和实现 |
| `osThread.hpp` | ⭐⭐⭐⭐⭐ | OS 线程相关的数据结构和接口定义 |
| `park.cpp` | ⭐⭐⭐⭐ | 线程挂起Object.wait/notify) |
| `park.hpp` | ⭐⭐⭐⭐ | Parker 类定义/唤醒机制 ( |
| `threadHeapSampler.cpp` | ⭐⭐⭐ | 线程堆内存采样，用于 JVM 诊断 |
| `semaphore.hpp` | ⭐⭐⭐⭐ | 信号量实现，用于线程同步 |
| `javaCalls.cpp` | ⭐⭐⭐⭐⭐ | Java 方法调用实现 (从 native 调用 Java) |
| `javaCalls.hpp` | ⭐⭐⭐⭐⭐ | JavaCalls 接口定义 |

---

## 线程状态相关

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `threadState.hpp` | ⭐⭐⭐⭐ | 线程状态定义（NEW, RUNNABLE, BLOCKED 等） |
| `javaThread.hpp` | ⭐⭐⭐⭐⭐ | JavaThread 类定义，继承 Thread |
| `javaThread.cpp` | ⭐⭐⭐⭐⭐ | JavaThread 核心实现 |
| `nativeThread.hpp` | ⭐⭐⭐ | 本地线程定义 |
| `threadHelper.cpp` | ⭐⭐⭐ | 线程创建辅助函数 |

---

## 线程本地存储 (TLS)

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `threadLocalStorage.cpp` | ⭐⭐⭐⭐ | TLS 底层实现 |
| `threadLocalStorage.inline.hpp` | ⭐⭐⭐ | TLS 内联函数 |
| `getThread.cpp` | ⭐⭐⭐⭐⭐ | 获取当前线程的实现 |

---

## 线程同步原语

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `mutex.cpp` | ⭐⭐⭐⭐⭐ | 互斥锁实现 |
| `mutex.hpp` | ⭐⭐⭐⭐⭐ | 互斥锁接口 |
| `mutexLocker.cpp` | ⭐⭐⭐⭐ | JVM 内部锁声明和初始化 |
| `platform_mutex.cpp` | ⭐⭐⭐⭐ | 平台特定的互斥锁实现 |
| `semaphore.cpp` | ⭐⭐⭐ | 信号量实现 |
| `spinYield.hpp` | ⭐⭐⭐ | 自旋等待实现 |

---

## 线程创建与销毁

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `os_linux.cpp` | ⭐⭐⭐⭐⭐ | Linux 平台线程创建（pthread_create） |
| `os_posix.cpp` | ⭐⭐⭐⭐ | POSIX 线程抽象 |
| `osThread_linux.cpp` | ⭐⭐⭐⭐ | Linux OSThread 实现 |

---

## 关键数据结构

```cpp
// JavaThread 核心状态
enum JavaThreadState {
    _thread_new = 0,           // 新创建，未启动
    _thread_new_trans = 1,    // 转换到RUNNABLE
    _thread_in_native = 2,     // 执行native代码
    _thread_in_native_trans = 3,
    _thread_blocked = 4,       // 阻塞状态
    _thread_blocked_trans = 5,
    _thread_in_vm = 6,         // 在VM中执行
    _thread_in_vm_trans = 7,
    _thread_in_Java = 8,       // 执行Java字节码
    _thread_in_Java_trans = 9,
    _thread_not_started = 10,  // 未启动
    _thread_terminated = 11    // 已终止
};
```

---

## 核心调用链

```
Threads::create_vm()
  → JavaThread::JavaThread()
  → Thread::start()
    → os::create_thread()
      → pthread_create()
        → JavaThread::thread_main_inner()
          → thread->run()
            → ConcurrentlyRunner::run() / JavaThread::call_on_newline()
```

---

## 学习建议

1. **优先级 P0**：thread.cpp, javaThread.cpp, osThread.cpp
2. **优先级 P1**：javaCalls.cpp, threadLocalStorage.cpp, park.cpp
3. **优先级 P2**：mutex.cpp, threadSMR.cpp

---

*线程系统是 JVM 的核心基础设施，理解线程创建、状态转换、调度是深入 JVM 的第一步。*
