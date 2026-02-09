# G1 调优参数专题大纲

## 专题目标
深入理解 G1 GC 的所有关键调优参数，掌握如何根据应用场景配置最优参数组合。

---

## 第一部分：基础配置参数 ⭐⭐⭐（核心必学）

### 1.1 堆大小与 Region 配置
| 参数 | 默认值 | 说明 | 调优建议 |
|-----|-------|------|---------|
| `-Xms` / `-Xmx` | - | 堆初始/最大大小 | 必须设置相同，避免动态调整 |
| `G1HeapRegionSize` | 0 (自动) | Region 大小 | 1-32MB，2的幂次，通常让 JVM 自动选择 |
| `G1ReservePercent` | 10 | 堆保留空间百分比 | 防止晋升失败，大堆可适当降低 |

**源码位置**：`g1_globals.hpp:188-199`, `heapRegion.cpp`

### 1.2 暂停时间目标
| 参数 | 默认值 | 说明 | 调优建议 |
|-----|-------|------|---------|
| `MaxGCPauseMillis` | 200 | 目标最大 GC 暂停时间 | 根据 SLA 设置，100-500ms 常见 |
| `GCTimeRatio` | 12 | GC 时间占比目标 | 计算：1/(1+GCTimeRatio)，默认约 8% |

**源码位置**：`g1Policy.cpp`, `g1MMUTracker.hpp`

---

## 第二部分：年轻代调优 ⭐⭐⭐（核心必学）

### 2.1 年轻代大小配置
| 参数 | 默认值 | 说明 | 调优建议 |
|-----|-------|------|---------|
| `G1NewSizePercent` | 5 | 年轻代最小占比 | 影响 Eden 初始大小 |
| `G1MaxNewSizePercent` | 60 | 年轻代最大占比 | 防止年轻代过大导致长暂停 |
| `NewRatio` | 2 | 老年代/年轻代比例 | G1 中不推荐直接使用 |

**源码位置**：`g1YoungGenSizer.cpp`, `g1_globals.hpp:223-233`

### 2.2 年轻代 GC 策略
| 参数 | 默认值 | 说明 | 调优建议 |
|-----|-------|------|---------|
| `G1HeapWastePercent` | 5 | 可容忍的堆浪费百分比 | 增大可减少 Mixed GC 频率 |
| `G1MixedGCCountTarget` | 8 | 标记后 Mixed GC 目标次数 | 控制增量回收速度 |

**源码位置**：`g1Policy.cpp`, `g1_globals.hpp:241-248`

---

## 第三部分：Mixed GC 调优 ⭐⭐⭐（核心必学）

### 3.1 CSet 选择策略
| 参数 | 默认值 | 说明 | 调优建议 |
|-----|-------|------|---------|
| `G1MixedGCLiveThresholdPercent` | 85 | Region 存活率阈值 | 超过此值不回收，降低可减少碎片 |
| `G1OldCSetRegionThresholdPercent` | 10 | 每次 Mixed GC 最多回收老年代比例 | 控制单次暂停时间 |

**源码位置**：`collectionSetChooser.hpp`, `g1_globals.hpp:235-267`

### 3.2 并发标记触发
| 参数 | 默认值 | 说明 | 调优建议 |
|-----|-------|------|---------|
| `InitiatingHeapOccupancyPercent` | 45 | 触发并发标记的堆占用率 | 降低可提前开始标记，减少 Full GC |
| `G1UseAdaptiveIHOP` | true | 自适应调整 IHOP | 建议开启，让 JVM 自动优化 |

**源码位置**：`g1ConcurrentMark.cpp`, `g1_globals.hpp:48-58`

---

## 第四部分：Remembered Set 调优 ⭐⭐（进阶）

### 4.1 RSet 内存配置
| 参数 | 默认值 | 说明 | 调优建议 |
|-----|-------|------|---------|
| `G1RSetRegionEntries` | 0 (自动) | Fine 模式最大 Region 数 | 大堆且引用多可适当增大 |
| `G1RSetSparseRegionEntries` | 0 (自动) | Sparse 模式最大条目数 | 通常保持自动 |

**源码位置**：`g1_globals.hpp:166-181`

### 4.2 并发 Refine 线程
| 参数 | 默认值 | 说明 | 调优建议 |
|-----|-------|------|---------|
| `G1ConcRefinementThreads` | 0 (自动) | Refine 线程数 | 通常等于 GC 线程数 |
| `G1RSetUpdatingPauseTimePercent` | 10 | GC 暂停中用于 RSet 更新的时间占比 | 增大可减少并发负担 |

**源码位置**：`g1ConcurrentRefine.cpp`, `g1_globals.hpp:145-205`

### 4.3 三色阈值配置
| 参数 | 默认值 | 说明 | 调优建议 |
|-----|-------|------|---------|
| `G1ConcRefinementGreenZone` | 0 (自动) | 不处理脏卡的缓冲区数量 | 保持自动 |
| `G1ConcRefinementYellowZone` | 0 (自动) | 逐渐激活 Refine 线程 | 保持自动 |
| `G1ConcRefinementRedZone` | 0 (自动) | 全速处理阈值 | 保持自动 |

**源码位置**：`g1_globals.hpp:115-143`

---

## 第五部分：并发标记调优 ⭐⭐（进阶）

### 5.1 并发标记参数
| 参数 | 默认值 | 说明 | 调优建议 |
|-----|-------|------|---------|
| `G1ConcMarkStepDurationMillis` | 10 | 单个并发标记步骤目标时间 | 降低可提高响应性 |
| `G1ConcRefinementServiceIntervalMillis` | 300 | Refine 线程唤醒间隔 | 通常无需调整 |

**源码位置**：`g1_globals.hpp:72-136`

### 5.2 SATB 队列配置
| 参数 | 默认值 | 说明 | 调优建议 |
|-----|-------|------|---------|
| `G1SATBBufferSize` | 1K | SATB 缓冲区大小 | 高并发可适当增大 |
| `G1SATBBufferEnqueueingThresholdPercent` | 60 | SATB 缓冲区入队阈值 | 保持默认 |

**源码位置**：`g1_globals.hpp:91-105`

---

## 第六部分：大对象与特殊场景 ⭐⭐（进阶）

### 6.1 Humongous 对象
| 参数 | 默认值 | 说明 | 调优建议 |
|-----|-------|------|---------|
| `G1EagerReclaimHumongousObjects` | true | 积极回收死亡大对象 | 建议开启 |
| `G1EagerReclaimHumongousObjectsWithStaleRefs` | true | 回收有陈旧引用的大对象 | 建议开启 |

**源码位置**：`g1_globals.hpp:253-258`

### 6.2 堆扩展与压缩
| 参数 | 默认值 | 说明 | 调优建议 |
|-----|-------|------|---------|
| `G1ExpandByPercentOfAvailable` | 20 | 堆扩展时占可用空间的比例 | 大堆可适当降低 |

**源码位置**：`g1_globals.hpp:107-109`

---

## 第七部分：诊断与日志 ⭐（工具）

### 7.1 日志配置
```bash
# 基础 GC 日志
-Xlog:gc*:file=gc.log:time,uptime,level,tags:filecount=5,filesize=100m

# 详细 GC 日志
-Xlog:gc+phases=debug,gc+remset=debug,gc+task=debug

# 暂停时间直方图
-Xlog:safepoint=debug
```

### 7.2 诊断参数
| 参数 | 说明 |
|-----|------|
| `G1SummarizeRSetStatsPeriod` | 定期输出 RSet 统计信息 |
| `G1VerifyRSetsDuringFullGC` | Full GC 时验证 RSet |

**源码位置**：`g1_globals.hpp:64-70`

---

## 第八部分：实战场景与参数组合 ⭐⭐⭐（实战）

### 8.1 低延迟场景（< 100ms）
```bash
-Xms8g -Xmx8g \
-XX:MaxGCPauseMillis=100 \
-XX:G1NewSizePercent=20 \
-XX:G1MaxNewSizePercent=30 \
-XX:InitiatingHeapOccupancyPercent=35 \
-XX:G1MixedGCLiveThresholdPercent=80 \
-XX:G1HeapWastePercent=10
```

### 8.2 大堆场景（> 32GB）
```bash
-Xms64g -Xmx64g \
-XX:MaxGCPauseMillis=200 \
-XX:G1HeapRegionSize=16m \
-XX:G1NewSizePercent=10 \
-XX:G1MaxNewSizePercent=40 \
-XX:G1MixedGCCountTarget=16
```

### 8.3 高吞吐场景
```bash
-Xms8g -Xmx8g \
-XX:MaxGCPauseMillis=500 \
-XX:GCTimeRatio=19 \
-XX:G1HeapWastePercent=15 \
-XX:InitiatingHeapOccupancyPercent=50
```

### 8.4 容器环境（K8s）
```bash
-Xms4g -Xmx4g \
-XX:MaxRAMPercentage=75.0 \
-XX:MaxGCPauseMillis=100 \
-XX:+UseContainerSupport \
-XX:G1HeapWastePercent=10
```

---

## 学习路径建议

```
基础配置参数 ➜ 年轻代调优 ➜ Mixed GC 调优 ➜ RSet 调优 ➜ 并发标记调优 ➜ 实战场景
    ⭐⭐⭐          ⭐⭐⭐          ⭐⭐⭐          ⭐⭐           ⭐⭐          ⭐⭐⭐
   (必须掌握)    (必须掌握)    (必须掌握)    (进阶可选)    (进阶可选)   (必须掌握)
```

---

## 文档输出规划

| 章节 | 输出文件 | 预估篇幅 |
|-----|---------|---------|
| 第1-2部分 | `7.1_G1_Tuning_Basic_and_YoungGen.md` | 长文 |
| 第3部分 | `7.2_G1_Tuning_Mixed_GC.md` | 长文 |
| 第4部分 | `7.3_G1_Tuning_RSet_and_Refine.md` | 长文 |
| 第5部分 | `7.4_G1_Tuning_Concurrent_Mark.md` | 中篇 |
| 第6部分 | `7.5_G1_Tuning_Special_Scenarios.md` | 中篇 |
| 第7部分 | `7.6_G1_Tuning_Diagnostics.md` | 短篇 |
| 第8部分 | `7.7_G1_Tuning_Practical_Cases.md` | 长文 |

**是否开始第一部分分析？**
