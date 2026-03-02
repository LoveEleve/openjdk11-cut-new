# ConcurrentHashTable 整体架构与设计哲学

> **源码位置**: `src/hotspot/share/utilities/concurrentHashTable.hpp/.inline.hpp`  
> **代码规模**: ~1800 行  
> **JDK 版本**: OpenJDK 11+  
> **分析时间**: 2026-02-11  
> **文档级别**: 专家级深度分析

---

## 1. 问题引入：为什么需要 ConcurrentHashTable？

### 1.1 HotSpot 的并发需求

在 JVM 内部，有多个全局哈希表需要支持高并发访问：

```
StringTable      - 存储 interned 字符串    (读多写少)
SymbolTable      - 存储标识符             (读多写少)
ThreadIdTable    - 存储线程 ID 映射       (读写均衡)
MethodCounters   - 存储方法计数器         (高并发写)
```

**核心挑战**:
- **读操作极其频繁**: 每次类加载都要查 SymbolTable
- **不能阻塞**: GC 路径不能长时间停顿
- **内存敏感**: JVM 内部，内存开销要尽可能小
- **自定义行为**: 需要支持弱引用、自定义分配策略

### 1.2 为什么不用现成的方案？

| 方案 | 问题 | 结论 |
|------|------|------|
| **JDK ConcurrentHashMap** | 1. Java 对象，C++ 无法直接用<br>2. 对象头开销大（16+ 字节）<br>3. 不支持自定义内存管理 | ❌ 不适用 |
| **std::unordered_map** | 1. 需要全局锁<br>2. 迭代器失效问题<br>3. 无法渐进式扩容 | ❌ 不适用 |
| **Folly ConcurrentHashMap** | 1. 依赖 Folly 库<br>2. 与 HotSpot 内存管理不兼容 | ❌ 不适用 |
| **自己实现** | 工作量大，需要严谨的并发设计 | ✅ 必须做 |

### 1.3 设计目标

```
┌─────────────────────────────────────────────────────────────────┐
│                    ConcurrentHashTable 设计目标                  │
├─────────────────────────────────────────────────────────────────┤
│ 1. Wait-Free 读操作    → 读永远不阻塞，GC 路径安全               │
│ 2. Per-bucket 写锁     → 最大化写并发度                         │
│ 3. 渐进式扩容          → 无全局停顿                            │
│ 4. 内存高效            → 指针位复用，缓存对齐                    │
│ 5. 模板化设计          → 零开销抽象，类型安全                    │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. 整体架构概览

### 2.1 类层次结构

```
ConcurrentHashTable<VALUE, CONFIG, F>  [模板类]
│
├── 模板参数
│   ├── VALUE  → 存储值类型 (如 WeakHandle<>, Symbol*)
│   ├── CONFIG → 策略配置类 (哈希函数、分配器、比较器)
│   └── F      → 内存标记 (mtSymbol, mtGC, mtInternal)
│
├── 内部数据结构
│   ├── class Node              → 链表节点
│   ├── class Bucket            → 哈希桶（链表头 + 状态位）
│   ├── class InternalTable     → Bucket 数组管理
│   └── class ActiveArray       → Resize 时的表切换
│
├── 核心操作接口
│   ├── get()       → Wait-Free 读取
│   ├── insert()    → CAS 插入
│   ├── remove()    → Per-bucket 锁删除
│   └── resize()    → 渐进式扩容
│
└── 批量操作任务
    ├── BulkDeleteTask  → GC 批量清理
    └── GrowTask        → 扩容任务
```

### 2.2 核心设计理念

#### 理念 1: 指针位复用（Pointer Packing）

```cpp
// Bucket 类定义
class Bucket {
    Node* volatile _first;  // 低 2 位复用！
    
    // 00 = unlocked      (无锁)
    // 01 = locked        (被某个线程锁定)
    // 10 = redirect      (指向新表，旧表正在迁移)
    // 11 = reserved      (保留)
};
```

**优势**:
- 节省 8 字节（无需单独的锁变量）
- 缓存友好（减少内存访问）
- 原子操作保证（CAS 整个指针）

#### 理念 2: Wait-Free vs Lock-Free

```
Lock-Free:
  保证系统整体进度，但单个线程可能饿死
  例如：CAS 一直失败，需要重试

Wait-Free:
  保证每个线程都有进度，操作在有限步骤完成
  例如：get() 操作最多遍历链表长度次

ConcurrentHashTable::get() 是 Wait-Free 的：
  - 不获取锁
  - 不重试
  - 步骤有上界
```

#### 理念 3: 渐进式 Resize

```
传统 Resize:
  1. 分配新数组
  2. 遍历旧表所有条目
  3. 迁移到新表
  4. 切换指针
  → 全局停顿，时间复杂度 O(n)

渐进式 Resize:
  1. 分配新数组
  2. 按需迁移：访问到哪个 Bucket 才迁移
  3. Redirect 指针：旧 Bucket 指向新 Bucket
  4. 多线程帮助迁移
  → 无全局停顿，摊还时间复杂度 O(1)
```

---

## 3. 核心数据结构详解

### 3.1 Node - 链表节点

```cpp
// concurrentHashTable.hpp:41-69
template <typename VALUE, typename CONFIG, MEMFLAGS F>
class ConcurrentHashTable : public CHeapObj<F> {
 private:
  class Node {
   private:
    Node* volatile _next;  // 链表指针
    VALUE _value;          // 存储的值
    
   public:
    Node(const VALUE& value, Node* next = NULL)
      : _next(next), _value(value) {
      // 确保 16 字节对齐（低 4 位为 0，方便位操作）
      assert((((uintptr_t)this) & ((uintptr_t)0x3)) == 0,
             "Must 16 bit aligned.");
    }
    
    Node* next() const { return _next; }
    void set_next(Node* node) { _next = node; }
    VALUE* value() { return &_value; }
    
    // Placement new 创建节点
    static Node* create_node(const VALUE& value, Node* next = NULL) {
      void* mem = CONFIG::allocate_node(sizeof(Node), value);
      return new (mem) Node(value, next);
    }
    
    static void destroy_node(Node* node) {
      CONFIG::free_node((void*)node, node->_value);
    }
  };
};
```

**内存布局**:
```
Node (16 字节，对齐到 16 字节)
┌────────────────┬────────────────┐
│   _next (8B)   │  _value (8B)   │
│   链表指针      │   存储的值      │
│   低 2 位 = 00  │   WeakHandle   │
└────────────────┴────────────────┘
```

### 3.2 Bucket - 哈希桶（核心创新）

```cpp
// concurrentHashTable.hpp:73-161
class Bucket {
 private:
  Node* volatile _first;  // 链表头 + 嵌入状态
  
  static const uintptr_t STATE_LOCK_BIT     = 0x1;  // 01
  static const uintptr_t STATE_REDIRECT_BIT = 0x2;  // 10
  static const uintptr_t STATE_MASK         = 0x3;  // 11
  
  // 获取纯指针（清除状态位）
  Node* first_raw() const {
    return (Node*)(((uintptr_t)_first) & (~STATE_MASK));
  }
  
  // 检查状态
  static bool is_state(Node* node, uintptr_t bits) {
    return (bits & (uintptr_t)node) == bits;
  }
  
  static uintptr_t get_state(Node* node) {
    return (((uintptr_t)node) & STATE_MASK);
  }
  
 public:
  // 获取链表头（清除状态位）
  Node* first() const {
    return clear_state(_first);
  }
  
  // 尝试获取锁
  bool trylock() {
    Node* first = Atomic::load(&_first);
    if (get_state(first) != 0) return false;  // 已被锁或 redirect
    
    Node* locked = (Node*)((uintptr_t)first | STATE_LOCK_BIT);
    return Atomic::cmpxchg(locked, &_first, first) == first;
  }
  
  // 释放锁
  void unlock() {
    Node* first = Atomic::load(&_first);
    assert(get_state(first) == STATE_LOCK_BIT, "Must be locked");
    Node* unlocked = (Node*)((uintptr_t)first & ~STATE_MASK);
    Atomic::store(&_first, unlocked);
  }
  
  // CAS 设置链表头（同时释放锁）
  bool cas_first(Node* node, Node* expect) {
    return Atomic::cmpxchg(node, &_first, expect) == expect;
  }
  
  // 是否有 redirect 标记
  bool have_redirect() const {
    return is_state(_first, STATE_REDIRECT_BIT);
  }
  
  // 设置 redirect（必须先持有锁）
  void redirect() {
    assert(is_locked(), "Must be locked");
    Node* redirect_node = (Node*)((uintptr_t)_first | STATE_REDIRECT_BIT);
    Atomic::store(&_first, redirect_node);
  }
};
```

**状态转换图**:
```
          trylock()              unlock()
UNLOCKED ─────────→ LOCKED ─────────→ UNLOCKED
    │                    │
    │ redirect()         │ redirect()
    │                    ▼
    └──────────────→ REDIRECT (终态)
```

### 3.3 InternalTable - Bucket 数组管理

```cpp
// concurrentHashTable.hpp:168-185
class InternalTable : public CHeapObj<F> {
 private:
  Bucket* _buckets;           // Bucket 数组指针
  
 public:
  const size_t _log2_size;    // 大小 = 2^_log2_size
  const size_t _size;         // 实际大小
  const size_t _hash_mask;    // 哈希掩码 = _size - 1
  
  InternalTable(size_t log2_size) 
    : _log2_size(log2_size),
      _size((size_t)1 << log2_size),
      _hash_mask(_size - 1) {
    // 分配 Bucket 数组，对齐到缓存行
    _buckets = NEW_C_HEAP_ARRAY(Bucket, _size, F);
    for (size_t i = 0; i < _size; i++) {
      new (&_buckets[i]) Bucket();  // Placement new 初始化
    }
  }
  
  ~InternalTable() {
    FREE_C_HEAP_ARRAY(Bucket, _buckets);
  }
  
  Bucket* get_bucket(size_t idx) {
    assert(idx < _size, "Index out of bounds");
    return &_buckets[idx];
  }
};
```

**为什么大小是 2 的幂次？**
```
计算桶索引: idx = hash & (size - 1)

如果 size = 2^n，则 size - 1 = 0b111...111 (n 个 1)
hash & (size - 1) = 取 hash 的低 n 位

这比取模运算 (hash % size) 快得多！
```

### 3.4 ActiveArray - Resize 表管理

```cpp
// concurrentHashTable.hpp:220-280 (简化)
class ActiveArray : public CHeapObj<F> {
 private:
  InternalTable* _table;           // 当前活跃的表
  volatile bool _has_new_table;    // 是否有新表正在 resize
  InternalTable* _new_table;       // 新表（resize 目标）
  
 public:
  // 获取当前表
  InternalTable* get() {
    return Atomic::load(&_table);
  }
  
  // 替换表（resize 完成后）
  void set(InternalTable* table) {
    Atomic::store(&_table, table);
  }
  
  // 开始 resize
  void start_resize(InternalTable* new_table) {
    _new_table = new_table;
    _has_new_table = true;
  }
  
  // 获取新表
  InternalTable* get_new_table() {
    return _has_new_table ? _new_table : NULL;
  }
};
```

---

## 4. 内存布局全景图

### 4.1 整体布局

```
┌──────────────────────────────────────────────────────────────────────┐
│                    ConcurrentHashTable 内存布局                       │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │              ConcurrentHashTable (模板实例)                      │ │
│  │  - _active_array: ActiveArray*                                  │ │
│  │  - _size: size_t (当前大小)                                     │ │
│  │  - _resize_lock: Monitor* (resize 全局锁)                       │ │
│  └─────────────────────────┬──────────────────────────────────────┘ │
│                            │                                         │
│                            ▼                                         │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                    ActiveArray                                  │ │
│  │  ┌──────────────────────────────────────────────────────────┐  │ │
│  │  │  _table ───────→ InternalTable (当前表)                  │  │ │
│  │  │  _has_new_table: false                                    │  │ │
│  │  │  _new_table: NULL                                         │  │ │
│  │  └──────────────────────────────────────────────────────────┘  │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                            │                                         │
│                            ▼                                         │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                    InternalTable                                │ │
│  │  _buckets ───────────────────────────────────────────────┐     │ │
│  │  _log2_size = 20  (size = 1,048,576)                     │     │ │
│  │  _hash_mask = 0xFFFFF                                    │     │ │
│  └──────────────────────────────────────────────────────────┼─────┘ │
│                                                             │        │
│                             ▼                               │        │
│  ┌──────────────────────────────────────────────────────────┴─────┐ │
│  │                    Bucket Array (1,048,576 个)                  │ │
│  │  ┌─────┬─────┬─────┬─────┬─────┬─────────┬─────────────────┐   │ │
│  │  │ B0  │ B1  │ B2  │ B3  │ B4  │  ...    │ B[1,048,575]    │   │ │
│  │  │(8B) │(8B) │(8B) │(8B) │(8B) │         │    (8B)         │   │ │
│  │  └─┬───┴─┬───┴─┬───┴─┬───┴─┬───┴─────────┴─────────────────┘   │ │
│  │    │     │     │     │     │                                    │ │
│  │    ▼     ▼     ▼     ▼     ▼                                    │ │
│  │  ┌─────┐ ┌─────┐ ┌─────┐ NULL  ┌─────┐                          │ │
│  │  │Node │ │Node │ │Node │       │Node │                          │ │
│  │  │(16B)│ │(16B)│ │(16B)│       │(16B)│                          │ │
│  │  └──┬──┘ └──┬──┘ └──┬──┘       └──┬──┘                          │ │
│  │     │       │       │             │                             │ │
│  │     ▼       ▼       NULL          ▼                             │ │
│  │   ┌─────┐ ┌─────┐               ┌─────┐                         │ │
│  │   │Node │ │Node │               │Node │                         │ │
│  │   │(16B)│ │(16B)│               │(16B)│                         │ │
│  │   └─────┘ └─────┘               └─────┘                         │ │
│  └─────────────────────────────────────────────────────────────────┘ │
│                                                                      │
│  内存占用估算 (默认 1M 个桶):                                          │
│  - Bucket 数组: 1,048,576 × 8B = 8MB                                 │
│  - Node 节点: ~500KB (假设 30,000 个节点)                            │
│  - 其他结构: ~1KB                                                    │
│  - 总计: ~8.5MB                                                      │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 4.2 缓存行对齐（False Sharing 避免）

```cpp
// 问题：如果两个 Bucket 在同一个缓存行，
//       线程 A 修改 Bucket0，会导致线程 B 的 Bucket1 缓存失效

// 解决方案：确保每个 Bucket 独占一个缓存行

#ifdef _LP64
  // 64 位系统，缓存行通常是 64 字节
  #define DEFAULT_CACHE_LINE_SIZE 64
#else
  #define DEFAULT_CACHE_LINE_SIZE 32
#endif

// Bucket 已经是指针大小（8 字节），自然对齐
// 但如果是更大的结构，需要显式填充

// 示例：如果 Bucket 有额外字段
class Bucket {
  Node* volatile _first;
  char _pad[DEFAULT_CACHE_LINE_SIZE - sizeof(Node*)];  // 填充到 64 字节
};
```

---

## 5. 模板配置与 CRTP 设计

### 5.1 CONFIG 模板参数

```cpp
// 使用示例：StringTableConfig
class StringTableConfig : public StringTableHash::BaseConfig {
 public:
  // 1. 哈希函数
  static uintx get_hash(WeakHandle<vm_string_table_data> const& value,
                        bool* is_dead) {
    oop val_oop = value.peek();
    if (val_oop == NULL) {
      *is_dead = true;
      return 0;
    }
    *is_dead = false;
    
    // 计算字符串哈希
    int length;
    jchar* chars = java_lang_String::as_unicode_string(val_oop, length);
    return hash_string(chars, length, StringTable::_alt_hash);
  }
  
  // 2. 节点分配
  static void* allocate_node(size_t size, 
                             WeakHandle<vm_string_table_data> const& value) {
    StringTable::item_added();  // 计数 +1
    return AllocateHeap(size, mtSymbol);  // CHeap 分配
  }
  
  // 3. 节点释放
  static void free_node(void* memory,
                        WeakHandle<vm_string_table_data> const& value) {
    value.release();  // 释放 WeakHandle
    FreeHeap(memory);
    StringTable::item_removed();  // 计数 -1
  }
};

// 类型定义
typedef ConcurrentHashTable<WeakHandle<vm_string_table_data>,
                            StringTableConfig, 
                            mtSymbol> StringTableHash;
```

### 5.2 CRTP（Curiously Recurring Template Pattern）

```cpp
// BaseConfig 提供默认实现
struct BaseConfig {
  // 默认使用 CONFIG 的 get_hash
  static uintx get_hash(const VALUE& value, bool* dead) {
    return CONFIG::get_hash(value, dead);
  }
  
  // 默认分配：使用 CHeap
  static void* allocate_node(size_t size, const VALUE& value) {
    return AllocateHeap(size, F);
  }
  
  // 默认释放
  static void free_node(void* memory, const VALUE& value) {
    FreeHeap(memory);
  }
};

// CONFIG 继承 BaseConfig，可以覆盖方法
class MyConfig : public ConcurrentHashTable<MyValue, MyConfig, mtGC>::BaseConfig {
  // 覆盖哈希函数
  static uintx get_hash(const MyValue& value, bool* dead) {
    return custom_hash(value);
  }
};
```

**CRTP 优势**:
1. **零开销抽象**：编译时多态，无虚函数开销
2. **类型安全**：编译期检查配置接口
3. **灵活定制**：覆盖需要的部分，复用默认实现

---

## 6. 与 JDK ConcurrentHashMap 对比

| 特性 | HotSpot CHT | JDK CHM |
|------|-------------|---------|
| **实现语言** | C++ | Java |
| **读操作** | **Wait-Free** | Lock-Free |
| **写操作** | Per-bucket 锁 | 分段锁 (Segment) |
| **Resize** | 渐进式 + Help Resize | 渐进式 |
| **锁实现** | 指针位复用 + CAS | ReentrantLock |
| **内存管理** | CHeap + 自定义分配 | Java 堆 + GC |
| **对象开销** | 16 字节/Node | ~32 字节/Node |
| **适用场景** | JVM 内部高频读 | 通用 Java 并发 |

**为什么 CHT 读更快？**
```
CHT get():
  1. 读取表指针 (Atomic::load)
  2. 计算桶索引 (hash & mask)
  3. 遍历链表 (最多 2-3 个节点)
  → 无锁，无重试，步骤固定

CHM get():
  1. 读取 Segment 数组
  2. 计算 Segment 索引
  3. 获取 Segment 锁或 volatile 读
  4. 计算桶索引
  5. 遍历链表
  → 需要 volatile 读保证可见性
```

---

## 7. 面试高频问答

### Q1: ConcurrentHashTable 的 Bucket 锁是如何实现的？

**答**：通过**指针位复用**实现。Bucket 只有一个成员 `_first`（Node*），它的低 2 位被复用来存储状态：
- `00` = unlocked
- `01` = locked
- `10` = redirect

上锁通过 CAS 操作：`cas_first(locked_ptr, unlocked_ptr)`

### Q2: 什么是 Wait-Free？ConcurrentHashTable 的哪个操作是 Wait-Free 的？

**答**：Wait-Free 是指操作在**有限步骤内完成**，不依赖其他线程的状态。

`get()` 操作是 Wait-Free 的：
- 不获取锁
- 不重试
- 最多遍历链表长度次（有上界）

### Q3: ConcurrentHashTable 如何处理 Resize？

**答**：使用**渐进式 Resize**：
1. 创建新表（大小翻倍）
2. 访问到旧 Bucket 时，帮助迁移数据到新表
3. 旧 Bucket 标记为 redirect，指向新 Bucket
4. 所有线程帮助迁移，分散开销
5. 旧表延迟释放

### Q4: 为什么删除操作需要锁，而插入可以用 CAS？

**答**：
- **插入**：只需要修改链表头（`_first`），可以用 CAS
- **删除**：需要修改中间节点的 `_next` 指针，必须持锁保证安全

### Q5: CONFIG 模板参数的作用是什么？

**答**：使用 **CRTP 模式**实现策略配置：
- `get_hash()`：自定义哈希函数
- `allocate_node()`：自定义内存分配
- `free_node()`：自定义资源释放

零运行时开销，编译期多态。

---

## 8. 总结

### 8.1 核心设计要点

| 设计 | 实现 | 价值 |
|------|------|------|
| **指针位复用** | 低 2 位存状态 | 省内存，缓存友好 |
| **Wait-Free 读** | 无锁快照 | GC 路径不阻塞 |
| **Per-bucket 锁** | 细粒度并发 | 最大化写并发 |
| **渐进式 Resize** | 按需迁移 | 无全局停顿 |
| **CRTP 配置** | 模板策略 | 零开销定制 |

### 8.2 关键内存大小

| 结构 | 大小 | 说明 |
|------|------|------|
| `ConcurrentHashTable` | ~40 字节 | 模板实例 |
| `InternalTable` | 8MB | 1M 个 Bucket |
| `Bucket` | 8 字节 | 指针 + 状态 |
| `Node` | 16 字节 | _next + _value |

### 8.3 下一步预告

**文档 2** 将深入分析核心算法：
- `get()` - Wait-Free 读的具体实现
- `insert()` - CAS 插入的详细流程
- `remove()` - Per-bucket 锁删除
- `resize()` - 渐进式扩容算法

---

**文档完成时间**: 2026-02-11  
**验证状态**: 基于 OpenJDK 11 源码分析  
**预计阅读时间**: 20 分钟
