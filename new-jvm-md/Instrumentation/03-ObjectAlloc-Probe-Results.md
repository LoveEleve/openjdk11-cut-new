# 对象分配链路探针结果

> 基于 OpenJDK 11 slowdebug 真实运行数据  
> 环境：`-Xms8g -Xmx8g -XX:+UseG1GC -Xint`  
> G1 Region = 4MB，Humongous 阈值 = 2MB（region_size / 2）  
> 采集时间：2026-03-04

---

## 一、TLAB 初始化参数

**探针位置**：`threadLocalAllocBuffer.cpp` → `startup_initialization()` 末尾  
**触发时机**：`universe_init()` 阶段，JVM 堆创建完成后立即执行

```
[PROBE][TLAB] startup_initialization 完成:
  target_refills=50 (每次GC期间预期refill次数)
  min_size=2KB (328 words)
  max_size=2048KB (262144 words)
  initial_desired_size=2048KB (262144 words)
  tlab_capacity(heap)=408MB
  计算公式: initial = tlab_capacity / (nof_threads * target_refills)
  → 结论: TLAB初始大小=2048KB, 每次GC期间预期refill 50次
```

### 关键数据解读

| 参数 | 值 | 含义 |
|------|-----|------|
| `target_refills` | **50** | JVM 期望每次 GC 间隔内每个线程 refill 50 次 |
| `min_size` | **2KB** (328 words) | TLAB 最小值，低于此值不再分配 TLAB |
| `max_size` | **2048KB** (262144 words) | TLAB 最大值上限 |
| `initial_desired_size` | **2048KB** | 启动时 desired_size = max_size（因为只有 1 个线程） |
| `tlab_capacity` | **408MB** | 堆中可用于 TLAB 的总容量（8GB 堆的约 5%） |
| `refill_waste_limit` | **32768B (32KB)** | 允许浪费的最大空间（超过则不 refill，直接堆分配） |

### 计算公式验证

```
initial_desired_size = tlab_capacity / (nof_threads * target_refills)
                     = 408MB / (1 * 50)
                     = 8.16MB → 但受 max_size=2048KB 限制
                     → 实际 = 2048KB ✓
```

---

## 二、TLAB Refill 过程

**探针位置**：`threadLocalAllocBuffer.cpp` → `fill()` 函数  
**触发时机**：每次 TLAB 空间不足，需要申请新 TLAB 块时

### 2.1 JVM 启动阶段第一次 Refill（universe2_init 期间）

```
[PROBE][TLAB] refill #1: tid=137058
  新TLAB: start=0x00000007ffc00000 size=2048KB (2097152 bytes)
  已用(top-start)=16 bytes, 可用=2047KB
  desired_size=2048KB, refill_waste_limit=32768B
  → 结论: TLAB大小=2048KB, 每次refill分配新块
```

**解读**：
- 第一个 TLAB 块从堆顶 `0x7ffc00000` 开始（G1 堆末尾）
- 大小 = 2048KB = `initial_desired_size`，符合预期
- `top-start=16 bytes`：刚分配就已用 16 字节（对象头 mark word + klass pointer）

### 2.2 第二个线程（GC 线程）的第一次 Refill

```
[PROBE][TLAB] refill #1: tid=137066
  新TLAB: start=0x00000007ffe00000 size=2048KB (2097152 bytes)
  已用(top-start)=192 bytes, 可用=2047KB
  desired_size=2048KB, refill_waste_limit=32768B
```

**解读**：
- tid=137066 是另一个线程（GC 线程），各线程独立持有 TLAB
- 两个 TLAB 地址相差 2MB（`0x7ffe00000 - 0x7ffc00000 = 0x200000 = 2MB`），互不重叠

### 2.3 场景 2：大量小对象分配触发 Refill（500000 个 int[4]）

```
[PROBE][TLAB] refill #1: tid=137058
  新TLAB: start=0x00000007ffc00000 size=2KB (2048 bytes)
  已用(top-start)=1040 bytes, 可用=0KB
  desired_size=2048KB, refill_waste_limit=32768B
  → 结论: TLAB大小=2KB, 每次refill分配新块
```

**⚠️ 关键发现**：YoungGC 后 TLAB 大小从 **2048KB 骤降到 2KB**！

**原因分析**：
- YoungGC 后 JVM 根据实际分配速率重新计算 `desired_size`
- 公式：`desired_size = allocated_bytes / target_refills`
- 若 YoungGC 间隔内分配量很小，则 desired_size 会缩小到 min_size(2KB)
- 这是 TLAB 自适应调整机制（Adaptive TLAB Sizing）

### 2.4 场景 4：YoungGC 后 Refill #50 的状态

```
[PROBE][TLAB] refill #50: tid=137058
  新TLAB: start=0x00000007fb800800 size=2048KB (2097152 bytes)
  已用(top-start)=1040 bytes, 可用=2046KB
  desired_size=2048KB, refill_waste_limit=32768B
```

**解读**：
- 经过大量分配后，TLAB 大小恢复到 2048KB（自适应调整回来）
- `top-start=1040 bytes`：每次 refill 时已有 1040 字节被用（上一个 TLAB 的 dummy fill）

### 2.5 Refill 次数统计

| 场景 | 最大 refill 编号 | 说明 |
|------|----------------|------|
| JVM 启动（universe2_init） | #1 | 加载基础类时触发 |
| 场景 2（500000 小对象） | #300+ | 每个 TLAB 约 2048KB，32B 对象 → 约 65536 个/TLAB |
| 场景 4（YoungGC 轮次） | #250 | 每轮 200000 × 1KB = 200MB，约 100 次 refill |

---

## 三、Humongous 大对象分配

**探针位置**：`g1CollectedHeap.cpp` → `humongous_obj_allocate()` 入口 + 出口  
**触发条件**：对象大小 > `_humongous_object_threshold_in_words * HeapWordSize = 2MB`

### 3.1 分配 3MB 对象（`new byte[3 * 1024 * 1024]`）

```
[PROBE][Humongous] #1 大对象分配: size=3145744 bytes (3.0MB)
  Humongous阈值=2097152 bytes (2.0MB) = region_size/2
  需要Region数=1 (ceil(3MB / 4MB))
  分配前free_region_count=2041
  → 结论: 超过阈值的对象直接占用整个Region，绕过TLAB

[PROBE][Humongous] 分配成功: result=0x0000000600000000
  starts_humongous Region index=0
  占用Region数=1 (starts=1 + continues=0)
  分配后free_region_count=2040 (减少了1个)
  → 结论: Humongous对象直接占用1个完整Region，不参与TLAB分配
```

**解读**：
- 3MB < 4MB（1 个 Region），所以只需 1 个 Region
- `starts_humongous Region index=0`：从 Region 0 开始（堆的最低地址区域）
- 地址 `0x600000000` = 堆起始地址（`-Xms8g` 从此处开始）
- 实际分配 size=3145744 而非 3145728（3MB）：多了 16 字节 = 对象头（mark word 8B + klass pointer 8B）

### 3.2 分配 6MB 对象（`new byte[6 * 1024 * 1024]`）

```
[PROBE][Humongous] #2 大对象分配: size=6291472 bytes (6.0MB)
  Humongous阈值=2097152 bytes (2.0MB) = region_size/2
  需要Region数=2 (ceil(6MB / 4MB))
  分配前free_region_count=2040

[PROBE][Humongous] 分配成功: result=0x0000000600400000
  starts_humongous Region index=1
  占用Region数=2 (starts=1 + continues=1)
  分配后free_region_count=2038 (减少了2个)
```

**解读**：
- 6MB > 4MB，需要 2 个 Region（1 个 starts_humongous + 1 个 continues_humongous）
- `result=0x600400000`：Region 1 的起始地址（`0x600000000 + 4MB = 0x600400000`）
- free_region_count 从 2040 → 2038，减少了 2 个 ✓

### 3.3 分配 10MB 对象（`new byte[10 * 1024 * 1024]`）

```
[PROBE][Humongous] #3 大对象分配: size=10485776 bytes (10.0MB)
  Humongous阈值=2097152 bytes (2.0MB) = region_size/2
  需要Region数=3 (ceil(10MB / 4MB))
  分配前free_region_count=2038

[PROBE][Humongous] 分配成功: result=0x0000000600c00000
  starts_humongous Region index=3
  占用Region数=3 (starts=1 + continues=2)
  分配后free_region_count=2035 (减少了3个)
```

**解读**：
- 10MB 需要 3 个 Region（ceil(10/4) = 3）
- `result=0x600c00000`：Region 3 的起始地址（`0x600000000 + 3×4MB = 0x600c00000`）
- Region 布局：Region 0（3MB 对象）→ Region 1-2（6MB 对象）→ Region 3-5（10MB 对象）

### 3.4 Humongous 分配规律总结

| 对象大小 | 需要 Region 数 | starts_humongous | continues_humongous | 地址 |
|---------|--------------|-----------------|--------------------|----|
| 3MB | 1 | Region 0 | 0 个 | `0x600000000` |
| 6MB | 2 | Region 1 | 1 个 | `0x600400000` |
| 10MB | 3 | Region 3 | 2 个 | `0x600c00000` |

**Region 地址规律**：`result = heap_start + region_index × 4MB`
- `0x600000000 + 0 × 0x400000 = 0x600000000` ✓
- `0x600000000 + 1 × 0x400000 = 0x600400000` ✓
- `0x600000000 + 3 × 0x400000 = 0x600c00000` ✓（Region 2 被 6MB 对象的 continues 占用）

---

## 四、TLAB vs Humongous 对比

| 维度 | TLAB 分配 | Humongous 分配 |
|------|----------|---------------|
| **触发条件** | 对象 < refill_waste_limit(32KB) | 对象 > 2MB（region_size/2） |
| **分配路径** | 线程本地，无锁 | 需要持有堆锁（`assert_heap_locked`） |
| **内存单位** | 按 TLAB 块（2MB）分配 | 按 Region（4MB）分配 |
| **地址连续性** | 同一 TLAB 内连续 | 跨 Region 连续（starts+continues） |
| **GC 处理** | 随 YoungGC 回收 | 专门的 Humongous 回收路径 |
| **碎片影响** | TLAB 内部碎片（dummy fill 填充） | Region 内部碎片（最后一个 Region 浪费） |
| **自适应调整** | desired_size 随分配速率动态调整 | 无自适应，每次按需计算 Region 数 |

---

## 五、关键结论

1. **TLAB 初始大小 = 2048KB**：由 `tlab_capacity(408MB) / (1线程 × 50次refill)` 计算，受 max_size 限制
2. **TLAB 自适应调整**：YoungGC 后根据实际分配速率重新计算 desired_size，可从 2048KB 骤降到 2KB
3. **Humongous 阈值 = 2MB**：精确等于 `region_size / 2 = 4MB / 2 = 2MB`
4. **Humongous 分配需要堆锁**：与 TLAB 的无锁分配形成鲜明对比，是大对象分配慢的根本原因
5. **Region 地址规律**：`result = heap_start + region_index × 4MB`，地址完全可预测
6. **对象头开销**：实际分配 size 比 Java 层 length 多 16 字节（mark word 8B + klass pointer 8B）
7. **free_region_count 精确递减**：3MB→减1，6MB→减2，10MB→减3，与 `ceil(size/4MB)` 完全吻合

