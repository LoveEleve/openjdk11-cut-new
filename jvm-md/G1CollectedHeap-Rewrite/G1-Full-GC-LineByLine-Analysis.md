# G1 Full GC 逐行深度源码分析

> **分析目标**: G1 Full GC（降级Full GC）完整执行流程  
> **源码文件**: 
> - `src/hotspot/share/gc/g1/g1CollectedHeap.cpp` (Lines 1132-1200+)
> - `src/hotspot/share/gc/g1/g1FullCollector.cpp/hpp`  
> **分析标准**: 面试级深度 - 逐行解释 + 面试问答 + GDB调试技巧

---

## 第1章: Full GC触发条件与入口

### 1.1 Full GC触发场景

**Full GC触发条件（按频率排序）：**

| 触发条件 | 说明 | 日志标识 |
|----------|------|----------|
| **分配失败** | Young GC和Mixed GC后仍无法分配 | (Allocation Failure) |
| **巨型对象分配失败** | Humongous对象分配失败 | (G1 Humongous Allocation) |
| **System.gc()** | 显式调用System.gc() | (System.gc()) |
| **元空间不足** | Metaspace OOM | (Metadata GC Threshold) |
| **晋升失败** | Survivor和Old都无法容纳晋升对象 | (Promotion Failed) |

**Full GC与Young/Mixed GC的区别：**
```
+------------------------------------------------------------------+
|                    Full GC vs Young/Mixed GC                      |
+------------------------------------------------------------------+
|                                                                   |
|  Young/Mixed GC：                                                  |
|  ├─ 部分回收（只回收CSet中的Region）                                │
|  ├─ 并发执行（标记阶段）                                            │
|  ├─ 复制算法（对象移动）                                            │
|  └─ 暂停时间短（通常<200ms）                                        │
|                                                                   |
|  Full GC：                                                         │
|  ├─ 全堆回收（所有Region）                                          │
|  ├─ 完全STW（无并发阶段）                                           │
|  ├─ 标记-整理算法（对象压缩）                                        │
|  └─ 暂停时间长（可能数秒）                                           │
|                                                                   |
|  为什么Full GC慢？                                                  │
|  1. 扫描整个堆（所有对象）                                           │
|  2. 计算对象新位置（压缩）                                           │
|  3. 更新所有引用（指针调整）                                          │
|  4. 移动所有存活对象                                                  │
+------------------------------------------------------------------+
```

---

### 1.2 do_full_collection - Full GC入口

```cpp
1132: bool G1CollectedHeap::do_full_collection(bool explicit_gc,
1133:                                          bool clear_all_soft_refs) {
1134:     assert_at_safepoint_on_vm_thread();
1135:
1136:     if (GCLocker::check_active_before_gc()) {
1137:         // Full GC was not completed.
1138:         return false;
1139:     }
1140:
1141:     const bool do_clear_all_soft_refs = clear_all_soft_refs ||
1142:                                         soft_ref_policy()->should_clear_all_soft_refs();
1143:
1144:     G1FullCollector collector(this, &_full_gc_memory_manager, explicit_gc, do_clear_all_soft_refs);
1145:     GCTraceTime(Info, gc) tm("Pause Full", NULL, gc_cause(), true);
1146:
1147:     collector.prepare_collection();
1148:     collector.collect();
1149:     collector.complete_collection();
1150:
1151:     // Full collection was successfully completed.
1152:     return true;
1153: }
```

**Line 1132-1153: Full GC入口深度解析**

**Line 1134: assert_at_safepoint_on_vm_thread()**
```cpp
// Full GC必须在Safepoint中执行，由VMThread调用
// 确保所有Java线程已停止
```

**Line 1136-1139: GCLocker检查**
```cpp
if (GCLocker::check_active_before_gc()) {
    return false;  // JNI临界区激活，无法执行GC
}
```

**Line 1141-1142: Soft Reference处理策略**
```cpp
const bool do_clear_all_soft_refs = clear_all_soft_refs ||
                                    soft_ref_policy()->should_clear_all_soft_refs();

// 何时清除所有Soft Reference？
// 1. 调用者明确要求（clear_all_soft_refs = true）
// 2. 内存严重不足（soft_ref_policy判断）
```

**Line 1144: G1FullCollector创建**
```cpp
G1FullCollector collector(this, &_full_gc_memory_manager, explicit_gc, do_clear_all_soft_refs);

// G1FullCollector是Full GC的核心控制器
// 采用4阶段标记-整理算法
```

**Line 1147-1149: Full GC三阶段**
```cpp
collector.prepare_collection();   // 准备阶段
collector.collect();              // 执行4阶段GC
collector.complete_collection();  // 完成清理
```

---

## 第2章: G1FullCollector类结构与4阶段算法

### 2.1 G1FullCollector类定义

```cpp
56: class G1FullCollector : StackObj {
57:   G1CollectedHeap*          _heap;
58:   G1FullGCScope             _scope;
59:   uint                      _num_workers;
60:   G1FullGCMarker**          _markers;
61:   G1FullGCCompactionPoint** _compaction_points;
62:   OopQueueSet               _oop_queue_set;
63:   ObjArrayTaskQueueSet      _array_queue_set;
64:   PreservedMarksSet         _preserved_marks_set;
65:   G1FullGCCompactionPoint   _serial_compaction_point;
66:   G1IsAliveClosure          _is_alive;
67:   ReferenceProcessorIsAliveMutator _is_alive_mutator;
```

**核心组件解析：**

| 组件 | 类型 | 作用 |
|------|------|------|
| `_markers` | G1FullGCMarker*[] | 每个工作线程的标记器 |
| `_compaction_points` | G1FullGCCompactionPoint*[] | 每个线程的压缩点 |
| `_oop_queue_set` | OopQueueSet | 标记队列（灰色对象） |
| `_array_queue_set` | ObjArrayTaskQueueSet | 大对象数组处理队列 |
| `_preserved_marks_set` | PreservedMarksSet | 保存的Mark Word |
| `_is_alive` | G1IsAliveClosure | 存活对象判断闭包 |

### 2.2 4阶段标记-整理算法

```cpp
167: void G1FullCollector::collect() {
168:   phase1_mark_live_objects();      // 阶段1: 标记存活对象
169:   verify_after_marking();
170:
171:   deactivate_derived_pointers();
172:
173:   phase2_prepare_compaction();     // 阶段2: 准备压缩
174:
175:   phase3_adjust_pointers();        // 阶段3: 调整指针
176:
177:   phase4_do_compaction();          // 阶段4: 执行压缩
178: }
```

**4阶段算法流程图：**
```
+==================================================================+
|              G1 Full GC 4阶段标记-整理算法                         |
+==================================================================+
|                                                                   |
|  阶段1: Mark Live Objects (标记存活对象)                           │
|  ├─ 从GC Roots开始遍历对象图                                        │
|  ├─ 标记所有可达对象                                                │
|  ├─ 处理引用（Soft/Weak/Phantom）                                   │
|  └─ 输出: 位图标记存活对象                                          │
|                                                                   |
|  阶段2: Prepare for Compaction (准备压缩)                          │
|  ├─ 计算每个存活对象的新地址                                        │
|  ├─ 按Region统计存活数据量                                          │
|  ├─ 决定哪些Region需要压缩                                          │
|  └─ 输出: 对象新地址映射表                                          │
|                                                                   |
|  阶段3: Adjust Pointers (调整指针)                                 │
|  ├─ 遍历所有对象引用字段                                            │
|  ├─ 将引用指向对象的新地址                                          │
|  ├─ 更新GC Roots中的引用                                            │
|  └─ 输出: 所有引用更新为新地址                                       │
|                                                                   |
|  阶段4: Do Compaction (执行压缩)                                   │
|  ├─ 按计算的新地址移动对象                                          │
|  ├─ 清理空闲Region                                                  │
|  ├─ 更新堆元数据                                                    │
|  └─ 输出: 内存压缩完成，碎片消除                                     │
|                                                                   |
+==================================================================+
```

**面试高频问题Q&A：**

**Q1: 为什么Full GC需要4个阶段？不能简化吗？**
```
A: 4阶段是标记-整理算法的标准流程，每个阶段都有明确职责：

为什么不能合并？

阶段1和阶段2不能合并：
- 阶段1只关心"哪些对象存活"
- 阶段2需要知道"所有存活对象的总大小"才能计算新地址
- 必须先完成全部标记，才能计算压缩布局

阶段2和阶段3不能合并：
- 阶段2计算新地址时，对象还在原位置
- 阶段3需要遍历对象引用，此时对象未移动
- 如果边移动边调整指针，会访问到不一致的状态

阶段3和阶段4不能合并：
- 阶段3需要遍历所有引用（包括被移动对象的引用）
- 如果先移动对象，可能覆盖其他未处理对象
- 必须等所有指针调整完，才能安全移动

类比：搬家
1. 标记：决定哪些家具要带走
2. 规划：计算每件家具在新家放哪
3. 通知：告诉所有人家具新位置
4. 搬运：实际搬家具
```

---

## 第3章: 阶段1 - 标记存活对象 (Lines 203-234)

### 3.1 phase1_mark_live_objects

```cpp
203: void G1FullCollector::phase1_mark_live_objects() {
204:   GCTraceTime(Info, gc, phases) info("Phase 1: Mark live objects", scope()->timer());
205:
206:   // Do the actual marking.
207:   G1FullGCMarkTask marking_task(this);
208:   run_task(&marking_task);
209:
210:   // Process references discovered during marking.
211:   G1FullGCReferenceProcessingExecutor reference_processing(this);
212:   reference_processing.execute(scope()->timer(), scope()->tracer());
213:
214:   // Weak oops cleanup.
215:   {
216:     GCTraceTime(Debug, gc, phases) trace("Phase 1: Weak Processing", scope()->timer());
217:     WeakProcessor::weak_oops_do(&_is_alive, &do_nothing_cl);
218:   }
219:
220:   // Class unloading and cleanup.
221:   if (ClassUnloading) {
222:     GCTraceTime(Debug, gc, phases) debug("Phase 1: Class Unloading and Cleanup", scope()->timer());
223:     bool purged_class = SystemDictionary::do_unloading(scope()->timer());
224:     _heap->complete_cleaning(&_is_alive, purged_class);
225:   }
226:
227:   scope()->tracer()->report_object_count_after_gc(&_is_alive);
228: }
```

**Line 203-228: 标记阶段深度解析**

**步骤1: 并行标记 (Lines 207-208)**
```cpp
G1FullGCMarkTask marking_task(this);
run_task(&marking_task);

// 多线程并行从GC Roots开始标记
// 使用位图记录存活对象
```

**步骤2: 引用处理 (Lines 211-212)**
```cpp
G1FullGCReferenceProcessingExecutor reference_processing(this);
reference_processing.execute(...);

// 处理Soft/Weak/Phantom/Final引用
// 决定哪些引用对象需要清除
```

**步骤3: 弱引用清理 (Lines 217)**
```cpp
WeakProcessor::weak_oops_do(&_is_alive, &do_nothing_cl);

// 清理JNI弱引用、JFR弱引用等
// 只保留存活对象相关的弱引用
```

**步骤4: 类卸载 (Lines 221-225)**
```cpp
if (ClassUnloading) {
    SystemDictionary::do_unloading(scope()->timer());
    _heap->complete_cleaning(&_is_alive, purged_class);
}

// 卸载无用的类
// 清理ClassLoaderData
// 释放Metaspace内存
```

### 3.2 G1FullGCMarkTask - 并行标记任务

```cpp
class G1FullGCMarkTask : public G1FullGCTask {
public:
  void work(uint worker_id) {
    // 1. 处理GC Roots
    G1FullGCMarker* marker = collector()->marker(worker_id);
    marker->mark_from_roots();
    
    // 2. 处理标记栈（灰色对象）
    marker->drain_stack();
    
    // 3. 完成标记
    marker->complete_marking();
  }
};
```

**标记算法：**
```
+------------------------------------------------------------------+
|                    并行标记算法                                   |
+------------------------------------------------------------------+
|                                                                   |
|  每个工作线程：                                                    │
|  1. 获取一组GC Roots（线程栈、全局变量等）                          │
|  2. 将Roots标记为灰色，加入标记栈                                   │
|  3. while (标记栈不为空) {                                         │
|       obj = 标记栈.pop()                                           │
|       for (obj的每个引用字段) {                                    │
|           if (引用对象未标记) {                                    │
|               标记对象                                             │
|               标记栈.push(对象)                                    │
|           }                                                        │
|       }                                                            │
|     }                                                              │
|  4. 标记完成                                                       │
|                                                                   |
|  工作窃取：                                                        │
|  - 如果自己的标记栈为空                                           │
|  - 从其他线程的标记栈窃取任务                                      │
|  - 确保负载均衡                                                    │
+------------------------------------------------------------------+
```

---

## 第4章: 阶段2 - 准备压缩 (Lines 236-245)

### 4.1 phase2_prepare_compaction

```cpp
236: void G1FullCollector::phase2_prepare_compaction() {
237:   GCTraceTime(Info, gc, phases) info("Phase 2: Prepare for compaction", scope()->timer());
238:   G1FullGCPrepareTask task(this);
239:   run_task(&task);
240:
241:   // To avoid OOM when there is memory left.
242:   if (!task.has_freed_regions()) {
243:     task.prepare_serial_compaction();
244:   }
245: }
```

**Line 236-245: 准备压缩阶段**

**核心任务：**
```
+------------------------------------------------------------------+
|                    准备压缩阶段任务                               |
+------------------------------------------------------------------+
|                                                                   |
|  1. 遍历所有Region                                                 │
|     ├─ 统计每个Region的存活对象大小                                │
|     ├─ 标记死亡对象（用于后续清理）                                │
|     └─ 计算Region的压缩目标                                        │
|                                                                   |
|  2. 计算对象新地址                                                 │
|     ├─ 按Region顺序分配新空间                                      │
|     ├─ 紧凑排列存活对象                                            │
|     └─ 记录每个对象的新地址                                        │
|                                                                   |
|  3. 处理特殊情况                                                   │
|     ├─ 如果Region全是垃圾，直接回收                                │
|     ├─ 如果存活对象很少，合并到相邻Region                          │
|     └─ 如果无法并行压缩，准备串行回退                              │
|                                                                   |
+------------------------------------------------------------------+
```

---

## 第5章: 阶段3和4 - 调整指针与压缩 (Lines 247-278)

### 5.1 phase3_adjust_pointers

```cpp
247: void G1FullCollector::phase3_adjust_pointers() {
248:   GCTraceTime(Info, gc, phases) info("Phase 3: Adjust pointers", scope()->timer());
249:   G1FullGCAdjustTask task(this);
250:   run_task(&task);
251: }
```

**指针调整：**
```
+------------------------------------------------------------------+
|                    指针调整阶段                                   |
+------------------------------------------------------------------+
|                                                                   |
|  遍历所有存活对象的引用字段：                                       │
|  ┌─────────────────────────────────────────────────────────┐     │
|  │  对象A（原地址0x1000，新地址0x5000）                       │     │
|  │  ├─ 引用字段1 -> 对象B（原0x2000，新0x6000）              │     │
|  │  │   调整为：引用字段1 = 0x6000                           │     │
|  │  │                                                       │     │
|  │  └─ 引用字段2 -> 对象C（原0x3000，新0x7000）              │     │
|  │      调整为：引用字段2 = 0x7000                           │     │
|  └─────────────────────────────────────────────────────────┘     │
|                                                                   |
|  需要更新的引用来源：                                              │
|  1. 对象引用字段（遍历所有存活对象）                                │
|  2. GC Roots（线程栈、全局变量等）                                  │
|  3. 元数据中的引用（Klass、CodeCache等）                           │
+------------------------------------------------------------------+
```

### 5.2 phase4_do_compaction

```cpp
254: void G1FullCollector::phase4_do_compaction() {
255:   GCTraceTime(Info, gc, phases) info("Phase 4: Compact heap", scope()->timer());
256:
257:   G1FullGCCompactTask task(this);
258:   run_task(&task);
259: }
```

**压缩执行：**
```
+------------------------------------------------------------------+
|                    压缩执行阶段                                   |
+------------------------------------------------------------------+
|                                                                   |
|  1. 按Region顺序处理                                               │
|                                                                   |
|  2. 对每个Region中的存活对象：                                     │
|     ├─ 读取对象当前地址                                            │
|     ├─ 查询对象新地址（阶段2计算）                                  │
|     ├─ 复制对象数据到新地址                                        │
|     └─ 更新Region的top指针                                         │
|                                                                   |
|  3. 清理完全空闲的Region                                           │
|     ├─ 加入空闲列表                                                │
|     ├─ 清除元数据                                                  │
|     └─ 可用于后续分配                                              │
|                                                                   |
|  4. 更新堆统计信息                                                 │
|     ├─ 已使用空间                                                  │
|     ├─ 空闲空间                                                    │
|     └─ Region状态                                                  │
+------------------------------------------------------------------+
```

---

## 第6章: Full GC完成与堆调整

### 6.1 complete_collection

```cpp
181: void G1FullCollector::complete_collection() {
182:   restore_marks();
183:   update_derived_pointers();
184:   BiasedLocking::restore_marks();
185:   CodeCache::gc_epilogue();
186:   JvmtiExport::gc_epilogue();
187:
188:   _heap->prepare_heap_for_mutators();
189:   _heap->g1_policy()->record_full_collection_end();
190:   _heap->gc_epilogue(true);
191:
192:   _heap->verify_after_full_collection();
193:   _heap->print_heap_after_full_collection(scope()->heap_transition());
194: }
```

**恢复操作：**
```
+------------------------------------------------------------------+
|                    Full GC完成恢复操作                            |
+------------------------------------------------------------------+
|                                                                   |
|  restore_marks()：                                                 │
|  - 恢复对象的Mark Word（hashcode、锁状态等）                        │
|                                                                   |
|  update_derived_pointers()：                                       │
|  - 更新派生指针（如C2编译的oop+offset）                            │
|                                                                   |
|  BiasedLocking::restore_marks()：                                  │
|  - 恢复偏向锁状态                                                  │
|                                                                   |
|  CodeCache::gc_epilogue()：                                        │
|  - 清理Code Cache中的无效nmethod                                   │
|                                                                   |
|  prepare_heap_for_mutators()：                                     │
|  - 恢复堆为可分配状态                                              │
|  - 重置TLAB、卡表等                                                │
+------------------------------------------------------------------+
```

### 6.2 堆大小调整

```cpp
1163: void G1CollectedHeap::resize_if_necessary_after_full_collection() {
1164:   const size_t capacity_after_gc = capacity();
1165:   const size_t used_after_gc = capacity_after_gc - unused_committed_regions_in_bytes();
1166:
1167:   // 根据MinHeapFreeRatio/MaxHeapFreeRatio调整堆大小
1168:   const double minimum_free_percentage = (double) MinHeapFreeRatio / 100.0;
1169:   const double maximum_used_percentage = 1.0 - minimum_free_percentage;
1170:
1171:   // 计算期望的堆大小
1172:   double used_after_gc_d = (double) used_after_gc;
1173:   double minimum_desired_capacity_d = used_after_gc_d / maximum_used_percentage;
1174:
1175:   // 扩展或收缩堆
1176:   if (capacity_after_gc < minimum_desired_capacity_d) {
1177:       // 扩展堆
1178:   } else if (capacity_after_gc > maximum_desired_capacity_d) {
1179:       // 收缩堆
1180:   }
1181: }
```

**堆调整参数：**
```
-XX:MinHeapFreeRatio=40（默认）
-XX:MaxHeapFreeRatio=70（默认）

含义：
- 空闲空间 < 40%：扩展堆
- 空闲空间 > 70%：收缩堆
- 在40%-70%之间：保持不变

目的：
- 避免堆内存浪费
- 及时将内存返还给OS
```

---

## Full GC完整流程总结

```
+==================================================================+
|              G1 Full GC 完整执行流程                              |
+==================================================================+
|                                                                   |
|  触发条件：                                                        │
|  ├─ 分配失败（Young/Mixed GC后仍不足）                             │
|  ├─ 巨型对象分配失败                                               │
|  ├─ System.gc()                                                   │
|  └─ 元空间不足                                                     │
|                                                                   |
|  执行流程：                                                        │
|  1. do_full_collection()                                          │
|     ├─ GCLocker检查                                               │
|     ├─ 创建G1FullCollector                                        │
|     ├─ prepare_collection()                                       │
|     │   ├─ 中止并发标记                                            │
|     │   ├─ 保存偏向锁                                              │
|     │   └─ 启用引用发现                                            │
|     │                                                             │
|     ├─ collect()                                                  │
|     │   ├─ Phase 1: Mark Live Objects（标记存活对象）              │
|     │   ├─ Phase 2: Prepare Compaction（准备压缩）                 │
|     │   ├─ Phase 3: Adjust Pointers（调整指针）                    │
|     │   └─ Phase 4: Do Compaction（执行压缩）                      │
|     │                                                             │
|     └─ complete_collection()                                      │
|         ├─ 恢复Mark Word                                           │
|         ├─ 更新派生指针                                            │
|         ├─ 恢复偏向锁                                              │
|         └─ 堆验证                                                  │
|                                                                   |
|  2. resize_if_necessary_after_full_collection()                   │
|     └─ 根据Min/MaxHeapFreeRatio调整堆大小                          │
|                                                                   |
+==================================================================+
```

---

**GDB调试脚本：**

```bash
# verify_full_gc.gdb
set pagination off
set logging on

break G1CollectedHeap::do_full_collection
break G1FullCollector::phase1_mark_live_objects
break G1FullCollector::phase2_prepare_compaction
break G1FullCollector::phase3_adjust_pointers
break G1FullCollector::phase4_do_compaction

run -Xms8g -Xmx8g -XX:+UseG1GC -XX:+PrintGCDetails

# 查看Full GC原因
p gc_cause()

# 查看标记位图
p collector->mark_bitmap()

# 查看工作线程数
p collector->_num_workers

# 查看压缩点
p collector->_compaction_points[0]

continue
quit
```

---

**文档完成**

本文档完成了G1 Full GC的逐行深度分析，涵盖：
- Full GC触发条件与入口
- G1FullCollector类结构
- 4阶段标记-整理算法详解
- 每个阶段的核心操作
- Full GC完成与堆调整

下一章将分析：**G1RemSet** - Remembered Set跨Region引用追踪核心
