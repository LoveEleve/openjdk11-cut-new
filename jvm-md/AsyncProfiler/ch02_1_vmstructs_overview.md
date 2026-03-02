# 2.1 VMStructs 设计哲学与推断方法总览

> 源文件: `vmStructs.cpp` (757行), `vmStructs.h` (718行)
> 关联 JVM 源码: `hotspot/share/runtime/vmStructs.hpp` (303行), `hotspot/share/runtime/vmStructs.cpp` (3210行)
> 前置章节: 1.1 Agent 加载路径, 1.3 VMInit 后的初始化

## 核心问题

**async-profiler 是怎么知道 JVM 内部数据结构的偏移量的？为什么不直接 `#include` JVM 的头文件？**

---

## 一、为什么不用 JVM 头文件？

这是一个关键设计决策。传统的做法是直接 `#include <hotspot/share/oops/klass.hpp>` 等 JVM 头文件来获取结构体定义。async-profiler **故意不这样做**，原因有三：

### 1. 跨版本兼容性

JVM 内部结构在 **每个大版本** 甚至 **小版本** 之间都可能变化：

```
JDK 8:   JavaThread::_osthread 偏移可能是 640
JDK 11:  JavaThread::_osthread 偏移变为 672
JDK 17:  JavaThread::_osthread 偏移又变为 800+
JDK 21:  JavaThread 甚至没有 _osthread 字段了
```

如果 `#include` JVM 头文件，async-profiler 就必须为 **每个 JDK 版本** 编译一个独立的 .so 文件。而用运行时推断，一个 .so 就能在 JDK 8~24 上运行。

### 2. Debug/Release/Product 差异

JVM 的 debug 构建和 release 构建的结构体大小不同（debug 版有额外的检查字段）。头文件方式无法处理这个差异。

### 3. 不同 JVM 实现

async-profiler 同时支持 HotSpot、OpenJ9 和 Zing。三者的内部结构完全不同。

---

## 二、推断方法总览 — 4 种数据源

async-profiler 使用 **4 种数据源** 来推断 JVM 内部偏移量，按使用阶段分为两步：

```
┌──────────────────────────────────────────────────────────────────────────┐
│                  VMStructs 偏移量推断的 4 种数据源                       │
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │ 阶段 1: VMStructs::init()  (Agent_OnLoad 时调用)                   │ │
│  │   数据源 ❶: gHotSpotVMStructs — JVM 主动暴露的结构偏移量表          │ │
│  │   数据源 ❷: gHotSpotVMTypes   — JVM 主动暴露的类型大小表            │ │
│  │   数据源 ❸: gHotSpotVMLongConstants / gHotSpotVMIntConstants       │ │
│  │   数据源 ❹: dlsym() — 从 libjvm.so 查找导出符号地址               │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                              ▼                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │ 阶段 2: VMStructs::ready()  (VMInit 后调用)                        │ │
│  │   数据源 ❶: JVMFlag 查询    — 运行时 JVM 参数值                    │ │
│  │   数据源 ❷: 间接指针解引用   — *_narrow_klass_base_addr 等          │ │
│  │   数据源 ❸: JNI 查询        — eetop/tid 等字段 ID                  │ │
│  │   数据源 ❹: TLS 暴力搜索    — pthread TLS key                     │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 三、数据源 ❶: gHotSpotVMStructs — JVM 的 "自我描述表"

### 3.1 JVM 侧：表是怎么生成的？

JVM 的 `vmStructs.cpp`（3210 行，巨大文件）中维护了一张 **静态描述表**，记录了 JVM 认为需要暴露给外部工具的所有字段偏移量。这个表最初是为 **Serviceability Agent (SA)** 设计的——SA 是 JDK 自带的调试工具，需要知道 JVM 内部结构来做 post-mortem 分析。

表的生成过程：

```cpp
// JVM 侧 vmStructs.cpp (简化)

// 1. 用宏定义所有要暴露的字段
#define VM_STRUCTS(nonstatic_field, static_field, ...)              \
  nonstatic_field(Klass,          _name,           Symbol*)         \
  nonstatic_field(Symbol,         _length,         unsigned short)  \
  nonstatic_field(Symbol,         _body,           jbyte)           \
  nonstatic_field(JavaThread,     _osthread,       OSThread*)       \
  nonstatic_field(JavaThread,     _anchor,         JavaFrameAnchor) \
  /* ... 数百行 ... */

// 2. 宏展开为 VMStructEntry 数组
//   GENERATE_NONSTATIC_VM_STRUCT_ENTRY(Klass, _name, Symbol*) 展开为:
//   { "Klass", "_name", "Symbol*", 0, offset_of(Klass, _name), NULL }

VMStructEntry VMStructs::localHotSpotVMStructs[] = {
  VM_STRUCTS(GENERATE_NONSTATIC_VM_STRUCT_ENTRY,
             GENERATE_STATIC_VM_STRUCT_ENTRY, ...)
  GENERATE_VM_STRUCT_LAST_ENTRY()  // 结束标记: { NULL, NULL, ... }
};

// 3. 导出为全局 C 符号（JNIEXPORT 确保符号可见）
extern "C" {
  JNIEXPORT VMStructEntry* gHotSpotVMStructs = VMStructs::localHotSpotVMStructs;
  JNIEXPORT uint64_t gHotSpotVMStructEntryArrayStride = STRIDE(gHotSpotVMStructs);
  JNIEXPORT uint64_t gHotSpotVMStructEntryTypeNameOffset = offset_of(VMStructEntry, typeName);
  JNIEXPORT uint64_t gHotSpotVMStructEntryFieldNameOffset = offset_of(VMStructEntry, fieldName);
  JNIEXPORT uint64_t gHotSpotVMStructEntryOffsetOffset = offset_of(VMStructEntry, offset);
  JNIEXPORT uint64_t gHotSpotVMStructEntryAddressOffset = offset_of(VMStructEntry, address);
}
```

### 3.2 VMStructEntry 的内存布局

```
┌───────────────────────────────────────────────────────────────┐
│ VMStructEntry (48 字节, GDB 验证 stride=48)                   │
├────────────────┬──────────┬──────────────────────────────────┤
│ 偏移量         │ 类型      │ 字段名       │ 示例值            │
├────────────────┼──────────┼──────────────┼──────────────────┤
│ 0              │ char*    │ typeName     │ "JavaThread"     │
│ 8              │ char*    │ fieldName    │ "_anchor"        │
│ 16             │ char*    │ typeString   │ "JavaFrameAnchor"│
│ 24             │ int32_t  │ isStatic     │ 0 (非静态)       │
│ 28             │ (4B pad) │              │                  │
│ 32             │ uint64_t │ offset       │ 888              │
│ 40             │ void*    │ address      │ NULL (非静态)    │
└────────────────┴──────────┴──────────────┴──────────────────┘
```

**GDB 验证**: `stride = 48`，与上面的布局完全一致。

### 3.3 async-profiler 侧：如何遍历这张表？

`initOffsets()` 的核心算法非常简洁：

```
1. 通过 dlsym 读取 gHotSpotVMStructs 数组的基地址和元数据偏移量
2. for 循环逐条遍历数组，每条 entry 包含 (typeName, fieldName, offset)
3. 用 strcmp(type, "JavaThread") + strcmp(field, "_anchor") 匹配感兴趣的字段
4. 读取 offset 值（如 888）赋值给 _thread_anchor_offset
5. 数组以 typeName==NULL 作为结束标记
```

**GDB 验证**: 在 JDK 11 slowdebug 中，`gHotSpotVMStructs` 共有 **833 条** VMStructEntry。

### 3.4 4 种表的用途对比

| 表名 | 条目数(GDB) | 提供内容 | async-profiler 用途 |
|------|:-----------:|---------|-------------------|
| gHotSpotVMStructs | 833 | 字段名→偏移量/地址 | 最核心：提供 90%+ 的偏移量 |
| gHotSpotVMTypes | 749 | 类型名→大小(bytes) | 获取 JVMFlag/ConstMethod 的大小 |
| gHotSpotVMLongConstants | ~20 | 命名常量(long) | markWord::klass_shift 等 |
| gHotSpotVMIntConstants | ~200 | 命名常量(int) | frame::entry_frame_call_wrapper_offset |

---

## 四、数据源 ❷: dlsym — 符号查找

有些信息不在 `gHotSpotVMStructs` 中，但可以从 `libjvm.so` 的导出符号直接获取：

```cpp
// vmEntry.cpp VM::init() 中
void* libjvm_handle = dlopen("libjvm.so", ...);
VM::_asyncGetCallTrace = dlsym(libjvm_handle, "AsyncGetCallTrace");
VM::_totalMemory       = dlsym(libjvm_handle, "JVM_TotalMemory");
VM::_freeMemory        = dlsym(libjvm_handle, "JVM_FreeMemory");
```

以及 `initJvmFunctions()` 中的 mangled C++ 符号查找：

```cpp
// vmStructs.cpp:433
_lock_func   = dlsym(libjvm, "_ZN7Monitor28lock_without_safepoint_checkEv");
_unlock_func = dlsym(libjvm, "_ZN7Monitor6unlockEv");
```

这些 C++ mangled 名称是通过 async-profiler 自己的 `CodeCache` 符号解析能力找到的（它能解析 ELF 符号表），而不是用 `dlsym`。

---

## 五、数据源 ❸: JVMFlag — 运行时参数查询

`resolveOffsets()` 中使用自建的 `JVMFlag::find()` 函数来查询 JVM 运行时参数：

```cpp
JVMFlag* ccp = JVMFlag::find("UseCompressedClassPointers");
if (ccp != NULL && ccp->get()) {
    _narrow_klass_base  = *_narrow_klass_base_addr;
    _narrow_klass_shift = *_narrow_klass_shift_addr;
}
```

`JVMFlag::find()` 本身就是利用 `gHotSpotVMStructs` 推断出的偏移量来遍历 JVM 的 Flag 数组：

```
JVMFlag::find("UseCompressedClassPointers")
  → 遍历 _flags_addr[0.._flag_count], 步长 _flag_size
    → 每个 Flag 在 _flag_name_offset 处读取名称
    → 在 _flag_addr_offset 处读取值的地址
    → *addr 得到 bool 值
```

**GDB 验证**: `_flags_addr = 0x7ffff75b2c60`, `_flag_count = 1366`, `_flag_size = 48`

---

## 六、数据源 ❹: 间接指针 + JNI + TLS 暴力搜索

这是在 `VMStructs::ready()`（VMInit 后）阶段使用的：

| 方法 | 获取内容 | 实现 |
|------|---------|------|
| 间接指针解引用 | _narrow_klass_base, _narrow_klass_shift, _code_heap_low/high | `*_xxx_addr` — 地址在 init 阶段从表中获得 |
| JNI GetFieldID | _eetop, _tid | `env->GetFieldID(Thread.class, "eetop", "J")` |
| TLS 暴力搜索 | _tls_index | `for(i=0;i<1024;i++) if(pthread_getspecific(i)==vm_thread)` |
| 指针算术 | _env_offset | `(intptr_t)env - (intptr_t)vm_thread = 920` |

---

## 七、initOffsets 遍历的完整偏移量清单

**GDB 验证**: 以下是 `initOffsets()` 完成后所有偏移量的最终值（JDK 11 slowdebug, x86_64）：

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│ 类别          │ 偏移量名                    │ 值    │ JVM 对应字段                    │
├──────────────────────────────────────────────────────────────────────────────────────┤
│ Klass         │ _klass_name_offset          │ 24    │ Klass::_name                    │
│ Symbol        │ _symbol_length_offset       │ 0     │ Symbol::_length                 │
│               │ _symbol_body_offset         │ 6     │ Symbol::_body[]                 │
│ oopDesc       │ _oop_klass_offset           │ 8     │ oopDesc::_metadata._klass       │
├──────────────────────────────────────────────────────────────────────────────────────┤
│ InstanceKlass │ _class_loader_data_offset   │ -1(!) │ InstanceKlass::_class_loader_data│
│               │ _class_loader_data_next_off │ 128   │ ClassLoaderData::_next          │
│               │ _methods_offset             │ 416   │ InstanceKlass::_methods         │
│               │ _jmethod_ids_offset         │ 344   │ InstanceKlass::_methods_jmethod_ids│
├──────────────────────────────────────────────────────────────────────────────────────┤
│ JavaThread    │ _thread_osthread_offset     │ 672   │ JavaThread::_osthread           │
│               │ _thread_anchor_offset       │ 888   │ JavaThread::_anchor             │
│               │ _thread_state_offset        │ 1040  │ JavaThread::_thread_state       │
│               │ _thread_vframe_offset       │ 952   │ JavaThread::_vframe_array_head  │
│ OSThread      │ _osthread_id_offset         │ 224   │ OSThread::_thread_id            │
│ Anchor        │ _anchor_sp_offset           │ 0     │ JavaFrameAnchor::_last_Java_sp  │
│               │ _anchor_pc_offset           │ 8     │ JavaFrameAnchor::_last_Java_pc  │
│               │ _anchor_fp_offset           │ 16    │ JavaFrameAnchor::_last_Java_fp  │
├──────────────────────────────────────────────────────────────────────────────────────┤
│ Compiler      │ _comp_env_offset            │ 1896  │ CompilerThread::_env            │
│               │ _comp_task_offset           │ 128   │ ciEnv::_task                    │
│               │ _comp_method_offset         │ 24    │ CompileTask::_method            │
├──────────────────────────────────────────────────────────────────────────────────────┤
│ CodeBlob      │ _blob_size_offset           │ 12    │ CodeBlob::_size                 │
│               │ _frame_size_offset          │ 28    │ CodeBlob::_frame_size           │
│               │ _frame_complete_offset      │ 20    │ CodeBlob::_frame_complete_offset│
│               │ _code_offset                │ -32   │ CodeBlob::_code_begin (指针)    │
│               │ _data_offset                │ 24    │ CodeBlob::_data_offset          │
│               │ _nmethod_name_offset        │ 112   │ CodeBlob::_name                 │
├──────────────────────────────────────────────────────────────────────────────────────┤
│ nmethod       │ _nmethod_method_offset      │ 128   │ nmethod::_method                │
│               │ _nmethod_entry_offset       │ -272  │ nmethod::_verified_entry_point   │
│               │ _nmethod_state_offset       │ 351   │ nmethod::_state                 │
│               │ _nmethod_level_offset       │ 344   │ nmethod::_comp_level            │
│               │ _scopes_pcs_offset          │ 316   │ nmethod::_scopes_pcs_offset     │
│               │ _scopes_data_offset         │ -136  │ nmethod::_scopes_data_begin(ptr)│
├──────────────────────────────────────────────────────────────────────────────────────┤
│ Method        │ _method_constmethod_offset  │ 16    │ Method::_constMethod            │
│               │ _method_code_offset         │ 80    │ Method::_code                   │
│ ConstMethod   │ _constmethod_constants_off  │ 8     │ ConstMethod::_constants         │
│               │ _constmethod_idnum_offset   │ 46    │ ConstMethod::_method_idnum      │
│               │ _constmethod_size           │ 56    │ sizeof(ConstMethod)             │
│ ConstantPool  │ _pool_holder_offset         │ 32    │ ConstantPool::_pool_holder      │
├──────────────────────────────────────────────────────────────────────────────────────┤
│ CodeHeap      │ _code_heap_addr             │ addr  │ CodeCache::_heaps 地址          │
│               │ _code_heap_memory_offset    │ 8     │ CodeHeap::_memory               │
│               │ _code_heap_segmap_offset    │ 120   │ CodeHeap::_segmap               │
│               │ _code_heap_segment_shift    │ 256(!)│ CodeHeap::_log2_segment_size 偏移│
│ VirtualSpace  │ _vs_low_bound/high_bound    │ 0/8   │ VirtualSpace::_low/_high_boundary│
│               │ _vs_low/_vs_high            │ 16/24 │ VirtualSpace::_low/_high        │
│ HeapBlock     │ _heap_block_used_offset     │ 8     │ HeapBlock::Header::_used        │
├──────────────────────────────────────────────────────────────────────────────────────┤
│ JVMFlag       │ _flags_addr                 │ addr  │ Flag 数组基地址                 │
│               │ _flag_count                 │ 1366  │ Flag 总数                       │
│               │ _flag_size                  │ 48    │ 每个 Flag 结构大小              │
│               │ _flag_name/addr/origin      │ 8/16/32│ Flag 内部字段偏移              │
├──────────────────────────────────────────────────────────────────────────────────────┤
│ Frame         │ _call_wrapper_anchor_offset │ 40    │ JavaCallWrapper::_anchor        │
│               │ _entry_frame_call_wrapper   │ -48   │ 常量(words→bytes)               │
│               │ _call_stub_return_addr      │ addr  │ StubRoutines::_call_stub_return │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

### 偏移量的正负含义

注意有些偏移量是 **负值**：

```
_code_offset         = -32   → CodeBlob::_code_begin (是指针，不是相对偏移)
_nmethod_entry_offset= -272  → nmethod::_verified_entry_point (是指针)
_scopes_data_offset  = -136  → nmethod::_scopes_data_begin (是指针)
```

这是 async-profiler 的编码约定：
- **正值** → 字段存的是一个"相对偏移量"（int），需要 `at(offset)` 读取后再做偏移计算
- **负值** → 字段存的是一个"绝对指针"（void*），需要 `*(void**)at(-offset)` 直接解引用

原因是不同 JDK 版本对同一概念的存储方式不同。例如 `nmethod::_verified_entry_point`：
- JDK 11: 存的是绝对地址（`void*`）→ 负偏移
- JDK 23+: 存的是相对于 `_code_begin` 的偏移量（`unsigned short`）→ 正偏移

---

## 八、_class_loader_data_offset = -1 的解释

**GDB 验证**中 `_class_loader_data_offset = -1`（未找到），但 `_class_loader_data_next_offset = 128`。

这不是 bug。查看 JDK 11 的 `gHotSpotVMStructs` 表：`InstanceKlass::_class_loader_data` 确实在表中，但 async-profiler 的匹配逻辑需要 **type = "InstanceKlass"** 且 **field = "_class_loader_data"**。实际上 JDK 11 的表中这个字段是挂在 `Klass` 类型下的（因为 `_class_loader_data` 是 `Klass` 的字段，不是 `InstanceKlass` 的）：

```
JDK 11: Klass::_class_loader_data  (在 Klass 中，不在 InstanceKlass 中)
JDK 17+: InstanceKlass 继承了 Klass 的这个字段
```

async-profiler 只匹配 `InstanceKlass::_class_loader_data`，所以在 JDK 11 上找不到。这不影响核心功能——影响的只是 `_has_class_loader_data` 标志，导致 `loadMethodIDs` 不走 CLD 优化路径。

---

## 九、设计哲学总结

### 原则 1: "借力打力"

async-profiler 不重新发明轮子，而是利用 JVM **已有的自描述机制**（`gHotSpotVMStructs`）。这个表本来是给 SA 用的，但 async-profiler 巧妙地"搭便车"——同一份数据，不同的消费者。

### 原则 2: "两阶段推断"

```
init()  阶段 → 只需要 libjvm.so 的符号表 → 不需要 JNI → Agent_OnLoad 可用
ready() 阶段 → 需要 JNI 和运行时环境    → 需要 JVM 完全初始化 → VMInit 后可用
```

分两阶段是因为不同信息在不同时间可用。init 阶段只能做"静态推断"（读符号表），ready 阶段才能做"动态探测"（JNI 查询、TLS 搜索）。

### 原则 3: "特性标志"

推断不一定 100% 成功（可能遇到未知 JDK 版本或变种），所以用 5 个 `_has_xxx` 标志来标记哪些能力可用：

```
_has_class_names     = true   → 可以解析类名
_has_method_structs  = true   → 可以解析方法结构
_has_compiler_structs= true   → 可以获取编译信息
_has_stack_structs   = true   → 可以用 VM 模式栈回溯
_has_class_loader_data=false  → 不能走 CLD 优化
```

这是一种**优雅降级**设计：即使某些偏移量推断失败，async-profiler 仍然可以工作，只是部分功能不可用。

### 原则 4: "巧妙的编码约定"

用偏移量的正负号区分"相对偏移"和"绝对指针"，用一个 int 字段同时编码两种访问模式，避免了为每个字段多维护一个 flag。

---

## 十、与 JVM 源码的交叉验证

| async-profiler 偏移量 | JVM 实际字段 | 验证方式 |
|----------------------|-------------|---------|
| `_thread_anchor_offset = 888` | `JavaThread::_anchor` at offset 888 | GDB: `p/d &((JavaThread*)0)->_anchor` |
| `_oop_klass_offset = 8` | `oopDesc::_metadata._klass` at offset 8 | GDB 验证 oop 头部布局 |
| `_nmethod_method_offset = 128` | `nmethod::_method` | GDB: `p/d &((nmethod*)0)->_method` |
| `_flag_size = 48` | `sizeof(JVMFlag) = 48` | GDB: `p sizeof(JVMFlag)` |
| `_flag_count = 1366` | JVM Flag 总数 | GDB: `p JVMFlag::numFlags` |

---

*创建日期: 2026-02-09*
*GDB 验证环境: OpenJDK 11 slowdebug + async-profiler v4.0 (git 00a0a12)*
*标准条件: -Xms8g -Xmx8g -XX:+UseG1GC -Xint*