# G1CollectedHeap::initialize() 逐行深度源码分析 - Part 2

> **延续**: Part 1 (Lines 1587-1744)  
> **本章**: Lines 1745-2005 - 热卡缓存与内存映射器创建  
> **源码文件**: `src/hotspot/share/gc/g1/g1CollectedHeap.cpp`

---

## 第4章: 热卡缓存创建 (Lines 1746-1755)

### 4.1 G1HotCardCache初始化

```cpp
1746:     // Create the hot card cache.
1747:     /*
1748:    * note 问题背景
1749:    *  在 G1 GC 中，当应用线程修改对象引用时，会触发写后屏障，将对应的卡标记为"脏"。然后并发细化线程（Concurrent Refinement Thread） 会处理这些脏卡，更新 RSet。
1750:    * note 问题
1751:    *  有些卡被频繁修改（比如热点代码中的对象），如果每次修改都立即处理，会造成大量重复工作。
1752:    * note 解决方案 热卡缓存
1753:    *  对于频繁修改的"热卡"，先放入缓存，等到 GC 暂停时再统一处理，避免重复劳动。
1754:    */
1755:     _hot_card_cache = new G1HotCardCache(this);
```

**Line 1746-1755: 热卡缓存创建深度解析**

**问题背景 - 为什么要热卡缓存？**

```
+------------------------------------------------------------------------+
|                    热卡问题场景                                         |
+------------------------------------------------------------------------+
|                                                                         |
|  场景：热点循环中频繁修改对象引用                                        |
|  +------------------------------------------------------------------+   |
|  |  for (int i = 0; i < 1000000; i++) {                             |   |
|  |      sharedArray[i] = new Object();  // 每次触发写后屏障          |   |
|  |  }                                                               |   |
|  +------------------------------------------------------------------+   |
|                                                                         |
|  问题：如果不优化                                                       |
|  - 每次循环都标记卡为脏                                                 |
|  - 并发细化线程处理同一张卡100万次                                       |
|  - 99.9%的工作是重复的！                                                |
|                                                                         |
|  解决方案：G1HotCardCache                                               |
|  - 记录每张卡被修改的次数                                               |
|  - 超过阈值（默认4次）标记为"热卡"                                      |
|  - 热卡延迟到GC暂停时批量处理                                           |
+------------------------------------------------------------------------+
```

**G1HotCardCache数据结构：**

```cpp
// src/hotspot/share/gc/g1/g1HotCardCache.hpp
class G1HotCardCache : public CHeapObj<mtGC> {
private:
    G1CollectedHeap* _g1h;
    
    // 卡计数表 - 记录每张卡被修改的次数
    // 大小 = 卡表大小 = 堆大小/512字节
    G1CardCounts _card_counts;
    
    // 热卡阈值 - 超过此值视为热卡
    const size_t _hot_card_threshold;
    
    // 是否使用热卡缓存
    bool _use_cache;
    
public:
    // 判断是否为热卡
    bool is_hot(void* card_ptr);
    // 设置卡的热度
    void set_hot(void* card_ptr);
    // 获取热卡数量
    size_t num_hot_cards() const;
};
```

**热卡判定算法：**

```cpp
bool G1HotCardCache::is_hot(void* card_ptr) {
    if (!_use_cache) return false;
    
    // 获取当前计数
    uint count = _card_counts.get(card_ptr);
    
    // 超过阈值即为热卡
    return count >= _hot_card_threshold;
}

void G1HotCardCache::set_hot(void* card_ptr) {
    if (!_use_cache) return;
    
    // 增加计数
    uint count = _card_counts.get(card_ptr);
    if (count < _hot_card_threshold) {
        _card_counts.set(card_ptr, count + 1);
    }
}
```

**JVM参数控制：**

```bash
# 启用/禁用热卡缓存（默认启用）
-XX:+UseG1HotCardCache
-XX:-UseG1HotCardCache

# 热卡阈值（默认4）
-XX:G1HotCardCountThreshold=4

# 查看热卡统计（调试版本）
-XX:+UnlockDiagnosticVMOptions -XX:+G1PrintHotCardCacheStats
```

**GDB验证热卡缓存：**

```bash
(gdb) p *_hot_card_cache
$1 = {
    _g1h = 0x7ffff0028c50,
    _hot_card_threshold = 4,
    _use_cache = true,
    _card_counts = {
        _counts_table = 0x7ffff0030000,  // 卡计数表起始地址
        _max_card_num = 16777216         // 16M张卡（8GB堆）
    }
}

# 查看特定卡的热度
(gdb) p _hot_card_cache->_card_counts.get(card_address)
```

**面试高频问题Q&A：**

**Q11: 热卡缓存和卡表是什么关系？**
```
A: 两层结构协同工作：

┌─────────────────────────────────────────────────────────────┐
│                     写后屏障处理流程                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. 应用线程修改引用                                         │
│     obj.field = new_val;                                    │
│                                                             │
│  2. 写后屏障触发                                             │
│     ├─ 计算卡地址: card = (addr >> 9) + card_table_base    │
│     ├─ 检查是否热卡: if (hot_card_cache->is_hot(card))     │
│     │   ├─ 是热卡 → 跳过，不加入DCQS                        │
│     │   └─ 非热卡 → 增加计数，标记卡为脏                    │
│     └─ 标记卡为脏: *card = dirty_card;                      │
│                                                             │
│  3. 并发细化线程                                             │
│     ├─ 处理DCQS中的脏卡                                      │
│     └─ 热卡在GC暂停时批量处理                                │
│                                                             │
│  4. GC暂停时                                                 │
│     └─ 处理所有热卡，重置计数                                │
└─────────────────────────────────────────────────────────────┘

关系：
- 卡表：记录哪些内存区域被修改（布尔值）
- 热卡缓存：记录修改频率（计数器）
- 热卡是卡表的"上层过滤"，减少重复工作
```

**Q12: 热卡阈值为什么是4？可以调整吗？**
```
A: 4是经验值，基于以下权衡：

阈值太低（如1）：
- 几乎所有卡都变成热卡
- 失去并发细化的意义
- GC暂停时工作量过大

阈值太高（如100）：
- 热卡判定延迟
- 并发细化线程重复处理多
- 失去缓存意义

调整建议：
- 写密集型应用：尝试提高到8-16
- 读密集型应用：可以降低到2
- 监控：-XX:+G1PrintHotCardCacheStats观察热卡比例
```

---

## 第5章: 内存映射器创建 (Lines 1757-2005)

### 5.1 堆存储映射器创建

```cpp
1777:     // forcus 从已预留的堆空间中切分出指定大小的前半部分
1778:     // note 通常情况下,这里的 g1_rs 和之前创建的 heap_rs 是一样的
1779:     // 从heap_rs.size()中划分出max_byte_size(-Xmx)区域
1780:     ReservedSpace g1_rs = heap_rs.first_part(max_byte_size);
1781:     // 获取页面大小,通常不会开启大页,默认为4KB
1782:     size_t page_size = UseLargePages ? os::large_page_size() : os::vm_page_size();
```

**Line 1780: ReservedSpace切分深度解析**

```cpp
ReservedSpace g1_rs = heap_rs.first_part(max_byte_size);
```

**为什么需要切分？**

```
+------------------------------------------------------------------+
|                    ReservedSpace 切分示意图                       |
+------------------------------------------------------------------+
|                                                                   |
|  heap_rs (预留的总空间)                                            |
|  ├─────────────────────────────────────────────────────────┤     |
|  │                                                          │     |
|  │  g1_rs (G1堆使用)      │  noaccess_prefix (保护区域)      │     |
|  │  ├─────────────────┤   │  ├─────────────────────────┤    │     |
|  │  │                 │   │  │  不可访问，用于检测越界  │    │     |
|  │  │   G1 Heap       │   │  │  通常1个Region大小       │    │     |
|  │  │   (-Xmx)        │   │  │                          │    │     |
|  │  │                 │   │  │                          │    │     |
|  │  └─────────────────┘   │  └─────────────────────────┘    │     |
|  │                        │                                  │     |
|  └─────────────────────────────────────────────────────────┘     |
|                                                                   |
|  注意：当压缩指针启用且堆<32GB时，heap_rs可能比-Xmx大一个Region    │
|        这是为了对齐到32GB边界                                      │
+------------------------------------------------------------------+
```

**Line 1782: 页面大小选择**

```cpp
size_t page_size = UseLargePages ? os::large_page_size() : os::vm_page_size();
```

**页面大小对比：**

| 类型 | 大小 | 获取方式 | 适用场景 |
|------|------|----------|----------|
| 普通页 | 4KB | `os::vm_page_size()` | 默认，通用 |
| 大页(HugeTLB) | 2MB | `os::large_page_size()` | 大堆，减少TLB miss |
| 巨页 | 1GB | 需特殊配置 | TB级堆 |

**大页配置：**
```bash
# 系统层面配置大页
$ echo 1024 > /proc/sys/vm/nr_hugepages  # 预留1024个2MB大页 = 2GB

# JVM启动参数
$ java -XX:+UseLargePages -Xms8g -Xmx8g -XX:+UseG1GC ...

# 验证大页使用
$ cat /proc/$(pgrep java)/smaps | grep -A5 "AnonymousHugePages"
```

**GDB验证页面大小：**
```bash
(gdb) p UseLargePages
$1 = false

(gdb) p os::vm_page_size()
$2 = 4096  // 4KB

(gdb) p os::large_page_size()
$3 = 2097152  // 2MB
```

---

### 5.2 堆存储映射器创建

```cpp
1801:     G1RegionToSpaceMapper *heap_storage =
1802:             G1RegionToSpaceMapper::create_mapper(g1_rs, // 预留的虚拟地址空间
1803:                                                  g1_rs.size(), // 实际使用大小
1804:                                                  page_size, // 页面大小
1805:                                                  HeapRegion::GrainBytes, // Region大小
1806:                                                  1, // commit_factor
1807:                                                  mtJavaHeap); // 内存类型标记
```

**Line 1801-1807: 堆存储映射器创建深度解析**

**G1RegionToSpaceMapper类层次：**

```cpp
// 抽象基类
class G1RegionToSpaceMapper : public CHeapObj<mtGC> {
public:
    // 创建具体实现
    static G1RegionToSpaceMapper* create_mapper(...);
    
    // 提交/释放Region对应的内存
    virtual void commit_regions(uint start_idx, size_t num_regions) = 0;
    virtual void uncommit_regions(uint start_idx, size_t num_regions) = 0;
    
    // 获取预留区域
    MemRegion reserved() const { return _reserved; }
    
protected:
    MemRegion _reserved;  // 预留的虚拟地址空间
};

// 两种具体实现
class G1RegionsSmallerThanCommitSizeMapper : public G1RegionToSpaceMapper {
    // Region < 页大小：多个Region共享一页
};

class G1RegionsLargerThanCommitSizeMapper : public G1RegionToSpaceMapper {
    // Region >= 页大小：一个Region可能跨多页
};
```

**创建逻辑选择：**

```cpp
G1RegionToSpaceMapper* G1RegionToSpaceMapper::create_mapper(
    ReservedSpace rs, size_t actual_size, size_t page_size,
    size_t region_granularity, size_t commit_factor, MemoryType type) {
    
    if (region_granularity < page_size) {
        // Region小于页大小（如1MB Region + 4KB页）
        return new G1RegionsSmallerThanCommitSizeMapper(...);
    } else {
        // Region大于等于页大小（标准情况：4MB Region + 4KB页）
        return new G1RegionsLargerThanCommitSizeMapper(...);
    }
}
```

**标准条件（8GB堆）：**
- Region大小 = 4MB
- 页大小 = 4KB
- 4MB > 4KB，使用`G1RegionsLargerThanCommitSizeMapper`

**内存映射关系：**

```
+------------------------------------------------------------------+
|              G1RegionsLargerThanCommitSizeMapper 映射关系         |
+------------------------------------------------------------------+
|                                                                   |
|  虚拟地址空间              物理内存分配                            |
|  ├─────────────────┤      ├─────────────────┤                     |
|  │   Region 0      │─────>│   4MB物理页      │ 提交时分配          |
|  │   (4MB)         │      │   (1024个4KB页)  │                     |
|  ├─────────────────┤      ├─────────────────┤                     |
|  │   Region 1      │─────>│   4MB物理页      │                     |
|  │   (4MB)         │      │                 │                     |
|  ├─────────────────┤      ├─────────────────┤                     |
|  │      ...        │      │      ...        │                     |
|  ├─────────────────┤      ├─────────────────┤                     |
|  │   Region 2047   │─────>│   4MB物理页      │                     |
|  │   (4MB)         │      │                 │                     |
|  └─────────────────┘      └─────────────────┘                     |
|                                                                   |
|  总计：8GB虚拟空间，初始0物理内存，按需提交                        │
+------------------------------------------------------------------+
```

**GDB验证映射器：**
```bash
(gdb) p *heap_storage
$1 = {
    _vptr.G1RegionToSpaceMapper = 0x7ffff68d6000,
    _reserved = {
        _start = 0x7f0000000000,
        _word_size = 1073741824  // 1G HeapWords = 8GB
    },
    _region_granularity = 524288,  // 4MB / 8 = 524288 HeapWords
    _page_size = 4096,
    _commit_map = {
        _num_regions = 2048,
        _bitmap = 0x7ffff0031000  // 提交状态位图
    }
}
```

---

### 5.3 辅助数据结构映射器创建

```cpp
1820:     // Create storage for the BOT, card table, card counts table (hot card cache) and the bitmaps.
1821:     // forcus BOT(Block Offset Table) - 用于快速定位对象起始地址
1822:     G1RegionToSpaceMapper *bot_storage =
1823:             create_aux_memory_mapper("Block Offset Table",
1824:                                      G1BlockOffsetTable::compute_size(g1_rs.size() / HeapWordSize),
1825:                                      G1BlockOffsetTable::heap_map_factor());
1826:     // forcus 跟踪跨代引用和并发标记
1827:     G1RegionToSpaceMapper *cardtable_storage =
1828:             create_aux_memory_mapper("Card Table",
1829:                                      G1CardTable::compute_size(g1_rs.size() / HeapWordSize),
1830:                                      G1CardTable::heap_map_factor());
1831:     // forcus 热卡缓存优化
1832:     G1RegionToSpaceMapper *card_counts_storage =
1833:             create_aux_memory_mapper("Card Counts Table",
1834:                                      G1CardCounts::compute_size(g1_rs.size() / HeapWordSize),
1835:                                      G1CardCounts::heap_map_factor());
```

**Line 1820-1835: 三个辅助映射器创建**

**辅助数据结构大小计算（8GB堆）：**

| 数据结构 | 计算方式 | 大小 | 比例 |
|----------|----------|------|------|
| BOT | 8GB / 512B × 1字节 | 16MB | 0.2% |
| Card Table | 8GB / 512B × 1字节 | 16MB | 0.2% |
| Card Counts | 8GB / 512B × 1字节 | 16MB | 0.2% |

**create_aux_memory_mapper vs create_mapper区别：**

```cpp
// create_mapper - 使用已有的ReservedSpace
G1RegionToSpaceMapper::create_mapper(
    ReservedSpace rs,  // 传入已预留的空间
    ...
);

// create_aux_memory_mapper - 创建新的ReservedSpace
G1CollectedHeap::create_aux_memory_mapper(
    const char* name,
    size_t size,       // 需要的大小
    size_t factor      // 对齐因子
) {
    // 内部调用新的mmap
    ReservedSpace rs(size, factor, false);
    return G1RegionToSpaceMapper::create_mapper(rs, ...);
}
```

**关键区别：**
- `heap_storage`：使用与Java堆相同的虚拟地址空间
- `bot_storage/cardtable_storage/card_counts_storage`：独立的虚拟地址空间

**为什么辅助结构要独立？**
1. **权限隔离**：堆内存是读写执行，辅助结构只需读写
2. **独立管理**：可以独立commit/uncommit
3. **NUMA优化**：可以绑定到不同节点

**GDB验证辅助映射器：**
```bash
(gdb) p *bot_storage
$1 = {
    _reserved = {
        _start = 0x7f1ff0000000,  // 独立地址空间
        _word_size = 2097152      // 16MB / 8 = 2M HeapWords
    }
}

(gdb) p *cardtable_storage
$2 = {
    _reserved = {
        _start = 0x7f1fe0000000,  // 独立地址空间
        _word_size = 2097152
    }
}
```

---

### 5.4 并发标记位图映射器创建

```cpp
1845:     size_t bitmap_size = G1CMBitMap::compute_size(g1_rs.size()); // 计算位图大小
1846:     /*
1847:    * 涉及到的一些jvm参数：
1848:    *  -XX:+UseLargePages：false  启用大页
1849:    *  -XX:+AlwaysPreTouch: false  启动时预触摸所有内存
1850:    *  -XX:G1HeapRegionSize: 自动  Region大小
1851:    *  -Xms / -Xmx: -  堆大小
1852:    */
1853:     /*
1854:    * note prev_bitmap_storage
1855:    *  - 存储上一轮并发标记的结果：保存已完成的标记周期中所有存活对象的标记信息
1856:    *  - 增量收集的基础：在Mixed GC中，作为判断老年代对象存活性的依据
1857:    *  - 稳定的引用基准：提供一个"快照"，避免并发标记过程中的不一致性
1858:    */
1859:     /*
1860:    * note next_bitmap_storage
1861:    *  - 存储当前并发标记的结果：正在进行的标记周期中新发现的存活对象
1862:    *  - 并发标记的工作区：标记线程在此位图上设置新的标记位
1863:    *  - 双缓冲机制：完成后与prev_bitmap交换，实现无锁切换
1864:    */
```

**Line 1845: 位图大小计算**

```cpp
size_t bitmap_size = G1CMBitMap::compute_size(g1_rs.size());
```

**计算逻辑：**
```cpp
// src/hotspot/share/gc/g1/g1ConcurrentMarkBitMap.cpp
size_t G1CMBitMap::compute_size(size_t heap_size) {
    // 每64字节堆内存对应1个bit
    // 8GB堆: 8GB / 64 = 128MB位图
    return heap_size / (sizeof(HeapWord) * BitsPerByte);
}
```

**为什么是64字节？**
- 对象最小大小 = 16字节（对象头）
- 64字节覆盖4个最小对象
- 平衡精度和空间开销

**双缓冲位图机制：**

```
+------------------------------------------------------------------+
|                    双缓冲位图工作原理                             |
+------------------------------------------------------------------+
|                                                                   |
|  时间线 →                                                         |
|                                                                   |
|  T0: 初始状态                                                     |
|  ┌─────────────┐  ┌─────────────┐                                |
│  │ prev_bitmap │  │ next_bitmap │                                │
│  │  (空/无效)  │  │  (空)       │                                │
│  └─────────────┘  └─────────────┘                                │
│                                                                   │
│  T1: 并发标记开始                                                 │
│  ┌─────────────┐  ┌─────────────┐                                │
│  │ prev_bitmap │  │ next_bitmap │ ← 标记线程写入                 │
│  │  (上一轮)   │  │  (新标记)   │                                │
│  └─────────────┘  └─────────────┘                                │
│                                                                   │
│  T2: Mixed GC使用prev_bitmap                                      │
│  ┌─────────────┐  ┌─────────────┐                                │
│  │ prev_bitmap │ ← Mixed GC读取  │                                │
│  │  (稳定快照) │  │ next_bitmap │                                │
│  └─────────────┘  └─────────────┘                                │
│                                                                   │
│  T3: 标记完成，交换指针                                           │
│  ┌─────────────┐  ┌─────────────┐                                │
│  │ prev_bitmap │←→│ next_bitmap │ swap(&prev, &next)             │
│  │  (新结果)   │  │  (清空)     │                                │
│  └─────────────┘  └─────────────┘                                │
│                                                                   │
│  交换操作是O(1)的原子指针交换！                                     │
+------------------------------------------------------------------+
```

**面试高频问题Q&A：**

**Q13: 为什么需要两个位图，一个不够吗？**
```
A: 并发场景下的读写冲突：

单一位图的问题：
┌─────────────────────────────────────────────────────────────┐
│  时间线                                                       │
│                                                              │
│  T1: 并发标记线程标记对象A为存活                              │
│      write(bitmap[A]) = 1                                    │
│                                                              │
│  T2: Mixed GC线程读取对象B的存活状态                          │
│      if (read(bitmap[B]) == 1) keep(B)                       │
│                                                              │
│  问题：如果只有一个位图                                       │
│  - 标记线程还在写（标记过程未完成）                           │
│  - GC线程在读（看到不完整的状态）                             │
│  - 可能漏标或误标！                                          │
└─────────────────────────────────────────────────────────────┘

双位图解决方案：
- prev_bitmap：上一轮完成的标记结果（只读，稳定）
- next_bitmap：当前正在进行的标记（可写，工作区）
- Mixed GC只读prev_bitmap，不受并发标记影响
- 标记完成后原子交换指针
```

**Q14: 位图大小为什么是堆大小的1/64？**
```
A: 空间与精度的权衡：

计算公式：
位图大小 = 堆大小 / (对象对齐粒度 × 8)
         = 8GB / (8字节 × 8)
         = 8GB / 64
         = 128MB

为什么是8字节对齐？
- 64位JVM对象按8字节对齐
- 8字节 = 2^3，可以用3位表示偏移
- 位图索引 = (addr - heap_base) >> 6  // 64 = 2^6

对比其他GC：
- CMS：也是1/64
- ZGC：1/64，但使用染色指针，不需要单独位图
- Shenandoah：1/64
```

---

## 第6章: HeapRegionManager初始化 (Lines 2000-2044)

### 6.1 位图存储映射器创建

```cpp
1990:     G1RegionToSpaceMapper *prev_bitmap_storage =
1991:             create_aux_memory_mapper("Prev Bitmap", bitmap_size, G1CMBitMap::heap_map_factor());
1998:     G1RegionToSpaceMapper *next_bitmap_storage =
1999:             create_aux_memory_mapper("Next Bitmap", bitmap_size, G1CMBitMap::heap_map_factor());
```

**Line 1990-1999: 两个位图映射器创建**

```cpp
// 8GB堆，bitmap_size = 128MB
G1RegionToSpaceMapper* prev_bitmap_storage = 
    create_aux_memory_mapper("Prev Bitmap", 128*1024*1024, 1);
    
G1RegionToSpaceMapper* next_bitmap_storage = 
    create_aux_memory_mapper("Next Bitmap", 128*1024*1024, 1);
```

**6个映射器总结：**

```
+------------------------------------------------------------------+
|                    G1 GC 6个内存映射器                            |
+----------+----------------+----------------+---------------------+
|  映射器   |    用途         |    大小(8GB堆)  |     创建方式       │
+----------+----------------+----------------+---------------------+
| heap     | Java堆内存      | 8GB            | create_mapper      │
| bot      | 块偏移表        | 16MB           | create_aux_...     │
| cardtable| 卡表            | 16MB           | create_aux_...     │
| counts   | 卡计数表        | 16MB           | create_aux_...     │
| prev_bm  | 上一轮标记位图  | 128MB          | create_aux_...     │
| next_bm  | 当前标记位图    | 128MB          | create_aux_...     │
+----------+----------------+----------------+---------------------+
总计辅助结构：320MB（约堆大小的4%）
```

---

### 6.2 HeapRegionManager初始化调用

```cpp
2004:     _hrm.initialize(heap_storage, prev_bitmap_storage, next_bitmap_storage, 
2005:                     bot_storage, cardtable_storage, card_counts_storage);
```

**Line 2004-2005: HeapRegionManager初始化深度解析**

**调用目标：**
```cpp
// src/hotspot/share/gc/g1/heapRegionManager.cpp
void HeapRegionManager::initialize(
    G1RegionToSpaceMapper* heap_storage,
    G1RegionToSpaceMapper* prev_bitmap,
    G1RegionToSpaceMapper* next_bitmap,
    G1RegionToSpaceMapper* bot,
    G1RegionToSpaceMapper* cardtable,
    G1RegionToSpaceMapper* card_counts) {
    
    _allocated_heapregions_length = 0;
    
    // 保存6个映射器
    _heap_mapper = heap_storage;
    _prev_bitmap_mapper = prev_bitmap;
    _next_bitmap_mapper = next_bitmap;
    _bot_mapper = bot;
    _cardtable_mapper = cardtable;
    _card_counts_mapper = card_counts;
    
    // 初始化区域表
    MemRegion reserved = heap_storage->reserved();
    _regions.initialize(reserved.start(), reserved.end(), HeapRegion::GrainBytes);
    
    // 初始化可用性位图
    _available_map.initialize(_regions.length());
}
```

**G1HeapRegionTable初始化：**

```cpp
// _regions类型: G1HeapRegionTable
// 继承自: G1BiasedMappedArray<HeapWord*, HeapRegion*>

void initialize(HeapWord* start, HeapWord* end, size_t granularity) {
    // 计算Region数量
    size_t num_regions = (end - start) * HeapWordSize / granularity;
    // 8GB / 4MB = 2048个Region
    
    // 分配数组
    _data = NEW_C_HEAP_ARRAY(HeapRegion*, num_regions, mtGC);
    // 初始化为NULL
    for (size_t i = 0; i < num_regions; i++) {
        _data[i] = NULL;
    }
}
```

**区域表结构：**

```
+------------------------------------------------------------------+
|                    G1HeapRegionTable 结构                         |
+------------------------------------------------------------------+
|                                                                   |
|  虚拟地址: 0x7f0000000000                                         │
|                                                                   |
|  _regions数组（HeapRegion* [2048]）                                │
|  ┌─────────┬──────────────────────────────────────────┐          │
|  │ Index 0 │ HeapRegion* (初始NULL，commit时创建)      │ ────────┼──> 0x7f0000000000
|  ├─────────┼──────────────────────────────────────────┤          │    Region 0 (4MB)
|  │ Index 1 │ HeapRegion*                              │ ────────┼──> 0x7f0000400000
|  ├─────────┼──────────────────────────────────────────┤          │    Region 1 (4MB)
|  │   ...   │         ...                              │          │
|  ├─────────┼──────────────────────────────────────────┤          │
|  │Index2047│ HeapRegion*                              │ ────────┼──> 0x7f1fffc00000
|  └─────────┴──────────────────────────────────────────┘          │    Region 2047
|                                                                   │
|  地址到Index转换: index = (addr - base) >> 22                     │
|  4MB = 2^22，所以右移22位                                          │
+------------------------------------------------------------------+
```

**_available_map位图：**

```cpp
// CHeapBitMap _available_map;
// 作用：标记哪些Region已提交并可用

// 初始化：2048位 = 256字节
_available_map.initialize(2048);

// 使用：
// commit_regions()时：_available_map.set_bit(index);
// uncommit_regions()时：_available_map.clear_bit(index);
```

**GDB验证HeapRegionManager：**
```bash
(gdb) p this->_hrm
$1 = {
    _regions = {
        _base = 0x7f0000000000,
        _length = 2048,
        _data = 0x7ffff0032000  // HeapRegion*数组
    },
    _heap_mapper = 0x7ffff002b000,
    _prev_bitmap_mapper = 0x7ffff002c000,
    _next_bitmap_mapper = 0x7ffff002d000,
    _available_map = {
        _map = 0x7ffff0034000,  // 位图数据
        _size = 2048
    },
    _num_committed = 0  // 初始0个Region已提交
}
```

---

## 本章总结

本章完成了G1CollectedHeap::initialize()的Lines 1745-2005分析，涵盖：

1. **热卡缓存创建** (Lines 1746-1755)
   - G1HotCardCache解决热点卡重复处理问题
   - 默认阈值4次，可配置
   - 延迟到GC暂停批量处理

2. **6个内存映射器创建** (Lines 1757-2005)
   - heap_storage: Java堆内存（8GB）
   - bot_storage: 块偏移表（16MB）
   - cardtable_storage: 卡表（16MB）
   - card_counts_storage: 卡计数表（16MB）
   - prev_bitmap_storage: 上一轮标记位图（128MB）
   - next_bitmap_storage: 当前标记位图（128MB）

3. **HeapRegionManager初始化** (Lines 2004-2005)
   - 创建2048个Region的索引表
   - 初始化可用性位图
   - 保存6个映射器引用

**关键数据（8GB堆标准条件）：**
- Region数量: 2048个
- Region大小: 4MB
- 辅助结构总大小: ~320MB（4%堆大小）
- 初始提交Region: 0个（按需提交）

下一章将分析：
- 卡表与热卡缓存初始化 (Lines 2006-2010)
- G1RemSet初始化 (Lines 2021-2031)
- BOT创建 (Lines 2045-2048)
- 最终验证与完成
