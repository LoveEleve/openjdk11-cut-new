# 双亲委派 loadClass 完整链路 — 从 Class.forName 到 InstanceKlass

> **目标**: 完整追踪 Java 层类加载的 loadClass 调用链，深入分析双亲委派模型的源码实现、并行加载锁机制、findLoadedClass/defineClass 的 JNI 穿越，以及打破双亲委派的经典案例
> **源码**: `ClassLoader.java`, `BuiltinClassLoader.java`, `Class.java`, `ServiceLoader.java`, `jvm.cpp`
> **标准环境**: `-Xms8g -Xmx8g -XX:+UseG1GC`
> **前置知识**: [ch06_classloader_hierarchy.md](ch06_classloader_hierarchy.md) (三级类加载器体系)
> **本篇定位**: 类加载系统 4 篇系列的第 2 篇——聚焦"怎么加载"

---

## 一句话总结

Java 层类加载有两条并行的 `loadClass` 实现：`ClassLoader.loadClass()`（传统双亲委派，给自定义 ClassLoader 使用）和 `BuiltinClassLoader.loadClassOrNull()`（模块感知委派，给三个内建 ClassLoader 使用）。两者都遵循"先查缓存（`findLoadedClass` → `JVM_FindLoadedClass` → `SystemDictionary::find`）→ 委托 parent → 自己加载（`findClass` → `defineClass` → `JVM_DefineClassWithSource` → `SystemDictionary::resolve_from_stream`）"的骨架，但模块感知版本增加了 `packageToModule` 快捷路径，可以跨层级直接委托。打破双亲委派的经典手法是**线程上下文类加载器（TCCL）**——让 Bootstrap 加载的 SPI 接口能找到 AppClassLoader 加载的实现类。

---

## 1. 类加载的三个入口

Java 代码触发类加载有三个主要入口：

### 1.1 Class.forName() — 显式加载

```java
// Class.java:312
public static Class<?> forName(String className) throws ClassNotFoundException {
    Class<?> caller = Reflection.getCallerClass();
    return forName0(className, true, ClassLoader.getClassLoader(caller), caller);
    //                         ^^^^  initialize=true → 加载后立即初始化
    //                               ^^^^^^^^^^^^^^^^ 使用调用者的 ClassLoader
}

// 三参数版本
public static Class<?> forName(String name, boolean initialize, ClassLoader loader) {
    // ... 安全检查 ...
    return forName0(name, initialize, loader, caller);
}

// ★ 最终走 native
private static native Class<?> forName0(String name, boolean initialize,
                                        ClassLoader loader, Class<?> caller);
// → JVM_FindClassFromCaller (jvm.cpp)
// → SystemDictionary::resolve_or_fail(class_name, class_loader, ...)
// → 如果 loader != null，会回调 Java 层的 ClassLoader.loadClass()
```

**关键点**: `Class.forName("X")` 默认 `initialize=true`，会触发类的 `<clinit>` 初始化。

### 1.2 ClassLoader.loadClass() — 双亲委派入口

```java
// ClassLoader.java:522
public Class<?> loadClass(String name) throws ClassNotFoundException {
    return loadClass(name, false);
    //                     ^^^^^ resolve=false → 不链接
}
```

### 1.3 字节码隐式加载

```java
new Foo();                    // new 指令 → 需要加载 Foo
Foo.staticField;              // getstatic → 需要加载 Foo
Foo.staticMethod();           // invokestatic → 需要加载 Foo
obj instanceof Foo;           // instanceof → 需要加载 Foo
(Foo) obj;                    // checkcast → 需要加载 Foo
```

字节码隐式加载由 JVM 内部的常量池解析触发，最终走 `SystemDictionary::resolve_or_fail()`，如果有非 null 的 ClassLoader 则回调 Java 层 `loadClass()`。

---

## 2. ClassLoader.loadClass() — 传统双亲委派的完整源码

这是自定义 ClassLoader 所走的标准路径：

```java
// ClassLoader.java:566 — 传统双亲委派核心实现
protected Class<?> loadClass(String name, boolean resolve)
    throws ClassNotFoundException
{
    // ① 获取类加载锁（parallel capable 用 per-name 锁，否则用 this）
    synchronized (getClassLoadingLock(name)) {

        // ② 检查缓存：这个 ClassLoader 是否已经加载过这个类？
        Class<?> c = findLoadedClass(name);

        if (c == null) {
            long t0 = System.nanoTime();
            try {
                // ③ 双亲委派：优先让 parent 加载
                if (parent != null) {
                    c = parent.loadClass(name, false);
                } else {
                    // parent == null → 到达 Bootstrap Loader
                    c = findBootstrapClassOrNull(name);
                }
            } catch (ClassNotFoundException e) {
                // parent 找不到 → 不抛异常，继续
            }

            // ④ parent 找不到 → 自己加载
            if (c == null) {
                long t1 = System.nanoTime();
                c = findClass(name);  // ★ 子类必须重写此方法

                // 性能统计
                PerfCounter.getParentDelegationTime().addTime(t1 - t0);
                PerfCounter.getFindClassTime().addElapsedTimeFrom(t1);
                PerfCounter.getFindClasses().increment();
            }
        }

        // ⑤ 可选：链接类（解析符号引用）
        if (resolve) {
            resolveClass(c);
        }
        return c;
    }
}
```

### 2.1 执行流程图

```
ClassLoader.loadClass("com.example.Foo")
│
├─① getClassLoadingLock("com.example.Foo")
│   ├── parallelLockMap != null → 从 map 获取/创建 per-name 锁
│   └── parallelLockMap == null → 锁 this（整个 ClassLoader）
│
├─② findLoadedClass("com.example.Foo")
│   └── checkName → findLoadedClass0 [native]
│       └── JVM_FindLoadedClass
│           └── SystemDictionary::find_instance_or_array_klass(name, loader, ...)
│               └── 在 Dictionary 中查找 (loader, name) 键值对
│               └── 如果 CDS: SystemDictionaryShared::find_or_load_shared_class
│           └── 找到 → 返回 Class 镜像对象
│           └── 找不到 → 返回 null
│
├─③ parent.loadClass("com.example.Foo", false)
│   └── [递归] parent 的 loadClass
│       └── parent 的 parent 的 loadClass ...
│           └── 最终: parent == null
│               └── findBootstrapClassOrNull("com.example.Foo")
│                   └── findBootstrapClass [native]
│                       └── JVM_FindClassFromBootLoader
│                           └── SystemDictionary::resolve_or_null(name, NULL, ...)
│                           └── Bootstrap 类 → 返回 Class
│                           └── 非 Bootstrap 类 → 返回 null
│
├─④ c == null → findClass("com.example.Foo")
│   └── [子类实现] 从 URL/文件/网络等获取字节码
│       └── defineClass(name, bytes, 0, len, pd)
│           └── preDefineClass: 安全检查
│               ├── checkName: 类名合法性
│               ├── 禁止非平台 loader 定义 java.* 类
│               └── checkCerts: 证书一致性
│           └── defineClass1 [native]
│               └── JVM_DefineClassWithSource
│                   └── jvm_define_class_common
│                       └── ClassFileStream(buf, len, source)
│                       └── SystemDictionary::resolve_from_stream(name, loader, pd, &st)
│                           └── ClassFileParser → InstanceKlass
│                       └── 返回 Class 镜像对象
│           └── postDefineClass: 定义包、设置签名者
│
└─⑤ resolve == true → resolveClass(c) [native]
    └── JVM_ResolveClass（JDK 11 中实际是 no-op）
```

### 2.2 每一步的深入分析

#### ② findLoadedClass — SystemDictionary 查找

```java
// ClassLoader.java:1278
protected final Class<?> findLoadedClass(String name) {
    if (!checkName(name))
        return null;
    return findLoadedClass0(name);  // [native]
}
```

C++ 层 `JVM_FindLoadedClass`：

```cpp
// jvm.cpp:968
JVM_ENTRY(jclass, JVM_FindLoadedClass(JNIEnv *env, jobject loader, jstring name))
    // ... 类名转 Symbol ...
    Klass *k = SystemDictionary::find_instance_or_array_klass(klass_name,
                                                              h_loader,
                                                              Handle(),
                                                              CHECK_NULL);
    #if INCLUDE_CDS
    if (k == NULL) {
        // ★ 如果没找到，尝试从 CDS 共享存档中加载
        k = SystemDictionaryShared::find_or_load_shared_class(klass_name, h_loader, CHECK_NULL);
    }
    #endif
    return (k == NULL) ? NULL :
           (jclass) JNIHandles::make_local(env, k->java_mirror());
JVM_END
```

**关键**: `findLoadedClass` 只查 SystemDictionary 缓存，**不触发类加载**。如果类没被加载过，直接返回 null。

#### ③ 双亲委派递归

```
加载 "com.example.Foo" 的委派链:

AppClassLoader.loadClass("com.example.Foo")
  ├── findLoadedClass → null
  ├── parent = PlatformClassLoader
  │   PlatformClassLoader.loadClass("com.example.Foo")
  │     ├── findLoadedClass → null
  │     ├── parent = null (BootClassLoader 映射为 null)
  │     │   findBootstrapClassOrNull("com.example.Foo")
  │     │     └── JVM_FindClassFromBootLoader → null (不是核心类)
  │     ├── findClass("com.example.Foo") → ClassNotFoundException
  │     └── 抛 ClassNotFoundException
  ├── catch ClassNotFoundException → 继续
  ├── c == null → findClass("com.example.Foo")
  │   └── [AppClassLoader] 从 classpath 搜索
  │       └── URLClassPath.getResource("com/example/Foo.class")
  │           → 找到 → defineClass(...)
  └── 返回 com.example.Foo

加载 "java.lang.String" 的委派链:

AppClassLoader.loadClass("java.lang.String")
  ├── findLoadedClass → 命中! (已被 BootLoader 加载过)
  └── 直接返回 java.lang.String
```

#### ④ defineClass — 字节码 → Class 对象

```java
// ClassLoader.java:1012
protected final Class<?> defineClass(String name, byte[] b, int off, int len,
                                     ProtectionDomain protectionDomain)
{
    // 安全前置检查
    protectionDomain = preDefineClass(name, protectionDomain);
    //  ├── checkName(name): 类名不能包含 '/' 或 ';'
    //  ├── java.* 包只能由 PlatformClassLoader 或 BootLoader 定义
    //  └── checkCerts: 同包类必须用相同证书签名

    // 获取代码源位置
    String source = defineClassSourceLocation(protectionDomain);

    // ★ 调用 native 方法创建 Class 对象
    Class<?> c = defineClass1(this, name, b, off, len, protectionDomain, source);
    // → JVM_DefineClassWithSource
    //   → jvm_define_class_common
    //     → SystemDictionary::resolve_from_stream(class_name, class_loader, pd, &st)
    //       → ClassFileParser::parse_stream → InstanceKlass
    //     → 返回 Class mirror

    // 后置处理
    postDefineClass(c, protectionDomain);
    //  ├── getNamedPackage: 定义包
    //  └── setSigners: 设置签名者

    return c;
}

// native 方法声明
static native Class<?> defineClass1(ClassLoader loader, String name, byte[] b, int off, int len,
                                    ProtectionDomain pd, String source);

static native Class<?> defineClass2(ClassLoader loader, String name, java.nio.ByteBuffer b,
                                    int off, int len, ProtectionDomain pd, String source);
```

C++ 层 `jvm_define_class_common`：

```cpp
// jvm.cpp:897
static jclass jvm_define_class_common(JNIEnv *env, const char *name,
                                      jobject loader, const jbyte *buf,
                                      jsize len, jobject pd,
                                      const char *source, TRAPS) {
    // ... 类名转 Symbol ...

    // ★ 核心：将字节码流解析为 InstanceKlass，注册到 SystemDictionary
    ClassFileStream st((u1 *) buf, len, source, ClassFileStream::verify);
    Handle class_loader(THREAD, JNIHandles::resolve(loader));
    Handle protection_domain(THREAD, JNIHandles::resolve(pd));

    Klass *k = SystemDictionary::resolve_from_stream(class_name,
                                                     class_loader,
                                                     protection_domain,
                                                     &st,
                                                     CHECK_NULL);
    return (jclass) JNIHandles::make_local(env, k->java_mirror());
}
```

**关键路径**: `defineClass1` → `JVM_DefineClassWithSource` → `jvm_define_class_common` → `SystemDictionary::resolve_from_stream` → `ClassFileParser::parse_stream` → `InstanceKlass` 创建。

---

## 3. BuiltinClassLoader.loadClassOrNull() — 模块感知委派

三个内建 ClassLoader（Boot/Platform/App）**不走** `ClassLoader.loadClass()`，而是走 `BuiltinClassLoader.loadClassOrNull()`：

```java
// BuiltinClassLoader.java:576
@Override
protected Class<?> loadClass(String cn, boolean resolve) throws ClassNotFoundException {
    Class<?> c = loadClassOrNull(cn, resolve);
    if (c == null)
        throw new ClassNotFoundException(cn);
    return c;
}

// 真正的实现
protected Class<?> loadClassOrNull(String cn, boolean resolve) {
    synchronized (getClassLoadingLock(cn)) {
        // ① 检查缓存
        Class<?> c = findLoadedClass(cn);

        if (c == null) {
            // ② 查模块映射表：这个类的包属于哪个模块？
            LoadedModule loadedModule = findLoadedModule(cn);

            if (loadedModule != null) {
                // ★ 路径 A: 模块路径
                BuiltinClassLoader loader = loadedModule.loader();
                if (loader == this) {
                    if (VM.isModuleSystemInited()) {
                        c = findClassInModuleOrNull(loadedModule, cn);
                    }
                } else {
                    c = loader.loadClassOrNull(cn);  // 跨级委托
                }
            } else {
                // ★ 路径 B: 传统双亲委派
                if (parent != null) {
                    c = parent.loadClassOrNull(cn);
                }
                if (c == null && hasClassPath() && VM.isModuleSystemInited()) {
                    c = findClassOnClassPathOrNull(cn);
                }
            }
        }

        if (resolve && c != null)
            resolveClass(c);
        return c;
    }
}
```

### 3.1 两条路径对比（详细版）

```
路径 A: 模块感知路径（加载 java.sql.Connection）
══════════════════════════════════════════════════════════════════
AppClassLoader.loadClassOrNull("java.sql.Connection")
  │
  ├─ findLoadedClass → null
  ├─ findLoadedModule("java.sql.Connection")
  │   └─ packageToModule.get("java.sql")
  │      → LoadedModule{loader=PlatformClassLoader, mref=java.sql}
  │
  ├─ loader = PlatformClassLoader ≠ this(AppClassLoader)
  │   └─ PlatformClassLoader.loadClassOrNull("java.sql.Connection")
  │       ├─ findLoadedClass → null
  │       ├─ findLoadedModule("java.sql.Connection")
  │       │   → LoadedModule{loader=PlatformClassLoader, mref=java.sql}
  │       ├─ loader == this → findClassInModuleOrNull(...)
  │       │   └─ defineClass("java.sql.Connection", loadedModule)
  │       │       └─ ModuleReader.read("java/sql/Connection.class")
  │       │       └─ defineClass(cn, byteBuffer, codeSource)
  │       │           └─ defineClass1 [native]
  │       └─ 返回 java.sql.Connection

路径 B: 传统双亲委派（加载 com.wjcoder.Main）
══════════════════════════════════════════════════════════════════
AppClassLoader.loadClassOrNull("com.wjcoder.Main")
  │
  ├─ findLoadedClass → null
  ├─ findLoadedModule("com.wjcoder.Main")
  │   └─ packageToModule.get("com.wjcoder") → null
  │      // 不在任何模块中
  │
  ├─ parent != null → PlatformClassLoader.loadClassOrNull(...)
  │   ├─ findLoadedClass → null
  │   ├─ findLoadedModule → null
  │   ├─ parent != null → BootClassLoader.loadClassOrNull(...)
  │   │   └─ JLA.findBootstrapClassOrNull(this, "com.wjcoder.Main")
  │   │       └─ JVM_FindClassFromBootLoader → null (不是核心类)
  │   ├─ hasClassPath() → false (PlatformClassLoader 无 classpath)
  │   └─ 返回 null
  │
  ├─ c == null && hasClassPath() → true (AppClassLoader 有 classpath)
  │   └─ findClassOnClassPathOrNull("com.wjcoder.Main")
  │       └─ ucp.getResource("com/wjcoder/Main.class")
  │           → Resource{url=file:/data/workspace/demo/src/}
  │       └─ defineClass("com.wjcoder.Main", resource)
  │           ├─ defineOrCheckPackage("com.wjcoder", ...)
  │           └─ defineClass(cn, bytes, codeSource)
  │               └─ defineClass1 [native]
  │                   └─ JVM_DefineClassWithSource
  │
  └─ 返回 com.wjcoder.Main
```

### 3.2 findLoadedModule — O(1) 包名查找

```java
// BuiltinClassLoader.java:653
private LoadedModule findLoadedModule(String cn) {
    int pos = cn.lastIndexOf('.');
    if (pos < 0)
        return null;  // 默认包 → 不在任何模块中
    String pn = cn.substring(0, pos);   // "java.sql.Connection" → "java.sql"
    return packageToModule.get(pn);     // ConcurrentHashMap O(1) 查找
}
```

**注意**: 这个方法只做包名截取和 HashMap 查找，没有任何 I/O 操作——非常快。

### 3.3 findClassInModuleOrNull — 从模块中加载

```java
// BuiltinClassLoader.java:665
private Class<?> findClassInModuleOrNull(LoadedModule loadedModule, String cn) {
    if (System.getSecurityManager() == null) {
        return defineClass(cn, loadedModule);  // 直接加载
    } else {
        PrivilegedAction<Class<?>> pa = () -> defineClass(cn, loadedModule);
        return AccessController.doPrivileged(pa);  // 特权加载
    }
}
```

### 3.4 findClassOnClassPathOrNull — 从 classpath 加载

```java
// BuiltinClassLoader.java:682
private Class<?> findClassOnClassPathOrNull(String cn) {
    String path = cn.replace('.', '/').concat(".class");
    // "com.wjcoder.Main" → "com/wjcoder/Main.class"

    Resource res = ucp.getResource(path, false);
    // URLClassPath 搜索 classpath 中的每个目录/JAR

    if (res != null) {
        return defineClass(cn, res);
        //  ├── defineOrCheckPackage: 定义/验证包
        //  ├── res.getByteBuffer() / res.getBytes(): 读取字节码
        //  └── defineClass(cn, bytes, codeSource): 调用 ClassLoader.defineClass
    }
    return null;
}
```

---

## 4. GDB 验证：一次完整的类加载追踪

### 4.1 验证结果

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC -Xint
┌──────────────────────────────────────────────────────────────────────────┐
│ 断点: JVM_DefineClassWithSource + JVM_FindClassFromBootLoader           │
│                                                                          │
│ 整个 JVM 启动 + 运行 com.wjcoder.Main 过程中:                           │
│                                                                          │
│ JVM_FindClassFromBootLoader: 被调用 100+ 次                             │
│   → 所有 JDK 核心类（java.lang.*, java.util.*, etc.）                   │
│   → 全部通过 Bootstrap Loader 加载（loader=NULL）                        │
│                                                                          │
│ JVM_DefineClassWithSource: 仅被调用 1 次                                │
│   → com/wjcoder/Main  source=file:/data/workspace/demo/src/             │
│   → 由 AppClassLoader 通过 findClassOnClassPathOrNull 触发              │
│                                                                          │
│ ★ 观察: JDK 核心类走 resolve_or_null（Boot Loader），                   │
│         用户类走 JVM_DefineClassWithSource（App Loader defineClass）     │
│         两条路径在 C++ 层最终都汇入 SystemDictionary                     │
└──────────────────────────────────────────────────────────────────────────┘
```

### 4.2 GDB 调试命令（可复现）

```bash
# 验证脚本位置: jvm-md/ClassLoading/gdb_loadclass_chain.txt
gdb -batch -x jvm-md/ClassLoading/gdb_loadclass_chain.txt \
    --args ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
    -XX:+UseG1GC -Xms8g -Xmx8g -Xint -cp /data/workspace/demo/src com.wjcoder.Main
```

---

## 5. 并行加载锁 — getClassLoadingLock 深入

### 5.1 核心实现

```java
// ClassLoader.java:660
protected Object getClassLoadingLock(String className) {
    Object lock = this;  // 默认：锁整个 ClassLoader
    if (parallelLockMap != null) {
        // Parallel capable → per-class-name 锁
        Object newLock = new Object();
        lock = parallelLockMap.putIfAbsent(className, newLock);
        if (lock == null) {
            lock = newLock;  // 首次 → 用新创建的锁
        }
        // 已有 → 用已存在的锁
    }
    return lock;
}
```

### 5.2 性能影响对比

```
非 Parallel Capable（锁 this）:
══════════════════════════════
Thread-1: loadClass("Foo") → synchronized(classLoader) → 加载中...
Thread-2: loadClass("Bar") → synchronized(classLoader) → ⏳ 等待!
Thread-3: loadClass("Baz") → synchronized(classLoader) → ⏳ 等待!
// 所有线程串行等待，即使加载不同的类

Parallel Capable（per-name 锁）:
══════════════════════════════
Thread-1: loadClass("Foo") → synchronized(lock_Foo) → 加载中...
Thread-2: loadClass("Bar") → synchronized(lock_Bar) → 加载中... ✅ 并行!
Thread-3: loadClass("Baz") → synchronized(lock_Baz) → 加载中... ✅ 并行!
Thread-4: loadClass("Foo") → synchronized(lock_Foo) → ⏳ 等待 Thread-1
// 只有加载相同类的线程才串行等待
```

### 5.3 死锁场景与解决

```
传统锁的死锁场景:
  ClassLoader A (locked) → 需要 ClassLoader B 加载某类
  ClassLoader B (locked) → 需要 ClassLoader A 加载某类
  → 死锁!

Parallel capable 的解决:
  ClassLoader A: lock("X") → 需要 ClassLoader B 加载 "Y"
  ClassLoader B: lock("Y") → 需要 ClassLoader A 加载 "X"
  → 不死锁! 因为 lock("X") 和 lock("Y") 是不同的锁对象
```

### 5.4 parallelLockMap 的 VM 使用

```java
// ClassLoader.java:242
// Note: VM also uses this field to decide if the current class loader
// is parallel capable and the appropriate lock object for class loading.
private final ConcurrentHashMap<String, Object> parallelLockMap;
```

JVM C++ 层在解析常量池引用时（`resolve_from_constant_pool`），会直接读取 ClassLoader 对象的 `parallelLockMap` 字段来决定用什么锁。**这个字段的偏移量被 VM 硬编码**。

---

## 6. findLoadedClass 与 defineClass 的 JNI 穿越详解

### 6.1 findLoadedClass0 → JVM_FindLoadedClass

```
Java 层                          C++ 层
─────────                        ─────────
findLoadedClass(name)
  │ checkName(name)              
  └── findLoadedClass0(name)     
      └── [JNI]                  JVM_FindLoadedClass(env, loader, name)
                                   │
                                   ├── name → Symbol*
                                   │
                                   ├── SystemDictionary::find_instance_or_array_klass
                                   │   (klass_name, h_loader, Handle())
                                   │   └── Dictionary::find(class_name, loader_data)
                                   │       └── 哈希表查找 → Klass* 或 null
                                   │
                                   ├── [CDS] 如果 null:
                                   │   SystemDictionaryShared::find_or_load_shared_class
                                   │   └── 从共享存档加载
                                   │
                                   └── k != null ? k->java_mirror() : null
```

**注意 `find` vs `resolve` 的区别**：
- `find`: 只在 Dictionary 中查找，不触发加载
- `resolve`: 查找 + 如果没找到则触发加载

### 6.2 defineClass1 → JVM_DefineClassWithSource

```
Java 层                          C++ 层
─────────                        ─────────
defineClass(name, b, off, len, pd)
  │ preDefineClass(name, pd)     
  │   ├── checkName             
  │   ├── 禁止非平台 loader 定义 java.*
  │   └── checkCerts            
  │
  │ source = defineClassSourceLocation(pd)
  │
  └── defineClass1(loader, name, b, off, len, pd, source)
      └── [JNI]                  JVM_DefineClassWithSource(env, name, loader, buf, len, pd, source)
                                   │
                                   └── jvm_define_class_common(...)
                                       │
                                       ├── name → Symbol*  (类名)
                                       ├── ClassFileStream st(buf, len, source)  (字节码流)
                                       ├── Handle class_loader(loader)
                                       ├── Handle protection_domain(pd)
                                       │
                                       └── SystemDictionary::resolve_from_stream
                                           (class_name, class_loader, protection_domain, &st)
                                           │
                                           ├── ClassFileParser::parse_stream(stream, ...)
                                           │   └── 解析 .class 文件 → InstanceKlass*
                                           │       (详见 classfile_parser.md)
                                           │
                                           ├── SystemDictionary::define_instance_class(k, loader)
                                           │   └── Dictionary::add_klass(name, loader_data, k)
                                           │       └── 注册到哈希表
                                           │
                                           └── 返回 InstanceKlass*
                                               → java_mirror() → jclass

  │ postDefineClass(c, pd)       
  │   ├── getNamedPackage        
  │   └── setSigners            
  └── 返回 Class<?>
```

### 6.3 java.* 包保护

```java
// ClassLoader.java:898 — preDefineClass
if ((name != null) && name.startsWith("java.")
        && this != getBuiltinPlatformClassLoader()) {
    throw new SecurityException
        ("Prohibited package name: " +
         name.substring(0, name.lastIndexOf('.')));
}
```

**任何自定义 ClassLoader 都不能定义 `java.*` 包下的类**——只有 PlatformClassLoader 及其祖先（BootClassLoader）可以。这是 Java 安全模型的基石。

---

## 7. Thread Context ClassLoader（TCCL）— 打破双亲委派

### 7.1 问题：SPI 的困境

```
Java 的 SPI（Service Provider Interface）模式:

java.sql.DriverManager (在 java.base 模块，由 BootClassLoader 加载)
  │
  ├── 需要加载 java.sql.Driver 的实现类
  │   例如: com.mysql.cj.jdbc.Driver (在 classpath 上，由 AppClassLoader 加载)
  │
  └── 问题: BootClassLoader 的 loadClass 只能向上委托（null parent）
             它看不到 AppClassLoader 的 classpath！
             
双亲委派只能"向上看"，不能"向下看"：
  Boot ← Platform ← App
  Boot 无法委托给 App 加载类
```

### 7.2 解决方案：TCCL

```
initPhase3() 中设置 TCCL:
  VM.initLevel(3);
  ClassLoader scl = ClassLoader.initSystemClassLoader();  // = AppClassLoader
  Thread.currentThread().setContextClassLoader(scl);       // ★ 主线程的 TCCL = AppClassLoader
  VM.initLevel(4);
```

### 7.3 ServiceLoader 如何使用 TCCL

```java
// ServiceLoader.java:1691
@CallerSensitive
public static <S> ServiceLoader<S> load(Class<S> service) {
    ClassLoader cl = Thread.currentThread().getContextClassLoader();
    // ★ 获取 TCCL（默认是 AppClassLoader）
    return new ServiceLoader<>(Reflection.getCallerClass(), service, cl);
}
```

**完整流程**:

```
DriverManager.getConnection("jdbc:mysql://...")  (BootClassLoader 加载的类)
  │
  ├── ServiceLoader.load(Driver.class)
  │   └── cl = Thread.currentThread().getContextClassLoader()
  │       → AppClassLoader  ★ 获取 TCCL
  │
  ├── new ServiceLoader<>(callerClass, Driver.class, AppClassLoader)
  │   └── 使用 AppClassLoader 扫描 META-INF/services/java.sql.Driver
  │       └── 读取文件内容: "com.mysql.cj.jdbc.Driver"
  │
  └── AppClassLoader.loadClass("com.mysql.cj.jdbc.Driver")
      └── ★ 成功! 因为 AppClassLoader 可以访问 classpath
          AppClassLoader 走正常双亲委派:
            Platform → Boot → 都找不到 → App 自己加载 → 成功
```

### 7.4 TCCL 打破双亲委派的本质

```
正常双亲委派（向上委托）:
  App → Platform → Boot
  
TCCL（向下委托）:
  Boot 中的代码 → Thread.currentThread().getContextClassLoader() → App
  相当于 Boot 委托给 App 加载类
  
这 *不是* 破坏了双亲委派的 "代码机制"——
loadClass() 的实现没有被修改。
而是通过 "获取另一个 ClassLoader 的引用" 来绕过限制。
AppClassLoader.loadClass() 内部仍然遵守双亲委派。
```

### 7.5 TCCL 的传递规则

```java
// Thread.java — 子线程继承父线程的 TCCL
public Thread(ThreadGroup group, Runnable target, String name, long stackSize) {
    Thread parent = currentThread();
    // ...
    this.contextClassLoader = parent.contextClassLoader;
    // ★ 子线程默认继承父线程的 TCCL
}
```

---

## 8. 打破双亲委派的其他经典案例

### 8.1 Tomcat 的类加载器体系

```
                Bootstrap ClassLoader
                        │
                Platform ClassLoader
                        │
                  App ClassLoader
                        │
               Tomcat Common ClassLoader
                   (shared libraries)
               ╱              ╲
    WebApp1 ClassLoader    WebApp2 ClassLoader
     (WEB-INF/classes)      (WEB-INF/classes)
```

**打破方式**: `WebAppClassLoader` 重写 `loadClass()`，**先自己加载，再委托 parent**：

```java
// Tomcat WebAppClassLoader 的 loadClass 伪代码
protected Class<?> loadClass(String name, boolean resolve) {
    Class<?> clazz = findLoadedClass(name);
    if (clazz != null) return clazz;
    
    // ① 先检查是否是 JDK 核心类（必须委托给 parent）
    if (name.startsWith("java.") || name.startsWith("javax.servlet.")) {
        return super.loadClass(name, resolve);
    }
    
    // ② 先尝试自己加载（打破双亲委派！）
    try {
        clazz = findClass(name);  // 搜索 WEB-INF/classes 和 WEB-INF/lib
        if (clazz != null) return clazz;
    } catch (ClassNotFoundException e) { }
    
    // ③ 自己找不到才委托给 parent
    return super.loadClass(name, resolve);
}
```

**目的**: 实现 Web 应用间的类隔离——两个 Web 应用可以使用不同版本的同名类。

### 8.2 OSGi 的网状委派

```
传统双亲委派:  树状结构，只能向上委托
OSGi:          网状结构，任意 Bundle 之间可以互相委托

Bundle A ←→ Bundle B
   ↕           ↕
Bundle C ←→ Bundle D

每个 Bundle 有自己的 ClassLoader。
加载规则不是"先问 parent"，而是:
  ① java.* → 委托给 Boot ClassLoader
  ② Import-Package 中声明的包 → 委托给导出该包的 Bundle
  ③ 自己的 Bundle 内查找
  ④ Dynamic-ImportPackage → 动态查找
```

### 8.3 Java 9 模块系统（BuiltinClassLoader 的模块感知委派）

JDK 9 的 `BuiltinClassLoader.loadClassOrNull()` 本身就是对传统双亲委派的"升级"：

```
传统双亲委派（JDK 8）:
  固定顺序: parent → self
  
模块感知委派（JDK 9+）:
  ① 查 packageToModule → 直接定位到目标 ClassLoader（可跨级）
  ② 找不到 → 退化为传统双亲委派
  
这不算"打破"，而是"增强"——增加了一条快捷路径。
```

---

## 9. 自定义 ClassLoader 的最佳实践

### 9.1 正确的自定义方式

```java
public class MyClassLoader extends ClassLoader {
    
    static {
        // ★ 必须注册为 parallel capable
        ClassLoader.registerAsParallelCapable();
    }
    
    private final Path classDir;
    
    public MyClassLoader(ClassLoader parent, Path classDir) {
        super(parent);  // ★ 正确设置 parent
        this.classDir = classDir;
    }
    
    // ★ 重写 findClass，不要重写 loadClass！
    @Override
    protected Class<?> findClass(String name) throws ClassNotFoundException {
        String path = name.replace('.', '/') + ".class";
        Path classFile = classDir.resolve(path);
        
        try {
            byte[] bytes = Files.readAllBytes(classFile);
            return defineClass(name, bytes, 0, bytes.length);
            // defineClass 内部会处理安全检查和 JNI 穿越
        } catch (IOException e) {
            throw new ClassNotFoundException(name, e);
        }
    }
}
```

### 9.2 常见错误

| 错误 | 后果 | 正确做法 |
|------|------|---------|
| 重写 `loadClass()` 跳过 parent 委托 | 可能重复定义类，导致 `LinkageError` | 只重写 `findClass()` |
| 忘记调用 `registerAsParallelCapable()` | 多线程加载类时性能差、可能死锁 | 在 static 块中注册 |
| 没有设置 parent | parent 默认为 `getSystemClassLoader()`（可能不是你想要的） | 显式传入 parent |
| 尝试定义 `java.*` 包的类 | `SecurityException` | 不要尝试 |
| 用不同 ClassLoader 加载同名类后互相转型 | `ClassCastException`（不同 ClassLoader 加载的同名类不兼容） | 通过接口/父类交互 |

### 9.3 为什么不同 ClassLoader 加载的同名类不兼容？

```
ClassLoader A → 加载 com.example.Foo → Class<Foo>@A
ClassLoader B → 加载 com.example.Foo → Class<Foo>@B

Class<Foo>@A ≠ Class<Foo>@B  （不同的 Class 对象）

Foo objA = ...; // A 加载的
Foo objB = (Foo) objA; // 编译通过，但运行时：
// ClassCastException: com.example.Foo cannot be cast to com.example.Foo
// 因为 JVM 用 (ClassLoader, ClassName) 二元组唯一标识一个类
```

这就是 `SystemDictionary` 用 `(loader, name)` 作为键的原因——见 [system_dictionary_deep_dive.md](system_dictionary_deep_dive.md)。

---

## 10. resolveClass 与链接

```java
// ClassLoader.java:546
protected final void resolveClass(Class<?> c) {
    if (c == null) throw new NullPointerException();
    resolveClass0(c);  // [native]
    // → JVM_ResolveClass (jvm.cpp)
}
```

**在 JDK 11 中，`JVM_ResolveClass` 实际上是 no-op**——类的链接在 `defineClass` 时已经完成（eager linking）。`resolveClass` 保留只是为了 API 兼容性。

实际的链接过程：
- **验证**: `defineClass` 时由 `ClassFileParser` 完成字节码校验
- **准备**: `InstanceKlass::link_class_impl()` 中分配静态字段内存、设置 vtable/itable
- **解析**: 延迟解析（lazy resolution）——符号引用在首次使用时才解析

---

## 11. 类加载的完整生命周期（loadClass 视角）

```
         Java 层                              C++ 层
    ┌─────────────────┐              ┌───────────────────────┐
    │ Class.forName()  │              │                       │
    │ or new Foo()     │              │ JVM_FindClassFromCaller│
    └────────┬────────┘              │ / bytecode resolve    │
             │                        └───────────┬───────────┘
             │ 回调                               │
             ▼                                    ▼
    ┌─────────────────┐              ┌───────────────────────┐
    │ loadClass(name)  │              │ SystemDictionary::     │
    │ ┌──────────────┐│              │   resolve_or_fail()   │
    │ │findLoadedClass││─── JNI ───→ │ find_instance_or_     │
    │ │              ││              │   array_klass()       │
    │ └──────────────┘│              │   (Dictionary 查找)    │
    │                  │              └───────────────────────┘
    │ ┌──────────────┐│              
    │ │parent.loadCls ││── 递归 ──→  同样的 loadClass 流程
    │ └──────────────┘│              
    │                  │              
    │ ┌──────────────┐│              ┌───────────────────────┐
    │ │ findClass()   ││              │                       │
    │ │ ┌──────────┐ ││              │ JVM_DefineClassWith-  │
    │ │ │defineCls │ ││─── JNI ───→ │   Source              │
    │ │ └──────────┘ ││              │ → resolve_from_stream │
    │ └──────────────┘│              │ → ClassFileParser     │
    │                  │              │ → InstanceKlass       │
    │ ┌──────────────┐│              │ → Dictionary::add     │
    │ │resolveClass  ││─── JNI ───→ │   (no-op in JDK 11)  │
    │ └──────────────┘│              └───────────────────────┘
    └─────────────────┘
```

---

## 12. 面试高频问题

### Q1: loadClass 和 findClass 有什么区别？什么时候重写哪个？

> `loadClass()` 实现了完整的双亲委派逻辑（查缓存→委托parent→自己加载）；`findClass()` 只负责"自己加载"这一步。
>
> **自定义 ClassLoader 应该只重写 `findClass()`**，这样双亲委派机制不会被破坏。只有在需要打破双亲委派时（如 Tomcat WebAppClassLoader），才重写 `loadClass()`。

### Q2: 什么是 Thread Context ClassLoader？为什么需要它？

> TCCL 是绑定在线程上的 ClassLoader 引用（`Thread.contextClassLoader`），默认在 `initPhase3` 中设为 `AppClassLoader`，子线程继承父线程的 TCCL。
>
> 需要它是因为 **SPI 场景**：Bootstrap Loader 加载的接口（如 `java.sql.Driver`）需要加载由 AppClassLoader 才能访问的实现类（如 `com.mysql.cj.jdbc.Driver`）。双亲委派只能向上委托，TCCL 提供了一条向下获取 ClassLoader 的通道。

### Q3: 为什么不同 ClassLoader 加载的同名类不兼容？

> JVM 用 **(ClassLoader, ClassName)** 二元组唯一标识一个类。不同 ClassLoader 加载的 `com.example.Foo` 会生成不同的 `InstanceKlass` 和不同的 `Class` 镜像对象，它们之间无法互相转型（`ClassCastException`）。
>
> 这是 Java 安全模型的基础——防止恶意代码冒充核心类。

### Q4: JDK 9 的模块感知委派和传统双亲委派有什么区别？

> 传统双亲委派是**固定的线性委托链**（App → Platform → Boot），只能向上查找。
>
> 模块感知委派增加了 `packageToModule` 快捷路径——先按包名查找类所属的模块，**直接定位到拥有该模块的 ClassLoader**（可以跨级）。找不到时才退化为传统双亲委派。这使得 PlatformClassLoader 可以直接委托给 AppClassLoader（通过模块映射），打破了传统的单向约束。

### Q5: defineClass 在 Java 层和 C++ 层分别做了什么？

> **Java 层** (`ClassLoader.defineClass`):
> 1. `preDefineClass`: 安全检查（类名合法性、`java.*` 包保护、证书检查）
> 2. 调用 `defineClass1` native 方法
> 3. `postDefineClass`: 定义包、设置签名者
>
> **C++ 层** (`JVM_DefineClassWithSource` → `jvm_define_class_common`):
> 1. 类名 → `Symbol*`
> 2. 字节码 → `ClassFileStream`
> 3. `SystemDictionary::resolve_from_stream()` → `ClassFileParser::parse_stream()` → 创建 `InstanceKlass`
> 4. `Dictionary::add_klass()` → 注册到 SystemDictionary
> 5. 返回 `k->java_mirror()` → `jclass`

### Q6: findLoadedClass 查的是什么？为什么它不会触发类加载？

> `findLoadedClass()` 最终调用 C++ 层的 `SystemDictionary::find_instance_or_array_klass()`，这个方法只在 `Dictionary` 哈希表中查找 `(loader, name)` 键值对——**纯粹的内存查找，不涉及任何 I/O 或类解析**。如果类没被加载过，字典中没有对应条目，直接返回 null。

### Q7: Tomcat 是怎么打破双亲委派的？为什么要这样做？

> Tomcat 的 `WebAppClassLoader` 重写了 `loadClass()`：对于非核心类（非 `java.*`），**先搜索自己的 `WEB-INF/classes` 和 `WEB-INF/lib`，找不到才委托给 parent**。
>
> 目的是**Web 应用间的类隔离**——两个 Web 应用可以使用不同版本的 `com.google.gson.Gson`，不会互相干扰。

### Q8: 如果两个线程同时加载同一个类会发生什么？

> 取决于 ClassLoader 是否 parallel capable：
> - **Parallel capable**: 两个线程获取同一个 per-name 锁，一个等待另一个完成。`defineClass` 只会被调用一次，第二个线程在 `findLoadedClass` 时就能命中缓存。
> - **非 Parallel capable**: 两个线程锁同一个 ClassLoader 实例，一个等待另一个释放。

---

## 13. 源码文件索引

| 文件 | 关键内容 | 行号 |
|------|---------|------|
| **Java 层** | | |
| `java/lang/Class.java` | `forName()` 三个重载版本 → `forName0` native | 312, 380, 454 |
| `java/lang/ClassLoader.java` | `loadClass()` 传统双亲委派核心 | 566-605 |
| 同上 | `getClassLoadingLock()` 并行加载锁 | 660-672 |
| 同上 | `findLoadedClass()` → `findLoadedClass0` native | 1278-1284 |
| 同上 | `findClass()` 默认实现（抛异常） | 720 |
| 同上 | `defineClass()` 四个重载版本 | 800-1112 |
| 同上 | `defineClass1` / `defineClass2` native 声明 | 1114-1118 |
| 同上 | `preDefineClass()` 安全前置检查 | 894-916 |
| `jdk/internal/loader/BuiltinClassLoader.java` | `loadClassOrNull()` 模块感知委派 | 590-644 |
| 同上 | `findLoadedModule()` 包名 → 模块查找 | 653-660 |
| 同上 | `findClassInModuleOrNull()` 模块内加载 | 665-672 |
| 同上 | `findClassOnClassPathOrNull()` classpath 搜索 | 682-718 |
| `java/util/ServiceLoader.java` | `load()` 使用 TCCL | 1691 |
| `java/lang/System.java` | `initPhase3()` 设置 TCCL | 2077 |
| **C++ 层** | | |
| `prims/jvm.cpp` | `JVM_FindLoadedClass` | 968-1012 |
| 同上 | `JVM_DefineClassWithSource` → `jvm_define_class_common` | 897-966 |
| 同上 | `JVM_FindClassFromBootLoader` | 770-795 |

---

## 14. 与其他文档的关系

```
前一篇 ch06: 三级类加载器体系 — "谁来加载"
  │
  └── 本篇 ch07: loadClass 完整链路 — "怎么加载"
        │
        ├── → ch08 (下一篇): defineClass JNI 穿越
        │     (defineClass → ClassFileParser → InstanceKlass 的完整链路)
        │
        ├── → ch09: GDB 验证 + 综合面试题
        │
        └── 依赖已有文档:
            ├── system_dictionary_deep_dive.md — find/resolve 的 C++ 实现
            ├── classfile_parser.md — parse_stream 的详细分析
            └── ch06_classloader_hierarchy.md — 三级 ClassLoader 体系
```

---

*创建时间: 2026-02-09*
*GDB 验证环境: OpenJDK 11, -Xms8g -Xmx8g -XX:+UseG1GC*
