# G1MonitoringSupport 专家级源码分析

> **定位**：G1 堆监控支持类，为 jstat、JMX 等监控工具提供堆内存统计数据  
> **核心问题**：G1 的 Region 化内存如何映射到传统分代监控模型？如何高效维护监控数据？  
> **源码路径**：`src/hotspot/share/gc/g1/g1MonitoringSupport.hpp/cpp`

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1MonitoringSupport 的本质是**G1 Region 化内存到传统分代监控模型的适配器**：`jstat`/JMX 期望看到 Eden/Survivor/Old 三个分代的容量和使用量，但 G1 的内存是 Region 化的（没有固定的分代边界）；G1MonitoringSupport 将 G1 的 Region 统计数据映射为传统分代模型，供监控工具使用。

### 0.2 为什么需要？

监控工具（jstat/JMX/JConsole）基于传统分代模型设计，期望看到 Eden/Survivor/Old 的容量和使用量。G1 的内存模型与传统分代不同（Region 可以动态切换角色），需要一个适配层将 G1 的内存统计转换为传统分代模型的格式。

### 0.3 怎么解决？

**Region 统计 → 分代统计映射**：`update_sizes()` 在每次 GC 后更新统计数据；Eden 容量 = Eden Region 数量 × Region 大小；Survivor 容量 = Survivor Region 数量 × Region 大小；Old 容量 = Old Region 数量 × Region 大小；Humongous 归入 Old。

### 0.4 为什么这样设计？

- **为什么 Humongous 归入 Old 而不是单独统计？** 传统监控模型没有 Humongous 的概念；Humongous 对象生命周期类似 Old 对象（不经过 Young GC），归入 Old 是最合理的近似
- **为什么 `update_sizes()` 在 GC 后而不是实时更新？** 实时更新需要在每次 Region 角色变化时更新统计，代价高；GC 后批量更新，监控数据有一定延迟但代价低

---

## 1. 一句话总结

**G1MonitoringSupport 是 G1 堆与监控工具之间的适配层，将 G1 的离散 Region 内存模型映射到传统分代监控模型（Eden/Survivor/Old），通过延迟计算和缓存机制，为 jstat、JMX MemoryMXBean 等提供准确的堆内存统计信息。**

---

## 2. 为什么需要 G1MonitoringSupport？

### 2.1 问题背景

G1 与传统分代 GC（如 Parallel GC）的内存模型完全不同：

| 特性 | Parallel GC | G1 |
|------|-------------|-----|
| 堆结构 | 连续内存空间（Young + Old） | 离散 Region（2048 个） |
| Eden/Survivor | 连续区域 | 非连续的多个 Region |
| 代边界 | 固定地址 | 动态变化 |

**核心挑战**：
- jstat、JMX 等工具期望传统的分代监控数据
- G1 的 Region 是动态分配的，没有固定的 Eden/Survivor 边界
- 需要实时计算各"逻辑空间"的使用情况

### 2.2 如果没有适配层？

```
问题场景
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

jstat 期望的数据：
  - S0C/S1C: Survivor 0/1 容量
  - EC: Eden 容量
  - OC: Old 容量
  - S0U/S1U/EU/OU: 各空间使用量

G1 实际情况：
  - 2048 个 Region，每个 4MB
  - Eden 由多个不连续的 Region 组成
  - Survivor 也是多个不连续的 Region
  - 没有固定的 S0/S1 划分

如果没有 G1MonitoringSupport：
  - jstat 显示 Eden=0, Survivor=0, Old=0
  - 监控工具无法正确显示 G1 堆状态
  - 运维人员无法判断 GC 情况

✅ G1MonitoringSupport 解决方案：
  - 将离散的 Region 按类型聚合
  - 模拟传统分代计数器
  - 实时计算并缓存统计数据
```

---

## 3. 整体架构

### 3.1 类层次关系

```
G1MonitoringSupport 架构
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

G1MonitoringSupport (核心适配器)
├── _g1h: G1CollectedHeap*              // G1 堆引用
├── 
│   // jstat/GC 计数器
├── _incremental_collection_counters: CollectorCounters*    // Young/Mixed GC
├── _full_collection_counters: CollectorCounters*          // Full GC
├── _conc_collection_counters: CollectorCounters*          // 并发 GC 阶段
│
│   // 分代计数器
├── _young_collection_counters: G1YoungGenerationCounters* // 年轻代
├── _old_collection_counters: G1OldGenerationCounters*     // 老年代
│
│   // 空间计数器（对应 jstat 输出）
├── _old_space_counters: HSpaceCounters*   // Old (OC/OU)
├── _eden_counters: HSpaceCounters*        // Eden (EC/EU)
├── _from_counters: HSpaceCounters*        // S0 (S0C/S0U) - 未使用
└── _to_counters: HSpaceCounters*          // S1 (S1C/S1U) - 实际 Survivor

    // 缓存的统计数据
├── _overall_reserved: size_t      // 保留内存 (8GB)
├── _overall_committed: size_t     // 提交内存
├── _overall_used: size_t          // 已使用内存
├── _young_region_num: uint        // 年轻代 Region 数
├── _young_gen_committed: size_t   // 年轻代提交内存
├── _eden_committed: size_t        // Eden 提交内存
├── _eden_used: size_t             // Eden 使用内存
├── _survivor_committed: size_t    // Survivor 提交内存
├── _survivor_used: size_t         // Survivor 使用内存
├── _old_committed: size_t         // Old 提交内存
└── _old_used: size_t              // Old 使用内存
```

### 3.2 监控数据映射

```
jstat 输出 vs G1MonitoringSupport
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

jstat -gc 列     G1MonitoringSupport 字段/计数器                说明
─────────────────────────────────────────────────────────────────
S0C             _from_counters->capacity()                      Survivor0 容量 (G1 中为 0)
S1C             _to_counters->capacity()                        Survivor1 容量 (实际 Survivor)
S0U             _from_counters->used()                          Survivor0 使用 (G1 中为 0)
S1U             _to_counters->used()                            Survivor1 使用 (实际 Survivor)
EC              _eden_counters->capacity()                      Eden 容量
EU              _eden_counters->used()                          Eden 使用
OC              _old_space_counters->capacity()                 Old 容量
OU              _old_space_counters->used()                     Old 使用
YGC             _incremental_collection_counters->invocations() Young GC 次数
YGCT            _incremental_collection_counters->time()        Young GC 耗时
FGC             _full_collection_counters->invocations()        Full GC 次数
FGCT            _full_collection_counters->time()               Full GC 耗时
GCT             YGCT + FGCT                                     总 GC 耗时

注：G1 不像传统 GC 有 S0/S1 复制，Survivor 由多个离散 Region 组成。
为了兼容 jstat，S0 设为 0，所有 Survivor 统计放在 S1。
```

---

## 4. 核心数据结构详解

### 4.1 计数器类型

```cpp
// G1MonitoringSupport 成员变量
class G1MonitoringSupport : public CHeapObj<mtGC> {
private:
    // ====== GC 收集器计数器 ======
    // 用于统计 GC 次数和耗时
    CollectorCounters*   _incremental_collection_counters;  // Young/Mixed GC
    CollectorCounters*   _full_collection_counters;         // Full GC  
    CollectorCounters*   _conc_collection_counters;         // 并发 GC STW 阶段
    
    // ====== 分代计数器 ======
    // 用于统计代（Generation）级别的数据
    GenerationCounters*  _young_collection_counters;        // 年轻代
    GenerationCounters*  _old_collection_counters;          // 老年代
    
    // ====== 空间计数器 ======
    // 用于统计空间（Space）级别的数据（对应 jstat 输出）
    HSpaceCounters*      _old_space_counters;   // generation.1.space.0 (Old)
    HSpaceCounters*      _eden_counters;        // generation.0.space.0 (Eden)
    HSpaceCounters*      _from_counters;        // generation.0.space.1 (S0 - 未使用)
    HSpaceCounters*      _to_counters;          // generation.0.space.2 (S1 - 实际 Survivor)
};
```

#### CollectorCounters 计数器命名

```
CollectorCounters 命名规则
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

collector.0: G1 incremental collections
  - 命名空间: "sun.gc.collector.0"
  - 统计: Young GC + Mixed GC 次数和耗时
  - jstat: YGC, YGCT

collector.1: G1 stop-the-world full collections
  - 命名空间: "sun.gc.collector.1"
  - 统计: Full GC 次数和耗时
  - jstat: FGC, FGCT

collector.2: G1 stop-the-world phases
  - 命名空间: "sun.gc.collector.2"
  - 统计: 并发 GC 的 STW 阶段（Initial Mark, Remark, Cleanup）
  - jstat: 无直接对应（内部统计）
```

#### GenerationCounters 命名规则

```
GenerationCounters 命名规则
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

generation.0: young
  - 命名空间: "sun.gc.generation.0"
  - 包含 3 个空间：eden, s0, s1
  - jstat: EC, EU, S0C, S0U, S1C, S1U

generation.1: old
  - 命名空间: "sun.gc.generation.1"
  - 包含 1 个空间：old space
  - jstat: OC, OU
```

### 4.2 缓存的统计数据

```cpp
// 延迟计算的统计数据
class G1MonitoringSupport : public CHeapObj<mtGC> {
private:
    // 整体堆统计
    size_t _overall_reserved;      // 最大容量 (-Xmx)
    size_t _overall_committed;     // 当前提交内存
    size_t _overall_used;          // 当前使用内存
    
    // 年轻代统计
    uint   _young_region_num;      // 年轻代 Region 数量
    size_t _young_gen_committed;   // 年轻代提交内存
    
    // Eden 统计
    size_t _eden_committed;        // Eden 提交内存
    size_t _eden_used;             // Eden 使用内存
    
    // Survivor 统计
    size_t _survivor_committed;    // Survivor 提交内存
    size_t _survivor_used;         // Survivor 使用内存
    
    // 老年代统计
    size_t _old_committed;         // Old 提交内存
    size_t _old_used;              // Old 使用内存
};
```

**为什么需要缓存？**
1. **性能优化**：避免每次查询都重新计算
2. **一致性**：GC 暂停期间批量更新，保证数据一致
3. **延迟计算**：只有必要时才重新计算

---

## 5. 核心算法详解

### 5.1 构造函数 - 计数器初始化

```cpp
G1MonitoringSupport::G1MonitoringSupport(G1CollectedHeap *g1h) :
        _g1h(g1h), ... {
    
    // 1. 获取整体保留内存（-Xmx）
    _overall_reserved = g1h->max_capacity();  // 8GB
    
    // 2. 计算各区域初始大小
    recalculate_sizes();

    // 3. 创建 GC 收集器计数器
    _incremental_collection_counters =
            new CollectorCounters("G1 incremental collections", 0);
    _full_collection_counters =
            new CollectorCounters("G1 stop-the-world full collections", 1);
    _conc_collection_counters =
            new CollectorCounters("G1 stop-the-world phases", 2);

    // 4. 创建分代计数器
    // generation.1 (old)
    _old_collection_counters = new G1OldGenerationCounters(this, "old");
    
    // generation.0 (young)
    _young_collection_counters = new G1YoungGenerationCounters(this, "young");

    // 5. 创建空间计数器
    const char *young_collection_name_space = _young_collection_counters->name_space();
    
    // generation.1.space.0 (Old)
    _old_space_counters = new HSpaceCounters(
        _old_collection_counters->name_space(), "space", 0,
        pad_capacity(overall_reserved()),      // max = 8GB
        pad_capacity(old_space_committed()));  // init

    // generation.0.space.0 (Eden)
    _eden_counters = new HSpaceCounters(
        young_collection_name_space, "eden", 0,
        pad_capacity(overall_reserved()),       // max = 8GB
        pad_capacity(eden_space_committed()));  // init

    // generation.0.space.1 (S0 - G1 未使用)
    _from_counters = new HSpaceCounters(
        young_collection_name_space, "s0", 1,
        pad_capacity(0),   // max = 0 (不用)
        pad_capacity(0));  // init = 0

    // generation.0.space.2 (S1 - 实际 Survivor)
    _to_counters = new HSpaceCounters(
        young_collection_name_space, "s1", 2,
        pad_capacity(overall_reserved()),           // max = 8GB
        pad_capacity(survivor_space_committed()));  // init
}
```

**关键设计**：
- **S0 设为 0**：G1 不像传统 GC 有 S0/S1 复制，Survivor 由离散 Region 组成
- **所有 Survivor 放在 S1**：为了兼容 jstat 输出格式
- **Padding**：避免 jstat 显示 0 容量（jstat 工具的特殊要求）

### 5.2 recalculate_sizes - 重新计算大小

```cpp
void G1MonitoringSupport::recalculate_sizes() {
    // 1. 获取 Region 数量
    uint young_list_length = _g1h->young_regions_count();      // 年轻代 Region 数
    uint survivor_list_length = _g1h->survivor_regions_count(); // Survivor Region 数
    uint eden_list_length = young_list_length - survivor_list_length;  // Eden Region 数
    
    // 最大年轻代长度（包含潜在扩展）
    uint young_list_max_length = _g1h->g1_policy()->young_list_max_length();
    uint eden_list_max_length = young_list_max_length - survivor_list_length;

    // 2. 计算使用量 (used)
    _overall_used = _g1h->used_unlocked();  // 整体使用
    _eden_used = (size_t) eden_list_length * HeapRegion::GrainBytes;
    _survivor_used = (size_t) survivor_list_length * HeapRegion::GrainBytes;
    _young_region_num = young_list_length;
    _old_used = subtract_up_to_zero(_overall_used, _eden_used + _survivor_used);

    // 3. 计算提交量 (committed)
    _survivor_committed = _survivor_used;
    _old_committed = HeapRegion::align_up_to_region_byte_size(_old_used);
    
    _overall_committed = _g1h->capacity();  // 8GB
    size_t committed = _overall_committed;
    
    // 减去已计算的 Survivor 和 Old
    committed -= (_survivor_committed + _old_committed);
    
    // 计算 Eden 提交量
    _eden_committed = (size_t) eden_list_max_length * HeapRegion::GrainBytes;
    _eden_committed = MIN2(_eden_committed, committed);
    committed -= _eden_committed;
    
    // 剩余给 Old
    _old_committed += committed;
    _young_gen_committed = _eden_committed + _survivor_committed;

    // 验证：各空间相加应等于整体
    assert(_overall_committed ==
           (_eden_committed + _survivor_committed + _old_committed),
           "the committed sizes should add up");
}

// 辅助函数：安全减法，避免负数（size_t 下溢）
static size_t subtract_up_to_zero(size_t x, size_t y) {
    return (x > y) ? (x - y) : 0;
}
```

**计算逻辑**：
1. **Eden 计算**：`eden_max_regions × 4MB`（基于目标年轻代大小）
2. **Survivor 计算**：`survivor_regions × 4MB`（实际使用）
3. **Old 计算**：剩余内存 = 总提交 - Eden - Survivor

### 5.3 update_sizes - 更新计数器

```cpp
void G1MonitoringSupport::update_sizes() {
    // 1. 重新计算所有大小
    recalculate_sizes();
    
    // 2. 更新 jstat 计数器（仅当启用性能数据时）
    if (UsePerfData) {
        // 更新 Eden 计数器
        eden_counters()->update_capacity(pad_capacity(eden_space_committed()));
        eden_counters()->update_used(eden_space_used());
        
        // 更新 Survivor 计数器（只更新 S1，S0 始终为 0）
        to_counters()->update_capacity(pad_capacity(survivor_space_committed()));
        to_counters()->update_used(survivor_space_used());
        
        // 更新 Old 计数器
        old_space_counters()->update_capacity(pad_capacity(old_space_committed()));
        old_space_counters()->update_used(old_space_used());
        
        // 更新分代计数器
        old_collection_counters()->update_all();
        young_collection_counters()->update_all();
        
        // 更新元空间计数器
        MetaspaceCounters::update_performance_counters();
        CompressedClassSpaceCounters::update_performance_counters();
    }
}
```

**调用时机**：
- **GC 结束后**：批量更新所有计数器
- **Eden 分配时**：轻量级更新 Eden 使用量（见下文）

### 5.4 recalculate_eden_size - 轻量级 Eden 更新

```cpp
void G1MonitoringSupport::recalculate_eden_size() {
    // 当分配新的 Eden Region 时，只更新 Eden 使用量
    // 避免每次 GC 都重新计算所有数据
    
    uint young_region_num = _g1h->young_regions_count();
    if (young_region_num > _young_region_num) {
        uint diff = young_region_num - _young_region_num;
        _eden_used += (size_t) diff * HeapRegion::GrainBytes;
        _eden_used = MIN2(_eden_used, _eden_committed);
        _young_region_num = young_region_num;
    }
}

void G1MonitoringSupport::update_eden_size() {
    recalculate_eden_size();
    if (UsePerfData) {
        eden_counters()->update_used(eden_space_used());
    }
}
```

**优化目的**：
- Eden 分配是高频操作（应用线程持续分配）
- 轻量级更新只修改 Eden 使用计数，不影响其他数据
- 保持分配路径低开销

---

## 6. 性能优化分析

### 6.1 延迟计算策略

```
计算策略对比
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

策略1：实时计算（每次查询都计算）
  jstat 查询 → 遍历所有 Region → 统计 Eden/Survivor/Old
  问题：
    - O(n) 复杂度，n=2048 个 Region
    - 每次查询耗时 ~0.1ms
    - jstat 每秒查询 10 次 = 1ms CPU 消耗

策略2：延迟计算（G1 实际采用）
  - GC 结束后：批量计算所有数据
  - Eden 分配时：轻量级更新 Eden 计数
  - 查询时：直接返回缓存值
  优势：
    - O(1) 查询复杂度
    - 计算开销分散在 GC 和分配路径
    - 不影响监控查询性能
```

### 6.2 Padding 机制

```cpp
// jstat 工具要求容量不能为 0
static size_t pad_capacity(size_t size_bytes, size_t mult = 1) {
    return size_bytes + MinObjAlignmentInBytes * mult;
}

// 示例：
// 实际 Eden 容量 = 432MB
// pad_capacity(432MB) = 432MB + 8 bytes
// 
// 原因：
// jstat 工具内部使用某些算法处理容量为 0 的情况会有问题
// 添加一个小 padding 避免显示问题
```

### 6.3 条件更新

```cpp
void G1MonitoringSupport::update_sizes() {
    // 只在启用性能数据时更新
    // 避免 -XX:-UsePerfData 时的无用开销
    if (UsePerfData) {
        // 更新计数器...
    }
}
```

---

## 7. 常见问题与面试题

### Q1: G1 的 S0 为什么是 0？

**答案**：
- G1 不像传统 GC（Parallel/CMS）有 S0/S1 两个 Survivor 空间来回复制
- G1 的 Survivor 由多个离散的 Region 组成
- 为了兼容 jstat 输出格式，将所有 Survivor 统计放在 S1，S0 设为 0

### Q2: recalculate_sizes 和 recalculate_eden_size 有什么区别？

**答案**：
| 方法 | 调用时机 | 计算范围 | 目的 |
|------|----------|----------|------|
| **recalculate_sizes** | GC 结束后 | 所有空间（Eden/Survivor/Old） | 全面更新，保证一致性 |
| **recalculate_eden_size** | Eden Region 分配时 | 仅 Eden | 轻量级更新，减少开销 |

### Q3: 为什么需要 G1MonitoringSupport 而不是直接用 G1CollectedHeap 的数据？

**答案**：
1. **模型转换**：G1 的 Region 模型需要转换为传统分代模型
2. **延迟计算**：避免实时遍历 2048 个 Region
3. **计数器管理**：统一管理 jstat/JMX 所需的各类计数器
4. **数据一致性**：GC 暂停期间批量更新，避免并发问题

### Q4: jstat 看到的 Eden 容量为什么比实际使用的大？

**答案**：
```
Eden 容量计算逻辑：
  _eden_committed = eden_max_regions × 4MB
  
  eden_max_regions = young_list_target_length - survivor_regions
                   = 108 - 0 (初始)
                   = 108
                   
  _eden_committed = 108 × 4MB = 432MB

实际 Eden 使用：
  - 应用刚启动，可能只分配了 10 个 Eden Region
  - 实际使用 = 10 × 4MB = 40MB
  
差距原因：
  - Eden 容量是"目标"大小（可容纳的最大 Region 数）
  - 实际使用是"当前"大小（已分配的 Region 数）
  - 随着应用运行，实际使用会接近目标容量
```

---

## 8. 总结

### 8.1 核心设计要点

```
G1MonitoringSupport 设计精髓
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. 模型适配
   ├── Region 模型 → 分代模型
   ├── 离散 Region → 连续空间假象
   └── S0/S1 兼容 → Survivor 统一放 S1

2. 性能优化
   ├── 延迟计算：GC 后批量更新
   ├── 轻量级更新：Eden 分配时只更新 Eden
   ├── 缓存机制：O(1) 查询复杂度
   └── 条件编译：UsePerfData 控制

3. 数据一致性
   ├── STW 期间更新：避免并发问题
   ├── 分层计算：Region → 空间 → 代
   └── 验证机制：assert 检查数据一致性

4. 兼容性
   ├── jstat 兼容：传统列名映射
   ├── JMX 兼容：MemoryPool MXBean
   └── Padding 处理：避免 0 容量问题
```

### 8.2 数据结构关系图

```
G1MonitoringSupport 数据流
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

G1CollectedHeap (Region 集合)
        │
        │ young_regions_count()
        │ survivor_regions_count()
        │ used_unlocked()
        │ capacity()
        ▼
G1MonitoringSupport.recalculate_sizes()
        │
        ├── Eden Region 数 × 4MB → _eden_committed/used
        ├── Survivor Region 数 × 4MB → _survivor_committed/used
        └── 剩余 → _old_committed/used
        │
        ▼
HSpaceCounters.update_capacity()/update_used()
        │
        ▼
jstat / JMX 输出
        │
        ├── generation.0.space.0 (EC/EU)
        ├── generation.0.space.2 (S1C/S1U)
        └── generation.1.space.0 (OC/OU)
```

---

## 参考文档

1. OpenJDK 11: `src/hotspot/share/gc/g1/g1MonitoringSupport.hpp/cpp`
2. OpenJDK 11: `src/hotspot/share/gc/shared/generationCounters.hpp`
3. OpenJDK 11: `src/hotspot/share/gc/shared/hSpaceCounters.hpp`
4. jstat 文档: https://docs.oracle.com/javase/8/docs/technotes/tools/unix/jstat.html

---

**文档信息**
- 创建时间: 2026-02-10
- 源码版本: OpenJDK 11
- 分析类型: 专家级源码分析
- 配套技能: Read-BottomUp, JVM-Optimization-Design
