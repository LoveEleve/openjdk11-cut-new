# 11.1 数据存储与输出 — CallTraceStorage + FlightRecorder JFR + FlameGraph

> 源文件: `callTraceStorage.cpp` (314行), `flightRecorder.cpp` (1501行), `flameGraph.cpp` (302行), `linearAllocator.cpp` (104行), `lookup.cpp` (187行)
> 关联: `profiler.cpp` (recordSample/dumpFlameGraph 入口), `event.h` (事件类型定义)
> 前置章节: 10.1 符号解析 (PC→帧名转换)

---

## 核心问题

async-profiler 在信号处理器中采集到调用栈后，需要解决三个问题：

1. **去重存储**：相同的调用栈可能被采集上万次，如何高效去重并计数？
2. **实时输出**：如何在信号处理器中将采样事件低成本地写入 JFR 文件？
3. **最终导出**：如何将海量采样数据转换为火焰图 HTML？

**核心约束**：所有操作必须**信号安全**——不能调用 malloc、不能持 mutex、不能阻塞。

---

## 一、CallTraceStorage — 信号安全的调用栈去重哈希表

### 1.1 设计思想

**问题**：信号处理器每秒产生数百个调用栈（每个栈含 20-40 帧），相同的热点路径会重复出现。直接存储所有原始栈会浪费大量内存。

**方案**：将调用栈通过 MurmurHash64A 映射为 64-bit 哈希值，用开放寻址哈希表存储。相同的栈只存一份，仅累加采样计数器。

```
信号处理器:
  调用栈 [frameA, frameB, frameC]
      │
      ▼
  MurmurHash64A → hash = 0xaec8e527...
      │
      ▼
  LongHashTable[slot] 
      ├── key = hash
      └── value = CallTraceSample {
              trace → CallTrace { num_frames=3, frames=[A,B,C] }  ← 只存一份
              samples = 1234    ← 累加
              counter = 12340000  ← 累加（纳秒数）
          }
```

### 1.2 核心数据结构

```
CallTraceStorage
├── _allocator: LinearAllocator  → 信号安全的 bump-pointer 分配器
├── _current_table: LongHashTable*  → 当前哈希表
└── _overflow: u64  → 溢出计数

LongHashTable (开放寻址哈希表)
├── _prev: LongHashTable*  → 前一个已满的表（链表）
├── _capacity: u32  → 容量（初始 65536，每次翻倍）
├── _size: volatile u32  → 当前条目数（原子操作）
├── [keys]: u64[capacity]  → hash 值数组
└── [values]: CallTraceSample[capacity]  → 采样数据数组

CallTraceSample
├── trace: CallTrace*  → 指向实际调用栈（acquire/release 语义）
├── samples: u64  → 采样次数
└── counter: u64  → 计数器值（通常是纳秒数）

CallTrace
├── num_frames: int  → 帧数
└── frames[]: ASGCT_CallFrame[]  → 帧数组（变长）
```

**内存布局（LongHashTable）**：

```
偏移       字段           大小       说明
0x00      _prev            8        前一个表的指针
0x08      _padding0        8        避免伪共享
0x10      _capacity        4        容量
0x14      _padding1[15]   60        缓存行填充
0x50      _size            4        当前大小（volatile）
0x54      _padding2[15]   60        缓存行填充
0x90      keys[0]          8*cap    hash 值数组
...       values[0]       24*cap    CallTraceSample 数组

→ _size 和 _capacity 分别在不同的缓存行中（避免伪共享）
→ keys 和 values 紧密排列，减少 cache miss
```

### 1.3 put() — 信号安全的哈希表插入

```cpp
u32 CallTraceStorage::put(int num_frames, ASGCT_CallFrame* frames, u64 counter) {
    u64 hash = calcHash(num_frames, frames);            // ① MurmurHash64A

    LongHashTable* table = _current_table;
    u32 slot = hash & (capacity - 1);                    // ② 快速取模（capacity 是 2 的幂）
    u32 step = 0;

    while (keys[slot] != hash) {                         // ③ 开放寻址探测
        if (keys[slot] == 0) {
            if (!__sync_bool_compare_and_swap(&keys[slot], 0, hash)) {
                continue;  // CAS 失败 → 其他线程抢先占位 → 重试
            }

            // ④ 检查是否需要扩容（负载因子 > 75%）
            if (table->incSize() == capacity * 3 / 4) {
                LongHashTable* new_table = LongHashTable::allocate(table, capacity * 2);
                __sync_bool_compare_and_swap(&_current_table, table, new_table);
            }

            // ⑤ 尝试从旧表迁移（节省内存）
            CallTrace* trace = table->prev() == NULL ? NULL : findCallTrace(table->prev(), hash);
            if (trace == NULL) {
                trace = storeCallTrace(num_frames, frames);  // 分配新的 CallTrace
            }
            table->values()[slot].setTrace(trace);
            break;
        }

        // ⑥ 改进的线性探测：slot = (slot + step) & (capacity - 1)
        if (++step >= capacity) {
            atomicInc(_overflow);
            return OVERFLOW_TRACE_ID;  // 极端情况：表满溢出
        }
        slot = (slot + step) & (capacity - 1);
    }

    // ⑦ 累加计数器
    CallTraceSample& s = table->values()[slot];
    atomicInc(s.samples);
    atomicInc(s.counter, counter);

    return capacity - (INITIAL_CAPACITY - 1) + slot;     // ⑧ 全局唯一 trace ID
}
```

**关键设计点**：

| 设计 | 原因 |
|------|------|
| CAS 占位 | 信号处理器不能持锁，用 CAS 实现无锁插入 |
| 开放寻址 | 无需 malloc 分配链表节点（链式哈希需要 malloc） |
| 改进探测 | `slot += step`（三角数探测），比纯线性探测更均匀 |
| 负载因子 75% | 达到 75% 时立即扩容，避免探测链过长 |
| 旧表迁移 | 新表创建后，旧表的 CallTrace 仍有效，直接引用节省分配 |

### GDB 验证 — CallTraceStorage::put

```
=== CallTraceStorage::put ===                                        ✅
num_frames=32, counter=10021010
_current_table->_capacity=65536                                      ← 初始容量 64K
_current_table->_size=0                                              ← 首次插入
call_trace_id = 32828                                                ← 全局唯一 ID

→ 32 帧的调用栈
→ counter = 10,021,010 ns ≈ 10ms（CPU profiling 的默认间隔）
→ call_trace_id = 65536 - (65536 - 1) + slot = slot + 1
```

### 1.4 calcHash — MurmurHash64A

```cpp
u64 CallTraceStorage::calcHash(int num_frames, ASGCT_CallFrame* frames) {
    const u64 M = 0xc6a4a7935bd1e995ULL;
    const int R = 47;

    int len = num_frames * sizeof(ASGCT_CallFrame);  // 每帧 16 字节
    u64 h = len * M;

    const u64* data = (const u64*)frames;
    const u64* end = data + len / 8;

    while (data != end) {
        u64 k = *data++;
        k *= M; k ^= k >> R; k *= M;
        h ^= k; h *= M;
    }
    // ... 尾部处理和最终混合
    return h;
}
```

**为什么选 MurmurHash？**
- 性能极高：每个 64-bit 字仅需 2 次乘法 + 2 次位运算
- 雪崩效应好：输入变化 1 bit，输出 ~50% bit 变化
- 在信号处理器中运行，不能用复杂的哈希算法

### GDB 验证 — calcHash

```
=== calcHash ===                                                     ✅
num_frames=40
hash = 0xaec8e52754c3057f

→ 40 帧 × 16 bytes = 640 bytes 输入
→ 64-bit 哈希分布均匀
```

### 1.5 call_trace_id 的全局唯一编码

```
当前表 capacity=131072，旧表 capacity=65536 时：

旧表 slot 范围: [0, 65535]
  → call_trace_id = 65536 - 65535 + slot = slot + 1
  → ID 范围: [1, 65536]

当前表 slot 范围: [0, 131071]
  → call_trace_id = 131072 - 65535 + slot = slot + 65537
  → ID 范围: [65537, 196608]

→ 不同表的 ID 永不冲突！
```

公式 `call_trace_id = capacity - (INITIAL_CAPACITY - 1) + slot` 巧妙利用了"每次扩容容量翻倍"的性质：几何级数的前 n 项和恰好不会与当前项重叠。

### 1.6 collectTraces — 收集所有有效调用栈

```cpp
void CallTraceStorage::collectTraces(std::map<u32, CallTrace*>& map) {
    for (LongHashTable* table = _current_table; table != NULL; table = table->prev()) {
        for (u32 slot = 0; slot < capacity; slot++) {
            if (keys[slot] != 0 && loadAcquire(values[slot].samples) != 0) {
                values[slot].samples = 0;  // 重置，避免 JFR chunk 间重复
                CallTrace* trace = values[slot].acquireTrace();
                if (trace != NULL) {
                    map[call_trace_id] = trace;
                }
            }
        }
    }
}
```

**JFR chunk 去重**：`values[slot].samples = 0` 确保同一个 CallTrace 不会在多个 JFR chunk 中重复出现。

---

## 二、LinearAllocator — 信号安全的 Bump-Pointer 分配器

### 2.1 设计思想

**问题**：`CallTraceStorage::storeCallTrace()` 需要分配变长内存来存储 CallTrace。但在信号处理器中不能调用 `malloc()`——它不是信号安全的。

**方案**：预分配大块内存（8MB chunk），用 CAS bump-pointer 分配。

### 2.2 核心结构

```
Chunk (预分配的 8MB 内存块)
├── prev: Chunk*           → 前一个 chunk（链表）
├── offs: volatile size_t  → 当前分配偏移（CAS 更新）
├── _padding[56]           → 填充到 72 字节（缓存行对齐）
└── [数据区]: 8MB - 72B    → 实际可用空间

LinearAllocator
├── _chunk_size: 8MB
├── _tail: Chunk*    → 当前活跃 chunk
└── _reserve: Chunk* → 预分配的下一个 chunk
```

### 2.3 alloc() — CAS Bump-Pointer

```cpp
void* LinearAllocator::alloc(size_t size) {
    Chunk* chunk = _tail;
    do {
        for (size_t offs = chunk->offs; offs + size <= _chunk_size; offs = chunk->offs) {
            if (__sync_bool_compare_and_swap(&chunk->offs, offs, offs + size)) {
                // 过了中点 → 预分配下一个 chunk
                if (_chunk_size / 2 - offs < size) {
                    reserveChunk(chunk);
                }
                return (char*)chunk + offs;
            }
        }
    } while ((chunk = getNextChunk(chunk)) != NULL);
    return NULL;
}
```

**设计要点**：

1. **CAS 无锁**：多个信号处理器可以并发分配，通过 CAS 保证原子性
2. **预分配**：当 chunk 使用超过一半时，提前分配下一个 chunk（`reserveChunk()`），避免竞争
3. **Reserve 机制**：`_reserve` 指针预先持有一个空闲 chunk。如果 `_reserve == _tail`，说明还没预分配，需要竞争分配
4. **只分配不释放**：CallTrace 永远不会被单独释放，只在 `clear()` 时整体释放

### GDB 验证 — LinearAllocator::alloc

```
=== LinearAllocator::alloc ===                                       ✅
size=760, _chunk_size=8388608                                        ← 8MB chunk
_tail->offs=72                                                       ← sizeof(Chunk) = 72
result=0x7ffff4a00048                                                ← chunk_base + 72

→ 760 bytes = sizeof(CallTrace) + 47帧 × 16 = 8 + 752
→ 一个 8MB chunk 可存 ~11000 个这样的调用栈
→ 首次分配从 offset=72 开始（跳过 Chunk 头部）
```

---

## 三、Profiler::recordSample — 存储入口

### 3.1 完整的信号处理器到存储的链路

```
SIGPROF 信号触发
     │
     ▼
PerfEvents::signalHandler / CTimer::signalHandler
     │
     ▼
Profiler::recordSample(ucontext, counter, event_type, event)
     │
     ├─① tryLock: 尝试获取 3 个 SpinLock 中的一个
     │   → 3 次机会，全失败则丢弃（_failures[-ticks_skipped]++）
     │
     ├─② 栈回溯: getNativeTrace + getJavaTraceAsync / StackWalker::walkVM
     │   → 获得 ASGCT_CallFrame frames[] (最多 MAX_NATIVE_FRAMES=128 帧)
     │
     ├─③ 存储: _call_trace_storage.put(num_frames, frames, counter)
     │   → MurmurHash → 哈希表查找/插入 → 返回 call_trace_id
     │
     ├─④ JFR 记录: _jfr.recordEvent(lock_index, tid, call_trace_id, event_type, event)
     │   → 写入 RecordingBuffer → 定期 flush 到磁盘
     │
     └─⑤ unlock
```

### 3.2 CONCURRENCY_LEVEL = 16

```cpp
SpinLock _locks[CONCURRENCY_LEVEL];
RecordingBuffer _buf[CONCURRENCY_LEVEL];
```

**16 把锁 + 16 个 Buffer**：每个信号处理器尝试获取锁 `lock_index = tid % 16`，失败则尝试 `+1, +2`。这样最多 16 个信号处理器并发写入不同的 Buffer，无竞争。

### GDB 验证 — FlightRecorder::recordEvent

```
=== FlightRecorder::recordEvent ===                                  ✅
lock_index=9, tid=915637, call_trace_id=51896, event_type=0

→ event_type=0 → PERF_SAMPLE（CPU 性能计数器采样）
→ lock_index=9 → 使用第 9 个 RecordingBuffer
→ 同一时刻最多 16 个信号处理器并发写入
```

---

## 四、FlightRecorder — JFR 文件输出引擎

### 4.1 JFR 文件格式概览

```
JFR 文件 (.jfr)
┌─────────────────────────────────────────┐
│ Chunk 1                                 │
│ ┌─────────────────────────────────────┐ │
│ │ Chunk Header (68 bytes)             │ │
│ │  magic: "FLR\0"                     │ │
│ │  version: 2.0                       │ │
│ │  chunk_size, cpool_offset, meta_off │ │
│ │  start_time, duration, start_ticks  │ │
│ │  ticks_per_sec                      │ │
│ ├─────────────────────────────────────┤ │
│ │ Metadata Event                      │ │
│ │  类型元信息 (XML→二进制)            │ │
│ ├─────────────────────────────────────┤ │
│ │ Recording Info + Settings           │ │
│ ├─────────────────────────────────────┤ │
│ │ Event Records (变长)                │ │
│ │  ExecutionSample, AllocInNewTLAB,   │ │
│ │  MonitorEnter, ThreadPark, ...      │ │
│ ├─────────────────────────────────────┤ │
│ │ Constant Pool                       │ │
│ │  Threads, StackTraces, Methods,     │ │
│ │  Classes, Packages, Symbols         │ │
│ └─────────────────────────────────────┘ │
├─────────────────────────────────────────┤
│ Chunk 2 (可选，switchChunk 后产生)      │
│ ...                                     │
└─────────────────────────────────────────┘
```

### 4.2 Chunk Header 格式 (68 bytes)

```
偏移   字段              大小   说明
0x00   magic             4     "FLR\0"
0x04   major             2     版本号主版本 = 2
0x06   minor             2     版本号次版本 = 0
0x08   chunk_size        8     整个 chunk 的字节数 (finishChunk 时回填)
0x10   cpool_offset      8     Constant Pool 在 chunk 内的偏移
0x18   meta_offset       8     Metadata 在 chunk 内的偏移
0x20   start_time_nanos  8     chunk 开始时间（纳秒，wall clock）
0x28   duration_nanos    8     chunk 持续时间（纳秒）
0x30   start_ticks       8     chunk 开始时的 TSC tick 值
0x38   ticks_per_sec     8     TSC 频率（ticks/秒）
0x40   features          4     特性标志位
总大小: 68 bytes
```

### GDB 验证 — Recording::writeHeader

```
=== Recording::writeHeader ===                                       ✅
_start_time = 1770690776733971 us
_start_ticks = 54287007038231
_chunk_size = 104857600 (100MB，默认 chunk 大小)
_chunk_time = 3600000000 (3600秒 = 1小时，默认 chunk 时间)
_fd = 3 (输出文件描述符)
```

### JFR 二进制验证

```
xxd -l 64 /tmp/profile_hdr.jfr:
00000000: 464c 5200 0002 0000 ...                  ← "FLR\0" + 版本 2.0  ✅
          ^^^^                                       magic = 0x464c5200
               ^^^^                                  major = 0x0002
                    ^^^^                              minor = 0x0000
```

### 4.3 Buffer — 高效的二进制序列化器

```
Buffer 是一个内联数组，直接在栈上或对象内分配:

SmallBuffer:     1024 bytes (用于 CPU Load、Heap Summary 等小事件)
RecordingBuffer: 65536 bytes (用于采样事件的主缓冲区)

序列化方法:
├── put8(v)      → 单字节
├── put16(v)     → 2字节 big-endian
├── put32(v)     → 4字节 big-endian
├── put64(v)     → 8字节 big-endian
├── putVar32(v)  → 1~5字节 LEB128 变长编码
├── putVar64(v)  → 1~9字节 LEB128 变长编码
├── putUtf8(v)   → [3] + [len] + [bytes]  (UTF8 编码字符串)
├── putFloat(v)  → 4字节 IEEE 754 big-endian
└── putByteString(v) → [5] + [len] + [bytes] (Latin1 字节数组)
```

**LEB128 变长编码**：小整数用 1 字节，大整数用多字节。JFR 格式中大量使用，节省空间。

```
值       编码               字节数
0        0x00               1
127      0x7f               1
128      0x80 0x01          2
16383    0xff 0x7f          2
16384    0x80 0x80 0x01     3
```

### 4.4 Recording — JFR 录制会话

Recording 是一个内部类，管理整个 JFR 录制的生命周期：

```
Recording 创建 (FlightRecorder::start)
     │
     ├── writeHeader()         → 写 68 字节 Chunk Header (占位)
     ├── writeMetadata()       → 写元数据（事件类型定义）
     ├── writeRecordingInfo()  → 写录制信息
     ├── writeSettings()       → 写采样设置
     ├── writeOsCpuInfo()      → 写操作系统/CPU 信息
     ├── writeJvmInfo()        → 写 JVM 版本/参数
     ├── writeSystemProperties()→ 写 Java 系统属性
     └── writeNativeLibraries() → 写本地库列表
            │
            ▼
    事件录制阶段（信号处理器中调用 recordEvent）
            │
            ▼
Recording 销毁 (FlightRecorder::stop → ~Recording)
     │
     ├── finishChunk()
     │   ├── flush 所有 Buffer
     │   ├── writeNativeLibraries() (增量写新发现的库)
     │   ├── writeCpool()          → 写 Constant Pool
     │   │   ├── writeFrameTypes()
     │   │   ├── writeThreadStates()
     │   │   ├── writeGCWhen()
     │   │   ├── writeThreads()
     │   │   ├── writeStackTraces()  → 从 CallTraceStorage 收集
     │   │   ├── writeMethods()      → 从 Lookup 解析
     │   │   ├── writeClasses()
     │   │   ├── writePackages()
     │   │   ├── writeSymbols()
     │   │   ├── writeUserEventTypes()
     │   │   └── writeLogLevels()
     │   ├── pwrite() 回填 cpool 大小
     │   └── pwrite() 回填 Chunk Header
     └── close(_fd)
```

### 4.5 recordEvent 的分发

```cpp
void FlightRecorder::recordEvent(int lock_index, int tid, u32 call_trace_id,
                                 EventType event_type, Event* event) {
    Buffer* buf = _rec->buffer(lock_index);  // 使用 lock_index 对应的 Buffer
    switch (event_type) {
        case PERF_SAMPLE:
        case EXECUTION_SAMPLE:
        case INSTRUMENTED_METHOD:
            _rec->recordExecutionSample(buf, tid, call_trace_id, (ExecutionEvent*)event);
            break;
        case ALLOC_SAMPLE:
            _rec->recordAllocationInNewTLAB(buf, tid, call_trace_id, (AllocEvent*)event);
            break;
        case LOCK_SAMPLE:
            _rec->recordMonitorBlocked(buf, tid, call_trace_id, (LockEvent*)event);
            break;
        // ... 13 种事件类型
    }
    _rec->flushIfNeeded(buf);  // Buffer 满了就 flush 到磁盘
    _rec->addThread(tid);       // 记录线程 ID 到线程集合
}
```

### 4.6 事件编码格式

以 ExecutionSample 为例：

```cpp
void recordExecutionSample(Buffer* buf, int tid, u32 call_trace_id, ExecutionEvent* event) {
    int start = buf->skip(1);            // 预留 1 字节放事件大小
    buf->put8(T_EXECUTION_SAMPLE);       // 事件类型 ID
    buf->putVar64(event->_start_time);   // 时间戳（TSC ticks）
    buf->putVar32(tid);                  // 线程 ID
    buf->putVar32(call_trace_id);        // 调用栈 ID（引用 Constant Pool）
    buf->putVar32(event->_thread_state); // 线程状态
    buf->put8(start, buf->offset() - start);  // 回填事件大小
}
```

**"length-prefix" 模式**：先 skip(1) 预留大小位，写完后回填。这避免了预先计算事件大小。

### 4.7 Constant Pool — 符号池

所有事件中引用的字符串、方法名、类名等，都通过 ID 引用 Constant Pool 中的条目：

```
Event Record:
  call_trace_id = 42  →────────────────→  Constant Pool:
                                           StackTrace[42] {
                                             truncated: 0
                                             frames: [
                                               { method: 7, lineNumber: 123, bci: 42, type: INTERPRETED }
                                               { method: 8, lineNumber: 0,   bci: 0,  type: NATIVE }
                                             ]
                                           }
                                           Method[7] = { class: 3, name: "sleep", sig: "(J)V" }
                                           Method[8] = { class: 5, name: "LinkResolver::resolve_field", sig: "()L;" }
                                           Class[3]  = { name: "java/lang/Thread" }
                                           Class[5]  = { name: "libjvm.so" }
```

**Constant Pool 在 chunk 末尾写入**：因为只有 chunk 结束时才知道所有引用到的符号。

### 4.8 writeCpool — Constant Pool 的 11 个子池

```
Constant Pool
├── T_FRAME_TYPE      (7 种帧类型)
├── T_THREAD_STATE    (3 种线程状态)
├── T_GC_WHEN         (2 种 GC 时机)
├── T_THREAD          (所有活跃线程)
├── T_STACK_TRACE     (所有调用栈)      ← 从 CallTraceStorage 收集
├── T_METHOD          (所有方法)         ← 从 Lookup 解析
├── T_CLASS           (所有类)
├── T_PACKAGE         (所有包)
├── T_SYMBOL          (所有字符串)
├── T_USER_EVENT_TYPE (用户自定义事件)
└── T_LOG_LEVEL       (日志级别)
```

### 4.9 writeStackTraces — 从 Storage 到 JFR

```cpp
void writeStackTraces(Buffer* buf, Lookup* lookup) {
    std::map<u32, CallTrace*> traces;
    Profiler::instance()->_call_trace_storage.collectTraces(traces);

    writePoolHeader(buf, T_STACK_TRACE, traces.size());
    for (auto it = traces.begin(); it != traces.end(); ++it) {
        CallTrace* trace = it->second;
        buf->putVar32(it->first);           // stack trace ID
        buf->putVar32(0);                    // truncated
        buf->putVar32(trace->num_frames);    // frame count
        for (int i = 0; i < trace->num_frames; i++) {
            MethodInfo* mi = lookup->resolveMethod(trace->frames[i]);
            buf->putVar32(mi->_key);         // method ID
            // 根据帧类型写入行号、BCI、帧类型
            ...
        }
    }
}
```

### 4.10 Lookup — 方法解析器

Lookup 是 JFR 输出阶段的核心桥梁，将 `ASGCT_CallFrame` 转换为 JFR 格式：

```cpp
MethodInfo* Lookup::resolveMethod(ASGCT_CallFrame& frame) {
    // 根据 bci 区分帧类型:
    if (frame.bci == BCI_NATIVE_FRAME) {
        // Native 帧: method_id 是 char* (符号名)
        fillNativeMethodInfo(mi, name, lib_name);
        // → Demangle + 库名查找
    }
    else if (frame.bci > BCI_NATIVE_FRAME) {
        // Java 帧: method_id 是 jmethodID
        fillJavaMethodInfo(mi, method, first_time);
        // → JVMTI 查询方法名/类名/行号表
    }
    else if (frame.bci == BCI_ADDRESS) {
        // 裸地址帧: 格式化为 "0x7fff1234"
    }
    // ... 其他帧类型
}
```

**fillJavaMethodInfo 的行号表获取**：

```cpp
if (first_time && jvmti->GetLineNumberTable(method, &mi->_line_number_table_size, 
                                              &mi->_line_number_table) != 0) {
    mi->_line_number_table_size = 0;
}
```

行号表只获取一次，缓存在 `MethodInfo` 中。

### 4.11 Chunk 分块机制

```cpp
void switchChunk() {
    finishChunk();        // 结束当前 chunk
    // 重置状态
    _start_time = _stop_time;
    _start_ticks = _stop_ticks;
    _base_id += 0x1000000;  // 符号 ID 偏移，避免跨 chunk 冲突
    _bytes_written = 0;
    // 开始新 chunk
    writeHeader + writeMetadata + writeRecordingInfo
}

bool needSwitchChunk(u64 wall_time) {
    return _bytes_written >= _chunk_size      // 默认 100MB
        || wall_time - _start_time >= _chunk_time;  // 默认 1 小时
}
```

**`_base_id += 0x1000000`**：每个 chunk 的符号 ID 空间偏移 16M，保证跨 chunk 的方法/类/包 ID 不冲突。

### 4.12 In-Memory 模式

```cpp
if (args.hasOption(IN_MEMORY) && (_memfd = OS::createMemoryFile("async-profiler-recording")) >= 0) {
    _in_memory = true;
}
```

当 `IN_MEMORY` 选项开启时：
1. 事件先写入 `memfd`（内存文件）
2. `finishChunk()` 时用 `OS::copyFile(memfd, fd)` 拷贝到实际文件
3. 减少对磁盘的小量随机写入

### 4.13 JFR Sync — 与 JDK 内置 JFR 集成

async-profiler 可以与 JDK 内置的 JFR 录制同步：

```cpp
Error FlightRecorder::startMasterRecording(Arguments& args, const char* filename) {
    // 1. 加载 JfrSync 辅助类
    jclass cls = env->DefineClass(JFR_SYNC_NAME, ...);

    // 2. 设置 JFR Options (chunk size, stack depth)
    env->CallStaticVoidMethod(options_class, "setMaxChunkSize", ...);

    // 3. 启动 JDK JFR 录制
    env->CallStaticVoidMethod(_jfr_sync_class, _start_method, filename, settings, event_mask);
}
```

---

## 五、FlameGraph — 火焰图 HTML 生成引擎

### 5.1 设计思想

**问题**：如何将数万个采样的调用栈转换为交互式火焰图？

**方案**：三步处理流水线：

```
① CallTraceStorage → collectSamples()
   → 获取所有 CallTraceSample (trace + samples + counter)

② 构建 Trie (前缀树)
   → 每个调用路径成为 Trie 中的一条路径
   → 每个节点记录 _total (该帧的总样本数) 和 _self (该帧独占的样本数)

③ Trie → HTML
   → 嵌入 flame.html 模板
   → 用压缩的 JS 函数调用表示帧: f(name,level,x,total)
```

### 5.2 Trie 数据结构

```
Trie (前缀树节点)
├── _children: map<u32, Trie*>  → 子节点（key = nameIndex | type << 28）
├── _total: u64                 → 该节点下的总样本数
├── _self: u64                  → 该节点独占的样本数（叶子节点贡献）
├── _inlined: u64               → 内联帧的样本数
├── _c1_compiled: u64           → C1 编译帧的样本数
└── _interpreted: u64           → 解释器帧的样本数
```

**key 编码**：`u32 key = name_index | (type << 28)`
- 低 28 位：名称在 cpool 中的索引
- 高 4 位：帧类型（FRAME_NATIVE, FRAME_JIT_COMPILED, FRAME_CPP 等）

### 5.3 addChild — 构建 Trie

```cpp
Trie* FlameGraph::addChild(Trie* f, const char* name, FrameTypeId type, u64 value) {
    // 去掉 "_[k]" 后缀
    std::string s(name, has_suffix ? len - 4 : len);

    u32 name_index = _cpool[s];  // 字符串常量池

    f->_total += value;  // 父节点累加

    switch (type) {
        case FRAME_INLINED:
            // 内联帧合并到 JIT_COMPILED 节点
            (f = f->child(name_index, FRAME_JIT_COMPILED))->_inlined += value;
            return f;
        case FRAME_C1_COMPILED:
            (f = f->child(name_index, FRAME_JIT_COMPILED))->_c1_compiled += value;
            return f;
        default:
            return f->child(name_index, type);
    }
}
```

**内联帧合并**：`FRAME_INLINED` 和 `FRAME_C1_COMPILED` 都合并到 `FRAME_JIT_COMPILED` 节点下，但通过 `_inlined` / `_c1_compiled` 计数器区分比例。火焰图中：
- 内联超过 1/3 → 显示为 inlined 颜色
- C1 编译超过 1/2 → 显示为 C1 compiled 颜色
- 解释执行超过 1/2 → 显示为 interpreted 颜色

### 5.4 dumpFlameGraph — 完整导出流程

```cpp
void Profiler::dumpFlameGraph(Writer& out, Arguments& args, bool tree) {
    FlameGraph flamegraph(title, counter, minwidth, reverse, inverted);

    // ① 收集所有采样
    std::vector<CallTraceSample*> samples;
    _call_trace_storage.collectSamples(samples);

    // ② 构建 Trie
    for (auto it = samples.begin(); it != samples.end(); ++it) {
        CallTrace* trace = (*it)->acquireTrace();
        u64 counter = (*it)->samples;

        Trie* f = flamegraph.root();
        if (reverse) {
            // 反向火焰图：从栈底到栈顶
            for (int j = 0; j < num_frames; j++) {
                f = flamegraph.addChild(f, fn.name(trace->frames[j]), fn.type(trace->frames[j]), counter);
            }
        } else {
            // 正向火焰图：从栈顶到栈底
            for (int j = num_frames - 1; j >= 0; j--) {
                f = flamegraph.addChild(f, fn.name(trace->frames[j]), fn.type(trace->frames[j]), counter);
            }
        }
        f->_total += counter;
        f->_self += counter;  // 叶子节点的 self 计数
    }

    // ③ 输出 HTML
    flamegraph.dump(out, tree);
}
```

### 5.5 printFrame — 压缩的帧编码

```
输出到 HTML 的帧编码函数:
  u(name_and_type)             → 子帧（上一帧的直接子节点，x不变）
  n(name_and_type)             → 兄弟帧（与上一帧同层，紧邻）
  f(name_and_type,level,dx)    → 任意帧（需要指定层级和 x 偏移）

可选的额外参数: ,total,inlined,c1,interpreted

示例:
  f(42,0,0,1000)        → 根帧，名称 42，层 0，x=0，total=1000
  u(17)                  → 子帧，名称 17（total 继承上一帧）
  n(23,500)              → 兄弟帧，名称 23，total=500
  u(8,300,100,50,0)      → 子帧，total=300，inlined=100，c1=50，interpreted=0
```

**这种增量编码极大压缩了火焰图数据**：

- 大多数帧是 `u()` 或 `n()`，只需 1 个参数
- level 和 x 通过前一帧自动推导，无需显式传递
- 相比 JSON 格式，压缩率可达 5-10 倍

### 5.6 Cpool 压缩

```cpp
void FlameGraph::printCpool(Writer& out) {
    // 前缀压缩：利用相邻字符串的公共前缀
    size_t prefix_len = StringUtils::getCommonPrefix(prev, it->first);
    // 编码: [prefix_len + ' '] + [suffix]
    // 例如: "java.lang.Thread.sleep" 和 "java.lang.Thread.start"
    //   → 共享前缀 "java.lang.Thread." (17字节)
    //   → 编码: chr(17+32) + "start" = "1start"
}
```

**有序遍历 + 前缀压缩**：由于 `std::map` 有序，相邻的帧名通常有较长的公共前缀（如同一个包的类），前缀压缩效率很高。

### 5.7 HTML 模板嵌入

```cpp
INCBIN(FLAMEGRAPH_TEMPLATE, "src/res/flame.html")
INCBIN(TREE_TEMPLATE, "src/res/tree.html")
```

`INCBIN` 宏将 HTML 模板在编译时嵌入到二进制中。输出时用 `printTill()` 方法在模板中的占位符位置插入数据。

---

## 六、四种输出格式对比

| 格式 | 方法 | 特点 |
|------|------|------|
| **JFR** | `FlightRecorder::recordEvent` | 实时写入，JDK 兼容格式，可用 JMC 打开 |
| **FlameGraph** | `dumpFlameGraph()` | 交互式 HTML，Trie 构建 + 压缩编码 |
| **Collapsed** | `dumpCollapsed()` | 文本格式，每行一个栈 + 计数 |
| **Text** | `dumpText()` | 按 counter 排序的文本摘要 |
| **OTLP** | `dumpOtlp()` | OpenTelemetry Protocol，Protobuf 格式 |

**JFR 是唯一的实时输出**——事件在采样时就写入文件。其他格式都是 stop 后才导出。

---

## 七、面试级知识点

### Q1: 为什么 CallTraceStorage 用开放寻址哈希表而不用链式哈希？

信号处理器中不能调用 `malloc()`。链式哈希在插入新节点时需要 `malloc` 分配链表节点。开放寻址只需要一个连续数组（`mmap` 预分配），用 CAS 就能无锁插入。

### Q2: 三角数探测（quadratic probing）比线性探测好在哪？

线性探测 `slot = (slot + 1) % cap` 在高负载时会形成**聚集（clustering）**——连续的已占位 slot 越长，插入越慢。三角数探测 `slot = (slot + step) % cap`（step 递增）跳跃式探测，避免聚集。

### Q3: JFR 的 Chunk Header 为什么需要回填？

写入 Header 时，`chunk_size` 和 `cpool_offset` 等字段还不知道（需要等整个 chunk 写完）。所以先写占位值，`finishChunk()` 时用 `pwrite()` 回填。

`pwrite()` 不改变文件偏移量，可以精准定位回填。

### Q4: 为什么 FlameGraph 用 Trie 而不是直接用 map<string, count>？

火焰图需要表达**层次结构**（A 调用 B 调用 C）。Trie 天然表达这种层次关系：
- 共同的调用前缀合并在同一条路径上
- 每个节点的 `_total` 自动累加子节点
- 可以直接 DFS 输出为火焰图

### Q5: _base_id += 0x1000000 是什么意思？

JFR 中方法/类/包的 ID 在写入 Constant Pool 时通过 `idx | _base_id` 编码。当切换 chunk 时，`_base_id` 增加 0x1000000（16M），确保新 chunk 的 ID 不与旧 chunk 冲突。这样每个 chunk 可以独立解析。

### Q6: LinearAllocator 的 reserve 机制解决了什么问题？

多个信号处理器可能同时耗尽当前 chunk 并需要新 chunk。如果等到 chunk 满了才分配新的，会造成**竞争风暴**——所有线程同时 `mmap`。

Reserve 机制在 chunk 使用过半时就预分配下一个，让后续的 chunk 切换只需一次 CAS 即可完成。

---

## 八、总结

### 数据流全景图

```
                        信号处理器 (热路径)
                              │
                    ┌─────────┼─────────┐
                    │                    │
                    ▼                    ▼
          CallTraceStorage         FlightRecorder
          (调用栈去重)              (JFR 实时写入)
          ┌──────────┐          ┌──────────────┐
          │MurmurHash│          │ Buffer[16]   │
          │LongHashTbl│         │ RecordingBuf │
          │LinearAlloc│         │ write(fd)    │
          └──────────┘          └──────────────┘
                    │                    │
                    └─────────┬──────────┘
                              │
                        stop / dump
                              │
                    ┌─────────┼──────────┐
                    │         │          │
                    ▼         ▼          ▼
              FlameGraph  Collapsed    Text
              (Trie→HTML)  (文本)     (摘要)
```

### 核心创新

| 创新点 | 设计 | 效果 |
|--------|------|------|
| **信号安全哈希表** | CAS + 开放寻址 + 三角数探测 | 无锁去重，75% 负载因子自动扩容 |
| **LinearAllocator** | CAS bump-pointer + reserve 预分配 | 信号安全、O(1) 分配、零碎片 |
| **16-way 并发 Buffer** | lock_index = tid % 16 | 16 路并行写入，几乎无竞争 |
| **增量帧编码** | u()/n()/f() 三种模式 | 火焰图数据压缩 5-10x |
| **前缀压缩 Cpool** | 利用 map 有序性 + 公共前缀 | 帧名存储高度压缩 |
| **Chunk 回填** | Header 占位 + pwrite 回填 | 流式写入，无需预计算大小 |

### GDB 验证关键数据

| 验证项 | 结果 | 含义 |
|--------|------|------|
| LongHashTable 初始容量 | **65536** | 2^16，足够大多数场景 |
| MurmurHash 输入 | 40 帧 × 16B = 640B | 高效的 64-bit 哈希 |
| LinearAllocator chunk | **8MB** | sizeof(Chunk)=72，可存 ~11000 个调用栈 |
| JFR Header magic | **FLR\0** | 版本 2.0，标准 JFR 格式 |
| Chunk 默认大小 | **100MB** | chunk_time 默认 1 小时 |
| CONCURRENCY_LEVEL | **16** | 16 把锁 + 16 个 Buffer |
| CPU counter | **10,021,010 ns** | ≈10ms（CPU profiling 默认间隔）|

---

*创建日期: 2026-02-10*
*GDB 验证环境: OpenJDK 11 slowdebug + async-profiler v4.0*
*标准条件: -Xms8g -Xmx8g -XX:+UseG1GC -Xint*
*测试程序: SymbolDemo.java*
