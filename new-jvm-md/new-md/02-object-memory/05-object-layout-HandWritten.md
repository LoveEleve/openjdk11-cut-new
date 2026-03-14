# 对象内存布局 — 我的踩坑笔记

> 对应现有文档：`ObjectModel/1-Oop-Klass-Architecture-Deep-Dive.md`  
> 风格参考：`/data/workspace/redis-7.0/src/md/cluster/Cluster-HandWritten.md`  
> 核心原则：**第一人称 · 学习时间线 · 真实踩坑 · 源码级深度**

---

## 第零天：我以为 new Object() 就是 malloc 一块内存

我以为 Java 对象在内存里就是一块连续的内存，前面几个字节是"类型信息"，后面是字段数据。就像 C 的 struct 一样。

```c
// 我以为的模型（C 风格）：
struct JavaObject {
    void* class_ptr;   // 指向类信息
    int field1;
    String field2;
    // ...
};
```

结果翻开源码，发现这个模型有四处根本性的错误：

1. 对象头不是"一个类型指针"，而是**两个字段**：`_mark`（8 字节）+ `_klass`（4 或 8 字节）
2. `_mark`（MarkWord）不是简单的标志位，而是一个**状态机**，5 种状态下位域布局完全不同
3. `_klass` 在开启压缩指针时只有 **4 字节**（不是 8 字节），而且存的是偏移量不是绝对地址
4. 对象头大小不是固定的：普通对象 **12 字节**（压缩）或 **16 字节**（不压缩），数组对象还要多 4 字节

这四个误解，我花了两天才全部搞清楚。

---

## 第一天：我踩的第一个坑 — 对象头到底有几个字段？

### 坑：我以为对象头就是"一个类型指针"

我以为对象头就是一个指向 `Class` 对象的指针，8 字节，仅此而已。

结果看了 `oop.hpp:55`，对象头是**两个字段**：

```cpp
// oop.hpp:55-63
class oopDesc {
  friend class VMStructs;
  friend class JVMCIVMStructs;
 private:
  // ★ 第一个字段：MarkWord（8 字节，固定）
  volatile markOop _mark;

  // ★ 第二个字段：类指针（union，4 或 8 字节，取决于压缩指针）
  union _metadata {
    Klass*      _klass;             // 64 位指针（8 字节）
    narrowKlass _compressed_klass;  // 32 位压缩指针（4 字节）
  } _metadata;
};
```

**两个字段，不是一个。**

`_mark` 是 MarkWord，存锁状态、GC 年龄、hashCode。`_klass` 才是类型指针，指向 Metaspace 里的 `InstanceKlass`。

### 为什么要分成两个字段？

我当时想：为什么不把锁状态、年龄、hashCode 都放到 `InstanceKlass` 里？

答案是：这些信息是**每个对象实例独有的**，不是类共享的。

- 锁状态：每个对象可以被不同线程锁住
- GC 年龄：每个对象的晋升年龄不同
- hashCode：每个对象的 identity hash 不同

如果放到 `InstanceKlass`，就变成了"所有 String 对象共享同一个锁状态"，这显然不对。

所以 `_mark` 必须在每个对象实例里，而 `_klass` 指向共享的类元数据。

---

## 第一天半：数据结构补课

我第二天看 `MemAllocator::finish()` 的时候，发现自己完全不知道 `prototype_header()` 是什么，也不知道 `release_set_klass` 和 `set_klass` 有什么区别，更不知道 `narrowKlass` 是怎么解码成 `Klass*` 的。回来补课。

### oopDesc — 所有对象的基类

```cpp
// oop.hpp:55-63
class oopDesc {
 private:
  volatile markOop _mark;       // 偏移 0，8 字节，MarkWord
  union _metadata {
    Klass*      _klass;         // 偏移 8，8 字节（未压缩）
    narrowKlass _compressed_klass; // 偏移 8，4 字节（压缩）
  } _metadata;
};
```

**sizeof(oopDesc) = 16 字节**（GDB 验证，未压缩模式）

**内存布局**：

```
oopDesc 内存布局（64位系统）：

开启压缩类指针（UseCompressedClassPointers=true，默认）：
偏移   字段                    大小
 0     _mark (volatile markOop)  8 字节  ← MarkWord
 8     _compressed_klass (narrowKlass)  4 字节  ← 压缩类指针
12     [klass_gap / 字段起始]    4 字节  ← 对齐填充 or 字段
总对象头：12 字节

关闭压缩类指针（UseCompressedClassPointers=false）：
偏移   字段                    大小
 0     _mark (volatile markOop)  8 字节  ← MarkWord
 8     _klass (Klass*)           8 字节  ← 完整类指针
16     [字段起始]                -
总对象头：16 字节
```

**关键字段生命周期**：

| 字段 | 谁设置 | 何时设置 | 设置什么值 | 谁读取 |
|------|--------|---------|-----------|--------|
| `_mark` | `MemAllocator::finish()` | 对象创建时 | `prototype_header()` 或 `markOopDesc::prototype()` | synchronized / hashCode / GC |
| `_mark` | `ObjectSynchronizer::enter()` | 加锁时 | BasicLock* / ObjectMonitor* | synchronized |
| `_mark` | `ObjectSynchronizer::FastHashCode()` | 首次 hashCode 时 | 写入 hash 位域 | `System.identityHashCode()` |
| `_mark` | GC 线程 | 标记/晋升时 | age++ / forwarding ptr | GC |
| `_klass` | `MemAllocator::finish()` | 对象创建时（最后设置！） | 指向 InstanceKlass | invokevirtual / instanceof / GC |

**为什么 `_klass` 最后设置？**

```cpp
// memAllocator.cpp:405-408
// Need a release store to ensure array/class length, mark word, and
// object zeroing are visible before setting the klass non-NULL, for
// concurrent collectors.
oopDesc::release_set_klass(mem, _klass);
```

并发 GC 用 `_klass != NULL` 作为"对象可解析"的信号。如果先设置 `_klass`，GC 可能读到未初始化的 `_mark` 或字段数据。所以必须最后设置，且用 `release_store`（写屏障）保证之前的写操作对 GC 线程可见。

### markOopDesc — MarkWord 的位域布局

这是我最没想到的设计：8 字节的 MarkWord 根据锁状态，位域布局**完全不同**。

```cpp
// markOop.hpp:111-154
// 位域大小定义
enum {
    age_bits         = 4,    // GC 年龄：4 位，最大 15
    lock_bits        = 2,    // 锁状态：2 位
    biased_lock_bits = 1,    // 偏向锁标志：1 位
    hash_bits        = 31,   // identity hash：31 位（max_hash_bits > 31 ? 31 : max_hash_bits）
    epoch_bits       = 2     // 偏向锁 epoch：2 位
};

// 位域偏移定义
enum {
    lock_shift        = 0,                              // lock 在最低 2 位
    biased_lock_shift = lock_bits,                      // biased_lock 在 bit 2
    age_shift         = lock_bits + biased_lock_bits,   // age 在 bit 3-6
    cms_shift         = age_shift + age_bits,           // cms 在 bit 7（1 位）
    hash_shift        = cms_shift + cms_bits,           // hash 在 bit 8-38
    epoch_shift       = hash_shift                      // epoch 和 hash 共用高位（偏向锁状态下）
};

// 锁状态值
enum {
    locked_value        = 0,   // 00 - 轻量级锁（ptr 指向 BasicLock）
    unlocked_value      = 1,   // 01 - 无锁
    monitor_value       = 2,   // 10 - 重量级锁（ptr 指向 ObjectMonitor）
    marked_value        = 3,   // 11 - GC 标记
    biased_lock_pattern = 5    // 101 - 偏向锁（biased_lock=1, lock=01）
};
```

**5 种状态下的完整位域图**：

```
64 位 MarkWord 位域布局（从低位到高位）：

无锁状态（lock=01, biased=0）：
bit: 63                                                              0
     [unused:25][hash:31][unused:1][age:4][biased:1=0][lock:2=01]
     ↑高位                                                    低位↑

偏向锁状态（lock=01, biased=1）：
bit: 63                                                              0
     [JavaThread*:54][epoch:2][unused:1][age:4][biased:1=1][lock:2=01]
     ↑高位                                                    低位↑

轻量级锁状态（lock=00）：
bit: 63                                                              0
     [BasicLock* ptr:62                                    ][lock:2=00]
     ↑高位                                                    低位↑

重量级锁状态（lock=10）：
bit: 63                                                              0
     [ObjectMonitor* ptr:62                                ][lock:2=10]
     ↑高位                                                    低位↑

GC 标记状态（lock=11）：
bit: 63                                                              0
     [forwarding ptr:62                                    ][lock:2=11]
     ↑高位                                                    低位↑
```

**关键设计**：最低 2 位（lock bits）是所有状态的"路由器"：

```
lock=00 → 轻量级锁，高 62 位是 BasicLock* 指针
lock=01 → 无锁或偏向锁，看 bit 2（biased_lock bit）
lock=10 → 重量级锁，高 62 位是 ObjectMonitor* 指针
lock=11 → GC 标记，高 62 位是 forwarding pointer
```

**为什么指针可以存在高 62 位？**

因为对象是 8 字节对齐的，所以所有对象地址的低 3 位都是 0。`BasicLock*` 和 `ObjectMonitor*` 也是对齐的，低 2 位天然是 0。把低 2 位用来存锁状态，不影响指针的有效性（解引用前先清掉低 2 位即可）。

### instanceOopDesc — 普通对象实例

```cpp
// instanceOop.hpp:33-52
class instanceOopDesc : public oopDesc {
 public:
  // ★ 没有任何新增字段！完全继承 oopDesc
  static int header_size() { return sizeof(instanceOopDesc)/HeapWordSize; }

  // 字段起始偏移（Java 字段从这里开始）
  static int base_offset_in_bytes() {
    // 开启压缩指针：字段从 klass_gap 之后开始（偏移 12）
    // 关闭压缩指针：字段从 oopDesc 大小之后开始（偏移 16）
    return (UseCompressedOops && UseCompressedClassPointers) ?
             klass_gap_offset_in_bytes() :
             sizeof(instanceOopDesc);
  }
};
```

**关键发现**：`instanceOopDesc` **没有任何新增字段**。普通 Java 对象的内存布局就是 `oopDesc` 的布局，Java 字段紧跟在对象头之后。

**实例：`new Person(age=25, name="Alice")` 的内存布局**（开启压缩指针）：

```
偏移   内容                    大小
 0     MarkWord（无锁原型）     8 字节  = 0x0000_0000_0000_0001
 8     narrowKlass（压缩类指针）4 字节  → 解码后指向 Person 的 InstanceKlass
12     int age = 25            4 字节
16     String name（narrowOop）4 字节  → 解码后指向 "Alice" 的 instanceOopDesc
20     [padding]               4 字节  （8 字节对齐）
总大小：24 字节
```

### arrayOopDesc — 数组对象

```cpp
// arrayOop.hpp:51-115
class arrayOopDesc : public oopDesc {
 public:
  // ★ 数组比普通对象多一个 length 字段（4 字节）
  // 但 length 不是 C++ 字段，而是通过偏移量访问的！
  static int length_offset_in_bytes() {
    // 开启压缩指针：length 在 klass_gap 位置（偏移 12）
    // 关闭压缩指针：length 在 oopDesc 之后（偏移 16）
    return UseCompressedClassPointers ? klass_gap_offset_in_bytes() :
                               sizeof(arrayOopDesc);
  }

  // 获取数组长度
  int length() const {
    return *(int*)(((intptr_t)this) + length_offset_in_bytes());
  }

  // 设置数组长度（静态版本，用于初始化）
  static void set_length(HeapWord* mem, int length) {
    *(int*)(((char*)mem) + length_offset_in_bytes()) = length;
  }
};
```

**关键发现**：数组的 `length` 字段**复用了 klass_gap 的位置**！

开启压缩指针时：
- `_mark`（8 字节）+ `_compressed_klass`（4 字节）= 12 字节
- 后面有 4 字节的 `klass_gap`（对齐填充）
- 数组把这 4 字节的 `klass_gap` 用来存 `length`

这是一个非常精妙的设计：数组头大小和普通对象头大小相同（都是 16 字节，8 字节对齐），没有额外开销。

**实例：`new int[10]` 的内存布局**（开启压缩指针）：

```
偏移   内容                    大小
 0     MarkWord（无锁原型）     8 字节
 8     narrowKlass（压缩类指针）4 字节  → 指向 int[] 的 TypeArrayKlass
12     length = 10             4 字节  ← 复用 klass_gap！
16     int[0] = 0              4 字节
20     int[1] = 0              4 字节
...
52     int[9] = 0              4 字节
56     [padding]               4 字节  （8 字节对齐）
总大小：60 字节
```

**插桩验证数据**（来自 `Instrumentation/03-ObjectAlloc-Probe-Results.md`）：

```
[GDB] 分配 int[3145728]（3MB 数组）：
  实际分配 size = 3145744 字节
  Java 层 length = 3145728 * 4 = 12582912 字节
  差值 = 3145744 - 12582912 = ... 等等，这不对

[重新计算]
  int[3145728] 的元素数据 = 3145728 * 4 = 12582912 字节
  对象头 = 16 字节（mark 8 + klass 4 + length 4）
  总大小 = 12582912 + 16 = 12582928 字节

[实测]
  top-start = 16 字节（对象头大小，mark word 8B + klass pointer 8B）
  ★ 注意：这里是关闭压缩指针的环境，所以 klass 是 8 字节
```

---

## 第二天：压缩指针 — 我以为只是"省内存的小优化"

### 坑：我以为压缩指针只是把 8 字节指针压成 4 字节

我以为压缩指针就是简单地把 64 位地址截断成 32 位，然后用的时候再补零。

结果看了源码，压缩指针是**移位编码**，不是截断：

```
压缩（encode）：narrowOop = (real_addr - heap_base) >> 3
解压（decode）：real_addr = (narrowOop << 3) + heap_base
```

**为什么是移位 3 位（除以 8）？**

因为对象是 8 字节对齐的，所有对象地址的低 3 位都是 0。存储时把低 3 位去掉（右移 3），读取时再补回来（左移 3）。

这样 32 位可以表示的地址范围就从 4GB 扩展到了 32GB（4G * 8 = 32GB）。

**两种压缩指针**：

| 类型 | 字段 | 大小 | 最大范围 | 默认开启条件 |
|------|------|------|---------|------------|
| `UseCompressedOops` | 对象引用字段 | 4B | 32GB 堆 | 堆 ≤ 32GB |
| `UseCompressedClassPointers` | 对象头中的 klass 指针 | 4B | 4GB Metaspace | Metaspace ≤ 4GB |

**两者独立控制**：

```
UseCompressedOops=true, UseCompressedClassPointers=true（默认）：
  对象头 = 8（mark）+ 4（narrowKlass）= 12 字节
  对象引用字段 = 4 字节

UseCompressedOops=true, UseCompressedClassPointers=false：
  对象头 = 8（mark）+ 8（Klass*）= 16 字节
  对象引用字段 = 4 字节

UseCompressedOops=false（堆 > 32GB）：
  对象头 = 8（mark）+ 8（Klass*）= 16 字节
  对象引用字段 = 8 字节
```

### klass_gap — 最让我困惑的 4 字节

开启压缩类指针时，对象头是 12 字节（8 + 4）。但 Java 对象是 8 字节对齐的，所以字段必须从 16 字节偏移开始？

不对！字段从 **12 字节**偏移开始，不是 16。

这 4 字节的"空隙"（klass_gap）被用来：
1. 普通对象：存第一个字段（如果字段是 4 字节的 int/float）
2. 数组对象：存 `length`

```cpp
// instanceOop.hpp:39-44
static int base_offset_in_bytes() {
  // ★ 开启压缩指针：字段从偏移 12 开始（klass_gap 位置）
  // ★ 关闭压缩指针：字段从偏移 16 开始（oopDesc 大小）
  return (UseCompressedOops && UseCompressedClassPointers) ?
           klass_gap_offset_in_bytes() :   // = 12
           sizeof(instanceOopDesc);         // = 16
}
```

**实例对比**：

```
class Foo { int x; long y; }

开启压缩指针（base_offset=12）：
偏移   内容
 0     MarkWord（8B）
 8     narrowKlass（4B）
12     int x（4B）← 从 12 开始，不是 16！
16     long y（8B）
总大小：24 字节

关闭压缩指针（base_offset=16）：
偏移   内容
 0     MarkWord（8B）
 8     Klass*（8B）
16     int x（4B）
20     [padding 4B]（long 需要 8 字节对齐）
24     long y（8B）
总大小：32 字节
```

开启压缩指针节省了 8 字节（25%）。

---

## 第三天：字段布局 — JVM 会重排字段顺序

### 坑：我以为字段按声明顺序排列

我以为 Java 字段在内存里的顺序和声明顺序一样。

结果 JVM 会**重排字段**以减少内存浪费（padding）。

**字段排列规则**（`FieldAllocator` 的分配策略）：

```
分配顺序（从大到小，减少 padding）：
1. double / long（8 字节）
2. int / float（4 字节）
3. short / char（2 字节）
4. byte / boolean（1 字节）
5. oop 引用（4 字节压缩 / 8 字节未压缩）
```

**实例**：

```java
class Example {
    byte b;     // 1 字节
    long l;     // 8 字节
    int i;      // 4 字节
    String s;   // 引用
}
```

我以为的内存布局（按声明顺序）：

```
偏移   内容
12     byte b（1B）
13     [padding 7B]（long 需要 8 字节对齐）
20     long l（8B）
28     int i（4B）
32     String s（4B，压缩引用）
总大小：36 字节（含 padding）
```

实际内存布局（JVM 重排后）：

```
偏移   内容
12     long l（8B）← 先放 8 字节字段
20     int i（4B）← 再放 4 字节字段
24     byte b（1B）← 再放 1 字节字段
25     [padding 3B]（引用需要 4 字节对齐）
28     String s（4B，压缩引用）
总大小：32 字节（节省 4 字节）
```

**为什么 JVM 要重排字段？**

减少 padding，节省内存。对于有大量实例的类（如 `HashMap.Entry`），每个实例节省几字节，乘以百万个实例，效果显著。

### 继承关系下的字段布局

父类字段在前，子类字段在后：

```java
class Animal {
    int age;    // 4 字节
}
class Dog extends Animal {
    String name;  // 4 字节（压缩引用）
}
```

内存布局（开启压缩指针）：

```
偏移   内容
 0     MarkWord（8B）
 8     narrowKlass（4B）→ Dog 的 InstanceKlass
12     int age（4B）← Animal 的字段
16     String name（4B）← Dog 的字段
总大小：20 字节
```

---

## 第四天：对象创建流程 — finish() 的两个细节

### 我踩的坑：以为对象创建就是"分配内存 + 清零"

我以为 `new Object()` 就是：
1. 分配一块内存
2. 清零
3. 设置类型指针

结果 `MemAllocator::finish()` 有两个我没想到的细节。

### 细节 1：先设置 mark，再设置 klass（顺序不能反）

```cpp
// memAllocator.cpp:397-408
oop MemAllocator::finish(HeapWord* mem) const {
  assert(mem != NULL, "NULL object pointer");

  // ★ 第一步：设置 MarkWord
  if (UseBiasedLocking) {
    // 偏向锁开启：使用类的原型头（包含偏向锁信息）
    oopDesc::set_mark_raw(mem, _klass->prototype_header());
  } else {
    // 偏向锁关闭：使用默认原型（unlocked, no_hash, age=0）
    // markOopDesc::prototype() = 0x0000_0000_0000_0001（lock=01，无锁）
    oopDesc::set_mark_raw(mem, markOopDesc::prototype());
  }

  // ★ 第二步：设置 klass 指针（release 语义，必须最后设置！）
  // Need a release store to ensure array/class length, mark word, and
  // object zeroing are visible before setting the klass non-NULL, for
  // concurrent collectors.
  oopDesc::release_set_klass(mem, _klass);
  return oop(mem);
}
```

**为什么 klass 必须最后设置？**

并发 GC（G1、CMS）在扫描堆时，用 `klass != NULL` 判断对象是否"可解析"（parsable）。

如果先设置 klass，GC 可能在 mark 还没设置时就开始解析对象，读到垃圾数据。

所以必须：
1. 先设置 mark（`set_mark_raw`，普通写）
2. 再设置 klass（`release_set_klass`，写屏障）

`release_set_klass` 保证：在 klass 写入对其他线程可见之前，mark 的写入已经对其他线程可见。

### 细节 2：数组的 length 必须在 klass 之前设置

```cpp
// memAllocator.cpp:426-436
oop ObjArrayAllocator::initialize(HeapWord* mem) const {
  // Set array length before setting the _klass field because a
  // non-NULL klass field indicates that the object is parsable by
  // concurrent GC.
  assert(_length >= 0, "length should be non-negative");
  if (_do_zero) {
    mem_clear(mem);
  }
  // ★ 先设置 length（在 klass 之前！）
  arrayOopDesc::set_length(mem, _length);
  // ★ 再调用 finish 设置 mark 和 klass
  return finish(mem);
}
```

同样的原因：GC 解析数组对象时需要 length 来计算对象大小。如果先设置 klass，GC 可能读到未初始化的 length（0），误判对象大小为 0，导致堆扫描出错。

**对象创建的完整顺序**：

```
普通对象：
  1. 分配内存（TLAB 快速路径 or 慢速路径）
  2. 清零（fill_to_aligned_words）
  3. 设置 MarkWord（set_mark_raw）
  4. 设置 klass（release_set_klass）← 最后！

数组对象：
  1. 分配内存
  2. 清零（如果 _do_zero）
  3. 设置 length（set_length）← 在 klass 之前！
  4. 设置 MarkWord（set_mark_raw）
  5. 设置 klass（release_set_klass）← 最后！
```

---

## 第四天半：oop 和 Klass 的双向关联

### 我踩的坑：以为 oop → Klass 是单向的

我以为 `oop` 只有一个指向 `Klass` 的指针，`Klass` 不知道自己有哪些实例。

结果 `Klass` 里有一个 `_java_mirror` 字段，指向 `java.lang.Class` 对象：

```cpp
// klass.hpp（关键字段）
class Klass : public Metadata {
 protected:
  jint        _layout_helper;           // 对象布局描述符（正数=实例大小，负数=数组信息）
  const KlassID _id;                    // Klass 类型标识
  juint       _super_check_offset;      // 快速类型检查偏移
  Symbol*     _name;                    // 类名（如 "java/lang/String"）
  Klass*      _secondary_super_cache;   // 二级父类缓存（instanceof 优化）
  Array<Klass*>* _secondary_supers;     // 二级父类数组
  Klass*      _primary_supers[8];       // 一级父类数组（最多 8 层，O(1) 查找）
  OopHandle   _java_mirror;             // ★ java.lang.Class 对象（双向关联！）
  Klass*      _super;                   // 父类
  Klass*      _subklass;                // 子类链表头
  Klass*      _next_sibling;            // 兄弟节点
  ClassLoaderData* _class_loader_data;  // 类加载器数据
  jint        _modifier_flags;          // 修饰符
  AccessFlags _access_flags;            // 访问标志
  markOop     _prototype_header;        // ★ 原型对象头（新对象的 MarkWord 初始值）
  int         _vtable_len;              // 虚表长度
};
```

**双向关联**：

```
oop（堆内存）                    Klass（Metaspace）
┌─────────────────┐              ┌─────────────────────────┐
│ _mark           │              │ _name: "java/lang/String"│
│ _klass ─────────┼─────────────→│ _methods: [...]          │
│ value: char[]   │              │ _fields: [...]           │
│ hash: int       │              │ _java_mirror ────────────┼──→ java.lang.Class
└─────────────────┘              │ _prototype_header        │
                                 │ _vtable_len              │
                                 └─────────────────────────┘
```

**`_prototype_header` 是什么？**

这是新对象的 MarkWord 初始值。

- 偏向锁开启时：`_prototype_header` 包含偏向锁信息（epoch + biased_lock=1）
- 偏向锁关闭时：`_prototype_header` = `markOopDesc::prototype()` = `0x0000_0000_0000_0001`

创建新对象时，`MemAllocator::finish()` 直接把 `_prototype_header` 复制到新对象的 `_mark`，不需要每次重新计算。

**`_layout_helper` 是什么？**

这是对象布局的"快速描述符"，避免每次都要解析 Klass 的完整信息：

```
正数：实例类，值 = 实例大小（字节）
负数：数组类，编码了数组头大小、元素类型、元素大小
  MSB:[tag:8][hsz:8][ebt:8][log2(esz):8]:LSB
  tag: 0x80 = 元素是 oop，0xC0 = 元素是基本类型
  hsz: 数组头大小（字节）
  ebt: 元素基本类型（BasicType 枚举）
  esz: 元素大小（字节）
```

---

## 第五天：插桩验证 — 我用数据打脸了自己的猜测

### 猜测 vs 实测对比表

| 猜测 | 实测 | 打脸程度 |
|------|------|---------|
| 对象头 = 8 字节（一个类型指针） | **12 字节**（mark 8 + narrowKlass 4，压缩模式） | 差了 4 字节 |
| sizeof(oopDesc) = 8 | **16 字节**（GDB 验证，未压缩模式） | 差了 8 字节 |
| sizeof(InstanceKlass) = 128 | **472 字节**（GDB 验证） | 差了 344 字节 |
| sizeof(Klass) = 64 | **208 字节**（GDB 验证） | 差了 144 字节 |
| 字段按声明顺序排列 | **JVM 重排字段**（大字段优先，减少 padding） | 完全错了 |
| 数组头 = 对象头 + length（额外 4 字节） | **复用 klass_gap**，数组头和普通对象头同样大小 | 没想到 |
| klass 指针是第一个字段 | **mark 是第一个字段**，klass 在偏移 8 | 顺序搞反了 |
| 对象创建 = 分配 + 清零 + 设置 klass | **klass 必须最后设置**（release_store），length 必须在 klass 之前 | 顺序有严格要求 |

### 实测数据（GDB 验证）

**oopDesc 字段偏移**：

```
[GDB] p &((oopDesc*)0)->_mark
$1 = 0    ← _mark 在偏移 0

[GDB] p &((oopDesc*)0)->_metadata
$2 = 8    ← _metadata（klass 指针）在偏移 8
```

**Klass 关键字段偏移**：

```
[GDB] p &((Klass*)0)->_layout_helper
$3 = 12   ← 在 vtable 指针（8B）之后

[GDB] p &((Klass*)0)->_name
$4 = 24

[GDB] p &((Klass*)0)->_java_mirror
$5 = 112

[GDB] p &((Klass*)0)->_super
$6 = 120

[GDB] p &((Klass*)0)->_prototype_header
$7 = 184

[GDB] p &((Klass*)0)->_vtable_len
$8 = 196
```

**InstanceKlass 关键字段偏移**：

```
[GDB] p &((InstanceKlass*)0)->_constants
$9 = 232   ← 常量池

[GDB] p &((InstanceKlass*)0)->_methods
$10 = 416  ← 方法数组

[GDB] p &((InstanceKlass*)0)->_fields
$11 = 464  ← 字段数组

[GDB] p &((InstanceKlass*)0)->_init_state
$12 = 394  ← 初始化状态（u1，1 字节）
```

**markOop 位域常量**：

```
[GDB] p (int)markOopDesc::age_bits
$13 = 4    ← GC 年龄 4 位

[GDB] p (int)markOopDesc::lock_bits
$14 = 2    ← 锁状态 2 位

[GDB] p (int)markOopDesc::hash_bits
$15 = 31   ← identity hash 31 位

[GDB] p (int)markOopDesc::locked_value
$16 = 0    ← 轻量级锁 = 00

[GDB] p (int)markOopDesc::unlocked_value
$17 = 1    ← 无锁 = 01

[GDB] p (int)markOopDesc::monitor_value
$18 = 2    ← 重量级锁 = 10

[GDB] p (int)markOopDesc::biased_lock_pattern
$19 = 5    ← 偏向锁 = 101
```

**对象分配插桩数据**（来自 `Instrumentation/03-ObjectAlloc-Probe-Results.md`）：

```
[插桩] 分配 int[] 数组：
  top-start = 16 字节（对象头大小）
  = mark word 8B + klass pointer 8B（未压缩环境）
  ★ 验证：数组头 = 普通对象头大小（length 复用了 klass_gap）

[插桩] 实际分配 size 比 Java 层 length 多 16 字节：
  = 对象头（mark word 8B + klass pointer 8B）
  ★ 验证：对象头开销确实是 16 字节（未压缩环境）
```

---

## 尾声：我现在怎么理解 Java 对象的内存布局

以前我以为 Java 对象就是"一块内存 + 类型指针"，现在我知道：

**Java 对象 = oopDesc（对象头）+ 字段数据**

```
对象头（oopDesc）：
  ├── _mark（8 字节）：MarkWord，状态机
  │     ├── 无锁：[unused:25][hash:31][unused:1][age:4][biased:1=0][lock:2=01]
  │     ├── 偏向锁：[JavaThread*:54][epoch:2][unused:1][age:4][biased:1=1][lock:2=01]
  │     ├── 轻量级锁：[BasicLock*:62][lock:2=00]
  │     ├── 重量级锁：[ObjectMonitor*:62][lock:2=10]
  │     └── GC 标记：[forwarding ptr:62][lock:2=11]
  └── _klass（4 字节压缩 / 8 字节未压缩）：类型指针 → InstanceKlass

字段数据（紧跟对象头）：
  ├── 普通对象：从偏移 12（压缩）或 16（未压缩）开始
  │     └── 字段按 JVM 重排顺序（大字段优先）
  └── 数组对象：length（4 字节，复用 klass_gap）+ 元素数据
```

**最重要的三个设计决策**：

1. **oop + Klass 分离**：对象只存个性（实例数据），Klass 存共性（元数据）。所有同类对象共享一个 Klass，节省内存。

2. **MarkWord 状态机**：8 字节存储 5 种状态，每种状态下位域布局不同。最低 2 位是"路由器"，决定如何解读剩余 62 位。

3. **klass 最后设置（release_store）**：并发 GC 用 `klass != NULL` 判断对象是否可解析。klass 必须最后设置，且用写屏障保证之前的写操作对 GC 线程可见。

**最容易踩的坑**：

```java
// ❌ 错误：以为对象头是 8 字节
// 实际：12 字节（压缩）或 16 字节（未压缩）

// ❌ 错误：以为字段按声明顺序排列
// 实际：JVM 重排字段（大字段优先）

// ❌ 错误：以为数组头比普通对象头多 4 字节
// 实际：数组 length 复用 klass_gap，头大小相同

// ❌ 错误：以为 System.identityHashCode() 返回对象地址
// 实际：hash 存在 MarkWord 的 hash 位域（31 位），
//       生成算法是 Marsaglia xor-shift（不是地址！）
//       一旦对象加了轻量级锁，hash 位域被 BasicLock* 覆盖，
//       必须先把 hash 保存到 BasicLock 里，解锁后再恢复
```

---

## 数据结构关系图

```mermaid
classDiagram
    direction TB

    class oopDesc {
        +volatile markOop _mark
        +union _metadata
        note: 偏移0=_mark, 偏移8=_klass
        note: 对象头12B(压缩)/16B(未压缩)
    }

    class markOopDesc {
        <<位域编码>>
        +lock_bits: 2
        +biased_lock_bits: 1
        +age_bits: 4
        +hash_bits: 31
        +epoch_bits: 2
        note: 5种状态，位域布局各不同
        note: 最低2位是状态路由器
    }

    class instanceOopDesc {
        <<继承oopDesc>>
        note: 无新增字段
        note: 字段从偏移12(压缩)/16(未压缩)开始
    }

    class arrayOopDesc {
        <<继承oopDesc>>
        +length() int
        note: length复用klass_gap(偏移12)
        note: 数组头=普通对象头大小
    }

    class Klass {
        +jint _layout_helper
        +Symbol* _name
        +Klass* _primary_supers[8]
        +OopHandle _java_mirror
        +Klass* _super
        +markOop _prototype_header
        +int _vtable_len
        note: sizeof=208B
        note: 存储在Metaspace
    }

    class InstanceKlass {
        <<继承Klass>>
        +ConstantPool* _constants
        +Array~Method~* _methods
        +Array~u2~* _fields
        +u1 _init_state
        note: sizeof=472B
        note: _init_state: 6种状态
    }

    class ArrayKlass {
        <<继承Klass>>
        +int _dimension
        +Klass* _higher_dimension
        +Klass* _lower_dimension
        note: sizeof=232B
    }

    class narrowOop {
        <<4字节压缩指针>>
        note: decode: (v<<3)+heap_base
        note: 最大支持32GB堆
    }

    class narrowKlass {
        <<4字节压缩类指针>>
        note: decode: Klass::decode_klass(v)
        note: 最大支持4GB Metaspace
    }

    oopDesc <|-- instanceOopDesc : 继承
    oopDesc <|-- arrayOopDesc : 继承
    oopDesc *-- markOopDesc : _mark(8B)
    oopDesc --> narrowKlass : _compressed_klass(4B)
    oopDesc --> Klass : _klass(8B,未压缩)

    Klass <|-- InstanceKlass : 继承
    Klass <|-- ArrayKlass : 继承

    Klass --> oopDesc : _java_mirror→java.lang.Class
    InstanceKlass --> narrowOop : 字段中的对象引用

    instanceOopDesc --> narrowOop : 字段中的对象引用
```

---

## 对象内存布局全景图

我当时最搞不清楚的是压缩指针开启/关闭时对象头的大小变化，以及数组对象的 length 字段到底放在哪里。把布局画出来才发现，`klass_gap` 被 length 复用这个设计真的很精妙：

```mermaid
flowchart LR
    subgraph 普通对象_压缩["普通对象（-XX:+UseCompressedOops）"]
        direction TB
        A1["offset 0: _mark (8B)\nMarkWord: hash/age/锁状态"]
        A2["offset 8: _compressed_klass (4B)\nnarrowKlass: 压缩类指针"]
        A3["offset 12: 字段区域\n(JVM 重排：8B→4B→2B→1B)"]
        A1 --> A2 --> A3
    end

    subgraph 普通对象_未压缩["普通对象（-XX:-UseCompressedOops）"]
        direction TB
        B1["offset 0: _mark (8B)"]
        B2["offset 8: _klass (8B)\n完整 Klass* 指针"]
        B3["offset 16: 字段区域"]
        B1 --> B2 --> B3
    end

    subgraph 数组对象_压缩["数组对象（-XX:+UseCompressedOops）"]
        direction TB
        C1["offset 0: _mark (8B)"]
        C2["offset 8: _compressed_klass (4B)"]
        C3["offset 12: length (4B)\n⚠️ 复用 klass_gap！"]
        C4["offset 16: 元素区域\n(8B 对齐)"]
        C1 --> C2 --> C3 --> C4
    end

    subgraph 字段重排规则["JVM 字段重排规则（FieldAllocationStyle=1）"]
        direction TB
        D1["1. 父类字段（按原顺序）"]
        D2["2. 8B 字段（long/double）"]
        D3["3. 4B 字段（int/float/ref）"]
        D4["4. 2B 字段（short/char）"]
        D5["5. 1B 字段（byte/boolean）"]
        D6["6. oop 引用（4B 压缩 / 8B 未压缩）"]
        D1 --> D2 --> D3 --> D4 --> D5 --> D6
    end

    style C3 fill:#FFD700
    style D1 fill:#E8F4FD
```

**几个我当时没想清楚的点：**

- `klass_gap` 是什么：压缩模式下 `_compressed_klass` 只占 4B，但 JVM 要求 8B 对齐，所以 offset 8-11 是 klass，offset 12-15 是 gap。数组对象把这个 gap 用来存 length，一分钱不浪费
- 为什么字段要重排：减少 padding。如果按声明顺序放，`int` 后面跟 `long` 会有 4B 的 padding；重排后大字段先放，padding 最小化
- `klass` 最后设置的原因：并发 GC 用 `klass != NULL` 判断对象是否可解析，所以 klass 必须最后写，而且要用 `release_store` 保证可见性

---

## 还没搞懂的地方

**1. FieldAllocationStyle 的三种模式**

JVM 有 `FieldAllocationStyle=0/1/2` 三种字段排列策略，默认是 1（oop 字段放最后）。我知道 0 是 oop 字段放最前，2 是什么我没有查清楚。不同策略对 GC 扫描效率有什么影响？

**2. 对象对齐填充的精确规则**

我知道对象大小要 8B 对齐（`ObjectAlignmentInBytes=8`），但具体的填充是加在哪里？是加在最后一个字段后面，还是有其他规则？`instanceOopDesc::base_offset_in_bytes()` 这个函数我没有仔细看。

**3. 压缩指针的 heap_base 是怎么确定的**

`narrowOop` 的解码公式是 `(v << 3) + heap_base`，`heap_base` 是堆的起始地址。但堆的起始地址是在 JVM 启动时动态分配的，怎么保证 `heap_base` 是 8B 对齐的？如果堆超过 32GB 会怎样？我知道会退化到未压缩模式，但具体的判断逻辑没有追。

**4. Klass 的 `_prototype_header` 字段**

`Klass` 里有个 `_prototype_header`（offset 184），我知道它和偏向锁有关（存储 epoch 信息），但大纲说偏向锁不用深入了解，所以这个字段我就跳过了。但它在非偏向锁场景下有没有其他用途？我不确定。

**5. 字段布局和 JIT 内联的关系**

C2 编译器在内联字段访问时，会直接把字段偏移编译进机器码（`mov rax, [rbx+12]` 这种）。如果 JVM 重排了字段，C2 是怎么知道正确偏移的？是在编译时查 InstanceKlass 的字段表，还是有其他机制？这个我完全没有追。

---

## 总结

### 数据结构层面

| 结构 | sizeof | 核心特征 |
|------|--------|---------|
| **oopDesc** | 16B（未压缩）/ 12B（压缩头） | `_mark`(0) + `_klass`(8)，所有对象的基类 |
| **markOopDesc** | 8B（存储时） | 5 种状态，位域布局各不同，最低 2 位是路由器 |
| **instanceOopDesc** | 无新增字段 | 字段从偏移 12（压缩）或 16（未压缩）开始，JVM 重排字段 |
| **arrayOopDesc** | 无新增字段 | length 复用 klass_gap（偏移 12），数组头大小 = 普通对象头 |
| **Klass** | 208B | `_prototype_header`(184) + `_layout_helper`(12) + `_java_mirror`(112) |
| **InstanceKlass** | 472B | `_init_state`(394) 6 种状态机 + `_methods`(416) + `_fields`(464) |
| **narrowOop/narrowKlass** | 4B | 移位编码（>>3/<<3），最大 32GB 堆 / 4GB Metaspace |

### 算法层面

| 算法 | 核心设计决策 |
|------|-------------|
| **对象创建** | klass 最后设置（release_store），数组 length 在 klass 之前；并发 GC 用 klass!=NULL 判断可解析性 |
| **字段布局** | JVM 重排字段（大字段优先），减少 padding；父类字段在前，子类字段在后 |
| **压缩指针** | 移位编码（×8），32 位存 35 位地址空间；klass_gap 被 length 复用 |
| **MarkWord 状态机** | 最低 2 位路由，5 种状态位域布局各不同；指针低 2 位天然为 0，可安全存锁状态 |

---

*文档状态：✅ 完成*  
*写作日期：2026-03-06*  
*参考文档：`ObjectModel/1-Oop-Klass-Architecture-Deep-Dive.md`*  
*插桩数据：`Instrumentation/03-ObjectAlloc-Probe-Results.md`*
