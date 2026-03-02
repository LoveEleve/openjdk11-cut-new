# 9. ClassLoaderData::init_null_class_loader_data()

> 分析 Bootstrap ClassLoader 的数据结构初始化

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文分析 **9. ClassLoaderData::init_null_class_loader_data()** 的初始化过程：JVM 启动时该组件如何被创建、配置和激活，以及初始化顺序的约束关系。

### 0.2 为什么需要？

JVM 初始化顺序有严格的依赖关系——某些组件必须在其他组件之前初始化。理解初始化顺序有助于排查启动失败问题，也能理解各组件的设计约束。

### 0.3 怎么解决？

追踪初始化函数的调用链，分析每个初始化步骤的前置条件和后置效果，识别关键的初始化顺序约束。

### 0.4 为什么这样设计？

初始化顺序的设计原则：「被依赖的先初始化」。例如内存管理必须在 GC 之前初始化，GC 必须在类加载之前初始化。

---


## 1. 源码分析

```cpp
// src/hotspot/share/classfile/classLoaderData.cpp:140
void ClassLoaderData::init_null_class_loader_data() {
  assert(_the_null_class_loader_data == NULL, "cannot initialize twice");
  assert(ClassLoaderDataGraph::_head == NULL, "cannot initialize twice");
  
  // 创建 ClassLoaderData 对象
  // Handle() 创建一个 null handle，表示没有对应的 Java ClassLoader
  // false 表示不是匿名类
  _the_null_class_loader_data = new ClassLoaderData(Handle(), false);
  
  // 设置为 ClassLoaderDataGraph 的头节点
  ClassLoaderDataGraph::_head = _the_null_class_loader_data;
  
  assert(_the_null_class_loader_data->is_the_null_class_loader_data(), "Must be");
  
  // 调试日志
  LogTarget(Debug, class, loader, data) lt;
  if (lt.is_enabled()) {
    ResourceMark rm;
    LogStream ls(lt);
    ls.print("create ");
    _the_null_class_loader_data->print_value_on(&ls);
    ls.cr();
  }
}
```

**核心理解**：
- `Handle()` - 空 Handle，表示 Bootstrap ClassLoader **没有对应的 Java ClassLoader 对象**
- `false` - 不是匿名类加载器
- 创建后立即设为 `ClassLoaderDataGraph::_head`（全局链表头）

---

## 2. ClassLoaderData 构造函数详解

```cpp
// src/hotspot/share/classfile/classLoaderData.cpp:206
ClassLoaderData::ClassLoaderData(Handle h_class_loader, bool is_anonymous) :
  _is_anonymous(is_anonymous),
  // 关键：如果是匿名类或 null loader，_keep_alive = 1（永不卸载）
  _keep_alive((is_anonymous || h_class_loader.is_null()) ? 1 : 0),
  _metaspace(NULL),          // 延迟创建
  _unloading(false),
  _klasses(NULL),            // 还没有加载任何类
  _modules(NULL),
  _packages(NULL),
  _unnamed_module(NULL),
  _dictionary(NULL),
  _claimed(0),
  _modified_oops(true),
  _accumulated_modified_oops(false),
  _jmethod_ids(NULL),
  _handles(),
  _deallocate_list(NULL),
  _next(NULL),               // 链表下一个节点
  _class_loader_klass(NULL), // null loader 没有 klass
  _name(NULL),
  _name_and_id(NULL),
  // 创建 Metaspace 分配锁
  _metaspace_lock(new Mutex(Monitor::leaf+1, "Metaspace allocation lock", true,
                            Monitor::_safepoint_check_never)) 
{
  // 如果有对应的 Java ClassLoader 对象
  if (!h_class_loader.is_null()) {
    _class_loader = _handles.add(h_class_loader());
    _class_loader_klass = h_class_loader->klass();
  }

  if (!is_anonymous) {
    // 初始化 holder（用于 GC 判断存活性）
    initialize_holder(h_class_loader);
    
    // PackageEntryTable（包入口表）
    // 大小 109，是质数，减少哈希冲突
    _packages = new PackageEntryTable(PackageEntryTable::_packagetable_entry_size);
    
    // 创建 unnamed module
    if (h_class_loader.is_null()) {
      _unnamed_module = ModuleEntry::create_boot_unnamed_module(this);
    } else {
      _unnamed_module = ModuleEntry::create_unnamed_module(this);
    }
    
    // Dictionary（类字典）- 存储已加载的 InstanceKlass
    _dictionary = create_dictionary();
  }
}
```

---

## 3. ClassLoaderData 结构详解

### 3.1 完整字段列表

```cpp
class ClassLoaderData : public CHeapObj<mtClass> {
private:
  static ClassLoaderData* _the_null_class_loader_data;  // 全局静态：Bootstrap ClassLoader
  
  // === 基本信息 ===
  WeakHandle<vm_class_loader_data> _holder;  // 用于 GC 判断存活
  OopHandle _class_loader;                   // 对应的 java.lang.ClassLoader 对象
  Klass* _class_loader_klass;                // ClassLoader 的 Klass
  Symbol* _name;                             // 类加载器名称
  Symbol* _name_and_id;                      // 名称 + id
  
  // === 元空间相关 ===
  ClassLoaderMetaspace* volatile _metaspace; // 元空间（延迟创建）
  Mutex* _metaspace_lock;                    // 元空间分配锁
  
  // === 状态标志 ===
  bool _unloading;                           // 是否正在卸载
  bool _is_anonymous;                        // 是否是匿名类加载器
  s2 _keep_alive;                            // 是否保持存活（0 可卸载，>0 不可卸载）
  volatile int _claimed;                     // GC 遍历标记
  
  // === GC 相关 ===
  bool _modified_oops;                       // 卡表等价物
  bool _accumulated_modified_oops;           // CMS 支持
  
  // === 类和模块管理 ===
  Klass* volatile _klasses;                  // 该加载器定义的所有类（链表）
  PackageEntryTable* volatile _packages;     // 包入口表
  ModuleEntryTable* volatile _modules;       // 模块入口表
  ModuleEntry* _unnamed_module;              // 未命名模块
  Dictionary* _dictionary;                   // 类字典（已加载的 InstanceKlass）
  
  // === 其他 ===
  ChunkedHandleList _handles;                // 句柄列表
  JNIMethodBlock* _jmethod_ids;              // JNI 方法 ID
  GrowableArray<Metadata*>* _deallocate_list; // 待释放元数据
  ClassLoaderData* _next;                    // 链表下一个节点
};
```

### 3.2 内存布局图

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                    ClassLoaderData @ 0x7ffff0c8e040                                 │
│                    (Bootstrap ClassLoader / Null ClassLoader)                       │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                     │
│  偏移  字段名                  值                    说明                           │
│  ────  ──────────────────────  ──────────────────    ────────────────────────────── │
│  +0x00 _holder                 (weak handle)         GC 存活判断                    │
│  +0x10 _class_loader           NULL                  没有对应的 Java ClassLoader    │
│  +0x18 _metaspace              NULL → 延迟创建      元空间                          │
│  +0x20 _metaspace_lock         0x7ffff0c8e120       Metaspace 分配锁               │
│  +0x28 _unloading              false                 非卸载状态                     │
│  +0x29 _is_anonymous           false                 非匿名类加载器                 │
│  +0x2a _keep_alive             1                     永远存活                       │
│  +0x2c _claimed                0                     GC 遍历标记                    │
│  +0x30 _klasses                NULL → 后续填充      已加载的类链表                 │
│  +0x38 _packages               0x7ffff0c8e1f0       PackageEntryTable              │
│  +0x40 _modules                NULL → 延迟创建      ModuleEntryTable               │
│  +0x48 _unnamed_module         0x7ffff0c8e970       未命名模块                     │
│  +0x50 _dictionary             0x7ffff0c8ea10       类字典                         │
│  +0x58 _jmethod_ids            NULL                  JNI 方法 ID                    │
│  +0x60 _deallocate_list        NULL                  待释放元数据                   │
│  +0x68 _next                   NULL                  链表下一个节点                 │
│  +0x70 _class_loader_klass     NULL                  没有对应的 Klass              │
│  +0x78 _name                   NULL                  未设置名称                     │
│  +0x80 _name_and_id            NULL                  未设置名称和 ID               │
│                                                                                     │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. 核心子结构

### 4.1 Dictionary（类字典）

```cpp
// src/hotspot/share/classfile/dictionary.hpp:42
class Dictionary : public Hashtable<InstanceKlass*, mtClass> {
  ClassLoaderData* _loader_data;  // 反向指针
  bool _resizable;
  bool _needs_resizing;
};

// 创建时
const int _boot_loader_dictionary_size = 1009;  // Bootstrap ClassLoader 使用
const int _default_loader_dictionary_size = 107; // 其他 ClassLoader

Dictionary* ClassLoaderData::create_dictionary() {
  int size;
  if (_the_null_class_loader_data == NULL) {
    size = _boot_loader_dictionary_size;  // 1009 个桶
    resizable = true;
  } else if (is_system_class_loader_data()) {
    size = _boot_loader_dictionary_size;  // 1009 个桶
    resizable = true;
  } else {
    size = _default_loader_dictionary_size;  // 107 个桶
    resizable = true;
  }
  return new Dictionary(this, size, resizable);
}
```

**作用**：
- 存储该 ClassLoader **已加载**的所有 `InstanceKlass`
- 当调用 `ClassLoader.loadClass("java.lang.String")` 时，先在 Dictionary 中查找

### 4.2 PackageEntryTable（包入口表）

```cpp
// src/hotspot/share/classfile/packageEntry.hpp:97
class PackageEntry : public HashtableEntry<Symbol*, mtModule> {
  ModuleEntry* _module;           // 所属模块
  int _export_flags;              // 导出状态
  GrowableArray<ModuleEntry*>* _qualified_exports;  // 导出目标
};
```

**作用**：
- 存储该 ClassLoader 加载的所有**包信息**
- Bootstrap ClassLoader 负责 `java.lang`、`java.util`、`java.io` 等核心包
- 大小：`_packagetable_entry_size = 109`（质数）

### 4.3 ModuleEntry（模块入口）

```cpp
// src/hotspot/share/classfile/moduleEntry.hpp:63
class ModuleEntry : public HashtableEntry<Symbol*, mtModule> {
  OopHandle _module;              // java.lang.Module 对象
  ClassLoaderData* _loader_data;  // 所属 ClassLoaderData
  GrowableArray<ModuleEntry*>* _reads;  // 可读模块列表
  Symbol* _version;               // 模块版本
  Symbol* _location;              // 模块位置
  bool _can_read_all_unnamed;     // 是否可读所有未命名模块
  bool _is_open;                  // 是否开放模块
};
```

**作用**：
- Bootstrap ClassLoader 创建 `_unnamed_module`（未命名模块）
- 不属于任何命名模块的类会归入这个未命名模块
- Java 9+ 模块系统的核心数据结构

---

## 5. ClassLoaderDataGraph（全局链表）

```cpp
// src/hotspot/share/classfile/classLoaderData.hpp:68
class ClassLoaderDataGraph : public AllStatic {
  static ClassLoaderData* _head;       // 链表头
  static ClassLoaderData* _unloading;  // 正在卸载的 CLD 链表
  static ClassLoaderData* _saved_head; // CMS 支持
  static ClassLoaderData* _saved_unloading;
  static bool _should_purge;
  static bool _metaspace_oom;          // 元空间 OOM 标记
  
  static volatile size_t _num_instance_classes;  // 实例类计数
  static volatile size_t _num_array_classes;     // 数组类计数
};
```

### 5.1 全局架构图

```
                        ClassLoaderDataGraph
                               │
                               │ _head
                               ▼
┌─────────────────────┐     ┌─────────────────────┐     ┌─────────────────────┐
│   ClassLoaderData   │     │   ClassLoaderData   │     │   ClassLoaderData   │
│   (Bootstrap CL)    │────▶│   (App CL)          │────▶│   (Custom CL)       │
│   _the_null_cld     │     │                     │     │                     │
├─────────────────────┤     ├─────────────────────┤     ├─────────────────────┤
│ _class_loader=NULL  │     │ _class_loader=oop   │     │ _class_loader=oop   │
│ _keep_alive=1       │     │ _keep_alive=0       │     │ _keep_alive=0       │
│ _klasses → ...      │     │ _klasses → ...      │     │ _klasses → ...      │
│ _dictionary → ...   │     │ _dictionary → ...   │     │ _dictionary → ...   │
│ _next ──────────────┼────▶│ _next ──────────────┼────▶│ _next = NULL        │
└─────────────────────┘     └─────────────────────┘     └─────────────────────┘
        │                           │                           │
        │ _klasses                  │ _klasses                  │ _klasses
        ▼                           ▼                           ▼
┌───────────────┐           ┌───────────────┐           ┌───────────────┐
│ java.lang.    │           │ com.example.  │           │ MyClass1      │
│ Object        │───▶       │ MyApp         │───▶       │               │───▶ NULL
│ (InstanceKlass│   ...     │ (InstanceKlass│   ...     │ (InstanceKlass│
└───────────────┘           └───────────────┘           └───────────────┘
```

### 5.2 遍历操作

```cpp
// 遍历所有 CLD
void ClassLoaderDataGraph::cld_do(CLDClosure* cl) {
  for (ClassLoaderData* cld = _head; cl != NULL && cld != NULL; cld = cld->next()) {
    cl->do_cld(cld);
  }
}

// 遍历所有类
void ClassLoaderDataGraph::classes_do(KlassClosure* klass_closure) {
  Thread* thread = Thread::current();
  for (ClassLoaderData* cld = _head; cld != NULL; cld = cld->next()) {
    Handle holder(thread, cld->holder_phantom());  // 防止 GC 期间被卸载
    cld->classes_do(klass_closure);
  }
}
```

---

## 6. Bootstrap ClassLoader 的特殊性

### 6.1 为什么没有 Java 对象？

```java
// Java 代码
Object.class.getClassLoader()  // 返回 null
String.class.getClassLoader()  // 返回 null
```

**原因**：
1. Bootstrap ClassLoader 是 JVM **内置**的，由 C++ 代码实现
2. 它负责加载 `rt.jar`（Java 8）或 `java.base` 模块（Java 9+）中的核心类
3. 在 Java 语言层面，`null` 表示 Bootstrap ClassLoader

### 6.2 _keep_alive = 1 的含义

```cpp
// 构造函数中
_keep_alive((is_anonymous || h_class_loader.is_null()) ? 1 : 0),
```

- `_keep_alive > 0`：表示该 CLD **永远不会被 GC 卸载**
- Bootstrap ClassLoader（`_class_loader = NULL`）的 `_keep_alive = 1`
- 匿名类的 `_keep_alive = 1`（直到解析完成）
- 普通 ClassLoader 的 `_keep_alive = 0`（可以被卸载）

### 6.3 存活性判断

```cpp
// src/hotspot/share/classfile/classLoaderData.cpp:753
bool ClassLoaderData::is_alive() const {
  bool alive = keep_alive()              // null loader 和匿名类
      || (_holder.peek() != NULL);       // 或者 WeakHandle 未被清理
  return alive;
}
```

---

## 7. Metaspace 延迟创建

```cpp
// src/hotspot/share/classfile/classLoaderData.cpp:881
ClassLoaderMetaspace* ClassLoaderData::metaspace_non_null() {
  ClassLoaderMetaspace* metaspace = OrderAccess::load_acquire(&_metaspace);
  if (metaspace == NULL) {
    MutexLockerEx ml(_metaspace_lock, Mutex::_no_safepoint_check_flag);
    if ((metaspace = _metaspace) == NULL) {
      if (this == the_null_class_loader_data()) {
        // Bootstrap ClassLoader 使用 BootMetaspaceType
        metaspace = new ClassLoaderMetaspace(_metaspace_lock, Metaspace::BootMetaspaceType);
      } else if (is_anonymous()) {
        metaspace = new ClassLoaderMetaspace(_metaspace_lock, Metaspace::AnonymousMetaspaceType);
      } else if (class_loader()->is_a(SystemDictionary::reflect_DelegatingClassLoader_klass())) {
        metaspace = new ClassLoaderMetaspace(_metaspace_lock, Metaspace::ReflectionMetaspaceType);
      } else {
        metaspace = new ClassLoaderMetaspace(_metaspace_lock, Metaspace::StandardMetaspaceType);
      }
      OrderAccess::release_store(&_metaspace, metaspace);
    }
  }
  return metaspace;
}
```

**延迟创建的原因**：
1. 并非所有 ClassLoader 都会加载类（如纯委派的）
2. 节省内存：只有真正需要时才分配 Metaspace

---

## 8. 类加载器卸载

### 8.1 卸载流程

```cpp
// src/hotspot/share/classfile/classLoaderData.cpp:1439
bool ClassLoaderDataGraph::do_unloading(bool clean_previous_versions) {
  ClassLoaderData* data = _head;
  ClassLoaderData* prev = NULL;
  bool seen_dead_loader = false;
  
  while (data != NULL) {
    if (data->is_alive()) {
      // 存活，继续
      prev = data;
      data = data->next();
      continue;
    }
    
    // 不存活，准备卸载
    seen_dead_loader = true;
    ClassLoaderData* dead = data;
    dead->unload();
    data = data->next();
    
    // 从链表中移除
    if (prev != NULL) {
      prev->set_next(data);
    } else {
      _head = data;
    }
    
    // 加入卸载链表
    dead->set_next(_unloading);
    _unloading = dead;
  }
  return seen_dead_loader;
}
```

### 8.2 为什么 Bootstrap ClassLoader 不会被卸载？

```
is_alive() 返回 true 的条件：
1. keep_alive() > 0  ← Bootstrap ClassLoader 的 _keep_alive = 1，满足！
2. 或者 _holder.peek() != NULL

所以 Bootstrap ClassLoader 永远 is_alive() = true
```

---

## 9. GDB 验证

### 9.1 断点设置

```bash
# 在 init_null_class_loader_data 设断点
b ClassLoaderData::init_null_class_loader_data
```

### 9.2 验证 ClassLoaderData

```gdb
# 进入函数后
n  # 执行 new ClassLoaderData

# 查看 _the_null_class_loader_data
p ClassLoaderData::_the_null_class_loader_data
# $1 = (ClassLoaderData *) 0x7ffff0c8e040

# 查看字段
p *ClassLoaderData::_the_null_class_loader_data
# {
#   _holder = {_obj = 0x0},
#   _class_loader = {_obj = 0x0},       ← NULL，没有对应的 Java 对象
#   _metaspace = 0x0,                    ← 延迟创建
#   _metaspace_lock = 0x7ffff0c8e120,
#   _unloading = false,
#   _is_anonymous = false,
#   _keep_alive = 1,                     ← 永不卸载
#   _klasses = 0x0,                      ← 还没有加载类
#   _packages = 0x7ffff0c8e1f0,          ← PackageEntryTable
#   _modules = 0x0,
#   _unnamed_module = 0x7ffff0c8e970,
#   _dictionary = 0x7ffff0c8ea10,
#   _next = 0x0,                         ← 链表唯一节点
#   _class_loader_klass = 0x0,
#   _name = 0x0,
#   _name_and_id = 0x0
# }

# 查看 ClassLoaderDataGraph
p ClassLoaderDataGraph::_head
# $2 = (ClassLoaderData *) 0x7ffff0c8e040  ← 与 _the_null_class_loader_data 相同
```

### 9.3 验证 Dictionary

```gdb
p ClassLoaderData::_the_null_class_loader_data->_dictionary
# $3 = (Dictionary *) 0x7ffff0c8ea10

p *ClassLoaderData::_the_null_class_loader_data->_dictionary
# {
#   _loader_data = 0x7ffff0c8e040,  ← 反向指针
#   _table_size = 1009,              ← 1009 个桶
#   _resizable = true,
#   _needs_resizing = false
# }
```

---

## 10. 查看日志

### 10.1 JVM 参数

```bash
java -Xlog:class+loader+data=debug -version
```

### 10.2 输出示例

```
[0.001s][debug][class,loader,data] create loader data: 0x00007f1234567890 of 'bootstrap'
```

---

## 11. 与其他组件的关系

```
                                    universe_init()
                                         │
                    ┌────────────────────┼────────────────────┐
                    │                    │                    │
                    ▼                    ▼                    ▼
            SymbolTable           ClassLoaderData        StringTable
           (11-已完成)               (当前)              (12-已完成)
                │                       │                    │
                │                       │                    │
                ▼                       ▼                    ▼
         存储符号名称             管理类加载器           存储字符串常量
         (UTF-8 编码)            和已加载的类           (String.intern)
                │                       │                    │
                └───────────────────────┼────────────────────┘
                                        │
                                        ▼
                              当加载类时，流程：
                              1. 在 SymbolTable 中查找/创建类名 Symbol
                              2. 在 ClassLoaderData._dictionary 中查找类
                              3. 如果没找到，加载类，创建 InstanceKlass
                              4. 字符串常量放入 StringTable
```

---

## 12. 设计要点总结

| 特性 | 说明 |
|------|------|
| **延迟初始化** | `_metaspace` 和 `_modules` 都是延迟创建 |
| **链表管理** | `ClassLoaderDataGraph` 用单向链表管理所有 CLD |
| **永不卸载** | Bootstrap ClassLoader 的 `_keep_alive=1` |
| **双重查找** | 加载类时先查 Dictionary，再委托父加载器 |
| **锁保护** | `_metaspace_lock` 保护元空间分配 |
| **GC 支持** | `_holder` 用 WeakHandle 支持 GC 判断存活 |

---

## 13. 常见问题

### Q1: 为什么 Bootstrap ClassLoader 没有 Java 对象？

**A**: 设计上的选择。Bootstrap ClassLoader 是 JVM 内置的 C++ 代码，在 JVM 启动时就存在，
不需要也无法用 Java 代码表示。在 Java 层面用 `null` 表示它。

### Q2: ClassLoaderData 和 ClassLoaderDataGraph 的关系？

**A**: 
- `ClassLoaderData` 是**每个类加载器**的数据容器
- `ClassLoaderDataGraph` 是**全局管理器**，用链表管理所有 CLD
- 关系类似于：`ClassLoaderData` 是链表节点，`ClassLoaderDataGraph` 是链表头

### Q3: 什么时候创建其他 ClassLoaderData？

**A**: 当 Java 代码创建新的 `ClassLoader` 实例并用它加载类时：
```java
ClassLoader loader = new URLClassLoader(urls);
Class<?> clazz = loader.loadClass("MyClass");  // 此时创建 CLD
```

---

## 14. 下一步

ClassLoaderData 的初始化完成后，JVM 已经具备了基本的类加载基础设施：
- **SymbolTable** - 存储类名、方法名等符号
- **ClassLoaderData** - 管理类加载器和已加载的类
- **StringTable** - 管理字符串常量

接下来 `universe_init()` 还有：
- 性能计数器初始化
- AOT 加载器初始化
- 其他组件...
