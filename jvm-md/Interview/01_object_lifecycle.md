# 主题一：对象生命周期 — 从 new 到回收

> 对应文档: `Runtime/ch01~ch05`, `Interpreter/5.1`, `Universe/3.3-TLAB`, `C2Compiler/escape_analysis`
> 面试覆盖: 对象头 / 内存布局 / 分配流程 / TLAB / 逃逸分析 / 引用类型 / 终结器

---

## Q1: Java 对象的内存布局是什么样的？⭐

### 一句话结论
Java 对象 = **markWord(8字节)** + **Klass 指针(4字节,压缩后)** + **实例数据** + **对齐填充**

### 普通回答
对象头包含 Mark Word 和类型指针，实例数据按照字段宽度排列，末尾对齐到 8 字节。

### 源码级回答

```
┌───────────────────────────── oopDesc ─────────────────────────────┐
│ markWord _mark (8 bytes)  │  Klass* _klass (4 bytes, compressed) │
├───────────────────────────────────────────────────────────────────┤
│                     实例字段数据 (instanceOop)                      │
│            按 long/double → int/float → short/char →              │
│            byte/boolean → oop 排列 (FieldsAllocationStyle=1)      │
├───────────────────────────────────────────────────────────────────┤
│                  对齐填充 (到 8 字节边界)                           │
└───────────────────────────────────────────────────────────────────┘
```

**markWord 64-bit 布局 (无锁态):**
```
|------- unused:25 -------|-- hashcode:31 --|-- unused:1 --|-- age:4 --|-- biased:1 --|-- lock:2 --|
```

- `lock = 01` 无锁/偏向锁，`00` 轻量级锁，`10` 重量级锁，`11` GC 标记
- `age` = 分代年龄，最大 15（4 bit），对应 `-XX:MaxTenuringThreshold`
- `hashcode` = 调用 `hashCode()` 后惰性写入（31 bit），写入后**不可再偏向锁**

**源码关键:**
```cpp
// src/hotspot/share/oops/markOop.hpp
// 64 bits: unused:25 hash:31 unused:1 age:4 biased_lock:1 lock:2
```

**Klass 指针压缩 (UseCompressedOops):**
```
实际地址 = narrowKlass << 3 + CompressedClassSpaceBase
```
- 4 字节存储，解码为 8 字节真实地址
- `-XX:+UseCompressedOops` 默认开启（堆 < 32GB）

**数组对象额外有:**
- `_length` (4 bytes) 紧跟在 Klass 指针后

> 📖 详细文档: `Runtime/ch01_object_header_markword.md`

---

## Q2: new 一个对象，JVM 底层经历了什么？⭐⭐

### 一句话结论
`new` → **解释器快速路径(TLAB CAS)** → 失败走 **慢速路径(MemAllocator → G1 Region 分配)** → **初始化(清零+mark+klass)**

### 源码级回答

**第一层: 解释器模板 (x86 汇编快速路径)**
```
1. 从常量池取 InstanceKlass*
2. 检查 klass 已初始化（_init_state == fully_initialized）
3. 计算对象大小（从 Klass._layout_helper 直接取）
4. TLAB 分配: top + size <= end ? → CAS bump top → 成功!
5. 清零内存 (rep stosq)
6. 写 markWord = prototype_header（无锁 001）
7. 写 Klass 指针
```

**第二层: 慢速路径 (C++ Runtime)**
```
InterpreterRuntime::_new()
  → InstanceKlass::allocate_instance()
    → MemAllocator::allocate()
      → mem_allocate_inside_tlab_slow()    // TLAB refill
        → Universe::heap()->allocate_new_tlab()
          → G1CollectedHeap::attempt_allocation()
            → HeapRegion CAS 分配
      → mem_allocate_outside_tlab()        // 如果 TLAB 放不下
        → attempt_allocation()             // 直接 Eden 分配
```

**关键数值 (GDB 验证):**
- TLAB 默认大小 ≈ Eden/线程数/2 ≈ 几百 KB
- 对象头 = 12 bytes（8 mark + 4 compressed klass）
- 最小对象 = 16 bytes（对齐到 8 字节）

> 📖 详细文档: `Runtime/ch02_object_allocation.md`, `Interpreter/5.1-allocation-bytecodes-deep-dive.md`

---

## Q3: 什么是 TLAB？为什么需要它？⭐⭐

### 一句话结论
TLAB (Thread-Local Allocation Buffer) 是**每个线程私有的 Eden 区小缓冲**，让对象分配无锁化，避免多线程竞争堆指针。

### 源码级回答

**为什么需要:**
- 没有 TLAB: 多线程同时 `new` → CAS 竞争同一个 `_top` 指针 → 高争用
- 有 TLAB: 每个线程有自己的 `[_top, _end)` 区间 → 本线程内 bump-the-pointer 无锁

**数据结构:**
```cpp
// ThreadLocalAllocBuffer (每个 JavaThread 内嵌)
HeapWord* _start;    // TLAB 起始地址
HeapWord* _top;      // 下一次分配的位置
HeapWord* _end;      // TLAB 结束地址（可能含对齐预留）
size_t _desired_size; // 期望大小（自适应调整）
```

**分配流程:**
```
1. top + obj_size <= end?  → top += obj_size (无锁!)
2. 超出 TLAB → 判断是否 refill:
   - 剩余空间 < _refill_waste_limit → 废弃当前 TLAB，申请新 TLAB
   - 剩余空间 >= _refill_waste_limit → 直接从 Eden 分配（不废弃 TLAB）
3. 新 TLAB 从 G1 HeapRegion 的 _top CAS 划拨
```

**自适应大小调整:**
```
desired_size = MAX(平均分配速率 × EdenRefillFactor, MinTLABSize)
             受限于 MaxTLABSize 和 Region 剩余空间
```

**面试亮点:**
> "TLAB 的 `_end` 不是真正的末尾，它可能预留了 `alignment_reserve` 用于放 dummy object 填充，确保 Region 内部可解析遍历。"

> 📖 详细文档: `Universe/3.3-TLAB.md`

---

## Q4: 什么是逃逸分析？它能带来哪些优化？⭐⭐

### 一句话结论
逃逸分析判断对象是否逃出方法/线程，未逃逸的对象可以做**栈上分配**（标量替换）、**锁消除**、**标量替换消除对象头开销**。

### 源码级回答

**逃逸状态三级 (ConnectionGraph):**
```
NoEscape    → 对象不逃出当前方法 → 可以标量替换
ArgEscape   → 对象作为参数传递但不逃出线程 → 可以锁消除
GlobalEscape → 对象被全局引用/存入堆字段 → 无法优化
```

**C2 实现核心:**
```cpp
// src/hotspot/share/opto/escape.cpp
ConnectionGraph::compute_escape() {
  // 1. 构建连接图（PointsTo 关系）
  // 2. 传播逃逸状态（worklist 迭代到不动点）
  // 3. 标记可优化的分配
}
```

**三大优化:**

| 优化 | 条件 | 效果 |
|------|------|------|
| 标量替换 | NoEscape | 对象字段拆散为局部变量，省去分配+GC |
| 锁消除 | NoEscape/ArgEscape | `synchronized(localObj)` 的锁操作直接移除 |
| 标量替换 | NoEscape | 消除对象头 (12 bytes) + 对齐填充 |

**注意: HotSpot 没有真正的"栈上分配"**，而是通过**标量替换**将对象拆散：
```java
// 源代码
Point p = new Point(x, y);
return p.x + p.y;

// 标量替换后（C2 IR 层面）
return x + y;  // Point 对象根本不存在了
```

**相关 JVM 参数:**
```
-XX:+DoEscapeAnalysis      # 开启逃逸分析（默认开）
-XX:+EliminateAllocations  # 开启标量替换（默认开）
-XX:+EliminateLocks        # 开启锁消除（默认开）
```

> 📖 详细文档: `C2Compiler/escape_analysis.md`

---

## Q5: hashCode() 的值是怎么生成的？存在哪里？⭐⭐

### 一句话结论
`hashCode()` 第一次调用时由 `ObjectSynchronizer::FastHashCode()` 计算并写入 markWord 的 31-bit hash 字段，之后直接读取。

### 源码级回答

**六种 hashCode 策略 (`-XX:hashCode=N`):**
```
0 → Park-Miller 随机数 (旧默认)
1 → 对象地址 XOR 线程随机数
2 → 始终返回 1 (测试用)
3 → 递增序列 (测试用)
4 → 对象地址强转 (不推荐, GC 移动会变)
5 → Marsaglia XorShift (JDK 8+ 默认) ← 当前默认
```

**FastHashCode 三路查找:**
```
1. markWord 中已有 hash? → 直接返回 (最快路径)
2. 对象正持有轻量级锁? → 从 BasicLock 的 displaced header 取 hash
3. 对象持有重量级锁? → 从 ObjectMonitor._header 取 hash
4. 都没有 → 调用 get_next_hash() 计算，CAS 写入 markWord
```

**hashCode 与偏向锁的冲突:**
- markWord 中 hash 占 31 bit，偏向锁的 thread id 占 54 bit → **同一位置**
- 所以: **调用过 hashCode() 的对象永远无法进入偏向锁状态**

> 📖 详细文档: `Runtime/ch01_object_header_markword.md`, `NativeLibs/ch14_libjava.md`

---

## Q6: 什么是压缩指针？原理是什么？⭐⭐

### 一句话结论
压缩指针将 8 字节 oop/klass 指针压缩为 4 字节，利用**对象 8 字节对齐**的特性，通过左移 3 位还原真实地址。

### 源码级回答

**两种压缩指针:**

| 类型 | 压缩谁 | 存储位置 | 参数 |
|------|--------|---------|------|
| CompressedOops | 对象引用 (oop) | 对象字段中 | `-XX:+UseCompressedOops` |
| CompressedClassPointers | Klass 指针 | 对象头中 | `-XX:+UseCompressedClassPointers` |

**编解码公式:**
```
// 编码 (8→4 字节)
narrowOop = (oop - base) >> shift

// 解码 (4→8 字节)
oop = base + (narrowOop << shift)
```

**shift 值的选择:**
```
堆 < 4GB  → shift=0, base=0 (Zero-Based)
堆 < 32GB → shift=3, base=0 (Zero-Based, 利用 8 字节对齐)
堆 ≥ 32GB → 压缩指针关闭 (或 shift=3, base≠0)
```

**CompressedClassSpace:**
- 独立的 1GB 连续空间（`-XX:CompressedClassSpaceSize`）
- 只存 Klass 元数据，与 Metaspace 分开
- 编解码: `klass = CompressedClassSpaceBase + (narrowKlass << 3)`

> 📖 详细文档: `Universe/3.4-CompressedOops.md`, `Universe/ch49_compressed_klass_pointers.md`

---

## Q7: 四种引用类型有什么区别？GC 怎么处理它们？⭐⭐

### 一句话结论
强 > 软 > 弱 > 虚，GC 通过 `ReferenceProcessor` 的**四阶段流水线**统一处理，区别在于"何时清除 referent"。

### 源码级回答

| 引用类型 | 清除时机 | 典型用途 | GC 对应阶段 |
|---------|---------|---------|------------|
| Strong | 不可达时回收 | 普通引用 | 正常 GC |
| Soft | 内存不足时 | 缓存 | Phase1: `clear_referent` 按 LRU 策略 |
| Weak | 下次 GC | WeakHashMap | Phase2: 统一清理 |
| Final | referent 不可达时 | `finalize()` | Phase3: 保活 + 入队 |
| Phantom | referent 被回收后 | DirectByteBuffer | Phase4: 清理入队 |

**四阶段处理 (ReferenceProcessor):**
```
Phase1: process_discovered_reflist(SoftRef)
        → SoftRef 策略: clock - timestamp > free_heap * ms_per_mb? 清除 : 保留

Phase2: process_discovered_reflist(WeakRef + SoftRef 残留)
        → 统一清除 referent

Phase3: process_discovered_reflist(FinalRef)
        → 保活 referent (让 Finalizer 线程还能访问)
        → 加入 ReferenceQueue

Phase4: process_discovered_reflist(PhantomRef)
        → 清除 + 入队
```

**Finalizer 的代价:**
- `has_finalizer` → 分配时 `register_finalizer()` → JNI upcall → Finalizer.register() → 双向链表
- **两次 GC 才能回收** (第一次入队，第二次真正回收)
- FinalizerThread 优先级低，可能堆积 → OOM

> 📖 详细文档: `Runtime/ch04_object_finalization_reference.md`, `ReferenceProcessor/referenceProcessor_init.md`

---

## Q8: System.arraycopy() 为什么快？底层怎么实现的？⭐⭐⭐

### 一句话结论
从 Java 层到最终汇编经历 **10 层调用**，最终落到 `StubRoutines::_jlong_arraycopy` 等 Stub，用 **rep movsq / AVX** 批量内存拷贝。

### 源码级回答

```
Java: System.arraycopy()
  → JNI: JVM_ArrayCopy()
    → ObjArrayKlass::copy_array() / TypeArrayKlass::copy_array()
      → Access API: arraycopy_conjoint()
        → 基本类型: Copy::conjoint_jlongs_atomic()
          → pd_conjoint_jlongs()
            → StubRoutines::_jlong_arraycopy (汇编 Stub)
              → rep movsq (x86_64)
        → 引用类型: G1 写屏障 + 元素拷贝
```

**为什么比 for 循环快:**
1. **单条指令批量操作**: `rep movsq` 一条指令搬运整个数组
2. **跳过 Java 边界检查**: 一次性检查 src/dst/offset/length，不是逐元素
3. **跳过对象头读取**: 直接操作原始内存地址
4. **引用数组**: 批量写屏障而非逐个

> 📖 详细文档: `NativeLibs/ch14_libjava.md`, `StubRoutines/stubRoutines_init2.md`

---

## Q9: 对象在堆上是怎么遍历的？为什么需要 BlockOffsetTable？⭐⭐⭐

### 一句话结论
G1 每个 Region 维护 **BlockOffsetTable (BOT)**，记录每 512 字节 card 的起始对象偏移，使 GC 能从任意 card 地址**快速定位该 card 内第一个对象头**。

### 源码级回答

**问题:** GC 需要遍历某个 card（512字节）内的对象，但不知道第一个对象从哪开始。

**BOT 原理:**
```
Region 内存:  |----card0----|----card1----|----card2----|
BOT 数组:     [    0         2            0           ...]
含义:          card0起始对象  card1起始对象在前2个card   card2起始对象在本card
```

- 每个 card 512 字节 → BOT 每个 entry 1 字节
- entry 值 = "第一个对象的起始位置在这个 card 之前多少个 card"
- **Power-of-2 编码**: 对于远距离对象，编码为 `N_words + 2^(k-1)` 的幂次链，形成对数跳跃

**用途:**
- Young GC 扫描 RSet 时: card 地址 → BOT 查到第一个对象 → 遍历对象的引用字段
- 并发标记: SATB 标记后需要知道对象边界

> 📖 详细文档: `Universe/C.6-G1BlockOffsetTable.md`

---

## Q10: Cleaner 和 finalize() 有什么区别？DirectByteBuffer 怎么回收堆外内存？⭐⭐

### 一句话结论
`Cleaner` 基于 `PhantomReference` + `ReferenceHandler` 线程，比 `finalize()` 更可靠、更及时，DirectByteBuffer 通过 Cleaner 调用 `Unsafe.freeMemory()` 回收堆外内存。

### 源码级回答

| 对比 | finalize() | Cleaner |
|------|-----------|---------|
| 触发线程 | FinalizerThread (优先级低) | ReferenceHandler (优先级最高 10) |
| 引用类型 | FinalReference | PhantomReference (jdk.internal.ref.Cleaner) |
| 回收速度 | 至少两次 GC | 一次 GC 后立即执行 |
| 异常处理 | 被吞掉 | 被吞掉但不阻塞队列 |
| 对象复活 | 可以在 finalize() 中复活对象 | 不可能（PhantomRef 拿不到 referent） |

**DirectByteBuffer 回收链路:**
```java
// 分配时注册 Cleaner
DirectByteBuffer(int cap) {
    Cleaner.create(this, new Deallocator(base, size, cap));
}

// GC 回收 DirectByteBuffer 后，Cleaner 触发:
Deallocator.run() → unsafe.freeMemory(address)
```

**ReferenceHandler 线程处理 Cleaner 的特殊路径:**
```java
// Reference.java
if (r instanceof Cleaner) {
    ((Cleaner)r).clean();  // 直接调用，不入队!
    continue;
}
```
→ Cleaner 不走 ReferenceQueue，而是在 ReferenceHandler 线程中**直接执行** `clean()` 方法。

> 📖 详细文档: `Runtime/ch04_object_finalization_reference.md`

---

## Q11: 对象分配的完整链路是什么？从 Java 代码到 Region 级别 ⭐⭐⭐

### 一句话结论
`new X()` → 解释器汇编快速路径(TLAB) → C++ 慢速路径(MemAllocator) → G1 attempt_allocation → HeapRegion CAS → 失败触发 GC → 重试。

### 源码级回答

```
┌──────────── 快速路径 (99%+ 的分配) ────────────┐
│                                                │
│ 解释器: _new bytecode template                  │
│   → 检查 Klass 已初始化                         │
│   → 从 _layout_helper 取对象大小                 │
│   → TLAB: thread→tlab_top + size <= tlab_end?   │
│   → CAS bump tlab_top                          │
│   → rep stosq 清零                              │
│   → 写 markWord + Klass 指针                    │
│                                                │
│ 耗时: ~10 ns                                    │
└────────────────────────────────────────────────┘
         │ 失败 (TLAB 满)
         ▼
┌──────────── 慢速路径 ──────────────────────────┐
│                                                │
│ InterpreterRuntime::_new()                      │
│   → InstanceKlass::allocate_instance()          │
│     → CollectedHeap::obj_allocate()             │
│       → MemAllocator::allocate()                │
│         → 尝试 TLAB refill (新 TLAB)             │
│         → 尝试 Eden 直接分配                     │
│         → G1: attempt_allocation()              │
│           → 当前 Region 有空间? CAS 分配         │
│           → 没有? 切换 Region                    │
│         → 失败? attempt_allocation_slow()        │
│           → 加锁 → expand heap → 还失败?         │
│           → do_collection_pause() 触发 GC!      │
│           → GC 后重试                            │
│                                                │
│ 耗时: 1μs ~ 10ms (触发GC时)                     │
└────────────────────────────────────────────────┘
```

> 📖 详细文档: `Runtime/ch02_object_allocation.md`, `Interpreter/5.1-allocation-bytecodes-deep-dive.md`

---

## Q12: Humongous 对象是什么？G1 怎么处理它？⭐⭐

### 一句话结论
大于 Region 的一半（默认 2MB，Region=4MB）的对象是 Humongous 对象，直接分配在连续的 Humongous Region 中，可被 **Eager Reclaim** 在 Young GC 时快速回收。

### 源码级回答

**判断阈值:**
```cpp
// HeapRegion::GrainBytes / 2 = 4MB / 2 = 2MB
bool is_humongous(size_t word_size) {
    return word_size >= GrainWords / 2;
}
```

**分配流程:**
```
attempt_allocation_humongous()
  → 需要 N 个连续 Region (N = ceil(obj_size / RegionSize))
  → 搜索 HeapRegionManager 的 FreeRegionList
  → 第一个 Region 标记为 StartsHumongous，后续标记为 ContinuesHumongous
  → 找不到连续空间? → Full GC 压缩
```

**Eager Reclaim (快速回收):**
```
Young GC 时:
  → 扫描所有 Humongous Region
  → 如果 referent 未被引用 (RSet 为空 + 不在 SATB buffer)
  → 直接回收，不需要等并发标记!
```

**常见问题:**
- `byte[2MB]` 是 Humongous → 频繁创建导致碎片
- 解决: `-XX:G1HeapRegionSize=8m` 增大 Region

> 📖 详细文档: `G1-GC/ch48_humongous_complete.md`

---

## Q13: 什么是标量替换？和栈上分配是什么关系？⭐⭐⭐

### 一句话结论
HotSpot **没有真正的栈上分配**，"栈上分配"本质是 C2 逃逸分析后的**标量替换**——将对象拆散为独立的局部变量。

### 源码级回答

**标量 vs 聚合量:**
- 标量 (Scalar): 不可再分的原始类型 (int, long, reference)
- 聚合量 (Aggregate): 可再分的对象 (Point 有 x, y 两个字段)

**标量替换过程 (C2 编译器):**
```java
// 源码
Point p = new Point(3, 5);
int sum = p.x + p.y;

// 逃逸分析: p 是 NoEscape
// 标量替换后 (C2 IR):
int p_x = 3;
int p_y = 5;
int sum = p_x + p_y;

// 常量折叠后:
int sum = 8;
```

**为什么不做真正的栈上分配?**
1. GC 需要知道栈上所有 oop → 需要额外的 OopMap 跟踪
2. 对象可能很大 → 栈空间有限
3. 标量替换效果更好 → 连对象头都省了

**确认效果的方法:**
```
-XX:+PrintEliminateAllocations  # 打印消除的分配
-XX:+TraceEscapeAnalysis        # 追踪逃逸分析过程
```

> 📖 详细文档: `C2Compiler/escape_analysis.md`

---

## Q14: 对象分配时为什么要清零？什么时候清零？⭐⭐⭐

### 一句话结论
Java 语言规范要求字段有默认零值，JVM 在分配后立即用 `rep stosq` 批量清零，这是**必须的语义保证**而非优化。

### 源码级回答

**清零时机（解释器快速路径）:**
```x86
; 分配完 TLAB 空间后，立即清零
xorq rax, rax          ; rax = 0
rep stosq              ; 从 rdi 开始, rcx 个 qword 全写 0
```

**慢速路径:**
```cpp
// MemAllocator::mem_allocate()
HeapWord* mem = Universe::heap()->mem_allocate(size, &need_zero);
if (need_zero) {
    Copy::fill_to_aligned_words(mem, size);  // 清零
}
```

**为什么 TLAB 也要清零?**
- TLAB 是从 Region 划出来的，Region 内存可能残留旧对象数据
- Java 规范: `int x;` 必须是 0，`Object ref;` 必须是 null
- 不清零 → 读到随机值 → 安全漏洞 + 正确性问题

**优化: TLAB 预清零 (`-XX:+ZeroTLAB`)**
- 默认 false: 分配对象时逐个清零
- 设为 true: 获得新 TLAB 时整块清零（利用缓存预取效果更好）

> 📖 详细文档: `Runtime/ch02_object_allocation.md`

---

## 🎯 面试话术建议

### 如何展示对象分配的源码功底:
> "我看过 HotSpot 的对象分配链路。解释器的 `_new` 字节码模板是一段 x86 汇编，快速路径就是 TLAB bump-the-pointer，用 CAS 移动 `tlab_top`，然后 `rep stosq` 清零，写入 markWord 和 Klass 指针。整个快速路径不到 10 条汇编指令，大约 10 纳秒。慢速路径才会走到 C++ 的 `MemAllocator`，最终到 G1 的 `attempt_allocation`。我用 GDB 在 slowdebug 版本上打断点验证过整个流程。"

### 如何展示引用处理的源码功底:
> "GC 对四种引用类型的处理是在 `ReferenceProcessor` 的四阶段流水线中统一完成的。SoftReference 的清除策略是一个 LRU 公式：`clock - timestamp > free_heap * ms_per_mb`，也就是说空闲堆越大，软引用活得越久。Cleaner 和 finalize 的关键区别是 Cleaner 由 ReferenceHandler 线程直接执行 `clean()` 方法，不经过 ReferenceQueue，而 FinalizerThread 优先级只有 8，可能处理不及时导致堆积。"
