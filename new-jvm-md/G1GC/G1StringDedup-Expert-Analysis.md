# G1StringDedup 专家级源码分析

> **定位**：G1 字符串去重功能，减少堆中重复的 String 对象内存占用  
> **核心问题**：如何识别和去重重复的字符串？何时触发去重？  
> **源码路径**：`src/hotspot/share/gc/g1/g1StringDedup.hpp/cpp`

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1StringDedup 的本质是**后台字符串内容去重器**：维护一个全局哈希表（`StringDedupTable`），将内容相同的 `char[]` 合并为同一个数组；多个 `String` 对象共享同一个 `char[]`，减少内存占用；去重在后台线程（`StringDedupThread`）中异步完成，不影响应用线程。

### 0.2 为什么需要？

Java 应用中大量字符串内容相同但对象不同（如 JSON 解析产生的重复键名、日志中的重复字符串），每个字符串对象有独立的 `char[]`，浪费内存。去重后多个 `String` 对象共享同一个 `char[]`，内存占用可降低 10-30%（取决于应用）。

### 0.3 怎么解决？

**年龄过滤 + 哈希表去重**：只对年龄 ≥ `StringDeduplicationAgeThreshold`（默认 3）的字符串去重（避免对短命字符串浪费去重代价）；`StringDedupTable` 用字符串内容的哈希值索引，找到内容相同的字符串后，将新字符串的 `char[]` 替换为已有的 `char[]`（原 `char[]` 变为垃圾，下次 GC 回收）。

### 0.4 为什么这样设计？

- **为什么需要年龄阈值？** 新创建的字符串可能很快被回收，去重代价浪费；只对存活足够久（年龄 ≥ 3）的字符串去重，提高去重效率（这些字符串更可能长期存活，去重收益更大）
- **为什么去重在后台线程而不是 GC 停顿中？** 去重不影响 GC 正确性（只是内存优化），不需要 STW；在后台线程中完成不增加 GC 停顿时间；`-XX:+UseStringDeduplication` 开启

---

## 1. 一句话总结

**G1StringDedup 是 G1 的字符串去重机制，通过在 Young GC 的 Evacuation 阶段识别候选 String 对象，将其加入队列，由后台去重线程异步处理，将重复字符串的 char[] 数组共享，从而减少内存占用。**

---

## 2. 为什么需要字符串去重？

### 2.1 问题背景

Java 应用中字符串（String）往往占用大量堆内存：
- **重复字符串**：许多字符串内容相同但是不同的对象（如配置项、JSON key、日志消息）
- **内存浪费**：每个字符串都有独立的 char[] 数组，重复内容导致内存浪费

**典型场景**：
```java
// 读取配置文件，产生大量重复字符串
String config1 = props.getProperty("database.url");  // "jdbc:mysql://localhost"
String config2 = props.getProperty("database.url");  // "jdbc:mysql://localhost" (重复)
String config3 = props.getProperty("database.url");  // "jdbc:mysql://localhost" (重复)

// 三个不同的 String 对象，但内容相同
// 内存占用：3 个 String 对象 + 3 个 char[] 数组
```

### 2.2 如果没有字符串去重？

```
内存占用对比
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

场景：10000 个重复的 "jdbc:mysql://localhost" 字符串

无去重：
  String 对象：10000 × 24 bytes = 240 KB
  char[] 数组：10000 × 50 bytes = 500 KB
  总内存：~740 KB

有去重（G1StringDedup）：
  String 对象：10000 × 24 bytes = 240 KB（保持独立）
  char[] 数组：1 × 50 bytes = 50 KB（共享）
  总内存：~290 KB
  
节省：~450 KB（60% 节省）
```

---

## 3. 整体架构

### 3.1 类层次关系

```
G1StringDedup 架构
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

G1StringDedup (G1 专用接口)
├── 继承 StringDedup (通用接口)
├── is_candidate_from_evacuation()  // 候选判断
├── enqueue_from_evacuation()       // 入队
├── unlink_or_oops_do()             // GC 清理
└── initialize()                    // 初始化

StringDedup (通用字符串去重基类)
├── StringDedupQueue  // 去重队列
├── StringDedupTable  // 去重哈希表
├── StringDedupThread // 去重线程
└── is_enabled()      // 是否启用

G1StringDedupQueue (G1 专用队列)
├── 每个 GC Worker 一个队列
├── push()            // GC 线程入队
└── pop()             // 去重线程出队

G1StringDedupStat (G1 专用统计)
└── 记录去重统计信息
```

### 3.2 去重流程

```
字符串去重完整流程
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. 候选识别（Young GC Evacuation 阶段）
   ┌─────────────────────────────────────────────────────┐
   │ copy_to_survivor_space()                            │
   │   └── 对象是 String？                                │
   │       └── 来源是年轻代？                             │
   │           └── 年龄达到阈值？                         │
   │               └── 是候选，入队                       │
   └─────────────────────────────────────────────────────┘
                           ↓
2. 队列收集
   ┌─────────────────────────────────────────────────────┐
   │ G1StringDedupQueue (每个 GC Worker 独立队列)         │
   │   └── GC 线程 push()                                 │
   │   └── 去重线程 pop()                                 │
   └─────────────────────────────────────────────────────┘
                           ↓
3. 异步去重（后台线程）
   ┌─────────────────────────────────────────────────────┐
   │ StringDedupThread                                    │
   │   └── 从队列取出候选                                 │
   │   └── 计算字符串哈希                                 │
   │   └── 查表（StringDedupTable）                       │
   │       ├── 已存在：共享 char[]                        │
   │       └── 不存在：插入哈希表                         │
   └─────────────────────────────────────────────────────┘
                           ↓
4. GC 清理
   ┌─────────────────────────────────────────────────────┐
   │ unlink_or_oops_do()                                  │
   │   └── 清理死亡的字符串引用                           │
   │   └── 调整哈希表大小                                 │
   └─────────────────────────────────────────────────────┘
```

---

## 4. 核心数据结构详解

### 4.1 G1StringDedup 类

```cpp
class G1StringDedup : public StringDedup {
private:
    // 候选判断策略
    static bool is_candidate_from_mark(oop obj);      // 标记阶段
    static bool is_candidate_from_evacuation(bool from_young, bool to_young, oop obj);

public:
    static void initialize();  // 初始化
    
    // 入队接口（Evacuation 阶段调用）
    static void enqueue_from_evacuation(bool from_young, bool to_young,
                                        uint worker_id, oop java_string);
    
    // GC 清理
    static void unlink_or_oops_do(BoolObjectClosure* is_alive, 
                                  OopClosure* keep_alive,
                                  bool allow_resize_and_rehash);
};
```

### 4.2 候选判断策略

```cpp
bool G1StringDedup::is_candidate_from_evacuation(bool from_young, bool to_young, oop obj) {
    // 1. 来源必须是年轻代
    if (from_young && java_lang_String::is_instance_inlined(obj)) {
        
        // 2. 情况 A：年轻代 → 年轻代，年龄等于阈值
        if (to_young && obj->age() == StringDeduplicationAgeThreshold) {
            return true;
        }
        
        // 3. 情况 B：年轻代 → 老年代，年龄小于阈值
        if (!to_young && obj->age() < StringDeduplicationAgeThreshold) {
            return true;
        }
    }
    return false;
}
```

**候选条件详解**：

| 条件 | 说明 | 目的 |
|------|------|------|
| `from_young` | 来源必须是年轻代 | 只处理新分配的字符串 |
| `java_lang_String::is_instance_inlined(obj)` | 必须是 String 对象 | 类型检查 |
| `age() == StringDeduplicationAgeThreshold` | 年龄等于阈值（默认 3） | 在特定年龄检查一次 |
| `age() < StringDeduplicationAgeThreshold` | 晋升时年龄小于阈值 | 晋升前检查 |

**为什么不检查所有字符串？**
- **性能考虑**：检查每个字符串有开销
- **收益递减**：存活时间长的字符串往往不重复
- **避免重复检查**：同一字符串只检查一次（基于年龄）

---

## 5. 去重流程详解

### 5.1 Evacuation 阶段入队

```cpp
// g1ParScanThreadState.cpp
oop G1ParScanThreadState::copy_to_survivor_space(...) {
    // ... 复制对象 ...
    
    // 字符串去重处理
    if (G1StringDedup::is_enabled()) {
        const bool is_from_young = state.is_young();
        const bool is_to_young = dest_state.is_young();
        
        // 入队候选字符串
        G1StringDedup::enqueue_from_evacuation(
            is_from_young,      // 来源是否年轻代
            is_to_young,        // 目标是否年轻代
            _worker_id,         // GC Worker ID
            obj                 // String 对象
        );
    }
    
    return obj;
}
```

### 5.2 入队实现

```cpp
void G1StringDedup::enqueue_from_evacuation(bool from_young, bool to_young, 
                                            uint worker_id, oop java_string) {
    // 1. 检查是否是候选
    if (is_candidate_from_evacuation(from_young, to_young, java_string)) {
        // 2. 入队到对应 Worker 的队列
        G1StringDedupQueue::push(worker_id, java_string);
    }
}
```

### 5.3 队列结构

```cpp
// g1StringDedupQueue.hpp
class G1StringDedupQueue : public StringDedupQueue {
public:
    // 每个 GC Worker 独立队列
    static inline void push(uint worker_id, oop java_string);
    static oop pop();
};
```

**设计特点**：
- **每 Worker 独立队列**：避免 GC 线程间竞争
- **去重线程单线程处理**：简化去重逻辑，避免冲突

### 5.4 GC 清理

```cpp
void G1StringDedup::unlink_or_oops_do(BoolObjectClosure* is_alive,
                                      OopClosure* keep_alive,
                                      bool allow_resize_and_rehash,
                                      G1GCPhaseTimes* phase_times) {
    // 创建并行任务
    G1StringDedupUnlinkOrOopsDoTask task(is_alive, keep_alive, 
                                         allow_resize_and_rehash, phase_times);
    
    // 并行执行
    G1CollectedHeap::heap()->workers()->run_task(&task);
}

// 任务实现
class G1StringDedupUnlinkOrOopsDoTask : public AbstractGangTask {
    void work(uint worker_id) {
        // 1. 清理队列
        StringDedupQueue::unlink_or_oops_do(&_cl);
        
        // 2. 清理哈希表
        StringDedupTable::unlink_or_oops_do(&_cl, worker_id);
    }
};
```

**清理目的**：
1. **移除死亡对象**：字符串被回收后，从队列和哈希表中移除
2. **调整表大小**：根据负载调整哈希表大小
3. **重新哈希**：必要时重新哈希以优化性能

---

## 6. 性能与调优

### 6.1 启用参数

```bash
# 启用字符串去重（G1 默认不启用）
java -XX:+UseStringDeduplication -XX:+UseG1GC MyApp

# 调整年龄阈值（默认 3）
java -XX:StringDeduplicationAgeThreshold=2 MyApp
```

### 6.2 年龄阈值调优

```
年龄阈值影响
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

阈值 = 1：
  - 第一次 Young GC 后检查
  - 检查频繁，CPU 开销大
  - 适合字符串重复率极高的场景

阈值 = 3（默认）：
  - 第三次 Young GC 后检查
  - 平衡 CPU 开销和内存节省
  - 适合大多数场景

阈值 = 5：
  - 第五次 Young GC 后检查
  - 检查较少，CPU 开销小
  - 适合字符串重复率较低的场景
```

### 6.3 日志输出

```bash
# 开启去重日志
java -XX:+PrintStringDeduplicationStatistics -XX:+UseStringDeduplication MyApp
```

**输出示例**：
```
String Deduplication:
  Concurrent Phase: 12345 ms
  Cancelled:        0
  Young+Old:        1234567 bytes
  (Young:           987654 bytes)
  (Old:             246913 bytes)
  Inspected:        100000
  Skipped:          20000
  Hashed:           80000
  Known:            70000
  New:              10000
```

**指标说明**：
| 指标 | 说明 |
|------|------|
| `Young+Old` | 总共节省的内存 |
| `Inspected` | 检查的字符串数量 |
| `Skipped` | 跳过的字符串（hash 冲突等）|
| `Hashed` | 计算哈希的字符串数量 |
| `Known` | 已存在的重复字符串 |
| `New` | 新发现的唯一字符串 |

---

## 7. 常见问题与面试题

### Q1: 字符串去重和 String.intern() 有什么区别？

**答案**：

| 特性 | String.intern() | G1StringDedup |
|------|-----------------|---------------|
| **共享级别** | String 对象本身 | 只共享 char[] 数组 |
| **生命周期** | 永久（在 Perm/Metaspace） | 受 GC 管理 |
| **触发时机** | 代码显式调用 | GC 自动处理 |
| **CPU 开销** | 高（扫描常量池） | 低（异步处理）|
| **线程安全** | 同步 | 无锁（单线程处理）|

### Q2: 为什么只处理年轻代的字符串？

**答案**：
1. **新字符串更可能重复**：刚创建的字符串往往来自配置文件、网络请求等，重复率高
2. **老年代字符串已稳定**：存活时间长的字符串通常已去重或不重复
3. **性能考虑**：避免扫描整个堆

### Q3: 为什么基于年龄阈值判断候选？

**答案**：
1. **避免重复检查**：同一字符串只检查一次
2. **平衡开销**：太频繁检查 CPU 开销大，太少检查内存节省少
3. **经验值**：默认 3 是 JVM 团队的实验结果

### Q4: 字符串去重对应用有什么影响？

**答案**：
- **CPU**：轻微增加（候选判断 + 后台去重线程）
- **内存**：显著节省（重复字符串多的场景可达 10-30%）
- **延迟**：后台异步处理，对应用延迟影响小
- **GC**：略微增加 Young GC 时间（候选判断）

---

## 8. 总结

### 8.1 核心设计要点

```
G1StringDedup 设计精髓
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. 异步处理
   ├── GC 阶段只识别候选并入队
   ├── 后台线程异步去重
   └── 不阻塞应用线程

2. 精确候选
   ├── 只处理年轻代字符串
   ├── 基于年龄阈值判断
   └── 避免重复检查

3. 细粒度共享
   ├── 不共享 String 对象（避免同步问题）
   ├── 只共享 char[] 数组
   └── String 对象独立，value 字段指向共享数组

4. GC 协同
   ├── GC 时清理死亡对象
   ├── 调整哈希表大小
   └── 并行处理提高效率
```

### 8.2 与其他 GC 的对比

| GC | 字符串去重支持 | 实现方式 |
|----|---------------|----------|
| **G1** | ✅ 原生支持 | G1StringDedup |
| **ZGC** | ❌ 不支持 | - |
| **Shenandoah** | ❌ 不支持 | - |
| **Parallel/CM** | ❌ 不支持 | - |

### 8.3 使用建议

```
启用条件：
  ✅ 堆中有大量重复字符串
  ✅ 应用是内存受限的
  ✅ 使用 G1 GC

不适用场景：
  ❌ 字符串重复率低
  ❌ CPU 资源紧张
  ❌ 延迟敏感（极致优化场景）
```

---

## 参考文档

1. OpenJDK 11: `src/hotspot/share/gc/g1/g1StringDedup.hpp/cpp`
2. OpenJDK 11: `src/hotspot/share/gc/g1/g1StringDedupQueue.hpp/cpp`
3. OpenJDK 11: `src/hotspot/share/gc/shared/stringdedup/`
4. JEP 192: String Deduplication in G1

---

**文档信息**
- 创建时间: 2026-02-10
- 源码版本: OpenJDK 11
- 分析类型: 专家级源码分析
- 配套技能: Read-BottomUp, JVM-Optimization-Design
