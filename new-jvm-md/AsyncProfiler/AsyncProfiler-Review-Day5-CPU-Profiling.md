# Day 5：CPU Profiling 深入 - 复习卡片

> 复习目标：完全掌握 perf_event 机制、硬件计数器、信号处理流程
> 学习时间：2-3 小时
> 完成标准：通过 4 个自测问题

---

## 知识索引

详细技术内容请参考源码分析文档：
- CPU Profiling 完整源码分析 → `05-CPU-Profiling-PerfEvents-Deep-Dive.md`
- Profiler 采样控制 → `08-Profiler-Core-Controller-Deep-Dive.md`
- CallTrace 存储 → `09-CallTraceStorage-Deep-Dive.md`

---

## 一、面试实战演练

### 1.1 问题 1：perf_event 采样的原理是什么？

**标准回答**：

**第一层（核心原理）**：
perf_event 利用 CPU 的硬件性能计数器进行精确采样。当计数器溢出时，内核发送信号，触发栈回溯。

**第二层（详细流程）**：

```
1. perf_event_open：创建内核对象，配置事件和采样周期
2. mmap：映射共享内存，用于零拷贝读取采样数据
3. fcntl：配置异步信号通知（SIGPROF）
4. ioctl：启用事件
5. 硬件计数：CPU 开始计数硬件事件
6. 溢出中断：计数器溢出时，内核发送 SIGPROF
7. 信号处理：栈回溯并记录样本
8. 重置并继续：重置计数器，继续监控
```

**第三层（技术细节）**：

**硬件计数器**：
- CPU 内置性能监控单元（PMU）
- 计数特定事件（如 CPU 周期、指令数）
- 溢出时触发中断

**内核处理**：
- 捕获硬件中断
- 保存上下文（寄存器、栈指针）
- 发送信号给目标进程

**第四层（优势）**：
- 精确：基于真实硬件事件
- 低开销：硬件计数，内核只处理溢出
- 准确：反映真实 CPU 使用

---

### 1.2 问题 2：perf_event 为什么需要 CAP_SYS_ADMIN 权限？

**标准回答**：

**第一层（直接回答）**：
为了安全，防止侧信道攻击和内核信息泄露。

**第二层（详细原因）**：

**1. 侧信道攻击风险**：
```
通过精确的时序测量，攻击者可以：
- 推断敏感数据
- 绕过 KASLR
- 实施 Spectre/Meltdown 类攻击
```

**2. 内核地址泄露**：
```
如果 exclude_kernel = 0：
- 采样包含内核地址
- 可能泄露内核布局信息
- 绕过地址空间布局随机化（ASLR）
```

**第三层（解决方案）**：

**方案 1：调整 perf_event_paranoid**
```bash
echo 0 > /proc/sys/kernel/perf_event_paranoid
```

**方案 2：排除内核态**
```cpp
attr.exclude_kernel = 1;  // 无需权限
```

**方案 3：使用其他采样方式**
```cpp
// CTimer 或 ITimer，无需权限
```

---

### 1.3 问题 3：三种采样方式有什么区别？如何选择？

**标准回答**：

**第一层（概述）**：
三种方式按精度和权限要求排序：PerfEvents > CTimer > ITimer。

**第二层（详细对比）**：

| 方式 | 实现 | 精度 | 开销 | 权限 |
|------|------|------|------|------|
| **PerfEvents** | 硬件计数器 | 最高 | < 1% | CAP_SYS_ADMIN |
| **CTimer** | 高精度定时器 | 高 | ~1.2% | 无 |
| **ITimer** | 传统定时器 | 中 | ~2.1% | 无 |

**第三层（选择策略）**：

```cpp
int chooseMethod() {
    // 1. 尝试 PerfEvents（最佳）
    if (hasPermission() && tryPerfEvents()) {
        return PERF_EVENTS;
    }
    
    // 2. 尝试 CTimer（次佳）
    if (tryCTimer()) {
        return CTIMER;
    }
    
    // 3. 使用 ITimer（后备）
    return ITIMER;
}
```

**第四层（适用场景）**：

- **PerfEvents**：生产环境（有权限），需要最高精度
- **CTimer**：容器环境，无权限但需要较高精度
- **ITimer**：受限环境，兼容性要求高

---

### 1.4 问题 4：如何优化 perf_event 采样的性能？

**标准回答**：

**第一层（核心原则）**：
减少信号处理器的工作量，避免阻塞和内存分配。

**第二层（具体优化）**：

**1. 批量处理**：
```cpp
// 不要每次都写入，批量写入
_buffer.add(sample);
if (_buffer.full()) {
    _writer->write(_buffer);
}
```

**2. 无锁数据结构**：
```cpp
// 避免锁竞争
LockFreeQueue queue;
queue.push(sample);
```

**3. 预分配内存**：
```cpp
// 启动时分配，避免信号处理器中分配
_samples = new Sample[MAX];
```

**4. 减少信号处理器工作量**：
```cpp
// 只做栈回溯，其他工作放到主线程
void signalHandler(...) {
    AsyncGetCallTrace(...);  // 栈回溯
    _buffer.add(trace);      // 添加到缓冲区
    // 其他工作在主线程做
}
```

**第三层（效果量化）**：

| 优化措施 | 开销降低 |
|---------|---------|
| 批量处理 | -30% |
| 无锁队列 | -20% |
| 预分配内存 | -10% |
| 简化信号处理器 | -15% |

**第四层（最终效果）**：
- 优化前：1-2% 开销
- 优化后：< 1% 开销

---

## 二、自测环节（必须通过）

### 自测 1：perf_event_open

**Q**: perf_event_open 的关键参数有哪些？各有什么作用？

<details>
<summary>点击查看答案</summary>

**A**:

```cpp
int perf_event_open(struct perf_event_attr *attr,
                    pid_t pid,
                    int cpu,
                    int group_fd,
                    unsigned long flags);
```

**参数**：
- `attr`：事件属性配置
  - `type`：事件类型（HARDWARE/SOFTWARE）
  - `config`：具体事件（CPU_CYCLES）
  - `sample_period`：采样周期
  - `exclude_kernel`：是否排除内核态
  
- `pid`：监控的进程 ID
- `cpu`：监控的 CPU 核心（-1 表示所有）
- `group_fd`：分组文件描述符（-1 表示独立）
- `flags`：标志位

**返回值**：
- 成功：文件描述符（> 0）
- 失败：-1（设置 errno）
</details>

---

### 自测 2：硬件计数器

**Q**: 常用的硬件性能计数器事件有哪些？如何选择采样周期？

<details>
<summary>点击查看答案</summary>

**A**:

**常用事件**：
- CPU_CYCLES：CPU 周期数（CPU 热点分析）
- INSTRUCTIONS：指令数（CPI 分析）
- CACHE_MISSES：缓存未命中（缓存优化）
- BRANCH_MISSES：分支预测失败（分支优化）

**采样周期选择**：

| 场景 | 周期 | 频率 | 开销 |
|------|------|------|------|
| 生产环境 | 20,000,000 | ~50 Hz | < 0.5% |
| 开发测试 | 10,000,000 | ~100 Hz | ~1% |
| 精细分析 | 1,000,000 | ~1000 Hz | ~5% |

**选择原则**：
- CPU 密集：可用较长周期
- I/O 密集：需要较短周期
- 平衡精度和开销
</details>

---

### 自测 3：三种采样方式

**Q**: PerfEvents、CTimer、ITimer 三种方式各有什么优缺点？

<details>
<summary>点击查看答案</summary>

**A**:

| 方式 | 实现 | 优点 | 缺点 |
|------|------|------|------|
| **PerfEvents** | 硬件计数器 | 精确、低开销 | 需要权限 |
| **CTimer** | 高精度定时器 | 无需权限、精度高 | 开销稍高 |
| **ITimer** | 传统定时器 | 最通用、无需权限 | 精度低、开销高 |

**选择策略**：
1. 优先尝试 PerfEvents（最佳）
2. 失败则尝试 CTimer（次佳）
3. 最后使用 ITimer（后备）

**适用场景**：
- PerfEvents：生产环境（有权限）
- CTimer：容器环境（无权限）
- ITimer：受限环境（兼容性要求高）
</details>

---

### 自测 4：性能优化

**Q**: 如何优化 perf_event 采样的性能？有哪些具体措施？

<details>
<summary>点击查看答案</summary>

**A**:

**核心原则**：减少信号处理器工作量，避免阻塞和内存分配。

**具体措施**：

1. **批量处理**：
   - 缓冲样本，批量写入
   - 减少系统调用次数

2. **无锁数据结构**：
   - 使用无锁队列
   - 避免锁竞争

3. **预分配内存**：
   - 启动时分配
   - 避免信号处理器中分配

4. **简化信号处理器**：
   - 只做栈回溯
   - 其他工作在主线程做

**效果**：
- 优化前：1-2% 开销
- 优化后：< 1% 开销
</details>

---

## 三、Day 5 完成标准

通过 Day 5 的标准是：

- [ ] 能说明 perf_event 的作用和原理
- [ ] 能描述 perf_event_attr 的关键参数
- [ ] 能说明硬件计数器的事件类型和选择
- [ ] 能对比三种采样方式的优缺点
- [ ] 能解释权限要求和解决方案
- [ ] 能说明性能优化的具体措施
- [ ] 通过所有 4 个自测问题

---

## 四、扩展阅读（追求极致深度）

### 4.1 Linux 内核文档

**必读文档**：
- `man perf_event_open`
- `Documentation/admin-guide/perf-security.rst`
- `tools/perf/Documentation/`

### 4.2 相关源码

**内核源码**：
- `kernel/events/core.c`：perf_event 核心实现
- `kernel/events/ring_buffer.c`：环形缓冲区
- `arch/x86/events/core.c`：x86 PMU 支持

### 4.3 实战工具

**查看 perf_event 支持的事件**：
```bash
# 查看硬件事件
perf list hw

# 查看软件事件
perf list sw

# 查看缓存事件
perf list cache
```

**查看当前 perf_event_paranoid 设置**：
```bash
cat /proc/sys/kernel/perf_event_paranoid
```

**使用 perf 工具测试**：
```bash
# 测试 perf_event 是否可用
perf stat ls

# 性能分析
perf record -g ./myapp
perf report
```

---

## 五、Day 5 总结

### 核心知识点

```
CPU Profiling 深入
├─ perf_event 系统调用
│  ├─ perf_event_open 参数
│  ├─ perf_event_attr 配置
│  └─ 工作流程
├─ 硬件计数器
│  ├─ 事件类型：CPU_CYCLES、INSTRUCTIONS
│  ├─ 采样周期选择
│  └─ 精确度控制（precise_ip）
├─ 三种采样方式
│  ├─ PerfEvents：硬件计数器（最佳）
│  ├─ CTimer：高精度定时器（次佳）
│  └─ ITimer：传统定时器（后备）
├─ 权限要求
│  ├─ CAP_SYS_ADMIN
│  ├─ perf_event_paranoid
│  └─ exclude_kernel
└─ 性能优化
   ├─ 批量处理
   ├─ 无锁数据结构
   ├─ 预分配内存
   └─ 简化信号处理器
```

### 面试要点

1. **原理**：能说明 perf_event 的工作原理
2. **配置**：能描述关键参数的含义
3. **对比**：能对比三种采样方式
4. **优化**：能说明性能优化措施

### 下一步

Day 5 完成后，进入 **Day 6：多种采样模式**，学习：
- CPU / Allocation / Lock / WallClock 四种模式
- 每种模式的原理和实现
- 适用场景对比

---

**Day 5 完成！准备好进入 Day 6 了吗？**
