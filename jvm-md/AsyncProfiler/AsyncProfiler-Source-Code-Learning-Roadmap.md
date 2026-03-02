# AsyncProfiler 源码学习实战大纲

> **目标**：从零开始掌握 AsyncProfiler 源码分析能力  
> **前置要求**：已完成 G1 GC 核心模块分析、熟悉 JVMTI 基础  
> **源码位置**：`/data/workspace/async-profiler/`  
> **源码版本**：v4.3 (stable)  
> **总代码量**：~16,000 行 C++ (核心) + ~5,000 行 Java (converter/api)

---

## 📁 一、源码目录结构与核心文件

### 1.1 目录结构概览

```
async-profiler/
├── src/
│   ├── main/                 # C++ 核心代码
│   │   ├── profiler.cpp/h          # 核心控制器（1917 行）⭐ 最重要
│   │   ├── vmEntry.cpp/h           # Agent 入口 + JVMTI 管理
│   │   ├── vmStructs.cpp/h         # JVM 偏移量推断
│   │   ├── engine.h                # 采样引擎基类
│   │   │
│   │   ├── perfEvents_linux.cpp    # Linux perf_event 采样 ⭐ CPU 采样核心
│   │   ├── ctimer.cpp              # CTimer fallback
│   │   ├── itimer.cpp              # ITimer fallback
│   │   ├── wallClock.cpp           # Wall Clock 采样
│   │   │
│   │   ├── allocTracer.cpp         # 对象分配追踪
│   │   ├── lockTracer.cpp          # 锁争用追踪
│   │   ├── mallocTracer.cpp        # Native 内存追踪
│   │   │
│   │   ├── stackWalker.cpp/h       # 栈回溯核心 ⭐
│   │   ├── stackFrame_x64.cpp      # x64 栈帧操作
│   │   ├── dwarf.cpp               # DWARF CFI 解析
│   │   │
│   │   ├── callTraceStorage.cpp    # 调用栈存储（去重）
│   │   ├── flightRecorder.cpp      # JFR 格式输出
│   │   ├── flameGraph.cpp          # 火焰图生成
│   │   │
│   │   ├── codeCache.cpp           # JIT 代码符号解析
│   │   ├── symbols_linux.cpp       # ELF 符号解析
│   │   ├── instrument.cpp          # 字节码插桩
│   │   └── hooks.cpp               # GOT/PLT patching
│   │
│   ├── converter/            # Java 转换器（JFR → 其他格式）
│   └── api/                  # Java API
│
├── build/                    # 编译产物
└── test/                     # 测试用例
```

### 1.2 核心文件清单（按重要性排序）

| 优先级 | 文件 | 行数 | 核心职责 | 学习难度 |
|--------|------|------|----------|----------|
| ⭐⭐⭐⭐⭐ | `profiler.cpp` | 1917 | 状态管理、引擎调度、采样记录 | ⭐⭐⭐⭐⭐ |
| ⭐⭐⭐⭐⭐ | `vmEntry.cpp` | 531 | Agent 入口、JVMTI 初始化 | ⭐⭐⭐ |
| ⭐⭐⭐⭐⭐ | `perfEvents_linux.cpp` | ~600 | Linux perf_event 采样 | ⭐⭐⭐⭐ |
| ⭐⭐⭐⭐⭐ | `stackWalker.cpp` | ~800 | 栈回溯核心逻辑 | ⭐⭐⭐⭐⭐ |
| ⭐⭐⭐⭐ | `vmStructs.cpp` | ~300 | JVM 偏移量推断 | ⭐⭐⭐⭐ |
| ⭐⭐⭐⭐ | `callTraceStorage.cpp` | 313 | 调用栈存储与去重 | ⭐⭐⭐ |
| ⭐⭐⭐ | `allocTracer.cpp` | ~186 | 对象分配追踪 | ⭐⭐⭐⭐ |
| ⭐⭐⭐ | `lockTracer.cpp` | 271 | 锁争用追踪 | ⭐⭐⭐ |
| ⭐⭐⭐ | `codeCache.cpp` | ~500 | JIT 代码符号解析 | ⭐⭐⭐ |
| ⭐⭐ | `flightRecorder.cpp` | 1500 | JFR 格式输出 | ⭐⭐⭐ |
| ⭐⭐ | `flameGraph.cpp` | ~300 | 火焰图生成 | ⭐⭐ |
| ⭐⭐ | `symbols_linux.cpp` | 881 | ELF 符号解析 | ⭐⭐⭐ |

---

## 🎯 二、学习路径设计（4 个阶段）

### 阶段 1：整体架构与入口（第 1 周）

**目标**：理解 AsyncProfiler 如何加载到 JVM、如何初始化

#### 1.1 源码阅读清单

```
必读文件：
  ├─ vmEntry.cpp (Agent_OnLoad/Agent_OnAttach/JNI_OnLoad)
  ├─ vmEntry.h (VM 类定义)
  └─ profiler.cpp (Profiler 类定义，先看头文件)

关键函数：
  ├─ Agent_OnLoad()        # 启动时加载入口
  ├─ Agent_OnAttach()      # 运行时附加入口
  ├─ VM::init()            # 核心初始化
  └─ Profiler::start()     # 启动采样
```

#### 1.2 实战练习

**练习 1：跟踪 Agent 加载流程**

```bash
# 1. 启动时加载方式
java -agentpath:/path/to/libasyncProfiler.so=start,svg=file.svg ...

# 2. 运行时附加方式
jcmd <pid> JVMTI.agent_load /path/to/libasyncProfiler.so

# 3. GDB 跟踪
gdb --args java -agentpath:...
(gdb) break Agent_OnLoad
(gdb) break VM::init
(gdb) run
```

**练习 2：理解 JVMTI Capabilities**

```cpp
// 问题：async-profiler 请求了哪些能力？为什么？
// vmEntry.cpp 中找到 jvmti->AddCapabilities()

// 动手验证：
// 1. 阅读 JVMTI 文档，理解每种能力的作用
// 2. 用 GDB 打印请求的 capabilities 结构
// 3. 思考：为什么需要 can_access_local_variables？
```

#### 1.3 核心问题清单

```
Q1: Agent_OnLoad 和 Agent_OnAttach 有什么区别？
Q2: VM::init() 做了哪些初始化？为什么 attach 参数很重要？
Q3: async-profiler 如何判断 JVM 类型（HotSpot/OpenJ9/Zing）？
Q4: JVMTI 环境是如何建立的？请求了哪些 Capabilities？
```

---

### 阶段 2：VMStructs 偏移量推断（第 2 周）

**目标**：理解 async-profiler 如何不依赖 JVM 头文件获取数据结构偏移

#### 2.1 源码阅读清单

```
必读文件：
  ├─ vmStructs.cpp (偏移量推断实现)
  ├─ vmStructs.h (VMStructs 类定义)
  └─ vmEntry.cpp (VM::ready() 函数)

核心数据结构：
  ├─ VMStructs::_thread_stack_base_offset
  ├─ VMStructs::_thread_obj_offset
  ├─ VMStructs::_java_thread_anchor_offset
  └─ VMStructs::_klass_name_offset
```

#### 2.2 实战练习

**练习 3：验证偏移量推断**

```gdb
# GDB 脚本：验证 VMStructs 推断的偏移量是否正确
break VM::ready
commands
  # 打印推断的偏移量
  printf "Thread stack base offset: %d\n", VMStructs::_thread_stack_base_offset
  printf "Thread obj offset: %d\n", VMStructs::_thread_obj_offset
  
  # 与 JVM 源码定义对比
  # hotspot/share/runtime/thread.hpp:
  #   class JavaThread {
  #     ...
  #     intptr_t* _stack_base;  // 偏移量应该是多少？
  #   }
  
  continue
end
```

**练习 4：理解推断算法**

```cpp
// 问题：VMStructs 如何不依赖头文件推断偏移量？
// 
// 提示：三种方法
//   1. 从 VMStructs 符号表中查找（JVM 导出的）
//   2. 从已知对象推断（如线程栈基址）
//   3. 从 JVM 代码模式推断（如解释器帧）
//
// 动手：vmStructs.cpp 中找到这三种方法的实现
```

#### 2.3 核心问题清单

```
Q1: 为什么 async-profiler 不直接使用 JVM 头文件？
Q2: VMStructs 有哪几种偏移量推断方法？各有什么优劣？
Q3: 如何验证推断的偏移量是正确的？
Q4: 不同 JVM 版本如何处理偏移量差异？
```

---

### 阶段 3：CPU 采样核心（第 3 周）⭐ 最重要

**目标**：理解 Linux perf_event 采样机制和栈回溯算法

#### 3.1 源码阅读清单

```
必读文件：
  ├─ perfEvents_linux.cpp (perf_event_open 封装)
  ├─ profiler.cpp (recordSample 函数)
  ├─ stackWalker.cpp (栈回溯核心)
  ├─ stackFrame_x64.cpp (x64 栈帧操作)
  └─ dwarf.cpp (DWARF CFI 解析)

关键函数：
  ├─ PerfEvents::start()           # 启动 perf_event
  ├─ PerfEvents::signalHandler()   # 信号处理器
  ├─ Profiler::recordSample()      # 采样入口
  ├─ StackWalker::walk()           # 栈回溯主函数
  ├─ StackWalker::walkFP()         # Frame Pointer 方式
  └─ StackWalker::walkDwarf()      # DWARF CFI 方式
```

#### 3.2 实战练习

**练习 5：理解 perf_event_open**

```cpp
// 问题：async-profiler 如何配置 perf_event？

// 步骤：
// 1. 阅读 perfEvents_linux.cpp 中的 PerfEvents::start()
// 2. 找到 perf_event_open 的调用
// 3. 分析 attr 结构体的配置
//    - type = PERF_TYPE_HARDWARE?
//    - config = PERF_COUNT_HW_CPU_CYCLES?
//    - sample_period = 多少？
//    - 如何处理多线程？

// 动手：用 GDB 打印 attr 结构
break perf_event_open
commands
  printf "perf_event_open called\n"
  print *attr
  continue
end
```

**练习 6：跟踪采样流程**

```gdb
# 从信号触发到栈回溯的完整流程
break PerfEvents::signalHandler
commands
  printf "=== SIGPROF 信号触发 ===\n"
  printf "当前线程: %p\n", $arg0
  printf "信号信息: %p\n", $arg1
  backtrace 10
  continue
end

break Profiler::recordSample
commands
  printf "=== 开始采样 ===\n"
  printf "调用栈深度: %d\n", $arg1
  continue
end
```

**练习 7：理解栈回溯算法**

```cpp
// 问题：async-profiler 如何回溯调用栈？
//
// 关键概念：
//   1. Frame Pointer (FP) 链式回溯
//      - 优点：简单、快速
//      - 缺点：需要 -fno-omit-frame-pointer 编译选项
//
//   2. DWARF CFI (Call Frame Information)
//      - 优点：不需要 FP，支持所有优化级别
//      - 缺点：复杂、需要 .eh_frame 段
//
//   3. JVM 内部帧识别
//      - 利用 VMStructs 推断的偏移量
//      - 处理解释器帧、JIT 帧、native 帧
//
// 动手：
//   在 stackWalker.cpp 中找到 walkFP/walkDwarf/walkVM 的实现
//   理解每种方式的适用场景
```

#### 3.3 核心问题清单

```
Q1: perf_event_open 如何配置？事件类型/采样周期如何决定？
Q2: SIGPROF 信号处理器里做了什么？为什么可以在信号上下文中安全调用？
Q3: AsyncGetCallTrace 是什么？为什么不需要 Safepoint？
Q4: FP 回溯和 DWARF 回溯有什么区别？何时使用哪种？
Q5: 如何处理混合栈（Java 帧 + native 帧）？
Q6: 如何保证栈回溯的安全性（避免访问无效内存）？
```

---

### 阶段 4：高级追踪与输出（第 4 周）

**目标**：理解对象分配追踪、锁争用追踪、数据存储与输出

#### 4.1 源码阅读清单

```
追踪引擎：
  ├─ allocTracer.cpp (对象分配追踪)
  ├─ lockTracer.cpp (锁争用追踪)
  ├─ wallClock.cpp (Wall Clock 采样)
  └─ instrument.cpp (字节码插桩)

数据存储：
  ├─ callTraceStorage.cpp (调用栈去重与存储)
  ├─ flightRecorder.cpp (JFR 格式)
  └─ flameGraph.cpp (火焰图生成)
```

#### 4.2 实战练习

**练习 8：对象分配追踪**

```cpp
// 问题：async-profiler 如何追踪对象分配？
//
// 两种方式：
//   1. Trap 机制（旧方法）
//      - 在 JVM 分配代码中植入断点
//      - 触发 SIGTRAP 信号
//      - 在信号处理器中记录分配
//
//   2. JVMTI SampledObjectAlloc（新方法）
//      - 使用 JVMTI 提供的事件
//      - JVM 内置采样
//      - 开销更小
//
// 动手：
//   阅读 allocTracer.cpp，理解两种方式的实现
//   思考：为什么要有两种方式？各有什么优劣？
```

**练习 9：锁争用追踪**

```cpp
// 问题：async-profiler 如何追踪锁争用？
//
// 关键：JVMTI MonitorContendedEnter 事件
//
// 步骤：
//   1. 注册 MonitorContendedEnter 回调
//   2. 在回调中记录争用事件
//   3. 关联到调用栈
//
// 动手：
//   阅读 lockTracer.cpp，理解实现
//   与 G1 GC 的 ObjectMonitor 分析对比
```

**练习 10：调用栈去重**

```cpp
// 问题：CallTraceStorage 如何去重和存储调用栈？
//
// 关键数据结构：
//   - CallTrace: 调用栈表示
//   - CallTraceStorage: 存储与去重
//
// 算法：
//   1. 计算调用栈哈希
//   2. 查找是否已存在
//   3. 不存在则插入，存在则增加计数
//
// 动手：
//   阅读 callTraceStorage.cpp
//   理解并发安全保证
```

#### 4.3 核心问题清单

```
Q1: 对象分配追踪如何实现？Trap 机制如何工作？
Q2: 锁争用追踪如何实现？与 G1 GC 的 ObjectMonitor 有什么关系？
Q3: Wall Clock 采样和 CPU 采样有什么区别？
Q4: 调用栈如何去重？并发安全如何保证？
Q5: JFR 格式是什么？如何生成？
Q6: 火焰图如何生成？数据结构是什么？
```

---

## 🔗 三、与 G1 GC 知识的结合点

### 3.1 关键交叉点

| AsyncProfiler 概念 | G1 GC 知识点 | 结合方式 |
|-------------------|-------------|----------|
| **JVMTI Agent** | AttachListener 机制 | Agent_OnAttach 通过 Attach API 加载 |
| **VMStructs 偏移量** | HeapRegion/G1CollectedHeap | 直接访问 JVM 数据结构 |
| **栈帧识别** | 解释器帧/JIT 帧 | 理解帧结构才能回溯 |
| **AsyncGetCallTrace** | Safepoint 机制 | 为什么不需要 Safepoint |
| **对象分配追踪** | TLAB/PLAB/分配路径 | 在分配路径上植入探针 |
| **锁争用追踪** | ObjectMonitor | 监控锁争用事件 |
| **符号解析** | CodeCache/nmethod | 从 JIT 代码中解析符号 |
| **内存映射** | G1 Region | 理解内存布局 |

### 3.2 实战案例

**案例 1：分析 GC 暂停期间的调用栈**

```bash
# 使用 async-profiler 分析 GC 暂停
asprof -d 60 -f gc_pause.html <pid>

# 问题：
#   1. GC 暂停期间能采集到调用栈吗？
#   2. 为什么能/不能？
#   3. 如何分析 GC 暂停瓶颈？

# 结合 G1 GC 知识：
#   - GC 暂停时所有应用线程在 Safepoint
#   - async-profiler 的信号处理器可能无法执行
#   - 但可以在 GC 前后采集，分析 GC 频率和耗时
```

**案例 2：分析对象分配热点**

```bash
# 使用 alloc 追踪找出分配热点
asprof -d 60 -e alloc -f alloc.html <pid>

# 结合 G1 GC 知识：
#   - 找出哪些对象分配最多
#   - 是否触发 TLAB refil？
#   - 是否有 Humongous 对象？
#   - 如何优化？
```

**案例 3：分析锁争用**

```bash
# 使用 lock 追踪找出锁争用
asprof -d 60 -e lock -f lock.html <pid>

# 结合 G1 GC 知识：
#   - ObjectMonitor 如何工作？
#   - 锁争用对 GC 有什么影响？
#   - 如何优化？
```

---

## 📝 四、源码分析方法论

### 4.1 自顶向下阅读法

```
步骤：
  1. 从入口开始（Agent_OnLoad/Agent_OnAttach）
  2. 跟踪主要流程（初始化 → 启动 → 采样 → 停止 → 输出）
  3. 识别关键数据结构（Profiler, Engine, CallTraceStorage）
  4. 深入核心算法（栈回溯、去重、符号解析）
  5. 理解边界条件（错误处理、并发安全）
```

### 4.2 问题驱动阅读法

```
步骤：
  1. 提出问题（如：如何实现 CPU 采样？）
  2. 找到相关文件（perfEvents_linux.cpp）
  3. 跟踪关键函数（start → signalHandler → recordSample）
  4. 理解数据流（信号 → 栈回溯 → 存储）
  5. 验证理解（GDB 断点 + 打印）
```

### 4.3 对比阅读法

```
步骤：
  1. 对比不同采样引擎（PerfEvents vs WallClock vs AllocTracer）
  2. 对比不同栈回溯方式（walkFP vs walkDwarf vs walkVM）
  3. 对比不同输出格式（JFR vs FlameGraph vs collapsed）
  4. 理解设计决策（为什么选择这种方式？）
```

---

## 🛠 五、调试工具与技巧

### 5.1 GDB 调试脚本

```gdb
# async_profiler_debug.gdb
# AsyncProfiler 调试脚本

# 1. Agent 加载
break Agent_OnLoad
break Agent_OnAttach
break VM::init

# 2. 采样流程
break PerfEvents::signalHandler
break Profiler::recordSample

# 3. 栈回溯
break StackWalker::walk
break StackWalker::walkFP
break StackWalker::walkDwarf

# 4. 数据存储
break CallTraceStorage::put

# 5. 输出
break FlameGraph::dump

run
```

### 5.2 日志与追踪

```bash
# 启用详细日志
asprof -d 60 -v -f profile.html <pid>

# 输出到文件
asprof -d 60 -v -o log -f profile.log <pid>

# 与 GC 日志结合
-Xlog:gc*:file=gc.log
asprof -d 60 -f profile.html <pid>
```

### 5.3 源码注释

```cpp
// 建议在关键函数添加注释
// 例如：profiler.cpp

bool Profiler::start(Checks& checks) {
    // 1. 检查参数
    // 2. 选择引擎
    // 3. 初始化存储
    // 4. 启动采样
    // 5. 启动工作线程
}
```

---

## 📚 六、参考资源

### 6.1 官方资源

- AsyncProfiler GitHub: https://github.com/jvm-profiling-tools/async-profiler
- 文档: https://github.com/jvm-profiling-tools/async-profiler/blob/master/docs
- FAQ: https://github.com/jvm-profiling-tools/async-profiler/wiki

### 6.2 相关 JVM 文档

- JVMTI 规范: https://docs.oracle.com/javase/11/docs/specs/jvmti.html
- Linux perf_event: `man perf_event_open`
- DWARF CFI: https://dwarfstd.org/doc/DWARF5.pdf

### 6.3 已有分析文档

- AsyncProfiler 完整分析: `/data/workspace/openjdk-cut-new/jvm-md/AsyncProfiler/`
- JVM Native Libraries 分析: `/data/workspace/openjdk-cut-new/jvm-md/JVM-Native-Libraries/`
- G1 GC 完整分析: `/data/workspace/openjdk-cut-new/jvm-md/G1CollectedHeap-Rewrite/`

---

## ✅ 七、学习检查点

### 第 1 周检查点

- [ ] 能用自己的话解释 Agent_OnLoad 和 Agent_OnAttach 的区别
- [ ] 能列出 VM::init() 做的 5 件关键事情
- [ ] 能说明 async-profiler 请求了哪些 JVMTI Capabilities
- [ ] 能用 GDB 跟踪 Agent 加载流程

### 第 2 周检查点

- [ ] 能解释为什么 async-profiler 不依赖 JVM 头文件
- [ ] 能列出 VMStructs 的 3 种偏移量推断方法
- [ ] 能验证推断的偏移量是否正确
- [ ] 能理解不同 JVM 版本的兼容性问题

### 第 3 周检查点

- [ ] 能解释 perf_event_open 的配置参数
- [ ] 能描述从 SIGPROF 信号到调用栈记录的完整流程
- [ ] 能对比 FP 回溯和 DWARF 回溯的优劣
- [ ] 能用 GDB 跟踪采样流程

### 第 4 周检查点

- [ ] 能解释对象分配追踪的两种方式
- [ ] 能说明锁争用追踪的实现原理
- [ ] 能理解调用栈去重算法
- [ ] 能分析火焰图数据结构

---

**预计总工时**: 4 周（每天 2-3 小时）  
**每阶段产出**: 1 份学习笔记 + 3-5 个实战练习  
**最终目标**: 能独立分析 AsyncProfiler 新功能，甚至贡献代码

---

**下一步建议**：

1. **立即开始**：按照阶段 1 的清单开始阅读源码
2. **边读边记**：每读完一个文件，用自己的话总结
3. **实践验证**：用 GDB 跟踪关键函数，验证理解
4. **结合 G1 GC**：思考 AsyncProfiler 如何与 G1 GC 交互

**准备好了吗？让我们从 vmEntry.cpp 开始！**
