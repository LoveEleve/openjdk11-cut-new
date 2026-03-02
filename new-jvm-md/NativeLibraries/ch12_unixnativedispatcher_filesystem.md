# 第 12 章：UnixNativeDispatcher — 文件系统操作

> 源码基线：OpenJDK 11，Linux x86_64
> 核心文件：`UnixNativeDispatcher.c` (1245行) + `LinuxNativeDispatcher.c` (232行) + `LinuxWatchService.c` (154行)

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **第 12 章：UnixNativeDispatcher — 文件系统操作**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 12.1 本章定位

`java.nio.file.Files.copy/move/delete/readAttributes/list` 等 NIO.2 文件 API 的底层实现，最终都会汇聚到 `UnixNativeDispatcher`——一个巨大的 **POSIX 系统调用 JNI 桥接层**。

它不是一个"聪明"的类——几乎不包含任何业务逻辑，就是把 Java 调用**直译**为 C 系统调用。但正是这种"笨"的设计，让我们能在一个文件里看到 Java NIO.2 文件系统操作对应的**全部** POSIX 系统调用。

**本章涉及三层 Native 调度**：

```
┌─────────────────────────────────────────────────────┐
│  UnixNativeDispatcher.c  (1245行, 跨平台通用)        │
│  → open/close/stat/lstat/fstat/chmod/chown/mkdir/   │
│    rmdir/link/unlink/symlink/readlink/rename/       │
│    opendir/readdir/closedir/access/statvfs/         │
│    getpwuid/getgrgid/...                            │
├─────────────────────────────────────────────────────┤
│  LinuxNativeDispatcher.c  (232行, Linux 特有)        │
│  → fgetxattr/fsetxattr/fremovexattr/flistxattr     │
│    (扩展属性)                                        │
│  → setmntent/getmntent/endmntent (挂载点)           │
├─────────────────────────────────────────────────────┤
│  LinuxWatchService.c  (154行, inotify 文件监控)      │
│  → inotify_init/inotify_add_watch/inotify_rm_watch │
├─────────────────────────────────────────────────────┤
│  UnixCopyFile.c  (85行, 用户空间文件拷贝)            │
│  → read + write 循环                                │
└─────────────────────────────────────────────────────┘
```

**为什么重要？**

- 理解 `Files.readAttributes()` 为什么有时候慢——因为底下是 `stat()` 系统调用
- 理解 `Files.walk()` 目录遍历的性能特征——`opendir + readdir` 循环
- 理解 `WatchService` 文件监控的底层——Linux 上是 `inotify`
- 理解扩展属性（xattr）在 Java 中的使用——Docker 镜像层、SELinux 标签

---

## 12.2 Java 层架构

### 12.2.1 类关系图

```
java.nio.file.Files (公开 API)
  └→ UnixFileSystemProvider (路由)
       ├→ UnixNativeDispatcher (JNI 桥接, 49 个 native 方法)
       │    └→ UnixNativeDispatcher.c → POSIX syscalls
       ├→ LinuxNativeDispatcher (Linux 特有, 扩展属性 + 挂载点)
       │    └→ LinuxNativeDispatcher.c
       ├→ LinuxWatchService (Linux inotify)
       │    └→ LinuxWatchService.c
       └→ UnixCopyFile (文件拷贝)
            └→ UnixCopyFile.c

数据载体类：
  UnixFileAttributes   ← struct stat 的 Java 映射
  UnixFileStoreAttributes ← struct statvfs 的 Java 映射
  UnixMountEntry       ← struct mntent 的 Java 映射
  UnixConstants        ← C 头文件常量 (#define → Java static final)
  UnixException        ← errno 的 Java 封装 → IOException 映射
```

### 12.2.2 UnixNativeDispatcher.java — 统一调用模式

Java 层对所有需要路径参数的方法，都遵循统一的**路径转换 + native 调用 + 清理**模式：

```java
// UnixNativeDispatcher.java 典型模式
static void stat(UnixPath path, UnixFileAttributes attrs) throws UnixException {
    NativeBuffer buffer = copyToNativeBuffer(path);  // UnixPath → C 字符串
    try {
        stat0(buffer.address(), attrs);               // 调用 native0 方法
    } finally {
        buffer.release();                              // 释放 native 内存
    }
}
private static native void stat0(long pathAddress, UnixFileAttributes attrs)
    throws UnixException;
```

**`copyToNativeBuffer()`** 将 Java 的 `UnixPath`（内部存储为 `byte[]`）转换为 C 原生内存中的以 `\0` 结尾的字符串。`NativeBuffer` 使用了 `Unsafe.allocateMemory()` 分配堆外内存，并在 `release()` 时释放。

### 12.2.3 能力检测

`init()` 方法在类加载时通过 `dlsym()` 检测运行时可用的系统调用：

```java
// UnixNativeDispatcher.java
private static final int SUPPORTS_OPENAT   = 1 << 1;
private static final int SUPPORTS_FUTIMES  = 1 << 2;
private static final int SUPPORTS_BIRTHTIME = 1 << 16;

private static final int capabilities;
static {
    System.loadLibrary("nio");
    capabilities = init();  // native init() 返回能力位图
}

static boolean openatSupported()    { return (capabilities & SUPPORTS_OPENAT) != 0; }
static boolean futimesSupported()   { return (capabilities & SUPPORTS_FUTIMES) != 0; }
static boolean birthtimeSupported() { return (capabilities & SUPPORTS_BIRTHTIME) != 0; }
```

---

## 12.3 初始化 — init()

`init()` 是整个文件最复杂的函数，一次性完成三件事：

### 12.3.1 缓存 JNI 字段 ID

```c
// UnixNativeDispatcher.c 第 193-309 行

// UnixFileAttributes — 14 个字段 (对应 struct stat)
attrs_st_mode, attrs_st_ino, attrs_st_dev, attrs_st_rdev,
attrs_st_nlink, attrs_st_uid, attrs_st_gid, attrs_st_size,
attrs_st_atime_sec, attrs_st_atime_nsec,
attrs_st_mtime_sec, attrs_st_mtime_nsec,
attrs_st_ctime_sec, attrs_st_ctime_nsec
// macOS 额外: attrs_st_birthtime_sec

// UnixFileStoreAttributes — 4 个字段 (对应 struct statvfs)
attrs_f_frsize, attrs_f_blocks, attrs_f_bfree, attrs_f_bavail

// UnixMountEntry — 5 个字段 (对应 struct mntent)
entry_name, entry_dir, entry_fstype, entry_options, entry_dev
```

**共计 23 个 JNI 字段 ID**。

### 12.3.2 dlsym 探测 *at 系列系统调用

```c
// UnixNativeDispatcher.c 第 259-282 行
my_openat64_func   = dlsym(RTLD_DEFAULT, "openat64");
my_fstatat64_func  = dlsym(RTLD_DEFAULT, "fstatat64");
my_unlinkat_func   = dlsym(RTLD_DEFAULT, "unlinkat");
my_renameat_func   = dlsym(RTLD_DEFAULT, "renameat");
my_futimesat_func  = dlsym(RTLD_DEFAULT, "futimesat");
my_fdopendir_func  = dlsym(RTLD_DEFAULT, "fdopendir");
```

`*at` 系列（如 `openat`、`fstatat`、`unlinkat`）是 POSIX 2008 引入的相对路径操作，允许基于**目录文件描述符**而非绝对路径来操作文件，避免 TOCTOU（Time-of-Check-to-Time-of-Use）竞态条件。

**为什么用 `dlsym` 而不直接链接？** 因为旧版 Linux/Solaris 可能没有这些函数。运行时检测确保向后兼容。

### 12.3.3 fstatat64 的 syscall 降级

```c
// UnixNativeDispatcher.c 第 157-176 行
// Linux i386/arm 上 glibc 可能缺少 fstatat64, 直接用 syscall
#if defined(__linux__) && (defined(__i386) || defined(__arm__))
static int fstatat64_wrapper(int dfd, const char *path,
                             struct stat64 *statbuf, int flag) {
    return syscall(__NR_fstatat64, dfd, path, statbuf, flag);
}
#endif

// Linux x86_64 上使用 __NR_newfstatat
#if defined(__linux__) && defined(_LP64) && defined(__NR_newfstatat)
static int fstatat64_wrapper(int dfd, const char *path,
                             struct stat64 *statbuf, int flag) {
    return syscall(__NR_newfstatat, dfd, path, statbuf, flag);
}
#endif
```

如果 `dlsym("fstatat64")` 返回 NULL，降级到直接 `syscall()` 调用——这是应对 glibc 版本过低的兜底策略。

### 12.3.4 返回能力位图

```c
// 第 284-308 行
jint capabilities = 0;

// BSD 原生支持 futimes
#ifdef _ALLBSD_SOURCE
    capabilities |= SUPPORTS_FUTIMES;
#else
    if (my_futimesat_func != NULL)
        capabilities |= SUPPORTS_FUTIMES;
#endif

// 所有 *at 函数都可用时才报告 SUPPORTS_OPENAT
if (my_openat64_func && my_fstatat64_func && my_unlinkat_func &&
    my_renameat_func && my_futimesat_func && my_fdopendir_func)
    capabilities |= SUPPORTS_OPENAT;

// macOS 支持 birthtime (文件创建时间)
#ifdef _DARWIN_FEATURE_64_BIT_INODE
    capabilities |= SUPPORTS_BIRTHTIME;
#endif

return capabilities;
```

---

## 12.4 核心模式 — RESTARTABLE 宏

整个文件中出现频率最高的两个宏：

```c
// UnixNativeDispatcher.c 第 95-105 行
#define RESTARTABLE(_cmd, _result) do { \
  do { \
    _result = _cmd; \
  } while((_result == -1) && (errno == EINTR)); \
} while(0)

#define RESTARTABLE_RETURN_PTR(_cmd, _result) do { \
  do { \
    _result = _cmd; \
  } while((_result == NULL) && (errno == EINTR)); \
} while(0)
```

**为什么需要？** POSIX 系统调用可能被信号中断返回 `EINTR`（如 `SIGCHLD`）。大多数情况下应该自动重试而非报错。两个变种：
- `RESTARTABLE`：用于返回 `int`（-1 = 错误）的系统调用
- `RESTARTABLE_RETURN_PTR`：用于返回指针（NULL = 错误）的函数

**不需要 RESTARTABLE 的调用**（源码注释标明 "EINTR not listed as a possible error"）：
- `opendir`, `closedir`, `readlink`, `mkdir`, `rmdir`, `unlink`, `rename`, `symlink`, `getcwd`, `realpath`

---

## 12.5 错误处理 — throwUnixException

```c
// UnixNativeDispatcher.c 第 182-188 行
static void throwUnixException(JNIEnv* env, int errnum) {
    jobject x = JNU_NewObjectByName(env, "sun/nio/fs/UnixException", "(I)V", errnum);
    if (x != NULL) {
        (*env)->Throw(env, x);
    }
}
```

所有 native 方法统一抛出 `UnixException(errno)`。Java 层的 `UnixException` 再根据 `errno` 映射为标准 `IOException`：

| errno | Java 异常 |
|-------|----------|
| `EACCES` | `AccessDeniedException` |
| `ENOENT` | `NoSuchFileException` |
| `EEXIST` | `FileAlreadyExistsException` |
| `ELOOP` | `FileSystemException`（"Too many symbolic links"） |
| 其他 | `FileSystemException`（附带 `strerror` 描述） |

**性能优化**：`UnixException.fillInStackTrace()` 被覆盖为空操作（直接 `return this`），因为这是内部异常，不需要代价高昂的堆栈追踪。

---

## 12.6 文件属性 — stat 系列

### 12.6.1 stat/lstat/fstat/fstatat 四兄弟

```c
// stat0: 获取文件属性 (跟随符号链接)
// UnixNativeDispatcher.c 第 542-556 行
JNIEXPORT void JNICALL
Java_sun_nio_fs_UnixNativeDispatcher_stat0(JNIEnv* env, jclass this,
    jlong pathAddress, jobject attrs) {
    struct stat64 buf;
    const char* path = (const char*)jlong_to_ptr(pathAddress);
    RESTARTABLE(stat64(path, &buf), err);
    if (err == -1) throwUnixException(env, errno);
    else prepAttributes(env, &buf, attrs);  // 将 stat 结果写入 Java 对象
}

// lstat0: 不跟随符号链接 (获取符号链接自身属性)
RESTARTABLE(lstat64(path, &buf), err);

// fstat: 通过文件描述符获取 (已打开的文件)
RESTARTABLE(fstat64((int)fd, &buf), err);

// fstatat0: 相对于目录 fd 获取 (TOCTOU 安全)
RESTARTABLE((*my_fstatat64_func)((int)dfd, path, &buf, (int)flag), err);
```

还有一个特殊的 `stat1`——只返回 `st_mode` 而不填充完整的 `attrs` 对象：

```c
// stat1: 快速路径, 只返回 st_mode (用于 Files.exists/isDirectory 等)
// UnixNativeDispatcher.c 第 558-570 行
JNIEXPORT jint JNICALL
Java_sun_nio_fs_UnixNativeDispatcher_stat1(JNIEnv* env, jclass this, jlong pathAddress) {
    struct stat64 buf;
    RESTARTABLE(stat64(path, &buf), err);
    if (err == -1) return 0;      // 不抛异常, 返回 0 表示不存在
    else return (jint)buf.st_mode; // 只返回模式字
}
```

这个快速路径被 `Files.exists()`、`Files.isDirectory()` 等使用，避免了创建 Java 对象的开销。

### 12.6.2 prepAttributes — struct stat → Java 对象

```c
// UnixNativeDispatcher.c 第 514-540 行
static void prepAttributes(JNIEnv* env, struct stat64* buf, jobject attrs) {
    SetIntField(attrs, attrs_st_mode,  buf->st_mode);    // 文件类型+权限
    SetLongField(attrs, attrs_st_ino,  buf->st_ino);     // inode 号
    SetLongField(attrs, attrs_st_dev,  buf->st_dev);     // 设备号
    SetLongField(attrs, attrs_st_rdev, buf->st_rdev);    // 特殊设备号
    SetIntField(attrs, attrs_st_nlink, buf->st_nlink);   // 硬链接数
    SetIntField(attrs, attrs_st_uid,   buf->st_uid);     // 所有者 UID
    SetIntField(attrs, attrs_st_gid,   buf->st_gid);     // 所有者 GID
    SetLongField(attrs, attrs_st_size, buf->st_size);    // 文件大小

    // 时间戳: 秒 + 纳秒 (Linux 用 st_atim.tv_nsec, macOS 用 st_atimespec.tv_nsec)
    SetLongField(attrs, attrs_st_atime_sec,  buf->st_atime);
    SetLongField(attrs, attrs_st_mtime_sec,  buf->st_mtime);
    SetLongField(attrs, attrs_st_ctime_sec,  buf->st_ctime);
#ifndef MACOSX
    SetLongField(attrs, attrs_st_atime_nsec, buf->st_atim.tv_nsec);
    SetLongField(attrs, attrs_st_mtime_nsec, buf->st_mtim.tv_nsec);
    SetLongField(attrs, attrs_st_ctime_nsec, buf->st_ctim.tv_nsec);
#else
    SetLongField(attrs, attrs_st_atime_nsec, buf->st_atimespec.tv_nsec);
    // macOS 额外: birthtime (文件创建时间)
    SetLongField(attrs, attrs_st_birthtime_sec, buf->st_birthtime);
#endif
}
```

**注意**：`stat` 返回的时间是**秒 + 纳秒**两个字段，Java 层合并为 `FileTime`。Linux 上支持纳秒精度，但 ext3 等旧文件系统实际只有秒精度。

### 12.6.3 UnixFileAttributes — Java 层数据载体

```java
// UnixFileAttributes.java 关键方法

// 文件类型判断 — 基于 st_mode & S_IFMT
boolean isRegularFile()  { return (st_mode & S_IFMT) == S_IFREG; }
boolean isDirectory()    { return (st_mode & S_IFMT) == S_IFDIR; }
boolean isSymbolicLink() { return (st_mode & S_IFMT) == S_IFLNK; }

// 权限转换 — st_mode 低 9 位 → Set<PosixFilePermission>
Set<PosixFilePermission> permissions() {
    int bits = st_mode & 0777;
    // S_IRUSR(0400) → OWNER_READ, S_IWUSR(0200) → OWNER_WRITE, ...
}

// owner/group — 懒加载, 双重检查锁定
UserPrincipal owner() {
    if (owner == null) {
        synchronized(this) {
            if (owner == null) {
                owner = UnixUserPrincipals.fromUid(st_uid);  // getpwuid()
            }
        }
    }
    return owner;
}

// 同一文件判断 — 比较 (dev, ino) 对
boolean isSameFile(UnixFileAttributes other) {
    return (st_ino == other.st_ino) && (st_dev == other.st_dev);
}
```

---

## 12.7 文件操作

### 12.7.1 open / openat / close

```c
// open0: 打开文件
// UnixNativeDispatcher.c 第 437-449 行
RESTARTABLE(open64(path, (int)oflags, (mode_t)mode), fd);

// openat0: 相对于目录 fd 打开 (TOCTOU 安全)
// 第 451-468 行
RESTARTABLE((*my_openat64_func)(dfd, path, (int)oflags, (mode_t)mode), fd);

// close0: 关闭文件描述符
// 第 470-483 行
// AIX 特殊: EINTR 后可以重试; 其他平台: close 只调用一次
#if defined(_AIX)
    RESTARTABLE(close((int)fd), res);  // AIX 可重试
#else
    res = close((int)fd);              // Linux/Solaris: 不重试!
#endif
    if (res == -1 && errno != EINTR) throwUnixException(env, errno);
```

**`close` 不重试的原因**：POSIX 规定 `close` 后 fd 状态是未定义的——即使 `EINTR`，fd 也可能已经被关闭。重试会关闭一个已被其他线程复用的 fd。AIX 是例外：AIX 保证 `EINTR` 时 fd 未关闭。

### 12.7.2 link / unlink / rename

```c
// link0: 创建硬链接
RESTARTABLE(link(existing, newname), err);

// unlink0: 删除文件
if (unlink(path) == -1) throwUnixException(env, errno);

// unlinkat0: 相对于目录 fd 删除 (可选 AT_REMOVEDIR 删除目录)
(*my_unlinkat_func)((int)dfd, path, (int)flags);

// rename0: 重命名/移动
if (rename(from, to) == -1) throwUnixException(env, errno);

// renameat0: 相对路径版本
(*my_renameat_func)((int)fromfd, from, (int)tofd, to);

// symlink0: 创建符号链接
if (symlink(target, link) == -1) throwUnixException(env, errno);
```

**`unlink` vs `rmdir`**：`unlink` 删除文件（减少硬链接计数），`rmdir` 删除空目录。`unlinkat` + `AT_REMOVEDIR` 可以替代 `rmdir`——这是 `*at` 系列的统一点。

### 12.7.3 readlink / realpath

```c
// readlink0: 读取符号链接的目标
// 第 907-932 行
int n = readlink(path, target, sizeof(target));  // target = PATH_MAX+1 (4097)
target[n] = '\0';
// 返回 byte[]

// realpath0: 解析为绝对路径 (消除所有 . / .. / symlink)
// 第 934-953 行
realpath(path, resolved);  // resolved = PATH_MAX+1
// 返回 byte[]
```

两者都使用栈上的 `PATH_MAX+1` 缓冲区。`PATH_MAX` 在 Linux 上通常为 4096。

### 12.7.4 symlink 与 link 的区别（基于源码）

| 对比项 | `link(existing, new)` | `symlink(target, link)` |
|--------|----------------------|------------------------|
| 调用 | 第 820 行 | 第 894 行 |
| 语义 | 硬链接, 共享 inode | 软链接, 独立 inode |
| 跨文件系统 | 不可以 (EXDEV) | 可以 |
| target 可不存在 | 不可以 | 可以（悬空链接） |
| 删除原文件后 | 硬链接仍可访问 | 软链接断裂 |

---

## 12.8 目录遍历

### 12.8.1 opendir / readdir / closedir

```c
// opendir0: 打开目录流
// UnixNativeDispatcher.c 第 732-745 行
dir = opendir(path);  // 不需要 RESTARTABLE
return ptr_to_jlong(dir);  // DIR* 转为 jlong 传回 Java

// fdopendir: 从 fd 打开目录流 (SecureDirectoryStream 使用)
// 第 747-762 行
dir = (*my_fdopendir_func)((int)dfd);

// readdir: 读取下一个目录项
// 第 773-793 行
errno = 0;
ptr = readdir64(dirp);
if (ptr == NULL) {
    if (errno != 0) throwUnixException(env, errno);
    return NULL;  // 目录结束
}
// 返回 d_name 的 byte[]

// closedir: 关闭目录流
// 第 764-771 行
if (closedir(dirp) == -1 && errno != EINTR) throwUnixException(env, errno);
```

**`readdir` 的错误检测技巧**：`readdir` 返回 NULL 时有两种含义：(1) 目录结束，(2) 错误。区分方法是调用前 `errno = 0`，返回 NULL 后检查 `errno`。如果 `errno != 0` 才是真正的错误。

### 12.8.2 Java 层的目录遍历流程

```
Files.list(dir)  或  Files.walk(dir)
  → UnixDirectoryStream.iterator()
    → UnixNativeDispatcher.opendir(path) → DIR*
    → 循环: readdir() → byte[] (文件名)
              → 过滤 "." 和 ".."
              → 构造 UnixPath
    → closedir()
```

**性能关键**：`readdir` 每次只返回一个目录项（文件名 + d_type）。如果需要文件属性，还要对每个文件调用 `stat`——这就是 `Files.walk()` 在大目录中比 `ls` 慢的原因之一。

---

## 12.9 权限管理

### 12.9.1 chmod / fchmod

```c
// chmod0: 修改文件权限
// UnixNativeDispatcher.c 第 623-634 行
RESTARTABLE(chmod(path, (mode_t)mode), err);

// fchmod: 通过 fd 修改权限 (已打开的文件)
// 第 636-646 行
RESTARTABLE(fchmod((int)filedes, (mode_t)mode), err);
```

### 12.9.2 chown / lchown / fchown

```c
// chown0: 修改文件所有者 (跟随符号链接)
// 第 649-660 行
RESTARTABLE(chown(path, (uid_t)uid, (gid_t)gid), err);

// lchown0: 修改符号链接自身的所有者 (不跟随)
// 第 662-672 行
RESTARTABLE(lchown(path, (uid_t)uid, (gid_t)gid), err);

// fchown: 通过 fd 修改所有者
// 第 674-683 行
RESTARTABLE(fchown(filedes, (uid_t)uid, (gid_t)gid), err);
```

### 12.9.3 access

```c
// access0: 检查文件访问权限
// 第 955-966 行
RESTARTABLE(access(path, (int)amode), err);  // amode = R_OK|W_OK|X_OK|F_OK

// exists0: 快速检查文件存在性 (不抛异常)
// 第 968-974 行
RESTARTABLE(access(path, F_OK), err);
return (err == 0) ? JNI_TRUE : JNI_FALSE;
```

`access` 检查的是**真实 UID/GID** 的权限（非 effective），这在 setuid 程序中会有差异。

---

## 12.10 时间戳操作

```c
// utimes0: 修改文件的 atime 和 mtime
// UnixNativeDispatcher.c 第 685-703 行
struct timeval times[2];
times[0].tv_sec  = accessTime / 1000000;       // 微秒 → 秒
times[0].tv_usec = accessTime % 1000000;       // 微秒 → 余数
times[1].tv_sec  = modificationTime / 1000000;
times[1].tv_usec = modificationTime % 1000000;
RESTARTABLE(utimes(path, &times[0]), err);

// futimes: 通过 fd 修改时间戳
// 第 705-730 行
#ifdef _ALLBSD_SOURCE
    RESTARTABLE(futimes(filedes, &times[0]), err);  // BSD 原生支持
#else
    RESTARTABLE((*my_futimesat_func)(filedes, NULL, &times[0]), err);  // Linux 用 futimesat
#endif
```

**注意**：Java 传入的时间单位是**微秒**（不是毫秒也不是纳秒），所以用 1000000 做除和取模。`utimes` 的精度是微秒级，而 `stat` 返回的是纳秒级——这是一个精度不对称。

**Linux 没有原生 `futimes`**：Linux 内核只有 `futimesat(fd, NULL, times)` 来实现同等功能。BSD 系统有原生 `futimes(fd, times)`。

---

## 12.11 文件系统信息 — statvfs / pathconf

### 12.11.1 statvfs — 磁盘空间查询

```c
// statvfs0: 获取文件系统存储统计
// UnixNativeDispatcher.c 第 976-1017 行
#ifdef MACOSX
    struct statfs buf;
    RESTARTABLE(statfs(path, &buf), err);  // macOS 用 statfs
#else
    struct statvfs64 buf;
    RESTARTABLE(statvfs64(path, &buf), err);  // Linux/Solaris 用 statvfs64
#endif

// 填充 Java 对象
SetLongField(attrs, attrs_f_frsize, buf.f_frsize);   // 块大小
SetLongField(attrs, attrs_f_blocks, buf.f_blocks);   // 总块数
SetLongField(attrs, attrs_f_bfree,  buf.f_bfree);    // 空闲块数
SetLongField(attrs, attrs_f_bavail, buf.f_bavail);   // 可用块数
```

**AIX 特殊处理**：`/proc` 文件系统的 `f_blocks` 返回 `ULONG_MAX`，这会导致 Java `long` 溢出。源码将其归零。

计算磁盘空间：
```
总空间 = f_blocks × f_frsize
空闲空间 = f_bfree × f_frsize     (含 root 保留)
可用空间 = f_bavail × f_frsize    (普通用户实际可用)
```

### 12.11.2 pathconf / fpathconf — 文件系统配置查询

```c
// pathconf0: 查询路径相关的系统限制
// 第 1019-1031 行
long err = pathconf(path, (int)name);
// name 可选值: _PC_NAME_MAX (文件名最大长度), _PC_PATH_MAX 等

// fpathconf: 通过 fd 查询
// 第 1033-1044 行
long err = fpathconf((int)fd, (int)name);
```

常用查询：`_PC_NAME_MAX` → ext4 上返回 255。

---

## 12.12 用户与组名解析

### 12.12.1 getpwuid — UID → 用户名

```c
// UnixNativeDispatcher.c 第 1059-1097 行
JNIEXPORT jbyteArray JNICALL
Java_sun_nio_fs_UnixNativeDispatcher_getpwuid(JNIEnv* env, jclass this, jint uid) {
    // 1. 分配缓冲区 (大小来自 sysconf)
    buflen = sysconf(_SC_GETPW_R_SIZE_MAX);
    if (buflen == -1) buflen = ENT_BUF_SIZE;  // 默认 1024
    pwbuf = malloc(buflen);

    // 2. 线程安全调用
    RESTARTABLE(getpwuid_r((uid_t)uid, &pwent, pwbuf, buflen, &p), res);

    // 3. 返回 pw_name 的 byte[]
    result = NewByteArray(strlen(p->pw_name));
    SetByteArrayRegion(result, p->pw_name);
    free(pwbuf);
}
```

### 12.12.2 getgrgid — GID → 组名（带 ERANGE 重试）

```c
// UnixNativeDispatcher.c 第 1100-1151 行
do {
    grbuf = malloc(buflen);
    RESTARTABLE(getgrgid_r((gid_t)gid, &grent, grbuf, buflen, &g), res);

    if (errno == ERANGE) {
        buflen += ENT_BUF_SIZE;  // 缓冲区不够, 扩大 1024 后重试
        retry = 1;
    }
    free(grbuf);
} while (retry);
```

**为什么 `getgrgid` 有重试而 `getpwuid` 没有？** 因为组记录可能包含大量成员列表，缓冲区更容易不够。`ERANGE` 是 `getgr*_r` 系列的标准"缓冲区不足"信号。

### 12.12.3 反向查询 — 用户名/组名 → UID/GID

```c
// getpwnam0: 用户名 → UID
// 第 1153-1191 行
RESTARTABLE(getpwnam_r(name, &pwent, pwbuf, buflen, &p), res);
uid = p->pw_uid;
// 查不到不抛异常, 返回 -1 (静默失败)

// getgrnam0: 组名 → GID (带 ERANGE 重试)
// 第 1193-1244 行
RESTARTABLE(getgrnam_r(name, &grent, grbuf, buflen, &g), res);
gid = g->gr_gid;
```

`getpwnam0` 查不到用户时**不抛异常**（只返回 -1），因为某些 errno（`ENOENT`/`ESRCH`/`EBADF`/`EPERM`）在 NSS 配置中是正常的"未找到"情况。

---

## 12.13 Linux 特有 — LinuxNativeDispatcher.c

### 12.13.1 扩展属性（xattr）

扩展属性是存储在 inode 中的键值对，用途广泛：SELinux 标签、ACL、Docker 镜像层标识等。

```c
// LinuxNativeDispatcher.c init() — dlsym 探测
// 第 62-68 行
my_fgetxattr_func    = dlsym(RTLD_DEFAULT, "fgetxattr");
my_fsetxattr_func    = dlsym(RTLD_DEFAULT, "fsetxattr");
my_fremovexattr_func = dlsym(RTLD_DEFAULT, "fremovexattr");
my_flistxattr_func   = dlsym(RTLD_DEFAULT, "flistxattr");

// fgetxattr0: 读取扩展属性
// 第 82-99 行
res = (*my_fgetxattr_func)(fd, name, value, valueLen);
// 如果函数不可用 → errno = ENOTSUP

// fsetxattr0: 设置扩展属性
// 第 101-117 行
res = (*my_fsetxattr_func)(fd, name, value, valueLen, 0);

// fremovexattr0: 删除扩展属性
// 第 119-134 行

// flistxattr: 列出所有扩展属性名
// 第 136-152 行
res = (*my_flistxattr_func)(fd, list, (size_t)size);
```

**对应 Java API**：
```java
// 读取 xattr
UserDefinedFileAttributeView view = Files.getFileAttributeView(path,
    UserDefinedFileAttributeView.class);
ByteBuffer buf = ByteBuffer.allocate(view.size("user.myattr"));
view.read("user.myattr", buf);
```

### 12.13.2 挂载点枚举 — setmntent / getmntent / endmntent

```c
// setmntent0: 打开 /etc/mtab 或 /proc/mounts
// LinuxNativeDispatcher.c 第 154-169 行
FILE* fp = setmntent(path, mode);  // 类似 fopen, 但解析 mntent 格式
return ptr_to_jlong(fp);

// getmntent0: 读取一条挂载记录
// 第 171-223 行
struct mntent ent;
m = getmntent_r(fp, &ent, buf, bufLen);  // 线程安全版本
// 填充 UnixMountEntry 的四个字段:
// m->mnt_fsname (设备名, 如 "/dev/sda1")
// m->mnt_dir    (挂载点, 如 "/home")
// m->mnt_type   (文件系统类型, 如 "ext4")
// m->mnt_opts   (挂载选项, 如 "rw,relatime")

// endmntent: 关闭
// 第 225-231 行
endmntent(fp);  // man page 没说如何返回错误, 所以不检查
```

**用途**：`FileStore.getFileStores()` 通过遍历 `/proc/mounts` 获取所有挂载的文件系统信息。

**UnixMountEntry Java 层**提供了两个实用方法：
- `isReadOnly()` → 检查 opts 中是否有 "ro"
- `hasOption(String)` → 按逗号分割 opts 后逐一比较

---

## 12.14 inotify 文件监控 — LinuxWatchService.c

Linux 上 `WatchService` 的底层实现是 `inotify` 内核子系统。

### 12.14.1 inotify 三板斧

```c
// inotifyInit: 创建 inotify 实例
// LinuxWatchService.c 第 71-80 行
int ifd = inotify_init();  // 返回 inotify 文件描述符

// inotifyAddWatch: 添加监控
// 第 82-94 行
int wfd = inotify_add_watch((int)fd, path, mask);
// mask: IN_CREATE|IN_DELETE|IN_MODIFY|IN_MOVED_FROM|IN_MOVED_TO|...
// 返回 watch descriptor

// inotifyRmWatch: 移除监控
// 第 96-103 行
inotify_rm_watch((int)fd, (int)wd);
```

### 12.14.2 事件读取机制

```c
// eventSize/eventOffsets: 获取 inotify_event 结构体布局
// 第 48-68 行
// Java 层通过这两个方法知道如何解析从 inotify fd read() 出来的二进制数据:
struct inotify_event {
    int      wd;      // watch descriptor
    uint32_t mask;    // 事件类型
    uint32_t cookie;  // rename 事件的关联 ID
    uint32_t len;     // name 字段长度
    char     name[];  // 文件名 (变长)
};
```

### 12.14.3 辅助功能

```c
// configureBlocking: 设置 inotify fd 为非阻塞
// 第 105-115 行
int flags = fcntl(fd, F_GETFL);
fcntl(fd, F_SETFL, flags | O_NONBLOCK);

// socketpair: 创建通知管道 (用于 close/cancel 唤醒)
// 第 117-130 行
socketpair(PF_UNIX, SOCK_STREAM, 0, sp);

// poll: 同时监听 inotify fd 和通知 socket
// 第 132-153 行
struct pollfd ufds[2] = {{fd1, POLLIN}, {fd2, POLLIN}};
poll(ufds, 2, -1);  // 无限等待
```

**完整流程**：

```
WatchService.take() / poll()
  → LinuxWatchService.poller 线程
    → poll(inotify_fd, socketpair[0])  等待事件
      ├─ inotify_fd 可读 → read() 获取事件 → 解析 inotify_event → 投递到 Java 队列
      └─ socketpair[0] 可读 → 唤醒信号 (cancel/close)
```

---

## 12.15 文件拷贝 — UnixCopyFile.c

```c
// UnixCopyFile.c 第 52-85 行 — 用户空间文件拷贝
JNIEXPORT void JNICALL
Java_sun_nio_fs_UnixCopyFile_transfer(JNIEnv* env, jclass this,
    jint dst, jint src, jlong cancelAddress) {
    char buf[8192];                                    // 8KB 栈缓冲区
    volatile jint* cancel = jlong_to_ptr(cancelAddress); // 取消标志

    for (;;) {
        RESTARTABLE(read((int)src, &buf, sizeof(buf)), n);
        if (n <= 0) { /* EOF 或错误 */ return; }

        if (cancel != NULL && *cancel != 0) {
            throwUnixException(env, ECANCELED);        // 支持中途取消
            return;
        }

        // 写入循环: 处理短写
        pos = 0; len = n;
        do {
            RESTARTABLE(write((int)dst, buf + pos, len), n);
            pos += n; len -= n;
        } while (len > 0);
    }
}
```

**关键设计**：
1. **8KB 栈缓冲区**：不使用堆分配，避免 GC 压力
2. **短写处理**：`write` 可能写入少于请求的字节数（如管道/socket），外层循环确保完整写入
3. **可取消**：通过 `volatile jint*` 指针检查取消标志，支持 `Files.copy` 的 interruptible 取消
4. **这是降级路径**：`Files.copy()` 在 Linux 上优先使用 `sendfile` 零拷贝（通过 `FileChannelImpl.transferTo`），只有降级时才走这个用户空间拷贝

---

## 12.16 UnixConstants — 平台常量桥接

`UnixConstants.java.template` 在构建时被 C 预处理器处理，生成平台正确的常量值：

```java
// 构建前 (template):
static final int O_RDONLY = PREFIX_O_RDONLY;    // PREFIX_ 占位
static final int O_WRONLY = PREFIX_O_WRONLY;
static final int S_IRUSR  = PREFIX_S_IRUSR;

// 构建后 (生成的 Java):
static final int O_RDONLY = 0;        // Linux 上 O_RDONLY = 0
static final int O_WRONLY = 1;        // Linux 上 O_WRONLY = 1
static final int S_IRUSR  = 256;     // Linux 上 S_IRUSR = 0x100
```

**定义的常量分类**（共约 50 个）：

| 类别 | 常量 | 用途 |
|------|------|------|
| 文件打开标志 | `O_RDONLY`, `O_WRONLY`, `O_RDWR`, `O_APPEND`, `O_CREAT`, `O_EXCL`, `O_TRUNC`, `O_SYNC`, `O_DSYNC`, `O_NOFOLLOW`, `O_DIRECT` | `open()` 参数 |
| 文件权限 | `S_IRUSR`, `S_IWUSR`, `S_IXUSR`, `S_IRGRP`, `S_IWGRP`, `S_IXGRP`, `S_IROTH`, `S_IWOTH`, `S_IXOTH`, `S_IAMB` | `chmod()` 参数 |
| 文件类型 | `S_IFMT`, `S_IFREG`, `S_IFDIR`, `S_IFLNK`, `S_IFCHR`, `S_IFBLK`, `S_IFIFO` | `stat.st_mode & S_IFMT` |
| 访问检查 | `R_OK`, `W_OK`, `X_OK`, `F_OK` | `access()` 参数 |
| 错误码 | `ENOENT`, `EACCES`, `EEXIST`, `ENOTDIR`, `EISDIR`, `ENOSPC`, `ELOOP`, `EROFS`, ... | 错误处理 |
| *at 标志 | `AT_SYMLINK_NOFOLLOW`, `AT_REMOVEDIR` | `fstatat`/`unlinkat` 参数 |

**平台差异处理**（条件编译）：
- FreeBSD 没有 `O_DSYNC` → 用 `O_SYNC` 替代
- 部分系统没有 `ENODATA` → 使用 12 (POSIX 值)
- macOS 没有 `O_DIRECT` → 不定义

---

## 12.17 数据流全景图

```
┌──────────────────────── Java 层 ──────────────────────────────┐
│                                                                │
│  Files.readAttributes(path, BasicFileAttributes.class)         │
│    → UnixFileAttributeViews.get()                              │
│      → UnixFileAttributes.get(path, followLinks)               │
│        → UnixNativeDispatcher.stat(path, attrs) 或 .lstat()    │
│                                                                │
│  Files.list(dir) / Files.walk(dir)                             │
│    → UnixDirectoryStream.iterator()                            │
│      → UnixNativeDispatcher.opendir(path)                      │
│      → 循环: UnixNativeDispatcher.readdir(dir) → 过滤 . / ..  │
│      → UnixNativeDispatcher.closedir(dir)                      │
│                                                                │
│  Files.copy(src, dst)                                          │
│    → UnixCopyFile.copy()                                       │
│      → UnixNativeDispatcher.open(src, O_RDONLY)                │
│      → UnixNativeDispatcher.open(dst, O_WRONLY|O_CREAT|O_TRUNC│
│      → UnixCopyFile.transfer(dst_fd, src_fd)                   │
│      → close(dst_fd), close(src_fd)                            │
│      → utimes(dst, atime, mtime)  复制时间戳                   │
│      → chmod(dst, mode)  复制权限                               │
│                                                                │
│  WatchService watchService = FileSystems.getDefault()          │
│      .newWatchService()                                        │
│    dir.register(watchService, ENTRY_CREATE, ENTRY_DELETE, ...) │
│    WatchKey key = watchService.take()                           │
└──────────────────────────┬─────────────────────────────────────┘
                           │ JNI
                           ▼
┌──────────── C 层 (UnixNativeDispatcher.c + Linux*.c) ─────────┐
│                                                                │
│  文件属性:  stat64 / lstat64 / fstat64 / fstatat64             │
│  文件操作:  open64 / close / read / write                      │
│  目录操作:  opendir / readdir64 / closedir                     │
│  文件管理:  link / unlink / rename / symlink / readlink        │
│  权限管理:  chmod / fchmod / chown / lchown / fchown / access  │
│  时间戳:    utimes / futimesat                                  │
│  文件系统:  statvfs64 / pathconf / mknod                       │
│  用户/组:   getpwuid_r / getgrgid_r / getpwnam_r / getgrnam_r  │
│  挂载点:    setmntent / getmntent_r / endmntent                │
│  扩展属性:  fgetxattr / fsetxattr / fremovexattr / flistxattr  │
│  文件监控:  inotify_init / inotify_add_watch / inotify_rm_watch│
│  文件拷贝:  read + write 循环 (8KB buf)                        │
│  错误处理:  errno → throwUnixException → UnixException(errno)   │
│                                                                │
└──────────────────────────┬─────────────────────────────────────┘
                           │ 系统调用
                           ▼
┌─────────────────────── Linux 内核 ────────────────────────────┐
│                                                                │
│  VFS 层:  stat / lstat / fstat / opendir / readdir / close     │
│  文件系统: ext4 / xfs / btrfs / tmpfs / proc / ...            │
│  inotify:  inotify_init / inotify_add_watch → fsnotify 框架    │
│  xattr:    fgetxattr → ext4_xattr_get → inode.i_xattr         │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

---

## 12.18 BSD 兼容性宏

文件开头定义了 BSD 系统的兼容性宏，因为 BSD 没有 64 位后缀的系统调用：

```c
// UnixNativeDispatcher.c 第 63-76 行
#ifdef _ALLBSD_SOURCE
    #define stat64     stat        // BSD 上 stat 就是 64 位的
    #define statvfs64  statvfs
    #define open64     open
    #define fstat64    fstat
    #define lstat64    lstat
    #define dirent64   dirent
    #define readdir64  readdir
#endif
```

**背景**：Linux 的 32 位内核有 `stat` (32位 ino/off) 和 `stat64` (64位) 两个版本。64 位 Linux 上 `stat64 = stat`。BSD/macOS 从一开始就是 64 位，不需要后缀。

---

## 12.19 面试常见问题

### Q1: Java 中 `Files.exists()` 和 `file.exists()` 有什么区别？

**答**：
- `java.io.File.exists()` → `UnixFileSystem.getBooleanAttributes()` → `stat64()` 然后检查返回值
- `java.nio.file.Files.exists()` → `UnixNativeDispatcher.stat1()` → 也是 `stat64()` 但只返回 `st_mode`

底层都是 `stat` 系统调用，但 NIO.2 版本多一个能力：可以选择是否跟随符号链接（`LinkOption.NOFOLLOW_LINKS`），此时用 `lstat` 替代 `stat`。

### Q2: `Files.readAttributes()` 的性能如何？

**答**：每次调用 = 1 次 `stat/lstat` 系统调用 + 创建 1 个 `UnixFileAttributes` Java 对象 + 通过 14 个 `SetField` JNI 调用填充字段。约 1-5μs/次（SSD）。批量操作时（如 `Files.walk`），每个文件额外 1 次 stat，大目录可能有数万次。

**优化**：如果只需要判断文件类型，用 `Files.isDirectory()` → `stat1()` 只返回 `st_mode` 的 int 值，避免对象创建。

### Q3: `WatchService` 在 Linux 上的限制？

**答**：
1. **只监控直接子项**：`inotify_add_watch` 只监控一层目录，不递归。要监控子目录需要手动对每个子目录注册
2. **watch descriptor 限制**：默认 `/proc/sys/fs/inotify/max_user_watches = 8192`，超过报 `ENOSPC`。Docker 容器中更容易触发
3. **NFS/CIFS 不支持**：inotify 只监控本地文件系统
4. **事件可能丢失**：内核事件队列满时（`/proc/sys/fs/inotify/max_queued_events`）会发送 `IN_Q_OVERFLOW`

### Q4: `close()` 为什么不重试 EINTR？

**答**：源码第 470-483 行明确区分了 AIX 和其他平台。POSIX 标准规定 `close` 后 fd 的状态是**未定义的**——即使返回 `EINTR`，fd 也可能已经被内核关闭了。如果重试 `close(fd)`，这个 fd 可能已经被另一个线程通过 `open/accept/dup` 复用，导致关闭了错误的文件描述符。AIX 是例外：它保证 `EINTR` 时 fd 不会被关闭。

### Q5: 扩展属性（xattr）在生产中的应用场景？

**答**：
1. **SELinux 安全标签**：`security.selinux` → 进程/文件的安全上下文
2. **ACL 扩展权限**：`system.posix_acl_access` → 超越 rwx 的细粒度权限
3. **Docker/OCI 镜像层**：overlay2 使用 xattr 标记镜像层元数据
4. **用户自定义**：`user.` 前缀可存储任意 KV 数据，如文件来源标签

Java API：`Files.getFileAttributeView(path, UserDefinedFileAttributeView.class)`。

---

## 12.20 源码文件交叉引用

| 文件路径 | 行数 | 角色 |
|---------|------|------|
| `java.base/unix/native/libnio/fs/UnixNativeDispatcher.c` | 1245 | **核心**：49 个 POSIX 系统调用的 JNI 实现 |
| `java.base/linux/native/libnio/fs/LinuxNativeDispatcher.c` | 232 | Linux 特有：xattr + 挂载点枚举 |
| `java.base/linux/native/libnio/fs/LinuxWatchService.c` | 154 | inotify 文件监控 |
| `java.base/unix/native/libnio/fs/UnixCopyFile.c` | 85 | 用户空间文件拷贝 (8KB buf) |
| `java.base/unix/classes/sun/nio/fs/UnixNativeDispatcher.java` | 626 | Java 层 JNI 桥接 + 路径转换 + 能力检测 |
| `java.base/unix/classes/sun/nio/fs/UnixFileAttributes.java` | 314 | `struct stat` 的 Java 映射 + 权限/时间/类型解析 |
| `java.base/unix/classes/sun/nio/fs/UnixFileStoreAttributes.java` | 59 | `struct statvfs` 的 Java 映射 (磁盘空间) |
| `java.base/unix/classes/sun/nio/fs/UnixMountEntry.java` | 85 | `struct mntent` 的 Java 映射 (挂载点) |
| `java.base/unix/classes/sun/nio/fs/UnixConstants.java.template` | 137 | C 预处理器模板 → 平台常量 |
| `java.base/unix/classes/sun/nio/fs/UnixException.java` | 122 | errno → IOException 映射 + 无堆栈追踪优化 |
| `java.base/unix/classes/sun/nio/fs/UnixFileSystemProvider.java` | 561 | 路由层：`Files.*` API → native 调度 |
| `java.base/unix/classes/sun/nio/fs/UnixDirectoryStream.java` | 221 | 目录遍历流封装 |
| `java.base/unix/classes/sun/nio/fs/UnixCopyFile.java` | 639 | 拷贝策略 + 属性保留 + 原子替换 |

---

## 12.21 本章总结

`UnixNativeDispatcher.c` 是 libnio.so 中文件系统部分的核心 JNI 桥接层。设计哲学是**薄封装**——几乎每个 native 方法都直译为一个 POSIX 系统调用。

**核心设计要点**：

1. **RESTARTABLE 宏**：所有可能被信号中断的系统调用都用该宏包装，自动重试 `EINTR`
2. **dlsym 能力探测**：`*at` 系列系统调用通过 `dlsym` 在运行时检测，确保老平台兼容
3. **三层 Native 调度**：通用（UnixNativeDispatcher.c, 1245行）→ 平台特有（LinuxNativeDispatcher.c, 232行）→ 功能特有（LinuxWatchService.c, 154行）
4. **UnixException 性能优化**：覆盖 `fillInStackTrace` 为空操作，避免为每个文件操作失败生成堆栈
5. **统一路径处理**：Java `UnixPath`（byte[]）→ `NativeBuffer`（Unsafe 堆外内存，C 字符串）→ 系统调用
6. **BSD 兼容宏**：`stat64 = stat` 等宏消除了 32/64 位 API 差异

**涉及的系统调用完整清单（Linux）**：

```
文件: open64, close, read, write, dup
属性: stat64, lstat64, fstat64, fstatat64, chmod, fchmod, chown, lchown, fchown
目录: opendir, readdir64, closedir, fdopendir, mkdir, rmdir
链接: link, unlink, unlinkat, symlink, readlink, realpath
移动: rename, renameat
时间: utimes, futimesat
查询: access, statvfs64, pathconf, fpathconf, mknod, getcwd
用户: getpwuid_r, getgrgid_r, getpwnam_r, getgrnam_r
挂载: setmntent, getmntent_r, endmntent
xattr: fgetxattr, fsetxattr, fremovexattr, flistxattr
监控: inotify_init, inotify_add_watch, inotify_rm_watch
流:   fopen, fclose, rewind, getline
```
