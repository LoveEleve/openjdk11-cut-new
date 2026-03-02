# G1ConcurrentMark 专家级源码分析（概览篇）

> **文档定位**：Mixed GC 学习 - 第一阶段第 1 篇  
> **分析模式**：Read-TopDown（自顶向下）  
> **创建时间**：2026-02-11  

---

## 一、一句话总结

**G1ConcurrentMark 是 G1 垃圾收集器的"并发标记引擎"，它通过三色标记法和 SATB（Snapshot-At-The-Beginning）算法，在应用线程运行的同时并发地标记堆中的存活对象，为 Mixed GC 提供准确的存活信息，避免全堆扫描的巨大停顿。**

---

## 二、设计哲学：为什么需要并发标记？

### 2.1 问题背景

**Young GC 的局限**：
- Young GC 只回收年轻代（Eden + Survivor）
- 老年代（Old Region）占用持续增长
- 当老年代满了怎么办？

**传统 Full GC 的问题**：
```
场景：10GB 老年代需要回收
传统串行标记：
  - 扫描 10GB 堆内存
  - 耗时 5-10 秒
  - 应用完全停顿（STW）
  
结果：用户请求超时，系统不可用
```

### 2.2 核心挑战

| 挑战 | 说明 |
|------|------|
| **堆内存大** | 数十 GB 老年代，扫描耗时太长 |
| **应用不能停** | 长时间停顿会导致服务不可用 |
| **标记准确性** | 并发期间对象引用关系会变化 |
| **一致性保证** | 不能漏标（对象被回收）或错标（垃圾存活） |

### 2.3 G1 的解决方案

**并发标记**：
```
时间线：
  ├─ 初始标记（Initial Mark）：短暂 STW，标记根对象
  ├─ 并发标记（Concurrent Mark）：与应用并发，遍历对象图
  ├─ 最终标记（Remark）：短暂 STW，处理 SATB 队列
  └─ 清理（Cleanup）：回收完全空闲的 Region

优势：
  - 最大停顿 < 200ms（可配置）
  - 标记工作分散到并发阶段
  - 应用吞吐量影响 < 10%
```

---

## 三、核心概念：三色标记法

### 3.1 基本定义

| 颜色 | 含义 | 状态 |
|------|------|------|
| **白色** | 未访问 | 对象尚未被标记器访问 |
| **灰色** | 已访问，字段未处理 | 对象已标记，但其引用字段尚未扫描 |
| **黑色** | 已访问，字段已处理 | 对象及其所有可达对象都已标记 |

### 3.2 标记过程演示

```
初始状态（只有根对象灰色）：
  [Root] → [A] → [B]
    ↓
  [C]

  灰色：[Root]
  白色：[A], [B], [C]
  黑色：无

步骤1：处理 Root，标记 A 和 C 为灰色：
  [Root] → [A] → [B]
    ↓
  [C]

  灰色：[A], [C]
  黑色：[Root]

步骤2：处理 A，标记 B 为灰色：
  [Root] → [A] → [B]
    ↓
  [C]

  灰色：[B], [C]
  黑色：[Root], [A]

步骤3：处理 B（无新引用）：
  灰色：[C]
  黑色：[Root], [A], [B]

步骤4：处理 C（无新引用）：
  灰色：无
  黑色：[Root], [A], [B], [C]

结束：白色对象可被回收
```

### 3.3 并发标记的挑战：对象关系变化

```
问题场景：标记器扫描 A 时，应用修改引用

标记前：
  [Root] → [A] → [B] → [D]
              ↓
             [C]

标记器处理 A 后：
  - A 变为黑色
  - B、C 变为灰色

应用并发修改（SATB 写屏障拦截）：
  A.next = null  // B 不再是 A 的后继
  Root.next = B  // B 直接挂在 Root 下

如果不处理：
  - B 已经是灰色，会被正常处理
  - 但如果 A.next = C 改为 null，C 可能丢失

解决方案：SATB（Snapshot-At-The-Beginning）
```

---

## 四、SATB 算法详解

### 4.1 核心思想

**SATB = 在标记开始时拍摄快照**

```
关键假设：
  "如果一个对象在标记开始时是存活的，
   那么它在整个标记周期内都认为是存活的"

实现方式：
  1. 标记开始时记录所有可达对象
  2. 写屏障拦截引用修改
  3. 被修改的旧引用存入 SATB 队列
  4. 最终标记阶段处理 SATB 队列，确保不遗漏
```

### 4.2 写屏障实现

```cpp
// 对象引用字段修改时触发
void satb_write_barrier(oop* field, oop new_value) {
  oop old_value = *field;
  
  // 1. 记录旧值（如果旧值非空且未标记）
  if (old_value != null && !is_marked(old_value)) {
    satb_queue.enqueue(old_value);
  }
  
  // 2. 执行实际修改
  *field = new_value;
}
```

### 4.3 SATB 与 CMS 的对比

| 特性 | SATB（G1） | 增量更新（CMS） |
|------|-----------|----------------|
| **算法** | 保守标记，记录旧引用 | 激进标记，跟踪新引用 |
| **精度** | 可能保留浮动垃圾 | 更精确，存活对象少 |
| **实现复杂度** | 简单，只记录旧值 | 复杂，需要重新扫描 |
| **吞吐量影响** | 较小 | 较大 |
| **Remark 停顿** | 较短（处理队列） | 较长（可能需要重新扫描） |

**G1 选择 SATB 的原因**：
1. 实现简单，可靠性高
2. Remark 阶段停顿可控
3. 浮动垃圾可通过后续 GC 回收

---

## 五、整体架构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         G1ConcurrentMark 整体架构                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                        并发标记生命周期                               │  │
│  │                                                                       │  │
│  │   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐   ┌─────────┐  │  │
│  │   │ Initial Mark│──▶│ Concurrent  │──▶│   Remark    │──▶│ Cleanup │  │  │
│  │   │  (初始标记)  │   │    Mark     │   │  (最终标记)  │   │ (清理)  │  │  │
│  │   └─────────────┘   └─────────────┘   └─────────────┘   └─────────┘  │  │
│  │          │                 │                 │              │        │  │
│  │      短暂 STW            并发执行          短暂 STW       并发/STW   │  │
│  │      (< 50ms)          (几秒~几分钟)      (< 200ms)      (< 50ms)   │  │
│  │          │                 │                 │              │        │  │
│  │          ▼                 ▼                 ▼              ▼        │  │
│  │   标记根对象+        遍历对象图           处理 SATB      回收空Region │  │
│  │   Survivor对象       标记存活对象         队列+引用处理    统计存活   │  │
│  │                                                                       │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                        核心数据结构                                   │  │
│  │                                                                       │  │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌──────────────────────┐  │  │
│  │  │  _next_mark_bitmap│  │  G1CMMarkStack   │  │  G1CMTask (×N)       │  │  │
│  │  │  (标记位图-写)   │  │  (全局标记栈)     │  │  (并发标记任务)       │  │  │
│  │  ├─────────────────┤  ├─────────────────┤  ├──────────────────────┤  │  │
│  │  │  _prev_mark_bitmap│  │  G1CMTaskQueue  │  │  _finger (全局指针)  │  │  │
│  │  │  (标记位图-读)   │  │  (任务队列集)     │  │  _task_queue (本地栈)│  │  │
│  │  └─────────────────┘  └─────────────────┘  └──────────────────────┘  │  │
│  │                                                                       │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                        写屏障支持                                     │  │
│  │                                                                       │  │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌──────────────────────┐  │  │
│  │  │  SATBMarkQueue   │  │  SATBMarkQueueSet│  │  G1SATBMarkQueueSet  │  │  │
│  │  │  (线程本地队列)   │  │  (全局队列集)     │  │  (并发处理)          │  │  │
│  │  └─────────────────┘  └─────────────────┘  └──────────────────────┘  │  │
│  │                                                                       │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 六、G1ConcurrentMark 核心字段

```cpp
class G1ConcurrentMark : public CHeapObj<mtGC> {
  // ===== 线程与执行控制 =====
  G1ConcurrentMarkThread* _cm_thread;      // 并发标记线程
  G1CollectedHeap*        _g1h;            // G1 堆引用
  
  // ===== 双缓冲位图 =====
  G1CMBitMap              _mark_bitmap_1;   // 位图 1
  G1CMBitMap              _mark_bitmap_2;   // 位图 2
  G1CMBitMap*             _prev_mark_bitmap; // 上一轮标记结果（只读）
  G1CMBitMap*             _next_mark_bitmap; // 当前标记（可写）
  
  // ===== 根区域管理 =====
  G1CMRootRegions         _root_regions;    // Survivor 区域作为根
  
  // ===== 灰色对象管理 =====
  G1CMMarkStack           _global_mark_stack; // 全局标记栈（灰色对象）
  HeapWord* volatile      _finger;            // 全局 finger 指针
  
  // ===== 任务管理 =====
  uint                    _max_num_tasks;     // 最大任务数
  uint                    _num_active_tasks;  // 活跃任务数
  G1CMTask**              _tasks;             // 任务数组
  G1CMTaskQueueSet*       _task_queues;       // 任务队列集
  ParallelTaskTerminator  _terminator;        // 终止协调器
  
  // ===== 溢出处理 =====
  WorkGangBarrierSync     _first_overflow_barrier_sync;
  WorkGangBarrierSync     _second_overflow_barrier_sync;
  volatile bool           _has_overflown;     // 标记栈溢出标志
  
  // ===== 状态控制 =====
  volatile bool           _concurrent;        // 是否并发阶段
  volatile bool           _has_aborted;       // 是否中止
  
  // ===== 统计信息 =====
  G1RegionMarkStats*      _region_mark_stats; // 每个 Region 的标记统计
  double*                 _accum_task_vtime;  // 累积虚拟时间
};
```

### 6.1 关键字段详解

| 字段 | 类型 | 说明 |
|------|------|------|
| `_next_mark_bitmap` | `G1CMBitMap*` | 当前正在构建的标记位图，标记为 1 表示对象存活 |
| `_prev_mark_bitmap` | `G1CMBitMap*` | 上一轮并发标记完成的位图，用于 Mixed GC 决策 |
| `_global_mark_stack` | `G1CMMarkStack` | 存储灰色对象的栈，标记器从中取对象继续扫描 |
| `_finger` | `HeapWord* volatile` | 全局进度指针，表示该地址之前的 Region 已被认领 |
| `_tasks` | `G1CMTask**` | 并发标记任务数组，每个线程一个 Task |
| `_region_mark_stats` | `G1RegionMarkStats*` | 每个 Region 的存活字节数统计 |

---

## 七、并发标记流程详解

### 7.1 阶段一：Initial Mark（初始标记）

**触发时机**：借道 Young GC
```cpp
void G1CollectedHeap::do_collection_pause_at_safepoint() {
  // ...
  if (g1_policy()->during_initial_mark_pause()) {
    // 启动初始标记
    concurrent_mark()->pre_initial_mark();
  }
  // ... Young GC 正常执行 ...
  if (during_initial_mark) {
    concurrent_mark()->post_initial_mark();
  }
}
```

**主要工作**：
1. 标记所有根对象（GC Roots）
2. 标记所有 Survivor Region 中的对象
3. 初始化 `_next_mark_bitmap`
4. 启动 `_cm_thread` 开始并发标记

**停顿时间**：通常 < 50ms（与 Young GC 一起执行）

### 7.2 阶段二：Concurrent Mark（并发标记）

**执行线程**：`G1ConcurrentMarkThread::run()`

```cpp
void G1ConcurrentMarkThread::run_service() {
  // 1. 扫描根区域（Survivor）
  _cm->scan_root_regions();
  
  // 2. 等待根区域扫描完成
  _cm->wait_until_root_region_scanning_done();
  
  // 3. 执行并发标记
  _cm->mark_from_roots();
  
  // 4. 等待 Remark 阶段
  wait_for_remark();
}
```

**核心循环**（`G1CMTask::do_marking_step()`）：
```cpp
void G1CMTask::do_marking_step(double time_target_ms) {
  // 1. 处理本地任务队列
  drain_local_queue(time_target_ms);
  
  // 2. 处理全局标记栈
  drain_global_stack(time_target_ms);
  
  // 3. 扫描已认领的 Region
  scan_claimed_region(time_target_ms);
  
  // 4. 尝试获取新 Region
  if (claim_next_region()) {
    scan_claimed_region(time_target_ms);
  }
  
  // 5. 尝试终止或窃取任务
  if (terminator()->offer_termination()) {
    return;
  }
}
```

**标记算法**：
```cpp
void G1CMTask::process_obj(oop obj) {
  // 1. 标记对象为黑色
  mark_bitmap()->mark(obj);
  
  // 2. 扫描对象的引用字段
  OopFieldStream stream(obj);
  while (!stream.eos()) {
    oop ref = stream.oop();
    if (ref != null && !mark_bitmap()->is_marked(ref)) {
      // 3. 将引用标记为灰色并入队
      if (task_queue()->push(G1TaskQueueEntry::from_oop(ref))) {
        // 本地队列满，压入全局栈
        global_mark_stack()->push(G1TaskQueueEntry::from_oop(ref));
      }
    }
    stream.next();
  }
}
```

### 7.3 阶段三：Remark（最终标记）

**触发条件**：并发标记完成或达到时间阈值

**主要工作**：
1. **处理 SATB 队列**：
   - 遍历所有线程的 `SATBMarkQueue`
   - 将队列中的对象标记为灰色并处理
   
2. **引用处理**：
   - 处理 Soft/Weak/Phantom Reference
   - 确定哪些引用对象需要清理

3. **类卸载准备**：
   - 标记需要卸载的类
   - 准备类元数据清理

**停顿时间**：通常 < 200ms

### 7.4 阶段四：Cleanup（清理）

**主要工作**：
1. **统计存活对象**：
   ```cpp
   for (each Region r) {
     live_words = count_live_objects(r, _prev_mark_bitmap);
     _region_mark_stats[r->index()]._live_words = live_words;
   }
   ```

2. **识别可回收 Region**：
   - 存活率 < 阈值（默认 85%）的 Region 可被回收
   - 完全空闲的 Region 立即回收

3. **RSet 重建准备**：
   - 设置 `_top_at_rebuild_starts`
   - 为后续并发精炼做准备

---

## 八、与 Young GC 的关系

```
时间线交织：

T1: Young GC (正常)          ──────STW──────
                              
T2: Young GC (Initial Mark)  ─STW─+─并发标记───
                                   │
T3: 并发标记进行中              ────│───────────────
                                   │
T4: Young GC (并发期间)         ─STW─│────────────
                                   │
T5: Remark                     ───STW───
                                   │
T6: Mixed GC (基于标记结果)     ──────STW──────

关键点：
1. Initial Mark 借道 Young GC，不额外停顿
2. 并发标记期间可以执行多次 Young GC
3. Mixed GC 基于并发标记的结果选择 CSet
```

---

## 九、GDB 验证

### 9.1 GDB 脚本

```gdb
# jvm-md/tmp-file/g1concurrentmark/gdb_g1cm.txt

set pagination off
set print pretty on

# 在并发标记初始化后设置断点
break G1ConcurrentMark::G1ConcurrentMark

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

printf "\n========== G1ConcurrentMark 基本信息 ==========\n"
set $g1h = G1CollectedHeap::heap()
set $cm = $g1h->_concurrent_mark

printf "_cm: %p\n", $cm
printf "sizeof(G1ConcurrentMark): %zu bytes\n", sizeof(G1ConcurrentMark)

printf "\n========== 位图信息 ==========\n"
printf "_next_mark_bitmap: %p\n", $cm->_next_mark_bitmap
printf "_prev_mark_bitmap: %p\n", $cm->_prev_mark_bitmap

printf "\n========== 任务信息 ==========\n"
printf "_max_num_tasks: %u\n", $cm->_max_num_tasks
printf "_num_active_tasks: %u\n", $cm->_num_active_tasks
printf "_num_concurrent_workers: %u\n", $cm->_num_concurrent_workers

printf "\n========== 全局 Finger ==========\n"
printf "_finger: %p\n", $cm->_finger
printf "_heap.start: %p\n", $cm->_heap.start
printf "_heap.end: %p\n", $cm->_heap.end

continue
```

### 9.2 GDB 实测输出

```
========== G1ConcurrentMark 验证 ==========
_cm: 0x7ffff0059830
sizeof(G1ConcurrentMark): 1840 bytes

---------- 位图信息 ----------
_next_mark_bitmap: 0x7ffff0059888
_prev_mark_bitmap: 0x7ffff0059850

---------- 任务信息 ----------
_max_num_tasks: 13
_num_active_tasks: 0
_num_concurrent_workers: 3

---------- 全局 Finger ----------
_finger: 0x600000000
```

【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
- sizeof(G1ConcurrentMark) = 1840 bytes ✓
- 双缓冲位图已初始化 ✓
- Finger 初始化为堆起始地址 ✓

---

## 十、面试问答

### Q1: 为什么要做并发标记？

**答案要点**：
1. 老年代越来越大，串行标记停顿时间不可接受
2. 将标记工作分散到并发阶段，降低 STW 时间
3. 为 Mixed GC 提供存活信息，实现增量回收

### Q2: 什么是三色标记法？

**答案要点**：
1. 白色：未访问，对象尚未被标记器访问
2. 灰色：已访问但字段未处理，对象已标记但其引用字段尚未扫描
3. 黑色：已访问且字段已处理，对象及其所有可达对象都已标记
4. 并发标记从灰色对象开始，处理完成后变为黑色

### Q3: SATB 和增量更新有什么区别？

**答案要点**：
1. SATB：记录旧引用，保守但实现简单，Remark 停顿短
2. 增量更新：跟踪新引用，更精确但实现复杂，可能需要重新扫描
3. G1 选择 SATB 是因为实现简单，可靠性高，停顿可控

### Q4: 并发标记期间对象引用关系变化怎么办？

**答案要点**：
1. SATB 写屏障拦截引用修改
2. 将旧引用存入线程本地 SATB 队列
3. Remark 阶段处理 SATB 队列，确保不遗漏存活对象
4. 可能产生浮动垃圾（本可回收但被保留），下次 GC 处理

---

## 十一、下一步学习

**本阶段关联文档**：
1. `G1ConcurrentMarkThread-Expert-Analysis.md` - 并发标记线程详解
2. `G1CMTask-Expert-Analysis.md` - 标记任务实现

**下阶段数据结构**：
1. `G1CMMarkStack-Expert-Analysis.md` - 标记栈实现
2. `G1SATBMarkQueue-Expert-Analysis.md` - SATB 队列机制

---

## 十二、总结

**G1ConcurrentMark 是 G1 实现低停顿的关键组件，通过三色标记法和 SATB 算法，在应用运行的同时并发标记存活对象，将标记工作从 STW 阶段转移到并发阶段，实现了大堆下的可预测停顿时间。**

| 核心机制 | 说明 |
|---------|------|
| 三色标记 | 白/灰/黑三色追踪对象标记状态 |
| SATB 算法 | 快照保障，记录旧引用防止漏标 |
| 并发执行 | 与应用线程并行，降低停顿 |
| 双缓冲位图 | Prev/Next 位图交替使用 |

**一句话记忆**：G1ConcurrentMark 就像是 GC 的"雷达扫描系统"，在飞机（应用）飞行的同时，持续扫描空域（堆内存），标记所有飞机（存活对象）的位置。

---

*文档生成时间: 2026-02-11*  
*源码版本: OpenJDK 11*  
*分析文件: g1ConcurrentMark.hpp/cpp*
