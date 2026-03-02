# E.6 GC 追踪器初始化 - 深度分析

> 源码位置：`gcTrace.cpp`、`gcTrace.hpp`、`gcTraceSend.cpp`
> G1NewTracer 的初始化：注册 JFR 类型常量，为后续 GC 事件报告做准备

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文是对 **E.6 GC 追踪器初始化 - 深度分析** 的深度源码分析：从数据结构到算法流程，逐层剖析其实现原理，并通过 GDB 验证关键结论。

### 0.2 为什么需要？

深入理解 JVM 内部实现，不仅能帮助排查生产问题，更能建立对 JVM 行为的精确预测能力——知道『为什么』比知道『是什么』更重要。

### 0.3 怎么解决？

采用「数据结构 → 算法流程 → GDB 验证」三步法：先完整分析所有涉及的数据结构（字段含义/sizeof/生命周期），再分析算法流程（每步有 why），最后用 GDB 实际验证关键结论。

### 0.4 为什么这样设计？

JVM 的每个设计决策都有其历史背景和性能考量。本文在分析每个关键设计时，都会解释「为什么这样而不是那样」，帮助读者建立设计直觉。

---


## 1. 功能定位

### 一句话说明
**`_gc_tracer_stw->initialize()` 注册 G1 特有的 JFR 类型常量**，使 JFR 能正确记录和展示 G1 GC 的 Region 类型和 YC（Young Collection）类型。

### 在整体流程中的位置
```
G1CollectedHeap 构造函数
│
├── 初始化列表：_gc_tracer_stw(new G1NewTracer())
│   └── G1NewTracer() : YoungGCTracer(G1New) {}
│
└── 构造函数体：
    ├── ... 前面的初始化 ...
    ├── _gc_tracer_stw->initialize();  ← 【本节分析】
    │   └── register_jfr_type_constants()
    │       ├── 注册 G1HeapRegionTypeConstant
    │       └── 注册 G1YCTypeConstant
    │
    └── guarantee(_task_queues != NULL, ...);
```

---

## 2. G1NewTracer 类层次结构

### 2.1 类继承关系

```
ResourceObj
│
└── GCTracer
    │
    │  • _shared_gc_info: SharedGCInfo
    │  • report_gc_start()
    │  • report_gc_end()
    │  • report_gc_heap_summary()
    │
    ├── YoungGCTracer
    │   │
    │   │  • _tenuring_threshold
    │   │  • report_promotion_failed()
    │   │  • report_tenuring_threshold()
    │   │  • send_young_gc_event()
    │   │
    │   └── G1NewTracer  ← 【本节重点】
    │       │
    │       │  • _g1_young_gc_info: G1YoungGCInfo
    │       │  • initialize()                  ← 注册 JFR 类型
    │       │  • report_yc_type()
    │       │  • report_evacuation_info()
    │       │  • report_evacuation_failed()
    │       │  • send_g1_young_gc_event()
    │       │  • send_evacuation_info_event()
    │       │
    │       └── 用于 G1 Young GC / Mixed GC
    │
    └── OldGCTracer
        │
        └── G1FullGCTracer
            └── 用于 G1 Full GC
```

### 2.2 G1NewTracer 定义

```cpp
// gcTrace.hpp:243-291
class G1NewTracer : public YoungGCTracer {
    G1YoungGCInfo _g1_young_gc_info;  // GC 类型信息

public:
    G1NewTracer() : YoungGCTracer(G1New) {}

    void initialize();  // 注册 JFR 类型常量
    
    // 报告方法
    void report_yc_type(G1YCType type);
    void report_evacuation_info(EvacuationInfo* info);
    void report_evacuation_failed(EvacuationFailedInfo& ef_info);
    void report_evacuation_statistics(...);
    void report_basic_ihop_statistics(...);
    void report_adaptive_ihop_statistics(...);

private:
    // JFR 事件发送方法
    void send_g1_young_gc_event();
    void send_evacuation_info_event(EvacuationInfo* info);
    void send_evacuation_failed_event(const EvacuationFailedInfo& ef_info) const;
    void send_young_evacuation_statistics(...) const;
    void send_old_evacuation_statistics(...) const;
    void send_basic_ihop_statistics(...);
    void send_adaptive_ihop_statistics(...);
};
```

---

## 3. initialize() 方法详解

### 3.1 源码分析

```cpp
// gcTrace.cpp:233-235
void G1NewTracer::initialize() {
    JFR_ONLY(register_jfr_type_constants());
}
```

**关键点**：
- `JFR_ONLY()` 宏：仅在启用 JFR 时编译
- 整个方法只做一件事：注册 JFR 类型常量

### 3.2 register_jfr_type_constants()

```cpp
// gcTrace.cpp:223-229
static void register_jfr_type_constants() {
    // 注册 G1HeapRegionType 常量
    JfrSerializer::register_serializer(TYPE_G1HEAPREGIONTYPE, 
                                       false,   // not required
                                       true,    // thread_local_cache
                                       new G1HeapRegionTypeConstant());

    // 注册 G1YCType 常量
    JfrSerializer::register_serializer(TYPE_G1YCTYPE, 
                                       false,   // not required
                                       true,    // thread_local_cache
                                       new G1YCTypeConstant());
}
```

---

## 4. JFR 类型常量详解

### 4.1 G1HeapRegionTypeConstant

```cpp
// gcTrace.cpp:199-209
class G1HeapRegionTypeConstant : public JfrSerializer {
public:
    void serialize(JfrCheckpointWriter& writer) {
        static const u4 nof_entries = G1HeapRegionTraceType::G1HeapRegionTypeEndSentinel;
        writer.write_count(nof_entries);  // 写入条目数量
        
        for (u4 i = 0; i < nof_entries; ++i) {
            writer.write_key(i);           // 写入 ID
            writer.write(G1HeapRegionTraceType::to_string(
                (G1HeapRegionTraceType::Type)i));  // 写入名称
        }
    }
};
```

### 4.2 G1HeapRegionTraceType 枚举

```cpp
// g1HeapRegionTraceType.hpp:33-44
enum Type {
    Free,               // 0 - 空闲 Region
    Eden,               // 1 - 伊甸园
    Survivor,           // 2 - 幸存者
    StartsHumongous,    // 3 - 巨型对象起始
    ContinuesHumongous, // 4 - 巨型对象续接
    Old,                // 5 - 老年代
    Pinned,             // 6 - 固定（不参与 GC）
    OpenArchive,        // 7 - 开放归档
    ClosedArchive,      // 8 - 关闭归档
    G1HeapRegionTypeEndSentinel  // 9 - 哨兵值
};
```

### 4.3 G1YCTypeConstant

```cpp
// gcTrace.cpp:211-221
class G1YCTypeConstant : public JfrSerializer {
public:
    void serialize(JfrCheckpointWriter& writer) {
        static const u4 nof_entries = G1YCTypeEndSentinel;
        writer.write_count(nof_entries);
        
        for (u4 i = 0; i < nof_entries; ++i) {
            writer.write_key(i);
            writer.write(G1YCTypeHelper::to_string((G1YCType)i));
        }
    }
};
```

### 4.4 G1YCType 枚举

```cpp
// g1YCTypes.hpp:30-36
enum G1YCType {
    Normal,              // 0 - 普通 Young GC
    InitialMark,         // 1 - 初始标记（并发标记开始）
    DuringMarkOrRebuild, // 2 - 标记过程中
    Mixed,               // 3 - 混合 GC
    G1YCTypeEndSentinel  // 4 - 哨兵值
};
```

---

## 5. G1 GC 相关 JFR 事件

### 5.1 事件类型表

| 事件类 | 描述 | 触发时机 |
|--------|------|----------|
| `EventG1GarbageCollection` | G1 GC 事件 | Young/Mixed GC 结束 |
| `EventEvacuationInformation` | 疏散信息 | GC 结束后 |
| `EventEvacuationFailed` | 疏散失败 | To-space exhausted |
| `EventG1HeapSummary` | 堆摘要 | GC 前后 |
| `EventG1HeapRegionTypeChange` | Region 类型变化 | Region 类型改变时 |
| `EventG1MMU` | MMU 追踪 | GC 后 |
| `EventG1EvacuationYoungStatistics` | Young 疏散统计 | GC 结束 |
| `EventG1EvacuationOldStatistics` | Old 疏散统计 | Mixed GC 结束 |
| `EventG1BasicIHOP` | 基本 IHOP | IHOP 计算后 |
| `EventG1AdaptiveIHOP` | 自适应 IHOP | IHOP 调整后 |

### 5.2 EventG1GarbageCollection 事件

```cpp
// gcTraceSend.cpp:190-199
void G1NewTracer::send_g1_young_gc_event() {
    EventG1GarbageCollection e(UNTIMED);
    if (e.should_commit()) {
        e.set_gcId(GCId::current());          // GC ID
        e.set_type(_g1_young_gc_info.type()); // Normal/InitialMark/Mixed
        e.set_starttime(_shared_gc_info.start_timestamp());
        e.set_endtime(_shared_gc_info.end_timestamp());
        e.commit();
    }
}
```

### 5.3 EventEvacuationInformation 事件

```cpp
// gcTraceSend.cpp:212-226
void G1NewTracer::send_evacuation_info_event(EvacuationInfo* info) {
    EventEvacuationInformation e;
    if (e.should_commit()) {
        e.set_gcId(GCId::current());
        e.set_cSetRegions(info->collectionset_regions());     // CSet Region 数
        e.set_cSetUsedBefore(info->collectionset_used_before()); // CSet 使用前
        e.set_cSetUsedAfter(info->collectionset_used_after());   // CSet 使用后
        e.set_allocationRegions(info->allocation_regions());     // 分配 Region 数
        e.set_allocationRegionsUsedBefore(info->alloc_regions_used_before());
        e.set_allocationRegionsUsedAfter(
            info->alloc_regions_used_before() + info->bytes_copied());
        e.set_bytesCopied(info->bytes_copied());     // 复制字节数
        e.set_regionsFreed(info->regions_freed());   // 释放 Region 数
        e.commit();
    }
}
```

### 5.4 EventEvacuationFailed 事件

```cpp
// gcTraceSend.cpp:228-235
void G1NewTracer::send_evacuation_failed_event(const EvacuationFailedInfo& ef_info) const {
    EventEvacuationFailed e;
    if (e.should_commit()) {
        e.set_gcId(GCId::current());
        e.set_evacuationFailed(to_struct(ef_info));  // 失败统计
        e.commit();
    }
}

// 转换结构体
static JfrStructCopyFailed to_struct(const CopyFailedInfo& cf_info) {
    JfrStructCopyFailed failed_info;
    failed_info.set_objectCount(cf_info.failed_count());    // 失败对象数
    failed_info.set_firstSize(cf_info.first_size());        // 第一个对象大小
    failed_info.set_smallestSize(cf_info.smallest_size());  // 最小对象大小
    failed_info.set_totalSize(cf_info.total_size());        // 总大小
    return failed_info;
}
```

---

## 6. 整体流程图

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                      G1NewTracer 初始化与使用流程                             │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                               │
│  【初始化阶段】                                                               │
│  ─────────────────────────────────────────────────────────────────────────   │
│                                                                               │
│  G1CollectedHeap 构造函数                                                     │
│  │                                                                            │
│  ├── _gc_tracer_stw = new G1NewTracer()                                      │
│  │   │                                                                        │
│  │   └── G1NewTracer() : YoungGCTracer(G1New) {}                             │
│  │       • _shared_gc_info.set_name(G1New)                                   │
│  │       • _g1_young_gc_info 默认初始化                                      │
│  │                                                                            │
│  └── _gc_tracer_stw->initialize()                                            │
│      │                                                                        │
│      └── JFR_ONLY(register_jfr_type_constants())                             │
│          │                                                                    │
│          ├── JfrSerializer::register_serializer(                             │
│          │       TYPE_G1HEAPREGIONTYPE,                                      │
│          │       new G1HeapRegionTypeConstant())                             │
│          │   │                                                                │
│          │   └── 注册 9 种 Region 类型：                                     │
│          │       Free, Eden, Survivor, StartsHumongous,                      │
│          │       ContinuesHumongous, Old, Pinned,                            │
│          │       OpenArchive, ClosedArchive                                  │
│          │                                                                    │
│          └── JfrSerializer::register_serializer(                             │
│                  TYPE_G1YCTYPE,                                              │
│                  new G1YCTypeConstant())                                     │
│              │                                                                │
│              └── 注册 4 种 YC 类型：                                         │
│                  Normal, InitialMark, DuringMarkOrRebuild, Mixed             │
│                                                                               │
│  ─────────────────────────────────────────────────────────────────────────   │
│                                                                               │
│  【运行时使用】                                                               │
│  ─────────────────────────────────────────────────────────────────────────   │
│                                                                               │
│  G1 Young GC 开始                                                            │
│  │                                                                            │
│  ├── _gc_tracer_stw->report_gc_start(cause, timestamp)                       │
│  │   └── 记录 GC 开始时间和原因                                              │
│  │                                                                            │
│  ├── _gc_tracer_stw->report_yc_type(type)                                    │
│  │   └── 设置 YC 类型：Normal / InitialMark / Mixed                          │
│  │                                                                            │
│  ├── ... GC 执行 ...                                                         │
│  │                                                                            │
│  ├── 如果疏散失败：                                                          │
│  │   └── _gc_tracer_stw->report_evacuation_failed(ef_info)                   │
│  │       └── send_evacuation_failed_event()                                  │
│  │           └── EventEvacuationFailed → JFR                                 │
│  │                                                                            │
│  ├── _gc_tracer_stw->report_evacuation_info(evac_info)                       │
│  │   └── send_evacuation_info_event()                                        │
│  │       └── EventEvacuationInformation → JFR                                │
│  │                                                                            │
│  └── _gc_tracer_stw->report_gc_end(timestamp, time_partitions)               │
│      │                                                                        │
│      ├── send_g1_young_gc_event()                                            │
│      │   └── EventG1GarbageCollection → JFR                                  │
│      │                                                                        │
│      └── send_young_gc_event()（父类）                                       │
│          └── EventYoungGarbageCollection → JFR                               │
│                                                                               │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 7. 生产环境实践

### 7.1 启用 JFR 记录 G1 GC 事件

```bash
# 方式 1：命令行启动 JFR
java -XX:+UseG1GC \
     -XX:StartFlightRecording=filename=gc.jfr,duration=60s,settings=gc \
     -jar myapp.jar

# 方式 2：使用 jcmd 动态启动
jcmd <pid> JFR.start filename=gc.jfr duration=60s settings=gc

# 方式 3：自定义配置
java -XX:+UseG1GC \
     -XX:StartFlightRecording=filename=gc.jfr,settings=custom.jfc \
     -jar myapp.jar
```

### 7.2 GC 相关 JFR 设置（gc.jfc 示例）

```xml
<configuration>
    <!-- G1 GC 事件 -->
    <event name="jdk.G1GarbageCollection">
        <setting name="enabled">true</setting>
    </event>
    
    <!-- 疏散信息 -->
    <event name="jdk.EvacuationInformation">
        <setting name="enabled">true</setting>
    </event>
    
    <!-- 疏散失败 -->
    <event name="jdk.EvacuationFailed">
        <setting name="enabled">true</setting>
    </event>
    
    <!-- 堆摘要 -->
    <event name="jdk.G1HeapSummary">
        <setting name="enabled">true</setting>
    </event>
    
    <!-- Region 类型变化（高开销，按需启用）-->
    <event name="jdk.G1HeapRegionTypeChange">
        <setting name="enabled">false</setting>
    </event>
</configuration>
```

### 7.3 JFR 事件字段解读

**jdk.G1GarbageCollection**:
```
字段           | 含义
-------------- | -------------------------
gcId           | GC 序号
type           | Normal/InitialMark/Mixed
startTime      | GC 开始时间
duration       | GC 持续时间
```

**jdk.EvacuationInformation**:
```
字段                       | 含义
-------------------------- | -------------------------
cSetRegions                | CSet 中的 Region 数量
cSetUsedBefore             | GC 前 CSet 使用量
cSetUsedAfter              | GC 后 CSet 使用量
bytesCopied                | 复制的字节数
regionsFreed               | 释放的 Region 数量
```

**jdk.EvacuationFailed**:
```
字段                | 含义
------------------- | -------------------------
objectCount         | 失败的对象数量
firstSize           | 第一个失败对象的大小
smallestSize        | 最小失败对象的大小
totalSize           | 所有失败对象的总大小
```

### 7.4 使用 JMC 分析 JFR 文件

```
1. 打开 JDK Mission Control (JMC)
2. File → Open File → 选择 gc.jfr
3. 导航到 "Garbage Collections" 页面
4. 可以看到：
   - GC 暂停时间分布
   - GC 类型统计（Normal/Mixed）
   - 疏散效率（复制字节数 vs 释放空间）
   - 疏散失败详情
```

### 7.5 监控最佳实践

| 监控项 | 健康指标 | 异常处理 |
|--------|----------|----------|
| GC 类型分布 | Normal 占主导，偶尔 Mixed | Mixed 过多 → 检查 IHOP |
| 疏散失败 | 0 | > 0 → 增大 G1ReservePercent |
| bytesCopied/cSetUsedBefore | > 50% | < 30% → 存活率过低，检查对象生命周期 |
| regionsFreed | 与 cSetRegions 接近 | 差距大 → 疏散失败 |

---

## 8. 与 D.3 的关联

之前分析的 **D.3 GC 计时与追踪** 创建了 `_gc_timer_stw` 和 `_gc_tracer_stw`：

```
D.3 创建对象：
├── _gc_timer_stw = new STWGCTimer()
│   └── 记录 GC 各阶段耗时
│
└── _gc_tracer_stw = new G1NewTracer()
    └── 报告 JFR 事件

E.6 初始化 Tracer：
└── _gc_tracer_stw->initialize()
    └── 注册 JFR 类型常量
```

两者配合：
- `STWGCTimer` 记录时间数据
- `G1NewTracer` 将数据报告为 JFR 事件
- JFR 类型常量使事件数据可读（将 ID 映射为字符串）

---

## 9. 总结

### 9.1 核心概念

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│  _gc_tracer_stw->initialize() 做了什么？                                 │
│  ────────────────────────────────────────────────────────────────────    │
│                                                                          │
│  注册两个 JFR 类型常量序列化器：                                         │
│                                                                          │
│  1. G1HeapRegionTypeConstant                                             │
│     └── 9 种 Region 类型：Free/Eden/Survivor/Old/Humongous/...          │
│                                                                          │
│  2. G1YCTypeConstant                                                     │
│     └── 4 种 YC 类型：Normal/InitialMark/DuringMark/Mixed               │
│                                                                          │
│  这些常量使 JFR 能够：                                                   │
│  • 正确解析 G1 事件中的类型字段                                          │
│  • 在 JMC 中显示可读的类型名称（而非数字 ID）                            │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 9.2 G1NewTracer 职责

| 方法 | 触发时机 | 生成事件 |
|------|----------|----------|
| `report_gc_start()` | GC 开始 | - |
| `report_yc_type()` | 确定 GC 类型后 | - |
| `report_evacuation_info()` | GC 结束 | EventEvacuationInformation |
| `report_evacuation_failed()` | 疏散失败 | EventEvacuationFailed |
| `report_gc_end()` | GC 结束 | EventG1GarbageCollection |

### 9.3 性能影响

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│  initialize() 的性能影响：                                               │
│  ────────────────────────────────────────────────────────────────────    │
│                                                                          │
│  时机：JVM 启动时执行一次                                                │
│  开销：极低（仅注册两个序列化器）                                        │
│  内存：两个小对象（~100 字节）                                           │
│                                                                          │
│  JFR 事件记录的开销：                                                    │
│  • should_commit() 检查：几乎为零                                        │
│  • 事件写入：仅在 JFR 启用时才有开销                                     │
│  • 条件编译：JFR_ONLY() 在无 JFR 时完全移除                              │
│                                                                          │
│  生产环境建议：                                                          │
│  • 默认启用核心 GC 事件（低开销）                                        │
│  • Region 类型变化事件按需启用（高频率）                                 │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 待分析节点更新

| 节点 | 主题 | 状态 |
|------|------|------|
| **E.6.1** | JFR 事件注册 | ✅ |
| - | G1HeapRegionTypeConstant | ✅ |
| - | G1YCTypeConstant | ✅ |
| **E.6.2** | 性能计数器初始化 | ✅ |
| - | 实际上通过 JFR 事件实现 | ✅ |
| - | 与 STWGCTimer 配合使用 | ✅ |
