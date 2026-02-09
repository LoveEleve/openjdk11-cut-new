# Ch22: 诊断命令与堆 Dump — DCmd 框架 + HeapDumper + NMT

> 基于 OpenJDK 11 源码 | diagnosticCommand + heapDumper + nmtDCmd 深度分析
> 模块 C（3 篇之二）| PerfMa 面试价值：⭐⭐⭐⭐⭐

---

## 22.1 总览：JVM 内置诊断命令的完整架构

### 核心问题

当你执行 `jcmd <pid> GC.heap_dump /tmp/dump.hprof` 或 `jcmd <pid> VM.native_memory summary` 时：
- **命令如何从 jcmd 进程传递到目标 JVM？** → Ch19 Attach API
- **JVM 收到命令后如何解析和执行？** → **本章：DCmd 框架**
- **堆 Dump 怎样在 Safepoint 下遍历整个堆？** → **本章：HeapDumper**
- **NMT 的内存数据怎么采集和报告？** → **本章：NMT DCmd**

### 全景架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                     诊断命令完整链路                                  │
│                                                                     │
│  外部入口                                                            │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │ jcmd <pid> GC.heap_dump     ─┐                               │    │
│  │ jcmd <pid> VM.native_memory ─┤  Attach API → jcmd 命令       │    │
│  │ jcmd <pid> Thread.print     ─┤                               │    │
│  │ jcmd <pid> VM.flags         ─┘                               │    │
│  │                                                              │    │
│  │ JMX DiagnosticCommandMBean  ───  JMX RMI 远程调用            │    │
│  │                                                              │    │
│  │ JVM 内部调用                ───  HeapDumpOnOutOfMemoryError   │    │
│  └───────────────────────────┬──────────────────────────────────┘    │
│                              │                                       │
│                              ▼                                       │
│  DCmd 框架 (diagnosticFramework)                                     │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │                    DCmdFactory 链表                           │    │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐    │    │
│  │  │HeapDump  │→ │ThreadDump│→ │VMFlags   │→ │NMT       │→...│    │
│  │  │DCmd      │  │DCmd      │  │DCmd      │  │DCmd      │    │    │
│  │  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘    │    │
│  │       │              │             │              │          │    │
│  │  DCmdParser → parse() → execute() ← outputStream            │    │
│  └──────────────────────────────────────────────────────────────┘    │
│                              │                                       │
│                              ▼                                       │
│  具体执行器                                                          │
│  ┌──────────────┬──────────────┬──────────────┬────────────────┐    │
│  │ VM_HeapDumper│ VM_PrintThreads│ WriteableFlags│ MemTracker    │    │
│  │ (Safepoint)  │ (Safepoint)    │ (直接调用)     │ (查询 NMT)   │    │
│  └──────────────┴──────────────┴──────────────┴────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 22.2 DCmd 框架 — 命令注册、解析与分发

### 类继承体系

```
ResourceObj
└── DCmd (诊断命令基类)
    │  _output : outputStream*    — 输出流
    │  _is_heap_allocated : bool  — 分配方式
    │  
    │  static parse_and_execute() — ★ 主入口：解析+执行
    │  virtual execute()          — 子类实现
    │  virtual parse()            — 参数解析
    │
    ├── DCmdWithParser (带参数解析器的命令)
    │   │  _dcmdparser : DCmdParser
    │   │
    │   ├── HelpDCmd              — "help"
    │   ├── PrintVMFlagsDCmd      — "VM.flags"
    │   ├── SetVMFlagDCmd         — "VM.set_flag"
    │   ├── HeapDumpDCmd          — "GC.heap_dump"       ★
    │   ├── ClassHistogramDCmd    — "GC.class_histogram"  ★
    │   ├── ClassStatsDCmd        — "GC.class_stats"
    │   ├── ThreadDumpDCmd        — "Thread.print"        ★
    │   ├── NMTDCmd               — "VM.native_memory"    ★
    │   ├── JMXStartRemoteDCmd    — "ManagementAgent.start"
    │   ├── JVMTIAgentLoadDCmd    — "JVMTI.agent_load"
    │   ├── SymboltableDCmd       — "VM.symboltable"
    │   ├── StringtableDCmd       — "VM.stringtable"
    │   ├── ClassHierarchyDCmd    — "VM.class_hierarchy"
    │   └── ...
    │
    ├── VersionDCmd               — "VM.version"（无参数）
    ├── CommandLineDCmd            — "VM.command_line"
    ├── SystemGCDCmd              — "GC.run"
    ├── HeapInfoDCmd              — "GC.heap_info"
    ├── VMInfoDCmd                — "VM.info"
    └── ...
```

### DCmdFactory — 命令工厂注册

**文件**：`diagnosticFramework.hpp`

```
DCmdFactory (命令工厂基类)
│  _next : DCmdFactory*     — 单链表
│  _enabled : bool          — 是否启用
│  _hidden : bool           — 是否隐藏（help 不显示）
│  _export_flags : uint32_t — 导出标志位
│  _num_arguments : int     — 参数个数
│
│  static _DCmdFactoryList  — ★ 全局工厂链表头
│
│  register_DCmdFactory()   — 注册工厂到链表
│  factory(source, cmd, len)— 根据命令名查找工厂
│  create_resource_instance()— 创建命令实例
│
└── DCmdFactoryImpl<DCmdClass> (模板工厂)
    │  → 编译期绑定具体 DCmd 子类
    │  → name() / description() / impact() 委托给 DCmdClass 的 static 方法
```

### export_flags — 三种调用源

```c
enum DCmdSource {
  DCmd_Source_Internal  = 0x01U,  // JVM 内部调用
  DCmd_Source_AttachAPI = 0x02U,  // Attach API (jcmd)
  DCmd_Source_MBean     = 0x04U   // JMX DiagnosticCommandMBean
};

uint32_t full_export = DCmd_Source_Internal | DCmd_Source_AttachAPI | DCmd_Source_MBean;
// 大多数命令支持所有三种调用源

// 例外：HeapDumpDCmd 不通过 MBean 导出
DCmdFactory::register_DCmdFactory(
  new DCmdFactoryImpl<HeapDumpDCmd>(
    DCmd_Source_Internal | DCmd_Source_AttachAPI,  // 不含 MBean！
    true, false));

// JMX Agent 命令也不通过 MBean 导出
uint32_t jmx_agent_export_flags = DCmd_Source_Internal | DCmd_Source_AttachAPI;
```

### 命令注册 — register_dcmds()

**文件**：`diagnosticCommand.cpp` 第 73-140 行

共注册 **35+ 个命令**，按功能分为 7 大类：

| 类别 | 命令 | 影响级别 |
|------|------|---------|
| **VM 信息** | VM.version / VM.command_line / VM.system_properties / VM.uptime / VM.info / VM.dynlibs | Low |
| **VM 配置** | VM.flags / VM.set_flag | Low |
| **GC 相关** | GC.run / GC.run_finalization / GC.heap_info / GC.heap_dump / GC.class_histogram / GC.class_stats / GC.finalizer_info | Medium-High |
| **线程** | Thread.print | Medium |
| **类加载** | VM.class_hierarchy / VM.classloader_stats / VM.symboltable / VM.stringtable / VM.systemdictionary | Medium |
| **编译器** | Compiler.queue / Compiler.codelist / Compiler.codecache / Compiler.CodeHeap_Analytics / Compiler.directives_* | Low-Medium |
| **JMX Agent** | ManagementAgent.start / start_local / stop / status | Medium |
| **JVMTI** | JVMTI.data_dump / JVMTI.agent_load | High |
| **NMT** | VM.native_memory（在 management_init 中单独注册） | Medium |
| **调试** | VM.start_java_debugging (hidden) | High |
| **Metaspace** | VM.metaspace | Medium |

### 命令执行链路

```
DCmd::parse_and_execute(source, out, cmdline, delim):
│
├── CmdLine line(cmdline, len, false)
│   → 解析命令名和参数（空格分隔）
│
├── DCmdFactory::factory(source, cmd_name, cmd_len)
│   → 遍历 _DCmdFactoryList 链表
│   → 匹配命令名 + 检查 export_flags 是否包含 source
│   → 返回对应 DCmdFactory
│
├── factory->create_resource_instance(out)
│   → 在 ResourceArea 创建 DCmd 实例
│
├── cmd->parse(&line, delim, THREAD)
│   → DCmdParser 解析参数
│   → option: "-all=true" → DCmdArgument<bool>
│   → argument: "filename.hprof" → DCmdArgument<char*>
│
└── cmd->execute(source, THREAD)
    → 子类实现，执行具体操作
```

---

## 22.3 HeapDumper — HPROF 格式堆 Dump 完整链路

### 入口点

**三种触发方式**：

| 触发方式 | 入口 | 调用链 |
|----------|------|--------|
| `jcmd <pid> GC.heap_dump file.hprof` | Attach → jcmd → `HeapDumpDCmd::execute()` | → `HeapDumper(true).dump(filename)` |
| `jmap -dump:format=b,file=dump.hprof <pid>` | Attach → dump_heap → `HeapDumper(true).dump(filename)` | 同上 |
| `-XX:+HeapDumpOnOutOfMemoryError` | OOME → `HeapDumper::dump_heap_from_oome()` | → `HeapDumper(true, oome=true).dump(path)` |
| JMX `jmm_DumpHeap0` | JMX MBean | → `HeapDumper(gc).dump(filename)` |

### HeapDumpDCmd::execute() 详解

```c
void HeapDumpDCmd::execute(DCmdSource source, TRAPS) {
  // 1. 检查 gzip 压缩级别 (1-9)
  jlong level = -1;  // -1 = 不压缩
  if (_gzip.is_set()) {
    level = _gzip.value();  // 1(最快) ~ 9(最强)
  }

  // 2. 创建 HeapDumper
  // _all=false → request GC before dump（清除不可达对象）
  // _all=true  → dump 所有对象（包括不可达的）
  HeapDumper dumper(!_all.value());

  // 3. 执行 dump
  dumper.dump(_filename.value(), output(), (int)level, _overwrite.value());
}
```

### HeapDumper::dump() 流程

```
HeapDumper::dump(path, out, compression, overwrite):
│
├── 1. 创建 DumpWriter:
│   ├── FileWriter(path, overwrite) — 文件写入器
│   ├── GZipCompressor(level) — 可选压缩器（dlopen libz.so）
│   └── CompressionBackend — 后台压缩+写入线程
│
├── 2. 创建 VM_HeapDumper:
│   ├── 继承 VM_GC_Operation — 在 Safepoint 执行
│   ├── 继承 AbstractGangTask — 支持并行（worker 线程做压缩写入）
│   ├── GCCause::_heap_dump — GC 原因标记
│   └── _gc_before_heap_dump — 是否先做 Full GC
│
├── 3. 提交到 VMThread 执行:
│   if (Thread::current()->is_VM_thread())
│     dumper.doit();  // 已经在 VM 线程（如 OOME 场景）
│   else
│     VMThread::execute(&dumper);  // 正常路径：提交给 VMThread
│
└── 4. 返回结果
```

### VM_HeapDumper::doit() — Safepoint 下的完整 Dump 流程

```
VM_HeapDumper::doit():
│
├── 1. ensure_parsability(false)
│   → 确保堆可安全遍历（TLAB 边界对齐）
│
├── 2. 可选 Full GC:
│   if (_gc_before_heap_dump && !GCLocker::is_active())
│     ch->collect_as_vm_thread(GCCause::_heap_dump)
│   → 减少不可达对象，使 dump 更有用
│
├── 3. 设置全局 dumper/writer:
│   set_global_dumper(); set_global_writer();
│
├── 4. 并行执行:
│   if (gang != NULL)
│     gang->run_task(this, active_workers, true)
│   else
│     work(0);  // 单线程
│
└── 5. 清理全局变量
```

### VM_HeapDumper::work() — HPROF 记录生成

```
VM_HeapDumper::work(worker_id):
│
├── worker_id != 0 (非 VM 线程):
│   writer()->writer_loop();  // 做压缩+写入的 worker
│   return;
│
├── worker_id == 0 (VM 线程，主执行):
│
│   ①  写 HPROF Header:
│       "JAVA PROFILE 1.0.2\0" + id_size(8) + timestamp(u8)
│
│   ②  写 HPROF_UTF8 记录:
│       SymbolTable::symbols_do(&sym_dumper)
│       → 遍历所有 Symbol，写 UTF8 字符串
│
│   ③  写 HPROF_LOAD_CLASS 记录:
│       ClassLoaderDataGraph::classes_do(&do_load_class)
│       Universe::basic_type_classes_do(&do_load_class)
│       → 为每个 Klass 写加载记录（含类序列号）
│
│   ④  写 HPROF_FRAME + HPROF_TRACE 记录:
│       dump_stack_traces()
│       → 遍历所有 JavaThread
│       → 为每个线程做 ThreadStackTrace（含所有栈帧）
│       → 写栈帧信息
│
│   ⑤  写 HPROF_GC_CLASS_DUMP 记录:
│       ClassLoaderDataGraph::classes_do(&do_class_dump)
│       → 每个类的静态字段、实例字段定义
│
│   ⑥  写堆对象记录 (占 90%+ 体积):
│       Universe::heap()->safe_object_iterate(&obj_dumper)
│       → HeapObjectDumper::do_object(oop o):
│         ├── instance → HPROF_GC_INSTANCE_DUMP
│         ├── objArray → HPROF_GC_OBJ_ARRAY_DUMP
│         └── typeArray → HPROF_GC_PRIM_ARRAY_DUMP
│
│   ⑦  写 GC Root 记录:
│       ├── do_threads()      → HPROF_GC_ROOT_THREAD_OBJ + JAVA_FRAME + JNI_LOCAL
│       ├── ObjectSynchronizer → HPROF_GC_ROOT_MONITOR_USED（Monitor 持有的对象）
│       ├── JNIHandles         → HPROF_GC_ROOT_JNI_GLOBAL
│       └── null_class_loader  → HPROF_GC_ROOT_STICKY_CLASS（不可卸载的类）
│
│   ⑧  写 HPROF_HEAP_DUMP_END
│
│   ⑨  writer()->deactivate() — 释放 worker 线程
```

### HPROF 文件格式

```
┌─────────────────────────────────────────────────────────┐
│ HPROF 文件格式 (JAVA PROFILE 1.0.2)                      │
│                                                          │
│ Header: "JAVA PROFILE 1.0.2\0" + id_size(4B) + ts(8B)  │
│                                                          │
│ Record:                                                  │
│   u1 TAG           — 记录类型                             │
│   u4 timestamp     — 微秒偏移                             │
│   u4 length        — Body 长度                            │
│   [u1]* Body       — 记录体                               │
│                                                          │
│ 顺序:                                                    │
│   [HPROF_UTF8]*          — 所有字符串                      │
│   [HPROF_LOAD_CLASS]*    — 所有已加载的类                   │
│   [HPROF_FRAME]*         — 栈帧                           │
│   [HPROF_TRACE]*         — 栈轨迹                          │
│   [HPROF_HEAP_DUMP_SEGMENT]* — 堆数据（分段）              │
│     ├── HPROF_GC_CLASS_DUMP     — 类 Dump                 │
│     ├── HPROF_GC_INSTANCE_DUMP  — 实例 Dump ← 最大        │
│     ├── HPROF_GC_OBJ_ARRAY_DUMP — 对象数组 Dump           │
│     ├── HPROF_GC_PRIM_ARRAY_DUMP— 基本类型数组 Dump        │
│     ├── HPROF_GC_ROOT_*         — GC Root                 │
│     └── ...                                               │
│   HPROF_HEAP_DUMP_END   — 结束标记                         │
└─────────────────────────────────────────────────────────┘
```

### DumpWriter + CompressionBackend — 高性能写入

```
DumpWriter:
│  _buffer : char*       — 当前写入缓冲区
│  _size / _pos          — 缓冲区大小/当前位置
│  _backend              — CompressionBackend
│
│  io_buffer_max_size = 1MB  — 每个缓冲区块大小
│  io_buffer_max_waste = 10KB — 允许浪费的最大字节数
│
│  工作方式:
│  ├── write_xxx() → 写入 _buffer
│  ├── flush() → _backend.get_new_buffer() → 提交旧 buffer 到压缩队列
│  └── deactivate() → 等待所有 worker 完成
│
CompressionBackend:
│  _writer : AbstractWriter*     — FileWriter
│  _compressor : AbstractCompressor* — GZipCompressor (可选)
│  _to_compress : WorkList       — 待压缩队列
│  _unused : WorkList            — 空闲 buffer 池
│  _finished : WorkList          — 已压缩待写入队列
│
│  写入流程:
│  ├── VM 线程填充 WriteWork 的 _in buffer
│  ├── flush → 提交到 _to_compress 队列
│  ├── Worker 线程从 _to_compress 取出 → compress() → 放入 _finished
│  └── 按 id 顺序写入文件（保证有序）
│
│  GZip 压缩:
│  ├── dlopen("libz.so") 动态加载
│  ├── deflateInit2() 初始化
│  └── deflate() 压缩每个块
```

---

## 22.4 ClassHistogramDCmd — jmap -histo 底层

```
ClassHistogramDCmd::execute():
│
├── VM_GC_HeapInspection heapop(output, !_all)
│   → 继承 VM_GC_Operation
│   → 在 Safepoint 下执行
│
├── VMThread::execute(&heapop)
│
└── heapop.doit():
    ├── collect_as_vm_thread(GCCause::_heap_inspection) — 可选 Full GC
    ├── HeapInspection::heap_inspection(out) — 遍历堆统计
    │   ├── KlassInfoTable — HashMap<Klass*, KlassInfoEntry>
    │   ├── 遍历每个对象，按类累加 count/size
    │   └── KlassInfoTable::sort() → 按 size 降序
    └── 输出:
        num   #instances   #bytes  class name
        ---   ----------   ------  ----------
          1:     1234567   98765432  [B
          2:      123456    7654321  java.lang.String
          ...
```

---

## 22.5 ThreadDumpDCmd — jstack 底层

```
ThreadDumpDCmd::execute():
│
├── VM_PrintThreads op1(output, _locks, _extended)
│   VMThread::execute(&op1)
│   → Safepoint 下打印所有线程栈
│   → 包含线程名、状态、栈帧、锁信息
│
├── VM_PrintJNI op2(output)
│   VMThread::execute(&op2)
│   → 打印 JNI global handles
│
└── VM_FindDeadlocks op3(output)
    VMThread::execute(&op3)
    → 检测死锁（Monitor + java.util.concurrent.locks）
    → 打印死锁链
```

---

## 22.6 NMT DCmd — VM.native_memory

### NMT 命令参数

```
VM.native_memory [summary|detail|baseline|summary.diff|detail.diff|shutdown|statistics]
                 [scale=KB|MB|GB]

参数说明:
├── summary      — 按子系统汇总（Java Heap / Class / Thread / Code / GC / ...）
├── detail       — 详细报告（含每个 callsite 的分配）
├── baseline     — 创建基线快照
├── summary.diff — 与基线对比（汇总）
├── detail.diff  — 与基线对比（详细）
├── shutdown     — 关闭 NMT
└── statistics   — 打印 NMT 自身的调优统计
```

### NMTDCmd::execute() 流程

```
NMTDCmd::execute():
│
├── 1. 检查 NMT 状态:
│   if (MemTracker::tracking_level() == NMT_off)
│     → "Native memory tracking is not enabled"
│   if (MemTracker::tracking_level() == NMT_minimal)
│     → "Native memory tracking has been shutdown"
│
├── 2. 解析 scale:
│   get_scale("KB") → 1024
│   get_scale("MB") → 1048576
│
├── 3. 互斥检查:
│   最多只能指定一个选项
│   默认 = summary
│
├── 4. 加锁执行:
│   MutexLocker locker(MemTracker::query_lock());
│
├── 5. 按选项执行:
│   ├── summary:
│   │   MemBaseline baseline;
│   │   baseline.baseline(summaryOnly=true);
│   │   MemSummaryReporter(baseline, output, scale).report();
│   │
│   ├── detail:
│   │   check_detail_tracking_level()
│   │   MemBaseline baseline;
│   │   baseline.baseline(summaryOnly=false);
│   │   MemDetailReporter(baseline, output, scale).report();
│   │
│   ├── baseline:
│   │   MemTracker::get_baseline().baseline(...)
│   │   → 创建快照，后续 diff 用
│   │
│   ├── summary.diff / detail.diff:
│   │   当前快照 vs 之前的 baseline
│   │   MemSummaryDiffReporter / MemDetailDiffReporter
│   │
│   └── shutdown:
│       MemTracker::shutdown();
│       → NMT 降级为 NMT_minimal，释放追踪数据
```

### NMT 输出示例

```
Native Memory Tracking:

Total: reserved=10427834KB, committed=670250KB
-                 Java Heap (reserved=8388608KB, committed=524288KB)
                            (mmap: reserved=8388608KB, committed=524288KB)
-                     Class (reserved=1056896KB, committed=4864KB)
                            (classes #1205)
                            (  instance classes #1083, array classes #122)
                            (malloc=128KB #1606)
                            (mmap: reserved=1056768KB, committed=4736KB)
-                    Thread (reserved=30815KB, committed=30815KB)
                            (thread #30)
                            (stack: reserved=30720KB, committed=30720KB)
-                      Code (reserved=250635KB, committed=8571KB)
                            (malloc=947KB #3556)
                            (mmap: reserved=249688KB, committed=7624KB)
-                        GC (reserved=466036KB, committed=99804KB)
                            (malloc=30260KB #4166)
                            (mmap: reserved=435776KB, committed=69544KB)
...
```

---

## 22.7 其他重要命令实现

### VM.flags — 打印 VM 参数

```c
void PrintVMFlagsDCmd::execute(DCmdSource source, TRAPS) {
  if (_all.value()) {
    JVMFlag::printFlags(output(), true);   // 打印所有 Flag
  } else {
    JVMFlag::printSetFlags(output());      // 只打印已设置的
  }
}
```

### VM.set_flag — 动态修改 Flag

```c
void SetVMFlagDCmd::execute(DCmdSource source, TRAPS) {
  FormatBuffer<80> err_msg("%s", "");
  int ret = WriteableFlags::set_flag(
    _flag.value(), val, JVMFlag::MANAGEMENT, err_msg);
  //                     ^^^^^^^^^^^^^^^^
  //                     标记来源为 MANAGEMENT
}
```

### GC.run — 触发 GC

```c
void SystemGCDCmd::execute(DCmdSource source, TRAPS) {
  Universe::heap()->collect(GCCause::_dcmd_gc_run);
  //                        ^^^^^^^^^^^^^^^^^^^^^
  //                        专用 GC 原因，区别于 System.gc()
}
```

### GC.heap_info — 堆信息

```c
void HeapInfoDCmd::execute(DCmdSource source, TRAPS) {
  MutexLocker hl(Heap_lock);       // 持有 Heap_lock
  Universe::heap()->print_on(output());  // 打印堆状态
}
```

### JVMTI.agent_load — 加载 Agent

```c
void JVMTIAgentLoadDCmd::execute(DCmdSource source, TRAPS) {
  if (is_java_agent) {
    // .jar → instrument agent
    JvmtiExport::load_agent_library("instrument", "false", _libpath.value(), output());
  } else {
    // .so → native agent
    JvmtiExport::load_agent_library(_libpath.value(), "true", _option.value(), output());
  }
}
// → 串联 Ch18 agentmain 链路!
```

### ManagementAgent.start — 远程 JMX 启动

```
JMXStartRemoteDCmd::execute():
│
├── loadAgentModule(THREAD)
│   → ModuleSystem.loadModule("jdk.management.agent")
│
├── 设置 System Properties:
│   "com.sun.management.jmxremote.port" = _jmxremote_port.value()
│   "com.sun.management.jmxremote.ssl" = ...
│   "com.sun.management.jmxremote.authenticate" = ...
│
└── JavaCalls::call_static(Agent, "startRemoteManagementAgent")
    → 启动 RMI 连接器
    → 监听指定端口
    → 接受远程 JMX 连接
```

---

## 22.8 HeapDumpOnOutOfMemoryError — OOME 自动 Dump

```
OOME 发生:
│
├── report_java_out_of_memory() 或 VM 内部触发
│
├── HeapDumper::dump_heap_from_oome()
│   → dump_heap(oome=true)
│
├── 文件名生成:
│   默认: java_pid<pid>.hprof
│   可配: -XX:HeapDumpPath=/path/to/dump
│   重复 dump: java_pid<pid>.hprof.1, .2, ...
│
├── HeapDumper dumper(gc=true, oome=true)
│   → _oome_thread = JavaThread::current()
│   → _oome_constructor = OutOfMemoryError.<init>()
│   → dump 时在栈顶添加伪 OOME 帧（帮助定位）
│
└── dumper.dump(my_path)
    → VMThread::execute()
    → Safepoint 下 dump
```

**关键细节**：OOME 时 dump 会在栈顶注入一个 `OutOfMemoryError.<init>()` 帧，让分析工具能直接看到哪个线程触发了 OOME。

---

## 22.9 诊断命令工具映射表

| 工具命令 | DCmd 命令 | 执行方式 | 影响 |
|----------|-----------|---------|------|
| `jcmd <pid> GC.heap_dump file.hprof` | HeapDumpDCmd | VM_HeapDumper@Safepoint | **High** |
| `jcmd <pid> GC.class_histogram` | ClassHistogramDCmd | VM_GC_HeapInspection@Safepoint | **High** |
| `jcmd <pid> GC.heap_info` | HeapInfoDCmd | Heap_lock | Medium |
| `jcmd <pid> GC.run` | SystemGCDCmd | collect(GCCause::_dcmd_gc_run) | Medium |
| `jcmd <pid> Thread.print -l` | ThreadDumpDCmd | VM_PrintThreads@Safepoint | Medium |
| `jcmd <pid> VM.native_memory summary` | NMTDCmd | MemTracker query | Medium |
| `jcmd <pid> VM.flags -all` | PrintVMFlagsDCmd | 直接读 | Low |
| `jcmd <pid> VM.set_flag X Y` | SetVMFlagDCmd | WriteableFlags | Low |
| `jcmd <pid> VM.info` | VMInfoDCmd | VMError::print_vm_info | Low |
| `jcmd <pid> VM.version` | VersionDCmd | 直接打印 | Low |
| `jcmd <pid> JVMTI.agent_load path` | JVMTIAgentLoadDCmd | load_agent_library | Low |
| `jcmd <pid> ManagementAgent.start` | JMXStartRemoteDCmd | 启动 RMI | Medium |
| `jcmd <pid> VM.symboltable -verbose` | SymboltableDCmd | VM_DumpHashtable@Safepoint | Medium |
| `jcmd <pid> VM.class_hierarchy` | ClassHierarchyDCmd | Safepoint | Medium |
| `jmap -dump:file=x.hprof <pid>` | Attach → dump_heap | HeapDumper::dump | **High** |
| `jmap -histo <pid>` | Attach → inspectheap | VM_GC_HeapInspection | **High** |
| `jstack <pid>` | Attach → threaddump | VM_PrintThreads | Medium |

---

## 22.10 面试专题

### Q1: jcmd GC.heap_dump 底层做了什么？会导致应用停顿吗？

**源码级回答**：

1. jcmd 通过 **Attach API** 发送 `jcmd` 命令到目标 JVM
2. AttachListener 线程接收后调用 `DCmd::parse_and_execute()`
3. 解析出 `GC.heap_dump`，找到 `HeapDumpDCmd` 工厂
4. `HeapDumpDCmd::execute()` 创建 `HeapDumper` → `VM_HeapDumper`
5. `VM_HeapDumper` 继承 `VM_GC_Operation`，**在 Safepoint 下执行**
6. **会导致应用停顿！** STW 期间遍历整个堆写入 HPROF 文件
7. 默认先做 Full GC（`-all` 跳过），GC + Dump 双重停顿
8. 支持 gzip 压缩（`-gz=1`），用 worker 线程并行压缩

**关键**：对生产大堆（50GB+）慎用，STW 可达分钟级。建议 `-all` 跳过 GC。

### Q2: HeapDumper 的并行设计是怎样的？

- `VM_HeapDumper` 同时继承 `VM_GC_Operation`（Safepoint 执行）和 `AbstractGangTask`（并行任务）
- `doit()` 使用 GC 的 `WorkGang`（safepoint workers）
- **VM 线程（worker 0）**做所有遍历 + 序列化
- **其他 worker 线程**做 `writer_loop()` — 从队列取 buffer → 压缩 → 写文件
- 这是**流水线并行**：VM 线程生产数据，worker 线程消费（压缩+写入）

### Q3: NMT 对性能的影响有多大？

- `-XX:NativeMemoryTracking=off`：零开销（默认）
- `-XX:NativeMemoryTracking=summary`：约 5-10% 内存开销，性能影响极小
- `-XX:NativeMemoryTracking=detail`：每次 malloc/mmap 记录 callsite，约 5-10% 性能开销
- NMT 数据结构自身也消耗内存，large app 可达几十 MB
- `VM.native_memory shutdown` 可运行时关闭（不可重启）

### Q4: DCmd 框架如何实现命令的可扩展性？

- **工厂模式**：`DCmdFactory` → `DCmdFactoryImpl<T>` 模板
- **单链表注册**：`register_DCmdFactory()` 追加到全局链表
- **编译期绑定**：`DCmdFactoryImpl<HeapDumpDCmd>` 自动绑定 name/description/impact
- **三源导出**：Internal / AttachAPI / MBean，不同命令可选择性导出
- **扩展点**：`register_dcmds_ext()` 允许平台特定命令
- **参数解析**：`DCmdParser` 支持 option（`-all`）和 argument（位置参数）

### Q5: HeapDump 文件为什么那么大？如何优化？

**为什么大**：
- HPROF 格式包含**每个对象的完整字段数据**
- 一个 byte[1024] 就占 1KB + 固定头部
- String 对象大量存在，每个含 char[]

**优化方法**：
1. `-gz=1`：gzip 压缩，通常压缩到 1/5 ~ 1/10
2. `-all`：跳过 GC，减少 STW 时间（文件可能更大）
3. 使用 `GC.class_histogram` 替代（只统计不 dump 数据）
4. 选择性分析：用 MAT 的 shallow/retained heap 分析

### Q6: DCmd 框架与 Attach API 是什么关系？

- **Attach API** 是传输层：负责将命令从 jcmd 进程传到目标 JVM
- **DCmd 框架** 是执行层：负责命令注册、解析和执行
- 连接点在 `attachListener.cpp` 的 `jcmd` 操作：

```
AttachListener::jcmd():
├── 从 socket 读取命令字符串
├── DCmd::parse_and_execute(DCmd_Source_AttachAPI, out, cmd, ' ', THREAD)
└── 输出结果写回 socket
```

---

*分析文件*：
- `src/hotspot/share/services/diagnosticFramework.hpp` — DCmd/DCmdFactory/DCmdParser 核心框架
- `src/hotspot/share/services/diagnosticFramework.cpp` — 框架实现（parse_and_execute）
- `src/hotspot/share/services/diagnosticCommand.hpp` — 所有诊断命令类定义（35+）
- `src/hotspot/share/services/diagnosticCommand.cpp` — 命令注册（register_dcmds）+ 命令实现
- `src/hotspot/share/services/heapDumper.hpp` — HeapDumper 接口
- `src/hotspot/share/services/heapDumper.cpp` — HPROF Dump 完整实现（2113 行）
- `src/hotspot/share/services/heapDumperCompression.hpp` — DumpWriter/CompressionBackend/GZipCompressor
- `src/hotspot/share/services/nmtDCmd.hpp` — NMT 诊断命令定义
- `src/hotspot/share/services/nmtDCmd.cpp` — NMT 命令实现（summary/detail/baseline/diff/shutdown）
