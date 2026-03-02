# G1 GC 完全指南：从入门到精通

> **版本**: 1.0  
> **目标**: 整合所有分散的GC文档，建立完整的知识体系和关联索引  
> **适用**: OpenJDK 11, G1 GC, -Xms8g -Xmx8g  
> **总文档数**: 整合24篇文档，约15万字

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文是 G1 GC 知识体系的**完全指南**：整合 24 篇专家级分析文档，建立从"对象分配"到"Full GC"的完整知识图谱；提供学习路径（入门→进阶→专家）、文档索引、关键概念速查表。

### 0.2 G1 GC 三大核心机制

| 机制 | 核心问题 | 关键文档 |
|------|---------|---------|
| Young GC | Eden 满了怎么办？ | 1-HeapRegion, 3-Object-Allocation, 9-CollectionSet-Evacuation |
| Mixed GC | Old 区怎么回收？ | 8-Concurrent-Marking, 7-G1Policy-Prediction-Model |
| Full GC | 兜底机制 | 10-Full-GC |

### 0.3 学习路径

**入门**（理解基本概念）：
1. HeapRegion（Region 化内存）
2. Object Allocation（对象分配路径）
3. WriteBarrier-CardTable（写屏障）

**进阶**（理解 GC 流程）：
4. RSet-Three-Level-Structure（记忆集）
5. Concurrent-Refinement（并发精炼）
6. Concurrent-Marking（并发标记）
7. CollectionSet-Evacuation（CSet 选择与 Evacuation）

**专家**（理解设计决策）：
8. G1Policy-Prediction-Model（预测模型）
9. Full-GC（兜底机制）
10. Expert-Analysis 系列（各组件深度分析）

---

---

## 目录

1. [知识地图](#一知识地图)
2. [学习路径推荐](#二学习路径推荐)
3. [核心概念速查](#三核心概念速查)
4. [详细内容索引](#四详细内容索引)
5. [实战案例索引](#五实战案例索引)
6. [源码对照表](#六源码对照表)

---

## 一、知识地图

### 1.1 G1 GC 整体架构图

```mermaid
graph TB
    subgraph "G1CollectedHeap 总控中心"
        G1H[G1CollectedHeap<br/>g1CollectedHeap.hpp]
    end
    
    subgraph "内存管理层"
        HR[HeapRegion<br/>heapRegion.hpp]
        HRM[HeapRegionManager<br/>heapRegionManager.hpp]
        HRTable[G1HeapRegionTable]
    end
    
    subgraph "对象分配层"
        GA[G1Allocator<br/>g1Allocator.hpp]
        MAR[MutatorAllocRegion]
        GAR[GCAllocRegion]
    end
    
    subgraph "引用追踪层"
        GRS[G1RemSet<br/>g1RemSet.hpp]
        HRRS[HeapRegionRemSet]
        ORT[OtherRegionsTable]
        PRT[PerRegionTable]
    end
    
    subgraph "屏障机制层"
        GBS[G1BarrierSet<br/>g1BarrierSet.hpp]
        GCT[G1CardTable<br/>g1CardTable.hpp]
        HRDC[HotCardCache]
    end
    
    subgraph "并发标记层"
        GCM[G1ConcurrentMark<br/>g1ConcurrentMark.hpp]
        GCMT[G1ConcurrentMarkThread]
        GCMTK[G1CMTask]
    end
    
    subgraph "回收策略层"
        GP[G1Policy<br/>g1Policy.hpp]
        GCS[G1CollectionSet]
        GCP[G1CollectionSetChooser]
    end
    
    G1H --> HR
    G1H --> HRM
    G1H --> GA
    G1H --> GRS
    G1H --> GBS
    G1H --> GCM
    G1H --> GP
    
    HRM --> HRTable
    HRM --> HR
    
    GA --> MAR
    GA --> GAR
    
    GRS --> HRRS
    HRRS --> ORT
    ORT --> PRT
    
    GBS --> GCT
    GBS --> HRDC
    
    GCM --> GCMT
    GCM --> GCMTK
    
    GP --> GCS
    GP --> GCP
```

### 1.2 数据流向图

```mermaid
flowchart LR
    subgraph "应用线程"
        A[对象分配<br/>new Object]
        B[写操作<br/>obj.field = x]
    end
    
    subgraph "屏障机制"
        C[写屏障<br/>G1BarrierSet]
        D[卡表标记<br/>CardTable]
        E[脏卡队列<br/>DirtyCardQueue]
    end
    
    subgraph "并发处理"
        F[Refinement线程<br/>G1ConcurrentRefine]
        G[RSet更新<br/>HeapRegionRemSet]
    end
    
    subgraph "GC决策"
        H[G1Policy<br/>预测模型]
        I[选择CSet<br/>CollectionSet]
    end
    
    subgraph "回收执行"
        J[Young GC<br/>Evacuation]
        K[并发标记<br/>ConcurrentMark]
        L[Mixed GC<br/>混合回收]
    end
    
    A --> |TLAB分配| M[HeapRegion]
    B --> C
    C --> D
    D --> E
    E --> F
    F --> G
    G --> H
    H --> I
    I --> J
    I --> K
    I --> L
    J --> M
    L --> M
```

### 1.3 核心组件关系图

```mermaid
classDiagram
    class G1CollectedHeap {
        +HeapRegionManager _hrm
        +G1Policy* _policy
        +G1RemSet* _rem_set
        +G1ConcurrentMark* _cm
        +G1CollectionSet _collection_set
        +initialize()
        +allocate_new_tlab()
        +do_collection_pause()
    }
    
    class HeapRegion {
        +HeapWord* _bottom
        +HeapWord* _top
        +HeapWord* _end
        +HeapRegionType _type
        +HeapRegionRemSet _rem_set
        +allocate()
        +object_iterate()
    }
    
    class G1RemSet {
        +G1CardTable* _card_table
        +G1HotCardCache* _hot_card_cache
        +G1ConcurrentRefine* _cr
        +add_region()
        +remove_region()
    }
    
    class HeapRegionRemSet {
        +OtherRegionsTable _other_regions
        +add_reference()
        +contains_reference()
    }
    
    class G1Policy {
        +G1Predictions _predictions
        +G1CollectionSetChooser _cset_chooser
        +record_pause_start()
        +record_pause_end()
        +choose_collection_set()
    }
    
    class G1ConcurrentMark {
        +G1CMBitMap _mark_bitmap
        +G1CMTask[] _tasks
        +concurrent_mark_cycle()
        +remark()
        +cleanup()
    }
    
    G1CollectedHeap --> HeapRegionManager
    G1CollectedHeap --> G1RemSet
    G1CollectedHeap --> G1Policy
    G1CollectedHeap --> G1ConcurrentMark
    
    HeapRegionManager --> HeapRegion
    HeapRegion --> HeapRegionRemSet
    G1RemSet --> HeapRegionRemSet
```

---

## 二、学习路径推荐

### 2.1 初学者路径（按顺序阅读）

```mermaid
graph LR
    A[0-G1-DataStructure-Map<br/>数据结构全景] --> B[1-HeapRegion-Deep-Dive<br/>Region详解]
    B --> C[3-Object-Allocation-Path<br/>对象分配]
    C --> D[4-WriteBarrier-CardTable<br/>写屏障]
    D --> E[5-RSet-Three-Level-Structure<br/>RSet结构]
    E --> F[11-Young-GC-Complete-STW-Flow<br/>Young GC流程]
    F --> G[18-GC-Log-Practice<br/>日志分析]
    G --> H[Troubleshooting-Series<br/>故障排查]
```

### 2.2 进阶路径（专题深入）

```mermaid
graph TB
    subgraph "并发标记专题"
        A[8-Concurrent-Marking] --> B[8A-Concurrent-Marking-Deep-Dive]
        B --> C[15-Reference-Processing]
    end
    
    subgraph "回收策略专题"
        D[7-G1Policy-Prediction-Model] --> E[9-CollectionSet-Evacuation]
        E --> F[16-Strategy-Adaptive-Adjustment]
    end
    
    subgraph "性能优化专题"
        G[6-Concurrent-Refinement] --> H[13-Write-Barrier-Assembly]
        H --> I[14-SafePoint-VMOperation]
    end
```

### 2.3 实战路径（问题导向）

```mermaid
graph LR
    A[问题现象] --> B{GC类型}
    B -->|Young GC频繁| C[02-GC-Frequent-Case-Study]
    B -->|Full GC| D[03-Full-GC-Case-Study]
    B -->|内存泄漏| E[01-Memory-Leak-Case-Study]
    B -->|大对象| F[04-Humongous-Object-Case-Study]
    
    C --> G[19-GC-Troubleshooting-Deep-Dive]
    D --> G
    E --> G
    F --> G
```

---

## 三、核心概念速查

### 3.1 Region类型与转换

```mermaid
stateDiagram-v2
    [*] --> Free: 初始化
    Free --> Eden: 分配Eden对象
    Free --> Humongous: 分配大对象
    
    Eden --> Survivor: Young GC后存活
    Eden --> Old: 晋升
    
    Survivor --> Survivor: 多次Young GC存活
    Survivor --> Old: 达到晋升阈值
    
    Old --> Free: Mixed GC回收
    Humongous --> Free: Full GC回收
    
    note right of Eden
        新对象分配
        触发Young GC
    end note
    
    note right of Old
        长期存活对象
        触发Mixed GC
    end note
```

### 3.2 GC触发条件

```mermaid
flowchart TD
    A[对象分配] --> B{Eden空间足够?}
    B -->|是| C[直接分配]
    B -->|否| D[触发Young GC]
    
    D --> E{GC后空间足够?}
    E -->|是| C
    E -->|否| F[触发Full GC]
    
    G[老年代使用率] --> H{超过阈值?}
    H -->|是| I[触发并发标记]
    I --> J[标记完成] --> K[触发Mixed GC]
    
    L[Humongous分配] --> M{连续Region足够?}
    M -->|否| F
```

### 3.3 记忆集(RSet)查询流程

```mermaid
sequenceDiagram
    participant GC as GC线程
    participant HRRS as HeapRegionRemSet
    participant ORT as OtherRegionsTable
    participant PRT as PerRegionTable
    participant Heap as 目标Region
    
    GC->>HRRS: 查询谁引用了我?
    HRRS->>ORT: get_rem_set(region_id)
    
    alt 稀疏表
        ORT->>PRT: 查询稀疏PRT
        PRT-->>GC: 返回引用卡片列表
    else 细粒度表
        ORT->>PRT: 查询细粒度PRT
        PRT-->>GC: 返回位图
    else 粗粒度
        ORT-->>GC: 返回整个Region
    end
    
    GC->>Heap: 扫描对应卡片
    Heap-->>GC: 返回存活对象
```

---

## 四、详细内容索引

### 4.1 数据结构层

| 组件 | 核心类 | 文档 | 关键字段 | 大小 |
|------|--------|------|----------|------|
| **Region管理** | HeapRegion | [1-HeapRegion-Deep-Dive](1-HeapRegion-Deep-Dive.md) | `_bottom/_top/_end` | 4MB |
| | HeapRegionManager | [2-HeapRegionManager-Deep-Dive](2-HeapRegionManager-Deep-Dive.md) | `_regions/_free_list` | - |
| | G1HeapRegionTable | [2-HeapRegionManager-Deep-Dive](2-HeapRegionManager-Deep-Dive.md) | `_base/_length` | 16KB |
| **对象分配** | G1Allocator | [3-Object-Allocation-Path](3-Object-Allocation-Path.md) | `_mutator_alloc_regions` | - |
| | MutatorAllocRegion | [3-Object-Allocation-Path](3-Object-Allocation-Path.md) | `_top/_end` | - |
| **引用追踪** | G1RemSet | [12-G1RemSet-Complete-Flow](12-G1RemSet-Complete-Flow.md) | `_card_table/_hot_card_cache` | - |
| | HeapRegionRemSet | [5-RSet-Three-Level-Structure](5-RSet-Three-Level-Structure.md) | `_other_regions` | ~1KB |
| | OtherRegionsTable | [5-RSet-Three-Level-Structure](5-RSet-Three-Level-Structure.md) | `_fine_grain_partitions` | - |
| | PerRegionTable | [5-RSet-Three-Level-Structure](5-RSet-Three-Level-Structure.md) | `_bm/_cards` | ~4KB |

### 4.2 屏障机制层

| 组件 | 核心类 | 文档 | 关键方法 | 触发时机 |
|------|--------|------|----------|----------|
| **写屏障** | G1BarrierSet | [4-WriteBarrier-CardTable](4-WriteBarrier-CardTable.md) | `write_ref_field_pre/post` | 引用字段赋值 |
| | G1CardTable | [4-WriteBarrier-CardTable](4-WriteBarrier-CardTable.md) | `inline_write_ref_field_post` | 标记脏卡 |
| | G1HotCardCache | [6-Concurrent-Refinement](6-Concurrent-Refinement.md) | `insert/flush` | 热点卡缓存 |
| **并发精炼** | G1ConcurrentRefine | [6-Concurrent-Refinement](6-Concurrent-Refinement.md) | `refine_card/concurrent_refine` | 异步处理脏卡 |
| | G1RefineThread | [6-Concurrent-Refinement](6-Concurrent-Refinement.md) | `run_service` | 后台线程 |

### 4.3 并发标记层

| 组件 | 核心类 | 文档 | 关键阶段 | 耗时 |
|------|--------|------|----------|------|
| **并发标记** | G1ConcurrentMark | [8-Concurrent-Marking](8-Concurrent-Marking.md) | `concurrent_mark_cycle` | - |
| | G1CMTask | [8A-Concurrent-Marking-Deep-Dive](8A-Concurrent-Marking-Deep-Dive.md) | `do_marking_step` | - |
| | G1CMBitMap | [8-Concurrent-Marking](8-Concurrent-Marking.md) | `mark/par_mark` | - |
| **阶段详解** | - | [8A-Concurrent-Marking-Deep-Dive](8A-Concurrent-Marking-Deep-Dive.md) | Initial Mark | <10ms |
| | - | - | Root Region Scanning | ~100ms |
| | - | - | Concurrent Mark | 数秒 |
| | - | - | Remark | <100ms |
| | - | - | Cleanup | <10ms |

### 4.4 回收策略层

| 组件 | 核心类 | 文档 | 关键算法 | 参数 |
|------|--------|------|----------|------|
| **策略决策** | G1Policy | [7-G1Policy-Prediction-Model](7-G1Policy-Prediction-Model.md) | `record_pause/revise_young_list` | - |
| | G1Predictions | [7-G1Policy-Prediction-Model](7-G1Policy-Prediction-Model.md) | `predict_xxx` | - |
| **回收集合** | G1CollectionSet | [9-CollectionSet-Evacuation](9-CollectionSet-Evacuation.md) | `add_old_region` | - |
| | G1CollectionSetChooser | [9-CollectionSet-Evacuation](9-CollectionSet-Evacuation.md) | `build/choose` | - |
| **自适应** | G1AdaptivePolicy | [16-Strategy-Adaptive-Adjustment](16-Strategy-Adaptive-Adjustment.md) | `update_xxx` | - |

### 4.5 GC执行层

| GC类型 | 文档 | 触发条件 | 回收范围 | 特点 |
|--------|------|----------|----------|------|
| **Young GC** | [11-Young-GC-Complete-STW-Flow](11-Young-GC-Complete-STW-Flow.md) | Eden满 | Eden+Survivor | STW, 并行 |
| **Mixed GC** | [9-CollectionSet-Evacuation](9-CollectionSet-Evacuation.md) | 标记后 | Eden+部分Old | STW, 并行 |
| **Full GC** | [10-Full-GC](10-Full-GC.md) | 空间不足 | 整个堆 | STW, 单线程 |
| **并发标记** | [8-Concurrent-Marking](8-Concurrent-Marking.md) | 老年代阈值 | 仅标记 | 并发 |

---

## 五、实战案例索引

### 5.1 故障排查系列

```mermaid
mindmap
  root((GC故障排查))
    内存泄漏
      静态缓存泄漏
        文档[01-Memory-Leak-Case-Study]
        日志[gc-memory-leak.log]
        根因[HashMap无限制增长]
        解决[Guava Cache]
    GC频繁
      小堆高分配
        文档[02-GC-Frequent-Case-Study]
        日志[gc-frequent.log]
        根因[128MB堆+140MB/s分配]
        解决[增大堆/UseContainerSupport]
    Full GC
      System.gc触发
        文档[03-Full-GC-Case-Study]
        日志[gc-full-gc.log]
        根因[显式调用System.gc]
        解决[DisableExplicitGC]
    Humongous对象
      大对象分配
        文档[04-Humongous-Object-Case-Study]
        日志[gc-humongous.log]
        根因[RegionSize过小]
        解决[增大RegionSize]
```

### 5.2 问题诊断决策树

```mermaid
flowchart TD
    A[GC问题] --> B{症状}
    
    B -->|堆持续增长| C[内存泄漏?]
    C --> C1[检查Old Region趋势]
    C --> C2[MAT分析Heap Dump]
    C --> C3[检查静态集合类]
    C1 & C2 & C3 --> C4[01-Memory-Leak-Case-Study]
    
    B -->|GC间隔<1s| D[GC频繁?]
    D --> D1[检查堆大小]
    D --> D2[检查分配速率]
    D --> D3[检查容器配置]
    D1 & D2 & D3 --> D4[02-GC-Frequent-Case-Study]
    
    B -->|Full GC| E[Full GC触发?]
    E --> E1[检查触发原因]
    E --> E2[检查堆/元空间]
    E --> E3[检查System.gc]
    E1 & E2 & E3 --> E4[03-Full-GC-Case-Study]
    
    B -->|大对象| F[Humongous对象?]
    F --> F1[检查RegionSize]
    F --> F2[检查对象大小分布]
    F1 & F2 --> F3[04-Humongous-Object-Case-Study]
```

---

## 六、源码对照表

### 6.1 核心源码文件索引

| 功能模块 | 头文件(.hpp) | 实现文件(.cpp) | 行数 | 文档 |
|----------|-------------|---------------|------|------|
| **总控** | g1CollectedHeap | g1CollectedHeap | 3000+ | [0-G1-DataStructure-Map](0-G1-DataStructure-Map.md) |
| **Region** | heapRegion | heapRegion | 1500+ | [1-HeapRegion-Deep-Dive](1-HeapRegion-Deep-Dive.md) |
| **Region管理** | heapRegionManager | heapRegionManager | 800+ | [2-HeapRegionManager-Deep-Dive](2-HeapRegionManager-Deep-Dive.md) |
| **分配器** | g1Allocator | g1Allocator | 600+ | [3-Object-Allocation-Path](3-Object-Allocation-Path.md) |
| **写屏障** | g1BarrierSet | g1BarrierSet | 500+ | [4-WriteBarrier-CardTable](4-WriteBarrier-CardTable.md) |
| **卡表** | g1CardTable | g1CardTable | 400+ | [4-WriteBarrier-CardTable](4-WriteBarrier-CardTable.md) |
| **RSet** | g1RemSet/heapRegionRemSet | g1RemSet | 2000+ | [12-G1RemSet-Complete-Flow](12-G1RemSet-Complete-Flow.md) |
| **并发标记** | g1ConcurrentMark | g1ConcurrentMark | 2500+ | [8-Concurrent-Marking](8-Concurrent-Marking.md) |
| **策略** | g1Policy | g1Policy | 1500+ | [7-G1Policy-Prediction-Model](7-G1Policy-Prediction-Model.md) |
| **CSet** | g1CollectionSet | g1CollectionSet | 800+ | [9-CollectionSet-Evacuation](9-CollectionSet-Evacuation.md) |
| **Young GC** | g1YoungCollector | g1YoungCollector | 1000+ | [11-Young-GC-Complete-STW-Flow](11-Young-GC-Complete-STW-Flow.md) |
| **Full GC** | g1FullCollector | g1FullCollector | 800+ | [10-Full-GC](10-Full-GC.md) |

### 6.2 关键函数调用链

```mermaid
flowchart LR
    subgraph "对象分配"
        A1[allocate_instance] --> A2[common_mem_allocate_init]
        A2 --> A3[attempt_allocation]
        A3 --> A4[allocate_new_tlab]
        A4 --> A5[par_allocate]
    end
    
    subgraph "写屏障"
        B1[write_ref_field_post] --> B2[inline_write_ref_field_post]
        B2 --> B3[enqueue]
        B3 --> B4[dirty_card_queue]
    end
    
    subgraph "Young GC"
        C1[do_collection_pause] --> C2[gc_prologue]
        C2 --> C3[evacuate_collection_set]
        C3 --> C4[g1_process_roots]
        C4 --> C5[gc_epilogue]
    end
    
    subgraph "并发标记"
        D1[concurrent_mark_cycle] --> D2[initial_mark]
        D2 --> D3[concurrent_mark]
        D3 --> D4[remark]
        D4 --> D5[cleanup]
    end
```

---

## 附录：快速参考

### A. JVM参数速查

```bash
# 基础配置
-Xms8g -Xmx8g                    # 堆内存
-XX:+UseG1GC                     # 使用G1
-XX:MaxGCPauseMillis=100         # 目标停顿时间

# Region配置
-XX:G1HeapRegionSize=4m          # Region大小(1-32m)

# GC日志
-Xlog:gc*:file=gc.log:time,uptime,level,tags

# 问题排查
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=/path/to/dump.hprof
-XX:+DisableExplicitGC           # 禁止System.gc()
```

### B. GC日志关键模式

```bash
# 查看GC频率
grep "Pause Young\|Pause Full" gc.log | wc -l

# 查看Old Region增长
grep "Old regions" gc.log

# 查看GC耗时分布
grep "Pause Young" gc.log | awk '{print $NF}'

# 统计Full GC次数
grep -c "Pause Full" gc.log
```

---

**文档版本**: 1.0  
**最后更新**: 2026-02-26  
**文档总数**: 24篇  
**总字数**: 约15万字
