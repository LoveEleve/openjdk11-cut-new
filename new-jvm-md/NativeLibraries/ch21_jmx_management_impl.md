# Ch21: libmanagement*.so — JMX 底层从 MXBean 到 JVM 内部数据

> 基于 OpenJDK 11 源码 | libmanagement + libmanagement_ext + HotSpot services 深度分析
> 模块 C（3 篇之一）| PerfMa 面试价值：⭐⭐⭐⭐

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **Ch21: libmanagement*.so — JMX 底层从 MXBean 到 JVM 内部数据**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 21.1 总览：JMX 底层为什么需要 Native 层？

### 核心问题

Java Management Extensions (JMX) 提供了标准的 MXBean API（如 `MemoryMXBean`、`ThreadMXBean`、`GarbageCollectorMXBean`），但这些数据（堆内存使用量、线程 CPU 时间、GC 次数等）全都在 HotSpot C++ 层维护。**如何让 Java 层访问这些数据？**

### 答案：JmmInterface — 函数指针表桥接

```
┌─────────────────────────────────────────────────────────────────────────┐
│                   JMX 三层架构                                           │
│                                                                         │
│  Java 层 (MXBean API)                                                   │
│  ┌──────────────────────────────────────────────────────────────────┐    │
│  │ java.lang.management.MemoryMXBean                                │    │
│  │ java.lang.management.ThreadMXBean                                │    │
│  │ java.lang.management.GarbageCollectorMXBean                      │    │
│  │ java.lang.management.RuntimeMXBean                               │    │
│  │ java.lang.management.ClassLoadingMXBean                          │    │
│  │ java.lang.management.CompilationMXBean                           │    │
│  │ java.lang.management.OperatingSystemMXBean                       │    │
│  │ com.sun.management.HotSpotDiagnosticMXBean                      │    │
│  │ com.sun.management.GarbageCollectorMXBean (扩展)                 │    │
│  └──────────────────┬───────────────────────────────────────────────┘    │
│                     │ JNI native method                                  │
│                     ▼                                                    │
│  Native 层 (3 个 .so)                                                    │
│  ┌───────────────────┬─────────────────────┬────────────────────────┐    │
│  │ libmanagement.so  │ libmanagement_ext.so │ libmanagement_agent.so│    │
│  │ (java.management) │ (jdk.management)     │ (jdk.management.agent)│    │
│  │                   │                      │                       │    │
│  │ GC 次数/时间      │ GcInfo/GcInfoBuilder │ 文件权限检查          │    │
│  │ 内存使用量        │ DiagnosticCommand    │ (JMX Agent 安全)      │    │
│  │ 线程信息/CPU时间  │ VM Flag 管理         │                       │    │
│  │ 类加载统计        │ OperatingSystem扩展  │                       │    │
│  │ VM管理信息        │ GC扩展属性           │                       │    │
│  └────────┬──────────┴──────────┬──────────┴────────────────────────┘    │
│           │    jmm_interface->   │                                       │
│           ▼                      ▼                                       │
│  HotSpot 层 (JmmInterface 函数表)                                        │
│  ┌──────────────────────────────────────────────────────────────────┐    │
│  │ management.cpp — jmm_interface 函数表 (39 个函数指针)             │    │
│  │  ├── jmm_GetMemoryUsage → MemoryService → MemoryPool            │    │
│  │  ├── jmm_GetLongAttribute → get_long_attribute 大 switch        │    │
│  │  ├── jmm_GetThreadInfo → ThreadService → ThreadSnapshot          │    │
│  │  ├── jmm_GetLastGCStat → GCMemoryManager → GCStatInfo           │    │
│  │  ├── jmm_ExecuteDiagnosticCommand → DCmd 框架                    │    │
│  │  ├── jmm_SetVMGlobal → WriteableFlags                           │    │
│  │  └── ... (39 个函数)                                              │    │
│  └──────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘
```

### 设计要点

1. **解耦**：Java 层通过 JNI 调用 native → native 通过 `jmm_interface` 函数指针表调用 HotSpot
2. **版本协商**：`JNI_OnLoad` 时调用 `JVM_GetManagement(JMM_VERSION)` 获取函数表
3. **一表通天下**：39 个函数指针覆盖内存、线程、GC、类加载、诊断命令等全部监控功能

---

## 21.2 JmmInterface 函数表 — 桥接核心

### JNI_OnLoad 初始化

**文件**：`src/java.management/share/native/libmanagement/management.c`

```c
const JmmInterface* jmm_interface = NULL;  // ★ 全局变量 ★

JNIEXPORT jint JNICALL DEF_JNI_OnLoad(JavaVM *vm, void *reserved) {
    jmm_interface = (JmmInterface*) JVM_GetManagement(JMM_VERSION);
    //                               ^^^^^^^^^^^^^^^^^^^^^^^^^^^
    //                               → Management::get_jmm_interface(version)
    //                               → 返回 &jmm_interface 静态结构体
}
```

### HotSpot 端：函数表定义

**文件**：`src/hotspot/share/services/management.cpp`（第 2231-2270 行）

```c
const struct jmmInterface_1_ jmm_interface = {
  NULL,                              // reserved1
  jmm_GetOneThreadAllocatedMemory,   // 线程分配内存量
  jmm_GetVersion,                    // 获取版本号
  jmm_GetOptionalSupport,           // 可选功能探测
  jmm_GetThreadInfo,                 // ★ 线程信息（jstack 底层）
  jmm_GetMemoryPools,               // 内存池列表
  jmm_GetMemoryManagers,            // 内存管理器列表
  jmm_GetMemoryPoolUsage,           // ★ 内存池使用量
  jmm_GetPeakMemoryPoolUsage,       // 峰值使用量
  jmm_GetThreadAllocatedMemory,     // 批量线程分配内存
  jmm_GetMemoryUsage,               // ★ 堆/非堆总使用量
  jmm_GetLongAttribute,             // ★ 通用 long 属性获取
  jmm_GetBoolAttribute,             // bool 属性获取
  jmm_SetBoolAttribute,             // bool 属性设置
  jmm_GetLongAttributes,            // 批量 long 属性
  jmm_FindMonitorDeadlockedThreads,  // 死锁检测（仅 Monitor）
  jmm_GetThreadCpuTime,             // 线程 CPU 时间
  jmm_GetVMGlobalNames,             // ★ VM Flag 名称列表
  jmm_GetVMGlobals,                 // ★ VM Flag 值
  jmm_GetInternalThreadTimes,       // 内部线程时间
  jmm_ResetStatistic,               // 重置统计
  jmm_SetPoolSensor,                // 设置内存池传感器
  jmm_SetPoolThreshold,             // 设置内存池阈值
  jmm_GetPoolCollectionUsage,       // GC 后内存池使用量
  jmm_GetGCExtAttributeInfo,        // GC 扩展属性信息
  jmm_GetLastGCStat,                // ★ 最近一次 GC 统计
  jmm_GetThreadCpuTimeWithKind,     // 线程 CPU 时间（区分 user/sys）
  jmm_GetThreadCpuTimesWithKind,    // 批量版
  jmm_DumpHeap0,                    // ★ Heap Dump
  jmm_FindDeadlockedThreads,        // 死锁检测（Monitor + Lock）
  jmm_SetVMGlobal,                  // ★ 设置 VM Flag
  NULL,                              // reserved6
  jmm_DumpThreads,                  // ★ 线程 Dump
  jmm_SetGCNotificationEnabled,     // GC 通知开关
  jmm_GetDiagnosticCommands,        // ★ 诊断命令列表
  jmm_GetDiagnosticCommandInfo,     // 诊断命令信息
  jmm_GetDiagnosticCommandArgumentsInfo,  // 命令参数信息
  jmm_ExecuteDiagnosticCommand,     // ★ 执行诊断命令
  jmm_SetDiagnosticFrameworkNotificationEnabled
};
```

---

## 21.3 内存监控 — 从 MemoryMXBean 到 MemoryPool

### 内存池模型

```
MemoryPool (抽象基类, HotSpot C++)
│  _name, _type(Heap/NonHeap), _initial_size, _max_size
│  _peak_usage, _after_gc_usage
│  _usage_threshold (ThresholdSupport)
│  _gc_usage_threshold (ThresholdSupport)
│  _usage_sensor / _gc_usage_sensor (SensorInfo)
│
├── CollectedMemoryPool (GC 管理的堆内存池)
│   ├── G1 Eden Space
│   ├── G1 Survivor Space
│   └── G1 Old Gen
│
├── CodeHeapPool (CodeCache 内存池)
│   ├── CodeHeap 'non-profiled nmethods'
│   ├── CodeHeap 'profiled nmethods'
│   └── CodeHeap 'non-nmethods'
│
├── MetaspacePool (Metaspace)
│
└── CompressedKlassSpacePool (压缩类指针空间)
```

### jmm_GetMemoryUsage — 获取总内存使用量

**文件**：`management.cpp` 第 738 行

```
jmm_GetMemoryUsage(env, heap):
│
├── 遍历所有 MemoryPool:
│   for (i = 0; i < MemoryService::num_memory_pools(); i++):
│     pool = MemoryService::get_memory_pool(i)
│     if (heap && pool->is_heap()) 或 (!heap && pool->is_non_heap()):
│       u = pool->get_memory_usage()
│       total_used += u.used()
│       total_committed += u.committed()
│       total_init += u.init_size()   // -1 表示未定义
│       total_max += u.max_size()     // -1 表示未定义
│
├── 构造 MemoryUsage 对象:
│   heap: init=InitialHeapSize, max=Universe::heap()->max_capacity()
│   non-heap: init=聚合值, max=聚合值
│
└── 返回 java.lang.management.MemoryUsage 实例
```

**Java 层调用链**：

```
ManagementFactory.getMemoryMXBean().getHeapMemoryUsage()
→ MemoryImpl.getMemoryUsage0(true)    // JNI native
→ jmm_interface->GetMemoryUsage(env, true)
→ 遍历 MemoryPool → 聚合 → MemoryUsage
```

### jmm_GetMemoryPoolUsage — 获取单个池使用量

```
jmm_GetMemoryPoolUsage(env, pool_obj):
│
├── mpool = get_memory_pool_from_jobject(pool_obj)
│   → 从 MemoryService::_pools_list 查找匹配的 MemoryPool
│
├── usage = mpool->get_memory_usage()
│   → 虚方法，各 MemoryPool 子类实现不同
│   → G1: 查询 G1CollectedHeap 的 used/committed/max
│   → Metaspace: 查询 MetaspaceUtils
│   → CodeHeap: 查询 CodeHeap::allocated_capacity()
│
└── 返回 MemoryUsage 实例
```

### 低内存检测 — Sensor 机制

```
ThresholdSupport:
│  _high_threshold — 高水位阈值
│  _low_threshold  — 低水位阈值
│  → 迟滞 (hysteresis) 机制：避免在阈值附近反复触发
│
SensorInfo:
│  _sensor_obj — Java 层 Sensor 对象
│  _sensor_on  — 当前传感器状态
│  _sensor_count — 触发次数
│  _pending_trigger_count / _pending_clear_count
│
│  工作方式（以 gauge 模式为例）：
│  ├── used >= high_threshold && sensor 当前 OFF → 触发通知
│  ├── used <  low_threshold && sensor 当前 ON  → 清除通知
│  └── used 在 low 和 high 之间 → 不变（迟滞区间）
│
LowMemoryDetector:
│  ├── GC 结束后检测 → detect_after_gc_memory()
│  ├── 慢路径分配时检测 → detect_low_memory_for_collected_pools()
│  └── ServiceThread 处理 pending requests → process_sensor_changes()
│
│  默认阈值：
│  ├── Eden/Survivor: -1（不支持阈值）
│  ├── Old Gen: 0（支持但默认关闭）
│  ├── Metaspace: 0（支持但默认关闭）
│  └── CodeCache: 0（支持但默认关闭）
```

---

## 21.4 GC 监控 — 从 GarbageCollectorMXBean 到 GCStatInfo

### GC 基本数据

```c
// GarbageCollectorImpl.c
jmm_interface->GetLongAttribute(env, mgr, JMM_GC_COUNT);   // GC 次数
jmm_interface->GetLongAttribute(env, mgr, JMM_GC_TIME_MS); // GC 总时间

// management.cpp 中的 get_gc_attribute():
case JMM_GC_TIME_MS:  return mgr->gc_time_ms();
case JMM_GC_COUNT:    return mgr->gc_count();
```

### GC 通知机制

```
GC 发生时:
│
├── gc_end() → MemoryService::gc_end():
│   ├── 更新每个 MemoryPool 的 _after_gc_usage
│   ├── 记录 GC 统计信息 (GCStatInfo)
│   └── GCNotifier::pushNotification(manager, action, cause)
│
├── GCNotifier::pushNotification():
│   ├── 创建 GCNotificationRequest:
│   │   ├── timestamp    — GC 时间戳
│   │   ├── gcManager    — 哪个 GC 管理器
│   │   ├── gcAction     — "end of major GC" / "end of minor GC"
│   │   ├── gcCause      — GCCause::to_string(cause)
│   │   └── gcStatInfo   — GC 前后内存快照
│   ├── 加入链表 (first_request → last_request)
│   └── 唤醒 ServiceThread
│
├── ServiceThread 处理:
│   GCNotifier::sendNotification():
│   ├── 取出 GCNotificationRequest
│   ├── 构造 GcInfo Java 对象:
│   │   ├── gc_index / start_time / end_time
│   │   ├── usage_before_gc[] / usage_after_gc[]
│   │   └── ext_att_values[]
│   └── 调用 Java 层 GarbageCollectorExtImpl.createGCNotification()
│       → javax.management.Notification 发送给监听器
│
└── Java 监听器接收:
    gc_mxbean.addNotificationListener(listener, filter, handback)
```

### GcInfoBuilder — 构建 GC 详细信息

**文件**：`src/jdk.management/share/native/libmanagement_ext/GcInfoBuilder.c`

```
getLastGcInfo0():
│
├── jmm_interface->GetLastGCStat(env, gc, &gc_stat)
│   → HotSpot 填充 jmmGCStat:
│   │  gc_index — 第几次 GC
│   │  start_time / end_time — 起止时间
│   │  usage_before_gc[] — 各池 GC 前用量
│   │  usage_after_gc[]  — 各池 GC 后用量
│   │  gc_ext_attribute_values[] — GC 扩展属性
│
├── 遍历扩展属性（按类型装箱）:
│   'Z' → Boolean, 'B' → Byte, 'I' → Integer,
│   'J' → Long, 'F' → Float, 'D' → Double, ...
│
└── new GcInfo(builder, index, startTime, endTime,
│              usageBeforeGC, usageAfterGC, extValues)
```

---

## 21.5 线程监控 — 从 ThreadMXBean 到 ThreadService

### 线程信息获取

```c
// ThreadImpl.c
jmm_interface->GetThreadInfo(env, ids, maxDepth, infoArray);
jmm_interface->GetThreadCpuTimeWithKind(env, tid, JNI_TRUE);
jmm_interface->GetOneThreadAllocatedMemory(env, tid);
jmm_interface->DumpThreads(env, ids, lockedMonitors, lockedSynchronizers, maxDepth);
jmm_interface->FindDeadlocks(env, JNI_FALSE);
```

### jmm_GetThreadInfo 实现要点

- 通过 `ThreadsListHandle` 安全遍历线程列表（SafeThreadsListPtr）
- `find_JavaThread_from_java_tid(tid)` 查找目标线程
- 创建 `ThreadSnapshot`：快照线程状态（阻塞对象、锁信息、栈帧）
- 构造 `ThreadInfo` Java 对象：名称、状态、栈帧、锁信息

### 线程 CPU 时间

```
jmm_GetThreadCpuTimeWithKind(tid, user_sys):
├── find_JavaThread_from_java_tid(tid)
└── os::thread_cpu_time(thread, user_sys)
    → Linux: /proc/<pid>/task/<tid>/stat
    → 读取 utime + stime（或仅 utime）
    → 纳秒精度
```

### 线程分配内存量

```
jmm_GetOneThreadAllocatedMemory(tid):
├── find_JavaThread_from_java_tid(tid)
└── thread->cooked_allocated_bytes()
    → JavaThread::_allocated_bytes 字段
    → TLAB 分配时累加
    → 用于统计每个线程分配了多少堆内存
```

---

## 21.6 通用属性获取 — get_long_attribute 大 switch

**文件**：`management.cpp` 第 890-980 行

`jmm_GetLongAttribute` 是 JMX 最核心的函数之一，通过一个大 switch 路由到各个 HotSpot 内部服务：

| JMM 属性 | 数据来源 | 说明 |
|----------|---------|------|
| `JMM_CLASS_LOADED_COUNT` | `ClassLoadingService::loaded_class_count()` | 已加载类总数 |
| `JMM_CLASS_UNLOADED_COUNT` | `ClassLoadingService::unloaded_class_count()` | 已卸载类总数 |
| `JMM_THREAD_TOTAL_COUNT` | `ThreadService::get_total_thread_count()` | 创建的线程总数 |
| `JMM_THREAD_LIVE_COUNT` | `ThreadService::get_live_thread_count()` | 当前活跃线程数 |
| `JMM_THREAD_PEAK_COUNT` | `ThreadService::get_peak_thread_count()` | 峰值线程数 |
| `JMM_THREAD_DAEMON_COUNT` | `ThreadService::get_daemon_thread_count()` | 守护线程数 |
| `JMM_JVM_INIT_DONE_TIME_MS` | `Management::vm_init_done_time()` | VM 初始化完成时间 |
| `JMM_JVM_UPTIME_MS` | `os::elapsed_counter()` | JVM 运行时长 |
| `JMM_COMPILE_TOTAL_TIME_MS` | `CompileBroker::total_compilation_ticks()` | JIT 编译总时间 |
| `JMM_OS_PROCESS_ID` | `os::current_process_id()` | 进程 PID |
| `JMM_SAFEPOINT_COUNT` | `RuntimeService::safepoint_count()` | Safepoint 总次数 |
| `JMM_TOTAL_SAFEPOINTSYNC_TIME_MS` | `RuntimeService::safepoint_sync_time_ms()` | Safepoint 同步总时间 |
| `JMM_TOTAL_STOPPED_TIME_MS` | `RuntimeService::safepoint_time_ms()` | STW 总时间 |
| `JMM_TOTAL_APP_TIME_MS` | `RuntimeService::application_time_ms()` | 应用运行总时间 |
| `JMM_CLASS_LOADED_BYTES` | `ClassLoadingService::loaded_class_bytes()` | 加载类字节数 |
| `JMM_VM_THREAD_COUNT` | `get_vm_thread_count()` | VM 内部线程数 |
| `JMM_METHOD_DATA_SIZE_BYTES` | `ClassLoadingService::class_method_data_size()` | 方法数据大小 |

### Bool 属性

| JMM 属性 | 数据来源 | 说明 |
|----------|---------|------|
| `JMM_VERBOSE_GC` | `MemoryService::get_verbose()` | GC 日志是否开启 |
| `JMM_VERBOSE_CLASS` | `ClassLoadingService::get_verbose()` | 类加载日志 |
| `JMM_THREAD_CONTENTION_MONITORING` | `ThreadService` | 线程竞争监控 |
| `JMM_THREAD_CPU_TIME` | `ThreadService` | 线程 CPU 时间监控 |
| `JMM_THREAD_ALLOCATED_MEMORY` | `ThreadService` | 线程分配内存监控 |

---

## 21.7 VM Flag 管理 — 从 HotSpotDiagnosticMXBean 到 WriteableFlags

### Flag.c — 获取和设置 VM Flag

```
Java_com_sun_management_internal_Flag_getFlags():
│
├── jmm_interface->GetVMGlobals(env, names, globals, count)
│   → HotSpot: 遍历 JVMFlag::flags[] 数组
│   → 填充 jmmVMGlobal 结构体:
│   │   name — Flag 名称（如 "MaxHeapSize"）
│   │   value — 当前值
│   │   type — JBOOLEAN/JLONG/JSTRING/JDOUBLE
│   │   origin — 来源（DEFAULT/COMMAND_LINE/MANAGEMENT/ERGONOMIC/ATTACH）
│   │   writeable — 是否可动态修改
│   │   external — 是否对外公开
│
└── 对每个 Flag 创建 Java Flag 对象，包含 origin 枚举

Java_com_sun_management_internal_Flag_setLongValue():
│
├── jmm_interface->SetVMGlobal(env, name, value)
│   → WriteableFlags::set_flag(name, value, JVMFlag::MANAGEMENT)
│   → 只允许 manageable 标记的 Flag
│   → origin 设为 JMM_VMGLOBAL_ORIGIN_MANAGEMENT
│
└── 例如：HeapDumpOnOutOfMemoryError, PrintGC, MaxDirectMemorySize
```

### Flag Origin 追踪

```
JMM_VMGLOBAL_ORIGIN_DEFAULT     — 默认值
JMM_VMGLOBAL_ORIGIN_COMMAND_LINE — 命令行参数
JMM_VMGLOBAL_ORIGIN_MANAGEMENT   — JMX 设置
JMM_VMGLOBAL_ORIGIN_ENVIRON_VAR  — 环境变量
JMM_VMGLOBAL_ORIGIN_CONFIG_FILE  — 配置文件
JMM_VMGLOBAL_ORIGIN_ERGONOMIC    — JVM 自适应
JMM_VMGLOBAL_ORIGIN_ATTACH_ON_DEMAND — Attach API 设置
```

---

## 21.8 诊断命令 — DiagnosticCommand 框架

### 初始化

**文件**：`management.cpp` — `Management::init()`

```
DCmdRegistrant::register_dcmds()
→ 注册所有内置诊断命令:
  ├── VM.version / VM.info / VM.uptime / VM.flags / VM.system_properties
  ├── VM.command_line / VM.print_touched_methods / VM.classloader_stats
  ├── GC.run / GC.run_finalization / GC.heap_info / GC.heap_dump
  ├── GC.class_histogram / GC.finalizer_info
  ├── Thread.print
  ├── Compiler.directive_print / Compiler.directive_add / Compiler.codecache
  ├── JVMTI.data_dump / JVMTI.agent_load
  ├── ManagementAgent.start / ManagementAgent.start_local / ManagementAgent.stop
  └── VM.native_memory (NMT)
```

### 执行链路

```
Java 层: DiagnosticCommandMBean.execute("VM.flags -all")
→ JNI: DiagnosticCommandImpl.executeDiagnosticCommand(command)
→ jmm_interface->ExecuteDiagnosticCommand(env, command)
→ HotSpot: DCmd::parse_and_execute(DCmd_Source_MBean, output, command)
→ 查找 DCmdFactory → 创建 DCmd 实例 → execute()
→ 输出结果字符串返回 Java 层
```

### Source 控制

```
DCmd_Source_Internal   — JVM 内部调用
DCmd_Source_AttachAPI  — Attach API (jcmd)
DCmd_Source_MBean      — JMX MBean

注册时指定 full_export = Internal | AttachAPI | MBean
→ 同一个命令可以通过 jcmd 或 JMX 两种方式调用
```

---

## 21.9 management_init — JVM 启动时的初始化

**文件**：`management.cpp` — `management_init()`

```
management_init():  ← 被 init_globals() 调用
│
├── Management::init():
│   ├── 创建 PerfCounter 时间戳:
│   │   sun.rt.createVmBeginTime
│   │   sun.rt.createVmEndTime
│   │   sun.rt.vmInitDoneTime
│   ├── 设置 _optional_support 位域
│   ├── DCmdRegistrant::register_dcmds() — 注册诊断命令
│   └── DCmdFactory::register_DCmdFactory(NMTDCmd) — 注册 NMT 命令
│
├── ThreadService::init():
│   → 初始化线程监控计数器
│
├── RuntimeService::init():
│   → 初始化 Safepoint 计数器、应用时间计数器
│
└── ClassLoadingService::init():
    → 初始化类加载统计计数器
```

### ManagementServer 启动

```
Management::initialize():  ← vm_init_done 后调用
│
├── if (ManagementServer):
│   ├── 加载 jdk.internal.agent.Agent 类
│   └── JavaCalls::call_static(Agent, "startAgent")
│       → 启动 JMX Agent（RMI 连接器）
│       → 监听端口，接受远程 JMX 连接
│
└── 触发条件：-Dcom.sun.management.jmxremote
    → Arguments 中设置 ManagementServer = true
```

---

## 21.10 三个 .so 的职责划分

| .so 库 | Java 模块 | 主要职责 | native 方法数 |
|--------|-----------|---------|-------------|
| **libmanagement.so** | `java.management` | GC 次数/时间、内存使用量、线程信息/CPU/分配量、类加载统计、VM 管理信息 | ~25 个 |
| **libmanagement_ext.so** | `jdk.management` | GcInfo 构建、DiagnosticCommand、VM Flag 管理、GC 扩展属性、OS 信息 | ~15 个 |
| **libmanagement_agent.so** | `jdk.management.agent` | 文件权限检查（JMX Agent 安全相关） | ~2 个 |

### 所有 native 方法一览

**libmanagement.so**:

| 类 | 方法 | JMM 函数 |
|----|------|---------|
| `GarbageCollectorImpl` | `getCollectionCount/Time` | `GetLongAttribute(JMM_GC_COUNT/TIME)` |
| `MemoryImpl` | `setVerboseGC` | `SetBoolAttribute(JMM_VERBOSE_GC)` |
| `MemoryImpl` | `getMemoryPools0/Managers0/Usage0` | `GetMemoryPools/Managers/Usage` |
| `MemoryPoolImpl` | `getUsage0/getPeakUsage0/getCollectionUsage0` | `GetMemoryPoolUsage/Peak/Collection` |
| `MemoryPoolImpl` | `setUsageThreshold0/setCollectionThreshold0` | `SetPoolThreshold` |
| `MemoryPoolImpl` | `setPoolUsageSensor/setPoolCollectionSensor` | `SetPoolSensor` |
| `MemoryManagerImpl` | `getMemoryPools0` | `GetMemoryPools` |
| `ThreadImpl` | `getThreadInfo1/dumpThreads0` | `GetThreadInfo/DumpThreads` |
| `ThreadImpl` | `getThreadTotalCpuTime0/1` | `GetThreadCpuTimeWithKind` |
| `ThreadImpl` | `getThreadAllocatedMemory0/1` | `GetOneThreadAllocatedMemory/GetThreadAllocatedMemory` |
| `ThreadImpl` | `findMonitorDeadlockedThreads0/findDeadlockedThreads0` | `FindCircularBlockedThreads/FindDeadlocks` |
| `VMManagementImpl` | `initOptionalSupportFields` | `GetOptionalSupport` |
| `VMManagementImpl` | `getTotalClassCount/getLiveThreadCount/getSafepointCount/...` | `GetLongAttribute(JMM_XXX)` |
| `ClassLoadingImpl` | `setVerboseClass` | `SetBoolAttribute(JMM_VERBOSE_CLASS)` |

**libmanagement_ext.so**:

| 类 | 方法 | JMM 函数 |
|----|------|---------|
| `GcInfoBuilder` | `getNumGcExtAttributes/fillGcAttributeInfo/getLastGcInfo0` | `GetGCExtAttributeInfo/GetLastGCStat` |
| `GarbageCollectorExtImpl` | (通过 Java 层) | GC 通知 |
| `DiagnosticCommandImpl` | `getDiagnosticCommands/getDiagnosticCommandInfo/executeDiagnosticCommand` | `GetDiagnosticCommands/ExecuteDiagnosticCommand` |
| `Flag` | `getFlags/setLongValue/setBooleanValue/...` | `GetVMGlobals/SetVMGlobal` |
| `HotSpotDiagnostic` | (通过 Flag) | HeapDump |

---

## 21.11 面试专题

### Q1: JMX 的数据是怎么从 HotSpot 传到 Java 层的？

**源码级回答**：

通过 **JmmInterface 函数指针表** 桥接：
1. `libmanagement.so` 在 `JNI_OnLoad` 时调用 `JVM_GetManagement(JMM_VERSION)` 获取 `JmmInterface*`
2. HotSpot 返回一个**静态函数表** `jmm_interface`，包含 39 个函数指针
3. Java 层 MXBean 的 native 方法（如 `getCollectionCount`）通过 JNI 进入 libmanagement.so
4. libmanagement.so 调用 `jmm_interface->GetLongAttribute(env, mgr, JMM_GC_COUNT)`
5. HotSpot 中的 `jmm_GetLongAttribute` 直接访问 `GCMemoryManager::gc_count()` 等内部数据

**关键设计**：Java 层完全不知道 HotSpot 内部结构，只通过函数指针表访问。版本协商通过 `JMM_VERSION` 实现。

### Q2: MemoryMXBean.getHeapMemoryUsage() 底层做了什么？

1. Java: `MemoryImpl.getMemoryUsage0(true)` — JNI native
2. JNI: `jmm_interface->GetMemoryUsage(env, true)`
3. HotSpot: 遍历所有 `MemoryPool`，过滤 `is_heap()` 类型
4. 每个池调用 `get_memory_usage()` — 虚方法，G1 实现查询 Region 使用量
5. 聚合 `init/used/committed/max`
6. 构造 `java.lang.management.MemoryUsage` 对象返回

### Q3: GC 通知是怎么推送到 Java 层的？

1. GC 结束时 `MemoryService::gc_end()` 记录 GC 前后内存快照
2. `GCNotifier::pushNotification()` 创建 `GCNotificationRequest` 加入链表
3. **ServiceThread** 被唤醒，调用 `GCNotifier::sendNotification()`
4. 构造 `GcInfo` Java 对象 → 调用 `GarbageCollectorExtImpl.createGCNotification()`
5. 通过 JMX `NotificationBroadcasterSupport` 发送 `javax.management.Notification`
6. Java 监听器收到通知

**关键**：通知是**异步**的，通过 ServiceThread 发送，不会阻塞 GC 线程。

### Q4: 如何通过 JMX 动态修改 VM Flag？

- `HotSpotDiagnosticMXBean.setVMOption("HeapDumpOnOutOfMemoryError", "true")`
- → `Flag.setBooleanValue(name, true)` → JNI
- → `jmm_interface->SetVMGlobal(env, name, value)`
- → `WriteableFlags::set_flag(name, value, JVMFlag::MANAGEMENT)`
- **限制**：只有标记为 `manageable` 的 Flag 才能修改
- origin 设为 `JMM_VMGLOBAL_ORIGIN_MANAGEMENT`

### Q5: ThreadMXBean.getThreadAllocatedBytes() 的数据从哪来？

- `JavaThread::_allocated_bytes` 字段
- **累加时机**：TLAB 退还时（TLAB 用完或线程结束时）
- `thread->cooked_allocated_bytes()` = _allocated_bytes + 当前 TLAB 已用量
- 不需要 Safepoint，通过 `ThreadsListHandle` 安全读取

### Q6: 低内存检测（Low Memory Detection）是怎么工作的？

1. **GC 后检测**：`gc_end()` → `detect_after_gc_memory(pool)` → 检查 `gc_usage_threshold`
2. **分配时检测**：慢路径分配 → `detect_low_memory_for_collected_pools()` → 检查 `usage_threshold`
3. **迟滞机制**：高阈值触发，低阈值清除，中间区间不变
4. **ServiceThread 处理**：`SensorInfo::process_pending_requests()` → 调用 Java 层 `Sensor.trigger()/clear()`
5. **默认**：所有池阈值 = 0，需要 Java 层显式设置才生效

---

## 21.12 与诊断工具的关联

| 工具 | 底层路径 |
|------|---------|
| `jconsole` / `VisualVM` | JMX RMI → MXBean → JNI → jmm_interface |
| `jcmd <pid> GC.heap_info` | Attach → jcmd → DCmd 框架 |
| `jcmd <pid> VM.flags` | Attach → jcmd → DCmd 框架 |
| `jinfo -flag +PrintGC <pid>` | Attach → setflag → WriteableFlags |
| Prometheus JMX Exporter | JMX RMI → MXBean → JNI → jmm_interface |
| Grafana + JMX | 同上 |
| PerfMa XLand | JMX + Attach 混合 |

---

*分析文件*：
- `src/java.management/share/native/libmanagement/management.c` — JNI_OnLoad 入口
- `src/java.management/share/native/libmanagement/management.h` — JmmInterface 声明
- `src/java.management/share/native/libmanagement/GarbageCollectorImpl.c` — GC MXBean native
- `src/java.management/share/native/libmanagement/MemoryImpl.c` — Memory MXBean native
- `src/java.management/share/native/libmanagement/MemoryPoolImpl.c` — MemoryPool native
- `src/java.management/share/native/libmanagement/ThreadImpl.c` — Thread MXBean native
- `src/java.management/share/native/libmanagement/VMManagementImpl.c` — VM 管理信息 native
- `src/java.management/share/native/libmanagement/ClassLoadingImpl.c` — 类加载 native
- `src/jdk.management/share/native/libmanagement_ext/GcInfoBuilder.c` — GcInfo 构建
- `src/jdk.management/share/native/libmanagement_ext/DiagnosticCommandImpl.c` — 诊断命令
- `src/jdk.management/share/native/libmanagement_ext/Flag.c` — VM Flag 管理
- `src/hotspot/share/include/jmm.h` — JmmInterface 定义（39 个函数指针）
- `src/hotspot/share/services/management.hpp` — Management 类定义
- `src/hotspot/share/services/management.cpp` — JMM 实现（2283 行核心）
- `src/hotspot/share/services/memoryService.hpp` — MemoryService
- `src/hotspot/share/services/memoryPool.hpp` — MemoryPool 层次
- `src/hotspot/share/services/lowMemoryDetector.hpp` — 低内存检测
- `src/hotspot/share/services/gcNotifier.hpp` — GC 通知
