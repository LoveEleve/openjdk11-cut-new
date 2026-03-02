# Lesson 10: 符号解析与代码缓存 深度逐行解析（方法内联展开）

> 本文档对 codeCache.cpp 和 symbols_linux.cpp 的核心实现进行深度解析，包括 ELF 解析、符号表加载、PLT/GOT Hook 等。

---

## 1. 核心数据结构概览

### 1.1 NativeFunc - Native 函数描述

```cpp
// 文件: codeCache.h 第 51-79 行

class NativeFunc {
  private:
    short _lib_index;   // 库索引（在 CodeCacheArray 中的位置）
    char _mark;         // 标记（VM_RUNTIME/INTERPRETER/COMPILER_ENTRY/ASYNC_PROFILER）
    char _reserved;     // 保留
    char _name[0];      // 柔性数组：函数名

    static NativeFunc* from(const char* name) {
        // 从函数名反推 NativeFunc 结构
        return (NativeFunc*)(name - sizeof(NativeFunc));
    }

  public:
    static char* create(const char* name, short lib_index);
    static void destroy(char* name);
    static short libIndex(const char* name) { return from(name)->_lib_index; }
    static char mark(const char* name) { return from(name)->_mark; }
    static void mark(const char* name, char value) { from(name)->_mark = value; }
};
```

**内存布局**：

```
NativeFunc 内存布局：

┌─────────────────────────────────────────────────────────────────┐
│ short _lib_index (2 bytes)                                      │
│   库索引，用于快速定位函数所属的共享库                            │
├─────────────────────────────────────────────────────────────────┤
│ char _mark (1 byte)                                             │
│   标记类型：                                                    │
│   MARK_VM_RUNTIME = 1     // VM 运行时入口                      │
│   MARK_INTERPRETER = 2    // 解释器帧                           │
│   MARK_COMPILER_ENTRY = 3 // 编译器入口                         │
│   MARK_ASYNC_PROFILER = 4 // async-profiler 内部函数            │
├─────────────────────────────────────────────────────────────────┤
│ char _reserved (1 byte)                                         │
│   保留字段                                                      │
├─────────────────────────────────────────────────────────────────┤
│ char _name[0] (柔性数组)                                        │
│   函数名，以 '\0' 结尾                                          │
│   例如："malloc", "pthread_create", "_ZN6Method4sizeEv"        │
└─────────────────────────────────────────────────────────────────┘

总大小 = 4 bytes + strlen(name) + 1
```

### 1.2 CodeBlob - 代码块描述

```cpp
// 文件: codeCache.h 第 82-101 行

class CodeBlob {
  public:
    const void* _start;   // 代码块起始地址
    const void* _end;     // 代码块结束地址
    char* _name;          // 代码块名称（指向 NativeFunc._name）

    static int comparator(const void* c1, const void* c2) {
        CodeBlob* cb1 = (CodeBlob*)c1;
        CodeBlob* cb2 = (CodeBlob*)c2;
        
        // 按 _start 排序
        if (cb1->_start < cb2->_start) return -1;
        if (cb1->_start > cb2->_start) return 1;
        
        // _start 相同时，范围大的排前面
        if (cb1->_end == cb2->_end) return 0;
        return cb1->_end > cb2->_end ? -1 : 1;
    }
};
```

**为什么范围大的排前面？**

```
场景：存在嵌套函数

  func_a: 0x1000 - 0x2000 (4KB)
  func_b: 0x1000 - 0x1000 (0 字节，标记点)

排序后：
  [0] func_a: 0x1000 - 0x2000
  [1] func_b: 0x1000 - 0x1000

这样在二分查找时：
  - 地址 0x1500 会匹配到 func_a
  - 因为 func_b 排在后面，不会误匹配
```

### 1.3 CodeCache - 代码缓存

```cpp
// 文件: codeCache.h 第 106-215 行

class CodeCache {
  private:
    // ==================== 基本信息 ====================
    char* _name;              // 库名（如 "libjvm.so"）
    short _lib_index;         // 库索引
    const void* _min_address; // 最小地址
    const void* _max_address; // 最大地址
    const char* _text_base;   // .text 段基址
    const char* _image_base;  // 镜像基址

    // ==================== PLT 信息 ====================
    unsigned int _plt_offset; // PLT 偏移
    unsigned int _plt_size;   // PLT 大小

    // ==================== 导入表 ====================
    void** _imports[NUM_IMPORTS][NUM_IMPORT_TYPES];
    // NUM_IMPORTS = 14 (dlopen, pthread_create, malloc, ...)
    // NUM_IMPORT_TYPES = 2 (PRIMARY, SECONDARY)
    bool _imports_patchable;  // 导入表是否可写
    bool _debug_symbols;      // 是否有调试符号

    // ==================== DWARF 信息 ====================
    FrameDesc* _dwarf_table;      // DWARF 帧描述表
    int _dwarf_table_length;      // 表长度

    // ==================== 符号表 ====================
    int _capacity;            // 容量
    int _count;               // 当前数量
    CodeBlob* _blobs;         // 符号数组

  public:
    // 核心方法
    void add(const void* start, int length, const char* name, bool update_bounds);
    void sort();
    const char* binarySearch(const void* address);
    const void* findSymbol(const char* name);
    void** findImport(ImportId id);
    void patchImport(ImportId id, void* hook_func);
};
```

---

## 2. CodeCache 核心方法

### 2.1 构造函数

```cpp
// 文件: codeCache.cpp 第 32-56 行

CodeCache::CodeCache(const char* name, short lib_index,
                     const void* min_address, const void* max_address,
                     const char* image_base) {
    // [1] 创建库名
    _name = NativeFunc::create(name, -1);
    // NativeFunc::create 展开为：
    // {
    //     NativeFunc* f = (NativeFunc*)malloc(sizeof(NativeFunc) + 1 + strlen(name));
    //     f->_lib_index = lib_index;
    //     f->_mark = 0;
    //     return strcpy(f->_name, name);
    // }

    // [2] 初始化地址范围
    _lib_index = lib_index;
    _min_address = min_address;
    _max_address = max_address;
    _text_base = NULL;
    _image_base = image_base;

    // [3] 初始化 PLT 信息
    _plt_offset = 0;
    _plt_size = 0;

    // [4] 初始化导入表
    memset(_imports, 0, sizeof(_imports));
    _imports_patchable = false;
    _debug_symbols = false;

    // [5] 初始化 DWARF 表
    _dwarf_table = NULL;
    _dwarf_table_length = 0;

    // [6] 初始化符号表
    _capacity = INITIAL_CODE_CACHE_CAPACITY;  // 1000
    _count = 0;
    _blobs = new CodeBlob[_capacity];
}
```

### 2.2 add() - 添加符号

```cpp
// 文件: codeCache.cpp 第 78-98 行

void CodeCache::add(const void* start, int length, const char* name, bool update_bounds) {
    // [1] 创建函数名副本
    char* name_copy = NativeFunc::create(name, _lib_index);
    // NativeFunc::create 展开为：
    // {
    //     NativeFunc* f = (NativeFunc*)malloc(sizeof(NativeFunc) + 1 + strlen(name));
    //     f->_lib_index = lib_index;
    //     f->_mark = 0;
    //     return strcpy(f->_name, name);
    // }

    // [2] 替换不可打印字符
    for (char* s = name_copy; *s != 0; s++) {
        if (*s < ' ') *s = '?';
        // 某些符号可能包含控制字符，替换为 '?'
    }

    // [3] 检查容量并扩容
    if (_count >= _capacity) {
        expand();
    }

    // [4] 添加到数组
    const void* end = (const char*)start + length;
    _blobs[_count]._start = start;
    _blobs[_count]._end = end;
    _blobs[_count]._name = name_copy;
    _count++;

    // [5] 更新地址范围
    if (update_bounds) {
        updateBounds(start, end);
    }
}
```

### 2.3 sort() - 排序符号表

```cpp
// 文件: codeCache.cpp 第 105-112 行

void CodeCache::sort() {
    if (_count == 0) return;

    // [1] 快速排序
    qsort(_blobs, _count, sizeof(CodeBlob), CodeBlob::comparator);
    // comparator 按地址排序

    // [2] 更新地址范围（如果未设置）
    if (_min_address == NO_MIN_ADDRESS) {
        _min_address = _blobs[0]._start;
    }
    if (_max_address == NO_MAX_ADDRESS) {
        _max_address = _blobs[_count - 1]._end;
    }
}
```

### 2.4 binarySearch() - 二分查找符号

```cpp
// 文件: codeCache.cpp 第 133-154 行

const char* CodeCache::binarySearch(const void* address) {
    int low = 0;
    int high = _count - 1;

    // [1] 标准二分查找
    while (low <= high) {
        int mid = (unsigned int)(low + high) >> 1;
        
        if (_blobs[mid]._end <= address) {
            // 地址在当前块右边
            low = mid + 1;
        } else if (_blobs[mid]._start > address) {
            // 地址在当前块左边
            high = mid - 1;
        } else {
            // 找到匹配的块
            return _blobs[mid]._name;
        }
    }

    // [2] 处理特殊情况
    // 符号可能大小为 0（如 ASM 入口点）
    // 或者返回地址可能指向函数结尾（无限循环）
    if (low > 0 && (_blobs[low - 1]._start == _blobs[low - 1]._end || 
                    _blobs[low - 1]._end == address)) {
        return _blobs[low - 1]._name;
    }
    
    // [3] 未找到，返回库名
    return _name;
}
```

**二分查找示例**：

```
假设有以下符号（已排序）：

索引  符号名       起始地址    结束地址
[0]  func_a       0x1000     0x1100
[1]  func_b       0x1100     0x1200
[2]  func_c       0x1200     0x1300
[3]  func_d       0x1300     0x1400
[4]  func_e       0x1400     0x1500

查找地址 0x1250：

1. low=0, high=4, mid=2
   _blobs[2]._end=0x1300 > 0x1250
   _blobs[2]._start=0x1200 <= 0x1250
   找到：func_c

查找地址 0x1190：

1. low=0, high=4, mid=2
   _blobs[2]._end=0x1300 > 0x1190
   _blobs[2]._start=0x1200 > 0x1190
   high = 1

2. low=0, high=1, mid=0
   _blobs[0]._end=0x1100 <= 0x1190
   low = 1

3. low=1, high=1, mid=1
   _blobs[1]._end=0x1200 > 0x1190
   _blobs[1]._start=0x1100 <= 0x1190
   找到：func_b
```

---

## 3. 导入表 Hook 机制

### 3.1 addImport() - 记录导入函数

```cpp
// 文件: codeCache.cpp 第 190-242 行

void CodeCache::addImport(void** entry, const char* name) {
    // entry: GOT 表项地址
    // name: 导入函数名
    
    switch (name[0]) {
        case 'a':
            if (strcmp(name, "aligned_alloc") == 0) {
                saveImport(im_aligned_alloc, entry);
            }
            break;
        case 'c':
            if (strcmp(name, "calloc") == 0) {
                saveImport(im_calloc, entry);
            }
            break;
        case 'd':
            if (strcmp(name, "dlopen") == 0) {
                saveImport(im_dlopen, entry);
            }
            break;
        case 'f':
            if (strcmp(name, "free") == 0) {
                saveImport(im_free, entry);
            }
            break;
        case 'm':
            if (strcmp(name, "malloc") == 0) {
                saveImport(im_malloc, entry);
            }
            break;
        case 'p':
            if (strcmp(name, "pthread_create") == 0) {
                saveImport(im_pthread_create, entry);
            } else if (strcmp(name, "pthread_exit") == 0) {
                saveImport(im_pthread_exit, entry);
            } else if (strcmp(name, "pthread_mutex_lock") == 0) {
                saveImport(im_pthread_mutex_lock, entry);
            }
            // ... 其他 pthread 函数
            break;
        case 'r':
            if (strcmp(name, "realloc") == 0) {
                saveImport(im_realloc, entry);
            }
            break;
    }
}
```

### 3.2 patchImport() - Hook 导入函数

```cpp
// 文件: codeCache.cpp 第 251-262 行

void CodeCache::patchImport(ImportId id, void* hook_func) {
    // [1] 确保导入表可写
    if (!_imports_patchable && !makeImportsPatchable()) {
        return;
    }

    // [2] 修改 GOT 表项
    for (int ty = 0; ty < NUM_IMPORT_TYPES; ty++) {
        void** entry = _imports[id][ty];
        if (entry != NULL) {
            *entry = hook_func;
            // 直接修改 GOT 表项
            // 之后所有对该函数的调用都会跳转到 hook_func
        }
    }
}
```

### 3.3 makeImportsPatchable() - 设置内存可写

```cpp
// 文件: codeCache.cpp 第 264-287 行

bool CodeCache::makeImportsPatchable() {
    // [1] 找到导入表的范围
    void** min_import = (void**)-1;
    void** max_import = NULL;
    
    for (int i = 0; i < NUM_IMPORTS; i++) {
        for (int j = 0; j < NUM_IMPORT_TYPES; j++) {
            void** entry = _imports[i][j];
            if (entry == NULL) continue;
            if (entry < min_import) min_import = entry;
            if (entry > max_import) max_import = entry;
        }
    }

    // [2] 设置内存页为可读写
    if (max_import != NULL) {
        uintptr_t patch_start = (uintptr_t)min_import & ~OS::page_mask;
        uintptr_t patch_end = (uintptr_t)max_import & ~OS::page_mask;
        
        if (OS::mprotect((void*)patch_start, 
                         patch_end - patch_start + OS::page_size, 
                         PROT_READ | PROT_WRITE) != 0) {
            Log::warn("Could not patch %s", name());
            return false;
        }
    }

    _imports_patchable = true;
    return true;
}
```

**GOT Hook 原理图**：

```
PLT/GOT 结构：

代码段 (.plt)：
┌─────────────────────────────────────────────────────────────────┐
│ malloc@plt:                                                     │
│   jmp    *GOT[malloc]    // 跳转到 GOT 表项                     │
│   push   index                                                  │
│   jmp    resolver        // 第一次调用时解析                    │
└─────────────────────────────────────────────────────────────────┘

数据段 (.got)：
┌─────────────────────────────────────────────────────────────────┐
│ GOT[malloc]: 0x7fff...  // malloc 的真实地址                    │
│ GOT[free]:   0x7fff...  // free 的真实地址                      │
│ ...                                                             │
└─────────────────────────────────────────────────────────────────┘

Hook 后：

GOT[malloc]: 0x7fff... -> malloc_hook  // 修改为 hook 函数地址

所有对 malloc 的调用都会跳转到 malloc_hook
```

---

## 4. ELF 符号解析

### 4.1 ElfParser 类

```cpp
// 文件: symbols_linux.cpp 第 155-177 行

#ifdef __LP64__
const unsigned char ELFCLASS_SUPPORTED = ELFCLASS64;
typedef Elf64_Ehdr ElfHeader;        // ELF 文件头
typedef Elf64_Shdr ElfSection;       // 节区头
typedef Elf64_Phdr ElfProgramHeader; // 程序头
typedef Elf64_Nhdr ElfNote;          // NOTE 段
typedef Elf64_Sym  ElfSymbol;        // 符号表项
typedef Elf64_Rel  ElfRelocation;    // 重定位项
typedef Elf64_Dyn  ElfDyn;           // 动态段
#else
// 32 位版本...
#endif
```

### 4.2 loadSymbols() - 加载符号表

```cpp
// 文件: symbols_linux.cpp 第 486-509 行

void ElfParser::loadSymbols(bool use_debug) {
    // [1] 查找 .symtab 节区
    ElfSection* symtab = findSection(SHT_SYMTAB, ".symtab");
    
    if (symtab != NULL) {
        // [2] 解析符号表
        ElfSection* strtab = section(symtab->sh_link);
        loadSymbolTable(at(symtab), symtab->sh_size, symtab->sh_entsize, at(strtab));
        _cc->setDebugSymbols(true);
    } else if (use_debug) {
        // [3] 尝试从外部 debuginfo 加载
        loadSymbolsUsingBuildId() || loadSymbolsUsingDebugLink();
    }

    if (use_debug) {
        // [4] 合成 PLT stub 名称
        ElfSection* plt = findSection(SHT_PROGBITS, ".plt");
        if (plt != NULL) {
            _cc->setPlt(plt->sh_addr, plt->sh_size);
            ElfSection* reltab = findSection(SHT_RELA, ".rela.plt");
            if (reltab != NULL || (reltab = findSection(SHT_REL, ".rel.plt")) != NULL) {
                addRelocationSymbols(reltab, base() + plt->sh_addr + PLT_HEADER_SIZE);
            }
        }
    }
}
```

### 4.3 loadSymbolTable() - 解析符号表

```cpp
// 文件: symbols_linux.cpp 第 632-643 行

void ElfParser::loadSymbolTable(const char* symbols, size_t total_size, 
                                size_t ent_size, const char* strings) {
    const char* base = this->base();
    
    for (const char* symbols_end = symbols + total_size; 
         symbols < symbols_end; 
         symbols += ent_size) {
        
        ElfSymbol* sym = (ElfSymbol*)symbols;
        
        // [1] 跳过无效符号
        if (sym->st_name == 0 || sym->st_value == 0) {
            continue;
        }
        
        // [2] 跳过特殊 AArch64 映射符号 ($x 和 $d)
        if (sym->st_size != 0 || sym->st_info != 0 || strings[sym->st_name] != '$') {
            // [3] 添加到 CodeCache
            _cc->add(base + sym->st_value, (int)sym->st_size, strings + sym->st_name);
        }
    }
}
```

**ElfSymbol 结构**：

```
Elf64_Sym 结构：

┌─────────────────────────────────────────────────────────────────┐
│ st_name  (4 bytes)  - 符号名在字符串表中的偏移                  │
│ st_info  (1 byte)   - 符号类型和绑定属性                        │
│ st_other (1 byte)   - 可见性                                    │
│ st_shndx (2 bytes)  - 所属节区索引                              │
│ st_value (8 bytes)  - 符号值（通常是地址）                      │
│ st_size  (8 bytes)  - 符号大小                                  │
└─────────────────────────────────────────────────────────────────┘

示例：

符号表 (.symtab)：
┌─────┬──────────────┬──────────┬─────────┬──────────┐
│索引 │    名称      │   地址   │  大小   │   类型   │
├─────┼──────────────┼──────────┼─────────┼──────────┤
│  1  │ main         │ 0x1000   │ 256     │ FUNC     │
│  2  │ func_a       │ 0x1100   │ 128     │ FUNC     │
│  3  │ global_var   │ 0x3000   │ 8       │ OBJECT   │
└─────┴──────────────┴──────────┴─────────┴──────────┘
```

### 4.4 解析导入表

```cpp
// 文件: symbols_linux.cpp 第 400-453 行

void ElfParser::parseDynamicTable() {
    // ... 获取动态段指针 ...

    // [1] 解析 .rela.plt (PLT 重定位表)
    if (jmprel != NULL && pltrelsz != 0 && relent != 0) {
        for (size_t offs = 0; offs < pltrelsz; offs += relent) {
            ElfRelocation* r = (ElfRelocation*)(jmprel + offs);
            ElfSymbol* sym = (ElfSymbol*)(symtab + ELF_R_SYM(r->r_info) * syment);
            
            if (sym->st_name != 0) {
                // 添加导入函数
                _cc->addImport((void**)(base + r->r_offset), strtab + sym->st_name);
            }
        }
    }

    // [2] 解析 .rela.dyn (全局数据重定位表)
    if (rel != NULL && relsz != 0 && relent != 0) {
        for (size_t offs = relcount * relent; offs < relsz; offs += relent) {
            ElfRelocation* r = (ElfRelocation*)(rel + offs);
            
            // 只处理 GLOB_DAT 和 ABS64 类型的重定位
            if (ELF_R_TYPE(r->r_info) == R_GLOB_DAT || 
                ELF_R_TYPE(r->r_info) == R_ABS64) {
                
                ElfSymbol* sym = (ElfSymbol*)(symtab + ELF_R_SYM(r->r_info) * syment);
                if (sym->st_name != 0) {
                    _cc->addImport((void**)(base + r->r_offset), strtab + sym->st_name);
                }
            }
        }
    }
}
```

---

## 5. DWARF 帧描述解析

### 5.1 parseDwarfInfo()

```cpp
// 文件: symbols_linux.cpp 第 456-468 行

void ElfParser::parseDwarfInfo() {
    if (!DWARF_SUPPORTED) return;

    // [1] 查找 .eh_frame_hdr 段
    ElfProgramHeader* eh_frame_hdr = findProgramHeader(PT_GNU_EH_FRAME);
    
    if (eh_frame_hdr != NULL && eh_frame_hdr->p_vaddr != 0) {
        // [2] 解析 DWARF 信息
        DwarfParser dwarf(_cc->name(), _base, at(eh_frame_hdr));
        _cc->setDwarfTable(dwarf.table(), dwarf.count());
    } else if (strcmp(_cc->name(), "[vdso]") == 0) {
        // [3] 特殊处理 vdso
        FrameDesc* table = (FrameDesc*)malloc(sizeof(FrameDesc));
        *table = FrameDesc::empty_frame;
        _cc->setDwarfTable(table, 1);
    }
}
```

### 5.2 findFrameDesc() - 查找帧描述

```cpp
// 文件: codeCache.cpp 第 294-317 行

FrameDesc* CodeCache::findFrameDesc(const void* pc) {
    // [1] 计算相对偏移
    u32 target_loc = (const char*)pc - _text_base;
    
    // [2] 二分查找
    int low = 0;
    int high = _dwarf_table_length - 1;

    while (low <= high) {
        int mid = (unsigned int)(low + high) >> 1;
        
        if (_dwarf_table[mid].loc < target_loc) {
            low = mid + 1;
        } else if (_dwarf_table[mid].loc > target_loc) {
            high = mid - 1;
        } else {
            return &_dwarf_table[mid];
        }
    }

    // [3] 返回最近的帧描述
    if (low > 0) {
        return &_dwarf_table[low - 1];
    } else if (target_loc - _plt_offset < _plt_size) {
        // PLT 代码：使用空帧
        return &FrameDesc::empty_frame;
    } else {
        // 默认帧
        return &FrameDesc::default_frame;
    }
}
```

---

## 6. 调试符号加载

### 6.1 通过 Build ID 加载

```cpp
// 文件: symbols_linux.cpp 第 573-589 行

bool ElfParser::loadSymbolsUsingBuildId() {
    // [1] 查找 .note.gnu.build-id 节区
    ElfSection* section = findSection(SHT_NOTE, ".note.gnu.build-id");
    if (section == NULL || section->sh_size <= 16) {
        return false;
    }

    // [2] 解析 Build ID
    ElfNote* note = (ElfNote*)at(section);
    if (note->n_namesz != 4 || note->n_descsz < 2 || note->n_descsz > 64) {
        return false;
    }

    const char* build_id = (const char*)note + sizeof(*note) + 4;
    int build_id_len = note->n_descsz;

    // [3] 尝试从以下位置加载：
    // - /usr/lib/debug/.build-id/ab/cdef1234.debug
    // - $DEBUGINFOD_CACHE_PATH/abcdef1234/debuginfo
    return loadSymbolsFromDebug(build_id, build_id_len)
        || loadSymbolsFromDebuginfodCache(build_id, build_id_len);
}
```

### 6.2 通过 Debug Link 加载

```cpp
// 文件: symbols_linux.cpp 第 592-630 行

bool ElfParser::loadSymbolsUsingDebugLink() {
    // [1] 查找 .gnu_debuglink 节区
    ElfSection* section = findSection(SHT_PROGBITS, ".gnu_debuglink");
    if (section == NULL || section->sh_size <= 4) {
        return false;
    }

    const char* basename = strrchr(_file_name, '/');
    if (basename == NULL) {
        return false;
    }

    char* dirname = strndup(_file_name, basename - _file_name);
    const char* debuglink = at(section);
    char path[PATH_MAX];
    bool result = false;

    // [2] 尝试以下路径：
    // - /path/to/libjvm.so.debug
    // - /path/to/.debug/libjvm.so.debug
    // - /usr/lib/debug/path/to/libjvm.so.debug
    
    if (strcmp(debuglink, basename + 1) != 0 &&
        snprintf(path, PATH_MAX, "%s/%s", dirname, debuglink) < PATH_MAX) {
        result = parseFile(_cc, _base, path, false);
    }

    if (!result && snprintf(path, PATH_MAX, "%s/.debug/%s", dirname, debuglink) < PATH_MAX) {
        result = parseFile(_cc, _base, path, false);
    }

    if (!result && snprintf(path, PATH_MAX, "/usr/lib/debug%s/%s", dirname, debuglink) < PATH_MAX) {
        result = parseFile(_cc, _base, path, false);
    }

    free(dirname);
    return result;
}
```

---

## 7. 内核符号解析

### 7.1 parseKernelSymbols()

```cpp
// 文件: symbols_linux.cpp 第 679-699 行

void Symbols::parseKernelSymbols(CodeCache* cc) {
    // [1] 打开 /proc/kallsyms
    int fd;
    if (FdTransferClient::hasPeer()) {
        fd = FdTransferClient::requestKallsymsFd();
    } else {
        fd = open("/proc/kallsyms", O_RDONLY);
    }

    if (fd == -1) {
        Log::warn("open(\"/proc/kallsyms\"): %s", strerror(errno));
        return;
    }

    FILE* f = fdopen(fd, "r");
    if (f == NULL) {
        Log::warn("fdopen(): %s", strerror(errno));
        close(fd);
        return;
    }

    char str[256];
    // ... 解析每一行 ...
```

**/proc/kallsyms 格式**：

```
地址            类型  符号名
ffffffff81000000 T startup_64
ffffffff81000050 T _text
ffffffff81001000 T __init_begin
ffffffff81001100 T __init_text_start
ffffffff81010000 T __init_text_end
ffffffff81020000 T __init_end
ffffffff81020000 T _stext
ffffffff81020000 T _text

类型说明：
  T = 代码段 (Text)
  D = 已初始化数据段 (Data)
  B = 未初始化数据段 (BSS)
  R = 只读数据段 (Read-only)
  W = 可写数据段
  A = 绝对符号
  t = 本地代码段符号
  d = 本地数据段符号
```

---

## 8. 完整架构图

```
符号解析与代码缓存架构：

┌─────────────────────────────────────────────────────────────────────────┐
│                        Profiler::_native_libs                            │
│                        (CodeCacheArray)                                 │
├─────────────────────────────────────────────────────────────────────────┤
│  [0] CodeCache: libjvm.so                                               │
│      ├─ _name: "libjvm.so"                                              │
│      ├─ _min_address: 0x7f0000000000                                    │
│      ├─ _max_address: 0x7f0001000000                                    │
│      ├─ _blobs: [CodeBlob, CodeBlob, ...]                              │
│      │    ├─ "JVM_StartThread": 0x7f0000abc000 - 0x7f0000abc100        │
│      │    ├─ "JVM_AllocateNewObject": 0x7f0000abd000 - ...             │
│      │    └─ ...                                                        │
│      ├─ _imports: [malloc@GOT, free@GOT, ...]                          │
│      └─ _dwarf_table: [FrameDesc, ...]                                  │
│                                                                         │
│  [1] CodeCache: libc.so.6                                               │
│      ├─ _name: "libc.so.6"                                              │
│      ├─ _blobs: [CodeBlob, ...]                                        │
│      │    ├─ "malloc": 0x7f0001000000 - ...                            │
│      │    ├─ "free": 0x7f0001001000 - ...                              │
│      │    └─ ...                                                        │
│      └─ _imports: [dlopen@GOT, ...]                                    │
│                                                                         │
│  [2] CodeCache: [kernel]                                                │
│      ├─ _name: "[kernel]"                                               │
│      └─ _blobs: 从 /proc/kallsyms 加载                                  │
│                                                                         │
│  ... (其他库)                                                           │
└─────────────────────────────────────────────────────────────────────────┘

符号解析流程：

┌─────────────────────────────────────────────────────────────────────────┐
│ 1. 启动时：updateSymbols()                                              │
│    ├─ 遍历 /proc/self/maps                                              │
│    ├─ 对每个库调用 ElfParser::parseFile()                               │
│    └─ 解析 ELF 符号表、DWARF 信息、导入表                               │
├─────────────────────────────────────────────────────────────────────────┤
│ 2. 运行时：findNativeMethod(pc)                                         │
│    ├─ findLibraryByAddress(pc) 找到所属库                               │
│    └─ CodeCache::binarySearch(pc) 二分查找符号                          │
├─────────────────────────────────────────────────────────────────────────┤
│ 3. Hook 时：patchImport(im_malloc, malloc_hook)                         │
│    ├─ CodeCache::findImport(im_malloc) 获取 GOT 地址                    │
│    ├─ makeImportsPatchable() 设置内存可写                               │
│    └─ 修改 GOT 表项指向 hook 函数                                        │
├─────────────────────────────────────────────────────────────────────────┤
│ 4. 栈回溯：findFrameDesc(pc)                                            │
│    ├─ 计算 pc 相对于 _text_base 的偏移                                  │
│    └─ 在 _dwarf_table 中二分查找帧描述                                  │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 9. 性能分析

### 9.1 内存使用

```
CodeCache 内存估算：

每个符号：
  - NativeFunc 头部：4 bytes
  - 符号名：平均 30 bytes
  - 总计：~34 bytes/symbol

CodeBlob：
  - 3 个指针：24 bytes

一个典型的 libjvm.so：
  - 符号数：~100,000
  - NativeFunc 内存：~3.4 MB
  - CodeBlob 内存：~2.4 MB
  - 总计：~6 MB

所有库总计（~200 个）：
  - 预估：~50-100 MB
```

### 9.2 查找性能

```
binarySearch() 性能：

时间复杂度：O(log n)
  - 100,000 个符号：~17 次比较
  - 10,000 个符号：~14 次比较

每次比较：
  - 2 次指针比较（_start, _end）
  - ~5-10 CPU 周期

总耗时：
  - 典型情况：~100-200 CPU 周期
  - 可忽略不计
```

---

## 10. 设计亮点

### 10.1 惰性加载

```
符号加载策略：

1. 启动时只加载基本信息
   - 库的地址范围
   - 导入表（用于 Hook）

2. 首次需要时加载符号
   - 从 .symtab 加载（如果有）
   - 从外部 debuginfo 加载

3. 按需解析 DWARF
   - 只在使用 DWARF 栈回溯时解析
```

### 10.2 零拷贝设计

```
NativeFunc 设计：

  传统方式：
    struct Symbol {
      string name;  // 动态分配
      void* addr;
    };
    // 需要两次内存分配

  async-profiler 方式：
    NativeFunc {
      short _lib_index;
      char _mark;
      char _name[0];  // 柔性数组
    };
    // 只需一次内存分配

  优点：
    - 减少内存分配次数
    - 提高缓存局部性
    - 简化内存管理
```

### 10.3 通用 Hook 机制

```
导入表 Hook 的优势：

1. 稳定性
   - 不修改代码段
   - 不破坏指令对齐
   - 不影响性能

2. 通用性
   - 适用于任何共享库
   - 不需要知道函数地址
   - 自动处理延迟绑定

3. 安全性
   - 只修改数据段
   - 不触发代码签名检查
   - 不影响 W^X 保护
```
