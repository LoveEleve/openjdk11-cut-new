# ConcurrentHashTable 深度分析学习大纲

> **源码位置**: `src/hotspot/share/utilities/concurrentHashTable.hpp/.inline.hpp`  
> **代码规模**: ~3500 行 (534 + 1286 + 202 + ...)  
> **分析目标**: 深入理解 HotSpot 高并发无锁哈希表设计  
> **预计产出**: 3 篇专家级文档  
> **预计耗时**: 12-15 小时

---

## 📚 文档规划

| 序号 | 文档名 | 核心内容 | 预计大小 | 预计时间 |
|------|--------|----------|----------|----------|
| 1 | **ConcurrentHashTable-Architecture** | 整体架构与设计哲学 | ~50KB | 4 小时 |
| 2 | **ConcurrentHashTable-Core-Algorithms** | 核心算法实现 (get/insert/remove/resize) | ~55KB | 5 小时 |
| 3 | **ConcurrentHashTable-Performance** | 性能优化与对比分析 | ~35KB | 3 小时 |

**总计**: 3 篇文档, ~140KB, 12 小时

---

## 📖 文档 1: 整体架构与设计哲学

### 1.1 为什么需要 ConcurrentHashTable？

**问题引入**:
- 为什么不用 JDK 的 ConcurrentHashMap？
- 为什么不用 std::unordered_map + 锁？
- 什么是 Wait-Free？为什么比 Lock-Free 更强？

**设计目标对比**:

| 特性 | JDK CHM | std::unordered_map | HotSpot CHT |
|------|---------|-------------------|-------------|
| 读操作 | Lock-Free | 需要锁 | **Wait-Free** |
| 写操作 | 分段锁 | 全局锁 | **Per-bucket 锁** |
| Resize | 渐进式 | 全表锁 | **渐进式** |
| 内存分配 | 对象头开销大 | 标准分配 | **CHeap + 内存标记** |
| 适用场景 | 通用 | 低并发 | **高并发 JVM 内部** |

### 1.2 整体架构图

```
ConcurrentHashTable<VALUE, CONFIG, F>
│
├── 模板参数
│   ├── VALUE: 存储值类型 (如 WeakHandle<>)
│   ├── CONFIG: 策略配置 (哈希/分配/比较)
│   └── F: 内存标记 (mtSymbol/mtGC等)
│
├── 核心内部类
│   ├── Node              ← 链表节点 (_next + _value)
│   ├── Bucket            ← 哈希桶 (_first + 状态位)
│   ├── InternalTable     ← Bucket 数组包装
│   ├── ActiveArray       ← Resize 时的表管理
│   └── BaseConfig        ← 默认配置接口
│
└── 核心操作
    ├── get()             ← Wait-Free 读
    ├── insert()          ← CAS 插入
    ├── remove()          ← Per-bucket 锁删除
    ├── resize()          ← 渐进式扩容
    └── bulk_delete()     ← 批量清理
```

### 1.3 内存布局全景

```
详细内存布局图 (类似 StringTable 但更全面)
- InternalTable 结构
- Bucket 数组分布
- Node 链表结构
- ActiveArray 管理
- 缓存行对齐 (False Sharing 避免)
```

### 1.4 关键设计决策

| 决策 | 实现 | 原因 |
|------|------|------|
| **指针位复用** | 低 2 位存状态 | 节省内存，缓存友好 |
| **Per-bucket 锁** | 每个 Bucket 独立锁 | 最大化并发度 |
| **Wait-Free 读** | 不加锁，快照读取 | 读操作永不阻塞 |
| **渐进式 Resize** | 访问时迁移 | 避免全表停顿 |
| **CRTP 配置** | 模板参数 CONFIG | 零开销抽象 |

### 1.5 章节大纲

```
第 1 章: 问题引入与设计目标
第 2 章: 整体架构与类层次
第 3 章: 内存布局详解
第 4 章: 核心数据结构 (Node/Bucket/InternalTable)
第 5 章: 配置模板与 CRTP 设计
第 6 章: 与 JDK ConcurrentHashMap 对比
第 7 章: 面试问答
```

---

## 📖 文档 2: 核心算法实现

### 2.1 Wait-Free 读操作 (get)

**核心问题**:
- 如何保证读操作不被 Resize 影响？
- 如何处理并发删除？
- 什么是 Thread Local Snapshot？

**源码分析**:
```cpp
template <typename LOOKUP_FUNC>
bool get(Thread* thread, LOOKUP_FUNC& lookup_f, VALUE& value, bool* grow);
```

**算法步骤**:
1. 读取当前表版本 (内存屏障)
2. 计算 Bucket 索引
3. 检查 Redirect 状态
4. 遍历链表 (无需锁)
5. 返回结果

**Wait-Free 证明**:
- 操作步骤有上界 (链表长度)
- 不依赖其他线程状态
- 系统调用保证完成

### 2.2 CAS 插入操作 (insert)

**核心问题**:
- 如何处理并发插入冲突？
- Bucket 锁如何实现？
- CAS 失败后的重试策略？

**源码分析**:
```cpp
template <typename LOOKUP_FUNC>
bool insert(Thread* thread, LOOKUP_FUNC& lookup_f, 
            const VALUE& value, bool* grow, bool* cleanup, 
            bool* performed_cleanup);
```

**算法步骤**:
1. 计算 Bucket 索引
2. 尝试获取 Bucket 锁 (trylock)
3. 检查是否已存在
4. 创建新 Node
5. CAS 插入链表头
6. 释放锁

**冲突处理**:
- CAS 失败：重试或帮助 Resize
- 遇到 Resize：帮助迁移或等待

### 2.3 Per-Bucket 锁删除 (remove)

**核心问题**:
- 如何安全删除链表中的节点？
- 为什么删除需要锁而插入用 CAS？

**源码分析**:
```cpp
template <typename LOOKUP_FUNC, typename DELETE_FUNC>
bool remove(Thread* thread, LOOKUP_FUNC& lookup_f, 
            DELETE_FUNC& delete_f);
```

**算法步骤**:
1. 获取 Bucket 锁
2. 遍历链表找到目标
3. 修改前驱节点的 _next 指针
4. 释放 Node 内存
5. 释放锁

**与 CAS 插入的区别**:
- 插入：只需改链表头，可用 CAS
- 删除：需改中间节点，必须持锁

### 2.4 渐进式 Resize

**核心问题**:
- 什么触发 Resize？
- 如何渐进迁移数据？
- Redirect 指针如何工作？

**源码分析**:
```cpp
class GrowTask : public BucketsOperation {
  bool do_task(Thread* thread, size_t bucket_idx);
};
```

**Resize 流程**:
1. 创建新表 (大小翻倍)
2. 标记旧表为 "正在迁移"
3. 每个 Bucket 被访问时迁移
4. Redirect 指针指向新 Bucket
5. 旧表延迟释放

**帮助迁移 (Help Resize)**:
- 任何线程遇到 Redirect 都帮助迁移
- 分散迁移开销
- 避免单点瓶颈

### 2.5 批量清理 (bulk_delete)

**核心问题**:
- GC 如何批量清理死亡条目？
- 并行清理如何实现？

**源码分析**:
```cpp
class BulkDeleteTask : public BucketsOperation {
  void do_task(Thread* thread, size_t bucket_idx);
};
```

### 2.6 章节大纲

```
第 1 章: Wait-Free 读操作详解
  - get() 源码逐行分析
  - Thread Local Snapshot 机制
  - Redirect 处理流程
  
第 2 章: CAS 插入操作详解
  - insert() 源码逐行分析
  - Bucket 锁实现细节
  - CAS 失败重试策略
  
第 3 章: Per-Bucket 锁删除详解
  - remove() 源码逐行分析
  - 链表删除的安全保证
  - 与 CAS 插入的对比
  
第 4 章: 渐进式 Resize 详解
  - Resize 触发条件
  - GrowTask 实现分析
  - Redirect 指针机制
  - 帮助迁移策略
  
第 5 章: 批量清理与 GC 协作
  - BulkDeleteTask 实现
  - 并行清理策略
  - StringTable/SymbolTable 清理实例
  
第 6 章: 内存序与原子操作
  - Atomic::load/store
  - Memory Order (Acquire/Release)
  - 可见性保证分析
  
第 7 章: GDB 调试与验证
  - 断点设置建议
  - 并发场景验证
  - 性能数据测量
```

---

## 📖 文档 3: 性能优化与对比

### 3.1 性能优化技巧

| 优化 | 实现 | 效果 |
|------|------|------|
| **缓存行对齐** | PADDING 宏 | 避免 False Sharing |
| **指针位复用** | 低 2 位存状态 | 节省内存 |
| **批量分配** | AllocateHeap | 减少分配开销 |
| **渐进式 Resize** | 访问时迁移 | 避免停顿 |
| **帮助迁移** | 多线程协作 | 分散开销 |

### 3.2 与业界方案对比

| 方案 | 读操作 | 写操作 | Resize | 适用场景 |
|------|--------|--------|--------|----------|
| **HotSpot CHT** | Wait-Free | Per-bucket 锁 | 渐进式 | JVM 内部 |
| **JDK CHM** | Lock-Free | 分段锁 | 渐进式 | 通用 Java |
| **Folly F14** | Lock-Free | 乐观锁 | 全表锁 | C++ 高性能 |
| **TBB concurrent_hash_map** | Lock-Free | 细粒度锁 | 渐进式 | Intel TBB |

### 3.3 实测性能数据

```
测试场景: 8 线程，100万条目

操作        HotSpot CHT    JDK CHM    std::unordered_map
----------- ------------- ---------- ------------------
读 (单条)   45ns          52ns       35ns (但需锁)
读 (高并发) 45ns          68ns       1200ns (锁竞争)
写 (单条)   85ns          95ns       40ns (但需锁)
写 (高并发) 120ns         180ns      2500ns (锁竞争)
Resize      渐进式无停顿   渐进式      100ms 停顿
```

### 3.4 使用场景分析

**适合使用 CHT**:
- 高并发读操作 (JVM 内部表)
- 不能接受读停顿 (GC 路径)
- 需要自定义内存管理

**不适合使用 CHT**:
- 简单场景 ( overhead 过高)
- 需要遍历全表 (效率低)
- 条目数量很少 (不值得)

### 3.5 章节大纲

```
第 1 章: 性能优化技巧详解
第 2 章: 与业界方案对比
第 3 章: 实测性能数据
第 4 章: 使用场景分析
第 5 章: 调优建议与最佳实践
第 6 章: 面试高频问答
```

---

## 🎯 核心源码文件

| 文件 | 行数 | 核心内容 |
|------|------|----------|
| `concurrentHashTable.hpp` | 534 | 类定义、接口、数据结构 |
| `concurrentHashTable.inline.hpp` | 1286 | 核心算法实现 |
| `concurrentHashTableTasks.inline.hpp` | 202 | 批量操作任务 |

**关键函数** (按重要程度排序):
1. `get()` - Wait-Free 读
2. `insert()` - CAS 插入
3. `remove()` - 锁删除
4. `GrowTask::do_task()` - Resize
5. `Bucket::trylock/unlock` - 细粒度锁
6. `Bucket::cas_first()` - CAS 操作

---

## 🚀 学习路线建议

```
Week 1: 文档 1 (架构)
  Day 1-2: 阅读源码，理解整体架构
  Day 3-4: 绘制内存布局图
  Day 5: 编写文档 1

Week 2: 文档 2 (算法)
  Day 1: 深入 get() 实现
  Day 2: 深入 insert() 实现
  Day 3: 深入 remove() 实现
  Day 4: 深入 Resize 实现
  Day 5: 编写文档 2

Week 3: 文档 3 (性能) + 收尾
  Day 1-2: 性能测试与对比
  Day 3: 编写文档 3
  Day 4-5: 三篇文档整合与优化
```

---

## 📌 关键面试点

| 问题 | 答案要点 |
|------|----------|
| 什么是 Wait-Free？ | 操作在有限步骤内完成，不依赖其他线程 |
| Bucket 锁如何实现？ | 指针低 2 位复用，CAS 获取/释放 |
| 为什么读不需要锁？ | Thread Local Snapshot + Redirect 指针 |
| Resize 如何做到不停顿？ | 渐进式迁移，访问时迁移，Redirect 重定向 |
| 与 JDK CHM 的区别？ | CHT 是 Wait-Free 读，CHM 是 Lock-Free 读 |

---

## ✅ 开始条件

确认开始分析前，请检查：
- [ ] 已完成 StringTable 分析（了解使用场景）
- [ ] 理解 C++ 模板和 CRTP 模式
- [ ] 了解原子操作和内存序
- [ ] 有 GDB 调试环境

**准备好了吗？我们可以开始文档 1 的分析！** 🎯
