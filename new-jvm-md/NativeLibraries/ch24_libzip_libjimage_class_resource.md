# Ch24: libzip.so + libjimage.so — 类路径资源读取

> 基于 OpenJDK 11 源码 | 类加载"读文件"层深度分析
> 模块 E（类加载基础设施）| PerfMa 面试价值：⭐⭐⭐

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **Ch24: libzip.so + libjimage.so — 类路径资源读取**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 24.1 总览：类加载时 .class 字节码从哪里来？

### 核心问题

当 HotSpot 需要加载 `java.lang.String`（引导类）或 `com.wjcoder.Main`（应用类）时，`.class` 字节码文件是怎么从磁盘读到内存的？

### JDK 8 vs JDK 9+ 的变化

```
JDK 8:
  引导类 → rt.jar (ZIP 格式)    → libzip.so 读取
  应用类 → *.jar  (ZIP 格式)    → libzip.so 读取

JDK 9+:
  引导类 → lib/modules (jimage) → libjimage.so 读取   ← 新增！
  应用类 → *.jar  (ZIP 格式)    → libzip.so 读取       ← 不变
```

### HotSpot 中的 ClassPathEntry 体系

```
ClassPathEntry (抽象基类)
├── ClassPathDirEntry          — 目录（exploded build / -cp dir）
│   └── open_stream(): 直接 open() + read() 读取 .class 文件
│
├── ClassPathZipEntry          — JAR/ZIP 文件（-cp xxx.jar / -Xbootclasspath/a:）
│   └── open_stream(): 通过 libzip.so 的函数指针读取
│       ├── FindEntry → ZIP_FindEntry()
│       ├── ReadEntry → ZIP_ReadEntry() → ZIP_Read() + InflateFully()
│       └── ZipOpen   → ZIP_Open()
│
└── ClassPathImageEntry        — JDK 模块镜像（lib/modules）
    └── open_stream(): 通过 libjimage.so 的函数指针读取
        ├── JImageFindResource → JIMAGE_FindResource()
        └── JImageGetResource  → JIMAGE_GetResource()
```

### HotSpot 函数指针绑定

**文件**：`classLoader.cpp` 第 85-100 行

HotSpot **不直接链接** libzip.so 和 libjimage.so，而是通过 `dlsym` 动态绑定函数指针：

```cpp
// libzip.so 函数指针（在 ClassLoader::load_zip_library 中绑定）
static ZipOpen_t         ZipOpen            = NULL;  // → ZIP_Open
static ZipClose_t        ZipClose           = NULL;  // → ZIP_Close
static FindEntry_t       FindEntry          = NULL;  // → ZIP_FindEntry
static ReadEntry_t       ReadEntry          = NULL;  // → ZIP_ReadEntry
static GetNextEntry_t    GetNextEntry       = NULL;  // → ZIP_GetNextEntry
static ZipInflateFully_t ZipInflateFully    = NULL;  // → ZIP_InflateFully
static Crc32_t           Crc32              = NULL;  // → ZIP_CRC32

// libjimage.so 函数指针（在 ClassLoader::load_jimage_library 中绑定）
static JImageOpen_t             JImageOpen             = NULL;  // → JIMAGE_Open
static JImageClose_t            JImageClose            = NULL;  // → JIMAGE_Close
static JImagePackageToModule_t  JImagePackageToModule  = NULL;  // → JIMAGE_PackageToModule
static JImageFindResource_t     JImageFindResource     = NULL;  // → JIMAGE_FindResource
static JImageGetResource_t      JImageGetResource      = NULL;  // → JIMAGE_GetResource
static JImageResourceIterator_t JImageResourceIterator = NULL;  // → JIMAGE_ResourceIterator
```

**为什么用函数指针而不是直接链接？**
- **可选依赖**：如果某个 .so 不存在或加载失败，JVM 仍然可以启动（只是对应功能不可用）
- **延迟加载**：启动时按需加载，减少启动时间
- **解耦**：HotSpot 和 Native 库可以独立编译

### Boot ClassLoader 搜索顺序

**文件**：`classLoader.cpp` → `ClassLoader::load_class()`

```
ClassLoader::load_class(name, search_append_only):
│
├── Attempt #1: --patch-module
│   → search_module_entries(_patch_mod_entries, ...)
│   → 仅在 !search_append_only 且 !DumpSharedSpaces 时
│
├── Attempt #2: [jimage | exploded build]
│   → if has_jrt_entry():
│       _jrt_entry->open_stream(file_name)    ← ClassPathImageEntry
│   → else:
│       search_module_entries(_exploded_entries, ...)  ← ClassPathDirEntry
│
└── Attempt #3: [-Xbootclasspath/a]; [jvmti appended entries]
    → 遍历 _first_append_entry 链表
    → e->open_stream(file_name)              ← 通常是 ClassPathZipEntry
```

**关键**：生产环境中，`java.lang.String` 等引导类走 Attempt #2 的 `_jrt_entry->open_stream()`（ClassPathImageEntry → libjimage.so）。应用类走 Java 层的 `AppClassLoader` → `URLClassPath` → 最终也调用 libzip.so。

---

## 24.2 libzip.so — ZIP/JAR 文件读取

### ZIP 格式基础

```
ZIP 文件整体布局：
┌─────────────────────────────────────────────────┐
│  [Local File Header 1]  [File Data 1]           │ ← LOC 区域
│  [Local File Header 2]  [File Data 2]           │    每个文件有自己的头
│  ...                                            │
│  [Local File Header N]  [File Data N]           │
├─────────────────────────────────────────────────┤
│  [Central Directory Entry 1]                    │ ← CEN 区域
│  [Central Directory Entry 2]                    │    所有文件的元数据索引
│  ...                                            │    包含指向 LOC 的偏移
│  [Central Directory Entry N]                    │
├─────────────────────────────────────────────────┤
│  [End of Central Directory Record]              │ ← END 记录
│  (指向 CEN 的偏移和总条目数)                      │    整个 ZIP 文件的"入口"
└─────────────────────────────────────────────────┘

读取顺序：END → CEN → 按需读取 LOC + Data
（先从文件末尾找 END，再根据 END 找 CEN，最后按需读具体文件）
```

### 四种 Header 签名

```
签名          偏移     含义
PK\x03\x04    LOC    Local File Header（每个文件的本地头）
PK\x01\x02    CEN    Central Directory Header（中央目录）
PK\x05\x06    END    End of Central Directory（终止记录）
PK\x06\x06    ZIP64  Zip64 End of Central Directory
PK\x06\x07    ZIP64  Zip64 End Locator
```

### 核心数据结构

#### jzfile — ZIP 文件描述符

**文件**：`zip_util.h` 第 174-197 行

```
jzfile（ZIP 文件描述符）
偏移      字段名          类型          说明
───────────────────────────────────────────────────────────────────
0x000    name            char*         ZIP 文件路径名
0x008    refs            jint          引用计数（同一 ZIP 被多处打开时共享）
0x00C    [padding]       4 bytes       对齐
0x010    len             jlong         ZIP 文件总字节大小
0x018    locsig          jboolean      文件是否以 LOCSIG 开头（有效 ZIP）
0x020    cencache        cencache      CEN 头缓存（页式缓存，8KB 一页）
         ├── .data       char*         缓存的 CEN 数据页
         └── .pos        jlong         该页在文件中的偏移
0x030    zfd             int           文件描述符（open() 返回值）
0x038    lock            void*         读锁（JVM_RawMonitor）
0x040    comment         char*         ZIP 文件注释
0x048    clen            jint          注释长度
0x050    msg             char*         错误消息
0x058    entries         jzcell*       ★ 哈希表 cell 数组（核心索引！）
0x060    total           jint          总 entry 数
0x064    [padding]       4 bytes
0x068    table           jint*         ★ 哈希链头数组
0x070    tablelen        jint          哈希表长度（= total/2 | 1，取奇数）
0x078    next            jzfile*       全局 ZIP 文件链表的下一个
0x080    cache           jzentry*      最近释放的 jzentry 缓存（1 条）
0x088    metanames       char**        META-INF/ 下的文件名数组
0x090    metacurrent     jint          metanames 下一个空槽
0x094    metacount       jint          metanames 数组大小
0x098    lastModified    jlong         最后修改时间
0x0A0    locpos          jlong         第一个 LOC 的位置（有 stub 前缀时非 0）
───────────────────────────────────────────────────────────────────
```

#### jzcell — 哈希表 cell

```
jzcell (12 bytes):
偏移    字段名     类型          说明
0x000  hash      unsigned int  文件名的 32 位哈希值（hash("java/lang/String.class")）
0x004  next      unsigned int  哈希链：下一个 cell 在 entries[] 中的索引
0x008  cenpos    jlong         该 entry 的 CEN 头在文件中的偏移量
```

#### jzentry — ZIP 文件 entry（查询结果）

```
jzentry (按需创建，表示一次查找结果):
偏移    字段名    类型     说明
0x000  name     char*    entry 名称（如 "java/lang/String.class"）
0x008  time     jlong    修改时间
0x010  size     jlong    ★ 解压后大小（.class 文件实际大小）
0x018  csize    jlong    压缩后大小（0 = 未压缩 STORED）
0x020  crc      jint     CRC32 校验值
0x028  comment  char*    注释
0x030  extra    jbyte*   额外数据（ZIP64 扩展在这里）
0x038  pos      jlong    ★ LOC 头位置（负值）或数据位置（正值）
0x040  flag     jint     通用标志位
0x044  nlen     jint     名称长度
```

**pos 字段设计**：
- `pos ≤ 0`：值为 `-(locpos + CENOFF)`，即 LOC 头的负偏移。需要时才读 LOC 头来计算实际数据偏移
- `pos > 0`：已计算的实际数据位置（LOC 头 + 文件名 + extra 之后）

**为什么延迟计算 pos？** 因为 CEN 中的 extra 长度和 LOC 中的 extra 长度**可以不同**（ZIP 规范允许），所以必须读取 LOC 头才能确定准确的数据偏移。延迟读取避免了初始化时的大量 I/O。

### ZIP_Open — 打开 JAR 文件

```
ZIP_Open(name, &pmsg):
│
├── ZIP_Open_Generic(name, &pmsg, O_RDONLY, 0):
│   │
│   ├── ZIP_Get_From_Cache(name, &pmsg, 0):
│   │   ├── InitializeZip()  ← 第一次调用时初始化全局锁
│   │   ├── MLOCK(zfiles_lock)
│   │   ├── 遍历全局 zfiles 链表
│   │   │   └── strcmp(name) && refs < 0xFFFF → zip->refs++ → 返回
│   │   └── MUNLOCK(zfiles_lock) → 未找到返回 NULL
│   │
│   └── 缓存未命中 → 打开新文件:
│       ├── ZFILE_Open(name, O_RDONLY) → open(fname, 0)
│       └── ZIP_Put_In_Cache0(name, zfd, &pmsg, 0, usemmap=JNI_TRUE):
│           │
│           ├── allocZip(name)  ← calloc(jzfile) + strdup(name) + 创建锁
│           ├── readFully(zfd, buf, 4) → 检查 LOCSIG
│           ├── IO_Lseek(zfd, 0, SEEK_END) → 获取文件大小
│           │
│           ├── ★ readCEN(zip, -1):  → 核心！读取中央目录
│           │   → 详见 24.2.1
│           │
│           ├── MLOCK(zfiles_lock)
│           ├── zip->next = zfiles; zfiles = zip;  ← 加入全局链表
│           └── MUNLOCK(zfiles_lock)
│
└── 返回 jzfile*
```

**缓存机制**：
- 全局链表 `zfiles` 维护所有打开的 ZIP 文件
- 用 `refs` 引用计数管理生命周期
- 同一 JAR 被多处（如多个 ClassLoader）打开时共享同一个 `jzfile`

### 24.2.1 readCEN — 读取中央目录（核心！）

```
readCEN(zip, knownTotal=-1):
│
├── findEND(zip, endbuf):
│   └── 从文件末尾向前搜索 "PK\x05\x06" 签名
│       ├── 每次读取 128 字节块，倒序扫描
│       ├── 找到 ENDSIG → 验证 ENDCOM 匹配 → 读取注释
│       ├── 还有 verifyEND() 额外验证:
│       │   ├── cenpos = endpos - ENDSIZ → 读 4 字节看是否 CENSIG
│       │   └── locpos = cenpos - ENDOFF → 读 4 字节看是否 LOCSIG
│       └── 返回 END 头位置
│
├── 从 END 提取 cenlen / cenoff / total:
│   └── 如果是 ZIP64 → findEND64() 获取 64 位值
│
├── cenpos = endpos - cenlen
│   zip->locpos = cenpos - cenoff  ← LOC 区域起始位置（有 stub 前缀时非 0）
│
├── ★ mmap 或 read CEN 数据:
│   ├── USE_MMAP 模式: mmap64(cenpos, cenlen + endhdrlen)
│   │   → 只 mmap CEN + END，不 mmap 整个文件！
│   │   → 原因: 避免增大进程 RSS 指标
│   └── 非 mmap 模式: malloc(cenlen) + readFullyAt()
│
├── ★ 构建哈希表:
│   entries = calloc(total, sizeof(jzcell))     ← cell 数组
│   tablelen = (total/2) | 1                    ← 取奇数减少碰撞
│   table = malloc(tablelen * sizeof(jint))     ← 链头数组
│   for (j = 0..tablelen) table[j] = ZIP_ENDCHAIN(-1)  ← 初始化为空
│
├── 遍历 CEN 条目:
│   for (cp = cenbuf; cp <= cenend - CENHDR; cp += CENSIZE(cp)):
│   │
│   │   ├── 校验 CENSIG 签名
│   │   ├── 校验不是加密 entry (CENFLG & 1 == 0)
│   │   ├── 校验压缩方法 (STORED=0 或 DEFLATED=8)
│   │   │
│   │   ├── 如果是 META-INF/ 下的文件 → addMetaName()
│   │   │
│   │   ├── entries[i].cenpos = cenpos + (cp - cenbuf)  ← 记录 CEN 偏移
│   │   ├── entries[i].hash = hashN(cp+CENHDR, nlen)    ← 记录名称哈希
│   │   │
│   │   └── ★ 插入哈希表头:
│   │       hsh = hash % tablelen
│   │       entries[i].next = table[hsh]  ← 新 entry 指向原来的链头
│   │       table[hsh] = i                ← 新 entry 成为新链头
│   │
│   └── zip->total = 最终 entry 计数
│
└── 返回 cenpos
```

**哈希表结构示意**：

```
table[] (链头数组, 大小 = total/2 | 1):
┌─────┬─────┬─────┬─────┬─────┬─────┬─────┐
│  3  │ -1  │  0  │ -1  │  7  │  2  │ -1  │  ← 指向 entries[] 的索引
└──┬──┴─────┴──┬──┴─────┴──┬──┴──┬──┴─────┘
   │           │           │     │
   ▼           ▼           ▼     ▼
entries[]:
┌───────────────────────────────────────────────────────┐
│ [0] hash=0x1234 cenpos=100 next=-1                    │ ← table[2] → [0]
│ [1] hash=0x5678 cenpos=200 next=-1                    │
│ [2] hash=0x9ABC cenpos=300 next=1                     │ ← table[5] → [2] → [1]
│ [3] hash=0xDEF0 cenpos=400 next=5                     │ ← table[0] → [3] → [5]
│ ...                                                   │
└───────────────────────────────────────────────────────┘
```

**设计要点**：
- **tablelen = (total/2) | 1**：取奇数是因为对奇数取模比偶数碰撞更少
- **只存 hash + cenpos**：不存文件名，节省内存。文件名在需要时从磁盘按 cenpos 读取
- **CEN 的 mmap 优化**：JDK 6+ 改为只 mmap CEN 区域，不 mmap 整个文件，大幅减少 RSS

### ZIP_GetEntry2 — 按名称查找 entry

```
ZIP_GetEntry2(zip, name, ulen, addSlash):
│
├── hsh = hashN(name, ulen)    ← 计算文件名哈希
├── ZIP_Lock(zip)
│
├── while(1):  ← 最多两轮：原名 + 追加 '/'
│   │
│   ├── 检查缓存:
│   │   if (zip->cache && equals(cache->name, name))
│   │       → 命中！移除缓存 → 返回
│   │
│   ├── ★ 遍历哈希链:
│   │   idx = table[hsh % tablelen]
│   │   while (idx != ZIP_ENDCHAIN):
│   │   │   zc = &entries[idx]
│   │   │   if (zc->hash == hsh):           ← 32 位哈希匹配
│   │   │       ze = newEntry(zip, zc)       ← 从磁盘读 CEN 创建 jzentry
│   │   │       if equals(ze->name, name):
│   │   │           → 精确匹配！返回
│   │   │       else:
│   │   │           → 假阳性，释放 ze，继续
│   │   │   idx = zc->next                   ← 沿链前进
│   │
│   ├── 如果未找到且 addSlash:
│   │   name[ulen++] = '/'               ← 追加斜杠
│   │   hsh = hash_append(hsh, '/')      ← 增量更新哈希
│   │   idx = table[hsh % tablelen]      ← 重新查找
│   │   addSlash = false                 ← 只追加一次
│   │
│   └── 否则 break
│
└── ZIP_Unlock(zip) → 返回 ze 或 NULL
```

**addSlash 优化**：查找 `java/lang` 时，会先找 `java/lang`，找不到再找 `java/lang/`。这支持了目录 entry 的查找。

### newEntry — 从 CEN 构建 jzentry

```
newEntry(zip, zc, accessHint):
│
├── 读取 CEN 头:
│   ├── USE_MMAP: cen = maddr + cenpos - offset   ← 直接指向 mmap 内存
│   ├── ACCESS_RANDOM: readCENHeader(cenpos, 160)  ← 读 160 字节（经验值）
│   └── ACCESS_SEQUENTIAL: sequentialAccessReadCENHeader()  ← 8KB 页缓存
│
├── 解析 CEN 字段:
│   ze->time  = CENTIM(cen)
│   ze->size  = CENLEN(cen)     ← 解压后大小
│   ze->csize = CENHOW(cen)==STORED ? 0 : CENSIZ(cen)   ← 压缩后大小
│   ze->crc   = CENCRC(cen)
│   ze->pos   = -(zip->locpos + CENOFF(cen))   ← 负值！延迟计算
│   ze->flag  = CENFLG(cen)
│
├── 复制文件名:
│   ze->name = malloc(nlen+1)
│   memcpy(ze->name, cen+CENHDR, nlen)
│
├── 处理 extra 数据 (ZIP64 扩展):
│   if size/csize/locoff == 0xFFFFFFFF:
│       → 从 extra 中的 ZIP64_EXTID 读取 64 位值
│
└── 返回 jzentry*
```

### ZIP_ReadEntry — 读取完整 entry 数据

这是 HotSpot 通过 `ReadEntry` 函数指针调用的函数。

```
ZIP_ReadEntry(zip, entry, buf, entryname):
│
├── strcpy(entryname, entry->name)   ← 复制文件名
│
├── if (entry->csize == 0):    ← STORED（未压缩）
│   └── 循环调用 ZIP_Read() 读取原始数据
│       ZIP_Read():
│       ├── ZIP_GetEntryDataOffset(entry)  ← 延迟计算数据偏移
│       │   └── 如果 pos ≤ 0: readFullyAt(LOC 头) → 计算实际偏移
│       └── readFullyAt(zfd, buf, len, start)  ← pread()
│
├── else:                      ← DEFLATED（压缩）
│   └── InflateFully(zip, entry, buf, &msg):
│       ├── inflateInit2(&strm, -MAX_WBITS)   ← zlib 初始化（raw deflate）
│       ├── while (count > 0):
│       │   ├── ZIP_Read(zip, entry, pos, tmp, 4096)  ← 分块读压缩数据
│       │   └── inflate(&strm, Z_PARTIAL_FLUSH)        ← zlib 解压
│       └── inflateEnd(&strm)
│
└── ZIP_FreeEntry(zip, entry)  ← 放入 1 条缓存
```

**1 条缓存设计**（`zip->cache`）：
- 每个 `jzfile` 只缓存 **最后一个释放的 jzentry**
- 下次 `ZIP_GetEntry2` 先检查缓存
- 优化了连续访问同一 entry 的场景（如先 `FindEntry` 再 `ReadEntry`）

### libzip 总结

```
┌────────────────────────────────────────────────────────────────────┐
│                    libzip.so 核心读取链路                            │
│                                                                    │
│  ZIP_Open(name)                                                    │
│  ├── 缓存查找 → 引用计数 ++                                         │
│  └── readCEN() → 构建 entries[]+table[] 哈希表                      │
│                                                                    │
│  ZIP_FindEntry(zip, "java/lang/String.class")                      │
│  └── ZIP_GetEntry2()                                               │
│      ├── hashN(name) → table[hash%tablelen] → 链遍历                │
│      ├── zc->hash 匹配 → newEntry() 从 CEN 创建 jzentry            │
│      └── 精确比较名称 → 返回 jzentry*                                │
│                                                                    │
│  ZIP_ReadEntry(zip, entry, buf, name)                              │
│  ├── STORED: ZIP_Read() → pread()                                  │
│  └── DEFLATED: InflateFully() → zlib inflate()                     │
│                                                                    │
│  ZIP_Close(zip)                                                    │
│  └── refs-- → 0 时从链表移除并释放                                   │
└────────────────────────────────────────────────────────────────────┘
```

---

## 24.3 libjimage.so — JDK 模块镜像读取

### 为什么需要 jimage？

JDK 8 的 `rt.jar`（约 65MB）是标准 ZIP 格式，问题：
1. **启动慢**：readCEN 需要读取整个中央目录
2. **内存大**：哈希表 entries[] + table[] 随 entry 数量线性增长
3. **查找慢**：哈希碰撞时需要从磁盘读 CEN 比较文件名

JDK 9+ 的 `lib/modules` 使用自定义的 jimage 格式，优化：
1. **Perfect Hash**：查找 O(1)，无碰撞（或最多 2 次 hash）
2. **内存映射**：整个索引 mmap 到内存
3. **原生字节序**：无需转换（平台相关，但启动快）

### jimage 文件格式

```
jimage 文件布局 (lib/modules):
┌────────────────────────────────────────────────────────────────────┐
│  ImageHeader (28 bytes)                                           │
│  ├── magic        = 0xCAFEDADA                                    │
│  ├── version      = major=1, minor=0                              │
│  ├── flags        = 0                                             │
│  ├── resource_count = 资源总数                                     │
│  ├── table_length   = Perfect Hash 表长度                          │
│  ├── locations_size = 位置属性区字节数                               │
│  └── strings_size   = 字符串表字节数                                │
├────────────────────────────────────────────────────────────────────┤
│  Index:                                                           │
│  ├── Redirect Table  (table_length × 4 bytes)                     │
│  │   └── s4[] : 0=not found, <0=-1-index, >0=reseed              │
│  ├── Offsets Table   (table_length × 4 bytes)                     │
│  │   └── u4[] : 指向 Location 属性数据的偏移                       │
│  ├── Location Data   (locations_size bytes)                       │
│  │   └── 压缩的属性流（module/parent/base/extension/offset/size）  │
│  └── String Table    (strings_size bytes)                         │
│      └── NUL 结尾的 UTF-8 字符串池                                 │
├────────────────────────────────────────────────────────────────────┤
│  Resources:                                                       │
│  └── .class 文件数据（可能压缩）                                    │
└────────────────────────────────────────────────────────────────────┘
```

### Perfect Hash 查找算法

**核心算法**（Practical Minimal Perfect Hashing）：

```
查找 path = "/java.base/java/lang/String.class":

步骤 1: redirectIndex = hash(path, DEFAULT_SEED=0x01000193) % table_length
步骤 2: redirect = redirectTable[redirectIndex]
步骤 3:
  if (redirect == 0)  → NOT FOUND
  if (redirect < 0)   → locationIndex = -1 - redirect     ← 直接索引，无碰撞
  if (redirect > 0)   → locationIndex = hash(path, redirect) % table_length  ← 用新种子重 hash
步骤 4: location = locationTable[locationIndex]
步骤 5: verify(location, path)  → 精确匹配验证
```

**性能对比**：

| 维度 | libzip (ZIP 哈希表) | libjimage (Perfect Hash) |
|------|-------------------|------------------------|
| 查找最佳 | O(1) | O(1) |
| 查找最差 | O(n)（链很长时） | O(1)（最多 2 次 hash） |
| 假阳性处理 | 从磁盘读 CEN 比较名称 | 从 mmap 内存比较名称 |
| 内存开销 | entries[N] × 12B + table[N/2] × 4B | redirect[M] × 4B + offsets[M] × 4B |
| 文件 I/O | 按需 pread（可能未 mmap） | 索引完全 mmap |

### ImageLocation — 属性压缩流

每个资源的位置信息被压缩成字节流：

```
属性流格式：
  [header byte] [value bytes...]  [header byte] [value bytes...]  ... [0x00]

  header byte:
    bit 7-3: attribute kind (0-7)
    bit 2-0: value length - 1 (0-7, 即实际 1-8 字节)

  attribute kinds:
    0 = ATTRIBUTE_END         结束标记
    1 = ATTRIBUTE_MODULE      模块名（字符串表偏移）
    2 = ATTRIBUTE_PARENT      包名/父路径（字符串表偏移）
    3 = ATTRIBUTE_BASE        基本名称（字符串表偏移）
    4 = ATTRIBUTE_EXTENSION   扩展名（字符串表偏移）
    5 = ATTRIBUTE_OFFSET      资源在文件中的偏移
    6 = ATTRIBUTE_COMPRESSED  压缩后大小（0=未压缩）
    7 = ATTRIBUTE_UNCOMPRESSED 解压后大小

示例："/java.base/java/lang/String.class" 的属性流：
  [0x0A] [offset_to_"java.base"]     → MODULE = "java.base"
  [0x12] [offset_to_"java/lang/"]    → PARENT = "java/lang/"
  [0x1A] [offset_to_"String"]        → BASE   = "String"
  [0x22] [offset_to_"class"]         → EXTENSION = "class"
  [0x2A] [0x00] [0x12] [0x34]        → OFFSET = 0x1234
  [0x3A] [0x00] [0x04] [0x56]        → UNCOMPRESSED = 0x456
  [0x00]                              → END
```

**为什么把路径拆分成 module/parent/base/extension？**
- **去重**：相同 module 名、包名、扩展名只存一次在字符串表中
- **压缩率高**：数千个 .class 共享 "class" 扩展名、共享模块名
- **快速验证**：`verify_location()` 可以逐段比较，无需拼接完整路径

### libjimage 6 个 API

```
API                        功能                          内部实现
─────────────────────────────────────────────────────────────────────
JIMAGE_Open(name, &err)    打开 jimage 文件              ImageFileReader::open()
                           → mmap 索引 + 初始化表        → 共享表 _reader_table

JIMAGE_Close(jimage)       关闭 jimage 文件              ImageFileReader::close()
                           → 引用计数 → 0 时真正关闭      → 从 _reader_table 移除

JIMAGE_PackageToModule     包名 → 模块名                  查询 /packages/<pkg> 资源
(jimage, pkg)              如 "java/lang" → "java.base"  → ImageModuleData

JIMAGE_FindResource        查找资源位置                    拼接 "/<module>/<name>"
(jimage, module, ver,      → Perfect Hash 查找            → find_location_index()
 name, &size)              → 返回 LocationRef + size

JIMAGE_GetResource         读取资源数据                    get_resource(offset, buf)
(jimage, location,         → 如果压缩则解压               → read_at() 或 mmap
 buffer, size)

JIMAGE_ResourceIterator    遍历所有资源                    遍历 offsets_table
(jimage, visitor, arg)     → 调用 visitor 回调            → 解析每个 ImageLocation
```

### ClassPathImageEntry::open_stream — HotSpot 如何通过 libjimage 加载类

**文件**：`classLoader.cpp` 第 493-553 行

```
ClassPathImageEntry::open_stream(name="java/lang/String.class"):
│
├── ★ 第一次尝试：空模块名
│   JImageFindResource(_jimage, "", version, name, &size)
│   → 通常失败（jimage 中资源路径都带模块名前缀）
│
├── ★ 确定模块名:
│   pkg_name = package_from_name(name)  → "java/lang"
│   │
│   ├── 模块系统未初始化（JVM 早期）:
│   │   → JImageFindResource(_jimage, "java.base", version, name, &size)
│   │   → 早期只从 java.base 找
│   │
│   └── 模块系统已初始化:
│       → PackageEntry* pe = get_package_entry(name, ...)
│       → ModuleEntry* mod = pe->module()
│       → module_name = mod->name()->as_C_string()  → "java.base"
│       → JImageFindResource(_jimage, "java.base", version, name, &size)
│
├── 找到 location (非 0):
│   char* data = NEW_RESOURCE_ARRAY(char, size)
│   JImageGetResource(_jimage, location, data, size)  ← 读取 .class 字节码
│   return new ClassFileStream(data, size, _name, verify)
│
└── 未找到: return NULL
```

**关键设计**：
- 模块系统初始化**之前**（JVM 早期加载 `Object`、`String` 等），硬编码使用 `"java.base"` 作为模块名
- 模块系统初始化**之后**，通过 `PackageEntry → ModuleEntry` 查找包所属的模块

---

## 24.4 HotSpot ClassPathEntry 集成视图

### ClassPathZipEntry::open_stream — 从 JAR 读 .class

```
ClassPathZipEntry::open_stream(name="com/wjcoder/Main.class"):
│
├── open_entry(name, &filesize, false):
│   ├── ThreadToNativeFromVM ttn(thread)  ← 切换到 native 状态
│   ├── (*FindEntry)(_zip, name, &filesize, &name_len)
│   │   → ZIP_FindEntry() → ZIP_GetEntry2() 哈希查找
│   │   → 返回 jzentry*，filesize = entry->size
│   ├── buffer = NEW_RESOURCE_ARRAY(u1, size)
│   ├── (*ReadEntry)(_zip, entry, buffer, filename)
│   │   → ZIP_ReadEntry() → ZIP_Read() + InflateFully()
│   └── 返回 buffer
│
└── return new ClassFileStream(buffer, filesize, _zip_name, verify)
```

### 完整类加载资源读取流程

```
                      SystemDictionary::load_instance_class()
                                    │
              ┌─────────────────────┼─────────────────────┐
              ▼                     ▼                     ▼
     Boot ClassLoader       Platform ClassLoader    App ClassLoader
     (C++ 层)               (Java 层)              (Java 层)
              │                     │                     │
              ▼                     ▼                     ▼
     ClassLoader::load_class()  URLClassPath          URLClassPath
              │                  .getResource()        .getResource()
              │                     │                     │
     ┌────────┼─────────┐          │                     │
     ▼        ▼         ▼          ▼                     ▼
  jimage    exploded  -Xboot/a   jar 文件              jar 文件
     │      build       │          │                     │
     ▼        ▼         ▼          ▼                     ▼
  libjimage  文件系统  libzip     libzip               libzip
  .so        read()   .so        .so                  .so
     │                  │          │                     │
     ▼                  ▼          ▼                     ▼
  lib/modules         *.jar      *.jar                *.jar
  (jimage)            (ZIP)      (ZIP)                (ZIP)
     │                  │          │                     │
     └──────────────────┴──────────┴─────────────────────┘
                                │
                                ▼
                     ClassFileStream (字节码)
                                │
                                ▼
                     KlassFactory::create_from_stream()
                                │
                                ▼
                     ClassFileParser::parse_stream()
```

---

## 24.5 面试专题

### Q1: JAR 文件的内部结构是什么？JVM 是怎么从 JAR 中读取 .class 文件的？

**源码级回答**：

JAR 文件就是 ZIP 格式。分三个区域：LOC（每个文件的头+数据）、CEN（中央目录索引）、END（终止记录）。

JVM 读取过程：
1. **ZIP_Open**：从文件末尾反向搜索 END 签名（`PK\x05\x06`），从 END 中获取 CEN 的偏移和长度
2. **readCEN**：读取整个 CEN 区域（或 mmap），遍历每个 CEN entry，为每个文件计算名称哈希，构建 `entries[] + table[]` 哈希表。CEN 中只记录文件名哈希和 CEN 偏移，不拷贝文件名（节省内存）
3. **ZIP_FindEntry**：对目标文件名计算哈希 → `table[hash % tablelen]` → 沿链遍历 → 哈希匹配时从磁盘读 CEN 创建 `jzentry`，精确比较名称
4. **ZIP_ReadEntry**：如果 `csize == 0` 直接 `pread()` 读取数据；否则分块读取压缩数据，通过 zlib `inflate()` 解压

### Q2: JDK 9+ 的 jimage 和 JAR 有什么区别？为什么 JDK 9 不再使用 rt.jar？

| 维度 | JAR (ZIP) | jimage |
|------|-----------|--------|
| 格式 | 标准 ZIP | 自定义二进制（0xCAFEDADA） |
| 字节序 | 小端（ZIP 规范） | 原生字节序（无需转换） |
| 查找算法 | 链式哈希表 O(1)~O(n) | Perfect Hash O(1)，最多 2 次 hash |
| 路径编码 | 完整路径字符串 | 拆分为 module/parent/base/ext + 字符串去重 |
| 索引存储 | 哈希表在内存中构建 | 索引直接 mmap（文件即索引） |
| 平台依赖 | 无 | 有（字节序） |
| 启动速度 | 需要 readCEN 构建哈希表 | mmap 后直接使用 |

**为什么替换？** rt.jar 包含 ~30000 个类，readCEN 需要读取整个中央目录并构建哈希表，影响启动速度。jimage 的索引直接 mmap，Perfect Hash 无需构建运行时数据结构。

### Q3: HotSpot 中 Boot ClassLoader 是怎么搜索类文件的？

三级搜索，按顺序：
1. **--patch-module**：如果类所在包被 patch-module 覆盖，从指定路径加载
2. **jimage/exploded**：生产环境从 `lib/modules`（ClassPathImageEntry → libjimage.so），开发构建从 exploded 目录（ClassPathDirEntry → 文件系统 read）
3. **-Xbootclasspath/a**：追加的引导类路径，通常是 Agent 注入的 JAR（ClassPathZipEntry → libzip.so）

### Q4: ZIP_Open 的缓存机制是怎么工作的？

全局链表 `zfiles` + 引用计数。`ZIP_Get_From_Cache` 遍历链表按文件名匹配；找到则 `refs++` 返回。`ZIP_Close` 时 `refs--`，归零则从链表移除并 `freeZip`。这确保同一 JAR 被多个 ClassLoader 打开时共享底层的 `jzfile`（包括已构建的哈希表和 mmap 数据）。

### Q5: 为什么 jzentry 的 pos 是负值？什么时候变成正值？

`pos` 存储为 `-(locpos + CENOFF)`（LOC 头偏移的负值）。这是**延迟计算**设计：CEN 中存的是 LOC 头偏移，但实际数据在 LOC 头之后（LOC 头大小固定 30 字节 + 变长的文件名 + 变长的 extra）。必须读取 LOC 头才能确定精确的数据偏移。

`ZIP_GetEntryDataOffset()` 在第一次访问时读取 LOC 头，计算 `pos = -pos + LOCHDR + LOCNAM + LOCEXT`，将 `pos` 更新为正值（实际数据偏移）。之后的访问直接使用正值，避免重复读取。

这个优化将 javac 在慢速文件系统上的性能提升了 **10 倍**（源码注释原文）。

### Q6: HotSpot 为什么用函数指针而不是直接链接 libzip.so？

三个原因：
1. **可选依赖**：如果 libzip.so 不存在（理论上），JVM 可以降级
2. **延迟加载**：`load_zip_library()` 在 `ClassLoader::initialize()` 中调用，而非 JVM 启动最早期
3. **平台解耦**：HotSpot 编译时不依赖 libzip.so 的头文件，运行时通过 `os::dll_load` + `os::dll_lookup` 绑定

---

*分析文件*：
- `src/java.base/share/native/libzip/zip_util.h` — ZIP 核心数据结构（288 行）
- `src/java.base/share/native/libzip/zip_util.c` — ZIP 核心实现（1698 行）
- `src/java.base/share/native/libzip/Inflater.c` — zlib 解压 JNI（306 行）
- `src/java.base/share/native/libjimage/jimage.hpp` — jimage 6 API 声明（194 行）
- `src/java.base/share/native/libjimage/jimage.cpp` — jimage 6 API 实现（218 行）
- `src/java.base/share/native/libjimage/imageFile.hpp` — ImageFileReader/ImageLocation 定义（586 行）
- `src/java.base/share/native/libjimage/imageFile.cpp` — ImageFileReader 实现（572 行）
- `src/hotspot/share/classfile/classLoader.hpp` — ClassPathEntry 体系定义（550 行）
- `src/hotspot/share/classfile/classLoader.cpp` — ClassLoader::load_class + open_stream 实现（2218 行）
