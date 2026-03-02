# JVM GC 故障排查实战系列

> **所有内容基于真实运行的Demo程序生成的GC日志，非纸上谈兵**
> 
> 环境：OpenJDK 11 slowdebug + G1 GC

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本系列是 **G1 GC 故障排查实战案例集**：基于真实运行的 Demo 程序和真实 GC 日志，覆盖内存泄漏、GC 频繁、Full GC、Humongous 对象等常见生产问题，提供从「发现问题」到「定位根因」到「优化方案」的完整排查流程。

### 0.2 为什么需要？

GC 调优是 Java 工程师的核心技能之一，但很多人只会背参数，不会看日志、不会分析根因。本系列通过真实案例，建立「看到 GC 日志 → 推断 JVM 内部状态 → 定位问题根因」的完整思维链路。

### 0.3 系列文档

| 编号 | 主题 | 核心问题 |
|------|------|---------|
| 01 | 内存泄漏排查 | Old 区持续增长，Full GC 后不降 |
| 02 | GC 频繁排查 | Young GC 过于频繁，吞吐量下降 |
| 03 | Full GC 排查 | Full GC 触发原因分析与优化 |
| 04 | Humongous 对象 | 大对象分配导致的 GC 问题 |

### 0.4 排查方法论

**三步排查法**：
1. **看日志**：从 GC 日志中提取关键指标（GC 频率/停顿时间/堆占用变化）
2. **推状态**：根据指标推断 JVM 内部状态（哪个区域有问题？什么对象在增长？）
3. **找根因**：结合代码和 JVM 内部机制，定位根本原因并给出优化方案

---

## 系列介绍

本系列完全基于**真实运行的Java程序**和**真实生成的GC日志**进行分析，拒绝空洞的理论讲解。

### 核心理念

```
实战 = 可运行的Demo + 真实的GC日志 + 详细的分析过程
```

### 场景覆盖

| 编号 | 场景 | 特征 | 危险程度 |
|------|------|------|---------|
| 01 | 内存泄漏 | 堆内存持续增长，GC无法回收 | 🔴 P0 |
| 02 | GC过于频繁 | 小堆+高分配，STW累积 | 🟠 P1 |
| 03 | Humongous对象问题 | 大对象分配导致碎片 | 🟡 P2 |
| 04 | Full GC触发 | 老年代/元空间不足 | 🔴 P0 |
| 05 | GC长停顿 | 单次GC时间超标 | 🔴 P0 |

### 配套Demo程序

所有Demo位于：`demo/GC-Troubleshooting-Demo/`

```
src/main/java/com/wjcoder/gc/demo/
├── MemoryLeakDemo.java       # 内存泄漏场景
├── GCFrequentDemo.java       # GC频繁场景
├── HumongousObjectDemo.java  # 大对象问题场景
└── FullGCTriggerDemo.java    # Full GC触发场景
```

### 真实GC日志文件

```
demo/GC-Troubleshooting-Demo/
├── gc-memory-leak.log      # 内存泄漏真实GC日志
├── gc-frequent.log         # 频繁GC真实日志
├── gc-humongous.log        # Humongous对象日志
└── gc-full-gc.log          # Full GC真实日志
```

---

## 方法论：GC问题排查五步法

```
┌─────────────────────────────────────────────────────────────────┐
│                    GC问题排查五步法                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Step 1: 确认问题现象                                            │
│    ├── GC日志分析（频率、耗时、回收效率）                          │
│    ├── 监控指标确认（内存曲线、CPU、吞吐量）                       │
│    └── 业务影响评估（响应时间、错误率）                           │
│                         ↓                                       │
│  Step 2: 定位根因                                                │
│    ├── 内存泄漏？ → Heap Dump分析                                │
│    ├── GC频繁？ → 分配速率 vs 堆大小                              │
│    ├── 长停顿？ → 具体Phase分析                                  │
│    └── Full GC？ → 触发原因分析                                  │
│                         ↓                                       │
│  Step 3: 复现验证                                                │
│    ├── 本地复现（调整参数模拟）                                   │
│    ├── 压测验证（JMeter等工具）                                   │
│    └── 生产灰度（小流量验证）                                     │
│                         ↓                                       │
│  Step 4: 制定优化方案                                            │
│    ├── 参数调优（堆大小、GC策略、RegionSize）                      │
│    ├── 代码优化（减少对象分配、修复泄漏）                          │
│    └── 架构优化（分库分表、异步化）                               │
│                         ↓                                       │
│  Step 5: 验证效果                                                │
│    ├── GC日志对比                                                │
│    ├── 监控指标对比                                              │
│    └── 业务指标验证                                              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## G1 GC日志关键指标速查

### Young GC日志解读

```
[gc           ] GC(1) Pause Young (Normal) (G1 Evacuation Pause) 40M->17M(512M) 549.189ms
│              │    │         │                    │              │      │    │
│              │    │         │                    │              │      │    └── GC耗时
│              │    │         │                    │              │      └─────── GC后堆大小
│              │    │         │                    │              └────────────── GC前堆大小
│              │    │         │                    └───────────────────────────── GC原因
│              │    │         └────────────────────────────────────────────────── GC类型
│              │    └──────────────────────────────────────────────────────────── GC编号
│              └───────────────────────────────────────────────────────────────── 暂停类型
└──────────────────────────────────────────────────────────────────────────────── GC标签
```

### 关键指标

| 指标 | 说明 | 健康阈值 | 异常表现 |
|------|------|---------|---------|
| GC频率 | 单位时间GC次数 | Young GC < 1次/秒 | 连续GC、GC间隔<1s |
| GC耗时 | 单次GC暂停时间 | < 100ms | > 200ms（需关注）> 1s（严重）|
| 回收效率 | (GC前-GC后)/GC前 | Young GC > 80% | < 50%（内存泄漏信号）|
| Old区增长 | 老年代Region增长 | 缓慢增长 | 每次GC后持续增长 |

### Region状态解读

```
Eden regions: 25->0(21)    # GC前25个Eden Region -> GC后0个 -> 目标21个
Survivor regions: 0->4(4)  # GC前0个Survivor -> GC后4个 -> 目标4个
Old regions: 0->13         # GC前0个Old -> GC后13个（对象晋升）
Humongous regions: 1->1    # GC前后都是1个Humongous Region
```

---

## 系列文章导航

### 已发布

1. **01-内存泄漏排查实战** - 基于真实Demo分析静态缓存泄漏
2. **02-GC频繁排查实战** - 小堆高分配场景分析
3. **03-Humongous对象问题排查** - 大对象分配优化
4. **04-Full GC触发排查** - System.gc()和晋升失败分析

### 待更新

5. **05-GC长停顿排查** - Evacuation时间过长分析
6. **06-生产环境GC调参** - 从P0事故中学习
7. **07-MAT堆Dump分析实战** - 使用Eclipse MAT定位泄漏

---

## 快速开始

### 运行Demo并生成GC日志

```bash
# 1. 进入Demo目录
cd demo/GC-Troubleshooting-Demo

# 2. 编译
mkdir -p bin
javac -d bin src/main/java/com/wjcoder/gc/demo/*.java

# 3. 运行内存泄漏Demo
java -Xms512m -Xmx512m -XX:+UseG1GC \
  -Xlog:gc*:file=gc-memory-leak.log:time,uptime,level,tags \
  -XX:+HeapDumpOnOutOfMemoryError \
  -cp bin com.wjcoder.gc.demo.MemoryLeakDemo
```

### 分析GC日志

```bash
# 查看GC概览
cat gc-memory-leak.log | grep "Pause Young\|Pause Full"

# 统计GC次数和总耗时
cat gc-memory-leak.log | grep -c "GC("
cat gc-memory-leak.log | grep "Pause Young" | awk -F' ' '{sum+=$NF} END {print sum}'

# 查看Old区增长趋势
cat gc-memory-leak.log | grep "Old regions"
```

---

## 总结

本系列的核心价值：

1. **真实性**：所有日志来自真实运行的程序
2. **可操作性**：每个场景都有可复现的Demo
3. **系统性**：从现象到根因到优化的完整链路
4. **实用性**：可直接应用到生产环境的问题排查

开始你的GC故障排查之旅吧！
