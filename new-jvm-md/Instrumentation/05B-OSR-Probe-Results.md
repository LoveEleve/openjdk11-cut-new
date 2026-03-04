# 第5B章：OSR（栈上替换）链路插桩验证结果

> 基于 OpenJDK 11 slowdebug 插桩版本  
> 运行环境：-Xms512m -Xmx512m -XX:+UseG1GC（不加 -Xint，允许 JIT）  
> 数据来源：第5章 JIT 编译触发链路实测日志中的 OSR 子集

---

## 一、验证目标

本章聚焦 OSR（On-Stack Replacement）链路，验证以下问题：

- OSR 触发时 `invocation_count` 与 `backedge_count` 的关系
- `osr_bci` 的实际含义（对应哪个循环回边）
- OSR 编译在分层编译中的层级选择（Tier3/Tier4）
- 同一方法多热循环时是否会出现多个 `osr_bci`

---

## 二、关键插桩点

- `src/hotspot/share/interpreter/interpreterRuntime.cpp`  
  `frequency_counter_overflow_inner()`（识别 `branch_bcp != NULL` 的 OSR 触发）
- `src/hotspot/share/compiler/compileBroker.cpp`  
  `invoke_compiler_on_method()`（识别 `osr_bci != -1` 的 OSR 编译完成）

---

## 三、实测结果

### 3.1 OSR 触发样例（解释器侧）

```text
[PROBE][JIT] frequency_counter_overflow: method=com.wjcoder.JITTest.main([Ljava/lang/String;)V
  触发类型=OSR(循环回边) (branch_bcp=非NULL)
  invocation_count=1
  backedge_count=1024
  当前编译级别=0 (解释执行)
  osr_bci=34 (循环回边字节码偏移量)
```

结论：
- OSR 触发时可出现 `invocation_count=1`，说明**方法调用不热但循环很热**即可触发编译。
- `backedge_count=1024` 展示了回边计数驱动 OSR 的典型路径。
- `osr_bci=34` 指向对应循环回边的字节码位置。

### 3.2 OSR 编译样例（编译器侧）

```text
[PROBE][JIT] 编译完成: method=com.wjcoder.JITTest.hotLoop(I)J
  编译级别=Tier4 (C2)
  是否OSR=YES (osr_bci=4)
  编译耗时=8ms
  代码大小: total=832 bytes, insts=416 bytes
```

结论：
- 热循环可直接触发 Tier4（C2）OSR 编译。
- `osr_bci=4` 对应 `hotLoop` 方法内循环回边。

### 3.3 同一方法多 OSR 位点

```text
[PROBE][JIT] 编译完成: method=com.wjcoder.JITTest.main([Ljava/lang/String;)V
  编译级别=Tier3 (C1-profiling)
  是否OSR=YES (osr_bci=34)

[PROBE][JIT] 编译完成: method=com.wjcoder.JITTest.main([Ljava/lang/String;)V
  编译级别=Tier3 (C1-profiling)
  是否OSR=YES (osr_bci=118)
```

结论：
- 同一方法的多个热循环可触发多个 OSR 编译任务。
- `osr_bci` 是区分 OSR 编译入口的关键标识。

---

## 四、核心结论汇总

| 问题 | 结论 |
|------|------|
| OSR 是看调用次数还是循环回边？ | 主要由循环回边热度驱动，`backedge_count` 是关键触发信号 |
| OSR 触发时 `invocation_count` 必须高吗？ | 不需要，可低至 1 |
| `osr_bci` 是什么？ | 热循环回边对应的字节码偏移量 |
| OSR 一定先 C1 再 C2 吗？ | 不一定，足够热时可直接到 C2 |
| 一个方法会有多个 OSR 编译吗？ | 会，不同热循环对应不同 `osr_bci` |

---

## 五、后续衔接

第5B章已完成“触发与编译结果”验证。下一步可继续第5C章（去优化）与第5D章（解释器 dispatch）的独立链路验证。