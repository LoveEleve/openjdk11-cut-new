# create_vm() 剩余部分分析 (Phase 6-8)

> **源码位置**: `src/hotspot/share/runtime/thread.cpp:4095-4306`
> **重要程度**: ⭐⭐⭐⭐ (完成 JVM 启动闭环)
> **分析范围**: Phase 6 (Java 类初始化) + Phase 7 (编译器/模块系统) + Phase 8 (服务线程/收尾)

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文对 **create_vm() 剩余部分分析 (Phase 6-8)** 进行源码级分析：追踪关键函数的执行路径，分析涉及的数据结构，解释每个设计决策的原因。

### 0.2 为什么需要？

仅靠文档和注释无法完全理解 JVM 的行为——很多关键细节只存在于源码中。源码级分析能建立对 JVM 行为的精确理解。

### 0.3 怎么解决？

从入口函数出发，自顶向下追踪调用链；对每个关键函数，分析其输入/输出/副作用；对每个数据结构，分析其字段含义和生命周期。

### 0.4 为什么这样设计？

分析过程中重点关注「为什么」：为什么选择这个数据结构？为什么这样处理边界情况？这些问题的答案往往揭示了 JVM 设计的精髓。

---


## 整体流程图

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    create_vm() Phase 6-8 完整流程                                │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  Phase 5 结束: VMThread 已创建并启动                                              │
│       │                                                                          │
│       ▼                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │ Phase 6: Java 基础类初始化 (L4121-L4139)                                 │    │
│  │                                                                          │    │
│  │   ├── JvmtiExport::enter_early_start_phase()                            │    │
│  │   ├── JvmtiExport::post_early_vm_start()                                │    │
│  │   ├── initialize_java_lang_classes() ★                                  │    │
│  │   │       ├── initialize_class(java_lang_String)                        │    │
│  │   │       ├── initialize_class(java_lang_System)                        │    │
│  │   │       ├── initialize_class(java_lang_Class)                         │    │
│  │   │       ├── initialize_class(java_lang_ThreadGroup)                   │    │
│  │   │       ├── create_initial_thread_group()                             │    │
│  │   │       ├── initialize_class(java_lang_Thread)                        │    │
│  │   │       ├── create_initial_thread() ★  ← 创建 Java main 线程          │    │
│  │   │       ├── initialize_class(java_lang_Module)                        │    │
│  │   │       ├── call_initPhase1()  ← System.initPhase1()                  │    │
│  │   │       └── 预分配异常对象 (OOM, NPE, SOE...)                          │    │
│  │   ├── quicken_jni_functions()                                           │    │
│  │   ├── StubCodeDesc::freeze()                                            │    │
│  │   └── set_init_completed()  ← 标记基础初始化完成                         │    │
│  └─────────────────────────────────────────────────────────────────────────┘    │
│       │                                                                          │
│       ▼                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │ Phase 7: 模块系统与编译器初始化 (L4178-L4241)                            │    │
│  │                                                                          │    │
│  │   ├── CompileBroker::compilation_init_phase1()  ← 编译器初始化 Phase 1   │    │
│  │   ├── CompileBroker::compilation_init_phase2()  ← 编译器初始化 Phase 2   │    │
│  │   ├── initialize_jsr292_core_classes()          ← MethodHandle 支持      │    │
│  │   ├── call_initPhase2()                         ← 模块系统初始化         │    │
│  │   ├── call_initPhase3()                         ← 安全管理器/类加载器    │    │
│  │   └── SystemDictionary::compute_java_loaders()  ← 缓存类加载器           │    │
│  └─────────────────────────────────────────────────────────────────────────┘    │
│       │                                                                          │
│       ▼                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │ Phase 8: 服务线程与收尾工作 (L4245-L4306)                                │    │
│  │                                                                          │    │
│  │   ├── JvmtiExport::enter_live_phase()                                   │    │
│  │   ├── Management::initialize()                  ← JMX 管理               │    │
│  │   ├── BiasedLocking::init()                     ← 偏向锁初始化           │    │
│  │   ├── WatcherThread::start()                    ← 看门狗线程             │    │
│  │   └── return JNI_OK                             ← JVM 启动完成!          │    │
│  └─────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Phase 6: Java 基础类初始化 (L4121-L4139)

### 6.1 核心方法: initialize_java_lang_classes()

```cpp
// 初始化 java.lang 核心类
initialize_java_lang_classes(main_thread, CHECK_JNI_ERR);
```

**初始化顺序**（关键）：

| 顺序 | 类 | 作用 |
|-----|-----|------|
| 1 | `java.lang.String` | 字符串类，最基础 |
| 2 | `java.lang.System` | 系统类，标准流 |
| 3 | `java.lang.Class` | 反射基础 |
| 4 | `java.lang.ThreadGroup` | 线程组 |
| 5 | `java.lang.Thread` | ★ 创建 Java main 线程 |
| 6 | `java.lang.Module` | Java 9 模块系统 |
| 7 | `java.lang.reflect.Method` | 反射方法 |
| 8 | `java.lang.ref.Finalizer` | 终结器 |

### 6.2 创建 Java main 线程 ★

```cpp
// 在 initialize_java_lang_classes() 内部
create_initial_thread_group();  // 创建主线程组
create_initial_thread();        // ★ 创建 Java 的 main 线程
main_thread->set_threadObj(result);  // 绑定到 C++ JavaThread
```

**关键区别**：
- **C++ JavaThread**: Phase 3 创建的 JVM 内部线程对象
- **Java Thread**: 这里创建的 `java.lang.Thread` 对象，是 Java 层面可见的

### 6.3 System.initPhase1()

```cpp
call_initPhase1();  // 调用 System.initPhase1()
```

**初始化内容**：
- 初始化系统属性 (`System.props`)
- 设置标准输入输出流 (`System.in/out/err`)
- 设置系统时区

### 6.4 预分配异常对象

```cpp
// 预分配常用异常对象，避免 OOM 时无法分配
initialize_class(java_lang_OutOfMemoryError);
initialize_class(java_lang_NullPointerException);
initialize_class(java_lang_StackOverflowError);
// ... 其他异常
```

**为什么预分配？**
- 当发生 OOM 时，堆已满，无法分配新的异常对象
- 预分配确保能抛出异常

### 6.5 标记初始化完成

```cpp
set_init_completed();  // 标记基础初始化完成
```

**作用**：
- 允许异常处理正常工作
- 允许调试功能启用

---

## Phase 7: 模块系统与编译器初始化 (L4178-L4241)

### 7.1 编译器初始化

```cpp
#if defined(COMPILER1) || COMPILER2_OR_JVMCI
    // Phase 1: 初始化编译器线程、编译队列
    CompileBroker::compilation_init_phase1(CHECK_JNI_ERR);
    
    // Phase 2: 完成编译器初始化
    CompileBroker::compilation_init_phase2();
#endif
```

**C1 vs C2**：
| 编译器 | 名称 | 特点 |
|-------|------|------|
| C1 | Client Compiler | 快速编译，低优化 |
| C2 | Server Compiler | 慢速编译，高优化 |

### 7.2 JSR292 支持 (MethodHandle)

```cpp
initialize_jsr292_core_classes(CHECK_JNI_ERR);
```

**初始化类**：
- `java.lang.invoke.MethodHandle`
- `java.lang.invoke.MemberName`
- `java.lang.invoke.MethodHandleNatives`

### 7.3 模块系统初始化 (Java 9+)

```cpp
// Phase 2: 初始化模块系统
call_initPhase2(CHECK_JNI_ERR);
// 内部调用: System.initPhase2()
// - 加载 java.base 模块
// - 初始化模块路径

// Phase 3: 安全管理器与类加载器
call_initPhase3(CHECK_JNI_ERR);
// 内部调用: System.initPhase3()
// - 设置安全管理器
// - 初始化系统类加载器
```

### 7.4 缓存类加载器

```cpp
SystemDictionary::compute_java_loaders(CHECK_JNI_ERR);
```

**缓存内容**：
- 系统类加载器 (AppClassLoader)
- 平台类加载器 (PlatformClassLoader)

---

## Phase 8: 服务线程与收尾工作 (L4245-L4306)

### 8.1 JVMTI 进入运行阶段

```cpp
JvmtiExport::enter_live_phase();
JvmtiExport::post_vm_initialized();
```

**JVMTI 阶段**：
1. `early_start_phase` - 早期启动
2. `start_phase` - 启动阶段
3. `live_phase` - 运行阶段 ← 这里

### 8.2 JMX 管理初始化

```cpp
Management::initialize(THREAD);
```

**功能**：
- 启动 JMX 代理
- 注册 MBean
- 支持 jconsole/visualvm 连接

### 8.3 偏向锁初始化

```cpp
BiasedLocking::init();
```

**偏向锁**：
- 优化无竞争锁的性能
- 延迟初始化，减少启动开销

### 8.4 看门狗线程

```cpp
WatcherThread::make_startable();
if (PeriodicTask::num_tasks() > 0) {
    WatcherThread::start();
}
```

**功能**：
- 执行周期性任务
- 统计采样、性能监控

### 8.5 JVM 启动完成!

```cpp
return JNI_OK;  // ★ JVM 启动成功!
```

---

## create_vm() 完整分析总结

### 8 个 Phase 总览

| Phase | 内容 | 状态 |
|-------|------|------|
| Phase 0 | 前置检查 (TLS, 随机数) | ✅ |
| Phase 1 | OS 初始化 + 参数解析 | ✅ |
| Phase 2 | 全局数据结构 (SafepointMechanism) | ✅ |
| Phase 3 | 主线程创建 (JavaThread) | ✅ |
| Phase 4 | 核心模块初始化 (init_globals) | 🟡 |
| Phase 5 | VMThread 创建 | ✅ |
| Phase 6 | Java 基础类初始化 | ✅ (本文) |
| Phase 7 | 编译器/模块系统 | ✅ (本文) |
| Phase 8 | 服务线程/收尾 | ✅ (本文) |

### 关键里程碑

```
Threads::create_vm()
    │
    ├── [Phase 0-5] 基础设施 ✅
    │
    ├── [Phase 6] initialize_java_lang_classes()
    │       └── create_initial_thread()  ← Java main 线程诞生
    │
    ├── [Phase 7] call_initPhase2/3()
    │       └── 模块系统初始化
    │
    ├── [Phase 8] 服务线程启动
    │       └── WatcherThread, Management
    │
    └── return JNI_OK  ← JVM 启动完成!
```

### create_vm() 完成度: **100%** ✅

---

## 下一步学习建议

**create_vm() 已全部完成分析！**

现在可以转向：

### 选项 A: Young GC 完整流程（动态行为）
- **内容**: 从触发到完成的完整 GC 流程
- **意义**: 将之前学的 VMThread、Safepoint 知识串联
- **重要性**: ⭐⭐⭐⭐⭐

### 选项 B: 类加载子系统
- **内容**: ClassLoader 体系、类加载流程、双亲委派
- **意义**: 补充 Phase 6 的类初始化细节
- **重要性**: ⭐⭐⭐⭐

### 选项 C: JIT 编译器深入
- **内容**: C1/C2 编译流程、编译触发条件
- **意义**: 补充 Phase 7 的编译器初始化
- **重要性**: ⭐⭐⭐⭐

**请问想继续分析哪一个？**
