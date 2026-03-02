# AsyncProfiler 复习文档总览

> 创建时间：2026-02-27
> 文档目的：PerfMa 面试准备，7 天深度复习

---

## 文档定位

本文是 7 天复习文档的总览索引。每个 Review Day 文件已精简为"复习卡片"格式（知识索引 + 面试问答 + 自测题），深度内容链接到对应的 Deep Dive 文档。

---


## 📚 文档列表

### 已创建文档

| 天数 | 主题 | 文件 | 字数 | 状态 |
|------|------|------|------|------|
| Day 1 | Safepoint Bias 问题 | [AsyncProfiler-Review-Day1-Safepoint-Bias.md](./AsyncProfiler-Review-Day1-Safepoint-Bias.md) | ~500 行 | ✅ 复习卡片 |
| Day 2 | AsyncGetCallTrace 方案 | [AsyncProfiler-Review-Day2-AsyncGetCallTrace.md](./AsyncProfiler-Review-Day2-AsyncGetCallTrace.md) | ~580 行 | ✅ 复习卡片 |
| Day 3 | 栈回溯方法对比 | [AsyncProfiler-Review-Day3-Stack-Walking-Methods.md](./AsyncProfiler-Review-Day3-Stack-Walking-Methods.md) | ~530 行 | ✅ 复习卡片 |
| Day 4 | VMStructs 偏移推断 | [AsyncProfiler-Review-Day4-VMStructs-Offset-Inference.md](./AsyncProfiler-Review-Day4-VMStructs-Offset-Inference.md) | ~460 行 | ✅ 复习卡片 |
| Day 5 | CPU Profiling 深入 | [AsyncProfiler-Review-Day5-CPU-Profiling.md](./AsyncProfiler-Review-Day5-CPU-Profiling.md) | ~500 行 | ✅ 复习卡片 |
| Day 6 | 多种采样模式 | [AsyncProfiler-Review-Day6-Multiple-Modes.md](./AsyncProfiler-Review-Day6-Multiple-Modes.md) | ~430 行 | ✅ 复习卡片 |
| Day 7 | 火焰图解读 + 实战演练 | [AsyncProfiler-Review-Day7-FlameGraph-Practice.md](./AsyncProfiler-Review-Day7-FlameGraph-Practice.md) | ~420 行 | ✅ 复习卡片 |

### 总体统计

- **总行数**：~3,420 行（复习卡片格式，深度内容在 Deep Dive 文档中）
- **学习时间**：7 天（每天 2-3 小时）
- **面试问题**：28 个核心问题
- **自测问题**：28 个

---

## 📅 学习计划

### Week 1: AsyncProfiler 核心原理

#### Day 1: Safepoint Bias 问题
- **学习时间**：2-3 小时
- **核心内容**：
  - Safepoint 的定义和必要性
  - Safepoint 不是均匀分布的
  - 传统 Profiler 的采样机制
  - 量化 Safepoint Bias 的影响
  - AsyncGetCallTrace 的解决思路
- **完成标准**：通过 4 个自测问题
- **面试能力**：能流畅解释为什么传统 Profiler 不准确

#### Day 2: AsyncGetCallTrace 方案
- **学习时间**：2-3 小时
- **核心内容**：
  - AsyncGetCallTrace 的函数签名
  - 完整的工作流程
  - JVM 内部实现（源码级）
  - 四大安全保证
  - 失败场景和失败率
  - 性能开销量化
- **完成标准**：通过 4 个自测问题
- **面试能力**：能说明 AsyncGetCallTrace 如何解决 Safepoint Bias

#### Day 3: 栈回溯方法对比
- **学习时间**：2-3 小时
- **核心内容**：
  - 四种栈回溯方法的原理
  - 每种方法的优缺点
  - 适用场景分析
  - 组合策略
  - 实战案例
- **完成标准**：通过 4 个自测问题
- **面试能力**：能为不同场景选择合适的栈回溯方法

#### Day 4: VMStructs 偏移推断
- **学习时间**：2-3 小时
- **核心内容**：
  - VMStructs 符号表结构
  - 三种偏移量推断方法
  - 关键偏移量的应用
  - 版本兼容性原理
  - 实战案例
- **完成标准**：通过 4 个自测问题
- **面试能力**：能解释 VMStructs 如何实现版本兼容

#### Day 5: CPU Profiling 深入
- **学习时间**：2-3 小时
- **核心内容**：
  - perf_event 子系统原理
  - 硬件计数器机制
  - perf_event_attr 配置
  - 信号处理流程
  - 三种采样方式对比
  - 权限和性能优化
- **完成标准**：通过 4 个自测问题
- **面试能力**：能深入解释 CPU Profiling 的实现原理

#### Day 6: 多种采样模式
- **学习时间**：2-3 小时
- **核心内容**：
  - CPU / Allocation / Lock / WallClock 四种模式
  - 每种模式的原理和实现
  - 适用场景对比
  - 组合使用策略
  - 实战案例
- **完成标准**：通过 4 个自测问题
- **面试能力**：能根据问题类型选择合适的采样模式

#### Day 7: 火焰图解读 + 实战演练
- **学习时间**：2-3 小时
- **核心内容**：
  - 火焰图的结构和含义
  - 如何解读火焰图
  - 定位性能瓶颈的方法
  - 实战演练（PerformanceDemo）
  - 优化建议
- **完成标准**：能现场演示 profiling 流程
- **面试能力**：能现场演示性能分析并提出优化建议

---

## 🎯 学习建议

### 1. 循序渐进

按照 Day 1 → Day 7 的顺序学习，每天的内容是递进的：
- Day 1-2：核心原理（为什么需要 async-profiler）
- Day 3-4：技术细节（如何实现）
- Day 5-6：采样模式（如何使用）
- Day 7：实战演练（综合应用）

### 2. 重在理解

不要死记硬背，要理解原理：
- 每个概念都要问"为什么"
- 尝试用自己的话复述
- 能够举一反三

### 3. 动手实践

光看不练是不够的：
- 运行测试程序
- 使用 async-profiler 进行 profiling
- 解读火焰图
- 验证文档中的结论

### 4. 自测验证

每天学完后，必须通过自测：
- 4 个自测问题全部通过
- 能流畅回答面试问题
- 能举出具体例子

### 5. 复习巩固

建议多次复习：
- 第一次：完整学习（7 天）
- 第二次：重点复习（3 天）
- 第三次：面试前冲刺（1 天）

---

## 📖 阅读方法

### 快速阅读（1 小时/天）

适合时间紧张的情况：
1. 阅读"核心概念"部分
2. 浏览"面试问答"部分
3. 尝试自测问题
4. 不追求源码级理解

### 深度阅读（2-3 小时/天）

推荐的学习方式：
1. 完整阅读所有内容
2. 理解源码示例
3. 运行验证实验
4. 通过所有自测问题

### 极致深度（4-5 小时/天）

适合追求极致的情况：
1. 阅读扩展材料
2. 研究 JVM 源码
3. 编写测试程序
4. 优化参数调优

---

## 🔑 面试要点

### 核心概念（必须掌握）

1. **Safepoint Bias**：传统 Profiler 的局限性
2. **AsyncGetCallTrace**：核心解决方案
3. **栈回溯方法**：四种方法的对比
4. **perf_event**：CPU Profiling 的原理
5. **采样模式**：四种模式的适用场景
6. **火焰图**：如何解读和定位问题

### 源码理解（加分项）

1. **AsyncGetCallTrace 实现**：forte_fill_call_trace_given_top
2. **栈帧识别**：解释帧 vs 编译帧
3. **VMStructs 推断**：偏移量提取
4. **perf_event 配置**：perf_event_attr

### 实战能力（必考项）

1. **现场演示**：运行 profiling
2. **火焰图解读**：定位性能瓶颈
3. **优化建议**：提出解决方案
4. **问题分析**：根因分析

---

## 📚 参考资料

### 官方文档

- async-profiler GitHub: https://github.com/jvm-profiling-tools/async-profiler
- async-profiler Wiki: https://github.com/jvm-profiling-tools/async-profiler/wiki

### 论文和博客

- "Profiling Java Programs with AsyncGetCallTrace"
- "Safepoints: Meaning, Side Effects and Overhead"
- https://shipilev.net/jvm/anatomy-quarks/22-safepoint-polls/

### JVM 源码

- OpenJDK 11: `/data/workspace/openjdk-cut-new/src/hotspot/`
- async-profiler: `/data/workspace/async-profiler/src/`

---

## ✅ 完成检查

### 学习完成标志

- [ ] 完成 Day 1 学习，通过 4 个自测
- [ ] 完成 Day 2 学习，通过 4 个自测
- [ ] 完成 Day 3 学习，通过 4 个自测
- [ ] 完成 Day 4 学习，通过 4 个自测
- [ ] 完成 Day 5 学习，通过 4 个自测
- [ ] 完成 Day 6 学习，通过 4 个自测
- [ ] 完成 Day 7 学习，能现场演示

### 面试准备完成标志

- [ ] 能流畅回答 28 个核心面试问题
- [ ] 能现场演示 profiling 流程
- [ ] 能解读火焰图并定位问题
- [ ] 能提出优化建议

---

**祝学习顺利！面试成功！**
