# 第5D章：字节码解释执行（TemplateInterpreter）探针验证结果

> 基于 OpenJDK 11 slowdebug，标准环境：`-Xms512m -Xmx512m -Xint`
> 探针位置：`templateInterpreterGenerator.cpp` `generate_all()` 末尾 + `templateTable_x86.cpp` + `java.cpp` `before_exit()`

---

## 验证目标

1. **dispatch table 内存布局**：TOS 状态数、每表项数、总大小、关键字节码 handler 地址
2. **字节码执行频率统计**：`new` 和 `invokevirtual` 的执行次数及比值
3. **`_active_table` vs `_normal_table` 的初始化时序**

---

## 探针输出（实测）

### 探针 5D.1 — dispatch table 布局

```
[PROBE][TemplateTable-5D.1] dispatch table 布局:
  TOS状态数=10 (btos/ztos/ctos/stos/atos/itos/ltos/ftos/dtos/vtos)
  每个dispatch table项数=256 (1<<8, 覆盖所有字节值)
  [itos] iload_0  handler=0x00007f44a50153de
  [itos] iadd     handler=0x00007f44a50180c7
  [itos] ireturn  handler=0x00007f44a501ad47
  [vtos] invokevirtual handler=0x00007f44a501f6df
  [vtos] new      handler=0x00007f44a502073f
  dispatch table 总大小=20480 bytes (10 states * 256 entries * 8 bytes/ptr)
  解释器代码段总大小=130592 bytes
  说明: generate_all()结束后 normal_table→active_table, Safepoint时切换为safept_table
```

### 探针 5D.2 — 字节码执行频率统计（JVM 退出时输出）

```
[PROBE][TemplateTable-5D.2] 字节码执行频率统计(最终值):
  new          执行次数=127828
  invokevirtual 执行次数=2336616
  invokevirtual/new 比值=18.3 (每次new对象平均触发18.3次虚方法调用)
```

---

## 数据分析

### 1. dispatch table 是 10×256 的二维指针数组

```
总大小 = 10 × 256 × 8 = 20480 bytes ✅

内存布局（按 TOS 状态排列）：
┌─────────────────────────────────────────────────────────┐
│  btos_table[256]  → 256 个 handler 指针（字节操作）      │
│  ztos_table[256]  → 256 个 handler 指针（boolean）       │
│  ctos_table[256]  → 256 个 handler 指针（char）          │
│  stos_table[256]  → 256 个 handler 指针（short）         │
│  atos_table[256]  → 256 个 handler 指针（引用类型）       │
│  itos_table[256]  → 256 个 handler 指针（int）           │
│  ltos_table[256]  → 256 个 handler 指针（long）          │
│  ftos_table[256]  → 256 个 handler 指针（float）         │
│  dtos_table[256]  → 256 个 handler 指针（double）        │
│  vtos_table[256]  → 256 个 handler 指针（void/无值）     │
└─────────────────────────────────────────────────────────┘
每个 table = 256 × 8 = 2048 bytes
总计 = 10 × 2048 = 20480 bytes
```

**为什么是 10 种 TOS 状态？**

TOS（Top Of Stack）状态描述当前操作数栈顶的值类型，解释器在 dispatch 时需要知道栈顶是什么类型，才能选择正确的 handler。10 种状态覆盖了 Java 所有基本类型 + 引用类型 + 无值（void）。

### 2. 关键 handler 地址分析

| 字节码 | TOS 状态 | handler 地址 | 字节码值 |
|--------|---------|-------------|---------|
| `iload_0` | itos | `0x7f44a50153de` | `0x1a` |
| `iadd` | itos | `0x7f44a50180c7` | `0x60` |
| `ireturn` | itos | `0x7f44a501ad47` | `0xac` |
| `invokevirtual` | vtos | `0x7f44a501f6df` | `0xb6` |
| `new` | vtos | `0x7f44a502073f` | `0xbb` |

**关键发现**：所有 handler 地址都在 `0x7f44a501xxxx` 附近，说明所有字节码 handler 被打包在同一块连续的 CodeBlob 里。

地址间距分析：
```
iload_0  → iadd:         0x80c7 - 0x53de = 0x2CE9 = 11497 bytes
iadd     → ireturn:      0xad47 - 0x80c7 = 0x2C80 = 11392 bytes
ireturn  → invokevirtual: 0xf6df - 0xad47 = 0x4998 = 18840 bytes
invokevirtual → new:     0x073f - 0xf6df = 0x1060 = 4192 bytes（跨越 0x...02xxxx）
```

`invokevirtual` 的 handler 最大（18840 bytes），因为它需要处理：vtable 查找、inline cache、类型检查、参数传递等复杂逻辑。

### 3. 解释器代码段总大小：130592 bytes ≈ 127KB

```
解释器代码段 = 所有字节码 handler 的机器码总和
            = 130592 bytes ≈ 127KB

Bytecodes::number_of_codes = 239（已定义字节码数）
平均每个字节码 handler = 130592 / 239 ≈ 546 bytes
```

这 127KB 的代码段在 JVM 启动时由 `generate_all()` 动态生成，存放在 CodeCache 的特殊区域（非 nmethod 区域）。

### 4. `_normal_table` vs `_active_table` 的初始化时序

```
generate_all() 执行期间：
  → 填充 _normal_table（每个字节码的 handler 地址写入）
  → 填充 _safept_table（每个 handler 前插入 safepoint 检查点）

generate_all() 完成后：
  → _active_table = _normal_table（复制，正常执行模式）

Safepoint 发生时：
  → _active_table = _safept_table（切换，每个 dispatch 前检查 safepoint）

Safepoint 结束后：
  → _active_table = _normal_table（切换回来）
```

**这就是为什么探针必须读 `_normal_table` 而不是 `_active_table`**：在 `generate_all()` 末尾，`_active_table` 还没有被填充（全是 0），只有 `_normal_table` 已经有了真实的 handler 地址。

### 5. 字节码执行频率：`invokevirtual` 是 `new` 的 18.3 倍

```
new          = 127,828 次
invokevirtual = 2,336,616 次
比值          = 18.3
```

**为什么 `invokevirtual` 远多于 `new`？**

这符合典型 Java 程序的特征：
- 一个对象创建后，会被多次调用方法（平均 18.3 次）
- `invokevirtual` 是 Java 最常用的方法调用指令（普通实例方法调用）
- 这也是 JVM 对虚方法调用做大量优化（inline cache、vtable、C2 内联）的根本原因

---

## 核心结论

| 发现 | 数据 | 意义 |
|------|------|------|
| dispatch table 结构 | 10 × 256 × 8 = 20480 bytes | O(1) 按 `[TOS状态][字节码值]` 索引跳转 |
| 解释器代码段大小 | 130592 bytes ≈ 127KB | 所有 239 个字节码 handler 打包在一块连续 CodeBlob |
| `invokevirtual` handler 最大 | ~18840 bytes | vtable 查找 + inline cache + 类型检查逻辑复杂 |
| `_active_table` 初始化时序 | `generate_all()` 完成后才填充 | 探针必须读 `_normal_table` |
| 字节码执行频率比 | invokevirtual/new = 18.3 | 虚方法调用是最高频操作，优化价值最高 |

---

## 插桩位置

| 探针 | 文件 | 位置 |
|------|------|------|
| 5D.1 dispatch table 布局 | `src/hotspot/share/interpreter/templateInterpreterGenerator.cpp` | `generate_all()` 末尾，读 `_normal_table` |
| 5D.2 字节码执行频率 | `src/hotspot/cpu/x86/templateTable_x86.cpp` + `src/hotspot/share/runtime/java.cpp` | `_new()`/`invokevirtual()` 原子自增 + `before_exit()` 输出 |
