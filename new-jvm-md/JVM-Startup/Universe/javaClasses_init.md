# javaClasses_init() 详细分析

> 文档位置：`jvm-md/Universe/javaClasses_init.md`
> 源码位置：`src/hotspot/share/classfile/javaClasses.cpp:4598-4602`

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文对 **javaClasses_init() 详细分析** 进行源码级分析：追踪关键函数的执行路径，分析涉及的数据结构，解释每个设计决策的原因。

### 0.2 为什么需要？

仅靠文档和注释无法完全理解 JVM 的行为——很多关键细节只存在于源码中。源码级分析能建立对 JVM 行为的精确理解。

### 0.3 怎么解决？

从入口函数出发，自顶向下追踪调用链；对每个关键函数，分析其输入/输出/副作用；对每个数据结构，分析其字段含义和生命周期。

### 0.4 为什么这样设计？

分析过程中重点关注「为什么」：为什么选择这个数据结构？为什么这样处理边界情况？这些问题的答案往往揭示了 JVM 设计的精髓。

---


## 1. 功能定位

### 1.1 一句话总结

**`javaClasses_init()` 是 HotSpot VM 与 Java 类库的"桥梁构建器"** —— 它计算 JDK 核心类（如 `Thread`、`String`、`MethodHandle`）中各字段在内存中的精确偏移量，让 JVM 的 C++ 代码能够直接读写 Java 对象的字段，无需通过反射。

### 1.2 为什么需要它？

| 问题 | 解决方案 |
|------|----------|
| JVM 需要频繁访问 `Thread.eetop`、`String.value` 等字段 | 预先计算偏移量，直接指针访问 |
| 不同 JDK 版本类布局可能不同 | 运行时动态计算，而非编译时硬编码 |
| 某些字段 JVM 自己注入（Java 代码看不到） | `InjectedField` 机制处理 |

### 1.3 在启动流程中的位置

```
init_globals()
├── ...
├── universe_init()          ← 已分析
│   └── JavaClasses::compute_hard_coded_offsets()  // 硬编码偏移量（PART1 的部分字段）
├── ...
├── universe2_init()
│   └── SystemDictionary::resolve_well_known_classes()
│       └── 加载 String、Class 等类，并调用其 compute_offsets()  // PART1 完整计算
├── ...
└── javaClasses_init()       ← 当前分析
    ├── JavaClasses::compute_offsets()    // PART2 的 28 个类
    ├── JavaClasses::check_offsets()      // 验证硬编码偏移量（仅 DEBUG）
    └── FilteredFieldsMap::initialize()   // 反射过滤字段
```

---

## 2. 源码解读

### 2.1 入口函数

```cpp
// src/hotspot/share/classfile/javaClasses.cpp:4598-4602
void javaClasses_init() {
  JavaClasses::compute_offsets();      // 核心：计算 28 个类的字段偏移量
  JavaClasses::check_offsets();        // 验证硬编码偏移量（PRODUCT 模式空实现）
  FilteredFieldsMap::initialize();     // 反射时需要过滤的字段（必须在偏移量计算后）
}
```

**只有 3 行代码！** 但每一行都很重要。

---

## 3. JavaClasses::compute_offsets() 详解

### 3.1 宏展开机制

```cpp
// 宏定义
#define DO_COMPUTE_OFFSETS(k) k::compute_offsets();

void JavaClasses::compute_offsets() {
  if (UseSharedSpaces) {
    // CDS 模式：偏移量已从共享存档恢复，跳过计算
    return;
  }

  // PART1 (java_lang_String, java_lang_Class) 已在 resolve_well_known_classes() 中计算
  // 这里只计算 PART2 的 28 个类
  BASIC_JAVA_CLASSES_DO_PART2(DO_COMPUTE_OFFSETS);

  // 通知汇编器：延迟常量现在可以解析了
  AbstractAssembler::update_delayed_values();
}
```

### 3.2 BASIC_JAVA_CLASSES_DO_PART2 展开

宏 `BASIC_JAVA_CLASSES_DO_PART2` 展开后等价于：

```cpp
java_lang_System::compute_offsets();
java_lang_ClassLoader::compute_offsets();
java_lang_Throwable::compute_offsets();
java_lang_Thread::compute_offsets();
java_lang_ThreadGroup::compute_offsets();
java_lang_AssertionStatusDirectives::compute_offsets();
java_lang_ref_SoftReference::compute_offsets();
java_lang_invoke_MethodHandle::compute_offsets();
java_lang_invoke_DirectMethodHandle::compute_offsets();
java_lang_invoke_MemberName::compute_offsets();
java_lang_invoke_ResolvedMethodName::compute_offsets();
java_lang_invoke_LambdaForm::compute_offsets();
java_lang_invoke_MethodType::compute_offsets();
java_lang_invoke_CallSite::compute_offsets();
java_lang_invoke_MethodHandleNatives_CallSiteContext::compute_offsets();
java_security_AccessControlContext::compute_offsets();
java_lang_reflect_AccessibleObject::compute_offsets();
java_lang_reflect_Method::compute_offsets();
java_lang_reflect_Constructor::compute_offsets();
java_lang_reflect_Field::compute_offsets();
java_nio_Buffer::compute_offsets();
reflect_ConstantPool::compute_offsets();
reflect_UnsafeStaticFieldAccessorImpl::compute_offsets();
java_lang_reflect_Parameter::compute_offsets();
java_lang_Module::compute_offsets();
java_lang_StackTraceElement::compute_offsets();
java_lang_StackFrameInfo::compute_offsets();
java_lang_LiveStackFrameInfo::compute_offsets();
java_util_concurrent_locks_AbstractOwnableSynchronizer::compute_offsets();
```

### 3.3 涉及的 30 个类分类

| 分类 | 类 | 用途 |
|------|-----|------|
| **核心类** | `java_lang_System` | `System.in/out/err` 访问 |
| | `java_lang_ClassLoader` | 类加载器父指针等 |
| | `java_lang_Throwable` | 异常栈帧、`cause` 等 |
| **线程相关** | `java_lang_Thread` | `eetop`(JavaThread*)、`tid`、`name` 等 |
| | `java_lang_ThreadGroup` | 线程组管理 |
| **方法句柄** | `java_lang_invoke_MethodHandle` | `type`、`form` 字段 |
| | `java_lang_invoke_DirectMethodHandle` | 直接方法调用 |
| | `java_lang_invoke_MemberName` | 方法/字段描述符 |
| | `java_lang_invoke_LambdaForm` | Lambda 编译形式 |
| | `java_lang_invoke_MethodType` | 方法类型签名 |
| | `java_lang_invoke_CallSite` | 动态调用点 |
| **反射** | `java_lang_reflect_Method` | 反射方法对象 |
| | `java_lang_reflect_Constructor` | 反射构造器 |
| | `java_lang_reflect_Field` | 反射字段 |
| | `java_lang_reflect_AccessibleObject` | 可访问性标志 |
| **引用** | `java_lang_ref_SoftReference` | 软引用特殊字段 |
| **NIO** | `java_nio_Buffer` | 缓冲区地址、容量 |
| **模块** | `java_lang_Module` | 模块名、加载器等 |
| **栈遍历** | `java_lang_StackTraceElement` | 栈帧信息 |
| | `java_lang_StackFrameInfo` | StackWalker API |
| **并发** | `AbstractOwnableSynchronizer` | 锁持有者线程 |
| **安全** | `java_security_AccessControlContext` | 安全上下文 |

---

## 4. 典型类分析：java_lang_Thread

### 4.1 字段定义宏

```cpp
// src/hotspot/share/classfile/javaClasses.cpp:1616-1623
#define THREAD_FIELDS_DO(macro) \
  macro(_name_offset,          k, vmSymbols::name_name(), string_signature, false); \
  macro(_group_offset,         k, vmSymbols::group_name(), threadgroup_signature, false); \
  macro(_contextClassLoader_offset, k, "contextClassLoader", classloader_signature, false); \
  macro(_inheritedAccessControlContext_offset, k, "inheritedAccessControlContext", accesscontrolcontext_signature, false); \
  macro(_priority_offset,      k, vmSymbols::priority_name(), int_signature, false); \
  macro(_eetop_offset,         k, "eetop", long_signature, false); \
  macro(_stillborn_offset,     k, "stillborn", bool_signature, false); \
  macro(_stackSize_offset,     k, "stackSize", long_signature, false); \
  macro(_tid_offset,           k, "tid", long_signature, false); \
  macro(_thread_status_offset, k, "threadStatus", int_signature, false); \
  macro(_park_blocker_offset,  k, "parkBlocker", object_signature, false)
```

### 4.2 compute_offsets() 实现

```cpp
void java_lang_Thread::compute_offsets() {
  assert(_group_offset == 0, "offsets should be initialized only once");

  InstanceKlass* k = SystemDictionary::Thread_klass();  // 获取 java.lang.Thread 的 Klass
  THREAD_FIELDS_DO(FIELD_COMPUTE_OFFSET);               // 宏展开计算每个字段偏移量
}
```

### 4.3 宏展开过程

`FIELD_COMPUTE_OFFSET` 宏定义：

```cpp
#define FIELD_COMPUTE_OFFSET(offset, klass, name, signature, is_static) \
  compute_offset(offset, klass, name, vmSymbols::signature(), is_static)
```

展开一个字段（以 `_eetop_offset` 为例）：

```cpp
// 原始宏调用
macro(_eetop_offset, k, "eetop", long_signature, false);

// 展开后
compute_offset(_eetop_offset, k, "eetop", vmSymbols::long_signature(), false);

// 实际执行
compute_offset(java_lang_Thread::_eetop_offset,   // 存储结果的静态变量
               Thread_klass,                       // java.lang.Thread 的 InstanceKlass
               "eetop",                            // 字段名
               vmSymbols::long_signature(),        // "J"（long 类型签名）
               false);                             // 非静态字段
```

### 4.4 核心函数：compute_offset()

```cpp
// src/hotspot/share/classfile/javaClasses.cpp:122-144
static void compute_offset(int &dest_offset,
                           InstanceKlass* ik, Symbol* name_symbol, Symbol* signature_symbol,
                           bool is_static = false) {
  fieldDescriptor fd;
  
  // 1. 检查 Klass 是否有效
  if (ik == NULL) {
    vm_exit_during_initialization("Invalid layout of well-known class");
  }

  // 2. 在类中查找字段
  if (!ik->find_local_field(name_symbol, signature_symbol, &fd) || 
      fd.is_static() != is_static) {
    // 字段不存在或类型不匹配 → 致命错误
    log_error(class)("Invalid layout of %s field: %s type: %s", ...);
    vm_exit_during_initialization("Invalid layout of well-known class");
  }
  
  // 3. 获取字段偏移量
  dest_offset = fd.offset();  // 从 fieldDescriptor 获取偏移量
}
```

**关键点**：
- 使用 `InstanceKlass::find_local_field()` 查找字段
- 字段不存在或类型不匹配会**直接导致 JVM 启动失败**
- 偏移量存储到类的静态变量中（如 `java_lang_Thread::_eetop_offset`）

### 4.5 偏移量的使用

计算完成后，JVM 可以直接访问 Java 对象字段：

```cpp
// 读取 Thread 对象的 eetop 字段（指向 JavaThread*）
JavaThread* java_lang_Thread::thread(oop java_thread) {
  return (JavaThread*)java_thread->address_field(_eetop_offset);
}

// 设置 Thread 对象的 eetop 字段
void java_lang_Thread::set_thread(oop java_thread, JavaThread* thread) {
  java_thread->address_field_put(_eetop_offset, (address)thread);
}

// 读取线程优先级
ThreadPriority java_lang_Thread::priority(oop java_thread) {
  return (ThreadPriority)java_thread->int_field(_priority_offset);
}
```

---

## 5. 典型类分析：java_lang_invoke_MethodHandle

### 5.1 字段定义

```cpp
#define METHODHANDLE_FIELDS_DO(macro) \
  macro(_type_offset, k, vmSymbols::type_name(), java_lang_invoke_MethodType_signature, false); \
  macro(_form_offset, k, "form",                 java_lang_invoke_LambdaForm_signature, false)
```

**MethodHandle 只有 2 个字段**：
- `type`：`MethodType` 对象，描述方法签名
- `form`：`LambdaForm` 对象，Lambda 表达式的编译形式

### 5.2 为什么 MethodHandle 这么简单？

MethodHandle 是 Java 7 引入的高性能方法调用机制。它的设计哲学是：

1. **Java 层面简洁**：只暴露 `type` 和 `form`
2. **复杂逻辑下沉**：真正的方法指针在 `MemberName` 中（通过 `form.vmentry` 间接访问）

```
MethodHandle                          MemberName
┌────────────────┐                   ┌────────────────┐
│ type ──────────│──→ MethodType     │ clazz          │
│ form ──────────│──→ LambdaForm     │ name           │
└────────────────┘    │              │ type           │
                      │              │ flags          │
                      │ vmentry ─────│──→ Method*     │ ← JVM 注入字段！
                      │              └────────────────┘
                      └──────────────┘
```

---

## 6. AbstractAssembler::update_delayed_values()

### 6.1 什么是 Delayed Values？

解释器模板代码（如 `TemplateInterpreterGenerator`）在生成时，可能需要引用某些字段偏移量。但这些偏移量在代码生成时**还没有计算出来**！

**解决方案**：延迟常量（Delayed Constants）

```cpp
// 生成解释器代码时
__ movptr(temp, Address(obj, delayed_value(java_lang_String::value_offset)));
                            ↑
                            此时 value_offset 可能还是 0！
```

### 6.2 工作原理

```cpp
// 1. 生成代码时，注册延迟常量
intptr_t* AbstractAssembler::delayed_value_addr(int(*value_fn)()) {
  DelayedConstant* dcon = DelayedConstant::add(T_INT, value_fn);
  return &dcon->value;  // 返回存储值的地址（当前为 0）
}

// 2. 偏移量计算完成后，统一更新
void DelayedConstant::update_all() {
  for (int i = 0; i < DC_LIMIT; i++) {
    DelayedConstant* dcon = &delayed_constants[i];
    if (dcon->value_fn != NULL && dcon->value == 0) {
      // 调用函数获取实际值
      switch (dcon->type) {
        case T_INT:     dcon->value = ((int_fn_t)dcon->value_fn)(); break;
        case T_ADDRESS: dcon->value = ((address_fn_t)dcon->value_fn)(); break;
      }
    }
  }
}
```

### 6.3 为什么有 DC_LIMIT = 20？

```cpp
enum { DC_LIMIT = 20 };  // 最多 20 个延迟常量
```

这是一个"够用就好"的设计。主要用于 MethodHandle 相关的偏移量（约 10 个左右）。

---

## 7. FilteredFieldsMap::initialize()

### 7.1 作用

在反射遍历字段时，**过滤掉 JVM 内部注入的字段**（这些字段 Java 代码不应该看到）。

```cpp
// src/hotspot/share/runtime/reflectionUtils.cpp:75-78
void FilteredFieldsMap::initialize() {
  // 1. reflect.ConstantPool.oop_offset —— 指向 oop 的内部指针
  int offset = reflect_ConstantPool::oop_offset();
  _filtered_fields->append(new FilteredField(SystemDictionary::reflect_ConstantPool_klass(), offset));
  
  // 2. UnsafeStaticFieldAccessorImpl.base —— 静态字段访问的基地址
  offset = reflect_UnsafeStaticFieldAccessorImpl::base_offset();
  _filtered_fields->append(new FilteredField(SystemDictionary::reflect_UnsafeStaticFieldAccessorImpl_klass(), offset));
}
```

### 7.2 为什么必须在偏移量计算后？

注释说得很清楚：

```cpp
FilteredFieldsMap::initialize();  // must be done after computing offsets.
```

因为 `reflect_ConstantPool::oop_offset()` 和 `reflect_UnsafeStaticFieldAccessorImpl::base_offset()` 的值**在 `compute_offsets()` 之后才有效**！

---

## 8. JavaClasses::check_offsets()

### 8.1 作用

**仅在 DEBUG 模式**下验证**硬编码**的偏移量是否正确。

```cpp
#ifndef PRODUCT
void JavaClasses::check_offsets() {
  bool valid = true;

  // 检查装箱类型的 value 字段偏移量
  CHECK_OFFSET("java/lang/Boolean",   java_lang_boxing_object, value, "Z");
  CHECK_OFFSET("java/lang/Character", java_lang_boxing_object, value, "C");
  CHECK_OFFSET("java/lang/Integer",   java_lang_boxing_object, value, "I");
  // ... 更多检查 ...

  // 检查 Reference 类的字段偏移量
  CHECK_OFFSET("java/lang/ref/Reference", java_lang_ref_Reference, referent, "Ljava/lang/Object;");
  CHECK_OFFSET("java/lang/ref/Reference", java_lang_ref_Reference, queue, "Ljava/lang/ref/ReferenceQueue;");
  // ...
}
#endif
```

### 8.2 硬编码 vs 动态计算

| 类型 | 示例 | 原因 |
|------|------|------|
| **硬编码** | `java_lang_boxing_object::value_offset` | 装箱类型布局稳定，性能关键 |
| **动态计算** | `java_lang_Thread::_eetop_offset` | 可能随 JDK 版本变化 |

硬编码偏移量在 `JavaClasses::compute_hard_coded_offsets()`（universe_init 阶段）中初始化。

---

## 9. GDB 验证

### 9.1 验证脚本

```gdb
# jvm-md/Universe/gdb_javaClasses_init.txt

set pagination off
set print pretty on

# 断点设在 javaClasses_init 之后
b init.cpp:149
run -Xms512m -Xmx512m -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# === java_lang_Thread 字段偏移量 ===
printf "\n========== java_lang_Thread offsets ==========\n"
printf "_eetop_offset:         %d\n", java_lang_Thread::_eetop_offset
printf "_name_offset:          %d\n", java_lang_Thread::_name_offset
printf "_group_offset:         %d\n", java_lang_Thread::_group_offset
printf "_priority_offset:      %d\n", java_lang_Thread::_priority_offset
printf "_tid_offset:           %d\n", java_lang_Thread::_tid_offset
printf "_thread_status_offset: %d\n", java_lang_Thread::_thread_status_offset
printf "_park_blocker_offset:  %d\n", java_lang_Thread::_park_blocker_offset

# === java_lang_String 字段偏移量 ===
printf "\n========== java_lang_String offsets ==========\n"
printf "value_offset:  %d\n", java_lang_String::value_offset
printf "hash_offset:   %d\n", java_lang_String::hash_offset
printf "coder_offset:  %d\n", java_lang_String::coder_offset

# === java_lang_invoke_MethodHandle 字段偏移量 ===
printf "\n========== java_lang_invoke_MethodHandle offsets ==========\n"
printf "_type_offset:  %d\n", java_lang_invoke_MethodHandle::_type_offset
printf "_form_offset:  %d\n", java_lang_invoke_MethodHandle::_form_offset

# === java_lang_invoke_MemberName 字段偏移量 ===
printf "\n========== java_lang_invoke_MemberName offsets ==========\n"
printf "_clazz_offset:  %d\n", java_lang_invoke_MemberName::_clazz_offset
printf "_name_offset:   %d\n", java_lang_invoke_MemberName::_name_offset
printf "_type_offset:   %d\n", java_lang_invoke_MemberName::_type_offset
printf "_flags_offset:  %d\n", java_lang_invoke_MemberName::_flags_offset
printf "_method_offset: %d\n", java_lang_invoke_MemberName::_method_offset

# === 装箱类型硬编码偏移量 ===
printf "\n========== Boxing object offsets (hardcoded) ==========\n"
printf "value_offset:      %d\n", java_lang_boxing_object::value_offset
printf "long_value_offset: %d\n", java_lang_boxing_object::long_value_offset

# === FilteredFieldsMap ===
printf "\n========== FilteredFieldsMap ==========\n"
printf "filtered_fields count: %d\n", FilteredFieldsMap::_filtered_fields->_len

quit
```

### 9.2 执行方式

```bash
cd /data/workspace/openjdk-cut-new
gdb -x jvm-md/Universe/gdb_javaClasses_init.txt \
    ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java
```

### 9.3 实际 GDB 验证结果

【GDB 验证】条件：-Xms256m -Xmx256m -Xint

```
========== java_lang_Thread offsets ==========
_eetop_offset:         16    ← long 字段，紧接对象头
_name_offset:          48    ← String 引用
_group_offset:         56    ← ThreadGroup 引用
_priority_offset:      12    ← int 字段
_tid_offset:           32    ← long 字段
_thread_status_offset: 40    ← int 字段
_park_blocker_offset:  76    ← Object 引用

========== java_lang_String offsets ==========
value_offset:  12    ← byte[] 引用
hash_offset:   16    ← int 字段
coder_offset:  未读取

========== java_lang_invoke_MethodHandle offsets ==========
_type_offset:  16    ← MethodType 引用
_form_offset:  20    ← LambdaForm 引用

========== java_lang_invoke_MemberName offsets ==========
_clazz_offset:  24   ← Class 引用
_name_offset:   28   ← String 引用
_type_offset:   32   ← Object 引用
_flags_offset:  12   ← int 字段
_method_offset: 36   ← ResolvedMethodName 引用
```

### 9.4 偏移量解读

**java_lang_Thread 内存布局**（压缩指针开启）：

```
Thread 对象内存布局（使用压缩指针）
偏移      字段名                大小    类型
───────────────────────────────────────────
0x00     [对象头 mark word]    8       markOop
0x08     [对象头 klass]        4       压缩类指针
0x0C     priority             4       int         ← offset = 12
0x10     eetop                8       long        ← offset = 16 (C++ JavaThread*)
0x18     (字段续...)
0x20     tid                  8       long        ← offset = 32
0x28     threadStatus         4       int         ← offset = 40
...
0x30     name                 4       String引用   ← offset = 48
0x38     group                4       ThreadGroup  ← offset = 56
...
0x4C     parkBlocker          4       Object引用   ← offset = 76
```

**关键观察**：
1. **eetop 偏移量 = 16**：紧接对象头，JVM 需要快速访问底层 JavaThread*
2. **压缩指针模式**：oop 引用只占 4 字节（如 name = 48, group = 56）
3. **字段排列**：JVM 会重排字段以优化内存对齐（非声明顺序）

---

## 10. 设计思考

### 10.1 为什么不在编译时硬编码所有偏移量？

| 原因 | 说明 |
|------|------|
| **JDK 版本兼容** | 不同版本类布局可能变化 |
| **CDS 支持** | 共享类数据需要动态校准 |
| **JVM 注入字段** | 某些字段只有 JVM 知道 |

### 10.2 为什么分 PART1 和 PART2？

```cpp
BASIC_JAVA_CLASSES_DO_PART1(f)  // java_lang_Class, java_lang_String
BASIC_JAVA_CLASSES_DO_PART2(f)  // 其他 28 个类
```

**PART1** 类是"最早需要"的：
- `java_lang_Class`：几乎所有类加载都需要
- `java_lang_String`：常量池解析需要

它们在 `resolve_well_known_classes()` 中加载，此时必须**立即计算偏移量**。

**PART2** 类可以稍后加载（如 `MethodHandle` 相关类），统一在 `javaClasses_init()` 计算。

### 10.3 性能影响

字段偏移量计算**只在 JVM 启动时执行一次**，之后所有字段访问都是直接指针操作（O(1)）。

对比反射的访问方式：
```java
// 反射（慢）
Field f = Thread.class.getDeclaredField("eetop");
long eetop = f.getLong(thread);

// JVM 内部（快）
long eetop = thread->long_field(_eetop_offset);  // 直接内存访问
```

---

## 11. 总结

### 11.1 核心流程

```
javaClasses_init()
    │
    ├──→ JavaClasses::compute_offsets()
    │        │
    │        ├── 跳过 CDS 模式（已从存档恢复）
    │        │
    │        ├── BASIC_JAVA_CLASSES_DO_PART2(DO_COMPUTE_OFFSETS)
    │        │       ↓
    │        │   java_lang_System::compute_offsets()
    │        │   java_lang_Thread::compute_offsets()
    │        │   java_lang_invoke_MethodHandle::compute_offsets()
    │        │   ... 共 28 个类 ...
    │        │       ↓
    │        │   THREAD_FIELDS_DO(FIELD_COMPUTE_OFFSET)
    │        │       ↓
    │        │   compute_offset(_eetop_offset, k, "eetop", J, false)
    │        │       ↓
    │        │   ik->find_local_field() → fd.offset()
    │        │
    │        └── AbstractAssembler::update_delayed_values()
    │                ↓
    │            解析延迟常量（解释器代码中的偏移量引用）
    │
    ├──→ JavaClasses::check_offsets()（仅 DEBUG）
    │        ↓
    │    验证硬编码偏移量与实际类布局一致
    │
    └──→ FilteredFieldsMap::initialize()
             ↓
         注册需要在反射中隐藏的 JVM 内部字段
```

### 11.2 关键数据结构

| 结构 | 作用 |
|------|------|
| `java_lang_Thread::_eetop_offset` | 静态变量，存储计算出的偏移量 |
| `fieldDescriptor` | 字段描述符，包含偏移量、类型等 |
| `DelayedConstant[20]` | 延迟常量数组，汇编器用 |
| `FilteredFieldsMap` | 反射过滤字段列表 |

### 11.3 与其他初始化的关系

| 阶段 | 函数 | 计算的偏移量 |
|------|------|-------------|
| universe_init | `compute_hard_coded_offsets()` | 装箱类型、Reference 等（硬编码） |
| universe2_init | PART1 `compute_offsets()` | String、Class |
| **javaClasses_init** | PART2 `compute_offsets()` | Thread、MethodHandle 等 28 个 |

---

## 12. 下一步建议

如果想深入，可以：

1. **GDB 验证**：运行上面的脚本，观察实际偏移量值
2. **跟踪 MethodHandle**：分析 `invokedynamic` 如何使用这些偏移量
3. **研究 CDS**：了解偏移量如何序列化和反序列化

---

> 📅 分析时间：2026-02-06
> 📁 源码版本：OpenJDK 11
