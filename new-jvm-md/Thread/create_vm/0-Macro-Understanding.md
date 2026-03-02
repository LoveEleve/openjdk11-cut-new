# Threads::create_vm() 完整深度分析

> 源码：`src/hotspot/share/runtime/thread.cpp:3876-4307`（431 行）
> 环境：`-Xms8g -Xmx8g -XX:+UseG1GC`，G1 Region = 4MB
> 原则：**每个调用都说清楚：做了什么、创建了什么对象、重要不重要、为什么需要它**

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文是对 **Threads::create_vm() 完整深度分析** 的深度源码分析：从数据结构到算法流程，逐层剖析其实现原理，并通过 GDB 验证关键结论。

### 0.2 为什么需要？

深入理解 JVM 内部实现，不仅能帮助排查生产问题，更能建立对 JVM 行为的精确预测能力——知道『为什么』比知道『是什么』更重要。

### 0.3 怎么解决？

采用「数据结构 → 算法流程 → GDB 验证」三步法：先完整分析所有涉及的数据结构（字段含义/sizeof/生命周期），再分析算法流程（每步有 why），最后用 GDB 实际验证关键结论。

### 0.4 为什么这样设计？

JVM 的每个设计决策都有其历史背景和性能考量。本文在分析每个关键设计时，都会解释「为什么这样而不是那样」，帮助读者建立设计直觉。

---


## 调用链入口

```
main()  →  JLI_Launch()  →  JVMInit()  →  ContinueInNewThread()
  →  pthread_create(ThreadJavaMain)     ← 关键：创建新 OS 线程
    →  JavaMain()  →  InitializeJVM()
      →  JNI_CreateJavaVM()             (jni.cpp:4108)
        →  JNI_CreateJavaVM_inner()     (jni.cpp:3949)
          →  Threads::create_vm()       ← 本文分析对象
```

**注意**：`create_vm()` 不在进程主线程中执行。启动器通过 `pthread_create()` 创建了新线程来执行它。**为什么？**因为进程初始线程的栈大小继承自 OS（默认 8MB），无法修改；通过 `pthread_create` + `pthread_attr_setstacksize` 可以精确控制栈大小（响应 `-Xss`）。

在 `JNI_CreateJavaVM_inner()` 中还有一个原子保护：
```cpp
if (Atomic::xchg(1, &vm_created) == 1) {
    return JNI_EEXIST;  // 一个进程只能创建一个 JVM
}
```
HotSpot 用了大量全局变量（全局堆、全局锁表、全局线程列表），从设计上不支持多 JVM 实例。

---

## Phase 1：早期初始化（L3876-3898）

### 1.1 `VM_Version::early_initialize()`（L3879）

**做了什么**：什么都没做。

```cpp
// abstract_vm_version.hpp:96
static void early_initialize() { }
```

这是一个**钩子函数**，留给需要在极早期检测 CPU 特性的平台用。当前 x86_64 没有覆盖它。

| 重要性 | 分类 |
|--------|------|
| ⭐ 不重要 | 占位符，当前为空实现 |

### 1.2 JNI 版本检查（L3882）

```cpp
if (!is_supported_jni_version(args->version)) return JNI_EVERSION;
```

检查调用者传入的 JNI 版本号是否在支持范围内（JNI_VERSION_1_1 ~ JNI_VERSION_10）。不通过就直接返回错误。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐ 一般 | 防御性检查，一行代码 |

### 1.3 `ThreadLocalStorage::init()`（L3886）⭐⭐⭐⭐⭐

**做了什么**：创建一个 pthread key，这是 `Thread::current()` 的基础。

```cpp
// threadLocalStorage_posix.cpp:51-58
static pthread_key_t _thread_key;
static bool _initialized = false;

extern "C" void restore_thread_pointer(void* p) {
  ThreadLocalStorage::set_thread((Thread*) p);
}

void ThreadLocalStorage::init() {
  assert(!_initialized, "initializing TLS more than once!");
  int rslt = pthread_key_create(&_thread_key, restore_thread_pointer);
  assert_status(rslt == 0, rslt, "pthread_key_create");
  _initialized = true;
}
```

**创建了什么**：一个 `pthread_key_t`（操作系统级别的线程局部存储键）。

**后续怎么用**：
- `pthread_setspecific(_thread_key, this)` → 把 JavaThread 指针存进 TLS
- `pthread_getspecific(_thread_key)` → 取出当前线程的 JavaThread 指针
- 这就是 `Thread::current()` 的底层实现

**为什么需要它**：JVM 几乎所有操作都需要知道"当前线程是谁"——GC 根扫描、异常处理、锁操作、JNI 调用，无一例外。没有 TLS，后续一切都无法进行。

**析构回调 `restore_thread_pointer` 的作用**：当某些 JNI 库调用 `pthread_key_create` 并注册析构函数时，可能意外清空 TLS 中的线程指针。这个回调负责恢复它。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐⭐⭐⭐ 最关键 | 整个 JVM 线程体系的基石 |

### 1.4 `ostream_init()`（L3890）

**做了什么**：创建全局输出流 `tty`。

```cpp
// ostream.cpp:918-930
void ostream_init() {
  if (defaultStream::instance == NULL) {
    defaultStream::instance = new(ResourceObj::C_HEAP, mtInternal) defaultStream();
    tty = defaultStream::instance;
    tty->time_stamp().update_to(1);
  }
}
```

**创建了什么**：一个 `defaultStream` 对象，赋给全局变量 `tty`。

**为什么需要它**：`tty` 是 JVM 的标准输出。后续所有 `tty->print_cr(...)` 调用（日志、错误信息、GC 日志）都依赖它。如果 `tty` 是 NULL，后面任何错误都无法输出。

**`tty->time_stamp().update_to(1)` 的作用**：将 GC 日志的时间基准设为 JVM 启动时刻（time=0），而不是第一次打印日志时。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐⭐ 重要 | 日志基础设施 |

### 1.5 `Arguments::process_sun_java_launcher_properties()`（L3894）

扫描 `args` 中是否有 `sun.java.launcher` 和 `sun.java.launcher.pid` 属性。如果有，设置到内部变量。

| 重要性 | 分类 |
|--------|------|
| ⭐ 不重要 | 启动器元数据，不影响运行 |

### 1.6 `os::init()`（L3898）⭐⭐⭐⭐

**做了什么**：Linux 操作系统级别的基础信息采集。

```cpp
// os_linux.cpp:5770-5817
void os::init(void) {
    clock_tics_per_sec = sysconf(_SC_CLK_TCK);   // 时钟滴答频率（通常100）
    init_random(1234567);                          // 随机种子
    Linux::set_page_size(sysconf(_SC_PAGESIZE));   // 内存页大小（4096）
    init_page_sizes((size_t) Linux::page_size());  // 注册页大小
    Linux::initialize_system_info();               // CPU 数量、物理内存大小
    Linux::initialize_os_info();                   // 内核版本

    // 动态获取 glibc mallinfo 函数指针（用于内存诊断）
    Linux::_mallinfo = dlsym(RTLD_DEFAULT, "mallinfo");
    Linux::_mallinfo2 = dlsym(RTLD_DEFAULT, "mallinfo2");

    // CPU steal ticks（虚拟化环境中被宿主机偷走的 CPU 时间）
    os::Linux::get_tick_information(&pticks, -1);

    Linux::_main_thread = pthread_self();   // 记录主线程 ID
    Linux::clock_init();                     // 高精度时钟初始化
    initial_time_count = javaTimeNanos();    // 记录启动时间

    // 动态获取 pthread_setname_np（用于给线程设名字）
    Linux::_pthread_setname_np = dlsym(RTLD_DEFAULT, "pthread_setname_np");

    check_pax();        // PaX 安全检查
    os::Posix::init();  // POSIX 通用初始化
}
```

**创建了什么**：没有创建对象，但初始化了大量全局变量：
- `Linux::_page_size` = 4096（后续 mmap、mprotect 都依赖它）
- `Linux::_physical_memory`（物理内存总量）
- `Linux::_processor_count`（CPU 核数）
- `initial_time_count`（纳秒级启动时间基准）

**为什么是第一个 OS 初始化**：因为它只获取不依赖参数的基础信息（页大小、CPU 数、物理内存）。参数解析 `Arguments::parse()` 内部会调用 `os::init_container_support()`（Docker 容器信息），而容器感知需要这些基础信息已就绪。

**`check_pax()` 是什么**：PaX 是 Linux 安全补丁，会禁止 JIT 生成可执行内存页。JVM 需要检测是否存在 PaX 限制，如果有，后续 mmap 需要特殊处理。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐⭐⭐ 非常重要 | 页大小、CPU 数、物理内存——后续所有内存操作的基础 |

### Phase 1 小结

```
Phase 1 创建的对象/状态：
├─ pthread_key_t _thread_key      → Thread::current() 的基础
├─ defaultStream* tty             → JVM 全局输出流
├─ Linux::_page_size = 4096       → 内存页大小
├─ Linux::_physical_memory        → 物理内存总量
├─ Linux::_processor_count        → CPU 核数
└─ initial_time_count             → 启动时间基准（纳秒）
```

**Phase 1 的设计哲学**：让 JVM 能"看见"和"说话"——看见硬件环境，说出错误信息。

---

## Phase 2：参数解析与自动调优（L3900-3946）

### 2.1 `Arguments::init_system_properties()`（L3909）

**做了什么**：创建 JVM 系统属性链表并填入初始值。

```cpp
// arguments.cpp:387-434
void Arguments::init_system_properties() {
  _system_boot_class_path = new PathString(NULL);

  // 只读属性（JVM 规范相关）
  PropertyList_add(&_system_properties,
    new SystemProperty("java.vm.specification.name",
                       "Java Virtual Machine Specification", false));
  PropertyList_add(&_system_properties,
    new SystemProperty("java.vm.version", VM_Version::vm_release(), false));
  PropertyList_add(&_system_properties,
    new SystemProperty("java.vm.name", VM_Version::vm_name(), false));

  // 可写属性（后续会被参数覆盖）
  _java_home      = new SystemProperty("java.home", NULL, true);
  _java_class_path = new SystemProperty("java.class.path", "", true);
  _java_library_path = new SystemProperty("java.library.path", NULL, true);

  // ... 注册到链表 ...
  os::init_system_properties_values();  // 由 OS 层填充实际值
}
```

**创建了什么**：10+ 个 `SystemProperty` 对象组成的链表，即 Java 层 `System.getProperty()` 读取的源头。

**关键属性**：
- `java.home`：JDK 安装路径
- `java.class.path`：用户 classpath（`-cp` 参数的目标）
- `java.library.path`：native 库搜索路径
- `sun.boot.library.path`：JDK 自带 native 库路径

| 重要性 | 分类 |
|--------|------|
| ⭐⭐⭐ 重要 | Java 系统属性的底层实现 |

### 2.2 `JDK_Version_init()` + `LogConfiguration::initialize()`（L3912-3918）

`JDK_Version_init()`：解析 JDK 版本号（major=11, minor=0 等），后续参数解析中某些行为依赖 JDK 版本。

`LogConfiguration::initialize()`：初始化统一日志框架（JEP 158, `-Xlog` 参数的基础），记录 JVM 启动时间。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐ 一般 | 辅助功能 |

### 2.3 `Arguments::parse(args)`（L3923）⭐⭐⭐⭐⭐

**做了什么**：解析用户传入的所有 JVM 启动参数。

这是一个 2000+ 行的巨型函数，核心逻辑是遍历 `args->options` 数组，对每个参数进行模式匹配：
- `-Xms8g` → 设置 `FLAG_SET_CMDLINE(size_t, InitialHeapSize, 8*G)`
- `-Xmx8g` → 设置 `FLAG_SET_CMDLINE(size_t, MaxHeapSize, 8*G)`
- `-XX:+UseG1GC` → 设置 `FLAG_SET_CMDLINE(bool, UseG1GC, true)`
- `-Xint` → 设置解释执行模式（禁用 JIT）
- `-cp path` → 设置 `java.class.path`
- `-D key=value` → 添加系统属性

**参数解析还做了一件重要的事**：`os::init_container_support()`——检测 Docker/cgroup 环境，读取容器的 CPU 和内存限制。在容器中，`os::physical_memory()` 返回的不是宿主机物理内存，而是容器的内存限制。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐⭐⭐⭐ 最关键 | 所有 JVM 行为的起点 |

### 2.4 `os::init_before_ergo()`（L3926）⭐⭐⭐⭐

**做了什么**：在 Ergonomics（自动调优）之前，获取影响调优决策的 OS 级信息。

```cpp
// os.cpp:449-474
void os::init_before_ergo() {
  // 1. 活跃 CPU 核心数（区分在线 vs 可用）
  initialize_initial_active_processor_count();

  // 2. 大页支持检测（Large Page 减少 TLB miss）
  large_page_init();

  // 3. 栈保护区域大小设置
  JavaThread::set_stack_red_zone_size(
    align_up(StackRedPages * 4 * K, vm_page_size()));     // Red Zone: 不可恢复溢出区 (~4KB)
  JavaThread::set_stack_yellow_zone_size(
    align_up(StackYellowPages * 4 * K, vm_page_size()));  // Yellow Zone: 抛 StackOverflowError (~8KB)
  JavaThread::set_stack_reserved_zone_size(
    align_up(StackReservedPages * 4 * K, vm_page_size())); // Reserved Zone (~4KB)
  JavaThread::set_stack_shadow_zone_size(
    align_up(StackShadowPages * 4 * K, vm_page_size()));  // Shadow Zone: 提前检测 (~80KB)
}
```

**创建了什么**：

| 全局变量 | 值 | 用途 |
|---------|-----|------|
| `_initial_active_processor_count` | 如 8 | 决定 GC 并行线程数 |
| `_large_page_size` | 2MB 或 0 | 大页支持（我们环境未开启，为 0） |
| `_stack_red_zone_size` | ~4KB | 栈溢出不可恢复区域 |
| `_stack_yellow_zone_size` | ~8KB | 栈溢出抛异常区域 |
| `_stack_shadow_zone_size` | ~80KB | 栈溢出提前检测 |

**四种栈保护区域是什么**？

```
线程栈布局（向低地址增长）：
┌──────────────────────┐ 高地址（栈基地址 stack_base）
│     正常栈帧          │
│     ...              │
├──────────────────────┤
│  Shadow Zone (~80KB)  │ ← JVM 用它检测"快要溢出了"
├──────────────────────┤
│  Reserved Zone (~4KB) │ ← 给关键代码（如锁释放）预留的空间
├──────────────────────┤
│  Yellow Zone (~8KB)   │ ← 触发 StackOverflowError，可恢复
├──────────────────────┤
│  Red Zone (~4KB)      │ ← 触发后 JVM 直接崩溃，不可恢复
└──────────────────────┘ 低地址
```

**为什么分四层**：如果只有一个保护页，栈溢出后连异常对象都没法创建（创建异常对象本身需要栈空间）。Yellow Zone 保证能抛出 StackOverflowError；Red Zone 是最后防线，防止栈溢出破坏其他内存。Shadow Zone 让 JVM 在溢出前就检测到风险。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐⭐⭐ 非常重要 | CPU 核数决定 GC 线程数；栈保护区防止 StackOverflow 导致进程崩溃 |

### 2.5 `Arguments::apply_ergo()`（L3928）⭐⭐⭐⭐⭐

**做了什么**：根据硬件环境和用户参数，自动做出一系列优化决策。

```cpp
// arguments.cpp:4034-4145
jint Arguments::apply_ergo() {
  // 1. 选择 GC、设置压缩指针
  jint result = set_ergonomics_flags();
  // 2. 自动计算堆大小（如果用户没指定）
  set_heap_size();
  // 3. GC 特定参数初始化（G1Arguments::initialize()）
  GCConfig::arguments()->initialize();
  // 4. CDS 共享空间
  set_shared_spaces_flags();
  // 5. 元空间参数对齐
  Metaspace::ergo_initialize();
  // 6. JIT 编译器配置
  CompilerConfig::ergo_initialize();
  // 7. 字节码重写标志
  set_bytecode_flags();
  // 8. 激进优化
  set_aggressive_opts_flags();
  // 9. 偏向锁决策
  ...
}
```

**`set_ergonomics_flags()` 内部做了什么**：

| 决策 | 在我们环境下的结果 | 原因 |
|------|-------------------|------|
| 选择 GC | G1GC | 用户指定了 `-XX:+UseG1GC` |
| UseCompressedOops | true | 堆 8GB < 32GB，可以用 4 字节引用代替 8 字节 |
| UseCompressedClassPointers | true | 跟随 CompressedOops |
| ObjectAlignmentInBytes | 8 | 对象对齐 8 字节 |

**`set_heap_size()` 的逻辑**：我们显式指定了 `-Xms8g -Xmx8g`，所以这个函数不会修改堆大小。但如果**没有**指定：
- 默认 `MaxHeapSize` = min(物理内存 / 4, 约 32GB)
- 默认 `InitialHeapSize` = min(物理内存 / 64, MaxHeapSize)

**`GCConfig::arguments()->initialize()` 的作用**：多态调用 `G1Arguments::initialize()`，设置 G1 特有的参数：
- `G1HeapRegionSize` = 4MB（8GB / 2048 = 4MB，向上取整到 2 的幂）
- `ParallelGCThreads`、`ConcGCThreads` 根据 CPU 核数自动设置
- `MaxGCPauseMillis` 默认 200ms

**`CompilerConfig::ergo_initialize()` 的作用**：在我们 `-Xint` 环境下，会禁用 JIT 编译器。正常情况下会配置 C1/C2 编译线程数。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐⭐⭐⭐ 最关键 | GC 选择、堆大小、压缩指针、Region 大小——全在这里决定 |

### 2.6 参数校验（L3932-3946）

```cpp
JVMFlagRangeList::check_ranges()         // 检查所有参数是否在合法范围内
JVMFlagConstraintList::check_constraints() // 检查参数间的约束关系
JVMFlagWriteableList::mark_startup()       // 标记启动完成，部分参数锁定
```

如果 `PauseAtStartup` 为 true，调用 `os::pause()` 暂停等待调试器 attach。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐ 一般 | 防御性检查 |

### Phase 2 小结

```
Phase 2 做出的关键决策：
├─ GC = G1GC
├─ HeapSize = 8GB (Xms = Xmx)
├─ G1HeapRegionSize = 4MB
├─ UseCompressedOops = true (引用 4 字节)
├─ UseCompressedClassPointers = true
├─ _initial_active_processor_count = N (CPU核数)
├─ _large_page_size = 0 (未开启大页)
├─ stack_red/yellow/reserved/shadow_zone_size 已设置
└─ CompilationMode = 解释执行 (-Xint)
```

**Phase 2 的设计哲学**：根据"用户告诉我什么"和"硬件是什么样"，计算出所有后续操作的配置参数。

---

## Phase 3：OS 深度初始化 + Safepoint（L3948-3972）

### 3.1 `os::init_2()`（L3955）⭐⭐⭐⭐

**做了什么**：OS 模块的第二阶段初始化——信号、线程、NUMA。

```cpp
// os_linux.cpp:5831-5938
jint os::init_2(void) {
  os::Posix::init_2();                     // POSIX 通用
  Linux::fast_thread_clock_init();          // 快速线程时钟

  // ⭐ 初始化 suspend/resume 机制
  SR_initialize();                          // 注册 SIGUSR2 作为线程暂停信号

  // ⭐ 信号集初始化：哪些信号要阻塞，哪些不阻塞
  Linux::signal_sets_init();

  // ⭐ 安装信号处理器（SIGSEGV, SIGBUS, SIGFPE, SIGPIPE 等）
  Linux::install_signal_handlers();

  // Java Signal API 支持
  jdk_misc_signal_init();

  // 最小栈大小校验
  Posix::set_minimum_stack_sizes();

  // 捕获初始栈信息
  Linux::capture_initial_stack(...);

  // libc/libpthread 版本检测
  Linux::libpthread_init();
  Linux::sched_getcpu_init();

  // NUMA 初始化（我们环境不用 NUMA）
  if (UseNUMA) { Linux::libnuma_init(); ... }

  // ⭐ 提升文件描述符上限到 hard limit
  if (MaxFDLimit) {
    getrlimit(RLIMIT_NOFILE, &nbr_files);
    nbr_files.rlim_cur = nbr_files.rlim_max;
    setrlimit(RLIMIT_NOFILE, &nbr_files);
  }

  // 线程创建序列化锁
  Linux::set_createThread_lock(new Mutex(...));

  // 线程优先级策略
  prio_init();
}
```

**为什么 `os::init()` 和 `os::init_2()` 要分开**：
- `os::init()`：获取不依赖参数的基础信息（页大小、CPU 数、物理内存）
- `os::init_2()`：做**依赖参数解析结果**的初始化——比如 `-Xss` 决定最小栈大小，`UseNUMA` 决定是否初始化 NUMA

**`SR_initialize()` 做了什么**：注册 `SIGUSR2` 作为线程暂停信号。当 JVM 需要暂停某个线程（GC safepoint、profiler 采样、线程转储）时，向该线程发送 SIGUSR2，线程的信号处理函数中会执行暂停逻辑。async-profiler 也利用了这个机制。

**`Linux::install_signal_handlers()` 安装了哪些信号**：
- `SIGSEGV` → 用于 NullPointerException 检测、safepoint polling、栈溢出检测
- `SIGBUS` → 总线错误处理
- `SIGFPE` → ArithmeticException（整数除零）
- `SIGPIPE` → 忽略（防止 socket 写入导致进程退出）
- `SIGXFSZ` → 忽略（文件大小超限）

**为什么提升文件描述符上限**：JVM 需要大量 FD——每个 socket 连接、每个打开的文件、每个 mmap 映射。默认 soft limit 通常只有 1024，对服务器应用远远不够。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐⭐⭐ 非常重要 | 信号处理是 NullPointerException、StackOverflowError、GC safepoint 的基础 |

### 3.2 `SafepointMechanism::initialize()`（L3965）⭐⭐⭐⭐⭐

**做了什么**：分配 safepoint polling page。

```cpp
// safepointMechanism.cpp:42-89
void SafepointMechanism::default_initialize() {
  if (ThreadLocalHandshakes) {  // JDK 11 默认 true
    // 分配 2 个连续内存页
    char* polling_page = os::reserve_memory(2 * page_size);
    os::commit_memory_or_exit(polling_page, 2 * page_size, false, ...);

    char* bad_page  = polling_page;            // 第一页
    char* good_page = polling_page + page_size; // 第二页

    os::protect_memory(bad_page,  page_size, os::MEM_PROT_NONE);  // 不可访问
    os::protect_memory(good_page, page_size, os::MEM_PROT_READ);  // 可读

    os::set_polling_page((address)(bad_page));

    _poll_armed_value    = bad_page;   // armed = 读 bad_page → SIGSEGV
    _poll_disarmed_value = good_page;  // disarmed = 读 good_page → 正常
  }
}
```

**创建了什么**：两个连续的 4KB 内存页（通过 mmap 分配）。

**Safepoint 机制原理**（JDK 11 Thread-Local Handshake）：
1. 每个 Java 线程有一个 `_polling_page` 指针
2. 正常情况下指向 `good_page`（可读），线程读取时什么都不会发生
3. 需要 safepoint 时，VMThread 把目标线程的 `_polling_page` 指向 `bad_page`（不可访问）
4. 线程下次读取 polling page 时触发 `SIGSEGV`
5. JVM 的 SIGSEGV 处理函数捕获这个信号，让线程进入 safepoint

**为什么是两个页**：Armed/disarmed 通过指向不同页实现，比修改页保护属性（mprotect）更快。mprotect 是系统调用，有 TLB flush 开销；而修改指针只是一次内存写。

**与 JDK 8 的区别**：JDK 8 只有一个全局 polling page，进入 safepoint 时对所有线程同时生效（全局 mprotect）。JDK 11 改为 thread-local，可以只让特定线程停下来（handshake），更精细。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐⭐⭐⭐ 最关键 | GC 依赖 safepoint，没有它就无法做 GC |

### 3.3 `ostream_init_log()`（L3972）

```cpp
// ostream.cpp:932-949
void ostream_init_log() {
  // CDS: -XX:DumpLoadedClassList=<file> 选项
  if (DumpLoadedClassList != NULL) {
    classlist_file = new fileStream(list_name);
  }
  // 强制提前初始化日志文件（避免 crash 时延迟初始化不稳定）
  defaultStream::instance->has_log_file();
}
```

| 重要性 | 分类 |
|--------|------|
| ⭐⭐ 一般 | CDS 相关，可跳过 |

### Phase 3 小结

```
Phase 3 创建的对象/状态：
├─ SIGUSR2 信号处理器    → 线程暂停/恢复机制
├─ SIGSEGV 信号处理器    → NPE 检测、safepoint、栈溢出
├─ SIGFPE 信号处理器     → ArithmeticException
├─ polling page (2 × 4KB) → safepoint 的核心
│   ├─ bad_page  (PROT_NONE) → armed 状态
│   └─ good_page (PROT_READ) → disarmed 状态
├─ 文件描述符上限已提升
└─ createThread_lock      → 线程创建序列化
```

---

## Phase 4：Agent 加载（L3977-3993）

```cpp
// -Xrun 转换为 -agentlib（向后兼容 JDK 5 之前的用法）
if (Arguments::init_libraries_at_startup()) {
    convert_vm_init_libraries_to_agents();
}
// 加载 -agentlib/-agentpath Agent
if (Arguments::init_agents_at_startup()) {
    create_vm_init_agents();
}
```

**做了什么**：如果用户指定了 `-agentlib:jdwp`（调试器）或 `-agentpath:/path/to/libasyncProfiler.so`，这里会 `dlopen` 加载对应的 .so 库，并调用其 `Agent_OnLoad()` 入口函数。

**为什么在堆创建之前加载**：某些 Agent（如 JDWP 调试器）需要在第一个 Java 类加载前注册 ClassFileLoadHook，以便对 java.lang.Object 等基础类进行字节码转换。如果太晚加载，就错过了。

**我们的环境**：标准配置没有 Agent，`Arguments::init_agents_at_startup()` 返回 false，这两个 if 块都跳过。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐ 一般（无 Agent 时跳过） | 工具/诊断基础设施 |

---

## Phase 5：轻量级全局初始化 — `vm_init_globals()`（L3996-4002）

```cpp
_thread_list = NULL;
_number_of_threads = 0;
_number_of_non_daemon_threads = 0;
vm_init_globals();
```

先初始化线程链表为空，然后调用 `vm_init_globals()`。

### 5.1 `check_ThreadShadow()`

检查 `ThreadShadow` 基类中 `_pending_exception` 字段的偏移是否正确。纯断言，release 版无效。

| 重要性 | ⭐ 不重要 |

### 5.2 `basic_types_init()`（⭐⭐⭐）

**做了什么**：验证基础类型大小，并根据 UseCompressedOops 设置堆引用大小。

```cpp
// globalDefinitions.cpp:53-177
void basic_types_init() {
  // 断言验证所有基本类型大小
  assert(1 == sizeof(jbyte),     "wrong size");
  assert(2 == sizeof(jchar),     "wrong size");
  assert(4 == sizeof(jint),      "wrong size");
  assert(8 == sizeof(jlong),     "wrong size");
  assert(4 == sizeof(jfloat),    "wrong size");
  assert(8 == sizeof(jdouble),   "wrong size");
  assert(8 == sizeof(intx),      "wrong size");  // 64位
  assert(8 == sizeof(jobject),   "wrong size");  // 64位

  // Java 线程优先级到 OS 优先级的映射
  os::java_to_os_priority[1..10] = JavaPriorityN_To_OSPriority;

  // ⭐ 关键：根据压缩指针设置堆 OOP 大小
  if (UseCompressedOops) {
    heapOopSize        = jintSize;      // 4 字节！
    LogBytesPerHeapOop = LogBytesPerInt; // log2(4) = 2
  } else {
    heapOopSize        = oopSize;       // 8 字节
    LogBytesPerHeapOop = LogBytesPerWord;
  }
  _type2aelembytes[T_OBJECT] = heapOopSize;
  _type2aelembytes[T_ARRAY]  = heapOopSize;
}
```

**创建了什么**：设置了全局变量 `heapOopSize`。

**为什么重要**：`heapOopSize` 决定了 Java 对象中每个引用字段占多少字节。压缩指针下 4 字节（比 8 字节省一半内存），这是一个**性能优化**——更小的引用意味着更少的内存占用、更好的 CPU 缓存命中率。

在我们 8GB 堆、UseCompressedOops=true 的环境下：`heapOopSize = 4`。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐⭐ 重要 | 压缩指针大小设置——影响所有 Java 对象的内存布局 |

### 5.3 `eventlog_init()`

初始化事件日志缓冲区，用于在 crash 时输出最近发生的事件（类似黑匣子）。

| 重要性 | ⭐⭐ 一般 | 诊断用 |

### 5.4 `mutex_init()`（⭐⭐⭐⭐⭐）

**做了什么**：创建 JVM 运行时所需的 **70+ 个全局锁**。

这是一个约 160 行的函数，通过 `def` 宏创建每个锁：

```cpp
// mutexLocker.cpp:194-352
#define def(var, type, pri, vm_block, safepoint_check_allowed) { \
  var = new type(Mutex::pri, #var, vm_block, safepoint_check_allowed); \
  _mutex_array[_num_mutex++] = var; \
}

void mutex_init() {
  def(tty_lock,           PaddedMutex, tty, true, Monitor::_safepoint_check_never);
  def(CGC_lock,           PaddedMonitor, special, true, ...);
  def(CodeCache_lock,     PaddedMutex, special, true, ...);
  def(Threads_lock,       PaddedMonitor, barrier, true, ...);
  def(Heap_lock,          PaddedMonitor, nonleaf+1, false, ...);
  def(Safepoint_lock,     PaddedMonitor, safepoint, true, ...);
  def(VMOperationQueue_lock, PaddedMonitor, nonleaf, true, ...);
  def(SystemDictionary_lock, PaddedMonitor, leaf, true, ...);
  def(SymbolTable_lock,   PaddedMutex, leaf+2, true, ...);
  def(MethodCompileQueue_lock, PaddedMonitor, nonleaf+4, true, ...);
  // ... 还有 60+ 个 ...
}
```

**为什么用 `PaddedMutex`/`PaddedMonitor`**：Padding 是为了防止 **false sharing**——如果两个锁对象碰巧在同一条 CPU cache line（64 字节）上，一个线程获取锁 A 会导致另一个线程的锁 B 被 cache invalidation，严重降低性能。`Padded` 版本在对象前后加填充，确保每个锁独占一条 cache line。这是**性能优化**。

**关键锁的作用**：

| 锁名 | 作用 | 谁在用 |
|-------|------|--------|
| `Heap_lock` | 保护堆内存分配 | GC、对象分配 |
| `Threads_lock` | 保护线程列表 | 线程创建/销毁 |
| `Safepoint_lock` | 协调 safepoint | VMThread |
| `VMOperationQueue_lock` | VM 操作队列 | VMThread |
| `SystemDictionary_lock` | 类字典（已加载的类） | 类加载 |
| `SymbolTable_lock` | 符号表（字符串常量池的底层） | 类加载、字符串 intern |
| `CodeCache_lock` | JIT 编译后的代码缓存 | 编译器 |
| `MethodCompileQueue_lock` | 编译任务队列 | 编译器线程 |
| `Compile_lock` | 编译过程保护 | C1/C2 编译器 |
| `tty_lock` | 保护日志输出 | 所有线程 |

**锁的优先级（pri）是什么**：HotSpot 用锁优先级来防止死锁——持有低优先级锁时不允许获取高优先级锁。优先级从低到高：`special < leaf < nonleaf < barrier < safepoint`。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐⭐⭐⭐ 最关键 | 没有锁就没有并发安全，后续所有操作都依赖这些锁 |

### 5.5 `chunkpool_init()`（⭐⭐⭐）

**做了什么**：创建 4 个内存块缓存池。

```cpp
// arena.cpp
static void initialize() {
  _large_pool  = new ChunkPool(32K - 40 + overhead);  // ~32KB
  _medium_pool = new ChunkPool(10K - 40 + overhead);  // ~10KB
  _small_pool  = new ChunkPool(1K  - 40 + overhead);  // ~1KB
  _tiny_pool   = new ChunkPool(256 - 40 + overhead);  // ~216B
}
```

每个 `ChunkPool` 内部是一个空闲块链表（LIFO），满了就返还 OS，空了就从 OS 申请。

**为什么需要它**：JVM 内部大量使用 Arena 分配模式——先从 ChunkPool 取一个合适大小的 Chunk，然后在 Chunk 内线性分配（bump pointer）。这比每次都 `malloc` 快得多，因为：
1. 线性分配只需要移动指针，O(1)
2. 整个 Chunk 一起释放，不需要逐个 free
3. 空闲块缓存避免频繁系统调用

Arena 用在哪里：`ResourceArea`（每个线程的临时分配区）、`HandleArea`（Handle 分配）、编译器临时数据等。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐⭐ 重要 | 内存分配性能优化，Arena 是 JVM 内部最常用的分配模式 |

### 5.6 `perfMemory_init()`（⭐⭐⭐）

**做了什么**：创建一块共享内存，用于暴露 JVM 内部性能数据给外部工具。

```cpp
// perfMemory.cpp:90-177
void PerfMemory::initialize() {
  size_t capacity = align_up(PerfDataMemorySize, os::vm_allocation_granularity());
  // 在 /tmp/hsperfdata_<user>/<pid> 创建 mmap 文件
  create_memory_region(capacity);

  _prologue = (PerfDataPrologue *)_start;
  _prologue->magic = 0xc0c0feca;  // 魔数
  _prologue->major_version = 2;
  _prologue->minor_version = 0;
  _prologue->accessible = 0;       // 初始不可访问
  // ...
}
```

**创建了什么**：
- 一个 **32KB** 的 mmap 共享内存区域
- 对应文件：`/tmp/hsperfdata_<username>/<pid>`
- 头部是 `PerfDataPrologue`（魔数 `0xc0c0feca`、版本号、字节序）

**谁在读这块内存**：`jstat`、`jps`、`jcmd` 等工具。它们不需要 attach 进程，直接 mmap 同一个文件就能读到实时数据——**零开销监控**。

**后续谁往里面写**：ObjectMonitor（锁统计）、GC（回收统计）、编译器（编译统计）、线程（线程计数）等。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐⭐ 重要 | jstat/jps 的数据源，监控基础设施 |

### 5.7 `SuspendibleThreadSet_init()`

初始化可暂停线程集合，用于 GC 协调并发线程。

| 重要性 | ⭐⭐ 一般 | GC 内部协调 |

### Phase 5 小结

```
Phase 5（vm_init_globals）创建的对象：
├─ heapOopSize = 4              → 压缩指针下引用占 4 字节
├─ 70+ 全局锁 (PaddedMutex/Monitor)
│   ├─ Heap_lock               → 堆分配保护
│   ├─ Threads_lock            → 线程列表保护
│   ├─ Safepoint_lock          → safepoint 协调
│   ├─ CodeCache_lock          → 代码缓存保护
│   └─ ... 60+ 其他 ...
├─ 4 个 ChunkPool
│   ├─ tiny_pool   (~216B)
│   ├─ small_pool  (~1KB)
│   ├─ medium_pool (~10KB)
│   └─ large_pool  (~32KB)
└─ PerfMemory 共享内存 (32KB mmap)
    └─ /tmp/hsperfdata_<user>/<pid>
```

**Phase 5 的设计哲学**：创建 JavaThread 之前，把它的"生存环境"准备好——锁（并发安全）、内存池（快速分配）、监控内存（外部可观测）。

---

## Phase 6：主线程创建（L4012-4065）

### 6.1 `new JavaThread()`（L4018）⭐⭐⭐⭐⭐

**做了什么**：在 C 堆上分配一个 `JavaThread` C++ 对象（约 928 字节），初始化所有字段为 NULL/0。

**注意：这不是创建线程！** OS 线程已经存在（`pthread_create` 在 `JavaMain` 之前就创建了）。这只是创建一个 C++ 对象来**描述**这个线程。

### 6.2 `set_thread_state(_thread_in_vm)`（L4019）

设置线程状态为"正在执行 VM 代码"。线程状态用于 safepoint 判断——`_thread_in_vm` 表示这个线程在执行 C++ 代码，GC 需要等它到达安全点。

### 6.3 `initialize_thread_current()`（L4020）⭐⭐⭐⭐⭐

**做了什么**：`pthread_setspecific(_thread_key, this)` — 把 JavaThread 指针存入 TLS。

**从这一刻起，`Thread::current()` 能返回正确的 JavaThread 对象了。** 在此之前，`Thread::current()` 返回 NULL。

### 6.4 `record_stack_base_and_size()`（L4022）

通过 `pthread_getattr_np()` 获取当前线程的栈基地址和栈大小，记录到 JavaThread 对象中。

### 6.5 `register_thread_stack_with_NMT()`（L4030）

将线程栈区域注册到 NMT（Native Memory Tracking）。NMT 是 JVM 的内存跟踪系统，通过 `jcmd <pid> VM.native_memory` 可以看到各部分的内存使用。

| 重要性 | ⭐⭐ 一般 | 诊断功能，默认关闭（需要 `-XX:NativeMemoryTracking=summary`） |

### 6.6 `set_active_handles(JNIHandleBlock::allocate_block())`（L4032）

**做了什么**：分配一个 `JNIHandleBlock`（32 个槽位的数组），作为当前线程的 JNI 局部引用存储。

**为什么需要**：JNI 代码中通过 `env->NewLocalRef()` 创建的 Java 对象引用存在这里。它防止 GC 回收正在被 native 代码使用的 Java 对象。

### 6.7 `set_as_starting_thread()`（L4040）⭐⭐⭐⭐

```cpp
bool Thread::set_as_starting_thread() {
    return os::create_main_thread((JavaThread*)this);
}
```

**做了什么**：创建 `OSThread` 对象并绑定到当前 OS 线程。`OSThread` 是 JavaThread 和操作系统线程之间的桥梁，保存 `pthread_id` 和线程状态。

### 6.8 `create_stack_guard_pages()`（L4051）

调用 `mprotect()` 在线程栈底部创建 Red/Yellow/Reserved Zone 保护页。

**为什么必须在 `set_as_starting_thread()` 之后**：源码注释说得很清楚——`create_main_thread()` 内部需要通过信号探测栈范围，如果 guard page 已经设置了，探测时会触发意外的 SIGSEGV。

### 6.9 `ObjectMonitor::Initialize()`（L4055）⭐⭐⭐

**做了什么**：创建 7 个性能计数器，注册到 PerfMemory 共享内存中。

```cpp
// objectMonitor.cpp:2246-2283
void ObjectMonitor::Initialize() {
  if (UsePerfData) {
    _sync_Inflations           = PerfDataManager::create_counter(...);  // 锁膨胀次数
    _sync_Deflations           = PerfDataManager::create_counter(...);  // 锁收缩次数
    _sync_ContendedLockAttempts = PerfDataManager::create_counter(...); // 锁竞争次数
    _sync_FutileWakeups        = PerfDataManager::create_counter(...);  // 无效唤醒次数
    _sync_Parks                = PerfDataManager::create_counter(...);  // 线程挂起次数
    _sync_Notifications        = PerfDataManager::create_counter(...);  // notify 次数
    _sync_MonExtant            = PerfDataManager::create_variable(...); // 当前存活 Monitor 数
  }
}
```

**可以通过命令查看**：`jcmd <pid> PerfCounter.print | grep sync`

| 重要性 | 分类 |
|--------|------|
| ⭐⭐⭐ 重要 | 锁性能监控数据源 |

### 6.10 `init_globals()`（L4060）⭐⭐⭐⭐⭐

这是 `create_vm()` 中最重量级的调用，内部包含约 30 个模块的初始化。已在 [4-Phase6-init_globals.md](./4-Phase6-init_globals.md) 中详细分析。

关键初始化（按顺序）：

| 调用 | 做了什么 | 重要性 |
|------|---------|--------|
| `bytecodes_init()` | 初始化 202 条字节码指令描述表 | ⭐⭐⭐ |
| `codeCache_init()` | 分配 JIT 代码缓存内存区域（240MB 默认） | ⭐⭐⭐⭐ |
| `stubRoutines_init1()` | 生成第一批汇编桩代码（memcpy、数组填充等） | ⭐⭐⭐⭐ |
| `universe_init()` | **创建 Java 堆 + 元空间 + 符号表 + 字符串表** | ⭐⭐⭐⭐⭐ |
| `interpreter_init()` | **生成字节码解释器（模板解释器）** | ⭐⭐⭐⭐⭐ |
| `templateTable_init()` | 初始化模板表（每条字节码对应的机器码模板） | ⭐⭐⭐⭐ |
| `SharedRuntime::generate_stubs()` | 生成方法调用/返回桩代码 | ⭐⭐⭐ |
| `javaClasses_init()` | 计算 Java 核心类字段偏移 | ⭐⭐⭐⭐ |
| `universe_post_init()` | 创建预分配异常对象（OOM 等） | ⭐⭐⭐⭐ |
| `stubRoutines_init2()` | 生成第二批汇编桩代码（异常处理等） | ⭐⭐⭐⭐ |

**为什么 `stubRoutines` 分两阶段**：`init1` 生成的是 `universe_init()` 需要的基础代码（内存操作），`init2` 生成的是依赖 `universe_post_init()` 已创建对象的高级代码（异常处理）。先有鸡还是先有蛋？HotSpot 的答案：**分两步走**。

### Phase 6 小结

```
Phase 6 创建的对象：
├─ JavaThread* main_thread     → 主线程 C++ 描述对象
├─ OSThread*                   → 主线程的 OS 绑定
├─ JNIHandleBlock*             → JNI 局部引用存储
├─ Guard Pages (mprotect)      → 栈溢出保护
├─ 7 个 ObjectMonitor 性能计数器
└─ init_globals() 创建的大量对象：
    ├─ Java 堆 (G1CollectedHeap) → 8GB mmap
    ├─ 元空间 (Metaspace)
    ├─ 符号表 (SymbolTable)
    ├─ 字符串表 (StringTable)
    ├─ 代码缓存 (CodeCache)
    ├─ 模板解释器
    └─ 汇编桩代码
```

---

## Phase 7-8：VMThread 创建（L4067-4104）

### 7.1 加入线程列表（L4074-4077）

```cpp
{
    MutexLocker mu(Threads_lock);
    Threads::add(main_thread);
}
```

以头插法将 main_thread 插入全局线程链表 `_thread_list`。同时通知 GC barrier set、ThreadService、ThreadsSMRSupport。

### 7.2 `VMThread::create()`（L4087）⭐⭐⭐⭐⭐

```cpp
// vmThread.cpp:242-275
void VMThread::create() {
  _vm_thread = new VMThread();
  _vm_queue = new VMOperationQueue();
  _terminate_lock = new Monitor(Mutex::safepoint, "VMThread::_terminate_lock", ...);
  if (UsePerfData) {
    _perf_accumulated_vm_operation_time = PerfDataManager::create_counter(...);
  }
}
```

**创建了什么**：
- `VMThread` 对象：JVM 中唯一一个专门执行 VM Operation 的线程
- `VMOperationQueue`：VM 操作队列，其他线程把请求放进去，VMThread 取出执行
- `_terminate_lock`：终止同步锁

### 7.3 启动 VMThread（L4090-4103）

```cpp
os::create_thread(vmthread, os::vm_thread);  // 创建真正的 OS 线程
os::start_thread(vmthread);                   // 启动
while (vmthread->active_handles() == NULL) {  // 等待就绪
    Notify_lock->wait();
}
```

**与主线程创建的区别**：主线程是"先有 OS 线程，后创建 JavaThread 绑定"；VMThread 是"先创建 VMThread 对象，再 `os::create_thread()` 创建新 OS 线程"。

**VMThread 的主循环做什么**：
1. 从 `_vm_queue` 取出一个 `VM_Operation`
2. 如果需要 safepoint，让所有 Java 线程停下来
3. 执行操作（GC、线程转储、偏向锁撤销等）
4. 恢复所有线程
5. 回到步骤 1

**为什么需要单独的 VMThread**：safepoint 需要一个"协调者"——等所有线程都停下来，然后执行操作。如果让发起方直接做，在等待其他线程停下来的过程中，发起方自己也被阻塞了，可能导致死锁。

| 重要性 | 分类 |
|--------|------|
| ⭐⭐⭐⭐⭐ 最关键 | GC 和所有需要 safepoint 的操作都依赖 VMThread |

---

## Phase 9：Java 类初始化（L4121-4139）

### 9.1 `initialize_java_lang_classes()`（L4130）⭐⭐⭐⭐⭐

```cpp
// thread.cpp:3812-3864
void Threads::initialize_java_lang_classes(JavaThread *main_thread, TRAPS) {
  // ⭐ 按严格顺序初始化核心类
  initialize_class(vmSymbols::java_lang_String(), CHECK);
  java_lang_String::set_compact_strings(CompactStrings);  // JDK 9+ 紧凑字符串

  initialize_class(vmSymbols::java_lang_System(), CHECK);
  initialize_class(vmSymbols::java_lang_Class(), CHECK);
  initialize_class(vmSymbols::java_lang_ThreadGroup(), CHECK);

  Handle thread_group = create_initial_thread_group(CHECK);  // 创建 "main" 线程组
  Universe::set_main_thread_group(thread_group());

  initialize_class(vmSymbols::java_lang_Thread(), CHECK);
  oop thread_object = create_initial_thread(thread_group, main_thread, CHECK);
  main_thread->set_threadObj(thread_object);  // C++ JavaThread ↔ Java Thread 对象关联

  initialize_class(vmSymbols::java_lang_Module(), CHECK);
  initialize_class(vmSymbols::java_lang_reflect_Method(), CHECK);
  initialize_class(vmSymbols::java_lang_ref_Finalizer(), CHECK);

  // ⭐ 调用 System.initPhase1()
  call_initPhase1(CHECK);

  // 预分配常见异常类
  initialize_class(vmSymbols::java_lang_OutOfMemoryError(), CHECK);
  initialize_class(vmSymbols::java_lang_NullPointerException(), CHECK);
  initialize_class(vmSymbols::java_lang_ClassCastException(), CHECK);
  initialize_class(vmSymbols::java_lang_ArrayStoreException(), CHECK);
  initialize_class(vmSymbols::java_lang_ArithmeticException(), CHECK);
  initialize_class(vmSymbols::java_lang_StackOverflowError(), CHECK);
  initialize_class(vmSymbols::java_lang_IllegalMonitorStateException(), CHECK);
  initialize_class(vmSymbols::java_lang_IllegalArgumentException(), CHECK);
}
```

**初始化顺序为什么不能打乱**：
- `String` 必须第一个——几乎所有类的 `<clinit>` 都用字符串常量
- `System` 依赖 `String`
- `Class` 依赖 `String` 和 `System`
- `ThreadGroup` 依赖 `Class`
- `Thread` 依赖 `ThreadGroup`（每个线程属于一个线程组）
- 然后才能 `create_initial_thread()`——把 C++ 层的 JavaThread 和 Java 层的 Thread 对象关联起来

**`call_initPhase1()` 做了什么**：调用 `java.lang.System.initPhase1()`（Java 方法），负责初始化系统属性、stdout/stderr/stdin、信号处理器、主线程组。这证明此时 JVM 已具备**执行 Java 代码**的能力。

**为什么预分配异常类**：OOM 发生时已经没有内存了，如果此时才去加载 OutOfMemoryError 类，可能因为内存不足而失败。提前加载，确保抛异常时类已就绪。

### 9.2 `set_init_completed()`（L4139）

```cpp
void set_init_completed() {
  assert(Universe::is_fully_initialized(), "Should have completed initialization");
  _init_completed = true;
}
```

设置全局标志。很多代码路径用 `is_init_completed()` 判断：初始化未完成时走简化路径（直接 abort），完成后走正常路径（创建异常对象、打印栈帧）。

---

## Phase 10：编译器与模块系统（L4144-4241）

### 10.1 `CompileBroker::compilation_init_phase1/2()`（L4196-4201）

初始化 JIT 编译器。**在我们 `-Xint` 环境下**，编译器不会真正启动，但框架会初始化。

正常环境（非 `-Xint`）下会创建 C1/C2 编译线程。

### 10.2 `call_initPhase2()`（L4212）⭐⭐⭐⭐

```cpp
// 调用 System.initPhase2() — 初始化模块系统
// 在此之前，只有 java.base 模块中的类可以加载
// 在此之后，可以从 -Xbootclasspath/a 等路径加载类
```

### 10.3 `call_initPhase3()`（L4224）⭐⭐⭐⭐

```cpp
// 调用 System.initPhase3() — 设置安全管理器 + 系统类加载器
// 安全管理器和系统类加载器可能是自定义类
```

**三个 Phase 的设计原因**（JDK 9 模块系统引入）：
- Phase 1：系统属性、IO 流（不需要模块系统）
- Phase 2：模块系统（之后才能从非 java.base 加载类）
- Phase 3：安全管理器和系统类加载器（可能是自定义类，需要模块已就绪）

### 10.4 `SystemDictionary::compute_java_loaders()`（L4227）

缓存 Bootstrap ClassLoader、Platform ClassLoader 和 Application ClassLoader 的引用。

---

## Phase 11-12：服务线程与最终初始化（L4245-4306）

### 11.1 JVMTI + 监控（L4245-4267）

```cpp
JvmtiExport::enter_live_phase();          // JVMTI 进入 live 阶段
JvmtiExport::post_vm_initialized();       // 通知 Agent VM 已初始化
Management::initialize(THREAD);            // JMX 初始化
BiasedLocking::init();                     // 偏向锁初始化（延迟启用，默认 4 秒后）
```

**`BiasedLocking::init()` 为什么有 4 秒延迟**：JVM 启动阶段有大量短生命周期的锁操作，如果立即启用偏向锁，会频繁发生偏向锁撤销（需要 safepoint），反而影响启动性能。延迟 4 秒让 JVM 先"热身"。这是**性能优化**。

### 11.2 `ServiceThread::initialize()`（L4176）

创建 ServiceThread，负责处理 JVMTI 延迟事件、哈希表清理等后台任务。

### 11.3 `os::initialize_jdk_signal_support()`（L4152）

创建 Signal Dispatcher 线程，负责将 OS 信号分发到 Java 层（`sun.misc.Signal`）。

### 11.4 `AttachListener::init()`（L4155-4160）

如果 `DisableAttachMechanism` 为 false（默认），启动 Attach Listener。这是 `jmap`、`jstack`、`jcmd` 等工具的基础——它们通过 Unix Domain Socket 连接到 JVM。

### 11.5 `WatcherThread::start()`（L4282-4293）⭐⭐⭐

```cpp
// thread.cpp:1613-1621
void WatcherThread::start() {
  if (watcher_thread() == NULL && _startable) {
    _should_terminate = false;
    new WatcherThread();  // 构造函数内部创建 OS 线程
  }
}
```

**WatcherThread 的作用**：执行周期性任务（`PeriodicTask`），比如：
- 定时 safepoint（`SafepointTracing`）
- 编译超时检测
- 偏向锁延迟启用
- 内存采样

**与 VMThread 的区别**：VMThread 是"被动触发，执行一次性操作"；WatcherThread 是"主动定时轮询"。

### Phase 11-12 小结

```
Phase 11-12 启动的线程：
├─ Signal Dispatcher   → 信号分发到 Java 层
├─ ServiceThread       → JVMTI 事件、表清理
├─ Attach Listener     → jmap/jstack/jcmd 的连接入口
└─ WatcherThread       → 定时任务执行

Phase 11-12 初始化的机制：
├─ BiasedLocking (延迟 4 秒启用) → 性能优化
├─ JMX Management     → 监控管理
└─ JVMTI live phase   → Agent 可以开始工作
```

---

## 最终结果：`return JNI_OK`

431 行代码执行完毕后，JVM 的状态：

```
┌─────────────────────────────────────────────────────────────┐
│                    JVM 已就绪状态                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  线程：                                                     │
│  ├─ 主线程 (JavaThread)      → 即将执行 main()              │
│  ├─ VMThread                  → 等待 VM Operation            │
│  ├─ Signal Dispatcher         → 等待信号                     │
│  ├─ ServiceThread             → 等待事件                     │
│  ├─ Attach Listener           → 等待连接                     │
│  └─ WatcherThread             → 定时轮询                     │
│                                                             │
│  内存：                                                     │
│  ├─ Java 堆 (8GB mmap)       → G1GC, 2048 × 4MB Region    │
│  ├─ 元空间                    → 类元数据存储                  │
│  ├─ 代码缓存                  → JIT 编译代码存储              │
│  ├─ PerfMemory (32KB)         → /tmp/hsperfdata_<user>/<pid> │
│  └─ ChunkPool (4个池)         → 内部快速内存分配              │
│                                                             │
│  机制：                                                     │
│  ├─ Safepoint (polling page)  → GC STW 的基础               │
│  ├─ 信号处理器                → NPE/SOE/ArithEx 的基础       │
│  ├─ 70+ 全局锁               → 并发安全的基础                │
│  ├─ 模板解释器                → 字节码执行的引擎              │
│  └─ 模块系统                  → 类加载的基础                  │
│                                                             │
│  Java 核心类已加载：                                         │
│  ├─ String, System, Class, Thread, ThreadGroup, Module       │
│  ├─ OutOfMemoryError, NullPointerException, ...              │
│  └─ main 线程组、main Thread 对象已创建                      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

回到调用者 `JNI_CreateJavaVM_inner()` 后，它把 `main_vm` 和 JNI 环境指针返回给 `JavaMain()`，`JavaMain()` 接下来就会加载用户指定的主类，调用其 `main()` 方法。

---

## 重要性分级汇总

### ⭐⭐⭐⭐⭐ 最关键（不可或缺）
| 调用 | 分类 |
|------|------|
| `ThreadLocalStorage::init()` | Thread::current() 的基础 |
| `Arguments::parse()` | 所有配置的起点 |
| `Arguments::apply_ergo()` | GC/堆/压缩指针决策 |
| `SafepointMechanism::initialize()` | GC STW 的基础 |
| `mutex_init()` | 所有并发操作的基础 |
| `init_globals()` → `universe_init()` | Java 堆创建 |
| `init_globals()` → `interpreter_init()` | 字节码执行引擎 |
| `VMThread::create()` | GC 执行的协调者 |
| `initialize_java_lang_classes()` | Java 核心类加载 |

### ⭐⭐⭐⭐ 非常重要
| 调用 | 分类 |
|------|------|
| `os::init()` | 页大小/CPU 数/物理内存 |
| `os::init_2()` | 信号处理/线程机制 |
| `os::init_before_ergo()` | 栈保护区/大页/CPU 核数 |
| `set_as_starting_thread()` | 主线程 OS 绑定 |
| `call_initPhase2/3()` | 模块系统/类加载器 |

### ⭐⭐⭐ 重要（性能或监控）
| 调用 | 分类 |
|------|------|
| `basic_types_init()` | 压缩指针大小设置（**性能优化**） |
| `chunkpool_init()` | 内存分配性能优化 |
| `perfMemory_init()` | 监控基础设施 |
| `ObjectMonitor::Initialize()` | 锁性能监控 |
| `BiasedLocking::init()` | 锁性能优化（延迟启用） |
| `WatcherThread::start()` | 定时任务执行 |

### ⭐⭐ 一般
| 调用 | 分类 |
|------|------|
| `ostream_init()` | 日志输出 |
| `JDK_Version_init()` | 版本信息 |
| `eventlog_init()` | 诊断黑匣子 |
| `register_thread_stack_with_NMT()` | 内存诊断 |
| Agent 加载 | 工具支持（无 Agent 时跳过） |

### ⭐ 不重要
| 调用 | 分类 |
|------|------|
| `VM_Version::early_initialize()` | 空实现 |
| `check_ThreadShadow()` | 纯断言 |
| `process_sun_java_launcher_properties()` | 启动器元数据 |
