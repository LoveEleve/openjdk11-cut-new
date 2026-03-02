# ReferenceProcessor 引用处理器详解

> 📌 **面试重要程度**：⭐⭐⭐⭐⭐（极高频）
> 📁 源码位置：`src/hotspot/share/gc/shared/referenceProcessor.cpp`
> 🎯 核心考点：四种引用类型、软引用清理策略、GC 处理流程

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文梳理 **ReferenceProcessor 引用处理器详解** 的完整执行流程：从触发条件到最终结果，展示每个阶段的核心操作和数据流转。

### 0.2 为什么需要？

复杂系统的行为往往难以从单个函数理解，需要从整体流程视角才能看清各组件的协作关系。

### 0.3 怎么解决？

以时序图/流程图展示整体流程，然后逐阶段深入分析：每个阶段解决什么问题、涉及哪些数据结构、关键代码在哪里。

### 0.4 为什么这样设计？

流程设计的核心权衡是「正确性 vs 性能」：某些看似冗余的步骤（如多次检查、屏障指令）是为了保证并发安全；某些看似复杂的路径是为了优化常见情况。

---


## 1. 概述：为什么需要 ReferenceProcessor？

### 1.1 一句话总结

**ReferenceProcessor 是 JVM 中负责处理软引用/弱引用/虚引用/Finalizer 的核心组件**，它决定了这些引用对象何时被清理、referent 何时变为 null、以及何时被加入 ReferenceQueue。

### 1.2 面试必知的四种引用类型

```java
// Java 中的四种引用类型
java.lang.ref.SoftReference<T>      // 软引用：内存不足时清理
java.lang.ref.WeakReference<T>      // 弱引用：GC 时清理
java.lang.ref.PhantomReference<T>   // 虚引用：对象回收后通知
java.lang.ref.FinalReference<T>     // Finalizer引用：支持 finalize() 方法（内部类）
```

### 1.3 引用强度对比（面试高频）

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      引用强度金字塔                                      │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│        强引用 (Strong)                                                  │
│       ▲  │  Object obj = new Object();                                 │
│       │  │  • 永不回收（除非 obj = null）                                │
│       │  │                                                              │
│   强  │  ▼                                                              │
│   度  │  软引用 (Soft)                                                   │
│       │  │  SoftReference<Object> sr = new SoftReference<>(obj);       │
│       │  │  • 内存不足时回收                                             │
│       │  │  • 适合做缓存                                                 │
│       │  │                                                              │
│       │  ▼                                                              │
│       │  弱引用 (Weak)                                                   │
│       │  │  WeakReference<Object> wr = new WeakReference<>(obj);       │
│       │  │  • 下次 GC 时回收                                             │
│       │  │  • WeakHashMap 使用此特性                                     │
│       │  │                                                              │
│       │  ▼                                                              │
│       │  虚引用 (Phantom)                                                │
│       ▼  │  PhantomReference<Object> pr = new PhantomReference<>(...); │
│          │  • 对象回收后收到通知                                         │
│          │  • get() 永远返回 null                                        │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.4 在启动流程中的位置

```
init_globals()
├── universe_init()             ← 创建堆
├── gc_init()                   ← 初始化 GC
├── referenceProcessor_init()   ← 【当前分析】初始化引用处理策略
├── jni_init()
└── ...
```

---

## 2. referenceProcessor_init() 源码解读

### 2.1 入口函数

```cpp
// src/hotspot/share/gc/shared/referenceProcessor.cpp:46
void referenceProcessor_init() {
  ReferenceProcessor::init_statics();
}
```

### 2.2 init_statics() 核心实现

```cpp
// src/hotspot/share/gc/shared/referenceProcessor.cpp:49
void ReferenceProcessor::init_statics() {
  // 1. 初始化软引用时间戳时钟（单调递增）
  jlong now = os::javaTimeNanos() / NANOSECS_PER_MILLISEC;
  _soft_ref_timestamp_clock = now;
  
  // 2. 同步到 Java 层的 SoftReference.clock 字段
  java_lang_ref_SoftReference::set_clock(_soft_ref_timestamp_clock);

  // 3. 创建软引用清理策略
  _always_clear_soft_ref_policy = new AlwaysClearPolicy();  // OOM 时使用
  
  if (is_server_compilation_mode_vm()) {
    // Server 模式：基于最大堆计算
    _default_soft_ref_policy = new LRUMaxHeapPolicy();
  } else {
    // Client 模式：基于当前堆计算
    _default_soft_ref_policy = new LRUCurrentHeapPolicy();
  }
  
  // 4. 验证引用发现策略
  guarantee(RefDiscoveryPolicy == ReferenceBasedDiscovery ||
            RefDiscoveryPolicy == ReferentBasedDiscovery,
            "Unrecognized RefDiscoveryPolicy");
}
```

### 2.3 初始化内容总结

| 组件 | 初始化内容 | 说明 |
|------|-----------|------|
| `_soft_ref_timestamp_clock` | 当前时间戳 | 用于计算软引用生存时间 |
| `_always_clear_soft_ref_policy` | AlwaysClearPolicy | OOM 时强制清理所有软引用 |
| `_default_soft_ref_policy` | LRUMaxHeap/LRUCurrentHeap | 正常 GC 时的清理策略 |

---

## 3. Java 引用对象内存布局（面试高频）

### 3.1 java.lang.ref.Reference 字段布局

```cpp
// 源码：src/hotspot/share/classfile/javaClasses.hpp
class java_lang_ref_Reference : AllStatic {
  // 字段偏移量
  static int referent_offset;    // 指向被引用对象
  static int queue_offset;       // 指向关联的 ReferenceQueue
  static int next_offset;        // 队列中的下一个引用
  static int discovered_offset;  // GC 发现链表的下一个
};
```

### 3.2 Reference 对象内存布局图

```
Reference 对象内存布局（64位压缩指针）：
┌────────────────────────────────────────────────────────────────────┐
│  Mark Word (8 bytes)                                               │
├────────────────────────────────────────────────────────────────────┤
│  Klass Pointer (4 bytes compressed)                                │
├────────────────────────────────────────────────────────────────────┤
│  referent (4 bytes)    ← 指向被引用的对象                           │
│                          T get() 返回的就是这个                     │
├────────────────────────────────────────────────────────────────────┤
│  queue (4 bytes)       ← 关联的 ReferenceQueue                     │
│                          构造时传入                                 │
├────────────────────────────────────────────────────────────────────┤
│  next (4 bytes)        ← 已入队时，指向队列中的下一个               │
│                          未入队时为 null 或 this                    │
├────────────────────────────────────────────────────────────────────┤
│  discovered (4 bytes)  ← GC 内部使用的发现链表                      │
│                          仅在 GC 期间有效                           │
└────────────────────────────────────────────────────────────────────┘

SoftReference 额外字段：
├────────────────────────────────────────────────────────────────────┤
│  timestamp (8 bytes)   ← 上次访问时间（用于 LRU 策略）              │
│                          每次 get() 时更新                          │
├────────────────────────────────────────────────────────────────────┤
│  static clock (8 bytes)← 全局时钟（每次 GC 时更新）                 │
└────────────────────────────────────────────────────────────────────┘
```

### 3.3 C++ 中访问 Reference 字段

```cpp
// 获取 referent（被引用对象）
oop java_lang_ref_Reference::referent(oop ref) {
  return ref->obj_field_access<ON_WEAK_OOP_REF | AS_NO_KEEPALIVE>(referent_offset);
}

// 获取 referent 地址（用于清空）
HeapWord* java_lang_ref_Reference::referent_addr_raw(oop ref) {
  return ref->field_addr(referent_offset);
}

// 设置 discovered 字段
void java_lang_ref_Reference::set_discovered_raw(oop ref, oop value) {
  ref->obj_field_put_raw(discovered_offset, value);
}
```

---

## 4. 软引用清理策略详解（面试超高频）

### 4.1 两种 LRU 策略

```cpp
// 策略1：LRUCurrentHeapPolicy（Client 模式）
// 基于【当前】可用堆空间计算
void LRUCurrentHeapPolicy::setup() {
  // 公式：max_interval = 当前空闲堆(MB) × SoftRefLRUPolicyMSPerMB
  _max_interval = (Universe::get_heap_free_at_last_gc() / M) * SoftRefLRUPolicyMSPerMB;
}

// 策略2：LRUMaxHeapPolicy（Server 模式）
// 基于【最大】可用堆空间计算
void LRUMaxHeapPolicy::setup() {
  size_t max_heap = MaxHeapSize;
  max_heap -= Universe::get_heap_used_at_last_gc();  // 减去已用
  max_heap /= M;
  // 公式：max_interval = 剩余最大堆(MB) × SoftRefLRUPolicyMSPerMB
  _max_interval = max_heap * SoftRefLRUPolicyMSPerMB;
}
```

### 4.2 软引用清理判断逻辑

```cpp
// 决定是否清理某个软引用
bool LRUMaxHeapPolicy::should_clear_reference(oop p, jlong timestamp_clock) {
  // interval = 当前时钟 - 软引用上次访问时间
  jlong interval = timestamp_clock - java_lang_ref_SoftReference::timestamp(p);
  
  // 如果 interval <= max_interval，保留该软引用
  // 否则清理
  if (interval <= _max_interval) {
    return false;  // 保留：最近访问过
  }
  return true;     // 清理：很久没访问了
}
```

### 4.3 SoftRefLRUPolicyMSPerMB 参数详解（面试必问）

```
JVM 参数：-XX:SoftRefLRUPolicyMSPerMB=<ms>
默认值：1000（即 1 秒/MB）

含义：每 MB 空闲堆空间，允许软引用多存活 ms 毫秒

示例计算：
┌─────────────────────────────────────────────────────────────────────────┐
│  假设：                                                                 │
│    MaxHeapSize = 1024 MB                                                │
│    已用堆 = 512 MB                                                       │
│    SoftRefLRUPolicyMSPerMB = 1000                                       │
│                                                                         │
│  计算（Server 模式）：                                                   │
│    剩余堆 = 1024 - 512 = 512 MB                                         │
│    max_interval = 512 × 1000 = 512,000 ms = 512 秒 ≈ 8.5 分钟            │
│                                                                         │
│  结论：                                                                  │
│    如果一个软引用在过去 8.5 分钟内没有被访问过（get()），                │
│    下次 GC 时它就会被清理。                                              │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.4 面试题：如何调优软引用？

```
问题：系统频繁 Full GC，怀疑是软引用过多，如何调优？

答案：
┌─────────────────────────────────────────────────────────────────────────┐
│  方案 1：降低 SoftRefLRUPolicyMSPerMB（更激进地清理）                    │
│    -XX:SoftRefLRUPolicyMSPerMB=500   // 默认 1000，改为 500              │
│                                                                         │
│  方案 2：增加堆空间                                                      │
│    -Xmx2g → -Xmx4g                                                      │
│                                                                         │
│  方案 3：完全禁用软引用缓存（应用层改造）                                │
│    将 SoftReference 改为 WeakReference                                  │
│                                                                         │
│  方案 4：监控软引用数量                                                  │
│    jcmd <pid> GC.class_histogram | grep SoftReference                   │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 5. GC 引用处理四阶段流程（核心）

### 5.1 处理流程总览

```cpp
ReferenceProcessorStats ReferenceProcessor::process_discovered_references(...) {
  // 禁用引用发现（此时开始处理）
  disable_discovery();
  
  // 更新软引用时钟
  _soft_ref_timestamp_clock = java_lang_ref_SoftReference::clock();

  // Phase 1: 软引用策略筛选
  process_soft_ref_reconsider(...);
  update_soft_ref_master_clock();

  // Phase 2: 处理 Soft/Weak/Final 引用
  process_soft_weak_final_refs(...);

  // Phase 3: Final 引用特殊处理（保持 referent 可达）
  process_final_keep_alive(...);

  // Phase 4: 处理 Phantom 引用
  process_phantom_refs(...);

  return stats;
}
```

### 5.2 四阶段流程图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      引用处理四阶段流程                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  GC 标记阶段完成后                                                       │
│        │                                                                │
│        ▼                                                                │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ Phase 1: process_soft_ref_reconsider()                           │  │
│  │  • 仅处理 SoftReference                                          │  │
│  │  • 根据 LRU 策略决定哪些软引用应该保留                            │  │
│  │  • 最近访问的软引用 → 移出发现队列，标记 referent 可达            │  │
│  │  • 很久未访问的软引用 → 保留在发现队列，准备清理                  │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│        │                                                                │
│        ▼                                                                │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ Phase 2: process_soft_weak_final_refs()                          │  │
│  │  • 处理 SoftRef/WeakRef/FinalRef                                 │  │
│  │  • 如果 referent 仍可达 → 移出发现队列                           │  │
│  │  • 如果 referent 不可达：                                        │  │
│  │    - Soft/Weak: 清空 referent，加入 pending 队列                 │  │
│  │    - Final: 保留在队列（Phase 3 处理）                           │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│        │                                                                │
│        ▼                                                                │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ Phase 3: process_final_keep_alive()                              │  │
│  │  • 仅处理 FinalReference                                         │  │
│  │  • 重要：保持 referent 可达！（因为要执行 finalize()）           │  │
│  │  • 设置 next = this（标记为非活跃）                              │  │
│  │  • 加入 pending 队列（等待 Finalizer 线程处理）                  │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│        │                                                                │
│        ▼                                                                │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ Phase 4: process_phantom_refs()                                  │  │
│  │  • 处理 PhantomReference                                         │  │
│  │  • 如果 referent 可达 → 移出发现队列                             │  │
│  │  • 如果 referent 不可达：                                        │  │
│  │    - 清空 referent                                               │  │
│  │    - 加入 pending 队列                                           │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│        │                                                                │
│        ▼                                                                │
│  处理完成，等待 ReferenceHandler 线程将 pending 引用入队               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 5.3 各阶段处理逻辑代码

```cpp
// Phase 2: 处理 Soft/Weak/Final 引用
size_t ReferenceProcessor::process_soft_weak_final_refs_work(
    DiscoveredList& refs_list,
    BoolObjectClosure* is_alive,
    OopClosure* keep_alive,
    bool do_enqueue_and_clear) {
    
  DiscoveredListIterator iter(refs_list, keep_alive, is_alive);
  
  while (iter.has_next()) {
    iter.load_ptrs();
    
    if (iter.referent() == NULL) {
      // referent 已被清空（并发 GC 可能发生）
      log_dropped_ref(iter, "cleared");
      iter.remove();
      iter.move_to_next();
      
    } else if (iter.is_referent_alive()) {
      // referent 仍然可达
      log_dropped_ref(iter, "reachable");
      iter.remove();
      iter.make_referent_alive();  // 标记 referent 存活
      iter.move_to_next();
      
    } else {
      // referent 不可达
      if (do_enqueue_and_clear) {
        iter.clear_referent();     // 清空 referent → null
        iter.enqueue();            // 加入 pending 队列
        log_enqueued_ref(iter, "cleared");
      }
      iter.next();
    }
  }
  
  if (do_enqueue_and_clear) {
    iter.complete_enqueue();
    refs_list.clear();
  }
  
  return iter.removed();
}
```

---

## 6. Pending 队列与 ReferenceHandler 线程

### 6.1 引用入队流程

```
GC 线程处理完成后
      │
      ▼
将引用加入 Universe::_reference_pending_list（全局 pending 队列）
      │
      ▼
通知 ReferenceHandler 线程
      │
      ▼
ReferenceHandler 线程将引用移入用户指定的 ReferenceQueue
      │
      ▼
用户代码通过 queue.poll()/remove() 获取引用
```

### 6.2 Java 层 ReferenceHandler 线程

```java
// java.lang.ref.Reference.ReferenceHandler
private static class ReferenceHandler extends Thread {
    public void run() {
        while (true) {
            tryHandlePending(true);  // 处理 pending 队列
        }
    }
    
    static boolean tryHandlePending(boolean waitForNotify) {
        Reference<Object> r;
        Cleaner c;
        
        synchronized (lock) {
            if (pending != null) {
                r = pending;
                c = r instanceof Cleaner ? (Cleaner) r : null;
                pending = r.discovered;  // 取下一个
                r.discovered = null;
            } else {
                if (waitForNotify) {
                    lock.wait();  // 等待 GC 通知
                }
                return waitForNotify;
            }
        }
        
        // 处理 Cleaner
        if (c != null) {
            c.clean();  // 执行清理逻辑
            return true;
        }
        
        // 加入 ReferenceQueue
        ReferenceQueue<? super Object> q = r.queue;
        if (q != ReferenceQueue.NULL) {
            q.enqueue(r);  // 入队
        }
        return true;
    }
}
```

### 6.3 complete_enqueue() 与 pending_list

```cpp
// 将处理完的引用加入全局 pending 队列
void DiscoveredListIterator::complete_enqueue() {
  if (_prev_discovered != NULL) {
    // 这是链表最后一个元素
    // 将整个链表 swap 到 Universe::_reference_pending_list
    oop old = Universe::swap_reference_pending_list(_refs_list.head());
    
    // 最后一个元素的 discovered 指向原来的 pending 头
    HeapAccess<AS_NO_KEEPALIVE>::oop_store_at(
        _prev_discovered, 
        java_lang_ref_Reference::discovered_offset, 
        old);
  }
}
```

---

## 7. FinalReference 与 Finalizer 线程（面试高频）

### 7.1 finalize() 方法的问题

```java
// 为什么不推荐使用 finalize()？
class BadExample {
    @Override
    protected void finalize() throws Throwable {
        // 问题1：执行时机不确定
        // 问题2：可能导致对象复活
        // 问题3：延长对象生命周期（至少两次 GC）
        // 问题4：单线程执行，可能成为瓶颈
        // 问题5：异常被忽略
    }
}
```

### 7.2 FinalReference 处理流程

```
对象有 finalize() 方法
      │
      ▼
JVM 自动创建 FinalReference 包装
      │
      ▼
GC 发现对象不可达
      │
      ▼
Phase 3: process_final_keep_alive()
      │
      ├── 保持 referent 可达（复活！）
      ├── 设置 next = this
      └── 加入 pending 队列
      │
      ▼
ReferenceHandler 线程处理，加入 Finalizer 队列
      │
      ▼
FinalizerThread 线程执行 finalize()
      │
      ▼
下次 GC 时，对象才真正被回收
```

### 7.3 Phase 3 代码详解

```cpp
// 保持 FinalReference 的 referent 存活
size_t ReferenceProcessor::process_final_keep_alive_work(
    DiscoveredList& refs_list,
    OopClosure* keep_alive,
    VoidClosure* complete_gc) {
    
  DiscoveredListIterator iter(refs_list, keep_alive, NULL);
  
  while (iter.has_next()) {
    iter.load_ptrs();
    
    // 关键：保持 referent 存活！
    // 因为需要执行 finalize() 方法
    iter.make_referent_alive();

    // 设置 next = this，标记为非活跃
    // 防止重复入队
    assert(java_lang_ref_Reference::next(iter.obj()) == NULL, "enqueued FinalReference");
    java_lang_ref_Reference::set_next_raw(iter.obj(), iter.obj());  // next = this

    iter.enqueue();
    log_enqueued_ref(iter, "Final");
    iter.next();
  }
  
  iter.complete_enqueue();
  complete_gc->do_void();
  refs_list.clear();

  return iter.removed();
}
```

### 7.4 面试题：finalize() 对象至少需要几次 GC 才能回收？

```
答案：至少 2 次 GC

第 1 次 GC：
┌─────────────────────────────────────────────────────────────────────────┐
│  1. 发现对象不可达                                                       │
│  2. 发现对象有 FinalReference                                           │
│  3. Phase 3 保持 referent 存活（"复活"）                                 │
│  4. 加入 Finalizer 队列                                                 │
│  5. 对象此时不会被回收！                                                 │
└─────────────────────────────────────────────────────────────────────────┘

Finalizer 线程：
┌─────────────────────────────────────────────────────────────────────────┐
│  1. 从队列取出 FinalReference                                           │
│  2. 调用 finalize() 方法                                                │
│  3. 清除 FinalReference                                                 │
└─────────────────────────────────────────────────────────────────────────┘

第 2 次 GC：
┌─────────────────────────────────────────────────────────────────────────┐
│  1. 对象真正变为不可达                                                   │
│  2. 没有 FinalReference 了                                              │
│  3. 对象可以被正常回收                                                   │
└─────────────────────────────────────────────────────────────────────────┘

特殊情况（对象在 finalize() 中复活）：可能永远不被回收！
```

---

## 8. PhantomReference 详解

### 8.1 虚引用特点

```java
// PhantomReference 的特点
PhantomReference<Object> pr = new PhantomReference<>(obj, queue);

// 1. get() 永远返回 null
pr.get();  // 返回 null

// 2. 必须关联 ReferenceQueue
new PhantomReference<>(obj, null);  // 不推荐，没有意义

// 3. 在 referent 被回收后才会入队
// 4. 入队后 referent 已经被清空

// 典型用途：资源清理
class DirectByteBuffer {
    private Cleaner cleaner;  // 内部使用 PhantomReference 机制
    
    DirectByteBuffer(int cap) {
        cleaner = Cleaner.create(this, new Deallocator(...));
    }
}
```

### 8.2 Phase 4 处理代码

```cpp
// 处理 PhantomReference
size_t ReferenceProcessor::process_phantom_refs_work(
    DiscoveredList& refs_list,
    BoolObjectClosure* is_alive,
    OopClosure* keep_alive,
    VoidClosure* complete_gc) {
    
  DiscoveredListIterator iter(refs_list, keep_alive, is_alive);
  
  while (iter.has_next()) {
    iter.load_ptrs();

    oop const referent = iter.referent();

    if (referent == NULL || iter.is_referent_alive()) {
      // referent 已清空或仍存活
      iter.make_referent_alive();
      iter.remove();
      iter.move_to_next();
    } else {
      // referent 不可达
      iter.clear_referent();  // 清空 referent
      iter.enqueue();         // 入队通知
      log_enqueued_ref(iter, "cleared Phantom");
      iter.next();
    }
  }
  
  iter.complete_enqueue();
  complete_gc->do_void();
  refs_list.clear();

  return iter.removed();
}
```

### 8.3 Cleaner 机制（DirectByteBuffer 释放堆外内存）

```java
// java.lang.ref.Cleaner 内部实现
public class Cleaner extends PhantomReference<Object> {
    private final Runnable thunk;  // 清理逻辑
    
    private Cleaner(Object referent, Runnable thunk) {
        super(referent, dummyQueue);
        this.thunk = thunk;
    }
    
    public void clean() {
        if (remove(this)) {
            thunk.run();  // 执行清理（如释放堆外内存）
        }
    }
}

// DirectByteBuffer 使用示例
class DirectByteBuffer {
    DirectByteBuffer(int cap) {
        long base = unsafe.allocateMemory(cap);  // 分配堆外内存
        cleaner = Cleaner.create(this, new Deallocator(base, cap));
    }
    
    private static class Deallocator implements Runnable {
        private long address;
        public void run() {
            unsafe.freeMemory(address);  // 释放堆外内存
        }
    }
}
```

---

## 9. ReferenceProcessor 类结构

### 9.1 核心数据结构

```cpp
class ReferenceProcessor : public ReferenceDiscoverer {
private:
  // 软引用时间戳时钟
  static jlong _soft_ref_timestamp_clock;
  
  // 软引用清理策略
  static ReferencePolicy* _default_soft_ref_policy;      // 默认策略
  static ReferencePolicy* _always_clear_soft_ref_policy; // OOM 时策略
  ReferencePolicy* _current_soft_ref_policy;             // 当前策略
  
  // 发现的引用队列（每种类型 × 每个 GC 线程）
  uint _max_num_queues;          // 最大队列数（= GC 线程数）
  DiscoveredList* _discovered_refs;         // 主数组
  DiscoveredList* _discoveredSoftRefs;      // 软引用队列
  DiscoveredList* _discoveredWeakRefs;      // 弱引用队列
  DiscoveredList* _discoveredFinalRefs;     // Final引用队列
  DiscoveredList* _discoveredPhantomRefs;   // 虚引用队列
  
  // 处理状态
  bool _discovering_refs;        // 是否正在发现引用
  bool _processing_is_mt;        // 是否多线程处理
  bool _discovery_is_mt;         // 是否多线程发现
};
```

### 9.2 DiscoveredList 队列结构

```cpp
class DiscoveredList {
  oop       _oop_head;          // 链表头（非压缩指针）
  narrowOop _compressed_head;   // 链表头（压缩指针）
  size_t    _len;               // 队列长度
  
public:
  oop head() const;             // 获取头节点
  void set_head(oop o);         // 设置头节点
  bool is_empty() const;        // 是否为空
  size_t length();              // 队列长度
};
```

### 9.3 内存布局

```
ReferenceProcessor 发现队列布局：

假设 4 个 GC 线程（_max_num_queues = 4）

_discovered_refs 数组：
┌───────────────────────────────────────────────────────────────────────┐
│  Soft[0]  │  Soft[1]  │  Soft[2]  │  Soft[3]   ← _discoveredSoftRefs │
├───────────────────────────────────────────────────────────────────────┤
│  Weak[0]  │  Weak[1]  │  Weak[2]  │  Weak[3]   ← _discoveredWeakRefs │
├───────────────────────────────────────────────────────────────────────┤
│  Final[0] │  Final[1] │  Final[2] │  Final[3]  ← _discoveredFinalRefs│
├───────────────────────────────────────────────────────────────────────┤
│  Phantom[0]│ Phantom[1]│ Phantom[2]│ Phantom[3] ← _discoveredPhantomRefs│
└───────────────────────────────────────────────────────────────────────┘

每个队列是一个链表：
  DiscoveredList.head → ref1 → ref2 → ref3 → ... → refN → refN(self-loop)
  
  通过 discovered 字段链接：
  ref1.discovered → ref2
  ref2.discovered → ref3
  refN.discovered → refN (结尾标记)
```

---

## 10. 引用发现过程

### 10.1 discover_reference() 方法

```cpp
// 发现一个引用对象（在 GC 标记阶段调用）
bool ReferenceProcessor::discover_reference(oop obj, ReferenceType rt) {
  // 1. 检查是否启用引用发现
  if (!_discovering_refs || !RegisterReferences) {
    return false;
  }

  // 2. FinalReference 特殊检查
  if ((rt == REF_FINAL) && (java_lang_ref_Reference::next(obj) != NULL)) {
    return false;  // 非活跃的 FinalReference，不重复发现
  }

  // 3. 检查引用发现策略
  if (RefDiscoveryPolicy == ReferenceBasedDiscovery &&
      !is_subject_to_discovery(obj)) {
    return false;  // 不在收集范围内
  }

  // 4. 检查 referent 是否可达
  if (is_alive_non_header() != NULL) {
    if (is_alive_non_header()->do_object_b(java_lang_ref_Reference::referent(obj))) {
      return false;  // referent 可达，无需发现
    }
  }
  
  // 5. 软引用策略检查
  if (rt == REF_SOFT) {
    if (!_current_soft_ref_policy->should_clear_reference(obj, _soft_ref_timestamp_clock)) {
      return false;  // 策略说不清理
    }
  }

  // 6. 检查是否已被发现
  const oop discovered = java_lang_ref_Reference::discovered(obj);
  if (discovered != NULL) {
    return false;  // 已被发现
  }

  // 7. 加入对应类型的发现队列
  DiscoveredList* list = get_discovered_list(rt);
  if (_discovery_is_mt) {
    add_to_discovered_list_mt(*list, obj, discovered_addr);  // 多线程安全
  } else {
    // 单线程：直接链表头插入
    oop current_head = list->head();
    oop next_discovered = (current_head != NULL) ? current_head : obj;
    RawAccess<>::oop_store(discovered_addr, next_discovered);
    list->set_head(obj);
    list->inc_length(1);
  }
  
  return true;
}
```

### 10.2 多线程发现（CAS）

```cpp
// 多线程安全地加入发现队列
inline void ReferenceProcessor::add_to_discovered_list_mt(
    DiscoveredList& refs_list,
    oop obj,
    HeapWord* discovered_addr) {
    
  oop current_head = refs_list.head();
  oop next_discovered = (current_head != NULL) ? current_head : obj;

  // CAS 设置 discovered 字段
  oop retest = HeapAccess<AS_NO_KEEPALIVE>::oop_atomic_cmpxchg(
      next_discovered, 
      discovered_addr, 
      oop(NULL));

  if (retest == NULL) {
    // CAS 成功，当前线程赢得入队权
    refs_list.set_head(obj);
    refs_list.inc_length(1);
  } else {
    // CAS 失败，其他线程已经发现了该引用
  }
}
```

---

## 11. GDB 验证

### 11.1 GDB 验证脚本

```gdb
# jvm-md/ReferenceProcessor/gdb_referenceProcessor_init.txt

set pagination off
set print pretty on

b ReferenceProcessor::init_statics
run -Xms256m -Xmx256m -XX:+UseG1GC -XX:SoftRefLRUPolicyMSPerMB=1000 -cp /data/workspace/demo/src com.wjcoder.Main

finish

printf "\n========== Soft Ref Timestamp Clock ==========\n"
printf "_soft_ref_timestamp_clock: %ld ms\n", ReferenceProcessor::_soft_ref_timestamp_clock

printf "\n========== Reference Policies ==========\n"
printf "_always_clear_soft_ref_policy: %p\n", ReferenceProcessor::_always_clear_soft_ref_policy
printf "_default_soft_ref_policy: %p\n", ReferenceProcessor::_default_soft_ref_policy

printf "\n========== JVM Parameters ==========\n"
printf "SoftRefLRUPolicyMSPerMB: %d\n", SoftRefLRUPolicyMSPerMB
printf "RefDiscoveryPolicy: %d\n", RefDiscoveryPolicy

quit
```

### 11.2 实际 GDB 验证结果

【GDB 验证】条件：-Xms256m -Xmx256m -XX:+UseG1GC -XX:SoftRefLRUPolicyMSPerMB=1000

```
=== Soft Ref Timestamp Clock ===
_soft_ref_timestamp_clock: 308659272 ms    ← 当前时间戳（启动后的毫秒数）✅

=== Reference Policies ===
_always_clear_soft_ref_policy: 0x7ffff02025a0    ← AlwaysClearPolicy ✅
_default_soft_ref_policy: 0x7ffff02025e0         ← LRUMaxHeapPolicy (Server 模式) ✅

=== JVM Parameters ===
SoftRefLRUPolicyMSPerMB: 1000                    ← 默认值 ✅
```

**验证分析**：

1. **时间戳时钟初始化**：`_soft_ref_timestamp_clock = 308659272 ms` ✅
   - 这是 JVM 启动后的单调时间（非 Unix 时间戳）
   - 用于计算软引用的 LRU 生存时间

2. **清理策略初始化**：
   - `_always_clear_soft_ref_policy`：OOM 时强制清理所有软引用
   - `_default_soft_ref_policy`：正常 GC 使用 LRUMaxHeapPolicy（因为是 Server 模式）

3. **参数生效**：`SoftRefLRUPolicyMSPerMB = 1000`
   - 每 MB 空闲堆，允许软引用存活 1000ms

---

## 12. 面试高频问题总结

### Q1: 四种引用的区别和使用场景？

| 引用类型 | 清理时机 | get() 返回 | 典型场景 |
|---------|---------|-----------|---------|
| 强引用 | 永不（除非 null） | 对象 | 普通变量 |
| 软引用 | 内存不足时 | 对象 | 缓存 |
| 弱引用 | 下次 GC | 对象 | WeakHashMap |
| 虚引用 | 对象回收后 | null | 资源清理通知 |

### Q2: SoftReference 何时被清理？

```
取决于 LRU 策略和 SoftRefLRUPolicyMSPerMB 参数：
max_interval = (MaxHeapSize - used) / M × SoftRefLRUPolicyMSPerMB

如果 (当前时间 - 上次访问时间) > max_interval → 清理
```

### Q3: finalize() 对象需要几次 GC 回收？

```
至少 2 次：
第 1 次：发现不可达，加入 Finalizer 队列，保持存活
第 2 次：执行完 finalize() 后，真正回收
```

### Q4: PhantomReference 和 WeakReference 的区别？

```
1. get() 返回值：Weak 返回对象，Phantom 永远返回 null
2. 入队时机：Weak 在 referent 被清空前，Phantom 在 referent 被回收后
3. 必须关联队列：Phantom 必须，Weak 可选
```

### Q5: 如何监控引用数量？

```bash
# 1. jcmd 查看直方图
jcmd <pid> GC.class_histogram | grep Reference

# 2. JFR 记录
-XX:StartFlightRecording=filename=ref.jfr,settings=profile

# 3. GC 日志
-Xlog:gc+ref=debug
```

### Q6: ReferenceQueue 是线程安全的吗？

```
是的，ReferenceQueue 内部使用 synchronized 保证线程安全。
```

---

## 13. 总结

### 核心流程

```
referenceProcessor_init()
    │
    └── ReferenceProcessor::init_statics()
        │
        ├── 初始化软引用时间戳时钟
        │   └── _soft_ref_timestamp_clock = 当前时间
        │
        ├── 同步到 Java 层
        │   └── SoftReference.clock = _soft_ref_timestamp_clock
        │
        └── 创建软引用清理策略
            ├── _always_clear_soft_ref_policy = AlwaysClearPolicy
            └── _default_soft_ref_policy = LRUMaxHeapPolicy (Server)
                                         = LRUCurrentHeapPolicy (Client)

GC 期间：
1. 引用发现：将引用对象加入 DiscoveredList
2. Phase 1: 软引用策略筛选
3. Phase 2: 处理 Soft/Weak/Final
4. Phase 3: Final 保持存活
5. Phase 4: 处理 Phantom
6. 入队通知用户
```

### 关键参数

| 参数 | 默认值 | 说明 |
|-----|-------|------|
| `-XX:SoftRefLRUPolicyMSPerMB` | 1000 | 每 MB 空闲堆允许软引用存活的毫秒数 |
| `-XX:+DisableExplicitGC` | false | 禁用 System.gc() |
| `-XX:RefDiscoveryPolicy` | 0 | 引用发现策略 |

### 最佳实践

1. **避免使用 finalize()**：使用 try-with-resources 或 Cleaner
2. **合理使用软引用**：监控数量，调整 SoftRefLRUPolicyMSPerMB
3. **WeakHashMap 注意事项**：不要存储强引用的 value
4. **PhantomReference 用途**：堆外内存清理、资源释放通知

---

> 📅 分析时间：2026-02-06
> 📁 源码版本：OpenJDK 11
