# 1.1 Agent 加载路径

> 源文件: `vmEntry.cpp` (531行), `vmEntry.h` (198行), `zInit.cpp` (66行), `hooks.cpp` (201行)
> 关联 JVM 源码: `thread.cpp` (Threads::create_vm_init_agents), `jvmtiExport.cpp` (load_agent_library)

## 核心问题

**async-profiler 的 .so 是怎么被加载到 JVM 进程里的？有几种方式？各自走的什么代码路径？**

答：有 **4 种加载方式**，每种进入 async-profiler 代码的入口不同：

```
┌─────────────────────────────────────────────────────────────────┐
│                   async-profiler 4 种加载方式                    │
│                                                                  │
│  1. -agentpath:       → Agent_OnLoad()     → VM::init(attach=0) │
│  2. Attach API (运行中) → Agent_OnAttach()  → VM::init(attach=1) │
│  3. System.loadLibrary → JNI_OnLoad()       → VM::init(attach=1) │
│  4. LD_PRELOAD        → LateInitializer()  → Hooks::init()      │
└─────────────────────────────────────────────────────────────────┘
```

## 一、加载方式 1：-agentpath 启动加载（最常用）

### 1.1 JVM 侧发生了什么？

用户用 `-agentpath:/path/to/libasyncProfiler.so=options` 启动 JVM 时，JVM 在 `Threads::create_vm()` 阶段（线程模型还没建好、Java 还没初始化）调用 `Threads::create_vm_init_agents()`：

```
JVM 启动流程（简化）:
    JavaMain()
      → JNI_CreateJavaVM()
        → Threads::create_vm()
          → ... 堆/GC/CodeCache 初始化 ...
          → Threads::create_vm_init_agents()    ← 在这里加载 agent
            → dlopen("libasyncProfiler.so")
            → dlsym("Agent_OnLoad")
            → (*on_load_entry)(&main_vm, options, NULL)   ← 调用 Agent_OnLoad
          → ... 继续初始化 ...
          → JvmtiExport::post_vm_initialized()  ← 触发 VMInit 回调
```

JVM 侧的关键代码在 `thread.cpp:4425-4445`：

```cpp
// Invokes Agent_OnLoad — Called very early, before JavaThreads exist
void Threads::create_vm_init_agents() {
    JvmtiExport::enter_onload_phase();
    for (agent = Arguments::agents(); agent != NULL; agent = agent->next()) {
        OnLoadEntry_t on_load_entry = lookup_agent_on_load(agent);
        jint err = (*on_load_entry)(&main_vm, agent->options(), NULL);
        // 如果返回非 JNI_OK，JVM 直接退出
    }
    JvmtiExport::enter_primordial_phase();
}
```

**关键时序**：`Agent_OnLoad` 被调用时，JVM 处于 **OnLoad Phase**，此时：
- ✅ 堆已创建、GC 已初始化、CodeCache 已建立
- ✅ 可以使用 JVMTI（但功能受限）
- ❌ JNI 不可用（Java 线程还没创建）
- ❌ 不能调用任何 Java 方法

### 1.2 async-profiler 侧的 Agent_OnLoad

```cpp
// vmEntry.cpp:460
extern "C" DLLEXPORT jint JNICALL
Agent_OnLoad(JavaVM* vm, char* options, void* reserved) {
    // ① 解析命令行参数
    if (!_global_args._preloaded) {
        Error error = _global_args.parse(options);
        Log::open(_global_args);
    }
    // ② 初始化核心基础设施
    if (!VM::init(vm, false)) {   // attach=false ← 关键区分点
        return COMMAND_ERROR;
    }
    return 0;    // ← 注意！不在这里启动 profiling
}
```

**注意**: `Agent_OnLoad` 里**不启动 profiling**！因为此时 JVM 还没完全初始化（JNI 不可用）。真正的 profiling 启动在后面的 `VMInit` 回调中。

### 1.3 VM::init() — 核心初始化函数

`VM::init(vm, attach)` 是所有加载方式的公共汇聚点，`attach` 参数决定走哪个分支：

```cpp
bool VM::init(JavaVM* vm, bool attach) {
    if (_jvmti != NULL) return true;  // 幂等：已初始化过则直接返回

    // Step 1: 获取 JVMTI 环境
    _vm = vm;
    _vm->GetEnv((void**)&_jvmti, JVMTI_VERSION_1_0);

    // Step 2: 识别 JVM 类型和版本
    //   通过 java.vm.name 区分: HotSpot / OpenJ9 / Zing
    //   通过 java.vm.version 提取版本号

    // Step 3: dlsym 查找关键函数
    //   AsyncGetCallTrace / JVM_TotalMemory / JVM_FreeMemory

    // Step 4: VMStructs::init() — 推断 JVM 内部结构偏移量

    // Step 5: 标记 runtime 入口函数（用于栈回溯时区分帧类型）

    // Step 6: 注册 JVMTI Capabilities + Callbacks + 事件通知

    // Step 7: 分支处理
    if (attach) {
        ready();                     // 立即完成后续初始化
        loadAllMethodIDs(...);       // 加载所有已有方法 ID
        GenerateEvents(COMPILED_METHOD_LOAD);  // 回放已编译方法
    } else {
        // 启动加载 → 注册 VMInit 事件，等 JVM 初始化完再执行
        SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_VM_INIT, NULL);
    }
}
```

### 1.4 Agent_OnLoad 的完整时序图

```
时间线    JVM 侧                          async-profiler 侧
────────────────────────────────────────────────────────────────
T0       Threads::create_vm_init_agents()
T1       dlopen("libasyncProfiler.so")
         → 触发 LateInitializer 构造函数    LateInitializer():
                                             checkJvmLoaded() → true
                                             VMStructs::init(libjvm) ← 第1次
T2       调用 Agent_OnLoad()               Agent_OnLoad():
                                             _global_args.parse(options)
                                             VM::init(vm, false):
                                               GetEnv → _jvmti
                                               识别 HotSpot v11
                                               dlsym(AsyncGetCallTrace)
                                               VMStructs::init() ← 跳过(已初始化)
                                               标记 runtime 入口
                                               注册 Capabilities
                                               注册 Callbacks
                                               注册 VMInit 事件 ← 等待
T3       ... JVM 继续初始化 ...
T4       post_vm_initialized()             VMInit 回调:
                                             VM::ready():
                                               setupSignalHandlers()
                                               VMStructs::ready()
                                               Hook JVMTI 函数表
                                             loadAllMethodIDs()
                                             Profiler::run() ← 启动 profiling!
```

## 二、加载方式 2：Attach API 动态附加

当 JVM 已经在运行时，通过 `asprof` 命令行工具或 `jattach` 动态加载：

```bash
asprof start <pid>
# 等价于: jattach <pid> load /path/to/libasyncProfiler.so true start,...
```

JVM 侧在 `jvmtiExport.cpp:2635` 中处理 Attach 请求：

```cpp
// JVM 在 Attach 线程中执行
jint JvmtiExport::load_agent_library(...) {
    library = os::dll_load(agent, ...);           // dlopen
    on_attach_entry = dlsym("Agent_OnAttach");    // 查找入口
    result = (*on_attach_entry)(&main_vm, options, NULL);  // 调用
}
```

async-profiler 侧：

```cpp
// vmEntry.cpp:483
extern "C" DLLEXPORT jint JNICALL
Agent_OnAttach(JavaVM* vm, char* options, void* reserved) {
    Arguments args;
    args.parse(options);

    VM::init(vm, true);   // attach=true ← 关键区别

    // 直接启动 profiling（不需要等 VMInit）
    Profiler::instance()->run(args);
    return 0;
}
```

**与 Agent_OnLoad 的核心区别**:

| 维度 | Agent_OnLoad (attach=false) | Agent_OnAttach (attach=true) |
|------|---------------------------|------------------------------|
| 时机 | JVM 启动初期，Java 未初始化 | JVM 已完全运行 |
| JNI | ❌ 不可用 | ✅ 可用 |
| ready() | 在 VMInit 回调中执行 | 在 VM::init() 中立即执行 |
| loadAllMethodIDs | 在 VMInit 回调中执行 | 在 VM::init() 中立即执行 |
| GenerateEvents | 在 VM::init() 中立即执行 | 在 VM::init() 中立即执行 |
| 启动 profiling | 在 VMInit 回调中延迟启动 | 在 Agent_OnAttach 中直接启动 |
| 参数存储 | `_global_args`（全局） | 局部 `args` 变量 |

## 三、加载方式 3：JNI_OnLoad（Java API 加载）

当通过 Java 代码 `System.loadLibrary("asyncProfiler")` 加载时：

```cpp
// vmEntry.cpp:515
extern "C" DLLEXPORT jint JNICALL
JNI_OnLoad(JavaVM* vm, void* reserved) {
    VM::init(vm, true);     // 和 Attach 相同路径
    JavaAPI::registerNatives(VM::jvmti(), VM::jni());  // 注册 native 方法
    return JNI_VERSION_1_6;
}
```

这种方式主要用于 **Java API 方式调用**（`one.profiler.AsyncProfiler` 类），不走命令行。

## 四、加载方式 4：LD_PRELOAD（无 agent 加载）

最特殊的方式——通过环境变量预加载 .so：

```bash
LD_PRELOAD=/path/to/libasyncProfiler.so ASPROF_COMMAND="start,event=cpu" java -jar app.jar
```

此时 async-profiler 的 .so 在 JVM 启动**之前**就被加载到进程中。入口是 `zInit.cpp` 中的静态构造函数：

```cpp
// zInit.cpp — 文件名以 z 开头，保证最后编译链接，构造函数最后执行
class LateInitializer {
  public:
    LateInitializer() {
        // 1. 防止 .so 被 dlclose 卸载
        dlopen(self, RTLD_LAZY | RTLD_NODELETE);

        // 2. 检查 libjvm 是否已加载
        if (!checkJvmLoaded()) {
            // libjvm 还没加载 → 纯 LD_PRELOAD 场景
            const char* command = getenv("ASPROF_COMMAND");
            if (command != NULL && Hooks::init(false)) {
                startProfiler(command);     // 预设参数，等 JVM 启动后自动 profiling
            }
        }
    }
};
static LateInitializer _late_initializer;  // 全局静态对象 → 进程加载时构造
```

**为什么文件叫 `zInit.cpp`？**

因为 C++ 全局静态对象的构造函数按编译单元链接顺序执行。文件名以 `z` 开头，在字母序上排最后，确保其他所有静态对象（如 `Profiler::_instance`）都已经构造完毕后，才执行 `LateInitializer` 的构造函数。

### LD_PRELOAD 模式的特殊之处：pthread hook

当以 LD_PRELOAD 方式加载时，`hooks.cpp` 中的弱符号覆盖生效：

```cpp
// hooks.cpp — 利用 WEAK 符号覆盖 libc 函数
extern "C" WEAK DLLEXPORT
int pthread_create(pthread_t* thread, ...) { ... }

extern "C" WEAK DLLEXPORT
void* dlopen(const char* filename, int flags) { ... }
```

这些 hook 在 `Hooks::initialized()` 返回 true 后才生效，用于：
- `pthread_create` hook → 在新线程中解除 SIGPROF 信号屏蔽 + 注册 CpuEngine
- `dlopen` hook → 新 .so 加载后更新符号表 + 重新 patch GOT

## 五、GDB 验证

### 【GDB 验证 1】Agent_OnLoad 完整调用栈

```
标准条件: -Xms8g -Xmx8g -XX:+UseG1GC -Xint
加载参数: -agentpath:libasyncProfiler.so=start,event=cpu,file=/tmp/profile.jfr
┌─────────────────────────────────────────────────────────────────────┐
│ #0  Agent_OnLoad (vm=0x7ffff75b2390, options="start,event=cpu,...") │
│ #1  Threads::create_vm_init_agents()    thread.cpp:4438             │
│ #2  Threads::create_vm()                thread.cpp:3992             │
│ #3  JNI_CreateJavaVM_inner()            jni.cpp:4010                │
│ #4  JNI_CreateJavaVM()                  jni.cpp:4115                │
│ #5  InitializeJVM()                     java.c:1626                 │
│ #6  JavaMain()                          java.c:509                  │
│ #7  ThreadJavaMain()                    java_md_solinux.c:765       │
│ #8  start_thread()                      libc                        │
└─────────────────────────────────────────────────────────────────────┘
```

**关键观察**: Agent_OnLoad 在 `Threads::create_vm()` 内部被调用，此时还在 `JNI_CreateJavaVM` 的过程中，JVM 还没完全就绪。

### 【GDB 验证 2】VM::init 内部状态

```
┌─────────────────────────────────────────────────────────────────────┐
│ VM::init(vm=0x7ffff75b2390, attach=false)                           │
│                                                                      │
│ _jvmti            = 0x7ffff176ceb8     ← JVMTI 环境指针              │
│ is_hotspot        = 1                  ← 识别为 HotSpot              │
│ is_zero_vm        = 0                                                │
│ _hotspot_version  = 11                 ← OpenJDK 11                  │
│                                                                      │
│ AsyncGetCallTrace = 0x7ffff6067a36     ← 从 libjvm.so 解析           │
│ JVM_TotalMemory   = 0x7ffff634d02c                                   │
│ JVM_FreeMemory    = 0x7ffff634d242                                   │
└─────────────────────────────────────────────────────────────────────┘
```

### 【GDB 验证 3】JVMTI Capabilities 请求清单

```
┌─────────────────────────────────────────────────────────────────────┐
│ can_generate_all_class_hook_events       = 1  ← Instrument 需要      │
│ can_retransform_classes                  = 1  ← Instrument 需要      │
│ can_retransform_any_class                = 1  ← 非 OpenJ9            │
│ can_get_bytecodes                        = 1  ← 方法分析             │
│ can_get_constant_pool                    = 1  ← 类信息               │
│ can_get_source_file_name                 = 1  ← 堆栈显示             │
│ can_get_line_numbers                     = 1  ← 行号信息             │
│ can_generate_compiled_method_load_events  = 1  ← JIT 方法跟踪        │
│ can_generate_monitor_events              = 1  ← LockTracer 需要      │
│ can_generate_garbage_collection_events    = 1  ← GC 事件              │
│ can_tag_objects                           = 1  ← 对象标记             │
└─────────────────────────────────────────────────────────────────────┘
```

### 【GDB 验证 4】VMStructs 关键偏移量（与 JVM 源码对照）

```
┌──────────────────────────────────────────────────────────────────────────┐
│ 偏移量名称                         asprof推断值  含义                      │
├──────────────────────────────────────────────────────────────────────────┤
│ _klass_name_offset                = 24         Klass::_name 偏移         │
│ _symbol_body_offset               = 6          Symbol::_body 偏移        │
│ _oop_klass_offset                 = 8          oopDesc::_metadata 偏移   │
│ _thread_osthread_offset           = 672        JavaThread::_osthread     │
│ _thread_anchor_offset             = 888        JavaThread::_anchor       │
│ _thread_state_offset              = 1040       JavaThread::_thread_state │
│ _anchor_sp_offset                 = 0          JavaFrameAnchor::_sp      │
│ _anchor_pc_offset                 = 8          JavaFrameAnchor::_pc      │
│ _anchor_fp_offset                 = 16         JavaFrameAnchor::_fp      │
│ _nmethod_method_offset            = 128        nmethod::_method          │
│ _nmethod_entry_offset             = -272       nmethod::_verified_entry   │
│ _nmethod_state_offset             = 351        nmethod::_state           │
│ _method_constmethod_offset        = 16         Method::_constMethod      │
│ _method_code_offset               = 80         Method::_code             │
│ _flag_count                       = 1366       JVM Flag 总数             │
│ _flag_size                        = 48         每个 Flag 结构大小         │
│ _entry_frame_call_wrapper_offset  = -48        entry frame 偏移          │
│ _code_heap_low                    = 0x7fffec7ff0a0                       │
│ _code_heap_high                   = 0x7fffec913b28                       │
└──────────────────────────────────────────────────────────────────────────┘
```

这些偏移量是 async-profiler 通过读取 `gHotSpotVMStructs` 符号表推断出来的，**不依赖 JVM 头文件**——这是 async-profiler 能跨 JDK 版本工作的关键。

### 【GDB 验证 5】VMInit 回调时序

```
┌─────────────────────────────────────────────────────────────────────┐
│ #0  VM::VMInit()                                                     │
│ #1  JvmtiExport::post_vm_initialized()   jvmtiExport.cpp:691        │
│ #2  Threads::create_vm()                 thread.cpp:4248             │
│ #3  JNI_CreateJavaVM_inner()             jni.cpp:4010                │
│                                                                      │
│ VMInit 回调中执行:                                                    │
│   → VM::ready()                                                      │
│     → Profiler::setupSignalHandlers()    ← 安装 SIGTRAP 等           │
│     → VMStructs::ready()                                             │
│       → resolveOffsets()                 ← 解析压缩指针等             │
│       → patchSafeFetch()                 ← JDK bug workaround        │
│       → initThreadBridge()               ← eetop 字段 + TLS          │
│     → Hook JVMTI 函数表 (RedefineClasses/RetransformClasses)         │
│   → loadAllMethodIDs()                   ← 遍历所有已加载类           │
│   → Profiler::run(_global_args)          ← 真正开始 profiling!        │
│                                                                      │
│ _global_args._event  = 'cpu'                                         │
│ _global_args._action = 1 (ACTION_START)                              │
│ _global_args._file   = '/tmp/profile.jfr'                            │
└─────────────────────────────────────────────────────────────────────┘
```

### 【GDB 验证 6】一个有趣的发现 — VMStructs::init 被调用了两次

```
时间    调用者                              libjvm 参数
─────────────────────────────────────────────────────────────
T1      LateInitializer::checkJvmLoaded()   libjvm=0x7ffff0112e40  ← 第1次
T2      VM::init()                          跳过（VMStructs::libjvm() != NULL）
```

第 1 次是 `dlopen("libasyncProfiler.so")` 触发的 `LateInitializer` 构造函数中调用。
到 `VM::init()` 时，检查 `VMStructs::libjvm() == NULL` 为 false，跳过了第 2 次调用。
这说明**即使是 -agentpath 模式，LateInitializer 的构造函数也会执行**（因为 dlopen 加载 .so 时触发），只是它检测到 `libjvm` 已加载，就走了 `checkJvmLoaded()` 的 true 分支返回了。

## 六、四种加载方式总结对比

```
                    ┌─────────────┐
                    │  用户触发    │
                    └──────┬──────┘
                           │
          ┌────────────────┼────────────────┬──────────────────┐
          ▼                ▼                ▼                  ▼
    -agentpath:      Attach API      System.load       LD_PRELOAD
          │                │                │                  │
          ▼                ▼                ▼                  ▼
    Agent_OnLoad     Agent_OnAttach    JNI_OnLoad      LateInitializer
    (attach=false)   (attach=true)    (attach=true)    + Hooks::init
          │                │                │                  │
          └────────────────┴────────────────┘                  │
                           │                                   │
                    VM::init(vm, attach)                  独立路径
                           │
               ┌───────────┴───────────┐
               │                       │
          attach=false            attach=true
               │                       │
          注册 VMInit 事件         ready() 立即执行
          等待 JVM 就绪           loadAllMethodIDs()
               │                  GenerateEvents()
               │                       │
          VMInit 回调:                  │
            ready()                    │
            loadAllMethodIDs()         │
            Profiler::run()      Profiler::run()
               │                       │
               └───────────┬───────────┘
                           │
                    Profiling 开始
```

## 七、设计洞察

### 为什么 Agent_OnLoad 不直接启动 profiling？

因为 `Agent_OnLoad` 在 JVM 的 **OnLoad Phase** 执行，此时：
1. **JNI 不可用** → `loadAllMethodIDs()` 需要 JNI
2. **Java 类还没全部加载** → 获取的 method ID 不完整
3. **VM 内部结构还在变化** → `VMStructs::resolveOffsets()` 需要 JNI 来获取 `eetop` 等字段

所以 async-profiler 注册了 `VMInit` 事件回调，等 JVM 完全初始化后再执行 `ready()` + `Profiler::run()`。

### 为什么 attach=true 时可以直接 ready()？

因为 Attach 时 JVM 已经完全初始化，JNI 可用，所有类都已加载，不需要等待。

### 为什么要预加载 jmethodIDs？

`loadAllMethodIDs()` 遍历所有已加载的类，调用 `GetClassMethods()` 让 JVM 为每个方法分配 `jmethodID`。这是因为 `AsyncGetCallTrace` 返回的栈帧包含 `jmethodID`，如果方法没有对应的 ID，栈帧信息就不完整。

### _preloaded 标志的含义

`_global_args._preloaded` 用于区分 LD_PRELOAD 场景：
- 当 `_preloaded = true` 时，`VMInit` 回调中**不会**调用 `Profiler::run()`（因为 LD_PRELOAD 模式已经在 `LateInitializer` 中启动了）
- 当 `_preloaded = false` 时（正常 -agentpath），`VMInit` 回调中**会**延迟启动 profiling

---

*创建日期: 2026-02-09*
*GDB 验证环境: OpenJDK 11 slowdebug + async-profiler v4.0 (git 00a0a12)*
*标准条件: -Xms8g -Xmx8g -XX:+UseG1GC -Xint*