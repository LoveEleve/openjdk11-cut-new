
# Ch 9 类操作命令 — jad / redefine / retransform / sc / sm / dump

> 源文件:
> - `klass100/JadCommand.java` (255行) — 反编译
> - `klass100/RedefineCommand.java` (182行) — 类重定义
> - `klass100/RetransformCommand.java` (502行) — 类重转换
> - `klass100/SearchClassCommand.java` (182行) — sc 搜索类
> - `klass100/SearchMethodCommand.java` (195行) — sm 搜索方法
> - `klass100/DumpClassCommand.java` (194行) — dump 导出字节码
> - `klass100/ClassDumpTransformer.java` (95行) — 字节码 dump 引擎
> - `util/Decompiler.java` (141行) — CFR 反编译器包装
> - `util/InstrumentationUtils.java` (55行) — retransform 工具
> - `util/SearchUtils.java` (144行) — 类/方法搜索引擎

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文深入分析 **Ch 9 类操作命令 — jad / redefine / retransform / sc / sm / dump**：从源码角度理解其设计原理、实现机制和关键细节。

### 0.2 为什么需要？

理解 JVM 内部实现是排查复杂问题、进行性能优化的基础。表面的 API 文档无法解释 JVM 的实际行为，只有深入源码才能建立精确的心智模型。

### 0.3 怎么解决？

结合源码阅读、数据结构分析和 GDB 运行时验证，从多个角度建立对该机制的完整理解。

### 0.4 为什么这样设计？

每个设计决策都有其权衡：性能 vs 正确性、简单性 vs 灵活性、内存占用 vs 查找速度。理解这些权衡是理解 JVM 设计的关键。

---


## 0. 本章概览 — 类操作命令全景

### 0.1 为什么需要这些命令？

在线上排查问题时，你经常需要回答以下问题：

| 问题 | 对应命令 | 核心操作 |
|------|---------|---------|
| "这个类到底被谁加载了？版本对不对？" | `sc` | 搜索已加载的类 |
| "这个类有哪些方法？方法签名是什么？" | `sm` | 搜索方法 |
| "这个类的源码到底长什么样？" | `jad` | 反编译为 Java 源码 |
| "想把这个类的字节码文件保存下来分析" | `dump` | 导出 .class 文件 |
| "修改了代码想热更新到线上" | `redefine` / `retransform` | 替换类字节码 |

### 0.2 命令定位图

```
                       Instrumentation API
                       ──────────────────
                       │ getAllLoadedClasses()     ← sc/sm 的数据源
                       │ retransformClasses()      ← jad/dump/retransform 的核心 API
                       │ redefineClasses()         ← redefine 的核心 API
                       │ addTransformer()          ← 注册 Transformer
                       └──────────────────

┌─────────────────── 查询类命令（只读）──────────────────────────┐
│                                                               │
│  sc (Search Class)      sm (Search Method)     dump           │
│  ├── 搜索已加载的类     ├── 搜索类的方法       ├── 导出字节码  │
│  ├── -d 显示详情        ├── -d 显示方法详情     ├── 保存到文件  │
│  └── -f 显示字段        └── 遍历 getDeclared*  └── retransform │
│      ↓                       ↓                      + dump     │
│  inst.getAllLoadedClasses  class.getDeclaredMethods              │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────── 反编译命令（只读）──────────────────────────┐
│                                                               │
│  jad (Java Decompile)                                         │
│  ├── Step 1: retransformClasses → ClassDumpTransformer         │
│  │           → 拦截字节码 → 写入 .class 文件                   │
│  ├── Step 2: CFR Decompiler → 反编译 .class → Java 源码        │
│  └── Step 3: 输出源码 + 行号映射                               │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────── 热更新命令（写操作！危险！）─────────────────┐
│                                                               │
│  redefine                        retransform                   │
│  ├── 读取 .class 文件            ├── 读取 .class 文件          │
│  ├── inst.redefineClasses()     ├── 注册 Transformer 到管道    │
│  ├── 一次性，不可回退 ❌         ├── inst.retransformClasses() │
│  └── 与增强命令冲突 ⚠️          ├── 可列表/删除/回退 ✅        │
│                                  └── 兼容增强命令 ✅            │
└─────────────────────────────────────────────────────────────────┘
```

---

## 1. jad 命令 — 反编译

### 1.1 jad 要解决什么问题？

线上环境经常遇到的痛点：
- "这个 bug 理论上不应该出现，代码应该没问题啊" → **线上部署的版本可能和你看的源码不一致**
- "这个类被 AOP 代理了，增强后的逻辑是什么？" → **需要反编译实际运行的字节码**
- "ClassLoader 冲突，到底加载了哪个版本？" → **需要看实际的 Class 内容**

### 1.2 核心流程（5 步）

```
用户输入: jad com.example.MyService doSomething

Step 1: 类搜索
──────────────
SearchUtils.searchClassOnly(inst, "com.example.MyService", false, code)
  → 遍历 inst.getAllLoadedClasses()
  → 通配符匹配类名
  → 返回 Set<Class<?>>

Step 2: 匹配数量判断
──────────────────────
matchedClasses.size() == 0  → "No class found for: ..."
matchedClasses.size() > 1   → "Found more than one class, use -c <hashcode>"
                                （同一个类被多个 ClassLoader 加载）
matchedClasses.size() == 1  → 继续

Step 3: 搜索内部类
──────────────────
SearchUtils.searchClassOnly(inst, "com.example.MyService$*", false, code)
  → 找到所有内部类（反编译时需要一起处理）
  → allClasses = {MyService, MyService$Inner1, MyService$1}

Step 4: dump 字节码到临时文件
────────────────────────────
ClassDumpTransformer transformer = new ClassDumpTransformer(allClasses);
InstrumentationUtils.retransformClasses(inst, transformer, allClasses);
  → inst.addTransformer(transformer, true)     // 注册临时 Transformer
  → inst.retransformClasses(allClasses)        // 触发类重新转换
  →   JVM 调用 transformer.transform()
  →     if (classesToEnhance.contains(classBeingRedefined))
  →       dumpClassIfNecessary(clazz, classfileBuffer)  // 将字节码写入文件
  →       return null   // ← 关键！返回 null 表示不修改字节码
  → inst.removeTransformer(transformer)        // 移除临时 Transformer

Step 5: CFR 反编译
──────────────────
Decompiler.decompileWithMappings(classFile.getPath(), "doSomething", false, true)
  → CfrDriver.Builder().withOptions(options).withOutputSink(sink).build()
  → driver.analyse(classFile)
  → 收集反编译源码 + 行号映射（bytecode行 → 源码行）
  → 正则清理空注释：pattern.matcher(source).replaceAll("")
  → 输出: JadModel{source, mappings, classInfo, location}
```

### 1.3 ClassDumpTransformer — 字节码拦截器

```java
class ClassDumpTransformer implements ClassFileTransformer {
    private Set<Class<?>> classesToEnhance;     // 目标类集合
    private Map<Class<?>, File> dumpResult;     // 结果：类 → 文件

    @Override
    public byte[] transform(ClassLoader loader, String className,
                            Class<?> classBeingRedefined,
                            ProtectionDomain protectionDomain,
                            byte[] classfileBuffer) {
        if (classesToEnhance.contains(classBeingRedefined)) {
            dumpClassIfNecessary(classBeingRedefined, classfileBuffer);
            // ↑ 把 classfileBuffer 写入文件
        }
        return null;   // ← 不修改字节码！只是拦截一下 dump 出来
    }
}
```

**关键设计**：

1. **为什么不直接用 `clazz.getResourceAsStream()` 获取字节码？**
   - 因为 `getResourceAsStream` 获取的是**原始**字节码（磁盘上的 .class 文件）
   - 如果类被 AOP、Arthas 或其他 Agent 增强过，获取的不是**运行时**的字节码
   - 通过 `retransformClasses` + `ClassFileTransformer`，JVM 会把**当前运行时**的字节码交给 Transformer

2. **为什么 `transform()` 返回 `null`？**
   - 返回 `null` 表示不修改字节码
   - jad 只是想"偷看"一眼字节码，不想改任何东西
   - 这就是一个**只读拦截**

3. **文件路径格式**：`{ClassLoader类名}-{hashCode}/{全限定类名}.class`
   ```
   ~/logs/arthas/classdump/
   └── sun.misc.Launcher$AppClassLoader-39eb305e/
       └── com/example/MyService.class
   ```

### 1.4 CFR 反编译器集成

```java
public static Pair<String, NavigableMap<Integer, Integer>> decompileWithMappings(...) {
    // ① 配置 CFR
    HashMap<String, String> options = new HashMap<>();
    options.put("showversion", "false");        // 不显示 CFR 版本
    options.put("hideutf", "true/false");       // 是否隐藏 Unicode
    options.put("trackbytecodeloc", "true");    // 启用字节码位置追踪
    options.put("methodname", "doSomething");   // 只反编译指定方法

    // ② 自定义输出接收器
    OutputSinkFactory mySink = new OutputSinkFactory() {
        // 处理 LINENUMBER 类型 → 收集行号映射
        // 处理 DECOMPILED 类型 → 收集源码文本
        // 忽略 PROGRESS 类型
    };

    // ③ 执行反编译
    CfrDriver driver = new CfrDriver.Builder()
            .withOptions(options)
            .withOutputSink(mySink)
            .build();
    driver.analyse(Arrays.asList(classFilePath));

    // ④ 添加行号注释（如 /*42*/）
    if (printLineNumber && !lineMapping.isEmpty()) {
        resultCode = addLineNumber(resultCode, lineMapping);
    }

    return Pair.make(resultCode, lineMapping);
}
```

**行号映射的意义**：
- CFR 反编译后的源码行号和原始 Java 源码的行号不一致
- `lineMapping` 记录了 `反编译源码行号 → 原始字节码行号` 的映射
- 输出时会在每行前面加上 `/*42*/` 这样的注释，标记原始行号
- 这样用户可以对照 IDE 中的源码定位问题

### 1.5 jad 完整数据流

```
jad com.example.MyService doSomething

         ┌─────────────────────────────────────────┐
         │            JadCommand.process()          │
         └────────────────┬────────────────────────┘
                          │
                ┌─────────▼─────────┐
                │ SearchUtils        │  遍历 inst.getAllLoadedClasses()
                │ .searchClassOnly() │  → 找到 MyService.class
                └─────────┬─────────┘
                          │
            ┌─────────────▼─────────────┐
            │ matchedClasses.size() == 1 │
            │ + 搜索内部类 MyService$*   │
            └─────────────┬─────────────┘
                          │
         ┌────────────────▼────────────────┐
         │ InstrumentationUtils             │
         │ .retransformClasses(inst,        │
         │   ClassDumpTransformer, classes) │
         └────────────────┬────────────────┘
                          │
    ┌─────────────────────▼─────────────────────┐
    │ inst.addTransformer(dumpTransformer, true) │
    │ inst.retransformClasses(MyService.class)   │
    │   → JVM 回调 transform()                  │
    │     → classfileBuffer → 写入临时 .class 文件│
    │     → return null（不修改字节码）           │
    │ inst.removeTransformer(dumpTransformer)    │
    └─────────────────────┬─────────────────────┘
                          │
         ┌────────────────▼────────────────┐
         │ Decompiler.decompileWithMappings │
         │   → CfrDriver.analyse()         │
         │   → Java 源码 + 行号映射         │
         └────────────────┬────────────────┘
                          │
              ┌───────────▼───────────┐
              │ 输出: JadModel         │
              │ ├── source: 源码文本   │
              │ ├── mappings: 行号映射 │
              │ ├── classInfo: 类信息  │
              │ └── location: 代码路径 │
              └───────────────────────┘
```

---

## 2. redefine vs retransform — 两种热更新

### 2.1 为什么有两个命令？

这要从 JDK `Instrumentation` API 的设计说起：

```java
// JDK 提供了两个 API：
inst.redefineClasses(ClassDefinition...)    // redefine 用这个
inst.retransformClasses(Class<?>...)         // retransform 用这个
```

| 维度 | `redefineClasses` | `retransformClasses` |
|------|-------------------|---------------------|
| **输入** | 直接传入新的字节码 `byte[]` | 触发已注册的 Transformer 链 |
| **Transformer 参与** | ❌ 不触发 Transformer | ✅ 触发所有 retransform Transformer |
| **可逆性** | ❌ 不可逆（覆盖式） | ✅ 删除 Transformer 后再 retransform 即可恢复 |
| **与增强命令兼容** | ❌ 覆盖增强（watch/trace 失效） | ✅ Transformer 链中共存 |
| **JDK 引入版本** | JDK 5 (JVMTI) | JDK 6 |

### 2.2 redefine 命令 — 简单粗暴

```java
// RedefineCommand.process() 核心逻辑：

// Step 1: 读取 .class 文件
for (String path : paths) {
    byte[] bytes = readFile(path);
    String className = new ClassReader(bytes).getClassName();  // ASM 解析类名
    bytesMap.put(className, bytes);
}

// Step 2: 在已加载的类中找到对应的 Class 对象
List<ClassDefinition> definitions = new ArrayList<>();
for (Class<?> clazz : inst.getAllLoadedClasses()) {
    if (bytesMap.containsKey(clazz.getName())) {
        // 可选：按 ClassLoader hashCode 过滤
        definitions.add(new ClassDefinition(clazz, bytesMap.get(clazz.getName())));
    }
}

// Step 3: 一行代码完成热更新！
inst.redefineClasses(definitions.toArray(new ClassDefinition[0]));
```

**redefine 的致命问题**：

```
⚠️ redefine 会覆盖类的字节码，导致 Arthas 增强命令失效！

场景：
1. 用户 watch com.example.MyService doSomething
   → Arthas 通过 Transformer 修改了 MyService 的字节码（注入了 SpyAPI 调用）

2. 用户 redefine /tmp/MyService.class
   → inst.redefineClasses() 直接替换了 MyService 的字节码
   → Arthas 注入的 SpyAPI 调用被覆盖了！
   → watch 命令失效！

3. 更糟糕的是：redefine 不可逆
   → 你无法"撤销" redefine
   → 只能重新执行 watch 来重新增强
```

**所以 Arthas 官方推荐使用 `retransform` 而非 `redefine`**。

### 2.3 retransform 命令 — 可控的热更新

retransform 是 Arthas 4.x 推荐的热更新方式，设计远比 redefine 精巧。

#### 2.3.1 核心数据结构

```
RetransformCommand (static 字段)
│
├── retransformEntries: List<RetransformEntry>   ← 全局热更新条目列表
│     │
│     ├── RetransformEntry #1
│     │     ├── id: 1                   ← 原子递增 ID
│     │     ├── className: "com.example.MyService"
│     │     ├── bytes: byte[]           ← 新的字节码
│     │     ├── hashCode: "39eb305e"    ← ClassLoader hashCode
│     │     ├── classLoaderClass: null   ← ClassLoader 类名
│     │     └── transformCount: 0       ← 被触发次数
│     │
│     └── RetransformEntry #2
│           ├── id: 2
│           ├── className: "com.example.MyHelper"
│           └── ...
│
└── transformer: RetransformClassFileTransformer  ← 全局唯一 Transformer
      │
      └── 注册到 TransformerManager.reTransformers
          （排在 Arthas 增强命令的 Transformer 之前！）
```

#### 2.3.2 RetransformClassFileTransformer — 核心拦截逻辑

```java
static class RetransformClassFileTransformer implements ClassFileTransformer {
    @Override
    public byte[] transform(ClassLoader loader, String className,
                            Class<?> classBeingRedefined,
                            ProtectionDomain protectionDomain,
                            byte[] classfileBuffer) {
        if (className == null) return null;
        className = className.replace('/', '.');

        // ★ 关键：倒序遍历！后添加的条目优先级更高
        List<RetransformEntry> entries = allRetransformEntries();
        ListIterator<RetransformEntry> it = entries.listIterator(entries.size());
        while (it.hasPrevious()) {
            RetransformEntry entry = it.previous();

            boolean match = false;
            if (className.equals(entry.getClassName())) {
                if (entry.getClassLoaderClass() != null || entry.getHashCode() != null) {
                    match = isLoaderMatch(entry, loader);  // 精确匹配 ClassLoader
                } else {
                    match = true;   // 不指定 ClassLoader → 匹配所有
                }
            }

            if (match) {
                entry.incTransformCount();     // 统计触发次数
                return entry.getBytes();       // ← 返回新字节码！
            }
        }
        return null;  // 没有匹配 → 不修改
    }
}
```

#### 2.3.3 retransform 上传 .class 文件的完整流程

```
用户输入: retransform /tmp/MyService.class

Step 1: 初始化（仅首次）
──────────────────────
initTransformer()
  → new RetransformClassFileTransformer()
  → transformerManager.addRetransformer(transformer)
    → 注册到 TransformerManager 的 reTransformers 列表
    → 在 Transformer 管道中排在最前面

Step 2: 读取 .class 文件
──────────────────────
byte[] bytes = readFile("/tmp/MyService.class");
String className = new ClassReader(bytes).getClassName();
  → "com.example.MyService"

Step 3: 查找已加载的类
──────────────────────
for (Class<?> clazz : inst.getAllLoadedClasses()) {
    if ("com.example.MyService".equals(clazz.getName())) {
        // 按 ClassLoader 过滤（可选）
        RetransformEntry entry = new RetransformEntry(className, bytes, hashCode, null);
        retransformEntryList.add(entry);
        classList.add(clazz);
    }
}

Step 4: 注册条目 + 触发重转换
──────────────────────────
addRetransformEntry(retransformEntryList);
  → retransformEntries 列表追加新条目
  → 按 ID 排序（保证后添加的在后面）

inst.retransformClasses(classList.toArray(new Class[0]));
  → JVM 触发 Transformer 链：
    → RetransformClassFileTransformer.transform()
      → 倒序查找 → 匹配 className → return entry.getBytes()
      → JVM 使用返回的 bytes 替换类定义
    → [Arthas watch/trace 的 Transformer 继续执行]
      → 在新字节码基础上注入 SpyAPI 调用
      → ★ 所以 retransform 和增强命令可以共存！
```

#### 2.3.4 retransform 的管理操作

```bash
# 列出所有热更新条目
retransform -l
→ ID  CLASSNAME                    CLASSLOADER_HASH  TRANSFORM_COUNT
→ 1   com.example.MyService        39eb305e          2
→ 2   com.example.MyHelper         39eb305e          1

# 删除指定条目
retransform -d 1
→ 从列表中移除 ID=1 的条目

# 删除后需要重新触发 retransform 才能恢复原始字节码
retransform --classPattern com.example.MyService
→ 触发 retransformClasses()
→ Transformer 中已没有 MyService 的条目 → return null → 恢复原始字节码

# 清空所有条目
retransform --deleteAll
```

### 2.4 redefine vs retransform 的关键区别

```
═══════════════ redefine（覆盖式）═══════════════

原始字节码 ──redefine──→ 新字节码
                         （直接替换，Transformer 不参与）

结果：Arthas 的增强（watch/trace）被覆盖 → 失效 ❌

═══════════════ retransform（管道式）═══════════════

原始字节码 ──→ RetransformClassFileTransformer ──→ watch Transformer ──→ 最终字节码
               （替换为新字节码）                   （注入 SpyAPI 调用）

结果：热更新 + 增强命令 同时生效 ✅

═══════════════ retransform 删除条目后 ══════════════

原始字节码 ──→ RetransformClassFileTransformer ──→ watch Transformer ──→ 最终字节码
               （return null，不修改）               （注入 SpyAPI 调用）

结果：恢复原始字节码 + 增强命令继续生效 ✅
```

### 2.5 TransformerManager 中的顺序

```java
// TransformerManager 管道（Ch 5 已分析）：
reTransformers  → retransform 命令的 Transformer（最先执行）
watchTransformers → watch/monitor/stack/tt（然后执行）
traceTransformers → trace 命令（最后执行）

// retransform 条目的 Transformer 排在最前面！
// 这意味着：
// 1. retransform 替换的字节码会作为"基础"传给后续 Transformer
// 2. watch/trace 在替换后的字节码上注入 SpyAPI 调用
// 3. 所以两者可以共存
```

---

## 3. sc 命令 — 搜索已加载的类

### 3.1 核心逻辑

```java
// SearchClassCommand.process()

// ① 搜索类
List<Class<?>> matchedClasses = SearchUtils.searchClass(inst, classPattern, isRegEx, hashCode);

// ② 排序（按类名字典序）
Collections.sort(matchedClasses, (c1, c2) ->
    StringUtils.classname(c1).compareTo(StringUtils.classname(c2)));

// ③ 输出
if (isDetail) {
    // -d 模式：输出类的详细信息
    for (Class<?> clazz : matchedClasses) {
        ClassDetailVO classInfo = ClassUtils.createClassInfo(clazz, isField, expand);
        // 包含：类名、修饰符、父类、接口、ClassLoader、代码路径等
        process.appendResult(new SearchClassModel(classInfo, isDetail, isField));
    }
} else {
    // 简洁模式：只输出类名（分页，每页 256 个）
    ResultUtils.processClassNames(matchedClasses, 256, ...);
}
```

### 3.2 SearchUtils — 类搜索引擎

```java
public static Set<Class<?>> searchClass(Instrumentation inst, String classPattern, boolean isRegEx) {
    // ① 创建匹配器（通配符或正则）
    Matcher<String> classNameMatcher = classNameMatcher(classPattern, isRegEx);

    // ② 搜索主类
    Set<Class<?>> matches = searchClass(inst, classNameMatcher);

    // ③ 搜索子类（默认开启，除非 GlobalOptions.isDisableSubClass）
    if (!GlobalOptions.isDisableSubClass) {
        matches = searchSubClass(inst, matches);
    }

    return matches;
}

public static Set<Class<?>> searchClass(Instrumentation inst, Matcher<String> matcher, int limit) {
    Set<Class<?>> matches = new HashSet<>();
    for (Class<?> clazz : inst.getAllLoadedClasses()) {   // ← 遍历所有已加载的类！
        if (clazz == null) continue;
        if (matcher.matching(clazz.getName())) {
            matches.add(clazz);
        }
        if (matches.size() >= limit) break;
    }
    return matches;
}
```

**性能注意**：
- `inst.getAllLoadedClasses()` 返回 JVM 中**所有**已加载的类（通常数万个）
- 每次搜索都是全量遍历 → O(n)
- 所以 sc 命令默认限制 100 个结果（`-n 100`）
- 搜索子类时嵌套两层循环 → O(n * m)，更慢

### 3.3 ClassLoader 过滤

```java
// 按 ClassLoader hashCode 过滤
private static Set<Class<?>> filter(Set<Class<?>> matchedClasses, String code) {
    if (code == null) return matchedClasses;
    Set<Class<?>> result = new HashSet<>();
    for (Class<?> c : matchedClasses) {
        if (c.getClassLoader() != null
            && Integer.toHexString(c.getClassLoader().hashCode()).equals(code)) {
            result.add(c);
        }
    }
    return result;
}
```

**为什么需要按 ClassLoader 过滤？**

```
在复杂应用中（如 Tomcat 多 WebApp），同一个类可能被多个 ClassLoader 加载：

sc com.example.MyService
→ com.example.MyService  (classLoader: WebAppClassLoader@39eb305e)    ← WebApp A
→ com.example.MyService  (classLoader: WebAppClassLoader@7a5d012c)    ← WebApp B

sc -c 39eb305e com.example.MyService
→ com.example.MyService  (classLoader: WebAppClassLoader@39eb305e)    ← 只返回 WebApp A 的
```

---

## 4. sm 命令 — 搜索方法

### 4.1 核心逻辑

```java
// SearchMethodCommand.process()

// ① 搜索类（同 sc）
Set<Class<?>> matchedClasses = SearchUtils.searchClass(inst, classPattern, isRegEx, hashCode);

// ② 遍历每个类的方法
for (Class<?> clazz : matchedClasses) {
    // 构造方法
    for (Constructor<?> constructor : clazz.getDeclaredConstructors()) {
        if (methodNameMatcher.matching("<init>")) {
            MethodVO methodInfo = ClassUtils.createMethodInfo(constructor, clazz, isDetail);
            process.appendResult(new SearchMethodModel(methodInfo, isDetail));
        }
    }
    // 普通方法
    for (Method method : clazz.getDeclaredMethods()) {
        if (methodNameMatcher.matching(method.getName())) {
            MethodVO methodInfo = ClassUtils.createMethodInfo(method, clazz, isDetail);
            process.appendResult(new SearchMethodModel(methodInfo, isDetail));
        }
    }
}
```

**注意**：使用 `getDeclaredMethods()` 而非 `getMethods()`：
- `getDeclaredMethods()` 返回**当前类声明的**所有方法（包括 private），**不含继承的**
- `getMethods()` 返回所有 **public** 方法（包括继承的）
- Arthas 选择前者 → 更聚焦，不受父类干扰

---

## 5. dump 命令 — 导出字节码

### 5.1 核心逻辑

dump 命令和 jad 的 Step 4 完全一样——都是用 `ClassDumpTransformer` + `retransformClasses` 来拦截字节码：

```java
private Map<Class<?>, File> dump(Instrumentation inst, Set<Class<?>> classes) {
    ClassDumpTransformer transformer;
    if (directory != null) {
        transformer = new ClassDumpTransformer(classes, new File(directory));
    } else {
        transformer = new ClassDumpTransformer(classes);
    }
    InstrumentationUtils.retransformClasses(inst, transformer, classes);
    return transformer.getDumpResult();
    // → Map<Class<?>, File>：每个类对应的 .class 文件路径
}
```

**dump 和 jad 的区别**：
- dump 只做 Step 4（保存 .class 文件），不做 Step 5（不反编译）
- dump 支持批量（可以一次 dump 多个类）
- jad 的 dump 是临时的（反编译后文件就不管了），dump 命令的目的就是保存文件

---

## 6. InstrumentationUtils — retransform 工具类

```java
public static void retransformClasses(Instrumentation inst,
                                       ClassFileTransformer transformer,
                                       Set<Class<?>> classes) {
    try {
        // ① 注册临时 Transformer
        inst.addTransformer(transformer, true);

        // ② 逐个触发 retransform
        for (Class<?> clazz : classes) {
            if (ClassUtils.isLambdaClass(clazz)) {
                // ← JDK 不支持 retransform Lambda 类！
                // https://github.com/alibaba/arthas/issues/1512
                continue;
            }
            try {
                inst.retransformClasses(clazz);
            } catch (Throwable e) {
                logger.error("retransformClasses error: " + clazz.getName(), e);
            }
        }
    } finally {
        // ③ 必须移除！否则 Transformer 会永久存在
        inst.removeTransformer(transformer);
    }
}
```

**关键点**：

1. **Lambda 类不可 retransform** — 这是 JDK 的限制，不是 Arthas 的 bug
2. **try-finally 保证移除** — 如果不移除，每次类加载都会触发这个 Transformer
3. **逐个 retransform** — 一个类失败不影响其他类

---

## 7. 六个命令的对比总结

| 维度 | sc | sm | jad | dump | redefine | retransform |
|------|-----|-----|------|------|----------|-------------|
| **功能** | 搜索类 | 搜索方法 | 反编译 | 导出字节码 | 热更新 | 热更新 |
| **读/写** | 只读 | 只读 | 只读 | 只读 | **写** | **写** |
| **核心 API** | getAllLoadedClasses | getDeclaredMethods | retransformClasses + CFR | retransformClasses | redefineClasses | retransformClasses |
| **修改字节码** | ❌ | ❌ | ❌ | ❌ | ✅ 覆盖式 | ✅ 管道式 |
| **可逆** | — | — | — | — | ❌ | ✅ |
| **与增强兼容** | — | — | — | — | ❌ | ✅ |
| **ClassLoader 过滤** | ✅ -c | ✅ -c | ✅ -c | ✅ -c | ✅ -c | ✅ -c |
| **风险等级** | 🟢 无 | 🟢 无 | 🟢 无 | 🟢 无 | 🔴 高 | 🟡 中 |

### 7.1 典型使用流程

```bash
# ① 先用 sc 确认类是否已加载
$ sc com.example.MyService
 com.example.MyService

# ② 用 sc -d 看类的详情（ClassLoader、版本、路径）
$ sc -d com.example.MyService
 class-info        com.example.MyService
 code-source       /app/myservice.jar
 classLoaderHash   39eb305e
 classLoader       sun.misc.Launcher$AppClassLoader@39eb305e

# ③ 用 sm 看方法列表
$ sm com.example.MyService
 com.example.MyService <init>()V
 com.example.MyService doSomething(Ljava/lang/String;)V
 com.example.MyService calculate(II)I

# ④ 用 jad 反编译看源码
$ jad com.example.MyService doSomething

# ⑤ 发现 bug，本地修改后用 retransform 热更新
$ retransform /tmp/MyService.class
 retransform success, size: 1, classes:
 com.example.MyService

# ⑥ 验证修复后，清除热更新
$ retransform -l
 Id  ClassName                   TransformCount
 1   com.example.MyService       1

$ retransform -d 1
$ retransform --classPattern com.example.MyService
# → 触发 retransform，恢复原始字节码
```

---

## 8. 设计总结

### 8.1 核心设计决策

| # | 决策 | 选择 | 理由 |
|---|------|------|------|
| 1 | jad 获取字节码方式 | retransformClasses + Transformer 拦截 | 获取运行时真实字节码，而非磁盘原始字节码 |
| 2 | 反编译器 | CFR | 活跃维护，支持行号映射，Java 8+ 语法支持好 |
| 3 | 热更新推荐方式 | retransform（非 redefine） | 可逆、与增强命令兼容 |
| 4 | retransform 条目管理 | static List + 倒序遍历 | 后添加的优先级更高，支持增量更新 |
| 5 | retransform Transformer 位置 | TransformerManager.reTransformers（最前） | 保证替换后的字节码作为增强命令的输入 |
| 6 | 类搜索 | 全量遍历 + 通配符/正则 | 简单可靠，getAllLoadedClasses() 是 JDK 标准 API |

### 8.2 命令协作图

```
┌──────────────────────────────────────────────────────────────────────┐
│                        Instrumentation API                           │
│                                                                      │
│  getAllLoadedClasses()  ←─── sc / sm / jad / dump / redefine /       │
│                              retransform（查找目标类）               │
│                                                                      │
│  addTransformer() ─────┐                                             │
│                         │  ┌─────────────────────────────┐           │
│  retransformClasses() ──┼→│ ClassDumpTransformer (只读)  │←─ jad     │
│                         │  │ → 拦截字节码写入文件         │←─ dump    │
│                         │  │ → return null（不修改）      │           │
│                         │  └─────────────────────────────┘           │
│                         │                                            │
│                         │  ┌─────────────────────────────────┐       │
│                         ├→│ RetransformClassFileTransformer  │←─ retransform
│                         │  │ → 倒序查找 entry               │        │
│                         │  │ → return entry.getBytes()       │        │
│                         │  └─────────────────────────────────┘       │
│                         │                                            │
│  removeTransformer() ───┘                                            │
│                                                                      │
│  redefineClasses() ────────→ 直接替换字节码 ←──────── redefine       │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

---

> **下一节**: [Ch 10 profiler/火焰图](ch10_profiler_flame_graph.md) — Arthas 集成 async-profiler 实现 CPU/内存火焰图
