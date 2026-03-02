# G1CMMarkStack 专家级源码分析

> **文档定位**：Mixed GC 学习 - 第二阶段第 1 篇  
> **分析模式**：Read-BottomUp（自底向上）  
> **创建时间**：2026-02-11  

---

## 一、一句话总结

**G1CMMarkStack 是 G1 并发标记的"全局仓库"，它通过 Chunked（块化）设计管理灰色对象，使用高水位线（HWM）和空闲链表实现高效的内存分配与回收，支持多线程并行的批量压栈/弹栈操作，是本地队列溢出时的重要备份。**

---

## 二、设计哲学：为什么需要全局标记栈？

### 2.1 问题背景

**本地队列的局限**：
```
场景：单个 CM Task 的本地队列满了（通常 1024-4096 个条目）
问题：
  1. 新发现的灰色对象无处存放
  2. 如果直接丢弃，会导致标记不完整
  3. 需要一种"溢出"机制

解决方案：全局标记栈作为备份存储
```

### 2.2 设计目标

| 目标 | 说明 |
|------|------|
| **大容量** | 支持存储数百万个灰色对象 |
| **高并发** | 多线程并行压栈/弹栈 |
| **低碎片** | 块化分配，减少内存碎片 |
| **可扩展** | 支持动态扩容 |

### 2.3 架构对比

```
本地队列 vs 全局标记栈

本地队列 (G1CMTaskQueue)：
  - 每个线程私有
  - 无锁 LIFO 操作
  - 容量有限（~1024 条目）
  - 快速访问

全局标记栈 (G1CMMarkStack)：
  - 多线程共享
  - CAS 批量操作
  - 大容量（数百万条目）
  - 溢出备份
```

---

## 三、核心数据结构

### 3.1 整体架构

```
┌─────────────────────────────────────────────────────────────────┐
│                       G1CMMarkStack                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    预留内存区域                            │  │
│  │  _base ───────────────────────────────────────────────►   │  │
│  │                                                          │  │
│  │  ┌────────┐  ┌────────┐  ┌────────┐      ┌────────┐     │  │
│  │  │ Chunk 0│  │ Chunk 1│  │ Chunk 2│  ... │ Chunk N│     │  │
│  │  │ (使用中)│  │ (空闲) │  │ (使用中)│      │ (空闲) │     │  │
│  │  └───┬────┘  └────┬───┘  └───┬────┘      └───┬────┘     │  │
│  │      │            │          │               │          │  │
│  │      └────────────┴──────────┘               │          │  │
│  │                   │                          │          │  │
│  │                   ▼                          ▼          │  │
│  │           _chunk_list ──►            _free_list ──►     │  │
│  │           (使用中的块)                  (空闲块链表)      │  │
│  │                                                          │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  高水位线 (HWM)：_hwm ──► 已分配的块数量                         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 核心字段

```cpp
class G1CMMarkStack {
public:
  // 每个 Chunk 包含的条目数（1023 个数据 + 1 个 next 指针）
  static const size_t EntriesPerChunk = 1024 - 1;

private:
  // ===== Chunk 结构 =====
  struct TaskQueueEntryChunk {
    TaskQueueEntryChunk* next;           // 链表指针（8 bytes）
    G1TaskQueueEntry data[EntriesPerChunk]; // 数据数组（1023 × 8 = 8184 bytes）
  };  // 总计：8192 bytes = 8KB

  // ===== 容量管理 =====
  size_t _max_chunk_capacity;    // 最大 Chunk 容量
  size_t _chunk_capacity;        // 当前 Chunk 容量

  // ===== 内存基址 =====
  TaskQueueEntryChunk* _base;    // 预留内存起始地址

  // ===== 链表头（缓存行对齐）=====
  TaskQueueEntryChunk* volatile _free_list;   // 空闲块链表
  TaskQueueEntryChunk* volatile _chunk_list;  // 使用中的块链表
  volatile size_t _chunks_in_chunk_list;      // 使用中的块数量

  // ===== 高水位线 =====
  volatile size_t _hwm;          // 高水位线（已分配的块数）
};
```

### 3.3 Chunk 结构详解

```
TaskQueueEntryChunk (8KB)
┌─────────────────────────────────────────────────────────────┐
│  next (8 bytes) │  data[0] │ data[1] │ ... │ data[1022]    │
│  链表指针        │  条目0   │  条目1  │     │  条目1022     │
├─────────────────┼─────────┼─────────┼─────┼───────────────┤
│  0x0000-0x0007  │0x0008   │0x0010   │ ... │ 0x1FF8        │
└─────────────────────────────────────────────────────────────┘

内存布局：
- next：指向下一个 Chunk（用于链表）
- data[]：存储 G1TaskQueueEntry（对象指针或数组切片）
- 总大小：8 + 1023×8 = 8192 bytes = 8KB
- 对齐：8KB 对齐，便于内存管理
```

---

## 四、核心方法详解

### 4.1 初始化：initialize()

```cpp
bool G1CMMarkStack::initialize(size_t initial_capacity, size_t max_capacity) {
  // 1. 计算 Chunk 数量
  // 默认初始容量：1M 条目 = ~1024 个 Chunk
  // 默认最大容量：16M 条目 = ~16384 个 Chunk
  size_t initial_chunk_capacity = align_up(initial_capacity, EntriesPerChunk) / EntriesPerChunk;
  size_t max_chunk_capacity = align_up(max_capacity, EntriesPerChunk) / EntriesPerChunk;

  _max_chunk_capacity = max_chunk_capacity;
  _chunk_capacity = initial_chunk_capacity;

  // 2. 预留虚拟内存（最大容量）
  // 使用 mmap 预留，但不立即提交物理内存
  size_t max_byte_size = max_chunk_capacity * sizeof(TaskQueueEntryChunk);
  _base = (TaskQueueEntryChunk*)os::reserve_memory(max_byte_size, NULL, false);

  if (_base == NULL) return false;

  // 3. 提交初始容量的物理内存
  size_t initial_byte_size = initial_chunk_capacity * sizeof(TaskQueueEntryChunk);
  if (!os::commit_memory((char*)_base, initial_byte_size, false)) {
    os::release_memory((char*)_base, max_byte_size);
    return false;
  }

  // 4. 初始化高水位线
  _hwm = 0;

  // 5. 初始化链表
  _free_list = NULL;
  _chunk_list = NULL;
  _chunks_in_chunk_list = 0;

  return true;
}
```

### 4.2 分配新 Chunk：allocate_new_chunk()

```cpp
TaskQueueEntryChunk* G1CMMarkStack::allocate_new_chunk() {
  // 1. 首先尝试从空闲链表获取
  TaskQueueEntryChunk* chunk = remove_chunk_from_free_list();
  if (chunk != NULL) {
    return chunk;
  }

  // 2. 检查是否超过高水位线
  size_t prev_hwm = _hwm;
  if (prev_hwm >= _chunk_capacity) {
    // 3. 超过当前容量，尝试扩容
    if (_chunk_capacity < _max_chunk_capacity) {
      expand();  // 扩展容量
    } else {
      return NULL;  // 已达最大容量，溢出
    }
  }

  // 4. 使用高水位线分配新 Chunk
  // CAS 操作确保线程安全
  size_t new_hwm = Atomic::add((size_t)1, &_hwm);
  if (new_hwm > _chunk_capacity) {
    // 分配失败，回退
    Atomic::dec(&_hwm);
    return NULL;
  }

  // 5. 计算 Chunk 地址
  TaskQueueEntryChunk* new_chunk = &_base[new_hwm - 1];

  // 6. 初始化 Chunk
  new_chunk->next = NULL;
  // data[] 不需要初始化（会被覆盖）

  return new_chunk;
}
```

### 4.3 批量压栈：par_push_chunk()

```cpp
bool G1CMMarkStack::par_push_chunk(G1TaskQueueEntry* buffer) {
  // 1. 分配新 Chunk
  TaskQueueEntryChunk* chunk = allocate_new_chunk();
  if (chunk == NULL) {
    // 分配失败，标记栈溢出
    return false;
  }

  // 2. 复制数据到 Chunk
  // buffer 最多 EntriesPerChunk 个条目，以 NULL 结束
  size_t i = 0;
  while (i < EntriesPerChunk && !buffer[i].is_null()) {
    chunk->data[i] = buffer[i];
    i++;
  }

  // 3. 如果未填满，最后一个条目设为 NULL（终止符）
  if (i < EntriesPerChunk) {
    chunk->data[i] = G1TaskQueueEntry();  // NULL
  }

  // 4. 原子添加到使用链表
  add_chunk_to_chunk_list(chunk);

  // 5. 更新计数
  Atomic::add((size_t)1, &_chunks_in_chunk_list);

  return true;
}
```

### 4.4 批量弹栈：par_pop_chunk()

```cpp
bool G1CMMarkStack::par_pop_chunk(G1TaskQueueEntry* buffer) {
  // 1. 从使用链表中移除一个 Chunk
  TaskQueueEntryChunk* chunk = remove_chunk_from_chunk_list();
  if (chunk == NULL) {
    return false;  // 栈为空
  }

  // 2. 更新计数
  Atomic::sub((size_t)1, &_chunks_in_chunk_list);

  // 3. 复制数据到 buffer
  size_t i = 0;
  while (i < EntriesPerChunk && !chunk->data[i].is_null()) {
    buffer[i] = chunk->data[i];
    i++;
  }

  // 4. buffer 以 NULL 结束
  if (i < EntriesPerChunk) {
    buffer[i] = G1TaskQueueEntry();  // NULL
  }

  // 5. 将 Chunk 归还到空闲链表
  add_chunk_to_free_list(chunk);

  return true;
}
```

### 4.5 链表操作（原子）

```cpp
// 原子添加到链表头部
void G1CMMarkStack::add_chunk_to_list(
    TaskQueueEntryChunk* volatile* list,
    TaskQueueEntryChunk* elem) {
  TaskQueueEntryChunk* old_head;
  do {
    old_head = *list;
    elem->next = old_head;
  } while (!Atomic::cmpxchg(elem, list, old_head) == old_head);
}

// 原子从链表头部移除
TaskQueueEntryChunk* G1CMMarkStack::remove_chunk_from_list(
    TaskQueueEntryChunk* volatile* list) {
  TaskQueueEntryChunk* old_head;
  TaskQueueEntryChunk* new_head;
  do {
    old_head = *list;
    if (old_head == NULL) {
      return NULL;  // 链表为空
    }
    new_head = old_head->next;
  } while (!Atomic::cmpxchg(new_head, list, old_head) == old_head);

  return old_head;
}
```

### 4.6 扩容：expand()

```cpp
void G1CMMarkStack::expand() {
  // 1. 只能在 STW 期间扩容
  assert(SafepointSynchronize::is_at_safepoint(), "must be at safepoint");
  assert(_chunk_list == NULL, "chunk list must be empty");
  assert(_free_list == NULL, "free list must be empty");

  // 2. 计算新容量（翻倍）
  size_t new_capacity = MIN2(_chunk_capacity * 2, _max_chunk_capacity);
  if (new_capacity == _chunk_capacity) {
    return;  // 已达最大容量
  }

  // 3. 提交更多物理内存
  size_t old_byte_size = _chunk_capacity * sizeof(TaskQueueEntryChunk);
  size_t new_byte_size = new_capacity * sizeof(TaskQueueEntryChunk);
  size_t delta_bytes = new_byte_size - old_byte_size;

  char* commit_start = (char*)_base + old_byte_size;
  if (!os::commit_memory(commit_start, delta_bytes, false)) {
    return;  // 扩容失败
  }

  // 4. 更新容量
  _chunk_capacity = new_capacity;
}
```

---

## 五、内存管理详解

### 5.1 内存分配策略

```
两级分配：

1. 高水位线（HWM）分配：
   - 从未使用的预留内存分配
   - 适用于"首次使用"的场景
   - 简单高效，无需链表操作

2. 空闲链表分配：
   - 从空闲链表复用 Chunk
   - 适用于"回收后再分配"的场景
   - 需要 CAS 链表操作

分配优先级：
   空闲链表 > HWM 分配 > 扩容 > 失败
```

### 5.2 内存占用计算

```
默认配置：
- 初始容量：1M 条目
- 最大容量：16M 条目

内存计算：
- Chunk 大小：8KB
- 初始 Chunk 数：1M / 1023 ≈ 1024 个
- 最大 Chunk 数：16M / 1023 ≈ 16384 个

内存占用：
- 虚拟内存：16384 × 8KB = 128MB
- 初始物理内存：1024 × 8KB = 8MB
- 实际使用：动态增长，按需提交
```

### 5.3 缓存行对齐

```cpp
// 关键字段使用缓存行对齐，避免伪共享
char _pad0[DEFAULT_CACHE_LINE_SIZE];
TaskQueueEntryChunk* volatile _free_list;
char _pad1[DEFAULT_CACHE_LINE_SIZE - sizeof(TaskQueueEntryChunk*)];
TaskQueueEntryChunk* volatile _chunk_list;
volatile size_t _chunks_in_chunk_list;
char _pad2[DEFAULT_CACHE_LINE_SIZE - sizeof(TaskQueueEntryChunk*) - sizeof(size_t)];
volatile size_t _hwm;
char _pad4[DEFAULT_CACHE_LINE_SIZE - sizeof(size_t)];
```

**好处**：
- _free_list 和 _chunk_list 位于不同缓存行
- 多线程操作不同链表时不会相互干扰
- 提高并发性能

---

## 六、使用场景

### 6.1 本地队列溢出

```cpp
void G1CMTask::move_entries_to_global_stack() {
  // 本地队列满了，批量转移到全局栈
  G1TaskQueueEntry buffer[G1CMMarkStack::EntriesPerChunk];
  size_t n = 0;

  // 从本地队列取出条目
  while (n < G1CMMarkStack::EntriesPerChunk && !_task_queue->is_empty()) {
    G1TaskQueueEntry entry;
    if (_task_queue->pop_local(entry)) {
      buffer[n++] = entry;
    }
  }

  // 批量压入全局栈
  if (n > 0) {
    if (!_cm->mark_stack_push(buffer)) {
      // 全局栈溢出
      set_has_aborted();
      _cm->set_has_overflown();
    }
  }
}
```

### 6.2 本地队列空了

```cpp
bool G1CMTask::get_entries_from_global_stack() {
  G1TaskQueueEntry buffer[G1CMMarkStack::EntriesPerChunk];

  // 从全局栈批量弹出
  if (_cm->mark_stack_pop(buffer)) {
    // 压入本地队列
    size_t i = 0;
    while (!buffer[i].is_null()) {
      _task_queue->push(buffer[i]);
      i++;
    }
    return true;
  }
  return false;
}
```

---

## 七、GDB 验证

### 7.1 GDB 脚本

```gdb
# jvm-md/tmp-file/g1cmmarkstack/gdb_g1cmms.txt

set pagination off
set print pretty on

break G1ConcurrentMark::G1ConcurrentMark

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -version

printf "\n========== G1CMMarkStack 验证 ==========\n"
set $g1h = G1CollectedHeap::heap()
set $cm = $g1h->_cm
set $ms = &$cm->_global_mark_stack

printf "sizeof(G1CMMarkStack): %zu bytes\n", sizeof(G1CMMarkStack)
printf "EntriesPerChunk: %zu\n", G1CMMarkStack::EntriesPerChunk

printf "\n---------- 容量信息 ----------\n"
printf "_max_chunk_capacity: %zu\n", $ms->_max_chunk_capacity
printf "_chunk_capacity: %zu\n", $ms->_chunk_capacity
printf "_hwm: %zu\n", $ms->_hwm

printf "\n---------- 链表状态 ----------\n"
printf "_chunk_list: %p\n", $ms->_chunk_list
printf "_free_list: %p\n", $ms->_free_list
printf "_chunks_in_chunk_list: %zu\n", $ms->_chunks_in_chunk_list

printf "\n---------- 内存信息 ----------\n"
printf "_base: %p\n", $ms->_base
printf "Chunk size: %zu bytes (%.2f KB)\n", sizeof(G1CMMarkStack::TaskQueueEntryChunk), sizeof(G1CMMarkStack::TaskQueueEntryChunk)/1024.0

continue
quit
```

### 7.2 预期输出

```
========== G1CMMarkStack 验证 ==========
sizeof(G1CMMarkStack): [待验证] bytes
EntriesPerChunk: 1023

---------- 容量信息 ----------
_max_chunk_capacity: [待验证]
_chunk_capacity: [待验证]
_hwm: 0

---------- 链表状态 ----------
_chunk_list: NULL
_free_list: NULL
_chunks_in_chunk_list: 0

---------- 内存信息 ----------
_base: [待验证]
Chunk size: 8192 bytes (8.00 KB)
```

---

## 八、面试问答

### Q1: G1CMMarkStack 的作用是什么？

**答案要点**：
1. 全局标记栈，存储灰色对象
2. 本地队列溢出时的备份存储
3. 支持多线程并行的批量压栈/弹栈
4. Chunked 设计，高效内存管理

### Q2: 为什么使用 Chunked 设计？

**答案要点**：
1. 减少内存碎片（固定 8KB 块）
2. 批量操作减少 CAS 次数
3. 简化内存管理（链表操作）
4. 支持动态扩容

### Q3: 高水位线（HWM）和空闲链表的区别？

**答案要点**：
1. HWM：从未使用的预留内存分配，简单高效
2. 空闲链表：复用回收的 Chunk，需要链表操作
3. 分配优先级：空闲链表 > HWM
4. 两者互补，提高分配效率

### Q4: 如何处理栈溢出？

**答案要点**：
1. 达到最大容量时返回失败
2. 设置溢出标志，触发标记中止
3. 下一轮标记会扩容（STW 期间）
4. 或者重启标记（_restart_for_overflow）

---

## 九、下一步学习

**本阶段关联**：
- 上一篇：`G1CMTask-Expert-Analysis.md` - 使用 G1CMMarkStack

**下阶段预告**：
- **2.2 G1SATBMarkQueue** - SATB 队列机制（写屏障、并发处理）

---

## 十、总结

**G1CMMarkStack 是 G1 并发标记的"全局仓库"，通过 Chunked 设计、高水位线分配和空闲链表复用，实现了大容量、高并发的灰色对象存储，是本地队列的重要补充。**

| 核心机制 | 说明 |
|---------|------|
| Chunked 设计 | 8KB 固定块，减少碎片 |
| 高水位线 | 快速分配新 Chunk |
| 空闲链表 | 复用回收的 Chunk |
| 批量操作 | 减少 CAS 次数 |
| 动态扩容 | STW 期间扩展容量 |

**一句话记忆**：G1CMMarkStack 就像是标记工作的"中央仓库"，当工人的工具箱（本地队列）满了，可以把工具存放到仓库，需要时再从仓库取出。

---

*文档生成时间: 2026-02-11*  
*源码版本: OpenJDK 11*  
*分析文件: g1ConcurrentMark.hpp (G1CMMarkStack 类)*
