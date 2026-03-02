# async-profiler 使用完全指南（Part 3：输出格式与高级特性）

> 接续 [Part 2：采样模式详解](async_profiler_usage_guide_part2.md)

---

## 目录

- [十四、输出格式详解](#十四输出格式详解)
- [十五、火焰图解读](#十五火焰图解读)
- [十六、JFR 可视化与转换](#十六jfr-可视化与转换)
- [十七、热力图（Heatmap）](#十七热力图heatmap)
- [十八、栈回溯模式](#十八栈回溯模式)
- [十九、高级栈特性](#十九高级栈特性)
- [二十、容器内 Profiling](#二十容器内-profiling)
- [二十一、非 Java 应用 Profiling](#二十一非-java-应用-profiling)
- [二十二、常见问题排查](#二十二常见问题排查)
- [二十三、实战食谱](#二十三实战食谱)

---

## 十四、输出格式详解

### 14.1 格式一览

| 格式 | 说明 | 文件扩展名 | 适用场景 |
|------|------|-----------|---------|
| `flamegraph` | 交互式 HTML 火焰图 | `.html` | **最常用**，浏览器查看 |
| `tree` | 交互式 HTML 调用树 | `.html` | 按资源使用排序的树形视图 |
| `jfr` | JDK Flight Recorder 格式 | `.jfr` | 多事件采集、JMC 分析 |
| `collapsed` | Collapsed 格式（分号分隔的栈 + 计数） | `.txt` | 与 FlameGraph.pl 脚本兼容 |
| `text` | 纯文本（默认） | 无扩展名 | 快速查看控制台 |
| `otlp` | OpenTelemetry 格式 | — | 可观测性平台集成 |

### 14.2 火焰图（推荐）

```bash
# 显式指定格式
asprof -d 30 -o flamegraph -f profile.html 8983

# 根据文件扩展名自动选择（.html → flamegraph）
asprof -d 30 -f profile.html 8983
```

### 14.3 调用树

```bash
# 正向树（从根开始）
asprof -d 30 -o tree -f tree.html 8983

# 反向树（从叶子开始，backtrace 视图）
asprof -d 30 -o tree --reverse -f tree.html 8983
```

### 14.4 JFR 格式

```bash
# 输出为 JFR（根据扩展名自动识别）
asprof -d 30 -f profile.jfr 8983
```

**JFR 中的事件类型**：
- `jdk.ExecutionSample` — CPU 采样
- `jdk.ObjectAllocationInNewTLAB` — TLAB 内分配
- `jdk.ObjectAllocationOutsideTLAB` — TLAB 外分配
- `jdk.JavaMonitorEnter` — 锁争用
- `jdk.ThreadPark` — park 等待

### 14.5 Collapsed 格式

```bash
asprof -d 30 -o collapsed -f traces.txt 8983
```

**输出格式**（可被 FlameGraph.pl 脚本处理）：
```
main;func1;func5 2
main;func2;func8 4
main;func3;func7 3
main;func4 1
```

### 14.6 文本格式

```bash
# 不指定 -f 或不带扩展名时，输出纯文本到控制台
asprof -d 30 8983

# 指定详细度
asprof -d 30 -o traces=200,flat=200 8983
# traces=200：最多显示 200 个采样调用栈
# flat=200：最多显示 200 个热点方法
```

---

## 十五、火焰图解读

### 15.1 如何阅读火焰图

```
                    ┌─── 顶部是叶子帧（实际消耗资源的方法）
                    │
          ┌─ func8 ──────────────┐
     ┌─── func2 ────────────┐ func6 │
func1 ─ func5 ─┐  func3 ─ func7 │    │
└──────── main() ──────────────────────┘
                    │
                    └─── 底部是根帧（main 方法）
```

**关键规则**：
1. **X 轴不是时间线**！它代表**采样比例**（越宽 = 被采样到越多次）
2. **Y 轴是调用深度**：从底部（根）到顶部（叶子）
3. **最宽的顶部帧**是最可能的性能瓶颈
4. 帧的排列按**字母序**（不是调用时间序）

### 15.2 颜色含义

async-profiler 的火焰图使用**颜色编码**区分帧类型：

| 颜色 | 帧类型 | 说明 |
|------|--------|------|
| 🟢 **绿色** | Java 方法 | JIT 编译的 Java 方法 |
| 🟡 **黄色** | C/C++ 方法 | Native 代码（libjvm/libc 等） |
| 🔴 **红色** | 内核方法 | 内核态函数（syscall 等） |
| 🟠 **橙色** | 解释器方法 | Java 解释执行的方法 |
| 🔵 **蓝色** | C1 编译方法 | C1 编译的 Java 方法 |
| 🟣 **紫色** | 内联方法 | JIT 内联的方法 |

### 15.3 火焰图交互

生成的 HTML 火焰图支持以下交互：
- **点击帧**：缩放到该帧
- **Ctrl+F**：搜索（匹配的帧高亮）
- **Reset Zoom**：恢复全图
- **Invert**：切换火焰图/冰柱图布局

### 15.4 反向火焰图（Icicle Graph）

```bash
# 反转栈：叶子在底部，根在顶部
asprof -d 30 --reverse -f reverse.html 8983

# 冰柱图布局（从上到下）
asprof -d 30 --inverted -f icicle.html 8983
```

**`--reverse` vs `--inverted`**：
- `--reverse`：改变**栈的合并方向**（从叶子帧开始合并，而非从根帧）
- `--inverted`：改变**布局方向**（火焰图↔冰柱图切换）
- 两者正交，可以组合使用

---

## 十六、JFR 可视化与转换

### 16.1 jfrconv 转换器

```bash
# 基本语法
jfrconv [options] <input> [<input>...] <output>
```

**支持的转换**：

| 源格式 | → html | → collapsed | → pprof | → pb.gz | → heatmap | → otlp |
|--------|:------:|:-----------:|:-------:|:-------:|:---------:|:------:|
| jfr | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| html | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| collapsed | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |

### 16.2 常用转换示例

```bash
# JFR → 火焰图（默认格式）
jfrconv profile.jfr profile.html

# 只提取 CPU 事件
jfrconv --cpu profile.jfr cpu.html

# 只提取 Wall Clock 事件
jfrconv --wall profile.jfr wall.html

# 只提取分配事件（按总字节数）
jfrconv --alloc --total profile.jfr alloc.html

# 只提取锁争用事件
jfrconv --lock profile.jfr lock.html

# 只提取原生锁
jfrconv --nativelock profile.jfr nativelock.html

# 原生内存泄漏分析
jfrconv --total --nativemem --leak profile.jfr leak.html

# 按线程分组
jfrconv --cpu -t profile.jfr cpu-threads.html

# 只保留 Running 状态的线程
jfrconv --cpu -s runnable profile.jfr running.html

# 自定义标题 + 反向栈
jfrconv --cpu profile.jfr cpu.html -r --title "My App CPU Profile"

# 只保留指定时间范围
jfrconv --cpu --from 10000 --to 20000 profile.jfr subset.html

# 过滤栈帧
jfrconv --cpu -I 'MyApplication\.main' -X '.*pthread_cond_wait.*' profile.jfr filtered.html

# 高亮匹配帧
jfrconv --cpu --highlight 'MyService.*' profile.jfr highlighted.html

# 转换为 pprof 格式（用 Google pprof 工具查看）
jfrconv --cpu -o pprof profile.jfr profile.pb.gz

# 生成热力图
jfrconv --cpu -o heatmap profile.jfr heatmap.html
```

### 16.3 JFR 可视化工具

| 工具 | 说明 |
|------|------|
| **jfrconv** | async-profiler 自带转换器 → HTML/collapsed/pprof |
| **JDK Mission Control (JMC)** | Oracle 官方 GUI 工具，完全兼容 |
| **IntelliJ IDEA Ultimate** | 内置 JFR 查看器 |
| **IntelliJ Community + Plugin** | 安装 "Java JFR Profiler" 插件 |
| **jfr 命令行** | JDK 自带的 `jfr` 工具 |

**JMC 中重点关注**：
- Java Application → **Method Profiling**（CPU 热点）
- Java Application → **Memory**（分配）
- Java Application → **Lock Instances**（锁争用）
- JVM Internals → **TLAB Allocations**（TLAB 分配）

---

## 十七、热力图（Heatmap）

### 17.1 什么是热力图？

火焰图是**聚合视图**，丢失了时间信息。热力图是**时间维度**的补充：

- 火焰图回答：**哪些代码路径消耗了最多资源？**
- 热力图回答：**资源消耗是均匀的，还是有间歇性尖峰？**

热力图是二维色块矩阵：
- X 轴：时间
- Y 轴：时间粒度的细分
- 颜色强度：采样密度（越深 = 事件越多）

### 17.2 生成热力图

```bash
# 先用 JFR 格式采样
asprof -e cpu --loop 1h -f /var/log/profile-%t.jfr 8983

# 从 JFR 生成热力图
jfrconv --cpu -o heatmap profile.jfr heatmap-cpu.html
```

### 17.3 热力图交互

| 操作 | 说明 |
|------|------|
| **点击色块** | 显示该时间段的火焰图 |
| **拖动选区** | 选择任意时间范围，生成该范围的火焰图 |
| **Ctrl + 拖动** | 选择对比基线 → 生成差异火焰图 |
| **Ctrl+F** | 搜索：匹配的时间段高亮为蓝色 |
| **Ctrl+Shift+F** | 搜索 + 过滤：火焰图只保留匹配的栈 |
| **缩放级别切换** | 3 级：5min/格 → 5s/格 → 20ms/格 |

### 17.4 优势

- 可视化 **24 小时**的连续采样，1GB JFR → 10-15MB HTML
- 独立 HTML 文件，**无需服务器**，浏览器直接打开
- 支持**差异对比**（目标时段 vs 基线时段）

---

## 十八、栈回溯模式

`--cstack MODE` 控制 async-profiler 如何回溯 Native 帧：

### 18.1 四种模式

| 模式 | 底层机制 | 优点 | 缺点 |
|------|---------|------|------|
| `vm`（**默认**，v4.2+） | 利用 JVM 内部结构 | 最可靠、有帧类型标注 | HotSpot 专属 |
| `fp` | Frame Pointer 链 | 最快 | 需要 `-fno-omit-frame-pointer` |
| `dwarf` | DWARF `.eh_frame` 信息 | 无需 FP，适合优化编译的库 | 更慢，内存更多 |
| `lbr` | Intel Last Branch Record | 硬件辅助，不依赖 FP | 仅 Intel Haswell+，最大深度 32 |
| `no` | 不收集 C 栈 | — | 只有 Java 帧 |

```bash
# 默认 VM Structs 模式（v4.2+）
asprof -d 30 -f profile.html 8983

# 显式指定
asprof --cstack vm -d 30 -f profile.html 8983

# 专家模式：Java + Native 帧混合交错显示
asprof --cstack vmx -d 30 -f profile.html 8983

# DWARF 模式（适合分析 native 库，如 libjvm 内部）
asprof --cstack dwarf -d 30 -f profile.html 8983

# Frame Pointer 模式
asprof --cstack fp -d 30 -f profile.html 8983

# LBR 模式（需要 -e cycles 等硬件事件）
asprof -e cycles --cstack lbr -d 30 -f profile.html 8983

# 不收集 Native 栈
asprof --cstack no -d 30 -f profile.html 8983
```

### 18.2 VM Structs 模式详解（默认，推荐）

从 v4.2 开始，async-profiler 默认使用 **VM Structs** 模式，利用 HotSpot 内部结构替代不稳定的 `AsyncGetCallTrace`：

**优势**：
- 完全由 `setjmp`/`longjmp` 保护，不会导致 JVM 崩溃
- 可以显示**所有帧类型**：Java、Native、JVM Stub
- 提供帧的额外信息（JIT 编译类型等）

**`vm` vs `vmx`**：
- `vm`：Java 帧和 Native 帧分开显示
- `vmx`：Java 和 Native 帧**交错混合**显示（专家模式）

---

## 十九、高级栈特性

使用 `-F` 参数启用：

### 19.1 显示 JIT 编译任务（comptask）

```bash
asprof -F comptask -d 30 -f profile.html 8983
```

在 JIT 编译线程的栈中，额外显示**正在编译的 Java 方法名**。可以定位：
- 哪些方法的编译最消耗 CPU
- C2 编译器是否卡在某个方法上（无限循环 bug）

### 19.2 显示虚方法调用目标（vtable）

```bash
asprof -F vtable -d 30 -f profile.html 8983
```

在 vtable/itable stub 顶部额外显示一个帧，标明**多态调用的实际接收者类型**。帮助分析 megamorphic virtual call 的分布。

### 19.3 显示指令地址（pcaddr）

```bash
asprof -F pcaddr -d 30 -f profile.html 8983
```

每个栈顶帧增加一个**PC 地址**合成帧，用于指令级性能分析。

### 19.4 组合使用

```bash
asprof -F vtable,comptask,pcaddr -d 30 -f profile.html 8983
```

---

## 二十、容器内 Profiling

### 20.1 从容器内部采样

容器内可以直接使用 asprof，但 Docker 默认 seccomp 策略会阻止 `perf_event_open`。

**方案一：放宽 seccomp 限制**
```bash
docker run --security-opt seccomp=unconfined --cap-add SYS_ADMIN ...
```

**方案二：fdtransfer（推荐）**
```bash
# 在宿主机上运行（有权限的进程传递 fd 给容器内进程）
asprof --fdtransfer -d 30 -f profile.html <container_java_pid>
```

**方案三：fallback 到 ctimer**
```bash
asprof -e ctimer -d 30 -f profile.html <pid>
```

### 20.2 从宿主机采样容器内进程

```bash
# 找到容器内 Java 进程在宿主机 namespace 的 PID
docker top <container>
# 或
ps aux | grep java

# 从宿主机采样（需要 root）
asprof -d 30 -f profile.html <host_pid>
```

> 需要确保容器内进程能通过**相同绝对路径**访问 `libasyncProfiler.so`，否则使用 `--libpath` 指定容器内路径。

---

## 二十一、非 Java 应用 Profiling

### 21.1 LD_PRELOAD 方式

```bash
LD_PRELOAD=/path/to/libasyncProfiler.so \
  ASPROF_COMMAND=start,event=cpu,file=profile.jfr \
  NativeApp [args]
```

支持 `cpu`、`wall`、`nativemem` 等模式。输出格式支持 Flame Graph 和 JFR（但没有 Java 特有事件）。

### 21.2 C API 方式

```c
#include "asprof.h"
#include <dlfcn.h>

int main() {
    void* lib = dlopen("/path/to/libasyncProfiler.so", RTLD_NOW);
    
    asprof_init_t asprof_init = dlsym(lib, "asprof_init");
    asprof_execute_t asprof_execute = dlsym(lib, "asprof_execute");
    
    asprof_init();
    asprof_execute("start,event=cpu,file=profile.jfr", callback);
    
    // ... work ...
    
    asprof_execute("stop", callback);
    return 0;
}
```

---

## 二十二、常见问题排查

### 22.1 错误消息速查表

| 错误信息 | 原因 | 解决方案 |
|---------|------|---------|
| **perf_event mmap failed: Operation not permitted** | perf_event buffer 总量超出锁定内存限制 | 增大 `ulimit -l` 或 `kernel.perf_event_mlock_kb` |
| **Failed to change credentials to match the target process** | asprof 运行用户 ≠ 目标 JVM 用户 | 用相同用户运行，或用 root |
| **Could not start attach mechanism: No such file or directory** | Attach socket 被清理 / JVM 禁止 attach / 容器隔离 | ① 排除 `/tmp/.java_pid*` 清理<br>② 检查 `-XX:+DisableAttachMechanism`<br>③ 检查 `/tmp` 挂载 |
| **Target JVM failed to load libasyncProfiler.so** | JVM 进程无权访问 .so 文件 | 确保相同绝对路径、相同用户权限 |
| **Perf events unavailable** | perf_event_paranoid >= 2 / seccomp 限制 / 虚拟化 | ① `sysctl kernel.perf_event_paranoid=1`<br>② `--fdtransfer`<br>③ fallback `-e ctimer` |
| **No AllocTracer symbols found** | JDK < 11 缺少调试符号 | 安装 `openjdk-xx-dbg` 包 |
| **VMStructs unavailable. Unsupported JVM?** | 不是 HotSpot JVM 或 JDK 构建异常 | 安装调试符号 / 确认 JVM 类型 |
| **Could not parse symbols from libname.so** | `/proc/[pid]/maps` 内容损坏 | Ubuntu + Linux 5.x 内核 bug |
| **Could not open output file** | 输出文件由目标 JVM 写入，路径不可达 | 确保 `-f` 路径 JVM 进程可访问 |

### 22.2 已知限制

| 限制 | 说明 | 解决方案 |
|------|------|---------|
| `-XX:MaxJavaStackTraceDepth=0` | 不会收集 Java 栈 | `--cstack vm` 不受此限制 |
| 采样间隔过短 | 可能中断长系统调用（如 `clone()`）导致其永不完成 | 增大采样间隔 |
| 运行时 attach 缺少调试信息 | JIT 编译的方法可能不够精确 | 加 `-XX:+DebugNonSafepoints` 或用 `-agentpath` 方式 |
| perf_events 最大栈深度 | 大多数 Linux 默认 127 帧 | `sysctl kernel.perf_event_max_stack=N` |
| Java 帧前的 Native 帧不可见 | 如 `start_thread → JavaMain` 不会显示 | 使用 `--cstack vmx` |
| macOS 限制 | 仅用户态采样 | — |

---

## 二十三、实战食谱

### 🍳 场景 1：CPU 热点定位

```bash
# 采样 30 秒，生成火焰图
asprof -d 30 -f cpu.html 8983
# 浏览器打开 cpu.html → 找最宽的顶部帧
```

### 🍳 场景 2：接口响应慢（CPU 不高）

```bash
# Wall Clock + 按线程分组 → 看线程在等什么
asprof -e wall -t -i 50ms -d 30 -f wall.html 8983
```

### 🍳 场景 3：内存分配频繁（GC 压力大）

```bash
# 分配采样 → 看哪些代码路径分配最多
asprof --alloc 500k -d 60 -f alloc.html 8983
```

### 🍳 场景 4：Java 堆内存泄漏

```bash
# 只保留存活对象
asprof -e alloc --live -d 120 -f leak.html 8983
```

### 🍳 场景 5：Native 内存泄漏

```bash
# 采样 + 泄漏分析
asprof start -e nativemem -f app.jfr 8983
# 等待足够长时间
asprof stop 8983
jfrconv --total --nativemem --leak app.jfr leak.html
```

### 🍳 场景 6：锁争用分析

```bash
# Java 锁
asprof -e lock --lock 10ms -t -d 30 -f lock.html 8983

# Native 锁（JVM 内部）
asprof --nativelock 5ms -t -d 30 -f nativelock.html 8983
```

### 🍳 场景 7：应用启动慢

```bash
# 作为 Agent 启动 → 从 JVM 启动就开始采样
java -agentpath:libasyncProfiler.so=start,event=wall,threads,file=startup.html MyApp
```

### 🍳 场景 8：全面诊断（开发环境）

```bash
# CPU + 分配 + 锁 + Wall Clock + 原生内存 一起采
asprof --all --alloc 2m --lock 10ms -f diag.jfr 8983

# 停止后分别提取
jfrconv --cpu diag.jfr cpu.html
jfrconv --alloc --total diag.jfr alloc.html
jfrconv --lock diag.jfr lock.html
jfrconv --wall diag.jfr wall.html
```

### 🍳 场景 9：生产环境持续 Profiling

```bash
# Agent 启动 + 每小时输出
java -agentpath:libasyncProfiler.so=start,event=cpu,alloc=2m,loop=1h,file=/var/log/profile-%t.jfr MyApp
```

### 🍳 场景 10：与 JDK JFR 联合使用

```bash
# async-profiler 采 CPU（无 Safepoint 偏差）
# + JDK JFR 采 GC/IO/线程等系统事件
asprof -e cpu --jfrsync profile -f combined.jfr 8983
# 用 JMC 或 IntelliJ IDEA 打开 combined.jfr
```

### 🍳 场景 11：定位 Safepoint 延迟

```bash
# TTSP 模式：只记录请求 Safepoint 到进入 Safepoint 期间的事件
asprof --ttsp -e cpu -d 60 -f ttsp.html 8983
# 火焰图中的栈就是导致 Safepoint 延迟的代码路径
```

### 🍳 场景 12：追踪大对象分配

```bash
asprof -e G1CollectedHeap::humongous_obj_allocate -d 60 -f humongous.html 8983
```

### 🍳 场景 13：追踪线程创建

```bash
asprof -e JVM_StartThread -d 60 -f threads.html 8983
```

### 🍳 场景 14：Cache Miss 分析

```bash
asprof -e cache-misses -d 30 -f cache.html 8983
```

### 🍳 场景 15：时间维度分析（间歇性抖动）

```bash
# 先持续采样
asprof --loop 1h -f /var/log/profile-%t.jfr 8983

# 生成热力图
jfrconv --cpu -o heatmap profile-*.jfr heatmap.html
# 在热力图中定位抖动时间段 → 点击查看该时段火焰图
```

---

## 总结：选择指南

```
你要分析什么？
│
├── CPU 热点 → asprof -e cpu -d 30 -f cpu.html <pid>
│
├── 线程在等什么 → asprof -e wall -t -d 30 -f wall.html <pid>
│
├── 内存分配热点 → asprof --alloc 500k -d 60 -f alloc.html <pid>
│
├── Java 堆泄漏 → asprof -e alloc --live -d 120 -f leak.html <pid>
│
├── Native 内存泄漏 → asprof -e nativemem -f app.jfr <pid>
│                      jfrconv --total --nativemem --leak app.jfr leak.html
│
├── 锁争用 → asprof -e lock --lock 10ms -t -d 30 -f lock.html <pid>
│
├── 全面诊断 → asprof --all -f diag.jfr <pid>
│
├── 持续监控 → asprof --loop 1h -f profile-%t.jfr <pid>
│
├── 间歇性抖动 → jfrconv --cpu -o heatmap profile.jfr heatmap.html
│
└── Safepoint 延迟 → asprof --ttsp -e cpu -d 60 -f ttsp.html <pid>
```

---

*本指南基于 async-profiler v4.2.1 官方文档整理*
*源码分析系列见: [async_profiler_outline.md](async_profiler_outline.md)*
*创建日期: 2026-02-10*
