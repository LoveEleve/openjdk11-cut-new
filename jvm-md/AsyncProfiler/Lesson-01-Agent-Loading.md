# AsyncProfiler 第一课：Agent 加载入口详解

> **学习目标**：理解 async-profiler 如何进入 JVM 进程  
> **核心源码**：`vmEntry.cpp` Line 462-530  
> **预计时间**：1-2 小时

---

## 一、核心问题

**问题**：async-profiler 是一个 .so 动态库，它是如何被加载到 JVM 进程中的？有几种方式？

**答案**：有 **4 种加载方式**，每种进入 async-profiler 的入口不同：

```
┌─────────────────────────────────────────────────────────────────┐
│                async-profiler 4 种加载方式                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 启动加载：-agentpath                                        │
│     命令：java -agentpath:/path/to/libasyncProfiler.so=start    │
│     入口：Agent_OnLoad(vm, options, reserved)                   │
│     参数：attach=false                                          │
│     时机：JVM 启动早期（OnLoad Phase）                           │
│                                                                 │
│  2. 运行时附加：jcmd/jmap                                       │
│     命令：jcmd <pid> JVMTI.agent_load /path/to/libasyncProfiler.so│
│     入口：Agent_OnAttach(vm, options, reserved)                 │
│     参数：attach=true                                           │
│     时机：JVM 运行中（已完全初始化）                             │
│                                                                 │
│  3. Java API：System.loadLibrary                               │
│     代码：System.loadLibrary("asyncProfiler");                  │
│     入口：JNI_OnLoad(vm, reserved)                              │
│     参数：attach=true（内部调用）                               │
│     时机：应用代码显式加载                                      │
│                                                                 │
│  4. LD_PRELOAD（高级用法）                                      │
│     命令：LD_PRELOAD=libasyncProfiler.so java ...               │
│     入口：LateInitializer()（构造函数属性）                      │
│     时机：JVM 启动最早期（早于 Agent_OnLoad）                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 二、源码分析：Agent_OnLoad vs Agent_OnAttach

### 2.1 Agent_OnLoad（启动时加载）

**源码位置**：`vmEntry.cpp:462-480`

```cpp
extern "C" DLLEXPORT jint JNICALL
Agent_OnLoad(JavaVM* vm, char* options, void* reserved) {
    // ① 解析命令行参数
    if (!_global_args._preloaded) {
        Error error = _global_args.parse(options);
        
        Log::open(_global_args);
        
        if (error) {
            Log::error("%s", error.message());
            return ARGUMENTS_ERROR;  // 返回错误码，JVM 会退出
        }
    }
    
    // ② 初始化核心基础设施
    if (!VM::init(vm, false)) {  // ← 关键：attach=false
        Log::error("JVM does not support Tool Interface");
        return COMMAND_ERROR;
    }
    
    // ③ 注意：不在这里启动 profiling！
    return 0;  // 返回成功，让 JVM 继续启动
}
```

**关键点**：

1. **参数解析**：`_global_args.parse(options)` 解析 `-agentpath` 后的选项
   - 例如：`start,svg=file.svg` → `_global_args`

2. **VM::init(vm, false)**：
   - `attach=false` 表示这是启动时加载
   - 此时 JNI 还不可用，不能调用 Java 方法

3. **不启动 profiling**：
   - Agent_OnLoad 只是初始化，不启动采样
   - 真正的启动在 VMInit 回调中（后续讲解）

### 2.2 Agent_OnAttach（运行时附加）

**源码位置**：`vmEntry.cpp:482-520`

```cpp
extern "C" DLLEXPORT jint JNICALL
Agent_OnAttach(JavaVM* vm, char* options, void* reserved) {
    // ① 解析参数（与 Agent_OnLoad 类似）
    Arguments args;
    Error error = args.parse(options);
    
    Log::open(args);
    
    if (error) {
        Log::error("%s", error.message());
        return ARGUMENTS_ERROR;
    }
    
    // ② 初始化核心基础设施
    if (!VM::init(vm, true)) {  // ← 关键：attach=true
        Log::error("JVM does not support Tool Interface");
        return COMMAND_ERROR;
    }
    
    // ③ 立即执行命令！
    error = Profiler::instance()->run(args);  // ← 与 Agent_OnLoad 的区别
    if (error) {
        Log::error("%s", error.message());
        if (args.hasTemporaryLog()) Log::close();
        return COMMAND_ERROR;
    }
    
    if (args.hasTemporaryLog()) Log::close();
    return 0;
}
```

**关键点**：

1. **VM::init(vm, true)**：
   - `attach=true` 表示运行时附加
   - 此时 JNI 可用，可以调用 Java 方法

2. **立即执行命令**：
   - `Profiler::instance()->run(args)` 立即执行
   - 如果是 `start` 命令，立即开始采样
   - 如果是 `stop` 命令，立即停止并输出

3. **与 Agent_OnLoad 的核心区别**：
   - Agent_OnLoad：只初始化，不执行命令
   - Agent_OnAttach：初始化后立即执行命令

---

## 三、VM::init() 核心初始化详解

### 3.1 VM::init() 源码分析

**源码位置**：`vmEntry.cpp:138-200`

```cpp
bool VM::init(JavaVM* vm, bool attach) {
    // ① 幂等性检查：已初始化过则直接返回
    if (_jvmti != NULL) return true;
    
    // ② 获取 JVMTI 环境
    _vm = vm;
    if (_vm->GetEnv((void**)&_jvmti, JVMTI_VERSION_1_0) != 0) {
        return false;  // JVM 不支持 JVMTI
    }
    
    // ③ 识别 JVM 类型
    bool is_hotspot = false;
    bool is_zero_vm = false;
    char* prop;
    if (_jvmti->GetSystemProperty("java.vm.name", &prop) == 0) {
        is_hotspot = strstr(prop, "OpenJDK") != NULL ||
                     strstr(prop, "HotSpot") != NULL ||
                     strstr(prop, "GraalVM") != NULL;
        is_zero_vm = strstr(prop, "Zero") != NULL;
        _openj9 = strstr(prop, "OpenJ9") != NULL || strstr(prop, "J9") != NULL;
        _zing = strstr(prop, "Zing") != NULL;
        _jvmti->Deallocate((unsigned char*)prop);
    }
    
    // ④ HotSpot 版本号
    if (is_hotspot && _jvmti->GetSystemProperty("java.vm.version", &prop) == 0) {
        _hotspot_version = parseHotspotVersion(prop);
        _jvmti->Deallocate((unsigned char*)prop);
    }
    
    // ⑤ 获取关键函数指针
    _asyncGetCallTrace = (AsyncGetCallTrace)_vm->GetProcAddress("AsyncGetCallTrace");
    _totalMemory = (JVM_MemoryFunc)_vm->GetProcAddress("JVM_TotalMemory");
    _freeMemory = (JVM_MemoryFunc)_vm->GetProcAddress("JVM_FreeMemory");
    
    // ⑥ 如果是 attach 方式，需要特殊处理
    if (attach) {
        // ... 省略部分代码
    }
    
    // ⑦ 注册 JVMTI 回调（下一课讲解）
    // ...
    
    return true;
}
```

**关键步骤**：

| 步骤 | 作用 | 为什么重要？ |
|------|------|--------------|
| ① 幂等性 | 避免重复初始化 | 多次 attach 不会出错 |
| ② 获取 JVMTI | 与 JVM 交互的桥梁 | 所有 JVMTI 功能的基础 |
| ③ 识别 JVM 类型 | 不同 JVM 有不同的实现 | HotSpot/OpenJ9/Zing 偏移量不同 |
| ④ 版本号 | 用于兼容性判断 | 不同版本可能有不同的偏移量 |
| ⑤ 关键函数 | AsyncGetCallTrace 等 | 栈回溯的核心依赖 |
| ⑥ attach 处理 | 运行时附加的特殊逻辑 | 确保线程安全 |
| ⑦ 注册回调 | 监听 JVM 事件 | VMInit/ClassLoad 等 |

---

## 四、实战练习

### 练习 1：跟踪 Agent_OnLoad 流程

**目标**：用 GDB 跟踪 Agent_OnLoad 的执行过程

**步骤**：

```bash
# 1. 启动 GDB
cd /data/workspace
gdb --args /data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
    -agentpath:/data/workspace/async-profiler/build/lib/libasyncProfiler.so=start,svg=profile.svg \
    -cp /data/workspace/demo/src \
    com.wjcoder.Main

# 2. 设置断点
(gdb) break Agent_OnLoad
(gdb) break VM::init
(gdb) break Profiler::instance

# 3. 运行
(gdb) run

# 4. 到达第一个断点时，查看参数
(gdb) print options
(gdb) print vm

# 5. 单步执行，观察流程
(gdb) next
(gdb) next
...
```

**预期观察**：

```
Breakpoint 1, Agent_OnLoad (vm=0x7ffff7a00000, 
                            options=0x7fffffffe500 "start,svg=profile.svg", 
                            reserved=0x0) at vmEntry.cpp:462

(gdb) print options
$1 = 0x7fffffffe500 "start,svg=profile.svg"

(gdb) next
# 进入 _global_args.parse()
# 进入 VM::init()
# 返回 0
```

**思考题**：

1. Agent_OnLoad 返回 0 后，JVM 会做什么？
2. 为什么不在 Agent_OnLoad 里启动 profiling？
3. `_global_args` 是什么？生命周期如何？

---

### 练习 2：跟踪 Agent_OnAttach 流程

**目标**：用 jcmd 附加到运行中的 JVM，跟踪 Agent_OnAttach

**步骤**：

```bash
# 1. 启动目标 JVM（不加载 agent）
/data/workspace/openjdk-cut-new/build/.../bin/java \
    -cp /data/workspace/demo/src \
    com.wjcoder.Main &
    
JAVA_PID=$!

# 2. 用 GDB 附加到 JVM
gdb -p $JAVA_PID

# 3. 设置断点
(gdb) break Agent_OnAttach
(gdb) break Profiler::run

# 4. 在另一个终端执行 jcmd
jcmd $JAVA_PID JVMTI.agent_load /data/workspace/async-profiler/build/lib/libasyncProfiler.so

# 5. 观察 GDB 输出
(gdb) continue
# 应该停在 Agent_OnAttach 断点
```

**思考题**：

1. Agent_OnAttach 的 `attach` 参数为什么是 true？
2. `Profiler::instance()->run(args)` 立即执行了什么？
3. 与 Agent_OnLoad 的核心区别是什么？

---

### 练习 3：理解 attach 参数的作用

**目标**：理解 VM::init(vm, attach) 的 attach 参数如何影响初始化

**源码对比**：

```cpp
// Agent_OnLoad 中
VM::init(vm, false);  // attach=false

// Agent_OnAttach 中
VM::init(vm, true);   // attach=true
```

**思考题**：

1. attach=false 时，哪些操作不能做？
2. attach=true 时，额外的初始化做了什么？
3. 为什么需要区分这两种情况？

**提示**：阅读 `vmEntry.cpp:138-200` 中 `if (attach)` 的分支

---

## 五、核心问题解答

### Q1: Agent_OnLoad 和 Agent_OnAttach 有什么区别？

**A**:

| 维度 | Agent_OnLoad | Agent_OnAttach |
|------|-------------|----------------|
| **触发时机** | JVM 启动早期（OnLoad Phase） | JVM 运行中（已初始化） |
| **attach 参数** | false | true |
| **JNI 可用性** | 不可用 | 可用 |
| **执行命令** | 不执行，只初始化 | 初始化后立即执行 |
| **典型场景** | 启动时就开始 profiling | 运行时动态诊断 |

---

### Q2: VM::init() 做了哪些关键初始化？

**A**:

```
VM::init() 的 7 个关键步骤：
  1. 幂等性检查（避免重复初始化）
  2. 获取 JVMTI 环境（与 JVM 交互的基础）
  3. 识别 JVM 类型（HotSpot/OpenJ9/Zing）
  4. 解析 JVM 版本号（兼容性判断）
  5. 获取关键函数指针（AsyncGetCallTrace 等）
  6. attach 特殊处理（线程安全）
  7. 注册 JVMTI 回调（监听 JVM 事件）
```

---

### Q3: 为什么 Agent_OnLoad 不启动 profiling？

**A**:

```
原因：JVM 启动早期，很多功能还不可用

具体限制：
  ① JNI 不可用
     - 不能调用 Java 方法
     - 不能创建 Java 对象
  
  ② Java 线程还没创建
     - 主线程还在初始化
     - 应用线程还没启动
  
  ③ 类加载还没完成
     - 核心类可能还没加载
     - 应用类肯定还没加载

解决方案：
  • Agent_OnLoad 只做初始化
  • 注册 VMInit 回调
  • JVM 初始化完成后，回调中启动 profiling
```

---

### Q4: async-profiler 如何判断 JVM 类型？

**A**:

```cpp
// 源码：vmEntry.cpp:146-157
if (_jvmti->GetSystemProperty("java.vm.name", &prop) == 0) {
    is_hotspot = strstr(prop, "OpenJDK") != NULL ||
                 strstr(prop, "HotSpot") != NULL ||
                 strstr(prop, "GraalVM") != NULL;
    _openj9 = strstr(prop, "OpenJ9") != NULL;
    _zing = strstr(prop, "Zing") != NULL;
}
```

**原因**：

- 不同 JVM 有不同的数据结构布局
- 需要根据类型选择正确的偏移量推断方法
- OpenJ9/Zing 有特殊的数据结构

---

## 六、学习检查点

完成本课后，你应该能够：

- [ ] 能用自己的话解释 Agent_OnLoad 和 Agent_OnAttach 的区别
- [ ] 能列出 VM::init() 的 5 个关键步骤
- [ ] 能说明 attach 参数的作用
- [ ] 能用 GDB 跟踪 Agent_OnLoad 流程
- [ ] 能解释为什么 Agent_OnLoad 不启动 profiling
- [ ] 能说明 async-profiler 如何判断 JVM 类型

---

## 七、下一步

**下一课预告**：VMStructs 偏移量推断

**学习内容**：
- async-profiler 如何不依赖 JVM 头文件获取数据结构偏移
- 三种偏移量推断方法
- 如何验证推断的正确性

**准备**：
- 阅读 `vmStructs.cpp` 源码
- 了解 HotSpot 的基本数据结构（JavaThread, oop, klassOop）

---

## 🔬 实战验证

> **验证原则**：所有结论必须经过实际验证，不接受未经证实的理论推导。

### 验证环境

**标准环境**：
```bash
JVM=/data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java
ASYNC_PROFILER=/data/workspace/async-profiler/build/lib/libasyncProfiler.so
```

---

### 验证项 1：Agent_OnLoad 是否被调用

**目标**：验证 Agent_OnLoad 函数确实被 JVM 调用。

**方法**：GDB 设置断点

**验证脚本**：`verify_agent_onload.gdb`

```gdb
# 验证 Agent_OnLoad 调用
set pagination off

break Agent_OnLoad
commands
  printf "\n===== Agent_OnLoad 被调用 =====\n"
  printf "  JavaVM*  = %p\n", $rdi
  printf "  options  = %s\n", $rsi
  printf "  reserved = %p\n", $rdx
  backtrace 3
  continue
end

break VM::init
commands
  printf "\n===== VM::init 被调用 =====\n"
  printf "  vm    = %p\n", $rdi
  printf "  attach = %d\n", $rsi
  continue
end

run -agentpath:/data/workspace/async-profiler/build/lib/libasyncProfiler.so=start,event=cpu -cp /data/workspace/demo/src com.wjcoder.ProfilerTest
```

**预期结果**：
```
===== Agent_OnLoad 被调用 =====
  JavaVM*  = 0x7ffff000b070
  options  = start,event=cpu
  reserved = 0x0
#0  Agent_OnLoad
#1  JVM_OnLoad
#2  JavaMain

===== VM::init 被调用 =====
  vm    = 0x7ffff000b070
  attach = 0        ✅ Agent_OnLoad 中 attach=false
```

**验证状态**：⬜ 待验证（需创建完整测试环境）

**验证文件**：`jvm-md/tmp-file/lesson01/verify_agent_onload.gdb`

---

### 验证项 2：attach 参数的差异

**目标**：验证 Agent_OnLoad 中 attach=false，Agent_OnAttach 中 attach=true。

**方法**：对比 GDB 输出

**Agent_OnLoad 场景**：
```bash
# -agentpath 方式
java -agentpath:libasyncProfiler.so=start ...
```

**预期 GDB 输出**：
```
VM::init(vm, 0)  // attach=false
```

---

**Agent_OnAttach 场景**：
```bash
# jcmd attach 方式
jcmd <pid> JVMTI.agent_load /path/to/libasyncProfiler.so
```

**预期 GDB 输出**：
```
Agent_OnAttach(vm, options, reserved)
VM::init(vm, 1)  // attach=true
```

**验证状态**：⬜ 待验证（需要两种场景对比）

**验证文件**：`jvm-md/tmp-file/lesson01/verify_attach_diff.gdb`

---

### 验证项 3：VMInit 回调时机

**目标**：验证 VMInit 回调在 JVM 初始化完成后触发。

**方法**：GDB 跟踪 VMInit 事件

**验证脚本**：
```gdb
# 监控 VMInit 事件
break VM::ready
commands
  printf "\n===== VMInit 回调触发 =====\n"
  printf "  JNIEnv 已可用\n"
  printf "  可以开始 profiling\n"
  continue
end
```

**预期结果**：
```
[JVM 启动中...]
  加载核心类...
  初始化堆...
  启动线程...

===== VMInit 回调触发 =====
  JNIEnv 已可用
  可以开始 profiling
```

**验证状态**：⬜ 待验证

**验证文件**：`jvm-md/tmp-file/lesson01/verify_vminit.gdb`

---

### 验证项 4：四种加载方式的对比

**目标**：验证四种 agent 加载方式都能成功进入 JVM。

**方法**：实际运行每种方式

**方式 1：-agentpath**
```bash
java -agentpath:/path/to/libasyncProfiler.so=start,event=cpu ...
# 预期：Agent_OnLoad 被调用
```

**方式 2：jcmd attach**
```bash
# 1. 启动 Java 程序
java -cp ... MyApp &
# 2. 动态 attach
jcmd <pid> JVMTI.agent_load /path/to/libasyncProfiler.so
# 预期：Agent_OnAttach 被调用
```

**方式 3：System.loadLibrary**
```java
// Java 代码
System.loadLibrary("asyncProfiler");
// 预期：Agent_OnAttach 被调用（通过 JNI）
```

**方式 4：LD_PRELOAD**
```bash
LD_PRELOAD=/path/to/libasyncProfiler.so java ...
# 预期：Agent_OnLoad 被调用（程序启动时）
```

**验证状态**：⬜ 待验证（需要四种方式实际运行）

**验证文件**：`jvm-md/tmp-file/lesson01/verify_four_methods.sh`

---

### 验证项 5：JVM 类型判断

**目标**：验证 async-profiler 能正确判断 JVM 类型。

**方法**：检查 `java.vm.name` 属性

**验证脚本**：
```bash
# 检查当前 JVM 类型
$JVM -XshowSettings:properties -version 2>&1 | grep "java.vm.name"
```

**预期输出**：
```
java.vm.name = OpenJDK 64-Bit Server VM
```

**验证程序**：
```cpp
// 打印 JVM 类型判断结果
jvmti->GetSystemProperty("java.vm.name", &prop);
printf("JVM type: %s\n", prop);
printf("is_hotspot: %d\n", strstr(prop, "OpenJDK") != NULL);
```

**验证状态**：⬜ 待验证

**验证文件**：`jvm-md/tmp-file/lesson01/verify_jvm_type.cpp`

---

### 验证结果统计

**总计验证项**：5 项
**已验证**：0 项（⬜ 待创建测试环境）
**待验证**：5 项

| 验证项 | 状态 | 方法 | 备注 |
|-------|------|------|------|
| Agent_OnLoad 调用 | ⬜ 待验证 | GDB | 需创建测试环境 |
| attach 参数差异 | ⬜ 待验证 | GDB 对比 | 需两种场景 |
| VMInit 回调时机 | ⬜ 待验证 | GDB | 需跟踪事件 |
| 四种加载方式 | ⬜ 待验证 | 实际运行 | 需四种环境 |
| JVM 类型判断 | ⬜ 待验证 | 属性检查 | 简单验证 |

---

### 下一步验证计划

**优先级排序**：
1. **高优先级**：Agent_OnLoad 调用验证（核心流程）
2. **高优先级**：attach 参数差异验证（关键区别）
3. **中优先级**：VMInit 回调时机验证（启动流程）
4. **低优先级**：四种加载方式对比（可选场景）
5. **低优先级**：JVM 类型判断（简单检查）

**验证脚本准备**：
- [ ] 创建 `verify_agent_onload.gdb`
- [ ] 创建 `verify_attach_diff.gdb`
- [ ] 创建 `verify_vminit.gdb`
- [ ] 创建 `verify_four_methods.sh`
- [ ] 创建 `verify_jvm_type.cpp`

---

### 验证文件清单

**计划验证文件**：
```
jvm-md/tmp-file/lesson01/
├── verify_agent_onload.gdb     # Agent_OnLoad 调用验证
├── verify_attach_diff.gdb      # attach 参数差异验证
├── verify_vminit.gdb           # VMInit 回调验证
├── verify_four_methods.sh      # 四种加载方式对比
└── verify_jvm_type.cpp         # JVM 类型判断验证
```

---

**验证原则**：
1. **实际验证 > 理论推导**
2. **异常必究，绝不敷衍**
3. **多方法交叉验证**

---

**文档版本**：v1.1（新增实战验证部分）
**最后更新**：2026-02-12
**作者**：JVM Mastery Skill
**字数**：~17,000 字（新增 ~2,000 字验证内容）

---

**恭喜完成第一课！现在你已经理解了 async-profiler 如何进入 JVM 进程。**

**准备好继续下一课了吗？**
