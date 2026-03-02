# async-profiler 使用完全指南（Part 2：采样模式详解）

> 接续 [Part 1：基础篇](async_profiler_usage_guide_part1.md)

---

## 目录

- [六、CPU 采样模式](#六cpu-采样模式)
- [七、Wall Clock 采样模式](#七wall-clock-采样模式)
- [八、分配（Allocation）采样模式](#八分配allocation采样模式)
- [九、锁争用（Lock）采样模式](#九锁争用lock采样模式)
- [十、原生内存（Native Memory）采样模式](#十原生内存native-memory采样模式)
- [十一、Java 方法追踪](#十一java-方法追踪)
- [十二、多事件同时采集](#十二多事件同时采集)
- [十三、持续 Profiling](#十三持续-profiling)

---

## 六、CPU 采样模式

### 6.1 基本用法

```bash
# 默认事件就是 cpu
asprof -d 30 -f cpu.html 8983

# 显式指定
asprof -e cpu -d 30 -f cpu.html 8983
```

**含义**：采样**正在 CPU 上运行**的线程调用栈。如果一个线程在等待 I/O 或锁，它**不会被采样**。

**默认采样频率**：100Hz（每 10ms 的 CPU 时间采一次）。

### 6.2 三种 CPU 采样引擎

async-profiler 提供了三种 CPU 采样引擎，根据环境自动选择：

| 引擎 | 底层 API | 特点 |
|------|---------|------|
| `cpu`（默认） | `perf_event_open` | **最精确**，可获取内核栈，但需要内核权限 |
| `ctimer` | `timer_create` | 线程级精度，不需要 perf_events 权限 |
| `itimer` | `setitimer(ITIMER_PROF)` | 进程级，跨平台（支持 macOS），精度最低 |

**详细对比**：

| 属性 | cpu (perf_events) | itimer | ctimer |
|------|:---:|:---:|:---:|
| 可获取内核栈 | ✅ | ❌ | ❌ |
| 高精度 | ✅ | ❌ | ❌ |
| 采样公平性 | ✅ | ❌ | 🆗 |
| 容器内默认可用 | ❌ | ✅ | ✅ |
| 不消耗文件描述符 | ❌ | ✅ | ✅ |
| macOS 支持 | ❌ | ✅ | ❌ |

**自动降级机制**：
- `-e cpu` 时，async-profiler 会尝试创建 `perf_event`
- 如果失败（权限不足/容器限制），**自动降级**到 `ctimer`
- 如果你明确要用 perf_events（用户态），使用 `-e cpu-clock --all-user`

**手动选择引擎**：
```bash
# 强制使用 itimer（macOS 或避免文件描述符问题）
asprof -e itimer -d 30 -f cpu.html 8983

# 强制使用 ctimer
asprof -e ctimer -d 30 -f cpu.html 8983
```

### 6.3 调整采样间隔

```bash
# 默认 10ms (100Hz)
asprof -e cpu -d 30 -f cpu.html 8983

# 更高频率：5ms (200Hz)，更精确但开销更高
asprof -e cpu -i 5ms -d 30 -f cpu.html 8983

# 更低频率：50ms (20Hz)，适合长时间采样
asprof -e cpu -i 50ms -d 30 -f cpu.html 8983
```

### 6.4 硬件性能计数器

除了 CPU 时间，还可以采集硬件事件：

```bash
# CPU cycles（每 N 个 cycle 采一次）
asprof -e cycles -d 30 -f cycles.html 8983

# Cache 缺失
asprof -e cache-misses -d 30 -f cache.html 8983

# 分支预测失败
asprof -e branch-misses -d 30 -f branch.html 8983

# 页面错误
asprof -e page-faults -d 30 -f pagefault.html 8983

# 上下文切换
asprof -e context-switches -d 30 -f ctx.html 8983

# L1 数据缓存加载缺失
asprof -e L1-dcache-load-misses -d 30 -f l1.html 8983

# LLC（Last Level Cache）缺失
asprof -e LLC-load-misses -d 30 -f llc.html 8983

# 自定义 PMU 事件（十六进制编码）
asprof -e r4d2 -d 30 -f pmu.html 8983
# 0x4d2 → MEM_LOAD_L3_HIT_RETIRED.XSNP_HITM
```

### 6.5 Kernel Tracepoint 和 Probe

```bash
# Kernel Tracepoint：追踪 open 系统调用
asprof -e syscalls:sys_enter_open -d 30 -f open.html 8983

# Kernel Probe
asprof -e kprobe:do_sys_open -d 30 -f kopen.html 8983

# Userspace Probe
asprof -e uprobe:/usr/lib64/libc-2.17.so+0x114790 -d 30 8983

# 硬件断点：读/写指定地址
asprof -e mem:0x7f1234567890:rw -d 30 8983

# Native 函数断点（等价于 mem:<func>:x）
asprof -e strcmp -d 30 8983
```

---

## 七、Wall Clock 采样模式

### 7.1 为什么需要 Wall Clock？

**CPU 采样的盲区**：只能看到线程在 CPU 上**运行**的时间，看不到线程在**等待什么**。

**典型场景**：
- 应用启动慢，但 CPU 利用率很低 → 大量时间花在类加载/IO 上
- 接口响应慢，但 CPU 不高 → 线程在等锁/等数据库
- 线程池阻塞，但 CPU 空闲 → 线程全部 park

**Wall Clock 能看到**：不管线程状态是 Running/Sleeping/Blocked，**全部采样**。

### 7.2 基本用法

```bash
# Wall clock 采样，推荐配合 -t（按线程分组）
asprof -e wall -t -i 50ms -d 30 -f wall.html 8983
```

**关键参数**：
- `-t`（`--threads`）：强烈推荐！按线程分组，否则不同线程的阻塞会混在一起
- `-i 50ms`：采样间隔（Wall Clock 的间隔是真实时间，不是 CPU 时间）

### 7.3 CPU + Wall Clock 同时采集

```bash
# CPU 事件 + Wall Clock 同时采集（需要 JFR 输出）
asprof -e cpu --wall 100ms -f combined.jfr 8983
```

### 7.4 过滤特定线程

```bash
# 只采样指定线程
asprof -e wall -d 30 --filter 120-127,132,134 Computey
```

---

## 八、分配（Allocation）采样模式

### 8.1 基本用法

```bash
# 堆分配采样
asprof -e alloc -d 30 -f alloc.html 8983

# 指定采样间隔：每分配 500KB 采一次
asprof -e alloc --alloc 500k -d 30 -f alloc.html 8983

# 每分配 2MB 采一次（适合高频分配场景）
asprof --alloc 2m -d 30 -f alloc.html 8983
```

### 8.2 采样原理

async-profiler 使用 **TLAB 驱动采样**（不是字节码插桩！）：
- 当对象在**新创建的 TLAB** 中分配时，触发采样
- 当对象在 TLAB **外部慢路径**分配时，触发采样

**优势**：
- 不影响逃逸分析
- 不阻止 JIT 优化（如分配消除）
- 只采样实际堆分配

### 8.3 火焰图含义

在分配采样模式下：
- **顶部帧**：被分配对象的**类名**（如 `byte[]`、`java.lang.String`）
- **计数器**：堆压力（分配的 TLAB 总大小或 TLAB 外对象大小）

### 8.4 存活对象采样（内存泄漏检测）

```bash
# --live：只保留到采样结束时仍存活的对象
asprof -e alloc --live -d 60 -f leak.html 8983
```

**原理**：GC 回收后，只保留**未被回收**的分配样本 → 这些就是潜在的内存泄漏来源。

---

## 九、锁争用（Lock）采样模式

### 9.1 Java 锁争用

```bash
# Java Monitor + j.u.c 锁争用
asprof -e lock -t -d 30 -f lock.html 8983

# 指定阈值：只记录等待 > 10ms 的锁
asprof -e lock --lock 10ms -t -d 30 -f lock.html 8983
```

**火焰图含义**：
- **顶部帧**：锁对象的**类名**
- **计数器**：等待进入锁的**纳秒数**

### 9.2 原生锁争用（pthread）

```bash
# pthread_mutex_lock / pthread_rwlock_* 争用
asprof --nativelock 5ms -t -d 30 -f nativelock.html 8983
```

**拦截的 API**：
- `pthread_mutex_lock`
- `pthread_rwlock_rdlock`
- `pthread_rwlock_wrlock`

**关键区别**：Java 锁采样看的是 Java Monitor，原生锁采样看的是 JVM 内部和 native 库中的 pthread 锁。

---

## 十、原生内存（Native Memory）采样模式

### 10.1 基本用法

```bash
# 开始采样
asprof start -e nativemem -f app.jfr 8983

# 也可以指定采样间隔
asprof start --nativemem 1m -f app.jfr 8983

# 如果只关心分配不关心释放
asprof start --nativemem 1m --nofree -f app.jfr 8983

# ... 等待一段时间 ...

# 停止
asprof stop 8983
```

### 10.2 分析内存泄漏

```bash
# 生成泄漏报告（只显示未 free 的分配）
jfrconv --total --nativemem --leak app.jfr leak.html

# 查看所有原生分配（不做泄漏分析）
jfrconv --total --nativemem app.jfr alloc.html

# 自定义尾部忽略比例（默认 10%）
# 避免最后 20% 时间内的新分配被误报为泄漏
jfrconv --nativemem --leak --tail 20% app.jfr leak.html
```

### 10.3 LD_PRELOAD 方式（非 Java 应用）

```bash
# 对 C/C++ 应用做原生内存泄漏检测
LD_PRELOAD=/path/to/libasyncProfiler.so \
  ASPROF_COMMAND=start,nativemem,total,loop=10m,cstack=dwarf,file=profile-%t.jfr \
  NativeApp [args]

# 然后转换
jfrconv --total --nativemem --leak profile-*.jfr leak.html
```

---

## 十一、Java 方法追踪

### 11.1 追踪指定方法的所有调用

```bash
# 追踪 getProperty 的所有调用点
asprof -e java.util.Properties.getProperty -d 30 -f trace.html 8983
```

**注意**：只支持**非 native** Java 方法。追踪 native 方法请使用硬件断点：
```bash
asprof -e Java_java_lang_Throwable_fillInStackTrace -d 30 8983
```

### 11.2 耗时追踪（Latency Profiling）

```bash
# 只记录耗时 > 50ms 的调用
asprof --trace my.pkg.Class.Method:50ms -d 30 -f trace.jfr 8983
```

### 11.3 有用的 Native 函数追踪

```bash
# 追踪 G1 大对象分配
asprof -e G1CollectedHeap::humongous_obj_allocate -d 30 8983

# 追踪新线程创建
asprof -e JVM_StartThread -d 30 8983

# 追踪类加载
asprof -e Java_java_lang_ClassLoader_defineClass1 -d 30 8983
```

---

## 十二、多事件同时采集

### 12.1 基本用法（需要 JFR 格式）

```bash
# CPU + 分配 + 锁 同时采集
asprof -e cpu,alloc,lock -f profile.jfr 8983

# 等价写法（可指定各自阈值）
asprof -e cpu --alloc 2m --lock 10ms -f profile.jfr 8983

# CPU + Wall Clock 同时采集
asprof -e cpu --wall 100ms -f combined.jfr 8983
```

### 12.2 一键全开（`--all`）

```bash
# 开启 cpu + wall + alloc + live + lock + nativemem
asprof --all -f profile.jfr 8983

# 自定义各事件参数
asprof --all --alloc 2m --lock 10ms -f profile.jfr 8983

# 替换主事件类型
asprof --all -e cycles -f profile.jfr 8983
```

> ⚠️ **`--all` 不推荐在生产环境使用**，尤其是持续 Profiling。开销虽然仍然很低，但多事件同时采集会增加数据量。

### 12.3 与 JDK JFR 同步录制（最佳实践）

```bash
# async-profiler 采 CPU/分配/锁
# + JDK JFR 采 GC/IO/线程等事件
# → 合并到同一个 .jfr 文件
asprof -e cpu --jfrsync profile -f combined.jfr 8983
```

**JFR 配置选项**：
- `profile` — JDK 预定义的 profiling 配置
- `default` — JDK 预定义的默认配置
- 自定义 `.jfc` 文件路径
- `+EventName` — 指定开启的 JFR 事件

---

## 十三、持续 Profiling

### 13.1 基本用法

```bash
# 每小时输出一个 JFR 文件（文件名含时间戳）
asprof --loop 1h -f /var/log/profile-%t.jfr 8983

# 每 30 分钟
asprof --loop 30m -f /var/log/profile-%t.jfr 8983

# 指定时钟时间（每天 00:00:00 输出）
asprof --loop 24:00:00 -f /var/log/profile-%t.jfr 8983
```

> ⚠️ **务必**在文件名中包含 `%t`（时间戳）或 `%n{MAX}`（序号），否则每次循环会覆盖上一次的文件！

### 13.2 作为 Agent 持续 Profiling（推荐生产环境）

```bash
java -agentpath:libasyncProfiler.so=start,event=cpu,loop=1h,file=/var/log/profile-%t.jfr MyApp
```

### 13.3 Time-to-Safepoint 采样（TTSP）

```bash
# 只记录从 "请求 Safepoint" 到 "进入 Safepoint" 期间的事件
asprof --ttsp -e cpu -d 60 -f ttsp.html 8983

# 等价于
asprof --begin SafepointSynchronize::begin \
       --end RuntimeService::record_safepoint_synchronized \
       -e cpu -d 60 -f ttsp.html 8983
```

**用途**：定位哪些代码路径导致 Safepoint 延迟（Counted Loop、JNI 调用等）。

---

*→ 继续阅读 [Part 3：输出格式与高级特性](async_profiler_usage_guide_part3.md)*
