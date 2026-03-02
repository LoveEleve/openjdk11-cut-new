# G1CMTask 专家级源码分析

> **文档定位**：Mixed GC 学习 - 第一阶段第 3 篇  
> **分析模式**：Read-TopDown（自顶向下）  
> **创建时间**：2026-02-11  

---

## 一、一句话总结

**G1CMTask 是 G1 并发标记的"工作单元"，每个 GC 工作线程拥有一个独立的 Task，负责认领 Region、扫描对象、标记存活对象，并通过本地标记栈与全局标记栈协作，实现并行化的对象图遍历。**

---

## 二、设计哲学：为什么需要 Task？

### 2.1 问题背景

**并发标记的挑战**：
```
场景：需要并发标记 8GB 堆内存中的存活对象
问题：
  1. 单线程标记太慢（可能需要数分钟）
  2. 多线程如何协作？
  3. 如何避免重复扫描？
  4. 如何负载均衡？
```

### 2.2 解决方案

**Task 并行模型**：
```
┌─────────────────────────────────────────────────────────────────┐
│                     G1CMTask 并行工作模型                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  全局协调器                                                     │
│  G1ConcurrentMark                                               │
│       │                                                         │
│       ├── 全局 Finger ───────────────────────────────────────┐ │
│       │  (全局进度指针)                                       │ │
│       └── 全局标记栈 (Global Mark Stack)                      │ │
│                                                              │ │
│       ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐   │ │
│       │Task 0   │  │Task 1   │  │Task 2   │  │Task N   │   │ │
│       │         │  │         │  │         │  │         │   │ │
│       │本地队列 │  │本地队列 │  │本地队列 │  │本地队列 │   │ │
│       │本地Finger│  │本地Finger│  │本地Finger│  │本地Finger│   │ │
│       │         │  │         │  │         │  │         │   │ │
│       │ 扫描    │  │ 扫描    │  │ 扫描    │  │ 扫描    │   │ │
│       │ Region 0│  │ Region 2│  │ Region 5│  │ Region N│   │ │
│       └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘   │ │
│            │            │            │            │         │ │
│            └────────────┴────────────┴────────────┘         │ │
│                         │                                    │ │
│                    工作窃取 (Work Stealing)                  │ │
│                                                              │ │
└─────────────────────────────────────────────────────────────────┘

优势：
1. 每个线程独立工作，无锁竞争
2. 本地队列减少同步开销
3. 全局标记栈作为备份
4. 工作窃取实现负载均衡
```

---

## 三、整体架构

### 3.1 类继承关系

```
TerminatorTerminator (抽象基类)
    │
    └── G1CMTask
```

**TerminatorTerminator**：提供终止协议支持，判断是否应退出终止。

### 3.2 核心组件关系

```
G1CMTask (工作单元)
    │
    ├── G1CMTaskQueue* _task_queue      // 本地标记队列
    ├── G1CMBitMap* _next_mark_bitmap   // 标记位图
    ├── HeapWord* _finger               // 本地进度指针
    └── G1RegionMarkStatsCache _stats   // 标记统计缓存
    │
    关联：
    ├── G1ConcurrentMark* _cm           // 全局协调器
    └── G1CollectedHeap* _g1h           // G1 堆
```

---

## 四、核心字段详解

```cpp
class G1CMTask : public TerminatorTerminator {
private:
  // ===== 基本信息 =====
  uint                        _worker_id;           // 工作线程 ID
  G1CollectedHeap*            _g1h;                 // G1 堆
  G1ConcurrentMark*           _cm;                  // 全局协调器
  G1CMBitMap*                 _next_mark_bitmap;    // 标记位图
  
  // ===== 本地队列 =====
  G1CMTaskQueue*              _task_queue;          // 本地标记队列
  
  // ===== 标记统计 =====
  G1RegionMarkStatsCache      _mark_stats_cache;    // Region 标记统计缓存
  
  // ===== 时间控制 =====
  double                      _time_target_ms;      // 目标执行时间
  double                      _start_time_ms;       // 开始时间
  
  // ===== 当前 Region =====
  HeapRegion*                 _curr_region;         // 当前扫描的 Region
  HeapWord*                   _finger;              // 本地进度指针
  HeapWord*                   _region_limit;        // Region 边界
  
  // ===== 扫描计数 =====
  size_t                      _words_scanned;       // 已扫描字数
  size_t                      _words_scanned_limit; // 扫描限制
  size_t                      _refs_reached;        // 已访问引用数
  size_t                      _refs_reached_limit;  // 引用限制
  
  // ===== 工作窃取 =====
  int                         _hash_seed;           // 哈希种子（用于窃取）
  
  // ===== 状态标志 =====
  bool                        _has_aborted;         // 是否中止
  bool                        _has_timed_out;       // 是否超时
  bool                        _draining_satb_buffers; // 是否处理 SATB
};
```

### 4.1 关键字段详解

| 字段 | 类型 | 说明 |
|------|------|------|
| `_worker_id` | uint | 工作线程唯一标识 |
| `_task_queue` | G1CMTaskQueue* | 本地标记队列，存储灰色对象 |
| `_finger` | HeapWord* | 本地进度指针，指向当前扫描位置 |
| `_curr_region` | HeapRegion* | 当前认领的 Region |
| `_words_scanned` | size_t | 已扫描的字数，用于时钟检查 |
| `_refs_reached` | size_t | 已访问的引用数，用于时钟检查 |
| `_hash_seed` | int | 工作窃取时的哈希种子 |

**内存布局**：
```
G1CMTask (继承 TerminatorTerminator)
偏移      字段名                 大小    说明
──────────────────────────────────────────────
0x000    [基类字段]            ~XX     TerminatorTerminator
0x0XX    _worker_id            4       工作线程 ID
0x0XX    _g1h                  8       G1 堆指针
0x0XX    _cm                   8       G1ConcurrentMark 指针
0x0XX    _next_mark_bitmap     8       标记位图指针
0x0XX    _task_queue           8       本地队列指针
0x0XX    _mark_stats_cache     ~XX     统计缓存
0x0XX    _time_target_ms       8       目标时间
0x0XX    _start_time_ms        8       开始时间
0x0XX    _curr_region          8       当前 Region
0x0XX    _finger               8       本地进度指针
0x0XX    _region_limit         8       Region 边界
0x0XX    _words_scanned        8       已扫描字数
0x0XX    _refs_reached         8       已访问引用数
0x0XX    _hash_seed            4       哈希种子
0x0XX    _has_aborted          1       中止标志
──────────────────────────────────────────────
总大小：约 400-500 bytes（估算）
```

---

## 五、核心方法详解

### 5.1 do_marking_step() - 标记主循环

```cpp
void G1CMTask::do_marking_step(double target_ms, bool do_termination, bool is_serial) {
  // 1. 记录开始时间
  record_start_time();
  _time_target_ms = target_ms;
  
  // 2. 主循环
  while (!_has_aborted) {
    // 2.1 处理本地队列
    drain_local_queue(partially = true);
    if (_has_aborted) break;
    
    // 2.2 从全局栈获取任务
    if (get_entries_from_global_stack()) {
      continue;  // 继续处理
    }
    
    // 2.3 扫描当前 Region
    if (_curr_region != NULL) {
      scan_current_region();
      if (_has_aborted) break;
    }
    
    // 2.4 认领新 Region
    if (claim_next_region()) {
      continue;  // 继续处理新 Region
    }
    
    // 2.5 处理 SATB 缓冲区
    drain_satb_buffers();
    if (_has_aborted) break;
    
    // 2.6 尝试终止或窃取
    if (do_termination && terminator()->offer_termination()) {
      break;
    }
    
    // 2.7 尝试工作窃取
    G1TaskQueueEntry entry;
    if (try_stealing(entry)) {
      push(entry);
      continue;
    }
    
    // 2.8 检查超时
    if (has_timed_out()) {
      break;
    }
  }
  
  // 3. 记录结束时间
  record_end_time();
}
```

### 5.2 扫描对象：scan_task_entry()

```cpp
void G1CMTask::scan_task_entry(G1TaskQueueEntry task_entry) {
  if (task_entry.is_array_slice()) {
    // 处理数组切片
    process_array_slice(task_entry.slice());
  } else {
    // 处理普通对象
    oop obj = task_entry.obj();
    
    // 1. 遍历对象的所有引用字段
    OopFieldStream stream(obj);
    while (!stream.eos()) {
      T* field = stream.field_addr();
      oop ref = RawAccess<>::oop_load(field);
      
      // 2. 处理引用
      if (ref != NULL) {
        deal_with_reference(field);
      }
      
      stream.next();
    }
    
    // 3. 更新扫描计数
    _words_scanned += obj->size();
    check_limits();  // 检查是否需要时钟调用
  }
}
```

### 5.3 处理引用：deal_with_reference()

```cpp
template <class T>
inline bool G1CMTask::deal_with_reference(T* p) {
  // 1. 加载引用
  oop obj = RawAccess<>::oop_load(p);
  
  // 2. 检查是否为空
  if (obj == NULL) return false;
  
  // 3. 检查是否在堆中
  if (!_g1h->is_in_g1_reserved(obj)) return false;
  
  // 4. 获取对象所在的 Region
  HeapRegion* hr = _g1h->heap_region_containing(obj);
  
  // 5. 检查对象是否在 nTAMS 之下（需要标记）
  if (hr->is_below_nTAMS(obj)) {
    // 6. 尝试标记
    if (make_reference_grey(obj)) {
      // 7. 标记成功，对象变为灰色，入队
      return true;
    }
  }
  return false;
}
```

### 5.4 标记对象：make_reference_grey()

```cpp
inline bool G1CMTask::make_reference_grey(oop obj) {
  // 1. 尝试在位图中设置标记
  if (_next_mark_bitmap->par_mark(obj)) {
    // 2. 标记成功（之前未标记）
    
    // 3. 将对象加入本地队列
    if (!_task_queue->push(G1TaskQueueEntry::from_oop(obj))) {
      // 4. 本地队列满，转移到全局栈
      move_entries_to_global_stack();
      _task_queue->push(G1TaskQueueEntry::from_oop(obj));
    }
    
    // 5. 更新统计
    update_liveness(obj, obj->size());
    
    return true;
  }
  // 6. 已被其他线程标记
  return false;
}
```

### 5.5 认领 Region：claim_next_region()

```cpp
bool G1CMTask::claim_next_region() {
  // 1. 尝试从全局获取未扫描的 Region
  HeapRegion* hr = _cm->claim_region(_worker_id);
  
  if (hr == NULL) {
    // 2. 没有可认领的 Region
    return false;
  }
  
  // 3. 设置当前 Region
  _curr_region = hr;
  _finger = hr->bottom();
  _region_limit = hr->top();
  
  // 4. 更新 Region 限制（可能并发变化）
  update_region_limit();
  
  return true;
}
```

### 5.6 扫描当前 Region

```cpp
void G1CMTask::scan_current_region() {
  // 1. 从 finger 开始扫描
  HeapWord* curr = _finger;
  HeapWord* limit = _region_limit;
  
  while (curr < limit) {
    // 2. 检查是否已标记
    if (_next_mark_bitmap->is_marked(curr)) {
      // 3. 已标记的对象，扫描其引用
      oop obj = oop(curr);
      scan_task_entry(G1TaskQueueEntry::from_oop(obj));
      
      // 4. 更新 finger
      move_finger_to(curr + obj->size());
    }
    
    // 5. 移动到下一个对象
    curr += oop(curr)->size();
    
    // 6. 检查时钟（是否超时或需要中止）
    if (regular_clock_call()) {
      break;  // 需要退出
    }
  }
  
  // 7. Region 扫描完成
  if (_finger >= _region_limit) {
    clear_region_fields();  // 清理 Region 字段
  }
}
```

---

## 六、本地队列与全局栈协作

### 6.1 数据流动

```
标记新对象时：
    
    新发现的对象
        │
        ▼
   ┌────────────┐
   │ 尝试入本地队列 │
   └─────┬──────┘
         │
    成功？──Yes──┐
         │       ▼
        No   本地队列处理
         │       │
         ▼       │
   ┌────────────┐│
   │ 批量转移到全局栈 ││
   └─────┬──────┘│
         │       │
         ▼       │
   ┌────────────┐│
   │ 全局标记栈   │◄─┘
   └─────┬──────┘
         │
         ▼
   其他 Task 窃取处理
```

### 6.2 批量转移优化

```cpp
void G1CMTask::move_entries_to_global_stack() {
  // 1. 准备缓冲区
  G1TaskQueueEntry buffer[G1CMMarkStack::EntriesPerChunk];
  size_t n = 0;
  
  // 2. 从本地队列取出条目
  while (n < G1CMMarkStack::EntriesPerChunk && !_task_queue->is_empty()) {
    G1TaskQueueEntry entry;
    if (_task_queue->pop_local(entry)) {
      buffer[n++] = entry;
    }
  }
  
  // 3. 批量压入全局栈
  if (n > 0) {
    if (!_cm->mark_stack_push(buffer)) {
      // 4. 全局栈溢出，设置溢出标志
      set_has_aborted();
      _cm->set_has_overflown();
    }
  }
}
```

---

## 七、工作窃取机制

### 7.1 窃取流程

```cpp
bool G1CMTask::try_stealing(G1TaskQueueEntry& entry) {
  // 1. 使用哈希种子选择目标队列
  uint queue_num = (uint) (_hash_seed ^ _worker_id);
  
  // 2. 尝试从其他 Task 的队列窃取
  for (uint i = 0; i < _cm->active_tasks(); i++) {
    uint target_id = (queue_num + i) % _cm->active_tasks();
    if (target_id == _worker_id) continue;
    
    G1CMTask* target_task = _cm->task(target_id);
    
    // 3. 尝试窃取全局端
    if (target_task->_task_queue->pop_global(entry)) {
      return true;  // 窃取成功
    }
  }
  
  return false;  // 窃取失败
}
```

### 7.2 窃取策略

```
Best-of-2 策略：

1. 随机选择两个队列
2. 比较两个队列的大小
3. 从较大的队列窃取
4. 好处：减少竞争，提高成功率
```

---

## 八、时钟机制（Clock）

### 8.1 为什么需要时钟？

**问题**：
- 并发标记需要可中断（响应安全点请求）
- 需要定期检查时间配额
- 需要处理 SATB 缓冲区

**解决方案**：定期检查（时钟调用）

### 8.2 时钟检查点

```cpp
void G1CMTask::regular_clock_call() {
  // 1. 检查是否需要让出（安全点）
  if (SuspendibleThreadSet::should_yield()) {
    set_has_aborted();
    return;
  }
  
  // 2. 检查时间配额
  double elapsed = os::elapsedTime() * 1000.0 - _start_time_ms;
  if (elapsed > _time_target_ms) {
    _has_timed_out = true;
    set_has_aborted();
    return;
  }
  
  // 3. 重新计算扫描限制
  recalculate_limits();
}

void G1CMTask::check_limits() {
  // 每扫描 12KB 或每访问 1024 个引用，触发一次时钟检查
  if (_words_scanned >= _words_scanned_limit ||
      _refs_reached >= _refs_reached_limit) {
    reached_limit();
  }
}
```

---

## 九、GDB 验证

### 9.1 GDB 脚本

```gdb
# jvm-md/tmp-file/g1cmtask/gdb_g1cmtask.txt

set pagination off
set print pretty on

# 在并发标记阶段设置断点
break G1CMTask::do_marking_step

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

printf "\n========== G1CMTask 验证 ==========\n"
set $g1h = G1CollectedHeap::heap()
set $cm = $g1h->_cm
set $task0 = $cm->_tasks[0]

printf "sizeof(G1CMTask): %zu bytes\n", sizeof(G1CMTask)

printf "\n---------- Task 0 基本信息 ----------\n"
printf "_worker_id: %u\n", $task0->_worker_id
printf "_finger: %p\n", $task0->_finger
printf "_curr_region: %p\n", $task0->_curr_region
printf "_has_aborted: %d\n", $task0->_has_aborted

printf "\n---------- 扫描计数 ----------\n"
printf "_words_scanned: %zu\n", $task0->_words_scanned
printf "_refs_reached: %zu\n", $task0->_refs_reached

continue
quit
```

### 9.2 GDB 实测输出（待验证）

```
========== G1CMTask 验证 ==========
sizeof(G1CMTask): [待验证] bytes

---------- Task 0 基本信息 ----------
_worker_id: 0
_finger: [待验证]
_curr_region: [待验证]
_has_aborted: 0

---------- 扫描计数 ----------
_words_scanned: [待验证]
_refs_reached: [待验证]
```

---

## 十、面试问答

### Q1: G1CMTask 的作用是什么？

**答案要点**：
1. 每个 GC 工作线程拥有一个独立的 Task
2. 负责认领 Region、扫描对象、标记存活对象
3. 通过本地队列和全局栈协作
4. 支持工作窃取实现负载均衡

### Q2: 本地队列和全局栈的关系？

**答案要点**：
1. 本地队列：线程私有，无锁访问（LIFO）
2. 全局栈：多线程共享，CAS 操作（FIFO 窃取）
3. 本地队列满时批量转移到全局栈
4. 本地空时从全局栈获取或窃取其他队列

### Q3: 如何实现负载均衡？

**答案要点**：
1. 全局 Finger：按 Region 分配任务
2. 工作窃取：空闲线程从其他队列窃取
3. Best-of-2：选择任务最多的队列窃取
4. 终止协议：所有线程完成后统一退出

### Q4: 时钟机制的作用？

**答案要点**：
1. 响应安全点请求（让出 CPU）
2. 控制执行时间（避免单次执行过长）
3. 定期处理 SATB 缓冲区
4. 检查是否需要中止（溢出、超时等）

---

## 十一、下一步学习

**本阶段完成**：第一阶段（并发标记架构）全部完成！

**下阶段预告**：第二阶段 - 核心数据结构
1. `G1CMMarkStack-Expert-Analysis.md` - 标记栈实现
2. `G1SATBMarkQueue-Expert-Analysis.md` - SATB 队列机制

---

## 十二、总结

**G1CMTask 是 G1 并发标记的"工作单元"，每个线程独立执行标记任务，通过本地队列、全局栈和工作窃取机制，实现高效的并行对象图遍历。**

| 核心机制 | 说明 |
|---------|------|
| 本地队列 | 线程私有，无锁 LIFO |
| 全局栈 | 共享备份，CAS 操作 |
| 工作窃取 | Best-of-2 策略，负载均衡 |
| 时钟机制 | 定期检查和让出 |
| Region 认领 | 全局 Finger 分配 |

**一句话记忆**：G1CMTask 就像是并发标记的"工人"，每个工人有自己的工具箱（本地队列），从仓库（全局栈）领料，也可以向其他工人借工具（工作窃取），共同完成大楼（对象图）的建造。

---

*文档生成时间: 2026-02-11*  
*源码版本: OpenJDK 11*  
*分析文件: g1ConcurrentMark.hpp (G1CMTask 类)*
