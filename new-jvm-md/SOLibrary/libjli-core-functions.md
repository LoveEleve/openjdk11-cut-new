# libjli.so 补充：核心函数详细分析

> 本文档补充 `5-libjli-Java-Launcher-Deep-Dive.md` 中的核心函数分析
>
> **方法论**：程序 = 数据结构 + 算法
> **遵循规范**：Source-Code-Depth L5（真实源码 + 逐行注释 + 设计解释）

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文对 **libjli.so 补充：核心函数详细分析** 进行源码级分析：追踪关键函数的执行路径，分析涉及的数据结构，解释每个设计决策的原因。

### 0.2 为什么需要？

仅靠文档和注释无法完全理解 JVM 的行为——很多关键细节只存在于源码中。源码级分析能建立对 JVM 行为的精确理解。

### 0.3 怎么解决？

从入口函数出发，自顶向下追踪调用链；对每个关键函数，分析其输入/输出/副作用；对每个数据结构，分析其字段含义和生命周期。

### 0.4 为什么这样设计？

分析过程中重点关注「为什么」：为什么选择这个数据结构？为什么这样处理边界情况？这些问题的答案往往揭示了 JVM 设计的精髓。

---


## 2.1 JLI_Launch() - 主入口函数 ⭐⭐⭐⭐⭐

**源码位置**: `java.c:274-436`

**解决什么问题**：Java 启动器的主入口函数，协调整个 JVM 启动流程。

### 2.1.1 函数签名

```cpp
// java.c:274-285
JNIEXPORT int JNICALL
JLI_Launch(int argc, char ** argv,              /* main argc, argv */
        int jargc, const char** jargv,          /* java args */
        int appclassc, const char** appclassv,  /* app classpath */
        const char* fullversion,                /* full version defined */
        const char* dotversion,                 /* UNUSED dot version defined */
        const char* pname,                      /* program name */
        const char* lname,                      /* launcher name */
        jboolean javaargs,                      /* JAVA_ARGS */
        jboolean cpwildcard,                    /* classpath wildcard*/
        jboolean javaw,                         /* windows-only javaw */
        jint ergo                               /* unused */
)
```

### 2.1.2 主流程骨架

```cpp
// java.c:286-436 (骨架版本，保留关键步骤)
int JLI_Launch(int argc, char ** argv, ...) {
    int mode = LM_UNKNOWN;           // ★ 启动模式
    char *what = NULL;               // ★ 主类名或 JAR 文件名
    char *main_class = NULL;         // ★ 从 manifest 提取的主类名
    int ret;                         // ★ 返回值
    InvocationFunctions ifn;         // ★ JVM 函数指针
    char jvmpath[MAXPATHLEN];        // ★ libjvm.so 路径
    char jrepath[MAXPATHLEN];        // ★ JRE 路径
    
    // ★ Step 1: 初始化全局变量
    _fVersion = fullversion;
    _launcher_name = lname;
    _program_name = pname;
    
    // ★ Step 2: 解析 JAR manifest，提取主类名
    SelectVersion(argc, argv, &main_class);
    
    // ★ Step 3: 创建执行环境，找到 JRE 和 JVM 路径
    CreateExecutionEnvironment(&argc, &argv,
                               jrepath, sizeof(jrepath),
                               jvmpath, sizeof(jvmpath),
                               jvmcfg,  sizeof(jvmcfg));
    
    // ★ Step 4: 加载 libjvm.so，获取函数指针
    if (!LoadJavaVM(jvmpath, &ifn)) {
        return(6);
    }
    
    // ★ Step 5: 设置默认 CLASSPATH
    char* cpath = getenv("CLASSPATH");
    if (cpath != NULL) {
        SetClassPath(cpath);
    }
    
    // ★ Step 6: 解析命令行参数
    if (!ParseArguments(&argc, &argv, &mode, &what, &ret, jrepath)) {
        return(ret);
    }
    
    // ★ Step 7: 设置伪属性
    SetJavaCommandLineProp(what, argc, argv);
    SetJavaLauncherProp();
    SetJavaLauncherPlatformProps();
    
    // ★ Step 8: 初始化 JVM 并执行主类
    return JVMInit(&ifn, threadStackSize, argc, argv, mode, what, ret);
}
```

### 2.1.3 设计决策

**为什么函数参数这么多？**

```
参数分类：

1. 命令行参数：
   - argc, argv: 用户输入的命令行参数
   - 例如：java -Xms8g com.example.Main arg1

2. 编译时预定义参数：
   - jargc, jargv: 编译时预设的参数（通常为空）
   - 用途：javac、javadoc 等工具可以预设参数

3. 应用 classpath：
   - appclassc, appclassv: 应用的 classpath
   - 用途：某些工具（如 javac）需要知道 classpath

4. 版本信息：
   - fullversion: 完整版本号（如 "11.0.11+9-LTS"）
   - dotversion: 点版本号（未使用）

5. 元信息：
   - pname: 程序名（如 "java"）
   - lname: 启动器名（如 "openjdk"）
   - javaargs: 是否使用 JAVA_ARGS
   - cpwildcard: 是否启用 classpath 通配符
   - javaw: Windows 专用（是否无控制台窗口）
   - ergo: 未使用

为什么这样设计？
  - 统一的启动器入口
  - 支持多种启动模式（java, javac, javadoc）
  - 灵活配置
```

---

## 2.2 SelectVersion() - 解析 JAR manifest 提取主类名 ⭐⭐⭐⭐

**源码位置**: `java.c:1136-1291`

**解决什么问题**：从 JAR 文件的 MANIFEST.MF 中提取主类名，处理多 JRE 版本选择（已废弃）。

### 2.2.1 完整源码（Linux 版本）

```cpp
// java.c:1136-1291
static void
SelectVersion(int argc, char **argv, char **main_class)
{
    char    *arg;
    char    *operand;
    char    *version = NULL;
    char    *jre = NULL;
    int     jarflag = 0;
    int     headlessflag = 0;
    int     restrict_search = -1;
    manifest_info info;
    char    env_entry[MAXNAMELEN + 24] = ENV_ENTRY "=";
    char    *splash_file_name = NULL;
    char    *splash_jar_name = NULL;
    char    *env_in;
    int     res;
    jboolean has_arg;

    // ★ Step 1: 检查环境变量（mJRE 机制，JDK 1.5-1.8 已废弃）
    if ((env_in = getenv(ENV_ENTRY)) != NULL) {
        if (*env_in != '\0')
            *main_class = JLI_StringDup(env_in);
        return;
    }

    // ★ Step 2: 扫描命令行参数
    argc--;
    argv++;
    while ((arg = *argv) != 0 && *arg == '-') {
        has_arg = IsOptionWithArgument(argc, argv);
        
        // ★ 2.1 检查废弃的多 JRE 选项
        if (JLI_StrCCmp(arg, "-version:") == 0) {
            JLI_ReportErrorMessage(SPC_ERROR1);  // ★ 报错：不再支持
        } else if (JLI_StrCmp(arg, "-jre-restrict-search") == 0) {
            JLI_ReportErrorMessage(SPC_ERROR2);  // ★ 报错：不再支持
        } else if (JLI_StrCmp(arg, "-jre-no-restrict-search") == 0) {
            JLI_ReportErrorMessage(SPC_ERROR2);  // ★ 报错：不再支持
        } else {
            // ★ 2.2 处理有效选项
            if (JLI_StrCmp(arg, "-jar") == 0)
                jarflag = 1;  // ★ 标记 JAR 模式
            
            if (IsWhiteSpaceOption(arg)) {
                if (has_arg) {
                    argc--;
                    argv++;
                    arg = *argv;
                }
            }

            // ★ 2.3 处理 headless 模式
            if (JLI_StrCmp(arg, "-Djava.awt.headless=true") == 0) {
                headlessflag = 1;
            } else if (JLI_StrCCmp(arg, "-Djava.awt.headless=") == 0) {
                headlessflag = 0;
            } else if (JLI_StrCCmp(arg, "-splash:") == 0) {
                splash_file_name = arg+8;  // ★ 提取 splash 屏幕图片名
            }
        }
        argc--;
        argv++;
    }
    
    // ★ Step 3: 获取操作数（JAR 文件名或主类名）
    if (argc <= 0) {
        operand = NULL;
    } else {
        argc--;
        operand = *argv++;
    }

    // ★ Step 4: 解析 JAR manifest（如果是 -jar 模式）
    if (jarflag && operand) {
        if ((res = JLI_ParseManifest(operand, &info)) != 0) {
            if (res == -1)
                JLI_ReportErrorMessage(JAR_ERROR2, operand);
            else
                JLI_ReportErrorMessage(JAR_ERROR3, operand);
            exit(1);
        }

        // ★ 4.1 设置 splash screen（如果 manifest 中有）
        if (!headlessflag && !splash_file_name && info.splashscreen_image_file_name) {
            splash_file_name = info.splashscreen_image_file_name;
            splash_jar_name = operand;
        }
    } else {
        info.manifest_version = NULL;
        info.main_class = NULL;
        info.jre_version = NULL;
        info.jre_restrict_search = 0;
    }

    // ★ Step 5: 通过环境变量传递 splash screen 信息
    if (splash_file_name && !headlessflag) {
        char* splash_file_entry = JLI_MemAlloc(JLI_StrLen(SPLASH_FILE_ENV_ENTRY "=")+JLI_StrLen(splash_file_name)+1);
        JLI_StrCpy(splash_file_entry, SPLASH_FILE_ENV_ENTRY "=");
        JLI_StrCat(splash_file_entry, splash_file_name);
        putenv(splash_file_entry);
    }
    if (splash_jar_name && !headlessflag) {
        char* splash_jar_entry = JLI_MemAlloc(JLI_StrLen(SPLASH_JAR_ENV_ENTRY "=")+JLI_StrLen(splash_jar_name)+1);
        JLI_StrCpy(splash_jar_entry, SPLASH_JAR_ENV_ENTRY "=");
        JLI_StrCat(splash_jar_entry, splash_jar_name);
        putenv(splash_jar_entry);
    }

    // ★ Step 6: 提取主类名（核心输出）
    if (info.main_class != NULL)
        *main_class = JLI_StringDup(info.main_class);

    if (info.jre_version == NULL) {
        JLI_FreeManifest();
        return;
    }
}
```

### 2.2.2 逐行注释

| 代码段 | 深度分析 |
|--------|----------|
| `getenv(ENV_ENTRY)` | **检查 mJRE 环境变量**。JDK 1.5-1.8 支持多 JRE 版本选择，JDK 9+ 已废弃。如果存在，说明是被另一个 JRE 启动的，直接返回主类名 |
| `JLI_StrCmp(arg, "-jar")` | **检测 JAR 模式**。标记 jarflag = 1，后续会解析 JAR manifest |
| `JLI_ParseManifest(operand, &info)` | **解析 JAR manifest**。打开 JAR 文件，读取 META-INF/MANIFEST.MF，提取 Main-Class、JRE-Version 等信息 |
| `info.main_class` | **核心输出**。存储提取的主类名，如 "com.example.Main" |
| `putenv(splash_file_entry)` | **通过环境变量传递 splash screen 信息**。子进程（如果有）会读取这个环境变量 |

### 2.2.3 设计决策

**为什么通过环境变量传递主类名和 splash screen？**

```
多进程通信的需求：

场景 1：mJRE 机制（已废弃）
  - JAR manifest 指定了 JRE 版本：JRE-Version: 1.8
  - 当前 JRE 是 11，需要启动 JRE 1.8
  - 当前进程 execve() 启动 JRE 1.8 的 java 命令
  - 主类名通过环境变量传递给新进程

场景 2：splash screen
  - splash 图片在 JAR 文件中
  - 需要在 JVM 启动前显示
  - 通过环境变量传递给 splash screen 库

为什么用环境变量？
  - execve() 后环境变量自动继承
  - 不需要修改 argv（复杂且容易出错）
  - 简单、可靠、跨平台
```

**为什么多 JRE 机制被废弃？**

```
多 JRE 的问题：

1. **复杂性**
   - 需要在系统中安装多个 JRE 版本
   - JAR manifest 需要指定版本
   - 启动器需要版本选择逻辑

2. **安全问题**
   - 旧版本 JRE 可能有安全漏洞
   - 自动降级到旧版本可能被利用

3. **维护困难**
   - 用户需要维护多个 JRE
   - 兼容性测试复杂

JDK 9+ 的解决方案：
  - 只支持当前 JRE
  - JAR 可以指定最低版本（JEP 247）
  - 模块化系统提供更好的依赖管理
```

---

## 2.3 CreateExecutionEnvironment() - 创建执行环境（Linux 平台）⭐⭐⭐⭐⭐

**源码位置**: `java_md_solinux.c:303-487`（平台相关）

**解决什么问题**：找到 JRE 路径、JVM 类型、libjvm.so 路径，必要时设置 LD_LIBRARY_PATH 并重新 exec。

### 2.3.1 完整源码（Linux 版本，关键部分）

```cpp
// java_md_solinux.c:303-487
void
CreateExecutionEnvironment(int *pargc, char ***pargv,
                           char jrepath[], jint so_jrepath,
                           char jvmpath[], jint so_jvmpath,
                           char jvmcfg[],  jint so_jvmcfg) {

    char * jvmtype = NULL;
    int argc = *pargc;
    char **argv = *pargv;

#ifdef SETENV_REQUIRED
    jboolean mustsetenv = JNI_FALSE;
    char *runpath = NULL;
    char* new_runpath = NULL;
    char* newpath = NULL;
    char* lastslash = NULL;
    char** newenvp = NULL;
    size_t new_runpath_size;
#endif

    // ★ Step 1: 设置可执行程序名（全局变量 execname）
    SetExecname(*pargv);  // ★ Linux: 读取 /proc/self/exe

    // ★ Step 2: 查找 JRE 路径
    if (!GetJREPath(jrepath, so_jrepath, JNI_FALSE)) {
        JLI_ReportErrorMessage(JRE_ERROR1);
        exit(2);
    }
    // ★ jrepath 示例：/data/workspace/openjdk11/build/jdk

    // ★ Step 3: 拼接 jvm.cfg 路径
    JLI_Snprintf(jvmcfg, so_jvmcfg, "%s%slib%sjvm.cfg",
            jrepath, FILESEP, FILESEP);
    // ★ jvmcfg 示例：/data/workspace/openjdk11/build/jdk/lib/jvm.cfg

    // ★ Step 4: 读取 jvm.cfg，解析已知的 JVM 类型
    if (ReadKnownVMs(jvmcfg, JNI_FALSE) < 1) {
        JLI_ReportErrorMessage(CFG_ERROR7);
        exit(1);
    }

    // ★ Step 5: 检查用户指定的 JVM 类型（-server, -client 等）
    jvmpath[0] = '\0';
    jvmtype = CheckJvmType(pargc, pargv, JNI_FALSE);  // ★ jvmtype = "server"
    if (JLI_StrCmp(jvmtype, "ERROR") == 0) {
        JLI_ReportErrorMessage(CFG_ERROR9);
        exit(4);
    }

    // ★ Step 6: 检查 libjvm.so 是否存在，并保存路径
    if (!GetJVMPath(jrepath, jvmtype, jvmpath, so_jvmpath)) {
        JLI_ReportErrorMessage(CFG_ERROR8, jvmtype, jvmpath);
        exit(4);
    }
    // ★ jvmpath 示例：/data/workspace/openjdk11/build/jdk/lib/server/libjvm.so

    // ★ Step 7: 设置 LD_LIBRARY_PATH（如果需要）
#ifdef SETENV_REQUIRED
    mustsetenv = RequiresSetenv(jvmpath);
    JLI_TraceLauncher("mustsetenv: %s\n", mustsetenv ? "TRUE" : "FALSE");

    if (mustsetenv == JNI_FALSE) {
        return;
    }
#else
    return;  // ★ Linux 默认不需要设置
#endif

#ifdef SETENV_REQUIRED
    if (mustsetenv) {
        // ★ 7.1 获取当前的 LD_LIBRARY_PATH
        runpath = getenv(LD_LIBRARY_PATH);

        // ★ 7.2 构造新的 LD_LIBRARY_PATH
        {
            char *new_jvmpath = JLI_StringDup(jvmpath);
            new_runpath_size = ((runpath != NULL) ? JLI_StrLen(runpath) : 0) +
                    2 * JLI_StrLen(jrepath) +
                    JLI_StrLen(new_jvmpath) + 52;
            new_runpath = JLI_MemAlloc(new_runpath_size);
            newpath = new_runpath + JLI_StrLen(LD_LIBRARY_PATH "=");

            // ★ 7.3 移除 libjvm.so 文件名，只保留目录
            lastslash = JLI_StrRChr(new_jvmpath, '/');
            if (lastslash)
                *lastslash = '\0';

            // ★ 7.4 设置 LD_LIBRARY_PATH
            sprintf(new_runpath, LD_LIBRARY_PATH "="
                    "%s:"        // libjvm.so 所在目录
                    "%s/lib:"    // $JRE/lib
                    "%s/../lib", // $JRE/../lib
                    new_jvmpath,
                    jrepath,
                    jrepath
                    );

            JLI_MemFree(new_jvmpath);

            // ★ 7.5 检查是否已经设置过
            if (runpath != NULL &&
                    JLI_StrNCmp(newpath, runpath, JLI_StrLen(newpath)) == 0 &&
                    (runpath[JLI_StrLen(newpath)] == 0 ||
                    runpath[JLI_StrLen(newpath)] == ':')) {
                JLI_MemFree(new_runpath);
                return;  // ★ 已经设置过，不需要重新 exec
            }
        }

        // ★ 7.6 追加用户原有的 LD_LIBRARY_PATH
        if (runpath != 0) {
            if ((JLI_StrLen(runpath) + 1 + 1) > new_runpath_size) {
                JLI_ReportErrorMessageSys(JRE_ERROR11);
                exit(1);
            }
            JLI_StrCat(new_runpath, ":");
            JLI_StrCat(new_runpath, runpath);
        }

        // ★ 7.7 设置环境变量
        if (putenv(new_runpath) != 0) {
            exit(1);
        }

        newenvp = environ;
    }
#endif

    // ★ Step 8: 重新 exec（因为 LD_LIBRARY_PATH 只在启动时读取）
    {
        char *newexec = execname;
        JLI_TraceLauncher("TRACER_MARKER:About to EXEC\n");
        (void) fflush(stdout);
        (void) fflush(stderr);
#ifdef SETENV_REQUIRED
        if (mustsetenv) {
            execve(newexec, argv, newenvp);
        } else {
            execv(newexec, argv);
        }
#else
        execv(newexec, argv);  // ★ Linux 默认路径
#endif
        JLI_ReportErrorMessageSys(JRE_ERROR4, newexec);
    }
    exit(1);
}
```

### 2.3.2 逐行注释

| 代码段 | 深度分析 |
|--------|----------|
| `SetExecname(*pargv)` | **设置全局变量 execname**。Linux 上读取 `/proc/self/exe` 获取当前可执行文件的绝对路径 |
| `GetJREPath(jrepath, ...)` | **查找 JRE 路径**。通过 `java` 可执行文件的位置推导 JRE 路径，验证 `$JRE/lib/libjava.so` 是否存在 |
| `ReadKnownVMs(jvmcfg, ...)` | **读取 jvm.cfg**。解析 `$JRE/lib/jvm.cfg`，填充全局数组 `knownVMs[]` |
| `CheckJvmType(pargc, pargv, ...)` | **检查 JVM 类型**。解析 `-server`、`-client` 等选项，返回 JVM 类型名（如 "server"） |
| `GetJVMPath(jrepath, jvmtype, ...)` | **构造 libjvm.so 路径**。拼接 `$JRE/lib/$jvmtype/libjvm.so`，验证文件是否存在 |
| `putenv(new_runpath)` | **设置 LD_LIBRARY_PATH**。让动态链接器能找到 libjvm.so 及其依赖库 |
| `execv(newexec, argv)` | **重新执行**。因为 Unix/Linux 只在进程启动时读取 LD_LIBRARY_PATH，修改后必须重新 exec 才能生效 |

### 2.3.3 设计决策

**为什么需要重新 exec？**

```
Unix/Linux 动态链接器的限制：

LD_LIBRARY_PATH 的读取时机：
  - 进程启动时（execve）读取一次
  - 之后修改环境变量不影响已加载的库

修改 LD_LIBRARY_PATH 的场景：
  - libjvm.so 所在目录不在默认路径
  - 需要加载 libjvm.so 的依赖库（如 libjava.so、libjli.so）

解决方案：
  1. putenv(new_runpath) 设置环境变量
  2. execv(newexec, argv) 重新执行自己
  3. 新进程启动时，动态链接器读取新的 LD_LIBRARY_PATH
  4. 成功加载 libjvm.so

为什么不用 dlopen 的 RTLD_GLOBAL？
  - dlopen 可以加载 libjvm.so
  - 但无法加载 libjvm.so 的依赖库
  - 依赖库也需要在 LD_LIBRARY_PATH 中
  - 必须重新 exec
```

**Linux 为什么默认不设置 LD_LIBRARY_PATH？**

```
Linux 的 RPATH/RUNPATH 机制：

编译时嵌入路径：
  - gcc -Wl,-rpath,/path/to/lib ...
  - 可执行文件中嵌入库搜索路径
  - 运行时自动搜索，不需要 LD_LIBRARY_PATH

OpenJDK 的做法：
  - java 可执行文件编译时嵌入 RPATH：$ORIGIN/../lib
  - $ORIGIN 是可执行文件所在目录
  - 自动搜索 ../lib 目录
  - 大多数情况下不需要设置 LD_LIBRARY_PATH

何时需要 SETENV_REQUIRED？
  - 某些平台（如 Solaris）不支持 $ORIGIN
  - 自定义构建可能没有设置 RPATH
  - 需要兼容旧版本
```

---

## 2.4 ReadKnownVMs() - 读取 jvm.cfg 配置文件 ⭐⭐⭐⭐

**源码位置**: `java.c:2165-2271`

**解决什么问题**：解析 `$JRE/lib/jvm.cfg` 文件，获取可用的 JVM 类型列表（server、client、zero 等）。

### 2.4.1 完整源码

```cpp
// java.c:2165-2271
jint
ReadKnownVMs(const char *jvmCfgName, jboolean speculative)
{
    FILE *jvmCfg;
    char line[MAXPATHLEN+20];
    int cnt = 0;
    int lineno = 0;
    jlong start = 0, end = 0;
    int vmType;
    char *tmpPtr;
    char *altVMName = NULL;
    char *serverClassVMName = NULL;
    static char *whiteSpace = " \t";
    
    if (JLI_IsTraceLauncher()) {
        start = CounterGet();
    }
    
    // ★ Step 1: 打开 jvm.cfg 文件
    jvmCfg = fopen(jvmCfgName, "r");
    if (jvmCfg == NULL) {
      if (!speculative) {
        JLI_ReportErrorMessage(CFG_ERROR6, jvmCfgName);
        exit(1);
      } else {
        return -1;
      }
    }
    
    // ★ Step 2: 逐行解析
    while (fgets(line, sizeof(line), jvmCfg) != NULL) {
        vmType = VM_UNKNOWN;
        lineno++;
        
        // ★ 2.1 跳过注释行
        if (line[0] == '#')
            continue;
        
        // ★ 2.2 检查行首是否有 '-'（JVM 类型名必须以 '-' 开头）
        if (line[0] != '-') {
            JLI_ReportErrorMessage(CFG_WARN2, lineno, jvmCfgName);
        }
        
        // ★ 2.3 扩容 knownVMs 数组（如果需要）
        if (cnt >= knownVMsLimit) {
            GrowKnownVMs(cnt);
        }
        
        // ★ 2.4 移除行尾的换行符
        line[JLI_StrLen(line)-1] = '\0';
        
        // ★ 2.5 分割字符串："-server KNOWN"
        tmpPtr = line + JLI_StrCSpn(line, whiteSpace);
        if (*tmpPtr == 0) {
            JLI_ReportErrorMessage(CFG_WARN3, lineno, jvmCfgName);
        } else {
            // ★ 2.6 提取 JVM 类型名（如 "-server"）
            *tmpPtr++ = 0;
            tmpPtr += JLI_StrSpn(tmpPtr, whiteSpace);
            
            if (*tmpPtr == 0) {
                JLI_ReportErrorMessage(CFG_WARN3, lineno, jvmCfgName);
            } else {
                // ★ 2.7 解析 JVM 类型标记
                if (!JLI_StrCCmp(tmpPtr, "KNOWN")) {
                    vmType = VM_KNOWN;  // ★ 已知可用
                } else if (!JLI_StrCCmp(tmpPtr, "ALIASED_TO")) {
                    // ★ 别名：-zero ALIASED_TO -server
                    tmpPtr += JLI_StrCSpn(tmpPtr, whiteSpace);
                    if (*tmpPtr != 0) {
                        tmpPtr += JLI_StrSpn(tmpPtr, whiteSpace);
                    }
                    if (*tmpPtr == 0) {
                        JLI_ReportErrorMessage(CFG_WARN3, lineno, jvmCfgName);
                    } else {
                        altVMName = tmpPtr;
                        tmpPtr += JLI_StrCSpn(tmpPtr, whiteSpace);
                        *tmpPtr = 0;
                        vmType = VM_ALIASED_TO;
                    }
                } else if (!JLI_StrCCmp(tmpPtr, "WARN")) {
                    vmType = VM_WARN;  // ★ 警告：已废弃
                } else if (!JLI_StrCCmp(tmpPtr, "IGNORE")) {
                    vmType = VM_IGNORE;  // ★ 忽略：不可用
                } else if (!JLI_StrCCmp(tmpPtr, "ERROR")) {
                    vmType = VM_ERROR;  // ★ 错误：不可用
                } else if (!JLI_StrCCmp(tmpPtr, "IF_SERVER_CLASS")) {
                    /* ignored */
                } else {
                    JLI_ReportErrorMessage(CFG_WARN5, lineno, &jvmCfgName[0]);
                    vmType = VM_KNOWN;
                }
            }
        }

        JLI_TraceLauncher("jvm.cfg[%d] = ->%s<-\n", cnt, line);
        
        // ★ Step 3: 保存到全局数组 knownVMs[]
        if (vmType != VM_UNKNOWN) {
            knownVMs[cnt].name = JLI_StringDup(line);  // ★ "-server"
            knownVMs[cnt].flag = vmType;               // ★ VM_KNOWN
            switch (vmType) {
            default:
                break;
            case VM_ALIASED_TO:
                knownVMs[cnt].alias = JLI_StringDup(altVMName);  // ★ "-server"
                JLI_TraceLauncher("    name: %s  vmType: %s  alias: %s\n",
                   knownVMs[cnt].name, "VM_ALIASED_TO", knownVMs[cnt].alias);
                break;
            }
            cnt++;
        }
    }
    
    fclose(jvmCfg);
    knownVMsCount = cnt;

    if (JLI_IsTraceLauncher()) {
        end = CounterGet();
        printf("%ld micro seconds to parse jvm.cfg\n",
               (long)(jint)Counter2Micros(end-start));
    }

    return cnt;
}
```

### 2.4.2 jvm.cfg 文件示例

```
# $JAVA_HOME/lib/jvm.cfg 内容示例

# Linux x86_64
-server KNOWN
-client IGNORE

# Linux ARM
-zero ALIASED_TO -server
-shark IGNORE

# 废弃的 JVM 类型
-gsg WARN
-gsgc WARN
```

**解析结果**：

```
knownVMs[0]:
  name = "-server"
  flag = VM_KNOWN
  alias = NULL

knownVMs[1]:
  name = "-client"
  flag = VM_IGNORE
  alias = NULL

knownVMs[2]:
  name = "-zero"
  flag = VM_ALIASED_TO
  alias = "-server"

knownVMs[3]:
  name = "-shark"
  flag = VM_IGNORE
  alias = NULL
```

### 2.4.3 设计决策

**为什么需要 jvm.cfg 文件？**

```
灵活配置 JVM 类型：

不同平台的 JVM 类型不同：
  - Linux x86_64: server, client（已移除）
  - Linux ARM: zero, shark（已废弃）
  - Solaris SPARC: server, client, tiered
  - Windows: server, client

配置文件的优势：
  1. 平台无关的启动器代码
     - 不需要硬编码 JVM 类型
     - 不同平台有不同的 jvm.cfg

  2. 灵活的别名机制
     - zero → server（zero 只是 server 的别名）
     - 平滑迁移，用户无感知

  3. 废弃警告
     - VM_WARN: 打印警告，回退到默认
     - 避免用户使用已废弃的 JVM 类型

  4. 易于扩展
     - 添加新的 JVM 类型：只需修改 jvm.cfg
     - 不需要重新编译启动器
```

**为什么不硬编码？**

```
硬编码的问题：

if (strcmp(jvmtype, "server") == 0) {
    // Linux x86_64
    jvmpath = "$JRE/lib/server/libjvm.so";
} else if (strcmp(jvmtype, "zero") == 0) {
    // Linux ARM
    jvmpath = "$JRE/lib/zero/libjvm.so";
} else if (...) {
    // 其他平台
}

问题：
  1. 每个平台需要不同的代码分支
  2. 添加新 JVM 类型需要修改代码
  3. 废弃旧类型需要修改代码
  4. 别名机制复杂

配置文件的优势：
  - 一个统一的代码逻辑
  - 所有配置在 jvm.cfg 中
  - 易于维护和扩展
```

---

## 2.5 CheckJvmType() - 检查 JVM 类型 ⭐⭐⭐⭐

**源码位置**: `java.c:757-896`

**解决什么问题**：检查用户指定的 JVM 类型是否有效，处理别名，返回真实的 JVM 类型名。

### 2.5.1 完整源码

```cpp
// java.c:757-896
char *
CheckJvmType(int *pargc, char ***argv, jboolean speculative) {
    int i, argi;
    int argc;
    char **newArgv;
    int newArgvIdx = 0;
    int isVMType;
    int jvmidx = -1;
    char *jvmtype = getenv("JDK_ALTERNATE_VM");  // ★ 环境变量指定 JVM 类型

    argc = *pargc;

    // ★ Step 1: 复制 argv 数组（移除 JVM 类型参数）
    newArgv = JLI_MemAlloc((argc + 1) * sizeof(char *));

    // ★ Step 2: 程序名总是存在
    newArgv[newArgvIdx++] = (*argv)[0];

    for (argi = 1; argi < argc; argi++) {
        char *arg = (*argv)[argi];
        isVMType = 0;

        if (IsJavaArgs()) {
            if (arg[0] != '-') {
                newArgv[newArgvIdx++] = arg;
                continue;
            }
        } else {
            if (IsWhiteSpaceOption(arg)) {
                newArgv[newArgvIdx++] = arg;
                argi++;
                if (argi < argc) {
                    newArgv[newArgvIdx++] = (*argv)[argi];
                }
                continue;
            }
            if (arg[0] != '-') break;
        }

        // ★ Step 3: 检查是否指定了 JVM 类型（如 -server, -client）
        i = KnownVMIndex(arg);
        if (i >= 0) {
            jvmtype = knownVMs[jvmidx = i].name + 1;  // ★ 跳过 '-'
            isVMType = 1;
            *pargc = *pargc - 1;  // ★ 移除这个参数
        }

        // ★ Step 4: 检查是否指定了 alternate JVM（如 -XXaltjvm=/path/to/jvm）
        else if (JLI_StrCCmp(arg, "-XXaltjvm=") == 0 || JLI_StrCCmp(arg, "-J-XXaltjvm=") == 0) {
            isVMType = 1;
            jvmtype = arg+((arg[1]=='X')? 10 : 12);
            jvmidx = -1;  // ★ 标记为 alternate JVM
        }

        if (!isVMType) {
            newArgv[newArgvIdx++] = arg;
        }
    }

    // ★ Step 5: 复制剩余参数
    while (argi < argc) {
        newArgv[newArgvIdx++] = (*argv)[argi];
        argi++;
    }

    newArgv[newArgvIdx] = 0;

    // ★ Step 6: 更新 argv
    *argv = newArgv;
    *pargc = newArgvIdx;

    // ★ Step 7: 如果没有指定 JVM 类型，使用默认（第一个）
    if (jvmtype == NULL) {
      char* result = knownVMs[0].name+1;
      JLI_TraceLauncher("Default VM: %s\n", result);
      return result;
    }

    // ★ Step 8: 如果是 alternate JVM，直接返回路径
    if (jvmidx < 0)
      return jvmtype;

    // ★ Step 9: 处理别名（循环跟随 alias 字段）
    {
      int loopCount = 0;
      while (knownVMs[jvmidx].flag == VM_ALIASED_TO) {
        int nextIdx = KnownVMIndex(knownVMs[jvmidx].alias);

        if (loopCount > knownVMsCount) {
          if (!speculative) {
            JLI_ReportErrorMessage(CFG_ERROR1);  // ★ 循环引用
            exit(1);
          } else {
            return "ERROR";
          }
        }

        if (nextIdx < 0) {
          if (!speculative) {
            JLI_ReportErrorMessage(CFG_ERROR2, knownVMs[jvmidx].alias);
            exit(1);
          } else {
            return "ERROR";
          }
        }
        jvmidx = nextIdx;
        jvmtype = knownVMs[jvmidx].name+1;
        loopCount++;
      }
    }

    // ★ Step 10: 根据 flag 处理
    switch (knownVMs[jvmidx].flag) {
    case VM_WARN:
        if (!speculative) {
            JLI_ReportErrorMessage(CFG_WARN1, jvmtype, knownVMs[0].name + 1);
        }
        /* fall through */
    case VM_IGNORE:
        jvmtype = knownVMs[jvmidx=0].name + 1;  // ★ 使用默认 JVM
        /* fall through */
    case VM_KNOWN:
        break;
    case VM_ERROR:
        if (!speculative) {
            JLI_ReportErrorMessage(CFG_ERROR3, jvmtype);
            exit(1);
        } else {
            return "ERROR";
        }
    }

    return jvmtype;
}
```

### 2.5.2 设计决策

**如何处理别名？**

```
别名处理流程：

用户指定：java -zero MyApp

检查 knownVMs：
  knownVMs[2]:
    name = "-zero"
    flag = VM_ALIASED_TO
    alias = "-server"

跟随别名：
  jvmidx = KnownVMIndex("-server") = 0
  jvmtype = knownVMs[0].name+1 = "server"

结果：
  使用 server JVM

为什么需要循环？
  - 支持多级别名
  - zero → client → server

循环检测：
  - loopCount > knownVMsCount
  - 防止无限循环（别名循环引用）
```

**VM_WARN vs VM_IGNORE vs VM_ERROR？**

```
三者的区别：

VM_WARN（警告）：
  - 打印警告消息
  - 回退到默认 JVM（knownVMs[0]）
  - 继续运行
  - 示例：java -gsg MyApp
    → 警告：gsg 已废弃，使用 server

VM_IGNORE（忽略）：
  - 不打印警告
  - 回退到默认 JVM
  - 继续运行
  - 示例：java -client MyApp
    → 直接使用 server（client 已移除）

VM_ERROR（错误）：
  - 打印错误消息
  - 退出
  - 示例：java -invalid MyApp
    → 错误：无效的 JVM 类型

设计原因：
  - VM_WARN: 用户可能不知道已废弃，提醒
  - VM_IGNORE: 用户可能使用旧脚本，默默处理
  - VM_ERROR: 用户明确指定了不存在的类型，报错
```

---

## 2.6 AddOption() - 添加 JVM 选项 ⭐⭐⭐⭐

**源码位置**: `java.c:1012-1063`

**解决什么问题**：将 JVM 选项添加到全局 `options[]` 数组，动态扩容。

### 2.6.1 完整源码

```cpp
// java.c:1012-1063
void
AddOption(char *str, void *info)
{
    // ★ Step 1: 检查是否需要扩容
    if (numOptions >= maxOptions) {
        if (options == 0) {
            // ★ 首次分配：分配 4 个 JavaVMOption
            maxOptions = 4;
            options = JLI_MemAlloc(maxOptions * sizeof(JavaVMOption));
        } else {
            // ★ 扩容：容量翻倍
            JavaVMOption *tmp;
            maxOptions *= 2;
            tmp = JLI_MemAlloc(maxOptions * sizeof(JavaVMOption));
            memcpy(tmp, options, numOptions * sizeof(JavaVMOption));
            JLI_MemFree(options);
            options = tmp;
        }
    }
    
    // ★ Step 2: 添加选项
    options[numOptions].optionString = str;  // ★ 如 "-Xms8g"
    options[numOptions++].extraInfo = info;  // ★ 通常为 NULL

    // ★ Step 3: 特殊处理：-Xss（线程栈大小）
    if (JLI_StrCCmp(str, "-Xss") == 0) {
        jlong tmp;
        if (parse_size(str + 4, &tmp)) {
            threadStackSize = tmp;  // ★ 保存到全局变量
            // ★ 确保栈大小足够大
            if (threadStackSize < (jlong)STACK_SIZE_MINIMUM) {
                threadStackSize = STACK_SIZE_MINIMUM;
            }
        }
    }

    // ★ Step 4: 特殊处理：-Xmx（最大堆大小）
    if (JLI_StrCCmp(str, "-Xmx") == 0) {
        jlong tmp;
        if (parse_size(str + 4, &tmp)) {
            maxHeapSize = tmp;  // ★ 保存到全局变量
        }
    }

    // ★ Step 5: 特殊处理：-Xms（初始堆大小）
    if (JLI_StrCCmp(str, "-Xms") == 0) {
        jlong tmp;
        if (parse_size(str + 4, &tmp)) {
           initialHeapSize = tmp;  // ★ 保存到全局变量
        }
    }
}
```

### 2.6.2 逐行注释

| 代码段 | 深度分析 |
|--------|----------|
| `if (numOptions >= maxOptions)` | **检查是否需要扩容**。初始为 0，第一次添加时分配 4 个元素 |
| `maxOptions *= 2` | **容量翻倍**。典型动态数组扩容策略，摊销 O(1) |
| `options[numOptions].optionString = str` | **保存选项字符串**。注意：str 是指针，不复制字符串内容 |
| `JLI_StrCCmp(str, "-Xss")` | **特殊处理线程栈大小**。保存到全局变量 `threadStackSize`，供 `ContinueInNewThread()` 使用 |
| `parse_size(str + 4, &tmp)` | **解析大小字符串**。如 "8g" → 8589934592，支持 k/K/m/M/g/G 后缀 |

### 2.6.3 设计决策

**为什么用动态扩容而不是固定大小？**

```
固定大小的问题：

#define MAX_OPTIONS 100
JavaVMOption options[MAX_OPTIONS];

问题：
  1. 限制 JVM 参数数量
     - 用户可能需要大量参数
     - 模块化应用：每个模块都可能有参数

  2. 浪费内存
     - 大多数应用只使用少量参数
     - 固定 100 个槽位浪费内存

动态扩容的优势：
  1. 无限制（受限于内存）
  2. 按需分配，节省内存
  3. 性能良好：摊销 O(1)

容量翻倍策略：
  - 初始：4 个
  - 第一次扩容：8 个
  - 第二次扩容：16 个
  - ...
  - n 次扩容：4 * 2^n 个

  摊销分析：
    - 总扩容次数：O(log n)
    - 总复制次数：O(n)
    - 摊销每次添加：O(1)
```

**为什么特殊处理 -Xss、-Xmx、-Xms？**

```
三个参数的特殊性：

-Xss（线程栈大小）：
  - 需要在创建 JavaMain 线程时使用
  - Save to threadStackSize
  - ContinueInNewThread() 会读取这个值

-Xmx（最大堆大小）：
  - 用于诊断信息
  - 保存到 maxHeapSize
  - ShowSettings() 会显示

-Xms（初始堆大小）：
  - 用于诊断信息
  - 保存到 initialHeapSize
  - ShowSettings() 会显示

为什么不在 ParseArguments() 中处理？
  - ParseArguments() 只负责识别参数类型
  - AddOption() 是所有选项的统一入口
  - 集中处理特殊参数，避免重复代码
```

---

## 2.7 SetClassPath() - 设置 CLASSPATH ⭐⭐⭐⭐

**源码位置**: `java_md.c`（平台相关，Linux 版本在 `src/java.base/unix/native/libjli/java_md.c`）

**解决什么问题**：动态加载 libjvm.so，获取 JNI 函数指针。

### 2.2.1 完整源码（Linux 版本，简化）

```cpp
// java_md.c (简化版)
jboolean LoadJavaVM(const char *jvmpath, InvocationFunctions *ifn) {
    void *libjvm;
    
    // ★ Step 1: 动态加载 libjvm.so
    libjvm = dlopen(jvmpath, RTLD_NOW + RTLD_GLOBAL);
    if (libjvm == NULL) {
        JLI_ReportErrorMessage(DLL_ERROR1, __LINE__);
        JLI_ReportErrorMessage(DLL_ERROR2, dlerror());
        return JNI_FALSE;
    }
    
    // ★ Step 2: 获取 JNI_CreateJavaVM 函数指针
    ifn->CreateJavaVM = (CreateJavaVM_t)
        dlsym(libjvm, "JNI_CreateJavaVM");
    if (ifn->CreateJavaVM == NULL) {
        JLI_ReportErrorMessage(DLL_ERROR1, __LINE__);
        JLI_ReportErrorMessage(DLL_ERROR2, dlerror());
        return JNI_FALSE;
    }
    
    // ★ Step 3: 获取 JNI_GetDefaultJavaVMInitArgs 函数指针
    ifn->GetDefaultJavaVMInitArgs = (GetDefaultJavaVMInitArgs_t)
        dlsym(libjvm, "JNI_GetDefaultJavaVMInitArgs");
    if (ifn->GetDefaultJavaVMInitArgs == NULL) {
        JLI_ReportErrorMessage(DLL_ERROR1, __LINE__);
        JLI_ReportErrorMessage(DLL_ERROR2, dlerror());
        return JNI_FALSE;
    }
    
    // ★ Step 4: 获取 JNI_GetCreatedJavaVMs 函数指针
    ifn->GetCreatedJavaVMs = (GetCreatedJavaVMs_t)
        dlsym(libjvm, "JNI_GetCreatedJavaVMs");
    if (ifn->GetCreatedJavaVMs == NULL) {
        JLI_ReportErrorMessage(DLL_ERROR1, __LINE__);
        JLI_ReportErrorMessage(DLL_ERROR2, dlerror());
        return JNI_FALSE;
    }
    
    return JNI_TRUE;
}
```

### 2.2.2 逐行注释

| 行号 | 代码 | 深度分析 |
|------|------|----------|
| dlopen | `dlopen(jvmpath, RTLD_NOW + RTLD_GLOBAL)` | **加载动态库**。RTLD_NOW：立即解析所有符号；RTLD_GLOBAL：符号对其他库可见 |
| dlsym | `dlsym(libjvm, "JNI_CreateJavaVM")` | **查找符号**。返回 JNI_CreateJavaVM 函数的地址 |
| 类型转换 | `(CreateJavaVM_t)dlsym(...)` | **类型转换**。将 void* 转换为函数指针类型 |

### 2.2.3 设计决策

**为什么用 dlopen 而不是静态链接？**

```
动态加载的优势：

1. **代码复用**
   - libjvm.so 被多个工具共享
   - 减少磁盘和内存占用

2. **版本选择**
   - 可以选择不同版本的 JVM
   - client/server 模式切换

3. **灵活性**
   - 可以在运行时决定加载哪个 JVM
   - 支持嵌入 JVM

4. **维护性**
   - JVM 更新不需要重新编译启动器
   - 解耦合

静态链接的问题：
  - 每个工具都包含 JVM 代码
  - 体积巨大（libjvm.so ~20MB）
  - 更新困难
```

**RTLD_NOW vs RTLD_LAZY？**

```
dlopen 的标志位：

RTLD_NOW：
  - 立即解析所有符号
  - 如果符号不存在，立即失败
  - 优点：错误早发现
  - 缺点：启动稍慢

RTLD_LAZY：
  - 延迟解析符号
  - 第一次调用时才解析
  - 优点：启动快
  - 缺点：运行时才发现错误

JVM 的选择：RTLD_NOW
  - 确保所有必需符号都存在
  - 避免运行时才发现缺少符号
  - JVM 启动已经够慢了，不在乎这点差异

RTLD_GLOBAL：
  - 导出符号给其他动态库
  - 允许 libjvm.so 中的符号被其他库引用
  - 某些 JNI 库可能需要引用 JVM 内部符号
```

---

## 2.7 SetClassPath() - 设置 CLASSPATH ⭐⭐⭐⭐

**源码位置**: `java.c:1065-1091`

**解决什么问题**：将 CLASSPATH 转换为 JVM 系统属性 `-Djava.class.path=...`。

### 2.7.1 完整源码

```cpp
// java.c:1065-1091
static void
SetClassPath(const char *s)
{
    char *def;
    const char *orig = s;
    static const char format[] = "-Djava.class.path=%s";
    
    // ★ Step 1: 检查 NULL
    if (s == NULL)
        return;
    
    // ★ Step 2: 展开通配符（lib/* → lib/a.jar:lib/b.jar）
    s = JLI_WildcardExpandClasspath(s);
    
    // ★ Step 3: 检查字符串是否损坏（溢出检查）
    if (sizeof(format) - 2 + JLI_StrLen(s) < JLI_StrLen(s))
        return;  // ★ s is became corrupted after expanding wildcards
    
    // ★ Step 4: 分配内存
    def = JLI_MemAlloc(sizeof(format)
                       - 2 /* strlen("%s") */
                       + JLI_StrLen(s));
    
    // ★ Step 5: 格式化字符串
    sprintf(def, format, s);  // ★ "-Djava.class.path=/app:/lib/*"
    
    // ★ Step 6: 添加到全局 options 数组
    AddOption(def, NULL);
    
    // ★ Step 7: 释放展开后的字符串（如果展开了）
    if (s != orig)
        JLI_MemFree((char *) s);
    
    _have_classpath = JNI_TRUE;  // ★ 标记已设置 classpath
}
```

### 2.7.2 逐行注释

| 代码段 | 深度分析 |
|--------|----------|
| `JLI_WildcardExpandClasspath(s)` | **展开通配符**。如 `lib/*` → `lib/a.jar:lib/b.jar:lib/c.jar`。返回的字符串可能是新分配的（如果展开了）或原指针（如果没有通配符） |
| `sizeof(format) - 2 + JLI_StrLen(s) < JLI_StrLen(s)` | **溢出检查**。如果展开后的字符串太长，可能导致整数溢出，这个检查防止溢出 |
| `sprintf(def, format, s)` | **格式化为系统属性**。JVM 会解析 `-Djava.class.path=...`，设置类加载器的搜索路径 |
| `AddOption(def, NULL)` | **添加到全局数组**。options[numOptions].optionString = "-Djava.class.path=/app:/lib/*" |
| `if (s != orig) JLI_MemFree((char *) s)` | **条件释放**。如果展开了通配符，`s` 是新分配的字符串，需要释放；否则 `s` 指向原字符串，不需要释放 |

### 2.7.3 设计决策

**为什么支持通配符？**

```
CLASSPATH 通配符的好处：

命令行简写：
  java -cp "lib/*" com.example.Main

  等价于：

  java -cp "lib/a.jar:lib/b.jar:lib/c.jar:lib/d.jar" com.example.Main

优势：
  1. 简化命令行
     - 不需要列出每个 jar 文件
     - 自动包含新增的 jar

  2. 避免参数过长
     - Windows 命令行有长度限制
     - 通配符可以大幅缩短

  3. 易于维护
     - 添加新 jar 不需要修改脚本

注意事项：
  - 只匹配 .jar 和 .JAR 文件
  - 不递归（lib/*/* 不匹配）
  - 展开顺序不确定（按文件系统顺序）
```

**为什么不直接设置环境变量？**

```
JVM 不读取 CLASSPATH 环境变量的原因：

启动流程：
  1. libjli.so 启动
  2. ParseArguments() 解析参数
  3. SetClassPath() 设置
  4. AddOption() 添加到 options[]
  5. InitializeJVM() 创建 JVM
  6. JNI_CreateJavaVM() 读取 options[]

为什么不读环境变量？
  - JVM 参数统一管理
  - options[] 数组是唯一来源
  - 环境变量可能冲突
  - 支持多个 -cp 参数（后者覆盖前者）

设计优势：
  - 统一的参数来源
  - 易于诊断（-XshowSettings）
  - 易于调试（打印 options[]）
```

---

## 2.8 SetJavaCommandLineProp() - 设置 sun.java.command 属性 ⭐⭐⭐

**源码位置**: `java.c:1914-1958`

**解决什么问题**：将完整的命令行保存为系统属性 `sun.java.command`，供诊断工具使用。

### 2.8.1 完整源码

```cpp
// java.c:1914-1958
void
SetJavaCommandLineProp(char *what, int argc, char **argv)
{
    int i = 0;
    size_t len = 0;
    char* javaCommand = NULL;
    char* dashDstr = "-Dsun.java.command=";

    if (what == NULL) {
        return;
    }

    // ★ Step 1: 计算需要的内存大小
    len = JLI_StrLen(what);
    for (i = 0; i < argc; i++) {
        len += JLI_StrLen(argv[i]) + 1;  // ★ +1 for space
    }

    // ★ Step 2: 分配内存
    javaCommand = (char*) JLI_MemAlloc(len + JLI_StrLen(dashDstr) + 1);

    // ★ Step 3: 构建字符串
    *javaCommand = '\0';
    JLI_StrCat(javaCommand, dashDstr);  // ★ "-Dsun.java.command="
    JLI_StrCat(javaCommand, what);      // ★ "com.example.Main"

    // ★ Step 4: 添加参数
    for (i = 0; i < argc; i++) {
        JLI_StrCat(javaCommand, " ");
        JLI_StrCat(javaCommand, argv[i]);  // ★ " arg1 arg2"
    }

    // ★ Step 5: 添加到 options 数组
    AddOption(javaCommand, NULL);
}
```

### 2.8.2 设计决策

**为什么需要 sun.java.command 属性？**

```
用途：

1. **诊断工具**
   - jcmd、jmap、jstack 等工具需要知道主类名
   - 示例：jcmd <pid> VM.command_line

2. **监控工具**
   - JMX 可以读取这个属性
   - 示例：ManagementFactory.getRuntimeMXBean().getName()

3. **日志记录**
   - JVM 日志可以包含完整命令行
   - 示例：hs_err_pid*.log 会记录这个属性

示例值：
  -Dsun.java.command=com.example.Main arg1 arg2

注意事项：
  - 不是 Java 标准 API（Sun 私有属性）
  - 可能包含敏感信息（密码等）
  - 空格分隔，无法区分嵌入空格的参数
```

---

## 2.9 SetJavaLauncherProp() - 设置 sun.java.launcher 属性 ⭐

**源码位置**: `java.c:1964-1967`

**解决什么问题**：标记 JVM 是由标准启动器启动的。

### 2.9.1 完整源码

```cpp
// java.c:1964-1967
void
SetJavaLauncherProp() {
  AddOption("-Dsun.java.launcher=SUN_STANDARD", NULL);
}
```

### 2.9.2 设计决策

**为什么需要这个属性？**

```
用途：

1. **区分启动方式**
   - SUN_STANDARD：标准 java 命令启动
   - 其他值：嵌入 JVM（如浏览器插件、数据库）

2. **兼容性检查**
   - 某些代码依赖标准启动器的行为
   - 示例：类加载器初始化顺序

3. **诊断工具**
   - 工具可以根据这个属性判断启动方式
   - 示例：JConsole 可以显示不同的界面

为什么是 "SUN_STANDARD"？
  - 历史原因：最初是 Sun JDK
  - 现在 OpenJDK 也使用这个值
  - 兼容性：不修改以避免破坏现有代码
```

---

## 2.10 JVMInit() - JVM 初始化（Linux 平台）⭐⭐⭐

**源码位置**: `java_md_solinux.c:829-837`（平台相关）

**解决什么问题**：平台相关的 JVM 初始化入口，Linux 上只是简单地调用 ContinueInNewThread()。

### 2.10.1 完整源码（Linux 版本）

```cpp
// java_md_solinux.c:829-837
int
JVMInit(InvocationFunctions* ifn, jlong threadStackSize,
        int argc, char **argv,
        int mode, char *what, int ret)
{
    ShowSplashScreen();  // ★ 显示启动画面（如果有）
    
    return ContinueInNewThread(ifn, threadStackSize, argc, argv, mode, what, ret);
}
```

### 2.10.2 设计决策

**为什么需要平台相关的 JVMInit()？**

```
不同平台的差异：

Linux/Unix:
  - 简单：只需调用 ContinueInNewThread()
  - ShowSplashScreen() 显示启动画面

macOS:
  - 需要初始化 Cocoa 框架
  - 需要设置应用程序菜单
  - 需要处理 Dock 图标

Windows:
  - 需要初始化 COM
  - 需要设置控制台窗口
  - 需要处理 Windows 消息循环

设计模式：
  - 平台无关代码：java.c
  - 平台相关代码：java_md.c / java_md_solinux.c
  - JVMInit() 是平台相关代码的入口

好处：
  - java.c 不需要处理平台差异
  - 每个平台有自己的初始化逻辑
  - 易于维护和扩展
```

---

## 2.11 ContinueInNewThread() - 在新线程中继续 ⭐⭐⭐⭐

**源码位置**: `java.c:2418-2456`

**解决什么问题**：创建 JavaMain 线程，传递参数，等待线程结束。

### 2.11.1 完整源码

```cpp
// java.c:2418-2456
int
ContinueInNewThread(InvocationFunctions* ifn, jlong threadStackSize,
                    int argc, char **argv,
                    int mode, char *what, int ret)
{
    // ★ Step 1: 如果用户没有指定线程栈大小，询问 JVM
    if (threadStackSize == 0) {
      struct JDK1_1InitArgs args1_1;
      memset((void*)&args1_1, 0, sizeof(args1_1));
      args1_1.version = JNI_VERSION_1_1;
      ifn->GetDefaultJavaVMInitArgs(&args1_1);  // ★ 获取 JVM 默认栈大小
      if (args1_1.javaStackSize > 0) {
         threadStackSize = args1_1.javaStackSize;
      }
    }

    // ★ Step 2: 创建 JavaMain 线程
    {
      JavaMainArgs args;
      int rslt;
      
      // ★ 2.1 准备参数
      args.argc = argc;
      args.argv = argv;
      args.mode = mode;
      args.what = what;
      args.ifn = *ifn;
      
      // ★ 2.2 创建新线程并执行 JavaMain()
      rslt = CallJavaMainInNewThread(threadStackSize, (void*)&args);
      
      // ★ 2.3 返回结果
      return (ret != 0) ? ret : rslt;
    }
}
```

### 2.11.2 逐行注释

| 代码段 | 深度分析 |
|--------|----------|
| `ifn->GetDefaultJavaVMInitArgs(&args1_1)` | **获取 JVM 默认栈大小**。虽然 HotSpot 不再支持 JNI 1.1，但这个调用仍然有效，用于获取默认线程栈大小 |
| `args.argc = argc; args.argv = argv; ...` | **打包参数**。将所有参数打包到 JavaMainArgs 结构体，传递给新线程 |
| `CallJavaMainInNewThread(threadStackSize, (void*)&args)` | **创建新线程**。平台相关函数，创建一个栈大小为 threadStackSize 的线程，执行 JavaMain() 函数 |

### 2.11.3 设计决策

**为什么不直接调用 JavaMain()？**

```
多线程设计的必要性：

单线程方案：
  main() {
      JLI_Launch(...) {
          JavaMain(...) {
              main() 方法执行
              如果有其他线程在运行？
              JVM 何时销毁？
          }
      }
  }

问题：
  1. main() 返回后，其他用户线程可能还在运行
  2. 无法等待其他线程结束
  3. 无法正确调用 DestroyJavaVM()

多线程方案：
  main() {
      JLI_Launch(...) {
          JVMInit(...) {
              ContinueInNewThread(...) {
                  创建 JavaMain 线程
                  等待 JavaMain 线程结束
              }
          }
      }
  }
  
  JavaMain 线程 {
      InitializeJVM()
      main() 方法执行
      DetachCurrentThread()  ← 关键！
      return
  }
  
  主线程 {
      等待 JavaMain 线程结束
      DestroyJavaVM()  ← 等待所有非守护线程结束
  }

为什么需要 DetachCurrentThread？
  - JavaMain 线程是 Java 线程（已 Attach）
  - DestroyJavaVM() 会等待所有 Java 线程结束
  - JavaMain 线程必须 Detach，否则 DestroyJavaVM() 会永远等待
  
这是一个精心设计的线程生命周期管理。
```

---

## 2.12 LoadMainClass() - 加载主类 ⭐⭐⭐⭐⭐

**源码位置**: `java.c:1703-1731`

**解决什么问题**：通过 JNI 调用 Java 类 `sun.launcher.LauncherHelper.checkAndLoadMain()` 加载主类。

### 2.12.1 完整源码

```cpp
// java.c:1703-1731
static jclass
LoadMainClass(JNIEnv *env, int mode, char *name)
{
    jmethodID mid;
    jstring str;
    jobject result;
    jlong start = 0, end = 0;
    jclass cls = GetLauncherHelperClass(env);  // ★ 加载 LauncherHelper 类
    NULL_CHECK0(cls);
    
    if (JLI_IsTraceLauncher()) {
        start = CounterGet();
    }
    
    // ★ Step 1: 获取 checkAndLoadMain 方法
    NULL_CHECK0(mid = (*env)->GetStaticMethodID(env, cls,
                "checkAndLoadMain",
                "(ZILjava/lang/String;)Ljava/lang/Class;"));
    
    // ★ Step 2: 将主类名转换为 Java String
    NULL_CHECK0(str = NewPlatformString(env, name));
    
    // ★ Step 3: 调用 LauncherHelper.checkAndLoadMain()
    NULL_CHECK0(result = (*env)->CallStaticObjectMethod(env, cls, mid,
                                                        USE_STDERR, mode, str));
    
    if (JLI_IsTraceLauncher()) {
        end = CounterGet();
        printf("%ld micro seconds to load main class\n",
               (long)(jint)Counter2Micros(end-start));
        printf("----%s----\n", JLDEBUG_ENV_ENTRY);
    }

    return (jclass)result;
}
```

### 2.12.2 设计决策

**为什么用 Java 代码加载主类？**

```
Java 代码的优势：

C 代码的局限：
  1. 类加载逻辑复杂
     - 模块化系统（JPMS）
     - 类加载器委托
     - 安全性检查

  2. 错误处理复杂
     - ClassNotFoundException
     - NoClassDefFoundError
     - UnsatisfiedLinkError

  3. 需要访问 Java API
     - Class.forName()
     - ClassLoader.loadClass()
     - ModuleLayer.boot()

Java 代码的优势：
  1. 复用 Java 标准库
     - java.lang.ClassLoader
     - java.lang.ModuleLayer

  2. 易于维护
     - 类加载逻辑在 Java 中
     - C 代码保持简单

  3. 易于扩展
     - 模块化系统（JDK 9+）
     - 动态加载

LauncherHelper.checkAndLoadMain() 的功能：
  1. 检查主类是否存在
  2. 检查 main() 方法签名
  3. 处理 -jar 模式（从 JAR 加载）
  4. 处理模块化应用
  5. 设置上下文类加载器
```

---

## 2.13 GetApplicationClass() - 获取应用类 ⭐⭐

**源码位置**: `java.c:1733-1747`

**解决什么问题**：获取真正的应用类（可能与主类不同）。

### 2.13.1 完整源码

```cpp
// java.c:1733-1747
static jclass
GetApplicationClass(JNIEnv *env)
{
    jmethodID mid;
    jclass appClass;
    jclass cls = GetLauncherHelperClass(env);
    NULL_CHECK0(cls);
    
    NULL_CHECK0(mid = (*env)->GetStaticMethodID(env, cls,
                "getApplicationClass",
                "()Ljava/lang/Class;"));

    appClass = (*env)->CallStaticObjectMethod(env, cls, mid);
    CHECK_EXCEPTION_RETURN_VALUE(0);
    
    return appClass;
}
```

### 2.13.2 设计决策

**为什么主类和应用类可能不同？**

```
主类 vs 应用类：

主类（mainClass）：
  - main() 方法所在的类
  - 必须有 public static void main(String[] args)

应用类（appClass）：
  - 真正的应用入口类
  - 可能与 mainClass 不同

示例场景：

1. JavaFX 应用
   mainClass: javafx.application.Application
   appClass: com.example.MyApp

2. 模块化应用
   mainClass: 模块描述符中的主类
   appClass: 实际的应用类

3. 框架 Launcher
   mainClass: com.framework.Launcher
   appClass: com.example.Main

为什么需要区分？
  - PostJVMInit() 需要知道真正的应用类
  - GUI 应用需要设置应用程序名（macOS）
  - 某些工具需要显示正确的应用名

大多数情况下：
  mainClass == appClass
```

---

## 2.14 CreateApplicationArgs() - 创建应用参数数组 ⭐

**源码位置**: `java_md_common.c:367-371`（平台相关，Linux 版本）

**解决什么问题**：将 C 的 `char** argv` 转换为 Java 的 `String[] args`。

### 2.14.1 完整源码（Linux 版本）

```cpp
// java_md_common.c:367-371
jobjectArray
CreateApplicationArgs(JNIEnv *env, char **strv, int argc)
{
    return NewPlatformStringArray(env, strv, argc);
}
```

**Windows 版本**（复杂得多，需要处理参数分割）：

```cpp
// java_md.c:981-... (Windows 版本，简化版)
jobjectArray
CreateApplicationArgs(JNIEnv *env, char **strv, int argc)
{
    // Windows 需要处理参数分割
    // 因为 Windows 的命令行是一个字符串
    // 需要按照 Shell 规则分割
    // ...
    return NewPlatformStringArray(env, strv, argc);
}
```

### 2.14.2 设计决策

**为什么 Linux 版本这么简单？**

```
Linux vs Windows 的差异：

Linux：
  - main(argc, argv) 的 argv 已经被 Shell 分割
  - 每个参数都是独立的字符串
  - 直接转换为 Java String[] 即可

Windows：
  - WinMain 的命令行是一个字符串
  - 需要按照 Shell 规则分割
  - 需要处理引号、转义字符

示例：
  命令行：java MyApp "arg with space" arg2

Linux:
  argc = 3
  argv[0] = "java"
  argv[1] = "MyApp"
  argv[2] = "arg with space"
  argv[3] = "arg2"
  
Windows:
  命令行字符串：'java MyApp "arg with space" arg2'
  需要解析：分割成 4 个参数

设计优势：
  - 平台相关代码处理差异
  - java.c 保持平台无关
```

---

## 2.15 ParseArguments() - 解析命令行参数 ⭐⭐⭐⭐

**源码位置**: `java.c:1365-1760`

**解决什么问题**：解析命令行参数，区分 JVM 参数、启动器参数和应用参数。

### 2.3.1 参数分类

```
命令行参数的分类：

1. JVM 参数（传递给 JVM）
   - 标准选项：-Xms, -Xmx, -cp, -jar
   - 扩展选项：-XX:+UseG1GC
   - 系统属性：-Dproperty=value

2. 启动器参数（启动器处理）
   - -version, -showversion
   - -?, -help
   - -X

3. 应用参数（传递给 main 方法）
   - 主类名或 JAR 文件名
   - main() 的 args[] 参数
```

### 2.3.2 核心逻辑（简化）

```cpp
// java.c:1365-1760 (简化版)
jboolean ParseArguments(int *pargc, char ***pargv,
                        int *pmode, char **pwhat,
                        int *pret, const char *jrepath) {
    int argc = *pargc;
    char **argv = *pargv;
    
    // 逐个参数解析
    for (i = 0; i < argc; i++) {
        char *arg = argv[i];
        
        // ★ 1. 启动器参数
        if (JLI_StrCCmp(arg, "-version") == 0) {
            printVersion = JNI_TRUE;
            return JNI_TRUE;
        }
        
        if (JLI_StrCCmp(arg, "-showversion") == 0) {
            showVersion = JNI_TRUE;
            continue;
        }
        
        // ★ 2. JVM 参数：-Xms, -Xmx
        if (arg[0] == '-' && arg[1] == 'X') {
            AddOption(arg, NULL);
            continue;
        }
        
        // ★ 3. JVM 参数：-XX:...
        if (JLI_StrCCmp(arg, "-XX:") == 0) {
            AddOption(arg, NULL);
            continue;
        }
        
        // ★ 4. 系统属性：-D...
        if (JLI_StrCCmp(arg, "-D") == 0) {
            AddOption(arg, NULL);
            continue;
        }
        
        // ★ 5. Classpath：-cp 或 -classpath
        if (JLI_StrCCmp(arg, "-cp") == 0 ||
            JLI_StrCCmp(arg, "-classpath") == 0) {
            SetClassPath(argv[++i]);
            continue;
        }
        
        // ★ 6. JAR 模式：-jar
        if (JLI_StrCCmp(arg, "-jar") == 0) {
            *pmode = LM_JAR;
            *pwhat = argv[++i];  // 下一个参数是 JAR 文件名
            return JNI_TRUE;
        }
        
        // ★ 7. 主类名（第一个非选项参数）
        if (arg[0] != '-') {
            *pmode = LM_CLASS;
            *pwhat = arg;
            return JNI_TRUE;
        }
    }
    
    return JNI_TRUE;
}
```

### 2.3.3 设计决策

**为什么参数解析这么复杂？**

```
复杂性来源：

1. **参数类型多样**
   - JVM 参数、启动器参数、应用参数
   - 需要正确区分和处理

2. **参数依赖关系**
   - -cp 需要一个参数
   - -jar 需要一个参数
   - 参数可能依赖顺序

3. **特殊情况**
   - -cp 支持通配符（lib/*）
   - -jar 模式下 classpath 被覆盖
   - 某些参数互斥

4. **兼容性**
   - 支持旧版本的参数
   - 支持废弃的参数（打印警告）
   - 跨平台差异

设计原则：
  - 每个参数只解析一次
  - 立即处理启动器参数
  - 收集 JVM 参数到数组
  - 应用参数留在 argv 中
```

---

## 2.4 InitializeJVM() - 初始化 JVM ⭐⭐⭐⭐⭐

**源码位置**: `java.c:867-888`

**解决什么问题**：调用 JNI_CreateJavaVM 创建 JVM 实例。

### 2.4.1 完整源码

```cpp
// java.c:867-888
static jboolean InitializeJVM(JavaVM **pvm, JNIEnv **penv,
                              InvocationFunctions *ifn) {
    JavaVMInitArgs args;
    jint r;
    
    // ★ Step 1: 准备 JavaVMInitArgs
    memset(&args, 0, sizeof(args));
    args.version  = JNI_VERSION_1_8;
    args.nOptions = numOptions;
    args.options  = options;
    args.ignoreUnrecognized = JNI_FALSE;
    
    // ★ Step 2: 调用 JNI_CreateJavaVM
    r = ifn->CreateJavaVM(pvm, (void **)penv, &args);
    
    // ★ Step 3: 检查结果
    return r == JNI_OK;
}
```

### 2.4.2 逐行注释

| 行号 | 代码 | 深度分析 |
|------|------|----------|
| 873 | `memset(&args, 0, sizeof(args))` | **清零结构体**。避免未初始化的字段导致问题 |
| 874 | `args.version = JNI_VERSION_1_8` | **设置 JNI 版本**。JVM 会根据版本提供相应功能 |
| 875 | `args.nOptions = numOptions` | **设置选项数量**。JVM 会读取这么多选项 |
| 876 | `args.options = options` | **设置选项数组**。指向全局 options 数组 |
| 877 | `args.ignoreUnrecognized = JNI_FALSE` | **不忽略无法识别的选项**。遇到无法识别的选项会返回错误 |
| 880 | `r = ifn->CreateJavaVM(pvm, (void **)penv, &args)` | **调用 JNI_CreateJavaVM**。这是 JVM 的真正初始化 |

### 2.4.3 设计决策

**为什么 ignoreUnrecognized = JNI_FALSE？**

```
严格模式 vs 宽容模式：

JNI_FALSE（严格模式）：
  - 遇到无法识别的选项立即返回错误
  - 避免拼写错误的选项被忽略
  - 调试友好

JNI_TRUE（宽容模式）：
  - 忽略无法识别的选项
  - 继续启动
  - 可能隐藏配置错误

JVM 的选择：JNI_FALSE
  - 严格模式
  - 帮助用户发现拼写错误
  - 例如：-XX:+UseG1GC 写成 -XX:+Use1GC 会被拒绝

好处：
  java -XX:+UseG1GCx MyApp
  Error: Could not find or load main class MyApp
  Caused by: java.lang.UnsupportedClassVersionError...
  
  ↑ 拒绝启动，告诉用户选项错误
```

---

## 2.5 JavaMain() - 执行主类 ⭐⭐⭐⭐⭐

**源码位置**: `java.c:486-618`

**解决什么问题**：加载主类，找到 main 方法，调用 main 方法。

### 2.5.1 完整源码（简化）

```cpp
// java.c:486-618 (简化版)
int JavaMain(void* _args) {
    JavaMainArgs *args = (JavaMainArgs *)_args;
    int argc = args->argc;
    char **argv = args->argv;
    int mode = args->mode;
    char *what = args->what;
    InvocationFunctions ifn = args->ifn;
    
    JavaVM *vm = 0;
    JNIEnv *env = 0;
    jclass mainClass = NULL;
    jclass appClass = NULL;
    jmethodID mainID;
    jobjectArray mainArgs;
    int ret = 0;
    
    // ★ Step 1: 初始化 JVM
    if (!InitializeJVM(&vm, &env, &ifn)) {
        JLI_ReportErrorMessage(JVM_ERROR1);
        exit(1);
    }
    
    // ★ Step 2: 加载主类
    mainClass = LoadMainClass(env, mode, what);
    CHECK_EXCEPTION_NULL_LEAVE(mainClass);
    
    // ★ Step 3: 获取应用类（可能是不同的类）
    appClass = GetApplicationClass(env);
    CHECK_EXCEPTION_NULL_LEAVE(appClass);
    
    // ★ Step 4: 找到 main 方法
    mainID = (*env)->GetStaticMethodID(env, mainClass, "main",
                                       "([Ljava/lang/String;)V");
    CHECK_EXCEPTION_NULL_LEAVE(mainID);
    
    // ★ Step 5: 准备 main 方法的参数
    mainArgs = CreateApplicationArgs(env, argv, argc);
    CHECK_EXCEPTION_NULL_LEAVE(mainArgs);
    
    // ★ Step 6: 调用 main 方法
    (*env)->CallStaticVoidMethod(env, mainClass, mainID, mainArgs);
    
    // ★ Step 7: 检查异常
    if ((*env)->ExceptionOccurred(env)) {
        JLI_ReportExceptionDescription(env);
        ret = 1;
    }
    
    // ★ Step 8: 清理
    LEAVE();
}
```

### 2.5.2 设计决策

**为什么 mainClass 和 appClass 可能不同？**

```
mainClass vs appClass：

mainClass：
  - main() 方法所在的类
  - 例如：com.example.Main

appClass：
  - 应用的主类（可能不同）
  - 例如：com.example.Launcher（如果是通过 Launcher 启动）

为什么可能不同？
  - JavaFX 应用：main() 在 Application 子类
  - 模块化应用：main() 可能在模块描述符指定的类
  - 某些框架：main() 在框架的 Launcher 类

实际使用：
  - 大多数情况下，mainClass == appClass
  - 但某些特殊场景需要区分
```

**LEAVE() 宏做了什么？**

```cpp
// java.c:451-461
#define LEAVE() \
    do { \
        if ((*vm)->DetachCurrentThread(vm) != JNI_OK) { \
            JLI_ReportErrorMessage(JVM_ERROR2); \
            ret = 1; \
        } \
        if (JNI_TRUE) { \
            (*vm)->DestroyJavaVM(vm); \
            return ret; \
        } \
    } while (JNI_FALSE)
```

**设计目的**：

```
LEAVE() 宏的三步：

1. DetachCurrentThread()
   - 分离当前线程
   - 告诉 JVM："这个线程不再是 Java 线程"
   - 允许 JVM 在其他线程回收资源

2. DestroyJavaVM()
   - 销毁 JVM
   - 等待所有非守护线程结束
   - 清理所有资源

3. return ret
   - 返回退出码

为什么需要 DetachCurrentThread？
  - JavaMain 线程是 Java 线程（已 Attach）
  - 如果不 Detach，DestroyJavaVM 会失败
  - 必须先 Detach，再 Destroy

这是一个精心设计的生命周期管理。
```

---

## 2.6 调用链全景图

```
JLI_Launch()
├── SelectVersion()
│   └── JLI_ParseManifest() [如果 -jar 模式]
│       └── 提取 Main-Class
│
├── CreateExecutionEnvironment()
│   ├── 查找 JRE 路径
│   ├── 查找 libjvm.so 路径
│   └── 读取 jvm.cfg
│
├── LoadJavaVM()
│   ├── dlopen("libjvm.so")
│   ├── dlsym("JNI_CreateJavaVM")
│   └── 填充 InvocationFunctions
│
├── ParseArguments()
│   ├── 解析 -version, -showversion
│   ├── 解析 -Xms, -Xmx, -XX:...
│   ├── 解析 -cp, -jar
│   └── 填充 JavaVMOption 数组
│
├── SetClassPath()
│   └── AddOption("-Djava.class.path=...")
│
├── SetJavaCommandLineProp()
│   └── AddOption("-Dsun.java.command=...")
│
└── JVMInit()
    ├── ContinueInNewThread()
    │   └── 创建新线程
    │       └── JavaMain()
    │           ├── InitializeJVM()
    │           │   └── JNI_CreateJavaVM()
    │           │       └── Threads::create_vm() [HotSpot 内部]
    │           │
    │           ├── LoadMainClass()
    │           │   └── FindClass("com/example/Main")
    │           │
    │           ├── GetStaticMethodID("main", "([Ljava/lang/String;)V")
    │           │
    │           ├── CreateApplicationArgs()
    │           │   └── 构造 String[] args
    │           │
    │           ├── CallStaticVoidMethod(main, args)
    │           │   └── 执行 Java main() 方法
    │           │
    │           └── LEAVE()
    │               ├── DetachCurrentThread()
    │               └── DestroyJavaVM()
    │
    └── 等待 JavaMain 线程结束
```

---

## 2.7 总结

### 2.7.1 核心流程

```
JVM 启动的 8 个关键步骤：

1. **解析 JAR manifest**：提取 Main-Class
2. **创建执行环境**：找到 JRE 和 libjvm.so
3. **加载 JVM**：dlopen + dlsym
4. **解析参数**：区分 JVM 参数和应用参数
5. **初始化 JVM**：JNI_CreateJavaVM
6. **加载主类**：FindClass
7. **调用 main**：CallStaticVoidMethod
8. **销毁 JVM**：DestroyJavaVM

每个步骤都有明确的职责和错误处理。
```

### 2.7.2 设计模式

1. **动态加载模式**：dlopen/dlsym 加载 libjvm.so
2. **参数收集模式**：JavaVMOption 数组收集所有参数
3. **多线程模式**：主线程等待 JavaMain 线程
4. **生命周期管理**：DetachCurrentThread + DestroyJavaVM

### 2.7.3 关键设计决策

| 决策 | 选择 | 理由 |
|------|------|------|
| 动态加载 vs 静态链接 | 动态加载 | 代码复用、版本选择、灵活性 |
| RTLD_NOW vs RTLD_LAZY | RTLD_NOW | 立即发现符号错误 |
| ignoreUnrecognized | JNI_FALSE | 严格模式，帮助发现配置错误 |
| 多线程 vs 单线程 | 多线程 | 正确处理线程生命周期 |
