# Lesson 12: JFR 输出格式深度解析

## 一、JFR 格式概览

Java Flight Recorder (JFR) 是 JDK 内置的低开销事件记录框架。AsyncProfiler 可以直接输出 JFR 格式，兼容 JDK Mission Control (JMC) 等工具。

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      JFR 文件结构                                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────────┐                                                    │
│  │   File Header   │  魔数 + 版本 + Chunk 大小预留                      │
│  │   (68 bytes)    │                                                    │
│  ├─────────────────┤                                                    │
│  │   Metadata      │  事件类型定义、字符串池                             │
│  ├─────────────────┤                                                    │
│  │   Recording     │  录制信息（名称、开始时间、持续时间）               │
│  │   Info          │                                                    │
│  ├─────────────────┤                                                    │
│  │   Settings      │  所有配置参数（engine, event, interval...）        │
│  ├─────────────────┤                                                    │
│  │   System Info   │  OS/CPU 信息、JVM 信息、系统属性、Native 库        │
│  ├─────────────────┤                                                    │
│  │   Events        │  执行采样、分配事件、锁事件等                       │
│  │   (可变长)      │  - 每个事件：类型 ID + 时间戳 + 事件数据            │
│  ├─────────────────┤                                                    │
│  │   Constant Pool │  方法、类、线程、符号表等常量                       │
│  │   (CPool)       │  - 在 Chunk 结束时写入                             │
│  └─────────────────┘                                                    │
│                                                                         │
│  注：JFR 文件可包含多个 Chunk，每个 Chunk 是独立的完整记录              │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 二、Buffer 类：二进制编码核心

### 2.1 Buffer 类定义

```cpp
// flightRecorder.cpp:77-203
class Buffer {
  private:
    int _offset;
    char _data[0];  // 柔性数组，实际大小由子类定义

  protected:
    Buffer() : _offset(0) {}

  public:
    // 基本操作
    const char* data() const { return _data; }
    int offset() const { return _offset; }
    int skip(int delta) { int offset = _offset; _offset = offset + delta; return offset; }
    void reset() { _offset = 0; }
    void put(const char* v, u32 len) { memcpy(_data + _offset, v, len); _offset += (int)len; }
    
    // 基本类型编码
    void put8(char v) { _data[_offset++] = v; }
    void put16(short v) { *(short*)(_data + _offset) = htons(v); _offset += 2; }
    void put32(int v) { *(int*)(_data + _offset) = htonl(v); _offset += 4; }
    void put64(u64 v) { *(u64*)(_data + _offset) = OS::hton64(v); _offset += 8; }
    void putFloat(float v) { union { float f; int i; } u; u.f = v; put32(u.i); }
    
    // VarInt 编码
    void putVar32(u32 v);
    void putVar64(u64 v);
    
    // 字符串编码
    void putUtf8(const char* v);
    void putUtf8(const char* v, u32 len);
    void putByteString(const char* v, u32 len);
    void putByteString(const char* v);
};
```

### 2.2 VarInt 编码详解

```cpp
// flightRecorder.cpp:139-160
void putVar32(u32 v) {
    while (v > 0x7f) {
        _data[_offset++] = (char)v | 0x80;  // 低 7 位 + 续位标记
        v >>= 7;
    }
    _data[_offset++] = (char)v;  // 最后一个字节无续位标记
}

void putVar64(u64 v) {
    int iter = 0;
    // 快速处理大数：每次迭代处理 3 个字节（21 位）
    while (v > 0x1fffff) {
        _data[_offset++] = (char)v | 0x80; v >>= 7;
        _data[_offset++] = (char)v | 0x80; v >>= 7;
        _data[_offset++] = (char)v | 0x80; v >>= 7;
        if (++iter == 3) return;  // 最多 9 字节（63 位）
    }
    // 处理剩余部分
    while (v > 0x7f) {
        _data[_offset++] = (char)v | 0x80;
        v >>= 7;
    }
    _data[_offset++] = (char)v;
}
```

**VarInt 编码示例：**

```
┌────────────────────────────────────────────────────────────────────────┐
│                    VarInt 编码规则                                       │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  编码规则：                                                             │
│  - 每字节高 1 位 = 1 表示"还有后续字节"                                │
│  - 每字节低 7 位 = 实际数据                                            │
│  - 小端序：低字节在前                                                  │
│                                                                        │
│  示例 1：编码 127 (0x7F)                                               │
│    127 = 0b01111111                                                   │
│    编码: 0x7F (1 字节)                                                 │
│    解码: 127                                                           │
│                                                                        │
│  示例 2：编码 128 (0x80)                                               │
│    128 = 0b0000001 0000000                                            │
│    编码: 0x80 0x01 (2 字节)                                            │
│    解码: (0x80 & 0x7F) | ((0x01 & 0x7F) << 7) = 0 | 128 = 128         │
│                                                                        │
│  示例 3：编码 300 (0x12C)                                              │
│    300 = 0b0000010 0101100                                            │
│    编码: 0xAC 0x02 (2 字节)                                            │
│    解码: (0xAC & 0x7F) | ((0x02 & 0x7F) << 7) = 44 | 256 = 300        │
│                                                                        │
│  字节数计算：                                                           │
│    0-127:       1 字节                                                 │
│    128-16383:   2 字节                                                 │
│    16384-2097151: 3 字节                                              │
│    ...                                                                 │
│    2^56-2^63-1: 9 字节                                                 │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

**六层面分析：**

| 层面 | 分析 |
|-----|------|
| **设计原理** | 空间效率优化：小数值用更少字节；网络传输友好：字节对齐 |
| **边界条件** | v=0 时输出 1 字节（0x00）；v 超过 63 位时截断 |
| **并发安全** | Buffer 是线程本地的，无需加锁 |
| **JVM 交互** | 无 |
| **性能影响** | 编码 O(log n)，解码 O(n)，n = 字节数 |
| **替代方案** | LEB128 (Little Endian Base 128)，类似但更标准 |

### 2.3 字符串编码

```cpp
// flightRecorder.cpp:162-190
void putUtf8(const char* v, u32 len) {
    put8(3);            // STRING_ENCODING_UTF8_BYTE_ARRAY = 3
    putVar32(len);      // 字符串长度
    put(v, len);        // 字符串内容
}

void putByteString(const char* v, u32 len) {
    put8(5);            // STRING_ENCODING_LATIN1_BYTE_ARRAY = 5
    putVar32(len);
    put(v, len);
}

void putUtf8(const char* v) {
    if (v == NULL) {
        put8(0);        // STRING_ENCODING_NULL = 0
    } else {
        size_t len = strlen(v);
        putUtf8(v, len < MAX_STRING_LENGTH ? len : MAX_STRING_LENGTH);
    }
}
```

**字符串编码类型：**

```
┌────────────────────────────────────────────────────────────────────────┐
│                    JFR 字符串编码类型                                    │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  编码类型 (1 字节):                                                    │
│  0x00 = NULL 字符串                                                    │
│  0x01 = 空字符串（内部 JFR 用）                                        │
│  0x02 = char[] (UTF-16, 已废弃)                                        │
│  0x03 = byte[] UTF-8                                                   │
│  0x04 = char[] (UTF-16, 已废弃)                                        │
│  0x05 = byte[] LATIN1                                                  │
│                                                                        │
│  AsyncProfiler 使用:                                                   │
│  - putUtf8(): 方法名、类名等 UTF-8 字符串                              │
│  - putByteString(): 线程名等 ASCII 字符串（更高效）                    │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 三、文件头与 Chunk 结构

### 3.1 writeHeader() 方法

```cpp
// flightRecorder.cpp:574-588
void writeHeader(Buffer* buf) {
    buf->put("FLR\0", 4);            // magic: "FLR" + null
    buf->put16(2);                   // major version: 2
    buf->put16(0);                   // minor version: 0
    buf->put64(1024 * 1024 * 1024);  // chunk size: 初始值 1GB（会被修正）
    buf->put64(0);                   // cpool offset: 会被修正
    buf->put64(0);                   // meta offset: 会被修正
    buf->put64(_start_time * 1000);  // start time: 纳秒
    buf->put64(0);                   // duration: 会被修正
    buf->put64(_start_ticks);        // start ticks: TSC 值
    buf->put64(TSC::frequency());    // ticks per second: 会被修正
    buf->put32(1);                   // features: 保留字段
}
```

**文件头布局（68 bytes）：**

```
┌──────────────────────────────────────────────────────────────────────┐
│ Offset │ Size │ Field           │ 说明                               │
├──────────────────────────────────────────────────────────────────────┤
│ 0      │ 4    │ magic           │ "FLR\0"                           │
│ 4      │ 2    │ major           │ 2                                 │
│ 6      │ 2    │ minor           │ 0                                 │
│ 8      │ 8    │ chunk_size      │ Chunk 总大小（会被修正）           │
│ 16     │ 8    │ cpool_offset    │ 常量池偏移（会被修正）             │
│ 24     │ 8    │ meta_offset     │ 元数据偏移（固定 68）              │
│ 32     │ 8    │ start_time      │ 开始时间（纳秒）                   │
│ 40     │ 8    │ duration        │ 持续时间（会被修正）               │
│ 48     │ 8    │ start_ticks     │ 开始 TSC 值                       │
│ 56     │ 8    │ ticks_per_sec   │ TSC 频率（会被修正）               │
│ 64     │ 4    │ features        │ 特性标志                          │
└──────────────────────────────────────────────────────────────────────┘
```

### 3.2 finishChunk() 方法：修正文件头

```cpp
// flightRecorder.cpp:333-386
off_t finishChunk() {
    // ... 刷新缓冲区 ...

    off_t cpool_offset = lseek(_fd, 0, SEEK_CUR);
    writeCpool(_buf);
    flush(_buf);

    off_t chunk_end = lseek(_fd, 0, SEEK_CUR);

    // Patch cpool size field
    _buf->putVar32(0, chunk_end - cpool_offset);
    ssize_t result = pwrite(_fd, _buf->data(), 5, cpool_offset);

    // 计算 TSC 频率
    u64 tsc_frequency;
    if (TSC::enabled()) {
        tsc_frequency = (u64)(double(_stop_ticks - _start_ticks) / 
                             double(_stop_time - _start_time) * 1000000);
    } else {
        tsc_frequency = TSC::frequency();
    }

    // Patch chunk header (56 bytes from offset 8)
    _buf->put64(chunk_end - _chunk_start);         // chunk size
    _buf->put64(cpool_offset - _chunk_start);      // cpool offset
    _buf->put64(68);                               // meta offset (fixed)
    _buf->put64(_start_time * 1000);               // start time
    _buf->put64((_stop_time - _start_time) * 1000);// duration
    _buf->put64(_start_ticks);                     // start ticks
    _buf->put64(tsc_frequency);                    // ticks per sec
    result = pwrite(_fd, _buf->data(), 56, _chunk_start + 8);

    return chunk_end;
}
```

**为什么需要修正？**

```
┌────────────────────────────────────────────────────────────────────────┐
│                     JFR Chunk 修正机制                                  │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  问题：写入文件头时，还不知道 Chunk 的最终大小和持续时间               │
│                                                                        │
│  解决：                                                                │
│  1. 写入文件头时，使用占位值（chunk_size=1GB, duration=0）            │
│  2. 记录 _chunk_start（当前文件位置）                                 │
│  3. 写入所有事件和常量池                                              │
│  4. 使用 pwrite() 回写正确的值：                                      │
│     - chunk_size = 实际大小                                           │
│     - cpool_offset = 常量池位置                                       │
│     - duration = 实际持续时间                                         │
│     - tsc_frequency = 实际 TSC 频率                                   │
│                                                                        │
│  注意：pwrite() 不改变文件指针位置，适合回写                          │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 四、事件记录机制

### 4.1 recordEvent() 方法：事件分发

```cpp
// flightRecorder.cpp:1424-1475
void FlightRecorder::recordEvent(int lock_index, int tid, u32 call_trace_id,
                                 EventType event_type, Event* event) {
    if (_rec != NULL) {
        ThreadLocalData::incrementSampleCounter();
        Buffer* buf = _rec->buffer(lock_index);
        
        switch (event_type) {
            case PERF_SAMPLE:
            case EXECUTION_SAMPLE:
            case INSTRUMENTED_METHOD:
                _rec->recordExecutionSample(buf, tid, call_trace_id, (ExecutionEvent*)event);
                break;
            case METHOD_TRACE:
                _rec->recordMethodTrace(buf, tid, call_trace_id, (MethodTraceEvent*)event);
                break;
            case WALL_CLOCK_SAMPLE:
                _rec->recordWallClockSample(buf, tid, call_trace_id, (WallClockEvent*)event);
                break;
            case MALLOC_SAMPLE:
                _rec->recordMallocSample(buf, tid, call_trace_id, (MallocEvent*)event);
                break;
            case ALLOC_SAMPLE:
                _rec->recordAllocationInNewTLAB(buf, tid, call_trace_id, (AllocEvent*)event);
                break;
            case ALLOC_OUTSIDE_TLAB:
                _rec->recordAllocationOutsideTLAB(buf, tid, call_trace_id, (AllocEvent*)event);
                break;
            case LIVE_OBJECT:
                _rec->recordLiveObject(buf, tid, call_trace_id, (LiveObject*)event);
                break;
            case LOCK_SAMPLE:
                _rec->recordMonitorBlocked(buf, tid, call_trace_id, (LockEvent*)event);
                break;
            case PARK_SAMPLE:
                _rec->recordThreadPark(buf, tid, call_trace_id, (LockEvent*)event);
                break;
            case NATIVE_LOCK_SAMPLE:
                _rec->recordNativeLockSample(buf, tid, call_trace_id, (NativeLockEvent*)event);
                break;
            case PROFILING_WINDOW:
                _rec->recordWindow(buf, tid, (ProfilingWindow*)event);
                break;
            case USER_EVENT:
                _rec->recordUserEvent(buf, tid, (UserEvent*)event);
                break;
        }
        _rec->flushIfNeeded(buf);
        _rec->addThread(tid);
    }
}
```

### 4.2 recordExecutionSample() 详解

```cpp
// flightRecorder.cpp:1048-1056
void recordExecutionSample(Buffer* buf, int tid, u32 call_trace_id, ExecutionEvent* event) {
    int start = buf->skip(1);  // 保留 1 字节存储事件大小
    buf->put8(T_EXECUTION_SAMPLE);           // 事件类型 ID
    buf->putVar64(event->_start_time);       // 时间戳
    buf->putVar32(tid);                      // 线程 ID
    buf->putVar32(call_trace_id);            // 调用栈 ID
    buf->putVar32(event->_thread_state);     // 线程状态
    buf->put8(start, buf->offset() - start); // 回写事件大小
}
```

**事件编码格式：**

```
┌────────────────────────────────────────────────────────────────────────┐
│                   ExecutionSample 事件格式                              │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  字节 │ 内容                │ 说明                                     │
│  ─────────────────────────────────────────────────────────────────    │
│  0    │ size                │ 事件大小（1 字节 VarInt，最大 127）      │
│  1    │ T_EXECUTION_SAMPLE  │ 事件类型 ID (VarInt, 通常 1 字节)        │
│  2+   │ start_time          │ 时间戳（VarInt，通常 5-9 字节）          │
│ 7+   │ tid                 │ 线程 ID（VarInt，通常 1-5 字节）         │
│ 8+   │ call_trace_id       │ 调用栈 ID（VarInt，通常 1-5 字节）       │
│ 9+   │ thread_state        │ 线程状态（VarInt，通常 1 字节）          │
│                                                                        │
│  典型大小：~15-30 字节/事件                                            │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

### 4.3 recordAllocationInNewTLAB() 详解

```cpp
// flightRecorder.cpp:1081-1091
void recordAllocationInNewTLAB(Buffer* buf, int tid, u32 call_trace_id, AllocEvent* event) {
    int start = buf->skip(1);
    buf->put8(T_ALLOC_IN_NEW_TLAB);
    buf->putVar64(event->_start_time);
    buf->putVar32(tid);
    buf->putVar32(call_trace_id);
    buf->putVar32(event->_class_id);        // 分配的类 ID
    buf->putVar64(event->_instance_size);   // 实例大小
    buf->putVar64(event->_total_size);      // 总大小（TLAB 批量分配）
    buf->put8(start, buf->offset() - start);
}
```

**分配事件类型：**

```
┌────────────────────────────────────────────────────────────────────────┐
│                    分配事件类型对比                                     │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  T_ALLOC_IN_NEW_TLAB (TLAB 内分配):                                   │
│  - 触发条件：对象分配在 TLAB 中                                        │
│  - 字段：class_id, instance_size, total_size                         │
│  - 说明：total_size 可能大于 instance_size（TLAB 批量分配）           │
│                                                                        │
│  T_ALLOC_OUTSIDE_TLAB (TLAB 外分配):                                  │
│  - 触发条件：大对象或 TLAB 满了                                        │
│  - 字段：class_id, total_size                                         │
│  - 说明：total_size = instance_size（单次分配）                       │
│                                                                        │
│  T_LIVE_OBJECT (存活对象):                                            │
│  - 触发条件：--live 参数开启时                                         │
│  - 字段：class_id, alloc_size, alloc_time                             │
│  - 说明：记录当前存活对象的分配信息                                   │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

### 4.4 recordMonitorBlocked() 详解

```cpp
// flightRecorder.cpp:1182-1193
void recordMonitorBlocked(Buffer* buf, int tid, u32 call_trace_id, LockEvent* event) {
    int start = buf->skip(1);
    buf->put8(T_MONITOR_ENTER);
    buf->putVar64(event->_start_time);
    buf->putVar64(event->_end_time - event->_start_time);  // 持续时间
    buf->putVar32(tid);
    buf->putVar32(call_trace_id);
    buf->putVar32(event->_class_id);       // 锁对象的类
    buf->put8(0);                          // 保留字段
    buf->putVar64(event->_address);        // 锁地址
    buf->put8(start, buf->offset() - start);
}
```

---

## 五、常量池（Constant Pool）机制

### 5.1 writeCpool() 方法

```cpp
// flightRecorder.cpp:829-856
void writeCpool(Buffer* buf) {
    buf->skip(5);  // size will be patched later
    buf->putVar32(T_CPOOL);
    buf->putVar64(_start_ticks);
    buf->putVar32(0);  // 保留
    buf->putVar32(0);  // 保留
    buf->putVar32(1);  // flush interval

    buf->putVar32(11);  // 11 种常量类型

    Index packages(1);
    Index symbols(1);
    Lookup lookup(&_method_map, Profiler::instance()->classMap(), &packages, &symbols, OUTPUT_JFR);
    
    writeFrameTypes(buf);
    writeThreadStates(buf);
    writeGCWhen(buf);
    writeThreads(buf);
    writeStackTraces(buf, &lookup);
    writeMethods(buf, &lookup);
    writeClasses(buf, &lookup);
    writePackages(buf, &lookup);
    writeSymbols(buf, &lookup);
    writeUserEventTypes(buf);
    writeLogLevels(buf);
}
```

**11 种常量类型：**

```
┌────────────────────────────────────────────────────────────────────────┐
│                     JFR 常量池类型                                      │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  1. Frame Types (帧类型)                                               │
│     - Interpreted, JIT compiled, Inlined, Native, C++, Kernel, C1     │
│                                                                        │
│  2. Thread States (线程状态)                                           │
│     - STATE_DEFAULT, STATE_RUNNABLE, STATE_SLEEPING                   │
│                                                                        │
│  3. GC When (GC 时机)                                                  │
│     - Before GC, After GC                                              │
│                                                                        │
│  4. Threads (线程信息)                                                 │
│     - OS tid, 线程名, Java 线程 ID                                     │
│                                                                        │
│  5. Stack Traces (调用栈)                                              │
│     - 调用栈 ID, 帧数量, 每帧的方法 ID + 行号 + BCI + 类型             │
│                                                                        │
│  6. Methods (方法)                                                     │
│     - 方法 ID, 类 ID, 名称索引, 签名索引, 修饰符                       │
│                                                                        │
│  7. Classes (类)                                                       │
│     - 类 ID, 类加载器, 符号索引, 包索引                                │
│                                                                        │
│  8. Packages (包)                                                      │
│     - 包 ID, 符号索引                                                  │
│                                                                        │
│  9. Symbols (符号/字符串)                                              │
│     - 符号 ID, 字符串内容                                              │
│                                                                        │
│  10. User Event Types (用户事件类型)                                   │
│      - 自定义事件类型 ID + 名称                                        │
│                                                                        │
│  11. Log Levels (日志级别)                                             │
│      - TRACE, DEBUG, INFO, WARN, ERROR                                │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

### 5.2 writeStackTraces() 详解

```cpp
// flightRecorder.cpp:937-966
void writeStackTraces(Buffer* buf, Lookup* lookup) {
    std::map<u32, CallTrace*> traces;
    Profiler::instance()->_call_trace_storage.collectTraces(traces);

    writePoolHeader(buf, T_STACK_TRACE, traces.size());
    for (auto it = traces.begin(); it != traces.end(); ++it) {
        CallTrace* trace = it->second;
        buf->putVar32(it->first);        // 调用栈 ID
        buf->putVar32(0);                // truncated (保留)
        buf->putVar32(trace->num_frames);// 帧数量
        
        for (int i = 0; i < trace->num_frames; i++) {
            MethodInfo* mi = lookup->resolveMethod(trace->frames[i]);
            buf->putVar32(mi->_key);     // 方法 ID
            
            if (mi->_type == FRAME_INTERPRETED) {
                jint bci = trace->frames[i].bci;
                FrameTypeId type = FrameType::decode(bci);
                bci = (bci & 0x10000) ? 0 : (bci & 0xffff);
                buf->putVar32(mi->getLineNumber(bci));  // 行号
                buf->putVar32(bci);                     // BCI
                buf->put8(type);                        // 帧类型
            } else {
                buf->put8(0);           // 行号 = 0
                buf->put8(0);           // BCI = 0
                buf->put8(mi->_type);   // 帧类型
            }
            flushIfNeeded(buf);
        }
    }
}
```

**调用栈编码示例：**

```
┌────────────────────────────────────────────────────────────────────────┐
│                    调用栈编码示例                                       │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  假设调用栈：                                                          │
│  java/lang/Thread.run:710                                             │
│  com/example/Worker.process:42                                        │
│  com/example/MyApp.doWork:156                                         │
│                                                                        │
│  编码输出：                                                            │
│  ┌─────────────────────────────────────────────────────────────────┐  │
│  │ call_trace_id = 1                                                │  │
│  │ truncated = 0                                                    │  │
│  │ num_frames = 3                                                   │  │
│  │ Frame[0]:                                                        │  │
│  │   method_id = 42 (MyApp.doWork)                                  │  │
│  │   line_number = 156                                              │  │
│  │   bci = 23                                                       │  │
│  │   type = FRAME_JIT_COMPILED (1)                                  │  │
│  │ Frame[1]:                                                        │  │
│  │   method_id = 67 (Worker.process)                                │  │
│  │   line_number = 42                                               │  │
│  │   bci = 15                                                       │  │
│  │   type = FRAME_JIT_COMPILED (1)                                  │  │
│  │ Frame[2]:                                                        │  │
│  │   method_id = 88 (Thread.run)                                    │  │
│  │   line_number = 710                                              │  │
│  │   bci = 8                                                        │  │
│  │   type = FRAME_INTERPRETED (0)                                   │  │
│  └─────────────────────────────────────────────────────────────────┘  │
│                                                                        │
│  事件引用：                                                            │
│  ExecutionSample { call_trace_id = 1; ... }                           │
│                      ↑                                                 │
│                      └─ 查表获取完整调用栈                             │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

### 5.3 writeMethods() 详解

```cpp
// flightRecorder.cpp:968-992
void writeMethods(Buffer* buf, Lookup* lookup) {
    MethodMap* method_map = lookup->_method_map;

    u32 marked_count = 0;
    for (auto it = method_map->begin(); it != method_map->end(); ++it) {
        if (it->second._mark) marked_count++;
    }

    writePoolHeader(buf, T_METHOD, marked_count);
    for (auto it = method_map->begin(); it != method_map->end(); ++it) {
        MethodInfo& mi = it->second;
        if (mi._mark) {
            mi._mark = false;
            buf->putVar32(mi._key);           // 方法 ID
            buf->putVar32(mi._class);         // 类 ID
            buf->putVar64(mi._name | _base_id);  // 名称索引 + base_id
            buf->putVar64(mi._sig | _base_id);   // 签名索引 + base_id
            buf->putVar32(mi._modifiers);     // 修饰符
            buf->putVar32(0);                 // hidden (保留)
            flushIfNeeded(buf);
        }
    }
}
```

**_base_id 的作用：**

```
┌────────────────────────────────────────────────────────────────────────┐
│                    _base_id 机制                                        │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  问题：多个 Chunk 可能有相同的符号索引                                 │
│  例如：Chunk 1 中 "java/lang/Object" 索引 = 1                         │
│       Chunk 2 中 "com/example/MyClass" 索引 = 1                       │
│       但它们是不同的字符串！                                           │
│                                                                        │
│  解决：每个 Chunk 有自己的 _base_id                                    │
│  Chunk 1: _base_id = 0                                                 │
│    符号索引 = 1 → 实际 ID = 1 | 0 = 1                                 │
│                                                                        │
│  Chunk 2: _base_id = 0x1000000 (16777216)                             │
│    符号索引 = 1 → 实际 ID = 1 | 0x1000000 = 16777217                  │
│                                                                        │
│  这样 JMC 解析时可以区分不同 Chunk 中的相同索引                        │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 六、并发缓冲区管理

### 6.1 多缓冲区设计

```cpp
// flightRecorder.cpp:231
RecordingBuffer _buf[CONCURRENCY_LEVEL];  // CONCURRENCY_LEVEL = 16

// flightRecorder.cpp:489-491
Buffer* buffer(int lock_index) {
    return &_buf[lock_index];
}
```

**设计原理：**

```
┌────────────────────────────────────────────────────────────────────────┐
│                    多缓冲区并发设计                                     │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  问题：多个 GC 线程同时写 JFR 事件，如何避免锁竞争？                   │
│                                                                        │
│  解决：16 个独立缓冲区，每个线程使用一个                               │
│                                                                        │
│  Thread 0 → _buf[0]  (lock_index = 0)                                 │
│  Thread 1 → _buf[1]  (lock_index = 1)                                 │
│  ...                                                                   │
│  Thread 15 → _buf[15] (lock_index = 15)                               │
│                                                                        │
│  lock_index = tid % 16                                                │
│                                                                        │
│  优点：                                                                │
│  - 无锁写入：每个线程独立缓冲区                                        │
│  - 缓存友好：线程本地数据                                              │
│  - 批量刷新：flush() 时一次性写入文件                                  │
│                                                                        │
│  缺点：                                                                │
│  - 内存占用：16 × 64KB = 1MB                                           │
│  - 浪费空间：低并发时部分缓冲区空闲                                    │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

### 6.2 flushIfNeeded() 与 flush()

```cpp
// flightRecorder.cpp:560-572
void flush(Buffer* buf) {
    ssize_t result = write(_in_memory ? _memfd : _fd, buf->data(), buf->offset());
    if (result > 0) {
        atomicInc(_bytes_written, result);
    }
    buf->reset();
}

void flushIfNeeded(Buffer* buf, int limit = RECORDING_BUFFER_LIMIT) {
    if (buf->offset() >= limit) {
        flush(buf);
    }
}

// 常量定义
const int RECORDING_BUFFER_SIZE = 65536;      // 64KB
const int RECORDING_BUFFER_LIMIT = RECORDING_BUFFER_SIZE - 4096;  // 61KB
```

**刷新策略：**

```
┌────────────────────────────────────────────────────────────────────────┐
│                    缓冲区刷新策略                                       │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  条件：buf->offset() >= 61440 (61KB)                                  │
│                                                                        │
│  触发场景：                                                            │
│  1. 每次 recordEvent() 后检查                                         │
│  2. writeStackTraces() 中每帧检查                                     │
│  3. writeMethods() 中每个方法检查                                     │
│                                                                        │
│  刷新目标：                                                            │
│  - 正常：_fd (文件描述符)                                              │
│  - IN_MEMORY 模式：_memfd (内存文件)                                  │
│                                                                        │
│  IN_MEMORY 模式优势：                                                  │
│  - 减少 disk I/O                                                       │
│  - 只在 Chunk 结束时一次性写入文件                                    │
│  - 适合高频采样场景                                                    │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 七、监控与统计

### 7.1 CPU 负载监控

```cpp
// flightRecorder.cpp:415-443
void cpuMonitorCycle() {
    if (!_cpu_monitor_enabled) return;

    CpuTimes times;
    times.proc.real = OS::getProcessCpuTime(&times.proc.user, &times.proc.system);
    times.total.real = OS::getTotalCpuTime(&times.total.user, &times.total.system);

    float proc_user = 0, proc_system = 0, machine_total = 0;

    if (times.proc.real != (u64)-1 && times.proc.real > _last_times.proc.real) {
        float delta = (times.proc.real - _last_times.proc.real) * _available_processors;
        proc_user = ratio((times.proc.user - _last_times.proc.user) / delta);
        proc_system = ratio((times.proc.system - _last_times.proc.system) / delta);
    }

    if (times.total.real != (u64)-1 && times.total.real > _last_times.total.real) {
        float delta = times.total.real - _last_times.total.real;
        machine_total = ratio(((times.total.user + times.total.system) -
                              (_last_times.total.user + _last_times.total.system)) / delta);
        if (machine_total < proc_user + proc_system) {
            machine_total = ratio(proc_user + proc_system);
        }
    }

    recordCpuLoad(&_monitor_buf, proc_user, proc_system, machine_total);
    flushIfNeeded(&_monitor_buf, SMALL_BUFFER_LIMIT);

    _last_times = times;
}
```

**CPU 负载计算：**

```
┌────────────────────────────────────────────────────────────────────────┐
│                    CPU 负载计算公式                                     │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  进程用户态 CPU % = (当前 user - 上次 user) / (当前 real - 上次 real)  │
│                    × CPU 核心数                                        │
│                                                                        │
│  进程系统态 CPU % = (当前 system - 上次 system) /                      │
│                    (当前 real - 上次 real) × CPU 核心数                │
│                                                                        │
│  整机 CPU % = ((当前 user + system) - (上次 user + system)) /          │
│               (当前 real - 上次 real)                                  │
│                                                                        │
│  ratio() 函数：限制在 [0, 1] 范围                                      │
│                                                                        │
│  数据来源：                                                            │
│  - /proc/self/stat (进程 CPU 时间)                                    │
│  - /proc/stat (整机 CPU 时间)                                         │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

### 7.2 Heap 监控

```cpp
// flightRecorder.cpp:445-452
void heapMonitorCycle(u32 gc_id) {
    if (!_heap_monitor_enabled || gc_id == _last_gc_id) return;

    recordHeapSummary(&_monitor_buf, gc_id, AFTER_GC, VM::_totalMemory(), VM::_freeMemory());
    flushIfNeeded(&_monitor_buf, SMALL_BUFFER_LIMIT);

    _last_gc_id = gc_id;
}
```

---

## 八、Chunk 切换机制

### 8.1 switchChunk() 方法

```cpp
// flightRecorder.cpp:388-404
void switchChunk() {
    _chunk_start = finishChunk();   // 完成当前 Chunk
    _start_time = _stop_time;
    _start_ticks = _stop_ticks;
    _base_id += 0x1000000;          // 增加 base_id
    _bytes_written = 0;

    writeHeader(_buf);              // 写新 Chunk 文件头
    writeMetadata(_buf);
    writeRecordingInfo(_buf);
    flush(_buf);

    if (_memfd >= 0) {
        while (ftruncate(_memfd, 0) < 0 && errno == EINTR);
        _in_memory = true;
    }
}
```

### 8.2 needSwitchChunk() 触发条件

```cpp
// flightRecorder.cpp:406-408
bool needSwitchChunk(u64 wall_time) {
    return loadAcquire(_bytes_written) >= _chunk_size || 
           wall_time - _start_time >= _chunk_time;
}
```

**Chunk 切换条件：**

```
┌────────────────────────────────────────────────────────────────────────┐
│                    Chunk 切换条件                                       │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  条件 1：大小限制                                                      │
│  - 默认：100MB (--chunksize 参数)                                      │
│  - 触发：_bytes_written >= _chunk_size                                │
│                                                                        │
│  条件 2：时间限制                                                      │
│  - 默认：3600 秒 (--chunktime 参数)                                    │
│  - 触发：wall_time - _start_time >= _chunk_time                       │
│                                                                        │
│  Chunk 切换的好处：                                                    │
│  1. 限制单个文件大小，避免文件过大                                    │
│  2. 定期刷新，减少数据丢失风险                                        │
│  3. 支持增量分析，JMC 可以只打开部分 Chunk                            │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 九、GDB 验证脚本

### 9.1 验证 JFR 文件头

```bash
# gdb_jfr_header.gdb
set pagination off

break Recording::writeHeader

commands
    printf "Writing JFR header at offset %ld\n", $buf->offset()
    
    # 继续到 header 写入完成
    continue
end

run
```

### 9.2 验证事件写入

```bash
# gdb_jfr_events.gdb
set pagination off

break Recording::recordExecutionSample

commands
    printf "Event: tid=%d, call_trace_id=%u, time=%lu\n", 
           $tid, $call_trace_id, $event->_start_time
    
    # 打印缓冲区使用情况
    printf "Buffer offset: %d\n", $buf->offset()
    
    continue
end

run
```

### 9.3 验证 Chunk 切换

```bash
# gdb_jfr_chunk.gdb
set pagination off

break Recording::switchChunk

commands
    printf "Switching chunk, _base_id = 0x%lx\n", $this->_base_id
    printf "Bytes written: %lu\n", $this->_bytes_written
    printf "Start time: %lu, Stop time: %lu\n", 
           $this->_start_time, $this->_stop_time
    
    continue
end

run
```

---

## 十、性能分析

### 10.1 空间复杂度

| 组件 | 大小 | 说明 |
|-----|------|------|
| 文件头 | 68 bytes | 固定大小 |
| Metadata | ~50KB | 事件类型定义 |
| Settings | ~5KB | 配置参数 |
| Events | 变长 | 每事件 15-50 bytes |
| CPool | 变长 | 方法/类/线程/符号表 |
| **总计** | ~10-500MB | 取决于采样次数和时长 |

### 10.2 时间复杂度

| 操作 | 时间复杂度 | 说明 |
|-----|-----------|------|
| recordEvent() | O(1) | 直接写入缓冲区 |
| flush() | O(n) | n = 缓冲区大小 |
| writeCpool() | O(m) | m = 常量数量 |
| switchChunk() | O(1) | 仅更新元数据 |

### 10.3 与其他格式对比

```
┌──────────────────────────────────────────────────────────────────────┐
│  格式        大小    写入时间  可读性  工具支持  功能完整性            │
├──────────────────────────────────────────────────────────────────────┤
│  TEXT        最小    最快     高      无        低                    │
│  COLLAPSED   小      快       中      FlameGraph 低                  │
│  FLAMEGRAPH  大      中       高      浏览器     中                   │
│  JFR         最大    最慢     低      JMC        高                   │
├──────────────────────────────────────────────────────────────────────┤
│  JFR 独有功能：                                                       │
│  - 时间线视图（按时间查看事件）                                       │
│  - 事件关联（同一时间的不同事件）                                     │
│  - 完整元数据（线程名、类名、方法签名）                               │
│  - JDK 内置事件整合（GC、类加载等）                                   │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 十一、总结

### 核心技术要点

1. **VarInt 编码**：空间效率优化，小数值用更少字节
2. **多缓冲区并发**：16 个独立缓冲区，无锁写入
3. **常量池机制**：事件引用常量 ID，减少重复存储
4. **Chunk 切换**：大小/时间限制，支持增量分析
5. **文件头回写**：pwrite() 修正动态值

### 设计亮点

- **线程本地缓冲区**：消除锁竞争，提高并发性能
- **IN_MEMORY 模式**：减少 disk I/O，适合高频采样
- **_base_id 机制**：解决多 Chunk 符号索引冲突

### 改进空间

- 可用更高效的编码（如 Protobuf）
- 可支持流式压缩（减少文件大小）
- 可支持实时流式输出（无需等待 Chunk 结束）

---

**AsyncProfiler 源码学习进度：12/12 (100%)**
