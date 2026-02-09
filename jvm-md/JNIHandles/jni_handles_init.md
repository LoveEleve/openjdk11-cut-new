# JNI Handles 句柄管理详解

> 📌 **面试重要程度**：⭐⭐⭐⭐⭐（极高频）
> 📁 源码位置：`src/hotspot/share/runtime/jniHandles.cpp`
> 🎯 核心考点：三种句柄类型、内存布局、GC 集成、内存泄漏诊断

---

## 1. 概述：为什么需要 JNI Handles？

### 1.1 核心问题

**当 Native 代码（C/C++）需要持有 Java 对象引用时，不能直接保存对象指针！**

原因：
1. **GC 会移动对象**：在 GC 期间，对象可能被移动到新地址
2. **指针会失效**：如果直接保存 oop 指针，GC 后该指针指向无效内存
3. **GC 无法追踪**：GC 不知道 Native 代码持有哪些对象引用

### 1.2 解决方案：JNI Handle 间接引用

```
Native 代码持有           JNI Handle            Java 堆
      │                      │                    │
      │   jobject obj        │                    │
      │  ─────────────────→  │  handle[0] ───────→│ Java 对象 A
      │                      │                    │
      │   jobject obj2       │                    │
      │  ─────────────────→  │  handle[1] ───────→│ Java 对象 B
      │                      │                    │

GC 移动对象时：
1. 只需更新 handle[0] 的指向
2. Native 代码的 jobject 不变
3. 通过 jobject 间接访问时，能获取正确的新地址
```

### 1.3 在启动流程中的位置

```
init_globals()
├── universe_init()              ← 创建堆
├── gc_init()                    ← 初始化 GC
├── referenceProcessor_init()    ← 初始化引用处理
├── jni_handles_init()           ← 【当前分析】初始化 JNI 句柄管理
├── compiler_init()              ← 编译器初始化
└── ...
```

---

## 2. jni_handles_init() 源码解读

### 2.1 入口函数

```cpp
// src/hotspot/share/runtime/jniHandles.cpp:341
void jni_handles_init() {
    JNIHandles::initialize();
}
```

### 2.2 JNIHandles::initialize() 核心实现

```cpp
// src/hotspot/share/runtime/jniHandles.cpp:204
void JNIHandles::initialize() {
    // 1. 创建全局引用存储
    _global_handles = new OopStorage("JNI Global",
                                     JNIGlobalAlloc_lock,
                                     JNIGlobalActive_lock);
    
    // 2. 创建弱全局引用存储
    _weak_global_handles = new OopStorage("JNI Weak",
                                          JNIWeakAlloc_lock,
                                          JNIWeakActive_lock);
}
```

### 2.3 初始化内容总结

| 组件 | 类型 | 说明 |
|------|------|------|
| `_global_handles` | OopStorage* | 存储全局引用（强引用） |
| `_weak_global_handles` | OopStorage* | 存储弱全局引用 |

---

## 3. 三种 JNI Handle 类型（面试必问）

### 3.1 类型对比

| 类型 | 生命周期 | GC 行为 | 创建方式 | 释放方式 |
|------|---------|--------|---------|---------|
| **Local** | 当前 Native 方法 | 阻止对象回收 | `make_local()` | 自动/`DeleteLocalRef` |
| **Global** | 手动控制 | 阻止对象回收 | `NewGlobalRef` | `DeleteGlobalRef` |
| **Weak Global** | 手动控制 | 不阻止回收 | `NewWeakGlobalRef` | `DeleteWeakGlobalRef` |

### 3.2 类型关系图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        JNI Handle 类型                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │           Local Reference（局部引用）                            │   │
│  │                                                                  │   │
│  │  • 存储在 JNIHandleBlock 中（线程私有）                          │   │
│  │  • Native 方法返回时自动释放                                     │   │
│  │  • 默认每个方法最多 16 个（可通过 EnsureLocalCapacity 扩展）     │   │
│  │  • GC 时作为根扫描                                               │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │           Global Reference（全局引用）                           │   │
│  │                                                                  │   │
│  │  • 存储在 OopStorage(_global_handles) 中                         │   │
│  │  • 必须手动调用 DeleteGlobalRef 释放                             │   │
│  │  • 可以跨线程、跨 Native 方法使用                                │   │
│  │  • GC 时作为强根扫描                                             │   │
│  │  • ⚠️ 忘记释放会导致内存泄漏！                                   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │           Weak Global Reference（弱全局引用）                    │   │
│  │                                                                  │   │
│  │  • 存储在 OopStorage(_weak_global_handles) 中                    │   │
│  │  • 必须手动调用 DeleteWeakGlobalRef 释放                         │   │
│  │  • 对象被 GC 时，引用自动变为 NULL                               │   │
│  │  • 使用前必须检查是否已被清理                                    │   │
│  │  • 类似 Java 的 WeakReference                                    │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.3 使用场景

```c
// 1. Local Reference - 临时使用
JNIEXPORT void JNICALL Java_Example_method(JNIEnv *env, jobject this) {
    jstring str = (*env)->NewStringUTF(env, "hello");  // Local ref
    // 使用 str...
    // 方法返回时自动释放
}

// 2. Global Reference - 缓存对象/跨方法
static jclass cachedClass = NULL;  // 全局变量

JNIEXPORT void JNICALL Java_Example_init(JNIEnv *env, jobject this) {
    jclass localClass = (*env)->FindClass(env, "java/lang/String");
    cachedClass = (*env)->NewGlobalRef(env, localClass);  // 升级为全局引用
    (*env)->DeleteLocalRef(env, localClass);  // 释放局部引用
}

JNIEXPORT void JNICALL Java_Example_cleanup(JNIEnv *env, jobject this) {
    (*env)->DeleteGlobalRef(env, cachedClass);  // 必须手动释放
    cachedClass = NULL;
}

// 3. Weak Global Reference - 缓存但允许 GC
static jweak weakCache = NULL;

JNIEXPORT jobject JNICALL Java_Example_get(JNIEnv *env, jobject this) {
    if (weakCache == NULL) {
        return NULL;
    }
    jobject obj = (*env)->NewLocalRef(env, weakCache);  // 尝试获取
    if (obj == NULL) {
        // 对象已被 GC，清理弱引用
        (*env)->DeleteWeakGlobalRef(env, weakCache);
        weakCache = NULL;
    }
    return obj;
}
```

---

## 4. Local Handle 实现详解

### 4.1 JNIHandleBlock 结构

```cpp
// src/hotspot/share/runtime/jniHandles.hpp:132
class JNIHandleBlock : public CHeapObj<mtInternal> {
private:
    enum SomeConstants {
        block_size_in_oops = 32    // 每块 32 个槽位
    };

    oop             _handles[block_size_in_oops];  // 句柄数组（32 个）
    int             _top;                          // 下一个空闲槽位索引
    JNIHandleBlock* _next;                         // 链表指向下一块
    JNIHandleBlock* _last;                         // 链表尾部
    JNIHandleBlock* _pop_frame_link;               // PopLocalFrame 链接
    oop*            _free_list;                    // 空闲槽位链表
    int             _allocate_before_rebuild;      // 重建空闲列表前的分配数
    size_t          _planned_capacity;             // 预期容量
    
    // 全局数据
    static JNIHandleBlock* _block_free_list;       // 全局空闲块链表
    static int             _blocks_allocated;      // 已分配块数
};
```

### 4.2 内存布局图

```
Thread 对象
    │
    └── _active_handles ──→ JNIHandleBlock (当前块)
                              │
                              ├── _handles[0]  ──→ Java 对象 A
                              ├── _handles[1]  ──→ Java 对象 B
                              ├── _handles[2]  ──→ NULL（空闲）
                              ├── ...
                              ├── _handles[31] ──→ NULL
                              │
                              ├── _top = 2（下一个空闲位置）
                              │
                              └── _next ──→ JNIHandleBlock (扩展块)
                                              │
                                              ├── _handles[0..31]
                                              └── _next ──→ NULL

全局空闲池：
JNIHandleBlock::_block_free_list ──→ Block ──→ Block ──→ Block ──→ NULL
```

### 4.3 分配 Local Handle 流程

```cpp
// src/hotspot/share/runtime/jniHandles.cpp:51
jobject JNIHandles::make_local(oop obj) {
    if (obj == NULL) {
        return NULL;
    }
    Thread* thread = Thread::current();
    assert(oopDesc::is_oop(obj), "not an oop");
    assert(!current_thread_in_native(), "must not be in native");
    // 从线程的 active_handles 中分配
    return thread->active_handles()->allocate_handle(obj);
}

// JNIHandleBlock::allocate_handle()
jobject JNIHandleBlock::allocate_handle(oop obj) {
    // 1. 首次分配或块被清空后的重置
    if (_top == 0) {
        _free_list = NULL;
        _allocate_before_rebuild = 0;
        _last = this;
        zap();  // 清空所有槽位
    }

    // 2. 尝试在最后一个块中分配
    if (_last->_top < block_size_in_oops) {
        oop* handle = &(_last->_handles)[_last->_top++];
        NativeAccess<IS_DEST_UNINITIALIZED>::oop_store(handle, obj);
        return (jobject) handle;
    }

    // 3. 尝试从空闲链表分配
    if (_free_list != NULL) {
        oop* handle = _free_list;
        _free_list = (oop*) *_free_list;
        NativeAccess<IS_DEST_UNINITIALIZED>::oop_store(handle, obj);
        return (jobject) handle;
    }

    // 4. 检查是否有未使用的后续块
    if (_last->_next != NULL) {
        _last = _last->_next;
        return allocate_handle(obj);  // 递归
    }

    // 5. 需要扩展：分配新块或重建空闲链表
    if (_allocate_before_rebuild == 0) {
        rebuild_free_list();
    } else {
        _last->_next = JNIHandleBlock::allocate_block(thread);
        _last = _last->_next;
        _allocate_before_rebuild--;
    }
    return allocate_handle(obj);  // 递归重试
}
```

### 4.4 块分配策略（两级缓存）

```cpp
// src/hotspot/share/runtime/jniHandles.cpp:378
JNIHandleBlock* JNIHandleBlock::allocate_block(Thread* thread) {
    JNIHandleBlock* block;
    
    // 策略 1：优先从线程本地空闲列表获取（无锁，最快）
    if (thread != NULL && thread->free_handle_block() != NULL) {
        block = thread->free_handle_block();
        thread->set_free_handle_block(block->_next);
    } 
    // 策略 2：从全局空闲列表获取（需要锁）
    else {
        MutexLockerEx ml(JNIHandleBlockFreeList_lock,
                         Mutex::_no_safepoint_check_flag);
        if (_block_free_list == NULL) {
            // 策略 3：分配新块
            block = new JNIHandleBlock();
            _blocks_allocated++;
            block->zap();
        } else {
            block = _block_free_list;
            _block_free_list = _block_free_list->_next;
        }
    }
    
    // 初始化块
    block->_top = 0;
    block->_next = NULL;
    block->_pop_frame_link = NULL;
    block->_planned_capacity = block_size_in_oops;
    return block;
}
```

### 4.5 两级缓存图解

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    JNIHandleBlock 两级缓存                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Thread 1                     Thread 2                                  │
│  ┌──────────────────┐        ┌──────────────────┐                      │
│  │ free_handle_block│        │ free_handle_block│                      │
│  │     │            │        │     │            │                      │
│  │     ▼            │        │     ▼            │                      │
│  │  Block ──→ Block │        │  Block ──→ NULL  │  ← 线程本地缓存     │
│  └──────────────────┘        └──────────────────┘    （无锁，快速）     │
│          │                                                              │
│          │ 用完后                                                       │
│          ▼                                                              │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                    全局空闲列表（需要锁）                          │  │
│  │                                                                    │  │
│  │  JNIHandleBlockFreeList_lock 保护                                  │  │
│  │                                                                    │  │
│  │  _block_free_list ──→ Block ──→ Block ──→ Block ──→ NULL          │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 5. Global Handle 实现详解

### 5.1 OopStorage 存储结构

```cpp
// src/hotspot/share/gc/shared/oopStorage.hpp:75
class OopStorage : public CHeapObj<mtGC> {
private:
    const char* _name;              // 名称（"JNI Global" 或 "JNI Weak"）
    ActiveArray* _active_array;     // 活跃块数组
    AllocationList _allocation_list;// 分配链表
    Block* volatile _deferred_updates;
    
    Mutex* _allocation_mutex;       // 分配锁
    Mutex* _active_mutex;           // 活跃数组锁
    
    volatile size_t _allocation_count;  // 当前分配数
    mutable SingleWriterSynchronizer _protect_active;
    mutable bool _concurrent_iteration_active;
};
```

### 5.2 make_global() 实现

```cpp
// src/hotspot/share/runtime/jniHandles.cpp:97
jobject JNIHandles::make_global(Handle obj, AllocFailType alloc_failmode) {
    assert(!Universe::heap()->is_gc_active(), "can't extend root set during GC");
    assert(!current_thread_in_native(), "must not be in native");
    
    jobject res = NULL;
    if (!obj.is_null()) {
        assert(oopDesc::is_oop(obj()), "not an oop");
        
        // 从全局存储分配槽位
        oop* ptr = global_handles()->allocate();
        
        if (ptr != NULL) {
            assert(*ptr == NULL, "invariant");
            // 存储对象引用
            NativeAccess<>::oop_store(ptr, obj());
            res = reinterpret_cast<jobject>(ptr);
        } else {
            // 分配失败处理
            report_handle_allocation_failure(alloc_failmode, "global");
        }
    }
    return res;
}
```

### 5.3 destroy_global() 实现

```cpp
// src/hotspot/share/runtime/jniHandles.cpp:168
void JNIHandles::destroy_global(jobject handle) {
    if (handle != NULL) {
        assert(!is_jweak(handle), "wrong method for destroying jweak");
        oop* oop_ptr = jobject_ptr(handle);
        
        // 先清空引用（防止 GC 扫描到脏数据）
        NativeAccess<>::oop_store(oop_ptr, (oop) NULL);
        
        // 释放槽位
        global_handles()->release(oop_ptr);
    }
}
```

---

## 6. Weak Global Handle 实现

### 6.1 弱引用标记机制

```cpp
// src/hotspot/share/runtime/jniHandles.hpp:63
class JNIHandles : AllStatic {
public:
    // 弱引用通过低位标记来区分
    static const uintptr_t weak_tag_size = 1;
    static const uintptr_t weak_tag_alignment = (1u << weak_tag_size);  // 2
    static const uintptr_t weak_tag_mask = weak_tag_alignment - 1;      // 1
    static const int weak_tag_value = 1;
};

// 判断是否是弱引用
inline bool JNIHandles::is_jweak(jobject handle) {
    return (reinterpret_cast<uintptr_t>(handle) & weak_tag_mask) != 0;
}

// 获取弱引用的实际指针
inline oop* JNIHandles::jweak_ptr(jobject handle) {
    assert(is_jweak(handle), "precondition");
    char* ptr = reinterpret_cast<char*>(handle) - weak_tag_value;
    return reinterpret_cast<oop*>(ptr);
}
```

### 6.2 弱引用标记图解

```
普通全局引用（jobject）：
ptr = 0x7fff12340008  (低位为 0)
                   │
                   └─ 直接指向 OopStorage 中的槽位

弱全局引用（jweak）：
handle = 0x7fff12340009  (低位为 1，打了 tag)
                   │
                   └─ 实际槽位地址 = handle - 1 = 0x7fff12340008

检查方式：
if (handle & 1) {
    // 是弱引用
    oop* ptr = (oop*)(handle - 1);  // 去掉 tag
}
```

### 6.3 make_weak_global() 实现

```cpp
// src/hotspot/share/runtime/jniHandles.cpp:124
jobject JNIHandles::make_weak_global(Handle obj, AllocFailType alloc_failmode) {
    assert(!Universe::heap()->is_gc_active(), "can't extend root set during GC");
    assert(!current_thread_in_native(), "must not be in native");
    
    jobject res = NULL;
    if (!obj.is_null()) {
        assert(oopDesc::is_oop(obj()), "not an oop");
        
        // 从弱引用存储分配槽位
        oop* ptr = weak_global_handles()->allocate();
        
        if (ptr != NULL) {
            assert(*ptr == NULL, "invariant");
            // 使用 PhantomReference 语义存储（不保持对象存活）
            NativeAccess<ON_PHANTOM_OOP_REF>::oop_store(ptr, obj());
            
            // 给指针打上弱引用 tag
            char* tptr = reinterpret_cast<char*>(ptr) + weak_tag_value;
            res = reinterpret_cast<jobject>(tptr);
        } else {
            report_handle_allocation_failure(alloc_failmode, "weak global");
        }
    }
    return res;
}
```

### 6.4 检查弱引用是否被清理

```cpp
// src/hotspot/share/runtime/jniHandles.cpp:157
bool JNIHandles::is_global_weak_cleared(jweak handle) {
    assert(handle != NULL, "precondition");
    assert(is_jweak(handle), "not a weak handle");
    
    oop* oop_ptr = jweak_ptr(handle);
    // 使用不保持存活的方式读取
    oop value = NativeAccess<ON_PHANTOM_OOP_REF | AS_NO_KEEPALIVE>::oop_load(oop_ptr);
    
    return value == NULL;  // NULL 说明对象已被 GC
}
```

---

## 7. GC 集成

### 7.1 全局引用作为 GC Root

```cpp
// src/hotspot/share/runtime/jniHandles.cpp:187
void JNIHandles::oops_do(OopClosure* f) {
    // 遍历所有全局引用，作为 GC Root
    global_handles()->oops_do(f);
}

// 弱引用特殊处理
void JNIHandles::weak_oops_do(BoolObjectClosure* is_alive, OopClosure* f) {
    // 遍历弱引用，清理已死亡对象的引用
    weak_global_handles()->weak_oops_do(is_alive, f);
}
```

### 7.2 GC 遍历 Local Handle

```cpp
// src/hotspot/share/runtime/jniHandles.cpp:480
void JNIHandleBlock::oops_do(OopClosure* f) {
    JNIHandleBlock* current_chain = this;
    
    // 遍历块链表
    while (current_chain != NULL) {
        for (JNIHandleBlock* current = current_chain; 
             current != NULL; 
             current = current->_next) {
            // 遍历块中的每个槽位
            for (int index = 0; index < current->_top; index++) {
                oop* root = &(current->_handles)[index];
                oop value = *root;
                // 只处理有效的堆指针
                if (value != NULL && Universe::heap()->is_in_reserved(value)) {
                    f->do_oop(root);
                }
            }
            // 块未满则后续块无效
            if (current->_top < block_size_in_oops) {
                break;
            }
        }
        current_chain = current_chain->pop_frame_link();
    }
}
```

### 7.3 GC Root 扫描流程

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         GC Root 扫描流程                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ 1. 扫描全局引用                                                   │  │
│  │    JNIHandles::oops_do(closure)                                   │  │
│  │    └─→ _global_handles->oops_do(closure)                          │  │
│  │        └─→ 遍历所有非空槽位，标记对象存活                          │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                              │                                          │
│                              ▼                                          │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ 2. 扫描每个线程的局部引用                                         │  │
│  │    for (JavaThread* t : threads) {                                │  │
│  │        t->active_handles()->oops_do(closure);                     │  │
│  │    }                                                               │  │
│  │    └─→ 遍历 JNIHandleBlock 链表中的所有槽位                        │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                              │                                          │
│                              ▼                                          │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ 3. 处理弱全局引用                                                 │  │
│  │    JNIHandles::weak_oops_do(is_alive, closure)                    │  │
│  │    └─→ _weak_global_handles->weak_oops_do(is_alive, closure)      │  │
│  │        └─→ 如果对象已死亡，清空槽位（设为 NULL）                   │  │
│  │        └─→ 如果对象存活，更新指针（对象可能被移动）                │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 8. PushLocalFrame / PopLocalFrame

### 8.1 用途

```c
// 当需要在一个 Native 方法中创建大量局部引用时
JNIEXPORT void JNICALL Java_Example_process(JNIEnv *env, jobject this) {
    // 创建新的局部引用帧，容量 100
    if ((*env)->PushLocalFrame(env, 100) < 0) {
        return;  // OutOfMemoryError
    }
    
    for (int i = 0; i < 1000; i++) {
        jstring str = (*env)->NewStringUTF(env, "temp");
        // 使用 str...
        // 不需要手动 DeleteLocalRef
    }
    
    // 弹出帧，自动释放所有在帧中创建的局部引用
    // 如果需要保留某个引用，传入它作为参数
    jobject result = (*env)->PopLocalFrame(env, someResult);
}
```

### 8.2 实现原理

```cpp
// PushLocalFrame 创建新的 JNIHandleBlock
JNIHandleBlock* new_block = JNIHandleBlock::allocate_block(thread);
new_block->set_pop_frame_link(thread->active_handles());
thread->set_active_handles(new_block);

// PopLocalFrame 恢复之前的 block
JNIHandleBlock* old_block = thread->active_handles();
thread->set_active_handles(old_block->pop_frame_link());
JNIHandleBlock::release_block(old_block, thread);
```

### 8.3 帧链表结构

```
调用 PushLocalFrame 前：
    thread->_active_handles ──→ Block A (原始帧)

调用 PushLocalFrame 后：
    thread->_active_handles ──→ Block B (新帧)
                                   │
                                   └── _pop_frame_link ──→ Block A (原始帧)

调用 PopLocalFrame 后：
    thread->_active_handles ──→ Block A (恢复)
    Block B 被释放到空闲列表
```

---

## 9. 内存泄漏诊断（面试高频）

### 9.1 常见泄漏场景

```c
// 场景 1：忘记释放全局引用
jclass cls = (*env)->FindClass(env, "java/lang/String");
jclass globalCls = (*env)->NewGlobalRef(env, cls);
// ❌ 忘记调用 DeleteGlobalRef(env, globalCls);

// 场景 2：循环中创建大量局部引用
for (int i = 0; i < 1000000; i++) {
    jstring str = (*env)->NewStringUTF(env, "leak");
    // ❌ 没有及时 DeleteLocalRef 或使用 PushLocalFrame
    // 导致局部引用表溢出
}

// 场景 3：在循环中反复创建全局引用
static jobject cache = NULL;
for (int i = 0; i < 100; i++) {
    jobject obj = ...;
    if (cache != NULL) {
        (*env)->DeleteGlobalRef(env, cache);  // ❌ 放在前面会丢失引用
    }
    cache = (*env)->NewGlobalRef(env, obj);
}
// ✅ 正确做法：先保存旧引用，再删除
```

### 9.2 诊断工具

```bash
# 1. 打印 JNI 句柄统计
jcmd <pid> VM.native_memory detail

# 2. 启用 JNI 检查
java -Xcheck:jni MyApp

# 3. 使用 VisualVM 或 JProfiler 监控
# - 观察 "JNI Global References" 增长趋势
# - 设置告警阈值

# 4. GC 日志中的引用计数
-Xlog:gc+ref=debug
```

### 9.3 JNIHandles::print_on() 输出

```cpp
// src/hotspot/share/runtime/jniHandles.cpp:302
void JNIHandles::print_on(outputStream* st) {
    st->print_cr("JNI global refs: " SIZE_FORMAT ", weak refs: " SIZE_FORMAT,
                 global_handles()->allocation_count(),
                 weak_global_handles()->allocation_count());
}

// 输出示例：
// JNI global refs: 1523, weak refs: 47
```

---

## 10. 面试高频问题

### Q1: 三种 JNI Handle 的区别？

| 特性 | Local | Global | Weak Global |
|------|-------|--------|-------------|
| 生命周期 | 当前 Native 方法 | 手动控制 | 手动控制 |
| 跨方法 | ❌ | ✅ | ✅ |
| 跨线程 | ❌ | ✅ | ✅ |
| 阻止 GC | ✅ | ✅ | ❌ |
| 自动释放 | ✅ | ❌ | ❌ |
| 存储位置 | JNIHandleBlock | OopStorage | OopStorage |

### Q2: 为什么 Local Handle 在方法返回后会失效？

```
因为 Native 方法返回时，JVM 会自动清空当前线程的 JNIHandleBlock：
1. _top 重置为 0
2. 所有槽位被 zap() 清空
3. 原来的 jobject 指针指向的位置变为无效

如果把 Local Handle 存储到全局变量：
static jobject badGlobal = NULL;

JNIEXPORT void method(JNIEnv *env, jobject this) {
    badGlobal = (*env)->NewStringUTF(env, "bad");  // ❌
}
// 方法返回后，badGlobal 指向已被清空的槽位
// 再次使用会导致崩溃或数据错误
```

### Q3: Weak Global Reference 什么时候变为 NULL？

```
在 GC 标记阶段结束后：
1. GC 遍历 _weak_global_handles
2. 对于每个弱引用，检查 referent 是否存活
3. 如果 referent 不可达（没有强引用），清空槽位

时机：
- Full GC 后必定检查
- Minor GC 如果 referent 在老年代，可能不检查
- 并发 GC（如 G1/ZGC）在并发标记阶段处理
```

### Q4: 如何判断一个 jobject 是全局引用还是局部引用？

```cpp
// JNI 提供了 GetObjectRefType 函数
jobjectRefType refType = (*env)->GetObjectRefType(env, handle);
switch (refType) {
    case JNIInvalidRefType:    // 无效引用
    case JNILocalRefType:      // 局部引用
    case JNIGlobalRefType:     // 全局引用
    case JNIWeakGlobalRefType: // 弱全局引用
}

// HotSpot 实现
jobjectRefType JNIHandles::handle_type(Thread* thread, jobject handle) {
    if (is_jweak(handle)) {
        // 检查是否在 weak_global_handles 中
        return JNIWeakGlobalRefType;
    } else {
        // 先检查全局存储
        if (global_handles()->allocation_status(ptr) == ALLOCATED_ENTRY) {
            return JNIGlobalRefType;
        }
        // 再检查局部引用
        if (is_local_handle(thread, handle)) {
            return JNILocalRefType;
        }
    }
    return JNIInvalidRefType;
}
```

### Q5: JNI 调用中如何避免内存泄漏？

```c
// 最佳实践

// 1. 使用 PushLocalFrame/PopLocalFrame 处理大量局部引用
if ((*env)->PushLocalFrame(env, 100) >= 0) {
    for (int i = 0; i < 1000; i++) {
        jstring str = (*env)->NewStringUTF(env, "temp");
        // 使用...
    }
    (*env)->PopLocalFrame(env, NULL);
}

// 2. 全局引用配对使用
jclass globalCls = (*env)->NewGlobalRef(env, localCls);
// ... 使用 globalCls ...
(*env)->DeleteGlobalRef(env, globalCls);

// 3. 及时删除不需要的局部引用
for (int i = 0; i < 1000; i++) {
    jstring str = (*env)->NewStringUTF(env, "temp");
    // 使用 str...
    (*env)->DeleteLocalRef(env, str);  // 及时释放
}

// 4. 使用 RAII 风格（C++）
class LocalRefGuard {
    JNIEnv* env;
    jobject ref;
public:
    LocalRefGuard(JNIEnv* e, jobject r) : env(e), ref(r) {}
    ~LocalRefGuard() { if (ref) env->DeleteLocalRef(ref); }
    jobject get() { return ref; }
};
```

---

## 11. GDB 验证

### 11.1 GDB 验证脚本

```gdb
# jvm-md/JNIHandles/gdb_jni_handles_init.txt

set pagination off
set print pretty on

b JNIHandles::initialize
run -Xms256m -Xmx256m -XX:+UseG1GC -cp /data/workspace/demo/src com.wjcoder.Main

finish

printf "\n========== JNI Global Handles ==========\n"
printf "_global_handles: %p\n", JNIHandles::_global_handles
printf "_weak_global_handles: %p\n", JNIHandles::_weak_global_handles

printf "\n========== JNIHandleBlock Stats ==========\n"
printf "_blocks_allocated: %d\n", JNIHandleBlock::_blocks_allocated
printf "_block_free_list: %p\n", JNIHandleBlock::_block_free_list

quit
```

### 11.2 实际 GDB 验证结果

【GDB 验证】条件：-Xms256m -Xmx256m -XX:+UseG1GC

```
=== JNI Global Handles ===
_global_handles: 0x7ffff02025c0         ← 全局引用存储已创建 ✅
_weak_global_handles: 0x7ffff0202770    ← 弱全局引用存储已创建 ✅

=== JNIHandleBlock Stats ===
_blocks_allocated: 4                     ← 已分配 4 个块 ✅
_block_free_list: (nil)                  ← 空闲列表为空（全在使用中）✅
```

**验证分析**：

1. **全局引用存储**：`_global_handles = 0x7ffff02025c0` ✅
   - OopStorage 对象已成功创建
   - 名称为 "JNI Global"
   - 用于存储所有全局引用

2. **弱全局引用存储**：`_weak_global_handles = 0x7ffff0202770` ✅
   - OopStorage 对象已成功创建
   - 名称为 "JNI Weak"
   - 用于存储所有弱全局引用

3. **JNIHandleBlock 状态**：
   - 已分配 4 个块（每块 32 个槽位）
   - 启动阶段就有一些 JNI 调用，预先分配了块
   - 空闲列表为空，说明当前分配的块都在使用中

---

## 12. 总结

### 核心流程

```
jni_handles_init()
    │
    └── JNIHandles::initialize()
        │
        ├── 创建 _global_handles (OopStorage)
        │   └── 用于存储全局引用
        │
        └── 创建 _weak_global_handles (OopStorage)
            └── 用于存储弱全局引用

运行时：
┌─────────────────────────────────────────────────────────────────────────┐
│  Local Handle:                                                          │
│    Thread->active_handles (JNIHandleBlock 链表)                         │
│    每块 32 个槽位，两级缓存（线程本地 + 全局空闲池）                     │
│                                                                         │
│  Global Handle:                                                         │
│    JNIHandles::_global_handles (OopStorage)                             │
│    GC 时作为强根扫描                                                    │
│                                                                         │
│  Weak Global Handle:                                                    │
│    JNIHandles::_weak_global_handles (OopStorage)                        │
│    GC 时清理已死亡对象的引用                                            │
│    通过低位 tag 区分普通全局引用                                        │
└─────────────────────────────────────────────────────────────────────────┘
```

### 关键数据结构

| 结构 | 用途 | 特点 |
|------|------|------|
| JNIHandleBlock | 存储局部引用 | 32 槽位/块，链表，两级缓存 |
| OopStorage | 存储全局/弱全局引用 | 支持并发分配，GC 安全迭代 |

### 最佳实践

1. **优先使用局部引用**：自动管理生命周期
2. **全局引用配对释放**：NewGlobalRef ↔ DeleteGlobalRef
3. **大量引用用 PushLocalFrame**：避免局部引用表溢出
4. **弱引用检查有效性**：使用前调用 `IsSameObject(env, weak, NULL)`
5. **监控引用数量**：定期检查全局引用增长趋势

---

> 📅 分析时间：2026-02-06
> 📁 源码版本：OpenJDK 11
