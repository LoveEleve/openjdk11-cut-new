# E.2 - 验证器和分配器

> **前置条件**：-Xms8G -Xmx8G，G1 GC，非大页，非 NUMA

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文通过 GDB 实际运行验证 **E.2 - 器和分配器** 的关键结论：用实际数据替代理论推断，确保分析结论的准确性。

### 0.2 为什么需要？

源码分析可能存在误读——代码路径可能在运行时走不同的分支，数据结构的实际大小可能与理论计算不符。GDB 验证是消除不确定性的最可靠方法。

### 0.3 怎么解决？

设计验证计划（验证哪些结论）→ 编写 GDB 脚本 → 实际运行 → 对比预期与实际结果 → 解释差异。

### 0.4 为什么这样设计？

验证策略：优先验证「影响结论正确性的关键假设」，而不是验证所有细节。关键假设包括：数据结构 sizeof、关键字段的值、代码路径的走向。

---


## 1. 概述

G1CollectedHeap 构造函数体中创建两个重要组件：

```cpp
// g1CollectedHeap.cpp:1505-1507
_verifier = new G1HeapVerifier(this);
_allocator = new G1Allocator(this);
```

- **G1HeapVerifier**：堆一致性验证器，调试和诊断用
- **G1Allocator**：内存分配器，管理三个分配区域

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    G1 分配架构                                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  应用线程分配                          GC 线程分配                           │
│  ═══════════════                      ═══════════════                       │
│                                                                             │
│  ┌─────────────────┐                  ┌─────────────────┐                  │
│  │ MutatorAlloc    │                  │ SurvivorGCAlloc │                  │
│  │    Region       │                  │    Region       │                  │
│  │ (Eden 分配)     │                  │ (幸存者复制)     │                  │
│  └─────────────────┘                  └─────────────────┘                  │
│         │                                    │                             │
│         │                             ┌──────┴──────┐                      │
│         ▼                             │             │                      │
│  ┌──────────────┐              ┌──────▼─────┐ ┌────▼────────┐              │
│  │    TLAB      │              │  Survivor  │ │    Old      │              │
│  │  (线程本地)   │              │  Region    │ │   Region    │              │
│  └──────────────┘              └────────────┘ └─────────────┘              │
│                                                      │                     │
│                                              ┌───────▼───────┐             │
│                                              │ OldGCAlloc    │             │
│                                              │   Region      │             │
│                                              │ (老年代晋升)   │             │
│                                              └───────────────┘             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. G1HeapVerifier - 堆验证器

### 2.1 类定义

```cpp
// g1HeapVerifier.hpp:35-75
class G1HeapVerifier : public CHeapObj<mtGC> {
private:
  static int _enabled_verification_types;
  G1CollectedHeap* _g1h;
  
  void verify_region_sets();

public:
  // 验证类型枚举
  enum G1VerifyType {
    G1VerifyYoungNormal     =  1,   // -XX:VerifyGCType=young-normal
    G1VerifyConcurrentStart =  2,   // -XX:VerifyGCType=concurrent-start
    G1VerifyMixed           =  4,   // -XX:VerifyGCType=mixed
    G1VerifyRemark          =  8,   // -XX:VerifyGCType=remark
    G1VerifyCleanup         = 16,   // -XX:VerifyGCType=cleanup
    G1VerifyFull            = 32,   // -XX:VerifyGCType=full
    G1VerifyAll             = -1    // 所有类型
  };
  
  // 构造函数
  G1HeapVerifier(G1CollectedHeap* heap) : _g1h(heap) {}
  
  // 静态方法
  static void enable_verification_type(G1VerifyType type);
  static bool should_verify(G1VerifyType type);
  
  // 执行验证
  void verify(VerifyOption vo);
};
```

### 2.2 验证时机

| 参数 | 说明 |
|------|------|
| `-XX:+VerifyBeforeGC` | GC 前验证 |
| `-XX:+VerifyAfterGC` | GC 后验证 |
| `-XX:+VerifyDuringGC` | GC 过程中验证 |
| `-XX:VerifyGCType=<type>` | 指定验证哪种 GC |

**示例**：
```bash
java -XX:+VerifyBeforeGC -XX:+VerifyAfterGC -XX:VerifyGCType=young-normal ...
```

### 2.3 验证选项（VerifyOption）

```cpp
enum VerifyOption {
  UsePrevMarking,   // 使用上一次标记信息（默认，最可靠）
  UseNextMarking,   // 使用本次标记信息（Remark 阶段）
  UseFullMarking    // Full GC 标记信息
};
```

---

## 3. G1Allocator - 内存分配器

### 3.1 类定义

```cpp
// g1Allocator.hpp:38-88
class G1Allocator : public CHeapObj<mtGC> {
  friend class VMStructs;

private:
  G1CollectedHeap* _g1h;
  
  bool _survivor_is_full;   // Survivor 区是否已满
  bool _old_is_full;        // Old 区是否已满

  // 三个分配区域
  MutatorAllocRegion _mutator_alloc_region;      // 应用线程分配（Eden）
  SurvivorGCAllocRegion _survivor_gc_alloc_region;  // GC 复制到 Survivor
  OldGCAllocRegion _old_gc_alloc_region;          // GC 复制到 Old

  HeapRegion* _retained_old_gc_alloc_region;     // 保留的 Old 区域

public:
  G1Allocator(G1CollectedHeap* heap);
  
  // 分配方法
  HeapWord* survivor_attempt_allocation(...);
  HeapWord* old_attempt_allocation(...);
  
  // TLAB 相关
  size_t unsafe_max_tlab_alloc();
};
```

### 3.2 构造函数

```cpp
// g1Allocator.cpp:36-43
G1Allocator::G1Allocator(G1CollectedHeap* heap) :
  _g1h(heap),
  _survivor_is_full(false),
  _old_is_full(false),
  _retained_old_gc_alloc_region(NULL),
  // Survivor 分配区域，使用 Young 统计
  _survivor_gc_alloc_region(heap->alloc_buffer_stats(InCSetState::Young)),
  // Old 分配区域，使用 Old 统计
  _old_gc_alloc_region(heap->alloc_buffer_stats(InCSetState::Old)) {
}
```

### 3.3 三种分配区域类型

```cpp
// g1AllocRegion.hpp:208-292

// 1. Mutator 分配区域（应用线程）
class MutatorAllocRegion : public G1AllocRegion {
private:
  size_t _wasted_bytes;                        // 浪费的字节数
  HeapRegion *volatile _retained_alloc_region; // 保留区域
  
  bool should_retain(HeapRegion *region);
};

// 2. Survivor GC 分配区域
class SurvivorGCAllocRegion : public G1GCAllocRegion {
public:
  SurvivorGCAllocRegion(G1EvacStats *stats)
    : G1GCAllocRegion("Survivor GC Alloc Region", 
                      false /* bot_updates */,  // 不更新 BOT
                      stats, 
                      InCSetState::Young) {}
};

// 3. Old GC 分配区域
class OldGCAllocRegion : public G1GCAllocRegion {
public:
  OldGCAllocRegion(G1EvacStats *stats)
    : G1GCAllocRegion("Old GC Alloc Region", 
                      true /* bot_updates */,   // 更新 BOT
                      stats, 
                      InCSetState::Old) {}
  
  // 特殊的 release() 确保最后一张卡被填充对象填满
  virtual HeapRegion *release();
};
```

---

## 4. 分配区域继承关系

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    分配区域类继承关系                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  G1AllocRegion (基类)                                                       │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │ _alloc_region: HeapRegion*     // 当前分配的 Region                   │ │
│  │ _bot_updates: bool              // 是否更新 BOT                       │ │
│  │ attempt_allocation()            // 尝试分配                           │ │
│  │ attempt_allocation_locked()     // 带锁分配                           │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│       │                                                                     │
│       ├──────────────────────────────────────────────┐                     │
│       │                                              │                     │
│       ▼                                              ▼                     │
│  MutatorAllocRegion                            G1GCAllocRegion             │
│  ┌─────────────────────┐                      ┌─────────────────────┐     │
│  │ 应用线程分配         │                      │ GC 线程分配         │     │
│  │ _retained_alloc_region                     │ _stats: G1EvacStats*│     │
│  │ _wasted_bytes       │                      │ _type: InCSetState  │     │
│  └─────────────────────┘                      └──────────┬──────────┘     │
│                                                          │                 │
│                                          ┌───────────────┴───────────────┐ │
│                                          │                               │ │
│                                          ▼                               ▼ │
│                               SurvivorGCAllocRegion           OldGCAllocRegion
│                               ┌─────────────────────┐   ┌─────────────────────┐
│                               │ bot_updates=false   │   │ bot_updates=true    │
│                               │ type=Young          │   │ type=Old            │
│                               └─────────────────────┘   └─────────────────────┘
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. 分配流程

### 5.1 应用线程分配流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    应用线程分配流程                                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  应用线程请求分配                                                            │
│       │                                                                     │
│       ▼                                                                     │
│  ┌───────────────────────────────────────┐                                 │
│  │ 1. 尝试 TLAB 分配                      │                                 │
│  │    (Thread Local Allocation Buffer)   │                                 │
│  └───────────────┬───────────────────────┘                                 │
│            成功  │  失败                                                    │
│       ┌──────────┴──────────┐                                              │
│       │                     │                                              │
│       ▼                     ▼                                              │
│  返回内存             ┌─────────────────────────────────┐                  │
│                      │ 2. 尝试从 MutatorAllocRegion 分配│                  │
│                      └───────────────┬─────────────────┘                  │
│                             成功     │  失败                               │
│                        ┌─────────────┴─────────────┐                       │
│                        │                           │                       │
│                        ▼                           ▼                       │
│                   返回内存                ┌─────────────────────┐          │
│                                          │ 3. 分配新 Eden Region│          │
│                                          │    作为 MutatorAlloc │          │
│                                          └───────────┬─────────┘          │
│                                              成功    │  失败              │
│                                         ┌────────────┴────────────┐       │
│                                         │                         │       │
│                                         ▼                         ▼       │
│                                    返回内存              ┌────────────────┐│
│                                                         │ 4. 触发 GC     ││
│                                                         └────────────────┘│
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 GC 线程分配流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    GC 线程分配流程（复制存活对象）                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  复制存活对象                                                                │
│       │                                                                     │
│       ▼                                                                     │
│  ┌───────────────────────────────────────┐                                 │
│  │ 1. 判断目标区域（根据对象 age）          │                                 │
│  │    • age < threshold → Survivor       │                                 │
│  │    • age >= threshold → Old           │                                 │
│  └───────────────┬───────────────────────┘                                 │
│                  │                                                          │
│       ┌──────────┴──────────┐                                              │
│       │                     │                                              │
│       ▼                     ▼                                              │
│  ┌──────────────┐     ┌──────────────┐                                     │
│  │ Survivor 分配 │     │   Old 分配   │                                     │
│  │ _survivor_gc_ │     │ _old_gc_     │                                     │
│  │ _alloc_region │     │ _alloc_region│                                     │
│  └───────┬──────┘     └───────┬──────┘                                     │
│          │                    │                                             │
│          │   ┌────────────────┘                                            │
│          │   │                                                             │
│          ▼   ▼                                                             │
│  ┌───────────────────────────────────────┐                                 │
│  │ 2. 尝试从当前 Region 分配              │                                 │
│  └───────────────┬───────────────────────┘                                 │
│            成功  │  失败                                                    │
│       ┌──────────┴──────────┐                                              │
│       │                     │                                              │
│       ▼                     ▼                                              │
│  返回内存             ┌─────────────────────────────────┐                  │
│                      │ 3. 分配新 Region                 │                  │
│                      │    (从 FreeList 获取)            │                  │
│                      └───────────────┬─────────────────┘                  │
│                             成功     │  失败                               │
│                        ┌─────────────┴─────────────┐                       │
│                        │                           │                       │
│                        ▼                           ▼                       │
│                   返回内存              ┌────────────────────────┐         │
│                                        │ 4. 设置 _is_full=true  │         │
│                                        │    疏散失败（to-space  │         │
│                                        │    exhausted）         │         │
│                                        └────────────────────────┘         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 6. BOT (Block Offset Table) 更新

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    BOT 更新差异                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  SurvivorGCAllocRegion: bot_updates = false                                │
│  ─────────────────────────────────────────                                 │
│  • Survivor Region 会被完整扫描                                             │
│  • 不需要 BOT 来定位对象起始位置                                             │
│  • 节省 BOT 更新开销                                                        │
│                                                                             │
│  OldGCAllocRegion: bot_updates = true                                      │
│  ──────────────────────────────────────                                    │
│  • Old Region 使用卡表追踪引用                                              │
│  • 需要 BOT 来定位卡内对象起始位置                                           │
│  • 必须在分配时更新 BOT                                                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 7. 内存布局

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    G1Allocator 内存布局                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  G1Allocator 对象                                                           │
│  ┌────────────────────────────────────────────────────────────────────┐    │
│  │ _g1h: G1CollectedHeap* ─────▶ G1CollectedHeap                      │    │
│  │ _survivor_is_full: false                                          │    │
│  │ _old_is_full: false                                               │    │
│  │ _retained_old_gc_alloc_region: NULL                               │    │
│  │                                                                    │    │
│  │ _mutator_alloc_region: MutatorAllocRegion                         │    │
│  │   ┌──────────────────────────────────────────────────────────┐    │    │
│  │   │ _alloc_region: HeapRegion* ─────▶ Eden Region (4MB)      │    │    │
│  │   │ _wasted_bytes: 0                                         │    │    │
│  │   │ _retained_alloc_region: NULL                             │    │    │
│  │   └──────────────────────────────────────────────────────────┘    │    │
│  │                                                                    │    │
│  │ _survivor_gc_alloc_region: SurvivorGCAllocRegion                  │    │
│  │   ┌──────────────────────────────────────────────────────────┐    │    │
│  │   │ _alloc_region: NULL (GC 时才分配)                         │    │    │
│  │   │ _bot_updates: false                                       │    │    │
│  │   │ _type: Young                                              │    │    │
│  │   └──────────────────────────────────────────────────────────┘    │    │
│  │                                                                    │    │
│  │ _old_gc_alloc_region: OldGCAllocRegion                            │    │
│  │   ┌──────────────────────────────────────────────────────────┐    │    │
│  │   │ _alloc_region: NULL (GC 时才分配)                         │    │    │
│  │   │ _bot_updates: true                                        │    │    │
│  │   │ _type: Old                                                │    │    │
│  │   └──────────────────────────────────────────────────────────┘    │    │
│  └────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 8. GDB 验证

### 8.1 GDB 脚本

```gdb
# 文件：jvm-md/tmp-file/universe-init/gdb_allocator.txt

b g1CollectedHeap.cpp:1507
commands
  silent
  printf "\n========== Verifier & Allocator Creation ==========\n"
  
  # G1HeapVerifier
  printf "----- G1HeapVerifier -----\n"
  printf "_verifier: %p\n", this->_verifier
  printf "_verifier->_g1h: %p (should match this: %p)\n", this->_verifier->_g1h, this
  
  # G1Allocator
  printf "\n----- G1Allocator -----\n"
  printf "_allocator: %p\n", this->_allocator
  printf "_survivor_is_full: %d\n", this->_allocator->_survivor_is_full
  printf "_old_is_full: %d\n", this->_allocator->_old_is_full
  printf "_retained_old_gc_alloc_region: %p\n", this->_allocator->_retained_old_gc_alloc_region
  
  continue
end
run
```

### 8.2 预期输出

```
========== Verifier & Allocator Creation ==========
----- G1HeapVerifier -----
_verifier: 0x7f...                          ✅
_verifier->_g1h: 0x7f... (should match this: 0x7f...)  ✅

----- G1Allocator -----
_allocator: 0x7f...                         ✅
_survivor_is_full: 0                        ✅ (false)
_old_is_full: 0                             ✅ (false)
_retained_old_gc_alloc_region: 0x0          ✅ (NULL)
```

---

## 9. 总结

### 9.1 G1HeapVerifier

| 特性 | 说明 |
|------|------|
| 用途 | 堆一致性验证（调试/诊断） |
| 触发 | `-XX:+VerifyBeforeGC`, `-XX:+VerifyAfterGC` |
| 验证类型 | young-normal, mixed, full 等 |

### 9.2 G1Allocator

| 特性 | 说明 |
|------|------|
| 用途 | 管理内存分配区域 |
| 三个区域 | Mutator（Eden）, Survivor, Old |
| Survivor BOT | false（不更新） |
| Old BOT | true（更新） |
| 初始状态 | 全部为空/false |

### 9.3 设计要点

1. **验证器**：轻量构造，仅保存 G1CollectedHeap 引用
2. **分配器**：三个分配区域对应三种分配场景
3. **BOT 优化**：Survivor 不更新 BOT，节省开销

---

## 待分析节点更新

| 节点 | 主题 | 状态 |
|------|------|------|
| B.1.1 | ParallelGCThreads 计算算法 | ✅ |
| F.1 | G1Predictions 预测器 | ✅ |
| E.5.1 | RefToScanQueue 工作窃取队列 | ✅ |
| D.4.1 | G1Policy 构造函数 | ✅ |
| F.2 | G1Analytics 分析器 | ✅ |
| F.3 | G1MMUTracker | ✅ |
| F.4 | G1IHOPControl | ✅ |
| C.1.1 | Region 大小计算算法 | ✅ |
| C.2 | RemSet 大小计算 | ✅ |
| C.3 | initialize_alignments() | ✅ |
| E.1 | WorkGang 创建 | ✅ |
| E.4 | 巨型对象阈值 | ✅ |
| F.5 | SurvRateGroup 存活率统计 | ✅ |
| **E.2** | **验证器和分配器** | **✅** |
