# PerfDataManager::create_string_variable 源码解析

> 文件：`src/hotspot/share/runtime/perfData.cpp:422`
> 功能：创建一个字符串性能计数器（用于 jstat 等工具读取）

---

## 一、函数签名

```cpp
PerfStringVariable* PerfDataManager::create_string_variable(
    CounterNS ns,           // 命名空间，如 SUN_GC（值为5，对应"sun.gc"）
    const char* name,       // 计数器名，如 "cause"
    int max_length,         // 最大长度，如 80
    const char* s,          // 初始值，如 "No GC"
    TRAPS                   // 异常处理
)
```

**实际调用示例**：
```cpp
// collectedHeap.cpp:238
_perf_gc_cause = PerfDataManager::create_string_variable(
    SUN_GC, "cause", 80, "No GC", CHECK
);
// 创建计数器：sun.gc.cause，最大80字符，初始值"No GC"
```

---

## 二、4步核心流程

```
┌─────────────────────────────────────────────────────────────────┐
│  Step 1: 处理长度                                                │
│  ─────────────────                                               │
│  if (max_length == 0) max_length = strlen(s);                   │
│  如果传0，就按初始字符串长度自动计算                              │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│  Step 2: 创建对象（触发5层构造函数）                              │
│  ────────────────────────────────                                │
│  PerfStringVariable* p = new PerfStringVariable(ns, name,       │
│                                                  max_length, s); │
│                                                                  │
│  这行代码会依次调用5个构造函数，见下文详解                          │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│  Step 3: 检查是否创建成功                                        │
│  ───────────────────────                                         │
│  if (!p->is_valid()) {                                          │
│      delete p;                                                  │
│      THROW_0(OutOfMemoryError);                                 │
│  }                                                              │
│                                                                  │
│  is_valid() 就是判断 _valuep != NULL                              │
│  _valuep 是指向共享内存中数据区的指针                              │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│  Step 4: 注册到全局列表                                          │
│  ─────────────────────                                           │
│  add_item(p, false);                                            │
│                                                                  │
│  把对象加入 PerfDataManager 的管理列表                            │
│  false = 不需要定时采样（字符串变量不需要）                         │
└─────────────────────────────────────────────────────────────────┘
```

---

## 三、5层构造函数链（重点）

`new PerfStringVariable()` 会依次调用：

### 第1层：CHeapObj（标记分配方式）
```cpp
// 空实现，只是标记这个类用 C Heap 分配（不是 Java Heap）
CHeapObj() {}
```

### 第2层：PerfData（基类初始化）
```cpp
PerfData(CounterNS ns, const char* name, Units u, Variability v)
    : _name(NULL), _u(u), _v(v), _valuep(NULL), _on_c_heap(false) 
{
    // 1. 获取命名空间前缀，如 "sun.gc"
    const char* prefix = PerfDataManager::ns_to_string(ns);
    
    // 2. 分配内存存储完整名称 "sun.gc.cause"
    _name = NEW_C_HEAP_ARRAY(char, strlen(name) + strlen(prefix) + 2, mtInternal);
    sprintf(_name, "%s.%s", prefix, name);
    
    // 3. 设置 F_Supported 标志（根据命名空间判断接口稳定性）
    if (PerfDataManager::is_stable_supported(ns) || 
        PerfDataManager::is_unstable_supported(ns)) {
        _flags = F_Supported;
    }
}
```

### 第3层：PerfByteArray（设置长度）
```cpp
PerfByteArray(CounterNS ns, const char* name, Units u, Variability v, jint length)
    : PerfData(ns, name, u, v), _length(length) 
{
    // ★ 关键：在共享内存中创建条目
    create_entry(T_BYTE, sizeof(jbyte), (size_t)_length);
}
```

### 第4层：PerfString（设置初始值）
```cpp
PerfString(CounterNS ns, const char* name, Variability v, 
           jint length, const char* initial_value)
    : PerfByteArray(ns, name, U_String, v, length) 
{
    if (is_valid()) {
        set_string(initial_value);  // 复制字符串到共享内存
    }
}

// set_string 实现
void PerfString::set_string(const char* s2) {
    // 复制 n 字节，确保 '\0' 结尾
    strncpy((char *)_valuep, s2 == NULL ? "" : s2, _length);
    ((char*)_valuep)[_length-1] = '\0';  // 强制终止
}
```

### 第5层：PerfStringVariable（标记可变类型）
```cpp
// 只是调用父类，max_length+1 是为了存储 '\0'
PerfStringVariable(CounterNS ns, const char* name, 
                   jint max_length, const char* initial_value)
    : PerfString(ns, name, V_Variable, max_length+1, initial_value) {}
```

---

## 四、核心：create_entry 干了什么？

这是最关键的逻辑：**在共享内存中分配空间，让外部工具（jstat）能读取**

```cpp
void PerfData::create_entry(BasicType dtype, size_t dsize, size_t vlen) {
    // 1. 计算各部分大小
    size_t dlen = vlen==0 ? 1 : vlen;                    // 数据元素个数
    size_t namelen = strlen(name()) + 1;                  // 名称长度（含'\0'）
    size_t size = sizeof(PerfDataEntry) + namelen;        // 头 + 名称
    size_t pad_length = ((size % dsize) == 0) ? 0 : dsize - (size % dsize);
    size += pad_length;                                   // 对齐填充
    size_t data_start = size;                             // 数据区起始位置
    size += (dsize * dlen);                               // 加上数据区
    
    // 2. 8字节对齐
    int align = sizeof(jlong) - 1;
    size = ((size + align) & ~align);
    
    // 3. 从 PerfMemory 分配（这是共享内存！）
    char* psmp = PerfMemory::alloc(size);
    if (psmp == NULL) {
        // 共享内存满了，回退到 C Heap
        psmp = NEW_C_HEAP_ARRAY(char, size, mtInternal);
        _on_c_heap = true;
    }
    
    // 4. 计算各字段地址
    char* cname = psmp + sizeof(PerfDataEntry);          // 名称存放位置
    void* valuep = (void*)(psmp + data_start);           // 数据存放位置 ★
    
    // 5. 复制名称到共享内存
    strcpy(cname, name());
    
    // 6. 填充 PerfDataEntry 头（外部工具靠这个解析）
    PerfDataEntry* pdep = (PerfDataEntry*)psmp;
    pdep->entry_length = (jint)size;                     // 条目总长度
    pdep->name_offset = (jint)(cname - psmp);            // 名称偏移
    pdep->data_offset = (jint)data_start;                // 数据偏移 ★
    pdep->data_type = (jbyte)type2char(dtype);           // 'B' = byte
    pdep->data_units = units();                          // U_String = 5
    pdep->data_variability = variability();              // V_Variable = 3
    pdep->flags = (jbyte)flags();
    pdep->vector_length = (jint)vlen;
    
    // 7. 保存到对象
    _pdep = pdep;        // 指向共享内存中的条目头
    _valuep = valuep;    // 指向共享内存中的数据区 ★ 关键！
    
    // 8. 标记已更新
    PerfMemory::mark_updated();
}
```

---

## 五、内存布局（一目了然）

共享内存中存储的结构：

```
地址偏移    内容                    大小
─────────────────────────────────────────
0x00       ┌─────────────────┐
           │ PerfDataEntry   │      32 bytes
           │   头结构         │
0x20       ├─────────────────┤
           │ name            │      N bytes
           │ "sun.gc.cause\0" │
           ├─────────────────┤
           │ padding         │      对齐填充
           ├─────────────────┤
data_start │ data            │      max_length+1 bytes
           │ "No GC\0"       │
           ├─────────────────┤
           │ padding         │      8字节对齐
           └─────────────────┘
           总大小 = 8字节对齐
```

**C++ 对象 vs 共享内存**：

```
┌─────────────────┐         ┌─────────────────┐
│  C++ 对象       │         │  PerfMemory     │
│  (C Heap)       │         │  (共享内存)      │
├─────────────────┤         ├─────────────────┤
│ _name           │──────┐  │ PerfDataEntry   │
│   → "sun.gc..." │      │  │   头            │
│ _valuep         │──────┼──┼→ 数据区         │
│   → 0x7f8...    │      │  │   "No GC"       │
│ _pdep           │──────┘  │                 │
│   → 条目头地址   │         │                 │
│ _length = 81    │         │                 │
│ ...             │         │                 │
└─────────────────┘         └─────────────────┘
      ↑                           ↑
      │                           │
      │    jstat 等工具读取        │
      └───────────────────────────┘
```

---

## 六、关键数据结构

### PerfData（C++ 对象基类）
```cpp
class PerfData : public CHeapObj<mtInternal> {
    char* _name;              // 完整名称（C Heap分配）
    Variability _v;           // 可变性：Constant/Monotonic/Variable
    Units _u;                 // 单位：String=5
    bool _on_c_heap;          // 是否从C Heap分配（失败回退标记）
    Flags _flags;             // 标志：F_Supported
    PerfDataEntry* _pdep;     // 指向共享内存中的条目头
    void* _valuep;            // ★ 指向共享内存中的数据区
};
```

### PerfDataEntry（共享内存中的条目头）
```cpp
struct PerfDataEntry {
    jint entry_length;        // 条目总长度
    jint name_offset;         // 名称字符串偏移
    jint vector_length;       // 向量长度
    jbyte data_type;          // 数据类型：'B'=byte, 'J'=long
    jbyte data_units;         // 单位：1=None, 2=Bytes, 5=String
    jbyte data_variability;   // 可变性：1=Constant, 2=Monotonic, 3=Variable
    jbyte flags;              // 标志位
    jint data_offset;         // 数据区偏移
};  // sizeof = 32 bytes
```

---

## 七、总结

| 问题 | 答案 |
|------|------|
| 这代码是干嘛的？ | 创建 JVM 性能计数器，让 jstat 等外部工具能读取 |
| 数据存在哪？ | **共享内存**（PerfMemory），映射到文件 `/tmp/hsperfdata_<user>/<pid>` |
| 为什么分5层构造？ | 每层负责一件事：内存标记→名称分配→长度设置→数据复制→类型标记 |
| `_valuep` 是什么？ | 指向共享内存中**实际数据**的指针 |
| 创建失败怎么办？ | 共享内存满了就回退到 C Heap，通过 `_on_c_heap` 标记 |

**一句话概括**：
> `create_string_variable` 在共享内存中创建了一个条目，存储字符串值，让外部工具能读取 JVM 的运行状态（如当前 GC 原因）。
