# 10.1 ELF 符号解析 + CodeCache + frameName

> 源文件: `symbols_linux.cpp` (882行), `codeCache.cpp` (328行), `frameName.cpp` (404行), `demangle.cpp` (103行)
> 关联: `profiler.cpp` (符号查找入口), `dwarf.cpp` (DWARF 信息解析)
> 前置章节: 9.1 GOT/PLT Patching (CodeCache 的 import 部分已介绍)

---

## 核心问题

async-profiler 在信号处理器中采集到一个 PC 地址（如 `0x7ffff64f6bb3`），最终需要在火焰图中显示为可读的帧名（如 `libjvm.so`LinkResolver::resolve_field`）。这个 **"PC → 帧名"** 的转换链路涉及：

1. **ELF 解析**：解析 `/proc/self/maps` + 每个 .so 的 ELF 符号表
2. **CodeCache 存储**：将符号按地址排序，支持 O(log n) 二分查找
3. **FrameName 格式化**：将 mangled 符号名 demangle + 格式化为最终帧名

**问题**：为什么不用 `dladdr()` 直接查？因为 `dladdr()` 只能查 `.dynsym`（动态符号表），找不到静态函数。async-profiler 需要解析 `.symtab` + 外部 debuginfo 文件，才能获得**所有函数名**（包括 static 函数和内联函数）。

---

## 一、Symbols::parseLibraries — 库发现与解析总入口

### 1.1 整体流程

```
Profiler::updateSymbols()
        │
        ▼
Symbols::parseLibraries(array, kernel_symbols)
        │
        ├─① 解析内核符号 (/proc/kallsyms)
        │
        ├─② collectSharedLibraries()
        │     └─ 解析 /proc/self/maps → 收集所有 .so 的 {file, map_start, map_end, image_base}
        │
        └─③ 对每个新库:
              ├─ ElfParser::parseFile()      → 从磁盘 mmap ELF，加载 .symtab 符号
              ├─ ElfParser::parseProgramHeaders() → 从内存中解析 PT_DYNAMIC (.dynsym + GOT)
              │                                     → 解析 PT_GNU_EH_FRAME (DWARF)
              ├─ cc->sort()                  → 按地址排序符号数组
              ├─ applyPatch(cc)              → JDK 8 poll() 热修复
              └─ array->add(cc)              → 添加到全局 CodeCacheArray
```

### 1.2 collectSharedLibraries — 解析 /proc/self/maps

```cpp
static void collectSharedLibraries(std::unordered_map<u64, SharedLibrary>& libs, int max_count) {
    FILE* f = fopen("/proc/self/maps", "r");

    while (max_count > 0 && (len = getline(&str, &str_size, f)) > 0) {
        MemoryMapDesc map(str);
        if (!map.isReadable() || map.file() == NULL) continue;

        u64 inode = u64(map.dev()) << 32 | map.inode();
        if (_parsed_inodes.find(inode) != _parsed_inodes.end()) {
            continue;  // 已解析过的库跳过（增量发现）
        }

        if (map.isExecutable()) {
            SharedLibrary& lib = libs[inode];
            lib.file = strdup(map.file());
            lib.map_start = map_start;
            lib.map_end = map_end;
            lib.image_base = image_base;  // 第一个 LOAD 段的映射地址
        }
    }
}
```

**/proc/self/maps 格式**：

```
地址范围              权限  偏移     设备   inode    文件名
7ffff7800000-7ffff7808000 r--p 00000000 fd:01 12345678 /usr/lib64/libc.so.6
7ffff7808000-7ffff79a0000 r-xp 00008000 fd:01 12345678 /usr/lib64/libc.so.6
7ffff79a0000-7ffff79e8000 r--p 001a0000 fd:01 12345678 /usr/lib64/libc.so.6
```

**关键设计**：
- **inode 去重**：同一个 .so 文件可能有多个映射段（r--p, r-xp, rw-p），用 `dev:inode` 唯一标识
- **增量发现**：`_parsed_inodes` 集合记录已解析的库，避免重复解析
- **image_base 识别**：第一个 `offset == 0` 的映射就是 ELF 文件头所在的段
- **MAX_NATIVE_LIBS = 2048**：最多支持 2048 个共享库

### 1.3 parseKernelSymbols — 内核符号解析

```cpp
void Symbols::parseKernelSymbols(CodeCache* cc) {
    // 优先通过 fdtransfer 获取（容器/安全环境）
    if (FdTransferClient::hasPeer()) {
        fd = FdTransferClient::requestKallsymsFd();
    } else {
        fd = open("/proc/kallsyms", O_RDONLY);
    }

    while (fgets(str, sizeof(str) - 8, f) != NULL) {
        strcpy(str + len, "_[k]");  // 追加 _[k] 后缀标识内核符号

        SymbolDesc symbol(str);
        if (type == 'T' || type == 't' || type == 'W' || type == 'w') {
            cc->add(addr, 0, symbol.name());
        }
    }
}
```

**`_[k]` 后缀**：内核符号名后追加 `_[k]`，这样在火焰图中可以通过后缀区分用户态和内核态帧。

---

## 二、ElfParser — ELF 文件解析引擎

### 2.1 两种解析模式

| 方法 | 数据来源 | 解析内容 | 何时使用 |
|------|---------|---------|---------|
| `parseFile()` | 磁盘文件 (mmap) | `.symtab` + `.strtab` + debuginfo | 静态符号（所有函数） |
| `parseProgramHeaders()` | 内存映射 | PT_DYNAMIC (`.dynsym` + GOT) + PT_GNU_EH_FRAME | 动态符号 + DWARF CFI |

**为什么两种都要？**
- `parseFile()` 可以读取 `.symtab`（完整符号表），包含 static 函数
- `parseProgramHeaders()` 读取内存中已加载的 Program Headers，获取 GOT 表（用于 hook）和 DWARF 信息（用于栈回溯）

### 2.2 parseFile — 从磁盘加载符号

```cpp
bool ElfParser::parseFile(CodeCache* cc, const char* base, const char* file_name, bool use_debug) {
    int fd = open(file_name, O_RDONLY);
    size_t length = lseek(fd, 0, SEEK_END);
    void* addr = mmap(NULL, length, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);

    ElfParser elf(cc, base, addr, file_name, false);
    if (elf.validHeader()) {
        elf.calcVirtualLoadAddress();
        elf.loadSymbols(use_debug);
    }
    munmap(addr, length);
    return true;
}
```

**关键步骤**：
1. `mmap` 整个 ELF 文件到内存（只读、私有映射）
2. `calcVirtualLoadAddress()`：计算 `_vaddr_diff = base - PT_LOAD.p_vaddr`
3. `loadSymbols()`：加载符号表

### 2.3 calcVirtualLoadAddress — 虚拟地址差值计算

```
ELF 文件中的虚拟地址:  PT_LOAD.p_vaddr = 0x0000 (位置无关代码)
实际加载到内存的地址:  base = 0x7ffff7800000

→ _vaddr_diff = 0x7ffff7800000 - 0x0000 = 0x7ffff7800000
→ 符号的实际地址 = _vaddr_diff + sym.st_value
```

**为什么 ET_EXEC 类型的差值是 0？** 可执行文件（ET_EXEC）的虚拟地址是绝对地址，已经是最终地址。只有共享库（ET_DYN）需要加 base。

### 2.4 loadSymbols — 符号加载策略

```
尝试顺序（优先级从高到低）：

① .symtab 存在？
   → 直接从 .symtab 加载完整符号表 ✅ 最佳结果
   
② 尝试 debuginfo 文件（通过 Build-ID）:
   → /usr/lib/debug/.build-id/ab/cdef1234.debug
   → ~/.cache/debuginfod_client/abcdef1234/debuginfo
   
③ 尝试 debuginfo 文件（通过 .gnu_debuglink 节）:
   → /path/to/libfoo.so.debug
   → /path/to/.debug/libfoo.so.debug
   → /usr/lib/debug/path/to/libfoo.so.debug

④ 都找不到？
   → 退化为只用 .dynsym（通过 parseDynamicSection 已加载）
```

### GDB 验证 — debuginfo 搜索链路

```
=== ElfParser::parseFile ===                                         ✅
file_name = /usr/lib64/libz.so.1.2.13, base = 0x..., use_debug = 1

→ .symtab 未找到，尝试 debuginfo:
  ① /usr/lib/debug/.build-id/a0/f6824223564656a5ff3d3144f9a1452e989b25.debug  ← 不存在
  ② ~/.cache/debuginfod_client/a0f6.../debuginfo                               ← 不存在
  ③ /usr/lib64/libz.so.1.2.13-1.2.13-9.tl4.x86_64.debug                      ← 不存在
  ④ /usr/lib64/.debug/libz.so.1.2.13-1.2.13-9.tl4.x86_64.debug               ← 不存在
→ 退化为 .dynsym
```

### 2.5 loadSymbolTable — 符号表解析

```cpp
void ElfParser::loadSymbolTable(const char* symbols, size_t total_size, 
                                size_t ent_size, const char* strings) {
    const char* base = this->base();
    for (const char* sym_end = symbols + total_size; symbols < sym_end; symbols += ent_size) {
        ElfSymbol* sym = (ElfSymbol*)symbols;
        if (sym->st_name != 0 && sym->st_value != 0) {
            // 跳过 AArch64 特殊映射符号: $x 和 $d
            if (sym->st_size != 0 || sym->st_info != 0 || strings[sym->st_name] != '$') {
                _cc->add(base + sym->st_value, (int)sym->st_size, strings + sym->st_name);
            }
        }
    }
}
```

**ElfSymbol 结构（Elf64_Sym）**：

```
偏移   字段         大小    含义
0x00   st_name      4      字符串表中的偏移
0x04   st_info      1      类型 + 绑定信息
0x05   st_other     1      可见性
0x06   st_shndx     2      所在节的索引
0x08   st_value     8      符号地址（虚拟地址）
0x10   st_size      8      符号大小（字节）
总大小: 24 bytes
```

### 2.6 parseDynamicSection — 动态节解析

这个方法同时完成两个任务：

**任务 1：加载 .dynsym 动态符号表**

```cpp
if (!_cc->hasDebugSymbols() && nsyms > 0) {
    loadSymbolTable(symtab, syment * nsyms, syment, strtab);
}
```

只有在没有 debug 符号时才从 `.dynsym` 加载（`.symtab` 是 `.dynsym` 的超集）。

**任务 2：收集 GOT 表条目（用于 hook）**

```cpp
// 解析 .rela.plt 表（PLT 跳转重定位）
for (size_t offs = 0; offs < pltrelsz; offs += relent) {
    ElfRelocation* r = (ElfRelocation*)(jmprel + offs);
    ElfSymbol* sym = (ElfSymbol*)(symtab + ELF_R_SYM(r->r_info) * syment);
    _cc->addImport((void**)(base + r->r_offset), strtab + sym->st_name);
}

// 解析 .rela.dyn 表（-fno-plt 模式下的全局数据重定位）
for (size_t offs = relcount * relent; offs < relsz; offs += relent) {
    ElfRelocation* r = (ElfRelocation*)(rel + offs);
    if (ELF_R_TYPE(r->r_info) == R_GLOB_DAT || ELF_R_TYPE(r->r_info) == R_ABS64) {
        _cc->addImport((void**)(base + r->r_offset), strtab + sym->st_name);
    }
}
```

**r->r_offset** 就是 GOT 表中函数指针的位置。`addImport` 记录这个位置，后续 `patchImport` 就是修改这个位置。

### 2.7 addRelocationSymbols — PLT 桩合成

```cpp
void ElfParser::addRelocationSymbols(ElfSection* reltab, const char* plt) {
    for (; relocations < relocations_end; relocations += reltab->sh_entsize) {
        snprintf(name, sizeof(name), "%s%cplt", sym_name,
                 sym_name[0] == '_' && sym_name[1] == 'Z' ? '.' : '@');
        _cc->add(plt, PLT_ENTRY_SIZE, name);
        plt += PLT_ENTRY_SIZE;
    }
}
```

**PLT 桩命名规则**：
- C++ mangled 函数（`_Z...`）：用 `.plt` 后缀（如 `_ZN5Bytes11get_Java_u2EPh.plt`）
- 普通 C 函数：用 `@plt` 后缀（如 `malloc@plt`）

这让火焰图能区分 PLT 跳板调用和真正的函数体。

### 2.8 musl vs glibc 的 GOT 重定位差异

```cpp
char* dyn_ptr(ElfDyn* dyn) {
    // GNU 动态链接器会重定位 dynamic section 中的指针
    // 而 musl 不会。另外 [vdso] 也不会被重定位
    if (_relocate_dyn || (char*)dyn->d_un.d_ptr < _base) {
        return (char*)_vaddr_diff + dyn->d_un.d_ptr;
    } else {
        return (char*)dyn->d_un.d_ptr;
    }
}
```

---

## 三、CodeCache — 符号缓存与二分查找

### 3.1 设计思想

**问题**：每次采样都需要将 PC 地址转为符号名。libjvm.so 有 **40 万+** 个符号，如何快速查找？

**方案**：将所有符号按起始地址排序，用二分查找实现 O(log n) 定位。

### 3.2 核心数据结构

```
CodeCache
├── _name: char*          → 库名（如 "/lib64/libc.so.6"）
├── _lib_index: short     → 在 CodeCacheArray 中的索引
├── _min_address / _max_address  → 地址范围（快速排除）
├── _text_base / _image_base     → ELF 基地址信息
├── _plt_offset / _plt_size      → PLT 节的位置和大小
├── _imports[14][2]       → GOT 表条目指针（见 Part 9）
├── _dwarf_table[]        → DWARF CFI 帧描述表（见 Part 5）
└── _blobs[]: CodeBlob[]  → 符号数组（按地址排序）
       ├── _start: void*    → 符号起始地址
       ├── _end: void*      → 符号结束地址
       └── _name: char*     → 指向 NativeFunc 的 _name 字段
```

### 3.3 NativeFunc — 带元数据的符号名

**问题**：符号名不仅仅是字符串——还需要携带额外信息（属于哪个库？是解释器还是编译代码？）。

**方案**：在符号名字符串前面附加一个 4 字节的头部：

```
NativeFunc 内存布局 (sizeof = 4 bytes):
偏移   字段         大小    含义
0x00   _lib_index   2      所属库在 CodeCacheArray 中的索引
0x02   _mark        1      标记位（见下方枚举）
0x03   _reserved    1      保留（对齐）
0x04   _name[0]     可变    C 字符串（符号名）

→ CodeBlob._name 指向 _name[0]，可以直接当 char* 使用
→ NativeFunc::from(name) = name - 4，可以反向访问头部
```

**Mark 枚举**：

| 值 | 名称 | 含义 |
|----|------|------|
| 1 | MARK_VM_RUNTIME | JVM 运行时代码（不应出现在火焰图中） |
| 2 | MARK_INTERPRETER | 解释器桩代码 |
| 3 | MARK_COMPILER_ENTRY | JIT 编译器入口 |
| 4 | MARK_ASYNC_PROFILER | async-profiler 自身的 hook 代码 |

### GDB 验证 — NativeFunc

```
=== NativeFunc::create ===                                           ✅
name = [stubs], lib_index = -1
sizeof(NativeFunc) = 4                                               ← 4 字节头
result ptr = 0x7ffff002b2c4                                          ← 返回的是 _name[0] 的地址

→ [stubs] 是 Profiler 的运行时桩 CodeCache
→ lib_index = -1 表示不属于任何共享库
```

### 3.4 binarySearch — O(log n) 符号查找

```cpp
const char* CodeCache::binarySearch(const void* address) {
    int low = 0;
    int high = _count - 1;

    while (low <= high) {
        int mid = (unsigned int)(low + high) >> 1;
        if (_blobs[mid]._end <= address) {
            low = mid + 1;
        } else if (_blobs[mid]._start > address) {
            high = mid - 1;
        } else {
            return _blobs[mid]._name;   // 命中！
        }
    }

    // 特殊情况：零大小符号（ASM 入口）或 return 地址恰好在函数末尾
    if (low > 0 && (_blobs[low-1]._start == _blobs[low-1]._end || _blobs[low-1]._end == address)) {
        return _blobs[low - 1]._name;
    }
    return _name;  // 未找到，返回库名
}
```

**零大小符号的处理**：汇编入口点（如 JVM 解释器的 dispatch table 入口）在 ELF 中大小为 0。如果不做特殊处理，它们永远无法被 binarySearch 命中。

### GDB 验证 — binarySearch

```
=== CodeCache::binarySearch ===                                      ✅
this._name = /data/workspace/.../libjvm.so
address = 0x7ffff5b6f97d
_count = 400659, _min = 0x7ffff5906000, _max = 0x7ffff6a97000
result = _ZN16typeArrayOopDesc14element_offsetIaEEli

→ libjvm.so 包含 400,659 个符号
→ 地址范围: 0x7ffff5906000 ~ 0x7ffff6a97000 (约 17.5MB)
→ 二分查找在 ~19 次比较内完成（log2(400659) ≈ 18.6）
```

### 3.5 CodeCacheArray — 全局库数组

```cpp
class CodeCacheArray {
    CodeCache* _libs[MAX_NATIVE_LIBS];  // 最多 2048 个库
    int _count;                          // 当前库数量
    size_t _used_memory;                 // 总内存占用

    void add(CodeCache* lib) {
        int index = __atomic_load_n(&_count, __ATOMIC_ACQUIRE);
        _libs[index] = lib;
        _used_memory += lib->usedMemory();
        __atomic_store_n(&_count, index + 1, __ATOMIC_RELEASE);
    }
};
```

**无锁的 add**：`_count` 使用 `acquire/release` 语义的原子操作。读者通过 `acquire` 读取 `_count`，确保能看到 `_libs[index]` 的完整初始化。这允许信号处理器在不持锁的情况下安全读取已有库。

### 3.6 findLibraryByAddress — 线性扫描

```cpp
CodeCache* Profiler::findLibraryByAddress(const void* address) {
    const int native_lib_count = _native_libs.count();
    for (int i = 0; i < native_lib_count; i++) {
        if (_native_libs[i]->contains(address)) {
            return _native_libs[i];
        }
    }
    return NULL;
}
```

**为什么不用二分？** 库的数量通常只有几十个（典型 Java 应用 20-50 个），线性扫描足够快。每个库的 `contains()` 只是两次指针比较。

### 3.7 resolveSymbol — 按名称查找符号

```cpp
const void* Profiler::resolveSymbol(const char* name) {
    // 支持 C++ 命名空间语法: "ClassName::method" → "_ZN9ClassName6methodE*"
    if (strstr(name, "::") != NULL) {
        mangle(name, mangled_name, sizeof(mangled_name));
        name = mangled_name;
    }

    // 支持通配符: "ThreadStart*" 匹配所有以 ThreadStart 开头的符号
    if (name[len - 1] == '*') {
        for (int i = 0; i < native_lib_count; i++) {
            const void* address = _native_libs[i]->findSymbolByPrefix(name, len - 1);
            if (address != NULL) return address;
        }
    } else {
        for (int i = 0; i < native_lib_count; i++) {
            const void* address = _native_libs[i]->findSymbol(name);
            if (address != NULL) return address;
        }
    }
    return NULL;
}
```

**VMStructs 大量使用 resolveSymbol** 来查找 JVM 内部函数地址（如 `Unsafe_Park`、`ThreadStart`），以此进行偏移量推断。

---

## 四、FrameName — 帧名称格式化引擎

### 4.1 设计思想

**问题**：采样得到的帧有多种类型——Native 帧（PC 地址 → 符号名）、Java 帧（jmethodID → 类名.方法名）、特殊帧（线程 ID、分配信息、锁信息）。需要一个统一的格式化器。

**方案**：`FrameName::name(ASGCT_CallFrame& frame)` 根据 `frame.bci` 的特殊值进行分发。

### 4.2 BCI 特殊值（帧类型标识）

```
BCI 值              含义                  method_id 的实际内容
──────────────────────────────────────────────────────────────
BCI_NATIVE_FRAME    原生帧               char* (mangled 符号名)
BCI_ALLOC           TLAB 内分配           类名索引
BCI_ALLOC_OUTSIDE   TLAB 外分配           类名索引
BCI_LOCK            锁争用               锁对象类名索引
BCI_PARK            Park 等待            Park 对象类名索引
BCI_THREAD_ID       线程标识帧            int (线程 tid)
BCI_ADDRESS         裸地址帧             void* (地址)
BCI_ERROR           错误帧               char* (错误信息)
BCI_CPU             CPU 标识帧            int (CPU 编号)
>=0                 正常 Java 帧          jmethodID (Java 方法)
```

### 4.3 name() — 统一分发

```cpp
const char* FrameName::name(ASGCT_CallFrame& frame, bool for_matching) {
    switch (frame.bci) {
        case BCI_NATIVE_FRAME:
            return decodeNativeSymbol((const char*)frame.method_id);
            // → C++/Rust demangle + 可选库名前缀

        case BCI_ALLOC / BCI_LOCK / BCI_PARK:
            javaClassName(symbol, strlen(symbol), _style | STYLE_DOTTED);
            // → "java/lang/Object" → "java.lang.Object"

        case BCI_THREAD_ID:
            // → "[main tid=1]"

        default:  // Java 方法
            javaMethodName(frame.method_id);
            // → JVMTI 查询 → "java.lang.Thread.sleep"
    }
}
```

### 4.4 decodeNativeSymbol — C++/Rust 符号解码

```cpp
const char* FrameName::decodeNativeSymbol(const char* name) {
    // 1. 获取库名（可选）
    const char* lib_name = (_style & STYLE_LIB_NAMES) ? getLibraryName(name) : NULL;

    // 2. Demangle
    if (Demangle::needsDemangling(name)) {
        char* demangled = Demangle::demangle(name, _style & STYLE_SIGNATURES);
        // → "libjvm.so`Bytes::get_Java_u2"
    }

    // 3. 如果 demangle 失败，保留原始 mangled 名
    return name;
}
```

**getLibraryName 的实现**：通过 `NativeFunc::libIndex(name)` 获取符号所属库的索引（存在符号名前 4 字节的头部中），然后从 `_native_libs[lib_index]` 取库名的最后一段（如 `libjvm.so`）。

### GDB 验证 — Demangle

```
=== Demangle::demangle ===                                           ✅
mangled  = _ZN5Bytes11get_Java_u2EPh
demangled = Bytes::get_Java_u2

→ C++ ABI demangle 成功
→ 默认不保留参数签名 (full_signature = false)
→ cutArguments() 会去掉 "(unsigned char*)" 部分
```

### 4.5 javaMethodName — Java 方法名解析

```cpp
void FrameName::javaMethodName(jmethodID method) {
    // 1. 检查是否是过期的 jmethodID
    if (VMMethod::isStaleMethodId(method)) {
        _str.assign("[stale_jmethodID]");
        return;
    }

    // 2. JVMTI 查询三步
    jvmti->GetMethodName(method, &method_name, &method_sig, NULL);
    jvmti->GetMethodDeclaringClass(method, &method_class);
    jvmti->GetClassSignature(method_class, &class_name, NULL);

    // 3. 格式化
    // class_name = "Ljava/lang/Thread;" → trim → "java/lang/Thread"
    javaClassName(class_name + 1, strlen(class_name) - 2, _style);
    _str.append(".").append(method_name);
    // → "java.lang.Thread.sleep" (STYLE_DOTTED)
    // → "java/lang/Thread.sleep" (默认)
}
```

**JMethodCache 缓存**：JVMTI 查询很慢（需要跨线程通信），所以 FrameName 维护一个 `map<jmethodID, string>` 缓存。缓存条目带 epoch 标记，过期的条目在 FrameName 析构时清理。

```cpp
JMethodCache::iterator it = _cache.lower_bound(frame.method_id);
if (it != _cache.end() && it->first == frame.method_id) {
    it->second[0] = _cache_epoch;  // 刷新缓存时间戳
    return it->second.c_str() + 1; // 跳过第 1 字节（epoch）
}

// Cache miss → 调用 JVMTI → 插入缓存
javaMethodName(frame.method_id);
_cache.insert(it, {frame.method_id, std::string(1, _cache_epoch) + _str});
```

### 4.6 Demangle 实现

```
Demangle::demangle(s, full_signature)
    │
    ├── isRustSymbol(s)?
    │     ├── "_R" 开头 → Rust V0 编码 → rust_demangle_display_demangle()
    │     └── "_ZN...17h[hex]E" → Rust legacy 编码 → rust_demangle_display_demangle()
    │
    └── demangleCpp(s)
          ├── abi::__cxa_demangle(s)  → 标准 C++ ABI demangle
          │
          └── 失败? → 尝试去掉 ".part.123" 后缀重试
                      （编译器优化可能添加的后缀）
    
    如果 !full_signature:
        cutArguments(result)  → 删除参数列表 "(int, char*)"
```

### 4.7 STYLE 位标志

| 标志 | 值 | 效果 | 示例 |
|------|---|------|------|
| STYLE_DOTTED | 1 | `/` → `.` | `java.lang.Thread.sleep` |
| STYLE_SIMPLE | 2 | 删除包名 | `Thread.sleep` |
| STYLE_SIGNATURES | 4 | 保留签名 | `Thread.sleep(J)V` |
| STYLE_ANNOTATE | 8 | 添加帧类型后缀 | `Thread.sleep_[0]` (解释器) |
| STYLE_LIB_NAMES | 16 | 添加库名前缀 | `libjvm.so`LinkResolver::resolve_field` |
| STYLE_NORMALIZE | 32 | 去除匿名类编号 | `Foo$1` → `Foo` |
| STYLE_NO_SEMICOLON | 64 | 替换分号 | `(Ljava/lang/String|)V` |

### 4.8 Matcher — 帧过滤器

```
支持 4 种模式:
  "exact"    → MATCH_EQUALS      → 精确匹配
  "*suffix"  → MATCH_ENDS_WITH   → 后缀匹配
  "prefix*"  → MATCH_STARTS_WITH → 前缀匹配
  "*middle*" → MATCH_CONTAINS    → 子串匹配
```

用于 `--include` / `--exclude` 参数，过滤火焰图中的帧。

---

## 五、完整的 PC → 帧名 解析链路

```
信号处理器中采样到 PC 地址
        │
        ▼
Profiler::findLibraryByAddress(pc)
→ 线性扫描 _native_libs[]，找到包含该 PC 的 CodeCache
        │
        ▼
CodeCache::binarySearch(pc)
→ 在排序的 _blobs[] 数组中二分查找
→ 返回 mangled 符号名（如 "_ZN12LinkResolver13resolve_fieldE..."）
        │
        ▼
存入 ASGCT_CallFrame { bci = BCI_NATIVE_FRAME, method_id = mangled_name }
        │
        ▼ (输出阶段)
FrameName::name(frame)
→ case BCI_NATIVE_FRAME: decodeNativeSymbol(name)
        │
        ├── NativeFunc::libIndex(name) → lib_index → 库名 "libjvm.so"
        │
        ├── Demangle::demangle("_ZN12LinkResolver...") → "LinkResolver::resolve_field"
        │
        └── 拼接 → "libjvm.so`LinkResolver::resolve_field"

对于 Java 帧：
信号处理器中 ASGCT 返回 jmethodID
        │
        ▼
存入 ASGCT_CallFrame { bci = 42, method_id = jmethodID }
        │
        ▼ (输出阶段)
FrameName::name(frame)
→ default case: javaMethodName(method)
        │
        ├── 检查 JMethodCache 缓存 → 命中? → 直接返回
        │
        └── Cache miss:
            ├── JVMTI::GetMethodName → "sleep"
            ├── JVMTI::GetMethodDeclaringClass → class
            ├── JVMTI::GetClassSignature → "Ljava/lang/Thread;"
            └── 格式化 → "java.lang.Thread.sleep"
```

---

## 六、UnloadProtection — 库卸载保护

### 6.1 问题

在解析 ELF Program Headers 时，async-profiler 读取的是**内存中已映射的 .so**。如果此时另一个线程调用了 `dlclose()` 卸载这个库，内存映射失效 → **段错误**。

### 6.2 解决方案

```cpp
UnloadProtection::UnloadProtection(const CodeCache* cc) {
    if (OS::isMusl() || isMainExecutable(...) || isLoader(...)) {
        _valid = true;  // 这些库永远不会被卸载
        return;
    }

    // dlopen(RTLD_NOLOAD) 增加引用计数但不重新加载
    _lib_handle = dlopen(stripped_name, RTLD_LAZY | RTLD_NOLOAD);
    // 验证基地址未变（排除同名不同库的情况）
    _valid = _lib_handle != NULL && verifyBaseAddress(cc, _lib_handle);
}

UnloadProtection::~UnloadProtection() {
    if (_lib_handle != NULL) {
        dlclose(_lib_handle);  // 析构时释放引用
    }
}
```

**RAII 模式**：创建 `UnloadProtection handle(cc)` → 增加引用计数 → 做完操作 → 析构函数自动 `dlclose()`。

### 6.3 "(deleted)" 文件处理

```cpp
// dlopen() 可以重新打开已删除但仍被映射的库
const char* stripped_name = cc->name();
if (name_len > 10 && strcmp(stripped_name + name_len - 10, " (deleted)") == 0) {
    // "/path/to/libfoo.so (deleted)" → "/path/to/libfoo.so"
    char* buf = stpncpy(...);
}
```

当文件被删除但进程仍在使用时，`/proc/self/maps` 中会显示 `(deleted)` 后缀。

---

## 七、applyPatch — JDK 8 poll() 热修复

```cpp
static void applyPatch(CodeCache* cc) {
    // JDK-8312065: JDK 8 的 libnet.so 使用 poll() 而非 ppoll()
    // poll() 不是 SA_RESTART 可恢复的，导致 SIGPROF 中断后 poll() 返回 EINTR
    if (patch_libnet && strcmp(cc->name() + len - 10, "/libnet.so") == 0) {
        cc->patchImport(im_poll, (void*)poll_hook);
    }
}
```

**poll_hook** 用 `ppoll()` 替代 `poll()`——`ppoll()` 是 SA_RESTART 可恢复的系统调用，不会被信号中断后返回 EINTR。

---

## 八、面试级知识点

### Q1: 为什么不用 dladdr() 而要自己解析 ELF？

`dladdr()` 只查 `.dynsym`（动态符号表），只包含**导出**的函数。但很多关键函数（如 JVM 内部的 static 函数、内联函数的 out-of-line 版本）只在 `.symtab` 中。async-profiler 需要解析 `.symtab` + 外部 debuginfo 才能获得完整的符号信息。

GDB 验证证实：libjvm.so 有 **400,659** 个符号（含 debug symbols），而 `.dynsym` 通常只有几百个。

### Q2: binarySearch 为什么要处理零大小符号？

ELF 中的 ASM 入口点（如 JVM 解释器的 dispatch table）大小为 0。标准二分查找要求 `start < end`，零大小符号 `start == end` 永远不满足 `start <= address < end`。特殊处理让这些符号仍然能被定位。

### Q3: CodeCacheArray::add 为什么不用锁？

信号处理器中不能持锁（会死锁）。`_count` 使用 `acquire/release` 原子操作：
- **写者**（`add`）：先写 `_libs[index]`，再用 `release` 写 `_count` → 保证读者看到 `_count` 时 `_libs[index]` 已完全初始化
- **读者**（信号处理器）：用 `acquire` 读 `_count` → 保证能看到已初始化的 `_libs[index]`

这是经典的 **发布-获取（release-acquire）** 模式。

### Q4: JMethodCache 为什么用 epoch 机制？

Java 类可以被卸载（Class Unloading），卸载后 `jmethodID` 变为无效。如果缓存中保留了无效的 `jmethodID`，查询 JVMTI 会返回错误。epoch 机制确保：
- 每个 profiling session 有一个 epoch 编号
- 缓存条目带 epoch 标记
- session 结束时，删除超过 `_cache_max_age` 个 epoch 未使用的条目

### Q5: debuginfo 搜索的优先级是什么？

1. `.symtab`（.so 自身）—— 最佳，包含所有符号
2. `/usr/lib/debug/.build-id/<build-id>.debug` —— 标准 debuginfo 包
3. `$DEBUGINFOD_CACHE_PATH/<build-id>/debuginfo` —— debuginfod 缓存
4. `$HOME/.cache/debuginfod_client/<build-id>/debuginfo` —— 用户本地缓存
5. `.gnu_debuglink` 指向的文件（3 个候选路径）—— 传统 debuglink

---

## 九、总结

### 符号解析系统的核心创新

1. **两阶段解析**：从磁盘加载 `.symtab`（完整符号）+ 从内存解析 PT_DYNAMIC（GOT 表 + DWARF）
2. **增量发现**：通过 inode 去重避免重复解析，新库通过 `dlopen_hook` 自动触发
3. **信号安全的查找**：排序数组 + 二分查找 + acquire/release 原子操作，在信号处理器中安全使用
4. **NativeFunc 元数据头**：4 字节头部（lib_index + mark）附着在符号名前面，零成本获取元信息
5. **多源 debuginfo**：Build-ID → debuginfod 缓存 → debuglink → fallback .dynsym

### FrameName 的核心创新

1. **BCI 编码复用**：利用 ASGCT_CallFrame.bci 的特殊值区分 13+ 种帧类型
2. **JMethodCache 缓存**：避免重复 JVMTI 查询，epoch 机制处理类卸载
3. **C++/Rust 双 demangle**：自动识别 Rust V0/legacy 编码 vs C++ ABI 编码
4. **PLT 桩合成**：为 PLT 跳板生成 `func@plt` 名称，区分直接调用和间接调用

### GDB 验证关键数据

| 验证项 | 结果 | 含义 |
|--------|------|------|
| libjvm.so 符号数量 | **400,659** | 包含 debug symbols |
| binarySearch 成功解析 | ✅ `_ZN16typeArrayOopDesc...` | O(log n) 查找工作 |
| Demangle C++ 符号 | ✅ `_ZN5Bytes11get_Java_u2EPh` → `Bytes::get_Java_u2` | ABI demangle 正确 |
| findNativeMethod 完整链路 | ✅ `0x7ffff64f6bb3` → `LinkResolver::resolve_field` | PC→符号名链路畅通 |
| debuginfo 搜索链路 | ✅ 按优先级尝试 5 个路径 | Build-ID → debuginfod → debuglink |
| sizeof(NativeFunc) | 4 bytes | 紧凑的元数据头 |

---

*创建日期: 2026-02-10*
*GDB 验证环境: OpenJDK 11 slowdebug + async-profiler v4.0*
*标准条件: -Xms8g -Xmx8g -XX:+UseG1GC -Xint*
*测试程序: SymbolDemo.java*
