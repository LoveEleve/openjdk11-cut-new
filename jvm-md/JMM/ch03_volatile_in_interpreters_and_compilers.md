# JMM 源码分析（三）：volatile 字段在解释器 & 编译器中的完整实现对比

> **核心问题**：同一个 `volatile int x = 42;` 的写入操作，在字节码解释器、模板解释器、C1 编译器、C2 编译器中分别是怎么处理的？它们在内存屏障策略上有什么异同？

---

## 一、四种执行引擎的对比总结

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                   volatile int 写操作的四种实现对比                                │
├─────────────┬────────────────────────────────────────────────────────────────────┤
│ 执行引擎     │ 实现方式                                                          │
├─────────────┼────────────────────────────────────────────────────────────────────┤
│ C++ 解释器   │ release_int_field_put()  → release_store(addr, val)               │
│ (Xint)      │ + OrderAccess::storeload()  → lock addl $0, 0(%rsp)               │
├─────────────┼────────────────────────────────────────────────────────────────────┤
│ 模板解释器   │ access_store_at(T_INT, IN_HEAP, field, rax, ...)                  │
│ (-Xint)     │ + volatile_barrier(StoreLoad|StoreStore) → lock addl              │
├─────────────┼────────────────────────────────────────────────────────────────────┤
│ C1 编译器   │ MO_SEQ_CST → BarrierSetC1::store_at_resolved()                    │
│             │ membar_release + volatile_field_store + membar()                   │
│             │ → [编译器屏障] + mov + lock addl                                   │
├─────────────┼────────────────────────────────────────────────────────────────────┤
│ C2 编译器   │ MO_SEQ_CST → C2AccessFence::MemBarRelease + Store + MemBarVolatile│
│             │ → [编译器屏障] + mov + lock addl                                   │
│             │ 【但 C2 可能优化掉冗余的 MemBar 节点】                               │
└─────────────┴────────────────────────────────────────────────────────────────────┘

实际在 x86 上最终生成的汇编（所有引擎最终殊途同归）：

  volatile 写：
    mov [addr], value              ; 普通写（release 屏障在 x86 上免费）
    lock; addl $0, 0(%rsp)         ; StoreLoad 屏障

  volatile 读：
    mov value, [addr]              ; 普通读
    [编译器屏障]                    ; acquire 屏障在 x86 上免费
```

---

## 二、C++ 字节码解释器（bytecodeInterpreter.cpp）

> **源码位置**：`src/hotspot/share/interpreter/bytecodeInterpreter.cpp`
> **使用条件**：`-Xint` 模式下，如果 HotSpot 编译时启用了 C++ 解释器

### 2.1 volatile 读（getfield/getstatic）

```cpp
// line 1974
if (cache->is_volatile()) {
  // IRIW 处理：仅在非 multi-copy-atomic CPU 上需要
  if (support_IRIW_for_not_multiple_copy_atomic_cpu) {
    OrderAccess::fence();   // x86 上 = false，跳过
  }
  // 使用 acquire 语义的字段读
  if (tos_type == atos) {
    SET_STACK_OBJECT(obj->obj_field_acquire(field_offset), -1);
  } else if (tos_type == itos) {
    SET_STACK_INT(obj->int_field_acquire(field_offset), -1);
  } else if (tos_type == ltos) {
    SET_STACK_LONG(obj->long_field_acquire(field_offset), 0);
  }
  // ... 其他类型
}
```

**执行链路**：
```
obj->int_field_acquire(field_offset)
  → HeapAccess<MO_ACQUIRE>::load_at(as_oop(), offset)
    → RawAccessBarrier::load_internal<MO_ACQUIRE>()
      → OrderAccess::load_acquire(addr)
        → [x86] mov + compiler_barrier()
```

### 2.2 volatile 写（putfield/putstatic）

```cpp
// line 2088
if (cache->is_volatile()) {
  // 使用 release 语义的字段写
  if (tos_type == itos) {
    obj->release_int_field_put(field_offset, STACK_INT(-1));
  } else if (tos_type == atos) {
    obj->release_obj_field_put(field_offset, STACK_OBJECT(-1));
  }
  // ... 其他类型

  // 关键：写后必须有 StoreLoad 屏障！
  OrderAccess::storeload();
}
```

**为什么是 release_store + storeload 而不是 release_store_fence？**

这里的 C++ 解释器选择了"分步实现"：
- `release_int_field_put` → `OrderAccess::release_store()`：保证前面的写不下沉（x86 免费）
- `OrderAccess::storeload()`：保证这次写对后续读可见 → `lock addl $0, 0(%rsp)`

效果等同于 `release_store_fence()`（= `xchg`），但分成两步更清晰。

### 2.3 volatile 读写的不对称性

```
volatile 读：  acquire（LoadLoad + LoadStore）
               x86 → 编译器屏障（免费！）

volatile 写：  release（LoadStore + StoreStore）+ StoreLoad
               x86 → 编译器屏障（免费）+ lock addl（~20 cycles）
```

**为什么写比读贵？** 因为 x86 TSO 模型中，Store Buffer 是写操作延迟的根源。只有 StoreLoad 需要刷新 Store Buffer，这是唯一需要硬件指令的屏障。

---

## 三、模板解释器（templateTable_x86.cpp）

> **源码位置**：`src/hotspot/cpu/x86/templateTable_x86.cpp`
> **使用条件**：默认解释器（非 -Xcomp 模式下的冷代码）

模板解释器与 C++ 解释器的本质区别：**直接生成汇编代码**，跳过了 C++ 的函数调用开销。

### 3.1 putfield_or_static 中的 volatile 处理

```cpp
void TemplateTable::putfield_or_static(int byte_no, bool is_static, RewriteControl rc) {
  // 1. 从 ConstantPoolCacheEntry 中提取 volatile 标志位
  __ movl(rdx, flags);
  __ shrl(rdx, ConstantPoolCacheEntry::is_volatile_shift);
  __ andl(rdx, 0x1);

  // 2. 根据字段类型执行存储（此处省略了类型分支，参见原始代码）
  // ... access_store_at(T_INT, IN_HEAP, field, rax, noreg, noreg) ...

  // 3. volatile 写后的屏障
  Label notVolatile, Done;

  // ... 在 Done 标签之前检查 volatile ...
  __ bind(Done);

  // 检查 volatile 标记
  __ testl(rdx, rdx);
  __ jcc(Assembler::zero, notVolatile);

  // StoreLoad + StoreStore 屏障
  volatile_barrier(Assembler::Membar_mask_bits(
    Assembler::StoreLoad | Assembler::StoreStore));

  __ bind(notVolatile);
}
```

**生成的伪汇编代码**：
```asm
; 1. 提取 volatile 标志
mov    rdx, [rcx + rbx*8 + flags_offset]
shr    rdx, is_volatile_shift
and    rdx, 1

; 2. 执行存储
mov    [obj + off], eax        ; 实际字段写入

; 3. volatile 屏障
test   rdx, rdx
je     notVolatile
lock; addl $0, 0(%rsp)         ; StoreLoad 屏障
notVolatile:
```

### 3.2 fast_storefield 的 volatile 处理

当 putfield 被"重写"为 fast 版本后，volatile 处理更简洁：

```cpp
void TemplateTable::fast_storefield(TosState state) {
  // ... 执行存储（根据 state 类型分支到不同的 access_store_at） ...

  // volatile 屏障
  __ testl(rdx, rdx);
  __ jcc(Assembler::zero, notVolatile);
  volatile_barrier(Assembler::Membar_mask_bits(
    Assembler::StoreLoad | Assembler::StoreStore));
  __ bind(notVolatile);
}
```

### 3.3 volatile_barrier 的实现

```cpp
void TemplateTable::volatile_barrier(Assembler::Membar_mask_bits order_constraint) {
  if (!os::is_MP()) return;    // 单核无需屏障
  __ membar(order_constraint);  // 生成 lock addl $0, 0(%rsp)
}
```

`os::is_MP()` 的检查确保在单处理器系统上不插入不必要的屏障。在多核系统上，`membar()` 生成 `lock addl $0, 0(%rsp)`。

### 3.4 32 位平台的特殊处理：volatile long

在 32 位 x86 上，volatile long 的写入需要特殊处理，因为无法用一条 32 位指令原子地写 8 字节：

```cpp
#else  // !_LP64
{
  Label notVolatileLong;
  __ testl(rdx, rdx);
  __ jcc(Assembler::zero, notVolatileLong);

  // volatile long 写：先写入，再加屏障
  __ pop(ltos);
  if (!is_static) pop_and_check_object(obj);

  __ access_store_at(T_LONG, IN_HEAP | MO_RELAXED, field, noreg, noreg, noreg);
  volatile_barrier(Assembler::Membar_mask_bits(
    Assembler::StoreLoad | Assembler::StoreStore));
  __ jmp(notVolatile);

  __ bind(notVolatileLong);
  // 非 volatile long 走普通路径
}
#endif // _LP64
```

注意这里用了 `MO_RELAXED`，因为 StoreLoad 屏障已经在后面显式插入了。

---

## 四、C1 编译器（轻量级优化编译器）

> **源码位置**：
> - `src/hotspot/share/c1/c1_LIRGenerator.cpp`（IR 生成）
> - `src/hotspot/share/gc/shared/c1/barrierSetC1.cpp`（屏障生成）

### 4.1 volatile 标记的传递

```cpp
// c1_LIRGenerator.cpp
void LIRGenerator::do_StoreField(StoreField* x) {
  bool is_volatile = x->field()->is_volatile();
  // ...
  DecoratorSet decorators = IN_HEAP;
  if (is_volatile) {
    decorators |= MO_SEQ_CST;   // 关键：标记为顺序一致性
  }
  access_store_at(decorators, field_type, object, ...);
}

void LIRGenerator::do_LoadField(LoadField* x) {
  bool is_volatile = x->field()->is_volatile();
  DecoratorSet decorators = IN_HEAP;
  if (is_volatile) {
    decorators |= MO_SEQ_CST;
  }
  access_load_at(decorators, field_type, object, ...);
}
```

### 4.2 C1 volatile store 的屏障生成

```cpp
// barrierSetC1.cpp
void BarrierSetC1::store_at_resolved(LIRAccess& access, LIR_Opr value) {
  bool is_volatile = (((decorators & MO_SEQ_CST) != 0) || AlwaysAtomicAccesses) && os::is_MP();

  // 步骤 1：写前 release 屏障
  if (is_volatile && os::is_MP()) {
    __ membar_release();      // x86: compiler_barrier()（免费）
  }

  // 步骤 2：执行字段写入
  if (is_volatile && !needs_patching) {
    gen->volatile_field_store(value, access.resolved_addr()->as_address_ptr(), ...);
  } else {
    __ store(value, ...);
  }

  // 步骤 3：写后 StoreLoad 屏障
  if (is_volatile && !support_IRIW_for_not_multiple_copy_atomic_cpu) {
    __ membar();              // x86: lock addl $0, 0(%rsp)
  }
}
```

**C1 volatile store 生成的 LIR 序列**：
```
[membar_release]                  → x86: 无（编译器屏障）
[volatile_field_store] value, addr → x86: mov [addr], value
[membar]                          → x86: lock addl $0, 0(%rsp)
```

### 4.3 C1 volatile load 的屏障生成

```cpp
void BarrierSetC1::load_at_resolved(LIRAccess& access, LIR_Opr result) {
  bool is_volatile = ...;

  // 步骤 1：读前屏障（仅 IRIW CPU）
  if (support_IRIW_for_not_multiple_copy_atomic_cpu && is_volatile) {
    __ membar();    // x86 上跳过（support_IRIW = false）
  }

  // 步骤 2：执行字段读取
  if (is_volatile && !needs_patching) {
    gen->volatile_field_load(access.resolved_addr()->as_address_ptr(), result, ...);
  } else {
    __ load(access.resolved_addr()->as_address_ptr(), result, ...);
  }

  // 步骤 3：读后 acquire 屏障
  if (is_volatile && os::is_MP()) {
    __ membar_acquire();    // x86: compiler_barrier()（免费）
  }
}
```

**C1 volatile load 生成的 LIR 序列**：
```
[volatile_field_load] addr, result  → x86: mov result, [addr]
[membar_acquire]                    → x86: 无（编译器屏障）
```

### 4.4 C1 为什么区分 volatile_field_store 和普通 store？

`volatile_field_store` 和 `volatile_field_load` 使用特殊的 LIR 操作码，原因是：
1. **寄存器分配约束**：volatile 操作可能需要特定寄存器（如 64 位原子操作在 32 位平台上需要 FPU 寄存器）
2. **对齐要求**：volatile 访问必须保证原子性，可能需要对齐检查
3. **消除优化**：标记为 volatile 可以阻止后续优化 pass 移动这些操作

---

## 五、C2 编译器（激进优化编译器）

> **源码位置**：`src/hotspot/share/gc/shared/c2/barrierSetC2.cpp`

### 5.1 C2AccessFence：RAII 式屏障管理

C2 使用一个精巧的 RAII 类 `C2AccessFence` 来管理 volatile 屏障的插入：

```cpp
class C2AccessFence {
  C2Access& _access;
  Node* _leading_membar;

  C2AccessFence(C2Access& access) : _access(access), _leading_membar(NULL) {
    bool is_volatile = (decorators & MO_SEQ_CST) != 0;

    if (is_write) {
      // volatile 写前：MemBarRelease
      if (is_volatile || is_release) {
        _leading_membar = kit->insert_mem_bar(Op_MemBarRelease);
      }
    } else if (is_read) {
      // volatile 读前：仅 IRIW CPU 需要 MemBarVolatile
      if (is_volatile && support_IRIW_for_not_multiple_copy_atomic_cpu) {
        _leading_membar = kit->insert_mem_bar(Op_MemBarVolatile);
      }
    }
  }

  ~C2AccessFence() {
    if (is_write) {
      // volatile 写后：MemBarVolatile（x86）
      if (is_volatile && !support_IRIW_for_not_multiple_copy_atomic_cpu) {
        Node* mb = kit->insert_mem_bar(Op_MemBarVolatile, n);
        // 建立 leading/trailing 配对关系
        MemBarNode::set_store_pair(_leading_membar->as_MemBar(), mb->as_MemBar());
      }
    } else if (is_read) {
      // volatile 读后：MemBarAcquire
      if (is_volatile || is_acquire) {
        Node* mb = kit->insert_mem_bar(Op_MemBarAcquire, n);
        mb->as_MemBar()->set_trailing_load();
      }
    }
  }
};
```

### 5.2 C2 volatile 写的 IR 图

```
构造函数阶段（写前）：
  MemBarRelease ────────── 阻止前面的操作下沉
       │
       ▼
  MemBarCPUOrder ────────── CPU 级排序（如果需要）
       │
       ▼
  Store [addr] = value ─── 实际写入

析构函数阶段（写后）：
       │
       ▼
  MemBarCPUOrder ────────── CPU 级排序
       │
       ▼
  MemBarVolatile ─────────── StoreLoad 屏障（x86 = lock addl）
```

**MemBarRelease 和 MemBarVolatile 的配对关系**：

C2 通过 `set_store_pair()` 将前后两个 MemBar 配对，这告诉优化器：
- 这两个 MemBar 是同一个 volatile 写的"围栏"
- 优化时不能把这对 MemBar 之间的 Store 移出去
- 但可以将 MemBar 对内的非 volatile 操作移出去

### 5.3 C2 volatile 读的 IR 图

```
（读前 IRIW 屏障 — x86 上省略）

  Load value = [addr] ─── 实际读取
       │
       ▼
  MemBarAcquire ────────── acquire 屏障（x86 = 编译器屏障）
  [trailing_load = true]
```

`set_trailing_load()` 标记告诉 C2 优化器：这个 MemBarAcquire 是紧跟 volatile load 的，可以在某些情况下被优化掉（如果后续没有需要保护的操作）。

### 5.4 C2 的 MemBar 优化

C2 是最激进的编译器，它会尝试优化冗余的 MemBar 节点：

**场景 1：连续的 volatile 写**
```java
volatile int x, y;
x = 1;
y = 2;
```

**优化前的 IR**：
```
MemBarRelease
Store x = 1
MemBarVolatile    ← 可以优化掉！
MemBarRelease     ← 可以优化掉！
Store y = 2
MemBarVolatile
```

**优化后的 IR**：
```
MemBarRelease
Store x = 1
Store y = 2
MemBarVolatile
```

C2 可以合并相邻的 volatile 写的屏障，因为中间没有 volatile 读（不需要 StoreLoad 保护中间状态）。

**场景 2：volatile 写后紧跟 volatile 读**
```java
volatile int x, y;
x = 1;       // 写后有 MemBarVolatile
int a = y;   // 读前无需额外屏障（MemBarVolatile 已经保证了）
```

MemBarVolatile（= StoreLoad）已经比 MemBarAcquire（= LoadLoad + LoadStore）更强，所以 C2 可以省掉 volatile 读前的任何额外屏障。

---

## 六、四种引擎在 x86 上的指令对比

### 6.1 volatile int 写

| 引擎 | 生成的指令 | 说明 |
|------|-----------|------|
| C++ 解释器 | `release_store(addr,val)` → `mov` <br> `storeload()` → `lock addl $0,0(%rsp)` | 分步实现 |
| 模板解释器 | `mov [addr], eax` <br> `lock addl $0,0(%rsp)` | 直接汇编 |
| C1 | `mov [addr], eax` <br> `lock addl $0,0(%rsp)` | LIR 生成 |
| C2 | `mov [addr], eax` <br> `lock addl $0,0(%rsp)` | 可能优化合并 |

### 6.2 volatile int 读

| 引擎 | 生成的指令 | 说明 |
|------|-----------|------|
| C++ 解释器 | `mov eax, [addr]` + 编译器屏障 | load_acquire |
| 模板解释器 | `mov eax, [addr]` | 无额外指令 |
| C1 | `mov eax, [addr]` + 编译器屏障 | membar_acquire |
| C2 | `mov eax, [addr]` | MemBarAcquire = nop on x86 |

### 6.3 CAS (compareAndSet)

所有引擎最终都生成：
```asm
lock cmpxchgl %ecx, [addr]
```

差异在于 C2 可能将 CAS 与条件分支融合，减少一次跳转。

---

## 七、关键差异总结

```
┌──────────────────────────────────────────────────────────────────────────┐
│                    四种执行引擎的关键差异                                  │
├─────────────┬──────────────────────────────────────────────────────────┤
│ 差异维度     │ 说明                                                    │
├─────────────┼──────────────────────────────────────────────────────────┤
│ volatile 检测│ C++ 解释器：cache->is_volatile() 运行时检查              │
│             │ 模板解释器：运行时从 ConstantPoolCacheEntry 提取标志位     │
│             │ C1：编译时 x->field()->is_volatile() 决定是否插入屏障    │
│             │ C2：编译时在 IR 图中插入 MemBar 节点                     │
├─────────────┼──────────────────────────────────────────────────────────┤
│ 屏障策略     │ C++ 解释器：release_store + storeload（保守但正确）      │
│             │ 模板解释器：store + volatile_barrier（直接高效）          │
│             │ C1：membar_release + store + membar（标准三段式）         │
│             │ C2：MemBarRelease + Store + MemBarVolatile（可优化）      │
├─────────────┼──────────────────────────────────────────────────────────┤
│ 优化能力     │ C++ 解释器：无优化                                       │
│             │ 模板解释器：bytecode 重写（fast_Xputfield）               │
│             │ C1：少量优化（值编号、内联）                               │
│             │ C2：激进优化（MemBar 合并、消除冗余屏障）                   │
├─────────────┼──────────────────────────────────────────────────────────┤
│ IRIW 处理   │ 所有引擎都检查 support_IRIW_for_not_multiple_copy_atomic │
│             │ x86 上该值 = false → 所有 IRIW 相关屏障被跳过             │
│             │ ARM/POWER 上 = true → 需要额外的 fence()                 │
├─────────────┼──────────────────────────────────────────────────────────┤
│ 最终 x86 指令│ 所有引擎最终殊途同归：                                    │
│             │   写 → mov + lock addl（或 xchg）                        │
│             │   读 → mov（+ 编译器屏障）                                │
└─────────────┴──────────────────────────────────────────────────────────┘
```

---

## 八、面试话术建议

### Q：volatile 在解释器和编译器中的实现有什么区别？

> 虽然四种执行引擎（C++ 解释器、模板解释器、C1、C2）的代码路径完全不同，但在 x86 上最终生成的指令是一样的：volatile 写是 `mov + lock addl`，volatile 读是普通 `mov`。
>
> 核心区别在于 **volatile 检测时机** 和 **屏障策略的灵活性**：
> - 解释器在运行时从 `ConstantPoolCacheEntry` 提取 `is_volatile` 标志位
> - C1/C2 在编译时就知道字段是否 volatile，可以在 IR 中直接插入合适的屏障节点
> - C2 最激进，它的 `MemBarRelease` + `MemBarVolatile` 配对可以被优化器合并——比如两个连续的 volatile 写可以共享一个 StoreLoad 屏障
>
> 另一个有趣的点是 IRIW 处理：所有引擎都检查 `support_IRIW_for_not_multiple_copy_atomic_cpu` 变量。在 x86 上它是 false，所以所有 IRIW 相关的屏障被编译时常量折叠掉了。但在 ARM/POWER 上它是 true，volatile 读前需要额外的 `fence()`。

---

## 九、关键源码文件索引

| 文件 | 层次 | 作用 |
|------|------|------|
| `share/interpreter/bytecodeInterpreter.cpp:1974,2088` | C++ 解释器 | volatile 读写处理 |
| `cpu/x86/templateTable_x86.cpp:3107,3390` | 模板解释器 | putfield/fast_storefield 的 volatile 屏障 |
| `cpu/x86/templateTable_x86.cpp:2715` | 模板解释器 | volatile_barrier() 实现 |
| `share/c1/c1_LIRGenerator.cpp:1493,1702` | C1 | StoreField/LoadField 的 volatile 标记 |
| `share/gc/shared/c1/barrierSetC1.cpp:150,175` | C1 | volatile 屏障生成 |
| `share/gc/shared/c2/barrierSetC2.cpp:140` | C2 | C2AccessFence 屏障管理 |
| `share/utilities/globalDefinitions.hpp:542` | 全局 | support_IRIW 常量定义 |
