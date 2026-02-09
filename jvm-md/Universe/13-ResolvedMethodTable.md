# 13. ResolvedMethodTable::create_table()

> 分析 MethodHandle/反射机制中已解析方法的全局缓存表

---

## 1. 源码分析

### 1.1 universe_init() 中的调用

```cpp
// src/hotspot/share/memory/universe.cpp:871
ResolvedMethodTable::create_table();
```

### 1.2 create_table() 实现

```cpp
// src/hotspot/share/prims/resolvedMethodTable.hpp:84
static void create_table() {
  assert(_the_table == NULL, "One symbol table allowed.");
  _the_table = new ResolvedMethodTable();
}

// 构造函数
ResolvedMethodTable::ResolvedMethodTable()
  : Hashtable<ClassLoaderWeakHandle, mtClass>(_table_size, sizeof(ResolvedMethodEntry)) { }

// 常量
enum Constants {
  _table_size = 1007  // 1007 个桶（质数）
};
```

---

## 2. 为什么需要 ResolvedMethodTable？

### 2.1 核心问题

**MethodHandle 机制需要缓存 Method*** 的包装对象。

```java
// Java 代码
MethodHandles.Lookup lookup = MethodHandles.lookup();
MethodHandle mh = lookup.findVirtual(String.class, "length", methodType(int.class));
// mh 内部需要引用 String.length() 方法的 Method*
```

### 2.2 三个核心需求

| 需求 | 说明 |
|------|------|
| **类重定义支持** | JVMTI RedefineClasses 热替换类时，需要更新所有指向旧 Method* 的引用 |
| **弱引用管理** | ResolvedMethodName 对象可以被 GC 回收，表中用弱引用跟踪 |
| **去重** | 同一个 Method* 只需要一个 ResolvedMethodName 对象 |

---

## 3. 关键数据结构

### 3.1 ResolvedMethodName（Java 对象）

```java
// java.lang.invoke.ResolvedMethodName
// 这是一个 JVM 内部类，用于包装 Method* 指针

class ResolvedMethodName {
    // JVM 注入的隐藏字段（非 Java 代码可见）
    Object vmholder;  // 持有 Method* 所属的 Klass（防止被卸载）
    long   vmtarget;  // 实际的 Method* 指针（intptr_t）
}
```

### 3.2 JVM 中的访问

```cpp
// src/hotspot/share/classfile/javaClasses.hpp:1088
class java_lang_invoke_ResolvedMethodName : AllStatic {
  static int _vmtarget_offset;  // vmtarget 字段偏移
  static int _vmholder_offset;  // vmholder 字段偏移
  
public:
  static Method* vmtarget(oop resolved_method) {
    Method* m = (Method*)resolved_method->address_field(_vmtarget_offset);
    return m;
  }
  
  static void set_vmtarget(oop resolved_method, Method* m) {
    resolved_method->address_field_put(_vmtarget_offset, (address)m);
  }
};
```

### 3.3 ResolvedMethodEntry（表条目）

```cpp
// src/hotspot/share/prims/resolvedMethodTable.hpp:38
class ResolvedMethodEntry : public HashtableEntry<ClassLoaderWeakHandle, mtClass> {
public:
  oop object() {
    return literal().resolve();  // 获取 ResolvedMethodName 对象
  }
  
  oop object_no_keepalive() {
    return literal().peek();     // 不保持存活的访问（GC 用）
  }
};
```

### 3.4 ResolvedMethodTable

```cpp
// src/hotspot/share/prims/resolvedMethodTable.hpp:54
class ResolvedMethodTable : public Hashtable<ClassLoaderWeakHandle, mtClass> {
  static ResolvedMethodTable* _the_table;  // 全局单例
  
  enum Constants {
    _table_size = 1007  // 1007 个桶
  };
  
  static int _oops_removed;  // GC 清理统计
  static int _oops_counted;
};
```

---

## 4. 内存布局

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    ResolvedMethodTable (全局哈希表)                         │
│                    _table_size = 1007                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   bucket[0] ──▶ NULL                                                        │
│   bucket[1] ──▶ ResolvedMethodEntry ──▶ ResolvedMethodEntry ──▶ NULL       │
│                       │                       │                             │
│                       ▼                       ▼                             │
│               WeakHandle                WeakHandle                          │
│                   │                         │                               │
│                   ▼                         ▼                               │
│          ┌────────────────────┐   ┌────────────────────┐                   │
│          │ ResolvedMethodName │   │ ResolvedMethodName │                   │
│          │ (Java 对象)        │   │ (Java 对象)        │                   │
│          ├────────────────────┤   ├────────────────────┤                   │
│          │ vmholder ──────────┼─▶ │ vmholder ──────────┼─▶ Klass*         │
│          │ vmtarget ──────────┼─▶ │ vmtarget ──────────┼─▶ Method*        │
│          └────────────────────┘   └────────────────────┘                   │
│                                                                             │
│   bucket[2] ──▶ NULL                                                        │
│   ...                                                                       │
│   bucket[1006] ──▶ NULL                                                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. 核心操作

### 5.1 哈希计算

```cpp
// src/hotspot/share/prims/resolvedMethodTable.cpp:81
unsigned int ResolvedMethodTable::compute_hash(Method* method) {
  // 组合多个因素计算哈希值
  unsigned int hash = method->method_holder()->class_loader_data()->identity_hash();
  hash = (hash * 31) ^ method->klass_name()->identity_hash();   // 类名
  hash = (hash * 31) ^ method->name()->identity_hash();          // 方法名
  hash = (hash * 31) ^ method->signature()->identity_hash();     // 方法签名
  return hash;
}
```

### 5.2 查找方法

```cpp
// src/hotspot/share/prims/resolvedMethodTable.cpp:60
oop ResolvedMethodTable::lookup(int index, unsigned int hash, Method* method) {
  for (ResolvedMethodEntry* p = bucket(index); p != NULL; p = p->next()) {
    if (p->hash() == hash) {
      oop target = p->object_no_keepalive();  // 弱引用 peek
      
      // 检查是否是同一个方法
      if (target != NULL && 
          java_lang_invoke_ResolvedMethodName::vmtarget(target) == method) {
        return p->object();  // 找到，返回（并保持存活）
      }
    }
  }
  return NULL;  // 未找到
}
```

### 5.3 添加方法

```cpp
// src/hotspot/share/prims/resolvedMethodTable.cpp:96
oop ResolvedMethodTable::basic_add(Method* method, Handle rmethod_name) {
  assert_locked_or_safepoint(ResolvedMethodTable_lock);
  
  unsigned int hash = compute_hash(method);
  int index = hash_to_index(hash);
  
  // 再次检查（double-check）
  oop entry = lookup(index, hash, method);
  if (entry != NULL) {
    return entry;
  }
  
  // 创建弱引用
  ClassLoaderWeakHandle w = ClassLoaderWeakHandle::create(rmethod_name);
  
  // 创建表条目
  ResolvedMethodEntry* p = (ResolvedMethodEntry*) 
      Hashtable<ClassLoaderWeakHandle, mtClass>::new_entry(hash, w);
  
  // 插入表中
  Hashtable<ClassLoaderWeakHandle, mtClass>::add_entry(index, p);
  
  return rmethod_name();
}
```

### 5.4 类重定义时更新

```cpp
// src/hotspot/share/prims/resolvedMethodTable.cpp:204
#if INCLUDE_JVMTI
void ResolvedMethodTable::adjust_method_entries(bool * trace_name_printed) {
  assert(SafepointSynchronize::is_at_safepoint(), "only called at safepoint");
  
  for (int i = 0; i < _the_table->table_size(); ++i) {
    for (ResolvedMethodEntry* entry = _the_table->bucket(i);
         entry != NULL; entry = entry->next()) {
      
      oop mem_name = entry->object_no_keepalive();
      if (mem_name == NULL) continue;
      
      Method* old_method = java_lang_invoke_ResolvedMethodName::vmtarget(mem_name);
      
      if (old_method->is_old()) {  // 方法已被重定义
        Method* new_method;
        
        if (old_method->is_deleted()) {
          // 方法被删除，替换为抛异常的桩
          new_method = Universe::throw_no_such_method_error();
        } else {
          // 获取新版本方法
          InstanceKlass* holder = old_method->method_holder();
          new_method = holder->method_with_idnum(old_method->orig_method_idnum());
        }
        
        // 更新 vmtarget 指向新方法
        java_lang_invoke_ResolvedMethodName::set_vmtarget(mem_name, new_method);
      }
    }
  }
}
#endif
```

---

## 6. GC 清理

```cpp
// src/hotspot/share/prims/resolvedMethodTable.cpp:155
void ResolvedMethodTable::unlink() {
  _oops_removed = 0;
  _oops_counted = 0;
  
  for (int i = 0; i < _the_table->table_size(); ++i) {
    ResolvedMethodEntry** p = _the_table->bucket_addr(i);
    ResolvedMethodEntry* entry = _the_table->bucket(i);
    
    while (entry != NULL) {
      _oops_counted++;
      oop l = entry->object_no_keepalive();
      
      if (l != NULL) {
        // 对象仍存活，保留
        p = entry->next_addr();
      } else {
        // 对象已被 GC 回收，移除条目
        _oops_removed++;
        entry->literal().release();  // 释放弱引用
        *p = entry->next();          // 从链表移除
        _the_table->free_entry(entry);
      }
      entry = (ResolvedMethodEntry*)HashtableEntry<...>::make_ptr(*p);
    }
  }
}
```

---

## 7. 与 MemberName 的关系

```
┌────────────────────────────────────────────────────────────────────────────┐
│                    MethodHandle 体系结构                                   │
├────────────────────────────────────────────────────────────────────────────┤
│                                                                            │
│  Java 层:                                                                  │
│  ┌─────────────────┐                                                       │
│  │  MethodHandle   │                                                       │
│  │  (抽象类)       │                                                       │
│  └────────┬────────┘                                                       │
│           │                                                                │
│           ▼                                                                │
│  ┌─────────────────┐                                                       │
│  │ DirectMethodHandle │                                                    │
│  │ _member ────────┼───▶ ┌─────────────────┐                              │
│  └─────────────────┘     │   MemberName    │                              │
│                          │   _method ──────┼──▶ ┌──────────────────────┐  │
│                          └─────────────────┘    │ ResolvedMethodName   │  │
│                                                 │ vmtarget ────────────┼─▶│
│                                                 └──────────────────────┘  │
│                                                                         │ │
│  JVM 层:                                                              Method*
│                                                                            │
│  ┌───────────────────────────────────────────────────────────────────────┐│
│  │                     ResolvedMethodTable                                ││
│  │  Method* ──▶ WeakHandle<ResolvedMethodName>                           ││
│  │  (缓存，支持类重定义时批量更新)                                       ││
│  └───────────────────────────────────────────────────────────────────────┘│
│                                                                            │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## 8. 使用场景

### 8.1 MethodHandle 创建

```java
// Java 代码
MethodHandles.Lookup lookup = MethodHandles.lookup();
MethodHandle mh = lookup.findVirtual(String.class, "length", methodType(int.class));

// JVM 内部流程:
// 1. 解析 String.length() 方法，得到 Method*
// 2. 在 ResolvedMethodTable 中查找是否已有 ResolvedMethodName
// 3. 如果没有，创建新的 ResolvedMethodName，放入表中
// 4. 将 ResolvedMethodName 设置到 MemberName 中
// 5. 创建 DirectMethodHandle
```

### 8.2 反射调用

```java
// Java 代码
Method method = String.class.getMethod("length");
Object result = method.invoke("hello");

// JVM 内部:
// 反射也可能使用 ResolvedMethodName 来缓存方法引用
```

### 8.3 类重定义（Hotswap）

```java
// 调试器执行 RedefineClasses
// JVM 在 safepoint 时调用:
// ResolvedMethodTable::adjust_method_entries()
// 更新所有 ResolvedMethodName 中的 vmtarget
```

---

## 9. 对比三个表

| 特性 | SymbolTable | StringTable | ResolvedMethodTable |
|------|-------------|-------------|---------------------|
| **存储内容** | Symbol (UTF-8 字符串) | Java String 对象 | ResolvedMethodName |
| **表大小** | 20011 | 65536 | 1007 |
| **引用类型** | 引用计数 | 弱引用 | 弱引用 |
| **生命周期** | 显式管理 | GC 管理 | GC 管理 |
| **类重定义** | 不受影响 | 不受影响 | **需要更新** |
| **主要用途** | 类名、方法名 | String.intern() | MethodHandle |

---

## 10. GDB 验证

### 10.1 断点设置

```bash
# 在创建表时设断点
b ResolvedMethodTable::create_table
```

### 10.2 验证表结构

```gdb
# 查看全局表
p ResolvedMethodTable::_the_table
# $1 = (ResolvedMethodTable *) 0x7ffff0c90100

# 查看表大小
p ResolvedMethodTable::_the_table->_table_size
# $2 = 1007

# 查看某个桶
p ResolvedMethodTable::_the_table->bucket(0)
# $3 = (ResolvedMethodEntry *) 0x0  (初始为空)
```

### 10.3 查看已添加的条目

```gdb
# 在程序运行一段时间后
# 遍历桶查找非空条目
p ResolvedMethodTable::_the_table->bucket(100)
# 如果非空，可以查看条目内容
```

---

## 11. 查看日志

### 11.1 JVM 参数

```bash
java -Xlog:membername+table=debug -version
```

### 11.2 输出示例

```
[0.123s][debug][membername,table] ResolvedMethod entry added for java/lang/String.length()I index 456
[0.456s][debug][membername,table] ResolvedMethod entry found for java/lang/Object.hashCode()I index 789
```

---

## 12. 设计要点总结

| 特性 | 说明 |
|------|------|
| **弱引用** | 使用 `ClassLoaderWeakHandle`，允许 GC 回收不再使用的条目 |
| **去重** | 同一个 Method* 只有一个 ResolvedMethodName |
| **类重定义** | `adjust_method_entries()` 批量更新所有 vmtarget |
| **锁保护** | 添加操作需要 `ResolvedMethodTable_lock` |
| **延迟清理** | GC 期间调用 `unlink()` 清理死亡条目 |

---

## 13. 常见问题

### Q1: 为什么不直接在 MemberName 中存 Method*？

**A**: 为了支持类重定义（Hotswap）。如果 Method* 分散存储，重定义时无法全部更新。
集中在 ResolvedMethodTable 中，可以一次遍历全部更新。

### Q2: 弱引用有什么好处？

**A**: 当 MethodHandle 不再被使用时，ResolvedMethodName 对象可以被 GC 回收，
表中的条目会在下次 `unlink()` 时自动清理，避免内存泄漏。

### Q3: 为什么表大小是 1007？

**A**: 1007 是质数，有助于均匀分布哈希值，减少冲突。
对于 MethodHandle 的使用场景，1007 是合理的初始大小。

---

## 14. 小结

`ResolvedMethodTable` 是 MethodHandle/反射机制的关键基础设施：

```
universe_init()
     │
     └─▶ ResolvedMethodTable::create_table()
              │
              └─▶ 创建 1007 个桶的空哈希表
                       │
                       │ 后续使用时
                       ▼
              ┌────────────────────────────────────────┐
              │  Java: lookup.findVirtual(...)         │
              │                 ↓                      │
              │  JVM: ResolvedMethodTable::add_method()│
              │                 ↓                      │
              │  存储: Method* ←→ ResolvedMethodName   │
              └────────────────────────────────────────┘
```

至此，`universe_init()` 的核心组件分析基本完成！
