# Chapter 5: 面试专题 — 对象生命周期源码级深度问答

> **系列**：Runtime System — 对象生命周期  
> **环境**：OpenJDK 11, `-Xms8g -Xmx8g -XX:+UseG1GC -XX:-UseBiasedLocking`, LP64  
> **前置**：Ch1（对象头）、Ch2（对象分配）、Ch3（锁优化）、Ch4（对象终结与引用处理）  
> **约定**：本文全部分析**排除偏向锁**（JDK 15 废弃, JDK 18 默认关闭, JDK 25 移除）

---

## 使用方法

本文按**四大主题**组织面试题，每题包含：
- **基础回答**：一两句话概括（适合 30 秒快答）
- **源码级深入**：引用具体文件和行号（适合追问）
- **数据佐证**：关键数值和 GDB 验证方法
- **易错点**：常见误区标注

难度标记：⭐ 基础 | ⭐⭐ 中级 | ⭐⭐⭐ 高级 | ⭐⭐⭐⭐ 专家

---

## 一、对象头与 markWord（Ch1）

### Q1: 一个 Java 对象在内存中的布局是什么？占多少字节？ ⭐

**快答**：对象头 + 实例数据 + 对齐填充。对象头由 mark word（8B）+ klass pointer 组成。

**深入**：

HotSpot 中所有 Java 对象的 C++ 基类是 `oopDesc`（`oops/oop.hpp`），只有两个字段：

```
偏移 0:  volatile markOop _mark          (8 字节)
偏移 8:  union { Klass* _klass;           (8 字节 / 未压缩)
                 narrowKlass _compressed_klass; (4 字节 / 压缩) }
```

**标准环境下的实例对象**（压缩 klass 开启，这是 HeapSize < 32GB 的默认设置）：
- 对象头 = 8（mark）+ 4（compressed klass）= **12 字节**
- klass 后面有 4 字节 gap，可以被第一个 int/float 字段复用
- `new Object()` 实际大小 = 16 字节（12B 头 + 4B 填充/对齐到 8）

**数组对象**：在 klass pointer 后多一个 4 字节 length 字段：
- 压缩模式：8（mark）+ 4（klass）+ 4（length）= **16 字节**头
- 非压缩模式：8（mark）+ 8（klass）+ 4（length）+ 4（padding）= **24 字节**头

> **源码**：`instanceOop.hpp` 的 `base_offset_in_bytes()` 返回实例数据起始偏移；`arrayOop.hpp` 的 `header_size()` 返回数组头大小。

**易错点**：面试常说"对象头 12 字节"是在压缩指针开启时。如果堆 > 32GB（`-XX:-UseCompressedOops`），klass pointer 为 8 字节，对象头变为 16 字节。

---

### Q2: markWord 的 64 位布局是什么？包含哪些信息？ ⭐⭐

**快答**：低 2 位是锁标志（`01`=无锁, `00`=轻量级锁, `10`=重量级锁, `11`=GC 标记），中间有 4 位 GC age（最大 15），31 位 identity hashCode。

**深入**（`markOop.hpp`）：

```
  63                  38 37         8  7   6   3  2    1   0
 +----------------------+-----------+---+-----+---+--------+
 |    unused (25 bits)  | hash (31) |cms| age | 0 |  lock  |
 +----------------------+-----------+---+-----+---+--------+
```

| 字段 | 位数 | shift | 说明 |
|------|------|-------|------|
| lock | 2 | 0 | 锁标志 |
| biased_lock | 1 | 2 | 已废弃，恒 0 |
| age | 4 | 3 | GC 分代年龄 |
| hash | 31 | 8 | identity hashCode |

新对象的初始 mark word：`markOopDesc::prototype()` = `0x0000000000000001`（无锁、无 hash、age=0）。

**不同锁状态下 mark word 的含义完全不同**：
- `01`（无锁）：上面的标准布局
- `00`（轻量级锁）：整个 64 位是指针 → 栈上 `BasicLock`（因为栈地址 8 字节对齐，低位天然为 0）
- `10`（重量级锁）：`ObjectMonitor* | 0x2`，原始 mark 保存在 `ObjectMonitor._header` 中
- `11`（GC）：forwarding pointer | 0x3

```cpp
// markOop.hpp 中的关键判断
bool is_locked()   const { return (value() & 0x3) != 1; }
bool has_locker()  const { return (value() & 0x3) == 0; }  // 轻量级锁
bool has_monitor() const { return (value() & 0x2) != 0; }  // 重量级锁
```

**易错点**：很多人背"锁标志位 2 位"但不知道轻量级锁时整个 mark word 都变成了指针——hash、age 全部"消失"了，需要从 displaced header 中找回。

---

### Q3: 对象的 hashCode 是什么时候生成的？存在哪？ ⭐⭐

**快答**：**懒生成**——第一次调用 `Object.hashCode()` 或 `System.identityHashCode()` 时才计算，之后写入 mark word 的 hash 字段（bit 8-38）。

**深入**（`synchronizer.cpp`）：

入口是 `ObjectSynchronizer::FastHashCode()`，它根据对象当前的锁状态走三条路径：

1. **重量级锁（`10`）**：从 `ObjectMonitor._header` 中读/写 hash
2. **轻量级锁（`00`）**：从栈上 `displaced_header` 中读/写 hash
3. **无锁（`01`）**：直接在对象 mark word 中 CAS 写入 hash

hash 生成算法由 `-XX:hashCode=N` 控制（`synchronizer.cpp: get_next_hash()`）：

| 值 | 算法 | 说明 |
|----|------|------|
| 0 | Park-Miller RNG | 随机数 |
| 1 | `(addr ^ GCT) >> 3` | 地址异或 |
| 2 | 常量 1 | 测试用 |
| 3 | 自增序列 | 不推荐 |
| 4 | 对象地址低位 | 简单 |
| **5 (默认)** | **Marsaglia xor-shift** | **线程局部，无竞争** |

默认算法 5 用线程局部的 `_hashStateX/Y/Z/W` 四个变量做 xor-shift128，没有全局竞争。如果算出来是 0，会替换为 `0xBAD`（因为 0 表示"未计算"）。

**追问：轻量级锁下调用 hashCode() 会怎样？**

会**强制膨胀为重量级锁**。因为轻量级锁的 mark word 整体是指针，没有空间存 hash。displaced header 中写 hash 后，解锁时 CAS 恢复 mark word 就能带上 hash，但如果发生竞争就会丢失。所以 HotSpot 选择直接膨胀到 ObjectMonitor，用 `_header` 字段安全保存 hash。

---

### Q4: `new Object()` 的 mark word 初始值是多少？ ⭐

**快答**：`0x0000000000000001`，即 `markOopDesc::prototype()`。

**含义**：hash=0（未计算）, age=0, biased_lock=0, lock=01（无锁）。

```cpp
// markOop.hpp
static markOop prototype() {
  return markOop(no_hash_in_place | no_lock_in_place);  // 0 | 1 = 0x1
}
```

这个值在对象初始化时写入（`memAllocator.cpp:412`），解释器汇编快速路径也直接写常量 `0x1`。

---

### Q5: GC 移动对象时，mark word 里的信息怎么办？ ⭐⭐⭐

**快答**：GC 需要用 mark word 存 forwarding pointer（`ptr | 11`），所以必须先保存原始 mark word，GC 结束后恢复。

**深入**（`markOop.inline.hpp`）：

```cpp
bool markOopDesc::must_be_preserved(oop obj) const {
  if (is_marked()) return false;   // 已是 GC 标记
  if (is_locked()) return true;    // 被锁定 → 必须保存
  if (has_no_hash()) return false; // 无 hash 且无锁 → 可重建
  return true;                     // 有 hash → 必须保存
}
```

保存策略：
- **被锁定**（mark 指向 BasicLock 或 Monitor）：必须保存，否则解锁时找不回原始 mark
- **有 hashCode**：必须保存，否则 hash 值丢失
- **无锁 + 无 hash**：不需要保存，GC 后用 `prototype_for_object()` 重建即可（只有 age 需要重算）

age 的读写也要考虑锁状态——被锁定时从 `displaced_mark` 读取，正常时从 mark word 直接读取。age 最大值 15（4 bit），这就是 `-XX:MaxTenuringThreshold` 上限为 15 的根本原因。

---

## 二、对象分配链路（Ch2）

### Q6: `new MyClass()` 在 JVM 内部经历了哪些步骤？ ⭐

**快答**：字节码 `0xBB` → 类检查 → 大小计算 → TLAB 快速分配 → 对象初始化（清零 + 设 mark + 设 klass）。

**深入**：完整链路分 6 层：

```
L0  解释器汇编 TLAB bump-the-pointer         ~5 指令, ~10ns, 99%+
L1  MemAllocator::allocate_inside_tlab()      ~20 指令
L2  TLAB slow (refill: 废弃旧 TLAB → 新 TLAB) CAS, ~100ns
L3  HeapRegion CAS 分配                       ~200ns
L4  attempt_allocation_slow (Heap_lock)       ~1μs, region 满
L5  触发 GC (STW)                             ~10ms
L6  OOM                                       抛异常
```

解释器快速路径（`templateTable_x86.cpp:3991`）全部在 x86 汇编中完成：
1. 检查类已解析、已初始化、无 finalizer
2. `top = tlab._top; new_top = top + size; if (new_top > tlab._end) goto slow;`
3. `tlab._top = new_top; return top;`
4. 清零字段区域
5. 写 mark word = `0x1`，写 klass pointer

**只有当快速路径的任何条件不满足时，才进入 C++ 慢速路径**：`InterpreterRuntime::_new()` → `InstanceKlass::allocate_instance()` → `MemAllocator::allocate()`。

---

### Q7: 什么是 TLAB？为什么需要它？ ⭐⭐

**快答**：Thread Local Allocation Buffer——每个线程私有的一小块 Eden 内存。分配对象时直接 bump-the-pointer，**无锁、无 CAS**。

**为什么需要**：如果所有线程都直接在 Eden 中分配，需要 CAS 竞争 `_top` 指针。TLAB 把竞争从"每次对象分配"降低到"每次 TLAB refill"——refill 频率大约是分配频率的 1/50 到 1/100。

**关键参数**：

| 参数 | 默认 | 说明 |
|------|------|------|
| `-XX:+UseTLAB` | true | 启用 TLAB |
| `-XX:TLABSize=N` | 0（自动） | 初始大小，0 = 自动计算 |
| `-XX:+ResizeTLAB` | true | GC 后自适应调整大小 |
| `-XX:TLABRefillWasteFraction=N` | 64 | 浪费阈值 = desired_size / N |
| `-XX:TLABWasteIncrement=N` | 4 | slow alloc 时阈值增量（HeapWords） |

**TLAB refill 决策**（`memAllocator.cpp:297`）：

当 TLAB 剩余空间不够当前对象时，JVM 面临选择：
- `剩余空间 > refill_waste_limit` → 保留当前 TLAB，这次直接在堆上分配
- `剩余空间 ≤ refill_waste_limit` → 废弃当前 TLAB（填充 dummy 对象保持 parsable），申请新 TLAB

每次走 slow path 时，`refill_waste_limit += TLABWasteIncrement(4)`，逐步放宽废弃条件。GC 时重置。

**TLAB 大小自适应**（`threadLocalAllocBuffer.cpp: resize()`）：

GC 后根据线程的分配历史重新计算：`desired_size = alloc_rate / target_refills`，其中 `target_refills = 50 × 线程权重 / 总权重`。使用 EMA 平滑。

---

### Q8: G1 中对象分配的底层是怎么做的？ ⭐⭐⭐

**快答**：在 HeapRegion 内部做 bump-the-pointer，单线程用 `_top += size`，多线程用 CAS。

**深入**（`heapRegion.inline.hpp`）：

```cpp
// 单线程路径（TLAB 内部、或持有 Heap_lock 时）
HeapWord* HeapRegion::allocate_impl(size_t min, size_t desired, size_t* actual) {
  HeapWord* obj = top();
  size_t available = pointer_delta(end(), obj);
  size_t want = MIN2(desired, available);
  if (want >= min) {
    set_top(obj + want);      // 直接推进 top
    *actual = want;
    return obj;
  }
  return NULL;
}

// 多线程路径（并行 GC 时）
HeapWord* HeapRegion::par_allocate_impl(size_t min, size_t desired, size_t* actual) {
  do {
    HeapWord* obj = top();
    size_t available = pointer_delta(end(), obj);
    size_t want = MIN2(desired, available);
    if (want >= min) {
      HeapWord* new_top = obj + want;
      HeapWord* result = Atomic::cmpxchg(new_top, &_top, obj);  // CAS
      if (result == obj) { *actual = want; return obj; }
      // CAS 失败 → 重试
    } else {
      return NULL;
    }
  } while (true);
}
```

**分配链路**：`G1Allocator::attempt_allocation()` → `MutatorAllocRegion::attempt_allocation()` → `HeapRegion::allocate()`。如果当前 alloc region 满了 → `attempt_allocation_slow()` → 加 `Heap_lock` → 重试 → 新 region → 如果还不行 → 触发 GC → 再重试 → 最终 OOM。

**大对象（Humongous）**：`> Region/2 = 2MB`（标准 4MB region）的对象直接分配到连续的 Old region 中，不走 TLAB。

---

### Q9: 两种 OOM 有什么区别？ ⭐⭐

**快答**：`Java heap space` = 堆真的满了；`GC overhead limit exceeded` = GC 花了 98%+ 的时间但只回收了不到 2% 的堆。

**深入**（`memAllocator.cpp:115`）：

```cpp
if (!_overhead_limit_exceeded) {
  report_java_out_of_memory("Java heap space");
  THROW_OOP_(Universe::out_of_memory_error_java_heap(), true);
} else {
  report_java_out_of_memory("GC overhead limit exceeded");
  THROW_OOP_(Universe::out_of_memory_error_gc_overhead_limit(), true);
}
```

`GC overhead limit` 由 `-XX:+UseGCOverheadLimit`（默认 true）控制。它的存在是为了避免程序陷入"疯狂 GC 但分配极少"的假死状态——与其慢慢耗死，不如快速失败。

**实战**：如果遇到 `GC overhead limit exceeded`，通常说明堆中有大量存活对象（缓存未清理、内存泄漏），单纯加大堆往往只是推迟崩溃。

---

### Q10: 为什么有 finalizer 的类不能走解释器快速路径？ ⭐⭐

**快答**：因为有 finalizer 的对象需要在 `<init>` 完成后注册到 FinalizerThread，而快速路径在汇编中完成，无法处理这个注册逻辑。

**深入**：

解释器快速路径检查 `InstanceKlass::layout_helper()` 的 `_lh_instance_slow_path_bit`。这个 bit 在以下情况被设置：
- 类有非空 `finalize()` 方法（`JVM_ACC_HAS_FINALIZER` 标志位 `0x40000000`）
- 类有异常布局（极少见）

一旦命中，跳转到 `InterpreterRuntime::_new()` 的 C++ 慢速路径，分配完成后通过 `InstanceKlass::register_finalizer()` 调用 `java.lang.ref.Finalizer.register(Object)` 将对象注册到 FinalizerThread。

**注意**：即使子类没有重写 `finalize()`，只要父类有非空 `finalize()`，子类也继承 `HAS_FINALIZER` 标志。但 `Object.finalize()` 本身是空方法（只有 `return` 字节码），**不设置**该标志。

---

## 三、锁优化与 synchronized（Ch3）

### Q11: synchronized 的锁升级过程是什么？ ⭐⭐

**快答**：（排除偏向锁）两级升级：无锁 `01` → 轻量级锁 `00` → 重量级锁 `10`。膨胀是单向的，只能在 safepoint 缩减回去。

**深入**：

**1. 无锁 → 轻量级锁**：

解释器汇编快速路径（`interp_masm_x86.cpp:1152-1234`）：
```
① 在栈帧的 BasicObjectLock 中准备 displaced header = mark | 1
② lock cmpxchg 将对象 mark word CAS 为 BasicLock 地址
③ 成功 → 加锁完成（~10ns，一条 CAS 指令）
④ 失败 → 检查是否递归（(mark - rsp) & (7 - page_size) == 0？）
   递归 → displaced header 置 NULL
   非递归 → 进入 slow_case
```

**2. 轻量级锁 → 重量级锁**：

当 CAS 失败且不是递归时，进入 `ObjectSynchronizer::slow_enter()`（`synchronizer.cpp:339`）→ `inflate()` 分配 ObjectMonitor → `ObjectMonitor::enter()` 获取锁。

**膨胀触发条件**：
1. 轻量级锁 CAS 失败（真正的竞争）
2. 轻量级锁下调用 `hashCode()`
3. 调用 `Object.wait()`
4. JNI `MonitorEnter`

---

### Q12: inflate() 是怎么把轻量级锁膨胀成 ObjectMonitor 的？ ⭐⭐⭐

**快答**：`inflate()` 是一个无限循环，根据对象 mark word 的四种状态分别处理。核心是**两阶段协议**——先 CAS 写入瞬态 `INFLATING(0)` 标记，再安装 ObjectMonitor。

**深入**（`synchronizer.cpp:1387-1583`）：

四种 case：

| mark 状态 | 处理 |
|-----------|------|
| 已膨胀（`has_monitor`） | 直接返回 monitor 指针 |
| `INFLATING(0)` | 其他线程正在膨胀，自旋/yield 等待 |
| 轻量级锁（`has_locker`） | ① `omAlloc()` 分配 monitor → ② CAS mark 为 `0`（INFLATING） → ③ 从 displaced header 拷贝原始 mark 到 `monitor._header` → ④ 设 `_owner = BasicLock*` → ⑤ `release_set_mark(encode(monitor))` 安装最终 mark |
| 无锁（`is_neutral`） | ① `omAlloc()` → ② 设 `_header = mark`，`_owner = NULL` → ③ CAS 安装 monitor，失败则重试 |

**为什么需要 INFLATING(0) 两阶段？**

假设线程 A 持有轻量级锁，线程 B 要膨胀。如果 B 直接 CAS 写入 monitor 编码，线程 A 的 `unlock` CAS 会失败（因为 mark 变了），A 进入慢速路径。但问题是：B 需要先读取 displaced header（在 A 的栈上）拷贝到 monitor._header，这不是原子的。如果 A 在 B 读取期间 CAS 恢复了 mark word，hashCode 就可能丢失。

所以 HotSpot 设计了 `0` 作为瞬态"正在膨胀"标记：B 先 CAS 写 `0`，成功后再安全地拷贝 displaced header，最后安装 monitor。期间其他线程看到 `0` 会自旋等待。

---

### Q13: ObjectMonitor::enter() 的获取锁流程是什么？ ⭐⭐⭐

**快答**：五步：① CAS `_owner` → ② 递归检测 → ③ BasicLock 转换 → ④ TrySpin 自旋 → ⑤ `EnterI()` 阻塞排队。

**深入**（`objectMonitor.cpp:265-419`）：

```
步骤 1: CAS _owner NULL→Self
        成功 → 获取锁，返回（最快路径，~10ns）

步骤 2: _owner == Self
        → _recursions++，递归加锁

步骤 3: is_lock_owned(current_owner)
        → 对方是 BasicLock 地址且在本线程栈上
        → _owner = Self, _recursions = 1
        (轻量级锁→重量级锁转换期间的特殊处理)

步骤 4: TrySpin (Knob_SpinEarly=1)
        → 自适应自旋，尝试在不阻塞的情况下获取
        成功 → 获取锁，返回

步骤 5: EnterI()
        → 阻塞排队（最慢路径）
```

---

### Q14: EnterI() 的阻塞排队是怎么实现的？ ⭐⭐⭐⭐

**快答**：CAS 将 ObjectWaiter 推入 `_cxq` 链表（LIFO），然后进入 park/unpark 循环。

**深入**（`objectMonitor.cpp:442-665`）：

三个阶段：

**阶段一：最后尝试**
- `TryLock()` + `TrySpin()` — 入队前再试一次，如果这时锁释放了可以直接获取

**阶段二：入队**
```cpp
// 分配 ObjectWaiter（在栈上）
ObjectWaiter node(Self);
node._prev = NULL;
node.TState = ObjectWaiter::TS_CXQ;

for (;;) {
  node._next = _cxq;
  if (Atomic::cmpxchg(&node, &_cxq, node._next) == node._next)
    break;  // CAS push 到 _cxq 头部（LIFO）
}
```

如果当前没有 `_Responsible` 线程（负责定时 unpark 防止死锁），当前线程自荐为 `_Responsible`。

**阶段三：park 循环**
```
loop:
  TryLock() → 成功 break
  TrySpin() → 成功 break
  if (Self == _Responsible)
    os::PlatformEvent::park(timeout)   // 定时 park，指数退避 1ms→8ms→64ms→MAX
  else
    os::PlatformEvent::park()          // 无限等待
  // 被 unpark 后不代表获得锁，只是有机会再试
  goto loop
```

退出后：`UnlinkAfterAcquire()` 从 EntryList（O(1) DLL 删除）或 cxq（CAS/线性扫描）移除自己。

---

### Q15: 锁释放（exit）时如何选择唤醒哪个线程？ ⭐⭐⭐

**快答**：默认策略（`Knob_QMode=0`）：先看 `_EntryList`，如果为空则将 `_cxq` drain 到 `_EntryList`，然后唤醒 `_EntryList` 头部线程。

**深入**（`objectMonitor.cpp:905-1229`）：

**退出流程**：

```
① 递归检查: _recursions > 0 → _recursions--，返回
② release_store _owner = NULL（释放锁）
③ storeload fence（保证 store 对其他线程可见）
④ 检查: (_EntryList | _cxq) == 0 → 没人等，直接返回
   检查: _succ != NULL → 已有后继者，直接返回（避免 futile wakeup）
⑤ CAS 重新获取锁（需要锁来操作队列元素）
⑥ 根据 QMode 选择后继者:
```

**五种 QMode**：

| QMode | 策略 | 说明 |
|-------|------|------|
| 0（默认） | EntryList first，cxq drain 到 EntryList（LIFO） | 平衡策略 |
| 1 | 同 0，但 cxq drain 时反转顺序（FIFO） | 更公平 |
| 2 | cxq 直接唤醒头部 | 最快释放，但不公平 |
| 3 | cxq drain 到 EntryList 尾部，唤醒 EntryList 头 | 偏向老等待者 |
| 4 | cxq drain 到 EntryList 头部，唤醒 EntryList 头 | cxq 优先 |

**ExitEpilog**（`objectMonitor.cpp:1282`）：
```cpp
_succ = Wakee;              // futile wakeup 节流：标记后继者
release_store _owner = NULL; // 释放锁
fence();
Wakee->unpark();            // 唤醒
```

**易错点**：`_succ` 是一个"提示"，不保证准确。被唤醒的线程不一定能获取锁（可能被新到达的线程抢走），所以 EnterI 的 park 循环醒来后必须重新 TryLock。

---

### Q16: 什么是自适应自旋？TrySpin 怎么工作的？ ⭐⭐⭐

**快答**：每个 ObjectMonitor 维护 `_SpinDuration` 计数器。自旋成功 `+= Knob_Bonus(100)`，失败 `-= Knob_Penalty(200)`。采用 TATAS（Test-And-Test-And-Set）策略，先读 `_owner` 是否为 NULL，再 CAS。

**深入**（`objectMonitor.cpp:1869-2086`）：

```
PreSpin: 10 次无条件迭代（总是执行）
  → 成功 → 返回

准入控制:
  _SpinDuration <= 0 → 不自旋（被历史失败惩罚到 0）
  _Spinner 过多 → 不自旋
  owner 不在 CPU 上运行（NotRunnable）→ 不自旋

主循环 (TATAS + 指数退避):
  for (ctr = _SpinDuration; ctr > 0; ctr--) {
    if (_owner == NULL) {
      if (CAS(_owner, NULL, Self) == NULL) {
        // 获取成功
        _SpinDuration += Knob_Bonus(100);  // max 5000
        return true;
      }
      // CAS 失败：abort（Knob_CASPenalty = -1）
    }
    // 指数退避：SpinPause * (random & msk)，msk 每轮可能翻倍
    // 每 256 次检查一次 safepoint
  }

  // 自旋失败
  _SpinDuration -= Knob_Penalty(200);  // min 0
  return false;
```

**关键 Knob 常量**：

| 常量 | 值 | 含义 |
|------|-----|------|
| `Knob_SpinLimit` | 5000 | 最大自旋次数 |
| `Knob_PreSpin` | 10 | 无条件预自旋次数 |
| `Knob_Bonus` | 100 | 成功奖励 |
| `Knob_Penalty` | 200 | 失败惩罚 |
| `Knob_CASPenalty` | -1 | CAS 失败直接 abort |
| `Knob_OXPenalty` | -1 | owner 切换直接 abort |

新 monitor 的初始 `_SpinDuration = Knob_Poverty(1000)` × 5 = **5000**，非常乐观。如果连续失败，5000 → 4800 → 4600 → ... → 0，之后完全不自旋。一次成功就 +100，逐步恢复。

---

### Q17: _cxq、_EntryList、_WaitSet 三个队列的区别？ ⭐⭐⭐

**快答**：

| 队列 | 数据结构 | 操作者 | 用途 |
|------|---------|--------|------|
| `_cxq` | 单链表 LIFO | 多线程 CAS push | 新到达的竞争线程 |
| `_EntryList` | 双向链表 | 仅 owner 操作 | 等待获取锁的线程 |
| `_WaitSet` | 循环双向链表 | `_WaitSetLock` 自旋锁保护 | `wait()` 中的线程 |

**深入**：

**为什么分 _cxq 和 _EntryList？**

如果只有一个队列，多线程竞争 push + owner 遍历唤醒会产生严重的竞争。分成两个：
- `_cxq` 只需要 CAS push（O(1)），多线程无阻塞
- `_EntryList` 只有 owner 操作，不需要额外同步，支持 O(1) 删除（DLL）
- owner 在 `exit()` 时将 `_cxq` 批量 drain 到 `_EntryList`

**_WaitSet 为什么用循环双向链表？**

因为 `wait()` 超时或中断时需要 `DequeueSpecificWaiter()` 精确删除特定节点，循环双向链表可以 O(1) 完成。用 `_WaitSetLock`（简单自旋锁）保护，因为 wait/notify 操作总在持有 monitor 后进行，竞争很少。

---

### Q18: wait() 和 notify() 的完整内部流程？ ⭐⭐⭐

**wait() 流程**（`objectMonitor.cpp:1416-1639`）：

```
① CHECK_OWNER → 不是 owner 抛 IllegalMonitorStateException
② 创建 ObjectWaiter(TS_WAIT)
③ SpinAcquire _WaitSetLock → AddWaiter 到 WaitSet（循环 DLL 尾部）
④ 保存 _recursions → _recursions = 0
⑤ exit() — 完全释放锁（包括所有递归层次）
⑥ os::PlatformEvent::park() — 阻塞
⑦ 被唤醒后检查状态:
   - TS_WAIT → 超时/中断，自己 DequeueSpecificWaiter 从 WaitSet 移除
   - TS_ENTER/TS_CXQ → notify 已经把我移到竞争队列了
⑧ enter() 或 ReenterI() 重新获取锁
⑨ 恢复 _recursions
```

**notify() 流程**（`objectMonitor.cpp:1649-1752`）：

`notify()` 调用 `INotify()`，从 WaitSet **头部**取一个 ObjectWaiter，根据 `Knob_MoveNotifyee`（默认 2）的 5 种策略转移：

| Policy | 行为 |
|--------|------|
| 0 | prepend 到 EntryList 头部 |
| 1 | append 到 EntryList 尾部 |
| **2（默认）** | **push 到 _cxq 头部（如果 EntryList 为空则直接放 EntryList）** |
| 3 | append 到 _cxq 尾部 |
| 4 | 直接 unpark（设 TS_RUN） |

`notifyAll()` 就是循环调用 `INotify()`，转移 WaitSet 中所有节点。

**关键理解**：`notify()` **不直接唤醒线程**（policy 4 除外）。它只是把线程从 WaitSet 转移到竞争队列，真正的 unpark 发生在 monitor 持有者调用 `exit()` 的 `ExitEpilog()` 中。

---

### Q19: 什么时候 ObjectMonitor 会被回收（deflate）？ ⭐⭐

**快答**：每个 safepoint 期间，`deflate_idle_monitors()` 检查所有 monitor，不忙的就回收。

**深入**（`synchronizer.cpp:1586-1663`）：

```cpp
bool is_busy() {
  return _count | _waiters | cxq() | _EntryList | _owner;
}
```

只有当 `is_busy()` 返回 0 时（无等待者、无持有者、无竞争者），monitor 才会被回收：
1. 从 monitor 的 `_header` 恢复原始 mark word 到对象头
2. 清除 monitor 的字段
3. 将 monitor 归还到线程局部的空闲列表

**注意**：deflation 只在 safepoint 进行，不能在正常运行时缩减。这意味着一旦一个对象的 monitor 被膨胀创建，即使竞争结束，也要等到下次 safepoint 才有机会回收。

---

### Q20: UseHeavyMonitors 参数是什么？什么场景下用？ ⭐⭐

**快答**：`-XX:+UseHeavyMonitors`（默认 false）跳过轻量级锁，所有 synchronized 直接用 ObjectMonitor。

**使用场景**：
1. **调试**：简化锁行为，更容易用 GDB 观察
2. **高竞争环境**：如果已知几乎所有锁都会膨胀，跳过轻量级锁的 CAS 反而减少了一次无用的 CAS + 膨胀开销
3. **性能分析基准**：对比轻量级锁的实际收益

---

## 四、对象终结与引用处理（Ch4）

### Q21: finalize() 为什么被废弃？有什么替代方案？ ⭐⭐

**快答**：五大问题——不确定执行时间、对象可复活、只执行一次、阻塞 FinalizerThread、延迟回收（至少两轮 GC）。替代方案是 `java.lang.ref.Cleaner`（Java 9+）或 `try-with-resources + AutoCloseable`。

**深入**：

Finalizer 的完整生命周期：

```
classFileParser 检测 has_finalizer → Klass 设置 JVM_ACC_HAS_FINALIZER (0x40000000)
    → Object.<init> 返回时 register_finalizer()
    → Finalizer.register(obj): new Finalizer(obj) 推入 unfinalized 双向链表
    → GC Phase 3: 发现不可达 → 保持 referent 存活 → 入队 pending list
    → ReferenceHandler 线程: pending → Finalizer.queue
    → FinalizerThread (优先级 8): queue.remove() → runFinalizer() → finalize()
    → 下次 GC 才能真正回收
```

**为什么至少两轮 GC**：第一轮 GC 发现不可达时，Phase 3 `process_final_keep_alive` **保持 referent 存活**（这是 FinalRef 特殊之处——GC 不清除 referent），入队等 FinalizerThread 执行。执行完 `clear()` 后，第二轮 GC 才发现真正无引用，才回收。

**替代方案对比**：

| 特性 | finalize() | jdk.internal.ref.Cleaner | java.lang.ref.Cleaner |
|------|-----------|-------------------------|----------------------|
| 可复活 | 可以 | 不可以（PhantomRef） | 不可以 |
| 执行线程 | FinalizerThread（共享） | ReferenceHandler（优先级 10） | 独立 daemon 线程 |
| 异常处理 | 吞掉 | `System.exit(1)` | 吞掉 |
| 引入版本 | JDK 1.0 | JDK 内部 | Java 9+ |
| 推荐场景 | 不推荐 | NIO DirectByteBuffer | 通用 native 资源清理 |

---

### Q22: 四种引用类型的区别和使用场景？ ⭐⭐

**快答**：

| 引用类型 | GC 行为 | get() | 典型场景 |
|---------|--------|-------|---------|
| SoftReference | 内存不足时清除 | 返回 referent | 缓存 |
| WeakReference | 下次 GC 即清除 | 返回 referent（如果还活着） | WeakHashMap、监听器 |
| PhantomReference | 不影响回收 | **永远返回 null** | 跟踪回收时机、释放 native 资源 |
| FinalReference | GC 不清除 referent | JVM 内部使用 | 支撑 finalize() 机制 |

**深入**：

**SoftReference 清除策略**（`referencePolicy.cpp`）：

Server 模式默认 `LRUMaxHeapPolicy`：

```
max_interval = (MaxHeap - 上次GC已用) / MB × SoftRefLRUPolicyMSPerMB
```

标准环境（8GB 堆，2GB 已用）：`max_interval = (8192 - 2048) × 1000 / 1000 = 6144 秒 ≈ 102 分钟`。

超过 102 分钟未被 `get()` 访问的 SoftRef 会被清除。`SoftReference.get()` 每次调用都更新 `timestamp = clock`（clock 由 GC 更新），所以**活跃使用的 SoftRef 不会被清除**。

**PhantomReference 的特殊性**：
- `get()` 永远返回 null → 无法获取 referent → 无法复活
- 在 JDK 9+ 中，referent 在 PhantomRef 入队时就被清除
- 适合做"通知"——知道对象被回收了，然后执行清理动作

---

### Q23: GC 的引用处理有哪几个阶段？ ⭐⭐⭐

**快答**：四个阶段，在 `process_discovered_references()` 中顺序执行。

**深入**（`referenceProcessor.cpp:201-260`）：

| 阶段 | 方法 | 处理 |
|------|------|------|
| Phase 1 | `process_soft_ref_reconsider` | SoftRef 策略重评估，保留策略说应留的 |
| Phase 2 | `process_soft_weak_final_refs` | 统一处理 Soft/Weak/Final：referent null→移除，alive→移除，else→Soft/Weak 清除 referent+入队；Final 不入队 |
| Phase 3 | `process_final_keep_alive` | FinalRef 专属：**保持 referent 存活** + 标记 inactive + 入队 pending list + 遍历传递闭包 |
| Phase 4 | `process_phantom_refs` | PhantomRef：alive→移除，else→清除 referent + 入队 |

**关键区别**：
- **FinalReference 在 Phase 2 不入队**——它有自己的 Phase 3 专门处理
- **Phase 3 保持 referent 存活**——这就是为什么有 finalize() 的对象不会被第一次 GC 回收
- Phase 3 还要 `complete_gc()`（遍历传递闭包），因为 finalize() 可能让整棵对象树复活

**发现阶段**（`discover_reference()`，在 GC 标记期间）：

当 GC 遍历到一个 Reference 对象时，检查其 referent 是否可达。如果不可达，将 Reference 加入对应类型的 discovered list（通过 `discovered` 字段链接，头插法）。

---

### Q24: ReferenceHandler 线程和 FinalizerThread 分别做什么？ ⭐⭐

**快答**：

- **ReferenceHandler**（优先级 10 = MAX_PRIORITY）：从 VM pending list 取引用 → Cleaner 直接 clean() → 其他入队 ReferenceQueue
- **FinalizerThread**（优先级 8 = MAX_PRIORITY - 2）：从 Finalizer 的 queue 中取 → 执行 finalize()

**深入**（`Reference.java:190-319`）：

ReferenceHandler 的核心循环：
```java
void processPendingReferences() {
  waitForReferencePendingList();          // native: 等待 GC 填充 pending list
  ref = getAndClearReferencePendingList(); // native: 获取并清空
  while (ref != null) {
    if (ref instanceof Cleaner) {
      ((Cleaner)ref).clean();             // Cleaner 直接执行，不入队
    } else {
      ref.referenceQueue.enqueue(ref);    // 其他类型入队
    }
    ref = ref.discovered;                 // 沿 discovered 链遍历
  }
}
```

FinalizerThread（`Finalizer.java`）：
```java
public void run() {
  while (true) {
    Finalizer f = (Finalizer) queue.remove();  // 阻塞等待
    f.runFinalizer();
    // runFinalizer(): unlink from unfinalized → invokeFinalize(finalizee) → clear()
  }
}
```

**ReferenceHandler 优先级更高**（10 > 8）的原因：它处理所有引用类型，包括 jdk.internal.ref.Cleaner（NIO DirectByteBuffer 的 native 内存释放），必须尽快执行。FinalizerThread 处理的是已废弃的 finalize()，优先级低一些。

---

### Q25: jdk.internal.ref.Cleaner 和 java.lang.ref.Cleaner 有什么区别？ ⭐⭐⭐

**快答**：

| 特性 | jdk.internal.ref.Cleaner | java.lang.ref.Cleaner |
|------|-------------------------|----------------------|
| 基类 | PhantomReference | — （内部用 PhantomCleanableRef） |
| 执行线程 | **ReferenceHandler**（优先级 10） | **独立 daemon 线程** |
| 异常处理 | `System.exit(1)` | 吞掉 |
| 访问性 | JDK 内部 | 公开 API（Java 9+） |
| 主要用途 | NIO DirectByteBuffer | 通用 native 资源清理 |
| 防 GC 机制 | 静态双向链表 | 静态双向链表 |

**深入**：

**jdk.internal.ref.Cleaner**（`jdk/internal/ref/Cleaner.java:59-155`）：

继承 PhantomReference。所有 Cleaner 实例被加入一个**静态双向链表**（`first` 头节点），防止 Cleaner 本身被 GC。当 ReferenceHandler 线程发现 pending 的 reference 是 Cleaner 类型时，**直接调用 `clean()`**，不走 ReferenceQueue。

`clean()` 方法：先从链表移除（幂等，CAS 保证只执行一次）→ `thunk.run()` → 如果 thunk 抛异常 → `System.exit(1)`。

**NIO DirectByteBuffer 用它释放 native 内存**——当 DirectByteBuffer 被 GC 回收时，Cleaner 的 thunk（`Deallocator`）调用 `Unsafe.freeMemory()` 释放对应的堆外内存。

**java.lang.ref.Cleaner**（`java/lang/ref/Cleaner.java:131-237`）：

Java 9+ 公开 API。每个 Cleaner 实例创建一个**独立的 daemon 线程** + 独立的 ReferenceQueue。`register(Object, Runnable)` 返回一个 `Cleanable`，对象被回收时 Runnable 被执行。

---

## 五、跨章节综合题

### Q26: 从 `new Object()` 到被 GC 回收，一个对象完整的生命周期是什么？ ⭐⭐⭐

**完整生命周期**：

```
1. 字节码 new (0xBB)
   → 解释器检查类/初始化状态
   → TLAB bump-the-pointer 分配内存
   → 清零 + 写 mark word (0x1) + 写 klass pointer
   → 执行 <init> 构造函数
   → 如果有 finalize(): Finalizer.register(obj)

2. 使用期
   → mark word 编码: 无锁(01), 可能有 hashCode(31bit), age(4bit)
   → synchronized: 轻量级锁(00) ⇄ 重量级锁(10)
   → GC 时 age++, 到 MaxTenuringThreshold(15) 晋升 Old

3. 不可达后
   ├─ 无 finalize(): 直接回收
   ├─ 有 SoftReference: 内存充足时保留，不足时清除
   ├─ 有 WeakReference: 下次 GC 清除
   ├─ 有 finalize():
   │    → GC Phase 3 保持存活 + 入队 pending list
   │    → ReferenceHandler → FinalizerThread 执行 finalize()
   │    → 如果 finalize() 中复活 → 继续存活（下次不再执行 finalize）
   │    → 否则 → 下次 GC 回收
   └─ 有 PhantomReference: 回收 + 入队通知

4. 回收
   → G1: 选入 CSet → Evacuation 复制到 Survivor/Old → 原 region 回收
   → mark word 临时变为 forwarding pointer (ptr|11)
   → GC 后恢复 mark word（如果需要保存的话）
```

---

### Q27: 一个对象的 mark word 在整个生命周期中会经历哪些变化？ ⭐⭐⭐

**时间线**：

```
创建: 0x0000000000000001                    (无锁, hash=0, age=0)
  │
首次 hashCode(): 0x00001A2B3C0D0001         (无锁, hash=0x1A2B3C, age=0)
  │
首次 synchronized enter:
  mark → BasicLock 栈地址 (低2位=00)        (轻量级锁)
  BasicLock.displaced_header = 原始 mark
  │
synchronized exit (无竞争):
  CAS 恢复原始 mark                         (回到无锁)
  │
再次 synchronized + 竞争:
  inflate() → mark = ObjectMonitor*|10       (重量级锁)
  ObjectMonitor._header = 原始 mark
  │
monitor 释放 + safepoint deflate:
  恢复原始 mark                             (回到无锁)
  │
GC 移动:
  mark → forwarding_ptr | 11                (GC 标记)
  恢复 mark (age 可能 +1)
  │
再次 GC (age 达到阈值):
  晋升到 Old region
  │
不可达:
  GC 回收，内存归还
```

---

### Q28: 为什么 `-XX:MaxTenuringThreshold` 最大只能设 15？ ⭐

**快答**：因为 age 字段在 mark word 中只有 **4 位**（bit 3-6），最大值 = 2^4 - 1 = **15**。

```cpp
// markOop.hpp
enum { age_bits = 4 };
enum { max_age = (1 << age_bits) - 1 };  // 15
```

这是 mark word 64 位空间紧张下的权衡——4 位 age 足够表达合理的晋升阈值（默认值是 15，G1 默认也是 15）。

---

### Q29: 轻量级锁下调用 hashCode() 会怎样？wait() 呢？ ⭐⭐⭐

**hashCode()**：**强制膨胀为重量级锁**。

原因：轻量级锁时 mark word 整体是指针（指向 BasicLock），没有空间存 hash。虽然 hash 可以写到 displaced header 中，但 CAS 解锁恢复 mark word 时可能与其他线程竞争，导致 hash 丢失。HotSpot 选择直接膨胀到 ObjectMonitor，用 `_header` 字段安全保存 hash。

**wait()**：同样**强制膨胀**。

原因：`wait()/notify()` 需要 `_WaitSet` 队列，这只有 ObjectMonitor 才有。轻量级锁没有这些数据结构。

调用链：`ObjectSynchronizer::wait()` → 检查不是 monitor → `inflate()` → `ObjectMonitor::wait()`。

---

### Q30: TLAB、Eden、Region 三者的关系是什么？ ⭐⭐

**快答**：TLAB ⊂ Eden Region ⊂ G1 Heap。TLAB 是线程私有的 Eden Region 内的一小段内存。

```
┌─────────────────────────── G1 Heap (8GB = 2048 个 4MB Region) ────────────────────┐
│                                                                                     │
│  ┌─ Eden Region (4MB) ──┐  ┌─ Eden Region (4MB) ──┐  ┌─ Survivor ─┐  ┌─ Old ─┐  │
│  │ ┌─ TLAB T1 ─┐        │  │ ┌─ TLAB T3 ─┐        │  │            │  │        │  │
│  │ │ bump ptr   │        │  │ │ bump ptr   │        │  │            │  │        │  │
│  │ └────────────┘        │  │ └────────────┘        │  │            │  │        │  │
│  │ ┌─ TLAB T2 ─┐        │  │                        │  │            │  │        │  │
│  │ │ bump ptr   │        │  │                        │  │            │  │        │  │
│  │ └────────────┘        │  │                        │  │            │  │        │  │
│  └───────────────────────┘  └────────────────────────┘  └────────────┘  └────────┘  │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

- **TLAB**（~几百 KB）：线程私有，bump-the-pointer，无锁
- **Eden Region**（4MB）：多个线程的 TLAB 在同一个 Region 中，TLAB refill 时 CAS 从 Region 分配
- **Region**：G1 的基本管理单位，可以是 Eden/Survivor/Old/Humongous/Free

一个 Eden Region 可以容纳多个线程的 TLAB。TLAB 用完时，从 Region 的 `_top` CAS 分配新段。Region 用完时，新建 Eden Region（受 `-XX:G1NewSizePercent` 和 `-XX:G1MaxNewSizePercent` 限制）。

---

### Q31: 一个有 finalize() 的对象至少需要几次 GC 才能被回收？为什么？ ⭐⭐

**快答**：至少 **两次**。

**详细流程**：

**第一次 GC**：
1. 标记阶段发现对象不可达
2. `discover_reference()` 将 FinalReference 加入 discovered list
3. Phase 2 `process_soft_weak_final_refs`: 发现 referent 不可达，但 FinalRef **不执行** `enqueue_and_clear`
4. **Phase 3** `process_final_keep_alive`: **保持 referent 存活** → 设 `next = this`（标记 inactive）→ 入队 pending list → `complete_gc()` 遍历传递闭包（复活整棵对象树）
5. 结果：对象**未被回收**

**GC 后**：
6. ReferenceHandler 线程从 pending list 取出，enqueue 到 Finalizer.queue
7. FinalizerThread 取出，执行 `runFinalizer()` → `finalize()` → `clear()`

**第二次 GC**：
8. 此时 FinalReference 已经 `clear()` 了 referent，对象无任何引用
9. 正常标记为不可达 → **真正回收**

**如果 finalize() 中建立了强引用**：对象"复活"，可能永远不会被回收——因为 finalize() 只调用一次，下次不可达时直接进入正常回收流程。

---

### Q32: SoftReference 的清除公式怎么算？什么时候 SoftRef 不会被清除？ ⭐⭐

**公式**（`referencePolicy.cpp`，LRUMaxHeapPolicy）：

```
max_interval_ms = (MaxHeapSize - 上次GC时已用) / MB × SoftRefLRUPolicyMSPerMB
```

**标准环境计算**：
- MaxHeapSize = 8192 MB
- 假设上次 GC 时已用 = 2048 MB
- SoftRefLRUPolicyMSPerMB = 1000（默认）
- `max_interval = (8192 - 2048) × 1000 = 6,144,000 ms ≈ 102 分钟`

如果 SoftReference 最后一次被 `get()` 访问到现在超过 102 分钟，就会在 GC Phase 1 被标记为可清除。

**什么时候 SoftRef 不会被清除**：
1. 空闲堆越大，max_interval 越长，越不容易被清除
2. 频繁调用 `get()` 会更新 `timestamp`，保持"活跃"
3. `SoftRefLRUPolicyMSPerMB` 设大 → 阈值更宽松
4. 设 `SoftRefLRUPolicyMSPerMB=0` → max_interval=0 → **立即清除所有不可达 SoftRef**（在 Full GC 前有用，避免 SoftRef 占满堆）

---

### Q33: 为什么 PhantomReference.get() 永远返回 null？ ⭐⭐

**快答**：设计如此——PhantomReference 的存在意义是**通知**而非**访问**。

```java
// PhantomReference.java
public T get() {
    return null;  // 直接返回 null，不读 referent
}
```

**为什么这样设计？**

PhantomReference 被设计为"最弱"的引用，用于跟踪对象被回收的时机。如果 `get()` 能返回 referent，用户就能重新建立强引用（复活对象），这违背了 PhantomReference 的设计目标。

对比 FinalReference——它的 referent 在 finalize() 中可以被访问（甚至复活），这正是 finalize() 被废弃的原因之一。PhantomReference 吸取了教训，从 API 层面杜绝了复活的可能。

---

### Q34: DirectByteBuffer 的堆外内存怎么释放的？ ⭐⭐⭐

**快答**：通过 `jdk.internal.ref.Cleaner`（PhantomReference 的子类），当 DirectByteBuffer 被 GC 回收时，ReferenceHandler 线程调用 Cleaner.clean() → Deallocator.run() → `Unsafe.freeMemory()`。

**详细链路**：

```
1. DirectByteBuffer 构造时:
   Cleaner.create(this, new Deallocator(base, size, cap))
   → Cleaner 加入静态链表防止自身被 GC
   → 同时是 PhantomReference，监控 DirectByteBuffer 对象

2. DirectByteBuffer 变得不可达:
   → GC 标记阶段 discover_reference() 发现 Cleaner
   → Phase 4 处理 PhantomRef → 入队 pending list

3. ReferenceHandler 线程:
   → 发现是 Cleaner 类型 → 直接调用 clean()
   → clean(): 从链表移除 + thunk.run()
   → Deallocator.run(): Unsafe.freeMemory(address)

4. 如果 clean() 的 thunk 抛异常:
   → System.exit(1) 直接终止 JVM
```

**为什么不用 finalize()?** DirectByteBuffer 的内存释放是关键操作，不能依赖不可靠的 finalize()。Cleaner 由 ReferenceHandler（优先级 10）直接执行，比 FinalizerThread（优先级 8）更及时，且不存在复活问题。

---

## 六、JVM 参数速查表

### 对象头相关

| 参数 | 默认 | 说明 |
|------|------|------|
| `-XX:-UseBiasedLocking` | true (JDK11) | 关闭偏向锁 |
| `-XX:hashCode=N` | 5 | hashCode 生成策略 |
| `-XX:+UseCompressedOops` | auto | 压缩对象指针（HeapSize < 32GB 自动开启） |
| `-XX:+UseCompressedClassPointers` | auto | 压缩类指针 |

### 对象分配相关

| 参数 | 默认 | 说明 |
|------|------|------|
| `-XX:+UseTLAB` | true | 启用 TLAB |
| `-XX:TLABSize=N` | 0 | 初始 TLAB 大小（0=自动） |
| `-XX:+ResizeTLAB` | true | GC 后自适应 TLAB |
| `-XX:TLABRefillWasteFraction=N` | 64 | 浪费阈值 |
| `-XX:TLABWasteIncrement=N` | 4 | slow alloc 阈值增量 |
| `-Xlog:gc+tlab=trace` | — | TLAB 统计日志 |
| `-Xlog:gc+alloc=trace` | — | 分配追踪日志 |

### 锁相关

| 参数 | 默认 | 说明 |
|------|------|------|
| `-XX:+UseHeavyMonitors` | false | 跳过轻量级锁 |
| `-Xlog:monitorinflation=debug` | — | 膨胀/缩减日志 |
| `-XX:+PrintConcurrentLocks` | false | jstack 显示并发锁 |

### 引用处理相关

| 参数 | 默认 | 说明 |
|------|------|------|
| `-XX:SoftRefLRUPolicyMSPerMB=N` | 1000 | SoftRef 存活策略 |
| `-XX:+ParallelRefProcEnabled` | false | 并行引用处理 |
| `-Xlog:gc+ref=debug` | — | 引用处理日志 |
| `-Xlog:gc+ref+stats=debug` | — | 引用处理统计 |
| `-XX:+RegisterFinalizersAtInit` | true | Object.<init> 时注册 Finalizer |

### 日志输出示例

```bash
# 查看 TLAB 分配统计
java -Xlog:gc+tlab=trace -Xms8g -Xmx8g -XX:+UseG1GC MyApp

# 输出示例:
# [gc,tlab] GC(0) TLAB: gc thread: 0x00007f8a3c012800 [id: 31]
#   desired_size: 262144  slow allocs: 3  refill waste: 4096
#   alloc: 0.99999  98304KB  refills: 375  waste: 0.1%

# 查看 monitor 膨胀
java -Xlog:monitorinflation=debug -XX:-UseBiasedLocking MyApp

# 输出示例:
# [monitorinflation] inflate(has_locker): object=0x000000071ab2e010
#   mark=0x00007f8a4c0fe710 (stack locked)
# [monitorinflation] deflate_monitor: object=0x000000071ab2e010
#   monitor=0x00007f8a3c0a4100

# 查看引用处理
java -Xlog:gc+ref+stats=debug -Xms8g -Xmx8g -XX:+UseG1GC MyApp

# 输出示例:
# [gc,ref,stats] GC(3) Soft: 128 processed, 12 cleared
# [gc,ref,stats] GC(3) Weak: 256 processed, 64 cleared
# [gc,ref,stats] GC(3) Final: 32 processed, 8 cleared
# [gc,ref,stats] GC(3) Phantom: 16 processed, 4 cleared
```

---

## 七、GDB 快速验证手册

### 7.1 观察对象头

```gdb
# 启动
gdb /data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java
set args -Xms8g -Xmx8g -XX:+UseG1GC -XX:-UseBiasedLocking -Xint \
  -cp /data/workspace/demo/src com.wjcoder.Main

# mark word
break InstanceKlass::allocate_instance
run
# 分配后查看
x/2gx obj                    # [mark_word] [klass_ptr]
p/x obj->mark()              # mark word 值
p obj->mark()->age()         # GC 年龄
p obj->mark()->hash()        # hashCode (0 = 未计算)
```

### 7.2 观察锁状态变化

```gdb
break ObjectSynchronizer::slow_enter
continue
p/x obj->mark()              # 加锁前: 0x...01 (无锁)
next
p/x obj->mark()              # 加锁后: 0x...00 (轻量级锁，指向栈)
p lock->displaced_header()   # 保存的原始 mark

break ObjectSynchronizer::inflate
continue
p/x obj->mark()              # 膨胀后: 0x...10 (重量级)
p obj->mark()->monitor()     # ObjectMonitor 指针
p obj->mark()->monitor()->_header   # 原始 mark
p obj->mark()->monitor()->_owner    # 持有者线程
p obj->mark()->monitor()->_recursions
p obj->mark()->monitor()->_EntryList
p obj->mark()->monitor()->_cxq
```

### 7.3 观察 TLAB 分配

```gdb
break ThreadLocalAllocBuffer::allocate
run
p _start                     # TLAB 起始
p _top                       # 当前分配位置
p _end                       # TLAB 结束
p pointer_delta(_end, _top)  # 剩余空间 (HeapWords)
p _desired_size
p _refill_waste_limit
```

### 7.4 观察引用处理

```gdb
break ReferenceProcessor::discover_reference
run
p/x obj                      # Reference 对象地址
p rt                         # 引用类型 (REF_SOFT/WEAK/FINAL/PHANTOM)

break ReferenceProcessor::process_discovered_references
continue
# 逐步执行四个阶段
```

---

## 八、常见误区总结

| 误区 | 事实 |
|------|------|
| "对象头固定 16 字节" | 压缩 klass 开启时为 12 字节（实例对象），可能有 gap 复用 |
| "hashCode 在对象创建时就有了" | 懒生成，第一次调用 hashCode() 时才计算并写入 mark word |
| "synchronized 有三级锁升级" | 排除偏向锁后只有两级：轻量级 → 重量级 |
| "轻量级锁失败立即变重量级" | 先进入 C++ slow_enter 尝试 CAS，失败后才 inflate |
| "notify() 会立即唤醒线程" | notify 只转移队列位置，真正 unpark 在 exit() 的 ExitEpilog |
| "finalize() 保证执行" | 不保证——FinalizerThread 是 daemon，JVM 退出时不等它 |
| "SoftRef 只在 Full GC 清除" | 每次 GC 都会评估 SoftRef 策略，Young GC 也可能清除 |
| "PhantomRef 和 WeakRef 差不多" | PhantomRef.get() 永远返回 null，不能访问/复活对象 |
| "对象最多活 15 次 GC" | 15 是 MaxTenuringThreshold 上限，但还有动态年龄判定等机制 |
| "TLAB 分配需要 CAS" | TLAB 内部是线程私有的，bump-the-pointer 无需任何同步 |

---

## 附：核心源码文件索引

| 主题 | 关键文件 | 内容 |
|------|---------|------|
| 对象头 | `oops/markOop.hpp` | mark word 位布局、所有常量 |
| 对象头 | `oops/oop.hpp` | oopDesc 定义 |
| 对象分配 | `cpu/x86/templateTable_x86.cpp:3991` | 解释器 new 字节码汇编 |
| 对象分配 | `gc/shared/memAllocator.cpp` | MemAllocator 框架 |
| 对象分配 | `gc/shared/threadLocalAllocBuffer.*` | TLAB 分配/refill/resize |
| 对象分配 | `gc/g1/g1CollectedHeap.cpp` | G1 分配、GC 触发 |
| 对象分配 | `gc/g1/heapRegion.inline.hpp` | Region 内 bump-the-pointer |
| 锁 | `cpu/x86/interp_masm_x86.cpp:1152` | 解释器 lock_object 汇编 |
| 锁 | `runtime/synchronizer.cpp` | slow_enter/fast_exit/inflate/deflate |
| 锁 | `runtime/objectMonitor.cpp` | enter/EnterI/exit/TrySpin/wait/notify |
| 锁 | `runtime/objectMonitor.hpp` | ObjectMonitor 字段布局 |
| 引用 | `java/lang/ref/Reference.java` | 引用状态机、ReferenceHandler |
| 引用 | `java/lang/ref/Finalizer.java` | Finalizer 注册/执行 |
| 引用 | `gc/shared/referenceProcessor.cpp` | GC 引用处理四阶段 |
| 引用 | `gc/shared/referencePolicy.cpp` | SoftRef 清除策略 |
| 引用 | `jdk/internal/ref/Cleaner.java` | NIO 堆外内存释放 |

---

*系列完结：Ch1 对象头 → Ch2 对象分配 → Ch3 锁优化 → Ch4 对象终结 → Ch5 面试专题*
