# G1RootProcessor 专家级源码分析

## 一、宏观理解：GC Roots 的中央处理器

### 1.1 一句话总结

**G1RootProcessor 是 G1 的 GC Roots 中央处理器**，负责在 Young GC 的 Evacuation 阶段，协调多个 GC 线程并行扫描各种 GC Roots（线程栈、JNI、CLDG、CodeCache 等），将存活对象复制到 Survivor/Old 区域。

### 1.2 为什么需要 G1RootProcessor？

**问题背景**：
- Young GC 需要找到所有从**根**可达的对象
- 根来源众多：线程栈、JNI 全局引用、类加载器、代码缓存等
- 需要**并行处理**以缩短暂停时间
- 需要**任务分发**避免线程竞争

**解决方案**：
- G1RootProcessor 提供统一的根处理框架
- 使用 `SubTasksDone` 进行任务认领（工作窃取）
- 支持强根/弱根分离处理（用于类卸载）

### 1.3 GC Roots 分类

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           GC Roots 分类                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Java 层面 Roots：                                                           │
│  ─────────────────                                                           │
│  ├── 线程栈（Threads）                                                       │
│  │   └── Java 线程的栈帧中的局部变量、操作数栈                                 │
│  │                                                                         │
│  ├── 类加载器数据图（ClassLoaderDataGraph）                                  │
│  │   └── 所有 ClassLoader 及其加载的类的静态字段                               │
│  │                                                                         │
│  └── JNI 引用（JNIHandles）                                                  │
│      ├── JNI 全局引用（Global References）                                   │
│      └── JNI 局部引用（Local References）                                    │
│                                                                              │
│  JVM 层面 Roots：                                                            │
│  ────────────────                                                            │
│  ├── Universe                                                                │
│  │   └── JVM 内部对象（如基本类型的 Class 对象、异常对象等）                   │
│  │                                                                         │
│  ├── SystemDictionary                                                        │
│  │   └── 已加载的类、方法、字段的符号引用                                      │
│  │                                                                         │
│  ├── ObjectSynchronizer                                                      │
│  │   └── 等待 Monitor 的对象                                                 │
│  │                                                                         │
│  ├── Management                                                              │
│  │   └── JMX 相关的 MBean 引用                                               │
│  │                                                                         │
│  ├── JVMTI                                                                   │
│  │   └── JVMTI 代理持有的引用                                                │
│  │                                                                         │
│  ├── StringTable                                                             │
│  │   └── 字符串常量池（弱根，类卸载时可能清除）                                │
│  │                                                                         │
│  └── CodeCache                                                               │
│      └── JIT 编译后的代码中引用的对象（nmethod）                              │
│                                                                              │
│  GC 内部 Roots：                                                             │
│  ────────────────                                                            │
│  ├── ReferenceProcessor                                                      │
│  │   └── 发现的 Reference 对象（Soft/Weak/Phantom Reference）                │
│  │                                                                         │
│  ├── WeakProcessor                                                           │
│  │   └── 各种弱引用（如 StringTable、SymbolTable）                           │
│  │                                                                         │
│  └── SATB Buffers                                                            │
│      └── 并发标记的 SATB 队列中的对象                                        │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.4 在 Young GC 中的位置

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Young GC 中 G1RootProcessor 的位置                         │
└─────────────────────────────────────────────────────────────────────────────┘

Young GC 触发
     │
     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  VM_G1CollectForAllocation::work()                                      │
│       │                                                                 │
│       ├──> G1CollectedHeap::do_collection_pause_at_safepoint()          │
│       │       │                                                         │
│       │       ├──> G1CollectedHeap::gc_prologue()                       │
│       │       ├──> G1CollectedHeap::process_roots()                     │
│       │       │       │                                                 │
│       │       │       └──> G1RootProcessor::evacuate_roots()           │
│       │       │               │  ★ 根处理入口                          │
│       │       │               ├──> process_java_roots()                │
│       │       │               │       ├──> ClassLoaderDataGraph        │
│       │       │               │       └──> Threads                     │
│       │       │               ├──> process_vm_roots()                  │
│       │       │               │       ├──> Universe                    │
│       │       │               │       ├──> JNIHandles                  │
│       │       │               │       ├──> SystemDictionary            │
│       │       │               │       └──> ...                         │
│       │       │               └──> process_string_table_roots()        │
│       │       │                                                     │
│       │       ├──> G1ParTask::work()  // Evacuation 阶段             │
│       │       │       └──> 复制存活对象到 Survivor/Old               │
│       │       │                                                     │
│       │       └──> G1CollectedHeap::gc_epilogue()                    │
│       │                                                             │
│       └──> ...                                                     │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 二、字段分析：数据结构的完整解剖

### 2.1 类定义与内存布局

```cpp
// g1RootProcessor.hpp:49-131
class G1RootProcessor : public StackObj {
    G1CollectedHeap* _g1h;                              // G1 堆引用
    SubTasksDone _process_strong_tasks;                 // 任务认领管理
    StrongRootsScope _srs;                              // 强根作用域
    OopStorage::ParState<false, false> _par_state_string; // 字符串表并行状态
    
    // 类卸载屏障
    Monitor _lock;
    volatile jint _n_workers_discovered_strong_classes; // 已完成强根扫描的线程数
    
    // 任务枚举（13 种根来源）
    enum G1H_process_roots_tasks {
        G1RP_PS_Universe_oops_do,               // Universe
        G1RP_PS_JNIHandles_oops_do,             // JNI Handles
        G1RP_PS_ObjectSynchronizer_oops_do,     // ObjectSynchronizer
        G1RP_PS_Management_oops_do,             // Management
        G1RP_PS_SystemDictionary_oops_do,       // SystemDictionary
        G1RP_PS_ClassLoaderDataGraph_oops_do,   // CLDG
        G1RP_PS_jvmti_oops_do,                  // JVMTI
        G1RP_PS_CodeCache_oops_do,              // CodeCache
        G1RP_PS_aot_oops_do,                    // AOT
        G1RP_PS_filter_satb_buffers,            // SATB Buffers
        G1RP_PS_refProcessor_oops_do,           // ReferenceProcessor
        G1RP_PS_weakProcessor_oops_do,          // WeakProcessor
        G1RP_PS_NumElements                     // 任务总数
    };
};
```

**对象大小估算**：
```
G1RootProcessor 对象（StackObj，栈上分配）：
  - _g1h: 8 bytes
  - _process_strong_tasks: SubTasksDone 对象（约 32 bytes）
  - _srs: StrongRootsScope 对象（约 16 bytes）
  - _par_state_string: OopStorage::ParState（约 16 bytes）
  - _lock: Monitor 对象（约 64 bytes）
  - _n_workers_discovered_strong_classes: 4 bytes
  - 总计：~140 bytes（栈上分配，GC 结束后自动释放）
```

### 2.2 核心字段详解

#### 2.2.1 `_process_strong_tasks` —— 任务认领管理

**类型**：`SubTasksDone`

**作用**：
- 管理 13 种根来源的处理任务
- 支持多线程并行认领任务（工作窃取）
- 每个任务只能被一个线程执行

**使用方式**：
```cpp
// 尝试认领任务
if (!_process_strong_tasks.is_task_claimed(G1RP_PS_Universe_oops_do)) {
    Universe::oops_do(strong_roots);  // 执行 Universe 根扫描
}

// 等待所有任务完成
_process_strong_tasks.all_tasks_completed(n_workers());
```

**为什么需要任务认领？**
```
场景：8 个 GC 线程，13 个根来源任务

方案 1：固定分配（不均匀）
  线程 0: 任务 0, 1
  线程 1: 任务 2, 3
  ...
  问题：任务 0 (Universe) 很快，任务 6 (CLDG) 很慢，负载不均衡

方案 2：任务认领（动态负载均衡）✅
  所有线程竞争认领任务
  先完成的线程继续认领剩余任务
  优势：自然负载均衡，避免线程空闲
```

#### 2.2.2 `_par_state_string` —— 字符串表并行状态

**类型**：`OopStorage::ParState<false, false>`

**作用**：
- 管理字符串表（StringTable）的并行遍历
- 支持多线程分桶扫描（每个线程处理一部分桶）

**为什么字符串表特殊？**
- 字符串表是一个大哈希表（约 60K 个桶）
- 使用 `OopStorage::ParState` 进行细粒度并行
- 每个线程独立扫描一部分桶，无需锁竞争

#### 2.2.3 类卸载屏障相关字段

```cpp
Monitor _lock;
volatile jint _n_workers_discovered_strong_classes;
```

**作用**（仅在开启类卸载时）：
1. **第一阶段**：所有线程扫描强 CLDs（有活跃类的 CLD）
2. **屏障**：等待所有线程完成强 CLD 扫描
3. **第二阶段**：扫描弱 CLDs（无活跃类的 CLD，可回收）

**流程**：
```
线程 1: 强 CLD 扫描 ──┐
线程 2: 强 CLD 扫描 ──┼──> Barrier: 等待所有线程 ──> 弱 CLD 扫描
线程 3: 强 CLD 扫描 ──┘
```

---

## 三、方法分析：根处理流程详解

### 3.1 主入口：`evacuate_roots()`

**流程图**：
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      evacuate_roots() 流程                                   │
└─────────────────────────────────────────────────────────────────────────────┘

G1ParTask::work()
     │
     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  G1RootProcessor::evacuate_roots(pss, worker_id)                        │
│       │                                                                 │
│       ├──> process_java_roots()                                         │
│       │       ├──> ClassLoaderDataGraph::roots_cld_do()  (强/弱 CLD)   │
│       │       └──> Threads::possibly_parallel_oops_do()  (线程栈)      │
│       │                                                                 │
│       ├──> worker_has_discovered_all_strong_classes()                   │
│       │       └──> 通知：已完成强 CLD 扫描                              │
│       │                                                                 │
│       ├──> process_vm_roots()                                           │
│       │       ├──> Universe::oops_do()                                  │
│       │       ├──> JNIHandles::oops_do()                                │
│       │       ├──> SystemDictionary::oops_do()                          │
│       │       └──> ...                                                  │
│       │                                                                 │
│       ├──> process_string_table_roots()                                 │
│       │       └──> StringTable::possibly_parallel_oops_do()            │
│       │                                                                 │
│       ├──> ReferenceProcessor (并发标记引用)                            │
│       │                                                                 │
│       ├──> wait_until_all_strong_classes_discovered()                   │
│       │       └──> 屏障：等待所有线程完成强 CLD 扫描                      │
│       │                                                                 │
│       ├──> WeakCLDRoots                                                 │
│       │       └──> ClassLoaderDataGraph::roots_cld_do()  (仅弱 CLD)    │
│       │                                                                 │
│       └──> SATBFiltering                                                │
│               └──> 过滤 SATB 缓冲区中的 CSet 引用                        │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

**代码解析**（g1RootProcessor.cpp:79-137）：
```cpp
void G1RootProcessor::evacuate_roots(G1ParScanThreadState* pss, uint worker_i) {
    G1GCPhaseTimes* phase_times = _g1h->g1_policy()->phase_times();
    
    // 1. Java 层面根（CLDG + 线程栈）
    G1EvacuationRootClosures* closures = pss->closures();
    process_java_roots(closures, phase_times, worker_i);
    
    // 2. 通知已完成强 CLD 扫描（类卸载屏障）
    if (closures->trace_metadata()) {
        worker_has_discovered_all_strong_classes();
    }
    
    // 3. JVM 层面根
    process_vm_roots(closures, phase_times, worker_i);
    
    // 4. 字符串表（弱根）
    process_string_table_roots(closures, phase_times, worker_i);
    
    // 5. 引用处理器（并发标记发现的引用）
    if (!_process_strong_tasks.is_task_claimed(G1RP_PS_refProcessor_oops_do)) {
        _g1h->ref_processor_cm()->weak_oops_do(closures->strong_oops());
    }
    
    // 6. 类卸载屏障：等待所有线程完成强 CLD
    if (closures->trace_metadata()) {
        wait_until_all_strong_classes_discovered();
        // 7. 处理弱 CLD
        ClassLoaderDataGraph::roots_cld_do(NULL, closures->second_pass_weak_clds());
    }
    
    // 8. SATB 缓冲区过滤
    if (!_process_strong_tasks.is_task_claimed(G1RP_PS_filter_satb_buffers)) {
        G1BarrierSet::satb_mark_queue_set().filter_thread_buffers();
    }
    
    // 等待所有任务完成
    _process_strong_tasks.all_tasks_completed(n_workers());
}
```

### 3.2 Java 层面根：`process_java_roots()`

**包含两类根**：
1. **ClassLoaderDataGraph (CLDG)**：所有类加载器及其加载的类的静态字段
2. **Threads**：所有 Java 线程的栈帧

**代码解析**（g1RootProcessor.cpp:220-240）：
```cpp
void G1RootProcessor::process_java_roots(G1RootClosures* closures,
                                         G1GCPhaseTimes* phase_times,
                                         uint worker_i) {
    // 1. 类加载器数据图（CLDG）
    {
        G1GCParPhaseTimesTracker x(phase_times, G1GCPhaseTimes::CLDGRoots, worker_i);
        if (!_process_strong_tasks.is_task_claimed(G1RP_PS_ClassLoaderDataGraph_oops_do)) {
            // 同时处理强 CLD 和弱 CLD（如果 trace_metadata 为 true）
            ClassLoaderDataGraph::roots_cld_do(closures->strong_clds(), 
                                               closures->weak_clds());
        }
    }
    
    // 2. 线程栈
    {
        G1GCParPhaseTimesTracker x(phase_times, G1GCPhaseTimes::ThreadRoots, worker_i);
        bool is_par = n_workers() > 1;
        Threads::possibly_parallel_oops_do(is_par,
                                           closures->strong_oops(),
                                           closures->strong_codeblobs());
    }
}
```

**线程栈扫描详解**：
```
Threads::possibly_parallel_oops_do(is_par, oop_closure, code_blob_closure)

对于每个 Java 线程：
  1. 扫描栈帧（Frame）
     - 局部变量表（Local Variables）
     - 操作数栈（Operand Stack）
  
  2. 扫描线程的 monitor
     - 当前线程持有的锁
  
  3. 扫描 ThreadLocal
     - 线程本地存储
  
  4. 扫描 JNI 局部引用
     - JNI 方法中创建的局部引用
```

### 3.3 JVM 层面根：`process_vm_roots()`

**代码解析**（g1RootProcessor.cpp:242-297）：
```cpp
void G1RootProcessor::process_vm_roots(G1RootClosures* closures,
                                       G1GCPhaseTimes* phase_times,
                                       uint worker_i) {
    OopClosure* strong_roots = closures->strong_oops();
    
    // 1. Universe：JVM 内部对象
    if (!_process_strong_tasks.is_task_claimed(G1RP_PS_Universe_oops_do)) {
        Universe::oops_do(strong_roots);
    }
    
    // 2. JNI 全局引用
    if (!_process_strong_tasks.is_task_claimed(G1RP_PS_JNIHandles_oops_do)) {
        JNIHandles::oops_do(strong_roots);
    }
    
    // 3. 同步器（等待 Monitor 的对象）
    if (!_process_strong_tasks.is_task_claimed(G1RP_PS_ObjectSynchronizer_oops_do)) {
        ObjectSynchronizer::oops_do(strong_roots);
    }
    
    // 4. JMX Management
    if (!_process_strong_tasks.is_task_claimed(G1RP_PS_Management_oops_do)) {
        Management::oops_do(strong_roots);
    }
    
    // 5. JVMTI
    if (!_process_strong_tasks.is_task_claimed(G1RP_PS_jvmti_oops_do)) {
        JvmtiExport::oops_do(strong_roots);
    }
    
    // 6. AOT（Ahead-Of-Time 编译）
    if (UseAOT) {
        if (!_process_strong_tasks.is_task_claimed(G1RP_PS_aot_oops_do)) {
            AOTLoader::oops_do(strong_roots);
        }
    }
    
    // 7. SystemDictionary
    if (!_process_strong_tasks.is_task_claimed(G1RP_PS_SystemDictionary_oops_do)) {
        SystemDictionary::oops_do(strong_roots);
    }
}
```

### 3.4 根处理闭包（Closures）

**闭包设计**：
```cpp
// G1RootClosures 接口（g1RootClosures.hpp）
class G1RootClosures {
public:
    virtual OopClosure* weak_oops() = 0;           // 弱根处理
    virtual OopClosure* strong_oops() = 0;         // 强根处理
    virtual CLDClosure* weak_clds() = 0;           // 弱 CLD 处理
    virtual CLDClosure* strong_clds() = 0;         // 强 CLD 处理
    virtual CodeBlobClosure* strong_codeblobs() = 0; // CodeCache 处理
};
```

**Evacuation 闭包**（实际使用）：
```cpp
// G1EvacuationRootClosures（g1RootClosures.cpp）
class G1EvacuationRootClosures : public G1RootClosures {
    G1ParScanThreadState* _pss;
    
public:
    OopClosure* strong_oops() { 
        return _pss->strong_roots_closures();  // 复制到 Survivor/Old
    }
    
    CLDClosure* strong_clds() {
        return _pss->clds_closures();  // 处理 CLD
    }
    
    CodeBlobClosure* strong_codeblobs() {
        return _pss->codeblobs_closures();  // 处理 CodeBlob
    }
    // ... 弱根类似
};
```

---

## 四、关联分析：组件交互图

### 4.1 完整根处理流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      Young GC 根处理完整流程                                │
└─────────────────────────────────────────────────────────────────────────────┘

G1ParTask::work(worker_id)
        │
        ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  1. G1RootProcessor::evacuate_roots()                                   │
│       └── 扫描所有 GC Roots，将存活对象标记并加入扫描队列                │
└─────────────────────────────────────────────────────────────────────────┘
        │
        ├──> 处理强根（保证存活）
        │       ├──> Java Roots
        │       │       ├──> CLDG（类静态字段）
        │       │       └──> Threads（线程栈）
        │       ├──> JVM Roots
        │       │       ├──> Universe
        │       │       ├──> JNIHandles
        │       │       └──> SystemDictionary
        │       └──> CodeCache（nmethod）
        │
        ├──> 处理弱根（类卸载时可能清除）
        │       ├──> StringTable（字符串常量池）
        │       ├──> WeakCLD（无活跃类的 CLD）
        │       └──> ReferenceProcessor（Soft/Weak/Phantom Reference）
        │
        └──> SATB 缓冲区过滤
                └──> 移除指向 CSet 的引用
        │
        ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  2. G1ParEvacuateFollowersClosure::do_void()                           │
│       └── 处理扫描队列，复制存活对象到 Survivor/Old                      │
└─────────────────────────────────────────────────────────────────────────┘
        │
        ├──> 从队列取对象
        ├──> 遍历对象字段
        │       ├──> 引用在 CSet 内？复制并转发
        │       └──> 引用在 CSet 外？记录到 RSet
        └──> 直到队列为空
        │
        ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  3. 根处理完成，继续其他 GC 阶段                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.2 与其他组件的关系

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         G1RootProcessor 组件关系图                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                         G1RootProcessor                                │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │                    evacuate_roots()                              │  │  │
│  │  │                        │                                        │  │  │
│  │  │      ┌─────────────────┼─────────────────┐                     │  │  │
│  │  │      │                 │                 │                     │  │  │
│  │  │      ▼                 ▼                 ▼                     │  │  │
│  │  │ process_java_    process_vm_     process_string_               │  │  │
│  │  │ roots()          roots()         table_roots()                 │  │  │
│  │  │      │                 │                 │                     │  │  │
│  │  │      ▼                 ▼                 ▼                     │  │  │
│  │  │ CLDG/Threads    Universe/JNI/...    StringTable                 │  │  │
│  │  └─────────────────────────────────────────────────────────────────┘  │  │
│  │                              │                                        │  │
│  │  ┌───────────────────────────┼───────────────────────────────┐       │  │
│  │  │                           │                               │       │  │
│  │  │  ┌──────────────────────┐ │ ┌──────────────────────────┐  │       │  │
│  │  │  │ G1EvacuationRoot    │ │ │ G1ParScanThreadState    │  │       │  │
│  │  │  │ Closures            │◄┘ │                         │  │       │  │
│  │  │  │ - strong_oops()     │   │ - strong_roots_closures()│  │       │  │
│  │  │  │ - weak_oops()       │   │ - weak_roots_closures() │  │       │  │
│  │  │  └──────────────────────┘   └──────────────────────────┘  │       │  │
│  │  │                              │                            │       │  │
│  │  │                              ▼                            │       │  │
│  │  │  ┌──────────────────────────────────────────────────────┐ │       │  │
│  │  │  │              G1ParScanThreadState::copy_to_          │ │       │  │
│  │  │  │              survivor_space()                        │ │       │  │
│  │  │  │                                                      │ │       │  │
│  │  │  │  1. 分配 Survivor/Old 空间                           │ │       │  │
│  │  │  │  2. 复制对象                                         │ │       │  │
│  │  │  │  3. 安装转发指针                                     │ │       │  │
│  │  │  │  4. 将引用加入扫描队列                               │ │       │  │
│  │  │  └──────────────────────────────────────────────────────┘ │       │  │
│  │  └───────────────────────────────────────────────────────────┘       │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 五、验证总结：日志与调试

### 5.1 关键日志输出

**启用根处理详细日志**：
```bash
java -Xlog:gc+phases=debug:file=gc-phases.log:time,uptime,level,tags \
     -Xms8g -Xmx8g -XX:+UseG1GC \
     -jar application.jar
```

**典型日志**：
```
# GC Phase 日志
[15.234s][debug][gc,phases] GC(23) Phase Summary:
[15.234s][debug][gc,phases] GC(23)   External Root Scanning: 12.45ms
[15.234s][debug][gc,phases] GC(23)     ClassLoaderDataGraph: 3.21ms
[15.234s][debug][gc,phases] GC(23)     Threads: 5.67ms
[15.234s][debug][gc,phases] GC(23)     Universe: 0.05ms
[15.234s][debug][gc,phases] GC(23)     JNI Handles: 1.23ms
[15.234s][debug][gc,phases] GC(23)     SystemDictionary: 0.89ms
[15.234s][debug][gc,phases] GC(23)     StringTable: 1.40ms
[15.234s][debug][gc,phases] GC(23)   Update RS: 45.23ms
[15.234s][debug][gc,phases] GC(23)   Scan RS: 32.15ms
[15.234s][debug][gc,phases] GC(23)   Code Roots: 5.67ms
[15.234s][debug][gc,phases] GC(23)   Object Copy: 42.29ms
```

### 5.2 监控指标

| 指标 | 查看方法 | 健康范围 |
|-----|---------|---------|
| 根扫描时间 | GC 日志 ExtRootScanning | < 20ms |
| CLDG 扫描时间 | GC 日志 CLDGRoots | < 10ms |
| 线程栈扫描时间 | GC 日志 ThreadRoots | < 15ms |
| 根来源数量 | 代码中枚举 | 13 种 |

---

## 六、总结

### 6.1 G1RootProcessor 的核心价值

G1RootProcessor 是 G1 **根处理的中央调度器**：

1. **统一入口**：提供单一的根处理接口
2. **并行处理**：使用任务认领实现负载均衡
3. **强/弱分离**：支持类卸载场景
4. **细粒度计时**：每种根来源独立计时

### 6.2 关键设计要点

| 设计点 | 说明 |
|-------|------|
| **SubTasksDone** | 任务认领机制，避免锁竞争，实现负载均衡 |
| **强/弱分离** | 强根必须处理，弱根在类卸载时可能跳过 |
| **类卸载屏障** | 两阶段 CLD 处理，确保正确识别死亡类 |
| **OopStorage** | 字符串表的细粒度并行扫描 |

### 6.3 学习路径回顾

```
G1CollectedHeap::initialize() ──> 堆初始化
    ├── HeapRegionManager::initialize() ──> Region 管理
    ├── HeapRegion ──> 单 Region 结构
    ├── G1RemSet ──> 记忆集
    │
    ├── G1Policy ──> GC 决策中心
    │       └── finalize_collection_set()
    │
    ├── G1CollectionSet ──> CSet 管理
    │       └── finalize_young_part() / finalize_old_part()
    │
    └── G1RootProcessor ──> 根处理（当前）
            └── evacuate_roots()
                ├── process_java_roots()
                ├── process_vm_roots()
                └── process_string_table_roots()
```

**根处理层核心已完成！** 接下来建议：
1. **G1ParScanThreadState** - 了解 Evacuation 阶段如何复制对象
2. **G1RootClosures** - 深入了解闭包实现
3. **WorkGang** - GC 工作线程池

---

**文档信息**：
- 分析版本：OpenJDK 11
- 分析日期：2026-02-10
- 源码路径：
  - `/data/workspace/openjdk-cut-new/src/hotspot/share/gc/g1/g1RootProcessor.hpp`
  - `/data/workspace/openjdk-cut-new/src/hotspot/share/gc/g1/g1RootProcessor.cpp`
