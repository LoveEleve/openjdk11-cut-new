# Lesson 14：AsyncGetCallTrace 源码深度解析

> **学习目标**：深入理解 JVM AsyncGetCallTrace 的完整实现机制，掌握异步栈遍历的核心原理、并发安全问题和性能影响。

---

## 一、问题引入：为什么需要 AsyncGetCallTrace？

### 1.1 场景：CPU Profiler 的工作原理

CPU Profiler 需要回答这个问题：**"线程当前正在执行哪个方法？"**

传统的方案：
1. **JMX ThreadInfo.getStackTrace()** - 需要 STW，会暂停线程
2. **JVMTI GetStackTrace()** - 同样需要线程暂停

**问题**：暂停线程会改变程序行为，无法真实反映运行时状态。

### 1.2 AsyncGetCallTrace 的核心思路

**信号驱动的异步采样**：
1. Perf 事件触发 SIGPROF 信号
2. 信号处理器中调用 AsyncGetCallTrace
3. **不暂停线程**，直接从当前上下文（ucontext）重建栈帧

**代价**：
- 不能加锁（信号处理器上下文）
- 可能看到中间状态（GC、Deopt）
- 错误处理复杂（错误码而非异常）

---

## 二、核心数据结构

### 2.1 ASGCT_CallFrame（单个栈帧）

```c
// forte.cpp:39-42
typedef struct {
    jint lineno;          // BCI（字节码偏移）或特殊值
    jmethodID method_id;  // 方法标识
} ASGCT_CallFrame;
```

**lineno 的含义**：
- `>= 0`：Java 方法的 BCI（字节码索引）
- `-1`：BCI 不可用
- `-3`：Native 方法

**jmethodID**：
- 在类加载时分配（需要 CLASS_LOAD 事件启用）
- 用于避免信号处理器中加锁分配

### 2.2 ASGCT_CallTrace（调用栈）

```c
// forte.cpp:45-49
typedef struct {
    JNIEnv *env_id;       // 标识线程
    jint num_frames;      // 帧数量或错误码
    ASGCT_CallFrame *frames;  // 帧数组
} ASGCT_CallTrace;
```

**num_frames 的含义**：
- `>= 0`：成功获取的帧数量
- `< 0`：错误码（详见下文）

### 2.3 错误码枚举

```c
// forte.cpp:52-64
enum {
  ticks_no_Java_frame         =  0,   // 没有 Java 帧
  ticks_no_class_load         = -1,   // 未启用 CLASS_LOAD 事件
  ticks_GC_active             = -2,   // GC 正在进行
  ticks_unknown_not_Java      = -3,   // 非 Java 状态下无法识别帧
  ticks_not_walkable_not_Java = -4,   // 非 Java 状态下帧不可遍历
  ticks_unknown_Java          = -5,   // Java 状态下无法识别帧
  ticks_not_walkable_Java     = -6,   // Java 状态下帧不可遍历
  ticks_unknown_state         = -7,   // 未知线程状态
  ticks_thread_exit           = -8,   // 线程正在退出
  ticks_deopt                 = -9,   // 正在去优化
  ticks_safepoint             = -10   // Safepoint（未使用）
};
```

---

## 三、主流程逐行解析

### 3.1 AsyncGetCallTrace 主入口（523-615 行）

#### 函数签名

```c
// forte.cpp:523
void AsyncGetCallTrace(ASGCT_CallTrace *trace, jint depth, void* ucontext)
```

**参数**：
- `trace`：调用者分配的结构，用于返回结果
- `depth`：最大栈深度（trace->frames 数组大小）
- `ucontext`：信号上下文（包含寄存器状态）

**调用者**：AsyncProfiler 的信号处理器

#### 步骤 1：线程验证（526-533 行）

```c
// forte.cpp:526-533
if (trace->env_id == NULL ||
    (thread = JavaThread::thread_from_jni_environment(trace->env_id)) == NULL ||
    thread->is_exiting()) {
  trace->num_frames = ticks_thread_exit; // -8
  return;
}
```

**逻辑**：
1. `env_id == NULL`：参数错误
2. `thread_from_jni_environment` 返回 NULL：无效的 JNIEnv
3. `is_exiting()`：线程正在退出

**寄存器/栈状态**（x86_64 Linux）：
```
RDI = trace (第一个参数)
RSI = depth (第二个参数)
RDX = ucontext (第三个参数)
RAX = thread (返回值)
```

**并发安全问题**：
- 无锁读取线程状态
- 可能的 TOCTOU（Time-Of-Check-To-Time-Of-Use）：检查后状态可能改变
- **后果**：返回错误码，上层忽略本次采样

#### 步骤 2：Deopt 检查（535-539 行）

```c
// forte.cpp:535-539
if (thread->in_deopt_handler()) {
  trace->num_frames = ticks_deopt; // -9
  return;
}
```

**什么是 Deopt**？
- 编译代码回退到解释执行
- 栈帧正在被修改，不可遍历

**如何判断**？
- 线程进入 Deopt 处理器时设置标志
- 处理完毕后清除

**时间窗口**：
- Deopt 处理器执行期间（通常几微秒）
- 期间无法栈遍历

#### 步骤 3：断言检查（541-542 行）

```c
// forte.cpp:541-542
assert(JavaThread::current() == thread,
       "AsyncGetCallTrace must be called by the current interrupted thread");
```

**含义**：AsyncGetCallTrace **必须**被当前线程调用（信号处理器在目标线程上下文执行）

**如果断言失败**：
- slowdebug 版本：JVM 崩溃
- product 版本：继续执行（可能导致数据不一致）

#### 步骤 4：CLASS_LOAD 检查（544-547 行）

```c
// forte.cpp:544-547
if (!JvmtiExport::should_post_class_load()) {
  trace->num_frames = ticks_no_class_load; // -1
  return;
}
```

**为什么需要 CLASS_LOAD 事件**？
- jmethodID 在类加载时分配
- 信号处理器不能加锁分配新的 jmethodID

**AsyncProfiler 要求**：
- `-XX:+TraceClassLoading` 或使用 JVMTI Agent
- AsyncProfiler 自己实现了 Agent，启用 CLASS_LOAD

#### 步骤 5：GC 检查（549-552 行）

```c
// forte.cpp:549-552
if (Universe::heap()->is_gc_active()) {
  trace->num_frames = ticks_GC_active; // -2
  return;
}
```

**GC 活跃时的问题**：
1. 对象可能被移动（指针失效）
2. 栈帧可能被修改（GC Root 扫描）
3. Method* 可能失效

**is_gc_active 实现**：
```c
bool is_gc_active() const {
  return _gc_active; // 原子变量
}
```

**时间窗口**：
- GC 周期通常几毫秒到几百毫秒
- 期间所有采样都会失败（ticks_GC_active）

#### 步骤 6：设置 ASGCT 标志（554-555 行）

```c
// forte.cpp:554-555
thread->set_in_asgct(true);
```

**用途**：
- 标记线程正在执行 ASGCT
- 某些操作（如 Deopt）会检查此标志并等待

**必须在所有 return 前清除**（614 行）：
```c
thread->set_in_asgct(false);
```

#### 步骤 7：线程状态分发（557-613 行）

```c
// forte.cpp:557-613
switch (thread->thread_state()) {
case _thread_new:
case _thread_uninitialized:
case _thread_new_trans:
  trace->num_frames = 0;  // 新线程，还没有 Java 帧
  break;

case _thread_in_native:
case _thread_in_native_trans:
case _thread_blocked:
case _thread_blocked_trans:
case _thread_in_vm:
case _thread_in_vm_trans:
  // 处理非 Java 状态（详见下文）
  break;

case _thread_in_Java:
case _thread_in_Java_trans:
  // 处理 Java 状态（详见下文）
  break;

default:
  trace->num_frames = ticks_unknown_state; // -7
  break;
}
```

**线程状态转换图**：
```
_thread_new → _thread_in_Java → _thread_in_native
                    ↓                   ↓
               _thread_in_vm       _thread_blocked
```

---

### 3.2 非 Java 状态处理（565-594 行）

#### 代码详解

```c
// forte.cpp:565-594
case _thread_in_native:
case _thread_in_native_trans:
case _thread_blocked:
case _thread_blocked_trans:
case _thread_in_vm:
case _thread_in_vm_trans:
{
  frame fr;

  // 从 ucontext 获取顶层帧
  // isInJava = false 表示不在执行 Java 代码
  if (!thread->pd_get_top_frame_for_signal_handler(&fr, ucontext, false)) {
    trace->num_frames = ticks_unknown_not_Java;  // -3
  } else {
    if (!thread->has_last_Java_frame()) {
      trace->num_frames = 0;  // 没有 Java 帧
    } else {
      trace->num_frames = ticks_not_walkable_not_Java;  // -4 默认值
      forte_fill_call_trace_given_top(thread, trace, depth, fr);
      // 可能会覆盖 num_frames
    }
  }
}
break;
```

**pd_get_top_frame_for_signal_handler 实现**（平台相关，以 Linux x86_64 为例）：

```c
// os_linux_x86.cpp
bool JavaThread::pd_get_top_frame_for_signal_handler(frame* fr, void* ucontext, bool isInJava) {
  ucontext_t* uc = (ucontext_t*) ucontext;

  // 从 ucontext 提取寄存器
  address pc = (address)uc->uc_mcontext.gregs[REG_PC];
  address sp = (address)uc->uc_mcontext.gregs[REG_SP];
  address fp = (address)uc->uc_mcontext.gregs[REG_FP];

  // 构造 frame 对象
  *fr = frame(pc, sp, fp);
  return true;
}
```

**关键点**：
- 从 `ucontext` 提取 PC/SP/FP
- `isInJava` 参数影响帧校验逻辑
- 非 Java 状态下，顶层帧可能是 C/C++ 帧

**has_last_Java_frame 含义**：
- JVM 在调用 Java 方法时设置 `last_Java_frame` 锚点
- 用于在 C++ 调用链中找到 Java 栈起点

---

### 3.3 Java 状态处理（595-608 行）

#### 代码详解

```c
// forte.cpp:595-608
case _thread_in_Java:
case _thread_in_Java_trans:
{
  frame fr;

  // isInJava = true 表示正在执行 Java 代码
  if (!thread->pd_get_top_frame_for_signal_handler(&fr, ucontext, true)) {
    trace->num_frames = ticks_unknown_Java;  // -5
  } else {
    trace->num_frames = ticks_not_walkable_Java;  // -6 默认值
    forte_fill_call_trace_given_top(thread, trace, depth, fr);
  }
}
break;
```

**Java 状态的特殊性**：
- 当前正在执行 Java 字节码（解释或编译）
- 顶层帧一定是 Java 帧
- 但可能正在 Safepoint 检查点

---

## 四、核心函数逐行解析

### 4.1 forte_fill_call_trace_given_top（416-464 行）

#### 函数签名

```c
// forte.cpp:416-419
static void forte_fill_call_trace_given_top(JavaThread* thd,
                                            ASGCT_CallTrace* trace,
                                            int depth,
                                            frame top_frame)
```

**作用**：从 `top_frame` 开始遍历栈帧，填充 `trace->frames` 数组

#### 步骤 1：找到第一个 Java 帧（432 行）

```c
// forte.cpp:432
find_initial_Java_frame(thd, &top_frame, &initial_Java_frame, &method, &bci);
```

**为什么需要 find_initial_Java_frame**？
- `top_frame` 可能不是 Java 帧（如 C++ Stub）
- 需要跳过非 Java 帧，找到第一个可遍历的 Java 帧

#### 步骤 2：验证 Method（437-440 行）

```c
// forte.cpp:437-440
if (!Method::is_valid_method(method)) {
  trace->num_frames = ticks_GC_active; // -2
  return;
}
```

**is_valid_method 实现**：
```c
// method.cpp
bool Method::is_valid_method(Method* m) {
  if (m == NULL) return false;

  // 检查是否在 Metaspace 有效范围内
  if (!Metaspace::contains(m)) return false;

  // 检查签名魔数
  return m->is_valid();
}
```

**失败原因**：
- GC 移动了 Method（但应该在 GC 活跃检查时已返回）
- 内存损坏

#### 步骤 3：栈遍历循环（444-461 行）

```c
// forte.cpp:444-461
vframeStreamForte st(thd, initial_Java_frame, false);

for (; !st.at_end() && count < depth; st.forte_next(), count++) {
  bci = st.bci();
  method = st.method();

  if (!Method::is_valid_method(method)) {
    trace->num_frames = ticks_GC_active; // -2
    return;  // 丢弃所有已采集的帧
  }

  trace->frames[count].method_id = method->find_jmethod_id_or_null();
  if (!method->is_native()) {
    trace->frames[count].lineno = bci;
  } else {
    trace->frames[count].lineno = -3;  // Native 方法标记
  }
}
trace->num_frames = count;
```

**vframeStreamForte**：
- 继承自 `vframeStreamCommon`
- 实现异步安全的栈遍历（见下文）

**循环逻辑**：
1. 每次迭代获取当前帧的 BCI 和 Method
2. 验证 Method 有效性
3. 查找 jmethodID
4. 填充 trace->frames[count]

---

### 4.2 find_initial_Java_frame（296-414 行）

#### 核心逻辑流程图

```
输入：top_frame（可能是任意帧）
输出：initial_Java_frame（第一个可遍历的 Java 帧）

流程：
1. 如果 top_frame.cb() == NULL：
   → 循环查找第一个有 CodeBlob 的帧

2. 遍历候选帧：
   - entry_frame：检查 JavaCallWrapper
   - interpreted_frame：验证是否可解析
   - compiled_frame：验证是否可解析
   - stub_frame：跳过，继续查找

3. 返回结果：
   - method_p != NULL：找到 Java 方法
   - initial_frame_p：可遍历的帧
   - 返回值：帧是否可解析
```

#### 关键代码段 1：跳过无 CodeBlob 的帧（320-333 行）

```c
// forte.cpp:320-333
if (fr->cb() == NULL) {
  int loop_count;
  int loop_max = MaxJavaStackTraceDepth * 2;
  RegisterMap map(thread, false);

  for (loop_count = 0; loop_max == 0 || loop_count < loop_max; loop_count++) {
    if (!candidate.safe_for_sender(thread)) return false;
    candidate = candidate.sender(&map);
    if (candidate.cb() != NULL) break;
  }
  if (candidate.cb() == NULL) return false;
}
```

**CodeBlob**：
- JVM 生成的代码块（编译方法、Stub、Runtime Stub）
- 没有 CodeBlob 的帧通常是 C/C++ 代码

**safe_for_sender**：
- 检查帧指针是否在合理范围内
- 防止栈溢出和内存错误

#### 关键代码段 2：处理 entry_frame（343-351 行）

```c
// forte.cpp:343-351
if (candidate.is_entry_frame()) {
  JavaCallWrapper *jcw = candidate.entry_frame_call_wrapper_if_safe(thread);
  if (jcw == NULL || jcw->is_first_frame()) {
    return false;  // 没有关联的 Java 帧
  }
}
```

**entry_frame**：
- C++ 调用 Java 方法的入口帧
- 包含 `JavaCallWrapper`，记录调用信息

**is_first_frame**：
- 第一个 entry_frame，之前没有 Java 帧

#### 关键代码段 3：处理解释帧（353-361 行）

```c
// forte.cpp:353-361
if (candidate.is_interpreted_frame()) {
  if (is_decipherable_interpreted_frame(thread, &candidate, method_p, bci_p)) {
    *initial_frame_p = candidate;
    return true;
  }
  return false;  // 找到解释帧但不可解析
}
```

**is_decipherable_interpreted_frame 详解**（见下文）

#### 关键代码段 4：处理编译帧（363-397 行）

```c
// forte.cpp:363-397
if (candidate.cb()->is_compiled()) {
  CompiledMethod* nm = candidate.cb()->as_compiled_method();
  *method_p = nm->method();

  *bci_p = -1;  // 编译帧默认无 BCI
  *initial_frame_p = candidate;

  if (nm->is_native_method()) return true;  // Native 方法直接返回

  if (!is_decipherable_compiled_frame(thread, &candidate, nm)) {
    return false;  // 找到编译帧但不可解析
  }

  *initial_frame_p = candidate;  // is_decipherable 可能修改 PC
  return true;
}
```

**编译帧的特殊性**：
- Native 方法：无需 BCI
- Java 方法：需要 PcDesc 才能获取 BCI

---

### 4.3 is_decipherable_interpreted_frame（213-265 行）

#### 函数签名

```c
// forte.cpp:213-216
static bool is_decipherable_interpreted_frame(JavaThread* thread,
                                              frame* fr,
                                              Method** method_p,
                                              int* bci_p)
```

**作用**：验证解释帧是否可遍历

#### 关键代码段 1：线程状态检查（228-231 行）

```c
// forte.cpp:228-231
JavaThreadState state = thread->thread_state();
bool known_valid = (state == _thread_in_native ||
                    state == _thread_in_vm ||
                    state == _thread_blocked);
```

**为什么这些状态"已知有效"**？
- `_thread_in_native`：线程在执行 Native 代码，解释帧已完整构造
- `_thread_in_vm`：线程在 JVM 内部，帧稳定
- `_thread_blocked`：线程阻塞，帧不会改变

#### 关键代码段 2：帧验证（233-261 行）

```c
// forte.cpp:233-261
if (known_valid || fr->is_interpreted_frame_valid(thread)) {
  Method* method = fr->interpreter_frame_method();

  if (!Method::is_valid_method(method)) return false;

  *method_p = method;

  address bcp = fr->interpreter_frame_bcp();
  int bci = method->validate_bci_from_bcp(bcp);

  *bci_p = bci;
  return true;
}

return false;
```

**interpreter_frame_method 实现**：
```c
// frame.hpp
Method* interpreter_frame_method() const {
  return *(Method**)((address) _fp + interpreter_frame_method_offset);
}
```

**并发竞争**：
- GC 可能正在移动 Method
- 但 GC 活跃检查应该已排除此情况

---

### 4.4 is_decipherable_compiled_frame（149-202 行）

#### 函数签名

```c
// forte.cpp:149
static bool is_decipherable_compiled_frame(JavaThread* thread, frame* fr, CompiledMethod* nm)
```

**作用**：验证编译帧是否可遍历（是否有 PcDesc）

#### 关键代码段 1：调用点检查（152-162 行）

```c
// forte.cpp:152-162
if (thread->has_last_Java_frame() && thread->last_Java_pc() == fr->pc()) {
  PcDesc* pc_desc = nm->pc_desc_at(fr->pc());

  if (pc_desc != NULL &&
      pc_desc->scope_decode_offset() != DebugInformationRecorder::serialized_null) {
    return true;
  }
}
```

**场景**：
- 线程停在调用点（call into VM）
- `last_Java_pc` 指向调用指令之后

#### 关键代码段 2：通用检查（164-201 行）

```c
// forte.cpp:164-201
PcDesc* pc_desc = nm->pc_desc_near(fr->pc() + 1);

if (pc_desc == NULL ||
    pc_desc->scope_decode_offset() == DebugInformationRecorder::serialized_null) {
  return false;  // 无调试信息
}

// 调整帧的 PC 以匹配 PcDesc
fr->set_pc(pc_desc->real_pc(nm));
return true;
```

**pc_desc_near 实现**：
```c
// compiledMethod.cpp
PcDesc* CompiledMethod::pc_desc_near(address pc) {
  // 二分查找 PcDesc 数组
  // 返回第一个 pc >= search_pc 的 PcDesc
}
```

**为什么需要调整 PC**？
- 异步采样时，PC 可能在指令中间
- PcDesc 记录的是 ScopeDesc 的结束位置
- 调整到最近的 PcDesc

---

### 4.5 vframeStreamForte::forte_next（116-144 行）

#### 函数签名

```c
// forte.cpp:116
void vframeStreamForte::forte_next()
```

**作用**：迭代到下一个栈帧（异步安全版本）

#### 关键代码段 1：处理内联（118-121 行）

```c
// forte.cpp:118-121
if (_mode == compiled_mode &&
    vframeStreamCommon::fill_in_compiled_inlined_sender()) {
  return;
}
```

**内联处理**：
- 一个编译帧可能包含多个内联方法
- 不移动 _frame，只切换虚拟帧

#### 关键代码段 2：帧遍历循环（125-143 行）

```c
// forte.cpp:125-143
int loop_count = 0;
int loop_max = MaxJavaStackTraceDepth * 2;

do {
  loop_count++;

  if ((loop_max != 0 && loop_count > loop_max) || !_frame.safe_for_sender(_thread)) {
    _mode = at_end_mode;
    return;
  }

  _frame = _frame.sender(&_reg_map);

} while (!fill_from_frame());
```

**safe_for_sender 检查**：
1. SP 对齐检查
2. FP 合理性检查
3. CodeBlob 边界检查

**fill_from_frame 实现**：
```c
// vframeStreamCommon.cpp
bool vframeStreamCommon::fill_from_frame() {
  if (_frame.is_first_frame()) {
    _mode = at_end_mode;
    return true;
  }

  if (_frame.is_interpreted_frame()) {
    fill_from_interpreter_frame();
    return true;
  }

  if (_frame.is_compiled_frame()) {
    fill_from_compiled_frame();
    return true;
  }

  return false;  // 未识别的帧类型
}
```

---

## 五、六级分析

### 5.1 设计原理

#### 核心问题

**如何在不暂停线程的情况下获取调用栈？**

#### 朴素方案：暂停线程

```
优点：
- 可以安全地遍历栈
- 可以获取完整的调试信息

缺点：
- 改变程序行为（Heisenberg 效应）
- 暂停开销大（毫秒级）
- 无法真实反映热点
```

#### AsyncGetCallTrace 方案

```
核心思路：利用信号处理器的上下文，在目标线程的执行流中"借道"采样

关键设计：
1. 信号触发：Perf 事件 → SIGPROF → 信号处理器
2. 上下文保存：内核保存寄存器状态到 ucontext
3. 异步遍历：从 ucontext 重建栈帧，不暂停线程

代价：
1. 错误处理：用错误码而非异常（信号处理器不能抛异常）
2. 并发安全：不能加锁，只能检测并放弃
3. 中间状态：可能看到正在修改的栈帧
```

### 5.2 边界条件

#### 不可遍历的情况

| 情况 | 错误码 | 原因 | 解决方案 |
|------|--------|------|---------|
| 未启用 CLASS_LOAD | -1 | jmethodID 未分配 | AsyncProfiler Agent 启用 |
| GC 活跃 | -2 | 对象正在移动 | 等待 GC 完成 |
| Deopt 处理中 | -9 | 栈帧正在修改 | 等待 Deopt 完成 |
| 线程退出 | -8 | 线程状态无效 | 忽略此线程 |
| 无调试信息 | -4/-6 | 编译时未生成 PcDesc | 使用 -g 编译 |

#### 时间窗口分析

```
GC 周期：
- Serial GC：几十毫秒
- Parallel GC：几百毫秒
- G1 GC：几十毫秒（混合回收）
- ZGC/Shenandoah：几乎无 STW

Deopt 周期：
- 通常几微秒
- 极少数情况（多层去优化）可能几十微秒

失败率估算：
- G1 GC：采样失败率约 1-5%
- Parallel GC：采样失败率约 5-10%
```

### 5.3 并发安全

#### 信号处理器的约束

**禁止操作**：
1. **加锁**：可能导致死锁
2. **分配内存**：可能触发 GC
3. **调用非异步安全函数**：如 malloc、printf

**AsyncGetCallTrace 的并发措施**：

1. **无锁数据访问**：
   ```c
   // 所有状态检查都是无锁的
   if (thread->in_deopt_handler()) return;  // 无锁读取
   if (Universe::heap()->is_gc_active()) return;  // 无锁读取
   ```

2. **TOCTOU 容忍**：
   ```c
   // 检查后状态可能改变，但返回错误码是安全的
   if (!Method::is_valid_method(method)) {
     return ticks_GC_active;  // 放弃本次采样
   }
   ```

3. **标志位保护**：
   ```c
   thread->set_in_asgct(true);  // 阻止某些并发操作
   // ... 遍历栈 ...
   thread->set_in_asgct(false);
   ```

#### 竞争场景

**场景 1：GC 与 ASGCT 竞争**
```
时间线：
T1: ASGCT 检查 is_gc_active() → false
T2: GC 开始，设置 is_gc_active = true
T3: ASGCT 访问 Method* → 可能已失效
T4: ASGCT 返回 ticks_GC_active（保守处理）

结果：采样失败，但不会崩溃
```

**场景 2：Deopt 与 ASGCT 竞争**
```
时间线：
T1: Deopt 开始，设置 in_deopt_handler = true
T2: ASGCT 检查 in_deopt_handler → true
T3: ASGCT 返回 ticks_deopt

结果：采样失败，等待 Deopt 完成
```

### 5.4 JVM 交互

#### 与 GC 的交互

```c
// forte.cpp:549-552
if (Universe::heap()->is_gc_active()) {
  trace->num_frames = ticks_GC_active;
  return;
}
```

**GC 各阶段的 ASGCT 可用性**：

| GC 阶段 | is_gc_active | ASGCT 可用 | 原因 |
|---------|--------------|-----------|------|
| 初始标记 | true | ❌ | STW |
| 并发标记 | false | ✅ | 对象未移动 |
| 最终标记 | true | ❌ | STW |
| 筛选回收 | true | ❌ | 对象移动 |

#### 与编译器的交互

**编译帧的解码依赖**：
1. **PcDesc**：记录 PC → BCI 映射
2. **ScopeDesc**：记录内联信息
3. **DebugInformationRecorder**：编译时生成

**没有调试信息时**：
```c
// forte.cpp:172-195
if (pc_desc == NULL ||
    pc_desc->scope_decode_offset() == DebugInformationRecorder::serialized_null) {
  return false;  // 编译时未生成调试信息
}
```

**解决方案**：
- 使用 `-g` 编译选项（默认启用）
- C1 编译器可能生成较少调试信息

#### 与解释器的交互

**解释帧的结构**：
```
+-------------------+
| locals[n-1]       | ← 局部变量表
| locals[n-2]       |
| ...               |
| locals[0]         |
+-------------------+
| monitor[0]        | ← 监视器（如有）
+-------------------+
| bcp               | ← 字节码指针
| method            | ← Method*
+-------------------+
| sender_sp         | ← 调用者栈指针
+-------------------+
```

**并发问题**：
```c
// forte.cpp:222-231
// GC 可能正在修改解释帧
// known_valid 状态下，帧已稳定
bool known_valid = (state == _thread_in_native ||
                    state == _thread_in_vm ||
                    state == _thread_blocked);
```

### 5.5 性能影响

#### 单次采样开销

```
组件                       时间（纳秒）
------------------------------------------
信号处理开销               ~100
线程状态检查               ~50
GC/Deopt 检查              ~50
获取顶层帧                 ~200
find_initial_Java_frame    ~500-5000（取决于栈深度）
vframeStream 遍历          ~1000-10000（每帧 ~200ns）
填充 trace                 ~100
------------------------------------------
总计（深度 64）            ~15000-30000 ns = 15-30 μs
```

#### 影响因素

1. **栈深度**：线性增加遍历时间
2. **编译 vs 解释**：编译帧需要 PcDesc 查找（二分）
3. **内联**：编译帧可能包含多个虚拟帧
4. **CodeCache 大小**：影响 PcDesc 查找性能

#### 与暂停式采样的对比

| 方法 | 暂停时间 | 采样准确性 | 并发影响 |
|------|---------|-----------|---------|
| JMX getStackTrace | 1-10 ms | 高（STW） | 大（暂停线程）|
| JVMTI GetStackTrace | 0.5-5 ms | 高（STW） | 中（暂停线程）|
| AsyncGetCallTrace | 15-30 μs | 中（可能失败）| 小（不暂停）|

### 5.6 替代方案

#### 方案 1：JFR（Java Flight Recorder）

```
优点：
- JVM 内置，零开销（设计目标 <1%）
- 丰富的上下文信息（分配、锁、GC）

缺点：
- 需要 JVM 启动参数（-XX:StartFlightRecording）
- 商业特性（JDK 11+ 免费）

实现方式：
- 在 Safepoint 采样（AsyncGetCallTrace 在任意点）
- 使用缓冲区减少同步开销
```

#### 方案 2：JVMTI GetStackTrace

```
优点：
- 稳定可靠（无并发问题）
- 完整的调试信息

缺点：
- 需要暂停线程
- 性能开销大（毫秒级）

适用场景：
- 调试、问题排查
- 不适合生产环境持续监控
```

#### 方案 3：AsyncGetCallTrace（当前方案）

```
优点：
- 低开销（微秒级）
- 不暂停线程
- 真实反映运行时状态

缺点：
- 并发问题（GC、Deopt）
- 错误码处理复杂
- 需要 CLASS_LOAD 事件

适用场景：
- 生产环境持续性能监控
- CPU Profiler（AsyncProfiler）
```

---

## 六、GDB 验证脚本

### 6.1 验证主流程

#### 脚本：验证 AsyncGetCallTrace 调用链

```gdb
# 文件：/data/workspace/openjdk-cut-new/jvm-md/tmp-file/AsyncGetCallTrace/gdb_verify_main.txt
# 用途：验证 AsyncGetCallTrace 主流程
# 执行：gdb -x gdb_verify_main.txt

set pagination off
set print pretty on
set logging file /data/workspace/openjdk-cut-new/jvm-md/tmp-file/AsyncGetCallTrace/gdb_verify_main_output.txt
set logging overwrite on
set logging on

file /data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java

# ========== 断点 1：AsyncGetCallTrace 入口 ==========
break forte.cpp:523
commands 1
  silent
  printf "\n========== BP1: AsyncGetCallTrace 入口 ==========\n"
  printf "trace = %p\n", $rdi
  printf "depth = %d\n", $rsi
  printf "ucontext = %p\n", $rdx
  printf "trace->env_id = %p\n", ((ASGCT_CallTrace*)$rdi)->env_id
  printf "trace->num_frames = %d\n", ((ASGCT_CallTrace*)$rdi)->num_frames
  printf "trace->frames = %p\n", ((ASGCT_CallTrace*)$rdi)->frames
  bt 3
  continue
end

# ========== 断点 2：线程状态检查后 ==========
break forte.cpp:557
commands 2
  silent
  printf "\n========== BP2: 线程状态检查后 ==========\n"
  printf "thread = %p\n", $rax
  printf "thread->thread_state() = %d\n", ((JavaThread*)$rax)->thread_state()
  printf "in_deopt_handler = %d\n", ((JavaThread*)$rax)->in_deopt_handler()
  continue
end

# ========== 断点 3：GC 检查后 ==========
break forte.cpp:554
commands 3
  silent
  printf "\n========== BP3: GC 检查 ==========\n"
  p Universe::heap()->is_gc_active()
  continue
end

# ========== 断点 4：forte_fill_call_trace_given_top 调用 ==========
break forte.cpp:582
commands 4
  silent
  printf "\n========== BP4: forte_fill_call_trace_given_top 调用 ==========\n"
  printf "thread = %p\n", $rdi
  printf "trace = %p\n", $rsi
  printf "depth = %d\n", $rdx
  printf "top_frame.pc = %p\n", $rcx
  continue
end

# ========== 断点 5：find_initial_Java_frame 调用 ==========
break forte.cpp:432
commands 5
  silent
  printf "\n========== BP5: find_initial_Java_frame 调用 ==========\n"
  printf "top_frame = %p\n", $rsi
  continue
end

# ========== 运行 ==========
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main
```

### 6.2 验证帧解码

#### 脚本：验证解释帧和编译帧的解码

```gdb
# 文件：/data/workspace/openjdk-cut-new/jvm-md/tmp-file/AsyncGetCallTrace/gdb_verify_frame.txt
# 用途：验证帧解码过程
# 执行：gdb -x gdb_verify_frame.txt

set pagination off
set print pretty on
set logging file /data/workspace/openjdk-cut-new/jvm-md/tmp-file/AsyncGetCallTrace/gdb_verify_frame_output.txt
set logging overwrite on
set logging on

file /data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java

# ========== 断点 1：is_decipherable_interpreted_frame ==========
break forte.cpp:233
commands 1
  silent
  printf "\n========== BP1: is_decipherable_interpreted_frame ==========\n"
  printf "thread state = %d\n", $rdi
  printf "frame = %p\n", $rsi
  printf "is_interpreted_frame_valid = %d\n", ((frame*)$rsi)->is_interpreted_frame_valid((JavaThread*)$rdi)
  
  # 获取 Method*
  set $method = ((frame*)$rsi)->interpreter_frame_method()
  printf "Method* = %p\n", $method
  if $method != 0
    printf "Method name = %s\n", $method->name()->as_C_string()
  end
  
  continue
end

# ========== 断点 2：is_decipherable_compiled_frame ==========
break forte.cpp:155
commands 2
  silent
  printf "\n========== BP2: is_decipherable_compiled_frame ==========\n"
  printf "frame.pc = %p\n", ((frame*)$rsi)->pc()
  printf "CompiledMethod = %p\n", $rcx
  
  # 获取 PcDesc
  set $nm = (CompiledMethod*)$rcx
  set $pc = ((frame*)$rsi)->pc()
  set $pc_desc = $nm->pc_desc_at($pc)
  printf "PcDesc* = %p\n", $pc_desc
  
  if $pc_desc != 0
    printf "PcDesc.pc_offset = %d\n", $pc_desc->pc_offset()
    printf "PcDesc.scope_decode_offset = %d\n", $pc_desc->scope_decode_offset()
  end
  
  continue
end

# ========== 断点 3：vframeStreamForte::forte_next ==========
break forte.cpp:141
commands 3
  silent
  printf "\n========== BP3: vframeStreamForte::forte_next ==========\n"
  printf "loop_count = %d\n", $r12
  printf "safe_for_sender = %d\n", ((vframeStreamForte*)$rdi)->_frame.safe_for_sender(((vframeStreamForte*)$rdi)->_thread)
  continue
end

# ========== 运行 ==========
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main
```

### 6.3 统计错误码分布

#### 脚本：统计各种错误码的出现频率

```gdb
# 文件：/data/workspace/openjdk-cut-new/jvm-md/tmp-file/AsyncGetCallTrace/gdb_error_stats.txt
# 用途：统计 ASGCT 错误码分布
# 执行：gdb -x gdb_error_stats.txt

set pagination off
set print pretty on
set logging file /data/workspace/openjdk-cut-new/jvm-md/tmp-file/AsyncGetCallTrace/gdb_error_stats_output.txt
set logging overwrite on
set logging on

file /data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java

# 统计变量
set $total_calls = 0
set $success = 0
set $ticks_no_class_load = 0
set $ticks_GC_active = 0
set $ticks_deopt = 0
set $ticks_thread_exit = 0
set $ticks_unknown = 0
set $ticks_not_walkable = 0

# ========== 断点：AsyncGetCallTrace 返回前 ==========
break forte.cpp:614
commands 1
  silent
  set $total_calls = $total_calls + 1
  
  # 获取 trace->num_frames
  set $num_frames = ((ASGCT_CallTrace*)$rdi)->num_frames
  
  if $num_frames >= 0
    set $success = $success + 1
  else
    if $num_frames == -1
      set $ticks_no_class_load = $ticks_no_class_load + 1
    else
      if $num_frames == -2
        set $ticks_GC_active = $ticks_GC_active + 1
      else
        if $num_frames == -9
          set $ticks_deopt = $ticks_deopt + 1
        else
          if $num_frames == -8
            set $ticks_thread_exit = $ticks_thread_exit + 1
          else
            if $num_frames == -4 || $num_frames == -6
              set $ticks_not_walkable = $ticks_not_walkable + 1
            else
              set $ticks_unknown = $ticks_unknown + 1
            end
          end
        end
      end
    end
  end
  
  # 每 100 次输出一次统计
  if $total_calls % 100 == 0
    printf "\n========== 统计（第 %d 次）==========\n", $total_calls
    printf "成功: %d (%.1f%%)\n", $success, $success * 100.0 / $total_calls
    printf "ticks_no_class_load: %d\n", $ticks_no_class_load
    printf "ticks_GC_active: %d\n", $ticks_GC_active
    printf "ticks_deopt: %d\n", $ticks_deopt
    printf "ticks_thread_exit: %d\n", $ticks_thread_exit
    printf "ticks_not_walkable: %d\n", $ticks_not_walkable
    printf "ticks_unknown: %d\n", $ticks_unknown
  end
  
  continue
end

# ========== 运行 ==========
run -Xms8g -Xmx8g -XX:+UseG1GC -cp /data/workspace/demo/src com.wjcoder.Main
```

### 6.4 验证栈遍历

#### 脚本：跟踪 vframeStream 的栈遍历过程

```gdb
# 文件：/data/workspace/openjdk-cut-new/jvm-md/tmp-file/AsyncGetCallTrace/gdb_verify_stack_walk.txt
# 用途：跟踪栈遍历的每一步
# 执行：gdb -x gdb_verify_stack_walk.txt

set pagination off
set print pretty on
set logging file /data/workspace/openjdk-cut-new/jvm-md/tmp-file/AsyncGetCallTrace/gdb_verify_stack_walk_output.txt
set logging overwrite on
set logging on

file /data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java

set $frame_count = 0

# ========== 断点：每次迭代 ==========
break forte.cpp:445
commands 1
  silent
  set $frame_count = $frame_count + 1
  
  printf "\n========== 栈帧 #%d ==========\n", $frame_count
  
  # 获取 bci 和 method
  set $st = (vframeStreamForte*)$rdi
  set $bci = $st->bci()
  set $method = $st->method()
  
  printf "BCI = %d\n", $bci
  printf "Method* = %p\n", $method
  
  if $method != 0
    printf "Method name = %s\n", $method->name()->as_C_string()
    printf "Method signature = %s\n", $method->signature()->as_C_string()
    printf "is_native = %d\n", $method->is_native()
  end
  
  # 限制输出（只看前 20 帧）
  if $frame_count >= 20
    printf "\n========== 已达 20 帧，停止跟踪 ==========\n"
    detach
  end
  
  continue
end

# ========== 运行 ==========
run -Xms8g -Xmx8g -XX:+UseG1GC -cp /data/workspace/demo/src com.wjcoder.Main
```

---

## 七、面试级 Q&A

### Q1：AsyncGetCallTrace 为什么不能在 GC 活跃时调用？

**答**：

GC 活跃时会带来三方面的问题：

1. **对象移动**：
   - GC 会移动对象（包括 Method 对象）
   - AsyncGetCallTrace 遍历栈时会读取 `Method*`
   - 如果 GC 正在移动 Method，访问会失败

2. **栈帧修改**：
   - GC 需要"打标签"（marking）栈上的引用
   - 可能临时修改帧结构
   - AsyncGetCallTrace 可能看到中间状态

3. **无法加锁保护**：
   - AsyncGetCallTrace 在信号处理器中调用
   - 不能加锁（可能导致死锁）
   - 只能检测并放弃

**实际表现**：
- G1 GC：采样失败率约 1-5%
- Parallel GC：采样失败率约 5-10%
- 失败时返回 `ticks_GC_active` 错误码

---

### Q2：为什么需要启用 CLASS_LOAD 事件才能使用 AsyncGetCallTrace？

**答**：

AsyncGetCallTrace 需要返回 `jmethodID`，但 jmethodID 的分配机制与 CLASS_LOAD 事件紧密相关：

1. **jmethodID 的分配时机**：
   - 正常情况：首次调用 `JNI GetMethodID` 时分配
   - 分配需要加锁（JmethodIdTable 是全局表）

2. **信号处理器的限制**：
   - 信号处理器中**不能加锁**
   - 如果此时分配 jmethodID，会触发锁操作，可能导致死锁

3. **CLASS_LOAD 事件的解决方案**：
   - 启用 CLASS_LOAD 事件后，JVM 在类加载时**预先分配**所有 jmethodID
   - AsyncGetCallTrace 只需查找，无需分配
   - 查找是无锁的（原子读）

**AsyncProfiler 的做法**：
```c
// AsyncProfiler Agent 启用 CLASS_LOAD 事件
jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_CLASS_LOAD, NULL);
```

---

### Q3：AsyncGetCallTrace 如何处理内联方法？

**答**：

内联方法是 AsyncGetCallTrace 的难点之一，因为一个编译帧可能包含多个内联方法：

1. **编译帧的调试信息**：
   - 编译器生成 `ScopeDesc` 树结构
   - 每个 `ScopeDesc` 代表一个内联层次
   - 记录了 BCI、局部变量、内联信息

2. **vframeStream 的内联处理**：
   ```c
   // forte.cpp:118-121
   if (_mode == compiled_mode &&
       vframeStreamCommon::fill_in_compiled_inlined_sender()) {
     return;  // 不移动 _frame，只切换虚拟帧
   }
   ```

3. **fill_in_compiled_inlined_sender 实现**：
   ```cpp
   bool vframeStreamCommon::fill_in_compiled_inlined_sender() {
     // 从当前 ScopeDesc 获取父 ScopeDesc
     ScopeDesc* scope = _scope_desc->sender();
     
     if (scope != NULL) {
       _scope_desc = scope;
       _method = scope->method();
       _bci = scope->bci();
       return true;  // 成功切换到内联调用者
     }
     
     return false;  // 无内联，需移动到物理帧
   }
   ```

4. **实际例子**：
   ```
   方法 A 调用方法 B（内联）调用方法 C（内联）
   
   编译后只有一个物理帧，但 AsyncGetCallTrace 会返回 3 个虚拟帧：
   - frame[0]: Method C, BCI = ...
   - frame[1]: Method B, BCI = ...
   - frame[2]: Method A, BCI = ...
   ```

---

### Q4：AsyncGetCallTrace 与 JVMTI GetStackTrace 的区别？

**答**：

| 特性 | AsyncGetCallTrace | JVMTI GetStackTrace |
|------|-------------------|---------------------|
| **调用方式** | 信号处理器中调用 | JVM TI 接口调用 |
| **线程暂停** | 不暂停 | 暂停目标线程 |
| **性能开销** | 15-30 μs | 0.5-5 ms |
| **并发安全** | 无锁，可能失败 | 有锁，保证成功 |
| **错误处理** | 错误码 | 异常/返回值 |
| **适用场景** | 高频采样（CPU Profiler） | 低频采样（调试） |
| **实现复杂度** | 高（异步安全） | 中（暂停式） |

**核心区别**：
- **AsyncGetCallTrace**："尽力而为"（best-effort），可能失败，但不干扰程序执行
- **GetStackTrace**："保证成功"，但需要暂停线程，可能改变程序行为

---

### Q5：AsyncGetCallTrace 如何从 ucontext 重建栈帧？

**答**：

ucontext 是内核在信号触发时保存的寄存器状态，AsyncGetCallTrace 从中提取关键信息重建栈帧：

1. **ucontext 的结构**（Linux x86_64）：
   ```c
   typedef struct ucontext {
     unsigned long     uc_flags;
     struct ucontext  *uc_link;
     stack_t           uc_stack;
     mcontext_t        uc_mcontext;  // 寄存器状态
     sigset_t          uc_sigmask;
   } ucontext_t;
   
   typedef struct {
     gregset_t gregs;  // 通用寄存器数组
     fpregset_t fpregs;  // 浮点寄存器
   } mcontext_t;
   ```

2. **关键寄存器**：
   ```c
   // Linux x86_64 寄存器索引
   #define REG_RIP    16  // 指令指针（PC）
   #define REG_RSP     15  // 栈指针
   #define REG_RBP     6   // 帧指针
   ```

3. **pd_get_top_frame_for_signal_handler 实现**：
   ```cpp
   bool JavaThread::pd_get_top_frame_for_signal_handler(
       frame* fr, void* ucontext, bool isInJava) {
     
     ucontext_t* uc = (ucontext_t*) ucontext;
     
     // 从 ucontext 提取寄存器
     address pc = (address)uc->uc_mcontext.gregs[REG_RIP];
     address sp = (address)uc->uc_mcontext.gregs[REG_RSP];
     address fp = (address)uc->uc_mcontext.gregs[REG_RBP];
     
     // 构造 frame 对象
     *fr = frame(pc, sp, fp);
     
     // 验证帧的有效性
     return fr->safe_for_sender(this);
   }
   ```

4. **重建过程**：
   ```
   ucontext.uc_mcontext.gregs
          ↓
   提取 PC/SP/FP
          ↓
   构造 frame(pc, sp, fp)
          ↓
   验证 safe_for_sender
          ↓
   开始栈遍历
   ```

---

### Q6：AsyncGetCallTrace 的采样失败率是多少？如何优化？

**答**：

**采样失败率（G1 GC 环境）**：
- 总失败率：约 2-8%
- 主要原因：
  - `ticks_GC_active`：1-5%（GC 活跃）
  - `ticks_not_walkable`：0.1-1%（帧不可遍历）
  - `ticks_deopt`：<0.1%（去优化）

**优化方案**：

1. **减少 GC 频率**：
   ```bash
   # 增大堆内存
   -Xms16g -Xmx16g
   
   # 调整 G1 参数
   -XX:MaxGCPauseMillis=200
   -XX:G1HeapRegionSize=8m
   ```

2. **避免去优化**：
   ```bash
   # 减少热点代码的重新编译
   -XX:CompileThreshold=10000
   -XX:-TieredCompilation
   ```

3. **提高采样成功率**：
   ```bash
   # 确保调试信息完整
   -XX:+PrintCompilation
   
   # 使用 C2 编译器（更完整的调试信息）
   -XX:-TieredCompilation
   -XX:CompileThreshold=10000
   ```

4. **AsyncProfiler 的优化**：
   - 多次重试（遇到错误码时等待几微秒重试）
   - 聚合失败的采样（不丢弃）
   - 自适应采样频率（GC 时降低频率）

---

### Q7：如何调试 AsyncGetCallTrace 的问题？

**答**：

**常见问题**：

1. **总是返回 `ticks_no_class_load`**：
   ```bash
   # 检查是否启用了 CLASS_LOAD 事件
   -agentpath:/path/to/libasyncProfiler.so
   
   # 或手动启用
   -XX:+TraceClassLoading
   ```

2. **大量 `ticks_GC_active`**：
   ```bash
   # 查看 GC 日志
   -Xlog:gc*:file=gc.log
   
   # 调整 GC 参数
   -XX:MaxGCPauseMillis=500
   ```

3. **栈不完整**：
   ```bash
   # 检查编译模式
   -XX:+PrintCompilation
   
   # 确保使用 C2 编译器
   -XX:-TieredCompilation
   ```

**调试步骤**：

1. **使用 GDB 脚本跟踪**：
   ```bash
   cd /data/workspace/openjdk-cut-new
   gdb -x jvm-md/tmp-file/AsyncGetCallTrace/gdb_error_stats.txt
   ```

2. **查看 AsyncProfiler 日志**：
   ```bash
   asprof -d 30 -f profile.html --log-level debug /path/to/app
   ```

3. **检查 JVM 日志**：
   ```bash
   -Xlog:jvmti:file=jvmti.log
   ```

---

### Q8：AsyncGetCallTrace 在 AArch64 平台上的差异？

**答**：

AArch64（ARM64）与 x86_64 在 AsyncGetCallTrace 实现上有以下差异：

1. **ucontext 结构差异**：
   ```c
   // x86_64
   uc_mcontext.gregs[REG_RIP]
   uc_mcontext.gregs[REG_RSP]
   uc_mcontext.gregs[REG_RBP]
   
   // AArch64
   uc_mcontext.regs[30]  // LR (Link Register)
   uc_mcontext.sp        // SP
   uc_mcontext.regs[29]  // FP (x29)
   ```

2. **帧指针约定**：
   - x86_64：使用 `rbp` 作为帧指针
   - AArch64：使用 `x29` 作为帧指针，`x30` 存储返回地址

3. **PC 获取方式**：
   ```cpp
   // os_linux_aarch64.cpp
   address pc = (address)uc->uc_mcontext.pc;
   ```

4. **平台相关代码**：
   ```bash
   # 源码位置
   src/hotspot/os_cpu/linux_aarch64/os_linux_aarch64.cpp
   ```

**兼容性**：
- AsyncGetCallTrace 在 AArch64 上同样可用
- AsyncProfiler 已支持 ARM 平台
- 主要差异在 `pd_get_top_frame_for_signal_handler` 实现

---

## 八、总结

### 核心要点

1. **设计哲学**：AsyncGetCallTrace 是"尽力而为"的异步栈遍历，优先保证不干扰程序执行，而非保证成功。

2. **并发安全**：通过无锁读取 + 错误码返回 + TOCTOU 容忍来处理并发问题，不追求强一致性。

3. **性能开销**：单次采样 15-30 μs，比暂停式采样快 100-1000 倍，适合高频采样。

4. **失败处理**：GC、Deopt 等情况会返回错误码，上层需要统计和重试。

5. **调试依赖**：编译帧的遍历依赖 PcDesc 和 ScopeDesc，需要编译器生成调试信息。

### 学习建议

1. **动手验证**：使用提供的 GDB 脚本实际运行，观察调用链和错误码分布。

2. **对比学习**：对比 AsyncGetCallTrace 与 JVMTI GetStackTrace 的实现。

3. **深入编译器**：学习 PcDesc 和 ScopeDesc 的生成机制（在 `compile.cpp`）。

4. **性能测试**：在不同 GC 配置下测试采样失败率。

---

## 九、参考资料

- **源码位置**：`/data/workspace/openjdk-cut-new/src/hotspot/share/prims/forte.cpp`
- **相关文件**：
  - `vframe.cpp`：vframeStream 实现
  - `compiledMethod.cpp`：PcDesc 查找
  - `os_linux_x86.cpp`：平台相关帧获取
- **已有文档**：`jvm-md/AsyncProfiler/Lesson-01~12.md`

---

**下一步**：基于 AsyncGetCallTrace 的理解，深入 AsyncProfiler 的信号处理和采样循环实现。
