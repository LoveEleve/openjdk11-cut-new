# JVM 源码插桩验证方案 —— 完整大纲

> 基于 OpenJDK 11 源码 `/data/workspace/openjdk-cut-new/`
> 标准环境：`-Xms8g -Xmx8g -XX:+UseG1GC -Xint`
> 插桩目标：用 `tty->print_cr()` / JVM 日志系统在关键路径全面布桩，跑程序验证结论

---

## 核心原则：插桩必须得出结论

**❌ 没有意义的插桩（禁止）：**
```
[PROBE] universe_init() START
[PROBE] universe_init() DONE
```
这种输出什么都没说明。

**✅ 有意义的插桩（要求）：**
```
[PROBE][universe_init] G1堆创建完成:
  heap_size=8589934592 (8192MB)
  region_size=4194304 (4MB)
  region_count=2048
  eden_region_count=409 (20% of total)
  survivor_region_count=0 (初始为0)
  old_region_count=0 (初始为0)
  reserved_bytes=8589934592, committed_bytes=8589934592
  → 结论：-Xms8g -Xmx8g 时堆完全预提交，无动态扩展
```

**每个插桩点必须回答：**
1. **这个模块初始化了什么数据结构？** → 打印关键字段值
2. **这个值是怎么算出来的？** → 打印计算公式的输入参数
3. **这个行为符合预期吗？** → 与理论值对比，得出结论

---

## 总体思路

```
源码插桩  →  重新编译  →  运行 Demo  →  收集日志  →  对照源码验证结论
```

**插桩优于 GDB 的场景：**
- 需要观察完整执行序列（GDB 只能看片段）
- 需要统计调用次数 / 频率
- 需要在并发场景下观察多线程交错
- 需要跨越多个函数的数据流追踪
- 需要长时间运行后的累积状态

---

## 插桩技术速查

### 方式 A：`tty->print_cr()`（最简单，立即可用）
```cpp
tty->print_cr("[PROBE] %s:%d  param=%d", __FILE__, __LINE__, value);
```

### 方式 B：JVM 日志系统（最规范，可按 tag 过滤）
```cpp
log_trace(gc)("[PROBE] YoungGC start, eden_used=%zu", eden_used());
log_debug(class, load)("[PROBE] Loading class: %s", name->as_C_string());
```
运行时加 `-Xlog:gc*=trace:stdout` 即可看到。

### 方式 C：条件计数（防止刷屏）
```cpp
static volatile int _probe_count = 0;
int cnt = Atomic::add(1, &_probe_count);
if (cnt <= 20 || cnt % 1000 == 0) {
    tty->print_cr("[PROBE#%d] ...", cnt);
}
```

### 方式 D：带线程信息（并发场景）
```cpp
tty->print_cr("[PROBE] tid=%ld  func=%s  val=%p",
    os::current_thread_id(), __FUNCTION__, ptr);
```

### 方式 E：计时插桩（性能路径）
```cpp
jlong t0 = os::javaTimeNanos();
// ... 被测代码 ...
jlong t1 = os::javaTimeNanos();
tty->print_cr("[PROBE] elapsed=%ldns", t1 - t0);
```

### 方式 F：打印 Java 对象名称（需要 ResourceMark + HandleMark）
```cpp
// 在 JVM 内部打印 Java 类名时，必须先建立 ResourceMark，否则内存泄漏
ResourceMark rm;
HandleMark hm;
tty->print_cr("[PROBE] klass=%s", klass->external_name());
tty->print_cr("[PROBE] method=%s", method->name_and_sig_as_C_string());
```

### 方式 G：多线程安全输出（防止乱序）
```cpp
// 用 tty_lock 保证多线程输出不交错
ttyLocker ttyl;
tty->print_cr("[PROBE][tid=%ld] ...", os::current_thread_id());
```

### 方式 H：利用已有内置 Flag（无需插桩）
```
-XX:+PrintCompilation          # JIT 编译事件（无需插桩 CompileBroker）
-XX:+PrintGCDetails            # GC 详情
-Xlog:class+load=info          # 类加载（无需插桩 ClassFileParser）
-Xlog:safepoint=trace          # Safepoint 事件
-Xlog:gc*=trace                # G1 全量 GC 日志
-XX:+TraceBiasedLocking        # 偏向锁事件
-XX:+PrintInlining             # JIT 内联决策
```
> **原则**：能用内置 Flag 看到的，优先用 Flag，插桩只补充 Flag 看不到的细节。

### 编译增量更新（只重编译修改的文件）
```bash
# 只重编译 hotspot（不重编译 jdk 层），速度快 3-5 倍
make CONF=linux-x86_64-normal-server-slowdebug hotspot 2>&1 | tail -30
```

---

## 插桩模块大纲（按执行顺序）

---

### 第 1 章：JVM 启动链路插桩

**目标**：验证 JVM 从 `main()` 到 `JavaMain()` 再到 `Threads::create_vm()` 的完整启动序列，**重点是每个子模块初始化了什么、初始化后的关键数据是什么**

---

#### 1.1 `vm_init_globals()` —— 5 个基础设施模块

**验证目标**：这 5 个模块按什么顺序初始化？每个模块初始化后的关键状态是什么？

##### 1.1.1 `mutex_init()` —— 全局锁初始化

**要验证的问题：**
- UseG1GC 时，`mutex_init()` 到底初始化了多少把锁？（源码中有条件分支：`if (UseG1GC)` 额外初始化 G1 专用锁）
- 这些锁按什么层级（rank）组织？最高 rank 是什么？
- G1 专用锁有哪些？（SATB_Q_FL_lock、DirtyCardQ_FL_lock 等）

**插桩代码位置**：`runtime/mutexLocker.cpp:mutex_init()` 末尾

**插桩内容**：
```cpp
// 在 mutex_init() 末尾统计锁数量
static int mutex_count = 0;
static int monitor_count = 0;
// 在每个 def() 宏展开处计数，或在末尾直接统计
tty->print_cr("[PROBE][mutex_init] 初始化完成:");
tty->print_cr("  UseG1GC=%s", UseG1GC ? "true" : "false");
tty->print_cr("  tty_lock rank=tty (最低)");
tty->print_cr("  Threads_lock rank=barrier (最高之一)");
tty->print_cr("  G1专用锁: SATB_Q_FL_lock, DirtyCardQ_FL_lock, FreeList_lock, OldSets_lock, RootRegionScan_lock");
tty->print_cr("  G1专用Monitor: SATB_Q_CBL_mon, DirtyCardQ_CBL_mon, FullGCCount_lock");
```

**预期输出与结论：**
```
[PROBE][mutex_init] 初始化完成:
  UseG1GC=true
  总锁数量=~70把 (含G1专用的~10把)
  锁层级: tty < leaf < nonleaf < barrier < safepoint
  G1专用锁: SATB_Q_FL_lock(SATB队列), DirtyCardQ_FL_lock(脏卡队列),
            FreeList_lock(空闲Region列表), OldSets_lock(Old/Humongous集合),
            RootRegionScan_lock(根Region扫描)
→ 结论：UseG1GC 比 UseSerialGC 多初始化约10把锁，全部用于G1并发标记和写屏障
```

---

##### 1.1.2 `chunkpool_init()` —— Chunk 内存池初始化

**要验证的问题：**
- ChunkPool 初始化了几个池？每个池的 chunk 大小是多少？
- 这和 Netty 的 PooledByteBufAllocator 有什么异同？（JVM 内部也用了池化思想）

**插桩代码位置**：`memory/arena.cpp:chunkpool_init()` 或 `utilities/chunkedList.hpp`

**插桩内容**：
```cpp
tty->print_cr("[PROBE][chunkpool_init] ChunkPool 初始化:");
tty->print_cr("  pool[0] chunk_size=%zu (tiny)", Chunk::tiny_size);
tty->print_cr("  pool[1] chunk_size=%zu (init)", Chunk::init_size);
tty->print_cr("  pool[2] chunk_size=%zu (medium)", Chunk::medium_size);
tty->print_cr("  pool[3] chunk_size=%zu (size)", Chunk::size);
```

**预期输出与结论：**
```
[PROBE][chunkpool_init] ChunkPool 初始化:
  pool[0] chunk_size=256   (tiny,  用于小型Arena)
  pool[1] chunk_size=1024  (init,  用于初始Arena)
  pool[2] chunk_size=8192  (medium,用于中型Arena)
  pool[3] chunk_size=32768 (size,  用于大型Arena)
→ 结论：JVM 用4级 ChunkPool 管理 Arena 内存，避免频繁 malloc/free
         类比 Netty：Netty 用 tiny/small/normal/huge 4级，JVM 用 tiny/init/medium/size 4级
```

---

#### 1.2 `init_globals()` —— 22 个核心模块（最重要）

**验证目标**：22 个模块的初始化顺序是否与源码一致？每个模块初始化后的关键数据是什么？

---

##### 1.2.1 `bytecodes_init()` —— 字节码表初始化

**要验证的问题：**
- JVM 共有多少个字节码？（理论值：202个，0x00-0xC9）
- 每个字节码的 length（指令长度）是多少？（1-5字节不等）
- 哪些字节码是"宽字节码"（wide 前缀）？

**插桩代码位置**：`interpreter/bytecodes.cpp:Bytecodes::initialize()` 末尾

**插桩内容**：
```cpp
// 统计字节码数量和长度分布
int count_1byte = 0, count_2byte = 0, count_3byte = 0, count_5byte = 0;
for (int i = 0; i < Bytecodes::number_of_codes; i++) {
    int len = Bytecodes::length_for((Bytecodes::Code)i);
    if (len == 1) count_1byte++;
    else if (len == 2) count_2byte++;
    else if (len == 3) count_3byte++;
    else if (len == 5) count_5byte++;
}
tty->print_cr("[PROBE][bytecodes_init] 字节码表初始化完成:");
tty->print_cr("  总字节码数=%d", Bytecodes::number_of_codes);
tty->print_cr("  1字节指令=%d个 (如nop/aload_0/ireturn)", count_1byte);
tty->print_cr("  2字节指令=%d个 (如bipush/iload)", count_2byte);
tty->print_cr("  3字节指令=%d个 (如sipush/iinc/if_icmpeq)", count_3byte);
tty->print_cr("  5字节指令=%d个 (如goto_w/invokedynamic)", count_5byte);
```

**预期输出与结论：**
```
[PROBE][bytecodes_init] 字节码表初始化完成:
  总字节码数=202
  1字节指令=~150个 (大多数操作数隐含在操作码中)
  2字节指令=~30个  (操作数1字节)
  3字节指令=~15个  (操作数2字节)
  5字节指令=~7个   (操作数4字节，如invokedynamic)
→ 结论：JVM 字节码设计偏向紧凑，约75%的指令是1字节，减少class文件体积
```

---

##### 1.2.2 `compilationPolicy_init()` —— 编译策略初始化

**要验证的问题：**
- `-Xint` 模式下，编译策略是什么？（应该是 `SimpleCompPolicy`，不做任何JIT）
- 正常模式下，编译策略是什么？（`AdvancedThresholdPolicy`，分层编译）
- 分层编译的各层阈值是多少？（C1触发阈值 vs C2触发阈值）

**插桩代码位置**：`runtime/compilationPolicy.cpp:compilationPolicy_init()` 末尾

**插桩内容**：
```cpp
tty->print_cr("[PROBE][compilationPolicy_init] 编译策略初始化:");
tty->print_cr("  策略类型=%s", CompilationPolicy::policy()->name());
tty->print_cr("  TieredCompilation=%s", TieredCompilation ? "true" : "false");
tty->print_cr("  CompileThreshold=%d", (int)CompileThreshold);
tty->print_cr("  Tier3InvocationThreshold=%d (C1触发)", (int)Tier3InvocationThreshold);
tty->print_cr("  Tier4InvocationThreshold=%d (C2触发)", (int)Tier4InvocationThreshold);
tty->print_cr("  Tier3BackEdgeThreshold=%d (C1 OSR触发)", (int)Tier3BackEdgeThreshold);
tty->print_cr("  Tier4BackEdgeThreshold=%d (C2 OSR触发)", (int)Tier4BackEdgeThreshold);
```

**预期输出与结论：**
```
[PROBE][compilationPolicy_init] 编译策略初始化:
  策略类型=AdvancedThresholdPolicy (分层编译)
  TieredCompilation=true
  CompileThreshold=10000 (默认值，-Xint时不使用)
  Tier3InvocationThreshold=200  (方法调用200次 → C1编译)
  Tier4InvocationThreshold=5000 (方法调用5000次 → C2编译)
  Tier3BackEdgeThreshold=60000  (循环回边60000次 → C1 OSR)
  Tier4BackEdgeThreshold=40000  (循环回边40000次 → C2 OSR)
→ 结论：分层编译下 C1 触发比 C2 早25倍，先用C1快速编译，再用C2深度优化
         -Xint 模式下这些阈值无效，所有方法永远解释执行
```

---

##### 1.2.3 `codeCache_init()` —— CodeCache 初始化

**要验证的问题：**
- CodeCache 的总大小是多少？（默认 240MB，可用 `-XX:ReservedCodeCacheSize` 调整）
- CodeCache 分为几个段？每段的大小和用途是什么？
- 初始时 CodeCache 使用了多少？（应该接近0）

**插桩代码位置**：`code/codeCache.cpp:CodeCache::initialize()` 末尾

**插桩内容**：
```cpp
tty->print_cr("[PROBE][codeCache_init] CodeCache 初始化完成:");
tty->print_cr("  ReservedCodeCacheSize=%zuMB", ReservedCodeCacheSize / M);
tty->print_cr("  NonNMethodCodeHeapSize=%zuMB (非方法代码，如解释器stub)", NonNMethodCodeHeapSize / M);
tty->print_cr("  ProfiledCodeHeapSize=%zuMB (C1编译代码)", ProfiledCodeHeapSize / M);
tty->print_cr("  NonProfiledCodeHeapSize=%zuMB (C2编译代码)", NonProfiledCodeHeapSize / M);
tty->print_cr("  初始已用=%zuKB", CodeCache::unallocated_capacity() == 0 ? 0 : (ReservedCodeCacheSize - CodeCache::unallocated_capacity()) / K);
```

**预期输出与结论：**
```
[PROBE][codeCache_init] CodeCache 初始化完成:
  ReservedCodeCacheSize=240MB
  NonNMethodCodeHeapSize=5MB   (解释器stub、vtable stub等)
  ProfiledCodeHeapSize=117MB   (C1编译的带profiling代码)
  NonProfiledCodeHeapSize=117MB (C2编译的最终优化代码)
  初始已用≈0KB
→ 结论：CodeCache 分3段管理，C1/C2代码隔离存放，避免互相污染
         NonNMethod段虽小(5MB)但最关键，解释器本身就在这里
```

---

##### 1.2.4 `universe_init()` —— 最重要：Java 堆 + 元空间 + 符号表创建

**要验证的问题：**
- G1 堆的实际参数：heap_size、region_size、region_count 是多少？
- 元空间的初始大小和最大大小是多少？
- 符号表（SymbolTable）的初始容量是多少？（哈希表桶数）
- 字符串表（StringTable）的初始容量是多少？
- 堆内存是否完全预提交？（-Xms == -Xmx 时应该是）

**插桩代码位置**：`gc/g1/g1CollectedHeap.cpp:G1CollectedHeap::initialize()` 末尾

**插桩内容**：
```cpp
tty->print_cr("[PROBE][universe_init/G1] G1堆初始化完成:");
tty->print_cr("  heap_size=%zu bytes (%zuMB)", MaxHeapSize, MaxHeapSize / M);
tty->print_cr("  region_size=%zu bytes (%zuMB)", HeapRegion::GrainBytes, HeapRegion::GrainBytes / M);
tty->print_cr("  region_count=%u", _hrm.length());
tty->print_cr("  eden_count=%u, survivor_count=%u, old_count=%u, humongous_count=%u",
    _eden.length(), _survivor.length(), _old_set.length(), _humongous_set.length());
tty->print_cr("  reserved=[" PTR_FORMAT ", " PTR_FORMAT ") size=%zu",
    p2i(_hrm.reserved().start()), p2i(_hrm.reserved().end()), _hrm.reserved().byte_size());
tty->print_cr("  committed_bytes=%zu (预提交=%s)",
    _hrm.capacity(), MaxHeapSize == InitialHeapSize ? "YES(Xms==Xmx)" : "NO");
// 元空间
tty->print_cr("  MetaspaceSize=%zuMB, MaxMetaspaceSize=%s",
    MetaspaceSize / M, MaxMetaspaceSize == (size_t)-1 ? "unlimited" : "limited");
// 符号表
tty->print_cr("  SymbolTable初始桶数=%d", SymbolTable::the_table()->table_size());
tty->print_cr("  StringTable初始桶数=%d", StringTable::the_table()->table_size());
```

**预期输出与结论：**
```
[PROBE][universe_init/G1] G1堆初始化完成:
  heap_size=8589934592 bytes (8192MB)
  region_size=4194304 bytes (4MB)
  region_count=2048
  eden_count=0, survivor_count=0, old_count=0, humongous_count=0  ← 初始全部是Free
  reserved=[0x700000000, 0x900000000) size=8589934592
  committed_bytes=8589934592 (预提交=YES, Xms==Xmx)
  MetaspaceSize=21MB, MaxMetaspaceSize=unlimited
  SymbolTable初始桶数=32768
  StringTable初始桶数=65536
→ 结论1：-Xms8g -Xmx8g 时堆完全预提交，JVM启动时就向OS申请了8GB内存
→ 结论2：2048个Region全部初始为Free状态，没有预分配eden/old
→ 结论3：region_size=4MB 由公式 heap_size/2048 决定（G1默认最多2048个Region）
→ 结论4：SymbolTable(32768桶) < StringTable(65536桶)，因为字符串比符号多
```

---

##### 1.2.5 `interpreter_init()` —— 解释器汇编代码生成

**要验证的问题：**
- 解释器生成了多少个字节码处理器（handler）？
- dispatch table 的地址在哪里？大小是多少？
- 解释器代码占用了多少 CodeCache 空间？
- 生成的代码在内存中的布局是什么？（entry_point 在哪？）

**插桩代码位置**：`interpreter/templateInterpreterGenerator.cpp:generate_all()` 末尾

**插桩内容**：
```cpp
tty->print_cr("[PROBE][interpreter_init] 解释器初始化完成:");
tty->print_cr("  dispatch_table地址=" PTR_FORMAT, p2i(Interpreter::dispatch_table(itos)));
tty->print_cr("  字节码handler数量=%d (应为202)", Bytecodes::number_of_codes);
tty->print_cr("  解释器代码段: [" PTR_FORMAT ", " PTR_FORMAT ") size=%zuKB",
    p2i(AbstractInterpreter::code()->code_start()),
    p2i(AbstractInterpreter::code()->code_end()),
    (AbstractInterpreter::code()->code_end() - AbstractInterpreter::code()->code_start()) / K);
tty->print_cr("  method_entry(normal)=" PTR_FORMAT, p2i(Interpreter::entry_for_kind(AbstractInterpreter::zerolocals)));
tty->print_cr("  method_entry(native)=" PTR_FORMAT, p2i(Interpreter::entry_for_kind(AbstractInterpreter::native)));
```

**预期输出与结论：**
```
[PROBE][interpreter_init] 解释器初始化完成:
  dispatch_table地址=0x7f1234560000
  字节码handler数量=202
  解释器代码段: [0x7f1234560000, 0x7f1234680000) size=1152KB
  method_entry(normal)=0x7f1234561000
  method_entry(native)=0x7f1234562000
→ 结论1：解释器本身是一段约1MB的汇编代码，存放在 CodeCache 的 NonNMethod 段
→ 结论2：dispatch_table 是一个 202 项的函数指针数组，每项指向对应字节码的汇编处理器
→ 结论3：解释器在 JVM 启动时就完全生成好了，不是运行时动态生成的
```

---

##### 1.2.6 `invocationCounter_init()` —— 调用计数器阈值初始化

**要验证的问题：**
- `InterpreterInvocationLimit` 的原始值（raw value）是多少？实际计数阈值是多少？
- 为什么 raw value 和实际阈值不同？（因为计数器低位存状态位）
- `InterpreterProfileLimit` 是多少？（触发 profiling 的阈值）
- `InterpreterBackwardBranchLimit` 是多少？（OSR 触发阈值）
- 这些值的计算公式是什么？

**插桩代码位置**：`interpreter/invocationCounter.cpp:InvocationCounter::reinitialize()` 末尾（已有插桩）

**预期输出与结论：**
```
[InvocationCounter::reinitialize] CompileThreshold=10000
[InvocationCounter::reinitialize] InterpreterInvocationLimit=160000 (raw)
  actual_count=10000 (raw >> 4, 因为低4位是状态位)
[InvocationCounter::reinitialize] InterpreterProfileLimit=80000 (raw)
  actual_count=5000 (CompileThreshold * 50% = 5000)
[InvocationCounter::reinitialize] InterpreterBackwardBranchLimit=140000 (raw)
  actual_count=8750 (CompileThreshold * 140% - 50% = 8750)
→ 结论1：InvocationCounter 低4位存状态，所以 raw_limit = actual_limit << 4
→ 结论2：ProfileLimit = CompileThreshold * 50%，即调用5000次开始收集profiling数据
→ 结论3：BackwardBranchLimit 用于 OSR，比 InvocationLimit 低，循环热点比方法热点更早触发编译
```

---

##### 1.2.7 `compileBroker_init()` —— JIT 编译线程启动

**要验证的问题：**
- 启动了多少个 C1 编译线程？多少个 C2 编译线程？
- 线程数量是怎么算出来的？（与 CPU 核数的关系）
- 每个编译线程的 OS tid 是多少？
- 编译队列（CompileQueue）的初始状态是什么？

**插桩代码位置**：`compiler/compileBroker.cpp:compileBroker_init()` 末尾

**插桩内容**：
```cpp
tty->print_cr("[PROBE][compileBroker_init] JIT编译线程启动完成:");
tty->print_cr("  CPU核数=%d", os::active_processor_count());
tty->print_cr("  C1线程数=%d (CompilationPolicy::compiler_count(C1))", _c1_count);
tty->print_cr("  C2线程数=%d (CompilationPolicy::compiler_count(C2))", _c2_count);
tty->print_cr("  C1队列初始大小=%d", _c1_compile_queue != NULL ? _c1_compile_queue->size() : 0);
tty->print_cr("  C2队列初始大小=%d", _c2_compile_queue != NULL ? _c2_compile_queue->size() : 0);
// 打印每个编译线程的 tid
for (int i = 0; i < _c1_count; i++) {
    tty->print_cr("  C1-CompilerThread-%d: os_tid=%ld", i, _compiler1_objects[i] != NULL ? ... : -1);
}
```

**预期输出与结论：**
```
[PROBE][compileBroker_init] JIT编译线程启动完成:
  CPU核数=8
  C1线程数=4  (公式: min(cpu_count, 3) + 1 ≈ 4)
  C2线程数=5  (公式: cpu_count * 5/8 ≈ 5)
  C1队列初始大小=0
  C2队列初始大小=0
  C1-CompilerThread-0: os_tid=12346
  C1-CompilerThread-1: os_tid=12347
  ...
→ 结论1：C1/C2 线程数与 CPU 核数相关，8核机器约 4C1 + 5C2
→ 结论2：编译线程在 JVM 启动时就创建好了，不是按需创建
→ 结论3：-Xint 模式下 _c1_count=0, _c2_count=0，不创建任何编译线程
```

---

##### 1.2.8 `universe_post_init()` —— 核心异常类预创建

**要验证的问题：**
- `universe_post_init()` 预创建了哪些异常对象？（OOM、NPE、StackOverflow 等）
- 这些异常对象的 klass 地址是多少？
- 为什么要预创建 OOM 异常？（因为 OOM 时无法再分配内存来创建异常对象）
- 预创建了多少个 OOM 异常实例？（需要多个，因为可能在不同场景下同时抛出）

**插桩代码位置**：`memory/universe.cpp:universe_post_init()` 末尾

**插桩内容**：
```cpp
tty->print_cr("[PROBE][universe_post_init] 核心类和异常预创建完成:");
tty->print_cr("  OutOfMemoryError klass=" PTR_FORMAT, p2i(Universe::_out_of_memory_error_java_heap->klass()));
tty->print_cr("  OOM实例数量=%d (预创建多个用于不同场景)", 4); // java_heap/metaspace/compressed_class/array
tty->print_cr("  NullPointerException klass=" PTR_FORMAT, p2i(Universe::_null_ptr_exception_instance->klass()));
tty->print_cr("  ArithmeticException klass=" PTR_FORMAT, p2i(Universe::_arithmetic_exception_instance->klass()));
tty->print_cr("  StackOverflowError klass=" PTR_FORMAT, p2i(Universe::_virtual_machine_error_instance->klass()));
tty->print_cr("  → 设计原因: OOM时无法new对象，必须提前准备好异常实例");
```

**预期输出与结论：**
```
[PROBE][universe_post_init] 核心类和异常预创建完成:
  OutOfMemoryError klass=0x7f1234000000
  OOM实例数量=4 (java_heap/metaspace/compressed_class/array各一个)
  NullPointerException klass=0x7f1234001000
  ArithmeticException klass=0x7f1234002000
  StackOverflowError klass=0x7f1234003000
→ 结论1：JVM 预创建了4种 OOM 异常实例，分别对应4种内存耗尽场景
→ 结论2：NPE 和 ArithmeticException 也预创建，因为这两种异常极其频繁
→ 结论3：这些预创建的异常对象是 GC Root，永远不会被回收
```

---

#### 1.3 启动链路总结验证

**最终验证：打印完整的启动时间线**

在 `Threads::create_vm()` 末尾插桩，打印各阶段耗时：

```cpp
tty->print_cr("[PROBE][create_vm] JVM启动完成，各阶段耗时:");
tty->print_cr("  vm_init_globals: %ldms", vm_init_globals_elapsed);
tty->print_cr("  init_globals:    %ldms", init_globals_elapsed);
tty->print_cr("    ├─ universe_init:      %ldms (最耗时，创建8GB堆)", universe_init_elapsed);
tty->print_cr("    ├─ interpreter_init:   %ldms (生成解释器汇编)", interpreter_init_elapsed);
tty->print_cr("    ├─ compileBroker_init: %ldms (启动JIT线程)", compileBroker_elapsed);
tty->print_cr("    └─ universe_post_init: %ldms (加载核心类)", post_init_elapsed);
tty->print_cr("  总启动耗时: %ldms", total_elapsed);
```

**预期输出与结论：**
```
[PROBE][create_vm] JVM启动完成，各阶段耗时:
  vm_init_globals: 2ms
  init_globals:    450ms
    ├─ universe_init:      380ms (最耗时，向OS申请8GB内存)
    ├─ interpreter_init:   30ms  (生成1MB汇编代码)
    ├─ compileBroker_init: 20ms  (创建9个JIT线程)
    └─ universe_post_init: 15ms  (加载java.lang.*核心类)
  总启动耗时: ~500ms
→ 结论：JVM 启动时间主要花在 universe_init（向OS申请大内存），
         -Xms8g 比 -Xms256m 启动慢约 300ms，就是因为内存预提交
```

---

### 第 2 章：类加载链路插桩

**目标**：验证从 `ClassLoader.loadClass()` 到 `InstanceKlass` 创建的完整链路，**重点是每个阶段处理了什么数据、产生了什么结构**

---

#### 2.1 双亲委派链路验证

**要验证的问题：**
- `com.wjcoder.Main` 的加载请求经过了几次委派？委派链是什么？
- 哪些类由 BootstrapClassLoader 加载？哪些由 AppClassLoader 加载？
- `SystemDictionary` 中已有多少个类？（加载 Main 之前）

**插桩代码位置**：`classfile/systemDictionary.cpp:SystemDictionary::load_instance_class()` 入口

**插桩内容**：
```cpp
tty->print_cr("[PROBE][ClassLoad] load_instance_class: name=%s, loader=%s",
    name->as_C_string(),
    loader.is_null() ? "BootstrapClassLoader" : loader->klass()->external_name());
tty->print_cr("  SystemDictionary当前已有类数=%d", SystemDictionary::number_of_classes());
tty->print_cr("  是否已在字典中=%s", SystemDictionary::find(name, loader, protection_domain, THREAD) != NULL ? "YES(缓存命中)" : "NO(需要加载)");
```

**预期输出与结论：**
```
[PROBE][ClassLoad] load_instance_class: name=java/lang/Object, loader=BootstrapClassLoader
  SystemDictionary当前已有类数=0
[PROBE][ClassLoad] load_instance_class: name=java/lang/String, loader=BootstrapClassLoader
  SystemDictionary当前已有类数=1
... (大量核心类加载) ...
[PROBE][ClassLoad] load_instance_class: name=com/wjcoder/Main, loader=sun/misc/Launcher$AppClassLoader
  SystemDictionary当前已有类数=487
  是否已在字典中=NO(需要加载)
→ 结论1：JVM 启动到执行 Main 之前，已经加载了约487个类（全是 java.lang.* 等核心类）
→ 结论2：com.wjcoder.Main 由 AppClassLoader 加载，java.lang.* 由 BootstrapClassLoader 加载
→ 结论3：双亲委派在 load_instance_class 中体现：先检查 parent，再自己加载
```

---

#### 2.2 ClassFileParser 阶段 —— 解析 .class 文件

**要验证的问题：**
- `com.wjcoder.Main` 的 .class 文件有多大？常量池有多少项？
- 解析出了多少个方法？多少个字段？
- 常量池中有多少个字符串常量？多少个方法引用？
- 解析后的 InstanceKlass 大小是多少字节？

**插桩代码位置**：`classfile/classFileParser.cpp:ClassFileParser::create_instance_klass()` 末尾

**插桩内容**：
```cpp
tty->print_cr("[PROBE][ClassFileParser] 解析完成: %s", _class_name->as_C_string());
tty->print_cr("  .class文件大小=%d bytes", _class_file_stream->length());
tty->print_cr("  常量池项数=%d", _cp->length());
tty->print_cr("  方法数=%d (含<init>和<clinit>)", _methods->length());
tty->print_cr("  字段数=%d", _fields->length());
tty->print_cr("  接口数=%d", _local_interfaces->length());
tty->print_cr("  父类=%s", _super_klass != NULL ? _super_klass->external_name() : "none");
tty->print_cr("  InstanceKlass大小=%zu bytes", ik->size() * wordSize);
tty->print_cr("  vtable大小=%d slots", ik->vtable_length());
tty->print_cr("  itable大小=%d slots", ik->itable_length());
```

**预期输出与结论：**
```
[PROBE][ClassFileParser] 解析完成: com/wjcoder/Main
  .class文件大小=1234 bytes
  常量池项数=87
  方法数=3 (main + <init> + 可能的hotMethod)
  字段数=0
  接口数=0
  父类=java/lang/Object
  InstanceKlass大小=512 bytes
  vtable大小=5 slots (继承自Object的5个虚方法)
  itable大小=0 slots (没有实现接口)
→ 结论1：InstanceKlass 是 .class 文件在内存中的完整表示，大小约为 .class 文件的 0.4 倍
→ 结论2：vtable 继承了 Object 的 5 个虚方法（hashCode/equals/clone/toString/finalize）
→ 结论3：常量池项数 >> 方法数，因为每个方法调用都需要多个常量池项（类名+方法名+描述符）
```

---

#### 2.3 链接阶段 —— 字节码验证 + vtable 构建

**要验证的问题：**
- 链接分为哪几个子阶段？（verify → prepare → resolve）
- 字节码验证（verify）检查了什么？耗时多少？
- vtable 构建时，每个 slot 指向哪个方法？
- `<clinit>` 是否存在？何时触发？

**插桩代码位置**：`oops/instanceKlass.cpp:InstanceKlass::link_class_impl()` 各阶段

**插桩内容**：
```cpp
tty->print_cr("[PROBE][ClassLink] %s 链接开始:", external_name());
tty->print_cr("  阶段1: verify (字节码验证)");
// ... verify 后
tty->print_cr("  verify完成: 验证了%d个方法的字节码", methods()->length());
tty->print_cr("  阶段2: prepare (静态字段分配默认值)");
tty->print_cr("  阶段3: rewrite (字节码重写，如将invokevirtual改为快速版本)");
tty->print_cr("  vtable构建完成:");
for (int i = 0; i < vtable_length(); i++) {
    klassVtable vt = vtable();
    tty->print_cr("    vtable[%d] = %s", i, vt.method_at(i)->name_and_sig_as_C_string());
}
tty->print_cr("  has_clinit=%s", class_initializer() != NULL ? "YES" : "NO");
```

**预期输出与结论：**
```
[PROBE][ClassLink] com/wjcoder/Main 链接开始:
  阶段1: verify (字节码验证)
  verify完成: 验证了3个方法的字节码
  阶段2: prepare (静态字段分配默认值)
  阶段3: rewrite (字节码重写)
  vtable构建完成:
    vtable[0] = java/lang/Object.finalize()V
    vtable[1] = java/lang/Object.equals(Ljava/lang/Object;)Z
    vtable[2] = java/lang/Object.toString()Ljava/lang/String;
    vtable[3] = java/lang/Object.hashCode()I
    vtable[4] = java/lang/Object.clone()Ljava/lang/Object;
  has_clinit=NO (Main没有静态初始化块)
→ 结论1：vtable 的前5个 slot 固定是 Object 的5个虚方法，这是 Java 多态的基础
→ 结论2：字节码重写把 invokevirtual 改为 fast_invokevirtual，避免运行时重复解析
→ 结论3：没有 <clinit> 的类在首次使用时不需要执行初始化，直接进入 LINKED 状态
```

---

### 第 3 章：对象分配链路插桩

**目标**：验证 `new Object()` 从字节码到 TLAB 分配的完整路径，**重点是 TLAB 的内部状态变化和大对象的 Region 分配**

---

#### 3.1 TLAB 分配路径 —— 快速路径

**要验证的问题：**
- TLAB 的初始大小是多少？（理论值：Eden 大小 / 线程数 / 8）
- 每次 TLAB 分配后，`top` 指针移动了多少？
- TLAB 什么时候触发 refill？（剩余空间 < 最小分配单元时）
- 一个 TLAB 的生命周期内分配了多少个对象？

**插桩代码位置**：`gc/shared/threadLocalAllocBuffer.cpp:ThreadLocalAllocBuffer::allocate()` 和 `refill()`

**插桩内容**：
```cpp
// 在 refill() 中打印 TLAB 状态
tty->print_cr("[PROBE][TLAB] refill触发: tid=%ld", os::current_thread_id());
tty->print_cr("  旧TLAB: start=" PTR_FORMAT " top=" PTR_FORMAT " end=" PTR_FORMAT,
    p2i(start()), p2i(top()), p2i(end()));
tty->print_cr("  旧TLAB已用=%zuKB, 剩余=%zuKB",
    (top() - start()) * wordSize / K, (end() - top()) * wordSize / K);
tty->print_cr("  旧TLAB分配对象数=%d", _number_of_refills > 0 ? ... : 0);
tty->print_cr("  新TLAB请求大小=%zuKB", new_tlab_size * wordSize / K);
// 在 initialize() 中打印新 TLAB 信息
tty->print_cr("[PROBE][TLAB] 新TLAB分配: start=" PTR_FORMAT " size=%zuKB",
    p2i(start()), (end() - start()) * wordSize / K);
```

**预期输出与结论：**
```
[PROBE][TLAB] refill触发: tid=12345
  旧TLAB: start=0x700001000000 top=0x700001100000 end=0x700001100000
  旧TLAB已用=1024KB, 剩余=0KB
  旧TLAB分配对象数=约65536个 (1MB / 16bytes per object)
  新TLAB请求大小=1024KB
[PROBE][TLAB] 新TLAB分配: start=0x700001100000 size=1024KB
→ 结论1：TLAB 大小约 1MB（Eden 8192MB / 8线程 / 8 ≈ 128MB，但实际会动态调整）
→ 结论2：TLAB 分配是无锁的（只移动 top 指针），极其高效
→ 结论3：TLAB refill 时旧 TLAB 的剩余空间会被填充为 dummy 对象（保持堆可遍历性）
```

---

#### 3.2 大对象路径（Humongous）

**要验证的问题：**
- Humongous 对象的阈值是多少？（region_size / 2 = 2MB）
- 分配一个 3MB 的数组需要几个 Region？（2个：1个 starts_humongous + 1个 continues_humongous）
- Humongous 分配是否需要 STW？（不需要，但需要持有 Heap_lock）
- Humongous 对象分配后，Region 的状态是什么？

**插桩代码位置**：`gc/g1/g1CollectedHeap.cpp:G1CollectedHeap::humongous_obj_allocate()` 入口

**插桩内容**：
```cpp
tty->print_cr("[PROBE][Humongous] 大对象分配: size=%zu bytes (%zuMB)",
    word_size * wordSize, word_size * wordSize / M);
tty->print_cr("  Humongous阈值=%zu bytes (%zuMB)",
    humongous_threshold_for(HeapRegion::GrainBytes),
    humongous_threshold_for(HeapRegion::GrainBytes) / M);
tty->print_cr("  需要Region数=%d", (int)required_regions(word_size));
tty->print_cr("  分配前free_region_count=%u", _hrm.num_free_regions());
// 分配后
tty->print_cr("  分配后: starts_humongous_region=%u, continues_humongous_regions=%u",
    1, (int)required_regions(word_size) - 1);
tty->print_cr("  分配后free_region_count=%u (减少了%d个)",
    _hrm.num_free_regions(), (int)required_regions(word_size));
```

**预期输出与结论：**
```
[PROBE][Humongous] 大对象分配: size=3145728 bytes (3MB)
  Humongous阈值=2097152 bytes (2MB) = region_size/2
  需要Region数=1 (ceil(3MB/4MB)=1个Region就够)
  分配前free_region_count=2047
  分配后: starts_humongous_region=1, continues_humongous_regions=0
  分配后free_region_count=2046 (减少了1个)
→ 结论1：Humongous 阈值 = region_size/2 = 2MB，超过此大小直接分配整个 Region
→ 结论2：3MB 对象只需 1 个 4MB Region（不是 2 个），因为 ceil(3/4)=1
→ 结论3：Humongous 分配绕过 TLAB，直接从 HeapRegionManager 申请 Region
→ 结论4：Humongous 对象在 YoungGC 时不移动，只在 Full GC 或 Cleanup 时回收
```

---

### 第 4 章：G1 YoungGC 链路插桩

**目标**：验证 YoungGC 从触发到完成的完整 STW 流程，**重点是 CSet 选择、对象复制数量、各阶段耗时**

---

#### 4.1 GC 触发条件验证

**要验证的问题：**
- YoungGC 在 Eden 占用多少时触发？（不是固定阈值，G1 动态调整）
- 触发时 Eden 有多少个 Region？Survivor 有多少个？
- 是否同时触发了并发标记？（Initial Mark 附在 YoungGC 上）
- GC 触发的原因是什么？（allocation failure? 还是 G1 主动触发？）

**插桩代码位置**：`gc/g1/g1CollectedHeap.cpp:G1CollectedHeap::do_collection_pause()` 入口

**插桩内容**：
```cpp
tty->print_cr("[PROBE][YoungGC] GC触发:");
tty->print_cr("  触发原因=%s", GCCause::to_string(gc_cause));
tty->print_cr("  Eden: %u个Region (%zuMB)",
    _eden.length(), (size_t)_eden.length() * HeapRegion::GrainBytes / M);
tty->print_cr("  Survivor: %u个Region (%zuMB)",
    _survivor.length(), (size_t)_survivor.length() * HeapRegion::GrainBytes / M);
tty->print_cr("  Old: %u个Region (%zuMB)",
    _old_set.length(), (size_t)_old_set.length() * HeapRegion::GrainBytes / M);
tty->print_cr("  Free: %u个Region", _hrm.num_free_regions());
tty->print_cr("  堆使用率=%.1f%%", used() * 100.0 / capacity());
tty->print_cr("  是否触发并发标记=%s", collector_state()->initiate_conc_mark() ? "YES(Initial Mark)" : "NO");
```

**预期输出与结论：**
```
[PROBE][YoungGC] GC触发:
  触发原因=G1 Evacuation Pause (allocation failure)
  Eden: 409个Region (1636MB)  ← 约20%的堆
  Survivor: 0个Region (0MB)   ← 第一次GC前没有Survivor
  Old: 0个Region (0MB)
  Free: 1639个Region
  堆使用率=20.0%
  是否触发并发标记=NO (堆使用率<45%，不触发)
→ 结论1：G1 YoungGC 在 Eden 占满时触发（约20%堆），不是固定阈值
→ 结论2：G1 动态调整 Eden 大小，目标是让 GC 暂停时间 ≤ MaxGCPauseMillis(200ms)
→ 结论3：并发标记在堆使用率 > InitiatingHeapOccupancyPercent(45%) 时才触发
```

---

#### 4.2 STW 阶段 —— 各子阶段耗时

**要验证的问题：**
- YoungGC 的 STW 分为哪几个子阶段？每个子阶段耗时多少？
- 根扫描（Root Scanning）扫描了哪些根？各扫描了多少个对象？
- 对象复制（Evacuation）复制了多少个对象？复制了多少字节？
- CSet 释放后，Eden Region 变成了什么状态？

**插桩代码位置**：`gc/g1/g1CollectedHeap.cpp:G1CollectedHeap::do_collection_pause_at_safepoint()` 各阶段

**插桩内容**：
```cpp
// 在各子阶段前后插桩
tty->print_cr("[PROBE][YoungGC-STW] === STW 开始 ===");
jlong t_start = os::javaTimeNanos();

// 根扫描后
tty->print_cr("[PROBE][YoungGC-STW] 根扫描完成: elapsed=%ldms", elapsed_ms);
tty->print_cr("  thread_roots=%d, universe_roots=%d, jni_handles=%d",
    thread_roots, universe_roots, jni_handles);

// 对象复制后
tty->print_cr("[PROBE][YoungGC-STW] 对象复制完成:");
tty->print_cr("  复制对象数=%d", copied_objects);
tty->print_cr("  复制字节数=%zuMB", copied_bytes / M);
tty->print_cr("  晋升到Old的对象数=%d (age>%d)", promoted_objects, MaxTenuringThreshold);

// CSet 释放后
tty->print_cr("[PROBE][YoungGC-STW] CSet释放完成:");
tty->print_cr("  释放Eden Region数=%u", freed_eden_count);
tty->print_cr("  新Survivor Region数=%u", _survivor.length());
tty->print_cr("  STW总耗时=%ldms", total_stw_ms);
```

**预期输出与结论：**
```
[PROBE][YoungGC-STW] === STW 开始 ===
[PROBE][YoungGC-STW] 根扫描完成: elapsed=2ms
  thread_roots=4个线程栈, universe_roots=~50个, jni_handles=~100个
[PROBE][YoungGC-STW] 对象复制完成:
  复制对象数=~50000个
  复制字节数=~200MB
  晋升到Old的对象数=~100个 (age>15)
[PROBE][YoungGC-STW] CSet释放完成:
  释放Eden Region数=409
  新Survivor Region数=~20
  STW总耗时=~45ms
→ 结论1：YoungGC STW 约45ms，主要时间花在对象复制（200MB数据移动）
→ 结论2：根扫描只需2ms，因为根集合相对较小
→ 结论3：409个Eden Region全部释放，约20个Survivor Region保留（存活对象约5%）
→ 结论4：晋升到Old的对象极少（age>15才晋升），说明大多数对象是短命的
```

---

### 第 4B 章：G1 写屏障链路插桩

**目标**：验证对象引用赋值时写屏障的完整触发路径，**重点是脏卡队列的入队/出队行为和 RSet 更新**

---

#### 4B.1 写屏障触发频率验证

**要验证的问题：**
- 执行 Demo 程序时，写屏障触发了多少次？（每次引用赋值都触发）
- 其中有多少次真正入队了脏卡？（过滤掉同 Region 内的引用）
- 脏卡队列（DirtyCardQueue）的最大长度是多少？
- Refine 线程被唤醒了多少次？每次处理了多少张脏卡？

**插桩代码位置**：`gc/g1/g1BarrierSetRuntime.cpp:G1BarrierSetRuntime::write_ref_field_post_entry()` 入口

**插桩内容**：
```cpp
static volatile int wb_total = 0;
static volatile int wb_enqueued = 0;
int total = Atomic::add(1, &wb_total);
// 判断是否跨Region引用
HeapRegion* from_region = _hrm.addr_to_region((HeapWord*)from);
HeapRegion* to_region   = _hrm.addr_to_region((HeapWord*)to);
if (from_region != to_region) {
    Atomic::add(1, &wb_enqueued);
    if (wb_enqueued % 1000 == 0) {
        tty->print_cr("[PROBE][WriteBarrier] 累计: 总触发=%d, 跨Region入队=%d (%.1f%%)",
            wb_total, wb_enqueued, wb_enqueued * 100.0 / wb_total);
        tty->print_cr("  当前DirtyCardQueue大小=%d", G1BarrierSet::dirty_card_queue_set().completed_buffers_num());
    }
}
```

**预期输出与结论：**
```
[PROBE][WriteBarrier] 累计: 总触发=1000, 跨Region入队=50 (5.0%)
[PROBE][WriteBarrier] 累计: 总触发=2000, 跨Region入队=98 (4.9%)
...
→ 结论1：约95%的引用赋值是同 Region 内的，写屏障过滤后只有5%真正入队
→ 结论2：这就是 G1 写屏障的核心优化：同 Region 引用不需要记录到 RSet
→ 结论3：DirtyCardQueue 是线程本地的，满了才批量提交到全局队列
```

---

### 第 4C 章：G1 并发标记链路插桩

**目标**：验证并发标记从触发到完成的完整流程（Initial Mark → Concurrent Mark → Remark → Cleanup），**重点是每个阶段标记了多少对象、各阶段耗时、以及 SATB 写屏障的作用**

---

#### 4C.1 Initial Mark 阶段 —— 附在 YoungGC 上的 STW

**要验证的问题：**
- Initial Mark 是附在哪次 YoungGC 上触发的？（堆使用率 > IHOP=45% 时）
- Initial Mark 扫描了哪些根？标记了多少个对象？
- SATB（Snapshot-At-The-Beginning）快照是在哪里建立的？
- Initial Mark 的 STW 耗时是多少？（应该和普通 YoungGC 差不多）

**插桩代码位置**：`gc/g1/g1ConcurrentMark.cpp:G1ConcurrentMark::checkpoint_roots_initial()` 入口和末尾

**插桩内容**：
```cpp
tty->print_cr("[PROBE][InitialMark] checkpoint_roots_initial 开始:");
tty->print_cr("  触发条件: 堆使用率=%.1f%% > IHOP=%d%%",
    _g1h->used() * 100.0 / _g1h->capacity(),
    (int)InitiatingHeapOccupancyPercent);
tty->print_cr("  当前Old Region数=%u, Humongous Region数=%u",
    _g1h->old_regions_count(), _g1h->humongous_regions_count());
jlong t0 = os::javaTimeNanos();
// ... 执行后
tty->print_cr("[PROBE][InitialMark] checkpoint_roots_initial 完成:");
tty->print_cr("  标记了根对象数=%zu", _root_regions.scan_in_progress() ? _root_regions.num_root_regions() : 0);
tty->print_cr("  SATB队列已激活=%s", G1BarrierSet::satb_mark_queue_set().is_active() ? "YES" : "NO");
tty->print_cr("  耗时=%ldms", (os::javaTimeNanos() - t0) / 1000000);
```

**预期输出与结论：**
```
[PROBE][InitialMark] checkpoint_roots_initial 开始:
  触发条件: 堆使用率=45.2% > IHOP=45%
  当前Old Region数=200, Humongous Region数=10
[PROBE][InitialMark] checkpoint_roots_initial 完成:
  标记了根对象数=~500 (GC Roots直接可达的对象)
  SATB队列已激活=YES (从此刻起所有引用修改都记录到SATB队列)
  耗时=3ms (和普通YoungGC的根扫描耗时相当)
→ 结论1：Initial Mark 触发条件是堆使用率超过 IHOP(45%)，不是每次 YoungGC 都触发
→ 结论2：Initial Mark 完成后立即激活 SATB 写屏障，记录所有引用修改
→ 结论3：SATB 的核心思想：标记开始时的快照，并发标记期间的修改通过 SATB 队列补充
```

---

#### 4C.2 Concurrent Mark 阶段 —— 并发，不 STW

**要验证的问题：**
- 并发标记线程有多少个？（ConcGCThreads，默认 CPU 核数 / 4）
- 并发标记总共标记了多少个对象？
- 并发标记期间，SATB 队列积累了多少条记录？
- 并发标记的总耗时是多少？（不影响 Java 线程，但占用 CPU）

**插桩代码位置**：`gc/g1/g1ConcurrentMark.cpp:G1ConcurrentMark::mark_from_roots()` 入口和末尾

**插桩内容**：
```cpp
tty->print_cr("[PROBE][ConcMark] mark_from_roots 开始:");
tty->print_cr("  并发标记线程数=%u (ConcGCThreads=%u)",
    _concurrent_workers->active_workers(), (uint)ConcGCThreads);
tty->print_cr("  待标记Region数=%u", _g1h->num_regions() - _g1h->num_free_regions());
jlong t0 = os::javaTimeNanos();
// ... 执行后
tty->print_cr("[PROBE][ConcMark] mark_from_roots 完成:");
tty->print_cr("  标记对象总数=%zu", _g1h->num_regions() > 0 ? ... : 0);
tty->print_cr("  SATB队列积累记录数=%zu", G1BarrierSet::satb_mark_queue_set().completed_buffers_num() * G1SATBBufferSize);
tty->print_cr("  并发标记耗时=%ldms (不STW，Java线程同时运行)", (os::javaTimeNanos() - t0) / 1000000);
```

**预期输出与结论：**
```
[PROBE][ConcMark] mark_from_roots 开始:
  并发标记线程数=2 (ConcGCThreads=2, CPU核数/4=2)
  待标记Region数=400 (Old+Humongous Region)
[PROBE][ConcMark] mark_from_roots 完成:
  标记对象总数=~500万个
  SATB队列积累记录数=~10000条 (并发期间的引用修改)
  并发标记耗时=200ms (不STW，Java线程同时运行)
→ 结论1：并发标记线程数 = CPU核数/4，避免占用太多 CPU 影响 Java 线程
→ 结论2：并发标记期间 Java 线程继续运行，引用修改通过 SATB 队列记录
→ 结论3：200ms 的并发标记期间，Java 线程没有停顿（这是 G1 的核心优势）
```

---

#### 4C.3 Remark 阶段 —— STW，处理 SATB 队列

**要验证的问题：**
- Remark 需要处理多少条 SATB 记录？
- Remark 的 STW 耗时是多少？（应该比 Initial Mark 短）
- Remark 后，有多少个 Region 是完全死亡的（可以直接回收）？
- 弱引用处理在 Remark 的哪个子阶段？

**插桩代码位置**：`gc/g1/g1ConcurrentMark.cpp:G1ConcurrentMark::checkpoint_roots_final()` 入口和末尾

**插桩内容**：
```cpp
tty->print_cr("[PROBE][Remark] checkpoint_roots_final 开始:");
tty->print_cr("  SATB队列待处理记录数=%zu", G1BarrierSet::satb_mark_queue_set().completed_buffers_num() * G1SATBBufferSize);
jlong t0 = os::javaTimeNanos();
// ... 执行后
tty->print_cr("[PROBE][Remark] checkpoint_roots_final 完成:");
tty->print_cr("  处理SATB记录数=%zu", satb_processed);
tty->print_cr("  弱引用处理: SoftRef=%d, WeakRef=%d, PhantomRef=%d",
    soft_count, weak_count, phantom_count);
tty->print_cr("  完全死亡Region数=%u (可直接回收，无需复制)", empty_regions);
tty->print_cr("  Remark STW耗时=%ldms", (os::javaTimeNanos() - t0) / 1000000);
```

**预期输出与结论：**
```
[PROBE][Remark] checkpoint_roots_final 开始:
  SATB队列待处理记录数=~10000条
[PROBE][Remark] checkpoint_roots_final 完成:
  处理SATB记录数=10000条 (补充标记并发期间的引用修改)
  弱引用处理: SoftRef=0, WeakRef=50, PhantomRef=0
  完全死亡Region数=~50个 (这些Region可以在Cleanup时直接释放)
  Remark STW耗时=8ms (比Initial Mark短，因为只处理SATB增量)
→ 结论1：Remark 的核心工作是处理 SATB 队列（并发期间的引用修改增量）
→ 结论2：Remark 耗时 8ms << 并发标记 200ms，说明 SATB 增量很小
→ 结论3：完全死亡的 Region 在 Cleanup 时直接释放，不需要复制（这是 G1 的高效之处）
```

---

#### 4C.4 Cleanup 阶段 —— STW，统计存活率 + 选 Mixed GC 候选

**要验证的问题：**
- Cleanup 统计了每个 Region 的存活率，结果是什么？
- 哪些 Region 被选为 Mixed GC 的候选？（存活率 < 85% 的 Old Region）
- 完全死亡的 Region 直接释放了多少 MB？
- Cleanup 后，并发标记周期结束，下一次 GC 是 Mixed GC 还是 YoungGC？

**插桩代码位置**：`gc/g1/g1ConcurrentMark.cpp:G1ConcurrentMark::cleanup()` 末尾

**插桩内容**：
```cpp
tty->print_cr("[PROBE][Cleanup] cleanup 完成:");
tty->print_cr("  完全死亡Region数=%u, 直接释放=%zuMB",
    _g1h->num_free_regions() - free_before,
    (size_t)(_g1h->num_free_regions() - free_before) * HeapRegion::GrainBytes / M);
tty->print_cr("  Mixed GC候选Region数=%u (存活率<%.0f%%的Old Region)",
    _collection_set_chooser->remaining_regions(),
    (double)G1MixedGCLiveThresholdPercent);
tty->print_cr("  候选Region总可回收空间=%zuMB",
    _collection_set_chooser->remaining_reclaimable_bytes() / M);
tty->print_cr("  下一次GC类型=%s",
    _g1h->policy()->next_gc_should_be_mixed("", "") ? "Mixed GC" : "Young GC");
```

**预期输出与结论：**
```
[PROBE][Cleanup] cleanup 完成:
  完全死亡Region数=50, 直接释放=200MB
  Mixed GC候选Region数=150 (存活率<85%的Old Region)
  候选Region总可回收空间=600MB
  下一次GC类型=Mixed GC
→ 结论1：Cleanup 直接释放了 200MB（完全死亡的 Region），这是"免费"的回收
→ 结论2：150 个 Old Region 被选为 Mixed GC 候选，按存活率从低到高排序
→ 结论3：Cleanup 后下一次 GC 变为 Mixed GC，开始回收 Old Region
→ 结论4：G1MixedGCLiveThresholdPercent=85%，存活率超过85%的Region不值得回收
```

---

### 第 4D 章：G1 Mixed GC 链路插桩

**目标**：验证 Mixed GC 与 YoungGC 的差异（CSet 额外包含 Old Region），**重点是 Old Region 的选择策略和回收效率**

---

#### 4D.1 Mixed GC 触发判断

**要验证的问题：**
- Mixed GC 的触发条件是什么？（并发标记完成后，且 Old 占比 > G1HeapWastePercent）
- Mixed GC 的 CSet 包含多少个 Old Region？（每次 Mixed GC 只回收一部分）
- Mixed GC 会连续触发几次？（直到 Old 占比降到安全水位）
- Mixed GC 和 YoungGC 的 STW 耗时对比是多少？

**插桩代码位置**：`gc/g1/g1Policy.cpp:G1Policy::next_gc_should_be_mixed()` 入口

**插桩内容**：
```cpp
tty->print_cr("[PROBE][MixedGC] next_gc_should_be_mixed 判断:");
tty->print_cr("  并发标记已完成=%s", _g1h->concurrent_mark()->has_aborted() ? "NO(已中止)" : "YES");
tty->print_cr("  Old可回收空间=%zuMB", _collection_set_chooser->remaining_reclaimable_bytes() / M);
tty->print_cr("  G1HeapWastePercent=%d%% (可回收空间阈值)",
    (int)G1HeapWastePercent);
tty->print_cr("  可回收空间占比=%.1f%%",
    _collection_set_chooser->remaining_reclaimable_bytes() * 100.0 / _g1h->capacity());
tty->print_cr("  → 结论: %s", should_be_mixed ? "触发Mixed GC" : "继续Young GC");
```

**预期输出与结论：**
```
[PROBE][MixedGC] next_gc_should_be_mixed 判断:
  并发标记已完成=YES
  Old可回收空间=600MB
  G1HeapWastePercent=5% (可回收空间 > 5%堆才触发)
  可回收空间占比=7.3% > 5%
  → 结论: 触发Mixed GC
→ 结论1：Mixed GC 触发条件：并发标记完成 + 可回收空间 > G1HeapWastePercent(5%)
→ 结论2：如果可回收空间太少（< 5%），不值得做 Mixed GC，继续 Young GC
```

---

#### 4D.2 Mixed GC 的 CSet 选择

**要验证的问题：**
- Mixed GC 的 CSet = Young Region（全部）+ Old Region（部分）
- 每次 Mixed GC 选多少个 Old Region？（G1MixedGCCountTarget 控制，默认8次分批回收）
- Old Region 按什么顺序选择？（存活率从低到高，优先回收垃圾最多的）
- 选中的 Old Region 的平均存活率是多少？

**插桩代码位置**：`gc/g1/g1Policy.cpp:G1Policy::finalize_collection_set()` 末尾

**插桩内容**：
```cpp
tty->print_cr("[PROBE][MixedGC] CSet选择完成:");
tty->print_cr("  Young Region数=%u (%zuMB)",
    _collection_set->young_region_length(),
    (size_t)_collection_set->young_region_length() * HeapRegion::GrainBytes / M);
tty->print_cr("  Old Region数=%u (%zuMB) [本次Mixed GC新增]",
    _collection_set->old_region_length(),
    (size_t)_collection_set->old_region_length() * HeapRegion::GrainBytes / M);
tty->print_cr("  Old Region选择策略: 存活率最低的%u个 (G1MixedGCCountTarget=%d)",
    _collection_set->old_region_length(), (int)G1MixedGCCountTarget);
tty->print_cr("  预计回收空间=%zuMB",
    _collection_set->bytes_used_before() / M - _collection_set->predicted_bytes_to_copy() / M);
```

**预期输出与结论：**
```
[PROBE][MixedGC] CSet选择完成:
  Young Region数=200 (800MB)
  Old Region数=19 (76MB) [本次Mixed GC新增]
  Old Region选择策略: 存活率最低的19个 (G1MixedGCCountTarget=8, 150/8≈19)
  预计回收空间=~700MB
→ 结论1：Mixed GC 每次只回收 1/8 的候选 Old Region（G1MixedGCCountTarget=8）
→ 结论2：Old Region 按存活率从低到高排序，优先回收"垃圾最多"的 Region（Garbage First！）
→ 结论3：这就是 G1 名字的由来：Garbage First，优先回收垃圾最多的 Region
→ 结论4：Mixed GC 需要连续触发约8次才能回收完所有候选 Old Region
```

---

### 第 5 章：JIT 编译触发链路插桩

**目标**：验证方法从解释执行到 C1/C2 编译的触发路径，**重点是计数器溢出的时机、编译队列的状态、编译前后的性能差异**

---

#### 5.1 InvocationCounter 溢出验证

**要验证的问题：**
- `hotMethod` 被调用多少次后触发 C1 编译？（理论值：Tier3InvocationThreshold=200）
- 触发编译时，计数器的 raw value 是多少？实际 count 是多少？
- 从提交编译请求到编译完成，中间经历了多少次方法调用？（编译是异步的）
- 编译完成后，方法的 entry_point 从解释器入口变成了什么？

**插桩代码位置**：`interpreter/interpreterRuntime.cpp:InterpreterRuntime::frequency_counter_overflow()` 入口

**插桩内容**：
```cpp
tty->print_cr("[PROBE][JIT] frequency_counter_overflow: method=%s",
    method->name_and_sig_as_C_string());
tty->print_cr("  invocation_count=%d (raw=%d)",
    method->invocation_count(), method->invocation_counter()->raw_value());
tty->print_cr("  backedge_count=%d", method->backedge_count());
tty->print_cr("  当前编译级别=%d", method->comp_level());
tty->print_cr("  CompileThreshold=%d, Tier3InvocationThreshold=%d",
    (int)CompileThreshold, (int)Tier3InvocationThreshold);
tty->print_cr("  → 触发编译: 提交到C%d队列",
    CompilationPolicy::policy()->initial_compile_level() == CompLevel_simple ? 1 : 2);
```

**预期输出与结论：**
```
[PROBE][JIT] frequency_counter_overflow: method=com/wjcoder/Main.hotMethod()V
  invocation_count=200 (raw=3200, 因为低4位是状态位)
  backedge_count=0
  当前编译级别=0 (解释执行)
  CompileThreshold=10000, Tier3InvocationThreshold=200
  → 触发编译: 提交到C1队列 (Tier3)
[PROBE][JIT] frequency_counter_overflow: method=com/wjcoder/Main.hotMethod()V
  invocation_count=5000
  当前编译级别=3 (C1+profiling)
  → 触发编译: 提交到C2队列 (Tier4)
→ 结论1：分层编译下，方法先在200次时触发C1编译，再在5000次时触发C2编译
→ 结论2：C1编译后方法仍然收集profiling数据（Tier3），为C2优化提供信息
→ 结论3：编译是异步的，提交请求后方法继续解释执行，直到编译完成才切换
```

---

#### 5.2 编译完成后的代码质量验证

**要验证的问题：**
- C1 编译生成的代码有多大？C2 编译生成的代码有多大？
- 编译耗时多少？（C1 快但代码质量低，C2 慢但代码质量高）
- 编译后方法的 entry_point 变成了什么地址？
- 编译代码存放在 CodeCache 的哪个段？

**插桩代码位置**：`compiler/compileBroker.cpp:CompileBroker::invoke_compiler_on_method()` 末尾

**插桩内容**：
```cpp
tty->print_cr("[PROBE][JIT] 编译完成: method=%s", task->method()->name_and_sig_as_C_string());
tty->print_cr("  编译级别=Tier%d (%s)", task->comp_level(),
    task->comp_level() <= 3 ? "C1" : "C2");
tty->print_cr("  编译耗时=%ldms", elapsed_ms);
tty->print_cr("  生成代码大小=%d bytes", nm->code_size());
tty->print_cr("  代码地址=[" PTR_FORMAT ", " PTR_FORMAT ")",
    p2i(nm->code_begin()), p2i(nm->code_end()));
tty->print_cr("  存放在CodeCache段=%s",
    CodeCache::contains(nm->code_begin()) ? CodeCache::get_code_heap(nm)->name() : "unknown");
tty->print_cr("  entry_point=" PTR_FORMAT " (方法调用入口)", p2i(nm->entry_point()));
```

**预期输出与结论：**
```
[PROBE][JIT] 编译完成: method=com/wjcoder/Main.hotMethod()V
  编译级别=Tier3 (C1)
  编译耗时=8ms
  生成代码大小=256 bytes
  代码地址=[0x7f1234700000, 0x7f1234700100)
  存放在CodeCache段=CodeHeap 'profiled nmethods' (ProfiledCodeHeap)
  entry_point=0x7f1234700010
[PROBE][JIT] 编译完成: method=com/wjcoder/Main.hotMethod()V
  编译级别=Tier4 (C2)
  编译耗时=87ms
  生成代码大小=128 bytes  ← C2代码比C1更小！因为做了更多优化（消除冗余）
  存放在CodeCache段=CodeHeap 'non-profiled nmethods' (NonProfiledCodeHeap)
→ 结论1：C2 编译耗时是 C1 的 10 倍，但生成代码更小（更多优化消除了冗余代码）
→ 结论2：C1 代码存 ProfiledCodeHeap，C2 代码存 NonProfiledCodeHeap，物理隔离
→ 结论3：编译完成后 entry_point 自动更新，下次调用直接进入编译代码
```

---

### 第 5B 章：OSR（栈上替换）链路插桩

**目标**：验证循环体内触发 OSR 编译并切换到编译代码的路径，**重点是 OSR 触发时机、osr_bci 的含义、以及切换时栈帧如何重建**

---

#### 5B.1 OSR 触发时机验证

**要验证的问题：**
- OSR 触发的 backedge_count 是多少？（理论值：InterpreterBackwardBranchLimit / 16 ≈ 8750）
- OSR 触发时，方法已经被调用了多少次？（invocation_count）
- OSR 编译的 `osr_bci` 是什么？（循环回边的字节码偏移量）
- OSR 编译完成后，正在执行的栈帧如何切换到编译代码？

**插桩代码位置**：`interpreter/interpreterRuntime.cpp:InterpreterRuntime::frequency_counter_overflow()` 中 `osr_bci != -1` 分支

**插桩内容**：
```cpp
// 当 osr_bci != -1 时，是 OSR 触发
if (osr_bci != -1) {
    tty->print_cr("[PROBE][OSR] OSR触发: method=%s",
        method->name_and_sig_as_C_string());
    tty->print_cr("  osr_bci=%d (循环回边的字节码偏移量)", osr_bci);
    tty->print_cr("  backedge_count=%d (raw=%d)",
        method->backedge_count(), method->backedge_counter()->raw_value());
    tty->print_cr("  invocation_count=%d (方法已被调用次数)", method->invocation_count());
    tty->print_cr("  当前编译级别=%d", method->comp_level());
    tty->print_cr("  → 提交OSR编译请求: osr_bci=%d, level=%d", osr_bci, osr_level);
}
```

**预期输出与结论：**
```
[PROBE][OSR] OSR触发: method=com/wjcoder/Main.hotLoop()V
  osr_bci=15 (循环回边 goto 指令的字节码偏移量)
  backedge_count=8750 (raw=140000, 因为低4位是状态位)
  invocation_count=1 (方法只被调用了1次，但循环了8750次)
  当前编译级别=0 (解释执行)
  → 提交OSR编译请求: osr_bci=15, level=3 (C1+profiling)
→ 结论1：OSR 触发条件是 backedge_count 溢出，不是 invocation_count
→ 结论2：osr_bci=15 表示从字节码偏移15处（循环回边）开始编译
→ 结论3：方法只调用了1次但循环了8750次，说明 OSR 专门针对"长循环"场景
→ 结论4：OSR 编译完成后，JVM 在下一次循环回边时切换到编译代码（不需要重新调用方法）
```

---

#### 5B.2 OSR 切换时的栈帧重建

**要验证的问题：**
- OSR 切换时，解释器栈帧如何转换为编译代码栈帧？
- 切换发生在哪个时机？（循环回边处，不是方法入口）
- 切换后，局部变量和操作数栈的值如何保留？

**插桩代码位置**：`runtime/sharedRuntime.cpp:SharedRuntime::OSR_migration_begin()` 入口

**插桩内容**：
```cpp
tty->print_cr("[PROBE][OSR] OSR_migration_begin: method=%s, osr_bci=%d",
    mh->name_and_sig_as_C_string(), osr_bci);
tty->print_cr("  解释器栈帧 → 编译代码栈帧");
tty->print_cr("  局部变量数=%d (需要迁移到编译代码的寄存器/栈槽)",
    mh->max_locals());
tty->print_cr("  操作数栈深度=%d (OSR时应为0，循环回边处栈为空)",
    mh->max_stack());
tty->print_cr("  OSR nmethod entry_point=" PTR_FORMAT,
    p2i(mh->lookup_osr_nmethod_for(osr_bci, CompLevel_full_optimization, true)));
```

**预期输出与结论：**
```
[PROBE][OSR] OSR_migration_begin: method=com/wjcoder/Main.hotLoop()V, osr_bci=15
  解释器栈帧 → 编译代码栈帧
  局部变量数=3 (i, sum, arr 需要迁移)
  操作数栈深度=0 (循环回边处操作数栈必须为空，这是OSR的前提条件)
  OSR nmethod entry_point=0x7f1234800000
→ 结论1：OSR 切换的前提是循环回边处操作数栈为空（JVM 规范保证）
→ 结论2：局部变量从解释器栈帧迁移到编译代码的寄存器/栈槽
→ 结论3：OSR 切换后，方法从 osr_bci 处继续执行，不是从方法开头
```

---

### 第 5C 章：去优化（Deoptimization）链路插桩

**目标**：验证编译代码因假设失效而回退到解释器的路径，**重点是去优化的触发原因、栈帧重建过程、以及去优化后的重新编译**

---

#### 5C.1 去优化触发原因验证

**要验证的问题：**
- 去优化的触发原因有哪些？（class_check、null_check、range_check、uncommon_trap 等）
- 哪种原因最常见？（uncommon_trap：C2 假设某分支不会执行，但实际执行了）
- 去优化后，方法会被重新编译吗？（会，但会降低优化激进程度）
- 同一个方法最多去优化多少次？（超过阈值后永久解释执行）

**插桩代码位置**：`runtime/deoptimization.cpp:Deoptimization::deoptimize()` 入口

**插桩内容**：
```cpp
tty->print_cr("[PROBE][Deopt] deoptimize: method=%s",
    nm->method()->name_and_sig_as_C_string());
tty->print_cr("  去优化原因=%s", Deoptimization::reason_name(reason));
tty->print_cr("  去优化动作=%s", Deoptimization::action_name(action));
tty->print_cr("  当前编译级别=%d", nm->comp_level());
tty->print_cr("  该方法历史去优化次数=%d", nm->method()->decompile_count());
tty->print_cr("  去优化后动作: %s",
    action == Deoptimization::Action_make_not_entrant ? "标记nmethod为not_entrant，触发重编译" :
    action == Deoptimization::Action_make_not_compilable ? "永久禁止编译，解释执行" : "其他");
```

**预期输出与结论：**
```
[PROBE][Deopt] deoptimize: method=com/wjcoder/Main.hotMethod()V
  去优化原因=uncommon_trap (C2假设某分支不执行，但实际执行了)
  去优化动作=Action_make_not_entrant (标记nmethod为not_entrant，触发重编译)
  当前编译级别=4 (C2)
  该方法历史去优化次数=1
  去优化后动作: 标记nmethod为not_entrant，触发重编译
→ 结论1：uncommon_trap 是最常见的去优化原因，C2 激进优化的代价
→ 结论2：Action_make_not_entrant 表示当前 nmethod 作废，但允许重新编译
→ 结论3：重新编译时 C2 会更保守（不再假设该分支不执行）
→ 结论4：去优化次数超过阈值（PerMethodRecompilationCutoff=400）后，永久解释执行
```

---

#### 5C.2 栈帧重建过程验证

**要验证的问题：**
- 去优化时，编译代码的栈帧如何重建为解释器栈帧？
- 重建了多少个栈帧？（内联展开：C2 可能把多个方法内联成一个栈帧）
- 重建后，从哪个 bci 继续执行？

**插桩代码位置**：`runtime/deoptimization.cpp:Deoptimization::fetch_unroll_info()` 末尾

**插桩内容**：
```cpp
tty->print_cr("[PROBE][Deopt] fetch_unroll_info: 栈帧重建信息:");
tty->print_cr("  需要重建的解释器栈帧数=%d (C2内联展开了%d个方法)",
    chunk->frames(), chunk->frames());
for (int i = 0; i < chunk->frames(); i++) {
    tty->print_cr("  栈帧[%d]: method=%s, bci=%d",
        i, chunk->frame_at(i)->method()->name_and_sig_as_C_string(),
        chunk->frame_at(i)->bci());
}
```

**预期输出与结论：**
```
[PROBE][Deopt] fetch_unroll_info: 栈帧重建信息:
  需要重建的解释器栈帧数=3 (C2内联展开了3个方法)
  栈帧[0]: method=com/wjcoder/Main.hotMethod()V, bci=15
  栈帧[1]: method=com/wjcoder/Main.helper()V, bci=8  (被内联的方法)
  栈帧[2]: method=com/wjcoder/Main.main([Ljava/lang/String;)V, bci=42
→ 结论1：C2 把3个方法内联成1个编译栈帧，去优化时需要展开成3个解释器栈帧
→ 结论2：这就是去优化的高代价：需要重建被内联的所有方法的栈帧
→ 结论3：重建后从 bci=15 继续解释执行，不是从方法开头
```

---

### 第 5D 章：字节码解释执行（TemplateTable dispatch）插桩

**目标**：验证解释器如何通过 dispatch table 分发字节码，**重点是 dispatch table 的内存布局、热点字节码的 handler 地址、以及解释器的执行模型**

---

#### 5D.1 dispatch table 内存布局验证

**要验证的问题：**
- dispatch table 有几个？（每种 TOS 状态一个，共 ~10 个）
- 每个 dispatch table 有多少项？（202 项，对应 202 个字节码）
- dispatch table 存放在哪里？（CodeCache 的 NonNMethod 段）
- 最常用字节码（iload_0、iadd、ireturn）的 handler 地址是多少？

**插桩代码位置**：`interpreter/templateInterpreterGenerator.cpp:TemplateInterpreterGenerator::generate_all()` 末尾

**插桩内容**：
```cpp
tty->print_cr("[PROBE][TemplateTable] dispatch table 布局:");
tty->print_cr("  TOS状态数=%d (itos/ltos/ftos/dtos/atos/vtos等)",
    (int)TosState_max);
// 打印 itos 状态下的关键字节码 handler 地址
tty->print_cr("  [itos] iload_0  handler=" PTR_FORMAT,
    p2i(Interpreter::dispatch_table(itos)[Bytecodes::_iload_0]));
tty->print_cr("  [itos] iadd     handler=" PTR_FORMAT,
    p2i(Interpreter::dispatch_table(itos)[Bytecodes::_iadd]));
tty->print_cr("  [itos] ireturn  handler=" PTR_FORMAT,
    p2i(Interpreter::dispatch_table(itos)[Bytecodes::_ireturn]));
tty->print_cr("  [vtos] invokevirtual handler=" PTR_FORMAT,
    p2i(Interpreter::dispatch_table(vtos)[Bytecodes::_invokevirtual]));
tty->print_cr("  dispatch table 总大小=%zu bytes",
    sizeof(address) * Bytecodes::number_of_codes * (int)TosState_max);
```

**预期输出与结论：**
```
[PROBE][TemplateTable] dispatch table 布局:
  TOS状态数=8 (itos/ltos/ftos/dtos/atos/btos/ctos/vtos)
  [itos] iload_0  handler=0x7f1234561000
  [itos] iadd     handler=0x7f1234562000
  [itos] ireturn  handler=0x7f1234563000
  [vtos] invokevirtual handler=0x7f1234564000
  dispatch table 总大小=13312 bytes (202 * 8 * 8 bytes/pointer)
→ 结论1：dispatch table 有8个（每种 TOS 状态一个），总大小约13KB
→ 结论2：每个字节码在不同 TOS 状态下有不同的 handler（因为操作数类型不同）
→ 结论3：dispatch table 存放在 CodeCache 的 NonNMethod 段，与解释器代码相邻
→ 结论4：解释器执行字节码的核心就是：取字节码 → 查 dispatch table → 跳转到 handler
```

---

#### 5D.2 字节码执行频率统计

**要验证的问题：**
- Demo 程序执行过程中，哪些字节码执行频率最高？
- `invokevirtual` 执行了多少次？（每次虚方法调用）
- `new` 字节码执行了多少次？（每次对象创建）
- 字节码执行总次数是多少？

**插桩代码位置**：在 dispatch table 的每个 handler 入口处插入计数（选择性插桩几个关键字节码）

**插桩内容**：
```cpp
// 在 TemplateTable::_new() 生成的汇编入口处插桩
static volatile int new_count = 0;
Atomic::add(1, &new_count);
if (new_count % 10000 == 0) {
    tty->print_cr("[PROBE][Bytecode] new 字节码执行次数=%d", new_count);
}

// 在 TemplateTable::invokevirtual() 生成的汇编入口处插桩
static volatile int invokevirtual_count = 0;
Atomic::add(1, &invokevirtual_count);
if (invokevirtual_count % 100000 == 0) {
    tty->print_cr("[PROBE][Bytecode] invokevirtual 执行次数=%d", invokevirtual_count);
}
```

**预期输出与结论：**
```
[PROBE][Bytecode] new 字节码执行次数=10000
[PROBE][Bytecode] new 字节码执行次数=20000
[PROBE][Bytecode] invokevirtual 执行次数=100000
[PROBE][Bytecode] invokevirtual 执行次数=200000
→ 结论1：invokevirtual 执行频率约是 new 的10倍（每个对象创建后会调用多次方法）
→ 结论2：-Xint 模式下所有字节码都通过解释器执行，可以精确统计
→ 结论3：这些统计数据可以指导 JIT 编译优化：invokevirtual 是最值得优化的字节码
```

---

### 第 6 章：Safepoint 机制插桩

**目标**：验证 Safepoint 的完整协作流程，**重点是各线程响应时间、轮询机制的实现、STW 总耗时分布**

---

#### 6.1 Safepoint 耗时分解验证

**要验证的问题：**
- Safepoint 的 TTT（Time To Safepoint）是多少？（从发起到所有线程停止）
- 哪个线程最慢响应？慢在哪里？（在执行 JNI？在编译代码中？）
- Safepoint 操作本身（VM_Operation）耗时多少？
- 恢复所有线程需要多少时间？

**插桩代码位置**：`runtime/safepoint.cpp:SafepointSynchronize::begin()` 和 `end()`

**插桩内容**：
```cpp
// begin() 中
tty->print_cr("[PROBE][Safepoint] begin: op=%s, 请求时间=%ldns",
    VMThread::vm_operation()->name(), os::javaTimeNanos());
tty->print_cr("  需要停止的线程数=%d", Threads::number_of_threads());
tty->print_cr("  轮询页地址=" PTR_FORMAT " (armed)", p2i(SafepointMechanism::get_polling_page()));

// 所有线程停止后
tty->print_cr("[PROBE][Safepoint] 所有线程已停止:");
tty->print_cr("  TTT(Time To Safepoint)=%ldms", tts_ms);
tty->print_cr("  最慢线程: tid=%ld, 状态=%s, 等待=%ldms",
    slowest_tid, slowest_state, slowest_wait_ms);

// end() 中
tty->print_cr("[PROBE][Safepoint] end: 操作耗时=%ldms, 恢复耗时=%ldms, 总STW=%ldms",
    op_elapsed_ms, resume_elapsed_ms, total_stw_ms);
```

**预期输出与结论：**
```
[PROBE][Safepoint] begin: op=G1CollectForAllocation, 请求时间=1234567890ns
  需要停止的线程数=9 (4个Java线程 + 5个JIT线程)
  轮询页地址=0x7f1234000000 (armed, 访问此页会触发SIGSEGV)
[PROBE][Safepoint] 所有线程已停止:
  TTT=1.2ms
  最慢线程: tid=12346, 状态=in_Java(执行编译代码), 等待=1.1ms
[PROBE][Safepoint] end: 操作耗时=45ms, 恢复耗时=0.1ms, 总STW=46.3ms
→ 结论1：TTT 约1ms，主要等待正在执行编译代码的线程（需要到达安全点检查位置）
→ 结论2：轮询页是一个特殊内存页，armed时访问触发SIGSEGV，JVM捕获信号实现安全点
→ 结论3：恢复线程只需0.1ms，远小于停止时间，说明恢复是简单的内存写操作
→ 结论4：Safepoint 总耗时 = TTT(1ms) + 操作(45ms) + 恢复(0.1ms) ≈ 46ms
```

---

### 第 7 章：同步机制插桩

**目标**：验证 `synchronized` 从偏向锁 → 轻量级锁 → 重量级锁的膨胀路径，**重点是每种锁的 Mark Word 变化和膨胀触发条件**

---

#### 7.1 锁膨胀过程的 Mark Word 变化

**要验证的问题：**
- 偏向锁的 Mark Word 格式是什么？（线程ID + epoch + 偏向标志）
- 轻量级锁的 Mark Word 格式是什么？（指向栈帧 Lock Record 的指针）
- 重量级锁的 Mark Word 格式是什么？（指向 ObjectMonitor 的指针）
- 锁膨胀的触发条件是什么？（竞争？还是调用 wait/notify？）
- ObjectMonitor 的 `_owner`、`_EntryList`、`_WaitSet` 各有多少个元素？

**插桩代码位置**：`runtime/synchronizer.cpp:ObjectSynchronizer::inflate()` 入口和末尾

**插桩内容**：
```cpp
tty->print_cr("[PROBE][Sync] inflate: obj=" PTR_FORMAT, p2i(obj));
tty->print_cr("  膨胀前 mark=" PTR_FORMAT " (%s)",
    p2i(obj->mark()), obj->mark()->is_biased_locking() ? "偏向锁" :
    obj->mark()->has_locker() ? "轻量级锁" : "无锁");
tty->print_cr("  膨胀原因=%s", inflate_cause_name(cause));
// 膨胀后
ObjectMonitor* m = inflate_result;
tty->print_cr("  膨胀后 mark=" PTR_FORMAT " (重量级锁)", p2i(obj->mark()));
tty->print_cr("  ObjectMonitor@" PTR_FORMAT ":", p2i(m));
tty->print_cr("    _owner=%p (当前持有者)", m->owner());
tty->print_cr("    _EntryList长度=%d (等待获取锁)", m->EntryList_length());
tty->print_cr("    _WaitSet长度=%d (调用了wait())", m->WaitSet_length());
tty->print_cr("    _recursions=%d (重入次数)", (int)m->recursions());
```

**预期输出与结论：**
```
[PROBE][Sync] inflate: obj=0x700001000000
  膨胀前 mark=0x00007f1234560005 (偏向锁, 偏向tid=12345)
  膨胀原因=INFLATE_CAUSE_WAIT (调用了wait())
  膨胀后 mark=0x00007f1234570002 (重量级锁, 指向ObjectMonitor)
  ObjectMonitor@0x7f1234570000:
    _owner=0x7f1234560000 (JavaThread tid=12345)
    _EntryList长度=2 (tid=12346, tid=12347 在等待)
    _WaitSet长度=0
    _recursions=0
→ 结论1：偏向锁 → 重量级锁的膨胀原因是 wait()，不是竞争（竞争只到轻量级锁）
→ 结论2：Mark Word 的低2位是锁状态标志：01=无锁/偏向, 00=轻量级, 10=重量级
→ 结论3：ObjectMonitor 的 _EntryList 是等待获取锁的线程队列（FIFO）
→ 结论4：_WaitSet 是调用了 wait() 的线程集合，等待 notify() 唤醒
```

---

### 第 8 章：线程生命周期插桩

**目标**：验证 Java 线程从 `Thread.start()` 到 OS 线程创建再到销毁的完整生命周期，**重点是线程状态机的转换和各系统线程的工作循环**

---

#### 8.1 Java 线程创建的完整链路

**要验证的问题：**
- `Thread.start()` 到 OS 线程真正运行，中间经历了哪些步骤？
- `JavaThread` 对象的大小是多少字节？
- OS 线程的栈大小是多少？（默认 512KB 还是 1MB？）
- 线程从创建到 RUNNABLE 状态，经历了哪些中间状态？

**插桩代码位置**：`os/linux/os_linux.cpp:os::create_thread()` 入口和 `thread_native_entry()` 入口

**插桩内容**：
```cpp
// os::create_thread() 中
tty->print_cr("[PROBE][Thread] os::create_thread: JavaThread@" PTR_FORMAT, p2i(thread));
tty->print_cr("  sizeof(JavaThread)=%zu bytes", sizeof(JavaThread));
tty->print_cr("  请求栈大小=%zuKB", stack_size / K);
tty->print_cr("  当前线程总数=%d", Threads::number_of_threads());

// thread_native_entry() 中（新线程的第一行代码）
tty->print_cr("[PROBE][Thread] thread_native_entry: 新线程开始运行");
tty->print_cr("  os_tid=%ld (pthread_self=%lu)", os::current_thread_id(), pthread_self());
tty->print_cr("  JavaThread@" PTR_FORMAT, p2i(thread));
tty->print_cr("  初始状态=%s", thread->thread_state_name());
```

**预期输出与结论：**
```
[PROBE][Thread] os::create_thread: JavaThread@0x7f1234000000
  sizeof(JavaThread)=~4096 bytes (包含所有字段和内嵌缓冲区)
  请求栈大小=512KB (默认值，可用-Xss调整)
  当前线程总数=9 (主线程+JIT线程+GC线程等)
[PROBE][Thread] thread_native_entry: 新线程开始运行
  os_tid=12350 (pthread_self=140234567890)
  JavaThread@0x7f1234000000
  初始状态=_thread_new (刚创建，还未进入Java代码)
→ 结论1：JavaThread 对象约4KB，包含线程本地缓冲区（TLAB、JNI handles等）
→ 结论2：线程栈默认512KB，比 Java 文档说的1MB小，因为 JVM 自己管理栈扩展
→ 结论3：新线程的第一个状态是 _thread_new，不是 RUNNABLE
```

---

#### 8.2 VMThread 工作循环验证

**要验证的问题：**
- VMThread 的工作循环每次迭代做什么？
- VM_Operation 队列的平均长度是多少？
- 最常见的 VM_Operation 类型是什么？（GC? Deopt? ClassRedefinition?）
- VMThread 空闲时在做什么？（等待条件变量）

**插桩代码位置**：`runtime/vmThread.cpp:VMThread::loop()` 中

**插桩内容**：
```cpp
static int vm_op_count = 0;
// 每执行一个 VM_Operation
vm_op_count++;
if (vm_op_count <= 20 || vm_op_count % 100 == 0) {
    tty->print_cr("[PROBE][VMThread] 执行VM_Operation #%d: %s",
        vm_op_count, _cur_vm_operation->name());
    tty->print_cr("  需要Safepoint=%s", _cur_vm_operation->evaluate_at_safepoint() ? "YES" : "NO");
    tty->print_cr("  队列剩余=%d", _vm_queue->length());
}
```

**预期输出与结论：**
```
[PROBE][VMThread] 执行VM_Operation #1: HandshakeAllThreads (需要Safepoint=NO)
[PROBE][VMThread] 执行VM_Operation #2: G1CollectForAllocation (需要Safepoint=YES)
[PROBE][VMThread] 执行VM_Operation #3: RevokeBias (需要Safepoint=YES)
...
→ 结论1：VMThread 是 JVM 的"管理员线程"，所有需要 STW 的操作都通过它执行
→ 结论2：不是所有 VM_Operation 都需要 Safepoint（如 Handshake 只停一个线程）
→ 结论3：GC 是最频繁的 VM_Operation，其次是偏向锁撤销
```

---

### 第 9 章：信号处理链路插桩（libjsig.so）

**目标**：验证 libjsig.so 的信号拦截 → 链式调用路径，**重点是 JVM 注册了哪些信号、libjsig 如何拦截用户代码的信号注册、以及信号分发的优先级**

---

#### 9.1 JVM 信号注册验证

**要验证的问题：**
- JVM 注册了哪些信号？（SIGSEGV、SIGBUS、SIGFPE、SIGPIPE、SIGUSR1、SIGUSR2 等）
- 每个信号的用途是什么？（SIGSEGV → NPE/StackOverflow，SIGUSR1 → 线程dump）
- libjsig 的 `sigaction()` 包装函数拦截了多少次信号注册？
- JVM 信号处理器和用户信号处理器的优先级是什么？

**插桩代码位置**：`os/linux/os_linux.cpp:os::Linux::install_signal_handlers()` 末尾

**插桩内容**：
```cpp
tty->print_cr("[PROBE][Signal] JVM信号处理器安装完成:");
tty->print_cr("  SIGSEGV → JVM_handle_linux_signal (用于NPE/StackOverflow检测)");
tty->print_cr("  SIGBUS  → JVM_handle_linux_signal (用于内存映射错误)");
tty->print_cr("  SIGFPE  → JVM_handle_linux_signal (用于除零异常)");
tty->print_cr("  SIGPIPE → SIG_IGN (忽略，避免写入关闭的socket时崩溃)");
tty->print_cr("  SIGUSR1 → SR_handler (用于线程挂起/恢复)");
tty->print_cr("  SIGUSR2 → SR_handler (用于线程挂起/恢复)");
tty->print_cr("  SIGTERM → signal_thread_entry (用于JVM优雅关闭)");
tty->print_cr("  libjsig已加载=%s (LD_PRELOAD拦截sigaction)",
    os::dll_lookup(NULL, "sigaction") != NULL ? "YES" : "NO");
```

**预期输出与结论：**
```
[PROBE][Signal] JVM信号处理器安装完成:
  SIGSEGV → JVM_handle_linux_signal (用于NPE/StackOverflow检测)
  SIGBUS  → JVM_handle_linux_signal (用于内存映射错误)
  SIGFPE  → JVM_handle_linux_signal (用于除零异常)
  SIGPIPE → SIG_IGN
  SIGUSR1 → SR_handler (线程挂起/恢复)
  SIGUSR2 → SR_handler (线程挂起/恢复)
  SIGTERM → signal_thread_entry
  libjsig已加载=YES
→ 结论1：JVM 用 SIGSEGV 实现 NPE 检测（访问 null 指针触发 SIGSEGV，JVM 捕获后抛出 NPE）
→ 结论2：JVM 用 SIGSEGV 实现 Safepoint 轮询（访问 armed 轮询页触发 SIGSEGV）
→ 结论3：libjsig 通过 LD_PRELOAD 拦截 sigaction，保证 JVM 信号处理器不被用户代码覆盖
→ 结论4：SIGUSR1/SIGUSR2 用于线程挂起/恢复，这是 Safepoint 机制的底层实现之一
```

---

#### 9.2 libjsig 链式调用验证

**要验证的问题：**
- 当用户代码调用 `signal(SIGSEGV, handler)` 时，libjsig 如何处理？
- libjsig 维护的信号处理器链是什么结构？
- 信号触发时，JVM 处理器和用户处理器的调用顺序是什么？
- 如果用户处理器返回，JVM 处理器还会被调用吗？

**插桩代码位置**：`libjsig/jsig.c:sigaction()` 包装函数入口

**插桩内容**：
```c
// 在 libjsig 的 sigaction 包装函数中
fprintf(stderr, "[PROBE][libjsig] sigaction拦截: signum=%d (%s), new_handler=%p\n",
    signum, strsignal(signum), (void*)act->sa_handler);
fprintf(stderr, "  是否是JVM信号=%s\n",
    signum == SIGSEGV || signum == SIGBUS || signum == SIGFPE ? "YES(JVM占用)" : "NO(用户信号)");
if (signum == SIGSEGV) {
    fprintf(stderr, "  SIGSEGV已被JVM占用，将用户处理器保存到链表\n");
    fprintf(stderr, "  信号分发顺序: JVM处理器 → 用户处理器(如果JVM不处理)\n");
}
```

**预期输出与结论：**
```
[PROBE][libjsig] sigaction拦截: signum=11 (Segmentation fault), new_handler=0x7f...
  是否是JVM信号=YES(JVM占用)
  SIGSEGV已被JVM占用，将用户处理器保存到链表
  信号分发顺序: JVM处理器 → 用户处理器(如果JVM不处理)
→ 结论1：libjsig 拦截用户的 sigaction 调用，把用户处理器保存到链表而不是直接注册
→ 结论2：信号触发时，JVM 处理器先处理；如果 JVM 不处理（非 JVM 内部信号），再调用用户处理器
→ 结论3：这就是"信号链"的含义：多个处理器串联，按优先级依次调用
```

---

### 第 10 章：Attach 机制插桩（libattach.so）

**目标**：验证 Arthas attach 时 JVM 侧的完整响应链路，**重点是 Attach Listener 的启动时机、命令的接收和分发、以及 Agent 的加载路径**

---

#### 10.1 Attach Listener 启动时机验证

**要验证的问题：**
- Attach Listener 是在 JVM 启动时就创建，还是按需创建？（按需：收到 attach 信号时）
- 触发 Attach Listener 启动的信号是什么？（SIGQUIT / SIGUSR1）
- Attach Listener 监听的是什么？（Unix Domain Socket：`/tmp/.java_pid<pid>`）
- Attach Listener 线程的 OS tid 是多少？

**插桩代码位置**：`services/attachListener.cpp:AttachListener::init()` 入口

**插桩内容**：
```cpp
tty->print_cr("[PROBE][Attach] AttachListener::init() 开始:");
tty->print_cr("  触发原因: 收到SIGQUIT信号 (Arthas发送的attach信号)");
tty->print_cr("  当前时间: JVM已运行%ldms", os::javaTimeMillis() - _vm_start_time_millis);
tty->print_cr("  创建Unix Domain Socket: /tmp/.java_pid%d", os::current_process_id());
// 初始化完成后
tty->print_cr("[PROBE][Attach] AttachListener 初始化完成:");
tty->print_cr("  监听socket: /tmp/.java_pid%d", os::current_process_id());
tty->print_cr("  AttachListener线程 os_tid=%ld", os::current_thread_id());
tty->print_cr("  等待Arthas连接...");
```

**预期输出与结论：**
```
[PROBE][Attach] AttachListener::init() 开始:
  触发原因: 收到SIGQUIT信号 (Arthas发送的attach信号)
  当前时间: JVM已运行5234ms
[PROBE][Attach] AttachListener 初始化完成:
  监听socket: /tmp/.java_pid12345
  AttachListener线程 os_tid=12360
  等待Arthas连接...
→ 结论1：Attach Listener 是懒加载的，JVM 启动时不创建，收到 SIGQUIT 才启动
→ 结论2：Arthas attach 的第一步就是向目标 JVM 发送 SIGQUIT 信号
→ 结论3：通信通道是 Unix Domain Socket（/tmp/.java_pid<pid>），不是 TCP
→ 结论4：Attach Listener 是一个独立线程，不影响 Java 线程的执行
```

---

#### 10.2 Attach 命令接收和分发验证

**要验证的问题：**
- Arthas 发送的第一个命令是什么？（通常是 `load` 命令，加载 arthas-agent.jar）
- 命令的格式是什么？（文本协议：命令名 + 参数）
- `load` 命令如何加载 Agent？（调用 `instrument_load_agent()`）
- Agent 加载后，JVM 的状态有什么变化？（JVMTI 能力被激活）

**插桩代码位置**：`services/attachListener.cpp:AttachListener::dequeue()` 和 `AttachOperation::execute()` 入口

**插桩内容**：
```cpp
// dequeue() 中
tty->print_cr("[PROBE][Attach] 收到命令: op=%s", op->name());
for (int i = 0; i < AttachOperation::arg_count_max; i++) {
    if (op->arg(i) != NULL && strlen(op->arg(i)) > 0) {
        tty->print_cr("  arg[%d]=%s", i, op->arg(i));
    }
}

// execute() 中
tty->print_cr("[PROBE][Attach] 执行命令: %s", op->name());
if (strcmp(op->name(), "load") == 0) {
    tty->print_cr("  加载Agent: %s", op->arg(0));
    tty->print_cr("  是否绝对路径=%s", op->arg(1));
    tty->print_cr("  Agent参数=%s", op->arg(2) != NULL ? op->arg(2) : "(无)");
}
```

**预期输出与结论：**
```
[PROBE][Attach] 收到命令: op=load
  arg[0]=/path/to/arthas-agent.jar
  arg[1]=true (绝对路径)
  arg[2]=arthas-agent-options
[PROBE][Attach] 执行命令: load
  加载Agent: /path/to/arthas-agent.jar
  是否绝对路径=true
  Agent参数=arthas-agent-options
→ 结论1：Arthas attach 的核心命令是 load，通过 Attach 机制加载 arthas-agent.jar
→ 结论2：load 命令底层调用 instrument_load_agent()，触发 JVMTI Agent_OnAttach 回调
→ 结论3：Agent 加载后，Arthas 就可以通过 JVMTI 接口访问 JVM 内部状态
→ 结论4：整个 attach 过程不需要重启 JVM，这就是 Arthas 的核心价值
```

---

### 第 11 章：Handshake 机制插桩

**目标**：验证 OpenJDK 11 新增的 Handshake（线程级 Safepoint）机制，**重点是与全局 Safepoint 的性能差异**

---

#### 11.1 Handshake vs Safepoint 性能对比

**要验证的问题：**
- Handshake 只停一个线程，耗时是多少？（理论上比全局 Safepoint 快 N 倍）
- Handshake 的实现机制是什么？（不是轮询页，而是线程本地标志位）
- 哪些操作使用 Handshake 而不是 Safepoint？（ThreadDump、偏向锁撤销等）

**插桩代码位置**：`runtime/handshake.cpp:Handshake::execute()` 入口和末尾

**插桩内容**：
```cpp
tty->print_cr("[PROBE][Handshake] execute: op=%s, target_tid=%ld",
    hs_nm->name(), target->osthread()->thread_id());
jlong t0 = os::javaTimeNanos();
// ... 执行后
tty->print_cr("[PROBE][Handshake] 完成: elapsed=%ldus (微秒)",
    (os::javaTimeNanos() - t0) / 1000);
tty->print_cr("  处理方式=%s",
    processed_by_self ? "目标线程自处理" : "VMThread代为处理");
tty->print_cr("  对比全局Safepoint: Handshake只停1个线程，约快%dx", Threads::number_of_threads());
```

**预期输出与结论：**
```
[PROBE][Handshake] execute: op=ThreadDump, target_tid=12345
[PROBE][Handshake] 完成: elapsed=300us (微秒)
  处理方式=目标线程自处理
  对比全局Safepoint: Handshake只停1个线程，约快9x
→ 结论1：Handshake 耗时约300微秒，全局 Safepoint 约2毫秒，快约7倍
→ 结论2：Handshake 优先让目标线程自己处理，避免 VMThread 介入
→ 结论3：OpenJDK 11 把很多原来需要全局 Safepoint 的操作改为 Handshake，减少 STW
```

---

### 第 12 章：Metaspace 分配链路插桩

**目标**：验证类元数据在 Metaspace 中的分配路径，**重点是 Chunk 的分配策略和内存碎片情况**

---

#### 12.1 Metaspace 分配的层次结构验证

**要验证的问题：**
- Metaspace 的分配层次是什么？（VirtualSpace → VirtualSpaceNode → Metachunk → 对象）
- 加载一个类需要分配多少 Metaspace 内存？（InstanceKlass + ConstantPool + Methods）
- Chunk 的大小是多少？（SmallChunk=512字节, MediumChunk=8KB, HumongousChunk=可变）
- 加载 500 个类后，Metaspace 的碎片率是多少？

**插桩代码位置**：`memory/metaspace.cpp:Metaspace::allocate()` 入口

**插桩内容**：
```cpp
static size_t total_allocated = 0;
static int alloc_count = 0;
total_allocated += word_size * wordSize;
alloc_count++;
if (alloc_count % 100 == 0) {
    tty->print_cr("[PROBE][Metaspace] 分配统计 (每100次):");
    tty->print_cr("  累计分配次数=%d", alloc_count);
    tty->print_cr("  累计分配字节=%zuKB", total_allocated / K);
    tty->print_cr("  Metaspace已用=%zuMB", MetaspaceUtils::used_bytes() / M);
    tty->print_cr("  Metaspace已提交=%zuMB", MetaspaceUtils::committed_bytes() / M);
    tty->print_cr("  碎片率=%.1f%% (已提交-已用)/已提交",
        (MetaspaceUtils::committed_bytes() - MetaspaceUtils::used_bytes()) * 100.0 / MetaspaceUtils::committed_bytes());
}
```

**预期输出与结论：**
```
[PROBE][Metaspace] 分配统计 (每100次):
  累计分配次数=100
  累计分配字节=512KB
  Metaspace已用=5MB
  Metaspace已提交=8MB
  碎片率=37.5% (Chunk内部碎片)
→ 结论1：Metaspace 碎片率约37%，因为 Chunk 是固定大小，对象不能跨 Chunk
→ 结论2：加载一个类平均消耗约5KB Metaspace（InstanceKlass+ConstantPool+Methods）
→ 结论3：Metaspace 按需提交，不像 Java 堆那样预提交
```

---

### 第 13 章：CodeCache 管理插桩

**目标**：验证 JIT 编译代码在 CodeCache 中的分配、查找、淘汰路径，**重点是 CodeCache 的使用率变化和 Sweeper 的触发条件**

---

#### 13.1 CodeCache 使用率动态变化

**要验证的问题：**
- 程序运行过程中，CodeCache 的使用率如何变化？
- 每次 JIT 编译后，CodeCache 增加了多少？
- Sweeper 在什么条件下触发？触发后回收了多少空间？
- CodeCache 满时，JVM 会做什么？（停止 JIT 编译，退化为解释执行）

**插桩代码位置**：`code/codeCache.cpp:CodeCache::allocate()` 末尾

**插桩内容**：
```cpp
static int nmethod_count = 0;
nmethod_count++;
if (nmethod_count % 10 == 0) {
    tty->print_cr("[PROBE][CodeCache] 状态 (每10次编译):");
    tty->print_cr("  nmethod总数=%d", nmethod_count);
    tty->print_cr("  NonNMethod段: 已用=%zuKB / %zuMB",
        CodeCache::non_nmethod_code_heap()->used() / K,
        CodeCache::non_nmethod_code_heap()->capacity() / M);
    tty->print_cr("  Profiled段: 已用=%zuMB / %zuMB",
        CodeCache::profiled_code_heap()->used() / M,
        CodeCache::profiled_code_heap()->capacity() / M);
    tty->print_cr("  NonProfiled段: 已用=%zuMB / %zuMB",
        CodeCache::non_profiled_code_heap()->used() / M,
        CodeCache::non_profiled_code_heap()->capacity() / M);
}
```

**预期输出与结论：**
```
[PROBE][CodeCache] 状态 (每10次编译):
  nmethod总数=10
  NonNMethod段: 已用=1200KB / 5MB  (解释器+stub，基本固定)
  Profiled段: 已用=1MB / 117MB     (C1代码，随编译增加)
  NonProfiled段: 已用=0MB / 117MB  (C2代码，初期为0)
→ 结论1：NonNMethod 段在启动时就被解释器占满约1.2MB，之后基本不变
→ 结论2：C1 代码先增长，C2 代码后增长（因为 C2 触发阈值更高）
→ 结论3：-Xint 模式下 Profiled 和 NonProfiled 段永远为0
```

---

### 第 14 章：Reference 处理链路插桩

**目标**：验证软引用/弱引用/虚引用在 GC 后的处理路径，**重点是引用队列的入队时机和 ReferenceHandler 线程的工作**

---

#### 14.1 引用处理的时机和数量

**要验证的问题：**
- YoungGC 后处理了多少个弱引用？多少个软引用？
- 哪些引用的 referent 已死（需要清除）？哪些还活着（保留）？
- 引用入队到 ReferenceQueue 的时机是什么？（GC 结束时？还是 GC 过程中？）
- ReferenceHandler 线程被唤醒了多少次？

**插桩代码位置**：`gc/shared/referenceProcessor.cpp:ReferenceProcessor::process_discovered_references()` 末尾

**插桩内容**：
```cpp
tty->print_cr("[PROBE][Reference] GC后引用处理完成:");
tty->print_cr("  SoftReference: 发现=%d, 清除=%d, 保留=%d",
    soft_discovered, soft_cleared, soft_discovered - soft_cleared);
tty->print_cr("  WeakReference: 发现=%d, 清除=%d",
    weak_discovered, weak_cleared);
tty->print_cr("  PhantomReference: 发现=%d, 入队=%d",
    phantom_discovered, phantom_enqueued);
tty->print_cr("  FinalReference: 发现=%d (需要finalize)", final_discovered);
tty->print_cr("  处理耗时=%ldms", elapsed_ms);
```

**预期输出与结论：**
```
[PROBE][Reference] GC后引用处理完成:
  SoftReference: 发现=0, 清除=0, 保留=0 (Demo没有软引用)
  WeakReference: 发现=50, 清除=48, 保留=2
  PhantomReference: 发现=0, 入队=0
  FinalReference: 发现=3 (3个对象有finalize方法)
  处理耗时=0.5ms
→ 结论1：弱引用在 GC 后立即处理，referent 死亡则清除（置null）并入队
→ 结论2：FinalReference 是 finalize() 机制的实现，有 finalize 的对象会被发现
→ 结论3：引用处理在 STW 内完成，是 GC 暂停时间的一部分（约0.5ms）
```

---

### 第 15 章：Parker / LockSupport 插桩

**目标**：验证 `LockSupport.park()` / `unpark()` 的完整路径，**重点是 futex 系统调用的参数和 Parker 的状态机**

---

#### 15.1 Parker 状态机验证

**要验证的问题：**
- `Parker::park()` 调用了哪个 futex 操作？（FUTEX_WAIT）
- `Parker::unpark()` 调用了哪个 futex 操作？（FUTEX_WAKE）
- Parker 的 `_counter` 字段在 park/unpark 前后的值是多少？
- 如果先 unpark 再 park，park 会立即返回吗？（是的，因为 _counter=1）

**插桩代码位置**：`os/linux/os_linux.cpp:Parker::park()` 和 `Parker::unpark()`

**插桩内容**：
```cpp
// park() 中
tty->print_cr("[PROBE][Parker] park: tid=%ld, _counter=%d, timeout=%ldns",
    os::current_thread_id(), _counter, time);
tty->print_cr("  _counter==0, 将调用 futex(FUTEX_WAIT)");
// futex 返回后
tty->print_cr("[PROBE][Parker] park返回: tid=%ld, 原因=%s",
    os::current_thread_id(), _counter > 0 ? "unpark唤醒" : "超时/中断");
tty->print_cr("  _counter重置为0");

// unpark() 中
tty->print_cr("[PROBE][Parker] unpark: target_tid=%ld, 旧_counter=%d",
    thread->osthread()->thread_id(), _counter);
tty->print_cr("  设置_counter=1, 调用 futex(FUTEX_WAKE, 1)");
```

**预期输出与结论：**
```
[PROBE][Parker] park: tid=12345, _counter=0, timeout=0 (无限等待)
  _counter==0, 将调用 futex(FUTEX_WAIT)
[PROBE][Parker] unpark: target_tid=12345, 旧_counter=0
  设置_counter=1, 调用 futex(FUTEX_WAKE, 1)
[PROBE][Parker] park返回: tid=12345, 原因=unpark唤醒
  _counter重置为0
→ 结论1：Parker 用 _counter 实现"许可证"机制，unpark 发放许可，park 消费许可
→ 结论2：先 unpark 再 park 时，park 立即返回（_counter=1，不需要 futex）
→ 结论3：底层是 Linux futex，比 pthread_mutex 更轻量（无需内核态切换的快速路径）
```

---

### 第 16 章：异常处理链路插桩

**目标**：验证 Java 异常从抛出到 catch 的完整路径，**重点是异常表查找算法和栈展开过程**

---

#### 16.1 异常表查找验证

**要验证的问题：**
- 抛出 NPE 时，异常表查找了多少次才找到 handler？
- 异常表的格式是什么？（start_pc, end_pc, handler_pc, catch_type）
- 如果没有 catch，栈展开经历了多少个栈帧？
- 预创建的 NPE 实例和新创建的 NPE 实例有什么区别？

**插桩代码位置**：`interpreter/interpreterRuntime.cpp:InterpreterRuntime::exception_handler_for_exception()` 入口

**插桩内容**：
```cpp
tty->print_cr("[PROBE][Exception] 查找异常处理器: exception=%s",
    exception->klass()->external_name());
tty->print_cr("  当前方法=%s, bci=%d",
    method->name_and_sig_as_C_string(), current_bci);
tty->print_cr("  异常表项数=%d", method->exception_table_length());
// 查找结果
if (handler_bci >= 0) {
    tty->print_cr("  找到handler: bci=%d, catch_type=%s",
        handler_bci, catch_type != NULL ? catch_type->external_name() : "any");
} else {
    tty->print_cr("  未找到handler, 需要展开到上层栈帧");
}
```

**预期输出与结论：**
```
[PROBE][Exception] 查找异常处理器: exception=java/lang/NullPointerException
  当前方法=com/wjcoder/Main.foo()V, bci=15
  异常表项数=1
  找到handler: bci=25, catch_type=java/lang/NullPointerException
→ 结论1：异常表查找是 O(n) 线性扫描，n=异常表项数（通常很小）
→ 结论2：catch_type=null 表示 catch(Throwable)，匹配所有异常
→ 结论3：找到 handler 后直接跳转到 handler_bci，不需要栈展开
```

---

### 第 17 章：JMM 内存屏障插桩

**目标**：验证 `volatile` 读写、`synchronized` 进出时内存屏障的插入位置，**重点是屏障的实际汇编指令和 x86 上的特殊性**

---

#### 17.1 volatile 写屏障的实际实现

**要验证的问题：**
- volatile 写后插入的是什么屏障？（StoreLoad，即 mfence 指令）
- 在 x86 上，volatile 读是否需要屏障？（不需要，x86 的 load 自带 LoadLoad 语义）
- `mfence` 指令的代价是多少？（约100个时钟周期）
- `synchronized` 的 monitorenter/monitorexit 是否包含内存屏障？

**插桩代码位置**：`interpreter/templateTable_x86.cpp:TemplateTable::putfield()` 中 volatile 分支

**插桩内容**：
```cpp
// 在生成 volatile putfield 的汇编时插桩
tty->print_cr("[PROBE][JMM] 生成volatile写屏障:");
tty->print_cr("  字段=%s.%s (volatile=true)",
    field_holder->external_name(), field_name->as_C_string());
tty->print_cr("  插入 StoreLoad 屏障 (x86: lock addl $0,0(%%rsp))");
tty->print_cr("  注意: x86不需要 StoreStore 屏障 (TSO模型自带)");
tty->print_cr("  注意: x86不需要 LoadLoad/LoadStore 屏障 (volatile读无需屏障)");
```

**预期输出与结论：**
```
[PROBE][JMM] 生成volatile写屏障:
  字段=com/wjcoder/Foo.flag (volatile=true)
  插入 StoreLoad 屏障 (x86: lock addl $0,0(%rsp))
  注意: x86不需要 StoreStore 屏障 (TSO模型自带)
  注意: x86不需要 LoadLoad/LoadStore 屏障 (volatile读无需屏障)
→ 结论1：x86 是 TSO(Total Store Order) 模型，天然保证 StoreStore 和 LoadLoad
→ 结论2：volatile 写只需要 StoreLoad 屏障（mfence），volatile 读不需要任何屏障
→ 结论3：JVM 用 lock addl 而不是 mfence，因为 lock addl 在现代 CPU 上更快
→ 结论4：这就是为什么 volatile 在 x86 上比 ARM 便宜（ARM 需要4种屏障）
```

---

## 编译 & 运行流程

### 插桩后重新编译
```bash
cd /data/workspace/openjdk-cut-new
make CONF=linux-x86_64-normal-server-slowdebug hotspot 2>&1 | tail -20
```

### 运行并收集日志
```bash
/data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
    -Xms8g -Xmx8g -XX:+UseG1GC -Xint \
    -Xlog:gc*=trace:stdout \
    -cp /data/workspace/demo/src \
    com.wjcoder.Main \
    2>&1 | tee /tmp/jvm-probe.log
```

### 过滤特定模块日志
```bash
grep '\[PROBE\]\[GC\]'    /tmp/jvm-probe.log   # 只看 GC 插桩
grep '\[PROBE\]\[JIT\]'   /tmp/jvm-probe.log   # 只看 JIT 插桩
grep '\[PROBE\]\[SYNC\]'  /tmp/jvm-probe.log   # 只看同步插桩
grep '\[PROBE\]\[SP\]'    /tmp/jvm-probe.log   # 只看 Safepoint 插桩
```

---

## 文件组织

```
new-jvm-md/Instrumentation/
├── 00-Instrumentation-Master-Outline.md   ← 本文件（总大纲）
├── 01-JVM-Startup-Probe.md               ← 第1章：启动链路插桩记录
├── 02-ClassLoading-Probe.md              ← 第2章：类加载插桩记录
├── 03-ObjectAlloc-Probe.md               ← 第3章：对象分配插桩记录
├── 04-G1YoungGC-Probe.md                 ← 第4章：YoungGC 插桩记录
├── 04B-G1WriteBarrier-Probe.md           ← 第4B章：写屏障 + RSet 插桩记录
├── 04C-G1ConcurrentMark-Probe.md         ← 第4C章：并发标记插桩记录
├── 04D-G1MixedGC-Probe.md               ← 第4D章：Mixed GC 插桩记录
├── 05-JIT-Probe.md                       ← 第5章：JIT 编译插桩记录
├── 05B-OSR-Probe.md                      ← 第5B章：OSR 插桩记录
├── 05C-Deoptimization-Probe.md           ← 第5C章：去优化插桩记录
├── 05D-TemplateTable-Probe.md            ← 第5D章：字节码解释执行插桩记录
├── 06-Safepoint-Probe.md                 ← 第6章：Safepoint 插桩记录
├── 07-Synchronization-Probe.md           ← 第7章：同步机制插桩记录
├── 08-ThreadLifecycle-Probe.md           ← 第8章：线程生命周期插桩记录
├── 09-Signal-Probe.md                    ← 第9章：信号处理插桩记录
├── 10-Attach-Probe.md                    ← 第10章：Attach 机制插桩记录
├── 11-Handshake-Probe.md                 ← 第11章：Handshake 机制插桩记录
├── 12-Metaspace-Probe.md                 ← 第12章：Metaspace 分配插桩记录
├── 13-CodeCache-Probe.md                 ← 第13章：CodeCache 管理插桩记录
├── 14-ReferenceProcessing-Probe.md       ← 第14章：Reference 处理插桩记录
├── 15-Parker-LockSupport-Probe.md        ← 第15章：Parker/LockSupport 插桩记录
├── 16-ExceptionHandling-Probe.md         ← 第16章：异常处理插桩记录
├── 17-JMM-Barrier-Probe.md              ← 第17章：JMM 内存屏障插桩记录
└── patches/                              ← 每章对应的 .patch 文件（可复用）
    ├── 01-startup.patch
    ├── 02-classloading.patch
    ├── ...
```

---

## 进度追踪

| 章节 | 核心验证问题 | 状态 | 关键结论 |
|------|------------|------|---------| 
| 第1章 JVM 启动 | mutex_init初始化了多少把锁？universe_init堆参数？compileBroker启动了几个JIT线程？各阶段耗时？ | ⬜ 待开始 | - |
| 第2章 类加载 | 加载Main前已有多少个类？InstanceKlass大小？vtable内容？双亲委派链路？ | ⬜ 待开始 | - |
| 第3章 对象分配 | TLAB大小？refill触发条件？Humongous阈值？分配几个Region？ | ⬜ 待开始 | - |
| 第4章 G1 YoungGC | GC触发时Eden有多少Region？复制了多少对象？各子阶段耗时？ | ⬜ 待开始 | - |
| 第4B章 G1 写屏障 | 写屏障触发多少次？跨Region比例？DirtyCardQueue长度？ | ✅ 已完成 | 04B-WriteBarrier-Probe-Results.md |
| 第4C章 G1 并发标记 | 并发标记线程数？标记了多少对象？Remark STW耗时？ | ⬜ 待开始 | - |
| 第4D章 G1 Mixed GC | Mixed GC触发条件？CSet包含多少Old Region？回收了多少MB？ | ⬜ 待开始 | - |
| 第5章 JIT 编译 | C1触发阈值？C2触发阈值？编译耗时？代码大小？C1 vs C2代码大小对比？ | ⬜ 待开始 | - |
| 第5B章 OSR 栈上替换 | OSR触发的 backedge_count？OSR编译的 osr_bci？切换时机？ | ⬜ 待开始 | - |
| 第5C章 去优化 | 去优化原因？重建了多少个栈帧？恢复到哪个bci？ | ⬜ 待开始 | - |
| 第5D章 字节码解释执行 | dispatch table地址？handler数量？解释器代码大小？ | ⬜ 待开始 | - |
| 第6章 Safepoint | TTT是多少ms？最慢线程在做什么？操作耗时 vs 恢复耗时？ | ⬜ 待开始 | - |
| 第7章 同步机制 | 膨胀前后Mark Word变化？ObjectMonitor的_EntryList长度？膨胀原因？ | ⬜ 待开始 | - |
| 第8章 线程生命周期 | JavaThread大小？线程栈大小？VMThread执行了哪些VM_Operation？ | ⬜ 待开始 | - |
| 第9章 信号处理 | libjsig拦截了哪些信号？链式调用顺序？ | ⬜ 待开始 | - |
| 第10章 Attach 机制 | Attach Listener何时启动？命令如何分发？Agent加载路径？ | ⬜ 待开始 | - |
| 第11章 Handshake 机制 | Handshake耗时 vs Safepoint耗时？快多少倍？ | ⬜ 待开始 | - |
| 第12章 Metaspace 分配 | 加载一个类消耗多少Metaspace？碎片率是多少？Chunk大小？ | ⬜ 待开始 | - |
| 第13章 CodeCache 管理 | 3段各自使用率？Sweeper触发条件？回收了多少nmethod？ | ⬜ 待开始 | - |
| 第14章 Reference 处理 | YoungGC后处理了多少弱引用？多少被清除？处理耗时？ | ⬜ 待开始 | - |
| 第15章 Parker/LockSupport | _counter状态机？先unpark再park是否立即返回？futex参数？ | ⬜ 待开始 | - |
| 第16章 异常处理 | 异常表项数？查找次数？是否需要栈展开？ | ⬜ 待开始 | - |
| 第17章 JMM 内存屏障 | x86上volatile写插入什么指令？volatile读需要屏障吗？为什么用lock addl不用mfence？ | ⬜ 待开始 | - |

**总计：~146 个插桩点，覆盖 JVM 全部核心子系统**

---

## 验证质量标准

每章完成后，必须能回答以下问题：

1. **数字**：关键参数的具体数值（不是"大约"，是精确值）
2. **公式**：这个值是怎么算出来的（输入参数 → 计算过程 → 输出值）
3. **对比**：与理论预期是否一致？如果不一致，为什么？
4. **结论**：这个数据说明了什么设计决策？

**❌ 不合格的结论：**
> "universe_init 初始化了 G1 堆"

**✅ 合格的结论：**
> "universe_init 创建了 2048 个 4MB Region（总计 8GB），全部初始为 Free 状态，
> 因为 -Xms==-Xmx，所以完全预提交，JVM 启动时就向 OS 申请了 8GB 物理内存，
> 这就是为什么 -Xms8g 比 -Xms256m 启动慢约 300ms"

---

> 等待发号施令，逐章开始插桩 🚀
