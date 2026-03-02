# 10. LatestMethodCache 创建

> 分析 JVM 内部频繁调用的 Java 方法缓存机制

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **10. LatestMethodCache 创建**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 1. 源码分析

### 1.1 universe_init() 中的创建

```cpp
// src/hotspot/share/memory/universe.cpp:832-837
Universe::_finalizer_register_cache = new LatestMethodCache();
Universe::_loader_addClass_cache    = new LatestMethodCache();
Universe::_pd_implies_cache         = new LatestMethodCache();
Universe::_throw_illegal_access_error_cache = new LatestMethodCache();
Universe::_throw_no_such_method_error_cache = new LatestMethodCache();
Universe::_do_stack_walk_cache = new LatestMethodCache();
```

**注意**：这里只是创建**空对象**，真正的初始化在 `universe_post_init()` 中的 `initialize_known_methods()` 完成。

---

## 2. LatestMethodCache 结构

```cpp
// src/hotspot/share/memory/universe.hpp:48
class LatestMethodCache : public CHeapObj<mtClass> {
private:
  Klass* _klass;        // 方法所属的类（不是 Method*！）
  int    _method_idnum; // 方法在类中的编号

public:
  LatestMethodCache() { _klass = NULL; _method_idnum = -1; }
  
  void   init(Klass* k, Method* m);
  Klass* klass() const           { return _klass; }
  int    method_idnum() const    { return _method_idnum; }
  
  Method* get_method();  // 动态获取最新的 Method*
};
```

### 2.1 为什么不直接缓存 Method*？

**关键设计**：存储 `(Klass*, method_idnum)` 而不是 `Method*`

```cpp
// 获取方法时动态查找
Method* LatestMethodCache::get_method() {
  if (klass() == NULL) return NULL;
  InstanceKlass* ik = InstanceKlass::cast(klass());
  Method* m = ik->method_with_idnum(method_idnum());  // 每次动态获取
  return m;
}
```

**原因**：支持**类重定义（RedefineClasses）**！

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        类重定义场景                                     │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   初始状态：                                                            │
│   ┌─────────────────┐                                                   │
│   │  InstanceKlass  │                                                   │
│   │  (Finalizer)    │                                                   │
│   │  _methods[0]────┼──▶ Method* (register)  @ 0x1000                  │
│   │  _methods[1]    │                                                   │
│   └─────────────────┘                                                   │
│                                                                         │
│   如果缓存 Method*：                                                    │
│   _finalizer_register_cache = 0x1000  ← 直接存地址                     │
│                                                                         │
│   类重定义后：                                                          │
│   ┌─────────────────┐                                                   │
│   │  InstanceKlass  │                                                   │
│   │  (Finalizer)    │                                                   │
│   │  _methods[0]────┼──▶ Method* (register)  @ 0x2000  ← 新地址！      │
│   │  _methods[1]    │                                                   │
│   └─────────────────┘                                                   │
│                                                                         │
│   问题：_finalizer_register_cache 仍指向 0x1000（已失效！）            │
│                                                                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   使用 (Klass*, idnum) 的方案：                                        │
│   _finalizer_register_cache = { _klass = Finalizer, _method_idnum = 0 }│
│                                                                         │
│   类重定义后：                                                          │
│   - Klass* 不变（类的元数据地址不变）                                  │
│   - method_idnum 不变（方法在类中的编号不变）                          │
│   - 调用 get_method() 时动态查找，总是获取最新的 Method*               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 6 个缓存详解

### 3.1 _finalizer_register_cache

```cpp
// 对应 Java 方法：java.lang.ref.Finalizer.register(Object)
initialize_known_method(_finalizer_register_cache,
                        SystemDictionary::Finalizer_klass(),
                        "register",
                        vmSymbols::object_void_signature(),  // (Ljava/lang/Object;)V
                        true, CHECK);
```

**作用**：注册需要执行 finalizer 的对象

**调用场景**：
```cpp
// src/hotspot/share/oops/instanceKlass.cpp:1225
instanceOop InstanceKlass::register_finalizer(instanceOop i, TRAPS) {
  instanceHandle h_i(THREAD, i);
  JavaValue result(T_VOID);
  JavaCallArguments args(h_i);
  // 获取缓存的方法
  methodHandle mh (THREAD, Universe::finalizer_register_method());
  // 调用 Finalizer.register(obj)
  JavaCalls::call(&result, mh, &args, CHECK_NULL);
  return h_i();
}
```

**对应 Java 代码**：
```java
// java.lang.ref.Finalizer
final class Finalizer extends FinalReference<Object> {
    static void register(Object finalizee) {
        new Finalizer(finalizee);  // 创建 Finalizer 引用包装对象
    }
}
```

### 3.2 _loader_addClass_cache

```cpp
// 对应 Java 方法：java.lang.ClassLoader.addClass(Class)
initialize_known_method(_loader_addClass_cache,
                        SystemDictionary::ClassLoader_klass(),
                        "addClass",
                        vmSymbols::class_void_signature(),  // (Ljava/lang/Class;)V
                        false, CHECK);
```

**作用**：类加载器注册已加载的类

**对应 Java 代码**：
```java
// java.lang.ClassLoader
void addClass(Class<?> c) {
    classes.addElement(c);  // 维护已加载类的 Vector
}
```

### 3.3 _pd_implies_cache

```cpp
// 对应 Java 方法：java.security.ProtectionDomain.impliesCreateAccessControlContext()
initialize_known_method(_pd_implies_cache,
                        SystemDictionary::ProtectionDomain_klass(),
                        "impliesCreateAccessControlContext",
                        vmSymbols::void_boolean_signature(),  // ()Z
                        false, CHECK);
```

**作用**：安全检查 - 检查保护域是否允许创建 AccessControlContext

### 3.4 _throw_illegal_access_error_cache

```cpp
// 对应 Java 方法：jdk.internal.misc.Unsafe.throwIllegalAccessError()
initialize_known_method(_throw_illegal_access_error_cache,
                        SystemDictionary::internal_Unsafe_klass(),
                        "throwIllegalAccessError",
                        vmSymbols::void_method_signature(),  // ()V
                        true, CHECK);
```

**作用**：从 native 代码抛出 `IllegalAccessError`

**对应 Java 代码**：
```java
// jdk.internal.misc.Unsafe
public native void throwIllegalAccessError();
```

### 3.5 _throw_no_such_method_error_cache

```cpp
// 对应 Java 方法：jdk.internal.misc.Unsafe.throwNoSuchMethodError()
initialize_known_method(_throw_no_such_method_error_cache,
                        SystemDictionary::internal_Unsafe_klass(),
                        "throwNoSuchMethodError",
                        vmSymbols::void_method_signature(),  // ()V
                        true, CHECK);
```

**作用**：从 native 代码抛出 `NoSuchMethodError`

### 3.6 _do_stack_walk_cache

```cpp
// 对应 Java 方法：java.lang.StackStreamFactory$AbstractStackWalker.doStackWalk(...)
initialize_known_method(_do_stack_walk_cache,
                        SystemDictionary::AbstractStackWalker_klass(),
                        "doStackWalk",
                        vmSymbols::doStackWalk_signature(),
                        false, CHECK);
```

**作用**：栈遍历回调（Java 9+ StackWalker API）

**方法签名**：
```java
// doStackWalk_signature
(JIIII)Ljava/lang/Object;
// 即：long anchor, int mode, int skipFrames, int batchSize, int startIndex
```

---

## 4. 内存布局

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    Universe 静态字段                                    │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  _finalizer_register_cache ──────▶ ┌─────────────────────────────────┐ │
│                                    │  LatestMethodCache              │ │
│                                    │  _klass = Finalizer             │ │
│                                    │  _method_idnum = 0              │ │
│                                    └─────────────────────────────────┘ │
│                                                                         │
│  _loader_addClass_cache ─────────▶ ┌─────────────────────────────────┐ │
│                                    │  LatestMethodCache              │ │
│                                    │  _klass = ClassLoader           │ │
│                                    │  _method_idnum = ?              │ │
│                                    └─────────────────────────────────┘ │
│                                                                         │
│  _pd_implies_cache ──────────────▶ ┌─────────────────────────────────┐ │
│                                    │  LatestMethodCache              │ │
│                                    │  _klass = ProtectionDomain      │ │
│                                    │  _method_idnum = ?              │ │
│                                    └─────────────────────────────────┘ │
│                                                                         │
│  _throw_illegal_access_error_cache ▶ ┌─────────────────────────────────┐│
│                                      │  LatestMethodCache              ││
│                                      │  _klass = internal_Unsafe       ││
│                                      │  _method_idnum = ?              ││
│                                      └─────────────────────────────────┘│
│                                                                         │
│  _throw_no_such_method_error_cache ▶ ┌─────────────────────────────────┐│
│                                      │  LatestMethodCache              ││
│                                      │  _klass = internal_Unsafe       ││
│                                      │  _method_idnum = ?              ││
│                                      └─────────────────────────────────┘│
│                                                                         │
│  _do_stack_walk_cache ───────────▶ ┌─────────────────────────────────┐ │
│                                    │  LatestMethodCache              │ │
│                                    │  _klass = AbstractStackWalker   │ │
│                                    │  _method_idnum = ?              │ │
│                                    └─────────────────────────────────┘ │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘

每个 LatestMethodCache 对象大小：
  _klass (8 bytes) + _method_idnum (4 bytes) + padding (4 bytes) = 16 bytes
```

---

## 5. 初始化流程

```
universe_init()                      universe_post_init()
     │                                      │
     ▼                                      ▼
┌─────────────────────┐           ┌─────────────────────────────────┐
│ 创建 6 个空对象     │           │ initialize_known_methods()      │
│ _klass = NULL       │    ...    │ 查找对应的 Java 类和方法        │
│ _method_idnum = -1  │ ───────▶  │ 设置 _klass 和 _method_idnum    │
└─────────────────────┘           └─────────────────────────────────┘
```

### 5.1 initialize_known_method 详解

```cpp
// src/hotspot/share/memory/universe.cpp:1141
static void initialize_known_method(LatestMethodCache* method_cache,
                                    InstanceKlass* ik,
                                    const char* method,
                                    Symbol* signature,
                                    bool is_static,
                                    TRAPS) {
  // 查找方法
  TempNewSymbol name = SymbolTable::new_symbol(method, CHECK);
  Method* m = NULL;
  
  if (is_static) {
    m = ik->find_method(name, signature);
  } else {
    // 包括父类中的方法
    m = ik->lookup_method(name, signature);
  }
  
  if (m == NULL || !m->is_static() != !is_static) {
    vm_exit_during_initialization("Unable to link/verify method");
  }
  
  // 初始化缓存
  method_cache->init(ik, m);
}
```

### 5.2 init() 实现

```cpp
// src/hotspot/share/memory/universe.cpp:1544
void LatestMethodCache::init(Klass* k, Method* m) {
  if (!UseSharedSpaces) {
    _klass = k;
  }
  _method_idnum = m->method_idnum();  // 只存编号，不存指针！
  assert(_method_idnum >= 0, "sanity check");
}
```

---

## 6. 使用场景总结

| 缓存 | Java 方法 | 调用场景 |
|------|----------|---------|
| `_finalizer_register_cache` | `Finalizer.register(Object)` | 创建有 `finalize()` 方法的对象时 |
| `_loader_addClass_cache` | `ClassLoader.addClass(Class)` | 类加载完成后注册 |
| `_pd_implies_cache` | `ProtectionDomain.impliesCreateAccessControlContext()` | 安全检查 |
| `_throw_illegal_access_error_cache` | `Unsafe.throwIllegalAccessError()` | 访问控制违规 |
| `_throw_no_such_method_error_cache` | `Unsafe.throwNoSuchMethodError()` | 方法解析失败 |
| `_do_stack_walk_cache` | `AbstractStackWalker.doStackWalk(...)` | StackWalker API |

---

## 7. Finalizer 注册流程示例

```
┌───────────────────────────────────────────────────────────────────────────┐
│                     创建有 finalize() 方法的对象                          │
├───────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│  Java 代码：                                                              │
│  class MyClass {                                                          │
│      @Override                                                            │
│      protected void finalize() { System.out.println("finalizing"); }      │
│  }                                                                        │
│  new MyClass();  // 触发 finalizer 注册                                   │
│                                                                           │
├───────────────────────────────────────────────────────────────────────────┤
│  JVM 内部流程：                                                           │
│                                                                           │
│  1. InstanceKlass::allocate_instance()                                    │
│     │                                                                     │
│     ▼                                                                     │
│  2. 检查 has_finalizer() == true                                          │
│     │                                                                     │
│     ▼                                                                     │
│  3. register_finalizer(instanceOop i, TRAPS)                              │
│     │                                                                     │
│     ▼                                                                     │
│  4. methodHandle mh = Universe::finalizer_register_method()               │
│     │   └──▶ _finalizer_register_cache->get_method()                      │
│     │        └──▶ Finalizer.method_with_idnum(0)                          │
│     │             └──▶ Method* for Finalizer.register                     │
│     ▼                                                                     │
│  5. JavaCalls::call(&result, mh, &args, ...)                              │
│     │                                                                     │
│     ▼                                                                     │
│  6. 执行 Java 代码：Finalizer.register(obj)                               │
│     │   └──▶ new Finalizer(obj)                                           │
│     │        └──▶ 加入 Finalizer 队列                                     │
│     ▼                                                                     │
│  7. 返回对象指针                                                          │
│                                                                           │
└───────────────────────────────────────────────────────────────────────────┘
```

---

## 8. GDB 验证

### 8.1 断点设置

```bash
# 在方法缓存初始化处设断点
b Universe::initialize_known_methods
```

### 8.2 验证缓存内容

```gdb
# 查看 _finalizer_register_cache
p Universe::_finalizer_register_cache
# $1 = (LatestMethodCache *) 0x7ffff0c90010

p *Universe::_finalizer_register_cache
# {
#   _klass = 0x100020c00,           ← Finalizer 类
#   _method_idnum = 0               ← register 方法的编号
# }

# 验证 Klass
p ((InstanceKlass*)Universe::_finalizer_register_cache->_klass)->_name->_body
# "java/lang/ref/Finalizer"

# 获取实际的 Method*
p Universe::_finalizer_register_cache->get_method()
# $2 = (Method *) 0x7ffff0123456

p Universe::_finalizer_register_cache->get_method()->name()->as_C_string()
# "register"
```

---

## 9. 设计要点总结

| 特性 | 说明 |
|------|------|
| **间接引用** | 存储 `(Klass*, idnum)` 而不是 `Method*` |
| **支持热替换** | 类重定义后 `get_method()` 返回新的 Method* |
| **延迟初始化** | `universe_init()` 创建空对象，`universe_post_init()` 才真正初始化 |
| **静态/实例方法** | `is_static` 参数控制使用 `find_method` 或 `lookup_method` |
| **性能优化** | 避免每次调用都通过名字查找方法 |

---

## 10. 常见问题

### Q1: 为什么 Finalizer.register 需要缓存？

**A**: 每创建一个有 `finalize()` 方法的对象都需要调用此方法。如果每次都通过名字查找，
性能损失很大。缓存后只需一次指针解引用。

### Q2: method_idnum 是什么？

**A**: 方法在类的方法数组中的索引。每个类在编译时确定，即使方法被重定义（RedefineClasses），
同名同签名的方法的 idnum 也保持不变。

### Q3: 为什么要支持类重定义？

**A**: JVMTI 允许调试器/profiler 在运行时替换类的方法实现（如 Hotswap）。
JVM 内部缓存的方法指针必须自动更新，否则会调用到旧代码。

---

## 11. 下一步

LatestMethodCache 完成后，`universe_init()` 还有：
- **13. ResolvedMethodTable** - MethodHandle/反射的方法解析缓存
- **0-2. 前置检查和 JavaClasses**
- **6-8. 性能计数器、AOT、参数约束**
