# invocationCounter_init() 详细分析

> 文档位置：`jvm-md/InvocationCounter/invocationCounter_init.md`
> 源码位置：`src/hotspot/share/interpreter/invocationCounter.cpp:169`

---

## 1. 功能定位

### 1.1 一句话总结

**`invocationCounter_init()` 是 JVM 的"热点检测温度计"** —— 它初始化方法调用计数器系统，设置触发 JIT 编译的各项阈值，是从"冷代码"变"热代码"的关键判断依据。

### 1.2 为什么需要调用计数器？

| 问题 | 调用计数器的作用 |
|------|------------------|
| **识别热点方法** | 频繁调用的方法值得编译优化 |
| **触发 JIT 编译** | 计数超过阈值时触发编译 |
| **触发 OSR 编译** | 循环次数超过阈值时触发栈上替换 |
| **触发 Profiling** | 计数达到阈值时开始收集方法数据 |
| **平衡启动与峰值性能** | 避免过早编译浪费资源 |

### 1.3 在启动流程中的位置

```
init_globals()
├── codeCache_init()
├── stubRoutines_init1()
├── universe_init()
├── interpreter_init()              ← 解释器代码生成
├── invocationCounter_init()        ← 【当前分析】设置编译阈值
├── SharedRuntime::generate_stubs()
├── universe2_init()
├── javaClasses_init()
├── compileBroker_init()            ← 编译器线程启动
└── ...
```

---

## 2. 源码解读

### 2.1 invocationCounter_init() 入口函数

```cpp
// src/hotspot/share/interpreter/invocationCounter.cpp:169
void invocationCounter_init() {
  InvocationCounter::reinitialize(DelayCompilationDuringStartup);
}
```

**关键点**：
- `DelayCompilationDuringStartup`：启动期间是否延迟编译（默认 true）
- 如果延迟，则使用衰减机制而非立即触发编译

### 2.2 reinitialize() 核心实现

```cpp
// src/hotspot/share/interpreter/invocationCounter.cpp:132-167
void InvocationCounter::reinitialize(bool delay_overflow) {
  // ===== Step 1: 定义状态机 =====
  guarantee((int)number_of_states <= (int)state_limit, "adjust number_of_state_bits");
  
  // 状态 0: wait_for_nothing - 不等待任何事件
  def(wait_for_nothing, 0, do_nothing);
  
  // 状态 1: wait_for_compile - 等待编译
  if (delay_overflow) {
    def(wait_for_compile, 0, do_decay);  // 启动期间：衰减计数
  } else {
    def(wait_for_compile, 0, dummy_invocation_counter_overflow);  // 正常：触发编译
  }

  // ===== Step 2: 计算解释器阈值 =====
  // 调用计数阈值（触发 JIT 编译）
  InterpreterInvocationLimit = CompileThreshold << number_of_noncount_bits;
  
  // Profiling 阈值
  InterpreterProfileLimit = ((CompileThreshold * InterpreterProfilePercentage) / 100) 
                            << number_of_noncount_bits;

  // ===== Step 3: 计算后向分支阈值（触发 OSR）=====
  if (ProfileInterpreter) {
    // 有 Profiling：比较的是 MethodData 计数器，不需要位移
    InterpreterBackwardBranchLimit = 
        (CompileThreshold * (OnStackReplacePercentage - InterpreterProfilePercentage)) / 100;
  } else {
    // 无 Profiling：比较的是 InvocationCounter
    InterpreterBackwardBranchLimit = 
        ((CompileThreshold * OnStackReplacePercentage) / 100) << number_of_noncount_bits;
  }

  // ===== Step 4: 断言验证 =====
  assert(0 <= InterpreterBackwardBranchLimit,
         "OSR threshold should be non-negative");
  assert(0 <= InterpreterProfileLimit &&
         InterpreterProfileLimit <= InterpreterInvocationLimit,
         "profile threshold should be less than the compilation threshold");
}
```

---

## 3. 核心数据结构

### 3.1 InvocationCounter 类

```cpp
class InvocationCounter {
private:
  unsigned int _counter;  // 32位计数器，格式：[count|carry|state]
  
  // 位布局常量
  enum PrivateConstants {
    number_of_state_bits = 2,    // 2 位状态
    number_of_carry_bits = 1,    // 1 位进位标志
    number_of_noncount_bits = 3, // 状态+进位 = 3 位
    // ...
  };
  
  // 静态阈值
  static int InterpreterInvocationLimit;      // 编译阈值
  static int InterpreterBackwardBranchLimit;  // OSR 阈值
  static int InterpreterProfileLimit;         // Profiling 阈值
  
  // 状态机
  static int    _init  [number_of_states];    // 初始值
  static Action _action[number_of_states];    // 溢出动作
};
```

### 3.2 计数器位布局

```
_counter 字段（32 位）：
┌────────────────────────────────────────────────────────────────────────┐
│  bit 31                                    bit 3  bit 2  bit 1  bit 0  │
├────────────────────────────────────────────────────────────────────────┤
│        count (29 位)                        │ carry │    state (2位)   │
│        调用次数                              │ 进位  │    状态          │
└────────────────────────────────────────────────────────────────────────┘

state 值:
  00 = wait_for_nothing  (不等待，已经编译或不需要编译)
  01 = wait_for_compile  (等待编译触发)

carry 标志:
  0 = 正常
  1 = 曾经溢出过（粘性标志）
```

### 3.3 状态机

```
                    状态转换图
                    
    ┌───────────────────────────────────────┐
    │                                       │
    │    ┌──────────────────┐               │
    │    │ wait_for_compile │               │
    │    │   (初始状态)      │               │
    │    └────────┬─────────┘               │
    │             │                         │
    │             │ count > threshold       │
    │             │                         │
    │             ▼                         │
    │    ┌──────────────────┐               │
    │    │ trigger_compile()│ ──────────────┤
    │    │   触发编译        │               │
    │    └────────┬─────────┘               │
    │             │                         │
    │             │ 编译完成 / 衰减          │
    │             │                         │
    │             ▼                         │
    │    ┌──────────────────┐               │
    │    │wait_for_nothing  │ ◄─────────────┘
    │    │   (最终状态)      │    set_carry()
    │    └──────────────────┘
    │
    └───────────────────────────────────────┘
```

---

## 4. MethodCounters 详解

### 4.1 类定义

`MethodCounters` 是每个方法独有的计数器存储结构：

```cpp
class MethodCounters : public Metadata {
  // 后向链接
  Method*           _method;                     // 所属方法
  
  // 调用统计
  int               _interpreter_invocation_count;  // 解释执行调用次数
  u2                _interpreter_throwout_count;    // 异常退出次数
  
  // 核心计数器
  InvocationCounter _invocation_counter;         // 调用计数器
  InvocationCounter _backedge_counter;           // 后向分支计数器
  
  // 每方法阈值（支持单独调整）
  int               _interpreter_invocation_limit;       // 编译阈值
  int               _interpreter_backward_branch_limit;  // OSR 阈值
  int               _interpreter_profile_limit;          // Profiling 阈值
  int               _invoke_mask;                        // 调用通知掩码
  int               _backedge_mask;                      // 后向分支通知掩码
  
  // 分层编译支持
  float             _rate;                       // 事件率
  jlong             _prev_time;                  // 上次采样时间
  u1                _highest_comp_level;         // 最高编译级别
  u1                _highest_osr_comp_level;     // 最高 OSR 编译级别
  
  // nmethod 老化
  int               _nmethod_age;                // 编译代码年龄
};
```

### 4.2 内存布局

```
MethodCounters 对象布局（x86_64）：
偏移      字段名                          大小    说明
────────────────────────────────────────────────────────────────
0x000    [Metadata header]               8       元数据头
0x008    _method                         8       所属方法指针
0x010    _interpreter_invocation_count   4       解释执行次数
0x014    _interpreter_throwout_count     2       异常退出次数
0x016    [padding]                       2       对齐
0x018    _invocation_counter             4       调用计数器
0x01C    _backedge_counter               4       后向分支计数器
0x020    _nmethod_age                    4       编译代码年龄
0x024    _interpreter_invocation_limit   4       编译阈值
0x028    _interpreter_backward_branch_limit 4    OSR 阈值
0x02C    _interpreter_profile_limit      4       Profiling 阈值
0x030    _invoke_mask                    4       调用掩码
0x034    _backedge_mask                  4       后向分支掩码
0x038    _rate                           4       事件率
0x03C    [padding]                       4       对齐
0x040    _prev_time                      8       上次时间
0x048    _highest_comp_level             1       最高编译级别
0x049    _highest_osr_comp_level         1       最高 OSR 级别
0x04A    [padding]                       6       对齐
────────────────────────────────────────────────────────────────
总大小：~80 字节
```

---

## 5. 阈值计算详解

### 5.1 默认参数值

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `CompileThreshold` | 10000 (C2) / 1500 (C1) | 编译触发阈值 |
| `OnStackReplacePercentage` | 140% | OSR 百分比 |
| `InterpreterProfilePercentage` | 33% | Profiling 百分比 |
| `number_of_noncount_bits` | 3 | 非计数位数 |

### 5.2 阈值计算公式

```
假设 CompileThreshold = 10000

┌─────────────────────────────────────────────────────────────────────────────┐
│                         阈值计算公式                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  InterpreterInvocationLimit = CompileThreshold << 3                         │
│                             = 10000 << 3                                    │
│                             = 80000                                         │
│                                                                             │
│  InterpreterProfileLimit = (CompileThreshold * 33 / 100) << 3               │
│                          = (10000 * 33 / 100) << 3                          │
│                          = 3300 << 3                                        │
│                          = 26400                                            │
│                                                                             │
│  InterpreterBackwardBranchLimit (有 Profiling):                              │
│    = CompileThreshold * (140 - 33) / 100                                    │
│    = 10000 * 107 / 100                                                      │
│    = 10700                                                                  │
│                                                                             │
│  InterpreterBackwardBranchLimit (无 Profiling):                              │
│    = (CompileThreshold * 140 / 100) << 3                                    │
│    = 14000 << 3                                                             │
│    = 112000                                                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.3 实际计数与阈值的关系

```
_counter 原始值与实际计数的关系：

原始值:       0x0001_8003  (二进制: ...000_0001_1000_0000_0000_0011)
                                       │              │  │  │
                                       │              │  └──┴─ state = 1 (wait_for_compile)
                                       │              └────────── carry = 0
                                       └─────────────────────── count = 0x3000 = 12288

实际调用次数 = _counter >> 3 = 12288 / 8 = 1536

比较时不需要移位，直接比较原始值：
  _counter (80003) vs InterpreterInvocationLimit (80000)
    如果 _counter >= InterpreterInvocationLimit，触发编译
```

---

## 6. 解释器中的计数器使用

### 6.1 方法入口处的计数器增加

```cpp
// src/hotspot/cpu/x86/templateInterpreterGenerator_x86.cpp:385-455
void TemplateInterpreterGenerator::generate_counter_incr(
        Label* overflow,           // 溢出跳转标签
        Label* profile_method,     // Profiling 跳转标签
        Label* profile_method_continue) {
        
  if (TieredCompilation) {
    // === 分层编译模式 ===
    // 增加计数器，使用掩码检查是否需要通知
    __ increment_mask_and_jump(invocation_counter, increment, mask, 
                               rcx, false, Assembler::zero, overflow);
  } else {
    // === 非分层编译模式 ===
    // 更新 invocation_counter
    __ movl(rcx, invocation_counter);
    __ incrementl(rcx, InvocationCounter::count_increment);  // +8 (count_grain)
    __ movl(invocation_counter, rcx);
    
    // 加上 backedge_counter（两者加一起比较）
    __ movl(rax, backedge_counter);
    __ andl(rax, InvocationCounter::count_mask_value);
    __ addl(rcx, rax);  // rcx = invocation + backedge
    
    // 检查是否需要 Profiling
    if (ProfileInterpreter && profile_method != NULL) {
      __ cmp32(rcx, interpreter_profile_limit);
      __ jcc(Assembler::less, *profile_method_continue);
      // 达到 profile 阈值，跳转创建 MethodData
      __ test_method_data_pointer(rax, *profile_method);
    }
    
    // 检查是否需要编译
    __ cmp32(rcx, interpreter_invocation_limit);
    __ jcc(Assembler::aboveEqual, *overflow);  // 达到阈值，跳转编译
  }
}
```

### 6.2 计数器溢出处理

```cpp
// 当计数器超过阈值时调用
void TemplateInterpreterGenerator::generate_counter_overflow(Label& do_continue) {
  // 保存状态
  __ push(rbx);  // 保存 Method*
  
  // 调用 InterpreterRuntime::frequency_counter_overflow
  __ call_VM(noreg, 
             CAST_FROM_FN_PTR(address, InterpreterRuntime::frequency_counter_overflow),
             rbx);
             
  // 恢复并继续
  __ pop(rbx);
  __ jmp(do_continue);
}
```

### 6.3 执行流程图

```
                    方法调用执行流程
                           │
                           ▼
┌──────────────────────────────────────────────────────────┐
│  generate_method_entry()                                 │
│  ┌─────────────────────────────────────────────────────┐│
│  │ 1. 获取 MethodCounters                               ││
│  │    rax = Method->method_counters                    ││
│  └─────────────────────────────────────────────────────┘│
│                          │                              │
│                          ▼                              │
│  ┌─────────────────────────────────────────────────────┐│
│  │ 2. 增加调用计数器                                    ││
│  │    _invocation_counter += count_increment (8)        ││
│  └─────────────────────────────────────────────────────┘│
│                          │                              │
│                          ▼                              │
│  ┌─────────────────────────────────────────────────────┐│
│  │ 3. 计算总计数 (invocation + backedge)                ││
│  └─────────────────────────────────────────────────────┘│
│                          │                              │
│                          ▼                              │
│  ┌─────────────────────────────────────────────────────┐│
│  │ 4. 检查 Profile 阈值                                 ││
│  │    if (count >= InterpreterProfileLimit)            ││
│  │        创建 MethodData                              ││
│  └─────────────────────────────────────────────────────┘│
│                          │                              │
│                          ▼                              │
│  ┌─────────────────────────────────────────────────────┐│
│  │ 5. 检查编译阈值                                      ││
│  │    if (count >= InterpreterInvocationLimit)         ││
│  │        ───────────────────────────────────►  编译!  ││
│  └─────────────────────────────────────────────────────┘│
│                          │                              │
│                          ▼                              │
│  ┌─────────────────────────────────────────────────────┐│
│  │ 6. 执行方法                                          ││
│  └─────────────────────────────────────────────────────┘│
│                                                         │
└──────────────────────────────────────────────────────────┘
```

---

## 7. 衰减机制

### 7.1 do_decay() 函数

```cpp
// src/hotspot/share/interpreter/invocationCounter.cpp:103-109
static address do_decay(const methodHandle& method, TRAPS) {
  // 启动期间：衰减计数器，延迟编译
  MethodCounters* mcs = method->method_counters();
  assert(mcs != NULL, "");
  mcs->invocation_counter()->decay();
  return NULL;
}
```

### 7.2 decay() 实现

```cpp
// src/hotspot/share/interpreter/invocationCounter.hpp:134-140
inline void InvocationCounter::decay() {
  int c = count();
  int new_count = c >> 1;  // 计数减半
  // 防止归零（区分从未执行的方法）
  if (c > 0 && new_count == 0) new_count = 1;
  set(state(), new_count);
}
```

### 7.3 衰减的作用

```
启动期间衰减机制的目的：

1. 避免过早编译
   - 启动时大量方法被调用少量次数
   - 如果立即编译，会浪费资源

2. 让真正的热点方法脱颖而出
   - 衰减后仍然超过阈值的方法才是真正的热点
   
3. 时间线示例：
   
   时间 │  方法 A (热点)  │  方法 B (启动)
   ─────┼────────────────┼────────────────
   T1   │  count=100     │  count=50
   T2   │  调用，count=101│  衰减，count=25
   T3   │  调用，count=102│  衰减，count=12
   T4   │  调用，count=103│  衰减，count=6
   ...  │  超过阈值，编译！│  永远不会编译
```

---

## 8. 进位标志 (Carry Flag)

### 8.1 set_carry() 函数

```cpp
// src/hotspot/share/interpreter/invocationCounter.cpp:43-53
void InvocationCounter::set_carry() {
  set_carry_flag();  // 设置 carry 位
  
  // 减少计数值，允许方法继续执行更多次
  int old_count = count();
  int new_count = MIN2(old_count, (int) (CompileThreshold / 2));
  
  // 防止归零
  if (new_count == 0) new_count = 1;
  if (old_count != new_count) set(state(), new_count);
}
```

### 8.2 Carry 标志的作用

```
Carry 标志的用途：

1. 标记"曾经很热"的方法
   - carry = 1 表示这个方法曾经达到过编译阈值
   - 即使计数被重置，carry 仍然保留

2. 用于编译决策
   - 编译器可以参考 carry 标志
   - 决定是否优先编译这个方法

3. 粘性标志
   - 一旦设置，永不清除
   - 除非方法被卸载
```

---

## 9. 分层编译下的计数器

### 9.1 分层编译简介

```
分层编译级别：

Level 0: 解释执行
Level 1: C1 编译，无 profiling
Level 2: C1 编译，有限 profiling
Level 3: C1 编译，完整 profiling
Level 4: C2 编译（最优化）

典型路径：
  L0 → L3 → L4  (收集 profile 后优化编译)
  L0 → L2 → L4  (快速编译路径)
  L0 → L1       (对不需要优化的方法)
```

### 9.2 分层编译中的阈值

```cpp
// 分层编译使用不同的通知机制
// Tier0InvokeNotifyFreqLog = 7 (默认)
// 每 2^7 = 128 次调用通知一次

// MethodCounters 中的掩码
_invoke_mask = right_n_bits(Tier0InvokeNotifyFreqLog) << count_shift;
// = 0b0111_1111 << 3 = 0x3F8

_backedge_mask = right_n_bits(Tier0BackedgeNotifyFreqLog) << count_shift;
// = 0b0001_1111 << 3 = 0xF8
```

### 9.3 分层编译计数器增加逻辑

```asm
; 分层编译中的计数器增加（x86_64 汇编）
increment_mask_and_jump:
    mov  ecx, [rax + invocation_counter_offset]  ; 读取计数器
    add  ecx, count_increment                    ; +8
    mov  [rax + invocation_counter_offset], ecx  ; 写回
    and  ecx, [rax + invoke_mask_offset]         ; 与掩码做 AND
    jz   overflow                                ; 如果为 0，跳转通知
```

---

## 10. GDB 验证

### 10.1 实际 GDB 验证结果

【GDB 验证】条件：-Xms256m -Xmx256m -Xint

```
=== Global Thresholds ===
CompileThreshold: 10000
OnStackReplacePercentage: 140
InterpreterProfilePercentage: 33

=== Computed Limits ===
InterpreterInvocationLimit: 80000 (raw) / 10000 (actual)
InterpreterProfileLimit: 26400 (raw) / 3300 (actual)
InterpreterBackwardBranchLimit: 112000

=== State Machine ===
_init[wait_for_nothing]: 0
_init[wait_for_compile]: 0
```

### 10.2 验证分析

**关键发现**：

1. **编译阈值计算验证**：
   - `CompileThreshold = 10000`
   - `InterpreterInvocationLimit = 10000 << 3 = 80000` ✅
   - 实际计数 = 80000 >> 3 = 10000 ✅

2. **Profile 阈值验证**：
   - `InterpreterProfileLimit = (10000 * 33 / 100) << 3 = 26400` ✅
   - 实际计数 = 26400 >> 3 = 3300 ✅
   - 含义：方法调用 3300 次后开始收集 profile 数据

3. **OSR 阈值验证**（无 ProfileInterpreter）：
   - `InterpreterBackwardBranchLimit = (10000 * 140 / 100) << 3 = 112000` ✅
   - 含义：循环执行 14000 次后触发 OSR 编译

4. **状态机初始值**：
   - 两个状态的初始值都是 0
   - 意味着新创建的计数器从 0 开始计数

### 10.3 验证脚本

```gdb
# jvm-md/InvocationCounter/gdb_invocationCounter_init.txt

set pagination off
set print pretty on

# 断点设在初始化完成后
b invocationCounter_init
run -Xms256m -Xmx256m -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

finish

# === 全局阈值 ===
printf "\n========== Global Invocation Thresholds ==========\n"
printf "CompileThreshold: %d\n", CompileThreshold
printf "OnStackReplacePercentage: %d\n", OnStackReplacePercentage
printf "InterpreterProfilePercentage: %d\n", InterpreterProfilePercentage
printf "\n"
printf "InterpreterInvocationLimit: %d (实际: %d)\n", InvocationCounter::InterpreterInvocationLimit, InvocationCounter::InterpreterInvocationLimit >> 3
printf "InterpreterProfileLimit: %d (实际: %d)\n", InvocationCounter::InterpreterProfileLimit, InvocationCounter::InterpreterProfileLimit >> 3
printf "InterpreterBackwardBranchLimit: %d\n", InvocationCounter::InterpreterBackwardBranchLimit

# === 状态机 ===
printf "\n========== State Machine ==========\n"
printf "_init[wait_for_nothing]: %d\n", InvocationCounter::_init[0]
printf "_init[wait_for_compile]: %d\n", InvocationCounter::_init[1]
printf "_action[wait_for_nothing]: %p\n", InvocationCounter::_action[0]
printf "_action[wait_for_compile]: %p\n", InvocationCounter::_action[1]

# === 位布局常量 ===
printf "\n========== Bit Layout Constants ==========\n"
printf "count_increment: %d\n", 8
printf "number_of_noncount_bits: %d\n", 3

quit
```

### 10.2 执行验证

```bash
cd /data/workspace/openjdk-cut-new
gdb -x jvm-md/InvocationCounter/gdb_invocationCounter_init.txt \
    ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java
```

---

## 11. 相关 JVM 参数

### 11.1 编译阈值参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-XX:CompileThreshold=N` | 10000 (C2) | 方法调用编译阈值 |
| `-XX:OnStackReplacePercentage=N` | 140 | OSR 编译百分比 |
| `-XX:InterpreterProfilePercentage=N` | 33 | Profiling 开始百分比 |
| `-XX:Tier0InvokeNotifyFreqLog=N` | 7 | 分层编译调用通知频率 |
| `-XX:Tier0BackedgeNotifyFreqLog=N` | 5 | 分层编译后向分支通知频率 |

### 11.2 调试参数

| 参数 | 说明 |
|------|------|
| `-XX:+PrintCompilation` | 打印编译事件 |
| `-XX:+CountBytecodes` | 统计字节码执行 |
| `-XX:+LogCompilation` | 记录编译日志 |
| `-XX:-TieredCompilation` | 禁用分层编译 |
| `-XX:+DelayCompilationDuringStartup` | 启动期间延迟编译（默认 true）|

### 11.3 调整示例

```bash
# 降低编译阈值，更早触发 JIT
java -XX:CompileThreshold=1000 ...

# 禁用分层编译，直接使用 C2
java -XX:-TieredCompilation ...

# 查看编译过程
java -XX:+PrintCompilation ...
```

---

## 12. 总结

### 12.1 核心流程

```
invocationCounter_init()
    │
    └── InvocationCounter::reinitialize(DelayCompilationDuringStartup)
        │
        ├── def(wait_for_nothing, 0, do_nothing)
        │
        ├── def(wait_for_compile, 0, delay ? do_decay : trigger_compile)
        │
        ├── InterpreterInvocationLimit = CompileThreshold << 3
        │       = 10000 << 3 = 80000
        │
        ├── InterpreterProfileLimit = (CompileThreshold * 33%) << 3
        │       = 3300 << 3 = 26400
        │
        └── InterpreterBackwardBranchLimit = CompileThreshold * 107%
                = 10700
```

### 12.2 关键数据总结

| 组件 | 值/说明 |
|------|---------|
| `_counter` 位布局 | [29位 count][1位 carry][2位 state] |
| `count_increment` | 8 (每次增加 8，因为低 3 位是状态) |
| 默认编译阈值 | 10000 次调用 |
| 默认 OSR 阈值 | ~14000 次后向分支 |
| 默认 Profile 阈值 | 3300 次调用 |
| 状态数 | 2 (wait_for_nothing, wait_for_compile) |

### 12.3 与其他组件的关系

```
invocationCounter_init()
         │
         │ 设置阈值
         │
         ▼
┌─────────────────────────────────────────────────────────────┐
│  interpreter_init()                                         │
│  解释器在方法入口检查计数器                                   │
│  generate_counter_incr() 增加计数                           │
│  generate_counter_overflow() 处理溢出                       │
└─────────────────────────────────────────────────────────────┘
         │
         │ 计数器溢出
         │
         ▼
┌─────────────────────────────────────────────────────────────┐
│  compileBroker_init()                                       │
│  编译任务提交到编译队列                                       │
│  CompileTask → CompileBroker → C1/C2 编译线程               │
└─────────────────────────────────────────────────────────────┘
         │
         │ 编译完成
         │
         ▼
┌─────────────────────────────────────────────────────────────┐
│  SharedRuntime                                              │
│  方法被重定向到编译后的 nmethod                               │
│  后续调用直接执行本地代码                                     │
└─────────────────────────────────────────────────────────────┘
```

---

## 13. 下一步建议

1. **compileBroker_init()**：了解编译任务如何被处理
2. **InterpreterRuntime::frequency_counter_overflow()**：计数器溢出的详细处理
3. **分层编译策略**：CompilationPolicy 如何选择编译级别
4. **OSR 编译流程**：栈上替换的详细实现

---

> 📅 分析时间：2026-02-06
> 📁 源码版本：OpenJDK 11
