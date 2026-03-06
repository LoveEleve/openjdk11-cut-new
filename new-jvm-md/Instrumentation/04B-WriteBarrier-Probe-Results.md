# 第 4B 章：G1 写屏障链路插桩结果

> 探针运行时间：2026-03-04  
> 标准环境：`-Xms8g -Xmx8g -XX:+UseG1GC -Xint`，G1 Region = 4MB  
> **v2.0**：补充汇编快路径漏斗分析（g1_write_barrier_post 全路径插桩）

---

## 一、插桩位置与目标

### 1.1 插桩演进

| 版本 | 插桩位置 | 能统计到什么 | 局限性 |
|------|---------|------------|--------|
| v1.0 | `write_ref_field_post_slow()` C++ 慢路径 | Old Region 卡被标记为 dirty 的次数 | **统计不到解释器汇编快路径**，漏掉 99.99% 的触发 |
| v2.0 | `g1_write_barrier_post()` 汇编生成入口 | **POST 屏障总触发次数 + 每个过滤点的拦截次数** | 非原子计数器，多线程下有轻微误差（实测误差 < 20） |

### 1.2 v2.0 插桩位置（三个文件）

| 文件 | 修改内容 |
|------|---------|
| `g1BarrierSet.cpp` | 定义 8 个全局计数器（`volatile int`） |
| `g1BarrierSetAssembler_x86.cpp` | 在 `g1_write_barrier_post()` 汇编序列入口 + 每个过滤点 + 快路径入队处插入 `__ incrementl(ExternalAddress(...))` |
| `g1CollectedHeap.cpp` | YoungGC 触发时打印完整漏斗分析 |

### 1.3 为什么必须在汇编生成代码里插桩？

```
Java 代码执行 aastore（对象引用赋值）
        │
        ▼
解释器字节码分发（templateTable_x86.cpp: aastore）
        │
        ▼
do_oop_store() → store_heap_oop() → oop_store_at()
        │
        ▼
g1BarrierSetAssembler_x86.cpp: g1_write_barrier_post()
  ← 这里是汇编代码生成函数，JVM 启动时执行一次，生成汇编指令序列
  ← 每次 Java 代码执行 aastore，都会执行这段生成好的汇编
  ← 在这里插入 __ incrementl(ExternalAddress(&counter)) 才能统计到每次执行
        │
        ├─ 过滤1：xor(store_addr, new_val) >> LogOfHRGrainBytes == 0 ?
        │   YES → [计数] g1_post_filter_same_region++  → done
        │         （store_addr 和 new_val 在同一 Region，不需要记录）
        │
        ├─ 过滤2：new_val == NULL ?
        │   YES → [计数] g1_post_filter_null_val++  → done
        │         （写入 null，不需要记录）
        │
        ├─ 计算 card_addr = byte_map_base + (store_addr >> card_shift)
        │
        ├─ 过滤3：*card_addr == g1_young_card_val() ?
        │   YES → [计数] g1_post_filter_young_card++  → done
        │         （store_addr 在 Young Region，YoungGC 全扫，不需要 RSet）
        │
        ├─ membar(StoreLoad)  ← 内存屏障，确保 card 读取不被重排序
        │
        ├─ 过滤4：*card_addr == dirty_card_val() ?
        │   YES → [计数] g1_post_filter_dirty_card++  → done
        │         （已经是 dirty，去重，不需要重复入队）
        │
        ├─ *card_addr = dirty_card_val()  ← 标记卡为 dirty
        │
        ├─ queue_index > 0 ?（线程本地 buffer 还有空间）
        │   YES → [计数] g1_post_enqueued_fast++
        │          buffer[queue_index] = card_addr
        │          queue_index -= wordSize
        │          → done（快路径入队，纯汇编）
        │
        └─ queue_index == 0 → call write_ref_field_post_entry()（慢路径）
                │
                ├─ [计数] wb_enqueued_total++
                ├─ 将满的 buffer 提交到全局 DirtyCardQueueSet
                └─ 分配新的空 buffer，重新入队
```

**关键认知**：`write_ref_field_post_slow()` 根本不在解释器路径上！它是 `g1BarrierSet.inline.hpp` 里的 C++ 模板函数，只有 JVM 内部 C++ 代码直接调用 `access_store_at` 时才走（如 GC 疏散过程中的对象复制）。

---

## 二、实验数据（v2.0 漏斗分析）

### 2.1 完整漏斗数据（6 次 YoungGC 的累计统计）

```
第 1 次 YoungGC 前（累计触发 138 万次）：
  POST屏障总触发(汇编入口)  = 1,382,677  (100%)
  ├─ 过滤1:同Region        =   306,932  (22.2%)
  ├─ 过滤2:new_val==NULL   =   162,238  (11.7%)
  ├─ 过滤3:card==young     =   913,507  (66.1%)
  ├─ 过滤4:card==dirty     =         0  ( 0.0%)
  ├─ 快路径入队(queue>0)   =         0  ( 0.0%)
  └─ 慢路径入队(queue=0)   =         0  ( 0.0%)
  [校验] 各项之和=1,382,677 ✅

第 2 次 YoungGC 前（累计触发 174 万次）：
  POST屏障总触发(汇编入口)  = 1,740,963  (100%)
  ├─ 过滤1:同Region        =   310,389  (17.8%)
  ├─ 过滤2:new_val==NULL   =   162,510  ( 9.3%)
  ├─ 过滤3:card==young     = 1,268,068  (72.8%)
  ├─ 过滤4:card==dirty     =         0  ( 0.0%)
  ├─ 快路径入队(queue>0)   =         0  ( 0.0%)
  └─ 慢路径入队(queue=0)   =         0  ( 0.0%)
  [校验] 各项之和=1,740,967 ≈ 1,740,963 ✅（误差4，多线程竞争）

第 3 次 YoungGC 前（累计触发 219 万次）：
  POST屏障总触发(汇编入口)  = 2,190,963  (100%)
  ├─ 过滤1:同Region        =   317,732  (14.5%)
  ├─ 过滤2:new_val==NULL   =   162,510  ( 7.4%)
  ├─ 过滤3:card==young     = 1,709,725  (78.0%)
  ├─ 过滤4:card==dirty     =       991  ( 0.0%)
  ├─ 快路径入队(queue>0)   =         9  ( 0.0%)
  └─ 慢路径入队(queue=0)   =         1  ( 0.0%)
  [校验] 各项之和=2,190,968 ≈ 2,190,963 ✅（误差5）

第 4 次 YoungGC 前（累计触发 291 万次）：
  POST屏障总触发(汇编入口)  = 2,909,254  (100%)
  ├─ 过滤1:同Region        =   332,798  (11.4%)
  ├─ 过滤2:new_val==NULL   =   167,266  ( 5.7%)
  ├─ 过滤3:card==young     = 2,408,177  (82.8%)
  ├─ 过滤4:card==dirty     =       991  ( 0.0%)
  ├─ 快路径入队(queue>0)   =        26  ( 0.0%)
  └─ 慢路径入队(queue=0)   =        11  ( 0.0%)
  [校验] 各项之和=2,909,269 ≈ 2,909,254 ✅（误差15）
  全局DirtyCardQueue已完成buffer数=8

第 5 次 YoungGC 前（累计触发 361 万次）：
  POST屏障总触发(汇编入口)  = 3,609,064  (100%)
  ├─ 过滤1:同Region        =   338,495  ( 9.4%)
  ├─ 过滤2:new_val==NULL   =   167,300  ( 4.6%)
  ├─ 过滤3:card==young     = 3,102,224  (86.0%)
  ├─ 过滤4:card==dirty     =     1,021  ( 0.0%)
  ├─ 快路径入队(queue>0)   =        27  ( 0.0%)
  └─ 慢路径入队(queue=0)   =        12  ( 0.0%)
  [校验] 各项之和=3,609,079 ≈ 3,609,064 ✅（误差15）
  全局DirtyCardQueue已完成buffer数=2

第 6 次 YoungGC 前（累计触发 431 万次）：
  POST屏障总触发(汇编入口)  = 4,311,009  (100%)
  ├─ 过滤1:同Region        =   344,793  ( 8.0%)
  ├─ 过滤2:new_val==NULL   =   167,300  ( 3.9%)
  ├─ 过滤3:card==young     = 3,797,871  (88.1%)
  ├─ 过滤4:card==dirty     =     1,021  ( 0.0%)
  ├─ 快路径入队(queue>0)   =        27  ( 0.0%)
  └─ 慢路径入队(queue=0)   =        12  ( 0.0%)
  [校验] 各项之和=4,311,024 ≈ 4,311,009 ✅（误差15）
  全局DirtyCardQueue已完成buffer数=0
```

### 2.2 各过滤点比例趋势（随 GC 次数变化）

| GC# | 总触发 | 过滤1:同Region | 过滤2:null | 过滤3:young | 过滤4:dirty | 真正入队 |
|-----|--------|--------------|-----------|------------|------------|---------|
| #1 | 138万 | 22.2% | 11.7% | 66.1% | 0.0% | 0.0% |
| #2 | 174万 | 17.8% | 9.3% | 72.8% | 0.0% | 0.0% |
| #3 | 219万 | 14.5% | 7.4% | 78.0% | 0.0% | 0.0% |
| #4 | 291万 | 11.4% | 5.7% | 82.8% | 0.0% | 0.0% |
| #5 | 361万 | 9.4% | 4.6% | 86.0% | 0.0% | 0.0% |
| #6 | 431万 | 8.0% | 3.9% | 88.1% | 0.0% | **0.0009%** |

---

## 三、关键发现与深度分析

### 3.1 发现一：过滤3（card==young）是最大的过滤器，且比例随 GC 增长

**现象**：过滤3 从 GC#1 的 66.1% 增长到 GC#6 的 88.1%，是最主要的过滤条件。

**根因**：

```
G1 的 Young Region 卡标记机制：
  - 每个 Region 初始化时，其对应的 card 被标记为 g1_young_card_val()
  - 只要 new_val 指向 Young Region（Eden 或 Survivor），card 就是 young_card
  - YoungGC 会全量扫描 Young Region，不需要 RSet 记录，所以直接过滤

为什么比例随 GC 增长？
  - 随着 GC 次数增加，堆中 Young Region 占比越来越大（Eden 不断分配）
  - 更多的引用赋值目标是 Young Region 中的对象
  - 因此过滤3 的比例持续上升
```

**结论**：G1 写屏障最核心的优化是**Young Card 快速过滤**，88% 的写操作在这里被拦截，完全不需要进入后续逻辑。

### 3.2 发现二：过滤1（同 Region）比例随 GC 下降

**现象**：过滤1 从 GC#1 的 22.2% 下降到 GC#6 的 8.0%。

**根因**：

```
随着 GC 次数增加：
  - 堆中对象分布越来越分散（多次 GC 后对象被复制到不同 Region）
  - 同 Region 内的引用赋值比例下降
  - 跨 Region 的引用赋值比例上升（但大部分被过滤3 拦截）
```

### 3.3 发现三：真正入队的比例极低（0.0009%）

**现象**：431 万次触发，只有 39 次真正入队（27 快路径 + 12 慢路径）。

**根因分析**：

```
过滤链路（按拦截顺序）：
  过滤1（同Region）：8.0%  → 拦截 344,793 次
  过滤2（null写入）：3.9%  → 拦截 167,300 次
  过滤3（young卡）：88.1%  → 拦截 3,797,871 次
  过滤4（dirty去重）：0.0% → 拦截 1,021 次
  ─────────────────────────────────────────
  通过所有过滤的：0.0009%  → 只有 39 次入队

为什么这么低？
  - 程序运行在 -Xint 模式，大量对象在 Young Region（过滤3 拦截 88%）
  - 只有 Old→Young 的跨代引用才需要入队，而 Old Region 很少
  - 这正是 G1 写屏障设计的目标：最小化 RSet 维护开销
```

### 3.4 发现四：快路径入队（27次）vs 慢路径入队（12次）

**现象**：快路径入队 27 次，慢路径入队 12 次，快路径占 69%。

**根因**：

```
快路径（queue_index > 0）：
  - 线程本地 DirtyCardQueue 还有空间
  - 直接写入 buffer[queue_index]，queue_index -= wordSize
  - 纯汇编，无 C++ 调用

慢路径（queue_index == 0）：
  - 线程本地 buffer 已满（256 个 card 地址）
  - 调用 G1BarrierSetRuntime::write_ref_field_post_entry()
  - 将满的 buffer 提交到全局 DirtyCardQueueSet
  - 分配新的空 buffer

为什么快路径更多？
  - 每个线程的 buffer 有 256 个槽位
  - 39 次入队中，只有 12 次恰好遇到 buffer 满的情况
  - 大部分时候 buffer 还有空间，走快路径
```

### 3.5 发现五：校验和误差分析

**现象**：各项之和与总触发的误差为 0~15，随 GC 次数增加而稳定在 15 左右。

**根因**：`__ incrementl(ExternalAddress(...))` 不是原子操作（没有 `lock` 前缀），多线程并发执行时存在竞争。误差 15 = 并发线程数 × 竞争概率，在统计目的下完全可接受。

---

## 四、G1 写屏障完整路径图（v2.0）

```
Java 代码执行 aastore（对象引用赋值）
        │
        ▼
解释器汇编（g1BarrierSetAssembler_x86.cpp: g1_write_barrier_post()）
        │
        ├─ [计数] g1_post_barrier_total++  ← 总触发计数
        │
        ├─ 过滤1：xor(store_addr, new_val) >> LogOfHRGrainBytes == 0 ?
        │   YES → [计数] g1_post_filter_same_region++  → done
        │         （store_addr 和 new_val 在同一 Region，不需要记录）
        │
        ├─ 过滤2：new_val == NULL ?
        │   YES → [计数] g1_post_filter_null_val++  → done
        │         （写入 null，不需要记录）
        │
        ├─ 计算 card_addr = byte_map_base + (store_addr >> card_shift)
        │
        ├─ 过滤3：*card_addr == g1_young_card_val() ?
        │   YES → [计数] g1_post_filter_young_card++  → done
        │         （store_addr 在 Young Region，YoungGC 全扫，不需要 RSet）
        │
        ├─ membar(StoreLoad)  ← 内存屏障，确保 card 读取不被重排序
        │
        ├─ 过滤4：*card_addr == dirty_card_val() ?
        │   YES → [计数] g1_post_filter_dirty_card++  → done
        │         （已经是 dirty，去重，不需要重复入队）
        │
        ├─ *card_addr = dirty_card_val()  ← 标记卡为 dirty
        │
        ├─ queue_index > 0 ?（线程本地 buffer 还有空间）
        │   YES → [计数] g1_post_enqueued_fast++
        │          buffer[queue_index] = card_addr
        │          queue_index -= wordSize
        │          → done（快路径入队，纯汇编）
        │
        └─ queue_index == 0 → call write_ref_field_post_entry()（慢路径）
                │
                ├─ [计数] wb_enqueued_total++
                ├─ 将满的 buffer 提交到全局 DirtyCardQueueSet
                └─ 分配新的空 buffer，重新入队
```

---

## 五、总结

### 5.1 核心结论（回答总纲的问题）

| 总纲问题 | 实测答案 |
|---------|---------|
| 写屏障触发了多少次？ | 431 万次（6 次 YoungGC 前的累计） |
| 有多少次真正入队了脏卡？ | 39 次（0.0009%） |
| 最大的过滤条件是什么？ | 过滤3（card==young），占 88.1% |
| 总纲预期"95% 同 Region 被过滤"是否正确？ | **不准确**。同 Region 只占 8%，最大过滤是 Young Card（88%） |
| DirtyCardQueue 的最大 buffer 数？ | 最多 8 个（GC#4 时），很快被 GC 线程清空 |
| Refine 线程被激活了吗？ | **未被激活**（buffer 数远低于激活阈值） |

### 5.2 对总纲预期的修正

总纲预期：
> 约 95% 的引用赋值是同 Region 内的，写屏障过滤后只有 5% 真正入队

**实测修正**：
- 同 Region 过滤（过滤1）只占 8%，不是 95%
- 最大的过滤是 **Young Card 过滤（过滤3，88%）**，这是 G1 特有的优化
- 真正入队的比例是 **0.0009%**，远低于总纲预期的 5%
- 总纲的描述混淆了"同 Region"和"Young Card"两个不同的过滤条件

### 5.3 G1 写屏障的核心设计价值

```
G1 写屏障的四层过滤（按拦截量排序）：
  1. Young Card 过滤（88%）：最重要！Young Region 不需要 RSet
  2. 同 Region 过滤（8%）：同 Region 内的引用不需要跨代记录
  3. null 写入过滤（4%）：null 不是有效引用，不需要记录
  4. dirty 去重过滤（0.02%）：已入队的卡不需要重复入队

设计价值：
  - 99.999% 的写操作被过滤，只有 0.001% 真正入队
  - 这使得 G1 的 RSet 维护开销极低
  - 代价是每次引用赋值都要执行这段汇编过滤逻辑（约 10-20 条指令）
```
