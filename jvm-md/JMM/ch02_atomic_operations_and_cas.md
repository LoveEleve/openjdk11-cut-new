# JMM 源码分析（二）：Atomic 操作与 CAS —— 从 AtomicInteger 到 lock cmpxchg

> **核心问题**：Java 中 `AtomicInteger.compareAndSet()` 到底经过了多少层封装，最终变成了什么 CPU 指令？CAS 的原子性是如何保证的？

---

## 一、全景链路：从 Java API 到 CPU 指令

```
┌───────────────────────────────────────────────────────────────────────────────────┐
│ Java 层                                                                           │
│   AtomicInteger.compareAndSet(expect, update)                                     │
│   → Unsafe.compareAndSetInt(this, VALUE, expect, update)                          │
├───────────────────────────────────────────────────────────────────────────────────┤
│ JNI 层                                                                            │
│   Unsafe_CompareAndSetInt() (unsafe.cpp)                                          │
│   → HeapAccess<>::atomic_cmpxchg_at(x, p, offset, e)                             │
├───────────────────────────────────────────────────────────────────────────────────┤
│ Access API 层                                                                     │
│   RawAccessBarrier::atomic_cmpxchg_internal()                                     │
│   → Atomic::cmpxchg(new_value, addr, compare_value, memory_order_conservative)    │
├───────────────────────────────────────────────────────────────────────────────────┤
│ Atomic 层 (atomic.hpp)                                                            │
│   CmpxchgImpl → PlatformCmpxchg<sizeof(T)>()                                     │
├───────────────────────────────────────────────────────────────────────────────────┤
│ 平台层 (atomic_linux_x86.hpp)                                                     │
│   PlatformCmpxchg<4>::operator()                                                  │
│   → __asm__ volatile ("lock cmpxchgl %1, (%3)")                                   │
├───────────────────────────────────────────────────────────────────────────────────┤
│ CPU 指令层                                                                         │
│   lock cmpxchg [mem], reg                                                         │
│   ┌─────────────────────────────────────────────────────┐                         │
│   │ 1. 锁定缓存行（MESI 协议取得 Exclusive 状态）         │                         │
│   │ 2. 比较 [mem] == EAX ?                              │                         │
│   │    是 → [mem] = reg, ZF=1                           │                         │
│   │    否 → EAX = [mem], ZF=0                           │                         │
│   │ 3. 释放缓存行锁                                      │                         │
│   │ 4. 隐式全屏障（drain Store Buffer）                   │                         │
│   └─────────────────────────────────────────────────────┘                         │
└───────────────────────────────────────────────────────────────────────────────────┘
```

---

## 二、Atomic 类：原子操作的统一抽象

> **源码位置**：`src/hotspot/share/runtime/atomic.hpp`

### 2.1 Atomic 类的设计哲学

**问题**：不同平台提供不同的原子操作原语：
- x86：通过 `lock` 前缀实现
- ARM：通过 `LDREX`/`STREX`（Load-Link / Store-Conditional）实现
- POWER：通过 `lwarx`/`stwcx` 实现

**解决方案**：`Atomic` 类定义统一接口，通过模板特化让平台提供具体实现：

```cpp
class Atomic : AllStatic {
public:
  // 原子存储
  template<typename T, typename D>
  static void store(T store_value, volatile D* dest);

  // 原子加载
  template<typename T>
  static T load(const volatile T* dest);

  // 原子加（返回新值）
  template<typename I, typename D>
  static D add(I add_value, D volatile* dest,
               atomic_memory_order order = memory_order_conservative);

  // 原子交换（返回旧值）
  template<typename T, typename D>
  static D xchg(T exchange_value, volatile D* dest,
                atomic_memory_order order = memory_order_conservative);

  // 原子比较并交换（返回旧值）
  template<typename T, typename D, typename U>
  static D cmpxchg(T exchange_value, D volatile* dest, U compare_value,
                   atomic_memory_order order = memory_order_conservative);
};
```

### 2.2 内存顺序枚举

```cpp
enum atomic_memory_order {
  memory_order_relaxed = 0,       // 无排序保证
  memory_order_acquire = 2,       // 后续操作不上浮
  memory_order_release = 3,       // 前面操作不下沉
  memory_order_acq_rel = 4,       // acquire + release
  memory_order_conservative = 8   // 最强的双向屏障（HotSpot 默认）
};
```

**注意**：HotSpot 的默认 order 是 `memory_order_conservative`（最保守），比 C++11 的默认值（`memory_order_seq_cst`）更强。这是因为 HotSpot 历史上基于 SPARC/x86 开发，这些平台的原子操作天然提供强屏障。

### 2.3 CmpxchgImpl 的模板分发机制

`Atomic::cmpxchg()` 的调用链：

```
Atomic::cmpxchg(exchange, dest, compare, order)
    │
    ▼
CmpxchgImpl<T, D, U>()     // 根据类型分发
    │
    ├── 整型/枚举类型 → PlatformCmpxchg<sizeof(T)>()(exchange, dest, compare, order)
    │                        │
    │                        ▼
    │                   平台特化（如 atomic_linux_x86.hpp）
    │
    ├── 指针类型 → 转换后调用 PlatformCmpxchg
    │
    └── 可翻译类型（PrimitiveConversions）→ 编解码后调用 PlatformCmpxchg
```

---

## 三、x86 平台的原子操作实现

> **源码位置**：`src/hotspot/os_cpu/linux_x86/atomic_linux_x86.hpp`

### 3.1 CAS（Compare-And-Swap）

**4 字节 CAS**：
```cpp
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

**逐行解析 GCC 内联汇编**：

```
"lock cmpxchgl %1, (%3)"

操作数约束：
  输出：  "=a" (exchange_value)  → 结果存到 EAX（"a" = EAX 寄存器）
  输入0：  "r" (exchange_value)  → 新值，放到任意通用寄存器
  输入1：  "a" (compare_value)   → 期望值，必须在 EAX
  输入2：  "r" (dest)            → 目标地址，放到任意寄存器

clobbered：
  "cc"     → 会修改 FLAGS 寄存器（ZF 标志）
  "memory" → 编译器屏障（告诉编译器所有内存可能被修改）
```

**cmpxchg 指令的执行逻辑**：
```
lock cmpxchg [dest], exchange_value
─────────────────────────────────
1. 锁定缓存行（通过 MESI 协议获取 Exclusive 状态）
2. 比较 [dest] 和 EAX（compare_value）：
   - 如果相等：[dest] = exchange_value, ZF = 1
   - 如果不等：EAX = [dest], ZF = 0
3. 释放缓存行锁
4. lock 前缀副作用：刷新 Store Buffer = 全内存屏障
```

**8 字节 CAS（AMD64）**：
```cpp
template<>
template<typename T>
inline T Atomic::PlatformCmpxchg<8>::operator()(...) const {
  STATIC_ASSERT(8 == sizeof(T));
  __asm__ __volatile__ ("lock cmpxchgq %1,(%3)"
                        : "=a" (exchange_value)
                        : "r" (exchange_value), "a" (compare_value), "r" (dest)
                        : "cc", "memory");
  return exchange_value;
}
```

唯一的区别是 `cmpxchgl`（32位）变成了 `cmpxchgq`（64位）。

**1 字节 CAS**：
```cpp
template<>
template<typename T>
inline T Atomic::PlatformCmpxchg<1>::operator()(...) const {
  STATIC_ASSERT(1 == sizeof(T));
  __asm__ volatile ("lock cmpxchgb %1,(%3)"
                    : "=a" (exchange_value)
                    : "q" (exchange_value), "a" (compare_value), "r" (dest)
                    : "cc", "memory");
  return exchange_value;
}
```

注意这里用的是 `"q"` 约束（只能是 AL/BL/CL/DL），因为 `cmpxchgb` 操作 byte 级别的寄存器。

### 3.2 Atomic Add（fetch_and_add）

```cpp
template<>
template<typename I, typename D>
inline D Atomic::PlatformAdd<4>::fetch_and_add(
    I add_value, D volatile* dest, atomic_memory_order order) const {
  STATIC_ASSERT(4 == sizeof(I));
  STATIC_ASSERT(4 == sizeof(D));
  D old_value;
  __asm__ volatile ("lock xaddl %0,(%2)"
                    : "=r" (old_value)
                    : "0" (add_value), "r" (dest)
                    : "cc", "memory");
  return old_value;
}
```

**`lock xadd` 指令**：
1. 原子地将 `add_value` 加到 `[dest]`
2. 返回 `[dest]` 的**旧值**
3. `lock` 前缀 = 全屏障

这就是 `AtomicInteger.getAndAdd()` 和 `AtomicInteger.incrementAndGet()` 的底层实现。

> **注意**：HotSpot 使用的是 `FetchAndAdd` 模式，返回旧值。`Atomic::add()` 方法在内部做了 `old + add_value` 的转换来返回新值。

### 3.3 Atomic Xchg（原子交换）

```cpp
template<>
template<typename T>
inline T Atomic::PlatformXchg<4>::operator()(
    T exchange_value, T volatile* dest, atomic_memory_order order) const {
  STATIC_ASSERT(4 == sizeof(T));
  __asm__ volatile ("xchgl (%2),%0"
                    : "=r" (exchange_value)
                    : "0" (exchange_value), "r" (dest)
                    : "memory");
  return exchange_value;
}
```

**关键**：`xchg` 指令**不需要** `lock` 前缀！Intel 手册规定，`xchg` 对内存操作时**隐式加锁**。所以 `xchg` 天然就是原子的且自带全屏障。

这就是为什么 `OrderAccess::release_store_fence()` 在 x86 上使用 `xchg` —— 一条指令同时完成原子存储和全屏障。

### 3.4 CmpxchgByteUsingInt：字节级 CAS 的精妙实现

有些平台不直接支持 1 字节的原子 CAS。`Atomic::CmpxchgByteUsingInt` 提供了一个巧妙的替代方案：

```cpp
template<typename T>
T operator()(T exchange_value, T volatile* dest, T compare_value,
             atomic_memory_order order) const {
  // 1. 将目标地址对齐到 4 字节边界
  volatile uint32_t* aligned_dest = align_down(dest, sizeof(uint32_t));
  size_t offset = pointer_delta(dest, aligned_dest, 1);

  // 2. 读取包含目标字节的 4 字节整数
  uint32_t cur = *aligned_dest;

  // 3. 循环 CAS
  do {
    uint32_t new_value = cur;
    // 只修改目标字节，保持其他三个字节不变
    reinterpret_cast<uint8_t*>(&new_value)[offset] = canon_exchange_value;

    uint32_t res = cmpxchg(new_value, aligned_dest, cur, order);
    if (res == cur) break;  // 成功

    cur = res;  // 至少一个字节变了，更新视图
  } while (cur_as_bytes[offset] == canon_compare_value);  // 目标字节没变就重试
}
```

这个实现的精妙之处在于：它把 1 字节的 CAS 转化为 4 字节的 CAS，同时保护了相邻字节不被意外修改。

---

## 四、x86 原子操作的 lock 前缀原理

### 4.1 lock 前缀做了什么？

在现代 x86 CPU 上，`lock` 前缀**不再锁总线**（那是 486 时代的做法）。实际机制是：

```
lock cmpxchg [addr], reg
┌─────────────────────────────────────────────────────┐
│ 1. 检查 [addr] 所在的缓存行状态                        │
│    - 如果在 L1 cache 中且是 Exclusive/Modified 状态    │
│      → 直接在 cache 中执行，不需要锁总线                │
│    - 如果不是 → 通过 MESI 协议取得 Exclusive 状态       │
│                                                     │
│ 2. 在缓存行级别的原子操作                               │
│    - 比较 + 交换在一个不可打断的操作中完成                │
│                                                     │
│ 3. 刷新 Store Buffer                                  │
│    - 所有在 lock 指令之前的 store 都可见                 │
│    - 所有在 lock 指令之后的 load 都会重新从 cache 读      │
│    - 效果 = 全内存屏障                                  │
└─────────────────────────────────────────────────────┘
```

### 4.2 性能开销

| 操作 | 延迟（Skylake 约值） | 说明 |
|------|---------------------|------|
| 普通 `mov` store | ~1 cycle | 写入 Store Buffer |
| `lock cmpxchg`（缓存命中） | ~18 cycles | 无竞争时 |
| `lock cmpxchg`（缓存未命中） | ~40+ cycles | 需要走 MESI 协议 |
| `lock xadd` | ~18 cycles | 类似 cmpxchg |
| `xchg`（内存） | ~23 cycles | 隐式 lock |
| `lock addl $0, 0(%rsp)` | ~20 cycles | 纯屏障 |
| `mfence` | ~33 cycles | HotSpot 不用 |

---

## 五、32 位平台的特殊处理

在 32 位 x86 上，64 位（8 字节）的原子操作需要特殊处理，因为 32 位寄存器一次只能操作 4 字节：

```cpp
#else // !AMD64

extern "C" {
  // 在汇编文件 linux_x86.s 中定义
  int64_t _Atomic_cmpxchg_long(int64_t, volatile int64_t*, int64_t);
  void _Atomic_move_long(const volatile int64_t* src, volatile int64_t* dst);
}

// 32 位上的 8 字节 CAS：通过 cmpxchg8b 指令
template<>
template<typename T>
inline T Atomic::PlatformCmpxchg<8>::operator()(...) const {
  return cmpxchg_using_helper<int64_t>(_Atomic_cmpxchg_long, ...);
}

// 32 位上的 8 字节 load：需要特殊处理保证原子性
template<>
template<typename T>
inline T Atomic::PlatformLoad<8>::operator()(T const volatile* src) const {
  volatile int64_t dest;
  _Atomic_move_long(src, &dest);  // 使用 fild/fistp 或 movq 指令
  return PrimitiveConversions::cast<T>(dest);
}
```

在 32 位平台上，`_Atomic_cmpxchg_long` 使用 `lock cmpxchg8b` 指令：
- `cmpxchg8b` 比较 `EDX:EAX`（期望值）与 `[dest]` 的 8 字节
- 相等则把 `ECX:EBX`（新值）写入 `[dest]`
- 不等则把 `[dest]` 的值加载到 `EDX:EAX`

而 `_Atomic_move_long` 使用 `fild`/`fistp`（浮点指令）或 `movq`（MMX 指令）来实现 64 位原子读写，因为 32 位 x86 上普通的两次 32 位 `mov` 无法保证 64 位原子性。

---

## 六、从 AtomicInteger 到 lock cmpxchg 的完整调用链

以 `AtomicInteger.compareAndSet(1, 2)` 为例：

```
1. Java 层
   AtomicInteger.compareAndSet(1, 2)
   → Unsafe.compareAndSetInt(this, valueOffset, 1, 2)

2. JNI 调用
   → Unsafe_CompareAndSetInt(env, unsafe, obj, offset, e=1, x=2)
   
3. unsafe.cpp
   oop p = JNIHandles::resolve(obj);
   return HeapAccess<>::atomic_cmpxchg_at(x=2, p, offset, e=1) == e;

4. Access API 分发
   → RawAccessBarrier<>::atomic_cmpxchg_internal(2, addr, 1)
   → Atomic::cmpxchg(2, volatile_addr, 1, memory_order_conservative)

5. Atomic 模板分发
   → CmpxchgImpl<jint, jint, jint>()
   → PlatformCmpxchg<4>()(2, volatile_addr, 1, order)

6. 平台实现
   → __asm__ volatile ("lock cmpxchgl %1,(%3)"
                        : "=a" (exchange_value)       // 输出到 EAX
                        : "r" (2),                    // 新值 = 2
                          "a" (1),                    // 期望值 = 1 → EAX
                          "r" (volatile_addr)         // 目标地址
                        : "cc", "memory");

7. CPU 执行
   EAX = 1         (compare_value)
   ECX = 2         (exchange_value, 假设分配到 ECX)
   lock cmpxchg [addr], ECX
   if ([addr] == EAX) {    // [addr] == 1?
     [addr] = ECX;         // [addr] = 2
     ZF = 1;               // 成功
   } else {
     EAX = [addr];         // 返回当前值
     ZF = 0;               // 失败
   }
```

---

## 七、面试话术建议

### Q：CAS 底层是怎么实现的？

> **L1**：CAS 在 x86 上最终是一条 `lock cmpxchg` 指令。`cmpxchg` 做的是"比较并交换"，`lock` 前缀保证了操作的原子性和内存可见性。
>
> **L2**：从源码看，Java 的 `Unsafe.compareAndSetInt()` 经过 JNI 调用到 `unsafe.cpp`，再通过 Access API 和 Atomic 的模板分发，最终到达 `atomic_linux_x86.hpp` 中的内联汇编。HotSpot 的 `Atomic` 类用 C++ 模板元编程做了精巧的类型安全封装，按操作字节数（1/4/8）分发到不同的平台特化实现。
>
> **L3**：`lock` 前缀在现代 CPU 上不锁总线，而是通过 MESI 协议在缓存行级别加锁。它还有个副作用——刷新 Store Buffer，等同于全内存屏障。所以 CAS 不仅保证原子性，还天然保证了内存可见性。在 32 位平台上，64 位的 CAS 用的是 `lock cmpxchg8b` 指令，通过 EDX:EAX 和 ECX:EBX 两对寄存器来操作 8 字节数据。

### Q：Atomic 类为什么默认用 memory_order_conservative？

> 因为 HotSpot 历史上主要在 SPARC 和 x86 上开发，这两个平台的原子操作本身就提供强屏障语义。`memory_order_conservative` 确保在所有平台上都有最强的排序保证，避免并发 bug。在性能敏感的场景（如 GC 内部），可以显式传入 `memory_order_relaxed` 来降低屏障强度。但在 x86 上这个区别几乎没有影响，因为 `lock cmpxchg` 的 `lock` 前缀无论如何都提供全屏障——HotSpot 源码中你可以看到 `memory_order` 参数在 x86 的 CAS 实现中被注释标记为 `/* order */`，直接被忽略了。

---

## 八、关键源码文件索引

| 文件 | 作用 |
|------|------|
| `share/runtime/atomic.hpp` | Atomic 类接口定义、模板分发机制 |
| `os_cpu/linux_x86/atomic_linux_x86.hpp` | x86 平台的 CAS/xadd/xchg 实现 |
| `share/prims/unsafe.cpp` | Unsafe.compareAndSetXXX 的 native 实现 |
| `share/oops/accessBackend.inline.hpp` | Access API → Atomic 的桥接 |
