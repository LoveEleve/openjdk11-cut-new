# Lesson 6: LockTracer 深度逐行解析（方法内联展开）

> 本文档对 LockTracer 的每一行代码进行深度解析，所有被调用的方法都展开到最底层实现。

---

## 1. LockTracer 核心概念

### 1.1 LockTracer 监控什么？

**两种锁争用**：

| 类型 | Java 机制 | 触发事件 | 检测方式 |
|-----|----------|---------|---------|
| **synchronized** | 内置监视器锁 | `MonitorContendedEnter`/`Entered` | JVMTI 事件 |
| **ReentrantLock** | `java.util.concurrent.locks` | `Unsafe.park()` 阻塞 | JNI Hook |

### 1.2 整体架构

```
Java 代码执行: synchronized(obj) { ... }
          │
          v
    线程尝试获取监视器锁
          │
    ┌─────┴─────┐
    │ 锁是否空闲？ │
    └─────┬─────┘
          │
    ┌─────┴─────┐
    │   否      │──→ JVM 触发 MonitorContendedEnter 事件
    │           │    AsyncProfiler 记录进入时间
    │   等待...  │
    │           │
    │   获得锁   │──→ JVM 触发 MonitorContendedEntered 事件
    │           │    AsyncProfiler 计算等待时间
    │   执行代码  │
    │   释放锁   │
    └───────────┘
```

---

## 2. 源码逐行解析（深度优先展开）

### 2.1 静态成员初始化

```cpp
// 文件: lockTracer.cpp 第 14-36 行

#define CAN_USE_TLS (sizeof(void*) >= sizeof(u64))
```

**解析**：判断是否可以使用 pthread 线程本地存储（TLS）。

**展开**：
- `sizeof(void*)`：指针大小（64 位平台 = 8 字节）
- `sizeof(u64)`：64 位无符号整数大小 = 8 字节
- 在 64 位平台上，`CAN_USE_TLS = true`
- 在 32 位平台上，`CAN_USE_TLS = false`（指针 4 字节，放不下 u64）

**为什么需要这个判断？**
- pthread 线程本地存储的值是 `void*` 类型
- 需要存储 64 位时间戳 `u64`
- 32 位平台上无法直接存储，需要用 JVMTI 的 Tag 机制

---

```cpp
static pthread_key_t lock_tracer_tls = (pthread_key_t)0;
```

**解析**：线程本地存储的键。

**pthread_key_t 展开**：

```c
// /usr/include/pthread.h
typedef unsigned int pthread_key_t;  // Linux 上是 unsigned int
```

**pthread 线程本地存储原理**：

```
每个线程有独立的 TLS 空间：
┌─────────────────────────────────────────┐
│ Thread 1                                │
│  ┌─────────────────────────────────────┐│
│  │ TLS[key1] = value1                  ││
│  │ TLS[key2] = value2                  ││
│  │ ...                                 ││
│  └─────────────────────────────────────┘│
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│ Thread 2                                │
│  ┌─────────────────────────────────────┐│
│  │ TLS[key1] = value3                  ││
│  │ TLS[key2] = value4                  ││
│  │ ...                                 ││
│  └─────────────────────────────────────┘│
└─────────────────────────────────────────┘

同一个 key，不同线程有不同的值。
```

---

```cpp
INCLUDE_HELPER_CLASS(LOCK_TRACER_NAME, LOCK_TRACER_CLASS, "one/profiler/LockTracer")
```

**展开 INCLUDE_HELPER_CLASS 宏**：

```cpp
// 文件: incbin.h 第 32-34 行
#define INCLUDE_HELPER_CLASS(NAME_VAR, DATA_VAR, NAME) \
    static const char* const NAME_VAR = NAME;\
    INCBIN(DATA_VAR, "src/helper/" NAME ".class")
```

**展开 INCBIN 宏**：

```cpp
// 文件: incbin.h 第 17-28 行
#define INCBIN(NAME, FILE) \
    extern "C" const char NAME[];\
    extern "C" const char NAME##_END[];\
    asm(INCBIN_SECTION "\n"\
        ".globl " INCBIN_SYMBOL #NAME "\n"\
        INCBIN_SYMBOL #NAME ":\n"\
        ".incbin \"" FILE "\"\n"\
        ".globl " INCBIN_SYMBOL #NAME "_END\n"\
        INCBIN_SYMBOL #NAME "_END:\n"\
        ".byte 0x00\n"\
        ".previous\n"\
    );
```

**完全展开后**：

```cpp
// 在编译时嵌入 LockTracer.class 文件到二进制中
static const char* const LOCK_TRACER_NAME = "one/profiler/LockTracer";

extern "C" const char LOCK_TRACER_CLASS[];
extern "C" const char LOCK_TRACER_CLASS_END[];

asm(
    ".section \".rodata\", \"a\"\n"
    ".globl LOCK_TRACER_CLASS\n"
    "LOCK_TRACER_CLASS:\n"
    ".incbin \"src/helper/one/profiler/LockTracer.class\"\n"
    ".globl LOCK_TRACER_CLASS_END\n"
    "LOCK_TRACER_CLASS_END:\n"
    ".byte 0x00\n"
    ".previous\n"
);
```

**原理**：将 Java 字节码文件 `LockTracer.class` 编译进 C++ 二进制文件中，运行时动态加载。

---

```cpp
bool LockTracer::_initialized = false;
double LockTracer::_ticks_to_nanos;
u64 LockTracer::_interval;
volatile u64 LockTracer::_total_duration;  // for interval sampling
u64 LockTracer::_start_time = 0;

jclass LockTracer::_Unsafe = NULL;
jclass LockTracer::_LockTracer = NULL;
jfieldID LockTracer::_parkBlocker = NULL;
jmethodID LockTracer::_setEntry = NULL;

RegisterNativesFunc LockTracer::_orig_register_natives = NULL;
UnsafeParkFunc LockTracer::_orig_unsafe_park = NULL;
```

**解析**：

| 静态成员 | 类型 | 用途 |
|---------|------|------|
| `_initialized` | bool | 是否已初始化 ReentrantLock 追踪 |
| `_ticks_to_nanos` | double | TSC ticks 到纳秒的转换系数 |
| `_interval` | u64 | 采样间隔（ticks） |
| `_total_duration` | volatile u64 | 累计等待时间（CAS 原子更新） |
| `_start_time` | u64 | 采样开始时间 |
| `_Unsafe` | jclass | `jdk.internal.misc.Unsafe` 类引用 |
| `_LockTracer` | jclass | `one.profiler.LockTracer` 类引用 |
| `_parkBlocker` | jfieldID | `Thread.parkBlocker` 字段 ID |
| `_setEntry` | jmethodID | `LockTracer.setEntry` 方法 ID |
| `_orig_register_natives` | RegisterNativesFunc | 原始的 `RegisterNatives` 函数指针 |
| `_orig_unsafe_park` | UnsafeParkFunc | 原始的 `Unsafe.park` 函数指针 |

---

### 2.2 start() 方法

```cpp
// 文件: lockTracer.cpp 第 38-65 行

Error LockTracer::start(Arguments& args) {
    // There is a JVM here, so TSC::frequency is calibrated from it
    _ticks_to_nanos = 1e9 / TSC::frequency();
    _interval = (u64)(args._lock * (TSC::frequency() / 1e9));
    _total_duration = 0;
```

**展开 TSC::frequency()**：

```cpp
// 文件: tsc.h 第 100-102 行
static u64 frequency() {
    return enabled() ? _frequency : NANOTIME_FREQ;
}
```

**展开 TSC::enabled()**：

```cpp
// 文件: tsc.h 第 89-91 行
static bool enabled() {
    return TSC_SUPPORTED && _enabled;
}
```

**展开 TSC_SUPPORTED**：

```cpp
// 文件: tsc.h 第 20 行 (x86_64)
#define TSC_SUPPORTED true
```

**展开 _frequency**：

```cpp
// 文件: tsc.cpp 第 15 行
u64 TSC::_frequency = NANOTIME_FREQ;  // 默认 1e9
```

**在 TSC::enable() 中如何校准频率**：

```cpp
// 文件: tsc.cpp 第 29-41 行
// 使用 JFR 的 JVM.getTicksFrequency() 校准
jclass cls = env->FindClass("jdk/jfr/internal/JVM");
jmethodID getTicksFrequency = env->GetMethodID(cls, "getTicksFrequency", "()J");
u64 frequency = env->CallLongMethod(env->GetStaticObjectField(cls, jvm), getTicksFrequency);
if (frequency > NANOTIME_FREQ) {
    _frequency = frequency;  // 例如：3.2 GHz CPU -> 3200000000
}
```

**_ticks_to_nanos 计算**：

```
假设：
  TSC::frequency() = 3200000000 (3.2 GHz)
  
_ticks_to_nanos = 1e9 / 3200000000 = 0.3125 (纳秒/tick)
```

**_interval 计算**：

```
假设：
  args._lock = 10000000 (10ms，用户参数 --lock 10ms)
  TSC::frequency() = 3200000000

_interval = 10000000 * (3200000000 / 1e9) = 10000000 * 3.2 = 32000000 ticks
          = 10ms 的 ticks 数
```

---

```cpp
    jvmtiEnv* jvmti = VM::jvmti();
    JNIEnv* env = VM::jni();
```

**展开 VM::jvmti()**：

```cpp
// 文件: vmEntry.h 第 110-112 行
static jvmtiEnv* jvmti() {
    return _jvmti;
}
```

**展开 VM::jni()**：

```cpp
// 文件: vmEntry.h 第 114-116 行
static JNIEnv* jni() {
    return _jni;
}
```

---

```cpp
    if (!_initialized) {
        Error error = initialize(jvmti, env);
        if (error) {
            Log::warn("ReentrantLock tracing unavailable: %s", error.message());
            env->ExceptionClear();
        }
        _initialized = true;
    }
```

**展开 Log::warn()**：

```cpp
// 文件: log.h 第 50 行
static void ATTR_FORMAT warn(const char* msg, ...);
```

**展开 Error::message()**：

```cpp
// 文件: arguments.h 第 152-154 行
const char* message() {
    return _message;
}
```

---

```cpp
    // Enable Java Monitor events
    jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_MONITOR_CONTENDED_ENTER, NULL);
    jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_MONITOR_CONTENDED_ENTERED, NULL);
    _start_time = TSC::ticks();
```

**展开 JVMTI_EVENT_MONITOR_CONTENDED_ENTER**：

```c
// /usr/include/jvmti.h
typedef enum {
    // ...
    JVMTI_EVENT_MONITOR_CONTENDED_ENTER = 83,   // 尝试获取锁时触发
    JVMTI_EVENT_MONITOR_CONTENDED_ENTERED = 84, // 成功获取锁后触发
    // ...
} jvmtiEvent;
```

**JVM 内部触发流程**：

```cpp
// hotspot/share/runtime/objectMonitor.cpp
void ObjectMonitor::enter(TRAPS) {
    // 尝试获取锁
    if (try_lock()) {
        return;  // 成功，不触发事件
    }
    
    // 竞争失败，触发 MonitorContendedEnter
    if (event != NULL) {
        event->send();  // JVMTI 事件
    }
    
    // 等待...
    wait();
    
    // 被唤醒，获得锁，触发 MonitorContendedEntered
    if (event != NULL) {
        event->send();  // JVMTI 事件
    }
}
```

**展开 TSC::ticks()**：

```cpp
// 文件: tsc.h 第 93-95 行
static u64 ticks() {
    return enabled() ? rdtsc() - _offset : OS::nanotime();
}
```

**展开 rdtsc()**：

```cpp
// 文件: tsc.h 第 22-32 行 (x86_64)
static inline u64 rdtsc() {
    u32 lo, hi;
    asm volatile("rdtsc" : "=a" (lo), "=d" (hi));
    return ((u64)hi << 32) | lo;
}
```

**汇编展开**：

```asm
; rdtsc 指令执行：
;   - 读取时间戳计数器到 EDX:EAX
;   - EDX = 高 32 位
;   - EAX = 低 32 位

rdtsc                    ; 读取 TSC
mov lo, eax              ; 保存低 32 位
mov hi, edx              ; 保存高 32 位
shl rdx, 32              ; 高 32 位左移
or rax, rdx              ; 合并为 64 位
ret                      ; 返回 RAX
```

---

```cpp
    // Intercept Unsafe.park() for tracing contended ReentrantLocks
    setUnsafeParkEntry(env, UnsafeParkHook);

    return Error::OK;
}
```

**为什么需要 Hook Unsafe.park()？**

```
ReentrantLock.lock() 的实现：
┌─────────────────────────────────────────────────┐
│ ReentrantLock.lock()                             │
│   ├─ tryAcquire() (CAS)                          │
│   │   └─ 成功：返回                               │
│   │   └─ 失败：继续                               │
│   ├─ acquireQueued()                             │
│   │   └─ shouldParkAfterFailedAcquire()         │
│   │       └─ LockSupport.park()                  │
│   │           └─ Unsafe.park()  <-- Hook 点      │
│   │               └─ 线程阻塞等待                 │
│   └─ 被唤醒后重试                                 │
└─────────────────────────────────────────────────┘

Unsafe.park() 是 native 方法，阻塞线程。
Hook 它可以测量等待时间。
```

---

### 2.3 initialize() 方法（核心初始化）

```cpp
// 文件: lockTracer.cpp 第 77-139 行

Error LockTracer::initialize(jvmtiEnv* jvmti, JNIEnv* env) {
    if (CAN_USE_TLS) {
        pthread_key_create(&lock_tracer_tls, NULL);
    }
```

**展开 pthread_key_create**：

```c
// /usr/include/pthread.h
int pthread_key_create(pthread_key_t *key, void (*destructor)(void*));
```

**参数**：
- `key`：输出参数，创建的键
- `destructor`：线程退出时的清理函数（NULL 表示不需要清理）

**内部实现**（glibc）：

```c
// glibc/nptl/pthread_key_create.c
int __pthread_key_create (key, destr)
     pthread_key_t *key;
     void (*destr) (void *);
{
    // 1. 在全局键表中找到一个未使用的槽位
    // 2. 分配键索引
    // 3. 记录析构函数
    // 返回 0 表示成功
}
```

**使用示例**：

```cpp
// 创建键
pthread_key_t key;
pthread_key_create(&key, NULL);

// 线程 A 设置值
pthread_setspecific(key, (void*)12345);

// 线程 B 设置不同的值
pthread_setspecific(key, (void*)67890);

// 线程 A 读取
pthread_getspecific(key);  // 返回 12345

// 线程 B 读取
pthread_getspecific(key);  // 返回 67890
```

---

```cpp
    // Try JDK 9+ package first, then fallback to JDK 8 package
    jclass unsafe = env->FindClass("jdk/internal/misc/Unsafe");
    if (unsafe == NULL) {
        env->ExceptionClear();
        if ((unsafe = env->FindClass("sun/misc/Unsafe")) == NULL) {
            return Error("Unsafe class not found");
        }
    }
    _Unsafe = (jclass)env->NewGlobalRef(unsafe);
```

**JDK 版本差异**：

```
JDK 8:
  sun.misc.Unsafe
  ├─ park()
  ├─ unpark()
  └─ ...

JDK 9+:
  jdk.internal.misc.Unsafe
  ├─ park()
  ├─ unpark()
  └─ ...
```

**为什么先尝试 JDK 9+ 包名？**
- JDK 9 重构了包结构
- 优先使用新包名，兼容旧版本

---

```cpp
    jmethodID register_natives = env->GetStaticMethodID(_Unsafe, "registerNatives", "()V");
    if (register_natives == NULL) {
        return Error("registerNatives method not found");
    }
```

**Unsafe.registerNatives() 的作用**：

```java
// jdk/internal/misc/Unsafe.java
public final class Unsafe {
    private static native void registerNatives();
    
    static {
        registerNatives();  // 注册 native 方法
    }
    
    public native void park(boolean isAbsolute, long time);
    // ...
}
```

**registerNatives() 做了什么**：

```c
// hotspot/share/prims/unsafe.cpp
static void registerNatives() {
    // 将 Java 方法名映射到 C++ 函数指针
    // 例如：
    //   "park" -> Unsafe_Park
    //   "unpark" -> Unsafe_Unpark
}
```

---

```cpp
    jniNativeInterface* jni_functions;
    if (jvmti->GetJNIFunctionTable(&jni_functions) == 0) {
        _orig_register_natives = jni_functions->RegisterNatives;
        jni_functions->RegisterNatives = RegisterNativesHook;
        jvmti->SetJNIFunctionTable(jni_functions);
```

**展开 GetJNIFunctionTable**：

```c
// JVMTI 函数
jvmtiError GetJNIFunctionTable(jvmtiEnv* env, jniNativeInterface** function_table);
```

**jniNativeInterface 结构**：

```c
// /usr/include/jni.h
struct JNINativeInterface_ {
    // ... 大量函数指针
    jint (*RegisterNatives)(JNIEnv*, jclass, const JNINativeMethod*, jint);
    // ...
};

typedef const struct JNINativeInterface_ *jniNativeInterface;
```

**JNI 函数表 Hook 原理**：

```
原始 JNI 函数表：
┌─────────────────────────────────────┐
│ FindClass        -> JVM 函数        │
│ GetMethodID      -> JVM 函数        │
│ RegisterNatives  -> JVM 函数        │ <-- Hook 点
│ ...                                 │
└─────────────────────────────────────┘

Hook 后的 JNI 函数表：
┌─────────────────────────────────────┐
│ FindClass        -> JVM 函数        │
│ GetMethodID      -> JVM 函数        │
│ RegisterNatives  -> RegisterNativesHook │ <-- 替换
│ ...                                 │
└─────────────────────────────────────┘
```

---

```cpp
        // Trace Unsafe.registerNatives() to find the original address of Unsafe.park() native
        env->CallStaticVoidMethod(_Unsafe, register_natives);
```

**关键技巧**：通过 Hook `RegisterNatives`，捕获 `Unsafe.park` 的原始函数地址！

**执行流程**：

```
1. 调用 Unsafe.registerNatives()
2. JVM 内部调用 JNIEnv->RegisterNatives()
3. 因为 Hook 了 RegisterNatives，进入 RegisterNativesHook()
4. 在 Hook 中读取 methods 参数，找到 park() 的函数指针
5. 保存到 _orig_unsafe_park
6. 返回，不实际注册
```

---

```cpp
        jni_functions->RegisterNatives = _orig_register_natives;
        jvmti->SetJNIFunctionTable(jni_functions);
        jvmti->Deallocate((unsigned char*)jni_functions);
    }
    if (env->ExceptionCheck() || _orig_unsafe_park == NULL) {
        return Error("Unsafe_park address not found");
    }
```

**恢复原始 JNI 函数表**，避免影响其他代码。

---

```cpp
    _parkBlocker = env->GetFieldID(env->FindClass("java/lang/Thread"), "parkBlocker", "Ljava/lang/Object;");
    if (_parkBlocker == NULL) {
        return Error("parkBlocker field not found");
    }
```

**Thread.parkBlocker 字段的作用**：

```java
// java/lang/Thread.java
public class Thread {
    // ...
    volatile Object parkBlocker;  // 记录线程在哪个锁上 park
    // ...
}
```

**谁设置 parkBlocker？**

```java
// java/util/concurrent/locks/LockSupport.java
public static void park(Object blocker) {
    Thread t = Thread.currentThread();
    setBlocker(t, blocker);  // 设置 parkBlocker
    U.park(false, 0L);
    setBlocker(t, null);     // 清除 parkBlocker
}
```

---

```cpp
    jclass cls = env->DefineClass(LOCK_TRACER_NAME, NULL, (const jbyte*)LOCK_TRACER_CLASS, INCBIN_SIZEOF(LOCK_TRACER_CLASS));
    if (cls != NULL) {
        const JNINativeMethod method = {(char*)"setEntry0", (char*)"(J)V", (void*)setEntry0};
        if (env->RegisterNatives(cls, &method, 1) != 0) {
            return Error("LockTracer registration failed");
        }
    } else {
        env->ExceptionClear();
        if ((cls = env->FindClass(LOCK_TRACER_NAME)) == NULL) {
            return Error("LockTracer registration failed");
        }
    }
    _LockTracer = (jclass)env->NewGlobalRef(cls);
```

**DefineClass 的作用**：从内存中加载 Java 类。

**为什么要动态加载 LockTracer.java？**

```java
// LockTracer.java 的作用：
// 1. 提供一个受信任的调用上下文
// 2. 绕过 JDK-8238460 的安全检查

class LockTracer {
    // 从 Java 代码调用 JNI RegisterNatives
    // 这样可以绕过某些安全限制
    private static native void setEntry0(long entry);
    
    static void setEntry(long entry) {
        setEntry0(entry);
    }
}
```

---

```cpp
    _setEntry = env->GetStaticMethodID(_LockTracer, "setEntry", "(J)V");
    if (_setEntry == NULL) {
        return Error("setEntry method not found");
    }

    return Error::OK;
}
```

---

### 2.4 RegisterNativesHook()（捕获 Unsafe.park 地址）

```cpp
// 文件: lockTracer.cpp 第 187-198 行

jint JNICALL LockTracer::RegisterNativesHook(JNIEnv* env, jclass cls, const JNINativeMethod* methods, jint nMethods) {
    if (env->IsSameObject(cls, _Unsafe)) {
        for (jint i = 0; i < nMethods; i++) {
            if (strcmp(methods[i].name, "park") == 0 && strcmp(methods[i].signature, "(ZJ)V") == 0) {
                _orig_unsafe_park = (UnsafeParkFunc)methods[i].fnPtr;
                break;
            }
        }
        return 0;  // 返回成功，但不实际注册
    }
    return _orig_register_natives(env, cls, methods, nMethods);  // 其他类正常注册
}
```

**JNINativeMethod 结构**：

```c
// /usr/include/jni.h
typedef struct {
    char* name;      // 方法名，例如 "park"
    char* signature; // 签名，例如 "(ZJ)V"
    void* fnPtr;     // C++ 函数指针
} JNINativeMethod;
```

**Unsafe.park 的注册信息**：

```c
{
    name = "park",
    signature = "(ZJ)V",  // boolean, long -> void
    fnPtr = 0x7fff12345678  // Unsafe_Park 函数地址
}
```

---

### 2.5 MonitorContendedEnter()（开始等待）

```cpp
// 文件: lockTracer.cpp 第 153-160 行

void JNICALL LockTracer::MonitorContendedEnter(jvmtiEnv* jvmti, JNIEnv* env, jthread thread, jobject object) {
    const u64 enter_time = TSC::ticks();
    if (CAN_USE_TLS && lock_tracer_tls) {
        pthread_setspecific(lock_tracer_tls, (void*)enter_time);
    } else {
        jvmti->SetTag(thread, enter_time);
    }
}
```

**参数解析**：
- `jvmti`：JVMTI 环境
- `env`：JNI 环境
- `thread`：当前线程（尝试获取锁的线程）
- `object`：锁对象

**存储进入时间的两种方式**：

| 方式 | 64 位平台 | 32 位平台 |
|-----|----------|----------|
| pthread TLS | 直接存储 u64 | 不可用 |
| JVMTI Tag | 可用但较慢 | 可用 |

**pthread_setspecific 展开**：

```c
// glibc/nptl/pthread_setspecific.c
int __pthread_setspecific (key, value)
     pthread_key_t key;
     const void *value;
{
    // 1. 获取当前线程的 TLS 数组
    // 2. 找到 key 对应的槽位
    // 3. 存储 value
    return 0;
}
```

**jvmti->SetTag 展开**：

```c
// JVMTI 函数
jvmtiError SetTag(jvmtiEnv* env, jobject object, jlong tag);

// JVM 内部实现：
// 每个 Java 对象有一个关联的 tag 字段
// tag = 0 表示无标签
// 可以存储任意 64 位值
```

---

### 2.6 MonitorContendedEntered()（获得锁）

```cpp
// 文件: lockTracer.cpp 第 162-185 行

void JNICALL LockTracer::MonitorContendedEntered(jvmtiEnv* jvmti, JNIEnv* env, jthread thread, jobject object) {
    if (!_enabled) return;  // 采样未启用，直接返回

    const u64 entered_time = TSC::ticks();
    u64 enter_time = 0;
    if (CAN_USE_TLS && lock_tracer_tls) {
        enter_time = (u64)pthread_getspecific(lock_tracer_tls);
    } else {
        jvmti->GetTag(thread, (jlong*)&enter_time);
    }
```

**pthread_getspecific 展开**：

```c
// glibc/nptl/pthread_getspecific.c
void* __pthread_getspecific (key)
     pthread_key_t key;
{
    // 1. 获取当前线程的 TLS 数组
    // 2. 找到 key 对应的槽位
    // 3. 返回存储的值
}
```

---

```cpp
    // Time is meaningless if lock attempt has started before profiling
    if (enter_time < _start_time) {
        return;
    }
```

**解析**：如果进入时间早于采样开始时间，忽略该事件。

**场景**：
- 线程在采样开始前就开始等待锁
- 采样开始时已经等待了很久
- 这段时间不应该计入采样

---

```cpp
    // When the duration accumulator overflows _interval, the event is sampled.
    const u64 duration = entered_time - enter_time;
    if (updateCounter(_total_duration, duration, _interval)) {
        char* lock_name = getLockName(jvmti, env, object);
        recordContendedLock(LOCK_SAMPLE, enter_time, entered_time, lock_name, object, 0);
        jvmti->Deallocate((unsigned char*)lock_name);
    }
}
```

**updateCounter() 已在 Lesson 5 详细解析**。

---

### 2.7 UnsafeParkHook()（Hook ReentrantLock 等待）

```cpp
// 文件: lockTracer.cpp 第 200-228 行

void JNICALL LockTracer::UnsafeParkHook(JNIEnv* env, jobject instance, jboolean isAbsolute, jlong time) {
    while (_enabled) {
        jvmtiEnv* jvmti = VM::jvmti();
        jobject park_blocker = getParkBlocker(jvmti, env);
        if (park_blocker == NULL) {
            break;  // 没有 blocker，不是 ReentrantLock
        }
```

**getParkBlocker() 展开**：

```cpp
// 文件: lockTracer.cpp 第 230-236 行
jobject LockTracer::getParkBlocker(jvmtiEnv* jvmti, JNIEnv* env) {
    jthread thread;
    if (jvmti->GetCurrentThread(&thread) != 0) {
        return NULL;
    }
    return env->GetObjectField(thread, _parkBlocker);
}
```

**parkBlocker 示例**：

```java
// 应用代码
ReentrantLock lock = new ReentrantLock();
lock.lock();  // 线程 A 获得锁

// 线程 B 尝试获取
lock.lock();  // 线程 B 阻塞在 park()
// 此时 Thread.currentThread().parkBlocker = lock 对象
```

---

```cpp
        char* lock_name = getLockName(jvmti, env, park_blocker);
        if (lock_name == NULL || !isConcurrentLock(lock_name)) {
            jvmti->Deallocate((unsigned char*)lock_name);
            break;
        }
```

**isConcurrentLock() 展开**：

```cpp
// 文件: lockTracer.cpp 第 246-250 行
bool LockTracer::isConcurrentLock(const char* lock_name) {
    // Do not count synchronizers other than ReentrantLock, ReentrantReadWriteLock and Semaphore
    return strncmp(lock_name, "Ljava/util/concurrent/locks/Reentrant", 37) == 0 ||
           strncmp(lock_name, "Ljava/util/concurrent/Semaphore", 31) == 0;
}
```

**解析**：只追踪 `java.util.concurrent` 包中的锁，忽略其他类型。

---

```cpp
        u64 park_start_time = TSC::ticks();
        _orig_unsafe_park(env, instance, isAbsolute, time);  // 调用原始 park()
        u64 park_end_time = TSC::ticks();
```

**_orig_unsafe_park 调用**：

```c
// 调用 JVM 的原始 Unsafe.park 实现
// 参数：
//   env: JNI 环境
//   instance: Unsafe 实例（不使用）
//   isAbsolute: 是否绝对时间
//   time: 等待时间（纳秒或截止时间）

// 如果 time = 0 且 isAbsolute = false，表示无限等待
// 线程会阻塞直到被 unpark() 或中断
```

---

```cpp
        const u64 duration = park_end_time - park_start_time;
        if (updateCounter(_total_duration, duration, _interval)) {
            recordContendedLock(PARK_SAMPLE, park_start_time, park_end_time, lock_name, park_blocker, time);
        }

        jvmti->Deallocate((unsigned char*)lock_name);
        return;
    }

    _orig_unsafe_park(env, instance, isAbsolute, time);  // 不是并发锁，正常调用
}
```

---

### 2.8 getLockName()

```cpp
// 文件: lockTracer.cpp 第 238-244 行

char* LockTracer::getLockName(jvmtiEnv* jvmti, JNIEnv* env, jobject lock) {
    char* class_name;
    if (jvmti->GetClassSignature(env->GetObjectClass(lock), &class_name, NULL) != 0) {
        return NULL;
    }
    return class_name;
}
```

**GetClassSignature 展开**：

```c
// JVMTI 函数
jvmtiError GetClassSignature(jvmtiEnv* env, jclass klass, char** signature_ptr, char** generic_ptr);

// 返回示例：
//   对于 java.lang.String -> "Ljava/lang/String;"
//   对于 int[] -> "[I"
//   对于 Object[][] -> "[[Ljava/lang/Object;"
```

**JVM 内部分配内存**：
- `class_name` 是 JVM 分配的内存
- 使用后必须调用 `Deallocate()` 释放

---

### 2.9 recordContendedLock()

```cpp
// 文件: lockTracer.cpp 第 252-271 行

void LockTracer::recordContendedLock(EventType event_type, u64 start_time, u64 end_time,
                                     const char* lock_name, jobject lock, jlong timeout) {
    LockEvent event;
    event._class_id = 0;
    event._start_time = start_time;
    event._end_time = end_time;
    event._address = *(uintptr_t*)lock;
    event._timeout = timeout;
```

**LockEvent 结构**：

```cpp
// 文件: event.h 第 71-77 行
class LockEvent : public EventWithClassId {
  public:
    u64 _start_time;      // 开始等待时间
    u64 _end_time;        // 获得锁时间
    uintptr_t _address;   // 锁对象地址
    long long _timeout;   // 超时时间（仅 park 事件）
};
```

**_address 的用途**：
- 区分同一类的不同锁实例
- 在火焰图中显示锁地址

---

```cpp
    if (lock_name != NULL) {
        if (lock_name[0] == 'L') {
            event._class_id = Profiler::instance()->classMap()->lookup(lock_name + 1, strlen(lock_name) - 2);
        } else {
            event._class_id = Profiler::instance()->classMap()->lookup(lock_name);
        }
    }
```

**类名处理**：
- `Ljava/lang/Object;` -> `java/lang/Object`（去掉 `L` 和 `;`）
- `[I` -> `[I`（数组类型，保持原样）

**Dictionary::lookup() 已在 Lesson 5 详细解析**。

---

```cpp
    u64 duration_nanos = (u64)((end_time - start_time) * _ticks_to_nanos);
    Profiler::instance()->recordSample(NULL, duration_nanos, event_type, &event);
}
```

**duration_nanos 计算**：

```
假设：
  end_time - start_time = 32000000 ticks (10ms)
  _ticks_to_nanos = 0.3125 (3.2 GHz CPU)

duration_nanos = 32000000 * 0.3125 = 10000000 纳秒 = 10ms
```

**Profiler::recordSample() 已在 Lesson 5 详细解析**。

---

### 2.10 stop() 方法

```cpp
// 文件: lockTracer.cpp 第 67-75 行

void LockTracer::stop() {
    jvmtiEnv* jvmti = VM::jvmti();

    // Disable Java Monitor events
    jvmti->SetEventNotificationMode(JVMTI_DISABLE, JVMTI_EVENT_MONITOR_CONTENDED_ENTER, NULL);
    jvmti->SetEventNotificationMode(JVMTI_DISABLE, JVMTI_EVENT_MONITOR_CONTENDED_ENTERED, NULL);

    // We don't reset the Unsafe::park hook due to JDK-8369219
}
```

**为什么不清除 Unsafe.park Hook？**

注释引用了 **JDK-8369219**：
- 这是一个 JDK bug
- 在某些情况下，清除 Hook 后会导致 JVM 崩溃
- 所以保留 Hook，不影响功能（Hook 内部会检查 `_enabled`）

---

## 3. 完整执行流程图

### 3.1 synchronized 锁争用流程

```
Java 代码: synchronized(obj) { ... }
              │
              v
        JVM 尝试获取 obj 的监视器锁
              │
        ┌─────┴─────┐
        │ 锁是否空闲？│
        └─────┬─────┘
              │
        ┌─────┴─────┐
        │    否     │──→ ObjectMonitor::enter()
        │           │     ├─ 触发 JVMTI MonitorContendedEnter
        │           │     │  └─ LockTracer::MonitorContendedEnter()
        │           │     │      └─ pthread_setspecific(enter_time)
        │           │     │
        │  等待...  │     │
        │           │     │
        │  获得锁   │──→ ObjectMonitor::enter() 返回
        │           │     └─ 触发 JVMTI MonitorContendedEntered
        │           │         └─ LockTracer::MonitorContendedEntered()
        │           │             ├─ pthread_getspecific(enter_time)
        │           │             ├─ duration = now - enter_time
        │           │             ├─ updateCounter() 判断是否采样
        │           │             └─ recordContendedLock()
        │           │                 └─ Profiler::recordSample()
        │  执行代码  │
        │  释放锁   │
        └───────────┘
```

### 3.2 ReentrantLock 锁争用流程

```
Java 代码: lock.lock()
              │
              v
        ReentrantLock.lock()
              │
              v
        tryAcquire() (CAS)
              │
        ┌─────┴─────┐
        │   成功？   │
        └─────┬─────┘
              │
        ┌─────┴─────┐
        │    否     │──→ acquireQueued()
        │           │     └─ shouldParkAfterFailedAcquire()
        │           │         └─ LockSupport.park(this)
        │           │             ├─ Thread.parkBlocker = this
        │           │             └─ Unsafe.park()
        │           │                 │
        │           │                 └─ [Hook 点]
        │           │                     LockTracer::UnsafeParkHook()
        │           │                     ├─ getParkBlocker() 获取锁对象
        │           │                     ├─ isConcurrentLock() 检查类型
        │           │                     ├─ 记录 start_time
        │           │                     ├─ _orig_unsafe_park() 阻塞
        │           │                     ├─ 记录 end_time
        │           │                     └─ recordContendedLock()
        │           │
        │  被唤醒   │
        │  重试... │
        │           │
        │  获得锁   │
        └───────────┘
```

---

## 4. 关键数据结构

### 4.1 LockEvent 内存布局

```cpp
class LockEvent : public EventWithClassId {
    // 继承自 EventWithClassId
    u32 _class_id;      // offset 0, 4 bytes
    
    // LockEvent 自身字段
    u64 _start_time;    // offset 8, 8 bytes (考虑对齐)
    u64 _end_time;      // offset 16, 8 bytes
    uintptr_t _address; // offset 24, 8 bytes
    long long _timeout; // offset 32, 8 bytes
};
// sizeof(LockEvent) = 40 bytes (64-bit)
```

### 4.2 pthread_key_t 线程本地存储

```
进程级数据结构：
┌─────────────────────────────────────────────────────┐
│ 全局键表 (pthread_keys)                              │
│   [0]: key1, destructor1                            │
│   [1]: key2, destructor2                            │
│   ...                                                │
│   [1023]: ...                                        │
└─────────────────────────────────────────────────────┘

线程级数据结构：
┌─────────────────────────────────────────────────────┐
│ Thread 1                                             │
│   ┌─────────────────────────────────────────────────┐│
│   │ TLS values                                      ││
│   │   [key1] = value1  <- lock_tracer_tls 存储点    ││
│   │   [key2] = value2                               ││
│   └─────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────┘
```

---

## 5. 与 G1 GC ObjectMonitor 的关联

**LockTracer 监控的是什么？**
- `synchronized` 锁的争用时间
- 对应 JVM 内部的 `ObjectMonitor`

**ObjectMonitor 在 G1 GC 中的位置**：

```
ObjectMonitor 对象：
┌─────────────────────────────────────────────────────┐
│ _header (mark word)                                 │
│ _object (关联的 Java 对象)                           │
│ _owner (持有锁的线程)                                │
│ _WaitSet (等待队列)                                  │
│ _EntryList (竞争队列)                                │
│ ...                                                  │
└─────────────────────────────────────────────────────┘

当线程竞争锁时：
1. 进入 _EntryList
2. 触发 MonitorContendedEnter 事件
3. 等待...
4. 离开 _EntryList，成为 _owner
5. 触发 MonitorContendedEntered 事件
```

---

## 6. 总结

### 6.1 LockTracer 的两种监控机制

| 机制 | synchronized | ReentrantLock |
|-----|-------------|---------------|
| **检测点** | JVM Monitor 事件 | Unsafe.park() Hook |
| **事件类型** | LOCK_SAMPLE | PARK_SAMPLE |
| **时间记录** | TLS/JVMTI Tag | Hook 内部计时 |
| **锁名获取** | GetClassSignature | parkBlocker 字段 |

### 6.2 性能考虑

| 操作 | 开销 |
|-----|------|
| pthread_setspecific/getspecific | ~10 cycles |
| JVMTI SetTag/GetTag | ~100 cycles |
| JVMTI MonitorContendedEnter 事件 | ~500 cycles |
| TSC::ticks() (RDTSC) | ~20 cycles |

**总体开销**：每次锁争用事件约 500-1000 cycles，可忽略。
