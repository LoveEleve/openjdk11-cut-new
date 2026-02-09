# Young GC GDB 调试指南

## 1. Young GC 能否用 GDB 调试？

**可以！** 但需要注意以下几点：

### 1.1 调试特点

| 方面 | 说明 |
|------|------|
| **时机** | GC 是自动触发的，需要设置断点等待 |
| **线程** | GC 在 VMThread 中执行，需要切换到 VMThread |
| **并发** | 其他 Java 线程被暂停，调试相对简单 |
| **频率** | 可以控制堆大小和分配速率来触发 GC |

### 1.2 调试策略

```
策略 1: 设置断点等待 GC 触发
─────────────────────────────────
break G1CollectedHeap::do_collection_pause_at_safepoint
run -Xms8g -Xmx8g -XX:+UseG1GC MyApp
# 当 Eden 满时自动触发 GC，断点命中

策略 2: 强制触发 GC
─────────────────────────────────
# 在 Java 代码中调用 System.gc()
# 或在 GDB 中调用:
call Universe::heap()->collect(GCCause::_java_lang_system_gc)

策略 3: 控制 GC 频率
─────────────────────────────────
# 使用小堆快速触发 GC
run -Xms32m -Xmx32m -XX:+UseG1GC MyApp
```

### 1.3 关键断点位置

```gdb
# 1. GC 入口
break G1CollectedHeap::do_collection_pause_at_safepoint

# 2. 安全点开始
break SafepointSynchronize::begin

# 3. 安全点结束  
break SafepointSynchronize::end

# 4. 疏散阶段
break G1CollectedHeap::evacuate_collection_set

# 5. GC 退出
break VM_G1CollectForAllocation::doit
```

## 2. 实际调试示例

### 2.1 查看 GC 触发时的线程状态

```gdb
# 当断点在 do_collection_pause_at_safepoint 命中时
(gdb) info threads
  Id   Target Id         Frame
  1    Thread 0x7ffff7...  pthread_cond_wait
  2    Thread 0x7ffff6...  G1CollectedHeap::do_collection_pause_at_safepoint
  3    Thread 0x7ffff5...  pthread_cond_wait  <-- Java 线程被暂停
  4    Thread 0x7ffff4...  pthread_cond_wait  <-- Java 线程被暂停

# 切换到 VMThread
(gdb) thread 2

# 查看当前线程
(gdb) print Thread::current()
$1 = (Thread *) 0x7ffff003f000  <-- VMThread
```

### 2.2 查看 Collection Set

```gdb
# 查看回收集合中的 Region 数量
(gdb) print collection_set()->region_length()
$2 = 12  <-- 本次 GC 要回收 12 个 Region

# 查看 Eden 区域
(gdb) print _eden.length()
$3 = 8   <-- Eden 有 8 个 Region

# 查看 Survivor 区域
(gdb) print _survivor.length()
$4 = 2   <-- Survivor 有 2 个 Region
```

### 2.3 单步跟踪 GC 流程

```gdb
# 在 GC 入口设置断点
break G1CollectedHeap::do_collection_pause_at_safepoint

# 运行程序
run -Xms100m -Xmx100m -XX:+UseG1GC -cp /data/workspace/demo MyApp

# 断点命中后，单步跟踪
(gdb) step
(gdb) next
...

# 查看当前执行的代码位置
(gdb) list
```

## 3. 编写测试程序触发 GC

```java
// /data/workspace/demo/GCTest.java
public class GCTest {
    public static void main(String[] args) {
        System.out.println("Starting GC test...");
        
        // 触发 Young GC
        for (int i = 0; i < 1000; i++) {
            byte[] allocation = new byte[1024 * 1024]; // 1MB
        }
        
        System.out.println("Triggering System.gc()...");
        System.gc(); // 强制触发 GC
        
        System.out.println("Done!");
    }
}
```

## 4. 完整 GDB 脚本

```gdb
# gdb_young_gc.txt
set pagination off
set print pretty on

# 设置断点
break G1CollectedHeap::do_collection_pause_at_safepoint
break SafepointSynchronize::begin
break SafepointSynchronize::end

# 运行程序
run -Xms100m -Xmx100m -XX:+UseG1GC -cp /data/workspace/demo GCTest

# 当 GC 触发时
printf "\n========== GC 触发 ==========\n"
print Thread::current()->name()

# 继续到安全点开始
continue
printf "\n========== Safepoint Begin ==========\n"

# 继续到安全点结束
continue
printf "\n========== Safepoint End ==========\n"

# 继续
continue
```

## 5. 调试技巧总结

| 技巧 | 命令 | 用途 |
|------|------|------|
| 查看堆信息 | `print Universe::heap()` | 查看堆对象 |
| 查看 GC 原因 | `print gc_cause()` | 了解为什么触发 GC |
| 查看线程状态 | `info threads` | 查看所有线程 |
| 查看 Region | `print _hrm` | 查看 HeapRegionManager |
| 强制 GC | `call System.gc()` | 手动触发 GC |

## 6. 注意事项

1. **超时问题**: GDB 调试可能导致 GC 超时，可以调大超时参数
   ```bash
   -XX:SafepointTimeoutDelay=60000
   ```

2. **多线程**: GC 是多线程的，注意查看 worker 线程

3. **日志配合**: 建议同时开启 GC 日志
   ```bash
   -Xlog:gc*:file=gc.log
   ```
