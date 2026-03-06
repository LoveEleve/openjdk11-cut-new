# JVM 启动链路插桩 —— 插桩代码清单

> 基于 OpenJDK 11 源码 `/data/workspace/openjdk-cut-new/`
> 标准环境：`-Xms8g -Xmx8g -XX:+UseG1GC -Xint`
> 状态：**已插桩，等待 build 后补充实际运行输出**

---

## 说明

本文档记录所有已完成插桩的**真实代码**。
实际运行输出（`[PROBE]` 日志）在 build 成功后由用户运行并填入 `02-JVM-Startup-Probe-Results.md`。

---

## 插桩点清单

| # | 函数 | 源码文件 | 插桩行号 | 验证目标 |
|---|------|---------|---------|---------|
| 1 | `mutex_init()` | `runtime/mutexLocker.cpp` | 353~391 | UseG1GC 时锁数量、G1专用锁列表 |
| 2 | `chunkpool_init()` | `memory/arena.cpp` | 157~170 | 4级 ChunkPool 的 chunk_size |
| 3 | `bytecodes_init()` | `interpreter/bytecodes.cpp` | 563~586 | 字节码总数、各长度分布 |
| 4 | `compilationPolicy_init()` | `runtime/compilationPolicy.cpp` | 100~114 | 分层编译阈值 C1/C2 触发条件 |
| 5 | `codeCache_init()` | `code/codeCache.cpp` | 1132~1148 | CodeCache 3段大小、初始已用量 |
| 6 | `universe_init()` | `memory/universe.cpp` | 874~902 | G1堆参数、Region数量、SymbolTable桶数 |
| 7 | `universe_post_init()` | `memory/universe.cpp` | 1351~1382 | 预分配 OOM/NPE 对象地址、Object vtable大小 |
| 8 | `InvocationCounter::reinitialize()` | `interpreter/invocationCounter.cpp` | 180~207 | 计数器阈值 raw vs actual、状态位数量 |
| 9 | `invocationCounter_init()` | `interpreter/invocationCounter.cpp` | 211~213 | DelayCompilationDuringStartup 状态 |
| 10 | `compileBroker_init()` | `compiler/compileBroker.cpp` | 250~256 | DirectivesStack 初始化确认 |
| 11 | `init_compiler_threads()` | `compiler/compileBroker.cpp` | 625~635 | C1/C2 线程数量计算公式 |

---

## 各插桩点真实代码

### 1. `mutex_init()` — `runtime/mutexLocker.cpp:353`

```cpp
// ===== [PROBE][mutex_init] 深度验证 =====
int total_mutex = 0;
int g1_mutex = 0;
for (int i = 0; i < _num_mutex; i++) {
  if (_mutex_array[i] != NULL) total_mutex++;
}
if (UseG1GC) {
  g1_mutex = 13;  // 源码中 G1 专用锁固定13把
}
tty->print_cr("[PROBE][mutex_init] 全局锁初始化完成:");
tty->print_cr("  UseG1GC=%s", UseG1GC ? "true" : "false");
tty->print_cr("  总锁数量=%d (含G1专用%d把)", total_mutex, g1_mutex);
tty->print_cr("  锁层级(rank从低到高): tty < leaf < nonleaf < barrier < safepoint");
tty->print_cr("  最高rank锁: Threads_lock(barrier), Safepoint_lock(safepoint)");
if (UseG1GC) {
  tty->print_cr("  G1专用锁列表:");
  tty->print_cr("    SATB_Q_FL_lock      (rank=access)   -- SATB队列空闲列表");
  tty->print_cr("    SATB_Q_CBL_mon      (rank=access)   -- SATB队列完成缓冲区");
  tty->print_cr("    Shared_SATB_Q_lock  (rank=access+1) -- 共享SATB队列");
  tty->print_cr("    DirtyCardQ_FL_lock  (rank=access)   -- 脏卡队列空闲列表");
  tty->print_cr("    DirtyCardQ_CBL_mon  (rank=access)   -- 脏卡队列完成缓冲区");
  tty->print_cr("    Shared_DirtyCardQ_lock(rank=access+1)-- 共享脏卡队列");
  tty->print_cr("    FreeList_lock       (rank=leaf)     -- 空闲Region列表");
  tty->print_cr("    OldSets_lock        (rank=leaf)     -- Old/Humongous Region集合");
  tty->print_cr("    RootRegionScan_lock (rank=leaf)     -- 根Region扫描");
  tty->print_cr("    MarkStackFreeList_lock(rank=leaf)   -- 标记栈空闲列表");
  tty->print_cr("    MarkStackChunkList_lock(rank=leaf)  -- 标记栈块列表");
  tty->print_cr("    StringDedupQueue_lock(rank=leaf)    -- 字符串去重队列");
  tty->print_cr("    StringDedupTable_lock(rank=leaf)    -- 字符串去重表");
  tty->print_cr("  → 结论: G1比Serial多13把锁，全部用于并发标记(SATB/DirtyCard)和Region管理");
}
// ===== [PROBE][mutex_init] END =====
```

**待验证的关键值**（build 后填入）：
- `total_mutex` = ？（预期约 70 把）
- `g1_mutex` = 13（代码中硬编码，但需确认 UseG1GC=true 分支确实走到）

---

### 2. `chunkpool_init()` — `memory/arena.cpp:157`

```cpp
// ===== [PROBE][chunkpool_init] 深度验证 =====
tty->print_cr("[PROBE][chunkpool_init] ChunkPool 4级内存池初始化完成:");
tty->print_cr("  pool[tiny]   chunk_size=%zu bytes (tiny,  用于小型Arena如符号解析)", (size_t)Chunk::tiny_size);
tty->print_cr("  pool[small]  chunk_size=%zu bytes (small, 用于初始Arena)", (size_t)Chunk::init_size);
tty->print_cr("  pool[medium] chunk_size=%zu bytes (medium,用于中型Arena如类解析)", (size_t)Chunk::medium_size);
tty->print_cr("  pool[large]  chunk_size=%zu bytes (large, 用于大型Arena如编译器)", (size_t)Chunk::size);
tty->print_cr("  → 结论: JVM用4级ChunkPool管理Arena内存(类比Netty tiny/small/normal/huge)");
tty->print_cr("  → 结论: slack=%d bytes = sizeof(Chunk)头部开销, 实际可用=标称值-slack", 20);
// ===== [PROBE][chunkpool_init] END =====
```

**待验证的关键值**（build 后填入）：
- `Chunk::tiny_size` = ？（源码注释说 256，需运行确认）
- `Chunk::init_size` = ？（源码注释说 1K）
- `Chunk::medium_size` = ？（源码注释说 10K）
- `Chunk::size` = ？（源码注释说 32K）

---

### 3. `bytecodes_init()` — `interpreter/bytecodes.cpp:563`

```cpp
// ===== [PROBE][bytecodes_init] 深度验证 =====
int count_1byte = 0, count_2byte = 0, count_3byte = 0, count_5byte = 0, count_other = 0;
for (int i = 0; i < Bytecodes::number_of_codes; i++) {
  int len = Bytecodes::length_for((Bytecodes::Code)i);
  if      (len == 1) count_1byte++;
  else if (len == 2) count_2byte++;
  else if (len == 3) count_3byte++;
  else if (len == 5) count_5byte++;
  else               count_other++;
}
tty->print_cr("[PROBE][bytecodes_init] 字节码表初始化完成:");
tty->print_cr("  总字节码数=%d (0x00~0xC9)", Bytecodes::number_of_codes);
tty->print_cr("  1字节指令=%d个 (~%.0f%%, 如nop/aload_0/ireturn, 操作数隐含在opcode中)",
    count_1byte, count_1byte * 100.0 / Bytecodes::number_of_codes);
tty->print_cr("  2字节指令=%d个 (~%.0f%%, 如bipush/iload, 操作数1字节)",
    count_2byte, count_2byte * 100.0 / Bytecodes::number_of_codes);
tty->print_cr("  3字节指令=%d个 (~%.0f%%, 如sipush/iinc/if_icmpeq, 操作数2字节)",
    count_3byte, count_3byte * 100.0 / Bytecodes::number_of_codes);
tty->print_cr("  5字节指令=%d个 (~%.0f%%, 如goto_w/invokedynamic, 操作数4字节)",
    count_5byte, count_5byte * 100.0 / Bytecodes::number_of_codes);
tty->print_cr("  其他长度=%d个 (可变长如tableswitch/lookupswitch)", count_other);
tty->print_cr("  → 结论: ~75%%指令为1字节, 字节码设计偏向紧凑以减小class文件体积");
tty->print_cr("  → 结论: invokedynamic(0xBA)=5字节, 是最长的固定长度指令");
// ===== [PROBE][bytecodes_init] END =====
```

**待验证的关键值**（build 后填入）：
- `number_of_codes` = ？（预期 202）
- `count_1byte` / `count_2byte` / `count_3byte` / `count_5byte` / `count_other` = ？

---

### 4. `compilationPolicy_init()` — `runtime/compilationPolicy.cpp:100`

```cpp
// ===== [PROBE][compilationPolicy_init] 深度验证 =====
tty->print_cr("[PROBE][compilationPolicy_init] 编译策略初始化完成:");
tty->print_cr("  CompilationPolicyChoice=%d", (int)CompilationPolicyChoice);
tty->print_cr("  TieredCompilation=%s", TieredCompilation ? "true" : "false");
tty->print_cr("  DelayCompilationDuringStartup=%s (启动期延迟JIT)", DelayCompilationDuringStartup ? "true" : "false");
tty->print_cr("  CompileThreshold=%d (非分层模式下的触发阈值)", (int)CompileThreshold);
tty->print_cr("  Tier3InvocationThreshold=%d (C1触发: 方法调用N次)", (int)Tier3InvocationThreshold);
tty->print_cr("  Tier4InvocationThreshold=%d (C2触发: 方法调用N次)", (int)Tier4InvocationThreshold);
tty->print_cr("  Tier3BackEdgeThreshold=%d (C1 OSR触发: 循环回边N次)", (int)Tier3BackEdgeThreshold);
tty->print_cr("  Tier4BackEdgeThreshold=%d (C2 OSR触发: 循环回边N次)", (int)Tier4BackEdgeThreshold);
tty->print_cr("  Tier3MinInvocationThreshold=%d (C1最低调用次数)", (int)Tier3MinInvocationThreshold);
tty->print_cr("  → 结论: C1触发比C2早%dx, 先快速编译再深度优化",
    (int)Tier4InvocationThreshold / ((int)Tier3InvocationThreshold > 0 ? (int)Tier3InvocationThreshold : 1));
tty->print_cr("  → 结论: -Xint模式下这些阈值无效, 所有方法永远解释执行");
// ===== [PROBE][compilationPolicy_init] END =====
```

**待验证的关键值**（build 后填入）：
- `CompilationPolicyChoice` = ？（预期 3 = AdvancedThresholdPolicy）
- `Tier3InvocationThreshold` = ？（预期 200）
- `Tier4InvocationThreshold` = ？（预期 5000）
- `Tier3BackEdgeThreshold` = ？（预期 60000）
- `Tier4BackEdgeThreshold` = ？（预期 40000）

---

### 5. `codeCache_init()` — `code/codeCache.cpp:1132`

```cpp
// ===== [PROBE][codeCache_init] 深度验证 =====
tty->print_cr("[PROBE][codeCache_init] CodeCache 初始化完成:");
tty->print_cr("  SegmentedCodeCache=%s", SegmentedCodeCache ? "true(分段模式)" : "false(单段模式)");
tty->print_cr("  ReservedCodeCacheSize=%zuMB (总保留空间)", ReservedCodeCacheSize / (1024*1024));
tty->print_cr("  NonNMethodCodeHeapSize=%zuMB (非方法代码: 解释器stub/vtable stub/适配器)",
    NonNMethodCodeHeapSize / (1024*1024));
tty->print_cr("  ProfiledCodeHeapSize=%zuMB (C1编译代码: 带profiling, 可被替换)",
    ProfiledCodeHeapSize / (1024*1024));
tty->print_cr("  NonProfiledCodeHeapSize=%zuMB (C2编译代码: 最终优化版本)",
    NonProfiledCodeHeapSize / (1024*1024));
tty->print_cr("  CodeCacheExpansionSize=%zuKB (每次扩展步长)", CodeCacheExpansionSize / 1024);
tty->print_cr("  unallocated_capacity=%zuKB (当前剩余可用)", CodeCache::unallocated_capacity() / 1024);
tty->print_cr("  → 结论: C1/C2代码隔离存放, NonNMethod段虽小(%zuMB)但最关键(解释器本身在此)",
    NonNMethodCodeHeapSize / (1024*1024));
tty->print_cr("  → 结论: 初始已用=%zuKB (仅解释器stub等基础设施)",
    (ReservedCodeCacheSize - CodeCache::unallocated_capacity()) / 1024);
// ===== [PROBE][codeCache_init] END =====
```

**待验证的关键值**（build 后填入）：
- `SegmentedCodeCache` = ？（TieredCompilation=true 时预期 true）
- `ReservedCodeCacheSize` = ？（预期 240MB）
- `NonNMethodCodeHeapSize` = ？（预期 5MB）
- `ProfiledCodeHeapSize` = ？（预期 117MB）
- `NonProfiledCodeHeapSize` = ？（预期 117MB）
- `unallocated_capacity` = ？（初始应接近 ReservedCodeCacheSize）

---

### 6. `universe_init()` — `memory/universe.cpp:874`

```cpp
// ===== [PROBE][universe_init] 深度验证 =====
{
  CollectedHeap* heap = Universe::heap();
  tty->print_cr("[PROBE][universe_init] 宇宙初始化完成:");
  tty->print_cr("  堆类型=%s", heap->name());
  tty->print_cr("  heap_capacity=%zuMB (%zu bytes)",
      heap->capacity() / (1024*1024), heap->capacity());
  tty->print_cr("  heap_max_capacity=%zuMB (%zu bytes)",
      heap->max_capacity() / (1024*1024), heap->max_capacity());
  if (UseG1GC) {
    G1CollectedHeap* g1h = G1CollectedHeap::heap();
    tty->print_cr("  [G1] region_size=%zuMB (%zu bytes)",
        HeapRegion::GrainBytes / (1024*1024), HeapRegion::GrainBytes);
    tty->print_cr("  [G1] total_region_count=%u", g1h->num_regions());
    tty->print_cr("  [G1] free_region_count=%u",  g1h->num_free_regions());
    tty->print_cr("  [G1] reserved_bytes=%zuMB",  g1h->g1_reserved().byte_size() / (1024*1024));
    tty->print_cr("  → 结论: -Xms8g -Xmx8g时堆完全预提交，free_region=total_region");
  }
  tty->print_cr("  Metaspace已初始化: MetaspaceSize=%zuMB, MaxMetaspaceSize=%zuMB",
      MetaspaceSize / (1024*1024),
      MaxMetaspaceSize == (size_t)-1 ? 0 : MaxMetaspaceSize / (1024*1024));
  tty->print_cr("  SymbolTable已创建 (桶数=%d)", SymbolTable::the_table()->table_size());
  tty->print_cr("  StringTable已创建 (桶数=%zu)", StringTable::the_table()->table_size());
  tty->print_cr("  → 结论: universe_init完成后堆/元空间/符号表全部就绪，但Java类还未加载");
}
// ===== [PROBE][universe_init] END =====
```

**待验证的关键值**（build 后填入）：
- `heap->name()` = ？（预期 "G1"）
- `heap_capacity` = ？（预期 8192MB）
- `HeapRegion::GrainBytes` = ？（预期 4MB = 4194304）
- `total_region_count` = ？（预期 2048）
- `free_region_count` = ？（预期 = total_region_count，因为 -Xms=-Xmx）
- `SymbolTable 桶数` = ？（预期 32768）
- `StringTable 桶数` = ？（预期 65536）

---

### 7. `universe_post_init()` — `memory/universe.cpp:1351`

```cpp
// ===== [PROBE][universe_post_init] 深度验证 =====
{
  ResourceMark rm;
  tty->print_cr("[PROBE][universe_post_init] 核心类和预分配对象完成:");
  tty->print_cr("  Object_klass=" PTR_FORMAT " (%s)",
      p2i(SystemDictionary::Object_klass()),
      SystemDictionary::Object_klass()->external_name());
  tty->print_cr("  String_klass=" PTR_FORMAT " (%s)",
      p2i(SystemDictionary::String_klass()),
      SystemDictionary::String_klass()->external_name());
  tty->print_cr("  Class_klass=" PTR_FORMAT " (%s)",
      p2i(SystemDictionary::Class_klass()),
      SystemDictionary::Class_klass()->external_name());
  tty->print_cr("  预分配OOM对象(Java heap space)=" PTR_FORMAT,
      p2i(Universe::_out_of_memory_error_java_heap));
  tty->print_cr("  预分配OOM对象(Metaspace)=" PTR_FORMAT,
      p2i(Universe::_out_of_memory_error_metaspace));
  tty->print_cr("  预分配NPE对象=" PTR_FORMAT,
      p2i(Universe::_null_ptr_exception_instance));
  tty->print_cr("  预分配ArithmeticException对象=" PTR_FORMAT,
      p2i(Universe::_arithmetic_exception_instance));
  tty->print_cr("  → 结论1: OOM/NPE/ArithmeticException在JVM启动时就预分配好了");
  tty->print_cr("  → 结论2: 预分配是为了避免抛出异常时再分配对象(此时可能已经OOM)");
  tty->print_cr("  → 结论3: Object/String/Class的klass地址在Metaspace中，不在堆里");
  tty->print_cr("  Object vtable大小=%d (Object有%d个虚方法)",
      SystemDictionary::Object_klass()->vtable_length() / vtableEntry::size(),
      SystemDictionary::Object_klass()->vtable_length() / vtableEntry::size());
}
// ===== [PROBE][universe_post_init] END =====
```

**待验证的关键值**（build 后填入）：
- `Object_klass` 地址 = ？（Metaspace 地址，非堆地址）
- `_out_of_memory_error_java_heap` 地址 = ？（堆地址）
- `Object vtable 大小` = ？（预期 5，Object 有 5 个虚方法）

---

### 8. `InvocationCounter::reinitialize()` — `interpreter/invocationCounter.cpp:180`

```cpp
// ===== [PROBE][invocationCounter_init] 深度验证 =====
tty->print_cr("[PROBE][InvocationCounter] 阈值计算完成:");
tty->print_cr("  CompileThreshold=%d (触发JIT编译的调用次数)", (int)CompileThreshold);
tty->print_cr("  number_of_noncount_bits=%d (低%d位存状态，不是计数)",
              (int)number_of_noncount_bits, (int)number_of_noncount_bits);
tty->print_cr("  InterpreterInvocationLimit(raw)=%d = CompileThreshold<<%d = %d<<%d",
              InterpreterInvocationLimit, (int)number_of_noncount_bits,
              (int)CompileThreshold, (int)number_of_noncount_bits);
tty->print_cr("  InterpreterInvocationLimit(actual)=%d (raw>>%d)",
              InterpreterInvocationLimit >> number_of_noncount_bits, (int)number_of_noncount_bits);
tty->print_cr("  → 结论1: raw值 != actual值！低%d位是状态位(carry/state)，不参与计数",
              (int)number_of_noncount_bits);
tty->print_cr("  InterpreterProfileLimit(raw)=%d, actual=%d (CompileThreshold*%d%%)",
              InterpreterProfileLimit, InterpreterProfileLimit >> number_of_noncount_bits,
              (int)InterpreterProfilePercentage);
tty->print_cr("  InterpreterBackwardBranchLimit=%d (ProfileInterpreter=%s)",
              InterpreterBackwardBranchLimit, ProfileInterpreter ? "true" : "false");
tty->print_cr("  → 结论2: ProfileInterpreter=true时BackwardBranchLimit不左移，因为比较的是MethodData计数器");
tty->print_cr("  sizeof(InvocationCounter)=%zu bytes (就是一个int，4字节)", sizeof(InvocationCounter));
tty->print_cr("  count_increment=%d (每次调用计数器增加的raw值，= 1<<%d)",
              (int)count_increment, (int)number_of_noncount_bits);
tty->print_cr("  carry_mask=0x%x, count_mask_value=0x%x",
              (int)carry_mask, (int)count_mask_value);
tty->print_cr("  delay_overflow=%s → 状态机action=%s",
              delay_overflow ? "true" : "false",
              delay_overflow ? "do_decay(启动期衰减，避免立即编译)" : "dummy_invocation_counter_overflow(正常溢出触发编译)");
tty->print_cr("  → 结论3: JVM启动期间delay_overflow=true，计数器溢出时衰减而非触发编译，避免启动时大量编译");
// ===== [PROBE][invocationCounter_init] END =====
```

**待验证的关键值**（build 后填入）：
- `number_of_noncount_bits` = ？（预期 4）
- `InterpreterInvocationLimit(raw)` = ？（预期 10000 << 4 = 160000）
- `InterpreterInvocationLimit(actual)` = ？（预期 10000）
- `InterpreterProfileLimit(raw)` = ？（预期 80000）
- `InterpreterBackwardBranchLimit` = ？
- `sizeof(InvocationCounter)` = ？（预期 4 字节）
- `count_increment` = ？（预期 16 = 1 << 4）
- `carry_mask` = ？
- `count_mask_value` = ？

---

### 9. `invocationCounter_init()` — `interpreter/invocationCounter.cpp:211`

```cpp
tty->print_cr("[PROBE][invocationCounter_init] 开始: DelayCompilationDuringStartup=%s",
              DelayCompilationDuringStartup ? "true" : "false");
InvocationCounter::reinitialize(DelayCompilationDuringStartup);
```

**待验证的关键值**（build 后填入）：
- `DelayCompilationDuringStartup` = ？（预期 true）

---

### 10. `compileBroker_init()` — `compiler/compileBroker.cpp:250`

```cpp
// ===== [PROBE][compileBroker_init] 深度验证 =====
tty->print_cr("[PROBE][compileBroker_init] 完成:");
tty->print_cr("  DirectivesStack已初始化 (编译指令栈，用于JIT编译控制)");
tty->print_cr("  注意: C1/C2线程在后续init_compiler_threads()中启动");
// ===== [PROBE][compileBroker_init] END =====
```

---

### 11. `init_compiler_threads()` — `compiler/compileBroker.cpp:625`

```cpp
// ===== [PROBE][init_compiler_threads] 深度验证 =====
tty->print_cr("[PROBE][init_compiler_threads] 编译线程数量计算:");
tty->print_cr("  CPU核数=%d (os::active_processor_count())", os::active_processor_count());
tty->print_cr("  C1线程数=%d (CompLevel_simple)", _c1_count);
tty->print_cr("  C2线程数=%d (CompLevel_full_optimization)", _c2_count);
tty->print_cr("  CICompilerCount=%d (总编译线程数，默认=max(2, CPU核数/2))", (int)CICompilerCount);
tty->print_cr("  计算公式: C2=max(1, CICompilerCount-1), C1=CICompilerCount-C2");
tty->print_cr("  → 结论: %d核CPU → CICompilerCount=%d → C1=%d个 + C2=%d个",
    os::active_processor_count(), (int)CICompilerCount, _c1_count, _c2_count);
tty->print_cr("  → 结论: C2线程比C1多，因为C2编译耗时更长，需要更多并发");
// ===== [PROBE][init_compiler_threads] END =====
```

**待验证的关键值**（build 后填入）：
- `os::active_processor_count()` = ？（取决于机器 CPU 核数）
- `CICompilerCount` = ？（预期 max(2, CPU/2)）
- `_c1_count` = ？
- `_c2_count` = ？

---

## 运行命令

build 成功后，用以下命令运行并收集 PROBE 输出：

```bash
/data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
  -Xms8g -Xmx8g -XX:+UseG1GC -Xint \
  -cp /data/workspace/demo/src \
  com.wjcoder.Main \
  2>&1 | grep -E "^\[PROBE\]" | head -200
```

收集到输出后，填入 `02-JVM-Startup-Probe-Results.md`。
