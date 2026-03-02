# Lesson 9 续二：错误恢复策略与 JFR 事件写入深度解析

> 本文档深入分析 AsyncGetCallTrace 失败时的错误恢复策略，以及 JFR 二进制格式的编码实现。

---

## 14. AsyncGetCallTrace 错误恢复策略

### 14.1 错误码概述

```cpp
// AsyncGetCallTrace 可能返回的错误码
enum ASGCT_FailureTypes {
    ticks_no_Java_frame         = -1,  // 没有 Java 帧
    ticks_no_class_load         = -2,  // 类未加载
    ticks_gc_active             = -3,  // GC 活动
    ticks_unknown_Java          = -4,  // 未知 Java 帧
    ticks_not_walkable_Java     = -5,  // 不可遍历 Java 帧
    ticks_unknown_not_Java      = -6,  // 未知非 Java 帧
    ticks_not_walkable_not_Java = -7,  // 不可遍历非 Java 帧
    ticks_deopt                 = -8,  // 反优化
    ticks_safepoint             = -9,  // Safepoint
    ticks_skipped               = -10, // 跳过
    ticks_thread_exit           = -11, // 线程退出
    ticks_unknown_state         = -12, // 未知状态
};
```

### 14.2 ticks_unknown_Java / ticks_not_walkable_Java 恢复

**问题场景**：当前 PC 指向 JVM 运行时 Stub，AsyncGetCallTrace 无法识别。

```cpp
// 文件: profiler.cpp 第 427-451 行
if ((trace.num_frames == ticks_unknown_Java || 
     trace.num_frames == ticks_not_walkable_Java) && 
    _features.unknown_java && ucontext != NULL) {
    
    // [步骤 1] 查找 Runtime Stub
    CodeBlob* stub = NULL;
    _stubs_lock.lockShared();
    if (_runtime_stubs.contains((const void*)frame.pc())) {
        stub = findRuntimeStub((const void*)frame.pc());
    }
    _stubs_lock.unlockShared();

    if (stub != NULL) {
        // [步骤 2] 特殊处理 vtable stub
        if (_features.vtable_target && isVTableStub(stub->_name)) {
            uintptr_t receiver = frame.jarg0();
            // jarg0() 展开为：
            //   return (uintptr_t)REG(RDI, rdi);
            //   即读取 RDI 寄存器（第一个参数）
            
            if (receiver != 0) {
                // receiver 是对象的 this 指针
                // 从对象头获取 klass
                VMSymbol* symbol = VMKlass::fromOop(receiver)->name();
                u32 class_id = classMap()->lookup(symbol->body(), symbol->length());
                max_depth -= makeFrame(trace.frames++, BCI_ALLOC, class_id);
            }
        }
        
        // [步骤 3] 添加 Stub 帧
        max_depth -= makeFrame(trace.frames++, BCI_NATIVE_FRAME, stub->_name);
        
        // [步骤 4] 尝试手动展开 Stub
        if (_features.unwind_stub && 
            frame.unwindStub((instruction_t*)stub->_start, stub->_name) &&
            isAddressInCode((const void*)frame.pc())) {
            
            java_ctx->pc = (const void*)frame.pc();
            VM::_asyncGetCallTrace(&trace, max_depth, ucontext);
        }
    }
```

#### 14.2.1 vtable stub 解析展开

```cpp
// 展开步骤 1: 什么是 vtable stub？
// JVM 为虚方法调用生成的 Stub
// 格式: "vtable stub[N]" 或 "itable stub[N]"
// N 是 vtable 索引

// 展开步骤 2: vtable stub 的汇编结构
// (以 vtable stub 为例)
//
//   mov    rax, [rdi + 0x8]     ; 获取对象的 klass 指针
//   mov    rbx, [rax + offset]  ; 从 vtable 获取方法
//   mov    rax, [rbx + method_offset] ; 获取 Method*
//   jmp    [rax]                ; 跳转到方法入口
//
// RDI 寄存器包含 this 指针（第一个参数）

// 展开步骤 3: frame.jarg0() 实现
// 文件: stackFrame_x64.cpp 第 59-61 行
uintptr_t StackFrame::jarg0() {
    return arg1();  // 注意：返回 arg1，不是 arg0
}

uintptr_t StackFrame::arg1() {
    return (uintptr_t)REG(RSI, rsi);
}

// 为什么是 RSI 而不是 RDI？
// JVM 的调用约定：
//   - RDI: JNIEnv* (JNI 调用时)
//   - RSI: receiver (this 指针)
// 所以 jarg0() 实际返回的是 receiver
```

#### 14.2.2 unwindStub() 展开

```cpp
// 展开步骤 1: unwindStub 实现
// 文件: stackFrame_x64.cpp 第 77-100 行
bool StackFrame::unwindStub(instruction_t* entry, const char* name, 
                           uintptr_t& pc, uintptr_t& sp, uintptr_t& fp) {
    instruction_t* ip = (instruction_t*)pc;
    
    // [情况 1] PC 等于入口，或碰到 ret 指令
    if (ip == entry || *ip == 0xc3
        || strncmp(name, "itable", 6) == 0
        || strncmp(name, "vtable", 6) == 0
        || strcmp(name, "InlineCacheBuffer") == 0)
    {
        // 从栈中获取返回地址
        pc = ((uintptr_t*)sp)[0] - 1;  // -1 因为返回地址指向调用后
        sp += 8;
        return true;
    }
    
    // [情况 2] Stub 以标准函数序言开始
    //   push rbp       ; 字节码: 0x55
    //   mov  rbp, rsp  ; 字节码: 0x48 0x89 0xec
    // 组合值: 0xec8b4855
    else if (entry != NULL && *(unsigned int*)entry == 0xec8b4855) {
        if (ip == entry + 1) {
            // PC 在 push rbp 之后
            pc = ((uintptr_t*)sp)[1] - 1;
            sp += 16;
            return true;
        } else if (withinCurrentStack(fp)) {
            // 标准帧展开
            sp = fp + 16;
            fp = ((uintptr_t*)sp)[-2];
            pc = ((uintptr_t*)sp)[-1] - 1;
            return true;
        }
    }
    
    return false;
}

// 展开步骤 2: 为什么 PC 要 -1？
// 返回地址指向调用指令的下一条指令
// 例如：
//   0x1000: call func
//   0x1005: ...        <- 返回地址
// 
// 返回地址 = 0x1005，但调用者是 0x1000
// PC - 1 = 0x1004，仍然在调用指令范围内
// 这样在查找符号时能正确定位到调用者
```

#### 14.2.3 六层面分析

| 层面 | 分析 |
|------|------|
| **设计原理** | 为什么需要手动展开 Stub？<br>AsyncGetCallTrace 只认识标准的 Java 帧，不认识 JVM 生成的 Stub。如果不处理，这些帧会丢失。 |
| **边界条件** | 如果 unwindStub 失败怎么办？<br>返回错误帧 "unknown_Java" 或 "not_walkable_Java"，让用户知道发生了什么。 |
| **并发安全** | `_runtime_stubs` 的查找使用读锁。允许多线程同时读取。 |
| **JVM 交互** | `isVTableStub()` 检测 Stub 类型。`VMKlass::fromOop()` 从对象获取类信息。 |
| **性能影响** | 展开 Stub 约 100-200 周期。只有失败时才执行，总体开销小。 |
| **替代方案** | 不处理 Stub？<br>问题：会丢失大量调用信息，尤其是虚方法调用。 |

---

### 14.3 ticks_unknown_not_Java 恢复（JavaFrameAnchor）

**问题场景**：线程在 Native 代码中，但最近调用过 Java 方法。AsyncGetCallTrace 返回 "unknown_not_Java"。

```cpp
// 文件: profiler.cpp 第 485-508 行
else if (trace.num_frames == ticks_unknown_not_Java && _features.java_anchor) {
    JavaFrameAnchor* anchor = vm_thread->anchor();
    uintptr_t sp = anchor->lastJavaSP();
    const void* pc = anchor->lastJavaPC();
    
    if (sp != 0 && pc == NULL) {
        // [步骤 1] 有 lastJavaSP，但 lastJavaPC 为空
        // 这意味着 JVM 还没来得及设置 PC
        // 我们手动从栈中获取 PC
        
        pc = ((const void**)sp)[-1];  // 栈顶保存返回地址
        anchor->setLastJavaPC(pc);    // 临时设置，让 AGCT 能工作

        NMethod* m = CodeHeap::findNMethod(pc);
        if (m != NULL) {
            // [步骤 2] 检查是否是 Runtime Stub 且 frame_complete_offset 无效
            if (!m->isNMethod() && m->frameSize() > 0 && m->frameCompleteOffset() == -1) {
                // AGCT 需要 frame_complete_offset 来判断帧是否完整
                // 某些 Stub 可能没有设置这个字段
                // 我们手动设置为 0（表示"帧从一开始就是完整的"）
                m->setFrameCompleteOffset(0);
            }
            
            // [步骤 3] 重新调用 AGCT
            VM::_asyncGetCallTrace(&trace, max_depth, ucontext);
        } else if (findLibraryByAddress(pc) != NULL) {
            // PC 在 Native 库中
            VM::_asyncGetCallTrace(&trace, max_depth, ucontext);
        }

        // [步骤 4] 恢复状态
        anchor->setLastJavaPC(NULL);
    }
}
```

#### 14.3.1 JavaFrameAnchor 结构

```cpp
// 展开步骤 1: JavaFrameAnchor 在 JVM 中的作用
// 文件: hotspot/share/runtime/thread.hpp
class JavaFrameAnchor {
  private:
    volatile intptr_t* _last_Java_sp;  // 最后一个 Java 帧的 SP
    volatile address   _last_Java_pc;  // 最后一个 Java 帧的 PC（可能为空）
    
    // 当线程从 Java 进入 Native 时：
    // 1. 保存当前 SP 到 _last_Java_sp
    // 2. _last_Java_pc 暂时为空（或指向某个已知位置）
    // 3. 当需要 GC 或栈回溯时，JVM 会计算 PC
};

// 展开步骤 2: 为什么 lastJavaPC 可能为空？
// 
// Java 调用 Native 的典型流程：
// 
//   Java: foo() {
//       nativeMethod();  // JNI 调用
//   }
// 
//   Native: nativeMethod() {
//       // 执行到这里时：
//       // - lastJavaSP 指向 foo() 的帧
//       // - lastJavaPC = NULL（还没设置）
//       // 
//       // 如果此时收到信号，AGCT 无法确定 PC
//   }
// 
// AsyncProfiler 的解决方案：
//   从 lastJavaSP 指向的位置向上找返回地址
```

#### 14.3.2 frame_complete_offset 问题

```cpp
// 展开步骤 1: 什么是 frame_complete_offset？
// NMethod（JIT 编译的方法）中的一个字段
// 表示"从哪个指令开始，帧结构已经完整"
// 
// 例如：
//   0x1000: sub rsp, 0x100    ; 分配栈空间
//   0x1007: mov [rbp+...], ...; 保存寄存器
//   0x1020: ...               ; frame_complete_offset 指向这里
// 
// 在 0x1000-0x1020 之间，帧结构不完整
// AGCT 如果尝试回溯，可能失败

// 展开步骤 2: 为什么某些 Stub 没有设置？
// Runtime Stub 是 JVM 生成的汇编代码
// 某些情况下，生成代码时没有设置这个字段
// 导致 AGCT 失败

// 展开步骤 3: setFrameCompleteOffset(0) 的含义
// 设置为 0 表示"帧从一开始就是完整的"
// 这是一种假设，但在实践中对大多数 Stub 有效
```

---

## 15. JFR 二进制格式编码

### 15.1 Buffer 类结构

```cpp
// 文件: flightRecorder.cpp 第 77-203 行
class Buffer {
  private:
    int _offset;     // 当前写入位置
    char _data[0];   // 柔性数组：数据区

  public:
    // [基本写入方法]
    void put8(char v) {
        _data[_offset++] = v;
    }

    void put16(short v) {
        *(short*)(_data + _offset) = htons(v);  // 网络字节序（大端）
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
};
```

### 15.2 变长编码（VarInt）

```cpp
// 文件: flightRecorder.cpp 第 139-160 行
void putVar32(u32 v) {
    while (v > 0x7f) {
        _data[_offset++] = (char)v | 0x80;  // 低 7 位 + 继续标志
        v >>= 7;
    }
    _data[_offset++] = (char)v;             // 最后一个字节
}

void putVar64(u64 v) {
    int iter = 0;
    // 前 3 次迭代使用 21 位
    while (v > 0x1fffff) {
        _data[_offset++] = (char)v | 0x80; v >>= 7;
        _data[_offset++] = (char)v | 0x80; v >>= 7;
        _data[_offset++] = (char)v | 0x80; v >>= 7;
        if (++iter == 3) return;
    }
    // 剩余部分使用 7 位
    while (v > 0x7f) {
        _data[_offset++] = (char)v | 0x80;
        v >>= 7;
    }
    _data[_offset++] = (char)v;
}
```

#### 15.2.1 变长编码原理

```
Var32 编码示例：

值 = 300 = 0b100101100

编码过程：
  v = 300 > 0x7f (127)
  byte1 = 300 & 0x7f | 0x80 = 0x2c | 0x80 = 0xAC
  v = 300 >> 7 = 2
  
  v = 2 <= 0x7f
  byte2 = 2 = 0x02
  
结果：AC 02（2 字节）

解码过程：
  byte1 = 0xAC = 0b10101100
  继续 = byte1 & 0x80 = 0x80 != 0
  value = byte1 & 0x7f = 0x2c = 44
  
  byte2 = 0x02 = 0b00000010
  继续 = byte2 & 0x80 = 0
  value = 44 | (2 << 7) = 44 | 256 = 300

编码大小对比：
  值范围            字节数
  0-127            1
  128-16383        2
  16384-2097151    3
  2097152-268435455 4

优点：小数值用更少字节，节省空间
```

#### 15.2.2 Var64 优化

```
Var64 编码优化：

问题：64 位值如果用简单的 7 位编码：
  最大 10 字节（64/7 ≈ 9.14）

优化策略：
  前 3 次迭代，每次处理 21 位（3 字节）
  后续迭代，每次处理 7 位

为什么是 21 位？
  21 位刚好是 3 个 7 位
  可以减少循环次数

编码示例（大值）：
  值 = 0x123456789ABCDEF0

  第一次迭代（21 位）：
    byte1 = v & 0x7f | 0x80
    byte2 = (v >> 7) & 0x7f | 0x80
    byte3 = (v >> 14) & 0x7f | 0x80
    v >>= 21
  
  第二次迭代（21 位）：...
  
  第三次迭代（21 位）：...
  
  剩余部分（7 位）：...
```

### 15.3 JFR 事件写入

```cpp
// 简化的事件写入示例
void recordExecutionSample(Buffer* buf, int tid, u32 call_trace_id) {
    int start = buf->skip(1);  // 保留 1 字节存大小
    
    buf->put8(T_EXECUTION_SAMPLE);       // 事件类型
    buf->putVar64(OS::nanotime());       // 时间戳
    buf->putVar32(tid);                  // 线程 ID
    buf->putVar32(call_trace_id);        // 调用栈 ID
    buf->putVar32(0);                    // 状态
    
    buf->put8(start, buf->offset() - start);  // 回填大小
}
```

#### 15.3.1 JFR 事件格式

```
JFR 事件二进制格式：

┌─────────────────────────────────────────────────────────────┐
│ 事件头                                                       │
│   size (1 byte): 事件总大小（变长）                          │
│   type (1 byte): 事件类型                                    │
├─────────────────────────────────────────────────────────────┤
│ 事件体                                                       │
│   timestamp (var64): 事件时间戳                              │
│   thread_id (var32): 线程 ID                                 │
│   call_trace_id (var32): 调用栈 ID                          │
│   ... (其他字段，取决于事件类型)                             │
└─────────────────────────────────────────────────────────────┘

事件类型：
  T_EXECUTION_SAMPLE   = 0: CPU 采样
  T_ALLOC_SAMPLE       = 1: 对象分配
  T_ALLOC_OUTSIDE_TLAB = 2: TLAB 外分配
  T_LOCK_SAMPLE        = 3: 锁争用
  T_WALL_CLOCK_SAMPLE  = 4: Wall Clock 采样
  ...
```

### 15.4 六层面分析

| 层面 | 分析 |
|------|------|
| **设计原理** | 为什么用变长编码？<br>JFR 文件可能包含数百万事件。变长编码对时间戳、线程 ID 等小值非常高效，节省大量空间。 |
| **边界条件** | 最大值如何编码？<br>Var32: 最多 5 字节<br>Var64: 最多 10 字节<br>都能完整表示。 |
| **并发安全** | 每个线程有独立的 Buffer（`_buf[CONCURRENCY_LEVEL]`）。无竞争。 |
| **JVM 交互** | JFR 格式与 JDK Flight Recorder 兼容。可以使用 `jfr` 命令行工具分析。 |
| **性能影响** | 编码约 10-20 周期/字节。解码时类似。总体开销小。 |
| **替代方案** | 固定长度编码？<br>问题：浪费空间。例如线程 ID 通常 < 65536，用 2 字节 VarInt，但固定长度需要 4 字节。 |

---

## 16. 完整错误恢复流程图

```
AsyncGetCallTrace 错误恢复决策树：

AGCT 返回
    │
    ├── num_frames > 0
    │       │
    │       └── 成功，返回帧
    │
    ├── ticks_unknown_Java / ticks_not_walkable_Java
    │       │
    │       ├── 查找 Runtime Stub
    │       │       │
    │       │       ├── 找到 vtable stub
    │       │       │       │
    │       │       │       └── 从 RDI 获取 receiver
    │       │       │               │
    │       │       │               └── 添加类名帧
    │       │       │
    │       │       └── 找到其他 stub
    │       │               │
    │       │               └── 尝试 unwindStub()
    │       │                       │
    │       │                       ├── 成功 → 重试 AGCT
    │       │                       └── 失败 → 返回错误帧
    │       │
    │       └── 没找到 stub
    │               │
    │               └── 尝试从 NMethod 恢复
    │                       │
    │                       └── fillFrameTypes()
    │
    ├── ticks_unknown_not_Java
    │       │
    │       ├── 检查 JavaFrameAnchor
    │       │       │
    │       │       ├── lastJavaSP != 0, lastJavaPC == NULL
    │       │       │       │
    │       │       │       ├── 从栈获取 PC
    │       │       │       ├── 设置 lastJavaPC
    │       │       │       ├── 修复 frame_complete_offset
    │       │       │       └── 重试 AGCT
    │       │       │
    │       │       └── lastJavaSP == 0
    │       │               │
    │       │               └── 不是 Java 线程，返回 0
    │       │
    │       └── ...
    │
    ├── ticks_GC_active
    │       │
    │       ├── lastJavaSP != 0
    │       │       │
    │       │       └── 返回 "GC_active" 错误帧
    │       │
    │       └── lastJavaSP == 0
    │               │
    │               └── Compiler 线程等，返回 0
    │
    └── 其他错误
            │
            └── 记录失败计数，返回错误帧
```

---

## 17. GDB 验证脚本

### 17.1 验证错误恢复

```gdb
# 文件: jvm-md/tmp-file/async-profiler/gdb_error_recovery.txt

set pagination off

# 在错误处理分支设置断点
break profiler.cpp:427

commands
    printf "\n========== AsyncGetCallTrace 失败 ==========\n"
    printf "错误码: %d\n", $trace.num_frames
    
    if $trace.num_frames == -4
        printf "ticks_unknown_Java: 尝试 Runtime Stub 恢复\n"
    end
    
    if $trace.num_frames == -6
        printf "ticks_unknown_not_Java: 尝试 JavaFrameAnchor 恢复\n"
    end
    
    continue
end

run
```

### 17.2 验证 VarInt 编码

```gdb
# 文件: jvm-md/tmp-file/async-profiler/gdb_varint.txt

set pagination off

break Buffer::putVar32

commands
    printf "\n========== putVar32() ==========\n"
    printf "输入值: %u\n", $arg0
    
    # 执行编码
    stepi 10
    
    printf "编码后:\n"
    # 打印前几个字节
    set $i = 0
    while $i < 5
        printf "  byte[%d] = 0x%02x\n", $i, ((char*)_data)[$i]
        set $i = $i + 1
    end
    
    continue
end

run
```

---

## 18. 性能总结

### 18.1 各阶段耗时占比

```
recordSample() 典型耗时分解：

阶段                    耗时(周期)    占比
─────────────────────────────────────────
原子计数                 20-50        1%
锁获取                   20-100       2%
Native 栈回溯            500-2000     30%
Java 栈回溯              1000-5000    40%
哈希计算                 50-100       3%
存储插入                 50-200       4%
JFR 写入                 50-100       2%
其他                     100-500      18%
─────────────────────────────────────────
总计                     2000-8000    100%

注意：
  - 栈回溯占 70% 左右
  - 如果调用栈很短，总耗时可低至 1000 周期
  - 如果遇到错误恢复，可能增加 500-2000 周期
```

### 18.2 优化建议

```
如果采样开销成为瓶颈：

1. 减少 max_stack_depth
   - 权衡：丢失深层调用信息
   - 效果：减少栈回溯时间

2. 使用 CSTACK_VM
   - 权衡：丢失 Native 帧
   - 效果：避免 Native 栈回溯

3. 关闭错误恢复特性
   - _features.unknown_java = 0
   - _features.java_anchor = 0
   - 权衡：某些采样会失败
   - 效果：减少错误处理开销

4. 减少 JFR 事件字段
   - 权衡：丢失某些信息
   - 效果：减少编码时间
```

---

**本课完成了 recordSample() 的完整深度解析，包括错误恢复策略和 JFR 编码。下一课将分析 FlameGraph 输出格式。**
