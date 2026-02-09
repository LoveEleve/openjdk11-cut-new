# Klass 层次结构：Java 类在 JVM 中的完整表示

> **源码版本**: OpenJDK 11 (`/data/workspace/openjdk-cut-new/`)
> **标准环境**: `-Xms8g -Xmx8g -XX:+UseG1GC`, Region 大小 4MB
> **核心源文件**: `src/hotspot/share/oops/klass.hpp`, `instanceKlass.hpp`, `arrayKlass.hpp`

---

## 第一章 为什么需要 Klass？——oop/klass 二分法

### 1.1 问题引入

Java 程序中每个对象都有类型信息（虚方法表、字段布局、继承关系等），C++ 的做法是在每个对象头部放一个 vtable 指针（8 字节）。但 JVM 需要管理数十亿个 Java 对象，如果每个 Java 对象都嵌入一个 C++ vtable 指针，**内存浪费巨大**。

### 1.2 解决方案：oop/klass 分离

HotSpot 将 Java 对象的表示分为两层：

```
┌─────────────────────────────────────────────────────────────────┐
│  oop 层（Java 对象实例）                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │ instanceOop  │  │ objArrayOop  │  │ typeArrayOop │          │
│  │ (普通对象)   │  │ (对象数组)   │  │ (基本类型数组)│          │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘          │
│         │ klass 指针        │ klass 指针        │ klass 指针       │
└─────────┼──────────────────┼──────────────────┼────────────────┘
          ▼                  ▼                  ▼
┌─────────────────────────────────────────────────────────────────┐
│  Klass 层（类元数据，存储在 Metaspace）                          │
│  ┌──────────────────┐  ┌──────────────┐  ┌───────────────┐     │
│  │  InstanceKlass   │  │ ObjArrayKlass│  │ TypeArrayKlass│     │
│  │ (java.lang.String│  │ (String[])   │  │ (int[])       │     │
│  │  的类信息)        │  │              │  │               │     │
│  └──────────────────┘  └──────────────┘  └───────────────┘     │
│  存储：虚方法表 / 字段布局 / 常量池 / 接口表 / 继承关系...       │
└─────────────────────────────────────────────────────────────────┘
```

**关键设计决策**：

| 对比项 | oop（Java 对象） | Klass（类元数据） |
|--------|-----------------|------------------|
| 存储位置 | Java 堆 | Metaspace |
| 数量级 | 数十亿（每个 Java 对象一个） | 数千（每个 Java 类一个） |
| 有无 C++ vtable | **没有**（省空间） | **有**（用于 C++ 多态分发） |
| 对象头 | markWord + klass 指针 | C++ vtable + 字段... |

> **核心原则**：oop 不含 C++ vtable 指针。所有"虚方法"转发到对应的 Klass 上执行，以 `oop_` 为前缀的函数实现此分发。
> 
> 源码注释 (`klass.hpp:80`)：
> ```
> // A Klass provides:
> //  1: language level class object (method dictionary etc.)
> //  2: provide vm dispatch behavior for the object
> // Both functions are combined into one C++ class.
> ```

### 1.3 对象头与 Klass 的连接

每个 Java 对象（oopDesc）的内存布局：

```
oopDesc (instanceOopDesc / arrayOopDesc)
偏移    内容                    大小
───────────────────────────────────────
0x000   markWord               8 字节   ← 锁状态 + hashCode + GC age
0x008   _metadata._klass       4 字节   ← 压缩 Klass 指针 (narrowKlass)
                      或       8 字节   ← 普通 Klass 指针 (UseCompressedClassPointers=false)
0x00C   实例字段开始...         ← 由 InstanceKlass._layout_helper 描述大小
```

通过 `_metadata._klass` 指针，从任意 Java 对象可以找到它的 Klass，进而获取：虚方法表、字段信息、继承关系、常量池等全部类元数据。

---

## 第二章 Klass 继承体系总览

### 2.1 完整继承树

```
MetaspaceObj
  └── Metadata                          ← 抽象基类，有 C++ vtable
        ├── Klass                        ← 所有类的元数据根类 (208 bytes)
        │     ├── InstanceKlass          ← 普通 Java 类/接口 (472 bytes)
        │     │     ├── InstanceMirrorKlass       ← java.lang.Class 的 Klass (472 bytes)
        │     │     ├── InstanceRefKlass          ← Reference 子类的 Klass (472 bytes)
        │     │     └── InstanceClassLoaderKlass  ← ClassLoader 子类的 Klass (472 bytes)
        │     └── ArrayKlass             ← 数组类的抽象基类 (232 bytes)
        │           ├── ObjArrayKlass    ← 对象引用数组 (248 bytes)
        │           └── TypeArrayKlass   ← 基本类型数组 (240 bytes)
        ├── Method                       ← 方法元数据
        ├── ConstMethod                  ← 只读方法数据
        ├── MethodData                   ← 性能分析数据
        └── ConstantPool                 ← 常量池
```

**源码位置**: `oopsHierarchy.hpp:214-221`

### 2.2 KlassID 枚举——去虚拟化分发

每个 Klass 子类有一个唯一的 `KlassID`，存储在 `Klass::_id` 字段中：

```cpp
// klass.hpp:41-48
enum KlassID {
  InstanceKlassID,               // 0 — 普通 Java 类
  InstanceRefKlassID,            // 1 — Reference 子类
  InstanceMirrorKlassID,         // 2 — java.lang.Class
  InstanceClassLoaderKlassID,    // 3 — ClassLoader 子类
  TypeArrayKlassID,              // 4 — 基本类型数组
  ObjArrayKlassID                // 5 — 对象引用数组
};
```

**为什么需要 KlassID？** GC 遍历对象时需要调用不同的 `oop_oop_iterate` 方法。如果每次都走 C++ 虚函数分发（间接跳转），性能差。有了 KlassID，可以在编译期将虚调用内联为 switch-case 直接分发，消除间接跳转开销。

### 2.3 六种 Klass 的使用场景

| Klass 类型 | KlassID | 对应 Java 类 | 特殊行为 |
|-----------|---------|------------|---------|
| InstanceKlass | 0 | 所有普通类和接口 | 嵌入 vtable/itable/oop-map |
| InstanceRefKlass | 1 | SoftReference/WeakReference/FinalReference/PhantomReference | GC 时特殊处理 referent/discovered 字段 |
| InstanceMirrorKlass | 2 | 仅 java.lang.Class | 变长实例：包含所代表类的静态字段 |
| InstanceClassLoaderKlass | 3 | ClassLoader 及其子类 | GC 时额外遍历 ClassLoaderData |
| TypeArrayKlass | 4 | int[]/byte[]/long[] 等基本类型数组 | 无 oop 字段，GC 只需算大小 |
| ObjArrayKlass | 5 | Object[]/String[] 等对象引用数组 | GC 需遍历每个元素 |

---

## 第三章 Klass 基类——208 字节的核心骨架

### 3.1 内存布局（GDB 验证）

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC, slowdebug 版本
┌──────────────────────────────────────────────────────────────────────────┐
│ Klass 内存布局 (总大小: 208 bytes)                                        │
├──────────┬────────────────────────────────────────┬──────┬──────────────┤
│ 偏移     │ 字段名                                  │ 大小 │ 类型          │
├──────────┼────────────────────────────────────────┼──────┼──────────────┤
│ 0x000(0) │ [C++ vtable pointer]                   │  8   │ intptr_t*    │
│          │ [_valid (NOT_PRODUCT)]                  │  4   │ int          │
│          │ [padding]                               │      │              │
│ 0x00C(12)│ _layout_helper                         │  4   │ jint         │
│ 0x010(16)│ _id                                    │  4   │ KlassID      │
│ 0x014(20)│ _super_check_offset                    │  4   │ juint        │
│ 0x018(24)│ _name                                  │  8   │ Symbol*      │
│ 0x020(32)│ _secondary_super_cache                 │  8   │ Klass*       │
│ 0x028(40)│ _secondary_supers                      │  8   │ Array<Klass*>│
│ 0x030(48)│ _primary_supers[0]                     │  8   │ Klass*       │
│ ...      │ _primary_supers[1..6]                  │ 48   │ Klass*[6]    │
│ 0x068(104)│ _primary_supers[7]                    │  8   │ Klass*       │
│ 0x070(112)│ _java_mirror                          │  8   │ OopHandle    │
│ 0x078(120)│ _super                                │  8   │ Klass*       │
│ 0x080(128)│ _subklass                             │  8   │ Klass*       │
│ 0x088(136)│ _next_sibling                         │  8   │ Klass*       │
│ 0x090(144)│ _next_link                            │  8   │ Klass*       │
│ 0x098(152)│ _class_loader_data                    │  8   │ ClassLoaderData*│
│ 0x0A0(160)│ _modifier_flags                       │  4   │ jint         │
│ 0x0A4(164)│ _access_flags                         │  4   │ AccessFlags  │
│ 0x0A8(168)│ _trace_id (JFR)                       │  8   │ traceid      │
│ 0x0B0(176)│ _last_biased_lock_bulk_revocation_time│  8   │ jlong        │
│ 0x0B8(184)│ _prototype_header                     │  8   │ markOop      │
│ 0x0C0(192)│ _biased_lock_revocation_count         │  4   │ jint         │
│ 0x0C4(196)│ _vtable_len                           │  4   │ int          │
│ 0x0C8(200)│ _shared_class_path_index              │  2   │ jshort       │
│ 0x0CA(202)│ _shared_class_flags                   │  2   │ u2 (CDS)     │
│ 0x0CC(204)│ _archived_mirror                      │  4   │ narrowOop    │
├──────────┼────────────────────────────────────────┼──────┼──────────────┤
│ 总计     │                                        │ 208  │              │
└──────────┴────────────────────────────────────────┴──────┴──────────────┘
```

> **注意**: offset 0-11 包含 C++ vtable 指针 (8 bytes) 和 debug 版本的 `_valid` 字段 (4 bytes)。`_layout_helper` 从 offset 12 开始，源码注释说"紧跟 vtable 指针之后，因为最频繁查询"。

### 3.2 核心字段详解

#### 3.2.1 `_layout_helper`（offset 12, 4 bytes）——对象布局描述符

**是什么**: 一个 `jint`，编码了该类创建的 Java 对象的大小信息。

**为什么需要**: 对象分配是最频繁的操作之一。分配时需要知道对象大小，`_layout_helper` 将这个信息编码成一个 int，一次内存读取即可获得，避免遍历字段列表计算大小。

**三种编码模式** (`klass.hpp:89-114`):

```
(1) 实例类 (layout_helper > 0):
    layout_helper = 对象大小（字节, 已对齐） | slow_path_bit
    
    例: java.lang.Object, layout_helper = 16
    → 16 字节 = 8 (markWord) + 4 (klass指针) + 4 (padding)

(2) 数组类 (layout_helper < 0):
    MSB: [tag:2 | header_size:8 | element_type:8 | log2(element_size):8] :LSB
    
    tag = 0x80 → 对象引用数组 (ObjArrayKlass)
    tag = 0xC0 → 基本类型数组 (TypeArrayKlass)
    
    例: int[] → tag=0xC0, hsz=16, ebt=T_INT(10), log2(esz)=2
        layout_helper = 0xC0001002 (负数)

(3) 中性值 (layout_helper == 0):
    非实例非数组的 Klass（如 ArrayKlass 初始化时的临时状态）
```

**快速类型判断** (`klass.hpp:372-385`):
```cpp
bool is_instance_klass()  → layout_helper > 0     // 一条 cmp 指令
bool is_array_klass()     → layout_helper < 0     // 一条 test 指令
bool is_typeArray_klass() → (unsigned)layout_helper >= 0xC0000000
bool is_objArray_klass()  → layout_helper < 0 && < 0xC0000000
```

#### 3.2.2 `_primary_supers[8]` + `_super_check_offset` + `_secondary_super_cache`——快速子类型检查

**解决的问题**: `instanceof` 和类型转换是 Java 程序中极其频繁的操作，需要检查 A 是否是 B 的子类型。简单的向上遍历继承链是 O(n)，太慢。

**解决方案——Cohen's Display 算法** (`klass.hpp:120-137`):

```
假设继承链: Object(0) → Animal(1) → Dog(2) → Labrador(3)

Labrador._primary_supers[] = {Object, Animal, Dog, Labrador, NULL, NULL, NULL, NULL}
Labrador._super_check_offset = &_primary_supers[3] - this = 48 + 3*8 = 72

检查 Labrador instanceof Animal:
  depth(Animal) = 1
  Labrador._primary_supers[1] == Animal? → true!  // O(1) 一次数组访问
```

**为什么限制 8 级？** 绝大多数 Java 类的继承深度 < 8（实际统计中位数 3-4 级）。超过 8 级的使用 `_secondary_supers` 数组线性搜索，并用 `_secondary_super_cache` 缓存最近一次查找结果。

```
快速路径 (depth < 8):
  this._primary_supers[target_depth] == target_klass?  → O(1)

慢速路径 (depth >= 8 或接口类型):
  1. 先查 _secondary_super_cache → 命中则 O(1)
  2. 不命中则线性搜索 _secondary_supers[] → O(n)
  3. 命中后更新 _secondary_super_cache
```

#### 3.2.3 `_java_mirror`（offset 112, 8 bytes）——java.lang.Class 镜像

**是什么**: 指向该类对应的 `java.lang.Class` 实例的句柄。

**为什么是 OopHandle 不是直接指针？** `java.lang.Class` 实例在 Java 堆中，GC 可能移动它。`OopHandle` 是一个间接指针（指向 `OopStorage` 中的 slot），GC 移动 Class 对象时只需更新 slot 的值，不需修改 Klass 中的 `_java_mirror` 字段。

**双向引用**:
```
InstanceKlass._java_mirror → java.lang.Class 实例（在 Java 堆中）
java.lang.Class 实例中有一个隐藏字段 → 反向指回 InstanceKlass（在 Metaspace 中）
```

#### 3.2.4 `_super` / `_subklass` / `_next_sibling`——类继承树

这三个指针构建了一棵 **类继承树**：

```
                Object (_super=NULL)
               /       \
          String       Thread       ← _subklass 链
          (_next_sibling → Thread)
         /
       ... 
```

- `_super`: 指向父类 Klass
- `_subklass`: 指向第一个子类 Klass
- `_next_sibling`: 同一父类下的兄弟链表

#### 3.2.5 `_next_link` / `_class_loader_data`——类加载器关联

- `_class_loader_data`: 指向加载此类的 `ClassLoaderData`，是类加载器在 VM 层面的表示
- `_next_link`: 同一个 `ClassLoaderData` 加载的所有类形成链表

**用途**: 当类加载器被 GC 回收时，需要遍历并卸载它加载的所有类。

#### 3.2.6 `_vtable_len`（offset 196, 4 bytes）——Java vtable 长度

**是什么**: 该类的 Java 虚方法表的条目数（以 word 为单位等于条目数，因为每个 `vtableEntry` 是一个 `Method*` = 8 bytes = 1 word）。

**与 C++ vtable 的区别**:
- C++ vtable: 在 offset 0，是 C++ 编译器生成的，Klass 自身的虚函数表
- Java vtable: **嵌入在 InstanceKlass header 之后**，是 Java 类的虚方法表，用于 `invokevirtual` 分发

#### 3.2.7 偏向锁相关字段

| 字段 | 偏移 | 说明 |
|------|------|------|
| `_last_biased_lock_bulk_revocation_time` | 176 | 上次批量撤销时间戳 |
| `_prototype_header` | 184 | 偏向锁原型 markWord |
| `_biased_lock_revocation_count` | 192 | 撤销计数器 |

> **注**: 本项目分析标准不考虑偏向锁（JDK 15+ 已废弃），但这些字段在 OpenJDK 11 中仍然占用空间。

---

## 第四章 InstanceKlass——Java 类的完整表示 (472 bytes)

### 4.1 功能定位

`InstanceKlass` 是 JVM 中最核心的数据结构之一。每加载一个 Java 类（包括接口），都会在 Metaspace 中创建一个 `InstanceKlass` 对象。它包含了在运行时执行该类代码所需的**全部**信息：

- 字段布局（_fields）
- 方法数组（_methods）
- 常量池（_constants）
- 虚方法表（embedded vtable）
- 接口方法表（embedded itable）
- GC oop 映射（embedded oop-map blocks）
- 类初始化状态机
- JVMTI 支持数据

### 4.2 内存布局（GDB 验证）

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC, slowdebug 版本
┌──────────────────────────────────────────────────────────────────────────┐
│ InstanceKlass 内存布局 (header 部分: 472 bytes)                           │
├──────────┬────────────────────────────────────────┬──────┬──────────────┤
│ 偏移     │ 字段名                                  │ 大小 │ 类型          │
├──────────┼────────────────────────────────────────┼──────┼──────────────┤
│          │ ═══ 继承自 Klass 的字段 (0-207) ═══     │      │              │
│ 0-207    │ (见第三章 Klass 布局)                    │ 208  │              │
├──────────┼────────────────────────────────────────┼──────┼──────────────┤
│          │ ═══ InstanceKlass 自有字段 (208-471) ═══│      │              │
│ 0x0D0(208)│ _annotations                          │  8   │ Annotations* │
│ 0x0D8(216)│ _package_entry                        │  8   │ PackageEntry*│
│ 0x0E0(224)│ _array_klasses                        │  8   │ Klass* volatile│
│ 0x0E8(232)│ _constants                            │  8   │ ConstantPool*│
│ 0x0F0(240)│ _inner_classes                        │  8   │ Array<u2>*   │
│ 0x0F8(248)│ _nest_members                         │  8   │ Array<u2>*   │
│ 0x100(256)│ _nest_host_index                      │  2   │ jushort      │
│ 0x102(258)│ [6-byte hole]                         │  6   │ padding      │
│ 0x108(264)│ _nest_host                            │  8   │ InstanceKlass*│
│ 0x110(272)│ _source_debug_extension               │  8   │ const char*  │
│ 0x118(280)│ _array_name                           │  8   │ Symbol*      │
│ 0x120(288)│ _nonstatic_field_size                 │  4   │ int          │
│ 0x124(292)│ _static_field_size                    │  4   │ int          │
│ 0x128(296)│ _generic_signature_index              │  2   │ u2           │
│ 0x12A(298)│ _source_file_name_index               │  2   │ u2           │
│ 0x12C(300)│ _static_oop_field_count               │  2   │ u2           │
│ 0x12E(302)│ _java_fields_count                    │  2   │ u2           │
│ 0x130(304)│ _nonstatic_oop_map_size               │  4   │ int          │
│ 0x134(308)│ _itable_len                           │  4   │ int          │
│ 0x138(312)│ _is_marked_dependent                  │  1   │ bool         │
│ 0x139(313)│ _is_being_redefined                   │  1   │ bool         │
│ 0x13A(314)│ _misc_flags                           │  2   │ u2           │
│ 0x13C(316)│ _minor_version                        │  2   │ u2           │
│ 0x13E(318)│ _major_version                        │  2   │ u2           │
│ 0x140(320)│ _init_thread                          │  8   │ Thread*      │
│ 0x148(328)│ _oop_map_cache                        │  8   │ OopMapCache* │
│ 0x150(336)│ _jni_ids                              │  8   │ JNIid*       │
│ 0x158(344)│ _methods_jmethod_ids                  │  8   │ jmethodID*   │
│ 0x160(352)│ _dep_context                          │  8   │ intptr_t     │
│ 0x168(360)│ _osr_nmethods_head                    │  8   │ nmethod*     │
│ 0x170(368)│ _breakpoints (JVMTI)                  │  8   │ BreakpointInfo*│
│ 0x178(376)│ _previous_versions (JVMTI)            │  8   │ InstanceKlass*│
│ 0x180(384)│ _cached_class_file (JVMTI)            │  8   │ JvmtiCachedClassFileData*│
│ 0x188(392)│ _idnum_allocated_count                │  2   │ volatile u2  │
│ 0x18A(394)│ _init_state                           │  1   │ u1           │
│ 0x18B(395)│ _reference_type                       │  1   │ u1           │
│ 0x18C(396)│ _this_class_index                     │  2   │ u2           │
│ 0x18E(398)│ [2-byte hole]                         │  2   │ padding      │
│ 0x190(400)│ _jvmti_cached_class_field_map (JVMTI) │  8   │ JvmtiCachedClassFieldMap*│
│ 0x198(408)│ _verify_count (NOT_PRODUCT)            │  4   │ int          │
│ 0x19C(412)│ [4-byte hole]                         │  4   │ padding      │
│ 0x1A0(416)│ _methods                              │  8   │ Array<Method*>*│
│ 0x1A8(424)│ _default_methods                      │  8   │ Array<Method*>*│
│ 0x1B0(432)│ _local_interfaces                     │  8   │ Array<Klass*>*│
│ 0x1B8(440)│ _transitive_interfaces                │  8   │ Array<Klass*>*│
│ 0x1C0(448)│ _method_ordering                      │  8   │ Array<int>*  │
│ 0x1C8(456)│ _default_vtable_indices               │  8   │ Array<int>*  │
│ 0x1D0(464)│ _fields                               │  8   │ Array<u2>*   │
├──────────┼────────────────────────────────────────┼──────┼──────────────┤
│ header   │ 合计                                    │ 472  │ = 59 words   │
╞══════════╪════════════════════════════════════════╪══════╪══════════════╡
│          │ ═══ 嵌入式变长数据 (header 之后) ═══     │      │              │
│ +472     │ [EMBEDDED Java vtable]                 │ 变长 │ vtableEntry[]│
│ +472+V   │ [EMBEDDED Java itable]                 │ 变长 │ itableEntry[]│
│ +472+V+I │ [EMBEDDED nonstatic oop-map blocks]    │ 变长 │ OopMapBlock[]│
│ ...      │ [EMBEDDED implementor] (仅接口)        │ 0或8 │ Klass*       │
│ ...      │ [EMBEDDED host klass] (仅匿名类)       │ 0或8 │ InstanceKlass*│
│ ...      │ [EMBEDDED fingerprint] (可选)          │ 0或8 │ uint64_t     │
└──────────┴────────────────────────────────────────┴──────┴──────────────┘
```

> **注**: slowdebug 版本包含 `_verify_count` (4 bytes) 和 JVMTI 字段。product 版本中这些字段不存在，`sizeof(InstanceKlass)` 会更小。

### 4.3 InstanceKlass 总大小计算

InstanceKlass 对象的总大小不是固定的，而是根据类的特性动态计算（`instanceKlass.hpp:1063-1073`）：

```cpp
static int size(int vtable_length, int itable_length,
                int nonstatic_oop_map_size,
                bool is_interface, bool is_anonymous, bool has_stored_fingerprint) {
    return align_metadata_size(
           header_size() +              // sizeof(InstanceKlass)/wordSize = 59
           vtable_length +              // Java vtable 条目数
           itable_length +              // Java itable 条目数
           nonstatic_oop_map_size +     // OopMapBlock 数
           (is_interface  ? 1 : 0) +    // implementor 指针
           (is_anonymous  ? 1 : 0) +    // host_klass 指针
           (has_stored_fingerprint ? 1 : 0));  // fingerprint
}
```

**典型大小举例**:

| 类 | header | vtable | itable | oop-map | 其他 | 总计 (words) |
|----|--------|--------|--------|---------|------|-------------|
| java.lang.Object | 59 | 5 | 2 | 0 | 0 | 66 → 528 bytes |
| 简单 POJO (3个方法) | 59 | 8 | 2 | 1 | 0 | 70 → 560 bytes |
| 接口 (Serializable) | 59 | 5 | 0 | 0 | +1(implementor) | 65 → 520 bytes |

### 4.4 核心字段详解

#### 4.4.1 `_constants`（offset 232）——常量池

**是什么**: 指向该类的 `ConstantPool` 对象。

**为什么需要**: 常量池是 .class 文件的核心数据结构，包含了所有字面量（字符串、数字）、类引用、方法引用、字段引用。字节码中的操作数通常是常量池索引。

**读取**: 解释器/编译器通过此指针查找方法签名、字段类型等。  
**写入**: ClassFileParser 解析 .class 文件时创建并填充。

#### 4.4.2 `_methods`（offset 416）——方法数组

**是什么**: `Array<Method*>*`，指向一个 Metaspace 中的 Method 指针数组。

**组织方式**: 数组按方法 ID（`method_idnum`）排序，支持 O(1) 按 ID 查找。方法的原始顺序保存在 `_method_ordering` 中（用于 JVMTI）。

**Method 对象核心字段** (`method.hpp:70-120`):

| 字段 | 类型 | 说明 |
|------|------|------|
| `_constMethod` | ConstMethod* | 只读数据（字节码、行号表、异常表） |
| `_method_data` | MethodData* | 运行时分析数据（分支频率等） |
| `_method_counters` | MethodCounters* | 调用/循环计数器 |
| `_access_flags` | AccessFlags | 方法访问标志 |
| `_vtable_index` | int | 在 vtable 中的索引 |
| `_i2i_entry` | address | 解释器到解释器入口 |
| `_from_compiled_entry` | address | 编译代码入口 |
| `_code` | CompiledMethod* | JIT 编译后的本地代码 |

#### 4.4.3 `_fields`（offset 464）——字段元数据

**是什么**: `Array<u2>*`，每个字段由 6 个 `u2` short 组成（`fieldInfo.hpp:69`）。

```
每个字段的 6-tuple:
[0] access_flags          — 访问修饰符
[1] name_index            — 常量池中字段名索引
[2] signature_index       — 常量池中类型签名索引
[3] initval_index         — 初始值索引（final static 字段）
[4] low_packed            — tag(2bit) + offset/type 信息
[5] high_packed           — offset 高位 或 @Contended group
```

**low_packed 的 tag 编码** (`fieldInfo.hpp:48-53`):
- `00` (blank): 尚未计算 offset
- `01` (offset): 已计算好字段偏移（offset >> 2 存入高位）
- `10` (plain type): 普通类型标记
- `11` (contended type): 带 `@Contended` 注解的字段

#### 4.4.4 `_init_state`（offset 394, 1 byte）——类生命周期状态机

```cpp
// instanceKlass.hpp:133-140
enum ClassState {
  allocated,              // 0 — 已分配（尚未链接）
  loaded,                 // 1 — 已加载到类层次结构
  linked,                 // 2 — 已链接/验证（尚未初始化）
  being_initialized,      // 3 — 正在执行 <clinit>
  fully_initialized,      // 4 — 初始化完成，可以使用
  initialization_error    // 5 — 初始化失败
};
```

**状态转换**:
```
  allocate_instance_klass()     fill_instance_klass()      link_class()
allocated ──────────────────→ loaded ──────────────────→ linked
                                                            │
                              被其他线程使用 ←── fully_initialized
                                                   ↑        │
                                                   │  initialize_impl()
                                                   │        ↓
                                            成功 ←── being_initialized ──→ initialization_error
```

**并发安全**: `_init_thread` 记录正在执行 `<clinit>` 的线程，防止递归初始化死锁。当一个类正在被线程 A 初始化时，如果线程 B 也尝试初始化同一个类，B 会 wait，直到 A 完成（或失败）。

#### 4.4.5 `_misc_flags`（offset 314, 2 bytes）——复合标志位

低 2 位 `kind` 字段区分四种 InstanceKlass 子类型:

```
bit[1:0] = 00 → _misc_kind_other         (普通 InstanceKlass)
bit[1:0] = 01 → _misc_kind_reference     (InstanceRefKlass)
bit[1:0] = 10 → _misc_kind_class_loader  (InstanceClassLoaderKlass)
bit[1:0] = 11 → _misc_kind_mirror        (InstanceMirrorKlass)
```

其余位 (`instanceKlass.hpp:225-241`):

| 位 | 名称 | 说明 |
|----|------|------|
| 2 | `_misc_rewritten` | 方法字节码已重写 |
| 3 | `_misc_has_nonstatic_fields` | 有非静态字段（压缩指针 sizing 用） |
| 4 | `_misc_should_verify_class` | 需要验证 |
| 5 | `_misc_is_anonymous` | 是匿名类（JSR 292） |
| 6 | `_misc_is_contended` | 有 `@Contended` 注解 |
| 7 | `_misc_has_nonstatic_concrete_methods` | 有非静态非抽象方法 |
| 8 | `_misc_declares_nonstatic_concrete_methods` | 直接声明了非静态非抽象方法 |
| 9 | `_misc_has_been_redefined` | 被 JVMTI 重定义过 |
| 15 | `_misc_has_resolved_methods` | 已添加到 resolved methods table |

### 4.5 嵌入式数据详解

#### 4.5.1 Java Vtable（嵌入在 header 之后）

```
嵌入位置: InstanceKlass 地址 + sizeof(InstanceKlass)
          即 this + 472 (59 words)

布局:
┌──────────────┐ ← start_of_vtable()
│ vtableEntry 0│ → Method* (如 Object.hashCode)
│ vtableEntry 1│ → Method* (如 Object.equals)
│ vtableEntry 2│ → Method* (如 Object.toString)
│ ...          │
│ vtableEntry N│ → Method* (最后一个虚方法)
└──────────────┘
```

每个 `vtableEntry` 就是一个 `Method*`（8 bytes, `klassVtable.hpp:204`）。

**invokevirtual 分发过程**:
```
1. 从对象头获取 Klass 指针
2. Klass + vtable_start_offset → vtable 起始地址
3. vtable[method_index] → Method*
4. Method._from_interpreted_entry → 跳转执行
```

> **关键设计** (`arrayKlass.cpp:44-46`): ArrayKlass 的 vtable 也从 `InstanceKlass::header_size()` 偏移开始，即使 ArrayKlass 实际更小（232 bytes vs 472 bytes）。这是为了保证所有 Klass 类型的 `vtable_start_offset()` 统一，解释器和编译器只需一个固定偏移即可找到 vtable。
>
> ```cpp
> int ArrayKlass::static_size(int header_size) {
>   assert(header_size <= InstanceKlass::header_size(), "bad header size");
>   header_size = InstanceKlass::header_size();  // 强制使用 InstanceKlass 的 header_size!
>   ...
> }
> ```

#### 4.5.2 Java Itable（紧跟 vtable 之后）

```
嵌入位置: start_of_vtable() + vtable_length

布局:
── offset table ──────────────
│ itableOffsetEntry 1 │  { Klass* interface_klass, int offset_to_methods }
│ itableOffsetEntry 2 │
│ ...                 │
│ itableOffsetEntry N │
│ sentinel (NULL, 0)  │
── method tables ─────────────
│ itableMethodEntry 1 │  { Method* }
│ itableMethodEntry 2 │
│ ...                 │
```

**invokeinterface 分发过程**:
```
1. 遍历 offset table 找到目标接口的 itableOffsetEntry
2. 用 offset 跳到对应的 method table
3. method_table[method_index] → Method*
```

#### 4.5.3 Nonstatic OopMap Blocks（紧跟 itable 之后）

```
嵌入位置: start_of_itable() + itable_length

OopMapBlock:
┌─────────────┐
│ _offset (4B)│ ← oop 字段在实例中的字节偏移
│ _count  (4B)│ ← 从 offset 开始连续的 oop 字段个数
└─────────────┘ 8 bytes per block

例: 类有 3 个连续 oop 字段从 offset 16 开始
    → OopMapBlock { offset=16, count=3 }
```

**用途**: GC 扫描对象实例中的 oop 引用时，不需要遍历字段列表，直接读 OopMapBlock 就知道哪些偏移处有 oop 指针需要处理。

---

## 第五章 ArrayKlass——数组类型的表示

### 5.1 ArrayKlass (232 bytes)

```
【GDB 验证】ptype /o ArrayKlass
┌──────────┬────────────────────────────────────────┬──────┬──────────────┐
│ 偏移     │ 字段名                                  │ 大小 │ 类型          │
├──────────┼────────────────────────────────────────┼──────┼──────────────┤
│ 0-207    │ (继承自 Klass)                          │ 208  │              │
│ 208      │ _dimension                             │  4   │ int          │
│ 212      │ [4-byte hole]                          │  4   │ padding      │
│ 216      │ _higher_dimension                      │  8   │ Klass* volatile│
│ 224      │ _lower_dimension                       │  8   │ Klass* volatile│
├──────────┼────────────────────────────────────────┼──────┼──────────────┤
│ 总计     │                                        │ 232  │              │
└──────────┴────────────────────────────────────────┴──────┴──────────────┘
```

#### 5.1.1 维度链

ArrayKlass 通过 `_higher_dimension` 和 `_lower_dimension` 构建多维数组的双向链表：

```
int[]  ←──lower──  int[][]  ←──lower──  int[][][]
  ──higher──→         ──higher──→

_dimension = 1         = 2                = 3
```

当创建 `int[][][]` 时，会懒加载创建 `int[][]` 和 `int[]` 的 Klass。

#### 5.1.2 ArrayKlass 实际占用大小

ArrayKlass 虽然只有 232 bytes 的字段，但实际分配大小更大：

```cpp
// arrayKlass.cpp:44
int ArrayKlass::static_size(int header_size) {
    header_size = InstanceKlass::header_size();  // 强制 = 59 words = 472 bytes!
    int vtable_len = Universe::base_vtable_size(); // 通常 = 5 (Object 的 vtable)
    return align_metadata_size(header_size + vtable_len);
    // = align(59 + 5) = 64 words = 512 bytes
}
```

所以 ArrayKlass 实际占 **512 bytes**（包含 472 bytes header padding + 5 个 vtable entries）。这是因为 vtable 必须从统一的偏移开始。

### 5.2 ObjArrayKlass (248 bytes)

```
┌──────────┬────────────────────────────────────────┬──────┬──────────────┐
│ 偏移     │ 字段名                                  │ 大小 │ 类型          │
├──────────┼────────────────────────────────────────┼──────┼──────────────┤
│ 0-231    │ (继承自 ArrayKlass)                     │ 232  │              │
│ 232      │ _element_klass                         │  8   │ Klass*       │
│ 240      │ _bottom_klass                          │  8   │ Klass*       │
├──────────┼────────────────────────────────────────┼──────┼──────────────┤
│ 总计     │                                        │ 248  │              │
└──────────┴────────────────────────────────────────┴──────┴──────────────┘
```

**两个关键指针**:
- `_element_klass`: 数组元素的直接类型。对于 `String[][]`，element_klass 是 `String[]` 的 ObjArrayKlass
- `_bottom_klass`: 数组的最底层非数组类型。对于 `String[][]`，bottom_klass 是 `String` 的 InstanceKlass

**用途**: `protection_domain()` 委托给 `bottom_klass()`，因为数组的保护域由其元素类型决定。

### 5.3 TypeArrayKlass (240 bytes)

```
┌──────────┬────────────────────────────────────────┬──────┬──────────────┐
│ 偏移     │ 字段名                                  │ 大小 │ 类型          │
├──────────┼────────────────────────────────────────┼──────┼──────────────┤
│ 0-231    │ (继承自 ArrayKlass)                     │ 232  │              │
│ 232      │ _max_length                            │  4   │ jint         │
│ 236      │ [4-byte padding]                       │  4   │ padding      │
├──────────┼────────────────────────────────────────┼──────┼──────────────┤
│ 总计     │                                        │ 240  │              │
└──────────┴────────────────────────────────────────┴──────┴──────────────┘
```

**`_max_length`**: 该基本类型数组允许的最大长度。对于 `int[]`，`_max_length = (max_heap_size - header_size) / sizeof(int)`，防止分配过大的数组导致溢出。

**特点**: TypeArrayKlass 没有 oop 字段，GC 不需要遍历其实例的内容，只需要计算对象大小跳过即可。

### 5.4 _layout_helper 数组编码示例

| 数组类型 | tag | header_size | element_type | log2(esz) | layout_helper (hex) |
|---------|-----|-------------|-------------|-----------|-------------------|
| `boolean[]` | 0xC0 | 16 | T_BOOLEAN(4) | 0 | 0xC0001000 |
| `byte[]` | 0xC0 | 16 | T_BYTE(8) | 0 | 0xC0001800 |
| `char[]` | 0xC0 | 16 | T_CHAR(5) | 1 | 0xC0001501 |
| `short[]` | 0xC0 | 16 | T_SHORT(9) | 1 | 0xC0001901 |
| `int[]` | 0xC0 | 16 | T_INT(10) | 2 | 0xC0001A02 |
| `long[]` | 0xC0 | 16 | T_LONG(11) | 3 | 0xC0001B03 |
| `float[]` | 0xC0 | 16 | T_FLOAT(6) | 2 | 0xC0001602 |
| `double[]` | 0xC0 | 16 | T_DOUBLE(7) | 3 | 0xC0001703 |
| `Object[]` | 0x80 | 16 | T_OBJECT(12) | 2 | 0x80001C02 |

> 注: `Object[]` 在使用压缩 oop 时 element_size=4 (log2=2), 不压缩时 element_size=8 (log2=3)。

---

## 第六章 三个 InstanceKlass 特化子类

### 6.1 InstanceMirrorKlass——java.lang.Class 的特殊处理

**唯一额外字段**: `static int _offset_of_static_fields`

**特殊之处**: `java.lang.Class` 的实例是**变长**的。每个 `java.lang.Class` 实例除了自身的字段，还包含了所代表类的**所有静态字段**。

```
java.lang.Class 实例（在 Java 堆中）的内存布局:
┌──────────────────────────────────────────┐
│ markWord                                 │  8 bytes
│ klass 指针 (→ InstanceMirrorKlass)       │  4 bytes (压缩)
│ java.lang.Class 自身的实例字段            │  ...
│ [隐藏的 Klass* 指针]                     │  8 bytes ← 指回 Metaspace 中的 InstanceKlass
│ ────── _offset_of_static_fields ──────   │
│ 所代表类的 static 字段 1                  │  ...
│ 所代表类的 static 字段 2                  │  ...
│ ...                                      │
└──────────────────────────────────────────┘
```

**为什么静态字段不存在 InstanceKlass 中？** 因为静态字段可能是 oop 类型（如 `static Object ref`），而 Metaspace 不在 Java 堆中，GC 遍历堆时不会扫描 Metaspace。把静态 oop 放在 Java 堆中的 Class 实例里，GC 可以自然地发现和更新这些引用。

### 6.2 InstanceRefKlass——Reference 子类的 GC 特殊处理

**没有额外字段**。只是覆写了 GC 迭代器方法。

**特殊处理**: `java.lang.ref.Reference` 子类（SoftReference、WeakReference、FinalReference、PhantomReference）有三个特殊字段：
- `referent`: 引用的目标对象
- `next`: 引用队列链表
- `discovered`: GC 发现链表

在 GC 标记阶段，`referent` 字段**不作为普通 oop 遍历**，而是走引用处理的特殊路径：先收集到待处理列表，等标记完成后再决定是否需要清理。

`InstanceRefKlass::update_nonstatic_oop_maps()` 方法会修改 oop-map，使 referent/next/discovered 字段从普通 oop 遍历中"隐藏"。

### 6.3 InstanceClassLoaderKlass——ClassLoader 的 GC 可达性

**没有额外字段**。只是覆写了 GC 迭代器方法。

**特殊处理**: 当 GC 遍历一个 ClassLoader 实例时，除了正常遍历实例字段外，还需要额外保持该 ClassLoader 的 `ClassLoaderData` 存活。因为 `ClassLoaderData` 中持有了该 ClassLoader 加载的所有类的 Klass 指针，如果 ClassLoaderData 被回收，这些类就会被卸载。

---

## 第七章 InstanceKlass 的创建流程

### 7.1 完整调用链

```
ClassFileParser::parse_stream()           ← 解析 .class 字节流
    │
ClassFileParser::create_instance_klass()  ← 外部入口
    │
    ├── InstanceKlass::allocate_instance_klass(parser)  (instanceKlass.cpp:345)
    │   │
    │   ├── 计算 size = header_size + vtable + itable + oop_map + ...
    │   │
    │   ├── 根据类类型选择构造函数:
    │   │   ├── java.lang.Class        → new InstanceMirrorKlass(parser)
    │   │   ├── ClassLoader 子类       → new InstanceClassLoaderKlass(parser)
    │   │   ├── Reference 子类         → new InstanceRefKlass(parser)
    │   │   └── 其他                   → new InstanceKlass(parser, _misc_kind_other)
    │   │
    │   └── operator new(size, loader_data, word_size)
    │       └── Metaspace::allocate()  ← 在 Metaspace 中分配（零初始化）
    │
    └── ClassFileParser::fill_instance_klass(ik)
        ├── set_name(), set_class_loader_data()
        ├── set_methods(), set_fields(), set_inner_classes()
        ├── set_local_interfaces(), set_transitive_interfaces()
        ├── initialize_supers()       ← 初始化 _primary_supers[] 和 _secondary_supers[]
        ├── vtable().initialize_vtable()   ← 初始化 Java vtable
        ├── itable().initialize_itable()   ← 初始化 Java itable
        └── java_lang_Class::create_mirror()  ← 创建 java.lang.Class 镜像
```

### 7.2 构造函数细节

```cpp
// instanceKlass.cpp:409-430
InstanceKlass::InstanceKlass(const ClassFileParser& parser, unsigned kind, KlassID id) :
  Klass(id),                                           // 基类初始化
  _static_field_size(parser.static_field_size()),
  _nonstatic_oop_map_size(nonstatic_oop_map_size(parser.total_oop_map_count())),
  _itable_len(parser.itable_size()),
  _init_thread(NULL),
  _init_state(allocated),                              // 初始状态 = allocated
  _reference_type(parser.reference_type()),
  _nest_members(NULL), _nest_host_index(0), _nest_host(NULL) {
    set_vtable_length(parser.vtable_size());
    set_kind(kind);
    set_access_flags(parser.access_flags());
    set_is_anonymous(parser.is_anonymous());
    set_layout_helper(Klass::instance_layout_helper(parser.layout_size(), false));
    
    assert(NULL == _methods, "underlying memory not zeroed?");  // Metaspace 已零初始化
}
```

**关键设计点**:
1. Metaspace 分配的内存是**零初始化**的，所以构造函数不需要显式设置所有指针字段为 NULL
2. `_init_state` 初始为 `allocated`，后续经过 `loaded` → `linked` → `fully_initialized` 状态转换
3. `_layout_helper` 在构造时就设置好，后续对象分配可以直接使用

---

## 第八章 Klass 与其他子系统的关联

### 8.1 全局关联关系图

```
                                    ┌───────────────────┐
                                    │  ClassFileParser   │
                                    │  (.class → Klass)  │
                                    └────────┬──────────┘
                                             │ create_instance_klass()
                                             ▼
┌─────────────┐    _class_loader_data    ┌───────────────────┐    _constants
│ClassLoaderData│←────────────────────── │   InstanceKlass    │──────────────→ ConstantPool
│              │  _next_link (类链表)    │   (472+ bytes)     │
│  _class_loader│                        │                    │    _methods
│  _klasses    │                        │                    │──────────────→ Array<Method*>
└─────────────┘                         │                    │
       ↕                                │                    │    _fields
  java.lang.ClassLoader                 │  _java_mirror      │──────────────→ Array<u2>
  (Java 堆中)                          │──────→ java.lang.Class│
                                        │       (Java 堆中)   │    _local_interfaces
                                        │                    │──────────────→ Array<Klass*>
   ┌──────────────────────┐             │  _super            │
   │   Java Object (oop)  │             │──────→ 父类 Klass   │    embedded:
   │  ┌─────────────┐     │             │                    │    [vtable]
   │  │ _metadata   │─────┼──compressed │  _subklass         │    [itable]
   │  │   ._klass   │     │    klass ──→│──────→ 子类 Klass   │    [oop-map]
   │  └─────────────┘     │             │                    │
   └──────────────────────┘             │  _primary_supers[8]│
                                        │──────→ 快速子类型检查│
                                        └───────────────────┘
                                          ↑           ↑
                              TypeArrayKlass      ObjArrayKlass
                              (int[]/byte[]等)    (Object[]/String[]等)
                              _max_length         _element_klass
                                                  _bottom_klass
```

### 8.2 与 GC 的关系

GC 需要从 Klass 获取的信息：

| 信息 | 来源 | 用途 |
|------|------|------|
| 对象大小 | `_layout_helper` | 计算对象大小以推进扫描指针 |
| oop 字段位置 | embedded oop-map blocks | 精确定位实例中的 oop 引用 |
| 是否是引用类型 | KlassID == InstanceRefKlassID | 特殊处理 referent 字段 |
| 是否是类加载器 | KlassID == InstanceClassLoaderKlassID | 额外保持 CLD 存活 |
| 数组元素类型 | `_layout_helper` 解码 | 判断数组元素是否是 oop |

### 8.3 与解释器/编译器的关系

| 操作 | 使用的 Klass 信息 |
|------|-----------------|
| `new` 字节码 | `_layout_helper`（对象大小）, `_init_state`（是否已初始化） |
| `invokevirtual` | embedded vtable[index] → Method* |
| `invokeinterface` | embedded itable → Method* |
| `instanceof`/`checkcast` | `_primary_supers[]`, `_secondary_supers[]`, `_super_check_offset` |
| `getfield`/`putfield` | `_fields` 中的 offset |
| `getstatic`/`putstatic` | `_java_mirror` → Class 实例 → 静态字段区 |

---

## 第九章 JVM 参数与日志

### 9.1 类加载相关参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-verbose:class` | false | 打印类加载/卸载信息 |
| `-Xlog:class+load=info` | - | 统一日志：类加载详情 |
| `-Xlog:class+unload=info` | - | 统一日志：类卸载详情 |
| `-XX:+TraceClassLoading` | false | 等效于 `-Xlog:class+load=info` |
| `-XX:+TraceClassUnloading` | false | 等效于 `-Xlog:class+unload=info` |

**日志输出示例** (`-Xlog:class+load=info`):
```
[0.008s][info][class,load] java.lang.Object source: jrt:/java.base
[0.009s][info][class,load] java.io.Serializable source: jrt:/java.base
[0.010s][info][class,load] java.lang.Comparable source: jrt:/java.base
[0.010s][info][class,load] java.lang.CharSequence source: jrt:/java.base
[0.011s][info][class,load] java.lang.String source: jrt:/java.base
```

### 9.2 Metaspace 相关参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-XX:MetaspaceSize` | ~21MB | Metaspace 初始大小（触发 GC 的阈值） |
| `-XX:MaxMetaspaceSize` | 无限 | Metaspace 最大大小 |
| `-XX:CompressedClassSpaceSize` | 1GB | 压缩类空间大小（Klass 分配在这里） |
| `-Xlog:metaspace` | - | Metaspace 分配/回收日志 |

---

## 第十章 面试高频问题

### Q1: Java 对象和 Java 类在 JVM 中分别怎么表示？

**快速答**: 对象用 oop（oopDesc），类用 Klass。oop 在 Java 堆中，通过对象头的 klass 指针指向 Metaspace 中的 Klass。

**深入答**: HotSpot 采用 oop/klass 二分法。oop 不包含 C++ vtable，节省内存。Klass 包含类的全部元数据：虚方法表、字段布局、常量池、继承关系等。InstanceKlass 是最常见的类型，472 bytes header + 变长的嵌入式 vtable/itable/oop-map。

### Q2: InstanceKlass 有多大？

**快速答**: header 472 bytes（slowdebug），加上变长的 vtable、itable、oop-map blocks。

**深入答**: `InstanceKlass::size()` = `header_size() + vtable_length + itable_length + nonstatic_oop_map_size + (接口?1:0) + (匿名?1:0) + (fingerprint?1:0)`。以 java.lang.Object 为例，约 528 bytes (66 words)。

### Q3: 为什么 ArrayKlass 的 vtable 要从 InstanceKlass::header_size() 偏移开始？

**快速答**: 为了统一所有 Klass 类型的 vtable 起始偏移，解释器和编译器只需一个固定常量即可找到 vtable。

**深入答**: `Klass::vtable_start_offset()` 硬编码返回 `InstanceKlass::header_size() * wordSize`。如果 ArrayKlass 用自己更小的 header_size，所有 vtable 访问代码都需要区分类型，增加复杂度。代价是 ArrayKlass 的 header 和 vtable 之间有未使用的空洞。

### Q4: 为什么 java.lang.Class 的实例包含静态字段？

**快速答**: 静态字段可能是 oop 引用，放在 Java 堆中的 Class 实例里可以被 GC 自然扫描。

**深入答**: Klass 在 Metaspace 中，GC 扫描 Java 堆时不扫描 Metaspace。如果静态 oop 字段存在 Klass 中，GC 需要额外机制来发现这些引用。把静态字段放在 Class 实例（Java 堆中），GC 遍历堆时自然能扫描到。InstanceMirrorKlass 覆写了 `oop_size()` 以包含这些变长的静态字段。

### Q5: Klass 分配在哪里？

**快速答**: Metaspace 中，通过 `Metaspace::allocate()` 分配。

**深入答**: `Klass::operator new()` 调用 `Metaspace::allocate(loader_data, word_size, MetaspaceObj::ClassType)`。如果启用了压缩类指针 (`UseCompressedClassPointers`)，Klass 分配在专用的 Compressed Class Space 中（默认 1GB），这样 klass 指针可以用 32-bit narrowKlass 表示，节省对象头空间。

---

## 第十一章 GDB 验证指南

### 11.1 查看 InstanceKlass 完整信息

```bash
# 断点设置
b InstanceKlass::allocate_instance_klass
# 跳过系统类，等待应用类
condition 1 parser._class_name->_body[0]=='c'  # 匹配 com.xxx

# 运行
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# 查看 InstanceKlass 类型信息
ptype /o InstanceKlass

# 查看具体实例的字段值
set $ik = (InstanceKlass*)this
printf "class: %s\n", $ik->_name->_body
printf "layout_helper: %d\n", $ik->_layout_helper
printf "vtable_len: %d\n", $ik->_vtable_len
printf "itable_len: %d\n", $ik->_itable_len
printf "methods count: %d\n", $ik->_methods->_length
printf "fields count: %d\n", $ik->_java_fields_count
printf "init_state: %d\n", (int)$ik->_init_state
```

### 11.2 查看 Java 对象的 Klass 信息

```bash
# 获取一个 Java 对象的 klass
set $obj = (oopDesc*)0x????????
set $klass = (InstanceKlass*)$obj->_metadata._compressed_klass  # 需要解码
# 或
set $klass = (InstanceKlass*)$obj->_metadata._klass  # 非压缩模式

printf "class: %s\n", $klass->_name->_body
printf "instance_size: %d bytes\n", $klass->_layout_helper
```

### 11.3 遍历 vtable

```bash
set $ik = (InstanceKlass*)0x????????
set $vtable = (vtableEntry*)((char*)$ik + sizeof(InstanceKlass))
set $i = 0
while $i < $ik->_vtable_len
  set $m = $vtable[$i]._method
  if $m != 0
    printf "vtable[%d]: %s\n", $i, $m->_constMethod->_constants->symbol_at($m->_constMethod->_name_index)->_body
  end
  set $i = $i + 1
end
```

---

## 第十二章 源文件索引

| 文件 | 路径 | 核心内容 |
|------|------|---------|
| klass.hpp | `src/hotspot/share/oops/klass.hpp` | Klass 基类定义 (733 行) |
| klass.cpp | `src/hotspot/share/oops/klass.cpp` | Klass 构造函数、operator new (932 行) |
| instanceKlass.hpp | `src/hotspot/share/oops/instanceKlass.hpp` | InstanceKlass 完整定义 (1493 行) |
| instanceKlass.cpp | `src/hotspot/share/oops/instanceKlass.cpp` | 创建/初始化/方法查找 (4019 行) |
| arrayKlass.hpp | `src/hotspot/share/oops/arrayKlass.hpp` | ArrayKlass 基类 (151 行) |
| arrayKlass.cpp | `src/hotspot/share/oops/arrayKlass.cpp` | ArrayKlass 构造/大小计算 (251 行) |
| objArrayKlass.hpp | `src/hotspot/share/oops/objArrayKlass.hpp` | ObjArrayKlass (189 行) |
| typeArrayKlass.hpp | `src/hotspot/share/oops/typeArrayKlass.hpp` | TypeArrayKlass (153 行) |
| instanceMirrorKlass.hpp | `src/hotspot/share/oops/instanceMirrorKlass.hpp` | java.lang.Class 的 Klass (137 行) |
| instanceRefKlass.hpp | `src/hotspot/share/oops/instanceRefKlass.hpp` | Reference 子类的 Klass (152 行) |
| instanceClassLoaderKlass.hpp | `src/hotspot/share/oops/instanceClassLoaderKlass.hpp` | ClassLoader 的 Klass (83 行) |
| metadata.hpp | `src/hotspot/share/oops/metadata.hpp` | Metadata 基类 (89 行) |
| oopsHierarchy.hpp | `src/hotspot/share/oops/oopsHierarchy.hpp` | oop/Klass 类型体系 (224 行) |
| klassVtable.hpp | `src/hotspot/share/oops/klassVtable.hpp` | vtable/itable 定义 (356 行) |
| method.hpp | `src/hotspot/share/oops/method.hpp` | Method 元数据 (1190 行) |
| fieldInfo.hpp | `src/hotspot/share/oops/fieldInfo.hpp` | 字段信息编码 (258 行) |
| accessFlags.hpp | `src/hotspot/share/utilities/accessFlags.hpp` | 访问标志 (291 行) |
| markOop.hpp | `src/hotspot/share/oops/markOop.hpp` | 对象头 mark word (399 行) |
| classFileParser.hpp | `src/hotspot/share/classfile/classFileParser.hpp` | .class 解析器 (554 行) |
| classFileParser.cpp | `src/hotspot/share/classfile/classFileParser.cpp` | 创建 InstanceKlass 入口 |

---

*最后更新: 2026-02-08*
