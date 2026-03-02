# CardTable 源码深度解析

> **学习目标**：深入理解 G1 GC 的 CardTable（卡表）机制，掌握跨代引用的标记和扫描原理。

---

## 一、问题驱动：为什么需要 CardTable？

### 1.1 场景：YGC 时如何快速找到老年代→年轻代的引用？

```
┌─────────────────────────────────────────────────────────────┐
│                    YGC 核心问题                               │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  问题：YGC 只回收年轻代，但年轻代可能被老年代引用            │
│                                                             │
│  示例：                                                     │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Old Region           Young Region (Eden)           │    │
│  │  ┌──────────┐        ┌──────────┐                 │    │
│  │  │ Object A │────────→│ Object B │                 │    │
│  │  │ (老年代) │        │ (新分配)  │                 │    │
│  │  └──────────┘        └──────────┘                 │    │
│  │                                                      │    │
│  │  GC Roots: A → B                                    │    │
│  │  如果只扫描 Young，无法找到 B                       │    │
│  │  B 会被错误回收！                                   │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                             │
│  朴素方案：扫描整个老年代                                   │
│  → O(老年代大小)，太慢！                                   │
│                                                             │
│  实际方案：CardTable 记录"脏卡"                            │
│  → 只扫描"可能引用年轻代"的卡                              │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 二、CardTable 核心概念

### 2.1 卡表的本质

```
┌─────────────────────────────────────────────────────────────┐
│                    卡表 (Card Table)                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  定义：将堆内存划分为固定大小的"卡"(512字节)               │
│       每张卡对应卡表中 1 字节                              │
│                                                             │
│  结构：                                                     │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  堆内存 (8GB)                                        │    │
│  │  ┌────────┬────────┬────────┬────────┐               │    │
│  │  │ 512B  │ 512B  │ 512B  │ 512B  │  ...          │    │
│  │  └───┬────┴───┬────┴───┬────┴───┬────┘               │    │
│  │      │        │        │        │                      │    │
│  │      ▼        ▼        ▼        ▼                      │    │
│  │  ┌─────┬─────┬─────┬─────┐                          │    │
│  │  │ 1B  │ 1B  │ 1B  │ 1B  │  ... (16MB)          │    │
│  │  └──┬──┴──┬──┴──┬──┴──┬─┘                          │    │
│  │     │     │     │     │                            │    │
│  │     ▼     ▼     ▼     ▼                            │    │
│  │   卡表数组 (每个字节记录对应堆卡的状态)              │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                             │
│  卡大小：512 字节（硬件对齐，优化性能）                     │
│  卡表大小：堆大小 / 512 = 16MB (8GB堆)                    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 卡值定义

```cpp
// cardTable.hpp:96-107
enum CardValues {
    clean_card       = -1,    // 干净卡（无引用）
    dirty_card       =  0,    // 脏卡（有引用需要处理）
    precleaned_card  =  1,    // 预清洗卡
    claimed_card     =  2,    // 已扫描卡
    deferred_card    =  4,    // 延迟处理卡
    last_card        =  8,    // 守护卡
    CT_MR_BS_last_reserved = 16
};

// g1CardTable.hpp:53-55
enum G1CardValues {
    g1_young_gen = CT_MR_BS_last_reserved << 1  // = 32，年轻代卡
};
```

### 2.3 卡值状态机

```
┌─────────────────────────────────────────────────────────────┐
│                    卡值状态转换                                │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  初始化: clean_card (-1)                                    │
│       ↓                                                     │
│       │ 引用赋值时                                         │
│       ▼                                                     │
│  dirty_card (0) ──────→ 并发 Refinement 处理               │
│       │                                                     │
│       │ 处理完成                                            │
│       ▼                                                     │
│  clean_card (-1) 或                                          │
│  claimed_card (2)                                            │
│       │                                                     │
│       │ GC 扫描时                                          │
│       ▼                                                     │
│  claimed_card (2) ──→ 本次 GC 结束 ──→ clean_card (-1)     │
│                                                             │
│  特殊: g1_young_gen (32)                                    │
│    - 年轻代 Region 专属                                     │
│    - 快速路径：检查到年轻代卡直接返回                       │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 三、核心函数解析

### 3.1 byte_for() - 地址转卡索引

```cpp
// cardTable.hpp:156-165
// 将堆地址转换为卡表条目地址
jbyte* byte_for(const void* p) const {
    // 计算公式：地址 >> 9 (512 = 2^9)
    jbyte* result = &_byte_map_base[uintptr_t(p) >> card_shift];
    return result;
}

// 常量定义
static const int card_shift = 9;           // 2^9 = 512
static const int card_size = 1 << 9;       // 512 字节
static const int card_size_in_words = 512 / 8 = 64;  // 64 个 HeapWord
```

### 3.2 地址转卡计算过程

```
示例：地址 0x0000000600001000

1. 右移 9 位 (除以 512):
   0x0000000600001000 >> 9 = 0x00000006000020

2. 作为索引访问卡表:
   byte_map_base[0x00000006000020]

3. 等价计算:
   卡索引 = (地址 - 卡表基址) / 512
```

### 3.3 write_ref_field_post() - 写后屏障

```cpp
// g1BarrierSet.inline.hpp:48-55
// 引用赋值时触发
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

---

## 四、CardTable 初始化

### 4.1 初始化流程

```
G1CollectedHeap::initialize()
    ↓
G1CardTable *ct = new G1CardTable(reserved_region());
    ↓
ct->initialize();
    ↓
_card_table->initialize(cardtable_storage);
```

### 4.2 G1CardTable 构造函数

```cpp
// g1CardTable.hpp:60-71
G1CardTable(MemRegion whole_heap): CardTable(whole_heap, true), _listener() {
    // 设置监听器，用于 Region 提交时自动清理卡表
    _listener.set_card_table(this);
}
```

### 4.3 初始化监听器

```cpp
// g1CardTable.cpp:68-72
// 当 G1 Region 提交内存时，自动清理对应的卡表区域
void G1CardTableChangedListener::on_commit(uint start_idx, size_t num_regions, bool zero_filled) {
    // 将对应的卡表区域设置为 clean_card (-1)
    _card_table->clear_range(start_idx, start_idx + num_regions);
}
```

---

## 五、卡表与 RSet 的协作

### 5.1 协作流程

```
┌─────────────────────────────────────────────────────────────┐
│              CardTable + RSet 协作流程                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. 引用赋值                                               │
│     obj_a.field = obj_b;  // A 在 Old, B 在 Young         │
│          ↓                                                    │
│     写后屏障触发                                             │
│          ↓                                                    │
│     卡表中标记 dirty (0)                                    │
│                                                             │
│  2. 并发 Refinement                                        │
│     Refinement 线程处理脏卡                                  │
│          ↓                                                    │
│     遍历卡中的引用                                          │
│          ↓                                                    │
│     更新目标 Region 的 RSet                                  │
│                                                             │
│  3. GC 扫描                                                │
│     扫描脏卡                                                │
│          ↓                                                    │
│     通过 RSet 找到跨 Region 引用                            │
│          ↓                                                    │
│     标记存活对象                                            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 为什么需要两层结构？

```
┌─────────────────────────────────────────────────────────────┐
│              CardTable vs RSet 职责分工                      │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  CardTable:                                                 │
│  - 粗粒度：记录"哪512字节的堆被修改"                        │
│  - 作用：快速筛选"需要扫描的卡"                            │
│  - 状态：干净 vs 脏                                         │
│                                                             │
│  RSet:                                                      │
│  - 细粒度：记录"哪个 Region 的哪张卡引用了我"               │
│  - 作用：精确找到跨 Region 引用                            │
│  - 结构：PerRegionTable + SparsePRT                         │
│                                                             │
│  协作：                                                     │
│  1. GC 时扫描 CardTable 的脏卡                             │
│  2. 对每个脏卡，通过 RSet 找到引用关系                    │
│  3. 标记被引用的对象为存活                                 │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 六、GDB 验证

### 6.1 验证卡表基本信息

```gdb
# 文件：gdb_verify_cardtable.txt
set pagination off
set print pretty on
set logging file /data/workspace/openjdk-cut-new/jvm-md/Universe/initialize-heap/tmp-file/gdb_cardtable_detail.txt
set logging overwrite on
set logging on

file /data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java

# 断点：CardTable 初始化后
break G1CardTable::initialize
commands 1
  silent
  printf "\n========== CardTable 验证 ==========\n"
  
  # 卡大小
  p CardTable::card_size
  p CardTable::card_shift
  
  # 卡值
  p CardTable::clean_card
  p CardTable::dirty_card
  p CardTable::claimed_card
  p G1CardTable::g1_young_gen
  
  # 卡表地址
  p ((G1CardTable*)Universe::heap()->card_table())
  p ((G1CardTable*)Universe::heap()->card_table())->_byte_map
  
  # 卡表大小
  p Universe::heap()->reserved_region().byte_size()
  
  # 计算卡数量 = 堆大小 / 512
  set $heap_size = Universe::heap()->reserved_region().byte_size()
  printf "卡数量 = %zu\n", $heap_size / 512
  
  continue
end

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main
```

### 6.2 JVM 日志验证

```bash
# 验证命令
/data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
    -Xms8g -Xmx8g -XX:+UseG1GC \
    -Xlog:gc+heap=debug \
    -version

# 预期输出
[debug][gc,heap] Card table byte_map: 0x0000000604000000 [0x0000000680000000)
[debug][gc,heap] Card page size: 512
```

---

## 七、面试级 Q&A

### Q1：CardTable 有什么用？

**答**：

```
记录老年代 → 年轻代的引用

原理：
- 堆划分为 512 字节的卡
- 引用赋值时标记"脏卡"
- GC 时只扫描脏卡
- 避免扫描整个老年代
```

---

### Q2：卡表和 RSet 有什么区别？

**答**：

| 特性 | CardTable | RSet |
|------|-----------|------|
| **粒度** | 512 字节 | Region 级别 |
| **作用** | 哪些卡被修改 | 谁引用了我 |
| **状态** | 干净/脏/年轻代 | PerRegionTable/SparsePRT |
| **用途** | 粗筛 | 精确定位 |

---

### Q3：为什么卡大小是 512 字节？

**答**：

```
1. 硬件对齐
   - 512 是常见的缓存行大小倍数
   - 优化 CPU 缓存命中

2. 权衡
   - 太小：卡表开销大
   - 太大：扫描精度低

3. 历史原因
   - 最初设计基于当时的硬件
   - 实践证明 512 是合理值
```

---

### Q4：写后屏障的性能影响？

**答**：

```
快速路径 (~5ns)：
- 检查卡值
- 如果是年轻代卡，直接返回

慢速路径 (~50ns)：
- 标记脏卡
- 脏卡入队

优化：
- 年轻代引用无需处理
- 批量入队减少竞争
- 并发 Refinement 不阻塞应用
```

---

### Q5：CardTable 的内存开销？

**答**：

```
8GB 堆：
- 卡大小：512 字节
- 卡数量：8GB / 512 = 16,777,216
- 卡表大小：16,777,216 字节 ≈ 16 MB

每张卡：1 字节

相比堆大小：~0.2%
```

---

### Q6：为什么需要 g1_young_gen 卡值？

**答**：

```
问题：年轻代对象引用年轻代对象，需要处理吗？

答案：不需要！

原因：
- YGC 会扫描整个年轻代
- 年轻代内部的引用会被自然遍历
- 不需要额外记录

优化：
- 写屏障检查到年轻代卡，直接返回
- 减少不必要的处理
- 提升性能
```

---

### Q7：脏卡如何被处理？

**答**：

```
处理流程：

1. 应用线程标记脏卡
   dirty_card_queue.push(card_ptr)

2. Refinement 线程处理
   - 从队列取出脏卡
   - 遍历卡中的对象引用
   - 更新目标 Region 的 RSet

3. GC 扫描
   - 扫描脏卡
   - 通过 RSet 找到跨 Region 引用
   - 标记存活对象
```

---

## 八、总结

### 8.1 核心要点

| 概念 | 说明 |
|------|------|
| **卡大小** | 512 字节 |
| **卡表大小** | 堆大小 / 512 |
| **卡值** | clean(-1), dirty(0), young(32) |
| **写后屏障** | 引用赋值时标记脏卡 |
| **快速路径** | 年轻代卡直接返回 |
| **内存开销** | ~0.2% 堆大小 |

### 8.2 性能数据

| 指标 | 数值 |
|------|------|
| 快速路径开销 | ~5 ns |
| 慢速路径开销 | ~50 ns |
| 卡表大小 | 16 MB (8GB 堆) |
| 卡数量 | 16,777,216 |

### 8.3 与其他组件的关系

```
┌─────────────────────────────────────────────────────────────┐
│                    组件关系图                                │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   应用线程                                                  │
│       │                                                    │
│       ▼                                                    │
│   写后屏障 → CardTable 标记脏卡                           │
│       │                                                    │
│       ▼                                                    │
│   脏卡队列 → Refinement 线程处理                          │
│       │                                                    │
│       ▼                                                    │
│   RSet 更新                                                │
│       │                                                    │
│       ▼                                                    │
│   GC 扫描脏卡 + RSet → 找到存活对象                       │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 九、参考资料

- CardTable 基类：`/data/workspace/openjdk-cut-new/src/hotspot/share/gc/shared/cardTable.hpp`
- G1CardTable：`/data/workspace/openjdk-cut-new/src/hotspot/share/gc/g1/g1CardTable.hpp`
- 写屏障：`/data/workspace/openjdk-cut-new/src/hotspot/share/gc/g1/g1BarrierSet.inline.hpp`

---

**下一步**：分析 Young GC 回收流程或并发标记机制
