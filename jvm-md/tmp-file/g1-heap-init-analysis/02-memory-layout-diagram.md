# G1堆内存布局图解

## 🏗️ 虚拟内存预留阶段

```
┌─────────────────────────────────────────────────────────────────┐
│                    进程虚拟地址空间                                │
├─────────────────────────────────────────────────────────────────┤
│  其他内存区域  │         G1堆预留区域（8GB）          │  其他内存区域  │
│               │  ┌─────────────────────────────────┐  │               │
│               │  │     mmap(PROT_NONE)            │  │               │
│               │  │     只预留地址空间              │  │               │
│               │  │     不分配物理内存              │  │               │
│               │  └─────────────────────────────────┘  │               │
└─────────────────────────────────────────────────────────────────┘
```

## 📊 G1堆数据结构布局

```
G1CollectedHeap (8GB)
├── 主堆区域 (heap_storage)
│   ├── Region 0 (4MB) ─── Eden
│   ├── Region 1 (4MB) ─── Eden  
│   ├── Region 2 (4MB) ─── Survivor
│   ├── Region 3 (4MB) ─── Old
│   ├── ...
│   └── Region 2047 (4MB) ─── Old/Humongous
│
├── 辅助数据结构
│   ├── BOT (Block Offset Table) ─── 16MB
│   │   └── 每512字节堆 → 1字节BOT
│   ├── Card Table ─── 16MB  
│   │   └── 每512字节堆 → 1字节Card
│   ├── Card Counts ─── 16MB
│   │   └── 热卡计数器
│   ├── Prev Bitmap ─── 128MB
│   │   └── 并发标记位图（上轮）
│   └── Next Bitmap ─── 128MB
│       └── 并发标记位图（当前）
│
└── 管理对象
    ├── HeapRegionManager (_hrm)
    ├── G1RemSet (_g1_rem_set)
    ├── G1ConcurrentMark (_cm)
    └── G1BlockOffsetTable (_bot)
```

## 🔄 内存映射器关系图

```
ReservedSpace (8GB预留空间)
    │
    ├── heap_storage ────────────► 实际堆Region存储
    │   └── G1RegionToSpaceMapper
    │
    ├── bot_storage ─────────────► BOT数据存储  
    │   └── G1RegionToSpaceMapper
    │
    ├── cardtable_storage ───────► 卡表数据存储
    │   └── G1RegionToSpaceMapper  
    │
    ├── card_counts_storage ─────► 热卡计数存储
    │   └── G1RegionToSpaceMapper
    │
    ├── prev_bitmap_storage ─────► 上轮标记位图
    │   └── G1RegionToSpaceMapper
    │
    └── next_bitmap_storage ─────► 当前标记位图
        └── G1RegionToSpaceMapper
```