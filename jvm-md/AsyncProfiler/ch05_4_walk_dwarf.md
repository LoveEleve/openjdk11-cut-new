# 5.4 walkDwarf — DWARF CFI 栈回溯

> 源文件: `stackWalker.cpp` (513行), `dwarf.cpp` (358行), `dwarf.h` (174行), `codeCache.cpp::findFrameDesc`
> 关联: `stackWalker.cpp::walkFP` (5.3), `stackWalker.cpp::walkVM` (5.5)
> 前置章节: 5.1 recordSample, 5.3 walkFP

## 核心问题

**当 `-fomit-frame-pointer` 编译的代码没有 FP 链时，如何进行栈回溯？**

答案：使用 ELF `.eh_frame` 段中的 **DWARF Call Frame Information (CFI)**。每个函数的每个 PC 地址都有一条 CFI 规则，精确描述了"在这个 PC 处，如何从当前帧的寄存器值计算出调用者的 SP/FP/PC"。walkDwarf 在启动时一次性解析所有 `.eh_frame` 段为 FrameDesc 查找表，运行时通过二分查找快速定位 CFI 规则。

---

## 一、为什么需要 DWARF？walkFP 有什么不足？

### 1.1 FP 链的脆弱性

walkFP 依赖一个前提：**每个函数都在 prologue 中保存 RBP 到栈上，并用 RBP 指向当前栈帧**。但在 release 构建中，`-O2 -fomit-frame-pointer` 会让编译器把 RBP 当通用寄存器使用，FP 链就断了：

```
debug 构建: push rbp; mov rbp, rsp   → FP 链完整，walkFP 正确
release 构建: （不 push rbp）           → FP 链断裂，walkFP 在第 1~3 帧就停了
```

### 1.2 实际影响

| 库 | 编译选项 | FP 链 | walkFP 表现 |
|----|---------|-------|------------|
| libjvm.so (debug) | `-O0 -g` | ✅ 完整 | 正常回溯 |
| libjvm.so (release) | `-O2 -fomit-frame-pointer` | ❌ 断裂 | 1~3 帧后断 |
| libc.so | `-O2` | ❌ 断裂 | 无法穿越 |
| libstdc++.so | `-O2` | ❌ 断裂 | 无法穿越 |

### 1.3 DWARF 的优势

DWARF CFI **不依赖 FP 链**——它用一张编译器生成的规则表，记录每个 PC 地址处栈帧的恢复规则。无论函数是否保留 FP，DWARF 都能正确回溯。

---

## 二、DWARF CFI 的结构层次

### 2.1 从 ELF 到 FrameDesc 的数据流

```
ELF .eh_frame_hdr 段
  │
  ├── 头部 (4 字节): version=1, 编码方式
  ├── eh_frame 指针
  ├── FDE 数量 (如 libjvm.so 有数万个 FDE)
  └── 查找表: [函数起始PC, FDE偏移] × N
        │
        ▼
  .eh_frame 段
  ├── CIE (Common Information Entry)
  │   ├── code_align_factor = 1 (x86_64)
  │   ├── data_align_factor = -8 (x86_64)
  │   └── return_address_register = 16 (RIP)
  │
  └── FDE (Frame Description Entry) × 数万
      ├── 函数地址范围: [start, start+len)
      └── CFI 指令序列:
          ├── DW_CFA_def_cfa RSP, 8      → 初始: CFA = RSP + 8
          ├── DW_CFA_advance_loc 1        → 到 push rbp 之后
          ├── DW_CFA_def_cfa_offset 16    → CFA = RSP + 16
          ├── DW_CFA_offset RBP, -16      → RBP 保存在 CFA-16
          ├── DW_CFA_advance_loc 3        → 到 mov rbp, rsp 之后
          └── DW_CFA_def_cfa_register RBP → CFA = RBP + 16
                │
                ▼
  DwarfParser 解析为 FrameDesc 数组
  ├── {loc=函数起始, cfa=RSP|8<<8, fp_off=DW_SAME_FP, pc_off=-8}
  ├── {loc=push后,  cfa=RSP|16<<8, fp_off=-16, pc_off=-8}
  └── {loc=mov后,   cfa=RBP|16<<8, fp_off=-16, pc_off=-8}
                │
                ▼
  CodeCache::findFrameDesc(PC)
  → 二分查找 → 返回 FrameDesc*
  → walkDwarf 用 FrameDesc 计算下一帧
```

### 2.2 GDB 验证 — readelf 与 FrameDesc 交叉对比

**readelf 输出**（libjvm.so 的一个典型 FDE）：

```
CIE: cf=1 df=-8 ra=16
FDE pc=0x30764c..0x307675
  LOC           CFA      rbp   ra
  30764c        rsp+8    u     c-8      ← push rbp 前
  30764d        rsp+16   c-16  c-8      ← push rbp 后
  307650        rbp+16   c-16  c-8      ← mov rbp, rsp 后
  307674        rsp+8    c-16  c-8      ← leave 后(epilogue)
```

**async-profiler 对应的 FrameDesc**（GDB 验证）：

```
每一行 LOC 生成一个 FrameDesc：
  {loc=0x30764c, cfa=DW_REG_SP|8<<8,   fp_off=DW_SAME_FP, pc_off=-8}  → CFA=RSP+8
  {loc=0x30764d, cfa=DW_REG_SP|16<<8,  fp_off=-16, pc_off=-8}         → CFA=RSP+16
  {loc=0x307650, cfa=DW_REG_FP|16<<8,  fp_off=-16, pc_off=-8}         → CFA=RBP+16
  {loc=0x307674, cfa=DW_REG_SP|8<<8,   fp_off=-16, pc_off=-8}         → CFA=RSP+8
```

---

## 三、FrameDesc 的精巧编码

### 3.1 FrameDesc 结构（16 字节）

```cpp
struct FrameDesc {
    u32 loc;      // 函数内偏移（相对于 _text_base）
    int cfa;      // CFA 规则编码: cfa_reg | (cfa_off << 8)
    int fp_off;   // FP 恢复: 到 CFA 的偏移 / DW_SAME_FP / DW_PC_OFFSET 特殊标记
    int pc_off;   // PC 恢复: 到 CFA 的偏移 / DW_LINK_REGISTER
};
```

### 3.2 cfa 字段编码

```
cfa = cfa_reg | (cfa_off << 8)

低 8 位 (cfa_reg):
  7   = DW_REG_SP    → CFA = RSP + cfa_off
  6   = DW_REG_FP    → CFA = RBP + cfa_off
  128 = DW_REG_PLT   → PLT 特殊规则
  255 = DW_REG_INVALID → 不支持，停止回溯

高 24 位 (cfa_off):
  CFA 偏移量（有符号）
```

### GDB 验证

```
GDB 输出: f->cfa = 0x1006
  cfa_reg = 0x06 = DW_REG_FP (RBP)
  cfa_off = 0x10 = 16
  → CFA = RBP + 16  ✅
```

### 3.3 两个预定义 FrameDesc

```cpp
// empty_frame: 用于 PLT 条目 — 只有返回地址在栈顶，没有保存 FP
FrameDesc::empty_frame = {
    loc = 0,
    cfa = DW_REG_SP | (8 << 8),    // CFA = RSP + 8
    fp_off = DW_SAME_FP,            // FP 不变
    pc_off = -8                      // PC = *(CFA - 8) = *RSP
};

// default_frame: 用于 DWARF 表中找不到的地址 — 假设标准 FP-based 帧
FrameDesc::default_frame = {
    loc = 0,
    cfa = DW_REG_FP | (16 << 8),   // CFA = RBP + 16
    fp_off = -16,                    // FP = *(CFA - 16) = *RBP
    pc_off = -8                      // PC = *(CFA - 8) = *(RBP + 8)
};
```

**设计思想**：当 DWARF 表没有覆盖某个地址时（比如手写汇编、JIT 代码），fallback 到 `default_frame`——这和 walkFP 的逻辑一样，假设有 FP 链。

---

## 四、walkDwarf 核心循环详解

### 4.1 初始化（与 walkFP 相同）

```cpp
StackFrame frame(ucontext);
pc = (const void*)frame.pc();     // 信号中断时的 RIP
fp = frame.fp();                   // 信号中断时的 RBP
sp = frame.sp();                   // 信号中断时的 RSP
bottom = &sp + MAX_WALK_SIZE;      // 栈安全上界（1MB）
```

### 4.2 每一步回溯的 6 个阶段

```
while (depth < max_depth) {
    // ─── 阶段 1: CodeHeap 检测 ───
    if (CodeHeap::contains(pc)) {
        java_ctx->set(pc, sp, fp);   // 保存 Java 上下文
        break;                        // 停止原生栈回溯
    }
    callchain[depth++] = pc;          // 记录当前帧

    // ─── 阶段 2: 查找 FrameDesc ───
    CodeCache* cc = profiler->findLibraryByAddress(pc);      // PC → 哪个 .so?
    FrameDesc* f = cc ? cc->findFrameDesc(pc) : &default;    // PC → 哪条 CFI 规则?

    // ─── 阶段 3: 计算新 SP (CFA) ───
    u8 cfa_reg = (u8)f->cfa;
    int cfa_off = f->cfa >> 8;
    if (cfa_reg == DW_REG_SP) sp = sp + cfa_off;        // CFA = RSP + offset
    else if (cfa_reg == DW_REG_FP) sp = fp + cfa_off;   // CFA = RBP + offset
    else if (cfa_reg == DW_REG_PLT) { /* PLT 特殊 */ }
    else break;                                           // 不支持 → 停止

    // ─── 阶段 4: 安全检查 ───
    if (sp < prev_sp || sp >= prev_sp + MAX_FRAME_SIZE || sp >= bottom) break;
    if (!aligned(sp)) break;

    // ─── 阶段 5: 恢复 FP 和 PC ───
    if (f->fp_off != DW_SAME_FP) fp = *(uintptr_t*)(sp + f->fp_off);   // 从栈上恢复 FP
    pc = stripPointer(*(void**)(sp + f->pc_off));                        // 从栈上恢复返回地址

    // ─── 阶段 6: 终止检查 ───
    if (inDeadZone(pc) || (pc == prev_pc && sp == prev_sp)) break;
}
```

### 4.3 GDB 逐步验证

以第一次 walkDwarf 调用为例（12 步回溯）：

```
初始: pc=0x7ffff5ebfebb  fp=0x7ffff7808890  sp=0x7ffff7808868

Step 1 (depth=1): FrameDesc {cfa=0x1006, fp_off=-16, pc_off=-8}
  CFA = FP + 16 = 0x7ffff7808890 + 16 = 0x7ffff78088a0 (= new SP)
  new_FP = *(CFA - 16) = *0x7ffff7808890
  new_PC = *(CFA - 8)  = *0x7ffff7808898
  → sp从0x7ffff78084b0跳到0x7ffff78084e0 (+48 bytes)

Step 2 (depth=2): FrameDesc {cfa=0x1006, fp_off=-16, pc_off=-8}
  同样公式: CFA = FP + 16
  → sp从0x7ffff78084e0跳到0x7ffff7808510 (+48 bytes)

... 重复 ...

Step 12 (depth=12): sp=0x7ffff7808a50 → CFA 计算后 sp=0x7ffff7808bc0
  PC 指向 CodeHeap → java_ctx->set() → break
```

**关键观察**：所有 12 帧的 FrameDesc 都是 `cfa=0x1006`（CFA=RBP+16），因为 libjvm.so debug 构建保留了 FP。**但这不是 DWARF 的局限**——如果是 release 构建，每帧可能有不同的 `cfa_reg` 和 `cfa_off`。

---

## 五、DwarfParser — .eh_frame 解析器

### 5.1 解析流程

```
DwarfParser(name, image_base, eh_frame_hdr)
  │
  ├── 初始化: code_align=1, data_align=-8 (x86_64)
  │
  ├── parse(eh_frame_hdr)
  │   ├── 验证 header: version=1, 编码方式
  │   ├── 读取 fde_count
  │   └── for each FDE in 查找表:
  │       └── parseFde()
  │           ├── 第一个 FDE → parseCie() 先解析 CIE
  │           ├── 读取函数范围 [range_start, range_start + range_len)
  │           └── parseInstructions(range_start, fde_end)
  │               ├── 按 DW_CFA_advance_loc 推进 loc
  │               └── 每次 loc 变化时 addRecord()
  │
  └── 产出: _table[] 数组（排序过的 FrameDesc）
```

### 5.2 CFI 指令解析（核心状态机）

```cpp
u32 cfa_reg = DW_REG_SP;
int cfa_off = EMPTY_FRAME_SIZE;    // 初始: CFA = RSP + 8 (x86_64)
int fp_off = DW_SAME_FP;           // 初始: FP 不恢复
int pc_off = INITIAL_PC_OFFSET;    // 初始: PC = *(CFA - 8) = *RSP

while (ptr < end) {
    u8 op = *ptr++;
    switch (op >> 6) {             // 高 2 位决定操作类
        case 0: /* 标准操作 */
            switch (op) {
                case DW_CFA_def_cfa:         cfa_reg=getLeb(); cfa_off=getLeb(); break;
                case DW_CFA_def_cfa_register: cfa_reg=getLeb(); break;
                case DW_CFA_def_cfa_offset:   cfa_off=getLeb(); break;
                case DW_CFA_advance_loc1:    addRecord(loc,...); loc+=get8(); break;
                case DW_CFA_advance_loc2:    addRecord(loc,...); loc+=get16(); break;
                case DW_CFA_advance_loc4:    addRecord(loc,...); loc+=get32(); break;
                case DW_CFA_offset_extended:
                    switch(getLeb()) {
                        case DW_REG_FP: fp_off = getLeb() * data_align; break;
                        case DW_REG_PC: pc_off = getLeb() * data_align; break;
                    }
                    break;
                case DW_CFA_remember_state:  rem_xxx = xxx; break;
                case DW_CFA_restore_state:   xxx = rem_xxx; break;
            }
        case DW_CFA_advance_loc:   // 高 2 位=1, 低 6 位=delta
            addRecord(loc,...);
            loc += (op & 0x3f) * code_align;
            break;
        case DW_CFA_offset:        // 高 2 位=2, 低 6 位=寄存器号
            switch(op & 0x3f) {
                case DW_REG_FP: fp_off = getLeb() * data_align; break;
                case DW_REG_PC: pc_off = getLeb() * data_align; break;
            }
            break;
    }
}
```

**重要**：`addRecord()` 只在 `DW_CFA_advance_loc` 时调用——每次 PC 推进意味着"前面的 CFI 规则已经确定，保存下来"。

### 5.3 addRecord — 去重优化

```cpp
void DwarfParser::addRecord(u32 loc, u32 cfa_reg, int cfa_off, int fp_off, int pc_off) {
    int cfa = cfa_reg | cfa_off << 8;
    if (_prev == NULL ||
        (_prev->loc == loc && --_count >= 0) ||           // 同位置覆盖
        _prev->cfa != cfa || _prev->fp_off != fp_off ||  // 规则变化了
        _prev->pc_off != pc_off) {
        _prev = addRecordRaw(loc, cfa, fp_off, pc_off);
    }
    // 如果规则没变 → 跳过，不生成新条目
}
```

**优化效果**：如果连续的 PC 范围使用相同的 CFI 规则（很常见——一个函数体中间通常不改变帧结构），只生成一条 FrameDesc。

---

## 六、findFrameDesc — 二分查找

### 6.1 算法

```cpp
FrameDesc* CodeCache::findFrameDesc(const void* pc) {
    u32 target_loc = (const char*)pc - _text_base;   // 转为相对偏移
    int low = 0, high = _dwarf_table_length - 1;

    // 标准二分查找
    while (low <= high) {
        int mid = (unsigned int)(low + high) >> 1;
        if (_dwarf_table[mid].loc < target_loc)       low = mid + 1;
        else if (_dwarf_table[mid].loc > target_loc)  high = mid - 1;
        else return &_dwarf_table[mid];                // 精确匹配
    }

    if (low > 0) return &_dwarf_table[low - 1];       // 返回前一条（区间匹配）
    else if (target_loc - _plt_offset < _plt_size)     // PLT 区域
        return &FrameDesc::empty_frame;
    else return &FrameDesc::default_frame;              // 未知区域 → 假设标准帧
}
```

### 6.2 GDB 验证 — 性能数据

| 库 | DWARF 表条目数 | 二分查找最大步数 | 内存占用 |
|----|:-------------:|:---------------:|:-------:|
| **libjvm.so** (debug) | **508,048** | 19 | **7.8 MB** |
| libstdc++.so | 35,437 | 16 | 0.5 MB |
| libc.so | 29,265 | 15 | 0.4 MB |
| ld-linux.so | 2,539 | 12 | 0.04 MB |
| libjava.so | 1,568 | 11 | 0.02 MB |
| libgcc_s.so | 1,367 | 11 | 0.02 MB |
| libz.so | 1,170 | 11 | 0.02 MB |
| libnio.so | 741 | 10 | 0.01 MB |
| libnet.so | 721 | 10 | 0.01 MB |
| libjli.so | 609 | 10 | 0.01 MB |
| [vdso] | 31 | 5 | ~0 |
| java (binary) | 10 | 4 | ~0 |
| libdl.so | 7 | 3 | ~0 |
| **总计 22 个库** | **~580,000+** | — | **~9 MB** |

---

## 七、PLT 特殊处理 — DW_REG_PLT

### 7.1 问题

PLT (Procedure Linkage Table) 是动态链接的跳板代码。PLT 条目的栈帧大小不固定——取决于 `call` 指令执行到了 PLT stub 的哪一步：

```asm
PLT stub (16 字节):
  0: push [GOT+n]        ← 如果从这里中断，RSP 比入口低了 8
  6: jmp *[GOT+n]        ← 如果从这里中断，栈没变
  b: nop ... (padding)
```

### 7.2 解决方案

DWARF 用 `DW_CFA_def_cfa_expression` 生成一个条件规则。async-profiler 将其简化为 `DW_REG_PLT` 特殊标记：

```cpp
if (cfa_reg == DW_REG_PLT) {
    sp += ((uintptr_t)pc & 15) >= 11 ? cfa_off * 2 : cfa_off;
}
```

**编码含义**：
- PLT stub 对齐到 16 字节边界
- `pc & 15` = PC 在 stub 内的偏移
- 如果 `>= 11`（在 push 之后）：帧大小翻倍（多了一个 push 的 8 字节）
- 否则：正常帧大小

---

## 八、DW_PC_OFFSET — PC 相对偏移

### 8.1 问题

某些编译器优化（如尾调用优化 TCO）会在 `DW_CFA_val_expression` 中描述"上一帧的 PC = 当前 PC + offset"，而不是从栈上读取返回地址。

### 8.2 实现

```cpp
// DwarfParser::parseExpression 处理 DW_CFA_val_expression
int pc_off = parseExpression();
if (pc_off != 0) {
    fp_off = DW_PC_OFFSET | (pc_off << 1);  // 用 fp_off 字段存储 PC 偏移
}

// walkDwarf 中使用
if (f->fp_off & DW_PC_OFFSET) {
    pc = (const char*)pc + (f->fp_off >> 1);   // PC = 当前 PC + offset
} else {
    // 正常路径：从栈上读 FP 和 PC
}
```

**DW_PC_OFFSET = 1**：用 `fp_off` 的最低位作为标志——如果最低位为 1，说明这是一个 PC 偏移编码，不是 FP 恢复偏移。

---

## 九、walkDwarf vs walkFP — 深度对比

### 9.1 算法对比

| 维度 | walkFP | walkDwarf |
|------|--------|-----------|
| **寻址基础** | FP 链（`*FP` → 上一帧 FP） | DWARF CFI 规则表 |
| **PC 获取** | `*(FP + 8)` | `*(CFA + pc_off)` |
| **SP 计算** | `FP + 16` | `SP + cfa_off` 或 `FP + cfa_off` |
| **需要 FP?** | ✅ 必须 | ❌ 不需要 |
| **安全保护** | SafeAccess::load | 范围检查 + 对齐检查 |
| **查找开销** | 无 | 二分查找（~19 步） |
| **内存开销** | 0 | ~9 MB DWARF 表 |
| **解析开销** | 0 | 启动时解析 .eh_frame |
| **准确性** | 依赖编译选项 | 始终准确（编译器保证）|

### 9.2 代码复杂度对比

```
walkFP 核心循环:   ~20 行（3 个指针操作）
walkDwarf 核心循环: ~50 行（查找 + CFA 计算 + 分支处理）
```

### 9.3 何时用哪个？

```
--cstack fp    → walkFP   → 快、轻量、但可能不完整
--cstack dwarf → walkDwarf → 准确、但有查找开销
--cstack vm    → walkVM   → 最全面（Java+Native 混合）
--cstack no    → 不采原生栈
```

**默认值**：async-profiler 默认 `--cstack vm`，因为 walkVM 最全面。`--cstack dwarf` 主要用于：
1. 不需要 Java 栈（如 C++ 性能分析）
2. 需要穿越 `libc.so` 等没有 FP 的库
3. 需要精确的原生栈但不需要 JVM 内部帧细节

---

## 十、eh_frame 加载时机

### 10.1 触发点

```
CodeCache::loadLibrary(name)
  → 解析 ELF → 找到 .eh_frame_hdr 段
  → DwarfParser(name, image_base, eh_frame_hdr)
  → 生成 FrameDesc 数组 → 排序（按 loc）
  → 存入 CodeCache::_dwarf_table
```

### 10.2 什么时候调用 loadLibrary？

1. **Profiler::start()** → `updateNativeLibraries()` → 读 `/proc/self/maps` → 为每个 `.so` 调用 `loadLibrary`
2. **dlopen_hook()** → 新库加载时动态更新

### 10.3 内存布局

```
CodeCache 对象 (per library)
  ├── _name = "libjvm.so"
  ├── _text_base = 0x7ffff5206000
  ├── _dwarf_table = FrameDesc[508048]     ← 7.8 MB
  ├── _dwarf_table_length = 508048
  ├── _plt_offset, _plt_size              ← PLT 区域范围
  ├── _blobs[] = CodeBlob[N]               ← ELF 符号
  └── _count = N
```

---

## 十一、AArch64 的特殊处理

在 x86_64 上，返回地址总是在栈上（`call` 指令 push）。但在 AArch64 上，返回地址在 **Link Register (LR/X30)** 中：

```cpp
// dwarf.h
#if defined(__aarch64__)
const int EMPTY_FRAME_SIZE = 0;         // 无隐式 push
const int LINKED_FRAME_SIZE = 0;        // 无固定链接帧
const int INITIAL_PC_OFFSET = DW_LINK_REGISTER;  // 初始 PC 在 LR 中
#endif

// walkDwarf 中
if (EMPTY_FRAME_SIZE > 0 || f->pc_off != DW_LINK_REGISTER) {
    pc = stripPointer(*(void**)(sp + f->pc_off));  // x86_64: 从栈读
} else if (depth == 1) {
    pc = (const void*)frame.link();                 // AArch64: 从 LR 读
} else {
    break;  // 无法继续
}
```

在 x86_64 上 `EMPTY_FRAME_SIZE = 8 > 0`，所以总是走第一个分支（从栈读取返回地址）。

---

## 十二、总结

### DWARF CFI 栈回溯的核心设计

1. **一次解析，多次查找**：启动时解析 `.eh_frame` 为 FrameDesc 数组（~9MB），运行时二分查找（~19 步），O(log n) 复杂度

2. **三层 fallback**：
   - DWARF 表中有匹配 → 使用精确 CFI 规则
   - PLT 区域 → `empty_frame`（RSP + 8）
   - 未知区域 → `default_frame`（假设标准 FP-based 帧）

3. **精巧的编码**：
   - `cfa` 字段 = 低 8 位寄存器 + 高 24 位偏移
   - `fp_off` 最低位 = DW_PC_OFFSET 标志
   - `DW_REG_PLT = 128` = PLT 条件分支

4. **去重优化**：连续相同 CFI 规则只存一条，显著减少表大小

### GDB 验证关键数据

| 验证项 | 实际值 | 含义 |
|--------|--------|------|
| 加载库数量 | 22 | 22 个共享库都解析了 DWARF |
| libjvm.so FrameDesc 数 | **508,048** | 最大的一个库 |
| 二分查找步数 | ≤ 19 | O(log₂ 508048) |
| 总内存占用 | ~9 MB | 所有库的 FrameDesc 表 |
| 典型 FrameDesc.cfa | 0x1006 | CFA = RBP + 16 (debug 构建) |
| fp_off | -16 | FP 保存在 CFA-16 |
| pc_off | -8 | 返回地址在 CFA-8 |
| walkDwarf 返回帧数 | 7~15 | 到 CodeHeap 边界停止 |
| CIE: cf=1 df=-8 ra=16 | x86_64 标准 | code_align=1, data_align=-8, RA=RIP |

### 与 readelf 的交叉验证

```
readelf 输出:  CFA=rbp+16  rbp=c-16  ra=c-8
GDB FrameDesc: cfa=0x1006  fp_off=-16  pc_off=-8
计算验证:      cfa_reg=6(RBP) cfa_off=16  → CFA=RBP+16
               FP=*(CFA-16)=*RBP  PC=*(CFA-8)=*(RBP+8)  ✅ 完全一致
```

### 在整体架构中的位置

```
Agent 加载（Ch01）
  → VMStructs 初始化（Ch02）
  → Engine 体系（Ch03）
  → perf_event_open + 信号驱动（Ch04）
  → 信号到达 → recordSample()（Ch05.1）
    ├── getNativeTrace（Ch05.1）
    │   ├── CSTACK_FP → walkFP（Ch05.3）
    │   ├── CSTACK_DWARF → walkDwarf（本节）  ← 你在这里
    │   └── CSTACK_VM → return 0
    ├── getJavaTraceAsync → ASGCT（Ch05.2）
    └── walkVM → 混合模式（Ch05.5）
```

---

*创建日期: 2026-02-09*
*GDB 验证环境: OpenJDK 11 slowdebug + async-profiler v4.0*
*标准条件: -Xms8g -Xmx8g -XX:+UseG1GC -Xint --cstack dwarf*
