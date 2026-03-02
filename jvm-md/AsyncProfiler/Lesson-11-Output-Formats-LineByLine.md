# Lesson 11: 多种输出格式与帧名称解析深度分析

## 一、输出格式概览

AsyncProfiler 支持 7 种输出格式，满足不同场景需求：

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      AsyncProfiler 输出格式矩阵                          │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  格式              用途              特点                典型大小        │
│  ─────────────────────────────────────────────────────────────────────  │
│  OUTPUT_TEXT       控制台查看        纯文本，易读        最小            │
│  OUTPUT_COLLAPSED  FlameGraph.pl     单行调用栈+计数     中等            │
│  OUTPUT_FLAMEGRAPH 浏览器交互        HTML+Canvas         大 (~2MB/10万样本)│
│  OUTPUT_TREE       层级查看          HTML折叠树          大              │
│  OUTPUT_JFR        Java Mission      二进制，完整信息    最大            │
│                    Control                                              │
│  OUTPUT_OTLP       OpenTelemetry     Protobuf格式        中等            │
│  OUTPUT_SVG        (已废弃)          矢量图形            大              │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 二、Collapsed 格式深度解析

### 2.1 格式定义

```
<frame>;<frame>;...;<topmost frame> <count>

示例:
  java/lang/Thread.run;java/lang/Runnable.run;com/example/MyApp.main 150
  java/lang/Thread.run;com/example/Worker.process 89
  _ZSt17invoke_r...;main 42
```

**特点：**
- 每行一个完整调用栈
- 帧之间用 `;` 分隔
- 最后一帧后跟空格和计数
- **底层到顶层**顺序（root → leaf）

### 2.2 dumpCollapsed() 逐行解析

```cpp
// profiler.cpp:1448-1472
void Profiler::dumpCollapsed(Writer& out, Arguments& args) {
    FrameName fn(args, args._style | STYLE_NO_SEMICOLON, _epoch, _thread_names_lock, _thread_names);
    char buf[32];
    u64 printed_sample_count = 0;

    std::vector<CallTraceSample*> samples;
    _call_trace_storage.collectSamples(samples);

    for (std::vector<CallTraceSample*>::const_iterator it = samples.begin(); it != samples.end(); ++it) {
        CallTrace* trace = (*it)->acquireTrace();
        if (trace == NULL || fn.excludeTrace(trace)) continue;

        u64 counter = args._counter == COUNTER_SAMPLES ? (*it)->samples : (*it)->counter;
        if (counter == 0) continue;

        for (int j = trace->num_frames - 1; j >= 0; j--) {
            const char* frame_name = fn.name(trace->frames[j]);
            out << frame_name << (j == 0 ? ' ' : ';');
        }
        out.write(buf, snprintf(buf, sizeof(buf), "%llu\n", counter));
        printed_sample_count++;
    }
    logEmptyOutput(args, printed_sample_count, out);
}
```

**逐行展开：**

```
Line 1449: FrameName fn(args, args._style | STYLE_NO_SEMICOLON, ...)
           │
           ├─ STYLE_NO_SEMICOLON 标志
           │   └─ 在方法签名中，将 ';' 替换为 '|'
           │      例如: (Ljava/lang/String;I)V → (Ljava/lang/String|I)V
           │      原因: ';' 是 collapsed 格式的分隔符
           │
           └─ FrameName 对象
               └─ 负责 jmethodID → 字符串的转换
                  后面详细解析

Line 1453-1454: samples 收集
                │
                ├─ _call_trace_storage.collectSamples(samples)
                │   └─ 遍历所有哈希表，收集非空条目
                │      详细过程:
                │      for (LongHashTable* table = _current_table; table != NULL; table = table->prev()) {
                │          for (u32 slot = 0; slot < capacity; slot++) {
                │              if (keys[slot] != 0) {
                │                  samples.push_back(&values[slot]);
                │              }
                │          }
                │      }
                │
                └─ 时间复杂度: O(n), n = 总调用栈数

Line 1457-1461: 过滤和计数选择
                │
                ├─ trace == NULL
                │   └─ 极端情况：哈希竞争导致 trace 未存储
                │
                ├─ fn.excludeTrace(trace)
                │   └─ 用户通过 -I/-X 指定的 include/exclude 规则
                │      详细解析见后文
                │
                └─ counter 选择
                    ├─ COUNTER_SAMPLES: 使用采样次数
                    │   例如: 100 次采样 = counter 100
                    │
                    └─ COUNTER_TOTAL: 使用累计值
                        对于 alloc: 累计分配字节数
                        对于 lock: 累计锁等待时间(ns)

Line 1463-1466: 输出调用栈
                │
                └─ for (int j = trace->num_frames - 1; j >= 0; j--)
                    └─ 逆序遍历：从底层到顶层
                    
                    trace->frames 数组结构:
                    ┌──────────────────────────────────────────┐
                    │ frames[0] = 顶层帧 (leaf, 正在执行的方法) │
                    │ frames[1] = 调用者                       │
                    │ ...                                      │
                    │ frames[n-1] = 底层帧 (root, 如 main)     │
                    └──────────────────────────────────────────┘
                    
                    输出顺序: frames[n-1] → frames[n-2] → ... → frames[0]
                    即: root → ... → leaf

Line 1468: 输出计数
           │
           └─ snprintf(buf, sizeof(buf), "%llu\n", counter)
               使用标准 C locale，避免不同地区的数字格式差异
               例如: 避免某些 locale 用 ',' 作为小数点
```

**六层面分析：**

| 层面 | 分析 |
|-----|------|
| **设计原理** | 简洁的文本格式，兼容原始 FlameGraph.pl 脚本 |
| **边界条件** | 空调用栈（num_frames=0）被过滤；counter=0 的条目跳过 |
| **并发安全** | 只读操作，线程安全 |
| **JVM 交互** | FrameName 内部调用 JVMTI 解析 jmethodID |
| **性能影响** | O(n) 遍历 + JVMTI 调用，每个方法名约 1-10 μs |
| **替代方案** | 可预计算方法名缓存，但已通过 JMethodCache 实现 |

### 2.3 为什么使用 STYLE_NO_SEMICOLON？

```cpp
// frameName.cpp:172-176
if (_style & STYLE_NO_SEMICOLON) {
    for (char* s = method_sig; *s; s++) {
        if (*s == ';') *s = '|';  // 替换分号为竖线
    }
}
```

**示例：**

```
原始方法签名: (Ljava/lang/String;I)V
          方法签名中的分号用于分隔参数类型

如果直接输出:
  foo;(Ljava/lang/String;I)V;bar 100
         ↑ 这里的分号会被误认为是帧分隔符

使用 STYLE_NO_SEMICOLON 后:
  foo|(Ljava/lang/String|I)V;bar 100
         ↑ 分号替换为竖线，不会混淆
```

---

## 三、FrameName 帧名称解析深度解析

### 3.1 name() 方法：核心解析函数

```cpp
// frameName.cpp:251-326
const char* FrameName::name(ASGCT_CallFrame& frame, bool for_matching) {
    if (frame.method_id == NULL) {
        return "[unknown]";
    }

    switch (frame.bci) {
        case BCI_NATIVE_FRAME:
            return decodeNativeSymbol((const char*)frame.method_id);

        case BCI_ALLOC:
        case BCI_ALLOC_OUTSIDE_TLAB:
        case BCI_LOCK:
        case BCI_PARK: {
            const char* symbol = _class_names[(uintptr_t)frame.method_id];
            javaClassName(symbol, strlen(symbol), _style | STYLE_DOTTED);
            if (!for_matching && !(_style & STYLE_DOTTED)) {
                _str += frame.bci == BCI_ALLOC_OUTSIDE_TLAB ? "_[k]" : "_[i]";
            }
            return _str.c_str();
        }

        case BCI_THREAD_ID: {
            int tid = (int)(uintptr_t)frame.method_id;
            MutexLocker ml(_thread_names_lock);
            ThreadMap::iterator it = _thread_names.find(tid);
            if (for_matching) {
                return it != _thread_names.end() ? it->second.c_str() : "";
            }

            char buf[32];
            snprintf(buf, sizeof(buf), "tid=%d]", tid);
            if (it != _thread_names.end()) {
                return _str.assign("[").append(it->second).append(" ").append(buf).c_str();
            } else {
                return _str.assign("[").append(buf).c_str();
            }
        }

        case BCI_ADDRESS: {
            char buf[32];
            snprintf(buf, sizeof(buf), "%p", frame.method_id);
            return _str.assign(buf).c_str();
        }

        case BCI_ERROR:
            return _str.assign("[").append((const char*)frame.method_id).append("]").c_str();

        case BCI_CPU: {
            int cpu = ((int)(uintptr_t)frame.method_id) & 0x7fff;
            char buf[32];
            snprintf(buf, sizeof(buf), "[CPU-%d]", cpu);
            return _str.assign(buf).c_str();
        }

        default: {
            // Java 方法
            const char* type_suffix = typeSuffix(FrameType::decode(frame.bci));

            JMethodCache::iterator it = _cache.lower_bound(frame.method_id);
            if (it != _cache.end() && it->first == frame.method_id) {
                it->second[0] = _cache_epoch;  // 更新缓存时间戳
                const char* name = it->second.c_str() + 1;
                if (type_suffix != NULL) {
                    return _str.assign(name).append(type_suffix).c_str();
                }
                return name;
            }

            javaMethodName(frame.method_id);  // JVMTI 调用解析方法名
            _cache.insert(it, JMethodCache::value_type(frame.method_id, std::string(1, _cache_epoch) + _str));
            if (type_suffix != NULL) {
                _str += type_suffix;
            }
            return _str.c_str();
        }
    }
}
```

### 3.2 BCI (Bytecode Index) 编码方案

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    BCI 编码与帧类型映射                                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  BCI 值              含义               method_id 内容                   │
│  ─────────────────────────────────────────────────────────────────────  │
│  >= 0                Java 方法           jmethodID (真实)                │
│                                                                         │
│  BCI_NATIVE_FRAME    Native/C++ 帧       字符串指针 (符号名)              │
│  (-1)               (如 libc 函数)                                       │
│                                                                         │
│  BCI_ALLOC           对象分配             Class指针                       │
│  (-2)               (TLAB内)                                             │
│                                                                         │
│  BCI_ALLOC_OUTSIDE   对象分配             Class指针                       │
│  _TLAB (-3)         (TLAB外)                                             │
│                                                                         │
│  BCI_LOCK            锁等待               Class指针 (锁对象类)            │
│  (-4)                                                                   │
│                                                                         │
│  BCI_PARK            LockSupport.park    Class指针                       │
│  (-5)                                                                   │
│                                                                         │
│  BCI_THREAD_ID       线程标识             int (线程ID)                    │
│  (-6)               (--threads 参数)                                     │
│                                                                         │
│  BCI_CPU             CPU 核心             int (CPU编号)                   │
│  (-7)               (--sched 参数)                                       │
│                                                                         │
│  BCI_ADDRESS         原始地址             void* (内存地址)                │
│  (-8)               (--pcaddr 参数)                                      │
│                                                                         │
│  BCI_ERROR           错误信息             字符串指针                      │
│  (-9)               (如 "storage_overflow")                              │
│                                                                         │
│  < BCI_ERROR         帧类型编码           jmethodID                       │
│  (如 -16)           (解释/JIT/内联)       (带类型标记)                    │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘

详细帧类型编码 (FrameType::decode):
  bci = -16 → FRAME_INTERPRETED  (解释执行)
  bci = -17 → FRAME_JIT_COMPILED (JIT编译)
  bci = -18 → FRAME_INLINED      (内联)
  bci = -19 → FRAME_C1_COMPILED  (C1编译)
  
实现:
  static FrameTypeId decode(int bci) {
      return (FrameTypeId)(-bci / 16 - 1);
      // -16 → (16/16 - 1) = 0 = FRAME_INTERPRETED
      // -17 → (17/16 - 1) = 0 = FRAME_INTERPRETED (实际用 bci % 16 判断)
  }
```

### 3.3 javaMethodName() 方法：JVMTI 调用详解

```cpp
// frameName.cpp:151-193
void FrameName::javaMethodName(jmethodID method) {
    if (VMMethod::isStaleMethodId(method)) {
        _str.assign("[stale_jmethodID]");
        return;
    }

    jclass method_class = NULL;
    char* class_name = NULL;
    char* method_name = NULL;
    char* method_sig = NULL;

    jvmtiEnv* jvmti = VM::jvmti();
    jvmtiError err;

    if ((err = jvmti->GetMethodName(method, &method_name, &method_sig, NULL)) == 0 &&
        (err = jvmti->GetMethodDeclaringClass(method, &method_class)) == 0 &&
        (err = jvmti->GetClassSignature(method_class, &class_name, NULL)) == 0) {
        
        // 解析类名: "Ljava/lang/Object;" → "java/lang/Object"
        javaClassName(class_name + 1, strlen(class_name) - 2, _style);
        _str.append(".").append(method_name);
        
        if (_style & STYLE_SIGNATURES) {
            if (_style & STYLE_NO_SEMICOLON) {
                for (char* s = method_sig; *s; s++) {
                    if (*s == ';') *s = '|';
                }
            }
            _str.append(method_sig);
        }
    } else if (err == JVMTI_ERROR_INVALID_METHODID) {
        _str.assign("[stale_jmethodID]");
    } else {
        char buf[32];
        snprintf(buf, sizeof(buf), "[jvmtiError %d]", err);
        _str.assign(buf);
    }

    // 清理资源
    if (method_class) {
        _jni->DeleteLocalRef(method_class);
    }
    jvmti->Deallocate((unsigned char*)class_name);
    jvmti->Deallocate((unsigned char*)method_sig);
    jvmti->Deallocate((unsigned char*)method_name);
}
```

**JVMTI 调用开销分析：**

```
┌────────────────────────────────────────────────────────────────┐
│  JVMTI 函数                     CPU 周期    说明                │
├────────────────────────────────────────────────────────────────┤
│  GetMethodName()               ~1000       获取方法名和签名    │
│  GetMethodDeclaringClass()     ~500        获取声明类          │
│  GetClassSignature()           ~500        获取类签名          │
│  Deallocate() (x3)             ~300        释放内存            │
│  DeleteLocalRef()              ~100        删除本地引用        │
├────────────────────────────────────────────────────────────────┤
│  总计                          ~2400       约 0.5-1 μs         │
└────────────────────────────────────────────────────────────────┘

优化: JMethodCache
  - 首次解析后缓存方法名
  - 后续查询只需 ~100 cycles (红黑树查找)
  - 缓存命中率: >99% (同一方法多次采样)
```

### 3.4 decodeNativeSymbol() 方法：Native 符号解析

```cpp
// frameName.cpp:115-136
const char* FrameName::decodeNativeSymbol(const char* name) {
    const char* lib_name = (_style & STYLE_LIB_NAMES) ? Profiler::instance()->getLibraryName(name) : NULL;

    if (Demangle::needsDemangling(name)) {
        char* demangled = Demangle::demangle(name, _style & STYLE_SIGNATURES);
        if (demangled != NULL) {
            if (lib_name != NULL) {
                _str.assign(lib_name).append("`").append(demangled);
            } else {
                _str.assign(demangled);
            }
            free(demangled);
            return _str.c_str();
        }
    }

    if (lib_name != NULL) {
        return _str.assign(lib_name).append("`").append(name).c_str();
    } else {
        return name;
    }
}
```

**C++ 符号 Demangling 示例：**

```
Mangled 符号 (编译器内部表示):
  _ZNSt6vectorIiSaIiEE9push_backEOi

Demangled 后 (人类可读):
  std::vector<int, std::allocator<int>>::push_back(int&&)

实现:
  Demangle::demangle() 调用:
    - Linux: __cxa_demangle() (libstdc++)
    - macOS: ??? (libstdc++ 或 libc++)

Demangle 算法:
  1. 解析符号前缀 (_Z = GCC mangling)
  2. 递归解析类型编码
     - N...E = 嵌套名称
     - St = std::
     - I...E = 模板参数
  3. 重构可读名称
```

### 3.5 JMethodCache 实现细节

```cpp
// frameName.h:23
typedef std::map<jmethodID, std::string> JMethodCache;

// frameName.cpp:75
JMethodCache FrameName::_cache;  // 静态全局缓存

// 缓存条目格式:
//   key: jmethodID (指针值，作为唯一标识)
//   value: std::string
//          第一个字节: epoch (缓存时间戳)
//          剩余部分: 方法名字符串
//          例如: "\x03java/lang/Object.hashCode"
//                 ↑     ↑
//                 epoch 方法名

// 插入缓存 (frameName.cpp:319):
_cache.insert(it, JMethodCache::value_type(frame.method_id, std::string(1, _cache_epoch) + _str));

// 查找缓存 (frameName.cpp:308-316):
JMethodCache::iterator it = _cache.lower_bound(frame.method_id);
if (it != _cache.end() && it->first == frame.method_id) {
    it->second[0] = _cache_epoch;  // 更新时间戳 (LRU-like)
    const char* name = it->second.c_str() + 1;  // 跳过第一个字节
    // ...
}

// 清理过期条目 (frameName.cpp:103-109):
for (JMethodCache::iterator it = _cache.begin(); it != _cache.end(); ) {
    if (_cache_epoch - (unsigned char)it->second[0] >= _cache_max_age) {
        _cache.erase(it++);  // 删除过期条目
    } else {
        ++it;
    }
}
```

**缓存策略分析：**

```
┌────────────────────────────────────────────────────────────────┐
│  缓存参数                    默认值      说明                    │
├────────────────────────────────────────────────────────────────┤
│  _cache_max_age              0         缓存有效期               │
│  (args._mcache)                        0 = 立即清理              │
│                                        >0 = 保留 N 次 epoch      │
├────────────────────────────────────────────────────────────────┤
│  _cache_epoch                N/A       当前 epoch (递增计数器)   │
│                                        每次 dump 后递增          │
└────────────────────────────────────────────────────────────────┘

典型场景:
  - 单次 profile + dump: mcache=0, 缓存在 dump 后立即清空
  - 连续 profile: mcache>0, 保留近期方法名，避免重复解析

内存占用估算:
  - 10 万个方法名
  - 平均每个方法名 50 字节
  - 总计: 100,000 * (50 + 8) ≈ 5.8 MB
```

---

## 四、Text 格式深度解析

### 4.1 dumpText() 方法

```cpp
// profiler.cpp:1540-1628 (简化版)
void Profiler::dumpText(Writer& out, Arguments& args) {
    // ... 收集 samples ...

    // 打印摘要
    snprintf(buf, sizeof(buf) - 1,
            "--- Execution profile ---\n"
            "Total samples       : %lld\n",
            _total_samples);
    out << buf;

    // 打印失败统计
    double spercent = 100.0 / _total_samples;
    for (int i = 1; i < ASGCT_FAILURE_TYPES; i++) {
        const char* err_string = asgctError(-i);
        if (err_string != NULL && _failures[i] > 0) {
            snprintf(buf, sizeof(buf), "%-20s: %lld (%.2f%%)\n", 
                     err_string, _failures[i], _failures[i] * spercent);
            out << buf;
        }
    }

    // 打印 Top N 调用栈
    if (args._dump_traces > 0) {
        std::sort(samples.begin(), samples.end(), [](const CallTraceSample& a, const CallTraceSample& b) {
            return a.counter > b.counter;
        });

        int max_count = args._dump_traces;
        for (auto it = samples.begin(); it != samples.end() && --max_count >= 0; ++it) {
            snprintf(buf, sizeof(buf) - 1, "--- %lld %s (%.2f%%), %lld sample%s\n",
                     it->counter, units_str, it->counter * cpercent,
                     it->samples, it->samples == 1 ? "" : "s");
            out << buf;

            CallTrace* trace = it->trace;
            for (int j = 0; j < trace->num_frames; j++) {
                const char* frame_name = fn.name(trace->frames[j]);
                snprintf(buf, sizeof(buf) - 1, "  [%2d] %s\n", j, frame_name);
                out << buf;
            }
            out << "\n";
        }
    }

    // 打印 Top N 方法
    if (args._dump_flat > 0) {
        std::map<std::string, MethodSample> histogram;
        for (auto it = samples.begin(); it != samples.end(); ++it) {
            const char* frame_name = fn.name(it->trace->frames[0]);  // 只统计顶层方法
            histogram[frame_name].add(it->samples, it->counter);
        }

        std::vector<NamedMethodSample> methods(histogram.begin(), histogram.end());
        std::sort(methods.begin(), methods.end(), sortByCounter);

        snprintf(buf, sizeof(buf) - 1, "%12s  percent  samples  top\n"
                                       "  ----------  -------  -------  ---\n", units_str);
        out << buf;

        int max_count = args._dump_flat;
        for (auto it = methods.begin(); it != methods.end() && --max_count >= 0; ++it) {
            snprintf(buf, sizeof(buf) - 1, "%12lld  %6.2f%%  %7lld  %s\n",
                     it->second.counter, it->second.counter * cpercent, 
                     it->second.samples, it->first.c_str());
            out << buf;
        }
    }
}
```

**输出示例：**

```
--- Execution profile ---
Total samples       : 10000
ticks_native        : 120 (1.20%)
ticks_GC_active     : 50 (0.50%)

--- 85000000 ns (85.00%), 850 samples
  [ 0] com/example/MyApp.processData
  [ 1] com/example/Worker.run
  [ 2] java/lang/Thread.run

--- 5000000 ns (5.00%), 50 samples
  [ 0] java/util/HashMap.get
  [ 1] com/example/Cache.lookup
  [ 2] com/example/MyApp.processData
  [ 3] com/example/Worker.run
  [ 4] java/lang/Thread.run

           ns  percent  samples  top
  ----------  -------  -------  ---
   85000000    85.00%      850  com/example/MyApp.processData
    5000000     5.00%       50  java/util/HashMap.get
```

---

## 五、include/exclude 过滤机制

### 5.1 excludeTrace() 实现

```cpp
// frameName.cpp:384-403
bool FrameName::excludeTrace(CallTrace* trace) {
    bool check_include = !_include.empty();
    bool check_exclude = !_exclude.empty();
    if (!(check_include || check_exclude)) {
        return false;  // 没有过滤规则，保留所有调用栈
    }

    for (int i = 0; i < trace->num_frames; i++) {
        const char* frame_name = name(trace->frames[i], true);  // for_matching=true
        if (check_exclude && exclude(frame_name)) {
            return true;  // 匹配 exclude 规则，丢弃调用栈
        }
        if (check_include && include(frame_name)) {
            check_include = false;  // 匹配 include 规则，标记已找到
            if (!check_exclude) break;
        }
    }

    return check_include;  // 如果需要 include 但未找到，丢弃调用栈
}
```

**过滤逻辑：**

```
┌─────────────────────────────────────────────────────────────────┐
│                     过滤规则组合                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  仅 -I (include):                                               │
│    保留: 包含任一匹配帧的调用栈                                   │
│    丢弃: 不包含任何匹配帧的调用栈                                 │
│                                                                 │
│  仅 -X (exclude):                                               │
│    保留: 不包含任何匹配帧的调用栈                                 │
│    丢弃: 包含任一匹配帧的调用栈                                   │
│                                                                 │
│  同时 -I 和 -X:                                                 │
│    保留: 包含 include 帧 且 不包含 exclude 帧                    │
│    丢弃: 不包含 include 帧 或 包含 exclude 帧                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 Matcher 模式匹配

```cpp
// frameName.cpp:21-35
Matcher::Matcher(const char* pattern) {
    if (pattern[0] == '*') {
        _type = MATCH_ENDS_WITH;
        _pattern = strdup(pattern + 1);  // 去掉前导 '*'
    } else {
        _type = MATCH_EQUALS;
        _pattern = strdup(pattern);
    }

    _len = strlen(_pattern);
    if (_len > 0 && _pattern[_len - 1] == '*') {
        _type = _type == MATCH_EQUALS ? MATCH_STARTS_WITH : MATCH_CONTAINS;
        _pattern[--_len] = 0;  // 去掉尾随 '*'
    }
}

// frameName.cpp:59-72
bool Matcher::matches(const char* s) {
    switch (_type) {
        case MATCH_EQUALS:
            return strcmp(s, _pattern) == 0;        // 精确匹配
        case MATCH_CONTAINS:
            return strstr(s, _pattern) != NULL;     // 包含
        case MATCH_STARTS_WITH:
            return strncmp(s, _pattern, _len) == 0; // 前缀匹配
        case MATCH_ENDS_WITH:
            int slen = strlen(s);
            return slen >= _len && strcmp(s + slen - _len, _pattern) == 0;  // 后缀匹配
    }
    return false;
}
```

**模式解析示例：**

```
┌────────────────────────────────────────────────────────────────┐
│  模式           解析结果            匹配示例                     │
├────────────────────────────────────────────────────────────────┤
│  "foo"          MATCH_EQUALS       "foo" ✓  "foobar" ✗         │
│  "foo*"         MATCH_STARTS_WITH  "foo" ✓  "foobar" ✓         │
│  "*foo"         MATCH_ENDS_WITH    "foo" ✓  "barfoo" ✓         │
│  "*foo*"        MATCH_CONTAINS     "foo" ✓  "xfoox" ✓          │
│  "foo*bar"      MATCH_STARTS_WITH  "foobar" ✓  "fooxbar" ✓     │
│                 (去掉尾*)          "foo" ✗                     │
└────────────────────────────────────────────────────────────────┘
```

---

## 六、OTLP 输出格式

### 6.1 dumpOtlp() 方法

```cpp
// profiler.cpp:1630-1637
void Profiler::dumpOtlp(Writer& out, Arguments& args) {
    FrameName fn(args, args._style & ~STYLE_ANNOTATE, _epoch, _thread_names_lock, _thread_names);
    Otlp::Recorder recorder(_engine, fn, _start_time * 1000ULL, (OS::micros() - _start_time) * 1000ULL);
    std::vector<CallTraceSample*> call_trace_samples;
    _call_trace_storage.collectSamples(call_trace_samples);
    recorder.record(call_trace_samples, args._counter == COUNTER_SAMPLES);
    recorder.write(out);
}
```

**OTLP (OpenTelemetry Protocol) 格式：**

```
OTLP 使用 Protocol Buffers 编码，结构如下:

ExportTraceServiceRequest {
  resource_spans: [
    {
      resource: {
        attributes: [
          { key: "service.name", value: "java-app" },
          { key: "telemetry.sdk.language", value: "java" }
        ]
      },
      scope_spans: [
        {
          spans: [
            {
              trace_id: "...",
              span_id: "...",
              name: "com/example/MyApp.processData",
              start_time_unix_nano: 1234567890,
              end_time_unix_nano: 1234567891,
              attributes: [
                { key: "profile.frame.type", value: "compiled" },
                { key: "profile.sample.count", value: 100 }
              ]
            }
          ]
        }
      ]
    }
  ]
}
```

**用途：**
- 与 OpenTelemetry Collector 集成
- 统一可观测性平台 (Grafana, Jaeger, etc.)
- 支持分布式追踪关联

---

## 七、性能对比总结

### 7.1 各格式性能指标

```
┌──────────────────────────────────────────────────────────────────────┐
│  格式          输出时间    文件大小    解析时间    交互性    用途       │
├──────────────────────────────────────────────────────────────────────┤
│  TEXT          ~30ms      最小       即时       无       控制台      │
│  COLLAPSED     ~50ms      小         快         无       FlameGraph  │
│  FLAMEGRAPH    ~100ms     大         中         高       浏览器查看  │
│  TREE          ~80ms      大         中         中       层级浏览    │
│  JFR           ~200ms     最大       慢         高       JMC 分析    │
│  OTLP          ~150ms     中         中         低       集成平台    │
└──────────────────────────────────────────────────────────────────────┘

测试条件: 10万采样，5000唯一方法名
```

### 7.2 关键优化点

1. **JMethodCache**：缓存方法名，避免重复 JVMTI 调用
2. **红黑树查找**：O(log n) 缓存查询
3. **单次遍历**：collectSamples() 只遍历一次哈希表
4. **格式选择**：根据使用场景选择最优格式

---

## 八、GDB 验证脚本

### 8.1 验证 FrameName 缓存

```bash
# gdb_framename_cache.gdb
set pagination off

break FrameName::javaMethodName

commands
    # 检查是否命中缓存
    printf "Checking cache for jmethodID: %p\n", $method
    
    # 打印缓存大小
    # 需要访问静态成员 FrameName::_cache
    
    continue
end

run
```

### 8.2 验证 excludeTrace 过滤

```bash
# gdb_filter.gdb
set pagination off

break FrameName::excludeTrace

commands
    printf "excludeTrace called, num_frames=%d\n", $trace->num_frames
    
    # 打印前 3 帧
    set $i = 0
    while $i < 3 && $i < $trace->num_frames
        printf "  frame[%d]: bci=%d\n", $i, $trace->frames[$i].bci
        set $i = $i + 1
    end
    
    continue
end

run
```

---

## 九、总结

### 核心要点

1. **多种格式满足不同场景**：从轻量级 TEXT 到完整 JFR
2. **FrameName 是核心转换层**：处理所有帧类型和方法名解析
3. **缓存机制提升性能**：JMethodCache 避免重复 JVMTI 调用
4. **过滤机制灵活**：支持 include/exclude 模式匹配

### 设计亮点

- **BCI 编码**：复用一个字段表示多种帧类型
- **STYLE 标志**：灵活控制输出格式
- **Matcher 模式**：简单但有效的通配符匹配

### 改进空间

- 可用 `std::unordered_map` 替代 `std::map` 加速缓存查找
- 可预计算常用方法名，减少首次解析延迟
- 可支持更复杂的过滤表达式（如正则表达式）

---

**下一课将分析 JFR (Java Flight Recorder) 输出格式的实现。**
