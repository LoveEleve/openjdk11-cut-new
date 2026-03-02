# G1AllocRegion 专家级源码分析

> **定位**：G1 Young GC 对象复制的目标 Region 管理器  
> **核心问题**：Evacuation 时对象复制到哪个 Region？Survivor 满了怎么办？  
> **源码路径**：`src/hotspot/share/gc/g1/g1AllocRegion.hpp`

---

## 1. 一句话总结

**G1AllocRegion 是一个两级分配架构的抽象基类，通过"当前活动 Region + Dummy Region 回退"机制，实现无锁 fast-path 分配，在 Region 满时通过加锁 slow-path 获取新 Region。**

---

## 2. 为什么需要 G1AllocRegion？

### 2.1 问题背景

在 G1 Young GC 的 Evacuation 阶段，需要将存活对象从 CSet Region 复制到新的 Region：
- **新生代对象** → Survivor Region
- **晋升对象** → Old Region

**核心挑战**：
1. **高并发分配**：多个 GC 线程同时复制对象
2. **Region 边界**：一个 Region 满了需要切换到下一个
3. **内存效率**：避免 Region 末尾的内存碎片浪费

### 2.2 如果没有 G1AllocRegion？

```
❌ 方案1：直接操作 HeapRegion
   - 每个线程直接对 HeapRegion::par_allocate()
   - 问题：Region 满时切换逻辑分散在各处，难以维护

❌ 方案2：全局分配器 + 锁
   - 所有线程竞争一个分配器
   - 问题：锁竞争激烈，性能瓶颈

✅ 方案3：线程本地分配器 + 两级分配（实际采用）
   - Fast path：本地无锁分配
   - Slow path：加锁获取新 Region
   - 统一的 Region 切换和回收逻辑
```

---

## 3. 整体架构与类继承关系

```
类继承层次
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
G1AllocRegion (基类)
├── MutatorAllocRegion       # 应用线程 Eden 分配
│   └── _retained_alloc_region  # 保留的 Region 减少浪费
├── G1GCAllocRegion          # GC 线程分配基类
    ├── SurvivorGCAllocRegion   # Survivor 区分配
    └── OldGCAllocRegion        # Old 区分配（处理 BOT 对齐）
```

### 各子类职责

| 子类 | 使用场景 | 特殊功能 |
|------|----------|----------|
| **MutatorAllocRegion** | 应用线程 TLAB 分配 | Retain 机制减少 Region 浪费 |
| **SurvivorGCAllocRegion** | GC 线程 Survivor 分配 | 无 BOT 更新（年轻代统一扫描） |
| **OldGCAllocRegion** | GC 线程 Old 区分配（晋升） | BOT 更新、对齐到卡边界 |

---

## 4. 核心数据结构详解

### 4.1 G1AllocRegion 基类

```cpp
class G1AllocRegion {
private:
    // 当前活动的分配 Region
    // 可能指向：实际 Region 或 _dummy_region（永远不会为 NULL）
    HeapRegion *volatile _alloc_region;
    
    // 当前活跃期间使用的 Region 数量统计
    uint _count;
    
    // 当前 Region 初始使用字节数（用于计算本次分配量）
    size_t _used_bytes_before;
    
    // 是否需要 BOT 更新（Old 区需要，Survivor 不需要）
    const bool _bot_updates;
    
    // 调试/日志名称
    const char *_name;
    
    // Dummy Region：全局共享的"满"Region
    // 任何分配请求都会失败，避免 NULL 检查
    static HeapRegion *_dummy_region;
};
```

#### 关键字段解析

| 字段 | 类型 | 作用 | 为什么重要 |
|------|------|------|-----------|
| `_alloc_region` | HeapRegion* volatile | 当前活动 Region | 分配的核心目标，volatile 保证多线程可见性 |
| `_count` | uint | 使用过的 Region 数 | 统计和启发式算法使用 |
| `_used_bytes_before` | size_t | Region 初始使用量 | 计算本次 GC/分配周期内的实际分配量 |
| `_bot_updates` | const bool | 是否需要 BOT 更新 | Old 区需要精确记录对象位置 |
| `_dummy_region` | static HeapRegion* | 全局虚拟满 Region | **核心设计**：避免 NULL 检查，简化 fast path |

### 4.2 Dummy Region 设计模式

```
Dummy Region 的作用
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

传统模式：
  if (_alloc_region != NULL) {
      result = par_allocate(_alloc_region, size);  // 需要 NULL 检查
  } else {
      result = NULL;
  }

Dummy Region 模式：
  // _alloc_region 永远不会为 NULL
  // 如果没有实际 Region，指向 _dummy_region（已满）
  result = par_allocate(_alloc_region, size);
  // 如果 _alloc_region 是 dummy，par_allocate 返回 NULL
```

**设计优势**：
1. **消除分支预测失败**：无需 NULL 检查，直接调用
2. **简化代码逻辑**：所有路径统一处理
3. **线程安全**：volatile 保证可见性，无需额外同步

### 4.3 MutatorAllocRegion 的 Retain 机制

```cpp
class MutatorAllocRegion : public G1AllocRegion {
private:
    size_t _wasted_bytes;                    // 累计浪费字节数
    HeapRegion *volatile _retained_alloc_region;  // 保留的 Region
    
    bool should_retain(HeapRegion* region) {
        size_t free_bytes = region->free();
        // 保留条件：剩余空间 >= MinTLABSize 且比之前保留的更大
        if (free_bytes < MinTLABSize) return false;
        if (_retained_alloc_region != NULL && 
            free_bytes < _retained_alloc_region->free()) {
            return false;
        }
        return true;
    }
};
```

**Retain 机制解决的问题**：

```
场景：Mutator 分配 Eden 对象
─────────────────────────────────────────────────

Region A (当前分配 Region)
┌────────────────────────────────────────────────┐
│已分配 3MB │ 剩余 1MB (小于 MinTLABSize=32KB?) │
└────────────────────────────────────────────────┘
             ↑
             这 1MB 如果不保留，直接浪费

Retain 机制：
  if (should_retain(Region A)) {
      _retained_alloc_region = Region A;  // 保留给下次使用
  } else {
      retire(Region A);  // 回收剩余空间
  }
  
下次分配：
  1. 先尝试 _retained_alloc_region（可能还有空间）
  2. 失败后再获取新 Region
```

---

## 5. 两级分配架构详解

### 5.1 分配路径层级

```
分配请求流程
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Level 1: Fast Path（无锁，本地操作）
┌─────────────────────────────────────────────────────┐
│ attempt_allocation()                                │
│   └── par_allocate(_alloc_region, size)            │
│       └── CAS 尝试在 _alloc_region 分配            │
│           ├── 成功：返回分配地址                    │
│           └── 失败：返回 NULL（进入 Level 2）      │
└─────────────────────────────────────────────────────┘
                        ↓ 失败
Level 2: Slow Path（加锁，可能切换 Region）
┌─────────────────────────────────────────────────────┐
│ attempt_allocation_locked()                         │
│   ├── 重试 attempt_allocation()（可能其他线程已换）│
│   ├── 成功：返回                                    │
│   │                                                 │
│   └── 失败：                                        │
│       ├── retire(true)  # 回收当前 Region          │
│       ├── allocate_new_region()  # 获取新 Region   │
│       └── 在新 Region 分配                          │
└─────────────────────────────────────────────────────┘
                        ↓ 失败
Level 3: Force Path（强制分配，可能触发扩展）
┌─────────────────────────────────────────────────────┐
│ attempt_allocation_force()                          │
│   └── 即使超过最大 Region 限制也尝试分配           │
└─────────────────────────────────────────────────────┘
```

### 5.2 Fast Path 源码

```cpp
// g1AllocRegion.inline.hpp
inline HeapWord* G1AllocRegion::attempt_allocation(size_t min_word_size,
                                                   size_t desired_word_size,
                                                   size_t* actual_word_size) {
    // 1. 读取当前活动 Region（volatile，保证看到最新值）
    HeapRegion* alloc_region = _alloc_region;
    
    // 2. 尝试 CAS 分配（多线程安全）
    HeapWord* result = par_allocate(alloc_region, min_word_size, 
                                     desired_word_size, actual_word_size);
    if (result != NULL) {
        return result;  // Fast path 成功
    }
    
    // 3. 失败，返回 NULL 让 caller 走 slow path
    return NULL;
}
```

**关键设计**：
- 无锁：只读取 volatile 变量 + CAS 操作
- O(1) 复杂度：单次 CAS 尝试
- 高命中率：大部分时间 Region 未满

### 5.3 Slow Path 源码

```cpp
inline HeapWord* G1AllocRegion::attempt_allocation_locked(
                                           size_t min_word_size,
                                           size_t desired_word_size,
                                           size_t* actual_word_size) {
    // 1. 先重试 fast path（可能其他线程刚换了 Region）
    HeapWord* result = attempt_allocation(min_word_size, desired_word_size, 
                                          actual_word_size);
    if (result != NULL) return result;
    
    // 2. Retire 当前 Region（回收剩余空间）
    retire(true /* fill_up */);
    
    // 3. 分配新 Region 并在其中分配
    result = new_alloc_region_and_allocate(desired_word_size, false /* force */);
    if (result != NULL) {
        *actual_word_size = desired_word_size;
        return result;
    }
    
    return NULL;
}
```

**为什么需要加锁？**
- `retire()` 和 `new_alloc_region_and_allocate()` 需要修改 `_alloc_region`
- 多线程并发调用时可能导致状态不一致
- 锁的粒度：只在 Region 切换时加锁，分配本身无锁

### 5.4 Region Retire（回收）机制

```cpp
size_t G1AllocRegion::retire(bool fill_up) {
    HeapRegion* alloc_region = _alloc_region;
    
    if (alloc_region != _dummy_region) {
        // 1. 填充剩余空间（防止其他线程继续分配）
        if (fill_up) {
            waste = fill_up_remaining_space(alloc_region);
        }
        
        // 2. 计算本次分配量
        size_t allocated_bytes = alloc_region->used() - _used_bytes_before;
        
        // 3. 调用子类实现的 Region 回收逻辑
        retire_region(alloc_region, allocated_bytes);
        
        // 4. 重置为 dummy region
        reset_alloc_region();
    }
    
    return waste;
}
```

**fill_up_remaining_space() 的作用**：

```
Region 回收前的状态
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Before fill_up:
┌─────────────────────────────────────────────────────────┐
│ 已分配对象 │ 空闲空间（可能小于最小对象大小）│
└─────────────────────────────────────────────────────────┘
             ↑_top                    ↑_end

After fill_up:
┌─────────────────────────────────────────────────────────┐
│ 已分配对象 │ 填充对象（Dummy Object）│
└─────────────────────────────────────────────────────────┘
             ↑_top = _end（Region 满）

目的：
1. 防止其他线程继续尝试分配（CAS 会失败）
2. 保持 HeapRegion 的"已分配"语义一致性
3. 便于计算准确的内存使用量
```

---

## 6. 子类特化实现

### 6.1 MutatorAllocRegion

```cpp
class MutatorAllocRegion : public G1AllocRegion {
    // 核心特化：Retain 机制
    
    size_t retire(bool fill_up) {
        HeapRegion* current_region = get();
        
        if (should_retain(current_region)) {
            // 保留当前 Region，退役之前保留的
            if (_retained_alloc_region != NULL) {
                waste = retire_internal(_retained_alloc_region, true);
            }
            _retained_alloc_region = current_region;
        } else {
            // 不保留，直接退役
            waste = retire_internal(current_region, fill_up);
        }
        
        _wasted_bytes += waste;
        reset_alloc_region();
        return waste;
    }
};
```

**Retain 策略的优势**：
- 减少 Region 切换次数（切换需要加锁，开销大）
- 减少内存碎片（小空间累积利用）
- 提高 TLAB 命中率

### 6.2 SurvivorGCAllocRegion vs OldGCAllocRegion

```cpp
// Survivor：不需要 BOT 更新
class SurvivorGCAllocRegion : public G1GCAllocRegion {
public:
    SurvivorGCAllocRegion(G1EvacStats* stats)
        : G1GCAllocRegion("Survivor GC Alloc Region", 
                          false /* bot_updates */,  // ❌ 不需要 BOT
                          stats, 
                          InCSetState::Young) {}
};

// Old：需要 BOT 更新
class OldGCAllocRegion : public G1GCAllocRegion {
public:
    OldGCAllocRegion(G1EvacStats* stats)
        : G1GCAllocRegion("Old GC Alloc Region", 
                          true /* bot_updates */,   // ✅ 需要 BOT
                          stats, 
                          InCSetState::Old) {}
};
```

**为什么 Survivor 不需要 BOT？**
- Survivor 区在 Young GC 中会被完全扫描
- 不需要通过 BOT 快速定位对象
- 省去 BOT 更新开销

**Old 区为什么需要 BOT？**
- 并发标记时需要快速定位对象起始位置
- 跨 Region 引用需要精确的对象边界
- BOT 加速从卡地址到对象地址的映射

### 6.3 OldGCAllocRegion 的特殊处理

```cpp
HeapRegion* OldGCAllocRegion::release() {
    HeapRegion* cur = get();
    if (cur != NULL) {
        // BOT 对齐处理：确保 top 对齐到卡边界
        HeapWord* top = cur->top();
        HeapWord* aligned_top = align_up(top, BOTConstants::N_bytes);
        
        size_t to_allocate_words = pointer_delta(aligned_top, top, HeapWordSize);
        
        if (to_allocate_words != 0) {
            // 分配填充对象到卡边界
            to_allocate_words = MIN2(pointer_delta(cur->end(), cur->top(), HeapWordSize),
                                     MAX2(to_allocate_words, G1CollectedHeap::min_fill_size()));
            
            if (to_allocate_words >= G1CollectedHeap::min_fill_size()) {
                HeapWord* dummy = attempt_allocation(to_allocate_words);
                CollectedHeap::fill_with_object(dummy, to_allocate_words);
            }
        }
    }
    return G1AllocRegion::release();
}
```

**对齐到卡边界的目的**：
1. **RSet 更新简化**：卡边界与 RSet 粒度对齐
2. **BOT 一致性**：BOT 条目按卡粒度组织
3. **避免跨卡对象**：减少 RSet 更新复杂度

---

## 7. 内存布局与 GDB 验证

### 7.1 结构体大小

【GDB 验证脚本】
```bash
cd /data/workspace/openjdk-cut-new

cat > jvm-md/tmp-file/g1allocregion/gdb_verify.txt << 'EOF'
set pagination off
set print pretty on

# 在 G1AllocRegion 初始化后断点
b G1AllocRegion::init
run -XX:+UseG1GC -Xms8g -Xmx8g -version

printf "\n========== G1AllocRegion 结构验证 ==========\n"

# 计算各结构大小
printf "\n结构体大小:\n"
printf "sizeof(G1AllocRegion)              = %lu\n", sizeof(G1AllocRegion)
printf "sizeof(MutatorAllocRegion)         = %lu\n", sizeof(MutatorAllocRegion)
printf "sizeof(G1GCAllocRegion)            = %lu\n", sizeof(G1GCAllocRegion)
printf "sizeof(SurvivorGCAllocRegion)      = %lu\n", sizeof(SurvivorGCAllocRegion)
printf "sizeof(OldGCAllocRegion)           = %lu\n", sizeof(OldGCAllocRegion)

# 验证字段偏移
printf "\nG1AllocRegion 字段偏移:\n"
set $base = (G1AllocRegion*)0
printf "&_alloc_region - base     = %lu\n", (size_t)&$base->_alloc_region - (size_t)$base
printf "&_count - base            = %lu\n", (size_t)&$base->_count - (size_t)$base
printf "&_used_bytes_before - base = %lu\n", (size_t)&$base->_used_bytes_before - (size_t)$base
printf "&_bot_updates - base      = %lu\n", (size_t)&$base->_bot_updates - (size_t)$base
printf "&_name - base             = %lu\n", (size_t)&$base->_name - (size_t)$base

quit
EOF

gdb -batch -x jvm-md/tmp-file/g1allocregion/gdb_verify.txt \
    --args ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
    -XX:+UseG1GC -Xms8g -Xmx8g -version 2>/dev/null
```

【预期输出】
```
========== G1AllocRegion 结构验证 ==========

结构体大小:
sizeof(G1AllocRegion)              = 48
sizeof(MutatorAllocRegion)         = 72
sizeof(G1GCAllocRegion)            = 64
sizeof(SurvivorGCAllocRegion)      = 64
sizeof(OldGCAllocRegion)           = 64

G1AllocRegion 字段偏移:
&_alloc_region - base      = 0
&_count - base             = 8
&_used_bytes_before - base = 16
&_bot_updates - base       = 24
&_name - base              = 32
```

### 7.2 内存布局图

```
G1AllocRegion (总大小: 48 bytes)
偏移      字段名                  大小    说明
─────────────────────────────────────────────────
0x00     _alloc_region           8       当前活动 Region 指针
0x08     _count                  4       Region 使用计数
0x0C     [padding]               4       对齐填充
0x10     _used_bytes_before      8       初始使用量
0x18     _bot_updates            1       BOT 更新标志
0x19     [padding]               7       对齐填充
0x20     _name                   8       调试名称指针
─────────────────────────────────────────────────

MutatorAllocRegion (继承 G1AllocRegion，总大小: 72 bytes)
偏移      字段名                  大小    说明
─────────────────────────────────────────────────
0x00-0x2F G1AllocRegion 基类     48      基类字段
0x30     _wasted_bytes           8       累计浪费字节
0x38     _retained_alloc_region  8       保留的 Region
0x40     [padding]               8       对齐到 8 字节边界
─────────────────────────────────────────────────
```

---

## 8. 在 G1 Evacuation 中的使用

### 8.1 初始化流程

```cpp
// G1ParScanThreadState 构造函数
G1ParScanThreadState::G1ParScanThreadState(G1CollectedHeap* g1h, 
                                           uint worker_id,
                                           size_t young_cset_length) {
    // 初始化 Survivor 分配器
    _survivor_alloc_region = new SurvivorGCAllocRegion(_stats);
    _survivor_alloc_region->init();
    
    // 初始化 Old 分配器
    _old_alloc_region = new OldGCAllocRegion(_stats);
    _old_alloc_region->init();
    
    // ...
}
```

### 8.2 对象复制流程

```cpp
oop G1ParScanThreadState::copy_to_survivor_space(oop obj, ...) {
    // 1. 确定目标类型（Survivor 或 Old）
    InCSetState dest_state = next_state(...);
    
    // 2. 获取对应的分配器
    G1GCAllocRegion* alloc_region = 
        (dest_state.is_young()) ? _survivor_alloc_region : _old_alloc_region;
    
    // 3. 尝试分配（fast path）
    HeapWord* obj_ptr = alloc_region->attempt_allocation(word_sz);
    
    if (obj_ptr == NULL) {
        // 4. Fast path 失败，走 slow path（加锁）
        obj_ptr = alloc_region->attempt_allocation_locked(word_sz);
    }
    
    if (obj_ptr == NULL) {
        // 5. Slow path 也失败，强制分配（可能触发堆扩展）
        obj_ptr = alloc_region->attempt_allocation_force(word_sz);
    }
    
    // 6. 复制对象数据
    Copy::aligned_disjoint_words(...);
    
    return cast_to_oop(obj_ptr);
}
```

### 8.3 生命周期时序图

```
G1AllocRegion 生命周期
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

初始化阶段 (GC 开始)
┌─────────────────────────────────────────────────────┐
│ init()                                              │
│   └── _alloc_region = _dummy_region                 │
│   └── _count = 0                                    │
└─────────────────────────────────────────────────────┘
            ↓
分配阶段 (Evacuation)
┌─────────────────────────────────────────────────────┐
│ 1. attempt_allocation()                             │
│      ├── 成功：分配并返回                           │
│      └── 失败：返回 NULL                            │
│                                                     │
│ 2. attempt_allocation_locked()                      │
│      ├── retire(true) 回收当前 Region              │
│      ├── allocate_new_region() 获取新 Region       │
│      └── 在新 Region 分配                           │
└─────────────────────────────────────────────────────┘
            ↓
回收阶段 (GC 结束)
┌─────────────────────────────────────────────────────┐
│ release()                                           │
│   ├── retire(false) 回收最后一个 Region            │
│   └── _alloc_region = NULL                          │
└─────────────────────────────────────────────────────┘
```

---

## 9. 性能优化分析

### 9.1 Fast Path 为什么快？

```
Fast Path 指令序列（近似）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. mov    _alloc_region, %rax      # 读取 volatile 变量
2. test   %rax, %rax               # 检查（实际不需要，dummy_region 模式）
3. mov    (%rax + top_offset), %rcx # 读取 Region top
4. add    size, %rcx               # 计算新 top
5. cmp    (%rax + end_offset), %rcx # 检查是否超过 end
6. ja     slow_path                # 超过则跳转到 slow path
7. lock cmpxchg ...                # CAS 更新 top
8. jne    slow_path                # CAS 失败跳转
9. mov    old_top, result          # 返回分配地址
```

**关键优化点**：
- **无锁**：只有 CAS 操作，无互斥锁
- **分支预测友好**：大部分时间走成功路径
- **缓存局部性**：`_alloc_region` 经常被访问，在 CPU 缓存中

### 9.2 Slow Path 开销分析

| 操作 | 开销 | 为什么 |
|------|------|--------|
| 加锁 | ~100-200ns | 获取 HeapRegion 的锁 |
| retire | ~500ns-1μs | 填充剩余空间、更新统计 |
| allocate_new_region | ~1-5μs | 从 RegionManager 获取 Region |
| 总计 | ~2-10μs | 远低于 fast path（~10ns） |

**优化策略**：
- PLAB（Promotion Local Allocation Buffer）减少分配次数
- 大对象直接分配到 Heap，不走 PLAB
- Retain 机制减少 Mutator 的 Region 切换

---

## 10. 常见问题与面试题

### Q1: G1AllocRegion 为什么使用 Dummy Region 模式？

**答案**：
1. 避免 NULL 检查分支，简化 fast path
2. Dummy Region 是"已满"的，任何分配请求都会失败并返回 NULL
3. 代码统一：无需特殊处理"无 Region"的情况

### Q2: MutatorAllocRegion 的 Retain 机制解决了什么问题？

**答案**：
1. **问题**：Mutator 分配 Eden 时，Region 末尾的小空间（< MinTLABSize）被浪费
2. **解决**：保留仍有足够空间的 Region，下次分配时复用
3. **效果**：减少 Region 切换次数，降低锁竞争，提高内存利用率

### Q3: Survivor 和 Old 分配器有什么区别？

**答案**：
| 特性 | Survivor | Old |
|------|----------|-----|
| BOT 更新 | 否 | 是 |
| 对齐要求 | 无 | 对齐到卡边界 |
| 统计类型 | Young | Old |
| Region 类型 | Young | Old |

### Q4: 什么时候会触发 Force 分配？

**答案**：
- 当正常分配路径都失败时（GC 压力大、堆快满了）
- Force 分配会尝试扩展堆或触发 GC
- 最后手段，成功后可能触发堆扩展或返回 NULL（OOM）

---

## 11. 总结

### 11.1 核心设计要点

```
G1AllocRegion 设计精髓
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. 两级分配架构
   ├── Fast Path：无锁 CAS 分配（~10ns）
   └── Slow Path：加锁切换 Region（~2-10μs）

2. Dummy Region 模式
   └── _alloc_region 永不为 NULL，避免分支预测失败

3. Region 生命周期管理
   ├── init()：指向 dummy
   ├── allocate()：实际分配
   ├── retire()：回收剩余空间
   └── release()：清理

4. 子类特化
   ├── Mutator：Retain 机制减少浪费
   ├── Survivor：无 BOT 开销
   └── Old：BOT 更新 + 卡边界对齐
```

### 11.2 与其他 GC 的对比

| 特性 | G1 G1AllocRegion | Parallel GC Space | ZGC Page Allocator |
|------|------------------|-------------------|-------------------|
| 分配粒度 | Region (4MB) | 整代 | Page (2MB/4MB) |
| 并发支持 | 是（CAS） | 否（锁） | 是（CAS） |
| 两级分配 | 是 | 否 | 否 |
| Retain 机制 | 是 | 否 | 否 |

---

## 参考文档

1. OpenJDK 11: `src/hotspot/share/gc/g1/g1AllocRegion.hpp`
2. OpenJDK 11: `src/hotspot/share/gc/g1/g1AllocRegion.inline.hpp`
3. OpenJDK 11: `src/hotspot/share/gc/g1/g1AllocRegion.cpp`
4. G1 论文: Detlefs et al., "Garbage-First Garbage Collection"

---

**文档信息**
- 创建时间: 2026-02-10
- 源码版本: OpenJDK 11
- 分析类型: 专家级源码分析
- 配套技能: Read-BottomUp, JVM-Optimization-Design
