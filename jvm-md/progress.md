# JVM 源码学习进度

> 更新时间: 2026-02-05

## 学习路径

```
Level 1: 基础概念
├── [ ] JVM 内存模型（堆、栈、元空间）
├── [ ] 对象布局（OOP、Klass）
└── [ ] GC 基础概念（什么是垃圾、根对象）

Level 2: G1 GC 核心
├── [x] HeapRegion ✓ (2026-02-05)
├── [~] G1CollectedHeap (universe_init 中分析过部分)
├── [ ] G1RemSet + G1CardTable
├── [ ] G1ConcurrentMark
└── [ ] G1Policy

Level 3: GC 执行流程
├── [ ] Young GC 完整流程
├── [ ] Mixed GC 完整流程
├── [ ] Full GC 完整流程
└── [ ] 并发标记流程

Level 4: 类加载子系统
├── [ ] ClassLoader 体系
├── [ ] 类加载流程
├── [~] SymbolTable (universe_init 中分析过)
├── [~] StringTable (universe_init 中分析过)
└── [ ] Metaspace

Level 5: 运行时
├── [ ] 线程模型（JavaThread、VMThread）
├── [ ] 同步机制（Monitor、锁优化）
├── [ ] 解释器执行
└── [ ] JIT 编译

Level 6: 高级主题
├── [ ] Safepoint 机制
├── [ ] 偏向锁实现
├── [ ] 逃逸分析
└── [ ] C2 编译优化
```

## 已完成的分析

### 1. universe_init() 创世纪方法（深度分析）
- **日期**: 2026-02-05
- **模式**: jvm-mastery Skill 组合模式分析
- **内容**: 
  - 宏观架构：JVM 启动流程中的位置
  - 执行流程：14 步调用链详解
  - 源码深潜：NarrowPtrStruct、LatestMethodCache 结构
  - GDB 验证：压缩指针、堆配置、符号表等
  - 对比学习：universe_init vs universe2_init vs universe_post_init
- **验证**: GDB 完整验证
- **文档**: `jvm-md/Universe/universe_init.md`

### 2. HeapRegion 详细结构
- **日期**: 2026-02-05
- **内容**: 
  - HeapRegion 432 字节结构详解
  - 所有字段含义和偏移量
  - HeapRegionRemSet 记忆集
  - HeapRegionType 类型系统
- **验证**: GDB 完整验证
- **文档**: `jvm-md/G1-GC/HeapRegion.md`

## GDB 验证数据汇总

### 标准环境
```
-Xms8g -Xmx8g -XX:+UseG1GC
Region 大小: 4MB
Region 数量: 2048
堆范围: [0x600000000, 0x800000000)
```

### 关键数据
| 结构 | 大小 | 地址(示例) |
|------|------|------------|
| G1CollectedHeap | ~4KB | 0x7ffff0032660 |
| HeapRegion | 432 bytes | 0x7ffff009f420 |
| HeapRegionRemSet | 328 bytes | 0x7ffff009f610 |
| G1BlockOffsetTable | - | 0x7ffff005a140 |

## 下一步计划

1. **G1RemSet + G1CardTable**: 理解跨 Region 引用追踪机制
2. **G1ConcurrentMark**: 理解并发标记算法（SATB）
3. **Young GC 流程**: 从触发到完成的完整过程

---

*使用 `jvm-mastery` skill 继续学习*
