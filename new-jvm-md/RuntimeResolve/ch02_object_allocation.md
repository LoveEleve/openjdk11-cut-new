# Chapter 2: 对象分配完整链路 — 从 new 到堆内存

> **系列**：Runtime System — 对象生命周期  
> **环境**：OpenJDK 11, `-Xms8g -Xmx8g -XX:+UseG1GC -XX:-UseBiasedLocking`, LP64  
> **G1 Region**：4MB，humongous 阈值 = Region/2 = 2MB

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **Chapter 2: 对象分配完整链路 — 从 new 到堆内存**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 1. 问题引入：一个 `new Object()` 到底发生了什么？

Java 程序员写 `new MyClass()` 只需要一行代码，但在 JVM 内部，这一行涉及：
1. **字节码解析** — 解释器/JIT 识别 `new` 指令
2. **类检查** — 类是否已加载、已初始化、可实例化
3. **大小计算** — 对象需要多少字节
4. **内存分配** — TLAB 快速路径 → TLAB 慢速路径 → 堆直接分配 → 触发 GC
5. **对象初始化** — 清零 + 设置 mark word + 设置 klass pointer

本文将沿着这条链路，逐层深入到最底层的 HeapRegion bump-the-pointer 操作。

---

## 2. 完整调用链总览

```
new 字节码 (bytecode: 0xBB)
  │
  ├─ [解释器快速路径] TemplateTable::_new()           (x86 汇编生成)
  │    ├─ 检查: 类已解析? 已初始化? 无 finalizer?
  │    ├─ TLAB bump-the-pointer (tlab_allocate 宏)
  │    ├─ 成功 → 清零 + 设 mark/klass → 返回
  │    └─ 失败 → fall through to slow case
  │
  └─ [解释器慢速路径] InterpreterRuntime::_new()       
       │  ① pool->klass_at()          — 解析常量池
       │  ② klass->check_valid...()   — 不能是抽象类/接口
       │  ③ klass->initialize()       — 确保类初始化完成
       │
       └─ InstanceKlass::allocate_instance()
            │  size = size_helper()     — 对象大小(HeapWord 单位)
            │
            └─ CollectedHeap::obj_allocate()
                 │  创建 ObjAllocator(klass, size)
                 │
                 └─ MemAllocator::allocate()          ← 统一分配入口
                      │
                      └─ mem_allocate()
                           │
                           ├─ [路径A] allocate_inside_tlab()
                           │    ├─ TLAB::allocate()             ← bump-the-pointer
                           │    └─ allocate_inside_tlab_slow()  ← refill TLAB
                           │         └─ heap->allocate_new_tlab()
                           │              └─ [G1] attempt_allocation()
                           │                   ├─ G1Allocator → MutatorAllocRegion
                           │                   └─ attempt_allocation_slow()
                           │                        └─ 加锁重试 / 触发 GC
                           │
                           └─ [路径B] allocate_outside_tlab()
                                └─ heap->mem_allocate()
                                     └─ [G1] attempt_allocation()
                                          或 attempt_allocation_humongous()
```

---

## 3. 解释器快速路径 — TemplateTable::_new()

> 源码：`src/hotspot/cpu/x86/templateTable_x86.cpp:3991`

这是**性能最关键**的路径。解释器为 `new` 字节码生成的是一段 x86 机器码，在运行时直接执行，完全不进入 C++ 代码。

### 3.1 前置检查（汇编）

```
1. 从字节码流读取 2 字节的常量池索引 (rdx)
2. 检查常量池 tag == JVM_CONSTANT_Class (类已解析?)
   → 否: 跳转 slow_case
3. 加载 InstanceKlass* (rcx)
4. 检查 init_state == fully_initialized
   → 否: 跳转 slow_case (类未初始化, 需要 C++ 处理)
5. 读取 layout_helper (rdx = 对象字节大小)
6. 检查 _lh_instance_slow_path_bit (有 finalizer 或异常布局?)
   → 是: 跳转 slow_case
```

**关键优化**：所有这些检查都在汇编中完成，没有函数调用开销。只有当所有条件都满足（类已初始化、无 finalizer）时，才走快速分配。

### 3.2 TLAB 快速分配（汇编）

```cpp
// 生成 tlab_allocate 宏汇编：
// rax = tlab.top()
// rbx = rax + rdx (new_top = top + size)
// if (rbx > tlab.end()) → slow_case
// tlab.set_top(rbx)
// return rax (对象地址)
__ tlab_allocate(thread, rax, rdx, 0, rcx, rbx, slow_case);
```

这就是著名的 **bump-the-pointer** 分配：
1. 读取 TLAB 的 `_top`
2. `new_top = top + object_size`
3. 如果 `new_top > end` → 空间不足，跳 slow case
4. 设置 `_top = new_top`
5. 返回旧 `top` 作为对象地址

**无锁、无 CAS、一条路径只需 ~10 条机器指令**。这是 Java 对象分配极快的根本原因。

### 3.3 对象初始化（汇编）

分配成功后，还在汇编中完成初始化：

```
1. 清零对象字段区域（从 sizeof(oopDesc) 到末尾，用 0 循环写入）
2. 设置 mark word = markOopDesc::prototype() (= 0x1, 无锁/无hash/age=0)
3. 设置 klass pointer:
   - 压缩模式: store_klass_gap(0) + encode_klass_not_null(klass) → offset 8
   - 非压缩模式: klass* → offset 8
```

**注意**：在 `-XX:-UseBiasedLocking` 下，mark word 写入的是常量 `0x1`（`markOopDesc::prototype()`）。如果开启了偏向锁，则写入的是 `klass->prototype_header()`（包含偏向模式的 mark word）。

---

## 4. 解释器慢速路径 — InterpreterRuntime::_new()

> 源码：`src/hotspot/share/interpreter/interpreterRuntime.cpp:217`

当快速路径的任何条件不满足时，解释器跳转到 C++ 运行时：

```cpp
IRT_ENTRY(void, InterpreterRuntime::_new(JavaThread* thread, ConstantPool* pool, int index))
  Klass* k = pool->klass_at(index, CHECK);        // ① 解析类
  InstanceKlass* klass = InstanceKlass::cast(k);
  klass->check_valid_for_instantiation(true, CHECK); // ② 不能是抽象类/接口
  klass->initialize(CHECK);                          // ③ 触发类初始化
  oop obj = klass->allocate_instance(CHECK);         // ④ 分配对象
  thread->set_vm_result(obj);                        // ⑤ 返回给解释器
IRT_END
```

**为什么需要慢速路径？** 以下场景会触发：
- 类尚未解析（第一次 `new` 某个类）
- 类尚未初始化（`<clinit>` 还没跑）
- 类有 finalizer（需要注册到 FinalizerThread）
- TLAB 空间不足（快速路径 bump-the-pointer 失败）

---

## 5. InstanceKlass::allocate_instance()

> 源码：`src/hotspot/share/oops/instanceKlass.cpp:1240`

```cpp
instanceOop InstanceKlass::allocate_instance(TRAPS) {
  bool has_finalizer_flag = has_finalizer();
  int size = size_helper();     // ← 对象大小，在类加载时已计算好
  
  instanceOop i;
  i = (instanceOop)Universe::heap()->obj_allocate(this, size, CHECK_NULL);
  
  if (has_finalizer_flag && !RegisterFinalizersAtInit) {
    i = register_finalizer(i, CHECK_NULL);  // 注册 finalizer
  }
  return i;
}
```

`size_helper()` 返回的是**以 HeapWord（8 字节）为单位**的对象总大小（含对象头）。这个值在类加载时就已经计算并缓存在 `Klass::_layout_helper` 中。

例如，一个空的 `new Object()`：
- mark word: 8B + compressed klass: 4B + padding: 4B = 16B = 2 HeapWords

**Finalizer 处理**：如果类覆盖了 `finalize()` 方法（且不是 `Object.finalize()`），会调用 `register_finalizer()` → `Finalizer.register(obj)`，将对象注册到 `FinalizerThread` 的队列中。

---

## 6. MemAllocator：统一内存分配框架

> 源码：`src/hotspot/share/gc/shared/memAllocator.hpp`, `memAllocator.cpp`

### 6.1 类层次

```
MemAllocator (基类)
  ├── ObjAllocator         — 普通对象 (new MyClass)
  ├── ObjArrayAllocator    — 对象数组 (new Object[10])
  └── ClassAllocator       — java.lang.Class 对象 (特殊)
```

### 6.2 入口：allocate()

```cpp
oop MemAllocator::allocate() const {
  oop obj = NULL;
  {
    Allocation allocation(*this, &obj);    // RAII: 析构时检查OOM + 通知监控
    HeapWord* mem = mem_allocate(allocation);  // 分配原始内存
    if (mem != NULL) {
      obj = initialize(mem);               // 清零 + 设置 mark/klass
    }
  }
  return obj;
}
```

`Allocation` 是一个 RAII 包装器。它在析构时会：
1. 检查是否 OOM → 抛出 `OutOfMemoryError`
2. 通知 JFR sampler（飞行记录器采样）
3. 通知 JVMTI（`VMObjectAlloc` 事件）
4. 通知 `LowMemoryDetector`（低内存检测）

### 6.3 mem_allocate() — 三条路径

```cpp
HeapWord* MemAllocator::mem_allocate(Allocation& allocation) const {
  if (UseTLAB) {
    HeapWord* result = allocate_inside_tlab(allocation);
    if (result != NULL) {
      return result;
    }
  }
  return allocate_outside_tlab(allocation);
}
```

| 路径 | 条件 | 说明 |
|------|------|------|
| **TLAB 快速** | `UseTLAB` && TLAB 有空间 | bump-the-pointer，最快 |
| **TLAB 慢速** | `UseTLAB` && TLAB 空间不足 | 废弃旧 TLAB → 申请新 TLAB → 在新 TLAB 中分配 |
| **堆直接分配** | TLAB 关闭或 TLAB 慢速也失败 | 直接调用 `heap->mem_allocate()` |

---

## 7. TLAB 快速路径 — allocate_inside_tlab()

> 源码：`memAllocator.cpp:284`, `threadLocalAllocBuffer.inline.hpp:34`

```cpp
HeapWord* MemAllocator::allocate_inside_tlab(Allocation& allocation) const {
  HeapWord* mem = _thread->tlab().allocate(_word_size);
  if (mem != NULL) {
    return mem;    // 快速路径成功
  }
  return allocate_inside_tlab_slow(allocation);  // 慢速路径
}
```

### 7.1 TLAB::allocate() — bump-the-pointer

```cpp
inline HeapWord* ThreadLocalAllocBuffer::allocate(size_t size) {
  invariants();
  HeapWord* obj = top();
  if (pointer_delta(end(), obj) >= size) {
    set_top(obj + size);
    return obj;
  }
  return NULL;
}
```

这就是整个 JVM 中**最快的内存分配**：
- 读 `_top`（线程私有，无竞争）
- 比较 `end() - top() >= size`
- 移动 `_top`
- 返回旧 `_top`

**无锁、无 CAS、无系统调用**。在 x86 上编译为 ~5 条机器指令。

---

## 8. TLAB 慢速路径 — allocate_inside_tlab_slow()

> 源码：`memAllocator.cpp:297`

当 TLAB 剩余空间不足时，进入慢速路径。核心决策：**是废弃当前 TLAB 申请新的，还是保留 TLAB 直接去堆上分配？**

### 8.1 决策逻辑

```cpp
HeapWord* MemAllocator::allocate_inside_tlab_slow(Allocation& allocation) const {
  ThreadLocalAllocBuffer& tlab = _thread->tlab();
  
  // 关键决策：当前 TLAB 剩余空间是否值得保留？
  if (tlab.free() > tlab.refill_waste_limit()) {
    // 剩余空间太多，不舍得丢弃 → 记录为 slow allocation，返回 NULL
    // 上层会走 allocate_outside_tlab() 直接堆分配
    tlab.record_slow_allocation(_word_size);
    return NULL;
  }
  
  // 剩余空间可接受的浪费 → 废弃旧 TLAB，申请新的
  size_t new_tlab_size = tlab.compute_size(_word_size);
  tlab.clear_before_allocation();  // 把旧 TLAB 填充 dummy 对象，使其 parsable
  
  if (new_tlab_size == 0) return NULL;
  
  size_t min_tlab_size = ThreadLocalAllocBuffer::compute_min_size(_word_size);
  HeapWord* mem = _heap->allocate_new_tlab(min_tlab_size, new_tlab_size, 
                                           &allocation._allocated_tlab_size);
  if (mem == NULL) return NULL;
  
  // 用新内存填充 TLAB
  tlab.fill(mem, mem + _word_size, allocation._allocated_tlab_size);
  return mem;  // 返回 TLAB 中对象的起始地址
}
```

### 8.2 refill_waste_limit — 浪费阈值

`_refill_waste_limit` 控制 TLAB 的丢弃策略：

```
初始值 = desired_size / TLABRefillWasteFraction
       = desired_size / 64（默认 TLABRefillWasteFraction=64）
```

例如 TLAB 大小为 256KB：
- 初始浪费阈值 = 256KB / 64 = 4KB
- 如果剩余 > 4KB → 不换 TLAB，直接堆分配
- 如果剩余 ≤ 4KB → 丢弃旧 TLAB，申请新的

**每次走 slow allocation（保留 TLAB），阈值会递增**：

```cpp
void record_slow_allocation(size_t obj_size) {
  set_refill_waste_limit(refill_waste_limit() + refill_waste_limit_increment());
  // increment = TLABWasteIncrement，默认 4 (HeapWords = 32 bytes)
}
```

这意味着如果一个线程**频繁**分配大对象导致 slow allocation，阈值会不断增大，最终触发 TLAB 更换。这是一个自适应机制。

### 8.3 compute_size() — 新 TLAB 大小计算

```cpp
inline size_t ThreadLocalAllocBuffer::compute_size(size_t obj_size) {
  const size_t available_size = Universe::heap()->unsafe_max_tlab_alloc(myThread()) / HeapWordSize;
  size_t new_tlab_size = MIN3(available_size, 
                               desired_size() + align_object_size(obj_size), 
                               max_size());
  if (new_tlab_size < compute_min_size(obj_size)) {
    return 0;  // 堆空间不够，分配失败
  }
  return new_tlab_size;
}
```

新 TLAB 大小取三者的最小值：
1. **堆中可用空间**（`unsafe_max_tlab_alloc`）
2. **期望大小 + 对象大小**（`desired_size + obj_size`）
3. **TLAB 最大限制**（`max_size`）

### 8.4 clear_before_allocation() — 旧 TLAB 退休

```cpp
void ThreadLocalAllocBuffer::clear_before_allocation() {
  _slow_refill_waste += (unsigned)remaining();
  make_parsable(true);  // 填充 dummy int[] 对象，使 GC 可以遍历
}
```

**为什么要填充 dummy 对象？** GC 需要遍历堆中所有对象。TLAB 尾部的未使用空间不是合法对象，如果不填充，GC 遍历时会崩溃。填充一个 `int[]` 数组（类型为 `T_INT`）使这片空间看起来像一个合法对象。

### 8.5 fill() — 安装新 TLAB

```cpp
void ThreadLocalAllocBuffer::fill(HeapWord* start, HeapWord* top, size_t new_size) {
  _number_of_refills++;
  _allocated_size += new_size;
  initialize(start, top, start + new_size - alignment_reserve());
  set_refill_waste_limit(initial_refill_waste_limit());  // 重置浪费阈值
}

void ThreadLocalAllocBuffer::initialize(HeapWord* start, HeapWord* top, HeapWord* end) {
  set_start(start);
  set_top(top);       // 注意：top = start + obj_size，对象已经占了第一段
  set_pf_top(top);
  set_end(end);
  set_allocation_end(end);
}
```

新 TLAB 安装后，`_top` 已经指向第一个对象之后（因为对象已在 TLAB 中分配），`_end` 留有 `alignment_reserve` 的安全保留空间（给 C2 预取指令用）。

---

## 9. TLAB 结构详解

> 源码：`src/hotspot/share/gc/shared/threadLocalAllocBuffer.hpp`

### 9.1 内存布局

```
 _start                    _top              _end      _allocation_end  hard_end
   │                        │                  │              │             │
   ▼                        ▼                  ▼              ▼             ▼
   ┌────────────────────────┬──────────────────┬──────────────┬─────────────┐
   │  已分配的对象区域       │  可分配空间       │  采样保留    │ prefetch 保留│
   │  (被 GC 视为活跃对象)  │  (bump-pointer)  │  (可选)      │ (C2 安全区) │
   └────────────────────────┴──────────────────┴──────────────┴─────────────┘
```

### 9.2 核心字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `_start` | HeapWord* | TLAB 起始地址 |
| `_top` | HeapWord* | 下一次分配的位置（bump pointer） |
| `_pf_top` | HeapWord* | 预取水位线（prefetch watermark） |
| `_end` | HeapWord* | 分配终点（可能被采样调整） |
| `_allocation_end` | HeapWord* | 真正的 TLAB 终点（排除 alignment_reserve） |
| `_desired_size` | size_t | 期望大小（含 alignment_reserve），动态调整 |
| `_refill_waste_limit` | size_t | 浪费阈值，决定是否废弃当前 TLAB |

### 9.3 TLAB 大小的动态调整

每次 GC 后，会调用 `resize()` 调整每个线程的 TLAB 大小：

```cpp
void ThreadLocalAllocBuffer::resize() {
  // 基于历史分配比例计算新大小
  size_t alloc = (size_t)(_allocation_fraction.average() *
                          (Universe::heap()->tlab_capacity(myThread()) / HeapWordSize));
  size_t new_size = alloc / _target_refills;  // _target_refills = 50 (默认)
  
  new_size = MIN2(MAX2(new_size, min_size()), max_size());
  set_desired_size(align_object_size(new_size));
  set_refill_waste_limit(initial_refill_waste_limit());
}
```

**核心思想**：
- `_allocation_fraction`：该线程在上次 GC 周期中占用 Eden 的比例（加权平均）
- 分配多的线程 → 更大的 TLAB → 更少的 refill → 更少的同步开销
- 分配少的线程 → 更小的 TLAB → 更少的内存浪费

**日志参数**：`-Xlog:gc+tlab=trace` 可看到 TLAB 统计信息：

```
[trace][gc,tlab] TLAB: fill thread: 0x00007f2c14001000 [id: 25]
  desired_size: 256KB slow allocs: 3 refill waste: 4096B
  alloc: 0.24500 63.0KB refills: 12 waste 1.2% gc: 320B slow: 640B fast: 0B
```

### 9.4 TLAB 初始化参数

```cpp
void ThreadLocalAllocBuffer::startup_initialization() {
  _target_refills = 100 / (2 * TLABWasteTargetPercent);  // = 50
  // 假设每个 TLAB 平均用一半就会 GC
  // 目标: 每个 GC 周期内每个线程 refill 50 次
  
  _global_stats = new GlobalTLABStats();
  
  // C2 预取保留空间
  int lines = MAX2(AllocatePrefetchLines, AllocateInstancePrefetchLines) + 2;
  _reserve_for_allocation_prefetch = 
    (AllocatePrefetchDistance + AllocatePrefetchStepSize * lines) / HeapWordSize;
}
```

初始 TLAB 大小的计算（`initial_desired_size()`）：

```cpp
size_t init_sz = (tlab_capacity / HeapWordSize) / (nof_threads * target_refills);
// 例如: Eden = 6GB, 1个线程, refills=50
// init_sz = (6GB/8) / (1 * 50) ≈ 15MB
// 但受 max_size 限制 (max_size = 堆的 1% 或 Region/2)
```

---

## 10. G1 堆分配 — 从 TLAB 请求到 HeapRegion

### 10.1 allocate_new_tlab() — G1 的 TLAB 供应

> 源码：`src/hotspot/share/gc/g1/g1CollectedHeap.cpp:397`

```cpp
HeapWord* G1CollectedHeap::allocate_new_tlab(size_t min_size,
                                             size_t requested_size,
                                             size_t* actual_size) {
  assert(!is_humongous(requested_size), "we do not allow humongous TLABs");
  return attempt_allocation(min_size, requested_size, actual_size);
}
```

直接委托给 `attempt_allocation()`。

### 10.2 mem_allocate() — 非 TLAB 的堆分配

> 源码：`g1CollectedHeap.cpp:407`

```cpp
HeapWord* G1CollectedHeap::mem_allocate(size_t word_size,
                                        bool* gc_overhead_limit_was_exceeded) {
  if (is_humongous(word_size)) {
    return attempt_allocation_humongous(word_size);  // 大对象走专用路径
  }
  size_t dummy = 0;
  return attempt_allocation(word_size, word_size, &dummy);
}
```

**humongous 判断**：`word_size >= Region_size / 2`。在 Region=4MB 时，对象 ≥ 2MB（约 256K HeapWords）就是 humongous。

### 10.3 attempt_allocation() — 快速分配

> 源码：`g1CollectedHeap.cpp:738`

```cpp
inline HeapWord* G1CollectedHeap::attempt_allocation(size_t min_word_size,
                                                     size_t desired_word_size,
                                                     size_t* actual_word_size) {
  // 第一步：无锁尝试——在 mutator alloc region 中分配
  HeapWord* result = _allocator->attempt_allocation(min_word_size, 
                                                     desired_word_size, 
                                                     actual_word_size);
  if (result == NULL) {
    // 第二步：慢速路径
    *actual_word_size = desired_word_size;
    result = attempt_allocation_slow(desired_word_size);
  }
  
  if (result != NULL) {
    dirty_young_block(result, *actual_word_size);  // 标记 card table
  }
  return result;
}
```

### 10.4 G1Allocator::attempt_allocation() — 两步无锁尝试

> 源码：`src/hotspot/share/gc/g1/g1Allocator.inline.hpp:44`

```cpp
inline HeapWord* G1Allocator::attempt_allocation(size_t min_word_size,
                                                 size_t desired_word_size,
                                                 size_t* actual_word_size) {
  // 第 1 步：尝试在 retained alloc region 中分配
  HeapWord* result = mutator_alloc_region()->attempt_retained_allocation(
      min_word_size, desired_word_size, actual_word_size);
  if (result != NULL) return result;
  
  // 第 2 步：尝试在当前 mutator alloc region 中分配
  return mutator_alloc_region()->attempt_allocation(
      min_word_size, desired_word_size, actual_word_size);
}
```

**retained alloc region** 是在 GC 后保留的未用完的 region。这样可以减少 region 切换频率。

### 10.5 G1AllocRegion::attempt_allocation() — Region 内分配

> 源码：`src/hotspot/share/gc/g1/g1AllocRegion.inline.hpp:78`

```cpp
inline HeapWord* G1AllocRegion::attempt_allocation(size_t min_word_size,
                                                   size_t desired_word_size,
                                                   size_t* actual_word_size) {
  HeapRegion* alloc_region = _alloc_region;
  HeapWord* result = par_allocate(alloc_region, min_word_size, 
                                   desired_word_size, actual_word_size);
  return result;  // NULL if region full
}
```

### 10.6 HeapRegion — 最底层 bump-the-pointer

> 源码：`src/hotspot/share/gc/g1/heapRegion.inline.hpp:38`

**单线程版（Region 独占时）**：

```cpp
inline HeapWord* G1ContiguousSpace::allocate_impl(size_t min_word_size,
                                                  size_t desired_word_size,
                                                  size_t* actual_size) {
  HeapWord* obj = top();
  size_t available = pointer_delta(end(), obj);
  size_t want_to_allocate = MIN2(available, desired_word_size);
  if (want_to_allocate >= min_word_size) {
    set_top(obj + want_to_allocate);
    *actual_size = want_to_allocate;
    return obj;
  }
  return NULL;
}
```

**并发版（多线程 mutator 共享时，用 CAS）**：

```cpp
inline HeapWord* G1ContiguousSpace::par_allocate_impl(size_t min_word_size,
                                                      size_t desired_word_size,
                                                      size_t* actual_size) {
  do {
    HeapWord* obj = top();
    size_t available = pointer_delta(end(), obj);
    size_t want_to_allocate = MIN2(available, desired_word_size);
    if (want_to_allocate >= min_word_size) {
      HeapWord* new_top = obj + want_to_allocate;
      HeapWord* result = Atomic::cmpxchg(new_top, top_addr(), obj);
      if (result == obj) {
        *actual_size = want_to_allocate;
        return obj;
      }
      // CAS 失败 → 重试
    } else {
      return NULL;  // region 空间不足
    }
  } while (true);
}
```

**关键区别**：
- TLAB 内的 `allocate()` → 简单指针移动，无 CAS（线程私有）
- HeapRegion 的 `par_allocate_impl()` → CAS 循环（多线程共享）

这就是为什么 TLAB 存在的原因：**将多线程竞争的 CAS 转化为线程私有的指针移动**。

---

## 11. attempt_allocation_slow() — 慢速路径

> 源码：`g1CollectedHeap.cpp:418`

当 mutator alloc region 满了，进入慢速路径：

```
for (;;) {
  1. 加 Heap_lock
  2. attempt_allocation_locked(word_size)
     → 在当前 region 重试（可能其他线程已经换了新 region）
     → 成功 → return
  
  3. 如果 GCLocker 活跃 && 可以扩展 young gen:
     attempt_allocation_force(word_size)
     → 强制分配新 region 到 young gen
     → 成功 → return
  
  4. 如果需要 GC:
     do_collection_pause(word_size, gc_count_before, ...)
     → 触发 Young GC / Mixed GC
     → GC 后返回可用空间 → return
     → GC 成功但仍无空间 → return NULL (OOM)
  
  5. 如果 GCLocker 阻止 GC:
     GCLocker::stall_until_clear()
     → 等待 JNI critical region 退出
     → 重试
}
```

**attempt_allocation_locked()** 的额外逻辑：

```cpp
inline HeapWord* G1AllocRegion::attempt_allocation_locked(...) {
  // 先重试当前 region（另一个线程可能已经换了新 region）
  HeapWord* result = attempt_allocation(...);
  if (result != NULL) return result;
  
  // 退休当前 region（填充 dummy 对象）
  retire(true /* fill_up */);
  // 分配一个新的 HeapRegion 作为 alloc region
  result = new_alloc_region_and_allocate(desired_word_size, false);
  return result;
}
```

**日志参数**：`-Xlog:gc+alloc=trace` 可看到分配追踪：

```
[trace][gc,alloc] main: Successfully scheduled collection returning 0x00000007158c0000
[trace][gc,alloc] main: Retried allocation 3 times for 512 words
```

---

## 12. Humongous 对象分配

> 源码：`g1CollectedHeap.cpp:847`

当对象大小 ≥ Region/2（标准环境下 ≥ 2MB）时，走 humongous 分配路径。

### 12.1 与普通分配的关键区别

| 方面 | 普通对象 | Humongous 对象 |
|------|---------|---------------|
| 分配区域 | Young region（Eden） | Old region（连续多个 StartsHumongous + ContinuesHumongous） |
| TLAB | 可以 | 不可以 |
| 触发 GC 的时机 | 空间不足时 | **分配前**就可能触发并发标记 |
| GC cause | `_g1_inc_collection_pause` | `_g1_humongous_allocation` |

### 12.2 分配流程

```
1. 检查是否需要启动并发标记
   if (g1_policy()->need_to_start_conc_mark("concurrent humongous allocation", word_size))
     collect(GCCause::_g1_humongous_allocation);

2. 循环重试:
   a. 加 Heap_lock
   b. humongous_obj_allocate(word_size)
      → 寻找连续的空闲 regions
      → 标记为 StartsHumongous + ContinuesHumongous
      → 成功 → return
   c. 失败 → 触发 GC pause
   d. GC 成功但仍无空间 → return NULL
```

**日志参数**：`-Xlog:gc+alloc+humongous=debug` 可看到 humongous 分配日志。

---

## 13. 对象初始化 — ObjAllocator::initialize()

> 源码：`memAllocator.cpp:412`

内存分配成功后，还需要将原始内存变成合法的 Java 对象：

```cpp
oop ObjAllocator::initialize(HeapWord* mem) const {
  mem_clear(mem);    // ① 清零
  return finish(mem); // ② 设置对象头
}
```

### 13.1 mem_clear() — 字段清零

```cpp
void MemAllocator::mem_clear(HeapWord* mem) const {
  const size_t hs = oopDesc::header_size();  // 对象头大小 (2 HeapWords)
  oopDesc::set_klass_gap(mem, 0);            // 清除 klass gap (offset 12)
  Copy::fill_to_aligned_words(mem + hs, _word_size - hs);  // 零填充字段区域
}
```

为什么只清零 `header_size()` 之后的区域？因为对象头的 mark word 和 klass pointer 会在 `finish()` 中显式设置。

### 13.2 finish() — 设置对象头

```cpp
oop MemAllocator::finish(HeapWord* mem) const {
  if (UseBiasedLocking) {
    oopDesc::set_mark_raw(mem, _klass->prototype_header());
  } else {
    oopDesc::set_mark_raw(mem, markOopDesc::prototype());  // = 0x1
  }
  // klass 指针最后设置（release store）
  // 这保证了并发 GC 看到 klass 时，对象的其他字段已经初始化完毕
  oopDesc::release_set_klass(mem, _klass);
  return oop(mem);
}
```

**为什么 klass 要用 release store？**

GC 线程可能并发扫描堆。当它看到一个 `klass != NULL` 的对象时，就认为该对象是可解析的（parsable）。如果 klass 在字段清零之前就设置了，GC 可能读到未初始化的字段。`release_set_klass` 保证了 **store ordering**：mark word 设置 → 字段清零 → klass 设置，对所有线程可见。

### 13.3 数组对象的初始化

```cpp
oop ObjArrayAllocator::initialize(HeapWord* mem) const {
  if (_do_zero) {
    mem_clear(mem);
  }
  arrayOopDesc::set_length(mem, _length);  // 先设 length
  return finish(mem);                       // 再设 klass
}
```

**length 必须在 klass 之前设置**——因为 GC 计算数组大小需要 length 字段。如果 klass 先设置了但 length 还是 0，GC 会认为这是一个空数组，导致大小计算错误。

---

## 14. allocate_outside_tlab() — TLAB 外直接堆分配

> 源码：`memAllocator.cpp:270`

当 TLAB 路径完全失败时（包括 TLAB 关闭或无法 refill），直接从堆分配：

```cpp
HeapWord* MemAllocator::allocate_outside_tlab(Allocation& allocation) const {
  allocation._allocated_outside_tlab = true;
  HeapWord* mem = _heap->mem_allocate(_word_size, &allocation._overhead_limit_exceeded);
  if (mem == NULL) return mem;
  
  size_t size_in_bytes = _word_size * HeapWordSize;
  _thread->incr_allocated_bytes(size_in_bytes);  // 更新线程分配统计
  return mem;
}
```

这条路径最终也会走到 G1 的 `attempt_allocation()` → `attempt_allocation_slow()` → 可能触发 GC。

---

## 15. OOM 处理

> 源码：`memAllocator.cpp:115`

当所有分配路径都失败，`mem_allocate()` 返回 NULL。`Allocation` 的析构函数检测到这个情况：

```cpp
bool MemAllocator::Allocation::check_out_of_memory() {
  if (obj() != NULL) return false;  // 分配成功
  
  if (!_overhead_limit_exceeded) {
    // 正常 OOM
    report_java_out_of_memory("Java heap space");
    THROW_OOP_(Universe::out_of_memory_error_java_heap(), true);
  } else {
    // GC 开销超限 (GC 花了太多时间但回收太少)
    report_java_out_of_memory("GC overhead limit exceeded");
    THROW_OOP_(Universe::out_of_memory_error_gc_overhead_limit(), true);
  }
}
```

**两种 OOM 类型**：
1. **`Java heap space`**：堆真的满了，GC 后也分配不了
2. **`GC overhead limit exceeded`**：GC 花费超过 98% 的时间，但回收不到 2% 的堆空间（由 `-XX:+UseGCOverheadLimit` 控制，默认开启）

---

## 16. 性能分层总结

| 层级 | 路径 | 锁 | 代价 | 频率 |
|------|------|-----|------|------|
| L0 | 解释器汇编 TLAB bump | 无 | ~5 指令 | 99%+ |
| L1 | MemAllocator TLAB allocate | 无 | ~20 指令 | 偶尔 |
| L2 | TLAB slow (refill) | 无锁 CAS | ~100ns | 每50次分配 |
| L3 | HeapRegion CAS 分配 | CAS | ~200ns | TLAB refill 时 |
| L4 | attempt_allocation_slow | Heap_lock | ~1μs | region 满时 |
| L5 | 触发 GC | STW | ~10ms | 堆满时 |
| L6 | OOM | — | 抛异常 | 极少 |

---

## 17. GDB 验证指南

### 17.1 观察 TLAB 分配

```gdb
# 在 TLAB 分配入口断点
break ThreadLocalAllocBuffer::allocate
run

# 查看 TLAB 状态
p _start
p _top
p _end
p _allocation_end
p pointer_delta(_end, _top)          # 剩余空间
p _desired_size
p _refill_waste_limit
```

### 17.2 观察 TLAB refill

```gdb
break MemAllocator::allocate_inside_tlab_slow
continue

# 查看决策
p tlab.free()
p tlab.refill_waste_limit()
# free > limit → 保留 TLAB，返回 NULL
# free <= limit → 废弃，申请新 TLAB
```

### 17.3 观察 G1 堆分配

```gdb
break G1CollectedHeap::attempt_allocation
continue

# 查看 mutator alloc region
p _allocator->_mutator_alloc_region._alloc_region
p _allocator->_mutator_alloc_region._alloc_region->top()
p _allocator->_mutator_alloc_region._alloc_region->end()
```

### 17.4 观察对象初始化

```gdb
break ObjAllocator::initialize
continue

# 分配完成后查看内存
p/x mem
x/2gx mem
# 应看到: [0x0000000000000001] [encoded_klass_ptr]
# 即 mark word = 0x1 (prototype)
```

---

## 18. 关键 JVM 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-XX:+UseTLAB` | true | 启用 TLAB |
| `-XX:TLABSize=N` | 0（自动） | 初始 TLAB 大小（0 = 自动计算） |
| `-XX:+ResizeTLAB` | true | GC 后自动调整 TLAB 大小 |
| `-XX:TLABRefillWasteFraction=N` | 64 | 浪费阈值 = desired_size / N |
| `-XX:TLABWasteIncrement=N` | 4 | slow alloc 时阈值增量 (HeapWords) |
| `-XX:TLABWasteTargetPercent=N` | 1 | 目标浪费百分比 |
| `-XX:MinTLABSize=N` | 2048 | TLAB 最小大小（字节） |
| `-XX:+ZeroTLAB` | false | 分配新 TLAB 时清零（默认延迟到使用时） |
| `-Xlog:gc+tlab=trace` | — | 打印 TLAB 统计 |
| `-Xlog:gc+alloc=trace` | — | 打印分配追踪 |
| `-Xlog:gc+alloc+humongous=debug` | — | 打印 humongous 分配 |

---

## 19. 总结

| 阶段 | 做了什么 | 关键源码 |
|------|---------|---------|
| 字节码触发 | `new` → 解释器 `TemplateTable::_new()` | `templateTable_x86.cpp:3991` |
| 快速路径 | TLAB bump-the-pointer (汇编) | `tlab_allocate` macro |
| 慢速路径 | C++ `InterpreterRuntime::_new()` | `interpreterRuntime.cpp:217` |
| 实例分配 | `InstanceKlass::allocate_instance()` | `instanceKlass.cpp:1240` |
| 内存框架 | `MemAllocator::allocate()` | `memAllocator.cpp:373` |
| TLAB 分配 | `ThreadLocalAllocBuffer::allocate()` | `threadLocalAllocBuffer.inline.hpp:34` |
| TLAB refill | 决策 + 申请新 TLAB + 安装 | `memAllocator.cpp:297` |
| G1 快速 | `G1Allocator` → `MutatorAllocRegion` | `g1Allocator.inline.hpp:44` |
| Region 内 | bump-the-pointer (单线程/CAS) | `heapRegion.inline.hpp:38` |
| G1 慢速 | 加锁 → 新 region / 触发 GC | `g1CollectedHeap.cpp:418` |
| Humongous | 连续 regions → Old gen | `g1CollectedHeap.cpp:847` |
| 初始化 | 清零 → set mark(0x1) → release set klass | `memAllocator.cpp:412` |
| OOM | `Java heap space` / `GC overhead limit exceeded` | `memAllocator.cpp:115` |

---

## 附：核心源码文件索引

| 文件 | 内容 |
|------|------|
| `cpu/x86/templateTable_x86.cpp` | 解释器 `new` 字节码汇编快速路径 |
| `interpreter/interpreterRuntime.cpp` | `InterpreterRuntime::_new()` 慢速路径 |
| `oops/instanceKlass.cpp` | `allocate_instance()` 入口 |
| `gc/shared/memAllocator.hpp/cpp` | `MemAllocator` 框架、ObjAllocator 初始化 |
| `gc/shared/threadLocalAllocBuffer.hpp` | TLAB 结构定义 |
| `gc/shared/threadLocalAllocBuffer.inline.hpp` | TLAB `allocate()`、`compute_size()` |
| `gc/shared/threadLocalAllocBuffer.cpp` | TLAB `resize()`、`fill()`、`make_parsable()` |
| `gc/shared/collectedHeap.cpp` | `obj_allocate()` 入口 |
| `gc/g1/g1CollectedHeap.cpp` | G1 `allocate_new_tlab`、`attempt_allocation*`、humongous |
| `gc/g1/g1Allocator.inline.hpp` | `G1Allocator::attempt_allocation()` |
| `gc/g1/g1AllocRegion.inline.hpp` | `G1AllocRegion` bump/CAS 分配 |
| `gc/g1/heapRegion.inline.hpp` | `allocate_impl()` / `par_allocate_impl()` 最底层 |
