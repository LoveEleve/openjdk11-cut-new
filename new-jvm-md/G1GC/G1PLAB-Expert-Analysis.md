# G1PLAB 专家级源码分析

> **定位**：G1 Young GC 线程局部分配缓冲区，优化对象复制性能  
> **核心问题**：如何减少 GC 线程间的分配竞争？如何自适应调整 PLAB 大小？  
> **源码路径**：`src/hotspot/share/gc/g1/g1Allocator.hpp`, `src/hotspot/share/gc/shared/plab.hpp`

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1PLAB（Parallel Local Allocation Buffer）的本质是**GC 线程的私有分配缓冲区**：类似应用线程的 TLAB，每个 GC Worker 有自己的 PLAB，在 PLAB 内分配无锁（指针碰撞）；PLAB 满时申请新 PLAB（加锁），减少 GC 线程间的分配竞争。

### 0.2 为什么需要？

Evacuation 阶段多个 GC Worker 并发向 Survivor/Old Region 复制对象。如果每次复制都加全局锁，锁竞争严重（GC Worker 数量通常等于 CPU 核数）。PLAB 让每个 GC Worker 有私有的分配缓冲区，在缓冲区内分配无锁，只有缓冲区满时才加锁申请新缓冲区。

### 0.3 怎么解决？

**指针碰撞 + 自适应大小**：PLAB 内部维护 `_top` 和 `_end` 指针；分配时 `_top += size`（无锁）；`_top >= _end` 时申请新 PLAB；`G1PLABStats` 根据历史 PLAB 使用率自适应调整 PLAB 大小（`desired_plab_sz()`）。

### 0.4 为什么这样设计？

- **为什么 PLAB 大小需要自适应？** PLAB 太小：频繁申请新 PLAB，锁竞争多；PLAB 太大：PLAB 末尾浪费（每个 PLAB 末尾未用空间不能给其他线程用）；自适应根据历史使用率找到最优大小
- **为什么 PLAB 末尾浪费不可避免？** PLAB 是线程私有的，末尾未用空间不能给其他线程；GC 结束时 `retire()` 将末尾空间填充为 dummy 对象（保持堆的可解析性）

---

## 1. 一句话总结

**G1PLAB（Promotion Local Allocation Buffer）是线程私有的堆上分配缓冲区，通过"本地无锁分配 + 批量申请 Region 空间"的机制，大幅减少多线程 GC 时的分配竞争，并通过历史统计数据自适应调整缓冲区大小。**

---

## 2. 为什么需要 PLAB？

### 2.1 问题背景

在 G1 Young GC 的 Evacuation 阶段，需要将存活对象从 CSet 复制到 Survivor/Old Region：
- **高频分配**：每个 GC 线程需要频繁分配空间存储复制的对象
- **多线程竞争**：多个 GC 线程同时操作共享的 Region

**核心挑战**：
1. **分配热点**：所有线程竞争同一个 Region 的 `top` 指针
2. **CAS 开销**：每次分配都需要原子操作（`par_allocate`）
3. **缓存失效**：多线程修改共享变量导致缓存同步

### 2.2 如果没有 PLAB？

```
❌ 方案1：直接 Region 分配
   ├── 每次对象复制都调用 HeapRegion::par_allocate()
   ├── CAS 操作竞争激烈（8 个线程争用同一个 Region）
   └── 性能瓶颈：分配成为 GC 热点

❌ 方案2：每个线程独享 Region
   ├── 每个线程分配一个完整 Region（4MB）
   ├── 问题1：小对象浪费大量空间（平均每个 Region 只用几百 KB）
   └── 问题2：Region 数量受限，线程数多时不够用

✅ 方案3：PLAB（实际采用）
   ├── 每个线程分配 PLAB（默认 4KB-64KB）
   ├── PLAB 内 bump-the-pointer 无锁分配
   ├── PLAB 耗尽后批量申请新空间
   └── 平衡竞争和内存效率
```

---

## 3. 整体架构

### 3.1 类层次关系

```
PLAB 类层次
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

PLAB (gc/shared/plab.hpp)
├── _bottom/_top/_end：缓冲区边界
├── allocate()：本地分配
├── set_buf()：绑定新缓冲区
└── retire()：回收剩余空间

PLABStats (gc/shared/plab.hpp)
├── 分配统计（allocated/wasted/unused）
├── _filter：自适应滤波器
├── desired_plab_sz()：计算期望大小
└── adjust_desired_plab_sz()：调整大小

G1PLABAllocator (gc/g1/g1Allocator.hpp)
├── _surviving_alloc_buffer：Survivor PLAB
├── _tenured_alloc_buffer：Old PLAB
├── plab_allocate()：快速分配
├── allocate_direct_or_new_plab()：PLAB 耗尽处理
└── flush_and_retire_stats()：刷新统计
```

### 3.2 分配层级

```
分配请求层级
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Level 1: PLAB Fast Path（无锁，~5ns）
┌─────────────────────────────────────────────────────┐
│ plab_allocate()                                     │
│   └── _top += word_sz  // bump-the-pointer         │
└─────────────────────────────────────────────────────┘
                        ↓ PLAB 满
Level 2: PLAB Refill（批量申请，~100ns-1μs）
┌─────────────────────────────────────────────────────┐
│ allocate_direct_or_new_plab()                       │
│   ├── retire() 当前 PLAB                           │
│   ├── par_allocate_during_gc() 申请新 PLAB         │
│   └── set_buf() 绑定新缓冲区                        │
└─────────────────────────────────────────────────────┘
                        ↓ Region 满
Level 3: 直接分配（fallback）
┌─────────────────────────────────────────────────────┐
│ _allocator->par_allocate_during_gc()               │
│   └── 直接分配，不经过 PLAB                         │
└─────────────────────────────────────────────────────┘
```

---

## 4. 核心数据结构详解

### 4.1 PLAB 结构

```cpp
class PLAB : public CHeapObj<mtGC> {
private:
    size_t    _word_sz;       // PLAB 总大小（HeapWord 单位）
    HeapWord* _bottom;        // 缓冲区起始地址
    HeapWord* _top;           // 当前分配位置（bump pointer）
    HeapWord* _end;           // 可分配区域结束（_hard_end - AlignmentReserve）
    HeapWord* _hard_end;      // 缓冲区物理结束
    
    // 统计信息
    size_t    _allocated;     // 累计分配量
    size_t    _wasted;        // 浪费空间（内部碎片）
    size_t    _undo_wasted;   // Undo 分配导致的浪费
    
    static size_t AlignmentReserve;  // 对齐预留（防止越界）

public:
    // 核心分配方法
    HeapWord* allocate(size_t word_sz) {
        HeapWord* res = _top;
        if (pointer_delta(_end, _top) >= word_sz) {
            _top = _top + word_sz;  // bump-the-pointer
            return res;
        }
        return NULL;  // PLAB 满
    }
};
```

#### 关键字段解析

| 字段 | 类型 | 作用 | 为什么重要 |
|------|------|------|-----------|
| `_top` | HeapWord* | 当前分配位置 | bump-the-pointer 的核心，无锁递增 |
| `_end` | HeapWord* | 可分配边界 | 预留对齐空间，防止越界 |
| `_hard_end` | HeapWord* | 物理边界 | 包含 AlignmentReserve |
| `_word_sz` | size_t | PLAB 总大小 | 决定 PLAB 容量 |
| `_wasted` | size_t | 浪费统计 | 用于自适应调整 |

#### AlignmentReserve 设计

```cpp
// 预留空间防止对齐导致的越界
static size_t AlignmentReserve;

// 计算实际可分配空间
_end = _hard_end - AlignmentReserve;

// 申请时需要额外空间
static size_t size_required_for_allocation(size_t word_size) {
    return word_size + AlignmentReserve;
}
```

**为什么需要预留？**
- 对象可能需要对齐（如 SurvivorAlignmentInBytes）
- 防止 `allocate_aligned()` 时越界
- 通常是 `ObjectAlignmentInBytes / HeapWordSize`

### 4.2 G1PLABAllocator 结构

```cpp
class G1PLABAllocator : public CHeapObj<mtGC> {
private:
    G1CollectedHeap* _g1h;
    G1Allocator* _allocator;
    
    // 两个 PLAB：Survivor 和 Old
    PLAB  _surviving_alloc_buffer;   // Survivor 区分配
    PLAB  _tenured_alloc_buffer;     // Old 区分配
    PLAB* _alloc_buffers[InCSetState::Num];  // 索引数组
    
    // Survivor 对齐（特殊优化）
    const uint _survivor_alignment_bytes;
    
    // 直接分配统计（绕过 PLAB）
    size_t _direct_allocated[InCSetState::Num];

public:
    // 快速分配（PLAB 内）
    inline HeapWord* plab_allocate(InCSetState dest, size_t word_sz);
    
    // PLAB 耗尽后的处理
    HeapWord* allocate_direct_or_new_plab(InCSetState dest,
                                          size_t word_sz,
                                          bool* plab_refill_failed);
    
    // 通用分配接口
    inline HeapWord* allocate(InCSetState dest,
                              size_t word_sz,
                              bool* refill_failed);
};
```

#### PLAB 选择逻辑

```cpp
inline PLAB* G1PLABAllocator::alloc_buffer(InCSetState dest) {
    assert(dest.is_valid(), "Invalid state");
    return _alloc_buffers[dest.value()];
}

// 初始化时绑定
G1PLABAllocator::G1PLABAllocator(G1Allocator* allocator) :
    _surviving_alloc_buffer(_g1h->desired_plab_sz(InCSetState::Young)),
    _tenured_alloc_buffer(_g1h->desired_plab_sz(InCSetState::Old)),
    ...
{
    _alloc_buffers[InCSetState::Young] = &_surviving_alloc_buffer;
    _alloc_buffers[InCSetState::Old]  = &_tenured_alloc_buffer;
}
```

---

## 5. 分配流程详解

### 5.1 快速分配（Fast Path）

```cpp
inline HeapWord* G1PLABAllocator::plab_allocate(InCSetState dest,
                                                size_t word_sz) {
    PLAB* buffer = alloc_buffer(dest);
    
    // Survivor 可能需要对齐
    if (_survivor_alignment_bytes == 0 || !dest.is_young()) {
        return buffer->allocate(word_sz);
    } else {
        return buffer->allocate_aligned(word_sz, _survivor_alignment_bytes);
    }
}

// PLAB::allocate - bump-the-pointer
HeapWord* PLAB::allocate(size_t word_sz) {
    HeapWord* res = _top;
    if (pointer_delta(_end, _top) >= word_sz) {
        _top = _top + word_sz;
        return res;
    }
    return NULL;
}
```

**性能优势**：
- **无锁**：单线程操作，无需 CAS
- **O(1)**：简单的指针加法
- **缓存友好**：连续分配，空间局部性好

### 5.2 PLAB 耗尽处理（Slow Path）

```cpp
HeapWord* G1PLABAllocator::allocate_direct_or_new_plab(
        InCSetState dest,
        size_t word_sz,
        bool* plab_refill_failed) {
    
    // 1. 计算期望的 PLAB 大小
    size_t plab_word_size = _g1h->desired_plab_sz(dest);
    size_t required_in_plab = PLAB::size_required_for_allocation(word_sz);
    
    // 2. 检查是否需要丢弃当前 PLAB
    // 条件：新对象大小 < PLAB 大小的 ParallelGCBufferWastePct%（默认 10%）
    if ((required_in_plab <= plab_word_size) &&
        may_throw_away_buffer(required_in_plab, plab_word_size)) {
        
        PLAB* alloc_buf = alloc_buffer(dest);
        
        // 3. 回收当前 PLAB（填充剩余空间）
        alloc_buf->retire();
        
        // 4. 申请新的 PLAB 空间
        size_t actual_plab_size = 0;
        HeapWord* buf = _allocator->par_allocate_during_gc(
                            dest,
                            required_in_plab,   // 最小需求
                            plab_word_size,     // 期望大小
                            &actual_plab_size);
        
        if (buf != NULL) {
            // 5. 绑定新 PLAB
            alloc_buf->set_buf(buf, actual_plab_size);
            
            // 6. 在新 PLAB 中分配
            HeapWord* const obj = alloc_buf->allocate(word_sz);
            assert(obj != NULL, "PLAB should be big enough");
            return obj;
        }
        
        // 7. 申请失败，标记 PLAB refill 失败
        *plab_refill_failed = true;
    }
    
    // 8. Fallback：直接分配（不经过 PLAB）
    HeapWord* result = _allocator->par_allocate_during_gc(dest, word_sz);
    if (result != NULL) {
        _direct_allocated[dest.value()] += word_sz;
    }
    return result;
}
```

#### may_throw_away_buffer 逻辑

```cpp
bool G1PLABAllocator::may_throw_away_buffer(
        size_t const allocation_word_sz, 
        size_t const buffer_size) const {
    // 默认 ParallelGCBufferWastePct = 10
    // 如果新对象小于 PLAB 的 10%，认为当前 PLAB 太浪费，丢弃
    return (allocation_word_sz * 100 < buffer_size * ParallelGCBufferWastePct);
}

// 示例：
// PLAB 大小 = 4096 words
// 新对象大小 = 100 words
// 检查：100 * 100 < 4096 * 10  =>  10000 < 40960  =>  true（丢弃）
```

**为什么需要丢弃机制？**
- 防止大对象占用小 PLAB 导致大量浪费
- 平衡内存使用和分配效率
- 默认 10% 阈值可调整（`-XX:ParallelGCBufferWastePct`）

### 5.3 在 copy_to_survivor_space 中的使用

```cpp
oop G1ParScanThreadState::copy_to_survivor_space(...) {
    const size_t word_sz = old->size();
    
    // 1. 首先尝试 PLAB 分配（Fast Path）
    HeapWord* obj_ptr = _plab_allocator->plab_allocate(dest_state, word_sz);
    
    if (obj_ptr == NULL) {
        // 2. PLAB 满，走 Slow Path
        bool plab_refill_failed = false;
        obj_ptr = _plab_allocator->allocate_direct_or_new_plab(
                      dest_state, word_sz, &plab_refill_failed);
        
        if (obj_ptr == NULL) {
            // 3. 分配失败，处理 Evacuation Failure
            return handle_evacuation_failure_par(old, old_mark);
        }
    }
    
    // 4. 分配成功，复制对象
    Copy::aligned_disjoint_words((HeapWord*)old, obj_ptr, word_sz);
    
    // 5. 尝试安装转发指针
    const oop forward_ptr = old->forward_to_atomic(obj, memory_order_relaxed);
    
    if (forward_ptr == NULL) {
        // 6. CAS 成功，复制成功
        return cast_to_oop(obj_ptr);
    } else {
        // 7. CAS 失败，撤销分配
        _plab_allocator->undo_allocation(dest_state, obj_ptr, word_sz);
        return forward_ptr;
    }
}
```

---

## 6. 自适应 PLAB 大小调整

### 6.1 PLABStats 统计

```cpp
class PLABStats : public CHeapObj<mtGC> {
protected:
    size_t _allocated;          // 累计分配量
    size_t _wasted;             // 浪费（内部碎片）
    size_t _undo_wasted;        // Undo 导致的浪费
    size_t _unused;             // 最后 PLAB 剩余
    size_t _desired_net_plab_sz;// 期望 PLAB 大小
    AdaptiveWeightedAverage _filter;  // 自适应滤波器

public:
    // 计算期望 PLAB 大小
    size_t desired_plab_sz(uint no_of_gc_workers);
    
    // 调整 PLAB 大小
    void adjust_desired_plab_sz();
};
```

### 6.2 调整算法

```cpp
size_t PLABStats::compute_desired_plab_sz() {
    // 1. 计算使用效率
    // 有效使用 = 分配量 - 浪费 - 未使用
    size_t used = _allocated - (_wasted + _unused);
    
    // 2. 计算期望大小
    // 基于历史数据使用加权移动平均
    size_t desired_size = used / _filter.average();
    
    // 3. 边界限制
    // 最小：PLAB::min_size()（默认 1KB）
    // 最大：PLAB::max_size()（默认 1MB）
    desired_size = MAX2(desired_size, PLAB::min_size());
    desired_size = MIN2(desired_size, PLAB::max_size());
    
    // 4. 对齐调整
    desired_size = align_down(desired_size, PLAB::min_size());
    
    return desired_size;
}
```

### 6.3 G1 的 PLAB 大小

```cpp
// G1CollectedHeap 为不同目标区域维护独立的 PLABStats
G1EvacStats* _alloc_buffer_stats[InCSetState::Num];

// 获取期望 PLAB 大小
size_t G1CollectedHeap::desired_plab_sz(InCSetState dest) {
    return _alloc_buffer_stats[dest.value()]->desired_plab_sz(workers()->active_workers());
}
```

**默认大小**：
- Young PLAB：通常 4KB-64KB（根据负载自适应）
- Old PLAB：通常 4KB-64KB

**相关 JVM 参数**：
- `-XX:MinPLABSize`：最小 PLAB 大小（默认 1KB）
- `-XX:MaxPLABSize`：最大 PLAB 大小（默认 1MB）
- `-XX:ParallelGCBufferWastePct`：浪费百分比阈值（默认 10）

---

## 7. 性能优化分析

### 7.1 分配延迟对比

| 分配方式 | 延迟 | 竞争程度 | 使用场景 |
|----------|------|----------|----------|
| **PLAB Fast Path** | ~5ns | 无 | 99%+ 的分配 |
| **PLAB Refill** | ~100ns-1μs | 有（批量） | PLAB 耗尽时 |
| **直接 Region 分配** | ~20-50ns | 高（每次 CAS） | 大对象、Fallback |
| **堆扩展** | ~1-10ms | 全局锁 | 堆满时 |

**优化效果**：
- 99% 的分配走 Fast Path，无锁
- PLAB Refill 批量申请，分摊 CAS 开销
- 自适应大小减少浪费

### 7.2 空间效率分析

```
PLAB 空间效率
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

场景1：PLAB 大小合适（4KB）
┌─────────────────────────────────────────────────────┐
│ 对象1(100B) │ 对象2(200B) │ ... │ 对象N(150B) │空闲 │
└─────────────────────────────────────────────────────┘
浪费率：~5-10%（可接受）

场景2：PLAB 过大（1MB）
┌─────────────────────────────────────────────────────┐
│ 少量对象 │ 大量空闲 │
└─────────────────────────────────────────────────────┘
浪费率：~50-80%（不可接受）

场景3：PLAB 过小（256B）
┌─────────────────────────────────────────────────────┐
│ 对象1 │ PLAB 满，申请新 PLAB │ 对象2 │ PLAB 满... │
└─────────────────────────────────────────────────────┘
问题：频繁 refill，CAS 开销增加

G1 的自适应策略：
  - 小负载：PLAB 较小（4KB）
  - 大负载：PLAB 较大（64KB）
  - 动态调整，平衡效率和浪费
```

---

## 8. 常见问题与面试题

### Q1: PLAB 和 TLAB 的区别是什么？

**答案**：
| 特性 | PLAB | TLAB |
|------|------|------|
| 使用阶段 | GC 期间（Evacuation） | Mutator 期间（应用运行） |
| 分配来源 | Eden/Survivor/Old | Eden |
| 大小 | 4KB-1MB（自适应） | 通常固定或自适应 |
| 线程 | GC 工作线程 | 应用线程 |
| 目的 | 减少 GC 线程竞争 | 减少应用线程竞争 |

### Q2: 为什么要丢弃当前 PLAB（may_throw_away_buffer）？

**答案**：
1. **防止大对象浪费**：如果新对象很大（>10% PLAB），当前 PLAB 剩余空间可能无法充分利用
2. **内存效率**：丢弃后申请新 PLAB，旧 PLAB 剩余空间被填充对象利用
3. **可调参数**：`-XX:ParallelGCBufferWastePct` 控制阈值

### Q3: PLAB 大小是如何自适应调整的？

**答案**：
1. **统计数据**：每次 GC 收集 allocated、wasted、unused
2. **滤波算法**：使用 AdaptiveWeightedAverage 计算加权平均
3. **计算期望大小**：基于历史有效使用率
4. **边界限制**：限制在 min_size 和 max_size 之间

### Q4: undo_allocation 什么时候使用？

**答案**：
- **场景**：PLAB 分配成功，但 CAS 安装转发指针失败（其他线程已复制）
- **操作**：将 PLAB 的 `_top` 回退，释放分配的空间
- **目的**：避免内存泄漏，保持 PLAB 一致性

---

## 9. 总结

### 9.1 核心设计要点

```
G1PLAB 设计精髓
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. 三级分配架构
   ├── PLAB Fast Path：无锁 bump-the-pointer（99%）
   ├── PLAB Refill：批量申请新缓冲区（<1%）
   └── Direct Allocate：Fallback（极少）

2. 线程本地优化
   ├── 每个 GC 线程独立 PLAB
   ├── 无 CAS 竞争
   └── 缓存行对齐（避免伪共享）

3. 自适应调整
   ├── 统计分配效率
   ├── 加权移动平均
   └── 动态调整 PLAB 大小

4. 内存效率
   ├── 丢弃浪费过多的 PLAB
   ├── 填充对象利用剩余空间
   └── 可调阈值参数
```

### 9.2 性能数据估算

```
标准场景（8 线程 GC，4MB Region）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

无 PLAB：
  - 每次分配 CAS 竞争
  - 预估吞吐量损失：30-50%

有 PLAB（默认）：
  - 99% 分配无锁
  - 1% 分配批量 CAS
  - 预估吞吐量提升：20-40%
  - 内存浪费：<10%
```

---

## 参考文档

1. OpenJDK 11: `src/hotspot/share/gc/g1/g1Allocator.hpp`
2. OpenJDK 11: `src/hotspot/share/gc/g1/g1Allocator.inline.hpp`
3. OpenJDK 11: `src/hotspot/share/gc/g1/g1Allocator.cpp`
4. OpenJDK 11: `src/hotspot/share/gc/shared/plab.hpp`
5. Jones & Lins, "Garbage Collection: Algorithms for Automatic Dynamic Memory Management"

---

**文档信息**
- 创建时间: 2026-02-10
- 源码版本: OpenJDK 11
- 分析类型: 专家级源码分析
- 配套技能: Read-BottomUp, JVM-Optimization-Design
