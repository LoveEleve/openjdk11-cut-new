# Lesson 8: 数据存储与输出 深度逐行解析（方法内联展开）

> 本文档对 CallTraceStorage、LinearAllocator、FlameGraph、FlightRecorder 的核心实现进行深度解析。

---

## 1. 核心数据结构概览

```
采样数据流：

信号处理程序
     │
     v
Profiler::recordSample()
     │
     ├─ StackWalker::walkVM()    // 栈回溯
     │    └─ 生成 ASGCT_CallFrame[]
     │
     └─ CallTraceStorage::put()  // 存储
          │
          ├─ calcHash()          // 计算哈希
          ├─ LongHashTable       // 哈希表查找/插入
          └─ LinearAllocator     // 线性分配器存储帧

输出阶段：

Profiler::dump()
     │
     ├─ FlameGraph::dump()       // 火焰图
     │    └─ Trie 树结构
     │
     └─ FlightRecorder::flush()  // JFR 格式
          └─ Binary Buffer
```

---

## 2. LinearAllocator（线性分配器）

### 2.1 设计原理

**为什么用线性分配器？**

```
传统分配器（malloc）：
- 每次分配需要查找空闲块
- 分配大小不确定
- 需要单独释放每个对象
- 多线程竞争严重

线性分配器：
- 只分配，不释放（直到整体重置）
- 分配大小固定（Chunk 大小）
- 只需要一个指针移动（bump pointer）
- CAS 原子操作，无锁
```

### 2.2 Chunk 结构

```cpp
// 文件: linearAllocator.h 第 12-17 行

struct Chunk {
    Chunk* prev;          // 前一个 Chunk（链表）
    volatile size_t offs; // 当前分配偏移
    // To avoid false sharing
    char _padding[56];    // 缓存行填充
};
```

**内存布局**：

```
Chunk 结构（64 bytes 头部 + 数据区）：
┌─────────────────────────────────────────────────────────────┐
│ Chunk* prev        (8 bytes)                               │
│ volatile size_t offs (8 bytes)                             │
│ char _padding[56]  (56 bytes)  <- 防止伪共享                │
├─────────────────────────────────────────────────────────────┤
│ 数据区开始                                                  │
│ offs = sizeof(Chunk) = 64                                  │
│ ...                                                         │
│ _chunk_size - 1                                             │
└─────────────────────────────────────────────────────────────┘
```

**为什么 offs 从 sizeof(Chunk) 开始？**

```
Chunk 本身占用头部空间：
- Chunk 结构体大小 = 64 bytes
- 数据区从偏移 64 开始
- offs 初始化为 64，表示"已分配到 64"
```

### 2.3 alloc() 方法（核心）

```cpp
// 文件: linearAllocator.cpp 第 41-58 行

void* LinearAllocator::alloc(size_t size) {
    Chunk* chunk = _tail;

    do {
        // Fast path: bump a pointer with CAS
        for (size_t offs = chunk->offs; offs + size <= _chunk_size; offs = chunk->offs) {
            if (__sync_bool_compare_and_swap(&chunk->offs, offs, offs + size)) {
                if (_chunk_size / 2 - offs < size) {
                    // Stepped over a middle of the chunk - it's time to prepare a new one
                    reserveChunk(chunk);
                }
                return (char*)chunk + offs;
            }
        }
    } while ((chunk = getNextChunk(chunk)) != NULL);

    return NULL;
}
```

**完全展开**：

```
alloc(size) 执行流程：

1. 获取当前 Chunk：chunk = _tail

2. 快速路径（CAS）：
   for (offs = chunk->offs; offs + size <= _chunk_size; ...) {
       // offs = 当前分配位置
       // offs + size <= _chunk_size：检查是否还有空间
       
       if (CAS(&chunk->offs, offs, offs + size)) {
           // CAS 成功：分配成功
           // 返回地址 = chunk 起始地址 + offs
           return (char*)chunk + offs;
       }
       // CAS 失败：其他线程抢先分配了，重试
   }

3. 当前 Chunk 已满：
   chunk = getNextChunk(chunk)  // 获取下一个 Chunk

4. 如果没有下一个 Chunk：
   return NULL  // 分配失败
```

**CAS 分配原理**：

```
假设 Chunk 大小 = 8KB，offs 初始 = 64

线程 A 请求 100 bytes：
  offs = 64
  CAS(&offs, 64, 64 + 100) -> 成功
  返回 chunk + 64
  offs 变成 164

线程 B 请求 200 bytes（同时）：
  offs = 64
  CAS(&offs, 64, 64 + 200) -> 失败（offs 已经是 164）
  重试：
    offs = 164
    CAS(&offs, 164, 164 + 200) -> 成功
    返回 chunk + 164
    offs 变成 364
```

### 2.4 reserveChunk()（预留 Chunk）

```cpp
// 文件: linearAllocator.cpp 第 73-79 行

void LinearAllocator::reserveChunk(Chunk* current) {
    Chunk* reserve = allocateChunk(current);
    if (reserve != NULL && !__sync_bool_compare_and_swap(&_reserve, current, reserve)) {
        // Unlikely case that we are too late
        freeChunk(reserve);
    }
}
```

**预分配策略**：

```
为什么需要预留 Chunk？

问题：
  - 当前 Chunk 快满时，需要分配新 Chunk
  - allocateChunk() 涉及系统调用（mmap），耗时较长
  - 在分配期间，其他线程可能也需要分配

解决：
  - 当 offs 超过 Chunk 一半时，提前预留下一个 Chunk
  - 预留的 Chunk 存储在 _reserve 中
  - 当需要新 Chunk 时，直接使用预留的
```

### 2.5 getNextChunk()（获取下一个 Chunk）

```cpp
// 文件: linearAllocator.cpp 第 81-103 行

Chunk* LinearAllocator::getNextChunk(Chunk* current) {
    Chunk* reserve = _reserve;

    if (reserve == current) {
        // Unlikely case: no reserve yet.
        // It's probably being allocated right now, so let's compete
        reserve = allocateChunk(current);
        if (reserve == NULL) {
            // Not enough memory
            return NULL;
        }

        Chunk* prev_reserve = __sync_val_compare_and_swap(&_reserve, current, reserve);
        if (prev_reserve != current) {
            freeChunk(reserve);
            reserve = prev_reserve;
        }
    }

    // Expected case: a new chunk is already reserved
    Chunk* tail = __sync_val_compare_and_swap(&_tail, current, reserve);
    return tail == current ? reserve : tail;
}
```

**场景分析**：

```
场景 1：正常情况（预留已就绪）
  _reserve = 新 Chunk
  _tail = 旧 Chunk（已满）
  
  getNextChunk()：
    reserve = _reserve（已就绪）
    CAS(&_tail, current, reserve)  // 原子更新
    返回 reserve

场景 2：预留未就绪（竞争）
  _reserve = current（指向当前 Chunk，表示未预留）
  
  getNextChunk()：
    多个线程同时调用 allocateChunk()
    只有一个能成功 CAS 更新 _reserve
    其他线程释放多余的 Chunk，使用成功者的 Chunk
```

---

## 3. CallTraceStorage（调用栈存储）

### 3.1 核心数据结构

```cpp
// 文件: callTraceStorage.h 第 18-42 行

struct CallTrace {
    int num_frames;           // 帧数量
    ASGCT_CallFrame frames[1]; // 帧数组（变长）
};

struct CallTraceSample {
    CallTrace* trace;  // 指向 CallTrace
    u64 samples;       // 采样次数
    u64 counter;       // 累计值
};

class CallTraceStorage {
  private:
    LinearAllocator _allocator;     // 线性分配器
    LongHashTable* _current_table;  // 当前哈希表
    u64 _overflow;                  // 溢出计数
};
```

### 3.2 LongHashTable（开放寻址哈希表）

```cpp
// 文件: callTraceStorage.cpp 第 17-80 行

class LongHashTable {
  private:
    LongHashTable* _prev;   // 前一个表（扩容链）
    u32 _capacity;          // 容量
    volatile u32 _size;     // 当前大小
    
    static size_t getSize(u32 capacity) {
        // 表头 + keys 数组 + values 数组
        return sizeof(LongHashTable) + 
               (sizeof(u64) + sizeof(CallTraceSample)) * capacity;
    }

  public:
    u64* keys() {
        return (u64*)(this + 1);  // 紧跟表头
    }

    CallTraceSample* values() {
        return (CallTraceSample*)(keys() + _capacity);  // 紧跟 keys
    }
};
```

**内存布局**：

```
LongHashTable（capacity = 65536）：
┌─────────────────────────────────────────────────────────────┐
│ LongHashTable 头部                                          │
│   LongHashTable* _prev                                      │
│   u32 _capacity = 65536                                     │
│   volatile u32 _size                                        │
├─────────────────────────────────────────────────────────────┤
│ u64 keys[65536]                                             │
│   keys[0] = hash1 或 0（空）                                │
│   keys[1] = hash2 或 0                                      │
│   ...                                                       │
│   keys[65535] = hashN                                       │
├─────────────────────────────────────────────────────────────┤
│ CallTraceSample values[65536]                               │
│   values[0] = {trace, samples, counter}                     │
│   values[1] = {trace, samples, counter}                     │
│   ...                                                       │
│   values[65535] = {trace, samples, counter}                 │
└─────────────────────────────────────────────────────────────┘

总大小 ≈ 64KB + 512KB + 1.5MB ≈ 2MB
```

### 3.3 put() 方法（核心）

```cpp
// 文件: callTraceStorage.cpp 第 233-281 行

u32 CallTraceStorage::put(int num_frames, ASGCT_CallFrame* frames, u64 counter) {
    u64 hash = calcHash(num_frames, frames);  // 1. 计算哈希

    LongHashTable* table = _current_table;
    u64* keys = table->keys();
    u32 capacity = table->capacity();
    u32 slot = hash & (capacity - 1);  // 2. 计算槽位
    u32 step = 0;

    while (keys[slot] != hash) {
        if (keys[slot] == 0) {
            // 3. 空槽位，尝试插入
            if (!__sync_bool_compare_and_swap(&keys[slot], 0, hash)) {
                continue;  // CAS 失败，重试
            }

            // 4. 检查是否需要扩容
            if (table->incSize() == capacity * 3 / 4) {
                LongHashTable* new_table = LongHashTable::allocate(table, capacity * 2);
                if (new_table != NULL) {
                    __sync_bool_compare_and_swap(&_current_table, table, new_table);
                }
            }

            // 5. 存储 CallTrace
            CallTrace* trace = table->prev() == NULL ? NULL : findCallTrace(table->prev(), hash);
            if (trace == NULL) {
                trace = storeCallTrace(num_frames, frames);
            }
            table->values()[slot].setTrace(trace);
            break;
        }

        // 6. 线性探测
        if (++step >= capacity) {
            atomicInc(_overflow);
            return OVERFLOW_TRACE_ID;
        }
        slot = (slot + step) & (capacity - 1);
    }

    // 7. 更新计数器
    if (counter != 0) {
        CallTraceSample& s = table->values()[slot];
        atomicInc(s.samples);
        atomicInc(s.counter, counter);
    }

    return capacity - (INITIAL_CAPACITY - 1) + slot;
}
```

**完全展开执行流程**：

```
put(num_frames, frames, counter):

[1] 计算哈希
    hash = MurmurHash64A(frames, num_frames * sizeof(ASGCT_CallFrame))

[2] 计算初始槽位
    slot = hash & (capacity - 1)
    // capacity 是 2 的幂，所以 capacity - 1 是掩码

[3] 开放寻址查找
    while (keys[slot] != hash) {
        if (keys[slot] == 0) {
            // 找到空槽位
            CAS(&keys[slot], 0, hash)  // 原子插入
            break;
        }
        // 冲突，线性探测
        slot = (slot + ++step) & (capacity - 1)
    }

[4] 插入新调用栈
    if (是新槽位) {
        // 检查扩容（负载因子 0.75）
        if (size == capacity * 3/4) {
            allocate new table with capacity * 2
        }
        
        // 存储帧数据
        trace = LinearAllocator::alloc(
            sizeof(CallTrace) + num_frames * sizeof(ASGCT_CallFrame)
        )
        trace->num_frames = num_frames
        memcpy(trace->frames, frames, ...)
    }

[5] 更新计数
    atomicInc(samples)
    atomicInc(counter, value)

[6] 返回 ID
    return call_trace_id
```

### 3.4 calcHash()（MurmurHash64A）

```cpp
// 文件: callTraceStorage.cpp 第 170-199 行

u64 CallTraceStorage::calcHash(int num_frames, ASGCT_CallFrame* frames) {
    const u64 M = 0xc6a4a7935bd1e995ULL;
    const int R = 47;

    int len = num_frames * sizeof(ASGCT_CallFrame);
    u64 h = len * M;

    const u64* data = (const u64*)frames;
    const u64* end = data + len / 8;

    while (data != end) {
        u64 k = *data++;
        k *= M;
        k ^= k >> R;
        k *= M;
        h ^= k;
        h *= M;
    }

    if (len & 4) {
        h ^= *(u32*)data;
        h *= M;
    }

    h ^= h >> R;
    h *= M;
    h ^= h >> R;

    return h;
}
```

**MurmurHash 算法特点**：
- 快速：只需简单的位运算和乘法
- 均匀：哈希分布均匀，冲突率低
- 确定性：相同输入产生相同输出

---

## 4. FlameGraph（火焰图）

### 4.1 Trie 树结构

```cpp
// 文件: flameGraph.h 第 17-68 行

class Trie {
  public:
    std::map<u32, Trie*> _children;  // 子节点
    u64 _total;      // 总计值
    u64 _self;       // 自身值
    u64 _inlined;    // 内联帧计数
    u64 _c1_compiled;  // C1 编译计数
    u64 _interpreted;  // 解释执行计数

    FrameTypeId type(u32 key) const {
        if (_inlined * 3 >= _total) {
            return FRAME_INLINED;
        } else if (_c1_compiled * 2 >= _total) {
            return FRAME_C1_COMPILED;
        } else if (_interpreted * 2 >= _total) {
            return FRAME_INTERPRETED;
        } else {
            return (FrameTypeId)(key >> 28);
        }
    }

    u32 nameIndex(u32 key) const {
        return key & ((1 << 28) - 1);  // 低 28 位是名称索引
    }

    Trie* child(u32 name_index, FrameTypeId type) {
        u32 key = name_index | (type << 28);  // 组合键
        Trie** ptr = &_children[key];
        if (*ptr == nullptr) {
            *ptr = new Trie();
        }
        return *ptr;
    }
};
```

**Trie 树结构**：

```
调用栈 1: A -> B -> C
调用栈 2: A -> B -> D
调用栈 3: A -> E

Trie 树：
                    root
                     │
                     A (total=3)
                    / \
                   B   E (total=1)
                   │
                   C (total=1)  D (total=1)
                   
每个节点记录：
  _total: 经过该节点的所有采样
  _self: 在该节点结束的采样
  _inlined/_interpreted: 不同编译类型的采样
```

### 4.2 addChild() 方法

```cpp
// 文件: flameGraph.cpp 第 87-112 行

Trie* FlameGraph::addChild(Trie* f, const char* name, FrameTypeId type, u64 value) {
    size_t len = strlen(name);
    bool has_suffix = len > 4 && name[len - 4] == '_' && name[len - 3] == '[' && name[len - 1] == ']';
    std::string s(name, has_suffix ? len - 4 : len);
    // 处理后缀如 "_[j]" (JIT 编译) "_[i]" (内联) 等

    u32 name_index = _cpool[s];
    if (name_index == 0) {
        name_index = _cpool[s] = _cpool.size();
    }

    f->_total += value;

    switch (type) {
        case FRAME_INLINED:
            (f = f->child(name_index, FRAME_JIT_COMPILED))->_inlined += value;
            return f;
        case FRAME_C1_COMPILED:
            (f = f->child(name_index, FRAME_JIT_COMPILED))->_c1_compiled += value;
            return f;
        case FRAME_INTERPRETED:
            (f = f->child(name_index, FRAME_JIT_COMPILED))->_interpreted += value;
            return f;
        default:
            return f->child(name_index, type);
    }
}
```

**后缀处理**：

```
原始帧名：java/lang/Object.hashCode_[j]
处理逻辑：
  has_suffix = true  // "_[j]"
  s = "java/lang/Object.hashCode"  // 去掉后缀

后缀类型：
  _[j]: JIT compiled
  _[i]: Inlined
  _[k]: C1 compiled (tier 1-3)
  _[g]: Generated
  _[n]: Native
```

### 4.3 printFrame()（输出帧数据）

```cpp
// 文件: flameGraph.cpp 第 172-220 行

void FlameGraph::printFrame(Writer& out, u32 key, const Trie& f, int level, u64 x) {
    u32 name_and_type = _name_order[f.nameIndex(key)] << 3 | f.type(key);
    bool has_extra_types = (f._inlined | f._c1_compiled | f._interpreted) &&
                           f._inlined < f._total && f._interpreted < f._total;

    char* p = _buf;
    // 压缩输出格式
    if (level == _last_level + 1 && x == _last_x) {
        p += snprintf(p, 100, "u(%u", name_and_type);  // 子节点
    } else if (level == _last_level && x == _last_x + _last_total) {
        p += snprintf(p, 100, "n(%u", name_and_type);  // 兄弟节点
    } else {
        p += snprintf(p, 100, "f(%u,%d,%llu", name_and_type, level, x - _last_x);  // 新帧
    }

    // ...
}
```

**压缩格式**：

```
火焰图数据格式：

f(name, level, x)    // 新帧：名称、层级、x 坐标
u(name)              // 子帧：继承父帧的 x 和 level+1
n(name)              // 兄弟帧：继承前一个帧的 level，x + total

示例输出：
f(1,0,0,100)         // 根帧，x=0, width=100
u(2)                 // 子帧，自动继承
n(3)                 // 兄弟帧
u(4)                 // 子帧

压缩效果：
  原始：每个帧需要 name + level + x + width
  压缩后：大多数帧只需要 name
```

---

## 5. FlightRecorder（JFR 格式）

### 5.1 Buffer 类

```cpp
// 文件: flightRecorder.cpp 第 77-200 行

class Buffer {
  private:
    int _offset;
    char _data[0];  // 柔性数组

  public:
    void put8(char v) {
        _data[_offset++] = v;
    }

    void put16(short v) {
        *(short*)(_data + _offset) = htons(v);  // 网络字节序
        _offset += 2;
    }

    void put32(int v) {
        *(int*)(_data + _offset) = htonl(v);
        _offset += 4;
    }

    void put64(u64 v) {
        *(u64*)(_data + _offset) = OS::hton64(v);
        _offset += 8;
    }

    void putVar32(u32 v) {
        while (v > 0x7f) {
            _data[_offset++] = (char)v | 0x80;  // 变长编码
            v >>= 7;
        }
        _data[_offset++] = (char)v;
    }

    void putVar64(u64 v) {
        // 类似 putVar32，但处理 64 位
    }
};
```

**变长编码原理**：

```
putVar32(300)：
  300 = 0b100101100
  第 1 字节：0b10101100 | 0x80 = 0xAC  // 低 7 位 + 继续标志
  第 2 字节：0b00000010 = 0x02          // 剩余位

编码结果：AC 02 (2 bytes)

putVar32(100)：
  100 = 0b1100100
  100 <= 0x7f，单字节
  编码结果：64 (1 byte)

优势：
  - 小数值用更少字节
  - 适合存储计数器、时间戳等
```

### 5.2 JFR 事件格式

```cpp
// 文件: flightRecorder.cpp 第 1069-1079 行

void recordWallClockSample(Buffer* buf, int tid, u32 call_trace_id, WallClockEvent* event) {
    int start = buf->skip(1);  // 保留 1 字节存大小
    buf->put8(T_WALL_CLOCK_SAMPLE);      // 事件类型
    buf->putVar64(event->_start_time);   // 开始时间
    buf->putVar32(tid);                  // 线程 ID
    buf->putVar32(call_trace_id);        // 调用栈 ID
    buf->putVar32(event->_thread_state); // 线程状态
    buf->putVar32(event->_samples);      // 样本数
    buf->putVar64(event->_time_span);    // 时间跨度
    buf->put8(start, buf->offset() - start);  // 回填事件大小
}
```

**JFR 文件格式**：

```
JFR 文件结构：
┌─────────────────────────────────────────────────────────────┐
│ 文件头（Magic + Version + Size）                            │
├─────────────────────────────────────────────────────────────┤
│ 元数据（Metadata）                                          │
│   - 事件类型定义                                            │
│   - 字段定义                                                │
│   - 字符串池                                                │
├─────────────────────────────────────────────────────────────┤
│ 事件数据                                                    │
│   - ExecutionSample                                         │
│   - WallClockSample                                         │
│   - AllocSample                                             │
│   - ...                                                     │
├─────────────────────────────────────────────────────────────┤
│ 检查点（Checkpoint）                                         │
│   - 线程信息                                                │
│   - 方法信息                                                │
│   - 类信息                                                  │
└─────────────────────────────────────────────────────────────┘
```

---

## 6. 完整数据流图

```
采样触发
    │
    v
┌─────────────────────────────────────────────────────────────┐
│ Profiler::recordSample(ucontext, counter, event_type, event)│
│                                                             │
│ [1] 栈回溯                                                  │
│     StackWalker::walkVM()                                   │
│         ├─ 解释器帧解析                                     │
│         ├─ JIT 帧解析                                       │
│         └─ Native 帧解析                                    │
│     返回：ASGCT_CallFrame frames[MAX_FRAMES]                │
│                                                             │
│ [2] 存储调用栈                                              │
│     CallTraceStorage::put(num_frames, frames, counter)      │
│         ├─ calcHash() -> u64 hash                           │
│         ├─ LongHashTable 查找/插入                          │
│         └─ LinearAllocator::alloc() 存储 CallTrace          │
│     返回：u32 call_trace_id                                 │
│                                                             │
│ [3] 记录事件                                                │
│     FlightRecorder::recordEvent(lock_index, tid, ...)       │
│         └─ Buffer::putVar64/putVar32() 写入 JFR            │
└─────────────────────────────────────────────────────────────┘
    │
    v
采样结束，数据已存储
    │
    v
┌─────────────────────────────────────────────────────────────┐
│ Profiler::dump()                                            │
│                                                             │
│ [1] 收集数据                                                │
│     CallTraceStorage::collectSamples()                      │
│         └─ 遍历 LongHashTable                               │
│                                                             │
│ [2] 构建火焰图                                              │
│     FlameGraph::addChild() 循环                             │
│         ├─ 遍历所有 CallTrace                               │
│         └─ 构建 Trie 树                                     │
│                                                             │
│ [3] 输出                                                    │
│     FlameGraph::dump()                                      │
│         ├─ printFrame() 输出帧数据                          │
│         └─ printCpool() 输出字符串池                        │
│                                                             │
│     或                                                      │
│                                                             │
│     FlightRecorder::flush()                                 │
│         └─ 输出 JFR 二进制格式                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 7. 性能分析

### 7.1 LinearAllocator 性能

| 操作 | 时间复杂度 | 备注 |
|-----|-----------|------|
| alloc() | O(1) amortized | CAS + bump pointer |
| 多线程分配 | 无锁 | CAS 原子操作 |
| 内存浪费 | ~50% | 最后一个 Chunk 可能未用完 |

### 7.2 CallTraceStorage 性能

| 操作 | 时间复杂度 | 备注 |
|-----|-----------|------|
| put() | O(1) average | 哈希查找 + CAS |
| 扩容 | O(n) | 但摊销到每次操作 |
| 内存使用 | O(unique traces) | 只存储唯一调用栈 |

### 7.3 火焰图构建性能

| 操作 | 时间复杂度 | 备注 |
|-----|-----------|------|
| addChild() | O(depth) | 树深度 |
| dump() | O(nodes) | 遍历所有节点 |
| 输出压缩 | ~50% | u/n 格式 |
