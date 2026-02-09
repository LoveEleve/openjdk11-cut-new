# 6. 性能计数器初始化

> 分析 JVM 性能数据（PerfData）机制，`jstat`、`jconsole` 等工具的数据来源

---

## 1. 源码分析

```cpp
// src/hotspot/share/memory/universe.cpp:792-793
MetaspaceCounters::initialize_performance_counters();
CompressedClassSpaceCounters::initialize_performance_counters();
```

### 1.1 MetaspaceCounters 初始化

```cpp
// src/hotspot/share/memory/metaspaceCounters.cpp:83
void MetaspaceCounters::initialize_performance_counters() {
  if (UsePerfData) {  // 默认为 true
    assert(_perf_counters == NULL, "Should only be initialized once");
    
    size_t min_capacity = 0;
    _perf_counters = new MetaspacePerfCounters(
        "metaspace",                    // 命名空间
        min_capacity,                   // = 0
        capacity(),                     // MetaspaceUtils::committed_bytes()
        max_capacity(),                 // MetaspaceUtils::reserved_bytes()
        used()                          // MetaspaceUtils::used_bytes()
    );
  }
}
```

### 1.2 创建的计数器

```cpp
// src/hotspot/share/memory/metaspaceCounters.cpp:51
MetaspacePerfCounters(const char* ns, size_t min_capacity, 
                      size_t curr_capacity, size_t max_capacity, size_t used) {
  // 常量（只写一次）
  create_constant(ns, "minCapacity", min_capacity, THREAD);
  
  // 变量（可更新）
  _capacity     = create_variable(ns, "capacity", curr_capacity, THREAD);
  _max_capacity = create_variable(ns, "maxCapacity", max_capacity, THREAD);
  _used         = create_variable(ns, "used", used, THREAD);
}
```

---

## 2. 创建的 8 个计数器

| 计数器路径 | 类型 | 说明 |
|-----------|------|------|
| `sun.gc.metaspace.minCapacity` | Constant | 最小容量（= 0） |
| `sun.gc.metaspace.capacity` | Variable | 当前已提交大小 |
| `sun.gc.metaspace.maxCapacity` | Variable | 最大保留大小 |
| `sun.gc.metaspace.used` | Variable | 当前已使用大小 |
| `sun.gc.compressedclassspace.minCapacity` | Constant | 压缩类空间最小容量 |
| `sun.gc.compressedclassspace.capacity` | Variable | 压缩类空间已提交 |
| `sun.gc.compressedclassspace.maxCapacity` | Variable | 压缩类空间最大 |
| `sun.gc.compressedclassspace.used` | Variable | 压缩类空间已使用 |

---

## 3. PerfData 共享内存机制

### 3.1 核心原理

```
┌───────────────────────────────────────────────────────────────────────────────┐
│                         PerfData 共享内存机制                                 │
├───────────────────────────────────────────────────────────────────────────────┤
│                                                                               │
│   JVM 进程                                       监控工具 (jstat/jconsole)   │
│   ┌─────────────────────┐                       ┌─────────────────────────┐  │
│   │     JVM 内部        │                       │    外部进程              │  │
│   │                     │                       │                         │  │
│   │  PerfDataManager    │                       │   mmap() 只读映射       │  │
│   │        │            │                       │        │                │  │
│   │        ▼            │                       │        ▼                │  │
│   │  ┌───────────────┐  │   mmap() 共享映射     │  ┌───────────────────┐  │  │
│   │  │ 虚拟地址空间  │  │ ◀───────────────────▶ │  │   虚拟地址空间    │  │  │
│   │  │ (读写)        │  │                       │  │   (只读)          │  │  │
│   │  └───────┬───────┘  │                       │  └─────────┬─────────┘  │  │
│   │          │          │                       │            │            │  │
│   └──────────┼──────────┘                       └────────────┼────────────┘  │
│              │                                               │               │
│              └───────────────────┬───────────────────────────┘               │
│                                  │                                           │
│                                  ▼                                           │
│                    ┌─────────────────────────────────┐                       │
│                    │  /tmp/hsperfdata_<user>/<pid>   │                       │
│                    │  (磁盘文件 / tmpfs 内存文件)    │                       │
│                    │  大小: 32KB                     │                       │
│                    └─────────────────────────────────┘                       │
│                                                                               │
│   优点：                                                                      │
│   1. 监控工具无需与 JVM 交互                                                 │
│   2. 零拷贝 - 直接读取共享内存                                               │
│   3. JVM 更新数据无需通知监控工具                                            │
│   4. 极低开销                                                                │
│                                                                               │
└───────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 共享内存文件

```bash
# 查看共享内存文件
$ ls -la /tmp/hsperfdata_$USER/
total 36
drwx------ 2 root root    60 Feb  5 10:00 .
drwxrwxrwt 1 root root  4096 Feb  5 10:00 ..
-rw------- 1 root root 32768 Feb  5 10:00 12345

# 文件名就是 JVM 的 PID
# 大小固定 32KB
```

### 3.3 文件创建代码

```cpp
// src/hotspot/os/linux/perfMemory_linux.cpp
_start = create_shared_memory(size);

// 内部调用
mapAddress = (char*)::mmap(
    (char*)0,           // 由系统选择地址
    size,               // 32KB
    PROT_READ|PROT_WRITE,
    MAP_SHARED,         // 关键！共享映射
    fd,                 // /tmp/hsperfdata_<user>/<pid> 的文件描述符
    0
);
```

---

## 4. PerfData 类层次

```
PerfData (抽象基类)
    │
    ├── PerfLong (抽象)
    │       │
    │       ├── PerfLongConstant (别名: PerfConstant)
    │       │       └── 只写一次，如 minCapacity
    │       │
    │       └── PerfLongVariant (抽象)
    │               │
    │               ├── PerfLongVariable (别名: PerfVariable)
    │               │       └── 可随时更新，如 capacity/used
    │               │
    │               └── PerfLongCounter
    │                       └── 单调递增，如 GC 次数
    │
    └── PerfByteArray (抽象)
            │
            └── PerfString (抽象)
                    │
                    ├── PerfStringVariable
                    └── PerfStringConstant
                            └── 如 java.vm.name
```

---

## 5. 命名空间约定

```cpp
// src/hotspot/share/runtime/perfData.hpp:39
enum CounterNS {
  JAVA_NS,           // java.*     - 稳定，支持
  COM_NS,            // com.sun.*  - 不稳定，支持
  SUN_NS,            // sun.*      - 不稳定，不支持
  
  JAVA_GC,           // java.gc.*
  COM_GC,            // com.sun.gc.*
  SUN_GC,            // sun.gc.*   ← Metaspace 计数器在这里
  
  JAVA_CI,           // java.ci.*  (编译器)
  JAVA_CLS,          // java.cls.* (类加载器)
  JAVA_RT,           // java.rt.*  (运行时)
  JAVA_OS,           // java.os.*  (操作系统)
  JAVA_THREADS,      // java.threads.*
  // ...
};
```

---

## 6. 实际使用

### 6.1 jstat 命令

```bash
# 查看 Metaspace 统计
$ jstat -gc <pid>
 S0C    S1C    S0U    S1U      EC       EU        OC         OU       MC     MU    CCSC   CCSU
1024.0 1024.0  0.0   512.0  8192.0   4096.0   20480.0    8192.0   10240.0 9856.0 1280.0 1180.0

# MC  = Metaspace Capacity     ← sun.gc.metaspace.capacity
# MU  = Metaspace Used         ← sun.gc.metaspace.used
# CCSC = Compressed Class Space Capacity ← sun.gc.compressedclassspace.capacity
# CCSU = Compressed Class Space Used     ← sun.gc.compressedclassspace.used
```

### 6.2 jcmd 命令

```bash
# 查看所有性能计数器
$ jcmd <pid> PerfCounter.print

# 示例输出
sun.gc.metaspace.capacity=10485760
sun.gc.metaspace.maxCapacity=1073741824
sun.gc.metaspace.minCapacity=0
sun.gc.metaspace.used=9856000
sun.gc.compressedclassspace.capacity=1310720
sun.gc.compressedclassspace.maxCapacity=1073741824
sun.gc.compressedclassspace.minCapacity=0
sun.gc.compressedclassspace.used=1180000
```

### 6.3 直接读取共享内存

```bash
# 用 hexdump 查看原始数据
$ hexdump -C /tmp/hsperfdata_$USER/<pid> | head -20
```

---

## 7. 计数器更新

### 7.1 更新时机

```cpp
// src/hotspot/share/memory/metaspaceCounters.cpp:96
void MetaspaceCounters::update_performance_counters() {
  if (UsePerfData) {
    _perf_counters->update(capacity(), max_capacity(), used());
  }
}

// 调用位置（举例）：
// - GC 后
// - Metaspace 扩展后
// - 类加载后
```

### 7.2 StatSampler 周期采样

JVM 有一个后台线程 `StatSampler` 定期采样需要周期更新的计数器：

```cpp
// 采样间隔默认 50ms
PerfDataSamplingInterval = 50
```

---

## 8. JVM 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-XX:+UsePerfData` | true | 启用性能数据 |
| `-XX:-UsePerfData` | - | 禁用（关闭 /tmp/hsperfdata_*） |
| `-XX:+PerfDataSaveToFile` | false | 退出时保存到文件 |
| `-XX:PerfDataSamplingInterval=<ms>` | 50 | 采样间隔 |

```bash
# 禁用性能数据（安全场景/减少开销）
java -XX:-UsePerfData -jar app.jar

# 此时 /tmp/hsperfdata_<user>/<pid> 不会创建
# jstat 等工具无法工作
```

---

## 9. 内存布局示意

```
/tmp/hsperfdata_<user>/<pid>  (32KB)
┌─────────────────────────────────────────────────────────────────┐
│  Prologue (头部信息)                                            │
│  ├── magic: 0xcafec0c0                                          │
│  ├── byte_order: big/little endian                              │
│  ├── major_version, minor_version                               │
│  ├── accessible: 1 (可访问)                                     │
│  ├── used: 当前使用的字节数                                     │
│  ├── overflow: 是否溢出                                         │
│  ├── mod_time_stamp: 修改时间戳                                 │
│  └── entry_offset: 第一个条目偏移                               │
├─────────────────────────────────────────────────────────────────┤
│  Entry 1: sun.gc.metaspace.minCapacity                          │
│  ├── entry_length                                               │
│  ├── name_offset, name_length: "sun.gc.metaspace.minCapacity"   │
│  ├── vector_length: 1                                           │
│  ├── data_type: Long                                            │
│  ├── flags: Constant                                            │
│  ├── data_units: U_Bytes                                        │
│  └── data_value: 0                                              │
├─────────────────────────────────────────────────────────────────┤
│  Entry 2: sun.gc.metaspace.capacity                             │
│  └── ... (Variable, 值会更新)                                   │
├─────────────────────────────────────────────────────────────────┤
│  Entry 3: sun.gc.metaspace.maxCapacity                          │
│  └── ...                                                        │
├─────────────────────────────────────────────────────────────────┤
│  Entry 4: sun.gc.metaspace.used                                 │
│  └── ...                                                        │
├─────────────────────────────────────────────────────────────────┤
│  ... (更多计数器: GC 次数、编译时间、类加载数等)                │
├─────────────────────────────────────────────────────────────────┤
│  (未使用空间)                                                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 10. 与 jstat 的对应关系

```bash
jstat -gc <pid>
```

| jstat 列 | 计数器路径 | 说明 |
|---------|-----------|------|
| MC | `sun.gc.metaspace.capacity` | Metaspace Capacity |
| MU | `sun.gc.metaspace.used` | Metaspace Used |
| CCSC | `sun.gc.compressedclassspace.capacity` | Compressed Class Space Capacity |
| CCSU | `sun.gc.compressedclassspace.used` | Compressed Class Space Used |
| YGC | `sun.gc.collector.0.invocations` | Young GC 次数 |
| FGC | `sun.gc.collector.1.invocations` | Full GC 次数 |
| GCT | `sun.gc.collector.*.time` | GC 总时间 |

---

## 11. 设计要点总结

| 特性 | 说明 |
|------|------|
| **共享内存** | 使用 mmap 映射 `/tmp/hsperfdata_<user>/<pid>` |
| **零拷贝** | 监控工具直接读取，无需 JVM 交互 |
| **低开销** | JVM 更新只是写内存，无需 IPC |
| **条件编译** | `UsePerfData=false` 可完全禁用 |
| **自动清理** | JVM 退出时删除共享内存文件 |

---

## 12. 常见问题

### Q1: 为什么 /tmp/hsperfdata_* 目录会残留？

**A**: JVM 异常退出（kill -9）时，文件不会被清理。可以手动删除。

### Q2: 禁用 PerfData 有什么影响？

**A**: 
- `jstat`、`jconsole` 等工具无法获取数据
- 减少约 32KB 内存和少量 CPU 开销
- 某些安全场景建议禁用

### Q3: 为什么用共享内存而不是 JMX？

**A**: 
- 共享内存开销更低（无需 RMI 连接）
- 监控工具无需与 JVM 交互
- 即使 JVM 忙也能读取数据

---

## 13. GDB 验证

```gdb
# 在初始化处设断点
b MetaspaceCounters::initialize_performance_counters

# 查看创建的计数器
p MetaspaceCounters::_perf_counters
p MetaspaceCounters::_perf_counters->_capacity->_valuep
p MetaspaceCounters::_perf_counters->_used->_valuep
```

---

## 14. 小结

性能计数器是 JVM **可观测性**的基础：

```
universe_init()
      │
      └─▶ MetaspaceCounters::initialize_performance_counters()
               │
               └─▶ 创建 4 个 Metaspace 计数器
                    │
                    └─▶ 写入 /tmp/hsperfdata_<user>/<pid>
                              │
                              └─▶ jstat/jconsole 通过 mmap 读取
```

这是一个非常实用的机制，让外部工具能以**零开销**方式监控 JVM！
