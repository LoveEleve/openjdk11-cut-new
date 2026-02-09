# G1 Full GC 深度分析

## 1. Full GC 概述

### 1.1 什么是 Full GC

Full GC 是 G1 垃圾收集器的**最后防线**，当其他 GC 方式无法解决内存问题时触发。它是一个**整堆收集器**，会：
- 回收整个年轻代和老年代
- 使用**标记-整理（Mark-Compact）**算法
- 完全停止应用线程（STW）
- 单线程或多线程并行执行

### 1.2 核心设计思想

```
┌─────────────────────────────────────────────────────────────────┐
│                     Full GC 设计哲学                             │
├─────────────────────────────────────────────────────────────────┤
│  1. 正确性优先：保证在任何情况下都能回收内存                      │
│  2. 单代收集：不再区分年轻代/老年代，统一处理                     │
│  3. 整理压缩：消除内存碎片，将存活对象移动到堆的一端               │
│  4. 串并行结合：大部分时间并行执行，必要时串行处理                 │
└─────────────────────────────────────────────────────────────────┘
```

### 1.3 触发条件

| 触发条件 | 描述 | 代码位置 |
|---------|------|---------|
| **Evacuation Failure** | 对象复制失败（晋升失败） | `g1ParScanThreadState.cpp` |
| **System.gc()** | 显式调用 | `System.gc()` |
| **堆扩展失败** | 无法满足分配请求 | `expand_and_allocate()` |
| **元数据区不足** | Metadata GC Threshold | `MetaspaceGC` |
| **元空间不足** | Class Metadata 分配失败 | 类加载时 |

## 2. 核心数据结构

### 2.1 G1FullCollector - Full GC 控制器

```cpp
// src/hotspot/share/gc/g1/g1FullCollector.hpp:56
class G1FullCollector : StackObj {
  G1CollectedHeap*          _heap;              // G1 堆实例
  G1FullGCScope             _scope;             // GC 作用域管理
  uint                      _num_workers;       // 工作线程数
  G1FullGCMarker**          _markers;           // 标记器数组（每个worker一个）
  G1FullGCCompactionPoint** _compaction_points; // 压缩点数组
  OopQueueSet               _oop_queue_set;     // 对象标记队列集合
  ObjArrayTaskQueueSet      _array_queue_set;   // 数组标记队列集合
  PreservedMarksSet         _preserved_marks_set; // 保留的mark word集合
  G1FullGCCompactionPoint   _serial_compaction_point; // 串行压缩点
  G1IsAliveClosure          _is_alive;          // 存活判断闭包
  
  // 四大核心阶段
  void phase1_mark_live_objects();     // 阶段1: 标记存活对象
  void phase2_prepare_compaction();    // 阶段2: 准备压缩
  void phase3_adjust_pointers();       // 阶段3: 调整指针
  void phase4_do_compaction();         // 阶段4: 执行压缩
};
```

**内存布局图：**
```
┌─────────────────────────────────────────────────────────────────┐
│                     G1FullCollector (StackObj)                  │
├─────────────────────────────────────────────────────────────────┤
│ _heap              │ 8 bytes │ 指向 G1CollectedHeap             │
│ _scope             │ 40 bytes│ G1FullGCScope                    │
│ _num_workers       │ 4 bytes │ 工作线程数量                     │
│ _markers           │ 8 bytes │ G1FullGCMarker* []               │
│ _compaction_points │ 8 bytes │ G1FullGCCompactionPoint* []      │
│ _oop_queue_set     │ 16 bytes│ OopQueueSet                      │
│ _array_queue_set   │ 16 bytes│ ObjArrayTaskQueueSet             │
│ _preserved_marks_set│24 bytes│ PreservedMarksSet                │
│ _serial_compaction_point│40 bytes│ G1FullGCCompactionPoint       │
│ _is_alive          │ 16 bytes│ G1IsAliveClosure                 │
└─────────────────────────────────────────────────────────────────┘
Total: ~160+ bytes
```

### 2.2 G1FullGCCompactionPoint - 压缩点

```cpp
// src/hotspot/share/gc/g1/g1FullGCCompactionPoint.hpp
class G1FullGCCompactionPoint : StackObj {
  HeapRegion* _current_region;           // 当前压缩目标Region
  GrowableArray<HeapRegion*>* _regions;  // 需要压缩的Region列表
  HeapWord*   _compaction_top;           // 当前压缩位置
  bool        _initialized;              // 是否已初始化
};
```

**内存布局：**
```
┌──────────────────────────────────────────────────────────────┐
│                G1FullGCCompactionPoint                        │
├──────────────────────────────────────────────────────────────┤
│ _current_region  │ 8 bytes │ 当前正在压缩的目标Region        │
│ _regions         │ 8 bytes │ GrowableArray<HeapRegion*>      │
│ _compaction_top  │ 8 bytes │ 当前压缩到的位置                │
│ _initialized     │ 1 byte  │ 是否已初始化                    │
│ padding          │ 7 bytes │ 对齐填充                        │
└──────────────────────────────────────────────────────────────┘
Total: 40 bytes
```

### 2.3 G1FullGCMarker - 并行标记器

```cpp
// src/hotspot/share/gc/g1/g1FullGCMarker.hpp
class G1FullGCMarker : StackObj {
  uint                              _worker_id;      // Worker ID
  G1FullGCMarkStack                 _oop_stack;      // 对象标记栈
  G1FullGCMarkStack                 _objarray_stack; // 数组标记栈
  PreservedMarks*                   _preserved_stack;// 保留的marks
  G1CMBitMap*                       _mark_bitmap;    // 标记位图
  G1FullGCMarkingVerifier           _verifier;       // 验证器
  G1FullGCMarkRootOopClosure        _root_closure;   // 根处理闭包
  G1FullGCMarkCodeBlobClosure       _code_closure;   // CodeBlob闭包
  G1FullGCMarkCLDClosure            _cld_closure;    // ClassLoaderData闭包
};
```

**内存布局：**
```
┌──────────────────────────────────────────────────────────────────┐
│                      G1FullGCMarker                               │
├──────────────────────────────────────────────────────────────────┤
│ _worker_id          │ 4 bytes  │ Worker线程ID                    │
│ _oop_stack          │ ~64 bytes│ 对象标记栈（动态数组）          │
│ _objarray_stack     │ ~64 bytes│ 数组标记栈                      │
│ _preserved_stack    │ 8 bytes  │ PreservedMarks*                 │
│ _mark_bitmap        │ 8 bytes  │ G1CMBitMap*                     │
│ _verifier           │ 16 bytes │ 验证器                          │
│ _root_closure       │ 24 bytes │ 根处理闭包                      │
│ _code_closure       │ 16 bytes │ CodeBlob处理闭包                │
│ _cld_closure        │ 16 bytes │ CLD处理闭包                     │
└──────────────────────────────────────────────────────────────────┘
Total: ~220+ bytes per worker
```

## 3. Full GC 四阶段算法详解

### 3.1 阶段1: 标记存活对象 (Mark Live Objects)

```cpp
// src/hotspot/share/gc/g1/g1FullCollector.cpp:203
void G1FullCollector::phase1_mark_live_objects() {
  GCTraceTime(Info, gc, phases) info("Phase 1: Mark live objects", scope()->timer());

  // 1. 并行标记
  G1FullGCMarkTask marking_task(this);
  run_task(&marking_task);

  // 2. 处理引用对象（软引用、弱引用等）
  G1FullGCReferenceProcessingExecutor reference_processing(this);
  reference_processing.execute(scope()->timer(), scope()->tracer());

  // 3. 弱引用清理
  WeakProcessor::weak_oops_do(&_is_alive, &do_nothing_cl);

  // 4. 类卸载和清理
  if (ClassUnloading) {
    SystemDictionary::do_unloading(scope()->timer());
    _heap->complete_cleaning(&_is_alive, purged_class);
  }
}
```

**标记算法 - 三色标记法：**
```
┌──────────────────────────────────────────────────────────────────┐
│                      三色标记原理                                 │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  白色: 未访问（垃圾对象）        灰色: 已访问但子对象未访问       │
│  黑色: 已访问且子对象已访问      标记位图: 记录对象存活状态       │
│                                                                  │
│  初始状态: 根对象为灰色，其他为白色                              │
│                                                                  │
│     ┌─────────┐                                                  │
│     │  灰色   │ ← Root Object                                   │
│     └────┬────┘                                                  │
│          │                                                       │
│    ┌─────┴─────┐                                                 │
│    ▼           ▼                                                 │
│ ┌──────┐   ┌──────┐                                              │
│ │白色  │   │白色  │                                              │
│ └──────┘   └──────┘                                              │
│                                                                  │
│  标记完成后: 黑色=存活，白色=垃圾                                 │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

**并行标记任务：**
```cpp
// src/hotspot/share/gc/g1/g1FullGCMarkTask.cpp:44
void G1FullGCMarkTask::work(uint worker_id) {
  G1FullGCMarker* marker = collector()->marker(worker_id);
  MarkingCodeBlobClosure code_closure(marker->mark_closure(), !CodeBlobToOopClosure::FixRelocations);

  // 1. 处理所有根对象（线程栈、JNI句柄、CLDs等）
  if (ClassUnloading) {
    _root_processor.process_strong_roots(
        marker->mark_closure(),
        marker->cld_closure(),
        &code_closure);
  } else {
    _root_processor.process_all_roots_no_string_table(...);
  }

  // 2. 处理并清空标记栈（并行处理）
  marker->complete_marking(collector()->oop_queue_set(), 
                           collector()->array_queue_set(), 
                           &_terminator);
}
```

**GDB 验证：**
```bash
# 设置断点在标记阶段
(gdb) break G1FullCollector::phase1_mark_live_objects
(gdb) break G1FullGCMarkTask::work

# 查看标记位图
(gdb) p *collector()->mark_bitmap()
(gdb) p /x bitmap->_bitmap_base[0]  # 查看位图前64位

# 查看标记栈
(gdb) p marker->_oop_stack
(gdb) p marker->_oop_stack._stack_base
```

### 3.2 阶段2: 准备压缩 (Prepare Compaction)

```cpp
// src/hotspot/share/gc/g1/g1FullCollector.cpp:236
void G1FullCollector::phase2_prepare_compaction() {
  GCTraceTime(Info, gc, phases) info("Phase 2: Prepare for compaction", scope()->timer());
  G1FullGCPrepareTask task(this);
  run_task(&task);

  // 如果没有释放Region，需要串行压缩准备
  if (!task.has_freed_regions()) {
    task.prepare_serial_compaction();
  }
}
```

**准备压缩算法：**
```cpp
// src/hotspot/share/gc/g1/g1FullGCPrepareTask.cpp:42
bool G1FullGCPrepareTask::G1CalculatePointersClosure::do_heap_region(HeapRegion* hr) {
  if (hr->is_humongous()) {
    // 处理大对象Region
    oop obj = oop(hr->humongous_start_region()->bottom());
    if (_bitmap->is_marked(obj)) {
      // 存活的大对象：原地不动，forward_to自己
      if (hr->is_starts_humongous()) {
        obj->forward_to(obj);
      }
    } else {
      // 死亡的大对象：释放Region
      free_humongous_region(hr);
    }
  } else if (!hr->is_pinned()) {
    // 普通Region：准备压缩
    prepare_for_compaction(hr);
  }

  // 重置Region元数据
  reset_region_metadata(hr);
  return false;
}
```

**压缩准备示意图：**
```
┌──────────────────────────────────────────────────────────────────┐
│                    压缩前内存布局                                 │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Region 0    Region 1    Region 2    Region 3    Region 4       │
│ ┌─────┐    ┌─────┐    ┌─────┐    ┌─────┐    ┌─────┐            │
│ │ ██  │    │░░░░░│    │ ██  │    │ ██  │    │░░░░░│            │
│ │ ██  │    │░░░░░│    │ ██  │    │     │    │░░░░░│            │
│ │     │    │░██░ │    │     │    │ ██  │    │░░░░░│            │
│ └─────┘    └─────┘    └─────┘    └─────┘    └─────┘            │
│  存活        垃圾      存活        存活(碎片)  垃圾              │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│                    计算转发指针（Forward）                        │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  每个存活对象设置 forward pointer:                                 │
│                                                                  │
│  obj1 (size=32)  ──forward_to──► Region 0, offset 0             │
│  obj2 (size=48)  ──forward_to──► Region 0, offset 32            │
│  obj3 (size=16)  ──forward_to──► Region 0, offset 80            │
│  obj4 (size=64)  ──forward_to──► Region 1, offset 0             │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│                    压缩后内存布局                                 │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Region 0    Region 1    Region 2    Region 3    Region 4       │
│ ┌─────┐    ┌─────┐    ┌─────┐    ┌─────┐    ┌─────┐            │
│ │obj1 │    │obj4 │    │     │    │     │    │     │            │
│ │obj2 │    │     │    │     │    │     │    │     │            │
│ │obj3 │    │     │    │     │    │     │    │     │            │
│ └─────┘    └─────┘    └─────┘    └─────┘    └─────┘            │
│  紧凑        部分      空闲       空闲       空闲               │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

**GDB 验证：**
```bash
# 断点在准备阶段
(gdb) break G1FullCollector::phase2_prepare_compaction
(gdb) break G1FullGCPrepareTask::work

# 查看Region转发信息
(gdb) p hr->_compaction_top
(gdb) p obj->mark()->decode_pointer()

# 查看压缩点队列
(gdb) p *compaction_point->_regions
(gdb) p compaction_point->_regions->_data[0]
```

### 3.3 阶段3: 调整指针 (Adjust Pointers)

```cpp
// src/hotspot/share/gc/g1/g1FullCollector.cpp:247
void G1FullCollector::phase3_adjust_pointers() {
  GCTraceTime(Info, gc, phases) info("Phase 3: Adjust pointers", scope()->timer());
  G1FullGCAdjustTask task(this);
  run_task(&task);
}
```

**指针调整算法：**
```cpp
// src/hotspot/share/gc/g1/g1FullGCAdjustTask.cpp:89
void G1FullGCAdjustTask::work(uint worker_id) {
  G1FullGCMarker* marker = collector()->marker(worker_id);
  
  // 1. 调整保留的marks
  marker->preserved_stack()->adjust_during_full_gc();

  // 2. 调整弱根
  _root_processor.process_full_gc_weak_roots(&_adjust);

  // 3. 调整所有根对象
  _root_processor.process_all_roots(&_adjust, &adjust_cld, &adjust_code);

  // 4. 调整每个Region内的对象指针
  G1AdjustRegionClosure blk(collector()->mark_bitmap(), worker_id);
  G1CollectedHeap::heap()->heap_region_par_iterate_from_worker_offset(&blk, &_hrclaimer, worker_id);
}
```

**调整逻辑：**
```cpp
// 将对象内的引用指向新的位置
class G1AdjustClosure : public OopClosure {
public:
  void do_oop(oop* p) {
    oop obj = RawAccess<>::oop_load(p);
    if (obj != NULL) {
      // 获取转发指针（新位置）
      oop new_obj = obj->forwardee();
      if (new_obj != NULL) {
        RawAccess<>::oop_store(p, new_obj);
      }
    }
  }
};
```

**指针调整示意图：**
```
┌──────────────────────────────────────────────────────────────────┐
│                    调整前对象引用                                 │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│    Object A                       Object B                       │
│   ┌─────────┐                   ┌─────────┐                     │
│   │klass    │                   │klass    │                     │
│   │field1   │─────ref_to_B─────►│data     │                     │
│   │field2   │                   │...      │                     │
│   └─────────┘                   └─────────┘                     │
│   addr=0x1000                   addr=0x5000                     │
│                                                                  │
│   转发指针: B.forwardee = 0x2000 (新位置)                        │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│                    调整后对象引用                                 │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│    Object A                       Object B (已移动)              │
│   ┌─────────┐                   ┌─────────┐                     │
│   │klass    │                   │klass    │                     │
│   │field1   │─────ref_to_B─────►│data     │                     │
│   │field2   │                   │...      │                     │
│   └─────────┘                   └─────────┘                     │
│   addr=0x1000                   addr=0x2000 ◄── 更新为转发目标  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

**GDB 验证：**
```bash
# 断点在调整阶段
(gdb) break G1FullCollector::phase3_adjust_pointers

# 查看对象转发指针
(gdb) p obj->mark()
(gdb) p obj->forwardee()

# 查看指针调整过程
(gdb) watch *oop_field_addr
(gdb) continue
```

### 3.4 阶段4: 执行压缩 (Do Compaction)

```cpp
// src/hotspot/share/gc/g1/g1FullCollector.cpp:255
void G1FullCollector::phase4_do_compaction() {
  GCTraceTime(Info, gc, phases) info("Phase 4: Compact heap", scope()->timer());
  G1FullGCCompactTask task(this);
  run_task(&task);

  // 串行压缩（当剩余空闲Region很少时）
  if (serial_compaction_point()->has_regions()) {
    task.serial_compaction();
  }
}
```

**压缩算法：**
```cpp
// src/hotspot/share/gc/g1/g1FullGCCompactTask.cpp:62
size_t G1FullGCCompactTask::G1CompactRegionClosure::apply(oop obj) {
  size_t size = obj->size();
  HeapWord* destination = (HeapWord*)obj->forwardee();
  
  if (destination == NULL) {
    // 对象不移动
    return size;
  }

  // 1. 复制对象到新位置
  HeapWord* obj_addr = (HeapWord*)obj;
  Copy::aligned_conjoint_words(obj_addr, destination, size);
  
  // 2. 重新初始化mark word
  oop(destination)->init_mark_raw();
  
  return size;
}
```

**压缩过程示意图：**
```
┌──────────────────────────────────────────────────────────────────┐
│                   压缩执行过程                                    │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  源Region (From)                目标Region (To)                 │
│ ┌─────────────┐               ┌─────────────┐                   │
│ │ obj1 (live) │ ──copy──►    │ obj1         │                   │
│ │ obj2 (dead) │ ──skip──►    │ obj2         │                   │
│ │ obj3 (live) │ ──copy──►    │ obj3         │                   │
│ │ obj4 (dead) │ ──skip──►    │              │                   │
│ │ obj5 (live) │ ──copy──►    │ obj5         │                   │
│ └─────────────┘               └─────────────┘                   │
│                                                                  │
│  按顺序遍历对象：                                                 │
│  - 存活对象：复制到目标Region的当前位置，更新目标位置             │
│  - 垃圾对象：跳过，不复制                                        │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

**GDB 验证：**
```bash
# 断点在压缩阶段
(gdb) break G1FullCollector::phase4_do_compaction
(gdb) break G1FullGCCompactTask::compact_region

# 查看对象复制过程
(gdb) p obj
(gdb) p destination
(gdb) p size

# 单步跟踪复制操作
(gdb) step
(gdb) p Copy::aligned_conjoint_words
```

## 4. 触发场景详细分析

### 4.1 Evacuation Failure (晋升失败)

**触发条件：**
```cpp
// src/hotspot/share/gc/g1/g1ParScanThreadState.cpp
inline void G1ParScanThreadState::copy_to_survivor_space(...) {
  // ... 尝试分配空间
  if (obj_ptr == NULL) {
    // 分配失败！触发 evacuation failure
    handle_evacuation_failure_par(old, m);
  }
}
```

**处理流程：**
```
┌─────────────────────────────────────────────────────────────────┐
│              Evacuation Failure 处理流程                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 对象复制失败                                                │
│       │                                                         │
│       ▼                                                         │
│  2. 设置 forward pointer 指向自己（原地不动）                  │
│       │                                                         │
│       ▼                                                         │
│  3. 保留原始 mark word（用于后续恢复）                          │
│       │                                                         │
│       ▼                                                         │
│  4. 如果失败对象过多，触发 Full GC                             │
│       │                                                         │
│       ▼                                                         │
│  5. Full GC 使用标记-整理算法回收整个堆                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 System.gc() 显式调用

```cpp
// 代码路径：java.lang.System.gc() → JVM_GC → invoke_gc
// src/hotspot/share/gc/g1/g1CollectedHeap.cpp
void G1CollectedHeap::collect(GCCause::Cause cause) {
  switch (cause) {
    case GCCause::_java_lang_system_gc:
      // 显式 GC 调用
      collect_full(cause, max_parallel_worker_threads(), false);
      break;
    // ...
  }
}
```

### 4.3 堆扩展失败

```cpp
// src/hotspot/share/gc/g1/g1CollectedHeap.cpp
HeapWord* G1CollectedHeap::expand_and_allocate(size_t word_size) {
  // 尝试扩展堆
  if (expand(word_size)) {
    return attempt_allocation(word_size);
  }
  // 扩展失败，返回 NULL，后续可能触发 Full GC
  return NULL;
}
```

## 5. 关键 JVM 参数

| 参数 | 默认值 | 说明 |
|-----|-------|------|
| `-XX:+UseG1GC` | - | 启用 G1 GC |
| `-XX:G1HeapRegionSize` | 动态计算 | Region 大小（1-32MB） |
| `-XX:+DisableExplicitGC` | false | 禁用 System.gc() |
| `-XX:G1ReservePercent` | 10 | 保留内存百分比 |
| `-XX:+UseDynamicNumberOfGCThreads` | true | 动态调整GC线程数 |

**日志参数：**
```bash
# 启用 Full GC 详细日志
-Xlog:gc*:file=gc.log:time,uptime,level,tags:filecount=5,filesize=100m

# 启用 Full GC 阶段日志
-Xlog:gc+phases=debug

# 启用任务执行日志
-Xlog:gc+task=debug
```

**示例输出：**
```
[2024-01-15T10:30:45.123+0800][info][gc] GC(42) Pause Full (System.gc()) 6144M->2048M(8192M) 2503.450ms
[2024-01-15T10:30:45.123+0800][info][gc,phases] GC(42) Phase 1: Mark live objects 800.234ms
[2024-01-15T10:30:45.123+0800][info][gc,phases] GC(42) Phase 2: Prepare for compaction 450.123ms
[2024-01-15T10:30:45.123+0800][info][gc,phases] GC(42) Phase 3: Adjust pointers 600.456ms
[2024-01-15T10:30:45.123+0800][info][gc,phases] GC(42) Phase 4: Compact heap 652.637ms
[2024-01-15T10:30:45.123+0800][info][gc,task] GC(42) Using 8 workers of 8 for full compaction
```

## 6. 结构关联图

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Full GC 结构关联图                            │
└─────────────────────────────────────────────────────────────────────┘

                        G1FullCollector
                              │
           ┌──────────────────┼──────────────────┐
           │                  │                  │
           ▼                  ▼                  ▼
    ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
    │G1FullGCScope │   │G1FullGCMarker│   │G1FullGC      │
    │              │   │    []*       │   │CompactionPoint│
    │- _timer      │   │              │   │    []*        │
    │- _tracer     │   │- _oop_stack  │   │              │
    │- _explicit_gc│   │- _mark_bitmap│   │- _regions    │
    └──────────────┘   │- _root_closure│   │- _compaction │
                       └──────────────┘   │  _top        │
                              │           └──────────────┘
                              │                  │
           ┌──────────────────┼──────────────────┤
           │                  │                  │
           ▼                  ▼                  ▼
    ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
    │G1FullGC      │   │G1FullGC      │   │G1FullGC      │
    │MarkTask      │   │PrepareTask   │   │AdjustTask    │
    │              │   │              │   │              │
    │- work()      │   │- work()      │   │- work()      │
    │  mark roots   │   │  calc ptrs    │   │  adjust ptrs  │
    │  drain stack  │   │  set forward  │   │  fix refs     │
    └──────────────┘   └──────────────┘   └──────────────┘
                                                  │
                                                  ▼
                                         ┌──────────────┐
                                         │G1FullGC      │
                                         │CompactTask    │
                                         │              │
                                         │- work()       │
                                         │  copy objects │
                                         │  compact heap │
                                         └──────────────┘

                              │
                              ▼
                    ┌──────────────────┐
                    │   HeapRegion       │
                    │   (每个Region)     │
                    ├──────────────────┤
                    │ - _compaction_top  │
                    │ - _bottom/_top     │
                    │ - rem_set()        │
                    └──────────────────┘
```

## 7. 总结

### 7.1 Full GC vs Young GC 对比

| 特性 | Young GC | Full GC |
|-----|---------|---------|
| 收集范围 | 年轻代（Eden + Survivor） | 整个堆（年轻代 + 老年代） |
| 算法 | 标记-复制（Mark-Copy） | 标记-整理（Mark-Compact） |
| 并行度 | 高（多线程并行） | 高（多线程并行 + 必要时串行） |
| STW 时间 | 短（通常 < 100ms） | 长（通常 > 1s） |
| 触发条件 | 分配失败、定时触发 | 晋升失败、显式调用、扩展失败 |
| 内存碎片 | 可能有（老年代） | 无（完全整理） |

### 7.2 关键要点

1. **Full GC 是最后防线**：当其他 GC 无法回收足够内存时触发
2. **四阶段算法**：标记 → 准备压缩 → 调整指针 → 执行压缩
3. **并行执行**：利用多核CPU并行处理，提高效率
4. **完全STW**：整个过程应用暂停，应尽量避免
5. **内存整理**：通过压缩消除碎片，提高后续分配效率
