# Threads::create_vm() 完整大纲

> **源码位置**: `src/hotspot/share/runtime/thread.cpp:3876`
> **重要程度**: ⭐⭐⭐⭐⭐ (JVM 启动核心入口)
> **代码行数**: ~400 行
> **调用链路**: `JavaMain()` → `InitializeJVM()` → `JNI_CreateJavaVM()` → `Threads::create_vm()`

---

## 📊 整体阶段划分

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                        Threads::create_vm() 执行流程                              │
├─────────────────────────────────────────────────────────────────────────────────┤
│  Phase 0: 前置检查与基础初始化 (L3876-L3920)                                       │
│  Phase 1: OS 模块与参数解析 (L3921-L3980)                                         │
│  Phase 2: 全局数据结构初始化 (L3981-L4020)                                         │
│  Phase 3: 主线程创建与附加 (L4021-L4080)                                          │
│  Phase 4: 核心模块初始化 - init_globals() (L4081-L4100) ✅已完成                   │
│  Phase 5: VMThread 创建与启动 (L4101-L4130) ✅已完成                              │
│  Phase 6: Java 基础类初始化 (L4131-L4180)                                         │
│  Phase 7: 模块系统与编译器初始化 (L4181-L4240)                                     │
│  Phase 8: 后续服务线程与收尾工作 (L4241-L4310)                                     │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 📋 详细大纲

### Phase 0: 前置检查与基础初始化 ⭐⭐

| 序号 | 函数调用 | 重要程度 | 分析状态 | 说明 |
|-----|---------|---------|---------|------|
| 0.1 | `VM_Version::early_initialize()` | ⭐⭐ | ⬜ 未分析 | CPU 特性早期检测 |
| 0.2 | `is_supported_jni_version()` | ⭐ | ⬜ 跳过 | JNI 版本检查 |
| 0.3 | `ThreadLocalStorage::init()` | ⭐⭐⭐ | ⬜ 未分析 | **TLS 初始化 - Thread::current() 的基础** |
| 0.4 | `ostream_init()` | ⭐ | ⬜ 跳过 | 输出流初始化 |
| 0.5 | `Arguments::process_sun_java_launcher_properties()` | ⭐ | ⬜ 跳过 | 启动器属性处理 |

**核心点**:
- `ThreadLocalStorage::init()` 是让每个线程能通过 `Thread::current()` 获取自己的 Thread 对象的基础

---

### Phase 1: OS 模块与参数解析 ⭐⭐⭐

| 序号 | 函数调用 | 重要程度 | 分析状态 | 说明 |
|-----|---------|---------|---------|------|
| 1.1 | `os::init()` | ⭐⭐⭐ | ⬜ 未分析 | **OS 相关的系统环境初始化** |
| 1.2 | `Arguments::init_system_properties()` | ⭐⭐ | ⬜ 未分析 | 初始化 JVM 系统属性 |
| 1.3 | `JDK_Version_init()` | ⭐ | ⬜ 跳过 | JDK 版本初始化 |
| 1.4 | `Arguments::init_version_specific_system_properties()` | ⭐ | ⬜ 跳过 | 版本特定属性 |
| 1.5 | `LogConfiguration::initialize()` | ⭐ | ⬜ 跳过 | 日志配置初始化 |
| 1.6 | `Arguments::parse()` | ⭐⭐⭐ | ⬜ 未分析 | **解析 JVM 启动参数** |
| 1.7 | `os::init_before_ergo()` | ⭐⭐ | ⬜ 未分析 | 自动调优前置准备 (CPU核心数/大页/保护页) |
| 1.8 | `Arguments::apply_ergo()` | ⭐⭐⭐ | ⬜ 未分析 | **自动调优 (Ergonomics)** |
| 1.9 | `JVMFlagRangeList::check_ranges()` | ⭐ | ⬜ 跳过 | 参数范围检查 |
| 1.10 | `JVMFlagConstraintList::check_constraints()` | ⭐ | ⬜ 跳过 | 参数约束检查 |

**核心点**:
- `Arguments::parse()` 解析 `-Xmx`, `-Xms`, `-XX:` 等所有启动参数
- `Arguments::apply_ergo()` 自动调优，根据机器配置自动设置最佳参数

---

### Phase 2: 全局数据结构初始化 ⭐⭐⭐

| 序号 | 函数调用 | 重要程度 | 分析状态 | 说明 |
|-----|---------|---------|---------|------|
| 2.1 | `os::init_2()` | ⭐⭐⭐ | ✅ 已完成 | **OS 模块第二阶段初始化 (信号/内存/线程)** |
| 2.2 | `SafepointMechanism::initialize()` | ⭐⭐⭐ | ✅ 已完成 | **分配 Polling Page (安全点机制)** |
| 2.3 | `Arguments::adjust_after_os()` | ⭐ | ⬜ 跳过 | OS 相关参数微调 |
| 2.4 | `ostream_init_log()` | ⭐ | ⬜ 跳过 | 日志文件输出初始化 |
| 2.5 | `convert_vm_init_libraries_to_agents()` | ⭐ | ⬜ 跳过 | -Xrun 转 -agentlib 兼容 |
| 2.6 | `create_vm_init_agents()` | ⭐⭐ | ⬜ 可选 | Agent 初始化 (JDWP/性能探针等) |
| 2.7 | `vm_init_globals()` | ⭐⭐⭐ | ✅ 已完成 | **VM 全局数据结构初始化** |

**核心点**:
- `SafepointMechanism::initialize()` 安全点机制的基础，GC 时让所有线程暂停的关键
- `vm_init_globals()` 初始化各种全局管理器，为后续 init_globals() 做准备
- `os::init_2()` 信号处理机制的建立，包括 SIGSEGV → NPE/SOE/Safepoint

**已完成分析文档**:
- [SafepointMechanism 安全点机制](./Safepoint/SafepointMechanism.md)
- [2.1 os::init_2() 分析](./Phase2/2.1_os_init_2_analysis.md)
- [2.2 vm_init_globals() 分析](./Phase2/2.2_vm_init_globals_analysis.md)

---

### Phase 3: 主线程创建与附加 ⭐⭐⭐⭐ ✅ 已完成

> **详细子大纲**: [Phase3_main_thread_outline.md](./Phase3_main_thread_outline.md)

| 序号 | 函数调用 | 重要程度 | 分析状态 | 说明 |
|-----|---------|---------|---------|------|
| 3.1 | `new JavaThread()` | ⭐⭐⭐⭐ | ✅ 已完成 | **创建 JavaThread 对象** |
| 3.2 | `main_thread->set_thread_state(_thread_in_vm)` | ⭐⭐ | ✅ 已完成 | 设置线程状态 |
| 3.3 | `main_thread->initialize_thread_current()` | ⭐⭐⭐ | ✅ 已完成 | **绑定到 OS 线程 (TLS)** |
| 3.4 | `main_thread->record_stack_base_and_size()` | ⭐⭐ | ✅ 已完成 | 记录栈基址和大小 |
| 3.5 | `main_thread->register_thread_stack_with_NMT()` | ⭐ | ⬜ 跳过 | NMT 内存追踪注册 |
| 3.6 | `main_thread->set_active_handles()` | ⭐⭐ | ✅ 已完成 | JNI Handle 分配 |
| 3.7 | `main_thread->set_as_starting_thread()` | ⭐⭐⭐⭐ | ✅ 已完成 | **附加到 OS 线程 (创建 OSThread)** |
| 3.8 | `main_thread->create_stack_guard_pages()` | ⭐⭐⭐ | ✅ 已完成 | 创建栈保护页 (防止栈溢出) |
| 3.9 | `ObjectMonitor::Initialize()` | ⭐⭐⭐ | ✅ 已完成 | **Java 同步子系统初始化** |

**核心点**:
- 这里创建的是 **JVM 内部的主线程**，不是 Java 的 main 线程
- `JavaThread` 是 C++ 对象，与 `java.lang.Thread` 不同
- `set_as_starting_thread()` 创建 `OSThread` 并与 OS 线程关联

**已完成分析文档**:
- [3.1 JavaThread 与 OSThread 分析](./Phase3/3.1_JavaThread_OSThread_analysis.md)
- [3.2 线程状态分析](./Phase3/3.2_thread_state_analysis.md)
- [3.4/3.7 栈信息与栈保护页](./Phase3/3.4_3.7_stack_analysis.md)
- [3.5 JNI Handle 分配](./Phase3/3.5_jni_handle_analysis.md)
- [3.8 ObjectMonitor 机制](./Phase3/3.8_objectmonitor_analysis.md)

---

### Phase 4: 核心模块初始化 ✅ 已完成

| 序号 | 函数调用 | 重要程度 | 分析状态 | 说明 |
|-----|---------|---------|---------|------|
| 4.1 | `init_globals()` | ⭐⭐⭐⭐⭐ | ✅ 已完成 | **JVM 核心模块初始化** |

**已分析内容**:
- `codeCache_init()` - JIT 代码缓存
- `universe_init()` / `universe2_init()` / `universe_post_init()` - 堆创建、类加载
- `interpreter_init()` - 模板解释器
- `compileBroker_init()` - 编译器线程
- `stubRoutines_init1/2()` - 桩代码
- ... 等 19 个核心模块

---

### Phase 5: VMThread 创建与启动 ⭐⭐⭐⭐ ✅ 已完成

| 序号 | 函数调用 | 重要程度 | 分析状态 | 说明 |
|-----|---------|---------|---------|------|
| 5.1 | `Threads::add(main_thread)` | ⭐⭐ | ✅ 已完成 | 主线程加入线程链表 |
| 5.2 | `JvmtiExport::transition_pending_onload_raw_monitors()` | ⭐ | ⬜ 跳过 | JVMTI 监视器转换 |
| 5.3 | `VMThread::create()` | ⭐⭐⭐⭐ | ✅ 已完成 | **创建 VMThread 对象** |
| 5.4 | `os::create_thread(vmthread, os::vm_thread)` | ⭐⭐⭐ | ✅ 已完成 | **创建 VMThread 的 OS 线程** |
| 5.5 | `os::start_thread(vmthread)` | ⭐⭐⭐ | ✅ 已完成 | **启动 VMThread** |
| 5.6 | `VM_Verify verify_op` (可选) | ⭐ | ⬜ 跳过 | 启动验证 |

**核心点**:
- `VMThread` 是 JVM 的核心后台线程，负责执行 VM 操作 (GC、偏向锁撤销、类卸载等)
- 所有需要安全点的操作都由 VMThread 执行

---

### Phase 6: Java 基础类初始化 ⭐⭐⭐⭐

| 序号 | 函数调用 | 重要程度 | 分析状态 | 说明 |
|-----|---------|---------|---------|------|
| 6.1 | `JvmtiExport::enter_early_start_phase()` | ⭐ | ⬜ 跳过 | JVMTI 进入早期启动阶段 |
| 6.2 | `JvmtiExport::post_early_vm_start()` | ⭐ | ⬜ 跳过 | JVMTI 通知 |
| 6.3 | `initialize_java_lang_classes()` | ⭐⭐⭐⭐⭐ | ✅ 已完成 | **初始化 java.lang 核心类** |
| 6.4 | `quicken_jni_functions()` | ⭐ | ⬜ 跳过 | JNI 函数加速 |
| 6.5 | `StubCodeDesc::freeze()` | ⭐⭐ | ⬜ 跳过 | 冻结桩代码（不允许再生成） |
| 6.6 | `set_init_completed()` | ⭐⭐ | ✅ 已完成 | 标记基础初始化完成 |

**`initialize_java_lang_classes()` 详细展开**:

```
initialize_java_lang_classes(main_thread, CHECK)
├── initialize_class(java_lang_String)          // String 类
├── java_lang_String::set_compact_strings()     // 紧凑字符串设置
├── initialize_class(java_lang_System)          // System 类
├── initialize_class(java_lang_Class)           // Class 类
├── initialize_class(java_lang_ThreadGroup)     // ThreadGroup 类
├── create_initial_thread_group()               // 创建主线程组
├── initialize_class(java_lang_Thread)          // Thread 类
├── create_initial_thread()                     // 创建 Java 主线程对象
├── main_thread->set_threadObj()                // 绑定到 JavaThread
├── initialize_class(java_lang_Module)          // Module 类
├── initialize_class(java_lang_reflect_Method)  // Method 类
├── initialize_class(java_lang_ref_Finalizer)   // Finalizer 类
├── call_initPhase1()                           // System.initPhase1()
├── JDK_Version::set_runtime_name/version()     // 设置运行时版本信息
├── initialize_class(java_lang_OutOfMemoryError)     // OOM 类
├── initialize_class(java_lang_NullPointerException) // NPE 类
├── initialize_class(java_lang_ClassCastException)   // CCE 类
├── initialize_class(java_lang_ArrayStoreException)  // ASE 类
├── initialize_class(java_lang_ArithmeticException)  // AE 类
├── initialize_class(java_lang_StackOverflowError)   // SOE 类
├── initialize_class(java_lang_IllegalMonitorStateException)  // IMSE 类
└── initialize_class(java_lang_IllegalArgumentException)      // IAE 类
```

**核心点**:
- 这里真正创建了 **Java 的 main 线程对象** (`java.lang.Thread`)
- `call_initPhase1()` 调用 `System.initPhase1()` 初始化系统属性、标准流等

---

### Phase 7: 模块系统与编译器初始化 ⭐⭐⭐

| 序号 | 函数调用 | 重要程度 | 分析状态 | 说明 |
|-----|---------|---------|---------|------|
| 7.1 | `os::initialize_jdk_signal_support()` | ⭐⭐ | ⬜ 未分析 | JDK 信号支持初始化 |
| 7.2 | `AttachListener::init()` | ⭐⭐ | ⬜ 可选 | Attach 机制初始化 (jstack/jmap) |
| 7.3 | `ServiceThread::initialize()` | ⭐⭐ | ⬜ 未分析 | 服务线程初始化 |
| 7.4 | `CompileBroker::compilation_init_phase1()` | ⭐⭐⭐ | ⬜ 未分析 | **编译器初始化 Phase 1** |
| 7.5 | `CompileBroker::compilation_init_phase2()` | ⭐⭐⭐ | ⬜ 未分析 | **编译器初始化 Phase 2** |
| 7.6 | `initialize_jsr292_core_classes()` | ⭐⭐⭐ | ⬜ 未分析 | **JSR 292 核心类初始化 (MethodHandle)** |
| 7.7 | `call_initPhase2()` | ⭐⭐⭐⭐ | ✅ 已完成 | **模块系统初始化 (System.initPhase2)** |
| 7.8 | `call_initPhase3()` | ⭐⭐⭐ | ✅ 已完成 | **安全管理器与类加载器初始化 (System.initPhase3)** |
| 7.9 | `SystemDictionary::compute_java_loaders()` | ⭐⭐⭐ | ⬜ 未分析 | **缓存系统/平台类加载器** |

**`initialize_jsr292_core_classes()` 详细展开**:

```
initialize_jsr292_core_classes(CHECK)
├── initialize_class(java_lang_invoke_MethodHandle)
├── initialize_class(java_lang_invoke_ResolvedMethodName)
├── initialize_class(java_lang_invoke_MemberName)
└── initialize_class(java_lang_invoke_MethodHandleNatives)
```

**核心点**:
- `call_initPhase2()` 初始化 Java 9 模块系统
- `call_initPhase3()` 设置安全管理器和系统类加载器

---

### Phase 8: 后续服务线程与收尾工作 ⭐⭐

| 序号 | 函数调用 | 重要程度 | 分析状态 | 说明 |
|-----|---------|---------|---------|------|
| 8.1 | `JvmtiExport::enter_live_phase()` | ⭐ | ⬜ 跳过 | JVMTI 进入运行阶段 |
| 8.2 | `JvmtiExport::post_vm_initialized()` | ⭐ | ⬜ 跳过 | JVMTI 通知 VM 初始化完成 |
| 8.3 | `Management::initialize()` | ⭐⭐ | ⬜ 可选 | JMX 管理初始化 |
| 8.4 | `MemProfiler::engage()` | ⭐ | ⬜ 跳过 | 内存分析器 |
| 8.5 | `StatSampler::engage()` | ⭐ | ⬜ 跳过 | 统计采样器 |
| 8.6 | `BiasedLocking::init()` | ⭐⭐⭐ | ⬜ 未分析 | **偏向锁初始化** |
| 8.7 | `call_postVMInitHook()` | ⭐ | ⬜ 跳过 | VM 初始化后钩子 |
| 8.8 | `WatcherThread::start()` | ⭐⭐ | ⬜ 可选 | 看门狗线程启动 |

**核心点**:
- `BiasedLocking::init()` 偏向锁是 Java 同步优化的重要机制

---

## 🎯 重点攻破建议

### 第一梯队 (必须掌握) ⭐⭐⭐⭐⭐

| 模块 | 说明 | 面试高频 |
|-----|------|---------|
| `initialize_java_lang_classes()` | Java 核心类初始化 | ✅ |
| `VMThread 创建流程` | VM 核心后台线程 | ✅ |
| `call_initPhase1/2/3()` | Java 系统初始化三阶段 | ✅ |
| `SafepointMechanism::initialize()` | 安全点机制 | ✅ |

### 第二梯队 (重要) ⭐⭐⭐⭐

| 模块 | 说明 | 面试高频 |
|-----|------|---------|
| `JavaThread 创建流程` | 线程内部结构 | ✅ |
| `ThreadLocalStorage::init()` | TLS 机制 | ⬜ |
| `Arguments::parse()` | 参数解析 | ⬜ |
| `Arguments::apply_ergo()` | 自动调优 | ✅ |
| `os::init()` / `os::init_2()` | OS 模块 | ⬜ |

### 第三梯队 (了解) ⭐⭐⭐

| 模块 | 说明 | 面试高频 |
|-----|------|---------|
| `BiasedLocking::init()` | 偏向锁 | ✅ |
| `ObjectMonitor::Initialize()` | 同步机制 | ✅ |
| `ServiceThread` | 服务线程 | ⬜ |
| `AttachListener` | Attach 机制 | ⬜ |

---

## 📈 完成度追踪

```
Phase 0: ████░░░░░░ 40%  (2/5 可选分析)
Phase 1: ██░░░░░░░░ 20%  (3/10 待分析)
Phase 2: ████████░░ 80%  (3/7 已完成) ← os::init_2 ✅ vm_init_globals ✅ SafepointMechanism ✅
Phase 3: ██████████ 100% ✅ 已完成 (JavaThread/OSThread)
Phase 4: ██████████ 100% ✅ 已完成 (init_globals)
Phase 5: ██████████ 100% ✅ 已完成 (VMThread)
Phase 6: ████████░░ 80%  ✅ 核心已完成 (initialize_java_lang_classes)
Phase 7: ████░░░░░░ 40%  ✅ initPhase1/2/3 已完成
Phase 8: █░░░░░░░░░ 10%  (1/8 待分析)
```

---

## 🚀 推荐学习路线

```
推荐顺序：
┌─────────────────────────────────────────────────────────────────────┐
│ 1. Phase 6: initialize_java_lang_classes() ★★★★★ ✅ 已完成          │
│    - 了解 Java 核心类如何初始化                                       │
│    - 理解 main 线程的创建过程                                         │
│    - call_initPhase1/2/3 三阶段 ✅ 已完成                            │
├─────────────────────────────────────────────────────────────────────┤
│ 2. Phase 5: VMThread 创建与启动 ★★★★ ✅ 已完成                       │
│    - VMThread 的作用 ✅                                              │
│    - 如何执行 VM 操作 ✅                                              │
│    - VMOperationQueue 队列机制 ✅                                    │
├─────────────────────────────────────────────────────────────────────┤
│ 3. Phase 3: JavaThread 创建流程 ★★★★ ✅ 已完成                       │
│    - 线程状态机 ✅                                                    │
│    - JavaThread 与 OSThread 的关系 ✅                                │
│    - 栈保护页与 ObjectMonitor ✅                                      │
├─────────────────────────────────────────────────────────────────────┤
│ 4. Phase 2: 安全点机制 ★★★ ← 建议下一步                              │
│    - SafepointMechanism::initialize()                                │
│    - Polling Page 原理                                               │
├─────────────────────────────────────────────────────────────────────┤
│ 5. Phase 1: 参数解析与自动调优 ★★★                                    │
│    - Arguments::parse()                                              │
│    - Arguments::apply_ergo()                                         │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 📚 相关文档

- [init_globals 大纲](./init_globals_outline.md) ✅ 已完成
- [Universe 初始化](./Universe/universe_init.md) ✅ 已完成
- [解释器初始化](./Interpreter/interpreter_init.md) ✅ 已完成
- [编译器初始化](./Compiler/compileBroker_init.md) ✅ 已完成
- [System 三阶段初始化](./SystemInit/System_initPhases.md) ✅ 已完成
- [VMThread 创建与运行](./VMThread/VMThread.md) ✅ 已完成

---

**请告诉我你想先攻破哪个阶段？** 🎯
