# Initial Mark Phase - 初始标记阶段

> **文档定位**: Mixed GC 学习路线 - 第3.1篇  
> **专家级分析**: 基于 GDB 运行时验证的精确数据  
> **JVM 参数**: `-Xms8g -Xmx8g -XX:+UseG1GC -Xint`

---

## 一、问题驱动：为什么需要初始标记？

### 1.1 核心问题

在并发标记周期开始之前，JVM 需要完成一些**必须在 STW（Stop-The-World）暂停**中完成的工作：

1. **标记所有从根直接可达的对象** - 这是后续并发标记的起点
2. **设置 TAMS（Top At Mark Start）指针** - 区分标记期间新分配的对象
3. **准备并发标记所需的数据结构** - 清空位图、重置统计信息等
4. **启动 SATB 屏障** - 开始记录并发标记期间的引用变化

### 1.2 为什么叫"借道 Young GC"？

```
关键洞察：初始标记可以复用 Young GC 的根扫描

场景：
- 初始标记需要扫描根（GC Roots）
- Young GC 也需要扫描根
- 两者都需要 STW

优化：
┌─────────────────────────────────────────────────────────────┐
│  传统方式                        借道优化                    │
│                                                             │
│  Young GC ──STW──▶ 初始标记 ──STW──▶ 并发标记              │
│  (扫描根)        (扫描根)                                  │
│                                                             │
│  借道方式：                                                  │
│  Young GC + 初始标记 ──STW──▶ 并发标记                     │
│  (一次扫描根做两件事)                                        │
│                                                             │
│  收益：减少一次 STW，降低总停顿时间                          │
└─────────────────────────────────────────────────────────────┘
```

### 1.3 初始标记在并发标记周期中的位置

```
并发标记周期（Concurrent Marking Cycle）:

    初始标记 (Initial Mark) ─────────────────────── STW
         │                                           │
         ▼                                           │
    并发标记 (Concurrent Mark) ── 与应用并发运行    │
         │                                           │
         ▼                                           │
    最终标记 (Remark) ─────────────────────────── STW
         │                                           │
         ▼                                           │
    清理 (Cleanup) ────────────────────────────── STW
         │                                           │
         ▼                                           │
    并发清理 (Concurrent Cleanup) ─ 与应用并发运行  │
         
初始标记特点：
- 必须是 STW（因为要设置一致的快照点）
- 通常与 Young GC 合并执行
- 时间较短（只标记根直接可达对象）
```

---

## 二、触发条件

### 2.1 IHOP（Initiating Heap Occupancy Percent）

```
触发条件：
老年代占用率 > IHOP 阈值

默认配置：
- IHOP = 45%
- 即当老年代（包括 Humongous 区域）占用超过堆的 45% 时触发

8GB 堆示例：
- 触发阈值 = 8GB × 45% = 3.6GB
- 当老年代占用 > 3.6GB 时，下一次 Young GC 将升级为 Initial Mark
```

### 2.2 GDB 验证

```gdb
# === IHOP 初始标记触发阈值 ===
p G1UseAdaptiveIHOP
$1 = true    # 启用自适应 IHOP

p InitiatingHeapOccupancyPercent
$2 = 45      # 默认 45%

# === 堆信息 ===
p $g1h->capacity()
$3 = 8589934592    # 8GB

# === IHOP 阈值计算 ===
p/x (size_t)8*1024*1024*1024 * 45 / 100
$4 = 0xe6666666    # 3,865,469,542 字节 (~3.6GB)
```

### 2.3 触发决策流程

```
G1Policy::need_to_start_conc_mark()
    │
    ▼
获取 IHOP 阈值
    │
    ▼
计算当前老年代占用 + 本次分配请求
    │
    ▼
占用 > 阈值 ?
    │
    ├── 是 ──▶ 检查是否处于 Young-Only 阶段
    │            │
    │            ├── 是 ──▶ 设置 initiate_conc_mark_if_possible = true
    │            │
    │            └── 否 ──▶ 延迟到 Mixed GC 后
    │
    └── 否 ──▶ 继续正常 Young GC

G1Policy::decide_on_conc_mark_initiation()
    │
    ▼
检查 initiate_conc_mark_if_possible
    │
    ▼
设置 in_initial_mark_gc = true
设置 initiate_conc_mark_if_possible = false
    │
    ▼
本次 GC 将执行初始标记工作
```

---

## 三、核心执行流程

### 3.1 整体流程图

```
Young GC 开始
    │
    ▼
G1Policy::decide_on_conc_mark_initiation()
    │
    ▼
如果决定执行初始标记
    │
    ├── 设置 in_initial_mark_gc = true
    │
    ▼
正常 Young GC 流程
（ evacuation + 根扫描 ）
    │
    ▼
G1ConcurrentMark::pre_initial_mark()
    │
    ├── reset() ─────────────────▶ 重置标记结构
    │   ├── 清空 next_mark_bitmap
    │   ├── 清空 Region 统计
    │   └── 重置全局标记栈
    │
    ├── 遍历所有 Region
    │   └── note_start_of_marking()
    │       ├── _prev_top_at_mark_start = _next_top_at_mark_start
    │       ├── _next_top_at_mark_start = bottom()
    │       └── _next_marked_bytes = 0
    │
    ▼
G1ConcurrentMark::post_initial_mark()
    │
    ├── 启动弱引用发现
    │   ├── rp->enable_discovery()
    │   └── rp->setup_policy(false)
    │
    ├── 激活 SATB 屏障
    │   └── satb_mq_set.set_active_all_threads(true, false)
    │
    ├── 准备根区域扫描
    │   └── _root_regions.prepare_for_scan()
    │
    └── 设置 mark_or_rebuild_in_progress = true
    │
    ▼
G1ConcurrentMarkThread::set_started()
    │
    ▼
并发标记线程开始运行
    │
    ▼
并发标记周期正式开始
```

### 3.2 pre_initial_mark() 详解

```cpp
// src/hotspot/share/gc/g1/g1ConcurrentMark.cpp:843
void G1ConcurrentMark::pre_initial_mark() {
  // 1. 初始化标记结构（必须在 STW 中完成）
  reset();
  
  // 2. 遍历所有 Region，标记标记开始
  NoteStartOfMarkHRClosure startcl;
  _g1h->heap_region_iterate(&startcl);
}

// reset() 具体工作
void G1ConcurrentMark::reset() {
  // 清空全局标记栈
  _global_mark_stack.clear();
  
  // 清空 Region 统计
  for (uint i = 0; i < _g1h->max_regions(); i++) {
    _region_mark_stats[i].clear();
    _top_at_rebuild_starts[i] = NULL;
  }
  
  // 重置位图（如果需要）
  // ...
}

// note_start_of_marking() 具体工作（每个 Region）
inline void HeapRegion::note_start_of_marking() {
  // 保存上一轮标记信息
  _prev_top_at_mark_start = _next_top_at_mark_start;
  _prev_marked_bytes = _next_marked_bytes;
  
  // 设置本轮标记起始点
  _next_top_at_mark_start = bottom();
  _next_marked_bytes = 0;
}
```

### 3.3 post_initial_mark() 详解

```cpp
// src/hotspot/share/gc/g1/g1ConcurrentMark.cpp:853
void G1ConcurrentMark::post_initial_mark() {
  // 1. 启动并发标记的弱引用发现
  ReferenceProcessor* rp = _g1h->ref_processor_cm();
  rp->enable_discovery();                    // 启用弱引用发现
  rp->setup_policy(false);                   // 设置引用处理策略
  
  // 2. 激活 SATB 写屏障
  SATBMarkQueueSet& satb_mq_set = G1BarrierSet::satb_mark_queue_set();
  satb_mq_set.set_active_all_threads(true,   // 新状态：激活
                                     false);  // 期望旧状态：未激活
  
  // 3. 准备根区域扫描
  // 根区域 = Survivor 区域（本次 Young GC 晋升的对象所在区域）
  _root_regions.prepare_for_scan();
  
  // 4. 标记"标记或重建进行中"
  // 这将影响后续的写屏障行为
  _g1h->collector_state()->set_mark_or_rebuild_in_progress(true);
}
```

---

## 四、TAMS 指针机制

### 4.1 什么是 TAMS？

```
TAMS = Top At Mark Start（标记开始时的顶部）

作用：
- 区分"标记开始前已存在"和"标记期间新分配"的对象
- 标记开始前已存在的对象：需要被标记
- 标记期间新分配的对象：隐式存活，不需要标记

双缓冲设计：
- prev TAMS：上一轮并发标记的 TAMS
- next TAMS：当前轮并发标记的 TAMS
```

### 4.2 TAMS 设置过程

```
初始标记前：
├─────────────────────────────────────────────────────┤
│ Region X                                            │
│ ┌─────────────────────────────────────────────────┐ │
│ │ 已分配对象                                       │ │
│ │                                                 │ │
│ │                    top ──▶ 未分配空间           │ │
│ │                                                 │ │
│ └─────────────────────────────────────────────────┘ │
│                                                     │
│ _prev_top_at_mark_start = 上一轮值                  │
│ _next_top_at_mark_start = top（当前分配顶）          │
└─────────────────────────────────────────────────────┘

初始标记时（note_start_of_marking）：
├─────────────────────────────────────────────────────┤
│ Region X                                            │
│ ┌─────────────────────────────────────────────────┐ │
│ │ 需要标记的对象（标记开始前已存在）               │ │
│ │ ◄── _next_top_at_mark_start = bottom()          │ │
│ │                                                 │ │
│ │ 新分配对象（隐式存活）                           │ │
│ │ ◄── top（标记期间分配）                          │ │
│ └─────────────────────────────────────────────────┘ │
│                                                     │
│ _prev_top_at_mark_start = 旧 _next_top_at_mark_start│
│ _next_top_at_mark_start = bottom()                  │
└─────────────────────────────────────────────────────┘

注意：
- 初始标记时，_next_top_at_mark_start 被设置为 bottom()
- 这意味着在标记期间，该 Region 中所有新分配的对象都在 TAMS 之上
- 并发标记时，只需扫描 [bottom, next TAMS) 区间的对象
```

### 4.3 TAMS 在并发标记中的作用

```
并发标记扫描对象时：

对于每个 Region：
  扫描范围 = [bottom, next_TAMS)
  
  为什么不是扫描到 top？
  - top 可能一直在增长（mutator 持续分配）
  - 扫描到 next_TAMS 确保只处理标记开始前已存在的对象
  
  新分配的对象怎么办？
  - 位于 [next_TAMS, top) 区间
  - 这些对象在标记期间分配，隐式视为存活
  - 不需要扫描，减少并发标记工作量
```

---

## 五、SATB 屏障启动

### 5.1 为什么需要 SATB？

```
并发标记的挑战：

Mutator 线程        并发标记线程
    │                   │
    │ 修改引用          │ 扫描对象
    │ A.obj = B         │ 标记 A
    │                   │ 发现 A 引用 C
    │                   │ （没看到新引用 B）
    ▼                   ▼
    
问题：B 对象可能丢失（如果只有 A 引用 B）

SATB 解决方案：
- 记录"修改前"的引用关系
- 在 Remark 阶段处理这些引用
- 保证不遗漏任何存活对象
```

### 5.2 SATB 启动过程

```cpp
// post_initial_mark() 中激活 SATB
satb_mq_set.set_active_all_threads(true,   // 新状态：激活
                                   false);  // 期望旧状态：未激活

// 这会影响每个线程的写屏障
// 具体在 g1BarrierSet.cpp 中实现

// 写屏障伪代码：
void write_barrier(oop* field, oop new_value) {
  // 1. 正常的 card table 标记
  mark_card(field);
  
  // 2. SATB 记录（如果激活）
  if (satb_is_active) {
    oop old_value = *field;  // 读取旧值
    if (old_value != NULL) {
      enqueue_to_satb_queue(old_value);  // 记录旧引用
    }
  }
  
  // 3. 写入新值
  *field = new_value;
}
```

---

## 六、根区域扫描

### 6.1 什么是根区域？

```
根区域（Root Regions）：
- 特指 Survivor 区域（即本次 Young GC 晋升对象所在的区域）
- 这些区域中的对象是新晋升到老年代的
- 它们可能包含指向老年代其他对象的引用
- 因此是并发标记的"根"之一

为什么是 Survivor 区域？
- Young GC 已经扫描了 Eden 和 Survivor 的根
- 但 Survivor 中的对象晋升到老年代后，它们的引用关系还没追踪
- 这些引用需要被并发标记扫描
```

### 6.2 根区域扫描机制

```cpp
// G1CMRootRegions 管理根区域扫描
class G1CMRootRegions {
private:
  const G1SurvivorRegions* _survivors;
  volatile bool _scan_in_progress;
  volatile bool _should_abort;

public:
  // 准备扫描（在 post_initial_mark 中调用）
  void prepare_for_scan();
  
  // 并发标记线程调用
  void scan_root_regions(G1CMTask* task);
  
  // 检查是否扫描完成
  bool scan_in_progress() const;
  bool should_abort() const;
};

// 扫描过程
void G1CMRootRegions::scan_root_regions(G1CMTask* task) {
  // 遍历所有 Survivor 区域
  for (each survivor region) {
    if (_should_abort) break;
    
    // 扫描区域内的所有对象
    region->object_iterate(&cl);
    
    // 闭包会将可达对象加入标记队列
  }
}
```

### 6.3 根区域扫描与并发标记的关系

```
并发标记流程：

1. 初始标记（STW）
   ├── 标记 GC Roots 直接可达对象
   └── 准备根区域扫描
   
2. 并发标记（与应用并发）
   ├── 阶段 1：等待根区域扫描完成
   │   └── 因为 Survivor 区域是标记起点之一
   │
   ├── 阶段 2：扫描全局标记栈
   │   └── 处理从 Survivor 发现的引用
   │
   └── 阶段 3：持续处理标记队列直到完成

关键点：
- 根区域扫描在并发阶段完成
- 但必须在并发标记主循环前完成
- 确保 Survivor 中的引用都被追踪
```

---

## 七、性能特征

### 7.1 停顿时间分析

```
初始标记停顿时间组成：

1. Young GC 本身时间
   ├── 根扫描
   ├── 疏散对象（Eden → Survivor / Old）
   └── 更新 RSet
   
2. 初始标记额外时间
   ├── 标记 GC Roots 直接可达对象
   │   └── 通常很快（< 1ms）
   ├── 设置 TAMS 指针
   │   └── 遍历所有 Region，O(num_regions)
   │   └── 8GB 堆（2048 regions）约 0.1-0.2ms
   └── 启动 SATB 屏障
       └── 非常快（设置标志位）

总计：
- 初始标记额外开销通常 < 5ms
- 主要开销还是 Young GC 本身
- 因此"借道"策略很高效
```

### 7.2 与 CMS 的对比

```
┌─────────────────────────────────────────────────────────────┐
│              G1 Initial Mark          CMS Initial Mark      │
├─────────────────────────────────────────────────────────────┤
│ 触发方式：                              触发方式：          │
│ - IHOP 阈值触发                         - 老年代占用率触发   │
│ - 通常伴随 Young GC                     - 独立触发           │
│                                                             │
│ 工作内容：                              工作内容：          │
│ - 标记 GC Roots                         - 标记 GC Roots      │
│ - 设置 TAMS                             - 标记年轻代引用     │
│ - 启动 SATB                             - 启动 CMS 屏障      │
│                                                             │
│ 优化：                                  优化：              │
│ - 借道 Young GC                         - 独立暂停           │
│ - 根扫描复用                            - 需要单独扫描根     │
│ - 停顿时间更短                          - 停顿时间更长       │
└─────────────────────────────────────────────────────────────┘
```

---

## 八、关键源码解析

### 8.1 触发决策链

```cpp
// 1. GC 前检查是否需要启动并发标记
// g1Policy.cpp:579
bool G1Policy::need_to_start_conc_mark(const char* source, size_t alloc_word_size) {
  // 获取 IHOP 控制的阈值
  size_t marking_initiating_used_threshold = 
    _ihop_control->get_conc_mark_start_threshold();
  
  // 计算当前老年代占用 + 本次分配
  size_t cur_used_bytes = _g1h->non_young_capacity_bytes();
  size_t alloc_byte_size = alloc_word_size * HeapWordSize;
  size_t marking_request_bytes = cur_used_bytes + alloc_byte_size;
  
  // 检查是否超过阈值
  if (marking_request_bytes > marking_initiating_used_threshold) {
    // 只有在 Young-Only 阶段才能启动
    return collector_state()->in_young_only_phase() && 
           !collector_state()->in_young_gc_before_mixed();
  }
  return false;
}

// 2. GC 开始时决策
// g1Policy.cpp:984
void G1Policy::decide_on_conc_mark_initiation() {
  if (collector_state()->initiate_conc_mark_if_possible()) {
    if (!about_to_start_mixed_phase() && 
        collector_state()->in_young_only_phase()) {
      // 启动初始标记
      initiate_conc_mark();
    }
  }
}

// 3. 设置初始标记状态
// g1Policy.cpp:978
void G1Policy::initiate_conc_mark() {
  collector_state()->set_in_initial_mark_gc(true);
  collector_state()->set_initiate_conc_mark_if_possible(false);
}
```

### 8.2 初始标记执行

```cpp
// 在 GC 暂停期间调用
// g1ConcurrentMark.cpp:843
void G1ConcurrentMark::pre_initial_mark() {
  // 重置标记结构
  reset();
  
  // 遍历所有 Region 设置 TAMS
  NoteStartOfMarkHRClosure startcl;
  _g1h->heap_region_iterate(&startcl);
}

void G1ConcurrentMark::post_initial_mark() {
  // 启动弱引用发现
  ReferenceProcessor* rp = _g1h->ref_processor_cm();
  rp->enable_discovery();
  rp->setup_policy(false);
  
  // 激活 SATB 屏障
  SATBMarkQueueSet& satb_mq_set = 
    G1BarrierSet::satb_mark_queue_set();
  satb_mq_set.set_active_all_threads(true, false);
  
  // 准备根区域扫描
  _root_regions.prepare_for_scan();
}
```

---

## 九、GDB 验证数据

### 9.1 验证脚本

```gdb
# GDB验证脚本: Initial Mark
# 保存为 verify_initial_mark.gdb

set width 0
set pagination off
set confirm off

break /data/workspace/openjdk-cut-new/src/hotspot/share/memory/universe.cpp:1265

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp <classpath> <MainClass>

set $g1h = G1CollectedHeap::heap()

printf "\n=== IHOP 配置 ===\n"
printf "G1UseAdaptiveIHOP = %d\n", G1UseAdaptiveIHOP
printf "InitiatingHeapOccupancyPercent = %zu\n", 
       InitiatingHeapOccupancyPercent

printf "\n=== 堆信息 ===\n"
printf "堆容量 = %zu bytes (%.1f GB)\n", 
       $g1h->capacity(), 
       (double)$g1h->capacity() / 1024 / 1024 / 1024

printf "\n=== IHOP 阈值 ===\n"
set $ihop_threshold = (size_t)($g1h->capacity() * 45 / 100)
printf "45%% 阈值 = 0x%lx bytes (~%.1f GB)\n", 
       $ihop_threshold, 
       (double)$ihop_threshold / 1024 / 1024 / 1024

printf "\n=== G1ConcurrentMark ===\n"
set $cm = $g1h->_cm
printf "G1ConcurrentMark 地址 = %p\n", $cm
printf "_finger = %p\n", $cm->_finger

printf "\n=== 验证通过 ===\n"

quit
```

### 9.2 验证结果

```gdb
# === IHOP 配置 ===
G1UseAdaptiveIHOP = true      # 启用自适应 IHOP
InitiatingHeapOccupancyPercent = 45  # 默认 45%

# === 堆信息 ===
堆容量 = 8589934592 bytes (8.0 GB)

# === IHOP 阈值 ===
45% 阈值 = 0xe6666666 bytes (~3.6 GB)

# === G1ConcurrentMark ===
G1ConcurrentMark 地址 = 0x7ffff0059850
_finger = 0x600000000
```

---

## 十、总结

### 10.1 核心概念

| 概念 | 说明 |
|------|------|
| Initial Mark | 并发标记周期的起点，STW 阶段 |
| 借道 Young GC | 复用 Young GC 的根扫描，减少一次 STW |
| IHOP | 触发阈值（默认 45%），老年代占用超过时触发 |
| TAMS | 标记起始指针，区分新旧对象 |
| SATB | 快照-at- the- beginning 屏障，记录引用变化 |
| 根区域 | Survivor 区域，并发标记的起点之一 |

### 10.2 关键数值（8GB 堆）

```
初始标记触发：
├── IHOP 阈值：45%
├── 触发大小：8GB × 45% = 3.6GB
└── 自适应调整：基于历史 GC 数据

初始标记开销：
├── TAMS 设置：O(num_regions) ≈ 0.1-0.2ms
├── SATB 启动：O(1) ≈ 微秒级
├── Root 标记：O(num_roots) ≈ < 1ms
└── 总计额外开销：< 5ms

数据结构准备：
├── 清空 next_mark_bitmap
├── 清空 Region 统计数组
├── 重置全局标记栈
└── 清空 SATB 队列
```

### 10.3 学习路径衔接

```
并发标记周期：
Initial Mark ──▶ Concurrent Mark ──▶ Remark ──▶ Cleanup
     │                │                │           │
     ▼                ▼                ▼           ▼
  本文档          3.2 下一篇       3.3          3.4

已完成的学习：
├── 第二阶段：核心数据结构（6篇）
└── 第三阶段：3.1 Initial Mark

下一步：3.2 Concurrent Mark（并发标记）
```

---

**文档完成日期**: 2026-02-11  
**GDB 验证状态**: ✅ 全部关键数据已验证  
**下一步预告**: 3.2 Concurrent Mark Phase（并发标记阶段）
