# 方法调用全链路 深度解析

> 基于 OpenJDK 11 源码分析 + 插桩验证
> 标准环境：`-Xms8g -Xmx8g -XX:+UseG1GC -Xint`，G1 Region = 4MB
> 核心文件：`src/hotspot/share/interpreter/interpreterRuntime.cpp`
>           `src/hotspot/share/interpreter/linkResolver.cpp`
>           `src/hotspot/share/oops/cpCache.hpp`

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

`invokevirtual` 方法调用 = **"首次调用时解析符号引用并缓存结果，后续调用直接用缓存的 vtable 索引查表"**。

解析结果缓存在 `ConstantPoolCacheEntry`（cpCache）中，一旦缓存就不再进入 `InterpreterRuntime`，直接在解释器模板中完成 vtable 查找。

### 0.2 为什么需要 cpCache？

字节码中的方法引用是符号引用（类名 + 方法名 + 签名），每次调用都去常量池解析符号 = 极慢。cpCache 把符号引用解析为 vtable 索引，后续调用只需 `recv.klass().vtable[index]` 一次内存访问。

### 0.3 两阶段解析

```
第一阶段：链接时解析（Linktime）
  → 从常量池找到方法的声明类（resolved_klass）
  → 找到方法的 vtable 索引（resolved_method.vtable_index）
  → 不依赖接收者类型

第二阶段：运行时解析（Runtime）
  → 根据实际接收者类型（recv.klass）
  → 用 vtable 索引查找实际方法（selected_method）
  → 实现多态分派
```

### 0.4 为什么这样设计？

- **两阶段分离**：链接时只做类型检查（不需要接收者），运行时才做多态分派（需要接收者）。这样 cpCache 只需缓存 vtable 索引，不需要缓存具体方法指针（因为不同接收者类型会选择不同方法）。
- **vtable 索引稳定性**：同一个虚方法在所有子类的 vtable 中占据相同的索引位置，这是多态分派 O(1) 的基础。
- **final 方法特殊处理**：final 方法不需要 vtable 查找，直接缓存方法指针（`is_vfinal = true`），比普通虚方法更快。

---

## 第 1 部分：数据结构全景

### 1.1 数据结构清单

| 结构名 | 源码位置 | 核心作用 |
|--------|----------|----------|
| `CallInfo` | `interpreter/linkResolver.hpp:38` | 解析结果容器，持有 resolved/selected 方法和 vtable 索引 |
| `LinkInfo` | `interpreter/linkResolver.hpp:130` | 解析输入，持有类名/方法名/签名/当前类 |
| `ConstantPoolCacheEntry` | `oops/cpCache.hpp:132` | 解析结果缓存，每个 invoke 字节码一个 |
| `ConstantPoolCache` | `oops/cpCache.hpp:482` | cpCache 整体，每个 ConstantPool 一个 |

### 1.2 CallInfo 详细分析

#### 1.2.1 字段列表

```cpp
// linkResolver.hpp:38
class CallInfo : public StackObj {
 public:
  enum CallKind {
    direct_call,   // 直接调用（invokespecial/invokestatic/final 方法）
    vtable_call,   // vtable 查找（invokevirtual 普通虚方法）
    itable_call,   // itable 查找（invokeinterface）
    unknown_kind = -1
  };
 private:
  Klass*       _resolved_klass;   // 静态接收者类（常量池中声明的类）
  Klass*       _selected_klass;   // 动态接收者类（运行时实际类型）
  methodHandle _resolved_method;  // 静态目标方法（声明类中的方法）
  methodHandle _selected_method;  // 动态目标方法（实际执行的方法）
  CallKind     _call_kind;        // 调用类型（direct/vtable/itable）
  int          _call_index;       // vtable 或 itable 索引
  Handle       _resolved_appendix;     // invokedynamic/invokehandle 附加参数
  Handle       _resolved_method_type;  // MethodType（invokedynamic）
  Handle       _resolved_method_name;  // ResolvedMethodName 对象
};
```

#### 1.2.2 关键字段含义

| 字段 | 含义 | 示例 |
|------|------|------|
| `_resolved_klass` | 常量池中声明的类 | `Animal`（即使实际是 `Dog`） |
| `_selected_klass` | 运行时实际类型 | `Dog` |
| `_resolved_method` | 声明类中的方法 | `Animal.speak()` |
| `_selected_method` | 实际执行的方法 | `Dog.speak()` |
| `_call_index` | vtable/itable 索引 | `5`（Animal.speak 在 vtable 第 5 位） |

#### 1.2.3 sizeof 与创建位置

- `CallInfo` 是栈对象（`StackObj`），在 `InterpreterRuntime::resolve_invoke()` 中创建
- sizeof 约 80 bytes（7 个指针/handle + 1 个 int + 1 个 enum）

#### 1.2.4 关键字段生命周期

- `_call_kind/_call_index`：由 `set_virtual()`/`set_interface()`/`set_static()` 设置
- 生命周期：`resolve_invoke()` 调用开始 → `cp_cache_entry->set_vtable_call()` 写入 cpCache → 栈帧销毁

### 1.3 LinkInfo 详细分析

#### 1.3.1 字段列表

```cpp
// linkResolver.hpp:130
class LinkInfo : public StackObj {
  Symbol*      _name;            // 方法名（从 JVM_CONSTANT_NameAndType 提取）
  Symbol*      _signature;       // 方法签名
  Klass*       _resolved_klass;  // 常量池中指向的类（静态类型）
  Klass*       _current_klass;   // 持有常量池的类（调用方所在类）
  methodHandle _current_method;  // 调用方方法（用于访问权限检查）
  bool         _check_access;    // 是否检查访问权限
  constantTag  _tag;             // 常量池条目类型
};
```

#### 1.3.2 创建位置与生命周期

- 在 `resolve_invokevirtual()` 中通过 `LinkInfo link_info(pool, index, CHECK)` 创建
- 从常量池的 `CONSTANT_Methodref` 条目中提取类名/方法名/签名
- 生命周期：仅在 `resolve_virtual_call()` 调用期间存在

### 1.4 ConstantPoolCacheEntry 详细分析

#### 1.4.1 字段列表

```cpp
// cpCache.hpp:132
class ConstantPoolCacheEntry {
 private:
  volatile intx      _indices;  // [b2(8)|b1(8)|cp_index(16)]
                                // b1 = 第一个字节码（如 invokespecial）
                                // b2 = 第二个字节码（如 invokevirtual）
                                // cp_index = 原始常量池索引
  Metadata* volatile _f1;       // 方法条目：非虚调用的 Method*，接口调用的 Klass*
                                // 字段条目：字段持有者 Klass（java.lang.Class）
  volatile intx      _f2;       // 方法条目：vtable/itable 索引，或 final Method*
                                // 字段条目：字段偏移（字节）
  volatile intx      _flags;    // [tos(4)|F|M|A|I|f|v|vf|indy_rf|...|psize(8)]
                                // tos = 返回类型的 TosState
                                // F = 是字段条目（0=方法）
                                // f = final，v = volatile，vf = virtual final
                                // psize = 参数大小（方法条目）
};
```

#### 1.4.2 内存布局（实测）

```
ConstantPoolCacheEntry 内存布局（32 bytes）：
┌──────────────────────────────────────────────────────────┐
│ offset 0:  _indices (8 bytes)  [b2|b1|cp_index]         │
│ offset 8:  _f1      (8 bytes)  Method* 或 Klass*        │
│ offset 16: _f2      (8 bytes)  vtable_index 或 Method*  │
│ offset 24: _flags   (8 bytes)  [tos|F|M|A|I|f|v|vf|...] │
└──────────────────────────────────────────────────────────┘
sizeof(ConstantPoolCacheEntry) = 32 bytes（4 × 8 bytes）
```

#### 1.4.3 invokevirtual 解析后的状态

```
解析前（未缓存）：
  _indices = [0x00 | 0x00 | cp_index]  ← b1/b2 都是 0
  _f1 = NULL
  _f2 = 0
  _flags = 0

解析后（vtable_call）：
  _indices = [invokevirtual(0xb6) | 0x00 | cp_index]  ← b2 写入字节码
  _f1 = NULL（vtable_call 不用 f1）
  _f2 = vtable_index（如 5）
  _flags = [atos | F=0 | ... | psize=1]
```

#### 1.4.4 关键字段生命周期

- `_indices.b2`：`set_bytecode_2()` 最后写入（写入后表示已解析，是原子操作）
- `_f2`：`set_f2()` 写入 vtable 索引，写入后不可更改（assert 保证）
- `_flags`：`set_method_flags()` 写入，包含参数大小和返回类型

#### 1.4.5 is_resolved 判断逻辑

```cpp
// cpCache.cpp
bool ConstantPoolCacheEntry::is_resolved(Bytecodes::Code code) const {
  switch (bytecode_number(code)) {
    case 1:  return (bytecode_1() == code);  // b1 字段是否已写入
    case 2:  return (bytecode_2() == code);  // b2 字段是否已写入
  }
  return false;  // invokevirtual 用 b2
}
```

**关键**：`invokevirtual` 用 `bytecode_2`（b2），写入 b2 是解析完成的标志。

### 1.5 ConstantPoolCache 详细分析

#### 1.5.1 字段列表

```cpp
// cpCache.hpp:482
class ConstantPoolCache: public MetaspaceObj {
 private:
  int             _length;           // 条目数量
  ConstantPool*   _constant_pool;    // 对应的常量池
  OopHandle       _resolved_references;  // 解析后的对象引用数组
  Array<u2>*      _reference_map;    // 解析对象索引 → 原始 cp 索引的映射
};
```

#### 1.5.2 与 ConstantPool 的关系

```
ConstantPool（只读，类加载时创建）
    │
    └── ConstantPoolCache（可写，类链接时创建）
            │
            └── ConstantPoolCacheEntry[0..n]（每个 invoke/field 字节码一个）
```

- `ConstantPool` 存储符号引用（类名/方法名/签名），**只读**
- `ConstantPoolCache` 存储解析结果（vtable 索引/Method*），**可写**
- 分离设计：允许 ConstantPool 在 CDS 中共享，而 ConstantPoolCache 每个类加载器独立

---

## 第 2 部分：算法/流程分析

### 2.1 核心流程概览

```mermaid
flowchart TD
    A["invokevirtual 字节码\n解释器执行"] --> B{cpCache 已解析?}
    B -->|Yes 99%+| C["直接用 _f2 的 vtable_index\nrecv.klass.vtable[index]\n无需进入 Runtime"]
    B -->|No 首次调用| D["InterpreterRuntime::resolve_invoke()\n进入 C++ 运行时"]
    
    D --> E["提取接收者 receiver\n从操作数栈顶"]
    E --> F["LinkResolver::resolve_invoke()\n分发到 resolve_invokevirtual"]
    F --> G["LinkInfo(pool, index)\n从常量池提取类名/方法名/签名"]
    G --> H["linktime_resolve_virtual_method()\n第一阶段：链接时解析"]
    H --> I["resolve_method()\n在声明类中查找方法"]
    I --> J["runtime_resolve_virtual_method()\n第二阶段：运行时解析"]
    J --> K["recv_klass.method_at_vtable(vtable_index)\n多态分派：查 vtable"]
    K --> L["result.set_virtual()\n填充 CallInfo"]
    L --> M{call_kind?}
    M -->|vtable_call| N["cp_cache_entry->set_vtable_call()\n写入 vtable_index 到 _f2\n写入 invokevirtual 到 b2"]
    M -->|direct_call| O["cp_cache_entry->set_direct_call()\n写入 Method* 到 _f1"]
    M -->|itable_call| P["cp_cache_entry->set_itable_call()\n写入 itable_index 到 _f2"]
    N --> Q["下次调用直接走缓存路径"]
    
    style C fill:#90EE90
    style Q fill:#90EE90
    style D fill:#FFD700
```

### 2.2 入口：InterpreterRuntime::resolve_invoke()

#### 2.2.1 解决什么问题？

字节码 `invokevirtual` 首次执行时，cpCache 未初始化，需要进入 C++ 运行时完成符号解析并缓存结果。

#### 2.2.2 源码（interpreterRuntime.cpp:856）

```cpp
// interpreterRuntime.cpp:856
void InterpreterRuntime::resolve_invoke(JavaThread* thread, Bytecodes::Code bytecode) {
  Thread* THREAD = thread;
  LastFrameAccessor last_frame(thread);

  // ★ 第一步：提取接收者（invokevirtual/invokeinterface/invokespecial 需要）
  Handle receiver(thread, NULL);
  if (bytecode == Bytecodes::_invokevirtual || bytecode == Bytecodes::_invokeinterface ||
      bytecode == Bytecodes::_invokespecial) {
    ResourceMark rm(thread);
    methodHandle m(thread, last_frame.method());
    Bytecode_invoke call(m, last_frame.bci());
    Symbol* signature = call.signature();
    receiver = Handle(thread, last_frame.callee_receiver(signature));
    // ★ callee_receiver 从操作数栈中找到 this 指针
    // ★ 根据签名计算参数个数，从栈顶往下数找到 receiver
  }

  // ★ 第二步：调用 LinkResolver 解析
  CallInfo info;
  constantPoolHandle pool(thread, last_frame.method()->constants());
  {
    JvmtiHideSingleStepping jhss(thread);  // 隐藏 JVMTI 单步事件
    LinkResolver::resolve_invoke(info, receiver, pool,
                                 last_frame.get_index_u2_cpcache(bytecode),
                                 bytecode, CHECK);
    // ★ 热重载支持：如果方法被重定义，重新解析
    if (JvmtiExport::can_hotswap_or_post_breakpoint()) {
      int retry_count = 0;
      while (info.resolved_method()->is_old()) {
        LinkResolver::resolve_invoke(info, receiver, pool, ...);
      }
    }
  }

  // ★ 第三步：检查是否已被其他线程解析（并发安全）
  ConstantPoolCacheEntry* cp_cache_entry = last_frame.cache_entry();
  if (cp_cache_entry->is_resolved(bytecode)) return;  // ★ 已解析，直接返回

  // ★ 第四步：根据 call_kind 写入 cpCache
  switch (info.call_kind()) {
  case CallInfo::direct_call:
    cp_cache_entry->set_direct_call(bytecode, info.resolved_method(),
                                    sender->is_interface());
    break;
  case CallInfo::vtable_call:
    cp_cache_entry->set_vtable_call(bytecode, info.resolved_method(),
                                    info.vtable_index());
    break;
  case CallInfo::itable_call:
    cp_cache_entry->set_itable_call(bytecode, info.resolved_klass(),
                                    info.resolved_method(), info.itable_index());
    break;
  }
}
```

**设计决策**：
- `is_resolved()` 检查在写入之前：多线程可能同时进入 `resolve_invoke()`，第一个写入的线程完成缓存，后续线程发现已解析直接返回，保证幂等性
- `b2` 字段最后写入（`set_bytecode_2()`）：这是原子操作，写入后其他线程才能看到"已解析"状态，保证 cpCache 的可见性

### 2.3 第一阶段：链接时解析（linktime_resolve_virtual_method）

#### 2.3.1 解决什么问题？

从常量池的符号引用（类名 + 方法名 + 签名）找到声明类中的 `Method*` 对象，并获取其 vtable 索引。这一步不依赖接收者类型，结果对所有调用点相同。

#### 2.3.2 源码（linkResolver.cpp:1302）

```cpp
// linkResolver.cpp:1302
methodHandle LinkResolver::linktime_resolve_virtual_method(const LinkInfo& link_info, TRAPS) {
  // ★ 在声明类（resolved_klass）中查找方法
  methodHandle resolved_method = resolve_method(link_info, Bytecodes::_invokevirtual, CHECK_NULL);

  // ★ 检查：不能是构造方法或类初始化方法
  assert(resolved_method->name() != vmSymbols::object_initializer_name(), "...");
  assert(resolved_method->name() != vmSymbols::class_initializer_name(), "...");

  // ★ 检查：私有接口方法必须用 invokespecial，不能用 invokevirtual
  Klass* resolved_klass = link_info.resolved_klass();
  if (resolved_klass->is_interface() && resolved_method->is_private()) {
    THROW_MSG_NULL(vmSymbols::java_lang_IncompatibleClassChangeError(), ...);
  }

  // ★ 检查：不能是静态方法
  if (resolved_method->is_static()) {
    THROW_MSG_NULL(vmSymbols::java_lang_IncompatibleClassChangeError(), ...);
  }

  return resolved_method;  // ★ 返回 Method*，其中 _vtable_index 已经设置好
}
```

**关键**：`resolved_method->vtable_index()` 在类加载时（`klassVtable::initialize_vtable()`）就已经设置好，这里直接读取。

### 2.4 第二阶段：运行时解析（runtime_resolve_virtual_method）

#### 2.4.1 解决什么问题？

根据实际接收者类型（`recv_klass`），用 vtable 索引查找实际执行的方法，实现多态分派。

#### 2.4.2 源码（linkResolver.cpp:1350）

```cpp
// linkResolver.cpp:1350
void LinkResolver::runtime_resolve_virtual_method(CallInfo& result,
                                                  const methodHandle& resolved_method,
                                                  Klass* resolved_klass,
                                                  Handle recv,
                                                  Klass* recv_klass,
                                                  bool check_null_and_abstract, TRAPS) {
  int vtable_index = Method::invalid_vtable_index;
  methodHandle selected_method;

  // ★ 空指针检查
  if (check_null_and_abstract && recv.is_null()) {
    THROW(vmSymbols::java_lang_NullPointerException());
  }

  // ★ 分支1：resolved_method 来自接口（default 方法或 miranda 方法）
  if (resolved_method->method_holder()->is_interface()) {
    // ★ 接口的 default 方法也在 vtable 中，需要先找到 vtable 索引
    vtable_index = vtable_index_of_interface_method(resolved_klass, resolved_method);
    selected_method = methodHandle(THREAD, recv_klass->method_at_vtable(vtable_index));
  } else {
    // ★ 分支2：普通虚方法，直接从 resolved_method 读取 vtable 索引
    vtable_index = resolved_method->vtable_index();

    if (vtable_index == Method::nonvirtual_vtable_index) {
      // ★ final 方法：vtable_index = -2，不需要查表，直接用 resolved_method
      assert(resolved_method->can_be_statically_bound(), "cannot override this method");
      selected_method = resolved_method;
    } else {
      // ★ 普通虚方法：用 vtable_index 在接收者类的 vtable 中查找
      selected_method = methodHandle(THREAD, recv_klass->method_at_vtable(vtable_index));
    }
  }

  // ★ 检查方法是否存在（抽象类实例化时可能为 null）
  if (selected_method.is_null()) {
    throw_abstract_method_error(resolved_method, recv_klass, CHECK);
  }

  // ★ 填充 CallInfo
  result.set_virtual(resolved_klass, recv_klass, resolved_method, selected_method,
                     vtable_index, CHECK);
}
```

**设计决策**：
- `vtable_index == nonvirtual_vtable_index（-2）`：final 方法的特殊值，表示不需要 vtable 查找，cpCache 会设置 `is_vfinal = true`，`_f2` 存储 `Method*` 而非索引
- `recv_klass->method_at_vtable(vtable_index)`：这是多态分派的核心，同一个 vtable_index 在不同子类中指向不同的方法实现

### 2.5 cpCache 写入：set_vtable_call()

#### 2.5.1 解决什么问题？

将解析结果（vtable 索引）写入 cpCache，使后续调用无需再进入 Runtime。

#### 2.5.2 源码（cpCache.cpp）

```cpp
// cpCache.cpp
void ConstantPoolCacheEntry::set_vtable_call(Bytecodes::Code invoke_code,
                                              const methodHandle& method,
                                              int index) {
  // ★ 调用通用的 set_direct_or_vtable_call
  set_direct_or_vtable_call(invoke_code, method, index, false);
}

void ConstantPoolCacheEntry::set_direct_or_vtable_call(Bytecodes::Code invoke_code,
                                                        const methodHandle& method,
                                                        int vtable_index,
                                                        bool sender_is_interface) {
  // ★ 计算 flags：返回类型 + 参数大小 + final/vfinal 标志
  bool is_vfinal = method->can_be_statically_bound();
  // ...
  set_method_flags(as_TosState(method->result_type()),
                   (is_vfinal ? 1 << is_vfinal_shift : 0) | ...,
                   method->size_of_parameters());

  if (is_vfinal) {
    // ★ final 方法：_f2 存储 Method* 指针
    set_f2_as_vfinal_method(method());
  } else {
    // ★ 普通虚方法：_f2 存储 vtable 索引
    assert(vtable_index >= 0, "valid index");
    set_f2(vtable_index);
  }

  // ★ 最后写入字节码（原子操作，写入后表示"已解析"）
  set_bytecode_2(invoke_code);  // ← 这是最后一步，保证可见性
}
```

**设计决策**：`set_bytecode_2()` 最后写入，是一个内存屏障点。其他线程通过 `is_resolved()` 检查 b2 是否已写入来判断 cpCache 是否有效，保证不会读到半初始化的 cpCache。

---

## 第 3 部分：插桩计划

### 3.1 验证目标

| 目标 | 插桩位置 | 验证问题 |
|------|---------|---------|
| 首次调用 vs 缓存命中 | `InterpreterRuntime::resolve_invoke()` | 每个方法调用点只解析一次？ |
| vtable 索引分配 | `runtime_resolve_virtual_method()` | vtable_index 的实际值是多少？ |
| call_kind 分布 | `InterpreterRuntime::resolve_invoke()` | direct/vtable/itable 各占多少？ |
| cpCache 写入 | `set_vtable_call()` / `set_direct_call()` | 写入后 _f2 的值是什么？ |

### 3.2 插桩代码

**插桩位置**：`src/hotspot/share/interpreter/interpreterRuntime.cpp`

在 `resolve_invoke()` 函数末尾（switch 语句之后）插入：

```cpp
// ===== [PROBE] 方法调用解析插桩 =====
{
  static int _resolve_count = 0;
  static int _direct_count = 0;
  static int _vtable_count = 0;
  static int _itable_count = 0;

  _resolve_count++;
  switch (info.call_kind()) {
    case CallInfo::direct_call: _direct_count++; break;
    case CallInfo::vtable_call: _vtable_count++; break;
    case CallInfo::itable_call: _itable_count++; break;
    default: break;
  }

  if (_resolve_count <= 50) {
    ResourceMark rm(thread);
    const char* kind_str = "unknown";
    int idx = info.call_index();
    switch (info.call_kind()) {
      case CallInfo::direct_call: kind_str = "direct"; break;
      case CallInfo::vtable_call: kind_str = "vtable"; break;
      case CallInfo::itable_call: kind_str = "itable"; break;
      default: break;
    }
    tty->print_cr("[PROBE][MethodInvoke] #%d bytecode=%s kind=%s"
                  " resolved=%s::%s index=%d",
                  _resolve_count,
                  Bytecodes::name(bytecode),
                  kind_str,
                  info.resolved_method()->method_holder()->external_name(),
                  info.resolved_method()->name()->as_C_string(),
                  idx);
  }
  if (_resolve_count % 100 == 0) {
    tty->print_cr("[PROBE][MethodInvoke] total=%d direct=%d vtable=%d itable=%d",
                  _resolve_count, _direct_count, _vtable_count, _itable_count);
  }
}
// ===== [PROBE END] =====
```

**插桩位置**：`src/hotspot/share/interpreter/linkResolver.cpp`

在 `runtime_resolve_virtual_method()` 的 `result.set_virtual()` 之前插入：

```cpp
// ===== [PROBE] vtable 索引插桩 =====
{
  static int _vtable_probe_count = 0;
  if (_vtable_probe_count++ < 30 && vtable_index >= 0) {
    ResourceMark rm(THREAD);
    tty->print_cr("[PROBE][vtable] #%d resolved=%s::%s"
                  " recv_klass=%s vtable_index=%d selected=%s::%s",
                  _vtable_probe_count,
                  resolved_method->method_holder()->external_name(),
                  resolved_method->name()->as_C_string(),
                  recv_klass != NULL ? recv_klass->external_name() : "null",
                  vtable_index,
                  selected_method.is_null() ? "null" : selected_method->method_holder()->external_name(),
                  selected_method.is_null() ? "null" : selected_method->name()->as_C_string());
  }
}
// ===== [PROBE END] =====
```

### 3.3 实际验证输出（已验证 ✅）

#### 3.3.1 前 50 次解析详情

```
[PROBE][MethodInvoke] #1  bytecode=invokestatic  kind=direct  resolved=java.lang.Object::registerNatives          index=-2
[PROBE][MethodInvoke] #2  bytecode=invokespecial kind=direct  resolved=java.lang.String$CaseInsensitiveComparator::<init> index=-2
[PROBE][MethodInvoke] #3  bytecode=invokespecial kind=direct  resolved=java.lang.Object::<init>                  index=-2
[PROBE][MethodInvoke] #4  bytecode=invokestatic  kind=direct  resolved=java.lang.System::registerNatives         index=-2
[PROBE][MethodInvoke] #5  bytecode=invokestatic  kind=direct  resolved=java.lang.Class::registerNatives          index=-2
[PROBE][MethodInvoke] #8  bytecode=invokevirtual kind=direct  resolved=java.lang.ThreadGroup::checkAccess         index=-2
[PROBE][MethodInvoke] #11 bytecode=invokevirtual kind=direct  resolved=java.lang.ThreadGroup::add                index=-2
[PROBE][MethodInvoke] #19 bytecode=invokevirtual kind=vtable  resolved=java.lang.ThreadGroup::addUnstarted        index=13
[PROBE][MethodInvoke] #22 bytecode=invokevirtual kind=vtable  resolved=java.lang.Thread::getContextClassLoader    index=12
```

#### 3.3.2 vtable 探针详情（多态分派验证）

```
[PROBE][vtable] #4  resolved=java.lang.ThreadGroup::addUnstarted  recv_klass=java.lang.ThreadGroup  vtable_index=13  selected=java.lang.ThreadGroup::addUnstarted
[PROBE][vtable] #7  resolved=java.lang.Thread::getContextClassLoader  recv_klass=java.lang.Thread  vtable_index=12  selected=java.lang.Thread::getContextClassLoader
[PROBE][vtable] #18 resolved=java.lang.Runtime::availableProcessors  recv_klass=java.lang.Runtime  vtable_index=13  selected=java.lang.Runtime::availableProcessors
```

#### 3.3.3 call_kind 分布统计（JVM 完整启动过程）

```
[PROBE][MethodInvoke] total=100   direct=96    vtable=3     itable=1
[PROBE][MethodInvoke] total=1000  direct=844   vtable=122   itable=34
[PROBE][MethodInvoke] total=4000  direct=3164  vtable=614   itable=222
[PROBE][MethodInvoke] total=8000  direct=3533  vtable=4118  itable=349
[PROBE][MethodInvoke] total=14500 direct=4378  vtable=9709  itable=413
```

#### 3.3.4 验证结论分析

**结论 1：JVM 启动早期 direct_call 占绝对主导（96%）**

前 100 次解析中 direct=96，vtable=3，itable=1。原因：
- JVM 启动时大量调用 `registerNatives()`（invokestatic → direct）
- 大量 `<init>` 构造方法（invokespecial → direct）
- `ThreadGroup`/`Thread` 初始化时调用 final 方法（invokevirtual + final → direct）
- **关键发现**：`invokevirtual` 字节码不一定是 vtable_call！`ThreadGroup::checkAccess` 是 final 方法，虽然字节码是 `invokevirtual`，但 call_kind = direct（index=-2）

**结论 2：稳定运行后 vtable_call 成为主流（~67%）**

到 total=14500 时：direct=4378（30%），vtable=9709（67%），itable=413（3%）。
- 应用代码中大量普通虚方法调用（如集合操作、IO 操作）
- vtable_call 比例随运行时间增长，说明应用层代码比启动代码更多态

**结论 3：vtable_index 实际值范围（12~13）**

```
ThreadGroup::addUnstarted   → vtable_index=13
Thread::getContextClassLoader → vtable_index=12
Runtime::availableProcessors  → vtable_index=13
```
- vtable 前 12 个槽位被 `Object` 的方法占据（hashCode/equals/clone/toString 等）
- 第 12、13 位是各类的第一个自定义虚方法
- **验证了 vtable 索引稳定性**：`recv_klass` 和 `resolved_klass` 相同时，`selected_method` 就是 `resolved_method`（无多态发生）

**结论 4：index=-2 是 final 方法的标志**

所有 `kind=direct` 的条目 `index=-2`，对应 `Method::nonvirtual_vtable_index`，cpCache 的 `_f2` 存储 `Method*` 而非 vtable 索引。

---

## 第 4 部分：数据结构关系图

```mermaid
graph TB
    subgraph Method["Method（类加载时创建）"]
        M1["_vtable_index\n虚方法：≥0\nfinal方法：-2（nonvirtual）\n非虚方法：-1（invalid）"]
        M2["_method_holder\n声明此方法的 InstanceKlass"]
    end

    subgraph LinkInfo["LinkInfo（栈对象，解析期间）"]
        LI1["_name: 方法名 Symbol*"]
        LI2["_signature: 签名 Symbol*"]
        LI3["_resolved_klass: 声明类"]
        LI4["_current_klass: 调用方类"]
    end

    subgraph CallInfo["CallInfo（栈对象，解析期间）"]
        CI1["_resolved_klass: 静态类型"]
        CI2["_selected_klass: 动态类型"]
        CI3["_resolved_method: 声明类方法"]
        CI4["_selected_method: 实际执行方法"]
        CI5["_call_kind: direct/vtable/itable"]
        CI6["_call_index: vtable/itable 索引"]
    end

    subgraph CPCacheEntry["ConstantPoolCacheEntry（Metaspace，持久）"]
        CP1["_indices: [b2|b1|cp_index]"]
        CP2["_f1: Method*(direct) 或 Klass*(itable)"]
        CP3["_f2: vtable_index 或 final Method*"]
        CP4["_flags: [tos|F|f|v|vf|psize]"]
    end

    subgraph vtable["InstanceKlass.vtable（类加载时构建）"]
        VT1["vtable[0]: Object.hashCode"]
        VT2["vtable[1]: Object.equals"]
        VT3["vtable[n]: 子类覆盖的方法"]
    end

    LinkInfo --> CallInfo
    CallInfo --> CPCacheEntry
    CPCacheEntry --> |"_f2 = vtable_index"| vtable
    Method --> |"_vtable_index"| vtable
    vtable --> |"method_at_vtable(index)"| Method
```

---

## 第 5 部分：总结

### 5.1 数据结构层面

| 结构 | 核心特征 |
|------|---------|
| `CallInfo` | 解析结果容器，区分 resolved（静态）和 selected（动态）两个维度 |
| `LinkInfo` | 解析输入，从常量池提取符号引用，生命周期极短（仅解析期间） |
| `ConstantPoolCacheEntry` | 32 bytes，`_f2` 存 vtable 索引，`b2` 最后写入保证可见性 |
| `ConstantPoolCache` | 每个 ConstantPool 一个，与 ConstantPool 分离（只读 vs 可写） |

### 5.2 算法层面

| 算法 | 核心设计决策 |
|------|------------|
| 两阶段解析 | 链接时找 vtable 索引（不依赖接收者），运行时查 vtable（依赖接收者），分离关注点 |
| cpCache 并发安全 | `b2` 最后写入（内存屏障），`is_resolved()` 检查 b2，保证不读半初始化状态 |
| final 方法优化 | `vtable_index = -2`，`_f2` 存 `Method*`，跳过 vtable 查找，比普通虚方法快一次内存访问 |
| 多态分派 | `recv_klass->method_at_vtable(vtable_index)`，同一索引在不同子类中指向不同实现 |

### 5.3 核心要点

1. **cpCache 是解析结果缓存**：每个 invoke 字节码对应一个 `ConstantPoolCacheEntry`，首次调用解析后缓存 vtable 索引，后续调用直接查表
2. **两阶段解析**：链接时（linktime）找 vtable 索引，运行时（runtime）用索引查 vtable，实现多态
3. **vtable 索引稳定性**：同一虚方法在所有子类 vtable 中占相同位置，这是 O(1) 多态分派的基础
4. **final 方法特殊路径**：`vtable_index = -2`，直接缓存 `Method*`，跳过 vtable 查找
5. **并发安全**：`b2` 字段最后写入，是 cpCache 初始化完成的原子标志

---

*文档状态：✅ 全部完成（数据结构 + 算法 + 插桩验证）*
*插桩文件：`src/hotspot/share/interpreter/interpreterRuntime.cpp`*
*           `src/hotspot/share/interpreter/linkResolver.cpp`*
*验证时间：2026-03-05，标准环境 `-Xms8g -Xmx8g -XX:+UseG1GC -Xint`*
