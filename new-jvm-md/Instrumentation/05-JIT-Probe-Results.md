# 第5章：JIT 编译触发链路插桩验证结果

> 基于 OpenJDK 11 slowdebug 插桩版本  
> 运行环境：-Xms512m -Xmx512m -XX:+UseG1GC（不加 -Xint，允许 JIT）  
> 插桩文件：
> - `src/hotspot/share/interpreter/interpreterRuntime.cpp`（`frequency_counter_overflow_inner`）
> - `src/hotspot/share/compiler/compileBroker.cpp`（`invoke_compiler_on_method`）

---

## 一、验证目标

JIT 编译触发链路分为两个关键节点：

| 节点 | 函数 | 核心问题 |
|------|------|---------|
| **触发判断** | `frequency_counter_overflow_inner()` | 什么时候触发？invocation_count 是多少？OSR 还是方法调用？ |
| **编译完成** | `invoke_compiler_on_method()` | 编译了哪个 Tier？耗时多少？代码多大？存在哪个 CodeCache 段？ |

---

## 二、插桩代码位置

```
[PROBE][JIT] frequency_counter_overflow  → interpreterRuntime.cpp:1068
[PROBE][JIT] 编译完成                    → compileBroker.cpp:2253
```

---

## 三、实测数据

### 3.1 总体统计

| 指标 | 数值 |
|------|------|
| `frequency_counter_overflow` 触发次数 | **3202 次** |
| 编译完成次数 | **632 次** |
| 其中 Tier1（C1-简单）| 75 次 |
| 其中 Tier3（C1-完整profiling）| 487 次 |
| 其中 Tier4（C2）| 70 次 |
| OSR 编译次数 | 3 次 |
| 非 OSR 编译次数 | 629 次 |

**关键比例**：触发 3202 次，只编译 632 次（约 1/5）。大量触发被去重或排队丢弃。

---

### 3.2 invocation_count 触发规律（`hotMethod`）

```
[PROBE][JIT] frequency_counter_overflow: method=com.wjcoder.JITTest.hotMethod(I)I
  触发类型=方法调用(invocation) (branch_bcp=NULL)
  invocation_count=128
  当前编译级别=0 (解释执行)
  Tier3InvocationThreshold=200, Tier4InvocationThreshold=5000

[PROBE][JIT] frequency_counter_overflow: method=com.wjcoder.JITTest.hotMethod(I)I
  invocation_count=256  ...

[PROBE][JIT] frequency_counter_overflow: method=com.wjcoder.JITTest.hotMethod(I)I
  invocation_count=384  ...
```

**关键结论：**

1. **计数器以 128 为步长递增**：`InvocationCounter` 不是每次调用都 +1，而是每次溢出时
   `raw_value` 增加一个固定步长（128），这是 HotSpot 的计数器压缩设计——低位存 state，
   高位存计数，每次 +1 实际上是 `raw_value += 8`（3位 state），128 次溢出 = 1024 raw。

2. **Tier3InvocationThreshold=200**：方法调用 200 次后触发 C1 编译请求。
   但实测 `invocation_count=128` 时就触发了 `frequency_counter_overflow`，
   说明计数器溢出检查是在 128 的倍数时触发（计数器步长），不是精确到 200。

3. **触发时编译级别=0（解释执行）**：说明第一次触发时方法还没被编译，
   `frequency_counter_overflow` 会提交编译请求到编译队列。

---

### 3.3 OSR 触发（`main` 方法的循环）

```
[PROBE][JIT] frequency_counter_overflow: method=com.wjcoder.JITTest.main([Ljava/lang/String;)V
  触发类型=OSR(循环回边) (branch_bcp=非NULL)
  invocation_count=1
  backedge_count=1024
  当前编译级别=0 (解释执行)
  osr_bci=34 (循环回边字节码偏移量)
  Tier3InvocationThreshold=200, Tier4InvocationThreshold=5000
```

**关键结论：**

1. **OSR 触发时 invocation_count=1**：`main` 方法只被调用了 1 次，但循环回边
   `backedge_count=1024` 触发了 OSR。这正是 OSR 的设计目的：**方法调用次数少但循环很热**。

2. **osr_bci=34**：字节码偏移量 34 是 `main` 方法中 `for (int i = 0; i < 100000; i++)` 
   循环的回边字节码位置。OSR 编译会从这个 bci 开始，直接替换正在执行的解释器栈帧。

3. **backedge_count=1024**：回边计数器也是 128 步长，1024 = 8 × 128，
   说明循环执行了约 1024 次时触发了第一次 OSR 检查。

---

### 3.4 分层编译：C1 → C2 升级（`hotMethod`）

```
# 第一次编译：C1（Tier3）
[PROBE][JIT] 编译完成: method=com.wjcoder.JITTest.hotMethod(I)I
  编译级别=Tier3 (C1-profiling)
  是否OSR=NO (osr_bci=-1)
  编译耗时=0ms
  代码大小: total=368 bytes, insts=192 bytes
  代码地址=[0x00007ff00d83dd40, 0x00007ff00d83de58)
  entry_point=0x00007ff00d83dd40

# 第二次编译：C2（Tier4）
[PROBE][JIT] 编译完成: method=com.wjcoder.JITTest.hotMethod(I)I
  编译级别=Tier4 (C2)
  是否OSR=NO (osr_bci=-1)
  编译耗时=0ms
  代码大小: total=168 bytes, insts=64 bytes
  代码地址=[0x00007ff014be49a0, 0x00007ff014be49f8)
  entry_point=0x00007ff014be49a0
  存放在CodeCache段=CodeHeap 'non-profiled nmethods'
```

**关键结论：**

1. **C2 代码比 C1 更小！**
   - C1（Tier3）：total=368 bytes，insts=192 bytes
   - C2（Tier4）：total=168 bytes，insts=64 bytes
   - **C2 代码大小仅为 C1 的 46%（insts 仅 33%）**
   
   原因：C2 做了深度优化（内联、常量折叠、死代码消除），`hotMethod(x) = x*x+x+1` 
   被 C2 优化为极少的指令；而 C1 保留了 profiling 代码（记录类型信息），所以更大。

2. **C1 编译耗时 0ms，C2 也是 0ms**：`hotMethod` 太简单，编译时间在毫秒以下。
   复杂方法的 C2 编译耗时可达 100ms+（见下文）。

3. **CodeCache 分段**：
   - C1（Tier3）：存放在 `CodeHeap 'profiled nmethods'`（含 profiling 代码）
   - C2（Tier4）：存放在 `CodeHeap 'non-profiled nmethods'`（纯优化代码）

---

### 3.5 OSR 编译：`hotLoop` 的 C2 OSR

```
[PROBE][JIT] 编译完成: method=com.wjcoder.JITTest.hotLoop(I)J
  编译级别=Tier4 (C2)
  是否OSR=YES (osr_bci=4)
  编译耗时=8ms
  代码大小: total=832 bytes, insts=416 bytes
  代码地址=[0x00007ff014bf46c0, 0x00007ff014bf4878)
  entry_point=0x00007ff014bf46c0
  存放在CodeCache段=CodeHeap 'non-profiled nmethods'
```

**关键结论：**

1. **OSR 直接到 C2（Tier4）**：`hotLoop` 的循环非常热，直接触发了 C2 OSR 编译，
   跳过了 C1 OSR 阶段。这是分层编译的优化：对于极热的循环，直接用 C2。

2. **osr_bci=4**：`hotLoop` 方法中字节码偏移量 4 是 `for (int i = 0; i < n; i++)` 的回边。

3. **代码大小 832 bytes**：比 `hotMethod` 的 C2 代码（168 bytes）大 5 倍，
   因为循环体需要展开、向量化等优化，生成的代码更多。

---

### 3.6 C2 编译耗时分布

```
C2 编译耗时最大值（前10名）：
  50ms, 55ms, 91ms, 102ms, 110ms, 117ms, 136ms, 138ms, 140ms, 172ms
```

**关键结论：**

1. **C2 编译耗时差异巨大**：简单方法 0ms，复杂方法可达 172ms。
   这就是为什么 JVM 用后台线程异步编译——如果同步编译，172ms 的 STW 是不可接受的。

2. **C1 编译耗时通常 < 5ms**：C1 只做简单优化，速度快；C2 做深度分析，耗时长。

---

### 3.7 `main` 方法的 OSR 编译（大循环）

```
[PROBE][JIT] 编译完成: method=com.wjcoder.JITTest.main([Ljava/lang/String;)V
  编译级别=Tier3 (C1-profiling)
  是否OSR=YES (osr_bci=34)
  编译耗时=38ms
  代码大小: total=19960 bytes, insts=12160 bytes

[PROBE][JIT] 编译完成: method=com.wjcoder.JITTest.main([Ljava/lang/String;)V
  编译级别=Tier3 (C1-profiling)
  是否OSR=YES (osr_bci=118)
  编译耗时=86ms
  代码大小: total=41360 bytes, insts=29632 bytes
```

**关键结论：**

1. **`main` 方法被 OSR 编译了两次**：osr_bci=34（场景1的循环）和 osr_bci=118（场景3的循环），
   说明 `main` 方法中有两个热循环，各自触发了独立的 OSR 编译。

2. **`main` 方法代码极大（41360 bytes）**：因为 `main` 包含了所有场景的代码，
   C1 编译时需要处理整个方法体，生成的代码很大。

---

## 四、JIT 触发链路时序图

```
Java 方法执行（解释器）
  │
  ├─ 每次方法调用 → invocation_count += 步长(128)
  │   └─ 溢出时 → frequency_counter_overflow(branch_bcp=NULL)
  │        └─ 提交编译请求到 CompileQueue
  │
  ├─ 每次循环回边 → backedge_count += 步长(128)
  │   └─ 溢出时 → frequency_counter_overflow(branch_bcp=非NULL)
  │        └─ 提交 OSR 编译请求
  │
  └─ 编译线程（后台异步）
       └─ invoke_compiler_on_method()
            ├─ Tier1/3 → C1 编译 → profiled nmethods 段
            └─ Tier4   → C2 编译 → non-profiled nmethods 段
```

---

## 五、核心发现总结

| 问题 | 答案 |
|------|------|
| invocation_count 触发步长？ | **128**（计数器压缩设计，低3位存state） |
| Tier3InvocationThreshold 是多少？ | **200**（但实际以128步长检查，不精确到200） |
| OSR 触发时 invocation_count 是多少？ | **1**（方法只调用1次，但循环很热） |
| C1 vs C2 代码大小？ | **C2 更小**（hotMethod: C1=192B, C2=64B，C2仅33%） |
| C1 vs C2 编译耗时？ | C1 通常 <5ms，C2 可达 172ms |
| C1 代码存哪个 CodeCache 段？ | `profiled nmethods`（含 profiling 代码） |
| C2 代码存哪个 CodeCache 段？ | `non-profiled nmethods`（纯优化代码） |
| 触发次数 vs 编译次数比例？ | 3202 触发 → 632 编译（约 1/5，大量去重/丢弃） |

---

## 六、与第4章（G1 GC）的关联

JIT 编译和 GC 是 JVM 性能的两大支柱：

```
JIT 编译（第5章）                    G1 GC（第4章）
─────────────────────────────────────────────────────
热方法 → C2 编译 → 代码更小          代码对象存 CodeCache（不在堆中）
编译线程后台异步运行                  GC 线程后台并发运行
编译完成 → nmethod 存 CodeCache      GC 回收堆中的 Java 对象
```

**关键联系**：
- JIT 编译生成的 `nmethod` 存放在 CodeCache（不受 G1 GC 管理）
- G1 GC 的 Remark 阶段会处理 `CodeCache` 中的弱引用（`CodeCache::do_unloading`）
- 当类被卸载时，对应的 `nmethod` 也会从 CodeCache 中移除

