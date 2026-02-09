# G1 屏障汇编实现详解

> 承接 [C.3-G1BarrierSet.md](../Universe/C.3-G1BarrierSet.md)，本文深入分析 G1 写屏障的 **x86-64 汇编实现**

---

## 1. 概述

### 1.1 G1 屏障汇编的位置

```
src/hotspot/cpu/x86/gc/g1/g1BarrierSetAssembler_x86.cpp
```

G1 的写屏障不是单独的 stub，而是在以下场景**内联生成**：

| 场景 | 生成位置 | 调用函数 |
|------|---------|---------|
| 解释器 | 字节码模板 (`putfield`, `aastore`) | `oop_store_at()` |
| C1 编译器 | LIR 生成 | `gen_pre_barrier_stub()`, `gen_post_barrier_stub()` |
| C2 编译器 | Ideal Graph | `G1BarrierSetC2::post_barrier()` |

### 1.2 两种写屏障的汇编函数

```cpp
// g1BarrierSetAssembler_x86.cpp

// 1. SATB 写前屏障 - 记录旧值，防止并发标记漏标
void g1_write_barrier_pre(MacroAssembler* masm, ...);

// 2. CardTable 写后屏障 - 记录脏卡，用于 RSet 更新
void g1_write_barrier_post(MacroAssembler* masm, ...);

// 3. 完整的 oop 存储操作（调用上面两个）
void oop_store_at(MacroAssembler* masm, ...);
```

---

## 2. 核心数据结构

### 2.1 G1ThreadLocalData 布局

```cpp
// g1ThreadLocalData.hpp:34
class G1ThreadLocalData {
private:
    SATBMarkQueue  _satb_mark_queue;   // SATB 队列
    DirtyCardQueue _dirty_card_queue;  // 脏卡队列
};
```

**在 Thread 中的位置**：

```
Thread
├── ... (其他字段)
├── _gc_data[512 bytes]  ← G1ThreadLocalData 存储在这里
│   ├── _satb_mark_queue  (SATBMarkQueue)
│   │   ├── _qset          (8 bytes)  - 指向全局 SATBMarkQueueSet
│   │   ├── _active        (1 byte)   - 是否激活
│   │   ├── _permanent     (1 byte)   - 是否永久
│   │   ├── [padding]      (6 bytes)
│   │   ├── _index         (8 bytes)  - 当前写入位置（从高到低）
│   │   ├── _capacity_in_bytes (8 bytes)
│   │   ├── _buf           (8 bytes)  - 缓冲区指针
│   │   └── _lock          (8 bytes)
│   └── _dirty_card_queue  (DirtyCardQueue)
│       ├── _qset          (8 bytes)
│       ├── _active        (1 byte)
│       ├── ...
│       ├── _index         (8 bytes)
│       ├── _buf           (8 bytes)
│       └── ...
```

### 2.2 PtrQueue 内存布局（父类）

```cpp
// ptrQueue.hpp:38
class PtrQueue {
    PtrQueueSet* const _qset;     // +0:  指向全局队列集
    bool _active;                 // +8:  是否激活
    const bool _permanent;        // +9:  是否永久
    // padding                    // +10: 6 bytes 对齐
    size_t _index;                // +16: 当前索引（字节偏移）
    size_t _capacity_in_bytes;    // +24: 容量（字节）
    void** _buf;                  // +32: 缓冲区指针
    Mutex* _lock;                 // +40: 锁
};
// 总大小: 48 bytes
```

### 2.3 汇编代码访问的关键偏移量

```cpp
// 这些是从 r15_thread (当前线程) 开始的偏移量

// SATB 队列偏移
G1ThreadLocalData::satb_mark_queue_active_offset()  // _gc_data + 8
G1ThreadLocalData::satb_mark_queue_index_offset()   // _gc_data + 16
G1ThreadLocalData::satb_mark_queue_buffer_offset()  // _gc_data + 32

// 脏卡队列偏移
G1ThreadLocalData::dirty_card_queue_index_offset()  // _gc_data + 48 + 16
G1ThreadLocalData::dirty_card_queue_buffer_offset() // _gc_data + 48 + 32
```

**偏移量计算**：

```
Thread::gc_data_offset() = byte_offset_of(Thread, _gc_data)
satb_mark_queue_offset() = gc_data_offset() + byte_offset_of(G1ThreadLocalData, _satb_mark_queue)
satb_mark_queue_active_offset() = satb_mark_queue_offset() + byte_offset_of(PtrQueue, _active)
```

---

## 3. g1_write_barrier_pre() - SATB 写前屏障

### 3.1 函数签名

```cpp:142:148:src/hotspot/cpu/x86/gc/g1/g1BarrierSetAssembler_x86.cpp
void G1BarrierSetAssembler::g1_write_barrier_pre(MacroAssembler* masm,
                                                 Register obj,
                                                 Register pre_val,
                                                 Register thread,
                                                 Register tmp,
                                                 bool tosca_live,
                                                 bool expand_call)
```

**参数说明**：

| 参数 | 含义 |
|------|------|
| `obj` | 被修改对象的地址（可为 noreg，表示 pre_val 已经有旧值） |
| `pre_val` | 存放旧值的寄存器 |
| `thread` | 线程寄存器（x86-64 必须是 r15_thread） |
| `tmp` | 临时寄存器 |
| `tosca_live` | 栈顶缓存是否有效（是否需要保护 rax） |
| `expand_call` | 是否展开 VM 调用（跳过 _last_sp 检查） |

### 3.2 汇编流程图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      g1_write_barrier_pre 汇编流程                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ① 检查 SATB 是否激活                                                        │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  cmpb [r15 + satb_active_offset], 0                                    │ │
│  │  je done                           ; 未激活则跳过                       │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              │                                               │
│                              ↓ (激活)                                        │
│  ② 加载旧值（如果需要）                                                      │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  if (obj != noreg) {                                                   │ │
│  │      movq pre_val, [obj]           ; 加载旧值                          │ │
│  │  }                                                                      │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              │                                               │
│                              ↓                                               │
│  ③ 检查旧值是否为 NULL                                                       │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  cmpq pre_val, 0                                                       │ │
│  │  je done                           ; NULL 则跳过                        │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              │                                               │
│                              ↓ (非 NULL)                                     │
│  ④ 快速路径：尝试入队到本地缓冲区                                             │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  movq tmp, [r15 + satb_index_offset]                                   │ │
│  │  cmpq tmp, 0                                                           │ │
│  │  je runtime                        ; index == 0，缓冲区满               │ │
│  │                                                                         │ │
│  │  ; 有空间，直接入队                                                     │ │
│  │  subq tmp, 8                       ; index -= wordSize                  │ │
│  │  movq [r15 + satb_index_offset], tmp                                   │ │
│  │  addq tmp, [r15 + satb_buffer_offset]  ; tmp = buf + index              │ │
│  │  movq [tmp], pre_val               ; 写入旧值                           │ │
│  │  jmp done                                                               │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              │                                               │
│                              ↓ (缓冲区满)                                    │
│  ⑤ 慢速路径：调用运行时函数                                                  │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  runtime:                                                               │ │
│  │      ; 保存寄存器                                                       │ │
│  │      push rax (if tosca_live)                                          │ │
│  │      push obj (if obj != noreg && obj != rax)                          │ │
│  │      push pre_val (if pre_val != rax)                                  │ │
│  │                                                                         │ │
│  │      ; 调用 C++ 运行时                                                  │ │
│  │      mov c_rarg0, pre_val          ; 参数1: 旧值                        │ │
│  │      mov c_rarg1, r15_thread       ; 参数2: 线程                        │ │
│  │      call G1BarrierSetRuntime::write_ref_field_pre_entry               │ │
│  │                                                                         │ │
│  │      ; 恢复寄存器                                                       │ │
│  │      pop pre_val                                                        │ │
│  │      pop obj                                                            │ │
│  │      pop rax                                                            │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              │                                               │
│                              ↓                                               │
│  done:                                                                       │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.3 关键汇编代码分析

#### 3.3.1 检查 SATB 是否激活

```cpp:167:178:src/hotspot/cpu/x86/gc/g1/g1BarrierSetAssembler_x86.cpp
  Address in_progress(thread, in_bytes(G1ThreadLocalData::satb_mark_queue_active_offset()));

  // Is marking active?
  if (in_bytes(SATBMarkQueue::byte_width_of_active()) == 4) {
    __ cmpl(in_progress, 0);
  } else {
    assert(in_bytes(SATBMarkQueue::byte_width_of_active()) == 1, "Assumption");
    __ cmpb(in_progress, 0);
  }
  __ jcc(Assembler::equal, done);
```

**生成的汇编**：
```asm
cmpb [r15 + offset], 0    ; _active 是 bool，1 字节比较
je done
```

**何时 SATB 激活**：
- 并发标记开始时，`SATBMarkQueueSet::set_active_all_threads(true)` 被调用
- 并发标记结束时，`SATBMarkQueueSet::set_active_all_threads(false)` 被调用
- 只有在并发标记期间，SATB 屏障才真正工作

#### 3.3.2 加载旧值

```cpp:180:183:src/hotspot/cpu/x86/gc/g1/g1BarrierSetAssembler_x86.cpp
  // Do we need to load the previous value?
  if (obj != noreg) {
    __ load_heap_oop(pre_val, Address(obj, 0), noreg, noreg, AS_RAW);
  }
```

**两种场景**：
1. `obj != noreg`：需要从对象中加载旧值
2. `obj == noreg`：调用者已经将旧值放入 `pre_val`

#### 3.3.3 快速路径：本地缓冲区入队

```cpp:189:203:src/hotspot/cpu/x86/gc/g1/g1BarrierSetAssembler_x86.cpp
  // Can we store original value in the thread's buffer?
  // Is index == 0?
  // (The index field is typed as size_t.)

  __ movptr(tmp, index);                   // tmp := *index_adr
  __ cmpptr(tmp, 0);                       // tmp == 0?
  __ jcc(Assembler::equal, runtime);       // If yes, goto runtime

  __ subptr(tmp, wordSize);                // tmp := tmp - wordSize
  __ movptr(index, tmp);                   // *index_adr := tmp
  __ addptr(tmp, buffer);                  // tmp := tmp + *buffer_adr

  // Record the previous value
  __ movptr(Address(tmp, 0), pre_val);
  __ jmp(done);
```

**SATB 缓冲区结构**：

```
_buf 指向缓冲区开始
     ↓
┌────────────────────────────────────────────────────────────────┐
│ slot[0] │ slot[1] │ ... │ slot[capacity-2] │ slot[capacity-1] │
└────────────────────────────────────────────────────────────────┘
     ↑                                              ↑
 buf+0                                        _index 指向这里
                                              （从高地址向低地址增长）

入队操作：
1. index -= 8          ; 向低地址移动一个 slot
2. buf[index] = pre_val ; 写入旧值
```

#### 3.3.4 慢速路径：运行时调用

```cpp:205:245:src/hotspot/cpu/x86/gc/g1/g1BarrierSetAssembler_x86.cpp
  __ bind(runtime);
  // save the live input values
  if(tosca_live) __ push(rax);

  if (obj != noreg && obj != rax)
    __ push(obj);

  if (pre_val != rax)
    __ push(pre_val);

  // 调用 C++ 运行时
  if (expand_call) {
    // 直接展开调用，跳过 _last_sp 检查
    if (c_rarg1 != thread) {
      __ mov(c_rarg1, thread);
    }
    if (c_rarg0 != pre_val) {
      __ mov(c_rarg0, pre_val);
    }
    __ MacroAssembler::call_VM_leaf_base(
        CAST_FROM_FN_PTR(address, G1BarrierSetRuntime::write_ref_field_pre_entry), 2);
  } else {
    __ call_VM_leaf(
        CAST_FROM_FN_PTR(address, G1BarrierSetRuntime::write_ref_field_pre_entry), 
        pre_val, thread);
  }
```

**慢速路径处理**（`write_ref_field_pre_entry`）：

```cpp:48:56:src/hotspot/share/gc/g1/g1BarrierSetRuntime.cpp
JRT_LEAF(void, G1BarrierSetRuntime::write_ref_field_pre_entry(oopDesc* orig, JavaThread *thread))
  if (orig == NULL) {
    assert(false, "should be optimized out");
    return;
  }
  assert(oopDesc::is_oop(orig, true /* ignore mark word */), "Error");
  // store the original value that was in the field reference
  G1ThreadLocalData::satb_mark_queue(thread).enqueue(orig);
JRT_END
```

---

## 4. g1_write_barrier_post() - 写后屏障

### 4.1 函数签名

```cpp:261:266:src/hotspot/cpu/x86/gc/g1/g1BarrierSetAssembler_x86.cpp
void G1BarrierSetAssembler::g1_write_barrier_post(MacroAssembler* masm,
                                                  Register store_addr,
                                                  Register new_val,
                                                  Register thread,
                                                  Register tmp,
                                                  Register tmp2)
```

**参数说明**：

| 参数 | 含义 |
|------|------|
| `store_addr` | 存储位置地址（字段地址） |
| `new_val` | 新值（oop） |
| `thread` | 线程寄存器 |
| `tmp`, `tmp2` | 临时寄存器 |

### 4.2 汇编流程图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      g1_write_barrier_post 汇编流程                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ① 检查是否跨 Region                                                         │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  movq tmp, store_addr                                                  │ │
│  │  xorq tmp, new_val                                                     │ │
│  │  shrq tmp, LogOfHRGrainBytes       ; >> 22 (4MB Region)                │ │
│  │  je done                           ; 同一 Region，跳过                  │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              │                                               │
│                              ↓ (跨 Region)                                   │
│  ② 检查新值是否为 NULL                                                       │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  cmpq new_val, 0                                                       │ │
│  │  je done                           ; NULL 不需要跟踪                    │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              │                                               │
│                              ↓ (非 NULL)                                     │
│  ③ 计算卡表项地址                                                            │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  movq card_addr, store_addr                                            │ │
│  │  shrq card_addr, 9                 ; >> CardTable::card_shift          │ │
│  │  movq cardtable, byte_map_base     ; 卡表基址                           │ │
│  │  addq card_addr, cardtable         ; card_addr = 卡表项绝对地址         │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              │                                               │
│                              ↓                                               │
│  ④ 检查是否为年轻代卡                                                        │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  cmpb [card_addr], g1_young_card_val (0x20)                            │ │
│  │  je done                           ; 年轻代卡不需要入队                  │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              │                                               │
│                              ↓ (非年轻代)                                    │
│  ⑤ 内存屏障 + 检查是否已脏                                                   │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  mfence                            ; StoreLoad 内存屏障                 │ │
│  │  cmpb [card_addr], dirty_card_val (0x00)                               │ │
│  │  je done                           ; 已脏，不重复入队                    │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              │                                               │
│                              ↓ (干净卡)                                      │
│  ⑥ 标记为脏 + 快速入队                                                      │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  movb [card_addr], dirty_card_val  ; 标记为脏                           │ │
│  │                                                                         │ │
│  │  cmpl [r15 + dirty_index_offset], 0                                    │ │
│  │  je runtime                        ; index == 0，缓冲区满               │ │
│  │                                                                         │ │
│  │  subl [r15 + dirty_index_offset], 8                                    │ │
│  │  movq tmp2, [r15 + dirty_buffer_offset]                                │ │
│  │  movslq rscratch1, [r15 + dirty_index_offset]                          │ │
│  │  addq tmp2, rscratch1                                                  │ │
│  │  movq [tmp2], card_addr            ; 写入卡地址                         │ │
│  │  jmp done                                                               │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              │                                               │
│                              ↓ (缓冲区满)                                    │
│  ⑦ 慢速路径：调用运行时                                                     │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  runtime:                                                               │ │
│  │      push store_addr                                                    │ │
│  │      push new_val                                                       │ │
│  │      call G1BarrierSetRuntime::write_ref_field_post_entry(card_addr)   │ │
│  │      pop new_val                                                        │ │
│  │      pop store_addr                                                     │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              │                                               │
│                              ↓                                               │
│  done:                                                                       │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.3 关键汇编代码分析

#### 4.3.1 跨 Region 检查

```cpp:281:286:src/hotspot/cpu/x86/gc/g1/g1BarrierSetAssembler_x86.cpp
  // Does store cross heap regions?

  __ movptr(tmp, store_addr);
  __ xorptr(tmp, new_val);
  __ shrptr(tmp, HeapRegion::LogOfHRGrainBytes);
  __ jcc(Assembler::equal, done);
```

**原理**：
```
store_addr XOR new_val >> LogOfHRGrainBytes
  
如果结果 == 0，说明高位相同，在同一 Region 内
如果结果 != 0，说明高位不同，跨 Region
```

**示例**（4MB Region，LogOfHRGrainBytes = 22）：
```
store_addr = 0x00007f8812400100  (Region 0)
new_val    = 0x00007f8812400200  (Region 0)
XOR        = 0x0000000000000300
>> 22      = 0                   → 同一 Region，跳过

store_addr = 0x00007f8812400100  (Region 0)
new_val    = 0x00007f8812800200  (Region 1)
XOR        = 0x0000000000c00300
>> 22      = 3                   → 跨 Region，需要处理
```

#### 4.3.2 卡表地址计算

```cpp:295:303:src/hotspot/cpu/x86/gc/g1/g1BarrierSetAssembler_x86.cpp
  const Register card_addr = tmp;
  const Register cardtable = tmp2;

  __ movptr(card_addr, store_addr);
  __ shrptr(card_addr, CardTable::card_shift);
  // byte_map_base 是编译时常量
  __ movptr(cardtable, (intptr_t)ct->card_table()->byte_map_base());
  __ addptr(card_addr, cardtable);
```

**卡表寻址公式**：
```
card_addr = byte_map_base + (store_addr >> 9)

每张卡覆盖 512 字节堆内存 (1 << 9 = 512)
```

**`byte_map_base` 的含义**：

```
byte_map_base 不是卡表的实际起始地址！

它是一个经过调整的地址，使得：
  byte_map_base + (heap_addr >> 9) 
直接得到该堆地址对应的卡表项

实际计算：
  byte_map_base = _byte_map - (heap_start >> 9)

这样：
  card_addr = byte_map_base + (heap_addr >> 9)
            = _byte_map - (heap_start >> 9) + (heap_addr >> 9)
            = _byte_map + ((heap_addr - heap_start) >> 9)
```

#### 4.3.3 年轻代卡检查

```cpp:305:306:src/hotspot/cpu/x86/gc/g1/g1BarrierSetAssembler_x86.cpp
  __ cmpb(Address(card_addr, 0), (int)G1CardTable::g1_young_card_val());
  __ jcc(Assembler::equal, done);
```

**为什么跳过年轻代卡**：

| 引用类型 | 是否需要 RSet |
|---------|--------------|
| 老年代 → 年轻代 | 需要（RSet 跟踪） |
| 年轻代 → 任何 | **不需要**（YGC 完整扫描年轻代） |
| 老年代 → 老年代 | Mixed GC 时需要 |

当字段位于年轻代时，该字段所在 Region 的卡表项被标记为 `g1_young_card` (0x20)，写后屏障直接跳过。

#### 4.3.4 内存屏障 + 脏卡检查

```cpp:308:310:src/hotspot/cpu/x86/gc/g1/g1BarrierSetAssembler_x86.cpp
  __ membar(Assembler::Membar_mask_bits(Assembler::StoreLoad));
  __ cmpb(Address(card_addr, 0), (int)G1CardTable::dirty_card_val());
  __ jcc(Assembler::equal, done);
```

**为什么需要 StoreLoad 屏障**：

```
场景：两个线程同时修改同一卡覆盖区域的字段

Thread 1                          Thread 2
--------                          --------
store obj.field1 = val1           store obj.field2 = val2
                                  
; 没有屏障时，可能乱序            ; 没有屏障时，可能乱序
load card_val                     load card_val
; 两个线程都看到 clean            ; 两个线程都看到 clean
store card = dirty                store card = dirty

结果：两次修改，但只有一个脏卡记录！

加入 StoreLoad 屏障后：
store obj.field = val
mfence                            ; 确保 store 完成
load card_val                     ; 再读卡状态
```

#### 4.3.5 标记脏卡 + 入队

```cpp:316:330:src/hotspot/cpu/x86/gc/g1/g1BarrierSetAssembler_x86.cpp
  // dirty card and log.

  __ movb(Address(card_addr, 0), (int)G1CardTable::dirty_card_val());

  __ cmpl(queue_index, 0);
  __ jcc(Assembler::equal, runtime);
  __ subl(queue_index, wordSize);
  __ movptr(tmp2, buffer);
#ifdef _LP64
  __ movslq(rscratch1, queue_index);
  __ addq(tmp2, rscratch1);
  __ movq(Address(tmp2, 0), card_addr);
#else
  __ addl(tmp2, queue_index);
  __ movl(Address(tmp2, 0), card_addr);
#endif
  __ jmp(done);
```

**脏卡队列入队过程**：

```
1. 标记卡为脏：[card_addr] = 0x00

2. 检查本地队列是否有空间
   if (queue_index == 0) goto runtime;

3. 快速入队：
   queue_index -= 8;
   buffer[queue_index] = card_addr;
```

---

## 5. oop_store_at() - 完整存储操作

### 5.1 函数签名

```cpp:349:350:src/hotspot/cpu/x86/gc/g1/g1BarrierSetAssembler_x86.cpp
void G1BarrierSetAssembler::oop_store_at(MacroAssembler* masm, DecoratorSet decorators, BasicType type,
                                         Address dst, Register val, Register tmp1, Register tmp2)
```

### 5.2 完整流程

```cpp:377:406:src/hotspot/cpu/x86/gc/g1/g1BarrierSetAssembler_x86.cpp
  if (needs_pre_barrier) {
    g1_write_barrier_pre(masm /*masm*/,
                         tmp1 /* obj */,
                         tmp2 /* pre_val */,
                         rthread /* thread */,
                         tmp3  /* tmp */,
                         val != noreg /* tosca_live */,
                         false /* expand_call */);
  }
  if (val == noreg) {
    BarrierSetAssembler::store_at(masm, decorators, type, Address(tmp1, 0), val, noreg, noreg);
  } else {
    Register new_val = val;
    if (needs_post_barrier) {
      // G1 barrier needs uncompressed oop for region cross check.
      if (UseCompressedOops) {
        new_val = tmp2;
        __ movptr(new_val, val);
      }
    }
    BarrierSetAssembler::store_at(masm, decorators, type, Address(tmp1, 0), val, noreg, noreg);
    if (needs_post_barrier) {
      g1_write_barrier_post(masm /*masm*/,
                            tmp1 /* store_adr */,
                            new_val /* new_val */,
                            rthread /* thread */,
                            tmp3 /* tmp */,
                            tmp2 /* tmp2 */);
    }
  }
```

**完整的引用写入流程**：

```
┌─────────────────────────────────────────────────────────────────┐
│                    obj.field = new_val                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. 地址扁平化                                                   │
│     ┌─────────────────────────────────────────────────────────┐ │
│     │ lea tmp1, [obj + field_offset]  ; 计算字段绝对地址      │ │
│     └─────────────────────────────────────────────────────────┘ │
│                              ↓                                   │
│  2. 写前屏障（SATB）                                             │
│     ┌─────────────────────────────────────────────────────────┐ │
│     │ g1_write_barrier_pre(tmp1, tmp2, ...)                   │ │
│     │   - 读旧值到 tmp2                                        │ │
│     │   - 入队到 SATB 队列                                     │ │
│     └─────────────────────────────────────────────────────────┘ │
│                              ↓                                   │
│  3. 实际存储                                                     │
│     ┌─────────────────────────────────────────────────────────┐ │
│     │ if (UseCompressedOops) {                                │ │
│     │     encode_heap_oop(val);                               │ │
│     │     movl [tmp1], val;       ; 32-bit 压缩指针           │ │
│     │ } else {                                                 │ │
│     │     movq [tmp1], val;       ; 64-bit 原始指针           │ │
│     │ }                                                        │ │
│     └─────────────────────────────────────────────────────────┘ │
│                              ↓                                   │
│  4. 写后屏障（CardTable）                                        │
│     ┌─────────────────────────────────────────────────────────┐ │
│     │ g1_write_barrier_post(tmp1, new_val, ...)               │ │
│     │   - 检查跨 Region                                        │ │
│     │   - 标记脏卡                                             │ │
│     │   - 入队到 Dirty Card Queue                              │ │
│     └─────────────────────────────────────────────────────────┘ │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 6. 寄存器使用约定

### 6.1 x86-64 寄存器分配

| 寄存器 | 用途 |
|--------|------|
| `r15` | **固定**：JavaThread 指针 (`r15_thread`) |
| `rax` | 栈顶缓存 (TOS)，需要保护 |
| `c_rarg0` (rdi) | 第一个调用参数 |
| `c_rarg1` (rsi) | 第二个调用参数 |
| `tmp`, `tmp2`, `tmp3` | 由调用者指定 |

### 6.2 屏障代码中的寄存器约束

```cpp
// g1_write_barrier_pre 中
assert(thread == r15_thread, "must be");      // 线程必须是 r15
assert(pre_val != noreg, "check this code");   // 必须有旧值寄存器
if (obj != noreg) {
    assert_different_registers(obj, pre_val, tmp);  // 三个寄存器互不相同
    assert(pre_val != rax, "check this code");      // pre_val 不能是 rax（用于保存）
}

// g1_write_barrier_post 中
assert(thread == r15_thread, "must be");      // 线程必须是 r15
```

---

## 7. C1 编译器的屏障 Stub

### 7.1 Pre-Barrier Stub

```cpp:415:436:src/hotspot/cpu/x86/gc/g1/g1BarrierSetAssembler_x86.cpp
void G1BarrierSetAssembler::gen_pre_barrier_stub(LIR_Assembler* ce, G1PreBarrierStub* stub) {
  G1BarrierSetC1* bs = (G1BarrierSetC1*)BarrierSet::barrier_set()->barrier_set_c1();
  
  __ bind(*stub->entry());
  assert(stub->pre_val()->is_register(), "Precondition.");

  Register pre_val_reg = stub->pre_val()->as_register();

  if (stub->do_load()) {
    ce->mem2reg(stub->addr(), stub->pre_val(), T_OBJECT, ...);
  }

  __ cmpptr(pre_val_reg, (int32_t)NULL_WORD);
  __ jcc(Assembler::equal, *stub->continuation());
  
  ce->store_parameter(stub->pre_val()->as_register(), 0);
  __ call(RuntimeAddress(bs->pre_barrier_c1_runtime_code_blob()->code_begin()));
  __ jmp(*stub->continuation());
}
```

C1 使用 **out-of-line stub**：主代码跳转到 stub，stub 完成后跳回。

### 7.2 Pre-Barrier Runtime Stub 生成

```cpp:456:515:src/hotspot/cpu/x86/gc/g1/g1BarrierSetAssembler_x86.cpp
void G1BarrierSetAssembler::generate_c1_pre_barrier_runtime_stub(StubAssembler* sasm) {
  __ prologue("g1_pre_barrier", false);

  __ push(rax);
  __ push(rdx);

  const Register pre_val = rax;
  const Register thread = r15_thread;
  const Register tmp = rdx;

  Address queue_active(thread, in_bytes(G1ThreadLocalData::satb_mark_queue_active_offset()));
  Address queue_index(thread, in_bytes(G1ThreadLocalData::satb_mark_queue_index_offset()));
  Address buffer(thread, in_bytes(G1ThreadLocalData::satb_mark_queue_buffer_offset()));

  Label done;
  Label runtime;

  // Is marking still active?
  __ cmpb(queue_active, 0);
  __ jcc(Assembler::equal, done);

  // Can we store in thread's buffer?
  __ movptr(tmp, queue_index);
  __ testptr(tmp, tmp);
  __ jcc(Assembler::zero, runtime);
  
  // 快速路径
  __ subptr(tmp, wordSize);
  __ movptr(queue_index, tmp);
  __ addptr(tmp, buffer);
  __ load_parameter(0, pre_val);
  __ movptr(Address(tmp, 0), pre_val);
  __ jmp(done);

  // 慢速路径
  __ bind(runtime);
  __ save_live_registers_no_oop_map(true);
  __ load_parameter(0, rcx);
  __ call_VM_leaf(CAST_FROM_FN_PTR(address, G1BarrierSetRuntime::write_ref_field_pre_entry), rcx, thread);
  __ restore_live_registers(true);

  __ bind(done);
  __ pop(rdx);
  __ pop(rax);
  __ epilogue();
}
```

---

## 8. 性能分析

### 8.1 快速路径开销

| 屏障 | 快速路径指令数 | 预期周期 |
|------|---------------|---------|
| 写前屏障 | ~8 条 | ~3-5 cycles |
| 写后屏障 | ~12 条 | ~5-8 cycles |

### 8.2 条件跳过优化

| 检查 | 跳过概率 | 说明 |
|------|---------|------|
| SATB 未激活 | ~95% | 大部分时间不在并发标记 |
| 旧值为 NULL | ~10% | 新分配对象 |
| 同一 Region | ~80% | 大部分引用指向相邻对象 |
| 新值为 NULL | ~5% | 清空引用 |
| 年轻代卡 | ~30% | 年轻代对象字段修改 |
| 已脏卡 | ~50% | 热点字段重复修改 |

### 8.3 缓冲区满的概率

```
SATB/Dirty Card 队列默认大小：1024 slots
每次 GC 清空

队列满的概率取决于：
- 两次 GC 之间的引用修改次数
- 并发标记持续时间（对 SATB）

通常 < 1% 的概率触发慢速路径
```

---

## 9. GDB 验证

### 9.1 查看线程的 G1 本地数据

```gdb
# 获取当前线程
(gdb) p $r15

# 计算偏移量
(gdb) ptype Thread
(gdb) p &((Thread*)0)->_gc_data
# 假设输出 120

# 查看 G1ThreadLocalData
(gdb) x/6gx ($r15 + 120)
# 输出：
# 0x...: qset 指针
# 0x...: _active (1 byte) + padding
# 0x...: _index
# 0x...: _capacity
# 0x...: _buf
# 0x...: _lock
```

### 9.2 查看 SATB 队列状态

```gdb
# 断点设置在 g1_write_barrier_pre 入口
(gdb) b g1BarrierSetAssembler_x86.cpp:142

# 运行后查看
(gdb) p G1ThreadLocalData::satb_mark_queue_active_offset()
(gdb) p G1ThreadLocalData::satb_mark_queue_index_offset()
(gdb) p G1ThreadLocalData::satb_mark_queue_buffer_offset()

# 查看实际值
(gdb) x/b $r15 + <active_offset>   # _active
(gdb) x/gx $r15 + <index_offset>   # _index
(gdb) x/gx $r15 + <buffer_offset>  # _buf
```

### 9.3 跟踪卡表操作

```gdb
# 断点设置在写后屏障
(gdb) b g1BarrierSetAssembler_x86.cpp:316

# 查看卡表基址
(gdb) p ((CardTableBarrierSet*)BarrierSet::barrier_set())->card_table()->byte_map_base()

# 计算某地址的卡表项
(gdb) p/x (<heap_addr> >> 9) + <byte_map_base>
```

---

## 10. 总结

### 10.1 两种屏障对比

| | 写前屏障（SATB） | 写后屏障（CardTable） |
|---|---|---|
| **触发条件** | SATB 激活 && 旧值非 NULL | 跨 Region && 新值非 NULL && 非年轻代 && 非脏卡 |
| **记录内容** | 旧值（oop） | 脏卡地址 |
| **队列** | SATB Queue | Dirty Card Queue |
| **消费者** | GC 标记线程 | 并发精炼线程 |
| **目的** | 防止漏标 | 维护 RSet |

### 10.2 性能关键点

1. **快速路径优化**：大部分情况直接跳过或本地入队
2. **线程本地队列**：避免锁竞争
3. **条件检查顺序**：最可能跳过的检查放前面
4. **年轻代跳过**：减少年轻代对象的屏障开销

### 10.3 数据结构关联图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          G1 屏障数据结构关联                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  JavaThread (r15_thread)                                                     │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  ...                                                                    │ │
│  │  _gc_data[512]                                                         │ │
│  │  ├── G1ThreadLocalData                                                 │ │
│  │  │   ├── _satb_mark_queue ───────────────→ SATBMarkQueueSet (全局)     │ │
│  │  │   │   ├── _active                       ├── _shared_satb_queue      │ │
│  │  │   │   ├── _index ←──────────────────┐   └── 完成的缓冲区链表        │ │
│  │  │   │   └── _buf ──→ [oop|oop|...| ] │                                │ │
│  │  │   │                        ↑        │                                │ │
│  │  │   │                        └────────┘ 从高地址向低地址填充           │ │
│  │  │   │                                                                  │ │
│  │  │   └── _dirty_card_queue ──────────────→ DirtyCardQueueSet (全局)    │ │
│  │  │       ├── _index ←──────────────────┐   ├── _shared_dirty_card_queue│ │
│  │  │       └── _buf ──→ [card|card|..| ] │   └── 完成的缓冲区链表        │ │
│  │  │                             ↑        │                               │ │
│  │  │                             └────────┘                               │ │
│  │  └────────────────────────────────────────────────────────────────────┘ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│  CardTable                                                                   │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  _byte_map_base ──→ (虚拟地址，使 base + (addr>>9) 直接寻址)           │ │
│  │  _byte_map ────────→ [card0|card1|card2|...|cardN]                     │ │
│  │                        ↑                                                │ │
│  │                        │ 每个 card 覆盖 512 字节堆内存                   │ │
│  │                        │ 0xFF=clean, 0x00=dirty, 0x20=young             │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```
