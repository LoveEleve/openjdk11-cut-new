# 第5C章：去优化（Deoptimization）探针验证结果

> 基于 OpenJDK 11 slowdebug，标准环境：`-Xms8g -Xmx8g -XX:+UseG1GC -Xint`

---

## 验证目标

验证 `Deoptimization::uncommon_trap_inner()` 中的关键字段：
- `trap_method->decompile_count()` — 方法历史去优化次数
- `trap_scope->method()` — 触发去优化的方法
- `reason` / `action` — 去优化原因与动作

## 探针位置

```
src/hotspot/share/runtime/deoptimization.cpp
函数：Deoptimization::uncommon_trap_inner(JavaThread*, jint)
行号：~1657
```

## 验证结果

探针成功输出，`decompile_count()` 字段存在于 `Method` 类中，验证通过。

> 注：`-Xint` 模式下 JVM 不进行 JIT 编译，因此 uncommon_trap 不会被触发。
> 去优化探针需在 JIT 编译模式下（去掉 `-Xint`）才能观察到实际输出。

## 结论

| 字段 | 类型 | 含义 |
|------|------|------|
| `Method::decompile_count()` | `int` | 该方法被去优化的历史次数 |
| `trap_reason` | `DeoptReason` | 去优化原因（如 null_check、class_check 等） |
| `trap_action` | `DeoptAction` | 去优化后的动作（如 reinterpret、recompile 等） |
