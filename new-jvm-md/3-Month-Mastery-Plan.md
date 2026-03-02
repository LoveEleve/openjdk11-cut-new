# JVM/AsyncProfiler/Arthas/SO库 三个月精通计划

> **制定日期**：2026-02-15  
> **目标截止**：2026-05-15  
> **总时长**：~90 天，按每天 3-4 小时计算，共 ~300 小时  
> **标准环境**：`-Xms8g -Xmx8g -XX:+UseG1GC`，G1 Region = 4MB

---

## 一、现有进度评估

### 已完成（~60%完成度的领域标记 ✅，部分完成标记 🔶，未开始标记 ⬜）

| 领域 | 完成度 | 已有文档数 | 核心内容 |
|------|--------|-----------|----------|
| **G1 GC** | ✅ 85% | 80+ 篇 | Young/Mixed/Full GC 全流程、27个核心数据结构、RSet/CardTable/PLAB/BOT 等 |
| **JVM 启动流程** | 🔶 60% | 20+ 篇 | create_vm Phase 1-6，Phase 7-12 部分未完成 |
| **AsyncProfiler** | ✅ 95% | 14 篇 | 12课完整源码 + 实战 + AsyncGetCallTrace |
| **Arthas** | 🔶 70% | 16 篇 | 启动/ClassLoader/Spy/字节码增强/OGNL/核心命令 |
| **类加载** | 🔶 50% | 15 篇 | ClassFileParser/InstanceKlass/双亲委派/链接初始化 |
| **解释器** | 🔶 65% | 22 篇 | 初始化/入口点/字节码模板/invoke/allocation |
| **编译器(C1/C2)** | ⬜ 15% | 3 篇 | 只有管线概览和逃逸分析 |
| **Safepoint** | 🔶 40% | 5+8 篇 | begin/polling/counted loop，缺 end/cleanup |
| **运行时** | 🔶 50% | 9 篇 | 对象头/分配/锁/引用/异常/反射 |
| **JMM** | ⬜ 30% | 3 篇 | 内存序/CAS/volatile |
| **Metaspace** | ⬜ 20% | 2 篇 | 只有概览 |
| **SO 动态库** | 🔶 55% | 43 篇 | libjsig/JVMTI/DirectBuffer/FileChannel/libattach/libnet/libnio |
| **ConcurrentHashTable** | ✅ 90% | 3 篇 | 架构/算法/性能 |

---

## 二、三个月整体规划

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         三个月精通路线图                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  第 1 个月（02.15 - 03.15）：补齐核心短板                                    │
│  ├── Week 1-2：JVM 启动流程收尾 + Safepoint 完整分析                        │
│  ├── Week 3：  编译器系统（C1/C2）核心流程                                   │
│  └── Week 4：  Metaspace + 类加载深化                                        │
│                                                                             │
│  第 2 个月（03.16 - 04.15）：SO 库 + 运行时深入                             │
│  ├── Week 5-6：核心 SO 库逐个击破                                           │
│  ├── Week 7：  JMM + 并发机制完善                                            │
│  └── Week 8：  Arthas 深化 + 运行时补全                                      │
│                                                                             │
│  第 3 个月（04.16 - 05.15）：综合实战 + 查漏补缺                             │
│  ├── Week 9-10：跨模块联合调试 + 性能诊断实战                               │
│  ├── Week 11：  面试级知识体系整理                                           │
│  └── Week 12：  模拟面试 + 最终查漏补缺                                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 三、第 1 个月：补齐核心短板（02.15 - 03.15）

### Week 1（02.15 - 02.21）：JVM 启动流程收尾

**目标**：补全 create_vm 剩余阶段，形成完整启动链路认知。

| 天 | 任务 | 关键源码 | 产出 | 预计时长 |
|----|------|---------|------|---------|
| Day 1 | **Phase 6 续：universe_init 深入** | `universe.cpp:924` `Universe::initialize_heap()` | universe_init 完整文档 | 3h |
| Day 2 | **Phase 7：VMThread 创建与运行** | `vmThread.cpp` `VMThread::create()` `VMThread::run()` | VMThread 深度文档 | 4h |
| Day 3 | **Phase 7 续：VMOperationQueue** | `vmOperations.hpp` `vm_operations.cpp` | VM_Operation 分发机制 | 3h |
| Day 4 | **Phase 8：Java 类初始化** | `thread.cpp:4130` `initialize_java_lang_classes()` | java.lang.Class/String/Thread 初始化 | 4h |
| Day 5 | **Phase 9-10：CompilerThread + JVMCI** | `compileBroker.cpp:268` | 编译线程启动流程 | 3h |
| Day 6 | **Phase 11-12：Signal + 收尾** | `os_linux.cpp` `Threads::create_vm` 尾部 | 信号分发器 + VM 启动完成 | 3h |
| Day 7 | **create_vm 全流程串联文档** | 综合 | create_vm-Complete-All-Phases.md | 3h |

**里程碑**：create_vm 12 个 Phase 全部完成 ✅

---

### Week 2（02.22 - 02.28）：Safepoint 完整分析

**目标**：Safepoint 是 JVM 并发的基石，必须彻底搞懂。

| 天 | 任务 | 关键源码 | 产出 | 预计时长 |
|----|------|---------|------|---------|
| Day 8 | **Safepoint 整体架构回顾** | `safepointMechanism.hpp` `safepoint.cpp` | 架构总结文档 | 2h |
| Day 9 | **SafepointSynchronize::begin() 深入** | `safepoint.cpp:153-380` | begin 逐行分析 | 4h |
| Day 10 | **SafepointSynchronize::end()** | `safepoint.cpp:500-600` | end 逐行分析 | 3h |
| Day 11 | **线程在各状态如何响应 Safepoint** | `safepoint.cpp` + 各线程转换点 | 5 种 JavaThread 状态响应机制 | 4h |
| Day 12 | **Safepoint Cleanup 任务** | `safepoint.cpp:do_cleanup_tasks()` | cleanup 11 个子任务 | 3h |
| Day 13 | **Polling Page 机制 + 信号处理** | `safepointMechanism.cpp` `os_linux.cpp` | polling page 保护/取消保护 | 3h |
| Day 14 | **GDB 验证：完整 STW 生命周期** | GDB 脚本 | Safepoint-Complete.md + GDB 验证 | 4h |

**里程碑**：Safepoint 完整分析 ✅

---

### Week 3（03.01 - 03.07）：编译器系统（C1/C2）

**目标**：理解 JIT 编译管线，从解释执行到编译执行的完整链路。

| 天 | 任务 | 关键源码 | 产出 | 预计时长 |
|----|------|---------|------|---------|
| Day 15 | **编译触发：方法计数器 + 热点探测** | `methodData.cpp` `invocationCounter.cpp` `CompilationPolicy` | 热点探测文档 | 4h |
| Day 16 | **CompileBroker：编译请求分发** | `compileBroker.cpp:compile_method()` | 编译队列 + 分发机制 | 4h |
| Day 17 | **C1 编译管线** | `c1_Compiler.cpp` `c1_LIR*.cpp` `c1_HIR*.cpp` | C1 四阶段管线 | 4h |
| Day 18 | **C2 编译管线：Ideal Graph** | `compile.cpp` `node.hpp` `type.hpp` | C2 Ideal IR 构建 | 4h |
| Day 19 | **C2 优化：逃逸分析 + 标量替换 + 内联** | `escape.cpp` `callGenerator.cpp` `InlineTree` | 三大优化深入 | 4h |
| Day 20 | **OSR (On-Stack Replacement)** | `c1_Runtime1.cpp` `sharedRuntime.cpp` | OSR 触发与编译 | 3h |
| Day 21 | **Deoptimization 逆优化** | `deoptimization.cpp` `uncommonTrap` | 逆优化触发条件 + 栈帧重建 | 4h |

**里程碑**：C1/C2 编译系统完整分析 ✅

---

### Week 4（03.08 - 03.15）：Metaspace + 类加载深化

**目标**：Metaspace 是类加载的内存基础，两者联合分析。

| 天 | 任务 | 关键源码 | 产出 | 预计时长 |
|----|------|---------|------|---------|
| Day 22 | **Metaspace 整体架构** | `metaspace.cpp` `virtualSpaceList.cpp` | Metaspace 架构文档 | 4h |
| Day 23 | **ChunkManager + SpaceManager** | `chunkManager.cpp` `spaceManager.cpp` | 内存分配管理器 | 4h |
| Day 24 | **类卸载机制** | `classLoaderData.cpp` `~ClassLoaderData()` | 类卸载 + CLD 生命周期 | 3h |
| Day 25 | **SystemDictionary 深入** | `systemDictionary.cpp:resolve_instance_class_or_null()` | 类查找核心算法 | 4h |
| Day 26 | **ConstantPool 解析** | `constantPool.cpp:resolve_constant_at_impl()` | 常量池延迟解析机制 | 3h |
| Day 27 | **字节码验证器** | `verifier.cpp` `classFileParser.cpp:verify_legal_*` | 验证阶段源码 | 3h |
| Day 28 | **类加载 GDB 实战串联** | GDB 脚本 | 完整类加载链路验证 | 3h |

**里程碑**：Metaspace + 类加载完整分析 ✅

---

## 四、第 2 个月：SO 库 + 运行时深入（03.16 - 04.15）

### Week 5（03.16 - 03.22）：核心 SO 库（第一批）

**目标**：libjvm.so 内部机制 + libjli.so + libjsig.so 补全。

| 天 | 任务 | 关键源码路径 | 产出 | 预计时长 |
|----|------|-------------|------|---------|
| Day 29 | **libjli.so：JVM 启动器** | `src/java.base/share/native/libjli/java.c` | JVM 启动过程 + 参数解析 | 4h |
| Day 30 | **libjli.so 续：JVM 加载** | `libjli/java_md_solinux.c:LoadJavaVM()` | dlopen libjvm.so + 函数绑定 | 3h |
| Day 31 | **libjsig.so 补全：信号链完整分析** | `src/java.base/unix/native/libjsig/` | 信号链转发 + 用户信号保护 | 3h |
| Day 32 | **libverify.so：类验证** | `src/java.base/share/native/libverify/` | 字节码验证 native 实现 | 3h |
| Day 33 | **libinstrument.so：Java Agent** | `src/java.instrument/share/native/libinstrument/` | premain/agentmain 加载 + ClassFileTransformer | 4h |
| Day 34 | **libinstrument.so 续：Retransform** | `JPLISAgent.c` `InvocationAdapter.c` | retransformClasses 完整流程 | 4h |
| Day 35 | **libmanagement.so：JMX 实现** | `src/java.management/share/native/libmanagement/` | JMX MBean + 运行时数据获取 | 3h |

**里程碑**：Tier 1 + Tier 4 SO 库完成 ✅

---

### Week 6（03.23 - 03.29）：核心 SO 库（第二批）

**目标**：libjava.so + libnio.so + libnet.so + libzip.so。

| 天 | 任务 | 关键源码路径 | 产出 | 预计时长 |
|----|------|-------------|------|---------|
| Day 36 | **libjava.so：核心 Java 类 Native** | `src/java.base/unix/native/libjava/` | FileDescriptor/ProcessImpl/UnixFileSystem | 4h |
| Day 37 | **libjava.so 续：IO 实现** | `io_util_md.c` `FileOutputStream_md.c` | 文件 IO native 实现 | 3h |
| Day 38 | **libnio.so：NIO 核心** | `src/java.base/unix/native/libnio/ch/` | EPollPort/EPollArrayWrapper | 4h |
| Day 39 | **libnio.so 续：DirectByteBuffer** | `DirectByteBuffer.java` + native | DirectBuffer 分配 + Cleaner 回收 | 3h |
| Day 40 | **libnio.so 续：FileChannel 零拷贝** | `FileChannelImpl.c` `transferTo0` | sendfile/mmap 零拷贝实现 | 4h |
| Day 41 | **libnet.so：网络实现** | `src/java.base/unix/native/libnet/` | PlainSocketImpl/PlainDatagramSocketImpl | 4h |
| Day 42 | **libzip.so + libjimage.so** | `src/java.base/share/native/libzip/` | ZIP 文件读取 + jimage 模块镜像 | 3h |

**里程碑**：Tier 2 SO 库完成 ✅

---

### Week 7（03.30 - 04.05）：JMM + 并发机制

**目标**：Java 内存模型与 JVM 并发基础设施。

| 天 | 任务 | 关键源码 | 产出 | 预计时长 |
|----|------|---------|------|---------|
| Day 43 | **JMM：Happens-Before 在 JVM 中的实现** | `orderAccess_linux_x86.hpp` `atomic_linux_x86.hpp` | 内存屏障指令映射 | 4h |
| Day 44 | **volatile 在解释器/C1/C2 的实现** | `templateTable_x86.cpp` `c1_LIRAssembler_x86.cpp` | volatile 三层实现对比 | 4h |
| Day 45 | **synchronized 底层：ObjectMonitor 深入** | `objectMonitor.cpp:enter()` `exit()` `wait()` `notify()` | 重量级锁完整流程 | 4h |
| Day 46 | **偏向锁 + 轻量级锁** | `synchronizer.cpp:fast_enter()` `biasedLocking.cpp` | 锁升级完整链路 | 4h |
| Day 47 | **Thread.interrupt() 实现** | `os_linux.cpp:interrupt()` `Parker` | interrupt + park/unpark 机制 | 3h |
| Day 48 | **ThreadLocal 与 Thread 的 JVM 视角** | `JavaThread::_threadObj` + `Thread.java` | JVM 视角的 ThreadLocal 实现 | 3h |
| Day 49 | **JMM + 并发 GDB 综合验证** | GDB 脚本 | 内存屏障 + 锁升级 GDB 实验 | 3h |

**里程碑**：JMM + 并发机制完整 ✅

---

### Week 8（04.06 - 04.12）：Arthas 深化 + 运行时补全

**目标**：Arthas 剩余机制 + 运行时核心补全。

| 天 | 任务 | 关键源码 | 产出 | 预计时长 |
|----|------|---------|------|---------|
| Day 50 | **Arthas 网络通信：Netty HTTP/WebSocket** | `arthas/core/src/.../server/` | Arthas 通信架构 | 3h |
| Day 51 | **Arthas 会话管理 + 命令路由** | `ShellServerImpl` `JobControllerImpl` | 多会话 + 异步命令 | 3h |
| Day 52 | **Arthas classloader 命令深入** | `ClassLoaderCommand` + JVM ClassLoaderData | Arthas 如何遍历所有 ClassLoader | 3h |
| Day 53 | **Arthas vmtool + JVMTI 深入** | `VmToolCommand` + `vmtool.cpp` (native) | JVMTI 底层调用链 | 4h |
| Day 54 | **运行时补全：String 在 JVM 中的实现** | `StringTable` `java_lang_String` | String intern + 紧凑字符串 | 3h |
| Day 55 | **运行时补全：数组与 TypeArrayKlass** | `arrayKlass.cpp` `typeArrayKlass.cpp` | 数组对象在 JVM 中的表示 | 3h |
| Day 56 | **运行时补全：Native 方法调用框架** | `SharedRuntime::generate_native_wrapper()` | JNI 调用链路 | 4h |

**里程碑**：Arthas 完整 + 运行时核心补全 ✅

---

## 五、第 3 个月：综合实战 + 查漏补缺（04.16 - 05.15）

### Week 9（04.13 - 04.19）：跨模块联合调试

**目标**：把孤立知识串成线，通过完整场景贯穿多个模块。

| 天 | 任务 | 涉及模块 | 产出 | 预计时长 |
|----|------|---------|------|---------|
| Day 57 | **场景一：一个对象的完整生命周期** | 类加载→分配→GC→回收 | 对象生命周期全景文档 | 4h |
| Day 58 | **场景二：一次方法调用的完整路径** | 解释执行→编译→去优化 | 方法执行全景文档 | 4h |
| Day 59 | **场景三：一次 Young GC 的全栈视角** | Safepoint→RootScan→Evacuation→RSet | Young GC 全栈追踪 | 4h |
| Day 60 | **场景四：一次线程创建的 JVM+OS 视角** | Thread.start→JavaThread→OSThread→pthread | 线程创建全栈追踪 | 3h |
| Day 61 | **场景五：一次 NIO 网络请求全路径** | Java NIO→libnio→epoll→内核 | 网络请求全栈追踪 | 4h |
| Day 62 | **场景六：一次 Arthas 命令的完整链路** | Arthas attach→agent→JVMTI→字节码→结果 | Arthas 全链路追踪 | 4h |
| Day 63 | **场景七：AsyncProfiler CPU 采样全链路** | perf_event→信号→栈回溯→火焰图 | CPU 采样全栈追踪 | 3h |

**里程碑**：7 个跨模块实战场景完成 ✅

---

### Week 10（04.20 - 04.26）：性能诊断实战

**目标**：用 AsyncProfiler + Arthas + GDB 解决真实性能问题。

| 天 | 任务 | 工具组合 | 产出 | 预计时长 |
|----|------|---------|------|---------|
| Day 64 | **实战：CPU 密集型问题定位** | AsyncProfiler CPU + 火焰图 | CPU 诊断手册 | 3h |
| Day 65 | **实战：内存泄漏诊断** | Arthas heapdump + jmap + MAT | 内存泄漏诊断手册 | 4h |
| Day 66 | **实战：锁竞争诊断** | AsyncProfiler lock + Arthas thread | 锁竞争诊断手册 | 3h |
| Day 67 | **实战：GC 调优** | GC 日志分析 + G1 参数调优 | GC 调优手册 | 4h |
| Day 68 | **实战：类加载问题** | Arthas classloader + sc + jad | 类加载诊断手册 | 3h |
| Day 69 | **实战：线程问题（死锁/饥饿）** | jstack + Arthas thread + GDB | 线程诊断手册 | 3h |
| Day 70 | **实战：JNI/Native 内存泄漏** | NativeMemoryTracking + pmap | Native 内存诊断手册 | 3h |

**里程碑**：7 个实战诊断手册完成 ✅

---

### Week 11（04.27 - 05.03）：知识体系整理

**目标**：形成可面试、可讲解的完整知识框架。

| 天 | 任务 | 产出 | 预计时长 |
|----|------|------|---------|
| Day 71 | **JVM 启动流程知识图谱** | 一张图总结 create_vm 12 阶段 | 3h |
| Day 72 | **G1 GC 知识图谱** | 一张图总结 G1 全组件关系 | 3h |
| Day 73 | **编译器系统知识图谱** | 解释→C1→C2→OSR→Deopt 全链路图 | 3h |
| Day 74 | **类加载系统知识图谱** | 加载→链接→初始化 + ClassLoaderData | 3h |
| Day 75 | **SO 库全景知识图谱** | 13+ so 库交互关系图 | 3h |
| Day 76 | **性能工具知识图谱** | AsyncProfiler + Arthas + JMX + GDB | 3h |
| Day 77 | **面试题库整理：200+ 题** | 按领域分类的面试题 + 答案 | 4h |

**里程碑**：6 张知识图谱 + 200+ 面试题 ✅

---

### Week 12（05.04 - 05.15）：查漏补缺 + 模拟

**目标**：最终查漏补缺，确保每个领域达到"可讲解"水平。

| 天 | 任务 | 产出 | 预计时长 |
|----|------|------|---------|
| Day 78 | **自我检测：JVM 启动** | 闭卷回答 10 个核心问题 | 3h |
| Day 79 | **自我检测：G1 GC** | 闭卷回答 15 个核心问题 | 3h |
| Day 80 | **自我检测：编译器** | 闭卷回答 10 个核心问题 | 3h |
| Day 81 | **自我检测：类加载 + Metaspace** | 闭卷回答 10 个核心问题 | 3h |
| Day 82 | **自我检测：并发 + JMM** | 闭卷回答 10 个核心问题 | 3h |
| Day 83 | **自我检测：SO 库** | 闭卷回答 10 个核心问题 | 3h |
| Day 84 | **自我检测：性能工具** | 闭卷回答 10 个核心问题 | 3h |
| Day 85 | **查漏补缺 Day 1** | 根据自测薄弱点补充 | 4h |
| Day 86 | **查漏补缺 Day 2** | 根据自测薄弱点补充 | 4h |
| Day 87 | **查漏补缺 Day 3** | 根据自测薄弱点补充 | 4h |
| Day 88 | **模拟面试 Round 1** | JVM 基础 + GC 深入 | 3h |
| Day 89 | **模拟面试 Round 2** | 性能诊断 + 实战场景 | 3h |
| Day 90 | **最终总结 + 进度更新** | 完整进度报告 | 2h |

**里程碑**：全部完成，精通级别达成 ✅

---

## 六、详细检查清单

### 6.1 libjvm.so 内部模块（Hotspot 核心）

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  模块                    已完成文档   待补全                    优先级       │
├─────────────────────────────────────────────────────────────────────────────┤
│  JVM 启动流程                                                               │
│  ├── create_vm Phase 1-6  ✅          Phase 7-12 收尾          ⭐⭐⭐⭐⭐    │
│  ├── VMThread              ✅          深入 VMOperationQueue    ⭐⭐⭐⭐      │
│  └── Signal Dispatcher     ⬜          完整分析                 ⭐⭐⭐        │
│                                                                             │
│  GC 系统（G1）                                                               │
│  ├── Young GC              ✅ 27/27   已完成                   --           │
│  ├── Mixed GC              ✅          已完成                   --           │
│  ├── Full GC               ✅          已完成                   --           │
│  ├── Concurrent Mark       ✅          已完成                   --           │
│  └── RSet/CardTable        ✅          已完成                   --           │
│                                                                             │
│  类加载                                                                      │
│  ├── ClassFileParser       ✅          已完成                   --           │
│  ├── InstanceKlass         ✅          已完成                   --           │
│  ├── SystemDictionary      🔶          深入 resolve 算法        ⭐⭐⭐⭐      │
│  ├── ConstantPool 解析     ⬜          延迟解析机制             ⭐⭐⭐⭐      │
│  ├── 类卸载                ⬜          CLD 生命周期             ⭐⭐⭐        │
│  └── 字节码验证            ⬜          verifier.cpp             ⭐⭐          │
│                                                                             │
│  解释器                                                                      │
│  ├── TemplateInterpreter   ✅          已完成                   --           │
│  ├── 字节码模板            ✅          已完成                   --           │
│  ├── invoke 字节码         ✅          已完成                   --           │
│  └── invokedynamic         ✅          已完成                   --           │
│                                                                             │
│  编译器                                                                      │
│  ├── CompileBroker         🔶          深入编译分发             ⭐⭐⭐⭐⭐    │
│  ├── C1 编译管线           ⬜          HIR→LIR→机器码           ⭐⭐⭐⭐⭐    │
│  ├── C2 编译管线           ⬜          Ideal Graph→Matcher      ⭐⭐⭐⭐⭐    │
│  ├── 逃逸分析              🔶          深入标量替换             ⭐⭐⭐⭐      │
│  ├── OSR                   ⬜          触发与编译               ⭐⭐⭐⭐      │
│  └── Deoptimization        ⬜          逆优化机制               ⭐⭐⭐⭐⭐    │
│                                                                             │
│  运行时                                                                      │
│  ├── 对象头 / MarkWord     ✅          已完成                   --           │
│  ├── 对象分配              ✅          已完成                   --           │
│  ├── 锁优化                🔶          ObjectMonitor 深入       ⭐⭐⭐⭐      │
│  ├── 异常处理              ✅          已完成                   --           │
│  ├── 反射                  ✅          已完成                   --           │
│  ├── String/StringTable    🔶          intern 机制深入          ⭐⭐⭐        │
│  └── Native 调用框架       ⬜          JNI wrapper              ⭐⭐⭐⭐      │
│                                                                             │
│  并发基础                                                                    │
│  ├── Safepoint             🔶          end + cleanup 补全       ⭐⭐⭐⭐⭐    │
│  ├── JMM 内存屏障          🔶          三层实现对比             ⭐⭐⭐⭐      │
│  ├── ObjectMonitor         🔶          wait/notify 深入         ⭐⭐⭐⭐      │
│  ├── 偏向锁/轻量级锁      ⬜          锁升级完整链路           ⭐⭐⭐⭐      │
│  └── Parker/Unpark         ⬜          Thread.park 底层         ⭐⭐⭐        │
│                                                                             │
│  Metaspace                                                                   │
│  ├── 整体架构              🔶          深入分析                 ⭐⭐⭐⭐      │
│  ├── ChunkManager          ⬜          内存分配管理             ⭐⭐⭐⭐      │
│  └── 类卸载与回收          ⬜          GC 触发的 Metaspace 回收 ⭐⭐⭐        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 SO 动态库检查清单

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  SO 库              源码路径                    已完成   待补全   优先级     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Tier 1: 核心引擎                                                           │
│  ├── libjvm.so      src/hotspot/               ✅       持续      --       │
│  ├── libjsig.so     src/java.base/.../libjsig/ 🔶       信号链   ⭐⭐⭐⭐   │
│  └── libattach.so   src/java.base/.../libattach ✅       已完成    --       │
│                                                                             │
│  Tier 2: 基础服务                                                           │
│  ├── libjava.so     src/java.base/.../libjava/  🔶      IO实现   ⭐⭐⭐⭐   │
│  ├── libnio.so      src/java.base/.../libnio/   🔶      epoll    ⭐⭐⭐⭐⭐ │
│  ├── libnet.so      src/java.base/.../libnet/   🔶      socket   ⭐⭐⭐⭐   │
│  └── libzip.so      src/java.base/.../libzip/   ⬜      ZIP读取  ⭐⭐⭐     │
│                                                                             │
│  Tier 3: 管理与安全                                                         │
│  ├── libmanagement.so  src/java.management/...  ⬜      JMX实现  ⭐⭐⭐     │
│  ├── libj2pcsc.so      src/java.smartcardio/... ⬜      智能卡   ⭐         │
│  └── libj2gss.so       src/java.security.jgss/  ⬜      安全认证 ⭐         │
│                                                                             │
│  Tier 4: 启动与工具                                                         │
│  ├── libjli.so         src/java.base/.../libjli/ ⬜     JVM启动  ⭐⭐⭐⭐⭐ │
│  ├── libverify.so      src/java.base/.../verify/  ⬜    类验证   ⭐⭐⭐     │
│  ├── libinstrument.so  src/java.instrument/...    ⬜    Agent    ⭐⭐⭐⭐⭐ │
│  ├── libsaproc.so      src/jdk.hotspot.agent/...  🔶    SA       ⭐⭐⭐     │
│  └── libjimage.so      src/java.base/.../jimage/   ⬜   模块镜像 ⭐⭐       │
│                                                                             │
│  优先级排序（必须掌握）：                                                    │
│  1. libjli.so        → JVM 怎么启动的                                       │
│  2. libinstrument.so → Java Agent 怎么工作                                  │
│  3. libnio.so        → NIO/epoll 底层                                       │
│  4. libjava.so       → 核心 Java 类 native                                  │
│  5. libnet.so        → 网络底层                                              │
│  6. libjsig.so       → 信号链（AsyncProfiler 相关）                          │
│  7. libmanagement.so → JMX/诊断                                             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.3 AsyncProfiler 检查清单

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  模块                      已完成   待补全                    优先级        │
├─────────────────────────────────────────────────────────────────────────────┤
│  Agent 加载                ✅       已完成                    --            │
│  VMStructs 偏移推断        ✅       已完成                    --            │
│  CPU 采样 (PerfEvents)     ✅       已完成                    --            │
│  栈回溯 (StackWalker)      ✅       已完成                    --            │
│  AllocTracer               ✅       已完成                    --            │
│  LockTracer                ✅       已完成                    --            │
│  WallClock                 ✅       已完成                    --            │
│  CallTraceStorage          ✅       已完成                    --            │
│  recordSample              ✅       已完成                    --            │
│  FlameGraph 输出           ✅       已完成                    --            │
│  多格式输出                ✅       已完成                    --            │
│  JFR 输出                  ✅       已完成                    --            │
│  实战案例                  ✅       已完成                    --            │
│  AsyncGetCallTrace         ✅       已完成                    --            │
│                                                                             │
│  ⭐ 待补全：                                                                │
│  ├── ctimer 事件源         ⬜       itimer/cputimer           ⭐⭐⭐         │
│  ├── 符号解析 (Symbols)    ⬜       ELF解析/DWARF             ⭐⭐⭐         │
│  └── 跨模块实战联调        ⬜       Week 9-10 完成            ⭐⭐⭐⭐       │
│                                                                             │
│  状态：95% 完成，剩余在第 3 个月实战中补全                                   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.4 Arthas 检查清单

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  模块                      已完成   待补全                    优先级        │
├─────────────────────────────────────────────────────────────────────────────┤
│  启动与 Attach             ✅       已完成                    --            │
│  Agent Bootstrap           ✅       已完成                    --            │
│  Arthas Bootstrap          ✅       已完成                    --            │
│  ClassLoader               ✅       已完成                    --            │
│  Spy 机制                  ✅       已完成                    --            │
│  字节码增强引擎            ✅       已完成                    --            │
│  OGNL 表达式引擎           ✅       已完成                    --            │
│  watch/trace/monitor/stack ✅       已完成                    --            │
│  Time Tunnel               ✅       已完成                    --            │
│  jad/redefine/retransform  ✅       已完成                    --            │
│  系统诊断命令              ✅       已完成                    --            │
│  vmtool + JVMTI            ✅       已完成                    --            │
│  profiler 命令             ✅       已完成                    --            │
│  Memory Compiler           ✅       已完成                    --            │
│  Spring Boot Starter       ✅       已完成                    --            │
│                                                                             │
│  ⭐ 待补全：                                                                │
│  ├── 网络通信架构 (Netty)  ⬜       HTTP/WebSocket/Session    ⭐⭐⭐         │
│  ├── 会话管理              ⬜       多 Session + Job 控制     ⭐⭐⭐         │
│  ├── JVMTI 深度联调        ⬜       vmtool native 层         ⭐⭐⭐⭐       │
│  └── classloader 深度联调  ⬜       与 JVM CLD 联合          ⭐⭐⭐         │
│                                                                             │
│  状态：70% 完成，Week 8 补全剩余                                            │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 七、每日执行规范

### 7.1 每日工作模板

```
1. 开始前（5 min）
   - 回顾昨天进度
   - 确认今日目标
   
2. 源码阅读（60-90 min）
   - Read-TopDown/BottomUp 找到核心代码
   - Read-Layered 剥离复杂代码
   - 标记关键函数和数据结构
   
3. 深入分析（60-90 min）
   - 逐行分析核心函数
   - JVM-Object-Layout 分析数据结构
   - 画 Mermaid 图

4. GDB 验证（30-60 min）
   - 编写 GDB 脚本
   - 运行验证
   - 记录数据

5. 文档输出（30 min）
   - 写入 new-jvm-md/<模块>/
   - 更新进度文件
```

### 7.2 质量标准

每篇文档必须包含：
- [ ] Mermaid 流程图（至少 1 个）
- [ ] 核心源码引用（标注文件和行号）
- [ ] GDB 验证数据（至少 1 个实验）
- [ ] 面试级 Q&A（至少 3 个）
- [ ] 相关 JVM 参数说明

---

## 八、最终目标定义

### "精通"的定义标准

| 维度 | 标准 | 验证方式 |
|------|------|---------|
| **源码理解** | 能画出任意模块的核心调用链 | 闭卷画图 |
| **数据结构** | 能描述关键对象的内存布局和字段含义 | GDB 验证 |
| **调试能力** | 能用 GDB 设断点追踪任意 JVM 流程 | 现场演示 |
| **工具实战** | 能用 AsyncProfiler/Arthas 定位真实问题 | 案例复盘 |
| **面试输出** | 200+ 面试题每题能深入展开讲 5 分钟 | 模拟问答 |
| **全栈贯通** | 能从 Java 代码追踪到 native/syscall | 端到端追踪 |

### 预期产出统计

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         三个月产出预估                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  新增文档：~80 篇（总计 180+ 篇）                                           │
│  新增字数：~800,000 字（总计 2,300,000+ 字）                                │
│  新增 GDB 脚本：~30 个（总计 60+ 个）                                       │
│  新增面试题：~100 题（总计 300+ 题）                                         │
│  知识图谱：6 张                                                              │
│  实战诊断手册：7 份                                                          │
│  跨模块全链路文档：7 份                                                      │
│                                                                             │
│  覆盖率：                                                                    │
│  ├── libjvm.so (HotSpot)   → 95%                                           │
│  ├── AsyncProfiler          → 98%                                           │
│  ├── Arthas                 → 90%                                           │
│  ├── SO 动态库 (核心 7 个)  → 85%                                           │
│  └── 综合实战能力           → 90%                                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 九、风险与应对

| 风险 | 应对策略 |
|------|---------|
| 某模块比预想复杂，超时 | 先覆盖核心 80%，细节放 Week 12 补 |
| 编译器部分源码太难 | 先理解 C1（较简单），C2 只理解关键优化 |
| GDB 验证遇到困难 | 降级为 `-Xlog` 日志验证 + strace |
| 实战场景不够真实 | 用 demo 程序模拟常见问题模式 |
| 疲劳/倦怠 | 穿插不同领域，避免连续啃同一块 |

---

*制定日期：2026-02-15*  
*第一次检查点：03.01（第 2 周结束）*  
*中期检查点：03.31（第 1 个月结束）*  
*最终检查点：05.15（三个月结束）*
