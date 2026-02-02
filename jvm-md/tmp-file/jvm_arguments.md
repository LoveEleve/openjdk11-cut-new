# JVM 日志系统与 -Xlog 参数完全指南

本文档整理了 OpenJDK 11 中的统一日志系统（Unified Logging）及其使用方法。

---

## 一、日志级别（Log Levels）

JVM 日志系统支持 5 个级别，从低到高：

| 级别 | 宏定义 | 说明 | 输出量 |
|------|--------|------|--------|
| `trace` | `log_trace()` | 最详细的跟踪信息 | 最多 |
| `debug` | `log_debug()` | 调试信息 | 较多 |
| `info` | `log_info()` | 一般信息（默认级别） | 中等 |
| `warning` | `log_warning()` | 警告信息 | 较少 |
| `error` | `log_error()` | 错误信息 | 最少 |

### 开发版专用宏（仅 debug/slowdebug 构建有效）

```cpp
log_develop_trace(tag1, tag2)("message");  // 仅非 PRODUCT 构建
log_develop_debug(tag1, tag2)("message");
log_develop_info(tag1, tag2)("message");
```

---

## 二、日志标签（Log Tags）完整列表

以下是 JVM 中所有可用的日志标签（来自 `logTag.hpp`）：

### GC 相关标签

| 标签 | 说明 | 示例参数 |
|------|------|----------|
| `gc` | GC 主标签 | `-Xlog:gc=info` |
| `heap` | 堆内存操作 | `-Xlog:gc+heap=debug` |
| `alloc` | 内存分配 | `-Xlog:gc+alloc=trace` |
| `age` | 对象年龄/晋升 | `-Xlog:gc+age=debug` |
| `barrier` | 屏障操作 | `-Xlog:gc+barrier=trace` |
| `bot` | Block Offset Table | `-Xlog:gc+bot=debug` |
| `cset` | Collection Set | `-Xlog:gc+cset=debug` |
| `ergo` | 自适应调优决策 | `-Xlog:gc+ergo=debug` |
| `freelist` | 空闲列表 | `-Xlog:gc+freelist=debug` |
| `humongous` | 大对象处理 | `-Xlog:gc+humongous=debug` |
| `ihop` | Initiating Heap Occupancy Percent | `-Xlog:gc+ihop=debug` |
| `liveness` | 存活性分析 | `-Xlog:gc+liveness=debug` |
| `mark` | 标记阶段 | `-Xlog:gc+mark=debug` |
| `marking` | 标记过程 | `-Xlog:gc+marking=trace` |
| `mmu` | Minimum Mutator Utilization | `-Xlog:gc+mmu=debug` |
| `phases` | GC 阶段 | `-Xlog:gc+phases=debug` |
| `plab` | Promotion LAB | `-Xlog:gc+plab=debug` |
| `promotion` | 对象晋升 | `-Xlog:gc+promotion=debug` |
| `ref` | 引用处理 | `-Xlog:gc+ref=debug` |
| `refine` | 并发优化 | `-Xlog:gc+refine=debug` |
| `region` | Region 管理 | `-Xlog:gc+region=debug` |
| `remset` | Remembered Set | `-Xlog:gc+remset=debug` |
| `scavenge` | Minor GC | `-Xlog:gc+scavenge=debug` |
| `start` | GC 启动 | `-Xlog:gc+start=debug` |
| `stats` | GC 统计 | `-Xlog:gc+stats=debug` |
| `stringdedup` | 字符串去重 | `-Xlog:gc+stringdedup=debug` |
| `survivor` | Survivor 区 | `-Xlog:gc+survivor=debug` |
| `sweep` | 清除阶段 | `-Xlog:gc+sweep=debug` |
| `task` | GC 任务 | `-Xlog:gc+task=debug` |
| `tlab` | Thread Local Allocation Buffer | `-Xlog:gc+tlab=debug` |
| `workgang` | 工作线程组 | `-Xlog:gc+workgang=debug` |

### 类加载相关标签

| 标签 | 说明 | 示例参数 |
|------|------|----------|
| `class` | 类操作 | `-Xlog:class+load=info` |
| `load` | 类加载 | `-Xlog:class+load=debug` |
| `unload` | 类卸载 | `-Xlog:class+unload=info` |
| `loader` | 类加载器 | `-Xlog:class+loader=debug` |
| `resolve` | 类解析 | `-Xlog:class+resolve=debug` |
| `init` | 类初始化 | `-Xlog:class+init=debug` |
| `preorder` | 类预加载顺序 | `-Xlog:class+preorder=debug` |

### JIT 编译相关标签

| 标签 | 说明 | 示例参数 |
|------|------|----------|
| `compilation` | 编译过程 | `-Xlog:jit+compilation=debug` |
| `inlining` | 方法内联 | `-Xlog:jit+inlining=debug` |
| `codecache` | 代码缓存 | `-Xlog:codecache=debug` |
| `nmethod` | 编译方法 | `-Xlog:nmethod=debug` |

### 线程与同步相关标签

| 标签 | 说明 | 示例参数 |
|------|------|----------|
| `thread` | 线程操作 | `-Xlog:thread=debug` |
| `safepoint` | 安全点 | `-Xlog:safepoint=debug` |
| `vmthread` | VM 线程 | `-Xlog:vmthread=debug` |
| `vmoperation` | VM 操作 | `-Xlog:vmoperation=debug` |
| `handshake` | 线程握手 | `-Xlog:handshake=debug` |
| `biasedlocking` | 偏向锁 | `-Xlog:biasedlocking=debug` |
| `monitorinflation` | 锁膨胀 | `-Xlog:monitorinflation=debug` |

### 内存管理相关标签

| 标签 | 说明 | 示例参数 |
|------|------|----------|
| `metaspace` | 元空间 | `-Xlog:metaspace=debug` |
| `metadata` | 元数据 | `-Xlog:metadata=debug` |
| `oops` | OOP 操作 | `-Xlog:oops=debug` |
| `coops` | 压缩指针 | `-Xlog:coops=debug` |
| `oom` | 内存溢出 | `-Xlog:oom=debug` |

### 其他常用标签

| 标签 | 说明 | 示例参数 |
|------|------|----------|
| `os` | 操作系统交互 | `-Xlog:os=debug` |
| `jni` | JNI 调用 | `-Xlog:jni=debug` |
| `jvmti` | JVMTI 操作 | `-Xlog:jvmti=debug` |
| `arguments` | JVM 参数解析 | `-Xlog:arguments=debug` |
| `exceptions` | 异常处理 | `-Xlog:exceptions=debug` |
| `module` | 模块系统 | `-Xlog:module=debug` |
| `verification` | 字节码验证 | `-Xlog:verification=debug` |

---

## 三、-Xlog 参数格式

### 基本格式

```
-Xlog:[tag1][+tag2...][*][=level][:[output][:[decorators][:output-options]]]
```

### 常用示例

```bash
# 基础 GC 日志
-Xlog:gc=info

# GC 详细日志（所有 gc 相关标签）
-Xlog:gc*=info

# 特定组合标签
-Xlog:gc+heap=debug
-Xlog:gc+marking=trace

# 多个日志配置
-Xlog:gc=info -Xlog:class+load=debug

# 输出到文件
-Xlog:gc*=info:file=gc.log

# 带时间戳装饰器
-Xlog:gc*=info:stdout:time,level,tags

# 文件轮转
-Xlog:gc*=info:file=gc.log:time,level,tags:filecount=5,filesize=10M
```

### 装饰器（Decorators）

| 装饰器 | 说明 |
|--------|------|
| `time` | 当前时间（ISO-8601 格式） |
| `utctime` | UTC 时间 |
| `uptime` | JVM 启动后的时间 |
| `timemillis` | 毫秒时间戳 |
| `uptimemillis` | 启动后毫秒数 |
| `timenanos` | 纳秒时间戳 |
| `uptimenanos` | 启动后纳秒数 |
| `pid` | 进程 ID |
| `tid` | 线程 ID |
| `level` | 日志级别 |
| `tags` | 标签名称 |

---

## 四、G1 GC 调试常用参数组合

### 4.1 基础监控

```bash
# GC 基本信息
-Xlog:gc=info

# GC 详细信息 + 堆信息
-Xlog:gc*=info -Xlog:gc+heap=debug
```

### 4.2 并发标记调试

```bash
# 并发标记过程
-Xlog:gc+marking=debug

# 标记栈操作
-Xlog:gc+mark=trace

# 工作线程组（WorkGang）
-Xlog:gc+workgang=debug

# Remembered Set
-Xlog:gc+remset=debug
```

### 4.3 Region 和堆管理

```bash
# Region 分配/释放
-Xlog:gc+region=debug

# 大对象（Humongous）
-Xlog:gc+humongous=debug

# TLAB 分配
-Xlog:gc+tlab=trace
```

### 4.4 完整调试配置

```bash
# 完整的 G1 GC 调试配置
-Xlog:gc*=debug:file=gc_debug.log:time,level,tags:filecount=10,filesize=50M
```

---

## 五、代码中的日志宏使用

### 源码中的用法

```cpp
// 单标签
log_info(gc)("GC pause %s", "young");

// 多标签组合
log_debug(gc, heap)("Heap size: " SIZE_FORMAT, heap_size);

// 带条件检查
if (log_is_enabled(Debug, gc, marking)) {
    log_debug(gc, marking)("Marking started");
}

// 开发版专用（仅 debug 构建）
log_develop_trace(gc, workgang)("Worker %d started", id);
```

### 你遇到的示例

```cpp
// workgroup.cpp 中的日志
log_develop_trace(gc, workgang)("Constructing work gang %s with %u threads", name(), total_workers());
```

要看到这条日志，需要：
1. 使用 **slowdebug** 或 **fastdebug** 构建（非 product）
2. 添加参数：`-Xlog:gc+workgang=trace`

---

## 六、快速查看所有可用标签

运行以下命令查看当前 JVM 支持的所有日志配置：

```bash
java -Xlog:help
```

输出会列出所有可用的：
- 日志标签（tags）
- 日志级别（levels）
- 装饰器（decorators）
- 输出选项（output options）

---

## 七、你的 java.c 参数注入配置参考

```c
static const char* DEBUG_INJECTED_ARGS[] = {
    // 堆配置
    "-Xms8g",
    "-Xmx8g",
    "-XX:+UseG1GC",
    
    // === GC 日志配置（按需启用） ===
    
    // 基础 GC 日志
    // "-Xlog:gc=info",
    
    // GC + 堆详情
    // "-Xlog:gc+heap=debug",
    
    // 并发标记
    // "-Xlog:gc+marking=trace",
    
    // 工作线程组
    // "-Xlog:gc+workgang=trace",
    
    // Region 管理
    // "-Xlog:gc+region=debug",
    
    // Remembered Set
    // "-Xlog:gc+remset=debug",
    
    // 完整 GC 调试（输出较多）
    // "-Xlog:gc*=debug",
    
    // === 类加载日志 ===
    // "-Xlog:class+load=info",
    // "-Xlog:class+unload=info",
    
    // === 安全点日志 ===
    // "-Xlog:safepoint=debug",
    
    // === 线程日志 ===
    // "-Xlog:thread=debug",
};
```

---

## 八、常见问题

### Q: 为什么 `log_develop_trace` 在 release 版本不输出？

A: `log_develop_*` 宏在 `PRODUCT` 构建中被定义为空操作，只有 debug/slowdebug 构建才会输出。

### Q: `-Xlog:gc*` 和 `-Xlog:gc` 的区别？

A: 
- `-Xlog:gc` 只匹配单独的 `gc` 标签
- `-Xlog:gc*` 匹配所有以 `gc` 开头的标签组合（如 `gc+heap`, `gc+marking` 等）

### Q: 如何同时输出到控制台和文件？

```bash
-Xlog:gc=info:stdout -Xlog:gc*=debug:file=gc.log
```
