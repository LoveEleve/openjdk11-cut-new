# G1RootClosures 与 G1OopClosures 专家级源码分析

> **定位**：G1 GC Roots 处理与对象引用遍历的核心闭包体系  
> **核心问题**：不同类型 Roots 如何处理？对象引用如何复制和更新？  
> **源码路径**：`src/hotspot/share/gc/g1/g1RootClosures.hpp`, `g1OopClosures.hpp`

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

G1RootClosures 的本质是**GC Roots 处理的闭包工厂**：为不同类型的 GC Roots（强引用/弱引用/CLDG/CodeCache）提供对应的 `OopClosure`；每种闭包的 `do_oop()` 方法实现不同的处理逻辑（复制对象/更新引用/标记存活）。

### 0.2 为什么需要？

G1 GC 有多种 GC Roots（线程栈/JNI/静态变量/CodeCache 等），不同类型的 Roots 需要不同的处理逻辑：强引用 Roots 需要复制对象并更新引用，弱引用 Roots 只需检查是否存活，CodeCache 中的引用需要特殊处理（nmethod 的 inline cache）。闭包模式让不同处理逻辑可以复用同一套 Root 扫描框架。

### 0.3 怎么解决？

**闭包工厂模式**：`G1RootClosures` 是一个接口，提供 `strong_oops()`/`weak_oops()`/`strong_codeblobs()` 等方法，返回对应的 `OopClosure`；`G1EvacuationRootClosures` 是 Young GC 的实现，返回 `G1CopyingClosure`（复制对象）；`G1MarkingRootClosures` 是并发标记的实现，返回 `G1MarkingClosure`（标记存活）。

### 0.4 为什么这样设计？

- **为什么用闭包而不是直接在 Root 扫描中处理？** 闭包将"如何处理引用"与"如何遍历 Roots"解耦；Root 扫描框架（`G1RootProcessor`）只负责找到所有 Roots，不关心如何处理；不同 GC 阶段（Young GC/并发标记）可以复用同一套 Root 扫描框架，只需提供不同的闭包
- **为什么强引用和弱引用需要不同的闭包？** 强引用必须复制（对象必须存活），弱引用只需检查（如果对象不存活则清除引用）；不同的语义需要不同的处理逻辑

---

## 1. 一句话总结

**G1RootClosures 定义了 GC Roots 处理的统一接口，G1OopClosures 通过模板化闭包体系实现了"对象引用复制 + RSet 更新 + 并发标记"的多场景复用，是连接 RootProcessor 和 ParScanThreadState 的桥梁。**

---

## 2. 为什么需要闭包体系？

### 2.1 问题背景

在 G1 GC 过程中，需要处理各种来源的对象引用：
- **GC Roots**：线程栈、CLDG、JNI、Code Cache 等
- **堆内对象**：CSet 中对象的引用字段
- **RSet 卡片**：跨 Region 引用

**核心挑战**：
1. **处理方式不同**：Roots 需要复制到 Survivor，RSet 只需更新引用
2. **执行阶段不同**：Young GC、Mixed GC、并发标记阶段行为不同
3. **代码复用需求**：相同逻辑不应重复实现

### 2.2 如果没有闭包体系？

```
❌ 方案1：每个场景独立实现
   ├── RootProcessor::process_roots() 独立逻辑
   ├── Evacuation::scan_object() 独立逻辑
   ├── RSet::scan_card() 独立逻辑
   └── 问题：重复代码，维护困难

❌ 方案2：函数指针回调
   ├── 使用函数指针处理引用
   └── 问题：无法内联，性能损失

✅ 方案3：C++ 闭包体系（实际采用）
   ├── 基类定义接口
   ├── 模板实现代码复用
   ├── 内联保证性能
   └── 多态支持扩展
```

---

## 3. 整体架构与类层次

### 3.1 核心类图

```
G1RootClosures 体系
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

G1RootClosures (接口基类)
├── weak_oops()          # 弱引用 OopClosure
├── strong_oops()        # 强引用 OopClosure
├── weak_clds()          # 弱引用 CLDClosure
├── strong_clds()        # 强引用 CLDClosure
└── strong_codeblobs()   # CodeBlobClosure

G1EvacuationRootClosures (Evacuation 专用)
├── 继承 G1RootClosures
├── second_pass_weak_clds()  # CLD 二阶段处理
├── raw_strong_oops()        # 原始强引用闭包
├── weak_codeblobs()         # 弱 CodeBlob
└── trace_metadata()         # 是否跟踪元数据

G1OopClosures 体系
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

BasicOopIterateClosure (JVM 基类)
└── G1ScanClosureBase (G1 扫描基类)
        ├── G1ScanEvacuatedObjClosure     # 扫描刚复制的对象
        ├── G1ScanObjsDuringScanRSClosure # 扫描 RSet 卡片
        └── G1ScanObjsDuringUpdateRSClosure # Update RS 阶段

OopClosure (JVM 基类)
└── G1ParCopyHelper (复制帮助基类)
        └── G1ParCopyClosure<barrier, do_mark> # 模板化复制闭包
                ├── G1ParCopyClosure<G1BarrierNone, G1MarkNone>
                ├── G1ParCopyClosure<G1BarrierCLD, G1MarkFromRoot>
                └── G1ParCopyClosure<...> (多种组合)
```

### 3.2 闭包类型矩阵

| 闭包类 | 使用阶段 | 核心功能 | 目标区域 |
|--------|----------|----------|----------|
| **G1ParCopyClosure** | Root Processing | 复制对象 + 更新引用 | CSet 外 → Survivor/Old |
| **G1ScanEvacuatedObjClosure** | Evacuation | 扫描新对象引用 | 刚复制的对象 |
| **G1ScanObjsDuringScanRSClosure** | Scan RS | 扫描 RSet 引用 | 跨 Region 引用 |
| **G1ScanObjsDuringUpdateRSClosure** | Update RS | 更新 RSet | 脏卡队列处理 |
| **G1CMOopClosure** | Concurrent Mark | 标记对象 | 并发标记 |
| **G1RootRegionScanClosure** | Root Region Scan | 标记根区域 | 并发标记初始化 |

---

## 4. G1RootClosures 详解

### 4.1 接口定义

```cpp
class G1RootClosures : public CHeapObj<mtGC> {
public:
    // Oop 闭包：处理对象引用
    virtual OopClosure* weak_oops() = 0;      // 弱引用（如 JNI 弱全局引用）
    virtual OopClosure* strong_oops() = 0;    // 强引用
    
    // CLD 闭包：处理 ClassLoaderData
    virtual CLDClosure* weak_clds() = 0;      // 弱 CLD
    virtual CLDClosure* strong_clds() = 0;    // 强 CLD
    
    // CodeBlob 闭包：处理 Code Cache
    virtual CodeBlobClosure* strong_codeblobs() = 0;
};

class G1EvacuationRootClosures : public G1RootClosures {
public:
    // CLD 二阶段处理：先处理强 CLD，再处理弱 CLD
    virtual CLDClosure* second_pass_weak_clds() = 0;
    
    // 原始强引用闭包：绕过某些检查，用于内部处理
    virtual OopClosure* raw_strong_oops() = 0;
    
    // 弱 CodeBlob（如某些优化后的代码）
    virtual CodeBlobClosure* weak_codeblobs() = 0;
    
    // 是否跟踪元数据（决定 CLD 处理细节）
    virtual bool trace_metadata() = 0;
    
    // 工厂方法：创建具体实现
    static G1EvacuationRootClosures* create_root_closures(
        G1ParScanThreadState* pss, 
        G1CollectedHeap* g1h);
};
```

### 4.2 为什么需要强弱分离？

```
强弱引用处理差异
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

强引用（Strong Roots）
├── 来源：线程栈、CLDG 强引用、JNI 强全局引用
├── 处理：必须复制到 Survivor/Old
└── 优先级：高（直接影响存活对象）

弱引用（Weak Roots）
├── 来源：JNI 弱全局引用、某些 CodeBlob
├── 处理：仅复制可达对象
└── 优先级：低（可被回收）

分离优势：
  1. 优先级控制：强引用先处理
  2. 性能优化：弱引用可延迟处理
  3. 正确性：避免提前回收强引用对象
```

### 4.3 CLD 二阶段处理

```cpp
// G1CLDScanClosure 处理 CLDG
class G1CLDScanClosure : public CLDClosure {
    G1ParCopyHelper* _closure;
    bool _process_only_dirty;  // 只处理 dirty CLD
    bool _must_claim;          // 是否需要认领
    
public:
    void do_cld(ClassLoaderData* cld) {
        // 1. 如果需要认领，检查是否已被其他线程处理
        if (_must_claim && !cld->claim()) {
            return;
        }
        
        // 2. 只处理 dirty CLD（优化）
        if (_process_only_dirty && !cld->has_modified_oops()) {
            return;
        }
        
        // 3. 处理 CLD 的所有 oops
        cld->oops_do(_closure, _must_claim);
        
        // 4. 清除 modified 标记
        cld->clear_modified_oops();
    }
};
```

**二阶段处理的意义**：

```
CLD 处理时序
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

阶段 1：处理强 CLD
  ├── 保证类加载器存活
  ├── 处理类元数据引用
  └── 优先级高

阶段 2：处理弱 CLD
  ├── 只处理可达的
  ├── 可能被回收的跳过
  └── 优先级低

优化效果：
  - 避免重复扫描未修改的 CLD
  - 减少并发冲突
  - 提高并行度
```

---

## 5. G1OopClosures 详解

### 5.1 G1ScanClosureBase - 扫描基类

```cpp
class G1ScanClosureBase : public BasicOopIterateClosure {
protected:
    G1CollectedHeap* _g1h;
    G1ParScanThreadState* _par_scan_state;
    HeapRegion* _from;  // 来源 Region
    
    // 核心方法：预取并 Push 到队列
    template <class T>
    inline void prefetch_and_push(T* p, oop const obj);
    
    // 处理非 CSet 对象（如 Humongous 对象）
    template <class T>
    inline void handle_non_cset_obj_common(InCSetState const state, 
                                           T* p, 
                                           oop const obj);
public:
    // 引用迭代模式：处理 discovered 引用
    virtual ReferenceIterationMode reference_iteration_mode() {
        return DO_DISCOVERED_AND_DISCOVERY;
    }
    
    void set_region(HeapRegion* from) { _from = from; }
    inline void trim_queue_partially();
};
```

### 5.2 G1ScanEvacuatedObjClosure - 扫描新对象

```cpp
class G1ScanEvacuatedObjClosure : public G1ScanClosureBase {
public:
    template <class T> void do_oop_work(T* p) {
        T heap_oop = RawAccess<>::oop_load(p);
        if (CompressedOops::is_null(heap_oop)) return;
        
        oop obj = CompressedOops::decode_not_null(heap_oop);
        const InCSetState state = _g1h->in_cset_state(obj);
        
        if (state.is_in_cset()) {
            // 对象还在 CSet 中，需要复制
            // 1. 预取对象 Mark Word
            // 2. Push 到队列，后续处理
            prefetch_and_push(p, obj);
        } else {
            // 对象不在 CSet 中
            if (HeapRegion::is_in_same_region(p, obj)) return;
            
            // 跨 Region 引用，更新 RSet
            handle_non_cset_obj_common(state, p, obj);
            _par_scan_state->update_rs(_from, p, obj);
        }
    }
};
```

**使用场景**：

```
何时使用 G1ScanEvacuatedObjClosure？
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

触发时机：
  copy_to_survivor_space() 复制完对象后
  
调用链：
  obj->oop_iterate_backwards(&_scanner)
    └── G1ScanEvacuatedObjClosure::do_oop()
        └── do_oop_work()

处理内容：
  1. 扫描新复制对象的每个引用字段
  2. 如果引用指向 CSet 中的对象 → Push 到队列
  3. 如果引用指向其他 Region → 更新 RSet
  4. 递归处理对象图
```

### 5.3 G1ParCopyClosure - 模板化复制闭包

```cpp
// 屏障类型枚举
enum G1Barrier {
    G1BarrierNone,    // 无屏障
    G1BarrierCLD      // CLD 屏障
};

// 标记类型枚举
enum G1Mark {
    G1MarkNone,           // 不标记
    G1MarkFromRoot,       // 从 Root 标记（初始标记）
    G1MarkPromotedFromRoot // 晋升对象标记
};

// 模板化闭包
template <G1Barrier barrier, G1Mark do_mark_object>
class G1ParCopyClosure : public G1ParCopyHelper {
public:
    template <class T> void do_oop_work(T* p) {
        T heap_oop = RawAccess<>::oop_load(p);
        if (CompressedOops::is_null(heap_oop)) return;
        
        oop obj = CompressedOops::decode_not_null(heap_oop);
        const InCSetState state = _g1h->in_cset_state(obj);
        
        if (state.is_in_cset()) {
            // 需要复制的对象
            markOop m = obj->mark_raw();
            oop forwardee;
            
            if (m->is_marked()) {
                // 已被其他线程复制
                forwardee = (oop) m->decode_pointer();
            } else {
                // 执行复制
                forwardee = _par_scan_state->copy_to_survivor_space(state, obj, m);
            }
            
            // 更新引用
            RawAccess<IS_NOT_NULL>::oop_store(p, forwardee);
            
            // 如果需要标记（初始标记阶段）
            if (do_mark_object != G1MarkNone && forwardee != obj) {
                mark_forwarded_object(obj, forwardee);
            }
            
            // CLD 屏障
            if (barrier == G1BarrierCLD) {
                do_cld_barrier(forwardee);
            }
        } else {
            // 非 CSet 对象
            if (state.is_humongous()) {
                _g1h->set_humongous_is_live(obj);
            }
            
            // 从 Root 标记（并发标记）
            if (do_mark_object == G1MarkFromRoot) {
                mark_object(obj);
            }
        }
        
        // 部分处理队列（避免队列过长）
        trim_queue_partially();
    }
};
```

**模板实例化组合**：

```cpp
// 常见闭包类型定义
typedef G1ParCopyClosure<G1BarrierNone, G1MarkNone> 
    G1ParScanExtRootClosure;           // 普通 Root 扫描

typedef G1ParCopyClosure<G1BarrierCLD, G1MarkFromRoot> 
    G1ParScanMetadataClosure;          // 元数据扫描（带 CLD 屏障）

typedef G1ParCopyClosure<G1BarrierNone, G1MarkFromRoot>
    G1ParScanAndMarkRootClosure;       // Root 扫描 + 标记
```

### 5.4 预取优化

```cpp
template <class T>
inline void G1ScanClosureBase::prefetch_and_push(T* p, oop const obj) {
    // 预取 Mark Word（用于写入转发指针）
    Prefetch::write(obj->mark_addr_raw(), 0);
    
    // 预读 Mark Word 数据（用于后续检查）
    Prefetch::read(obj->mark_addr_raw(), HeapWordSize * 2);
    
    // Push 到队列
    _par_scan_state->push_on_queue(p);
}
```

**预取策略**：

```
预取时机和距离
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

时间局部性：
  - 预取 Mark Word：0 偏移（即将访问）
  - 预读数据：2 个 HeapWord 后（后续检查）

空间局部性：
  - 对象头部和 Mark Word 相邻
  - 预取减少缓存未命中

效果：
  - 在对象被处理前，数据已在缓存
  - 减少内存访问延迟
  - 提高吞吐量（约 5-10%）
```

---

## 6. 闭包在 GC 流程中的使用

### 6.1 Root Processing 阶段

```cpp
void G1RootProcessor::process_roots(...) {
    // 1. 创建闭包
    G1EvacuationRootClosures* closures = 
        G1EvacuationRootClosures::create_root_closures(pss, _g1h);
    
    // 2. 处理线程栈（强引用）
    process_java_roots(closures->strong_oops(), ...);
    
    // 3. 处理 CLDG（强引用）
    process_cldg_roots(closures->strong_clds(), ...);
    
    // 4. 处理 JNI（强引用）
    process_jni_roots(closures->strong_oops(), ...);
    
    // 5. 处理 Code Cache（强引用）
    process_code_cache_roots(closures->strong_codeblobs(), ...);
    
    // 6. 二阶段处理弱 CLD
    process_cldg_roots(closures->second_pass_weak_clds(), ...);
}
```

### 6.2 Evacuation 阶段

```cpp
void G1ParEvacuateFollowersClosure::do_void() {
    G1ParScanThreadState* pss = par_scan_state();
    
    // 使用 G1ScanEvacuatedObjClosure 扫描新对象
    // 这个闭包在 copy_to_survivor_space 中被调用
    
    pss->trim_queue();
    do {
        pss->steal_and_trim_queue(queues());
    } while (!offer_termination());
}
```

### 6.3 并发标记阶段

```cpp
// 根区域扫描（Young GC 后）
class G1RootRegionScanClosure : public MetadataVisitingOopIterateClosure {
    template <class T> void do_oop_work(T* p) {
        T heap_oop = RawAccess<MO_VOLATILE>::oop_load(p);
        if (CompressedOops::is_null(heap_oop)) return;
        
        oop obj = CompressedOops::decode_not_null(heap_oop);
        // 标记到 Next Bitmap
        _cm->mark_in_next_bitmap(_worker_id, obj);
    }
};

// 并发标记主闭包
class G1CMOopClosure : public MetadataVisitingOopIterateClosure {
    template <class T> void do_oop_work(T* p) {
        _task->deal_with_reference(p);
    }
};
```

---

## 7. 性能优化分析

### 7.1 模板化的优势

```cpp
// 编译期确定，可内联
template <G1Barrier barrier, G1Mark do_mark_object>
class G1ParCopyClosure { ... }

// 对比虚函数方案
class VirtualOopClosure {
    virtual void do_oop(oop* p) = 0;  // 虚函数，运行时决议
};
```

| 特性 | 模板 | 虚函数 |
|------|------|--------|
| 解析时机 | 编译期 | 运行期 |
| 内联 | 是 | 否 |
| 代码膨胀 | 多份实例 | 单份代码 |
| 运行时开销 | 无 | 虚表查找 (~3-5ns) |

**G1 的选择**：
- 使用模板（barrier 和 do_mark 组合有限）
- 牺牲代码大小换取运行时性能

### 7.2 批量处理优化

```cpp
// trim_queue_partially 阈值控制
inline void G1ParCopyClosure::do_oop_work(T* p) {
    // ... 处理逻辑 ...
    
    // 部分处理队列，避免队列过长
    trim_queue_partially();
}
```

**为什么部分处理？**

```
队列长度控制
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

问题：
  扫描大对象时，可能生成大量新任务
  队列过长导致：
    1. 内存占用增加
    2. Stealing 效率下降
    3. 缓存失效

解决：
  每处理 N 个引用，检查并处理队列
  N = _stack_trim_upper_threshold（默认 100）

效果：
  队列长度稳定在阈值以下
  平衡处理速度和内存占用
```

---

## 8. 常见问题与面试题

### Q1: G1RootClosures 和 G1OopClosures 的区别是什么？

**答案**：
- **G1RootClosures**：接口定义类，提供获取各种闭包的方法，用于 RootProcessor
- **G1OopClosures**：具体实现类，定义对象引用处理的逻辑，用于实际扫描

### Q2: 为什么 G1ParCopyClosure 使用模板而不是虚函数？

**答案**：
1. **性能**：模板编译期确定，可内联；虚函数有运行时开销
2. **组合有限**：barrier × mark 组合数量固定（2×3=6种）
3. **代码复用**：相同模板代码复用，减少重复实现

### Q3: CLD 为什么要二阶段处理？

**答案**：
1. **优先级**：强 CLD 保证类加载器存活，先处理
2. **优化**：弱 CLD 可能已被回收，延迟处理减少无效工作
3. **并发安全**：分阶段减少线程竞争

### Q4: prefetch_and_push 为什么预取 Mark Word？

**答案**：
1. **即将访问**：后续需要检查/设置转发指针
2. **缓存友好**：提前加载到 CPU 缓存
3. **性能提升**：减少内存访问延迟，提高吞吐量

---

## 9. 总结

### 9.1 核心设计要点

```
G1 闭包体系设计精髓
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. 分层架构
   ├── G1RootClosures：接口定义，统一获取方式
   ├── G1OopClosures：具体实现，处理逻辑封装
   └── 模板化：编译期优化，运行时高效

2. 职责分离
   ├── Root 处理：复制对象 + 更新引用
   ├── 对象扫描：递归处理引用图
   ├── RSet 更新：维护跨 Region 引用
   └── 并发标记：标记存活对象

3. 性能优化
   ├── 预取：减少缓存未命中
   ├── 批量处理：控制队列长度
   ├── 模板内联：消除虚函数开销
   └── 部分 trim：平衡速度和内存

4. 扩展性
   ├── 新阶段只需新增闭包子类
   ├── 模板参数组合覆盖多种场景
   └── 基类提供公共功能复用
```

---

## 参考文档

1. OpenJDK 11: `src/hotspot/share/gc/g1/g1RootClosures.hpp`
2. OpenJDK 11: `src/hotspot/share/gc/g1/g1OopClosures.hpp`
3. OpenJDK 11: `src/hotspot/share/gc/g1/g1OopClosures.inline.hpp`
4. OpenJDK 11: `src/hotspot/share/gc/g1/g1OopClosures.cpp`

---

**文档信息**
- 创建时间: 2026-02-10
- 源码版本: OpenJDK 11
- 分析类型: 专家级源码分析
- 配套技能: Read-BottomUp, JVM-Optimization-Design
