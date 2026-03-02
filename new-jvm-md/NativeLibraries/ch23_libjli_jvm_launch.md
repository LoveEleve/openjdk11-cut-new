# Ch23: libjli.so — 从 `java` 命令到 CreateJavaVM

> 基于 OpenJDK 11 源码 | libjli 启动链路深度分析
> 模块 D（JVM 启动器）| PerfMa 面试价值：⭐⭐⭐⭐⭐

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **Ch23: libjli.so — 从 `java` 命令到 CreateJavaVM**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 23.1 总览：从用户敲下 `java` 到 JVM 诞生

### 核心问题

当你在终端执行 `java -Xms8g -Xmx8g -XX:+UseG1GC -cp /app Main` 时：
- **谁是 `java` 命令？** → 一个极小的 C 程序（`main.c`），只调用 `JLI_Launch()`
- **谁负责找到 libjvm.so 并加载？** → **libjli.so**（Java Launcher Infrastructure）
- **参数怎么传给 HotSpot？** → `JavaVMOption[]` 数组 → `JNI_CreateJavaVM()`
- **为什么要在新线程里启动 JVM？** → 避免 primordial thread 的栈大小限制问题

### 全景架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                    JVM 启动完整链路                                   │
│                                                                     │
│  用户命令                                                            │
│  $ java -Xms8g -Xmx8g -XX:+UseG1GC -cp /app Main                  │
│                         │                                           │
│                         ▼                                           │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ main.c  →  main(argc, argv)                                │    │
│  │            │                                                │    │
│  │            ├── 合并 JDK_JAVA_OPTIONS 环境变量                │    │
│  │            ├── 展开 @argfile 参数文件                        │    │
│  │            └── JLI_Launch(argc, argv, ...)                  │    │
│  └────────────────────────┬────────────────────────────────────┘    │
│                           ▼                                         │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ libjli.so  (java.c + java_md_solinux.c)                    │    │
│  │                                                             │    │
│  │ JLI_Launch():                                               │    │
│  │  ① SelectVersion()        — JAR manifest 版本检查           │    │
│  │  ② CreateExecutionEnvironment()                             │    │
│  │     ├── SetExecname()     — /proc/self/exe 获取路径         │    │
│  │     ├── GetJREPath()      — 探测 jre 目录                   │    │
│  │     ├── ReadKnownVMs()    — 解析 jvm.cfg → -server          │    │
│  │     ├── GetJVMPath()      — 拼接 libjvm.so 路径             │    │
│  │     └── RequiresSetenv()  — 检查是否需要 reexec             │    │
│  │  ③ LoadJavaVM()                                             │    │
│  │     ├── dlopen("xxx/lib/server/libjvm.so")                  │    │
│  │     ├── dlsym("JNI_CreateJavaVM")                           │    │
│  │     ├── dlsym("JNI_GetDefaultJavaVMInitArgs")               │    │
│  │     └── dlsym("JNI_GetCreatedJavaVMs")                      │    │
│  │  ④ ParseArguments()       — 解析命令行 → options[]          │    │
│  │  ⑤ JVMInit()                                                │    │
│  │     └── ContinueInNewThread()                               │    │
│  │         └── CallJavaMainInNewThread()                       │    │
│  │             └── pthread_create(ThreadJavaMain)              │    │
│  └────────────────────────┬────────────────────────────────────┘    │
│                           ▼  (新线程)                               │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ JavaMain():                                                 │    │
│  │  ① InitializeJVM()   → ifn->CreateJavaVM()                 │    │
│  │                          → JNI_CreateJavaVM() [HotSpot]     │    │
│  │  ② LoadMainClass()   → LauncherHelper.checkAndLoadMain()    │    │
│  │  ③ GetStaticMethodID → main(String[])                       │    │
│  │  ④ CallStaticVoidMethod → 执行 Java main 方法               │    │
│  │  ⑤ DetachCurrentThread                                      │    │
│  │  ⑥ DestroyJavaVM     → 等待所有非守护线程退出                 │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
```

### 源码文件概览

| 文件 | 大小 | 职责 |
|------|------|------|
| `launcher/main.c` | 215 行 | C `main()` 入口，组装参数后调用 `JLI_Launch()` |
| `libjli/java.c` | 2497 行 | **核心**：JLI_Launch + JavaMain + ParseArguments + InitializeJVM |
| `libjli/java.h` | 279 行 | InvocationFunctions / LaunchMode / JavaMainArgs 定义 |
| `libjli/java_md_solinux.c` | 880 行 | Linux 平台：CreateExecutionEnvironment / LoadJavaVM / CallJavaMainInNewThread |
| `libjli/java_md_common.c` | 372 行 | Unix 公共：GetApplicationHome / SetExecname / FindExecName |
| `libjli/args.c` | — | @argfile 参数文件展开 |
| `libjli/parse_manifest.c` | — | JAR manifest 解析 |
| `libjli/wildcard.c` | — | classpath 通配符展开 |

---

## 23.2 Phase 1: main() — 极简入口

**文件**：`src/java.base/share/native/launcher/main.c`

```c
JNIEXPORT int
main(int argc, char **argv)
{
    int margc;
    char** margv;
    int jargc;
    char** jargv;
    const jboolean const_javaw = JNI_FALSE;

    // 1. 编译时预定义参数（通常为空）
    jargc = (sizeof(const_jargs) / sizeof(char *)) > 1
        ? sizeof(const_jargs) / sizeof(char *) : 0;
    jargv = (char **) const_jargs;

    JLI_InitArgProcessing(jargc > 0, const_disable_argfile);

    // 2. 组装命令行参数（Unix 路径）
    JLI_List args = JLI_List_new(argc + 1);
    JLI_List_add(args, JLI_StringDup(argv[0]));

    // 3. ★ 合并 JDK_JAVA_OPTIONS 环境变量
    JLI_AddArgsFromEnvVar(args, JDK_JAVA_OPTIONS);

    // 4. 展开 @argfile（参数文件）
    for (i = 1; i < argc; i++) {
        JLI_List argsInFile = JLI_PreprocessArg(argv[i], JNI_TRUE);
        if (argsInFile == NULL)
            JLI_List_add(args, JLI_StringDup(argv[i]));
        else { /* 展开文件中的参数 */ }
    }

    margc = args->size;
    margv = args->elements;

    // 5. ★★★ 进入 libjli 核心
    return JLI_Launch(margc, margv,
                   jargc, (const char**) jargv,
                   0, NULL,
                   VERSION_STRING, DOT_VERSION,
                   const_progname, const_launcher,
                   jargc > 0, const_cpwildcard, const_javaw, 0);
}
```

**关键设计**：
- `main.c` 极其简单（215 行），**唯一职责**就是组装参数然后调用 `JLI_Launch()`
- 这个文件会被 javac、javap、jstack 等所有工具复用编译（通过不同的 `const_jargs` 预定义）
- `JDK_JAVA_OPTIONS` 环境变量在 main 就合并进来，**对所有 java 命令生效**
- `@argfile` 支持将长参数列表放在文件中（避免命令行长度限制）

---

## 23.3 Phase 2: JLI_Launch() — 启动器主控流程

**文件**：`java.c` 第 254-375 行

```
JLI_Launch(argc, argv, jargc, jargv, appclassc, appclassv,
           fullversion, dotversion, pname, lname,
           javaargs, cpwildcard, javaw, ergo):
│
├── ① 保存全局状态:
│   _program_name = pname;      // "java"
│   _launcher_name = lname;     // "java"
│   _is_java_args = javaargs;   // JNI_FALSE (非 javac 等工具)
│   _wc_enabled = cpwildcard;   // JNI_TRUE (启用通配符展开)
│
├── ② InitLauncher(javaw):
│   JLI_SetTraceLauncher();     // 检查 _JAVA_LAUNCHER_DEBUG 环境变量
│
├── ③ DumpState():  // 调试模式下打印启动器状态
│
├── ④ SelectVersion(argc, argv, &main_class):
│   → 检查 JAR manifest 中的版本信息（JDK 9+ 已禁止指定其他 JRE 版本）
│   → 如果是 -jar 模式，从 manifest 提取 Main-Class
│
├── ⑤ ★ CreateExecutionEnvironment():  → 详见 23.4
│   → 探测 jrepath / jvmpath / jvmcfg
│   → 如果需要，reexec 自己（修正 LD_LIBRARY_PATH）
│
├── ⑥ SetJvmEnvironment():
│   → 扫描 -XX:NativeMemoryTracking=xxx
│   → 设置 NMT_LEVEL_<pid>=xxx 环境变量
│   → JVM 启动后会读取这个环境变量
│
├── ⑦ ★ LoadJavaVM(jvmpath, &ifn):  → 详见 23.5
│   → dlopen(libjvm.so) + dlsym(3 个函数)
│
├── ⑧ 环境变量 CLASSPATH 处理:
│   char* cpath = getenv("CLASSPATH");
│   if (cpath != NULL) SetClassPath(cpath);
│   → "-Djava.class.path=xxx" 添加到 options[]
│
├── ⑨ ★ ParseArguments():  → 详见 23.6
│   → 解析所有命令行参数
│   → 确定 mode (LM_CLASS/LM_JAR/LM_MODULE/LM_SOURCE)
│   → 确定 what (主类名/jar 名/模块名)
│   → 构建 options[] 数组
│
├── ⑩ 设置伪属性:
│   SetJavaCommandLineProp(what, argc, argv);
│   → "-Dsun.java.command=Main arg1 arg2"
│   SetJavaLauncherProp();
│   → "-Dsun.java.launcher=SUN_STANDARD"
│   SetJavaLauncherPlatformProps();
│   → "-Dsun.java.launcher.pid=<pid>"  (Linux only)
│
└── ⑪ ★ JVMInit(&ifn, threadStackSize, argc, argv, mode, what, ret):
    → 详见 23.7
```

---

## 23.4 Phase 3: CreateExecutionEnvironment() — 路径探测与环境准备

**文件**：`java_md_solinux.c` 第 251-360 行

这是 Linux 平台上最复杂的函数之一，负责**找到 JRE 和 libjvm.so 的精确路径**。

```
CreateExecutionEnvironment(&argc, &argv, jrepath, jvmpath, jvmcfg):
│
├── ① SetExecname(*pargv):
│   → Linux: readlink("/proc/self/exe")
│   → 结果: "/path/to/jdk/bin/java"
│   → 保存到全局变量 execname（后续 reexec 用）
│
├── ② GetJREPath(jrepath):
│   → GetApplicationHome(path):
│     → 从 execname 截取 "/bin/" 之前的部分
│     → 例: "/path/to/jdk/bin/java" → "/path/to/jdk"
│   → 验证 <jrepath>/lib/libjava.so 存在
│   → 结果: jrepath = "/path/to/jdk"
│
├── ③ 拼接 jvmcfg 路径:
│   JLI_Snprintf(jvmcfg, "%s/lib/jvm.cfg", jrepath);
│   → "/path/to/jdk/lib/jvm.cfg"
│
├── ④ ★ ReadKnownVMs(jvmcfg):
│   → 解析 jvm.cfg 文件 → 填充 knownVMs[] 数组
│   → 详见 23.4.1
│
├── ⑤ CheckJvmType(&argc, &argv):
│   → 扫描命令行找 -server / -client
│   → 如果没有指定，取 knownVMs[0]（默认 server）
│   → 从 argv 中移除 VM 类型参数
│   → 结果: jvmtype = "server"
│
├── ⑥ GetJVMPath(jrepath, jvmtype, jvmpath):
│   → JLI_Snprintf(jvmpath, "%s/lib/%s/libjvm.so", jrepath, jvmtype)
│   → 例: "/path/to/jdk/lib/server/libjvm.so"
│   → stat() 验证文件存在
│
└── ⑦ RequiresSetenv(jvmpath):  → 是否需要 reexec
    → 详见 23.4.2
```

### 23.4.1 jvm.cfg 解析

**文件内容示例**（`<jdk>/lib/jvm.cfg`）：

```
# JVM 配置文件
-server KNOWN
-client IGNORE
```

**解析逻辑**（`java.c` 第 1807-1916 行）：

```
ReadKnownVMs(jvmCfgName):
│
├── fopen(jvmCfgName, "r")
│
├── 逐行读取:
│   ├── '#' 开头 → 注释，跳过
│   ├── '-' 开头 → VM 定义行
│   │   ├── "-server KNOWN"      → knownVMs[0] = {name="-server", flag=VM_KNOWN}
│   │   ├── "-client IGNORE"     → knownVMs[1] = {name="-client", flag=VM_IGNORE}
│   │   ├── "-XXX ALIASED_TO -server" → 别名
│   │   ├── "-XXX WARN"         → 使用但警告
│   │   └── "-XXX ERROR"        → 报错退出
│   └── 其他 → 警告
│
└── 返回 knownVMsCount
```

**关键**：`knownVMs[0]` 是默认 VM 类型。在标准安装中，`-server` 排第一位，所以默认使用 Server VM。

### 23.4.2 RequiresSetenv() — LD_LIBRARY_PATH reexec 机制

```
RequiresSetenv(jvmpath):
│
├── 检查 LD_LIBRARY_PATH:
│   llp = getenv("LD_LIBRARY_PATH");
│   if (llp == NULL) return JNI_FALSE;  // 没设置 → 不需要 reexec
│
├── 安全检查 (Linux):
│   if (getgid() != getegid() || getuid() != geteuid())
│     return JNI_FALSE;  // suid/sgid 程序 → glibc 会清除 LD_LIBRARY_PATH
│
├── 防止递归:
│   if (llp 以 jvmpath 目录开头)
│     return JNI_FALSE;  // 已经设置正确了
│
└── 检查是否有冲突的 libjvm.so:
    if (LD_LIBRARY_PATH 中包含 "lib/client" 或 "lib/server" 路径下的其他 libjvm.so)
      return JNI_TRUE;  // 可能加载错误的 libjvm.so → 需要 reexec
```

**如果需要 reexec**：
1. 构建新的 `LD_LIBRARY_PATH = <jvmpath_dir>:<jrepath>/lib:...:<原始 LD_LIBRARY_PATH>`
2. `putenv(new_runpath)`
3. `execve(execname, argv, newenvp)` — **重新执行自己**
4. 第二次执行时，`RequiresSetenv()` 检测到 LD_LIBRARY_PATH 前缀已正确，直接 return

**为什么需要这个机制？**
- `ld.so`（Linux 动态链接器）**只在进程启动时读取一次 LD_LIBRARY_PATH**
- 如果 `LD_LIBRARY_PATH` 指向了错误的 `libjvm.so`（比如其他 JDK 版本），运行时 `dlopen` 可能解析到错误的依赖
- 通过 reexec，确保正确的 `LD_LIBRARY_PATH` 在进程启动时就生效

---

## 23.5 Phase 4: LoadJavaVM() — dlopen + dlsym 加载 HotSpot

**文件**：`java_md_solinux.c` 第 448-490 行

```c
jboolean LoadJavaVM(const char *jvmpath, InvocationFunctions *ifn) {
    void *libjvm;

    // ★ dlopen：加载 libjvm.so
    // RTLD_NOW：立即解析所有符号（不延迟到使用时）
    // RTLD_GLOBAL：libjvm.so 中的符号对后续 dlopen 的库全局可见
    libjvm = dlopen(jvmpath, RTLD_NOW + RTLD_GLOBAL);

    // ★ dlsym：查找三个 JNI Invocation API 函数
    ifn->CreateJavaVM =
        (CreateJavaVM_t)dlsym(libjvm, "JNI_CreateJavaVM");

    ifn->GetDefaultJavaVMInitArgs =
        (GetDefaultJavaVMInitArgs_t)dlsym(libjvm, "JNI_GetDefaultJavaVMInitArgs");

    ifn->GetCreatedJavaVMs =
        (GetCreatedJavaVMs_t)dlsym(libjvm, "JNI_GetCreatedJavaVMs");

    return JNI_TRUE;
}
```

### InvocationFunctions — 三函数指针结构体

**文件**：`java.h` 第 86-92 行

```c
typedef jint (JNICALL *CreateJavaVM_t)(JavaVM **pvm, void **env, void *args);
typedef jint (JNICALL *GetDefaultJavaVMInitArgs_t)(void *args);
typedef jint (JNICALL *GetCreatedJavaVMs_t)(JavaVM **vmBuf, jsize bufLen, jsize *nVMs);

typedef struct {
    CreateJavaVM_t CreateJavaVM;                     // JNI_CreateJavaVM
    GetDefaultJavaVMInitArgs_t GetDefaultJavaVMInitArgs; // JNI_GetDefaultJavaVMInitArgs
    GetCreatedJavaVMs_t GetCreatedJavaVMs;           // JNI_GetCreatedJavaVMs
} InvocationFunctions;
```

| 函数 | 用途 | 调用时机 |
|------|------|---------|
| `JNI_CreateJavaVM` | 创建并初始化 JVM | `InitializeJVM()` 中调用 |
| `JNI_GetDefaultJavaVMInitArgs` | 获取默认 VM 初始化参数（如默认栈大小） | `ContinueInNewThread()` 中查询 |
| `JNI_GetCreatedJavaVMs` | 获取已创建的 JVM 列表 | 极少使用 |

### dlopen 标志的意义

| 标志 | 作用 | 为什么需要 |
|------|------|-----------|
| `RTLD_NOW` | 加载时立即解析所有未定义符号 | 如果 libjvm.so 有缺失依赖，立即报错而不是延迟到运行时崩溃 |
| `RTLD_GLOBAL` | 加载的符号全局可见 | libjava.so / libinstrument.so 等后续库需要引用 libjvm.so 中的符号（如 JVM_FindClassFromBootLoader） |

---

## 23.6 Phase 5: ParseArguments() — 命令行参数解析

**文件**：`java.c` 第 1145-1339 行

### 参数分类

```
enum OptionKind {
    LAUNCHER_OPTION = 0,               // -jar, -cp, --module
    LAUNCHER_OPTION_WITH_ARGUMENT,     // -cp <path>, --class-path <path>
    LAUNCHER_MAIN_OPTION,              // --module / -m（指定主模块）
    VM_LONG_OPTION,                    // --add-modules=xxx
    VM_LONG_OPTION_WITH_ARGUMENT,      // --module-path <path>
    VM_OPTION                          // -Xms8g, -XX:+UseG1GC, -Dfoo=bar
};
```

### 解析流程

```
ParseArguments(&argc, &argv, &mode, &what, &ret, jrepath):
│
├── 循环处理所有以 '-' 开头的参数:
│
│   ├── -jar → mode = LM_JAR
│   ├── --module / -m → mode = LM_MODULE
│   ├── --source → mode = LM_SOURCE
│   ├── -classpath / -cp / --class-path → SetClassPath(value), mode = LM_CLASS
│   │   → "-Djava.class.path=<value>" 加入 options[]
│   │
│   ├── 版本/帮助类:
│   │   ├── -version / --version → printVersion = true
│   │   ├── -showversion / --show-version → showVersion = true
│   │   ├── -help / -h / --help → printUsage = true
│   │   └── -X / --help-extra → printXUsage = true
│   │
│   ├── 模块系统:
│   │   ├── --list-modules / --show-resolved-modules / --describe-module
│   │   ├── --module-path / --upgrade-module-path
│   │   ├── --add-modules / --limit-modules / --add-exports / --add-opens / --add-reads
│   │   └── --patch-module → 以 VM_LONG_OPTION_WITH_ARGUMENT 方式加入 options[]
│   │
│   ├── 兼容性转换:
│   │   ├── -verbosegc → -verbose:gc
│   │   ├── -noverify → -Xverify:none
│   │   ├── -ss / -ms / -mx → -Xss / -Xms / -Xmx
│   │   └── -debug → -Xdebug
│   │
│   └── 其他所有 -X / -XX / -D 参数:
│       AddOption(arg, NULL);  → 直接加入 options[]
│
├── 确定 what（第一个非 '-' 参数）:
│   *pwhat = *argv;  // 例: "com.wjcoder.Main"
│
└── 确定 mode（如果还未确定）:
    if (mode == LM_UNKNOWN) {
      if (!_have_classpath) SetClassPath(".");  // 默认 classpath = "."
      mode = IsSourceFile(arg) ? LM_SOURCE : LM_CLASS;
    }
```

### AddOption() — 全局 options 数组构建

```c
static JavaVMOption *options;  // 全局数组
static int numOptions, maxOptions;

void AddOption(char *str, void *info) {
    // 动态扩容（初始 4，每次翻倍）
    if (numOptions >= maxOptions) {
        maxOptions = (options == 0) ? 4 : maxOptions * 2;
        options = realloc(options, maxOptions * sizeof(JavaVMOption));
    }
    options[numOptions].optionString = str;
    options[numOptions++].extraInfo = info;

    // ★ 特殊处理：提前解析堆/栈大小
    if (strncmp(str, "-Xss", 4) == 0) {
        parse_size(str + 4, &threadStackSize);  // → 用于新线程创建
    }
    if (strncmp(str, "-Xmx", 4) == 0) {
        parse_size(str + 4, &maxHeapSize);
    }
    if (strncmp(str, "-Xms", 4) == 0) {
        parse_size(str + 4, &initialHeapSize);
    }
}
```

**关键设计**：`-Xss` 在 `ParseArguments` 阶段就被解析到 `threadStackSize` 全局变量，因为这个值在 `CallJavaMainInNewThread()` 中创建新线程时需要使用，此时 JVM 还没启动。

### 四种启动模式

```c
enum LaunchMode {
    LM_UNKNOWN = 0,  // 未确定
    LM_CLASS,        // 1: java Main            → 直接指定类名
    LM_JAR,          // 2: java -jar app.jar    → JAR 文件
    LM_MODULE,       // 3: java -m mod/Main     → 模块
    LM_SOURCE         // 4: java Main.java       → 源文件（JDK 11 新增！）
};
```

| 模式 | 触发条件 | what 的含义 | 特殊处理 |
|------|---------|------------|---------|
| LM_CLASS | `-cp xxx Main` 或直接指定类名 | 类的全限定名（如 `com.wjcoder.Main`） | 默认模式 |
| LM_JAR | `-jar app.jar` | JAR 文件路径 | `SetClassPath(what)` 覆盖 classpath |
| LM_MODULE | `-m mod/Main` 或 `--module mod/Main` | 模块/类名 | `SetMainModule(value)` |
| LM_SOURCE | `Main.java`（文件以 .java 结尾且存在） | `jdk.compiler/...launcher.Main` | 重写 what 为编译器入口 |

---

## 23.7 Phase 6: JVMInit → ContinueInNewThread → CallJavaMainInNewThread

### 为什么需要新线程？

**关键注释**（`java.c` 第 228 行）：
> Running Java code in primordial thread caused many problems. We will create a new thread to invoke JVM. See 6316197 for more information.

**原因**：
1. **栈大小不可控**：primordial 线程（main 线程）的栈大小由 OS 决定（通常 8MB），不受 `-Xss` 控制
2. **线程栈终止问题**：某些 OS 上 primordial 线程栈不能被正确回收
3. **信号处理**：primordial 线程在某些 OS 上有特殊的信号处理行为

### 调用链

```
JVMInit(&ifn, threadStackSize, argc, argv, mode, what, ret):
│
├── ShowSplashScreen();  // 启动画面（如果有）
│
└── ContinueInNewThread(&ifn, threadStackSize, argc, argv, mode, what, ret):
    │
    ├── 查询默认栈大小（如果用户没指定）:
    │   if (threadStackSize == 0) {
    │     struct JDK1_1InitArgs args1_1;
    │     args1_1.version = JNI_VERSION_1_1;
    │     ifn->GetDefaultJavaVMInitArgs(&args1_1);
    │     threadStackSize = args1_1.javaStackSize;
    │   }
    │
    ├── 构建 JavaMainArgs:
    │   args.argc = argc;
    │   args.argv = argv;
    │   args.mode = mode;      // LM_CLASS
    │   args.what = what;      // "com.wjcoder.Main"
    │   args.ifn  = *ifn;     // 三个函数指针
    │
    └── CallJavaMainInNewThread(threadStackSize, &args):
        │
        ├── pthread_attr_init(&attr);
        ├── pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_JOINABLE);
        ├── if (stack_size > 0)
        │     pthread_attr_setstacksize(&attr, stack_size);
        ├── pthread_attr_setguardsize(&attr, 0);  // ★ 禁用 guard page
        │
        ├── ★ pthread_create(&tid, &attr, ThreadJavaMain, args):
        │   → 创建新线程
        │   → 入口: ThreadJavaMain() → JavaMain()
        │
        ├── pthread_join(tid, &tmp);  // 主线程阻塞等待
        │
        └── return rslt;
```

**关键设计**：
- `PTHREAD_CREATE_JOINABLE`：主线程需要 `pthread_join` 等待新线程完成
- `pthread_attr_setguardsize(&attr, 0)`：**禁用 guard page**。JVM 自己管理栈溢出检测（通过 StackOverflow 信号处理），不需要 OS 的 guard page
- 如果 `pthread_create` 失败（内存不足等），**降级**在当前线程直接调用 `JavaMain(args)`

---

## 23.8 Phase 7: JavaMain() — JVM 创建与 Java 执行

**文件**：`java.c` 第 394-530 行

这是**整个 libjli 的核心函数**，在新线程中执行。

```
JavaMain(void* _args):
│
├── ① 解包参数:
│   JavaMainArgs *args = (JavaMainArgs *)_args;
│   int mode = args->mode;      // LM_CLASS
│   char *what = args->what;    // "com.wjcoder.Main"
│   InvocationFunctions ifn = args->ifn;
│
├── ② ★★★ InitializeJVM(&vm, &env, &ifn):
│   → 构建 JavaVMInitArgs
│   → 调用 ifn->CreateJavaVM() → JNI_CreateJavaVM() [HotSpot]
│   → 成功后 vm / env 可用
│   → 详见 23.8.1
│
├── ③ 处理版本/设置等选项:
│   if (showSettings)    ShowSettings(env, showSettings);
│   if (listModules)     ListModules(env);        LEAVE();
│   if (printVersion)    PrintJavaVersion(env);   LEAVE();
│   if (validateModules) LEAVE();
│   if (what == 0)       PrintUsage(env);         LEAVE();
│
├── ④ ★ LoadMainClass(env, mode, what):
│   → 通过 LauncherHelper.checkAndLoadMain(mode, name) 加载主类
│   → 验证 main 方法存在且签名正确
│   → 支持 JavaFX 等特殊入口
│   → 详见 23.8.2
│
├── ⑤ 准备参数:
│   appClass = GetApplicationClass(env);
│   mainArgs = CreateApplicationArgs(env, argv, argc);
│   PostJVMInit(env, appClass, vm);
│
├── ⑥ 获取 main 方法:
│   mainID = (*env)->GetStaticMethodID(env, mainClass, "main",
│                                       "([Ljava/lang/String;)V");
│
├── ⑦ ★★★ 调用 Java main 方法:
│   (*env)->CallStaticVoidMethod(env, mainClass, mainID, mainArgs);
│
│   // 到这里，Java 的 main 方法已经执行完毕
│   // 如果 main 中调用了 System.exit()，不会走到这里
│
├── ⑧ 检查异常:
│   ret = (*env)->ExceptionOccurred(env) == NULL ? 0 : 1;
│
└── ⑨ ★ LEAVE() 宏:
    ├── (*vm)->DetachCurrentThread(vm);
    │   → 将当前线程从 JVM 分离
    │   → 触发 uncaught exception handler
    │
    └── (*vm)->DestroyJavaVM(vm);
        → ★★★ 等待所有非守护线程退出
        → 创建 "DestroyJavaVM" 线程
        → 执行 VM 关闭流程
        → 关闭钩子 (shutdown hooks) 在这里执行
```

### 23.8.1 InitializeJVM — 从 options[] 到 JNI_CreateJavaVM

```c
static jboolean
InitializeJVM(JavaVM **pvm, JNIEnv **penv, InvocationFunctions *ifn) {
    JavaVMInitArgs args;
    memset(&args, 0, sizeof(args));
    args.version  = JNI_VERSION_1_2;
    args.nOptions = numOptions;     // 参数个数
    args.options  = options;        // JavaVMOption[] 数组
    args.ignoreUnrecognized = JNI_FALSE;  // 不忽略未识别的选项

    // ★ 调用 HotSpot 的 JNI_CreateJavaVM
    jint r = ifn->CreateJavaVM(pvm, (void **)penv, &args);

    JLI_MemFree(options);  // 释放 options 数组
    return r == JNI_OK;
}
```

**options 数组示例**（对应 `java -Xms8g -Xmx8g -XX:+UseG1GC -cp /app Main`）：

```
option[0] = "-Djava.class.path=/app"
option[1] = "-Xms8g"
option[2] = "-Xmx8g"
option[3] = "-XX:+UseG1GC"
option[4] = "-Dsun.java.command=Main"
option[5] = "-Dsun.java.launcher=SUN_STANDARD"
option[6] = "-Dsun.java.launcher.pid=12345"
```

**注意**：主类名（Main）**不在** options 中！它通过 `what` 变量单独传递给 `LoadMainClass()`。

### 23.8.2 LoadMainClass — 通过 LauncherHelper 加载主类

```c
static jclass LoadMainClass(JNIEnv *env, int mode, char *name) {
    jclass cls = GetLauncherHelperClass(env);
    // → FindBootStrapClass(env, "sun/launcher/LauncherHelper")
    // → 从引导类加载器查找（不走 application class loader）

    jmethodID mid = (*env)->GetStaticMethodID(env, cls,
        "checkAndLoadMain",
        "(ZILjava/lang/String;)Ljava/lang/Class;");

    jstring str = NewPlatformString(env, name);

    return (*env)->CallStaticObjectMethod(env, cls, mid,
        USE_STDERR, mode, str);
    // → LauncherHelper.checkAndLoadMain(true, LM_CLASS, "com.wjcoder.Main")
}
```

**LauncherHelper.checkAndLoadMain()** 在 Java 层做了什么：
1. 根据 mode 确定如何找到主类
2. `LM_CLASS`：`ClassLoader.getSystemClassLoader().loadClass(name)`
3. `LM_JAR`：从 JAR manifest 读取 `Main-Class`，然后加载
4. `LM_MODULE`：从模块系统查找
5. 验证 `main(String[])` 方法存在（public static void）
6. 返回主类的 `Class` 对象

### LEAVE() 宏 — 优雅退出

```c
#define LEAVE() \
    do { \
        if ((*vm)->DetachCurrentThread(vm) != JNI_OK) { \
            ret = 1; \
        } \
        if (JNI_TRUE) { \
            (*vm)->DestroyJavaVM(vm); \
            return ret; \
        } \
    } while (JNI_FALSE)
```

**设计精妙之处**：
1. **先 Detach**：让当前线程"看起来已经结束"。这样 `mainThread.join()` 和 `mainThread.isAlive()` 在 Java 层会得到正确结果
2. **再 DestroyJavaVM**：等待所有非守护线程退出。在内部创建了一个名为 `"DestroyJavaVM"` 的新 Java 线程，**与执行 main 的是不同的 Java 线程**（虽然底层是同一个 C 线程）

---

## 23.9 NMT 环境变量设置

**文件**：`java.c` 第 629-680 行

```
SetJvmEnvironment():
│
├── 扫描 argv 寻找 "-XX:NativeMemoryTracking=xxx"
│
├── 构建环境变量:
│   NMT_LEVEL_<pid>=<value>
│   例: "NMT_LEVEL_12345=summary"
│
└── putenv(pbuf)
    → JVM 启动后会读取 NMT_LEVEL_<pid> 并据此初始化 NMT
    → JVM 负责在读取后清除这个环境变量
```

**为什么用环境变量而不是直接传 option？**
- NMT 需要在 JVM 最早期（甚至在 `malloc` hook 安装之前）就知道追踪级别
- 环境变量在 `JNI_CreateJavaVM` 之前就可用
- 用 `<pid>` 后缀避免多个 JVM 实例之间的冲突

---

## 23.10 完整时序图

```
时间线          主线程 (primordial)              新线程 (JavaMain)
─────────────────────────────────────────────────────────────────
T0  main(argc, argv)
T1  └── JLI_Launch()
T2      ├── SelectVersion()
T3      ├── CreateExecutionEnvironment()
T4      │   ├── SetExecname()
T5      │   ├── GetJREPath()
T6      │   ├── ReadKnownVMs()
T7      │   ├── CheckJvmType()
T8      │   └── GetJVMPath()
T9      ├── LoadJavaVM()
T10     │   ├── dlopen(libjvm.so)
T11     │   └── dlsym × 3
T12     ├── ParseArguments()
T13     │   └── AddOption() × N
T14     ├── SetJavaCommandLineProp()
T15     └── JVMInit()
T16         └── ContinueInNewThread()
T17             └── CallJavaMainInNewThread()
T18                 ├── pthread_create() ──────→ ThreadJavaMain()
T19                 │                            ├── JavaMain()
T20                 │   (阻塞等待)                │   ├── InitializeJVM()
T21                 │                            │   │   └── JNI_CreateJavaVM()
T22                 │                            │   │       └── Threads::create_vm()
T23                 │                            │   │           └── init_globals()
T24                 │                            │   │               └── [HotSpot 完整初始化]
T25                 │                            │   ├── LoadMainClass()
T26                 │                            │   │   └── LauncherHelper.checkAndLoadMain()
T27                 │                            │   ├── GetStaticMethodID("main")
T28                 │                            │   ├── CallStaticVoidMethod()
T29                 │                            │   │   └── [执行 Java main 方法]
T30                 │                            │   │       └── [应用运行中...]
T31                 │                            │   ├── DetachCurrentThread()
T32                 │                            │   └── DestroyJavaVM()
T33                 │                            │       └── [等待非守护线程退出]
T34                 │                            │           └── [关闭钩子执行]
T35                 │                            └── return rslt
T36                 ├── pthread_join() 返回 ←────
T37                 └── return rslt
T38     return ret
```

---

## 23.11 面试专题

### Q1: java 命令的启动流程是怎样的？从敲下命令到 main 方法执行经过了哪些步骤？

**源码级回答**：

1. OS 加载 `java` 可执行文件（只包含 main.c 中的 `main()`），链接 `libjli.so`
2. `main()` 合并 `JDK_JAVA_OPTIONS` 环境变量，展开 `@argfile`，调用 `JLI_Launch()`
3. `JLI_Launch()` 中：
   - `CreateExecutionEnvironment()`：通过 `/proc/self/exe` 定位 JDK 目录，读取 `jvm.cfg` 确定 VM 类型（server），拼接 `libjvm.so` 路径
   - `LoadJavaVM()`：`dlopen("xxx/lib/server/libjvm.so")` + `dlsym` 获取三个 JNI 函数指针
   - `ParseArguments()`：解析所有命令行参数到 `options[]` 数组，确定启动模式和主类名
   - `JVMInit()` → `ContinueInNewThread()` → `pthread_create()` 创建新线程
4. 新线程中 `JavaMain()`：
   - `InitializeJVM()`：构建 `JavaVMInitArgs`，调用 `JNI_CreateJavaVM()`（进入 HotSpot）
   - `LoadMainClass()`：通过 `LauncherHelper.checkAndLoadMain()` 加载主类
   - `CallStaticVoidMethod()`：调用 Java `main` 方法
   - `LEAVE()`：Detach → DestroyJavaVM → 等待非守护线程 → 关闭钩子

### Q2: 为什么 JVM 要在新线程而不是 main 线程中启动？

- **栈大小控制**：primordial 线程栈大小由 OS 决定（通常 8MB），无法通过 `-Xss` 控制；新线程可以用 `pthread_attr_setstacksize` 精确设置
- **guard page 管理**：JVM 自己管理栈溢出检测（通过 SIGSEGV 信号），新线程可以用 `pthread_attr_setguardsize(0)` 禁用 OS guard page
- **线程生命周期**：某些 OS 对 primordial 线程有特殊限制，新线程行为更一致
- **历史 Bug 修复**：参见 JDK Bug 6316197

### Q3: LoadJavaVM 中 dlopen 为什么用 RTLD_NOW + RTLD_GLOBAL？

- **RTLD_NOW**：立即解析 libjvm.so 的所有符号引用。如果有缺失的依赖（比如 libpthread 没链接），**立即报错**而不是在运行时随机崩溃
- **RTLD_GLOBAL**：libjvm.so 中的符号对后续 dlopen 的库**全局可见**。这对 libjava.so、libinstrument.so 等至关重要——它们需要调用 libjvm.so 中的 JVM_xxx 函数（如 `JVM_FindClassFromBootLoader`），如果不设 GLOBAL，这些符号就找不到

### Q4: jvm.cfg 文件有什么作用？为什么需要它？

- **历史原因**：早期 JDK 同时包含 client 和 server VM，jvm.cfg 用于配置哪些可用、如何选择
- **格式**：每行 `-<name> <flag>`，flag 可以是 KNOWN / ALIASED_TO / WARN / IGNORE / ERROR
- **作用**：`knownVMs[0]` 决定默认 VM（通常是 `-server KNOWN`）
- **JDK 11+**：client VM 已移除，jvm.cfg 通常只有 `-server KNOWN`。但机制保留以支持自定义 VM 集成

### Q5: ParseArguments 中 -Xss 为什么要提前解析？

- `-Xss` 指定的是 Java 线程栈大小
- `ParseArguments()` 提前将 `-Xss` 解析到全局变量 `threadStackSize`
- 这个值在 `CallJavaMainInNewThread()` 中用 `pthread_attr_setstacksize()` 设置**创建 JVM 的那个新线程的栈大小**
- 此时 JVM 还没启动，所以不能等到 JVM 内部处理

### Q6: LD_LIBRARY_PATH reexec 机制是什么？什么时候触发？

**触发条件**：
1. `LD_LIBRARY_PATH` 已设置
2. 不是 suid/sgid 进程
3. `LD_LIBRARY_PATH` 第一个路径不是目标 libjvm.so 的目录
4. `LD_LIBRARY_PATH` 中包含其他 libjvm.so 路径

**流程**：
1. 修改 `LD_LIBRARY_PATH`，将正确的 libjvm.so 路径放到最前面
2. `execve(自己)` — 重新执行自己
3. 第二次启动时检测到路径已正确，正常继续

**原因**：Linux 动态链接器只在进程启动时读一次 `LD_LIBRARY_PATH`，运行中修改无效。所以必须 reexec。

### Q7: DestroyJavaVM 做了什么？为什么要先 Detach？

**先 Detach 的原因**：
- Detach 后，当前线程在 Java 层"消失"了
- `Thread.currentThread().isAlive()` 返回 false
- `mainThread.join()` 不再阻塞
- 这让 main 方法的生命周期与 Java Thread 对象的生命周期一致

**DestroyJavaVM 的流程**：
1. 当前线程以 `"DestroyJavaVM"` 名字重新 Attach（虽然底层是同一个 C 线程，但 Java 层是新 Thread）
2. **等待所有非守护线程退出**
3. 执行 **关闭钩子**（Runtime.addShutdownHook 注册的）
4. 运行 finalizer
5. 关闭 JVM 内部服务
6. 释放资源

---

*分析文件*：
- `src/java.base/share/native/launcher/main.c` — C main() 入口（215 行）
- `src/java.base/share/native/libjli/java.c` — JLI_Launch + JavaMain + ParseArguments + InitializeJVM（2497 行）
- `src/java.base/share/native/libjli/java.h` — InvocationFunctions / LaunchMode / JavaMainArgs 定义（279 行）
- `src/java.base/unix/native/libjli/java_md_solinux.c` — Linux: CreateExecutionEnvironment / LoadJavaVM / CallJavaMainInNewThread（880 行）
- `src/java.base/unix/native/libjli/java_md_common.c` — Unix: GetApplicationHome / SetExecname / FindExecName（372 行）
- `src/hotspot/share/prims/jni.cpp` — JNI_CreateJavaVM → JNI_CreateJavaVM_inner（HotSpot 衔接点）
