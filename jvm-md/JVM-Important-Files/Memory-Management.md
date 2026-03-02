# 内存管理 (Memory Management) 重要文件

> **源码路径**：`src/hotspot/share/memory/`  
> **重要程度**：⭐⭐⭐⭐⭐

---

## 堆内存管理

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `heap.cpp` | ⭐⭐⭐⭐⭐ | 堆内存管理核心实现 |
| `heap.hpp` | ⭐⭐⭐⭐⭐ | 堆接口定义 |
| `heap.inline.hpp` | ⭐⭐⭐⭐⭐ | 堆内联函数 |
| `universe.cpp` | ⭐⭐⭐⭐⭐ | 堆内存空间初始化和验证 |
| `universe.hpp` | ⭐⭐⭐⭐⭐ | Universe 接口 |
| `universe.inline.hpp` | ⭐⭐⭐⭐⭐ | Universe 内联 |

---

## Metaspace

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `metaspace.cpp` | ⭐⭐⭐⭐⭐ | 元空间 (Metaspace) 管理 |
| `metaspace.hpp` | ⭐⭐⭐⭐⭐ | Metaspace 接口 |
| `metaspace.cpp` | ⭐⭐⭐⭐⭐ | Metaspace 实现 |
| `metaspace.hpp` | ⭐⭐⭐⭐⭐ | Metaspace 接口 |
| `metaspaceAllocation.cpp` | ⭐⭐⭐⭐ | Metaspace 分配 |
| `metaspaceAllocation.hpp` | ⭐⭐⭐⭐ | Metaspace 分配接口 |
| `metaspaceShared.cpp` | ⭐⭐⭐⭐ | 类的共享数据区管理 |
| `metaspaceShared.hpp` | ⭐⭐⭐⭐ | 共享 Metaspace 接口 |
| `virtualSpaceList.cpp` | ⭐⭐⭐⭐ | 虚拟内存空间列表 |
| `virtualSpaceList.hpp` | ⭐⭐⭐⭐ | VSL 接口 |
| `chunkManager.cpp` | ⭐⭐⭐⭐ | 内存块管理器 |
| `chunkManager.hpp` | ⭐⭐⭐⭐ | ChunkManager 接口 |
| `spaceManager.cpp` | ⭐⭐⭐⭐ | 空间管理器 |
| `spaceManager.hpp` | ⭐⭐⭐⭐ | SpaceManager 接口 |

---

## 内存区域

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `memRegion.cpp` | ⭐⭐⭐⭐⭐ | 内存区域抽象 |
| `memRegion.hpp` | ⭐⭐⭐⭐⭐ | MemRegion 接口 |
| `memRegion.inline.hpp` | ⭐⭐⭐⭐⭐ | MemRegion 内联 |
| `virtualspace.cpp` | ⭐⭐⭐⭐⭐ | 虚拟内存空间管理 |
| `virtualspace.hpp` | ⭐⭐⭐⭐⭐ | VirtualSpace 接口 |

---

## Arena 分配器

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `arena.cpp` | ⭐⭐⭐⭐⭐ | 内存分配器 Arena 实现 |
| `arena.hpp` | ⭐⭐⭐⭐⭐ | Arena 接口 |
| `arena.inline.hpp` | ⭐⭐⭐⭐⭐ | Arena 内联 |
| `arenaChunk.cpp` | ⭐⭐⭐⭐ | Arena 块 |
| `arenaChunk.hpp` | ⭐⭐⭐⭐ | ArenaChunk 接口 |

---

## 堆检查与统计

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `heapInspection.cpp` | ⭐⭐⭐⭐ | 堆内存检查和统计 |
| `heapInspection.hpp` | ⭐⭐⭐⭐ | 堆检查接口 |
| `heapShared.cpp` | ⭐⭐⭐⭐ | 堆共享数据管理 |
| `heapShared.hpp` | ⭐⭐⭐⭐ | HeapShared 接口 |

---

## 文件映射

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `filemap.cpp` | ⭐⭐⭐⭐⭐ | CDS 文件映射管理 |
| `filemap.hpp` | ⭐⭐⭐⭐⭐ | FileMap 接口 |
| `filemapInfo.cpp` | ⭐⭐⭐⭐ | 文件映射信息 |

---

## 通用分配

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `allocation.cpp` | ⭐⭐⭐⭐⭐ | 通用内存分配接口 |
| `allocation.hpp` | ⭐⭐⭐⭐⭐ | 分配接口定义 |
| `allocation.inline.hpp` | ⭐⭐⭐⭐⭐ | 分配内联 |
| `memAllocator.cpp` | ⭐⭐⭐⭐⭐ | 内存分配器 |
| `memAllocator.hpp` | ⭐⭐⭐⭐⭐ | 分配器接口 |

---

## 指针压缩

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `compressedOops.cpp` | ⭐⭐⭐⭐⭐ | 压缩 oop 处理 |
| `compressedOops.hpp` | ⭐⭐⭐⭐⭐ | 压缩 oop 接口 |
| `compressedKlass.cpp` | ⭐⭐⭐⭐⭐ | 压缩类指针处理 |

---

## 核心调用链

```
JVM 启动时堆初始化：
Universe::initialize()
  → Universe::create_heap()
    → G1CollectedHeap::initialize()
      → HeapRegionManager::initialize()
        → G1RegionToSpaceMapper::initialize()

Metaspace 分配：
Metaspace::allocate()
  → ChunkManager::allocate()
    → VirtualSpaceList::allocate()
      →arena()->Amalloc()
```

---

## 内存布局（8GB 堆）

```
┌────────────────────────────────────────────────────────┐
│                      Java Heap (8GB)                  │
├────────────────────────────────────────────────────────┤
│                                                        │
│  G1 Eden (约 1-2GB)                                  │
│  ──────────────────                                   │
│  G1 Survivor (约 100-500MB)                          │
│  ──────────────────                                   │
│  G1 Old (约 5-7GB)                                   │
│                                                        │
├────────────────────────────────────────────────────────┤
│  Card Table (16MB)                                    │
├────────────────────────────────────────────────────────┤
│  Bitmap (256MB) Prev+Next                             │
├────────────────────────────────────────────────────────┤
│  Metaspace (动态)                                     │
├────────────────────────────────────────────────────────┤
│  Code Cache (动态，240MB)                             │
└────────────────────────────────────────────────────────┘
```

---

## 学习建议

1. **优先级 P0**：heap.cpp, universe.cpp, metaspace.cpp, allocation.cpp
2. **优先级 P1**：memRegion.cpp, virtualspace.cpp, arena.cpp, filemap.cpp
3. **优先级 P2**：compressedOops.cpp, chunkManager.cpp, spaceManager.cpp
