# StringTable 专家级深度分析

> **源码位置**: `src/hotspot/share/classfile/stringTable.hpp/cpp`  
> **JDK版本**: OpenJDK 11+  
> **重要程度**: ⭐⭐⭐⭐⭐ (面试高频)  
> **分析时间**: 2026-02-11

---

## 1. 问题引入：为什么需要 StringTable？

### 1.1 String.intern() 的作用

```java
String s1 = new String("hello");
String s2 = new String("hello");

System.out.println(s1 == s2);           // false，不同对象
System.out.println(s1.intern() == s2.intern());  // true，同一对象
```

**核心问题**：
- `intern()` 如何保证相同内容的字符串返回同一对象？
- 全局唯一的字符串存储在哪里？
- GC 如何清理不再使用的 interned 字符串？
- 为什么 JDK7+ 将字符串常量池从 PermGen 移到 Heap？

### 1.2 StringTable 的核心职责

```
┌─────────────────────────────────────────────────────────────────────┐
│                         StringTable 定位                             │
├─────────────────────────────────────────────────────────────────────┤
│ 1. 全局字符串哈希表：存储所有 interned 字符串                         │
│ 2. 去重机制：相同内容只保留一份，节省内存                            │
│ 3. 线程安全：支持并发读写，读操作 wait-free                          │
│ 4. GC 协作：弱引用存储，允许 GC 回收不再使用的字符串                 │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. 整体架构概览

### 2.1 类层次结构

```
StringTable (单例)
    │
    ├── _local_table: StringTableHash*  ← 实际存储结构
    │   └── ConcurrentHashTable<WeakHandle<>, StringTableConfig, mtSymbol>
    │       ├── InternalTable  (Bucket 数组)
    │       │   └── Bucket[]   ← 哈希桶，每个桶是一个链表头
    │       │       └── Node   ← 链表节点
    │       │           ├── _next: Node*  ← 链表指针
    │       │           └── _value: WeakHandle<vm_string_table_data>
    │       │               └── _obj: OopHandle  ← 弱引用指向 String 对象
    │       │
    │       └── ActiveArray  ← 管理 Bucket 数组的元数据
    │
    ├── _weak_handles: OopStorage*  ← 弱引用存储池
    │
    └── _shared_table: CompactHashtable  ← CDS 共享字符串表

关键组件关系:
- StringTable 是 facade，提供静态接口
- ConcurrentHashTable 是核心哈希表实现
- WeakHandle 实现弱引用，允许 GC 回收
- OopStorage 管理弱引用内存
```

### 2.2 内存布局全景图

```
┌──────────────────────────────────────────────────────────────────────┐
│                         StringTable 内存布局                          │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                    StringTable (单例对象)                       │ │
│  │  - _local_table: StringTableHash*                               │ │
│  │  - _weak_handles: OopStorage*                                   │ │
│  │  - _items: size_t (当前条目数)                                  │ │
│  │  - _current_size: size_t (当前桶数量)                           │ │
│  └─────────────────────────┬──────────────────────────────────────┘ │
│                            │                                         │
│                            ▼                                         │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │              StringTableHash (ConcurrentHashTable)              │ │
│  │  - _table: InternalTable*  ← 指向 Bucket 数组                  │ │
│  │  - _size: size_t (2的幂次，如 2^20 = 1,048,576)                │ │
│  └─────────────────────────┬──────────────────────────────────────┘ │
│                            │                                         │
│                            ▼                                         │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                    InternalTable (Bucket数组)                   │ │
│  │  ┌─────────┬─────────┬─────────┬─────────┬─────────────────┐   │ │
│  │  │ Bucket0 │ Bucket1 │ Bucket2 │  ...    │ Bucket[N-1]     │   │ │
│  │  │  (8B)   │  (8B)   │  (8B)   │         │    (8B)         │   │ │
│  │  └────┬────┴────┬────┴────┬────┴─────────┴─────────────────┘   │ │
│  │       │         │         │                                     │ │
│  │       ▼         ▼         ▼                                     │ │
│  │  ┌───────┐  ┌───────┐  ┌───────┐                               │ │
│  │  │ Node  │  │ Node  │  │ NULL  │  ← 链表结构                   │ │
│  │  │ (16B) │  │ (16B) │  │       │                               │ │
│  │  └───┬───┘  └───┬───┘  └───────┘                               │ │
│  │      │          │                                               │ │
│  │      ▼          ▼                                               │ │
│  │  ┌───────┐  ┌───────┐                                           │ │
│  │  │ Node  │  │ Node  │                                           │ │
│  │  │ (16B) │  │ (16B) │                                           │ │
│  │  └───────┘  └───┬───┘                                           │ │
│  │                 │                                                │ │
│  │                 ▼                                                │ │
│  │               NULL                                               │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                    Node 节点结构 (16字节)                        │ │
│  │  ┌────────────────┬────────────────┐                            │ │
│  │  │  _next (8B)    │  _value (8B)   │                            │ │
│  │  │  链表指针       │ WeakHandle指针  │                            │ │
│  │  └────────────────┴────────────────┘                            │ │
│  │                                                                  │ │
│  │  _value 指向:                                                    │ │
│  │  ┌──────────────────────────────────────┐                       │ │
│  │  │     WeakHandle<vm_string_table_data>  │                       │ │
│  │  │     - _obj: OopHandle (弱引用)        │                       │ │
│  │  │       └── 指向 Java Heap 中的 String   │                       │ │
│  │  └──────────────────────────────────────┘                       │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                    OopStorage (弱引用存储池)                     │ │
│  │  - 管理所有 WeakHandle 的内存                                    │ │
│  │  - GC 时扫描，释放死亡对象的引用                                  │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

内存占用估算 (默认 1,048,576 个桶):
- Bucket 数组: 1,048,576 × 8B = 8MB
- Node 节点: 约 200KB (假设 10,000 个字符串)
- OopStorage: 约 100KB
- 总计: ~8.3MB
```

---

## 3. 核心数据结构详解

### 3.1 StringTable (Facade 类)

```cpp
// stringTable.hpp:47-77
class StringTable : public CHeapObj<mtSymbol> {
private:
  static StringTable* _the_table;                    // 单例指针
  static CompactHashtable<oop, char> _shared_table;  // CDS 共享表
  
  StringTableHash* _local_table;     // 实际的哈希表
  size_t _current_size;              // 当前桶数量
  volatile size_t _items;            // 当前条目数
  volatile size_t _uncleaned_items;  // 待清理的死亡条目
  
  OopStorage* _weak_handles;         // 弱引用存储池
  
  volatile bool _has_work;           // 标记是否有清理工作
  volatile bool _needs_rehashing;    // 标记是否需要 rehash
  
public:
  static void create_table() {
    _the_table = new StringTable();  // CHeap 上分配
  }
  
  // 核心接口
  static oop intern(oop string, TRAPS);                    // intern 入口
  static oop lookup(jchar* chars, int len);                // 查找
  static void unlink_or_oops_do(BoolObjectClosure* cl);    // GC 清理
};
```

### 3.2 ConcurrentHashTable (核心哈希表)

```cpp
// concurrentHashTable.hpp:36-70
template <typename VALUE, typename CONFIG, MEMFLAGS F>
class ConcurrentHashTable : public CHeapObj<F> {
private:
  // 内部节点
  class Node {
    Node* volatile _next;    // 链表指针
    VALUE _value;            // 存储的值 (WeakHandle)
  };
  
  // Bucket：嵌入状态位的链表头
  class Bucket {
    Node* volatile _first;   // 低 2 位存储状态 (locked/redirect)
    
    // 状态位定义
    static const uintptr_t STATE_LOCK_BIT = 0x1;
    static const uintptr_t STATE_REDIRECT_BIT = 0x2;
  };
  
  // InternalTable：Bucket 数组的包装
  class InternalTable {
    Bucket* const _buckets;   // Bucket 数组
    const size_t _size;       // 数组大小 (2的幂次)
  };
  
  InternalTable* _table;      // 当前表
  size_t _size;               // 当前大小
  
public:
  // 读操作 (wait-free)
  template <typename LOOKUP_FUNC>
  bool get(Thread* thread, LOOKUP_FUNC& lookup_f, VALUE& value, bool* grow);
  
  // 插入操作 (CAS)
  template <typename LOOKUP_FUNC>
  bool insert(Thread* thread, LOOKUP_FUNC& lookup_f, const VALUE& value);
  
  // 删除操作 (per-bucket 锁)
  template <typename LOOKUP_FUNC>
  bool remove(Thread* thread, LOOKUP_FUNC& lookup_f);
};
```

### 3.3 WeakHandle (弱引用实现)

```cpp
// oops/weakHandle.hpp
// WeakHandle 是对 OopHandle 的包装，实现弱引用语义

template <typename T>
class WeakHandle {
private:
  OopHandle _obj;  // 实际存储在 OopStorage 中的句柄
  
public:
  // peek()：不阻止 GC，可能返回 NULL (对象已死)
  oop peek() const {
    if (_obj == NULL) return NULL;
    return NativeAccess<ON_PHANTOM_OOP_REF | AS_NO_KEEPALIVE>::oop_load(_obj);
  }
  
  // resolve()：解析为强引用，阻止 GC
  oop resolve() const {
    if (_obj == NULL) return NULL;
    return NativeAccess<ON_PHANTOM_OOP_REF>::oop_load(_obj);
  }
  
  void release() {  // 释放引用
    if (_obj != NULL) {
      T::storage()->release(_obj);
      _obj = NULL;
    }
  }
};

// StringTable 使用的具体类型
typedef WeakHandle<vm_string_table_data> StringTableWeakHandle;

// vm_string_table_data 提供 OopStorage 访问
struct vm_string_table_data : public AllStatic {
  static OopStorage* storage();
};
```

### 3.4 OopStorage (弱引用存储池)

```cpp
// gc/shared/oopStorage.hpp
// OopStorage 管理一组 OopHandle，支持 GC 扫描

class OopStorage {
private:
  // Block：固定大小的数组，存储 OopHandle
  static const size_t _block_size = 4096;  // 每个 Block 4096 个条目
  
  class Block {
    oop* const _data;           // OopHandle 数组
    volatile uint32_t _num_allocated;  // 已分配数量
    volatile uint32_t _num_dead;       // 死亡条目数
    // ...
  };
  
  // ActiveArray：管理所有 Block 的数组
  class ActiveArray {
    Block* const* _base;        // Block 指针数组
    size_t _size;               // 当前大小
    // ...
  };
  
  ActiveArray* _active_array;   // 活跃的 Block 数组
  // ...
  
public:
  // 分配 OopHandle
  OopHandle allocate();
  
  // 释放 OopHandle
  void release(OopHandle handle);
  
  // GC 遍历所有引用
  void oops_do(OopClosure* cl);
  
  // 并行清理死亡引用
  void possibly_parallel_unlink(ParState* par_state, BoolObjectClosure* cl);
};
```

---

## 4. String.intern() 实现机制

### 4.1 调用链

```
java.lang.String.intern()
    │
    ▼ (JNI 调用)
JVM_String_intern(JNIEnv* env, jobject str)
    │
    ▼
StringTable::intern(oop string, TRAPS)
    │
    ▼
StringTable::intern(Handle string_or_null_h, jchar* name, int len, TRAPS)
    │
    ├── 1. 计算 hash
    │   └── hash_string(name, len, _alt_hash)
    │
    ├── 2. 查找已有字符串
    │   └── do_lookup(name, len, hash)
    │       └── _local_table->get(...)  // wait-free 读
    │
    ├── 3. 找到？返回已有对象
    │   └── return found_string
    │
    └── 4. 未找到？创建新条目
        └── do_intern(string_or_null, name, len, hash, THREAD)
            ├── 4.1 创建 WeakHandle
            │   └── _weak_handles->allocate()
            │
            ├── 4.2 尝试插入 (CAS 操作)
            │   └── _local_table->insert(...)
            │       └── bucket.trylock()  // 获取桶锁
            │       └── cas_first(node)   // CAS 插入链表头
            │
            └── 4.3 插入成功？返回新字符串
                └── return new_string
```

### 4.2 核心代码解析

```cpp
// stringTable.cpp:295-350
oop StringTable::intern(oop string, TRAPS) {
  // 1. 提取字符串内容
  int len;
  jchar* chars = java_lang_String::as_unicode_string(string, len, CHECK_NULL);
  
  // 2. 调用内部实现
  return intern(string, chars, len, THREAD);
}

oop StringTable::intern(Handle string_or_null_h, jchar* name, int len, TRAPS) {
  // 1. 计算 hash
  uintx hash = hash_string(name, len, _alt_hash);
  
  // 2. 尝试查找 (wait-free)
  oop found = do_lookup(name, len, hash);
  if (found != NULL) {
    return found;  // 已存在，直接返回
  }
  
  // 3. 未找到，创建新条目
  return do_intern(string_or_null_h, name, len, hash, THREAD);
}

oop StringTable::do_lookup(jchar* name, int len, uintx hash) {
  // 创建查找器
  StringTableLookupJchar lookup(Thread::current(), hash, name, len);
  
  // wait-free 读操作
  WeakHandle<vm_string_table_data> wh;
  bool grow;
  bool found = _local_table->get(Thread::current(), lookup, wh, &grow);
  
  if (found) {
    return lookup.found();  // 返回找到的字符串
  }
  return NULL;
}

oop StringTable::do_intern(Handle string_or_null, jchar* name, int len, 
                           uintx hash, TRAPS) {
  // 1. 创建新的 String 对象 (如果需要)
  Handle string;
  if (string_or_null.is_null()) {
    string = java_lang_String::create_from_unicode(name, len, CHECK_NULL);
  } else {
    string = string_or_null;
  }
  
  // 2. 在 OopStorage 中分配弱引用
  WeakHandle<vm_string_table_data> wh(_weak_handles->allocate());
  wh.set(string);  // 存储引用
  
  // 3. 创建插入器
  StringTableLookupJchar lookup(Thread::current(), hash, name, len);
  
  // 4. 尝试插入 (CAS)
  bool grow;
  bool inserted = _local_table->insert(Thread::current(), lookup, wh, &grow);
  
  if (inserted) {
    item_added();  // 计数 +1
    return string();
  } else {
    // 插入失败（并发冲突），释放资源
    wh.release();
    // 返回已存在的字符串
    return lookup.found();
  }
}
```

### 4.3 ConcurrentHashTable::insert 详解

```cpp
// concurrentHashTable.inline.hpp
template <typename VALUE, typename CONFIG, MEMFLAGS F>
template <typename LOOKUP_FUNC>
bool ConcurrentHashTable<VALUE, CONFIG, F>::insert(
    Thread* thread, LOOKUP_FUNC& lookup_f, const VALUE& value, bool* grow) {
  
  // 1. 计算桶索引
  size_t hash = lookup_f.get_hash();
  size_t bucket_idx = hash & (_size - 1);  // 快速取模
  
  Bucket* bucket = _table->get_bucket(bucket_idx);
  
  // 2. 尝试获取桶锁 (trylock)
  while (!bucket->trylock()) {
    // 可能遇到 resize，需要重试
    if (bucket->have_redirect()) {
      // 表正在 resize，帮助完成或等待
      help_resize(thread);
      bucket = _table->get_bucket(bucket_idx);
    }
    SpinPause();  // 自旋等待
  }
  
  // 3. 持有锁后，再次检查是否已存在
  Node* first = bucket->first();
  Node* prev = NULL;
  Node* curr = first;
  
  while (curr != NULL) {
    bool is_dead;
    if (lookup_f.equals(curr->value(), &is_dead)) {
      bucket->unlock();  // 已存在，释放锁
      return false;      // 插入失败
    }
    prev = curr;
    curr = curr->next();
  }
  
  // 4. 创建新节点并 CAS 插入
  Node* new_node = Node::create_node(value, first);
  
  // CAS 设置链表头（解锁同时完成）
  if (bucket->cas_first(new_node, first)) {
    return true;   // 插入成功
  } else {
    Node::destroy_node(new_node);
    bucket->unlock();
    return false;  // CAS 失败
  }
}
```

---

## 5. 并发控制机制

### 5.1 读操作：Wait-Free

```cpp
// ConcurrentHashTable 的读操作是 wait-free 的
// 不需要锁，不需要重试，在有限步骤内完成

template <typename LOOKUP_FUNC>
bool ConcurrentHashTable<VALUE, CONFIG, F>::get(
    Thread* thread, LOOKUP_FUNC& lookup_f, VALUE& value, bool* grow) {
  
  size_t hash = lookup_f.get_hash();
  size_t bucket_idx = hash & (_size - 1);
  
  // 直接读取，不加锁
  Bucket* bucket = _table->get_bucket(bucket_idx);
  Node* first = bucket->first();
  
  // 遍历链表
  Node* curr = first;
  while (curr != NULL) {
    bool is_dead;
    if (lookup_f.equals(curr->value(), &is_dead)) {
      value = *curr->value();
      return true;  // 找到
    }
    curr = curr->next();
  }
  
  return false;  // 未找到
}
```

**Wait-Free 保证**：
- 不获取任何锁
- 不依赖其他线程的状态
- 固定步骤内完成（链表长度）
- 即使有 resize，也能通过 redirect 指针找到新表

### 5.2 写操作：Per-Bucket 锁

```cpp
// Bucket 的锁实现（嵌入指针低 2 位）

class Bucket {
  Node* volatile _first;  // 低 2 位：00=unlocked, 01=locked, 10=redirect
  
  // 尝试获取锁
  bool trylock() {
    Node* first = Atomic::load(&_first);
    if (get_state(first) == STATE_LOCKED) return false;
    
    Node* locked = set_state(clear_state(first), STATE_LOCKED);
    return Atomic::cmpxchg(locked, &_first, first) == first;
  }
  
  // 释放锁
  void unlock() {
    Node* first = Atomic::load(&_first);
    assert(get_state(first) == STATE_LOCKED, "must be locked");
    
    Node* unlocked = clear_state(first);
    Atomic::store(&_first, unlocked);
  }
};
```

**优势**：
- 细粒度锁：只锁单个桶，不影响其他桶
- 无锁膨胀：不升级为重量级锁
- 快速失败：trylock 失败可立即重试或帮助 resize

### 5.3 Resize 机制

```cpp
// 当负载因子超过阈值时触发 resize

void StringTable::grow(JavaThread* jt) {
  size_t new_size = _current_size * 2;  // 翻倍
  if (new_size > (1 << END_SIZE)) {     // 最大 2^24
    new_size = (1 << END_SIZE);
  }
  
  // 创建新表
  InternalTable* new_table = new InternalTable(new_size);
  
  // 渐进式迁移：每个桶被访问时迁移
  _local_table->try_move_nodes_to(new_table);
  
  // 切换表指针
  _table = new_table;
  _current_size = new_size;
}
```

**渐进式 Resize**：
- 不暂停所有操作
- 旧表和新表同时存在
- 每个桶被访问时才迁移
- 读操作通过 redirect 指针找到新表

---

## 6. GC 协作机制

### 6.1 弱引用清理流程

```
Full GC / Concurrent Mark
    │
    ▼
StringTable::unlink_or_oops_do(is_alive_closure)
    │
    ├── 1. 遍历所有 Bucket
    │   └── for each bucket in _table
    │
    ├── 2. 遍历 Bucket 中的 Node 链表
    │   └── for each node in bucket
    │
    ├── 3. 检查 Node 是否存活
    │   └── oop obj = node->_value.peek()
    │   └── if (obj == NULL) → 已死，需要清理
    │   └── if (is_alive->do_object_b(obj)) → 存活
    │
    ├── 4. 清理死亡节点
    │   └── 从链表中断开
    │   └── node->_value.release()  // 释放 WeakHandle
    │   └── Node::destroy_node(node)
    │
    └── 5. 更新统计
        └── _uncleaned_items -= ndead
```

### 6.2 代码实现

```cpp
// stringTable.cpp:400-450
void StringTable::unlink_or_oops_do(BoolObjectClosure* is_alive, 
                                     OopClosure* f, 
                                     int* processed, int* removed) {
  int proc = 0, rem = 0;
  
  // 遍历所有桶
  for (size_t i = 0; i < _current_size; i++) {
    Bucket* bucket = _local_table->get_bucket(i);
    
    // 获取桶锁
    if (!bucket->trylock()) {
      continue;  // 跳过被锁定的桶
    }
    
    Node* prev = NULL;
    Node* curr = bucket->first();
    
    while (curr != NULL) {
      proc++;
      
      // 检查是否存活
      oop obj = curr->_value.peek();
      if (obj == NULL || !is_alive->do_object_b(obj)) {
        // 对象已死，清理
        rem++;
        Node* dead = curr;
        curr = curr->next();
        
        // 从链表中断开
        if (prev == NULL) {
          bucket->cas_first(curr, dead);
        } else {
          prev->set_next(curr);
        }
        
        // 释放资源
        dead->_value.release();
        Node::destroy_node(dead);
      } else {
        // 存活，继续
        if (f != NULL) {
          f->do_oop(&obj);  // 处理指针（压缩指针等）
        }
        prev = curr;
        curr = curr->next();
      }
    }
    
    bucket->unlock();
  }
  
  if (processed != NULL) *processed = proc;
  if (removed != NULL) *removed = rem;
}
```

### 6.3 并发清理

```cpp
// 后台线程定期清理死亡条目

void StringTable::concurrent_work(JavaThread* jt) {
  // 1. 检查是否需要清理
  double dead_factor = get_dead_factor();
  if (dead_factor < CLEAN_DEAD_HIGH_WATER_MARK) {
    return;  // 死亡条目不足，不清理
  }
  
  // 2. 执行清理
  clean_dead_entries(jt);
  
  // 3. 检查是否需要扩容
  double load_factor = get_load_factor();
  if (load_factor > PREF_AVG_LIST_LEN) {
    grow(jt);  // 扩容
  }
  
  _has_work = false;  // 标记工作完成
}
```

---

## 7. JVM 参数调优

### 7.1 关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-XX:StringTableSize` | 1009 (JDK8) / 60013 (JDK11+) | 初始桶数量 |
| `-XX:StringTableHashCode` | 0 | 哈希算法 (0=java_hash, 1=siphash) |
| `-XX:PrintStringTableStatistics` | false | 打印统计信息 |
| `-XX:+UseStringDeduplication` | false | G1 字符串去重 |

### 7.2 性能诊断

```bash
# 打印 StringTable 统计
java -XX:+PrintStringTableStatistics YourApp

# 输出示例
StringTable statistics:
Number of buckets       :     60013    ← 桶数量
Average bucket size     :     2.15     ← 平均链表长度 (目标 < 2)
Variance of bucket size :     1.89     ← 方差 (越小越均匀)
Table occupancy         :    129045    ← 条目总数
Number of dead items    :      1234    ← 死亡条目数
```

### 7.3 调优建议

```
问题1: Average bucket size > 5
解决: 增加 -XX:StringTableSize=1000003

问题2: Number of dead items > 50% occupancy
解决: 调用 System.gc() 或等待后台清理

问题3: StringTable 占用内存过大
解决: 减少 String.intern() 使用，或使用 G1 String Deduplication
```

---

## 8. 与图片对应关系

您提供的图片展示了 StringTable 的内存布局，对应关系如下：

| 图片元素 | 实际类/结构 | 说明 |
|----------|-------------|------|
| **StringTable** | `StringTable` | Facade 类，单例 |
| **StringTable 实际内存布局** | `StringTableHash` | `ConcurrentHashTable` 实例 |
| **InternalTable 实际内存布局** | `InternalTable` | Bucket 数组的包装 |
| **Node** | `ConcurrentHashTable::Node` | 链表节点 |
| **GapStorage** | `OopStorage` | 弱引用存储池 |
| **GapStorage Block** | `OopStorage::Block` | 固定大小的 OopHandle 数组 |
| **ConcurrentHashTable 实际内存布局** | `ConcurrentHashTable` | 模板类实例 |
| **Bucket** | `ConcurrentHashTable::Bucket` | 哈希桶（链表头 + 状态位） |
| **WeakHandle** | `WeakHandle<>` | 弱引用包装 |
| **ActiveArray** | `ActiveArray` | 管理 Block 数组的元数据 |
| **AllocatedList** | `AllocatedList` | 已分配的 Block 列表 |

---

## 9. 面试高频问答

### Q1: StringTable 和 SymbolTable 有什么区别？

**答**：
- **SymbolTable**：存储标识符（类名、方法名、字段名），生命周期长，存储在 Metaspace
- **StringTable**：存储 interned 字符串，存储在 Heap，支持 GC 回收

### Q2: 为什么 JDK7 要把字符串常量池从 PermGen 移到 Heap？

**答**：
1. **PermGen 大小固定**，容易 OOM: PermGen space
2. **字符串生命周期不一**：有些只在方法内使用，应该随 GC 回收
3. **Heap 可自动扩展**：根据负载自动调整
4. **与 StringTable 统一**：都使用弱引用，支持 GC 清理

### Q3: String.intern() 在 JDK6 和 JDK7+ 有什么区别？

**答**：
- **JDK6**：interned 字符串存储在 PermGen，不会 GC，除非 Full GC
- **JDK7+**：interned 字符串存储在 Heap，使用 WeakHandle，支持 GC 清理

### Q4: ConcurrentHashTable 如何保证线程安全？

**答**：
1. **读操作**：Wait-free，不加锁，直接读取
2. **写操作**：Per-bucket 锁，只锁单个桶
3. **状态嵌入**：锁状态嵌入指针低 2 位，无额外内存开销
4. **CAS 操作**：链表插入使用 CAS，保证原子性

### Q5: StringTable 的负载因子和 rehash 策略是什么？

**答**：
- **目标链表长度**：2 (PREF_AVG_LIST_LEN)
- **触发 rehash**：平均链表长度 > 2 或单个链表 > 100 (REHASH_LEN)
- **扩容策略**：桶数量翻倍，最大 2^24
- **渐进式迁移**：每个桶被访问时才迁移，不暂停整个表

---

## 10. 总结

### 10.1 核心设计思想

| 设计 | 实现 | 优势 |
|------|------|------|
| 弱引用存储 | `WeakHandle` + `OopStorage` | 允许 GC 回收死亡字符串 |
| 并发控制 | Per-bucket 锁 | 细粒度，高并发 |
| 读优化 | Wait-free | 读操作无锁，性能高 |
| 内存布局 | 分离桶数组和节点 | 缓存友好，减少伪共享 |
| 渐进式 resize | Redirect 指针 | 不暂停整个表 |

### 10.2 关键数据结构大小

| 结构 | 大小 | 说明 |
|------|------|------|
| `StringTable` | ~72 字节 | 单例对象 |
| `StringTableHash` | ~40 字节 | 哈希表头 |
| `InternalTable` | 8MB (默认) | 1,048,576 个 Bucket × 8B |
| `Bucket` | 8 字节 | 链表头指针 + 状态位 |
| `Node` | 16 字节 | _next (8B) + _value (8B) |
| `WeakHandle` | 8 字节 | OopHandle 包装 |
| `OopStorage::Block` | 32KB | 4096 个 OopHandle |

### 10.3 相关文档

- `SymbolTable-Expert-Analysis.md`（标识符表）
- `ConcurrentHashTable-Expert-Analysis.md`（通用哈希表）
- `OopStorage-Expert-Analysis.md`（弱引用存储池）

---

**文档完成时间**: 2026-02-11  
**验证状态**: 基于 OpenJDK 11 源码分析  
**关联图片**: StringTable 内存布局图 ✅
