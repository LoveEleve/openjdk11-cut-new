
# Ch 11 vmtool — JVMTI Native 直通车

> 源文件:
> - `arthas-vmtool/src/main/java/arthas/VmTool.java` (131行) — Java 接口层
> - `arthas-vmtool/src/main/java/arthas/VmToolMXBean.java` (70行) — MXBean 接口
> - `arthas-vmtool/src/main/native/src/jni-library.cpp` (230行) — **C++ Native 实现（核心）**
> - `arthas-vmtool/target/native/include/arthas_VmTool.h` (77行) — JNI 头文件
> - `common/src/main/java/com/taobao/arthas/common/VmToolUtils.java` (36行) — 平台检测
> - `core/.../monitor200/VmToolCommand.java` (357行) — 命令入口
>
> HotSpot 对应源码:
> - `hotspot/share/prims/jvmtiEnv.cpp` — JVMTI 函数入口
> - `hotspot/share/prims/jvmtiTagMap.cpp` — 堆对象遍历 + Tag 机制

---

## 0. 本章概览 — vmtool 解决什么问题？

### 0.1 问题：Java API 的天花板

Arthas 的大多数命令都基于 Java API（MXBean、Instrumentation、反射），但有些事情 **Java 层根本做不到**：

| 需求 | Java API 能力 | 缺失原因 |
|------|-------------|---------|
| 获取某个类的所有活跃实例 | ❌ 不可能 | Java 没有"反向查找"能力 |
| 计算某个对象的精确内存大小 | ❌ 不可能 | `Instrumentation.getObjectSize()` 是浅层大小 |
| 强制触发 GC | ⚠️ `System.gc()` 只是建议 | JVM 可以忽略 |
| 获取所有已加载类 | ⚠️ `Instrumentation.getAllLoadedClasses()` | 有，但 vmtool 提供了 JVMTI 原生路径 |
| 释放 glibc 空闲内存 | ❌ 不可能 | 需要 Native 调用 `malloc_trim` |

**vmtool 的方案**：直接跳到 JVMTI（JVM Tool Interface）这一层，用 C++ JNI 调用 HotSpot 底层 API。

### 0.2 架构全景

```
┌─ 用户命令 ──────────────────────────────────────────────────────────────┐
│  vmtool --action getInstances --className demo.MathGame                │
└────────────────────────────┬────────────────────────────────────────────┘
                             │
┌─ Java 层 ─────────────────▼──────────────────────────────────────────┐
│  VmToolCommand.process()                                              │
│    ├── 解析 --action, --className, --express, --limit                 │
│    ├── SearchUtils.searchClassOnly() → 找到 Class<?> 对象             │
│    ├── vmToolInstance().getInstances(klass, limit)                     │
│    │           │                                                      │
│    │   ┌──────▼──────────┐                                            │
│    │   │ VmTool.java     │                                            │
│    │   │  (Java 单例)    │                                            │
│    │   │  getInstances() │──→ native getInstances0(klass, limit)      │
│    │   └──────│──────────┘                    │ JNI 边界              │
│    │          │                               │                       │
│    │          │    ┌──────────────────────────▼─────────────────┐     │
│    │          │    │ System.load("libArthasJniLibrary-x64.so")  │     │
│    │          │    └──────────────────────────┬─────────────────┘     │
│    │          │                               │                       │
│    └── OGNL 求值（可选）                       │                       │
│         express: 'instances.length'            │                       │
└────────────────────────────────────────────────│───────────────────────┘
                                                 │
┌─ C++ Native 层 (jni-library.cpp) ─────────────▼──────────────────────┐
│                                                                       │
│  static jvmtiEnv *jvmti;     ← JNI_OnLoad 时获取                     │
│  static jlong tagCounter;     ← 全局递增的 tag 值                     │
│                                                                       │
│  Java_arthas_VmTool_getInstances0(env, thisClass, klass, limit)       │
│    │                                                                  │
│    ├── ① tag = ++tagCounter                                           │
│    ├── ② limitCounter.init(limit)                                     │
│    ├── ③ jvmti->IterateOverInstancesOfClass(klass, callback, &tag)    │
│    │            │                                                     │
│    │   ┌───────▼────────────────────────────────────────────────┐     │
│    │   │  HeapObjectCallback(class_tag, size, tag_ptr, data)    │     │
│    │   │    *tag_ptr = tag;       // 给对象打 tag                │     │
│    │   │    limitCounter.countDown();                            │     │
│    │   │    return allow() ? CONTINUE : ABORT;                  │     │
│    │   └────────────────────────────────────────────────────────┘     │
│    │                                                                  │
│    ├── ④ jvmti->GetObjectsWithTags(1, &tag, &count, &instances)       │
│    │            // 根据 tag 值收集所有被标记的对象                      │
│    │                                                                  │
│    ├── ⑤ env->NewObjectArray(count, klass, NULL)                      │
│    │    // 创建 Java 数组，复制对象引用                                 │
│    │                                                                  │
│    └── ⑥ jvmti->Deallocate(instances)                                 │
│            // 释放 JVMTI 分配的 native 内存                            │
│                                                                       │
└───────────────────────────────────────────────────────────────────────┘
                             │
┌─ HotSpot JVMTI 层 ────────▼──────────────────────────────────────────┐
│                                                                       │
│  JvmtiEnv::IterateOverInstancesOfClass(k_mirror, filter, cb, data)    │
│    └── JvmtiTagMap::iterate_over_heap(filter, klass, cb, data)        │
│          └── VM_HeapIterateOperation op(&closure)                     │
│                └── VMThread::execute(&op)    ← 在 SafePoint 下执行！   │
│                      └── Universe::heap()->object_iterate(closure)    │
│                            // 遍历整个堆中的每一个对象                  │
│                            // 对每个对象调用 closure->do_object(o)      │
│                                                                       │
│  do_object(oop o):                                                    │
│    if (klass != NULL && !o->is_a(klass)) return;  // instanceof 过滤  │
│    control = callback(class_tag, size, tag_ptr, data);                │
│    if (control == ABORT) set_iteration_aborted(true);                 │
│                                                                       │
└───────────────────────────────────────────────────────────────────────┘
```

---

## 1. 三层架构详解

### 1.1 第一层：VmToolCommand（命令入口）

```java
public enum VmToolAction {
    getInstances,       // 获取实例
    forceGc,            // 强制 GC
    interruptThread,    // 中断指定线程
    mallocTrim,         // 释放 glibc 空闲内存
    mallocStats         // 打印 glibc 内存统计
}
```

**process() 的核心流程**：

```
vmtool --action getInstances --className demo.MathGame --express 'instances[0]' -x 2

Step 1: 解析 ClassLoader
──────────────────────────
  --classLoaderClass → ClassLoaderUtils.getClassLoaderByClassName()
  -c <hash>          → ClassLoaderUtils.getClassLoader(inst, hash)
  默认                → ClassLoader.getSystemClassLoader()

Step 2: 查找 Class 对象
──────────────────────────
  SearchUtils.searchClassOnly(inst, "demo.MathGame", false, hash)
  → 找到且只有一个 → 继续
  → 找到多个       → 报错，要求指定 ClassLoader
  → 找不到         → 报错

Step 3: JNI 调用获取实例
──────────────────────────
  Object[] instances = vmToolInstance().getInstances(matchedClasses.get(0), limit);
  → 进入 VmTool.java → 进入 C++ native

Step 4: OGNL 表达式求值（可选）
──────────────────────────
  if (express != null) {
      Express unpooledExpress = ExpressFactory.unpooledExpress(classLoader);
      value = unpooledExpress.bind(new InstancesWrapper(instances)).get(express);
      //                                  ↑ 将 instances 数组包装成变量
      // express = "instances[0]"    → 取第一个实例
      // express = "instances.length" → 取实例总数
      // express = "instances.{#this.field1}" → 提取所有实例的 field1
  }

Step 5: 结果输出
──────────────────────────
  VmToolModel model = new VmToolModel().setValue(new ObjectVO(value, expand));
  process.appendResult(model);
  //                                              ↑ expand 控制对象展开层数
```

**InstancesWrapper 的设计巧妙之处**：

```java
static class InstancesWrapper {
    Object instances;
    public Object getInstances() { return instances; }
    public void setInstances(Object instances) { this.instances = instances; }
}
```

为什么不直接把 `Object[]` 传给 OGNL？

因为 OGNL 的变量绑定需要一个 Java Bean 对象，通过 getter 访问属性。
用户写 `instances.length` → OGNL 解析为：
1. 先在绑定对象上找 `instances` 属性 → 调用 `getInstances()` → 获得 `Object[]`
2. 再访问 `.length` → 数组长度

### 1.2 第二层：VmTool.java（Java-Native 桥梁）

```java
public class VmTool implements VmToolMXBean {
    public final static String JNI_LIBRARY_NAME = "ArthasJniLibrary";
    private static VmTool instance;  // 单例

    // 8 个 native 方法声明（private，只通过包装方法暴露）
    private static synchronized native void forceGc0();
    private static synchronized native <T> T[] getInstances0(Class<T> klass, int limit);
    private static synchronized native long sumInstanceSize0(Class<?> klass);
    private static native long getInstanceSize0(Object instance);
    private static synchronized native long countInstances0(Class<?> klass);
    private static synchronized native Class<?>[] getAllLoadedClasses0(Class<?> klass);
    private static synchronized native int mallocTrim0();
    private static synchronized native boolean mallocStats0();
}
```

**关键设计决策**：

| # | 决策 | 原因 |
|---|------|------|
| 1 | 大部分 native 方法声明为 `synchronized` | 堆遍历操作**不可并发**（会导致 tag 冲突） |
| 2 | `getInstanceSize0` 没有 `synchronized` | 获取单个对象大小是线程安全的，不需要同步 |
| 3 | 单例模式（`getInstance`） | native 库只能加载一次，`System.load` 幂等性问题 |
| 4 | 加载方式用 `System.load(绝对路径)` | 避免依赖 `java.library.path`，更可控 |

**native 库加载的防御设计**：

```java
// VmToolCommand.vmToolInstance() 中：
private VmTool vmToolInstance() {
    if (vmTool != null) return vmTool;

    // ★ 关键：把 .so 文件复制到临时文件再加载！
    File tmpLibFile = File.createTempFile(VmTool.JNI_LIBRARY_NAME, null);
    IOUtils.copy(new FileInputStream(libPath), new FileOutputStream(tmpLibFile));
    libPath = tmpLibFile.getAbsolutePath();

    vmTool = VmTool.getInstance(libPath);
    return vmTool;
}
```

**为什么要复制到临时文件？**

```
问题：当 Arthas 多次 attach/detach 同一个 JVM 时

System.load("/path/to/libArthasJniLibrary.so")   ← 第一次：成功
// ... Arthas detach，ArthasClassLoader 被卸载 ...
System.load("/path/to/libArthasJniLibrary.so")   ← 第二次：
  → UnsatisfiedLinkError: Native Library already loaded in another classloader

原因：JVM 对同一路径的 native 库只允许一个 ClassLoader 加载
      即使旧的 ClassLoader 已卸载，路径仍然被记录

解决：每次都复制到新的临时文件
  /tmp/ArthasJniLibrary1234567890.tmp  ← 第一次
  /tmp/ArthasJniLibrary9876543210.tmp  ← 第二次
  → 路径不同，不会冲突！
```

### 1.3 第三层：jni-library.cpp（C++ Native 核心）

这是 vmtool 的灵魂所在，只有 230 行 C++ 代码，但功能极为强大。

#### 1.3.1 初始化 — 获取 JVMTI 环境

```cpp
static jvmtiEnv *jvmti;      // 全局 JVMTI 环境指针
static jlong tagCounter = 0;  // 全局递增 tag 计数器

// 三个入口都指向同一个 init_agent：
// Agent_OnLoad()   → 通过 -agentpath 启动时加载
// Agent_OnAttach() → 通过 Attach API 动态加载
// JNI_OnLoad()     → 通过 System.load() 加载（Arthas 走这条路）

int init_agent(JavaVM *vm, void *reserved) {
    // ① 获取 JVMTI 环境
    vm->GetEnv((void **)&jvmti, JVMTI_VERSION_1_2);

    // ② 申请 "给对象打 tag" 的能力
    jvmtiCapabilities capabilities = {0};
    capabilities.can_tag_objects = 1;     // ← 这是唯一需要的 capability
    jvmti->AddCapabilities(&capabilities);

    return JNI_OK;
}
```

**can_tag_objects** — 这个 capability 是什么？

```
JVMTI 的 "Tag" 机制：
━━━━━━━━━━━━━━━━━━━━━━

每个 Java 对象在 JVMTI 层面可以关联一个 jlong 类型的 "tag"（标签）。

默认情况下 tag = 0（未标记）。

核心 API：
  SetTag(object, tag)    → 给对象打标签
  GetTag(object) → tag   → 读取标签
  GetObjectsWithTags(tags[]) → objects[]  → 根据标签值批量收集对象

HotSpot 实现：
  JvmtiTagMap（哈希表）：<oop, jlong> 映射
  → 不在对象头中存储（不修改对象布局）
  → 而是维护一个外部哈希表
```

#### 1.3.2 getInstances0 — 堆遍历核心算法

这是 vmtool 最重要的函数，我们逐行解析：

```cpp
JNIEXPORT jobjectArray JNICALL
Java_arthas_VmTool_getInstances0(JNIEnv *env, jclass thisClass, jclass klass, jint limit) {

    // ① 生成唯一 tag 值
    jlong tag = getTag();   // ++tagCounter，每次调用都不同
    //                         → 避免不同调用之间的 tag 冲突

    // ② 初始化数量限制器
    limitCounter.init(limit);
    // limit = -1 → 无限制
    // limit = 10 → 最多标记 10 个对象

    // ③ 遍历堆中 klass 的所有实例，对每个实例执行回调
    jvmtiError error = jvmti->IterateOverInstancesOfClass(
        klass,                          // 目标类
        JVMTI_HEAP_OBJECT_EITHER,       // 不管有没有 tag 都遍历
        HeapObjectCallback,             // 每个实例的回调函数
        &tag                            // 传给回调的用户数据（tag 值）
    );

    // ④ 根据 tag 值收集所有被标记的对象
    jint count = 0;
    jobject *instances;
    error = jvmti->GetObjectsWithTags(
        1,           // tag 数组长度
        &tag,        // tag 数组
        &count,      // [out] 找到的对象数量
        &instances,  // [out] 对象数组（JVMTI 分配的内存）
        NULL         // 不需要 tag 结果
    );

    // ⑤ 把 native 数组转成 Java 数组
    jobjectArray array = env->NewObjectArray(count, klass, NULL);
    for (int i = 0; i < count; i++) {
        env->SetObjectArrayElement(array, i, instances[i]);
    }

    // ⑥ 释放 JVMTI 分配的内存
    jvmti->Deallocate(reinterpret_cast<unsigned char *>(instances));

    return array;
}
```

**HeapObjectCallback — 每个对象的回调**：

```cpp
jvmtiIterationControl JNICALL
HeapObjectCallback(jlong class_tag, jlong size, jlong *tag_ptr, void *user_data) {
    jlong *data = static_cast<jlong *>(user_data);

    *tag_ptr = *data;           // 给这个对象打上 tag（写入 JvmtiTagMap）

    limitCounter.countDown();    // 计数 -1
    if (limitCounter.allow()) {
        return JVMTI_ITERATION_CONTINUE;  // 继续遍历
    } else {
        return JVMTI_ITERATION_ABORT;     // 达到 limit，停止遍历
    }
}
```

**完整时序图**：

```
时间 →
─────────────────────────────────────────────────────────────────────────

Java Thread (调用方)          VMThread (SafePoint)           堆内存
──────────────              ─────────────────              ─────────
  │                             │                            │
  │ getInstances0(klass, 10)    │                            │
  │──┐                          │                            │
  │  │ IterateOverInstancesOfClass(klass, cb, &tag)          │
  │  │─────────────────────────→│                            │
  │  │                          │ VM_HeapIterateOperation     │
  │  │                          │ (需要 SafePoint!)           │
  │  │                          │                            │
  │  │  ★ STW 开始              │ ensure_parsability()       │
  │  │  所有Java线程暂停        │ → 填充 TLAB 空隙           │
  │  │                          │                            │
  │  │                          │ object_iterate(closure)    │
  │  │                          │─────────────────────────→  │ obj1 (String)
  │  │                          │  is_a(klass)? NO → skip    │
  │  │                          │─────────────────────────→  │ obj2 (MathGame)
  │  │                          │  is_a(klass)? YES          │
  │  │                          │  → callback → tag = 42     │
  │  │                          │  → count: 1/10             │
  │  │                          │─────────────────────────→  │ obj3 (byte[])
  │  │                          │  is_a(klass)? NO → skip    │
  │  │                          │─────────────────────────→  │ obj4 (MathGame)
  │  │                          │  is_a(klass)? YES          │
  │  │                          │  → callback → tag = 42     │
  │  │                          │  → count: 2/10             │
  │  │                          │        ...                 │
  │  │                          │  → 遍历完整个堆或达到 limit │
  │  │                          │                            │
  │  │  ★ STW 结束              │                            │
  │  │  Java线程恢复            │                            │
  │  │                          │                            │
  │  │ GetObjectsWithTags(&42)  │                            │
  │  │─────────────────────────→│                            │
  │  │                          │ 查询 JvmtiTagMap           │
  │  │                          │ → 找到 tag=42 的所有对象    │
  │  │←─────────────────────────│ 返回 {obj2, obj4}          │
  │  │                          │                            │
  │  │ NewObjectArray(2, klass) │                            │
  │  │ 复制引用到 Java 数组      │                            │
  │  │ Deallocate(instances)    │                            │
  │←─┘                          │                            │
  │ return Object[]{obj2,obj4}  │                            │
```

#### 1.3.3 LimitCounter — 简单但关键的限流

```cpp
struct LimitCounter {
    jint currentCounter;
    jint limitValue;

    void init(jint limit) {
        currentCounter = 0;
        limitValue = limit;
    }

    void countDown() { currentCounter++; }

    bool allow() {
        if (limitValue < 0) return true;    // -1 = 无限制
        return limitValue > currentCounter;
    }
};

static LimitCounter limitCounter = {0, 0};  // ← 全局静态，所以 native 方法需要 synchronized
```

**为什么需要 limit？**

```
场景：vmtool --action getInstances --className java.lang.String

如果不限制：
  String 在 JVM 中可能有数百万个实例
  → 遍历整个堆需要很长时间（STW！）
  → 创建数百万元素的数组可能 OOM
  → 传输到客户端更慢

加上 --limit 10：
  → 遍历到第 10 个就停止（JVMTI_ITERATION_ABORT）
  → STW 时间大大缩短
  → 结果集可控
```

#### 1.3.4 其他 native 方法

```cpp
// forceGc — 一行代码！
void Java_arthas_VmTool_forceGc0(JNIEnv *env, jclass thisClass) {
    jvmti->ForceGarbageCollection();
    // ← 与 System.gc() 的区别：
    //    System.gc() 只是建议，JVM 可以忽略（-XX:+DisableExplicitGC）
    //    JVMTI ForceGarbageCollection 是 **强制** 的，JVM 必须执行
}

// sumInstanceSize — 遍历所有实例，累加对象大小
long Java_arthas_VmTool_sumInstanceSize0(JNIEnv *env, jclass thisClass, jclass klass) {
    // ① 遍历堆，给所有 klass 实例打 tag
    jvmti->IterateOverInstancesOfClass(klass, JVMTI_HEAP_OBJECT_EITHER, callback, &tag);
    // ② 收集被 tag 的对象
    jvmti->GetObjectsWithTags(1, &tag, &count, &instances, NULL);
    // ③ 逐个获取对象大小并累加
    for (int i = 0; i < count; i++) {
        jlong size = 0;
        jvmti->GetObjectSize(instances[i], &size);
        sum += size;
    }
    return sum;
}

// getInstanceSize — 单个对象
long Java_arthas_VmTool_getInstanceSize0(JNIEnv *env, jclass thisClass, jobject instance) {
    jlong size = -1;
    jvmti->GetObjectSize(instance, &size);
    return size;
}

// countInstances — 只要数量，不要对象引用
long Java_arthas_VmTool_countInstances0(JNIEnv *env, jclass thisClass, jclass klass) {
    jvmti->IterateOverInstancesOfClass(klass, JVMTI_HEAP_OBJECT_EITHER, callback, &tag);
    jvmti->GetObjectsWithTags(1, &tag, &count, NULL, NULL);  // ← 不要 object 结果
    return count;
}

// getAllLoadedClasses — 获取所有已加载的类
jobjectArray Java_arthas_VmTool_getAllLoadedClasses0(JNIEnv *env, jclass thisClass, jclass kclass) {
    jclass *classes;
    jint count = 0;
    jvmti->GetLoadedClasses(&count, &classes);
    // → 底层读取 SystemDictionary 中所有已加载的 Klass
    // → 转成 jclass (JNI handle) 返回
    jobjectArray array = env->NewObjectArray(count, kclass, NULL);
    for (int i = 0; i < count; i++) {
        env->SetObjectArrayElement(array, i, classes[i]);
    }
    jvmti->Deallocate(reinterpret_cast<unsigned char *>(classes));
    return array;
}

// mallocTrim — glibc 特有，释放空闲内存回 OS
jint Java_arthas_VmTool_mallocTrim0(JNIEnv *env, jclass thisClass) {
#ifdef __GLIBC__
    return ::malloc_trim(0);  // 返回 1 表示成功释放了内存
#endif
    return -1;  // 非 glibc 平台不支持
}

// mallocStats — 打印 glibc 内存分配统计到 stderr
jboolean Java_arthas_VmTool_mallocStats0(JNIEnv *env, jclass thisClass) {
#ifdef __GLIBC__
    ::malloc_stats();  // 输出到 stderr，不是 stdout
    return JNI_TRUE;
#else
    return JNI_FALSE;
#endif
}
```

---

## 2. HotSpot JVMTI 底层实现

### 2.1 IterateOverInstancesOfClass — 堆遍历的真相

当 C++ 层调用 `jvmti->IterateOverInstancesOfClass(klass, filter, callback, data)` 时，HotSpot 内部发生了什么？

```
JvmtiEnv::IterateOverInstancesOfClass(k_mirror, filter, callback, data)
│
├── 安全检查
│   if (java_lang_Class::is_primitive(k_mirror)) return;  // 基本类型无实例
│   Klass* klass = java_lang_Class::as_Klass(k_mirror);
│   if (klass == NULL) return JVMTI_ERROR_INVALID_CLASS;
│
├── JvmtiTagMap::iterate_over_heap(filter, klass, callback, data)
│   │
│   ├── MutexLocker ml(Heap_lock);    // ← 获取堆锁
│   │
│   ├── 创建 IterateOverHeapObjectClosure（封装回调逻辑）
│   │
│   ├── VM_HeapIterateOperation op(&closure);
│   │   └── VMThread::execute(&op);   // ← 提交到 VMThread 执行！
│   │
│   └── VM_HeapIterateOperation::doit()   // 在 SafePoint 下执行
│       │
│       ├── Universe::heap()->ensure_parsability(false);
│       │   // 填充所有 TLAB 的空隙
│       │   // 否则遍历时可能遇到未初始化的内存
│       │
│       ├── if (VerifyBeforeIteration) Universe::verify();
│       │   // 可选：遍历前验证堆完整性
│       │
│       └── Universe::heap()->object_iterate(&closure);
│           // ★ 遍历整个堆中的每一个对象
│           // G1: 遍历每个 Region 的 [bottom, top) 区间
│           // 对每个对象 o 调用 closure->do_object(o)
│
└── IterateOverHeapObjectClosure::do_object(oop o)
    │
    ├── if (is_iteration_aborted()) return;  // 已中止
    │
    ├── if (klass != NULL && !o->is_a(klass)) return;
    │   // instanceof 检查：o 必须是 klass 的实例（含子类）
    │   // o->is_a(klass) 检查 o 的 Klass 是否是 klass 或其子类
    │
    ├── CallbackWrapper wrapper(tag_map, o);
    │   // 从 JvmtiTagMap 查找 o 的当前 tag
    │   // 同时计算 class_tag 和 obj_size
    │
    ├── tag 过滤
    │   if (tag != 0 && filter == UNTAGGED) return;
    │   if (tag == 0 && filter == TAGGED) return;
    │   // JVMTI_HEAP_OBJECT_EITHER → 不过滤（Arthas 用的就是这个）
    │
    └── control = callback(class_tag, obj_size, tag_ptr, user_data);
        // 调用 Arthas 注册的 HeapObjectCallback
        // HeapObjectCallback 会写入 *tag_ptr = tag
        // → 这会更新 JvmtiTagMap 中该对象的 tag
        if (control == JVMTI_ITERATION_ABORT)
            set_iteration_aborted(true);
```

### 2.2 ⚠️ 性能影响分析

```
┌─────────────────────────────────────────────────────────────────────┐
│                      vmtool getInstances 的代价                      │
│                                                                      │
│  1. STW (Stop-The-World)                                             │
│     ━━━━━━━━━━━━━━━━━━━━━                                           │
│     堆遍历必须在 SafePoint 下执行                                     │
│     → 所有 Java 线程暂停                                              │
│     → STW 时间 ∝ 堆中对象数量（不是堆大小！）                          │
│                                                                      │
│     8GB 堆, 1000万对象: 可能 STW 数百毫秒                             │
│     8GB 堆, 1亿对象: 可能 STW 数秒！                                  │
│                                                                      │
│  2. --limit 的救命作用                                                │
│     ━━━━━━━━━━━━━━━━━━━━                                            │
│     即使有 limit，也需要遍历到第 N 个匹配对象                          │
│     如果目标类实例很少，仍然可能遍历大部分堆                            │
│     最差情况：只有 1 个实例在堆末尾 → 遍历整个堆                       │
│                                                                      │
│  3. 内存开销                                                          │
│     ━━━━━━━━━━━━                                                    │
│     JvmtiTagMap 为每个被 tag 的对象维护一个哈希表条目                   │
│     GetObjectsWithTags 会分配 native 内存存放结果                     │
│     NewObjectArray 在 Java 堆中分配结果数组                            │
│                                                                      │
│  ★ 生产环境建议                                                       │
│    • 始终指定 --limit（默认 10，合理）                                 │
│    • 避免对 String、byte[] 等超高频类使用                              │
│    • 大堆环境谨慎使用（>16GB 时 STW 可能很长）                         │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.3 ForceGarbageCollection — 强制 GC

```cpp
// HotSpot 源码 (jvmtiEnv.cpp):
jvmtiError JvmtiEnv::ForceGarbageCollection() {
    Universe::heap()->collect(GCCause::_jvmti_force_gc);
    return JVMTI_ERROR_NONE;
}
```

**与 System.gc() 的本质区别**：

```
System.gc()
└── Runtime.gc()
    └── JVM_GC()                        // hotspot/share/prims/jvm.cpp
        └── Universe::heap()->collect(GCCause::_java_lang_system_gc);
            └── if (DisableExplicitGC) return;  // ← 可以被禁用！

JVMTI ForceGarbageCollection()
└── Universe::heap()->collect(GCCause::_jvmti_force_gc);
    └── 无条件执行，不受 DisableExplicitGC 影响
    //   GCCause::_jvmti_force_gc 不在 DisableExplicitGC 的检查路径中
```

**使用场景**：
- 排查内存泄漏前，先强制 GC，确保 dump 中没有垃圾对象
- 配合 `vmtool getInstances` 使用：先 forceGc 再 getInstances，结果更准确
- 生产环境中 `-XX:+DisableExplicitGC` 时，这是唯一的强制 GC 手段

---

## 3. 跨平台 native 库加载

### 3.1 平台检测

```java
// VmToolUtils.java
static {
    if (OSUtils.isMac())    libName = "libArthasJniLibrary.dylib";
    if (OSUtils.isLinux()) {
        if (OSUtils.isArm32())   libName = "libArthasJniLibrary-arm.so";
        if (OSUtils.isArm64())   libName = "libArthasJniLibrary-aarch64.so";
        if (OSUtils.isX86_64())  libName = "libArthasJniLibrary-x64.so";
        else libName = "libArthasJniLibrary-" + OSUtils.arch() + ".so";
    }
    if (OSUtils.isWindows()) libName = "libArthasJniLibrary-x64.dll";
}
```

### 3.2 加载路径解析

```
VmToolCommand.class
    .getProtectionDomain()
    .getCodeSource()
    .getLocation()
    → file:/path/to/arthas-core.jar
    → bootJarPath = /path/to/arthas-core.jar
    → soFile = /path/to/lib/libArthasJniLibrary-x64.so
```

### 3.3 完整加载链

```
VmToolCommand 首次使用
│
├── static {} 静态初始化
│   ├── VmToolUtils.detectLibName()
│   │   → "libArthasJniLibrary-x64.so"
│   └── 定位 .so 文件路径
│       → defaultLibPath = "/path/to/lib/libArthasJniLibrary-x64.so"
│
├── vmToolInstance()
│   ├── 复制 .so 到临时文件（防 "already loaded" 错误）
│   │   → /tmp/ArthasJniLibrary123456.tmp
│   │
│   └── VmTool.getInstance("/tmp/ArthasJniLibrary123456.tmp")
│       ├── System.load("/tmp/ArthasJniLibrary123456.tmp")
│       │   → 触发 JNI_OnLoad()
│       │     → init_agent()
│       │       → vm->GetEnv(&jvmti)
│       │       → jvmti->AddCapabilities({can_tag_objects=1})
│       │
│       └── instance = new VmTool()
│           → 后续所有调用复用此 instance
```

---

## 4. interruptThread — 纯 Java 实现

有趣的是，`interruptThread` 是 vmtool 中 **唯一不需要 native 调用** 的 action：

```java
@Override
public void interruptSpecialThread(int threadId) {
    Map<Thread, StackTraceElement[]> allThread = Thread.getAllStackTraces();
    for (Map.Entry<Thread, StackTraceElement[]> entry : allThread.entrySet()) {
        if (entry.getKey().getId() == threadId) {
            entry.getKey().interrupt();  // ← 纯 Java API
            return;
        }
    }
}
```

**为什么放在 vmtool 而不是 thread 命令？**

因为 `thread` 命令是只读的（观察），而 `interruptThread` 是**有副作用的操作**（修改），放在 vmtool 更符合语义——vmtool 就是"对 JVM 做操作"的工具。

---

## 5. mallocTrim / mallocStats — glibc 内存管理

### 5.1 问题背景

```
Java 应用的内存 = JVM 堆 + 非堆（Metaspace、线程栈、Code Cache）+ Native 内存

Native 内存由 glibc 的 malloc 管理，存在一个问题：
  → glibc 的 malloc 会缓存释放的内存（arena/bin 机制）
  → 即使 Java 代码释放了大量 native 内存，RSS 也不会下降
  → 因为 glibc 没有把这些内存归还给 OS

表现：
  jcmd <pid> VM.native_memory → Native Memory 已释放
  top/ps → RSS 居高不下
  
  → 这就是 "RSS 虚高" 问题
```

### 5.2 mallocTrim 的作用

```cpp
#ifdef __GLIBC__
    return ::malloc_trim(0);
    // malloc_trim(pad)：
    //   释放 glibc 缓存的空闲内存回 OS
    //   pad = 0 → 尽可能多地释放
    //   返回 1 → 成功释放了一些内存
    //   返回 0 → 没有可释放的内存
#endif
```

**使用场景**：
```bash
# RSS 异常高，怀疑是 glibc 缓存导致
vmtool --action mallocTrim
# → "mallocTrim result: true"
# → RSS 应该会下降
```

### 5.3 mallocStats 的作用

```cpp
#ifdef __GLIBC__
    ::malloc_stats();
    // 输出 glibc 内存分配器的统计信息到 stderr
    // 包括：
    //   Arena 数量和大小
    //   正在使用的内存
    //   mmap 分配的大小
    //   空闲的内存
#endif
```

**注意**：输出到**目标 JVM 进程的 stderr**，不是 Arthas 终端！需要到 JVM 的 stderr 日志中查看。

---

## 6. 设计总结

### 6.1 vmtool 的核心价值

```
                          Java API 天花板
                                │
                                │  getInstances    → JVMTI IterateOverInstancesOfClass
    vmtool 打破了               │  forceGc         → JVMTI ForceGarbageCollection
    Java API 的限制  ───────────┤  getInstanceSize → JVMTI GetObjectSize
                                │  getAllLoadedClasses → JVMTI GetLoadedClasses
                                │  mallocTrim      → glibc malloc_trim
                                │  mallocStats     → glibc malloc_stats
                                │
                          C/C++ Native 层
```

### 6.2 关键设计决策

| # | 决策 | 选择 | 理由 |
|---|------|------|------|
| 1 | 堆遍历方式 | Tag + GetObjectsWithTags 两阶段 | JVMTI 标准模式，不能直接在回调中创建 JNI 引用 |
| 2 | 并发控制 | synchronized + 全局 LimitCounter | 简单可靠，堆遍历本身就是串行的 |
| 3 | native 库加载 | 复制到临时文件再 System.load | 解决多次 attach 时的 "already loaded" 问题 |
| 4 | tag 唯一性 | 全局递增 tagCounter | 避免不同调用间的 tag 冲突 |
| 5 | limit 机制 | 回调中 ABORT | 提前终止遍历，减少 STW 时间 |
| 6 | forceGc 路径 | JVMTI 而非 System.gc() | 不受 DisableExplicitGC 限制 |
| 7 | JDK 兼容性 | 仅用 JVMTI 1.2 标准 API | JDK 6+ 全兼容 |

### 6.3 与同类工具的对比

| 功能 | vmtool | jmap -histo | jcmd GC.class_histogram | MAT |
|------|--------|-------------|-------------------------|-----|
| 获取实例引用 | ✅ 可直接操作 | ❌ 只有统计 | ❌ 只有统计 | ✅ 离线分析 |
| 在线操作实例 | ✅ OGNL 表达式 | ❌ | ❌ | ❌ |
| 强制 GC | ✅ 不可禁用 | ❌ | ⚠️ 可被禁用 | ❌ |
| 实时性 | ✅ 在线 | ✅ 在线 | ✅ 在线 | ❌ 离线 |
| STW 影响 | 有 | 有 | 有 | 无（离线） |

### 6.4 典型使用场景

```bash
# ① 获取 Spring ApplicationContext（最经典的用法）
vmtool --action getInstances \
       --classLoaderClass org.springframework.boot.loader.LaunchedURLClassLoader \
       --className org.springframework.context.ApplicationContext \
       --express 'instances[0].getBean("userService").findById(42)'
# → 直接调用 Spring Bean 的方法！无需写任何测试代码

# ② 统计某个类的实例数量（排查内存泄漏）
vmtool --action getInstances --className com.example.CacheEntry --express 'instances.length'
# → 42857（预期应该只有几百个 → 确认泄漏）

# ③ 查看某个单例的状态
vmtool --action getInstances --className com.example.ConfigManager -x 3
# → 展开 3 层，查看配置管理器的完整状态

# ④ 容器环境释放 RSS
vmtool --action forceGc        # 先强制 GC
vmtool --action mallocTrim     # 再释放 glibc 缓存
# → RSS 下降到合理水平
```

---

> **下一节**: [Ch 12 profiler — async-profiler 集成](ch12_profiler_flame_graph.md) — CPU/内存火焰图的实现
