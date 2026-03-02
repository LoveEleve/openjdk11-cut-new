# AsyncProfiler 源码学习：Lesson 5 - AllocTracer（验证驱动）

> **学习方式**：验证驱动学习（Verification-Driven Learning）
> **核心理念**：先验证，后讲解。从验证结果理解源码。

---

## 验证问题清单

1. **AllocTracer 如何 hook JVM 分配函数？**
2. **断点陷阱机制如何工作？**
3. **如何从寄存器读取分配大小？**
4. **如何获取分配对象的类名？**

---

## 验证 1：AllocTracer 如何找到 JVM 分配函数？

### 问题

AllocTracer 需要 hook JVM 的分配函数，如何找到这些函数的地址？

### 验证脚本

```bash
# 查找 JVM 中的 AllocTracer 符号
nm -C /data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/lib/server/libjvm.so | grep -i "AllocTracer.*send_allocation"
```

### 验证结果

**预期输出**（JDK 11+）：
```
0000000001a3b4a0 T AllocTracer::send_allocation_in_new_tlab(Klass*, HeapWord*, unsigned long, unsigned long, Thread*)
0000000001a3b5c0 T AllocTracer::send_allocation_outside_tlab(Klass*, HeapWord*, unsigned long, Thread*)
```

**实际输出**（需要运行验证）：
```bash
# 运行验证脚本
```

### 从结果理解源码

**源码位置**：`allocTracer.cpp:27-38`

```cpp
if ((ne = libjvm->findSymbolByPrefix("_ZN11AllocTracer27send_allocation_in_new_tlab")) != NULL &&
    (oe = libjvm->findSymbolByPrefix("_ZN11AllocTracer28send_allocation_outside_tlab")) != NULL) {
    _trap_kind = 1;  // JDK 10+
}
```

**解释**：

1. **符号名称**：
   - `_ZN11AllocTracer27send_allocation_in_new_tlab`：C++ mangled 名称
   - `AllocTracer::send_allocation_in_new_tlab`：demangled 名称

2. **为什么要用前缀查找？**
   - 不同 JDK 版本符号名不同
   - 参数类型可能不同（KlassHandle vs Klass*）

3. **_trap_kind 的含义**：
   - `1`：JDK 10+ 或 JDK 8u262+（参数是 Klass*）
   - `2`：JDK 7-9（参数是 KlassHandle）

---

## 验证 2：断点陷阱如何工作？

### 问题

AllocTracer 使用断点陷阱（breakpoint trap）hook 函数，如何实现？

### 验证脚本

**GDB 脚本**：`verify_trap.gdb`

```gdb
# 验证断点陷阱机制
set pagination off

# 在 Trap::install 设置断点
break Trap::install
commands
  printf "\n===== Trap::install 被调用 =====\n"
  printf "  目标地址 = %p\n", $rdi
  printf "  当前指令 = %x\n", *(unsigned char*)$rdi
  continue
end

# 在 AllocTracer::trapHandler 设置断点
break AllocTracer::trapHandler
commands
  printf "\n===== AllocTracer::trapHandler 被调用 =====\n"
  printf "  信号 = %d\n", $rdi
  printf "  PC = %p\n", ((ucontext_t*)$rdx)->uc_mcontext.gregs[REG_RIP]
  continue
end

run -agentpath:/data/workspace/async-profiler/build/lib/libasyncProfiler.so=start,event=alloc,alloc=1k \
    -Xms1g -Xmx1g -XX:+UseG1GC \
    -cp /data/workspace/demo/src com.wjcoder.ProfilerTest
```

### 验证结果

**预期流程**：

```
启动 → Trap::install → 设置断点（INT3）
  ↓
对象分配 → 触发断点 → SIGTRAP 信号
  ↓
AllocTracer::trapHandler → 读取参数 → 记录分配
  ↓
模拟 ret → 返回调用者
```

**实际输出**（需要运行验证）：
```
===== Trap::install 被调用 =====
  目标地址 = 0x7ffff1234567
  当前指令 = 55  # push rbp

===== AllocTracer::trapHandler 被调用 =====
  信号 = 5  # SIGTRAP
  PC = 0x7ffff1234567
```

### 从结果理解源码

**源码位置**：`trap.cpp`（假设）

```cpp
bool Trap::install() {
    // 1. 保存原始指令
    _saved_insn = *(u8*)_entry;

    // 2. 写入 INT3 指令（0xCC）
    *(u8*)_entry = 0xCC;

    return true;
}
```

**解释**：

1. **INT3 指令**：
   - 操作码：`0xCC`
   - 触发 SIGTRAP 信号
   - 用于调试器断点

2. **陷阱处理流程**：
   ```
   执行 INT3 → 触发 SIGTRAP
     ↓
   信号处理函数 → AllocTracer::trapHandler
     ↓
   读取参数（从寄存器）
     ↓
   模拟 ret → 跳过原函数
   ```

3. **为什么用断点而不是 hook？**
   - 不需要修改代码
   - 不影响性能
   - 可以获取原始参数

---

## 验证 3：如何从寄存器读取分配大小？

### 问题

当断点触发时，如何从寄存器读取分配大小？

### 验证脚本

**C++ 程序**：`verify_read_args.cpp`

```cpp
#include <stdio.h>
#include <signal.h>
#include <ucontext.h>

// 模拟 send_allocation_in_new_tlab 的参数传递
void test_allocation(size_t tlab_size, size_t alloc_size) {
    printf("tlab_size = %lu\n", tlab_size);
    printf("alloc_size = %lu\n", alloc_size);
}

void handler(int sig, siginfo_t* info, void* ucontext) {
    ucontext_t* ctx = (ucontext_t*)ucontext;

    printf("\n=== 信号处理函数 ===\n");
    printf("  PC = %p\n", (void*)ctx->uc_mcontext.gregs[REG_RIP]);

    // 从寄存器读取参数（x86_64 calling convention）
    // arg0 = rdi, arg1 = rsi, arg2 = rdx, arg3 = rcx
    printf("  arg0 (rdi) = %lu\n", ctx->uc_mcontext.gregs[REG_RDI]);
    printf("  arg1 (rsi) = %lu\n", ctx->uc_mcontext.gregs[REG_RSI]);
    printf("  arg2 (rdx) = %lu\n", ctx->uc_mcontext.gregs[REG_RDX]);
    printf("  arg3 (rcx) = %lu\n", ctx->uc_mcontext.gregs[REG_RCX]);
}

int main() {
    struct sigaction sa;
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGTRAP, &sa, NULL);

    // 触发断点
    printf("调用 test_allocation(1024, 512)\n");
    asm volatile("int3");
    test_allocation(1024, 512);

    return 0;
}
```

### 验证结果

**预期输出**：
```
调用 test_allocation(1024, 512)

=== 信号处理函数 ===
  PC = 0x...
  arg0 (rdi) = 1024
  arg1 (rsi) = 512
  arg2 (rdx) = ...
  arg3 (rcx) = ...
```

**实际输出**（需要运行验证）：
```bash
# 编译运行
g++ -o verify_read_args verify_read_args.cpp
./verify_read_args
```

### 从结果理解源码

**源码位置**：`allocTracer.cpp:56-67`

```cpp
if (_in_new_tlab.covers(frame.pc())) {
    // send_allocation_in_new_tlab(Klass* klass, HeapWord* obj, size_t tlab_size, size_t alloc_size, Thread* thread)
    event_type = ALLOC_SAMPLE;
    total_size = _trap_kind == 1 ? frame.arg2() : frame.arg1();
    instance_size = _trap_kind == 1 ? frame.arg3() : frame.arg2();
}
```

**解释**：

1. **x86_64 调用约定**：
   ```
   arg0 = rdi
   arg1 = rsi
   arg2 = rdx
   arg3 = rcx
   arg4 = r8
   arg5 = r9
   ```

2. **JDK 10+ 参数**：
   ```cpp
   send_allocation_in_new_tlab(
       Klass* klass,      // arg0 (rdi)
       HeapWord* obj,     // arg1 (rsi)
       size_t tlab_size,  // arg2 (rdx)  ← total_size
       size_t alloc_size, // arg3 (rcx)  ← instance_size
       Thread* thread     // arg4 (r8)
   )
   ```

3. **读取逻辑**：
   ```cpp
   total_size = frame.arg2();     // rdx → tlab_size
   instance_size = frame.arg3();  // rcx → alloc_size
   ```

---

## 验证 4：如何获取分配对象的类名？

### 问题

从 Klass* 指针如何获取类名？

### 验证脚本

**GDB 脚本**：`verify_klass_name.gdb`

```gdb
# 验证从 Klass 读取类名
set pagination off

break AllocTracer::recordAllocation
commands
  printf "\n===== recordAllocation 被调用 =====\n"
  printf "  rklass = %p\n", $rdi
  printf "  total_size = %lu\n", $rsi
  printf "  instance_size = %lu\n", $rdx

  # 尝试读取类名
  set $klass = (void*)$rdi
  printf "  尝试读取类名...\n"

  continue
end

run -agentpath:/data/workspace/async-profiler/build/lib/libasyncProfiler.so=start,event=alloc,alloc=1k \
    -Xms1g -Xmx1g -XX:+UseG1GC \
    -cp /data/workspace/demo/src com.wjcoder.ProfilerTest
```

### 验证结果

**预期输出**：
```
===== recordAllocation 被调用 =====
  rklass = 0x7ffff0012340
  total_size = 1024
  instance_size = 16
  尝试读取类名...
  类名 = java/lang/Object
```

**实际输出**（需要运行验证）：
```bash
# 运行 GDB 脚本
gdb -batch -x verify_klass_name.gdb ...
```

### 从结果理解源码

**源码位置**：`allocTracer.cpp:91-94`

```cpp
if (VMStructs::hasClassNames()) {
    VMSymbol* symbol = VMKlass::fromHandle(rklass)->name();
    event._class_id = Profiler::instance()->classMap()->lookup(symbol->body(), symbol->length());
}
```

**解释**：

1. **Klass 结构**：
   ```cpp
   class Klass {
       Symbol* _name;  // 类名符号
       // ...
   };
   ```

2. **读取步骤**：
   ```
   Klass* → _name → Symbol*
     ↓
   Symbol::body() → 字符数组
     ↓
   classMap->lookup() → class_id
   ```

3. **为什么要用 class_id？**
   - 压缩存储（4 字节 vs 字符串）
   - 快速比较
   - 支持去重

---

## 总结：AllocTracer 完整工作流程

### 核心流程图

```
┌─────────────────────────────────────────────────────────────┐
│                AllocTracer 工作流程                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. 初始化阶段                                               │
│     ├─ findSymbolByPrefix() 查找 JVM 符号                  │
│     ├─ 保存函数地址到 _in_new_tlab/_outside_tlab           │
│     └─ 确定 _trap_kind（JDK 版本）                          │
│                                                             │
│  2. 启动阶段                                                 │
│     ├─ 设置采样间隔 _interval                                │
│     ├─ _in_new_tlab.install() → 写入 INT3                  │
│     └─ _outside_tlab.install() → 写入 INT3                 │
│                                                             │
│  3. 运行阶段（每次对象分配）                                 │
│     ├─ JVM 调用 send_allocation_in_new_tlab()              │
│     ├─ 执行 INT3 → 触发 SIGTRAP                             │
│     ├─ AllocTracer::trapHandler()                          │
│     │   ├─ 判断是哪个函数（in_new_tlab/outside_tlab）      │
│     │   ├─ 从寄存器读取参数（klass、size）                  │
│     │   ├─ 模拟 ret 指令返回                                │
│     │   └─ recordAllocation()                               │
│     │       ├─ 从 Klass* 读取类名                           │
│     │       ├─ 查找或创建 class_id                          │
│     │       └─ Profiler::recordSample()                     │
│     └─ 返回调用者                                           │
│                                                             │
│  4. 停止阶段                                                 │
│     ├─ _in_new_tlab.uninstall() → 恢复原指令               │
│     └─ _outside_tlab.uninstall() → 恢复原指令              │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 源码理解深度分析

### 关键技术点

1. **断点陷阱机制**：
   - 使用 INT3 指令（0xCC）
   - 不修改代码逻辑
   - 可以获取原始参数

2. **符号查找**：
   - 兼容不同 JDK 版本
   - 使用前缀匹配
   - 支持 C++ name mangling

3. **寄存器读取**：
   - 遵循 x86_64 calling convention
   - 从 rdi/rsi/rdx/rcx 读取参数
   - 支持 JVM 不同版本的参数布局

4. **类名查找**：
   - 通过 VMKlass 访问 Klass 结构
   - 使用 VMStructs 偏移推断
   - 支持 Symbol 压缩存储

---

## 验证文件清单

```
jvm-md/tmp-file/lesson05/
├── verify_alloc_tracer.log         ⬜ 待创建
├── verify_trap.gdb                 ⬜ 待创建
├── verify_read_args.cpp            ⬜ 待创建
├── verify_klass_name.gdb           ⬜ 待创建
└── verification_results.md         ⬜ 待创建
```

---

## 下一步验证计划

- [ ] **运行验证脚本**：验证 4 个关键问题
- [ ] **记录验证结果**：补充验证结果到文档
- [ ] **深入源码细节**：理解 Trap 类的实现

---

**文档版本**：v1.0（验证驱动版）
**最后更新**：2026-02-12
**学习程度**：70%（源码已理解，验证待完成）
