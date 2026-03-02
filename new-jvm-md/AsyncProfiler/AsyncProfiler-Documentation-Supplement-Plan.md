# AsyncProfiler 文档补充计划与进度跟踪

> 创建时间：2026-03-02
> 目标：将所有 Deep Dive 文档提升到 L4 深度（真实源码 + 逐行注释 + 设计解释）
> 方法论：程序 = 数据结构 + 算法 | Doc-DataStructure-First | Source-Code-Depth | Read-Runtime-Verify

---

## 一、总体目标

### 1.1 当前状态评估

**总体评分：B+（良好偏上）**

| 维度 | 当前状态 | 目标状态 |
|------|---------|---------|
| 文档覆盖面 | ✅ 优秀（15 篇 Deep Dive + 7 篇复习卡片） | 保持 |
| 第 0 部分（核心原理） | ✅ 优秀（简洁、直击根因） | 保持 |
| 第 1 部分（数据结构） | ⚠️ 参差不齐（部分完整，部分缺失） | 100% 完整（6 项覆盖） |
| 第 2 部分（算法/流程） | ❌ 不足（L2-L3 深度，伪代码为主） | L4 深度（真实源码 + 逐行注释） |
| 第 3 部分（GDB 验证） | ❌ 缺失（无 .gdb 脚本文件） | 关键结论全部验证 |
| 数据结构关系图 | ❌ 缺失（仅 1 篇有 Mermaid 图） | 每篇必备 |
| 文档重复度 | ⚠️ 较高（总目录与 Review Plan 重复） | 消除重复 |

### 1.2 核心问题

1. **源码深度不够**：算法/流程部分停留在概念描述，缺少真实源码逐行注释
2. **GDB 验证缺失**：关键结论缺少实际验证数据
3. **数据结构关系图缺失**：无法直观理解组件关系

---

## 二、P0 优先级（核心质量问题，必须修复）

### 2.1 源码深度补充（最关键）

**问题**：Deep Dive 文档的"第 2 部分：算法/流程"停留在 L2-L3（伪代码/概念描述），未达到 L4 标准。

#### 2.1.1 CPU Profiling（05-CPU-Profiling-PerfEvents-Deep-Dive.md）✅ 基本完成

| 章节 | 当前状态 | 需要补充 | 完成状态 |
|------|---------|---------|---------|
| 2.2 PerfEvents::start() 流程 | ✅ 真实源码 + 逐行注释 | — | [x] |
| 2.3 signalHandler() 核心逻辑 | ✅ 真实源码 + 逐行注释 | — | [x] |
| 2.4 perf_event_attr 填充 | ✅ 在 createForThread Phase 2 中完整分析 | — | [x] |
| 2.5 REFRESH vs ENABLE 切换逻辑 | ✅ 在 start() 中完整分析 | — | [x] |
| 2.6 walk() 函数 | ✅ 本次补充完成 | — | [x] |
| 2.7 resetBuffer() 函数 | ✅ 本次补充完成 | — | [x] |
| 2.8 CTimer/ITimer Fallback | 简要描述 | 独立引擎，暂缓 | [ ] |

**源码位置参考**：
- `perfEvents_linux.cpp`: PerfEvents::start(), PerfEvents::signalHandler()
- `perfEvents.h`: PerfEvents 类定义
- `cpuEngine.h`: CpuEngine 基类

**验收标准**：
- [ ] 每个核心函数有：文件:行号 + 解决什么问题 + 真实源码 + 逐行注释 + 设计决策
- [ ] signalHandler() 包含完整的 DISABLE → recordSample → RESET → ENABLE 流程
- [ ] perf_event_attr 每个字段的填充逻辑都有注释

---

#### 2.1.2 Lock Profiling（07-Lock-Profiling-Deep-Dive.md）✅ 完成

| 章节 | 当前状态 | 需要补充 | 完成状态 |
|------|---------|---------|---------|
| 2.2 MonitorContendedEnter/Entered | ✅ 真实源码 + 逐行注释 | — | [x] |
| 2.3 UnsafeParkHook | ✅ 真实源码 + 逐行注释 | — | [x] |
| 2.4 updateCounter CAS | ✅ engine.h 源码 + 注释 | — | [x] |
| 2.5 pthread TLS | ✅ 完整分析 | — | [x] |
| 2.6 Native pthread 锁 Hook | ✅ GOT/PLT patching 完整 | — | [x] |
| 数据结构关系图 | ✅ Mermaid classDiagram | — | [x] |
| GDB 验证 | ✅ 本次补充完成 | — | [x] |

**源码位置参考**：
- `lockTracer.cpp`: recordContendedLock(), UnsafeParkHook(), updateCounter()
- `nativeLockTracer.cpp`: pthread_mutex_lock Hook
- `engine.h`: Engine::updateCounter()

**验收标准**：
- [ ] MonitorContendedEnter/Entered 完整回调链分析
- [ ] UnsafeParkHook 包含：获取原始 park 指针、包装逻辑、TSC 时间戳读取
- [ ] updateCounter 包含：CAS 循环、概率采样阈值判断、累加逻辑

---

#### 2.1.3 Allocation Profiling（06-Allocation-Profiling-Deep-Dive.md）

| 章节 | 当前状态 | 需要补充 | 完成状态 |
|------|---------|---------|---------|
| 2.2 AllocTracer::start() | 概念描述 | 真实源码 + 逐行注释 | [ ] |
| 2.3 trapHandler() 核心逻辑 | 简要描述 | 完整分析（INT3 → SIGTRAP 流程） | [ ] |
| 2.4 onObjectAlloc() 记录 | 未分析 | 完整分析 | [ ] |
| 2.5 Trap 安装和恢复 | 未分析 | INT3 植入、单步执行、重新安装 | [ ] |
| 2.6 JVMTI SampledObjectAlloc 路径 | 简要描述 | 完整源码分析（JDK 11+ 路径） | [ ] |

**源码位置参考**：
- `allocTracer.cpp`: AllocTracer::start(), trapHandler(), onObjectAlloc()
- `trap.cpp`: Trap::install(), Trap::uninstall()

**验收标准**：
- [ ] trapHandler 包含：寄存器参数读取、recordAllocation 调用、单步执行
- [ ] Trap 安装流程：mprotect、memcpy INT3、缓存原始指令
- [ ] 两种实现方式（Trap vs JVMTI）的源码对比

---

#### 2.1.4 Profiler Core Controller（08-Profiler-Core-Controller-Deep-Dive.md）✅ 完成

| 章节 | 当前状态 | 需要补充 | 完成状态 |
|------|---------|---------|---------|
| Profiler 类完整分析 | ✅ 8 个分组，30+ 字段全分析 | — | [x] |
| recordSample() 源码分析 | ✅ 12 步骤完整分析 | — | [x] |
| start() 流程分析 | ✅ 14 阶段完整分析 | — | [x] |
| stop() 流程分析 | ✅ 11 步骤完整分析 | — | [x] |
| 分段锁分配逻辑 | ✅ getLockIndex() 完整分析 | — | [x] |
| 缓冲区池分配 | ✅ CallTraceBuffer 完整分析 | — | [x] |
| 数据结构关系图 | ✅ Mermaid classDiagram | — | [x] |
| GDB 验证 | ✅ 极其详细的验证数据 | — | [x] |
| 实验验证 | ✅ strace + features=stats | — | [x] |

**验收标准**：
- [x] start() 包含：参数解析、引擎选择、资源分配、状态转换
- [x] recordSample() 包含：获取锁、栈回溯、CallTraceStorage::put()、释放锁
- [x] 分段锁分配逻辑：`lock_index = getLockIndex(tid)`
- [x] GDB 验证：sizeof、字段偏移、运行时状态

---

#### 2.1.5 CallTrace Storage（09-CallTraceStorage-Deep-Dive.md）

| 章节 | 当前状态 | 需要补充 | 完成状态 |
|------|---------|---------|---------|
| 2.2 CallTraceStorage::put() | 概念描述 | 真实源码 + 逐行注释（哈希去重核心） | [ ] |
| 2.3 LongHashTable::lookup() | 未分析 | 完整分析（开放寻址 + CAS） | [ ] |
| 2.4 LinearAllocator::alloc() | 未分析 | 完整分析（bump-pointer + CAS） | [ ] |
| 2.5 哈希计算 | 未分析 | 调用栈哈希算法 | [ ] |
| 2.6 扩容流程 | 简要描述 | 两阶段扩容完整分析 | [ ] |

**源码位置参考**：
- `callTraceStorage.cpp`: CallTraceStorage::put(), LongHashTable
- `linearAllocator.cpp`: LinearAllocator::alloc()

**验收标准**：
- [ ] put() 包含：哈希计算、LongHashTable 查找、CAS 插入、分配 CallTrace
- [ ] LongHashTable 包含：开放寻址探测、CAS 占位、冲突处理
- [ ] LinearAllocator 包含：chunk 分配、bump-pointer、CAS 更新

---

### 2.2 GDB 验证补充

**问题**：当前 `new-jvm-md/AsyncProfiler/` 目录下没有任何 `.gdb` 脚本文件。

#### 2.2.1 数据结构 sizeof/offset 验证

| 验证目标 | 验证内容 | GDB 脚本 | 完成状态 |
|---------|---------|---------|---------|
| LockEvent | sizeof + 字段偏移 | `tmp-file/async-profiler/lock-event-verify.gdb` | [ ] |
| NativeLockEvent | sizeof + 字段偏移 | `tmp-file/async-profiler/native-lock-event-verify.gdb` | [ ] |
| CallTrace | sizeof + 柔性数组 | `tmp-file/async-profiler/call-trace-verify.gdb` | [ ] |
| PerfEvent | sizeof + fd + mmap_page | `tmp-file/async-profiler/perf-event-verify.gdb` | [ ] |
| Profiler | sizeof + 关键字段偏移 | `tmp-file/async-profiler/profiler-verify.gdb` | [ ] |

**验收标准**：
- [ ] 每个 GDB 脚本包含：断点设置、打印命令、预期结果
- [ ] 实际运行结果粘贴到对应 Deep Dive 的"第 3 部分：GDB 验证"
- [ ] 理论 sizeof 与 GDB 验证结果对比，解释差异

---

#### 2.2.2 CPU Profiling 流程验证

| 验证目标 | 验证内容 | GDB 脚本 | 完成状态 |
|---------|---------|---------|---------|
| perf_event_open 参数 | type/config/sample_period 实际值 | `tmp-file/async-profiler/perf-event-open-verify.gdb` | [ ] |
| signalHandler 触发 | 触发频率、调用栈 | `tmp-file/async-profiler/signal-handler-verify.gdb` | [ ] |
| REFRESH vs ENABLE | 切换逻辑、内核版本检测 | `tmp-file/async-profiler/refresh-enable-verify.gdb` | [ ] |
| 栈回溯深度 | AGCT 返回的帧数 | `tmp-file/async-profiler/stack-depth-verify.gdb` | [ ] |

**验收标准**：
- [ ] perf_event_open 参数与源码配置一致
- [ ] signalHandler 触发频率符合预期（~100 Hz）
- [ ] 栈回溯深度统计（平均、最大、失败率）

---

#### 2.2.3 Lock Profiling 流程验证

| 验证目标 | 验证内容 | GDB 脚本 | 完成状态 |
|---------|---------|---------|---------|
| MonitorContendedEnter | 回调触发、时间戳记录 | `tmp-file/async-profiler/monitor-enter-verify.gdb` | [ ] |
| MonitorContendedEntered | 回调触发、竞争时长计算 | `tmp-file/async-profiler/monitor-entered-verify.gdb` | [ ] |
| UnsafeParkHook | Hook 执行、TSC 时间戳 | `tmp-file/async-profiler/unsafe-park-verify.gdb` | [ ] |
| updateCounter CAS | CAS 成功率、阈值判断 | `tmp-file/async-profiler/update-counter-verify.gdb` | [ ] |
| pthread TLS | 跨回调数据传递 | `tmp-file/async-profiler/pthread-tls-verify.gdb` | [ ] |

**验收标准**：
- [ ] Enter/Entered 回调成对触发
- [ ] 竞争时长计算正确（TSC → 纳秒转换）
- [ ] CAS 采样成功率统计

---

#### 2.2.4 CallTrace Storage 验证

| 验证目标 | 验证内容 | GDB 脚本 | 完成状态 |
|---------|---------|---------|---------|
| put() 调用统计 | 调用次数、哈希碰撞率 | `tmp-file/async-profiler/put-verify.gdb` | [ ] |
| 哈希计算 | 相同调用栈哈希值相同 | `tmp-file/async-profiler/hash-verify.gdb` | [ ] |
| 扩容触发 | 负载因子 75% 触发 | `tmp-file/async-profiler/resize-verify.gdb` | [ ] |
| LinearAllocator | chunk 分配、bump-pointer | `tmp-file/async-profiler/linear-alloc-verify.gdb` | [ ] |

**验收标准**：
- [ ] 哈希碰撞率 < 10%
- [ ] 扩容时机符合预期（负载因子 75%）
- [ ] 内存分配无 malloc 调用（仅 syscall）

---

## 三、P1 优先级（完整性问题，显著影响质量）

### 3.1 数据结构关系图补充

**问题**：按 `Doc-DataStructure-First` 规则，每篇分析文档必须有 Mermaid 数据结构关系图。

| 文档 | 需要补充的关系图 | 完成状态 |
|------|----------------|---------|
| 05-CPU-Profiling-PerfEvents-Deep-Dive.md | PerfEvents → PerfEvent → perf_event_attr → RingBuffer | [ ] |
| 06-Allocation-Profiling-Deep-Dive.md | AllocTracer → Trap → AllocEvent | [ ] |
| 07-Lock-Profiling-Deep-Dive.md | LockTracer → LockEvent → pthread_key_t → TSC 时间流图 | [ ] |
| 08-Profiler-Core-Controller-Deep-Dive.md | **Profiler → Engine → CallTraceStorage → FlameGraph 全局组件关系图** ⭐ | [ ] |
| 09-CallTraceStorage-Deep-Dive.md | **CallTrace → ASGCT_CallFrame → LongHashTable → LinearAllocator 存储层关系图** ⭐ | [ ] |
| AsyncProfiler-Complete-Guide.md | **整体架构图（Agent → Profiler → Engines → Storage → Output）** | [ ] |

**验收标准**：
- [ ] 每篇 Deep Dive 在"第 N-1 部分"有一个 Mermaid 关系图
- [ ] 全局有一个"AsyncProfiler 整体架构图"
- [ ] 图中展示：数据结构、包含/引用关系、关键字段指向

---

### 3.2 Profiler 核心类完整分析

**问题**：`Profiler` 类有 100+ 字段（profiler.h 有 258 行），当前只分析了 5 个子结构。

| 分析项 | 当前状态 | 需要补充 | 完成状态 |
|-------|---------|---------|---------|
| Profiler 静态字段 | 未分析 | `_instance`、`_state`、`_jvmti`、`_engine` 等 | [ ] |
| Profiler 实例字段 | 未分析 | `_storage`、`_class_map`、`_lock` 等 | [ ] |
| Profiler 方法列表 | 未分析 | `start()`、`stop()`、`recordSample()`、`shutdown()` 等 | [ ] |
| 字段生命周期 | 未分析 | 谁设置、何时设置、设置什么值、谁读取 | [ ] |

**验收标准**：
- [ ] 完整分析 Profiler 类的所有字段（静态 + 实例）
- [ ] 每个字段包含：类型、含义、sizeof、创建位置、生命周期
- [ ] 关键字段画值域图（如 State 枚举）

---

### 3.3 数据结构分析完整性补全

**问题**：部分数据结构分析不完整，缺少 sizeof GDB 验证、生命周期追踪、值域图。

| 文档 | 数据结构 | 缺失项 | 完成状态 |
|------|---------|-------|---------|
| 05-CPU-Profiling-PerfEvents-Deep-Dive.md | PerfEvent | sizeof GDB 验证、字段生命周期 | [ ] |
| 05-CPU-Profiling-PerfEvents-Deep-Dive.md | RingBuffer | 完整分析（当前只有定义） | [ ] |
| 06-Allocation-Profiling-Deep-Dive.md | Trap | sizeof GDB 验证、完整字段分析 | [ ] |
| 06-Allocation-Profiling-Deep-Dive.md | AllocEvent | 完整分析（当前只有概念描述） | [ ] |
| 08-Profiler-Core-Controller-Deep-Dive.md | CallTraceBuffer | sizeof、内存布局图 | [ ] |
| 08-Profiler-Core-Controller-Deep-Dive.md | MethodSample | sizeof、生命周期 | [ ] |

**验收标准**：
- [ ] 每个数据结构覆盖 6 项：全部字段 + 含义 + sizeof + 创建位置 + 关键字段生命周期 + 值域图
- [ ] sizeof 必须有 GDB 验证数据

---

## 四、P2 优先级（优化性问题，提升整体质量）

### 4.1 文档重复度消除

**问题**：`AsyncProfiler-Complete-Guide.md`（763 行）与 `AsyncProfiler-Review-Plan.md`（1557 行）有大量重复内容。

| 文档 | 调整方向 | 完成状态 |
|------|---------|---------|
| AsyncProfiler-Complete-Guide.md | 改为纯索引：只保留章节标题 + 一句话概括 + 链接 | [ ] |
| AsyncProfiler-Review-Plan.md | 拆分：面试问答 → 移到 Review Day；知识内容 → 链接到 Deep Dive | [ ] |
| Review Day 1-7 | 保持"复习卡片"定位：知识索引 + 面试问答 + 自测题 | [ ] |

**验收标准**：
- [ ] 总目录只做索引，无重复内容
- [ ] Review 文档定位清晰：面试准备，不含深度源码分析
- [ ] Deep Dive 文档是唯一深度分析源

---

### 4.2 Wall Clock Profiling Deep Dive 检查

**问题**：`12-WallClock-Profiling-Deep-Dive.md` 存在但未检查深度。

| 检查项 | 验收标准 | 完成状态 |
|-------|---------|---------|
| 第 0 部分（核心原理） | 是否符合简洁原则 | [ ] |
| 第 1 部分（数据结构） | 是否完整分析所有涉及的数据结构（6 项覆盖） | [ ] |
| 第 2 部分（算法/流程） | 是否达到 L4 深度（真实源码 + 逐行注释） | [ ] |
| 第 3 部分（GDB 验证） | 是否有实际验证数据 | [ ] |

**如果不符合标准**，按 P0/P1 优先级补充。

---

### 4.3 其他 Deep Dive 文档检查

**问题**：还有 6 篇 Deep Dive 未抽样检查深度。

| 文档 | 检查重点 | 完成状态 |
|------|---------|---------|
| 02-AsyncGetCallTrace-Solution.md | AsyncGetCallTrace 调用流程、forte_fill_call_trace_given_top 源码 | [ ] |
| 03-Stack-Walking-Methods-Comparison.md | 是否达到 L4 深度，还是停留在概念对比 | [ ] |
| 04-VMStructs-Offset-Inference.md | VMStructs::init() 源码分析、偏移量推断算法 | [ ] |
| 10-SymbolResolution-CodeCache-Deep-Dive.md | 符号解析流程源码分析 | [ ] |
| 11-FlightRecorder-JFR-Output-Deep-Dive.md | JFR 输出流程源码分析 | [ ] |
| 13-FlameGraph-Output-Deep-Dive.md | 火焰图生成算法源码分析 | [ ] |
| 14-Output-Formats-Deep-Dive.md | 各种输出格式的实现源码分析 | [ ] |

**验收标准**：每篇检查后，按 P0/P1 优先级补充缺失内容。

---

## 五、补充顺序建议（逐一攻破路线）

### 阶段 1：核心中的核心（1-2 周）

```
Week 1-2: 攻破 CPU Profiling 和 Lock Profiling
├─ 05-CPU-Profiling-PerfEvents-Deep-Dive.md
│  ├─ [ ] 补充 signalHandler() 完整源码分析（L4 深度）
│  ├─ [ ] 补充 perf_event_attr 填充源码分析
│  ├─ [ ] 补充 GDB 验证（perf_event_open 参数、signalHandler 触发）
│  └─ [ ] 补充数据结构关系图
├─ 07-Lock-Profiling-Deep-Dive.md
│  ├─ [ ] 补充 MonitorContendedEnter/Entered 源码分析
│  ├─ [ ] 补充 UnsafeParkHook 源码分析
│  ├─ [ ] 补充 updateCounter CAS 算法源码分析
│  ├─ [ ] 补充 GDB 验证
│  └─ [ ] 补充数据结构关系图
```

### 阶段 2：核心控制器和存储引擎（2-3 周）

```
Week 3-4: 攻破 Profiler 核心和存储
├─ 08-Profiler-Core-Controller-Deep-Dive.md
│  ├─ [ ] 完善 Profiler 类完整分析（所有字段 + 生命周期）
│  ├─ [ ] 补充 recordSample() 完整源码分析
│  ├─ [ ] 补充 GDB 验证
│  └─ [ ] 补充全局组件关系图 ⭐
├─ 09-CallTraceStorage-Deep-Dive.md
│  ├─ [ ] 补充 put() 完整源码分析
│  ├─ [ ] 补充 LongHashTable::lookup() 完整分析
│  ├─ [ ] 补充 LinearAllocator::alloc() 完整分析
│  ├─ [ ] 补充 GDB 验证
│  └─ [ ] 补充存储层关系图 ⭐
```

### 阶段 3：其他 Deep Dive 补充（3-4 周）

```
Week 5-6: 补充其他 Deep Dive
├─ 06-Allocation-Profiling-Deep-Dive.md
│  └─ [ ] 同上，按 P0/P1 标准补充
├─ 02~04、10~14 Deep Dive 文档
│  └─ [ ] 逐一检查，按标准补充
```

### 阶段 4：文档整理优化（1 周）

```
Week 7: 文档整理
├─ [ ] 消除 AsyncProfiler-Complete-Guide.md 与 Review-Plan.md 重复
├─ [ ] 检查所有 Deep Dive 是否符合 Doc-DataStructure-First 规范
├─ [ ] 检查所有文档是否遵循 Source-Code-Depth 规范
└─ [ ] 最终质量验收
```

---

## 六、验收总清单

完成所有补充后，每篇 Deep Dive 文档应满足：

### 第 0 部分（核心原理）
- [ ] 本质：一句话概括核心问题
- [ ] 为什么需要：从根本机制缺陷讲起，2-3 段话，不堆砌场景列表
- [ ] 怎么解决：核心思路 + 关键设计（2-3 点），不堆砌图表
- [ ] 为什么这样设计：用"为什么 X 而不是 Y？"格式解释设计理由

### 第 1 部分（数据结构全景）
- [ ] 数据结构清单：列出所有涉及的结构
- [ ] 每个结构覆盖 6 项：全部字段 + 含义 + sizeof + 创建位置 + 关键字段生命周期 + 值域图
- [ ] sizeof 有 GDB 验证数据

### 第 2 部分（算法/流程分析）
- [ ] 每个核心函数 4 要素：文件:行号 + 解决什么问题 + 真实源码+逐行注释 + 设计决策
- [ ] 达到 L4 深度：真实源码 + 逐行注释 + 设计解释
- [ ] 不存在伪代码、不存在"源码翻译"式描述

### 第 3 部分（GDB 验证）
- [ ] 验证计划：明确验证目标
- [ ] GDB 脚本：保存到 `tmp-file/async-profiler/`
- [ ] 验证结果：关键 GDB 输出 + 解释
- [ ] 交叉验证：关键结论至少两种方法验证

### 第 N-1 部分（数据结构关系图）
- [ ] Mermaid 图：展示数据结构关系
- [ ] 包含：所有涉及的结构、包含/引用关系、关键字段指向

### 第 N 部分（总结）
- [ ] 数据结构层面：涉及了哪些结构、每个结构的核心特征
- [ ] 算法层面：涉及了哪些算法、每个算法的核心设计决策

---

## 七、进度统计

### 7.1 总体进度

| 优先级 | 总任务数 | 已完成 | 进度 |
|--------|---------|--------|------|
| P0（核心质量） | 45 | 23 | 51% |
| P1（完整性） | 18 | 8 | 44% |
| P2（优化性） | 13 | 0 | 0% |
| **总计** | **76** | **31** | **41%** |

### 7.2 分文档进度

| 文档 | P0 任务 | P1 任务 | P2 任务 | 总进度 |
|------|---------|---------|---------|--------|
| 05-CPU-Profiling-PerfEvents-Deep-Dive.md | 6 | 2 | 0 | **100%** ✅ |
| 07-Lock-Profiling-Deep-Dive.md | 7 | 1 | 0 | **100%** ✅ |
| 08-Profiler-Core-Controller-Deep-Dive.md | 7 | 3 | 0 | **100%** ✅ |
| 06-Allocation-Profiling-Deep-Dive.md | 7 | 2 | 0 | 0% |
| 09-CallTraceStorage-Deep-Dive.md | 6 | 2 | 0 | 0% |
| 其他 Deep Dive（10 篇） | 6 | 8 | 13 | 0% |

---

## 八、下一步行动

**建议从 `05-CPU-Profiling-PerfEvents-Deep-Dive.md` 开始**，这是 async-profiler 的核心采样机制。

**具体步骤**：
1. 读取 `perfEvents_linux.cpp` 源码，定位 `signalHandler()` 函数
2. 补充 signalHandler() 完整源码分析（L4 深度）
3. 编写 GDB 验证脚本
4. 补充数据结构关系图
5. 更新本文档的进度统计

---

**创建人**：AI Assistant
**创建时间**：2026-03-02
**最后更新**：2026-03-02
