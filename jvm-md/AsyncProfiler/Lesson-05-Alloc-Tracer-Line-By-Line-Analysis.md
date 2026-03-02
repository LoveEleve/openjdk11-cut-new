# Lesson 5: AllocTracer 逐行源码解析

> 本文档对 AllocTracer 相关的所有源码进行逐行解析，确保每一行代码都理解透彻。

---

## 1. arch.h - 架构相关定义

### 1.1 x86_64 架构定义（逐行解析）

```cpp
// 文件: arch.h 第 51-66 行

#if defined(__x86_64__) || defined(__i386__)
```
**解析**：编译时检查是否为 x86_64 或 i386 架构。

```cpp
typedef unsigned char instruction_t;
```
**解析**：定义指令类型。x86_64 的指令是变长的，最小长度为 1 字节，所以用 `unsigned char` 表示单条指令。

```cpp
const instruction_t BREAKPOINT = 0xcc;
```
**解析**：断点指令 `INT3` 的机器码。当 CPU 执行 `INT3` 时，会触发 `SIGTRAP` 信号。

**为什么是 0xCC？**
- `INT3` 是 x86 的软中断指令
- 操作码 `0xCC` 是 `INT3` 的单字节编码
- 另一种编码 `0xCD 0x03` 是两字节的

```cpp
const int BREAKPOINT_OFFSET = 0;
```
**解析**：断点相对于函数入口的偏移量。x86_64 直接在函数入口（偏移 0）设置断点。

**对比 PPC64**：
```cpp
// PPC64 的断点偏移是 8，因为前两条指令可能被跳过
const int BREAKPOINT_OFFSET = 8;
```

```cpp
const int SYSCALL_SIZE = 2;
```
**解析**：x86_64 系统调用指令 `syscall` 的长度是 2 字节（`0x0F 0x05`）。

```cpp
const int FRAME_PC_SLOT = 1;
```
**解析**：返回地址在栈帧中的位置（相对于 SP）。在 x86_64 调用约定中，调用指令 `call` 会将返回地址压栈，所以 `SP[0]` 是返回地址，`SP[1]` 是其他内容。

```cpp
#define flushCache(addr)  asm volatile("mfence; clflush (%0); mfence" : : "r" (addr) : "memory")
```
**解析**：刷新 CPU 指令缓存。当修改代码段时，需要确保 CPU 看到最新的指令。

**为什么需要这个？**
1. CPU 有指令缓存（I-Cache）和数据缓存（D-Cache）
2. 修改内存中的代码（写入 D-Cache）不会自动更新 I-Cache
3. 需要显式刷新缓存，否则 CPU 可能执行旧指令

**指令解析**：
- `mfence`：内存屏障，确保之前的写操作完成
- `clflush (%0)`：刷新指定地址的缓存行
- `mfence`：再次内存屏障

---

### 1.2 WX_MEMORY 定义

```cpp
// 文件: arch.h 第 191-196 行

#if defined(__aarch64__) && defined(__APPLE__)
#  define WX_MEMORY  true
#else
#  define WX_MEMORY  false
#endif
```
**解析**：Apple M1（aarch64）启用了 W^X（Write XOR Execute）保护，内存要么可写，要么可执行，不能同时可写可执行。

**对 trap.cpp 的影响**：
- 如果 `WX_MEMORY = true`，需要先修改内存权限为可写，写入断点，再修改为可执行
- 如果 `WX_MEMORY = false`，内存可以同时可写可执行

---

## 2. trap.h - Trap 类定义（逐行解析）

```cpp
// 文件: trap.h

#ifndef _TRAP_H
#define _TRAP_H

#include <stdint.h>
#include "arch.h"

const int TRAP_COUNT = 4;
```
**解析**：最多支持 4 个断点。AllocTracer 使用 2 个（TLAB 内/外），LockTracer 可能使用其他。

```cpp
class Trap {
  private:
    int _id;
```
**解析**：断点 ID，范围 0-3。

```cpp
    bool _unprotect;
    bool _protect;
```
**解析**：
- `_unprotect`：安装断点前是否需要取消内存保护
- `_protect`：安装断点后是否需要恢复内存保护

**为什么需要两个标志？**

见 `trap.cpp` 的 `pair()` 函数。如果两个断点在同一内存页，只需要保护/取消保护一次。

```cpp
    uintptr_t _entry;
```
**解析**：目标函数的入口地址（断点位置）。

```cpp
    instruction_t _breakpoint_insn;
```
**解析**：断点指令（x86_64 是 `0xCC`）。

```cpp
    instruction_t _saved_insn;
```
**解析**：被断点指令覆盖的原始指令。卸载断点时恢复。

```cpp
    bool patch(instruction_t insn);
```
**解析**：私有方法，在 `_entry` 地址处写入指令 `insn`。

```cpp
    static uintptr_t _page_start[TRAP_COUNT];
```
**解析**：静态数组，存储每个断点所在内存页的起始地址。用于 `isFaultInstruction()` 判断。

```cpp
  public:
    Trap(int id) : _id(id), _unprotect(true), _protect(WX_MEMORY), _entry(0), _breakpoint_insn(BREAKPOINT) {
    }
```
**解析**：构造函数。
- `_id`：传入的断点 ID
- `_unprotect = true`：默认需要取消保护
- `_protect = WX_MEMORY`：根据架构决定是否需要恢复保护
- `_entry = 0`：初始化为 0，稍后由 `assign()` 设置
- `_breakpoint_insn = BREAKPOINT`：断点指令（x86_64 是 0xCC）

```cpp
    uintptr_t entry() {
        return _entry;
    }
```
**解析**：获取断点地址。

```cpp
    bool covers(uintptr_t pc) {
        // PC points either to BREAKPOINT instruction or to the next one
        return pc - _entry <= sizeof(instruction_t);
    }
```
**解析**：判断 PC 是否在断点范围内。

**为什么 PC 可能指向下一条指令？**

x86_64 的 `INT3` 指令长度是 1 字节。当 CPU 执行 `INT3` 后，PC 可能指向：
- `_entry`：如果断点刚刚触发
- `_entry + 1`：如果某些情况下 CPU 更新了 PC

所以 `covers()` 允许 PC 在 `_entry` 或 `_entry + 1`。

```cpp
    void assign(const void* address, uintptr_t offset = BREAKPOINT_OFFSET);
    void pair(Trap& second);
```
**解析**：
- `assign()`：设置断点地址，保存原始指令
- `pair()`：配对两个断点，优化内存保护操作

```cpp
    bool install() {
        return _entry == 0 || patch(_breakpoint_insn);
    }
```
**解析**：安装断点。
- 如果 `_entry == 0`，说明断点未初始化，返回成功（不做事）
- 否则，调用 `patch(_breakpoint_insn)` 写入断点指令

```cpp
    bool uninstall() {
        return _entry == 0 || patch(_saved_insn);
    }
```
**解析**：卸载断点，恢复原始指令。

```cpp
    static bool isFaultInstruction(uintptr_t pc);
};
```
**解析**：静态方法，判断 PC 是否在任何断点附近。用于处理信号时的快速判断。

---

## 3. trap.cpp - Trap 类实现（逐行解析）

```cpp
// 文件: trap.cpp

#include <sys/mman.h>
#include "trap.h"
#include "os.h"

uintptr_t Trap::_page_start[TRAP_COUNT] = {0};
```
**解析**：静态成员初始化为全 0。

### 3.1 isFaultInstruction

```cpp
bool Trap::isFaultInstruction(uintptr_t pc) {
    for (int i = 0; i < TRAP_COUNT; i++) {
        if (pc - _page_start[i] < OS::page_size) {
            return true;
        }
    }
    return false;
}
```
**解析**：遍历所有断点，检查 PC 是否在任何一个断点所在的内存页内。

**用途**：当收到 `SIGTRAP` 或 `SIGSEGV` 信号时，快速判断是否由断点引起。

### 3.2 assign

```cpp
void Trap::assign(const void* address, uintptr_t offset) {
    _entry = (uintptr_t)address;
    if (_entry == 0) {
        return;
    }
    _entry += offset;
```
**解析**：
1. 保存函数地址
2. 如果地址为 0（未找到符号），直接返回
3. 加上偏移量（x86_64 的 `BREAKPOINT_OFFSET = 0`）

```cpp
#if defined(__arm__) || defined(__thumb__)
    _breakpoint_insn = (_entry & 1) ? BREAKPOINT_THUMB : BREAKPOINT;
    _entry &= ~(uintptr_t)1;
#endif
```
**解析**：ARM 架构特殊处理。ARM 有 ARM 模式和 Thumb 模式，地址最低位表示模式。

```cpp
    _saved_insn = *(instruction_t*)_entry;
```
**解析**：**关键操作**！读取并保存入口处的原始指令。

**为什么可以这样做？**
- 此时函数所在的内存页是可读可执行的（PROT_READ | PROT_EXEC）
- 直接读取内存中的指令字节

```cpp
    _page_start[_id] = _entry & -OS::page_size;
}
```
**解析**：计算断点所在内存页的起始地址。

**位运算解释**：
- `OS::page_size` 通常是 4096（4KB）
- `-OS::page_size` 在二进制中是 `...111111111111000000000000`（高位全 1，低 12 位全 0）
- `_entry & -OS::page_size` 将低 12 位清零，得到页起始地址

**示例**：
```
_entry = 0x7fffd8c9a860
page_size = 4096 = 0x1000
-page_size = 0xfffffffffffff000
_entry & -page_size = 0x7fffd8c9a000  <-- 页起始地址
```

### 3.3 pair

```cpp
void Trap::pair(Trap& second) {
    if (_page_start[_id] == _page_start[second._id]) {
        _protect = false;
        second._unprotect = false;
    }
}
```
**解析**：如果两个断点在同一内存页，优化内存保护操作。

**场景**：
- `send_allocation_in_new_tlab` 和 `send_allocation_outside_tlab` 可能在同一内存页
- 如果在同一页，只需要：
  1. 取消保护一次（由第一个断点做）
  2. 恢复保护一次（由第二个断点做）

**优化效果**：
- 减少系统调用（`mprotect`）
- 提高性能

### 3.4 patch

```cpp
bool Trap::patch(instruction_t insn) {
    if (_unprotect) {
        int prot = WX_MEMORY ? (PROT_READ | PROT_WRITE) : (PROT_READ | PROT_WRITE | PROT_EXEC);
        if (OS::mprotect((void*)(_entry & -OS::page_size), OS::page_size, prot) != 0) {
            return false;
        }
    }
```
**解析**：
1. 如果需要取消保护（`_unprotect = true`）：
   - Apple M1：设置为可读可写（`PROT_READ | PROT_WRITE`）
   - 其他架构：设置为可读可写可执行（`PROT_READ | PROT_WRITE | PROT_EXEC`）
2. 如果 `mprotect` 失败，返回 `false`

**注意**：`_entry & -OS::page_size` 再次计算页起始地址。

```cpp
    *(instruction_t*)_entry = insn;
```
**解析**：**核心操作**！在 `_entry` 地址处写入新指令。

**写入的是断点指令（0xCC）时**：
- 原始指令被覆盖
- CPU 下次执行到这里会触发 `INT3`

```cpp
    flushCache(_entry);
```
**解析**：刷新 CPU 指令缓存，确保 CPU 看到新指令。

```cpp
    if (_protect) {
        OS::mprotect((void*)(_entry & -OS::page_size), OS::page_size, PROT_READ | PROT_EXEC);
    }
    return true;
}
```
**解析**：
1. 如果需要恢复保护（`_protect = true`），设置为可读可执行
2. 返回成功

---

## 4. allocTracer.h - AllocTracer 类定义（逐行解析）

```cpp
// 文件: allocTracer.h

class AllocTracer : public Engine {
```
**解析**：继承自 `Engine` 基类。`Engine` 定义了采样引擎的通用接口。

```cpp
  private:
    static int _trap_kind;
```
**解析**：JDK 版本类型：
- `1`：JDK 8u262+ 或 JDK 10+（参数含 Thread*）
- `2`：JDK 7-9（参数不含 Thread*）

```cpp
    static Trap _in_new_tlab;
    static Trap _outside_tlab;
```
**解析**：两个断点对象。
- `_in_new_tlab`：监控 TLAB 内分配（小对象）
- `_outside_tlab`：监控 TLAB 外分配（大对象）

```cpp
    static u64 _interval;
    static volatile u64 _allocated_bytes;
```
**解析**：
- `_interval`：采样间隔（字节）。例如 `--alloc 1m` 表示每分配 1MB 采样一次
- `_allocated_bytes`：已分配字节的累计值（原子计数器）

```cpp
    static Error initialize();
    static void recordAllocation(void* ucontext, EventType event_type, uintptr_t rklass,
                                 uintptr_t total_size, uintptr_t instance_size);
```
**解析**：
- `initialize()`：查找 JVM 符号，初始化断点
- `recordAllocation()`：记录分配事件

```cpp
  public:
    const char* type() {
        return "alloc_tracer";
    }
    
    const char* title() {
        return "Allocation profile";
    }
    
    const char* units() {
        return "bytes";
    }
```
**解析**：元信息方法，用于输出报告。

```cpp
    Error start(Arguments& args);
    void stop();

    static void trapHandler(int signo, siginfo_t* siginfo, void* ucontext);
};
```
**解析**：
- `start()`：启动采样（安装断点）
- `stop()`：停止采样（卸载断点）
- `trapHandler()`：信号处理函数（当断点触发时调用）

---

## 5. allocTracer.cpp - AllocTracer 实现（逐行解析）

### 5.1 静态成员初始化

```cpp
// 文件: allocTracer.cpp 第 13-18 行

int AllocTracer::_trap_kind;
Trap AllocTracer::_in_new_tlab(0);
Trap AllocTracer::_outside_tlab(1);

u64 AllocTracer::_interval;
volatile u64 AllocTracer::_allocated_bytes;
```
**解析**：
- `_trap_kind` 未初始化，默认为 0
- `_in_new_tlab` 构造时传入 ID=0
- `_outside_tlab` 构造时传入 ID=1
- `_interval` 和 `_allocated_bytes` 由 `start()` 初始化

### 5.2 initialize

```cpp
Error AllocTracer::initialize() {
    if (_in_new_tlab.entry() == 0 || _outside_tlab.entry() == 0) {
```
**解析**：检查断点是否已初始化。`entry()` 返回 `_entry`，初始值为 0。

```cpp
        CodeCache* libjvm = VMStructs::libjvm();
        const void* ne;
        const void* oe;
```
**解析**：
- `VMStructs::libjvm()` 返回 `libjvm.so` 的代码缓存对象
- `ne`：`send_allocation_in_new_tlab` 符号地址
- `oe`：`send_allocation_outside_tlab` 符号地址

```cpp
        if ((ne = libjvm->findSymbolByPrefix("_ZN11AllocTracer27send_allocation_in_new_tlab")) != NULL &&
            (oe = libjvm->findSymbolByPrefix("_ZN11AllocTracer28send_allocation_outside_tlab")) != NULL) {
            _trap_kind = 1;  // JDK 10+
        }
```
**解析**：**JDK 10+ 符号查找**。

**C++ 名称修饰（Name Mangling）解析**：
- `_ZN11AllocTracer27send_allocation_in_new_tlab` 解码为：
  - `_ZN`：开始
  - `11AllocTracer`：类名长度 11，内容 "AllocTracer"
  - `27send_allocation_in_new_tlab`：方法名长度 27
  - 结束（没有 `E`，因为参数被省略了）

**`findSymbolByPrefix` 的作用**：
- 不需要完整符号名（参数类型可能不同）
- 只需要前缀匹配即可

```cpp
        else if ((ne = libjvm->findSymbolByPrefix("_ZN11AllocTracer33send_allocation_in_new_tlab_eventE11KlassHandleP8HeapWord")) != NULL &&
                   (oe = libjvm->findSymbolByPrefix("_ZN11AllocTracer34send_allocation_outside_tlab_eventE11KlassHandleP8HeapWord")) != NULL) {
            _trap_kind = 1;  // JDK 8u262+
        }
```
**解析**：**JDK 8u262+ 符号查找**。函数名变了（增加了 `_event` 后缀），参数也变了。

```cpp
        else if ((ne = libjvm->findSymbolByPrefix("_ZN11AllocTracer33send_allocation_in_new_tlab_event")) != NULL &&
                   (oe = libjvm->findSymbolByPrefix("_ZN11AllocTracer34send_allocation_outside_tlab_event")) != NULL) {
            _trap_kind = 2;  // JDK 7-9
        }
```
**解析**：**JDK 7-9 符号查找**。`_trap_kind = 2` 表示参数布局不同。

```cpp
        else {
            return Error("No AllocTracer symbols found. Are JDK debug symbols installed?");
        }
```
**解析**：如果所有符号都找不到，返回错误。通常是因为 JVM 没有调试符号。

```cpp
        _in_new_tlab.assign(ne);
        _outside_tlab.assign(oe);
        _in_new_tlab.pair(_outside_tlab);
    }

    return Error::OK;
}
```
**解析**：
1. `assign(ne)`：设置断点地址，保存原始指令
2. `pair()`：如果两个断点在同一页，优化内存保护

### 5.3 trapHandler（核心）

```cpp
// 文件: allocTracer.cpp 第 49-81 行

void AllocTracer::trapHandler(int signo, siginfo_t* siginfo, void* ucontext) {
```
**解析**：信号处理函数。当 `INT3` 断点触发时，操作系统调用此函数。

**参数**：
- `signo`：信号编号（`SIGTRAP = 5`）
- `siginfo`：信号信息（包含触发原因等）
- `ucontext`：用户上下文（包含寄存器状态）

```cpp
    StackFrame frame(ucontext);
```
**解析**：构造 `StackFrame` 对象，封装 `ucontext`。

```cpp
    EventType event_type;
    uintptr_t total_size;
    uintptr_t instance_size;
```
**解析**：声明局部变量，稍后填充。

```cpp
    if (_in_new_tlab.covers(frame.pc())) {
```
**解析**：检查 PC 是否在 `_in_new_tlab` 断点范围内。

```cpp
        // send_allocation_in_new_tlab(Klass* klass, HeapWord* obj, size_t tlab_size, size_t alloc_size, Thread* thread)
        // send_allocation_in_new_tlab_event(KlassHandle klass, size_t tlab_size, size_t alloc_size)
        event_type = ALLOC_SAMPLE;
        total_size = _trap_kind == 1 ? frame.arg2() : frame.arg1();
        instance_size = _trap_kind == 1 ? frame.arg3() : frame.arg2();
```
**解析**：**参数读取**！

**JDK 10+ (`_trap_kind = 1`)**：
- `arg0()` = RDI = `Klass* klass`
- `arg1()` = RSI = `HeapWord* obj`
- `arg2()` = RDX = `size_t tlab_size`（总大小）
- `arg3()` = RCX = `size_t alloc_size`（实例大小）
- `arg4()` = R8 = `Thread* thread`

**JDK 7-9 (`_trap_kind = 2`)**：
- `arg0()` = `KlassHandle klass`
- `arg1()` = `size_t tlab_size`
- `arg2()` = `size_t alloc_size`

```cpp
    } else if (_outside_tlab.covers(frame.pc())) {
        event_type = ALLOC_OUTSIDE_TLAB;
        total_size = _trap_kind == 1 ? frame.arg2() : frame.arg1();
        instance_size = 0;
    }
```
**解析**：TLAB 外分配只报告总大小，实例大小为 0。

```cpp
    else {
        // Not our trap
        Profiler::instance()->trapHandler(signo, siginfo, ucontext);
        return;
    }
```
**解析**：如果 PC 不在任何已知断点范围内，转发给父类处理。可能是其他类型的断点。

```cpp
    // Leave the trapped function by simulating "ret" instruction
    uintptr_t klass = frame.arg0();
    frame.ret();
```
**解析**：**关键操作**！
1. 读取 `Klass*` 参数
2. 调用 `frame.ret()` 模拟返回指令

**为什么顺序是先读取参数再 ret？**
- `ret()` 会修改 SP（`sp += 8`）
- 但不影响寄存器，所以参数仍然可读

```cpp
    if (_enabled && updateCounter(_allocated_bytes, total_size, _interval)) {
        recordAllocation(ucontext, event_type, klass, total_size, instance_size);
    }
}
```
**解析**：
1. `_enabled`：全局开关（由 `enableEvents()` 控制）
2. `updateCounter()`：判断是否达到采样间隔
3. 如果需要采样，调用 `recordAllocation()`

### 5.4 recordAllocation

```cpp
void AllocTracer::recordAllocation(void* ucontext, EventType event_type, uintptr_t rklass,
                                   uintptr_t total_size, uintptr_t instance_size) {
    AllocEvent event;
    event._start_time = TSC::ticks();
    event._class_id = 0;
    event._total_size = total_size;
    event._instance_size = instance_size;
```
**解析**：构造 `AllocEvent` 结构体，填充基本信息。

**`TSC::ticks()`**：读取 CPU 时间戳计数器（RDTSC 指令），高精度计时。

```cpp
    if (VMStructs::hasClassNames()) {
        VMSymbol* symbol = VMKlass::fromHandle(rklass)->name();
        event._class_id = Profiler::instance()->classMap()->lookup(symbol->body(), symbol->length());
    }
```
**解析**：**类名解析**！

**步骤分解**：
1. `VMStructs::hasClassNames()`：检查是否支持类名解析（需要 VMStructs）
2. `VMKlass::fromHandle(rklass)`：将 `Klass*` 转换为 `VMKlass` 对象
3. `->name()`：获取 `Symbol*`（JVM 内部字符串表示）
4. `symbol->body()`：获取字符数组指针
5. `symbol->length()`：获取字符串长度
6. `classMap()->lookup()`：将类名加入映射表，返回 ID

```cpp
    Profiler::instance()->recordSample(ucontext, total_size, event_type, &event);
}
```
**解析**：调用 `Profiler::recordSample()` 记录采样事件。

### 5.5 start

```cpp
Error AllocTracer::start(Arguments& args) {
    if (args._live && !args._all) {
        return Error("'live' option is supported on OpenJDK 11+");
    }
```
**解析**：检查参数兼容性。`--live` 选项需要 JDK 11+。

```cpp
    Error error = initialize();
    if (error) return error;
```
**解析**：初始化断点。

```cpp
    _interval = args._alloc > 0 ? args._alloc : 0;
    _allocated_bytes = 0;
```
**解析**：
- 设置采样间隔（`args._alloc` 是命令行参数 `--alloc`）
- 重置计数器

```cpp
    if (!_in_new_tlab.install() || !_outside_tlab.install()) {
        return Error("Cannot install allocation breakpoints");
    }

    return Error::OK;
}
```
**解析**：**安装断点**！

调用 `Trap::install()`，实际执行：
1. `mprotect(PROT_READ | PROT_WRITE | PROT_EXEC)`
2. 写入 `0xCC`（INT3）
3. `flushCache()`
4. `mprotect(PROT_READ | PROT_EXEC)`

### 5.6 stop

```cpp
void AllocTracer::stop() {
    _in_new_tlab.uninstall();
    _outside_tlab.uninstall();
}
```
**解析**：卸载断点，恢复原始指令。

---

## 6. stackFrame_x64.cpp - StackFrame 实现（逐行解析）

### 6.1 REG 宏定义

```cpp
// 文件: stackFrame_x64.cpp 第 15-19 行

#ifdef __APPLE__
#  define REG(l, m)  _ucontext->uc_mcontext->__ss.__##m
#else
#  define REG(l, m)  _ucontext->uc_mcontext.gregs[REG_##l]
#endif
```
**解析**：寄存器访问宏。

**参数**：
- `l`：Linux 使用的寄存器常量名（如 `RDI`）
- `m`：macOS 使用的寄存器成员名（如 `rdi`）

**示例**：
```cpp
REG(RDI, rdi)
// Linux 展开为: _ucontext->uc_mcontext.gregs[REG_RDI]
// macOS 展开为: _ucontext->uc_mcontext->__ss.__rdi
```

**为什么需要两个参数？**
- Linux 的 `ucontext` 使用 `gregs` 数组 + 常量索引
- macOS 的 `ucontext` 使用结构体成员

### 6.2 寄存器访问方法

```cpp
uintptr_t& StackFrame::pc() {
    return (uintptr_t&)REG(RIP, rip);
}
```
**解析**：返回 PC（Program Counter / Instruction Pointer）的引用。

**x86_64 寄存器**：`RIP` = Instruction Pointer

```cpp
uintptr_t& StackFrame::sp() {
    return (uintptr_t&)REG(RSP, rsp);
}
```
**解析**：返回 SP（Stack Pointer）的引用。

**x86_64 寄存器**：`RSP` = Stack Pointer

```cpp
uintptr_t& StackFrame::fp() {
    return (uintptr_t&)REG(RBP, rbp);
}
```
**解析**：返回 FP（Frame Pointer）的引用。

**x86_64 寄存器**：`RBP` = Base Pointer

```cpp
uintptr_t StackFrame::link() {
    // No link register on x86
    return 0;
}
```
**解析**：x86 没有链接寄存器（Link Register）。ARM/aarch64 有 LR（X30），x86 使用栈存储返回地址。

```cpp
uintptr_t StackFrame::arg0() {
    return (uintptr_t)REG(RDI, rdi);
}

uintptr_t StackFrame::arg1() {
    return (uintptr_t)REG(RSI, rsi);
}

uintptr_t StackFrame::arg2() {
    return (uintptr_t)REG(RDX, rdx);
}

uintptr_t StackFrame::arg3() {
    return (uintptr_t)REG(RCX, rcx);
}
```
**解析**：**参数读取**！

**x86_64 SysV ABI 调用约定**：
- 第 1 个参数：RDI
- 第 2 个参数：RSI
- 第 3 个参数：RDX
- 第 4 个参数：RCX
- 第 5 个参数：R8
- 第 6 个参数：R9
- 更多参数：通过栈传递

**示例**：
```cpp
// 函数调用：foo(a, b, c, d, e, f)
// 编译后：
//   mov rdi, a
//   mov rsi, b
//   mov rdx, c
//   mov rcx, d
//   mov r8, e
//   mov r9, f
//   call foo
```

### 6.3 ret 方法

```cpp
void StackFrame::ret() {
    pc() = stackAt(0);
    sp() += 8;
}
```
**解析**：**模拟返回指令**！

**步骤**：
1. `stackAt(0)` = `((uintptr_t*)sp())[0]`：读取栈顶的返回地址
2. `pc() = ...`：设置 PC 为返回地址
3. `sp() += 8`：弹出返回地址（x86_64 指针是 8 字节）

**等价于 x86_64 汇编**：
```asm
pop rip    # 但实际上 x86 不支持这个指令
# 实际等价于：
mov rip, [rsp]
add rsp, 8
```

**栈布局**：
```
              +-------------------+
              | 返回地址           |  <- SP 指向这里 (stackAt(0))
              +-------------------+
              | 保存的 RBP         |  <- stackAt(1)
              +-------------------+
              | 第一个局部变量     |  <- stackAt(2)
              +-------------------+

ret() 执行后:
              +-------------------+
              | 返回地址 (已弹出)  |
              +-------------------+
              | 保存的 RBP         |  <- SP 现在指向这里
              +-------------------+
```

---

## 7. engine.h - updateCounter 实现（逐行解析）

```cpp
// 文件: engine.h 第 16-34 行

static bool updateCounter(volatile unsigned long long& counter, unsigned long long value, unsigned long long interval) {
    if (interval <= 1) {
        return true;
    }
```
**解析**：
- `counter`：累计计数器（引用）
- `value`：本次增加的值
- `interval`：采样间隔

如果 `interval <= 1`，表示每次都采样（无条件采样）。

```cpp
    while (true) {
        unsigned long long prev = counter;
        unsigned long long next = prev + value;
```
**解析**：
1. 读取当前计数器值
2. 计算新值（累加）

```cpp
        if (next < interval) {
            if (__sync_bool_compare_and_swap(&counter, prev, next)) {
                return false;
            }
        }
```
**解析**：如果新值小于间隔，尝试 CAS 更新。

**`__sync_bool_compare_and_swap`**：
- 原子操作：如果 `counter == prev`，则 `counter = next`，返回 `true`
- 如果失败（其他线程修改了 counter），返回 `false`

**返回 `false` 表示**：未达到采样间隔，不采样。

```cpp
        else {
            if (__sync_bool_compare_and_swap(&counter, prev, next % interval)) {
                return true;
            }
        }
    }
}
```
**解析**：如果新值达到或超过间隔，尝试 CAS 更新，返回 `true`（采样）。

**为什么要 `next % interval`？**
- 避免计数器无限增长
- 保留余数，下次继续累计

**示例**：
```
interval = 1000
prev = 950
value = 100
next = 1050

next >= interval，所以：
counter = 1050 % 1000 = 50
return true（采样）
```

**多线程安全**：
- 使用 CAS（Compare-And-Swap）保证原子性
- 如果多个线程同时调用，只有一个会成功更新
- 失败的线程会重试（while 循环）

---

## 8. 完整执行流程

### 8.1 启动阶段

```
用户命令: ./profiler.sh -d 60 -e alloc --alloc 1m -f alloc.html <pid>

1. Agent_OnLoad() 加载 libasyncProfiler.so
2. 解析参数，选择 AllocTracer 引擎
3. AllocTracer::start()
   ├─ initialize()
   │  ├─ 查找 send_allocation_in_new_tlab 符号
   │  ├─ 查找 send_allocation_outside_tlab 符号
   │  ├─ _in_new_tlab.assign(ne)    // 保存原始指令
   │  ├─ _outside_tlab.assign(oe)   // 保存原始指令
   │  └─ _in_new_tlab.pair(_outside_tlab)  // 优化内存保护
   └─ install()
      ├─ mprotect(PROT_READ | PROT_WRITE | PROT_EXEC)
      ├─ 写入 0xCC (INT3)
      ├─ flushCache()
      └─ mprotect(PROT_READ | PROT_EXEC)
```

### 8.2 运行阶段

```
Java 代码: new byte[1024]

1. JVM 分配内存（TLAB 或直接堆）
2. 调用 send_allocation_in_new_tlab(klass, obj, tlab_size, alloc_size, thread)
3. 执行到函数入口的 INT3 (0xCC)
4. CPU 触发 SIGTRAP 信号
5. 操作系统调用 trapHandler(signo, siginfo, ucontext)
   ├─ StackFrame frame(ucontext)  // 封装上下文
   ├─ _in_new_tlab.covers(frame.pc())  // 判断断点类型
   ├─ total_size = frame.arg2()  // 读取 RDX
   ├─ instance_size = frame.arg3()  // 读取 RCX
   ├─ klass = frame.arg0()  // 读取 RDI
   ├─ frame.ret()  // 模拟返回
   ├─ updateCounter(_allocated_bytes, total_size, _interval)  // 判断是否采样
   └─ recordAllocation()  // 记录事件
      ├─ 获取类名（通过 VMStructs）
      └─ Profiler::recordSample()  // 写入 Ring Buffer
6. 继续执行 Java 代码（函数被"跳过"）
```

### 8.3 停止阶段

```
用户命令: ./profiler.sh stop <pid>

1. Agent 接收停止命令
2. AllocTracer::stop()
   ├─ _in_new_tlab.uninstall()    // 恢复原始指令
   └─ _outside_tlab.uninstall()   // 恢复原始指令
3. 生成火焰图
```

---

## 9. 关键技术点总结

| 技术点 | 源码位置 | 说明 |
|--------|---------|------|
| INT3 断点 | `arch.h:54` | `BREAKPOINT = 0xCC` |
| 符号查找 | `allocTracer.cpp:27-35` | `findSymbolByPrefix` 查找 JVM 函数 |
| 参数读取 | `stackFrame_x64.cpp:43-57` | 从 RDI/RSI/RDX/RCX 读取 |
| 模拟返回 | `stackFrame_x64.cpp:71-74` | `pc = [sp], sp += 8` |
| 采样间隔 | `engine.h:16-34` | CAS 原子计数器 |
| 类名解析 | `allocTracer.cpp:91-93` | 通过 VMStructs 读取 `Symbol*` |

---

## 10. GDB 验证对照表

| GDB 验证命令 | 验证内容 | 源码对应 |
|-------------|---------|---------|
| `x/1bx 0x...` | 查看断点指令 | `patch(_breakpoint_insn)` |
| `info registers rdi rsi rdx` | 查看参数 | `frame.arg0/1/2()` |
| `p/x $rsp` | 查看栈指针 | `StackFrame::sp()` |
| `x/1gx $rsp` | 查看返回地址 | `stackAt(0)` in `ret()` |
| `disassemble send_allocation_in_new_tlab` | 查看函数入口 | `assign()` 保存原始指令 |

---

## 11. 参考资料

- `man 2 sigaction`：信号处理
- `man 2 mprotect`：内存保护
- `man 2 ptrace`：进程跟踪
- [System V AMD64 ABI](https://gitlab.com/x86-psABIs/x86-64-ABI)：调用约定
- [Intel SDM](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html)：指令集参考
