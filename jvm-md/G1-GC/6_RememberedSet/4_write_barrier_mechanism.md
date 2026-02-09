# G1 写屏障（Write Barrier）机制详解

## 1. 功能定位

### 1.1 一句话说明

**G1 写屏障是插在对象引用写操作前后的"钩子代码"，写前屏障（Pre-Write Barrier）记录旧引用用于 SATB 并发标记，写后屏障（Post-Write Barrier）标记脏卡用于跨 Region 引用追踪。**

### 1.2 为什么需要写屏障

```
┌─────────────────────────────────────────────────────────────────────┐
│                    没有写屏障的问题                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  并发标记期间，应用线程同时修改对象引用：                            │
│                                                                      │
│  时刻 T1（标记开始）：                                               │
│      A ──► B ──► C                                                   │
│      ↑                                                               │
│     Root（已标记为存活）                                             │
│                                                                      │
│  时刻 T2（应用修改）：                                               │
│      A ──► X ──► C  （A.field 从 B 改为 X）                         │
│      B 变为浮动垃圾                                                  │
│                                                                      │
│  时刻 T3（标记结束）：                                               │
│      - A 已标记（黑色）                                              │
│      - B 未标记（白色）但仍有引用指向 C                              │
│      - C 未被扫描到（漏标！）                                        │
│                                                                      │
│  后果：C 被错误回收，导致数据丢失！                                  │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.3 写屏障解决方案

```
┌─────────────────────────────────────────────────────────────────────┐
│                    写屏障的解决思路                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  【写前屏障 - SATB】                                                 │
│  A.field = X 执行前，先记录旧值 B：                                  │
│      enqueue(B) ──► SATB Queue                                       │
│                                                                      │
│  并发标记时处理 SATB 队列：                                          │
│      即使 B 从 A 断开，也确保 B 和 C 被标记                          │
│                                                                      │
│  【写后屏障 - Dirty Card】                                           │
│  A.field = X 执行后，检查跨 Region 引用：                            │
│      if (A in Old && X in Young)                                     │
│          mark_card_dirty(A) ──► DC Queue                             │
│                                                                      │
│  Refine 线程处理 DC 队列：                                           │
│      更新 X 所在 Region 的 RSet                                      │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. 类继承关系

```
┌─────────────────────────────────────────────────────────────────────┐
│                      写屏障类继承关系                                │
└─────────────────────────────────────────────────────────────────────┘

                      BarrierSet (基类)
                           │
                           ▼
                    ┌──────────────┐
                    │ ModRefBarrierSet│
                    │ (修改引用屏障) │
                    └──────┬───────┘
                           │
                           ▼
                    ┌──────────────┐
                    │CardTableBarrierSet│
                    │ (卡表屏障)     │
                    └──────┬───────┘
                           │
                           ▼
                    ┌──────────────┐
                    │ G1BarrierSet │ ◄── 本分析目标
                    ├──────────────┤
                    │ _satb_mark_queue_set │
                    │ _dirty_card_queue_set│
                    └──────────────┘
                           │
           ┌───────────────┼───────────────┐
           │               │               │
           ▼               ▼               ▼
    ┌────────────┐  ┌────────────┐  ┌────────────┐
    │G1BarrierSet│  │G1BarrierSet│  │G1BarrierSet│
    │Assembler   │  │C1          │  │C2          │
    │(解释器)    │  │(C1编译器)  │  │(C2编译器)  │
    └────────────┘  └────────────┘  └────────────┘
```

---

## 3. 核心数据结构

### 3.1 G1BarrierSet 字段

```cpp
// src/hotspot/share/gc/g1/g1BarrierSet.hpp:39
class G1BarrierSet: public CardTableBarrierSet {
 private:
  static SATBMarkQueueSet  _satb_mark_queue_set;   // SATB 队列集
  static DirtyCardQueueSet _dirty_card_queue_set;  // 脏卡队列集
  
 public:
  // 写前屏障：记录旧引用
  template <DecoratorSet decorators, typename T>
  void write_ref_field_pre(T* field);
  
  // 写后屏障：标记脏卡
  template <DecoratorSet decorators, typename T>
  void write_ref_field_post(T* field, oop new_val);
  
  // 慢路径：实际执行脏卡入队
  void write_ref_field_post_slow(volatile jbyte* byte);
  
  // 入队旧引用到 SATB
  static void enqueue(oop pre_val);
};
```

### 3.2 关键字段详解

#### _satb_mark_queue_set（SATB 队列集）

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【是什么】
  类型：SATBMarkQueueSet（静态全局唯一）
  作用：管理所有线程的 SATB 标记队列

【为什么需要】
  问题：并发标记期间，应用线程修改引用可能导致漏标
  解决：记录所有被覆盖的旧引用，确保它们被标记

【工作流程】
  1. 写前屏障：读取 field 的旧值 pre_val
  2. 如果 pre_val != null，调用 enqueue(pre_val)
  3. enqueue：获取线程本地 SATBMarkQueue，入队 pre_val
  4. 队列满时，批量提交到 _satb_mark_queue_set
  5. GC 线程处理全局队列，标记所有旧引用

【三色标记中的应用】
  - 白色：未标记
  - 灰色：已标记，待处理子引用
  - 黑色：已标记，子引用已处理
  
  SATB 保证：如果白色对象被黑色对象引用断开，
            旧引用会被记录并标记，不会漏标
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

#### _dirty_card_queue_set（脏卡队列集）

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【是什么】
  类型：DirtyCardQueueSet（静态全局唯一）
  作用：管理所有线程的脏卡队列

【为什么需要】
  问题：需要追踪跨 Region 引用修改，但直接更新 RSet 太慢
  解决：批量记录脏卡，后台线程异步更新 RSet

【工作流程】
  1. 写后屏障：获取 field 所在 Card 的地址
  2. 如果 Card 不是 young_gen，标记为 dirty
  3. 将 Card 地址入队到线程本地 DirtyCardQueue
  4. 队列满时，批量提交到 _dirty_card_queue_set
  5. Concurrent Refine 线程处理队列，更新 RSet

【过滤优化】
  - 年轻代 Card 跳过（不需要追踪，Young GC 会全扫描）
  - 已是 dirty 的 Card 跳过（避免重复入队）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 4. 写屏障核心算法

### 4.1 写前屏障（Pre-Write Barrier）

```cpp
// src/hotspot/share/gc/g1/g1BarrierSet.inline.hpp:35
template <DecoratorSet decorators, typename T>
inline void G1BarrierSet::write_ref_field_pre(T* field) {
  // 1. 过滤不需要屏障的场景
  if (HasDecorator<decorators, IS_DEST_UNINITIALIZED>::value ||
      HasDecorator<decorators, AS_NO_KEEPALIVE>::value) {
    return;  // 对象初始化或特殊访问，无需屏障
  }

  // 2. 读取旧值（将被覆盖的值）
  T heap_oop = RawAccess<MO_VOLATILE>::oop_load(field);
  
  // 3. 如果旧值非空，入队 SATB
  if (!CompressedOops::is_null(heap_oop)) {
    enqueue(CompressedOops::decode_not_null(heap_oop));
  }
}
```

**执行流程图：**
```
┌─────────────────────────────────────────────────────────────────────┐
│                    写前屏障执行流程                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  obj.field = new_val  （即将执行）                                   │
│       │                                                              │
│       ▼                                                              │
│  ┌─────────────────────┐                                            │
│  │ 1. 检查装饰器        │                                            │
│  │ IS_DEST_UNINITIALIZED?                                            │
│  │ AS_NO_KEEPALIVE?     │                                            │
│  └──────────┬──────────┘                                            │
│       │ YES │ NO                                                     │
│       ▼     ▼                                                        │
│    直接返回  │                                                        │
│              ▼                                                        │
│  ┌─────────────────────┐                                            │
│  │ 2. 读取旧值          │                                            │
│  │ old_val = *field     │                                            │
│  │ (MO_VOLATILE 保证可见性)                                          │
│  └──────────┬──────────┘                                            │
│             ▼                                                        │
│  ┌─────────────────────┐                                            │
│  │ 3. 检查旧值          │                                            │
│  │ old_val == null?     │                                            │
│  └──────────┬──────────┘                                            │
│       │ YES │ NO                                                     │
│       ▼     ▼                                                        │
│    直接返回  │                                                        │
│              ▼                                                        │
│  ┌─────────────────────┐                                            │
│  │ 4. 入队 SATB        │                                            │
│  │ enqueue(old_val)    │                                            │
│  │ 添加到线程本地队列   │                                            │
│  └─────────────────────┘                                            │
│                                                                      │
│  5. 执行实际写操作：*field = new_val                                  │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 4.2 写后屏障（Post-Write Barrier）

```cpp
// src/hotspot/share/gc/g1/g1BarrierSet.inline.hpp:48
template <DecoratorSet decorators, typename T>
inline void G1BarrierSet::write_ref_field_post(T* field, oop new_val) {
  // 1. 获取 field 所在的 Card 地址
  volatile jbyte* byte = _card_table->byte_for(field);
  
  // 2. 年轻代过滤：Young Card 不需要追踪
  if (*byte != G1CardTable::g1_young_card_val()) {
    // 3. 老年代 Card，走慢路径
    write_ref_field_post_slow(byte);
  }
}

// 慢路径：实际标记脏卡并入队
void G1BarrierSet::write_ref_field_post_slow(volatile jbyte* byte) {
  // 内存屏障：确保写操作先完成
  OrderAccess::storeload();
  
  // 检查是否已是 dirty（避免重复入队）
  if (*byte != G1CardTable::dirty_card_val()) {
    *byte = G1CardTable::dirty_card_val();  // 标记脏卡
    
    // 入队到线程本地 DC 队列
    Thread* thr = Thread::current();
    if (thr->is_Java_thread()) {
      G1ThreadLocalData::dirty_card_queue(thr).enqueue(byte);
    } else {
      // VM 线程使用共享队列（加锁）
      MutexLockerEx x(Shared_DirtyCardQ_lock, ...);
      _dirty_card_queue_set.shared_dirty_card_queue()->enqueue(byte);
    }
  }
}
```

**执行流程图：**
```
┌─────────────────────────────────────────────────────────────────────┐
│                    写后屏障执行流程                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  obj.field = new_val  （已执行）                                     │
│       │                                                              │
│       ▼                                                              │
│  ┌─────────────────────┐                                            │
│  │ 1. 获取 Card 地址    │                                            │
│  │ byte = card_table-> │                                            │
│  │        byte_for(field)                                           │
│  └──────────┬──────────┘                                            │
│             ▼                                                        │
│  ┌─────────────────────┐                                            │
│  │ 2. 年轻代过滤        │                                            │
│  │ *byte == young_val? │                                            │
│  └──────────┬──────────┘                                            │
│       │ YES │ NO                                                     │
│       ▼     ▼                                                        │
│    直接返回  │                                                        │
│              ▼                                                        │
│  ┌─────────────────────┐                                            │
│  │ 3. 内存屏障          │                                            │
│  │ OrderAccess::storeload()                                         │
│  │ 确保 obj.field 写完成                                              │
│  └──────────┬──────────┘                                            │
│             ▼                                                        │
│  ┌─────────────────────┐                                            │
│  │ 4. 重复过滤          │                                            │
│  │ *byte == dirty?      │                                            │
│  └──────────┬──────────┘                                            │
│       │ YES │ NO                                                     │
│       ▼     ▼                                                        │
│    直接返回  │                                                        │
│              ▼                                                        │
│  ┌─────────────────────┐                                            │
│  │ 5. 标记脏卡          │                                            │
│  │ *byte = dirty        │                                            │
│  └──────────┬──────────┘                                            │
│             ▼                                                        │
│  ┌─────────────────────┐                                            │
│  │ 6. 入队 DC Queue    │                                            │
│  │ enqueue(byte)       │                                            │
│  └─────────────────────┘                                            │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 4.3 写屏障触发条件总结

| 屏障类型 | 触发条件 | 过滤条件 | 入队内容 |
|---------|---------|---------|---------|
| **Pre (SATB)** | 所有非初始化写操作 | 对象初始化、AS_NO_KEEPALIVE | 旧引用 (oop) |
| **Post (Dirty)** | 所有写操作 | 年轻代 Card、已是 dirty | Card 地址 (jbyte*) |

---

## 5. 内存布局与性能

### 5.1 写屏障内存开销

```
┌─────────────────────────────────────────────────────────────────────┐
│                    写屏障内存开销分析                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  每个 JavaThread：                                                   │
│  ┌─────────────────────────────────────┐                            │
│  │ SATBMarkQueue   │ ~16KB 缓冲区      │                            │
│  │ DirtyCardQueue  │ ~16KB 缓冲区      │                            │
│  └─────────────────────────────────────┘                            │
│  总计：~32KB/线程                                                    │
│                                                                      │
│  对于 1000 个线程：32MB                                              │
│                                                                      │
│  全局队列集：                                                        │
│  ┌─────────────────────────────────────┐                            │
│  │ SATBMarkQueueSet  │ ~1MB（链表管理）│                            │
│  │ DirtyCardQueueSet │ ~1MB（链表管理）│                            │
│  └─────────────────────────────────────┘                            │
│                                                                      │
│  总开销：可接受（相比堆大小）                                        │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 5.2 写屏障 CPU 开销

```
┌─────────────────────────────────────────────────────────────────────┐
│                    写屏障 CPU 开销分析                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  写前屏障（快速路径）：                                              │
│  - 检查装饰器：     ~1 周期                                          │
│  - 读取旧值：       ~3 周期（内存读取）                              │
│  - 检查 null：      ~1 周期                                          │
│  - 入队（慢路径）： ~50 周期（队列满时触发）                         │
│  平均开销：~5 周期（99% 快速路径）                                   │
│                                                                      │
│  写后屏障（快速路径）：                                              │
│  - 计算 Card 地址： ~3 周期                                          │
│  - 读取 Card 值：   ~3 周期（内存读取）                              │
│  - 年轻代过滤：     ~2 周期                                          │
│  - 慢路径：         ~100 周期（标记+入队）                           │
│  平均开销：~8 周期（Young 分配为主，老年代写较少）                   │
│                                                                      │
│  总体开销：应用性能的 5-10%（可接受）                                │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 6. GDB 验证脚本

```bash
# 文件：jvm-md/G1-GC/6_RememberedSet/gdb_write_barrier.txt

set pagination off
set print pretty on

# 断点1：观察写前屏障
break G1BarrierSet::write_ref_field_pre
cmd
  silent
  printf "\n========== write_ref_field_pre (SATB) ==========\n"
  printf "field = %p\n", $field
  printf "old_val = %p\n", (oop)$heap_oop
  continue
end

# 断点2：观察写后屏障快速路径
break G1BarrierSet::write_ref_field_post
cmd
  silent
  printf "\n========== write_ref_field_post ==========\n"
  printf "field = %p\n", $field
  printf "card_addr = %p\n", $byte
  printf "card_value = %d\n", (int)*$byte
  continue
end

# 断点3：观察写后屏障慢路径
break G1BarrierSet::write_ref_field_post_slow
cmd
  silent
  printf "\n========== write_ref_field_post_slow ==========\n"
  printf "card_addr = %p\n", $byte
  printf "old_card_value = %d\n", (int)*$byte
  printf "marked as dirty and enqueued to DC queue\n"
  continue
end

# 断点4：观察 SATB 入队
break G1BarrierSet::enqueue
cmd
  silent
  printf "\n========== SATB enqueue ==========\n"
  printf "pre_val = %p\n", $pre_val
  printf "is_active = %d\n", G1BarrierSet::_satb_mark_queue_set.is_active()
  continue
end

# 断点5：统计队列大小
break PtrQueue::enqueue
cmd
  silent
  # 统计入队次数
  set $enqueue_count++
  if $enqueue_count % 1000 == 0
    printf "Total enqueue operations: %d\n", $enqueue_count
  end
  continue
end

# 初始化计数器
set $enqueue_count = 0

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main
```

---

## 7. 写屏障与其他组件的关系

```
┌─────────────────────────────────────────────────────────────────────┐
│                    写屏障组件关系图                                  │
└─────────────────────────────────────────────────────────────────────┘

  应用代码：obj.field = new_val
       │
       ├──► 【写前屏障】───────────────────────────────────────────────┐
       │     G1BarrierSet::write_ref_field_pre()                       │
       │       │                                                        │
       │       ▼                                                        │
       │     SATBMarkQueue::enqueue(pre_val)                           │
       │       │                                                        │
       │       ▼                                                        │
       │     G1ThreadLocalData::satb_mark_queue()                       │
       │       │                                                        │
       │       ├── 缓冲区未满 ──► 直接存入线程本地缓冲区                │
       │       │                                                        │
       │       └── 缓冲区满 ────► 批量提交到 SATBMarkQueueSet           │
       │                              │                                 │
       │                              ▼                                 │
       │                         全局队列链表                           │
       │                              │                                 │
       │                              ▼                                 │
       │                         GC 线程处理（并发标记）                │
       │                         标记旧引用指向的对象                   │
       │                                                                │
       └──► 【实际写操作】                                              │
       │     *field = new_val                                           │
       │                                                                │
       └──► 【写后屏障】───────────────────────────────────────────────┤
             G1BarrierSet::write_ref_field_post()                       │
               │                                                        │
               ▼                                                        │
             CardTable::byte_for(field) ──► 获取 Card 地址             │
               │                                                        │
               ▼                                                        │
             年轻代过滤？                                               │
               │                                                        │
               ├── 是 Young Card ──► 直接返回                           │
               │                                                        │
               └── 是 Old Card ────► write_ref_field_post_slow()       │
                                          │                             │
                                          ▼                             │
                                        mark_card_dirty()               │
                                          │                             │
                                          ▼                             │
                                        DirtyCardQueue::enqueue()      │
                                          │                             │
                                          ▼                             │
                                        G1ThreadLocalData::            │
                                          dirty_card_queue()            │
                                          │                             │
                                          ├── 缓冲区未满 ──► 直接存入   │
                                          │                             │
                                          └── 缓冲区满 ────► 批量提交   │
                                                               │        │
                                                               ▼        │
                                                          DirtyCardQueueSet
                                                               │
                                                               ▼
                                                  Concurrent Refine Thread
                                                               │
                                                               ▼
                                                  扫描 Card，更新 RSet
```

---

## 8. 总结

### 8.1 核心要点

| 组件 | 职责 | 触发时机 | 处理时机 |
|-----|------|---------|---------|
| **Pre-Write Barrier** | 记录旧引用（SATB） | 引用修改前 | 并发标记时 |
| **Post-Write Barrier** | 标记脏卡 | 引用修改后 | Refine 线程异步处理 |
| **SATB Queue** | 存储旧引用 | Pre-Barrier | GC 标记阶段 |
| **Dirty Card Queue** | 存储脏卡地址 | Post-Barrier | Refine 线程 |

### 8.2 关键设计决策

1. **分离 Pre/Post 屏障**：
   - Pre：保证并发标记正确性（SATB）
   - Post：追踪跨 Region 引用（Dirty Card）

2. **线程本地队列**：
   - 避免全局锁竞争
   - 批量提交提高效率

3. **多层过滤**：
   - 装饰器过滤（初始化）
   - 年轻代过滤（Young Card）
   - 重复过滤（已是 dirty）

4. **内存序保证**：
   - `MO_VOLATILE`：读取旧值可见性
   - `storeload`：确保写操作先完成

---

**质量自检清单：**
- [x] 功能定位（一句话 + 为什么需要 + 无它后果）
- [x] 类继承关系图
- [x] Pre/Post 屏障详细流程
- [x] 关键代码分析
- [x] 性能开销分析
- [x] GDB 验证脚本
- [x] 组件关系图
