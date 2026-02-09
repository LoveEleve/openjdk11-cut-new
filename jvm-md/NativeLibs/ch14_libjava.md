# Ch14: libjava.so 深度分析 — java.lang / java.io 核心 Native 实现

> **标准环境**: `-Xms8g -Xmx8g -XX:+UseG1GC`, G1 Region = 4MB
> **源码版本**: OpenJDK 11
> **源码路径**: `src/java.base/share/native/libjava/` + `src/java.base/unix/native/libjava/` + `src/java.base/linux/native/libjava/`

---

## 一、为什么要分析 libjava.so？

**一句话**：libjava.so 是 JDK 中最核心的 native 库，承载了 `java.lang.*` 和 `java.io.*` 全部 native 方法的实现。

你写的每一行 Java 代码，几乎都间接依赖 libjava.so：
- `System.arraycopy()` — 所有集合类扩容的基础
- `Object.hashCode()` — HashMap 的基石
- `Object.clone()` — 深浅拷贝的起点
- `Thread.start0()` — 线程创建
- `FileInputStream.read()` / `FileOutputStream.write()` — 文件 I/O
- `Runtime.gc()` / `Runtime.freeMemory()` — 运行时内存查询
- `ClassLoader.defineClass1()` — 类加载

**面试价值**：
- "System.arraycopy 底层怎么实现的？" — 从 JNI 到 x86 汇编的 10 层调用链
- "Object.hashCode() 默认用什么算法？" — Marsaglia xor-shift + 6 种策略选择
- "FileInputStream.read() 一次读一个字节有多慢？" — JNI 开销 + 系统调用

---

## 二、libjava.so 全景：59 个 .c 文件，11 大分类

### 2.1 文件分布

```
src/java.base/
├── share/native/libjava/         # 42 个 .c (跨平台)
├── unix/native/libjava/          # 15 个 .c (Unix/Linux/macOS)
└── linux/native/libjava/         #  2 个 .c (Linux 特有)
```

### 2.2 分类总览

| 分类 | 文件数 | 代表文件 | 对应 Java 类 |
|------|--------|---------|-------------|
| **A. java.lang 核心** | 16 | Object.c, Thread.c, System.c, Class.c, String.c | Object, Thread, System, Class, String |
| **B. java.io** | 12 | FileInputStream.c, FileOutputStream_md.c, io_util.c | FileInputStream, FileOutputStream, RandomAccessFile |
| **C. 反射** | 6 | Reflection.c, Field.c, Method.c, Constructor.c | java.lang.reflect.* |
| **D. 安全** | 1 | AccessController.c | AccessController |
| **E. 引用/并发** | 2 | Reference.c, Finalizer.c | java.lang.ref.* |
| **F. JDK 内部/VM** | 5 | VM.c, VMSupport.c, Signal.c, Perf.c | jdk.internal.misc.VM |
| **G. 工具类** | 7 | Math.c, Float.c, Double.c, Bits.c | Math, Float, Double |
| **H. 时区** | 2 | TimeZone_md.c, TimeZone.c | java.util.TimeZone |
| **I. 进程** | 5 | ProcessImpl_md.c, ProcessHandleImpl_linux.c | ProcessBuilder |
| **J. 系统属性** | 1 | java_props_md.c | System.getProperties() |
| **K. Linux 特有** | 2 | CgroupMetrics.c, ProcessHandleImpl_linux.c | Cgroup 容器感知 |

### 2.3 两大核心设计模式

#### 模式一：JVM 委托（Delegation to libjvm.so）

绝大多数 `java.lang.*` 的 native 方法都是 **薄薄一层 JNI 外壳**，真正实现在 `libjvm.so` (HotSpot) 的 `JVM_*` 函数中：

```c
// Object.c — hashCode 委托给 JVM_IHashCode
{"hashCode", "()I", (void *)&JVM_IHashCode}

// Thread.c — start0 委托给 JVM_StartThread  
{"start0", "()V", (void *)&JVM_StartThread}

// Runtime.c — gc 委托给 JVM_GC
Java_java_lang_Runtime_gc(JNIEnv *env, jobject this) {
    JVM_GC();
}
```

**为什么这么设计？** 因为这些方法需要直接操作 JVM 内部数据结构（堆、线程栈、对象头），必须在 libjvm.so 的地址空间内执行。libjava.so 只负责 JNI 注册和参数转换。

#### 模式二：RegisterNatives 批量注册

核心类不使用默认的 `Java_包名_类名_方法名` 命名约定，而是通过 `registerNatives()` 批量注册：

```c
// Object.c
static JNINativeMethod methods[] = {
    {"hashCode",  "()I",                    (void *)&JVM_IHashCode},
    {"wait",      "(J)V",                   (void *)&JVM_MonitorWait},
    {"notify",    "()V",                    (void *)&JVM_MonitorNotify},
    {"notifyAll", "()V",                    (void *)&JVM_MonitorNotifyAll},
    {"clone",     "()Ljava/lang/Object;",   (void *)&JVM_Clone},
};

Java_java_lang_Object_registerNatives(JNIEnv *env, jclass cls) {
    (*env)->RegisterNatives(env, cls, methods, 5);
}
```

**好处**：
1. 方法名可以自由映射，不受 JNI 命名约束
2. 注册时机可控（在类初始化的 `static {}` 块中调用）
3. 可以直接指向 libjvm.so 的 `JVM_*` 函数指针，省去一层间接调用

**使用 RegisterNatives 的核心类**：Object (5 方法)、Thread (16 方法)、System (3 方法)、Class (25 方法)、ClassLoader (1 方法)

---

## 三、System.arraycopy() 完整链路 — 从 Java 到 x86 汇编

### 3.1 为什么 arraycopy 如此重要？

`System.arraycopy()` 是 Java 中调用频率最高的 native 方法之一：
- `ArrayList.grow()` — 扩容时复制元素
- `HashMap.resize()` — rehash 时复制桶
- `String.getBytes()` — 字符串编码转换
- `Arrays.copyOf()` — 数组拷贝工具方法

它也是 HotSpot 中优化层次最深的方法——从 JNI 到解释器到 C1 到 C2，每一层都有专门优化。

### 3.2 十层调用链总览

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Layer 1: Java 声明                                                      │
│   @HotSpotIntrinsicCandidate                                            │
│   public static native void arraycopy(Object src, int srcPos,           │
│       Object dest, int destPos, int length);                            │
├─────────────────────────────────────────────────────────────────────────┤
│ Layer 2: JNI 注册 (System.c)                                            │
│   {"arraycopy", "(LOIOI)V", (void *)&JVM_ArrayCopy}                     │
├─────────────────────────────────────────────────────────────────────────┤
│ Layer 3: JVM_ArrayCopy (jvm.cpp:327-340)                                │
│   null 检查 → resolve JNI handle → s->klass()->copy_array() 虚分派      │
├─────────────────────────────────────────────────────────────────────────┤
│ Layer 4: Klass::copy_array() 虚分派                                      │
│   ├── TypeArrayKlass::copy_array() — 基本类型数组                        │
│   └── ObjArrayKlass::copy_array()  — 对象引用数组                        │
├─────────────────────────────────────────────────────────────────────────┤
│ Layer 5: Access API 模板流水线                                           │
│   ArrayAccess<ARRAYCOPY_ATOMIC>::arraycopy<void>()                      │
│   五步装饰器: HeapAccess → RuntimeDispatch → GC Barrier → RawAccess      │
├─────────────────────────────────────────────────────────────────────────┤
│ Layer 6: Copy 工具类 (copy.hpp/copy.cpp)                                 │
│   conjoint_memory_atomic() — 按最大原子单元选择复制方式                    │
├─────────────────────────────────────────────────────────────────────────┤
│ Layer 7: 平台实现 (copy_linux_x86.inline.hpp)                            │
│   pd_conjoint_bytes → memmove()                                         │
│   pd_conjoint_oops_atomic → _Copy_conjoint_jlongs_atomic (汇编)         │
├─────────────────────────────────────────────────────────────────────────┤
│ Layer 8: StubRoutines x86_64 数组拷贝 Stub                               │
│   generate_arraycopy_stubs() — 为每种类型生成 disjoint/conjoint stub     │
│   generate_generic_copy() — 编译器使用的统一入口                          │
├─────────────────────────────────────────────────────────────────────────┤
│ Layer 9: SharedRuntime::slow_arraycopy_C — 编译代码的慢路径回退           │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.3 Layer 2-3: JNI 注册与 JVM_ArrayCopy

**注册** (`System.c:38-41`)：

```c
static JNINativeMethod methods[] = {
    {"currentTimeMillis", "()J",              (void *)&JVM_CurrentTimeMillis},
    {"nanoTime",          "()J",              (void *)&JVM_NanoTime},
    {"arraycopy",     "(LOIOI)V",             (void *)&JVM_ArrayCopy},
};
```

System 只注册了 3 个性能关键方法（注释原文："Only register the performance-critical methods"），其余 native 方法如 `identityHashCode`、`initProperties`、`setIn0/setOut0/setErr0`、`mapLibraryName` 用默认 JNI 命名。

**JVM_ArrayCopy** (`jvm.cpp:327-340`)：

```c
JVM_ENTRY(void, JVM_ArrayCopy(JNIEnv * env, jclass ignored, 
        jobject src, jint src_pos, jobject dst, jint dst_pos, jint length))
    // Step 1: null 检查
    if (src == NULL || dst == NULL) {
        THROW(vmSymbols::java_lang_NullPointerException());
    }
    // Step 2: 解析 JNI handle → oop
    arrayOop s = arrayOop(JNIHandles::resolve_non_null(src));
    arrayOop d = arrayOop(JNIHandles::resolve_non_null(dst));
    // Step 3: 虚分派到具体 Klass 的 copy_array
    s->klass()->copy_array(s, src_pos, d, dst_pos, length, thread);
JVM_END
```

核心在 **Step 3**：通过 `klass()` 获取源数组的 Klass 元数据，虚调用 `copy_array()`。TypeArrayKlass 和 ObjArrayKlass 有不同实现。

### 3.4 Layer 4a: TypeArrayKlass::copy_array() — 基本类型数组

> 源码：`typeArrayKlass.cpp:126-192`

处理 `int[]`、`byte[]`、`long[]` 等基本类型数组的拷贝。

**执行流程**：

1. **类型检查**：目标必须是 typeArray，且元素类型一致，否则抛 ArrayStoreException
2. **边界检查**：src_pos/dst_pos/length 非负，且不越界
3. **零长度快速返回**：`if (length == 0) return;`
4. **计算字节偏移并复制**：

```c
int l2es = log2_element_size();  // int[] → 2, byte[] → 0, long[] → 3
size_t src_offset = arrayOopDesc::base_offset_in_bytes(element_type()) 
                    + ((size_t)src_pos << l2es);
size_t dst_offset = arrayOopDesc::base_offset_in_bytes(element_type()) 
                    + ((size_t)dst_pos << l2es);
ArrayAccess<ARRAYCOPY_ATOMIC>::arraycopy<void>(s, src_offset, d, dst_offset, 
                                                (size_t)length << l2es);
```

关键点：
- `base_offset_in_bytes` 跳过对象头（markWord + Klass + length），到达数组数据区
- `ARRAYCOPY_ATOMIC` 标志保证每个元素的写入是原子的（对齐的 int/long 写入本身就是原子的）
- 模板参数 `<void>` 表示纯字节复制，无类型特化

### 3.5 Layer 4b: ObjArrayKlass::copy_array() — 对象引用数组

> 源码：`objArrayKlass.cpp:256-328`、`do_copy (221-254)`

处理 `Object[]`、`String[]` 等对象引用数组，比 TypeArrayKlass 复杂得多——因为需要 **GC 写屏障** 和 **类型检查**。

**ObjArrayKlass::copy_array** 的流程：
1. 类型检查（目标必须是 objArray）
2. 边界检查（同 TypeArrayKlass）
3. 根据 `UseCompressedOops` 计算 offset
4. 调用 `do_copy()` 实际复制

**do_copy() 三条路径**：

```c
void ObjArrayKlass::do_copy(arrayOop s, size_t src_offset,
                            arrayOop d, size_t dst_offset, int length, TRAPS) {
    if (s == d) {
        // 路径 1: 自拷贝 — conjoint（可能重叠）
        ArrayAccess<>::oop_arraycopy(s, src_offset, d, dst_offset, length);
    } else {
        Klass* bound = ObjArrayKlass::cast(d->klass())->element_klass();
        Klass* stype = ObjArrayKlass::cast(s->klass())->element_klass();
        if (stype == bound || stype->is_subtype_of(bound)) {
            // 路径 2: 类型兼容 — disjoint（不重叠，更快）
            ArrayAccess<ARRAYCOPY_DISJOINT>::oop_arraycopy(...);
        } else {
            // 路径 3: 需要逐元素类型检查 — checkcast
            ArrayAccess<ARRAYCOPY_DISJOINT | ARRAYCOPY_CHECKCAST>::oop_arraycopy(...);
        }
    }
}
```

**三条路径的差异**：

| 路径 | 条件 | 标志 | 性能 | 场景 |
|------|------|------|------|------|
| conjoint | `s == d` | 默认 | 中 | `arraycopy(a, 0, a, 1, 5)` 自身移位 |
| disjoint | `stype ⊂ bound` | ARRAYCOPY_DISJOINT | 快 | `Object[] = String[]` 协变 |
| checkcast | 类型不确定 | DISJOINT\|CHECKCAST | 慢 | `Number[] src; Integer[] dst;` 逐元素检查 |

对象引用拷贝与基本类型最大的区别是：**每个 oop 写入都需要触发 GC 写屏障（G1 post-write barrier）**，通知 GC 引用关系的变化。这通过 Access API 的 GC Barrier 装饰器自动完成。

### 3.6 Layer 5-7: Access API → Copy → 平台实现

Access API 是 HotSpot 的模板元编程框架，用于在内存访问路径上插入 GC 屏障：

```
ArrayAccess<ARRAYCOPY_ATOMIC>::arraycopy<void>(s, src_offset, d, dst_offset, len)
    → HeapAccess                    // 标记为堆访问
    → RuntimeDispatch              // 根据 GC 类型分派
    → G1BarrierSet::AccessBarrier  // G1 写屏障（仅 oop 数组）
    → RawAccessBarrier::arraycopy  // 最终原始内存拷贝
    → Copy::conjoint_memory_atomic // 选择最大原子单元
    → pd_conjoint_bytes / pd_conjoint_jlongs_atomic  // 平台实现
```

对于基本类型数组（无 GC 屏障），最终路径：
- **AMD64 + 字节对齐** → `memmove()`（glibc 优化，AVX2/SSE2）
- **AMD64 + long/oop 对齐** → `_Copy_conjoint_jlongs_atomic`（手写汇编，保证 8 字节原子性）

### 3.7 Layer 8-9: StubRoutines Stubs 与编译器快路径

解释器路径走上面的 JVM_ArrayCopy → Klass::copy_array → Access API 链条。但 **编译器（C1/C2）不走这条路** —— 它们有专门的内联 intrinsic。

**StubRoutines::generate_arraycopy_stubs()** (`stubGenerator_x86_64.cpp:2867-2964`)：
- 为每种基本类型 (byte/short/int/long) + oop 生成专用 stub
- 每种类型有 disjoint 和 conjoint 两个版本
- 直接使用 `rep movsb/movsq` 或 AVX 指令，跳过所有 JNI/C++ 开销

**generate_generic_copy()** (`stubGenerator_x86_64.cpp:2573-2865`)：
- 编译器的统一入口，处理类型检查、对齐、边界检查后分派到类型特化 stub

**SharedRuntime::slow_arraycopy_C** (`sharedRuntime.cpp:1945-1966`)：
- 编译代码的最终慢路径回退，当 intrinsic 不适用时回退到 C++ 实现

### 3.8 三种执行路径总结

| 路径 | 触发条件 | 入口 | 性能 |
|------|---------|------|------|
| **解释器** | `-Xint` 或方法未编译 | JVM_ArrayCopy → Klass::copy_array | 最慢（JNI 开销 + 虚调用） |
| **C2 Intrinsic** | 编译后的热点代码 | 内联 generate_generic_copy stub | 最快（直接 AVX/rep movsq） |
| **C2 慢路径** | intrinsic bailout | SharedRuntime::slow_arraycopy_C | 中等 |

> **面试要点**：`System.arraycopy()` 标注了 `@HotSpotIntrinsicCandidate`，C2 编译器会将其替换为 CPU 原生的内存拷贝指令（AVX、rep movsq），完全绕过 JNI 和 C++ 调用栈。这就是为什么 `Arrays.copyOf()` 在热点代码中比手写 for 循环快得多。

---

## 四、Object.hashCode() 完整链路 — 6 种策略与 FastHashCode

### 4.1 调用链

```
Object.hashCode()                    // Java
  → JVM_IHashCode (jvm.cpp:608-612)  // JNI 委托
    → ObjectSynchronizer::FastHashCode(THREAD, obj)  // 核心算法
      → get_next_hash(Self, obj)     // hash 生成策略
```

### 4.2 JVM_IHashCode

```c
JVM_ENTRY(jint, JVM_IHashCode(JNIEnv * env, jobject handle))
    return handle == NULL ? 0 : 
           ObjectSynchronizer::FastHashCode(THREAD, JNIHandles::resolve_non_null(handle));
JVM_END
```

注意：`null.hashCode()` 在 Java 层会 NPE，但 `System.identityHashCode(null)` 也走这条路径，返回 0。

### 4.3 FastHashCode 三路查找

> 源码：`synchronizer.cpp:710-813`

FastHashCode 的核心逻辑是：**hashCode 存储在对象头 markWord 中**，但 markWord 可能处于三种状态，需要分别处理。

```
markWord 64 位布局（无锁态）:
┌──────────────────────────────────────────────────────┐
│ unused:25 | hash:31 | unused:1 | age:4 | biased:1 | lock:2 │
└──────────────────────────────────────────────────────┘
                        hash 占 31 位，最大 2^31-1
```

**三种状态的处理**：

```
FastHashCode(Thread* Self, oop obj)
  │
  ├── 步骤 0: 如果启用偏向锁，先撤销偏向
  │            BiasedLocking::revoke_and_rebias(hobj, false, ...)
  │
  ├── mark = ReadStableMark(obj)  // 读取稳定的 markWord
  │
  ├── Case 1: mark->is_neutral()  (无锁态, lock=01)
  │   ├── hash = mark->hash()     // 直接从 markWord 读 hash
  │   ├── if (hash != 0) return hash   // 已有 hash，直接返回
  │   ├── hash = get_next_hash()       // 生成新 hash
  │   ├── temp = mark->copy_set_hash(hash)  // 合并到 markWord
  │   └── CAS(temp, mark)              // 原子写入 → 成功返回
  │                                    // 失败则 fall-through 到膨胀
  │
  ├── Case 2: mark->has_monitor()  (重量级锁, lock=10)
  │   ├── monitor = mark->monitor()
  │   ├── temp = monitor->header()    // displaced header
  │   ├── hash = temp->hash()
  │   └── if (hash != 0) return hash  // 从 displaced header 读
  │
  ├── Case 3: Self->is_lock_owned(mark->locker())  (轻量级锁, lock=00)
  │   ├── temp = mark->displaced_mark_helper()  // BasicLock 的 displaced header
  │   ├── hash = temp->hash()
  │   └── if (hash != 0) return hash
  │
  └── 最终路径: 膨胀监视器写入 hash
      ├── monitor = inflate(Self, obj, inflate_cause_hash_code)
      ├── mark = monitor->header()
      ├── hash = mark->hash()
      ├── if (hash == 0):
      │   ├── hash = get_next_hash()
      │   └── CAS(mark->copy_set_hash(hash), monitor->header_addr(), mark)
      └── return hash
```

**关键设计决策**：
1. **无锁态**：hashCode 直接 CAS 写入对象头，最快路径
2. **轻量级锁**：hashCode 在 displaced header（栈上的 BasicLock）中，**不能直接写入**——因为其他线程可能异步读取 BasicLock（inflate 时），所以 **必须膨胀为重量级锁**
3. **重量级锁**：hashCode 在 ObjectMonitor 的 displaced header 中

> **重要推论**：调用 `hashCode()` 可能导致对象锁从轻量级膨胀为重量级！这就是为什么 "一旦计算了 hashCode，偏向锁就会被撤销" 的根本原因。

### 4.4 get_next_hash() 六种策略

> 源码：`synchronizer.cpp:669-708`

通过 JVM 参数 `-XX:hashCode=N` 选择策略（**默认 N=5**）：

| hashCode 值 | 算法 | 特点 |
|-------------|------|------|
| 0 | `os::random()` (Park-Miller RNG) | 全局锁竞争严重，多核性能差 |
| 1 | `(addr >> 3) ^ (addr >> 8) ^ GVars.stwRandom` | STW 稳定（同一对象在不同 STW 间结果一致） |
| 2 | `1` | **所有对象 hashCode 都是 1**（仅用于灵敏度测试） |
| 3 | `++GVars.hcSequence` | 全局递增序列号 |
| 4 | `cast_from_oop<intptr_t>(obj)` | 直接用对象地址（GC 移动后会变！不应用于生产） |
| **5 (默认)** | **Marsaglia xor-shift** | **线程本地状态，无锁，高性能** |

**默认策略 5 的实现**（Marsaglia xor-shift 128-bit）：

```c
unsigned t = Self->_hashStateX;           // 读线程本地状态
t ^= (t << 11);                          // xor-shift 变换
Self->_hashStateX = Self->_hashStateY;    // 状态轮转
Self->_hashStateY = Self->_hashStateZ;
Self->_hashStateZ = Self->_hashStateW;
unsigned v = Self->_hashStateW;
v = (v ^ (v >> 19)) ^ (t ^ (t >> 8));    // 混合
Self->_hashStateW = v;
value = v;
```

**为什么选择 xor-shift？**
1. **无全局锁**：每个线程有独立的 4-word 状态（`_hashStateX/Y/Z/W`），完全无竞争
2. **周期极长**：2^128 - 1，实际上不会重复
3. **分布均匀**：通过 chi-square 检验
4. **计算极快**：只有位运算，无除法/乘法

**最后处理**：

```c
value &= markOopDesc::hash_mask;  // 截断到 31 位
if (value == 0) value = 0xBAD;    // hash=0 被 markWord 用作"无 hash"标志
```

### 4.5 JVM 参数

```bash
# 查看默认策略
-XX:+PrintFlagsFinal -version 2>&1 | grep hashCode
# 输出: intx hashCode = 5

# 切换为地址策略（测试用）
-XX:hashCode=4

# 切换为常量 1（调试用）
-XX:hashCode=2
```

---

## 五、Object.clone() — 浅拷贝的完整实现

> 源码：`jvm.cpp:646-696`

### 5.1 执行流程

```
JVM_Clone(env, handle)
  │
  ├── Step 1: Cloneable 检查
  │   └── if (!klass->is_cloneable()) throw CloneNotSupportedException
  │       注意: 所有数组都自动实现 Cloneable
  │
  ├── Step 2: Reference 子类检查
  │   └── if (reference_type() != REF_NONE) throw CloneNotSupportedException
  │       SoftReference/WeakReference/PhantomReference 不可 clone
  │
  ├── Step 3: 分配新对象
  │   ├── if (obj->is_array())
  │   │   └── heap->array_allocate(klass, size, length, do_zero=true)
  │   └── else
  │       └── heap->obj_allocate(klass, size)
  │
  ├── Step 4: 浅拷贝
  │   └── HeapAccess<>::clone(obj(), new_obj_oop, size)
  │       通过 GC 屏障安全地复制所有字段（包括 oop 字段）
  │
  └── Step 5: Finalizer 注册
      └── if (klass->has_finalizer())
          └── InstanceKlass::register_finalizer(new_obj)
```

### 5.2 关键设计点

1. **clone 是浅拷贝**：`HeapAccess<>::clone` 只复制对象的内存内容（逐字复制），引用字段复制的是指针而非指向的对象
2. **新对象有新的 markWord**：clone 后的对象是全新分配的，有独立的对象头（独立的 hashCode、锁状态）
3. **数组 clone 包含长度**：`array_allocate` 会设置正确的 length 字段
4. **Reference 子类禁止 clone**：因为 Reference 的 referent 字段由 GC 特殊管理，clone 会破坏引用处理语义
5. **Finalizer 处理**：如果类重写了 `finalize()`，clone 出的新对象也需要注册到 Finalizer 链表

> **面试要点**：`Object.clone()` 是 native 方法，绕过了构造函数。clone 的新对象不会调用任何构造器，而是直接从源对象内存拷贝。这也是为什么 Effective Java 建议用"拷贝构造函数"或"拷贝工厂"替代 clone。

---

## 六、Object.wait/notify/notifyAll — 监视器操作

### 6.1 调用链

```
Object.wait(long timeout)              // Java
  → JVM_MonitorWait (jvm.cpp:615-629)  // JNI
    → ObjectSynchronizer::wait(obj, ms, CHECK)
      → inflate(Self, obj)             // 膨胀为 ObjectMonitor
      → monitor->wait(ms, true, Self)  // ObjectMonitor::wait

Object.notify()
  → JVM_MonitorNotify (jvm.cpp:632-636)
    → ObjectSynchronizer::notify(obj, CHECK)
      → inflate() → monitor->notify(CHECK)

Object.notifyAll()
  → JVM_MonitorNotifyAll (jvm.cpp:639-643)
    → ObjectSynchronizer::notifyall(obj, CHECK)
      → inflate() → monitor->notifyall(CHECK)
```

### 6.2 核心要点

1. **必须持有锁**：wait/notify 要求当前线程持有 obj 的监视器锁，否则 `IllegalMonitorStateException`
2. **必须膨胀**：wait/notify 的等待队列（WaitSet）只存在于 ObjectMonitor 中，轻量级锁没有
3. **JVMTI 支持**：`JVM_MonitorWait` 在调用前检查是否需要发送 `JVMTI_EVENT_MONITOR_WAIT` 事件

> 关于 ObjectMonitor 的 wait/notify 详细实现（WaitSet、EntryList、cxq 三队列协作），请参阅 `Runtime/ch03_lock_optimization.md` 的第七节。

---

## 七、FileInputStream / FileOutputStream — 文件 I/O Native 实现

### 7.1 架构概览

```
Java 层                  libjava.so (C)            内核
──────────────────      ──────────────────      ──────────
FileInputStream         FileInputStream.c
  .read0()         →     readSingle()       →   read(2)
  .readBytes()     →     readBytes()        →   read(2)
  .open0()         →     fileOpen()         →   open(2)
  .skip0()         →     IO_Lseek()         →   lseek(2)
  .available0()    →     IO_Available()     →   ioctl(FIONREAD)

FileOutputStream        FileOutputStream_md.c
  .write()         →     writeSingle()      →   write(2)
  .writeBytes()    →     writeBytes()       →   write(2)
  .open0()         →     fileOpen()         →   open(2)
                         
                         io_util.c (共享实现)
```

### 7.2 io_util.c 核心函数

#### readSingle() — 读单字节

```c
jint readSingle(JNIEnv *env, jobject this, jfieldID fid) {
    char ret;
    FD fd = GET_FD(this, fid);      // 从 Java FileDescriptor 获取 fd
    if (fd == -1) { /* Stream Closed */ }
    jint nread = IO_Read(fd, &ret, 1);  // read(fd, &ret, 1) 系统调用
    if (nread == 0) return -1;      // EOF
    if (nread == -1) /* error */;
    return ret & 0xFF;              // 返回 unsigned byte (0-255)
}
```

**性能问题**：每次读 1 字节就是 1 次系统调用 + 1 次 JNI 调用。这就是为什么 `BufferedInputStream` 默认用 8192 字节缓冲区。

#### readBytes() — 读多字节（栈缓冲区优化）

```c
#define BUF_SIZE 8192

jint readBytes(JNIEnv *env, jobject this, jbyteArray bytes,
               jint off, jint len, jfieldID fid) {
    char stackBuf[BUF_SIZE];        // 栈上 8KB 缓冲区
    char *buf = NULL;
    
    if (len > BUF_SIZE) {
        buf = malloc(len);          // 超过 8KB 才 malloc
    } else {
        buf = stackBuf;             // ≤8KB 用栈缓冲区（避免 malloc 开销）
    }
    
    FD fd = GET_FD(this, fid);
    nread = IO_Read(fd, buf, len);  // 一次系统调用
    if (nread > 0) {
        (*env)->SetByteArrayRegion(env, bytes, off, nread, (jbyte *)buf);
        // 从 C 缓冲区拷贝到 Java byte[]
    }
    
    if (buf != stackBuf) free(buf); // 只 free malloc 的
    return nread;
}
```

**为什么不直接读入 Java byte[]？**
1. GC 可能在系统调用期间移动 Java 数组（虽然 GetPrimitiveArrayCritical 可以 pin，但会阻止 GC）
2. `SetByteArrayRegion` 是安全的 JNI 接口，处理了 GC 兼容性

**BUF_SIZE = 8192 的设计**：
- 与 `BufferedInputStream` 默认缓冲区大小一致
- 8KB 在栈上是安全的（线程栈默认 1MB，8KB 仅占 0.8%）
- 避免频繁 malloc/free 的开销

#### writeSingle() — 写单字节

```c
void writeSingle(JNIEnv *env, jobject this, jint byte, 
                 jboolean append, jfieldID fid) {
    char c = (char) byte;           // 截断高 24 位
    FD fd = GET_FD(this, fid);
    if (append == JNI_TRUE) {
        n = IO_Append(fd, &c, 1);   // 追加模式
    } else {
        n = IO_Write(fd, &c, 1);    // 覆写模式
    }
}
```

#### writeBytes() — 写多字节（循环写保证完整性）

```c
void writeBytes(JNIEnv *env, jobject this, jbyteArray bytes,
                jint off, jint len, jboolean append, jfieldID fid) {
    char stackBuf[BUF_SIZE];
    char *buf = (len > BUF_SIZE) ? malloc(len) : stackBuf;
    
    // Step 1: 从 Java byte[] 拷贝到 C 缓冲区
    (*env)->GetByteArrayRegion(env, bytes, off, len, (jbyte *)buf);
    
    // Step 2: 循环写入（处理 partial write）
    off = 0;
    while (len > 0) {
        fd = GET_FD(this, fid);
        n = append ? IO_Append(fd, buf+off, len) : IO_Write(fd, buf+off, len);
        if (n == -1) { /* error */ break; }
        off += n;
        len -= n;                   // partial write 时继续写剩余部分
    }
}
```

**关键细节——partial write 循环**：`write(2)` 系统调用不保证一次写入所有字节（特别是在管道、socket、信号中断时），所以 `writeBytes` 用 while 循环确保完整写入。

### 7.3 FileOutputStream 的 open0

```c
// FileOutputStream_md.c:56-60
Java_java_io_FileOutputStream_open0(JNIEnv *env, jobject this,
                                    jstring path, jboolean append) {
    fileOpen(env, this, path, fos_fd,
             O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC));
}
```

- `new FileOutputStream("test.txt")` → `O_WRONLY | O_CREAT | O_TRUNC`（覆写模式，清空已有内容）
- `new FileOutputStream("test.txt", true)` → `O_WRONLY | O_CREAT | O_APPEND`（追加模式）

### 7.4 FileInputStream 的 open0

```c
// FileInputStream.c:60-62
Java_java_io_FileInputStream_open0(JNIEnv *env, jobject this, jstring path) {
    fileOpen(env, this, path, fis_fd, O_RDONLY);
}
```

只读模式打开，最简单的标志组合。

---

## 八、Runtime — 5 个 JVM 内存/GC 查询

> 源码：`Runtime.c`，73 行，全部是一行转发

```c
Java_java_lang_Runtime_freeMemory(...)    { return JVM_FreeMemory(); }
Java_java_lang_Runtime_totalMemory(...)   { return JVM_TotalMemory(); }
Java_java_lang_Runtime_maxMemory(...)     { return JVM_MaxMemory(); }
Java_java_lang_Runtime_gc(...)            { JVM_GC(); }
Java_java_lang_Runtime_availableProcessors(...) { return JVM_ActiveProcessorCount(); }
```

libjvm.so 中的实现：
- `JVM_FreeMemory()` → `Universe::heap()->unused()`（空闲堆大小）
- `JVM_TotalMemory()` → `Universe::heap()->capacity()`（当前已 committed 的堆大小）
- `JVM_MaxMemory()` → `Universe::heap()->max_capacity()`（-Xmx 指定的最大堆）
- `JVM_GC()` → `Universe::heap()->collect(GCCause::_java_lang_system_gc)`（触发 Full GC，除非 `-XX:+DisableExplicitGC`）
- `JVM_ActiveProcessorCount()` → `os::active_processor_count()`（考虑 cgroup 限制）

> **面试要点**：`Runtime.availableProcessors()` 在容器环境（Docker/K8s）中，如果 JDK 版本足够新（JDK 10+），会读取 cgroup 的 CPU quota/period 来计算可用核数，而不是返回宿主机的物理核数。对应源码在 `src/java.base/linux/native/libjava/CgroupMetrics.c`。

---

## 九、Thread.c — 16 个线程 Native 方法

Thread.c 通过 RegisterNatives 一次性注册 16 个 native 方法，全部委托给 `JVM_*` 函数：

| Java 方法 | JVM 函数 | 功能 |
|-----------|---------|------|
| `start0()` | JVM_StartThread | 创建 OS 线程 (pthread_create) |
| `stop0(Throwable)` | JVM_StopThread | 强制抛异常停止（已废弃） |
| `isAlive()` | JVM_IsThreadAlive | 检查线程状态 |
| `suspend0()` | JVM_SuspendThread | 挂起（已废弃） |
| `resume0()` | JVM_ResumeThread | 恢复（已废弃） |
| `setPriority0(int)` | JVM_SetThreadPriority | 设置 OS 线程优先级 |
| `yield()` | JVM_Yield | sched_yield() |
| `sleep(long)` | JVM_Sleep | ParkEvent::park() |
| `currentThread()` | JVM_CurrentThread | 读 TLS 中的 JavaThread::_threadObj |
| `countStackFrames()` | JVM_CountStackFrames | 已废弃 |
| `interrupt0()` | JVM_Interrupt | 设置中断标志 + unpark |
| `isInterrupted(boolean)` | JVM_IsInterrupted | 检查/清除中断标志 |
| `holdsLock(Object)` | JVM_HoldsLock | 检查是否持有对象锁 |
| `getThreads()` | JVM_GetAllThreads | 获取所有活跃线程 |
| `dumpThreads(Thread[])` | JVM_DumpThreads | 获取线程栈帧 |
| `setNativeName(String)` | JVM_SetNativeThreadName | pthread_setname_np |

---

## 十、Class.c — 25 个反射 Native 方法

Class.c 是 libjava.so 中注册方法最多的文件（25 个），但大部分是薄薄的 JVM_* 委托：

| 类别 | 方法 | 数量 |
|------|------|------|
| 类查找 | forName0, isInstance, isAssignableFrom | 3 |
| 类信息 | getName0, getSuperclass, getInterfaces, getModifiers | 4 |
| 类成员获取 | getDeclaredFields0, getDeclaredMethods0, getDeclaredConstructors0 | 3 |
| 泛型/注解 | getGenericSignature0, getAnnotationBytes, getTypeAnnotationBytes | 3 |
| 类特征 | isPrimitive, isInterface, isArray, isHidden | 4 |
| 安全/封装 | getProtectionDomain0, getDeclaringClass0, getEnclosingMethod0 | 3 |
| 其他 | getComponentType, desiredAssertionStatus0, getRawAnnotations | 5 |

唯一有 C 实现（不是纯委托）的是 `forName0`——它在 C 层做类名校验后调用 `JVM_FindClassFromCaller`。

---

## 十一、ClassLoader.c — 类加载核心

ClassLoader.c (524 行) 是 libjava.so 中代码量最大的文件之一，包含：

### 11.1 defineClass1

```c
Java_java_lang_ClassLoader_defineClass1(JNIEnv *env, jclass cls,
    jobject loader, jstring name, jbyteArray data, 
    jint offset, jint length, jobject pd, jstring source)
```

流程：
1. `malloc(length)` 分配 native 缓冲区
2. `GetByteArrayRegion` 从 Java byte[] 拷贝 class 字节码
3. 类名格式校验 (`VerifyFixClassname` 将 `.` 替换为 `/`)
4. 调用 `JVM_DefineClassWithSource` → 进入 HotSpot ClassFileParser

### 11.2 NativeLibrary 加载

```c
Java_java_lang_ClassLoader_00024NativeLibrary_load(...)
Java_java_lang_ClassLoader_00024NativeLibrary_unload(...)
Java_java_lang_ClassLoader_00024NativeLibrary_findEntry(...)
```

- `load` → `JVM_LoadLibrary(name)` → `dlopen()`
- `findEntry` → `JVM_FindLibraryEntry(handle, name)` → `dlsym()`
- `unload` → `JVM_UnloadLibrary(handle)` → `dlclose()`

### 11.3 findBootstrapClass

```c
Java_java_lang_ClassLoader_findBootstrapClass(...)
    → JVM_FindClassFromBootLoader(env, clname)
```

引导类加载器的本地实现入口。

---

## 十二、System.c 其他功能

### 12.1 identityHashCode

```c
Java_java_lang_System_identityHashCode(JNIEnv *env, jobject this, jobject x) {
    return JVM_IHashCode(env, x);  // 与 Object.hashCode() 走同一条路径
}
```

### 12.2 setIn0/setOut0/setErr0

```c
Java_java_lang_System_setIn0(JNIEnv *env, jclass cla, jobject stream) {
    jfieldID fid = (*env)->GetStaticFieldID(env, cla, "in", "Ljava/io/InputStream;");
    (*env)->SetStaticObjectField(env, cla, fid, stream);
}
```

这三个方法**绕过 Java 的 final 语义**，直接通过 JNI 修改 `System.in/out/err` 的 static final 字段。注释原文："They are natively implemented because they violate the semantics of the language (i.e. set final variable)."

### 12.3 initProperties

`System.initProperties()` (System.c:166-385) 是 JVM 启动时系统属性的设置入口：
- 从 `GetJavaProperties()` 获取 OS 层面的属性
- 通过 JNI 调用 `props.put(key, value)` 设置每个属性
- 涵盖：os.name/version/arch、file.separator、user.name/home/dir、java.io.tmpdir、file.encoding 等

### 12.4 mapLibraryName

```c
Java_java_lang_System_mapLibraryName(JNIEnv *env, jclass ign, jstring libname)
```

将库名映射为平台特定文件名：
- Linux: `"java"` → `"libjava.so"`（前缀 `lib` + 后缀 `.so`）
- macOS: `"java"` → `"libjava.dylib"`
- Windows: `"java"` → `"java.dll"`

---

## 十三、面试高频问题

### Q1: System.arraycopy 和 Arrays.copyOf 有什么区别？

**答**：`Arrays.copyOf` 是 Java 层的包装方法，底层调用 `System.arraycopy`。区别在于：
- `Arrays.copyOf` 会创建新数组（`new T[newLength]`），然后调用 `System.arraycopy` 复制元素
- `System.arraycopy` 不创建数组，只做拷贝

两者在 C2 编译后性能几乎相同，因为 `System.arraycopy` 标注了 `@HotSpotIntrinsicCandidate`，会被替换为 CPU 原生内存拷贝指令。

### Q2: Object.hashCode() 默认算法是什么？跟对象地址有关吗？

**答**：OpenJDK 11 默认使用 **Marsaglia xor-shift 128-bit 伪随机数生成器**（`-XX:hashCode=5`），跟对象地址**完全无关**。每个线程有 4-word 的独立状态（`_hashStateX/Y/Z/W`），无锁生成，周期 2^128-1。

hashCode=4 时才使用对象地址，但这不是默认值，且 GC 移动对象后地址会变（虽然 hashCode 一旦计算就缓存在 markWord 中不会变）。

### Q3: 为什么调用 hashCode() 会影响锁性能？

**答**：hashCode 存储在对象头 markWord 的 hash:31 位中。偏向锁模式下，markWord 存储的是偏向线程 ID，没有空间存 hashCode。因此：
- **调用 hashCode() 会导致偏向锁撤销**（revoke_and_rebias）
- 如果对象已被轻量级锁锁定，hashCode 无法写入栈上的 displaced header（不安全），**必须膨胀为重量级锁**
- 结论：**在 synchronized 代码块中调用 hashCode() 可能导致锁膨胀**

### Q4: FileInputStream.read() 一次读一个字节有多大开销？

**答**：每次 `read()` 的完整开销：
1. **Java → JNI 切换**：保存/恢复调用帧、锁定 JNI 引用
2. **系统调用**：`read(fd, &buf, 1)`——即使只读 1 字节，也要完整的 user→kernel→user 上下文切换
3. **JNI → Java 切换**：返回

实测单次 `read()` 约 1-5μs，而用 `BufferedInputStream`（8KB 缓冲区）后，只有每 8192 次才触发一次系统调用，平摊到每字节约 0.1-0.5ns。

> **结论**：永远不要裸用 `FileInputStream.read()`，至少包一层 `BufferedInputStream`。

### Q5: clone() 是深拷贝还是浅拷贝？

**答**：JVM 层面的 `Object.clone()` **永远是浅拷贝**。`JVM_Clone` 通过 `HeapAccess<>::clone()` 逐字节复制对象内容，引用字段只复制指针值。如果需要深拷贝，必须在 Java 层自行实现（递归 clone 或序列化/反序列化）。

另外，clone 绕过构造函数——新对象不会调用任何 `<init>` 方法。这是 Effective Java 推荐用拷贝构造函数替代 clone 的重要原因之一。

---

## 十四、源文件索引

### java.lang 核心

| 文件 | 行数 | 关键函数 |
|------|------|---------|
| `share/native/libjava/Object.c` | 67 | RegisterNatives(hashCode/wait/notify/notifyAll/clone), getClass |
| `share/native/libjava/Thread.c` | 72 | RegisterNatives(16 个方法: start0/sleep/yield/interrupt0...) |
| `share/native/libjava/System.c` | 456 | RegisterNatives(arraycopy/currentTimeMillis/nanoTime), initProperties, setIn0/setOut0/setErr0, mapLibraryName |
| `share/native/libjava/Class.c` | 188 | RegisterNatives(25 个方法), forName0 实现 |
| `share/native/libjava/ClassLoader.c` | 524 | defineClass1, NativeLibrary load/unload/findEntry, findBootstrapClass |
| `share/native/libjava/Runtime.c` | 73 | freeMemory/totalMemory/maxMemory/gc/availableProcessors |
| `share/native/libjava/String.c` | ~20 | intern → JVM_InternString |
| `share/native/libjava/Throwable.c` | ~150 | fillInStackTrace → JVM_FillInStackTrace |

### java.io

| 文件 | 行数 | 关键函数 |
|------|------|---------|
| `share/native/libjava/FileInputStream.c` | 111 | open0, read0, readBytes, skip0, available0 |
| `unix/native/libjava/FileOutputStream_md.c` | 73 | open0, write, writeBytes |
| `share/native/libjava/io_util.c` | 225 | readSingle, readBytes(BUF_SIZE=8192 优化), writeSingle, writeBytes(partial write 循环), throwFileNotFoundException |
| `share/native/libjava/RandomAccessFile.c` | ~150 | open0, read0/readBytes, write/writeBytes, seek, getFilePointer, length |
| `unix/native/libjava/io_util_md.c` | ~200 | IO_Read/IO_Write/IO_Append/IO_Available/IO_Lseek 的平台实现 |
| `share/native/libjava/FileDescriptor.c` | ~30 | sync → fsync(fd) |
| `share/native/libjava/ObjectStreamClass.c` | ~30 | hasStaticInitializer |
| `share/native/libjava/ObjectInputStream.c` | ~40 | latestUserDefinedLoader |
| `share/native/libjava/ObjectOutputStream.c` | ~20 | floatsToBytes, doublesToBytes |

### HotSpot 对接 (libjvm.so)

| 文件 | 关键函数 |
|------|---------|
| `hotspot/share/prims/jvm.cpp` | JVM_ArrayCopy (327-340), JVM_IHashCode (608-612), JVM_Clone (646-696), JVM_MonitorWait/Notify/NotifyAll (615-643) |
| `hotspot/share/runtime/synchronizer.cpp` | FastHashCode (710-813), get_next_hash (669-708), ReadStableMark (584-649) |
| `hotspot/share/oops/typeArrayKlass.cpp` | copy_array (126-192) |
| `hotspot/share/oops/objArrayKlass.cpp` | copy_array (256-328), do_copy (221-254) |
| `hotspot/share/utilities/copy.hpp/cpp` | conjoint_memory_atomic, conjoint_jints_atomic |
| `hotspot/os_cpu/linux_x86/copy_linux_x86.inline.hpp` | pd_conjoint_bytes (memmove), pd_conjoint_oops_atomic |
| `hotspot/cpu/x86/stubGenerator_x86_64.cpp` | generate_arraycopy_stubs (2867-2964), generate_generic_copy (2573-2865) |

---

*最后更新: 2026-02-08*
