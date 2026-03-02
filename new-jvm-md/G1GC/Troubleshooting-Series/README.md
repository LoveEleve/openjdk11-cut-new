# JVM GC 故障排查实战系列

> **所有内容基于真实运行的Demo程序生成的GC日志**
> 
> 理念：拒绝纸上谈兵，一切从真实案例出发

---

## 系列概览

本系列通过4个真实可运行的Java程序，演示GC故障排查的完整流程。每个案例包含：

- ✅ 真实可运行的Demo代码
- ✅ 真实生成的GC日志文件
- ✅ 详细的日志分析过程
- ✅ 根因定位方法
- ✅ 解决方案对比
- ✅ 生产环境最佳实践

---

## 快速导航

| 编号 | 文章 | 场景 | 核心问题 | 真实日志 |
|------|------|------|----------|----------|
| 00 | [系列概述](00-Series-Overview.md) | 方法论 | GC排查五步法 | - |
| 01 | [内存泄漏排查](01-Memory-Leak-Case-Study.md) | 静态缓存泄漏 | Old区持续增长，GC无法回收 | `gc-memory-leak.log` |
| 02 | [GC频繁排查](02-GC-Frequent-Case-Study.md) | 小堆高分配 | GC间隔<1秒，回收正常 | `gc-frequent.log` |
| 03 | [Full GC排查](03-Full-GC-Case-Study.md) | 显式System.gc() | Full GC触发，服务卡顿 | `gc-full-gc.log` |
| 04 | [Humongous对象](04-Humongous-Object-Case-Study.md) | 大对象分配 | RegionSize过小 | `gc-humongous.log` |

---

## 配套资源

### Demo程序

```
demo/GC-Troubleshooting-Demo/
├── src/main/java/com/wjcoder/gc/demo/
│   ├── MemoryLeakDemo.java       # 内存泄漏场景
│   ├── GCFrequentDemo.java       # GC频繁场景
│   ├── FullGCTriggerDemo.java    # Full GC场景
│   └── HumongousObjectDemo.java  # Humongous对象场景
└── bin/                          # 编译后的class文件
```

### 真实GC日志

```
demo/GC-Troubleshooting-Demo/
├── gc-memory-leak.log      # 内存泄漏真实GC日志 (8.4KB)
├── gc-frequent.log         # 频繁GC真实日志 (22.9KB)
├── gc-full-gc.log          # Full GC真实日志 (11.5KB)
└── gc-humongous.log        # Humongous对象日志 (1KB)
```

---

## 快速开始

### 1. 编译Demo

```bash
cd demo/GC-Troubleshooting-Demo
mkdir -p bin
javac -d bin src/main/java/com/wjcoder/gc/demo/*.java
```

### 2. 运行并生成GC日志

```bash
# 运行内存泄漏Demo
java -Xms512m -Xmx512m -XX:+UseG1GC \
  -Xlog:gc*:file=gc-memory-leak.log:time,uptime,level,tags \
  -XX:+HeapDumpOnOutOfMemoryError \
  -cp bin com.wjcoder.gc.demo.MemoryLeakDemo
```

### 3. 分析GC日志

```bash
# 查看GC概览
cat gc-memory-leak.log | grep "Pause Young\|Pause Full"

# 统计GC次数
cat gc-memory-leak.log | grep -c "GC("

# 查看Old区增长
cat gc-memory-leak.log | grep "Old regions"
```

---

## 核心价值

### 与传统GC教程的区别

| 特性 | 传统教程 | 本系列 |
|------|----------|--------|
| GC日志来源 | 假设/模拟 | **真实运行生成** |
| Demo代码 | 伪代码 | **可运行Java程序** |
| 分析深度 | 表面解释 | **逐行日志分析** |
| 解决方案 | 泛泛而谈 | **参数对比实测** |
| 生产价值 | 理论参考 | **直接可用** |

### 适用读者

- 🔧 **运维工程师**：快速诊断生产GC问题
- 🧑‍💻 **Java开发**：理解GC原理，写出GC友好的代码
- 📊 **性能工程师**：系统性GC性能调优
- 🎓 **学习者**：通过真实案例学习JVM GC

---

## GC排查速查表

### 内存泄漏诊断

```
症状：堆内存持续增长，GC回收率<30%
检查：
1. Old Region是否持续增长？
2. GC后堆内存是否几乎不下降？
3. 是否有静态集合类？
工具：MAT分析Heap Dump
```

### GC频繁诊断

```
症状：GC间隔<1秒，回收率正常
检查：
1. 堆内存是否设置过小？
2. 分配速率是否过高？
3. 容器内存limit是否远大于-Xmx？
解决：增大堆或降低分配速率
```

### Full GC诊断

```
症状：Full GC触发，服务卡顿
检查：
1. 触发原因是System.gc()？
2. 老年代是否不足？
3. 元空间是否不足？
解决：启用DisableExplicitGC或增大堆
```

---

## 联系与反馈

如有问题或建议，欢迎交流讨论。

---

**重要提示**：本系列所有内容基于OpenJDK 11 slowdebug版本，不同JDK版本的行为可能略有差异。
