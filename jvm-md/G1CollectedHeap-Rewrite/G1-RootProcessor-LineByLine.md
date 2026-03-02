# G1RootProcessor 逐行源码分析

> **核心目标**：深入理解 G1 GC 根集扫描机制、13 种根来源处理、并行扫描同步和任务认领机制。

---

## 目录

1. [问题引入：什么是 GC Roots？](#1-问题引入什么是-gc-roots)
2. [整体架构](#2-整体架构)
3. [内存布局](#3-内存布局)
4. [13 种根来源详解](#4-13-种根来源详解)
5. [并行扫描机制](#5-并行扫描机制)
6. [根集扫描完整流程](#6-根集扫描完整流程)
7. [关键场景分析](#7-关键场景分析)
8. [GDB 验证脚本](#8-gdb-验证脚本)
9. [面试级 Q&A](#9-面试级-qa)

---

## 1. 问题引入：什么是 GC Roots？

### 问题场景

**可达性分析**是现代 GC 的核心算法：从 GC Roots 出发，遍历对象引用链，标记所有可达对象。

```java
// 示例：可达性分析
class Example {
  static Object staticField;  // GC Root 1：静态字段
  
  public void method() {
    Object local = new Object();  // GC Root 2：栈帧局部变量
    synchronized(local) {         // GC Root 3：锁对象
      // ...
    }
  }
}

// JNI 调用
native void jniMethod();  // GC Root 4：JNI 引用
```

**关键问题**：哪些对象是 GC Roots？

**传统方案的问题**：
- 不同 GC 对根集的定义不同
- 根集扫描可能非常耗时（数百毫秒）
- 多线程扫描需要同步机制

**G1 的解决方案**：
```
G1RootProcessor：
1. 统一的根集定义（13 种根来源）
2. 并行扫描框架（SubTasksDone 任务认领）
3. 分层闭包体系（G1RootClosures）
4. 性能监控（G1GCPhaseTimes）
```

---

## 2. 整体架构

### 2.1 类关系图

```
┌─────────────────────────────────────────────────────────────┐
│                    G1RootProcessor                          │
│                                                             │
│  - _g1h: G1CollectedHeap*                                  │
│  - _process_strong_tasks: SubTasksDone                     │
│  - _srs: StrongRootsScope                                  │
│  - _lock: Monitor                                          │
│  - _n_workers_discovered_strong_classes: volatile jint     │
│                                                             │
│  + evacuate_roots(pss, worker_id): void                    │
│  + process_strong_roots(oops, clds, blobs): void           │
│  + process_all_roots(oops, clds, blobs): void              │
│  - process_java_roots(closures, phase_times, worker_i)     │
│  - process_vm_roots(closures, phase_times, worker_i)       │
│  - process_string_table_roots(closures, phase_times, worker_i)│
│  - process_code_cache_roots(code_closure, phase_times, worker_i)│
└─────────────────────────────────────────────────────────────┘
                           │ 使用
                           ↓
┌─────────────────────────────────────────────────────────────┐
│                    G1RootClosures                           │
│                                                             │
│  + strong_oops(): OopClosure*                              │
│  + weak_oops(): OopClosure*                                │
│  + strong_clds(): CLDClosure*                              │
│  + weak_clds(): CLDClosure*                                │
│  + strong_codeblobs(): CodeBlobClosure*                    │
└─────────────────────────────────────────────────────────────┘
                           ↑ 实现
                           │
        ┌──────────────────┴──────────────────┐
        │                                      │
┌───────────────────────┐        ┌───────────────────────┐
│  StrongRootsClosures  │        │   AllRootsClosures    │
│  (只处理强引用)        │        │   (处理所有引用)      │
└───────────────────────┘        └───────────────────────┘
```

### 2.2 工作流程

```
GC 触发
    │
    ↓
G1RootProcessor 构造（n_workers）
    │
    ├─→ _process_strong_tasks = SubTasksDone(13)
    ├─→ _srs = StrongRootsScope(n_workers)
    └─→ _n_workers_discovered_strong_classes = 0
    │
    ↓
evacuate_roots(pss, worker_id) （并行调用）
    │
    ├─→ process_java_roots()
    │     ├─→ ClassLoaderDataGraph (类加载器)
    │     └─→ Threads (线程栈)
    │
    ├─→ worker_has_discovered_all_strong_classes() （屏障）
    │
    ├─→ process_vm_roots()
    │     ├─→ Universe
    │     ├─→ JNIHandles
    │     ├─→ ObjectSynchronizer
    │     ├─→ Management
    │     ├─→ JVMTI
    │     ├─→ AOTLoader
    │     └─→ SystemDictionary
    │
    ├─→ process_string_table_roots()
    │
    ├─→ RefProcessor (CM)
    │
    ├─→ wait_until_all_strong_classes_discovered() （屏障）
    │
    ├─→ WeakCLDRoots
    │
    ├─→ SATBFiltering
    │
    └─→ _process_strong_tasks.all_tasks_completed()
```

---

## 3. 内存布局

### 3.1 G1RootProcessor 字段布局

```cpp
// src/hotspot/share/gc/g1/g1RootProcessor.hpp:49-58
class G1RootProcessor : public StackObj {
  G1CollectedHeap* _g1h;                                    // offset 0
  SubTasksDone _process_strong_tasks;                      // offset 8
  StrongRootsScope _srs;                                    // offset ?
  OopStorage::ParState<false, false> _par_state_string;    // offset ?
  Monitor _lock;                                            // offset ?
  volatile jint _n_workers_discovered_strong_classes;      // offset ?
};
```

**内存布局图**：

```
G1RootProcessor 对象：
+--------------------------------+ offset 0
| _g1h                           | G1CollectedHeap* (8 bytes)
+--------------------------------+ offset 8
| _process_strong_tasks          | SubTasksDone (~40 bytes)
|  - _tasks[]                    | bool 数组（13 个元素）
|  - _n_threads                  | uint
|  - _n_completed                | volatile jint
+--------------------------------+ offset ~48
| _srs                           | StrongRootsScope (~16 bytes)
|  - _n_threads                  | uint
+--------------------------------+ offset ~64
| _par_state_string              | OopStorage::ParState (~40 bytes)
+--------------------------------+ offset ~104
| _lock                          | Monitor (~160 bytes)
|  - _lock_count                 |
|  - _waiters                    |
|  - _owner                      |
+--------------------------------+ offset ~264
| _n_workers_discovered_strong_classes | volatile jint (4 bytes)
+--------------------------------+ offset ~268
```

### 3.2 SubTasksDone 结构

```cpp
// src/hotspot/share/gc/shared/workgroup.hpp
class SubTasksDone: public CHeapObj<mtInternal> {
  volatile bool* _tasks;           // 任务数组
  uint _n_tasks;                   // 任务数量
  volatile uint _n_completed;      // 已完成任务数
  uint _n_threads;                 // 参与线程数
  
  bool is_task_claimed(uint t);    // 认领任务
  void all_tasks_completed();      // 标记所有任务完成
};
```

**任务数组布局**：

```
_tasks 数组（13 个任务）：
+----+----+----+----+----+----+----+----+----+----+----+----+----+
| T0 | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10| T11| T12|
+----+----+----+----+----+----+----+----+----+----+----+----+----+
  ↓    ↓    ↓    ↓    ↓    ↓    ↓    ↓    ↓    ↓    ↓    ↓    ↓
 Universe JNI  Sync Mgmt SysDict CLDG JVMTI Code AOT  SATB Ref  Weak

每个任务：
  false = 未认领
  true  = 已认领

线程认领过程：
  CAS(&_tasks[t], false, true)
  成功：任务被该线程认领
  失败：任务已被其他线程认领
```

### 3.3 StrongRootsScope 结构

```cpp
// src/hotspot/share/gc/shared/strongRootsScope.hpp:38-47
class StrongRootsScope : public MarkScope {
  const uint _n_threads;           // 参与线程数
  
public:
  StrongRootsScope(uint n_threads);
  ~StrongRootsScope();
  
  uint n_threads() const { return _n_threads; }
};
```

**作用**：

```
StrongRootsScope 是 RAII 对象：

构造时：
  1. MarkScope::MarkScope()
     - 通知 JVMTI 标记开始
     - 增加 StrongRootsScope 计数
  
  2. _n_threads = n_workers

析构时：
  1. 通知 JVMTI 标记结束
  2. 减少 StrongRootsScope 计数

作用：
  - 确保根集扫描期间 JVMTI 知晓
  - 协调并发标记和根集扫描
```

---

## 4. 13 种根来源详解

### 4.1 根来源枚举定义

```cpp
// src/hotspot/share/gc/g1/g1RootProcessor.hpp:59-74
enum G1H_process_roots_tasks {
  G1RP_PS_Universe_oops_do,              // 0: Universe 对象
  G1RP_PS_JNIHandles_oops_do,            // 1: JNI 句柄
  G1RP_PS_ObjectSynchronizer_oops_do,    // 2: 对象监视器
  G1RP_PS_Management_oops_do,            // 3: JMX 管理
  G1RP_PS_SystemDictionary_oops_do,      // 4: 系统字典
  G1RP_PS_ClassLoaderDataGraph_oops_do,  // 5: 类加载器图
  G1RP_PS_jvmti_oops_do,                 // 6: JVMTI
  G1RP_PS_CodeCache_oops_do,             // 7: 代码缓存
  G1RP_PS_aot_oops_do,                   // 8: AOT 编译
  G1RP_PS_filter_satb_buffers,           // 9: SATB 缓冲区过滤
  G1RP_PS_refProcessor_oops_do,          // 10: 引用处理器
  G1RP_PS_weakProcessor_oops_do,         // 11: 弱引用处理器
  G1RP_PS_NumElements                    // 12: 总数（13 个）
};
```

### 4.2 每种根来源的详细说明

#### 1. Universe（全局对象）

```cpp
// src/hotspot/share/gc/g1/g1RootProcessor.cpp:248-252
if (!_process_strong_tasks.is_task_claimed(G1RP_PS_Universe_oops_do)) {
  Universe::oops_do(strong_roots);
}
```

**包含**：
```
Universe::_main_thread_group          // 主线程组
Universe::_system_thread_group        // 系统线程组
Universe::_the_empty_class_name_array // 空类名数组
Universe::_null_ptr_exception_instance
Universe::_arithmetic_exception_instance
...（所有 JVM 内部对象）
```

**为什么需要**：JVM 内部对象不能被回收

---

#### 2. JNIHandles（JNI 句柄）

```cpp
// src/hotspot/share/gc/g1/g1RootProcessor.cpp:255-259
if (!_process_strong_tasks.is_task_claimed(G1RP_PS_JNIHandles_oops_do)) {
  JNIHandles::oops_do(strong_roots);
}
```

**包含**：
```
全局 JNI 引用：
  - NewGlobalRef() 创建的引用
  - JNI 代码中持有的 Java 对象引用

局部 JNI 引用：
  - NewLocalRef() 创建的引用
  - JNI 方法参数和返回值
```

**示例**：
```c
// C++ JNI 代码
JNIEXPORT void JNICALL Java_Example_nativeMethod(JNIEnv* env, jobject obj) {
  jclass cls = env->GetObjectClass(obj);  // 局部引用
  static jobject globalRef = env->NewGlobalRef(obj);  // 全局引用
  // 这些引用都是 GC Roots
}
```

---

#### 3. ObjectSynchronizer（对象监视器）

```cpp
// src/hotspot/share/gc/g1/g1RootProcessor.cpp:262-266
if (!_process_strong_tasks.is_task_claimed(G1RP_PS_ObjectSynchronizer_oops_do)) {
  ObjectSynchronizer::oops_do(strong_roots);
}
```

**包含**：
```
synchronized (obj) {
  // obj 被锁定，成为 GC Root
}

所有被锁定的对象：
  - synchronized 块中的对象
  - wait()/notify() 调用者
  - ObjectMonitor 集合
```

**为什么需要**：被锁定的对象不能在锁释放前被回收

---

#### 4. Management（JMX 管理）

```cpp
// src/hotspot/share/gc/g1/g1RootProcessor.cpp:269-273
if (!_process_strong_tasks.is_task_claimed(G1RP_PS_Management_oops_do)) {
  Management::oops_do(strong_roots);
}
```

**包含**：
```
JMX (Java Management Extensions) 相关对象：
  - MemoryMXBean
  - ThreadMXBean
  - ClassLoadingMXBean
  - RuntimeMXBean
  - ...
```

**为什么需要**：JMX Bean 持有 Java 对象引用

---

#### 5. SystemDictionary（系统字典）

```cpp
// src/hotspot/share/gc/g1/g1RootProcessor.cpp:292-296
if (!_process_strong_tasks.is_task_claimed(G1RP_PS_SystemDictionary_oops_do)) {
  SystemDictionary::oops_do(strong_roots);
}
```

**包含**：
```
系统类加载器：
  - Bootstrap ClassLoader
  - Platform ClassLoader
  - System ClassLoader

已加载的类：
  - java.lang.Object
  - java.lang.String
  - ...（所有核心类）

类的静态字段：
  - System.out
  - System.err
  - ...（所有静态字段）
```

---

#### 6. ClassLoaderDataGraph（类加载器图）

```cpp
// src/hotspot/share/gc/g1/g1RootProcessor.cpp:227-231
if (!_process_strong_tasks.is_task_claimed(G1RP_PS_ClassLoaderDataGraph_oops_do)) {
  ClassLoaderDataGraph::roots_cld_do(closures->strong_clds(), closures->weak_clds());
}
```

**包含**：
```
所有类加载器及其加载的类：
  ClassLoaderData
    ├── _class_loader (类加载器对象)
    ├── _dictionary (类名字典)
    ├── _klasses (已加载的类)
    └── _modules (模块)

示例：
  CustomClassLoader → ClassA → ClassB → ...
```

**特点**：
- 强 CLD：存活类加载器
- 弱 CLD：可能被卸载的类加载器

---

#### 7. Threads（线程栈）

```cpp
// src/hotspot/share/gc/g1/g1RootProcessor.cpp:234-239
bool is_par = n_workers() > 1;
Threads::possibly_parallel_oops_do(is_par,
                                   closures->strong_oops(),
                                   closures->strong_codeblobs());
```

**包含**：
```
所有 Java 线程的栈帧：
  Frame 0: 局部变量、操作数栈
  Frame 1: 局部变量、操作数栈
  ...
  
每个栈帧包含：
  - 局部变量表（Local Variable Table）
  - 操作数栈（Operand Stack）
  - 锁记录（Lock Records）
  
示例：
  void method() {
    Object a = new Object();  // a 是 GC Root
    Object b = a;            // b 不是 GC Root（不是根，是引用）
  }
```

**为什么最重要**：
```
线程栈是最大的根集来源：
  - 大多数对象通过局部变量引用
  - 扫描耗时最长
  - 必须并行处理
```

---

#### 8. JVMTI（Java 虚拟机工具接口）

```cpp
// src/hotspot/share/gc/g1/g1RootProcessor.cpp:276-280
if (!_process_strong_tasks.is_task_claimed(G1RP_PS_jvmti_oops_do)) {
  JvmtiExport::oops_do(strong_roots);
}
```

**包含**：
```
JVMTI 代理持有的引用：
  - Debug 代理（如 jdb）
  - Profiler（如 JProfiler）
  - APM 工具（如 Skywalking）
  
示例：
  jvmtiEnv* env = ...;
  jobject taggedObject = ...;  // JVMTI 标记的对象
```

---

#### 9. CodeCache（代码缓存）

```cpp
// src/hotspot/share/gc/g1/g1RootProcessor.cpp:309-315
if (!_process_strong_tasks.is_task_claimed(G1RP_PS_CodeCache_oops_do)) {
  CodeCache::blobs_do(code_closure);
}
```

**包含**：
```
JIT 编译代码中的对象引用：
  nmethod (JIT 编译的方法)
    ├── 内联常量
    ├── 对象常量（String、Class 等）
    └── oop 映射表
  
示例：
  void method() {
    Object obj = CONSTANT_OBJECT;  // 编译时常量
    // obj 引用嵌入在 nmethod 中
  }
```

---

#### 10. AOTLoader（AOT 编译器）

```cpp
// src/hotspot/share/gc/g1/g1RootProcessor.cpp:283-289
if (UseAOT) {
  if (!_process_strong_tasks.is_task_claimed(G1RP_PS_aot_oops_do)) {
    AOTLoader::oops_do(strong_roots);
  }
}
```

**包含**：
```
AOT (Ahead-Of-Time) 编译代码中的引用：
  - jaotc 编译的代码
  - 共享库中的对象引用
```

---

#### 11. StringTable（字符串表）

```cpp
// src/hotspot/share/gc/g1/g1RootProcessor.cpp:299-307
StringTable::possibly_parallel_oops_do(&_par_state_string, closures->weak_oops());
```

**包含**：
```
所有 intern 字符串：
  String s1 = "hello".intern();  // 在字符串表中
  String s2 = new String("world").intern();  // 也加入表
  
StringTable 是哈希表：
  Bucket 0: String1 → String2 → ...
  Bucket 1: String3 → String4 → ...
  ...
  
特点：
  - 弱引用（可以被回收）
  - 并行处理（每个线程处理部分桶）
```

---

#### 12. RefProcessor（引用处理器）

```cpp
// src/hotspot/share/gc/g1/g1RootProcessor.cpp:99-106
if (!_process_strong_tasks.is_task_claimed(G1RP_PS_refProcessor_oops_do)) {
  _g1h->ref_processor_cm()->weak_oops_do(closures->strong_oops());
}
```

**包含**：
```
引用对象（Reference）：
  - SoftReference
  - WeakReference
  - PhantomReference
  - FinalReference
  
示例：
  SoftReference<Object> softRef = new SoftReference<>(obj);
  // softRef 本身是 GC Root
  // obj 不是 GC Root（可能被回收）
```

---

#### 13. WeakProcessor（弱引用处理器）

```cpp
// src/hotspot/share/gc/g1/g1RootProcessor.cpp:322-324
if (!_process_strong_tasks.is_task_claimed(G1RP_PS_weakProcessor_oops_do)) {
  WeakProcessor::oops_do(oops);
}
```

**包含**：
```
Java 9+ 的 Cleaner 和其他弱引用机制：
  Cleaner cleaner = Cleaner.create();
  cleaner.register(obj, () -> cleanup());
  // cleaner 内部引用是 GC Root
```

---

## 5. 并行扫描机制

### 5.1 SubTasksDone 任务认领

```cpp
// src/hotspot/share/gc/shared/workgroup.hpp
bool is_task_claimed(uint t) {
  assert(t < _n_tasks, "task id out of range");
  
  // CAS 原子操作
  jbyte res = Atomic::cmpxchg((jbyte)1, &_tasks[t], (jbyte)0);
  
  // 返回值：
  //   false = 认领成功（之前未被认领）
  //   true  = 已被其他线程认领
  return res != 0;
}
```

**认领流程**：

```
初始状态：
  _tasks[0] = false  // Universe 任务未认领
  _tasks[1] = false  // JNI 任务未认领
  ...

线程 A 尝试认领 Universe 任务：
  CAS(&_tasks[0], false, true)
  成功：_tasks[0] = true
  返回：false（认领成功）
  
线程 B 尝试认领 Universe 任务：
  CAS(&_tasks[0], true, true)
  失败：_tasks[0] 已经是 true
  返回：true（已被认领）
  
结果：
  线程 A 处理 Universe
  线程 B 跳过 Universe，尝试其他任务
```

### 5.2 任务认领示例

```cpp
// src/hotspot/share/gc/g1/g1RootProcessor.cpp:247-252
{
  G1GCParPhaseTimesTracker x(phase_times, G1GCPhaseTimes::UniverseRoots, worker_i);
  
  if (!_process_strong_tasks.is_task_claimed(G1RP_PS_Universe_oops_do)) {
    // 只有第一个到达的线程会执行
    Universe::oops_do(strong_roots);
  }
  // 其他线程直接跳过
}
```

**工作流程**：

```
假设有 4 个线程（W0, W1, W2, W3）和 13 个任务：

时刻 T0：
  W0: is_task_claimed(0) = false → 处理 Universe
  W1: is_task_claimed(1) = false → 处理 JNI
  W2: is_task_claimed(2) = false → 处理 ObjectSynchronizer
  W3: is_task_claimed(3) = false → 处理 Management

时刻 T1（W0 完成 Universe）：
  W0: is_task_claimed(4) = false → 处理 SystemDictionary
  W1: is_task_claimed(0) = true  → 跳过，尝试下一个
  W1: is_task_claimed(5) = false → 处理 ClassLoaderDataGraph
  W2: is_task_claimed(3) = true  → 跳过
  W2: is_task_claimed(6) = false → 处理 JVMTI
  W3: is_task_claimed(4) = true  → 跳过
  W3: is_task_claimed(7) = false → 处理 CodeCache

...

最终：13 个任务被 4 个线程并行处理
```

### 5.3 CLD 并发屏障

```cpp
// src/hotspot/share/gc/g1/g1RootProcessor.cpp:49-69
void G1RootProcessor::worker_has_discovered_all_strong_classes() {
  uint new_value = (uint)Atomic::add(1, &_n_workers_discovered_strong_classes);
  
  if (new_value == n_workers()) {
    // 最后一个到达的线程，通知其他线程
    MonitorLockerEx ml(&_lock, Mutex::_no_safepoint_check_flag);
    _lock.notify_all();
  }
}

void G1RootProcessor::wait_until_all_strong_classes_discovered() {
  if ((uint)_n_workers_discovered_strong_classes != n_workers()) {
    MonitorLockerEx ml(&_lock, Mutex::_no_safepoint_check_flag);
    
    while ((uint)_n_workers_discovered_strong_classes != n_workers()) {
      _lock.wait(Mutex::_no_safepoint_check_flag, 0, false);
    }
  }
}
```

**屏障的作用**：

```
问题：为什么要等所有线程完成强 CLD 扫描？

答案：因为强 CLD 和弱 CLD 有依赖关系

强 CLD：存活的类加载器
弱 CLD：可能被卸载的类加载器

处理顺序：
  阶段1：所有线程处理强 CLD
    ↓
  屏障：等待所有线程完成
    ↓
  阶段2：处理弱 CLD

如果不等屏障：
  线程 A 处理强 CLD，发现类加载器 L 存活
  线程 B 开始处理弱 CLD，认为 L 可以卸载
  → 不一致！
```

**时序图**：

```
W0          W1          W2          W3
│           │           │           │
├─ 强 CLD   ├─ 强 CLD   ├─ 强 CLD   ├─ 强 CLD
│           │           │           │
│           │           │           │
├─ 完成 ────┼───────────┼───────────┤
│ notify    │           │           │
│ wait      │ wait      │ wait      │ wait
│           │           │           │
│ notify_all│           │           │
│           │           │           │
├─ 弱 CLD   ├─ 弱 CLD   ├─ 弱 CLD   ├─ 弱 CLD
│           │           │           │
```

---

## 6. 根集扫描完整流程

### 6.1 evacuate_roots() 主流程

```cpp
// src/hotspot/share/gc/g1/g1RootProcessor.cpp:79-137
void G1RootProcessor::evacuate_roots(G1ParScanThreadState* pss, uint worker_i) {
  G1GCPhaseTimes* phase_times = _g1h->g1_policy()->phase_times();
  
  // 性能计时器
  G1EvacPhaseTimesTracker timer(phase_times, pss, G1GCPhaseTimes::ExtRootScan, worker_i);
  
  // 步骤1：获取闭包
  G1EvacuationRootClosures* closures = pss->closures();
  
  // 步骤2：处理 Java 根（线程栈 + CLDG）
  process_java_roots(closures, phase_times, worker_i);
  
  // 步骤3：通知完成强 CLD 扫描
  if (closures->trace_metadata()) {
    worker_has_discovered_all_strong_classes();
  }
  
  // 步骤4：处理 VM 根（Universe, JNI, ...）
  process_vm_roots(closures, phase_times, worker_i);
  
  // 步骤5：处理字符串表
  process_string_table_roots(closures, phase_times, worker_i);
  
  // 步骤6：处理引用处理器
  {
    G1GCParPhaseTimesTracker x(phase_times, G1GCPhaseTimes::CMRefRoots, worker_i);
    if (!_process_strong_tasks.is_task_claimed(G1RP_PS_refProcessor_oops_do)) {
      _g1h->ref_processor_cm()->weak_oops_do(closures->strong_oops());
    }
  }
  
  // 步骤7：等待所有线程完成强 CLD 扫描
  if (closures->trace_metadata()) {
    {
      G1GCParPhaseTimesTracker x(phase_times, G1GCPhaseTimes::WaitForStrongCLD, worker_i);
      wait_until_all_strong_classes_discovered();
    }
    
    // 步骤8：处理弱 CLD
    G1GCParPhaseTimesTracker x(phase_times, G1GCPhaseTimes::WeakCLDRoots, worker_i);
    ClassLoaderDataGraph::roots_cld_do(NULL, closures->second_pass_weak_clds());
  }
  
  // 步骤9：过滤 SATB 缓冲区
  {
    G1GCParPhaseTimesTracker x(phase_times, G1GCPhaseTimes::SATBFiltering, worker_i);
    if (!_process_strong_tasks.is_task_claimed(G1RP_PS_filter_satb_buffers) && 
        _g1h->collector_state()->mark_or_rebuild_in_progress()) {
      G1BarrierSet::satb_mark_queue_set().filter_thread_buffers();
    }
  }
  
  // 步骤10：标记所有任务完成
  _process_strong_tasks.all_tasks_completed(n_workers());
}
```

### 6.2 process_java_roots() 详解

```cpp
// src/hotspot/share/gc/g1/g1RootProcessor.cpp:220-240
void G1RootProcessor::process_java_roots(G1RootClosures* closures,
                                         G1GCPhaseTimes* phase_times,
                                         uint worker_i) {
  // 步骤1：处理 ClassLoaderDataGraph
  {
    G1GCParPhaseTimesTracker x(phase_times, G1GCPhaseTimes::CLDGRoots, worker_i);
    
    if (!_process_strong_tasks.is_task_claimed(G1RP_PS_ClassLoaderDataGraph_oops_do)) {
      // 强 CLD + 弱 CLD
      ClassLoaderDataGraph::roots_cld_do(closures->strong_clds(), closures->weak_clds());
    }
  }
  
  // 步骤2：处理所有线程栈
  {
    G1GCParPhaseTimesTracker x(phase_times, G1GCPhaseTimes::ThreadRoots, worker_i);
    
    bool is_par = n_workers() > 1;
    Threads::possibly_parallel_oops_do(is_par,
                                       closures->strong_oops(),
                                       closures->strong_codeblobs());
  }
}
```

**并行扫描线程栈**：

```cpp
// Threads::possibly_parallel_oops_do()
void Threads::possibly_parallel_oops_do(bool is_par, OopClosure* f, CodeBlobClosure* cf) {
  if (is_par) {
    // 并行扫描
    for (JavaThread* thread = _thread_list; thread != NULL; thread = thread->next()) {
      if (thread->claim_oops_do(is_par)) {
        // 线程栈被当前 worker 认领
        thread->oops_do(f, cf);
      }
      // 其他 worker 跳过已认领的线程
    }
  } else {
    // 串行扫描
    for (JavaThread* thread = _thread_list; thread != NULL; thread = thread->next()) {
      thread->oops_do(f, cf);
    }
  }
}
```

**线程栈认领机制**：

```
JavaThread 对象：
  - _threads_do_token: int
  
认领逻辑：
  bool claim_oops_do(bool is_par) {
    if (!is_par) return true;
    
    int token = Threads::thread_claim_token();
    
    // CAS 认领
    int old = Atomic::cmpxchg(token, &_threads_do_token, token - 1);
    
    return old != token;
  }

示例：
  初始：_threads_do_token = -1
  
  Worker 0:
    token = 1
    CAS(&_threads_do_token, 1, -1) → 成功，_threads_do_token = 1
    认领线程，扫描栈
    
  Worker 1:
    token = 1
    CAS(&_threads_do_token, 1, 1) → 失败
    跳过该线程
    
  Worker 2:
    token = 1
    CAS(&_threads_do_token, 1, 1) → 失败
    跳过该线程
```

---

## 7. 关键场景分析

### 7.1 场景1：Young GC 根集扫描

```
触发：Eden 区满
工作线程数：n_workers = 8

流程：
1. G1RootProcessor 构造（8 workers）
2. 8 个线程并行调用 evacuate_roots()

扫描顺序：
  W0: Universe + SystemDictionary + CodeCache
  W1: JNI + ClassLoaderDataGraph
  W2: ObjectSynchronizer + Thread[0-2]
  W3: Management + Thread[3-5]
  W4: JVMTI + Thread[6-8]
  W5: AOT + Thread[9-11]
  W6: StringTable + Thread[12-14]
  W7: RefProcessor + Thread[15-17]

屏障：
  所有线程完成强 CLD → 处理弱 CLD
  所有线程完成根集扫描 → 进入 Evacuation 阶段

性能：
  根集扫描时间：10-50ms（取决于线程数和根集大小）
  并行效率：接近线性（负载均衡好）
```

### 7.2 场景2：Mixed GC 根集扫描

```
触发：并发标记完成后，选择部分老年代 Region
工作线程数：n_workers = 8

与 Young GC 的区别：
  - 无 SATB 过滤（并发标记已完成）
  - 弱 CLD 处理更复杂（可能卸载类）

流程：
  1. 强 CLD 扫描
  2. 屏障等待
  3. 弱 CLD 扫描（可能卸载未使用的类）
  4. Evacuation

性能：
  根集扫描时间：20-100ms（类卸载需要额外时间）
```

### 7.3 场景3：Full GC 根集扫描

```
触发：System.gc() 或分配失败
工作线程数：n_workers = 1（串行）

流程：
  process_all_roots(oops, clds, blobs)
    ├─ Universe
    ├─ JNI
    ├─ ObjectSynchronizer
    ├─ Management
    ├─ SystemDictionary
    ├─ ClassLoaderDataGraph
    ├─ JVMTI
    ├─ StringTable
    └─ CodeCache

特点：
  - 串行处理
  - 扫描所有根（无弱引用优化）
  - 耗时更长（100-500ms）
```

---

## 8. GDB 验证脚本

### 8.1 验证根集扫描流程

```gdb
# gdb_script: verify_root_processor.gdb
# 用法: gdb -x verify_root_processor.gdb --args java -Xms8g -Xmx8g -XX:+UseG1GC ...

break G1RootProcessor::evacuate_roots
commands
  printf "\n=== evacuate_roots() 被调用 ===\n"
  printf "worker_id: %u\n", $rsi
  
  # 单步执行
  next
  next
  
  continue
end

run
```

### 8.2 观察任务认领

```gdb
# gdb_script: observe_task_claim.gdb

break SubTasksDone::is_task_claimed
commands
  printf "\n=== is_task_claimed() ===\n"
  printf "task_id: %u\n", $rdi
  
  # 查看结果
  next
  printf "claimed: %s\n", $rax ? "yes" : "no"
  
  continue
end

run
```

### 8.3 观察 CLD 屏障

```gdb
# gdb_script: observe_cld_barrier.gdb

break G1RootProcessor::worker_has_discovered_all_strong_classes
commands
  printf "\n=== worker_has_discovered_all_strong_classes() ===\n"
  
  # 查看计数器
  set $rp = (G1RootProcessor*)$rdi
  printf "n_workers_discovered: %d\n", $rp->_n_workers_discovered_strong_classes
  printf "n_workers: %u\n", $rp->n_workers()
  
  continue
end

break G1RootProcessor::wait_until_all_strong_classes_discovered
commands
  printf "\n=== wait_until_all_strong_classes_discovered() ===\n"
  
  # 查看是否需要等待
  set $rp = (G1RootProcessor*)$rdi
  printf "n_workers_discovered: %d\n", $rp->_n_workers_discovered_strong_classes
  printf "n_workers: %u\n", $rp->n_workers()
  
  continue
end

run
```

### 8.4 统计各根来源耗时

```gdb
# gdb_script: stat_root_scan_time.gdb

break G1RootProcessor::evacuate_roots
commands
  set $start_time = $_stktimestamp
  continue
end

break G1RootProcessor::process_java_roots
commands
  printf "Java Roots: %lu ns\n", $_stktimestamp - $start_time
  continue
end

break G1RootProcessor::process_vm_roots
commands
  printf "VM Roots: %lu ns\n", $_stktimestamp - $start_time
  continue
end

break G1RootProcessor::process_string_table_roots
commands
  printf "String Table: %lu ns\n", $_stktimestamp - $start_time
  continue
end

run
```

---

## 9. 面试级 Q&A

### Q1: 什么是 GC Roots？为什么需要它们？

**A**: GC Roots 是可达性分析的起点。

**定义**：
```
GC Roots 是一组必须存活的对象引用，从它们出发可以遍历所有存活对象。

不可达对象：
  从 GC Roots 出发无法到达的对象，可以被回收。
```

**为什么需要**：
```
可达性分析算法：
  1. 从 GC Roots 开始遍历
  2. 标记所有可达对象
  3. 回收不可达对象

如果没有 GC Roots：
  无法区分存活对象和垃圾对象
  无法安全回收内存
```

**比喻**：
```
GC Roots 就像树根：
  - 树根（GC Roots）→ 树干（主对象）→ 树枝（引用）→ 树叶（末端对象）
  - 没有连接到树根的树枝 → 枯枝（垃圾）→ 可以剪掉（回收）
```

---

### Q2: G1 有哪些类型的 GC Roots？

**A**: G1 定义了 13 种根来源。

**分类**：

| 类型 | 说明 | 示例 |
|------|------|------|
| **线程相关** | | |
| Threads | 线程栈 | 局部变量、操作数栈 |
| ClassLoaderDataGraph | 类加载器 | 已加载的类 |
| **JVM 内部** | | |
| Universe | JVM 内部对象 | 异常实例、空引用 |
| SystemDictionary | 系统类加载器 | java.lang.Object |
| **外部引用** | | |
| JNIHandles | JNI 句柄 | native 代码引用 |
| JVMTI | 工具接口 | debugger、profiler |
| **同步机制** | | |
| ObjectSynchronizer | 锁对象 | synchronized |
| **管理接口** | | |
| Management | JMX | MemoryMXBean |
| **编译代码** | | |
| CodeCache | JIT 代码 | nmethod 常量 |
| AOTLoader | AOT 代码 | 预编译代码 |
| **特殊引用** | | |
| StringTable | intern 字符串 | "hello".intern() |
| RefProcessor | 引用对象 | SoftReference |
| WeakProcessor | 弱引用 | Cleaner |

**重要性排序**：
```
1. Threads（线程栈） - 最大的根集来源，占比 > 80%
2. ClassLoaderDataGraph - 所有类的元数据
3. JNIHandles - native 代码交互
4. 其他 - 占比 < 5%
```

---

### Q3: 为什么线程栈是最大的根集来源？

**A**: 因为大多数对象通过局部变量引用。

**示例**：
```java
void method() {
  Object a = new Object();  // a 在栈帧中
  Object b = a;            // b 在栈帧中
  
  for (int i = 0; i < 1000; i++) {
    Object temp = new Object();  // temp 在栈帧中
    // temp 引用的对象成为 GC Root
  }
}
```

**栈帧结构**：
```
+-------------------+
| 局部变量表         |  ← 包含对象引用（GC Roots）
+-------------------+
| 操作数栈           |  ← 可能包含对象引用
+-------------------+
| 帧数据             |
+-------------------+

每个线程可能有数百个栈帧
每个栈帧可能有数十个局部变量
→ 栈帧中的引用数量巨大
```

**性能影响**：
```
扫描时间：
  单个线程栈：1-10ms
  所有线程栈：10-100ms（并行）
  
优化：
  1. 并行扫描不同线程的栈
  2. 栈帧内联优化
  3. 减少栈深度
```

---

### Q4: SubTasksDone 如何保证任务不被重复处理？

**A**: 通过 CAS 原子操作。

**原理**：
```cpp
bool is_task_claimed(uint t) {
  // 原子 CAS 操作
  jbyte res = Atomic::cmpxchg((jbyte)1, &_tasks[t], (jbyte)0);
  
  // CAS 语义：
  // if (_tasks[t] == 0) {
  //   _tasks[t] = 1;
  //   return false;  // 认领成功
  // } else {
  //   return true;   // 已被认领
  // }
  
  return res != 0;
}
```

**并发场景**：
```
初始：_tasks[0] = 0

线程 A 和 B 同时尝试认领任务 0：

线程 A：
  Atomic::cmpxchg(1, &_tasks[0], 0)
  → _tasks[0] == 0，设置为 1
  → 返回旧值 0
  → res = 0，认领成功

线程 B（同时）：
  Atomic::cmpxchg(1, &_tasks[0], 0)
  → _tasks[0] != 0（已被 A 改为 1）
  → 不修改
  → 返回当前值 1
  → res = 1，已被认领

结果：只有一个线程认领成功
```

---

### Q5: 为什么需要 CLD 屏障？

**A**: 确保强 CLD 和弱 CLD 处理的一致性。

**问题场景**：
```
假设没有屏障：

线程 A：
  扫描强 CLD
  发现类加载器 L 存活
  标记 L 为存活

线程 B（同时）：
  扫描弱 CLD
  认为 L 未被强 CLD 引用
  卸载 L 和它加载的类

结果：
  A 认为 L 存活
  B 卸载了 L
  → 不一致！崩溃！
```

**有屏障的流程**：
```
阶段 1（并行）：
  所有线程扫描强 CLD
  标记存活的类加载器

屏障：
  等待所有线程完成

阶段 2（并行）：
  扫描弱 CLD
  只卸载未被标记的类加载器

结果：
  一致性得到保证
```

**代码**：
```cpp
// 阶段 1：强 CLD
process_java_roots(closures, ...);  // 包含强 CLD

// 通知完成
worker_has_discovered_all_strong_classes();

// 阶段 1.5：其他根
process_vm_roots(...);

// 屏障：等待所有线程完成强 CLD
wait_until_all_strong_classes_discovered();

// 阶段 2：弱 CLD
ClassLoaderDataGraph::roots_cld_do(NULL, closures->second_pass_weak_clds());
```

---

### Q6: 如何优化根集扫描性能？

**A**: 从多个维度优化。

**1. 并行化**：
```
优化：
  多个线程并行扫描不同根来源
  
效果：
  线性加速（接近 n_workers 倍）
  
配置：
  -XX:ParallelGCThreads=8
```

**2. 任务分区**：
```
优化：
  大任务分为小任务（线程栈、StringTable）
  
示例：
  StringTable：
    - 桶分区（每个线程处理部分桶）
    - OopStorage::ParState
  
线程栈：
  - 每个线程认领部分 JavaThread
  - claim_oops_do() 机制
```

**3. 缓存优化**：
```
优化：
  - 顺序访问（提高缓存命中率）
  - 预取（Prefetch）
  
示例：
  Threads::possibly_parallel_oops_do()
    → 线性遍历线程列表
    → 缓存友好
```

**4. 减少根集大小**：
```
优化：
  - 减少线程数（-XX:ParallelGCThreads）
  - 减少局部变量
  - 避免过度 intern
  
示例：
  不推荐：
    for (int i = 0; i < 10000; i++) {
      String s = "value".intern();  // 增加 StringTable 负担
    }
  
  推荐：
    private static final String VALUE = "value";  // 常量
```

**5. 异步处理**：
```
优化：
  - StringTable 并发清理
  - ClassLoaderDataGraph 并发卸载
  
效果：
  减少同步等待时间
```

---

### Q7: 根集扫描在哪个阶段发生？

**A**: GC 暂停的最初阶段。

**Young GC 流程**：
```
1. 根集扫描（STW）          ← 这里！
   ├─ 线程栈
   ├─ 强 CLD
   ├─ VM 根
   └─ 弱 CLD

2. Evacuation（STW）
   ├─ 复制存活对象
   └─ 更新引用

3. 弱引用处理（STW）
```

**并发标记流程**：
```
1. 初始标记（STW）
   └─ 根集扫描           ← 这里！

2. 并发标记（并发）
   └─ 从根集遍历整个堆

3. 最终标记（STW）
   └─ 处理 SATB 缓冲区

4. 清理（STW）
   └─ 统计、卸载类
```

**Full GC 流程**：
```
1. 根集扫描（STW）          ← 这里！
   └─ 所有根

2. 标记（STW）
   └─ 从根集遍历

3. 压缩（STW）
   └─ 移动对象
```

---

### Q8: 如何用 GDB 查看当前有哪些线程在扫描根集？

**A**: 完整步骤：

```gdb
# 1. 设置断点
break G1RootProcessor::evacuate_roots
commands
  printf "Worker %u: 开始扫描根集\n", $rsi
  continue
end

# 2. 运行程序
run

# 3. 查看所有线程
info threads

# 输出示例：
#   Id   Target Id         Frame 
#   1    Thread 0x7f...    G1RootProcessor::evacuate_roots
#   2    Thread 0x7f...    G1RootProcessor::evacuate_roots
#   3    Thread 0x7f...    G1RootProcessor::evacuate_roots
#   ...

# 4. 查看某个线程的扫描进度
thread 1
bt
# #0  G1RootProcessor::process_java_roots
# #1  G1RootProcessor::evacuate_roots
# ...

# 5. 查看任务认领状态
set $rp = (G1RootProcessor*)$_g1h->_root_processor
set $tasks = $rp->_process_strong_tasks._tasks

printf "Universe: %s\n", $tasks[0] ? "已认领" : "未认领"
printf "JNI: %s\n", $tasks[1] ? "已认领" : "未认领"
# ...（查看所有 13 个任务）

# 6. 查看屏障状态
printf "已发现强 CLD 的线程数: %d\n", $rp->_n_workers_discovered_strong_classes
printf "总线程数: %u\n", $rp->n_workers()
```

---

## 总结

**G1RootProcessor 的核心价值**：

1. **统一根集定义**：13 种根来源，覆盖所有场景
2. **并行扫描框架**：SubTasksDone 任务认领，高效并行
3. **一致性保障**：CLD 屏障确保强/弱引用处理一致
4. **性能监控**：G1GCPhaseTimes 精确记录各阶段耗时

**关键数据**：
- 根来源类型：13 种
- 任务数组大小：13 个 bool
- 最大耗时：线程栈扫描（10-100ms）
- 并行效率：接近线性

**下一步学习**：
- G1ParScanThreadState：根集扫描后的对象处理
- G1RootClosures：闭包体系的具体实现
- G1EvacuationRootClosures：Evacuation 阶段的闭包
