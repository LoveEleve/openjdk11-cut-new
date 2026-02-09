# C.4 G1HotCardCache - 热卡缓存

> 延迟处理频繁修改的卡，避免并发精炼线程重复工作

---

## 1. 热卡问题

### 1.1 什么是热卡？

```
┌─────────────────────────────────────────────────────────────────────┐
│                       热卡问题场景                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  某些内存区域被频繁修改（如热点数据、缓存对象）：                    │
│                                                                      │
│  时间线:                                                             │
│  ───────────────────────────────────────────────────────────────    │
│   t1    t2    t3    t4    t5    t6    t7    t8                       │
│   ↓     ↓     ↓     ↓     ↓     ↓     ↓     ↓                       │
│  修改  修改  修改  修改  修改  修改  修改  修改   ← 同一张卡          │
│   ↓     ↓     ↓     ↓     ↓     ↓     ↓     ↓                       │
│  精炼  精炼  精炼  精炼  精炼  精炼  精炼  精炼   ← 8 次重复工作！   │
│                                                                      │
│  问题：                                                              │
│  - 同一张卡被反复标记为"脏"                                         │
│  - 精炼线程反复扫描同一个 512B 区域                                 │
│  - 大量 CPU 浪费在重复工作上                                        │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.2 解决方案：热卡缓存

```
┌─────────────────────────────────────────────────────────────────────┐
│                       热卡缓存机制                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  统计卡被修改的次数，超过阈值（4次）就是"热卡"                       │
│  热卡不立即精炼，放入缓存延迟处理                                   │
│                                                                      │
│  时间线:                                                             │
│  ───────────────────────────────────────────────────────────────    │
│   t1    t2    t3    t4    t5    t6    t7    t8    GC                 │
│   ↓     ↓     ↓     ↓     ↓     ↓     ↓     ↓     ↓                 │
│  修改  修改  修改  修改  修改  修改  修改  修改   │                  │
│  计数  计数  计数  计数   │                       │                  │
│  =1    =2    =3    =4    │                       │                  │
│  精炼  精炼  精炼  放入   放入  放入  放入  放入  批量               │
│                    缓存   缓存  缓存  缓存  缓存  精炼               │
│                                                   │                  │
│                                                   └─ 只精炼 1 次！   │
│                                                                      │
│  效果：8 次修改 → 只精炼 4 次（前 3 次 + GC 时 1 次批量）           │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. G1HotCardCache 类结构

### 2.1 类定义

```cpp
// g1HotCardCache.hpp:56-142

class G1HotCardCache: public CHeapObj<mtGC> {
  G1CollectedHeap*  _g1h;         // 堆引用
  
  bool              _use_cache;   // 是否启用缓存
  
  G1CardCounts      _card_counts; // 卡计数器（统计每张卡被修改的次数）
  
  // 热卡缓存数组
  jbyte**           _hot_cache;           // 缓存数组，存储卡指针
  size_t            _hot_cache_size;      // 缓存大小 = 1024
  size_t            _hot_cache_par_chunk_size;  // 并行处理块大小 = 32
  
  // 避免伪共享的填充
  char _pad_before[DEFAULT_CACHE_LINE_SIZE];  // 64B 填充
  
  volatile size_t _hot_cache_idx;              // 当前插入位置
  volatile size_t _hot_cache_par_claimed_idx;  // 并行处理进度
  
  char _pad_after[DEFAULT_CACHE_LINE_SIZE];   // 64B 填充
  
  static const int ClaimChunkSize = 32;  // 每个线程处理 32 个卡

public:
  // 判断是否启用缓存（G1ConcRSLogCacheSize > 0）
  static bool default_use_cache();
  
  // 插入卡到缓存，返回被驱逐的卡（如果有）
  jbyte* insert(jbyte* card_ptr);
  
  // GC 时批量精炼缓存中的卡
  void drain(CardTableEntryClosure* cl, uint worker_i);
};
```

### 2.2 内存布局

```
G1HotCardCache 对象:
┌────────────────────────────────────────────────────────────────────┐
│ _g1h                  │ → G1CollectedHeap*                         │ 8B
│ _use_cache            │ true                                       │ 1B
│ padding               │                                            │ 7B
│ _card_counts          │ G1CardCounts 内嵌对象                      │ ~40B
├────────────────────────────────────────────────────────────────────┤
│ _hot_cache            │ → jbyte*[1024]                             │ 8B
│ _hot_cache_size       │ 1024                                       │ 8B
│ _hot_cache_par_chunk_size │ 32                                     │ 8B
├────────────────────────────────────────────────────────────────────┤
│ _pad_before[64]       │ 缓存行填充                                 │ 64B
│ _hot_cache_idx        │ volatile，当前插入位置                     │ 8B
│ _hot_cache_par_claimed_idx │ volatile，并行处理进度                │ 8B
│ _pad_after[64]        │ 缓存行填充                                 │ 64B
└────────────────────────────────────────────────────────────────────┘

热卡缓存数组 (_hot_cache):
┌────────────────────────────────────────────────────────────────────┐
│ [0]  │ → 卡表中某张卡的地址 (jbyte*)                               │
│ [1]  │ → 卡表中某张卡的地址                                        │
│ [2]  │ → ...                                                       │
│ ...  │                                                             │
│ [1023] │ → 卡表中某张卡的地址                                      │
└────────────────────────────────────────────────────────────────────┘
总大小: 1024 × 8B = 8KB
```

---

## 3. G1CardCounts - 卡计数器

### 3.1 类定义

```cpp
// g1CardCounts.hpp:56-129

class G1CardCounts: public CHeapObj<mtGC> {
  G1CollectedHeap* _g1h;
  G1CardTable*     _ct;
  
  // 计数数组：每张卡对应 1 字节计数
  jubyte* _card_counts;
  
  // 最大卡数量
  size_t _reserved_max_card_num;
  
  // 卡表起始位置
  const jbyte* _ct_bot;

public:
  // 增加卡的计数，返回增加前的值
  uint add_card_count(jbyte* card_ptr);
  
  // 判断是否是热卡（count >= 4）
  bool is_hot(uint count);
  
  // 清除某个 Region 的计数
  void clear_region(HeapRegion* hr);
};
```

### 3.2 计数数组内存布局

```
G1CardCounts 与 G1CardTable 对齐:

堆内存:     [────────────────────── 8GB ──────────────────────]
            ↓ 每 512B 一张卡
CardTable:  [───────────────────── 16MB ─────────────────────]
            ↓ 每张卡对应 1 字节计数
CardCounts: [───────────────────── 16MB ─────────────────────]

示例:
┌─────────┬─────────┬─────────┬─────────┬─────────┬─────────┐
│  堆地址  │  0~512  │512~1024 │1024~1536│   ...   │         │
├─────────┼─────────┼─────────┼─────────┼─────────┼─────────┤
│ CardTable│  dirty  │  clean  │  dirty  │   ...   │  卡值   │
├─────────┼─────────┼─────────┼─────────┼─────────┼─────────┤
│CardCounts│    3    │    0    │    4    │   ...   │ 修改次数│
└─────────┴─────────┴─────────┴─────────┴─────────┴─────────┘
                                  ↑
                         计数=4，是热卡！
```

---

## 4. 初始化流程

### 4.1 G1HotCardCache 初始化

```cpp
// g1HotCardCache.cpp:71-99

void G1HotCardCache::initialize(G1RegionToSpaceMapper* card_counts_storage) {
  // Step 1: 检查是否启用缓存
  // G1ConcRSLogCacheSize 默认 = 10，即缓存大小 = 2^10 = 1024
  if (default_use_cache()) {
    _use_cache = true;
    
    // Step 2: 计算缓存大小
    _hot_cache_size = (size_t)1 << G1ConcRSLogCacheSize;  // 1024
    
    // Step 3: 分配热卡缓存数组
    // 1024 个 jbyte* 指针，共 8KB
    _hot_cache = ArrayAllocator<jbyte*>::allocate(_hot_cache_size, mtGC);
    
    // Step 4: 清零缓存
    reset_hot_cache_internal();  // 所有元素设为 NULL
    
    // Step 5: 设置并行处理参数
    _hot_cache_par_chunk_size = ClaimChunkSize;  // 32
    _hot_cache_par_claimed_idx = 0;
    
    // Step 6: 初始化卡计数器
    // 使用 card_counts_storage 提供的 16MB 内存
    _card_counts.initialize(card_counts_storage);
  }
}
```

### 4.2 G1CardCounts 初始化

```cpp
// g1CardCounts.cpp:65-91

void G1CardCounts::initialize(G1RegionToSpaceMapper* mapper) {
  // G1ConcRSHotCardLimit 默认 = 4
  // 修改次数 >= 4 就是热卡
  if (G1ConcRSHotCardLimit > 0) {
    // 获取卡表引用
    _ct = _g1h->card_table();
    
    // 计算卡表起始位置
    // _ct_bot = 卡表中对应堆起始地址的位置
    _ct_bot = _ct->byte_for_const(_g1h->reserved_region().start());
    
    // 获取计数数组存储空间
    // mapper 提供的是 card_counts_storage (16MB)
    _card_counts = (jubyte*) mapper->reserved().start();
    _reserved_max_card_num = mapper->reserved().byte_size();  // 16M 条计数
    
    // 设置内存提交监听器
    mapper->set_mapping_changed_listener(&_listener);
  }
}
```

---

## 5. 热卡判定与缓存插入

### 5.1 insert() - 插入逻辑

```cpp
// g1HotCardCache.cpp:110-132

jbyte* G1HotCardCache::insert(jbyte* card_ptr) {
  // Step 1: 增加卡的计数，获取增加前的值
  uint count = _card_counts.add_card_count(card_ptr);
  
  // Step 2: 判断是否是热卡
  if (!_card_counts.is_hot(count)) {
    // 不是热卡（count < 4），立即返回让精炼线程处理
    return card_ptr;
  }
  
  // Step 3: 是热卡，放入缓存
  // 原子增加索引
  size_t index = Atomic::add(1u, &_hot_cache_idx) - 1;
  // 环形缓冲：取模得到实际位置
  size_t masked_index = index & (_hot_cache_size - 1);
  
  // Step 4: 获取该位置原有的卡（可能被驱逐）
  jbyte* current_ptr = _hot_cache[masked_index];
  
  // Step 5: CAS 写入新卡
  jbyte* previous_ptr = Atomic::cmpxchg(card_ptr,
                                        &_hot_cache[masked_index],
                                        current_ptr);
  
  // Step 6: 返回被驱逐的卡（如果有）让精炼线程处理
  return (previous_ptr == current_ptr) ? previous_ptr : card_ptr;
}
```

### 5.2 插入流程图

```
┌─────────────────────────────────────────────────────────────────────┐
│                    热卡插入流程                                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  精炼线程处理脏卡:                                                  │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ card_ptr = 某张脏卡的地址                                    │   │
│  └───────────────────────────┬──────────────────────────────────┘   │
│                              ↓                                       │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ count = _card_counts.add_card_count(card_ptr)                │   │
│  │ // 增加计数：0→1, 1→2, 2→3, 3→4（最大4）                    │   │
│  └───────────────────────────┬──────────────────────────────────┘   │
│                              ↓                                       │
│  ┌────────────────────────────────────────────────────────────┐     │
│  │                    count < 4?                              │     │
│  │                         │                                  │     │
│  │    ┌────────────────────┼────────────────────┐            │     │
│  │    ↓ Yes                │                    ↓ No          │     │
│  │ 返回 card_ptr           │              放入热卡缓存        │     │
│  │ (立即精炼)              │              (延迟处理)          │     │
│  └────────────────────────────────────────────────────────────┘     │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 5.3 环形缓冲与驱逐

```
热卡缓存是环形缓冲，满了就驱逐旧卡:

初始状态 (_hot_cache_idx = 0):
┌─────┬─────┬─────┬─────┬─────┬─────┐
│NULL │NULL │NULL │NULL │ ... │NULL │  [0..1023]
└─────┴─────┴─────┴─────┴─────┴─────┘

插入 3 个热卡后 (_hot_cache_idx = 3):
┌─────┬─────┬─────┬─────┬─────┬─────┐
│ A   │ B   │ C   │NULL │ ... │NULL │  A, B, C 是卡指针
└─────┴─────┴─────┴─────┴─────┴─────┘

缓存满后继续插入 (_hot_cache_idx = 1025):
┌─────┬─────┬─────┬─────┬─────┬─────┐
│ X   │ B   │ C   │ D   │ ... │ W   │  
└─────┴─────┴─────┴─────┴─────┴─────┘
  ↑                                     
  位置 0 被新卡 X 覆盖                  
  原来的 A 被驱逐，返回给精炼线程处理    
```

---

## 6. GC 时批量处理

### 6.1 drain() - 排空热卡缓存

```cpp
// g1HotCardCache.cpp:134-159

void G1HotCardCache::drain(CardTableEntryClosure* cl, uint worker_i) {
  assert(!use_cache(), "cache should be disabled");  // GC 期间缓存被禁用
  
  // 多线程并行处理
  while (_hot_cache_par_claimed_idx < _hot_cache_size) {
    // Step 1: 原子获取一个处理块
    size_t end_idx = Atomic::add(_hot_cache_par_chunk_size,  // +32
                                 &_hot_cache_par_claimed_idx);
    size_t start_idx = end_idx - _hot_cache_par_chunk_size;
    
    // Step 2: 处理这个块中的卡
    end_idx = MIN2(end_idx, _hot_cache_size);
    for (size_t i = start_idx; i < end_idx; i++) {
      jbyte* card_ptr = _hot_cache[i];
      if (card_ptr != NULL) {
        // 精炼这张卡
        cl->do_card_ptr(card_ptr, worker_i);
      } else {
        break;  // 遇到空槽，后面都是空的
      }
    }
  }
  
  // 处理完后缓存会被 reset
}
```

### 6.2 GC 期间的处理流程

```
┌─────────────────────────────────────────────────────────────────────┐
│                    GC 期间热卡缓存处理                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  1. GC 开始前                                                       │
│     ┌───────────────────────────────────────────────────────────┐   │
│     │ _use_cache = false;  // 禁用缓存，新脏卡直接精炼          │   │
│     └───────────────────────────────────────────────────────────┘   │
│                                                                      │
│  2. 并行排空缓存                                                    │
│     ┌───────────────────────────────────────────────────────────┐   │
│     │ 多个 GC 线程并行:                                         │   │
│     │   Thread 0: 处理 [0, 32)                                  │   │
│     │   Thread 1: 处理 [32, 64)                                 │   │
│     │   Thread 2: 处理 [64, 96)                                 │   │
│     │   ...                                                     │   │
│     │   Thread 31: 处理 [992, 1024)                             │   │
│     │                                                           │   │
│     │ 每个卡: cl->do_card_ptr(card_ptr, worker_i)              │   │
│     │         → 扫描卡覆盖的 512B                               │   │
│     │         → 找出跨 Region 引用                              │   │
│     │         → 更新 RSet                                       │   │
│     └───────────────────────────────────────────────────────────┘   │
│                                                                      │
│  3. GC 结束后                                                       │
│     ┌───────────────────────────────────────────────────────────┐   │
│     │ reset_hot_cache();   // 清空缓存                          │   │
│     │ _use_cache = true;   // 重新启用缓存                      │   │
│     └───────────────────────────────────────────────────────────┘   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 7. 相关 JVM 参数

### 7.1 核心参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-XX:G1ConcRSLogCacheSize` | 10 | 热卡缓存大小 = 2^10 = 1024 |
| `-XX:G1ConcRSHotCardLimit` | 4 | 热卡阈值（修改 ≥4 次） |

### 7.2 参数调优

```
场景1: 写密集型应用，很多热卡
  → 增大 G1ConcRSLogCacheSize（如 12，缓存 4096 个卡）
  → 减少精炼线程的重复工作

场景2: 读多写少的应用
  → 减小 G1ConcRSLogCacheSize（如 8，缓存 256 个卡）
  → 节省内存

场景3: 想完全禁用热卡缓存
  → -XX:G1ConcRSLogCacheSize=0
  → 所有脏卡立即精炼
```

---

## 8. 与其他组件的协作

### 8.1 整体架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                    热卡缓存在 G1 中的位置                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Mutator 写引用                                                      │
│       │                                                              │
│       ↓                                                              │
│  写屏障: CardTable[idx] = dirty                                     │
│       │                                                              │
│       ↓                                                              │
│  DirtyCardQueue (TLS)                                               │
│       │                                                              │
│       ↓ 满了                                                        │
│  DirtyCardQueueSet (全局)                                           │
│       │                                                              │
│       ↓ 精炼线程取出                                                │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │              G1HotCardCache.insert(card_ptr)                │    │
│  │                         │                                   │    │
│  │           ┌─────────────┴─────────────┐                    │    │
│  │           ↓                           ↓                    │    │
│  │     count < 4                   count >= 4                 │    │
│  │     (冷卡)                       (热卡)                    │    │
│  │           │                           │                    │    │
│  │           ↓                           ↓                    │    │
│  │     立即精炼                    放入缓存                    │    │
│  │           │                     (延迟处理)                 │    │
│  │           ↓                           │                    │    │
│  │       更新 RSet          GC 时批量精炼 ←───────────────────┘    │
│  │                                       │                         │
│  │                                       ↓                         │
│  │                                   更新 RSet                     │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 8.2 内存开销总结

| 组件 | 大小 | 说明 |
|------|------|------|
| `_hot_cache` | 8KB | 1024 × 8B 指针数组 |
| `_card_counts` | 16MB | card_counts_storage 映射器 |
| G1HotCardCache 对象 | ~200B | 对象本身 |

---

## 9. 设计亮点

### 9.1 统计驱动的延迟处理

```
关键洞察：
- 热卡短时间内会被反复修改
- 立即精炼可能很快就失效
- 延迟处理让修改"稳定"后再精炼

效果：
- 减少重复精炼
- 节省 CPU
- 但不影响 GC 正确性（GC 时批量处理）
```

### 9.2 环形缓冲 + 驱逐机制

```
优点：
- 固定内存开销（8KB）
- 无需动态分配
- 自然淘汰最旧的热卡

驱逐策略：
- 被驱逐的卡立即精炼
- 保证不会遗漏
```

### 9.3 缓存行填充避免伪共享

```cpp
char _pad_before[DEFAULT_CACHE_LINE_SIZE];  // 64B
volatile size_t _hot_cache_idx;
volatile size_t _hot_cache_par_claimed_idx;
char _pad_after[DEFAULT_CACHE_LINE_SIZE];   // 64B
```

```
多线程并发更新索引时:
- 没有填充 → 两个索引在同一缓存行 → 伪共享 → 性能差
- 有填充 → 两个索引在不同缓存行 → 独立更新 → 性能好
```

---

## 10. 总结

### 10.1 G1HotCardCache 核心职责

| 功能 | 说明 |
|------|------|
| **识别热卡** | 通过 G1CardCounts 统计修改次数 |
| **延迟处理** | 热卡放入缓存，GC 时批量精炼 |
| **减少重复** | 避免精炼线程重复处理同一张卡 |
| **驱逐机制** | 缓存满时驱逐旧卡，保证不遗漏 |

### 10.2 关键数值（默认配置）

| 数值 | 含义 |
|------|------|
| 1024 | 热卡缓存容量 (`G1ConcRSLogCacheSize=10`) |
| 4 | 热卡阈值 (`G1ConcRSHotCardLimit`) |
| 32 | GC 时每个线程处理的块大小 |
| 16MB | 卡计数数组大小 |

### 10.3 简化理解

```
热卡缓存 = "写密集区域的缓冲区"

修改 < 4 次 → 冷卡 → 立即精炼
修改 ≥ 4 次 → 热卡 → 延迟精炼 → GC 时批量处理
```
