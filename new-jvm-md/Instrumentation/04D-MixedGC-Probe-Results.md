# 第4D章：G1 Mixed GC 触发判断 + CSet 选择插桩验证结果

> 基于 OpenJDK 11 slowdebug 插桩版本
> 运行环境：-Xms8g -Xmx8g -XX:+UseG1GC -XX:InitiatingHeapOccupancyPercent=20
>           -XX:G1HeapWastePercent=0 -XX:+UnlockExperimentalVMOptions -XX:G1MixedGCLiveThresholdPercent=50
> 插桩文件：
>   - src/hotspot/share/gc/g1/g1Policy.cpp（next_gc_should_be_mixed）
>   - src/hotspot/share/gc/g1/g1CollectionSet.cpp（finalize_old_part）

---

## 一、验证目标

Mixed GC 的触发需要满足两个条件，本章通过插桩验证每个条件的判断逻辑：

| 条件 | 判断位置 | 核心问题 |
|------|---------|---------|
| 条件1：有足够的 Old Region 候选 | `next_gc_should_be_mixed()` | 什么情况下有候选？候选数量是多少？ |
| 条件2：可回收空间超过 G1HeapWastePercent | `next_gc_should_be_mixed()` | 可回收空间如何计算？阈值是多少？ |
| CSet 选择 | `finalize_old_part()` | 每次 Mixed GC 选几个 Old Region？ |

---

## 二、插桩代码位置

```
src/hotspot/share/gc/g1/g1Policy.cpp
  → next_gc_should_be_mixed() 三个分支各插一个探针：
    [PROBE][MixedGC] 无候选（CSet Chooser 为空）
    [PROBE][MixedGC] 可回收不足（< G1HeapWastePercent）
    [PROBE][MixedGC] 触发 Mixed GC（可回收充足）

src/hotspot/share/gc/g1/g1CollectionSet.cpp
  → finalize_old_part() 末尾：
    [PROBE][MixedGC] CSet选择完成
```

---

## 三、实测数据

### 3.1 Mixed GC 触发判断（`next_gc_should_be_mixed()`）

#### 3.1.1 分支命中统计

| 分支 | 命中次数 | 含义 |
|------|---------|------|
| 无候选（CSet Chooser 为空） | 0 次 | 并发标记未完成或无 Old Region |
| 可回收不足 | 0 次 | 有候选但可回收空间 < G1HeapWastePercent |
| **触发 Mixed GC** | **3 次** | 可回收空间充足，触发 Mixed GC |

#### 3.1.2 触发 Mixed GC 时的详细数据

```
[PROBE][MixedGC] next_gc_should_be_mixed 判断:
  候选Old Region数=26, 可回收空间=73MB (0.9%)
  G1HeapWastePercent=0% (阈值), 可回收空间充足
  → 结论: 触发Mixed GC (可回收空间 0.9% > 阈值 0%)

[PROBE][MixedGC] next_gc_should_be_mixed 判断:
  候选Old Region数=26, 可回收空间=73MB (0.9%)
  G1HeapWastePercent=0% (阈值), 可回收空间充足
  → 结论: 触发Mixed GC (可回收空间 0.9% > 阈值 0%)

[PROBE][MixedGC] next_gc_should_be_mixed 判断:
  候选Old Region数=22, 可回收空间=57MB (0.7%)
  G1HeapWastePercent=0% (阈值), 可回收空间充足
  → 结论: 触发Mixed GC (可回收空间 0.7% > 阈值 0%)
```

**关键结论：**

1. **候选 Old Region = 26 个**：`G1MixedGCLiveThresholdPercent=50%` 生效，
   存活率低于 50% 的 Old Region 被选为候选。
   每个 Region = 4MB，26 个 = 104MB，其中可回收 73MB（存活 31MB）。

2. **可回收空间 = 73MB（0.9%）**：相对于 8GB 堆，0.9% 超过了 `G1HeapWastePercent=0%` 阈值，
   触发 Mixed GC。

3. **第3次触发时候选减少到 22 个**：第1次 Mixed GC 已经回收了 4 个 Old Region（26-22=4），
   剩余 22 个候选等待后续 Mixed GC 轮次处理。

---

### 3.2 CSet 选择（`finalize_old_part()`）

```
[PROBE][MixedGC] CSet选择完成 (Mixed GC):
  Young Region数=102 (408MB)
  Old Region数=4 (16MB) [本次Mixed GC回收的Old Region]
  Old Region选择范围: min=4, max=205 (G1MixedGCCountTarget=8)
  剩余候选Old Region数=22 (还需几轮Mixed GC才能清完)
  预计Old Region回收耗时=2.75ms
```

**关键结论：**

1. **每次 Mixed GC 只选 4 个 Old Region（16MB）**：
   - `G1MixedGCCountTarget=8`（默认值）：26 个候选 / 8 轮 = 3.25，向上取整 = 4
   - `min_old = ceil(26/8) = 4`，`max_old = 205`（受时间预算限制）
   - 实际选了 4 个（= min_old），说明时间预算充足但策略保守

2. **Young Region = 102 个（408MB）**：Mixed GC 本质上是 YoungGC + 少量 Old Region，
   Young Region 数量远多于 Old Region（102 vs 4）。

3. **剩余候选 = 22 个**：26 - 4 = 22，还需要 22/4 ≈ 6 轮 Mixed GC 才能清完所有候选。

4. **预计 Old Region 回收耗时 = 2.75ms**：G1 的时间预测模型估算，
   用于判断是否在 MaxGCPauseMillis 预算内。

---

### 3.3 为什么前几次运行没有触发 Mixed GC？

| 运行参数 | 结果 | 根因 |
|---------|------|------|
| `G1HeapWastePercent=5%`（默认） | 未触发 | 可回收空间 0.0-0.1%，远低于 5% 阈值 |
| `G1HeapWastePercent=1%` + `G1MixedGCLiveThresholdPercent=50%` | 未触发 | 可回收空间 0.8% < 1% 阈值 |
| `G1HeapWastePercent=0%` + `G1MixedGCLiveThresholdPercent=50%` | **触发！** | 可回收空间 0.9% > 0% 阈值 |

**根本原因**：测试程序的 1KB 小对象在 Old Region 中分布均匀，
每个 Region 里存活和死亡对象混杂，导致没有 Region 的存活率低于默认阈值 85%。
降低 `G1MixedGCLiveThresholdPercent=50%` 后，才有足够的候选 Region。

---

## 四、Mixed GC 触发全链路时序图

```
并发标记完成（Cleanup 阶段）
  └─ finalize_collection_set_chooser()
       ├─ 遍历所有 Old Region
       ├─ 过滤：存活率 > G1MixedGCLiveThresholdPercent(50%) 的 Region 排除
       └─ 剩余 26 个候选 Region 加入 CSet Chooser（按存活率从低到高排序）

YoungGC 触发时（每次 YoungGC 都会调用 next_gc_should_be_mixed()）
  └─ next_gc_should_be_mixed()
       ├─ 检查 CSet Chooser 是否为空 → 不为空（26 个候选）
       ├─ 计算可回收空间 = 73MB（0.9%）
       ├─ 比较 0.9% > G1HeapWastePercent(0%) → 触发 Mixed GC！
       └─ 返回 true

Mixed GC 执行（YoungGC + Old Region 回收）
  └─ finalize_old_part()
       ├─ 计算本轮选几个：ceil(26/8) = 4 个
       ├─ 从 CSet Chooser 取出 4 个存活率最低的 Old Region
       └─ 加入 CSet（与 102 个 Young Region 一起回收）

Mixed GC 完成后
  └─ 剩余候选 = 22 个，下一次 YoungGC 继续判断是否触发 Mixed GC
```

---

## 五、核心发现总结

| 问题 | 答案 |
|------|------|
| Mixed GC 触发的两个条件？ | ① CSet Chooser 不为空（有候选 Old Region）② 可回收空间 > G1HeapWastePercent |
| 候选 Old Region 如何筛选？ | 存活率 < G1MixedGCLiveThresholdPercent(默认85%) 的 Old Region 才会被选为候选 |
| 每次 Mixed GC 选几个 Old Region？ | ceil(总候选数 / G1MixedGCCountTarget) = ceil(26/8) = **4 个** |
| Mixed GC 本质是什么？ | **YoungGC + 少量 Old Region 回收**（本次 102 Young + 4 Old） |
| 为什么 Old Region 数量这么少？ | G1 的增量回收策略：分多轮（G1MixedGCCountTarget=8轮）慢慢清，避免单次 STW 过长 |
| 默认参数下为什么难触发 Mixed GC？ | G1HeapWastePercent=5% 阈值较高，需要大量死亡 Old Region 才能超过 |

---

## 六、与第4C章（并发标记）的关联

```
第4C章（并发标记）                    第4D章（Mixed GC）
─────────────────────────────────────────────────────────────
Cleanup 阶段                          next_gc_should_be_mixed()
  └─ 统计每个 Old Region 存活率  →    └─ 读取 CSet Chooser 中的候选
  └─ 存活率 < 50% → 加入候选    →    └─ 计算可回收空间
                                      └─ 决定是否触发 Mixed GC
                                              ↓
                                      finalize_old_part()
                                        └─ 选出 4 个 Old Region 加入 CSet
```

**关键联系**：
- 并发标记的 Cleanup 阶段是 Mixed GC 的"前置条件"——没有 Cleanup 就没有候选 Region
- Mixed GC 的 Old Region 数量由 `G1MixedGCCountTarget` 控制，实现增量回收
- 每轮 Mixed GC 后，候选数量减少，直到 `next_gc_should_be_mixed()` 返回 false，恢复 Young GC

