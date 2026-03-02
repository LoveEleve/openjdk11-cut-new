# DirtyCardQueue 专家级源码分析

## 一、一句话总结

**DirtyCardQueue 是 G1 写屏障的"快递收件箱"，它通过线程本地缓冲区收集被修改的卡片（跨 Region 引用），批量提交给并发精炼线程处理，实现 RSet 的异步更新，避免写屏障成为性能瓶颈。**

---

## 二、设计哲学：为什么需要 DirtyCardQueue？

### 2.1 问题背景

G1 需要维护 Remembered Set (RSet) 来跟踪跨 Region 引用。如果没有缓冲机制：

```
场景：应用线程每次修改引用都立即更新 RSet
问题：
  1. 写屏障开销大（需要查找目标 Region 的 RSet）
  2. 并发竞争严重（多个线程竞争更新同一 RSet）
  3. 缓存局部性差（随机访问不同 Region 的 RSet）

结果：应用吞吐量下降 30%+
```

### 2.2 解决方案

**Deferred Update (延迟更新) 策略**：

```
应用线程                    DirtyCardQueue                 并发精炼线程
    │                            │                               │
    │  1. 修改引用                │                               │
    │  2. 写屏障发现跨Region引用   │                               │
    │────────────────────────────>│                               │
    │  3. 卡片地址入本地队列        │                               │
    │  (无锁，O(1))              │                               │
    │                            │  4. 缓冲区满                   │
    │                            │────┬───────────────────────────│
    │                            │    │ 5. 批量处理卡片            │
    │                            │    │   (更新RSet)              │
    │                            │<───┘                           │
```

**核心优势**：
1. **写屏障轻量**：只记录卡片地址，不立即更新 RSet
2. **无锁设计**：线程本地缓冲区，无并发竞争
3. **批量处理**：提高缓存局部性，减少锁竞争

---

## 三、整体架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                     DirtyCardQueueSet (全局)                        │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                  已完成缓冲区链表                              │  │
│  │  _completed_buffers_head ──> [BufferNode] ──> [BufferNode]   │  │
│  │  _completed_buffers_tail                                     │  │
│  │  _n_completed_buffers (计数)                                  │  │
│  └──────────────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                  空闲缓冲区链表                                │  │
│  │  _buf_free_list ──> [BufferNode] ──> [BufferNode]            │  │
│  └──────────────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                  共享脏卡队列                                 │  │
│  │  _shared_dirty_card_queue (GC/VM线程使用)                     │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
                              ▲
                              │ 每个线程一个
┌─────────────────────────────────────────────────────────────────────┐
│                     DirtyCardQueue (线程本地)                       │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  _buf ──> [卡片地址1, 卡片地址2, ..., 卡片地址N]               │  │
│  │  _index (下一个写入位置)                                       │  │
│  │  _capacity_in_bytes (缓冲区容量)                              │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                     │
│  操作：                                                             │
│  • enqueue(card_ptr) ──> 写入 _buf[_index--]                       │
│  • 缓冲区满 ──> 提交到全局已完成链表                                │
│  • 获取新缓冲区 ──> 从空闲链表分配                                  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 四、核心数据结构详解

### 4.1 PtrQueue (基类)

```cpp
class PtrQueue {
protected:
  PtrQueueSet* const _qset;        // 指向全局 QueueSet
  bool _active;                     // 是否激活
  const bool _permanent;            // 是否永久（不解构）
  size_t _index;                    // 下一个写入位置（字节偏移）
  size_t _capacity_in_bytes;        // 缓冲区容量（字节）
  void** _buf;                      // 缓冲区指针
  Mutex* _lock;                     // 关联锁

public:
  void enqueue(void* ptr) {         // 入队
    if (!_active) return;
    enqueue_known_active(ptr);
  }
  
  void enqueue_known_active(void* ptr) {
    if (_index == 0) {              // 缓冲区满
      handle_zero_index();          // 处理满缓冲区
    }
    _index -= sizeof(void*);        // 倒序写入
    _buf[byte_index_to_index(_index)] = ptr;
  }
  
  size_t size() const {             // 当前元素数量
    return (_buf == NULL) ? 0 : 
           (capacity_in_bytes() - _index) / sizeof(void*);
  }
  
  bool is_empty() const {
    return _buf == NULL || _index == capacity_in_bytes();
  }
};
```

**内存布局：**
```
PtrQueue (40 bytes)
偏移      字段名                 大小      说明
────────────────────────────────────────────────────
0x000    _qset                  8        QueueSet 指针
0x008    _active                1        是否激活
0x009    _permanent             1        是否永久
0x00A    [padding]              6        对齐填充
0x010    _index                 8        写入位置（字节）
0x018    _capacity_in_bytes     8        容量（字节）
0x020    _buf                   8        缓冲区指针
0x028    _lock                  8        锁指针
────────────────────────────────────────────────────
总大小：0x30 = 48 bytes（含对齐）
```

**【倒序写入设计】**

```
缓冲区布局（_capacity = 256）：
索引（字节）   0    8    16        256-16  256-8  256
             ▼    ▼    ▼           ▼      ▼     ▼
            [E4] [E3] [E2]  ...   [E1]   [空]  [空]
                                  ▲
                                _index = 256-16 = 240

写入 E5：
_index -= 8 → 232
_buf[232/8] = E5

优势：
1. 满缓冲区时 _index = 0，判断简单（if _index == 0）
2. 缓冲区大小变化时不需要修改索引计算
```

### 4.2 DirtyCardQueue (派生类)

```cpp
class DirtyCardQueue: public PtrQueue {
public:
  DirtyCardQueue(DirtyCardQueueSet* qset, bool permanent = false);
  ~DirtyCardQueue() { flush(); }   // 析构时刷新
  
  void flush() { flush_impl(); }    // 将剩余内容提交到全局队列
};
```

**内存布局：**
```
DirtyCardQueue (继承 PtrQueue，48 bytes)
没有新增字段，只是特化行为
```

### 4.3 BufferNode (缓冲区节点)

```cpp
class BufferNode {
  size_t _index;                    // 已处理位置
  BufferNode* _next;                // 链表指针
  void* _buffer[1];                 // 柔性数组（实际大小动态）

public:
  static BufferNode* allocate(size_t size);     // 分配节点
  static void deallocate(BufferNode* node);     // 释放节点
  
  static void** make_buffer_from_node(BufferNode* node) {
    return &node->_buffer[0];
  }
  
  static BufferNode* make_node_from_buffer(void** buffer, size_t index) {
    return (BufferNode*)((char*)buffer - offset_of(BufferNode, _buffer));
  }
};
```

**内存布局：**
```
BufferNode (header + 缓冲区)
偏移      字段名                 大小      说明
────────────────────────────────────────────────────
0x000    _index                 8        处理位置
0x008    _next                  8        链表指针
0x010    _buffer[0]             8×N      实际缓冲区（N=buffer_size）
────────────────────────────────────────────────────

默认 buffer_size = 256（由 G1UpdateBufferSize 控制）
总大小 = 16 + 256×8 = 2056 bytes
```

### 4.4 DirtyCardQueueSet (全局管理器)

```cpp
class DirtyCardQueueSet: public PtrQueueSet {
  DirtyCardQueue _shared_dirty_card_queue;      // 共享队列
  FreeIdSet* _free_ids;                         // 并行ID管理
  
  // 统计计数
  jint _processed_buffers_mut;                  // Mutator 处理数
  jint _processed_buffers_rs_thread;            // RS 线程处理数
  
  // 并行迭代状态
  BufferNode* volatile _cur_par_buffer_node;

public:
  void initialize(...);
  
  // 并发精炼
  bool refine_completed_buffer_concurrently(uint worker_i, size_t stop_at);
  
  // GC 期间处理
  bool apply_closure_during_gc(CardTableEntryClosure* cl, uint worker_i);
  
  // 获取已完成缓冲区
  BufferNode* get_completed_buffer(size_t stop_at);
  
  // 合并所有线程的日志
  void concatenate_logs();
};
```

---

## 五、核心方法详解

### 5.1 enqueue() - 写入卡片地址

```cpp
void PtrQueue::enqueue_known_active(void* ptr) {
  // 步骤1：检查缓冲区是否已满
  if (_index == 0) {
    handle_zero_index();  // 缓冲区满，处理并获取新缓冲区
  }
  
  // 步骤2：倒序写入
  _index -= sizeof(void*);
  size_t byte_index = _index;
  size_t ind = byte_index / sizeof(void*);
  _buf[ind] = ptr;
}
```

**流程图：**
```
enqueue(card_ptr)
    │
    ▼
_is_active? ──NO──> 返回（不记录）
    │YES
    ▼
_index == 0? ──NO──> 直接写入
    │YES              _index -= 8
    ▼                 _buf[_index/8] = card_ptr
handle_zero_index()
    │
    ├──> flush_impl() ──> 提交当前缓冲区到全局链表
    │
    └──> 从空闲链表获取新缓冲区
         _buf = new_buffer
         _index = capacity
```

### 5.2 handle_zero_index() - 缓冲区满处理

```cpp
void PtrQueue::handle_zero_index() {
  if (should_enqueue_buffer()) {
    // 将当前缓冲区加入全局已完成链表
    BufferNode* node = BufferNode::make_node_from_buffer(_buf, 0);
    _qset->enqueue_complete_buffer(node);
  }
  
  // 分配新缓冲区
  _buf = _qset->allocate_buffer();
  _index = capacity_in_bytes();
}
```

### 5.3 refine_completed_buffer_concurrently() - 并发精炼

```cpp
bool DirtyCardQueueSet::refine_completed_buffer_concurrently(
    uint worker_i, size_t stop_at) {
  
  G1RefineCardConcurrentlyClosure cl;
  return apply_closure_to_completed_buffer(&cl, worker_i, stop_at, false);
}

bool DirtyCardQueueSet::apply_closure_to_completed_buffer(
    CardTableEntryClosure* cl,
    uint worker_i,
    size_t stop_at,
    bool during_pause) {
  
  // 步骤1：获取一个已完成缓冲区
  BufferNode* node = get_completed_buffer(stop_at);
  if (node == NULL) return false;
  
  // 步骤2：应用闭包处理每个卡片
  if (apply_closure_to_buffer(cl, node, true, worker_i)) {
    // 完全处理，释放缓冲区
    deallocate_buffer(node);
    Atomic::inc(&_processed_buffers_rs_thread);
  } else {
    // 部分处理（并发场景下 yield），重新入队
    enqueue_complete_buffer(node);
  }
  return true;
}
```

### 5.4 apply_closure_to_buffer() - 处理缓冲区

```cpp
bool DirtyCardQueueSet::apply_closure_to_buffer(
    CardTableEntryClosure* cl,
    BufferNode* node,
    bool consume,
    uint worker_i) {
  
  void** buf = BufferNode::make_buffer_from_node(node);
  size_t i = node->index();
  size_t limit = buffer_size();
  
  for (; i < limit; ++i) {
    jbyte* card_ptr = (jbyte*)buf[i];
    
    // 处理单个卡片
    if (!cl->do_card_ptr(card_ptr, worker_i)) {
      // 闭包返回 false，停止处理（如需要 yield）
      if (consume) node->set_index(i);
      return false;
    }
  }
  return true;  // 全部处理完成
}
```

### 5.5 concatenate_logs() - GC 期间合并

```cpp
void DirtyCardQueueSet::concatenate_logs() {
  // 在 SafePoint 下执行
  assert(SafepointSynchronize::is_at_safepoint(), "Must be at safepoint.");
  
  // 遍历所有 Java 线程
  for (JavaThreadIteratorWithHandle jtiwh; JavaThread *t = jtiwh.next(); ) {
    DirtyCardQueue& dcq = G1ThreadLocalData::dirty_card_queue(t);
    if (!dcq.is_empty()) {
      dcq.flush();  // 将线程本地队列刷新到全局链表
    }
  }
  
  // 刷新共享队列
  concatenate_log(_shared_dirty_card_queue);
}
```

---

## 六、并发处理模型

### 6.1 三色区域与线程协作

```
┌─────────────────────────────────────────────────────────────┐
│                     脏卡缓冲区数量                            │
│  0        Green Zone        Yellow Zone        Red Zone      │
│  ├─────────────────────┼─────────────────────┼───────────────┤
│  │                     │                     │               │
│  ▼                     ▼                     ▼               │
│ 空闲              并发精炼线程            Mutator Refinement  │
│                 逐渐激活处理               应用线程参与处理    │
│                                                            │
│  阈值：                                                   │
│  • Green: 0  (G1ConcRefinementGreenZone)                  │
│  • Yellow: 默认 CPU × 2  (G1ConcRefinementYellowZone)      │
│  • Red: 默认 CPU × 3  (G1ConcRefinementRedZone)            │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 线程角色

| 线程类型 | 职责 | 触发条件 |
|---------|------|---------|
| Mutator (应用) | 写入脏卡到本地队列 | 每次跨 Region 引用修改 |
| Mutator (应急) | 处理已完成缓冲区 | Red Zone 时 |
| Concurrent Refine | 批量处理脏卡 | Yellow/Red Zone |
| GC Worker | 处理剩余脏卡 | GC 暂停期间 |

---

## 七、GDB 验证

### 7.1 GDB 脚本

```gdb
# jvm-md/tmp-file/dirtycardqueue/gdb_dirtycardqueue.txt

set pagination off
set print pretty on

# 在 DirtyCardQueueSet::apply_closure_to_buffer 设置断点
break DirtyCardQueueSet::apply_closure_to_buffer

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

printf "\n========== DirtyCardQueueSet 基本信息 ==========\n"
set $dcqs = G1CollectedHeap::heap()->_dirty_card_queue_set
printf "buffer_size: %zu\n", $dcqs->buffer_size()
printf "completed_buffers_num: %zu\n", $dcqs->completed_buffers_num()
printf "process_completed_threshold: %d\n", $dcqs->process_completed_threshold()

printf "\n========== 当前线程 DirtyCardQueue ==========\n"
set $thread = Threads::first()
set $dcq = $thread->_gc_state._dirty_card_queue
printf "_index: %zu\n", $dcq._index
printf "_capacity: %zu\n", $dcq._capacity_in_bytes
printf "size: %zu\n", ($dcq._capacity_in_bytes - $dcq._index) / 8

continue
```

### 7.2 预期输出示例

```
========== DirtyCardQueueSet 基本信息 ==========
buffer_size: 256
completed_buffers_num: 12
process_completed_threshold: 4

========== 当前线程 DirtyCardQueue ==========
_index: 2048
_capacity: 2048
size: 0
```

---

## 八、关键设计决策

### 8.1 为什么使用倒序写入？

| 方案 | 优点 | 缺点 |
|------|------|------|
| 倒序写入 (_index--) | 满时 _index=0，判断简单 | 索引计算稍复杂 |
| 正序写入 (_index++) | 直观 | 需要保存容量或计算余量 |

**选择**：倒序写入，因为判断缓冲区是否满非常简单（_index == 0）。

### 8.2 为什么需要三级处理？

| 级别 | 目的 | 优势 |
|------|------|------|
| 本地队列 | 写屏障快速路径 | 无锁、O(1) |
| 已完成链表 | 批量处理 | 提高缓存局部性 |
| 并发精炼 | 异步处理 | 不阻塞应用线程 |

### 8.3 为什么缓冲区大小是 256？

```cpp
// G1UpdateBufferSize = 256
```

**权衡**：
- 太小：频繁提交，增加同步开销
- 太大：延迟增加，内存占用大
- 256：在 4MB Region、512B 卡片粒度下，可以覆盖约 128KB 的修改范围

---

## 九、面试问答

### Q1: DirtyCardQueue 的作用是什么？

**答案要点**：
1. 收集写屏障发现的跨 Region 引用（脏卡）
2. 线程本地缓冲区，无锁设计
3. 批量提交给并发精炼线程处理
4. 实现 RSet 的异步更新，降低写屏障开销

### Q2: 为什么需要三级处理（本地队列→已完成链表→并发精炼）？

**答案要点**：
1. 本地队列：保证写屏障快速，O(1) 无锁
2. 已完成链表：缓冲区满了批量提交，减少同步频率
3. 并发精炼：异步处理，不阻塞应用线程
4. 分层设计平衡了延迟和吞吐量

### Q3: 倒序写入的优势是什么？

**答案要点**：
1. 满缓冲区时 _index = 0，判断简单（if _index == 0）
2. 不需要额外变量记录容量
3. 缓冲区大小变化时逻辑不变
4. 符合"向零靠近"的直觉（剩余空间越来越少）

### Q4: Mutator Refinement 是什么场景？

**答案要点**：
1. 当脏卡缓冲区数量超过 Red Zone 阈值时触发
2. 应用线程参与处理脏卡，减轻并发精炼线程压力
3. 是一种"自我保护"机制，防止缓冲区无限增长
4. 会略微影响应用吞吐量，但保证系统稳定

---

## 十、总结

**DirtyCardQueue 是 G1 写屏障的"缓冲带"，通过延迟更新策略实现了高吞吐量和低延迟的平衡。**

| 核心机制 | 说明 |
|---------|------|
| 线程本地队列 | 每个线程独立缓冲区，无锁竞争 |
| 倒序写入 | 简单高效的满缓冲区判断 |
| 批量提交 | 提高缓存局部性，减少同步 |
| 三级处理 | Mutator → 已完成链表 → 并发精炼 |

**一句话记忆**：DirtyCardQueue 就像是 RSet 更新的"异步消息队列"，应用线程只负责"发消息"，后台线程负责"处理消息"，两者解耦，性能最优。

---

*文档生成时间: 2026-02-11*  
*源码版本: OpenJDK 11*  
*分析文件: dirtyCardQueue.hpp/cpp, ptrQueue.hpp*
