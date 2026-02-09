# Ch16: retransformClasses 完整链路 — 从 Java API 到 VM_RedefineClasses

> 基于 OpenJDK 11 源码 | libinstrument.so + HotSpot 深度分析
> 模块 A（第 2 篇 / 共 4 篇）| PerfMa 面试价值：⭐⭐⭐⭐⭐

---

## 16.1 总览：retransformClasses 解决什么问题？

### 核心场景

**已加载的类，需要在运行时重新被 ClassFileTransformer 处理**。

典型使用：
- **Arthas trace**：对一个已加载的方法添加耗时统计 → 需要 retransform 目标类
- **热修复**：替换有 bug 的方法实现 → 需要 retransform
- **动态增强**：按需给某个类加上监控代码 → 需要 retransform
- **卸载增强**：把之前的增强代码去掉（retransform 时 Transformer 不做修改，恢复原始字节码）

### retransformClasses vs redefineClasses

```
┌─────────────────────────────────────────────────────────────────────────┐
│                retransformClasses vs redefineClasses                     │
├─────────────────┬──────────────────────┬────────────────────────────────┤
│ 维度             │ retransformClasses   │ redefineClasses               │
├─────────────────┼──────────────────────┼────────────────────────────────┤
│ 字节码来源       │ JVM 缓存的原始字节码  │ 调用者自己提供新字节码          │
│                 │ → 经过 Transformer   │ → 不经过 Transformer           │
│                 │   链式处理            │   直接替换                     │
├─────────────────┼──────────────────────┼────────────────────────────────┤
│ Transformer 参与│ ✅ retransformable   │ ❌ 不参与                      │
│                 │   的 Transformer     │                                │
├─────────────────┼──────────────────────┼────────────────────────────────┤
│ 可逆性           │ ✅ 可恢复原始字节码   │ ❌ 不可逆（丢失原始字节码）     │
├─────────────────┼──────────────────────┼────────────────────────────────┤
│ 典型使用者       │ Arthas / APM 工具    │ HotSwap / IDE debug            │
├─────────────────┼──────────────────────┼────────────────────────────────┤
│ JVMTI 能力      │ can_retransform_     │ can_redefine_classes           │
│                 │ classes              │                                │
├─────────────────┼──────────────────────┼────────────────────────────────┤
│ 最终都走         │ VM_RedefineClasses   │ VM_RedefineClasses             │
│                 │ (kind=retransform)   │ (kind=redefine)                │
└─────────────────┴──────────────────────┴────────────────────────────────┘
```

### 完整调用链概览

```
用户代码:
  inst.retransformClasses(MyClass.class)
      │
      ▼
[Java 层] InstrumentationImpl.retransformClasses(classes)
  → retransformClasses0(mNativeAgent, classes)  // native 方法
      │
      ▼
[JNI 层] Java_sun_instrument_InstrumentationImpl_retransformClasses0
  → retransformClasses(jnienv, agent, classes)  // JPLISAgent.c
      │
      ▼
[libinstrument] retransformClasses()            // JPLISAgent.c
  → 从 Java 数组提取 jclass[]
  → (*retransformerEnv)->RetransformClasses(retransformerEnv, numClasses, classArray)
      │
      ▼
[JVMTI 层] JvmtiEnv::RetransformClasses()      // jvmtiEnv.cpp
  ├── 获取每个类的原始字节码：
  │   ├── 有缓存？→ ik->get_cached_class_file_bytes()
  │   └── 无缓存？→ JvmtiClassFileReconstituter 从 InstanceKlass 重建
  ├── 构造 jvmtiClassDefinition[] 数组
  └── VM_RedefineClasses op(count, defs, retransform)
      → VMThread::execute(&op)
          │
          ▼
[VM Operation — JavaThread] doit_prologue()     // jvmtiRedefineClasses.cpp
  ├── lock_classes()                             // 防止并发 redefine
  ├── load_new_class_versions()
  │   ├── SystemDictionary::parse_stream()       // 解析新字节码 → scratch_class
  │   │   └── 解析过程中触发 ClassFileLoadHook ！
  │   │       → eventHandlerClassFileLoadHook()
  │   │       → retransformable Transformer 链式处理字节码
  │   ├── compare_and_normalize_class_versions()  // 新旧类版本对比验证
  │   ├── Verifier::verify(scratch_class)         // 字节码验证
  │   ├── merge_cp_and_rewrite()                  // 常量池合并 + 字节码重写
  │   ├── Rewriter::rewrite(scratch_class)        // Rewriter 处理
  │   └── scratch_class->link_methods()           // 方法链接
  └── return true → 进入 safepoint
          │
          ▼
[VM Operation — VMThread @ Safepoint] doit()
  ├── MetadataOnStackMark md_on_stack(true)       // 标记栈上的 metadata
  ├── for each class:
  │   └── redefine_single_class(jclass, scratch_class)
  │       ├── 清除断点
  │       ├── flush_dependent_code()              // 反优化依赖此类的编译代码
  │       ├── compute_added_deleted_matching_methods()
  │       ├── 替换 methods 数组
  │       ├── 替换 constant pool
  │       ├── check_methods_and_mark_as_obsolete()
  │       ├── transfer_old_native_function_registrations()
  │       ├── 缓存原始字节码（用于下次 retransform）
  │       ├── 初始化 vtable / itable
  │       ├── add_previous_version()              // 保存旧版本
  │       ├── AdjustCpoolCacheAndVtable           // 调整所有引用此类的 cpCache/vtable
  │       └── increment_class_counter()
  ├── MethodDataCleaner 清理 MethodData
  ├── ResolvedMethodTable::adjust_method_entries()
  └── JvmtiExport::set_has_redefined_a_class()
          │
          ▼
[VM Operation] doit_epilogue()
  └── unlock_classes() + 释放 scratch_classes 内存
```

---

## 16.2 Java 层 → JNI 层 → libinstrument

### Java 入口

**文件**：`InstrumentationImpl.java` (line 163)

```java
public void retransformClasses(Class<?>... classes) {
    if (!isRetransformClassesSupported()) {
        throw new UnsupportedOperationException(...);
    }
    if (classes.length == 0) {
        return; // no-op
    }
    retransformClasses0(mNativeAgent, classes);  // → native 方法
}
```

### JNI 桥接

**文件**：`InstrumentationImplNativeMethods.c` (line 106)

```c
JNIEXPORT void JNICALL
Java_sun_instrument_InstrumentationImpl_retransformClasses0(
    JNIEnv * jnienv, jobject implThis, jlong agent, jobjectArray classes) {
    // agent 是 native 指针，在 InstrumentationImpl 构造时存入 Java long 字段
    retransformClasses(jnienv, (JPLISAgent*)(intptr_t)agent, classes);
}
```

### libinstrument: retransformClasses()

**文件**：`JPLISAgent.c` (line ~1430)

```
retransformClasses(jnienv, agent, classes):
│
├── retransformerEnv = retransformableEnvironment(agent)
│   └── 获取 Retransform 专用 JVMTI 环境
│       如果 mRetransformEnvironment.mJVMTIEnv 为 NULL → 出错
│
├── numClasses = GetArrayLength(classes)
│
├── classArray = allocate(retransformerEnv, numClasses * sizeof(jclass))
│
├── for (index = 0; index < numClasses; index++)
│   └── classArray[index] = GetObjectArrayElement(classes, index)
│       └── 逐一从 Java 数组中提取 jclass 引用
│
├── ★ 关键调用 ★
│   errorCode = (*retransformerEnv)->RetransformClasses(
│                   retransformerEnv, numClasses, classArray)
│   └── → JVMTI 层 JvmtiEnv::RetransformClasses()
│
├── deallocate(retransformerEnv, classArray)
│
└── 错误处理:
    └── createAndThrowThrowableFromJVMTIErrorCode(jnienv, errorCode)
    └── mapThrownThrowableIfNecessary(jnienv, redefineClassMapper)
        └── 把 JVMTI 错误映射为 Java 异常
```

**注意**：`retransformClasses` 用的是 `retransformerEnv`（Retransform 专用环境），不是 `mNormalEnvironment`。这确保了只有 retransformable 的 Transformer 会参与后续的 ClassFileLoadHook 回调。

---

## 16.3 JVMTI 层: JvmtiEnv::RetransformClasses

**文件**：`jvmtiEnv.cpp` (line 393)

这是 retransformClasses 和 redefineClasses 的**分水岭**——retransform 在这里获取原始字节码，然后与 redefine 汇合到同一个 `VM_RedefineClasses`。

### 完整流程

```
JvmtiEnv::RetransformClasses(class_count, classes[]):
│
├── 分配 jvmtiClassDefinition 数组
│
├── for (index = 0; index < class_count; index++):
│   │
│   ├── 验证 jclass 有效性
│   │   ├── JNIHandles::resolve_external_guard(jcls) → oop
│   │   ├── k_mirror->is_a(Class_klass)？
│   │   └── is_modifiable_class(k_mirror)？ → 排除基本类型/数组/匿名类
│   │
│   ├── 检查类状态
│   │   └── klass->jvmti_class_status() & JVMTI_CLASS_STATUS_ERROR → 无效
│   │
│   ├── ★ 获取原始字节码 ★（retransform 独有）
│   │   ├── ik->get_cached_class_file_bytes() != NULL？
│   │   │   └── 有缓存 → 直接使用缓存的原始字节码
│   │   │       class_definitions[i].class_bytes = cached bytes
│   │   │       class_definitions[i].class_byte_count = cached len
│   │   │
│   │   └── 缓存为 NULL → 从 InstanceKlass 重建
│   │       JvmtiClassFileReconstituter reconstituter(ik)
│   │       → 遍历 InstanceKlass 的内部结构
│   │       → 重新生成标准 .class 文件格式
│   │       class_definitions[i].class_bytes = reconstituter.class_file_bytes()
│   │       class_definitions[i].class_byte_count = reconstituter.class_file_size()
│   │
│   └── class_definitions[i].klass = jcls
│
├── ★ 创建 VM_RedefineClasses 并执行 ★
│   VM_RedefineClasses op(class_count, class_definitions,
│                         jvmti_class_load_kind_retransform)  ← retransform 标记！
│   VMThread::execute(&op)  ← 提交到 VMThread 执行
│
└── return op.check_error()
```

### 字节码来源的两种情况

```
情况 1：有缓存（大多数场景）
─────────────────────────────────────────────
  首次 ClassFileLoadHook 触发时，JvmtiClassFileLoadHookPoster
  会缓存原始字节码到 ik->_cached_class_file：
  
  JvmtiCachedClassFileData {
      jint length;               // 字节码长度
      unsigned char data[1];     // 柔性数组，存原始字节码
  }
  
  retransformClasses 直接读取这份缓存 → 交给 Transformer 处理

情况 2：无缓存（首次 retransform 且加载时无 Agent）
─────────────────────────────────────────────
  类加载时没有 Agent → 没有 ClassFileLoadHook → 没有缓存
  需要用 JvmtiClassFileReconstituter 从 InstanceKlass 重建：
  
  InstanceKlass 的内存结构 → 逆向还原为 .class 文件格式
  包括：magic/version/constant_pool/methods/fields/attributes
  
  注意：重建的字节码可能与原始 .class 略有差异
  （例如编译器生成的辅助代码、调试信息可能不完全一致）
```

### retransformClasses vs redefineClasses 在 JVMTI 层的差异

```
// retransformClasses:
VM_RedefineClasses op(class_count, class_definitions,
                      jvmti_class_load_kind_retransform);  // ← retransform

// redefineClasses:
VM_RedefineClasses op(class_count, class_definitions,
                      jvmti_class_load_kind_redefine);     // ← redefine
```

**汇合点**：两者从这里开始走**完全相同**的代码路径（`VM_RedefineClasses::doit_prologue` / `doit`），只是 `_class_load_kind` 不同，影响后续 ClassFileLoadHook 的分发策略。

---

## 16.4 VM_RedefineClasses 三阶段执行

### 整体设计

`VM_RedefineClasses` 是一个 **VM_Operation**，分三阶段执行：

```
┌─────────────────────────────────────────────────────────────────────┐
│                    VM_RedefineClasses 执行模型                       │
│                                                                     │
│  JavaThread（调用线程）                   VMThread                    │
│  ─────────────────────                ──────────                    │
│  │                                    │                             │
│  ├── doit_prologue() ──────────────┐  │                             │
│  │   ├── lock_classes()            │  │                             │
│  │   └── load_new_class_versions() │  │                             │
│  │       ├── parse_stream()        │  │                             │
│  │       │   └── 触发 ClassFile    │  │                             │
│  │       │       LoadHook !!!      │  │                             │
│  │       ├── verify()              │  │                             │
│  │       ├── merge_cp_and_rewrite()│  │                             │
│  │       ├── Rewriter::rewrite()   │  │                             │
│  │       └── link_methods()        │  │                             │
│  │                                 │  │                             │
│  │   如果返回 true ─────────────────┘  │                             │
│  │   → 等待 safepoint                  │                             │
│  │                                    │                             │
│  │                           ═══════════════ Safepoint ════════════ │
│  │                                    │                             │
│  │                                    ├── doit()                    │
│  │                                    │   ├── MetadataOnStackMark   │
│  │                                    │   └── redefine_single_class │
│  │                                    │       (对每个类)             │
│  │                                    │                             │
│  │                           ═══════════════ End Safepoint ════════ │
│  │                                    │                             │
│  ├── doit_epilogue() ◄────────────────┘                             │
│  │   └── unlock_classes()                                           │
│  │       free(_scratch_classes)                                     │
│  │                                                                  │
│  ▼ 返回到调用者                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

**关键设计决策**：

1. **doit_prologue() 在 JavaThread 中执行**：因为 `parse_stream()` 需要 Java 线程上下文（类加载、JVMTI 回调等）
2. **doit() 在 VMThread safepoint 中执行**：因为替换类的内部结构必须在所有 Java 线程暂停时进行
3. **ClassFileLoadHook 在 prologue 中触发**：即 Transformer 处理发生在进入 safepoint **之前**

---

## 16.5 Phase 1: doit_prologue — load_new_class_versions

### parse_stream 与 ClassFileLoadHook

**关键问题**：retransformClasses 的字节码是在哪里被 Transformer 修改的？

答案是在 `load_new_class_versions()` → `SystemDictionary::parse_stream()` → `ClassFileParser` → `KlassFactory::create_from_stream()` → `check_class_file_load_hook()` → **ClassFileLoadHook 事件**。

```
load_new_class_versions():
│
├── state->set_class_being_redefined(the_class, _class_load_kind)
│   ← 告诉 JVMTI：当前正在 redefine 这个类
│     ClassFileLoadHook 回调中 classBeingRedefined 参数来自这里
│
├── scratch_class = SystemDictionary::parse_stream(
│       the_class_sym, the_class_loader, protection_domain, &st)
│   │
│   └── 内部调用 ClassFileParser → KlassFactory::create_from_stream()
│       └── check_class_file_load_hook()
│           └── JvmtiExport::post_class_file_load_hook(
│                   name, loader, pd, &ptr, &end_ptr, &cache)
│               │
│               └── JvmtiClassFileLoadHookPoster::post_all_envs()
│                   │
│                   ├── 第一轮：非 retransformable 环境
│                   │   └── if _class_load_kind == retransform → 跳过！！！
│                   │       ← 这是 retransform 和 redefine 的关键区别
│                   │
│                   └── 第二轮：retransformable 环境
│                       └── post_to_env(env, true)
│                           → eventHandlerClassFileLoadHook()
│                           → transformClassFile(agent, ..., is_retransformer=true)
│                           → InstrumentationImpl.transform(..., isRetransformer=true)
│                           → mRetransfomableTransformerManager.transform(...)
│                           → 链式调用所有 retransformable Transformer
│                           → 返回修改后的字节码
│
├── state->clear_class_being_redefined()
│
├── compare_and_normalize_class_versions(the_class, scratch_class)
│   └── 验证新旧类的兼容性：
│       - 类名相同
│       - 父类相同
│       - 接口列表相同
│       - 字段数量、名称、签名、修饰符完全相同
│       - 方法签名和修饰符兼容（可以修改方法体）
│       - 不能添加/删除字段
│
├── Verifier::verify(scratch_class)
│   └── 验证修改后的字节码的合法性
│
├── merge_cp_and_rewrite(the_class, scratch_class)
│   └── 常量池合并：
│       ├── 将 old_cp 的所有条目复制到 merge_cp
│       ├── 将 scratch_cp 中的唯一条目追加到 merge_cp
│       ├── 跟踪 scratch_cp → merge_cp 的索引映射
│       ├── rewrite_cp_refs(): 更新 scratch_class 字节码中的 CP 索引
│       └── set_new_constant_pool(): 将 merge_cp 安装到 scratch_class
│
├── Rewriter::rewrite(scratch_class)
│   └── 字节码重写（你在 ch11-ch13 中已深入分析过）：
│       ├── 生成 ConstantPoolCache（CPCache）
│       ├── 将 getfield/putfield/invokevirtual 等重写为 _fast_* 形式
│       └── 处理 invokedynamic 引导方法
│
└── scratch_class->link_methods()
    └── 为每个方法设置 Method::_from_interpreted_entry
        和 Method::_i2i_entry（解释器入口）
```

### retransform 时 ClassFileLoadHook 的分发差异

**文件**：`jvmtiExport.cpp` 中 `JvmtiClassFileLoadHookPoster::post_all_envs()`

```
post_all_envs():
  第一轮（非 retransformable 环境）:
    for each non-retransformable env:
      if _class_load_kind == retransform:
        跳过！  ← ★ retransform 不触发普通 Transformer
      else:
        post_to_env(env, false)  // 普通类加载 + redefine 才触发

  第二轮（retransformable 环境）:
    for each retransformable env:
      post_to_env(env, true)  // 两种情况都触发
```

**这就是为什么 `addTransformer(transformer, true)` 的第二个参数 `canRetransform` 如此重要**：
- `true` → 注册到 `mRetransfomableTransformerManager` → retransform 时会被调用
- `false` → 注册到 `mTransformerManager` → retransform 时**不会**被调用

---

## 16.6 Phase 2: doit — redefine_single_class（safepoint 中）

这是整个 retransformClasses 的**核心——在 safepoint 中真正替换类的内部结构**。

### 完整步骤拆解

```
redefine_single_class(the_jclass, scratch_class):
│
├── 步骤 1: 准备工作
│   ├── the_class = get_ik(the_jclass)
│   ├── 清除此类中所有 JVMTI 断点
│   └── flush_dependent_code(the_class)  ← ★ 反优化
│       └── 两种策略：
│           ├── 已记录所有依赖 → CodeCache::flush_evol_dependents_on(ik)
│           │   → 只反优化依赖此类的 nmethod
│           └── 首次 redefine → CodeCache::mark_all_nmethods_for_deoptimization()
│               → 反优化所有编译代码（保守策略）
│               → Deoptimization::deoptimize_dependents()
│               → 之后 set_all_dependencies_are_recorded(true)
│
├── 步骤 2: 计算方法差异
│   ├── _old_methods = the_class->methods()
│   ├── _new_methods = scratch_class->methods()
│   ├── compute_added_deleted_matching_methods()
│   │   └── 双指针遍历（方法已按名称排序）：
│   │       → _matching_old_methods[] + _matching_new_methods[]
│   │       → _added_methods[]
│   │       → _deleted_methods[]
│   └── update_jmethod_ids()
│       └── 将旧方法的 jmethodID 指向新方法
│
├── 步骤 3: 替换核心结构（the_class ← scratch_class 互换）
│   │
│   ├── 3a. 替换常量池
│   │   scratch_class->constants()->set_pool_holder(the_class)
│   │   the_class->set_constants(scratch_class->constants())
│   │   scratch_class->set_constants(old_constants) // 保留旧的防 GC
│   │
│   ├── 3b. 替换方法数组
│   │   the_class->set_methods(_new_methods)
│   │   scratch_class->set_methods(_old_methods)  // 保留旧的防 GC
│   │
│   └── 3c. 替换方法排序
│       the_class->set_method_ordering(scratch_class->method_ordering())
│
├── 步骤 4: 标记旧方法
│   ├── check_methods_and_mark_as_obsolete()
│   │   ├── matching 方法：比较是否 EMCP（Equivalent Modulo CP）
│   │   │   ├── EMCP（方法体未变）→ 设 is_old()，不设 obsolete
│   │   │   │   → 栈上仍在执行的旧方法可以继续运行
│   │   │   └── 非 EMCP（方法体已变）→ 设 is_old() + is_obsolete()
│   │   │       → 栈上旧方法可以继续运行，但下次调用走新版本
│   │   └── deleted 方法 → 设 is_old() + is_obsolete()
│   │
│   └── transfer_old_native_function_registrations()
│       └── 将旧 native 方法的 JNI 函数注册转移到新方法
│
├── 步骤 5: 缓存原始字节码（retransform 专用）
│   if (the_class->get_cached_class_file() == NULL)
│       the_class->set_cached_class_file(scratch_class->get_cached_class_file())
│   └── 首次缓存：将原始字节码（Transformer 处理前的）保存到 InstanceKlass
│       → 供下次 retransformClasses 使用
│
├── 步骤 6: 替换其他元数据
│   ├── inner_classes
│   ├── source_file_name
│   ├── source_debug_extension
│   ├── access_flags（如 has_localvariable_table）
│   ├── annotations（swap_annotations）
│   ├── minor/major version
│   └── enclosing_method_indices
│
├── 步骤 7: 重新初始化虚表和接口表
│   the_class->vtable().initialize_vtable(false)
│   the_class->itable().initialize_itable(false)
│   └── 用新的方法填充 vtable/itable
│
├── 步骤 8: 保存旧版本（用于栈上旧方法的继续执行）
│   the_class->set_has_been_redefined()
│   the_class->add_previous_version(scratch_class, emcp_method_count)
│   └── 将 scratch_class（现在持有旧方法和旧常量池）加入
│       the_class 的 _previous_versions 链表
│       → 这些旧方法会一直保留直到栈上没有帧在使用它们
│
├── 步骤 9: 调整所有引用此类的其他类
│   AdjustCpoolCacheAndVtable adjust_cpool_cache_and_vtable(THREAD)
│   ClassLoaderDataGraph::classes_do(&adjust_cpool_cache_and_vtable)
│   └── 遍历所有已加载的类，调整它们的：
│       ├── ConstantPoolCache 中指向旧方法的条目 → 指向新方法
│       ├── vtable 中继承/override 的方法条目 → 指向新方法
│       └── itable 中接口方法条目 → 指向新方法
│
├── 步骤 10: 刷新缓存
│   if (the_class->oop_map_cache() != NULL)
│       the_class->oop_map_cache()->flush_obsolete_entries()
│
└── 步骤 11: 递增计数器
    increment_class_counter(the_class)
    └── the_class 和所有子类的 classRedefinedCount++
```

---

## 16.7 常量池合并详解

**为什么需要常量池合并？**

retransform/redefine 后，scratch_class 的常量池可能与 the_class 的常量池不同（新增/修改了引用）。但旧方法（还在栈上执行的）仍然引用旧常量池的索引。

**解决方案**：`merge_cp_and_rewrite()`

```
merge_cp_and_rewrite(the_class, scratch_class):
│
├── old_cp = the_class->constants()
├── scratch_cp = scratch_class->constants()
│
├── merge_constant_pools(old_cp, scratch_cp, &merge_cp, &merge_cp_length)
│   │
│   ├── Step 1: 复制 old_cp 的所有条目到 merge_cp
│   │   → 保持索引不变 → 旧方法可以继续正常工作
│   │
│   ├── Step 2: 遍历 scratch_cp 的每个条目
│   │   for (scratch_i = 1; scratch_i < scratch_cp->length(); scratch_i++)
│   │   ├── 在 merge_cp 中查找是否已存在相同条目
│   │   ├── 已存在 → 记录 scratch_i → merge_i 的索引映射
│   │   └── 不存在 → 追加到 merge_cp 末尾，记录映射
│   │
│   └── 结果：merge_cp = old_cp 全部条目 + scratch_cp 的新增条目
│
├── rewrite_cp_refs(scratch_class)
│   └── 根据索引映射，重写 scratch_class 中的所有 CP 引用
│       ├── 方法字节码中的 CP 索引
│       ├── 异常表中的 CP 索引
│       ├── 注解中的 CP 索引
│       ├── 栈映射表中的 CP 索引
│       └── StackMap/LocalVariableTable 中的 CP 索引
│
└── set_new_constant_pool(scratch_class, merge_cp, merge_cp_length)
    └── 将 merge_cp 安装为 scratch_class 的常量池
        → 后续 scratch_class 的常量池会替换 the_class 的
```

---

## 16.8 反优化（Deoptimization）

**问题**：如果一个方法被 C2 编译了，retransform 后怎么办？

JIT 编译的 nmethod 直接嵌入了方法体的机器码，如果方法体被 retransform 修改了，这些 nmethod 就过时了。

### flush_dependent_code 策略

```
flush_dependent_code(ik):
│
├── 场景 1：JvmtiExport::all_dependencies_are_recorded()
│   └── CodeCache::flush_evol_dependents_on(ik)
│       → 只反优化依赖此类的 nmethod
│       → 精准反优化，影响范围小
│
└── 场景 2：首次 redefine（能力是运行时获取的）
    ├── CodeCache::mark_all_nmethods_for_deoptimization()
    │   → 标记所有 nmethod 需要反优化（保守策略）
    ├── Deoptimization::deoptimize_dependents()
    │   → 触发反优化
    ├── CodeCache::make_marked_nmethods_not_entrant()
    │   → 防止新的调用进入旧的编译代码
    └── set_all_dependencies_are_recorded(true)
        → 之后的 redefine 可以精准反优化
```

**面试要点**：retransformClasses 会导致相关方法的 JIT 编译代码失效，回退到解释执行。如果该方法后续仍然是热点，C1/C2 会重新编译新版本的方法体。

---

## 16.9 面试专题

### Q1: Arthas trace 底层是怎么实现的？

**完整回答**：
1. Arthas 通过 Attach API 连接到目标 JVM（Ch19 讲）
2. 加载 Agent jar → `agentmain()` 获得 `Instrumentation` 对象
3. 注册一个 retransformable 的 `ClassFileTransformer`（`addTransformer(t, true)`）
4. 调用 `inst.retransformClasses(targetClass)` 触发目标类的重新转换
5. 在 Transformer 中用 ASM/ByteBuddy 修改目标方法的字节码，在方法入口/出口插入计时代码
6. **JVM 内部发生了什么**：
   - JVMTI `RetransformClasses` 获取缓存的原始字节码
   - 提交 `VM_RedefineClasses` 到 VMThread
   - `doit_prologue` 中 `parse_stream()` 触发 ClassFileLoadHook → Transformer 修改字节码
   - `merge_cp_and_rewrite` 合并常量池
   - `Rewriter::rewrite` + `link_methods` 重建执行基础设施
   - 进入 safepoint → `redefine_single_class` 替换方法数组和常量池
   - `flush_dependent_code` 反优化相关 JIT 编译代码
   - 退出 safepoint → 下次执行该方法时走新的字节码（解释执行，后续可能再被 JIT）

### Q2: retransformClasses 为什么可以"恢复"原始类？

因为 JVM 缓存了 Transformer 处理**之前**的原始字节码（`ik->_cached_class_file`）。
retransform 时用这份缓存作为输入给 Transformer。如果此时用户已经 `removeTransformer`，
没有 Transformer 再修改字节码，那么原始字节码直接被用来重新定义类 → 等效于恢复。

### Q3: retransform 时为什么不触发普通 Transformer？

JVMTI 规范设计：retransform 只触发 retransformable 环境上的 ClassFileLoadHook。
在 `JvmtiClassFileLoadHookPoster::post_all_envs()` 中，如果 `_class_load_kind == retransform`，第一轮遍历（非 retransformable 环境）会被跳过。
这保证了 retransform 的语义：只有通过 `addTransformer(t, true)` 注册的 Transformer 参与。

### Q4: retransform 能修改类的结构吗（加字段/方法）？

**不能**。`compare_and_normalize_class_versions()` 严格验证：
- 字段数量、名称、签名、修饰符必须完全相同
- 方法签名和修饰符必须兼容（但方法体可以修改）
- 父类、接口列表不能变
- 只能修改方法体（字节码）和常量池

### Q5: retransform 期间其他线程在做什么？

三个阶段的线程状态不同：
1. **doit_prologue**：当前 JavaThread 正常执行，其他线程也正常运行（ClassFileLoadHook 回调在这里触发）
2. **doit (safepoint)**：所有 Java 线程暂停在安全点，只有 VMThread 在执行 `redefine_single_class`
3. **doit_epilogue**：safepoint 结束，所有线程恢复执行

### Q6: retransform 对性能的影响？

- **短期影响**：
  - 进入 safepoint（所有 Java 线程短暂暂停）
  - `flush_dependent_code` 反优化相关编译代码 → 回退到解释执行
  - `ClassLoaderDataGraph::classes_do` 遍历所有类调整 cpCache/vtable

- **长期影响**：
  - 被 retransform 的方法如果仍是热点，会被重新 JIT 编译
  - `_cached_class_file` 占用额外内存
  - `add_previous_version` 保留旧版本直到栈上无引用

---

## 16.10 关联知识串联

| 本章知识点 | 串联已有分析 |
|-----------|-------------|
| `Rewriter::rewrite(scratch_class)` | Ch11-Ch13 Rewriter 分析 |
| `scratch_class->link_methods()` | Ch12 Method::link_method 分析 |
| `ClassFileParser → parse_stream()` | Ch08 defineClass 类加载分析 |
| `flush_dependent_code → Deoptimization` | 与 C1/C2 编译器关联 |
| `ClassFileLoadHook → transformClassFile` | Ch15 Java Agent 机制 |
| `ConstantPoolCache 调整` | Ch11 CPCache 结构分析 |

---

## GDB 验证计划

```bash
# 验证 RetransformClasses 入口
gdb -batch -ex "b JvmtiEnv::RetransformClasses" \
    -ex "run" --args ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
    -javaagent:/tmp/test-agent.jar -Xms8g -Xmx8g -XX:+UseG1GC \
    -cp /data/workspace/demo/src com.wjcoder.Main

# 验证 redefine_single_class 在 safepoint 中执行
gdb -batch -ex "b VM_RedefineClasses::redefine_single_class" \
    -ex "run" --args ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
    -javaagent:/tmp/test-agent.jar -Xms8g -Xmx8g -XX:+UseG1GC \
    -cp /data/workspace/demo/src com.wjcoder.Main

# 验证 ClassFileLoadHook 在 retransform 期间被触发
gdb -batch -ex "b eventHandlerClassFileLoadHook" \
    -ex "run" --args ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
    -javaagent:/tmp/test-agent.jar -Xms8g -Xmx8g -XX:+UseG1GC \
    -cp /data/workspace/demo/src com.wjcoder.Main

# 查看 JVM redefine 日志
./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
    -Xlog:redefine+class*=trace \
    -javaagent:/tmp/test-agent.jar -Xms8g -Xmx8g -XX:+UseG1GC \
    -cp /data/workspace/demo/src com.wjcoder.Main
```

---

## 下一步

**Ch17: JVMTI 事件体系 — 从 Event 注册到 Callback 分发**
- JVMTI 事件的注册/启用/禁用完整机制
- JvmtiEventController 的全局/线程级事件控制
- 各种事件的触发时机和回调链路
- 与 libinstrument 的 ClassFileLoadHook 串联

---

*分析文件*：`src/java.instrument/share/classes/sun/instrument/InstrumentationImpl.java`
*分析文件*：`src/java.instrument/share/native/libinstrument/JPLISAgent.c` (retransformClasses)
*分析文件*：`src/java.instrument/share/native/libinstrument/InstrumentationImplNativeMethods.c`
*分析文件*：`src/hotspot/share/prims/jvmtiEnv.cpp` (RetransformClasses / RedefineClasses)
*分析文件*：`src/hotspot/share/prims/jvmtiRedefineClasses.cpp` (VM_RedefineClasses 全部)
*分析文件*：`src/hotspot/share/prims/jvmtiRedefineClasses.hpp`
