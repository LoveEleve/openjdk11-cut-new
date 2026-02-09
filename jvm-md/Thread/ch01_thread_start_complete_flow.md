# Thread.start() 完整链路：从 Java 到 pthread_create

> 基于 OpenJDK 11 源码，标准环境 `-Xms8g -Xmx8g -XX:+UseG1GC`，Linux x86_64

---

## 第一章：为什么要分析 Thread.start()

**面试频率**：Thread.start() 是 Java 多线程面试最高频的入口级问题。

**核心问题**：
- `new Thread().start()` 到底发生了什么？
- Java 线程和操作系统线程是什么关系？1:1 还是 M:N？
- 为什么 `start()` 只能调用一次？
- 父子线程之间如何同步？
- 线程什么时候真正开始执行 `run()` 方法？

**结论前置**：OpenJDK 11 中 Java 线程与 OS 线程是 **1:1 模型**（即每个 `java.lang.Thread` 对象对应一个 `pthread`）。`Thread.start()` 最终调用 `pthread_create` 创建操作系统线程，通过两次 Monitor 握手同步父子线程，最终在子线程中通过 `JavaCalls::call_virtual` 调用 Java 层的 `Thread.run()`。

---

## 第二章：完整调用链路总览

```
Java Thread.start()                               [Thread.java:780]
  ├─ threadStatus != 0 → IllegalThreadStateException
  ├─ group.add(this)
  └─ native start0()                              [Thread.java:812]
      └─ JVM_StartThread()                        [jvm.cpp:2882]
          │                                        (通过 RegisterNatives 映射, Thread.c:44)
          ├─ [持 Threads_lock]
          │   ├─ 检查重复启动
          │   └─ new JavaThread(&thread_entry, sz) [jvm.cpp:2923]
          │       └─ JavaThread::JavaThread()      [thread.cpp:1849]
          │           ├─ set_entry_point(&thread_entry)
          │           └─ os::create_thread()       [os_linux.cpp:935]
          │               ├─ new OSThread → state=ALLOCATED
          │               ├─ 计算栈大小 (get_initial_stack_size)
          │               ├─ pthread_create(thread_native_entry) [os_linux.cpp:999]
          │               │   └─ [子线程] thread_native_entry()  [os_linux.cpp:863]
          │               │       ├─ record_stack_base_and_size()
          │               │       ├─ initialize_thread_current() (TLS)
          │               │       ├─ set_state(INITIALIZED) → notify_all()  ──→ 唤醒父线程
          │               │       └─ wait(INITIALIZED)  ←── 等待父线程启动
          │               └─ wait(ALLOCATED)  ←── 父线程等待子线程初始化
          │                  (子线程 notify_all 后，父线程从此处醒来)
          ├─ native_thread->prepare(jthread)       [thread.cpp:3357]
          │   ├─ set_threadObj() ──→ JavaThread._threadObj = java.lang.Thread
          │   ├─ set_thread() ──→ java.lang.Thread.eetop = JavaThread*
          │   ├─ Thread::set_priority()
          │   └─ Threads::add(this)                [thread.cpp:4675]
          │       ├─ 头插入 _thread_list
          │       ├─ ThreadsSMRSupport::add_thread()
          │       └─ _number_of_non_daemon_threads++
          └─ Thread::start(native_thread)          [thread.cpp:563]
              ├─ set_thread_status(RUNNABLE)  (java.lang.Thread 层面)
              └─ os::start_thread()                [os.cpp:892]
                  ├─ set_state(RUNNABLE)  (OSThread 层面)
                  └─ pd_start_thread() → notify()  [os_linux.cpp:1144]
                     └─ [子线程被唤醒]
                         └─ thread->call_run()     [thread.cpp:426]
                             └─ JavaThread::run()  [thread.cpp:1921]
                                 ├─ initialize_tlab()
                                 ├─ create_stack_guard_pages()
                                 ├─ transition(_thread_new → _thread_in_vm)
                                 └─ thread_main_inner()  [thread.cpp:1961]
                                     └─ entry_point()(this, this)
                                         └─ thread_entry()  [jvm.cpp:2867]
                                             └─ JavaCalls::call_virtual("run")
                                                 └─ Java Thread.run() 开始执行！
```

---

## 第三章：Java 层 — Thread.start() 和 start0()

### 3.1 Thread.start() 源码

**文件**: `src/java.base/share/classes/java/lang/Thread.java`，第 780~812 行

```java
public synchronized void start() {
    // threadStatus == 0 对应 Thread.State.NEW
    // 只有 NEW 状态才能启动，保证 start() 只能调用一次
    if (threadStatus != 0)
        throw new IllegalThreadStateException();

    // 将线程加入 ThreadGroup 的 threads 数组
    // 同时递减 ThreadGroup.nUnstartedThreads
    group.add(this);

    boolean started = false;
    try {
        start0();          // ★ 进入 native 层
        started = true;
    } finally {
        try {
            if (!started) {
                group.threadStartFailed(this);
            }
        } catch (Throwable ignore) {
        }
    }
}

private native void start0();
```

**关键设计**：
1. **`synchronized`**：`start()` 是同步方法，防止并发调用
2. **`threadStatus != 0` 检查**：`Thread.State.NEW` 对应值 0，只有新创建的线程才能 start。start 过的线程 `threadStatus` 会被 JVM 设为 `RUNNABLE`（在 `Thread::start()` 中），因此二次调用必抛异常
3. **`group.add(this)`**：先加入线程组。如果 `start0()` 失败，在 finally 中调用 `threadStartFailed` 回滚

### 3.2 Native 注册表

**文件**: `src/java.base/share/native/libjava/Thread.c`，第 43~71 行

```c
static JNINativeMethod methods[] = {
    {"start0",           "()V",        (void *)&JVM_StartThread},
    {"stop0",            "(" OBJ ")V", (void *)&JVM_StopThread},
    {"isAlive",          "()Z",        (void *)&JVM_IsThreadAlive},
    {"suspend0",         "()V",        (void *)&JVM_SuspendThread},
    {"resume0",          "()V",        (void *)&JVM_ResumeThread},
    {"setPriority0",     "(I)V",       (void *)&JVM_SetThreadPriority},
    {"yield",            "()V",        (void *)&JVM_Yield},
    {"sleep",            "(J)V",       (void *)&JVM_Sleep},
    {"currentThread",    "()" THD,     (void *)&JVM_CurrentThread},
    {"countStackFrames", "()I",        (void *)&JVM_CountStackFrames},
    {"interrupt0",       "()V",        (void *)&JVM_Interrupt},
    {"isInterrupted",    "(Z)Z",       (void *)&JVM_IsInterrupted},
    {"holdsLock",        "(" OBJ ")Z", (void *)&JVM_HoldsLock},
    {"getThreads",        "()[" THD,   (void *)&JVM_GetAllThreads},
    {"dumpThreads",      "([" THD ")[[" STE, (void *)&JVM_DumpThreads},
    {"setNativeName",    "(" STR ")V", (void *)&JVM_SetNativeThreadName},
};

JNIEXPORT void JNICALL
Java_java_lang_Thread_registerNatives(JNIEnv *env, jclass cls) {
    (*env)->RegisterNatives(env, cls, methods, ARRAY_LENGTH(methods));
}
```

Thread 类共注册 **16 个 native 方法**。`start0` 映射到 `JVM_StartThread`。

---

## 第四章：JVM_StartThread — HotSpot 线程创建入口

### 4.1 thread_entry 回调函数

**文件**: `src/hotspot/share/prims/jvm.cpp`，第 2867~2879 行

```cpp
static void thread_entry(JavaThread* thread, TRAPS) {
    HandleMark hm(THREAD);
    Handle obj(THREAD, thread->threadObj());  // 获取 java.lang.Thread 对象
    JavaValue result(T_VOID);
    JavaCalls::call_virtual(&result,
                            obj,
                            SystemDictionary::Thread_klass(),
                            vmSymbols::run_method_name(),       // "run"
                            vmSymbols::void_method_signature(), // "()V"
                            THREAD);
}
```

这个函数是线程真正开始执行时的 C++ 入口——通过 `JavaCalls::call_virtual` 调用 Java 层的 `Thread.run()` 方法。它在 `new JavaThread()` 时作为 `entry_point` 保存，在子线程运行时被调用。

### 4.2 JVM_StartThread 完整实现

**文件**: `src/hotspot/share/prims/jvm.cpp`，第 2882~2970 行

```cpp
JVM_ENTRY(void, JVM_StartThread(JNIEnv* env, jobject jthread))
  JVMWrapper("JVM_StartThread");
  JavaThread *native_thread = NULL;
  bool throw_illegal_thread_state = false;

  {
    // ① 加锁保护全局线程列表
    MutexLocker mu(Threads_lock);

    // ② 检查线程是否已经启动过
    //    java_lang_Thread::thread() 读取 eetop 字段
    //    如果不为 NULL，说明已有 JavaThread 关联
    if (java_lang_Thread::thread(JNIHandles::resolve_non_null(jthread)) != NULL) {
      throw_illegal_thread_state = true;
    } else {
      // ③ 获取 Java 层设置的栈大小（Thread(ThreadGroup, Runnable, String, long) 构造器的 stackSize 参数）
      jlong size = java_lang_Thread::stackSize(JNIHandles::resolve_non_null(jthread));
      size_t sz = size > 0 ? (size_t)size : 0;

      // ④ ★ 创建 JavaThread 对象
      //    传入 thread_entry 作为回调，sz 作为请求的栈大小
      native_thread = new JavaThread(&thread_entry, sz);

      // ⑤ 如果 OS 线程创建成功，执行 prepare 绑定
      if (native_thread->osthread() != NULL) {
        native_thread->prepare(jthread);
      }
    }
  } // 释放 Threads_lock

  if (throw_illegal_thread_state) {
    THROW(vmSymbols::java_lang_IllegalThreadStateException());
  }

  // ⑥ 创建失败处理
  if (native_thread->osthread() == NULL) {
    native_thread->smr_delete();
    if (JvmtiExport::should_post_resource_exhausted()) {
      JvmtiExport::post_resource_exhausted(
        JVMTI_RESOURCE_EXHAUSTED_OOM_ERROR | JVMTI_RESOURCE_EXHAUSTED_THREADS,
        os::native_thread_creation_failed_msg());
    }
    THROW_MSG(vmSymbols::java_lang_OutOfMemoryError(),
              os::native_thread_creation_failed_msg());
  }

  // ⑦ ★ 启动线程
  Thread::start(native_thread);
JVM_END
```

**六步核心流程**：

| 步骤 | 操作 | 说明 |
|------|------|------|
| ① | `MutexLocker mu(Threads_lock)` | 全局锁保护 |
| ② | 检查 `eetop` | 防止重复启动 |
| ③ | 获取 `stackSize` | 用户可通过构造器指定 |
| ④ | `new JavaThread(&thread_entry, sz)` | 创建 C++ 线程对象 + OS 线程 |
| ⑤ | `prepare(jthread)` | 建立双向关联 + 加入全局列表 |
| ⑥ | `Thread::start(native_thread)` | 设置 RUNNABLE + 唤醒子线程 |

---

## 第五章：JavaThread 构造 — 从 C++ 对象到 OS 线程

### 5.1 JavaThread 构造函数

**文件**: `src/hotspot/share/runtime/thread.cpp`，第 1849~1871 行

```cpp
JavaThread::JavaThread(ThreadFunction entry_point, size_t stack_sz) :
    Thread() {
  initialize();                      // 初始化 50+ 个成员变量
  _jni_attach_state = _not_attaching_via_jni;
  set_entry_point(entry_point);      // ★ 保存入口函数指针
  os::ThreadType thr_type = os::java_thread;
  thr_type = entry_point == &compiler_thread_entry ? os::compiler_thread :
             os::java_thread;
  os::create_thread(this, thr_type, stack_sz);  // ★ 创建 OS 线程
}
```

构造函数做三件事：
1. **初始化成员变量**：`initialize()` 设置 `_entry_point`、`_threadObj`、`_anchor`、`_stack_base` 等 50+ 字段
2. **保存入口函数**：`_entry_point = thread_entry`，后续子线程执行时回调
3. **创建 OS 线程**：`os::create_thread` 调用 `pthread_create`

> 注意：编译线程 (`compiler_thread_entry`) 使用不同的 `ThreadType`，会影响栈大小（4MB vs 1MB）。

### 5.2 JavaThread::prepare() — 双向关联与全局注册

**文件**: `src/hotspot/share/runtime/thread.cpp`，第 3357~3399 行

```cpp
void JavaThread::prepare(jobject jni_thread, ThreadPriority prio) {
  assert(Threads_lock->owner() == Thread::current(), "must have threads lock");

  Handle thread_oop(Thread::current(),
                    JNIHandles::resolve_non_null(jni_thread));

  // ★ 正向关联：JavaThread._threadObj → java.lang.Thread 对象
  set_threadObj(thread_oop());
  // ★ 反向关联：java.lang.Thread.eetop → JavaThread* 指针
  java_lang_Thread::set_thread(thread_oop(), this);

  // 设置优先级
  if (prio == NoPriority) {
    prio = java_lang_Thread::priority(thread_oop());
  }
  Thread::set_priority(this, prio);

  // ★ 加入全局线程列表
  Threads::add(this);
}
```

**双向关联模型**：

```
┌──────────────────────┐          ┌──────────────────────┐
│  java.lang.Thread    │          │     JavaThread        │
│                      │          │     (C++ 对象)        │
│  eetop ─────────────────────→  │                      │
│  threadStatus        │          │  _threadObj ─────────────→ java.lang.Thread
│  name                │  ←───────────────────────────── │                      │
│  priority            │          │  _entry_point        │
│  daemon              │          │  _osthread ──→ OSThread
│  group               │          │  _anchor             │
└──────────────────────┘          └──────────────────────┘
```

**`eetop` 字段**：`java.lang.Thread` 中的 `long` 类型字段，JVM 用它存储 `JavaThread*` 指针。这是判断 `isAlive()` 的唯一依据：`eetop != NULL` → alive。

---

## 第六章：os::create_thread — Linux pthread 创建

### 6.1 完整实现

**文件**: `src/hotspot/os/linux/os_linux.cpp`，第 935~1049 行

```cpp
bool os::create_thread(Thread* thread, ThreadType thr_type, size_t req_stack_size) {
  // ① 创建 OSThread 对象
  OSThread* osthread = new OSThread(NULL, NULL);
  if (osthread == NULL) return false;

  osthread->set_thread_type(thr_type);
  osthread->set_state(ALLOCATED);      // 初始状态
  thread->set_osthread(osthread);      // JavaThread 关联 OSThread

  // ② 初始化 pthread 属性
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);  // 分离线程

  // ③ 计算栈大小
  size_t stack_size = os::Posix::get_initial_stack_size(thr_type, req_stack_size);
  size_t guard_size = os::Linux::default_guard_size(thr_type);
  if (stack_size <= SIZE_MAX - guard_size) {
    stack_size += guard_size;
  }
  pthread_attr_setstacksize(&attr, stack_size);
  pthread_attr_setguardsize(&attr, os::Linux::default_guard_size(thr_type));

  // ④ 调用 pthread_create，重试最多 3 次（应对 EAGAIN）
  ThreadState state;
  {
    pthread_t tid;
    int ret = 0;
    int limit = 3;
    do {
      ret = pthread_create(&tid, &attr,
                           (void*(*)(void*))thread_native_entry, thread);
    } while (ret == EAGAIN && limit-- > 0);

    pthread_attr_destroy(&attr);

    if (ret != 0) {
      // 创建失败
      thread->set_osthread(NULL);
      delete osthread;
      return false;
    }

    osthread->set_pthread_id(tid);

    // ⑤ ★ 父线程等待子线程初始化完成
    {
      Monitor* sync_with_child = osthread->startThread_lock();
      MutexLockerEx ml(sync_with_child, Mutex::_no_safepoint_check_flag);
      while ((state = osthread->get_state()) == ALLOCATED) {
        sync_with_child->wait(Mutex::_no_safepoint_check_flag);
      }
    }
  }

  if (state == ZOMBIE) {
    thread->set_osthread(NULL);
    delete osthread;
    return false;
  }

  return true;  // state == INITIALIZED
}
```

### 6.2 关键设计决策

| 决策 | 说明 |
|------|------|
| `PTHREAD_CREATE_DETACHED` | 不需要 `pthread_join` 回收资源，JVM 自行管理线程生命周期 |
| EAGAIN 重试 3 次 | 系统临时资源不足时给予机会恢复 |
| 父子线程同步等待 | 父线程等待子线程设置完 TLS、线程 ID 等，确保子线程完全初始化后才返回 |

### 6.3 栈大小计算

**文件**: `src/hotspot/os/posix/os_posix.cpp`，第 1558~1608 行

```cpp
size_t os::Posix::get_initial_stack_size(ThreadType thr_type, size_t req_stack_size) {
  size_t stack_size;
  if (req_stack_size == 0) {
    stack_size = default_stack_size(thr_type);
  } else {
    stack_size = req_stack_size;
  }

  switch (thr_type) {
  case os::java_thread:
    if (req_stack_size == 0 && JavaThread::stack_size_at_create() > 0) {
      stack_size = JavaThread::stack_size_at_create();  // ★ 优先使用 -Xss 的值
    }
    stack_size = MAX2(stack_size, _java_thread_min_stack_allowed);
    break;
  case os::compiler_thread:
    if (req_stack_size == 0 && CompilerThreadStackSize > 0) {
      stack_size = (size_t)(CompilerThreadStackSize * K);
    }
    stack_size = MAX2(stack_size, _compiler_thread_min_stack_allowed);
    break;
  default:
    if (req_stack_size == 0 && VMThreadStackSize > 0) {
      stack_size = (size_t)(VMThreadStackSize * K);
    }
    stack_size = MAX2(stack_size, _vm_internal_thread_min_stack_allowed);
    break;
  }

  return align_up(stack_size, vm_page_size());
}
```

**平台默认栈大小**（`os_linux_x86.cpp`，第 719~727 行）：

| 线程类型 | x86_64 (AMD64) | x86 (32-bit) |
|----------|----------------|---------------|
| Java 线程 | **1 MB** | 512 KB |
| 编译器线程 | **4 MB** | 2 MB |

**栈大小决策优先级**：
1. `Thread(group, target, name, stackSize)` 构造器指定的 `stackSize` > 0 → 使用该值
2. `-Xss` 参数（`JavaThread::stack_size_at_create()`）> 0 → 使用该值
3. 平台默认值（AMD64: 1MB）
4. 不低于最小值（`_java_thread_min_stack_allowed`）

**Guard Page**（`os_linux.cpp`，第 3544~3549 行）：

```cpp
size_t os::Linux::default_guard_size(os::ThreadType thr_type) {
  return ((thr_type == java_thread || thr_type == compiler_thread) ? 0 : page_size());
}
```

Java 线程和编译器线程的 guard page 大小为 **0**（HotSpot 自己管理栈保护页），其他线程使用 glibc 默认的一页。

---

## 第七章：父子线程两阶段握手

这是 Thread.start() 链路中最精妙的同步设计。通过 `OSThread::startThread_lock()` 这个 Monitor，父子线程进行两次握手。

### 7.1 thread_native_entry — 子线程的真正入口

**文件**: `src/hotspot/os/linux/os_linux.cpp`，第 863~933 行

```cpp
static void* thread_native_entry(Thread* thread) {
  // ① 记录栈信息
  thread->record_stack_base_and_size();

  // ② 初始化 TLS（Thread Local Storage）
  //    此后任何地方都可以通过 Thread::current() 获取当前线程
  thread->initialize_thread_current();

  OSThread* osthread = thread->osthread();
  Monitor* sync = osthread->startThread_lock();

  // ③ 设置线程 ID（Linux tid）
  osthread->set_thread_id(os::current_thread_id());

  // ④ NUMA 亲和性
  if (UseNUMA) {
    int lgrp_id = os::numa_get_group_id();
    if (lgrp_id != -1) {
      thread->set_lgrp_id(lgrp_id);
    }
  }

  // ⑤ 信号掩码 + 浮点状态
  os::Linux::hotspot_sigmask(thread);
  os::Linux::init_thread_fpu_state();

  // ⑥ ★ 第一次握手：通知父线程"我已初始化好"
  {
    MutexLockerEx ml(sync, Mutex::_no_safepoint_check_flag);
    osthread->set_state(INITIALIZED);  // ALLOCATED → INITIALIZED
    sync->notify_all();                // 唤醒父线程

    // ⑦ ★ 阻塞等待父线程调用 os::start_thread()
    while (osthread->get_state() == INITIALIZED) {
      sync->wait(Mutex::_no_safepoint_check_flag);
    }
  }

  // ⑧ 被唤醒后开始执行
  thread->call_run();

  return 0;
}
```

### 7.2 两阶段握手时序图

```
时间轴 ──────────────────────────────────────────────────────→

父线程 (调用 start() 的线程)           子线程 (新创建的 pthread)
─────────────────────────             ─────────────────────────
os::create_thread() {                 [pthread 刚创建]
  │                                     │
  │  pthread_create() ──────────→      thread_native_entry() {
  │                                       │
  │                                       record_stack_base_and_size()
  │                                       initialize_thread_current()
  │                                       set_thread_id(tid)
  │                                       hotspot_sigmask()
  │                                       │
  │                                       ┌─ 加锁(sync) ─────────┐
  │                                       │ set_state(INITIALIZED)│
  │  ┌─ wait(ALLOCATED) ─┐     ←────── │ notify_all()          │
  │  │ (从 wait 中醒来)   │               │ wait(INITIALIZED) ←──┤
  │  └────────────────────┘               │  [阻塞等待...]       │
  │                                       └──────────────────────┘
} // create_thread 返回                    │
                                           │
prepare(jthread) {                         │
  set_threadObj()                          │
  set_thread(eetop)                        │
  Threads::add()                           │
}                                          │
                                           │
Thread::start() {                          │
  set_thread_status(RUNNABLE)              │  (java.lang.Thread 层面)
  os::start_thread() {                     │
    set_state(RUNNABLE)                    │  (OSThread 层面)
    pd_start_thread() {                    │
      notify() ────────────────────→      │
    }                                      │  [从 wait 中醒来]
  }                                        │
}                                          ↓
                                          call_run()
                                          → JavaThread::run()
                                          → thread_main_inner()
                                          → thread_entry()
                                          → JavaCalls::call_virtual("run")
                                          → Java Thread.run()
```

### 7.3 为什么需要两阶段握手？

**第一阶段**（子线程 → 父线程）：
- 子线程需要先完成基本初始化（TLS、栈信息、线程ID、信号掩码）
- 父线程需要确认 OS 线程创建成功（不是 ZOMBIE），才能继续后续操作
- 如果不等待，`native_thread->prepare()` 可能操作一个还未初始化完毕的线程

**第二阶段**（父线程 → 子线程）：
- 父线程需要先完成 `prepare()`（双向关联 + 加入全局列表）和 `Thread::start()`（设置 RUNNABLE 状态）
- 子线程只有在被正式注册为 RUNNABLE 后才能开始执行用户代码
- 如果不等待，子线程可能在没有 `threadObj` 关联、没有加入 `_thread_list` 的情况下执行，GC/Safepoint 无法感知该线程

---

## 第八章：子线程执行链路

### 8.1 Thread::call_run()

**文件**: `src/hotspot/share/runtime/thread.cpp`，第 426~449 行

```cpp
void Thread::call_run() {
  register_thread_stack_with_NMT();   // NMT（Native Memory Tracking）注册
  JFR_ONLY(Jfr::on_thread_start(this);)  // JFR 事件

  this->run();  // ★ 多态调用，实际调用 JavaThread::run()
}
```

### 8.2 JavaThread::run() — 新 Java 线程的第一个方法

**文件**: `src/hotspot/share/runtime/thread.cpp`，第 1921~1958 行

```cpp
void JavaThread::run() {
  // ① 初始化 TLAB
  this->initialize_tlab();

  // ② 记录栈基址（用于栈溢出检测）
  this->record_base_of_stack_pointer();

  // ③ 创建栈保护页（Yellow Zone + Red Zone + Shadow Zone）
  this->create_stack_guard_pages();

  // ④ 缓存全局变量到线程本地
  this->cache_global_variables();

  // ⑤ ★ 关键状态转换：_thread_new → _thread_in_vm
  //    经过中间态 _thread_new_trans (=3)
  //    此处会检查 SafePoint，必要时阻塞
  ThreadStateTransition::transition_and_fence(this, _thread_new, _thread_in_vm);

  // ⑥ 分配 JNI 句柄块
  this->set_active_handles(JNIHandleBlock::allocate_block());

  // ⑦ JVMTI 通知
  if (JvmtiExport::should_post_thread_life()) {
    JvmtiExport::post_thread_start(this);
  }

  // ⑧ 进入线程主体
  thread_main_inner();
}
```

### 8.3 JavaThread::thread_main_inner()

**文件**: `src/hotspot/share/runtime/thread.cpp`，第 1961~1983 行

```cpp
void JavaThread::thread_main_inner() {
  assert(JavaThread::current() == this, "sanity check");
  assert(this->threadObj() != NULL, "just checking");

  // 检查无异常且未被 stop()
  if (!this->has_pending_exception() &&
      !java_lang_Thread::is_stillborn(this->threadObj())) {
    {
      ResourceMark rm(this);
      // 设置原生线程名（反映到 Linux 内核，/proc/[pid]/task/[tid]/comm）
      this->set_native_thread_name(this->get_thread_name());
    }
    HandleMark hm(this);
    // ★ 调用入口函数：thread_entry → JavaCalls::call_virtual("run")
    this->entry_point()(this, this);
  }

  DTRACE_THREAD_PROBE(stop, this);

  // 线程退出
  this->exit(false);
  // 安全删除
  this->smr_delete();
}
```

### 8.4 thread_entry → JavaCalls::call_virtual → Thread.run()

回顾 `thread_entry`（jvm.cpp:2867）的实现：

```cpp
static void thread_entry(JavaThread* thread, TRAPS) {
  HandleMark hm(THREAD);
  Handle obj(THREAD, thread->threadObj());
  JavaValue result(T_VOID);
  JavaCalls::call_virtual(&result,
                          obj,
                          SystemDictionary::Thread_klass(),
                          vmSymbols::run_method_name(),       // "run"
                          vmSymbols::void_method_signature(), // "()V"
                          THREAD);
}
```

`JavaCalls::call_virtual` 内部：
1. `LinkResolver::resolve_virtual_call` — 解析 `run()` 方法（虚分派，实际类可能重写了 `run()`）
2. `JavaCalls::call_helper` — 进入 Java 执行
3. `JavaCallWrapper` 构造 — **状态转换 `_thread_in_vm` → `_thread_in_Java`**
4. `StubRoutines::call_stub()` — 通过汇编 stub 进入 Java 字节码执行

**至此，Java 层的 `Thread.run()` 方法开始执行。**

---

## 第九章：两套线程状态机

Thread.start() 链路涉及两套独立但协同工作的状态机。

### 9.1 OSThread 状态机（OS 层面）

**文件**: `src/hotspot/share/runtime/osThread.hpp`，第 44~54 行

```cpp
enum ThreadState {
  ALLOCATED,                    // 内存已分配，尚未初始化
  INITIALIZED,                  // 已初始化但尚未启动
  RUNNABLE,                     // 已启动，可运行
  MONITOR_WAIT,                 // 等待 contended monitor lock
  CONDVAR_WAIT,                 // 等待条件变量
  OBJECT_WAIT,                  // Object.wait()
  BREAKPOINTED,                 // 断点挂起
  SLEEPING,                     // Thread.sleep()
  ZOMBIE                        // 已结束，等待回收
};
```

**Thread.start() 中的转换路径**：

```
ALLOCATED ──[子线程 thread_native_entry]──→ INITIALIZED ──[父线程 os::start_thread]──→ RUNNABLE
```

### 9.2 JavaThreadState 状态机（Safepoint 层面）

**文件**: `src/hotspot/share/utilities/globalDefinitions.hpp`，第 890~903 行

```cpp
enum JavaThreadState {
  _thread_uninitialized =  0,  // 不应出现
  _thread_new           =  2,  // 刚创建，正在初始化
  _thread_new_trans     =  3,  // 过渡态
  _thread_in_native     =  4,  // 执行 native 代码
  _thread_in_native_trans=  5,  // 过渡态
  _thread_in_vm         =  6,  // 执行 VM 代码
  _thread_in_vm_trans   =  7,  // 过渡态
  _thread_in_Java       =  8,  // 执行 Java 代码
  _thread_in_Java_trans =  9,  // 过渡态
  _thread_blocked       = 10,  // VM 中被阻塞
  _thread_blocked_trans = 11,  // 过渡态
};
```

**Thread.start() 中的转换路径**：

```
_thread_new (=2)
    │
    ↓  JavaThread::run() 中 transition_and_fence()
    │  经过 _thread_new_trans (=3)
    ↓
_thread_in_vm (=6)
    │
    ↓  JavaCallWrapper 构造中 transition()
    │  经过 _thread_in_vm_trans (=7)
    ↓
_thread_in_Java (=8)  ←── Thread.run() 开始执行
```

**过渡态的设计意义**：每个稳定态都有对应的 `_trans` 中间态（值 = 稳定态 + 1）。在 Safepoint 协议中，线程处于过渡态时会检查是否需要暂停。这保证了 Safepoint 能可靠地让所有线程停下来。

### 9.3 java.lang.Thread.threadStatus（Java 层状态）

**文件**: `src/hotspot/share/classfile/javaClasses.hpp`，第 407~434 行

```cpp
enum ThreadStatus {
  NEW                      = 0,
  RUNNABLE                 = JVMTI_THREAD_STATE_ALIVE + JVMTI_THREAD_STATE_RUNNABLE,
  SLEEPING                 = ...,
  IN_OBJECT_WAIT           = ...,
  IN_OBJECT_WAIT_TIMED     = ...,
  PARKED                   = ...,
  PARKED_TIMED             = ...,
  BLOCKED_ON_MONITOR_ENTER = ...,
  TERMINATED               = JVMTI_THREAD_STATE_TERMINATED
};
```

**Thread.start() 中的转换**：

```
NEW (=0)
  │
  ↓  Thread::start() 中 set_thread_status(RUNNABLE)
  │  [在 os::start_thread 之前设置]
  ↓
RUNNABLE
  │
  ↓  ... 线程运行中 ...
  ↓
  ↓  ensure_join() 中 set_thread_status(TERMINATED)
  ↓
TERMINATED
```

### 9.4 三套状态机的对应关系

| 阶段 | OSThread | JavaThreadState | threadStatus |
|------|----------|-----------------|-------------|
| pthread_create 后 | ALLOCATED | _thread_new | NEW |
| 子线程初始化完成 | INITIALIZED | _thread_new | NEW |
| Thread::start() | RUNNABLE | _thread_new | **RUNNABLE** |
| JavaThread::run() | RUNNABLE | **_thread_in_vm** | RUNNABLE |
| JavaCallWrapper | RUNNABLE | **_thread_in_Java** | RUNNABLE |
| 执行 Thread.run() | RUNNABLE | _thread_in_Java | RUNNABLE |
| 退出中 | RUNNABLE | _thread_in_vm | RUNNABLE |
| ensure_join() | RUNNABLE | _thread_in_vm | **TERMINATED** |
| Threads::remove() 后 | ZOMBIE | N/A | TERMINATED |

---

## 第十章：线程退出与清理

### 10.1 JavaThread::exit() 四阶段

**文件**: `src/hotspot/share/runtime/thread.cpp`，第 2009~2214 行

线程退出是一个复杂的过程，分为四个阶段：

**Phase 1: Java 层清理**
```
├─ 分发未捕获异常
│   └─ JavaCalls::call_virtual(dispatchUncaughtException)
│      └─ 调用 Thread.getUncaughtExceptionHandler().uncaughtException()
├─ 调用 Java 层 Thread.exit()（最多重试 3 次，防止 Thread.stop 干扰）
│   └─ 从 ThreadGroup 中移除自己
├─ JVMTI post_thread_end 通知
└─ 检查外部 suspend 请求，设置 _thread_exiting
```

**Phase 2: 设置 TERMINATED 状态并唤醒 join 等待者**
```
├─ ensure_join(this)
│   ├─ ObjectLocker lock(threadObj)     // synchronized(Thread对象)
│   ├─ set_thread_status(TERMINATED)    // threadStatus = TERMINATED
│   ├─ set_thread(threadObj, NULL)      // eetop = NULL → isAlive() = false
│   └─ lock.notify_all()               // 唤醒 join() 等待者
```

**Phase 3: 资源释放**
```
├─ 释放 ObjectMonitor（如果 JNI Detach）
├─ 释放 JNI 句柄块（active_handles + free_handle_block）
├─ 移除栈保护页
├─ retire TLAB（make_parsable）
├─ JVMTI 清理
└─ BarrierSet::on_thread_detach（通知 GC 屏障）
```

**Phase 4: 从全局列表移除**
```
├─ Threads::remove(this, daemon)
│   ├─ ObjectSynchronizer::omFlush()   // 回收 ObjectMonitor
│   ├─ ThreadsSMRSupport::remove_thread()
│   ├─ 从 _thread_list 链表中摘除
│   ├─ _number_of_non_daemon_threads--
│   │   └─ 若 == 1 → notify_all(Threads_lock)  // 触发 VM shutdown
│   └─ set_terminated_value()          // Safepoint 忽略该线程
```

### 10.2 ensure_join() — join() 的唤醒机制

**文件**: `src/hotspot/share/runtime/thread.cpp`，第 1986~2001 行

```cpp
static void ensure_join(JavaThread* thread) {
  Handle threadObj(thread, thread->threadObj());
  ObjectLocker lock(threadObj, thread);   // ← synchronized(this)
  thread->clear_pending_exception();
  java_lang_Thread::set_thread_status(threadObj(), java_lang_Thread::TERMINATED);
  java_lang_Thread::set_thread(threadObj(), NULL);  // ← eetop = NULL
  lock.notify_all(thread);               // ← 唤醒 join() 等待者
  thread->clear_pending_exception();
}
```

### 10.3 Thread.join() — Java 层实现

**文件**: `src/java.base/share/classes/java/lang/Thread.java`，第 1289~1330 行

```java
public final synchronized void join(long millis) throws InterruptedException {
    long base = System.currentTimeMillis();
    long now = 0;

    if (millis == 0) {
        // 无限等待：循环检查 isAlive()
        while (isAlive()) {
            wait(0);  // ← 在 Thread 对象上 wait
        }
    } else {
        while (isAlive()) {
            long delay = millis - now;
            if (delay <= 0) break;
            wait(delay);
            now = System.currentTimeMillis() - base;
        }
    }
}
```

**join() 和 ensure_join() 的配合**：

1. `join()` 是 `synchronized` 方法 → 锁住 Thread 对象
2. `while (isAlive()) { wait(0); }` → 循环检查 + 等待
3. `isAlive()` = `java_lang_Thread::thread(this) != NULL` = `eetop != NULL`
4. 线程退出时 `ensure_join()` 也用 `ObjectLocker` 锁住同一个 Thread 对象
5. `set_thread(NULL)` 使 `isAlive()` 返回 false
6. `notify_all()` 唤醒所有 `join()` 的等待者
7. `join()` 从 `wait` 返回，再检查 `isAlive()` → false → 退出循环

> **注意**：这就是为什么 JDK 文档建议不要在 Thread 对象上调用 `wait/notify`——JVM 内部已经用它来实现 `join()` 机制。

### 10.4 isAlive() 的底层判断

```
Java Thread.isAlive()          [Thread.java:1051, native]
  → JVM_IsThreadAlive()        [jvm.cpp:3016]
    → java_lang_Thread::is_alive(oop java_thread)  [javaClasses.cpp:1683]
      → thr = java_lang_Thread::thread(java_thread)  // 读取 eetop 字段
      → return (thr != NULL);
```

**极其简单**：只检查 `eetop` 字段是否为 NULL。

---

## 第十一章：Threads::add / remove — 全局线程列表管理

### 11.1 Threads::add()

**文件**: `src/hotspot/share/runtime/thread.cpp`，第 4675~4706 行

```cpp
void Threads::add(JavaThread* p, bool force_daemon) {
  assert(Threads_lock->owned_by_self(), "must have threads lock");

  // 通知 GC 屏障（如 G1 的 DirtyCardQueue 初始化）
  BarrierSet::barrier_set()->on_thread_attach(p);

  // ★ 头插法加入全局链表
  p->set_next(_thread_list);
  _thread_list = p;

  // 标记已加入列表（此后必须通过 smr_delete 删除）
  p->set_on_thread_list();

  _number_of_threads++;
  oop threadObj = p->threadObj();
  bool daemon = true;
  if ((!force_daemon) && !is_daemon(threadObj)) {
    _number_of_non_daemon_threads++;
    daemon = false;
  }

  ThreadService::add_thread(p, daemon);
  ThreadsSMRSupport::add_thread(p);  // 加入 SMR 快速列表
}
```

### 11.2 Threads::remove()

**文件**: `src/hotspot/share/runtime/thread.cpp`，第 4708~4759 行

```cpp
void Threads::remove(JavaThread* p, bool is_daemon) {
  // 回收该线程持有的所有 ObjectMonitor
  ObjectSynchronizer::omFlush(p);

  {
    MutexLocker ml(Threads_lock);

    // 从 SMR 快速列表移除
    ThreadsSMRSupport::remove_thread(p);

    // 从 _thread_list 链表中摘除
    JavaThread* current = _thread_list;
    JavaThread* prev = NULL;
    while (current != p) {
      prev = current;
      current = current->next();
    }
    if (prev) {
      prev->set_next(current->next());
    } else {
      _thread_list = p->next();
    }

    _number_of_threads--;
    if (!is_daemon) {
      _number_of_non_daemon_threads--;
      // ★ 当非守护线程只剩 1 个时，唤醒 destroy_vm
      if (number_of_non_daemon_threads() == 1) {
        Threads_lock->notify_all();
      }
    }

    ThreadService::remove_thread(p, is_daemon);
    p->set_terminated_value();  // Safepoint 忽略该线程
  }
}
```

**`_number_of_non_daemon_threads == 1` 的意义**：JVM 正常退出条件是"所有非守护线程都结束了"。当只剩最后一个非守护线程（主线程）时，`notify_all()` 唤醒 `Threads::destroy_vm()` 中的等待，触发 JVM shutdown 流程。

### 11.3 ThreadsSMR — 安全内存回收

JVM 使用 **Hazard Pointer** 机制实现安全的线程列表遍历，称为 **SMR (Safe Memory Reclamation)**。

核心类（`src/hotspot/share/runtime/threadSMR.hpp`）：

| 类 | 作用 |
|----|------|
| `ThreadsSMRSupport` | 全局静态工具类，持有 `_java_thread_list` |
| `ThreadsList` | 不可变的线程数组快照（copy-on-write） |
| `ThreadsListHandle` | 栈上 RAII 包装，获取/释放安全引用 |
| `SafeThreadsListPtr` | Hazard Pointer 机制实现 |

**核心思想**：

```
遍历者：
  ThreadsListHandle handle(this);
  ThreadsList* list = handle.list();
  for (int i = 0; i < list->length(); i++) {
    JavaThread* t = list->thread_at(i);
    // 安全遍历，即使有线程在退出
  }
  // 析构 ThreadsListHandle → 释放 hazard pointer

线程退出时：
  Threads::remove(p)                     // 从链表和 SMR 列表移除
  smr_delete(p)                          // 等待所有 hazard pointer 释放
    → while (is_a_protected_JavaThread(p)) {
        wait();                          // 有人还在引用，等待
      }
    → delete p;                          // 安全删除
```

---

## 第十二章：TLS — 当前线程获取机制

### 12.1 Thread::current() 的实现

**文件**: `src/hotspot/share/runtime/thread.hpp`，第 120~123, 767~783 行

```cpp
// 声明：编译器级别的 thread_local 变量
static THREAD_LOCAL_DECL Thread* _thr_current;

// 实现
inline Thread* Thread::current() {
  Thread* current = current_or_null();
  assert(current != NULL, "Thread::current() called on detached thread");
  return current;
}

inline Thread* Thread::current_or_null() {
#ifndef USE_LIBRARY_BASED_TLS_ONLY
  return _thr_current;                    // 快速路径：直接读 __thread 变量
#else
  return ThreadLocalStorage::thread();    // 后备路径：pthread_getspecific
#endif
}
```

### 12.2 TLS 初始化

**文件**: `src/hotspot/share/runtime/thread.cpp`，第 346~362 行

```cpp
void Thread::initialize_thread_current() {
  _thr_current = this;                    // 设置编译器 TLS
  ThreadLocalStorage::set_thread(this);   // 设置 pthread_key TLS
}

void Thread::clear_thread_current() {
  _thr_current = NULL;
  ThreadLocalStorage::set_thread(NULL);
}
```

**双重 TLS 机制**：
1. **快速路径**：编译器内建 `__thread`（GCC）或 `thread_local`（C++11），直接通过 `%fs` 段寄存器访问，开销约 1 条指令
2. **后备路径**：`pthread_key_t` + `pthread_getspecific`，需要函数调用，开销更大
3. 两者始终保持一致（有 `assert` 校验）

**在 thread_native_entry 中调用**：`thread->initialize_thread_current()` 在子线程创建后第一时间执行，确保 `Thread::current()` 可用。

---

## 第十三章：线程优先级

### 13.1 Java 优先级到 Linux nice 值的映射

**文件**: `src/hotspot/os/linux/os_linux.cpp`，第 4763~4781 行

```cpp
int os::java_to_os_priority[CriticalPriority + 1] = {
  19,   // 0  不应使用
   4,   // 1  MIN_PRIORITY
   3,   // 2
   2,   // 3
   1,   // 4
   0,   // 5  NORM_PRIORITY
  -1,   // 6
  -2,   // 7
  -3,   // 8
  -4,   // 9  NearMaxPriority
  -5,   // 10 MAX_PRIORITY
  -5    // 11 CriticalPriority
};
```

| Java 优先级 | 语义 | Linux nice 值 |
|-------------|------|---------------|
| 1 | `MIN_PRIORITY` | 4 (最低) |
| 5 | `NORM_PRIORITY` | 0 (默认) |
| 10 | `MAX_PRIORITY` | -5 (较高) |
| 11 | `CriticalPriority` | -5 (GC 线程等) |

### 13.2 os::set_native_priority()

**文件**: `src/hotspot/os/linux/os_linux.cpp`，第 4799~4804 行

```cpp
OSReturn os::set_native_priority(Thread* thread, int newpri) {
  if (!UseThreadPriorities || ThreadPriorityPolicy == 0) return OS_OK;
  int ret = setpriority(PRIO_PROCESS, thread->osthread()->thread_id(), newpri);
  return (ret == 0) ? OS_OK : OS_ERR;
}
```

**关键**：默认 `ThreadPriorityPolicy == 0`，此时 `set_native_priority` **什么都不做**直接返回。这意味着在默认配置下，Java 的 `Thread.setPriority()` 在 Linux 上**没有实际效果**。

要让优先级生效，需要设置 `-XX:ThreadPriorityPolicy=1`，并且进程需要 root 权限或 `CAP_SYS_NICE` 能力。

> **JVM 参数**：`-XX:ThreadPriorityPolicy=1`
> **日志**：启动时如果不是 root 用户会看到警告：
> ```
> -XX:ThreadPriorityPolicy=1 may require system level permission,
> e.g., being the root user.
> ```

---

## 第十四章：~JavaThread() 析构函数

**文件**: `src/hotspot/share/runtime/thread.cpp`，第 1873~1916 行

```cpp
JavaThread::~JavaThread() {
  // ① 归还 Parker（LockSupport.park/unpark 使用）
  Parker::Release(_parker);
  _parker = NULL;

  // ② 释放去优化相关数据
  vframeArray* old_array = vframe_array_last();
  if (old_array != NULL) {
    Deoptimization::UnrollBlock* old_info = old_array->unroll_block();
    old_array->set_unroll_block(NULL);
    delete old_info;
    delete old_array;
  }

  // ③ 清理 JVMTI 延迟局部变量
  GrowableArray<jvmtiDeferredLocalVariableSet*>* deferred = deferred_locals();
  if (deferred != NULL) {
    do {
      jvmtiDeferredLocalVariableSet* dlv = deferred->at(0);
      deferred->remove_at(0);
      delete dlv;
    } while (deferred->length() != 0);
    delete deferred;
  }

  // ④ 销毁 Safepoint 状态
  ThreadSafepointState::destroy(this);
  if (_thread_stat != NULL) delete _thread_stat;

  // ⑤ JVMCI 计数器合并
  // ...
}
```

**注意**：大部分清理工作在 `JavaThread::exit()` 中完成，析构函数只负责释放 C++ 层面的资源。

---

## 第十五章：线程完整生命周期图

```
                              ┌─────────────────────────────────────┐
                              │        线程完整生命周期                │
                              └─────────────────────────────────────┘

  new Thread()                Thread.start()                              run() 完成
       │                           │                                         │
       ▼                           ▼                                         ▼
  ┌─────────┐    start0()    ┌──────────┐    thread_entry    ┌──────────┐   exit()    ┌────────────┐
  │   NEW   │ ──────────→   │ 创建中   │ ──────────────→   │ 运行中   │ ────────→  │ 退出清理   │
  │         │                │          │                    │          │            │            │
  │ Java 对象│               │ JavaThread│                   │Thread.run│            │ ensure_join│
  │ 已创建   │               │ OSThread  │                   │ 执行用户 │            │ set_thread │
  │ eetop=0  │               │ pthread   │                   │   代码   │            │  (NULL)    │
  └─────────┘                └──────────┘                    └──────────┘            └────────────┘
                                                                                          │
       Java 层:  NEW ────────→ RUNNABLE ──────────────────────────────────→ TERMINATED     │
     OS Thread:  N/A ─→ ALLOCATED → INITIALIZED → RUNNABLE ──────────────→ ZOMBIE         │
   JavaThread:   N/A ──→ _thread_new ──→ _thread_in_vm ──→ _thread_in_Java ──→ exit()     │
                                                                                          │
                                                                                          ▼
                                                                                   ┌────────────┐
                                                                                   │Threads::   │
                                                                                   │remove()    │
                                                                                   │smr_delete()│
                                                                                   │~JavaThread │
                                                                                   └────────────┘
```

---

## 第十六章：JVM 参数与日志

### 16.1 相关 JVM 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-Xss<size>` | 1MB (AMD64) | Java 线程栈大小 |
| `-XX:ThreadStackSize=<KB>` | 1024 | 等同 `-Xss`（单位为 KB） |
| `-XX:CompilerThreadStackSize=<KB>` | 4096 | 编译器线程栈大小 |
| `-XX:VMThreadStackSize=<KB>` | 1024 | VM 内部线程栈大小 |
| `-XX:ThreadPriorityPolicy=<0\|1>` | 0 | 0=忽略优先级, 1=使用 setpriority |
| `-XX:+UseThreadPriorities` | true | 是否启用线程优先级 |
| `-XX:+UseCriticalJavaThreadPriority` | false | Java MAX_PRIORITY 使用 CriticalPriority 的 nice 值 |

### 16.2 相关日志

**线程创建/销毁日志**：
```bash
-Xlog:os+thread=info
```

输出示例：
```
[info][os,thread] Thread is alive (tid: 12345, pthread id: 140001234567680).
[info][os,thread] JavaThread exiting (tid: 12345).
[info][os,thread] Thread finished (tid: 12345, pthread id: 140001234567680).
```

**线程栈信息**：
```bash
-Xlog:os+thread=debug
```

输出示例：
```
[debug][os,thread] Thread 12345 stack dimensions: 0x00007f0000100000-0x00007f0000200000 (1024k).
```

**线程创建失败**：
```bash
-Xlog:os+thread=warning
```

输出示例：
```
[warning][os,thread] Failed to start the native thread for java.lang.Thread "my-thread"
```

---

## 第十七章：面试高频问题

### Q1: Thread.start() 底层做了什么？

**答**：六步流程：
1. Java 层检查 `threadStatus == 0`（只允许 NEW 状态启动），加入 ThreadGroup
2. 调用 native `start0()` → `JVM_StartThread`
3. `new JavaThread(&thread_entry, sz)` 创建 C++ JavaThread 对象，内部调用 `pthread_create` 创建 OS 线程
4. `prepare()` 建立 Java Thread ↔ JavaThread 双向关联（通过 `eetop` 字段），加入全局线程列表
5. `Thread::start()` 设置 `threadStatus = RUNNABLE`，通过 `os::start_thread()` 唤醒子线程
6. 子线程执行 `JavaThread::run()` → `thread_entry()` → `JavaCalls::call_virtual("run")` → 执行 Java `Thread.run()`

### Q2: Java 线程和 OS 线程是什么关系？

**答**：OpenJDK 11 使用 **1:1 模型**。每个 `java.lang.Thread` 对应一个 `JavaThread`（C++），对应一个 `OSThread`，对应一个 `pthread`。通过 `eetop` 字段和 `_threadObj` 字段实现双向关联。

```
java.lang.Thread ←──eetop──→ JavaThread ──→ OSThread ──→ pthread_t
                 ←─threadObj─┘
```

### Q3: 为什么 start() 只能调用一次？

**答**：**双重检查**：
1. Java 层：`threadStatus != 0` → `IllegalThreadStateException`。第一次 start 后 `threadStatus` 被设为 `RUNNABLE`
2. JVM 层：`java_lang_Thread::thread(jthread) != NULL` → `IllegalThreadStateException`。第一次 start 后 `eetop` 指向 JavaThread*

即使线程已经结束（`threadStatus = TERMINATED`），也不能再次 start——`threadStatus != 0` 检查就会失败。

### Q4: 父子线程之间如何同步？

**答**：通过 `OSThread::startThread_lock()` 这个 Monitor 进行 **两阶段握手**：

1. **第一阶段**（子→父）：子线程完成 TLS/信号掩码等初始化后，将 OSThread 状态设为 `INITIALIZED` 并 `notify_all()`，父线程从 `wait(ALLOCATED)` 中醒来
2. **第二阶段**（父→子）：父线程完成 `prepare()`（双向关联+全局注册）和 `Thread::start()`（设置 RUNNABLE）后，通过 `pd_start_thread()` `notify()` 子线程，子线程从 `wait(INITIALIZED)` 中醒来开始执行

### Q5: Thread.join() 是如何实现的？

**答**：`join()` 是 `synchronized` 方法（锁住 Thread 对象本身），内部 `while (isAlive()) { wait(0); }`。

线程退出时，`ensure_join()` 用 `ObjectLocker` 锁住同一个 Thread 对象，然后：
1. `set_thread_status(TERMINATED)`
2. `set_thread(NULL)` → `eetop = NULL` → `isAlive()` 返回 false
3. `notify_all()` → 唤醒所有 `join()` 的等待者

这就是为什么不应在 Thread 对象上手动调用 `wait/notify`——会干扰 `join()` 机制。

### Q6: Thread.isAlive() 的底层判断是什么？

**答**：`isAlive()` native → `JVM_IsThreadAlive` → `java_lang_Thread::is_alive()` → 检查 `eetop` 字段是否为 NULL。

`eetop` 在 `prepare()` 中设置为 JavaThread*（线程创建时），在 `ensure_join()` 中设置为 NULL（线程退出时）。因此 `isAlive()` 在从 `prepare()` 到 `ensure_join()` 之间返回 true。

### Q7: Java 线程优先级在 Linux 上有效吗？

**答**：**默认无效**。`ThreadPriorityPolicy` 默认值为 0，此时 `os::set_native_priority()` 直接返回不做任何事。

要使优先级生效需要：
1. 设置 `-XX:ThreadPriorityPolicy=1`
2. 进程拥有 root 权限或 `CAP_SYS_NICE` 能力
3. 底层调用 `setpriority(PRIO_PROCESS, tid, nice_value)` 设置 Linux nice 值

Java MIN_PRIORITY(1) → nice 4，NORM_PRIORITY(5) → nice 0，MAX_PRIORITY(10) → nice -5。

### Q8: 线程栈大小是怎么决定的？

**答**：优先级从高到低：
1. `Thread(group, target, name, stackSize)` 构造器中的 `stackSize` 参数
2. `-Xss` 命令行参数（例如 `-Xss512k`）
3. 平台默认值：AMD64 Java 线程 1MB，编译器线程 4MB
4. 不低于 `_java_thread_min_stack_allowed`（栈保护区 + 阴影区的总和）
5. 最终按页大小对齐

---

## 第十八章：源文件索引

| 文件路径 | 关键内容 | 行号 |
|---------|---------|------|
| `src/java.base/share/classes/java/lang/Thread.java` | `start()`, `start0()`, `join()`, `isAlive()` | 780-812, 1289-1330, 1051 |
| `src/java.base/share/native/libjava/Thread.c` | RegisterNatives: start0→JVM_StartThread | 43-71 |
| `src/hotspot/share/prims/jvm.cpp` | `thread_entry`, `JVM_StartThread`, `JVM_IsThreadAlive` | 2867-2970, 3016-3021 |
| `src/hotspot/share/runtime/thread.cpp` | `JavaThread::JavaThread()`, `prepare()`, `run()`, `thread_main_inner()`, `exit()`, `ensure_join()`, `Thread::start()`, `call_run()`, `Threads::add()`, `Threads::remove()`, TLS | 1849-1871, 3357-3399, 1921-1983, 2009-2214, 1986-2001, 563-579, 426-449, 4675-4759, 346-362 |
| `src/hotspot/share/runtime/thread.hpp` | `_thr_current` TLS, `Thread::current()`, `_entry_point` | 120-123, 767-783, 959, 1219 |
| `src/hotspot/os/linux/os_linux.cpp` | `thread_native_entry`, `os::create_thread`, `pd_start_thread`, `set_native_priority`, `java_to_os_priority` | 863-933, 935-1049, 1144-1150, 4763-4804 |
| `src/hotspot/share/runtime/os.cpp` | `os::start_thread` | 892-898 |
| `src/hotspot/os/posix/os_posix.cpp` | `get_initial_stack_size`, `set_minimum_stack_sizes` | 1558-1608, 1500-1554 |
| `src/hotspot/os_cpu/linux_x86/os_linux_x86.cpp` | `default_stack_size` | 719-727 |
| `src/hotspot/share/runtime/osThread.hpp` | `ThreadState` 枚举, `OSThread` 类 | 44-109 |
| `src/hotspot/share/utilities/globalDefinitions.hpp` | `JavaThreadState` 枚举 | 890-903 |
| `src/hotspot/share/classfile/javaClasses.hpp` | `java_lang_Thread::ThreadStatus`, `_eetop_offset` | 347-434 |
| `src/hotspot/share/classfile/javaClasses.cpp` | `set_thread()`, `thread()`, `is_alive()` | 1637-1686 |
| `src/hotspot/share/runtime/javaCalls.cpp` | `call_virtual`, `call_helper`, `JavaCallWrapper` | 190-224, 348-473, 56-104 |
| `src/hotspot/share/runtime/interfaceSupport.inline.hpp` | `ThreadStateTransition` | 103-183 |
| `src/hotspot/share/runtime/threadSMR.hpp` | `ThreadsSMRSupport`, `ThreadsList`, `ThreadsListHandle` | 88-298 |
| `src/hotspot/share/runtime/threadSMR.cpp` | `smr_delete`, `add_thread`, `remove_thread` | 743-1019 |

---

*最后更新: 2026-02-08*
