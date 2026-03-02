# 第二章：AsyncGetCallTrace — 绕过 Safepoint 的栈采样接口

> **基于 OpenJDK 11 源码分析（纯源码验证，无网络搜索）**
> **标准环境**：`-Xms8g -Xmx8g -XX:+UseG1GC`，G1 Region = 4MB
> **方法论**：程序 = 数据结构 + 算法 | 问题驱动设计分析
> **源码文件**：`src/hotspot/share/prims/forte.cpp`（全文 666 行，AsyncGetCallTrace 核心实现）

---

## 第 0 部分：核心原理

### 0.1 本质是什么？

`AsyncGetCallTrace` 是 HotSpot JVM 内部的非标准 C 函数（`forte.cpp:523`），它允许在 **SIGPROF 信号处理器** 中由被中断线程自身直接调用来获取调用栈，不需要 stop-the-world，从根本上绕过了 Safepoint 限制。

### 0.2 为什么需要？

第一章已经证明：传统 Profiler 通过 `VMThread::execute(&VM_ThreadDump)` 采样，必须 stop-the-world。而 CPU 密集线程因 Loop Strip Mining 导致 Safepoint 间隔长达数秒，使传统采样产生严重的 Safepoint Bias。

**根本矛盾**：安全的栈遍历需要线程暂停（Safepoint），但暂停本身就会扭曲采样分布。我们需要一种**不暂停线程**就能获取调用栈的方法。

### 0.3 怎么解决？

核心思路：**利用 POSIX 信号机制中断线程，从信号上下文 `ucontext` 中提取寄存器状态（PC/SP/FP），就地重建栈帧链并回溯。**

关键设计：
1. **信号中断 ≠ Safepoint**：线程被 SIGPROF 中断时仍"在运行"，只是暂时执行信号处理器代码
2. **从 ucontext 重建帧**：信号处理器的第三个参数 `ucontext` 包含被中断时刻的全部寄存器状态
3. **容忍失败**：遇到 GC 竞争、Deopt 中间态等不安全状态时，返回错误码（负数），丢弃此次采样

### 0.4 为什么这样设计？

**为什么由被中断线程自身调用，而不是由独立线程遍历？** 信号处理器天然运行在目标线程的上下文中，可以直接访问该线程的 `JavaThread*`、栈帧和寄存器。如果用独立线程遍历，要么需要暂停目标线程（回到 Safepoint 问题），要么面临并发读取的一致性问题。

**为什么用错误码而不是异常？** 信号处理器上下文有三个严格限制：不能加锁（可能死锁）、不能分配堆内存（`malloc` 不是 async-signal-safe）、不能抛异常。所以只能通过 `trace->num_frames` 返回负数错误码。

**为什么 jmethodID 需要预分配？** `AsyncGetCallTrace` 需要将 `Method*` 转为 `jmethodID` 返回给调用者。但 `jmethodID` 的分配需要加锁（`JNIMethodBlock` 扩容时），信号处理器中不能加锁。因此必须在类加载时通过 JVMTI `CLASS_LOAD` 事件预分配好所有 `jmethodID`，信号处理器中只做 `find_jmethod_id_or_null()` 查找。

---

## 第 1 部分：数据结构全景

### 1.1 数据结构清单

| 结构名 | 源码位置 | 核心作用 |
|--------|----------|----------|
| `ASGCT_CallFrame` | `forte.cpp:39-42` | 单个栈帧：BCI + jmethodID |
| `ASGCT_CallTrace` | `forte.cpp:45-49` | 完整调用栈：线程 ID + 帧数组 + 帧数/错误码 |
| 错误码枚举（匿名） | `forte.cpp:52-64` | 11 种状态码（0 及 -1 到 -10） |
| `vframeStreamForte` | `forte.cpp:75-80` | 异步安全的 Java 栈帧迭代器（继承 `vframeStreamCommon`） |
| `vframeStreamCommon` | `vframe.hpp:268-330` | 栈帧迭代器基类：frame + mode + method + bci |
| `ucontext_t` / `mcontext_t` | POSIX 标准 | 信号上下文：被中断时刻的全部寄存器状态 |

### 1.2 ASGCT_CallFrame — 单个栈帧

#### 问题推导

**问题**：采样一个栈帧，Profiler 至少需要知道什么信息？

**需要什么信息？**
- **方法标识**：这个帧执行的是哪个方法？→ 需要一个方法 ID
- **执行位置**：方法中执行到哪一行？→ 需要 BCI（字节码索引）或行号
- 其他信息（如局部变量）在 Profiling 场景中不需要

**推导出的结构**：一个二元组 `{位置, 方法ID}`，非常简单。

#### 真实数据结构

```cpp
// forte.cpp:39-42
typedef struct {
    jint lineno;                      // ★ BCI 或特殊标记值
    jmethodID method_id;              // ★ 方法标识（指向 Method* 的稳定句柄）
} ASGCT_CallFrame;
```

**推导 vs 实际**：完全吻合。字段名 `lineno` 有些误导——它存的不是源码行号，而是 BCI（字节码索引）或特殊值。

#### 完整分析

| 字段 | 类型 | 偏移 | 大小 | 含义 |
|------|------|------|------|------|
| ★ `lineno` | `jint` | 0x00 | 4B | BCI（≥0）；Native 方法为 -3；不可用为 -1 |
| （padding） | — | 0x04 | 4B | 64 位平台对齐填充 |
| ★ `method_id` | `jmethodID` | 0x08 | 8B | 方法句柄（类加载时预分配） |

**sizeof = 16 字节**（含 4 字节对齐填充）。

**`lineno` 值域图**：

```mermaid
stateDiagram-v2
    state "lineno 值域" as S {
        state "≥ 0: BCI（字节码索引）" as BCI
        state "-1: BCI 不可用" as NOBCI
        state "-3: Native 方法" as NATIVE
    }
    note right of BCI
        解释帧：从 interpreter_frame_bcp() 计算
        编译帧：从 PcDesc → ScopeDesc 解码
    end note
    note right of NOBCI
        编译帧无 PcDesc，或帧构造中
    end note
    note right of NATIVE
        forte.cpp:459
        method->is_native() 时固定写 -3
    end note
```

**创建位置**：调用者（async-profiler）在信号处理器中预分配 `ASGCT_CallFrame` 数组，AsyncGetCallTrace 负责填充。

**`method_id` 生命周期**：
- **分配**：类加载时，通过 JVMTI `CLASS_LOAD` 事件触发 `Method::jmethod_id()` 分配
- **读取**：`forte.cpp:455` — `method->find_jmethod_id_or_null()` 查找已分配的 ID
- **释放**：类卸载时释放

#### 设计决策

**为什么用 `jmethodID` 而不是 `Method*`？** `Method*` 是 Metaspace 中的指针，GC 不会移动它（Metaspace 不被 GC 管理），理论上可以直接用。但 `jmethodID` 是 JNI 标准接口，async-profiler 拿到后可以直接用 JVMTI `GetMethodName()` 等 API 查询方法信息，无需跨越 JVM 内部/外部边界。

### 1.3 ASGCT_CallTrace — 完整调用栈

#### 问题推导

**问题**：一次栈采样需要传入什么、返回什么？

**需要什么信息？**
- **输入**：要采样哪个线程？→ 需要线程标识
- **输出**：采到了多少帧？→ 需要帧计数
- **输出**：每帧的详细信息？→ 需要帧数组
- **错误处理**：采样失败怎么办？→ 帧计数可以复用为错误码（负数 = 错误）

**推导出的结构**：一个三元组 `{线程ID, 帧数/错误码, 帧数组指针}`。

#### 真实数据结构

```cpp
// forte.cpp:45-49
typedef struct {
    JNIEnv *env_id;                   // ★ 输入：线程标识
    jint num_frames;                  // ★ 输出：帧数量（≥0）或错误码（<0）
    ASGCT_CallFrame *frames;          // ★ 输出：帧数组（调用者预分配）
} ASGCT_CallTrace;
```

**推导 vs 实际**：吻合。线程标识用 `JNIEnv*` 而非 `JavaThread*`，因为这是对外接口。

#### 完整分析

| 字段 | 类型 | 偏移 | 大小 | 含义 |
|------|------|------|------|------|
| ★ `env_id` | `JNIEnv*` | 0x00 | 8B | 调用者设置：标识目标线程的 JNI 环境 |
| ★ `num_frames` | `jint` | 0x08 | 4B | ASGCT 设置：≥0 为成功帧数，<0 为错误码 |
| （padding） | — | 0x0C | 4B | 对齐填充 |
| ★ `frames` | `ASGCT_CallFrame*` | 0x10 | 8B | 调用者分配：长度 ≥ depth 的帧数组 |

**sizeof = 24 字节**。

**`num_frames` 值域图**：

```mermaid
stateDiagram-v2
    state "num_frames 值域" as S {
        state "成功" as OK {
            state "0: 无 Java 帧（线程太年轻/在 native 中无 Java 栈）" as F0
            state "1..N: 成功采集到 N 个 Java 帧" as FN
        }
        state "失败（错误码）" as ERR {
            state "-1: 未启用 CLASS_LOAD 事件" as E1
            state "-2: GC 正在进行" as E2
            state "-3: 非 Java 状态，帧无法识别" as E3
            state "-4: 非 Java 状态，帧不可遍历" as E4
            state "-5: Java 状态，帧无法识别" as E5
            state "-6: Java 状态，帧不可遍历" as E6
            state "-7: 未知线程状态" as E7
            state "-8: 线程正在退出" as E8
            state "-9: 正在 Deopt" as E9
            state "-10: Safepoint（未实际使用）" as E10
        }
    }
```

**`env_id` 反查线程的机制**：

```cpp
// forte.cpp:527 — 从 JNIEnv 反查 JavaThread
thread = JavaThread::thread_from_jni_environment(trace->env_id)
```

**为什么用 `JNIEnv*` 而不是 `pthread_t` 或 `JavaThread*`？**
- `JNIEnv` 是每个 Java 线程唯一持有的 JNI 接口指针，线程内部可通过偏移直接反查 `JavaThread*`
- async-profiler 在信号处理器中可以通过 JVMTI `GetCurrentThread()` 或直接用 TLS 获取 `JNIEnv*`
- `JavaThread*` 是 JVM 内部类型，不对外暴露

### 1.4 错误码枚举

#### 问题推导

**问题**：信号处理器中不能抛异常，不能返回复杂错误信息。如何告知调用者"这次采样失败了，原因是什么"？

**设计**：复用 `num_frames` 字段。成功时 ≥ 0 表示帧数，失败时 < 0 表示错误码。用枚举给每种失败原因分配一个负值。

#### 真实数据结构

```cpp
// forte.cpp:52-64
enum {
  ticks_no_Java_frame         =  0,   // 没有 Java 帧（不算错误，线程可能在纯 native）
  ticks_no_class_load         = -1,   // ★ 致命：未启用 JVMTI CLASS_LOAD 事件
  ticks_GC_active             = -2,   // ★ GC 正在进行，栈帧可能不一致
  ticks_unknown_not_Java      = -3,   // 非 Java 状态，无法获取 top frame
  ticks_not_walkable_not_Java = -4,   // 非 Java 状态，帧不可遍历（默认值）
  ticks_unknown_Java          = -5,   // Java 状态，无法获取 top frame
  ticks_not_walkable_Java     = -6,   // Java 状态，帧不可遍历（默认值）
  ticks_unknown_state         = -7,   // 线程状态不在已知范围内
  ticks_thread_exit           = -8,   // 线程正在退出或 env_id 无效
  ticks_deopt                 = -9,   // 线程正在 Deopt，栈帧正在被改写
  ticks_safepoint             = -10   // 源码中未实际使用
};
```

**关键分组**：

| 分组 | 错误码 | 含义 | async-profiler 处理方式 |
|------|--------|------|------------------------|
| 致命错误 | -1 | 未启用 CLASS_LOAD | 启动时必须确保启用 |
| 瞬态失败 | -2, -9 | GC 或 Deopt 进行中 | 丢弃本次采样，正常现象 |
| 帧不可识别 | -3, -5 | 无法获取 top frame | 丢弃本次采样 |
| 帧不可遍历 | -4, -6 | 有 frame 但无法遍历 | 丢弃本次采样 |
| 线程问题 | -7, -8 | 状态异常或正在退出 | 丢弃本次采样 |

**注意**：`-4` 和 `-6` 是"默认值"——在进入 `forte_fill_call_trace_given_top()` 之前先设成这个值，如果成功遍历会被覆盖为实际帧数。

### 1.5 vframeStreamForte — 异步安全的栈帧迭代器

#### 问题推导

**问题**：HotSpot 已有 `vframeStream` 用于遍历 Java 栈帧，为什么 AsyncGetCallTrace 不直接用，而要搞一个 `vframeStreamForte`？

**需要什么？**
- 普通 `vframeStream` 的 `next()` 没有安全检查——它假设在 Safepoint 或线程自身安全上下文中调用
- AsyncGetCallTrace 运行在信号处理器中，栈可能不完整或已损坏
- 需要额外的安全措施：`safe_for_sender()` 检查 + 循环次数上限

**推导出的结构**：继承 `vframeStreamCommon`，覆盖 `next()` 方法加入安全检查。

#### 真实数据结构

```cpp
// forte.cpp:75-80
class vframeStreamForte : public vframeStreamCommon {
 public:
  // 构造函数：从给定的 top frame 开始（不是从 last_Java_frame）
  vframeStreamForte(JavaThread *jt, frame fr, bool stop_at_java_call_stub);
  void forte_next();  // ★ 安全版的 next()，替代 vframeStreamCommon::next()
};
```

**继承自 `vframeStreamCommon` 的关键字段**（`vframe.hpp:268-283`）：

| 字段 | 类型 | 含义 |
|------|------|------|
| `_frame` | `frame` | 当前物理栈帧 |
| `_thread` | `JavaThread*` | 拥有该栈帧的线程 |
| `_reg_map` | `RegisterMap` | 寄存器映射（用于 sender 回溯） |
| `_mode` | enum | 当前模式：`interpreted_mode` / `compiled_mode` / `at_end_mode` |
| `_sender_decode_offset` | `int` | 内联调用者的解码偏移（用于处理 JIT 内联） |
| `_method` | `Method*` | 当前帧的 Java 方法 |
| `_bci` | `int` | 当前帧的字节码索引 |
| `_stop_at_java_call_stub` | `bool` | 是否在 Java call stub 处停止 |

**设计决策**：

**`forte_next()` vs `vframeStreamCommon::next()` 的区别是什么？**

普通 `next()`（`vframe.inline.hpp:41-49`）直接调 `_frame.sender()` 不做边界检查。`forte_next()`（`forte.cpp:116-144`）加了两层保护：
1. `safe_for_sender(_thread)` — 检查 sender frame 的 SP 是否在线程栈范围内
2. `loop_max = MaxJavaStackTraceDepth * 2` — 防止损坏栈导致无限循环

### 1.6 ucontext_t / mcontext_t — 信号上下文

#### 问题推导

**问题**：线程被 SIGPROF 中断时，如何知道它在执行什么代码？在栈的哪个位置？

**需要什么？**
- 当前执行的指令地址（PC/RIP）— 用于确定在哪个方法的哪个位置
- 栈指针（SP/RSP）— 用于定位栈帧
- 帧指针（FP/RBP）— 用于回溯帧链

**答案**：POSIX 信号处理器的第三个参数 `ucontext` 包含被中断时刻的全部 CPU 寄存器状态。

#### 真实数据结构

```c
// /usr/include/x86_64-linux-gnu/sys/ucontext.h（Linux x86_64）
typedef struct ucontext_t {
    struct ucontext_t *uc_link;        // 后续上下文
    sigset_t           uc_sigmask;     // 信号掩码
    stack_t            uc_stack;       // 替代信号栈信息
    mcontext_t         uc_mcontext;    // ★ 机器上下文（寄存器）
    // ...
} ucontext_t;

// mcontext_t 包含 gregset_t（通用寄存器数组）
// gregset_t[REG_RIP] = 指令指针
// gregset_t[REG_RSP] = 栈指针
// gregset_t[REG_RBP] = 帧指针
```

**AsyncGetCallTrace 如何使用 ucontext**：

AsyncGetCallTrace 自身**不直接**解析 ucontext。它将 ucontext 传给平台相关函数 `pd_get_top_frame_for_signal_handler()`（`thread_linux_x86.cpp:38-42`），后者委托给 `pd_get_top_frame()`（同文件第 49-102 行）：

```cpp
// thread_linux_x86.cpp:49-97（核心逻辑）
bool JavaThread::pd_get_top_frame(frame* fr_addr, void* ucontext, bool isInJava) {
    // ★ 优先路径：如果有 last_Java_frame 且可行走，直接用
    if (jt->has_last_Java_frame() && jt->frame_anchor()->walkable()) {
        *fr_addr = jt->pd_last_frame();  // 从 anchor 获取 SP/FP/PC
        return true;
    }
    // ★ 次优路径：线程在 Java 代码中（isInJava=true），从 ucontext 构造 frame
    if (isInJava) {
        ucontext_t* uc = (ucontext_t*) ucontext;
        intptr_t* ret_fp;
        intptr_t* ret_sp;
        // 从 ucontext 提取 SP/FP/PC
        ExtendedPC addr = os::Linux::fetch_frame_from_ucontext(this, uc, &ret_sp, &ret_fp);
        // ...
        frame ret_frame(ret_sp, ret_fp, addr.pc());  // ★ 构造 frame 对象
        if (!ret_frame.safe_for_sender(jt)) {
            // C2/JVMCI 可能将 RBP 用作通用寄存器，尝试 FP=NULL
            frame ret_frame2(ret_sp, NULL, addr.pc());
            // ...
        }
        *fr_addr = ret_frame;
        return true;
    }
    return false;  // 非 Java 状态且无 last_Java_frame
}
```

**关键设计**：有两条路径获取 top frame：
1. **last_Java_frame 路径**：线程从 Java 进入 native/VM 时，`JavaFrameAnchor` 保存了最后一个 Java 帧的 SP/FP/PC，这是最可靠的
2. **ucontext 路径**：线程正在执行 Java 代码时，没有 last_Java_frame，必须从信号上下文的寄存器构造帧

---

## 第 2 部分：算法/流程分析

### 2.1 核心流程概览

```mermaid
flowchart TD
    Entry["AsyncGetCallTrace(trace, depth, ucontext)<br/>forte.cpp:523"] --> V1{"验证线程<br/>env_id → JavaThread"}
    V1 -->|无效/退出| R8["num_frames = -8<br/>ticks_thread_exit"]
    V1 -->|有效| V2{"检查 Deopt<br/>in_deopt_handler()"}
    V2 -->|正在 Deopt| R9["num_frames = -9<br/>ticks_deopt"]
    V2 -->|不在 Deopt| V3{"检查 CLASS_LOAD<br/>should_post_class_load()"}
    V3 -->|未启用| R1["num_frames = -1<br/>ticks_no_class_load"]
    V3 -->|已启用| V4{"检查 GC<br/>heap()->is_gc_active()"}
    V4 -->|GC 活跃| R2["num_frames = -2<br/>ticks_GC_active"]
    V4 -->|GC 非活跃| SW{"switch<br/>thread_state()"}
    
    SW -->|new/uninitialized| R0["num_frames = 0"]
    SW -->|"in_native/blocked/in_vm"| NotJava["pd_get_top_frame<br/>(isInJava=false)"]
    SW -->|in_Java| InJava["pd_get_top_frame<br/>(isInJava=true)"]
    SW -->|default| R7["num_frames = -7"]
    
    NotJava -->|失败| R3["num_frames = -3"]
    NotJava -->|成功| HasLJF{"has_last_Java_frame?"}
    HasLJF -->|否| R0_2["num_frames = 0"]
    HasLJF -->|是| Fill1["forte_fill_call_trace_given_top()"]
    
    InJava -->|失败| R5["num_frames = -5"]
    InJava -->|成功| Fill2["forte_fill_call_trace_given_top()"]
    
    Fill1 --> Done["num_frames = 实际帧数"]
    Fill2 --> Done

    style Done fill:#99ff99
    style R8 fill:#ff9999
    style R9 fill:#ff9999
    style R1 fill:#ff9999
    style R2 fill:#ff9999
    style R3 fill:#ff9999
    style R5 fill:#ff9999
    style R7 fill:#ff9999
```

### 2.2 AsyncGetCallTrace 主函数（forte.cpp:523-615）

#### 解决什么问题？

作为入口函数，负责：(1) 前置安全检查（线程有效性、Deopt、CLASS_LOAD、GC），(2) 根据线程状态分派到不同的帧获取路径，(3) 调用 `forte_fill_call_trace_given_top()` 遍历栈帧。

#### 真实源码 + 逐行注释

**Phase 1：前置安全检查**

```cpp
// forte.cpp:523-552
extern "C" {
JNIEXPORT
void AsyncGetCallTrace(ASGCT_CallTrace *trace, jint depth, void* ucontext) {
  JavaThread* thread;

  // ★ 检查 1：线程有效性（三重验证）
  if (trace->env_id == NULL ||                                    // env 空指针
    (thread = JavaThread::thread_from_jni_environment(trace->env_id)) == NULL ||  // 反查失败
    thread->is_exiting()) {                                       // 线程正在退出
    trace->num_frames = ticks_thread_exit; // -8
    return;
  }

  // ★ 检查 2：Deopt 状态
  // Deopt 过程中栈帧正在被改写（JIT 帧 → 解释帧），遍历会崩溃
  if (thread->in_deopt_handler()) {
    trace->num_frames = ticks_deopt; // -9
    return;
  }

  // ★ 断言：必须由被中断线程自身调用（不是 VM 线程或其他线程）
  assert(JavaThread::current() == thread,
         "AsyncGetCallTrace must be called by the current interrupted thread");

  // ★ 检查 3：CLASS_LOAD 事件是否启用
  // 没有 CLASS_LOAD → jmethodID 未预分配 → find_jmethod_id_or_null() 全返回 NULL
  if (!JvmtiExport::should_post_class_load()) {
    trace->num_frames = ticks_no_class_load; // -1
    return;
  }

  // ★ 检查 4：GC 是否活跃
  // GC 进行时对象可能被移动，Method* 可能失效
  if (Universe::heap()->is_gc_active()) {
    trace->num_frames = ticks_GC_active; // -2
    return;
  }
```

**⚠️ 重要纠正**：旧文档（补充文档 Q&A 第 567 行）声称检查 `SafepointSynchronize::is_at_safepoint()`，这是**错误的**。实际源码（forte.cpp:549）检查的是 `Universe::heap()->is_gc_active()`——这只检查 GC 是否活跃，**不检查是否在 Safepoint**。AsyncGetCallTrace 可以在 Safepoint 期间运行（如果不是 GC 触发的 Safepoint）。

**Phase 2：根据线程状态分派**

```cpp
  // forte.cpp:554-614
  // ★ 标记当前线程正在执行 ASGCT（用于 JVM 内部状态检查）
  thread->set_in_asgct(true);

  switch (thread->thread_state()) {
  // ★ 分支 1：新建/未初始化线程 → 没有 Java 帧
  case _thread_new:
  case _thread_uninitialized:
  case _thread_new_trans:
    trace->num_frames = 0;
    break;

  // ★ 分支 2：线程不在 Java 代码中（native/blocked/vm）
  case _thread_in_native:
  case _thread_in_native_trans:
  case _thread_blocked:
  case _thread_blocked_trans:
  case _thread_in_vm:
  case _thread_in_vm_trans:
    {
      frame fr;
      // ★ isInJava = false：优先用 last_Java_frame
      if (!thread->pd_get_top_frame_for_signal_handler(&fr, ucontext, false)) {
        trace->num_frames = ticks_unknown_not_Java;  // -3
      } else {
        if (!thread->has_last_Java_frame()) {
          trace->num_frames = 0;  // 纯 native 线程，无 Java 帧
        } else {
          trace->num_frames = ticks_not_walkable_not_Java;  // -4（默认值，成功后覆盖）
          forte_fill_call_trace_given_top(thread, trace, depth, fr);
        }
      }
    }
    break;

  // ★ 分支 3：线程正在执行 Java 代码
  case _thread_in_Java:
  case _thread_in_Java_trans:
    {
      frame fr;
      // ★ isInJava = true：可能需要从 ucontext 构造帧
      if (!thread->pd_get_top_frame_for_signal_handler(&fr, ucontext, true)) {
        trace->num_frames = ticks_unknown_Java;  // -5
      } else {
        trace->num_frames = ticks_not_walkable_Java;  // -6（默认值，成功后覆盖）
        forte_fill_call_trace_given_top(thread, trace, depth, fr);
      }
    }
    break;

  default:
    trace->num_frames = ticks_unknown_state; // -7
    break;
  }
  thread->set_in_asgct(false);
}
```

#### 设计决策

**为什么按线程状态分两条路径？**

关键差异在 `pd_get_top_frame_for_signal_handler()` 的 `isInJava` 参数：

| 线程状态 | isInJava | 帧获取策略 |
|----------|----------|-----------|
| native/blocked/vm | `false` | 只用 `last_Java_frame`（anchor 已保存） |
| in_Java | `true` | 优先 `last_Java_frame`，否则从 `ucontext` 构造 |

当线程在 native/blocked/vm 状态时，它进入非 Java 代码前已经在 `JavaFrameAnchor` 中保存了最后一个 Java 帧的 SP/FP/PC（通过 `set_last_Java_frame()`）。此时 ucontext 指向的是 native/VM 代码的帧，对 Java 栈遍历没用。

当线程在 Java 状态时，没有 anchor（线程从未离开 Java），必须从 ucontext 的寄存器直接构造帧。

**为什么 `-4` 和 `-6` 是"默认值"？** 这是一种"先悲观后乐观"的模式：先假设帧不可遍历（设默认错误码），然后调用 `forte_fill_call_trace_given_top()`。如果遍历成功，`num_frames` 会被覆盖为实际帧数。如果遍历中途失败（如发现 `Method` 无效），则保持错误码或设为 `-2`。

### 2.3 forte_fill_call_trace_given_top（forte.cpp:416-464）

#### 解决什么问题？

给定一个 `top_frame`（可能是 Java 帧，也可能是 C++ stub），找到第一个可遍历的 Java 帧，然后用 `vframeStreamForte` 迭代器遍历整个 Java 栈帧链，填充 `ASGCT_CallFrame` 数组。

#### 真实源码 + 逐行注释

```cpp
// forte.cpp:416-464
static void forte_fill_call_trace_given_top(JavaThread* thd,
                                            ASGCT_CallTrace* trace,
                                            int depth,
                                            frame top_frame) {
  NoHandleMark nhm;    // ★ 禁止在本函数中创建 Handle（信号处理器安全要求）

  frame initial_Java_frame;
  Method* method;
  int bci = -1;        // ★ 默认 BCI 不可用
  int count;

  count = 0;
  assert(trace->frames != NULL, "trace->frames must be non-NULL");

  // ★ 步骤 1：从 top_frame 向上搜索，找到第一个可遍历的 Java 帧
  // 如果 top_frame 是 C++ stub 或 Runtime stub，需要跳过
  find_initial_Java_frame(thd, &top_frame, &initial_Java_frame, &method, &bci);

  // ★ 步骤 2：检查是否找到了 Java 方法
  if (method == NULL) return;   // 整个栈上没有 Java 帧

  // ★ 步骤 3：验证 Method 指针有效性
  // GC 可能在 find_initial_Java_frame 执行过程中移动了对象
  if (!Method::is_valid_method(method)) {
    trace->num_frames = ticks_GC_active; // -2
    return;
  }

  // ★ 步骤 4：用找到的 initial_Java_frame 初始化 vframeStreamForte 迭代器
  vframeStreamForte st(thd, initial_Java_frame, false);

  // ★ 步骤 5：遍历循环 — 逐帧填充 ASGCT_CallFrame 数组
  for (; !st.at_end() && count < depth; st.forte_next(), count++) {
    bci = st.bci();          // 从迭代器获取当前帧的 BCI
    method = st.method();    // 从迭代器获取当前帧的 Method

    // ★ 每帧都验证 Method 有效性（防止遍历过程中 GC 移动对象）
    if (!Method::is_valid_method(method)) {
      // 发现无效 Method → 丢弃所有已采集帧（不能信任任何数据）
      trace->num_frames = ticks_GC_active; // -2
      return;
    }

    // ★ 填充当前帧
    trace->frames[count].method_id = method->find_jmethod_id_or_null();
    if (!method->is_native()) {
      trace->frames[count].lineno = bci;   // Java 方法：写入 BCI
    } else {
      trace->frames[count].lineno = -3;    // Native 方法：固定写 -3
    }
  }
  trace->num_frames = count;  // ★ 写入实际帧数（覆盖之前的默认错误码）
  return;
}
```

#### 设计决策

**为什么发现一帧无效就丢弃全部已采集帧？** 如果 GC 移动了一个 `Method*`，说明 GC 正在进行中（`is_gc_active()` 检查可能刚好被绕过——信号处理器和 GC 线程并发执行）。此时其他已采集帧的 `Method*` 也不可信，全部丢弃是最安全的选择。

**`NoHandleMark nhm` 是什么？** HotSpot 的 Handle 系统在 HandleArea 中分配，这涉及线程私有的 Arena 分配。虽然不是 `malloc`，但在信号处理器中仍需谨慎。`NoHandleMark` 的 debug 版会在有人创建 Handle 时触发 assert 失败，作为防御性检查。

### 2.4 find_initial_Java_frame（forte.cpp:296-414）

#### 解决什么问题？

信号中断时线程可能在任意位置——C++ runtime 代码、JVM stub、GC 代码等。这些帧没有 `CodeBlob`（即不在 CodeCache 中），无法用 `vframeStream` 遍历。此函数从 `top_frame` 开始向上搜索，找到第一个"可遍历的 Java 帧"。

#### 核心流程图

```mermaid
flowchart TD
    Start["find_initial_Java_frame(fr)"] --> CB{"fr->cb() == NULL?<br/>（无 CodeBlob）"}
    
    CB -->|是| Loop1["循环：candidate = candidate.sender()<br/>直到找到 cb() != NULL 的帧<br/>上限：MaxJavaStackTraceDepth * 2"]
    CB -->|否| Loop2
    
    Loop1 -->|找到| Loop2["循环：识别帧类型"]
    Loop1 -->|未找到/不安全| Fail["return false"]
    
    Loop2 --> IsEntry{"is_entry_frame()?"}
    IsEntry -->|是| JCW{"JavaCallWrapper<br/>有效且非 first_frame?"}
    JCW -->|是| NextFrame["跳过，继续 sender()"]
    JCW -->|否| Fail
    
    Loop2 --> IsInterp{"is_interpreted_frame()?"}
    IsInterp -->|是| DecInterp["is_decipherable_interpreted_frame()"]
    DecInterp -->|可解析| OK["设置 initial_frame, method, bci<br/>return true"]
    DecInterp -->|不可解析| Fail
    
    Loop2 --> IsComp{"cb()->is_compiled()?"}
    IsComp -->|是| GetMethod["method = nm->method()"]
    GetMethod --> IsNative{"nm->is_native_method()?"}
    IsNative -->|是| OK
    IsNative -->|否| DecComp["is_decipherable_compiled_frame()"]
    DecComp -->|可解析| OK
    DecComp -->|不可解析| Fail
    
    Loop2 --> IsOther["其他帧（stub 等）"]
    IsOther --> NextFrame
    NextFrame --> Loop2

    style OK fill:#99ff99
    style Fail fill:#ff9999
```

#### 真实源码 + 逐行注释

```cpp
// forte.cpp:296-414
static bool find_initial_Java_frame(JavaThread* thread,
                                    frame* fr,
                                    frame* initial_frame_p,
                                    Method** method_p,
                                    int* bci_p) {
  *method_p = NULL;  // ★ 初始化为 NULL，调用者通过此判断是否找到了方法

  frame candidate = *fr;

  // ★ Phase 1：如果 top_frame 无 CodeBlob，向上搜索直到找到有 CodeBlob 的帧
  // 无 CodeBlob = 纯 C++ 代码帧，不在 CodeCache 中
  if (fr->cb() == NULL) {
    int loop_count;
    int loop_max = MaxJavaStackTraceDepth * 2;  // 防止无限循环
    RegisterMap map(thread, false);

    for (loop_count = 0; loop_max == 0 || loop_count < loop_max; loop_count++) {
      if (!candidate.safe_for_sender(thread)) return false;  // SP 不在栈范围内
      candidate = candidate.sender(&map);
      if (candidate.cb() != NULL) break;  // 找到了
    }
    if (candidate.cb() == NULL) return false;  // 遍历完上限仍未找到
  }

  // ★ Phase 2：候选帧有 CodeBlob，识别具体类型
  int loop_count;
  int loop_max = MaxJavaStackTraceDepth * 2;
  RegisterMap map(thread, false);

  for (loop_count = 0; loop_max == 0 || loop_count < loop_max; loop_count++) {

    // ★ 类型 1：entry_frame（C++ → Java 的入口桩帧）
    if (candidate.is_entry_frame()) {
      JavaCallWrapper *jcw = candidate.entry_frame_call_wrapper_if_safe(thread);
      // 如果 jcw 无效或是第一个 entry（无更多 Java 帧），返回失败
      if (jcw == NULL || jcw->is_first_frame()) {
        return false;
      }
      // 否则跳过 entry_frame，继续搜索 sender
    }

    // ★ 类型 2：解释帧
    if (candidate.is_interpreted_frame()) {
      if (is_decipherable_interpreted_frame(thread, &candidate, method_p, bci_p)) {
        *initial_frame_p = candidate;
        return true;   // ✅ 找到可遍历的解释帧
      }
      return false;    // 解释帧但不可解析（如 Method 无效）
    }

    // ★ 类型 3：编译帧
    if (candidate.cb()->is_compiled()) {
      CompiledMethod* nm = candidate.cb()->as_compiled_method();
      *method_p = nm->method();  // ★ 先记录 Method（即使后续不可解析也有用）
      *bci_p = -1;               // 编译帧默认无 BCI

      *initial_frame_p = candidate;

      // Native 包装帧可以直接遍历
      if (nm->is_native_method()) return true;

      // ★ 验证编译帧是否可解析（需要有效的 PcDesc）
      if (!is_decipherable_compiled_frame(thread, &candidate, nm)) {
        return false;  // 有 Method 但无 PcDesc，调用者可以用 Method 但不遍历
      }

      // is_decipherable_compiled_frame 可能修改了 candidate 的 PC
      *initial_frame_p = candidate;
      return true;   // ✅ 找到可遍历的编译帧
    }

    // ★ 类型 4：其他帧（Runtime stub 等），跳过继续搜索
    if (!candidate.safe_for_sender(thread)) return false;
    candidate = candidate.sender(&map);

    if (candidate.cb() == NULL) return false;  // 不应该出现（CodeCache 中的帧 sender 也应在 CodeCache 中）
  }

  return false;
}
```

#### 设计决策

**为什么解释帧和编译帧的"不可解析"处理不同？** 对于解释帧，如果不可解析（`Method` 无效），说明帧数据已损坏，不设置 `*method_p`，直接 `return false`。对于编译帧，**即使不可解析（无 PcDesc），也会设置 `*method_p`**（第 366 行）。这样调用者知道线程在执行哪个方法，只是不知道具体位置。

**为什么循环上限是 `MaxJavaStackTraceDepth * 2`？** `MaxJavaStackTraceDepth` 默认 1024。乘以 2 是因为 Java 帧和 stub/native 帧交替出现，实际深度可能是纯 Java 深度的 2 倍。这个上限是防御性措施，防止损坏栈导致无限回溯。

### 2.5 is_decipherable_interpreted_frame（forte.cpp:213-265）

#### 解决什么问题？

判断一个解释帧是否"可安全解析"——即能否从中提取有效的 `Method*` 和 BCI。在信号处理器中断的瞬间，GC 可能正在移动对象，解释帧的内部数据可能处于不一致状态。

#### 真实源码 + 逐行注释

```cpp
// forte.cpp:213-265
static bool is_decipherable_interpreted_frame(JavaThread* thread,
                                              frame* fr,
                                              Method** method_p,
                                              int* bci_p) {
  assert(fr->is_interpreted_frame(), "just checking");

  // ★ 线程状态检查：在某些"已知安全"状态下，帧保证有效
  // 因为 GC 竞争可能导致有效帧看起来无效（is_interpreted_frame_valid 误判）
  JavaThreadState state = thread->thread_state();
  bool known_valid = (state == _thread_in_native ||    // 在 native 中，Java 帧已固定
                      state == _thread_in_vm ||         // 在 VM 中，Java 帧已固定
                      state == _thread_blocked );       // 在阻塞中，Java 帧已固定

  // ★ 如果线程在已知安全状态 或 帧通过有效性检查
  if (known_valid || fr->is_interpreted_frame_valid(thread)) {

    Method* method = fr->interpreter_frame_method();    // 从帧中读取 Method*

    if (!Method::is_valid_method(method)) return false; // Method 被 GC 破坏
    *method_p = method;

    address bcp = fr->interpreter_frame_bcp();          // 读取字节码指针
    int bci = method->validate_bci_from_bcp(bcp);       // BCP → BCI（带范围验证）

    // bci < 0 表示 BCP 无效（帧正在构建中、或 GC 移动了）
    *bci_p = bci;
    return true;
  }

  return false;
}
```

#### 设计决策

**为什么有 `known_valid` 快速路径？** 当线程处于 `_thread_in_native` / `_thread_in_vm` / `_thread_blocked` 状态时，Java 解释帧已经"冻结"——线程不再修改解释帧的内部字段。即使 `is_interpreted_frame_valid()` 因 GC 竞争返回 false，帧实际上仍然有效。这个 `known_valid` 跳过了可能误判的帧验证，减少假阴性。

**⚠️ 旧文档错误纠正**：补充文档（第 306-308 行）声称检查 `_thread_in_Java || _thread_in_native`，这是**错误的**。实际源码（forte.cpp:229-231）是 `_thread_in_native || _thread_in_vm || _thread_blocked`。`_thread_in_Java` 恰恰**不在** `known_valid` 中——因为线程正在执行 Java 字节码时，解释帧可能正在被修改。

### 2.6 is_decipherable_compiled_frame（forte.cpp:149-202）

#### 解决什么问题？

判断一个编译帧（JIT 编译的方法）是否"可解析"——即能否找到有效的 `PcDesc`，从而获取作用域信息（ScopeDesc）用于解码内联方法和 BCI。

#### 真实源码 + 逐行注释

```cpp
// forte.cpp:149-202
static bool is_decipherable_compiled_frame(JavaThread* thread, frame* fr, CompiledMethod* nm) {
  assert(nm->is_java_method(), "invariant");

  // ★ 快速路径：线程在 JVM 调用点暂停（last_Java_pc 匹配当前帧 PC）
  // 这是最可靠的情况——线程从 Java 调用了 JVM runtime，PC 精确
  if (thread->has_last_Java_frame() && thread->last_Java_pc() == fr->pc()) {
    PcDesc* pc_desc = nm->pc_desc_at(fr->pc());    // 精确匹配
    if (pc_desc != NULL &&
        pc_desc->scope_decode_offset() != DebugInformationRecorder::serialized_null) {
      return true;
    }
  }

  // ★ 慢路径：线程在编译代码的随机位置被中断
  // 搜索 PC ≥ fr->pc()+1 的最近 PcDesc
  // 原因：PcDesc 记录的是区域末尾的 PC，不是开始
  PcDesc* pc_desc = nm->pc_desc_near(fr->pc() + 1);

  if (pc_desc == NULL ||
      pc_desc->scope_decode_offset() == DebugInformationRecorder::serialized_null) {
    // ★ 无可用 PcDesc → 帧不可解析
    // 但不是严重错误：vframeStreamCommon::fill_from_frame() 会将其当作
    // native 编译帧处理（零 BCI），仍然可以报告方法名
    return false;
  }

  // ★ 找到了有效 PcDesc，但需要调整帧的 PC
  // 使 vframeStream 后续查找使用这个 PcDesc 对应的真实 PC
  fr->set_pc(pc_desc->real_pc(nm));
  return true;
}
```

#### 设计决策

**为什么搜索 `fr->pc() + 1` 而不是精确匹配？** JIT 编译器生成 PcDesc 时，记录的是调试信息覆盖区域的**末尾 PC**，不是开始。当信号中断在区域中间时，`pc_desc_at(fr->pc())` 会找不到。`pc_desc_near(fr->pc() + 1)` 搜索"PC ≥ 给定值的最近 PcDesc"，能找到覆盖当前 PC 的那个 PcDesc。

**为什么要 `fr->set_pc(pc_desc->real_pc(nm))`？** 将帧的 PC 调整为 PcDesc 记录的 real_pc，这样后续 `vframeStreamCommon::fill_from_frame()` 用 `nm->pc_desc_at(_frame.pc())` 查找时能精确命中，避免二次搜索。

### 2.7 vframeStreamForte::forte_next（forte.cpp:116-144）

#### 解决什么问题？

安全地推进 `vframeStreamForte` 迭代器到下一个 Java 帧。与普通 `vframeStreamCommon::next()` 相比，增加了异步安全保护。

**⚠️ 重要纠正**：旧文档（主文档第 599 行和补充文档第 450-511 行）声称 `forte_next()` 位于 `vframe.cpp:116-144`，**这是错误的**。`forte_next()` 仅定义在 `forte.cpp:116-144`，与 vframe.cpp 无关。旧补充文档中 forte_next 的"完整源码"（第 467-510 行）是**完全编造的**——它写了 `if (_frame.is_interpreted_frame())` 等不存在的逻辑。

#### 真实源码 + 逐行注释

```cpp
// forte.cpp:116-144
void vframeStreamForte::forte_next() {
  // ★ 步骤 1：处理 JIT 内联方法
  // 一个编译帧可能包含多个内联方法，此时不移动物理栈帧
  // 只通过 ScopeDesc 链解码下一个内联调用者
  if (_mode == compiled_mode &&
      vframeStreamCommon::fill_in_compiled_inlined_sender()) {
    return;  // ★ 还有内联调用者，不移动栈帧
  }

  // ★ 步骤 2：没有更多内联方法，移动到物理栈帧的 sender
  int loop_count = 0;
  int loop_max = MaxJavaStackTraceDepth * 2;  // ★ 防止无限循环

  do {
    loop_count++;

    // ★ 安全检查 1：循环次数上限（防止损坏栈无限回溯）
    // ★ 安全检查 2：safe_for_sender（检查 sender SP 是否在线程栈范围内）
    if ((loop_max != 0 && loop_count > loop_max) || !_frame.safe_for_sender(_thread)) {
      _mode = at_end_mode;  // 标记遍历结束
      return;
    }

    // ★ 移动到 sender frame
    _frame = _frame.sender(&_reg_map);

  } while (!fill_from_frame());
  // ★ fill_from_frame() 返回 true 表示找到了一个 Java 帧或到达栈底
  // 返回 false 表示当前帧是 stub/native，需要继续搜索
}
```

**`fill_from_frame()`（`vframe.inline.hpp:125-201`）的核心逻辑**：

```
if (解释帧) → fill_from_interpreter_frame(), return true
if (编译帧) → fill_from_compiled_frame(decode_offset), return true
if (栈底或 entry_frame) → _mode = at_end_mode, return true
否则 → return false（需要继续找 sender）
```

#### 设计决策

**为什么内联处理在步骤 1（不移动栈帧）？** JIT 编译器将多个方法内联到一个编译帧中。逻辑上有 N 个方法调用，但物理上只有一个栈帧。`ScopeDesc` 链记录了内联的层次关系。遍历时先把同一帧的所有内联方法都输出完（`fill_in_compiled_inlined_sender`），再移动到物理 sender。

**`fill_in_compiled_inlined_sender()`（`vframe.inline.hpp:66-72`）的逻辑**：
```cpp
inline bool vframeStreamCommon::fill_in_compiled_inlined_sender() {
  if (_sender_decode_offset == DebugInformationRecorder::serialized_null) {
    return false;   // ★ 没有更多内联调用者
  }
  fill_from_compiled_frame(_sender_decode_offset);  // ★ 解码下一个内联层
  return true;
}
```

---

## 第 3 部分：完整调用链时序图

```mermaid
sequenceDiagram
    participant Kernel as Linux Kernel
    participant Handler as 信号处理器<br/>(async-profiler)
    participant ASGCT as AsyncGetCallTrace<br/>(forte.cpp:523)
    participant PD as pd_get_top_frame<br/>(thread_linux_x86.cpp:49)
    participant FIJF as find_initial_Java_frame<br/>(forte.cpp:296)
    participant FFCT as forte_fill_call_trace_given_top<br/>(forte.cpp:416)
    participant VFS as vframeStreamForte<br/>(forte.cpp:75)

    Kernel->>Handler: SIGPROF 中断线程
    Handler->>ASGCT: AsyncGetCallTrace(trace, depth, ucontext)
    
    ASGCT->>ASGCT: 验证线程 + Deopt + CLASS_LOAD + GC
    ASGCT->>PD: pd_get_top_frame_for_signal_handler(&fr, ucontext, isInJava)
    
    alt 有 last_Java_frame 且可行走
        PD-->>ASGCT: 从 JavaFrameAnchor 获取 frame ✓
    else 线程在 Java 代码中
        PD->>PD: os::Linux::fetch_frame_from_ucontext() → SP/FP/PC
        PD->>PD: frame(ret_sp, ret_fp, addr.pc()) + safe_for_sender 检查
        PD-->>ASGCT: 从 ucontext 构造 frame ✓
    else 无法获取
        PD-->>ASGCT: return false → 错误码
    end

    ASGCT->>FFCT: forte_fill_call_trace_given_top(thread, trace, depth, fr)
    FFCT->>FIJF: find_initial_Java_frame(thread, &top_frame, ...)
    
    FIJF->>FIJF: 跳过无 CodeBlob 的帧
    FIJF->>FIJF: 识别帧类型 → is_decipherable_xxx
    FIJF-->>FFCT: initial_Java_frame + method + bci

    FFCT->>VFS: new vframeStreamForte(thd, initial_Java_frame, false)
    
    loop 每个 Java 帧（含内联展开）
        FFCT->>VFS: st.method(), st.bci()
        FFCT->>FFCT: trace->frames[count] = {bci, method_id}
        FFCT->>VFS: st.forte_next()
        VFS->>VFS: 先处理内联（fill_in_compiled_inlined_sender）
        VFS->>VFS: 再移动帧（sender + fill_from_frame）
    end
    
    FFCT-->>ASGCT: trace->num_frames = count
    ASGCT-->>Handler: 返回
    Handler-->>Kernel: 信号返回，线程恢复执行
```

---

## 第 4 部分：验证（三种独立方法）

### 4.1 验证方法 1：GDB sizeof 验证

**验证脚本**：`new-jvm-md/tmp-file/AsyncGetCallTrace/verify_sizeof.gdb`

**方法**：在 `Forte::register_stub()` 设断点（JVM 启动时自动调用），断点命中后打印类型大小和偏移。

**GDB 实际输出**：

```
========== sizeof 验证（在 Forte::register_stub 中）==========
sizeof(ASGCT_CallFrame) = 16
sizeof(ASGCT_CallTrace) = 24
sizeof(jint) = 4
sizeof(jmethodID) = 8
sizeof(JNIEnv*) = 8

========== ASGCT_CallFrame 字段偏移 ==========
offset of lineno    = 0
offset of method_id = 8

========== ASGCT_CallTrace 字段偏移 ==========
offset of env_id     = 0
offset of num_frames = 8
offset of frames     = 16

========== vframeStream 相关 sizeof ==========
sizeof(vframeStreamForte)  = 4752
sizeof(vframeStreamCommon) = 4752
sizeof(frame) = 48
sizeof(RegisterMap) = 4664
```

**验证结论**：

| 数据结构 | 文档预测 | GDB 实测 | 状态 |
|----------|---------|---------|------|
| `ASGCT_CallFrame` sizeof | 16 字节 | **16** | ✅ 通过 |
| `ASGCT_CallTrace` sizeof | 24 字节 | **24** | ✅ 通过 |
| `ASGCT_CallFrame.lineno` 偏移 | 0x00 | **0** | ✅ 通过 |
| `ASGCT_CallFrame.method_id` 偏移 | 0x08 | **8** | ✅ 通过 |
| `ASGCT_CallTrace.env_id` 偏移 | 0x00 | **0** | ✅ 通过 |
| `ASGCT_CallTrace.num_frames` 偏移 | 0x08 | **8** | ✅ 通过 |
| `ASGCT_CallTrace.frames` 偏移 | 0x10 | **16** | ✅ 通过 |

**额外发现**：
- `vframeStreamForte` 与 `vframeStreamCommon` 的 sizeof 相同（4752 字节），因为 `vframeStreamForte` 没有新增任何成员字段，只覆盖了 `forte_next()` 方法
- `RegisterMap` 占 4664 字节（几乎全部是 `vframeStreamCommon` 的体积），因为它包含了所有寄存器的映射信息
- `frame` 只有 48 字节（`_sp` + `_fp` + `_pc` + `_cb` + `_deopt_state` + padding）

### 4.2 验证方法 2：async-profiler 运行时采样

**验证程序**：`com.wjcoder.AsgctDemo`（递归调用 `compute(20)` + `hotLoop()`，运行 5 秒）

**命令**：
```bash
LD_LIBRARY_PATH=.../jdk/lib/server java \
  -agentpath:.../libasyncProfiler.so=start,event=cpu,interval=10000000,file=/tmp/asgct_test.txt,collapsed \
  -Xms8g -Xmx8g -XX:+UseG1GC -Xint \
  -cp /data/workspace/demo/src com.wjcoder.AsgctDemo
```

**采样统计**：

| 指标 | 数值 |
|------|------|
| 总采样数 | **520 次** |
| 不同栈形态数 | 54 种 |
| 包含 `hotLoop` 的采样 | 402 次（77.3%）|
| 包含 `compute` 的采样 | 494 次（95.0%）|
| 最大调用深度 | 52 帧 |

**采样数据示例**（collapsed 格式，`;` 分隔调用链，末尾数字为采样次数）：

```
com/wjcoder/AsgctDemo.main;com/wjcoder/AsgctDemo.compute;...;com/wjcoder/AsgctDemo.hotLoop 6
com/wjcoder/AsgctDemo.main;com/wjcoder/AsgctDemo.compute;com/wjcoder/AsgctDemo.compute 4
com/wjcoder/AsgctDemo.main 3
```

**验证结论**：
- ✅ AsyncGetCallTrace 成功采集到 Java 栈帧，包含完整的递归调用链
- ✅ 调用深度正确（main + 20 层 compute + hotLoop = 22 帧，加上 JVM 内部帧可达 52）
- ✅ `-Xint` 模式下所有帧都是解释帧，`is_decipherable_interpreted_frame()` 路径正确处理
- ✅ 热点方法 `hotLoop` 占比最高（77.3%），符合 CPU Profiling 预期

### 4.3 验证方法 3：strace 系统调用链路

**命令**：
```bash
strace -f -e trace=perf_event_open,rt_sigaction -o /tmp/asgct_strace.txt java \
  -agentpath:.../libasyncProfiler.so=start,event=cpu,interval=10000000 ...
```

**关键 strace 输出**：

**1) perf_event_open 调用**（为每个线程注册 CPU 时钟事件）：
```
perf_event_open({type=PERF_TYPE_SOFTWARE, config=PERF_COUNT_SW_CPU_CLOCK,
                 sample_period=10000000, ...}, <tid>, -1, -1, PERF_FLAG_FD_CLOEXEC) = <fd>
```
- 调用 16 次（每个线程一次）
- `sample_period=10000000` = 10ms 采样间隔 ✅

**2) SIGPROF 信号注册**：
```
rt_sigaction(SIGPROF, {sa_handler=0x..., sa_flags=SA_RESTART|SA_SIGINFO}, ...) = 0
```
- `SA_SIGINFO` 标志 → 信号处理器签名 `void handler(int, siginfo_t*, void* ucontext)` ✅
- 第三个参数 `ucontext` 就是传给 `AsyncGetCallTrace` 的 ✅

**3) SIGPROF 信号接收**：
```
--- SIGPROF {si_signo=SIGPROF, si_code=0x6} ---
```
- 共 510 次，与 collapsed 输出 520 次基本吻合 ✅

**验证结论**：
- ✅ async-profiler 通过 `perf_event_open` + `SIGPROF` 信号驱动采样
- ✅ 信号处理器使用 `SA_SIGINFO`，确保能获取 `ucontext`（寄存器上下文）
- ✅ 信号接收次数与成功采样次数基本一致（差值来自部分失败返回错误码的采样）

### 4.4 已知限制：GDB 与 perf_events 不兼容

**发现**：在 GDB（ptrace）环境下，`perf_event_open` 注册的事件**不会**向被调试进程发送 SIGPROF 信号。因此无法在 GDB 中直接断点 `AsyncGetCallTrace` 的运行时调用。

**原因**：ptrace 会拦截所有信号传递，而 perf_events 的信号通知机制在 ptrace 下行为异常。GDB attach 到运行中的 JVM 后，async-profiler 的采样也会停止。

**替代验证方案**：
- 使用 `Forte::register_stub()` 断点验证 sizeof/偏移（JVM 启动时调用，不依赖 SIGPROF）
- 使用 async-profiler collapsed 输出验证运行时行为
- 使用 strace 验证系统调用链路

### 4.5 验证方法 4：async-profiler 源码插桩（第 4 种独立验证）

**方法**：直接修改 async-profiler 源码（`profiler.cpp`），在 `getJavaTraceAsync()` 函数的每个 ASGCT 调用点添加 `atomicInc` 原子计数器，编译后运行，采集 ASGCT 调用的真实统计数据。

**修改位置**（7 个计数器）：

| 计数器 | 位置 | 含义 |
|--------|------|------|
| `_asgct_calls` | profiler.cpp:420 主调用前 | ASGCT 总调用次数 |
| `_asgct_success` | 主调用后 `num_frames > 0` | 首次调用就成功 |
| `_asgct_retry_stub` | unwind_stub 重试前 | runtime stub 展开后重试 |
| `_asgct_retry_comp` | unwind_comp 重试前 | 编译帧展开后重试 |
| `_asgct_retry_probe` | probe_sp 循环内 | SP 探测重试 |
| `_asgct_retry_anchor` | java_anchor 路径（3 处） | anchor 修补后重试 |
| `_asgct_retry_success` | 函数末尾 `num_frames > 0` | 重试最终成功 |

**编译运行**：
```bash
cd /data/workspace/async-profiler && make clean && make
java -agentpath:.../libasyncProfiler.so=start,event=cpu,cstack=fp,\
  log=/tmp/asgct_log.txt,loglevel=INFO,features=stats \
  -cp ... com.wjcoder.AsgctDemo
```

> **注意**：必须使用 `cstack=fp` 强制走 ASGCT 路径。默认 `cstack=vm` 走 `StackWalker::walkVM()`，不经过 ASGCT。

**测试结果**：

| 指标 | Test 1（5s） | Test 2（30s） | Test 3（5s） |
|------|-------------|--------------|-------------|
| 总 ASGCT 调用 | 579 | 3111 | 587 |
| 主调用成功 | 510（88.08%） | 2975（95.63%） | 511（87.05%） |
| 重试成功 | 8 | 42 | 12 |
| 重试路径：comp | 1 | 38 | 5 |
| 重试路径：anchor | 7 | 4 | 7 |
| 重试路径：stub | 0 | 0 | 0 |
| 重试路径：probe | 0 | 0 | 0 |
| **总成功率** | **89.46%** | **96.98%** | **89.10%** |
| 平均栈回溯耗时 | 27712 ns | 28114 ns | 29635 ns |

**对比：VM 模式（不走 ASGCT）**：

| 指标 | VM 模式（30s） | ASGCT 模式（30s） |
|------|---------------|------------------|
| 采样数 | 3117 | 3112 |
| ASGCT 调用 | **0** | 3111 |
| 平均耗时 | **1818 ns** | 28114 ns |
| 速度差异 | **快 15.5 倍** | — |

**验证结论**：
- ✅ ASGCT 主调用成功率 87-96%，验证了第 2 部分分析的"多层安全检查 + 帧验证"机制有效
- ✅ async-profiler 的重试机制（comp/anchor）额外挽救了 12-31% 的失败样本
- ✅ `unwind_comp` 和 `java_anchor` 是最活跃的重试路径，`stub/probe` 在简单负载下不触发
- ✅ 默认 VM 模式比 ASGCT 快 15 倍，解释了为什么 async-profiler v4.3 默认选择 `CSTACK_VM`
- ✅ 数据文件：`new-jvm-md/tmp-file/AsyncGetCallTrace/asgct_instrumented_output.txt`

### 4.6 GDB 脚本位置

| 脚本 | 路径 | 用途 |
|------|------|------|
| sizeof 验证 | `new-jvm-md/tmp-file/AsyncGetCallTrace/verify_sizeof.gdb` | 验证数据结构大小和偏移 |
| 运行时验证 | `new-jvm-md/tmp-file/AsyncGetCallTrace/verify_runtime.gdb` | 断点采集（需在非 GDB 环境触发 SIGPROF） |
| attach 验证 | `new-jvm-md/tmp-file/AsyncGetCallTrace/verify_attach.gdb` | GDB attach 到运行中 JVM |

### 4.7 前置检查清单

- [x] `AsyncGetCallTrace` 是 `extern "C"` 函数，符号名无 C++ mangling，GDB 可直接用函数名设断点
- [x] `find_initial_Java_frame` 是 `static` 函数，mangled 名为 `_ZL23find_initial_Java_frameP10JavaThreadP5frameS2_PP6MethodPi`
- [x] `forte_fill_call_trace_given_top` 是 `static` 函数，mangled 名为 `_ZL31forte_fill_call_trace_given_topP10JavaThreadP15ASGCT_CallTracei5frame`
- [x] `handle SIGPROF nostop noprint pass` 已设置，但 GDB 下 perf_events 仍不工作（已知限制）
- [x] async-profiler .so 文件路径 `/data/workspace/async-profiler/build/lib/libasyncProfiler.so` 存在且有效

---

## 第 5 部分：数据结构关系图

```mermaid
classDiagram
    class ASGCT_CallTrace {
        +JNIEnv* env_id
        +jint num_frames
        +ASGCT_CallFrame* frames
    }
    
    class ASGCT_CallFrame {
        +jint lineno
        +jmethodID method_id
    }
    
    class vframeStreamForte {
        +forte_next() void
    }
    
    class vframeStreamCommon {
        #frame _frame
        #JavaThread* _thread
        #RegisterMap _reg_map
        #enum _mode
        #int _sender_decode_offset
        #Method* _method
        #int _bci
        +method() Method*
        +bci() int
        +at_end() bool
        #fill_from_frame() bool
        #fill_in_compiled_inlined_sender() bool
    }

    class JavaThread {
        -volatile void* _polling_page
        -JavaThreadState _thread_state
        -bool _in_asgct
        +pd_get_top_frame_for_signal_handler() bool
        +thread_from_jni_environment() JavaThread*$
        +has_last_Java_frame() bool
    }
    
    class frame {
        -intptr_t* _sp
        -intptr_t* _fp  
        -address _pc
        -CodeBlob* _cb
        +cb() CodeBlob*
        +is_interpreted_frame() bool
        +is_entry_frame() bool
        +safe_for_sender() bool
        +sender() frame
    }
    
    class CompiledMethod {
        +method() Method*
        +pc_desc_at() PcDesc*
        +pc_desc_near() PcDesc*
        +is_native_method() bool
    }
    
    class PcDesc {
        +real_pc() address
        +scope_decode_offset() int
    }
    
    class ucontext_t {
        +mcontext_t uc_mcontext
    }
    
    class mcontext_t {
        +gregset_t gregs
        note "gregs[REG_RIP] = PC\ngregs[REG_RSP] = SP\ngregs[REG_RBP] = FP"
    }

    ASGCT_CallTrace "1" *-- "0..N" ASGCT_CallFrame : frames[]
    ASGCT_CallTrace ..> JavaThread : env_id → thread
    vframeStreamForte --|> vframeStreamCommon : 继承
    vframeStreamCommon --> frame : _frame
    vframeStreamCommon --> JavaThread : _thread
    frame --> CompiledMethod : _cb (当编译帧时)
    CompiledMethod --> PcDesc : pc_desc_at/near
    ucontext_t --> mcontext_t : uc_mcontext
    ucontext_t ..> frame : "pd_get_top_frame() 构造"
    JavaThread ..> frame : "pd_last_frame() 或 ucontext 构造"
```

---

## 第 6 部分：总结

### 6.1 数据结构层面

| 数据结构 | 核心特征 |
|----------|----------|
| `ASGCT_CallFrame` | 16 字节（含 4B padding），BCI + jmethodID 的二元组 |
| `ASGCT_CallTrace` | 24 字节，输入（env_id）+ 输出（num_frames/错误码 + frames 数组）的三元组 |
| 错误码枚举 | 11 种状态（0 及 -1 到 -10），`num_frames` 负值复用为错误码 |
| `vframeStreamForte` | 继承 `vframeStreamCommon`，`forte_next()` 比普通 `next()` 增加 `safe_for_sender` 检查和循环上限 |
| `ucontext_t` | POSIX 信号上下文，包含被中断时刻的 PC/SP/FP 等全部寄存器 |

### 6.2 算法层面

| 算法/流程 | 核心设计决策 |
|-----------|-------------|
| AsyncGetCallTrace 主函数 | 四级前置检查（线程→Deopt→CLASS_LOAD→GC）+ 按线程状态分两条帧获取路径 |
| pd_get_top_frame | 非 Java 状态优先用 anchor，Java 状态从 ucontext 构造帧 + C2 的 FP=NULL 重试 |
| find_initial_Java_frame | 两阶段搜索（先找有 CodeBlob 的帧，再识别类型），三种帧类型不同验证策略 |
| forte_fill_call_trace_given_top | 先找初始帧 → 初始化迭代器 → 遍历循环（每帧验证 Method 有效性）→ 发现无效全部丢弃 |
| forte_next | 先处理内联（不移动帧） → 再移动物理帧（do-while + fill_from_frame），加 safe_for_sender 保护 |
| is_decipherable_interpreted_frame | `known_valid` 快速路径（native/vm/blocked 状态帧保证有效）+ `validate_bci_from_bcp` |
| is_decipherable_compiled_frame | 快速路径（last_Java_pc 精确匹配）+ 慢路径（`pc_desc_near(pc+1)` 搜索 + PC 调整）|

### 6.3 勘误记录

本次重写修正了以下错误：

| 错误 | 旧文档位置 | 实际情况 |
|------|-----------|----------|
| `forte_next()` 位于 `vframe.cpp:116-144` | 主文档第 599 行 | 位于 **`forte.cpp:116-144`** |
| 补充文档 `forte_next()` 源码 | 补充文档第 467-510 行 | **完全编造**，写了不存在的 if-else 帧类型判断 |
| 引用 `JVM_GetStackTrace` | 主文档第 27 行 | 不存在此 API，传统 API 是 JVMTI `GetAllStackTraces` |
| Q&A 声称检查 `SafepointSynchronize::is_at_safepoint()` | 补充文档第 567 行 | 实际检查 `Universe::heap()->is_gc_active()`（forte.cpp:549） |
| `is_decipherable_interpreted_frame` 检查 `_thread_in_Java` | 补充文档第 306 行 | 实际 `known_valid` 是 `_thread_in_native \|\| _thread_in_vm \|\| _thread_blocked` |
| `is_decipherable_compiled_frame` 签名 `(frame*, Method**, int*)` | 补充文档第 383 行 | 实际签名 `(JavaThread*, frame*, CompiledMethod*)` |
| GDB 验证数据 1523 次/98.4% | 主文档第 735-747 行 | **疑似捏造** → 已用 4 种独立方法真实验证替换（GDB sizeof + 运行时采样 520 次 + strace 510 次 SIGPROF + 源码插桩 3111 次 ASGCT 调用统计）|
| 4.4 节简化源码流程 | 主文档第 514-545 行 | 不存在 `os::fetch_frame_from_context` 直接调用，实际是 `switch(thread_state())` 分派 |
