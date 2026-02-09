# D.8/D.9/D.10 初始化列表字段合并分析

> **分析条件**：8GB 堆（-Xms8g -Xmx8g），G1 GC，4MB Region
> **源码位置**：`g1CollectedHeap.cpp:1485-1497`

---

## D.8 Region 集合

### 源码

```cpp
// g1CollectedHeap.cpp:1485
_old_set("Old Set", false, new OldRegionSetMtSafeChecker()),
_humongous_set("Master Humongous Set", true, new HumongousRegionSetMtSafeChecker()),
```

### HeapRegionSet 类结构

```cpp
// heapRegionSet.hpp:64
class HeapRegionSetBase {
  bool _is_humongous;           // 是否存储巨型区域
  bool _is_free;                // 是否存储空闲区域
  HRSMtSafeChecker* _mt_safety_checker;  // 线程安全检查器
  
  uint _length;                 // Region 数量
  const char* _name;            // 集合名称
};

class HeapRegionSet : public HeapRegionSetBase {
  // 简单计数器实现，无链表
};

class FreeRegionList : public HeapRegionSetBase {
  HeapRegion* _head;            // 双向链表头
  HeapRegion* _tail;            // 双向链表尾
  HeapRegion* _last;            // 上次插入位置（优化顺序插入）
};
```

### 三种 Region 集合

| 集合 | 类型 | 用途 | 数据结构 |
|------|------|------|----------|
| `_old_set` | HeapRegionSet | 老年代 Region 计数 | 计数器 |
| `_humongous_set` | HeapRegionSet | 巨型 Region 计数 | 计数器 |
| `_free_list` | FreeRegionList | 空闲 Region 池 | 双向链表 |

### MtSafeChecker 线程安全检查

```cpp
// heapRegionSet.hpp:33
class HRSMtSafeChecker : public CHeapObj<mtGC> {
public:
  virtual void check() = 0;  // 检查当前操作是否线程安全
};

// 实现类
class OldRegionSetMtSafeChecker : public HRSMtSafeChecker {
  void check() {
    // 检查是否持有堆锁或在安全点
    guarantee(Heap_lock->owned_by_self() || 
              SafepointSynchronize::is_at_safepoint(),
              "Must own Heap_lock or be at safepoint");
  }
};
```

**为什么需要检查？**
- Region 集合是共享数据结构
- 并发修改会导致数据不一致
- DEBUG 构建中会触发断言失败

---

## D.9 统计与 PLAB

### 源码

```cpp
// g1CollectedHeap.cpp:1489-1492
_summary_bytes_used(0),
_survivor_evac_stats("Young", YoungPLABSize, PLABWeight),
_old_evac_stats("Old", OldPLABSize, PLABWeight),
```

### PLAB 机制详解

**PLAB = Promotion Local Allocation Buffer**

**问题**：GC 时多线程并发复制对象到 Survivor/Old 区，直接 CAS 分配会产生大量竞争。

**解决**：每个 GC 线程维护自己的本地分配缓冲区（类似 TLAB）。

```
┌─────────────────────────────────────────────────────────────────┐
│                      Survivor Region                             │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
│  │ GC Thread 0 │  │ GC Thread 1 │  │ GC Thread N │    未分配    │
│  │   PLAB      │  │   PLAB      │  │   PLAB      │              │
│  │  (32KB)     │  │  (32KB)     │  │  (32KB)     │              │
│  └─────────────┘  └─────────────┘  └─────────────┘              │
│        ↑               ↑               ↑                        │
│   无锁分配         无锁分配         无锁分配                      │
└─────────────────────────────────────────────────────────────────┘
```

### PLAB 数据结构

```cpp
// plab.hpp:36
class PLAB: public CHeapObj<mtGC> {
  size_t    _word_sz;       // PLAB 大小（words）
  HeapWord* _bottom;        // 起始地址
  HeapWord* _top;           // 当前分配位置
  HeapWord* _end;           // 结束地址
  
  size_t    _allocated;     // 已分配量
  size_t    _wasted;        // 浪费量（内部碎片）
};
```

### G1EvacStats - G1 特有的统计

```cpp
// g1EvacStats.hpp:31
class G1EvacStats : public PLABStats {
  size_t _region_end_waste;   // Region 末尾浪费
  uint   _regions_filled;     // 完全填满的 Region 数
  size_t _direct_allocated;   // 直接分配（绕过 PLAB）
  
  size_t _failure_used;       // 疏散失败的存活对象
  size_t _failure_waste;      // 疏散失败的浪费
};
```

### 默认参数值

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `YoungPLABSize` | 4096 words = 32KB | Survivor PLAB 大小 |
| `OldPLABSize` | 1024 words = 8KB | Old PLAB 大小 |
| `PLABWeight` | 75 | 自适应调整权重 |

**为什么 Young > Old？**
- Survivor 区对象通常较小且数量多
- Old 区晋升对象相对较少
- Young PLAB 大 → 减少申请次数

### 🏭 生产环境实践

**监控 PLAB 效率**：
```bash
-Xlog:gc+plab=debug

# 输出示例
[gc,plab] Young PLAB: allocated 1234KB, wasted 56KB (4.5%)
[gc,plab] Old PLAB: allocated 567KB, wasted 12KB (2.1%)
```

**调优建议**：

| 场景 | 调整 | 原因 |
|------|------|------|
| PLAB 浪费率 > 10% | 减小 PLAB | 碎片过多 |
| direct allocation 过多 | 增大 PLAB | 大对象绕过 PLAB |
| GC 线程竞争严重 | 增大 PLAB | 减少申请频率 |

```bash
# 大对象较多场景
-XX:YoungPLABSize=8192
-XX:OldPLABSize=2048
```

---

## D.10 其他标志

### 源码

```cpp
// g1CollectedHeap.cpp:1494-1497
_expand_heap_after_alloc_failure(true),
_old_marking_cycles_started(0),
_old_marking_cycles_completed(0),
_in_cset_fast_test(),
```

### _expand_heap_after_alloc_failure

```cpp
bool _expand_heap_after_alloc_failure;  // 默认 true
```

**作用**：分配失败后是否尝试扩展堆。

**在 Xms=Xmx 配置下**：虽然设为 true，但实际上无法扩展（已达最大值）。

### _old_marking_cycles_started/completed

```cpp
uint _old_marking_cycles_started;   // 已启动的并发标记周期数
uint _old_marking_cycles_completed; // 已完成的并发标记周期数
```

**用途**：
- 判断是否有正在进行的并发标记
- `started > completed` 表示标记进行中
- 用于协调并发标记与疏散暂停

### _in_cset_fast_test【重要】

```cpp
G1InCSetStateFastTestBiasedMappedArray _in_cset_fast_test;
```

**作用**：O(1) 判断对象是否在 Collection Set 中。

**核心设计**：

```cpp
// 4 种状态
enum InCSetState {
  NotInCSet = 0,     // 不在 CSet
  Young     = 1,     // 年轻代，在 CSet
  Old       = 2,     // 老年代，在 CSet
  Humongous = -1     // 巨型对象，特殊处理
};
```

**实现原理**（偏置数组）：

```
                    _in_cset_fast_test 数组
                    ┌───┬───┬───┬───┬───┬───┬───┬───┐
                    │ 0 │ 1 │ 0 │ 2 │ 0 │ 0 │-1 │ 0 │
                    └───┴───┴───┴───┴───┴───┴───┴───┘
                      ↑   ↑       ↑           ↑
                    R0  R1      R3          R6
                    不在 Young   Old       Humongous
                    CSet 在CSet  在CSet     特殊

查询：obj_addr >> 22 → index → _in_cset_fast_test[index]
```

**8GB 堆配置**：
```
数组长度 = 8GB / 4MB = 2048 个元素
每元素 1 字节
总内存 = 2KB
```

**为什么重要？**

这是 GC 热路径上的关键操作：
```cpp
// g1CollectedHeap.inline.hpp:144
InCSetState G1CollectedHeap::in_cset_state(const oop obj) {
  return _in_cset_fast_test.at((HeapWord*)obj);  // O(1) 查找
}
```

每次对象引用更新、复制时都会调用，必须极快。

---

## 完整内存布局

```
G1CollectedHeap 初始化列表字段
┌─────────────────────────────────────────────────────────────────┐
│                                                                  │
│  D.8 Region 集合                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ _old_set      : {_length=0, _name="Old Set"}             │   │
│  │ _humongous_set: {_length=0, _name="Master Humongous Set"}│   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  D.9 PLAB 统计                                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ _summary_bytes_used = 0                                   │   │
│  │ _survivor_evac_stats: PLAB=32KB, weight=75               │   │
│  │ _old_evac_stats:      PLAB=8KB,  weight=75               │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  D.10 其他标志                                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ _expand_heap_after_alloc_failure = true                   │   │
│  │ _old_marking_cycles_started = 0                           │   │
│  │ _old_marking_cycles_completed = 0                         │   │
│  │ _in_cset_fast_test: [2048 bytes, 偏置数组]                │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## GDB 验证脚本

```bash
# 文件：jvm-md/tmp-file/universe-init/gdb_init_list.txt

b g1CollectedHeap.cpp:1497
commands
  printf "\n=== D.8/D.9/D.10 初始化列表字段验证 ===\n"
  
  printf "\n[D.8] Region 集合:\n"
  printf "  _old_set._length = %u\n", _old_set._length
  printf "  _old_set._name = %s\n", _old_set._name
  printf "  _humongous_set._length = %u\n", _humongous_set._length
  printf "  _humongous_set._name = %s\n", _humongous_set._name
  
  printf "\n[D.9] PLAB 统计:\n"
  printf "  _summary_bytes_used = %zu\n", _summary_bytes_used
  printf "  _survivor_evac_stats._description = %s\n", _survivor_evac_stats._description
  printf "  _old_evac_stats._description = %s\n", _old_evac_stats._description
  printf "  YoungPLABSize = %zu words (%zu KB)\n", YoungPLABSize, YoungPLABSize*8/1024
  printf "  OldPLABSize = %zu words (%zu KB)\n", OldPLABSize, OldPLABSize*8/1024
  
  printf "\n[D.10] 其他标志:\n"
  printf "  _expand_heap_after_alloc_failure = %d\n", _expand_heap_after_alloc_failure
  printf "  _old_marking_cycles_started = %u\n", _old_marking_cycles_started
  printf "  _old_marking_cycles_completed = %u\n", _old_marking_cycles_completed
  
  continue
end

run
```

**预期输出**：
```
=== D.8/D.9/D.10 初始化列表字段验证 ===

[D.8] Region 集合:
  _old_set._length = 0
  _old_set._name = "Old Set"
  _humongous_set._length = 0
  _humongous_set._name = "Master Humongous Set"

[D.9] PLAB 统计:
  _summary_bytes_used = 0
  _survivor_evac_stats._description = "Young"
  _old_evac_stats._description = "Old"
  YoungPLABSize = 4096 words (32 KB)
  OldPLABSize = 1024 words (8 KB)

[D.10] 其他标志:
  _expand_heap_after_alloc_failure = 1
  _old_marking_cycles_started = 0
  _old_marking_cycles_completed = 0
```

---

## 🏭 生产环境综合建议

### PLAB 调优

```bash
# 默认配置（大多数场景）
# 无需调整

# 大对象较多（> 1KB）
-XX:YoungPLABSize=8192
-XX:OldPLABSize=2048

# 监控 PLAB 效率
-Xlog:gc+plab=debug
```

### in_cset_fast_test 相关

无需调优，这是内部实现细节。但理解它有助于：
- 理解 GC 暂停时的性能特征
- 排查奇怪的 GC 行为

---

## 待分析节点更新

| 节点 | 主题 | 状态 |
|------|------|------|
| **D.8.1** | HeapRegionSet 的数据结构 | ✅ |
| **D.8.2** | MtSafeChecker 的作用 | ✅ |
| **D.9.1** | PLAB 机制 | ✅ |
| **D.9.2** | PLABWeight 参数 | ✅ |
| **D.10.1** | _expand_heap_after_alloc_failure | ✅ |
| **D.10.2** | _in_cset_fast_test 位图实现 | ✅ |
