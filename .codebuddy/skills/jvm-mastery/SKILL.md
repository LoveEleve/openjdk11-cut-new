---
name: jvm-mastery
description: JVM 源码精通技能。当用户要求深入学习 JVM 源码、分析 JVM 内部实现、调试 JVM 问题时使用此技能。支持六大学习模式：宏观架构、源码分析、GDB 调试、执行流程追踪、对比学习、问题驱动学习。
---

# JVM 源码精通技能

## ⚠️ 强制约束条件

**以下约束在使用本技能时必须严格遵守：**

### 1. 工作目录约束
- **所有源码分析、搜索、调试操作必须限定在 `/data/workspace/openjdk-cut-new` 目录下**
- 搜索文件时，必须使用绝对路径 `/data/workspace/openjdk-cut-new/` 作为搜索根目录
- 不得在其他目录进行 JVM 源码相关的分析操作

### 2. 输出文件存放约束
- **所有生成的临时文件、分析文档、GDB 脚本必须存放在 `jvm-md/{topic}/` 目录下**
- `{topic}` 为当前分析的主题名称，例如：
  - 分析 HeapRegion → `jvm-md/HeapRegion/`
  - 分析 interpreter_init → `jvm-md/Interpreter/`
  - 分析 universe_init → `jvm-md/Universe/`
- 目录结构示例：
  ```
  jvm-md/
  ├── {topic}/                    # 按主题组织
  │   ├── {topic}.md              # 主分析文档
  │   ├── {topic}_outline.md      # 大纲/概览（如果需要）
  │   ├── gdb_{topic}.txt         # GDB 调试脚本
  │   └── tmp-xxx.md              # 其他临时文件
  ├── progress.md                 # 学习进度跟踪
  └── init_globals_outline.md     # 全局大纲
  ```
- **禁止**将文件生成到项目根目录或其他任意位置

---

## 核心理念

**"先见森林，再见树木，最后能种树"**

学习 JVM 源码必须遵循三层递进：
1. **宏观理解**：先知道整体架构和设计哲学
2. **深入细节**：再钻研具体数据结构和算法
3. **实践验证**：通过 GDB 调试、源码修改来巩固理解

---

## 六大学习模式

根据用户的学习需求，选择最合适的模式（可组合使用）：

### 模式 1：宏观架构模式 (Architecture)

**触发词**：整体架构、设计思想、为什么这样设计、全景图

**适用场景**：刚接触某个子系统，需要建立整体认知

**输出要求**：
1. **设计哲学**：这个子系统要解决什么核心问题？有哪些设计权衡？
2. **核心组件图**：用 ASCII 图展示主要组件及其关系
3. **数据流/控制流**：请求/数据如何在组件间流动
4. **关键抽象**：核心接口/基类有哪些？为什么这样抽象？
5. **历史演进**（可选）：从早期版本到现在的演变

**示例输出结构**：
```
## G1 GC 整体架构

### 1. 设计哲学
G1 要解决的核心问题：如何在大堆（数十 GB）下实现可预测的低停顿？

关键设计决策：
- Region 化：将堆分割成固定大小的 Region，支持增量回收
- 并发标记：应用运行时并发标记，减少 STW 时间
- 混合回收：Young GC 时顺便回收部分 Old Region

### 2. 核心组件图
┌─────────────────────────────────────────────────────────────┐
│                      G1CollectedHeap                         │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │HeapRegion   │  │ G1RemSet    │  │ G1ConcurrentMark    │  │
│  │ Manager     │  │ (记忆集)    │  │ (并发标记)          │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ G1Policy    │  │ G1CardTable │  │ G1ConcurrentRefine  │  │
│  │ (策略决策)   │  │ (卡表)      │  │ (并发精炼)          │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
└─────────────────────────────────────────────────────────────┘

### 3. 数据流
写屏障 → 脏卡队列 → Refinement 线程 → 更新 RemSet
                                            ↓
应用分配 → Region 满 → Young GC ← G1Policy 选择 CSet
                          ↓
                    Evacuation（疏散）
```

---

### 模式 2：源码深潜模式 (Deep Dive)

**触发词**：源码分析、实现细节、数据结构、字段含义、内存布局

**适用场景**：需要彻底理解某个类/函数的实现

**输出要求**（必须全部满足）：

#### 2.1 功能定位（必须首先说明！）
- 一句话说明这个类/函数是干什么的
- 它在整体流程中的位置（上游是谁、下游是谁）
- 如果没有它会怎样？它解决了什么问题？

#### 2.2 类继承关系
```
BaseClass
└── ParentClass
    └── TargetClass  ← 分析目标
        └── ChildClass（如果有）
```

#### 2.3 关键字段详解

**不要只列表格！** 每个重要字段必须回答：
- **是什么**：字段类型、大小
- **为什么**：为什么需要这个字段？它解决什么问题？
- **怎么用**：谁读、谁写、什么时候读写？
- **特殊值**：有没有特殊值/魔数？分别代表什么？
- **并发性**：需要原子操作吗？volatile 吗？

**示例**：
```
字段：_top (HeapWord* volatile)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【是什么】指向 Region 中下一个可分配位置的指针

【为什么需要】
  问题：对象分配需要快速找到空闲位置
  解决：维护一个"水位线"指针，分配就是 bump-the-pointer

【怎么用】
  读取：每次分配前检查 _top + size <= _end
  写入：分配后 _top += size（需要原子操作）
  重置：Region 被回收后 _top = _bottom

【特殊值】
  _top == _bottom：Region 完全空闲
  _top == _end：Region 已满，无法分配

【并发性】
  声明为 volatile：多线程可见性
  写入时使用 CAS：par_allocate() 中的 Atomic::cmpxchg
```

#### 2.4 内存布局图

必须包含：
- 每个字段的精确偏移量（通过 GDB 验证）
- 字段大小
- 对齐填充（padding）
- 总大小

```
ClassName (总大小: XXX bytes)
偏移      字段名                 大小    说明
──────────────────────────────────────────────
0x000    [vtable]              8      虚表指针
0x008    _field1               8      说明
0x010    _field2               4      说明
0x014    [padding]             4      对齐填充
0x018    _field3               8      说明
──────────────────────────────────────────────
```

#### 2.5 关联结构递归分析

如果字段指向其他复杂结构，必须递归分析，直到基本类型。

**示例**：分析 HeapRegion 时必须同时分析：
- HeapRegionRemSet → OtherRegionsTable → SparsePRT / PerRegionTable
- G1BlockOffsetTablePart → G1BlockOffsetTable
- HeapRegionType

---

### 模式 3：GDB 实战模式 (Debug)

**触发词**：GDB 调试、验证、实际数据、运行时状态

**适用场景**：需要验证分析结论、查看实际运行时数据

**执行流程**：

#### 3.1 自动生成 GDB 脚本

根据分析目标，自动生成完整的 GDB 调试脚本，保存到 `jvm-md/tmp-file/{topic}/gdb_xxx.txt`

脚本模板：
```gdb
set pagination off
set print pretty on

# 断点设置（选择合适的时机）
b {合适的断点位置}
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# 变量获取
set $var = {表达式}

# 结构体字段打印
printf "\n========== {结构名} ==========\n"
printf "地址: %p\n", $var
printf "字段1: %值格式\n", $var->field1
...

# sizeof 验证
printf "sizeof({结构}): %lu\n", sizeof({结构})

# 偏移量验证
printf "&field - base: %lu\n", (size_t)&$var->field - (size_t)$var

quit
```

#### 3.2 执行并捕获输出

执行 GDB 脚本，捕获完整输出。

#### 3.3 数据解读

对 GDB 输出进行详细解读：
- 每个数值代表什么？
- 是否符合预期？
- 发现了什么有趣的现象？

---

### 模式 4：执行流程追踪模式 (Trace)

**触发词**：执行流程、调用链、从哪里开始、经过哪些步骤、什么时候触发

**适用场景**：理解某个功能的完整执行过程

**输出要求**：

#### 4.1 触发条件
- 什么情况下会触发这个流程？
- 入口函数是什么？
- 调用者是谁？

#### 4.2 调用链图
```
入口函数()
├── 步骤1: function_a()
│   ├── 子步骤: helper_1()
│   └── 子步骤: helper_2()
├── 步骤2: function_b()
│   └── 关键操作: do_something()
└── 步骤3: function_c()
    └── 结束处理: cleanup()
```

#### 4.3 关键节点详解

对调用链中的关键节点，解释：
- 这一步在做什么？
- 输入是什么？输出是什么？
- 有什么副作用？
- 可能失败吗？失败了怎么处理？

#### 4.4 状态变化时间线

```
时间线    状态/事件
──────────────────────────────────
T0       初始状态：...
T1       调用 func_a()：状态变为 ...
T2       调用 func_b()：分配了 ...
T3       调用 func_c()：完成，状态变为 ...
```

---

### 模式 5：对比学习模式 (Compare)

**触发词**：和...的区别、为什么不用...、对比、演进

**适用场景**：通过对比加深理解

**对比维度**：
1. **不同实现的对比**：如 Serial GC vs Parallel GC vs G1 vs ZGC
2. **不同版本的对比**：如 JDK 8 vs JDK 11 vs JDK 17
3. **不同配置的对比**：如小堆 vs 大堆、开启 NUMA vs 关闭
4. **理想方案 vs 实际方案**：为什么不直接用最简单的方案？

**输出格式**：
```
| 对比维度 | 方案 A | 方案 B | 为什么选择 B |
|----------|--------|--------|--------------|
| 性能     | O(n)   | O(1)   | 热路径需要   |
| 内存     | 更少   | 更多   | 空间换时间   |
| 复杂度   | 简单   | 复杂   | 功能需要     |
```

---

### 模式 6：问题驱动模式 (Problem)

**触发词**：为什么要、如何解决、什么问题、设计考虑

**适用场景**：从问题出发理解设计

**输出结构**：

```
## 问题：{具体问题}

### 1. 问题场景
在什么情况下会遇到这个问题？
具体的例子是什么？

### 2. 如果不解决会怎样？
- 性能影响：...
- 正确性影响：...
- 可用性影响：...

### 3. 可选的解决方案
| 方案 | 优点 | 缺点 |
|------|------|------|
| 方案 A | ... | ... |
| 方案 B | ... | ... |

### 4. JVM 的实际选择
选择了方案 X，因为...

### 5. 实现细节
具体代码在哪里？关键数据结构是什么？
```

---

## JVM 学习路径

### 推荐学习顺序

```
Level 1: 基础概念
├── JVM 内存模型（堆、栈、元空间）
├── 对象布局（OOP、Klass）
└── GC 基础概念（什么是垃圾、根对象）

Level 2: G1 GC 核心
├── HeapRegion（√ 已学习）
├── G1CollectedHeap
├── G1RemSet + G1CardTable
├── G1ConcurrentMark
└── G1Policy

Level 3: GC 执行流程
├── Young GC 完整流程
├── Mixed GC 完整流程
├── Full GC 完整流程
└── 并发标记流程

Level 4: 类加载子系统
├── ClassLoader 体系
├── 类加载流程
├── SymbolTable / StringTable
└── Metaspace

Level 5: 运行时
├── 线程模型（JavaThread、VMThread）
├── 同步机制（Monitor、锁优化）
├── 解释器执行
└── JIT 编译

Level 6: 高级主题
├── Safepoint 机制
├── 偏向锁实现
├── 逃逸分析
└── C2 编译优化
```

### 当前进度追踪

在 `jvm-md/` 目录下维护学习进度：
- `jvm-md/progress.md`：已学习的主题
- `jvm-md/G1-GC/`：G1 相关笔记
- `jvm-md/ClassLoading/`：类加载相关笔记
- `jvm-md/Runtime/`：运行时相关笔记

---

## 输出规范

### 文档输出位置

**⚠️ 强制规则**：所有分析文档必须输出到 `jvm-md/{topic}/` 对应目录：

```
jvm-md/
├── Universe/                    # Universe 相关主题
│   ├── universe_init.md
│   ├── universe2_init.md
│   ├── 3.1-create_heap.md
│   └── gdb_universe.txt
├── Interpreter/                 # 解释器相关主题
│   ├── interpreter_init_outline.md
│   ├── generate_normal_entry.md
│   └── gdb_interpreter.txt
├── GC/                          # GC 相关主题
│   ├── HeapRegion.md
│   ├── G1CollectedHeap.md
│   └── G1RemSet.md
├── ClassLoading/                # 类加载相关
├── Runtime/                     # 运行时相关
├── {新主题}/                    # 按需创建新主题目录
│   ├── {主题分析}.md
│   └── gdb_{主题}.txt
├── progress.md                  # 学习进度跟踪
└── init_globals_outline.md      # 全局大纲
```

**创建新文件前必须检查**：
1. 确定当前分析主题属于哪个 `{topic}` 目录
2. 如果目录不存在，先创建目录
3. 文件命名应清晰描述内容

### 图表规范

1. **ASCII 图**：用于内存布局、结构关系（兼容性最好）
2. **Mermaid 图**：用于流程图、时序图（如果用户要求）
3. **表格**：用于字段对比、方案对比

### GDB 数据标注

所有 GDB 验证数据必须标注：
```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
┌─────────────────────────────────────────────┐
│ HeapRegion::GrainBytes = 4,194,304 (4MB)    │
│ HeapRegion::CardsPerRegion = 8,192          │
│ sizeof(HeapRegion) = 432 bytes              │
└─────────────────────────────────────────────┘
```

---

## 质量检查清单

每次分析完成后，自检：

### 宏观层面
- [ ] 是否说明了设计哲学和核心问题？
- [ ] 是否画出了整体架构图？
- [ ] 是否说明了在 JVM 中的位置？

### 细节层面
- [ ] 每个字段是否都解释了"为什么需要"？
- [ ] 是否提供了内存布局图（含偏移量）？
- [ ] 是否递归分析了所有关联结构？

### 验证层面
- [ ] 是否提供了 GDB 脚本？
- [ ] GDB 数据是否有详细解读？
- [ ] 理论分析是否与 GDB 数据一致？

### 实用层面
- [ ] 是否说明了相关 JVM 参数？
- [ ] 是否给出了下一步学习建议？

---

## 标准调试环境

### 强制标准条件

**⚠️ 所有 GDB 调试、源码分析、内存计算必须基于以下标准条件：**

```bash
# JVM 参数（必须严格使用）
-Xms8g -Xmx8g          # 初始堆=最大堆=8GB
-XX:+UseG1GC           # 使用 G1 GC

# 推导配置（基于此标准条件的所有计算）
Region 大小：4MB（G1HeapRegionSize = 4194304）
Region 数量：2048（8GB / 4MB）
CardsPerRegion：8192（4MB / 512B）
CardTable 大小：16MB（8GB / 512B = 16,777,216 bytes）
位图大小：128MB x 2（并发标记用）
```

### GDB 验证要求

1. **启动脚本模板**：
```bash
cd /data/workspace/openjdk-cut-new

# 方式1：完整调试（推荐）
gdb -x {脚本} \
    ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
    -- -XX:+UseG1GC -Xms8g -Xmx8g -Xint \
    -cp /data/workspace/demo/src com.wjcoder.Main

# 方式2：快速验证（-version）
gdb -batch -x {脚本} \
    --args ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
    -XX:+UseG1GC -Xms8g -Xmx8g -version
```

2. **验证标准配置**：
```gdb
# 在 GDB 中必须验证以下常量
printf "HeapRegion::GrainBytes = %u (应为 4194304 = 4MB)\n", HeapRegion::GrainBytes
printf "HeapRegion::CardsPerRegion = %u (应为 8192 = 4MB/512B)\n", HeapRegion::CardsPerRegion
printf "CardTable::card_size = %d (应为 512)\n", CardTable::card_size
```

3. **GDB 数据标注格式**：
```
【GDB 验证】标准条件：-Xms8g -Xmx8g -XX:+UseG1GC
┌────────────────────────────────────────────────────────┐
│ HeapRegion::GrainBytes      = 4,194,304 (4MB) ✓        │
│ HeapRegion::CardsPerRegion  = 8,192 ✓                  │
│ CardTable::card_size        = 512 bytes ✓              │
│ Region 数量                 = 2048 (8GB/4MB) ✓         │
├────────────────────────────────────────────────────────┤
│ sizeof(HeapRegionRemSet)    = XXX bytes                │
│ sizeof(OtherRegionsTable)   = XXX bytes                │
│ sizeof(PerRegionTable)      = XXX bytes                │
└────────────────────────────────────────────────────────┘
```

### 测试程序要求

测试程序必须能触发以下场景：
1. **对象分配**：创建大量对象填满 Eden
2. **跨代引用**：老年代对象引用年轻代对象
3. **GC 触发**：触发 Young GC 或 Mixed GC
4. **RSet 更新**：验证脏卡队列和 Refine 线程

```java
// 推荐测试程序模板
public class Main {
    static Object[] oldGenRefs = new Object[1000];
    
    public static void main(String[] args) throws Exception {
        // 1. 创建老年代引用
        for (int i = 0; i < 1000; i++) {
            oldGenRefs[i] = new byte[1024 * 100]; // 100KB 对象
        }
        
        // 2. 触发 Young GC，同时建立跨代引用
        for (int round = 0; round < 10; round++) {
            for (int i = 0; i < 10000; i++) {
                Object young = new byte[1024]; // 1KB 年轻代对象
                // 随机让老年代引用年轻代
                if (i % 10 == 0) {
                    oldGenRefs[(i/10) % 1000] = young;
                }
            }
            Thread.sleep(100);
        }
        
        // 3. 触发 GC
        System.gc();
        Thread.sleep(1000);
        
        System.out.println("Test completed");
    }
}
```

### 常见错误规避

❌ **错误做法**：
- 使用 `-Xms1g -Xmx1g`（Region 大小会变为 1MB）
- 不指定 `-XX:+UseG1GC`（可能使用其他 GC）
- 在 JVM 初始化完成前读取 `HeapRegion::GrainBytes`（可能读到默认值）

✅ **正确做法**：
- 严格使用 `-Xms8g -Xmx8g -XX:+UseG1GC`
- 在 `G1CollectedHeap::initialize` 完成后验证常量
- 所有内存计算基于 4MB Region / 8192 CardsPerRegion
