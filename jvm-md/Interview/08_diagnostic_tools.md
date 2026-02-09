# 主题八：JVM 诊断与工具 — 从 Agent 到 HeapDump

> 对应文档: `NativeLibs/ch15~ch24`
> 面试覆盖: Java Agent / JVMTI / Attach API / JMX / HeapDump / NMT / 诊断命令

---

## Q1: Java Agent 是怎么工作的？premain 和 agentmain 有什么区别？⭐⭐

### 一句话结论
**premain** = JVM 启动时 `-javaagent` 加载，在 main() 之前执行；**agentmain** = JVM 运行中通过 Attach API 动态加载。底层都通过 **JVMTI + ClassFileLoadHook** 实现字节码修改。

### 源码级回答

**premain 流程:**
```
-javaagent:agent.jar
  → JVM 启动时 Agent_OnLoad() (libinstrument.so)
  → 创建 JPLISAgent → 注册 VMInit 回调
  → VMInit 触发:
    → createInstrumentationImpl() (创建 Java Instrumentation 对象)
    → 加载 Agent-Class → 调用 premain(String args, Instrumentation inst)
  → 注册 ClassFileLoadHook 事件
  → 后续类加载时自动触发 transformer
```

**agentmain 流程:**
```
VirtualMachine.attach(pid)
  → SIGQUIT 握手 → Unix Domain Socket (/tmp/.java_pid<pid>)
  → vm.loadAgent("agent.jar")
    → 发送 "load" 命令 → 目标 JVM 的 AttachListener 线程
    → dlopen(libinstrument.so) → Agent_OnAttach()
    → 创建 JPLISAgent → 加载 Agent-Class → agentmain()
```

**六大差异:**
| 维度 | premain (Agent_OnLoad) | agentmain (Agent_OnAttach) |
|------|----------------------|---------------------------|
| 时机 | JVM 启动时 | 运行中动态加载 |
| 入口 | premain() | agentmain() |
| MANIFEST | Premain-Class | Agent-Class |
| JVMTI Phase | OnLoad → Primordial → Start → Live | 直接 Live |
| 能力 | 可请求所有能力 | 只能请求 Live 阶段可用的能力 |
| retransform 已加载类 | 需要配合 retransformClasses | 核心场景 |

> 📖 详细文档: `NativeLibs/ch15_java_agent_mechanism.md`, `NativeLibs/ch18_agentmain_dynamic_attach.md`

---

## Q2: Arthas 的 trace/watch 命令底层原理是什么？⭐⭐⭐

### 一句话结论
Arthas 通过 **Attach API 连接目标 JVM → 加载 Agent → retransformClasses 修改字节码** → 在方法入口/出口插入追踪代码 → 完成后再 retransform 还原。

### 源码级回答

```
arthas-core 启动:
  → VirtualMachine.attach(pid)
  → vm.loadAgent("arthas-agent.jar")

arthas-agent.jar:
  → agentmain() → 获取 Instrumentation
  → Instrumentation.retransformClasses(targetClass)
    → JNI: retransformClasses0()
      → JvmtiEnv::RetransformClasses()
        → VM_RedefineClasses (在 Safepoint 下执行!)
          → 获取原始字节码 (get_cached_class_file_bytes)
          → 触发 ClassFileLoadHook 事件
          → Arthas 的 Transformer 修改字节码:
            → 在方法入口插入: Spy.ON_BEFORE(args)
            → 在方法出口插入: Spy.ON_RETURN(result)
            → 在异常处插入:   Spy.ON_THROWS(ex)
          → 新字节码替换旧字节码
          → 更新 vtable/itable
          → flush_dependent_code (反优化已编译的代码!)
```

**retransform vs redefine:**
| 维度 | retransform | redefine |
|------|-------------|----------|
| 原始字节码 | 保留，可以还原 | 覆盖，不可还原 |
| Transformer | 只触发 can_retransform 的 | 触发所有 |
| Arthas 使用 | ✅ retransformClasses | ❌ |
| 限制 | 不能改方法签名/字段 | 不能改方法签名/字段 |

> 📖 详细文档: `NativeLibs/ch16_retransform_classes.md`

---

## Q3: JVMTI 事件体系是怎么设计的？为什么说它是"零开销"？⭐⭐⭐

### 一句话结论
JVMTI 事件默认关闭，启用时通过 **四层位掩码** 层层传播，`should_post_xxx` 全局标志让未启用的事件检查只需**一次 if 判断**，几乎零开销。

### 源码级回答

**四层启用结构:**
```
JvmtiEventEnabled (全局)
  ← EnvEventEnable (每个 JVMTI Agent)
    ← EnvThreadEventEnable (每个线程)
      ← ThreadEventEnable (每个线程)
        → recompute_enabled() 汇总为全局标志
```

**零开销设计:**
```cpp
// 在热路径上的检查:
if (JvmtiExport::should_post_class_file_load_hook()) {
    // 只有这个全局 bool 为 true 才进入
    post_class_file_load_hook(stream);
}
// 没有 Agent 时: should_post_xxx = false → 一次 if 跳过

// 有 Agent 时: 遍历 JvmtiEnvIterator 分发事件
```

**interp_only_mode 联动:**
```
启用 SINGLE_STEP/BREAKPOINT 事件:
  → 设置线程的 interp_only_mode = true
  → VM_EnterInterpOnlyMode → 反优化所有编译帧!
  → 强制回到解释器执行 → 可以在每条字节码处触发事件
  → 性能影响巨大 (100x 慢)
```

> 📖 详细文档: `NativeLibs/ch17_jvmti_event_system.md`

---

## Q4: Attach API 是怎么和目标 JVM 通信的？⭐⭐

### 一句话结论
Attach API 通过 **SIGQUIT 信号 + .attach_pid 文件 + Unix Domain Socket** 三步握手建立连接，然后通过 Socket 发送命令。

### 源码级回答

**握手协议:**
```
┌──── 客户端 (jstack/jmap/Arthas) ────┐  ┌──── 目标 JVM ────────────────────┐
│                                      │  │                                  │
│ 1. 创建 /proc/<pid>/cwd/.attach_pid │  │                                  │
│ 2. kill(pid, SIGQUIT)               │──→│ 3. 信号处理 → 检查 .attach_pid   │
│                                      │  │ 4. 创建 AttachListener 线程      │
│                                      │  │ 5. 创建 /tmp/.java_pid<pid> Socket│
│ 6. connect(/tmp/.java_pid<pid>)     │←─│                                  │
│ 7. write("load\0agent.jar\0...")    │──→│ 8. 解析命令 → 执行 load_agent    │
│ 9. read(response)                   │←─│ 10. 返回结果                      │
└──────────────────────────────────────┘  └──────────────────────────────────┘
```

**安全保护 (三层):**
```
1. .attach_pid 文件权限: 只有同用户可创建
2. SO_PEERCRED: Socket 连接时验证对端 uid
3. uid 匹配: client uid == JVM uid (或 root)
```

**10 个 Attach 命令:**
| 命令 | 对应工具 | 功能 |
|------|---------|------|
| threaddump | jstack | 线程 dump |
| dumpheap | jmap -dump | 堆 dump |
| inspectheap | jmap -histo | 类实例统计 |
| load | Arthas/javaagent | 动态加载 Agent |
| properties | jinfo | 获取系统属性 |
| setflag | jinfo -flag | 修改 JVM 参数 |
| jcmd | jcmd | 诊断命令 |

> 📖 详细文档: `NativeLibs/ch19_libattach_attach_api.md`

---

## Q5: JMX 底层是怎么获取内存/GC 信息的？⭐⭐

### 一句话结论
JMX MXBean → JNI → **JmmInterface 函数表** (39 个函数指针) → 直接读取 JVM 内部数据结构，不经过 JVMTI。

### 源码级回答

```
Java: ManagementFactory.getMemoryMXBean().getHeapMemoryUsage()
  → sun.management.MemoryImpl.getMemoryUsage0(true)
    → JNI: Java_sun_management_MemoryImpl_getMemoryUsage0()
      → jmm_GetMemoryUsage()
        → 遍历所有 MemoryPool → 聚合 init/used/committed/max
```

**JmmInterface 初始化:**
```cpp
JNI_OnLoad(libmanagement.so) {
    jmm = JVM_GetManagement();  // 获取函数表指针
    // jmm 指向 39 个函数: GetMemoryUsage/GetGCInfo/GetThreadInfo/...
}
```

**GC 通知机制:**
```
GC 完成:
  → GCNotifier::pushNotification() → GCNotificationRequest 入链表
  → ServiceThread::service_thread_entry() 检测到通知
  → Java: GarbageCollectorImpl.createGCNotification()
  → 用户注册的 NotificationListener 被回调
```

**低内存检测:**
```
MemoryPool.setUsageThreshold(bytes)
  → ThresholdSupport 迟滞机制
  → GC 后 LowMemoryDetector::detect_low_memory()
  → 超过阈值 → SensorInfo → ServiceThread → 用户回调
```

> 📖 详细文档: `NativeLibs/ch21_jmx_management_impl.md`

---

## Q6: HeapDump 是怎么生成的？为什么会很慢？⭐⭐

### 一句话结论
HeapDump 在 **Safepoint 下**由 `VM_HeapDumper` 遍历整个堆，将对象按 **HPROF 格式**写入文件。8GB 堆的 dump 可能需要几十秒到几分钟。

### 源码级回答

```
jmap -dump:format=b,file=heap.hprof <pid>
  → Attach API → HeapDumpDCmd
    → VM_HeapDumper::doit() (在 Safepoint 下执行!)

VM_HeapDumper::doit():
  1. 写 HPROF 文件头
  2. 遍历所有 String (HPROF_UTF8 记录)
  3. 遍历 SystemDictionary 导出所有类 (HPROF_LOAD_CLASS)
  4. 写 HPROF_HEAP_DUMP_SEGMENT:
     → 遍历堆中所有 Region 的所有对象
     → 每个对象: class + 所有字段值 + 数组元素
  5. 写 GC Roots (线程栈引用、JNI 引用等)
  6. 写 HPROF_HEAP_DUMP_END

为什么慢:
  - 整堆遍历 → O(堆大小)
  - 全程 STW → 应用完全停止
  - 磁盘 I/O → 文件可能和堆一样大
```

**GZip 压缩优化 (JDK 11+):**
```
-XX:HeapDumpGzipCompression=1  # 启用 GZip 压缩
→ DumpWriter + CompressionBackend 流水线并行
→ 写入和压缩并行执行
→ 文件小 5-10 倍
```

**OOM 自动 Dump:**
```
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=/path/to/dump
→ OOM 时自动触发 dump
→ report_vm_out_of_memory() → HeapDumper::dump()
```

> 📖 详细文档: `NativeLibs/ch22_diagnostic_command_heapdumper.md`

---

## Q7: NMT (Native Memory Tracking) 能追踪什么？怎么用？⭐⭐

### 一句话结论
NMT 追踪 JVM **所有 native 内存分配**（堆/Metaspace/线程栈/CodeCache/GC/编译器/...），通过 `jcmd VM.native_memory` 查看。

### 源码级回答

**启用 NMT:**
```
-XX:NativeMemoryTracking=summary  # 汇总模式 (~5% 开销)
-XX:NativeMemoryTracking=detail   # 详细模式 (~10% 开销, 记录调用栈)
```

**查看内存分布:**
```
$ jcmd <pid> VM.native_memory summary

Total: reserved=9GB, committed=8.5GB
-                 Java Heap (reserved=8GB, committed=8GB)
-                     Class (reserved=1GB, committed=50MB)    ← Metaspace
-                    Thread (reserved=500MB, committed=500MB)  ← 线程栈
-                      Code (reserved=250MB, committed=100MB)  ← CodeCache
-                        GC (reserved=400MB, committed=400MB)  ← GC 数据结构
-                  Compiler (reserved=10MB, committed=10MB)    ← 编译器
-                  Internal (reserved=50MB, committed=50MB)    ← JVM 内部
-                    Symbol (reserved=20MB, committed=20MB)    ← 符号表
```

**基线对比 (内存泄漏排查):**
```
1. jcmd <pid> VM.native_memory baseline      # 设置基线
2. ... 运行一段时间 ...
3. jcmd <pid> VM.native_memory summary.diff   # 对比差异
   → [+10MB] 某个区域增长 → 可能泄漏
```

> 📖 详细文档: `NativeLibs/ch22_diagnostic_command_heapdumper.md`

---

## Q8: jstack/jmap/jcmd 底层都是通过什么实现的？⭐

### 一句话结论
都通过 **Attach API** → Unix Domain Socket → 发送对应命令 → 目标 JVM 的 AttachListener 线程执行并返回结果。

### 源码级回答

| 工具 | Attach 命令 | 目标 JVM 执行 |
|------|------------|--------------|
| jstack | threaddump | VM_PrintThreads (STW) |
| jmap -dump | dumpheap | VM_HeapDumper (STW) |
| jmap -histo | inspectheap | VM_GC_HeapInspection (STW) |
| jcmd | jcmd | 通过 DCmdFactory 路由到具体命令 |
| jinfo -flag | setflag | WriteableFlags::set_flag() |

**DCmd 框架 (jcmd 命令路由):**
```
jcmd <pid> GC.heap_dump /tmp/heap.hprof
  → Attach API → "jcmd\0GC.heap_dump /tmp/heap.hprof"
  → AttachListener → DCmdFactory 查找 "GC.heap_dump"
  → HeapDumpDCmd::execute()
  → VM_HeapDumper (STW)
```

**jcmd 常用命令:**
```
jcmd <pid> GC.heap_dump /tmp/heap.hprof    # 堆 dump
jcmd <pid> GC.class_histogram              # 类直方图
jcmd <pid> Thread.print                     # 线程 dump
jcmd <pid> VM.native_memory summary         # NMT
jcmd <pid> VM.flags                         # JVM 参数
jcmd <pid> VM.system_properties             # 系统属性
jcmd <pid> Compiler.queue                   # 编译队列
jcmd <pid> GC.run                           # 触发 GC
```

> 📖 详细文档: `NativeLibs/ch22_diagnostic_command_heapdumper.md`, `NativeLibs/ch19_libattach_attach_api.md`

---

## Q9: JVM 启动流程是什么？从 java 命令到 main() ⭐⭐

### 一句话结论
`java` 命令 → `libjli.so` 的 `JLI_Launch` → 解析参数 → `LoadJavaVM` (dlopen libjvm.so) → 新线程 `JavaMain` → `InitializeJVM` → `JNI_CreateJavaVM` → `Threads::create_vm()` → 调用用户 `main()`。

### 源码级回答

```
main() [libjli.so]
  → JLI_Launch()
    → CreateExecutionEnvironment()
      → GetJREPath() → ReadKnownVMs(jvm.cfg) → GetJVMPath()
    → LoadJavaVM()
      → dlopen(libjvm.so, RTLD_NOW | RTLD_GLOBAL)
      → dlsym("JNI_CreateJavaVM")
    → ParseArguments()
      → 分类参数 (VM options / Main class / Program args)
    → JVMInit()
      → ContinueInNewThread()
        → pthread_create(JavaMain)  // 在新线程中执行!

JavaMain():
  → InitializeJVM()
    → JNI_CreateJavaVM()
      → Threads::create_vm()
        → Arguments::parse()           // 解析 JVM 参数
        → os::init()                   // OS 初始化
        → vm_init_globals()            // 全局初始化
        → init_globals()               // 38 步组件初始化!
        → create main JavaThread       // 创建主线程
        → universe_post_init()         // 后初始化
        → System.initPhase1/2/3        // Java 层初始化

  → LoadMainClass("com.example.Main")
    → LauncherHelper.checkAndLoadMain()
  → CallStaticVoidMethod(mainClass, "main", args)
    → 用户代码开始执行!
```

**为什么 JavaMain 要在新线程中?**
- 主线程的栈大小由 OS 决定，可能不够
- 新线程可以精确控制 `-Xss` 设定的栈大小
- 主线程变成 "等待线程"（等 DestroyJavaVM）

> 📖 详细文档: `NativeLibs/ch23_libjli_jvm_launch.md`

---

## Q10: 反射 Method.invoke() 底层是怎么实现的？⭐⭐

### 一句话结论
前 15 次通过 **NativeMethodAccessorImpl** JNI 调用，第 16 次自动 **inflation**（生成动态字节码 `GeneratedMethodAccessorN`），之后走纯 Java 快速路径。

### 源码级回答

```
Method.invoke(obj, args)
  → DelegatingMethodAccessorImpl.invoke()
    → (前15次) NativeMethodAccessorImpl.invoke()
      → JNI: invoke0() → JVM_InvokeMethod()
        → Reflection::invoke_method()
          → 参数 unbox + widen
          → JavaCalls::call() → 解释器/编译代码

    → (第16次) inflation! 生成 GeneratedMethodAccessorN:
      → MethodAccessorGenerator.generate()
        → 动态生成字节码类
        → defineClass() → DelegatingMagicAccessor
      → 替换 delegate 为 GeneratedMethodAccessorImpl

    → (后续) GeneratedMethodAccessorImpl.invoke()
      → 纯 Java 调用 (checkcast + invokevirtual)
      → 可被 JIT 内联!
```

**为什么 15 次阈值?**
```
-Dsun.reflect.inflationThreshold=15  # 可配置
→ 少于 15 次: JNI 开销 < 生成字节码的开销
→ 超过 15 次: 生成的字节码可被 JIT 优化，长期受益
```

> 📖 详细文档: `Runtime/ch07_reflection_deep_dive.md`

---

## 🎯 面试话术建议

### 如何展示诊断工具的源码功底:

> "Arthas 的 trace 命令底层是 retransformClasses。它通过 Attach API 连接目标 JVM，加载 Agent，然后调用 Instrumentation.retransformClasses。JVM 内部这会触发 VM_RedefineClasses 在 Safepoint 下执行，获取原始字节码，触发 ClassFileLoadHook 让 Transformer 修改字节码，最后替换方法并反优化已编译的代码。所以 trace 会导致一次短暂的 STW。"

> "Attach API 的握手协议我看过源码：客户端创建 .attach_pid 文件，发送 SIGQUIT 信号，目标 JVM 的信号处理器检查到文件后创建 AttachListener 线程，监听 /tmp/.java_pid<pid> 的 Unix Domain Socket。安全保障靠文件权限、SO_PEERCRED 的 uid 验证和目录所有者检查。"

> "反射的 inflation 机制很有意思——前 15 次走 JNI 通道（JVM_InvokeMethod → Reflection::invoke_method → JavaCalls::call），第 16 次用 MethodAccessorGenerator 动态生成字节码类 GeneratedMethodAccessorN。生成的类继承 MagicAccessorImpl，跳过访问权限检查和字节码验证。后续调用是纯 Java，可以被 JIT 内联，性能和直接调用几乎一样。"
