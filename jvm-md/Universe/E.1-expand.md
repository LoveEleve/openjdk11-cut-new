# E.1 expand() - 堆扩展（从预留到提交）

> **这是 JVM 堆内存真正从"虚拟地址占位"变成"可用物理内存"的核心方法**

---

## 1. 核心概念：两阶段内存分配

Linux 内存分配采用**两阶段**模式：

| 阶段 | 系统调用 | 保护标志 | 物理内存 | 说明 |
|------|----------|----------|----------|------|
| **Reserve（预留）** | `mmap(..., PROT_NONE, ...)` | 不可读写 | ❌ 不分配 | 只占用虚拟地址空间 |
| **Commit（提交）** | `mmap(..., PROT_READ\|PROT_WRITE, MAP_FIXED, ...)` | 可读写 | ✅ 按需分配 | 真正分配物理页 |

```
┌─────────────────────────────────────────────────────────────────┐
│                     虚拟地址空间 (48位)                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   Phase 1: Reserve (mmap PROT_NONE)                             │
│   ┌────────────────────────────────────────────────────────┐    │
│   │ 0x600000000 ～ 0x800000000  (8GB 虚拟地址空间)          │    │
│   │ 状态：虚拟地址已占用，无物理内存                         │    │
│   │ 访问：任何读写都会 SIGSEGV                              │    │
│   └────────────────────────────────────────────────────────┘    │
│                            ↓                                     │
│   Phase 2: Commit (mmap PROT_READ|PROT_WRITE, MAP_FIXED)        │
│   ┌────────────────────────────────────────────────────────┐    │
│   │ 0x600000000 ～ 0x800000000  (8GB 可用堆内存)            │    │
│   │ 状态：虚拟地址映射到物理页（按需分配）                   │    │
│   │ 访问：正常读写                                          │    │
│   └────────────────────────────────────────────────────────┘    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. 完整调用链

```
G1CollectedHeap::initialize()                    [g1CollectedHeap.cpp:1879]
│
└── expand(init_byte_size, _workers)             [g1CollectedHeap.cpp:1348]
    │
    ├── 1. 对齐 expand_bytes（页对齐 + Region对齐）
    │
    └── 2. _hrm.expand_by(2048, workers)         [heapRegionManager.cpp:225]
        │
        └── expand_at(0, 2048, workers)          [heapRegionManager.cpp:230]
            │
            ├── 3. find_unavailable_from_idx()   找到未提交的 Region 范围
            │
            └── 4. make_regions_available(0, 2048, workers)  [heapRegionManager.cpp:152]
                │
                ├── 5. commit_regions(0, 2048)   [heapRegionManager.cpp:103]
                │   │
                │   ├── _heap_mapper->commit_regions()     提交 8GB 堆
                │   ├── _prev_bitmap_mapper->commit_regions()  提交 128MB
                │   ├── _next_bitmap_mapper->commit_regions()  提交 128MB
                │   ├── _bot_mapper->commit_regions()      提交 16MB
                │   ├── _cardtable_mapper->commit_regions() 提交 16MB
                │   └── _card_counts_mapper->commit_regions() 提交 16MB
                │       │
                │       └── G1RegionsLargerThanCommitSizeMapper::commit_regions()
                │           │
                │           └── _storage.commit(start_page, num_pages)
                │               │
                │               └── commit_internal()
                │                   │
                │                   └── commit_preferred_pages()
                │                       │
                │                       └── os::commit_memory_or_exit()
                │                           │
                │                           └── mmap(addr, 8GB, PROT_READ|PROT_WRITE,
                │                                    MAP_FIXED|MAP_ANONYMOUS, -1, 0)
                │
                ├── 6. 循环创建 2048 个 HeapRegion 对象
                │
                ├── 7. 设置 _available_map 位图（标记 Region 可用）
                │
                └── 8. 初始化每个 Region 并加入 _free_list
```

---

## 3. 源码逐层分析

### 3.1 入口：G1CollectedHeap::expand()

```cpp
// g1CollectedHeap.cpp:1348
bool G1CollectedHeap::expand(size_t expand_bytes, WorkGang* pretouch_workers, double* expand_time_ms) {
    // Step 1: 页对齐（通常 4KB）
    size_t aligned_expand_bytes = ReservedSpace::page_align_size_up(expand_bytes);
    
    // Step 2: Region 对齐（4MB）
    aligned_expand_bytes = align_up(aligned_expand_bytes, HeapRegion::GrainBytes);
    
    log_debug(gc, ergo, heap)(
        "Expand the heap. requested: " SIZE_FORMAT "B expansion: " SIZE_FORMAT "B",
        expand_bytes, aligned_expand_bytes);
    
    // Step 3: 检查是否已达最大
    if (is_maximal_no_gc()) {
        log_debug(gc, ergo, heap)("Did not expand (heap already fully expanded)");
        return false;
    }
    
    // Step 4: 计算需要扩展的 Region 数
    // 8GB / 4MB = 2048 个 Region
    uint regions_to_expand = (uint)(aligned_expand_bytes / HeapRegion::GrainBytes);
    
    // Step 5: 调用 HeapRegionManager 进行实际扩展
    uint expanded_by = _hrm.expand_by(regions_to_expand, pretouch_workers);
    
    if (expanded_by > 0) {
        size_t actual_expand_bytes = expanded_by * HeapRegion::GrainBytes;
        g1_policy()->record_new_heap_size(num_regions());
    }
    
    return expanded_by > 0;
}
```

**关键数据**（8GB 堆）：
- `expand_bytes` = 8GB = 8,589,934,592 字节
- `regions_to_expand` = 8GB / 4MB = 2048

### 3.2 核心：HeapRegionManager::expand_at()

```cpp
// heapRegionManager.cpp:230
uint HeapRegionManager::expand_at(uint start, uint num_regions, WorkGang* pretouch_workers) {
    if (num_regions == 0) return 0;
    
    uint cur = start;           // 当前搜索位置 = 0
    uint idx_last_found = 0;    // 找到的未分配 Region 起始索引
    uint num_last_found = 0;    // 找到的连续未分配 Region 数量
    uint expanded = 0;          // 已成功扩展的 Region 数量
    
    // 循环查找并分配可用的 Region 范围
    while (expanded < num_regions &&
           (num_last_found = find_unavailable_from_idx(cur, &idx_last_found)) > 0) {
        /*
         * find_unavailable_from_idx() 做了什么？
         * - 扫描 _available_map 位图（初始全为 0）
         * - 找到从索引 0 开始的连续未分配 Region
         * - 返回：num_last_found = 2048, idx_last_found = 0
         */
        uint to_expand = MIN2(num_regions - expanded, num_last_found);
        
        // ★ 核心方法：真正分配内存
        make_regions_available(idx_last_found, to_expand, pretouch_workers);
        
        expanded += to_expand;
        cur = idx_last_found + num_last_found + 1;
    }
    
    return expanded;  // 返回 2048
}
```

### 3.3 关键：HeapRegionManager::make_regions_available()

```cpp
// heapRegionManager.cpp:152
void HeapRegionManager::make_regions_available(uint start, uint num_regions, WorkGang* pretouch_gang) {
    guarantee(num_regions > 0, "No point in calling this for zero regions");
    
    // ========== Step 1: 提交虚拟内存（6 个 mapper 一起提交）==========
    commit_regions(start, num_regions, pretouch_gang);
    
    // ========== Step 2: 创建 HeapRegion 对象（2048 个）==========
    for (uint i = start; i < start + num_regions; i++) {
        if (_regions.get_by_index(i) == NULL) {
            // 创建 HeapRegion 对象（在 C++ 堆上）
            HeapRegion* new_hr = new_heap_region(i);
            
            // 内存屏障确保可见性
            OrderAccess::storestore();
            
            // 存储到 _regions 数组
            _regions.set_by_index(i, new_hr);
            
            // 更新已分配边界
            _allocated_heapregions_length = MAX2(_allocated_heapregions_length, i + 1);
        }
    }
    
    // ========== Step 3: 标记 Region 为可用 ==========
    /*
     * 位图结构（64 bit 一组）：
     * 字0:  [111...111] (Region 0-63)
     * 字1:  [111...111] (Region 64-127)
     * ...
     * 字31: [111...111] (Region 1984-2047)
     */
    _available_map.par_set_range(start, start + num_regions, BitMap::unknown_range);
    
    // ========== Step 4: 初始化 Region 并加入空闲列表 ==========
    for (uint i = start; i < start + num_regions; i++) {
        HeapRegion* hr = at(i);
        
        // 打印日志（如果启用 -Xlog:gc+region=trace）
        if (G1CollectedHeap::heap()->hr_printer()->is_active()) {
            G1CollectedHeap::heap()->hr_printer()->commit(hr);
        }
        
        // 计算 Region 内存范围
        HeapWord* bottom = G1CollectedHeap::heap()->bottom_addr_for_region(i);
        MemRegion mr(bottom, bottom + HeapRegion::GrainWords);
        
        // 初始化 Region（设置 _bottom, _end, _top）
        hr->initialize(mr);
        
        // ★ 加入空闲列表
        insert_into_free_list(at(i));
    }
}
```

### 3.4 提交内存：commit_regions()

```cpp
// heapRegionManager.cpp:103
void HeapRegionManager::commit_regions(uint index, size_t num_regions, WorkGang* pretouch_gang) {
    guarantee(num_regions > 0, "Must commit more than zero regions");
    
    // 更新已提交 Region 计数（0 → 2048）
    _num_committed += (uint)num_regions;
    
    // ★ 提交主堆内存（8GB）
    _heap_mapper->commit_regions(index, num_regions, pretouch_gang);
    
    // ★ 提交辅助数据结构（5 个 mapper）
    _prev_bitmap_mapper->commit_regions(index, num_regions, pretouch_gang);  // 128MB
    _next_bitmap_mapper->commit_regions(index, num_regions, pretouch_gang);  // 128MB
    _bot_mapper->commit_regions(index, num_regions, pretouch_gang);          // 16MB
    _cardtable_mapper->commit_regions(index, num_regions, pretouch_gang);    // 16MB
    _card_counts_mapper->commit_regions(index, num_regions, pretouch_gang);  // 16MB
}
```

### 3.5 映射器提交：G1RegionsLargerThanCommitSizeMapper

```cpp
// g1RegionToSpaceMapper.cpp:75
virtual void commit_regions(uint start_idx, size_t num_regions, WorkGang* pretouch_gang) {
    // 计算起始页号
    // 对于堆：_pages_per_region = 4MB / 4KB = 1024
    size_t start_page = (size_t)start_idx * _pages_per_region;
    
    // ★ 调用底层 G1PageBasedVirtualSpace::commit()
    // total_pages = 2048 * 1024 = 2,097,152 页
    bool zero_filled = _storage.commit(start_page, num_regions * _pages_per_region);
    
    // 可选：预触摸（AlwaysPreTouch 默认 false）
    if (AlwaysPreTouch) {
        _storage.pretouch(start_page, num_regions * _pages_per_region, pretouch_gang);
    }
    
    // 更新 _commit_map 位图
    _commit_map.set_range(start_idx, start_idx + num_regions);
    
    // 触发监听器回调
    fire_on_commit(start_idx, num_regions, zero_filled);
}
```

### 3.6 最底层：G1PageBasedVirtualSpace::commit()

```cpp
// g1PageBasedVirtualSpace.cpp:199
bool G1PageBasedVirtualSpace::commit(size_t start_page, size_t size_in_pages) {
    guarantee(is_area_uncommitted(start_page, size_in_pages), "Area not uncommitted");
    
    bool zero_filled = true;
    size_t end_page = start_page + size_in_pages;
    
    if (_special) {
        // 大页路径（跳过）
    } else {
        // ★ 普通内存：调用 commit_internal
        commit_internal(start_page, end_page);
    }
    
    // 更新已提交位图
    _committed.set_range(start_page, end_page);
    
    return zero_filled;
}
```

### 3.7 系统调用：commit_preferred_pages()

```cpp
// g1PageBasedVirtualSpace.cpp:131
void G1PageBasedVirtualSpace::commit_preferred_pages(size_t start, size_t num_pages) {
    // 计算起始地址
    // start = 0, _low_boundary = 0x600000000
    // start_addr = 0x600000000
    char* start_addr = page_start(start);
    
    // 计算大小
    // num_pages = 2,097,152, _page_size = 4KB
    // size = 2,097,152 * 4KB = 8GB
    size_t size = num_pages * _page_size;
    
    // ★★★ 核心系统调用 ★★★
    os::commit_memory_or_exit(start_addr, size, _page_size, _executable, ...);
    
    /*
     * 最终调用：
     * mmap(0x600000000,           // 地址（之前 reserve 时获得）
     *      8589934592,            // 大小（8GB）
     *      PROT_READ | PROT_WRITE,// 可读可写
     *      MAP_PRIVATE |          // 私有映射，写时复制
     *      MAP_FIXED |            // 使用指定地址
     *      MAP_ANONYMOUS,         // 匿名映射
     *      -1, 0);                // 无文件
     */
}
```

---

## 4. 内存分配详细数据

### 4.1 六个映射器的提交

| 映射器 | 大小 | 页数 | 用途 |
|--------|------|------|------|
| heap_mapper | 8GB | 2,097,152 | Java 堆 |
| prev_bitmap_mapper | 128MB | 32,768 | 并发标记位图 A |
| next_bitmap_mapper | 128MB | 32,768 | 并发标记位图 B |
| bot_mapper | 16MB | 4,096 | Block Offset Table |
| cardtable_mapper | 16MB | 4,096 | 卡表 |
| card_counts_mapper | 16MB | 4,096 | 热卡计数 |
| **总计** | **8.3GB** | **2,174,976** | |

### 4.2 HeapRegion 对象分配

```
HeapRegion 对象（C++ 堆）：
- 数量：2048 个
- 每个大小：约 200 字节
- 总计：2048 × 200B ≈ 400KB

存储位置：
- HeapRegion 对象本身：C++ 堆（malloc）
- HeapRegion 管理的内存：Java 堆（mmap）
```

---

## 5. GDB 验证

### 5.1 验证脚本

```bash
# 保存为 gdb_expand.txt
set pagination off
set logging file /tmp/expand_trace.log
set logging on

# 断点：expand 入口
b g1CollectedHeap.cpp:1348
commands
  printf "=== expand() called ===\n"
  printf "expand_bytes = %lu (%.2f GB)\n", expand_bytes, expand_bytes/1073741824.0
  continue
end

# 断点：计算 Region 数
b g1CollectedHeap.cpp:1373
commands
  printf "regions_to_expand = %u\n", regions_to_expand
  continue
end

# 断点：make_regions_available
b heapRegionManager.cpp:152
commands
  printf "=== make_regions_available(%u, %lu) ===\n", start, num_regions
  continue
end

# 断点：commit_regions
b heapRegionManager.cpp:112
commands
  printf "Committing heap: %u regions\n", num_regions
  continue
end

# 断点：系统调用
b g1PageBasedVirtualSpace.cpp:149
commands
  printf "mmap(%p, %lu bytes = %.2f GB)\n", start_addr, size, size/1073741824.0
  continue
end

# 断点：HeapRegion 创建
b heapRegionManager.cpp:163
commands
  printf "Creating HeapRegion[%u]\n", i
  if i % 512 == 0
    printf "  Progress: %u / 2048 regions\n", i
  end
  continue
end

# 断点：加入空闲列表
b heapRegionManager.cpp:203
commands
  printf "Region[%u] added to free_list\n", i
  if i % 512 == 0
    printf "  FreeList size: %u\n", _free_list._length
  end
  continue
end

run
```

### 5.2 运行方式

```bash
cd /data/workspace/openjdk-cut-new
gdb -x gdb_expand.txt --args build/linux-x86_64-server-slowdebug/jdk/bin/java \
  -Xms8g -Xmx8g -XX:+UseG1GC \
  -Xlog:gc+region=trace \
  -version
```

### 5.3 预期输出

```
=== expand() called ===
expand_bytes = 8589934592 (8.00 GB)
regions_to_expand = 2048

=== make_regions_available(0, 2048) ===
Committing heap: 2048 regions

mmap(0x600000000, 8589934592 bytes = 8.00 GB)  # 堆
mmap(0x..., 134217728 bytes = 0.13 GB)         # prev_bitmap
mmap(0x..., 134217728 bytes = 0.13 GB)         # next_bitmap
mmap(0x..., 16777216 bytes = 0.02 GB)          # bot
mmap(0x..., 16777216 bytes = 0.02 GB)          # cardtable
mmap(0x..., 16777216 bytes = 0.02 GB)          # card_counts

Creating HeapRegion[0]
  Progress: 0 / 2048 regions
Creating HeapRegion[512]
  Progress: 512 / 2048 regions
...

Region[0] added to free_list
Region[512] added to free_list
  FreeList size: 512
...
```

---

## 6. 日志验证

### 6.1 启用日志

```bash
java -Xms8g -Xmx8g -XX:+UseG1GC \
  -Xlog:gc+region=trace \
  -version
```

### 6.2 预期输出

```
[0.076s][trace][gc,region] G1HR COMMIT (FREE) [0x0000000600000000, 0x0000000600000000, 0x0000000600400000]
[0.076s][trace][gc,region] G1HR COMMIT (FREE) [0x0000000600400000, 0x0000000600400000, 0x0000000600800000]
...
[0.082s][trace][gc,region] G1HR COMMIT (FREE) [0x00000007ffc00000, 0x00000007ffc00000, 0x0000000800000000]
```

**日志格式解读**：
```
G1HR COMMIT (FREE) [bottom, top, end]
                    │      │    │
                    │      │    └── Region 结束地址（bottom + 4MB）
                    │      └─────── 当前分配位置（初始 = bottom）
                    └────────────── Region 起始地址
```

---

## 7. 关键数据结构状态

### 7.1 expand() 后的 HeapRegionManager

```
HeapRegionManager {
    _regions: G1HeapRegionTable {
        _base: 0x...,
        _length: 2048,
        [0]: HeapRegion* → 0x600000000 ~ 0x600400000
        [1]: HeapRegion* → 0x600400000 ~ 0x600800000
        ...
        [2047]: HeapRegion* → 0x7FC00000 ~ 0x800000000
    }
    
    _num_committed: 2048
    _allocated_heapregions_length: 2048
    
    _available_map: CHeapBitMap {
        size: 2048 bits
        words[0..31]: 0xFFFFFFFFFFFFFFFF (全1，表示全部可用)
    }
    
    _free_list: FreeRegionList {
        _head: HeapRegion[0]
        _tail: HeapRegion[2047]
        _length: 2048
    }
}
```

### 7.2 HeapRegion 对象状态

```
HeapRegion[0] {
    // 继承自 G1ContiguousSpace
    _bottom: 0x600000000    // Region 起始地址
    _end:    0x600400000    // Region 结束地址（bottom + 4MB）
    _top:    0x600000000    // 当前分配位置（初始 = bottom）
    
    // HeapRegion 特有
    _hrm_index: 0           // Region 索引
    _type: FreeRegionType   // 类型：空闲
    _next: HeapRegion[1]    // 空闲链表下一个
    _prev: NULL             // 空闲链表前一个
}
```

---

## 8. 内存布局总览

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        expand() 后的内存布局                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Java 堆（8GB，已提交）                                                  │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │ 0x600000000                                           0x800000000  │ │
│  │ ├──────┬──────┬──────┬─────────────────────────┬──────┤            │ │
│  │ │ R[0] │ R[1] │ R[2] │   ...  (2048 Regions)  │R[2047]│            │ │
│  │ │ 4MB  │ 4MB  │ 4MB  │                        │  4MB  │            │ │
│  │ ├──────┴──────┴──────┴─────────────────────────┴──────┤            │ │
│  │ │                全部在 FreeRegionList 中              │            │ │
│  │ └────────────────────────────────────────────────────────────────┘ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  辅助结构（304MB，已提交）                                               │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐                     │
│  │ BOT (16MB)   │ │CardTable(16MB│ │CardCounts(16M│                     │
│  └──────────────┘ └──────────────┘ └──────────────┘                     │
│                                                                          │
│  ┌────────────────────────┐ ┌────────────────────────┐                  │
│  │ Prev Bitmap (128MB)    │ │ Next Bitmap (128MB)    │                  │
│  └────────────────────────┘ └────────────────────────┘                  │
│                                                                          │
├─────────────────────────────────────────────────────────────────────────┤
│  总已提交内存：8GB + 304MB = 8.3GB                                       │
│  物理内存：按需分配（首次访问时触发缺页中断）                             │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 9. 关键设计要点

### 9.1 为什么要两阶段分配？

| 方案 | 优点 | 缺点 |
|------|------|------|
| 一次性分配 | 简单 | 浪费物理内存，启动慢 |
| **两阶段分配** | 节省物理内存，快速启动 | 首次访问有缺页开销 |

**实际效果**：
- JVM 启动时只 commit 地址空间，不分配物理内存
- 物理内存在首次访问时**按需分配**（缺页中断）
- 如果应用实际只用 2GB，物理内存也只消耗约 2GB

### 9.2 AlwaysPreTouch 参数

```bash
# 默认：不预触摸
java -Xms8g -Xmx8g ...
# 启动快，物理内存按需分配

# 预触摸：立即分配所有物理内存
java -Xms8g -Xmx8g -XX:+AlwaysPreTouch ...
# 启动慢（需要触摸所有页），但运行时无缺页开销
```

**生产建议**：
- 延迟敏感应用：使用 `-XX:+AlwaysPreTouch`
- 普通应用：保持默认

### 9.3 MAP_FIXED 的作用

```c
mmap(addr, size, prot, MAP_FIXED | MAP_ANONYMOUS, -1, 0);
                       ^^^^^^^^
```

- **必须使用 Reserve 时获得的地址**
- 如果不用 MAP_FIXED，内核可能返回其他地址
- 压缩指针等优化依赖固定地址

---

## 10. 总结

`expand()` 是 JVM 堆内存真正可用的关键步骤：

```
┌─────────────────────────────────────────────────────────────────┐
│                        expand() 做了什么？                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. 提交内存（6 个 mmap 调用）                                   │
│     ├── 堆：8GB                                                  │
│     └── 辅助：304MB                                              │
│                                                                  │
│  2. 创建 HeapRegion 对象（2048 个）                              │
│                                                                  │
│  3. 设置可用位图（全部标记为可用）                                │
│                                                                  │
│  4. 初始化 Region 并加入空闲列表                                 │
│                                                                  │
│  结果：2048 个 4MB Region 在 FreeRegionList 中等待分配           │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**下一步**：当应用创建对象时，G1Allocator 从 FreeRegionList 取出 Region 分配给 Eden 区。
