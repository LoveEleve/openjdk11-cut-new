# 11. SymbolTable::create_table()

> SymbolTable：存储 JVM 中所有符号（类名、方法名、字段名等）的全局哈希表

## 1. 源码入口

```cpp
// src/hotspot/share/memory/universe.cpp:852
SymbolTable::create_table();
StringTable::create_table();
```

## 2. 什么是 Symbol？

### 2.1 Symbol vs String

| 特性 | Symbol | String |
|------|--------|--------|
| 存储内容 | 类名、方法名、字段名、签名 | Java 字符串对象 |
| 存储位置 | C++ 堆（Arena）或 Metaspace | Java 堆 |
| 编码 | 修改的 UTF-8 | UTF-16 |
| 引用计数 | 有（非永久 Symbol） | 无（由 GC 管理） |
| 唯一性 | 相同内容只有一份 | 可以有多份 |

### 2.2 Symbol 的用途

```
Symbol 用于 JVM 内部标识：
┌────────────────────────────────────────────────────────────────────┐
│ 1. 类名：       "java/lang/Object", "com/example/MyClass"         │
│ 2. 方法名：     "main", "<init>", "<clinit>"                      │
│ 3. 字段名：     "value", "count", "hash"                          │
│ 4. 方法签名：   "(Ljava/lang/String;)V", "()I"                    │
│ 5. 字段描述符： "I", "J", "[Ljava/lang/String;"                   │
└────────────────────────────────────────────────────────────────────┘
```

### 2.3 Symbol 的内存布局

```cpp
// src/hotspot/share/oops/symbol.hpp:104
class Symbol : public MetaspaceObj {
  ATOMIC_SHORT_PAIR(
    volatile short _refcount,   // 引用计数（-1 = 永久）
    unsigned short _length      // UTF8 字符数
  );
  short _identity_hash;         // 身份哈希
  jbyte _body[2];               // UTF8 字节（变长）
};
```

内存布局示例（`"java/lang/Object"` = 16 字节）：
```
Symbol 实例（约 24 字节）
┌─────────────────────────────────────────────────────────────────┐
│ _refcount (2 字节)  │ _length (2 字节)                          │
│      -1 (永久)      │     16                                    │
├─────────────────────────────────────────────────────────────────┤
│ _identity_hash (2 字节)                                         │
├─────────────────────────────────────────────────────────────────┤
│ _body[16]: "java/lang/Object"                                   │
│  'j' 'a' 'v' 'a' '/' 'l' 'a' 'n' 'g' '/' 'O' 'b' 'j' 'e' 'c' 't'│
└─────────────────────────────────────────────────────────────────┘

大小计算：
sizeof(Symbol) = 2 + 2 + 2 + 2 = 8 字节（基础）
实际大小 = 8 + (length - 2) = 8 + 14 = 22 字节，对齐到 24 字节
```

## 3. SymbolTable 数据结构

### 3.1 总体架构

```
SymbolTable（开放寻址哈希表）
┌─────────────────────────────────────────────────────────────────────────────┐
│  SymbolTable @ 0x7ffff0c92b60                                               │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │ _the_table (static) = this                                             │ │
│  │ _needs_rehashing = false                                               │ │
│  │ _table_size = 20011 (质数)                                             │ │
│  │ _entry_size = 24 (sizeof HashtableEntry)                               │ │
│  │ _number_of_entries = 0                                                 │ │
│  │ _free_list = NULL                                                      │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│  _buckets ──────────────────────────────────────────────────────────────┐   │
│                                                                          │   │
│  ┌───────────────────────────────────────────────────────────────────────┼──┤
│  │  HashtableBucket[20011]                                               ▼  │
│  │  ┌─────────┬─────────┬─────────┬─────────┬─────────┬─────────────────┐  │
│  │  │bucket[0]│bucket[1]│bucket[2]│  ...    │bucket[N]│...bucket[20010] │  │
│  │  │ _entry  │ _entry  │ _entry  │         │ _entry  │                 │  │
│  │  │  NULL   │  NULL   │   ──────┼───┐     │  NULL   │                 │  │
│  │  └─────────┴─────────┴─────────┴───┼─────┴─────────┴─────────────────┘  │
│  │                                    │                                     │
│  │                                    ▼                                     │
│  │                           ┌────────────────────────────┐                 │
│  │                           │ HashtableEntry             │                 │
│  │                           │  _hash = 0x12345678        │                 │
│  │                           │  _next ─────────────────────────┐            │
│  │                           │  _literal ──────┐          │    │            │
│  │                           └─────────────────┼──────────┘    │            │
│  │                                             │               │            │
│  │                                             ▼               ▼            │
│  │                                      ┌───────────┐   ┌───────────┐       │
│  │                                      │  Symbol   │   │ Entry...  │       │
│  │                                      │ "Object"  │   │           │       │
│  │                                      └───────────┘   └───────────┘       │
│  └──────────────────────────────────────────────────────────────────────────┘
│                                                                              │
│  Arena @ 0x7ffff0c92bd0 (用于分配永久 Symbol)                               │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │ _flags = mtSymbol                                                      │ │
│  │ _size_in_bytes = 360KB                                                 │ │
│  │ _first ──────┐   _chunk ──────┐                                        │ │
│  │              │                │                                        │ │
│  │              ▼                ▼                                        │ │
│  │         ┌─────────────────────────────────────────────────────────┐   │ │
│  │         │                    Chunk (360KB)                        │   │ │
│  │         │  _next = NULL                                           │   │ │
│  │         │  _len = 368640                                          │   │ │
│  │         │  ┌─────────────────────────────────────────────────────┐│   │ │
│  │         │  │ Symbol 分配区域                                     ││   │ │
│  │         │  │ ← _hwm (高水位，下次分配位置)                        ││   │ │
│  │         │  │                                                     ││   │ │
│  │         │  │ ← _max (最大位置)                                    ││   │ │
│  │         │  └─────────────────────────────────────────────────────┘│   │ │
│  │         └─────────────────────────────────────────────────────────┘   │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 关键数据结构

```cpp
// HashtableBucket - 桶（8 字节）
template <MEMFLAGS F> class HashtableBucket {
    BasicHashtableEntry<F>* _entry;  // 指向链表头
};

// BasicHashtableEntry - 基础条目（16 字节）
template <MEMFLAGS F> class BasicHashtableEntry {
    unsigned int _hash;               // 32 位哈希值
    BasicHashtableEntry<F>* _next;    // 链表指针
};

// HashtableEntry - 符号条目（24 字节）
template <class T, MEMFLAGS F> class HashtableEntry : public BasicHashtableEntry<F> {
    T _literal;                       // Symbol* 指针
};
```

### 3.3 为什么是 20011 个桶？

```cpp
// src/hotspot/share/utilities/globalDefinitions.hpp:486
const int defaultSymbolTableSize = 20011;
const int minimumSymbolTableSize = 1009;
```

**20011 是质数**：
- 质数桶数量能使哈希分布更均匀
- 减少哈希冲突
- 这是哈希表设计的经典做法

**内存计算**：
```
桶数组大小 = 20011 × 8 字节 = 160,088 字节 ≈ 156KB
```

## 4. create_table() 源码分析

```cpp
// src/hotspot/share/classfile/symbolTable.hpp:222
static void create_table() {
    assert(_the_table == NULL, "One symbol table allowed.");
    
    // 1. 创建哈希表
    _the_table = new SymbolTable();
    
    // 2. 创建 Arena（360KB）
    initialize_symbols(symbol_alloc_arena_size);  // 360KB
}

// SymbolTable 构造函数
SymbolTable()
    : RehashableHashtable<Symbol*, mtSymbol>(
          SymbolTableSize,                           // 20011
          sizeof(HashtableEntry<Symbol*, mtSymbol>)  // 24
      ) {}

// initialize_symbols
void SymbolTable::initialize_symbols(int arena_alloc_size) {
    _arena = new (mtSymbol) Arena(mtSymbol, arena_alloc_size);  // 360KB
}
```

## 5. Arena：Symbol 的内存池

### 5.1 为什么需要 Arena？

```
传统分配方式：每次 malloc
┌─────────────────────────────────────────────────────────────────┐
│ 问题：                                                          │
│ 1. 每次分配都有 malloc 开销                                     │
│ 2. 内存碎片化                                                   │
│ 3. Symbol 很小（几十字节），malloc 开销相对较大                 │
└─────────────────────────────────────────────────────────────────┘

Arena 方式：预分配大块，内部线性分配
┌─────────────────────────────────────────────────────────────────┐
│ 优点：                                                          │
│ 1. 一次 malloc 360KB，后续分配只需移动指针                      │
│ 2. 无碎片化                                                     │
│ 3. 分配速度极快（指针 bump）                                    │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 Arena 结构

```cpp
// src/hotspot/share/memory/arena.hpp:93
class Arena : public CHeapObj<mtNone> {
    MEMFLAGS _flags;        // mtSymbol
    Chunk* _first;          // 第一个 Chunk
    Chunk* _chunk;          // 当前 Chunk
    char* _hwm;             // High Water Mark（下次分配位置）
    char* _max;             // 当前 Chunk 的最大位置
    size_t _size_in_bytes;  // 总大小
};
```

### 5.3 分配流程

```cpp
// Arena 分配（伪代码）
void* Arena::Amalloc(size_t size) {
    if (_hwm + size <= _max) {
        // 快速路径：直接在当前 Chunk 分配
        void* result = _hwm;
        _hwm += size;
        return result;
    } else {
        // 慢路径：需要新的 Chunk
        return grow(size);
    }
}
```

```
Arena 分配示意图
┌─────────────────────────────────────────────────────────────────┐
│  Chunk (360KB)                                                  │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ Symbol1 │ Symbol2 │ Symbol3 │ ... │ 空闲空间                 ││
│  │         │         │         │     │ ← _hwm                  ││
│  │         │         │         │     │                         ││
│  │         │         │         │     │ ← _max                  ││
│  └─────────────────────────────────────────────────────────────┘│
│                                                                 │
│  分配 Symbol4:                                                  │
│  1. 检查 _hwm + size <= _max                                    │
│  2. result = _hwm                                               │
│  3. _hwm += size                                                │
│  4. 返回 result                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## 6. Symbol 的引用计数

### 6.1 两种 Symbol

| 类型 | refcount | 分配位置 | 生命周期 |
|------|----------|----------|----------|
| 永久 Symbol | -1 (PERM_REFCOUNT) | Arena | 永不回收 |
| 临时 Symbol | >= 1 | C++ 堆 | 引用计数归零时回收 |

### 6.2 永久 Symbol 的场景

```
永久 Symbol（refcount = -1）：
- JDK 核心类名：java/lang/Object, java/lang/String
- 常用方法名：<init>, <clinit>, main
- 基本类型描述符：I, J, Z, V

临时 Symbol（refcount >= 1）：
- 应用类名：com/example/MyClass
- 应用方法名和字段名
- 动态生成的类
```

### 6.3 引用计数管理

```cpp
// src/hotspot/share/oops/symbol.cpp
void Symbol::increment_refcount() {
    if (_refcount != PERM_REFCOUNT) {  // -1 永久不变
        Atomic::inc(&_refcount);
    }
}

void Symbol::decrement_refcount() {
    if (_refcount != PERM_REFCOUNT) {
        short new_value = Atomic::add((short)-1, &_refcount);
        // 当 refcount 变为 0，由 GC 后续清理
    }
}
```

## 7. 哈希与查找

### 7.1 哈希函数

```cpp
// src/hotspot/share/classfile/symbolTable.cpp
unsigned int SymbolTable::hash_symbol(const char* s, int len) {
    // 使用 java_lang_String 的哈希算法
    unsigned int h = 0;
    while (len-- > 0) {
        h = 31 * h + (unsigned char) *s++;
    }
    return h;
}
```

### 7.2 查找流程

```cpp
Symbol* SymbolTable::lookup(const char* name, int len, TRAPS) {
    unsigned int hash = hash_symbol(name, len);
    int index = the_table()->hash_to_index(hash);  // hash % 20011
    
    // 1. 先查共享表（CDS）
    Symbol* sym = lookup_shared(name, len, hash);
    if (sym != NULL) return sym;
    
    // 2. 查动态表
    sym = lookup_dynamic(index, name, len, hash);
    if (sym != NULL) return sym;
    
    // 3. 未找到，创建新 Symbol
    return basic_add(index, name, len, hash, ...);
}
```

```
查找示意图
┌─────────────────────────────────────────────────────────────────┐
│ 查找 "java/lang/Object"                                         │
│                                                                 │
│ 1. 计算哈希: h = hash_symbol("java/lang/Object", 16)            │
│    h = 31*0 + 'j' = 106                                         │
│    h = 31*106 + 'a' = 3383                                      │
│    ... 继续计算 ...                                             │
│    最终 h = 某个 32 位值                                        │
│                                                                 │
│ 2. 计算桶索引: index = h % 20011                                │
│                                                                 │
│ 3. 遍历链表:                                                    │
│    bucket[index] → Entry1 → Entry2 → Entry3 → NULL              │
│                      ↓        ↓        ↓                        │
│                   Symbol1  Symbol2  Symbol3                     │
│                                                                 │
│    比较每个 Symbol 的内容，找到匹配的返回                        │
└─────────────────────────────────────────────────────────────────┘
```

## 8. GDB 验证

```gdb
# 设置断点
b SymbolTable::create_table

# 运行到断点后
(gdb) finish

# 查看 SymbolTable
(gdb) p SymbolTable::_the_table
$1 = (SymbolTable *) 0x7ffff0c92b60

(gdb) p *SymbolTable::_the_table
$2 = {
  <RehashableHashtable<Symbol*, (MEMFLAGS)5>> = {
    <Hashtable<Symbol*, (MEMFLAGS)5>> = {
      <BasicHashtable<(MEMFLAGS)5>> = {
        _table_size = 20011,
        _buckets = 0x7ffff407c030,
        _entry_size = 24,
        _number_of_entries = 0
      }
    }
  },
  _needs_rehashing = false
}

# 查看 Arena
(gdb) p SymbolTable::_arena
$3 = (Arena *) 0x7ffff0c92bd0

(gdb) p *SymbolTable::_arena
$4 = {
  _flags = mtSymbol,
  _first = 0x7ffff4021030,
  _chunk = 0x7ffff4021030,
  _hwm = 0x7ffff4021050,   # 下次分配位置
  _max = 0x7ffff407b050,   # Chunk 末尾
  _size_in_bytes = 368640  # 360KB
}

# 查看 Chunk
(gdb) p *((Chunk*)0x7ffff4021030)
$5 = {
  _next = 0x0,
  _len = 368640
}
```

## 9. JVM 参数

```bash
# 调整 SymbolTable 大小
java -XX:SymbolTableSize=32003 MyApp

# 打印 SymbolTable 统计（调试版本）
java -XX:+PrintSymbolTableSizeHistogram MyApp
```

## 10. 设计要点总结

| 特性 | 实现 |
|------|------|
| 唯一性 | 全局哈希表保证相同内容只有一份 Symbol |
| 快速查找 | 20011 个桶 + 链表，平均 O(1) |
| 快速分配 | Arena 预分配，指针 bump 分配 |
| 内存节省 | Symbol 紧凑布局，变长存储 |
| 引用计数 | 非永久 Symbol 可在类卸载时回收 |
| 共享支持 | CDS 共享表 + 动态表 |

**核心思想**：
1. **空间换时间** - 20011 个桶减少冲突
2. **池化分配** - Arena 避免频繁 malloc
3. **两级查找** - 先共享表后动态表
4. **引用计数** - 永久 Symbol 不计数，临时 Symbol 精确管理

---

## 下一步

SymbolTable 是 JVM 最基础的数据结构之一，后续的类加载、方法解析都依赖它。

接下来可以分析：
- **12. StringTable::create_table()** - 字符串常量池
- **9. ClassLoaderData::init_null_class_loader_data()** - Bootstrap ClassLoader
- **6. 性能计数器初始化** - PerfData 共享内存
