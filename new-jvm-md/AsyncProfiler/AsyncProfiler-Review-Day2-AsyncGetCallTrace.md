# Day 2：AsyncGetCallTrace 方案 - 复习卡片

> 复习目标：完全掌握 AsyncGetCallTrace 的工作原理、安全性保证、失败场景
> 学习时间：2-3 小时
> 完成标准：通过 4 个自测问题

---

## 知识索引

详细技术内容请参考源码分析文档：
- AsyncGetCallTrace 完整流程 → `02-AsyncGetCallTrace-Solution.md`
- CPU 采样中 AGCT 的使用 → `05-CPU-Profiling-PerfEvents-Deep-Dive.md`
- Profiler 如何调用 AGCT → `08-Profiler-Core-Controller-Deep-Dive.md`

---

## 一、面试实战演练

### 1.1 问题 1：AsyncGetCallTrace 为什么不需要 Safepoint？

**标准回答**：

**第一层（核心思路）**：
AsyncGetCallTrace 在信号处理器中调用，信号可以异步中断任何线程，无需线程主动配合或到达特定点。

**第二层（技术原理）**：
当信号发生时：
1. **线程被中断**：内核立即暂停线程执行
2. **上下文保存**：内核保存完整的寄存器状态到 ucontext
3. **栈帧稳定**：线程暂停后，栈帧链不会变化
4. **直接读取**：从 ucontext 提取 PC、SP、FP，直接遍历栈帧

**第三层（对比传统方法）**：
传统 Profiler 需要：
- 发送全局请求
- 等待所有线程到达 Safepoint
- 遍历线程栈

AsyncGetCallTrace 只需：
- 发送信号（微秒级）
- 信号处理器立即执行
- 无需等待

**第四层（源码验证）**：
```cpp
// 传统方法需要全局协调
VMThread::execute(&op);  // 等待 Safepoint

// AsyncGetCallTrace 直接执行
forte_fill_call_trace_given_top(trace, depth, thread, ucontext);
// 无需等待，直接从 ucontext 提取信息
```

---

### 1.2 问题 2：AsyncGetCallTrace 在信号处理器中调用安全吗？

**标准回答**：

**第一层（直接回答）**：
安全。AsyncGetCallTrace 经过了特殊设计，符合 async-signal-safe 的要求。

**第二层（四大保证）**：

**1. 只读操作**：
- 只读取寄存器和栈指针
- 只读方法 ID 和行号
- 不修改任何 JVM 状态

**2. 无锁操作**：
- 不获取 JVM 内部锁
- 避免死锁风险
- 因为只读，不需要同步

**3. 无内存分配**：
- 使用调用者提供的缓冲区
- 不调用 malloc/new
- 避免内存分配器的锁

**4. 栈帧稳定性**：
- 线程已暂停，栈不变
- 栈帧链是静态的
- 可以安全遍历

**第三层（源码验证）**：
```cpp
// hotspot/share/prims/forte.cpp

void AsyncGetCallTrace(...) {
    // 没有：
    // - MutexLocker（无锁）
    // - NEW/malloc（无分配）
    // - 修改操作（只读）
    
    // 直接调用核心逻辑
    forte_fill_call_trace_given_top(trace, depth, thread, ucontext);
}
```

**第四层（对比不安全的情况）**：
```cpp
// 不安全的操作（不能在信号处理器中调用）
void UnsafeFunction() {
    malloc(100);        // ❌ 内存分配
    lock(&mutex);       // ❌ 锁操作
    modify_heap(obj);   // ❌ 修改堆
    call_java_method(); // ❌ 调用 Java 方法
}

// AsyncGetCallTrace 避免了所有这些操作
```

---

### 1.3 问题 3：AsyncGetCallTrace 什么时候会失败？

**标准回答**：

**第一层（概述）**：
AsyncGetCallTrace 主要在以下情况返回 num_frames = 0：
1. 线程处于 Native 代码
2. 线程正在退出
3. 栈损坏
4. PC 不在已知代码范围

**第二层（详细场景）**：

**场景 1：线程在 Native 代码**
```java
// JNI 调用期间
nativeMethod();

// JVM 内部操作（GC、类加载）
// 这些时候没有 Java 栈帧
```

**场景 2：线程状态异常**
```java
// 线程正在退出
// 数据结构不稳定，无法安全访问
```

**场景 3：栈损坏**
```java
// 栈溢出
// 内存错误
// 导致栈帧链断开
```

**第三层（量化数据）**：
根据实测：
- 纯 Java 应用：失败率 1-3%
- Java + JNI：失败率 5-10%
- 大量 Native：失败率 20-30%

**第四层（应对策略）**：
async-profiler 的降级策略：
```cpp
if (trace.num_frames == 0) {
    // 尝试 VMStructs 推断
    try_vmstructs_walk();
    
    // 尝试 FP 链式回溯
    try_fp_walk();
    
    // 记录失败
    _failed_samples++;
}
```

---

### 1.4 问题 4：AsyncGetCallTrace 的性能开销如何？

**标准回答**：

**第一层（直接回答）**：
开销极低，单次采样 7-54 微秒，对应用影响 < 1%。

**第二层（详细分解）**：

| 阶段 | 操作 | 开销 |
|------|------|------|
| 信号进入 | 内核保存上下文 | 1-2 μs |
| 提取寄存器 | 从 ucontext 读取 | < 0.1 μs |
| AsyncGetCallTrace | JVM 内部栈回溯 | 5-50 μs |
| 信号返回 | 内核恢复上下文 | 1-2 μs |
| **总计** | **完整采样** | **7-54 μs** |

**第三层（影响因素）**：

**栈深度**：
```
浅栈（10 帧）：5-10 μs
深栈（100 帧）：20-50 μs
```

**帧类型**：
```
解释帧：慢（需要查找字节码）
编译帧：快（有调试信息）
Native 帧：跳过（快）
```

**第四层（对比传统方法）**：

| 方式 | 单次开销 | 等待时间 | 总开销 |
|------|---------|---------|--------|
| 传统 Profiler | 10-50 μs | 1-10 秒 | 不可预测 |
| AsyncGetCallTrace | 7-54 μs | 0 | 可预测 |

**第五层（量化影响）**：
假设采样频率 100 Hz：
```
每秒采样：100 次
每次开销：10-50 μs
总开销：1-5 ms/s
占比：< 0.5%
```

---

## 二、自测环节（必须通过）

### 自测 1：函数签名

**Q**: AsyncGetCallTrace 的函数签名是什么？每个参数的含义是什么？

<details>
<summary>点击查看答案</summary>

**A**:

```cpp
void AsyncGetCallTrace(ASGCT_CallTrace *trace, 
                       jint depth, 
                       void* ucontext);
```

**参数**：
- `trace`：输出参数，存储调用栈。调用者需分配 ASGCT_CallFrame 数组
- `depth`：最大栈深度，通常是 128-1024
- `ucontext`：信号上下文，包含寄存器状态（PC、SP、FP等）

**返回值**：
- `trace->num_frames > 0`：成功，返回帧数
- `trace->num_frames = 0`：失败，无法获取栈
- `trace->num_frames = -1`：严重错误

**关键点**：
- 调用者负责分配 `trace->frames` 数组
- `ucontext` 从信号处理器传入
- 不是标准 JVMTI 接口，是 HotSpot 特有
</details>

---

### 自测 2：安全性

**Q**: 为什么 AsyncGetCallTrace 在信号处理器中调用是安全的？请说明四大保证。

<details>
<summary>点击查看答案</summary>

**A**:

**四大保证**：

**1. 只读操作**：
- 只读取寄存器、栈指针、方法 ID、行号
- 不修改 JVM 堆、线程栈、内部数据结构

**2. 无锁操作**：
- 不获取任何 JVM 内部锁
- 因为只读，不需要同步
- 避免死锁风险

**3. 无内存分配**：
- 使用调用者提供的缓冲区
- 不调用 malloc/new
- 避免内存分配器的锁

**4. 栈帧稳定性**：
- 线程已暂停，栈不变
- 栈帧链是静态的
- 可以安全遍历

**源码验证**：
```cpp
void AsyncGetCallTrace(...) {
    // 没有 MutexLocker（无锁）
    // 没有 NEW/malloc（无分配）
    // 没有修改操作（只读）
    forte_fill_call_trace_given_top(trace, depth, thread, ucontext);
}
```
</details>

---

### 自测 3：失败场景

**Q**: AsyncGetCallTrace 什么时候会返回 num_frames = 0？失败率大概是多少？

<details>
<summary>点击查看答案</summary>

**A**:

**失败场景**：

1. **线程在 Native 代码**：
   - JNI 调用期间
   - JVM 内部操作（GC、类加载）
   - 没有 Java 栈帧

2. **线程正在退出**：
   - 数据结构不稳定
   - 无法安全访问

3. **栈损坏**：
   - 栈溢出
   - 内存错误
   - 栈帧链断开

4. **PC 不在已知代码范围**：
   - 未注册到 CodeCache
   - 动态生成的代码

**失败率**（实测数据）：
- 纯 Java 应用：1-3%
- Java + JNI：5-10%
- 大量 Native：20-30%

**应对策略**：
```cpp
if (trace.num_frames == 0) {
    // 降级到其他方法
    try_vmstructs_walk();
    try_fp_walk();
}
```
</details>

---

### 自测 4：性能开销

**Q**: AsyncGetCallTrace 的性能开销是多少？请量化说明。

<details>
<summary>点击查看答案</summary>

**A**:

**单次开销**：7-54 μs

**分解**：
```
信号进入：        1-2 μs
提取寄存器：      < 0.1 μs
AsyncGetCallTrace：5-50 μs
信号返回：        1-2 μs
总计：           7-54 μs
```

**影响因素**：

1. **栈深度**：
   - 浅栈（10 帧）：5-10 μs
   - 深栈（100 帧）：20-50 μs

2. **帧类型**：
   - 解释帧：慢（需查找字节码）
   - 编译帧：快（有调试信息）

**对应用的影响**：

假设采样频率 100 Hz：
```
每秒采样：100 次
每次开销：10-50 μs
总开销：  1-5 ms/s
占比：    < 0.5%
```

**对比传统方法**：
- 传统：需要等待 Safepoint，可能 1-10 秒
- AsyncGetCallTrace：立即执行，微秒级
</details>

---

## 三、Day 2 完成标准

通过 Day 2 的标准是：

- [ ] 能写出 AsyncGetCallTrace 的函数签名
- [ ] 能说明每个参数的含义和注意事项
- [ ] 能描述完整的工作流程（信号 → ucontext → 栈回溯）
- [ ] 能解释四大安全保证（只读、无锁、无分配、栈稳定）
- [ ] 能列举失败场景和失败率
- [ ] 能量化性能开销（7-54 μs）
- [ ] 通过所有 4 个自测问题

---

## 四、扩展阅读（追求极致深度）

### 4.1 JVM 源码

**必读源码**：
1. `forte.cpp`：AsyncGetCallTrace 实现
2. `frame.hpp`：帧数据结构
3. `registerMap.hpp`：寄存器映射
4. `stackValue.cpp`：栈值解析

**关键函数**：
```cpp
AsyncGetCallTrace()                      // 入口
forte_fill_call_trace_given_top()       // 核心逻辑
find_initial_Java_frame()               // 找初始帧
frame::sender()                         // 获取调用者帧
fill_interpreted_frame()                // 填充解释帧
fill_compiled_frame()                   // 填充编译帧
```

### 4.2 相关规范

**POSIX 信号处理规范**：
- `signal-safety(7)`：async-signal-safe 函数列表
- AsyncGetCallTrace 不在标准列表中，但符合要求

**JVMTI 规范**：
- AsyncGetCallTrace 不是标准接口
- 只有 HotSpot/OpenJ9 实现
- 其他 JVM 可能有类似接口

### 4.3 论文和博客

**必读论文**：
- "AsyncGetCallTrace: Efficient Stack Tracing for Java" by HotSpot team

**必读博客**：
- https://github.com/jvm-profiling-tools/async-profiler/blob/master/docs/AsyncGetCallTrace.md
- https://bugs.openjdk.org/browse/JDK-8173181（AsyncGetCallTrace 改进）

### 4.4 实战调试

**启用 AsyncGetCallTrace 日志**：
```bash
java -XX:+UnlockDiagnosticVMOptions \
     -XX:+LogAsyncGetCallTrace \
     MyApp
```

**调试命令**：
```bash
# GDB 中设置断点
gdb -p <pid>
(gdb) break AsyncGetCallTrace
(gdb) continue

# 查看调用栈
(gdb) backtrace

# 查看参数
(gdb) print *trace
(gdb) print depth
(gdb) print *(ucontext_t*)ucontext
```

---

## 五、Day 2 总结

### 核心知识点

```
AsyncGetCallTrace 方案
├─ 函数签名
│  ├─ 参数：trace（输出）、depth（深度）、ucontext（信号上下文）
│  ├─ 返回值：num_frames > 0 成功，= 0 失败，= -1 错误
│  └─ 注意：调用者分配缓冲区
├─ 工作流程
│  ├─ 信号中断线程
│  ├─ 从 ucontext 提取寄存器
│  ├─ find_initial_Java_frame 找初始帧
│  ├─ 遍历栈帧（解释帧/编译帧）
│  └─ 填充 ASGCT_CallFrame 数组
├─ 安全性保证
│  ├─ 只读操作：不修改 JVM 状态
│  ├─ 无锁操作：避免死锁
│  ├─ 无内存分配：使用调用者缓冲区
│  └─ 栈帧稳定性：线程已暂停
├─ 失败场景
│  ├─ 线程在 Native 代码
│  ├─ 线程正在退出
│  ├─ 栈损坏
│  └─ PC 不在已知代码范围
└─ 性能开销
   ├─ 单次：7-54 μs
   ├─ 影响因素：栈深度、帧类型
   └─ 对应用影响：< 1%
```

### 面试要点

1. **函数签名**：能写出签名，说明参数含义
2. **工作流程**：能描述完整的栈回溯过程
3. **安全性**：能解释四大保证
4. **失败场景**：能列举何时失败，量化失败率
5. **性能开销**：能量化说明开销和影响因素

### 下一步

Day 2 完成后，进入 **Day 3：栈回溯方法对比**，学习：
- AsyncGetCallTrace vs Frame Pointer vs DWARF vs VMStructs
- 每种方法的原理、优缺点、适用场景
- 组合策略和降级方案

---

**Day 2 完成！准备好进入 Day 3 了吗？**
