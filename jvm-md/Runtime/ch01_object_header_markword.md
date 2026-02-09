# Chapter 1: 对象头与 markWord 深度解析

> **系列**：Runtime System — 对象生命周期  
> **环境**：OpenJDK 11, `-Xms8g -Xmx8g -XX:+UseG1GC -XX:-UseBiasedLocking`, LP64  
> **约定**：本文全部分析**排除偏向锁**（JDK 15 废弃, JDK 18 默认关闭, JDK 25 移除）

---

## 1. 问题引入：为什么需要对象头？

每个 Java 对象在堆上至少需要回答三个问题：
1. **我是谁** — 这个对象属于哪个类？（类型信息）
2. **我的状态** — 是否被加锁？GC 年龄多少？hashCode 是多少？（运行时状态）
3. **谁在持有我** — 如果被锁定，锁的持有者是谁？（同步信息）

HotSpot 的解法是在每个对象的起始位置放一个**对象头 (Object Header)**，用极少的字节（通常 12~16 字节）编码上述所有信息。

---

## 2. oopDesc：Java 对象在 C++ 中的表示

> 源码：`src/hotspot/share/oops/oop.hpp`

`oopDesc` 是 HotSpot 中所有 Java 对象的 C++ 基类。它只有两个字段：

```cpp
class oopDesc {
  volatile markOop _mark;      // 8 字节 — mark word
  union _metadata {
    Klass*      _klass;             // 8 字节（未压缩）
    narrowKlass _compressed_klass;  // 4 字节（压缩 klass 指针）
  } _metadata;
};
```

**关键偏移量**（通过 `oop.hpp` 中的静态方法获取）：

| 偏移量方法 | 值 | 含义 |
|-----------|-----|------|
| `mark_offset_in_bytes()` | 0 | mark word 在对象中的偏移 |
| `klass_offset_in_bytes()` | 8 | klass 指针的偏移 |
| `klass_gap_offset_in_bytes()` | 12 | 压缩 klass 后留下的 4 字节间隙 |

### 2.1 mark word 的读写

`oop.inline.hpp` 中定义了 mark word 的访问方式：

```cpp
// 通过 HeapAccess 屏障读取（GC 安全）
markOop oopDesc::mark() const {
  return HeapAccess<MO_VOLATILE>::load_at(as_oop(), mark_offset_in_bytes());
}

// 直接原始读取（性能敏感路径）
markOop oopDesc::mark_raw() const {
  return _mark;
}

// CAS 原子更新（锁操作的核心）
markOop oopDesc::cas_set_mark(markOop new_mark, markOop old_mark) {
  return HeapAccess<>::atomic_cmpxchg_at(new_mark, as_oop(), mark_offset_in_bytes(), old_mark);
}
```

为什么需要两套 API（`mark()` vs `mark_raw()`）？
- `mark()` 走 GC 屏障，用于可能触发 GC 的路径
- `mark_raw()` 直接读字段，用于 GC 内部或性能极敏感的路径（如 scavenge、forwarding）

---

## 3. markWord 64-bit 布局

> 源码：`src/hotspot/share/oops/markOop.hpp`

在 64 位 JVM（`-XX:-UseBiasedLocking`）下，mark word 的 64 bit 布局如下：

```
  63                  38 37         8  7   6   3  2    1   0
 +----------------------+-----------+---+-----+---+--------+
 |    unused (25 bits)  | hash (31) |cms| age |  0|  lock  |
 +----------------------+-----------+---+-----+---+--------+
                                     1b   4b   1b    2b
```

各字段的具体定义（来自 `markOop.hpp` 的枚举）：

| 字段 | 位数 | shift | mask | 说明 |
|------|------|-------|------|------|
| lock | 2 | 0 | `0x3` | 锁状态标志位 |
| biased_lock | 1 | 2 | — | **废弃**，在 `-XX:-UseBiasedLocking` 下恒为 0 |
| age | 4 | 3 | `0xF` | GC 分代年龄，最大值 15 |
| cms | 1 | 7 | `0x1` | LP64 专属，CMS free chunk 标记 |
| hash | 31 | 8 | `0x7FFFFFFF` | identity hash code |
| unused | 25 | 39 | — | 未使用 |

### 3.1 锁状态编码

lock 字段（低 2 bit）+ biased_lock（bit 2）共同决定对象当前的同步状态：

```
 [ptr             | 00]  轻量级锁定   — ptr 指向栈上的 BasicLock
 [header      | 0 | 01]  无锁         — 正常对象头（含 hash, age）
 [ptr             | 10]  重量级锁定   — ptr 指向堆中的 ObjectMonitor（低 2 bit OR'd）
 [ptr             | 11]  GC 标记      — 仅 GC 期间使用（forwarding pointer）
```

**注意**：
- `00`（轻量级锁定）时，整个 mark word 是一个指针——指向栈帧中 `BasicLock` 的地址，因为栈地址 8 字节对齐，低 2 bit 天然为 0
- `10`（重量级）时，mark word 存的是 `ObjectMonitor* | 0x2`，解码时用 `value() ^ monitor_value` 去掉标记位
- `11`（GC marked）时，mark word 存的是 forwarding pointer（目标对象地址 | 0x3）

**源码中的关键判断方法**：

```cpp
bool is_locked()   const { return (value() & 0x3) != 1; }  // 不是无锁就是被锁
bool is_unlocked() const { return (value() & 0x7) == 1; }  // 低 3 bit 为 001
bool is_neutral()  const { return (value() & 0x7) == 1; }  // 同 is_unlocked
bool has_locker()  const { return (value() & 0x3) == 0; }  // 轻量级锁：低 2 bit 为 00
bool has_monitor() const { return (value() & 0x2) != 0; }  // 重量级：bit 1 为 1
bool is_marked()   const { return (value() & 0x3) == 3; }  // GC 标记
```

### 3.2 prototype() — 新对象的初始 mark word

```cpp
static markOop prototype() {
  return markOop( no_hash_in_place | no_lock_in_place );
  // no_hash_in_place = 0 << 8 = 0
  // no_lock_in_place = unlocked_value = 1
  // 结果 = 0x0000000000000001
}
```

所以，**每个新创建的 Java 对象的 mark word 初始值为 `0x1`**（无锁，无 hash，age=0）。

### 3.3 INFLATING() — 膨胀过程的瞬态标记

```cpp
static markOop INFLATING() { return (markOop) 0; }
```

当一个线程正在将轻量级锁**膨胀**为重量级 ObjectMonitor 时，它会先将对象的 mark word CAS 为 `0`（表示"正在膨胀中"）。这是一个极短暂的瞬态值。其他线程看到 `0` 时，必须自旋等待膨胀完成。

---

## 4. 实例对象的内存布局

> 源码：`src/hotspot/share/oops/instanceOop.hpp`

### 4.1 标准情况（压缩 klass 指针开启，这是默认）

```
偏移  内容              大小
 0    mark word          8 字节
 8    compressed klass   4 字节 (narrowKlass)
12    [klass gap]        4 字节 — 可放第一个字段！
16    instance fields...
```

`instanceOopDesc::base_offset_in_bytes()` 的逻辑：

```cpp
static int base_offset_in_bytes() {
  return UseCompressedOops && UseCompressedClassPointers
    ? klass_gap_offset_in_bytes()   // = 12，复用 klass gap
    : sizeof(instanceOopDesc);      // = 16
}
```

**关键设计**：当同时开启压缩 oop 和压缩 klass 指针时，字段从偏移 12 开始，而不是 16——这 4 字节的 klass gap 被复用来存储第一个实例字段，从而节省内存。

### 4.2 未压缩 klass 指针

```
偏移  内容              大小
 0    mark word          8 字节
 8    Klass*             8 字节 (完整指针)
16    instance fields...
```

---

## 5. 数组对象的内存布局

> 源码：`src/hotspot/share/oops/arrayOop.hpp`

数组对象 `arrayOopDesc` 继承自 `oopDesc`，但有一个**特殊的 length 字段**——它没有在 C++ 中声明！而是隐式地放在 klass 指针之后。

### 5.1 压缩模式（默认）

```
偏移  内容              大小
 0    mark word          8 字节
 8    compressed klass   4 字节
12    length (int)       4 字节  ← 放在 klass gap 位置
16    array elements...
```

### 5.2 未压缩模式

```
偏移  内容              大小
 0    mark word          8 字节
 8    Klass*             8 字节
16    length (int)       4 字节
20    [padding]          4 字节  ← 对齐到 8 字节
24    array elements...
```

**length 偏移量**的计算：

```cpp
static int length_offset_in_bytes() {
  return UseCompressedClassPointers
    ? klass_gap_offset_in_bytes()    // = 12
    : sizeof(arrayOopDesc);          // = 16
}
```

**数组头大小**（包含 mark + klass + length，按 HeapWordSize 对齐）：

```cpp
static int header_size_in_bytes() {
  size_t hs = align_up(length_offset_in_bytes() + sizeof(int), HeapWordSize);
  // 压缩: align_up(12+4, 8) = 16
  // 非压缩: align_up(16+4, 8) = 24
  return (int)hs;
}
```

对于 `long[]` 和 `double[]`，还需要额外对齐到 8 字节（`BytesPerLong`），这由 `header_size()` 方法处理。

---

## 6. 轻量级锁机制：BasicLock 与 displaced header

> 源码：`src/hotspot/share/runtime/basicLock.hpp`, `synchronizer.cpp`

### 6.1 BasicLock 结构

```cpp
class BasicLock {
  volatile markOop _displaced_header;  // 8 字节 — 保存原始 mark word
};
```

`BasicLock` 仅有一个字段：`_displaced_header`（位移头），用于在轻量级锁定期间保存对象原始的 mark word。

### 6.2 BasicObjectLock — 解释器栈帧中的锁记录

```cpp
class BasicObjectLock {
  BasicLock _lock;  // 8 字节 — displaced header
  oop       _obj;   // 8 字节 — 被锁对象的引用
};
// sizeof(BasicObjectLock) = 16 字节
```

每当解释器执行 `monitorenter` 指令时，会在当前栈帧中分配一个 `BasicObjectLock`。

### 6.3 轻量级锁加锁流程 — slow_enter()

```
ObjectSynchronizer::slow_enter(Handle obj, BasicLock* lock, TRAPS)
```

**流程**：

```
1. 读取对象的 mark word
2. if (mark is neutral / unlocked, 低3bit = 001):
     a. lock->set_displaced_header(mark)   // 保存原始 mark 到栈上
     b. CAS(obj->mark, mark, (markOop)lock)  // 把对象 mark 替换为指向 BasicLock 的指针
     c. if CAS 成功 → 加锁完成，return
     d. if CAS 失败 → fall through 到膨胀
3. else if (mark has_locker 且 locker 是当前线程):
     // 重入！同一线程对同一对象再次加锁
     lock->set_displaced_header(NULL)  // 标记为重入（displaced header = NULL）
     return
4. else:
     // 竞争或已膨胀
     lock->set_displaced_header(unused_mark())  // 设为哨兵值 0x3
     inflate(obj)->enter(THREAD)  // 膨胀为重量级锁并进入
```

**关键理解**：
- `displaced_header == NULL` 表示**重入锁记录**，不是真正的锁持有者
- `displaced_header == unused_mark() (0x3)` 表示这个 BasicLock 从未真正持有过轻量级锁（已直接进入重量级路径）
- 只有 `displaced_header` 是一个合法的 mark word（`is_neutral()` 为 true）时，这个 BasicLock 才是真正的轻量级锁持有者

### 6.4 轻量级锁解锁流程 — fast_exit()

```
ObjectSynchronizer::fast_exit(oop object, BasicLock* lock, TRAPS)
```

**流程**：

```
1. dhw = lock->displaced_header()
2. if (dhw == NULL):
     // 重入退出，不需要做任何事
     return
3. if (object->mark == (markOop)lock):
     // 对象 mark 仍然指向这个 BasicLock → 无竞争
     CAS(object->mark, lock, dhw)  // 把原始 mark word 恢复回去
     if CAS 成功 → return
4. // CAS 失败说明有竞争，已被其他线程膨胀
   inflate(object)->exit(THREAD)
```

---

## 7. 重量级锁：ObjectMonitor

> 源码：`src/hotspot/share/runtime/objectMonitor.hpp`

当轻量级锁竞争激烈或调用 `Object.wait()` 时，锁会**膨胀**为 `ObjectMonitor`。

### 7.1 ObjectMonitor 关键字段

```cpp
class ObjectMonitor {
  volatile markOop   _header;       // 位移头：保存原始 mark word（必须在偏移 0）
  void*     volatile _object;       // 反向指针：指向被锁的 Java 对象
  ObjectMonitor*     FreeNext;      // 空闲链表指针
  // --- cache line padding ---
  void*  volatile _owner;           // 当前持有者：Thread* 或 BasicLock*
  volatile jlong _previous_owner_tid;
  volatile intptr_t  _recursions;   // 重入次数（首次加锁 = 0）
  ObjectWaiter* volatile _EntryList; // 阻塞队列：等待获取锁的线程
  ObjectWaiter* volatile _cxq;      // 竞争队列：最近到达的竞争线程
  Thread* volatile _succ;           // 继承者线程（减少无谓唤醒）
  Thread* volatile _Responsible;    // 责任线程
  volatile int _Spinner;            // 自旋优化
  volatile int _SpinDuration;       // 自旋持续时间
  volatile jint _count;             // 引用计数（防止在 STW 时被回收）
  ObjectWaiter* volatile _WaitSet;  // 等待集：调用 wait() 的线程
  volatile jint _waiters;           // 等待中的线程数
  volatile int _WaitSetLock;        // 保护 WaitSet 的自旋锁
};
```

**关键设计**：
1. `_header` **必须在偏移 0**——因为 `displaced_mark_helper()` 直接把 mark word 中的指针当作 `markOop*` 解引用，读取的就是 `_header` 字段
2. `_header` 和 `_owner` 之间有 **cache line padding**——避免不同线程读写这两个热点字段时的 false sharing
3. `_owner` 可以是 `Thread*` 也可以是 `BasicLock*`——在从栈锁膨胀时，owner 初始指向原来的 BasicLock

### 7.2 ObjectWaiter — 等待队列节点

```cpp
class ObjectWaiter : public StackObj {
  enum TStates { TS_UNDEF, TS_READY, TS_RUN, TS_WAIT, TS_ENTER, TS_CXQ };
  ObjectWaiter* volatile _next;
  ObjectWaiter* volatile _prev;
  Thread*       _thread;       // 关联的线程
  ParkEvent*    _event;        // 用于 park/unpark
  volatile int  _notified;
  volatile TStates TState;
};
```

### 7.3 mark word 与 ObjectMonitor 的编码关系

```cpp
// 编码：ObjectMonitor* → mark word
static markOop encode(ObjectMonitor* monitor) {
  return (markOop) ((intptr_t)monitor | monitor_value);  // | 0x2
}

// 解码：mark word → ObjectMonitor*
ObjectMonitor* monitor() const {
  return (ObjectMonitor*) (value() ^ monitor_value);     // ^ 0x2
}
```

用 XOR 而不是 AND 的原因：XOR 额外提供了一次校验——如果 bit 1 本来就不是 1，XOR 会产生错误结果，从而被 assert 捕获。

---

## 8. 膨胀流程：inflate()

> 源码：`src/hotspot/share/runtime/synchronizer.cpp:1387`

`inflate()` 是一个自旋循环（`for(;;)`），根据当前 mark word 状态分四种情况处理：

### 8.1 已膨胀 — 直接返回

```
if mark->has_monitor():
  return mark->monitor()
```

### 8.2 正在膨胀（mark == 0）— 自旋等待

```
if mark == INFLATING():
  ReadStableMark(object)  // 自旋 + yield
  continue
```

### 8.3 栈锁定（mark has_locker）— 膨胀栈锁

这是最复杂的路径：

```
1. m = omAlloc(Self)                     // 预分配一个 ObjectMonitor
2. m->Recycle()                          // 初始化字段
3. CAS(object->mark, mark, INFLATING()) // 把 mark 从栈锁指针换成 0
   if CAS 失败 → omRelease(m) + continue
4. 现在 mark word 是 0，只有当前线程能继续：
   dmw = mark->displaced_mark_helper()  // 从 BasicLock 读取原始 mark
   m->set_header(dmw)                   // 保存到 monitor 的 _header
   m->set_owner(mark->locker())         // owner 设为原来的 BasicLock 地址
   m->set_object(object)
5. object->release_set_mark(encode(m))  // mark 设为 monitor 指针 | 0x2
```

**为什么不直接 CAS(mark, stack-lock-ptr, encode(m))？**

如果这样做，另一个线程可能在 CAS 成功到设置 `m->_header` 之间尝试解锁——它会 CAS(mark, stack-lock-ptr, original-header)，但 mark 已经不是 stack-lock-ptr 了，解锁失败。然后它进入慢路径看到 monitor 但 `_header` 还没设置好。用 `0` 作为中间状态可以让解锁方知道"膨胀正在进行"，必须等待。

### 8.4 无锁 / neutral — 直接膨胀

```
1. m = omAlloc(Self)
2. m->set_header(mark)          // 原始 mark 直接存到 monitor
3. m->set_owner(NULL)           // 无人持有
4. m->set_object(object)
5. CAS(object->mark, mark, encode(m))
   if CAS 失败 → Recycle(m) + omRelease(m) + continue
```

**日志参数**：要看到膨胀日志，添加 `-Xlog:monitorinflation=debug`：

```
[debug][monitorinflation] Inflating object 0x000000071ab00010 , mark 0x000000071ab00012 , type com.example.MyLock
```

---

## 9. HashCode 生成与存储

> 源码：`src/hotspot/share/runtime/synchronizer.cpp:669`

### 9.1 六种 hashCode 策略

通过 `-XX:hashCode=N` 控制（N 默认 = 5）：

| N | 策略 | 说明 | 特点 |
|---|------|------|------|
| 0 | Park-Miller RNG | `os::random()` 全局随机数 | 多线程竞争全局状态，cache-thrashing |
| 1 | 地址 + STW random | `(addr >> 3) ^ (addr >> 8) ^ GVars.stwRandom` | STW 间稳定 |
| 2 | 常量 1 | 返回固定值 1 | 仅用于敏感性测试 |
| 3 | 自增序列 | `++GVars.hcSequence` | 全局计数器 |
| 4 | 原始地址 | `cast_from_oop<intptr_t>(obj)` | 最简单，GC 后会变 |
| **5** | **Marsaglia xor-shift** | **线程私有状态的 xor-shift RNG** | **默认，性能最优** |

**默认策略（hashCode=5）的实现**：

```cpp
unsigned t = Self->_hashStateX;
t ^= (t << 11);
Self->_hashStateX = Self->_hashStateY;
Self->_hashStateY = Self->_hashStateZ;
Self->_hashStateZ = Self->_hashStateW;
unsigned v = Self->_hashStateW;
v = (v ^ (v >> 19)) ^ (t ^ (t >> 8));
Self->_hashStateW = v;
value = v;
```

这是 Marsaglia 的 128-bit xor-shift 算法，使用线程局部的 4 个 32-bit 状态变量（`_hashStateX/Y/Z/W`），**完全无锁、无全局竞争**。

生成后，`value &= hash_mask`（取低 31 bit），如果结果为 0 则替换为 `0xBAD`（确保 hash 非零）。

### 9.2 FastHashCode() — hashCode 的三路查找

`FastHashCode()` 是获取对象 identity hash code 的核心函数，它需要处理三种锁状态：

**路径 1：无锁状态（mark is neutral）**

```
hash = mark->hash()
if hash != 0 → return hash       // 已有 hash，直接返回
hash = get_next_hash()            // 生成新 hash
temp = mark->copy_set_hash(hash)  // 合并到 mark word 中
CAS(obj->mark, mark, temp)        // 原子安装
if CAS 成功 → return hash
// CAS 失败 → fall through 到膨胀
```

**路径 2：重量级锁状态（mark has_monitor）**

```
monitor = mark->monitor()
temp = monitor->header()          // 从 monitor 的 displaced header 读
hash = temp->hash()
if hash != 0 → return hash
// 无 hash → fall through 到膨胀安装
```

**路径 3：轻量级锁状态（mark has_locker，且是当前线程持有）**

```
temp = mark->displaced_mark_helper()  // 从栈上的 BasicLock 读
hash = temp->hash()
if hash != 0 → return hash
// 无 hash → fall through 到膨胀
```

**三路都无法直接安装时 — 膨胀后安装**

```
monitor = inflate(obj, inflate_cause_hash_code)
mark = monitor->header()
hash = mark->hash()
if hash == 0:
  hash = get_next_hash()
  temp = mark->copy_set_hash(hash)
  CAS(monitor->_header, mark, temp)  // 安装到 monitor 的 displaced header
return hash
```

**关键结论**：如果对象处于轻量级锁定状态且尚未计算过 hashCode，调用 `hashCode()` 会**强制将轻量级锁膨胀为重量级 ObjectMonitor**。这是因为 BasicLock 中的 displaced header 不能被安全修改（其他线程在 inflate 时可能异步读取它）。

### 9.3 identity_hash() — 快速路径

`oop.inline.hpp` 中还有一个快速路径：

```cpp
intptr_t oopDesc::identity_hash() {
  markOop mrk = mark();
  if (mrk->is_unlocked() && !mrk->has_no_hash()) {
    return mrk->hash();   // 最快路径：无锁且有 hash，直接位操作提取
  } else if (mrk->is_marked()) {
    return mrk->hash();   // GC 标记状态也能读 hash
  } else {
    return slow_identity_hash();  // 走 FastHashCode
  }
}
```

---

## 10. 三态锁转换全景

排除偏向锁后，锁的状态转换为简洁的三态模型：

```
                    首次 synchronized
   ┌──────────┐  ──────────────────>  ┌──────────────────┐
   │  无锁    │                       │   轻量级锁       │
   │ [01]     │  <──────────────────  │   [00]           │
   └──────────┘    CAS 恢复 mark      │ mark→BasicLock   │
        │                             └──────────────────┘
        │                                     │
        │                             竞争或 hashCode()
        │                                     │
        │                                     ▼
        │                             ┌──────────────────┐
        │      inflate (neutral)      │   重量级锁       │
        └──────────────────────────>  │   [10]           │
                                      │ mark→Monitor|10  │
                                      └──────────────────┘
```

**膨胀触发条件**：
1. 轻量级锁 CAS 失败（真正的竞争）
2. 轻量级锁状态下调用 `hashCode()`
3. 调用 `Object.wait()`
4. JNI `MonitorEnter`
5. 直接从无锁膨胀（`inflate_cause_vm_internal` 等场景）

**注意**：在 OpenJDK 11 中，锁膨胀是**单向**的——一旦膨胀为 ObjectMonitor，在该 monitor 被回收前不会降级回轻量级锁。Monitor 的回收（deflation）发生在 safepoint 期间（`deflate_idle_monitors()`），只回收**空闲**的 monitor（`is_busy()` 返回 0）。

---

## 11. GC 与 mark word 的保存/恢复

> 源码：`src/hotspot/share/oops/markOop.inline.hpp`

GC 在移动对象时需要用 mark word 存放 forwarding pointer（低 2 bit = 11）。如果原始 mark word 包含有用信息（锁状态、hash code），则必须先保存再恢复。

```cpp
// 判断 mark 是否需要保存
inline bool markOopDesc::must_be_preserved(oop obj) const {
  if (is_marked()) return false;   // 已经是 GC 标记，不需要
  if (must_be_preserved_with_bias(obj)) return true;
  // 非偏向锁路径：
  if (is_locked()) return true;    // 被锁定 → 必须保存
  if (has_no_hash()) return false; // 无 hash 且无锁 → 不需要
  return true;                     // 有 hash → 必须保存
}
```

GC 保存 mark word 的场景：对象被锁定（mark 指向 BasicLock），或者 mark 中存有非零 hash code。对于无锁且无 hash 的对象，GC 后直接用 `prototype_for_object()` 重新初始化即可。

`age` 的管理也在 mark word 中：

```cpp
// 读取 age（需考虑锁定状态）
uint oopDesc::age() const {
  if (has_displaced_mark_raw()) {
    return displaced_mark_raw()->age();   // 锁定时从 displaced header 读
  } else {
    return mark_raw()->age();             // 正常从 mark 读
  }
}

// 增加 age
void oopDesc::incr_age() {
  if (has_displaced_mark_raw()) {
    set_displaced_mark_raw(displaced_mark_raw()->incr_age());
  } else {
    set_mark_raw(mark_raw()->incr_age());
  }
}
```

**重要**：age 最大值为 15（4 bit），对应 `-XX:MaxTenuringThreshold` 的上限。

---

## 12. 对象大小的计算

> 源码：`src/hotspot/share/oops/oop.inline.hpp:208`

`oopDesc::size_given_klass()` 是 GC 最频繁调用的函数之一，它利用 `Klass::layout_helper()` 快速计算对象大小：

- **实例对象**：`layout_helper > 0`，直接是 `size_in_words`（HeapWord 单位），编译时已确定
- **数组对象**：`layout_helper < 0`，需要运行时计算：
  ```
  size_in_bytes = array_length << log2_element_size + header_size
  size_in_words = align_up(size_in_bytes, MinObjAlignmentInBytes) / HeapWordSize
  ```
- **其他（layout_helper == 0）**：走虚函数 `klass->oop_size(this)`

---

## 13. GDB 验证指南

以下 GDB 命令可验证本文所述的对象头布局：

### 13.1 创建测试对象并观察 mark word

```bash
# 启动 GDB
gdb /data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java

# 设置参数（禁用偏向锁）
set args -Xms8g -Xmx8g -XX:+UseG1GC -XX:-UseBiasedLocking -Xint \
  -cp /data/workspace/demo/src com.wjcoder.Main

# 在对象分配后断点
break InstanceKlass::allocate_instance
run
```

### 13.2 查看 mark word 值

```gdb
# 假设 obj 是一个 oop
# 查看 mark word（偏移 0）
x/1gx obj

# 解析 mark word
# 无锁状态应该看到类似：0x0000000000000001 (hash=0, age=0, lock=01)
# 或 hashCode 已计算: 0x0000001234560001 (hash=0x2468AC, age=0, lock=01)

# 查看 compressed klass（偏移 8，4字节）
x/1wx ((char*)obj + 8)

# 查看整个对象头（16字节）
x/2gx obj
```

### 13.3 观察锁状态变化

```gdb
# 在 slow_enter 断点
break ObjectSynchronizer::slow_enter
continue

# 加锁前查看 mark
p/x obj->mark()

# 加锁后查看 mark — 应该看到低 2 bit 为 00，指向栈上 BasicLock
p/x obj->mark()
p lock->displaced_header()

# 在 inflate 断点
break ObjectSynchronizer::inflate
continue

# 膨胀后查看 mark — 应该看到低 2 bit 为 10
p/x obj->mark()
p/x obj->mark()->monitor()
p obj->mark()->monitor()->_header
p obj->mark()->monitor()->_owner
p obj->mark()->monitor()->_recursions
```

### 13.4 验证 hashCode 存储位置

```gdb
# 在 FastHashCode 断点
break ObjectSynchronizer::FastHashCode
continue

# 查看生成的 hash
finish
p/x $rax   # 返回值（x86_64）

# 验证 hash 嵌入 mark word
x/1gx obj
# 应该看到 bit[8:38] 包含非零的 hash 值
```

---

## 14. 总结

| 概念 | 要点 |
|------|------|
| mark word | 64-bit，编码 hash(31) + age(4) + lock(2)，三种锁状态 |
| oopDesc | `_mark`(8B) + `_metadata`(4/8B)，所有 Java 对象的 C++ 基类 |
| 实例对象头 | 压缩模式 12B（复用 klass gap），非压缩 16B |
| 数组对象头 | 压缩模式 16B（length 在偏移 12），非压缩 24B |
| 轻量级锁 | BasicLock displaced header + CAS mark word，栈上操作 |
| 重量级锁 | ObjectMonitor，_header 保存原始 mark，cache line padding 优化 |
| 膨胀 | 单向（轻量→重量），CAS 0 作为 BUSY 标记，三种入口状态 |
| hashCode | 默认 Marsaglia xor-shift (线程局部)，31-bit，0 替换为 0xBAD |
| hashCode + lock 交互 | 轻量级锁下首次 hashCode → 强制膨胀 |

---

## 附：核心源码文件索引

| 文件 | 内容 |
|------|------|
| `oops/markOop.hpp` | mark word 位布局定义、所有常量和方法 |
| `oops/markOop.inline.hpp` | GC 保存 mark word 的判断逻辑 |
| `oops/oop.hpp` | `oopDesc` 类定义 |
| `oops/oop.inline.hpp` | mark 读写、klass 访问、对象大小计算、identity_hash |
| `oops/instanceOop.hpp` | 实例对象 `base_offset_in_bytes()` |
| `oops/arrayOop.hpp` | 数组对象 length 字段位置、header size |
| `runtime/basicLock.hpp` | `BasicLock`、`BasicObjectLock` 定义 |
| `runtime/objectMonitor.hpp` | `ObjectMonitor` 完整字段、`ObjectWaiter` |
| `runtime/synchronizer.hpp` | `ObjectSynchronizer` API 声明 |
| `runtime/synchronizer.cpp` | `slow_enter`、`fast_exit`、`inflate`、`FastHashCode`、`get_next_hash` |
