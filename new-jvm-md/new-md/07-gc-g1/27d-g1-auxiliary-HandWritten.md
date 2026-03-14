# 第 27d 篇：G1 字符串去重与类卸载 — 两个被忽视的后台机制

> 基于 OpenJDK 11 源码分析  
> 标准环境：`-Xms8g -Xmx8g -XX:+UseG1GC`，G1 Region = 4MB

---

## 本章与其他章节的关系

```
[24] Young GC（字符串去重在 Young GC 时入队）
    ↓
你在这里
    ↓
[27d] 字符串去重与类卸载 ← 本篇（两个后台优化机制）
    ↓
[30] 调优实战（字符串去重的调优参数）
```

**前置知识**：第 24 篇（Young GC，了解对象在 Young GC 时的处理流程）

**本篇解决的问题**：G1 字符串去重与 `String.intern()` 有什么本质区别？`G1StringDedup` 的去重队列、去重表、去重线程是怎么工作的？类卸载的触发条件是什么？

**读完本篇你能理解**：
- 为什么字符串去重不能替代 `String.intern()`（去重 `byte[]` vs 去重引用）
- 第 30 篇中 `-XX:+UseStringDeduplication` 调优参数的适用场景
- 类卸载与 Metaspace 的关系（`ClassLoaderData` 的生命周期）

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

**字符串去重 = 让内容相同的 String 对象共享同一个 `byte[]` 数组，释放重复的数组内存。**

Java 字符串不可变，但同样内容的字符串可能有多个对象，各自持有一个 `byte[]`：

```java
String a = new String("hello");  // a._value = byte[]{104,101,108,108,111}
String b = new String("hello");  // b._value = byte[]{104,101,108,108,111}  ← 重复！
```

去重后：`a._value` 和 `b._value` 指向同一个 `byte[]`，释放了一份内存。

### 0.2 为什么需要？

Java 应用中字符串重复率极高（HTTP 请求头、数据库字段名、JSON key 等），重复的 `byte[]` 数组可能占用堆内存的 10%~30%。

### 0.3 怎么解决？

**三个组件协作**：
1. **去重队列（`G1StringDedupQueue`）**：Young GC 时，把满足年龄条件的字符串入队
2. **去重线程（`StringDedupThread`）**：后台并发线程，从队列取出字符串，查表去重
3. **去重表（`StringDedupTable`）**：哈希表，存储所有已知的唯一 `byte[]`，用于查找重复

### 0.4 为什么这样设计？

- **为什么在 Young GC 时入队？** 字符串在 Young GC 时被疏散（复制），此时可以顺便检查年龄，代价最低
- **为什么用后台线程去重？** 去重需要计算哈希、比较内容，代价较高，放在 STW 期间会增加停顿时间
- **为什么只针对存活 N 次的字符串？** 短命字符串还没来得及去重就死了，浪费 CPU；只对"老"字符串去重，性价比更高
- **为什么去重 `byte[]` 而不是 `String` 对象？** `String` 对象本身很小（只有几个字段），`byte[]` 才是内存大户

---

## 第 1 部分：数据结构全景

### 1.1 数据结构清单

| 结构名 | 源码位置 | 核心作用 |
|--------|----------|----------|
| `G1StringDedupQueue` | `g1StringDedupQueue.cpp` | G1 专用去重队列，每个 GC Worker 一个子队列 |
| `StringDedupEntry` | `stringDedupTable.hpp:40` | 去重表的哈希链表节点，弱引用 `byte[]` |
| `StringDedupTable` | `stringDedupTable.hpp:100` | 去重哈希表，存储所有唯一 `byte[]` |
| `StringDedupEntryCache` | `stringDedupTable.cpp:50` | 表项缓存，减少 GC 期间的内存分配压力 |
| `StringDedupThread` | `stringDedupThread.hpp` | 后台并发去重线程（`StrDedup` 线程） |
| `StringDedupStat` | `stringDedupStat.hpp` | 去重统计信息（检查数、去重数、节省内存等） |

### 1.2 `StringDedupEntry` — 去重表的哈希节点

#### 1.2.1 字段列表

```cpp
// stringDedupTable.hpp:40
class StringDedupEntry : public CHeapObj<mtGC> {
  StringDedupEntry* _next;    // 哈希链表的下一个节点（用于冲突链和 freelist）
  unsigned int      _hash;    // byte[] 的哈希值（缓存，避免重复计算）
  bool              _latin1;  // 是否是 Latin-1 编码（JDK 9+ 紧凑字符串）
  typeArrayOop      _obj;     // 弱引用指向 byte[]（GC 时可能被清除）
};
```

**关键设计**：`_obj` 是**弱引用**（`ON_PHANTOM_OOP_REF`），当 `byte[]` 不再被任何 `String` 引用时，GC 会清除这个引用，去重表在下次 GC 时会移除这个条目。

#### 1.2.2 `_latin1` 字段的作用

JDK 9 引入了紧凑字符串（Compact Strings）：
- `latin1 = true`：字符串只包含 Latin-1 字符（ASCII），用 `byte[]` 存储，每个字符 1 字节
- `latin1 = false`：字符串包含非 Latin-1 字符（如中文），用 `byte[]` 存储，每个字符 2 字节（UTF-16）

两个字符串即使 `byte[]` 内容相同，如果编码不同也不能去重（`latin1` 不同）。

### 1.3 `StringDedupTable` — 去重哈希表

#### 1.3.1 字段列表

```cpp
// stringDedupTable.hpp:100
class StringDedupTable : public CHeapObj<mtGC> {
  // 静态字段（全局唯一实例）
  static StringDedupTable*      _table;          // 当前活跃的哈希表实例
  static StringDedupEntryCache* _entry_cache;    // 表项缓存

  // 实例字段
  StringDedupEntry**  _buckets;          // 哈希桶数组（链表头指针数组）
  size_t              _size;             // 哈希桶数量（必须是 2 的幂）
  uintx               _entries;         // 当前表项数量
  uintx               _shrink_threshold; // 缩容阈值（= size × 0.67）
  uintx               _grow_threshold;   // 扩容阈值（= size × 2.0）
  bool                _rehash_needed;    // 是否需要重新哈希（哈希冲突过多时）
  uint64_t            _hash_seed;        // 哈希种子（0 = Java 兼容哈希，非 0 = murmur3）

  // 统计字段（仅用于日志）
  static uintx        _entries_added;    // 累计添加的表项数
  static uintx        _entries_removed;  // 累计移除的表项数
  static uintx        _resize_count;     // 扩缩容次数
  static uintx        _rehash_count;     // 重新哈希次数
};
```

#### 1.3.2 关键常量

```cpp
// stringDedupTable.cpp:190
const size_t  StringDedupTable::_min_size = (1 << 10);   // 1024（初始大小）
const size_t  StringDedupTable::_max_size = (1 << 24);   // 16,777,216（最大大小）
const double  StringDedupTable::_grow_load_factor = 2.0; // 负载因子 > 200% 时扩容（翻倍）
const double  StringDedupTable::_shrink_load_factor = _grow_load_factor / 3.0; // 负载因子 < 67% 时缩容（减半）
const double  StringDedupTable::_max_cache_factor = 0.1; // 最多缓存 10% 的表大小
const uintx   StringDedupTable::_rehash_multiple = 60;   // 某个桶的冲突数 > 平均值 × 60 时触发重新哈希
```

#### 1.3.3 创建位置

```cpp
// stringDedupTable.cpp:210
void StringDedupTable::create() {
  _entry_cache = new StringDedupEntryCache(_min_size * _max_cache_factor);  // 缓存 102 个表项
  _table = new StringDedupTable(_min_size);  // 初始 1024 个桶
}
```

在 `G1StringDedup::initialize()` 中调用，JVM 启动时（`-XX:+UseStringDeduplication`）初始化。

### 1.4 `G1StringDedupQueue` — G1 专用去重队列

#### 1.4.1 字段列表

```cpp
// g1StringDedupQueue.hpp
class G1StringDedupQueue : public StringDedupQueue {
  static const size_t _max_size;        // 每个子队列最大容量 = 1,000,000
  static const size_t _max_cache_size;  // 每个子队列的缓存大小 = 0

  size_t                    _nqueues;   // 子队列数量 = ParallelGCThreads（默认 13）
  G1StringDedupWorkerQueue* _queues;    // 子队列数组（每个 GC Worker 一个）
  volatile size_t           _cursor;   // 当前弹出位置（轮询各子队列）
  volatile bool             _cancel;   // 是否取消等待
  volatile bool             _empty;    // 是否为空（快速判断）
  volatile uintx            _dropped;  // 因队列满而丢弃的字符串数
};
```

**设计亮点**：每个 GC Worker 有独立的子队列，入队时无锁（各 Worker 只写自己的队列），出队时轮询所有子队列（去重线程单线程消费）。

---

## 第 2 部分：算法/流程分析

### 2.1 核心流程概览

```mermaid
flowchart TD
    A[Young GC 疏散对象] --> B{是 String 对象?}
    B -->|否| C[正常疏散]
    B -->|是| D{from_young?}
    D -->|否| C
    D -->|是| E{年龄条件满足?}
    E -->|否| C
    E -->|是| F[G1StringDedupQueue::push]
    F --> G[入队到 worker 的子队列]

    H[StringDedupThread 主循环] --> I[StringDedupQueue::wait 等待非空]
    I --> J[StringDedupQueue::pop 取出字符串]
    J --> K[StringDedupTable::deduplicate]
    K --> L{查表找到相同 byte\[\]?}
    L -->|找到| M[java_lang_String::set_value 替换 byte\[\]]
    L -->|未找到| N[add 加入去重表]
    M --> J
    N --> J
```

### 2.2 入队时机：`enqueue_from_evacuation()`（`g1StringDedup.cpp:85`）

#### 2.2.1 解决什么问题？

Young GC 疏散对象时，顺便把满足条件的字符串加入去重队列，代价最低（此时已经在处理这个对象了）。

#### 2.2.2 两种入队路径

**路径 1：从 Young 疏散到 Young（Survivor）**

```cpp
// g1StringDedup.cpp:66
bool G1StringDedup::is_candidate_from_evacuation(bool from_young, bool to_young, oop obj) {
  if (from_young && java_lang_String::is_instance_inlined(obj)) {
    if (to_young && obj->age() == StringDeduplicationAgeThreshold) {
      // ★ 条件：从 Young 疏散到 Young，且年龄恰好达到阈值（默认 3）
      // 含义：这个字符串已经存活了 3 次 Young GC，值得去重
      return true;
    }
    if (!to_young && obj->age() < StringDeduplicationAgeThreshold) {
      // ★ 条件：从 Young 疏散到 Old，且年龄未达到阈值
      // 含义：对象被晋升到 Old 区，但还没来得及去重，现在补上
      return true;
    }
  }
  return false;
}
```

**路径 2：从并发标记入队（`enqueue_from_mark()`）**

```cpp
// g1StringDedup.cpp:43
bool G1StringDedup::is_candidate_from_mark(oop obj) {
  if (java_lang_String::is_instance_inlined(obj)) {
    bool from_young = G1CollectedHeap::heap()->heap_region_containing(obj)->is_young();
    if (from_young && obj->age() < StringDeduplicationAgeThreshold) {
      // ★ 并发标记时，Young 区中年龄未达阈值的字符串也入队
      // 场景：并发标记扫描到 Young 区的字符串，顺便入队
      return true;
    }
  }
  return false;
}
```

**年龄条件总结**：

| 场景 | 条件 | 原因 |
|------|------|------|
| Young → Young（Survivor） | `age == threshold`（默认 3） | 恰好达到阈值，第一次入队 |
| Young → Old（晋升） | `age < threshold` | 晋升时补入队，避免漏掉 |
| 并发标记扫描 | `age < threshold` | 顺便入队，避免漏掉 |

### 2.3 去重核心：`StringDedupTable::deduplicate()`（`stringDedupTable.cpp:345`）

#### 2.3.1 解决什么问题？

从队列取出一个字符串，查找去重表中是否有相同内容的 `byte[]`。如果有，替换；如果没有，加入表中。

#### 2.3.2 完整源码 + 逐行注释

```cpp
// stringDedupTable.cpp:345
void StringDedupTable::deduplicate(oop java_string, StringDedupStat* stat) {
  assert(java_lang_String::is_instance(java_string), "Must be a string");
  NoSafepointVerifier nsv;  // ★ 去重期间不允许 SafePoint（防止对象被移动）

  stat->inc_inspected();  // 统计：检查了一个字符串

  typeArrayOop value = java_lang_String::value(java_string);
  if (value == NULL) {
    stat->inc_skipped();  // ★ 跳过：字符串没有 value（空字符串或已被清除）
    return;
  }

  bool latin1 = java_lang_String::is_latin1(java_string);
  unsigned int hash = 0;

  if (use_java_hash()) {
    hash = java_lang_String::hash(java_string);  // ★ 优先使用缓存的哈希值
  }

  if (hash == 0) {
    hash = hash_code(value, latin1);  // ★ 缓存没有，重新计算
    stat->inc_hashed();
    if (use_java_hash() && hash != 0) {
      java_lang_String::set_hash(java_string, hash);  // ★ 顺便缓存哈希值
    }
  }

  // ★ 核心：查表或添加
  typeArrayOop existing_value = lookup_or_add(value, latin1, hash);

  if (existing_value == value) {
    stat->inc_known();  // ★ 已知：这个 byte[] 就是表中的那个，无需去重
    return;
  }

  uintx size_in_bytes = value->size() * HeapWordSize;
  stat->inc_new(size_in_bytes);  // 统计：新发现的字符串

  if (existing_value != NULL) {
    // ★ 找到了相同内容的 byte[]，执行去重！
    java_lang_String::set_value(java_string, existing_value);
    // ↑ 把 java_string._value 指向表中已有的 byte[]
    // ↑ 原来的 byte[] 不再被引用，下次 GC 时会被回收
    stat->deduped(value, size_in_bytes);  // 统计：去重了，节省了 size_in_bytes 字节
  }
  // 如果 existing_value == NULL，说明是新字符串，已经被 lookup_or_add 加入表中
}
```

#### 2.3.3 `lookup_or_add_inner()` — 查表或添加

```cpp
// stringDedupTable.cpp:298
typeArrayOop StringDedupTable::lookup_or_add_inner(typeArrayOop value, bool latin1, unsigned int hash) {
  size_t index = hash_to_index(hash);  // ★ 计算桶索引：hash & (size - 1)
  StringDedupEntry** list = bucket(index);
  uintx count = 0;

  // ★ 在哈希链表中查找
  typeArrayOop existing_value = lookup(value, latin1, hash, list, count);

  if (count > _rehash_threshold) {
    _rehash_needed = true;  // ★ 冲突太多，标记需要重新哈希
  }

  if (existing_value == NULL) {
    // ★ 未找到，添加新表项
    add(value, latin1, hash, list);
    _entries_added++;
  }

  return existing_value;  // NULL 表示新添加，非 NULL 表示找到了已有的
}
```

#### 2.3.4 设计决策

**为什么用弱引用存储 `byte[]`？**

去重表存储的是 `byte[]` 的弱引用。当所有引用这个 `byte[]` 的 `String` 对象都死了，`byte[]` 本身也应该被回收，去重表中的条目也应该被清除。弱引用让 GC 能自动清除这些"孤儿"条目，避免内存泄漏。

**为什么用 `NoSafepointVerifier`？**

去重期间不能发生 SafePoint，因为 SafePoint 可能触发 GC，GC 可能移动对象，导致 `value` 指针失效。

### 2.4 去重线程主循环（`stringDedupThread.inline.hpp:35`）

```cpp
template <typename S>
void StringDedupThreadImpl<S>::do_deduplication() {
  S total_stat;
  deduplicate_shared_strings(&total_stat);  // ★ 先处理 CDS 共享字符串

  for (;;) {
    S stat;
    stat.mark_idle();

    StringDedupQueue::wait();  // ★ 阻塞等待队列非空（Monitor 等待）
    if (this->should_terminate()) break;

    {
      SuspendibleThreadSetJoiner sts_join;  // ★ 加入 SuspendibleThreadSet，允许 SafePoint 时暂停

      stat.mark_exec();
      StringDedupStat::print_start(&stat);

      for (;;) {
        oop java_string = StringDedupQueue::pop();  // ★ 从队列取出字符串
        if (java_string == NULL) break;

        StringDedupTable::deduplicate(java_string, &stat);  // ★ 执行去重

        if (sts_join.should_yield()) {
          stat.mark_block();
          sts_join.yield();  // ★ SafePoint 时主动让步（不阻塞 STW）
          stat.mark_unblock();
        }
      }

      stat.mark_done();
      total_stat.add(&stat);
      print_end(&stat, &total_stat);
    }

    StringDedupTable::clean_entry_cache();  // ★ 清理溢出的缓存条目
  }
}
```

**关键设计**：`SuspendibleThreadSetJoiner` 让去重线程能在 SafePoint 时主动暂停，不阻塞 GC 的 STW 操作。

---

## 第 3 部分：String.intern() vs G1 字符串去重

这是一个常见的混淆点，必须澄清。

### 3.1 本质区别

| 维度 | `String.intern()` | G1 字符串去重 |
|------|-------------------|--------------|
| **去重对象** | `String` 对象（引用） | `byte[]` 数组（内容） |
| **机制** | 字符串常量池（`StringTable`，哈希表） | 去重表（`StringDedupTable`，哈希表） |
| **触发时机** | 显式调用 `intern()` | Young GC 时自动触发 |
| **线程** | 应用线程（STW 期间） | 后台去重线程（并发） |
| **内存节省** | 节省 `String` 对象（24 字节） | 节省 `byte[]` 数组（几十到几千字节） |
| **副作用** | 字符串常量池可能 OOM | 无副作用 |
| **适用场景** | 需要用 `==` 比较字符串 | 大量重复字符串，不需要 `==` 比较 |

### 3.2 `String.intern()` 的实现

```cpp
// stringTable.hpp:90
static oop intern(Handle string_or_null_h, jchar* name, int len, TRAPS);
```

`intern()` 把字符串加入 `StringTable`（字符串常量池），返回常量池中的引用。如果常量池中已有相同内容的字符串，返回已有的引用，原字符串对象可以被 GC 回收。

**`intern()` 去重的是 `String` 对象**：两个 `String` 对象 `intern()` 后，返回同一个 `String` 对象，可以用 `==` 比较。

**G1 去重的是 `byte[]` 数组**：两个 `String` 对象去重后，仍然是两个不同的 `String` 对象，不能用 `==` 比较，但它们的 `_value` 字段指向同一个 `byte[]`。

### 3.3 内存节省对比

```
场景：1000 个内容为 "hello" 的 String 对象

String 对象大小：24 字节（对象头 16B + _value 引用 4B + _hash 4B）
byte[] 大小：24 字节（对象头 16B + 5 字节数据 + 3 字节对齐）

不去重：
  1000 × 24（String）+ 1000 × 24（byte[]）= 48,000 字节

String.intern() 后：
  1（String）+ 1（byte[]）= 48 字节（节省 99.9%）
  但：需要显式调用，且常量池不会被 GC 回收（JDK 7+ 在堆中，可以 GC）

G1 字符串去重后：
  1000 × 24（String）+ 1（byte[]）= 24,024 字节（节省 50%）
  但：自动触发，无需修改代码
```

---

## 第 4 部分：类卸载机制

### 4.1 本质

**类卸载 = 当一个类加载器（ClassLoader）不再被引用时，它加载的所有类（Klass）和相关元数据从 Metaspace 中释放。**

### 4.2 触发时机

类卸载在**并发标记的 Remark 阶段**（STW）执行：

```cpp
// g1ConcurrentMark.cpp:1771
// Unload Klasses, String, Symbols, Code Cache, etc.
if (ClassUnloadingWithConcurrentMark) {
  GCTraceTime(Debug, gc, phases) debug("Class Unloading", _gc_timer_cm);
  bool purged_classes = SystemDictionary::do_unloading(_gc_timer_cm, false /* Defer cleaning */);
  _g1h->complete_cleaning(&g1_is_alive, purged_classes);
} else {
  // ★ 如果禁用了类卸载，只做字符串去重的清理
  _g1h->partial_cleaning(&g1_is_alive, false, false, G1StringDedup::is_enabled());
}
```

**Cleanup 阶段（并发）还有一次 Metaspace 清理**：

```cpp
// g1ConcurrentMark.cpp:1292
if (ClassUnloadingWithConcurrentMark) {
  GCTraceTime(Debug, gc, phases) debug("Purge Metaspace", _gc_timer_cm);
  ClassLoaderDataGraph::purge();  // ★ 释放已卸载类的 Metaspace 内存
}
```

### 4.3 类卸载的条件

```
类加载器 A 加载了类 Foo
    ↓
类加载器 A 不再被任何 GC Root 引用
    ↓
并发标记发现类加载器 A 是垃圾
    ↓
Remark 阶段：SystemDictionary::do_unloading()
    ↓
卸载类加载器 A 加载的所有类（Foo 等）
    ↓
Cleanup 阶段：ClassLoaderDataGraph::purge()
    ↓
释放 Metaspace 中的 Klass、Method、ConstantPool 等元数据
```

**关键约束**：
- **Bootstrap ClassLoader 加载的类永远不会被卸载**（`java.lang.Object`、`java.lang.String` 等）
- **只有自定义 ClassLoader 加载的类才可能被卸载**（Spring AOP 生成的代理类、Groovy 脚本类等）
- **类加载器本身必须不可达**（没有任何强引用指向它）

### 4.4 类卸载的 GC 日志

```bash
# 开启类卸载日志
-Xlog:class+unload=debug

# 输出示例
[1.234s][debug][class,unload] unloading class com.example.GeneratedProxy$1 0x00007f1234560000
[1.234s][debug][class,unload] unloading class com.example.GeneratedProxy$2 0x00007f1234570000
[1.235s][debug][gc,phases   ] GC(5) Purge Metaspace 2.3ms
```

### 4.5 控制参数

```bash
-XX:+ClassUnloadingWithConcurrentMark  # 并发标记期间卸载类（默认开启）
-XX:-ClassUnloading                    # 完全禁止类卸载（调试用，会导致 Metaspace OOM）
-XX:MetaspaceSize=256m                 # Metaspace 初始大小
-XX:MaxMetaspaceSize=512m              # Metaspace 最大大小（默认无限制）
```

---

## 第 5 部分：打桩验证

### 5.1 验证环境

```
JVM：OpenJDK 11 slowdebug
参数：-Xms8g -Xmx8g -XX:+UseG1GC -Xint -XX:+UseStringDeduplication -XX:StringDeduplicationAgeThreshold=3
场景：分配 10 万个重复字符串（100 种内容），触发多次 Young GC
```

### 5.2 打桩点 1：入队路径（`is_candidate_from_evacuation()`）

```
[PROBE-27d-enqueue] Young->Old (promotion): obj=0x600100040 age=0 threshold=3
[PROBE-27d-enqueue] Young->Old (promotion): obj=0x600100110 age=0 threshold=3
[PROBE-27d-enqueue] Young->Old (promotion): obj=0x600100218 age=0 threshold=3
```

**关键发现**：走的是 **Young→Old（晋升）** 路径，`age=0`！

**原因分析**：测试程序每轮分配 1GB 临时对象，Young 区（约 1.6GB）被填满，字符串在第一次 Young GC 时就被迫晋升到 Old 区（`age=0 < threshold=3`），走了"晋升时补入队"的路径。

这验证了源码中的设计：**晋升时补入队是为了防止漏掉那些还没来得及在 Young 区达到年龄阈值就被晋升的字符串。**

### 5.3 打桩点 2：新条目加入去重表（`PROBE-27d-new`）

```
[PROBE-27d-new] new entry: string=0x7ffc00eb0 value=0x7ffc00ec8 size_bytes=56 latin1=1 hash=0xa09ef8ab
[PROBE-27d-new] new entry: string=0x7ffc00f00 value=0x7ffc00f18 size_bytes=48 latin1=1 hash=0x8c31edbd
[PROBE-27d-new] new entry: string=0x7ffc00f48 value=0x7ffc00f60 size_bytes=32 latin1=1 hash=0x8087d182
[PROBE-27d-new] new entry: string=0x7ffc00f80 value=0x7ffc00f98 size_bytes=32 latin1=1 hash=0x350d005a
[PROBE-27d-new] new entry: string=0x7ffc02e28 value=0x7ffc02e40 size_bytes=24 latin1=1 hash=0x6c5e0272
```

**解读**：
- 这 5 个是 JVM 启动时的系统字符串（地址在 `0x7ffc...`，是 Old 区的低地址段）
- `latin1=1`：全部是 Latin-1 编码（ASCII 字符）
- `size_bytes=24~56`：`byte[]` 大小 24~56 字节，对应 8~40 个字符的字符串

### 5.4 打桩点 3：去重发生（`PROBE-27d-dedup`）

```
[PROBE-27d-dedup] dedup: string=0x6156b41e0 old_value=0x6156b41f8 new_value=0x6156b4380 size_bytes=32 latin1=1 hash=0xb4f18ec0
[PROBE-27d-dedup] dedup: string=0x6156b4170 old_value=0x6156b4188 new_value=0x6156b4348 size_bytes=32 latin1=1 hash=0xe9404951
[PROBE-27d-dedup] dedup: string=0x6156b4100 old_value=0x6156b4118 new_value=0x6156b42d8 size_bytes=32 latin1=1 hash=0xe9404958
[PROBE-27d-dedup] dedup: string=0x6156ae448 old_value=0x6156ae460 new_value=0x6156b94d8 size_bytes=32 latin1=1 hash=0xe9404994
[PROBE-27d-dedup] dedup: string=0x6156ae410 old_value=0x6156ae428 new_value=0x6156bc1f8 size_bytes=32 latin1=1 hash=0xe9404995
```

**解读**：
- `old_value ≠ new_value`：`byte[]` 被替换了（`string._value` 从 `old_value` 改为 `new_value`）
- `size_bytes=32`：每个 `byte[]` 32 字节（对应 `"hello-world-XX"` 这样的字符串，约 14 字符）
- `latin1=1`：全部是 Latin-1 编码
- 每次去重节省 32 字节，原来的 `old_value` 数组不再被引用，下次 GC 时会被回收

### 5.5 GC 日志中的去重统计

```
[3.203s][info][gc,stringdedup] Concurrent String Deduplication (3.203s)
[3.900s][info][gc,stringdedup] Concurrent String Deduplication 3297.3K->119.0K(3178.3K) avg 96.4% (3.203s, 3.900s) 253.125ms
```

**解读**：
- `3297.3K->119.0K(3178.3K)`：去重前 3297.3K，去重后 119.0K，**节省了 3178.3K（约 3.1MB）**
- `avg 96.4%`：平均去重率 96.4%（100 种内容，每种 1000 个，去重后每种只保留 1 个 `byte[]`）
- `253.125ms`：去重线程运行了 253ms（后台并发，不影响 STW 时间）

### 5.6 验证总结

| 打桩点 | 实测结果 | 验证的结论 |
|--------|---------|-----------|
| `PROBE-27d-enqueue` | Young→Old 路径，`age=0` | 晋升时补入队机制有效，防止漏掉被迫晋升的字符串 |
| `PROBE-27d-new` | 5 条系统字符串加入表 | 去重表在 JVM 启动时就开始工作 |
| `PROBE-27d-dedup` | `old_value ≠ new_value`，`size=32` | `byte[]` 被替换，`String` 对象本身不变 |
| GC 日志 | 节省 3.1MB，去重率 96.4% | 大量重复字符串场景下去重效果显著 |

---

## 第 6 部分：猜测 vs 实测

| 我的猜测 | 实际情况 | 打脸了吗？ |
|---------|---------|-----------|
| 字符串去重在 GC 停顿期间执行 | **不对！** 去重在后台并发线程（`StrDedup`）中执行，不增加 STW 时间 | ✅ 打脸 |
| 去重的是 `String` 对象 | **不对！** 去重的是 `byte[]` 数组，`String` 对象本身不变 | ✅ 打脸 |
| 所有字符串都会被去重 | **不对！** 只有存活 N 次 Young GC 的字符串才入队（默认 3 次） | ✅ 打脸 |
| `String.intern()` 和字符串去重效果一样 | **不对！** `intern()` 去重引用（可用 `==`），G1 去重 `byte[]`（不能用 `==`） | ✅ 打脸 |
| 类卸载在 Full GC 时触发 | **不对！** 类卸载在并发标记的 Remark 阶段（STW）触发，不需要 Full GC | ✅ 打脸 |
| Bootstrap ClassLoader 的类也能被卸载 | **不对！** Bootstrap ClassLoader 的类永远不会被卸载 | ✅ 打脸 |

---

## 第 7 部分：数据结构关系图

```mermaid
classDiagram
    class G1StringDedup {
        +initialize()
        +enqueue_from_evacuation(from_young, to_young, worker_id, java_string)
        +enqueue_from_mark(java_string, worker_id)
        +unlink_or_oops_do(is_alive, keep_alive, allow_resize_and_rehash)
    }

    class G1StringDedupQueue {
        +size_t _nqueues
        +G1StringDedupWorkerQueue* _queues
        +volatile bool _empty
        +volatile uintx _dropped
        +push(worker_id, java_string)
        +pop() oop
    }

    class StringDedupThread {
        +do_deduplication()
        +deduplicate_shared_strings()
    }

    class StringDedupTable {
        +StringDedupEntry** _buckets
        +size_t _size
        +uintx _entries
        +uint64_t _hash_seed
        +deduplicate(java_string, stat)
        +lookup_or_add(value, latin1, hash)
    }

    class StringDedupEntry {
        +StringDedupEntry* _next
        +unsigned int _hash
        +bool _latin1
        +typeArrayOop _obj
    }

    G1StringDedup --> G1StringDedupQueue : push
    StringDedupThread --> G1StringDedupQueue : pop
    StringDedupThread --> StringDedupTable : deduplicate
    StringDedupTable "1" --> "*" StringDedupEntry : _buckets
    StringDedupEntry --> "byte[]" : _obj (弱引用)
```

---

## 第 8 部分：总结

### 8.1 数据结构层面

| 结构 | 核心特征 |
|------|---------|
| `G1StringDedupQueue` | 每个 GC Worker 一个子队列，入队无锁，出队轮询 |
| `StringDedupEntry` | 弱引用 `byte[]`，GC 时自动清除死亡条目 |
| `StringDedupTable` | 动态扩缩容哈希表（1024~16M 桶），负载因子 200% 时扩容 |

### 8.2 算法层面

| 算法 | 核心设计决策 |
|------|------------|
| **入队判断** | 年龄阈值（默认 3）过滤短命字符串，只对"老"字符串去重 |
| **去重执行** | 后台并发线程，`SuspendibleThreadSetJoiner` 保证 SafePoint 时主动让步 |
| **表维护** | 弱引用自动清除死亡条目，动态扩缩容避免内存浪费 |
| **类卸载** | Remark 阶段（STW）执行，Cleanup 阶段（并发）释放 Metaspace |

### 8.3 核心要点

1. **字符串去重是后台并发的**：不增加 GC 停顿时间，但有 CPU 开销
2. **去重的是 `byte[]` 不是 `String`**：去重后两个 `String` 对象仍然不能用 `==` 比较
3. **年龄阈值是关键参数**：`-XX:StringDeduplicationAgeThreshold=3`（默认），降低可以更早去重但增加 CPU 开销
4. **类卸载不需要 Full GC**：并发标记的 Remark 阶段就能触发类卸载
5. **Bootstrap ClassLoader 的类永远不卸载**：只有自定义 ClassLoader 的类才能被卸载

---

## 还没搞懂的地方

- [ ] **字符串去重的哈希冲突处理**：`StringDedupTable` 使用链地址法处理哈希冲突，当两个不同的 `byte[]` 内容相同但哈希值不同时，如何保证去重的正确性？`_hash_seed` 的随机化是否会导致同一内容在不同 JVM 实例中有不同的哈希值？

- [ ] **类卸载与 JIT 编译代码的关系**：当一个类被卸载时，JIT 编译器为该类生成的机器码（CodeBlob）如何处理？是立即失效还是延迟清理？`CodeCache` 的清理时机是什么？

- [ ] **`G1StringDedupQueue` 的背压机制**：如果去重线程处理速度跟不上入队速度，队列会无限增长吗？有没有背压机制（如丢弃低优先级条目）？

---

## 继续深入

- **[第 27e 篇：引用处理](./27e-g1-reference-HandWritten.md)** — G1 的另一个辅助机制：SoftRef/WeakRef/PhantomRef 在 GC 时的处理流程
- **[第 26 篇：并发标记与 SATB](./26-g1-concurrent-mark-HandWritten.md)** — 类卸载发生在并发标记的 Remark 阶段，这里有完整的并发标记流程分析
- **[第 29 篇：GC 日志深度解读](./29-g1-gc-log-HandWritten.md)** — 如何从 GC 日志中识别字符串去重的效果（`-Xlog:gc+stringdedup`）
- **相关源码**：
  - `src/hotspot/share/gc/g1/g1StringDedup.cpp`（字符串去重入口）
  - `src/hotspot/share/gc/g1/g1StringDedupThread.cpp`（去重后台线程）
  - `src/hotspot/share/gc/g1/g1StringDedupTable.cpp`（去重哈希表）
  - `src/hotspot/share/classfile/classLoaderData.cpp`（ClassLoaderData 生命周期）

---

*写于 2026-03-08*  
*参考：彭成寒《JVM G1源码分析和调优》第 9 章*
