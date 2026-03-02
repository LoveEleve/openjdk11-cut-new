# G1GCPhaseTimes 专家级源码分析

## 一、一句话总结

**G1GCPhaseTimes 是 G1 的垃圾回收"性能仪表盘"，它精确记录 GC 暂停期间 30+ 个阶段的耗时（从根扫描到对象复制再到 CSet 释放），并生成结构化的 GC 日志，是 GC 调优和问题诊断的核心数据源。**

---

## 二、设计哲学：为什么需要详细计时？

### 2.1 问题背景

当 GC 暂停时间过长时，开发者需要知道**时间花在哪里**：

```
场景：Young GC 耗时 500ms，远超 200ms 目标
问题：这 500ms 都花在哪了？
  - 是根扫描太慢？
  - 是对象复制太多？
  - 是 RSet 更新阻塞？
  - 还是终止协议等待？
```

### 2.2 解决方案

**G1GCPhaseTimes 的设计目标**：
1. **全覆盖**：记录 GC 暂停的每个阶段
2. **多线程感知**：记录每个 GC 线程的独立耗时
3. **层级输出**：支持 info/debug/trace 多级日志
4. **辅助计数**：不仅记录时间，还记录工作量（扫描多少卡片、复制多少对象）

### 2.3 典型 GC 日志输出

```
[0.8s][info][gc,phases] GC(0) Pre Evacuate Collection Set: 12.3ms
[0.8s][info][gc,phases] GC(0) Evacuate Collection Set: 156.7ms
[0.8s][debug][gc,phases] GC(0)   Ext Root Scanning: 15.2ms
[0.8s][debug][gc,phases] GC(0)   Update RS: 45.3ms
[0.8s][debug][gc,phases] GC(0)     Processed Buffers: 1234
[0.8s][debug][gc,phases] GC(0)   Scan RS: 32.1ms
[0.8s][debug][gc,phases] GC(0)   Object Copy: 58.9ms
[0.8s][info][gc,phases] GC(0) Post Evacuate Collection Set: 28.4ms
```

---

## 三、整体架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                        G1GCPhaseTimes                               │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                    GCParPhases (枚举)                         │  │
│  │  GCWorkerStart, ExtRootScan, ThreadRoots, StringTableRoots,  │  │
│  │  UniverseRoots, JNIRoots, ..., UpdateRS, ScanRS, ObjCopy,    │  │
│  │  Termination, ..., YoungFreeCSet, NonYoungFreeCSet           │  │
│  │  共 30+ 个阶段                                                │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                              │                                      │
│                              ▼                                      │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │              WorkerDataArray<double> 数组                     │  │
│  │  _gc_par_phases[GCParPhasesSentinel]                          │  │
│  │  每个阶段一个数组，存储每个 worker 的耗时                      │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                              │                                      │
│                              ▼                                      │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                    辅助计数器                                 │  │
│  │  • _update_rs_processed_buffers                              │  │
│  │  • _scan_rs_scanned_cards                                    │  │
│  │  • _termination_attempts                                     │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                              │                                      │
│                              ▼                                      │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                    输出方法                                   │  │
│  │  print() → print_pre_evacuate()                             │  │
│  │         → print_evacuate()                                  │  │
│  │         → print_post_evacuate()                             │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │   GC 日志输出    │
                    │  -Xlog:gc,phases │
                    └─────────────────┘
```

---

## 四、核心数据结构详解

### 4.1 GCParPhases 枚举 - 定义所有 GC 阶段

```cpp
enum GCParPhases {
  // ===== Worker 生命周期 =====
  GCWorkerStart,          // Worker 线程开始
  GCWorkerEnd,            // Worker 线程结束
  GCWorkerTotal,          // Worker 总耗时

  // ===== 根扫描阶段 =====
  ExtRootScan,            // 外部根扫描（总入口）
  ThreadRoots,            // Java 线程栈
  StringTableRoots,       // 字符串表
  UniverseRoots,          // JVM 内部对象
  JNIRoots,               // JNI 全局引用
  ObjectSynchronizerRoots,// 同步锁对象
  ManagementRoots,        // MXBean 对象
  SystemDictionaryRoots,  // 系统字典
  CLDGRoots,              // 类加载器数据图
  JVMTIRoots,             // JVMTI 代理
  CMRefRoots,             // 并发标记引用
  WaitForStrongCLD,       // 等待强 CLD
  WeakCLDRoots,           // 弱 CLD
  SATBFiltering,          // SATB 过滤

  // ===== RSet 处理阶段 =====
  UpdateRS,               // 更新 RSet
  ScanHCC,                // 扫描热卡片缓存
  ScanRS,                 // 扫描 RSet

  // ===== 代码根 =====
  CodeRoots,              // 代码根扫描
  AOTCodeRoots,           // AOT 代码根

  // ===== 疏散阶段 =====
  ObjCopy,                // 对象复制
  Termination,            // 终止协议
  Other,                  // 其他时间

  // ===== 字符串去重 =====
  StringDedupQueueFixup,  // 去重队列修复
  StringDedupTableFixup,  // 去重表修复

  // ===== 清理阶段 =====
  RedirtyCards,           // 重新标记脏卡
  YoungFreeCSet,          // 释放年轻代 CSet
  NonYoungFreeCSet,       // 释放非年轻代 CSet

  GCParPhasesSentinel     // 哨兵，用于数组大小
};
```

### 4.2 WorkerDataArray - 线程数据数组模板

```cpp
template <class T>
class WorkerDataArray : public CHeapObj<mtGC> {
  uint _length;           // Worker 数量
  const char* _title;     // 标题（用于日志输出）
  T* _data;              // 数据数组
  WorkerDataArray<size_t>* _thread_work_items[MaxThreadWorkItems];

public:
  void set(uint worker_i, T value);      // 设置指定 worker 的值
  T get(uint worker_i) const;            // 获取指定 worker 的值
  void add(uint worker_i, T value);      // 累加值
  T sum() const;                         // 求和
  T average() const;                     // 平均值
  T minimum() const;                     // 最小值
  T maximum() const;                     // 最大值
  T diff() const;                        // 最大值-最小值（负载不均衡度）
  void reset();                          // 重置所有值
};
```

**用途**：存储每个 GC 线程在特定阶段的耗时或工作量。

**示例**：
```
_gc_par_phases[UpdateRS] = 
  Worker[0]: 45.2ms
  Worker[1]: 42.8ms
  Worker[2]: 48.1ms
  Worker[3]: 44.5ms
  Sum: 180.6ms, Avg: 45.15ms, Min: 42.8ms, Max: 48.1ms, Diff: 5.3ms
```

### 4.3 G1GCPhaseTimes 主类字段

```cpp
class G1GCPhaseTimes : public CHeapObj<mtGC> {
  // 基础信息
  uint _max_gc_threads;                    // 最大 GC 线程数
  jlong _gc_start_counter;                 // GC 开始时间戳
  double _gc_pause_time_ms;                // GC 总暂停时间

  // 并行阶段数据（每个阶段一个 WorkerDataArray）
  WorkerDataArray<double>* _gc_par_phases[GCParPhasesSentinel];

  // UpdateRS 阶段的详细计数
  WorkerDataArray<size_t>* _update_rs_processed_buffers;  // 处理的缓冲区数
  WorkerDataArray<size_t>* _update_rs_scanned_cards;      // 扫描的卡片数
  WorkerDataArray<size_t>* _update_rs_skipped_cards;      // 跳过的卡片数

  // ScanRS 阶段的详细计数
  WorkerDataArray<size_t>* _scan_rs_scanned_cards;        // 扫描的卡片数
  WorkerDataArray<size_t>* _scan_rs_claimed_cards;        // 认领的卡片数
  WorkerDataArray<size_t>* _scan_rs_skipped_cards;        // 跳过的卡片数

  // Termination 阶段统计
  WorkerDataArray<size_t>* _termination_attempts;         // 终止尝试次数

  // RedirtyCards 阶段统计
  WorkerDataArray<size_t>* _redirtied_cards;              // 重新标记的卡片数

  // 串行阶段时间（非并行，单线程执行）
  double _cur_collection_par_time_ms;           // 并行收集时间
  double _cur_collection_code_root_fixup_time_ms;  // 代码根修复时间
  double _cur_strong_code_root_purge_time_ms;   // 强代码根清理时间
  double _cur_evac_fail_recalc_used;            // 疏散失败重计算时间
  double _cur_evac_fail_remove_self_forwards;   // 疏散失败移除自转发时间
  double _cur_string_dedup_fixup_time_ms;       // 字符串去重修复时间
  double _cur_prepare_tlab_time_ms;             // 准备 TLAB 时间
  double _cur_resize_tlab_time_ms;              // 调整 TLAB 时间
  double _cur_derived_pointer_table_update_time_ms;  // 派生指针表更新时间
  double _cur_clear_ct_time_ms;                 // 清理卡表时间
  double _cur_expand_heap_time_ms;              // 扩展堆时间
  double _cur_ref_proc_time_ms;                 // 引用处理时间
  double _cur_ref_enq_time_ms;                  // 引用入队时间
  double _cur_weak_ref_proc_time_ms;            // 弱引用处理时间

  // 决策阶段时间
  double _recorded_young_cset_choice_time_ms;      // 年轻代 CSet 选择时间
  double _recorded_non_young_cset_choice_time_ms;  // 非年轻代 CSet 选择时间
  double _recorded_redirty_logged_cards_time_ms;   // Redirty 卡片时间
  double _recorded_preserve_cm_referents_time_ms;  // 保留 CM 引用时间
  double _recorded_merge_pss_time_ms;              // 合并 PSS 时间
  double _recorded_start_new_cset_time_ms;         // 开始新 CSet 时间
  double _recorded_total_free_cset_time_ms;        // 释放 CSet 总时间
  double _recorded_serial_free_cset_time_ms;       // 串行释放 CSet 时间

  // 大对象快速回收统计
  double _cur_fast_reclaim_humongous_time_ms;           // 快速回收时间
  double _cur_fast_reclaim_humongous_register_time_ms;  // 注册时间
  size_t _cur_fast_reclaim_humongous_total;             // 大对象总数
  size_t _cur_fast_reclaim_humongous_candidates;        // 候选数
  size_t _cur_fast_reclaim_humongous_reclaimed;         // 实际回收数

  // 验证时间
  double _cur_verify_before_time_ms;   // GC 前验证时间
  double _cur_verify_after_time_ms;    // GC 后验证时间

  // 引用处理阶段详细时间
  ReferenceProcessorPhaseTimes _ref_phase_times;
};
```

---

## 五、核心方法详解

### 5.1 构造与初始化

```cpp
G1GCPhaseTimes::G1GCPhaseTimes(STWGCTimer* gc_timer, uint max_gc_threads) :
  _max_gc_threads(max_gc_threads),
  _gc_start_counter(0),
  _gc_pause_time_ms(0.0),
  _ref_phase_times((GCTimer*)gc_timer, max_gc_threads)
{
  // 为每个阶段创建 WorkerDataArray
  _gc_par_phases[GCWorkerStart] = new WorkerDataArray<double>(max_gc_threads, "GC Worker Start (ms):");
  _gc_par_phases[ExtRootScan] = new WorkerDataArray<double>(max_gc_threads, "Ext Root Scanning (ms):");
  // ... 其他阶段类似

  // 关联辅助计数器
  _scan_rs_scanned_cards = new WorkerDataArray<size_t>(max_gc_threads, "Scanned Cards:");
  _gc_par_phases[ScanRS]->link_thread_work_items(_scan_rs_scanned_cards, ScanRSScannedCards);

  _update_rs_processed_buffers = new WorkerDataArray<size_t>(max_gc_threads, "Processed Buffers:");
  _gc_par_phases[UpdateRS]->link_thread_work_items(_update_rs_processed_buffers, UpdateRSProcessedBuffers);

  _termination_attempts = new WorkerDataArray<size_t>(max_gc_threads, "Termination Attempts:");
  _gc_par_phases[Termination]->link_thread_work_items(_termination_attempts);

  reset();
}
```

### 5.2 记录时间

```cpp
// 记录指定 worker 在指定阶段的耗时（秒）
void G1GCPhaseTimes::record_time_secs(GCParPhases phase, uint worker_i, double secs) {
  _gc_par_phases[phase]->set(worker_i, secs);
}

// 累加时间（用于分多次记录同一阶段）
void G1GCPhaseTimes::add_time_secs(GCParPhases phase, uint worker_i, double secs) {
  _gc_par_phases[phase]->add(worker_i, secs);
}

// 记录对象复制时间（特殊处理，可能多次记录）
void G1GCPhaseTimes::record_or_add_objcopy_time_secs(uint worker_i, double secs) {
  if (_gc_par_phases[ObjCopy]->get(worker_i) == _gc_par_phases[ObjCopy]->uninitialized()) {
    record_time_secs(ObjCopy, worker_i, secs);
  } else {
    add_time_secs(ObjCopy, worker_i, secs);
  }
}

// 记录工作量（如扫描的卡片数）
void G1GCPhaseTimes::record_thread_work_item(GCParPhases phase, uint worker_i, size_t count, uint index) {
  _gc_par_phases[phase]->set_thread_work_item(worker_i, count, index);
}
```

### 5.3 GC 生命周期

```cpp
// GC 开始时调用
void G1GCPhaseTimes::note_gc_start() {
  _gc_start_counter = os::elapsed_counter();  // 记录开始时间戳
  reset();                                     // 重置所有数据
}

// GC 结束时调用（内部方法）
void G1GCPhaseTimes::note_gc_end() {
  // 计算总暂停时间
  _gc_pause_time_ms = TimeHelper::counter_to_millis(
    os::elapsed_counter() - _gc_start_counter);

  // 计算每个 worker 的总时间
  for (uint i = 0; i < _max_gc_threads; i++) {
    double worker_start = _gc_par_phases[GCWorkerStart]->get(i);
    if (worker_start != uninitialized) {
      double worker_end = _gc_par_phases[GCWorkerEnd]->get(i);
      double total_worker_time = worker_end - worker_start;
      record_time_secs(GCWorkerTotal, i, total_worker_time);

      // 计算"其他"时间 = 总时间 - 已知阶段时间
      double worker_known_time = worker_time(ExtRootScan, i) +
                                 worker_time(ScanHCC, i) +
                                 worker_time(UpdateRS, i) +
                                 worker_time(ScanRS, i) +
                                 worker_time(CodeRoots, i) +
                                 worker_time(ObjCopy, i) +
                                 worker_time(Termination, i);
      record_time_secs(Other, i, total_worker_time - worker_known_time);
    }
  }
}
```

### 5.4 日志输出

```cpp
void G1GCPhaseTimes::print() {
  note_gc_end();  // 先计算统计数据

  double accounted_ms = 0.0;

  // 输出三个阶段的大类
  accounted_ms += print_pre_evacuate_collection_set();
  accounted_ms += print_evacuate_collection_set();
  accounted_ms += print_post_evacuate_collection_set();

  // 输出"其他"时间（未统计到的时间）
  print_other(accounted_ms);
}
```

**输出示例解析：**

```
[0.8s][info][gc,phases] GC(0) Pre Evacuate Collection Set: 12.3ms
[0.8s][debug][gc,phases] GC(0)   Prepare TLABs: 2.1ms
[0.8s][debug][gc,phases] GC(0)   Choose Collection Set: 8.5ms
[0.8s][info][gc,phases] GC(0) Evacuate Collection Set: 156.7ms
[0.8s][debug][gc,phases] GC(0)   Ext Root Scanning: 15.2ms
[0.8s][debug][gc,phases] GC(0)   Update RS: 45.3ms
[0.8s][trace][gc,phases] GC(0)     Processed Buffers: 1234 (sum), 308 (avg)
[0.8s][debug][gc,phases] GC(0)   Scan RS: 32.1ms
[0.8s][debug][gc,phases] GC(0)   Object Copy: 58.9ms
[0.8s][debug][gc,phases] GC(0)   Termination: 3.2ms
[0.8s][info][gc,phases] GC(0) Post Evacuate Collection Set: 28.4ms
```

| 输出级别 | 日志标签 | 内容 |
|---------|---------|------|
| info | gc,phases | 三个阶段大类耗时 |
| debug | gc,phases | 各阶段详细耗时 |
| trace | gc,phases | 每个 worker 的详细数据 |

---

## 六、辅助计时器类

### 6.1 G1GCParPhaseTimesTracker - RAII 自动计时

```cpp
class G1GCParPhaseTimesTracker : public CHeapObj<mtGC> {
  Ticks _start_time;                        // 开始时间戳
  G1GCPhaseTimes::GCParPhases _phase;       // 当前阶段
  G1GCPhaseTimes* _phase_times;             // 目标 G1GCPhaseTimes
  uint _worker_id;                          // Worker ID

public:
  G1GCParPhaseTimesTracker(G1GCPhaseTimes* phase_times, 
                           G1GCPhaseTimes::GCParPhases phase, 
                           uint worker_id) 
    : _phase_times(phase_times), _phase(phase), _worker_id(worker_id) {
    if (_phase_times != NULL) {
      _start_time = Ticks::now();  // 构造时记录开始时间
    }
  }

  virtual ~G1GCParPhaseTimesTracker() {
    if (_phase_times != NULL) {
      // 析构时自动记录耗时
      _phase_times->record_time_secs(_phase, _worker_id, 
        (Ticks::now() - _start_time).seconds());
    }
  }
};
```

**使用方式**（RAII 模式）：
```cpp
void G1RootProcessor::process_roots(...) {
  // 构造时开始计时，析构时自动记录
  G1GCParPhaseTimesTracker tracker(_phase_times, 
                                   G1GCPhaseTimes::ExtRootScan, 
                                   worker_id);
  
  // 执行根扫描...
  scan_roots();
  
}  // 离开作用域，自动调用析构函数记录时间
```

### 6.2 G1EvacPhaseTimesTracker - 带 Trim 时间统计

```cpp
class G1EvacPhaseTimesTracker : public G1GCParPhaseTimesTracker {
  Tickspan _total_time;      // 总时间
  Tickspan _trim_time;       // Trim 队列时间
  G1EvacPhaseWithTrimTimeTracker _trim_tracker;

public:
  G1EvacPhaseTimesTracker(G1GCPhaseTimes* phase_times, 
                          G1ParScanThreadState* pss,
                          G1GCPhaseTimes::GCParPhases phase, 
                          uint worker_id);

  virtual ~G1EvacPhaseTimesTracker() {
    if (_phase_times != NULL) {
      _trim_tracker.stop();
      // 排除 trim 时间（trim 是队列处理，不算真正的对象复制）
      _start_time += _trim_time;
      _phase_times->record_or_add_objcopy_time_secs(_worker_id, _trim_time.seconds());
    }
  }
};
```

**作用**：区分"真正的对象复制时间"和"队列处理时间"，更精确地定位性能瓶颈。

---

## 七、GDB 验证

### 7.1 GDB 脚本

```gdb
# jvm-md/tmp-file/g1gcphasetimes/gdb_g1gcphasetimes.txt

set pagination off
set print pretty on

# 在 G1GCPhaseTimes::print 设置断点
break G1GCPhaseTimes::print

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

printf "\n========== G1GCPhaseTimes 基本信息 ==========\n"
set $pt = (G1GCPhaseTimes*)g1h->policy()->_phase_times
printf "_max_gc_threads: %u\n", $pt->_max_gc_threads
printf "_gc_pause_time_ms: %.3f ms\n", $pt->_gc_pause_time_ms

printf "\n========== 并行阶段耗时 ==========\n"
# UpdateRS 阶段
set $update_rs = $pt->_gc_par_phases[G1GCPhaseTimes::UpdateRS]
printf "Update RS: %.3f ms (avg)\n", $update_rs->average() * 1000.0

# ObjCopy 阶段
set $obj_copy = $pt->_gc_par_phases[G1GCPhaseTimes::ObjCopy]
printf "Object Copy: %.3f ms (avg)\n", $obj_copy->average() * 1000.0

# ScanRS 阶段
set $scan_rs = $pt->_gc_par_phases[G1GCPhaseTimes::ScanRS]
printf "Scan RS: %.3f ms (avg)\n", $scan_rs->average() * 1000.0

printf "\n========== 工作量统计 ==========\n"
# UpdateRS 处理的缓冲区数
set $update_buffers = $pt->_update_rs_processed_buffers
printf "UpdateRS Processed Buffers: %zu (sum)\n", $update_buffers->sum()

# ScanRS 扫描的卡片数
set $scan_cards = $pt->_scan_rs_scanned_cards
printf "ScanRS Scanned Cards: %zu (sum)\n", $scan_cards->sum()

continue
```

### 7.2 预期输出示例

```
========== G1GCPhaseTimes 基本信息 ==========
_max_gc_threads: 4
_gc_pause_time_ms: 156.734 ms

========== 并行阶段耗时 ==========
Update RS: 45.234 ms (avg)
Object Copy: 58.912 ms (avg)
Scan RS: 32.156 ms (avg)

========== 工作量统计 ==========
UpdateRS Processed Buffers: 1234 (sum)
ScanRS Scanned Cards: 56789 (sum)
```

---

## 八、关键设计决策

### 8.1 为什么使用 WorkerDataArray 而不是简单数组？

| 方案 | 优点 | 缺点 |
|------|------|------|
| WorkerDataArray | 封装统计计算(sum/avg/min/max/diff)，自动内存管理 | 有模板实例化开销 |
| double[] | 简单直接 | 需要手动实现统计逻辑 |
| vector<double> | 动态扩容 | 不需要扩容，GC 线程数固定 |

**选择**：WorkerDataArray，因为它封装了常用的统计计算，代码更简洁。

### 8.2 为什么区分 info/debug/trace 三级输出？

| 级别 | 适用场景 | 性能影响 |
|------|---------|---------|
| info | 生产环境，只关注总体耗时 | 最小 |
| debug | 调优阶段，查看各阶段耗时 | 中等 |
| trace | 深度诊断，查看每个 worker 详情 | 最大 |

**好处**：开发者可以根据需要选择合适的日志级别，避免不必要的性能开销。

### 8.3 为什么需要 "Other" 阶段？

```cpp
// 计算"其他"时间
record_time_secs(Other, i, total_worker_time - worker_known_time);
```

**原因**：
1. Worker 的总时间 = 各阶段时间之和
2. 但可能存在未统计的时间（如线程同步、缓存未命中等）
3. "Other" 帮助发现统计遗漏或未知的性能开销
4. 如果 "Other" 时间很大，说明有需要调查的地方

---

## 九、面试问答

### Q1: G1GCPhaseTimes 的作用是什么？

**答案要点**：
1. 记录 GC 暂停期间 30+ 个阶段的详细耗时
2. 支持多线程感知（每个 worker 独立记录）
3. 生成结构化的 GC 日志（info/debug/trace 三级）
4. 辅助记录工作量（扫描卡片数、处理缓冲区数等）
5. 为 GC 调优和问题诊断提供数据支持

### Q2: WorkerDataArray 提供哪些统计功能？

**答案要点**：
- sum()：总和
- average()：平均值
- minimum()：最小值
- maximum()：最大值
- diff()：最大值-最小值（反映负载均衡度）

### Q3: 如何查看详细的 GC 阶段耗时？

**答案要点**：
- `-Xlog:gc,gc+phases`：info 级别，显示三个阶段大类
- `-Xlog:gc,gc+phases::debug`：debug 级别，显示各阶段详细耗时
- `-Xlog:gc,gc+phases::trace`：trace 级别，显示每个 worker 的数据

### Q4: 为什么需要 G1GCParPhaseTimesTracker？

**答案要点**：
1. RAII 模式自动计时，避免手动记录开始/结束时间
2. 构造时记录开始时间，析构时自动记录耗时
3. 代码更简洁，避免遗漏
4. 支持异常安全（即使发生异常也会记录）

---

## 十、总结

**G1GCPhaseTimes 是 G1 的"性能 CT 扫描仪"，它精确记录 GC 暂停的每个阶段，帮助开发者理解"时间花在哪里"。**

| 核心功能 | 说明 |
|---------|------|
| 30+ 阶段 | 全覆盖 GC 暂停的所有阶段 |
| 多线程感知 | 每个 worker 独立记录，支持负载均衡分析 |
| 三级日志 | info/debug/trace 适应不同场景 |
| 辅助计数 | 不仅记录时间，还记录工作量 |
| RAII 计时 | G1GCParPhaseTimesTracker 自动计时 |

**一句话记忆**：G1GCPhaseTimes 就像是 GC 的"黑匣子"，详细记录每次飞行的每个阶段，帮助飞行员（开发者）分析性能问题。

---

*文档生成时间: 2026-02-11*  
*源码版本: OpenJDK 11*  
*分析文件: g1GCPhaseTimes.hpp/cpp*
