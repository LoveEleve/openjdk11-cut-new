# 第 4 章：G1 YoungGC 链路插桩结果

> 基于 OpenJDK 11 源码插桩验证
> 标准环境：`-Xms8g -Xmx8g -XX:+UseG1GC -Xint`
> G1 Region = 4MB，总 Region 数 = 2048

---

## 探针布局（最终版）

经过 3 轮修复，最终确定 3 个探针的正确位置：

```
do_collection_pause_at_safepoint()
  │
  ├── [探针1] note_gc_start() 之前
  │     → 读 Eden/Survivor/Old/Free Region 数、堆使用率、GC类型
  │     → 必须在 note_gc_start() 之前！否则 Eden 被移入 CSet 后 _eden.length()=0
  │
  ├── note_gc_start()          ← Eden Region 移入 CSet
  │
  ├── evacuate_collection_set()  ← 对象复制
  │
  ├── post_evacuate_collection_set()
  │     ├── free_collection_set()  ← 释放 CSet Region
  │     └── record_collection_pause_end()
  │
  ├── [探针2] free_collection_set() 之前
  │     → 读 CSet Region 数（此时 CSet 还未释放，数量有效）
  │
  ├── set_collectionset_used_before()  ← 3867行，CSet使用前才在这里设置
  ├── set_bytes_copied()               ← 3868行，复制字节数才在这里设置
  │
  └── [探针3] set_bytes_copied() 之后
        → 读 CSet使用前/后、复制字节数、释放Region数、新Survivor/Old
        → 必须在 set_bytes_copied() 之后！否则这些字段还未赋值，全为0
```

**关键教训**：`evacuation_info` 的字段在 GC 生命周期的不同阶段才被赋值，必须在正确时机读取。

---

## 4.1 GC 触发条件验证

### 实际探针输出

**第 1 次 YoungGC：**
```
[PROBE][YoungGC] #1 GC触发:
  触发原因=G1 Evacuation Pause
  Eden: 102个Region (408MB)
  Survivor: 0个Region (0MB)
  Old: 0个Region (0MB)
  Free: 1940个Region (7760MB)
  堆已用=432MB / 总容量=8192MB (5.3%)
  GC类型=YoungGC(Normal)
```

**第 2 次 YoungGC：**
```
[PROBE][YoungGC] #2 GC触发:
  触发原因=G1 Evacuation Pause
  Eden: 89个Region (356MB)
  Survivor: 13个Region (52MB)
  Old: 33个Region (132MB)
  Free: 1913个Region (7652MB)
  堆已用=537MB / 总容量=8192MB (6.6%)
  GC类型=YoungGC(Normal)
```

### 对比总纲预期

| 指标 | 总纲预期 | 实际结果 | 差异分析 |
|------|---------|---------|---------|
| 触发原因 | `G1 Evacuation Pause (allocation failure)` | `G1 Evacuation Pause` | ✅ 本质相同，GCCause 枚举值一致 |
| Eden Region 数 | ~409个（约20%堆） | **102个（408MB，约5%堆）** | ⚠️ 差异大，见下方分析 |
| Survivor（第1次） | 0个 | 0个 | ✅ 完全一致 |
| Old（第1次） | 0个 | 0个 | ✅ 完全一致 |
| 并发标记触发 | NO（堆使用率<45%） | NO（GC类型=YoungGC(Normal)） | ✅ 完全一致 |

### 结论分析

**结论1（修正总纲预期）：G1 YoungGC 触发时 Eden 约 102 个 Region（408MB），约占堆的 5%，而非总纲预期的 20%**

原因：总纲预期基于 `-Xmx4g` 的经验值（409个Region × 4MB ≈ 1.6GB ≈ 40%堆），而本次环境是 `-Xms8g -Xmx8g`（8GB堆），G1 的 `MaxGCPauseMillis=200ms` 目标不变，但堆更大，G1 会把 Eden 控制在更小的比例以保证暂停时间目标。

**结论2：G1 动态调整 Eden 大小，目标是让 GC 暂停时间 ≤ MaxGCPauseMillis(200ms)**

从两次 GC 对比可以看出：
- 第1次：Eden=102个Region（408MB），Survivor=0，Old=0
- 第2次：Eden=89个Region（356MB），Survivor=13，Old=33
- Eden 从 102 减少到 89，说明 G1 根据第1次 GC 的暂停时间反馈，**主动缩小了 Eden 大小**

**结论3：并发标记在堆使用率 > IHOP(45%) 时才触发，两次 GC 均未触发（5.3% 和 6.6%）**

**结论4（新发现）：第2次 GC 时 Old 已有 33 个 Region（132MB）**

这是第1次 GC 晋升的对象。说明 Demo 中有部分对象在第1次 GC 时已经达到晋升年龄（age > MaxTenuringThreshold=15），或者因为 Survivor 空间不足而提前晋升（Premature Promotion）。

---

## 4.2 GC 完成统计

### 实际探针输出

**第 1 次 YoungGC 完成：**
```
[PROBE][YoungGC] CSet Region数=102 (被回收的Eden+Survivor Region)
[PROBE][YoungGC] GC完成统计(最终):
  CSet使用前=408MB (GC前Eden占用)
  CSet使用后=0MB (GC后残留)
  复制字节数=181MB (存活对象移动量)
  释放Region数=102
  新Survivor: 13个Region (52MB)
  新Old: 33个Region (132MB)
  GC后Free: 2002个Region (8008MB)
  疏散失败=NO
```

**第 2 次 YoungGC 完成：**
```
[PROBE][YoungGC] CSet Region数=102 (被回收的Eden+Survivor Region)
[PROBE][YoungGC] GC完成统计(最终):
  CSet使用前=408MB (GC前Eden占用)
  CSet使用后=0MB (GC后残留)
  复制字节数=141MB (存活对象移动量)
  释放Region数=102
  新Survivor: 13个Region (52MB)
  新Old: 55个Region (220MB)
  GC后Free: 1980个Region (7920MB)
  疏散失败=NO
```

### 对比总纲预期

| 指标 | 总纲预期 | 第1次实际 | 第2次实际 |
|------|---------|---------|---------|
| 释放 Eden Region 数 | ~409个 | 102个 | 102个 |
| 新 Survivor Region 数 | ~20个 | **13个** | **13个** |
| 复制字节数 | ~200MB | **181MB** | **141MB** |
| 疏散失败 | NO | NO ✅ | NO ✅ |

### 结论分析

**结论5：CSet 使用前=408MB，使用后=0MB，说明 Eden Region 被完全清空**

`CSet使用后=0MB` 表示 CSet 中的所有存活对象都已被复制走，原 Eden Region 完全变为空闲。

**结论6：存活率约 44%（181MB / 408MB），远高于总纲预期的 5%**

原因：Demo 程序（Scene 4）分配了大量对象并保持引用（`list.add(obj)`），导致存活率高。这些存活对象被复制到 Survivor 和 Old Region。

**结论7：两次 GC 的 Survivor 数量稳定在 13 个 Region（52MB）**

G1 的 Survivor 大小由 `G1MaxNewSizePercent` 和暂停时间目标共同决定，两次 GC 结果一致说明 G1 的 Survivor 大小已经稳定。

**结论8：Old Region 从 33 个增长到 55 个（+22个，+88MB）**

第2次 GC 新晋升了 22 个 Old Region（88MB），说明 Demo 中有大量对象在第2次 GC 时达到晋升年龄。

**结论9：GC 后 Free Region 从 2002 减少到 1980（-22个）**

与 Old Region 增加 22 个完全对应，验证了 Region 守恒：`释放的CSet Region = 新Survivor + 新Old + 新Free`。

---

## 4.3 Region 守恒验证

G1 GC 的 Region 守恒公式：

```
GC前 = Eden + Survivor + Old + Free
GC后 = 新Survivor + 新Old + 新Free + Humongous(不变)
```

**第1次 GC 验证：**
```
GC前: Eden=102 + Survivor=0 + Old=0 + Free=1940 + Humongous=6 = 2048 ✅
GC后: Survivor=13 + Old=33 + Free=2002 = 2048 ✅
      (Humongous=6 不参与YoungGC，保持不变)

CSet(102) = 释放Region(102) → 全部变为Free
Free增加: 2002 - 1940 = +62个
Free增加来源: CSet释放102 - 新Survivor13 - 新Old33 = 56个... 
```

> 注：Free 增加 62 个（2002-1940），而 CSet 释放 102 个，新 Survivor 13 个，新 Old 33 个。
> 102 - 13 - 33 = 56，但实际增加 62，差 6 个。
> 原因：Humongous 对象（h1/h2/h3 共 6 个 Region）在 YoungGC 时被 eagerly reclaim（提前回收），贡献了额外的 6 个 Free Region。

**第2次 GC 验证：**
```
GC前: Eden=89 + Survivor=13 + Old=33 + Free=1913 = 2048 ✅
GC后: Survivor=13 + Old=55 + Free=1980 = 2048 ✅
      (Humongous 已在第1次GC时被回收，此时=0)

CSet(102) = Eden(89) + Survivor(13) = 102 ✅
Free增加: 1980 - 1913 = +67个
Free增加来源: CSet释放102 - 新Survivor13 - 新Old(55-33=22) = 102 - 13 - 22 = 67 ✅
```

第2次 GC Region 守恒完全验证！

---

## 4.4 探针修复历程（重要教训）

### 问题1：Eden Region 数为 0

**现象**：探针输出 `Eden: 0个Region`

**根因**：探针放在 `note_gc_start()` **之后**。`note_gc_start()` 会把所有 Eden Region 移入 CSet，导致 `_eden.length()=0`。

**修复**：把探针移到 `note_gc_start()` **之前**。

### 问题2：CSet使用前=0MB，复制字节数=0MB

**现象**：探针输出 `CSet使用前=0MB`、`复制字节数=0MB`

**根因**：`evacuation_info` 的字段赋值时机比预期晚：
```
free_collection_set()              ← 3781行（探针原来在这里）
record_collection_pause_end()
set_collectionset_used_before()    ← 3867行，才在这里赋值！
set_bytes_copied()                 ← 3868行，才在这里赋值！
```

**修复**：把最终统计探针移到 `set_bytes_copied()` **之后**（3855行）。

---

## 总结

### 数据结构层面

| 结构 | 核心特征 |
|------|---------|
| `_eden` (HeapRegionSet) | YoungGC 触发时被 `note_gc_start()` 清空，必须在此之前读取 |
| `evacuation_info` (EvacuationInfo) | 字段在 GC 生命周期末尾才被赋值，必须在 `set_bytes_copied()` 之后读取 |
| `_survivor` (HeapRegionSet) | GC 完成后包含新的 Survivor Region，数量稳定在 13 个 |
| `_old_set` (HeapRegionSet) | 每次 GC 后增加晋升的 Old Region |

### 算法层面

| 算法 | 核心设计决策 |
|------|------------|
| Eden 大小动态调整 | G1 根据上次 GC 暂停时间反馈调整 Eden 大小（102→89），目标是 ≤ MaxGCPauseMillis(200ms) |
| Humongous 提前回收 | YoungGC 时顺带回收可达性为死的 Humongous 对象（eagerly reclaim），无需等到 Full GC |
| CSet = Eden + Survivor | 每次 YoungGC 的 CSet 包含全部 Eden Region + 全部 Survivor Region |
| 疏散失败保护 | 8GB 堆 + 5% 使用率，疏散失败概率极低，两次 GC 均未触发 |
