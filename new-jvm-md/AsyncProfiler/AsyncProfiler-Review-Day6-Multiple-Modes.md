# Day 6：多种采样模式 - 复习卡片

> 复习目标：掌握四种采样模式的原理、实现、适用场景
> 学习时间：2-3 小时
> 完成标准：通过 4 个自测问题

---

## 知识索引

Day 6 的技术内容已整合到以下 Deep Dive 文档中，本卡片仅保留面试问答、自测、完成标准等复习内容：

| 主题 | Deep Dive 文档 | 对应内容 |
|------|---------------|----------|
| CPU Profiling 原理与实现 | [05-CPU-Profiling-PerfEvents-Deep-Dive.md](05-CPU-Profiling-PerfEvents-Deep-Dive.md) | CPU 采样模式完整分析 |
| Allocation Profiling 原理 | [06-Allocation-Profiling-Deep-Dive.md](06-Allocation-Profiling-Deep-Dive.md) | 内存分配采样完整分析 |
| Lock Profiling 原理 | [07-Lock-Profiling-Deep-Dive.md](07-Lock-Profiling-Deep-Dive.md) | 锁竞争采样完整分析 |
| WallClock Profiling 原理 | [12-WallClock-Profiling-Deep-Dive.md](12-WallClock-Profiling-Deep-Dive.md) | 挂钟采样完整分析 |
| Profiler 控制器与引擎协调 | [08-Profiler-Core-Controller-Deep-Dive.md](08-Profiler-Core-Controller-Deep-Dive.md) | 多引擎统一协调 |

---

## 一、面试实战演练

### 1.1 问题 1：四种采样模式各有什么特点？

**标准回答**：

**第一层（概述）**：
四种模式针对不同类型的性能问题：CPU（CPU 热点）、Allocation（内存分配）、Lock（锁竞争）、WallClock（I/O 阻塞）。

**第二层（详细对比）**：

| 模式 | 事件类型 | 实现方式 | 开销 | 适用场景 |
|------|---------|---------|------|---------|
| **CPU** | CPU 周期 | perf_event | < 1% | CPU 热点分析 |
| **Allocation** | 对象分配 | JVM 插桩 | 2-5% | 内存瓶颈、GC 压力 |
| **Lock** | 锁竞争 | JVMTI 事件 | 1-3% | 锁优化 |
| **WallClock** | 挂钟时间 | 定时信号 | 1-2% | I/O 阻塞 |

**第三层（选择策略）**：
- CPU 占用高 → CPU 模式
- GC 频繁 → Allocation 模式
- 响应慢（锁多）→ Lock 模式
- 响应慢（I/O 多）→ WallClock 模式

---

### 1.2 问题 2：CPU Profiling 和 Wall Clock Profiling 有什么区别？

**标准回答**：

**第一层（核心区别）**：
CPU Profiling 只采样正在使用 CPU 的线程，Wall Clock Profiling 采样所有活跃线程（包括等待的）。

**第二层（详细对比）**：

| 维度 | CPU Profiling | Wall Clock Profiling |
|------|--------------|---------------------|
| **触发条件** | CPU 周期溢出 | 定时器到期 |
| **采样对象** | 正在执行 CPU 的线程 | 所有活跃线程 |
| **包含内容** | CPU 时间 | CPU + 等待 + I/O |
| **火焰图宽度** | CPU 占比 | 总时间占比 |
| **适用场景** | CPU 热点 | I/O 阻塞、整体吞吐 |

**第三层（实例说明）**：

```java
// CPU Profiling 重点采样
public void cpuIntensive() {
    for (int i = 0; i < 10000000; i++) {
        sum += i;  // CPU 密集
    }
}

// Wall Clock Profiling 重点采样
public void ioIntensive() {
    Thread.sleep(1000);  // 等待 I/O
}
```

**第四层（选择建议）**：
- 分析 CPU 占用率 → CPU Profiling
- 分析响应时间 → Wall Clock Profiling
- 综合分析 → 两者结合

---

### 1.3 问题 3：Allocation Profiling 如何避免影响性能？

**标准回答**：

**第一层（核心策略）**：
使用概率采样，而不是记录每次分配。

**第二层（采样机制）**：

```cpp
// 每 N 字节分配采样一次
should_sample(alloc_size) {
    _bytes_since_last_sample += alloc_size;
    if (_bytes_since_last_sample >= _sample_interval) {
        _bytes_since_last_sample = 0;
        return true;  // 采样
    }
    return false;  // 不采样
}
```

**第三层（参数调整）**：

```bash
# 低开销（生产环境）
asprof -e alloc:1m <pid>  # 每 1 MB 采样一次

# 中等开销（默认）
asprof -e alloc:256k <pid>  # 每 256 KB 采样一次

# 高精度（开发测试）
asprof -e alloc:64k <pid>  # 每 64 KB 采样一次
```

**第四层（开销控制）**：

| 采样间隔 | 开销 | 精度 |
|---------|------|------|
| 1 MB | 1-2% | 低 |
| 256 KB（默认） | 2-5% | 中 |
| 64 KB | 5-10% | 高 |

---

### 1.4 问题 4：如何综合使用多种模式定位性能问题？

**标准回答**：

**第一层（分析流程）**：

```
1. CPU Profiling → 找 CPU 热点
2. Allocation Profiling → 找内存瓶颈
3. Lock Profiling → 找锁竞争
4. Wall Clock Profiling → 找阻塞点
```

**第二层（组合分析）**：

**CPU + Allocation**：
```
CPU 高 + 分配少 → 计算密集 → 优化算法
CPU 低 + 分配高 → 内存瓶颈 → 减少分配
```

**CPU + Lock**：
```
CPU 显示锁竞争多 → 优化锁粒度
CPU 显示计算密集 → 优化算法
```

**Wall Clock + CPU**：
```
Wall Clock 高 + CPU 低 → I/O 瓶颈 → 异步化
Wall Clock ≈ CPU → CPU 瓶颈 → 优化计算
```

**第三层（实例应用）**：

**场景**：应用响应慢

```bash
# 1. Wall Clock Profiling
asprof -d 60 -e wall -f wall.html <pid>

# 分析：发现 socket.read() 占比高

# 2. CPU Profiling
asprof -d 60 -f cpu.html <pid>

# 分析：CPU 占比正常

# 结论：I/O 瓶颈，考虑异步化
```

---

## 二、自测环节（必须通过）

### 自测 1：四种模式对比

**Q**: 请对比四种采样模式的特点和适用场景。

<details>
<summary>点击查看答案</summary>

**A**:

| 模式 | 事件类型 | 实现方式 | 开销 | 适用场景 |
|------|---------|---------|------|---------|
| **CPU** | CPU 周期 | perf_event | < 1% | CPU 热点分析 |
| **Allocation** | 对象分配 | JVM 插桩 | 2-5% | 内存瓶颈、GC 压力 |
| **Lock** | 锁竞争 | JVMTI 事件 | 1-3% | 锁优化 |
| **WallClock** | 挂钟时间 | 定时信号 | 1-2% | I/O 阻塞 |

**选择策略**：
- CPU 占用高 → CPU 模式
- GC 频繁 → Allocation 模式
- 响应慢（锁多）→ Lock 模式
- 响应慢（I/O 多）→ WallClock 模式
</details>

---

### 自测 2：CPU vs Wall Clock

**Q**: CPU Profiling 和 Wall Clock Profiling 有什么区别？何时使用？

<details>
<summary>点击查看答案</summary>

**A**:

**核心区别**：
- CPU Profiling：只采样正在使用 CPU 的线程
- Wall Clock Profiling：采样所有活跃线程（包括等待的）

**详细对比**：

| 维度 | CPU Profiling | Wall Clock Profiling |
|------|--------------|---------------------|
| **触发条件** | CPU 周期溢出 | 定时器到期 |
| **采样对象** | 正在执行 CPU 的线程 | 所有活跃线程 |
| **包含内容** | CPU 时间 | CPU + 等待 + I/O |

**使用场景**：
- 分析 CPU 占用率 → CPU Profiling
- 分析响应时间 → Wall Clock Profiling
- 分析 I/O 阻塞 → Wall Clock Profiling

**组合使用**：
- Wall Clock 高 + CPU 低 → I/O 瓶颈
- Wall Clock ≈ CPU → CPU 瓶颈
</details>

---

### 自测 3：Allocation Profiling

**Q**: Allocation Profiling 如何实现？如何控制开销？

<details>
<summary>点击查看答案</summary>

**A**:

**实现方式**：
- JDK 7-17：Trap 机制（INT3 断点）
- JDK 17+：TLAB 钩子

**采样机制**：
```cpp
// 每 N 字节分配采样一次
if (bytes_since_last_sample >= sample_interval) {
    sample();
    bytes_since_last_sample = 0;
}
```

**开销控制**：
```bash
# 低开销（生产环境）
asprof -e alloc:1m <pid>  # 每 1 MB 采样

# 默认开销
asprof -e alloc:256k <pid>  # 每 256 KB 采样

# 高精度（开发测试）
asprof -e alloc:64k <pid>  # 每 64 KB 采样
```

**开销对比**：

| 采样间隔 | 开销 |
|---------|------|
| 1 MB | 1-2% |
| 256 KB | 2-5% |
| 64 KB | 5-10% |
</details>

---

### 自测 4：组合使用

**Q**: 如何综合使用多种模式定位性能问题？

<details>
<summary>点击查看答案</summary>

**A**:

**分析流程**：
```
1. CPU Profiling → 找 CPU 热点
2. Allocation Profiling → 找内存瓶颈
3. Lock Profiling → 找锁竞争
4. Wall Clock Profiling → 找阻塞点
```

**组合分析**：

**CPU + Allocation**：
- CPU 高 + 分配少 → 计算密集 → 优化算法
- CPU 低 + 分配高 → 内存瓶颈 → 减少分配

**CPU + Lock**：
- CPU 显示锁竞争多 → 优化锁粒度
- CPU 显示计算密集 → 优化算法

**Wall Clock + CPU**：
- Wall Clock 高 + CPU 低 → I/O 瓶颈 → 异步化
- Wall Clock ≈ CPU → CPU 瓶颈 → 优化计算

**实例**：
```bash
# 1. Wall Clock Profiling（找整体瓶颈）
asprof -d 60 -e wall -f wall.html <pid>

# 2. CPU Profiling（找 CPU 热点）
asprof -d 60 -f cpu.html <pid>

# 3. 根据结果选择优化方向
```
</details>

---

## 三、Day 6 完成标准

通过 Day 6 的标准是：

- [ ] 能说明四种采样模式的原理和实现
- [ ] 能对比四种模式的适用场景
- [ ] 能解释 CPU Profiling 和 Wall Clock 的区别
- [ ] 能说明 Allocation Profiling 的采样机制
- [ ] 能综合使用多种模式定位问题
- [ ] 通过所有 4 个自测问题

---

## 四、扩展阅读（追求极致深度）

### 4.1 相关源码

**CPU Profiling**：
- `engine.cpp`：perf_event 实现
- `perfEvents.cpp`：perf_event 封装

**Allocation Profiling**：
- `allocTracer.cpp`：JVM 分配路径插桩
- `allocTracer.h`：分配追踪接口

**Lock Profiling**：
- `jvmtiEnv.cpp`：JVMTI 事件处理

**Wall Clock Profiling**：
- `wallClock.cpp`：定时器线程实现

### 4.2 实战工具

**查看当前采样模式**：
```bash
# 查看支持的采样模式
asprof --help | grep -A10 "Event types"
```

**组合使用示例**：
```bash
# 综合分析脚本
for event in cpu alloc lock wall; do
    asprof -d 60 -e $event -f ${event}_$(date +%s).html <pid>
    sleep 5
done
```

---

## 五、Day 6 总结

### 核心知识点

```
多种采样模式
├─ CPU Profiling
│  ├─ 实现：perf_event 硬件计数器
│  ├─ 开销：< 1%
│  └─ 适用：CPU 热点分析
├─ Allocation Profiling
│  ├─ 实现：JVM 插桩 + 概率采样
│  ├─ 开销：2-5%
│  └─ 适用：内存瓶颈、GC 压力
├─ Lock Profiling
│  ├─ 实现：JVMTI MonitorWait/MonitorEntered
│  ├─ 开销：1-3%
│  └─ 适用：锁优化
├─ Wall Clock Profiling
│  ├─ 实现：独立定时器线程 + 信号广播
│  ├─ 开销：1-2%
│  └─ 适用：I/O 阻塞、整体吞吐
└─ 组合策略
   ├─ CPU + Allocation → 计算密集 vs 内存瓶颈
   ├─ CPU + Lock → CPU 热点 vs 锁竞争
   └─ Wall Clock + CPU → I/O 瓶颈 vs CPU 瓶颈
```

### 面试要点

1. **对比分析**：能对比四种模式的原理和适用场景
2. **区别理解**：能解释 CPU vs Wall Clock 的区别
3. **开销控制**：能说明 Allocation 的采样机制
4. **综合应用**：能组合使用多种模式定位问题

### 下一步

Day 6 完成后，进入 **Day 7：火焰图解读 + 实战演练**，学习：
- 火焰图的结构和含义
- 如何解读火焰图
- 定位性能瓶颈
- 实战演练

---

**Day 6 完成！准备好进入 Day 7 了吗？**
