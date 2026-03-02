# Ch15: Java Agent 机制 — 从 -javaagent 到 premain()

> 基于 OpenJDK 11 源码 | libinstrument.so 深度分析
> 模块 A（第 1 篇 / 共 4 篇）| PerfMa 面试价值：⭐⭐⭐⭐⭐

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **Ch15: Java Agent 机制 — 从 -javaagent 到 premain()**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 15.1 总览：Java Agent 解决什么问题？

### 核心问题

**如何在不修改应用代码的情况下，对 Java 类进行运行时增强（字节码修改）？**

典型场景：
- **APM 监控**：自动给方法加耗时统计（SkyWalking/PinPoint）
- **线上诊断**：运行时修改类行为（Arthas trace/watch）
- **安全检测**：在关键 API 前插入安全检查（RASP）
- **热修复**：运行时替换有 bug 的方法实现

### 四种 Agent 类型对比

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       Java Agent 四种加载方式                            │
├──────────────┬────────────────┬────────────────┬────────────────────────┤
│   类型        │  触发方式       │  入口函数       │  典型使用者             │
├──────────────┼────────────────┼────────────────┼────────────────────────┤
│ premain      │ -javaagent:    │ premain()      │ SkyWalking/PinPoint    │
│ Agent        │ 命令行参数      │                │ 启动时注入              │
├──────────────┼────────────────┼────────────────┼────────────────────────┤
│ agentmain    │ Attach API     │ agentmain()    │ Arthas/VisualVM        │
│ Agent        │ 运行时连接      │                │ 运行时注入              │
├──────────────┼────────────────┼────────────────┼────────────────────────┤
│ JVMTI Native │ -agentlib:     │ Agent_OnLoad() │ async-profiler         │
│ Agent        │ -agentpath:    │                │ 直接用 C/C++ 写        │
├──────────────┼────────────────┼────────────────┼────────────────────────┤
│ Launcher     │ MANIFEST 中    │ agentmain()    │ 可执行 JAR 自带        │
│ Agent        │ Launcher-Agent │                │ Agent（JDK 9+）        │
└──────────────┴────────────────┴────────────────┴────────────────────────┘
```

**本章聚焦**：premain Agent 的完整加载链路（最常用、面试最常考）。

### 整体架构与组件关系

```
  用户代码                    libinstrument.so              HotSpot JVM
┌───────────┐          ┌──────────────────────┐      ┌─────────────────────┐
│           │          │  InvocationAdapter.c  │      │  runtime/thread.cpp │
│ MANIFEST: │  ─────►  │  Agent_OnLoad()       │◄──── │  create_vm_init_    │
│ Premain-  │  解析     │  Agent_OnAttach()     │ 调用  │  agents()           │
│ Class     │          │                      │      │                     │
│           │          │  JPLISAgent.c         │      │  prims/             │
│ premain() │  ◄─────  │  processJavaStart()   │─────►│  jvmtiExport.cpp    │
│ 方法      │  反射调用  │  createInstrumentation│ JVMTI│  JVMTI 事件体系      │
│           │          │  transformClassFile() │◄─────│  ClassFileLoadHook  │
│           │          │                      │ 回调   │                     │
│ ClassFile │          │  InstrumentationImpl  │      │  classfile/         │
│ Transformer│ ◄─────  │  NativeMethods.c      │      │  klassFactory.cpp   │
│ .transform│  Java调用 │  retransformClasses() │─────►│  post_class_file_   │
│           │          │  redefineClasses()    │ JVMTI│  load_hook()        │
└───────────┘          └──────────────────────┘      └─────────────────────┘

Java 层:
┌──────────────────────────────────────────────────────────┐
│  sun.instrument.InstrumentationImpl                       │
│  ├── mTransformerManager (普通 Transformer)               │
│  ├── mRetransfomableTransformerManager (可 retransform)   │
│  ├── loadClassAndCallPremain() → 反射调用 premain()        │
│  └── transform() → 遍历 TransformerManager 链式调用        │
│                                                           │
│  sun.instrument.TransformerManager                        │
│  └── mTransformerList[] → 有序数组，添加顺序执行            │
└──────────────────────────────────────────────────────────┘
```

### 完整时间线

```
┌──────────────────────────────────────────────────────────────────────────┐
│ 时间线：java -javaagent:myagent.jar=opts -jar app.jar                    │
├─────────┬────────────────────────────────────────────────────────────────┤
│ Phase 1 │ 参数解析（Arguments::parse）                                   │
│ T0      │ 匹配 "-javaagent:" → add_instrument_agent("instrument", ...)  │
│         │ 向 _agentList 添加 AgentLibrary{name="instrument",             │
│         │   options="myagent.jar=opts", is_instrument_lib=true}          │
├─────────┼────────────────────────────────────────────────────────────────┤
│ Phase 2 │ Agent 加载（Threads::create_vm_init_agents）                   │
│ T1      │ 遍历 _agentList → dlopen("libinstrument.so")                  │
│ T2      │ dlsym("Agent_OnLoad") → DEF_Agent_OnLoad()                    │
│ T3      │   createNewJPLISAgent() → 获取 jvmtiEnv                       │
│ T4      │   readAttributes(jarfile) → 读 MANIFEST.MF                    │
│ T5      │   getAttribute("Premain-Class") → 得到 Agent 类名              │
│ T6      │   convertCapabilityAttributes() → 设置 JVMTI 能力              │
│ T7      │   recordCommandLineData() → 保存类名和选项                     │
│ T8      │   initializeJPLISAgent() → 注册 VMInit 回调                    │
├─────────┼────────────────────────────────────────────────────────────────┤
│ Phase 3 │ VMInit 回调（eventHandlerVMInit）                              │
│ T9      │ JVM 初始化完成 → 触发 VMInit 事件                              │
│ T10     │   appendClassPath(agent->mJarfile) → jar 加入系统类路径         │
│ T11     │   processJavaStart() → 开始 Java 层初始化                      │
│ T12     │     createInstrumentationImpl() → new InstrumentationImpl()    │
│ T13     │     setLivePhaseEventHandlers() → 注册 ClassFileLoadHook       │
│ T14     │     startJavaAgent() → 反射调用 premain(String,Instrumentation)│
├─────────┼────────────────────────────────────────────────────────────────┤
│ Phase 4 │ 运行时类加载拦截（持续生效）                                    │
│ T15+    │ 每次类加载 → KlassFactory → post_class_file_load_hook()        │
│         │ → eventHandlerClassFileLoadHook → transformClassFile()          │
│         │ → InstrumentationImpl.transform() → 遍历 Transformer 链        │
│         │ → 返回修改后的字节码 → ClassFileParser 解析新字节码              │
└─────────┴────────────────────────────────────────────────────────────────┘
```

---

## 15.2 Phase 1: -javaagent 参数解析

### 问题：JVM 如何认识 `-javaagent:myagent.jar=opts`？

**答案**：HotSpot 在 `Arguments::parse()` 中把 `-javaagent:` 转换为内部的 Agent 库加载请求。

### 关键代码

**文件**：`src/hotspot/share/runtime/arguments.cpp` (line 2601)

```cpp
// -javaagent
} else if (match_option(option, "-javaagent:", &tail)) {
    if (tail != NULL) {
        size_t length = strlen(tail) + 1;
        char *options = NEW_C_HEAP_ARRAY(char, length, mtArguments);
        jio_snprintf(options, length, "%s", tail);
        // 关键！把 -javaagent 转换为一个名为 "instrument" 的 agent 库加载请求
        add_instrument_agent("instrument", options, false);
        // 同时确保 java.instrument 模块被加载
        create_numbered_property("jdk.module.addmods", "java.instrument", addmods_count++);
    }
}
```

**`add_instrument_agent` 做了什么？**

```cpp
// arguments.cpp line 316
void Arguments::add_instrument_agent(const char* name, char* options, bool absolute_path) {
    // 注意最后一个参数 true → is_instrument_lib 标记
    _agentList.add(new AgentLibrary(name, options, absolute_path, NULL, true));
}
```

### 转换关系

```
用户输入:   java -javaagent:myagent.jar=opts -jar app.jar
                     ↓
参数解析:   tail = "myagent.jar=opts"
                     ↓
内部表示:   AgentLibrary {
                name           = "instrument"       ← 固定值！
                options        = "myagent.jar=opts"  ← 原始 tail
                absolute_path  = false
                is_instrument_lib = true              ← 标记为 instrument 库
            }
                     ↓
实际效果:   等价于 -agentlib:instrument=myagent.jar=opts
                     ↓
加载动作:   dlopen("libinstrument.so") → Agent_OnLoad(vm, "myagent.jar=opts", NULL)
```

**面试要点**：`-javaagent` 在 JVM 内部被转换为 `-agentlib:instrument=<tail>`。名为 `"instrument"` 是硬编码的，对应的 `.so` 文件是 `libinstrument.so`。

---

## 15.3 Phase 2: Agent_OnLoad — libinstrument.so 的入口

### 问题：JVM 启动时如何调用到 libinstrument.so 的 Agent_OnLoad？

**触发时机**：在 `Threads::create_vm()` 中，`vm_init_globals()` 之前。

```
create_vm() 调用链:
  ...
  ostream_init_log()
  convert_vm_init_libraries_to_agents()   // 兼容 -Xrun
  create_vm_init_agents()                 // ← 这里加载 agent
  vm_init_globals()                       // 之后才初始化 VM 全局数据
  ...
```

### create_vm_init_agents() 完整分析

**文件**：`src/hotspot/share/runtime/thread.cpp` (line 4427)

```cpp
void Threads::create_vm_init_agents() {
    extern struct JavaVM_ main_vm;

    JvmtiExport::enter_onload_phase();  // 进入 JVMTI OnLoad 阶段

    for (AgentLibrary* agent = Arguments::agents();
         agent != NULL;
         agent = agent->next()) {
        // 1. 查找 Agent_OnLoad 函数
        OnLoadEntry_t on_load_entry = lookup_agent_on_load(agent);

        if (on_load_entry != NULL) {
            // 2. 调用 Agent_OnLoad(vm, options, NULL)
            jint err = (*on_load_entry)(&main_vm, agent->options(), NULL);
            if (err != JNI_OK) {
                vm_exit_during_initialization("agent library failed to init",
                                              agent->name());
            }
        }
    }

    JvmtiExport::enter_primordial_phase();  // 进入 JVMTI Primordial 阶段
}
```

### lookup_agent_on_load 查找过程

```
lookup_agent_on_load(agent)
  └── lookup_on_load(agent, {"Agent_OnLoad"}, 1)
        ├── agent 尚未加载？ → dlopen("libinstrument.so")
        │   ├── 先在 JVM 的 dll_dir 找：{jre}/lib/libinstrument.so
        │   └── 找不到则在系统 library path 找
        └── dlsym(library, "Agent_OnLoad") → 返回函数指针
```

对于 `-javaagent`，agent->name() 是 `"instrument"`，所以 JVM 会：
1. `dlopen("libinstrument.so")` — 加载 libinstrument 共享库
2. `dlsym("Agent_OnLoad")` — 找到入口函数
3. 调用 `Agent_OnLoad(&main_vm, "myagent.jar=opts", NULL)`

### DEF_Agent_OnLoad 详细分析

**文件**：`src/java.instrument/share/native/libinstrument/InvocationAdapter.c` (line 142)

这是 `Agent_OnLoad` 的真正实现。下面按步骤拆解：

```
DEF_Agent_OnLoad(JavaVM *vm, char *tail, void *reserved)
│
├── 步骤 1: createNewJPLISAgent(vm, &agent)
│   ├── GetEnv(vm, &jvmtienv, JVMTI_VERSION_1_1)  ← 获取 JVMTI 环境
│   ├── allocateJPLISAgent(jvmtienv)                ← 分配 JPLISAgent 结构体
│   └── initializeJPLISAgent(agent, vm, jvmtienv)   ← 初始化 + 注册 VMInit 回调
│
├── 步骤 2: parseArgumentTail(tail, &jarfile, &options)
│   └── "myagent.jar=opts" → jarfile="myagent.jar", options="opts"
│
├── 步骤 3: readAttributes(jarfile)
│   └── 打开 JAR 文件 → 读取 META-INF/MANIFEST.MF → 解析属性
│
├── 步骤 4: getAttribute(attributes, "Premain-Class")
│   └── 从 MANIFEST 中取出 Premain-Class 的值 → Agent 类名
│
├── 步骤 5: convertCapabilityAttributes(attributes, agent)
│   ├── "Can-Redefine-Classes: true"   → addRedefineClassesCapability()
│   ├── "Can-Retransform-Classes: true" → retransformableEnvironment()
│   └── "Can-Set-Native-Method-Prefix: true" → addNativeMethodPrefixCapability()
│
├── 步骤 6: recordCommandLineData(agent, premainClass, options)
│   ├── agent->mAgentClassName = strdup(premainClass)
│   └── agent->mOptionsString = strdup(options)
│
└── 返回 JNI_OK
```

### JPLISAgent 数据结构

**文件**：`src/java.instrument/share/native/libinstrument/JPLISAgent.h` (line 92)

```
struct _JPLISAgent（Agent_OnLoad 创建后的初始状态）
偏移       字段名                         初始值          说明
───────────────────────────────────────────────────────────────────
0x000     mJVM                          vm 指针         JavaVM 句柄
0x008     mNormalEnvironment             {jvmtienv,...}  普通 JVMTI 环境
          ├── mJVMTIEnv                 jvmtienv        JVMTI 环境指针
          ├── mAgent                    agent           回指 Agent
          └── mIsRetransformer          JNI_FALSE       非 retransformer
0x020     mRetransformEnvironment        {NULL,...}      Retransform 专用环境
          ├── mJVMTIEnv                 NULL             尚未创建
          ├── mAgent                    agent           回指 Agent
          └── mIsRetransformer          JNI_FALSE       尚未激活
0x038     mInstrumentationImpl          NULL             Java Instrumentation 对象
0x040     mPremainCaller                NULL             premain 调用方法 ID
0x048     mAgentmainCaller              NULL             agentmain 调用方法 ID
0x050     mTransform                    NULL             transform 方法 ID
0x058     mRedefineAvailable            JNI_TRUE/FALSE   是否支持 redefine
0x05C     mRedefineAdded                JNI_FALSE       redefine 能力已添加？
0x060     mNativeMethodPrefixAvailable  JNI_TRUE/FALSE   是否支持 prefix
0x064     mNativeMethodPrefixAdded      JNI_FALSE       prefix 能力已添加？
0x068     mAgentClassName               "com/xxx/Agent"  Agent 类名
0x070     mOptionsString                "opts" 或 NULL   选项字符串
0x078     mJarfile                      "myagent.jar"    JAR 文件名
───────────────────────────────────────────────────────────────────
```

### 双 JVMTI 环境设计

**为什么需要两个 JVMTI 环境？**

这是理解 `retransform` 的关键设计：

```
┌─────────────────────────────────────────────────────────────────┐
│                    JPLISAgent                                    │
│                                                                 │
│  mNormalEnvironment (普通环境)                                    │
│  ├── 用于：addTransformer(transformer, false)                    │
│  ├── 能力：can_redefine_classes                                  │
│  └── 事件：ClassFileLoadHook（类加载时触发）                       │
│                                                                 │
│  mRetransformEnvironment (Retransform 环境)                      │
│  ├── 用于：addTransformer(transformer, true)                     │
│  ├── 能力：can_retransform_classes（额外能力）                    │
│  └── 事件：ClassFileLoadHook（retransform 触发时也参与）           │
│                                                                 │
│  为什么分开？                                                     │
│  ───────────                                                     │
│  JVMTI 规范要求：                                                 │
│  - retransform 时，只有 retransformable 的 transformer 参与       │
│  - 普通 load 时，两种 transformer 都参与                          │
│  - 用两个独立的 JVMTI env，JVM 可以精确控制哪些回调被触发          │
└─────────────────────────────────────────────────────────────────┘
```

### initializeJPLISAgent — 注册 VMInit 回调

```cpp
JPLISInitializationError
initializeJPLISAgent(JPLISAgent* agent, JavaVM* vm, jvmtiEnv* jvmtienv) {
    // ... 字段初始化 ...

    // 把 agent 环境信息存入 JVMTI TLS（以便回调时能找回 agent）
    (*jvmtienv)->SetEnvironmentLocalStorage(jvmtienv,
                                            &(agent->mNormalEnvironment));
    // 检查能力
    checkCapabilities(agent);

    // 检查当前阶段
    jvmtiPhase phase;
    (*jvmtienv)->GetPhase(jvmtienv, &phase);

    if (phase == JVMTI_PHASE_LIVE) {
        return JPLIS_INIT_ERROR_NONE;  // 运行时 attach 场景，跳过 VMInit
    }

    // OnLoad 阶段：注册 VMInit 事件回调
    jvmtiEventCallbacks callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.VMInit = &eventHandlerVMInit;    // ← 关键！注册 VMInit 处理器

    (*jvmtienv)->SetEventCallbacks(jvmtienv, &callbacks, sizeof(callbacks));
    (*jvmtienv)->SetEventNotificationMode(jvmtienv, JVMTI_ENABLE,
                                          JVMTI_EVENT_VM_INIT, NULL);
    return JPLIS_INIT_ERROR_NONE;
}
```

**关键点**：Agent_OnLoad 阶段 **不会调用 premain()**！它只是：
1. 创建 JPLISAgent 数据结构
2. 解析 MANIFEST.MF 中的配置
3. 记录 Agent 类名和选项
4. 注册 VMInit 回调

premain() 的调用发生在后面的 Phase 3（VMInit 回调）。

### MANIFEST.MF 能力映射

```
MANIFEST.MF 属性                     JVMTI 能力                      效果
─────────────────────────────────────────────────────────────────────────
Can-Redefine-Classes: true    →    can_redefine_classes           允许 redefineClasses()
Can-Retransform-Classes: true →    can_retransform_classes        允许 retransformClasses()
                                   (创建第二个 jvmtiEnv)           + 创建 Retransform 环境
Can-Set-Native-Method-Prefix →    can_set_native_method_prefix   允许设置 native 方法前缀
Boot-Class-Path: lib/ext.jar  →    AddToBootstrapClassLoaderSearch 添加到 BootClassPath
```

---

## 15.4 Phase 3: VMInit 回调 — 创建 Instrumentation 并调用 premain()

### 问题：premain() 是怎么被调用的？

**触发条件**：JVM 初始化完成（所有子系统 ready），触发 `JVMTI_EVENT_VM_INIT` 事件。

### eventHandlerVMInit 完整流程

**文件**：`InvocationAdapter.c` (line ~485)

```
eventHandlerVMInit(jvmtienv, jnienv, thread)
│
├── getJPLISEnvironment(jvmtienv) → 取回 JPLISAgent
│   └── GetEnvironmentLocalStorage(jvmtienv) → &agent->mNormalEnvironment
│       → environment->mAgent → agent
│
├── appendClassPath(agent, agent->mJarfile)
│   └── AddToSystemClassLoaderSearch(jvmtienv, "myagent.jar")
│       → 把 agent jar 加入系统类路径，这样才能 loadClass(Agent类名)
│
└── processJavaStart(agent, jnienv)  ← 进入核心流程
    │
    ├── 步骤 1: initializeFallbackError(jnienv)
    │   └── 创建备用的 InternalError（以防后续出错时能抛异常）
    │
    ├── 步骤 2: createInstrumentationImpl(jnienv, agent)  ← 创建 Java 层对象
    │   ├── FindClass("sun/instrument/InstrumentationImpl")
    │   ├── GetMethodID("<init>", "(JZZ)V")
    │   ├── NewObject(implClass, constructorID,
    │   │             (jlong)agent,          ← native 指针作为 long 传入
    │   │             agent->mRedefineAdded,
    │   │             agent->mNativeMethodPrefixAdded)
    │   ├── NewGlobalRef(localRef) → agent->mInstrumentationImpl
    │   ├── GetMethodID("loadClassAndCallPremain", ...) → agent->mPremainCaller
    │   ├── GetMethodID("loadClassAndCallAgentmain", ...) → agent->mAgentmainCaller
    │   └── GetMethodID("transform", ...) → agent->mTransform
    │
    ├── 步骤 3: setLivePhaseEventHandlers(agent)
    │   ├── 替换回调：VMInit → ClassFileLoadHook
    │   │   callbacks.ClassFileLoadHook = &eventHandlerClassFileLoadHook
    │   └── 关闭 VMInit 事件通知
    │
    ├── 步骤 4: startJavaAgent(agent, jnienv, className, options, premainCaller)
    │   ├── commandStringIntoJavaStrings() → 创建 Java String 参数
    │   └── invokeJavaAgentMainMethod() → CallVoidMethod(...)
    │       └── InstrumentationImpl.loadClassAndCallPremain(className, options)
    │           └── loadClassAndStartAgent(className, "premain", options)
    │               ├── ClassLoader.getSystemClassLoader().loadClass(className)
    │               ├── 查找 premain 方法（4 级优先级搜索）
    │               └── method.invoke(null, options, this)  ← 调用 premain()
    │
    └── 步骤 5: deallocateCommandLineData(agent) → 释放类名/选项的副本
```

### premain 方法查找优先级

**文件**：`InstrumentationImpl.java` (line ~430)

```
查找顺序（从高到低）：
┌──────────────────────────────────────────────────────────────┐
│ 1. 类中声明的 premain(String, Instrumentation)              │ ← 最高优先级
│ 2. 类中声明的 premain(String)                               │
│ 3. 继承的 premain(String, Instrumentation)                  │
│ 4. 继承的 premain(String)                                   │ ← 最低优先级
└──────────────────────────────────────────────────────────────┘

规则：
- declared（getDeclaredMethod）优先于 inherited（getMethod）
- 2 参数版本优先于 1 参数版本
- premain 方法不要求是 public（会 setAccessible(true)）
- 找不到任何 premain → 抛出 NoSuchMethodException → JVM 启动失败
```

### 从 native 到 Java 再到 native 的完整调用栈

```
[HotSpot C++] Threads::create_vm()
    → post VMInit event
        → [libinstrument C] eventHandlerVMInit()
            → processJavaStart()
                → createInstrumentationImpl()  ← JNI 创建 Java 对象
                → startJavaAgent()
                    → invokeJavaAgentMainMethod()
                        → [JNI] CallVoidMethod(instrumentationImpl,
                                               premainCallerMethodID,
                                               classNameString,
                                               optionsString)
                            → [Java] InstrumentationImpl.loadClassAndCallPremain()
                                → loadClassAndStartAgent()
                                    → ClassLoader.loadClass(agentClassName)
                                    → getDeclaredMethod("premain", ...)
                                    → method.setAccessible(true)
                                    → method.invoke(null, options, this)
                                        → [用户代码] MyAgent.premain(String, Instrumentation)
                                            → inst.addTransformer(myTransformer, true)
                                                → [Java] InstrumentationImpl.addTransformer()
                                                    → mRetransfomableTransformerManager.addTransformer()
                                                    → [JNI] setHasRetransformableTransformers(agent, true)
                                                        → [libinstrument C] setHasRetransformableTransformers()
                                                            → [JVMTI] SetEventNotificationMode(ENABLE,
                                                                       CLASS_FILE_LOAD_HOOK)
                                                                → [HotSpot] JvmtiEventController 激活事件
```

---

## 15.5 Phase 4: ClassFileLoadHook — 类加载时的字节码拦截

### 问题：Agent 注册的 Transformer 是怎么在每次类加载时被调用的？

### 触发点：KlassFactory::create_from_stream

**文件**：`src/hotspot/share/classfile/klassFactory.cpp` (line 178)

```cpp
InstanceKlass* KlassFactory::create_from_stream(...) {
    JvmtiCachedClassFileData* cached_class_file = NULL;
    ClassFileStream* old_stream = stream;

    // 非匿名类才走 JVMTI hook
    if (host_klass == NULL) {
        // ← 这里触发 ClassFileLoadHook
        stream = check_class_file_load_hook(stream, name, loader_data,
                                            protection_domain,
                                            &cached_class_file, CHECK_NULL);
    }

    // 之后用（可能被修改的）stream 解析类
    ClassFileParser parser(stream, name, loader_data, ...);
    InstanceKlass* result = parser.create_instance_klass(
                                old_stream != stream,  // changed_by_loadhook
                                CHECK_NULL);
    // ...
}
```

### check_class_file_load_hook → post_class_file_load_hook

```
check_class_file_load_hook()
│
├── JvmtiExport::should_post_class_file_load_hook()?
│   └── 检查全局标志位（任何 env 启用了 CLASS_FILE_LOAD_HOOK_BIT 就为 true）
│
├── 如果有 redefine/retransform 正在进行：
│   └── 从 JvmtiThreadState 获取 cached_class_file（原始字节码）
│
└── JvmtiExport::post_class_file_load_hook(name, loader, pd, &ptr, &end_ptr, &cache)
    └── JvmtiClassFileLoadHookPoster poster(...)
        └── poster.post()
            └── post_all_envs()
```

### JvmtiClassFileLoadHookPoster 分发逻辑

**文件**：`src/hotspot/share/prims/jvmtiExport.cpp` (line 834)

这是 HotSpot 内部将 ClassFileLoadHook 事件分发给所有注册的 JVMTI Agent 的核心逻辑：

```
post_all_envs():
│
├── 第一轮：遍历非 retransformable 的环境
│   for (env : all JVMTI environments) {
│       if (!env->is_retransformable() && env->is_enabled(CLASS_FILE_LOAD_HOOK)) {
│           post_to_env(env, false);  // false = 不缓存原始字节码
│       }
│   }
│   注意：retransform 操作触发时跳过这一轮！
│
└── 第二轮：遍历 retransformable 的环境
    for (env : all JVMTI environments) {
        if (env->is_retransformable() && env->is_enabled(CLASS_FILE_LOAD_HOOK)) {
            post_to_env(env, true);   // true = 缓存原始字节码
        }
    }
```

**post_to_env 的核心**：

```cpp
void post_to_env(JvmtiEnv* env, bool caching_needed) {
    unsigned char *new_data = NULL;
    jint new_len = 0;

    // 回调到 libinstrument.so 注册的 eventHandlerClassFileLoadHook
    jvmtiEventClassFileLoadHook callback = env->callbacks()->ClassFileLoadHook;
    (*callback)(env->jvmti_external(), jem.jni_env(),
                jem.class_being_redefined(), jem.jloader(),
                jem.class_name(), jem.protection_domain(),
                _curr_len, _curr_data,    // 当前字节码（可能被前一个 agent 修改过）
                &new_len, &new_data);      // agent 可以返回新字节码

    if (new_data != NULL) {
        _has_been_modified = true;
        // 缓存原始字节码（retransform 时需要用到）
        if (caching_needed && *_cached_class_file_ptr == NULL) {
            JvmtiCachedClassFileData *p = os::malloc(...);
            memcpy(p->data, _curr_data, _curr_len);
            *_cached_class_file_ptr = p;
        }
        _curr_data = new_data;  // 更新为 agent 返回的新字节码
        _curr_len = new_len;
        _curr_env = env;        // 记录当前 env（用于后续释放内存）
    }
}
```

### 从 HotSpot 回调到 libinstrument 再到 Java Transformer

```
[HotSpot] post_to_env → (*callback)(...)
    → [libinstrument] eventHandlerClassFileLoadHook()
        → getJPLISEnvironment(jvmtienv) → 取回 JPLISEnvironment
        → transformClassFile(agent, jnienv, loader, name, ...)
            │
            ├── tryToAcquireReentrancyToken()  ← 防止递归！
            │   └── GetThreadLocalStorage() → 检查当前线程是否已在 transform 中
            │   └── 如果已在 transform 中 → 直接返回（不调用 transformer）
            │
            ├── 参数编组（C → Java）
            │   ├── NewStringUTF(name) → classNameStringObject
            │   ├── NewByteArray(class_data_len) → classFileBufferObject
            │   └── SetByteArrayRegion(..., class_data, ...)
            │
            ├── CallObjectMethod(instrumentationImpl, transformMethodID,
            │                    module, loader, className,
            │                    classBeingRedefined, protectionDomain,
            │                    classFileBuffer, isRetransformer)
            │   → [Java] InstrumentationImpl.transform()
            │       → mgr = isRetransformer ? mRetransfomableTransformerManager
            │                               : mTransformerManager
            │       → mgr.transform(module, loader, classname, ...)
            │           → TransformerManager.transform()
            │               → 按顺序遍历 mTransformerList[]
            │               → 对每个 transformer 调用 transform()
            │               → 如果返回非 null，用新字节码作为下一个的输入
            │               → 最终返回最后的字节码（或 null 表示未修改）
            │
            ├── 结果解组（Java → C）
            │   ├── GetArrayLength(transformedBufferObject) → size
            │   ├── JVMTI Allocate(size, &resultBuffer)
            │   ├── GetByteArrayRegion(..., resultBuffer)
            │   └── *new_class_data = resultBuffer
            │
            └── releaseReentrancyToken()  ← 释放重入锁
```

### 重入保护机制

**文件**：`Reentrancy.c`

**问题**：为什么需要重入保护？

考虑这个场景：
1. 类加载 A → 触发 ClassFileLoadHook → 调用用户的 Transformer
2. 用户 Transformer 内部 `new SomeClass()` → 触发 SomeClass 的类加载
3. SomeClass 类加载 → 又触发 ClassFileLoadHook → 又调用 Transformer
4. 如果 Transformer 不是可重入的 → **无限递归！**

**解决方案**：用 JVMTI Thread Local Storage 存一个 token：

```
tryToAcquireReentrancyToken():
  GetThreadLocalStorage(thread) → storedValue
  if storedValue == JPLIS_CURRENTLY_INSIDE_TOKEN (0x7EFFC0BB):
      return false  → 已在 transform 中，跳过
  else:
      SetThreadLocalStorage(thread, JPLIS_CURRENTLY_INSIDE_TOKEN)
      return true   → 获取成功，可以调用 transformer

releaseReentrancyToken():
  SetThreadLocalStorage(thread, JPLIS_CURRENTLY_OUTSIDE_TOKEN (0x0))
```

**面试要点**：这意味着 **Transformer 执行过程中加载的新类不会被同一个 Transformer 再次拦截**。这是一个有意的设计决策，防止无限递归。

### Transformer 链式调用

**文件**：`TransformerManager.java` (line 168)

```java
public byte[] transform(Module module, ClassLoader loader,
                         String classname, ..., byte[] classfileBuffer) {
    boolean someoneTouchedTheBytecode = false;
    TransformerInfo[] transformerList = getSnapshotTransformerList(); // 快照，无锁读
    byte[] bufferToUse = classfileBuffer;

    // 按添加顺序依次调用每个 Transformer
    for (int x = 0; x < transformerList.length; x++) {
        ClassFileTransformer transformer = transformerList[x].transformer();
        byte[] transformedBytes = null;
        try {
            transformedBytes = transformer.transform(module, loader, classname,
                                                     classBeingRedefined,
                                                     protectionDomain,
                                                     bufferToUse);  // 前一个的输出是下一个的输入
        } catch (Throwable t) {
            // 吞掉异常！不让一个 transformer 影响其他的
        }
        if (transformedBytes != null) {
            someoneTouchedTheBytecode = true;
            bufferToUse = transformedBytes;  // 链式传递
        }
    }
    return someoneTouchedTheBytecode ? bufferToUse : null;
}
```

**设计要点**：
1. **快照读**：`mTransformerList` 是 copy-on-write 的，添加/删除时复制数组，读取时直接读引用（无锁）
2. **链式传递**：前一个 Transformer 的输出是下一个的输入
3. **异常隔离**：catch(Throwable) 吞掉异常，保证一个 Transformer 出错不影响其他
4. **顺序保证**：按 `addTransformer` 的调用顺序执行

---

## 15.6 能力协商与 MANIFEST.MF 属性

### 标准 MANIFEST.MF 示例

```
Manifest-Version: 1.0
Premain-Class: com.example.MyAgent
Agent-Class: com.example.MyAgent
Can-Redefine-Classes: true
Can-Retransform-Classes: true
Can-Set-Native-Method-Prefix: true
Boot-Class-Path: lib/helper.jar
```

### 能力转换过程

```
convertCapabilityAttributes(attributes, agent):
│
├── "Can-Redefine-Classes: true"
│   → addRedefineClassesCapability(agent)
│     → GetCapabilities() + 设置 can_redefine_classes=1
│     → AddCapabilities()
│     → agent->mRedefineAdded = JNI_TRUE
│
├── "Can-Retransform-Classes: true"
│   → retransformableEnvironment(agent)
│     → GetEnv(vm, &retransformerEnv, JVMTI_VERSION_1_1)  ← 创建第二个 JVMTI env！
│     → 设置 can_retransform_classes=1
│     → AddCapabilities()
│     → SetEventCallbacks(ClassFileLoadHook = &eventHandlerClassFileLoadHook)
│     → agent->mRetransformEnvironment.mJVMTIEnv = retransformerEnv
│     → agent->mRetransformEnvironment.mIsRetransformer = JNI_TRUE
│     → SetEnvironmentLocalStorage(retransformerEnv, &agent->mRetransformEnvironment)
│
└── "Can-Set-Native-Method-Prefix: true"
    → addNativeMethodPrefixCapability(agent)
      → 在两个环境上都设置 can_set_native_method_prefix=1
```

**关键设计**：`Can-Retransform-Classes: true` 会创建第二个 JVMTI 环境。这就是 JPLISAgent 有 `mNormalEnvironment` 和 `mRetransformEnvironment` 两个环境的原因。

---

## 15.7 面试专题

### Q1: -javaagent 底层是怎么实现的？

**完整回答**：
1. JVM 参数解析阶段，`-javaagent:xxx.jar=opts` 被转换为 `-agentlib:instrument=xxx.jar=opts`
2. `Threads::create_vm_init_agents()` 遍历 agent 列表，`dlopen("libinstrument.so")`，找到 `Agent_OnLoad` 入口
3. `Agent_OnLoad` 做 3 件事：创建 JPLISAgent + 解析 MANIFEST.MF + 注册 VMInit 回调
4. VMInit 时回调 `eventHandlerVMInit`：创建 `InstrumentationImpl` Java 对象 → 注册 `ClassFileLoadHook` → 反射调用 `premain()`
5. 之后每次类加载，`KlassFactory::create_from_stream` 中会触发 `ClassFileLoadHook` → 回调到 `transformClassFile` → 调用所有注册的 `ClassFileTransformer.transform()`

### Q2: premain() 和 agentmain() 有什么区别？

| 维度 | premain | agentmain |
|------|---------|-----------|
| 加载时机 | JVM 启动时（VMInit） | 运行时（Attach API） |
| 参数来源 | -javaagent 命令行 | VirtualMachine.loadAgent() |
| MANIFEST 属性 | Premain-Class | Agent-Class |
| JVMTI 阶段 | OnLoad → Primordial → Live | Live |
| JAR 加入类路径 | VMInit 回调中 appendClassPath | Agent_OnAttach 中 appendClassPath |
| 能力限制 | 完整 JVMTI 能力 | 部分能力可能不可用 |

### Q3: ClassFileTransformer 的执行顺序是什么？

按 `addTransformer()` 的调用顺序执行。多个 Agent 之间，先注册的先执行。前一个 Transformer 的输出是下一个的输入（链式调用）。Transformer 中的异常被 catch(Throwable) 吞掉，不影响其他 Transformer。

### Q4: 为什么 Transformer 中加载的新类不会被再次 transform？

因为重入保护机制。`transformClassFile` 使用 JVMTI Thread Local Storage 存储一个 token (0x7EFFC0BB)，标记当前线程正在 transform 中。如果同一线程在 transform 过程中触发了新的类加载（进而触发新的 ClassFileLoadHook），`tryToAcquireReentrancyToken()` 会检测到 token 已存在，直接跳过 transform。

### Q5: JPLISAgent 为什么有两个 JVMTI 环境？

为了区分 retransformable 和 non-retransformable 的 Transformer。JVMTI 规范要求：retransform 操作只会触发 retransformable 环境上的 ClassFileLoadHook；而普通类加载会触发两种环境上的 hook。两个独立的 JVMTI 环境让 JVM 能精确控制事件分发。

### Q6: Java Agent 启动失败会怎样？

如果 `Agent_OnLoad` 返回非 JNI_OK，JVM 会立即 `vm_exit_during_initialization` 退出。如果 `premain()` 抛出未捕获异常，`processJavaStart` 返回 false，`eventHandlerVMInit` 会调用 `abortJVM`，JVM 也会退出。

---

## GDB 验证计划

```bash
# 验证 Agent_OnLoad 被调用
gdb -batch -ex "b DEF_Agent_OnLoad" \
    -ex "run -javaagent:/tmp/test-agent.jar -Xms8g -Xmx8g -XX:+UseG1GC -version" \
    --args ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java

# 验证 eventHandlerVMInit 回调
gdb -batch -ex "b eventHandlerVMInit" \
    -ex "run -javaagent:/tmp/test-agent.jar -Xms8g -Xmx8g -XX:+UseG1GC -version" \
    --args ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java

# 验证 transformClassFile 被调用
gdb -batch -ex "b transformClassFile" \
    -ex "run -javaagent:/tmp/test-agent.jar -Xms8g -Xmx8g -XX:+UseG1GC -version" \
    --args ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java
```

---

## 下一步

**Ch16: Instrumentation API 实现 — retransformClasses 完整链路**
- retransformClasses() 从 Java → JNI → JVMTI → VM_RedefineClasses 的完整路径
- 方法替换、常量池合并、nmethod 失效等核心逻辑
- 与已有的 Rewriter/CPCache/Method::link_method 知识串联

---

*分析文件*：`src/java.instrument/share/native/libinstrument/` (全部)
*分析文件*：`src/java.instrument/share/classes/sun/instrument/` (全部)
*分析文件*：`src/hotspot/share/prims/jvmtiExport.cpp` (ClassFileLoadHookPoster)
*分析文件*：`src/hotspot/share/classfile/klassFactory.cpp` (触发点)
*分析文件*：`src/hotspot/share/runtime/thread.cpp` (create_vm_init_agents)
*分析文件*：`src/hotspot/share/runtime/arguments.cpp` (参数解析)
