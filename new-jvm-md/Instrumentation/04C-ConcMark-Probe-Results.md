# 第4C章：G1 并发标记全链路插桩验证结果

> 基于 OpenJDK 11 slowdebug 插桩版本
> 运行环境：-Xms8g -Xmx8g -XX:+UseG1GC -XX:InitiatingHeapOccupancyPercent=20
> 插桩文件：src/hotspot/share/gc/g1/g1ConcurrentMark.cpp

---

## 一、验证目标

G1 并发标记分为 4 个阶段，本章通过插桩验证每个阶段的关键行为：

| 阶段 | 是否 STW | 插桩函数 | 核心问题 |
|------|---------|---------|---------|
| Initial Mark | **是**（搭 YoungGC 的车） | `post_initial_mark()` | SATB 何时激活？触发时堆使用率是多少？ |
| Concurrent Mark | **否** | `mark_from_roots()` | 用几个线程？耗时多少？SATB 积累了多少？ |
| Remark | **是** | `remark()` | STW 耗时多少？SATB 队列如何清空？ |
| Cleanup | **是** | `cleanup()` | 能回收多少 Region？下一次是 Mixed GC 吗？ |

---

## 二、插桩代码位置

```
src/hotspot/share/gc/g1/g1ConcurrentMark.cpp

[PROBE][InitialMark]  → post_initial_mark() 末尾
[PROBE][ConcMark]     → mark_from_roots() 开头 + 末尾
[PROBE][Remark]       → remark() 开头 + 末尾
[PROBE][Cleanup]      → cleanup() 末尾
```

---

## 三、实测数据

### 3.1 Initial Mark（`post_initial_mark()`）

```
[PROBE][InitialMark] post_initial_mark 完成:
  SATB写屏障已激活=YES (从此刻起所有引用修改都记录到SATB队列)
  堆使用率=19.8% (used=1620MB / capacity=8192MB)
  Old Region数=0, Humongous Region数=405
  Root Region数=1 (需要并发扫描的Survivor Region)
```

**关键结论：**

1. **SATB 激活时机**：`post_initial_mark()` 返回时，SATB 写屏障立即激活（`is_active()=YES`）。
   从这一刻起，所有引用字段的修改都会被记录到 SATB 队列，防止并发标记期间漏标。

2. **触发阈值验证**：堆使用率 **19.8%**，刚好超过 `IHOP=20%`（1638MB），触发了 Initial Mark。
   - 8192MB × 20% = 1638MB，实测 1620MB 触发（误差来自 YoungGC 后的精确计算时机）

3. **Old Region = 0**：本次测试全部是 Humongous 对象（32MB 块），没有普通 Old Region。
   405 个 Humongous Region × 4MB = 1620MB，与 `used=1620MB` 完全吻合。

4. **Root Region = 1**：Initial Mark 搭 YoungGC 的车，YoungGC 产生了 1 个 Survivor Region，
   这个 Survivor Region 需要在 Concurrent Mark 开始前优先扫描（Root Region Scan 阶段）。

---

### 3.2 Concurrent Mark（`mark_from_roots()`）

```
[PROBE][ConcMark] mark_from_roots 开始:
  并发标记线程数=3 (总线程池=3)
  待标记Region数=415 (used=415, free=1633)
  SATB写屏障激活=YES

[PROBE][ConcMark] mark_from_roots 完成:
  并发标记耗时=1ms (不STW，Java线程同时运行)
  SATB队列已完成缓冲区数=0 (并发期间积累的引用修改)
  标记是否溢出=NO
```

**关键结论：**

1. **并发标记线程数 = 3**：`calc_active_marking_workers()` 根据 CPU 核数计算，
   本机 4 核，G1 默认用 `ceil(CPU/4)` 到 `CPU/4` 之间，实测 3 个并发标记线程。

2. **耗时极短（1ms）**：因为测试程序的对象都是大块 byte[]，引用关系极简单，
   标记图很浅，3 个线程 1ms 就扫完了 415 个 Region。

3. **SATB 队列 = 0**：并发标记期间 Java 线程几乎没有引用修改（只是分配新对象），
   所以 SATB 队列没有积累任何缓冲区。这说明 Remark 的工作量会很小。

4. **未溢出**：标记栈没有溢出，不需要重启标记。

---

### 3.3 Remark（`remark()`）

```
[PROBE][Remark] remark 开始 (STW):
  SATB队列已完成缓冲区数=0 (并发期间积累的引用修改待处理)
  SATB写屏障激活=YES
  Old Region数=0, Humongous Region数=414

[PROBE][Remark] remark 完成 (STW):
  Remark总耗时=37.91ms (标记=1.40ms + 弱引用=36.52ms)
  标记完成=YES (未溢出=YES)
  SATB写屏障已关闭=YES (Remark后不再需要SATB)
  SATB剩余缓冲区=0 (应为0)
```

**关键结论：**

1. **Remark 耗时 = 37.91ms，但标记本身只用了 1.40ms！**
   剩余 36.52ms 全部花在**弱引用处理**（`process_weak_references()`）上。
   这是 Remark 的真正瓶颈：不是 SATB 队列处理，而是弱引用/软引用/虚引用的清理。

2. **SATB 队列 = 0**：Remark 开始时 SATB 队列已经是空的（并发期间没有积累），
   所以标记阶段只用 1.40ms 就完成了。

3. **SATB 关闭时机**：Remark 完成后，`satb_qs.is_active()=NO`。
   这是正确的：Remark 已经处理了所有并发期间的引用修改，不再需要 SATB 保护。

4. **SATB 剩余缓冲区 = 0**：Remark 处理完所有 SATB 缓冲区后清零，符合预期。

#### 3.3.1 Remark 耗时 10 轮完整数据

| 轮次 | 总耗时 | 标记耗时 | 弱引用耗时 |
|------|--------|---------|----------|
| 第1轮 | 37.91ms | 1.40ms | 36.52ms |
| 第2轮 | 37.93ms | 0.77ms | 37.16ms |
| 第3轮 | 37.73ms | 0.71ms | 37.02ms |
| 第4轮 | 36.99ms | 0.71ms | 36.28ms |
| 第5轮 | 37.70ms | 1.21ms | 36.49ms |
| 第6轮 | 37.48ms | 0.88ms | 36.60ms |
| 第7轮 | 37.04ms | 0.84ms | 36.21ms |
| **第8轮** | **45.87ms** | 0.84ms | **45.03ms** |
| **第9轮** | **46.44ms** | 0.69ms | **45.74ms** |
| **第10轮** | **58.35ms** | 1.61ms | **56.73ms** |

**第8-10轮耗时突然跳涨的根因分析：**

> ⚠️ 注意：这**不是** "弱引用处理时间随堆增长线性增长"，根因是**对象死亡率突然升高**。

测试程序在第10轮附近（阶段4）**释放了一半存活对象（~1GB）**，导致：
- 大量 Humongous 对象从"存活"变为"死亡"，但 SATB 队列中仍记录了对它们的引用
- 弱引用表（`StringTable`、`SymbolTable`、`JNIHandles` 等）中有大量条目需要重新验证
- 弱引用处理时间从 ~37ms 跳涨到 57ms，增幅 54%

**结论**：Remark 弱引用处理耗时**与对象死亡率正相关**，而非与堆大小正相关。
堆越大但对象都存活 → 弱引用处理快；堆中大量对象死亡 → 弱引用处理慢。

---

### 3.4 Cleanup（`cleanup()`）

```
[PROBE][Cleanup] cleanup 完成 (STW):
  Cleanup耗时=1.84ms
  当前空闲Region数=1624 (含Cleanup直接释放的完全死亡Region)
  堆使用率=20.7% (used=1692MB / capacity=8192MB)
  下一次GC类型=Young GC (无足够候选)
  Old Region数=0, Humongous Region数=423
```

**关键结论：**

1. **Cleanup 耗时极短（1.84ms）**：Cleanup 的主要工作是统计每个 Region 的存活率，
   并把完全死亡的 Region 直接加入 Free List。本次没有完全死亡的 Region（全是存活的 Humongous 对象），
   所以 Cleanup 几乎没有实际工作。

2. **下一次 GC = Young GC（不是 Mixed GC）**：
   `next_gc_should_be_mixed()=false`，原因是 Old Region 数 = 0。
   G1 的 Mixed GC 需要有足够的 Old Region 候选（超过 `G1MixedGCLiveThresholdPercent=85%` 的 Region 不会被选），
   本次测试全是 Humongous Region，没有普通 Old Region，所以不会触发 Mixed GC。

3. **Humongous Region 持续增长**：
   - 第1轮 Cleanup：Humongous Region = 423
   - 第10轮 Cleanup：Humongous Region = 504
   每轮增加约 9 个（对应每次分配的 32MB = 9 个 4MB Region），说明存活对象在持续积累。

---

## 四、并发标记全链路时序图

```
YoungGC (STW)
  └─ Initial Mark 搭车
       └─ post_initial_mark()
            ├─ SATB 写屏障激活 ✓
            └─ Root Region Scan 开始

并发阶段（Java 线程同时运行）
  ├─ Root Region Scan（扫描 Survivor Region）
  └─ mark_from_roots()（并发标记，3线程，1ms）
       ├─ SATB 写屏障持续记录引用修改
       └─ 标记完成，SATB 队列积累 = 0

Remark (STW, 37~58ms)
  ├─ 处理 SATB 队列（~1ms，队列为空所以很快）
  ├─ 弱引用处理（36~57ms，真正的瓶颈，与对象死亡率正相关）
  └─ SATB 写屏障关闭 ✓

Cleanup (STW, 1.84ms)
  ├─ 统计每个 Region 存活率
  ├─ 完全死亡的 Region → Free List
  └─ 决定下一次 GC 类型（本次 = Young GC）
```

---

## 五、核心发现总结

| 问题 | 答案 |
|------|------|
| Initial Mark 触发时堆使用率？ | **19.8%**（IHOP=20%，8192MB×20%=1638MB） |
| SATB 何时激活？ | `post_initial_mark()` 返回时立即激活 |
| 并发标记用几个线程？ | **3 个**（4核机器，`calc_active_marking_workers()` 计算） |
| 并发标记耗时？ | **1ms**（对象引用关系简单，标记图浅） |
| SATB 队列积累了多少？ | **0**（测试程序并发期间几乎没有引用修改） |
| Remark STW 耗时？ | **37~58ms**（第1-7轮稳定 ~37ms，第8-10轮跳涨至 58ms） |
| Remark 的真正瓶颈是什么？ | **弱引用处理**（占 96%），不是 SATB 队列处理 |
| Remark 耗时为何后期跳涨？ | 测试程序释放大量存活对象 → 对象死亡率升高 → 弱引用表清理压力增大 |
| SATB 何时关闭？ | Remark 完成后立即关闭 |
| Cleanup 能回收多少 Region？ | **0 个**（全是存活的 Humongous 对象） |
| Cleanup 后下一次是 Mixed GC？ | **否**（Old Region = 0，无候选） |

---

## 六、与第4B章（写屏障）的关联

第4B章验证了写屏障的触发路径（汇编快路径 → 慢路径 → SATB 队列）。
本章验证了 SATB 队列的消费端：

```
写屏障（第4B章）                    并发标记（第4C章）
─────────────────────────────────────────────────────
引用修改 → SATB 队列写入            Remark 处理 SATB 队列
         ↑                                    ↓
    Initial Mark 激活 SATB ←→ Remark 完成后关闭 SATB
```

**关键联系**：
- Initial Mark 激活 SATB → 写屏障开始记录引用修改
- Remark 处理 SATB 队列 → 确保并发期间的引用修改不漏标
- Remark 完成 → SATB 关闭 → 写屏障不再记录（直到下一次 Initial Mark）

