# G1RemSet 源码深度解析

> **学习目标**：深入理解 G1 GC 的 Remembered Set（记忆集）机制，掌握跨 Region 引用的追踪原理。

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文对 **G1RemSet 源码深度解析** 进行源码级分析：追踪关键函数的执行路径，分析涉及的数据结构，解释每个设计决策的原因。

### 0.2 为什么需要？

仅靠文档和注释无法完全理解 JVM 的行为——很多关键细节只存在于源码中。源码级分析能建立对 JVM 行为的精确理解。

### 0.3 怎么解决？

从入口函数出发，自顶向下追踪调用链；对每个关键函数，分析其输入/输出/副作用；对每个数据结构，分析其字段含义和生命周期。

### 0.4 为什么这样设计？

分析过程中重点关注「为什么」：为什么选择这个数据结构？为什么这样处理边界情况？这些问题的答案往往揭示了 JVM 设计的精髓。

---


## 一、问题驱动：为什么需要 RSet？

### 1.1 场景：GC 时如何找到"谁引用了我"？

```
┌─────────────────────────────────────────────────────────────┐
│                    GC 核心问题                               │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  问题：当 GC 回收 Region A 时，如何知道                    │
│        哪些外部对象引用了 Region A 中的对象？               │
│                                                             │
│  示例：                                                     │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Region A (Eden)        Region B (Old)             │    │
│  │  ┌──────────────┐       ┌──────────────┐            │    │
│  │  │ Object A1   │ ←──── │ Object B1   │            │    │
│  │  │ (将被回收)   │       │ (老年代)    │            │    │
│  │  └──────────────┘       └──────────────┘            │    │
│  │                                                      │    │
│  │  GC 时：Region A 中的对象被 B1 引用                  │    │
│  │        不能回收 A1！                                  │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                             │
│  朴素方案：遍历整个堆                                        │
│  → 复杂度 O(堆大小)，太慢！                               │
│                                                             │
│  实际方案：每个 Region 维护 RSet                            │
│  → 只扫描 RSet，复杂度 O(RSet 大小)                       │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 二、G1RemSet 核心数据结构

### 2.1 G1RemSet 类定义

```cpp
// g1RemSet.hpp:69-88
class G1RemSet : public CHeapObj<mtGC> {
private:
    G1RemSetScanState *_scan_state;      // GC 期间的记忆集扫描状态
    G1RemSetSummary _prev_period_summary; // 统计信息
    
    G1CollectedHeap *_g1h;                // G1 堆引用
    size_t _num_conc_refined_cards;       // 并发精炼的卡数
    
    G1CardTable *_ct;                     // 卡表引用
    G1Policy *_g1p;                      // GC 策略引用
    G1HotCardCache *_hot_card_cache;      // 热卡缓存引用
};
```

### 2.2 RSet 存储架构

```
┌─────────────────────────────────────────────────────────────┐
│              G1 Remembered Set 三层存储架构                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  写入时：SparsePRT → 定时合并到 PerRegionTable              │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Layer 1: SparsePRT (稀疏表)                        │    │
│  │    - 新引用时先写入这里                             │    │
│  │    - 内存开销极小                                   │    │
│  │    - 满了则合并到 Layer 2                          │    │
│  └─────────────────────────────────────────────────────┘    │
│                          ↓ 合并                             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Layer 2: PerRegionTable ★ (细粒度表)             │    │
│  │    - 每个 Region 一个                               │    │
│  │    - 记录：哪个外部 Region 的哪张卡引用了我         │    │
│  │    - 空间换时间                                    │    │
│  └─────────────────────────────────────────────────────┘    │
│                          ↓ 备选                             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Layer 3: Coarse (粗粒度)                          │    │
│  │    - 整个 Region 级别                              │    │
│  │    - PerRegionTable 太多时降级                    │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 2.3 PerRegionTable 结构

```cpp
// heapRegionRemSet.cpp:45-65
class PerRegionTable: public CHeapObj<mtGC> {
    HeapRegion*     _hr;                    // 关联的 HeapRegion
    CHeapBitMap     _bm;                    // 位图，记录引用的卡
    jint            _occupied;              // 占用计数
    PerRegionTable* _next;                  // 分配链表 next
    PerRegionTable* _prev;                  // 分配链表 prev
    PerRegionTable* _collision_list_next;    // 哈希冲突链表
    static PerRegionTable* volatile _free_list;  // 空闲列表
};
```

---

## 三、写屏障：引用更新的核心机制

### 3.1 两类屏障

```
┌─────────────────────────────────────────────────────────────┐
│                    G1 写屏障类型                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. 写前屏障 (SATB Barrier)                               │
│     时机：引用被覆盖前                                      │
│     作用：记录旧值到 SATB 队列                              │
│     场景：并发标记阶段                                      │
│                                                             │
│  2. 写后屏障 (Card Barrier) ★                             │
│     时机：引用修改后                                       │
│     作用：标记卡表为脏                                      │
│     场景：跨 Region 引用赋值                               │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 写后屏障源码解析

```cpp
// g1BarrierSet.inline.hpp:48-55
// 引用赋值: obj->field = new_value; 会触发此函数
template <DecoratorSet decorators, typename T>
inline void G1BarrierSet::write_ref_field_post(T* field, oop new_val) {
    // 1. 获取字段对应的卡地址
    volatile jbyte* byte = _card_table->byte_for(field);
    
    // 2. 快速路径：如果是年轻代卡，直接返回
    if (*byte != G1CardTable::g1_young_card_val()) {
        // 3. 慢速路径：标记为脏
        write_ref_field_post_slow(byte);
    }
}
```

### 3.3 慢速路径

```cpp
// g1BarrierSet.cpp:156-170
void G1BarrierSet::write_ref_field_post_slow(volatile jbyte* card_ptr) {
    // 1. 标记卡为 dirty
    *card_ptr = G1CardTable::dirty_card_val();
    
    // 2. 获取当前线程的脏卡队列
    DirtyCardQueue& queue = _dirty_card_queue_set.thread_local_queue();
    
    // 3. 将脏卡入队，后续由 Refinement 线程处理
    queue.push(card_ptr);
}
```

---

## 四、引用更新流程

### 4.1 完整流程图

```
┌─────────────────────────────────────────────────────────────┐
│              跨 Region 引用赋值完整流程                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  应用线程:                                                  │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ obj_a.field = obj_b;  // A 在 Region X, B 在 Y    │    │
│  └─────────────────────────────────────────────────────┘    │
│                          ↓                                  │
│  编译器生成写后屏障:                                        │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ 1. 获取 field 对应的卡地址                          │    │
│  │ 2. if (卡不是 young) { 标记为脏, 入队 }           │    │
│  └─────────────────────────────────────────────────────┘    │
│                          ↓                                  │
│  脏卡队列:                                                 │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ [card_ptr1, card_ptr2, ..., card_ptrN]           │    │
│  └─────────────────────────────────────────────────────┘    │
│                          ↓                                  │
│  并发 Refinement 线程:                                     │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ 1. 从队列取出脏卡                                  │    │
│  │ 2. 遍历卡中的引用                                  │    │
│  │ 3. 更新目标 Region 的 RSet                         │    │
│  │ 4. 放入热卡缓存（如频繁）                          │    │
│  └─────────────────────────────────────────────────────┘    │
│                          ↓                                  │
│  RSet 更新:                                                 │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ Region Y 的 RSet 中增加一条记录：                  │    │
│  │ "Region X 的卡 K 引用了我"                         │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 时序图

```
时间 →
─────────────────────────────────────────────────────────────────→

应用线程                Refinement 线程              GC 线程
    │                         │                           │
    │ obj.a = new_obj;       │                           │
    │ [写后屏障]             │                           │
    │ ─────────────────→     │                           │
    │ card 入队              │                           │
    │                         │                           │
    │                   处理脏卡                        │
    │                   ──────────→                     │
    │                   更新 RSet                        │
    │                                                   │
    │                                                   │ YGC 开始
    │                                                   │ ──────→ 
    │                                                   │ 扫描 RSet
    │                                                   │ 找到引用
    │                                                   │ ←────────
    │                                                   │ 标记存活
    │                                                   │
```

---

## 五、G1RemSet::initialize() 分析

### 5.1 源码

```cpp
// g1RemSet.cpp:458-470
void G1RemSet::initialize(size_t capacity, uint max_regions) {
    // 1. 初始化 G1FromCardCache
    //    作用：记住每个 Region 在每个线程上最近处理的卡
    //    目的：避免重复处理相同的卡
    G1FromCardCache::initialize(num_par_rem_sets(), max_regions);
    
    // 2. 初始化扫描状态
    _scan_state->initialize(max_regions);
}
```

### 5.2 G1FromCardCache

```
┌─────────────────────────────────────────────────────────────┐
│              G1FromCardCache 作用                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  问题：多线程并发更新 RSet 时，可能重复处理同一张卡         │
│                                                             │
│  解决方案：每个线程缓存"最近处理过的卡"                     │
│                                                             │
│  结构：                                                     │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ Thread 1: Region[0] → last_processed_card = 5      │    │
│  │ Thread 2: Region[0] → last_processed_card = 8      │    │
│  │ Thread N: Region[N] → last_processed_card = K      │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                             │
│  效果：                                                     │
│  - 减少重复工作                                            │
│  - 提高并发效率                                            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 六、并发 Refinement 机制

### 6.1 热卡缓存

```cpp
// g1CollectedHeap.cpp:1747-1755
// 背景：
// - 频繁修改的"热卡"会反复进入脏卡队列
// - 每次都处理会浪费 CPU

// 解决方案：热卡缓存
_hot_card_cache = new G1HotCardCache(this);

// 效果：
// - 热卡先缓存
// - GC 暂停时批量处理
// - 减少重复工作
```

### 6.2 Refinement 线程

```
┌─────────────────────────────────────────────────────────────┐
│              并发 Refinement 线程                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  触发条件：                                                 │
│  - 脏卡队列达到阈值                                        │
│  - 定时任务                                                │
│                                                             │
│  处理流程：                                                 │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ 1. pop 脏卡                                          │    │
│  │ 2. 遍历卡中的引用 (oop_iterate)                     │    │
│  │ 3. 找到引用的目标 Region                             │    │
│  │ 4. 更新目标 Region 的 RSet                           │    │
│  │ 5. 如果卡很热，放入热卡缓存                          │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                             │
│  优化：                                                     │
│  - 多线程并行                                               │
│  - 自适应阈值                                               │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 七、GDB 验证

### 7.1 验证 RSet 初始化

```gdb
# 文件：gdb_verify_remset.txt
set pagination off
set print pretty on
set logging file /data/workspace/openjdk-cut-new/jvm-md/Universe/initialize-heap/tmp-file/gdb_remset.txt
set logging overwrite on
set logging on

file /data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java

# 在 RSet 初始化后打印信息
break G1RemSet::initialize
commands 1
  silent
  printf "\n========== G1RemSet 初始化 ==========\n"
  p max_regions
  p num_par_rem_sets()
  continue
end

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main
```

### 7.2 验证写屏障触发

```gdb
# 文件：gdb_verify_barrier.txt
set pagination off
set print pretty on
set logging file /data/workspace/openjdk-cut-new/jvm-md/Universe/initialize-heap/tmp-file/gdb_barrier.txt
set logging overwrite on
set logging on

file /data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java

# 写后屏障慢路径
break G1BarrierSet::write_ref_field_post_slow
commands 1
  silent
  printf "\n========== 写后屏障触发 ==========\n"
  printf "card_ptr = %p\n", card_ptr
  printf "*card_ptr = %d\n", *card_ptr
  continue
end

run -Xms8g -Xmx8g -XX:+UseG1GC -cp /data/workspace/demo/src com.wjcoder.Main
```

---

## 八、面试级 Q&A

### Q1：RSet 存什么？

**答**：

```
每个 Region 维护一个 RSet，记录：
"哪些外部 Region 引用了我？"

示例：
- Region A (Eden) 的 RSet 包含：
  → Region B (Old) 的卡 5 引用了我
  → Region C (Survivor) 的卡 12 引用了我
  → Region D (Old) 的卡 8 引用了我
```

---

### Q2：为什么需要三层存储？

**答**：

| 层级 | 优点 | 缺点 | 使用场景 |
|------|------|------|----------|
| SparsePRT | 内存开销极小 | 容量有限 | 新引用写入 |
| PerRegionTable | 查找 O(1) | 内存开销大 | 主流存储 |
| Coarse | 内存极小 | 扫描开销大 | 降级方案 |

**自适应策略**：
- 引用少 → SparsePRT
- 引用多 → PerRegionTable
- 引用太多 → 降级到 Coarse

---

### Q3：写屏障的性能影响？

**答**：

```
开销：
- 快速路径：~5 纳秒（检查 + 可能返回）
- 慢速路径：~50-100 纳秒（标记 + 入队）

优化：
- 年轻代卡直接返回（快速路径）
- 批量入队减少竞争
- 并发 Refinement 不阻塞应用
```

---

### Q4：RSet 的内存开销？

**答**：

```
8GB 堆 = 2048 个 Region

每个 Region 的 RSet：
- PerRegionTable: ~200-500 字节（平均）
- 极端情况：每个外部 Region 都引用 → ~16KB

总开销：
- 平均：~1-2 MB
- 极端：~32 MB (2KB × 16KB)

相比堆大小 (8GB)：
- 平均：~0.02%
- 极端：~0.4%
```

---

### Q5：为什么需要热卡缓存？

**答**：

```
问题：
- 某些卡被频繁修改（如热点代码）
- 每次都处理，重复工作

解决：
- 热卡先缓存
- GC 暂停时批量处理
- 减少 CPU 浪费
```

---

### Q6：Refinement 线程何时工作？

**答**：

```
触发条件：
1. 脏卡队列达到阈值
   → 阈值自适应调整
   
2. 定时任务
   → 定期检查和处理

3. GC 暂停前
   → 确保 RSet 最新

不阻塞应用线程：
- 使用独立队列
- 并发处理
```

---

### Q7：RSet 在 GC 时如何使用？

**答**：

```
YGC 流程：
1. 扫描 GC Roots
2. 遍历年轻代 Region 的 RSet
3. 找到老年代→年轻代的引用
4. 标记引用的对象为存活

为什么快？
- 不扫描整个老年代
- 只扫描"可能引用年轻代"的卡
- RSet 提供了精确的索引
```

---

## 九、总结

### 9.1 核心要点

| 概念 | 说明 |
|------|------|
| **RSet 作用** | 记录"谁引用了我"，加速跨 Region 引用查找 |
| **三层存储** | SparsePRT → PerRegionTable → Coarse |
| **写后屏障** | 引用赋值时标记脏卡 |
| **并发 Refinement** | 后台线程处理脏卡，更新 RSet |
| **热卡缓存** | 缓存频繁修改的卡，减少重复工作 |

### 9.2 性能数据

| 指标 | 数值 |
|------|------|
| 写屏障开销 | ~5-100 ns |
| RSet 内存开销 | ~1-2 MB (平均) |
| Refinement 线程 | 自适应（1-N 个） |

### 9.3 与其他组件的关系

```
┌─────────────────────────────────────────────────────────────┐
│                    G1 组件关系图                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   应用线程                                                  │
│       │                                                    │
│       ▼                                                    │
│   写后屏障 ──→ 脏卡队列 ──→ Refinement 线程              │
│       │                              │                      │
│       │                              ▼                      │
│       │                      G1RemSet 更新                │
│       │                              │                      │
│       ▼                              ▼                      │
│   G1CardTable ◄───────────────── PerRegionTable            │
│       │                                                    │
│       ▼                                                    │
│   GC 扫描 RSet ──→ 找到跨 Region 引用                     │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 十、参考资料

- G1RemSet：`/data/workspace/openjdk-cut-new/src/hotspot/share/gc/g1/g1RemSet.cpp`
- 写屏障：`/data/workspace/openjdk-cut-new/src/hotspot/share/gc/g1/g1BarrierSet.inline.hpp`
- PerRegionTable：`/data/workspace/openjdk-cut-new/src/hotspot/share/gc/g1/heapRegionRemSet.cpp`

---

**下一步**：分析 CardTable 的具体实现和并发精炼机制
