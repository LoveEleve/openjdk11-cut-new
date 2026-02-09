# C.6 G1BlockOffsetTable - 块偏移表

> BOT 实现 O(log n) 时间复杂度的对象起始地址查找，是 RSet 扫描和卡表处理的关键优化

---

## 1. BOT 解决的问题

### 1.1 问题：如何快速找到对象起始地址？

```
┌─────────────────────────────────────────────────────────────────────┐
│                    问题场景                                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  GC 扫描卡表时，拿到的是一个卡地址（512B 区域）:                    │
│                                                                      │
│  卡覆盖的 512B 区域:                                                │
│  ┌────────────────────────────────────────────────────────────┐     │
│  │  ████████  ░░░░░░░░░░░░░░░░░░░░░  ████████████  ░░░░░░░░░ │     │
│  │  │← 对象尾巴                   │← 对象 B      │← 对象头   │     │
│  │     (对象 A 的一部分)                                     │     │
│  └────────────────────────────────────────────────────────────┘     │
│       ↑                                                             │
│       卡起始地址                                                    │
│                                                                      │
│  问题：                                                              │
│  - 卡起始地址可能在某个对象的中间                                   │
│  - 必须找到第一个对象的起始地址才能正确扫描                         │
│  - 如何快速定位？                                                    │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.2 解决方案：块偏移表

```
┌─────────────────────────────────────────────────────────────────────┐
│                    BOT 原理                                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  每 512B 堆内存对应 1 字节 BOT 条目                                 │
│  条目值表示"向前回退多少个字（HeapWord）可以找到对象起始"          │
│                                                                      │
│  堆内存:                                                            │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ 卡 0        │ 卡 1        │ 卡 2        │ 卡 3        │     │    │
│  │ 0~512B      │ 512~1024B   │ 1024~1536B  │ 1536~2048B  │     │    │
│  │ ┌──────────┐│┌──────────┐│             │             │     │    │
│  │ │  Obj A   ││ Obj A 续 ││   Obj B     │   Obj C     │     │    │
│  │ │ (起始)   ││          ││  (起始)     │  (起始)     │     │    │
│  │ └──────────┘│└──────────┘│             │             │     │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                      │
│  BOT 数组:                                                          │
│  ┌────┬────┬────┬────┬─────────────────────────────────────────┐    │
│  │  0 │ 64 │  0 │  0 │  ...                                    │    │
│  └────┴────┴────┴────┴─────────────────────────────────────────┘    │
│    ↑     ↑     ↑     ↑                                              │
│    │     │     │     │                                              │
│    │     │     │     └─ 卡 3 起始就是对象 C 起始                    │
│    │     │     └─ 卡 2 起始就是对象 B 起始                          │
│    │     └─ 卡 1 起始需要回退 64 个字 (512B) 找到对象 A             │
│    └─ 卡 0 起始就是对象 A 起始                                      │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. BOT 常量定义

### 2.1 BOTConstants

```cpp
// blockOffsetTable.hpp:50-60

class BOTConstants : public AllStatic {
public:
  static const uint LogN = 9;       // log2(512) = 9
  static const uint LogN_words = LogN - LogHeapWordSize;  // 9 - 3 = 6
  static const uint N_bytes = 1 << LogN;      // 512 字节
  static const uint N_words = 1 << LogN_words; // 64 个 HeapWord
  
  // 对数跳跃参数（用于大对象优化）
  static const uint LogBase = 4;    // log2(16) = 4
  static const uint Base = (1 << LogBase);  // 16
  static const uint N_powers = 14;  // 最大跳跃次数
};
```

### 2.2 关键数值

| 常量 | 值 | 含义 |
|------|-----|------|
| `N_bytes` | 512 | 每个 BOT 条目覆盖 512 字节堆内存 |
| `N_words` | 64 | 512B / 8B = 64 个 HeapWord |
| `LogN` | 9 | log2(512) |
| `Base` | 16 | 对数跳跃的底数 |
| `N_powers` | 14 | 支持 16^14 = 2^56 字节的大对象 |

---

## 3. G1BlockOffsetTable 类

### 3.1 类定义

```cpp
// g1BlockOffsetTable.hpp:45-107

class G1BlockOffsetTable: public CHeapObj<mtGC> {
private:
  // 覆盖的堆区域
  MemRegion _reserved;
  
  // BOT 数组：每 512B 堆内存对应 1 字节
  volatile u_char* _offset_array;

public:
  // 计算 BOT 大小
  static size_t compute_size(size_t mem_region_words) {
    return mem_region_words / BOTConstants::N_words;
    // 8GB 堆: 8GB / 512B = 16MB
  }
  
  // 映射因子
  static size_t heap_map_factor() {
    return BOTConstants::N_bytes;  // 512
  }
  
  // 构造函数
  G1BlockOffsetTable(MemRegion heap, G1RegionToSpaceMapper* storage);
  
  // 地址 → 索引
  inline size_t index_for(const void* p) const;
  
  // 索引 → 地址
  inline HeapWord* address_for_index(size_t index) const;
};
```

### 3.2 构造函数

```cpp
// g1BlockOffsetTable.cpp:41-51

G1BlockOffsetTable::G1BlockOffsetTable(MemRegion heap, 
                                        G1RegionToSpaceMapper* storage) :
  _reserved(heap), _offset_array(NULL) {
  
  // 获取 bot_storage 的起始地址
  MemRegion bot_reserved = storage->reserved();
  
  // _offset_array 指向 bot_storage 的内存
  _offset_array = (u_char*)bot_reserved.start();
}
```

### 3.3 内存布局

```
G1BlockOffsetTable 对象:
┌────────────────────────────────────────────────────────────────────┐
│ _reserved           │ MemRegion (堆起始/结束)                      │ 16B
│ _offset_array       │ → u_char[16M] (bot_storage)                  │ 8B
└────────────────────────────────────────────────────────────────────┘

BOT 数组 (_offset_array):
┌────────────────────────────────────────────────────────────────────┐
│ 索引 0    │ 索引 1    │ 索引 2    │ ... │ 索引 16M-1              │
├───────────┼───────────┼───────────┼─────┼─────────────────────────┤
│ offset_0  │ offset_1  │ offset_2  │ ... │ offset_16M-1            │
│ (1 字节)  │ (1 字节)  │ (1 字节)  │     │ (1 字节)                │
└───────────┴───────────┴───────────┴─────┴─────────────────────────┘

映射关系:
- 堆地址 addr → BOT 索引 = (addr - heap_start) >> 9
- BOT 索引 i → 堆地址 = heap_start + (i << 9)
```

---

## 4. 地址转换

### 4.1 index_for() - 地址转索引

```cpp
// g1BlockOffsetTable.inline.hpp:84-97

// 原始版本（无检查）
inline size_t G1BlockOffsetTable::index_for_raw(const void* p) const {
  return pointer_delta((char*)p, _reserved.start(), sizeof(char)) >> BOTConstants::LogN;
  // (p - heap_start) >> 9
  // 即 (p - heap_start) / 512
}

// 带检查版本
inline size_t G1BlockOffsetTable::index_for(const void* p) const {
  assert(pc >= (char*)_reserved.start() && pc < (char*)_reserved.end(), ...);
  size_t result = index_for_raw(p);
  check_index(result, "bad index from address");
  return result;
}
```

### 4.2 address_for_index() - 索引转地址

```cpp
// g1BlockOffsetTable.hpp:104-106

inline HeapWord* address_for_index_raw(size_t index) const {
  return _reserved.start() + (index << BOTConstants::LogN_words);
  // heap_start + (index << 6)
  // 即 heap_start + index * 64 个字 = heap_start + index * 512B
}
```

---

## 5. 对象起始地址查找

### 5.1 block_start() 核心算法

```cpp
// g1BlockOffsetTable.inline.hpp:34-41

inline HeapWord* G1BlockOffsetTablePart::block_start(const void* addr) {
  if (addr >= _space->bottom() && addr < _space->end()) {
    // Step 1: 找到 addr 之前的某个对象起始（可能就是包含 addr 的对象）
    HeapWord* q = block_at_or_preceding(addr, true, _next_offset_index-1);
    
    // Step 2: 从 q 向前扫描，找到真正包含 addr 的对象
    return forward_to_block_containing_addr(q, addr);
  } else {
    return NULL;
  }
}
```

### 5.2 block_at_or_preceding() - 对数跳跃

```cpp
// g1BlockOffsetTable.inline.hpp:113-139

inline HeapWord* G1BlockOffsetTablePart::block_at_or_preceding(
    const void* addr, bool has_max_index, size_t max_index) const {
  
  size_t index = _bot->index_for(addr);
  if (has_max_index) {
    index = MIN2(index, max_index);
  }
  HeapWord* q = _bot->address_for_index(index);
  
  // 读取偏移值
  uint offset = _bot->offset_array(index);
  
  // 对数跳跃：offset >= 64 表示需要回退
  while (offset >= BOTConstants::N_words) {  // >= 64
    // offset 编码了跳跃距离
    size_t n_cards_back = BOTConstants::entry_to_cards_back(offset);
    q -= (BOTConstants::N_words * n_cards_back);
    index -= n_cards_back;
    offset = _bot->offset_array(index);
  }
  
  // offset < 64: 直接偏移
  q -= offset;
  return q;
}
```

### 5.3 查找流程示例

```
┌─────────────────────────────────────────────────────────────────────┐
│                    BOT 查找示例                                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  假设要查找地址 0x1234 对应的对象起始:                              │
│                                                                      │
│  Step 1: 计算索引                                                   │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ index = (0x1234 - heap_start) / 512 = 假设是索引 17          │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  Step 2: 读取 BOT[17] = 假设是 66 (> 64)                           │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ offset = 66 >= 64，需要对数跳跃                              │   │
│  │ n_cards_back = entry_to_cards_back(66) = 16^(66-64) = 16^2 = 1│   │
│  │ (实际算法更复杂，这里简化)                                   │   │
│  │ 新索引 = 17 - 1 = 16                                         │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  Step 3: 读取 BOT[16] = 假设是 32 (< 64)                           │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ offset = 32 < 64，直接偏移                                   │   │
│  │ 对象起始 = address_for_index(16) - 32 个字                   │   │
│  │          = (heap_start + 16*512) - 32*8                       │   │
│  │          = heap_start + 8192 - 256                            │   │
│  │          = heap_start + 7936                                  │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  Step 4: 向前扫描确认                                               │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ 从 heap_start + 7936 开始，逐个对象前进                      │   │
│  │ 直到找到包含 0x1234 的对象                                   │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 6. 对数编码（大对象优化）

### 6.1 问题：大对象跨越多张卡

```
问题场景:
一个 1MB 的大对象跨越 2048 张卡（1MB / 512B = 2048）

如果每张卡都存储"回退到对象起始的距离":
- 卡 0: offset = 0
- 卡 1: offset = 64 (512B / 8B)
- 卡 2: offset = 128
- ...
- 卡 2047: offset = 131008  ← 需要 17 位，1 字节存不下！

解决方案: 对数编码
- offset < 64: 直接偏移（字数）
- offset >= 64: 对数跳跃（跳过多张卡）
```

### 6.2 对数编码方案

```
┌─────────────────────────────────────────────────────────────────────┐
│                    对数编码示意                                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  大对象 (跨多张卡):                                                 │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  卡0  │  卡1  │  卡2  │  ...  │  卡7  │  卡8-71  │  卡72+  │   │
│  │ 对象  │       │       │       │       │          │         │   │
│  │ 起始  │       │       │       │       │          │         │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  BOT 编码:                                                          │
│  ┌──────┬──────┬──────┬──────┬──────┬──────────────┬───────────┐   │
│  │  0   │  0   │  0   │  0   │  0   │      65      │    66     │   │
│  │      │      │      │      │      │  (跳 16 张)  │ (跳 256)  │   │
│  └──────┴──────┴──────┴──────┴──────┴──────────────┴───────────┘   │
│    ↑                   ↑              ↑                             │
│  卡 0                卡 7           卡 8-71                          │
│  (对象起始)        (直接偏移 0)    (对数跳跃)                       │
│                                                                      │
│  编码规则:                                                          │
│  - offset 0~63: 直接偏移，回退 offset 个字                          │
│  - offset 64+:  对数跳跃，跳回 16^(offset-64) 张卡                  │
│                                                                      │
│  示例: offset = 66                                                  │
│  - 回退 16^(66-64) = 16^2 = 256 张卡                                │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 7. G1BlockOffsetTablePart

### 7.1 每个 Region 一个 Part

```cpp
// g1BlockOffsetTable.hpp:109-230

class G1BlockOffsetTablePart {
private:
  // 下一个需要更新 BOT 的边界
  HeapWord* _next_offset_threshold;
  size_t    _next_offset_index;
  
  // 全局 BOT 引用
  G1BlockOffsetTable* _bot;
  
  // 所属的 Region
  G1ContiguousSpace* _space;

public:
  // 查找对象起始
  inline HeapWord* block_start(const void* addr);
  
  // 分配对象时更新 BOT
  void alloc_block(HeapWord* blk_start, HeapWord* blk_end) {
    if (blk_end > _next_offset_threshold) {
      alloc_block_work(&_next_offset_threshold, &_next_offset_index, 
                       blk_start, blk_end);
    }
  }
};
```

### 7.2 分配时更新 BOT

```
┌─────────────────────────────────────────────────────────────────────┐
│                    对象分配时更新 BOT                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  分配前:                                                            │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  已用空间                    │   空闲空间                    │   │
│  │                              ↑                               │   │
│  │                         top (也是 _next_offset_threshold)    │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  分配对象后:                                                        │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  已用空间        │ 新对象 │   空闲空间                       │   │
│  │                  ↑       ↑                                   │   │
│  │              blk_start  blk_end (新 top)                     │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  更新 BOT:                                                          │
│  - 如果 blk_end > _next_offset_threshold                           │
│  - 需要更新跨越的卡对应的 BOT 条目                                 │
│  - 新条目指向 blk_start                                             │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 8. 内存开销

### 8.1 8GB 堆配置

| 组件 | 计算 | 大小 |
|------|------|------|
| BOT 数组 | 8GB / 512B | 16MB |
| G1BlockOffsetTable 对象 | 固定 | ~32B |
| G1BlockOffsetTablePart | 每 Region | ~48B × 2048 = 96KB |
| **总计** | | **~16.1MB** |

### 8.2 与其他映射器的关系

```
bot_storage (16MB) 是 6 个映射器之一:
┌─────────────────────────────────────────────────────────────────────┐
│  heap_storage     │ 8GB    │ Java 堆                               │
│  bot_storage      │ 16MB   │ 块偏移表 ← 就是这个                    │
│  cardtable_storage│ 16MB   │ 卡表                                   │
│  card_counts      │ 16MB   │ 热卡计数                               │
│  prev_bitmap      │ 128MB  │ 上轮标记位图                           │
│  next_bitmap      │ 128MB  │ 本轮标记位图                           │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 9. 设计亮点

### 9.1 空间效率

```
映射比例: 512B → 1B
空间开销: 堆大小的 1/512 ≈ 0.2%

8GB 堆只需要 16MB BOT
```

### 9.2 时间效率

```
小对象 (< 512B):
- 1 次 BOT 查找 + O(1) 向前扫描
- 总体 O(1)

大对象 (跨多张卡):
- 对数跳跃，最多 14 次
- 总体 O(log n)
```

### 9.3 与卡表配合

```
BOT 和 CardTable 有相同的粒度 (512B):
- CardTable: 标记哪些区域有修改
- BOT: 快速定位区域内的对象起始

两者配合实现高效的 RSet 扫描
```

---

## 10. 总结

### 10.1 G1BlockOffsetTable 核心职责

| 职责 | 说明 |
|------|------|
| **对象定位** | 给定任意地址，快速找到包含它的对象起始 |
| **RSet 扫描** | 扫描脏卡时需要找到卡内第一个对象 |
| **对数编码** | 支持大对象，保持 1 字节条目 |

### 10.2 关键数值

| 数值 | 含义 |
|------|------|
| 512B | 每个 BOT 条目覆盖的堆大小 |
| 64 | 直接偏移的最大值（N_words） |
| 16 | 对数跳跃的底数（Base） |
| 14 | 最大跳跃次数（N_powers） |
| 16MB | 8GB 堆的 BOT 大小 |

### 10.3 查找复杂度

```
block_start(addr):
  - 小对象: O(1)
  - 大对象: O(log n)，最多 14 次跳跃

空间开销: O(堆大小 / 512)
```
