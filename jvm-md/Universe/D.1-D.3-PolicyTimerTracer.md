# D.1/D.2/D.3 策略、监控与追踪

> **分析条件**：8GB 堆（-Xms8g -Xmx8g），G1 GC，4MB Region
> **源码位置**：`g1CollectedHeap.cpp:1454-1463`

---

## D.1 策略与线程相关

### 源码

```cpp
// g1CollectedHeap.cpp:1454-1456
_young_gen_sampling_thread(NULL),
_collector_policy(collector_policy),
_soft_ref_policy(),
```

### _young_gen_sampling_thread

**采样线程**：周期性采样年轻代 RSet 大小，用于预测 GC 暂停时间。

```cpp
// g1YoungRemSetSamplingThread.hpp:42
class G1YoungRemSetSamplingThread: public ConcurrentGCThread {
  Monitor _monitor;
  double _vtime_accum;  // 累积虚拟时间
  
  void sample_young_list_rs_lengths();  // 采样年轻代 RSet 长度
  void sleep_before_next_cycle();       // 等待下一次采样
};
```

**工作流程**：

```
┌─────────────────────────────────────────────────────────┐
│  G1YoungRemSetSamplingThread                             │
│                                                          │
│  while (!should_terminate()) {                          │
│    1. sample_young_list_rs_lengths();  // 采样 RSet     │
│       └── 遍历年轻代 Region                              │
│       └── 累加 RSet 条目数                               │
│       └── 更新预测模型                                   │
│                                                          │
│    2. sleep(G1ConcRefinementServiceIntervalMillis);     │
│       └── 默认 300ms                                     │
│  }                                                       │
└─────────────────────────────────────────────────────────┘
```

**为什么需要采样？**

- RSet 大小直接影响 Update RS 阶段耗时
- 采样数据用于预测暂停时间
- 帮助 G1 决定 CSet 大小

### _soft_ref_policy

**软引用策略**：控制何时清理软引用。

```cpp
// softRefPolicy.hpp:30
class SoftRefPolicy {
  bool _should_clear_all_soft_refs;  // 是否清理所有软引用
  bool _all_soft_refs_clear;         // 软引用是否已全部清理
};
```

**清理时机**：
- Full GC 时
- 内存不足时（由 `SoftRefLRUPolicyMSPerMB` 控制）

```bash
# 软引用保留策略
-XX:SoftRefLRUPolicyMSPerMB=1000  # 每 MB 空闲内存保留 1 秒
```

**计算公式**：
```
保留时间 = free_heap_MB × SoftRefLRUPolicyMSPerMB
8GB 堆空闲 4GB → 保留 4000 秒 ≈ 66 分钟
```

---

## D.2 JMX 监控相关

### 源码

```cpp
// g1CollectedHeap.cpp:1457-1462
_memory_manager("G1 Young Generation", "end of minor GC"),
_full_gc_memory_manager("G1 Old Generation", "end of major GC"),
_eden_pool(NULL),
_survivor_pool(NULL),
_old_pool(NULL),
```

### GCMemoryManager

**JMX 中的 MemoryManagerMXBean 实现**。

```cpp
// memoryManager.hpp:136
class GCMemoryManager : public MemoryManager {
  size_t       _num_collections;       // GC 次数
  elapsedTimer _accumulated_timer;     // 累积 GC 时间
  GCStatInfo*  _last_gc_stat;          // 上次 GC 统计
  GCStatInfo*  _current_gc_stat;       // 当前 GC 统计
  int          _num_gc_threads;        // GC 线程数
  const char*  _gc_end_message;        // GC 结束消息
};
```

**G1 的两个 MemoryManager**：

| 管理器 | 名称 | 管理的池 | 触发时机 |
|--------|------|----------|----------|
| `_memory_manager` | "G1 Young Generation" | Eden, Survivor | Young GC |
| `_full_gc_memory_manager` | "G1 Old Generation" | Old | Full GC |

### 内存池（MemoryPool）

```
┌─────────────────────────────────────────────────────────────┐
│  JMX 内存池视图                                              │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  _eden_pool ─────────→ "G1 Eden Space"                      │
│  _survivor_pool ─────→ "G1 Survivor Space"                  │
│  _old_pool ──────────→ "G1 Old Gen"                         │
│                                                              │
│  每个池提供：                                                │
│  • getUsage()       → 当前使用量                             │
│  • getPeakUsage()   → 峰值使用量                             │
│  • getCollectionUsage() → GC 后使用量                        │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 🏭 生产环境实践

**JMX 监控代码**：
```java
// 获取 G1 内存管理器
ManagementFactory.getGarbageCollectorMXBeans().forEach(gc -> {
    if (gc.getName().contains("G1")) {
        System.out.println(gc.getName() + 
            ": count=" + gc.getCollectionCount() + 
            ", time=" + gc.getCollectionTime() + "ms");
    }
});

// 输出示例
// G1 Young Generation: count=156, time=2345ms
// G1 Old Generation: count=2, time=890ms
```

**jstat 监控**：
```bash
jstat -gc <pid> 1000

# 字段解释
# S0C/S1C: Survivor 容量（G1 中动态变化）
# EC: Eden 容量
# OC: Old 容量
# YGC: Young GC 次数
# YGCT: Young GC 总时间
# FGC: Full GC 次数
# FGCT: Full GC 总时间
```

---

## D.3 GC 计时与追踪

### 源码

```cpp
// g1CollectedHeap.cpp:1463
_gc_timer_stw(new(ResourceObj::C_HEAP, mtGC) STWGCTimer()),
_gc_tracer_stw(new(ResourceObj::C_HEAP, mtGC) G1NewTracer()),
```

### STWGCTimer

**记录 STW 暂停的精确时间**。

```cpp
// gcTimer.hpp:155
class STWGCTimer : public GCTimer {
  void register_gc_start(const Ticks& time);
  void register_gc_end(const Ticks& time);
};

// GCTimer 基类
class GCTimer : public ResourceObj {
  Ticks _gc_start;                    // GC 开始时间
  Ticks _gc_end;                      // GC 结束时间
  TimePartitions _time_partitions;    // 阶段时间分区
};
```

**记录的阶段**：
```
Young GC 时间分区
├── Pre Evacuate Collection Set
│   ├── Prepare TLABs
│   └── Choose Collection Set
├── Evacuate Collection Set
│   ├── Ext Root Scanning
│   ├── Update RS
│   ├── Scan RS
│   ├── Object Copy
│   └── Termination
├── Post Evacuate Collection Set
│   ├── Code Roots Fixup
│   ├── Reference Processing
│   └── Clear Card Table
└── Other
```

### G1NewTracer

**生成 JFR (Java Flight Recorder) 事件**。

```cpp
// gcTrace.hpp:243
class G1NewTracer : public YoungGCTracer {
  G1YoungGCInfo _g1_young_gc_info;
  
  void report_yc_type(G1YCType type);           // 报告 GC 类型
  void report_evacuation_info(EvacuationInfo*); // 报告疏散信息
  void report_evacuation_failed(EvacuationFailedInfo&); // 报告疏散失败
};
```

**JFR 事件类型**：

| 事件 | 说明 |
|------|------|
| `jdk.G1GarbageCollection` | G1 GC 事件 |
| `jdk.G1HeapSummary` | 堆摘要 |
| `jdk.GCPhasePause` | GC 阶段暂停 |
| `jdk.EvacuationFailed` | 疏散失败 |

### 内存分配方式

```cpp
new(ResourceObj::C_HEAP, mtGC) STWGCTimer()
```

**解析**：
- `ResourceObj::C_HEAP`：分配在 C 堆（非 Java 堆）
- `mtGC`：内存类型标记为 GC 相关
- 用于 Native Memory Tracking

```bash
# 查看 GC 相关内存
jcmd <pid> VM.native_memory summary | grep -A5 "GC"

# 输出示例
-                        GC (reserved=423MB, committed=423MB)
                            (malloc=45MB #1234)
                            (mmap: reserved=378MB, committed=378MB)
```

---

## 完整架构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       G1CollectedHeap 策略与监控架构                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  D.1 策略与线程                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ _young_gen_sampling_thread ──→ 周期采样 RSet，预测暂停时间           │   │
│  │ _collector_policy ───────────→ G1CollectorPolicy（堆配置）           │   │
│  │ _soft_ref_policy ────────────→ 软引用清理策略                        │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  D.2 JMX 监控                                                                │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                                                                      │   │
│  │  MemoryManagerMXBean              MemoryPoolMXBean                  │   │
│  │  ┌────────────────────┐          ┌────────────────────┐            │   │
│  │  │ _memory_manager    │──关联───→│ _eden_pool         │            │   │
│  │  │ "G1 Young Gen"     │          │ "G1 Eden Space"    │            │   │
│  │  └────────────────────┘          ├────────────────────┤            │   │
│  │  ┌────────────────────┐          │ _survivor_pool     │            │   │
│  │  │ _full_gc_memory_   │          │ "G1 Survivor Space"│            │   │
│  │  │ manager            │──关联───→├────────────────────┤            │   │
│  │  │ "G1 Old Gen"       │          │ _old_pool          │            │   │
│  │  └────────────────────┘          │ "G1 Old Gen"       │            │   │
│  │                                  └────────────────────┘            │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  D.3 计时与追踪                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ _gc_timer_stw ───────→ STW 暂停时间记录                              │   │
│  │     │                                                                │   │
│  │     └─→ _time_partitions ───→ 各阶段耗时                             │   │
│  │                                                                      │   │
│  │ _gc_tracer_stw ──────→ JFR 事件生成                                  │   │
│  │     │                                                                │   │
│  │     ├─→ jdk.G1GarbageCollection                                     │   │
│  │     ├─→ jdk.G1HeapSummary                                           │   │
│  │     └─→ jdk.EvacuationFailed                                        │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 🏭 生产环境监控清单

### JMX 监控

```java
// 获取 GC 统计
List<GarbageCollectorMXBean> gcBeans = ManagementFactory.getGarbageCollectorMXBeans();
for (GarbageCollectorMXBean gc : gcBeans) {
    System.out.printf("%s: count=%d, time=%dms%n",
        gc.getName(), gc.getCollectionCount(), gc.getCollectionTime());
}

// 获取内存池状态
List<MemoryPoolMXBean> pools = ManagementFactory.getMemoryPoolMXBeans();
for (MemoryPoolMXBean pool : pools) {
    if (pool.getName().contains("G1")) {
        MemoryUsage usage = pool.getUsage();
        System.out.printf("%s: used=%dMB, max=%dMB%n",
            pool.getName(), usage.getUsed() / 1024 / 1024, usage.getMax() / 1024 / 1024);
    }
}
```

### JFR 录制

```bash
# 启动 JFR 录制
jcmd <pid> JFR.start name=gc_analysis duration=60s filename=/tmp/gc.jfr

# 分析 JFR 文件
jfr print --events jdk.G1GarbageCollection /tmp/gc.jfr

# 或使用 JMC (Java Mission Control) 可视化分析
```

### 关键监控指标

| 指标 | 获取方式 | 正常范围 | 异常信号 |
|------|----------|----------|----------|
| Young GC 频率 | jstat/JMX | 每秒 < 1 次 | 每秒 > 5 次 |
| Young GC 时间 | jstat/JMX | < 100ms | > 500ms |
| Full GC 次数 | jstat/JMX | 极少 | 频繁发生 |
| 软引用清理 | GC 日志 | Full GC 时 | 每次 GC |

### GC 日志配置

```bash
# 详细 GC 日志
-Xlog:gc*=info,gc+heap=debug,gc+age=debug:file=/var/log/gc.log:time,uptime,level,tags

# JFR 自动录制
-XX:StartFlightRecording=duration=60s,filename=/tmp/gc.jfr
```

---

## GDB 验证脚本

```bash
# 文件：jvm-md/tmp-file/universe-init/gdb_policy_timer.txt

b g1CollectedHeap.cpp:1463
commands
  printf "\n=== D.1/D.2/D.3 策略监控追踪验证 ===\n"
  
  printf "\n[D.1] 策略与线程:\n"
  printf "  _young_gen_sampling_thread = %p (构造函数中为 NULL)\n", _young_gen_sampling_thread
  printf "  _collector_policy = %p\n", _collector_policy
  printf "  SoftRefLRUPolicyMSPerMB = %d\n", SoftRefLRUPolicyMSPerMB
  
  printf "\n[D.2] JMX 监控:\n"
  printf "  _memory_manager._name = %s\n", _memory_manager._name
  printf "  _full_gc_memory_manager._name = %s\n", _full_gc_memory_manager._name
  printf "  _eden_pool = %p (构造函数中为 NULL)\n", _eden_pool
  
  printf "\n[D.3] 计时与追踪:\n"
  printf "  _gc_timer_stw = %p\n", _gc_timer_stw
  printf "  _gc_tracer_stw = %p\n", _gc_tracer_stw
  
  continue
end

run
```

**预期输出**：
```
=== D.1/D.2/D.3 策略监控追踪验证 ===

[D.1] 策略与线程:
  _young_gen_sampling_thread = 0x0 (构造函数中为 NULL)
  _collector_policy = 0x7f...
  SoftRefLRUPolicyMSPerMB = 1000

[D.2] JMX 监控:
  _memory_manager._name = "G1 Young Generation"
  _full_gc_memory_manager._name = "G1 Old Generation"
  _eden_pool = 0x0 (构造函数中为 NULL)

[D.3] 计时与追踪:
  _gc_timer_stw = 0x7f...
  _gc_tracer_stw = 0x7f...
```

---

## 待分析节点更新

| 节点 | 主题 | 状态 |
|------|------|------|
| **D.1.1** | _young_gen_sampling_thread 作用 | ✅ |
| **D.1.2** | _soft_ref_policy 软引用策略 | ✅ |
| **D.2.1** | GCMemoryManager 作用 | ✅ |
| **D.2.2** | 三个内存池 | ✅ |
| **D.3.1** | STWGCTimer 实现 | ✅ |
| **D.3.2** | G1NewTracer 与 JFR | ✅ |
| **D.3.3** | 内存分配方式 C_HEAP/mtGC | ✅ |
