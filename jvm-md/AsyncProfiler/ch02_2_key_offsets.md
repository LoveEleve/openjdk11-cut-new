# 2.2 关键偏移量详解 — 每个偏移量在 Profiling 中的作用

> 源文件: `vmStructs.cpp` (757行), `vmStructs.h` (718行)
> 关联: `profiler.cpp`, `stackWalker.cpp`
> 前置章节: 2.1 VMStructs 设计哲学与推断方法总览

## 核心问题

**async-profiler 推断了 60+ 个偏移量，每个偏移量在实际 profiling 中到底干什么用？**

2.1 节列出了所有偏移量的数值，但没有讲清楚"为什么需要这个偏移量"。这节按功能分组，逐一解释每个偏移量在采样过程中的实际作用。

---

## 一、分组总览

把 60+ 个偏移量按功能分为 **8 组**，按采样流程中的使用顺序排列：

```
采样信号到达
  ├── [A] 线程识别组: 找到当前 Java 线程    → 4 个偏移量
  ├── [B] 线程状态组: 判断线程当前在干什么  → 3 个偏移量
  ├── [C] Java 帧锚组: 找到最后一个 Java 帧 → 5 个偏移量
  ├── [D] CodeHeap 组: PC→NMethod 定位      → 8 个偏移量
  ├── [E] NMethod 组: 从 NMethod 读取方法信息 → 8 个偏移量
  ├── [F] 方法元数据组: NMethod→类名方法名   → 7 个偏移量
  ├── [G] 对象头/类名组: oop→类名解析        → 7 个偏移量
  └── [H] JVMFlag + 杂项组                  → 9 个偏移量
```

---

## 二、[A] 线程识别组 — "这个信号是哪个 Java 线程收到的？"

### 场景

当 `SIGPROF` 信号到达时，async-profiler 需要知道：
1. 当前线程是不是 Java 线程？（不是 Java 线程就忽略）
2. 如果是，它对应的 `JNIEnv*` 是什么？（传给 `AsyncGetCallTrace`）
3. 它的 OS 线程 ID 是什么？（写入 JFR 输出）

### 偏移量与使用

| 偏移量 | 值 | JVM 字段 | 使用位置 | 作用 |
|--------|:--:|---------|---------|------|
| `_tls_index` | 0 | pthread TLS key | `VMThread::current()` | 从 TLS 拿到 `JavaThread*` |
| `_env_offset` | 920 | JNIEnv 在 Thread 中的偏移 | `VMThread::jni()` | 计算 `JNIEnv* = this + 920` |
| `_thread_osthread_offset` | 672 | `JavaThread::_osthread` | `VMThread::osThreadId()` | 拿到 `OSThread*` |
| `_osthread_id_offset` | 224 | `OSThread::_thread_id` | `VMThread::osThreadId()` | 读取 `pid_t tid` |

### 调用链

```
信号处理器 → VMThread::current()
                ↓ pthread_getspecific(_tls_index=0)
              VMThread* vm_thread
                ↓ vm_thread->isJavaThread()   // 检查 vtable
                ↓ vm_thread->jni()            // (char*)this + _env_offset → JNIEnv*
              传给 AsyncGetCallTrace(trace, max_depth, ucontext)
                ↓ vm_thread->osThreadId()     // 写入 JFR
              *(OSThread**)((char*)this + 672) → osthread
              *(int*)((char*)osthread + 224)   → pid_t
```

### GDB 交叉验证

```
asprof _thread_osthread_offset = 672    vs JVM &((JavaThread*)0)->_osthread = 672    ✅
asprof _osthread_id_offset     = 224    vs JVM &((OSThread*)0)->_thread_id  = 224    ✅
```

---

## 三、[B] 线程状态组 — "线程在执行 Java 代码还是 Native 代码？"

### 场景

AsyncGetCallTrace 可能失败（返回负值），失败后 async-profiler 需要判断线程状态来决定恢复策略：
- **线程在 Java 状态**（`_thread_in_Java = 8`）→ 尝试 native 栈展开到 Java 帧
- **线程在 VM/Native 状态** → 用 JavaFrameAnchor 恢复

### 偏移量与使用

| 偏移量 | 值 | JVM 字段 | 使用位置 | 作用 |
|--------|:--:|---------|---------|------|
| `_thread_state_offset` | 1040 | `JavaThread::_thread_state` | `VMThread::inJava()` | 判断 `state() == 8` |
| `_thread_vframe_offset` | 952 | `JavaThread::_vframe_array_head` | `VMThread::inDeopt()` | 判断是否在反优化中 |
| `_comp_env_offset` | 1896 | `CompilerThread::_env` | `VMThread::compiledMethod()` | 获取编译线程正在编译的方法 |

### 关键代码路径

```cpp
// profiler.cpp:404 — 信号处理器中
if (_features.unwind_native && vm_thread->inJava()) {
    // 线程在 Java 状态 → 可以安全做 native 栈展开
    frame.restore(java_ctx->pc, java_ctx->sp, java_ctx->fp);
}

// stackWalker.cpp:342 — 解释器帧处理
if (vm_thread != NULL && vm_thread->inDeopt()) {
    // 线程在反优化中 → 帧结构不完整，停止回溯
    fillFrame(frames[depth++], BCI_ERROR, "break_deopt");
    break;
}

// stackWalker.cpp:418 — 编译线程的伪 Java 帧
VMMethod* method = vm_thread->compiledMethod();
// 通过 CompilerThread→ciEnv→CompileTask→Method 三级指针链获取正在编译的方法
```

### `compiledMethod()` 的三级指针链

这个值得详细解释，因为它涉及 3 个偏移量的链式使用：

```
CompilerThread         ciEnv              CompileTask         Method
┌──────────────┐    ┌──────────┐       ┌──────────────┐    ┌────────┐
│ ...          │    │ ...      │       │ ...          │    │ ...    │
│ _env (1896)──┼───→│ _task(128┼──────→│ _method(24)──┼───→│        │
│ ...          │    │ ...      │       │ ...          │    │        │
└──────────────┘    └──────────┘       └──────────────┘    └────────┘
```

**GDB 交叉验证**:
```
asprof _comp_env_offset  = 1896    vs JVM &((CompilerThread*)0)->_env = 1896    ✅
asprof _comp_task_offset = 128     vs 通过 gHotSpotVMStructs 获取               ✅
asprof _comp_method_offset = 24    vs 通过 gHotSpotVMStructs 获取               ✅
```

---

## 四、[C] Java 帧锚组 — "最后一个 Java 帧在哪里？"

### 场景

当线程不在 Java 状态（在 VM/Native 中）时，`AsyncGetCallTrace` 依赖 `JavaFrameAnchor` 找到最后一个 Java 帧的 SP/PC/FP。async-profiler 在 ASGCT 失败时，也会直接读取 anchor 进行恢复。

### 偏移量与使用

| 偏移量 | 值 | JVM 字段 | 使用位置 | 作用 |
|--------|:--:|---------|---------|------|
| `_thread_anchor_offset` | 888 | `JavaThread::_anchor` | `VMThread::anchor()` | 从线程拿到 anchor |
| `_anchor_sp_offset` | 0 | `JavaFrameAnchor::_last_Java_sp` | `anchor->lastJavaSP()` | 读取最后 Java SP |
| `_anchor_pc_offset` | 8 | `JavaFrameAnchor::_last_Java_pc` | `anchor->lastJavaPC()` | 读取最后 Java PC |
| `_anchor_fp_offset` | 16 | `JavaFrameAnchor::_last_Java_fp` | `anchor->lastJavaFP()` | 读取最后 Java FP |
| `_call_wrapper_anchor_offset` | 40 | `JavaCallWrapper::_anchor` | `JavaFrameAnchor::fromEntryFrame()` | Entry 帧→anchor |

### 关键代码路径（profiler.cpp:485-507）

```
ASGCT 返回 ticks_unknown_not_Java (-3)
  → "线程不在 Java 中，ASGCT 不知道怎么走"
  → 读取 anchor: vm_thread->anchor()
    → sp = anchor->lastJavaSP()    // at(0)  = _last_Java_sp
    → pc = anchor->lastJavaPC()    // at(8)  = _last_Java_pc
  → 如果 sp != 0 但 pc == NULL:
    → "anchor 有但没标记为 walkable"
    → 手动从栈上恢复 pc: pc = ((void**)sp)[-1]
    → 设置 anchor->setLastJavaPC(pc)  → 写入 at(8)
    → 重试 ASGCT（这次能成功了）
    → 恢复 anchor->setLastJavaPC(NULL) → 清除痕迹
```

**这是 async-profiler 的核心创新之一**：当 ASGCT 因为 anchor 不可行走而失败时，async-profiler 自己修复 anchor（从栈上推断 PC），让 ASGCT 重试。这大大降低了"unknown_not_Java"采样丢失率。

### Entry 帧过渡（stackWalker.cpp:370）

```
Java 代码 → JavaCalls::call_helper → call_stub → native 代码
                    ↑
              JavaCallWrapper 保存了 anchor
              从 Entry 帧的 FP 找到 JavaCallWrapper → _anchor(40) → 下一个 anchor
              → 继续回溯更深层的 Java 帧
```

---

## 五、[D] CodeHeap 组 — "这个 PC 地址对应哪个编译方法？"

### 场景

栈回溯时，每遇到一个 PC 地址，需要判断它是否在 JVM 的 CodeHeap 中。如果是，需要快速找到对应的 `NMethod`。

### 偏移量与使用

| 偏移量 | 值 | JVM 字段 | 使用位置 | 作用 |
|--------|:--:|---------|---------|------|
| `_code_heap_addr` | ptr | `CodeCache::_heaps` | `resolveOffsets()` | CodeHeap 数组基地址 |
| `_code_heap_low_addr` | ptr | `CodeCache::_low_bound` | `CodeHeap::contains()` | 范围检查下界 |
| `_code_heap_high_addr` | ptr | `CodeCache::_high_bound` | `CodeHeap::contains()` | 范围检查上界 |
| `_code_heap_memory_offset` | 8 | `CodeHeap::_memory` | `findNMethod()` | 内存区域的 VirtualSpace |
| `_code_heap_segmap_offset` | 120 | `CodeHeap::_segmap` | `findNMethod()` | segment map（快速定位） |
| `_code_heap_segment_shift` | *(运行时) | `CodeHeap::_log2_segment_size` | `findNMethod()` | 地址→segment 索引 |
| `_vs_low_offset` | 16 | `VirtualSpace::_low` | `findNMethod()` | 已使用空间下界 |
| `_heap_block_used_offset` | 8 | `HeapBlock::Header::_used` | `findNMethod()` | block 是否在使用 |

### CodeHeap::findNMethod 算法（vmStructs.cpp:691）

这是一个 O(1) 查找算法，不需要遍历：

```
                    CodeHeap
    ┌────────────────────────────────────────────┐
    │ _memory (VirtualSpace)                     │
    │   _low ─→ ┌──────────────────────────┐     │
    │           │ HeapBlock[0] | code...    │     │
    │           │ HeapBlock[1] | code...    │ ← PC│
    │           │ HeapBlock[2] | code...    │     │
    │   _high─→ └──────────────────────────┘     │
    │                                            │
    │ _segmap (VirtualSpace)                     │
    │   _low ─→ ┌──────────────────────────┐     │
    │           │ 0 | 1 | 2 | 0 | 1 | ff  │     │
    │           └──────────────────────────┘     │
    └────────────────────────────────────────────┘

    查找步骤:
    1. idx = (PC - heap_start) >> _segment_shift    // O(1) 地址→索引
    2. while segmap[idx] > 0: idx -= segmap[idx]    // 回溯到 block 头部
    3. block = heap_start + (idx << _segment_shift)  // 索引→block地址
    4. 如果 block._used == true → return NMethod*
```

**segmap 回溯原理**: segmap[i] 记录的是"从当前 segment 到 block 起始需要后退多少个 segment"。0 表示这就是 block 起始；>0 表示后退 segmap[i] 步；0xff 表示空闲。

---

## 六、[E] NMethod 组 — "这个编译方法的详细信息是什么？"

### 场景

找到 NMethod 后，需要读取：方法指针、是否存活、入口地址、scope 信息（用于内联展开）。

### 偏移量与使用

| 偏移量 | 值 | JVM 字段 | 使用位置 | 作用 |
|--------|:--:|---------|---------|------|
| `_nmethod_method_offset` | 128 | `nmethod::_method` | `NMethod::method()` | 获取 `VMMethod*` |
| `_nmethod_entry_offset` | **-272** | `nmethod::_verified_entry_point` | `NMethod::entry()` | 方法入口地址 |
| `_nmethod_state_offset` | 351 | `nmethod::_state` | `NMethod::isAlive()` | 判断编译方法是否有效 |
| `_nmethod_level_offset` | 344 | `nmethod::_comp_level` | `NMethod::level()` | C1(1-3) vs C2(4) |
| `_blob_size_offset` | 12 | `CodeBlob::_size` | `NMethod::size()` | 代码块总大小 |
| `_frame_size_offset` | 28 | `CodeBlob::_frame_size` | `NMethod::frameSize()` | 栈帧大小(words) |
| `_code_offset` | **-32** | `CodeBlob::_code_begin` | `NMethod::code()` | 机器码起始地址 |
| `_nmethod_name_offset` | 112 | `CodeBlob::_name` | `NMethod::name()` | "nmethod"/"Interpreter" |

### 正负号编码的关键理解

- `_nmethod_entry_offset = -272`：负号表示 `_verified_entry_point` 是一个**绝对地址指针**（`void*`）

  ```cpp
  // JDK 11 存法: void* _verified_entry_point
  const void* entry() { return *(void**) at(-(-272)); }  // = *(void**) at(272)
  
  // JDK 23+ 存法: unsigned short _verified_entry_offset (相对偏移)
  const void* entry() { return at(*(int*)at(_code_offset) + *(unsigned short*)at(_nmethod_entry_offset)); }
  ```

- `_code_offset = -32`：负号表示 `_code_begin` 是指针

  ```cpp
  const char* code() { return *(const char**) at(-(-32)); }  // = *(char**) at(32)
  ```

### 在栈回溯中的使用（stackWalker.cpp:288-327）

```cpp
NMethod* nm = CodeHeap::findNMethod(pc);
if (nm->isNMethod()) {
    int level = nm->level();                    // _nmethod_level_offset=344
    fillFrame(frames[depth++], type, 0, nm->method()->id());  // _nmethod_method_offset=128
    
    if (nm->isFrameCompleteAt(pc)) {           // _frame_complete_offset=20
        int scope_offset = nm->findScopeOffset(pc);  // _scopes_pcs_offset=316
        // 如果有内联方法，展开 ScopeDesc
        ScopeDesc scope(nm);                   // _scopes_data_offset=-136
        scope.decode(scope_offset);            // 读取 scope 链
        
        sp += nm->frameSize() * sizeof(void*); // _frame_size_offset=28
        fp = ((uintptr_t*)sp)[-2];
        pc = ((void**)sp)[-1];
    }
}
```

### GDB 交叉验证

```
asprof _nmethod_method_offset     = 128   vs JVM &((nmethod*)0)->_method               = 128   ✅
asprof _nmethod_state_offset      = 351   vs JVM &((nmethod*)0)->_state                = 351   ✅
asprof |_nmethod_entry_offset|    = 272   vs JVM &((nmethod*)0)->_verified_entry_point = 272   ✅
asprof |_scopes_data_offset|      = 136   vs JVM &((nmethod*)0)->_scopes_data_begin    = 136   ✅
asprof _scopes_pcs_offset         = 316   vs JVM &((nmethod*)0)->_scopes_pcs_offset    = 316   ✅
asprof _nmethod_level_offset      = 344   vs JVM &((nmethod*)0)->_comp_level           = 344   ✅
asprof _blob_size_offset          = 12    vs JVM &((CodeBlob*)0)->_size                = 12    ✅
asprof _frame_size_offset         = 28    vs JVM &((CodeBlob*)0)->_frame_size          = 28    ✅
asprof |_code_offset|             = 32    vs JVM &((CodeBlob*)0)->_code_begin          = 32    ✅
asprof _nmethod_name_offset       = 112   vs JVM &((CodeBlob*)0)->_name               = 112   ✅
asprof _frame_complete_offset     = 20    vs JVM &((CodeBlob*)0)->_frame_complete_offset= 20   ✅
asprof _data_offset               = 24    vs JVM &((CodeBlob*)0)->_data_offset         = 24    ✅
```

---

## 七、[F] 方法元数据组 — "从 NMethod 到类名和方法名"

### 场景

拿到 `VMMethod*` 后，需要获取 `jmethodID`，最终用于输出火焰图/JFR 中的方法名。

### 偏移量与使用

| 偏移量 | 值 | JVM 字段 | 使用位置 | 作用 |
|--------|:--:|---------|---------|------|
| `_method_constmethod_offset` | 16 | `Method::_constMethod` | `VMMethod::id()` | Method→ConstMethod |
| `_method_code_offset` | 80 | `Method::_code` | `VMMethod::code()` | Method→NMethod |
| `_constmethod_constants_offset` | 8 | `ConstMethod::_constants` | `VMMethod::id()` | ConstMethod→ConstantPool |
| `_constmethod_idnum_offset` | 46 | `ConstMethod::_method_idnum` | `VMMethod::id()` | 方法在类中的编号 |
| `_constmethod_size` | 56 | `sizeof(ConstMethod)` | `VMMethod::bytecode()` | bytecode 在 ConstMethod 末尾 |
| `_pool_holder_offset` | 32 | `ConstantPool::_pool_holder` | `VMMethod::id()` | ConstantPool→InstanceKlass |
| `_jmethod_ids_offset` | 344 | `InstanceKlass::_methods_jmethod_ids` | `VMKlass::jmethodIDs()` | jmethodID 数组 |

### VMMethod::id() — 方法 ID 解析链（vmStructs.cpp:659）

这是最复杂的指针链之一，涉及 6 个偏移量：

```
VMMethod* this
  │
  ├─ at(_method_constmethod_offset=16) → ConstMethod*
  │   ├─ at(_constmethod_constants_offset=8) → ConstantPool*
  │   │   └─ at(_pool_holder_offset=32) → InstanceKlass* holder
  │   │       └─ at(_jmethod_ids_offset=344) → jmethodID* ids[]
  │   │           └─ ids[idnum + 1] → jmethodID
  │   └─ at(_constmethod_idnum_offset=46) → unsigned short idnum
  │
  └─ 返回 jmethodID

内存布局:
┌─────────┐  +16  ┌──────────────┐  +8   ┌──────────────┐  +32  ┌──────────────┐
│ Method  │──────→│ ConstMethod  │──────→│ ConstantPool │──────→│InstanceKlass │
│         │       │ _idnum(+46)  │       │              │       │ _jmethod_ids │
│ _code(80)│      │ bytecodes(56)│       │              │       │   (+344)     │
└─────────┘       └──────────────┘       └──────────────┘       └──────┬───────┘
                                                                       │
                      jmethodID = ids[idnum + 1]  ←────────────────────┘
```

### GDB 交叉验证

```
asprof _method_constmethod_offset    = 16  vs JVM &((Method*)0)->_constMethod         = 16  ✅
asprof _method_code_offset           = 80  vs JVM &((Method*)0)->_code                = 80  ✅
asprof _constmethod_constants_offset = 8   vs JVM &((ConstMethod*)0)->_constants      = 8   ✅
asprof _constmethod_idnum_offset     = 46  vs JVM &((ConstMethod*)0)->_method_idnum   = 46  ✅
asprof _constmethod_size             = 56  vs JVM sizeof(ConstMethod)                 = 56  ✅
asprof _pool_holder_offset           = 32  vs JVM &((ConstantPool*)0)->_pool_holder   = 32  ✅
asprof _jmethod_ids_offset           = 344 vs JVM &((InstanceKlass*)0)->_methods_jmethod_ids = 344 ✅
asprof _methods_offset               = 416 vs JVM &((InstanceKlass*)0)->_methods      = 416 ✅
```

---

## 八、[G] 对象头/类名组 — "这个 oop 是什么类的实例？"

### 场景

在 VTable Stub 帧中（虚方法调用），async-profiler 会尝试从接收者对象（receiver）解析类名，辅助诊断虚方法调度的目标。在分配追踪中也需要从 oop 解析类名。

### 偏移量与使用

| 偏移量 | 值 | JVM 字段 | 使用位置 | 作用 |
|--------|:--:|---------|---------|------|
| `_oop_klass_offset` | 8 | `oopDesc::_metadata._klass` | `VMKlass::fromOop()` | oop→Klass（非压缩） |
| `_narrow_klass_base` | ptr | 运行时值 | `VMKlass::fromOop()` | 压缩 Klass 基地址 |
| `_narrow_klass_shift` | int | 运行时值 | `VMKlass::fromOop()` | 压缩 Klass 位移 |
| `_klass_name_offset` | 24 | `Klass::_name` | `VMKlass::name()` | Klass→Symbol |
| `_symbol_length_offset` | 0 | `Symbol::_length` | `VMSymbol::length()` | 类名长度 |
| `_symbol_body_offset` | 6 | `Symbol::_body` | `VMSymbol::body()` | 类名 UTF-8 数据 |
| `_klass` | jfieldID | `java.lang.Class::klass` | `VMKlass::fromJavaClass()` | Class→Klass |

### VMKlass::fromOop() 解压缩逻辑

```cpp
// 非压缩模式（_narrow_klass_shift < 0）
VMKlass* klass = *(VMKlass**)(oop + 8);

// 压缩模式（JDK 11 默认）
uint32_t narrow_klass = *(uint32_t*)(oop + 8);
VMKlass* klass = (VMKlass*)(_narrow_klass_base + (narrow_klass << _narrow_klass_shift));
```

### 使用场景（stackWalker.cpp:384, profiler.cpp:440）

```cpp
// VTable Stub 帧：从接收者对象获取目标类名
uintptr_t receiver = frame.jarg0();
VMSymbol* symbol = VMKlass::fromOop(receiver)->name();
u32 class_id = classMap()->lookup(symbol->body(), symbol->length());
```

---

## 九、[H] JVMFlag + 帧结构 + 杂项

### JVMFlag 查询

| 偏移量 | 值 | 使用场景 |
|--------|:--:|---------|
| `_flags_addr` | ptr | JVMFlag 数组基地址 |
| `_flag_count` | 1366 | JVMFlag 总数 |
| `_flag_size` | 48 | 每个 JVMFlag 的大小 |
| `_flag_name_offset` | 8 | Flag 名字字段偏移 |
| `_flag_addr_offset` | 16 | Flag 值地址偏移 |

用于查询 `UseCompressedClassPointers`、`UseCompactObjectHeaders` 等运行时参数。

### 帧结构

| 偏移量 | 值 | 使用场景 |
|--------|:--:|---------|
| `_entry_frame_call_wrapper_offset` | -48 | Entry 帧中 JavaCallWrapper 的位置 |
| `_call_stub_return_addr` | ptr | `StubRoutines::_call_stub_return_address` |
| `_interpreter_frame_bcp_offset` | -8 | 解释器帧中 BCP 的栈槽偏移 |

### _interpreter_frame_bcp_offset 的平台差异

```cpp
#if defined(__x86_64__)
    _interpreter_frame_bcp_offset = VM::hotspot_version() >= 11 ? -8 : VM::hotspot_version() == 8 ? -7 : 0;
#elif defined(__aarch64__)
    _interpreter_frame_bcp_offset = VM::hotspot_version() >= 11 ? -9 : VM::hotspot_version() == 8 ? -7 : 0;
```

---

## 十、特性标志 — 偏移量推断成功了吗？

`resolveOffsets()` 最后会设置 5 个 `_has_xxx` 标志，每个标志代表一组偏移量是否全部推断成功：

```
_has_class_names     = _klass_name_offset >= 0 && _oop_klass_offset >= 0
                       && (_symbol_length_offset >= 0) && _symbol_body_offset >= 0
                       && _klass != NULL
                     → 能解析类名吗？

_has_method_structs  = _jmethod_ids_offset >= 0 && _nmethod_method_offset >= 0
                       && _nmethod_entry_offset != -1 && _nmethod_state_offset >= 0
                       && _method_constmethod_offset >= 0 && ... (全部方法相关偏移量)
                     → 能解析方法ID吗？

_has_compiler_structs= _comp_env_offset >= 0 && _comp_task_offset >= 0
                       && _comp_method_offset >= 0
                     → 能获取编译任务吗？

_has_class_loader_data = _class_loader_data_offset >= 0 && _methods_offset >= 0
                         && _lock_func != NULL && _unlock_func != NULL
                     → 能遍历 CLD 优化加载吗？（JDK 11 = false）

_has_stack_structs   = _has_method_structs && _call_wrapper_anchor_offset >= 0
                       && _entry_frame_call_wrapper_offset != -1
                       && _code_offset != -1 && _scopes_data_offset != -1 && ...
                     → 能做 VM 模式栈回溯吗？
```

**GDB 验证结果**（JDK 11 slowdebug）：
```
_has_class_names      = true   ✅ 可以解析类名
_has_method_structs   = true   ✅ 可以解析方法
_has_compiler_structs = true   ✅ 可以获取编译任务
_has_class_loader_data= false  ⚠️ 不走 CLD 优化路径
_has_stack_structs    = true   ✅ 可以做 VM 模式栈回溯
```

---

## 十一、总结：偏移量在采样流程中的使用时序

```
SIGPROF 到达
  ↓
[A] 线程识别: _tls_index → VMThread* → _env_offset → JNIEnv*
  ↓
[B] 线程状态: _thread_state_offset → inJava()? → 决定栈展开策略
  ↓
    AsyncGetCallTrace(jni, frames, ucontext)
  ↓ 如果 ASGCT 失败:
[C] 帧锚恢复: _thread_anchor_offset → anchor → lastJavaSP/PC/FP
  ↓
    开始栈回溯 (walkVM)
  ↓
[D] CodeHeap: PC → segment map → HeapBlock → NMethod*
  ↓
[E] NMethod: → method(), name(), isAlive(), frameSize(), findScopeOffset()
  ↓
[F] 方法元数据: NMethod → VMMethod → ConstMethod → ConstantPool → Klass → jmethodID
  ↓
[G] 类名解析: oop → klass → name → Symbol → body/length
  ↓
    写入 CallTraceStorage / FlightRecorder / FlameGraph
```

---

*创建日期: 2026-02-09*
*GDB 验证环境: OpenJDK 11 slowdebug + async-profiler v4.0 (git 00a0a12)*
*全部 60+ 偏移量交叉验证: **100% 匹配***