# C.3 G1BarrierSet - 写屏障机制

> G1 通过**写前屏障（SATB）** 和 **写后屏障（CardTable）** 实现并发标记和跨代引用追踪

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **C.3 G1BarrierSet - 写屏障机制**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 1. 为什么需要写屏障？

### 1.1 问题场景

```
问题 1：并发标记期间，应用线程修改引用
┌────────────────────────────────────────────────────────────────┐
│  GC 线程正在标记          │    应用线程修改引用                │
│  ┌──┐      ┌──┐          │    ┌──┐      ┌──┐                  │
│  │A │ ───→ │B │ (已标记)  │    │A │ ─X─→ │B │                  │
│  └──┘      └──┘          │    └──┘      └──┘                  │
│                          │      │                              │
│                          │      └──→ ┌──┐                      │
│                          │           │C │ (未标记，漏标！)      │
│                          │           └──┘                      │
└────────────────────────────────────────────────────────────────┘

问题 2：老年代对象引用年轻代对象
┌────────────────────────────────────────────────────────────────┐
│  Old Region             │    Young Region                      │
│  ┌──────────────┐       │    ┌──────────────┐                  │
│  │ ObjA ──────────────────→ │ ObjB         │                  │
│  │              │       │    │              │                  │
│  └──────────────┘       │    └──────────────┘                  │
│                         │                                       │
│  Minor GC 时，如何知道 ObjB 被 ObjA 引用？                       │
│  如果不知道，ObjB 会被误回收！                                   │
└────────────────────────────────────────────────────────────────┘
```

### 1.2 G1 的解决方案

| 问题 | 解决方案 | 屏障类型 |
|------|----------|----------|
| 并发标记漏标 | SATB（Snapshot-At-The-Beginning） | **写前屏障** |
| 跨代引用追踪 | CardTable + Dirty Card Queue | **写后屏障** |

---

## 2. G1BarrierSet 类结构

```cpp
// g1BarrierSet.hpp:39
class G1BarrierSet : public CardTableBarrierSet {
    // 两个核心队列集（静态成员，全局唯一）
    static SATBMarkQueueSet  _satb_mark_queue_set;   // SATB 队列集
    static DirtyCardQueueSet _dirty_card_queue_set;  // 脏卡队列集
    
public:
    // 写前屏障
    template <DecoratorSet decorators, typename T>
    void write_ref_field_pre(T* field);
    
    // 写后屏障
    template <DecoratorSet decorators, typename T>
    void write_ref_field_post(T* field, oop new_val);
};
```

**继承层次**：
```
BarrierSet
    └── ModRefBarrierSet
            └── CardTableBarrierSet
                    └── G1BarrierSet
```

---

## 3. 写前屏障（SATB）

### 3.1 原理

```
SATB = Snapshot-At-The-Beginning（起始快照）

核心思想：在并发标记开始时，对对象图拍"快照"
         之后被删除的引用（旧值）都记录下来
         确保快照时刻存活的对象不会漏标

流程：
┌─────────────────────────────────────────────────────────────────┐
│                                                                  │
│   A.field = B  →  A.field = C                                   │
│                                                                  │
│   写前屏障触发：                                                  │
│   1. 读取旧值 B                                                  │
│   2. 将 B 入队到 SATB 队列                                       │
│   3. 执行实际写入 A.field = C                                    │
│                                                                  │
│   GC 线程后续处理 SATB 队列，确保 B 被标记                       │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 源码实现

```cpp
// g1BarrierSet.inline.hpp:36
template <DecoratorSet decorators, typename T>
inline void G1BarrierSet::write_ref_field_pre(T* field) {
    // 如果是未初始化的目标，跳过（不需要记录旧值）
    if (HasDecorator<decorators, IS_DEST_UNINITIALIZED>::value ||
        HasDecorator<decorators, AS_NO_KEEPALIVE>::value) {
        return;
    }
    
    // Step 1: 读取旧值
    T heap_oop = RawAccess<MO_VOLATILE>::oop_load(field);
    
    // Step 2: 如果旧值非空，入队
    if (!CompressedOops::is_null(heap_oop)) {
        enqueue(CompressedOops::decode_not_null(heap_oop));
    }
}

// g1BarrierSet.cpp:118
void G1BarrierSet::enqueue(oop pre_val) {
    // SATB 不活跃时（非并发标记期间），直接返回
    if (!_satb_mark_queue_set.is_active()) return;
    
    Thread* thr = Thread::current();
    if (thr->is_Java_thread()) {
        // Java 线程：入队到线程本地 SATB 队列
        G1ThreadLocalData::satb_mark_queue(thr).enqueue(pre_val);
    } else {
        // 非 Java 线程：入队到共享 SATB 队列
        MutexLockerEx x(Shared_SATB_Q_lock, Mutex::_no_safepoint_check_flag);
        _satb_mark_queue_set.shared_satb_queue()->enqueue(pre_val);
    }
}
```

### 3.3 SATB 队列架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SATB 队列架构                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Java Thread 1          Java Thread 2          Java Thread N                │
│  ┌───────────────┐      ┌───────────────┐      ┌───────────────┐            │
│  │ Local SATB Q  │      │ Local SATB Q  │      │ Local SATB Q  │            │
│  │ [oopA][oopB]..│      │ [oopX][oopY]..│      │ [oopM][oopN]..│            │
│  └───────┬───────┘      └───────┬───────┘      └───────┬───────┘            │
│          │ 队列满               │                      │                     │
│          ↓                      ↓                      ↓                     │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                    SATBMarkQueueSet（全局）                          │    │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐                              │    │
│  │  │ Buffer1 │  │ Buffer2 │  │ Buffer3 │  ...                         │    │
│  │  └─────────┘  └─────────┘  └─────────┘                              │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                              ↓                                               │
│                    GC 线程消费，标记对象                                     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. 写后屏障（CardTable）

### 4.1 原理

```
核心思想：修改引用后，标记对应的卡表项为"脏"
         Minor GC 时只扫描脏卡，避免全堆扫描

流程：
┌─────────────────────────────────────────────────────────────────┐
│                                                                  │
│   A.field = B                                                   │
│                                                                  │
│   写后屏障触发：                                                  │
│   1. 计算 A 所在的卡表索引                                       │
│   2. 如果是年轻代卡（g1_young_card），跳过                       │
│   3. 否则标记为脏（dirty_card）                                  │
│   4. 将脏卡地址入队到 Dirty Card Queue                          │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 卡值定义

```cpp
// cardTable.hpp:96
enum CardValues {
    clean_card       = -1,   // 0xFF：干净，无需扫描
    dirty_card       =  0,   // 0x00：脏，需要扫描
    precleaned_card  =  1,   // 已预清理
    claimed_card     =  2,   // 已声明
    deferred_card    =  4,   // 延迟处理
};

// g1CardTable.hpp:53
enum G1CardValues {
    g1_young_gen = CT_MR_BS_last_reserved << 1  // 0x20：年轻代
};
```

**卡值状态图**：
```
┌─────────────────────────────────────────────────────────────────┐
│                        卡表项状态转换                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   clean (0xFF)                                                  │
│       │                                                          │
│       │ 写屏障触发                                               │
│       ↓                                                          │
│   dirty (0x00) ─────────────→ 并发精炼线程处理                   │
│       │                              │                           │
│       │ 进入年轻代                   │                           │
│       ↓                              ↓                           │
│   g1_young (0x20)            clean (0xFF)                        │
│   (跳过写后屏障)                                                 │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 4.3 源码实现

```cpp
// g1BarrierSet.inline.hpp:48
template <DecoratorSet decorators, typename T>
inline void G1BarrierSet::write_ref_field_post(T* field, oop new_val) {
    // Step 1: 获取卡表项地址
    volatile jbyte* byte = _card_table->byte_for(field);
    
    // Step 2: 快速路径 - 年轻代卡无需处理
    if (*byte != G1CardTable::g1_young_card_val()) {
        // 慢速路径
        write_ref_field_post_slow(byte);
    }
}

// g1BarrierSet.cpp:156
void G1BarrierSet::write_ref_field_post_slow(volatile jbyte* byte) {
    // 确保不是年轻代卡
    assert(*byte != G1CardTable::g1_young_card_val(), "...");
    
    // 内存屏障
    OrderAccess::storeload();
    
    // 如果不是脏卡，标记为脏并入队
    if (*byte != G1CardTable::dirty_card_val()) {
        *byte = G1CardTable::dirty_card_val();
        
        Thread* thr = Thread::current();
        if (thr->is_Java_thread()) {
            // Java 线程：入队到线程本地脏卡队列
            G1ThreadLocalData::dirty_card_queue(thr).enqueue(byte);
        } else {
            // 非 Java 线程：入队到共享脏卡队列
            MutexLockerEx x(Shared_DirtyCardQ_lock, ...);
            _dirty_card_queue_set.shared_dirty_card_queue()->enqueue(byte);
        }
    }
}
```

### 4.4 脏卡队列架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         脏卡队列架构                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Java Thread 1          Java Thread 2          Java Thread N                │
│  ┌───────────────┐      ┌───────────────┐      ┌───────────────┐            │
│  │Local DirtyQ   │      │Local DirtyQ   │      │Local DirtyQ   │            │
│  │[card1][card2] │      │[card5][card6] │      │[card9][card10]│            │
│  └───────┬───────┘      └───────┬───────┘      └───────┬───────┘            │
│          │ 队列满               │                      │                     │
│          ↓                      ↓                      ↓                     │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                 DirtyCardQueueSet（全局）                            │    │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐                              │    │
│  │  │ Buffer1 │  │ Buffer2 │  │ Buffer3 │  ...                         │    │
│  │  └─────────┘  └─────────┘  └─────────┘                              │    │
│  │                                                                      │    │
│  │  队列长度 < Yellow Zone (39)：正常                                   │    │
│  │  队列长度 ≥ Yellow Zone：触发并发精炼                                │    │
│  │  队列长度 ≥ Red Zone (65)：应用线程帮忙处理                          │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                              ↓                                               │
│               并发精炼线程（Concurrent Refinement）                          │
│                    处理脏卡，更新 RSet                                       │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. 写屏障完整流程

```java
// Java 代码
obj.field = newValue;
```

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          写屏障完整流程                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ① 写前屏障（SATB）                                                         │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │ if (SATB_active && oldValue != null) {                               │   │
│  │     satb_queue.enqueue(oldValue);  // 保存旧值                       │   │
│  │ }                                                                     │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                              ↓                                               │
│  ② 实际写入                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │ obj.field = newValue;                                                │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                              ↓                                               │
│  ③ 写后屏障（CardTable）                                                    │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │ jbyte* card = card_table[&obj.field >> 9];                           │   │
│  │ if (*card != g1_young_card) {                                        │   │
│  │     if (*card != dirty_card) {                                       │   │
│  │         *card = dirty_card;                                          │   │
│  │         dirty_card_queue.enqueue(card);                              │   │
│  │     }                                                                 │   │
│  │ }                                                                     │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 6. 初始化代码

```cpp
// g1CollectedHeap.cpp:1736
G1BarrierSet* bs = new G1BarrierSet(ct);  // ct = G1CardTable
bs->initialize();  // 调用父类 CardTableBarrierSet::initialize()

assert(bs->is_a(BarrierSet::G1BarrierSet), "sanity");

// 设置为全局唯一屏障集
// 同时为当前线程创建 G1ThreadLocalData
BarrierSet::set_barrier_set(bs);

_card_table = ct;
```

**构造函数**：
```cpp
// g1BarrierSet.cpp:73
G1BarrierSet::G1BarrierSet(G1CardTable* card_table) :
    CardTableBarrierSet(
        make_barrier_set_assembler<G1BarrierSetAssembler>(),  // 汇编器
        make_barrier_set_c1<G1BarrierSetC1>(),                // C1 支持
        make_barrier_set_c2<G1BarrierSetC2>(),                // C2 支持
        card_table,                                            // 卡表
        BarrierSet::FakeRtti(BarrierSet::G1BarrierSet))        // 类型标识
{}
```

---

## 7. 年轻代优化

### 7.1 为什么年轻代卡跳过写后屏障？

```
原因：年轻代每次 GC 都会完整扫描，不需要 RSet 跟踪

┌────────────────────────────────────────────────────────────────┐
│  老年代 → 年轻代 引用：需要 RSet 跟踪                           │
│  年轻代 → 老年代 引用：不需要（年轻代会完整扫描）               │
│  年轻代 → 年轻代 引用：不需要（年轻代会完整扫描）               │
│  老年代 → 老年代 引用：Mixed GC 时需要                          │
└────────────────────────────────────────────────────────────────┘
```

### 7.2 年轻代卡标记

```cpp
// g1CardTable.hpp:99
void g1_mark_as_young(const MemRegion& mr);
```

当 Region 被分配给年轻代时，对应的卡表项被标记为 `g1_young_card`，写后屏障就会跳过这些卡。

---

## 8. 线程本地数据

```cpp
// g1BarrierSet.cpp:212
void G1BarrierSet::on_thread_create(Thread* thread) {
    // 为每个线程创建本地数据
    G1ThreadLocalData::create(thread);
}

// G1ThreadLocalData 包含：
// - SATB 本地队列
// - Dirty Card 本地队列
```

**好处**：
- 减少锁竞争
- 提高并发性能
- 队列满时才同步到全局

---

## 9. 性能考量

### 9.1 写屏障开销

| 屏障 | 操作 | 开销 |
|------|------|------|
| 写前屏障 | 1 次读 + 条件判断 + 可能入队 | 低 |
| 写后屏障 | 1 次地址计算 + 1 次读 + 条件判断 + 可能入队 | 低 |

### 9.2 优化手段

| 优化 | 说明 |
|------|------|
| 年轻代跳过 | 年轻代卡无需处理写后屏障 |
| 线程本地队列 | 减少锁竞争 |
| 批量处理 | 队列满了才同步 |
| 条件编译 | 解释器/C1/C2 不同实现 |

---

## 10. 总结

### 10.1 两种写屏障对比

| | 写前屏障（SATB） | 写后屏障（CardTable） |
|---|---|---|
| **时机** | 引用被覆盖前 | 引用被修改后 |
| **目的** | 防止并发标记漏标 | 跟踪跨代引用 |
| **记录** | 旧值（被覆盖的引用） | 脏卡地址 |
| **队列** | SATB Queue | Dirty Card Queue |
| **处理** | GC 线程标记 | 并发精炼线程更新 RSet |
| **活跃条件** | 并发标记期间 | 始终活跃 |

### 10.2 关键设计点

1. **SATB 保证不漏标**：记录所有被删除的引用
2. **CardTable 避免全堆扫描**：只扫描脏卡
3. **年轻代优化**：跳过年轻代卡的写后屏障
4. **线程本地队列**：减少锁竞争
5. **三种实现**：解释器/C1/C2 各有优化版本
