# C.7 快速测试数组 (Fast Test Arrays)

## 概述

G1 GC 需要在 GC 过程中频繁判断：
1. **某个对象是否在收集集合（CSet）中？** - 用于决定是否需要疏散
2. **某个巨型对象是否可以被回收？** - 用于急切回收（Eager Reclaim）

传统做法是遍历 CSet 链表查找，时间复杂度 O(n)。G1 通过**偏置数组**将这两种查询优化到 **O(1)**。

```
传统遍历: CSet链表 → O(n) 查找
    ┌─────┐   ┌─────┐   ┌─────┐   ┌─────┐
    │ R0  │──▶│ R5  │──▶│ R12 │──▶│ R99 │
    └─────┘   └─────┘   └─────┘   └─────┘
    需要逐个比较才能判断某个Region是否在CSet中

偏置数组: _in_cset_fast_test → O(1) 访问
    对象地址 0x600400000
         │
         │ >> 22 (右移22位 = 除以4MB)
         ▼
    biased_index = 0x1801
         │
         ▼
    biased_base[0x1801] = Young (1)
    
    直接得知: 该对象在CSet中，属于年轻代区域
```

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **C.7 快速测试数组 (Fast Test Arrays)**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 1. 核心数据结构

### 1.1 G1BiasedMappedArrayBase - 偏置数组基类

```cpp
// src/hotspot/share/gc/g1/g1BiasedArray.hpp
class G1BiasedMappedArrayBase : public CHeapObj<mtGC> {
protected:
  address _base;          // 实际数组起始地址
  size_t _length;         // 数组长度（区域总数）
  address _biased_base;   // 偏置基地址（性能优化核心）
  size_t _bias;           // 地址偏移量
  uint _shift_by;         // 右移位数（log2(region_size) = 22）
};
```

### 1.2 内存布局

```
标准配置（8GB 堆，4MB Region）:
┌─────────────────────────────────────────────────────────────┐
│                    G1BiasedMappedArrayBase                   │
├─────────────────────────────────────────────────────────────┤
│  _base         │ 指向 malloc 分配的 2048 字节               │
│  _length       │ 2048 (区域总数)                            │
│  _biased_base  │ _base - (0x1800 * elem_size)               │
│  _bias         │ 0x1800 (heap_start / 4MB = 6144)           │
│  _shift_by     │ 22 (log2(4MB))                             │
└─────────────────────────────────────────────────────────────┘

数组内存:
┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐
│  0  │  1  │  0  │  0  │  2  │  0  │ -1  │ ... │
├─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┤
│ [0]   [1]   [2]   [3]   [4]   [5]   [6]   ... │
│  ↑     ↑                 ↑           ↑        │
│  │     │                 │           │        │
│ Not  Young              Old      Humongous    │
│InCSet                                         │
└───────────────────────────────────────────────┘
```

---

## 2. InCSetState - 区域状态枚举

### 2.1 状态值设计

```cpp
// src/hotspot/share/gc/g1/g1InCSetState.hpp
struct InCSetState {
  typedef int8_t in_cset_state_t;  // 1字节，节省内存
  
  enum {
    Humongous  = -1,  // 巨型区域（特殊处理）
    NotInCSet  =  0,  // 不在CSet中（默认值）
    Young      =  1,  // 年轻代区域，在CSet中
    Old        =  2,  // 老年代区域，在CSet中
  };
};
```

### 2.2 编码设计的精妙之处

```
值的选择经过精心优化:

1. 最常见检查: 区域是否在CSet中?
   ┌──────────────────────────────────────┐
   │  if (_value > 0) → 在CSet中          │
   │                                      │
   │  Humongous(-1) > 0? → false          │
   │  NotInCSet(0)  > 0? → false          │
   │  Young(1)      > 0? → true  ✓        │
   │  Old(2)        > 0? → true  ✓        │
   └──────────────────────────────────────┘
   
   一条比较指令搞定，无需逐个比较!

2. 正值按代际递增:
   Young(1) → Old(2)
   
   代际转换只需简单递增，便于索引数组

3. 负值用于特殊情况:
   Humongous(-1) 需要特殊的引用处理和急切回收
```

---

## 3. _in_cset_fast_test - CSet快速测试数组

### 3.1 类定义

```cpp
// src/hotspot/share/gc/g1/g1InCSetState.hpp
class G1InCSetStateFastTestBiasedMappedArray : public G1BiasedMappedArray<InCSetState> {
protected:
  InCSetState default_value() const { return InCSetState::NotInCSet; }
  
public:
  void set_humongous(uintptr_t index);  // 标记为巨型区域
  void set_in_young(uintptr_t index);   // 标记为年轻代
  void set_in_old(uintptr_t index);     // 标记为老年代
  
  // 核心查询方法
  bool is_in_cset(HeapWord* addr) const;
  bool is_in_cset_or_humongous(HeapWord* addr) const;
  InCSetState at(HeapWord* addr) const;
};
```

### 3.2 初始化过程

```cpp
// src/hotspot/share/gc/g1/g1CollectedHeap.cpp:2089
_in_cset_fast_test.initialize(start, end, granularity);
// 参数: heap_start, heap_end, 4MB

// 内部调用链:
// 1. G1BiasedMappedArray::initialize()
// 2. G1BiasedMappedArrayBase::initialize()
// 3. create_new_base_array() - malloc分配内存
// 4. initialize_base() - 设置偏置参数
// 5. clear() - 初始化为 NotInCSet
```

### 3.3 O(1) 访问的实现原理

```cpp
// 核心访问方法
T get_by_address(HeapWord* value) const {
  // 步骤1: 地址右移22位，等效于除以4MB
  idx_t biased_index = ((uintptr_t)value) >> this->shift_by();
  
  // 步骤2: 直接通过偏置基地址访问
  return biased_base()[biased_index];
}
```

**数学原理**:

```
假设:
  heap_start    = 0x600000000 (24GB)
  region_size   = 0x400000    (4MB)
  对象地址       = 0x600400000 (堆中第二个区域)

传统方法 (需要减法):
  region_index = (0x600400000 - 0x600000000) / 4MB
               = 0x400000 / 4MB
               = 1

偏置数组方法 (无需减法):
  _bias         = 0x600000000 / 4MB = 0x1800 (6144)
  _biased_base  = _base - (0x1800 * 1)  // elem_size = 1字节
  
  biased_index  = 0x600400000 >> 22 = 0x1801 (6145)
  
  访问: biased_base[0x1801]
      = (_base - 0x1800)[0x1801]
      = _base[0x1801 - 0x1800]
      = _base[1]  ✓
  
  关键: 减法预先计算在 _biased_base 中，运行时只需右移和数组访问!
```

### 3.4 使用场景

```cpp
// 1. GC开始时标记CSet区域
void G1CollectedHeap::register_young_region_with_cset(HeapRegion* r) {
  _in_cset_fast_test.set_in_young(r->hrm_index());
}

void G1CollectedHeap::register_old_region_with_cset(HeapRegion* r) {
  _in_cset_fast_test.set_in_old(r->hrm_index());
}

// 2. 引用处理时快速判断
InCSetState G1CollectedHeap::in_cset_state(oop obj) {
  // O(1) 判断对象所在区域的状态
  return _in_cset_fast_test.at((HeapWord*)obj);
}

// 3. GC结束后清理
void G1CollectedHeap::clear_cset_fast_test() {
  _in_cset_fast_test.clear();
}
```

---

## 4. _humongous_reclaim_candidates - 巨型对象回收候选

### 4.1 类定义

```cpp
// src/hotspot/share/gc/g1/g1CollectedHeap.hpp:253
class HumongousReclaimCandidates : public G1BiasedMappedArray<bool> {
protected:
  bool default_value() const { return false; }
  
public:
  void set_candidate(uint region, bool value) {
    set_by_index(region, value);
  }
  
  bool is_candidate(uint region) {
    return get_by_index(region);
  }
};

// 成员变量
HumongousReclaimCandidates _humongous_reclaim_candidates;
bool _has_humongous_reclaim_candidates;  // 优化标志
```

### 4.2 巨型对象急切回收机制

```
巨型对象 (Humongous Object):
  - 大小 ≥ region_size / 2 (≥ 2MB)
  - 跨越多个连续区域
  - 传统方式只在 Full GC 时回收

急切回收 (Eager Reclaim):
  - 在 Young GC 时就尝试回收不可达的巨型对象
  - 无需等待 Full GC，提高空间利用率

回收流程:
┌────────────────────────────────────────────────────────────┐
│  1. GC开始: 标记所有巨型区域为候选                          │
│     _humongous_reclaim_candidates[region] = true           │
│                                                            │
│  2. 引用遍历: 发现被引用的巨型对象，移除候选标记            │
│     _humongous_reclaim_candidates[region] = false          │
│                                                            │
│  3. GC结束: 仍为true的区域可以立即回收                      │
│     for (region in candidates)                             │
│       if (is_candidate(region)) free_humongous_region()    │
└────────────────────────────────────────────────────────────┘
```

### 4.3 优化标志

```cpp
// _has_humongous_reclaim_candidates 的作用
bool _has_humongous_reclaim_candidates;

// 如果没有任何巨型对象候选，可以跳过整个回收流程
if (!_has_humongous_reclaim_candidates) {
  // 跳过巨型对象回收相关的处理
  return;
}
```

---

## 5. 内存占用分析

### 5.1 _in_cset_fast_test

```
元素类型: InCSetState (int8_t, 1字节)
数组长度: 2048 (8GB / 4MB)
总内存: 2048 * 1 = 2KB

加上管理结构:
  G1BiasedMappedArrayBase: ~40字节
  
总计: ~2KB
```

### 5.2 _humongous_reclaim_candidates

```
元素类型: bool (1字节)
数组长度: 2048
总内存: 2048 * 1 = 2KB

总计: ~2KB
```

### 5.3 总内存开销

```
┌─────────────────────────────────────────────────────────────┐
│  快速测试数组总内存开销                                      │
├─────────────────────────────────────────────────────────────┤
│  _in_cset_fast_test:            ~2KB                        │
│  _humongous_reclaim_candidates: ~2KB                        │
│  管理结构开销:                  ~100字节                    │
├─────────────────────────────────────────────────────────────┤
│  总计:                          ~4KB                        │
│  占堆比例:                      4KB / 8GB ≈ 0.00005%       │
└─────────────────────────────────────────────────────────────┘

用 4KB 内存换取 O(1) 查询，性价比极高!
```

---

## 6. 性能对比

### 6.1 CSet 查询对比

```
传统链表遍历:
  - 时间复杂度: O(n)，n = CSet中的区域数
  - Young GC 典型CSet大小: 200-500个区域
  - 每次查询: 需要遍历链表，多次内存访问
  
偏置数组:
  - 时间复杂度: O(1)
  - 操作: 1次右移 + 1次数组访问
  - 无分支预测失败风险

性能提升:
  假设每次GC需要判断100万个引用:
  
  链表遍历: 100万 × 平均遍历150个节点 = 1.5亿次比较
  偏置数组: 100万 × 2次操作 = 200万次操作
  
  提升倍数: 75倍!
```

### 6.2 汇编级别分析

```asm
# 偏置数组访问 (O(1))
# 假设: 对象地址在 rdi, biased_base 在 rsi
mov    rax, rdi           # rax = 对象地址
shr    rax, 22            # rax = biased_index (右移22位)
movzx  eax, BYTE [rsi+rax]# 访问 biased_base[index]

# 仅 3 条指令，无分支，缓存友好
```

---

## 7. GDB 验证

### 7.1 查看 _in_cset_fast_test 结构

```gdb
# 获取 G1CollectedHeap 实例
(gdb) p _g1_heap
$1 = (G1CollectedHeap *) 0x7f8a8c010000

# 查看 _in_cset_fast_test 字段
(gdb) p _g1_heap->_in_cset_fast_test
$2 = {
  _base = 0x7f8a8c100000,
  _length = 2048,
  _biased_base = 0x7f8a8c0fe800,  # _base - 0x1800
  _bias = 6144,                    # 0x1800
  _shift_by = 22
}

# 验证偏置计算
(gdb) p/x (0x7f8a8c100000 - 6144)
$3 = 0x7f8a8c0fe800  ✓ (与 _biased_base 一致)
```

### 7.2 验证 O(1) 访问

```gdb
# 假设测试对象在第二个区域
(gdb) set $obj_addr = 0x600400000
(gdb) set $shift = 22

# 计算 biased_index
(gdb) p/x ($obj_addr >> $shift)
$4 = 0x1801  # biased_index = 6145

# 读取状态值
(gdb) p _g1_heap->_in_cset_fast_test._biased_base[0x1801]
$5 = {_value = 1}  # InCSetState::Young

# 验证: 该区域在CSet中，是年轻代区域
```

### 7.3 查看 _humongous_reclaim_candidates

```gdb
(gdb) p _g1_heap->_humongous_reclaim_candidates
$6 = {
  _base = 0x7f8a8c102000,
  _length = 2048,
  _biased_base = 0x7f8a8c100800,
  _bias = 6144,
  _shift_by = 22
}

# 检查某个区域是否是回收候选
(gdb) p _g1_heap->_humongous_reclaim_candidates.is_candidate(100)
$7 = true  # 区域100是巨型对象回收候选
```

---

## 8. 数据结构关系图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         G1CollectedHeap                                  │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │  _in_cset_fast_test (G1InCSetStateFastTestBiasedMappedArray)    │    │
│  │  ┌─────────────────────────────────────────────────────────┐    │    │
│  │  │  继承自 G1BiasedMappedArray<InCSetState>                │    │    │
│  │  │  ┌─────────────────────────────────────────────────┐    │    │    │
│  │  │  │  继承自 G1BiasedMappedArrayBase                 │    │    │    │
│  │  │  │  ┌─────────────────────────────────────────┐    │    │    │    │
│  │  │  │  │  _base         : address               │    │    │    │    │
│  │  │  │  │  _length       : size_t (2048)         │    │    │    │    │
│  │  │  │  │  _biased_base  : address               │    │    │    │    │
│  │  │  │  │  _bias         : size_t (6144)         │    │    │    │    │
│  │  │  │  │  _shift_by     : uint (22)             │    │    │    │    │
│  │  │  │  └─────────────────────────────────────────┘    │    │    │    │
│  │  │  └─────────────────────────────────────────────────┘    │    │    │
│  │  └─────────────────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │  _humongous_reclaim_candidates (HumongousReclaimCandidates)     │    │
│  │  ┌─────────────────────────────────────────────────────────┐    │    │
│  │  │  继承自 G1BiasedMappedArray<bool>                       │    │    │
│  │  │  (结构同上，元素类型为bool)                             │    │    │
│  │  └─────────────────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                          │
│  _has_humongous_reclaim_candidates : bool                               │
└─────────────────────────────────────────────────────────────────────────┘

InCSetState 枚举值:
┌─────────────────────────────────────────────────────────────────────────┐
│  Humongous (-1)  │  NotInCSet (0)  │  Young (1)  │  Old (2)             │
│       ↓                  ↓               ↓            ↓                 │
│  特殊处理           默认状态         在CSet中     在CSet中              │
│  急切回收           无需处理         需要疏散     需要疏散              │
└─────────────────────────────────────────────────────────────────────────┘

O(1) 访问流程:
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│  对象地址: 0x600400000                                                   │
│       │                                                                  │
│       │ >> 22 (右移22位)                                                 │
│       ▼                                                                  │
│  biased_index: 0x1801                                                    │
│       │                                                                  │
│       │ 直接数组访问                                                     │
│       ▼                                                                  │
│  biased_base[0x1801]                                                     │
│       │                                                                  │
│       │ = (_base - 0x1800)[0x1801]                                       │
│       │ = _base[1]                                                       │
│       ▼                                                                  │
│  InCSetState: Young (1)                                                  │
│                                                                          │
│  结论: 对象在CSet中，属于年轻代区域，需要疏散                           │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 9. 关键要点总结

| 特性 | _in_cset_fast_test | _humongous_reclaim_candidates |
|------|-------------------|-------------------------------|
| 元素类型 | InCSetState (int8_t) | bool |
| 数组大小 | 2KB | 2KB |
| 用途 | O(1) 判断对象是否在CSet | O(1) 判断巨型对象可否回收 |
| 状态值 | -1/0/1/2 | true/false |
| 更新时机 | GC开始/结束 | 引用遍历过程中 |

**偏置数组的核心优化思想**:
1. 预先计算偏移量到 `_biased_base`
2. 运行时只需右移和数组访问
3. 用空间换时间，4KB 换 O(1) 查询
4. 状态值编码优化，`> 0` 即可判断是否在 CSet

---

## 相关文件

- `src/hotspot/share/gc/g1/g1BiasedArray.hpp` - 偏置数组基类
- `src/hotspot/share/gc/g1/g1InCSetState.hpp` - CSet状态和快速测试数组
- `src/hotspot/share/gc/g1/g1CollectedHeap.hpp` - HumongousReclaimCandidates定义
- `src/hotspot/share/gc/g1/g1CollectedHeap.cpp` - 初始化代码
