# 第6章：Safepoint 机制插桩结果（完整版）

> 基于 OpenJDK 11 源码插桩验证
> 标准环境：`-Xms8g -Xmx8g -XX:+UseG1GC -Xint`
> 插桩文件：`safepoint.cpp` / `safepointMechanism.cpp` / `suspendibleThreadSet.cpp`

---

## 6.1 插桩位置总览（12 个探针）

| 探针 ID | 文件 | 位置 | 验证内容 |
|---------|------|------|---------|
| `SafepointMechanism::init` | `safepointMechanism.cpp` | `default_initialize()` | 轮询页类型、armed/disarmed 值、poll_bit |
| `STS::join` | `suspendibleThreadSet.cpp` | `join()` | 并发 GC 线程加入可暂停集合 |
| `STS::leave` | `suspendibleThreadSet.cpp` | `leave()` | 并发 GC 线程离开集合 |
| `STS::yield` | `suspendibleThreadSet.cpp` | `yield()` 进入等待前 | 并发 GC 线程响应暂停请求 |
| `STS::yield_resume` | `suspendibleThreadSet.cpp` | `yield()` 恢复后 | 并发 GC 线程从暂停中恢复 |
| `STS::synchronize` | `suspendibleThreadSet.cpp` | `synchronize()` 入口 | VMThread 请求暂停所有并发 GC 线程 |
| `STS::synchronize_done` | `suspendibleThreadSet.cpp` | `synchronize()` 完成 | 所有并发 GC 线程已暂停 |
| `STS::desynchronize` | `suspendibleThreadSet.cpp` | `desynchronize()` | VMThread 恢复所有并发 GC 线程 |
| `begin` | `safepoint.cpp` | `begin()` 入口 | VM_Operation 名称、需停止线程数 |
| `phase1_done` | `safepoint.cpp` | arm 轮询页后 | 轮询页已 armed，仍在运行的线程数 |
| `phase2_done` | `safepoint.cpp` | 所有线程停止后 | TTSP（Time-To-Safepoint）、计数器 |
| `end` | `safepoint.cpp` | `end()` 末尾 | STW 结束，计数器 |
| `block` | `safepoint.cpp` | `block()` | Java 线程主动阻塞（前5次） |
| `block_if_requested_slow` | `safepointMechanism.cpp` | `block_if_requested_slow()` | 线程检测到轮询页触发（前5次） |

---

## 6.2 探针1：SafepointMechanism 初始化

### 实际输出

```
[PROBE-28] SafepointMechanism::init: type=thread_local_poll
  poll_armed=0x00007f7953b48008
  poll_disarmed=0x00007f7953b49000
  poll_bit=0x0000000000000008
```

### 数据解读

| 字段 | 值 | 含义 |
|------|-----|------|
| `type` | `thread_local_poll` | JDK 11 默认机制，每线程独立轮询标志 |
| `poll_armed` | `0x...8008` | 末位 bit3=1（`poll_bit=8`），线程读到此值 → 进入 block |
| `poll_disarmed` | `0x...9000` | 末位 bit3=0，线程读到此值 → 继续执行 |
| `poll_bit` | `0x8`（= 8） | 第 3 位（bit3）是 armed 标志位 |

**关键设计**：`poll_armed` 和 `poll_disarmed` 指向同一个 4KB 页内的两个不同偏移（`0x8008` vs `0x9000`），通过 bit3 区分 armed/disarmed 状态。VMThread arm 线程时，只需将该线程的 `_polling_page` 字段从 `poll_disarmed` 改为 `poll_armed`，无需任何系统调用。

---

## 6.3 探针2：STS（SuspendibleThreadSet）生命周期

### 实际输出（节选）

```
[PROBE-28] STS::join: tid=25102 nthreads=1 time_ns=1187511319732
[PROBE-28] STS::leave: tid=25102 nthreads=0 suspend_all=0 time_ns=1187511342023
[PROBE-28] STS::join: tid=25102 nthreads=1 time_ns=1187811420840
[PROBE-28] STS::leave: tid=25102 nthreads=0 suspend_all=0 time_ns=1187811435718
...（每 300ms 一次，对应 G1 并发标记线程的周期性工作）
```

### 数据解读

**只有 1 个线程（tid=25102）反复 join/leave**，这是 G1 的 **ConcurrentMarkThread**（并发标记线程）。

| 观察 | 含义 |
|------|------|
| `nthreads=1`（join 后） | 同一时刻只有 1 个并发 GC 线程在 STS 中 |
| `nthreads=0`（leave 后） | 并发 GC 线程工作完毕后立即离开 |
| `suspend_all=0`（leave 时） | leave 时没有 STW 请求，正常退出 |
| 周期约 300ms | 对应 G1 并发标记的工作间隔 |

**STS 的作用**：并发 GC 线程在执行并发工作时必须 join STS，这样 VMThread 发起 STW 时可以通过 `STS::synchronize()` 等待所有并发 GC 线程暂停，确保 STW 期间没有并发 GC 线程在修改堆。

---

## 6.4 探针3：STW 与 STS 协作时序

### 实际输出（一次完整 STW）

```
# ① VMThread 发起 STW
[PROBE-28] begin: op=G1CollectForAllocation threads=6 time_ns=1190794500588

# ② VMThread 请求暂停并发 GC 线程（此时 nthreads=0，已经没有并发 GC 线程在运行）
[PROBE-28] STS::synchronize: nthreads=0 time_ns=1190794520636
[PROBE-28] STS::synchronize_done: already_synchronized nthreads=0 time_ns=1190794523741

# ③ arm 轮询页，等待 Java 线程停止
[PROBE-28] phase1_done: polling_armed still_running=6 time_ns=1190794539341

# ④ 所有线程停止，TTSP=0.046ms
[PROBE-28] phase2_done: all_at_safepoint counter=3 ttsp_ms=0.046 time_ns=1190794546434

# ⑤ STW 结束（G1 YoungGC 执行了约 860ms）
[PROBE-28] end: counter=3 time_ns=1191654229445

# ⑥ 恢复并发 GC 线程
[PROBE-28] STS::desynchronize: nthreads=0 time_ns=1191654246687

# ⑦ 并发 GC 线程重新 join，继续并发工作
[PROBE-28] STS::join: tid=25102 nthreads=1 time_ns=1191654285039
[PROBE-28] STS::leave: tid=25102 nthreads=0 suspend_all=0 time_ns=1191654328951
```

### 时序图

```
VMThread                ConcurrentMarkThread        Java线程1~6
    |                           |                       |
    |                    join() |                       |
    |                    nthreads=1                     |
    |                    leave()|                       |
    |                    nthreads=0                     |
    |                           |                       |
    | begin(G1CollectForAlloc)  |                       |
    |                           |                       |
    | STS::synchronize()        |                       |
    | nthreads=0 → already_sync |                       |
    |                           |                       |
    | arm per-thread poll flags |                       |
    | phase1_done still_run=6   |                       |
    |                           |                       |
    |                           |          block_if_requested_slow()
    |                           |          global_poll=1 → block()
    |                           |          等待...
    |                           |                       |
    | phase2_done ttsp=0.046ms  |                       |
    |                           |                       |
    | 执行 G1 YoungGC (~860ms)  |                       |
    |                           |                       |
    | end()                     |                       |
    | STS::desynchronize()      |                       |
    |                           |                       |
    |                    join() |          恢复执行      |
    |                    nthreads=1                     |
    |                    leave()|                       |
    |                    nthreads=0                     |
```

---

## 6.5 探针4：Java 线程阻塞路径

### 实际输出

```
[PROBE-28] block_if_requested_slow[1]: tid=26813 global_poll=1 has_handshake=0 time_ns=1286497670614
[PROBE-28] block[1]: tid=26813 state=7 waiting_to_block=1
[PROBE-28] block_if_requested_slow[2]: tid=26813 global_poll=1 has_handshake=0 time_ns=1287504154024
[PROBE-28] block[2]: tid=26813 state=7 waiting_to_block=1
[PROBE-28] block_if_requested_slow[3]: tid=26813 global_poll=1 has_handshake=0 time_ns=1288517014257
[PROBE-28] block[3]: tid=26813 state=7 waiting_to_block=1
[PROBE-28] block_if_requested_slow[4]: tid=26813 global_poll=1 has_handshake=0 time_ns=1289531539221
[PROBE-28] block[4]: tid=26813 state=7 waiting_to_block=1
[PROBE-28] block_if_requested_slow[5]: tid=26813 global_poll=1 has_handshake=0 time_ns=1289686767553
[PROBE-28] block[5]: tid=26813 state=7 waiting_to_block=1
```

### 数据解读

| 字段 | 值 | 含义 |
|------|-----|------|
| `global_poll=1` | 1 | 全局轮询标志为 true，触发阻塞 |
| `has_handshake=0` | 0 | 不是 Handshake 请求，是真正的 SafePoint |
| `state=7` | 7 = `_thread_in_Java` | 线程在执行 Java 字节码时被停止 |
| `waiting_to_block=1` | 1 | 还有 1 个线程未到达 SafePoint |

**阻塞路径**：
```
字节码执行 → 安全点检查（每条字节码）
    → 读取 per-thread poll 标志
    → 发现 armed（bit3=1）
    → 调用 SafepointMechanism::block_if_requested_slow()
    → global_poll=1 → SafepointSynchronize::block()
    → 线程挂起，等待 STW 结束
```

---

## 6.6 完整数据汇总（5次 STW）

| # | VM_Operation | 线程数 | TTSP | STW 总耗时 | STS::synchronize 耗时 |
|---|-------------|--------|------|-----------|----------------------|
| 1 | EnableBiasedLocking | 6 | 0.074 ms | ~0.6 ms | ~3 μs（already_sync） |
| 2 | G1CollectForAllocation | 6 | 0.046 ms | ~860 ms | ~3 μs（already_sync） |
| 3 | G1CollectForAllocation | 6 | 0.052 ms | ~576 ms | ~3 μs（already_sync） |
| 4 | G1CollectForAllocation | 6 | 0.058 ms | ~248 ms | ~3 μs（already_sync） |
| 5 | G1CollectForAllocation | 6 | 0.055 ms | ~202 ms | ~3 μs（already_sync） |

**TTSP 统计（5次）：**
- 最小：0.046 ms
- 最大：0.074 ms
- 平均：约 0.057 ms（比旧版 0.25ms 更精确，因为新探针在 phase2_done 处记录）

---

## 6.7 关键结论

### 结论1：STS::synchronize 几乎零耗时（already_synchronized）

**数据**：所有 5 次 STW 的 `STS::synchronize_done` 都显示 `already_synchronized nthreads=0`。

**原因**：G1 的 ConcurrentMarkThread 采用 **短暂 join/leave 模式**——它只在执行并发标记任务时 join STS，任务完成后立即 leave。因此 VMThread 发起 STW 时，并发 GC 线程往往已经不在 STS 中（`nthreads=0`），`synchronize()` 直接返回，耗时约 3 μs。

**对比**：如果并发 GC 线程正在 STS 中（`nthreads=1`），VMThread 需要等待它调用 `yield()` 主动让步，这会增加 TTSP。

### 结论2：TTSP 极短（约 0.05ms），比旧版数据更精确

**数据**：新探针在 `phase2_done` 处记录 TTSP，平均约 0.057ms，比旧版（0.25ms）更精确。

**原因**：旧版探针在 `_state = _synchronized` 之后记录，包含了一些额外开销；新版探针直接在 `phase2_done` 处记录，更接近真实 TTSP。

**解释**：`-Xint`（纯解释执行）下每条字节码都有安全点检查，线程响应极快。

### 结论3：Java 线程阻塞时 state=7（_thread_in_Java）

**数据**：所有 5 次 `block` 探针显示 `state=7`。

**含义**：`state=7` = `_thread_in_Java`，表示线程在执行 Java 字节码时被停止。这是最常见的情况——线程在解释执行字节码的安全点检查处发现 armed 标志，进入 block。

### 结论4：SafepointMechanism 使用 bit3 区分 armed/disarmed

**数据**：
- `poll_armed = 0x...8008`（bit3=1）
- `poll_disarmed = 0x...9000`（bit3=0）
- `poll_bit = 0x8`

**设计精妙之处**：两个值都是合法的内存地址（指向同一个 4KB 页内），但通过 bit3 区分状态。线程只需做一次位运算 `value & poll_bit` 即可判断是否需要阻塞，无需任何系统调用或内存访问。

### 结论5：Safepoint 计数器奇偶交替

**数据**：`counter=1, 3, 5, 7, 9`（全为奇数，在 STW 期间）

**含义**：`_safepoint_counter` 在 `begin()` 时 +1（变奇数），在 `end()` 时再 +1（变偶数）。奇数 = 在 STW 中；偶数 = 不在 STW 中。这是经典的"版本号"技巧，用于无锁判断当前是否在 SafePoint。

---

## 6.8 与理论预期对比

| 验证问题 | 理论预期 | 实际结果 | 是否符合 |
|---------|---------|---------|---------|
| 轮询机制类型？ | JDK 11 默认 thread_local_poll | thread_local_poll | ✅ |
| poll_bit 是哪一位？ | bit3（值=8） | `poll_bit=0x8` | ✅ |
| STS::synchronize 耗时？ | 并发 GC 线程不在 STS 中时应极短 | ~3μs（already_sync） | ✅ |
| Java 线程阻塞时的 state？ | _thread_in_Java（=7） | `state=7` | ✅ |
| TTSP 在 -Xint 下？ | 极短（< 0.1ms） | 0.046~0.074ms | ✅ |
| Safepoint 计数器奇偶？ | STW 中为奇数 | 1,3,5,7,9 | ✅ |
| STS::yield 是否出现？ | 并发 GC 线程在 STS 中时才出现 | 未出现（nthreads=0 时 STW） | ✅ |
| block_if_requested_slow 触发条件？ | global_poll=1 时触发 SafePoint | `global_poll=1` | ✅ |
