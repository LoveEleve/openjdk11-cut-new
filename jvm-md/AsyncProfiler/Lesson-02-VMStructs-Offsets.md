# AsyncProfiler 第二课：VMStructs 偏移量推断

> **学习目标**：理解 async-profiler 如何不依赖 JVM 头文件获取数据结构偏移  
> **核心源码**：`vmStructs.cpp` `vmStructs.h`  
> **预计时间**：2-3 小时

---

## 一、核心问题

**问题**：async-profiler 如何不依赖 JVM 头文件就能访问 JVM 内部数据结构？

**例如**：
```cpp
// 如何获取 JavaThread 的 _stack_base 字段偏移？
// 如何获取 oop 的 _mark 字段偏移？
// 如何获取 Klass 的 _name 字段偏移？
```

**答案**：通过 **三种偏移量推断方法**！

---

## 二、为什么需要偏移量推断？

### 2.1 传统方法的问题

```
┌─────────────────────────────────────────────────────────────────┐
│  传统方法：依赖 JVM 头文件                                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  方案 1：直接包含 JVM 头文件                                     │
│    #include "thread.hpp"                                        │
│    #include "oops/oop.hpp"                                      │
│                                                                 │
│  问题：                                                          │
│    ① 版本兼容性                                                  │
│       - OpenJDK 8/11/17/21 的数据结构可能不同                   │
│       - 每个版本都要维护不同的头文件                            │
│                                                                 │
│    ② 编译复杂度                                                  │
│       - 需要完整的 JVM 源码环境                                  │
│       - 编译时需要链接 JVM 库                                    │
│                                                                 │
│    ③ 发布困难                                                    │
│       - 一个 .so 只能支持特定 JVM 版本                          │
│       - 用户需要下载对应版本的 agent                            │
│                                                                 │
│  结论：不可行！                                                  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 async-profiler 的解决方案

```
┌─────────────────────────────────────────────────────────────────┐
│  async-profiler 方法：运行时推断偏移量                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  核心思想：                                                      │
│    在运行时从 JVM 导出的符号表中读取偏移量，                     │
│    或通过已知信息推断未知偏移量。                                │
│                                                                 │
│  优势：                                                          │
│    ① 版本兼容：自动适应不同 JVM 版本                            │
│    ② 编译简单：不需要 JVM 头文件                                │
│    ③ 发布简单：一个 .so 支持所有版本                            │
│                                                                 │
│  三种方法：                                                      │
│    1. 从 gHotSpotVMStructs 符号表读取（最可靠）                 │
│    2. 从已知对象推断（中等可靠）                                │
│    3. 从 JVM 代码模式推断（备用方案）                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 三、方法 1：从 gHotSpotVMStructs 符号表读取

### 3.1 gHotSpotVMStructs 是什么？

**答案**：HotSpot JVM 导出的一个符号表，包含所有数据结构的偏移量信息。

**位置**：`hotspot/share/runtime/vmStructs.cpp`（JVM 源码）

**导出符号**：
```cpp
// JVM 导出的符号
extern "C" {
    // 符号表起始地址
    VMStructEntry* gHotSpotVMStructs;
    
    // 符号表步长
    int gHotSpotVMStructEntryArrayStride;
    
    // Entry 结构的字段偏移
    int gHotSpotVMStructEntryTypeNameOffset;
    int gHotSpotVMStructEntryFieldNameOffset;
    int gHotSpotVMStructEntryOffsetOffset;
    int gHotSpotVMStructEntryAddressOffset;
}
```

**Entry 结构**（JVM 源码）：
```cpp
struct VMStructEntry {
    const char* typeName;      // 类型名，如 "Klass"
    const char* fieldName;     // 字段名，如 "_name"
    uint64_t   offset;         // 字段偏移量，如 24
    void*      address;        // 全局变量地址（可选）
};
```

### 3.2 async-profiler 如何读取？

**源码位置**：`vmStructs.cpp:147-200`

```cpp
void VMStructs::initOffsets() {
    // ① 读取 JVM 导出的符号地址
    uintptr_t entry = readSymbol("gHotSpotVMStructs");
    uintptr_t stride = readSymbol("gHotSpotVMStructEntryArrayStride");
    uintptr_t type_offset = readSymbol("gHotSpotVMStructEntryTypeNameOffset");
    uintptr_t field_offset = readSymbol("gHotSpotVMStructEntryFieldNameOffset");
    uintptr_t offset_offset = readSymbol("gHotSpotVMStructEntryOffsetOffset");
    uintptr_t address_offset = readSymbol("gHotSpotVMStructEntryAddressOffset");
    
    // ② 遍历符号表
    if (entry != 0 && stride != 0) {
        for (;; entry += stride) {
            // 读取 Entry 的类型名和字段名
            const char* type = *(const char**)(entry + type_offset);
            const char* field = *(const char**)(entry + field_offset);
            if (type == NULL || field == NULL) {
                break;  // 符号表结束
            }
            
            // ③ 根据类型和字段名匹配，保存偏移量
            if (strcmp(type, "Klass") == 0) {
                if (strcmp(field, "_name") == 0) {
                    _klass_name_offset = *(int*)(entry + offset_offset);
                    // 例如：_klass_name_offset = 24
                }
            } else if (strcmp(type, "Symbol") == 0) {
                if (strcmp(field, "_length") == 0) {
                    _symbol_length_offset = *(int*)(entry + offset_offset);
                }
            } else if (strcmp(type, "oopDesc") == 0) {
                if (strcmp(field, "_metadata._klass") == 0) {
                    _oop_klass_offset = *(int*)(entry + offset_offset);
                }
            }
            // ... 更多字段匹配
        }
    }
}
```

**关键函数**：`readSymbol()`

```cpp
uintptr_t VMStructs::readSymbol(const char* symbol_name) {
    // 从 libjvm.so 中查找符号
    const void* symbol = _libjvm->findSymbol(symbol_name);
    if (symbol == NULL) {
        return 0;  // 符号不存在
    }
    // 返回符号的值（不是地址！）
    return *(uintptr_t*)symbol;
}
```

### 3.3 实战示例

**示例 1：获取 Klass::_name 偏移量**

```
步骤：
  1. JVM 导出 gHotSpotVMStructs 符号表
  2. async-profiler 遍历符号表
  3. 找到 typeName="Klass", fieldName="_name" 的 Entry
  4. 读取 offset 字段，保存到 _klass_name_offset

假设 JVM 符号表中：
  Entry {
    typeName = "Klass"
    fieldName = "_name"
    offset = 24
  }

则：_klass_name_offset = 24

验证：
  Klass* k = ...;
  Symbol* name = *(Symbol**)((char*)k + _klass_name_offset);
  // 等价于：Symbol* name = k->_name;
```

---

## 四、方法 2：从已知对象推断

### 4.1 为什么需要推断？

```
问题：
  不是所有字段都在 gHotSpotVMStructs 中！

例如：
  • JavaThread::_stack_base
  • JavaThread::_threadObj
  • OSThread::_thread_id

原因：
  这些是平台相关的或内部实现细节，JVM 不导出。
```

### 4.2 推断方法示例

**示例：推断 JavaThread::_stack_base 偏移量**

**源码位置**：`vmStructs.cpp`（具体实现较复杂，这里讲原理）

```
原理：
  1. 获取当前线程的 pthread_t
  2. 通过 pthread_getattr_np() 获取栈信息
  3. 找到 JavaThread 对象的地址
  4. 对比栈基址和 JavaThread 地址，计算偏移

步骤：
  Step 1: 获取当前 JavaThread 对象
    JavaThread* thread = JavaThread::current();  // 如何获取？

  Step 2: 获取线程栈基址
    pthread_attr_t attr;
    pthread_getattr_np(pthread_self(), &attr);
    void* stack_base;
    size_t stack_size;
    pthread_attr_getstack(&attr, &stack_base, &stack_size);
    // stack_base = 栈基址

  Step 3: 计算偏移量
    // 假设：
    //   thread 地址 = 0x7ffff0001000
    //   stack_base 地址 = 0x7ffff0002000
    //   则偏移量 = stack_base - thread = 0x1000
    
    _thread_stack_base_offset = (char*)stack_base - (char*)thread;
```

**示例 2：推断 JavaThread::_threadObj 偏移量**

```
原理：
  1. Thread.currentThread() 返回 Java 对象
  2. 该对象存储在 JavaThread 的 _threadObj 字段中
  3. 通过 JNI 获取 Java 对象地址，计算偏移

步骤：
  Step 1: 在 Java 代码中
    Thread current = Thread.currentThread();

  Step 2: 在 C++ 代码中
    jthread thread_obj = jvmti->GetCurrentThread();
    // thread_obj 是 jni 本地引用

  Step 3: 获取 JavaThread 对象
    JavaThread* java_thread = JavaThread::current();

  Step 4: 计算偏移量
    // 假设：
    //   java_thread 地址 = 0x7ffff0001000
    //   thread_obj 地址 = 0x7ffff0003000
    //   则偏移量 = thread_obj - java_thread = 0x2000
    
    _thread_obj_offset = (char*)thread_obj - (char*)java_thread;
```

---

## 五、方法 3：从 JVM 代码模式推断

### 5.1 什么是代码模式推断？

```
原理：
  通过分析 JVM 的汇编代码，找到特定的代码模式，
  从而推断出数据结构的布局。

例如：
  • 解释器入口点的代码模式
  • 栈帧布局的代码模式
  • 调用约定的代码模式
```

### 5.2 示例：推断解释器帧的 BCP 偏移量

**源码位置**：`vmStructs.cpp:489`

```cpp
void VMStructs::resolveOffsets() {
    // ...
    
    // 解释器帧的 BCP (Bytecode Pointer) 偏移量
    // HotSpot 11: -8
    // HotSpot 8: -7
    #if defined(__x86_64__) || defined(__i386__)
        _interpreter_frame_bcp_offset = 
            VM::hotspot_version() >= 11 ? -8 : 
            VM::hotspot_version() == 8 ? -7 : 0;
    #elif defined(__aarch64__)
        // ARM 架构的处理
        _interpreter_frame_bcp_offset = ...;
    #endif
}
```

**原理**：
- 解释器执行字节码时，需要访问 BCP（字节码指针）
- BCP 通常存储在栈帧的某个固定偏移位置
- 不同 HotSpot 版本的栈帧布局略有不同
- 通过版本号推断偏移量

---

## 六、完整初始化流程

### 6.1 两阶段初始化

```
┌─────────────────────────────────────────────────────────────────┐
│  VMStructs 两阶段初始化                                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  阶段 1：Agent_OnLoad 时（JNI 不可用）                           │
│    函数：VMStructs::init(libjvm)                                │
│    作用：                                                       │
│      • 从 gHotSpotVMStructs 读取基本偏移量                      │
│      • 初始化 JVM 函数指针                                      │
│                                                                 │
│  阶段 2：VMInit 回调时（JNI 可用）                               │
│    函数：VMStructs::ready()                                     │
│    作用：                                                       │
│      • 解析需要 JNI 的偏移量                                    │
│      • 修补 SafeFetch 函数                                      │
│      • 初始化线程桥接                                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 6.2 源码流程

```cpp
// 阶段 1：Agent_OnLoad
void VMStructs::init(CodeCache* libjvm) {
    if (libjvm != NULL) {
        _libjvm = libjvm;
        initOffsets();      // 读取 gHotSpotVMStructs
        initJvmFunctions(); // 初始化 JVM 函数指针
    }
}

// 阶段 2：VMInit 回调
void VMStructs::ready() {
    resolveOffsets();    // 解析需要 JNI 的偏移量
    patchSafeFetch();    // 修补 SafeFetch 函数
    initThreadBridge();  // 初始化线程桥接
}
```

---

## 七、关键偏移量清单

### 7.1 对象头相关

| 偏移量变量 | 类型 | 说明 | 示例值 |
|-----------|------|------|--------|
| `_oop_klass_offset` | int | oop->_metadata._klass | 8 (32-bit) |
| `_markword_klass_shift` | int | markword 中 klass 的位移 | -1 (disabled) |
| `_markword_monitor_value` | int | markword 的 monitor 标志 | 2 |

### 7.2 类元数据相关

| 偏移量变量 | 类型 | 说明 | 示例值 |
|-----------|------|------|--------|
| `_klass_name_offset` | int | Klass->_name | 24 |
| `_symbol_length_offset` | int | Symbol->_length | 0 |
| `_symbol_body_offset` | int | Symbol->_body | 8 |
| `_methods_offset` | int | Klass->_methods | 128 |
| `_jmethod_ids_offset` | int | Klass->_jmethod_ids | 160 |

### 7.3 线程相关

| 偏移量变量 | 类型 | 说明 | 示例值 |
|-----------|------|------|--------|
| `_thread_osthread_offset` | int | JavaThread->_osthread | 280 |
| `_thread_anchor_offset` | int | JavaThread->_anchor | 320 |
| `_osthread_id_offset` | int | OSThread->_thread_id | 24 |
| `_anchor_sp_offset` | int | JavaFrameAnchor->_last_Java_sp | 0 |
| `_anchor_pc_offset` | int | JavaFrameAnchor->_last_Java_pc | 8 |
| `_anchor_fp_offset` | int | JavaFrameAnchor->_last_Java_fp | 16 |

### 7.4 JIT 代码相关

| 偏移量变量 | 类型 | 说明 | 示例值 |
|-----------|------|------|--------|
| `_nmethod_method_offset` | int | nmethod->_method | 64 |
| `_nmethod_entry_offset` | int | nmethod->_verified_entry_offset | 128 |
| `_nmethod_state_offset` | int | nmethod->_state | 32 |
| `_code_offset` | int | nmethod->_code_offset | 256 |

---

## 八、实战练习

### 练习 1：验证偏移量推断

**目标**：用 GDB 验证 VMStructs 推断的偏移量是否正确

**步骤**：

```bash
# 1. 启动 JVM + GDB
gdb --args /data/workspace/openjdk-cut-new/build/.../bin/java \
    -agentpath:/data/workspace/async-profiler/build/lib/libasyncProfiler.so=start \
    -cp /data/workspace/demo/src \
    com.wjcoder.Main

# 2. 设置断点 break VMStructs::initOffsets
(gdb) break VMStructs::ready

# 3. 运行 run

# 4. 到达断点后，查看偏移量
(gdb) print VMStructs::_klass_name_offset
(gdb) print VMStructs::_oop_klass_offset
(gdb) print VMStructs::_nmethod_method_offset

# 5. 与 JVM 源码定义对比
# 打开 hotspot/share/oops/klass.hpp
# 查看 Klass 类的定义：
#   class Klass {
#     ...
#     Symbol* _name;  // 偏移量应该是多少？
#     ...
#   };
# 
# 计算偏移量：
#   假设 Klass 大小 = 8 字节对齐
#   _name 字段在类中的偏移 = ?

# 6. 验证
# 在 GDB 中打印 Klass 对象
(gdb) print *(Klass*)0x7ffff0001000
(gdb) print ((Klass*)0x7ffff0001000)._name
# 应该等于：
(gdb) print *(Symbol**)(0x7ffff0001000 + VMStructs::_klass_name_offset)
```

**思考题**：

1. 为什么 `_klass_name_offset` 的值是 24？
2. 如何验证这个值是正确的？
3. 不同 JVM 版本的偏移量会不会不同？

---

### 练习 2：理解 gHotSpotVMStructs

**目标**：直接查看 JVM 导出的符号表

**步骤**：

```bash
# 1. 找到 libjvm.so
LIBJVM=/data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/lib/server/libjvm.so

# 2. 查看 gHotSpotVMStructs 符号
nm -C $LIBJVM | grep gHotSpotVMStructs

# 输出示例：
# 0000000000b4a2e0 D gHotSpotVMStructs
# 0000000000b4a2f0 D gHotSpotVMStructEntryArrayStride
# ...

# 3. 用 GDB 读取符号表内容
gdb $LIBJVM
(gdb) print gHotSpotVMStructs[0]
# 应该看到第一个 Entry 的内容

(gdb) print gHotSpotVMStructs[1]
# 第二个 Entry

# 4. 遍历符号表
(gdb) set $i = 0
(gdb) while gHotSpotVMStructs[$i].typeName != 0
 > printf "%s::%s = %d\n", gHotSpotVMStructs[$i].typeName, gHotSpotVMStructs[$i].fieldName, gHotSpotVMStructs[$i].offset
 > set $i = $i + 1
 > end
```

**预期输出**：

```
Klass::_name = 24
Symbol::_length = 0
Symbol::_body = 8
oopDesc::_metadata._klass = 8
JavaThread::_osthread = 280
...
```

---

### 练习 3：推断 JavaThread 偏移量

**目标**：理解如何从已知对象推断偏移量

**提示**：

```cpp
// 原理：JavaThread 与 Java Thread 对象的关系
// 
// Java 代码：
//   Thread t = Thread.currentThread();
// 
// JVM 内部：
//   - JavaThread* java_thread = thread_local->get();
//   - oop thread_obj = java_thread->_threadObj;
//   - 返回 thread_obj
//
// 推断：
//   1. 获取当前 JavaThread 对象
//   2. 获取当前 Java Thread 对象（JNI）
//   3. 计算偏移量
```

**思考题**：

1. 如何获取当前 JavaThread 对象？
2. 如何获取当前 Java Thread 对象？
3. 如何验证推断的偏移量？

---

## 九、核心问题解答

### Q1: 为什么不依赖 JVM 头文件？

**A**:

```
原因 1：版本兼容性
  • OpenJDK 8/11/17/21 的数据结构布局不同
  • 维护多个版本的头文件成本高

原因 2：编译复杂度
  • 需要完整的 JVM 源码环境
  • 编译时需要链接 JVM 库

原因 3：发布困难
  • 一个 .so 只能支持特定版本
  • 用户需要下载对应版本

解决方案：运行时推断
  • 从符号表读取偏移量
  • 自动适应不同版本
  • 一个 .so 支持所有版本
```

---

### Q2: 三种推断方法的优劣？

**A**:

| 方法 | 可靠性 | 适用范围 | 性能 |
|------|--------|----------|------|
| **gHotSpotVMStructs** | ⭐⭐⭐⭐⭐ 最可靠 | 所有导出字段 | 快（直接读取） |
| **已知对象推断** | ⭐⭐⭐⭐ 较可靠 | 非导出字段 | 中等（需要计算） |
| **代码模式推断** | ⭐⭐⭐ 备用 | 平台相关字段 | 快（硬编码） |

**优先级**：
1. 优先使用 gHotSpotVMStructs（最可靠）
2. 无法获取时用已知对象推断
3. 前两者都不行时用代码模式推断

---

### Q3: 如何验证推断正确性？

**A**:

```
方法 1：GDB 直接验证
  • 用 GDB 打印 JVM 对象
  • 对比推断的偏移量和实际字段

方法 2：交叉验证
  • 从多个已知对象推断
  • 结果应该一致

方法 3：版本对比
  • 对比不同 JVM 版本的偏移量
  • 应该符合预期规律

示例：
  # 假设推断 _klass_name_offset = 24
  Klass* k = ...;
  Symbol* name1 = *(Symbol**)((char*)k + 24);  # 推断方法
  
  # 在 JVM 源码中
  Symbol* name2 = k->_name;  # 直接访问
  
  # 验证：name1 == name2
```

---

### Q4: 不同 JVM 类型如何处理？

**A**:

```cpp
// 源码：vmEntry.cpp:146-157
if (_jvmti->GetSystemProperty("java.vm.name", &prop) == 0) {
    is_hotspot = strstr(prop, "OpenJDK") != NULL ||
                 strstr(prop, "HotSpot") != NULL;
    _openj9 = strstr(prop, "OpenJ9") != NULL;
    _zing = strstr(prop, "Zing") != NULL;
}

// 不同 JVM 有不同的处理
void VMStructs::resolveOffsets() {
    if (VM::isOpenJ9() || VM::isZing()) {
        return;  // OpenJ9/Zing 有不同的数据结构
    }
    // HotSpot 的处理
    ...
}
```

---

## 十、学习检查点

完成本课后，你应该能够：

- [ ] 能解释为什么不依赖 JVM 头文件
- [ ] 能列出三种偏移量推断方法
- [ ] 能说明 gHotSpotVMStructs 的作用
- [ ] 能用 GDB 验证推断的偏移量
- [ ] 能理解不同 JVM 类型的处理方式
- [ ] 能阅读 `vmStructs.cpp` 理解推断逻辑

---

## 十一、下一步

**下一课预告**：CPU 采样核心——PerfEvents

**学习内容**：
- Linux perf_event 机制
- 如何配置 perf_event_open
- SIGPROF 信号处理
- 栈回溯核心算法

**准备**：
- 阅读 `man perf_event_open`
- 了解 Linux 信号机制
- 阅读 `stackWalker.cpp` 源码

---

## 🔬 实战验证

> **验证原则**：所有结论必须经过实际验证，不接受未经证实的理论推导。

### 验证环境

**标准环境**：
```bash
JVM=/data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java
ASYNC_PROFILER=/data/workspace/async-profiler/build/lib/libasyncProfiler.so
```

---

### 验证项 1：gHotSpotVMStructs 符号表存在性

**目标**：验证 JVM 确实导出了 `gHotSpotVMStructs` 符号。

**方法**：使用 `nm` 或 `readelf` 检查符号表

**验证命令**：
```bash
# 方法 1：nm 查找符号
nm -C $JVM/../lib/server/libjvm.so | grep gHotSpotVMStructs

# 方法 2：readelf 查找符号
readelf -s $JVM/../lib/server/libjvm.so | grep gHotSpotVMStructs
```

**预期输出**：
```
0000000000abcd1234 D gHotSpotVMStructs
0000000000abcd1238 D gHotSpotVMStructEntryArrayStride
```

**验证状态**：⬜ 待验证

**验证文件**：`jvm-md/tmp-file/lesson02/verify_vmstructs_symbol.sh`

---

### 验证项 2：关键偏移量的正确性

**目标**：验证推断的偏移量与 GDB 直接打印的一致。

**方法**：GDB 打印 + 源码对比

**验证脚本**：
```gdb
# 启动 JVM
run -agentpath:/path/to/libasyncProfiler.so=start ...

# 读取 gHotSpotVMStructs
set $entry = (void*)gHotSpotVMStructs
set $stride = gHotSpotVMStructEntryArrayStride

# 查找 _name 偏移
while 1
  set $type = *(char**)($entry + 0)
  set $field = *(char**)($entry + 8)
  
  if $type == 0 || $field == 0
    break
  end
  
  if $type == "Klass" && $field == "_name"
    set $offset = *(int*)($entry + 16)
    printf "_name offset = %d\n", $offset
  end
  
  set $entry = $entry + $stride
end

# 直接打印 Klass 结构验证
print sizeof(Klass)
print &((Klass*)0)->_name
```

**预期结果**：
```
_name offset = 24  ✅ 从 gHotSpotVMStructs 读取
$1 = 24            ✅ GDB 直接打印
```

**验证状态**：⬜ 待验证

**验证文件**：`jvm-md/tmp-file/lesson02/verify_offsets.gdb`

---

### 验证项 3：已知对象推断方法

**目标**：验证通过已知对象推断偏移量的方法。

**方法**：使用 Java 线程对象推断 `JavaThread` 偏移

**验证脚本**：
```gdb
# 1. 获取当前 JavaThread 指针
call Thread::current()
set $thread = (JavaThread*)$rax

# 2. 获取对应的 java.lang.Thread 对象
set $java_thread = $thread->getThreadObj()

# 3. 比较地址
printf "JavaThread*  = %p\n", $thread
printf "Thread object = %p\n", $java_thread

# 4. 验证偏移量
# 如果 async-profiler 推断的 _threadObj_offset 正确
# 那么 *(oop*)($thread + _threadObj_offset) 应该等于 $java_thread
```

**预期结果**：
```
JavaThread*  = 0x7ffff0012340
Thread object = 0x00000007ffe12340  ✅ 推断偏移正确
```

**验证状态**：⬜ 待验证

**验证文件**：`jvm-md/tmp-file/lesson02/verify_known_object.gdb`

---

### 验证项 4：三种推断方法的对比

**目标**：对比三种推断方法的结果，验证一致性。

**方法**：对同一字段使用三种方法推断

**字段**：`JavaThread::_threadObj`

**方法 1：gHotSpotVMStructs**
```cpp
// 从符号表读取
int offset_from_table = readFromTable("JavaThread", "_threadObj");
```

**方法 2：已知对象推断**
```cpp
// 已知：JavaThread* thread, oop threadObj
int offset_from_object = (char*)&thread->_threadObj - (char*)thread;
```

**方法 3：代码模式推断**
```cpp
// 在汇编中查找访问模式
// mov rax, [rdi + offset]  ; rdi = JavaThread*, rax = threadObj
int offset_from_asm = findPatternInCode();
```

**预期结果**：
```
方法 1 (符号表):     offset = 272
方法 2 (已知对象):   offset = 272  ✅ 一致
方法 3 (代码模式):   offset = 272  ✅ 一致
```

**验证状态**：⬜ 待验证

**验证文件**：`jvm-md/tmp-file/lesson02/verify_three_methods.cpp`

---

### 验证项 5：跨 JVM 版本的兼容性

**目标**：验证 async-profiler 能在不同 JVM 版本上工作。

**方法**：在多个 JVM 版本上测试

**测试矩阵**：

| JVM 版本 | gHotSpotVMStructs | 已知对象推断 | 代码模式推断 | 结果 |
|---------|-------------------|-------------|-------------|------|
| OpenJDK 8 | ✅ | ✅ | ✅ | ⬜ 待测 |
| OpenJDK 11 | ✅ | ✅ | ✅ | ⬜ 待测 |
| OpenJDK 17 | ✅ | ✅ | ✅ | ⬜ 待测 |
| OpenJ9 | ❌ | ✅ | ✅ | ⬜ 待测 |

**验证脚本**：
```bash
# 测试脚本
for jvm in /path/to/jdk8 /path/to/jdk11 /path/to/jdk17; do
  $jvm/bin/java -agentpath:$ASYNC_PROFILER=start,event=cpu -version
  if [ $? -eq 0 ]; then
    echo "$jvm: ✅ 成功"
  else
    echo "$jvm: ❌ 失败"
  fi
done
```

**验证状态**：⬜ 待验证

**验证文件**：`jvm-md/tmp-file/lesson02/verify_cross_version.sh`

---

### 验证结果统计

**总计验证项**：5 项
**已验证**：0 项（⬜ 待创建测试环境）
**待验证**：5 项

| 验证项 | 状态 | 方法 | 备注 |
|-------|------|------|------|
| gHotSpotVMStructs 符号 | ⬜ 待验证 | nm/readelf | 简单检查 |
| 关键偏移量正确性 | ⬜ 待验证 | GDB 对比 | 核心验证 |
| 已知对象推断 | ⬜ 待验证 | GDB | 重要方法 |
| 三种方法对比 | ⬜ 待验证 | 代码实现 | 完整对比 |
| 跨版本兼容性 | ⬜ 待验证 | 多 JVM 测试 | 扩展验证 |

---

### 下一步验证计划

**优先级排序**：
1. **高优先级**：gHotSpotVMStructs 符号存在性验证（基础）
2. **高优先级**：关键偏移量正确性验证（核心）
3. **中优先级**：已知对象推断方法验证（重要方法）
4. **中优先级**：三种方法对比验证（完整性）
5. **低优先级**：跨版本兼容性验证（扩展性）

**验证脚本准备**：
- [ ] 创建 `verify_vmstructs_symbol.sh`
- [ ] 创建 `verify_offsets.gdb`
- [ ] 创建 `verify_known_object.gdb`
- [ ] 创建 `verify_three_methods.cpp`
- [ ] 创建 `verify_cross_version.sh`

---

### 验证文件清单

**计划验证文件**：
```
jvm-md/tmp-file/lesson02/
├── verify_vmstructs_symbol.sh  # 符号表验证
├── verify_offsets.gdb          # 偏移量验证
├── verify_known_object.gdb     # 已知对象推断验证
├── verify_three_methods.cpp    # 三种方法对比
└── verify_cross_version.sh     # 跨版本测试
```

---

**验证原则**：
1. **实际验证 > 理论推导**
2. **异常必究，绝不敷衍**
3. **多方法交叉验证**

---

**文档版本**：v1.1（新增实战验证部分）
**最后更新**：2026-02-12
**作者**：JVM Mastery Skill
**字数**：~18,000 字（新增 ~2,000 字验证内容）

---

**恭喜完成第二课！现在你已经理解了 async-profiler 如何访问 JVM 内部数据结构。**

**准备好继续下一课了吗？**
