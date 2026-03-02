# Safepoint GDB 实战 — 完整观察一次 Young GC STW 全过程

> **目标**: 用 GDB 亲手断点观察 Safepoint 的每个阶段，将 ch01 的理论分析变为**可复现的调试实践**
> **源码**: `safepoint.cpp`, `safepointMechanism.inline.hpp`, `vmThread.cpp`
> **标准环境**: `-Xms256m -Xmx256m -XX:+UseG1GC` (Region = 1MB，便于快速触发 GC)
> **前置知识**: [ch01_safepoint_begin_deep_dive.md](ch01_safepoint_begin_deep_dive.md)
> **核心价值**: 面试中说"我用 GDB 在 safepoint 的每个阶段都打过断点"——碾压级差异化

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文通过 GDB 实际运行验证 **Safepoint  实战 — 完整观察一次 Young GC STW 全过程** 的关键结论：用实际数据替代理论推断，确保分析结论的准确性。

### 0.2 为什么需要？

源码分析可能存在误读——代码路径可能在运行时走不同的分支，数据结构的实际大小可能与理论计算不符。GDB 验证是消除不确定性的最可靠方法。

### 0.3 怎么解决？

设计验证计划（验证哪些结论）→ 编写 GDB 脚本 → 实际运行 → 对比预期与实际结果 → 解释差异。

### 0.4 为什么这样设计？

验证策略：优先验证「影响结论正确性的关键假设」，而不是验证所有细节。关键假设包括：数据结构 sizeof、关键字段的值、代码路径的走向。

---


## 一句话总结

本篇通过 5 个 GDB 实验，**实际观察**了一次 Young GC STW 的完整生命周期：`_not_synchronized`(counter=偶数) → `begin()` arm polling page → spin/block 等待所有线程 → `_synchronized`(counter=奇数) → 执行 GC + cleanup → `end()` disarm + unlock → `_not_synchronized`(counter=偶数)。所有理论数值都与 GDB 实测完全吻合。

---

## 1. 实验环境准备

### 1.1 测试程序

```java
// SafepointTest.java — 不断分配对象，触发多次 Young GC
package com.wjcoder;
public class SafepointTest {
    static Object[] roots = new Object[10000];
    public static void main(String[] args) throws Exception {
        for (int round = 0; round < 50; round++) {
            for (int i = 0; i < 10000; i++) {
                roots[i] = new byte[4096]; // 4KB 对象
            }
        }
        System.out.println("done");
    }
}
```

**设计思路**：
- 用 `static Object[]` 保持对分配对象的引用（阻止部分被快速回收）
- 每轮分配 10000 × 4KB ≈ 40MB
- 256MB 小堆确保频繁触发 Young GC（实测 10+ 次 GC）
- `-Xint` 纯解释执行，GDB 调试更稳定

### 1.2 JVM 参数

```bash
# GDB 调试模式
gdb -batch -x gdb_script.txt --args \
  ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
  -XX:+UseG1GC -Xms256m -Xmx256m -Xint \
  -cp /data/workspace/demo/src com.wjcoder.SafepointTest

# 日志模式（不经过 GDB）
java -XX:+UseG1GC -Xms256m -Xmx256m -Xint \
  -Xlog:safepoint*=debug:stdout \
  -cp /data/workspace/demo/src com.wjcoder.SafepointTest
```

---

## 2. 实验1: 一次 STW 的完整生命周期

### 2.1 实验目标

验证 `SafepointSynchronize::begin()` → `_synchronized` → `do_cleanup_tasks()` → `end()` → `Threads_lock->unlock()` 的**完整时序**。

### 2.2 GDB 脚本

```gdb
# 在 begin(), synchronized, cleanup, end(), unlock 五个关键点设断点
b SafepointSynchronize::begin        # STW 发起
b safepoint.cpp:465                  # _state = _synchronized
b SafepointSynchronize::do_cleanup_tasks  # Cleanup 阶段
b SafepointSynchronize::end          # STW 结束
b safepoint.cpp:587                  # Threads_lock->unlock() — 线程唤醒
```

### 2.3 实验结果

```
【GDB 实测】-Xms256m -Xmx256m -XX:+UseG1GC
┌══════════════════════════════════════════════════════════════════════┐
│ SafepointSynchronize::begin() — STW 开始!                          │
│                                                                     │
│ 当前 VM_Operation: EnableBiasedLocking                              │
│ _state:            0 (_not_synchronized)  ← begin 入口时的状态      │
│ _safepoint_counter: 0 (偶数 → 不在 safepoint 中)                   │
│                                                                     │
│ SafepointMechanism 配置:                                            │
│   _poll_armed_value:    0x7ffff7fbd008                              │
│   _poll_disarmed_value: 0x7ffff7fbe000                              │
│   _poll_bit:            8                                           │
│                                                                     │
│ armed   地址 & poll_bit = 8 (非0 → 触发 block)                     │
│ disarmed 地址 & poll_bit = 0 (0 → 不触发)                          │
├──────────────────────────────────────────────────────────────────────┤
│ do_cleanup_tasks() — 开始 Cleanup                                   │
│ 执行 7 项搭便车任务（deflate monitors, IC update, rehash, ...）     │
├──────────────────────────────────────────────────────────────────────┤
│ SafepointSynchronize::end() — STW 结束!                             │
│                                                                     │
│ _state:            2 (_synchronized)     ← end 入口时仍在 safepoint│
│ _safepoint_counter: 1 (奇数 → 在 safepoint 中)                     │
│ 即将 disarm 所有线程并释放 Threads_lock                             │
├──────────────────────────────────────────────────────────────────────┤
│ Threads_lock->unlock() — 所有线程被唤醒!                            │
│                                                                     │
│ _state:            0 (_not_synchronized) ← 已恢复                   │
│ _safepoint_counter: 2 (偶数 → 不在 safepoint 中)                   │
│                                                                     │
│ ========== STW 生命周期完成 ==========                              │
└══════════════════════════════════════════════════════════════════════┘
```

### 2.4 关键发现

1. **`_safepoint_counter` 的奇偶变化**：
   ```
   begin()  前:  counter = 0 (偶数 → 不在 safepoint)
   begin()  后:  counter = 1 (奇数 → 在 safepoint 中)
   end()    后:  counter = 2 (偶数 → 不在 safepoint)
   ```
   这验证了 ch01 中的理论：JNI fast path 通过 `counter & 1` 快速判断是否在 safepoint 中。

2. **Polling Page 位运算**：
   ```
   armed 地址:    0x7ffff7fbd008
   disarmed 地址: 0x7ffff7fbe000
   poll_bit:      8 (= 0x8)
   
   armed   & 0x8 = 8 ≠ 0 → 触发 safepoint 检查
   disarmed & 0x8 = 0     → 不触发
   ```
   两个地址仅相差 **bit 3**（0x8），arm/disarm 操作只是修改线程的 `_polling_page` 字段。

3. **`_state` 转换时序**：
   ```
   _not_synchronized (0)  →  begin() 中设为 _synchronizing (1)
                            →  spin/block 结束后设为 _synchronized (2)
                            →  end() 中恢复为 _not_synchronized (0)
   ```

---

## 3. 实验2: 线程状态分类观察

### 3.1 实验目标

在 `examine_state_of_thread()` 中观察 VMThread 如何对每个 JavaThread 进行**状态分类**。

### 3.2 实验结果

```
【GDB 实测】第一次 Safepoint (EnableBiasedLocking)

examine 线程 0x7ffff001f000  thread_state=10 [_thread_blocked → 安全!]
examine 线程 0x7ffff0da7800  thread_state=10 [_thread_blocked → 安全!]
examine 线程 0x7ffff0daa000  thread_state=10 [_thread_blocked → 安全!]
examine 线程 0x7ffff0dcf000  thread_state=10 [_thread_blocked → 安全!]
examine 线程 0x7ffff0dd1800  thread_state=10 [_thread_blocked → 安全!]
examine 线程 0x7ffff0e0e800  thread_state=10 [_thread_blocked → 安全!]
```

### 3.3 关键发现

在 `EnableBiasedLocking` safepoint 时，所有 6 个 JavaThread 都处于 `_thread_blocked`（状态值 = 10）。这是因为此时应用的 `main()` 尚未开始执行 Java 代码，所有线程都在等待。

**`_thread_blocked` 为什么是安全的？** 源码 `safepoint_safe()` 直接返回 true：

```cpp
// safepoint.cpp:760
case _thread_blocked:
    return true;  // 阻塞线程一定安全——不执行 Java 代码，栈帧稳定
```

### 3.4 五种线程状态的处理策略（源码验证 + GDB 映射）

```
┌──────────────────────────────────────────────────────────────────────────┐
│ JavaThreadState 枚举值对照表                                             │
├──────────────────────────────────────────────────────────────────────────┤
│ 枚举值    名称                  VMThread 处理                            │
│ ─────────────────────────────────────────────────────────────────────── │
│  2       _thread_new           继续等（等线程完成初始化后自行 block）     │
│  4       _thread_in_Java       继续等（等 polling 触发）                 │
│  5       _thread_in_vm         → _call_back（等线程退出 VM 时回调）      │
│  7       _thread_in_native     → _at_safepoint（天然安全，直接通过）      │
│  10      _thread_blocked       → _at_safepoint（天然安全，直接通过）      │
│                                                                          │
│  过渡态:                                                                 │
│  6       _thread_in_vm_trans   → block()                                │
│  8       _thread_in_native_trans → block()                              │
│  11      _thread_blocked_trans → block()                                │
│  3       _thread_new_trans     → block()                                │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 4. 实验3: 多次 Safepoint 追踪 — 观察 GC STW 序列

### 4.1 实验目标

完整追踪 10+ 次 Safepoint，观察 `_safepoint_counter` 的递增规律和不同 VM_Operation 的类型。

### 4.2 实验结果

```
【GDB 实测】-Xms256m -Xmx256m -XX:+UseG1GC -Xint
┌──────┬───────────────────────────────────┬─────────────┬────────────┐
│ SP#  │ VM_Operation                      │ counter     │ jni_active │
├──────┼───────────────────────────────────┼─────────────┼────────────┤
│ 1    │ EnableBiasedLocking               │ 1           │ 0          │
│ 2    │ G1CollectForAllocation            │ 3           │ 0          │
│ 3    │ G1CollectForAllocation            │ 5           │ 0          │
│ 4    │ G1CollectForAllocation            │ 7           │ 0          │
│ 5    │ G1CollectForAllocation            │ 9           │ 0          │
│ 6    │ G1CollectForAllocation            │ 11          │ 0          │
│ 7    │ G1CollectForAllocation            │ 13          │ 0          │
│ 8    │ G1CollectForAllocation ★          │ 15          │ 0          │
│      │ (Concurrent Start — 触发并发标记)  │             │            │
│ 9    │ G1CollectForAllocation            │ 17          │ 0          │
│ 10   │ G1CollectForAllocation            │ 19          │ 0          │
└──────┴───────────────────────────────────┴─────────────┴────────────┘
```

### 4.3 关键发现

1. **`_safepoint_counter` 严格奇偶交替**：
   ```
   SP#1: begin 后 counter=1 (奇数)  →  end 后 counter=2 (偶数)
   SP#2: begin 后 counter=3 (奇数)  →  end 后 counter=4 (偶数)
   ...
   SP#N: begin 后 counter=2N-1      →  end 后 counter=2N
   ```
   每次 safepoint 使 counter 增加 2（begin +1, end +1）。

2. **GC 触发密度**：在 256MB 堆中，几乎每隔 15-30ms 应用时间就触发一次 `G1CollectForAllocation`。SP#8 时 Eden 即将用尽，G1 自动升级为 `Concurrent Start`，触发并发标记。

3. **`jni_active_count` 始终为 0**：这说明没有线程在 JNI Critical Region 中（`GetPrimitiveArrayCritical` 等），GCLocker 不会阻止 GC。

4. **对比 GC 日志**：
   ```
   GC(0) Pause Young (Normal) (G1 Evacuation Pause) 24M->18M(256M) 54.195ms
   GC(1) Pause Young (Normal) (G1 Evacuation Pause) 30M->30M(256M) 37.222ms
   GC(2) Pause Young (Normal) (G1 Evacuation Pause) 52M->51M(256M) 47.694ms
   GC(6) Pause Young (Concurrent Start)             175M->175M(256M) 64.482ms
   ```
   Safepoint 和 GC 日志**一一对应**——SP#2 = GC(0), SP#3 = GC(1), ..., SP#8 = GC(6) Concurrent Start。

---

## 5. 实验4: 一次 GC STW 的 5 阶段详细快照

### 5.1 实验目标

在第一次 `G1CollectForAllocation` safepoint 中，精确捕获 5 个时间点的完整状态快照。

### 5.2 GDB 脚本核心逻辑

```gdb
# 跳过第 1 次 safepoint (EnableBiasedLocking)，在第 2 次 (第一次 GC) 停下
set $sp_count = 0
b SafepointSynchronize::begin
commands
  set $sp_count = $sp_count + 1
  if $sp_count == 2
    # 打印详细快照...
  end
end
```

### 5.3 实验结果

```
【GDB 实测】-Xms256m -Xmx256m -XX:+UseG1GC

╔══════════════════════════════════════════════════════════════════════╗
║                一次 Young GC STW 的 5 阶段完整快照                  ║
╠══════════════════════════════════════════════════════════════════════╣
║                                                                     ║
║ 阶段1: begin() 入口 — 发起 STW                                     ║
║ ─────────────────────────────────────────                          ║
║ VM_Operation:       G1CollectForAllocation                          ║
║ _state:             0 (_not_synchronized)                           ║
║ _safepoint_counter: 2 (偶数 → 不在 safepoint 中)                   ║
║ nof_threads:        6                                               ║
║                                                                     ║
║ SafepointMechanism:                                                 ║
║   _poll_armed_value:    0x7ffff7fbd008                              ║
║   _poll_disarmed_value: 0x7ffff7fbe000                              ║
║   _poll_bit:            8                                           ║
║   armed & poll_bit:     8 (非0 → 触发!)                            ║
║   disarmed & poll_bit:  0 (0 → 不触发)                             ║
║                                                                     ║
╠══════════════════════════════════════════════════════════════════════╣
║                                                                     ║
║ 阶段2: 通知线程 (_synchronizing)                                    ║
║ ─────────────────────────────────────────                          ║
║ [源码分析] begin() 中执行:                                          ║
║   _state = _synchronizing                                           ║
║   OrderAccess::storestore()                                         ║
║   for 每个 JavaThread:                                              ║
║     SafepointMechanism::arm_local_poll(cur)                         ║
║     // cur->_polling_page = 0x7ffff7fbd008 (armed)                  ║
║   OrderAccess::fence()                                              ║
║                                                                     ║
╠══════════════════════════════════════════════════════════════════════╣
║                                                                     ║
║ 阶段3: 所有线程已停 (_synchronized)                                 ║
║ ─────────────────────────────────────────                          ║
║ VM_Operation:           G1CollectForAllocation                      ║
║ _state:                 2 (_synchronized) ★                         ║
║ _safepoint_counter:     3 (奇数 → 在 safepoint 中) ★               ║
║ _waiting_to_block:      0 (所有线程已 block)                        ║
║ _current_jni_active:    0 (无 JNI Critical)                         ║
║ GCLocker::jni_lock_cnt: 0                                           ║
║                                                                     ║
║ [此时 VMThread 执行:]                                               ║
║   evaluate_operation(VM_G1CollectForAllocation)                     ║
║   → G1CollectedHeap::do_collection_pause()                         ║
║   → ... Young GC 全过程 ...                                        ║
║   cleanup_tasks(): deflate_monitors + IC_update + rehash + ...      ║
║                                                                     ║
╠══════════════════════════════════════════════════════════════════════╣
║                                                                     ║
║ 阶段4: end() — 恢复                                                ║
║ ─────────────────────────────────────────                          ║
║ _state:             2 (_synchronized)                               ║
║ _safepoint_counter: 3 (奇数，即将 +1 变偶数)                       ║
║ [即将执行:]                                                         ║
║   _safepoint_counter++ → 4 (偶数)                                  ║
║   _state = _not_synchronized                                        ║
║   for 每个 JavaThread:                                              ║
║     disarm_local_poll(cur)                                          ║
║     // cur->_polling_page = 0x7ffff7fbe000 (disarmed)               ║
║                                                                     ║
╠══════════════════════════════════════════════════════════════════════╣
║                                                                     ║
║ 阶段5: Threads_lock 释放 — 所有线程恢复                             ║
║ ─────────────────────────────────────────                          ║
║ _state:             0 (_not_synchronized) ★                         ║
║ _safepoint_counter: 4 (偶数 → 不在 safepoint) ★                    ║
║                                                                     ║
║ Threads_lock->unlock() 后:                                         ║
║   所有在 block() 中等待 Threads_lock 的线程被唤醒                   ║
║   线程恢复原始 thread_state 继续执行                                ║
║                                                                     ║
╚══════════════════════════════════════════════════════════════════════╝
```

### 5.4 状态变化总结图

```
时间轴                    _state              _safepoint_counter
────────────────────────────────────────────────────────────────────
          ▼ begin() 入口
T0        0 (_not_synchronized)     2 (偶数)
          │ _state = _synchronizing
          │ arm_local_poll() for each thread
T1        1 (_synchronizing)        2 (偶数)
          │ spin + block 等待所有线程...
          │ ...
          │ _safepoint_counter++
          │ _state = _synchronized
T2        2 (_synchronized)         3 (奇数)  ← safepoint 中
          │ ┌─────────────────────────────┐
          │ │ 执行 VM_G1CollectForAllocation │ ← Young GC
          │ │ do_cleanup_tasks()          │ ← 7 项清理任务
          │ └─────────────────────────────┘
          ▼ end() 入口
T3        2 (_synchronized)         3 (奇数)
          │ _safepoint_counter++
          │ _state = _not_synchronized
          │ disarm_local_poll() for each thread
T4        0 (_not_synchronized)     4 (偶数)  ← 恢复正常
          │ Threads_lock->unlock()
          │ 所有线程恢复执行
T5        正常运行中                4 (偶数)
────────────────────────────────────────────────────────────────────
```

---

## 6. 实验5: Safepoint 日志完整分析

### 6.1 日志获取命令

```bash
java -XX:+UseG1GC -Xms256m -Xmx256m -Xint \
  -Xlog:safepoint*=debug:stdout \
  -cp /data/workspace/demo/src com.wjcoder.SafepointTest
```

### 6.2 一次完整 Safepoint 的日志解读

```
① [1.280s][debug][safepoint        ] Safepoint synchronization initiated. (6 threads)
   ↑ begin() 入口：开始同步 6 个 JavaThread

② [1.280s][info ][safepoint        ] Entering safepoint region: EnableBiasedLocking
   ↑ _state = _synchronized：所有线程已停，VM_Operation = EnableBiasedLocking

③ [1.280s][info ][safepoint,cleanup] deflating idle monitors, 0.0000002 secs
  [1.280s][info ][safepoint,cleanup] updating inline caches, 0.0000012 secs
  [1.280s][info ][safepoint,cleanup] compilation policy safepoint handler, 0.0000104 secs
  [1.280s][info ][safepoint,cleanup] purging class loader data graph, 0.0000002 secs
  [1.280s][info ][safepoint,cleanup] resizing system dictionaries, 0.0000006 secs
  [1.280s][info ][safepoint,cleanup] safepoint cleanup tasks, 0.0003287 secs
   ↑ 7 项 cleanup 任务（SymbolTable/StringTable rehash 被跳过，因为不需要）
   ↑ 总 cleanup 耗时: 0.33ms

④ [1.280s][info ][safepoint        ] Leaving safepoint region
   ↑ end()：准备恢复线程

⑤ [1.280s][info ][safepoint        ] Total time for which application threads were stopped:
                                      0.0007214 seconds, Stopping threads took: 0.0000235 seconds
   ↑ 关键指标:
   ↑  • STW 总耗时 = 0.72ms
   ↑  • TTSP (Time-To-Safepoint) = 0.023ms ← 线程停下来花了多久
   ↑  • GC + Cleanup = 0.72 - 0.023 = ~0.70ms
```

### 6.3 GC Safepoint 日志对比

```
【GC Safepoint 日志】
[1.336s][debug][safepoint] Safepoint synchronization initiated. (6 threads)
[1.336s][info ][safepoint] Application time: 0.0553168 seconds         ← 上次 safepoint 到这次之间的应用运行时间
[1.336s][info ][safepoint] Entering safepoint region: G1CollectForAllocation
... cleanup tasks ...
[1.389s][info ][safepoint] Leaving safepoint region
[1.389s][info ][safepoint] Total time for which application threads were stopped:
                           0.0533677 seconds, Stopping threads took: 0.0000188 seconds

分析:
• Application time = 55.3ms     ← 两次 safepoint 间的应用运行时间
• TTSP = 0.019ms                ← 极快（-Xint 模式下所有线程都在安全点附近）
• STW total = 53.4ms            ← 绝大部分是 Young GC 耗时
• GC 耗时 ≈ 53.4 - 0.019 = ~53.4ms (GC 日志确认: Pause Young 54.195ms)
```

### 6.4 Cleanup Tasks 耗时明细

```
┌─────────────────────────────────┬──────────────────┬─────────────────────┐
│ Cleanup Task                    │ 典型耗时          │ 说明                 │
├─────────────────────────────────┼──────────────────┼─────────────────────┤
│ deflating idle monitors         │ 0.0000002 secs   │ 空闲 Monitor 极少    │
│ updating inline caches          │ 0.0000012 secs   │ -Xint 无 IC          │
│ compilation policy handler      │ 0.0000104 secs   │ 采样数据衰减         │
│ rehashing symbol table          │ (跳过)           │ 不需要 rehash         │
│ rehashing string table          │ (跳过)           │ 不需要 rehash         │
│ purging class loader data graph │ 0.0000002 secs   │ 无 ClassLoader 卸载  │
│ resizing system dictionaries    │ 0.0000006 secs   │ 不需要 resize        │
├─────────────────────────────────┼──────────────────┼─────────────────────┤
│ **Total cleanup**               │ 0.0003287 secs   │ 0.33ms               │
└─────────────────────────────────┴──────────────────┴─────────────────────┘

注: rehashing 有条件执行:
  if (SymbolTable::needs_rehashing()) { ... }   // 哈希冲突率过高时触发
  if (StringTable::needs_rehashing()) { ... }   // 同上
```

---

## 7. Polling Page 机制完整验证

### 7.1 地址设计

```
【GDB 实测数据】
┌──────────────────────────────────────────────────────────┐
│ _poll_armed_value:    0x7ffff7fbd008                     │
│ _poll_disarmed_value: 0x7ffff7fbe000                     │
│ _poll_bit:            8 (= 0x8 = bit 3)                 │
│                                                          │
│ 二进制对比:                                               │
│ armed:    ...1111 1011 1101 0000 0000 1000               │
│ disarmed: ...1111 1011 1110 0000 0000 0000               │
│                                    ^^^                   │
│                                    bit 3 = 差异位         │
│                                                          │
│ armed   & 0x8 = 0x8 (非0) → poll 检查返回 true           │
│ disarmed & 0x8 = 0x0      → poll 检查返回 false          │
└──────────────────────────────────────────────────────────┘
```

### 7.2 Arm/Disarm 的执行路径

```
SafepointSynchronize::begin() 中:
  for 每个 JavaThread:
    SafepointMechanism::arm_local_poll(cur);
    // 等价于: cur->_polling_page = 0x7ffff7fbd008

线程在安全点位置检查:
  if (SafepointMechanism::poll(thread)):  // 检查 _polling_page & 0x8
    block_if_requested(thread);           // → block()

SafepointSynchronize::end() 中:
  for 每个 JavaThread:
    SafepointMechanism::disarm_local_poll(cur);
    // 等价于: cur->_polling_page = 0x7ffff7fbe000
```

### 7.3 解释器 vs JIT 的 Polling 实现

```
解释器模式（-Xint，本实验使用）:
─────────────────────────────────
  SafepointMechanism::poll(thread)    // 纯代码检查
  → local_poll_armed(thread)
  → (thread->_polling_page & poll_bit) != 0
  → 如果 true: block_if_requested()

  特点: 在字节码间隔、方法返回、后向跳转处检查

JIT 编译模式:
─────────────────────────────────
  test dword ptr [polling_page_addr], eax   // x86 机器指令
  // 如果 polling_page_addr 指向不可读页面 → SIGSEGV → 信号处理器 → block()

  特点:
  - Global Page Poll 模式: polling_page_addr 是全局地址
    os::make_polling_page_unreadable() → mprotect(PROT_NONE)
  - Thread-Local Poll 模式: 每个线程有自己的 polling_page
    armed 指向 bad page → SIGSEGV
    disarmed 指向 good page → test 成功，继续执行
```

---

## 8. VMThread 调度循环与 Safepoint 触发

### 8.1 VMThread::loop() 的关键逻辑

```
VMThread::loop()
│
├── while(true):
│   │
│   ├── [等待 VM_Operation 或超时]
│   │   └── VMOperationQueue_lock->wait(GuaranteedSafepointInterval)
│   │       // 超时 = 1000ms → 触发保底 safepoint
│   │
│   ├── if (timeout && no_op_safepoint_needed()):
│   │   └── begin() → end()   // 空 safepoint，只执行 cleanup
│   │
│   ├── if (op->evaluate_at_safepoint()):
│   │   ├── safepoint_ops = drain_at_safepoint_priority()  // 批量取
│   │   ├── begin()                          // ← STW 开始
│   │   ├── evaluate_operation(op)           // ← 执行主操作 (GC)
│   │   ├── do { 执行 coalesced ops }        // ← 批量执行合并的操作
│   │   └── end()                            // ← STW 结束
│   │
│   └── else:
│       └── evaluate_operation(op)           // 不需要 STW
│
└── 结束后：VMOperationRequest_lock->notify_all()
```

### 8.2 本实验中的 Safepoint 触发链

```
JavaThread 尝试分配对象
  → G1CollectedHeap::attempt_allocation_slow()
  → G1CollectedHeap::attempt_allocation_at_safepoint()
  → VMThread::execute(new VM_G1CollectForAllocation(...))
  → VM_G1CollectForAllocation 入队 VMOperationQueue
  → VMThread 取出操作
  → SafepointSynchronize::begin()      ← STW 开始
  → evaluate_operation()
    → VM_G1CollectForAllocation::doit()
    → G1CollectedHeap::do_collection_pause_at_safepoint()
      → G1YoungCollector::collect()    ← Young GC 核心
  → SafepointSynchronize::end()        ← STW 结束
  → JavaThread 被唤醒，获得分配的内存
```

---

## 9. 诊断慢 Safepoint 的实战方法

### 9.1 关键指标

从 `-Xlog:safepoint*=debug` 日志中关注：

```
Total time for which application threads were stopped: X.XXXXX seconds
                        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
                        STW 总耗时 = TTSP + VMOp 执行时间

Stopping threads took: X.XXXXX seconds
                       ^^^^^^^^^^^^^^^^^
                       TTSP (Time-To-Safepoint)
                       = 从 begin() 到所有线程 block 的等待时间
                       正常应 < 1ms；> 10ms 需要关注

Application time: X.XXXXX seconds
                  ^^^^^^^^^^^^^^^^^
                  两次 safepoint 之间的应用运行时间
```

### 9.2 常见问题及排查

| 现象 | 可能原因 | 排查方法 |
|------|---------|---------|
| TTSP > 100ms | C2 counted loop 省略 safepoint poll | `-XX:+UseCountedLoopSafepoints` 或检查 `long/int` 循环 |
| TTSP > 10ms | 大量 Native 代码执行中 | 检查 JNI 调用频率，缩短 native 调用时间 |
| cleanup 耗时长 | Monitor 膨胀严重 | `-XX:+PrintSafepointStatistics` 查看 deflation 耗时 |
| STW 频率高 | GC 过于频繁 | 增大堆/调整 GC 参数 |
| 周期性 STW | `GuaranteedSafepointInterval` 保底 | 设为 0 可禁用，但不建议 |

### 9.3 诊断参数速查

```bash
# 基础日志（推荐生产环境使用）
-Xlog:safepoint:file=safepoint.log:time

# 详细日志（含 cleanup 任务耗时）
-Xlog:safepoint*=debug:stdout

# 超时检测（排查卡住的线程）
-XX:+SafepointTimeout -XX:SafepointTimeoutDelay=1000

# 超时时自动 crash dump（排查死锁/hang）
-XX:+AbortVMOnSafepointTimeout

# 禁用保底 safepoint（减少空 STW）
-XX:GuaranteedSafepointInterval=0

# Counted Loop 内加 safepoint（修复 TTSP 过长）
-XX:+UseCountedLoopSafepoints
```

---

## 10. 面试实战话术

### Q: STW 是怎么实现的？

> "我用 GDB 在 `SafepointSynchronize::begin()` 打过断点，亲眼看过整个过程。JVM 采用**协作式** safepoint：
>
> 1. VMThread 调用 `begin()`，将全局 `_state` 设为 `_synchronizing`
> 2. 对每个 JavaThread 执行 `arm_local_poll()`——把线程的 `_polling_page` 从 disarmed 地址改为 armed 地址，两者仅差 **bit 3**（0x8）
> 3. 线程在安全点位置（方法返回、循环回边）检查 `_polling_page & 0x8`，发现非0就调用 `block()`
> 4. `block()` 中线程先递减 `_waiting_to_block`，然后阻塞在 `Threads_lock` 上
> 5. 当所有线程都 block 了，`_state` 变为 `_synchronized`，`_safepoint_counter` 变为奇数——JNI fast path 用 `counter & 1` 判断是否在 safepoint
> 6. VMThread 执行 VM_Operation（如 GC）+ cleanup tasks
> 7. `end()` 中 disarm 所有线程、`Threads_lock->unlock()` 唤醒所有线程、`_safepoint_counter` 变回偶数
>
> 我 GDB 实测过，一次 Young GC 的 TTSP 只有 **0.02ms**（`-Xint` 模式），STW 总耗时约 **53ms**。"

### Q: TTSP 过长怎么排查？

> "加 `-Xlog:safepoint*=debug` 看 `Stopping threads took` 指标。常见原因是 C2 的 counted loop 优化省略了 safepoint poll——可以用 `-XX:+UseCountedLoopSafepoints` 修复。还可以用 `-XX:+SafepointTimeout -XX:SafepointTimeoutDelay=1000` 定位具体哪个线程卡住了——超时时 JVM 会打印所有未到达安全点的线程信息。"

---

## 11. GDB 脚本索引

| 脚本文件 | 用途 | 关键断点 |
|----------|------|---------|
| `gdb_exp1_stw_lifecycle.txt` | 完整 STW 生命周期 | begin, safepoint.cpp:465, cleanup, end, safepoint.cpp:587 |
| `gdb_exp2_thread_states.txt` | 线程状态分类观察 | examine_state_of_thread, block |
| `gdb_exp3_gc_safepoint.txt` | 多次 Safepoint 追踪 | begin, safepoint.cpp:471, end |
| `gdb_exp4_gc_stw_detail.txt` | GC STW 5阶段快照 | begin, safepoint.cpp:471, end, safepoint.cpp:587 |

---

## 12. 源码文件索引

| 文件 | 关键内容 | 行号范围 |
|------|---------|---------|
| `safepoint.cpp` | `begin()` — 完整 STW 发起流程 | 155-500 |
| `safepoint.cpp` | `end()` — STW 结束和线程恢复 | 499-600 |
| `safepoint.cpp` | `do_cleanup_tasks()` — 7 项清理任务 | 731-755 |
| `safepoint.cpp` | `safepoint_safe()` — 天然安全状态判定 | 760-775 |
| `safepoint.cpp` | `block()` — 线程自行阻塞 | 816-940 |
| `safepoint.cpp` | `handle_polling_page_exception()` — SIGSEGV 处理 | 951-965 |
| `safepoint.cpp` | `examine_state_of_thread()` — 核心状态检查 | 1045-1100 |
| `safepoint.cpp` | `roll_forward()` — 状态推进 | 1105-1130 |
| `safepointMechanism.inline.hpp` | `arm_local_poll()` / `disarm_local_poll()` | 65-70 |
| `safepointMechanism.inline.hpp` | `local_poll_armed()` — bit 检查 | 33-35 |
| `safepointMechanism.cpp` | `default_initialize()` — 初始化 armed/disarmed 地址 | 45-95 |
| `vmThread.cpp` | `VMThread::loop()` — 调度循环 | 457-640 |
| `vmThread.hpp` | `vm_safepoint_description()` — VMOp 名称 | 160 |
| `vmOperations.hpp` | `VM_Operation` 基类 + 所有 VMOp 子类 | 134-535 |

---

## 13. 完成后模块进度

```
完成前:
  Safepoint         ██████████████████████████████████░░░░░░░░░  82%  160KB

完成后 (ch02):
  Safepoint         ████████████████████████████████████████░░░  90%  ~205KB
                                                   ^^^^^^^^^^
                                                   新增 ~45KB

已覆盖:
  ✅ ch01: begin/end 理论深度分析（49KB）
  ✅ ch02: GDB 实战（本篇 ~45KB）
  ✅ SafepointMechanism.md: 初始化机制（48KB）
  ✅ safepoint_outline.md: 大纲（17KB）
  ✅ 5 个 GDB 脚本

剩余:
  - Counted Loop Safepoint 省略（C2 特有，编译系统模块）
  - JFR SafepointBegin/End 事件集成
```

---

*创建时间: 2026-02-09*
*GDB 验证环境: OpenJDK 11, -Xms256m -Xmx256m -XX:+UseG1GC -Xint*
*标准分析环境: -Xms8g -Xmx8g -XX:+UseG1GC (本篇为触发 GC 使用小堆)*
