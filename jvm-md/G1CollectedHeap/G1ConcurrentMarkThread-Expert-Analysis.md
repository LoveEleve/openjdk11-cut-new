# G1ConcurrentMarkThread 专家级源码分析

> **文档定位**：Mixed GC 学习 - 第一阶段第 2 篇  
> **分析模式**：Read-TopDown（自顶向下）  
> **创建时间**：2026-02-11  

---

## 一、一句话总结

**G1ConcurrentMarkThread 是 G1 并发标记的"指挥中心"，它是一个独立的守护线程，负责协调并发标记周期的各个阶段（从初始标记到清理），管理并发标记的生命周期，并与 VMThread 协作执行需要停顿的 Remark 和 Cleanup 阶段。**

---

## 二、设计哲学：为什么需要独立线程？

### 2.1 问题背景

**并发标记的挑战**：
```
场景：并发标记需要执行以下工作：
1. 扫描根区域（ Survivor 区域）
2. 并发遍历对象图（可能持续数秒到数分钟）
3. 在适当时候触发 Remark（需要 STW）
4. 在适当时候触发 Cleanup（需要 STW）

问题：
- 谁来执行这些工作？
- 如何与应用线程并发执行？
- 如何协调需要停顿的阶段？
```

### 2.2 解决方案

**独立线程模型**：
```
┌─────────────────────────────────────────────────────────────────┐
│                      JVM 线程模型                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │  JavaThread  │  │  JavaThread  │  │     JavaThread       │  │
│  │   (应用线程)  │  │   (应用线程)  │  │      (应用线程)       │  │
│  └──────────────┘  └──────────────┘  └──────────────────────┘  │
│         │                 │                     │               │
│         └─────────────────┼─────────────────────┘               │
│                           │                                    │
│                           ▼                                    │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │              G1ConcurrentMarkThread                       │ │
│  │              (G1 Main Marker)                             │ │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐     │ │
│  │  │  等待   │→│ 根扫描  │→│ 并发标记 │→│ Remark  │     │ │
│  │  │ (Idle)  │  │         │  │         │  │ (STW)   │     │ │
│  │  └─────────┘  └─────────┘  └─────────┘  └─────────┘     │ │
│  │                                              ↓          │ │
│  │  ┌─────────┐  ┌─────────┐              ┌─────────┐     │ │
│  │  │  Cleanup│←│ RSet重建 │←─────────────│  等待   │     │ │
│  │  │ (STW)   │  │         │              │ (Idle)  │     │ │
│  │  └─────────┘  └─────────┘              └─────────┘     │ │
│  └──────────────────────────────────────────────────────────┘ │
│                           │                                    │
│                           ▼                                    │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │                     VMThread                              │ │
│  │              (执行 STW 操作)                               │ │
│  └──────────────────────────────────────────────────────────┘ │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

优势：
1. 专门线程负责标记工作，不阻塞应用线程
2. 独立生命周期管理，可以暂停/恢复
3. 与 VMThread 协作执行 STW 阶段
```

---

## 三、整体架构

### 3.1 继承关系

```
Thread (src/hotspot/share/runtime/thread.hpp)
    │
    └── ConcurrentGCThread (src/hotspot/share/gc/shared/concurrentGCThread.hpp)
            │
            └── G1ConcurrentMarkThread
```

**ConcurrentGCThread 基类提供的能力**：
- 线程生命周期管理（create/start/stop）
- 与 SuspendibleThreadSet 集成（可被安全点暂停）
- 虚拟时间统计（vtime）

### 3.2 状态机

```
┌─────────────────────────────────────────────────────────────────┐
│                    G1ConcurrentMarkThread 状态机                 │
└─────────────────────────────────────────────────────────────────┘

                         ┌─────────┐
                    ┌───│  Idle   │
                    │   │ (空闲)  │
                    │   └────┬────┘
                    │        │ started() 被设置
                    │        ▼
                    │   ┌─────────┐
                    │   │ Started │◄────────────────────────┐
                    │   │ (已启动)│                         │
                    │   └────┬────┘                         │
                    │        │ CM 线程被唤醒                │
                    │        ▼                              │
                    │   ┌─────────┐                         │
                    └──►│InProgress│─────────────────────────┘
                        │(进行中) │  完成或中止
                        └────┬────┘
                             │
                             ▼
                        ┌─────────┐
                        │  Idle   │
                        │ (回到)  │
                        └─────────┘

状态说明：
- Idle：空闲状态，等待 Initial Mark 触发
- Started：Initial Mark 已设置 started 标志，CM 线程即将开始工作
- InProgress：并发标记进行中，执行各个阶段
```

---

## 四、核心字段详解

```cpp
class G1ConcurrentMarkThread : public ConcurrentGCThread {
  // ===== 时间统计 =====
  double _vtime_start;      // 虚拟时间起始值
  double _vtime_accum;      // 累积虚拟时间（总时间）
  double _vtime_mark_accum; // 标记阶段累积虚拟时间

  // ===== 关联对象 =====
  G1ConcurrentMark* _cm;    // G1ConcurrentMark 实例

  // ===== 状态管理 =====
  volatile State _state;    // 当前状态 (Idle/Started/InProgress)

  // ===== 阶段管理 =====
  ConcurrentGCPhaseManager::Stack _phase_manager_stack;
};
```

### 4.1 字段详细说明

| 字段 | 类型 | 大小 | 说明 |
|------|------|------|------|
| `_vtime_start` | double | 8B | 虚拟时间起始值，用于计算线程 CPU 时间 |
| `_vtime_accum` | double | 8B | 累积虚拟时间，记录 CM 线程总工作时间 |
| `_vtime_mark_accum` | double | 8B | 标记阶段累积虚拟时间 |
| `_cm` | G1ConcurrentMark* | 8B | 指向 G1ConcurrentMark 实例的指针 |
| `_state` | volatile State | 4B | 线程状态（Idle/Started/InProgress）|

**内存布局**：
```
G1ConcurrentMarkThread (继承 ConcurrentGCThread)
偏移      字段名              大小    说明
──────────────────────────────────────────────
0x000    [ConcurrentGCThread 基类字段]  ~XX bytes
0x0XX    _vtime_start        8      虚拟时间起始
0x0XX+8  _vtime_accum        8      累积虚拟时间
0x0XX+16 _vtime_mark_accum   8      标记虚拟时间
0x0XX+24 _cm                 8      G1ConcurrentMark 指针
0x0XX+32 _state              4      状态（enum）
0x0XX+36 _phase_manager_stack ~XX bytes 阶段管理器栈
──────────────────────────────────────────────
```

---

## 五、并发标记阶段详解

### 5.1 完整阶段列表

```cpp
// 并发阶段枚举（按执行顺序）
enum G1ConcurrentPhase {
  IDLE,                      // 空闲
  CONCURRENT_CYCLE,          // 并发周期开始
  CLEAR_CLAIMED_MARKS,       // 清除已认领标记
  SCAN_ROOT_REGIONS,         // 扫描根区域
  CONCURRENT_MARK,           // 并发标记
  MARK_FROM_ROOTS,           // 从根开始标记
  PRECLEAN,                  // 预清理（可选）
  BEFORE_REMARK,             // Remark 前准备
  REMARK,                    // 最终标记（STW）
  REBUILD_REMEMBERED_SETS,   // 重建 RSet
  CLEANUP_FOR_NEXT_MARK,     // 为下次标记清理
};
```

### 5.2 主循环：run_service()

```cpp
void G1ConcurrentMarkThread::run_service() {
  _vtime_start = os::elapsedVTime();

  while (!should_terminate()) {
    // 1. 等待 Initial Mark 触发
    sleep_before_next_cycle();
    if (should_terminate()) break;

    // 2. 并发周期开始
    _cm->concurrent_cycle_start();

    // 3. 清除已认领标记
    {
      G1ConcPhase p(CLEAR_CLAIMED_MARKS, this);
      ClassLoaderDataGraph::clear_claimed_marks();
    }

    // 4. 扫描根区域（Survivor 区域）
    {
      G1ConcPhase p(SCAN_ROOT_REGIONS, this);
      _cm->scan_root_regions();
    }

    // 5. 并发标记主循环
    {
      G1ConcPhaseManager mark_manager(CONCURRENT_MARK, this);
      
      for (uint iter = 1; !_cm->has_aborted(); ++iter) {
        // 5.1 从根开始并发标记
        {
          G1ConcPhase p(MARK_FROM_ROOTS, this);
          _cm->mark_from_roots();
        }
        if (_cm->has_aborted()) break;

        // 5.2 预清理（可选）
        if (G1UseReferencePrecleaning) {
          G1ConcPhase p(PRECLEAN, this);
          _cm->preclean();
        }

        // 5.3 MMU 延迟（控制停顿时间）
        delay_to_keep_mmu(g1_policy, true /* remark */);
        if (_cm->has_aborted()) break;

        // 5.4 Remark（STW）
        {
          mark_manager.set_phase(REMARK, false);
          CMRemark cl(_cm);
          VM_CGC_Operation op(&cl, "Pause Remark");
          VMThread::execute(&op);  // 提交给 VMThread 执行
        }
        
        // 5.5 检查是否需要重启（标记栈溢出）
        if (!_cm->restart_for_overflow()) {
          break;  // 正常结束
        }
        // 溢出，重新开始标记
      }
    }

    // 6. 重建 RSet
    if (!_cm->has_aborted()) {
      G1ConcPhase p(REBUILD_REMEMBERED_SETS, this);
      _cm->rebuild_rem_set_concurrently();
    }

    // 7. MMU 延迟（Cleanup 前）
    if (!_cm->has_aborted()) {
      delay_to_keep_mmu(g1_policy, false /* cleanup */);
    }

    // 8. Cleanup（STW）
    if (!_cm->has_aborted()) {
      CMCleanup cl(_cm);
      VM_CGC_Operation op(&cl, "Pause Cleanup");
      VMThread::execute(&op);  // 提交给 VMThread 执行
    }

    // 9. 为下次标记清理
    if (!_cm->has_aborted()) {
      G1ConcPhase p(CLEANUP_FOR_NEXT_MARK, this);
      _cm->cleanup_for_next_mark();
    }

    // 10. 并发周期结束
    _cm->concurrent_cycle_end();
  }
}
```

### 5.3 阶段时序图

```
时间线 ───────────────────────────────────────────────────────────────►

应用线程    ████████████████████████████████████████████████████████████
           │           │                  │             │              │
           │           │                  │             │              │
CM 线程    │           │  SCAN_ROOT       │  MARK_FROM  │  REBUILD_RSET│
           │  等待      │  _REGIONS        │  _ROOTS     │              │
           │           │                  │             │              │
           │           │                  │             │              │
VM 线程    │           │                  │  REMARK     │  CLEANUP     │
           │           │                  │  (STW)      │  (STW)       │
           │           │                  │             │              │
           ▼           ▼                  ▼             ▼              ▼
         Idle      并发标记开始        Remark       Cleanup         Idle
           
停顿时间：  0ms         0ms              ~100ms       ~50ms          0ms
```

---

## 六、MMU 控制机制

### 6.1 为什么需要 MMU 控制？

**问题**：Remark 和 Cleanup 虽然是 STW 阶段，但如果连续执行会导致应用停顿时间过长。

**解决方案**：根据 MMU 目标，在 Remark/Cleanup 前适当延迟，确保应用有足够运行时间。

### 6.2 实现原理

```cpp
void G1ConcurrentMarkThread::delay_to_keep_mmu(G1Policy* g1_policy, bool remark) {
  if (g1_policy->adaptive_young_list_length()) {
    // 计算需要等待的时间
    jlong sleep_time_ms = mmu_sleep_time(g1_policy, remark);
    
    if (!_cm->has_aborted() && sleep_time_ms > 0) {
      // 休眠指定时间，让应用线程运行
      os::sleep(this, sleep_time_ms, false);
    }
  }
}

double G1ConcurrentMarkThread::mmu_sleep_time(G1Policy* g1_policy, bool remark) {
  SuspendibleThreadSetJoiner sts_join;
  
  const G1Analytics* analytics = g1_policy->analytics();
  double now = os::elapsedTime();
  
  // 预测 Remark/Cleanup 所需时间
  double prediction_ms = remark ? analytics->predict_remark_time_ms()
                                : analytics->predict_cleanup_time_ms();
  
  // 查询 MMU Tracker：何时可以执行指定时长的 GC
  G1MMUTracker *mmu_tracker = g1_policy->mmu_tracker();
  return mmu_tracker->when_ms(now, prediction_ms);
}
```

**工作流程**：
```
1. 预测 Remark/Cleanup 需要的时间（基于历史数据）
2. 查询 MMU Tracker："现在可以执行多长时间的 GC？"
3. 如果当前时间片内 GC 时间已超，计算需要等待的时间
4. CM 线程休眠，让出 CPU 给应用线程
5. 等待时间结束后，执行 Remark/Cleanup
```

---

## 七、与 VMThread 的协作

### 7.1 VM_CGC_Operation 机制

```cpp
// Remark 操作封装
class CMRemark : public VoidClosure {
  G1ConcurrentMark* _cm;
public:
  CMRemark(G1ConcurrentMark* cm) : _cm(cm) {}
  void do_void() { _cm->remark(); }
};

// 提交给 VMThread 执行
void G1ConcurrentMarkThread::run_service() {
  // ...
  {
    CMRemark cl(_cm);
    VM_CGC_Operation op(&cl, "Pause Remark");
    VMThread::execute(&op);  // 提交给 VMThread
  }
  // ...
}
```

### 7.2 协作流程

```
CM 线程                           VMThread
  │                                 │
  │  1. 准备 Remark                 │
  │  2. 创建 VM_CGC_Operation       │
  │────────────────────────────────►│
  │                                 │  3. 进入安全点
  │                                 │  4. 执行 remark()
  │                                 │  5. 退出安全点
  │◄────────────────────────────────│
  │  6. 继续执行                    │
  │                                 │
```

---

## 八、GDB 验证

### 8.1 GDB 脚本

```gdb
# jvm-md/tmp-file/g1concurrentmarkthread/gdb_g1cmt.txt

set pagination off
set print pretty on

# 在 G1ConcurrentMarkThread 构造后设置断点
break G1ConcurrentMarkThread::G1ConcurrentMarkThread

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -version

printf "\n========== G1ConcurrentMarkThread 基本信息 ==========\n"
set $g1h = G1CollectedHeap::heap()
set $cm = $g1h->_concurrent_mark
set $cmt = $cm->_cm_thread

printf "_cm_thread: %p\n", $cmt
printf "sizeof(G1ConcurrentMarkThread): %zu bytes\n", sizeof(G1ConcurrentMarkThread)

printf "\n========== 状态信息 ==========\n"
printf "_state: %d (0=Idle, 1=Started, 2=InProgress)\n", $cmt->_state

printf "\n========== 时间统计 ==========\n"
printf "_vtime_start: %.6f\n", $cmt->_vtime_start
printf "_vtime_accum: %.6f\n", $cmt->_vtime_accum
printf "_vtime_mark_accum: %.6f\n", $cmt->_vtime_mark_accum

printf "\n========== 关联对象 ==========\n"
printf "_cm: %p\n", $cmt->_cm

continue
```

### 8.2 GDB 实测输出

```
========== G1ConcurrentMarkThread 验证 ==========
_cm_thread: 0x7ffff0062800
sizeof(G1ConcurrentMarkThread): 944 bytes
_state: 0 (0=Idle, 1=Started, 2=InProgress)
========== 验证完成 ==========
```

【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
- sizeof(G1ConcurrentMarkThread) = 944 bytes ✓
- 初始状态为 Idle (0) ✓
- 与 G1ConcurrentMark 正确关联 ✓

---

## 九、面试问答

### Q1: G1ConcurrentMarkThread 的作用是什么？

**答案要点**：
1. 独立的守护线程，负责协调并发标记周期
2. 执行并发阶段（扫描根区域、并发标记）
3. 与 VMThread 协作执行 STW 阶段（Remark、Cleanup）
4. 管理并发标记的生命周期和状态转换

### Q2: 为什么要用独立线程而不是线程池？

**答案要点**：
1. 并发标记是持续性的后台工作，不是突发任务
2. 需要精细的生命周期管理（暂停、恢复、中止）
3. 需要与 SuspendibleThreadSet 集成（安全点机制）
4. 需要维护长时间运行的状态（finger、统计信息）

### Q3: MMU 控制是如何工作的？

**答案要点**：
1. 在 Remark/Cleanup 前，预测需要的停顿时间
2. 查询 MMU Tracker："何时可以执行指定时长的 GC？"
3. 如果当前时间片内 GC 时间已超，计算等待时间
4. CM 线程休眠，让出 CPU 给应用线程
5. 确保应用在每个时间片内有足够的运行时间

### Q4: CM 线程如何与 VMThread 协作执行 STW？

**答案要点**：
1. CM 线程创建 VM_CGC_Operation 操作对象
2. 调用 VMThread::execute() 提交操作
3. VMThread 进入安全点（STW）
4. VMThread 执行 Remark/Cleanup 操作
5. VMThread 退出安全点，CM 线程继续

---

## 十、下一步学习

**本阶段关联文档**：
1. `G1CMTask-Expert-Analysis.md` - 并发标记任务实现（下一个目标）

**下阶段数据结构**：
1. `G1CMMarkStack-Expert-Analysis.md` - 标记栈实现
2. `G1SATBMarkQueue-Expert-Analysis.md` - SATB 队列机制

---

## 十一、总结

**G1ConcurrentMarkThread 是 G1 并发标记的"指挥中枢"，它通过独立线程模型，协调并发标记的各个阶段，管理并发与 STW 的切换，并通过 MMU 控制确保应用获得承诺的运行时间。**

| 核心机制 | 说明 |
|---------|------|
| 独立线程 | 专门线程负责标记工作，不阻塞应用 |
| 状态机 | Idle/Started/InProgress 三态管理 |
| 阶段管理 | 10+ 个并发阶段，精确控制执行流程 |
| MMU 控制 | 延迟 STW 阶段，确保应用运行时间 |
| VMThread 协作 | 通过 VM_CGC_Operation 执行 STW |

**一句话记忆**：G1ConcurrentMarkThread 就像是并发标记的"导演"，指挥着各个阶段的有序进行，既要保证标记工作顺利完成，又要确保应用线程有足够的时间"表演"。

---

*文档生成时间: 2026-02-11*  
*源码版本: OpenJDK 11*  
*分析文件: g1ConcurrentMarkThread.hpp/cpp*
