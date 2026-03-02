# async-profiler 使用完全指南（Part 1：基础篇）

> 版本: v4.2.1 (stable) / v4.3 (源码分析版本)
> 官方文档: `/data/workspace/async-profiler/docs/`
> 本文基于 async-profiler 官方 15 篇文档整理，覆盖从入门到高级的全部使用场景

---

## 目录

- [一、async-profiler 是什么？](#一async-profiler-是什么)
- [二、环境准备](#二环境准备)
- [三、快速入门](#三快速入门)
- [四、三种集成方式](#四三种集成方式)
- [五、完整参数手册](#五完整参数手册)

---

## 一、async-profiler 是什么？

### 1.1 一句话定义

async-profiler 是一个**低开销的 Java 采样性能分析器**，它**不受 Safepoint 偏差问题**的影响，能同时采集 **Java 帧**、**Native 帧**和**内核帧**的混合调用栈。

### 1.2 与传统 Java Profiler 的区别

| 特性 | 传统 Profiler (JFR/jstack) | async-profiler |
|------|---------------------------|----------------|
| 采样方式 | Safepoint 采样（STW） | **异步信号采样（无 STW）** |
| Safepoint 偏差 | ✅ 存在 | ❌ **无偏差** |
| Native 帧 | ❌ 不显示 | ✅ 显示（libc/libjvm 等） |
| 内核帧 | ❌ 不显示 | ✅ 显示（syscall/调度等） |
| GC/JIT 线程 | ❌ 不可见 | ✅ **可见** |
| 需要 `-XX:+PreserveFramePointer` | — | ❌ **不需要**（v4.2+ 默认 VM Structs 模式） |
| 开销 | 中等 | **极低**（<1%） |

### 1.3 支持的采样事件

- **CPU 时间**：热点方法/函数定位
- **Wall Clock 时间**：包含阻塞/等待的全线程采样
- **Java 堆分配**：TLAB 驱动的分配采样
- **锁争用**：Java Monitor 和 j.u.c 锁
- **原生锁争用**：pthread_mutex/rwlock
- **原生内存**：malloc/realloc/free 追踪，内存泄漏检测
- **硬件性能计数器**：cache-misses, page-faults, context-switches 等
- **Java 方法追踪**：指定方法的所有调用栈
- **Native 函数追踪**：如 `G1CollectedHeap::humongous_obj_allocate`
- **Kernel Tracepoint**：`syscalls:sys_enter_open` 等

### 1.4 支持平台

| 平台 | 官方构建 | 社区移植 |
|------|---------|----------|
| **Linux** | x64, arm64 | x86, arm32, ppc64le, riscv64, loongarch64 |
| **macOS** | x64, arm64 | — |

---

## 二、环境准备

### 2.1 Linux 内核参数（重要！）

要获取**内核态调用栈**（推荐设置），需要调整两个内核参数：

```bash
# 允许非 root 用户使用 perf_events
sysctl kernel.perf_event_paranoid=1

# 允许读取内核符号地址（火焰图中显示内核函数名）
sysctl kernel.kptr_restrict=0
```

**持久化**（重启后仍生效）：
```bash
echo 'kernel.perf_event_paranoid=1' >> /etc/sysctl.conf
echo 'kernel.kptr_restrict=0' >> /etc/sysctl.conf
sysctl -p
```

**各 paranoid 级别说明**：

| 值 | 含义 | async-profiler 影响 |
|----|------|-------------------|
| -1 | 完全不限制 | 完全可用 |
| 0 | 允许所有用户 | 完全可用 |
| **1** | 允许但限制内核追踪 | **推荐设置** |
| 2 | 仅 root 用户 | 需要 root 或 fallback 到 ctimer |
| 3 | 完全禁止 | 必须 fallback 到 ctimer |

> **注意**：如果不设置这些参数，async-profiler 会**自动降级**到 `ctimer` 引擎——仍然可以采样，但没有内核栈。

### 2.2 JVM 参数（推荐但非必须）

```bash
# 推荐：提高采样精度（仅在运行时 attach 时需要）
-XX:+UnlockDiagnosticVMOptions -XX:+DebugNonSafepoints
```

**解释**：
- `-XX:+DebugNonSafepoints`：让 JIT 编译器在非 Safepoint 处也生成调试信息，使采样点能精确映射到源码位置
- 如果 async-profiler 作为 **Agent 随 JVM 启动**（`-agentpath`），则**不需要**这些参数，因为 `CompiledMethodLoad` JVMTI 事件会自动启用调试信息

### 2.3 文件描述符限制

CPU 模式下，async-profiler 会为**每个线程**创建一个 `perf_event` 文件描述符。如果应用线程很多，可能需要提高限制：

```bash
# 查看当前限制
ulimit -n

# 临时提高
ulimit -n 65536
```

### 2.4 安装

```bash
# 下载（Linux x64 为例）
wget https://github.com/async-profiler/async-profiler/releases/download/v4.2.1/async-profiler-4.2.1-linux-x64.tar.gz
tar xzf async-profiler-4.2.1-linux-x64.tar.gz
cd async-profiler-4.2.1-linux-x64

# 核心文件
bin/asprof          # 命令行启动器
lib/libasyncProfiler.so  # Agent 库（核心）
bin/jfrconv         # JFR 转换工具
```

### 2.5 libjvm 调试符号（JDK < 11 的分配采样需要）

```bash
# Debian / Ubuntu
apt install openjdk-17-dbg   # 替换为你的 JDK 版本

# CentOS / RHEL
debuginfo-install java-1.8.0-openjdk

# 验证符号是否安装成功
gdb $JAVA_HOME/lib/server/libjvm.so -ex 'info address UseG1GC'
# 成功: Symbol "UseG1GC" is at 0xxxxx
# 失败: No symbol "UseG1GC" in current context
```

> **JDK 11+** 不需要额外安装调试符号。部分发行版（Amazon Corretto、Liberica JDK、Azul Zulu）已内嵌。

---

## 三、快速入门

### 3.1 最简单的使用

```bash
# 找到目标 Java 进程 PID
jps
# 输出: 8983 MyApplication

# 对 PID=8983 的进程采样 30 秒，生成火焰图
asprof -d 30 -f flamegraph.html 8983
```

> **PID 的替代写法**：
> - `jps` — 自动查找（仅当系统中只有一个 Java 进程时）
> - `MyApplication` — 使用 `jps` 输出中的应用名

### 3.2 手动 start/stop 模式

```bash
# 开始采样
asprof start 8983

# ... 执行你要测试的操作 ...

# 停止采样并查看结果
asprof stop 8983
```

**输出示例**（文本格式）：
```
--- Execution profile ---
Total samples:           687
Unknown (native):        1 (0.15%)

--- 6790000000 (98.84%) ns, 679 samples
  [ 0] Primes.isPrime
  [ 1] Primes.primesThread
  [ 2] Primes.access$000
  [ 3] Primes$1.run
  [ 4] java.lang.Thread.run

          ns  percent  samples  top
  ----------  -------  -------  ---
  6790000000   98.84%      679  Primes.isPrime
    40000000    0.58%        4  __do_softirq
```

### 3.3 查看当前状态

```bash
asprof status 8983
# 输出: Profiling is running for 15 seconds

# 中途导出数据（不停止采样）
asprof dump 8983

# 恢复已停止的采样（保留之前的数据）
asprof resume 8983
```

### 3.4 查看可用事件

```bash
asprof list 8983
```

输出示例：
```
Basic events:
  cpu
  alloc
  lock
  wall
  itimer
  ctimer
Java method calls:
  ClassName.methodName
Perf events:
  page-faults
  context-switches
  cycles
  instructions
  cache-references
  cache-misses
  branch-instructions
  branch-misses
  ...
```

---

## 四、三种集成方式

### 4.1 方式一：asprof 命令行（推荐日常使用）

最简单的方式，适合日常排查。

```bash
# 基本语法
asprof [action] [options] <PID>
```

**Actions 动作一览**：

| 动作 | 说明 |
|------|------|
| `start` | 启动采样，直到手动 `stop` |
| `stop` | 停止采样，输出结果 |
| `resume` | 恢复之前停止的采样（保留已有数据） |
| `dump` | 导出当前数据但不停止采样 |
| `status` | 查看采样状态 |
| `metrics` | 输出 Prometheus 格式的指标 |
| `list` | 列出目标进程支持的事件类型 |

### 4.2 方式二：JVM Agent 启动（推荐生产环境）

随 JVM 启动时直接加载 async-profiler，适合**持续 Profiling** 和**应用启动阶段分析**。

```bash
java -agentpath:/path/to/libasyncProfiler.so=start,event=cpu,file=profile.html MyApp
```

**参数格式**：`-agentpath:/path/to/libasyncProfiler.so=<options>`，多个选项用逗号分隔。

**常用 Agent 启动示例**：

```bash
# CPU 采样 + 火焰图输出
java -agentpath:libasyncProfiler.so=start,event=cpu,file=cpu.html MyApp

# 多事件同时采集（输出为 JFR）
java -agentpath:libasyncProfiler.so=start,event=cpu,alloc=2m,lock=10ms,file=profile.jfr MyApp

# 持续 Profiling：每小时输出一个 JFR 文件
java -agentpath:libasyncProfiler.so=start,event=cpu,loop=1h,file=/var/log/profile-%t.jfr MyApp

# 30 秒后自动停止
java -agentpath:libasyncProfiler.so=start,event=cpu,timeout=30,file=profile.html MyApp
```

**Agent vs asprof 参数对照**：

| asprof | Agent 参数 | 说明 |
|--------|-----------|------|
| `-e cpu` | `event=cpu` | 事件类型 |
| `-i 10ms` | `interval=10000000` | 采样间隔（ns） |
| `-d 30` | `timeout=30` | 持续时间 |
| `-f file.html` | `file=file.html` | 输出文件 |
| `--alloc 2m` | `alloc=2m` | 分配采样间隔 |
| `--lock 10ms` | `lock=10ms` | 锁争用阈值 |
| `--loop 1h` | `loop=1h` | 持续 Profiling |
| `-t` | `threads` | 按线程分组 |

### 4.3 方式三：Java API（推荐嵌入应用）

通过 Maven 依赖在应用中编程控制采样。

**Maven 依赖**：
```xml
<dependency>
    <groupId>tools.profiler</groupId>
    <artifactId>async-profiler</artifactId>
    <version>4.2</version>
</dependency>
```

**代码示例**：
```java
import one.profiler.AsyncProfiler;

public class ProfileExample {
    public static void main(String[] args) throws Exception {
        AsyncProfiler profiler = AsyncProfiler.getInstance();
        
        // 开始采样
        profiler.execute("start,jfr,event=cpu,file=/path/to/%p.jfr");
        
        // ... 执行业务逻辑 ...
        doSomeWork();
        
        // 停止采样
        profiler.execute("stop");
    }
}
```

> `%p` 会自动替换为进程 PID。其他占位符见下文参数手册。

### 4.4 IntelliJ IDEA 内置集成

IntelliJ IDEA 已内置 async-profiler：

1. **Settings** → **Build, Execution, Deployment** → **Java Profiler**
2. 可修改 Agent options 自定义采样参数
3. 勾选 **Collect native calls** 可采集 Native 帧
4. 直接右键 → **Profile** 启动

---

## 五、完整参数手册

### 5.1 通用选项（所有输出格式适用）

| 参数 | 说明 | 示例 |
|------|------|------|
| `-e EVENT` | 事件类型 | `-e cpu` / `-e wall` / `-e alloc` |
| `-d N` | 采样持续秒数 | `-d 30` |
| `-i N` | 采样间隔（CPU:ns, wall:时间, method:调用次数） | `-i 5ms` / `-i 1000000` |
| `-f FILE` | 输出文件（`%p`=PID, `%t`=时间戳, `%n{MAX}`=序号） | `-f /tmp/profile-%t.html` |
| `-o FMT` | 输出格式 | `-o flamegraph` / `-o jfr` / `-o collapsed` |
| `-j N` | 最大栈深度（默认 2048） | `-j 512` |
| `-I PAT` | 包含匹配的调用栈（支持 `*` 通配） | `-I 'com.myapp.*'` |
| `-X PAT` | 排除匹配的调用栈 | `-X '*Unsafe.park*'` |
| `-L level` | 日志级别 | `-L debug` |
| `--alloc N` | 分配采样间隔 | `--alloc 500k` / `--alloc 2m` |
| `--live` | 只保留存活对象的分配样本 | `--live` |
| `--nativemem N` | 原生内存采样 | `--nativemem 1m` |
| `--nofree` | 不记录 free 调用 | `--nofree` |
| `--lock TIME` | Java 锁争用阈值 | `--lock 10ms` |
| `--nativelock TIME` | 原生锁争用阈值 | `--nativelock 5ms` |
| `--wall INTERVAL` | Wall clock 间隔（可与 cpu 同时使用） | `--wall 100ms` |
| `--loop TIME` | 持续 Profiling（自动循环输出） | `--loop 1h` |
| `--cstack MODE` | Native 栈回溯模式 | `--cstack dwarf` / `--cstack vm` / `--cstack lbr` |
| `--all-user` | 仅用户态事件 | `--all-user` |
| `--signal NUM` | 自定义信号 | `--signal 37` |
| `--begin FUNC` | 指定函数执行时自动开始采样 | `--begin SafepointSynchronize::begin` |
| `--end FUNC` | 指定函数执行时自动停止采样 | `--end RuntimeService::record_safepoint_synchronized` |
| `--ttsp` | Time-to-Safepoint 采样（是 begin/end 的快捷方式） | `--ttsp` |
| `--trace METHOD[:T]` | Java 方法追踪（可选延迟阈值） | `--trace my.pkg.Class.Method:50ms` |
| `-F features` | 高级栈特性 | `-F vtable,comptask,pcaddr` |
| `--filter IDS` | Wall 模式下仅采样指定线程 ID | `--filter 120-127,132` |
| `--target-cpu N` | 仅采样指定 CPU 上的线程 | `--target-cpu 3` |

### 5.2 JFR 专用选项

| 参数 | 说明 | 示例 |
|------|------|------|
| `--chunksize N` | JFR chunk 大小（默认 100MB） | `--chunksize 50m` |
| `--chunktime N` | JFR chunk 时间限制（默认 1 小时） | `--chunktime 30m` |
| `--jfrsync CONFIG` | 与 JDK JFR 同步录制 | `--jfrsync profile` |
| `--all` | 一键开启 cpu+wall+alloc+live+lock+nativemem | `--all` |

### 5.3 火焰图/树视图专用选项

| 参数 | 说明 | 示例 |
|------|------|------|
| `--title TITLE` | 自定义标题 | `--title "CPU Profile"` |
| `--minwidth N` | 最小帧宽度百分比 | `--minwidth 0.5` |
| `--reverse` | 反转调用栈（默认火焰图→变冰柱图） | `--reverse` |
| `--inverted` | 切换火焰图/冰柱图布局 | `--inverted` |

### 5.4 非 JFR 格式的通用选项

| 参数 | 说明 | 示例 |
|------|------|------|
| `-t` | 按线程分组显示 | `-t` |
| `-s` | 简单类名（不带包名） | `-s` |
| `-n` | 标准化 lambda/隐藏类名 | `-n` |
| `-g` | 显示方法签名 | `-g` |
| `-l` | 显示库名前缀 | `-l` |
| `--total` | 显示总量（总字节/总时间）而非样本数 | `--total` |
| `-a` | 注解帧类型（`_[j]`=JIT, `_[i]`=内联, `_[0]`=解释器） | `-a` |

### 5.5 文件名占位符

| 占位符 | 说明 | 示例 |
|--------|------|------|
| `%p` | 进程 PID | `profile-%p.jfr` → `profile-8983.jfr` |
| `%t` | 时间戳 | `profile-%t.jfr` → `profile-2024-01-15_10-30-00.jfr` |
| `%n{MAX}` | 序号（最大 MAX） | `profile-%n{100}.jfr` → `profile-001.jfr` |
| `%{ENV}` | 环境变量值 | `profile-%{HOSTNAME}.jfr` |

---

*→ 继续阅读 [Part 2：采样模式详解](async_profiler_usage_guide_part2.md)*
