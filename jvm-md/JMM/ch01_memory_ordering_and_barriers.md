# JMM 源码分析（一）：内存屏障与 OrderAccess —— volatile 在 HotSpot 中的落地实现

> **核心问题**：Java 中 `volatile` 关键字的语义保证（可见性 + 有序性），在 JVM 源码层面是如何通过内存屏障落地到 CPU 指令的？

---

## 一、全景架构：从 Java 语义到 CPU 指令的完整链路

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                        Java 层：volatile int x = 42;                            │
├─────────────────────────────────────────────────────────────────────────────────┤
│                    JVM 字节码层：putfield / getfield                             │
│                    （ConstantPoolCacheEntry::is_volatile 标记）                   │
├────────────────────┬──────────────────────┬─────────────────────────────────────┤
│   解释器执行层       │     C1 编译器         │         C2 编译器                    │
│                    │                      │                                     │
│ bytecodeInterp:    │ BarrierSetC1:        │ BarrierSetC2:                       │
│  release_*_put()   │  membar_release()    │  MemBarRelease                      │
│  + storeload()     │  volatile_field_*()  │  + Store                            │
│  *_field_acquire() │  membar_acquire()    │  + MemBarVolatile                   │
│  + fence() [IRIW]  │  membar() [IRIW]     │  [or MemBarAcquire for load]        │
├────────────────────┴──────────────────────┴─────────────────────────────────────┤
│                     Access API (accessDecorators.hpp)                            │
│                     MO_SEQ_CST / MO_RELEASE / MO_ACQUIRE                        │
├─────────────────────────────────────────────────────────────────────────────────┤
│                    RawAccessBarrier (accessBackend.inline.hpp)                   │
│                    → OrderAccess::release_store_fence() [SEQ_CST store]          │
│                    → OrderAccess::load_acquire()        [SEQ_CST load]           │
├─────────────────────────────────────────────────────────────────────────────────┤
│                    OrderAccess (orderAccess.hpp)                                 │
│                    → 平台相关实现 (orderAccess_linux_x86.hpp)                     │
├─────────────────────────────────────────────────────────────────────────────────┤
│                    x86 CPU 指令层                                                │
│                    fence()    → lock; addl $0, 0(%rsp)                           │
│                    storeload  → lock; addl $0, 0(%rsp)                           │
│                    release    → compiler_barrier() [x86 TSO 免费]                │
│                    acquire    → compiler_barrier() [x86 TSO 免费]                │
│                    release_store_fence → xchg 指令                               │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**核心结论（先说答案）**：

1. **volatile 写** 最终变成 `xchg` 指令（自带 `lock` 语义的全屏障），或者普通 `mov` + `lock addl $0, 0(%rsp)` 的 StoreLoad 屏障
2. **volatile 读** 在 x86 上只需要编译器屏障（因为 x86 TSO 不会重排 Load-Load / Load-Store），不需要硬件屏障
3. **CAS 操作** 使用 `lock cmpxchg` 指令，自带全屏障语义
4. x86 是 **TSO（Total Store Order）** 架构，只可能发生 StoreLoad 重排序，所以 volatile 的大部分屏障在 x86 上是"免费的"

---

## 二、OrderAccess：内存屏障的核心抽象

> **源码位置**：`src/hotspot/share/runtime/orderAccess.hpp`

### 2.1 设计哲学：为什么需要这个类？

**问题**：不同 CPU 架构的内存模型差异巨大：
- x86（TSO）：只需要 StoreLoad 屏障，其他三种屏障天然保证
- ARM/POWER：所有四种屏障都需要显式指令
- SPARC TSO：类似 x86

**解决方案**：`OrderAccess` 提供统一的屏障接口，平台特定实现在 `os_cpu/` 目录下：

```cpp
// orderAccess.hpp 中定义的四种基本屏障 + acquire/release + fence
class OrderAccess : private Atomic {
 public:
  // 四种基本内存屏障
  static void loadload();    // Load1; LoadLoad; Load2    → 保证 Load1 在 Load2 之前完成
  static void storestore();  // Store1; StoreStore; Store2 → 保证 Store1 在 Store2 之前可见
  static void loadstore();   // Load1; LoadStore; Store2   → 保证 Load1 在 Store2 之前完成
  static void storeload();   // Store1; StoreLoad; Load2   → 保证 Store1 在 Load2 之前可见（最昂贵！）

  // 高级屏障
  static void acquire();     // LoadLoad + LoadStore（单向：阻止后续访问上浮）
  static void release();     // LoadStore + StoreStore（单向：阻止前面访问下沉）
  static void fence();       // 全屏障：LoadStore + StoreStore + LoadLoad + StoreLoad

  // 带语义的操作（推荐使用）
  template <typename T>
  static T load_acquire(const volatile T* p);            // load + acquire 屏障

  template <typename T, typename D>
  static void release_store(volatile D* p, T v);         // release 屏障 + store

  template <typename T, typename D>
  static void release_store_fence(volatile D* p, T v);   // release + store + fence（最强 = volatile 语义）
};
```

### 2.2 为什么 OrderAccess 继承 Atomic？

```cpp
class OrderAccess : private Atomic { ... };
```

因为 `OrderAccess` 的内部实现需要使用 `Atomic::store()` 和 `Atomic::load()` 来保证单次内存访问的原子性。`ordered_store` 和 `ordered_load` 模板方法内部就是用 `Atomic` 的操作配合 `ScopedFence` 实现的：

```cpp
template <typename FieldType, ScopedFenceType FenceType>
inline void OrderAccess::ordered_store(volatile FieldType* p, FieldType v) {
  ScopedFence<FenceType> f((void*)p);  // 构造函数调 prefix()，析构函数调 postfix()
  Atomic::store(v, p);                 // 中间执行原子存储
}
```

这是一个 **RAII 模式**：
- `ScopedFence` 的构造函数调用 `prefix()`（如 `release()` 屏障）
- 中间执行实际的 `Atomic::store`
- `ScopedFence` 的析构函数调用 `postfix()`（如 `fence()` 屏障）

### 2.3 ScopedFence 的三种模式

```cpp
enum ScopedFenceType {
  X_ACQUIRE,        // load_acquire:         无前缀 + acquire 后缀
  RELEASE_X,        // release_store:         release 前缀 + 无后缀
  RELEASE_X_FENCE   // release_store_fence:   release 前缀 + fence 后缀
};

// 模板特化：
template<> void ScopedFenceGeneral<X_ACQUIRE>::postfix()       { OrderAccess::acquire(); }
template<> void ScopedFenceGeneral<RELEASE_X>::prefix()        { OrderAccess::release(); }
template<> void ScopedFenceGeneral<RELEASE_X_FENCE>::prefix()  { OrderAccess::release(); }
template<> void ScopedFenceGeneral<RELEASE_X_FENCE>::postfix() { OrderAccess::fence();   }
```

| 操作 | ScopedFenceType | prefix() | 操作 | postfix() |
|------|-----------------|----------|------|-----------|
| `load_acquire()` | X_ACQUIRE | 无 | load | acquire() |
| `release_store()` | RELEASE_X | release() | store | 无 |
| `release_store_fence()` | RELEASE_X_FENCE | release() | store | fence() |

---

## 三、x86 平台的内存屏障实现

> **源码位置**：`src/hotspot/os_cpu/linux_x86/orderAccess_linux_x86.hpp`

### 3.1 x86 TSO 模型的"免费午餐"

x86 使用 **TSO（Total Store Order）** 内存模型，可以理解为：
- **每个 CPU 都有一个 FIFO 写缓冲区（Store Buffer）**
- 写操作先进入 Store Buffer，按序列化到主存
- 读操作直接读主存（如果 Store Buffer 中有，优先读 Store Buffer）

这意味着 x86 **天然保证**了以下顺序：
- **Load-Load**：不重排（读都是直接从主存/cache 获取）
- **Load-Store**：不重排
- **Store-Store**：不重排（Store Buffer 是 FIFO）

**唯一可能的重排序是 Store-Load**：写入 Store Buffer 后，后续的读可能在写落地主存之前就执行了。

### 3.2 x86 上的实现：大部分屏障 = 编译器屏障

```cpp
// orderAccess_linux_x86.hpp

// 编译器屏障：告诉 GCC "我在这里修改了所有内存"，阻止编译器优化重排
static inline void compiler_barrier() {
  __asm__ volatile ("" : : : "memory");
}

// 四种基本屏障在 x86 上的实现
inline void OrderAccess::loadload()   { compiler_barrier(); }  // x86 TSO 免费！
inline void OrderAccess::storestore() { compiler_barrier(); }  // x86 TSO 免费！
inline void OrderAccess::loadstore()  { compiler_barrier(); }  // x86 TSO 免费！
inline void OrderAccess::storeload()  { fence();            }  // 唯一需要真正硬件屏障！

// acquire/release 在 x86 上也是免费的
inline void OrderAccess::acquire()    { compiler_barrier(); }
inline void OrderAccess::release()    { compiler_barrier(); }
```

**关键发现**：x86 上只有 `storeload()` 和 `fence()` 需要真正的硬件屏障。

### 3.3 fence() 的实现：lock addl 的奥秘

```cpp
inline void OrderAccess::fence() {
  // 始终使用 locked addl，因为 mfence 有时更慢
#ifdef AMD64
  __asm__ volatile ("lock; addl $0,0(%%rsp)" : : : "cc", "memory");
#else
  __asm__ volatile ("lock; addl $0,0(%%esp)" : : : "cc", "memory");
#endif
  compiler_barrier();
}
```

**为什么用 `lock addl` 而不是 `mfence`？**

| 对比 | `lock addl $0, 0(%rsp)` | `mfence` |
|------|-------------------------|----------|
| 效果 | 全屏障（drain Store Buffer） | 全屏障 |
| 延迟 | ~20 cycles (Skylake) | ~33 cycles (Skylake) |
| 副作用 | 在栈顶写 0（无实际影响） | 无 |
| 实际选择 | ✅ HotSpot 选择 | ❌ 不用 |

`lock` 前缀的指令会**锁定缓存行并刷新 Store Buffer**，达到全屏障的效果。`addl $0, 0(%rsp)` 就是"在栈顶加 0"——什么也没改，但 lock 前缀保证了内存顺序。

### 3.4 release_store_fence() 的实现：用 xchg 替代

```cpp
// 以 4 字节为例
template<>
struct OrderAccess::PlatformOrderedStore<4, RELEASE_X_FENCE> {
  template <typename T>
  void operator()(T v, volatile T* p) const {
    __asm__ volatile ("xchgl (%2),%0"
                      : "=r" (v)
                      : "0" (v), "r" (p)
                      : "memory");
  }
};
```

**为什么 `release_store_fence()` 用 `xchg` 而不是 `mov` + `lock addl`？**

因为 **x86 的 `xchg` 指令自带隐式 `lock` 前缀**！Intel 手册明确规定 `xchg` 对内存操作时自动加锁。所以一条 `xchg` 指令就同时完成了：
1. 原子存储
2. 全屏障（drain Store Buffer）

这比 `release + store + fence` 三步合一更高效。

### 3.5 x86 内存屏障总结表

```
┌─────────────────────────┬──────────────────────────────────────┐
│    OrderAccess 方法       │     x86 实际生成的指令                 │
├─────────────────────────┼──────────────────────────────────────┤
│ loadload()              │ 编译器屏障（无硬件指令）                 │
│ storestore()            │ 编译器屏障（无硬件指令）                 │
│ loadstore()             │ 编译器屏障（无硬件指令）                 │
│ storeload()             │ lock; addl $0, 0(%rsp)               │
│ acquire()               │ 编译器屏障（无硬件指令）                 │
│ release()               │ 编译器屏障（无硬件指令）                 │
│ fence()                 │ lock; addl $0, 0(%rsp)               │
│ load_acquire()          │ mov（普通读）+ 编译器屏障               │
│ release_store()         │ 编译器屏障 + mov（普通写）              │
│ release_store_fence()   │ xchg（自带 lock 语义）                 │
└─────────────────────────┴──────────────────────────────────────┘
```

---

## 四、Access API：从 MO_SEQ_CST 到 OrderAccess 的桥梁

> **源码位置**：`src/hotspot/share/oops/accessDecorators.hpp` + `accessBackend.inline.hpp`

### 4.1 内存顺序装饰器

HotSpot 使用装饰器（Decorator）模式来传递内存顺序要求：

```cpp
// accessDecorators.hpp
const DecoratorSet MO_UNORDERED = UCONST64(1) << 6;   // JMM plain（无序）
const DecoratorSet MO_VOLATILE  = UCONST64(1) << 7;   // C++ volatile（编译器不重排）
const DecoratorSet MO_RELAXED   = UCONST64(1) << 8;   // JMM opaque（原子但无序）
const DecoratorSet MO_ACQUIRE   = UCONST64(1) << 9;   // JMM acquire
const DecoratorSet MO_RELEASE   = UCONST64(1) << 10;  // JMM release
const DecoratorSet MO_SEQ_CST   = UCONST64(1) << 11;  // JMM volatile（最强！）
```

**JMM ↔ HotSpot 装饰器映射**：

| JMM 语义 | HotSpot 装饰器 | 说明 |
|----------|---------------|------|
| plain access | MO_UNORDERED | 无保证，编译器/硬件随意重排 |
| opaque | MO_RELAXED | 原子性，但无排序保证 |
| acquire | MO_ACQUIRE | 后续操作不上浮 |
| release | MO_RELEASE | 前面操作不下沉 |
| **volatile** | **MO_SEQ_CST** | **顺序一致性，最强保证** |

### 4.2 MO_SEQ_CST 如何映射到 OrderAccess

在 `accessBackend.inline.hpp` 中：

```cpp
// MO_SEQ_CST load：fence（仅 IRIW）+ load_acquire
template <DecoratorSet decorators>
template <DecoratorSet ds, typename T>
inline typename EnableIf<HasDecorator<ds, MO_SEQ_CST>::value, T>::type
RawAccessBarrier<decorators>::load_internal(void* addr) {
  if (support_IRIW_for_not_multiple_copy_atomic_cpu) {
    OrderAccess::fence();         // 仅在 ARM/POWER 上需要
  }
  return OrderAccess::load_acquire(reinterpret_cast<const volatile T*>(addr));
}

// MO_SEQ_CST store：release_store_fence（最强写屏障）
template <DecoratorSet decorators>
template <DecoratorSet ds, typename T>
inline typename EnableIf<HasDecorator<ds, MO_SEQ_CST>::value>::type
RawAccessBarrier<decorators>::store_internal(void* addr, T value) {
  OrderAccess::release_store_fence(reinterpret_cast<volatile T*>(addr), value);
}
```

**在 x86 上展开就是**：
- **volatile 读**：`mov`（普通读）+ `compiler_barrier()`（acquire = 编译器屏障）
- **volatile 写**：`xchg`（= release + store + fence 三合一）

### 4.3 IRIW 问题与 support_IRIW_for_not_multiple_copy_atomic_cpu

```cpp
// globalDefinitions.hpp
#ifdef CPU_NOT_MULTIPLE_COPY_ATOMIC
const bool support_IRIW_for_not_multiple_copy_atomic_cpu = true;   // ARM/POWER
#else
const bool support_IRIW_for_not_multiple_copy_atomic_cpu = false;  // x86/SPARC
#endif
```

**IRIW（Independent Reads of Independent Writes）** 问题：
- 两个 CPU 分别写不同变量，另外两个 CPU 读这两个变量，能否看到不同的写入顺序？
- x86 是 **multi-copy atomic**（写一旦可见，对所有 CPU 同时可见），所以不存在 IRIW 问题
- ARM/POWER 不是 multi-copy atomic，需要额外的 `fence()` 来保证

**在 x86 上，这个 flag = false，所以所有 IRIW 相关的屏障都被省略**。

---

## 五、volatile 在四个执行层的实现

### 5.1 字节码解释器（C++ 解释器）

> **源码位置**：`src/hotspot/share/interpreter/bytecodeInterpreter.cpp`

**volatile 读（getfield/getstatic）**：

```cpp
if (cache->is_volatile()) {
  if (support_IRIW_for_not_multiple_copy_atomic_cpu) {
    OrderAccess::fence();                    // ARM/POWER 才需要，x86 跳过
  }
  // 使用 *_field_acquire() 方法 → 底层调用 OrderAccess::load_acquire()
  if (tos_type == atos) {
    SET_STACK_OBJECT(obj->obj_field_acquire(field_offset), -1);
  } else if (tos_type == itos) {
    SET_STACK_INT(obj->int_field_acquire(field_offset), -1);
  }
  // ... 其他类型类似
}
```

**volatile 写（putfield/putstatic）**：

```cpp
if (cache->is_volatile()) {
  // 使用 release_*_field_put() → 底层调用 OrderAccess::release_store()
  if (tos_type == itos) {
    obj->release_int_field_put(field_offset, STACK_INT(-1));
  } else if (tos_type == atos) {
    obj->release_obj_field_put(field_offset, STACK_OBJECT(-1));
  }
  // ... 其他类型类似

  // 写后加 StoreLoad 屏障！
  OrderAccess::storeload();  // → lock; addl $0, 0(%rsp) on x86
}
```

**关键观察**：
- volatile 读 = `load_acquire`（x86 上 = 普通 mov + 编译器屏障）
- volatile 写 = `release_store` + `storeload`（x86 上 = 普通 mov + `lock addl`）

### 5.2 模板解释器（汇编解释器）

> **源码位置**：`src/hotspot/cpu/x86/templateTable_x86.cpp`

模板解释器直接生成汇编代码，处理更加高效：

**putfield/putstatic 的 volatile 处理**：

```cpp
void TemplateTable::putfield_or_static(int byte_no, bool is_static, RewriteControl rc) {
  // ...
  // 从 ConstantPoolCacheEntry 中提取 is_volatile 标志
  __ movl(rdx, flags);
  __ shrl(rdx, ConstantPoolCacheEntry::is_volatile_shift);
  __ andl(rdx, 0x1);

  // ... 执行存储 ...

  // volatile 写后的屏障
  Label notVolatile;
  __ testl(rdx, rdx);
  __ jcc(Assembler::zero, notVolatile);         // 非 volatile 跳过
  volatile_barrier(Assembler::Membar_mask_bits(
    Assembler::StoreLoad | Assembler::StoreStore));  // StoreLoad 屏障
  __ bind(notVolatile);
}
```

**volatile_barrier 实现**：

```cpp
void TemplateTable::volatile_barrier(Assembler::Membar_mask_bits order_constraint) {
  if (!os::is_MP()) return;           // 单核不需要屏障
  __ membar(order_constraint);        // 生成 lock; addl 指令
}
```

**fast_storefield 也遵循同样的模式**：

```cpp
void TemplateTable::fast_storefield(TosState state) {
  // ... 存储字段 ...

  // 检查 volatile 标记
  __ testl(rdx, rdx);
  __ jcc(Assembler::zero, notVolatile);
  volatile_barrier(Assembler::Membar_mask_bits(
    Assembler::StoreLoad | Assembler::StoreStore));
  __ bind(notVolatile);
}
```

### 5.3 C1 编译器

> **源码位置**：`src/hotspot/share/c1/c1_LIRGenerator.cpp` + `src/hotspot/share/gc/shared/c1/barrierSetC1.cpp`

C1 通过 Access API 的 `MO_SEQ_CST` 装饰器来标记 volatile 访问：

```cpp
// c1_LIRGenerator.cpp - volatile store
void LIRGenerator::do_StoreField(StoreField* x) {
  bool is_volatile = x->field()->is_volatile();
  // ...
  DecoratorSet decorators = IN_HEAP;
  if (is_volatile) {
    decorators |= MO_SEQ_CST;   // 标记为顺序一致性
  }
  access_store_at(decorators, field_type, object, ...);
}
```

在 `BarrierSetC1` 中展开：

```cpp
// barrierSetC1.cpp - volatile store 的屏障
void BarrierSetC1::store_at_resolved(LIRAccess& access, LIR_Opr value) {
  bool is_volatile = (((decorators & MO_SEQ_CST) != 0) || AlwaysAtomicAccesses) && os::is_MP();

  // 1. 写前 release 屏障
  if (is_volatile && os::is_MP()) {
    __ membar_release();           // x86: compiler_barrier()
  }

  // 2. 执行存储
  if (is_volatile && !needs_patching) {
    gen->volatile_field_store(value, ...);  // 使用特殊的 volatile store
  } else {
    __ store(value, ...);
  }

  // 3. 写后全屏障（仅 multi-copy atomic CPU，即 x86）
  if (is_volatile && !support_IRIW_for_not_multiple_copy_atomic_cpu) {
    __ membar();                   // x86: lock; addl $0, 0(%rsp)
  }
}

// barrierSetC1.cpp - volatile load 的屏障
void BarrierSetC1::load_at_resolved(LIRAccess& access, LIR_Opr result) {
  bool is_volatile = ...;

  // 1. 读前 fence（仅 IRIW CPU，x86 跳过）
  if (support_IRIW_for_not_multiple_copy_atomic_cpu && is_volatile) {
    __ membar();
  }

  // 2. 执行加载
  if (is_volatile && !needs_patching) {
    gen->volatile_field_load(...);
  } else {
    __ load(...);
  }

  // 3. 读后 acquire 屏障
  if (is_volatile && os::is_MP()) {
    __ membar_acquire();           // x86: compiler_barrier()
  }
}
```

### 5.4 C2 编译器

> **源码位置**：`src/hotspot/share/gc/shared/c2/barrierSetC2.cpp`

C2 使用 `MemBar` 节点在 IR 图中表示屏障：

```cpp
// barrierSetC2.cpp - volatile store
C2AccessFence(C2Access& access) {
  if (is_write) {
    if (is_volatile || is_release) {
      _leading_membar = kit->insert_mem_bar(Op_MemBarRelease);
    }
  }
}

~C2AccessFence() {
  if (is_write) {
    // x86 上：volatile 写后插入 MemBarVolatile
    if (is_volatile && !support_IRIW_for_not_multiple_copy_atomic_cpu) {
      Node* mb = kit->insert_mem_bar(Op_MemBarVolatile, n);
      // 建立 store-pair 关系，帮助后续优化
      MemBarNode::set_store_pair(_leading_membar->as_MemBar(), mb->as_MemBar());
    }
  } else {
    // volatile 读后插入 MemBarAcquire
    if (is_volatile || is_acquire) {
      Node* mb = kit->insert_mem_bar(Op_MemBarAcquire, n);
      mb->as_MemBar()->set_trailing_load();
    }
  }
}
```

**C2 volatile 写的 IR 节点序列**：
```
MemBarRelease        ← release 屏障
  ↓
Store                ← 实际的写操作
  ↓
MemBarVolatile       ← StoreLoad 屏障（x86 = lock addl）
```

**C2 volatile 读的 IR 节点序列**：
```
Load                 ← 实际的读操作
  ↓
MemBarAcquire        ← acquire 屏障（x86 = 编译器屏障）
```

---

## 六、Unsafe 类的 volatile 操作

> **源码位置**：`src/hotspot/share/prims/unsafe.cpp`

### 6.1 putXXXVolatile / getXXXVolatile

```cpp
// 通用 Volatile 读
T get_volatile() {
  if (_obj == NULL) {
    // 堆外内存：使用 RawAccess<MO_SEQ_CST>
    volatile T ret = RawAccess<MO_SEQ_CST>::load(addr());
    return normalize_for_read(ret);
  } else {
    // 堆内存：使用 HeapAccess<MO_SEQ_CST>
    T ret = HeapAccess<MO_SEQ_CST>::load_at(_obj, _offset);
    return normalize_for_read(ret);
  }
}

// 通用 Volatile 写
void put_volatile(T x) {
  if (_obj == NULL) {
    RawAccess<MO_SEQ_CST>::store(addr(), normalize_for_write(x));
  } else {
    HeapAccess<MO_SEQ_CST>::store_at(_obj, _offset, normalize_for_write(x));
  }
}
```

最终都通过 `MO_SEQ_CST` 装饰器走到 `OrderAccess::release_store_fence()` / `OrderAccess::load_acquire()`。

### 6.2 Unsafe 的 Fence 操作

```cpp
UNSAFE_LEAF(void, Unsafe_LoadFence(JNIEnv *env, jobject unsafe)) {
  OrderAccess::acquire();     // x86: compiler_barrier()
} UNSAFE_END

UNSAFE_LEAF(void, Unsafe_StoreFence(JNIEnv *env, jobject unsafe)) {
  OrderAccess::release();     // x86: compiler_barrier()
} UNSAFE_END

UNSAFE_LEAF(void, Unsafe_FullFence(JNIEnv *env, jobject unsafe)) {
  OrderAccess::fence();       // x86: lock; addl $0, 0(%rsp)
} UNSAFE_END
```

### 6.3 CAS 操作

```cpp
UNSAFE_ENTRY(jboolean, Unsafe_CompareAndSetInt(..., jint e, jint x)) {
  oop p = JNIHandles::resolve(obj);
  if (p == NULL) {
    volatile jint* addr = (volatile jint*)index_oop_from_field_offset_long(p, offset);
    return RawAccess<>::atomic_cmpxchg(x, addr, e) == e;
  } else {
    return HeapAccess<>::atomic_cmpxchg_at(x, p, (ptrdiff_t)offset, e) == e;
  }
} UNSAFE_END
```

最终走到 `Atomic::cmpxchg()` → x86 上的 `lock cmpxchg` 指令：

```cpp
// atomic_linux_x86.hpp
template<>
template<typename T>
inline T Atomic::PlatformCmpxchg<4>::operator()(
    T exchange_value, T volatile* dest, T compare_value,
    atomic_memory_order /* order */) const {
  STATIC_ASSERT(4 == sizeof(T));
  __asm__ volatile ("lock cmpxchgl %1,(%3)"
                    : "=a" (exchange_value)
                    : "r" (exchange_value), "a" (compare_value), "r" (dest)
                    : "cc", "memory");
  return exchange_value;
}
```

**注意**：`lock cmpxchg` 的 `memory_order` 参数被忽略了！因为在 x86 上 `lock` 前缀本身就提供了全屏障语义，无论传什么 order 都一样。

---

## 七、volatile 在 x86 上的完整指令对照

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                     Java volatile 操作 → x86 指令映射                         │
├──────────────────────────┬───────────────────────────────────────────────────┤
│ Java 操作                 │ x86 生成的指令                                    │
├──────────────────────────┼───────────────────────────────────────────────────┤
│ volatile int 读           │ mov (%addr), %eax                                │
│                          │ [编译器屏障]                                       │
│                          │ 【说明】x86 TSO 保证 load 不重排，只需编译器屏障     │
├──────────────────────────┼───────────────────────────────────────────────────┤
│ volatile int 写           │ (方式A) xchg %eax, (%addr)                       │
│                          │         → release_store_fence 路径                 │
│                          │ (方式B) mov %eax, (%addr)                         │
│                          │         lock; addl $0, 0(%rsp)                    │
│                          │         → release_store + storeload 路径           │
├──────────────────────────┼───────────────────────────────────────────────────┤
│ volatile long 读          │ mov (%addr), %rax  (64位天然原子)                  │
│                          │ [编译器屏障]                                       │
├──────────────────────────┼───────────────────────────────────────────────────┤
│ volatile long 写          │ xchgq %rax, (%addr) 或 mov + lock addl            │
├──────────────────────────┼───────────────────────────────────────────────────┤
│ Unsafe.compareAndSetInt  │ lock cmpxchgl %ecx, (%addr)                       │
│                          │ 【说明】lock 前缀 = 全屏障 + 原子比较交换            │
├──────────────────────────┼───────────────────────────────────────────────────┤
│ Unsafe.getIntVolatile    │ mov (%addr), %eax + 编译器屏障                     │
├──────────────────────────┼───────────────────────────────────────────────────┤
│ Unsafe.putIntVolatile    │ xchg 或 mov + lock addl                           │
├──────────────────────────┼───────────────────────────────────────────────────┤
│ AtomicInteger.getAndAdd  │ lock xaddl %eax, (%addr)                          │
│                          │ 【说明】lock xadd = 原子加 + 全屏障                 │
├──────────────────────────┼───────────────────────────────────────────────────┤
│ Unsafe.fullFence()       │ lock; addl $0, 0(%rsp)                            │
│ Unsafe.loadFence()       │ [编译器屏障]                                       │
│ Unsafe.storeFence()      │ [编译器屏障]                                       │
└──────────────────────────┴───────────────────────────────────────────────────┘
```

---

## 八、面试话术建议

### Q：volatile 在 JVM 层面是怎么实现的？

> **三层回答法**：
>
> **L1（概念层）**：volatile 的语义是"可见性 + 有序性"。可见性靠的是 Store Buffer 的强制刷新；有序性靠的是内存屏障阻止重排序。在 JSR-133 的 Cookbook 中定义了四种屏障：LoadLoad、StoreStore、LoadStore、StoreLoad，但实际在 x86 上只有 StoreLoad 需要真正的硬件指令。
>
> **L2（源码层）**：HotSpot 有一个 `OrderAccess` 类，在 `orderAccess.hpp` 中定义了统一的屏障接口。每个平台有自己的实现，x86 的在 `orderAccess_linux_x86.hpp`。volatile 写最终调用 `release_store_fence()`，在 x86 上生成 `xchg` 指令（自带 lock 语义）；volatile 读调用 `load_acquire()`，在 x86 上就是普通 `mov` 加编译器屏障。所有这些操作通过 Access API 的 `MO_SEQ_CST` 装饰器统一调度。
>
> **L3（指令层）**：x86 是 TSO 模型，只有 Store-Load 可能重排。volatile 写后面的 StoreLoad 屏障用的是 `lock addl $0, 0(%rsp)`，这比 `mfence` 快约 40%。CAS 操作用 `lock cmpxchg`，`lock` 前缀本身就是全屏障。所以在 x86 上 volatile 的主要开销集中在写操作（需要 lock 指令刷新 Store Buffer），而读操作几乎零开销。

### Q：为什么 x86 上 volatile 读不需要屏障？

> 因为 x86 是 TSO（Total Store Order）模型。TSO 保证：所有 load 操作按程序顺序执行，所有 store 操作按程序顺序可见。唯一可能的重排是 Store-Load，就是说写入 Store Buffer 后，后续读可能在写落地之前执行。所以 volatile 读只需要一个编译器屏障防止 GCC/Clang 优化重排，硬件层面是免费的。但在 ARM/POWER 上就不行了，那些是弱内存模型，需要 `dmb` / `lwsync` 等硬件屏障。

---

## 九、关键源码文件索引

| 文件 | 作用 |
|------|------|
| `share/runtime/orderAccess.hpp` | 内存屏障统一接口定义 |
| `os_cpu/linux_x86/orderAccess_linux_x86.hpp` | x86 平台的屏障实现 |
| `share/runtime/atomic.hpp` | 原子操作统一接口 |
| `os_cpu/linux_x86/atomic_linux_x86.hpp` | x86 平台的 CAS/xadd/xchg 实现 |
| `share/oops/accessDecorators.hpp` | MO_SEQ_CST 等内存顺序装饰器定义 |
| `share/oops/accessBackend.inline.hpp` | MO_SEQ_CST → OrderAccess 的映射逻辑 |
| `share/prims/unsafe.cpp` | Unsafe 类 volatile/CAS 操作的 native 实现 |
| `share/interpreter/bytecodeInterpreter.cpp` | C++ 解释器中 volatile 处理 |
| `cpu/x86/templateTable_x86.cpp` | x86 模板解释器中 volatile 屏障 |
| `share/c1/c1_LIRGenerator.cpp` | C1 编译器 volatile 字段处理 |
| `share/gc/shared/c1/barrierSetC1.cpp` | C1 volatile 屏障生成 |
| `share/gc/shared/c2/barrierSetC2.cpp` | C2 volatile 屏障生成（MemBar 节点） |
| `share/utilities/globalDefinitions.hpp` | support_IRIW_for_not_multiple_copy_atomic_cpu 定义 |
