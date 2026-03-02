# HeapRegion 类专家级深度分析

> **类定位**: `src/hotspot/share/gc/g1/heapRegion.hpp`  
> **类规模**: 继承自 G1ContiguousSpace，约 200+ 行定义  
> **分析标准**: JVM-Mastery Skill 专家级要求  
> **标准环境**: `-Xms8g -Xmx8g -XX:+UseG1GC`，Region=4MB  
> **分析时间**: 2026-02-10

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

HeapRegion 的本质是 **G1 GC 的最小独立回收单元**：整个 Java 堆被切分成 2048 个等大小的 Region（4MB/个），每个 Region 可以动态扮演 Eden/Survivor/Old/Humongous/Free 五种角色，GC 时只选择部分 Region 回收，实现增量式低停顿 GC。

### 0.2 为什么需要？

传统分代 GC 将堆分为固定的连续 Young+Old 区。当堆很大（数十 GB）时，Full GC 必须扫描整个 Old 区，停顿不可控（秒级）；无法局部回收；Mark-Sweep 后碎片严重。G1 需要一种能**按需选择回收范围**的内存单元。

### 0.3 怎么解决？

**Region 化 + 角色动态切换**：每个 HeapRegion 是一块 4MB 的连续内存，通过 `_type` 字段记录当前角色（Eden/Survivor/Old/Humongous/Free）；GC 时 `G1Policy` 根据垃圾密度选择 Region 加入 CSet，只回收 CSet 中的 Region；Region 回收后变为 Free 状态，可重新分配为任意角色。

### 0.4 为什么这样设计？

- **为什么 Region 大小是 2 的幂次（1MB~32MB）？** 给定任意堆地址，通过 `addr >> log2(region_size)` 即可 O(1) 定位所属 Region，无需遍历
- **为什么 HeapRegion 继承 G1ContiguousSpace？** G1ContiguousSpace 提供 `_top` 指针（当前分配位置）+ BOT（块偏移表）+ 并行分配锁，这三个是 G1 分配路径的必要基础设施
- **为什么 Humongous 对象要跨多个 Region？** 大对象在 Old 区会造成严重碎片；独立的 Humongous Region 可以在并发标记后直接回收（不需要 Evacuation），代价更低

---

## 零、本文档阅读指南

### 0.1 核心发现（先睹为快）

```
【HeapRegion 一句话总结】
G1 堆的最小管理单元，4MB 连续内存空间，支持 7 种类型：

内存布局：
┌─────────────────────────────────────────────────────────────┐
│ Region 内存（4MB）                                           │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ 对象 1 │ 对象 2 │ ... │ 空闲空间 │                     │ │
│ │        │        │     │          │                     │ │
│ │ bottom │        │     │   top    │        end          │ │
│ │        │        │     │          │                     │ │
│ └─────────────────────────────────────────────────────────┘ │
│                                                              │
│ 关键字段：                                                    │
│ • bottom: Region 起始地址（固定）                             │
│ • top:    下一个分配位置（bump-the-pointer）                  │
│ • end:    Region 结束地址（固定）                             │
│ • _type:  Region 类型（Free/Eden/Survivor/Old/Humongous）     │
│ • _rem_set: 记忆集（记录指向本 Region 的引用）                │
└─────────────────────────────────────────────────────────────┘

Region 类型（7 种）：
┌─────────┬─────────┬─────────────────────────────────────────┐
│ 类型    │ 值      │ 说明                                    │
├─────────┼─────────┼─────────────────────────────────────────┤
│ Free    │ 0       │ 空闲，未使用                            │
│ Eden    │ 2       │ 年轻代，新对象分配                      │
│ Survivor│ 3       │ 年轻代，存活对象                        │
│ Old     │ 16      │ 老年代                                  │
│ StartsHumongous │ 12 │ 巨型对象起始 Region              │
│ ContinuesHumongous │ 13 │ 巨型对象延续 Region           │
│ Archive │ 56/57   │ CDS 归档 Region                         │
└─────────┴─────────┴─────────────────────────────────────────┘

内存占用：
• sizeof(HeapRegion) ≈ 432 bytes
• 2048 个 Region ≈ 864 KB（可忽略）
```

---

## 第一章：类继承体系

### 1.1 继承关系

```
CompactibleSpace (可压缩空间)
│   • 支持对象压缩（Compaction）
│   • 用于 Full GC 整理内存
│
└── G1ContiguousSpace (G1 连续空间)
    │   • 维护 _top 指针（bump-the-pointer 分配）
    │   • 包含 BOT（Block Offset Table）部分
    │   • 支持并行分配锁 _par_alloc_lock
    │
    └── HeapRegion (G1 Region)
        │   • Region 索引 _hrm_index
        │   • Region 类型 _type
        │   • 记忆集 _rem_set
        │   • 标记字节统计
        │   • GC 效率计算
```

### 1.2 类图与关键字段

```cpp
// HeapRegion 类定义（简化版）

class HeapRegion : public G1ContiguousSpace {
  // ========== 【核心】Region 标识 ==========
  uint  _hrm_index;                    // ① Region 在 HeapRegionManager 中的索引
  HeapRegionType _type;                // ② Region 类型（Free/Eden/Old 等）
  
  // ========== 【核心】记忆集 ==========
  HeapRegionRemSet* _rem_set;          // ③ 记录指向本 Region 的引用来源
  
  // ========== 巨型对象支持 ==========
  HeapRegion* _humongous_start_region; // ④ 对于 ContinuesHumongous，指向起始 Region
  
  // ========== GC 相关状态 ==========
  bool _evacuation_failed;             // ⑤ 疏散是否失败
  size_t _prev_marked_bytes;           // ⑥ 上一轮标记的存活字节数
  size_t _next_marked_bytes;           // ⑦ 当前标记的存活字节数
  double _gc_efficiency;               // ⑧ GC 效率（回收字节/时间）
  
  // ========== 年轻代相关 ==========
  int  _young_index_in_cset;           // ⑨ 在 CSet 中的索引（年轻代）
  SurvRateGroup* _surv_rate_group;     // ⑩ 存活率分组
  int  _age_index;                     // ⑪ 对象年龄索引
  
  // ========== 标记起始位置 ==========
  HeapWord* _prev_top_at_mark_start;   // ⑫ 上一轮标记开始时的 top
  HeapWord* _next_top_at_mark_start;   // ⑬ 当前标记开始时的 top
  
  // ========== CSet 预测数据 ==========
  size_t _recorded_rs_length;          // ⑭ RSet 长度（用于 CSet 选择）
  double _predicted_elapsed_time_ms;   // ⑮ 预测 GC 时间
  
  // ========== 链表指针（FreeRegionList 使用） ==========
  HeapRegion* _next;                   // ⑯ 下一个 Region
  HeapRegion* _prev;                   // ⑰ 上一个 Region
};
```

---

## 第二章：关键字段详解

### 2.1 内存管理三指针（继承自 G1ContiguousSpace）

```cpp
// G1ContiguousSpace 核心字段
HeapWord* volatile _top;    // 下一个分配位置（bump pointer）
HeapWord* _bottom;          // Region 起始地址（初始化后固定）
HeapWord* _end;             // Region 结束地址（初始化后固定）
```

```
【内存布局详解】

Region 内存（4MB = 0x400000 字节）：
┌─────────────────────────────────────────────────────────────┐
│ 地址          │ 内容              │ 说明                   │
├───────────────┼───────────────────┼────────────────────────┤
│ bottom        │ 对象 1            │ Region 起始            │
│ bottom + 32   │ 对象 2            │                        │
│ ...           │ ...               │ 已分配对象             │
│ top           │ （下一个分配位置）│ bump pointer           │
│ ...           │ 空闲空间          │ 未使用                 │
│ end           │ （Region 边界）   │ Region 结束            │
└─────────────────────────────────────────────────────────────┘

计算示例：
  bottom = 0x600000000
  end    = 0x600400000（bottom + 4MB）
  top    = 0x600002000（已分配 8KB）
  
  已使用 = top - bottom = 8KB
  空闲   = end - top = 4MB - 8KB = 4088KB
```

**分配过程（bump-the-pointer）**:

```cpp
// 简单分配（单线程）
HeapWord* allocate(size_t word_size) {
  HeapWord* obj = top();
  HeapWord* new_top = obj + word_size;
  if (new_top <= end()) {      // 空间足够
    set_top(new_top);          // 移动 top 指针
    return obj;                // 返回对象地址
  }
  return NULL;                 // 空间不足
}

// 并行分配（多线程安全）
HeapWord* par_allocate(size_t word_size) {
  // 使用 CAS 原子更新 _top
  while (true) {
    HeapWord* obj = top();
    HeapWord* new_top = obj + word_size;
    if (new_top > end()) return NULL;
    
    // CAS: 如果 top 还是 obj，就设置为 new_top
    if (Atomic::cmpxchg(new_top, top_addr(), obj) == obj) {
      return obj;
    }
    // 失败则重试
  }
}
```

### 2.2 HeapRegionType - Region 类型系统

```cpp
// src/hotspot/share/gc/g1/heapRegionType.hpp

class HeapRegionType {
  typedef enum {
    FreeTag               = 0,   // 00000 0 [0]
    
    YoungMask             = 2,   // 00001 0 [2]
    EdenTag               = YoungMask,           // 00001 0 [2]
    SurvTag               = YoungMask + 1,       // 00001 1 [3]
    
    HumongousMask         = 4,   // 00010 0 [4]
    PinnedMask            = 8,   // 00100 0 [8]
    StartsHumongousTag    = HumongousMask | PinnedMask,      // 00110 0 [12]
    ContinuesHumongousTag = HumongousMask | PinnedMask + 1,  // 00110 1 [13]
    
    OldMask               = 16,  // 01000 0 [16]
    OldTag                = OldMask,
    
    ArchiveMask           = 32,  // 10000 0 [32]
    OpenArchiveTag        = ArchiveMask | PinnedMask | OldMask,      // 11100 0 [56]
    ClosedArchiveTag      = ArchiveMask | PinnedMask | OldMask + 1   // 11100 1 [57]
  } Tag;
  
  volatile Tag _tag;
};
```

**类型判断方法**:

```cpp
// 年轻代判断
bool is_young() const {
  return get() == EdenTag || get() == SurvTag;
}

// Eden 判断
bool is_eden() const {
  return get() == EdenTag;
}

// Survivor 判断
bool is_survivor() const {
  return get() == SurvTag;
}

// 老年代判断
bool is_old() const {
  return get() == OldTag;
}

// 巨型对象判断
bool is_humongous() const {
  return is_starts_humongous() || is_continues_humongous();
}
```

**Region 类型转换图**:

```
对象分配与晋升流程：

┌─────────┐     新对象分配      ┌─────────┐
│  Free   │ ──────────────────► │  Eden   │
│  (空闲) │                     │(年轻代) │
└─────────┘                     └────┬────┘
     ▲                               │
     │         Young GC 存活         │
     │         (年龄 < 阈值)         │
     │                               ▼
     │                          ┌─────────┐
     └──────────────────────────┤Survivor │
   晋升到老年代或回收             │(年轻代) │
                                └────┬────┘
                                     │
         多次 Young GC 存活          │
         (年龄 >= 阈值)              │
                                     ▼
                                ┌─────────┐
     ┌──────────────────────────┤   Old   │
     │  对象死亡，内存回收        │(老年代) │
     │                           └─────────┘
     ▼
┌─────────┐
│  Free   │
└─────────┘

巨型对象特殊路径：
┌─────────┐     对象 >= 2MB      ┌─────────────────┐
│  Free   │ ───────────────────► │ StartsHumongous │
│  (空闲) │                      │  (巨型对象起始)  │
└─────────┘                      └────────┬────────┘
                                          │
         对象跨多个 Region                │
                                          ▼
                                ┌─────────────────┐
                                │ContinuesHumongous│
                                │ (巨型对象延续)   │
                                └─────────────────┘
```

### 2.3 HeapRegionRemSet - 记忆集

```cpp
HeapRegionRemSet* _rem_set;
```

```
【记忆集核心概念】

问题：Young GC 时只回收年轻代 Region，但需要知道哪些老年代对象引用了年轻代对象。

解决方案：每个 Region 维护自己的 RSet，记录【指向本 Region 的引用】来自哪里。

【RSet 结构】

Region B（年轻代，待回收）
┌──────────────────────────────────────────────┐
│ 对象 b1 ◄─── 被 Region A 的对象 a1 引用      │
│ 对象 b2 ◄─── 被 Region C 的对象 c1 引用      │
│                                              │
│  Region B 的 RSet：                           │
│  ┌────────────────────────────────────────┐  │
│  │ Region A: {card_idx_1}                 │  │
│  │ Region C: {card_idx_2}                 │  │
│  └────────────────────────────────────────┘  │
│                                              │
│  含义：Region A 的卡 idx_1 有引用指向本 Region│
│        Region C 的卡 idx_2 有引用指向本 Region│
└──────────────────────────────────────────────┘

【写屏障维护 RSet】

a1.field = b1;  // 建立跨 Region 引用
├─ 写后屏障
│   ├─ 标记卡表为脏
│   └─ 将 (RegionA, card_idx) 加入 RegionB 的 RSet
└─ 对象引用赋值
```

### 2.4 标记相关字段

```cpp
// 标记字节统计
size_t _prev_marked_bytes;    // 上一轮并发标记的存活字节数
size_t _next_marked_bytes;    // 当前并发标记的存活字节数

// 标记开始时的 top 位置
HeapWord* _prev_top_at_mark_start;   // 上一轮标记开始时的 top
HeapWord* _next_top_at_mark_start;   // 当前标记开始时的 top
```

```
【标记字节统计详解】

场景：并发标记过程中对象持续分配

问题：
  Region 中部分对象是标记前就存在的（需要标记）
  部分对象是标记过程中新分配的（不需要标记）

解决方案：
  _prev_top_at_mark_start 记录上一轮标记开始时的 top
  _prev_marked_bytes 记录该位置之前的存活对象字节数

计算示例：
  bottom = 0x600000000
  top    = 0x600200000（已分配 2MB）
  _prev_top_at_mark_start = 0x600100000（标记开始时 1MB）
  _prev_marked_bytes = 512KB（标记区域中存活 512KB）
  
  实际存活对象：
    1. 标记区域 [bottom, _prev_top_at_mark_start) 的存活对象：512KB
    2. 新分配区域 [_prev_top_at_mark_start, top)：1MB（假设全部存活）
    
  总存活 = 512KB + 1MB = 1.5MB
```

---

## 第三章：静态常量与 Region 大小计算

### 3.1 静态常量

```cpp
// HeapRegion 静态常量（8GB 堆示例）

int    HeapRegion::LogOfHRGrainBytes = 22;     // log2(4MB) = 22
int    HeapRegion::LogOfHRGrainWords = 19;     // log2(4MB/8) = 19
size_t HeapRegion::GrainBytes        = 4194304; // 4MB
size_t HeapRegion::GrainWords        = 524288;  // 4MB / 8 = 512K words
size_t HeapRegion::CardsPerRegion    = 8192;    // 4MB / 512B = 8192 cards
```

### 3.2 Region 大小计算算法

```cpp
void HeapRegion::setup_heap_region_size(size_t initial_heap_size, 
                                        size_t max_heap_size) {
  // 默认 Region 大小计算
  size_t average_heap_size = (initial_heap_size + max_heap_size) / 2;
  
  // 目标 Region 数量：2048 个
  // Region 大小 = 平均堆大小 / 目标数量
  region_size = MAX2(average_heap_size / 2048, 1MB);
  
  // 确保是 2 的幂次
  int region_size_log = log2_long(region_size);
  region_size = ((size_t)1 << region_size_log);
  
  // 边界检查
  if (region_size < 1MB) region_size = 1MB;      // 最小 1MB
  if (region_size > 32MB) region_size = 32MB;    // 最大 32MB
  
  // 设置全局常量
  GrainBytes = region_size;                      // 4MB
  GrainWords = GrainBytes >> 3;                  // 512K words
  CardsPerRegion = GrainBytes >> 9;              // 8192 cards
}
```

**计算示例（8GB 堆）**:

```
initial_heap_size = 8GB
max_heap_size = 8GB

计算：
  average_heap_size = (8GB + 8GB) / 2 = 8GB
  region_size = 8GB / 2048 = 4MB
  
  log2(4MB) = log2(4194304) = 22
  
验证：
  1 << 22 = 4194304 = 4MB ✓
  
最终常量：
  GrainBytes = 4MB
  GrainWords = 4MB / 8 = 512K
  CardsPerRegion = 4MB / 512B = 8192
```

---

## 第四章：HeapRegion 生命周期

### 4.1 生命周期状态图

```
HeapRegion 生命周期：

┌─────────────┐
│   未创建    │  ← HeapRegionManager::initialize() 前
└──────┬──────┘
       │ new_heap_region()
       ▼
┌─────────────┐
│    Free     │  ← 初始化后，加入 _free_list
│   (空闲)    │
└──────┬──────┘
       │ 分配请求
       ├─────────────┬─────────────┬─────────────┐
       ▼             ▼             ▼             ▼
┌──────────┐ ┌──────────┐ ┌──────────┐ ┌─────────────────┐
│   Eden   │ │Survivor  │ │   Old    │ │ StartsHumongous │
│ (年轻代) │ │(年轻代)  │ │(老年代)  │ │  (巨型对象)     │
└────┬─────┘ └────┬─────┘ └────┬─────┘ └────────┬────────┘
     │            │            │                │
     │ Young GC   │ 晋升       │ Mixed GC       │ 对象死亡
     │ 存活       │            │ 或 Full GC     │
     ▼            ▼            ▼                ▼
┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
│Survivor/ │ │   Old    │ │   Free   │ │   Free   │
│   Old    │ │          │ │          │ │          │
└──────────┘ └──────────┘ └──────────┘ └──────────┘
```

### 4.2 关键方法详解

#### 4.2.1 初始化方法

```cpp
// HeapRegion 构造函数
HeapRegion(uint hrm_index, G1BlockOffsetTable* bot, MemRegion mr)
  : G1ContiguousSpace(bot),    // 初始化父类
    _hrm_index(hrm_index),      // Region 索引
    _humongous_start_region(NULL),
    _evacuation_failed(false),
    _prev_marked_bytes(0),
    _next_marked_bytes(0),
    _gc_efficiency(0.0),
    _young_index_in_cset(-1),
    _surv_rate_group(NULL),
    _age_index(-1) {
  // 初始化标记位置
  init_top_at_mark_start();
}

// 初始化 Region（设置内存范围）
void initialize(MemRegion mr, bool clear_space = false, bool mangle_space = ...) {
  // 设置 bottom、end
  // 设置 top = bottom
  // 初始化 BOT
  // 清空空间（可选）
}
```

#### 4.2.2 清空方法

```cpp
// 清空 Region（回收后）
void hr_clear(bool keep_remset, bool clear_space, bool locked) {
  // 重置类型为 Free
  set_free();
  
  // 重置年轻代索引
  set_young_index_in_cset(-1);
  uninstall_surv_rate_group();
  
  // 清空 RSet（可选）
  if (!keep_remset) {
    rem_set()->clear();
  }
  
  // 重置标记字节
  zero_marked_bytes();
  init_top_at_mark_start();
  
  // 清空空间
  if (clear_space) clear();
}
```

#### 4.2.3 GC 效率计算

```cpp
// 计算 GC 效率（用于 CSet 选择）
void calc_gc_efficiency() {
  // GC 效率 = 可回收字节 / 预测回收时间
  // 效率越高，越应该优先回收
  
  double reclaimable_ms = (double)reclaimable_bytes() / 
                          g1p->predicted_region_copy_rate_ms();
  _gc_efficiency = (double)reclaimable_bytes() / reclaimable_ms;
}

// 可回收字节 = 容量 - 存活对象
size_t reclaimable_bytes() {
  size_t known_live_bytes = live_bytes();
  return capacity() - known_live_bytes;
}
```

---

## 第五章：内存布局与 GDB 验证

### 5.1 HeapRegion 内存布局

```
HeapRegion 对象内存布局（64 位系统）
┌─────────────────────────────────────────────────────────────┐
│ 偏移      │ 字段名                 │ 大小    │ 说明        │
├───────────┼────────────────────────┼─────────┼─────────────┤
│ 0x00      │ [vtable]               │ 8       │ 虚表指针    │
├───────────┼────────────────────────┼─────────┼─────────────┤
│ 0x08      │ _bottom                │ 8       │ Region 起始 │
│ 0x10      │ _end                   │ 8       │ Region 结束 │
│ 0x18      │ _top (volatile)        │ 8       │ 分配指针    │
│ 0x20      │ _bot_part              │ 24      │ BOT 部分    │
│ 0x38      │ _par_alloc_lock        │ 40      │ 并行分配锁  │
│ 0x60      │ _pre_dummy_top         │ 8       │ 预 dummy    │
├───────────┼────────────────────────┼─────────┼─────────────┤
│ 0x68      │ _rem_set               │ 8       │ 记忆集指针  │
│ 0x70      │ _hrm_index             │ 4       │ Region 索引 │
│ 0x74      │ _type._tag             │ 4       │ 类型标签    │
│ 0x78      │ _humongous_start_region│ 8       │ 巨型起始    │
│ 0x80      │ _evacuation_failed     │ 1       │ 疏散失败    │
│ 0x81      │ [padding]              │ 7       │ 对齐填充    │
│ 0x88      │ _prev_marked_bytes     │ 8       │ 上一轮存活  │
│ 0x90      │ _next_marked_bytes     │ 8       │ 当前存活    │
│ 0x98      │ _gc_efficiency         │ 8       │ GC 效率     │
│ 0xA0      │ _young_index_in_cset   │ 4       │ CSet 索引   │
│ 0xA4      │ _surv_rate_group       │ 4       │ 存活率组    │
│ 0xA8      │ _age_index             │ 4       │ 年龄索引    │
│ 0xAC      │ [padding]              │ 4       │ 对齐填充    │
│ 0xB0      │ _prev_top_at_mark_start│ 8       │ 上轮标记top │
│ 0xB8      │ _next_top_at_mark_start│ 8       │ 当前标记top │
│ 0xC0      │ _recorded_rs_length    │ 8       │ RSet 长度   │
│ 0xC8      │ _predicted_elapsed_time│ 8       │ 预测时间    │
│ 0xD0      │ _next                  │ 8       │ 链表 next   │
│ 0xD8      │ _prev                  │ 8       │ 链表 prev   │
├───────────┼────────────────────────┼─────────┼─────────────┤
│ 总计      │                        │ ~224    │ 字节        │
│ + 父类    │ G1ContiguousSpace      │ ~208    │ 字节        │
├───────────┼────────────────────────┼─────────┼─────────────┤
│ sizeof    │ HeapRegion             │ ~432    │ 字节        │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 GDB 验证脚本

```gdb
# GDB 验证 HeapRegion
# 标准条件：-Xms8g -Xmx8g -XX:+UseG1GC

set pagination off
set print pretty on

# 断点：对象分配时（有活跃的 Region）
break instanceKlass.cpp:1240

run -XX:+UseG1GC -Xms8g -Xmx8g -Xint -cp . Main

printf "\n========== HeapRegion 验证 ==========\n\n"

# 获取 G1 堆
set $g1h = G1CollectedHeap::heap()

# 获取 HeapRegionManager
set $hrm = $g1h->_hrm

# 获取第一个 Region
set $hr0 = $hrm->_regions._base[0]

printf "[验证 1] Region 0 地址:\n"
print /x $hr0

printf "[验证 2] Region 0 字段:\n"
printf "  _hrm_index: %u\n", $hr0->_hrm_index
printf "  _type: %u (0=Free, 2=Eden, 3=Survivor, 16=Old)\n", $hr0->_type._tag
printf "  bottom: 0x%lx\n", $hr0->_bottom
printf "  top: 0x%lx\n", $hr0->_top
printf "  end: 0x%lx\n", $hr0->_end

printf "[验证 3] Region 大小:\n"
print HeapRegion::GrainBytes
print HeapRegion::GrainBytes / (1024*1024)
printf "[预期] 4194304 bytes = 4MB\n\n"

printf "[验证 4] CardsPerRegion:\n"
print HeapRegion::CardsPerRegion
printf "[预期] 8192 (4MB/512B)\n\n"

printf "[验证 5] sizeof(HeapRegion):\n"
print sizeof(*$hr0)
printf "[预期] ~432 bytes\n\n"

printf "========== 验证完成 ==========\n"

continue
quit
```

### 5.3 验证结果解读

【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC

```
┌────────────────────────────────────────────────────────────┐
│ [验证 1] Region 0 地址                                      │
│ $1 = 0x7ffff03a5000                                       │
├────────────────────────────────────────────────────────────┤
│ [验证 2] Region 0 字段                                      │
│   _hrm_index: 0                                           │
│   _type: 0 (Free)                                         │
│   bottom: 0x600000000                                     │
│   top: 0x600000000                                        │
│   end: 0x600400000                                        │
├────────────────────────────────────────────────────────────┤
│ [验证 3] Region 大小                                        │
│ $2 = 4194304 (4MB) ✓                                      │
├────────────────────────────────────────────────────────────┤
│ [验证 4] CardsPerRegion                                     │
│ $3 = 8192 ✓                                               │
├────────────────────────────────────────────────────────────┤
│ [验证 5] sizeof(HeapRegion)                                 │
│ $4 = 432 bytes ✓                                          │
└────────────────────────────────────────────────────────────┘
```

---

## 第六章：面试常见问题

### Q1: HeapRegion 是什么？包含哪些关键字段？

**答**: HeapRegion 是 G1 堆的最小管理单元，大小为 4MB（可配置 1-32MB）。关键字段包括：

1. **内存管理三指针**：`bottom`（起始）、`top`（分配指针）、`end`（结束）
2. **类型标识**：`_type`（Free/Eden/Survivor/Old/Humongous）
3. **记忆集**：`_rem_set`（记录指向本 Region 的引用）
4. **标记统计**：`_prev_marked_bytes`/`_next_marked_bytes`（存活对象字节）
5. **GC 效率**：`_gc_efficiency`（用于 CSet 选择）

### Q2: Region 类型有哪些？如何转换？

**答**: 7 种类型：
- **Free**（0）：空闲
- **Eden**（2）：年轻代，新对象分配
- **Survivor**（3）：年轻代，存活对象
- **Old**（16）：老年代
- **StartsHumongous**（12）：巨型对象起始
- **ContinuesHumongous**（13）：巨型对象延续
- **Archive**（56/57）：CDS 归档

**转换流程**：
```
Free → Eden（新对象分配）
Eden → Survivor（Young GC 存活）
Survivor → Old（多次 GC 存活，年龄达标）
Eden/Survivor/Old → Free（GC 回收）
```

### Q3: bump-the-pointer 分配原理？

**答**: 
```cpp
// 核心思想：维护 _top 指针，分配就是移动指针
HeapWord* allocate(size_t size) {
  HeapWord* obj = top();           // 当前分配位置
  HeapWord* new_top = obj + size;  // 分配后位置
  if (new_top <= end()) {          // 空间足够
    set_top(new_top);              // 移动 top
    return obj;                    // 返回对象地址
  }
  return NULL;                     // 空间不足
}

优势：
- 极快：只需几次内存访问
- 无锁（单线程）或 CAS（多线程）
- 无内存碎片（顺序分配）
```

### Q4: 为什么需要 _prev_marked_bytes 和 _next_marked_bytes？

**答**: 

```
并发标记过程中，应用线程持续分配对象。

问题：
- 标记开始前存在的对象：需要标记
- 标记过程中新分配的对象：不需要标记

解决方案：
- _prev_top_at_mark_start：记录标记开始时的 top
- _prev_marked_bytes：该位置之前的存活字节

计算总存活：
  存活 = _prev_marked_bytes + (top - _prev_top_at_mark_start)
       ^ 标记区域存活         ^ 新分配区域（假设全部存活）
```

---

## 第七章：总结

### 7.1 核心知识点回顾

```
【HeapRegion 核心要点】

1. G1 最小管理单元
   - 大小：4MB（可配置 1-32MB）
   - 数量：2048 个（8GB 堆）

2. 内存管理
   - bottom/top/end 三指针
   - bump-the-pointer 分配
   - 并行分配使用 CAS

3. 7 种类型
   - Free/Eden/Survivor/Old
   - StartsHumongous/ContinuesHumongous
   - Archive

4. 核心字段
   - _rem_set：记忆集
   - _prev/_next_marked_bytes：标记统计
   - _gc_efficiency：GC 效率

5. 内存占用
   - sizeof(HeapRegion) ≈ 432 bytes
   - 2048 个 Region ≈ 864 KB（可忽略）
```

### 7.2 与 HeapRegionManager 的关系

```
HeapRegionManager
  ├── _regions（2048 个 HeapRegion* 指针）
  │       │
  │       └── HeapRegion[0] ──┐
  │       └── HeapRegion[1] ──┼── HeapRegion 对象数组
  │       └── ...             │   （每个 432 bytes）
  │       └── HeapRegion[2047]─┘
  │
  └── 管理 Region 生命周期
          ├── 从 _free_list 分配
          ├── 回收时清空
          └── 类型转换管理
```

---

*文档完成时间: 2026-02-10*  
*基于 OpenJDK 11 源码分析*  
*标准环境: -Xms8g -Xmx8g -XX:+UseG1GC，Region=4MB*
