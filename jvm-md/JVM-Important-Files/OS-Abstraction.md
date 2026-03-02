# 操作系统抽象层 (OS Abstraction Layer) 重要文件

> **源码路径**：`src/hotspot/os/`, `src/hotspot/os_cpu/`  
> **重要程度**：⭐⭐⭐⭐⭐

---

## 通用 OS 抽象

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `os.cpp` | ⭐⭐⭐⭐⭐ | 操作系统抽象层核心 |
| `os.hpp` | ⭐⭐⭐⭐⭐ | OS 抽象接口定义 |
| `os.inline.hpp` | ⭐⭐⭐⭐⭐ | OS 内联函数 |

---

## Linux 特定

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `os_linux.cpp` | ⭐⭐⭐⭐⭐ | Linux 特定实现 |
| `os_linux.hpp` | ⭐⭐⭐⭐⭐ | Linux 接口 |
| `os_linux.inline.hpp` | ⭐⭐⭐⭐⭐ | Linux 内联 |
| `osThread_linux.cpp` | ⭐⭐⭐⭐⭐ | Linux OSThread 实现 |
| `osThread_linux.hpp` | ⭐⭐⭐⭐⭐ | OSThread Linux 接口 |

---

## 线程创建

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `thread_linux.cpp` | ⭐⭐⭐⭐⭐ | Linux 线程实现 |
| `thread_linux.hpp` | ⭐⭐⭐⭐⭐ | Thread Linux 接口 |
| `pthread_wrapper.hpp` | ⭐⭐⭐⭐ | pthread 包装器 |

---

## 性能计数器

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `os_perf_linux.cpp` | ⭐⭐⭐⭐ | Linux 性能计数器 |
| `os_perf_linux.hpp` | ⭐⭐⭐⭐ | Perf 接口 |
| `perfMemory_linux.cpp` | ⭐⭐⭐⭐ | Linux 共享内存性能数据 |

---

## 内存管理

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `os_linux.cpp` | ⭐⭐⭐⭐⭐ | mmap, munmap, mprotect 等 |
| `gcSync.cpp` | ⭐⭐⭐⭐ | GC 同步原语 |

---

## 信号处理

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `os_linux.cpp` | ⭐⭐⭐⭐⭐ | signal handler 安装 |
| `os_linux_signal.cpp` | ⭐⭐⭐⭐ | 信号处理实现 |

---

## CPU 特定代码

### x86 Linux

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `os_cpu/linux_x86/os_linux_x86.cpp` | ⭐⭐⭐⭐⭐ | x86 Linux 特定代码 |
| `os_cpu/linux_x86/thread_linux_x86.cpp` | ⭐⭐⭐⭐⭐ | x86 Linux 线程实现 |
| `os_cpu/linux_x86/cpu_linux_x86.cpp` | ⭐⭐⭐⭐⭐ | x86 CPU 特定 |

### x86 通用

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `cpu/x86/vm_version_x86.cpp` | ⭐⭐⭐⭐ | x86 版本检测 |
| `cpu/x86/vm_version_x86.hpp` | ⭐⭐⭐⭐ | 版本接口 |
| `cpu/x86/assembler_x86.cpp` | ⭐⭐⭐⭐ | x86 汇编器 |
| `cpu/x86/assembler_x86.hpp` | ⭐⭐⭐⭐ | 汇编器接口 |
| `cpu/x86/macroAssembler_x86.cpp` | ⭐⭐⭐⭐ | x86 宏汇编器 |
| `cpu/x86/macroAssembler_x86.hpp` | ⭐⭐⭐⭐ | 宏汇编器接口 |

---

## 原子操作

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `atomic_linux_x86.hpp` | ⭐⭐⭐⭐⭐ | x86 原子操作 |
| `orderAccess_linux_x86.hpp` | ⭐⭐⭐⭐⭐ | 内存序实现 |

---

## 锁实现

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `mutex_linux.cpp` | ⭐⭐⭐⭐⭐ | Linux 互斥锁实现 |
| `os_linux.cpp` | ⭐⭐⭐⭐⭐ | pthread_mutex |

---

## 网络

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `socket_linux.cpp` | ⭐⭐⭐⭐⭐ | Socket 实现 |
| `socket_linux.hpp` | ⭐⭐⭐⭐⭐ | Socket 接口 |

---

## 核心调用链

```
线程创建：
JavaThread::start()
  → Thread::start()
    → os::create_thread()
      → pthread_create()
        → thread_native_entry()
          → JavaThread::run()
```

---

## Linux 系统调用

| 功能 | 系统调用 | 相关文件 |
|------|---------|---------|
| 线程创建 | pthread_create | os_linux.cpp |
| 内存映射 | mmap/munmap | os_linux.cpp |
| 信号处理 | sigaction/sigprocmask | os_linux.cpp |
| 文件操作 | open/read/write | os_linux.cpp |
| Socket | socket/bind/listen | socket_linux.cpp |
| 时间 | gettimeofday/clock_gettime | os_linux.cpp |

---

## 学习建议

1. **优先级 P0**：os_linux.cpp, thread_linux.cpp, atomic_linux_x86.hpp, orderAccess_linux_x86.hpp
2. **优先级 P1**：os_cpu/linux_x86/*.cpp, pthread_wrapper.hpp, mutex_linux.cpp
3. **优先级 P2**：socket_linux.cpp, perfMemory_linux.cpp
