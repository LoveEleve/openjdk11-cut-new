# G1 Young GC 核心模块学习总结

> **学习日期**：2026-02-12  
> **文档数量**：8 份核心模块 + 1 份全流程  
> **总内容量**：~293 KB  
> **学习时长**：建议 2-3 周（每天 2 小时）

---

## 一、学习路径建议

### 阶段一：基础设施（1 周）

**学习顺序**：
1. G1CardTable → 理解跨代引用追踪
2. G1BlockOffsetTable → 理解对象定位
3. G1HotCardCache → 理解性能优化

**核心问题**：
- G1 如何追踪跨代引用？
- 如何快速找到对象起始地址？
- 如何避免重复处理热门卡？

**实践建议**：
```bash
# 使用 GDB 验证卡表状态
gdb -x verify_card_table.gdb --args java -Xms8g -Xmx8g -XX:+UseG1GC ...

# 观察卡状态变化
break G1CardTable::mark_card_deferred
commands
  printf "card_index=%lu, old_val=%d, new_val=%d\n", ...
  continue
end
```

### 阶段二：执行核心（1 周）

**学习顺序**：
1. G1RootProcessor → 理解 GC Roots
2. G1ParScanThreadState → 理解 Evacuation
3. G1PLABAllocator → 理解快速分配
4. G1ScanClosures → 理解引用扫描

**核心问题**：
- G1 有哪些 GC Roots？
- 对象如何复制？引用如何更新？
- 如何实现无锁快速分配？
- 闭包体系如何协作？

**实践建议**：
```bash
# 观察对象复制流程
gdb -x observe_object_copy.gdb

# 观察 PLAB 分配
gdb -x observe_plab_allocate.gdb

# 观察引用扫描
gdb -x observe_scan_evacuated_obj.gdb
```

### 阶段三：完整流程（3-5 天）

**学习顺序**：
1. G1YoungGC-FullWorkflow → 理解完整流程
2. 各模块串联 → 理解协作关系

**核心问题**：
- Young GC 有哪些阶段？各阶段耗时？
- 如何预测暂停时间？
- 如何优化 Young GC 性能？

**实践建议**：
```bash
# 观察完整 GC 流程
gdb -x observe_young_gc_flow.gdb

# 统计各阶段耗时
gdb -x stat_gc_phases.gdb
```

---

## 二、核心知识点速查表

### 1. 关键数据结构

| 数据结构 | 大小 | 作用 | 关键算法 |
|----------|------|------|----------|
| **CardTable** | 16 MB | 跨代引用标记 | 卡索引 = 地址 / 512 |
| **HotCardCache** | 1024 slots | 热卡缓存 | 环形缓冲 + CAS |
| **BlockOffsetTable** | 16 MB | 对象定位 | 对数跳跃（基 16） |
| **PLAB** | 4-16 KB | 快速分配 | bump-the-pointer |
| **RefToScanQueue** | 可变 | 任务队列 | 本地无锁 + 窃取 CAS |

### 2. 关键性能指标

| 操作 | 耗时 | 优化技术 | 提升倍数 |
|------|------|----------|----------|
| **PLAB 分配** | ~5ns | bump-the-pointer | ~20x |
| **Region CAS 分配** | ~100ns | CAS | 基准 |
| **预取 mark word** | ~5ns | Prefetch | ~20x |
| **无预取 cache miss** | ~100ns | - | 基准 |
| **标记脏卡** | ~5ns | 延迟更新 | ~10x |
| **直接更新 RSet** | ~50ns | - | 基准 |

### 3. 关键算法

#### 衰减平均

```cpp
// 最近数据权重更高，快速适应变化
davg = weight * new_val + (1 - weight) * old_davg;

// 默认 weight = 0.7
// 示例：
// 第1次：actual=50ms → davg=50ms
// 第2次：actual=55ms → davg=0.7*55+0.3*50=53.5ms
// 第3次：actual=48ms → davg=0.7*48+0.3*53.5=49.65ms
```

#### 预测区间

```cpp
// 提供缓冲，避免过于乐观
prediction = davg + sigma * stddev;

// 默认 sigma = 0.5
// 示例：
// davg=50ms, stddev=10ms
// prediction=50+0.5*10=55ms
```

#### Work Stealing 终止协议

```cpp
// 原子计数 + 任务检查
if (Atomic::add(1, &_n_terminated) == _n_threads) {
  return true;  // 所有线程已终止
}

while (true) {
  if (_queues->has_tasks()) {
    Atomic::sub(1, &_n_terminated);
    return false;  // 有新任务，取消终止
  }
  if (_n_terminated == _n_threads) {
    return true;  // 确认所有线程终止
  }
  os::naked_yield();
}
```

---

## 三、面试高频问题

### Level 1：基础理解

**Q1: G1 为什么叫 Garbage-First？**

A: G1 会优先回收垃圾最多的 Region。通过 Concurrent Mark 识别出垃圾比例高的 Region，优先回收这些 Region，以最小的代价回收最多的空间。

**Q2: G1 和 CMS 有什么区别？**

A:
- G1: 基于 Region，增量回收，可预测暂停时间，整理碎片
- CMS: 基于传统分代，全老年代回收，不可预测暂停，不整理碎片

**Q3: G1 的 Region 大小如何确定？**

A: Region 大小 = 2^floor(log2(堆大小 / 2048))，范围为 1MB-32MB。标准配置下（8GB 堆），Region = 4MB。

### Level 2：机制理解

**Q4: G1 如何处理跨代引用？**

A: 通过 RSet（Remembered Set）追踪跨 Region 引用。写屏障在更新引用时标记源卡为脏卡，GC 时扫描脏卡找到跨代引用。

**Q5: G1 如何实现无锁对象复制？**

A: 使用 CAS 转发指针。多个线程同时复制同一对象时，通过 CAS 安装转发指针，只有一个线程成功复制，其他线程使用已复制的对象。

**Q6: PLAB 有什么作用？为什么比直接从 Region 分配快？**

A: PLAB（线程本地分配缓冲区）避免 CAS 竞争。直接从 Region 分配需要 CAS 竞争同一个 `_top` 指针，PLAB 使用 bump-the-pointer 无锁分配，提升 ~20 倍。

### Level 3：深度理解

**Q7: G1 如何预测 GC 暂停时间？**

A: 基于历史数据的衰减平均 + 标准差。追踪根集扫描、RSet 处理、对象复制等操作的耗时，使用衰减平均快速适应变化，加上标准差作为缓冲。

**Q8: Work Stealing 如何保证正确性？**

A: 
1. 本地操作无锁（pop_local/push）
2. 窃取操作使用 CAS（pop_global）
3. 终止协议使用原子计数（offer_termination）
4. 终止前再次检查是否有新任务

**Q9: G1 如何处理 Evacuation Failure？**

A: 对象自转发（forward_to_self），保留在原 Region。标记 Region 为 evacuation_failed，不被释放，下次 GC 再次尝试回收。

### Level 4：性能优化

**Q10: 如何优化 G1 Young GC 性能？**

A:
1. **年轻代大小**：根据对象生命周期调整（G1NewSizePercent）
2. **并行度**：根据 CPU 核心数调整（ParallelGCThreads）
3. **PLAB 大小**：根据浪费率调整（G1PLABSize）
4. **对象分配**：避免大对象、减少 TLAB 分配失败
5. **RSet**：减少跨 Region 引用

---

## 四、常见问题排查

### 问题 1：Young GC 暂停时间过长

**现象**：Young GC 暂停时间超过目标（200ms）

**可能原因**：
1. 存活对象过多 → 增大年轻代
2. RSet 过大 → 减少跨 Region 引用
3. 根集过大 → 检查是否有过多的线程/类加载器

**排查方法**：
```bash
# 启用详细日志
-Xlog:gc*=debug

# 查看各阶段耗时
# [GC pause (young), 0.0500000 secs]
#  [GC Worker Start (ms): Min: 123.4, Avg: 123.5, Max: 123.6]
#  [Ext Root Scanning (ms): Min: 5.2, Avg: 6.3, Max: 8.1]
#  [Update RS (ms): Min: 3.1, Avg: 4.2, Max: 5.0]
#  [Scan RS (ms): Min: 2.0, Avg: 2.5, Max: 3.0]
#  [Object Copy (ms): Min: 25.3, Avg: 28.5, Max: 32.1]
```

### 问题 2：Evacuation Failure

**现象**：`[GC evacuation failure]`

**可能原因**：
1. 老年代空间不足
2. 无法分配新 Region
3. 堆大小达到上限

**排查方法**：
```bash
# 查看堆使用情况
jmap -heap <pid>

# 查看错误日志
hs_err_pid*.log

# 启用错误日志
-XX:HeapDumpOnOutOfMemoryError
```

**解决方案**：
```bash
# 扩容堆
-Xmx16g

# 调整 IHOP
-XX:InitiatingHeapOccupancyPercent=35

# 增加年轻代
-XX:G1MaxNewSizePercent=50
```

### 问题 3：Work Stealing 不均衡

**现象**：某些 GC 线程很忙，某些很空闲

**可能原因**：
1. 任务分配不均
2. GC 线程数过多或过少
3. Work Stealing 策略不适合当前负载

**排查方法**：
```bash
# 启用任务统计
-Xlog:gc+task+stats=debug

# 输出示例：
# GC Termination Stats
# thr   elapsed  --strong roots-- -------termination------- ------waste (KiB)------
#  0     45.2       10.3     22.8%     5.1    11.3%     12     1024      512      128
#  1     43.8        9.8     22.4%     4.8    11.0%     11      987      498      115
```

---

## 五、进阶学习建议

### 1. 源码阅读顺序

```
第 1 遍：理解流程
  ├─→ g1CollectedHeap.cpp: collect() → do_collection_pause_at_safepoint()
  ├─→ g1ParScanThreadState.cpp: copy_to_survivor_space()
  └─→ g1RootProcessor.cpp: evacuate_roots()

第 2 遍：理解细节
  ├─→ g1Allocator.cpp: par_allocate_during_gc()
  ├─→ g1OopClosures.inline.hpp: do_oop_work()
  └─→ g1RemSet.cpp: scan_rem_set()

第 3 遍：理解优化
  ├─→ g1HotCardCache.cpp: add()
  ├─→ g1BlockOffsetTable.cpp: block_start_const()
  └─→ g1Policy.cpp: predict_young_collection_pause_time()
```

### 2. 实验环境搭建

```bash
# 编译 Debug 版 JVM
cd /data/workspace/openjdk-cut-new
bash configure --with-debug-level=slowdebug
make images

# 设置标准运行环境
export JVM=/data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java
export ARGS="-Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main"

# 验证环境
$JVM -version
```

### 3. 性能测试用例

```java
// 测试对象分配速率
for (int i = 0; i < 10000000; i++) {
    byte[] arr = new byte[1024];  // 1KB 对象
    // arr 立即死亡
}

// 测试存活对象比例
List<byte[]> list = new ArrayList<>();
for (int i = 0; i < 1000000; i++) {
    if (i % 10 == 0) {
        list.add(new byte[1024]);  // 10% 存活
    } else {
        byte[] arr = new byte[1024];  // 90% 死亡
    }
}

// 测试跨 Region 引用
class CrossRegionRef {
    Object ref;  // 可能跨 Region
}
CrossRegionRef[] refs = new CrossRegionRef[10000];
for (int i = 0; i < refs.length; i++) {
    refs[i] = new CrossRegionRef();
    refs[i].ref = new Object();  // 跨 Region 引用
}
```

---

## 六、参考资源

### 官方文档

- [OpenJDK G1 GC](https://openjdk.java.net/jeps/307)
- [HotSpot Virtual Machine Garbage Collection Tuning Guide](https://docs.oracle.com/en/java/javase/11/gctuning/)

### 推荐书籍

- 《Java Performance》- Scott Oaks
- 《Garbage Collection Handbook》- Richard Jones
- 《深入理解 Java 虚拟机》- 周志明

### 本地文档

- **进度总览**：`jvm-md/progress_comprehensive.md`
- **完整知识体系**：`jvm-md/README-Complete-Knowledge-System.md`
- **G1YoungGC 流程**：`jvm-md/G1CollectedHeap-Rewrite/G1-YoungGC-FullWorkflow.md`

---

## 七、学习成果自测

### 基础测试（应该能回答）

1. G1 的 Region 大小如何计算？
2. 什么是双缓冲位图？为什么需要？
3. G1 有哪些 GC Roots？
4. 什么是 PLAB？为什么比直接分配快？
5. Work Stealing 如何工作？

### 进阶测试（应该能深入）

1. 详细解释 G1CardTable 的三种状态
2. 描述 Evacuation 的完整流程
3. 解释 CAS 转发指针如何保证并发安全
4. 分析衰减平均算法的优缺点
5. 如何优化 Young GC 性能？

### 专家测试（应该能创新）

1. 设计一个更好的 Work Stealing 策略
2. 分析 G1 在大内存场景的瓶颈
3. 对比 G1 和 ZGC 的并发设计
4. 设计一个自适应 PLAB 大小算法
5. 分析 G1 在容器环境的问题

---

**祝学习顺利！如有问题，请参考各模块详细文档或源码。**
