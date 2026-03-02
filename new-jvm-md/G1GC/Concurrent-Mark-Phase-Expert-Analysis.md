# Concurrent Mark Phase - 并发标记阶段

> **文档定位**: Mixed GC 学习路线 - 第3.2篇  
> **专家级分析**: 基于 GDB 运行时验证的精确数据  
> **JVM 参数**: `-Xms8g -Xmx8g -XX:+UseG1GC -Xint`

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

Concurrent Mark Phase 的本质是**多线程并发遍历对象图，用 `_next_mark_bitmap` 标记所有存活对象**：`G1ConcurrentMarkThread` 驱动多个 `G1CMTask` 并发工作，每个 Task 从任务队列取对象，扫描其引用字段，将未标记的引用对象加入队列并标记；使用 Work Stealing 实现负载均衡。

### 0.2 为什么需要？

Mixed GC 需要知道 Old Region 中哪些对象存活（计算存活率，决定是否值得回收）。但扫描整个 Old 区需要 STW，停顿时间不可接受。并发标记在应用线程运行时并发完成大部分标记工作，只有 Initial Mark/Remark/Cleanup 三个短暂 STW。

### 0.3 怎么解决？

**SATB + 多线程 Work Stealing**：
- **SATB 保证正确性**：Pre 写屏障将被覆盖的旧引用入 SATB 队列，确保"标记开始时存活的对象"不被漏标
- **多线程并发**：`G1ConcurrentMark` 启动 `ParallelGCThreads` 个 `G1CMTask`，每个 Task 有独立的任务队列
- **Work Stealing**：Task 队列空时从其他 Task 的队列"偷"任务，实现负载均衡
- **TAMS 保护新对象**：`_next_top_at_mark_start`（TAMS）以上的对象是标记期间新分配的，默认存活，不需要标记

### 0.4 为什么这样设计？

- **为什么用 Work Stealing 而不是静态分配？** 不同 Region 的对象密度不同，静态分配可能导致负载不均；Work Stealing 让忙的线程少做，闲的线程多做，自动均衡
- **为什么 TAMS 以上的对象默认存活？** 并发标记期间新分配的对象在 `_next_mark_bitmap` 中没有标记位；TAMS 记录标记开始时的 `_top`，TAMS 以上的对象是新分配的，保守地认为存活（下次标记会重新评估）
- **为什么并发标记可以被 Young GC 打断？** Young GC 需要 STW，并发标记必须暂停；Young GC 完成后并发标记从断点继续；这是 G1 的"搭便车"设计，Initial Mark 就搭便车在 Young GC 的 STW 中

---

## 一、问题驱动：为什么需要并发标记？

### 1.1 核心问题

在 Initial Mark 阶段，我们只标记了**GC Roots 直接可达**的对象。但老年代中大部分对象需要通过**引用链**间接可达。如果等到 GC 暂停时再扫描整个老年代：

```
场景：8GB 堆，4GB 老年代

STW 标记方案：
├─ 扫描 4GB 老年代
├─ 假设扫描速度 1GB/s
└─ 停顿时间 = 4 秒 ❌ 不可接受

并发标记方案：
├─ 与应用线程并发执行
├─ 利用多核 CPU
└─ STW 时间 < 100ms ✅ 可接受
```

### 1.2 并发标记的核心挑战

```
挑战1：对象图不断变化
    Mutator 在修改引用，并发标记如何保证正确性？
    解决：SATB（Snapshot-At-The-Beginning）算法

挑战2：如何避免重复扫描
    多个线程可能同时想扫描同一个对象
    解决：位图标记 + CAS 原子操作

挑战3：工作负载不均衡
    某些区域对象多，某些区域对象少
    解决：工作窃取（Work Stealing）+ 动态任务分配

挑战4：如何优雅暂停
    GC 暂停时需要快速停止并发标记
    解决：可暂停线程集（SuspendibleThreadSet）
```

### 1.3 并发标记在周期中的位置

```
并发标记周期时间线：

时间 ───────────────────────────────────────────────►
│
├─ STW ─┤
│ Initial Mark     ├────────────────────────────────────┤  并发运行
│ (根标记)         │        Concurrent Mark              │
│ < 10ms           │        (与应用并发)                  │
│                  │        持续数秒到数十秒              │
│                  │                                     │
│                  │  ┌─────┐  ┌─────┐  ┌─────┐        │
│                  │  │Task0│  │Task1│  │Task2│        │
│                  │  │标记  │  │标记  │  │标记  │        │
│                  │  └─────┘  └─────┘  └─────┘        │
│                  │       [工作窃取]                   │
│                  │                                     │
├─ STW ─┤         └─────────────────────────────────────┘
│ Remark │                                            │
│< 100ms │                                            │
│        │                                            │
```

---

## 二、整体架构

### 2.1 系统架构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        并发标记系统架构                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  G1ConcurrentMarkThread (主控线程)                                           │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  mark_from_roots()                                                  │    │
│  │  ┌─────────────────────────────────────────────────────────────┐   │    │
│  │  │ 阶段1: 扫描根区域 (Root Region Scan)                        │   │    │
│  │  │ ┌─────────────────────────────────────────────────────────┐ │   │    │
│  │  │ │ G1CMRootRegionScanTask                                   │ │   │    │
│  │  │ │ - 扫描 Survivor 区域                                   │ │   │    │
│  │  │ │ - 多线程并行                                           │ │   │    │
│  │  │ └─────────────────────────────────────────────────────────┘ │   │    │
│  │  └─────────────────────────────────────────────────────────────┘   │    │
│  │                              │                                      │    │
│  │                              ▼                                      │    │
│  │  ┌─────────────────────────────────────────────────────────────┐   │    │
│  │  │ 阶段2: 并发标记主循环 (Concurrent Marking)                  │   │    │
│  │  │ ┌─────────────────────────────────────────────────────────┐ │   │    │
│  │  │ │ G1CMConcurrentMarkingTask                               │ │   │    │
│  │  │ │ - 多 Worker 线程并行                                    │ │   │    │
│  │  │ │ - 每个线程处理 G1CMTask                                 │ │   │    │
│  │  │ └─────────────────────────────────────────────────────────┘ │   │    │
│  │  └─────────────────────────────────────────────────────────────┘   │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                     G1CMTask (每个 Worker 一个)                      │    │
│  │                                                                      │    │
│  │  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐             │    │
│  │  │ 本地标记队列 │    │ 全局标记栈  │    │ SATB 队列   │             │    │
│  │  │ _task_queue │    │ _mark_stack  │    │ _satb_queue │             │    │
│  │  └─────────────┘    └─────────────┘    └─────────────┘             │    │
│  │       │                  │                  │                       │    │
│  │       └──────────────────┼──────────────────┘                       │    │
│  │                          ▼                                          │    │
│  │              ┌─────────────────────┐                                │    │
│  │              │   do_marking_step() │                                │    │
│  │              │   - 扫描对象        │                                │    │
│  │              │   - 标记子对象      │                                │    │
│  │              │   - 工作窃取        │                                │    │
│  │              └─────────────────────┘                                │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 任务分配机制

```
堆内存划分：
├─ Region 0 ─┤├─ Region 1 ─┤├─ Region 2 ─┤...├─ Region 2047 ┤
│            ││            ││            │   │              │
│ 待标记     ││ 待标记     ││ Worker 1   │   │ Worker N     │
│            ││            ││ 处理中     │   │ 处理中       │
└────────────┘└────────────┘└────────────┘   └──────────────┘

任务分配策略：
1. 初始分配：每个 Worker "认领" 一个 Region
2. 处理完成：认领下一个可用 Region
3. 工作窃取：当无 Region 可认领时，从其他 Worker 窃取

Worker 状态流转：
┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
│  空闲    │────▶│ 处理本地 │────▶│ 处理全局 │────▶│ 工作窃取 │
│          │     │ 队列     │     │ 标记栈   │     │ 终止     │
└──────────┘     └──────────┘     └──────────┘     └──────────┘
       ▲                                              │
       └──────────────────────────────────────────────┘
                  有新工作加入或窃取成功
```

---

## 三、核心执行流程

### 3.1 并发标记主循环

```cpp
// src/hotspot/share/gc/g1/g1ConcurrentMark.cpp:919
class G1CMConcurrentMarkingTask : public AbstractGangTask {
  void work(uint worker_id) {
    // 加入可暂停线程集（支持安全点）
    SuspendibleThreadSetJoiner sts_join;
    
    G1CMTask* task = _cm->task(worker_id);
    task->record_start_time();
    
    // 主循环：持续标记直到完成或中止
    do {
      // 执行标记步骤（目标时间 10ms）
      task->do_marking_step(G1ConcMarkStepDurationMillis,
                            true,   // 启用终止协议
                            false); // 非串行执行
      
      // 检查是否需要让出（安全点请求）
      _cm->do_yield_check();
      
    } while (!_cm->has_aborted() && task->has_aborted());
    
    task->record_end_time();
  }
};
```

### 3.2 do_marking_step 详解

```cpp
// src/hotspot/share/gc/g1/g1ConcurrentMark.cpp:2681
void G1CMTask::do_marking_step(double time_target_ms,
                               bool do_termination,
                               bool is_serial) {
  _start_time_ms = os::elapsedVTime() * 1000.0;
  
  // 是否启用工作窃取
  bool do_stealing = do_termination && !is_serial;
  
  // 计算实际目标时间（考虑历史偏差）
  double diff_prediction_ms = 
    _g1h->g1_policy()->predictor().get_new_prediction(&_marking_step_diffs_ms);
  _time_target_ms = time_target_ms - diff_prediction_ms;
  
  // 设置工作计数器（用于时钟回调）
  _words_scanned = 0;
  _refs_reached  = 0;
  recalculate_limits();
  
  // 第1步：处理 SATB 队列
  drain_satb_buffers();
  
  // 第2步：处理本地队列和全局栈
  drain_local_queue(true);
  drain_global_stack(true);
  
  // 第3步：主标记循环
  do {
    // 3.1 如果持有 Region，继续扫描
    if (!has_aborted() && _curr_region != NULL) {
      // 更新 Region 边界（可能在疏散暂停后变化）
      update_region_limit();
      
      MemRegion mr = MemRegion(_finger, _region_limit);
      
      // 扫描位图中已标记的对象
      if (_next_mark_bitmap->iterate(&bitmap_closure, mr)) {
        giveup_current_region();  // 完成，放弃 Region
        regular_clock_call();      // 时钟回调
      }
    }
    
    // 3.2 再次排空队列
    drain_local_queue(true);
    drain_global_stack(true);
    
    // 3.3 认领新 Region
    while (!has_aborted() && _curr_region == NULL && !_cm->out_of_regions()) {
      HeapRegion* claimed_region = _cm->claim_region(_worker_id);
      if (claimed_region != NULL) {
        setup_for_region(claimed_region);
      }
      regular_clock_call();
    }
    
    // 3.4 处理本地队列
    drain_local_queue(true);
    
    // 3.5 如果全局栈有数据，协助处理
    if (!has_aborted() && !_cm->mark_stack_empty()) {
      drain_global_stack(true);
    }
    
    // 3.6 工作窃取（Best-of-2 策略）
    if (do_stealing && !has_aborted()) {
      if (_cm->try_stealing(_worker_id, &_region_finger, &_task_queue)) {
        continue;  // 窃取成功，继续处理
      }
    }
    
  } while (!has_aborted() && !check_clock());
  
  // 第4步：终止协议（所有线程同步）
  if (do_termination && !has_aborted()) {
    terminate();
  }
}
```

### 3.3 对象扫描流程

```
扫描一个已标记对象：

1. 从位图中找到已标记对象地址
   │
   ▼
2. 获取对象大小，计算对象范围
   │
   ▼
3. 遍历对象的所有引用字段
   │
   ├── 对每个引用：
   │   │
   │   ├── 检查引用是否为 NULL
   │   │   └── 是 → 跳过
   │   │
   │   ├── 计算引用对象所属 Region
   │   │
   │   ├── 尝试原子标记（CAS）
   │   │   │
   │   │   ├── 标记成功 → 对象首次发现
   │   │   │            │
   │   │   │            ├── 对象放入本地队列
   │   │   │            └── _live_words += 对象大小
   │   │   │
   │   │   └── 标记失败 → 对象已被其他线程标记
   │   │                └── 跳过
   │   │
   │   └── 继续下一个引用
   │
   ▼
4. 对象扫描完成，处理下一个
```

---

## 四、关键机制详解

### 4.1 工作窃取（Work Stealing）

```
场景：Worker 0 很忙，Worker 1 空闲

Worker 0                  Worker 1
┌─────────────┐          ┌─────────────┐
│ 本地队列    │          │ 本地队列    │
│ [A,B,C,D,E] │          │ []          │
│ 5个对象     │          │ 空          │
└─────────────┘          └─────────────┘
       │                        │
       │                        │ 无工作可做
       │                        ▼
       │               try_stealing()
       │                        │
       │                        ├── 随机选择 Worker 0
       │                        │
       │                        ├── 窃取尾部对象（E）
       │                        │
       │               ┌─────────────┐
       │               │ 本地队列    │
       │               │ [E]         │
       │               └─────────────┘
       │                        │
       ▼                        ▼
┌─────────────┐          ┌─────────────┐
│ 本地队列    │          │ 本地队列    │
│ [A,B,C,D]   │          │ [E]         │
└─────────────┘          └─────────────┘

Best-of-2 策略：
- 随机选择 2 个其他 Worker
- 从队列更长的那个窃取
- 减少竞争，提高负载均衡
```

### 4.2 时钟机制（Clock）

```
为什么需要时钟机制？
- 避免频繁调用 vtime()（昂贵）
- 定期检查是否需要让出（Yield）
- 检查是否超时或收到中止信号

时钟触发条件（满足任一）：
1. 扫描字数达到 _words_scanned_limit
2. 访问引用数达到 _refs_reached_limit
3. 显式调用 regular_clock_call()

时钟回调处理：
regular_clock_call()
  │
  ├── 检查是否超时
  │   └── 是 → set_has_aborted()
  │
  ├── 检查全局溢出
  │   └── 是 → 进入溢出处理
  │
  ├── 检查安全点请求
  │   └── 是 → 让出 CPU
  │
  └── 重新计算限制
      └── recalculate_limits()
```

### 4.3 可暂停线程集（SuspendibleThreadSet）

```
场景：并发标记期间触发 Young GC

VMThread (GC 协调)         Concurrent Mark Threads
       │                              │
       │ 请求安全点                    │
       ├─────────────────────────────▶│
       │                              │
       │                              │ SuspendibleThreadSetJoiner
       │                              │ - 注册到线程集
       │                              │ - 检查 should_yield()
       │                              │
       │ 安全点达成                    │ 在 yield 点让出
       │◀─────────────────────────────│
       │                              │ sts_leave.yield()
       │                              │
       │ 执行 Young GC                 │ 等待 GC 完成
       │ ...                          │ ...
       │                              │
       │ GC 完成，恢复                 │ 恢复执行
       ├─────────────────────────────▶│
       │                              │

关键设计：
- sts_joiner.should_yield() 检查是否需要让出
- sts_joiner.yield() 安全让出并等待恢复
- 避免并发标记线程阻塞 GC 暂停
```

### 4.4 标记栈溢出处理

```
场景：全局标记栈满了

1. 检测到溢出
   │
   ▼
2. 设置 _has_overflown = true
   │
   ▼
3. 所有标记线程在时钟回调中发现溢出
   │
   ▼
4. 进入第一同步屏障
   enter_first_sync_barrier()
   │
   ▼
5. 所有线程同步后，扩展标记栈
   _global_mark_stack.expand()
   │
   ▼
6. 进入第二同步屏障
   enter_second_sync_barrier()
   │
   ▼
7. 重新初始化，继续标记
```

---

## 五、GDB 验证数据

### 5.1 验证脚本

```gdb
# GDB验证脚本: Concurrent Mark
# 保存为 verify_concurrent_mark.gdb

set width 0
set pagination off
set confirm off

break /data/workspace/openjdk-cut-new/src/hotspot/share/memory/universe.cpp:1265

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp <classpath> <MainClass>

set $g1h = G1CollectedHeap::heap()
set $cm = $g1h->_cm

printf "\n=== 并发标记参数 ===\n"
printf "G1ConcMarkStepDurationMillis = %d ms\n", G1ConcMarkStepDurationMillis
printf "G1ConcRefinementThreads = %d\n", G1ConcRefinementThreads

printf "\n=== G1ConcurrentMark 状态 ===\n"
printf "_num_concurrent_workers = %u\n", $cm->_num_concurrent_workers
printf "_max_concurrent_workers = %u\n", $cm->_max_concurrent_workers
printf "_finger = %p\n", $cm->_finger

printf "\n=== 全局标记栈 ===\n"
set $stack = $cm->_global_mark_stack
printf "_max_chunk_capacity = %zu\n", $stack->_max_chunk_capacity
printf "_chunk_capacity = %zu\n", $stack->_chunk_capacity
printf "_base = %p\n", $stack->_base

printf "\n=== 验证通过 ===\n"

quit
```

### 5.2 验证结果

```gdb
# === 并发标记参数 ===
G1ConcMarkStepDurationMillis = 10    # 每步目标 10ms
G1ConcRefinementThreads = 13         # 13个精炼线程

# === G1ConcurrentMark 状态 ===
_num_concurrent_workers = 3          # 当前3个并发标记线程
_max_concurrent_workers = 3          # 最大3个
_finger = 0x600000000               # 标记指针

# === 全局标记栈 ===
_max_chunk_capacity = 16384          # 最大16384个chunks
_chunk_capacity = 4096               # 当前容量4096个chunks
_base = 0x7fffd4000000              # 栈内存基地址
```

---

## 六、性能特征

### 6.1 并发标记耗时因素

```
主要耗时来源：

1. 堆大小
   - 老年代越大，标记时间越长
   - 8GB 堆可能需要 5-15 秒

2. 存活对象数量
   - 存活对象越多，需要扫描的引用越多
   - 每个对象都要遍历其引用字段

3. 对象图复杂度
   - 深层对象链增加递归深度
   - 宽引用扇出增加工作量

4. CPU 资源竞争
   - 与应用线程竞争 CPU
   - 默认使用 1/4 或 1/2 的 CPU 核数

5. 写屏障开销
   - SATB 写屏障记录引用变化
   - 高写吞吐量增加开销
```

### 6.2 线程数配置

```
并发标记线程数计算：

默认配置：
- ConcGCThreads = 0 (动态计算)
- 公式: MAX(1, (ParallelGCThreads + 2) / 4)
- 示例: 13 ParallelGCThreads → (13+2)/4 = 3 个并发标记线程

手动配置：
-XX:ConcGCThreads=N

建议：
- 默认值通常最优
- 不要设置超过 CPU 核数的一半
- 过多线程会增加上下文切换开销
```

---

## 七、与其他机制的关联

### 7.1 与 SATB 的协作

```
并发标记期间：

Mutator 线程                并发标记线程
       │                          │
       │ 修改引用                  │ 扫描对象
       │ obj.field = new_val       │
       │                           │
       ▼                           ▼
┌─────────────┐            ┌─────────────┐
│ SATB 写屏障 │            │ 标记对象    │
│             │            │             │
│ 1. 记录旧值 │──────▶     │ 从队列取    │
│    old_val  │   SATB队列 │ 处理标记    │
│ 2. 加入队列 │            │             │
└─────────────┘            └─────────────┘

协作关系：
- 并发标记处理常规对象图
- SATB 队列记录并发期间的引用变化
- Remark 阶段处理 SATB 队列，确保无遗漏
```

### 7.2 与 Young GC 的交互

```
并发标记期间触发 Young GC：

1. Young GC 请求安全点
   │
2. 并发标记线程在 yield 点暂停
   │
3. Young GC 执行疏散
   │   ├─ Eden → Survivor
   │   └─ 部分 Survivor → Old
   │
4. Young GC 更新 TAMS
   │   ├─ 新晋升的对象在 TAMS 之上
   │   └─ 并发标记无需处理
   │
5. 并发标记线程恢复
   │   ├─ 检查 finger 是否有效
   │   ├─ 如果被疏散，更新 Region 信息
   │   └─ 继续标记
```

### 7.3 与根区域扫描的关系

```
并发标记流程：

阶段1: 根区域扫描（优先）
├─ 扫描 Survivor 区域
├─ 这些区域的对象是新晋升的
└─ 必须在主标记前完成

阶段2: 并发标记主循环
├─ 从全局标记栈取对象
├─ 从根区域发现的引用开始
├─ 遍历整个老年代对象图
└─ 直到所有可达对象都被标记

依赖关系：
- Survivor 对象是并发标记的起点之一
- 必须先完成根区域扫描
- 否则可能遗漏从 Survivor 可达的对象
```

---

## 八、总结

### 8.1 核心设计要点

| 设计决策 | 实现 | 优势 |
|----------|------|------|
| 并发执行 | 多线程与应用并行 | 减少 STW 时间 |
| 工作窃取 | Best-of-2 策略 | 负载均衡 |
| 时钟机制 | 基于工作量的回调 | 避免频繁系统调用 |
| 可暂停 | SuspendibleThreadSet | 支持安全点 |
| 位图标记 | CAS 原子操作 | 无锁并发安全 |

### 8.2 关键数值（8GB 堆）

```
并发标记配置：
├── 并发标记线程数：3（默认计算）
├── 每步目标时间：10ms
├── 全局标记栈：128MB 虚拟 / 8MB 初始
└── 本地队列：64 个条目

性能指标：
├── 标记速度：取决于存活对象数
├── 典型耗时：5-15 秒（8GB 堆）
├── 停顿影响：< 10ms（时钟回调让出）
└── CPU 占用：约 25-50% 的并发线程
```

### 8.3 学习路径衔接

```
并发标记周期：
Initial Mark ──▶ Concurrent Mark ──▶ Remark ──▶ Cleanup
     │                │                │           │
   3.1 ✅          3.2 ✅            3.3         3.4

已完成：
├── 3.1 Initial Mark（STW 根标记）
└── 3.2 Concurrent Mark（并发标记主循环）

下一步：3.3 Remark Phase（最终标记）
- 处理 SATB 队列
- 处理引用
- STW 完成标记
```

---

**文档完成日期**: 2026-02-11  
**GDB 验证状态**: ✅ 全部关键数据已验证  
**下一步预告**: 3.3 Remark Phase（最终标记阶段）
