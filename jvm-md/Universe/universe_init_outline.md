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

### 3.2 G1CollectedHeap::initialize()【超级核心】✅ 已完成
```cpp
jint status = _collectedHeap->initialize();
```
> ⚠️ **递归细化大纲**：`jvm-md/Universe/3.2-initialize_outline.md`（全部完成）

已分析的详细文档：
- `A-ReserveHeap.md` - 预留虚拟内存、压缩指针模式
- `B-Six-Mappers.md` - 6 个 G1RegionToSpaceMapper
- `C.1-HeapRegionManager.md` - Region 管理
- `C.2-RemSetSize.md` / `C.3-G1BarrierSet.md` - 卡表与屏障
- `C.4-G1HotCardCache.md` / `C.5-G1RemSet.md` - 记忆集
- `C.6-G1BlockOffsetTable.md` / `C.7-FastTestArrays.md` - BOT 与快速测试
- `D.1-G1ConcurrentMark.md` / `D.2-G1ConcurrentRefine.md` / `D.3-G1YoungRemSetSamplingThread.md` - 并发组件
- `E.1-expand.md` - 堆扩展
- `F-RuntimeComponents.md` - 运行时组件

### 3.3 TLAB 相关设置 ✅ 已完成
```cpp
ThreadLocalAllocBuffer::set_max_size(Universe::heap()->max_tlab_size());
```
> 详见 [3.3-TLAB.md](3.3-TLAB.md)

- [x] **3.3.1** max_tlab_size() = Region/2 = 2MB（确保不触发巨型对象路径）
- [x] **3.3.2** ThreadLocalAllocBuffer 结构（_start/_top/_end/_desired_size）
- [x] **3.3.3** startup_initialization()（_target_refills=50、C2 预取保留）

### 3.4 压缩指针配置 ✅ 已完成
```cpp
if (UseCompressedOops) {
    if (heap_end > UnscaledOopHeapMax) set_narrow_oop_shift(3);
    if (heap_end <= OopEncodingHeapMax) set_narrow_oop_base(0);
}
```
> 详见 [3.4-CompressedOops.md](3.4-CompressedOops.md)

- [x] **3.4.1** UnscaledOopHeapMax (4GB) 和 OopEncodingHeapMax (32GB)
- [x] **3.4.2** 四种压缩指针模式（Unscaled/ZeroBased/DisjointBase/HeapBased）
- [x] **3.4.3** narrow_oop_base=0, narrow_oop_shift=3（8GB 堆典型配置）
- [x] **3.4.4** 隐式空指针检查（_use_implicit_null_checks）

### 3.5 TLAB 启动初始化 ✅ 已包含在 3.3
> 已合并到 [3.3-TLAB.md](3.3-TLAB.md) 中分析

---

## 4. SystemDictionary::initialize_oop_storage() ✅ 已完成
```cpp
SystemDictionary::initialize_oop_storage();
```
> 详见 [4-OopStorage.md](4-OopStorage.md)

- [x] **4.1** OopStorage 解决什么问题？（管理堆外 oop 引用的高并发容器）
- [x] **4.2** "VM Weak Oop Handles" 存储了什么？（JNI 弱全局引用、StringTable 去重等）
- [x] **4.3** OopStorage 的内存布局（Block + ActiveArray + AllocationList）
- [x] **4.4** GC 如何遍历 OopStorage？（位图跳过空位，双锁分离）

---

## 5. Metaspace::global_initialize() ✅ 已完成
```cpp
Metaspace::global_initialize();
```
> 详见 [5-Metaspace.md](5-Metaspace.md)

- [x] **5.1** Metaspace 的两部分：压缩类空间（1GB）+ 数据元空间（8MB 初始）
- [x] **5.2** VirtualSpaceList / VirtualSpaceNode / ChunkManager 结构
- [x] **5.3** CompressedClassSpace 的预留（紧挨堆末尾 0x800000000）
- [x] **5.4** 压缩类指针编码（base=堆末尾, shift=0）
- [x] **5.5** MetaspaceGC 阈值（启动时设为 MaxMetaspaceSize）

---

## 6. 性能计数器初始化 ✅ 已完成
```cpp
MetaspaceCounters::initialize_performance_counters();
CompressedClassSpaceCounters::initialize_performance_counters();
```
> 详见 [6-PerfCounters.md](6-PerfCounters.md)

- [x] **6.1** PerfData 共享内存机制（`/tmp/hsperfdata_<user>/<pid>`，32KB mmap）
- [x] **6.2** 创建的 8 个计数器详解（metaspace + compressedclassspace 各 4 个）
- [x] **6.3** jstat 如何读取这些数据？（mmap 只读映射，零拷贝）
- [x] **6.4** 与 jstat 列名的对应（MC/MU/CCSC/CCSU）
- [x] **6.5** 禁用方式及影响（`-XX:-UsePerfData`）

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

## 9. ClassLoaderData::init_null_class_loader_data() ✅ 已完成
```cpp
ClassLoaderData::init_null_class_loader_data();
```
> 详见 [9-ClassLoaderData.md](9-ClassLoaderData.md)

- [x] **9.1** Bootstrap ClassLoader 为什么特殊？（`_class_loader=NULL`，`_keep_alive=1`，永不卸载）
- [x] **9.2** ClassLoaderData 的结构（`_metaspace`/`_klasses`/`_packages`/`_dictionary`）
- [x] **9.3** _the_null_class_loader_data 的作用（全局静态指针，表示 Bootstrap ClassLoader）
- [x] **9.4** ClassLoaderDataGraph 的概念（全局单向链表，管理所有 CLD）
- [x] **9.5** Dictionary 类字典（1009 个桶，存储已加载的 InstanceKlass）
- [x] **9.6** Metaspace 延迟创建（首次加载类时才分配）

---

## 10. LatestMethodCache 创建 ✅ 已完成
```cpp
Universe::_finalizer_register_cache = new LatestMethodCache();
Universe::_loader_addClass_cache    = new LatestMethodCache();
Universe::_pd_implies_cache         = new LatestMethodCache();
Universe::_throw_illegal_access_error_cache = new LatestMethodCache();
Universe::_throw_no_such_method_error_cache = new LatestMethodCache();
Universe::_do_stack_walk_cache = new LatestMethodCache();
```
> 详见 [10-LatestMethodCache.md](10-LatestMethodCache.md)

- [x] **10.1** LatestMethodCache 的数据结构（`_klass` + `_method_idnum`）
- [x] **10.2** 为什么用 (Klass*, idnum) 而不是 Method*？（支持类重定义/Hotswap）
- [x] **10.3** 6 个缓存分别对应什么 Java 方法？
  - `Finalizer.register(Object)` - 注册 finalizer
  - `ClassLoader.addClass(Class)` - 注册已加载的类
  - `ProtectionDomain.impliesCreateAccessControlContext()` - 安全检查
  - `Unsafe.throwIllegalAccessError()` / `throwNoSuchMethodError()` - 抛异常
  - `AbstractStackWalker.doStackWalk(...)` - 栈遍历 API
- [x] **10.4** 这些方法在什么场景下被调用？（创建有 finalize() 的对象、类加载等）
- [x] **10.5** 真正的初始化在哪里？(`universe_post_init` → `initialize_known_methods`)

---

## 11. SymbolTable::create_table() ✅ 已完成
```cpp
SymbolTable::create_table();
```
> 详见 [11-SymbolTable.md](11-SymbolTable.md)

- [x] **11.1** Symbol 是什么？和 String 有什么区别？（C++ 堆存储、UTF-8 编码、引用计数）
- [x] **11.2** SymbolTable 的哈希表实现
  - [x] 11.2.1 bucket 数量为什么是 20011（质数减少冲突）
  - [x] 11.2.2 HashtableEntry 的结构（24 字节：hash + next + literal）
  - [x] 11.2.3 哈希冲突的处理（链表法）
- [x] **11.3** Symbol 的引用计数机制（-1=永久，>=1=临时）
- [x] **11.4** Symbol 的内存分配（Arena 360KB 预分配，指针 bump）

---

## 12. StringTable::create_table() ✅ 已完成
```cpp
StringTable::create_table();
```
> 详见 [12-StringTable.md](12-StringTable.md)

- [x] **12.1** StringTable 和 SymbolTable 的区别（弱引用 vs 引用计数，Java 堆 vs C++ 堆）
- [x] **12.2** String.intern() 的实现（查共享表 → 查动态表 → 插入）
- [x] **12.3** StringTable 的 GC（WeakHandle + OopStorage，后台清理死亡条目）
- [x] **12.4** G1 的 StringDeduplication 特性（自动去重）

---

## 13. ResolvedMethodTable::create_table() ✅ 已完成
```cpp
ResolvedMethodTable::create_table();
```
> 详见 [13-ResolvedMethodTable.md](13-ResolvedMethodTable.md)

- [x] **13.1** ResolvedMethodName 是什么？（包装 Method* 的 Java 对象，含 vmtarget 字段）
- [x] **13.2** MethodHandle 如何使用这个表？（MemberName → ResolvedMethodName → Method*）
- [x] **13.3** 类重定义 (RedefineClasses) 时的更新（`adjust_method_entries()` 批量更新 vmtarget）
- [x] **13.4** 与 SymbolTable/StringTable 的对比（弱引用、1007 桶、支持类重定义）
- [x] **13.5** GC 清理机制（`unlink()` 移除已回收的 ResolvedMethodName）

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
