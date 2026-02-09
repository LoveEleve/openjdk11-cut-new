# 12. StringTable::create_table()

> StringTable：Java 字符串常量池的底层实现（String.intern()）

## 1. 源码入口

```cpp
// src/hotspot/share/memory/universe.cpp:853
StringTable::create_table();

// src/hotspot/share/classfile/stringTable.hpp:107
static void create_table() {
    assert(_the_table == NULL, "One string table allowed.");
    _the_table = new StringTable();
}
```

## 2. StringTable vs SymbolTable

| 特性 | StringTable | SymbolTable |
|------|-------------|-------------|
| 存储内容 | Java String 对象（oop） | Symbol（UTF-8 字节数组） |
| 引用类型 | **弱引用**（GC 可回收） | 引用计数 |
| 存储位置 | Java 堆 | C++ 堆（Arena/Metaspace） |
| 编码 | UTF-16 | 修改的 UTF-8 |
| 哈希表类型 | ConcurrentHashTable（无锁） | 传统链表哈希表 |
| 默认大小 | 65536 桶 | 20011 桶 |

## 3. 核心数据结构

### 3.1 总体架构

```
StringTable（无锁并发哈希表）
┌─────────────────────────────────────────────────────────────────────────────────────┐
│  StringTable @ 0x7ffff0c92d00                                                       │
│  ┌────────────────────────────────────────────────────────────────────────────────┐ │
│  │ _the_table (static) = this                                                     │ │
│  │ _current_size = 65536                                                          │ │
│  │ _items = 0 (当前条目数)                                                         │ │
│  │ _uncleaned_items = 0 (待清理的死亡条目)                                         │ │
│  │ _has_work = false                                                              │ │
│  │ _needs_rehashing = false                                                       │ │
│  └────────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                      │
│  _weak_handles ─────────────────────────────────────────────────────────────────┐   │
│  (OopStorage: 存储弱引用)                                                        │   │
│  ┌─────────────────────────────────────────────────────────────────────────────┐│   │
│  │ OopStorage "StringTable weak"                                               ││   │
│  │ _allocation_mutex = StringTableWeakAlloc_lock                               ││   │
│  │ _active_mutex = StringTableWeakActive_lock                                  ││   │
│  │                                                                             ││   │
│  │ 存储 WeakHandle<vm_string_table_data>                                       ││   │
│  │ 每个 WeakHandle 指向一个 String 对象                                         ││   │
│  └─────────────────────────────────────────────────────────────────────────────┘│   │
│                                                                                  ▼   │
│  _local_table ──────────────────────────────────────────────────────────────────┐   │
│  (ConcurrentHashTable: 无锁并发哈希表)                                           │   │
│  ┌─────────────────────────────────────────────────────────────────────────────┐│   │
│  │ StringTableHash (ConcurrentHashTable<WeakHandle, StringTableConfig>)        ││   │
│  │                                                                             ││   │
│  │ _log2_size = 16 (2^16 = 65536 桶)                                          ││   │
│  │ _log2_size_limit = 24 (最大 2^24 = 16M 桶)                                 ││   │
│  │ _rehash_len = 100 (链长超过 100 触发 rehash)                                ││   │
│  │                                                                             ││   │
│  │ Bucket[65536]:                                                              ││   │
│  │ ┌─────────┬─────────┬─────────┬─────────┬────────────────────────────┐     ││   │
│  │ │bucket[0]│bucket[1]│bucket[2]│  ...    │              bucket[65535] │     ││   │
│  │ │ _first  │ _first  │ _first  │         │                            │     ││   │
│  │ │  NULL   │   ──────┼───┐     │         │                            │     ││   │
│  │ └─────────┴─────────┴───┼─────┴─────────┴────────────────────────────┘     ││   │
│  │                         │                                                   ││   │
│  │                         ▼                                                   ││   │
│  │                  ┌─────────────────────┐                                    ││   │
│  │                  │  Node               │                                    ││   │
│  │                  │  _next ────────────────┐                                 ││   │
│  │                  │  _value: WeakHandle │  │                                 ││   │
│  │                  │    ↓                │  │                                 ││   │
│  │                  │  oop* → String      │  ▼                                 ││   │
│  │                  └─────────────────────┘ Node ...                           ││   │
│  └─────────────────────────────────────────────────────────────────────────────┘│   │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 关键类关系

```cpp
// StringTable 使用的哈希表类型
typedef ConcurrentHashTable<WeakHandle<vm_string_table_data>,
                            StringTableConfig, mtSymbol> StringTableHash;

// WeakHandle：弱引用包装
template <WeakHandleType T>
class WeakHandle {
    oop* _obj;  // 指向 OopStorage 中的槽位
};

// ConcurrentHashTable：无锁并发哈希表
template <typename VALUE, typename CONFIG, MEMFLAGS F>
class ConcurrentHashTable {
    class Node {
        Node* volatile _next;
        VALUE _value;  // WeakHandle
    };
    class Bucket {
        Node* volatile _first;  // 低 2 位用于自旋锁状态
    };
};
```

## 4. 构造函数分析

```cpp
// src/hotspot/share/classfile/stringTable.cpp:185
StringTable::StringTable() : 
    _local_table(NULL), 
    _current_size(0), 
    _has_work(0),
    _needs_rehashing(false), 
    _weak_handles(NULL), 
    _items(0), 
    _uncleaned_items(0) 
{
    // 1. 创建 OopStorage（弱引用存储）
    _weak_handles = new OopStorage("StringTable weak",
                                   StringTableWeakAlloc_lock,
                                   StringTableWeakActive_lock);
    
    // 2. 计算哈希表初始大小
    size_t start_size_log_2 = ceil_pow_2(StringTableSize);  // 65536 → 16
    _current_size = ((size_t)1) << start_size_log_2;        // 2^16 = 65536
    
    // 3. 创建 ConcurrentHashTable
    _local_table = new StringTableHash(
        start_size_log_2,   // 初始大小：2^16 = 65536
        END_SIZE,           // 最大大小：2^24 = 16M
        REHASH_LEN          // rehash 阈值：链长 100
    );
}
```

### 4.1 为什么使用弱引用？

```
┌─────────────────────────────────────────────────────────────────────┐
│ 问题：String.intern() 返回的字符串如果没有其他引用，应该能被 GC 回收 │
│                                                                      │
│ 解决：使用 WeakHandle 包装，GC 时：                                  │
│   1. 如果 String 没有其他强引用 → 回收 String 对象                   │
│   2. WeakHandle 变成"死亡"状态（peek() 返回 NULL）                   │
│   3. 后台任务清理死亡条目                                            │
└─────────────────────────────────────────────────────────────────────┘
```

### 4.2 为什么使用 ConcurrentHashTable？

```
传统哈希表（SymbolTable）：
  - 操作需要加锁
  - 高并发场景性能差

ConcurrentHashTable：
  - 无锁读取
  - 细粒度锁写入（每个 Bucket 有独立的自旋锁）
  - 支持并发扩容
  - 适合高并发的 intern() 场景
```

## 5. String.intern() 实现

### 5.1 intern 流程

```cpp
// src/hotspot/share/classfile/stringTable.cpp:315
oop StringTable::intern(Handle string_or_null_h, jchar* name, int len, TRAPS) {
    // 1. 计算哈希
    unsigned int hash = java_lang_String::hash_code(name, len);
    
    // 2. 先查共享表（CDS）
    oop found_string = lookup_shared(name, len, hash);
    if (found_string != NULL) return found_string;
    
    // 3. 查动态表
    found_string = do_lookup(name, len, hash);
    if (found_string != NULL) return found_string;
    
    // 4. 未找到，插入新条目
    return do_intern(string_or_null_h, name, len, hash, THREAD);
}
```

### 5.2 查找流程

```cpp
oop StringTable::do_lookup(jchar* name, int len, uintx hash) {
    Thread* thread = Thread::current();
    StringTableLookupJchar lookup(thread, hash, name, len);
    StringTableGet stg(thread);
    bool rehash_warning;
    
    // ConcurrentHashTable 的无锁查找
    _local_table->get(thread, lookup, stg, &rehash_warning);
    
    if (rehash_warning) {
        _needs_rehashing = true;  // 链太长，需要 rehash
    }
    return stg.get_res_oop();
}
```

### 5.3 插入流程

```cpp
oop StringTable::do_intern(Handle string_or_null_h, jchar* name,
                           int len, uintx hash, TRAPS) {
    // 1. 如果没有传入 String，创建新的
    Handle string_h;
    if (string_or_null_h.is_null()) {
        string_h = java_lang_String::create_from_unicode(name, len, CHECK_NULL);
    } else {
        string_h = string_or_null_h;
    }
    
    // 2. 创建 WeakHandle
    StringTableCreateEntry stc(THREAD, string_h);
    
    // 3. 插入到 ConcurrentHashTable
    bool rehash_warning;
    bool clean_hint;
    _local_table->insert(THREAD, lookup, stc, &rehash_warning, &clean_hint);
    
    return stc.get_return();
}
```

## 6. GC 与清理

### 6.1 弱引用处理

```
GC 期间的 StringTable 处理：
┌─────────────────────────────────────────────────────────────────────┐
│ 1. 标记阶段：                                                        │
│    - 不把 StringTable 中的 String 作为根                             │
│    - 只有通过其他路径可达的 String 才会被标记                        │
│                                                                      │
│ 2. 清理阶段：                                                        │
│    - 遍历 OopStorage 中的弱引用                                      │
│    - 如果 String 未被标记 → 置为 NULL（死亡）                        │
│    - 记录死亡条目数量 (_uncleaned_items)                             │
│                                                                      │
│ 3. 后台清理：                                                        │
│    - ServiceThread 检查 _has_work 标志                               │
│    - 调用 clean_dead_entries() 移除死亡条目                          │
└─────────────────────────────────────────────────────────────────────┘
```

### 6.2 清理触发条件

```cpp
// src/hotspot/share/classfile/stringTable.cpp:63
#define CLEAN_DEAD_HIGH_WATER_MARK 0.5  // 死亡条目达到桶数的 50%

void StringTable::check_concurrent_work() {
    // 死亡比例 = _uncleaned_items / _current_size
    double dead_factor = get_dead_factor();
    
    if (dead_factor > CLEAN_DEAD_HIGH_WATER_MARK) {
        trigger_concurrent_work();  // 触发后台清理
    }
}
```

## 7. 动态扩容

```
ConcurrentHashTable 扩容机制：
┌─────────────────────────────────────────────────────────────────────┐
│ 触发条件：                                                           │
│   - 负载因子 > 阈值（平均链长 > PREF_AVG_LIST_LEN = 2）             │
│   - 或某条链长 > REHASH_LEN = 100                                   │
│                                                                      │
│ 扩容过程：                                                           │
│   1. 分配新的 Bucket 数组（大小翻倍）                                │
│   2. 并发迁移：多线程分段迁移条目                                    │
│   3. 原子替换：完成后替换指针                                        │
│                                                                      │
│ 大小范围：                                                           │
│   - 初始：2^16 = 65,536 桶                                          │
│   - 最大：2^24 = 16,777,216 桶                                      │
└─────────────────────────────────────────────────────────────────────┘
```

## 8. 初始化后的状态

```
StringTable 创建后
┌─────────────────────────────────────────────────────────────────────┐
│                                                                      │
│  StringTable @ 0x7ffff0c92d00                                        │
│  ├── _current_size = 65536                                           │
│  ├── _items = 0                                                      │
│  ├── _uncleaned_items = 0                                            │
│  ├── _has_work = false                                               │
│  ├── _needs_rehashing = false                                        │
│  │                                                                   │
│  ├── _weak_handles (OopStorage)                                      │
│  │   ├── _name = "StringTable weak"                                  │
│  │   ├── _allocation_count = 0                                       │
│  │   └── _active_array: Block* [8] = {NULL, ...}                     │
│  │                                                                   │
│  └── _local_table (ConcurrentHashTable)                              │
│      ├── _log2_size = 16                                             │
│      ├── _log2_size_limit = 24                                       │
│      └── Bucket[65536] = {NULL, NULL, ...}                           │
│                                                                      │
│  内存占用：                                                           │
│  - Bucket 数组：65536 × 8 = 512KB                                    │
│  - OopStorage：约 1KB（空）                                          │
│  - 总计：约 513KB                                                    │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

## 9. GDB 验证

```gdb
# 断点
b StringTable::create_table

# 执行
(gdb) finish

# 查看 StringTable
(gdb) p StringTable::_the_table
$1 = (StringTable *) 0x7ffff0c92d00

(gdb) p *StringTable::_the_table
$2 = {
  _local_table = 0x7ffff0c92e00,
  _current_size = 65536,
  _has_work = false,
  _needs_rehashing = false,
  _weak_handles = 0x7ffff0c92d80,
  _items = 0,
  _uncleaned_items = 0
}

# 查看 OopStorage
(gdb) p *StringTable::_the_table->_weak_handles
$3 = {
  _name = "StringTable weak",
  _allocation_count = 0,
  ...
}
```

## 10. JVM 参数

```bash
# 调整 StringTable 大小
java -XX:StringTableSize=1000003 MyApp

# 打印 StringTable 统计
java -XX:+PrintStringTableStatistics MyApp

# 输出示例：
# StringTable statistics:
# Number of buckets       :     65536 =    524288 bytes, each 8
# Number of entries       :     12345
# Number of literals      :     12345 =    493800 bytes, avg  40.000
# Total footprint         :           =   1018088 bytes
```

## 11. 设计要点总结

| 特性 | 实现 |
|------|------|
| 弱引用 | WeakHandle + OopStorage，允许 GC 回收无引用的 intern 字符串 |
| 无锁并发 | ConcurrentHashTable，读无锁，写细粒度自旋锁 |
| 动态扩容 | 支持从 2^16 扩展到 2^24 桶 |
| 后台清理 | ServiceThread 异步清理死亡条目 |
| 共享支持 | CDS 共享表 + 动态表 |

**与 SymbolTable 的关键区别**：
1. StringTable 使用**弱引用**，SymbolTable 使用引用计数
2. StringTable 存储**Java 堆中的 String 对象**，SymbolTable 存储 C++ 堆中的 Symbol
3. StringTable 使用**无锁并发哈希表**，SymbolTable 使用传统加锁哈希表

---

## 下一步

StringTable 是 `String.intern()` 的底层实现，理解它对于优化字符串密集型应用很重要。

接下来可以分析：
- **13. ResolvedMethodTable::create_table()** - 方法句柄缓存
- **9. ClassLoaderData::init_null_class_loader_data()** - Bootstrap ClassLoader
- **6. 性能计数器初始化** - PerfData
