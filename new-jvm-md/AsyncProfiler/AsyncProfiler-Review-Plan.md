# AsyncProfiler 核心概念复习计划

> 复习目标：掌握 async-profiler 的核心原理，能够流畅回答面试问题
> 复习时间：1 周（7 天）
> 复习资料：new-jvm-md/AsyncProfiler/*.md

---

## 文档定位

本文是 7 天复习计划的**详细版**，包含每天的核心概念讲解、面试问答和自测题目。每天对应一个 Deep Dive 文档作为深度参考。精简版索引见各 Review Day 文件的"知识索引"部分。

---


## 📅 复习时间表

| 天数 | 主题 | 核心文档 | 目标 |
|------|------|----------|------|
| Day 1 | Safepoint Bias 问题 | 01-Safepoint-Bias-Problem.md | 理解传统 profiler 的局限性 |
| Day 2 | AsyncGetCallTrace 方案 | 02-AsyncGetCallTrace-Solution.md | 掌握核心解决思路 |
| Day 3 | 栈回溯方法对比 | 03-Stack-Walking-Methods-Comparison.md | 了解四种技术方案 |
| Day 4 | VMStructs 偏移推断 | 04-VMStructs-Offset-Inference.md | 理解 JVM 内部数据访问 |
| Day 5 | CPU Profiling | 05-CPU-Profiling-PerfEvents-Deep-Dive.md | 掌握 CPU 采样原理 |
| Day 6 | 多种采样模式 | 06-08 相关文档 | 了解 Allocation/Lock/WallClock |
| Day 7 | 输出与实战 | 13-15 相关文档 | 火焰图解读 + 实战演练 |

---

## 📚 Day 1：Safepoint Bias 问题

### 核心概念

**问题**：传统 Java Profiler（JProfiler、YourKit）存在 Safepoint Bias，导致采样不准确。

**根本原因**：
```
传统 Profiler 只能在 Safepoint 采样
    ↓
Safepoint 不是均匀分布的
    ↓
CPU 密集代码段可能长时间没有 Safepoint
    ↓
采样结果偏向有 Safepoint 的代码（如锁操作、GC）
```

### 关键知识点

#### 1. Safepoint 是什么？

**定义**：JVM 可以安全执行 GC、类加载等操作的安全点。

**特征**：
- 线程在 Safepoint 会暂停
- 不是所有指令都是 Safepoint
- 循环回跳、方法调用、异常抛出等位置可能是 Safepoint

**举例**：
```java
// CPU 密集型代码（可能长时间没有 Safepoint）
public void cpuIntensive() {
    long sum = 0;
    for (int i = 0; i < Integer.MAX_VALUE; i++) {
        sum += i;  // 这个循环可能跑很久没有 Safepoint
    }
}

// 锁操作（一定会触发 Safepoint）
public void withLock() {
    synchronized (lock) {  // 获取锁时触发 Safepoint
        // ...
    }
}
```

#### 2. Safepoint Bias 的量化影响

| 场景 | 真实 CPU 占比 | 传统 Profiler 显示 | 误差 |
|------|--------------|-------------------|------|
| CPU 密集循环 | 80% | 20% | **-75%** |
| 锁操作 | 10% | 60% | **+500%** |
| GC 频繁 | 5% | 15% | **+200%** |

**结论**：传统 Profiler 会严重低估 CPU 密集型代码，高估锁操作和 GC。

#### 3. 为什么会有这个问题？

**历史原因**：
- 早期 JVM 只能在 Safepoint 获取线程栈
- 在非 Safepoint 获取栈可能导致内存不一致
- 所以所有 profiler 都只能依赖 Safepoint

**解决方案**：
- AsyncGetCallTrace（JDK 8+，非标准 JVMTI 接口）
- 允许在信号处理器中获取线程栈
- 无需等待 Safepoint

### 面试问答

**Q1：为什么传统 Java Profiler 不准确？**

**A**：传统 Profiler 依赖 Safepoint 采样，而 Safepoint 不是均匀分布的。

具体来说：
1. **Safepoint 不是随处都有**：只有方法调用、循环回跳、异常抛出等位置可能是 Safepoint
2. **CPU 密集代码少 Safepoint**：纯粹的计算循环可能跑几百万次才遇到一个 Safepoint
3. **锁操作多 Safepoint**：锁的获取、释放都会触发 Safepoint

结果就是：
- CPU 密集代码被**低估**（可能只采样到 20%，实际占 80%）
- 锁操作被**高估**（可能显示 60%，实际只占 10%）

**举例**：
```java
// 这个循环可能跑 1 秒钟都没有 Safepoint
// 传统 Profiler 会认为这个方法几乎不占 CPU
for (int i = 0; i < 1000000000; i++) {
    sum += i;
}

// 这个锁操作每次都会触发 Safepoint
// 传统 Profiler 会认为这个方法占用大量 CPU
synchronized (lock) {
    // 实际操作可能很快
}
```

**Q2：如何量化 Safepoint Bias 的影响？**

**A**：可以通过实验测量：

1. **准备测试程序**：
   - CPU 密集方法（长时间循环）
   - 锁密集方法（频繁 synchronized）

2. **对比测试**：
   - 用传统 Profiler（JProfiler）采样
   - 用 async-profiler 采样
   - 对比结果

3. **典型结果**：
   - CPU 密集方法：JProfiler 显示 20%，async-profiler 显示 80%
   - 锁密集方法：JProfiler 显示 60%，async-profiler 显示 10%

**Q3：AsyncProfiler 如何解决 Safepoint Bias？**

**A**：使用 AsyncGetCallTrace 接口，在信号处理器中获取线程栈，无需等待 Safepoint。

核心思路：
1. **定时信号中断**：通过 perf_event 或 ITimer 定时发送 SIGPROF 信号
2. **信号处理器执行**：线程被中断，跳转到信号处理器
3. **AsyncGetCallTrace 调用**：在信号上下文中调用 JVMTI 接口获取栈
4. **无需 Safepoint**：AsyncGetCallTrace 可以在非 Safepoint 安全获取栈

优势：
- 采样是**均匀**的（时间驱动，不是 Safepoint 驱动）
- 真实反映 CPU 占比
- 开销低（< 1%）

### 复习检查点

- [ ] 能解释 Safepoint 是什么
- [ ] 能说明 Safepoint 不是均匀分布的
- [ ] 能举例 CPU 密集代码为什么少 Safepoint
- [ ] 能量化 Safepoint Bias 的影响（典型数据）
- [ ] 能说明传统 Profiler 的局限性
- [ ] 能解释为什么需要 AsyncGetCallTrace

---

## 📚 Day 2：AsyncGetCallTrace 方案

### 核心概念

**AsyncGetCallTrace 是什么**：JVMTI 的非标准接口（HotSpot 特有），允许在信号处理器中安全获取线程调用栈。

**核心优势**：
- 不需要等待 Safepoint
- 在信号上下文中调用
- 返回完整的 Java 调用栈

### 关键知识点

#### 1. AsyncGetCallTrace 函数签名

```cpp
// jvmti.h
void AsyncGetCallTrace(ASGCT_CallTrace *trace, jint depth, void* ucontext);
```

**参数说明**：
- `trace`：输出参数，存储调用栈信息
- `depth`：最大栈深度
- `ucontext`：信号上下文（包含寄存器状态）

**ASGCT_CallTrace 结构**：
```cpp
typedef struct {
    JNIEnv *env;          // JNI 环境
    jint num_frames;      // 实际获取的帧数
    ASGCT_CallFrame *frames; // 调用栈数组
} ASGCT_CallTrace;

typedef struct {
    jint lineno;          // 行号
    jmethodID method_id;  // 方法 ID
} ASGCT_CallFrame;
```

#### 2. 工作原理

```
信号中断线程（SIGPROF）
    ↓
进入信号处理器
    ↓
从 ucontext 提取寄存器状态（PC、SP、FP）
    ↓
调用 AsyncGetCallTrace
    ↓
JVM 内部流程：
  1. 从 PC 找到最近的代码位置
  2. 判断是 Java 帧、Native 帧、还是解释帧
  3. 根据帧类型回溯调用栈
  4. 返回完整的 Java 调用栈
    ↓
返回到信号处理器
    ↓
记录样本
```

#### 3. 安全性保证

**问题**：在信号上下文中调用 JVM 函数，是否安全？

**保证机制**：
1. **栈帧稳定性**：
   - 信号发生时，线程暂停，栈帧链表是稳定的
   - 不会发生栈帧的增删

2. **内存访问安全**：
   - AsyncGetCallTrace 只读栈帧信息
   - 不会分配内存、不会触发 GC

3. **信号处理限制**：
   - 信号处理器中只能调用 async-signal-safe 函数
   - AsyncGetCallTrace 经过特殊设计，符合这个要求

#### 4. 失败场景

**可能返回 num_frames = 0 的情况**：

1. **线程处于 Native 代码**：
   - 正在执行 JNI 调用
   - 正在执行 C++ 代码（如 GC）

2. **线程状态异常**：
   - 线程正在退出
   - 线程未完全初始化

3. **栈损坏**：
   - 栈帧链断开
   - 内存损坏

**async-profiler 的处理**：
- 记录失败次数
- 提供降级方案（如 FP 回溯）

### 面试问答

**Q1：AsyncGetCallTrace 为什么不需要 Safepoint？**

**A**：因为 AsyncGetCallTrace 在信号处理器中调用，此时线程被中断，栈帧链表是稳定的。

具体来说：
1. **信号中断**：线程被强制暂停，不依赖 Safepoint
2. **栈帧稳定**：线程暂停时，调用栈是静态的，不会变化
3. **只读操作**：AsyncGetCallTrace 只读取栈帧信息，不修改
4. **无副作用**：不分配内存、不触发 GC、不获取锁

对比传统方法：
- 传统方法：等待线程到达 Safepoint → Safepoint 不是均匀的 → 采样偏差
- AsyncGetCallTrace：强制中断线程 → 均匀采样 → 真实反映 CPU 占比

**Q2：AsyncGetCallTrace 在信号处理器中调用，如何保证安全？**

**A**：AsyncGetCallTrace 经过了特殊设计，符合 async-signal-safe 要求。

**安全性保证**：

1. **只读操作**：
   - 只读取栈帧指针、方法 ID
   - 不会修改 JVM 状态

2. **无锁操作**：
   - 不获取任何 JVM 内部锁
   - 避免死锁风险

3. **无内存分配**：
   - 使用调用者提供的缓冲区
   - 不会调用 malloc/new

4. **栈帧稳定性**：
   - 信号发生时线程已暂停
   - 栈帧链表不会变化

**失败处理**：
- 如果检测到不安全状态，返回 num_frames = 0
- 调用者可以记录失败，不影响程序运行

**Q3：AsyncGetCallTrace 的局限性是什么？**

**A**：AsyncGetCallTrace 也有一些局限性：

1. **非标准接口**：
   - 不是 JVMTI 标准接口
   - 只在 HotSpot/OpenJ9 上可用
   - 其他 JVM 可能不支持

2. **失败场景**：
   - 线程在 Native 代码中可能失败
   - 栈损坏时无法回溯
   - 成功率约 95%（根据实测）

3. **信息有限**：
   - 只返回方法 ID 和行号
   - 不包含参数、局部变量等信息

4. **性能开销**：
   - 每次调用需要进入 JVM 内部
   - 开销比简单的 FP 回溯高

**async-profiler 的应对**：
- 多种回溯方法（FP、DWARF、VMStructs）
- 失败时降级到其他方法
- 综合使用多种方法提高成功率

### 复习检查点

- [ ] 能描述 AsyncGetCallTrace 的函数签名
- [ ] 能解释为什么不需要 Safepoint
- [ ] 能说明安全性保证机制
- [ ] 能列举可能的失败场景
- [ ] 能说明局限性和应对方法

---

## 📚 Day 3：栈回溯方法对比

### 核心概念

async-profiler 支持四种栈回溯方法，每种有不同的适用场景和性能特征。

### 四种方法对比

#### 1. AsyncGetCallTrace（AGCT）

**原理**：调用 JVMTI 接口获取 Java 调用栈。

**优点**：
- 准确度高（JVM 保证正确性）
- 支持所有 Java 帧（解释帧、编译帧）
- 信息完整（方法 ID + 行号）

**缺点**：
- 非标准接口（HotSpot 特有）
- Native 帧支持有限
- 性能开销较高

**适用场景**：
- Java 代码为主的应用
- 需要准确行号信息
- HotSpot/OpenJ9 JVM

**成功率**：95%

#### 2. Frame Pointer（FP）链式回溯

**原理**：通过 RBP 寄存器链式回溯 Native 调用栈。

**优点**：
- 极快（只读寄存器）
- 无需符号表
- 适合 Native 代码

**缺点**：
- 需要 GCC -fno-omit-frame-pointer
- 现代 JVM 默认不保留 FP
- 无法区分 Java 帧

**适用场景**：
- C++ 代码分析
- 编译时保留 FP 的程序
- 性能敏感场景

**成功率**：50-70%（取决于编译选项）

#### 3. DWARF CFI（.eh_frame）

**原理**：解析 ELF 文件的 .eh_frame 段，获取栈回溯信息。

**优点**：
- 无需保留 FP
- 支持 GCC 默认编译的程序
- 准确度高

**缺点**：
- 需要符号表
- 解析开销较大
- JVM 库可能没有 .eh_frame

**适用场景**：
- 现代 C++ 程序
- 无 FP 的 Native 代码
- 需要准确回溯

**成功率**：80-90%

#### 4. VMStructs 偏移推断

**原理**：通过 JVM 导出的 VMStructs 符号表，推断内部数据结构偏移量。

**优点**：
- 不依赖 JVM 头文件
- 支持 Java + Native 混合帧
- 适用于各种 JVM 版本

**缺点**：
- 复杂度高
- JVM 内部结构变化可能导致失败
- 需要符号表

**适用场景**：
- JVM 内部分析
- Java + Native 混合调用链
- 需要 JVM 内部信息

**成功率**：85-95%

### 组合策略

async-profiler 的回溯策略：

```
1. 尝试 AsyncGetCallTrace
   ↓ 失败
2. 尝试 VMStructs 推断
   ↓ 失败
3. 尝试 DWARF CFI
   ↓ 失败
4. 降级到 FP 链式回溯
```

**最终成功率**：99%+

### 面试问答

**Q1：为什么需要四种回溯方法？**

**A**：因为每种方法都有局限性，需要组合使用提高成功率。

具体来说：
- **AGCT**：最准确，但 Native 帧支持有限
- **FP**：最快，但需要编译选项支持
- **DWARF**：现代，但需要符号表
- **VMStructs**：功能强，但复杂度高

组合策略：
1. 优先用 AGCT（准确度高）
2. 失败时降级到其他方法
3. 最终成功率可达 99%+

**Q2：如何选择回溯方法？**

**A**：根据应用特点选择：

| 应用类型 | 推荐方法 | 理由 |
|---------|---------|------|
| 纯 Java | AGCT | 准确度最高 |
| Java + 少量 JNI | AGCT + VMStructs | 混合帧支持 |
| 大量 C++ 代码 | DWARF + FP | Native 帧准确 |
| 性能敏感 | FP | 开销最低 |

**Q3：VMStructs 偏移推断的原理是什么？**

**A**：通过 JVM 导出的 VMStructs 符号表，推断内部数据结构的字段偏移量。

步骤：
1. 查找 `gHotSpotVMStructs` 符号
2. 遍历符号表，找到感兴趣的偏移量
3. 通过偏移量访问 JVM 内部数据结构
4. 推断栈帧布局

举例：
```
// 查找 JavaThread._stack_base 的偏移
for (entry in VMStructs) {
    if (entry.typeName == "JavaThread" && 
        entry.fieldName == "_stack_base") {
        stack_base_offset = entry.offset;
    }
}

// 通过偏移访问
void* stack_base = *(void**)((char*)thread + stack_base_offset);
```

优势：
- 不依赖 JVM 版本
- 不需要 JVM 头文件
- 支持自定义 JVM

### 复习检查点

- [ ] 能说明四种方法的原理和优缺点
- [ ] 能比较不同方法的适用场景
- [ ] 能解释组合策略的逻辑
- [ ] 能描述 VMStructs 推断的基本原理

---

## 📚 Day 4：VMStructs 偏移推断

### 核心概念

**问题**：async-profiler 需要访问 JVM 内部数据结构（如 JavaThread、Klass），但没有 JVM 头文件。

**解决方案**：通过 VMStructs 符号表推断字段偏移量。

### 关键知识点

#### 1. VMStructs 是什么

**定义**：JVM 导出的全局符号表，包含内部数据结构的字段信息。

**导出位置**：
```cpp
// hotspot/share/runtime/vmStructs.cpp
VMStructEntry* gHotSpotVMStructs = localHotSpotVMStructs;
```

**结构定义**：
```cpp
struct VMStructEntry {
    const char* typeName;    // 类型名（如 "JavaThread"）
    const char* fieldName;   // 字段名（如 "_stack_base"）
    const char* typeString;  // 字段类型字符串
    address* address;        // 字段地址（静态字段）
    uint64_t offset;         // 字段偏移（实例字段）
    void* staticValue;       // 静态字段值
};
```

#### 2. 推断流程

```
启动时初始化
    ↓
1. 查找 gHotSpotVMStructs 符号
   dlsym(RTLD_DEFAULT, "gHotSpotVMStructs")
    ↓
2. 遍历符号表
   for (entry in gHotSpotVMStructs) {
       if (entry.typeName == "JavaThread" && 
           entry.fieldName == "_stack_base") {
           _stack_base_offset = entry.offset;
       }
   }
    ↓
3. 缓存关键偏移量
   - JavaThread::_stack_base
   - JavaThread::_stack_size
   - JavaThread::_threadObj
   - Klass::_name
   - oop::_mark
   - oop::_klass
    ↓
运行时使用
   void* stack_base = *(void**)((char*)thread + _stack_base_offset);
```

#### 3. 关键偏移量

**JavaThread 相关**：
```
_stack_base     - 线程栈基址
_stack_size     - 线程栈大小
_threadObj      - Thread 对象
_osthread       - OSThread
_anchor         - last_Java_fp
```

**对象模型相关**：
```
oop::_mark      - 对象头 Mark Word
oop::_klass     - 类指针（压缩或不压缩）
Klass::_name    - 类名 Symbol*
Klass::_java_mirror - Java 镜像 Class 对象
```

**方法相关**：
```
Method::_constMethod    - 常量池
Method::_method_size    - 方法大小
ConstMethod::_constants - 常量池
ConstantPool::_pool_holder - 常量池所属类
```

#### 4. 三种推断方法

**方法 1：符号表查找（首选）**

成功率：95%+

```cpp
// 直接从符号表获取
for (entry in gHotSpotVMStructs) {
    if (match(entry)) {
        offset = entry.offset;
        break;
    }
}
```

**方法 2：已知对象推断**

成功率：70%+

```cpp
// 从已知线程对象推算
JavaThread* thread = current_thread();
oop threadObj = thread->_threadObj;

// 已知 _name 是第一个字段
Klass* klass = threadObj->klass();
Symbol* name = *(Symbol**)((char*)klass + name_offset);
```

**方法 3：代码模式推断**

成功率：50%+

```cpp
// 通过解释器帧模式匹配
// 解释器帧有固定的布局模式
if (is_interpreter_frame(frame)) {
    // 根据模式推断字段位置
}
```

### 面试问答

**Q1：为什么需要 VMStructs 推断，而不是直接包含 JVM 头文件？**

**A**：主要原因：

1. **版本兼容性**：
   - JVM 版本众多（8/11/17/21）
   - 不同版本字段偏移可能变化
   - 包含头文件需要为每个版本编译

2. **闭源 JVM**：
   - Oracle JDK 某些版本不开放源码
   - 没有头文件可用

3. **部署简化**：
   - 不需要 JVM 开发包
   - 一个二进制适配多种 JVM

**对比**：
- 传统方式：`#include "jvm.h"` → 需要为每个 JVM 版本编译
- VMStructs：运行时推断 → 一个二进制适配所有版本

**Q2：VMStructs 推断失败怎么办？**

**A**：async-profiler 有降级策略：

1. **Fallback 1**：尝试 AGCT
   - 如果 AGCT 可用，优先使用

2. **Fallback 2**：使用默认值
   - 常见 JVM 版本有内置偏移量
   - 作为后备方案

3. **Fallback 3**：跳过 Java 帧识别
   - 只记录 Native 帧
   - 用户仍能看到部分调用链

4. **报告错误**：
   - 记录失败日志
   - 建议用户检查 JVM 版本

**Q3：VMStructs 推断的性能开销如何？**

**A**：开销极小：

1. **初始化开销**：
   - 只在启动时执行一次
   - 约 100-200 微秒

2. **运行时开销**：
   - 只是一次指针加法
   - `*(void**)((char*)obj + offset)`
   - 约 1-2 个 CPU 周期

3. **内存开销**：
   - 只缓存关键偏移量
   - 约 50 个字段，几百字节

**总结**：初始化后，运行时几乎无开销。

### 复习检查点

- [ ] 能解释 VMStructs 的作用
- [ ] 能描述推断流程
- [ ] 能列举关键偏移量
- [ ] 能说明三种推断方法
- [ ] 能解释失败降级策略

---

## 📚 Day 5：CPU Profiling 深入

### 核心概念

**CPU Profiling 的核心**：通过 perf_event 子系统进行硬件计数器采样。

### 关键知识点

#### 1. perf_event 机制

**硬件计数器**：
- CPU 周期计数器（CPU_CYCLES）
- 指令计数器（INSTRUCTIONS）
- 缓存未命中计数器（CACHE_MISSES）

**工作流程**：
```
1. perf_event_open() 创建内核对象
   ↓
2. mmap() 映射共享内存页
   ↓
3. fcntl() 配置信号通知
   ↓
4. ioctl() 启用计数器
   ↓
5. 硬件计数器溢出 → 内核发送 SIGPROF
   ↓
6. 信号处理器 → 栈回溯 → 记录样本
```

#### 2. perf_event_attr 配置

```cpp
struct perf_event_attr {
    __u32 type;          // PERF_TYPE_HARDWARE/SOFTWARE
    __u64 config;        // PERF_COUNT_HW_CPU_CYCLES
    __u64 sample_period; // 采样周期（如 10,000,000 个周期）
    __u64 sample_type;   // PERF_SAMPLE_CALLCHAIN
    __u64 exclude_kernel; // 是否排除内核态
};
```

**关键参数**：
- `sample_period`：多少个事件触发一次采样
  - 太小：开销大，影响性能
  - 太大：精度低，遗漏细节
  - 推荐：10,000,000（约 100 Hz）

- `exclude_kernel`：
  - 0：包含内核态采样（需要 CAP_SYS_ADMIN）
  - 1：只采样用户态（无需权限）

#### 3. 信号处理流程

```cpp
void sigprof_handler(int sig, siginfo_t* info, void* ucontext) {
    // 1. 禁用计数器（避免递归）
    ioctl(fd, PERF_EVENT_IOC_DISABLE, 0);
    
    // 2. 获取当前线程
    JavaThread* thread = current_thread();
    
    // 3. 栈回溯
    ASGCT_CallTrace trace;
    AsyncGetCallTrace(&trace, MAX_DEPTH, ucontext);
    
    // 4. 记录样本
    recordSample(trace);
    
    // 5. 重置并启用计数器
    ioctl(fd, PERF_EVENT_IOC_RESET, 0);
    ioctl(fd, PERF_EVENT_IOC_ENABLE, 0);
}
```

#### 4. 三种采样方式对比

| 方式 | 实现 | 权限需求 | 开销 | 精度 |
|------|------|---------|------|------|
| perf_event | 硬件计数器 | CAP_SYS_ADMIN | 0.5% | 最高 |
| CTimer | 高精度定时器 | 无 | 1.2% | 高 |
| ITimer | setitimer() | 无 | 2.1% | 中 |

**async-profiler 选择策略**：
1. 尝试 perf_event
2. 失败 → 尝试 CTimer
3. 失败 → 使用 ITimer

### 面试问答

**Q1：perf_event 采样的原理是什么？**

**A**：perf_event 利用 CPU 的硬件性能计数器进行精确采样。

具体流程：
1. **配置计数器**：告诉 CPU 要计数什么事件（如 CPU 周期）
2. **设置阈值**：每 N 个事件触发一次中断
3. **启动计数**：CPU 开始计数
4. **溢出中断**：计数器溢出时，CPU 发送 SIGPROF 信号
5. **信号处理**：在信号处理器中进行栈回溯
6. **记录样本**：保存调用栈信息
7. **继续计数**：重置计数器，继续

**优势**：
- 精确：基于真实硬件事件
- 低开销：由硬件完成计数
- 准确：反映真实 CPU 使用

**Q2：为什么 perf_event 需要 CAP_SYS_ADMIN 权限？**

**A**：安全考虑。

**风险**：
1. **侧信道攻击**：
   - 通过精确计时推断数据
   - Spectre/Meltdown 类攻击

2. **内核信息泄露**：
   - 采样包含内核地址
   - 可用于绕过 KASLR

**解决方案**：
1. **无权限模式**：
   - 使用 CTimer/ITimer
   - 开销稍高，但无需权限

2. **perf_event_paranoid 设置**：
   ```bash
   echo 0 > /proc/sys/kernel/perf_event_paranoid
   ```
   允许非特权用户使用 perf_event

**Q3：如何选择合适的采样周期？**

**A**：需要权衡精度和开销。

**影响因素**：

1. **应用特点**：
   - CPU 密集型：可用较长周期（低采样率）
   - I/O 密集型：需要较短周期（高采样率）

2. **分析精度**：
   - 高精度：短周期，多样本
   - 快速概览：长周期，少样本

3. **性能开销**：
   - 每次采样开销约 1-5 微秒
   - 100 Hz → 100 次/秒 → 0.1-0.5 毫秒开销
   - 开销 < 1%

**推荐配置**：

| 场景 | 采样周期 | 采样频率 | 开销 |
|------|---------|---------|------|
| 生产环境 | 20,000,000 | ~50 Hz | < 0.5% |
| 开发测试 | 10,000,000 | ~100 Hz | ~1% |
| 精细分析 | 1,000,000 | ~1000 Hz | ~5% |

**命令示例**：
```bash
# 默认（100 Hz）
asprof -d 30 <pid>

# 低开销（50 Hz）
asprof -d 30 -i 20m <pid>

# 高精度（1000 Hz）
asprof -d 30 -i 1m <pid>
```

### 复习检查点

- [ ] 能描述 perf_event 的工作流程
- [ ] 能解释 perf_event_attr 的关键参数
- [ ] 能说明三种采样方式的区别
- [ ] 能解释权限要求和解决方案
- [ ] 能推荐合适的采样周期

---

## 📚 Day 6：多种采样模式

### 核心概念

async-profiler 支持多种采样模式，每种针对不同类型的性能问题。

### 四种采样模式

#### 1. CPU Profiling（默认）

**事件类型**：CPU 周期、指令执行

**采样方式**：perf_event 硬件计数器

**适用场景**：
- CPU 热点分析
- 计算密集型应用优化
- 找出占用 CPU 的方法

**命令**：
```bash
asprof -d 30 -f cpu.html <pid>
```

#### 2. Allocation Profiling

**事件类型**：对象分配

**采样方式**：JVM 分配路径插桩 + 概率采样

**实现方式**：
- **JDK 7-17**：Trap 机制（INT3 断点）
- **JDK 17+**：TLAB 钩子

**适用场景**：
- 内存分配热点
- GC 压力分析
- 内存泄漏定位

**命令**：
```bash
asprof -d 30 -e alloc -f alloc.html <pid>
```

**采样策略**：
- 每 N 字节分配采样一次
- 默认：每 256 KB 采样一次
- 可调整：`-e alloc:512k`

#### 3. Lock Profiling

**事件类型**：锁竞争

**采样方式**：JVMTI MonitorWait/MonitorEntered 事件

**监控内容**：
- 等锁时间（lock.wait.time）
- 持锁时间（lock.hold.time）
- 锁竞争次数

**适用场景**：
- 锁竞争分析
- 并发性能优化
- 死锁排查

**命令**：
```bash
# 锁等待时间
asprof -d 30 -e lock -f lock.html <pid>

# 锁持有时间
asprof -d 30 -e lock:hold -f lock_hold.html <pid>
```

#### 4. Wall Clock Profiling

**事件类型**：挂钟时间（包含等待、睡眠）

**采样方式**：独立定时器线程 + 信号广播

**实现原理**：
- 创建独立线程，定时发送信号给所有线程
- 不依赖 perf_event
- 对所有线程均匀采样

**适用场景**：
- I/O 等待分析
- 线程阻塞分析
- 整体应用吞吐瓶颈

**命令**：
```bash
asprof -d 30 -e wall -f wall.html <pid>
```

### 模式对比

| 模式 | 事件类型 | 采样方式 | 开销 | 适用场景 |
|------|---------|---------|------|---------|
| CPU | CPU 周期 | perf_event | 0.5% | CPU 热点 |
| Allocation | 对象分配 | JVM 插桩 | 2-5% | 内存分配 |
| Lock | 锁竞争 | JVMTI 事件 | 1-3% | 锁优化 |
| Wall Clock | 挂钟时间 | 定时信号 | 1-2% | I/O 阻塞 |

### 组合使用

**场景 1：CPU 热点 + 内存分配**
```bash
# 先 CPU profiling
asprof -d 30 -f cpu.html <pid>

# 再 allocation profiling
asprof -d 30 -e alloc -f alloc.html <pid>

# 对比分析：CPU 高但分配少 → 计算密集
#            CPU 低但分配多 → 内存瓶颈
```

**场景 2：锁竞争 + Wall Clock**
```bash
# 锁竞争分析
asprof -d 30 -e lock -f lock.html <pid>

# Wall Clock 分析
asprof -d 30 -e wall -f wall.html <pid>

# 对比分析：锁竞争时间长但 Wall Clock 低 → 锁竞争集中在少数线程
#            锁竞争时间短但 Wall Clock 高 → I/O 阻塞是主要问题
```

### 面试问答

**Q1：CPU Profiling 和 Wall Clock Profiling 的区别是什么？**

**A**：关键区别在于采样触发方式：

**CPU Profiling**：
- 触发条件：CPU 周期计数器溢出
- 采样对象：正在使用 CPU 的线程
- 适合分析：计算密集型代码

**Wall Clock Profiling**：
- 触发条件：固定时间间隔（如 10ms）
- 采样对象：所有活跃线程（包括等待的）
- 适合分析：整体应用吞吐瓶颈

**举例**：

```java
// CPU Profiling 会重点采样这个方法
public void cpuIntensive() {
    for (int i = 0; i < 10000000; i++) {
        sum += i;  // CPU 密集
    }
}

// Wall Clock Profiling 会重点采样这个方法
public void ioIntensive() {
    Thread.sleep(1000);  // 等待 I/O
}
```

**选择建议**：
- 分析 CPU 占用率 → CPU Profiling
- 分析响应时间 → Wall Clock Profiling
- 两者结合 → 全面性能分析

**Q2：Allocation Profiling 如何避免影响性能？**

**A**：使用概率采样，而不是记录每次分配。

**采样策略**：
1. **TLAB 采样**：
   - 每 N 字节分配采样一次
   - 默认：每 256 KB 采样一次
   - 可调整：`-e alloc:512k`

2. **概率采样**：
   - 不是每次分配都记录
   - 大对象更容易被采样
   - 保证统计意义

**开销控制**：
- 采样间隔大 → 开销低，但精度低
- 采样间隔小 → 开销高，但精度高
- 推荐：256 KB（开销 2-5%）

**实时监控**：
```bash
# 生产环境（低开销）
asprof -d 60 -e alloc:1m -f alloc.html <pid>

# 开发测试（高精度）
asprof -d 60 -e alloc:64k -f alloc.html <pid>
```

**Q3：Lock Profiling 能发现什么问题？**

**A**：Lock Profiling 可以发现：

1. **锁竞争热点**：
   - 哪些锁竞争最激烈
   - 哪些方法持锁时间最长

2. **锁粒度问题**：
   - 粗粒度锁导致竞争
   - 锁范围过大

3. **死锁风险**：
   - 持锁时间过长
   - 锁嵌套

**实例分析**：

```java
// Lock Profiling 会发现这个问题
public class BadLock {
    private final Object lock = new Object();
    
    public void process() {
        synchronized (lock) {
            // 持锁时间过长
            Thread.sleep(100);  // 模拟耗时操作
            doSomething();
        }
    }
}
```

**火焰图特征**：
- 宽栈帧：持锁时间长
- 多个线程在同一位置：竞争激烈

**优化建议**：
1. **减小锁粒度**：
   ```java
   // 优化后
   public void process() {
       doSomethingWithoutLock();  // 不需要锁的操作移出去
       synchronized (lock) {
           doSomething();
       }
   }
   ```

2. **使用并发工具**：
   ```java
   // 使用 ConcurrentHashMap
   private final ConcurrentHashMap<String, Object> map = new ConcurrentHashMap<>();
   ```

### 复习检查点

- [ ] 能说明四种采样模式的原理
- [ ] 能比较不同模式的适用场景
- [ ] 能选择合适的采样模式
- [ ] 能解释组合使用的策略

---

## 📚 Day 7：火焰图解读 + 实战演练

### 火焰图基础

#### 1. 什么是火焰图

**定义**：调用栈的可视化表示，X 轴表示方法占比，Y 轴表示调用深度。

**特征**：
- **宽度**：方法占用的时间/资源比例
- **高度**：调用栈深度
- **颜色**：通常无特殊含义（随机），用于区分不同方法

#### 2. 如何阅读火焰图

**基本规则**：
1. **从下往上读**：底部是调用入口，顶部是叶子方法
2. **宽度表示占比**：越宽表示占用越多资源
3. **关注平顶**：平顶通常表示热点方法
4. **追踪调用链**：从热点方法向下追踪调用来源

**示例解读**：
```
                    ┌───────────┐
                    │ methodD() │ (20%) - 平顶，热点方法
                ┌───┴───────────┴───┐
                │     methodB()     │ (30%) - 调用 methodD
            ┌───┴───────────────────┴───┐
            │       methodA()           │ (50%) - 根方法
            └───────────────────────────┘
```

#### 3. 火焰图交互

**操作**：
- **点击栈帧**：放大查看该方法的调用链
- **搜索**：Ctrl+F 搜索方法名
- **重置**：按 0 重置视图

### 实战演练

#### 场景 1：CPU 热点分析

**测试程序**：
```bash
cd /data/workspace/demo
java -cp out com.example.PerformanceDemo 0 120
```

**Profiling**：
```bash
# 获取 PID
jps | grep PerformanceDemo

# CPU profiling
asprof -d 30 -f cpu_profile.html <pid>
```

**分析火焰图**：
1. 打开 cpu_profile.html
2. 搜索 "buildReport"
3. 观察占比（应该较高）
4. 查看调用链：
   ```
   main
     └─ lambda$main$0
        └─ StringConcatProblem.buildReport  ← 热点
           └─ StringBuilder.toString
              └─ Arrays.copyOf
   ```

**结论**：
- buildReport 方法占用 CPU 高
- 原因：字符串拼接创建大量 StringBuilder

**优化建议**：
```java
// 优化前
String result = "";
for (DataItem item : items) {
    result += item.toString() + "\n";  // 每次创建 StringBuilder
}

// 优化后
StringBuilder sb = new StringBuilder(items.size() * 50);
for (DataItem item : items) {
    sb.append(item.toString()).append("\n");
}
```

#### 场景 2：内存分配分析

**Profiling**：
```bash
# Allocation profiling
asprof -d 30 -e alloc -f alloc_profile.html <pid>
```

**分析火焰图**：
1. 打开 alloc_profile.html
2. 搜索 "processData"
3. 观察分配量
4. 查看调用链：
   ```
   main
     └─ lambda$main$0
        └─ MemoryAllocationProblem.processData
           ├─ byte[1048576]  ← 临时数组
           ├─ byte[1048576]  ← 临时数组
           └─ byte[1048576]  ← 结果数组
   ```

**结论**：
- processData 方法分配大量临时数组
- 每次调用分配 3 MB

**优化建议**：
```java
// 优化前：每次调用分配 3 个数组
byte[] temp1 = new byte[input.length];
byte[] temp2 = new byte[input.length];
byte[] result = new byte[input.length];

// 优化后：复用缓冲区
private byte[] buffer = new byte[MAX_SIZE];
public void processDataInPlace(byte[] data) {
    // 原地修改，无需额外分配
}
```

#### 场景 3：锁竞争分析

**Profiling**：
```bash
# Lock profiling
asprof -d 30 -e lock -f lock_profile.html <pid>
```

**分析火焰图**：
1. 打开 lock_profile.html
2. 搜索 "increment"
3. 观察锁等待时间
4. 查看调用链：
   ```
   main
     └─ ThreadPoolExecutor.runWorker
        └─ lambda$main$0
           └─ LockContentionProblem.increment
              └─ Object.wait  ← 锁等待
   ```

**结论**：
- increment 方法锁竞争严重
- 原因：粗粒度锁 + 持锁时间长

**优化建议**：
```java
// 优化前：粗粒度锁
synchronized (lock) {
    counter++;
    Thread.sleep(1);  // 持锁期间睡眠
}

// 优化后：无锁并发
private AtomicInteger counter = new AtomicInteger(0);
counter.incrementAndGet();  // 无锁
```

### 面试问答

**Q1：如何通过火焰图定位性能瓶颈？**

**A**：五步法：

1. **找平顶**：
   - 浏览火焰图顶部
   - 找出最宽的平顶栈帧
   - 这是 CPU/内存热点

2. **追踪调用链**：
   - 从热点方法向下追踪
   - 找出是谁在调用
   - 分析调用上下文

3. **分析原因**：
   - 是算法问题？(O(n²))
   - 是实现问题？(频繁分配)
   - 是锁竞争问题？

4. **提出优化**：
   - 算法优化（改用高效算法）
   - 实现优化（减少分配、复用对象）
   - 架构优化（异步化、并发化）

5. **验证效果**：
   - 实施优化
   - 重新 profiling
   - 对比火焰图

**Q2：CPU 火焰图和 Allocation 火焰图有什么区别？**

**A**：

| 维度 | CPU 火焰图 | Allocation 火焰图 |
|------|-----------|------------------|
| 宽度含义 | CPU 时间占比 | 内存分配量占比 |
| 热点特征 | 计算密集型方法 | 内存分配密集型方法 |
| 典型问题 | 算法慢、循环多 | 频繁创建对象 |
| 优化方向 | 减少计算量 | 减少对象创建、复用 |

**举例**：
```java
// CPU 火焰图热点
public void cpuIntensive() {
    for (int i = 0; i < 1000000; i++) {
        sum += i;  // CPU 计算密集
    }
}

// Allocation 火焰图热点
public void allocationIntensive() {
    List<String> list = new ArrayList<>();
    for (int i = 0; i < 100000; i++) {
        list.add("item-" + i);  // 频繁创建 String
    }
}
```

**Q3：如何判断火焰图中的问题是否值得优化？**

**A**：评估标准：

1. **占比大小**：
   - 占比 < 5%：通常不值得优化
   - 占比 5-20%：可以考虑优化
   - 占比 > 20%：优先优化

2. **优化难度**：
   - 简单修改：立即优化
   - 需要重构：评估 ROI
   - 架构变更：谨慎决策

3. **业务影响**：
   - 核心路径：必须优化
   - 非关键路径：可延后
   - 初始化代码：可能不需要优化

4. **优化空间**：
   - 有明显优化方案：立即优化
   - 不确定如何优化：先调研

**决策流程**：
```
发现热点
    ↓
占比 > 20%？
    ├─ 是 → 评估优化难度
    │        ↓
    │      难度低？
    │        ├─ 是 → 立即优化
    │        └─ 否 → 评估业务影响
    │                 ↓
    │               核心路径？
    │                 ├─ 是 → 必须优化
    │                 └─ 否 → 可延后
    └─ 否 → 占比 > 5%？
               ├─ 是 → 记录待优化
               └─ 否 → 暂不优化
```

### 复习检查点

- [ ] 能读懂火焰图的基本结构
- [ ] 能找出火焰图中的热点
- [ ] 能追踪调用链定位问题
- [ ] 能针对不同类型的问题选择优化策略
- [ ] 能评估优化优先级

---

## 📝 复习总结

### 核心知识体系

```
AsyncProfiler 核心原理
├─ Safepoint Bias 问题
│  ├─ 传统 Profiler 的局限性
│  └─ 为什么采样不准确
├─ AsyncGetCallTrace 方案
│  ├─ 工作原理（信号上下文）
│  ├─ 安全性保证
│  └─ 失败场景
├─ 四种栈回溯方法
│  ├─ AsyncGetCallTrace（最准确）
│  ├─ Frame Pointer（最快）
│  ├─ DWARF CFI（现代）
│  └─ VMStructs（最全面）
├─ VMStructs 偏移推断
│  ├─ 符号表查找
│  ├─ 已知对象推断
│  └─ 代码模式推断
├─ CPU Profiling
│  ├─ perf_event 机制
│  ├─ 硬件计数器
│  └─ 信号处理流程
├─ 多种采样模式
│  ├─ CPU（CPU 热点）
│  ├─ Allocation（内存分配）
│  ├─ Lock（锁竞争）
│  └─ Wall Clock（整体时间）
└─ 火焰图解读
   ├─ 找平顶热点
   ├─ 追踪调用链
   └─ 提出优化方案
```

### 面试高频问题清单

#### 基础概念类

1. **为什么传统 Java Profiler 不准确？**
   - Safepoint Bias 问题
   - CPU 密集代码被低估
   - 锁操作被高估

2. **AsyncGetCallTrace 如何解决 Safepoint Bias？**
   - 信号上下文中调用
   - 无需等待 Safepoint
   - 均匀采样

3. **AsyncGetCallTrace 在信号处理器中调用安全吗？**
   - 只读操作
   - 无锁、无内存分配
   - 栈帧稳定

#### 技术原理类

4. **perf_event 采样的原理是什么？**
   - 硬件性能计数器
   - 溢出中断
   - 信号处理

5. **为什么需要四种栈回溯方法？**
   - 每种方法有局限性
   - 组合提高成功率
   - 不同场景不同选择

6. **VMStructs 偏移推断的原理是什么？**
   - JVM 导出符号表
   - 运行时推断偏移量
   - 版本兼容

#### 实战应用类

7. **如何选择采样模式？**
   - CPU 热点 → CPU Profiling
   - 内存问题 → Allocation Profiling
   - 锁竞争 → Lock Profiling
   - I/O 阻塞 → Wall Clock Profiling

8. **如何解读火焰图？**
   - 找平顶热点
   - 追踪调用链
   - 分析原因
   - 提出优化

9. **CPU Profiling 和 Wall Clock Profiling 的区别？**
   - CPU：只采样正在运行的线程
   - Wall Clock：采样所有线程（包括等待的）

#### 性能优化类

10. **如何判断是否需要优化？**
    - 占比大小（> 20% 优先）
    - 业务影响（核心路径优先）
    - 优化难度（低难度优先）

### 实战演练清单

- [ ] 运行 PerformanceDemo
- [ ] CPU Profiling 并解读火焰图
- [ ] Allocation Profiling 并解读火焰图
- [ ] Lock Profiling 并解读火焰图
- [ ] 提出优化方案

---

**复习完成标志**：
- 能流畅回答上述 10 个高频问题
- 能现场演示 profiling 流程
- 能解读火焰图并提出优化建议

**下一步**：开始 Arthas 架构和命令实现复习
