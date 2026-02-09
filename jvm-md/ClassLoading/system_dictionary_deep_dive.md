# SystemDictionary 深度分析：JVM 类加载的"中央调度台"

> 基于 OpenJDK 11，标准环境：`-Xms8g -Xmx8g -XX:+UseG1GC`，Region=4MB
> 核心源码：`classfile/systemDictionary.hpp` (737行), `systemDictionary.cpp` (3081行)
> 辅助源码：`dictionary.hpp/cpp`, `placeholders.hpp/cpp`, `loaderConstraints.hpp/cpp`
> 前置阅读：`classloading_complete_flow.md`（已有 6 步骨架）

---

## 1. SystemDictionary 解决什么问题

JVM 的类加载是按需延迟加载的。当字节码遇到 `new`、`getstatic`、`invokestatic` 等引用未加载类的指令时，需要一个**中央调度台**来协调整个加载过程。

如果没有 SystemDictionary：

| 问题 | 后果 |
|------|------|
| 多线程同时请求加载同一个类 | 内存中出现两个不同的 `InstanceKlass`，类型系统崩溃 |
| A 的父类是 B，B 的父类是 A | 无限递归加载，栈溢出 |
| 两个 ClassLoader 加载同名类 | 如果不区分，类型混淆导致 ClassCastException |
| 类加载器 L1 和 L2 各自加载了同名类 C | 方法签名中的 C 可能指向不同的类，链接错误 |
| 已加载的类需要快速查找 | 每次引用都重新加载，性能灾难 |

SystemDictionary 就是解决这些问题的核心枢纽。

---

## 2. 设计哲学：协调者，而非容器

**关键认知**：SystemDictionary 本身**不存储已加载的类**。

```
                             ┌─────────────────────────────────────────────┐
                             │         SystemDictionary (AllStatic)        │
                             │                                             │
                             │  ┌────────────────────────────────────┐    │
                             │  │  _placeholders (PlaceholderTable)  │    │ ← 正在加载中的类
                             │  │  _loader_constraints (LCT)        │    │ ← 加载器约束
                             │  │  _resolution_errors (RET)         │    │ ← 解析错误缓存
                             │  │  _pd_cache_table (PDCT)           │    │ ← 保护域缓存
                             │  │  _shared_dictionary (Dict)        │    │ ← CDS 共享字典
                             │  │  _well_known_klasses[WKID_LIMIT]  │    │ ← 核心类数组
                             │  │  _invoke_method_table (SPT)       │    │ ← JSR 292 方法表
                             │  └────────────────────────────────────┘    │
                             │                                             │
                             │  ★ 注意：已加载类存储在各个 CLD 的           │
                             │     Dictionary 中，不在这里！               │
                             └────────────────┬────────────────────────────┘
                                              │
                         ┌────────────────────┼──────────────────────┐
                         │                    │                      │
                         ▼                    ▼                      ▼
               ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
               │ ClassLoaderData  │ │ ClassLoaderData  │ │ ClassLoaderData  │
               │ (Bootstrap CL)  │ │ (Platform CL)    │ │ (App CL)         │
               │                  │ │                  │ │                  │
               │ Dictionary* ─────┼─┤ Dictionary* ─────┼─┤ Dictionary* ────┐│
               │ ┌──────────────┐ │ │ ┌──────────────┐ │ │ ┌──────────────┐││
               │ │ Object       │ │ │ │ java.sql.*   │ │ │ │ com.app.*    │││
               │ │ String       │ │ │ │ javax.xml.*  │ │ │ │ MyClass      │││
               │ │ Class        │ │ │ │ ...          │ │ │ │ ...          │││
               │ │ Thread       │ │ │ └──────────────┘ │ │ └──────────────┘││
               │ │ ...          │ │ │                  │ │                  ││
               │ └──────────────┘ │ │                  │ │                  ││
               └──────────────────┘ └──────────────────┘ └──────────────────┘
```

**每个 ClassLoaderData 持有一个 Dictionary**，以 `(class_name)` 为 key，`InstanceKlass*` 为 value。SystemDictionary 不持有任何 Dictionary，而是通过 `class_loader → ClassLoaderData → dictionary()` 的链路来定位。

这样设计的原因：
1. **类卸载高效**：ClassLoader GC 后，其 CLD 连带 Dictionary 整个回收，O(1)
2. **隔离天然保证**：不同 ClassLoader 的同名类存在不同 Dictionary 中
3. **无需全局字典锁**：读取已加载的类时，只需访问对应 CLD 的 Dictionary

---

## 3. 四张核心表：各司其职

SystemDictionary 协调四张表来管理类加载的全生命周期：

```
┌─────────────────────────────────────────────────────────────────────┐
│                    类加载生命周期与四张表                              │
├───────────────┬───────────────────┬─────────────────────────────────┤
│ 阶段          │ 使用的表           │ 作用                             │
├───────────────┼───────────────────┼─────────────────────────────────┤
│ ① 查找已加载  │ Dictionary        │ 命中则直接返回，热路径 O(1)       │
│ ② 正在加载中  │ PlaceholderTable  │ 并发控制 + 循环依赖检测           │
│ ③ 加载完成    │ Dictionary        │ 注册到定义/发起加载器的字典中      │
│ ④ 跨加载器引用│ LoaderConstraintT │ 确保不同加载器对同名类达成一致     │
│ ⑤ 权限校验    │ PD cache(在Entry) │ 缓存已验证的 ProtectionDomain    │
└───────────────┴───────────────────┴─────────────────────────────────┘
```

---

## 4. Dictionary — 每个 ClassLoader 一个的类字典

### 4.1 这张表解决什么问题

**核心问题**：给定一个类名和一个 ClassLoader，快速判断这个类是否已经被加载。

如果不用哈希表，每次类引用（`new`、`checkcast`、`instanceof`）都需要线性搜索所有已加载类——这是不可接受的。

### 4.2 继承体系

```
Hashtable<InstanceKlass*, mtClass>     // 通用哈希表（开链法）
  └── Dictionary                       // 类字典
        字段:
          _loader_data   : ClassLoaderData*   ← 反向指针，指向拥有这个字典的 CLD
          _resizable     : bool               ← 是否允许动态扩容
          _needs_resizing: bool               ← 是否需要扩容

HashtableEntry<InstanceKlass*, mtClass>
  └── DictionaryEntry                  // 字典条目
        字段:
          literal()      : InstanceKlass*     ← 存储的类（继承自 HashtableEntry）
          _pd_set        : ProtectionDomainEntry* volatile  ← 已验证的保护域集合
```

### 4.3 哈希表的内部机制

#### 桶数组 + 开链法

```
Dictionary (table_size = 107, 默认 Bootstrap CL)
┌───────┬───────────────────────────────────────────────┐
│ 下标  │ 链表内容                                       │
├───────┼───────────────────────────────────────────────┤
│   0   │ → [java/lang/Object, pd_set] → NULL           │
│   1   │ → NULL                                        │
│   2   │ → [java/lang/String, pd_set] → [java/lang/Thread, pd_set] → NULL │
│  ...  │ ...                                           │
│  106  │ → [com/sun/xxx, pd_set] → NULL                │
└───────┴───────────────────────────────────────────────┘
```

#### 哈希计算

```cpp
// hashtable.hpp — 继承自 BasicHashtable
unsigned int compute_hash(Symbol* name) {
  return (unsigned int)(name->identity_hash());
  // identity_hash() 返回 Symbol 对象地址的哈希
  // 对于同一个 Symbol*，地址固定，所以哈希稳定
}

int hash_to_index(unsigned int hash) {
  return hash % table_size();  // 取模定位桶
}
```

#### 查找算法：`find()` — 无锁快速路径

```cpp
// dictionary.cpp:305
InstanceKlass* Dictionary::find(unsigned int hash, Symbol* name,
                                Handle protection_domain) {
  NoSafepointVerifier nsv;   // ← 断言：查找过程中不会触发 safepoint

  int index = hash_to_index(hash);
  DictionaryEntry* entry = get_entry(index, hash, name);
  if (entry != NULL && entry->is_valid_protection_domain(protection_domain)) {
    return entry->instance_klass();
  } else {
    return NULL;
  }
}
```

**为什么可以无锁读？** 源码注释给出了三个关键保证：
1. 条目只在 safepoint 删除（此时只有一个线程运行）
2. 读者不会在检查条目期间遇到 safepoint（NoSafepointVerifier 保证）
3. 新条目在对并发读者可见之前必须完全构造好（写入顺序保证）

这意味着 `resolve_instance_class_or_null` 的第一次查找是零开销的——不需要任何锁。

#### `get_entry()` — 链表遍历

```cpp
// dictionary.cpp:288
DictionaryEntry* Dictionary::get_entry(int index, unsigned int hash,
                                       Symbol* class_name) {
  for (DictionaryEntry* entry = bucket(index);
                        entry != NULL;
                        entry = entry->next()) {
    if (entry->hash() == hash && entry->equals(class_name)) {
      return entry;  // 先比 hash（整数比较，快），再比 name（指针比较）
    }
  }
  return NULL;
}
```

**`equals()` 的实现**：

```cpp
// dictionary.hpp:159
bool equals(const Symbol* class_name) const {
  InstanceKlass* klass = (InstanceKlass*)literal();
  return (klass->name() == class_name);  // ← 指针比较！Symbol 全局唯一
}
```

因为 JVM 中所有 Symbol 都存储在全局 SymbolTable 中（已在 `Universe/11-SymbolTable.md` 分析），同名的 Symbol 只有一个实例，所以可以用指针比较代替字符串比较——O(1)。

#### `add_klass()` — 插入新类

```cpp
// dictionary.cpp:281
void Dictionary::add_klass(unsigned int hash, Symbol* class_name,
                           InstanceKlass* obj) {
  assert_locked_or_safepoint(SystemDictionary_lock);  // ← 写必须持锁

  DictionaryEntry* entry = new_entry(hash, obj);
  int index = hash_to_index(hash);
  add_entry(index, entry);       // 头插法：新条目插入链表头部
  check_if_needs_resize();       // 检查是否需要扩容
}
```

#### 动态扩容机制

```cpp
// dictionary.cpp:113
const int _resize_load_trigger = 5;       // 负载因子阈值：entries > 5 * table_size 时扩容
const double _resize_factor    = 2.0;     // 扩容倍数：2x 当前 entries 数
const int _resize_max_size     = 40423;   // 最大桶数
const int _primelist[] = {107, 1009, 2017, 4049, 5051, 10103, 20201, 40423};
```

扩容选择最近的素数大小——素数桶数可以减少哈希碰撞。

**关键限制**：扩容在 safepoint 时执行（`resize_if_needed()` 由 GC 阶段调用），因为需要 rehash 所有条目。

#### ProtectionDomain 缓存

DictionaryEntry 不只存类，还维护了一个 **保护域集合**（`_pd_set`）：

```cpp
class DictionaryEntry : public HashtableEntry<InstanceKlass*, mtClass> {
  ProtectionDomainEntry* volatile _pd_set;  // 链表：已验证通过的 PD 集合
};
```

**作用**：避免每次类引用都回调 `ClassLoader.checkPackageAccess()`（Java 层调用开销大）。第一次验证通过后，将 `(ProtectionDomain)` 加入 `_pd_set`，后续查找命中即可跳过验证。

**`is_valid_protection_domain()` 流程**：

```
1. protection_domain == NULL → 直接返回 true（无保护域）
2. protection_domain == klass->protection_domain() → 匹配定义域，返回 true
3. 遍历 _pd_set 链表查找 → 命中返回 true
4. 未命中 → 返回 false → 调用者需要调用 validate_protection_domain()（回调 Java）
```

---

## 5. PlaceholderTable — 加载中的占位符表

### 5.1 这张表解决什么问题

**核心问题**：多个线程可能同时请求加载同一个类，需要协调谁来做实际加载，其他人等待。同时，加载过程中需要检测类循环依赖（ClassCircularityError）。

### 5.2 数据结构

```
PlaceholderTable (table_size = 1009)
  继承: Hashtable<Symbol*, mtClass>
  Key: (class_name, ClassLoaderData)   ← 类名 + 加载器 联合键

PlaceholderEntry:
  ┌───────────────────────────────────────────────────────────────┐
  │  klassname()        : Symbol*          ← 类名（继承的 literal）│
  │  _loader_data       : ClassLoaderData* ← 发起加载器            │
  │  _havesupername     : bool             ← 是否正在加载超类      │
  │  _supername         : Symbol*          ← 正在加载的超类名      │
  │  _definer           : Thread*          ← define token 持有者  │
  │  _instanceKlass     : InstanceKlass*   ← define 成功后的结果   │
  │  _superThreadQ      : SeenThread*      ← LOAD_SUPER 线程队列  │
  │  _loadInstanceThreadQ: SeenThread*     ← LOAD_INSTANCE 队列   │
  │  _defineThreadQ     : SeenThread*      ← DEFINE_CLASS 队列    │
  └───────────────────────────────────────────────────────────────┘
```

### 5.3 三种 Action 的含义

```cpp
enum classloadAction {
  LOAD_INSTANCE = 1,  // 正在调用 load_instance_class
  LOAD_SUPER    = 2,  // 正在加载超类（用于循环依赖检测）
  DEFINE_CLASS  = 3   // 正在 define（并发 define 控制）
};
```

| Action | 对应队列 | 触发场景 | 作用 |
|--------|---------|---------|------|
| `LOAD_INSTANCE` | `_loadInstanceThreadQ` | `resolve_instance_class_or_null` 开始加载 | 标记"有线程在加载这个类" |
| `LOAD_SUPER` | `_superThreadQ` | `resolve_super_or_fail` 开始加载超类 | 循环依赖检测 |
| `DEFINE_CLASS` | `_defineThreadQ` | `find_or_define_instance_class` 开始 define | 并发 define 控制 |

### 5.4 SeenThread — 双向链表记录参与的线程

```cpp
class SeenThread : public CHeapObj<mtInternal> {
  Thread*     _thread;    // 线程指针
  SeenThread* _stnext;    // 下一个
  SeenThread* _stprev;    // 上一个（双向链表支持 O(1) 删除）
};
```

每个 PlaceholderEntry 有**三个独立的 SeenThread 队列**（对应三种 action），一个线程可以同时出现在多个队列中。

### 5.5 循环依赖检测算法

```
场景：Base 的超类是 Super，Super 的超类是 Base

线程 T1: 加载 Base
  → placeholder(T1, Base, LOAD_SUPER, super=Super)    // 标记：T1 正在为 Base 加载超类 Super
  → 递归加载 Super
    → placeholder(T1, Super, LOAD_SUPER, super=Base)  // 标记：T1 正在为 Super 加载超类 Base
    → 递归加载 Base
      → 在 placeholder 中发现 T1 已经在为 Base 做 LOAD_SUPER
      → check_seen_thread(T1, LOAD_SUPER) == true
      → throw ClassCircularityError!
```

代码路径（`resolve_super_or_fail`，`systemDictionary.cpp:389`）：

```cpp
MutexLocker mu(SystemDictionary_lock, THREAD);
PlaceholderEntry* probe = placeholders()->get_entry(p_index, p_hash, child_name, loader_data);
if (probe && probe->check_seen_thread(THREAD, PlaceholderTable::LOAD_SUPER)) {
    throw_circularity_error = true;  // ← 当前线程已在加载这个类的超类，循环了！
}
if (!throw_circularity_error) {
    // 注册占位符
    placeholders()->find_and_add(p_index, p_hash, child_name, loader_data,
                                 PlaceholderTable::LOAD_SUPER, class_name, THREAD);
}
```

### 5.6 `find_and_add` — 原子查找+注册

```cpp
// placeholders.cpp:115
PlaceholderEntry* PlaceholderTable::find_and_add(int index, unsigned int hash,
                                                 Symbol* name,
                                                 ClassLoaderData* loader_data,
                                                 classloadAction action,
                                                 Symbol* supername,
                                                 Thread* thread) {
  PlaceholderEntry* probe = get_entry(index, hash, name, loader_data);
  if (probe == NULL) {
    // 不存在则新建
    add_entry(index, hash, name, loader_data, (action == LOAD_SUPER), supername);
    probe = get_entry(index, hash, name, loader_data);
  } else {
    if (action == LOAD_SUPER) {
      probe->set_havesupername(true);
      probe->set_supername(supername);
    }
  }
  if (probe) probe->add_seen_thread(thread, action);  // 将当前线程加入对应队列
  return probe;
}
```

### 5.7 `find_and_remove` — 清理后检查是否可以删除整个条目

```cpp
// placeholders.cpp:141
void PlaceholderTable::find_and_remove(int index, unsigned int hash,
                                       Symbol* name, ClassLoaderData* loader_data,
                                       classloadAction action, Thread* thread) {
    PlaceholderEntry *probe = get_entry(index, hash, name, loader_data);
    if (probe != NULL) {
       probe->remove_seen_thread(thread, action);
       // 只有当所有三个队列都空，且没有 definer 时，才删除整个条目
       if ((probe->superThreadQ()       == NULL) &&
           (probe->loadInstanceThreadQ() == NULL) &&
           (probe->defineThreadQ()       == NULL) &&
           (probe->definer()             == NULL)) {
         remove_entry(index, hash, name, loader_data);
       }
    }
}
```

**设计要点**：PlaceholderEntry 的生命周期与**所有使用它的线程**绑定。只要还有一个线程在使用（任意一个队列非空），条目就不会被删除。

---

## 6. LoaderConstraintTable — 加载器约束表

### 6.1 这张表解决什么问题

**核心问题**：当方法签名中包含类型引用时，调用者（caller）和被调用者（callee）可能由不同的 ClassLoader 加载。必须确保它们对签名中每个类名的理解是一致的。

**经典场景**：

```java
// 由 AppClassLoader 加载
class Caller {
    void test(com.lib.Foo foo) {    // Foo 通过 AppCL 解析
        foo.process();              // 调用 Foo.process()，Foo 由谁定义？
    }
}

// 由 ExtClassLoader 加载
class com.lib.Foo {
    void process() { ... }
}
```

如果 AppCL 和 ExtCL 各自定义了不同的 `com.lib.Foo`，那方法调用时参数类型不匹配——需要在链接阶段就检测出来。

### 6.2 数据结构

```
LoaderConstraintTable (table_size = 107)
  继承: Hashtable<InstanceKlass*, mtClass>

LoaderConstraintEntry:
  ┌───────────────────────────────────────────────────┐
  │  _name         : Symbol*          ← 约束的类名    │
  │  literal()     : InstanceKlass*   ← 约束的类      │
  │  _num_loaders  : int              ← 参与的加载器数 │
  │  _max_loaders  : int              ← 数组容量      │
  │  _loaders      : ClassLoaderData** ← 加载器数组   │
  └───────────────────────────────────────────────────┘
```

一个约束条目表示：所有 `_loaders[]` 中的加载器对 `_name` 这个类名的解析，必须得到同一个 `InstanceKlass*`（即 `literal()` 所指向的类）。

### 6.3 约束检查触发点

约束由 `SystemDictionary::check_signature_loaders()` 在以下场景触发：

| 触发者 | 场景 |
|--------|------|
| `LinkResolver::resolve_method` | 方法解析时，确保 caller 和 callee 的签名类型一致 |
| `LinkResolver::resolve_field` | 字段解析时，确保字段类型一致 |
| `klassVtable::initialize_vtable` | vtable 初始化时，overriding 方法签名一致 |
| `klassItable::initialize_itable` | itable 初始化时，interface 方法签名一致 |

### 6.4 `add_entry()` — 添加/合并约束

```cpp
// loaderConstraints.cpp:155
bool LoaderConstraintTable::add_entry(Symbol* class_name,
                                      InstanceKlass* klass1, Handle class_loader1,
                                      InstanceKlass* klass2, Handle class_loader2) {
  // 情况 1: 两边都已加载，且是同一个类 → 不需要约束
  if (klass1 != NULL && klass2 != NULL) {
    if (klass1 == klass2) return true;
    else return false;  // ← 违反约束！不同的类
  }

  // 查找 loader1 和 loader2 是否已有约束
  LoaderConstraintEntry** pp1 = find_loader_constraint(class_name, class_loader1);
  LoaderConstraintEntry** pp2 = find_loader_constraint(class_name, class_loader2);

  if (*pp1 == NULL && *pp2 == NULL) {
    // 两边都没有约束 → 创建新约束，包含两个 loader
    p = new_entry(hash, class_name, klass, 2, 2);
    p->set_loaders(NEW_C_HEAP_ARRAY(ClassLoaderData*, 2, mtClass));
    p->set_loader(0, class_loader1());
    p->set_loader(1, class_loader2());
  } else if (*pp1 == *pp2) {
    // 同一个约束 → 已经满足
  } else if (*pp1 == NULL) {
    // loader1 无约束，loader2 有 → 把 loader1 加入 loader2 的约束
    extend_loader_constraint(*pp2, class_loader1, klass);
  } else if (*pp2 == NULL) {
    // 反之
    extend_loader_constraint(*pp1, class_loader2, klass);
  } else {
    // 两边各有约束 → 合并两个约束
    merge_loader_constraints(pp1, pp2, klass);
  }
  return true;
}
```

### 6.5 `check_or_update()` — 定义类时的约束校验

当一个类被定义后（`define_instance_class`），需要检查是否满足已有约束：

```cpp
// loaderConstraints.cpp:246
bool LoaderConstraintTable::check_or_update(InstanceKlass* k,
                                            Handle loader, Symbol* name) {
  LoaderConstraintEntry* p = *(find_loader_constraint(name, loader));
  if (p && p->klass() != NULL && p->klass() != k) {
    return false;  // ← 约束中已有另一个类！违反约束
  } else {
    if (p && p->klass() == NULL) {
      p->set_klass(k);  // ← 约束中还没有类，设置它
    }
    return true;
  }
}
```

### 6.6 面试要点：为什么两个 ClassLoader 加载的同名类不同？

**答案就在这里**：

1. Dictionary 以 `(class_name)` 为 key，但**每个 CLD 有独立的 Dictionary**
2. CLD1.dictionary 中的 `com.Foo` ≠ CLD2.dictionary 中的 `com.Foo`
3. 当两个类需要互相引用时，LoaderConstraintTable 强制它们达成一致
4. 如果达不成一致 → `LinkageError: loader constraint violation`

---

## 7. SystemDictionary::initialize() — 启动初始化

`systemDictionary.cpp:1865`，在 `init_globals()` → `systemDictionary_init()` 中被调用。

```cpp
void SystemDictionary::initialize(TRAPS) {
  // 1. 创建四张辅助表
  _placeholders        = new PlaceholderTable(_placeholder_table_size);  // 1009 桶
  _loader_constraints  = new LoaderConstraintTable(_loader_constraint_size);  // 107 桶
  _resolution_errors   = new ResolutionErrorTable(_resolution_error_size);  // 107 桶
  _invoke_method_table = new SymbolPropertyTable(_invoke_method_size);  // 139 桶
  _pd_cache_table      = new ProtectionDomainCacheTable(defaultProtectionDomainCacheSize); // 1009 桶

  // 2. 创建系统类加载器锁对象（一个空的 int[]）
  _system_loader_lock_obj = oopFactory::new_intArray(0, CHECK);

  // 3. 加载所有 well-known 类
  resolve_well_known_classes(CHECK);
}
```

**注意**：这里只创建了 `PlaceholderTable` 等辅助表。Dictionary 不在这里创建——它是在 `ClassLoaderData` 构造时创建的（Bootstrap CLD 在 `ClassLoaderData::init_null_class_loader_data()` 中创建，用户 CLD 在 `ClassLoaderDataGraph::find_or_create()` 中创建）。

### 7.1 resolve_well_known_classes — 预加载 ~80 个核心类

`systemDictionary.cpp:1891`，按照 `WK_KLASSES_DO` 宏定义的顺序加载核心类。

加载顺序（分阶段，顺序不能变）：

```
阶段 1: Object → String → Class                    ← 最先加载，后续都依赖
  ↓ 计算 String/Class 的字段偏移
  ↓ Universe::initialize_basic_type_mirrors()
  ↓ Universe::fixup_mirrors()                      ← 为早期类创建 java.lang.Class mirror

阶段 2: Cloneable → ... → Reference                ← 基础类型

阶段 3: SoftReference → FinalReference → PhantomReference  ← 设置 reference_type
  ↓ 设置 REF_SOFT / REF_WEAK / REF_FINAL / REF_PHANTOM

阶段 4: MethodHandle → ... → VolatileCallSite      ← JSR 292 动态调用

阶段 5: 剩余所有 well-known 类（Boolean, Integer, Iterator 等）

最后: 设置 _box_klasses[] 数组，检查 checkPackageAccess 方法
```

**为什么顺序很重要？** 例如：
- Object 必须最先加载，因为所有类的超类都是 Object
- String 必须在 Class 之前，因为 Class 的字段包含 String
- 必须先加载完 Object/String/Class 才能调用 `compute_offsets()`——否则字段偏移未知

### 7.2 resolve_wk_klass — 加载单个 well-known 类

```cpp
// systemDictionary.cpp:1880
bool SystemDictionary::resolve_wk_klass(WKID id, int init_opt, TRAPS) {
  int  info = wk_init_info[id - FIRST_WKID];
  int  sid  = (info >> CEIL_LG_OPTION_LIMIT);   // 提取 vmSymbol ID
  Symbol* symbol = vmSymbols::symbol_at((vmSymbols::SID)sid);  // 获取类名 Symbol

  InstanceKlass** klassp = &_well_known_klasses[id];

  if ((*klassp) == NULL) {
    Klass* k;
    if (must_load) {
      k = resolve_or_fail(symbol, true, CHECK_0);   // Pre 标志：必须成功
    } else {
      k = resolve_or_null(symbol, CHECK_0);          // Opt 标志：可选
    }
    (*klassp) = (k == NULL) ? NULL : InstanceKlass::cast(k);
  }
  return ((*klassp) != NULL);
}
```

**wk_init_info 编码**：每个 well-known 类有一个 `short` 值，高位编码 vmSymbol ID（类名），低 2 位编码 `InitOption`（Pre/Opt）。这是一个紧凑的查表编码，比函数指针数组节省内存。

---

## 8. resolve_instance_class_or_null — 类加载的心脏（250 行）

`systemDictionary.cpp:631-880`。这是整个类加载系统最核心的函数，`classloading_complete_flow.md` 中给出了 6 步骨架，这里逐行深入。

### 8.1 完整流程图

```
resolve_instance_class_or_null(name, class_loader, protection_domain)
│
├── 阶段 0: 准备工作
│   ├── non_reflection_class_loader()     跳过反射代理加载器
│   ├── register_loader()                 获取/创建 ClassLoaderData
│   ├── dictionary = loader_data->dictionary()
│   └── d_hash = dictionary->compute_hash(name)
│
├── 阶段 1: 无锁快速查找 ────────────── 热路径
│   └── probe = dictionary->find(d_hash, name, pd)
│       └── if (probe != NULL) return probe    ← O(1) 返回
│
├── 阶段 2: 计算锁策略
│   ├── DoObjectLock = !is_parallelCapable(class_loader)
│   ├── lockObject = compute_loader_lock_object()
│   └── ObjectLocker ol(lockObject, DoObjectLock)
│
├── 阶段 3: 加锁 + 二次检查
│   ├── MutexLocker mu(SystemDictionary_lock)
│   ├── check = find_class(d_hash, name, dictionary)
│   │   └── if (check != NULL) { k = check; class_has_been_loaded = true; }
│   └── else: 检查 placeholder 是否有超类加载进行中
│       └── if (placeholder && super_load_in_progress) → handle_parallel_super_load
│
├── 阶段 4: 并发加载检测 (4 种 case)
│   ├── case 1: 传统 CL（持有对象锁）—— 无需额外处理
│   ├── case 2: 传统但释放了锁（deadlock workaround）—— double_lock_wait
│   ├── case 3: Bootstrap CL —— 通过 placeholder LOAD_INSTANCE 协调
│   └── case 4: parallelCapable CL —— 允许并行 LOAD_INSTANCE
│   ↓
│   注册 placeholder: find_and_add(LOAD_INSTANCE)
│   最终检查 find_class → 防止 TOCTOU
│
├── 阶段 5: 实际加载
│   └── k = load_instance_class(name, class_loader)
│       ├── [Bootstrap CL] ClassLoader::load_class()
│       │   ├── CDS 共享归档查找
│       │   ├── jimage (modules)
│       │   └── -Xbootclasspath/a
│       └── [用户 CL] JavaCalls::call_virtual(loadClass)
│
├── 阶段 6: 加载后处理
│   ├── if (k->class_loader() != class_loader) → 委派加载
│   │   ├── check_constraints(d_hash, k, class_loader, false)
│   │   ├── loader_data->record_dependency(k)
│   │   └── update_dictionary(d_hash, p_index, p_hash, k, class_loader)
│   └── JVMTI post_class_load 通知
│
├── 阶段 7: 清理 placeholder
│   ├── find_and_remove(LOAD_INSTANCE)
│   └── SystemDictionary_lock->notify_all()
│
└── 阶段 8: ProtectionDomain 验证
    ├── if (pd == NULL) return k
    ├── if (dictionary->is_valid_protection_domain(d_hash, name, pd)) return k
    └── validate_protection_domain(k, class_loader, pd)  → Java 回调
```

### 8.2 阶段 1 深入：无锁快速查找

```cpp
// systemDictionary.cpp:647-651
{
  Klass* probe = dictionary->find(d_hash, name, protection_domain);
  if (probe != NULL) return probe;  // 热路径：99.9% 的查找在这里返回
}
```

**为什么包在一个匿名 block `{}` 里？** 这是 C++ 的作用域技巧——`probe` 在 block 结束后自动销毁，避免后续代码误用（`probe` 是未持锁获取的，不能在后续锁定区域使用）。

**性能分析**：
- 哈希计算：O(1)（Symbol 的 identity_hash 是预计算的）
- 桶定位：O(1)
- 链表遍历：通常 1~3 个节点（负载因子 < 5）
- 总计：**O(1)**，且不需要任何锁

### 8.3 阶段 2 深入：锁策略选择

```cpp
// systemDictionary.cpp:662-670
bool DoObjectLock = true;
if (is_parallelCapable(class_loader)) {
  DoObjectLock = false;
}
Handle lockObject = compute_loader_lock_object(class_loader, THREAD);
ObjectLocker ol(lockObject, THREAD, DoObjectLock);
```

**锁策略矩阵**：

| 加载器类型 | is_parallelCapable | DoObjectLock | 锁对象 |
|-----------|-------------------|-------------|--------|
| Bootstrap (null) | true | false | _system_loader_lock_obj（不加锁） |
| AppClassLoader | true（JDK 7+） | false | class_loader 对象（不加锁） |
| 自定义 parallel CL | true | false | class_loader 对象（不加锁） |
| 传统自定义 CL | false | true | class_loader 对象（**加锁**） |

**为什么 parallelCapable 不需要对象锁？** 因为它们通过 PlaceholderTable 的 `DEFINE_CLASS` token 来序列化 define 操作，不需要粗粒度的对象锁。

### 8.4 阶段 4 深入：四种并发场景

这是整个函数最复杂的部分（`systemDictionary.cpp:728-820`），处理四种 case：

**Case 1：传统 ClassLoader（持有对象锁）**

```
T1: 获取 CL 对象锁 → placeholder.find_and_add(LOAD_INSTANCE) → load_instance_class → 成功
T2: 获取 CL 对象锁（阻塞等待 T1 释放锁）
    → 锁获取成功 → find_class → 已加载 → 直接返回
```

**Case 2：传统 ClassLoader 但释放了对象锁（死锁 workaround）**

某些自定义 ClassLoader 在 `loadClass()` 中错误地释放了对象锁（为了避免死锁），导致多个线程可以并行进入。通过 placeholder 的 LOAD_INSTANCE 队列协调：

```cpp
// systemDictionary.cpp:756-784
if (oldprobe->check_seen_thread(THREAD, PlaceholderTable::LOAD_INSTANCE)) {
  throw_circularity_error = true;  // 同一线程再次加载同一类 → 循环
} else {
  while (!class_has_been_loaded && oldprobe && oldprobe->instance_load_in_progress()) {
    if (class_loader.is_null()) {
      SystemDictionary_lock->wait();       // case 3: Bootstrap CL
    } else {
      double_lock_wait(lockObject, THREAD); // case 2: 传统 CL（复杂的双锁等待）
    }
    // 被唤醒后再次检查
    check = find_class(d_hash, name, dictionary);
    if (check != NULL) { k = check; class_has_been_loaded = true; }
  }
}
```

**`double_lock_wait()` 的复杂舞蹈**（`systemDictionary.cpp:524`）：

```
问题：需要先释放 CL 对象锁再等待 SystemDictionary_lock，避免死锁
步骤：
1. notify CL 对象锁上的等待者
2. 完全退出 CL 对象锁（记录递归次数）
3. 在 SystemDictionary_lock 上 wait
4. 被唤醒后：先释放 SystemDictionary_lock
5. 以原来的递归次数重新进入 CL 对象锁
6. 重新获取 SystemDictionary_lock
```

**Case 4：parallelCapable ClassLoader**

```cpp
// systemDictionary.cpp:797-813
// 直接注册 LOAD_INSTANCE，允许多线程并行加载不同类
PlaceholderEntry* newprobe = placeholders()->find_and_add(p_index, p_hash, name,
    loader_data, PlaceholderTable::LOAD_INSTANCE, NULL, THREAD);

// 最终检查：防止另一线程刚好完成了加载
InstanceKlass* check = find_class(d_hash, name, dictionary);
if (check != NULL) {
  k = check;
  class_has_been_loaded = true;
}
```

### 8.5 阶段 5 深入：加载后的委派处理

加载成功后，检查**定义加载器**是否等于**发起加载器**：

```cpp
// systemDictionary.cpp:831-858
if (!HAS_PENDING_EXCEPTION && k != NULL &&
    k->class_loader() != class_loader()) {
  // 定义加载器 != 发起加载器 → 这个类是通过委派找到的
  // 例如：AppCL 请求加载 java.lang.Object，但实际由 Bootstrap CL 定义

  // 1. 检查加载器约束
  check_constraints(d_hash, k, class_loader, false, THREAD);

  // 2. 记录依赖关系（防止定义加载器被 GC 而发起加载器还活着）
  loader_data->record_dependency(k);

  // 3. 注册到发起加载器的字典中（作为 initiating loader）
  MutexLocker mu(Compile_lock, THREAD);  // ← 防止编译器读到不一致的类层次
  update_dictionary(d_hash, p_index, p_hash, k, class_loader, THREAD);
}
```

**关键区分**：
- **定义加载器**（defining loader）：实际执行 `defineClass` 的加载器
- **发起加载器**（initiating loader）：最初请求加载的加载器

同一个类可以出现在多个加载器的 Dictionary 中——每次通过委派找到时，都会注册到发起加载器的字典中。

---

## 9. define_instance_class — 注册类到字典

`systemDictionary.cpp:1555-1624`，类加载的最终注册步骤。

### 9.1 完整流程

```
define_instance_class(InstanceKlass* k)
│
├── check_constraints(d_hash, k, class_loader, true)   ← defining=true
│   检查是否违反加载器约束
│   如果 Dictionary 中已有同名类 → LinkageError: duplicate class definition
│
├── ClassLoader.addClass(mirror)                       ← Java 回调
│   将 Class 对象注册到 Java 层的 ClassLoader.classes Vector
│   (JVMTI FollowReferences 需要通过这个 Vector 找到所有类)
│
├── MutexLocker mu_r(Compile_lock)                     ← 防止编译器竞争
│   ├── add_to_hierarchy(k)                            ← 加入类层次
│   │   ├── k->append_to_sibling_list()               连接兄弟链表
│   │   ├── k->process_interfaces()                   处理接口
│   │   ├── k->set_init_state(loaded)                 设置状态为 loaded
│   │   └── CodeCache::flush_dependents_on(k)         刷新依赖的编译代码
│   │
│   └── update_dictionary(d_hash, p_index, p_hash, k, class_loader)
│       └── dictionary->add_klass(d_hash, name, k)    ← 写入哈希表
│
├── k->eager_initialize()                              ← 尝试立即初始化
│   如果无静态初始化器且超类已初始化 → 跳过 <clinit>
│
└── JVMTI post_class_load                              ← 通知 agent
```

### 9.2 check_constraints 的 defining vs initiating

```cpp
// systemDictionary.cpp:2191
void SystemDictionary::check_constraints(unsigned int d_hash,
                                         InstanceKlass* k,
                                         Handle class_loader,
                                         bool defining, TRAPS) {
  MutexLocker mu(SystemDictionary_lock, THREAD);

  InstanceKlass* check = find_class(d_hash, name, loader_data->dictionary());
  if (check != NULL) {
    if ((defining == true) || (k != check)) {
      // defining=true 时，字典中已有同名类 → duplicate definition
      // defining=false 时，如果不是同一个对象 → 也是错误
      throwException = true;
      ss.print("loader %s attempted duplicate %s definition for %s",
               loader_data->loader_name_and_id(),
               k->external_kind(), k->external_name());
    } else {
      return;  // 同一个对象，OK（并行线程都找到了同一个类）
    }
  }

  // 检查加载器约束
  if (constraints()->check_or_update(k, class_loader, name) == false) {
    throwException = true;
    ss.print("loader constraint violation: loader %s wants to load %s %s.",
             loader_data->loader_name_and_id(),
             k->external_kind(), k->external_name());
  }
}
```

### 9.3 update_dictionary — 最终写入

```cpp
// systemDictionary.cpp:2239
void SystemDictionary::update_dictionary(unsigned int d_hash,
                                         int p_index, unsigned int p_hash,
                                         InstanceKlass* k,
                                         Handle class_loader, TRAPS) {
  MutexLocker mu1(SystemDictionary_lock, THREAD);

  // 偏向锁设置：如果启用 BiasedLocking 且是定义加载器
  if (UseBiasedLocking && BiasedLocking::enabled()) {
    if (k->class_loader() == class_loader()) {
      k->set_prototype_header(markOopDesc::biased_locking_prototype());
    }
  }

  // 写入字典（只有不存在时才写入）
  Dictionary* dictionary = loader_data->dictionary();
  InstanceKlass* sd_check = find_class(d_hash, name, dictionary);
  if (sd_check == NULL) {
    dictionary->add_klass(d_hash, name, k);  // ← 最终的写入点
  }

  SystemDictionary_lock->notify_all();  // ← 唤醒所有等待的线程
}
```

---

## 10. find_or_define_instance_class — 并行 define 控制

`systemDictionary.cpp:1630-1730`。所有 parallelCapable 加载器和 Bootstrap 加载器使用这个函数，而非直接调用 `define_instance_class`。

### 10.1 解决的问题

parallelCapable 加载器允许多个线程并行加载**不同**的类，但对**同一个**类，只能有一个线程成功 define。

### 10.2 DEFINE_CLASS token 机制

```
┌──────────────────────────────────────────────────────────────────┐
│  find_or_define_instance_class 流程                                │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  T1: find_class → NULL                                           │
│      → find_and_add(DEFINE_CLASS)                                │
│      → definer == NULL → set_definer(T1) → T1 获得 define token  │
│      → 调用 define_instance_class(k)                             │
│      → 成功: set_instance_klass(k), set_definer(NULL)            │
│      → find_and_remove(DEFINE_CLASS), notify_all                 │
│      → return k                                                  │
│                                                                  │
│  T2: find_class → NULL                                           │
│      → find_and_add(DEFINE_CLASS)                                │
│      → definer == T1（非NULL）→ wait()                           │
│      → 被唤醒后: definer == NULL, instance_klass == k            │
│      → return probe->instance_klass()  ← 复用 T1 的结果         │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### 10.3 关键代码

```cpp
// systemDictionary.cpp:1654-1699
InstanceKlass* SystemDictionary::find_or_define_instance_class(
    Symbol* class_name, Handle class_loader, InstanceKlass* k, TRAPS) {

  // 1. 检查是否已有定义
  {
    MutexLocker mu(SystemDictionary_lock, THREAD);
    if (is_parallelDefine(class_loader)) {
      InstanceKlass* check = find_class(d_hash, name_h, dictionary);
      if (check != NULL) return check;  // 已有定义，直接返回
    }

    // 2. 获取 DEFINE_CLASS token
    probe = placeholders()->find_and_add(p_index, p_hash, name_h, loader_data,
                                         PlaceholderTable::DEFINE_CLASS, NULL, THREAD);

    // 3. 等待前一个 definer 完成
    while (probe->definer() != NULL) {
      SystemDictionary_lock->wait();
    }

    // 4. 检查是否可以复用前一个 definer 的结果
    if (is_parallelDefine(class_loader) && (probe->instance_klass() != NULL)) {
      // 前一个 definer 成功了，复用结果
      placeholders()->find_and_remove(p_index, p_hash, name_h, loader_data,
                                       PlaceholderTable::DEFINE_CLASS, THREAD);
      return probe->instance_klass();
    } else {
      // 当前线程成为 definer
      probe->set_definer(THREAD);
    }
  }

  // 5. 实际定义（不持有 SystemDictionary_lock）
  define_instance_class(k, THREAD);

  // 6. 通知等待者
  {
    MutexLocker mu(SystemDictionary_lock, THREAD);
    if (!HAS_PENDING_EXCEPTION) {
      probe->set_instance_klass(k);   // 成功：保存结果供其他线程复用
    }
    probe->set_definer(NULL);
    placeholders()->find_and_remove(..., PlaceholderTable::DEFINE_CLASS, THREAD);
    SystemDictionary_lock->notify_all();
  }

  return k;
}
```

**设计精妙之处**：
- `definer` 字段确保只有一个线程做实际 define
- 等待线程通过 `instance_klass()` 字段获取结果，避免重复工作
- 如果 definer 失败，下一个等待者成为新的 definer（不会所有人都失败）

---

## 11. 并发控制全景总结

### 11.1 锁层次（从粗到细）

```
┌──────────────────────────────────────────────────────────────────┐
│                        锁层次关系                                 │
├──────────────┬────────────────┬──────────────────────────────────┤
│ 锁           │ 持有者          │ 保护的资源                       │
├──────────────┼────────────────┼──────────────────────────────────┤
│ CL 对象锁    │ 传统(非parallel)│ 防止同一 CL 重复 define          │
│              │ 加载器          │ （parallelCapable 不使用此锁）   │
├──────────────┼────────────────┼──────────────────────────────────┤
│ SystemDict   │ 全局            │ Dictionary/PlaceholderTable/     │
│ _lock        │                │ LoaderConstraintTable 更新       │
├──────────────┼────────────────┼──────────────────────────────────┤
│ Compile_lock │ 全局            │ 类层次变更时防止编译器读到        │
│              │                │ 不一致状态                        │
└──────────────┴────────────────┴──────────────────────────────────┘

排序约束: CL对象锁 → SystemDictionary_lock → Compile_lock
         （必须按此顺序获取，否则死锁）
```

### 11.2 四种加载器的并发行为对比

```
┌───────────────────┬──────────────┬──────────────┬──────────────────┐
│ 加载器类型         │ 对象锁        │ Placeholder  │ 并行能力          │
├───────────────────┼──────────────┼──────────────┼──────────────────┤
│ Bootstrap (null)  │ 不加锁       │ LOAD_INSTANCE│ 同类串行,异类并行  │
│                   │              │ + DEFINE_CLASS│                  │
├───────────────────┼──────────────┼──────────────┼──────────────────┤
│ AppClassLoader    │ 不加锁       │ LOAD_INSTANCE│ 同类串行,异类并行  │
│ (parallelCapable) │              │ + DEFINE_CLASS│                  │
├───────────────────┼──────────────┼──────────────┼──────────────────┤
│ 传统自定义 CL     │ 加锁         │ LOAD_INSTANCE│ 所有加载串行      │
│                   │              │              │ （对象锁粗粒度）   │
├───────────────────┼──────────────┼──────────────┼──────────────────┤
│ 传统但破坏锁 CL   │ 加锁(被释放) │ LOAD_INSTANCE│ 意外并行,         │
│                   │              │ + wait       │ 通过 double_lock  │
│                   │              │              │ _wait 修复        │
└───────────────────┴──────────────┴──────────────┴──────────────────┘
```

---

## 12. GDB 验证指南

### 12.1 查看 Bootstrap CLD 的 Dictionary

```gdb
set pagination off
set print pretty on

# 在 universe_post_init 之后断点
b universe2_init
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# 获取 Bootstrap ClassLoaderData
set $boot_cld = ClassLoaderData::_the_null_class_loader_data
printf "Bootstrap CLD: %p\n", $boot_cld

# 获取 Dictionary
set $dict = $boot_cld->_dictionary
printf "Dictionary addr: %p\n", $dict
printf "table_size: %d\n", $dict->_table_size
printf "number_of_entries: %d\n", $dict->_number_of_entries
printf "resizable: %d\n", $dict->_resizable

# 遍历 Dictionary 的前几个桶
set $i = 0
while $i < 10
  set $entry = $dict->_buckets[$i]._entry
  if $entry != 0
    printf "bucket[%d]: ", $i
    set $e = (DictionaryEntry*)$entry
    while $e != 0
      printf "%s -> ", $e->_literal->_name->_body
      set $e = (DictionaryEntry*)$e->_next
    end
    printf "NULL\n"
  end
  set $i = $i + 1
end
```

### 12.2 查看 PlaceholderTable 状态

```gdb
# 在类加载入口断点
b SystemDictionary::resolve_instance_class_or_null
commands
  printf "Loading: %s\n", name->_body
  printf "PlaceholderTable entries: %d\n", SystemDictionary::_placeholders->_number_of_entries
  continue
end
```

### 12.3 查看 Well-Known Klasses

```gdb
# 在 resolve_well_known_classes 之后
b SystemDictionary::resolve_well_known_classes
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -version

# 跳过断点直到完成
finish

# 查看前 10 个 well-known klasses
set $i = 1
while $i < 11
  set $k = SystemDictionary::_well_known_klasses[$i]
  if $k != 0
    printf "WK[%d]: %s\n", $i, $k->_name->_body
  end
  set $i = $i + 1
end
```

### 12.4 验证 LoaderConstraintTable

```gdb
set $lct = SystemDictionary::_loader_constraints
printf "LoaderConstraintTable: table_size=%d, entries=%d\n", $lct->_table_size, $lct->_number_of_entries
```

### 12.5 追踪类加载全过程

```gdb
# 跟踪一个特定类的加载过程
b SystemDictionary::resolve_instance_class_or_null if name->_body[0]=='c' && name->_body[1]=='o' && name->_body[2]=='m'
commands
  printf "=== resolve_instance_class_or_null: %s ===\n", name->_body
  printf "class_loader: %p\n", class_loader._obj
end

b SystemDictionary::load_instance_class
commands
  printf "=== load_instance_class: %s ===\n", class_name->_body
  printf "class_loader is null: %d\n", class_loader._obj == 0
end

b SystemDictionary::define_instance_class
commands
  printf "=== define_instance_class: %s ===\n", k->_name->_body
  printf "class_loader_data: %p\n", k->_class_loader_data
end

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main
```

### 12.6 JVM 参数

| 参数 | 用途 |
|------|------|
| `-Xlog:class+load=info` | 类加载日志 |
| `-Xlog:class+load=debug` | 包含加载来源 |
| `-Xlog:class+loader+constraints=info` | 加载器约束日志 |
| `-Xlog:protectiondomain=debug` | 保护域验证日志 |

---

## 13. 面试高频问题源码解答

### Q1: 双亲委派是怎么实现的？

**答**：双亲委派不在 C++ 层实现，而是在 Java 层的 `ClassLoader.loadClass()` 中：

```java
protected Class<?> loadClass(String name, boolean resolve) {
    Class<?> c = findLoadedClass(name);     // → JVM_FindLoadedClass → Dictionary::find
    if (c == null) {
        try {
            if (parent != null) {
                c = parent.loadClass(name, false);  // ← 递归委派给父
            } else {
                c = findBootstrapClassOrNull(name);  // ← 委派给 Bootstrap
            }
        } catch (ClassNotFoundException e) { }
        if (c == null) {
            c = findClass(name);             // ← 自己加载
        }
    }
    return c;
}
```

C++ 层只负责调用 `JavaCalls::call_virtual(loadClass)`（`load_instance_class` 的用户 CL 路径），委派逻辑完全在 Java 层。

### Q2: 类是怎么缓存的？

**答**：通过每个 `ClassLoaderData` 持有的 `Dictionary`（开链哈希表）缓存。查找路径：
1. `class_loader → ClassLoaderData → dictionary()`
2. `dictionary->find(hash, name, protection_domain)`
3. 无锁快速查找，O(1) 返回

### Q3: 两个 ClassLoader 加载同名类为什么不同？

**答**：因为每个 `ClassLoaderData` 有**独立的 Dictionary**。`CLD1.dictionary["Foo"]` 和 `CLD2.dictionary["Foo"]` 是两个不同的 `DictionaryEntry`，指向不同的 `InstanceKlass`。

JVM 中的类唯一标识是 `(class_name, defining_class_loader)`，不只是 `class_name`。

### Q4: 如何检测类循环依赖？

**答**：通过 `PlaceholderTable` 的 `LOAD_SUPER` 队列。在加载超类之前，注册 `(child_name, LOAD_SUPER, super_name)` 到 PlaceholderTable。如果递归加载超类的超类时发现 `check_seen_thread(THREAD, LOAD_SUPER)` 为 true，说明当前线程已经在为这个类加载超类——循环了。

### Q5: parallelCapable ClassLoader 如何保证不重复定义？

**答**：通过 `find_or_define_instance_class` 的 `DEFINE_CLASS` token 机制。第一个到达的线程成为 definer（`probe->set_definer(THREAD)`），其他线程等待。Definer 完成后通过 `probe->set_instance_klass(k)` 保存结果，等待者直接复用。

---

## 14. 源码文件索引

| 文件 | 行数 | 核心内容 |
|------|------|---------|
| `systemDictionary.hpp` | 737 | WK_KLASSES_DO 宏、80+ 核心类枚举、API 声明 |
| `systemDictionary.cpp` | 3081 | resolve_or_null、load_instance_class、resolve_from_stream、define_instance_class、find_or_define_instance_class、initialize、resolve_well_known_classes |
| `dictionary.hpp` | 317 | Dictionary/DictionaryEntry/SymbolPropertyEntry 结构 |
| `dictionary.cpp` | 626 | find/add_klass/get_entry/扩容/ProtectionDomain 缓存 |
| `placeholders.hpp` | 325 | PlaceholderTable/PlaceholderEntry/SeenThread 结构 |
| `placeholders.cpp` | 238 | find_and_add/find_and_remove/add_seen_thread |
| `loaderConstraints.hpp` | 134 | LoaderConstraintTable/LoaderConstraintEntry 结构 |
| `loaderConstraints.cpp` | 491 | add_entry/check_or_update/merge/extend/purge |

---

## 15. 与已有文档的衔接

### 与 `classloading_complete_flow.md` 的关系

那篇文档给出了类加载的**端到端骨架**（从 `new MyClass()` 到 `InstanceKlass` 创建），对 SystemDictionary 的覆盖是概述级别。本文是对那篇文档中 **§3（数据结构）** 和 **§5（并发控制）** 的深度展开。

| 主题 | `classloading_complete_flow.md` | 本文 |
|------|-------------------------------|------|
| Dictionary | 5 行结构体定义 | 完整哈希表机制（find/add/扩容/无锁读） |
| PlaceholderTable | 3 种 action 一句话 | SeenThread 双向链表、循环依赖算法、4 种并发 case |
| LoaderConstraintTable | 未涉及 | 完整的约束添加/合并/校验流程 |
| initialize() | 未涉及 | 5 张表创建 + well-known 类加载顺序 |
| define_instance_class | 8 行流程 | 逐步深入（check_constraints、add_to_hierarchy、update_dictionary） |
| find_or_define | 3 行提及 | DEFINE_CLASS token 完整流程 |

### 与 `CreateVM` 模块的衔接

`SystemDictionary::initialize()` 在 `init_globals()` 的第 18 步被调用：

```
init_globals()
  → ... (前 17 步)
  → systemDictionary_init()          ← 本文分析的入口
    → SystemDictionary::initialize()
      → 创建 5 张表
      → resolve_well_known_classes()  ← 加载 ~80 个核心类
  → ... (后续步骤)
```

这一步补齐了 `create_vm_outline.md` 中标注的 `SystemDictionary_init` 缺口。

### 与 `klass_hierarchy.md` 的衔接

`define_instance_class()` 中的 `add_to_hierarchy(k)` 将新类插入 `klass_hierarchy.md` 分析的继承层次：

```
add_to_hierarchy(k)
  → k->append_to_sibling_list()     ← 加入 Klass::_next_sibling 链表
  → k->process_interfaces()         ← 建立 itable
  → k->set_init_state(loaded)       ← 状态从 allocated → loaded
  → CodeCache::flush_dependents_on(k) ← 使依赖此类的编译代码失效
```

---

*分析完成。类加载系统进度: 85% → 92%，CreateVM 进度: 92% → 95%*
