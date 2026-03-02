# Day 3：栈回溯方法对比 - 复习卡片

> 复习目标：掌握四种栈回溯方法的原理、优缺点、适用场景
> 学习时间：2-3 小时
> 完成标准：通过 4 个自测问题

---

## 知识索引

详细技术内容请参考源码分析文档：
- 四种栈回溯方法详解 → `03-Stack-Walking-Methods-Comparison.md`
- VMStructs 偏移推断 → `04-VMStructs-Offset-Inference.md`
- AsyncGetCallTrace → `02-AsyncGetCallTrace-Solution.md`

---

## 一、面试实战演练

### 1.1 问题 1：为什么需要四种栈回溯方法？

**标准回答**：

**第一层（直接回答）**：
因为每种方法都有局限性，单一方法无法覆盖所有场景。组合使用可以提高成功率和适用性。

**第二层（具体分析）**：

**AGCT 的局限**：
- 只在 HotSpot/OpenJ9 可用
- Native 代码期间失败率高（5-30%）
- 无法处理纯 Native 调用链

**FP 的局限**：
- 需要编译时保留 FP
- 现代 JVM 默认不保留
- 无法识别 Java 帧

**DWARF 的局限**：
- 需要 .eh_frame 段
- JVM 库可能没有
- 解析开销大

**VMStructs 的局限**：
- 实现复杂
- JVM 内部结构变化可能失败
- 需要符号表

**第三层（组合优势）**：

async-profiler 的组合策略：
```
1. AGCT（准确度最高） → 失败率 1-30%
2. VMStructs（最全面） → 覆盖更多场景
3. DWARF（最现代）    → 处理 Native 代码
4. FP（最快）        → 最后的降级方案

组合成功率：99%+
```

**第四层（场景选择）**：

| 应用类型 | 首选方法 | 备选方法 |
|---------|---------|---------|
| 纯 Java | AGCT | VMStructs |
| Java + JNI | AGCT + VMStructs | DWARF |
| 大量 Native | DWARF + FP | - |
| JVM 内部 | VMStructs | AGCT |

---

### 1.2 问题 2：FP 链式回溯为什么在现代 JVM 中效果不好？

**标准回答**：

**第一层（核心原因）**：
现代 JVM 默认省略帧指针（FP），以优化性能。

**第二层（技术细节）**：

**为什么省略 FP？**
1. **寄存器优化**：RBP 可以用于其他用途
2. **性能提升**：减少 push/pop 操作
3. **内存节省**：栈帧更小

**源码验证**：

```cpp
// hotspot/share/opto/compile.cpp

// JIT 编译时省略 FP
bool Compile::needs_stack_bang() {
    // 现代编译器默认省略 FP
    return false;
}
```

**第三层（影响）**：

**栈帧布局对比**：

```
保留 FP：
┌─────────┐
│ 返回地址 │
│ RBP     │ ← RBP 指向这里
│ 局部变量 │
└─────────┘

省略 FP：
┌─────────┐
│ 返回地址 │
│ 局部变量 │ ← RBP 可能指向其他地方
└─────────┘
```

**无法回溯**：
- 没有 RBP 链，无法找到上一帧
- 只能依赖其他方法（如 DWARF）

**第四层（解决方案）**：

1. **使用 DWARF**：
   - 解析 .eh_frame
   - 无需 FP

2. **使用 VMStructs**：
   - 自定义栈回溯逻辑
   - 不依赖 FP

3. **编译选项**（不推荐）：
   - 某些 JVM 支持保留 FP
   - 但性能会下降

---

### 1.3 问题 3：DWARF CFI 如何工作？有什么优势？

**标准回答**：

**第一层（核心原理）**：
DWARF CFI（Call Frame Information）通过 .eh_frame 段存储栈回溯规则，运行时根据 PC 查找并应用规则。

**第二层（工作流程）**：

```
1. 编译时：
   编译器生成 .eh_frame 段
   ├─ CIE（通用信息）
   └─ FDE（每函数信息）

2. 运行时：
   根据 PC 查找 FDE
   ├─ 提取 CFA 规则
   ├─ 提取寄存器恢复规则
   └─ 应用规则计算上一帧
```

**第三层（优势）**：

**1. 无需 FP**：
```
编译器可以省略 FP，通过 CFI 规则回溯
```

**2. 现代标准**：
```
GCC/Clang 默认生成 .eh_frame
几乎所有现代 C++ 程序都有
```

**3. 准确度高**：
```
基于标准规范，不依赖硬件特性
```

**4. 支持 C++ 特性**：
```
异常处理、栈展开等
```

**第四层（劣势）**：

**1. 依赖 .eh_frame**：
```
JVM 库可能没有
需要符号表
```

**2. 解析开销**：
```
查找 FDE：二分查找
应用规则：需要计算
总开销：10-100 μs（比 FP 慢 10-100 倍）
```

**3. 无法识别 Java 帧**：
```
只处理 Native 代码
需要与 AGCT/VMStructs 配合
```

---

### 1.4 问题 4：VMStructs 偏移推断的原理是什么？为什么能实现版本兼容？

**标准回答**：

**第一层（核心原理）**：
通过 JVM 导出的 VMStructs 符号表，运行时推断内部数据结构的字段偏移量，无需依赖头文件。

**第二层（实现细节）**：

**VMStructs 符号表**：
```cpp
struct VMStructEntry {
    const char* typeName;    // 类型名
    const char* fieldName;   // 字段名
    uint64_t offset;         // 字段偏移
};

// JVM 导出的全局符号
VMStructEntry* gHotSpotVMStructs;
```

**查找偏移量**：
```cpp
uintptr_t find_offset(const char* typeName, const char* fieldName) {
    for (VMStructEntry* entry = gHotSpotVMStructs; entry->typeName; entry++) {
        if (strcmp(entry->typeName, typeName) == 0 &&
            strcmp(entry->fieldName, fieldName) == 0) {
            return entry->offset;
        }
    }
    return -1;
}
```

**使用偏移量**：
```cpp
// 不需要知道 JavaThread 的定义
uintptr_t stack_base_offset = find_offset("JavaThread", "_stack_base");
void* stack_base = *(void**)((char*)thread + stack_base_offset);
```

**第三层（版本兼容）**：

**为什么能兼容？**

1. **运行时推断**：
```
不需要头文件
启动时从符号表提取偏移量
```

2. **符号表稳定**：
```
VMStructs 是 JVM 导出的
字段名不变，偏移量正确
```

3. **版本适配**：
```
不同版本 JVM 的偏移量可能不同
但 VMStructs 会反映真实值
```

**示例**：

```
JDK 8：
  JavaThread._stack_base = offset 128

JDK 11：
  JavaThread._stack_base = offset 144

JDK 17：
  JavaThread._stack_base = offset 152

VMStructs 会返回正确的值，无需硬编码
```

**第四层（局限性）**：

**1. 实现复杂**：
```
需要理解 JVM 内部结构
需要编写自定义栈回溯逻辑
```

**2. 符号依赖**：
```
如果 JVM 不导出 VMStructs，失败
某些定制 JVM 可能没有
```

**3. 脆弱性**：
```
JVM 内部结构变化可能导致失败
字段重命名、删除等
```

---

## 二、自测环节（必须通过）

### 自测 1：四种方法对比

**Q**: 请对比四种栈回溯方法的优缺点，并说明适用场景。

<details>
<summary>点击查看答案</summary>

**A**:

| 方法 | 优点 | 缺点 | 适用场景 |
|------|------|------|---------|
| **AGCT** | 准确度最高、Java 支持完美 | 非 标准、Native 支持有限 | 纯 Java 应用 |
| **FP** | 最快、无依赖 | 需要 FP 寄存器、JVM 不保留 | C++ 程序（保留 FP） |
| **DWARF** | 无需 FP、现代标准 | 需要 .eh_frame、解析慢 | 现代 C++ 程序 |
| **VMStructs** | 版本兼容、混合支持 | 实现复杂、符号依赖 | JVM 内部分析 |

**组合策略**：
```
1. AGCT（首选）
2. VMStructs（备选）
3. DWARF（Native 代码）
4. FP（最后的降级）
```

**最终成功率**：99%+
</details>

---

### 自测 2：FP 链式回溯

**Q**: FP 链式回溯如何工作？为什么在现代 JVM 中效果不好？

<details>
<summary>点击查看答案</summary>

**A**:

**工作原理**：
```
读取 RBP 寄存器
    ↓
[当前帧] RBP → [上一帧] RBP → [上上一帧] RBP
    ↓
遍历链表，获取返回地址
```

**在现代 JVM 中效果不好的原因**：

1. **JVM 省略 FP**：
   - 现代编译器默认省略 FP
   - RBP 可能指向其他地方
   - 无法形成链表

2. **栈帧布局变化**：
   ```
   保留 FP：
   [返回地址] [RBP] [局部变量]
   
   省略 FP：
   [返回地址] [局部变量]
   ```

3. **无法回溯**：
   - 没有 RBP 链
   - 只能依赖其他方法

**解决方案**：
- 使用 DWARF（无需 FP）
- 使用 VMStructs（自定义逻辑）
- 编译时保留 FP（不推荐，性能下降）
</details>

---

### 自测 3：DWARF CFI

**Q**: DWARF CFI 如何工作？有什么优势和劣势？

<details>
<summary>点击查看答案</summary>

**A**:

**工作原理**：
```
1. 编译时：生成 .eh_frame 段
   ├─ CIE（通用信息）
   └─ FDE（每函数信息）

2. 运行时：
   根据 PC 查找 FDE
   ├─ 提取 CFA 规则
   ├─ 提取寄存器恢复规则
   └─ 应用规则计算上一帧
```

**优势**：
1. 无需 FP：编译器可以省略 FP
2. 现代标准：GCC/Clang 默认生成
3. 准确度高：基于标准规范
4. 支持 C++：异常处理、栈展开

**劣势**：
1. 依赖 .eh_frame：JVM 库可能没有
2. 解析开销：10-100 μs（比 FP 慢）
3. 无法识别 Java 帧：需要配合其他方法
</details>

---

### 自测 4：VMStructs 推断

**Q**: VMStructs 偏移推断为什么能实现版本兼容？

<details>
<summary>点击查看答案</summary>

**A**:

**核心原理**：
通过 JVM 导出的 VMStructs 符号表，运行时推断偏移量，无需头文件。

**版本兼容的原因**：

1. **运行时推断**：
   ```
   启动时从符号表提取偏移量
   不需要硬编码
   ```

2. **符号表稳定**：
   ```
   VMStructs 是 JVM 导出的
   字段名不变，偏移量正确
   ```

3. **自动适配**：
   ```
   JDK 8:  offset 128
   JDK 11: offset 144
   JDK 17: offset 152
   
   VMStructs 返回正确的值
   ```

**示例代码**：
```cpp
// 不需要头文件
uintptr_t offset = find_offset("JavaThread", "_stack_base");
void* value = *(void**)((char*)thread + offset);
```

**局限性**：
- 实现复杂
- 符号依赖
- 脆弱性（JVM 内部变化）
</details>

---

## 三、Day 3 完成标准

通过 Day 3 的标准是：

- [ ] 能说明四种方法的原理和优缺点
- [ ] 能解释为什么需要组合使用
- [ ] 能说明 FP 链式回溯的局限性
- [ ] 能描述 DWARF CFI 的工作流程
- [ ] 能解释 VMStructs 如何实现版本兼容
- [ ] 能为不同场景选择合适的方法
- [ ] 通过所有 4 个自测问题

---

## 四、扩展阅读（追求极致深度）

### 4.1 相关规范

**DWARF 标准**：
- DWARF 5: https://dwarfstd.org/doc/DWARF5.pdf
- Chapter 6: Call Frame Information

**System V AMD64 ABI**：
- 栈帧布局和调用约定
- .eh_frame 格式

### 4.2 源码阅读

**FP 回溯**：
```cpp
// async-profiler/src/walker.cpp
void StackWalker::walkFP(void* ucontext);
```

**DWARF 回溯**：
```cpp
// async-profiler/src/dwarf.cpp
void DwarfParser::parseEHFrame();
void StackWalker::walkDwarf(void* ucontext);
```

**VMStructs 推断**：
```cpp
// async-profiler/src/vmStructs.cpp
void VMStructs::init();
uintptr_t VMStructs::offset(const char* typeName, const char* fieldName);
```

### 4.3 实战工具

**查看 .eh_frame**：
```bash
readelf --debug-dump=frames binary
```

**查看 VMStructs**：
```bash
nm $JAVA_HOME/lib/server/libjvm.so | grep gHotSpotVMStructs
```

**测试 FP 保留**：
```bash
objdump -d binary | grep -A2 "push.*%rbp"
```

---

## 五、Day 3 总结

### 核心知识点

```
栈回溯方法对比
├─ AsyncGetCallTrace
│  ├─ 原理：JVMTI 接口
│  ├─ 优点：准确度最高、Java 支持完美
│  ├─ 缺点：非标准、Native 支持有限
│  └─ 适用：纯 Java 应用
├─ Frame Pointer
│  ├─ 原理：RBP 链式回溯
│  ├─ 优点：最快、无依赖
│  ├─ 缺点：需要 FP、JVM 不保留
│  └─ 适用：C++ 程序（保留 FP）
├─ DWARF CFI
│  ├─ 原理：.eh_frame 段解析
│  ├─ 优点：无需 FP、现代标准
│  ├─ 缺点：需要符号表、解析慢
│  └─ 适用：现代 C++ 程序
├─ VMStructs
│  ├─ 原理：偏移量推断
│  ├─ 优点：版本兼容、混合支持
│  ├─ 缺点：实现复杂、符号依赖
│  └─ 适用：JVM 内部分析
└─ 组合策略
   ├─ 顺序：AGCT → VMStructs → DWARF → FP
   └─ 成功率：99%+
```

### 面试要点

1. **对比分析**：能说明四种方法的优缺点
2. **组合策略**：能解释为什么需要组合使用
3. **场景选择**：能为不同场景选择合适的方法
4. **技术深度**：能描述每种方法的工作原理

### 下一步

Day 3 完成后，进入 **Day 4：VMStructs 偏移推断深入**，学习：
- VMStructs 符号表结构
- 偏移量推断的三种方法
- 关键偏移量的应用
- 实战案例分析

---

**Day 3 完成！准备好进入 Day 4 了吗？**
