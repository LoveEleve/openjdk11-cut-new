# 4. SystemDictionary::initialize_oop_storage()

> OopStorage：JVM 管理堆外 oop 引用的高并发容器

## 1. 源码入口

```cpp
// src/hotspot/share/memory/universe.cpp:729
SystemDictionary::initialize_oop_storage();

// src/hotspot/share/classfile/systemDictionary.cpp:3045
void SystemDictionary::initialize_oop_storage() {
  _vm_weak_oop_storage =
    new OopStorage("VM Weak Oop Handles",  // 名称
                   VMWeakAlloc_lock,        // 分配锁
                   VMWeakActive_lock);      // 活动锁
}
```

## 2. OopStorage 解决什么问题？

### 2.1 问题背景

JVM 内部需要持有 Java 对象的引用（oop），但这些引用存在于 **C++ 堆（native heap）** 中，而不是 Java 堆。GC 必须能够：
1. **找到这些引用** - 否则会漏标导致对象被错误回收
2. **更新这些引用** - 对象移动后需要更新指针
3. **处理弱引用语义** - 某些引用是弱引用，死亡对象要置 NULL

### 2.2 传统方案的问题

```cpp
// 传统方案：全局数组 + 全局锁
static oop* _weak_refs[MAX_REFS];
static Mutex* _lock;

oop* allocate() {
    MutexLocker ml(_lock);  // 全局锁，高争用
    // 线性查找空位，O(n) 复杂度
    for (int i = 0; i < MAX_REFS; i++) {
        if (_weak_refs[i] == NULL) {
            return &_weak_refs[i];
        }
    }
}
```

问题：
- **高锁争用** - 所有操作共享一把锁
- **GC 遍历慢** - 需要遍历整个数组，包括空位
- **碎片化** - 难以高效管理空闲空间

### 2.3 OopStorage 的解决方案

```
设计理念：
┌─────────────────────────────────────────────────────────────────┐
│ 1. 分块管理 - 固定大小的 Block，每个 Block 存 64 个 oop        │
│ 2. 双锁分离 - 分配锁 + 活动锁，减少争用                        │
│ 3. 位图跟踪 - 64 位位图快速定位空闲/已分配位置                 │
│ 4. 无锁释放 - release() 操作使用 CAS，不需要锁                 │
│ 5. 延迟更新 - 状态变更延迟到分配时处理                         │
└─────────────────────────────────────────────────────────────────┘
```

## 3. 数据结构详解

### 3.1 总体架构

```
OopStorage ("VM Weak Oop Handles")
┌──────────────────────────────────────────────────────────────────────┐
│  _name = "VM Weak Oop Handles"                                       │
│  _allocation_count = 当前已分配的条目数                              │
│  _concurrent_iteration_active = false (是否有并发 GC 迭代在进行)      │
│                                                                      │
│  _allocation_mutex = VMWeakAlloc_lock   (分配/释放时的锁)            │
│  _active_mutex = VMWeakActive_lock      (管理活动块数组的锁)          │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ _active_array (ActiveArray)                                  │   │
│  │ ┌────────────────────────────────────────────────────────┐  │   │
│  │ │ _size = 8 (初始容量)                                   │  │   │
│  │ │ _block_count = 当前 Block 数量                         │  │   │
│  │ │ _refcount = 引用计数（支持无锁扩展）                    │  │   │
│  │ │                                                         │  │   │
│  │ │ Block* _blocks[8]:                                      │  │   │
│  │ │ [0] ──→ Block0                                          │  │   │
│  │ │ [1] ──→ Block1                                          │  │   │
│  │ │ [2] ──→ ...                                             │  │   │
│  │ └────────────────────────────────────────────────────────┘  │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ _allocation_list (双向链表，只包含非满的 Block)              │   │
│  │   head ──→ Block2 ←→ Block0 ←→ Block5 ←── tail               │   │
│  │            (有空位)   (有空位)  (空的)                         │   │
│  │   注：满的 Block 不在此链表中                                 │   │
│  │       空的 Block 放在链表尾部（方便删除）                      │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  _deferred_updates ──→ Block3 ──→ Block7 ──→ NULL                   │
│  (延迟更新链表：release() 时状态变化的 Block)                        │
└──────────────────────────────────────────────────────────────────────┘
```

### 3.2 Block 结构

```cpp
// src/hotspot/share/gc/shared/oopStorage.inline.hpp:132
class OopStorage::Block {
  // _data 必须是第一个成员，保证对齐
  oop _data[BitsPerWord];           // 64 个 oop 槽位（512 字节）
  
  volatile uintx _allocated_bitmask; // 64 位位图，1=已分配
  const OopStorage* _owner;          // 所属 OopStorage
  void* _memory;                     // 原始分配地址（用于释放）
  size_t _active_index;              // 在 ActiveArray 中的索引
  AllocationListEntry _allocation_list_entry;  // 链表节点
  Block* volatile _deferred_updates_next;      // 延迟更新链表
  volatile uintx _release_refcount;            // 释放引用计数
};
```

内存布局（64 位系统）：
```
Block (约 600 字节)
┌─────────────────────────────────────────────────────────────┐
│ oop _data[64]                                               │ 512 字节
│ ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬───────┐  │
│ │oop0│oop1│oop2│oop3│oop4│oop5│ ... │oop63│       │  │
│ └─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴───────┘  │
├─────────────────────────────────────────────────────────────┤
│ _allocated_bitmask (8 字节)                                 │
│   例：0x0000_0000_0000_001F = 前 5 个已分配                 │
│   位 0 = _data[0], 位 1 = _data[1], ...                     │
├─────────────────────────────────────────────────────────────┤
│ _owner (8 字节) → OopStorage*                               │
│ _memory (8 字节) → 原始 malloc 地址                         │
│ _active_index (8 字节)                                      │
├─────────────────────────────────────────────────────────────┤
│ _allocation_list_entry:                                     │
│   _prev (8 字节)                                            │
│   _next (8 字节)                                            │
├─────────────────────────────────────────────────────────────┤
│ _deferred_updates_next (8 字节)                             │
│ _release_refcount (8 字节)                                  │
└─────────────────────────────────────────────────────────────┘
```

### 3.3 位图操作

```cpp
// 分配：找到第一个空位
oop* OopStorage::Block::allocate() {
    uintx allocated = _allocated_bitmask;
    while (true) {
        // count_trailing_zeros(~allocated) 找到第一个 0 位
        unsigned index = count_trailing_zeros(~allocated);
        uintx new_value = allocated | bitmask_for_index(index);
        
        // CAS 更新位图
        uintx fetched = Atomic::cmpxchg(new_value, &_allocated_bitmask, allocated);
        if (fetched == allocated) {
            return get_pointer(index);  // 成功
        }
        allocated = fetched;  // 重试
    }
}
```

位图操作示例：
```
初始状态：_allocated_bitmask = 0x0000_0000_0000_0000 (全空)

分配第 1 个：
  ~allocated = 0xFFFF_FFFF_FFFF_FFFF
  count_trailing_zeros(~allocated) = 0  → index = 0
  new_value = 0x0000_0000_0000_0001
  返回 &_data[0]

分配第 2 个：
  allocated = 0x0000_0000_0000_0001
  ~allocated = 0xFFFF_FFFF_FFFF_FFFE
  count_trailing_zeros(~allocated) = 1  → index = 1
  new_value = 0x0000_0000_0000_0003
  返回 &_data[1]

释放 index=0：
  releasing = 0x0000_0000_0000_0001
  new_value = old_allocated ^ releasing
            = 0x0000_0000_0000_0003 ^ 0x0000_0000_0000_0001
            = 0x0000_0000_0000_0002
```

## 4. 核心操作

### 4.1 分配流程

```cpp
oop* OopStorage::allocate() {
    MutexLockerEx ml(_allocation_mutex, Mutex::_no_safepoint_check_flag);
    
    // 1. 处理延迟更新
    while (reduce_deferred_updates() && (_allocation_list.head() == NULL)) {}
    
    // 2. 从分配链表头部获取 Block
    Block* block = _allocation_list.head();
    
    if (block == NULL) {
        // 3. 没有可用 Block，创建新的
        block = Block::new_block(this);
        
        // 4. 添加到 ActiveArray
        if (!_active_array->push(block)) {
            expand_active_array();  // 扩展数组
            _active_array->push(block);
        }
        
        // 5. 添加到分配链表尾部
        _allocation_list.push_back(*block);
    }
    
    // 6. 从 Block 分配槽位
    oop* result = block->allocate();
    
    // 7. 如果 Block 满了，从分配链表移除
    if (block->is_full()) {
        _allocation_list.unlink(*block);
    }
    
    Atomic::inc(&_allocation_count);
    return result;
}
```

流程图：
```
allocate()
    │
    ▼
┌─────────────────────────┐
│ 获取 _allocation_mutex  │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐     ┌─────────────────────────┐
│ _allocation_list 有块?  │──否→│ 创建新 Block            │
└───────────┬─────────────┘     │ 添加到 ActiveArray      │
            │是                  │ 添加到 allocation_list  │
            │                   └───────────┬─────────────┘
            ▼                               │
┌─────────────────────────┐                 │
│ block = list.head()     │←────────────────┘
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│ result = block->allocate│  (位图 CAS 操作)
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐     ┌─────────────────────────┐
│ Block 满了?             │──是→│ 从 allocation_list 移除 │
└───────────┬─────────────┘     └───────────┬─────────────┘
            │否                              │
            ▼                               ▼
┌─────────────────────────┐
│ 返回 result (oop*)      │
└─────────────────────────┘
```

### 4.2 释放流程（无锁）

```cpp
void OopStorage::release(const oop* ptr) {
    // 1. 通过地址对齐找到所属 Block（无需遍历）
    Block* block = Block::block_for_ptr(this, ptr);
    
    // 2. 计算位图掩码
    uintx releasing = block->bitmask_for_entry(ptr);
    
    // 3. CAS 更新位图
    block->release_entries(releasing, &_deferred_updates);
    
    // 4. 减少计数
    Atomic::sub(1, &_allocation_count);
}

void Block::release_entries(uintx releasing, Block* volatile* deferred_list) {
    // 防止在释放过程中 Block 被删除
    Atomic::inc(&_release_refcount);
    
    // CAS 更新位图
    uintx old_allocated = _allocated_bitmask;
    while (true) {
        uintx new_value = old_allocated ^ releasing;
        uintx fetched = Atomic::cmpxchg(new_value, &_allocated_bitmask, old_allocated);
        if (fetched == old_allocated) break;
        old_allocated = fetched;
    }
    
    // 如果状态变化（变空或从满变非满），加入延迟更新链表
    if ((releasing == old_allocated) || is_full_bitmask(old_allocated)) {
        // 无锁 push 到 deferred_updates 链表
        Block* head;
        do {
            head = *deferred_list;
            _deferred_updates_next = head;
        } while (Atomic::cmpxchg(this, deferred_list, head) != head);
    }
    
    Atomic::dec(&_release_refcount);
}
```

**关键设计**：release() 完全无锁，状态变更（Block 变空/从满变非满）通过延迟更新链表处理，由后续的 allocate() 或 GC 处理。

### 4.3 GC 遍历

```cpp
// 安全点遍历（串行）
template<typename F>
bool OopStorage::iterate_safepoint(F f) {
    assert_at_safepoint();
    
    ActiveArray* blocks = _active_array;
    size_t limit = blocks->block_count();
    
    for (size_t i = 0; i < limit; ++i) {
        Block* block = blocks->at(i);
        
        // 遍历 Block 中已分配的条目
        uintx bitmask = block->allocated_bitmask();
        while (bitmask != 0) {
            unsigned index = count_trailing_zeros(bitmask);
            bitmask ^= block->bitmask_for_index(index);
            
            oop* ptr = block->get_pointer(index);
            if (!f(ptr)) return false;  // 用户回调
        }
    }
    return true;
}
```

**优点**：只遍历已分配的条目，通过位图快速跳过空位。

## 5. 双锁设计详解

```
┌─────────────────────────────────────────────────────────────────────┐
│                         锁分离策略                                   │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  VMWeakAlloc_lock (分配锁)            VMWeakActive_lock (活动锁)    │
│  ┌─────────────────────────┐          ┌─────────────────────────┐   │
│  │ 保护:                   │          │ 保护:                   │   │
│  │ - _allocation_list      │          │ - _active_array         │   │
│  │ - Block 内槽位分配      │          │ - _concurrent_iteration │   │
│  │ - _deferred_updates     │          │                         │   │
│  │                         │          │                         │   │
│  │ 操作:                   │          │ 操作:                   │   │
│  │ - allocate()            │          │ - GC 并发遍历           │   │
│  │ - reduce_deferred()     │          │ - 删除空 Block          │   │
│  └─────────────────────────┘          └─────────────────────────┘   │
│                                                                      │
│  要求: active_mutex.rank < allocation_mutex.rank                    │
│        （避免死锁，总是先获取 active_mutex）                         │
└─────────────────────────────────────────────────────────────────────┘
```

为什么分两把锁？
```
场景                    传统单锁              双锁设计
─────────────────────────────────────────────────────────
线程 A: allocate()      获取锁               获取 alloc_lock
线程 B: GC 遍历         等待...              获取 active_lock（无阻塞）
线程 C: release()       等待...              无锁 CAS

结果：                  串行执行              并发执行，大大减少争用
```

## 6. "VM Weak Oop Handles" 存储什么？

```cpp
// 典型使用场景
class SomeNativeCode {
    oop* _cached_object;  // 指向 OopStorage 中的槽位
    
    void cache_object(oop obj) {
        _cached_object = SystemDictionary::vm_weak_oop_storage()->allocate();
        *_cached_object = obj;
    }
    
    oop get_cached() {
        return *_cached_object;  // 可能为 NULL（被 GC 清理）
    }
    
    ~SomeNativeCode() {
        *_cached_object = NULL;
        SystemDictionary::vm_weak_oop_storage()->release(_cached_object);
    }
};
```

典型用途：
| 用途 | 说明 |
|------|------|
| JNI Weak Global Refs | `NewWeakGlobalRef()` 创建的弱全局引用 |
| StringTable 去重 | G1 StringDeduplication 的候选字符串 |
| 类加载器关联数据 | ClassLoaderData 中的弱引用 |
| JVMTI 对象标签 | 调试工具标记对象 |

**弱引用语义**：
- GC 时，如果对象不可达，OopStorage 中的槽位会被置为 NULL
- 用户代码读取时需要检查是否为 NULL

## 7. 构造函数分析

```cpp
// src/hotspot/share/gc/shared/oopStorage.cpp:720
const size_t initial_active_array_size = 8;

OopStorage::OopStorage(const char* name,
                       Mutex* allocation_mutex,
                       Mutex* active_mutex) :
  _name(dup_name(name)),                                    // 复制名称
  _active_array(ActiveArray::create(initial_active_array_size)),  // 创建大小为 8 的数组
  _allocation_list(),                                       // 空链表
  _deferred_updates(NULL),                                  // 无延迟更新
  _allocation_mutex(allocation_mutex),
  _active_mutex(active_mutex),
  _allocation_count(0),
  _concurrent_iteration_active(false)
{
  _active_array->increment_refcount();
  
  // 断言：active_mutex 的 rank 必须低于 allocation_mutex
  assert(_active_mutex->rank() < _allocation_mutex->rank(), ...);
}
```

初始状态：
```
OopStorage 创建后
┌─────────────────────────────────────────────────────────────────┐
│ _name = "VM Weak Oop Handles"                                   │
│ _allocation_count = 0                                           │
│                                                                 │
│ _active_array:                                                  │
│   _size = 8, _block_count = 0, _refcount = 1                   │
│   _blocks[] = {NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL} │
│                                                                 │
│ _allocation_list: head = NULL, tail = NULL                      │
│ _deferred_updates = NULL                                        │
└─────────────────────────────────────────────────────────────────┘
```

## 8. GDB 验证

```gdb
# 设置断点
b SystemDictionary::initialize_oop_storage

# 运行到断点后
(gdb) finish

# 查看 _vm_weak_oop_storage
(gdb) p SystemDictionary::_vm_weak_oop_storage
$1 = (OopStorage *) 0x7f1234560000

(gdb) p *SystemDictionary::_vm_weak_oop_storage
$2 = {
  _name = "VM Weak Oop Handles",
  _active_array = 0x7f1234560100,
  _allocation_list = { _head = 0x0, _tail = 0x0 },
  _deferred_updates = 0x0,
  _allocation_mutex = 0x7f1234500200,  # VMWeakAlloc_lock
  _active_mutex = 0x7f1234500100,      # VMWeakActive_lock
  _allocation_count = 0,
  _concurrent_iteration_active = false
}

# 查看 ActiveArray
(gdb) p *((OopStorage::ActiveArray*)0x7f1234560100)
$3 = {
  _size = 8,
  _block_count = 0,
  _refcount = 1
}
```

## 9. 设计亮点总结

| 特性 | 传统方案 | OopStorage |
|------|---------|------------|
| 分配 | 全局锁 + 线性查找 | 分块 + 位图，O(1) 复杂度 |
| 释放 | 需要锁 | 完全无锁（CAS） |
| GC 遍历 | 遍历全部槽位 | 位图跳过空位 |
| 并发 | 单锁串行 | 双锁分离，高并发 |
| 扩展 | 固定大小或全锁扩展 | 引用计数 + 无锁数组替换 |

**核心思想**：
1. **空间换时间** - Block 分块管理，减少全局争用
2. **延迟处理** - 状态变更延迟到分配时，避免释放时加锁
3. **读写分离** - 分配锁和活动锁分离，GC 遍历不阻塞分配

---

## 下一步

OopStorage 是 JVM 管理堆外 oop 引用的基础设施，后续的 StringTable、SymbolTable 等也会使用类似的设计思想。

接下来可以分析：
- **5. Metaspace::global_initialize()** - 元空间初始化
- **11. SymbolTable::create_table()** - 符号表（哈希表实现）
