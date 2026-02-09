# 主题四：类加载机制 — 从 loadClass 到初始化

> 对应文档: `ClassLoading/` 全系列 (9 篇), `Phase6/` 系列
> 面试覆盖: 双亲委派 / 打破双亲委派 / ClassFileParser / 链接初始化 / SystemDictionary / Klass 体系

---

## Q1: 类加载的完整流程是什么？⭐

### 一句话结论
**加载(Loading) → 链接(Linking: 验证+准备+解析) → 初始化(Initialization)**，加载由 ClassLoader 完成，链接和初始化由 JVM 内部驱动。

### 源码级回答

```
┌─────── 加载 (Loading) ──────────────────────────────────────────────────┐
│ ClassLoader.loadClass() → findClass() → defineClass()                   │
│   → JNI: JVM_DefineClassWithSource()                                    │
│     → SystemDictionary::resolve_from_stream()                           │
│       → KlassFactory::create_from_stream()                              │
│         → ClassFileParser 9 阶段解析 .class 文件                         │
│         → 构造 InstanceKlass + 创建 java.lang.Class mirror              │
│       → define_instance_class() 注册到 SystemDictionary                 │
└─────────────────────────────────────────────────────────────────────────┘
                              ↓
┌─────── 链接 (Linking) ──────────────────────────────────────────────────┐
│ InstanceKlass::link_class_impl()                                        │
│   → 验证 (verify_code): 字节码合法性检查                                 │
│   → 准备 (prepare): 为 static 字段分配零值                               │
│   → 解析 (可选): 符号引用 → 直接引用 (通常延迟到首次使用)                 │
│   → 重写 (rewrite_class): 字节码优化重写                                 │
│   → 链接方法 (link_methods): vtable/itable 填充                         │
└─────────────────────────────────────────────────────────────────────────┘
                              ↓
┌─────── 初始化 (Initialization) ─────────────────────────────────────────┐
│ InstanceKlass::initialize_impl()                                        │
│   → 1. 递归初始化父类                                                    │
│   → 2. 执行 <clinit> 方法 (static 初始化块 + static 字段赋值)            │
│   → 3. 设置 _init_state = fully_initialized                            │
│   → 并发安全: ObjectLocker 锁 + init_state 状态机                       │
└─────────────────────────────────────────────────────────────────────────┘
```

**init_state 状态机:**
```
allocated → loaded → linked → being_initialized → fully_initialized
                                     ↓ (异常)
                              initialization_error
```

> 📖 详细文档: `ClassLoading/classloading_complete_flow.md`, `ClassLoading/class_linking_initialization.md`

---

## Q2: 双亲委派模型是什么？源码怎么实现的？⭐

### 一句话结论
加载类时先委托父加载器，父加载器加载不了才自己加载。核心在 `ClassLoader.loadClass()` 的 **parent.loadClass()** 递归调用。

### 源码级回答

```java
// java.lang.ClassLoader.loadClass()
protected Class<?> loadClass(String name, boolean resolve) {
    synchronized (getClassLoadingLock(name)) {
        // 1. 检查是否已加载
        Class<?> c = findLoadedClass(name);

        if (c == null) {
            // 2. 委派父加载器
            if (parent != null) {
                c = parent.loadClass(name, false);  // 递归!
            } else {
                c = findBootstrapClassOrNull(name);  // Bootstrap
            }

            // 3. 父加载器加载失败 → 自己加载
            if (c == null) {
                c = findClass(name);  // 子类重写此方法
            }
        }
        return c;
    }
}
```

**三级类加载器 (JDK 11):**
```
BootstrapClassLoader (C++ 实现, parent=null)
    ↑
PlatformClassLoader (Java, 取代 ExtClassLoader)
    ↑
AppClassLoader (Java, 应用类)
```

**JDK 11 的模块感知委派 (BuiltinClassLoader):**
```java
// BuiltinClassLoader.loadClassOrNull()
// 新增: 先查 packageToModule 映射，看目标类属于哪个模块
Module module = packageToModule.get(packageName);
if (module != null) {
    // 直接委派给模块所属的 ClassLoader（可能跳过双亲委派!）
    return module.getClassLoader().loadClassOrNull(name);
}
// 否则走传统双亲委派
```

> 📖 详细文档: `ClassLoading/ch07_parent_delegation_loadclass.md`

---

## Q3: 怎么打破双亲委派？有哪些实际案例？⭐⭐

### 一句话结论
重写 `loadClass()` 而非 `findClass()`，或使用 **Thread Context ClassLoader (TCCL)** 让父加载器反向委托子加载器。

### 源码级回答

**三种打破方式:**

| 方式 | 代表案例 | 原理 |
|------|---------|------|
| 重写 loadClass() | Tomcat WebAppClassLoader | 先自己加载，失败再委派父 |
| TCCL | SPI (JDBC/JNDI) | Bootstrap 通过 TCCL 加载用户类 |
| OSGi 网状委派 | Eclipse | 每个 Bundle 有自己的 ClassLoader |

**SPI 的困境与 TCCL:**
```
问题: java.sql.DriverManager 由 BootstrapClassLoader 加载
      但 MySQL Driver 在 classpath → 只有 AppClassLoader 能加载
      Bootstrap 看不到 AppClassLoader 的类!

解法: TCCL
    DriverManager.getConnection() {
        ClassLoader cl = Thread.currentThread().getContextClassLoader();
        // cl 是 AppClassLoader
        ServiceLoader.load(Driver.class, cl);
        // 用 AppClassLoader 加载 MySQL Driver
    }
```

**Tomcat 的委派模型:**
```
         Bootstrap
             ↑
          System
             ↑
         Common
        ↗      ↖
  Webapp1    Webapp2   ← 每个 Web 应用独立，先自己加载!
```
- WebAppClassLoader 重写 `loadClass()`：先自己的 `/WEB-INF/classes` → 再委派父

> 📖 详细文档: `ClassLoading/ch07_parent_delegation_loadclass.md`

---

## Q4: ClassFileParser 解析 .class 文件的流程？⭐⭐⭐

### 一句话结论
ClassFileParser 构造函数内完成**9 阶段解析**：魔数 → 版本 → 常量池 → 访问标志 → 类/父类 → 接口 → 字段 → 方法 → 属性，然后 `create_instance_klass()` 在 Metaspace 分配 InstanceKlass。

### 源码级回答

```
ClassFileParser 构造函数 9 阶段:
│
├── 1. 魔数验证 (0xCAFEBABE)
├── 2. 版本号 (major/minor version)
├── 3. 常量池 (parse_constant_pool)
│       → 构建 ConstantPool 对象
│       → 解析 UTF8/Integer/Float/Class/Method/Field/String/...
├── 4. 访问标志 (ACC_PUBLIC, ACC_FINAL, ...)
├── 5. this_class / super_class 解析
├── 6. 接口列表 (parse_interfaces)
├── 7. 字段 (parse_fields)
│       → 字段排序: static 先于 instance
│       → 计算字段偏移和对象大小
├── 8. 方法 (parse_methods)
│       → 每个方法 → Method + ConstMethod
│       → Code 属性 → bytecode 复制
│       → 异常表/行号表/局部变量表
└── 9. 属性 (InnerClasses, SourceFile, BootstrapMethods, ...)

post_process_parsed_stream():
  → 递归加载父类 (触发新的 resolve_or_null)
  → 加载接口

create_instance_klass():
  → Metaspace 分配 InstanceKlass
  → 填充 vtable/itable 布局
  → create_mirror() 创建 java.lang.Class 对象
```

> 📖 详细文档: `ClassLoading/classfile_parser.md`

---

## Q5: SystemDictionary 是什么？类是怎么注册的？⭐⭐⭐

### 一句话结论
SystemDictionary 是 JVM 的**全局类注册表**，底层是哈希表，key = `(类名 Symbol, ClassLoader)`，value = `InstanceKlass*`，确保同一个 ClassLoader 下同名类只有一份。

### 源码级回答

**核心方法:**
```cpp
// 查找
Klass* SystemDictionary::resolve_or_null(Symbol* class_name,
                                         Handle class_loader, TRAPS) {
    // 1. 先查 Dictionary 缓存
    Klass* k = find(class_name, class_loader);
    if (k != NULL) return k;  // 84% 命中率 (GDB 实测)

    // 2. 缓存未命中 → 加载
    // Bootstrap: resolve_instance_class_or_null() → load_class
    // App: call Java ClassLoader.loadClass()
}

// 注册
void SystemDictionary::define_instance_class(InstanceKlass* k, TRAPS) {
    // check_constraints: 验证不同 ClassLoader 定义同名类的约束
    // update_dictionary: 注册到 Dictionary 哈希表
    // add_to_hierarchy: 加入 Klass 继承链
}
```

**并行控制 (PlaceholderTable):**
```
问题: 多个线程同时加载同一个类 → 重复加载
解法: PlaceholderTable 令牌机制
  Thread A: 放入 placeholder → 加载 → 注册到 Dictionary → 移除 placeholder
  Thread B: 发现 placeholder → 等待 Thread A 完成 → 从 Dictionary 取
```

**关键数据 (GDB 验证):**
- HelloWorld 启动: 5155 次 `resolve_or_null`，816 次 `create_from_stream`
- Dictionary 缓存命中率: ~84%

> 📖 详细文档: `ClassLoading/system_dictionary_deep_dive.md`, `ClassLoading/ch09_classloading_interview_gdb.md`

---

## Q6: Klass 体系有哪些类？InstanceKlass 有多大？⭐⭐⭐

### 一句话结论
Klass 体系: `Klass` → `InstanceKlass`/`ArrayKlass` → `InstanceMirrorKlass`/`ObjArrayKlass`/`TypeArrayKlass`。一个 InstanceKlass 至少 **472 字节** (GDB 实测)。

### 源码级回答

```
                    ┌─── Klass (208 bytes) ───┐
                    │                          │
          ┌─────────┴──────────┐     ┌────────┴────────┐
    InstanceKlass (472B)    ArrayKlass (232B)           │
          │                    │                        │
    ┌─────┴──────┐      ┌─────┴──────┐           Klass
    │            │      │            │           (基类)
InstanceMirror  InstanceRef  ObjArray  TypeArray
Klass          Klass       Klass     Klass
(java.lang.   (java.lang.  (Object[] (int[] 等)
 Class)        ref.Ref)     等)
```

**InstanceKlass 关键字段:**
```cpp
class InstanceKlass : public Klass {
    // Klass 继承的 (208 bytes):
    //   _name, _layout_helper, _super, _subklass, _next_sibling,
    //   _java_mirror, _access_flags, _vtable_len, _class_loader_data, ...

    // InstanceKlass 新增 (~264 bytes):
    Array<Method*>*    _methods;           // 方法数组
    Array<InstanceKlass*>* _local_interfaces; // 直接实现的接口
    ConstantPool*      _constants;         // 常量池
    Array<u2>*         _fields;            // 字段描述
    u2                 _java_fields_count; // Java 字段数
    ClassState         _init_state;        // 初始化状态
    u1                 _reference_type;    // 引用类型 (Strong/Soft/Weak/...)
    OopMapBlock*       _nonstatic_oop_map; // GC 需要的 oop 偏移表
    // ... 还有 vtable, itable 紧跟在对象末尾
};
```

**sizeof 对比 (GDB 验证):**
| 类型 | sizeof |
|------|--------|
| Klass | 208 bytes |
| InstanceKlass | 472 bytes |
| ArrayKlass | 232 bytes |
| ObjArrayKlass | 248 bytes |
| TypeArrayKlass | 240 bytes |
| ClassLoaderData | 168 bytes |

> 📖 详细文档: `ClassLoading/klass_hierarchy.md`, `ClassLoading/ch09_classloading_interview_gdb.md`

---

## Q7: 类的初始化 `<clinit>` 是怎么保证线程安全的？⭐⭐

### 一句话结论
通过 `InstanceKlass` 的 `_init_lock`（ObjectLocker）和 `_init_state` 状态机实现：**只有一个线程能执行 `<clinit>`，其他线程阻塞等待**。

### 源码级回答

```cpp
void InstanceKlass::initialize_impl(TRAPS) {
    ObjectLocker ol(init_lock(), THREAD);  // 加锁!

    // 1. 已经初始化? → 返回
    if (_init_state == fully_initialized) return;

    // 2. 正在被当前线程初始化? → 递归调用, 直接返回
    if (_init_state == being_initialized && _init_thread == Self) return;

    // 3. 正在被其他线程初始化? → 等待
    while (_init_state == being_initialized && _init_thread != Self) {
        ol.waitUninterruptibly(CHECK);  // 释放锁 + wait
    }

    // 4. 初始化出错? → 抛 NoClassDefFoundError
    if (_init_state == initialization_error) {
        THROW(vmSymbols::java_lang_NoClassDefFoundError());
    }

    // 5. 开始初始化
    _init_state = being_initialized;
    _init_thread = Self;
    ol.unlock();  // 释放锁!

    // 6. 递归初始化父类
    super()->initialize(CHECK);

    // 7. 执行 <clinit>
    call_class_initializer(CHECK);

    // 8. 完成
    ol.lock();
    _init_state = fully_initialized;
    ol.notifyAll();  // 唤醒所有等待的线程
}
```

> 📖 详细文档: `ClassLoading/class_linking_initialization.md`

---

## Q8: defineClass 从 Java 到 JVM 经历了什么？⭐⭐⭐

### 一句话结论
`ClassLoader.defineClass()` → 安全检查 → JNI `defineClass1` → malloc 复制字节码 → `SystemDictionary::resolve_from_stream()` → ClassFileParser → InstanceKlass → 注册到 Dictionary。

### 源码级回答

```
Java 层: ClassLoader.defineClass(name, byte[], off, len)
  → preDefineClass() 安全检查:
    ├── 类名不能以 "java." 开头 (SecurityManager)
    ├── 检查 signing certificate 一致性
    └── 包不能跨 ClassLoader 定义

JNI 层: ClassLoader.c → defineClass1()
  → malloc(len) 复制 byte[] 到 native 内存
  → 为什么复制? byte[] 可能被 GC 移动!
  → jvm_define_class_common()

HotSpot 层:
  → SystemDictionary::resolve_from_stream()
    → 并行 ClassLoader: find_or_define_instance_class()
      → PlaceholderTable 令牌机制防止重复定义
    → 非并行: resolve_from_stream() 持 SystemDictionary_lock
    → KlassFactory::create_from_stream()
      → JVMTI ClassFileLoadHook 事件 (Agent 可修改字节码!)
      → ClassFileParser 9 阶段解析
      → create_instance_klass()
      → fill_instance_klass()
    → define_instance_class()
      → check_constraints()
      → update_dictionary()
```

> 📖 详细文档: `ClassLoading/ch08_defineclass_jni_bridge.md`

---

## Q9: 一个 HelloWorld 程序会加载多少个类？⭐⭐

### 一句话结论
GDB 实测: **816 个类** 被 `create_from_stream` 创建，但 `resolve_or_null` 被调用 **5155 次**（大量走 Dictionary 缓存命中）。

### 源码级回答

**关键统计 (GDB 验证):**
```
resolve_or_null:     5155 次 (入口查找)
create_from_stream:   816 次 (实际解析 .class)
update_dictionary:    754 次 (注册到字典)
find_or_define:       750 次 (AppClassLoader 路径)
JVM_DefineClassWithSource: 1 次 (只有 com.wjcoder.Main 走此路径!)
```

**why 816 个类?**
- JDK 核心类: ~700+ (java.lang.*, java.util.*, java.io.*, ...)
- 内部模块类: ~100+ (jdk.internal.*, sun.*, ...)
- 用户类: 1 (com.wjcoder.Main)

**Dictionary 缓存命中率:** (5155 - 816) / 5155 ≈ **84%**

**Metaspace 消耗:** 816 类 × ~3KB ≈ **2.5MB**

> 📖 详细文档: `ClassLoading/ch09_classloading_interview_gdb.md`

---

## Q10: Class.forName() 和 ClassLoader.loadClass() 有什么区别？⭐

### 一句话结论
`Class.forName()` 默认**触发初始化** (执行 `<clinit>`)，`ClassLoader.loadClass()` **只加载不初始化**。

### 源码级回答

```java
// Class.forName() — 默认 initialize=true
Class.forName("com.example.Foo");
  → native forName0(name, true, callerClassLoader)
    → JVM: Klass* k = SystemDictionary::resolve_or_fail()
    → k->initialize()  // 触发 <clinit>!

// ClassLoader.loadClass() — 只加载
classLoader.loadClass("com.example.Foo");
  → 双亲委派查找/加载
  → 不调用 initialize()
  → 要初始化需要: Class.forName(name, true, classLoader)
```

**使用场景:**
| 方法 | 初始化 | 典型场景 |
|------|--------|---------|
| Class.forName(name) | ✅ 是 | JDBC `Class.forName("com.mysql.Driver")` |
| classLoader.loadClass(name) | ❌ 否 | 框架延迟加载 |
| Class.forName(name, false, cl) | ❌ 否 | 显式控制 |

> 📖 详细文档: `ClassLoading/ch07_parent_delegation_loadclass.md`

---

## 🎯 面试话术建议

### 如何展示类加载的源码功底:

> "我在 GDB 上跟过一个 HelloWorld 的完整类加载链路。resolve_or_null 被调用了 5155 次，但实际 create_from_stream 只有 816 次——84% 走了 Dictionary 缓存命中。Bootstrap 类走 C++ 路径 resolve_instance_class_or_null，App 类走 Java 的 ClassLoader.loadClass，最终都汇合到 KlassFactory::create_from_stream。"

> "defineClass 的 JNI 层有个细节：它会先 malloc 把 byte[] 复制到 native 内存，因为后续 ClassFileParser 解析过程中可能触发 GC，如果直接用 Java 数组的指针，GC 移动对象后指针就野了。"

> "类的初始化线程安全靠 InstanceKlass 的 ObjectLocker + init_state 状态机。being_initialized 状态带 init_thread 字段，支持递归初始化（A 初始化时引用 B，B 的 clinit 又引用 A）。其他线程看到 being_initialized 就 wait，直到 notifyAll。"
