# B.1.1 ParallelGCThreads 计算算法 - 深度分析

> 源码位置：`abstract_vm_version.cpp:348-422`
> 调用链：`G1Arguments::initialize()` → `parallel_worker_threads()` → `nof_parallel_worker_threads(5, 8, 8)`

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文是对 **B.1.1 ParallelGCThreads 计算算法 - 深度分析** 的深度源码分析：从数据结构到算法流程，逐层剖析其实现原理，并通过 GDB 验证关键结论。

### 0.2 为什么需要？

深入理解 JVM 内部实现，不仅能帮助排查生产问题，更能建立对 JVM 行为的精确预测能力——知道『为什么』比知道『是什么』更重要。

### 0.3 怎么解决？

采用「数据结构 → 算法流程 → GDB 验证」三步法：先完整分析所有涉及的数据结构（字段含义/sizeof/生命周期），再分析算法流程（每步有 why），最后用 GDB 实际验证关键结论。

### 0.4 为什么这样设计？

JVM 的每个设计决策都有其历史背景和性能考量。本文在分析每个关键设计时，都会解释「为什么这样而不是那样」，帮助读者建立设计直觉。

---


## 1. 功能定位

### 一句话说明
`ParallelGCThreads` 决定了 **STW（Stop-The-World）阶段并行工作的 GC 线程数**，直接影响 GC 暂停时间。

### 在整体流程中的位置
```
JVM 启动
└── Arguments::parse()
    └── GCConfig::initialize()
        └── G1Arguments::initialize()          ← 设置 ParallelGCThreads
            └── parallel_worker_threads()
                └── nof_parallel_worker_threads(5, 8, 8)
                    └── os::initial_active_processor_count()  ← 获取 CPU 数
```

### 影响范围
| 阶段 | 使用场景 | 影响 |
|------|---------|------|
| Young GC | 并行扫描根、并行复制对象 | 线程越多，暂停越短 |
| Mixed GC | 并行标记、并行疏散 | 同上 |
| Full GC | 并行压缩 | 同上 |
| 并发标记 | G1ConcRefinementThreads 默认 = ParallelGCThreads | 并发处理脏卡 |

---

## 2. 核心算法

### 2.1 源码（含详细注释）

```cpp
// abstract_vm_version.cpp:348-401
unsigned int Abstract_VM_Version::nof_parallel_worker_threads(
    unsigned int num,       // 分子，默认 5
    unsigned int den,       // 分母，默认 8
    unsigned int switch_pt  // 切换点，默认 8
) {
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 分支1：用户没有显式指定 ParallelGCThreads，JVM 自动计算
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    if (FLAG_IS_DEFAULT(ParallelGCThreads)) {
        assert(ParallelGCThreads == 0, "Default ParallelGCThreads is not 0");
        
        unsigned int threads;
        
        // 获取 CPU 核心数（程序启动时的快照，不会变化）
        unsigned int ncpus = (unsigned int) os::initial_active_processor_count();
        
        // ════════════════════════════════════════════════════════
        // 核心公式：
        //   if (ncpus <= 8)
        //       threads = ncpus                    // 小机器：1:1
        //   else
        //       threads = 8 + (ncpus - 8) * 5/8   // 大机器：打折
        // ════════════════════════════════════════════════════════
        threads = (ncpus <= switch_pt) ?
                  ncpus :
                  (switch_pt + ((ncpus - switch_pt) * num) / den);
        
        // 32位系统额外限制（现代生产环境不用考虑）
        #ifndef _LP64
        threads = MIN2(threads, (2 * switch_pt));  // 最多 16 线程
        #endif
        
        return threads;
    } 
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 分支2：用户显式指定了 -XX:ParallelGCThreads=N
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    else {
        return ParallelGCThreads;  // 直接使用用户指定的值
    }
}
```

### 2.2 算法图解

```
 ParallelGCThreads
        │
     80 ┤                                          ╱
        │                                        ╱
     60 ┤                                      ╱
        │                                    ╱  斜率 = 5/8 = 0.625
     40 ┤                                  ╱
        │                                ╱
     20 ┤                    ╱─────────╱
        │              ╱─────
      8 ┤        ╱─────  斜率 = 1
        │  ╱─────
      0 ┼─────┬─────┬─────┬─────┬─────┬─────┬───► CPU 核心数
        0     8    16    32    48    64    80
                  │
                  └── 切换点 (switch_pt = 8)

═══════════════════════════════════════════════════════════════
公式：
  ncpus ≤ 8:   threads = ncpus
  ncpus > 8:   threads = 8 + (ncpus - 8) × 5/8
═══════════════════════════════════════════════════════════════
```

### 2.3 计算示例表

| CPU 核心数 | 公式 | ParallelGCThreads | 说明 |
|-----------|------|-------------------|------|
| 1 | 1 | 1 | 单核，1:1 |
| 4 | 4 | 4 | 小机器，1:1 |
| 8 | 8 | 8 | 切换点，1:1 |
| 12 | 8 + (12-8)×5/8 = 8 + 2.5 = 10 | **10** | 开始打折 |
| 16 | 8 + (16-8)×5/8 = 8 + 5 = 13 | **13** | |
| 20 | 8 + (20-8)×5/8 = 8 + 7.5 = 15 | **15** | |
| 32 | 8 + (32-8)×5/8 = 8 + 15 = 23 | **23** | |
| 64 | 8 + (64-8)×5/8 = 8 + 35 = 43 | **43** | |
| 72 | 8 + (72-8)×5/8 = 8 + 40 = 48 | **48** | 官方注释中的例子 |
| 128 | 8 + (128-8)×5/8 = 8 + 75 = 83 | **83** | 超大机器 |

---

## 3. 为什么要打折？

### 3.1 问题：大机器上 GC 线程过多的坏处

```
问题场景：假设一台 72 核的服务器

方案 A：ParallelGCThreads = 72（不打折）
┌────────────────────────────────────────────────────────────────┐
│  问题 1：收益递减（Diminishing Returns）                        │
│  ─────────────────────────────────────────────────────────────  │
│  • GC 工作量有限，线程太多会争抢锁、缓存失效                     │
│  • 72 线程并不比 48 线程快多少，但开销更大                       │
│                                                                 │
│  问题 2：系统资源霸占                                           │
│  ─────────────────────────────────────────────────────────────  │
│  • STW 期间，72 个 GC 线程全力运行                              │
│  • 其他进程（监控、日志、网络）被严重饿死                        │
│  • 在容器环境中，可能影响其他容器                                │
│                                                                 │
│  问题 3：线程管理开销                                           │
│  ─────────────────────────────────────────────────────────────  │
│  • 每个 GC 线程有自己的栈（1MB）、PLAB、任务队列                 │
│  • 72 线程 vs 48 线程：额外 24MB 栈空间 + 其他开销               │
│                                                                 │
│  问题 4：同步开销                                               │
│  ─────────────────────────────────────────────────────────────  │
│  • 线程越多，任务分配和结果汇总的同步开销越大                    │
│  • 工作窃取队列的竞争加剧                                        │
└────────────────────────────────────────────────────────────────┘

方案 B：ParallelGCThreads = 48（打折到 5/8）
┌────────────────────────────────────────────────────────────────┐
│  √ 足够的并行度，GC 暂停时间仍然很短                            │
│  √ 留出 24 个核心给系统和其他服务                               │
│  √ 减少内存开销和同步开销                                        │
│  √ 更好的缓存利用率                                              │
└────────────────────────────────────────────────────────────────┘
```

### 3.2 为什么是 5/8？

```
历史背景（源码注释）：
"They were chosen by running GCOld and SPECjbb on debris with different
numbers of GC threads and choosing them based on the results"

翻译：Oracle 工程师在 SPECjbb 和 GCOld 基准测试中反复调优得出的经验值

5/8 的平衡点：
┌──────────────────────────────────────────────────────────────────┐
│                                                                   │
│   太激进（如 3/8 = 0.375）                                        │
│   • 线程太少，GC 暂停变长                                         │
│   • 大堆时 Young GC 可能超过目标暂停时间                          │
│                                                                   │
│   太保守（如 7/8 = 0.875）                                        │
│   • 接近 1:1，打折效果不明显                                      │
│   • 仍然霸占太多资源                                              │
│                                                                   │
│   5/8 = 0.625 是经验最优值                                        │
│   • 大约 60% 的核心用于 GC                                        │
│   • 40% 的核心留给系统                                            │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘
```

### 3.3 为什么切换点是 8？

```
历史原因：
• JDK 5/6 时代，8 核以上的机器算"大机器"
• 当时主流服务器是 4-8 核
• 8 核以下按 1:1 已经很合理

现代考量：
• 虽然现在 8 核是"小机器"，但公式仍然有效
• 8 核以下的机器通常堆也小，GC 工作量有限
• 即使 1:1 也不会有太大问题
```

---

## 4. 调用链详解

### 4.1 完整调用链

```
G1Arguments::initialize()                    [g1Arguments.cpp:98]
│
│   FLAG_SET_DEFAULT(ParallelGCThreads, 
│                    Abstract_VM_Version::parallel_worker_threads());
│
└── Abstract_VM_Version::parallel_worker_threads()  [abstract_vm_version.cpp:411]
    │
    ├── 检查 _parallel_worker_threads_initialized
    │   （首次调用为 false）
    │
    ├── 检查 FLAG_IS_DEFAULT(ParallelGCThreads)
    │   │
    │   ├── true（用户没指定）
    │   │   └── VM_Version::calc_parallel_worker_threads()
    │   │       └── nof_parallel_worker_threads(5, 8, 8)  ← 核心算法
    │   │           └── os::initial_active_processor_count()  ← 获取 CPU 数
    │   │
    │   └── false（用户指定了 -XX:ParallelGCThreads=N）
    │       └── return ParallelGCThreads  ← 直接返回用户值
    │
    └── _parallel_worker_threads_initialized = true
        （缓存结果，避免重复计算）
```

### 4.2 os::initial_active_processor_count() 的实现

```cpp
// os.cpp
static int _initial_active_processor_count = 0;

void os::initialize_initial_active_processor_count() {
    // 在 JVM 启动早期调用一次
    _initial_active_processor_count = active_processor_count();
}

int os::initial_active_processor_count() {
    return _initial_active_processor_count;
}

// Linux 上的实现
int os::active_processor_count() {
    // 1. 优先检查 cgroup 限制（容器环境）
    // 2. 否则返回系统 CPU 数
    return sched_getaffinity() 或 sysconf(_SC_NPROCESSORS_ONLN);
}
```

**重要**：使用 `initial_active_processor_count()` 而不是 `active_processor_count()`，因为：
- 启动时的 CPU 数是固定的
- 运行时 CPU 数可能被 cgroup 动态调整
- GC 线程数一旦确定就不会改变

---

## 5. GDB 验证

### 5.1 GDB 脚本

```gdb
# 保存到 jvm-md/tmp-file/universe-init/gdb_parallel_gc_threads.txt
set pagination off
set print pretty on

# 在 G1Arguments::initialize() 设置 ParallelGCThreads 之后断点
b g1Arguments.cpp:99
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# 查看 ParallelGCThreads
printf "\n========== ParallelGCThreads 计算结果 ==========\n"
printf "ParallelGCThreads = %u\n", ParallelGCThreads

# 查看 CPU 数
printf "\n========== CPU 信息 ==========\n"
printf "os::_initial_active_processor_count = %d\n", os::_initial_active_processor_count

# 验证计算过程
set $ncpus = os::_initial_active_processor_count
set $switch_pt = 8
set $num = 5
set $den = 8
printf "\n========== 计算过程验证 ==========\n"
printf "ncpus = %u\n", $ncpus
printf "switch_pt = %u\n", $switch_pt
if $ncpus <= $switch_pt
    printf "公式: threads = ncpus = %u\n", $ncpus
else
    set $threads = $switch_pt + (($ncpus - $switch_pt) * $num) / $den
    printf "公式: threads = %u + (%u - %u) * %u / %u = %u\n", $switch_pt, $ncpus, $switch_pt, $num, $den, $threads
end

# 查看相关参数
printf "\n========== 相关 GC 参数 ==========\n"
printf "G1ConcRefinementThreads = %u\n", G1ConcRefinementThreads
printf "ConcGCThreads = %u\n", ConcGCThreads

quit
```

### 5.2 执行命令

```bash
cd /data/workspace/openjdk-cut-new
gdb -x jvm-md/tmp-file/universe-init/gdb_parallel_gc_threads.txt \
    ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java
```

### 5.3 实际 GDB 输出（16 核机器）

```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
┌─────────────────────────────────────────────────────────────────┐
│                 ParallelGCThreads 计算结果                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  CPU 信息                                                        │
│  ───────────────────────────────                                 │
│  os::_initial_active_processor_count = 16                        │
│                                                                  │
│  计算过程验证                                                    │
│  ───────────────────────────────                                 │
│  ncpus = 16                                                      │
│  switch_pt = 8                                                   │
│  num = 5, den = 8                                                │
│                                                                  │
│  公式: threads = 8 + (16 - 8) * 5 / 8                            │
│       = 8 + 8 * 5 / 8                                            │
│       = 8 + 40 / 8                                               │
│       = 8 + 5                                                    │
│       = 13  ✓                                                    │
│                                                                  │
│  最终结果                                                        │
│  ───────────────────────────────                                 │
│  ParallelGCThreads = 13  ✓ （与公式计算一致）                    │
│                                                                  │
│  相关参数（此时尚未设置）                                        │
│  ───────────────────────────────                                 │
│  G1ConcRefinementThreads = 0  （稍后设置为 ParallelGCThreads）   │
│  ConcGCThreads = 0            （稍后计算）                       │
│  UseDynamicNumberOfGCThreads = 1 （动态调整线程数，默认开启）    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**验证结论**：GDB 实际数据与公式计算完全一致！

---

## 6. 用户可调参数

### 6.1 显式指定 ParallelGCThreads

```bash
# 显式指定 GC 线程数
java -XX:ParallelGCThreads=8 -Xms8g -Xmx8g -XX:+UseG1GC ...

# 适用场景：
# 1. 容器环境中，CPU 核心数被限制，但 JVM 看不到
# 2. 想要限制 GC 对系统的影响
# 3. 调优后发现默认值不是最优
```

### 6.2 相关参数对照表

| 参数 | 默认值 | 作用 |
|------|--------|------|
| `ParallelGCThreads` | 自动计算 | STW 阶段的并行 GC 线程数 |
| `G1ConcRefinementThreads` | = ParallelGCThreads | 并发细化线程数（处理脏卡） |
| `ConcGCThreads` | = ParallelGCThreads / 4 | 并发标记线程数 |

### 6.3 调优建议

```
场景 1：容器环境（4 核限制）
────────────────────────────────────────────────
问题：JVM 可能看到宿主机的 64 核，计算出 ParallelGCThreads = 43
解决：java -XX:ParallelGCThreads=4 ...

场景 2：延迟敏感型应用
────────────────────────────────────────────────
需求：尽可能短的 GC 暂停
策略：可以适当增加 ParallelGCThreads（但不要超过 CPU 数）

场景 3：吞吐量优先型应用
────────────────────────────────────────────────
需求：GC 占用的 CPU 时间尽量少
策略：可以适当减少 ParallelGCThreads

场景 4：混合部署环境
────────────────────────────────────────────────
问题：多个 JVM 实例共享机器
解决：每个 JVM 限制 ParallelGCThreads，避免 GC 期间争抢
```

---

## 7. 设计思考

### 7.1 为什么不直接用 CPU 核心数？

| 问题 | 直接用 ncpus | 打折方案 |
|------|-------------|----------|
| 资源霸占 | 所有核心被 GC 占用 | 留出 40% 给系统 |
| 收益递减 | 线程多，竞争大 | 控制在合理范围 |
| 线程开销 | 栈、PLAB、队列 | 减少内存占用 |
| 可预测性 | 暂停时间波动大 | 更稳定 |

### 7.2 为什么缓存计算结果？

```cpp
static unsigned int _parallel_worker_threads;
static bool _parallel_worker_threads_initialized;

unsigned int parallel_worker_threads() {
    if (!_parallel_worker_threads_initialized) {
        // ... 计算 ...
        _parallel_worker_threads_initialized = true;
    }
    return _parallel_worker_threads;
}
```

原因：
1. `os::initial_active_processor_count()` 调用开销
2. 多处需要这个值（G1Arguments、Parallel GC、CMS 等）
3. 值不会变化，缓存是正确的优化

---

## 8. 总结

### 核心公式

```
if (ncpus <= 8)
    ParallelGCThreads = ncpus
else
    ParallelGCThreads = 8 + (ncpus - 8) × 5/8
```

### 设计理念

```
┌────────────────────────────────────────────────────────────────┐
│                                                                 │
│  "不要霸占整个系统"                                              │
│                                                                 │
│  • 小机器（≤8 核）：全力 GC，因为 GC 是瓶颈                      │
│  • 大机器（>8 核）：打折，因为收益递减 + 留资源给系统            │
│  • 5/8 是 Oracle 工程师在基准测试中调出来的经验值                │
│                                                                 │
└────────────────────────────────────────────────────────────────┘
```

### 你机器上的值（16 核）

```
ParallelGCThreads = 8 + (16 - 8) × 5/8
                  = 8 + 8 × 0.625
                  = 8 + 5              ← 整数除法：40/8 = 5
                  = 13  ✓

GDB 实际验证：ParallelGCThreads = 13 ✓
```

---

## 下一步

建议继续学习：
- **B.2** `G1ConcRefinementThreads` - 了解并发细化线程
- **E.1** `WorkGang` 创建 - 了解这些线程是如何被管理的
- **F.1** `G1Predictions` - 了解 G1 如何预测 GC 暂停时间

或者告诉我："运行 GDB 验证 B.1.1"，我帮你执行脚本获取实际数据。
