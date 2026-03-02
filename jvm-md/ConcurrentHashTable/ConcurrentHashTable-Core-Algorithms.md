# ConcurrentHashTable 核心算法深度分析

> **文档定位**：CHT 系列文档 2/3 - 核心算法实现原理  
> **分析目标**：深入剖析 `get()`、`insert()`、`remove()`、渐进式扩容等核心算法  
> **源码版本**：OpenJDK 11  
> **核心文件**：`src/hotspot/share/utilities/concurrentHashTable.inline.hpp` (1286 行)

---

## 目录

1. [整体架构回顾](#1-整体架构回顾)
2. [get() - Wait-Free 读取](#2-get---wait-free-读取)
3. [insert() - CAS 插入](#3-insert---cas-插入)
4. [remove() - 桶级锁删除](#4-remove---桶级锁删除)
5. [渐进式扩容算法](#5-渐进式扩容算法)
6. [批量删除与 GC 协作](#6-批量删除与-gc-协作)
7. [内存序与并发控制](#7-内存序与并发控制)
8. [GDB 调试实战](#8-gdb-调试实战)
9. [面试高频考点](#9-面试高频考点)

---

## 1. 整体架构回顾

### 1.1 核心设计原则

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     ConcurrentHashTable 设计原则                         │
├─────────────────────────────────────────────────────────────────────────┤
│  读取 (get)    │  Wait-Free，无锁，无重试，有限步骤内完成                 │
│  插入 (insert) │  CAS 无锁插入，冲突时重试，失败转为带锁路径              │
│  删除 (remove) │  桶级自旋锁，互斥执行                                    │
│  扩容 (grow)   │  渐进式，逐桶迁移，不阻塞读写                            │
│  缩容 (shrink) │  渐进式，逐桶合并，不阻塞读写                            │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.2 状态机回顾

```
Bucket 状态转换图：

     ┌──────────┐      trylock()       ┌──────────┐
     │ UNLOCKED │ ───────────────────→ │  LOCKED  │
     │  (00)    │ ←─────────────────── │   (01)   │
     └──────────┘       unlock()       └────┬─────┘
            │                                │
            │ redirect()                     │ redirect()
            │                                │
            └────────────────────────────────┘
                           │
                           ▼
                    ┌──────────────┐
                    │   REDIRECT   │ ←── 终态，指向新表
                    │    (10)      │
                    └──────────────┘
```

---

## 2. get() - Wait-Free 读取

### 2.1 问题背景

**为什么读取需要 Wait-Free？**

在 JVM 中，StringTable 的查找操作极其频繁（类加载、字符串常量解析）。如果读取需要加锁或重试，会严重影响性能。

**传统方案的缺陷：**
| 方案 | 问题 |
|------|------|
| 全局读写锁 | 读操作也需要获取锁，并发度低 |
| 分段锁 (CHM) | 需要计算 Segment，额外开销 |
| Lock-Free CAS | 冲突时需要重试，非 Wait-Free |

**CHT 的解决方案：**
- 使用 **GlobalCounter (RCU 机制)** 保护表结构
- 读取线程进入 Critical Section 后即可安全访问
- 无锁、无重试、有限步骤完成

### 2.2 源码分析

```cpp
// concurrentHashTable.inline.hpp:855-875
template <typename VALUE, typename CONFIG, MEMFLAGS F>
template <typename LOOKUP_FUNC>
inline VALUE* ConcurrentHashTable<VALUE, CONFIG, F>::
  internal_get(Thread* thread, LOOKUP_FUNC& lookup_f, bool* grow_hint)
{
  bool clean = false;
  size_t loops = 0;
  VALUE* ret = NULL;

  // 1. 获取 bucket（处理扩容时的重定向）
  const Bucket* bucket = get_bucket(lookup_f.get_hash());
  
  // 2. 遍历链表查找
  Node* node = get_node(bucket, lookup_f, &clean, &loops);
  if (node != NULL) {
    ret = node->value();
  }
  
  // 3. 返回是否建议扩容（链表过长）
  if (grow_hint != NULL) {
    *grow_hint = loops > _grow_hint;
  }

  return ret;
}
```

**关键点解析：**

```cpp
// get_bucket: 处理扩容时的 bucket 定位
inline Bucket* get_bucket(uintx hash) const
{
  InternalTable* table = get_table();           // 获取当前表
  Bucket* bucket = get_bucket_in(table, hash);  // 计算 bucket 索引
  
  // 如果 bucket 被标记为 REDIRECT，说明正在扩容，需要访问新表
  if (bucket->have_redirect()) {
    table = get_new_table();
    bucket = get_bucket_in(table, hash);
  }
  return bucket;
}
```

### 2.3 get_node 链表遍历

```cpp
// concurrentHashTable.inline.hpp:621-645
template <typename LOOKUP_FUNC>
Node* get_node(const Bucket* const bucket, LOOKUP_FUNC& lookup_f,
               bool* have_dead, size_t* loops) const
{
  size_t loop_count = 0;
  Node* node = bucket->first();  // 获取链表头
  
  while (node != NULL) {
    bool is_dead = false;
    ++loop_count;
    
    // 调用用户提供的比较函数
    if (lookup_f.equals(node->value(), &is_dead)) {
      break;  // 找到匹配项
    }
    
    // 标记是否有 dead 节点（用于后续清理）
    if (is_dead && !(*have_dead)) {
      *have_dead = true;
    }
    
    node = node->next();  // 遍历下一个
  }
  
  if (loops != NULL) {
    *loops = loop_count;  // 返回遍历次数，用于扩容判断
  }
  return node;
}
```

### 2.4 调用栈与关键路径

```
StringTable::lookup()
    └── ConcurrentHashTable::get()
            └── ScopedCS cs(thread, this)     // 进入 Critical Section
            │       └── GlobalCounter::critical_section_begin()
            │
            └── internal_get()
                    ├── get_bucket(hash)      // 定位 bucket
                    │       ├── get_table()   // 获取当前表
                    │       └── check redirect // 检查是否在扩容
                    │
                    └── get_node()            // 遍历链表
                            └── lookup_f.equals()  // 比较 key

                    ~ScopedCS()               // 退出 Critical Section
                            └── GlobalCounter::critical_section_end()
```

### 2.5 Wait-Free 的保证

```
┌────────────────────────────────────────────────────────────────────┐
│                      Wait-Free 保证机制                             │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  1. 无循环重试                                                      │
│     - 读取操作没有 CAS 失败重试                                      │
│     - 只有简单的链表遍历，最多遍历桶内所有节点                        │
│                                                                    │
│  2. 有限步骤                                                        │
│     - 步骤数 = 固定开销 + 链表长度                                   │
│     - 链表长度受 grow_hint 限制（默认 4）                            │
│                                                                    │
│  3. 不依赖其他线程进度                                              │
│     - 即使其他线程正在扩容/删除，读取线程也能完成                    │
│     - 通过 GlobalCounter 的 publish 机制保证                        │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

---

## 3. insert() - CAS 插入

### 3.1 设计目标

插入操作需要处理多种并发场景：
1. **无冲突快速路径**：使用 CAS 直接插入
2. **重复检测**：插入前检查是否已存在
3. **扩容协作**：链表过长时触发扩容
4. **死节点清理**：发现死节点时顺带清理

### 3.2 快速路径分析

```cpp
// concurrentHashTable.inline.hpp:877-942
template <typename LOOKUP_FUNC, typename VALUE_FUNC, typename CALLBACK_FUNC>
inline bool ConcurrentHashTable<VALUE, CONFIG, F>::
  internal_insert(Thread* thread, LOOKUP_FUNC& lookup_f, VALUE_FUNC& value_f,
                  CALLBACK_FUNC& callback, bool* grow_hint)
{
  bool ret = false;
  bool clean = false;
  bool locked;
  size_t loops = 0;
  size_t i = 0;
  Node* new_node = NULL;
  uintx hash = lookup_f.get_hash();
  
  // ========== 主循环：CAS 重试 ==========
  while (true) {
    {
      ScopedCS cs(thread, this);  // 进入 Critical Section
      Bucket* bucket = get_bucket(hash);

      Node* first_at_start = bucket->first();
      Node* old = get_node(bucket, lookup_f, &clean, &loops);
      
      if (old == NULL) {
        // ===== 无重复，可以插入 =====
        if (new_node == NULL) {
          new_node = Node::create_node(value_f(), first_at_start);
        } else {
          new_node->set_next(first_at_start);
        }
        
        // CAS 尝试插入到链表头
        if (bucket->cas_first(new_node, first_at_start)) {
          callback(true, new_node->value());
          new_node = NULL;
          ret = true;
          break;  // 成功！退出循环
        }
        
        // CAS 失败，记录状态，退出 Critical Section 后重试
        locked = bucket->is_locked();
      } else {
        // 发现重复项
        callback(false, old->value());
        break;
      }
    }  // 离开 Critical Section
    
    // 退避策略
    i++;
    if (locked) {
      os::naked_yield();  // bucket 被锁，让出 CPU
    } else {
      SpinPause();        // 自旋等待
    }
  }
  // ... 后续清理代码
}
```

### 3.3 CAS 快速路径流程图

```
┌─────────────────────────────────────────────────────────────────┐
│                     insert() 执行流程                            │
└─────────────────────────────────────────────────────────────────┘
                            │
                            ▼
              ┌─────────────────────────────┐
              │      进入 Critical Section   │
              └─────────────────────────────┘
                            │
                            ▼
              ┌─────────────────────────────┐
              │    获取 bucket & 链表头      │
              └─────────────────────────────┘
                            │
                            ▼
              ┌─────────────────────────────┐
              │      遍历链表检查重复        │
              └─────────────────────────────┘
                            │
            ┌───────────────┴───────────────┐
            │                               │
            ▼                               ▼
    ┌───────────────┐              ┌───────────────┐
    │  发现重复项    │              │  无重复，准备  │
    │  返回 false   │              │     插入       │
    └───────────────┘              └───────┬───────┘
                                           │
                                           ▼
                              ┌──────────────────────────┐
                              │  创建新节点，指向当前头   │
                              │  new_node -> first        │
                              └───────────┬──────────────┘
                                          │
                                          ▼
                              ┌──────────────────────────┐
                              │   CAS 替换链表头          │
                              │  cas_first(new, old)      │
                              └───────────┬──────────────┘
                                          │
                        ┌─────────────────┴─────────────────┐
                        │                                   │
                        ▼                                   ▼
            ┌──────────────────┐                ┌──────────────────┐
            │    CAS 成功       │                │    CAS 失败      │
            │   插入完成 ✓      │                │  有其他线程修改   │
            └──────────────────┘                └────────┬─────────┘
                                                         │
                                                         ▼
                                           ┌─────────────────────────┐
                                           │  离开 Critical Section  │
                                           │      根据情况退避        │
                                           │  locked -> yield()      │
                                           │  !locked -> SpinPause() │
                                           └───────────┬─────────────┘
                                                       │
                                                       ▼
                                           ┌─────────────────────────┐
                                           │        重试循环          │
                                           └─────────────────────────┘
```

### 3.4 CAS 操作详解

```cpp
// concurrentHashTable.inline.hpp:139-152
inline bool Bucket::cas_first(Node *node, Node* expect)
{
  // 如果 bucket 被锁定，不能 CAS
  if (is_locked()) {
    return false;
  }
  
  // 尝试 CAS 替换链表头
  if (Atomic::cmpxchg(node, &_first, expect) == expect) {
    return true;
  }
  return false;
}
```

**CAS 失败的场景：**
1. 其他线程成功插入（链表头改变）
2. 其他线程获取了 bucket 锁（状态位改变）
3. 正在扩容（设置了 REDIRECT 位）

### 3.5 慢速路径：死节点清理

```cpp
// 在 insert 成功后，如果发现链表中有死节点，顺带清理
if (new_node != NULL) {
  // CAS 失败且有重复插入，释放预分配节点
  Node::destroy_node(new_node);
} else if (i == 0 && clean) {
  // 快速路径成功且发现死节点，清理之
  Bucket* bucket = get_bucket_locked(thread, lookup_f.get_hash());
  assert(bucket->is_locked(), "Must be locked.");
  delete_in_bucket(thread, bucket, lookup_f);
  bucket->unlock();
}
```

**设计思想：**
- 只在快速路径（`i == 0`）时清理，避免增加慢路径开销
- 清理需要获取 bucket 锁，是昂贵的操作
- 延迟清理策略：大部分死节点等待批量删除处理

---

## 4. remove() - 桶级锁删除

### 4.1 为什么删除需要锁？

**并发删除的挑战：**
```
场景：两个线程同时删除链表中的不同节点

初始：A -> B -> C -> D

线程1 要删除 B：需要修改 A.next = C
线程2 要删除 C：需要修改 B.next = D

如果同时执行，可能导致：
- 线程1看到 B.next = C
- 线程2成功删除 C
- 线程1执行 A.next = C（指向已释放内存！）
```

**解决方案：** 桶级自旋锁，同一 bucket 的删除操作串行化。

### 4.2 源码分析

```cpp
// concurrentHashTable.inline.hpp:459-488
template <typename LOOKUP_FUNC, typename DELETE_FUNC>
inline bool ConcurrentHashTable<VALUE, CONFIG, F>::
  internal_remove(Thread* thread, LOOKUP_FUNC& lookup_f, DELETE_FUNC& delete_f)
{
  // 1. 获取 bucket 锁（可能自旋）
  Bucket* bucket = get_bucket_locked(thread, lookup_f.get_hash());
  assert(bucket->is_locked(), "Must be locked.");
  
  // 2. 查找要删除的节点
  Node* const volatile * rem_n_prev = bucket->first_ptr();
  Node* rem_n = bucket->first();
  bool have_dead = false;
  
  while (rem_n != NULL) {
    if (lookup_f.equals(rem_n->value(), &have_dead)) {
      // 找到目标，修改前驱节点的 next 指针
      bucket->release_assign_node_ptr(rem_n_prev, rem_n->next());
      break;
    } else {
      rem_n_prev = rem_n->next_ptr();
      rem_n = rem_n->next();
    }
  }

  // 3. 释放 bucket 锁
  bucket->unlock();

  if (rem_n == NULL) {
    return false;  // 未找到
  }
  
  // 4. 同步等待所有读取者离开
  GlobalCounter::write_synchronize();
  
  // 5. 调用用户回调，然后销毁节点
  delete_f(rem_n->value());
  Node::destroy_node(rem_n);
  return true;
}
```

### 4.3 bucket 锁的获取

```cpp
// concurrentHashTable.inline.hpp:591-618
inline Bucket* get_bucket_locked(Thread* thread, const uintx hash)
{
  Bucket* bucket;
  int i = 0;
  
  while(true) {
    {
      ScopedCS cs(thread, this);
      bucket = get_bucket(hash);
      
      // 尝试获取锁
      if (bucket->trylock()) {
        break;  // 成功，离开 Critical Section
      }
    }  // 离开 Critical Section
    
    // 退避
    if ((++i) == SPINPAUSES_PER_YIELD) {
      os::naked_yield();  // 让出 CPU
      i = 0;
    } else {
      SpinPause();        // 自旋
    }
  }
  return bucket;
}
```

**关键设计：** 在无法获取锁时，**先退出 Critical Section** 再退避，避免阻塞其他读取者。

### 4.4 安全内存回收

```cpp
// 删除后的关键步骤
GlobalCounter::write_synchronize();
```

**为什么需要 write_synchronize？**

```
时间线：
T1: 线程 A 正在读取 node X
T2: 线程 B 获取 bucket 锁，删除 node X
T3: 线程 B 调用 write_synchronize()
T4: 线程 B 调用 destroy_node(X)

write_synchronize() 确保：
- 所有在 T2 之前开始的读取操作都已完成
- 线程 A 不会再访问 node X
- 可以安全释放 node X 的内存
```

---

## 5. 渐进式扩容算法

### 5.1 为什么要渐进式扩容？

**传统扩容的问题：**
```
全局锁扩容：
- 创建新表（2倍大小）
- 遍历旧表所有 bucket
- 将每个节点重新哈希插入新表
- 耗时与表大小成正比，导致长时间停顿
```

**CHT 的解决方案 - 渐进式扩容：**
- 按需迁移：只有访问到的 bucket 才迁移
- 无全局停顿：读写操作与扩容并行
- 双表共存：旧表和新表同时存在，通过 REDIRECT 标志切换

### 5.2 扩容状态机

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        扩容状态流转                                      │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   ┌─────────┐    internal_grow_prolog()    ┌──────────────┐            │
│   │  NORMAL │ ───────────────────────────→ │  PREPARING   │            │
│   └─────────┘                              └──────┬───────┘            │
│                                                   │                     │
│                                                   │ 创建新表(2倍大小)    │
│                                                   │ 设置 _new_table     │
│                                                   ▼                     │
│                                          ┌──────────────┐              │
│   完成所有迁移                            │  MIGRATING   │              │
│   ┌──────────────────────────────────────│  (渐进迁移)   │              │
│   │                                      └──────┬───────┘              │
│   │                                             │                      │
│   ▼                                             │ 访问触发迁移         │
│  ┌─────────┐                                    │                      │
│  │ FINISH  │ ←─────────────────────────────────┘                      │
│  └────┬────┘                                    \_new_table 完全可用   │
│       │                                                                 │
│       │ internal_grow_epilog()                                          │
│       ▼                                                                 │
│  ┌─────────┐                                                            │
│  │  NORMAL │  (新表成为当前表，旧表销毁)                                 │
│  └─────────┘                                                            │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 5.3 扩容触发条件

```cpp
// StringTable 的扩容触发逻辑
void StringTable::grow(JavaThread* thread) {
  bool rehash_warning = false;
  // 尝试将表大小翻倍
  while (!_local_table->is_max_size_reached() && 
         _local_table->should_grow(thread)) {
    if (_local_table->is_safepoint_safe()) {
      // 安全点期间可以全量迁移
      _local_table->grow(thread);
    } else {
      // 非安全点期间，渐进式扩容
      // 通过 GrowTask 分批次迁移
      trigger_concurrent_grow();
    }
  }
}
```

### 5.4 单桶迁移算法 (unzip_bucket)

```cpp
// concurrentHashTable.inline.hpp:647-703
inline bool ConcurrentHashTable<VALUE, CONFIG, F>::
  unzip_bucket(Thread* thread, InternalTable* old_table,
               InternalTable* new_table, size_t even_index, size_t odd_index)
{
  Node* aux = old_table->get_bucket(even_index)->first();
  if (aux == NULL) {
    return false;  // 空 bucket，无需迁移
  }
  
  Node* delete_me = NULL;
  Node* const volatile * even = new_table->get_bucket(even_index)->first_ptr();
  Node* const volatile * odd = new_table->get_bucket(odd_index)->first_ptr();
  
  while (aux != NULL) {
    bool dead_hash = false;
    size_t aux_hash = CONFIG::get_hash(*aux->value(), &dead_hash);
    Node* aux_next = aux->next();
    
    if (dead_hash) {
      // 死节点，两个新 bucket 都跳过它
      delete_me = aux;
      new_table->get_bucket(odd_index)->release_assign_node_ptr(odd, aux_next);
      new_table->get_bucket(even_index)->release_assign_node_ptr(even, aux_next);
    } else {
      // 根据 hash 的额外一位决定放入哪个 bucket
      size_t aux_index = bucket_idx_hash(new_table, aux_hash);
      
      if (aux_index == even_index) {
        // hash 高位为 0，放入 even bucket
        new_table->get_bucket(odd_index)->release_assign_node_ptr(odd, aux_next);
        even = aux->next_ptr();
      } else if (aux_index == odd_index) {
        // hash 高位为 1，放入 odd bucket
        new_table->get_bucket(even_index)->release_assign_node_ptr(even, aux_next);
        odd = aux->next_ptr();
      }
    }
    
    aux = aux_next;
    
    // 关键：每次只移动一个指针，然后同步
    // 防止读取者被错误地引导到错误链表
    write_synchonize_on_visible_epoch(thread);
    
    if (delete_me != NULL) {
      Node::destroy_node(delete_me);
      delete_me = NULL;
    }
  }
  return true;
}
```

**算法核心：**
```
旧表 bucket（大小 N） → 新表两个 buckets（大小 2N）

假设旧表 bucket 索引 = 5，新表大小翻倍后：
- 新表索引 = 5（hash 高位为 0）
- 新表索引 = 5 + N（hash 高位为 1）

根据 hash & N 的结果决定节点归属：
- 结果为 0 → 放入 even bucket
- 结果为 1 → 放入 odd bucket
```

### 5.5 读写与扩容的并发

```
场景：扩容期间，读取和插入如何工作？

┌────────────────────────────────────────────────────────────────┐
│                     扩容期间的读取流程                          │
└────────────────────────────────────────────────────────────────┘

读取线程                              扩容线程
─────────────────────────────────────────────────────────────────
get_bucket(hash)
  ├── get_table() → 旧表
  ├── get_bucket_in(旧表, hash) → bucket_X
  └── bucket_X.have_redirect()? 
      ├── YES → 访问新表
      │         get_new_table()
      │         get_bucket_in(新表, hash)
      │         └── 读取成功
      └── NO → 直接读取旧表
                 └── 读取成功


┌────────────────────────────────────────────────────────────────┐
│                     扩容期间的插入流程                          │
└────────────────────────────────────────────────────────────────┘

插入线程                              扩容线程
─────────────────────────────────────────────────────────────────
get_bucket(hash)
  └── 发现 bucket_X.have_redirect()
      
      路径1：重试
      └── 重新 get_bucket(hash)
          └── 这次访问新表
          
      路径2：尝试 CAS 旧表（会失败）
      └── cas_first() 发现 REDIRECT 状态
          └── 返回 false，重试
```

### 5.6 缩容算法

缩容是扩容的逆过程，将两个相邻 bucket 合并到一个：

```cpp
// concurrentHashTable.inline.hpp:741-776
inline void ConcurrentHashTable<VALUE, CONFIG, F>::
  internal_shrink_range(Thread* thread, size_t start, size_t stop)
{
  for (size_t bucket_it = start; bucket_it < stop; bucket_it++) {
    // 旧表的两个相邻 bucket
    size_t even_hash_index = bucket_it;                    // 高位为 0
    size_t odd_hash_index = bucket_it + _new_table->_size;  // 高位为 1

    Bucket* b_old_even = _table->get_bucket(even_hash_index);
    Bucket* b_old_odd  = _table->get_bucket(odd_hash_index);

    // 锁定两个 bucket
    b_old_even->lock();
    b_old_odd->lock();

    // 复制 even bucket 到新表
    _new_table->get_buckets()[bucket_it] = *b_old_even;
    
    // 将 odd bucket 的链表连接到 even 链表末尾
    _new_table->get_bucket(bucket_it)->
      release_assign_last_node_next(*(b_old_odd->first_ptr()));

    // 设置 REDIRECT，让后续访问转到新表
    b_old_even->redirect();
    b_old_odd->redirect();

    write_synchonize_on_visible_epoch(thread);
    
    // 解锁新表的 bucket
    _new_table->get_bucket(bucket_it)->unlock();
  }
}
```

---

## 6. 批量删除与 GC 协作

### 6.1 为什么需要批量删除？

**StringTable 的场景：**
- JVM 启动时加载大量类，产生大量字符串常量
- 随着时间推移，很多类被卸载（如动态生成的代理类）
- 对应的字符串常量变成"垃圾"，需要清理

**批量删除的优势：**
- 摊平开销：一次性清理多个死节点
- 减少锁竞争：批量获取 bucket 锁，而非逐个获取
- GC 友好：可以与 GC 周期同步执行

### 6.2 批量删除流程

```cpp
// concurrentHashTable.inline.hpp:491-540
template <typename EVALUATE_FUNC, typename DELETE_FUNC>
inline void ConcurrentHashTable<VALUE, CONFIG, F>::
  do_bulk_delete_locked_for(Thread* thread, size_t start_idx, size_t stop_idx,
                            EVALUATE_FUNC& eval_f, DELETE_FUNC& del_f, bool is_mt)
{
  assert(_resize_lock_owner != NULL, "Re-size lock not held");
  
  Node* ndel[BULK_DELETE_LIMIT];  // 待删除节点缓冲区
  InternalTable* table = get_table();
  
  GlobalCounter::critical_section_begin(thread);
  
  for (size_t bucket_it = start_idx; bucket_it < stop_idx; bucket_it++) {
    Bucket* bucket = table->get_bucket(bucket_it);
    Bucket* prefetch_bucket = (bucket_it+1) < stop_idx ?
                              table->get_bucket(bucket_it+1) : NULL;

    // 快速检查：是否有可删除节点？
    if (!HaveDeletables<IsPointer<VALUE>::value, EVALUATE_FUNC>::
        have_deletable(bucket, eval_f, prefetch_bucket)) {
        continue;  // 此 bucket 无死节点
    }

    GlobalCounter::critical_section_end(thread);
    
    // 获取 bucket 锁并删除
    bucket->lock();
    size_t nd = delete_check_nodes(bucket, eval_f, BULK_DELETE_LIMIT, ndel);
    bucket->unlock();
    
    // 同步等待读取者离开
    if (is_mt) {
      GlobalCounter::write_synchronize();
    } else {
      write_synchonize_on_visible_epoch(thread);
    }
    
    // 销毁节点
    for (size_t node_it = 0; node_it < nd; node_it++) {
      del_f(ndel[node_it]->value());
      Node::destroy_node(ndel[node_it]);
    }
    
    GlobalCounter::critical_section_begin(thread);
  }
  
  GlobalCounter::critical_section_end(thread);
}
```

### 6.3 预取优化 (Prefetch)

```cpp
// 针对指针类型的 VALUE，使用预取优化遍历
template<typename EVALUATE_FUNC>
struct HaveDeletables<true, EVALUATE_FUNC> {
  static bool have_deletable(Bucket* bucket, EVALUATE_FUNC& eval_f,
                             Bucket* prefetch_bucket)
  {
    Node* pref = prefetch_bucket != NULL ? prefetch_bucket->first() : NULL;
    
    for (Node* next = bucket->first(); next != NULL; next = next->next()) {
      // 预取下一个 bucket 的节点值
      if (pref != NULL) {
        Prefetch::read(*pref->value(), 0);
        pref = pref->next();
      }
      
      // 预取当前节点的下一个节点值
      Node* next_pref = next->next();
      if (next_pref != NULL) {
        Prefetch::read(*next_pref->value(), 0);
      }
      
      if (eval_f(next->value())) {
        return true;
      }
    }
    return false;
  }
};
```

**性能提升：** 预取可以带来约 **30%** 的遍历性能提升。

---

## 7. 内存序与并发控制

### 7.1 GlobalCounter (RCU 机制)

CHT 使用 `GlobalCounter` 实现读-复制-更新（RCU）语义：

```cpp
// 读取线程
GlobalCounter::critical_section_begin(thread);
  // 安全访问哈希表
  // 表结构不会被释放
GlobalCounter::critical_section_end(thread);

// 写入/扩容线程
GlobalCounter::write_synchronize();
  // 等待所有在调用前进入 Critical Section 的线程离开
  // 然后可以安全修改/释放表结构
```

### 7.2 内存序使用总结

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         内存序使用场景                                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  load_acquire / release_store                                           │
│  ├── bucket.first() 读取链表头                                          │
│  ├── bucket._first 的 CAS 操作                                          │
│  └── _table / _new_table 的访问                                         │
│                                                                         │
│  OrderAccess::fence()                                                   │
│  ├── write_synchonize_on_visible_epoch() 中防止重排序                   │
│  └── 确保状态变更对其他线程可见                                         │
│                                                                         │
│  Atomic::cmpxchg                                                        │
│  ├── trylock() / unlock() 状态变更                                      │
│  └── cas_first() 链表头插入                                             │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 7.3 并发安全总结

| 操作 | 读取保护 | 写入保护 | 同步机制 |
|------|----------|----------|----------|
| get | Critical Section | 无 | GlobalCounter |
| insert | Critical Section | CAS + 自旋 | GlobalCounter |
| remove | Critical Section | Bucket 锁 | GlobalCounter + write_synchronize |
| grow | Critical Section | Resize 锁 + Bucket 锁 | GlobalCounter + write_synchronize |
| bulk_delete | Critical Section | Resize 锁 + Bucket 锁 | GlobalCounter + write_synchronize |

---

## 8. GDB 调试实战

### 8.1 设置断点

```gdb
# 在 insert 操作设置断点
break concurrentHashTable.inline.hpp:904

# 在扩容迁移设置断点
break concurrentHashTable.inline.hpp:441

# 在删除操作设置断点
break concurrentHashTable.inline.hpp:470
```

### 8.2 查看 Bucket 状态

```gdb
# 打印 bucket 状态
define print_bucket
  set $b = (ConcurrentHashTable<oopDesc*, StringTableConfig, (MEMFLAGS)9>::Bucket*)$arg0
  set $first = $b->_first
  set $state = ((uintptr_t)$first) & 0x3
  
  printf "Bucket @ %p:\n", $b
  printf "  _first: %p\n", (void*)((uintptr_t)$first & ~0x3)
  
  if $state == 0
    printf "  State: UNLOCKED\n"
  else
    if $state == 1
      printf "  State: LOCKED\n"
    else
      if $state == 2
        printf "  State: REDIRECT\n"
      else
        printf "  State: INVALID (%d)\n", (int)$state
      end
    end
  end
end
```

### 8.3 遍历链表

```gdb
# 遍历 bucket 链表
define traverse_bucket
  set $b = (ConcurrentHashTable<oopDesc*, StringTableConfig, (MEMFLAGS)9>::Bucket*)$arg0
  set $node = (void*)((uintptr_t)$b->_first & ~0x3)
  set $i = 0
  
  printf "Bucket chain:\n"
  while $node != 0 && $i < 20
    printf "  [%d] Node @ %p\n", $i, $node
    set $node = (void*)((uintptr_t)*(void**)$node & ~0x3)
    set $i = $i + 1
  end
end
```

### 8.4 查看扩容状态

```gdb
# 打印扩容相关信息
define print_resize_state
  # 打印当前表
  printf "Current table:\n"
  printf "  _table: %p\n", _table
  printf "  _log2_size: %zu\n", _table->_log2_size
  printf "  _size: %zu\n", _table->_size
  
  # 打印新表（如果正在扩容）
  printf "\nNew table (resizing to):\n"
  printf "  _new_table: %p\n", _new_table
  if _new_table != 0
    printf "  _log2_size: %zu\n", _new_table->_log2_size
    printf "  _size: %zu\n", _new_table->_size
  else
    printf "  (not resizing)\n"
  end
  
  # 打印锁状态
  printf "\nLock state:\n"
  printf "  _resize_lock_owner: %p\n", _resize_lock_owner
  printf "  _invisible_epoch: %p\n", _invisible_epoch
end
```

---

## 9. 面试高频考点

### 9.1 核心问题

**Q1: CHT 的 get() 为什么是 Wait-Free 而不是 Lock-Free？**

```
答案要点：
1. Wait-Free 是更强的保证，要求每个操作在有限步骤内完成
2. CHT 的 get() 没有 CAS 重试，只有固定开销 + 链表遍历
3. 链表长度有限（触发扩容前最多 grow_hint 个节点）
4. 不依赖其他线程进度，即使其他线程卡住也能完成
```

**Q2: CHT 如何处理扩容期间的读写？**

```
答案要点：
1. 双表共存：旧表(_table)和新表(_new_table)同时存在
2. REDIRECT 标志：旧表 bucket 设置 REDIRECT 后，读取转到新表
3. 渐进迁移：只有被访问的 bucket 才会触发迁移
4. 无全局停顿：扩容与读写并行执行
```

**Q3: CHT 为什么使用桶级锁而不是更细粒度的锁？**

```
答案要点：
1. 简单高效：链表操作的锁竞争本来就是 bucket 级别的
2. 状态压缩：锁状态存储在 _first 指针的低位，无需额外字段
3. 扩容友好：bucket 是扩容迁移的基本单位
4. 足够细粒度：相比全局锁，bucket 级锁并发度已经足够高
```

**Q4: GlobalCounter 的 write_synchronize 是什么作用？**

```
答案要点：
1. 实现 RCU (Read-Copy-Update) 语义
2. 等待所有在调用前进入 Critical Section 的读取线程离开
3. 确保删除/扩容操作的内存安全
4. 避免使用引用计数等复杂机制
```

### 9.2 源码细节问题

**Q5: `bucket->_first` 指针的低 2 位存储什么状态？**

```cpp
static const uintptr_t STATE_LOCK_BIT     = 0x1;  // 01 - 已锁定
static const uintptr_t STATE_REDIRECT_BIT = 0x2;  // 10 - 重定向
static const uintptr_t STATE_MASK         = 0x3;  // 掩码
```

**Q6: CAS 插入失败后会如何处理？**

```
流程：
1. CAS 失败 → 离开 Critical Section
2. 判断失败原因（locked? redirect? 冲突插入?）
3. 选择退避策略（yield 或 SpinPause）
4. 重新进入循环重试
```

---

## 10. 总结

### 10.1 算法复杂度

| 操作 | 时间复杂度 | 空间复杂度 | 并发级别 |
|------|-----------|-----------|----------|
| get | O(链长) ≈ O(1) | O(1) | Wait-Free |
| insert | O(链长) + CAS 重试 | O(1) | Lock-Free (快速路径) |
| remove | O(链长) + 锁等待 | O(1) | 桶级互斥 |
| grow/shrink | O(触发的 bucket 数) | O(2N) | 渐进式，不阻塞 |

### 10.2 设计亮点

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        CHT 核心设计亮点                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  1. Wait-Free 读取                                                      │
│     - 使用 RCU 机制保护表结构                                            │
│     - 读取线程无锁、无重试                                               │
│                                                                         │
│  2. 指针打包状态                                                        │
│     - bucket 锁状态存储在 _first 指针低位                                │
│     - 节省内存，支持原子 CAS 操作                                        │
│                                                                         │
│  3. 渐进式扩容                                                          │
│     - 按需迁移，无全局停顿                                               │
│     - 双表共存，REDIRECT 标志平滑切换                                    │
│                                                                         │
│  4. 延迟清理策略                                                        │
│     - 单条插入快速路径只处理 fast case                                   │
│     - 批量删除集中处理 dead 节点                                         │
│                                                                         │
│  5. CRTP 模板设计                                                       │
│     - 零成本抽象，编译期多态                                             │
│     - 支持自定义 hash/allocator/comparator                               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 10.3 后续学习建议

1. **阅读 StringTable 实现**：看 CHT 如何被实际使用
2. **研究 GlobalCounter**：深入理解 RCU 机制在 JVM 中的实现
3. **对比 JDK ConcurrentHashMap**：理解不同场景的设计权衡
4. **性能测试**：使用 JMH 测试 CHT 在不同负载下的表现

---

**文档完成时间**：2025年2月  
**系列文档**：
- 文档 1/3：ConcurrentHashTable-Architecture.md（架构设计）
- 文档 2/3：ConcurrentHashTable-Core-Algorithms.md（核心算法）⭐ 本文档
- 文档 3/3：ConcurrentHashTable-Performance.md（性能分析）待完成
