# Chapter 4: 对象回收与终结 — 引用处理与 Finalizer 机制

> **系列**：Runtime System — 对象生命周期  
> **环境**：OpenJDK 11, `-Xms8g -Xmx8g -XX:+UseG1GC`, LP64  
> **前置**：Ch1（对象头）、Ch2（对象分配）、Ch3（锁优化）

---

## 1. 问题引入：对象"死了"之后还能活过来？

GC 判定一个对象不可达后，它真的就被立即回收了吗？不一定。Java 的引用处理系统在"判死"和"真正回收"之间插入了多个阶段：

1. **有 `finalize()` 的对象** — 不可达时不会立即回收，而是被送到 Finalizer 线程执行 `finalize()`，如果在 `finalize()` 中重新建立强引用，对象可以"复活"
2. **SoftReference** — 内存充足时不清除，内存紧张时才清除
3. **WeakReference** — 下一次 GC 就清除
4. **PhantomReference** — 无法获取 referent，仅用于跟踪回收时机

这四种机制形成了 Java 的**五级可达性模型**：

```
Strong → Soft → Weak → Finalizable → Phantom → Unreachable
  │        │       │         │            │           │
  │        │       │         │            │           └─ 可回收
  │        │       │         │            └─ 已终结，虚引用通知
  │        │       │         └─ 需要执行 finalize()
  │        │       └─ 下次 GC 清除
  │        └─ 内存不足时清除
  └─ 不回收
```

---

## 2. Finalizer 机制全链路

### 2.1 第一步：类加载时检测 has_finalizer 标志

> 源码：`src/hotspot/share/classfile/classFileParser.cpp:2937-2943, 4495-4506`

类文件解析时，检查是否有非空的 `finalize()` 方法：

```cpp
// 解析每个方法时
if (name == vmSymbols::finalize_method_name() &&
    signature == vmSymbols::void_method_signature()) {
  if (m->is_empty_method()) {
    _has_empty_finalizer = true;   // 空 finalize() → 不设标志
  } else {
    _has_finalizer = true;         // 非空 finalize() → 需要特殊处理
  }
}
```

在 `set_precomputed_flags()` 中设置到 Klass 上：

```cpp
if (!_has_empty_finalizer) {
  if (_has_finalizer || (super != NULL && super->has_finalizer())) {
    ik->set_has_finalizer();  // 设置 JVM_ACC_HAS_FINALIZER = 0x40000000
  }
}
```

**关键优化**：如果 `finalize()` 是空方法（只有 `return` 字节码），不设置标志。这意味着 `Object.finalize()` 本身（空实现）不会触发终结开销。标志通过继承传播——父类有非空 finalize，子类也会被标记。

### 2.2 第二步：对象分配后注册 Finalizer

> 源码：`src/hotspot/share/oops/instanceKlass.cpp:1225-1251`

注册时机由 `RegisterFinalizersAtInit`（默认 `true`）控制：

**默认路径（RegisterFinalizersAtInit=true）**：在 `Object.<init>` 返回时注册

解释器在 `Object.<init>` 方法的 `return` 字节码处插入了对 `register_finalizer` 的调用（字节码重写阶段完成）。C1/C2 编译器也在 `Object.<init>` 的出口处生成相同的调用。

**备选路径（RegisterFinalizersAtInit=false）**：在 `allocate_instance()` 中注册

```cpp
instanceOop InstanceKlass::allocate_instance(TRAPS) {
  bool has_finalizer_flag = has_finalizer();
  int size = size_helper();
  instanceOop i = (instanceOop)Universe::heap()->obj_allocate(this, size, CHECK_NULL);
  if (has_finalizer_flag && !RegisterFinalizersAtInit) {
    i = register_finalizer(i, CHECK_NULL);
  }
  return i;
}
```

### 2.3 第三步：register_finalizer 调用 Java 方法

> 源码：`src/hotspot/share/oops/instanceKlass.cpp:1225-1238`

```cpp
instanceOop InstanceKlass::register_finalizer(instanceOop i, TRAPS) {
  instanceHandle h_i(THREAD, i);
  JavaValue result(T_VOID);
  JavaCallArguments args(h_i);
  methodHandle mh(THREAD, Universe::finalizer_register_method());
  JavaCalls::call(&result, mh, &args, CHECK_NULL);
  return h_i();
}
```

通过 `JavaCalls::call` 调用 Java 层的 `Finalizer.register(Object)` 方法。`Universe::finalizer_register_method()` 在 JVM 启动时缓存了这个方法引用。

### 2.4 第四步：Java 端 Finalizer.register()

> 源码：`src/java.base/share/classes/java/lang/ref/Finalizer.java:34-67`

```java
final class Finalizer extends FinalReference<Object> {
    private static ReferenceQueue<Object> queue = new ReferenceQueue<>();
    private static Finalizer unfinalized = null;  // 双向链表头
    private Finalizer next, prev;

    // 由 VM 调用
    static void register(Object finalizee) {
        new Finalizer(finalizee);
    }

    private Finalizer(Object finalizee) {
        super(finalizee, queue);           // FinalReference → Reference(referent, queue)
        synchronized (lock) {
            if (unfinalized != null) {
                this.next = unfinalized;
                unfinalized.prev = this;
            }
            unfinalized = this;            // 推入 unfinalized 双向链表
        }
    }
}
```

每个有 `finalize()` 的对象，在分配后都会创建一个 `Finalizer` 对象，形成 `Finalizer → FinalReference → 目标对象` 的引用链。`unfinalized` 双向链表持有所有 Finalizer 的强引用，防止 Finalizer 本身在目标对象被回收前就被 GC 回收。

**开销分析**：每个可终结对象的额外开销：
- 1 个 Finalizer 对象（~40 字节）
- 1 个 FinalReference（Reference 的字段：referent, queue, next, discovered）
- unfinalized 链表的维护（synchronized 块）
- register_finalizer 的 JNI upcall

### 2.5 第五步：GC 发现不可达的 FinalReference

> 源码：`src/hotspot/share/gc/shared/referenceProcessor.cpp:1099-1206`

GC 标记阶段，`ReferenceProcessor::discover_reference()` 发现引用对象：

```cpp
bool ReferenceProcessor::discover_reference(oop obj, ReferenceType rt) {
  if (!_discovering_refs || !RegisterReferences) return false;

  // FinalReference 特殊处理：如果 next != null，说明已非活跃，跳过
  if ((rt == REF_FINAL) && (java_lang_ref_Reference::next(obj) != NULL)) {
    return false;
  }

  // referent 如果已知存活 → 不发现（不需要处理）
  if (is_alive_non_header() != NULL) {
    if (is_alive_non_header()->do_object_b(java_lang_ref_Reference::referent(obj))) {
      return false;
    }
  }

  // SoftReference 提前决策：如果策略说不该清除 → 不发现
  if (rt == REF_SOFT) {
    if (!_current_soft_ref_policy->should_clear_reference(obj, _soft_ref_timestamp_clock)) {
      return false;
    }
  }

  // 添加到对应类型的 discovered list
  DiscoveredList* list = get_discovered_list(rt);
  // 单线程：头插法加入链表
  // 多线程：CAS 头插法
  ...
}
```

### 2.6 第六步：引用处理四阶段

> 源码：`src/hotspot/share/gc/shared/referenceProcessor.cpp:201-260`

GC 暂停阶段调用 `process_discovered_references()`，按顺序处理四个阶段：

```
Phase 1: process_soft_ref_reconsider     — SoftRef 策略重评估
Phase 2: process_soft_weak_final_refs    — Soft/Weak/Final 统一清理
Phase 3: process_final_keep_alive        — FinalRef 特殊处理
Phase 4: process_phantom_refs            — PhantomRef 清理
```

**Phase 1：SoftReference 策略重评估**

> 源码：`referenceProcessor.cpp:341-370`

遍历 SoftRef discovered list，对于 referent 不可达但**策略说不应清除**的引用：
- 从 discovered list 中移除
- 保持 referent 存活（标记为活跃）

这使得被近期访问过的 SoftReference 在内存充足时存活下来。

**Phase 2：Soft/Weak/Final 统一清理**

> 源码：`referenceProcessor.cpp:372-415`

遍历三种类型的 discovered list：

```cpp
while (iter.has_next()) {
    if (iter.referent() == NULL) {
        iter.remove();           // referent 已被清除 → 移除
    } else if (iter.is_referent_alive()) {
        iter.remove();           // referent 存活 → 移除
        iter.make_referent_alive();
    } else {
        if (do_enqueue_and_clear) {   // Soft/Weak: true; Final: false
            iter.clear_referent();    // 清除 referent
            iter.enqueue();           // 入队到 pending list
        }
        iter.next();
    }
}
```

注意 FinalReference 在此阶段 `do_enqueue_and_clear = false`——**不清除 referent**，因为 Finalizer 线程需要通过 `get()` 获取对象来调用 `finalize()`。

**Phase 3：FinalReference 特殊处理**

> 源码：`referenceProcessor.cpp:417-441`

```cpp
while (iter.has_next()) {
    iter.make_referent_alive();   // ① 保持 referent 存活！
    java_lang_ref_Reference::set_next_raw(iter.obj(), iter.obj());  // ② next=this，标记为非活跃
    iter.enqueue();               // ③ 入队到 pending list
    iter.next();
}
complete_gc->do_void();           // ④ 追踪 referent 的传递闭包
```

**这是 finalize() 能"复活"对象的关键**：Phase 3 将 referent 标记为存活，所以目标对象**在这次 GC 中不会被回收**。对象被保留到 Finalizer 线程调用 `finalize()` 之后，下一轮 GC 才有机会真正回收。

**Phase 4：PhantomReference 清理**

> 源码：`referenceProcessor.cpp:443-471`

PhantomReference 是最后处理的：referent 不可达 → 清除 referent + 入队。因为 `PhantomReference.get()` 始终返回 `null`，所以无法复活对象。

### 2.7 第七步：ReferenceHandler 线程分发

> 源码：`src/java.base/share/classes/java/lang/ref/Reference.java:236-270`

GC 将处理后的引用放入 VM 内部的 pending list。ReferenceHandler 线程（优先级 MAX_PRIORITY，守护线程）负责分发：

```java
private static void processPendingReferences() {
    waitForReferencePendingList();                    // native：等待 VM pending list 非空
    Reference<Object> pendingList;
    synchronized (processPendingLock) {
        pendingList = getAndClearReferencePendingList(); // native：原子获取并清除
        processPendingActive = true;
    }
    while (pendingList != null) {
        Reference<Object> ref = pendingList;
        pendingList = ref.discovered;
        ref.discovered = null;

        if (ref instanceof Cleaner) {
            ((Cleaner)ref).clean();                    // Cleaner: 直接执行，不入队
            synchronized (processPendingLock) {
                processPendingLock.notifyAll();         // 通知 nio.Bits 等待者
            }
        } else {
            ReferenceQueue<? super Object> q = ref.queue;
            if (q != ReferenceQueue.NULL) q.enqueue(ref); // 其他引用：入队
        }
    }
    synchronized (processPendingLock) {
        processPendingActive = false;
        processPendingLock.notifyAll();
    }
}
```

**两个关键分支**：
- **`jdk.internal.ref.Cleaner`**：ReferenceHandler 线程直接调用 `clean()`，绕过 ReferenceQueue
- **其他引用（包括 Finalizer）**：调用 `queue.enqueue(ref)` 放入各自的 ReferenceQueue

### 2.8 第八步：FinalizerThread 执行 finalize()

> 源码：`src/java.base/share/classes/java/lang/ref/Finalizer.java:146-177`

```java
private static class FinalizerThread extends Thread {
    public void run() {
        // 等待 VM 初始化完成
        while (VM.initLevel() == 0) {
            VM.awaitInitLevel(1);
        }
        final JavaLangAccess jla = SharedSecrets.getJavaLangAccess();
        running = true;
        for (;;) {
            Finalizer f = (Finalizer)queue.remove();  // 阻塞等待
            f.runFinalizer(jla);
        }
    }
}
```

`runFinalizer()` 的执行流程：

```java
private void runFinalizer(JavaLangAccess jla) {
    synchronized (lock) {
        if (this.next == this) return;   // 已执行过 → 跳过
        // 从 unfinalized 链表中移除
        if (unfinalized == this) unfinalized = this.next;
        else this.prev.next = this.next;
        if (this.next != null) this.next.prev = this.prev;
        this.prev = null;
        this.next = this;                // 标记为已执行
    }

    try {
        Object finalizee = this.get();   // 获取目标对象（FinalReference 不清除 referent！）
        if (finalizee != null && !(finalizee instanceof java.lang.Enum)) {
            jla.invokeFinalize(finalizee);   // 调用 obj.finalize()
            finalizee = null;                // 帮助 GC
        }
    } catch (Throwable x) { }               // 吞掉所有异常！
    super.clear();                           // 清除 referent
}
```

**关键细节**：
1. `Enum` 类跳过终结——因为枚举实例是常量，永远不需要终结
2. 异常被完全吞掉——`finalize()` 中的异常不会影响 JVM
3. `super.clear()` 在调用 `finalize()` 之后——这才真正断开 FinalReference 到目标对象的引用
4. FinalizerThread 优先级 `MAX_PRIORITY - 2 = 8`，低于 ReferenceHandler 的 `MAX_PRIORITY = 10`

### 2.9 Finalizer 机制完整数据流

```
┌──────────────────────────────────────────────────────────────────────┐
│                    Finalizer 完整生命周期                             │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ① 类加载                                                            │
│     classFileParser → has_finalizer 标志 → Klass._access_flags       │
│                                                                      │
│  ② 对象分配                                                          │
│     Object.<init> return → register_finalizer()                      │
│       → JavaCalls → Finalizer.register(obj)                          │
│         → new Finalizer(obj, queue)                                  │
│           → FinalReference(obj, queue) → unfinalized 链表             │
│                                                                      │
│  ③ 对象使用中...                                                     │
│     Finalizer ──FinalRef──→ obj  (strong via unfinalized list)       │
│                                                                      │
│  ④ GC 发现 obj 不可达                                                │
│     ReferenceProcessor::discover_reference()                         │
│       → obj 的 FinalReference 加入 _discoveredFinalRefs              │
│                                                                      │
│  ⑤ GC 引用处理 Phase 3                                               │
│     process_final_keep_alive()                                       │
│       → make_referent_alive(): obj 本轮 GC 不回收!                   │
│       → set next = this: 标记 FinalReference 为非活跃                │
│       → enqueue to VM pending list                                   │
│                                                                      │
│  ⑥ ReferenceHandler 线程                                             │
│     processPendingReferences()                                       │
│       → queue.enqueue(finalizer_ref) → Finalizer.queue               │
│                                                                      │
│  ⑦ FinalizerThread                                                   │
│     queue.remove() → runFinalizer()                                  │
│       → 从 unfinalized 链表移除                                      │
│       → jla.invokeFinalize(obj)  ← 执行 obj.finalize()              │
│       → super.clear()           ← 断开 FinalReference → obj 引用    │
│                                                                      │
│  ⑧ 下一轮 GC                                                        │
│     obj 无任何引用 → 真正回收                                         │
│     (除非 finalize() 中重新建立了强引用 → 复活!)                      │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 3. 四种引用类型

### 3.1 Reference 基类状态机

> 源码：`src/java.base/share/classes/java/lang/ref/Reference.java:44-149`

Reference 对象有**两个独立的属性维度**：

**活跃维度**：
- **Active** — 刚创建，GC 特殊对待。`referent ≠ null`
- **Pending** — GC 已通知，等待 ReferenceHandler 处理。`referent = null`（非 Final）
- **Inactive** — 终态

**注册维度**：
- **Registered** — 关联了 queue，尚未入队。`queue = 用户指定的队列`
- **Enqueued** — 已入队。`queue = ENQUEUED 哨兵`
- **Dequeued** — 已从队列取出。`queue = NULL 哨兵`
- **Unregistered** — 创建时未关联 queue。`queue = NULL 哨兵`

状态转换图：

```
[active/registered] ──GC通知──→ [pending/registered]
        │                              │
        │ clear()                      │ ReferenceHandler
        ↓                              ↓
[inactive/registered]          [inactive/enqueued]
        │                              │
        │ enqueue                      │ poll/remove
        ↓                              ↓
        └───────────────→ [inactive/dequeued] (终态)
```

**关键字段**：

| 字段 | 类型 | 用途 |
|------|------|------|
| `referent` | T | 被引用的目标对象，GC 特殊对待 |
| `queue` | ReferenceQueue | 注册的引用队列 |
| `next` | Reference | 队列链表指针（next=this 表示已处理） |
| `discovered` | Reference | GC discovered list / pending list 的链指针 |

### 3.2 SoftReference

> 源码：`src/java.base/share/classes/java/lang/ref/SoftReference.java:64-118`

SoftReference 在四种引用中最特殊——它有基于时间的清除策略。

```java
public class SoftReference<T> extends Reference<T> {
    static private long clock;        // 由 GC 更新的时钟（毫秒）
    private long timestamp;           // 每次 get() 时更新

    public T get() {
        T o = super.get();
        if (o != null && this.timestamp != clock)
            this.timestamp = clock;   // 更新"最后访问时间"
        return o;
    }
}
```

**SoftReference 清除策略**（C++ 端）：

> 源码：`src/hotspot/share/gc/shared/referencePolicy.cpp`

四种策略：

| 策略类 | 何时使用 | 清除条件 |
|--------|----------|----------|
| `NeverClearPolicy` | — | 永不清除 |
| `AlwaysClearPolicy` | OOM 前 | 始终清除 |
| `LRUCurrentHeapPolicy` | Client 模式 | `空闲堆(MB) × SoftRefLRUPolicyMSPerMB < 未访问时间` |
| `LRUMaxHeapPolicy` | **Server 模式默认** | `(最大堆 - 上次GC已用)(MB) × SoftRefLRUPolicyMSPerMB < 未访问时间` |

**Server 模式计算公式**（LRUMaxHeapPolicy）：

```
_max_interval = (MaxHeapSize - heap_used_at_last_gc) / MB * SoftRefLRUPolicyMSPerMB
```

以标准环境为例（8GB 堆，假设上次 GC 后使用 2GB）：

```
_max_interval = (8192 - 2048) * 1000 = 6,144,000 ms ≈ 102 分钟
```

即：最后一次 `get()` 后超过 102 分钟没被访问的 SoftReference 会被清除。`SoftRefLRUPolicyMSPerMB` 默认 1000。

### 3.3 WeakReference

> 源码：`src/java.base/share/classes/java/lang/ref/WeakReference.java:48-72`

最简单的引用类型，直接继承 Reference，无额外逻辑。

```java
public class WeakReference<T> extends Reference<T> {
    public WeakReference(T referent) {
        super(referent);
    }
    public WeakReference(T referent, ReferenceQueue<? super T> q) {
        super(referent, q);
    }
}
```

WeakReference 的 referent 在**下一次 GC** 时如果不可达就会被清除。典型用途：`WeakHashMap`、监听器注册。

### 3.4 PhantomReference

> 源码：`src/java.base/share/classes/java/lang/ref/PhantomReference.java:50-80`

```java
public class PhantomReference<T> extends Reference<T> {
    public T get() {
        return null;    // 始终返回 null！
    }
    public PhantomReference(T referent, ReferenceQueue<? super T> q) {
        super(referent, q);
    }
}
```

`get()` 始终返回 `null` — 这是设计决策，确保 PhantomReference 无法复活对象。PhantomReference 的唯一用途是**收到通知**（通过 ReferenceQueue），然后执行清理操作（如释放 native 内存）。

### 3.5 FinalReference

> 源码：`src/java.base/share/classes/java/lang/ref/FinalReference.java:31-41`

```java
class FinalReference<T> extends Reference<T> {
    public FinalReference(T referent, ReferenceQueue<? super T> q) {
        super(referent, q);
    }
    @Override
    public boolean enqueue() {
        throw new InternalError("should never reach here");
    }
}
```

**FinalReference 与其他引用的关键区别**：
- GC 处理时**不清除 referent**（Phase 2 中 `do_enqueue_and_clear = false`）
- `enqueue()` 抛异常——只有 GC 内部路径可以入队
- 只在 Phase 3 中入队，此时 referent 被标记为存活

### 3.6 四种引用对比

| 特性 | SoftReference | WeakReference | FinalReference | PhantomReference |
|------|---------------|---------------|----------------|------------------|
| get() | 返回 referent | 返回 referent | 返回 referent | **始终 null** |
| 清除时机 | 内存不足 | 下次 GC | finalize() 后 | 下次 GC |
| GC 清除 referent | Phase 2 | Phase 2 | **Phase 3 后** | Phase 4 |
| referent 可复活 | 否 | 否 | **是** | 否 |
| 用途 | 缓存 | WeakHashMap | finalize() | native 资源清理 |
| 处理线程 | 用户线程 | 用户线程 | FinalizerThread | 用户线程/Cleaner |

---

## 4. ReferenceQueue 实现

> 源码：`src/java.base/share/classes/java/lang/ref/ReferenceQueue.java:39-207`

### 4.1 队列结构

```java
public class ReferenceQueue<T> {
    static final ReferenceQueue<Object> NULL = new Null();      // 哨兵：未注册/已出队
    static final ReferenceQueue<Object> ENQUEUED = new Null();  // 哨兵：已入队

    private final Lock lock = new Lock();
    private volatile Reference<? extends T> head;
    private long queueLength = 0;
}
```

队列是一个简单的单链表（通过 `Reference.next` 链接），以 `head` 为头，末尾节点的 `next` 指向自身。

### 4.2 入队操作

```java
boolean enqueue(Reference<? extends T> r) {
    synchronized (lock) {
        if (r.queue == NULL || r.queue == ENQUEUED) return false;
        
        r.next = (head == null) ? r : head;  // 自环表示链表末尾
        head = r;
        queueLength++;
        r.queue = ENQUEUED;
        
        if (r instanceof FinalReference) {
            VM.addFinalRefCount(1);           // JVM 内部计数
        }
        lock.notifyAll();                     // 唤醒 remove() 等待者
        return true;
    }
}
```

### 4.3 出队操作

```java
public Reference<? extends T> remove(long timeout) throws InterruptedException {
    synchronized (lock) {
        Reference<? extends T> r = reallyPoll();
        if (r != null) return r;
        for (;;) {
            lock.wait(timeout);               // 阻塞等待
            r = reallyPoll();
            if (r != null) return r;
            if (timeout != 0 && elapsed >= timeout) return null;
        }
    }
}
```

---

## 5. GC 引用处理四阶段详解

### 5.1 整体流程

> 源码：`src/hotspot/share/gc/shared/referenceProcessor.cpp:201-260`

```cpp
ReferenceProcessorStats ReferenceProcessor::process_discovered_references(...) {
  disable_discovery();                    // 停止发现新引用

  // Phase 1: 重评估 SoftRef，保留策略允许的
  process_soft_ref_reconsider(...);
  update_soft_ref_master_clock();         // 更新 SoftReference.clock

  // Phase 2: 处理 Soft/Weak/Final — 清除不可达的 referent
  process_soft_weak_final_refs(...);

  // Phase 3: Final 特殊处理 — 保持 referent 存活，入队
  process_final_keep_alive(...);

  // Phase 4: 处理 Phantom — 清除不可达的 referent
  process_phantom_refs(...);
}
```

### 5.2 G1 中的集成点

**Young GC（STW）**：
- 在 `g1CollectedHeap.cpp:4682-4737`，使用 `_ref_processor_stw`
- 在 GC alloc regions 退休**之前**处理，因为可能需要复制 referent 对象

**Concurrent Mark（Remark 阶段）**：
- 在 `g1ConcurrentMark.cpp:1718-1748`，使用 concurrent mark 的 ReferenceProcessor
- 支持多线程并行处理

### 5.3 日志参数

```
-Xlog:gc+ref=debug
```

输出示例：
```
[debug][gc,ref] GC(12) Discovered  reference (0x0000000714890010: java.lang.ref.WeakReference)
[debug][gc,ref] GC(12) Dropped 142 active Refs out of 256 Refs in discovered list
```

```
-Xlog:gc+ref+stats=debug
```

输出示例：
```
[debug][gc,ref,stats] GC(12) SoftReference: 45 discovered, 12 cleared
[debug][gc,ref,stats] GC(12) WeakReference: 256 discovered, 142 cleared  
[debug][gc,ref,stats] GC(12) FinalReference: 8 discovered, 3 enqueued
[debug][gc,ref,stats] GC(12) PhantomReference: 15 discovered, 5 cleared
```

---

## 6. Cleaner 机制：finalize() 的替代

### 6.1 为什么需要 Cleaner？

`finalize()` 有严重的问题：
1. **不确定的执行时间** — FinalizerThread 可能来不及处理
2. **对象复活风险** — `finalize()` 可以把对象重新变成可达
3. **只执行一次** — 复活后第二次不可达时不再调用 `finalize()`
4. **阻塞 FinalizerThread** — 一个慢的 `finalize()` 会拖慢所有终结
5. **额外的分配开销** — 每个可终结对象都需要创建 Finalizer 对象
6. **延迟回收** — 至少需要两轮 GC 才能真正回收

### 6.2 jdk.internal.ref.Cleaner（旧版，NIO 使用）

> 源码：`src/java.base/share/classes/jdk/internal/ref/Cleaner.java:59-155`

```java
public class Cleaner extends PhantomReference<Object> {
    private static final ReferenceQueue<Object> dummyQueue = new ReferenceQueue<>();
    private static Cleaner first = null;    // 双向链表，防止 Cleaner 被 GC
    private final Runnable thunk;           // 清理操作

    public static Cleaner create(Object ob, Runnable thunk) {
        return add(new Cleaner(ob, thunk));
    }

    public void clean() {
        if (!remove(this)) return;   // 幂等：只执行一次
        try {
            thunk.run();
        } catch (final Throwable x) {
            System.exit(1);          // 清理失败 → 直接退出 JVM！
        }
    }
}
```

**Cleaner 与 Finalizer 的关键区别**：

| 特性 | Finalizer | jdk.internal.ref.Cleaner |
|------|-----------|--------------------------|
| 继承 | FinalReference | **PhantomReference** |
| 处理线程 | FinalizerThread（优先级 8） | **ReferenceHandler**（优先级 10） |
| 执行方式 | 入队到 Finalizer.queue → 取出执行 | **直接调用 clean()**，不入队 |
| 异常处理 | 吞掉异常 | **System.exit(1)** |
| 对象复活 | 可能 | **不可能**（PhantomReference.get()=null） |
| 创建开销 | JNI upcall | 纯 Java 对象创建 |
| 典型用户 | 用户 finalize() | **NIO DirectByteBuffer** |

**NIO 使用 Cleaner 的典型场景**：

```java
// DirectByteBuffer 构造函数中
cleaner = Cleaner.create(this, new Deallocator(base, size, cap));
// 当 DirectByteBuffer 被回收时，Deallocator.run() 释放 native 内存
```

### 6.3 java.lang.ref.Cleaner（Java 9+ 新 API）

> 源码：`src/java.base/share/classes/java/lang/ref/Cleaner.java:131-237`

Java 9 引入的公开 API，比 `jdk.internal.ref.Cleaner` 更安全：

```java
public final class Cleaner {
    final CleanerImpl impl;

    public static Cleaner create() {
        Cleaner cleaner = new Cleaner();
        cleaner.impl.start(cleaner, null);  // 启动独立守护线程
        return cleaner;
    }

    public Cleanable register(Object obj, Runnable action) {
        return new CleanerImpl.PhantomCleanableRef(obj, this, action);
    }
}
```

**与旧版 Cleaner 的区别**：
- 每个 `java.lang.ref.Cleaner` 实例有**独立的守护线程和 ReferenceQueue**
- 不在 ReferenceHandler 线程中执行，避免阻塞引用处理
- 公开 API，用户可直接使用
- 支持 Phantom/Weak/Soft 三种类型的 Cleanable

---

## 7. 对象回收的性能影响

### 7.1 Finalizer 的开销量化

| 开销来源 | 估计值 |
|----------|--------|
| 每个可终结对象额外内存 | ~48 字节（Finalizer + FinalReference） |
| register_finalizer 调用 | ~1-2μs（JNI upcall + synchronized） |
| GC 引用处理（per reference） | ~100ns-1μs |
| 延迟回收（至少多一轮 GC） | 延迟 = GC 周期 |
| FinalizerThread 执行 finalize() | 取决于用户代码 |

### 7.2 最佳实践

1. **避免使用 `finalize()`** — 已在 JDK 9 标记 `@Deprecated`，JDK 18 标记 `@Deprecated(forRemoval=true)`
2. **使用 `java.lang.ref.Cleaner`** — 更安全、更可预测
3. **优先 try-with-resources** — 对于 `AutoCloseable` 资源
4. **SoftReference 缓存注意 OOM** — 大量 SoftReference 可能导致 Full GC 频繁

---

## 8. GDB 验证指南

### 8.1 观察引用处理

```gdb
# 断点在引用处理入口
break ReferenceProcessor::process_discovered_references
commands
  silent
  printf "=== Reference Processing ===\n"
  printf "Soft:    %d discovered\n", total_count(_discoveredSoftRefs)
  printf "Weak:    %d discovered\n", total_count(_discoveredWeakRefs)
  printf "Final:   %d discovered\n", total_count(_discoveredFinalRefs)
  printf "Phantom: %d discovered\n", total_count(_discoveredPhantomRefs)
  continue
end
```

### 8.2 观察 Finalizer 注册

```gdb
# 断点在 register_finalizer
break InstanceKlass::register_finalizer
commands
  silent
  printf "register_finalizer: obj=%p, klass=%s\n", i, i->klass()->external_name()
  continue
end
```

### 8.3 观察引用发现

```gdb
break ReferenceProcessor::discover_reference
commands
  silent
  printf "discover_reference: type=%d, obj=%p\n", rt, obj
  continue
end
```

---

## 9. JVM 参数速查

| 参数 | 默认值 | 用途 |
|------|--------|------|
| `-XX:SoftRefLRUPolicyMSPerMB=N` | 1000 | 每 MB 空闲堆允许 SoftRef 存活 N 毫秒 |
| `-XX:+ParallelRefProcEnabled` | false | 并行引用处理 |
| `-XX:+PrintReferenceGC` | false | 打印引用处理统计（JDK 8） |
| `-Xlog:gc+ref=debug` | — | 引用发现/清除日志 |
| `-Xlog:gc+ref+stats=debug` | — | 引用处理统计 |
| `-XX:+TraceFinalizerRegistration` | false | 跟踪 Finalizer 注册 |
| `-XX:+RegisterFinalizersAtInit` | true | 在 Object.<init> 返回时注册 |

---

## 10. 面试高频问题

**Q: finalize() 为什么被废弃？有什么替代方案？**

A: finalize() 有五大问题：①不确定执行时间 ②对象可复活 ③只执行一次 ④阻塞 FinalizerThread ⑤延迟回收（至少两轮 GC）。替代方案是 `java.lang.ref.Cleaner`（Java 9+），它基于 PhantomReference，不能复活对象，有独立的清理线程，更安全可控。对于资源管理，优先使用 try-with-resources + AutoCloseable。

**Q: 四种引用类型的区别和使用场景？**

A: 
- **SoftReference**：内存不足时清除，适合缓存。清除公式依赖空闲堆大小和最后访问时间
- **WeakReference**：下次 GC 即清除，适合 WeakHashMap、监听器等不想阻止 GC 的场景
- **PhantomReference**：get() 返回 null，只能收通知。适合跟踪对象回收、释放 native 资源
- **FinalReference**：JVM 内部使用，支撑 finalize() 机制。GC 时不清除 referent，允许复活

**Q: 一个有 finalize() 的对象至少需要几次 GC 才能被回收？**

A: 至少两次。第一次 GC 发现不可达时，Phase 3 保持 referent 存活并入队到 pending list → ReferenceHandler → Finalizer.queue → FinalizerThread 执行 finalize() → clear()。第二次 GC 发现无任何引用后才真正回收。如果 finalize() 中重新建立了强引用，对象"复活"，可能永远不会被回收（finalize() 只调用一次）。

**Q: ReferenceHandler 线程和 FinalizerThread 分别做什么？**

A: **ReferenceHandler**（优先级 10）：从 VM pending list 取出引用，如果是 Cleaner 直接执行 clean()，否则 enqueue 到对应的 ReferenceQueue。**FinalizerThread**（优先级 8）：从 Finalizer 专用的 queue 中取出 Finalizer 引用，执行 runFinalizer() → 调用目标对象的 finalize() 方法。

**Q: SoftReference 的清除策略是什么？**

A: Server 模式默认 `LRUMaxHeapPolicy`：`_max_interval = (MaxHeap - 上次GC已用) / MB × SoftRefLRUPolicyMSPerMB`。如果 SoftReference 的最后访问时间到现在超过 `_max_interval`，则清除。8GB 堆使用 2GB 时，默认约 102 分钟内未被 get() 访问的 SoftRef 会被清除。可通过 `-XX:SoftRefLRUPolicyMSPerMB` 调整（0 = 立即清除，用于避免 SoftRef 导致的 Full GC）。
