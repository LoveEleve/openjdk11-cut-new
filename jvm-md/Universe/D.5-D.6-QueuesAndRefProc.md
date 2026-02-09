# D.5/D.6 脏卡队列与引用处理器

> **分析条件**：8GB 堆（-Xms8g -Xmx8g），G1 GC，4MB Region
> **源码位置**：`g1CollectedHeap.cpp:1464-1473`

---

## 概述

G1 使用两类队列处理并发操作：

| 队列类型 | 用途 | 触发时机 |
|----------|------|----------|
| **DirtyCardQueueSet** | 记录被修改的卡（写后屏障） | 引用字段更新 |
| **SATBMarkQueueSet** | 记录被覆盖的引用（写前屏障） | 并发标记期间 |

以及两套引用处理器处理 Java 引用对象：

| 处理器 | 用途 | 使用阶段 |
|--------|------|----------|
| **_ref_processor_stw** | STW 阶段引用处理 | Young GC、Mixed GC、Full GC |
| **_ref_processor_cm** | 并发标记引用处理 | Concurrent Marking |

---

## D.5 脏卡队列

### 源码

```cpp
// g1CollectedHeap.cpp:1464
_dirty_card_queue_set(false),  // false 表示不是 SATB 队列
```

**注意**：实际的 DirtyCardQueueSet 是 G1BarrierSet 的**静态成员**：

```cpp
// g1BarrierSet.hpp:43
class G1BarrierSet: public CardTableBarrierSet {
  static SATBMarkQueueSet  _satb_mark_queue_set;
  static DirtyCardQueueSet _dirty_card_queue_set;
};
```

### 写后屏障流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  应用线程执行: obj.field = new_value                                         │
│       ↓                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ 写后屏障 (Post Write Barrier)                                        │    │
│  │                                                                      │    │
│  │ 1. 计算卡地址: card_addr = card_table + (field_addr >> 9)           │    │
│  │                                                                      │    │
│  │ 2. 检查卡状态:                                                       │    │
│  │    if (*card_addr == dirty_card) return;  // 已脏，跳过              │    │
│  │                                                                      │    │
│  │ 3. 检查跨区域引用:                                                   │    │
│  │    if (same_region(obj, new_value)) return;  // 同区域，跳过         │    │
│  │                                                                      │    │
│  │ 4. 标记卡为脏:                                                       │    │
│  │    *card_addr = dirty_card;                                          │    │
│  │                                                                      │    │
│  │ 5. 入队到线程本地 DirtyCardQueue:                                    │    │
│  │    thread->dirty_card_queue().enqueue(card_addr);                    │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│       ↓                                                                      │
│  线程本地队列满 → 转移到全局 DirtyCardQueueSet                               │
│       ↓                                                                      │
│  并发精炼线程处理 → 更新 RSet                                                │
└─────────────────────────────────────────────────────────────────────────────┘
```

### DirtyCardQueue 数据结构

```cpp
// dirtyCardQueue.hpp:44
class DirtyCardQueue: public PtrQueue {
  // 继承自 PtrQueue
  // void** _buf;    // 缓冲区
  // size_t _index;  // 当前位置
  // size_t _sz;     // 缓冲区大小
};

// dirtyCardQueue.hpp:70
class DirtyCardQueueSet: public PtrQueueSet {
  DirtyCardQueue _shared_dirty_card_queue;  // 共享队列
  
  FreeIdSet* _free_ids;                      // 空闲 ID 池
  jint _processed_buffers_mut;               // Mutator 处理的缓冲区数
  jint _processed_buffers_rs_thread;         // 精炼线程处理的缓冲区数
  
  BufferNode* volatile _cur_par_buffer_node; // 并行迭代用
};
```

### 缓冲区处理流程

```
线程本地队列                    全局队列集                   精炼线程
┌─────────────┐              ┌─────────────┐            ┌─────────────┐
│ Thread 0    │──满──┐      │  completed  │───取出────→│ Refine 0    │
│ DCQ [...]   │      │      │  buffers    │            │ 处理 → RSet │
├─────────────┤      │      │  list       │            ├─────────────┤
│ Thread 1    │──满──┼─────→│             │───取出────→│ Refine 1    │
│ DCQ [...]   │      │      │             │            │ 处理 → RSet │
├─────────────┤      │      └─────────────┘            ├─────────────┤
│ Thread N    │──满──┘             ↓                   │ Refine N    │
│ DCQ [...]   │                Green/Yellow/Red        │ 处理 → RSet │
└─────────────┘                 区域控制               └─────────────┘
```

### 🏭 生产环境实践

**监控脏卡队列**：
```bash
-Xlog:gc+refine*=debug

# 输出示例
[gc,refine] Processed buffers: mutator 1234, rs_thread 5678
[gc,refine] Completed buffers: 15 (green: 13, yellow: 26, red: 39)
```

**问题诊断**：Update RS 时间长

```bash
# 症状
[gc,phases] Update RS (ms): Avg: 25.3  # 过长！

# 可能原因
1. 脏卡积压（精炼跟不上）
2. 跨区域引用过多
3. 大量写操作

# 解决方案
-XX:G1ConcRefinementThreads=20        # 增加精炼线程
-XX:G1RSetUpdatingPauseTimePercent=5  # 限制 Update RS 占比
```

---

## D.5.1 SATB 队列（对比理解）

**SATB = Snapshot-At-The-Beginning**

与 DirtyCardQueue 对比：

| 特性 | DirtyCardQueue | SATBMarkQueue |
|------|----------------|---------------|
| 屏障类型 | 写后屏障 | 写前屏障 |
| 记录内容 | 脏卡地址 | 被覆盖的旧引用 |
| 触发时机 | 每次引用更新 | **仅并发标记期间** |
| 用途 | 维护 RSet | 维护标记正确性 |

```cpp
// 写前屏障伪代码（并发标记期间）
void pre_write_barrier(oop* field) {
  oop old_value = *field;
  if (marking_active && old_value != NULL) {
    satb_queue.enqueue(old_value);  // 记录旧值
  }
}
```

**为什么需要 SATB？**

并发标记期间，应用线程可能：
1. 删除一个已标记对象的引用
2. 导致标记遗漏，对象被错误回收

SATB 记录所有被删除的引用，确保不会漏标。

---

## D.6 引用处理器

### 源码

```cpp
// g1CollectedHeap.cpp:1467-1473
_ref_processor_stw(NULL),              // STW 引用处理器
_is_alive_closure_stw(this),           // 存活判断闭包
_is_subject_to_discovery_stw(this),    // 引用发现判断

_ref_processor_cm(NULL),               // 并发标记引用处理器
_is_alive_closure_cm(this),            // 并发标记存活判断
_is_subject_to_discovery_cm(this),     // 并发标记引用发现
```

### 为什么需要两套引用处理器？

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         G1 GC 两种引用处理场景                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  场景 1: STW 暂停（Young GC / Mixed GC）                                     │
│  ┌────────────────────────────────────────────────────────────────────┐     │
│  │  使用 _ref_processor_stw                                           │     │
│  │  • 发现范围：整个 Collection Set                                    │     │
│  │  • 处理时机：暂停期间                                               │     │
│  │  • 存活判断：对象是否在 CSet 外或已复制                              │     │
│  └────────────────────────────────────────────────────────────────────┘     │
│                                                                              │
│  场景 2: 并发标记（Concurrent Marking）                                      │
│  ┌────────────────────────────────────────────────────────────────────┐     │
│  │  使用 _ref_processor_cm                                            │     │
│  │  • 发现范围：整个堆                                                 │     │
│  │  • 处理时机：Remark 暂停                                            │     │
│  │  • 存活判断：对象是否被并发标记标记为存活                            │     │
│  └────────────────────────────────────────────────────────────────────┘     │
│                                                                              │
│  切换逻辑（每次 Young GC）：                                                  │
│  1. 禁用 _ref_processor_cm 的发现                                            │
│  2. 启用 _ref_processor_stw 的发现                                           │
│  3. 执行 GC                                                                  │
│  4. 处理 _ref_processor_stw 发现的引用                                       │
│  5. 恢复 _ref_processor_cm 的状态                                            │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 引用处理的四种类型

```cpp
// referenceProcessor.hpp:175
enum RefProcSubPhases {
  SoftRefSubPhase1,    // 软引用 Phase 1
  SoftRefSubPhase2,    // 软引用 Phase 2
  WeakRefSubPhase2,    // 弱引用
  FinalRefSubPhase2,   // Final 引用
  FinalRefSubPhase3,   // Final 引用（入队）
  PhantomRefSubPhase4, // 虚引用
};
```

**处理顺序**：

```
Phase 1: 处理 SoftReference
         └── 根据内存压力决定是否清理
         
Phase 2: 处理 WeakReference + 继续处理 SoftReference
         └── 引用对象不可达则清理
         
Phase 3: 处理 FinalReference
         └── 将需要 finalize 的对象入队到 Finalizer 队列
         
Phase 4: 处理 PhantomReference
         └── 引用对象被回收后通知
```

### ReferenceProcessor 构造

```cpp
// g1CollectedHeap.cpp:2529
_ref_processor_cm = new ReferenceProcessor(
    &_is_subject_to_discovery_cm,
    mt_processing,                                  // 多线程处理
    ParallelGCThreads,                              // 处理线程数
    (ParallelGCThreads > 1) || (ConcGCThreads > 1), // 多线程发现
    MAX2(ParallelGCThreads, ConcGCThreads),         // 发现线程数
    ...
);

_ref_processor_stw = new ReferenceProcessor(
    &_is_subject_to_discovery_stw,
    mt_processing,                        // 多线程处理
    ParallelGCThreads,                    // 处理线程数
    (ParallelGCThreads > 1),              // 多线程发现
    ParallelGCThreads,                    // 发现线程数
    ...
);
```

**8GB 堆（16 核）配置**：
```
_ref_processor_stw:
  处理线程数 = 13
  发现线程数 = 13

_ref_processor_cm:
  处理线程数 = 13
  发现线程数 = MAX(13, ConcGCThreads) = 13
```

### 🏭 生产环境实践

**监控引用处理**：
```bash
-Xlog:gc+ref*=debug

# 输出示例
[gc,ref] Ref Counts: Soft: 1234 Weak: 5678 Final: 12 Phantom: 45
[gc,ref] Ref Proc: 15.2ms
  SoftRef: 3.1ms
  WeakRef: 8.5ms
  FinalRef: 2.1ms
  PhantomRef: 1.5ms
```

**常见问题**：

| 问题 | 症状 | 解决方案 |
|------|------|----------|
| Ref Proc 时间长 | > 10% 暂停时间 | 启用并行处理 |
| WeakRef 过多 | WeakRef 处理慢 | 检查 WeakHashMap 使用 |
| Finalizer 堆积 | FinalRef 处理慢 | 减少 finalize() 使用 |

**调优参数**：
```bash
# 并行引用处理（默认已启用）
-XX:+ParallelRefProcEnabled

# 软引用策略
-XX:SoftRefLRUPolicyMSPerMB=1000  # 每 MB 空闲内存保留软引用 1 秒
```

---

## 完整架构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        G1 写屏障与引用处理架构                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  应用线程                                                                    │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ obj.field = new_value                                                │   │
│  └───────────────┬─────────────────────────────┬───────────────────────┘   │
│                  ↓                             ↓                            │
│  ┌───────────────────────────┐  ┌───────────────────────────┐              │
│  │ 写前屏障 (SATB)           │  │ 写后屏障 (Card Marking)    │              │
│  │ (仅并发标记期间)          │  │ (始终启用)                 │              │
│  │                           │  │                            │              │
│  │ 记录 old_value            │  │ 标记卡为脏                 │              │
│  │       ↓                   │  │       ↓                    │              │
│  │ SATBMarkQueue             │  │ DirtyCardQueue             │              │
│  └───────────┬───────────────┘  └───────────┬────────────────┘              │
│              ↓                              ↓                               │
│  ┌───────────────────────────┐  ┌───────────────────────────┐              │
│  │ SATBMarkQueueSet          │  │ DirtyCardQueueSet         │              │
│  │ (全局)                    │  │ (全局)                    │              │
│  └───────────┬───────────────┘  └───────────┬────────────────┘              │
│              ↓                              ↓                               │
│  ┌───────────────────────────┐  ┌───────────────────────────┐              │
│  │ Remark 暂停处理           │  │ 并发精炼线程处理          │              │
│  │ → 确保标记完整            │  │ → 更新 RSet               │              │
│  └───────────────────────────┘  └───────────────────────────┘              │
│                                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                        引用处理器                                            │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                                                                      │   │
│  │  _ref_processor_stw              _ref_processor_cm                  │   │
│  │  ┌──────────────────┐           ┌──────────────────┐                │   │
│  │  │ Young/Mixed GC   │           │ Concurrent Mark  │                │   │
│  │  │                  │           │                  │                │   │
│  │  │ • SoftRef        │           │ • SoftRef        │                │   │
│  │  │ • WeakRef        │           │ • WeakRef        │                │   │
│  │  │ • FinalRef       │           │ • FinalRef       │                │   │
│  │  │ • PhantomRef     │           │ • PhantomRef     │                │   │
│  │  └──────────────────┘           └──────────────────┘                │   │
│  │         ↓                              ↓                            │   │
│  │  _is_alive_closure_stw          _is_alive_closure_cm                │   │
│  │  (CSet 外或已复制?)             (被标记为存活?)                      │   │
│  │                                                                      │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## GDB 验证脚本

```bash
# 文件：jvm-md/tmp-file/universe-init/gdb_queues_refproc.txt

# 验证 DirtyCardQueueSet
b G1BarrierSet::G1BarrierSet
commands
  printf "\n=== D.5 DirtyCardQueueSet 验证 ===\n"
  printf "  G1BarrierSet::_dirty_card_queue_set 地址: %p\n", &G1BarrierSet::_dirty_card_queue_set
  printf "  G1BarrierSet::_satb_mark_queue_set 地址: %p\n", &G1BarrierSet::_satb_mark_queue_set
  continue
end

# 验证引用处理器创建
b g1CollectedHeap.cpp:2540
commands
  printf "\n=== D.6 引用处理器验证 ===\n"
  printf "  _ref_processor_cm = %p\n", _ref_processor_cm
  printf "  _ref_processor_stw = %p (即将创建)\n", _ref_processor_stw
  printf "  ParallelGCThreads = %d\n", ParallelGCThreads
  printf "  ParallelRefProcEnabled = %d\n", ParallelRefProcEnabled
  continue
end

# 验证创建后
b g1CollectedHeap.cpp:2550
commands
  printf "\n=== 引用处理器创建完成 ===\n"
  printf "  _ref_processor_stw = %p\n", _ref_processor_stw
  printf "  _ref_processor_stw->_num_q = %d\n", _ref_processor_stw->_num_q
  printf "  _ref_processor_stw->_mt_processing = %d\n", _ref_processor_stw->_mt_processing
  continue
end

run
```

**预期输出**：
```
=== D.5 DirtyCardQueueSet 验证 ===
  G1BarrierSet::_dirty_card_queue_set 地址: 0x7f...
  G1BarrierSet::_satb_mark_queue_set 地址: 0x7f...

=== D.6 引用处理器验证 ===
  _ref_processor_cm = 0x7f...
  _ref_processor_stw = 0x0 (即将创建)
  ParallelGCThreads = 13
  ParallelRefProcEnabled = 1

=== 引用处理器创建完成 ===
  _ref_processor_stw = 0x7f...
  _ref_processor_stw->_num_q = 13
  _ref_processor_stw->_mt_processing = 1
```

---

## 🏭 生产环境综合建议

### 监控命令

```bash
# 全面 GC 日志
-Xlog:gc*=info,gc+ref*=debug,gc+refine*=debug

# 引用处理统计
jstat -gcutil <pid> 1000
# 关注 FGC/FGCT（Full GC 与引用处理相关）
```

### 常见调优参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `ParallelRefProcEnabled` | true | 并行引用处理 |
| `SoftRefLRUPolicyMSPerMB` | 1000 | 软引用保留时间 |
| `G1ConcRefinementThreads` | ParallelGCThreads | 并发精炼线程 |

### 问题排查清单

| 问题 | 检查项 | 解决方案 |
|------|--------|----------|
| Ref Proc 慢 | 引用对象数量 | 减少弱引用使用 |
| Update RS 慢 | 脏卡队列长度 | 增加精炼线程 |
| SATB 溢出 | 并发标记期间写入量 | 增大 SATB 缓冲区 |

---

## 待分析节点更新

| 节点 | 主题 | 状态 |
|------|------|------|
| **D.5.1** | DirtyCardQueueSet vs SATBMarkQueueSet | ✅ |
| **D.5.2** | false 参数的含义 | ✅ |
| **D.6.1** | 为什么有两套引用处理器 | ✅ |
| **D.6.2** | _is_alive_closure 闭包 | ✅ |
| **D.6.3** | _is_subject_to_discovery | ✅ |
