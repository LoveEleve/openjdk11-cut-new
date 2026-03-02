# libjimage.so — JDK 9+ 模块化镜像深度剖析

> 文件位置：`src/java.base/share/native/libjimage/` (C++ 实现)
> 
> 目标：理解 JDK 9+ 的模块化镜像（jimage）如何实现比 JAR 更快的类加载
> 
> 方法论：程序 = 数据结构 + 算法
> 标准环境：-Xms8g -Xmx8g -XX:+UseG1GC

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

**一句话概括**：libjimage.so 实现 **JImage 文件格式**，是 JDK 9+ 用来替代部分 JAR 文件的优化方案，提供比 ZIP 更快的类加载速度。

```
JDK 8 及以前：
  rt.jar (约 60MB)
    ↓
  每次加载类都要在 ZIP 中央目录中查找
    ↓
  性能一般

JDK 9+：
  modules.jimage (约 50MB)
    ↓
  Minimal Perfect Hashing: O(1) 查找
    ↓
  更快！
```

### 0.2 为什么需要 JImage？

```
问题：JAR 文件查找太慢

ZIP 中央目录查找：
  - 需要解析字符串
  - 哈希 + 遍历
  - 平均 O(n/m) 复杂度

JImage 优化：
  - Minimal Perfect Hashing (MPH)
  - O(1) 查找，无哈希冲突
  - 内存映射，无 I/O
```

### 0.3 JImage vs JAR

| 特性 | JAR | JImage |
|------|-----|--------|
| 文件格式 | ZIP | 自定义 |
| 查找算法 | 哈希表 | MPH |
| 查找复杂度 | O(1) 均摊 | O(1) 确定 |
| 压缩 | DEFLATE | 无压缩 |
| 适用场景 | 用户代码 | JDK 核心模块 |

---

## 一、JImage 文件格式 ⭐⭐⭐⭐⭐

### 1.1 文件结构

```
+---------------------------+
| Header (32 bytes)         |  ← 文件头
+---------------------------+
| Index                     |  ← 索引区 (MPH 表)
|   - Redirect Table        |
|   - Attribute Offsets     |
|   - Attribute Data        |
|   - Strings              |
+---------------------------+
| Resources                 |  ← 资源数据区
+---------------------------+

Header: 元信息
Index: 快速查找表
Resources: 实际数据（class 文件等）
```

### 1.2 文件头

```c
// imageFile.hpp:65-80
struct ImageHeader {
    u4 magic;          /* 0xCAFEDADA */
    u1 major;          /* 主版本 */
    u1 minor;          /* 次版本 */
    u4 flags;          /* 标志位 */
    u4 resource_count; /* 资源数量 */
    u4 table_length;   /* 哈希表长度 */
    u4 attributes_size;/* 属性区大小 */
    u4 strings_size;   /* 字符串区大小 */
};
```

---

## 二、核心数据结构 ⭐⭐⭐

### 2.1 JImageFile — 文件描述符

```c
// imageFile.hpp: ...
class JImageFile {
public:
    const char* file_name;        /* 文件路径 */
    int file;                     /* 文件描述符 */
    void* file_mapping;          /* mmap 映射 */
    size_t file_size;            /* 文件大小 */
    
    /* ===== 索引区 ===== */
    u1* index;                   /* 索引起始地址 */
    u4 index_size;               /* 索引大小 */
    
    /* ===== 哈希表 ===== */
    u4* redirect_table;         /* 重定向表 (MPH) */
    u4* location_table;         /* 位置表 */
    
    /* ===== 资源区 ===== */
    u1* resources;              /* 资源数据起始地址 */
    u4 resources_size;          /* 资源数据大小 */
    
    /* ===== 字符串 ===== */
    u1* strings;                /* 字符串池 */
    u4 strings_size;             /* 字符串池大小 */
};
```

### 2.2 ImageLocation — 资源位置

```c
// jimage.hpp: ...
class ImageLocation {
public:
    // 从 Attribute Data 中解析出的信息
    u8 offset;          /* 资源在文件中的偏移 */
    u8 uncompressed_size;/* 未压缩大小 */
    u8 compressed_size;  /* 压缩大小 */
    u4 entry_size;       /* 条目大小 */
    // ...
};
```

---

## 三、核心算法 ⭐⭐⭐⭐⭐

### 3.1 Minimal Perfect Hashing

**核心思想**：MPH 是一种完美的哈希，没有冲突，且 O(1) 查找。

```
传统哈希表：
  key → hash() → table[index]
  → 冲突处理 → 最坏 O(n)

MPH:
  key → hash1() → redirect
  → hash2() + redirect → index
  → 无冲突！O(1) 确定
```

### 3.2 查找算法

```cpp
// jimage.cpp: ...
JImageLocationRef 
JIMAGE_FindResource(JImageFile* jimage,
                   const char* module_name,
                   const char* version,
                   const char* name,
                   jlong* size) {
    // ★ 1. 构建完整路径
    // "/java.base/java/lang/String.class"
    char path[JIMAGE_MAX_PATH];
    build_path(path, module_name, name);
    
    // ★ 2. MPH 查找
    u4 hash1 = hash_string(path, DEFAULT_SEED);
    u4 hash2 = hash_string(path, redirect);
    
    // ★ 3. 计算索引
    int index = redirect_table[hash1 % table_length];
    if (index < 0) {
        // ★ 命中！直接使用
        index = -1 - index;
    } else {
        // ★ 二次哈希
        index = location_table[index + (hash2 % table_length)];
    }
    
    // ★ 4. 验证（确保真的找到了）
    if (!verify_match(path, index)) {
        return JIMAGE_NOT_FOUND;
    }
    
    // ★ 5. 返回位置
    return get_location(index);
}
```

### 3.3 MPH 算法详解

```cpp
// 查找公式（来自 imageFile.hpp:98-105）
redirectIndex = hash(path, DEFAULT_SEED) % table_length;
redirect = redirectTable[redirectIndex];

if (redirect == 0) 
    return NOT_FOUND;  // 未命中

// 需要二次哈希
if (redirect < 0) {
    // 负值：直接是索引
    locationIndex = -1 - redirect;
} else {
    // 正值：使用 redirect 作为 seed 再哈希
    locationIndex = hash(path, redirect) % table_length;
}

location = locationTable[locationIndex];
```

**为什么这样设计？**

```
1. 双哈希：解决冲突
2. 负值标记：区分直接索引和需要二次哈希
3. 验证步骤：确保正确性（虽然 MPH 不应有冲突）
```

---

## 四、与类加载器的集成 ⭐⭐⭐⭐⭐

### 4.1 BootstrapClassLoader 加载流程

```
JDK 9+ 类加载：

ClassLoader.loadClass("java.lang.Object")
    ↓
findClass("java/lang/Object.class")
    ↓
BuiltInClassLoader.findClass()
    ↓
  1. JImageFile* jimage = JIMAGE_Open("modules.jimage")
  2. location = JIMAGE_FindResource(jimage, "java.base", "9.0", "java/lang/Object.class")
  3. JIMAGE_GetResource(jimage, location, buffer, size)
  4. defineClass(buffer)
```

### 4.2 核心 API

```c
// jimage.hpp

// 1. 打开 JImage 文件
JImageFile* JIMAGE_Open("modules.jimage", &error);

// 2. 查找资源
JImageLocationRef location = 
    JIMAGE_FindResource(jimage, 
                       "java.base",      // 模块名
                       "9.0",           // 版本
                       "java/lang/Object.class",  // 资源名
                       &size);          // 输出：大小

// 3. 读取资源
JIMAGE_GetResource(jimage, location, buffer, size);
```

---

## 五、JImage vs ZIP 对比 ⭐⭐⭐

### 5.1 性能对比

| 操作 | ZIP (libzip) | JImage (libjimage) |
|------|--------------|-------------------|
| 查找算法 | 哈希表 | MPH |
| 复杂度 | O(1) 均摊 | O(1) 确定 |
| 内存映射 | 仅索引区 | 全部 |
| 压缩 | DEFLATE | 无 |

### 5.2 适用场景

```
JImage 优势场景：
  - JDK 核心类加载 (java.base 等)
  - 启动性能敏感
  - 高频率类加载

JAR 优势场景：
  - 用户代码
  - 需要解压运行
  - 动态添加/修改
```

---

## 六、核心文件清单

| 文件 | 职责 |
|------|------|
| `jimage.cpp` | 核心 API 实现 |
| `jimage.hpp` | 头文件 + API 定义 |
| `imageFile.cpp` | 文件读写 + MPH |
| `imageFile.hpp` | 数据结构 |
| `imageDecompressor.cpp` | 解压实现 |

---

## 七、总结

### 7.1 核心设计

| 设计点 | 选择 | 理由 |
|--------|------|------|
| 哈希算法 | MPH | 无冲突，O(1) 确定 |
| 索引 | 内存映射 | 快速随机访问 |
| 压缩 | 无 | 空间换时间 |
| 模块化 | jmod | JDK 9+ 特性 |

### 7.2 性能关键点

1. **MPH 算法**：一次哈希定位，无冲突
2. **内存映射**：整个文件 mmap，无需 I/O
3. **无解压**：资源区无压缩，直接读取
4. **固定格式**：消除解析开销

### 7.3 文件位置

```
$JAVA_HOME/lib/modules
  = modules.jimage
  
jimage 文件由 jlink 工具生成：
  jlink --add-modules java.base --output custom-jre
```

---

> 下一步：可选 libverify.so（字节码校验）
