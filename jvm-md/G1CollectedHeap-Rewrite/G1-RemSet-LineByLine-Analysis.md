# G1 RemSet (Remembered Set) 逐行深度源码分析

> **分析目标**: G1跨Region引用追踪核心机制  
> **源码文件**: 
> - `src/hotspot/share/gc/g1/g1RemSet.cpp/hpp`
> - `src/hotspot/share/gc/g1/heapRegionRemSet.cpp/hpp`  
> **分析标准**: 面试级深度 - 逐行解释 + 面试问答 + GDB调试技巧

---

## 第1章: RemSet核心概念与设计

### 1.1 为什么需要RemSet

**问题背景：**
```
+------------------------------------------------------------------+
|                    跨Region引用问题                               |
+------------------------------------------------------------------+
|                                                                   |
|  场景：Young GC只回收年轻代Region                                  |
|                                                                   |
|  ┌─────────────┐         ┌─────────────┐                         │
|  │   Region A  │────────>│   Region B  │                         │
|  │  (Old)      │ 引用    │  (Young)    │                         │
|  │             │         │  在CSet中   │                         │
|  │  obj_a      │────────>│  obj_b      │                         │
|  │    ↓        │         │             │                         │
|  │  field ─────┘         │             │                         │
|  └─────────────┘         └─────────────┘                         │
|                                                                   |
|  问题：如果Region B在CSet中（被回收），如何知道obj_b被引用？         │
|                                                                   |
|  方案1：扫描整个Old区                                              │
|  - 需要扫描所有Old Region                                          │
|  - Young GC暂停时间无法控制                                         │
|  - 不可行                                                          │
|                                                                   |
|  方案2：RemSet（G1选择）                                           │
|  - Region B维护一个集合，记录哪些Region引用了自己                    │
|  - Young GC只扫描这些Region的RSet                                  │
|  - O(1)定位引用来源                                                │
+------------------------------------------------------------------+
```

### 1.2 RemSet核心设计

```
+------------------------------------------------------------------+
|                    RemSet设计原则                                 |
+------------------------------------------------------------------+
|                                                                   |
|  每个Region有一个HeapRegionRemSet                                  │
|                                                                   |
|  HeapRegionRemSet记录：                                            │
|  "哪些其他Region有指针指向我"                                       │
|                                                                   |
|  示例：                                                            │
|  Region B的RSet = {Region A, Region C, Region D}                   │
|  表示：A、C、D三个Region都有引用指向B中的对象                        │
|                                                                   |
|  写屏障责任：                                                      │
|  当 obj_a.field = obj_b 时（跨Region引用）                          │
|  1. 找到obj_b所在的Region（Region B）                               │
|  2. 在Region B的RSet中添加Region A                                  │
|  3. 记录具体的卡（Card）位置                                        │
+------------------------------------------------------------------+
```

---

## 第2章: G1RemSet类结构

### 2.1 G1RemSet类定义

```cpp
69: class G1RemSet : public CHeapObj<mtGC> {
70: private:
71:     G1RemSetScanState *_scan_state;
72:     G1RemSetSummary _prev_period_summary;
73:
77:     void scan_rem_set(G1ParScanThreadState *pss, uint worker_i);
81:     void update_rem_set(G1ParScanThreadState *pss, uint worker_i);
83:     G1CollectedHeap *_g1h;
84:     size_t _num_conc_refined_cards;
86:     G1CardTable *_ct;
87:     G1Policy *_g1p;
88:     G1HotCardCache *_hot_card_cache;
```

**核心组件：**

| 字段 | 类型 | 作用 |
|------|------|------|
| `_scan_state` | G1RemSetScanState* | GC期间RSet扫描状态 |
| `_ct` | G1CardTable* | 卡表，用于脏卡检测 |
| `_hot_card_cache` | G1HotCardCache* | 热卡缓存，优化频繁修改的卡 |

### 2.2 oops_into_collection_set_do - RSet扫描入口

```cpp
117: void oops_into_collection_set_do(G1ParScanThreadState *pss, uint worker_i);
```

**调用时机：**
```
Young GC / Mixed GC
  └─ evacuate_collection_set()
       └─ G1ParTask::work()
            └─ g1_rem_set()->oops_into_collection_set_do(pss, worker_id)
                 ├─ scan_rem_set()      // 扫描RSet
                 └─ update_rem_set()    // 更新RSet
```

---

## 第3章: HeapRegionRemSet - Region级RSet

### 3.1 OtherRegionsTable三层结构

```cpp
74: class OtherRegionsTable {
82:   CHeapBitMap _coarse_map;           // 粗粒度位图
86:   PerRegionTable** _fine_grain_regions; // 细粒度表
94:   PerRegionTable * _first_all_fine_prts; // 细粒度PRT链表
```

**三层存储策略：**

```
+------------------------------------------------------------------+
|                    RemSet三层存储结构                             |
+------------------------------------------------------------------+
|                                                                   |
|  目标：平衡查询速度和内存占用                                        │
|                                                                   |
|  第1层：Coarse Map（粗粒度位图）                                    │
|  ├─ 每个bit对应一个Region                                          │
|  ├─ bit=1表示该Region可能有引用指向我                               │
|  ├─ 内存占用：2048 bits = 256 bytes（8GB堆）                        │
|  └─ 查询时需要扫描整个Region                                         │
|                                                                   |
|  第2层：Fine Grain Table（细粒度表）                                │
|  ├─ 哈希表，记录具体哪些卡有引用                                     │
|  ├─ 精确到512字节的卡                                               │
|  ├─ 内存占用较大，但查询精确                                        │
|  └─ 当引用密集时使用                                                │
|                                                                   |
|  第3层：Sparse Table（稀疏表）                                      │
|  ├─ 记录少量的跨Region引用                                          │
|  ├─ 内存占用最小                                                    │
|  └─ 当引用很少时使用                                                │
|                                                                   |
|  自动降级：                                                         │
|  当细粒度表条目过多时，降级为粗粒度位图                               │
+------------------------------------------------------------------+
```

### 3.2 添加引用记录

```cpp
// 当发生跨Region引用时调用
void add_reference(HeapRegion* from_region, HeapWord* from_card) {
    // 1. 检查是否已存在粗粒度记录
    if (_coarse_map.at(from_region->hrm_index())) {
        return;  // 已记录，无需重复
    }
    
    // 2. 尝试添加到细粒度表
    PerRegionTable* prt = find_per_region_table(from_region);
    if (prt != NULL) {
        prt->add_card(from_card);  // 记录具体卡
        return;
    }
    
    // 3. 细粒度表满，降级为粗粒度
    if (_n_fine_entries >= _max_fine_entries) {
        coarsen_entry(from_region);  // 标记粗粒度位图
        return;
    }
    
    // 4. 创建新的细粒度表项
    prt = new PerRegionTable(from_region);
    prt->add_card(from_card);
    add_to_fine_grain_table(prt);
}
```

---

## 第4章: 写屏障与RSet更新

### 4.1 写后屏障

```cpp
// 写后屏障代码（简化）
void post_write_barrier(oop* field, oop new_value) {
    // 1. 获取field所在的卡
    HeapWord* field_addr = (HeapWord*)field;
    CardValue* card = card_table->byte_for(field_addr);
    
    // 2. 标记卡为脏
    *card = dirty_card;
    
    // 3. 检查是否跨Region引用
    HeapRegion* from_region = heap->heap_region_containing(field_addr);
    HeapRegion* to_region = heap->heap_region_containing(new_value);
    
    if (from_region != to_region) {
        // 4. 更新目标Region的RSet
        to_region->rem_set()->add_reference(from_region, field_addr);
    }
}
```

**写屏障执行流程：**
```
+------------------------------------------------------------------+
|                    写后屏障执行流程                                 |
+------------------------------------------------------------------+
|                                                                   |
|  Java: obj.field = new_val;                                       │
|                                                                   |
|  编译后：                                                          │
|  1. 写入对象引用                                                   │
|     mov [obj + field_offset], new_val                             │
|                                                                   |
|  2. 写后屏障（插入的代码）                                          │
|     ├─ 计算卡地址：card = (addr >> 9) + card_table_base          │
|     ├─ 标记脏卡：*card = 0x1                                      │
|     ├─ 检查跨Region                                                │
|     └─ 更新RSet：to_region->rem_set()->add_reference(...)         │
|                                                                   |
|  开销：                                                            │
|  - 无跨Region：~10个CPU周期                                        │
|  - 有跨Region：~100个CPU周期（需要更新RSet）                        │
+------------------------------------------------------------------+
```

---

## 第5章: RSet扫描与GC

### 5.1 scan_rem_set - RSet扫描

```cpp
void G1RemSet::scan_rem_set(G1ParScanThreadState* pss, uint worker_i) {
    // 遍历CSet中的每个Region
    _g1h->collection_set_iterate_from([&](HeapRegion* region) {
        // 获取该Region的RSet
        HeapRegionRemSet* rem_set = region->rem_set();
        
        // 遍历RSet中记录的引用来源
        rem_set->iterate([&](HeapRegion* from_region, CardValue* card) {
            // 扫描该卡中的对象
            scan_card(card, region, pss);
        });
    }, worker_i);
}
```

**RSet扫描流程：**
```
+------------------------------------------------------------------+
|                    RSet扫描流程                                   |
+------------------------------------------------------------------+
|                                                                   |
|  Young GC时：                                                      │
|  1. 获取CSet中的Region B                                           │
|  2. 获取Region B的RSet                                             │
|     RSet = {Region A, Region C}                                    │
|  3. 只扫描Region A和C中RSet记录的卡                                 │
|  4. 找到引用obj_b的obj_a                                           │
|  5. 如果obj_b被移动，更新obj_a.field                               │
|                                                                   |
|  优势：                                                            │
|  - 不需要扫描整个Old区                                             │
|  - 只扫描有引用的Region                                            │
|  - 只扫描有引用的卡（512字节粒度）                                  │
+------------------------------------------------------------------+
```

---

## 第6章: 并发细化与RSet优化

### 6.1 并发细化线程

```cpp
// G1ConcurrentRefineThread
void run() {
    while (!should_terminate()) {
        // 1. 获取脏卡队列
        DirtyCardQueue* dcq = get_dirty_card_queue();
        
        // 2. 处理脏卡
        while (!dcq->is_empty()) {
            CardValue* card = dcq->pop();
            refine_card(card);  // 更新RSet
        }
        
        // 3. 等待更多脏卡
        wait_for_cards();
    }
}
```

**并发细化目的：**
```
+------------------------------------------------------------------+
|                    并发细化目的                                   |
+------------------------------------------------------------------+
|                                                                   |
|  问题：                                                            │
|  - 应用线程频繁修改对象引用                                        │
|  - 每次修改都触发写屏障                                            │
|  - 如果立即更新RSet，竞争激烈                                       │
|                                                                   |
|  解决方案：                                                        │
|  1. 写屏障只标记卡为脏，不立即更新RSet                              │
|  2. 脏卡加入队列                                                    │
|  3. 并发细化线程异步处理脏卡                                         │
|  4. 更新对应的RSet                                                  │
|                                                                   |
|  优势：                                                            │
|  - 减少写屏障开销                                                  │
|  - 异步处理不阻塞应用线程                                           │
|  - 批量处理提高效率                                                │
+------------------------------------------------------------------+
```

---

## RemSet核心总结

```
+==================================================================+
|              G1 RemSet 核心机制总结                                |
+==================================================================+
|                                                                   |
|  1. 设计目标                                                       │
|     └─ 快速定位跨Region引用，避免全堆扫描                           │
|                                                                   |
|  2. 数据结构                                                       │
|     ├─ 每个Region一个HeapRegionRemSet                              │
|     ├─ 三层存储：Coarse -> Fine -> Sparse                          │
|     └─ 自动降级平衡内存和速度                                        │
|                                                                   |
|  3. 更新机制                                                       │
|     ├─ 写后屏障检测跨Region引用                                     │
|     ├─ 标记脏卡 + 加入队列                                          │
|     └─ 并发细化线程异步更新RSet                                     │
|                                                                   |
|  4. 使用场景                                                       │
|     ├─ Young GC：扫描CSet Region的RSet                             │
|     ├─ Mixed GC：扫描CSet Region的RSet                             │
|     └─ 并发标记：更新RSet                                           │
|                                                                   |
|  5. 性能优化                                                       │
|     ├─ 热卡缓存（Hot Card Cache）                                  │
|     ├─ 批量处理脏卡                                                 │
|     └─ 粗粒度位图减少内存占用                                        │
|                                                                   |
+==================================================================+
```

---

**面试高频问题Q&A：**

**Q1: RemSet和Card Table有什么区别？**
```
A: 两者互补，不是替代关系：

Card Table（卡表）：
- 全局结构，覆盖整个堆
- 记录"哪些内存区域被修改过"
- 写屏障直接操作
- 用于并发标记和Young GC

RemSet（记忆集）：
- 每个Region独立
- 记录"哪些Region引用了我"
- 通过Card Table间接更新
- 用于Young GC时快速定位引用

关系：
写屏障 -> 标记Card Table -> 并发细化 -> 更新RemSet
```

**Q2: 为什么RemSet需要三层存储？**
```
A: 平衡内存占用和查询效率：

场景1：少量跨Region引用
- 使用Sparse Table
- 内存占用最小

场景2：中等数量引用
- 使用Fine Grain Table
- 精确到卡，查询快

场景3：大量引用
- 使用Coarse Map
- 避免Fine Table过大
- 牺牲精度换取内存

自动降级：
当Fine Table条目过多时，自动降级为Coarse Map
```

---

**GDB调试脚本：**

```bash
# verify_remeset.gdb
set pagination off

break G1RemSet::oops_into_collection_set_do
break HeapRegionRemSet::add_reference
break G1RemSet::scan_rem_set

run -Xms8g -Xmx8g -XX:+UseG1GC -XX:+PrintGCDetails

# 查看Region的RSet
p region->rem_set()

# 查看RSet统计
p _coarse_map
p _n_fine_entries

# 查看卡表
p _ct

continue
quit
```

---

**文档完成**

本文档完成了G1 RemSet的逐行深度分析，涵盖：
- RemSet设计原理与核心概念
- G1RemSet类结构
- HeapRegionRemSet三层存储
- 写屏障与RSet更新
- RSet扫描与GC
- 并发细化优化

至此，G1 GC核心模块重写分析全部完成！
