# libzip.so — ZIP/JAR 压缩与类加载深度剖析

> 文件位置：`src/java.base/share/native/libzip/` (zlib + zip_util.c)
> 
> 目标：理解 JAR 文件如何解析、类加载器如何从 JAR 中读取 class
> 
> 方法论：程序 = 数据结构 + 算法
> 标准环境：-Xms8g -Xmx8g -XX:+UseG1GC

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

**一句话概括**：libzip.so 实现 **ZIP/JAR 文件格式解析 + zlib 压缩算法**，是 Java 类加载器读取 class 文件的基础。

```
类加载器读取 class 文件流程：

BootstrapClassLoader
    ↓
openJar() → 打开 rt.jar
    ↓
libzip.so: ZIP_Open("rt.jar")
    ↓
读取中央目录 (Central Directory)
    ↓
ZIP_FindEntry("java/lang/Object.class")
    ↓
ZIP_ReadEntry() → 解压 → 返回 byte[]
    ↓
defineClass() → Class 对象
```

### 0.2 为什么需要 libzip？

```
问题：JVM 需要从 JAR 中读取大量 class 文件

方案对比：

1. 每次读取都打开文件 → ❌ 性能差
2. 解压到目录 → ❌ 占用空间大
3. 直接读取 ZIP 文件 → ✅ libzip 方案

libzip 优势：
- 内存映射 (mmap) 快速访问中央目录
- 按需解压单个文件
- 多 JAR 文件缓存复用
```

---

## 一、数据结构全景 ⭐

### 1.1 jzfile — ZIP 文件描述符 ⭐⭐⭐⭐⭐

**解决什么问题**：表示一个打开的 ZIP/JAR 文件，包含文件句柄、哈希表、缓存。

```c
// zip_util.h:207-237
typedef struct jzfile {   /* Zip file */
    char *name;           /* zip 文件名 (如 "rt.jar") */
    jint refs;            /* 引用计数 */
    jlong len;            /* 文件长度 (bytes) */
    
#ifdef USE_MMAP
    unsigned char *maddr; /* 内存映射地址 (CEN + ENDHDR) */
    jlong mlen;           /* 映射长度 */
    jlong offset;         /* 映射起始偏移 */
    jboolean usemmap;     /* 是否使用 mmap */
#endif
    
    jboolean locsig;      /* ZIP 文件是否以 LOCSIG 开头 */
    cencache cencache;    /* CEN 头缓存 */
    ZFILE zfd;            /* 文件描述符 */
    void *lock;           /* 读锁 */
    char *comment;         /* ZIP 文件注释 */
    jint clen;            /* 注释长度 */
    char *msg;            /* 错误信息 */
    
    /* ===== 哈希表：快速查找 entry ===== */
    jzcell *entries;      /* 哈希单元格数组 */
    jint total;           /* entry 总数 */
    jint *table;          /* 哈希链头数组 */
    jint tablelen;        /* 哈希表大小 */
    
    struct jzfile *next;  /* 下一个 ZIP 文件 (搜索链) */
    jzentry *cache;       /* 最近释放的 jzentry 缓存 */
    
    /* ===== META-INF 元数据 ===== */
    char **metanames;     /* META-INF 目录下的文件名 */
    jint metacurrent;     /* metanames 数组当前索引 */
    jint metacount;       /* metanames 数组大小 */
    
    jlong lastModified;   /* 最后修改时间 */
    jlong locpos;        /* 第一个 LOC 头的位置 */
} jzfile;
```

**sizeof**：约 200-300 字节（不含 entries 数组）

---

### 1.2 jzcell — 哈希单元格

```c
// zip_util.h:183-187
typedef struct jzcell {
    unsigned int hash;    /* 名字的 32 位哈希值 */
    unsigned int next;    /* 哈希链：指向下一个 entry */
    jlong cenpos;         /* 中央目录头的位置 (偏移量) */
} jzcell;
```

**作用**：用空间换时间，通过哈希表 O(1) 查找 entry

---

### 1.3 jzentry — ZIP 条目

```c
// Java 层定义 (java.util.zip.ZipEntry)
class ZipEntry {
    String name;          /* 条目名 */
    long crc;             /* CRC-32 校验 */
    long size;            /* 原始大小 */
    long csize;           /* 压缩后大小 */
    long mtime;           /* 修改时间 */
    int method;           /* 压缩方法: STORED/DEFLATED */
    // ...
}
```

---

## 二、ZIP 文件格式 ⭐⭐⭐

### 2.1 ZIP 文件结构

```
+---------------------------+
| Local File Header 1       |  ← 文件数据前
|   (文件名 + 数据)         |
+---------------------------+
| Local File Header 2       |
|   (文件名 + 数据)         |
+---------------------------+
| ...                      |
+---------------------------+
| Central Directory        |  ← 中央目录
|   (文件元数据)           |
+---------------------------+
| End of Central Directory |  ← 目录结束
+---------------------------+

三个关键部分：
1. LOC (Local file header) - 每个文件的本地头
2. CEN (Central directory) - 中央目录索引
3. END (End of central directory) - 结束标记
```

### 2.2 中央目录结构

```
CEN Header (46 bytes固定 + 可变部分):
+-----------------------------+
| 0-3: 签名 (0x02014b50)      |  ← PK\x01\x02
| 4-5: version made by        |
| 6-7: version needed         |
| 8-9: general purpose flags  |
| 10-11: compression method   |  ← 0=STORED, 8=DEFLATED
| 12-13: last mod time        |
| 14-17: CRC-32               |
| 18-21: compressed size      |  ← 压缩后大小
| 22-25: uncompressed size    |  ← 原始大小
| 26-27: filename length      |  ← 名字长度
| 28-29: extra field length   |
| 30-31: comment length       |
| 32-33: disk number start    |
| 34-35: internal attrs       |
| 36-39: external attrs       |
| 40-43: local header offset  |  ← LOC 偏移量
| 44+: filename + extra + comment
+-----------------------------+
```

---

## 三、核心流程 ⭐⭐⭐⭐⭐

### 3.1 打开 JAR 文件

```c
// zip_util.c:910-919
JNIEXPORT jzfile *
ZIP_Open(const char *name, char **pmsg)
{
    // ★ 核心函数：打开 ZIP 文件
    jzfile *file = ZIP_Open_Generic(name, pmsg, O_RDONLY, 0);
    if (file == NULL && pmsg != NULL && *pmsg != NULL) {
        free(*pmsg);
        *pmsg = "Zip file open error";
    }
    return file;
}
```

**流程**：

```
ZIP_Open("rt.jar")
    ↓
ZIP_Open_Generic()
    ↓
1. 检查缓存: ZIP_Get_From_Cache(name)
    ├─ 命中 → 返回缓存的 jzfile
    └─ 未命中 → 继续
    ↓
2. 打开文件: ZFILE_Open(name, O_RDONLY)
    ↓
3. 读取 END: findEND() → 定位中央目录
    ↓
4. 解析 CEN: readCEN() → 填充哈希表
    ↓
5. 加入缓存: ZIP_Put_In_Cache()
    ↓
6. 返回 jzfile
```

### 3.2 查找 Entry（核心热路径）

```c
// zip_util.c: ...
ZIP_FindEntry(jzfile *zip, char *name, jint *sizeP, jint *nameLenP)
{
    // ★ 1. 计算哈希值
    unsigned int hash = hashFor(name);
    
    // ★ 2. 定位哈希桶
    int idx = hash % zip->tablelen;
    
    // ★ 3. 遍历哈希链
    for (int i = zip->table[idx]; i != 0; i = zip->entries[i].next) {
        jzcell *cell = &zip->entries[i];
        
        // ★ 4. 哈希匹配后精确比较
        if (cell->hash == hash && strcmp(name, entryName) == 0) {
            // ★ 5. 找到！返回位置
            return cell->cenpos;
        }
    }
    
    return NULL;  // 未找到
}
```

**性能优化**：
- 哈希表 O(1) 查找
- 先比较哈希，再精确匹配（减少 strcmp 调用）
- 多级缓存：jzfile 缓存 + jzentry 缓存

### 3.3 读取 Entry

```c
// zip_util.c: ...
ZIP_ReadEntry(jzfile *zip, jzentry *entry, 
             unsigned char *buf, char *entrynm)
{
    // ★ 1. 定位 LOC 头
    lfd = LOCHDR + entry->name + entry->ext;
    
    // ★ 2. 读取 CRC/大小
    CRC = LOCCRC(buf);
    csize = LOCSIZ(buf);
    size = LOCLEN(buf);
    
    // ★ 3. 读取文件数据
    readFully(fd, buf + LOCHDR + nameLen + extLen, csize);
    
    // ★ 4. 解压 (如果是 DEFLATED)
    if (method == DEFLATED) {
        inflate(buf, size, csize);  // 调用 zlib
    }
    
    // ★ 5. 校验 CRC
    if (crc32(...) != CRC) {
        throw new ZipException("CRC error");
    }
}
```

---

## 四、与类加载器的集成 ⭐⭐⭐⭐⭐

### 4.1 BootstrpClassLoader 打开 JAR

```java
// Java 层: java.lang.ClassLoader
protected Class<?> loadClass(String name, boolean resolve) {
    // ★ 1. 检查已加载
    Class<?> c = findLoadedClass(name);
    if (c != null) return c;
    
    // ★ 2. 尝试加载 (Bootstrap)
    if (parent == null) {
        c = findBootstrapClassOrNull(name);  // ← 关键！
    }
}

// java.util.jar.JarFile
public ZipEntry getEntry(String name) {
    return getEntry(name, false);
}

private native long getEntry0(JarFile zf, String name);
//    ↓ libzip.so: ZIP_FindEntry()
```

### 4.2 类加载流程

```
UserCode: Class.forName("java.lang.Object")
    ↓
BootstrapClassLoader.loadClass("java.lang.Object")
    ↓
JarFile.getEntry("java/lang/Object.class")
    ↓
libzip: ZIP_FindEntry(jzfile, "java/lang/Object.class")
    ↓ 找到 → 返回 cenpos
libzip: ZIP_ReadEntry(jzfile, entry, buf)
    ↓ 读取 + 解压 → byte[] classData
    ↓
defineClass(classData)
    ↓
Class 对象
```

---

## 五、zlib 压缩算法 ⭐⭐

### 5.1 压缩/解压接口

```c
// Deflater.c (压缩)
Java_java_util_zip_Deflater_deflateBytesBytes(...)
    ↓
deflate(z_stream *strm, Z_FINISH)
    ↓
zlib 压缩算法

// Inflater.c (解压)
Java_java_util_zip_Inflater_inflateBytesBytes(...)
    ↓
inflate(z_stream *strm, Z_NO_FLUSH)
    ↓
zlib 解压算法
```

### 5.2 压缩级别

```c
// zlib.h
#define Z_NO_COMPRESSION      0
#define Z_BEST_SPEED          1
#define Z_BEST_COMPRESSION    9
#define Z_DEFAULT_COMPRESSION -1

// Java: Deflater(int level)
level = 9;  // 最高压缩
level = 1;  // 最快速度
```

---

## 六、核心文件清单

| 文件 | 职责 |
|------|------|
| `zip_util.c` | ZIP 文件解析 (核心) |
| `zip_util.h` | 数据结构定义 |
| `Inflater.c` | 解压算法 |
| `Deflater.c` | 压缩算法 |
| `zlib/` | zlib 源码 |

---

## 七、总结

### 7.1 核心设计

| 设计点 | 选择 | 理由 |
|--------|------|------|
| 索引结构 | 哈希表 | O(1) 查找 |
| 中央目录 | mmap | 快速随机访问 |
| 缓存 | jzfile 缓存池 | 复用打开的 JAR |
| 压缩 | zlib | 标准、高效 |

### 7.2 性能关键点

1. **哈希表**：首次打开时构建，之后 O(1) 查找
2. **mmap**：中央目录常驻内存，避免重复读取
3. **entry 缓存**：释放的 jzentry 回收复用
4. **写时复制**：父子类加载器共享 JAR 缓存

### 7.3 与类加载器的关键接口

```c
// libzip → 类加载器
jzfile *ZIP_Open(name, &msg);           // 打开 JAR
jzentry *ZIP_FindEntry(jzfile, name);   // 查找 class
ZIP_ReadEntry(jzfile, entry, buf);      // 读取 class 数据
```

---

> 下一步：分析 libjimage.so（JDK 9+ 模块化）
