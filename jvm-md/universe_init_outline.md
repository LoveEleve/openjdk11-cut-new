# universe_init() 详细大纲

> 这是一个学习索引，每个小节都可以单独深入分析
> 标记说明：[ ] 待分析  [~] 部分分析  [x] 已完成

---

## 0. 前置断言检查（可跳过）
```cpp
assert(!Universe::_fully_initialized, "called after initialize_vtables");
guarantee(1 << LogHeapWordSize == sizeof(HeapWord), ...);
guarantee(sizeof(oop) >= sizeof(HeapWord), ...);
guarantee(sizeof(oop) % sizeof(HeapWord) == 0, ...);
```
- [ ] **0.1** LogHeapWordSize 是什么？为什么要检查？
- [ ] **0.2** HeapWord 的作用是什么？

---

## 1. 计时器初始化
```cpp
TraceTime timer("Genesis", TRACETIME_LOG(Info, startuptime));
```
- [ ] **1.1** TraceTime 类的实现原理
- [ ] **1.2** TRACETIME_LOG 宏展开后是什么？
- [ ] **1.3** 如何通过 `-Xlog:startuptime` 查看输出？

---

## 2. JavaClasses::compute_hard_coded_offsets()
```cpp
JavaClasses::compute_hard_coded_offsets();
```
- [ ] **2.1** 什么是 "hard coded offsets"？
- [ ] **2.2** 计算了哪些 Java 类的哪些字段偏移量？
- [ ] **2.3** 为什么 JVM 需要直接访问 Java 对象的字段？
- [ ] **2.4** 这些偏移量存储在哪里？后续怎么使用？

---

## 3. Universe::initialize_heap()【核心】
```cpp
jint status = Universe::initialize_heap();
```

### 3.1 create_heap() - 创建 G1CollectedHeap 对象 [~]
```cpp
_collectedHeap = create_heap();
// → GCConfig::arguments()->create_heap();
// → new G1CollectedHeap(g1_policy);
```
- [~] **3.1.1** GCConfig 如何根据 JVM 参数选择 GC？
- [~] **3.1.2** G1CollectedHeap 构造函数做了什么？
- [~] **3.1.3** G1Policy 是什么？什么时候创建的？

> 概要分析见：`jvm-md/Universe/3.1-create_heap.md`
> ⚠️ **递归细化大纲**：`jvm-md/Universe/3.1-create_heap_outline.md`（包含 50+ 个可深入的子节点）

### 3.2 G1CollectedHeap::initialize()【超级核心】
```cpp
jint status = _collectedHeap->initialize();
```
- [ ] **3.2.1** Universe::reserve_heap() - 预留虚拟内存
  - [ ] 3.2.1.1 ReservedHeapSpace 构造过程
  - [ ] 3.2.1.2 mmap() 系统调用的参数和返回值
  - [ ] 3.2.1.3 压缩指针 base 的初步设置
  - [ ] 3.2.1.4 大页 (Large Pages) 的处理
- [ ] **3.2.2** HeapRegion 的创建
  - [ ] 3.2.2.1 HeapRegionManager 初始化
  - [ ] 3.2.2.2 G1HeapRegionTable 的创建
  - [ ] 3.2.2.3 2048 个 HeapRegion 对象的分配
  - [ ] 3.2.2.4 FreeRegionList 的初始化
- [ ] **3.2.3** CardTable 的创建
  - [ ] 3.2.3.1 G1CardTable 的大小计算
  - [ ] 3.2.3.2 为什么是 512 字节对应 1 个 card？
  - [ ] 3.2.3.3 CardTable 的内存布局
- [ ] **3.2.4** SATB 标记位图的创建
  - [ ] 3.2.4.1 G1CMBitMap 的大小（2 个位图）
  - [ ] 3.2.4.2 prev_bitmap 和 next_bitmap 的作用
  - [ ] 3.2.4.3 为什么需要双缓冲？
- [ ] **3.2.5** BOT (Block Offset Table) 的创建
  - [ ] 3.2.5.1 G1BlockOffsetTable 的作用
  - [ ] 3.2.5.2 每个 HeapRegion 的 BOT 分区
- [ ] **3.2.6** RemSet 相关结构的创建
  - [ ] 3.2.6.1 G1RemSet 初始化
  - [ ] 3.2.6.2 G1FromCardCache 初始化
  - [ ] 3.2.6.3 DirtyCardQueueSet 初始化
- [ ] **3.2.7** 并发标记相关
  - [ ] 3.2.7.1 G1ConcurrentMark 创建
  - [ ] 3.2.7.2 G1ConcurrentRefine 创建
  - [ ] 3.2.7.3 并发标记线程的创建
- [ ] **3.2.8** 其他辅助结构
  - [ ] 3.2.8.1 G1MonitoringSupport（JMX 监控）
  - [ ] 3.2.8.2 G1YoungRemSetSamplingThread
  - [ ] 3.2.8.3 WorkGang（并行 GC 工作线程）

### 3.3 TLAB 相关设置
```cpp
ThreadLocalAllocBuffer::set_max_size(Universe::heap()->max_tlab_size());
```
- [ ] **3.3.1** max_tlab_size() 的计算逻辑（Region/2 = 2MB）
- [ ] **3.3.2** 为什么 TLAB 最大是 Region 的一半？
- [ ] **3.3.3** ThreadLocalAllocBuffer 类的结构

### 3.4 压缩指针配置
```cpp
if (UseCompressedOops) {
    if (heap_end > UnscaledOopHeapMax) set_narrow_oop_shift(3);
    if (heap_end <= OopEncodingHeapMax) set_narrow_oop_base(0);
}
```
- [ ] **3.4.1** UnscaledOopHeapMax (4GB) 和 OopEncodingHeapMax (32GB)
- [ ] **3.4.2** 四种压缩指针模式的选择逻辑
- [ ] **3.4.3** narrow_oop_base 和 narrow_oop_shift 的计算
- [ ] **3.4.4** 隐式空指针检查 (_use_implicit_null_checks)

### 3.5 TLAB 启动初始化
```cpp
ThreadLocalAllocBuffer::startup_initialization();
```
- [ ] **3.5.1** 初始 TLAB 大小的计算
- [ ] **3.5.2** _target_refills 的含义
- [ ] **3.5.3** TLABStats 性能统计

---

## 4. SystemDictionary::initialize_oop_storage()
```cpp
SystemDictionary::initialize_oop_storage();
```
- [ ] **4.1** OopStorage 是什么？解决什么问题？
- [ ] **4.2** "VM Weak Oop Handles" 存储了什么？
- [ ] **4.3** OopStorage 的内存布局（Block 和 ActiveArray）
- [ ] **4.4** GC 如何遍历 OopStorage？

---

## 5. Metaspace::global_initialize()
```cpp
Metaspace::global_initialize();
```
- [ ] **5.1** Metaspace 的整体架构
  - [ ] 5.1.1 VirtualSpaceList
  - [ ] 5.1.2 ChunkManager
  - [ ] 5.1.3 SpaceManager
- [ ] **5.2** CompressedClassSpace 的预留（1GB）
- [ ] **5.3** 非类元数据空间的管理
- [ ] **5.4** Metaspace 的扩展策略
- [ ] **5.5** 与 MaxMetaspaceSize 参数的关系

---

## 6. 性能计数器初始化
```cpp
MetaspaceCounters::initialize_performance_counters();
CompressedClassSpaceCounters::initialize_performance_counters();
```
- [ ] **6.1** PerfData 共享内存机制
- [ ] **6.2** 创建的 8 个计数器详解
- [ ] **6.3** jstat 如何读取这些数据？

---

## 7. AOTLoader::universe_init()
```cpp
AOTLoader::universe_init();
```
- [ ] **7.1** AOT (Ahead-Of-Time) 编译是什么？
- [ ] **7.2** AOT 代码的加载流程
- [ ] **7.3** 与 JIT 的关系

---

## 8. JVM 参数约束检查
```cpp
JVMFlagConstraintList::check_constraints(JVMFlagConstraint::AfterMemoryInit);
```
- [ ] **8.1** AfterMemoryInit 阶段检查哪些约束？
- [ ] **8.2** JVMFlagConstraint 机制详解

---

## 9. ClassLoaderData::init_null_class_loader_data()
```cpp
ClassLoaderData::init_null_class_loader_data();
```
- [ ] **9.1** Bootstrap ClassLoader 为什么特殊？
- [ ] **9.2** ClassLoaderData 的结构
- [ ] **9.3** _the_null_class_loader_data 的作用
- [ ] **9.4** ClassLoaderDataGraph 的概念

---

## 10. LatestMethodCache 创建
```cpp
Universe::_finalizer_register_cache = new LatestMethodCache();
Universe::_loader_addClass_cache    = new LatestMethodCache();
Universe::_pd_implies_cache         = new LatestMethodCache();
Universe::_throw_illegal_access_error_cache = new LatestMethodCache();
Universe::_throw_no_such_method_error_cache = new LatestMethodCache();
Universe::_do_stack_walk_cache = new LatestMethodCache();
```
- [ ] **10.1** LatestMethodCache 的数据结构
- [ ] **10.2** 为什么用 (Klass*, idnum) 而不是 Method*？
- [ ] **10.3** 6 个缓存分别对应什么 Java 方法？
- [ ] **10.4** 这些方法在什么场景下被调用？
- [ ] **10.5** 真正的初始化在哪里？(universe_post_init)

---

## 11. SymbolTable::create_table()
```cpp
SymbolTable::create_table();
```
- [ ] **11.1** Symbol 是什么？和 String 有什么区别？
- [ ] **11.2** SymbolTable 的哈希表实现
  - [ ] 11.2.1 bucket 数量为什么是 20011（质数）？
  - [ ] 11.2.2 HashtableEntry 的结构
  - [ ] 11.2.3 哈希冲突的处理
- [ ] **11.3** Symbol 的引用计数机制
- [ ] **11.4** Symbol 的内存分配（Arena）

---

## 12. StringTable::create_table()
```cpp
StringTable::create_table();
```
- [ ] **12.1** StringTable 和 SymbolTable 的区别
- [ ] **12.2** String.intern() 的实现
- [ ] **12.3** StringTable 的 GC（弱引用）
- [ ] **12.4** G1 的 StringDeduplication 特性

---

## 13. ResolvedMethodTable::create_table()
```cpp
ResolvedMethodTable::create_table();
```
- [ ] **13.1** ResolvedMethodName 是什么？
- [ ] **13.2** MethodHandle 如何使用这个表？
- [ ] **13.3** 类重定义 (RedefineClasses) 时的更新

---

## 学习建议

1. **入门推荐**：先学 11（SymbolTable），因为哈希表是基础
2. **核心必学**：3.2（G1 堆初始化），这是 G1 GC 的核心
3. **理解内存**：5（Metaspace），理解类元数据存储
4. **性能调优**：3.4（压缩指针），理解 32GB 堆限制的来源

---

## 如何使用这个大纲

对我说：
- "分析 3.2.1 - Universe::reserve_heap()"
- "讲解 11.2 - SymbolTable 的哈希表实现"
- "深入 3.4.2 - 四种压缩指针模式"

我会针对那个小节进行深入分析，包括：
- 源码逐行解读
- 关键数据结构
- GDB 验证
- 设计考量
