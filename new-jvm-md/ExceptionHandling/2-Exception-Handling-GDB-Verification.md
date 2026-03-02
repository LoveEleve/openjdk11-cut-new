# Day 33：异常处理 GDB/CLion 验证指南

> 基于 OpenJDK 11 slowdebug，`-Xms8g -Xmx8g -XX:+UseG1GC -Xint`
> 本文档包含：已验证的 sizeof/offset 数据 + CLion 断点验证指南

---

## 第 0 部分：验证目标与方法 ⭐

### 0.1 本文档验证什么？

本文档是 `1-Exception-Handling-Deep-Dive.md` 的**配套验证文档**，通过 GDB 自动采集和 CLion 断点验证，确认以下关键结论：

- `ThreadShadow::_pending_exception` 偏移 = 8（vtable 技巧有效）
- `ExceptionTableElement` sizeof = 8，`HandlerTableEntry` sizeof = 12
- 四层栈保护区大小（Red=4KB, Yellow=8KB, Reserved=4KB, Shadow=88KB）
- `_stack_overflow_limit` = `stack_end + MAX2(guard_zone, shadow_zone)` 数值精确匹配
- 显式异常处理的完整链路（athrow → exception_handler_for_exception → fast_exception_handler_bci_for）
- StackOverflowError 不调构造函数（直接 allocate_instance）

### 0.2 验证方法

| 方法 | 适用场景 | 工具 |
|------|---------|------|
| GDB 自动采集 | sizeof/offset/枚举值等静态数据 | GDB 脚本文件 |
| CLion 断点 | 运行时流程验证（调用链、字段值变化） | CLion + slowdebug JVM |
| 日志参数 | 异常抛出/处理的宏观验证 | `-Xlog:exceptions=info` |

### 0.3 关键发现（与文档预期的差异）

| 项目 | 文档预期 | 实际验证 | 说明 |
|------|---------|---------|------|
| Yellow Zone 大小 | 1 页 = 4KB | **2 页 = 8KB** | slowdebug 版本 `StackYellowPages` 默认值为 2 |
| `_stack_overflow_limit` 计算 | MAX2(guard, shadow) | ✅ 精确匹配 | 验证了 MAX2 逻辑正确 |
| `_pending_exception` 偏移 | 8 | ✅ 8 | vtable 技巧有效 |

---

## 一、测试 Java 程序

文件：`/data/workspace/demo/src/com/wjcoder/ExceptionTest.java`

```java
package com.wjcoder;

public class ExceptionTest {
    
    // 测试 1: 显式 try-catch（走 exception_handler_for_exception）
    public static void testTryCatch() {
        try {
            throw new RuntimeException("test exception");
        } catch (RuntimeException e) {
            System.out.println("Caught: " + e.getMessage());
        }
    }
    
    // 测试 2: 隐式 null 检查（-Xint 模式下走解释器，不走 SIGSEGV）
    public static void testNullPointer() {
        try {
            String s = null;
            int len = s.length();
        } catch (NullPointerException e) {
            System.out.println("Caught NPE");
        }
    }
    
    // 测试 3: 栈溢出
    public static void testStackOverflow() {
        try {
            recursiveCall(0);
        } catch (StackOverflowError e) {
            System.out.println("Caught SOE");
        }
    }
    
    static void recursiveCall(int depth) {
        recursiveCall(depth + 1);
    }
    
    // 测试 4: 多层 catch（验证异常表顺序匹配）
    public static void testMultiCatch() {
        try {
            throw new IllegalArgumentException("multi-catch test");
        } catch (IllegalArgumentException e) {
            System.out.println("Caught IAE: " + e.getMessage());
        } catch (RuntimeException e) {
            System.out.println("Caught RE (should not reach here)");
        } catch (Exception e) {
            System.out.println("Caught E (should not reach here)");
        }
    }
    
    public static void main(String[] args) {
        System.out.println("=== Test 1: try-catch ===");
        testTryCatch();
        System.out.println("=== Test 2: null pointer ===");
        testNullPointer();
        System.out.println("=== Test 3: stack overflow ===");
        testStackOverflow();
        System.out.println("=== Test 4: multi-catch ===");
        testMultiCatch();
        System.out.println("=== All tests passed ===");
    }
}
```

CLion 运行参数：`-Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.ExceptionTest`

---

## 二、已验证数据（GDB 自动采集）

### 2.1 数据结构 sizeof / offset ✅

| 结构 | sizeof | 文档预期 | 验证结果 |
|------|--------|---------|---------|
| **ThreadShadow** | **32 字节** | vtable(8) + oop(8) + char*(8) + int(4) + pad(4) = 32 | ✅ 完全一致 |
| **ExceptionTableElement** | **8 字节** | 4 × u2 = 8 | ✅ 完全一致 |
| **HandlerTableEntry** | **12 字节** | 3 × int = 12 | ✅ 完全一致 |
| **ImplicitExceptionTable** | **32 字节** | uint(4) + uint(4) + ptr(8) + pad + ReallocMark | ✅ |
| **ExceptionHandlerTable** | **32 字节** | ptr(8) + int(4) + int(4) + ReallocMark(8+8) | ✅ |
| **ExceptionCache** | **288 字节** | Klass*(8) + pc[16](128) + handler[16](128) + int(4) + ptr(8) + pad | ✅ |
| **Thread** | **856 字节** | — | ✅ |
| **JavaThread** | **1888 字节** | — | ✅ |

### 2.2 ThreadShadow 字段偏移 ✅

| 字段 | 偏移 | 含义 |
|------|------|------|
| [vtable ptr] | 0 | 虚函数表指针（`unused_initial_virtual` 强制生成的） |
| `_pending_exception` | **8** | 异常 oop 指针 |
| `_exception_file` | 16 | 调试用 C++ 源文件名 |
| `_exception_line` | 24 | 调试用行号 |

**关键验证**：`Thread::_pending_exception` 偏移 = `ThreadShadow::_pending_exception` 偏移 = **8**。这证实了文档中说的 "vtable 强制技巧确保偏移一致"。

### 2.3 HandlerTableEntry 字段偏移 ✅

| 字段 | 偏移 | 含义 |
|------|------|------|
| `_bci` | 0 | handler bci（或 subtable header 的 len） |
| `_pco` | 4 | pc offset（或 subtable header 的 catch_pco） |
| `_scope_depth` | 8 | 内联深度 |

### 2.4 栈保护区大小 ✅

| Zone | 大小 | 页数 | 文档预期 |
|------|------|------|---------|
| **Red Zone** | **4,096 字节 (4 KB)** | 1 页 | "默认 1 页 = 4KB" ✅ |
| **Yellow Zone** | **8,192 字节 (8 KB)** | 2 页 | 文档写"默认 1 页"，**实际是 2 页** ⚠️ |
| **Reserved Zone** | **4,096 字节 (4 KB)** | 1 页 | "默认 1 页 = 4KB" ✅ |
| **Shadow Zone** | **90,112 字节 (88 KB)** | 22 页 | 文档未给具体值 |

**重要发现**：Yellow Zone 实际是 **8KB (2 页)**，不是文档里写的 1 页。这是因为 slowdebug 版本 `StackYellowPages` 默认值可能是 2。

### 2.5 栈地址布局验证 ✅

```
线程栈布局（实际数据）：

stack_base               = 0x7ffff780c000  （高地址，栈起始）
stack_size               = 1,048,576 (1024 KB = 1 MB)

stack_end                = 0x7ffff770c000  （低地址，栈底）
  │  Red Zone    (4 KB)
red_zone_base            = 0x7ffff770d000  （stack_end + 4096）
  │  Yellow Zone (8 KB)
yellow_zone_base         = 0x7ffff770f000  （red_base + 8192）
  │  Reserved    (4 KB)
reserved_zone_base       = 0x7ffff7710000  （yellow_base + 4096）
  │
_stack_overflow_limit    = 0x7ffff7722000  ← ★
  │  Shadow Zone (88 KB, 逻辑区域)
  │
  │  Normal Stack (可用空间)
stack_base               = 0x7ffff780c000

Guard Zone 总大小 = R + Y + Res = 4 + 8 + 4 = 16 KB
Shadow Zone 大小 = 88 KB
_stack_overflow_limit = stack_end + MAX2(16KB, 88KB) = stack_end + 88KB ✅
```

**关键验证**：`_stack_overflow_limit` 的 MAX2 计算完全正确：
- expected = 0x7ffff770c000 + 90112 = 0x7ffff7722000
- actual   = 0x7ffff7722000 ✅

### 2.6 _stack_guard_state 枚举值

```cpp
// thread.hpp
enum StackGuardState {
  stack_guard_unused,                    // = 0, 非 Java 线程
  stack_guard_yellow_reserved_disabled,  // = 1, Yellow+Reserved 已 disable
  stack_guard_reserved_disabled,         // = 2, 仅 Reserved 已 disable
  stack_guard_enabled                    // = 3, 全部启用（正常状态）
};
```

实测值 = **3 (stack_guard_enabled)**，符合正常运行状态。✅

---

## 三、CLion 断点验证指南

### 验证 1：显式异常处理流程（testTryCatch）

> 目标：验证 `athrow → exception_handler_for_exception → fast_exception_handler_bci_for → handler_bci` 的完整链路

**断点位置与观察变量：**

| # | 文件 | 行号/函数 | 观察什么 | 预期 |
|---|------|----------|---------|------|
| 1 | `interpreterRuntime.cpp:470` | `exception_handler_for_exception` 入口 | `thread`, `exception`, `current_bci` | `exception` 是 RuntimeException oop；`current_bci` = athrow 指令的 bci |
| 2 | `method.cpp:200` | `fast_exception_handler_bci_for` 入口 | `throw_bci`, `mh._value`, `ex_klass` | `throw_bci` 与上面的 `current_bci` 一致 |
| 3 | `method.cpp:207` | for 循环内 | `i`, `beg_bci`, `end_bci`, `handler_bci`, `klass_index` | 遍历异常表每条记录，看 beg_bci ≤ throw_bci < end_bci |
| 4 | `method.cpp:227-228` | `is_subtype_of` 匹配 | `handler_bci` | 对于 RuntimeException → catch(RuntimeException)，应该匹配成功 |
| 5 | `interpreterRuntime.cpp:597` | handler_pc 赋值 | `handler_bci`, `handler_pc` | handler_bci ≥ 0，handler_pc = code_base + handler_bci |

**关键追踪**：
- 异常表长度：在 `method.cpp:204` 看 `table.length()`，testTryCatch 应该有 **1 条**异常表记录
- 匹配路径：RuntimeException 是具体类型，走的是 `is_subtype_of` 路径（不是 catch-all）

---

### 验证 2：多层 catch 顺序匹配（testMultiCatch）

> 目标：验证异常表**顺序扫描**，第一个匹配就返回

**断点位置同验证 1，但关注点不同：**

| 观察点 | 预期 |
|--------|------|
| `table.length()` | testMultiCatch 应有 **3 条**异常表记录（IAE、RE、Exception） |
| for 循环 `i` 的值 | 应该在 **i=0** 就匹配成功（IAE 是第一条） |
| `klass_index` | 3 条记录的 klass_index 应该指向不同的异常类 |
| `is_subtype_of` 结果 | 第一条就 true（IAE 是 IAE 的子类） |

**如果把 `throw new IllegalArgumentException` 改成 `throw new RuntimeException`**：
- 第一条（IAE）不匹配（RuntimeException 不是 IAE 的子类）
- 第二条（RE）匹配 → i=1 时返回

---

### 验证 3：栈溢出处理（testStackOverflow）

> 目标：验证 StackOverflowError 的特殊创建路径（不调构造函数）

**断点位置与观察变量：**

| # | 文件 | 行号/函数 | 观察什么 | 预期 |
|---|------|----------|---------|------|
| 1 | `sharedRuntime.cpp:769` | `throw_StackOverflowError_common` 入口 | `thread`, `delayed` | `delayed` = false（非延迟模式） |
| 2 | `sharedRuntime.cpp:774` | `allocate_instance` 调用 | — | 直接分配，**不调 `<init>`** |
| 3 | `sharedRuntime.cpp:781` | `fill_in_stack_trace` | `exception` | 直接填充堆栈跟踪 |
| 4 | `sharedRuntime.cpp:784` | `Atomic::inc(&_stack_overflow_errors)` | — | 计数器 +1 |

**关键追踪**：
- 观察调用栈（bt）：应该能看到 `Interpreter::throw_StackOverflowError_entry` → 信号处理或解释器检查
- `_stack_guard_state` 的变化：进入时应该已经从 3 (enabled) 变成了 1 (yellow_reserved_disabled)

**进阶验证**：在 `interpreterRuntime.cpp:584` 断点：
```cpp
if (handler_bci < 0 || !thread->reguard_stack((address) &continuation))
```
- SOE 在 `recursiveCall` 中抛出，`recursiveCall` 没有 try-catch → `handler_bci < 0` → 走 `remove_activation`
- 逐帧展开直到 `testStackOverflow` 的 catch(StackOverflowError) 匹配

---

### 验证 4：隐式空指针检查（需要关闭 -Xint）

> ⚠️ 重要：`-Xint` 模式下**不会**触发隐式 null 检查！解释器每条字节码都有显式 null check。
> 要验证隐式 null 检查，必须用 **`-Xcomp`** 或者至少 **`-XX:-TieredCompilation`** 让代码被编译。

**运行参数改为**：`-Xms8g -Xmx8g -XX:+UseG1GC -cp /data/workspace/demo/src com.wjcoder.ExceptionTest`
（去掉 `-Xint`，让 C2 编译 `testNullPointer`）

但注意：需要足够的预热让方法被编译。可以在 main 里加循环调用 `testNullPointer` 10000 次。

**断点位置：**

| # | 文件 | 函数 | 观察什么 | 预期 |
|---|------|------|---------|------|
| 1 | `os_linux_x86.cpp:268` | `JVM_handle_linux_signal` | `sig`, `info->si_addr`, `pc` | sig=SIGSEGV, si_addr 是一个小地址（< 4096） |
| 2 | `os_linux_x86.cpp:483` | `needs_explicit_null_check` 判断 | `info->si_addr` | 返回 false（地址 < page_size=4096）→ 判定为隐式 null |
| 3 | `sharedRuntime.cpp:797` | `continuation_for_implicit_exception` | `exception_kind` | 应该是 `IMPLICIT_NULL (0)` |
| 4 | `sharedRuntime.cpp:833-839` | compiled code 分支 | `target_pc` | 从 ImplicitExceptionTable 查到 cont_offset |

**注意**：信号处理函数里的断点可能会干扰信号传递机制，CLion 有时会捕获 SIGSEGV 导致程序停住。需要在 CLion 的 GDB/LLDB 配置中设置：
```
handle SIGSEGV nostop noprint pass
```
或者在 CLion 的 Run > Edit Configurations > GDB Server > GDB Startup Commands 中加入这行。

---

### 验证 5：exception_handler_for_exception 的 do-while 循环

> 目标：验证 bug 4307310 修复——类加载失败时的重复查找

这个比较难触发（需要异常表中引用一个加载会失败的类）。简单了解即可，关注 `interpreterRuntime.cpp:545-558`：

```cpp
if (HAS_PENDING_EXCEPTION) {
    h_exception = Handle(THREAD, PENDING_EXCEPTION);
    CLEAR_PENDING_EXCEPTION;
    if (handler_bci >= 0) {
        current_bci = handler_bci;
        should_repeat = true;  // ← 用新异常从 handler_bci 重新查找
    }
}
```

---

### 验证 6：reguard_stack 时机

> 目标：验证异常展开过程中何时重新启用保护页

**断点**：`thread.cpp` 中 `JavaThread::reguard_stack(address cur_sp)`

```cpp
bool JavaThread::reguard_stack(address cur_sp) {
    if (_stack_guard_state != stack_guard_yellow_reserved_disabled) return true;
    if (register_stack_overflow()) { ... return false; }
    if (cur_sp < stack_reserved_zone_base()) return false;  // 还不够远
    enable_stack_yellow_reserved_zone();  // ★ 重新 mprotect
    return true;
}
```

**预期**：
- SOE 发生时 `_stack_guard_state` = 1 (disabled)
- 展开栈帧过程中，每帧调用 `reguard_stack`
- 当 `cur_sp >= stack_reserved_zone_base()` 时（栈指针已经退到保护区上方），调用 `enable_stack_yellow_reserved_zone()` 恢复保护

---

## 四、文档修正

基于 GDB 验证数据，Day 32 文档需要修正一处：

| 位置 | 原文 | 修正 |
|------|------|------|
| 3.6.7 完整四层布局 | "Yellow Zone（默认 1 页 = 4KB）" | **Yellow Zone（slowdebug 下默认 2 页 = 8KB）** |

说明：Yellow Zone 的大小由 `StackYellowPages` 参数控制，slowdebug 版本默认值为 2 页（8KB），product 版本可能不同。

---

## 五、总结

### 5.1 已验证（GDB 自动采集）

| 验证项 | 结果 |
|--------|------|
| ThreadShadow sizeof = 32, `_pending_exception` offset = 8 | ✅ |
| ExceptionTableElement sizeof = 8 | ✅ |
| HandlerTableEntry sizeof = 12, 字段偏移 0/4/8 | ✅ |
| ImplicitExceptionTable sizeof = 32 | ✅ |
| ExceptionCache sizeof = 288 | ✅ |
| Red Zone = 4KB, Yellow = 8KB, Reserved = 4KB, Shadow = 88KB | ✅ |
| `_stack_overflow_limit` = stack_end + MAX2(guard, shadow) | ✅ 数值精确匹配 |
| `_stack_guard_state` = 3 (enabled) 正常状态 | ✅ |
| `_pending_exception` 在 Thread 和 ThreadShadow 中偏移一致 = 8 | ✅ vtable 技巧有效 |

### 5.2 待 CLion 手动验证

| 验证项 | 断点位置 | 难度 |
|--------|---------|------|
| 显式异常 try-catch 全链路 | `interpreterRuntime.cpp:470` + `method.cpp:200` | ⭐ 简单 |
| 多层 catch 顺序匹配 | `method.cpp:207` 循环内 | ⭐ 简单 |
| SOE 不调构造函数 | `sharedRuntime.cpp:769` | ⭐⭐ 中等 |
| 隐式 null 检查（需关闭 -Xint） | `os_linux_x86.cpp:268` | ⭐⭐⭐ 较难 |
| reguard_stack 恢复保护页 | `thread.cpp` reguard_stack | ⭐⭐ 中等 |
