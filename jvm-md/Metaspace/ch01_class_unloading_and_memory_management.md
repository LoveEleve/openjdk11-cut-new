# Metaspace 深入分析：类卸载完整链路与内存管理

> 基于 OpenJDK 11，标准环境：`-Xms8g -Xmx8g -XX:+UseG1GC`，Region=4MB
> 前置知识：`Metaspace/metaspace_deep_dive.md`（架构+数据结构+分配流程+初始化）
> 源码：`src/hotspot/share/memory/metaspace.cpp` + `classfile/classLoaderData.cpp`

---

## 本文解决的核心问题

前一篇 `metaspace_deep_dive.md` 已覆盖了 Metaspace 的架构、数据结构、分配流程和初始化。但以下**运行时关键问题**还没深入：

1. **类卸载时 Metaspace 到底发生了什么？**（从 GC 判定"死亡"到内存归还操作系统的完整链路）
2. **Metaspace OOM 时 JVM 做了什么？**（分配失败→GC→retry→OOM 的完整逻辑）
3. **碎片化是如何产生的？JVM 如何应对？**（合并/拆分的实际效果和局限）
4. **MetaspaceGC 的 HWM 到底怎么调整？**（扩展/收缩的精确公式与阻尼策略）
5. **生产环境怎么监控和诊断 Metaspace 问题？**（jcmd / JMX / 日志参数）

---

## 1. 类卸载完整链路

### 1.1 设计哲学：为什么 Metaspace 比 PermGen 高效？

**PermGen 的痛点**：类卸载需要 Full GC 扫描整个永久代，逐个对象判断是否可回收，效率极低。

**Metaspace 的解决方案**：**以 ClassLoader 为粒度整批释放**。每个 ClassLoader 拥有独立的 `ClassLoaderMetaspace`，包含自己的所有 Chunk。当 ClassLoader 被 GC 回收时，其所有 Chunk 整批归还 `ChunkManager` 空闲池，不需要遍历里面的每个元数据对象。

**核心前提**：一个类的生命周期 ≤ 加载它的 ClassLoader 的生命周期。ClassLoader 死了，它加载的所有类必然也死了。

### 1.2 类卸载触发时机（G1 GC 视角）

类卸载在 G1 中有两个触发路径：

```
路径1: 并发标记 Remark 阶段（正常路径，增量回收）
  G1ConcurrentMark::checkpointRootsFinalWork()         // Remark STW
    ├── WeakProcessor::weak_oops_do()                   // 弱引用处理
    └── if (ClassUnloadingWithConcurrentMark) {         // 默认 true
          SystemDictionary::do_unloading()              // 类卸载入口
            └── ClassLoaderDataGraph::do_unloading()    // 核心：遍历 CLDG
        }
  
  G1ConcurrentMark::cleanupForNextMark()               // Cleanup 阶段
    └── if (ClassUnloadingWithConcurrentMark) {
          ClassLoaderDataGraph::purge()                 // 核心：析构死亡 CLD
          // ↑ 这里才真正释放 Metaspace 内存
        }

路径2: Full GC（最后手段）
  G1CollectedHeap::do_full_collection_inner()
    ├── ClassLoaderDataGraph::do_unloading()
    └── ClassLoaderDataGraph::purge()
```

**关键参数**：
- `ClassUnloading`（默认 true）：是否允许类卸载
- `ClassUnloadingWithConcurrentMark`（默认 true）：是否在并发标记中卸载类（否则只在 Full GC 中卸载）

### 1.3 第一阶段：判活与标记（do_unloading）

```cpp
// classLoaderData.cpp:1439
bool ClassLoaderDataGraph::do_unloading(bool clean_previous_versions) {
  ClassLoaderData* data = _head;
  ClassLoaderData* prev = NULL;
  bool seen_dead_loader = false;

  // 遍历 ClassLoaderDataGraph 链表
  while (data != NULL) {
    if (data->is_alive()) {
      // 存活的 CLD：清理 deallocate_list 中的垃圾元数据
      data->free_deallocate_list();
      prev = data;
      data = data->next();
      continue;
    }
    
    // 发现死亡 CLD
    seen_dead_loader = true;
    ClassLoaderData* dead = data;
    dead->unload();           // 标记为卸载中，通知 serviceability 工具
    data = data->next();
    
    // 从 CLDG 链表中摘除，移到 _unloading 链表
    if (prev != NULL) prev->set_next(data);
    else _head = data;
    dead->set_next(_unloading);
    _unloading = dead;
  }
  
  // 清理存活 CLD 中引用已卸载模块/包的导出列表
  if (seen_dead_loader) {
    // purge_all_package_exports / purge_all_module_reads / clean_cached_protection_domains
  }
  return seen_dead_loader;
}
```

**判活逻辑**（`ClassLoaderData::is_alive()`）：

```cpp
bool ClassLoaderData::is_alive() const {
  bool alive = keep_alive()            // BootClassLoader 和未完成的匿名类永远存活
      || (_holder.peek() != NULL);     // WeakHandle 没有被 GC 清除 → ClassLoader 还活着
  return alive;
}
```

- `_holder` 是一个 `WeakOopHandle`，指向 ClassLoader 对象（`java.lang.ClassLoader` 实例）
- 如果 ClassLoader 对象没有被任何强引用可达，GC 在弱引用处理阶段会清除 `_holder`
- 此时 `_holder.peek() == NULL`，`is_alive()` 返回 false

**`unload()` 方法做了什么**：

```cpp
void ClassLoaderData::unload() {
  _unloading = true;                        // 标记卸载状态
  unload_deallocate_list();                 // 释放待回收元数据的 C 堆内存
  classes_do(InstanceKlass::notify_unload_class);  // 通知 JVMTI 等工具
}
```

注意：`unload()` **并不释放 Metaspace 内存**。它只做标记和通知。真正的内存释放在 `purge()` 阶段。

### 1.4 第二阶段：析构与释放（purge）

```cpp
// classLoaderData.cpp:1523
void ClassLoaderDataGraph::purge() {
  assert(SafepointSynchronize::is_at_safepoint(), "must be at safepoint!");
  ClassLoaderData* list = _unloading;
  _unloading = NULL;
  ClassLoaderData* next = list;
  bool classes_unloaded = false;
  
  while (next != NULL) {
    ClassLoaderData* purge_me = next;
    next = purge_me->next();
    delete purge_me;              // ← 触发 ~ClassLoaderData()
    classes_unloaded = true;
  }
  
  if (classes_unloaded) {
    Metaspace::purge();           // ← 全局 VSN 清理
    set_metaspace_oom(false);     // 重置 OOM 标志（之前 OOM 可能是因为未卸载的类占用）
  }
}
```

**`delete purge_me` 触发析构链**：

```
~ClassLoaderData()
  ├── ReleaseKlassClosure::do_klass()     // 释放每个类的 C 堆结构
  │     └── InstanceKlass::release_C_heap_structures()  // 释放 C++ 堆上的辅助数据
  ├── _holder.release()                    // 释放 WeakHandle
  ├── delete _packages                     // 释放包表
  ├── delete _modules                      // 释放模块表
  ├── delete _dictionary                   // 释放字典
  ├── delete _metaspace (ClassLoaderMetaspace)  // ← 关键！释放元空间
  │     └── ~ClassLoaderMetaspace()
  │           ├── delete _vsm (SpaceManager)    // 数据 SpaceManager
  │           │     └── ~SpaceManager()         // ← 核心释放逻辑
  │           └── delete _class_vsm (SpaceManager) // 类 SpaceManager
  │                 └── ~SpaceManager()
  ├── Method::clear_jmethod_ids()          // 清除 JNI 方法 ID
  ├── delete _metaspace_lock               // 释放锁
  ├── delete _deallocate_list              // 释放待回收列表
  └── _name->decrement_refcount()          // 减少 Symbol 引用计数
```

### 1.5 第三阶段：Chunk 归还（SpaceManager 析构）

这是 Metaspace 内存释放的**核心**：

```cpp
// spaceManager.cpp:281
SpaceManager::~SpaceManager() {
  // 1. 获取全局扩展锁
  MutexLockerEx fcl(MetaspaceExpand_lock, Mutex::_no_safepoint_check_flag);
  
  // 2. 更新全局计数器（减去本 SpaceManager 的 capacity/overhead/used）
  account_for_spacemanager_death();
  
  // 3. 核心：将所有使用中的 Chunk 整批归还 ChunkManager 空闲池
  chunk_manager()->return_chunk_list(chunk_list());
  
  // 4. 释放 BlockFreelist
  if (_block_freelists != NULL) {
    delete _block_freelists;
  }
}
```

**`return_chunk_list()` 做了什么**：

```cpp
// chunkManager.cpp
void ChunkManager::return_chunk_list(Metachunk* chunks) {
  Metachunk* cur = chunks;
  while (cur != NULL) {
    Metachunk* next = cur->next();
    return_single_chunk(cur);    // 逐个归还
    cur = next;
  }
}

void ChunkManager::return_single_chunk(Metachunk* chunk) {
  // 1. mangle（debug 模式下填充垃圾值）
  DEBUG_ONLY(chunk->mangle(badMetaWordVal));
  
  // 2. 根据大小归还到对应空闲链表或红黑树
  if (index != HumongousIndex) {
    free_chunks(index)->return_chunk_at_head(chunk);  // Specialized/Small/Medium → 链表
  } else {
    _humongous_dictionary.return_chunk(chunk);         // Humongous → 红黑树
  }
  
  // 3. 更新 VirtualSpaceNode 的 container_count
  chunk->container()->dec_container_count();
  
  // 4. 更新 OccupancyMap 中的 in-use 标记
  do_update_in_use_info_for_chunk(chunk, false);
  
  // 5. 更新空闲计数
  account_for_added_chunk(chunk);
  
  // 6. 尝试合并：小 Chunk 合并为大 Chunk
  if (index == SmallIndex || index == SpecializedIndex) {
    if (!attempt_to_coalesce_around_chunk(chunk, MediumIndex)) {
      if (index == SpecializedIndex) {
        attempt_to_coalesce_around_chunk(chunk, SmallIndex);
      }
    }
  }
}
```

### 1.6 第四阶段：VSN 清理（Metaspace::purge）

当所有 ClassLoader 的 Chunk 都归还后，某些 VirtualSpaceNode 可能完全空闲（`container_count == 0`），此时可以释放回操作系统。

```cpp
// metaspace.cpp:1622
void Metaspace::purge() {
  MutexLockerEx cl(MetaspaceExpand_lock, Mutex::_no_safepoint_check_flag);
  purge(NonClassType);           // 数据 VSL purge
  if (using_class_space()) {
    purge(ClassType);            // 类 VSL purge
  }
}

void Metaspace::purge(MetadataType mdtype) {
  get_space_list(mdtype)->purge(get_chunk_manager(mdtype));
}
```

```cpp
// virtualSpaceList.cpp:76
void VirtualSpaceList::purge(ChunkManager* chunk_manager) {
  assert(SafepointSynchronize::is_at_safepoint(), "must be called at safepoint");
  
  VirtualSpaceNode* prev_vsl = virtual_space_list();
  VirtualSpaceNode* next_vsl = prev_vsl;
  
  while (next_vsl != NULL) {
    VirtualSpaceNode* vsl = next_vsl;
    next_vsl = vsl->next();
    
    // 条件：container_count == 0 且不是当前活跃 VSN
    if (vsl->container_count() == 0 && vsl != current_virtual_space()) {
      // 1. 从链表中摘除
      if (prev_vsl == vsl) {
        set_virtual_space_list(vsl->next());
      } else {
        prev_vsl->set_next(vsl->next());
      }
      
      // 2. VSN purge：从 ChunkManager 中移除该 VSN 上的所有空闲 Chunk
      vsl->purge(chunk_manager);
      
      // 3. 更新计数器
      dec_reserved_words(vsl->reserved_words());
      dec_committed_words(vsl->committed_words());
      dec_virtual_space_count();
      
      // 4. 释放 VSN（释放 ReservedSpace → munmap）
      delete vsl;
      // ~VirtualSpaceNode() 中调用 _rs.release() → os::release_memory()
    } else {
      prev_vsl = vsl;
    }
  }
}
```

**VSN::purge 做了什么**：

```cpp
// virtualSpaceNode.cpp:83
void VirtualSpaceNode::purge(ChunkManager* chunk_manager) {
  Metachunk* chunk = first_chunk();
  Metachunk* invalid_chunk = (Metachunk*) top();
  while (chunk < invalid_chunk) {
    assert(chunk->is_tagged_free(), "Should be tagged free");
    MetaWord* next = ((MetaWord*)chunk) + chunk->word_size();
    chunk_manager->remove_chunk(chunk);  // 从空闲链表中移除
    chunk->remove_sentinel();
    chunk = (Metachunk*) next;
  }
}
```

### 1.7 完整时序图

```
                GC 标记阶段                    Remark STW                     Cleanup
    ──────────────────────────>│<────────────────────────────>│<─────────────────────>│
                               │                              │                       │
    GC 发现 ClassLoader X      │ do_unloading()               │  purge()              │
    不可达,清除 WeakHandle     │  ├── is_alive(X)→false       │  ├── delete CLD_X     │
    (_holder.peek()==NULL)     │  ├── X.unload() 标记         │  │    ├── ~CLD()       │
                               │  ├── 摘除→_unloading 链表    │  │    │  ├── delete     │
                               │  └── 清理存活CLD的导出列表   │  │    │  │  ClassLoader │
                               │                              │  │    │  │  Metaspace   │
                               │                              │  │    │  │  ├──delete    │
                               │                              │  │    │  │  │  _vsm      │
                               │                              │  │    │  │  │  └──return  │
                               │                              │  │    │  │  │     _chunk  │
                               │                              │  │    │  │  │     _list   │
                               │                              │  │    │  │  └──delete     │
                               │                              │  │    │  │     _class_vsm │
                               │                              │  │    │  └── ...          │
                               │                              │  ├── Metaspace::purge()   │
                               │                              │  │    ├── VSL::purge()    │
                               │                              │  │    │  if container_    │
                               │                              │  │    │  count==0:        │
                               │                              │  │    │  delete VSN       │
                               │                              │  │    │  →munmap 归还OS   │
                               │                              │  └── set_metaspace_oom    │
                               │                              │       (false)             │
```

---

## 2. Metaspace OOM 完整处理链路

### 2.1 问题：分配失败怎么办？

当 `Metaspace::allocate()` 返回 NULL 时，JVM 不会立即抛出 OOM。它会进行**多轮 GC + 重试**。

### 2.2 分配入口（6 层 → GC → OOM）

```cpp
// metaspace.cpp:1510
MetaWord* Metaspace::allocate(ClassLoaderData* loader_data, size_t word_size,
                              MetaspaceObj::Type type, TRAPS) {
  MetadataType mdtype = (type == MetaspaceObj::ClassType) ? ClassType : NonClassType;
  
  // 第1次尝试：正常分配（6层：SpaceManager→ChunkManager→VirtualSpaceList）
  MetaWord* result = loader_data->metaspace_non_null()->allocate(word_size, mdtype);
  
  if (result == NULL) {
    // 分配失败，触发 GC+重试
    if (is_init_completed()) {
      result = Universe::heap()->satisfy_failed_metadata_allocation(
                 loader_data, word_size, mdtype);
    }
  }
  
  if (result == NULL) {
    // GC+重试也失败，报告 OOM
    report_metadata_oome(loader_data, word_size, type, mdtype, THREAD);
    return NULL;
  }
  
  // 零初始化
  Copy::fill_to_words((HeapWord*)result, word_size, 0);
  return result;
}
```

### 2.3 satisfy_failed_metadata_allocation（GC+重试循环）

```cpp
// collectedHeap.cpp:259
MetaWord* CollectedHeap::satisfy_failed_metadata_allocation(
    ClassLoaderData* loader_data, size_t word_size, Metaspace::MetadataType mdtype) {
  
  do {
    // 重试1：直接再试一次（其他线程可能释放了内存）
    MetaWord* result = loader_data->metaspace_non_null()->allocate(word_size, mdtype);
    if (result != NULL) return result;
    
    // 处理 GCLocker（JNI 临界区）
    if (GCLocker::is_active_and_needs_gc()) {
      // 尝试 expand_and_allocate（不经过 GC，直接扩展）
      result = loader_data->metaspace_non_null()->expand_and_allocate(word_size, mdtype);
      if (result != NULL) return result;
      // 如果当前线程不在临界区，等待 GCLocker 释放
      GCLocker::stall_until_clear();
      continue;
    }
    
    // 触发 VM_CollectForMetadataAllocation 操作
    // 这会：
    //   1. 先尝试 Young GC（可能卸载匿名类）
    //   2. 如果不够，触发并发标记（标记死亡类，最终 purge 释放 Metaspace）
    //   3. 如果还不够，触发 Full GC（强制全量类卸载）
    //   4. GC 完成后再尝试分配
    VM_CollectForMetadataAllocation op(loader_data, word_size, mdtype,
                                       gc_count, full_gc_count,
                                       GCCause::_metadata_GC_threshold);
    VMThread::execute(&op);
    
    if (op.prologue_succeeded()) {
      return op.result();       // GC 后分配成功
    }
    
    loop_count++;
    // 循环继续，直到成功或最终失败
  } while (true);
}
```

### 2.4 report_metadata_oome（最终 OOM）

```cpp
// metaspace.cpp:1556
void Metaspace::report_metadata_oome(ClassLoaderData* loader_data, size_t word_size,
                                      MetaspaceObj::Type type, MetadataType mdtype, TRAPS) {
  // 1. 打印 OOM 日志
  Log(gc, metaspace, freelist, oom) log;
  log.info("Metaspace (%s) allocation failed for size %zu",
           is_class_space_allocation(mdtype) ? "class" : "data", word_size);
  MetaspaceUtils::print_basic_report(&ls, 0);  // 输出当前 Metaspace 使用情况
  
  // 2. 判断是 Compressed Class Space OOM 还是 Metaspace OOM
  bool out_of_compressed_class_space = false;
  if (is_class_space_allocation(mdtype)) {
    out_of_compressed_class_space =
      MetaspaceUtils::committed_bytes(ClassType) +
      (metaspace->class_chunk_size(word_size) * BytesPerWord) > CompressedClassSpaceSize;
  }
  
  // 3. 触发 HeapDumpOnOutOfMemoryError
  report_java_out_of_memory(out_of_compressed_class_space ?
    "Compressed class space" : "Metaspace");
  
  // 4. 通知 JVMTI
  if (JvmtiExport::should_post_resource_exhausted()) {
    JvmtiExport::post_resource_exhausted(JVMTI_RESOURCE_EXHAUSTED_OOM_ERROR, space_string);
  }
  
  // 5. 抛出 OutOfMemoryError
  if (out_of_compressed_class_space) {
    THROW_OOP(Universe::out_of_memory_error_class_metaspace());
    // → java.lang.OutOfMemoryError: Compressed class space
  } else {
    THROW_OOP(Universe::out_of_memory_error_metaspace());
    // → java.lang.OutOfMemoryError: Metaspace
  }
}
```

**两种 OOM 消息的含义**：

| OOM 消息 | 含义 | 常见原因 |
|---------|------|---------|
| `OutOfMemoryError: Metaspace` | NonClass 数据空间不足 | 加载了太多类/方法/字节码 |
| `OutOfMemoryError: Compressed class space` | 1GB 类空间用尽 | Klass 结构太多（Lambda/CGLIB/动态代理） |

---

## 3. Chunk 合并与拆分：碎片化的战争

### 3.1 碎片化是如何产生的？

考虑以下场景：

```
VSN 内存布局（初始）：
[  ClassLoader A 的 Medium Chunk (64KB)  ][  ClassLoader B 的 Medium Chunk (64KB)  ]

ClassLoader A 被卸载后：
[   FREE Medium Chunk (64KB)   ][  ClassLoader B 的 Medium Chunk (64KB, 在用)  ]

ClassLoader C 请求 Small Chunk (4KB)：
[ C's Small(4KB) ][ FREE? ][  B's Medium(64KB, 在用)  ]
```

**碎片化的本质**：不同 ClassLoader 的 Chunk 交错分布在 VSN 中。当某些 ClassLoader 被卸载后，空闲 Chunk 散落在使用中 Chunk 之间，无法合并为大 Chunk。

### 3.2 合并策略（归还时自动触发）

```cpp
// chunkManager.cpp:126
bool ChunkManager::attempt_to_coalesce_around_chunk(Metachunk* chunk, 
                                                     ChunkIndex target_chunk_type) {
  const size_t target_chunk_word_size = 
    get_size_for_nonhumongous_chunktype(target_chunk_type, is_class());
  
  // 1. 计算对齐的合并区域
  //    例：目标 Medium(64KB)，chunk 在 Medium 对齐边界内的位置
  MetaWord* p_merge_region_start = 
    align_down(chunk, target_chunk_word_size * sizeof(MetaWord));
  MetaWord* p_merge_region_end = 
    p_merge_region_start + target_chunk_word_size;
  
  // 2. 检查合并区域是否在 VSN 范围内
  if (p_merge_region_start < vsn->bottom() || p_merge_region_end > vsn->top()) {
    return false;
  }
  
  // 3. 检查边界：区域起始必须是 Chunk 起始，区域结束必须是 Chunk 起始
  if (!ocmap->chunk_starts_at_address(p_merge_region_start)) return false;
  if (p_merge_region_end < vsn->top() && 
      !ocmap->chunk_starts_at_address(p_merge_region_end)) return false;
  
  // 4. 关键检查：合并区域内的所有 Chunk 是否都是空闲的
  //    通过 OccupancyMap 的 in_use_map 快速判断
  if (ocmap->is_region_in_use(p_merge_region_start, target_chunk_word_size)) {
    return false;  // 有在用 Chunk，无法合并
  }
  
  // 5. 合并成功！移除旧 Chunk，创建新大 Chunk
  int num_removed = remove_chunks_in_area(p_merge_region_start, target_chunk_word_size);
  
  Metachunk* p_new_chunk = ::new (p_merge_region_start) 
    Metachunk(target_chunk_type, is_class(), target_chunk_word_size, vsn);
  p_new_chunk->set_origin(origin_merge);
  
  // 6. 更新 OccupancyMap
  ocmap->wipe_chunk_start_bits_in_region(p_merge_region_start, target_chunk_word_size);
  ocmap->set_chunk_starts_at_address(p_merge_region_start, true);
  
  // 7. 加入空闲链表
  free_chunks(target_chunk_type)->return_chunk_at_head(p_new_chunk);
  
  return true;
}
```

**合并规则**：

| 源 Chunk | 目标 Chunk | 条件 |
|---------|-----------|------|
| Specialized (1KB) | → Small (4KB) | 对齐区域内 4 个连续 1KB Chunk 全空闲 |
| Specialized (1KB) | → Medium (64KB) | 对齐区域内 64 个连续 1KB Chunk 全空闲 |
| Small (4KB) | → Medium (64KB) | 对齐区域内 16 个连续 4KB Chunk 全空闲 |

**合并触发时机**：`return_single_chunk()` → 归还后自动尝试合并，优先尝试合并为 Medium，不行则尝试 Small。

### 3.3 拆分策略（分配时按需触发）

```cpp
// chunkManager.cpp:405
Metachunk* ChunkManager::split_chunk(size_t target_chunk_word_size, Metachunk* larger_chunk) {
  // 例：请求 Small(4KB)，但只有 Medium(64KB) 空闲
  
  // 1. 移除大 Chunk
  free_chunks(larger_chunk_index)->remove_chunk(larger_chunk);
  
  // 2. 在区域起始创建目标 Chunk
  Metachunk* target_chunk = ::new (region_start) 
    Metachunk(target_chunk_index, is_class(), target_chunk_word_size, vsn);
  target_chunk->set_origin(origin_split);
  
  // 3. 剩余空间创建尽可能大的 Chunk
  // 例：64KB Medium 拆分为 4KB Small + 4KB Small + ... + 剩余尽可能大
  // 实际会创建：1个4KB目标 + 若干个尽可能大的剩余 Chunk
  p += target_chunk->word_size();
  while (p < region_end) {
    // 找最大的能对齐的 Chunk 大小
    ChunkIndex this_chunk_index = prev_chunk_index(larger_chunk_index);
    while (!is_aligned(p, this_chunk_word_size * BytesPerWord)) {
      this_chunk_index = prev_chunk_index(this_chunk_index);
    }
    // 创建剩余 Chunk 并归还空闲池
    Metachunk* this_chunk = ::new (p) Metachunk(...);
    free_chunks(this_chunk_index)->return_chunk_at_head(this_chunk);
    p += this_chunk_word_size;
  }
  
  return target_chunk;
}
```

### 3.4 碎片化的局限性

合并**只能**在**同一个 VSN 内**、**连续且对齐**的空闲 Chunk 之间进行。如果两个空闲 Chunk 被一个在用 Chunk 隔开，就无法合并：

```
[FREE Small][IN-USE Small][FREE Small]  ← 无法合并为 Medium，中间有在用 Chunk
```

**生产中常见的碎片化场景**：
1. **大量 Lambda/CGLIB 代理类**：每个 Lambda 表达式创建独立的匿名 ClassLoader（Specialized Chunk），卸载后散落为小碎片
2. **热部署/重部署**：不断加载/卸载 WebApp 类，新旧 Chunk 交替

---

## 4. MetaspaceGC HWM 调整策略

### 4.1 核心变量

```cpp
volatile size_t MetaspaceGC::_capacity_until_GC;  // 高水位线（HWM）
static uint _shrink_factor;                        // 收缩阻尼因子
```

HWM 决定了 Metaspace **何时触发 GC**：当 `committed_bytes >= _capacity_until_GC` 时，分配会失败并触发 GC。

### 4.2 GC 后调整公式

```
used_after_gc = MetaspaceUtils::committed_bytes()  // 注意是 committed 而非 used

扩展条件：
  minimum_desired_capacity = used_after_gc / (1 - MinMetaspaceFreeRatio/100)
  如果 HWM < minimum_desired_capacity:
    expand_bytes = minimum_desired_capacity - HWM
    new_HWM = HWM + expand_bytes

收缩条件（MaxMetaspaceFreeRatio < 100 时）：
  maximum_desired_capacity = used_after_gc / (1 - MaxMetaspaceFreeRatio/100)
  如果 HWM > maximum_desired_capacity:
    shrink_bytes = (HWM - maximum_desired_capacity) * shrink_factor / 100
```

### 4.3 收缩阻尼策略

```
第1次 GC 后想收缩：shrink_factor = 0%   → 不收缩
第2次 GC 后想收缩：shrink_factor = 10%  → 收缩 10%
第3次 GC 后想收缩：shrink_factor = 40%  → 收缩 40%
第4次 GC 后想收缩：shrink_factor = 100% → 全量收缩

如果中间有一次不需要收缩：shrink_factor 重置为 0
```

**为什么要阻尼**？防止 `System.gc()` 导致 HWM 过度缩小→下次分配又要扩展→频繁 GC 抖动。

### 4.4 默认参数下的行为

```
MetaspaceSize = 21807104 (~21MB)  → 初始 HWM
MinMetaspaceFreeRatio = 40        → 至少保留 40% 空闲空间
MaxMetaspaceFreeRatio = 70        → 最多保留 70% 空闲空间
MaxMetaspaceSize = ~UINT64_MAX    → 无上限（除非显式设置）

最小所需容量 = used / 0.6
最大所需容量 = used / 0.3

例：GC 后 committed = 50MB
  minimum_desired_capacity = 50MB / 0.6 = 83.3MB
  maximum_desired_capacity = 50MB / 0.3 = 166.7MB
  如果 HWM = 60MB < 83.3MB → 扩展到 83.3MB
  如果 HWM = 200MB > 166.7MB → 收缩（带阻尼）
```

---

## 5. 监控与诊断

### 5.1 JVM 日志参数

| 参数 | 内容 |
|------|------|
| `-Xlog:gc+metaspace=info` | 每次 GC 后的 Metaspace 使用摘要 |
| `-Xlog:gc+metaspace=trace` | HWM 调整详情（compute_new_size） |
| `-Xlog:gc+metaspace+freelist=trace` | Chunk 分配/释放/合并/拆分 |
| `-Xlog:gc+metaspace+freelist+oom=info` | OOM 时的详细报告 |
| `-Xlog:gc+metaspace+alloc=trace` | Humongous Chunk 分配 |
| `-Xlog:class+unload=info` | 类卸载事件 |
| `-Xlog:class+loader+data=debug` | ClassLoaderData 创建/卸载 |

**示例输出**（类卸载）：

```
[debug][class,loader,data] unload loader data 0x00007f8b1c7abed0 for instance a]
[info ][class,unload       ] unloading class com.example.DynamicProxy$$ByCGLIB$$abc123 0x0000000800c7e000
[trace][gc,metaspace,freelist] returned 12 chunks to freelist, total word size 32768.
[debug][gc,phases          ] Purge Metaspace 0.123ms
```

### 5.2 jcmd 诊断命令

```bash
# 查看 Metaspace 详细报告（按 ClassLoader 分组）
jcmd <pid> VM.metaspace show-loaders show-classes

# 查看 Metaspace 基本统计
jcmd <pid> VM.metaspace

# 查看内存分布
jcmd <pid> VM.native_memory summary
```

### 5.3 JMX 监控

```java
// 通过 MemoryPoolMXBean
ManagementFactory.getMemoryPoolMXBeans().stream()
  .filter(pool -> pool.getName().contains("Metaspace") || 
                  pool.getName().contains("Compressed Class"))
  .forEach(pool -> {
    System.out.println(pool.getName() + ": " + pool.getUsage());
  });
// 输出：
// Metaspace: init=0, used=15234KB, committed=16128KB, max=-1
// Compressed Class Space: init=0, used=1853KB, committed=2048KB, max=1048576KB
```

### 5.4 PrintMetaspaceStatisticsAtExit

JDK 11 的 Debug 版本支持 `PrintMetaspaceStatisticsAtExit`，输出包括：

- 每种 SpaceType 的使用详情（Boot/Standard/Anonymous/Reflection）
- ChunkManager 空闲池状态（各类型 Chunk 数量和总大小）
- 浪费分析（committed 未使用 / Chunk 内浪费 / 空闲 Chunk 占用 / deallocated 块）
- VirtualSpaceNode 列表和内存映射

---

## 6. 常见生产问题与解决方案

### 6.1 问题：Metaspace 持续增长不释放

**原因**：ClassLoader 泄露。ClassLoader 被某处引用（如 ThreadLocal、static 字段、JMX MBean），导致 GC 无法回收。

**诊断**：
```bash
jcmd <pid> VM.metaspace show-loaders  # 查看哪个 ClassLoader 占用最多
jcmd <pid> GC.class_histogram         # 查看哪些类数量异常
```

**解决**：修复泄露（常见：ThreadLocal 未清理、webapp 卸载时 static 未置 null）

### 6.2 问题：Compressed Class Space OOM

**原因**：压缩类空间只有 1GB（默认），且只有 1 个 VSN，不能动态扩展。

**诊断**：`-Xlog:gc+metaspace+freelist+oom=info` 查看 OOM 时报告。

**解决**：`-XX:CompressedClassSpaceSize=2g`（最大 3GB）或减少动态类生成。

### 6.3 问题：频繁 Metaspace GC

**原因**：`MetaspaceSize` 太小（默认 ~21MB），正常加载就会触发 GC。

**解决**：`-XX:MetaspaceSize=256m`（设置初始 HWM），减少启动期 GC。

### 6.4 问题：Metaspace 碎片化导致 OOM

**原因**：虽然空闲空间足够，但都是 Specialized (1KB) 碎片，无法满足大分配请求。

**诊断**：`-Xlog:gc+metaspace+freelist=trace` 查看 Chunk 分配/合并情况。

**解决**：难以根治。减少短命 ClassLoader 的数量，或增大 `MaxMetaspaceSize`。

---

## 7. 面试 Q&A

### Q1: Metaspace 和 PermGen 的本质区别是什么？

**答**：三个核心区别：

1. **内存来源**：PermGen 在 Java 堆内（受 `-XX:MaxPermSize` 限制），Metaspace 使用 native memory（mmap）
2. **回收粒度**：PermGen 需要 Full GC 逐个对象扫描，Metaspace 以 ClassLoader 为粒度整批释放
3. **弹性增长**：PermGen 固定大小不能动态扩展，Metaspace 可通过 VirtualSpaceList 动态添加 VSN

**源码证据**：`SpaceManager::~SpaceManager()` 中 `chunk_manager()->return_chunk_list(chunk_list())` —— 不遍历 Chunk 内部，直接整条链表归还空闲池。

### Q2: 类卸载的完整条件是什么？

**答**：三个条件同时满足：
1. **ClassLoader 不可达**：没有任何强引用指向 ClassLoader 对象
2. **ClassUnloading = true**：JVM 参数允许类卸载（默认 true）
3. **GC 触发判活**：GC 的弱引用处理阶段清除了 CLD 的 `_holder`（WeakOopHandle）

**特殊情况**：BootClassLoader / PlatformClassLoader / AppClassLoader 永远不会被卸载（`keep_alive() == true`）。

### Q3: 为什么 Compressed Class Space 只有 1 个 VSN？

**答**：压缩类指针（narrowKlass）要求所有 Klass 在一段连续的虚拟地址空间内（`base + offset << shift` 编码为 32 位）。如果 VSN 分散在不同地址，就无法用统一的 base+shift 解码。所以类空间永远只有 1 个 VSN（固定 1GB），在 `create_new_virtual_space()` 中直接 assert 失败：

```cpp
if (is_class()) {
  assert(false, "We currently don't support more than one VirtualSpace for"
                " the compressed class space.");
  return false;
}
```

### Q4: Metaspace OOM 时 JVM 做了几次努力？

**答**：至少 3 次：
1. **直接分配**（6 层：SpaceManager → ChunkManager → VirtualSpaceList）
2. **GC + 重试**：`satisfy_failed_metadata_allocation()` 触发 `VM_CollectForMetadataAllocation`（Young GC → 并发标记 → Full GC），GC 后再分配
3. **最终 OOM**：`report_metadata_oome()` 打印报告 → 触发 HeapDump → JVMTI 通知 → 抛出 `OutOfMemoryError`

### Q5: Chunk 合并和拆分的时机分别是什么？

**答**：
- **合并**：每次归还 Chunk 到 ChunkManager 时自动尝试（`return_single_chunk()` → `attempt_to_coalesce_around_chunk()`），Specialized/Small 尝试合并为 Medium
- **拆分**：分配时请求的 Chunk 大小在空闲池中没有，但有更大的 Chunk 时（`free_chunks_get()` → `split_chunk()`）

### Q6: 如何诊断 Metaspace 泄露？

**答**：5 步诊断法：
1. `jcmd <pid> VM.metaspace show-loaders` → 找出占用最大的 ClassLoader
2. `-Xlog:class+unload=info` → 观察是否有类被卸载
3. `-Xlog:class+loader+data=debug` → 观察 ClassLoaderData 是否被清除
4. `jmap -histo:live <pid>` → 触发 Full GC 并查看类直方图
5. MAT 分析 heap dump → 找到 ClassLoader 的 GC Root 引用链

---

## 8. 源码文件索引

| 文件 | 关键内容 |
|------|---------|
| `memory/metaspace.cpp` | Metaspace::allocate / report_metadata_oome / purge / MetaspaceGC::compute_new_size |
| `memory/metaspace/spaceManager.cpp` | SpaceManager::~SpaceManager() / return_chunk_list |
| `memory/metaspace/chunkManager.cpp` | return_single_chunk / attempt_to_coalesce / split_chunk |
| `memory/metaspace/virtualSpaceList.cpp` | VirtualSpaceList::purge / expand_by / get_new_chunk |
| `memory/metaspace/virtualSpaceNode.cpp` | VirtualSpaceNode::purge / take_from_committed / retire |
| `classfile/classLoaderData.cpp` | ~ClassLoaderData / do_unloading / purge / is_alive / unload |
| `classfile/classLoaderData.hpp` | ClassLoaderDataGraph::purge_if_needed |
| `gc/g1/g1ConcurrentMark.cpp:1292` | Cleanup 阶段 ClassLoaderDataGraph::purge() |
| `gc/g1/g1ConcurrentMark.cpp:1771` | Remark 阶段 SystemDictionary::do_unloading() |
| `gc/shared/collectedHeap.cpp:259` | satisfy_failed_metadata_allocation 循环 |

---

*完成时间: 2026-02-09*
