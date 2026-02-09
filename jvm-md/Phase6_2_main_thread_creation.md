# Phase 6.2: 主线程创建阶段 ⭐⭐⭐⭐⭐

> **源码位置**: `src/hotspot/share/runtime/thread.cpp`
> **核心函数**: `create_initial_thread_group()` + `create_initial_thread()`
> **重要程度**: ⭐⭐⭐⭐⭐ (面试必问！)

---

## 📊 整体流程图

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                          Phase 6.2: 主线程创建完整流程                                        │
├─────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                               │
│  ┌─────────────────────────────────────────────────────────────────────────────────────┐    │
│  │ Step 1: 初始化核心类                                                                  │    │
│  │ ├── initialize_class(java_lang_System)                                                │    │
│  │ ├── initialize_class(java_lang_Class)                                                 │    │
│  │ └── initialize_class(java_lang_ThreadGroup)  ← Thread 依赖 ThreadGroup               │    │
│  └─────────────────────────────────────────────────────────────────────────────────────┘    │
│                                          ↓                                                   │
│  ┌─────────────────────────────────────────────────────────────────────────────────────┐    │
│  │ Step 2: create_initial_thread_group() - 创建线程组层次结构                            │    │
│  │                                                                                       │    │
│  │  ┌─────────────────────────────────┐                                                  │    │
│  │  │ 1. 创建 system 线程组            │  ← 调用 ThreadGroup() 无参构造                   │    │
│  │  │    parent = null                │                                                  │    │
│  │  │    name = "system"              │                                                  │    │
│  │  └─────────────────────────────────┘                                                  │    │
│  │                   ↓                                                                   │    │
│  │  ┌─────────────────────────────────┐                                                  │    │
│  │  │ 2. 创建 main 线程组              │  ← 调用 ThreadGroup(parent, name) 构造          │    │
│  │  │    parent = system              │                                                  │    │
│  │  │    name = "main"                │                                                  │    │
│  │  └─────────────────────────────────┘                                                  │    │
│  │                   ↓                                                                   │    │
│  │  Universe::set_main_thread_group(main_group)  ← 缓存到 Universe                      │    │
│  └─────────────────────────────────────────────────────────────────────────────────────┘    │
│                                          ↓                                                   │
│  ┌─────────────────────────────────────────────────────────────────────────────────────┐    │
│  │ Step 3: initialize_class(java_lang_Thread) - Thread 类静态初始化                      │    │
│  └─────────────────────────────────────────────────────────────────────────────────────┘    │
│                                          ↓                                                   │
│  ┌─────────────────────────────────────────────────────────────────────────────────────┐    │
│  │ Step 4: create_initial_thread() - 创建 main 线程对象 ★★★★★                         │    │
│  │                                                                                       │    │
│  │  ┌─────────────────────────────────┐                                                  │    │
│  │  │ 1. allocate_instance_handle()   │  ← 分配 Thread 对象内存                          │    │
│  │  │    (不调用构造函数)              │                                                  │    │
│  │  └─────────────────────────────────┘                                                  │    │
│  │                   ↓                                                                   │    │
│  │  ┌─────────────────────────────────────────────────────────────────────────────────┐ │    │
│  │  │ 2. 【关键】先建立双向绑定关系（在调用构造函数之前！）                              │ │    │
│  │  │    ┌─────────────────────────────────────────────────────────────────────────┐  │ │    │
│  │  │    │  java_lang_Thread::set_thread(thread_oop, main_thread)                  │  │ │    │
│  │  │    │  ↓                                                                       │  │ │    │
│  │  │    │  thread_oop.eetop = (long) main_thread   // Java → JVM 绑定             │  │ │    │
│  │  │    └─────────────────────────────────────────────────────────────────────────┘  │ │    │
│  │  │    ┌─────────────────────────────────────────────────────────────────────────┐  │ │    │
│  │  │    │  main_thread->set_threadObj(thread_oop)                                 │  │ │    │
│  │  │    │  ↓                                                                       │  │ │    │
│  │  │    │  main_thread._threadObj = thread_oop     // JVM → Java 绑定             │  │ │    │
│  │  │    └─────────────────────────────────────────────────────────────────────────┘  │ │    │
│  │  └─────────────────────────────────────────────────────────────────────────────────┘ │    │
│  │                   ↓                                                                   │    │
│  │  ┌─────────────────────────────────┐                                                  │    │
│  │  │ 3. 调用 Thread(group, "main")   │  ← 这时 Thread.currentThread() 才能正常工作！   │    │
│  │  │    构造函数                      │                                                  │    │
│  │  └─────────────────────────────────┘                                                  │    │
│  └─────────────────────────────────────────────────────────────────────────────────────┘    │
│                                          ↓                                                   │
│  ┌─────────────────────────────────────────────────────────────────────────────────────┐    │
│  │ Step 5: 设置线程状态为 RUNNABLE                                                       │    │
│  │ java_lang_Thread::set_thread_status(thread_object, RUNNABLE)                         │    │
│  └─────────────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                               │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 📋 源码详细分析

### 1️⃣ `create_initial_thread_group()` - 创建线程组

```cpp
// 源码位置: src/hotspot/share/runtime/thread.cpp:1171
static Handle create_initial_thread_group(TRAPS) {
    // ═══════════════════════════════════════════════════════════════════════
    // Step 1: 创建 system 线程组 (顶级线程组)
    // ═══════════════════════════════════════════════════════════════════════
    // 调用 ThreadGroup() 无参构造函数
    // Java 代码: private ThreadGroup() { this.name = "system"; this.parent = null; }
    Handle system_instance = JavaCalls::construct_new_instance(
            SystemDictionary::ThreadGroup_klass(),  // ThreadGroup.class
            vmSymbols::void_method_signature(),     // ()V - 无参构造
            CHECK_NH);
    
    // 缓存到 Universe，后续可通过 Universe::system_thread_group() 获取
    Universe::set_system_thread_group(system_instance());

    // ═══════════════════════════════════════════════════════════════════════
    // Step 2: 创建 main 线程组 (parent = system)
    // ═══════════════════════════════════════════════════════════════════════
    // 创建字符串 "main"
    Handle string = java_lang_String::create_from_str("main", CHECK_NH);
    
    // 调用 ThreadGroup(ThreadGroup parent, String name) 构造函数
    // Java 代码: public ThreadGroup(ThreadGroup parent, String name) { ... }
    Handle main_instance = JavaCalls::construct_new_instance(
            SystemDictionary::ThreadGroup_klass(),
            vmSymbols::threadgroup_string_void_signature(),  // (Ljava/lang/ThreadGroup;Ljava/lang/String;)V
            system_instance,  // parent = system 线程组
            string,           // name = "main"
            CHECK_NH);
    
    return main_instance;  // 返回 main 线程组
}
```

**线程组层次结构图**：
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          JVM 线程组层次结构                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                        system ThreadGroup                              │  │
│  │  ├── parent = null (顶级线程组)                                        │  │
│  │  ├── name = "system"                                                   │  │
│  │  ├── maxPriority = Thread.MAX_PRIORITY                                 │  │
│  │  └── 由 JVM 通过无参构造函数创建                                        │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                    │                                         │
│                                    │ parent                                  │
│                                    ↓                                         │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                         main ThreadGroup                               │  │
│  │  ├── parent = system                                                   │  │
│  │  ├── name = "main"                                                     │  │
│  │  ├── 包含主线程 "main"                                                  │  │
│  │  └── 用户创建的线程默认加入此组                                         │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                    │                                         │
│                                    │ parent                                  │
│                                    ↓                                         │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                      用户自定义 ThreadGroup                            │  │
│  │  ├── 通过 new ThreadGroup("name") 创建                                 │  │
│  │  └── 默认 parent = 当前线程的线程组 (通常是 main)                       │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### 2️⃣ `create_initial_thread()` - 创建主线程对象 ⭐⭐⭐⭐⭐

这是**最核心**的函数，面试必问！

```cpp
// 源码位置: src/hotspot/share/runtime/thread.cpp:1189
static oop create_initial_thread(Handle thread_group, JavaThread *thread, TRAPS) {
    // 获取 java.lang.Thread 类
    InstanceKlass *ik = SystemDictionary::Thread_klass();
    assert(ik->is_initialized(), "must be");  // Thread 类必须已初始化
    
    // ═══════════════════════════════════════════════════════════════════════
    // Step 1: 分配 Thread 对象内存（但不调用构造函数！）
    // ═══════════════════════════════════════════════════════════════════════
    instanceHandle thread_oop = ik->allocate_instance_handle(CHECK_NULL);

    // ═══════════════════════════════════════════════════════════════════════
    // Step 2: 【关键】先建立双向绑定关系
    // ═══════════════════════════════════════════════════════════════════════
    // 
    // ┌────────────────────────────────────────────────────────────────────┐
    // │  为什么不能用 JavaCalls::construct_new_instance() ?               │
    // │                                                                    │
    // │  因为 Thread 构造函数内部会调用 Thread.currentThread()            │
    // │  而 currentThread() 的实现是：                                     │
    // │                                                                    │
    // │    JVM_CurrentThread() {                                          │
    // │        oop jthread = thread->threadObj();  // 获取 _threadObj    │
    // │        return jthread;                                            │
    // │    }                                                              │
    // │                                                                    │
    // │  如果不先设置 _threadObj，currentThread() 会返回 null！           │
    // └────────────────────────────────────────────────────────────────────┘
    
    // 2.1 设置 Java 层的 eetop 字段，指向 JavaThread
    // 这使得从 Java Thread 对象可以找到 JVM JavaThread
    java_lang_Thread::set_thread(thread_oop(), thread);
    
    // 2.2 设置优先级为默认值
    java_lang_Thread::set_priority(thread_oop(), NormPriority);  // 5
    
    // 2.3 设置 JVM 层的 _threadObj 字段，指向 Java Thread 对象
    // 这使得从 JavaThread 可以找到 Java Thread 对象
    thread->set_threadObj(thread_oop());

    // ═══════════════════════════════════════════════════════════════════════
    // Step 3: 调用 Thread(ThreadGroup, String) 构造函数
    // ═══════════════════════════════════════════════════════════════════════
    // 创建线程名 "main"
    Handle string = java_lang_String::create_from_str("main", CHECK_NULL);

    // 调用 Thread.<init>(ThreadGroup, String) 构造函数
    // 因为双向绑定已建立，构造函数中的 currentThread() 可以正常工作
    JavaValue result(T_VOID);
    JavaCalls::call_special(&result, thread_oop,
                            ik,
                            vmSymbols::object_initializer_name(),            // "<init>"
                            vmSymbols::threadgroup_string_void_signature(),  // (ThreadGroup, String)V
                            thread_group,  // main 线程组
                            string,        // "main"
                            CHECK_NULL);
    
    return thread_oop();
}
```

---

### 3️⃣ 双向绑定关系详解 ⭐⭐⭐⭐⭐

这是理解 Java 线程模型的**核心**！

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                            Java 线程与 JVM 线程的双向绑定                                    │
├─────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                               │
│                        Java 层                        JVM C++ 层                             │
│                  ─────────────────────        ─────────────────────────                      │
│                                                                                               │
│  ┌─────────────────────────────────┐        ┌─────────────────────────────────────────────┐ │
│  │   java.lang.Thread 对象         │        │              JavaThread 对象                 │ │
│  │                                 │        │                                              │ │
│  │  ┌───────────────────────────┐  │        │  ┌──────────────────────────────────────┐   │ │
│  │  │ private long eetop;       │──┼───────►│  │  oop _threadObj;                     │   │ │
│  │  │ (存储 JavaThread* 指针)   │  │        │  │  (存储 java.lang.Thread oop)         │◄──┼─┘ │
│  │  └───────────────────────────┘  │        │  └──────────────────────────────────────┘   │ │
│  │                                 │        │                                              │ │
│  │  name: "main"                   │        │  OSThread* _osthread ──────────────────────►│ │
│  │  priority: 5                    │        │                                              │ │
│  │  group: main ThreadGroup        │        │                                              │ │
│  │  daemon: false                  │        │                                              │ │
│  └─────────────────────────────────┘        └─────────────────────────────────────────────┘ │
│                                                              │                               │
│                                                              │ _osthread                     │
│                                                              ↓                               │
│                                              ┌─────────────────────────────────────────────┐ │
│                                              │              OSThread 对象                  │ │
│                                              │                                              │ │
│                                              │  pthread_t _pthread_id;  // Linux 线程 ID   │ │
│                                              │  thread_id_t _thread_id; // OS 线程 ID     │ │
│                                              └─────────────────────────────────────────────┘ │
│                                                                                               │
├─────────────────────────────────────────────────────────────────────────────────────────────┤
│  eetop 字段的秘密：                                                                          │
│  ─────────────────                                                                           │
│  • 字段名来源: "execution engine top" (执行引擎顶层指针)                                     │
│  • 类型: private long (在 64 位系统上正好能存储指针)                                         │
│  • 作用: 存储指向 C++ JavaThread 对象的原始指针                                              │
│  • 初始值: 0 (线程未启动或已终止时)                                                          │
│                                                                                               │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

### 4️⃣ eetop 字段的源码实现

```cpp
// ═══════════════════════════════════════════════════════════════════════════
// 文件: src/hotspot/share/classfile/javaClasses.cpp
// ═══════════════════════════════════════════════════════════════════════════

// _eetop_offset 是 Thread 类中 eetop 字段的偏移量
int java_lang_Thread::_eetop_offset = 0;

// 字段映射宏 (在类初始化时计算偏移量)
#define THREAD_FIELDS_DO(macro) \
  macro(_eetop_offset,         k, "eetop", long_signature, false); \
  // ... 其他字段

// 从 Java Thread 对象获取 JavaThread 指针
JavaThread* java_lang_Thread::thread(oop java_thread) {
    // 从 java_thread 对象的 eetop 字段位置读取地址
    return (JavaThread*)java_thread->address_field(_eetop_offset);
}

// 设置 Java Thread 对象的 eetop 字段
void java_lang_Thread::set_thread(oop java_thread, JavaThread* thread) {
    // 将 JavaThread 指针写入 java_thread 对象的 eetop 字段位置
    java_thread->address_field_put(_eetop_offset, (address)thread);
}
```

---

### 5️⃣ `Thread.currentThread()` 的本质

```cpp
// ═══════════════════════════════════════════════════════════════════════════
// 文件: src/hotspot/share/prims/jvm.cpp:3168
// ═══════════════════════════════════════════════════════════════════════════

// Thread.currentThread() 的 native 实现
JVM_ENTRY(jobject, JVM_CurrentThread(JNIEnv * env, jclass threadClass))
    JVMWrapper("JVM_CurrentThread");
    
    // thread 是当前执行的 JavaThread* (通过 TLS 获取)
    // threadObj() 返回 _threadObj 字段，即 java.lang.Thread 对象
    oop jthread = thread->threadObj();
    
    assert (thread != NULL, "no current thread!");
    
    // 包装成 JNI handle 返回
    return JNIHandles::make_local(env, jthread);
JVM_END
```

**执行流程**：
```
┌──────────────────────────────────────────────────────────────────────────────┐
│                    Thread.currentThread() 执行流程                            │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                               │
│  Java 代码                    JNI                         JVM C++            │
│  ──────────                ─────────                   ─────────────          │
│                                                                               │
│  Thread.currentThread()                                                       │
│         │                                                                     │
│         │ native 调用                                                         │
│         ↓                                                                     │
│  ┌──────────────────┐                                                        │
│  │ JVM_CurrentThread │                                                        │
│  └────────┬─────────┘                                                        │
│           │                                                                   │
│           │ 1. 通过 TLS 获取当前 JavaThread*                                  │
│           │    (ThreadLocalStorage::get_thread())                            │
│           ↓                                                                   │
│  ┌──────────────────────────────────┐                                        │
│  │ thread->threadObj()              │  ← 读取 _threadObj 字段                 │
│  │ 返回 java.lang.Thread oop        │                                        │
│  └──────────────────────────────────┘                                        │
│           │                                                                   │
│           │ 2. 包装成 JNI handle                                              │
│           ↓                                                                   │
│  返回给 Java 层                                                               │
│                                                                               │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

### 6️⃣ 为什么必须先绑定再调用构造函数？

```java
// ═══════════════════════════════════════════════════════════════════════════
// 文件: java.lang.Thread (Java 源码)
// ═══════════════════════════════════════════════════════════════════════════

public class Thread implements Runnable {
    
    public Thread(ThreadGroup group, String name) {
        // 【关键】构造函数第一步就调用 currentThread()！
        Thread parent = currentThread();  // ← 如果 _threadObj 未设置，返回 null！
        
        // 如果 parent 为 null，后续代码会崩溃
        SecurityManager security = System.getSecurityManager();
        if (security != null) {
            security.checkPermission(parent.getContextClassLoader(), ...);  // NPE!
        }
        
        // 从 parent 继承各种属性
        if (group == null) {
            group = parent.getThreadGroup();  // NPE!
        }
        
        // ... 其他初始化
    }
}
```

**核心结论**：
```
┌─────────────────────────────────────────────────────────────────────────────┐
│  JVM 必须在调用 Thread 构造函数之前建立双向绑定！                            │
│                                                                              │
│  正确顺序:                                                                   │
│  1. allocate_instance_handle()   → 分配内存                                  │
│  2. set_thread(thread_oop, jt)   → 设置 eetop                               │
│  3. set_threadObj(thread_oop)    → 设置 _threadObj                          │
│  4. call_special(<init>)         → 调用构造函数 (此时 currentThread() 可用) │
│                                                                              │
│  错误顺序 (使用 construct_new_instance):                                     │
│  1. allocate + <init>            → 构造函数中 currentThread() 返回 null!    │
│  2. 程序崩溃!                                                                │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 🎯 面试高频问题

### Q1: Java 线程与 JVM 线程是什么关系？

**答案**：
```
一对一映射关系，通过双向指针绑定：

1. Java 层 → JVM 层：
   • java.lang.Thread 对象的 eetop 字段存储 JavaThread* 指针
   • 通过 java_lang_Thread::thread(oop) 获取

2. JVM 层 → Java 层：
   • JavaThread 对象的 _threadObj 字段存储 Thread oop
   • 通过 JavaThread::threadObj() 获取

3. JVM 层 → OS 层：
   • JavaThread 对象的 _osthread 字段存储 OSThread*
   • OSThread 封装了 pthread_t (Linux) 或 HANDLE (Windows)
```

### Q2: Thread.currentThread() 是如何实现的？

**答案**：
```
1. Thread.currentThread() 是 native 方法，对应 JVM_CurrentThread()

2. 实现原理：
   • 通过 TLS (Thread Local Storage) 获取当前 JavaThread*
   • 从 JavaThread 的 _threadObj 字段获取 java.lang.Thread 对象
   • 返回该对象

3. 关键点：
   • TLS 存储的是 C++ JavaThread 指针，不是 Java 对象
   • 线程创建时必须先设置 _threadObj，否则 currentThread() 返回 null
```

### Q3: eetop 字段是什么？为什么是 long 类型？

**答案**：
```
1. eetop = "execution engine top"，执行引擎顶层指针

2. 它存储的是 C++ JavaThread 对象的内存地址

3. 为什么是 long？
   • 在 64 位系统上，指针是 8 字节
   • Java 的 long 类型正好是 8 字节，可以完整存储指针
   • 这是一种跨语言传递指针的常用技巧

4. 使用场景：
   • Thread.isAlive() 检查 eetop != 0
   • Thread.getState() 通过 eetop 获取 JavaThread 查询状态
```

### Q4: main 线程组的父线程组是什么？

**答案**：
```
main 线程组的父是 system 线程组。

线程组层次结构：
┌──────────────────────────┐
│ system ThreadGroup       │  ← 顶级，parent = null
│   └── main ThreadGroup   │  ← parent = system
│         └── 用户线程组   │  ← 默认 parent = main
└──────────────────────────┘

system 线程组：
• 由 JVM 通过 ThreadGroup() 私有无参构造函数创建
• 是所有线程组的祖先
• 用户代码无法创建 parent = null 的线程组
```

### Q5: 为什么 main 线程的创建不能使用 `construct_new_instance()`？

**答案**：
```
因为 Thread 构造函数会调用 Thread.currentThread()！

如果使用 construct_new_instance()：
1. 先分配内存
2. 立即调用 <init> 构造函数
3. 构造函数中 currentThread() 返回 null (因为 _threadObj 还没设置)
4. 后续代码 NPE 崩溃

正确做法：
1. 先分配内存 (allocate_instance_handle)
2. 设置 eetop 字段 (set_thread)
3. 设置 _threadObj 字段 (set_threadObj)
4. 再调用构造函数 (call_special)
```

---

## 📈 调试技巧

### GDB 查看线程绑定关系

```bash
# 1. 获取当前 JavaThread
(gdb) p Thread::current()
$1 = (JavaThread *) 0x7f8a12345678

# 2. 查看 JavaThread 的 _threadObj
(gdb) p ((JavaThread*)0x7f8a12345678)->_threadObj
$2 = (oop) 0x7f8a00001234

# 3. 查看 Thread 对象的 eetop 字段
(gdb) p *(long*)((char*)0x7f8a00001234 + 104)  # 104 是 eetop 偏移量(可能不同)
$3 = 0x7f8a12345678  # 应该等于 JavaThread 地址

# 4. 查看线程名
(gdb) call java_lang_Thread::name((oop)0x7f8a00001234)
```

---

## ✅ 本节小结

| 知识点 | 重要程度 | 面试频率 | 关键理解 |
|-------|---------|---------|---------|
| 双向绑定机制 | ⭐⭐⭐⭐⭐ | 极高 | eetop ↔ _threadObj |
| 线程组层次 | ⭐⭐⭐ | 中 | system → main → 用户组 |
| currentThread() 实现 | ⭐⭐⭐⭐ | 高 | TLS + _threadObj |
| 创建顺序的重要性 | ⭐⭐⭐⭐⭐ | 高 | 先绑定再构造 |
| eetop 字段含义 | ⭐⭐⭐⭐ | 高 | long 存指针 |

---

**下一步建议**: 继续学习 **6.4 System.initPhase1()** 或 **6.5 异常类预初始化**？ 🚀
