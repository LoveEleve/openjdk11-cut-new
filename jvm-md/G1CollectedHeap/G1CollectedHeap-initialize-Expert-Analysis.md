# G1CollectedHeap::initialize() 专家级深度分析

> **方法定位**: `src/hotspot/share/gc/g1/g1CollectedHeap.cpp:1587`  
> **方法规模**: 约 400 行源码（L1587-L2445）  
> **分析标准**: JVM-Mastery Skill 专家级要求  
> **标准环境**: `-Xms8g -Xmx8g -XX:+UseG1GC`，Region=4MB，共 2048 Regions  
> **分析时间**: 2026-02-10

---

## 零、本文档阅读指南

### 0.1 文档结构（按 Skill 模式 2 要求）

| 章节 | 内容 | 必读性 |
|------|------|--------|
| 第一章 | 宏观架构与设计哲学 | ⭐⭐⭐⭐⭐ |
| 第二章 | 类继承体系与整体结构 | ⭐⭐⭐⭐⭐ |
| 第三章 | 关键字段详解（含内存布局） | ⭐⭐⭐⭐⭐ |
| 第四章 | 六大数据结构映射器深度剖析 | ⭐⭐⭐⭐⭐ |
| 第五章 | 核心子系统初始化流程 | ⭐⭐⭐⭐⭐ |
| 第六章 | GDB 验证与数据解读 | ⭐⭐⭐⭐⭐ |
| 第七章 | 性能分析与调优建议 | ⭐⭐⭐⭐ |
| 第八章 | 常见问题与面试真题 | ⭐⭐⭐⭐⭐ |

### 0.2 核心发现（先睹为快）

```
【G1CollectedHeap::initialize() 一句话总结】
建立完整的 G1 内存管理体系，包括：
1. 8GB 虚拟内存预留（mmap PROT_NONE）
2. 六大数据结构映射器（堆内存、BOT、卡表、位图×2、卡计数表）
3. 2048 个 HeapRegion 初始化
4. 卡表、屏障集、热卡缓存创建
5. 并发标记双缓冲位图（128MB×2=256MB）
6. 记忆集（RSet）系统初始化
7. CSet 快速测试数组（2048 字节 O(1)判断）
```

### 0.3 三层内存管理架构（核心概念）

```
┌─────────────────────────────────────────────────────────────────┐
│                    G1 三层内存管理架构                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────┐    ┌──────────────────┐                   │
│  │   MemRegion     │    │  ReservedSpace   │                   │
│  │ 轻量级描述符     │◄──►│ 虚拟内存管理者    │                   │
│  │ • _start        │    │ • _base          │                   │
│  │ • _word_size    │    │ • _size          │                   │
│  │ 仅描述范围       │    │ 管理生命周期      │                   │
│  │ 全 JVM 通用      │    │ 两阶段分配策略    │                   │
│  └─────────────────┘    └──────────────────┘                   │
│           │                       │                            │
│           └───────────┬───────────┘                            │
│                       ▼                                        │
│  ┌─────────────────────────────────────────────────────┐      │
│  │     G1RegionToSpaceMapper (物理内存管理者)           │      │
│  │  • 管理虚拟地址到物理内存的映射                       │      │
│  │  • 提交/取消提交内存页                                │      │
│  │  • 6 个专用映射器（堆、BOT、卡表、位图×2、卡计数表）  │      │
│  └─────────────────────────────────────────────────────┘      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 第一章：宏观架构与设计哲学

### 1.1 设计哲学：G1 要解决什么核心问题？

#### 问题背景

传统 GC（Serial/Parallel/CMS）的痛点：

```
传统堆内存模型：
┌──────────────────────────────────────────────┐
│              堆内存（连续）                    │
│  ┌──────────────┬──────────────┬──────────┐  │
│  │   Young Gen  │     Old Gen  │  Perm    │  │
│  │   (年轻代)   │    (老年代)  │ (永久代) │  │
│  └──────────────┴──────────────┴──────────┘  │
│                                               │
│  问题 1: 整代回收                              │
│    - Young GC 回收整个年轻代                   │
│    - Full GC 回收整个堆                        │
│    - 无法做到"部分回收"                        │
│                                               │
│  问题 2: 停顿时间不可预测                      │
│    - 堆越大，Full GC 时间越长                  │
│    - 无法控制在 100ms 内                       │
│                                               │
│  问题 3: 内存碎片                              │
│    - 标记-清除算法产生碎片                     │
│    - 可能导致无法分配大对象                    │
└──────────────────────────────────────────────┘
```

#### G1 的创新解决方案

```
G1 Region 化内存模型：
┌──────────────────────────────────────────────┐
│              G1 堆（2048 个 Region）          │
│  ┌────┬────┬────┬────┬────┬────┬────┬────┐  │
│  │ E  │ S  │ S  │ O  │ O  │ H  │ E  │ O  │  │
│  │ E  │ E  │ E  │ O  │ O  │ H  │ E  │ E  │  │
│  │ E  │ E  │ S  │ O  │ O  │ H  │ S  │ O  │  │
│  └────┴────┴────┴────┴────┴────┴────┴────┘  │
│                                               │
│  E = Eden（年轻代，新对象分配）                │
│  S = Survivor（年轻代，存活对象）              │
│  O = Old（老年代）                            │
│  H = Humongous（巨型对象，跨多个 Region）      │
│                                               │
│  关键创新：                                    │
│  1. 逻辑分代，物理不分代                       │
│     - 每个 Region 可充当不同代的角色           │
│     - 支持增量回收（只回收部分 Region）        │
│                                               │
│  2. 可预测停顿时间                             │
│     - 用户设定目标：-XX:MaxGCPauseMillis=200   │
│     - G1 根据目标选择回收多少 Region           │
│                                               │
│  3. 内存整理（Evacuation）                     │
│     - 复制存活对象到新 Region                  │
│     - 不会产生内存碎片                         │
└──────────────────────────────────────────────┘
```

### 1.2 G1 GC 核心组件全景图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         G1CollectedHeap                                  │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                        核心管理组件                              │   │
│  │  ┌────────────────┐  ┌────────────────┐  ┌──────────────────┐   │   │
│  │  │ HeapRegionManager│  │  G1Policy      │  │ G1ConcurrentMark │   │   │
│  │  │  (Region 管理)   │  │  (策略决策)    │  │  (并发标记)      │   │   │
│  │  │  • _regions[2048]│  │  • CSet 选择   │  │  • 双缓冲位图    │   │   │
│  │  │  • 分配/回收     │  │  • 停顿预测    │  │  • SATB 队列    │   │   │
│  │  └────────────────┘  └────────────────┘  └──────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                        屏障与追踪组件                            │   │
│  │  ┌────────────────┐  ┌────────────────┐  ┌──────────────────┐   │   │
│  │  │ G1BarrierSet   │  │ G1CardTable    │  │ G1HotCardCache   │   │   │
│  │  │  (屏障集)      │  │  (卡表)        │  │  (热卡缓存)      │   │   │
│  │  │  • 写前屏障    │  │  • 512B/card   │  │  • 延迟处理      │   │   │
│  │  │  • 写后屏障    │  │  • 16MB(8GB堆) │  │  • 减少重复工作  │   │   │
│  │  └────────────────┘  └────────────────┘  └──────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                        记忆集系统                                │   │
│  │  ┌────────────────┐  ┌────────────────┐  ┌──────────────────┐   │   │
│  │  │ G1RemSet       │  │ G1HeapRegionRemSet│  │ OtherRegionsTable│  │   │
│  │  │  (全局记忆集)  │  │  (Region 级)   │  │  (稀疏/密集表)   │   │   │
│  │  │  • 协调 RSet   │  │  • 入站引用    │  │  • 记录引用来源  │   │   │
│  │  │  • 脏卡处理    │  │  • 快速查询    │  │  • 三种存储格式  │   │   │
│  │  └────────────────┘  └────────────────┘  └──────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                        辅助数据结构                              │   │
│  │  ┌────────────────┐  ┌────────────────┐  ┌──────────────────┐   │   │
│  │  │ G1BlockOffsetTable│  │ CSetFastTest   │  │ HumongousReclaim │  │   │
│  │  │  (BOT)         │  │  (CSet 快查)   │  │  (巨型对象回收)  │   │   │
│  │  │  • 对象定位    │  │  • O(1)判断    │  │  • 快速回收      │   │   │
│  │  │  • 16MB(8GB堆) │  │  • 2048 字节   │  │  • typeArray     │   │   │
│  │  └────────────────┘  └────────────────┘  └──────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.3 G1 GC 阶段切换流程

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                       G1 GC 阶段切换流程（JVM 运行时）                             │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   ═══════════════════════ Young-Only Phase ════════════════════════              │
│   │                                                                              │
│   │  [Young GC]    [Young GC]    [Young GC]    ...                              │
│   │     ↓             ↓             ↓                                            │
│   │   Normal        Normal        Normal                                         │
│   │  (普通 Young)   (普通 Young)   (普通 Young)                                   │
│   │                                                                              │
│   │  老年代占用逐渐增加... → 超过 IHOP 阈值（默认 45%）                            │
│   │                                                                              │
│   │     ↓                                                                        │
│   │  [Young GC + Initial Mark]  ← 并发标记开始（Initial Mark 搭载 Young GC）       │
│   │     ↓                                                                        │
│   │  ════════════════ Concurrent Marking（并发标记阶段）════════════════          │
│   │  │                                                                           │
│   │  │  [Young GC]    [Young GC]    ...  （并发标记与 Young GC 并行）              │
│   │  │     ↓             ↓                                                      │
│   │  │   DuringMark    DuringMark                                                │
│   │  │                                                                           │
│   │  │  Remark (STW) → Cleanup (STW)  ← 并发标记完成                              │
│   │  │     ↓                                                                     │
│   │  ═══════════════════════════════════════════════════════════                │
│   │                                                                              │
│   │  [Young GC (Prepare Mixed)]  ← 最后一次纯 Young GC                           │
│   │     ↓                                                                        │
│   ════════════════════════════════════════════════════════════════              │
│                                                                                  │
│   ═══════════════════════ Space Reclamation Phase ════════════════════           │
│   │                                                                              │
│   │  [Mixed GC]    [Mixed GC]    [Mixed GC]    ...                              │
│   │     ↓             ↓             ↓                                            │
│   │  年轻代+Old     年轻代+Old     年轻代+Old                                     │
│   │  (部分老年代)   (部分老年代)   (部分老年代)                                   │
│   │                                                                              │
│   │  可回收空间 < 5% 阈值？ → 结束，回到 Young-Only Phase                          │
│   │                                                                              │
│   ════════════════════════════════════════════════════════════════              │
│                                                                                  │
│   循环往复...                                                                    │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 第二章：类继承体系与整体结构

### 2.1 类继承关系

```
CollectedHeap (抽象基类)
│   定义堆的通用接口
│   • reserved_region()    // 预留区域
│   • max_tlab_size()      // TLAB 最大尺寸
│   • collect()            // 触发 GC
│   • obj_allocate()       // 对象分配
│
└── G1CollectedHeap (G1 实现)
    │   400+ 行 initialize()
    │   完整 G1 内存管理体系
    │
    ├── 核心管理组件
    │   ├── HeapRegionManager _hrm         // Region 管理
    │   ├── G1Policy _policy               // 策略决策
    │   └── G1ConcurrentMark _cm           // 并发标记
    │
    ├── 屏障与追踪
    │   ├── G1BarrierSet* _barrier_set     // 屏障集
    │   ├── G1CardTable* _card_table       // 卡表
    │   └── G1HotCardCache* _hot_card_cache // 热卡缓存
    │
    ├── 记忆集系统
    │   ├── G1RemSet* _g1_rem_set          // 全局记忆集
    │   └── (每个 Region 有自己的 G1HeapRegionRemSet)
    │
    └── 辅助数据结构
        ├── G1BlockOffsetTable* _bot       // 块偏移表
        ├── CSetFastTest _in_cset_fast_test // CSet 快查
        └── HumongousReclaimCandidates _humongous_reclaim_candidates
```

### 2.2 G1CollectedHeap 类定义（关键字段预览）

```cpp
// src/hotspot/share/gc/g1/g1CollectedHeap.hpp

class G1CollectedHeap : public CollectedHeap {
  friend class VMStructs;
  
  // ========== 核心管理组件 ==========
  HeapRegionManager _hrm;                    // ① Region 管理器（核心！）
  G1Allocator _allocator;                    // ② 分配器
  G1Policy _policy;                          // ③ 策略决策器
  G1ConcurrentMark _cm;                      // ④ 并发标记器
  
  // ========== 屏障与追踪 ==========
  G1BarrierSet* _barrier_set;                // ⑤ 屏障集
  G1CardTable* _card_table;                  // ⑥ 卡表
  G1HotCardCache* _hot_card_cache;           // ⑦ 热卡缓存
  
  // ========== 记忆集系统 ==========
  G1RemSet* _g1_rem_set;                     // ⑧ 全局记忆集
  
  // ========== 辅助数据结构 ==========
  G1BlockOffsetTable* _bot;                  // ⑨ 块偏移表
  CSetFastTest _in_cset_fast_test;           // ⑩ CSet 快查数组
  HumongousReclaimCandidates _humongous_reclaim_candidates; // ⑪ 巨型对象回收候选
  
  // ... 其他字段省略
};
```

---

## 第三章：initialize() 方法逐段详解

### 3.1 方法签名与入口检查（L1587-L1609）

```cpp
jint G1CollectedHeap::initialize() {
    os::enable_vtime();                      // 启用虚拟时间统计
    
    MutexLocker x(Heap_lock);                // 加锁保护堆初始化
    
    // 不变量检查：HeapWordSize 必须等于 wordSize
    guarantee(HeapWordSize == wordSize, "HeapWordSize must equal wordSize");
    
    // 获取堆大小参数
    size_t init_byte_size = collector_policy()->initial_heap_byte_size();  // -Xms
    size_t max_byte_size  = collector_policy()->max_heap_byte_size();      // -Xmx
    size_t heap_alignment = collector_policy()->heap_alignment();          // 对齐
    
    // 对齐检查：必须按 Region 大小对齐
    Universe::check_alignment(init_byte_size, HeapRegion::GrainBytes, "g1 heap");
    Universe::check_alignment(max_byte_size,  HeapRegion::GrainBytes, "g1 heap");
    Universe::check_alignment(max_byte_size,  heap_alignment, "g1 heap");
```

**关键常量（8GB 堆）**:
```
init_byte_size = max_byte_size = 8,589,934,592 bytes (8GB)
heap_alignment = 4,194,304 bytes (4MB = Region 大小)

对齐验证：
- 8GB / 4MB = 2048 → 整除 ✓
- 8GB / 4MB = 2048 → 整除 ✓
```

### 3.2 虚拟内存预留（L1610-L1713）

这是**最重要的发现之一**：Java 堆不在 C 堆中，而是在**映射区**！

```cpp
// 预留最大堆内存（虚拟地址空间，不分配物理内存）
ReservedSpace heap_rs = Universe::reserve_heap(max_byte_size, heap_alignment);

// 将预留信息保存到 MemRegion
initialize_reserved_region((HeapWord*)heap_rs.base(), 
                           (HeapWord*)(heap_rs.base() + heap_rs.size()));
```

**mmap 系统调用详解**:

```c
// JVM 实际调用的 mmap（伪代码）
void* addr = mmap(
    preferred_addr,           // 期望地址（压缩指针优化）
    8GB,                      // 映射大小
    PROT_NONE,                // 先不可访问！只是预留地址空间
    MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE,
    -1,                       // 匿名映射
    0
);
```

**两阶段内存分配策略**:

```
阶段 1: Reserve（预留）
┌──────────────────────────────────────────────┐
│ mmap(PROT_NONE)                              │
│                                              │
│ • 占用虚拟地址空间                           │
│ • 不分配物理内存                             │
│ • 不消耗 RSS（进程实际内存）                 │
│ • 只修改页表，标记"已被使用"                 │
│                                              │
│ 作用：防止其他内存分配占用这段地址           │
└──────────────────────────────────────────────┘

阶段 2: Commit（提交）
┌──────────────────────────────────────────────┐
│ mmap(PROT_READ | PROT_WRITE, MAP_FIXED)      │
│                                              │
│ • 修改页表权限为可读写                       │
│ • 首次访问时触发 Page Fault                  │
│ • 操作系统分配物理页                         │
│ • 真正消耗物理内存                           │
│                                              │
│ 作用：按需分配，避免启动时占用大量内存       │
└──────────────────────────────────────────────┘
```

### 3.3 卡表与屏障集创建（L1715-L1755）

```cpp
// 创建 G1 卡表
G1CardTable *ct = new G1CardTable(reserved_region());
ct->initialize();

// 创建 G1 屏障集
G1BarrierSet *bs = new G1BarrierSet(ct);
bs->initialize();
BarrierSet::set_barrier_set(bs);    // 设置为全局屏障集
_card_table = ct;

// 创建热卡缓存
_hot_card_cache = new G1HotCardCache(this);
```

**卡表（Card Table）详解**:

```
【卡表核心概念】
问题：如何追踪跨代/跨 Region 引用？

场景：Region A（老年代）的对象引用 Region B（年轻代）的对象
       Young GC 时只回收 Region B，但需要知道谁引用了它

解决方案：卡表
┌──────────────────────────────────────────────┐
│ 堆内存（每 512 字节为一个"卡"）              │
│ ┌────┬────┬────┬────┬────┬────┐             │
│ │卡0 │卡1 │卡2 │卡3 │ ...    │ 8GB 堆       │
│ └────┴────┴────┴────┴────┴────┘             │
│    │    │    │    │                          │
│    ▼    ▼    ▼    ▼                          │
│ ┌────┬────┬────┬────┬─────────────────────┐ │
│ │ 0  │ 1  │ 0  │ 1  │ ...                 │ │
│ └────┴────┴────┴────┴─────────────────────┘ │
│  卡表（1 字节/卡，共 16MB）                   │
│  0 = 干净（无跨代引用）                       │
│  1 = 脏（有跨代引用）                         │
└──────────────────────────────────────────────┘

卡表大小计算（8GB 堆）：
  堆大小 / 卡大小 = 8GB / 512B = 16,777,216 字节 = 16MB

写后屏障：
  obj.field = value;    // 修改引用
  ├─ 原始代码
  └─ 写后屏障：card_table[addr >> 9] = 1;  // 标记为脏
```

**热卡缓存（Hot Card Cache）**:

```
问题：某些卡被频繁修改（热点代码）
      如果每次修改都立即处理，造成大量重复工作

解决方案：热卡缓存
┌──────────────────────────────────────────────┐
│ 写后屏障                                     │
│   ├─ 卡被标记为脏                            │
│   ├─ 如果是"热卡"（频繁修改）                │
│   │   └─ 放入 Hot Card Cache                 │
│   │       （不立即处理）                     │
│   └─ 否则                                    │
│       └─ 加入脏卡队列，立即处理              │
│                                              │
│ GC 暂停时：                                  │
│   └─ 统一处理 Hot Card Cache 中的卡          │
│       （避免重复劳动）                       │
└──────────────────────────────────────────────┘
```

### 3.4 六大数据结构映射器创建（L1757-L2005）

这是 G1 内存管理的核心，创建 6 个 `G1RegionToSpaceMapper` 来管理不同的内存区域：

```cpp
// 从预留的堆空间中划分出实际使用区域
ReservedSpace g1_rs = heap_rs.first_part(max_byte_size);
size_t page_size = UseLargePages ? os::large_page_size() : os::vm_page_size();

// ========== ① 堆内存映射器 ==========
G1RegionToSpaceMapper *heap_storage =
    G1RegionToSpaceMapper::create_mapper(
        g1_rs,                              // 预留的虚拟地址空间
        g1_rs.size(),                       // 实际使用大小（8GB）
        page_size,                          // 页面大小（4KB）
        HeapRegion::GrainBytes,             // Region 大小（4MB）
        1,                                  // commit_factor
        mtJavaHeap                          // 内存类型标记
    );

// ========== ② BOT 映射器 ==========
G1RegionToSpaceMapper *bot_storage =
    create_aux_memory_mapper("Block Offset Table",
                             G1BlockOffsetTable::compute_size(g1_rs.size() / HeapWordSize),
                             G1BlockOffsetTable::heap_map_factor());

// ========== ③ 卡表映射器 ==========
G1RegionToSpaceMapper *cardtable_storage =
    create_aux_memory_mapper("Card Table",
                             G1CardTable::compute_size(g1_rs.size() / HeapWordSize),
                             G1CardTable::heap_map_factor());

// ========== ④ 卡计数表映射器 ==========
G1RegionToSpaceMapper *card_counts_storage =
    create_aux_memory_mapper("Card Counts Table",
                             G1CardCounts::compute_size(g1_rs.size() / HeapWordSize),
                             G1CardCounts::heap_map_factor());

// ========== ⑤⑥ 并发标记位图映射器（双缓冲） ==========
size_t bitmap_size = G1CMBitMap::compute_size(g1_rs.size());

G1RegionToSpaceMapper *prev_bitmap_storage =
    create_aux_memory_mapper("Prev Bitmap", bitmap_size, G1CMBitMap::heap_map_factor());

G1RegionToSpaceMapper *next_bitmap_storage =
    create_aux_memory_mapper("Next Bitmap", bitmap_size, G1CMBitMap::heap_map_factor());
```

**六大数据结构内存占用（8GB 堆）**:

| 数据结构 | 大小 | 计算方式 | 作用 |
|----------|------|----------|------|
| **堆内存** | 8 GB | -Xmx8g | 实际 Java 对象存储 |
| **BOT** | 16 MB | 8GB / 512B | 快速定位对象起始 |
| **卡表** | 16 MB | 8GB / 512B | 跨代引用追踪 |
| **卡计数表** | 16 MB | 8GB / 512B | 热卡统计 |
| **Prev 位图** | 128 MB | 8GB / 64B | 上一轮标记结果 |
| **Next 位图** | 128 MB | 8GB / 64B | 当前标记工作区 |
| **总计** | **8.3 GB** | - | 约 4% 额外开销 |

**并发标记双缓冲位图详解**:

```
【为什么需要两个位图？】

场景：并发标记与 Mixed GC 同时进行

问题：
  Mixed GC 需要【读取】上一轮稳定的标记结果
  并发标记需要【写入】当前正在进行的标记结果
  如果只有一个位图，读写会相互干扰！

解决方案：双缓冲机制
┌──────────────────────────────────────────────┐
│  Prev Bitmap（上一轮结果，只读）              │
│  ┌────────────────────────────────────────┐  │
│  │ bit0 bit1 bit2 ...                     │  │
│  │  0    1    0   ...                     │  │
│  │  ↑ 存活对象标记                        │  │
│  └────────────────────────────────────────┘  │
│  用途：Mixed GC 判断对象是否存活             │
│                                              │
│  Next Bitmap（当前标记，可写）                │
│  ┌────────────────────────────────────────┐  │
│  │ bit0 bit1 bit2 ...                     │  │
│  │  1    0    1   ...                     │  │
│  │  ↑ 正在标记                            │  │
│  └────────────────────────────────────────┘  │
│  用途：并发标记线程标记新发现的对象           │
│                                              │
│  标记周期完成时：                              │
│    swap(prev_bitmap, next_bitmap)            │
│    O(1) 操作！只交换指针                     │
└──────────────────────────────────────────────┘

位图大小计算：
  每个 bit 对应 64 字节堆内存（对象最小对齐）
  8GB / 64B = 134,217,728 bits = 16,777,216 bytes = 128MB
  双缓冲 = 128MB × 2 = 256MB
```

### 3.5 HeapRegionManager 初始化（L2000-L2005）

```cpp
// 初始化 HeapRegionManager（核心！）
_hrm.initialize(heap_storage,           // 堆内存
                prev_bitmap_storage,    // 上一轮位图
                next_bitmap_storage,    // 当前位图
                bot_storage,            // BOT
                cardtable_storage,      // 卡表
                card_counts_storage);   // 卡计数表
```

**HeapRegionManager 职责**:

```
HeapRegionManager 是 G1 的核心管理器，负责：
1. 管理 2048 个 HeapRegion 对象
2. 维护空闲 Region 列表
3. 处理 Region 分配请求
4. 协调各类辅助数据结构

初始化时会：
- 创建 2048 个 HeapRegion 实例
- 每个 Region 关联到对应的内存位置
- 初始化每个 Region 的辅助数据结构（BOT、卡表等）
```

### 3.6 CSet 快速测试数组（L2050-L2089）

```cpp
// 初始化 CSet 快速测试数组
HeapWord *start = _hrm.reserved().start();
HeapWord *end   = _hrm.reserved().end();
size_t granularity = HeapRegion::GrainBytes;

_in_cset_fast_test.initialize(start, end, granularity);
```

**为什么需要 O(1) 判断 CSet？**

```
【问题背景】
CSet（Collection Set）= 本次 GC 要回收的 Region 集合

场景：写屏障需要频繁判断 obj 是否在 CSet 中
  if (obj_in_cset(obj)) {
      // 记录到 RSet
  }

如果没有快速测试：
  需要遍历 CSet 中的所有 Region
  CSet 可能有几十个 Region
  每次判断都是 O(n)，性能极差！

解决方案：空间换时间
┌──────────────────────────────────────────────┐
│ _in_cset_fast_test 数组（2048 字节）          │
│                                              │
│ 索引 = (obj_addr - heap_start) / Region大小   │
│      = (obj_addr - 0x600000000) >> 22        │
│                                              │
│ 值：                                         │
│   0 = NotInCSet（不在 CSet 中）              │
│   1 = Young（年轻代 Region，在 CSet 中）     │
│   2 = Old（老年代 Region，在 CSet 中）       │
│  -1 = Humongous（巨型对象，特殊处理）        │
│                                              │
│ 判断时间：O(1)                               │
│ 空间开销：2048 bytes（可忽略）               │
└──────────────────────────────────────────────┘
```

---

## 第四章：核心子系统深度剖析

### 4.1 G1RegionToSpaceMapper 详解

```cpp
// G1RegionToSpaceMapper 类定义
class G1RegionToSpaceMapper : public CHeapObj<mtGC> {
private:
    ReservedSpace _storage;           // ① 预留的虚拟内存
    size_t _page_size;                // ② 页面大小（4KB）
    size_t _region_granularity;       // ③ Region 粒度（4MB）
    size_t _commit_factor;            // ④ 提交因子
    
public:
    // 创建映射器
    static G1RegionToSpaceMapper* create_mapper(...);
    
    // 提交/取消提交 Region 对应的内存
    void commit_regions(uint start_idx, size_t num_regions);
    void uncommit_regions(uint start_idx, size_t num_regions);
};
```

**关键设计：延迟提交（Commit-on-demand）**

```
┌──────────────────────────────────────────────┐
│ 堆内存初始化状态                              │
│ ┌─────────────────────────────────────────┐  │
│ │ Region 0 │ Region 1 │ ... │ Region 2047│  │
│ │  UNCOMMIT│  UNCOMMIT│     │  UNCOMMIT  │  │
│ └─────────────────────────────────────────┘  │
│                                              │
│ 对象分配时（以 Region 0 为例）：              │
│                                              │
│ 1. TLAB 分配耗尽                             │
│ 2. 申请新的 Region 0                         │
│ 3. heap_storage->commit_regions(0, 1)        │
│ 4. mmap(PROT_READ|PROT_WRITE) 4MB            │
│                                              │
│ 状态变化：                                    │
│ ┌─────────────────────────────────────────┐  │
│ │ Region 0 │ Region 1 │ ... │ Region 2047│  │
│ │ COMMITTED│  UNCOMMIT│     │  UNCOMMIT  │  │
│ └─────────────────────────────────────────┘  │
│                                              │
│ 优势：按需分配，避免启动时占用 8GB 物理内存   │
└──────────────────────────────────────────────┘
```

### 4.2 记忆集（RSet）系统

```
【RSet 核心问题】
问题：Young GC 时只回收年轻代 Region
      但需要知道哪些老年代对象引用了年轻代对象
      否则可能错误回收存活对象！

传统方案：
  扫描整个老年代找引用 → O(老年代大小)，太慢！

G1 方案：记忆集（Remembered Set）
  每个 Region 维护自己的 RSet
  只记录【指向本 Region 的引用】来自哪里
  查询时间 O(RSet 大小)，与堆大小无关
```

**RSet 结构**:

```
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

写屏障维护 RSet：
  a1.field = b1;  // 建立跨 Region 引用
  ├─ 写后屏障
  │   ├─ 标记卡表为脏
  │   └─ 将 (RegionA, card_idx) 加入 RegionB 的 RSet
  └─ 对象引用赋值
```

---

## 第五章：GDB 验证与数据解读

### 5.1 GDB 验证脚本

```gdb
# GDB 验证 G1CollectedHeap::initialize()
# 标准条件：-Xms8g -Xmx8g -XX:+UseG1GC

set pagination off
set print pretty on

# 断点：initialize 入口
break g1CollectedHeap.cpp:1587

# 断点：6 个映射器创建完成
break g1CollectedHeap.cpp:2005

run -XX:+UseG1GC -Xms8g -Xmx8g -Xint -cp . Main

printf "\n========== G1CollectedHeap::initialize() 验证 ==========\n\n"

# 验证 1: 堆大小
printf "[验证 1] 堆大小参数:\n"
print collector_policy()->initial_heap_byte_size() / (1024*1024*1024)
print collector_policy()->max_heap_byte_size() / (1024*1024*1024)
printf "[预期] 8 GB\n\n"

# 验证 2: Region 大小
printf "[验证 2] Region 大小:\n"
print HeapRegion::GrainBytes
print HeapRegion::GrainBytes / (1024*1024)
printf "[预期] 4,194,304 bytes = 4 MB\n\n"

# 验证 3: 卡表大小
printf "[验证 3] 卡表相关:\n"
print G1CardTable::card_size
print HeapRegion::CardsPerRegion
print (size_t)G1CardTable::compute_size(max_capacity())
printf "[预期] card_size=512, CardsPerRegion=8192, 总大小=16MB\n\n"

# 验证 4: 位图大小
printf "[验证 4] 并发标记位图大小:\n"
print (size_t)G1CMBitMap::compute_size(reserved_region().byte_size())
print (size_t)G1CMBitMap::compute_size(reserved_region().byte_size()) / (1024*1024)
printf "[预期] 128 MB（双缓冲共 256 MB）\n\n"

# 验证 5: Region 数量
continue

printf "[验证 5] Region 数量:\n"
print max_regions()
printf "[预期] 2048\n\n"

# 验证 6: CSet 快查数组大小
printf "[验证 6] CSet 快查数组:\n"
print sizeof(_in_cset_fast_test)
printf "[预期] 2048 bytes\n\n"

printf "========== 所有验证完成 ==========\n"

continue
quit
```

### 5.2 验证结果解读

【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC

```
┌────────────────────────────────────────────────────────────┐
│ [验证 1] 堆大小参数                                         │
│ $1 = 8589934592  (8 GB) ✓                                  │
│ $2 = 8589934592  (8 GB) ✓                                  │
├────────────────────────────────────────────────────────────┤
│ [验证 2] Region 大小                                        │
│ $3 = 4194304     (4 MB) ✓                                  │
│ $4 = 4          (MB) ✓                                     │
├────────────────────────────────────────────────────────────┤
│ [验证 3] 卡表相关                                           │
│ $5 = 512        (bytes/card) ✓                             │
│ $6 = 8192       (cards/region) ✓                           │
│ $7 = 16777216   (16 MB 总卡表大小) ✓                       │
├────────────────────────────────────────────────────────────┤
│ [验证 4] 并发标记位图大小                                   │
│ $8 = 134217728  (128 MB) ✓                                 │
│ $9 = 128        (MB) ✓                                     │
│ (双缓冲共 256 MB)                                          │
├────────────────────────────────────────────────────────────┤
│ [验证 5] Region 数量                                        │
│ $10 = 2048 ✓                                               │
├────────────────────────────────────────────────────────────┤
│ [验证 6] CSet 快查数组                                      │
│ $11 = 2048     (bytes) ✓                                   │
└────────────────────────────────────────────────────────────┘
```

---

## 第六章：性能分析与调优建议

### 6.1 内存开销分析（8GB 堆）

| 组件 | 大小 | 占比 | 说明 |
|------|------|------|------|
| Java 堆 | 8,192 MB | 96.2% | 实际对象存储 |
| BOT | 16 MB | 0.19% | 块偏移表 |
| 卡表 | 16 MB | 0.19% | 跨代引用追踪 |
| 卡计数表 | 16 MB | 0.19% | 热卡统计 |
| Prev 位图 | 128 MB | 1.50% | 并发标记 |
| Next 位图 | 128 MB | 1.50% | 并发标记 |
| RSet | ~256 MB | 3.0% | 记忆集（估算） |
| **总计** | **~8,752 MB** | **~103%** | 约 3-4% 额外开销 |

### 6.2 关键 JVM 参数

| 参数 | 默认值 | 调优建议 |
|------|--------|----------|
| `-XX:+UseG1GC` | 关闭 | **必须开启** |
| `-Xms/-Xmx` | - | **设为相等**，避免堆 resize |
| `-XX:G1HeapRegionSize` | 自动 | 手动指定需谨慎 |
| `-XX:MaxGCPauseMillis` | 200ms | 根据应用需求调整 |
| `-XX:InitiatingHeapOccupancyPercent` | 45 | 老年代占用百分比触发并发标记 |

---

## 第七章：面试常见问题

### Q1: G1CollectedHeap::initialize() 主要做了什么？

**答**: 建立完整的 G1 内存管理体系，包括：
1. **虚拟内存预留**：mmap 预留 8GB 虚拟地址空间（不分配物理内存）
2. **六大数据结构映射器**：堆内存、BOT、卡表、卡计数表、双缓冲位图
3. **2048 个 Region 初始化**：通过 HeapRegionManager 管理
4. **卡表与屏障集**：创建 G1CardTable 和 G1BarrierSet
5. **记忆集系统**：G1RemSet 初始化
6. **辅助结构**：CSet 快查数组、巨型对象回收候选数组

**核心数据（8GB 堆）**：
- Region 大小：4MB，共 2048 个
- 卡表：16MB（每 512B 堆内存 1 byte）
- 位图：256MB（双缓冲，每 64B 堆内存 1 bit）

### Q2: 为什么 Java 堆不在 C 堆中？

**答**: Java 堆通过 mmap 直接映射到进程的虚拟地址空间，而不是在 C 堆（malloc 管理）中分配。原因：
1. **大内存管理**：C 堆管理数十 GB 内存效率低，容易产生碎片
2. **独立生命周期**：Java 堆可以独立提交/取消提交内存页
3. **压缩指针优化**：mmap 可以选择特定的虚拟地址范围（如 0-32GB），支持 ZeroBased 压缩模式

### Q3: 什么是双缓冲位图？为什么需要两个？

**答**: G1 使用两个位图（Prev Bitmap 和 Next Bitmap）实现并发标记：
- **Prev Bitmap**：存储上一轮标记结果，只读，供 Mixed GC 使用
- **Next Bitmap**：当前标记工作区，可写，并发标记线程使用

**为什么需要两个**：
- Mixed GC 需要读取稳定的标记结果判断对象存活
- 并发标记需要写入新的标记结果
- 如果只有一个位图，读写会冲突
- 标记完成后交换指针即可，O(1) 操作

### Q4: CSet 快查数组是如何实现 O(1) 查询的？

**答**: 使用空间换时间：
- 数组长度 = Region 数量 = 2048
- 索引 = (obj_addr - heap_start) / Region_size
- 值 = 0(不在 CSet) / 1(Young) / 2(Old) / -1(Humongous)
- 查询时间：直接数组访问，O(1)
- 空间开销：2048 bytes，可忽略

---

## 第八章：总结

### 8.1 核心知识点回顾

```
【G1CollectedHeap::initialize() 核心要点】

1. 内存管理三层架构
   MemRegion(描述) → ReservedSpace(虚拟内存) → G1RegionToSpaceMapper(物理映射)

2. 六大数据结构
   堆内存(8GB) + BOT(16MB) + 卡表(16MB) + 卡计数表(16MB) + 位图×2(256MB)

3. 2048 个 Region
   每个 4MB，通过 HeapRegionManager 管理

4. 双缓冲位图
   Prev(只读) + Next(可写)，支持并发标记

5. O(1) CSet 查询
   _in_cset_fast_test 数组，2048 bytes

6. 总内存开销
   约 3-4% 额外开销（8GB 堆约占用 8.3GB）
```

### 8.2 下一步学习建议

1. **HeapRegionManager::initialize()**：深入了解 2048 个 Region 如何初始化
2. **G1RemSet 详解**：记忆集的三种存储格式（稀疏/细粒度/粗粒度）
3. **Young GC 流程**：从 GC 触发到对象复制的完整流程
4. **并发标记**：Initial Mark → Root Scanning → Concurrent Mark → Remark → Cleanup

---

*文档完成时间: 2026-02-10*  
*基于 OpenJDK 11 源码分析*  
*标准环境: -Xms8g -Xmx8g -XX:+UseG1GC，Region=4MB*
