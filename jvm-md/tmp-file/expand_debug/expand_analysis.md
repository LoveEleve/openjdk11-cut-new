# expand() 方法 GDB 调试分析

## 调试环境
- JVM 参数: `-Xms8g -Xmx8g -XX:+UseG1GC`
- Region 大小: 4MB
- 总 Region 数: 2048

---

## 断点位置
`HeapRegionManager::make_regions_available()`

---

## 调用前状态 (执行 make_regions_available 之前)

### HeapRegionManager 对象 (this = 0x7ffff0032648)

```
HeapRegionManager {
    _regions = {
        _base = 0x7ffff0047180       // HeapRegion* 数组基址
        _length = 2048               // 数组长度
        _shift_by = 22               // 2^22 = 4MB (Region 大小)
    }
    
    _heap_mapper = 0x7ffff0043d90    // 主堆内存映射器
    _prev_bitmap_mapper = 0x7ffff0044c90
    _next_bitmap_mapper = 0x7ffff0045ee0
    _bot_mapper = 0x7ffff0043fa0
    _cardtable_mapper = 0x7ffff00443f0
    _card_counts_mapper = 0x7ffff0044840
    
    _free_list = {
        _length = 0                  // ⭐ 空闲列表为空
        _head = NULL
        _tail = NULL
        _name = "Free list"
    }
    
    _available_map = {
        _size = 2048                 // 位图大小
    }
    
    _num_committed = 0               // ⭐ 已提交 Region 数 = 0
    _allocated_heapregions_length = 0
}
```

### 主堆映射器 (_heap_mapper)

```
G1RegionsLargerThanCommitSizeMapper {
    _storage = {
        _low_boundary = 0x600000000   // 堆起始地址 (约 25.6GB 虚拟地址)
        _high_boundary = 0x800000000  // 堆结束地址 (32GB)
        _page_size = 4096             // 页大小 4KB
    }
    _region_granularity = 4194304     // Region 粒度 = 4MB
    _commit_map._size = 2048          // 2048 个 Region
}
```

### 调用参数

```
start = 0           // 从第 0 个 Region 开始
num_regions = 2048  // 扩展 2048 个 Region
pretouch_gang = 0x7ffff003f300  // WorkGang (13 个线程用于预触摸)
```

---

## 调用后状态 (执行 make_regions_available 之后)

### _num_committed 变化

```
调用前: _num_committed = 0
调用后: _num_committed = 2048  ✅
```

### _free_list 变化

```
调用前:
    _length = 0
    _head = NULL
    _tail = NULL

调用后:
    _length = 2048              ✅ 2048 个 Region 全部加入空闲列表
    _head = 0x7ffff009f160      // 第一个 HeapRegion
    _tail = 0x7ffff0c7d9a0      // 最后一个 HeapRegion
```

---

## 内存地址分布

```
虚拟地址空间:
┌────────────────────────────────────────────────────────────────┐
│                        Java Heap (8GB)                         │
├────────────────────────────────────────────────────────────────┤
│  起始: 0x600000000 (约 25.6GB)                                 │
│  结束: 0x800000000 (32GB)                                      │
│  大小: 0x200000000 = 8GB                                       │
└────────────────────────────────────────────────────────────────┘

Region 分布:
┌─────────┬─────────┬─────────┬─────────┬───────┬─────────┐
│ Region0 │ Region1 │ Region2 │   ...   │       │ R2047   │
│ 4MB     │ 4MB     │ 4MB     │         │       │ 4MB     │
├─────────┼─────────┼─────────┼─────────┼───────┼─────────┤
│0x600000 │0x600400 │0x600800 │         │       │0x7FFC00 │
│000      │000      │000      │         │       │000      │
└─────────┴─────────┴─────────┴─────────┴───────┴─────────┘
```

---

## 执行流程总结

```
make_regions_available(start=0, num_regions=2048)
    │
    ├─1. commit_regions(0, 2048)
    │       │
    │       ├── _num_committed: 0 → 2048
    │       ├── _heap_mapper->commit_regions()     // 提交 8GB 堆内存
    │       ├── _prev_bitmap_mapper->commit()      // 提交 prev 位图
    │       ├── _next_bitmap_mapper->commit()      // 提交 next 位图
    │       ├── _bot_mapper->commit()              // 提交 BOT
    │       ├── _cardtable_mapper->commit()        // 提交 CardTable
    │       └── _card_counts_mapper->commit()      // 提交 CardCounts
    │
    ├─2. 创建 HeapRegion 对象 (循环 2048 次)
    │       │
    │       └── for i in 0..2047:
    │               new_heap_region(i)
    │               _regions.set_by_index(i, new_hr)
    │
    ├─3. 标记为可用
    │       │
    │       └── _available_map.par_set_range(0, 2048)
    │
    └─4. 初始化并加入空闲列表
            │
            └── for i in 0..2047:
                    hr->initialize(mr)
                    insert_into_free_list(hr)
                    
    结果: _free_list._length = 2048 ✅
```

---

## 关键数据验证

| 指标 | 调用前 | 调用后 | 说明 |
|------|--------|--------|------|
| `_num_committed` | 0 | 2048 | 已提交 Region 数 |
| `_free_list._length` | 0 | 2048 | 空闲 Region 数 |
| `_free_list._head` | NULL | 0x7ffff009f160 | 第一个空闲 Region |
| `_free_list._tail` | NULL | 0x7ffff0c7d9a0 | 最后一个空闲 Region |

---

## 内存分配总结

| 组件 | 大小 | 说明 |
|------|------|------|
| 主堆 | 8GB | Java 对象存储 |
| prev_bitmap | ~128MB | 8GB ÷ 64 |
| next_bitmap | ~128MB | 8GB ÷ 64 |
| BOT | ~16MB | Block Offset Table |
| CardTable | ~16MB | 每 512B 一个字节 |
| CardCounts | ~16MB | 卡计数 |
| **总计** | **~8.3GB** | 物理内存 |
