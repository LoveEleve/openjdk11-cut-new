
# Ch 8 tt 命令 — 时间隧道

> 源文件:
> - `monitor200/TimeTunnelCommand.java` (545行) — 命令主体（7 种操作模式）
> - `monitor200/TimeTunnelAdviceListener.java` (159行) — 录制逻辑 + ObjectStack
> - `monitor200/TimeFragment.java` (33行) — 时间碎片数据结构
> - `advisor/ArthasMethod.java` (167行) — 反射重放引擎
> - `advisor/Advice.java` (140行) — 调用上下文快照

---

## 0. tt 是什么？解决什么问题？

### 0.1 watch 的局限

```bash
watch com.example.MyService doSomething '{params, returnObj}'
```

watch 的问题是：**数据即时输出，用完即弃**。

- 想再看一下 3 分钟前的那次调用？——不行，数据已经打印过了
- 想用不同的 OGNL 表达式重新观察同一次调用？——不行，得重新执行
- 想用**完全相同的参数**再调用一次这个方法？——不行，参数没保留
- 某个 bug 偶尔出现一次，想对着调用数据反复分析？——不行

### 0.2 tt 的解决方案

**tt = Time Tunnel（时间隧道）**，核心思想是：

```
watch 模式:  方法调用 → 即时输出 → 丢弃
tt 模式:     方法调用 → 录制到内存 → 随时回看/搜索/重放
```

tt 把每次方法调用的**完整上下文**（target、params、returnObj/throwExp、耗时、时间戳）都保存在一个 `LinkedHashMap` 中，用一个递增的序号索引。之后可以：

| 操作 | 命令 | 说明 |
|------|------|------|
| 录制 | `tt -t *MyService doSomething` | 每次调用都录制一个时间碎片 |
| 列表 | `tt -l` | 查看所有已录制的时间碎片 |
| 查看 | `tt -i 1003` | 查看序号 1003 的详细信息 |
| 观察 | `tt -i 1003 -w 'params[0]'` | 用 OGNL 表达式观察指定碎片 |
| 搜索 | `tt -s '{params[0] > 1}' -w '{params}'` | 搜索满足条件的碎片 |
| **重放** | `tt -i 1003 -p` | 用原始参数**重新调用**方法！ |
| 多次重放 | `tt -i 1003 -p --replay-times 3` | 重放 3 次 |
| 删除 | `tt -i 1003 -d` | 删除指定碎片 |
| 清空 | `tt --delete-all` | 清空所有碎片 |

---

## 1. 架构概览

### 1.1 继承关系

```
EnhancerCommand
    └── TimeTunnelCommand
            ├── 录制模式（-t）→ enhance() → TimeTunnelAdviceListener
            ├── 列表模式（-l）→ processList()
            ├── 查看模式（-i）→ processShow()
            ├── 观察模式（-i -w）→ processWatch()
            ├── 搜索模式（-s）→ processSearch()
            ├── 重放模式（-i -p）→ processPlay()
            ├── 删除模式（-i -d）→ processDelete()
            └── 清空模式（--delete-all）→ processDeleteAll()
```

### 1.2 核心数据结构

```
TimeTunnelCommand
│
├── timeFragmentMap: LinkedHashMap<Integer, TimeFragment>  ← 静态！全局唯一
│     │
│     │  key = 序号（1000, 1001, 1002, ...）
│     │  value = TimeFragment
│     │           ├── advice: Advice                ← 调用上下文快照
│     │           │    ├── loader: ClassLoader
│     │           │    ├── clazz: Class<?>
│     │           │    ├── method: ArthasMethod      ← 重放时用
│     │           │    ├── target: Object             ← this 指针
│     │           │    ├── params: Object[]            ← 入参数组
│     │           │    ├── returnObj: Object           ← 返回值
│     │           │    └── throwExp: Throwable         ← 异常
│     │           ├── gmtCreate: LocalDateTime        ← 录制时间
│     │           └── cost: double                    ← 方法耗时(ms)
│     │
│     └── 有序（LinkedHashMap）→ 按录制顺序排列
│
└── sequence: AtomicInteger(1000)   ← 序号生成器
```

**关键设计决策**：

1. **static 字段**：`timeFragmentMap` 和 `sequence` 都是 `static`，意味着**跨命令共享**。第一次 `tt -t` 录制的数据，第二次 `tt -l` 可以看到
2. **LinkedHashMap**：保持插入顺序，`tt -l` 按时间顺序展示
3. **序号从 1000 开始**：避免和其他 ID（如 listenerId）混淆
4. **保存原始引用**：params/target/returnObj 保存的是**对象引用**，不是深拷贝

### 1.3 第 4 点的隐患

```
⚠️ tt 保存的是对象引用，不是深拷贝！

如果目标方法修改了入参对象的字段，tt 中保存的也会变。
如果 GC 回收了目标对象（target 不再被其他地方引用），tt 中的引用会防止 GC。

→ 长时间录制可能导致内存泄漏！这是有意为之的 trade-off：
   深拷贝成本太高（需要序列化整个对象图），而且不一定能拷贝（某些对象不可序列化）。
   所以 tt 选择保存引用 + 提供 --delete-all 清理能力。
```

---

## 2. 录制模式 — TimeTunnelAdviceListener

### 2.1 process() 路由

```java
public void process(final CommandProcess process) {
    checkArguments();
    // ...
    if (isTimeTunnel) {
        enhance(process);         // ← 调用 EnhancerCommand.enhance()
    } else if (isPlay) {
        processPlay(process);     // ← 重放
    } else if (isList) {
        processList(process);     // ← 列表
    }
    // ... 其他模式
}
```

当 `-t` 时，走 `enhance(process)`（继承自 EnhancerCommand），创建 `TimeTunnelAdviceListener` 进行录制。

### 2.2 TimeTunnelAdviceListener — 录制核心

```java
public class TimeTunnelAdviceListener extends AdviceListenerAdapter {

    // ① 入参快照栈（ThreadLocal + 固定大小）
    private final ThreadLocal<ObjectStack> argsRef = new ThreadLocal<ObjectStack>() {
        @Override
        protected ObjectStack initialValue() {
            return new ObjectStack(512);
        }
    };

    private volatile boolean isFirst = true;    // 第一次输出时带表头
    private final ThreadLocalWatch threadLocalWatch = new ThreadLocalWatch();

    // ========= 方法入口 =========
    @Override
    public void before(ClassLoader loader, Class<?> clazz, ArthasMethod method,
                       Object target, Object[] args) throws Throwable {
        argsRef.get().push(args);    // ② 保存入参快照！
        threadLocalWatch.start();    // ③ 开始计时
    }

    // ========= 正常返回 =========
    @Override
    public void afterReturning(..., Object returnObject) throws Throwable {
        args = (Object[]) argsRef.get().pop();  // ④ 取出入口时的 args！
        afterFinishing(Advice.newForAfterReturning(loader, clazz, method, target, args, returnObject));
    }

    // ========= 异常返回 =========
    @Override
    public void afterThrowing(..., Throwable throwable) {
        args = (Object[]) argsRef.get().pop();  // ⑤ 同上
        afterFinishing(Advice.newForAfterThrowing(loader, clazz, method, target, args, throwable));
    }
}
```

### 2.3 为什么需要 argsRef（入参快照）？

```java
// 目标方法可能这样写：
public void doSomething(List<String> items) {
    items.add("new item");     // ← 修改了入参！
    items.clear();             // ← 又修改了！
    // ...
}
```

如果不在 `before` 时保存 `args` 引用，`afterReturning` 拿到的 `args` 已经被方法内部修改了。

但注意：**这里保存的仍然是引用**——如果方法修改了 `args[0]` 指向的对象的**内部字段**，tt 中看到的也是修改后的值。Arthas 只保存了**数组引用**，不做深拷贝。

### 2.4 afterFinishing() — 录制逻辑

```java
private void afterFinishing(Advice advice) {
    double cost = threadLocalWatch.costInMillis();

    // ① 创建时间碎片
    TimeFragment timeTunnel = new TimeFragment(advice, LocalDateTime.now(), cost);

    // ② OGNL 条件过滤
    boolean match = false;
    try {
        match = isConditionMet(command.getConditionExpress(), advice, cost);
    } catch (ExpressException e) {
        process.end(-1, "tt failed, condition is: ...");
    }

    if (!match) {
        return;   // 不匹配条件 → 跳过，不录制
    }

    // ③ 存入全局 Map（关键！）
    int index = command.putTimeTunnel(timeTunnel);

    // ④ 输出到终端（带序号）
    TimeFragmentVO timeFragmentVO = TimeTunnelCommand.createTimeFragmentVO(index, timeTunnel, command.getExpand());
    TimeTunnelModel timeTunnelModel = new TimeTunnelModel()
            .setTimeFragmentList(Collections.singletonList(timeFragmentVO))
            .setFirst(isFirst);     // 第一次输出带表头
    process.appendResult(timeTunnelModel);

    if (isFirst) {
        isFirst = false;            // 后续不再输出表头
    }

    // ⑤ 次数限制
    process.times().incrementAndGet();
    if (isLimitExceeded(command.getNumberOfLimit(), process.times().get())) {
        abortProcess(process, command.getNumberOfLimit());
    }
}
```

### 2.5 putTimeTunnel() — 序号分配

```java
int putTimeTunnel(TimeFragment tt) {
    int indexOfSeq = sequence.getAndIncrement();   // 原子递增
    timeFragmentMap.put(indexOfSeq, tt);
    return indexOfSeq;
}
```

**注意**：这里有一个源码中的 TODO 注释：`// TODO 并非线程安全？`

**分析**：
- `sequence.getAndIncrement()` 是原子的 → 序号不会重复 ✓
- `timeFragmentMap.put()` 操作的是 `LinkedHashMap`（非线程安全） → **多线程同时录制时可能数据错乱** ✗
- 但实际场景中，同一个 Session 同一时间只有一个增强（`session.tryLock()`），所以问题不大
- 如果多个 Session 同时 tt 同一个方法，理论上可能有问题，但概率极低

### 2.6 录制完整数据流

```
用户输入: tt -t com.example.MyService doSomething -n 5

                        增强阶段
                        ────────
TimeTunnelCommand.process()
  → isTimeTunnel = true
  → enhance(process)
    → new TimeTunnelAdviceListener(command, process)
    → new Enhancer(listener, isTracing=false, ...)
    → enhancer.enhance(inst, 50)
    → "Affect(class count: 1, method count: 1)"

                        运行时（每次调用录制）
                        ────────────────────

目标应用线程调用 doSomething("hello"):
  → SpyAPI.atEnter(...)
    → listener.before(loader, clazz, method, this, ["hello"])
      → argsRef.push(["hello"])         ← 保存入参快照
      → threadLocalWatch.start()        ← 开始计时

  → doSomething 执行原始逻辑...
  → return "result"

  → SpyAPI.atExit(...)
    → listener.afterReturning(loader, clazz, method, this, args, "result")
      → args = argsRef.pop()            ← 取出入口时的 args
      → afterFinishing(Advice{target=this, params=["hello"], returnObj="result"})
        → cost = 23.5ms
        → TimeFragment{advice, now(), 23.5}
        → isConditionMet(null, advice, 23.5) → true
        → index = sequence.getAndIncrement() = 1000
        → timeFragmentMap.put(1000, fragment)
        → process.appendResult(...)

终端输出:
 INDEX  TIMESTAMP            COST(ms)  IS-RET  IS-EXP  OBJECT      CLASS                    METHOD
 1000   2026-02-10 14:00:00  23.5      true    false   0x1a2b3c    com.example.MyService    doSomething
```

---

## 3. ObjectStack — 固定大小的环形栈

### 3.1 为什么不用 java.util.Stack？

```java
static class ObjectStack {
    private Object[] array;
    private int pos = 0;
    private int cap;

    public ObjectStack(int maxSize) {
        array = new Object[maxSize];   // 固定 512
        cap = array.length;
    }
}
```

**问题场景**：

```
方法 A() {
    → push(args_A)        // before A
    方法 B() {
        → push(args_B)    // before B
        → pop()           // after B → args_B ✓
    }
    → pop()               // after A → args_A ✓
}
```

正常情况下 push/pop 成对出现，但有**异常场景**：

```
方法 A() {
    → push(args_A)        // before A
    方法 B() {
        → push(args_B)    // before B
        // ⚡ B 抛异常了，但 afterThrowing 的字节码被跳过
        // → pop() 没有执行！
    }
    → pop()               // after A → 弹出的是 args_B，而不是 args_A！
}
```

如果使用普通的 `ArrayList` 或 `Stack`，在这种不成对的情况下：
1. Stack 会一直增长 → **内存泄漏**
2. 弹出的数据可能错位 → **数据不准确**

### 3.2 ObjectStack 的解决方案

```java
public void push(Object value) {
    if (pos < cap) {
        array[pos++] = value;
    } else {
        // 满了就归零 → 环形覆盖
        pos = 0;
        array[pos++] = value;
    }
}

public Object pop() {
    if (pos > 0) {
        pos--;
        Object object = array[pos];
        array[pos] = null;        // 帮助 GC
        return object;
    } else {
        // pos == 0 时回绕到末尾
        pos = cap;
        pos--;
        Object object = array[pos];
        array[pos] = null;
        return object;
    }
}
```

**设计哲学**：**宁可数据偶尔不准确，也不要内存泄漏**。

- 容量固定 512 → 即使 push 被疯狂调用，内存也只用 512 个槽位
- 满了就归零 → 旧数据被覆盖，不会 OOM
- push/pop 不对称时，数据可能错位 → 但在极端场景下可以接受

```
正常场景（99.9%）：
  push A → push B → pop B → pop A    完美匹配 ✓

极端场景（0.1%）：
  push A → push B → [B 的 pop 丢失] → pop 取到 B 而不是 A
  → args 不准确，但不会崩溃，不会内存泄漏 ✓（可接受的 trade-off）
```

---

## 4. 重放模式 — processPlay()

### 4.1 重放的本质

```
录制时: doSomething("hello") → 返回 "result"
重放时: 用反射重新调用 doSomething("hello") → 观察新的返回值
```

重放的本质就是**反射调用**：`method.invoke(target, params)`

### 4.2 processPlay() 完整逻辑

```java
private void processPlay(CommandProcess process) {
    // ① 从 Map 中找到指定碎片
    TimeFragment tf = timeFragmentMap.get(index);
    if (null == tf) {
        process.end(1, "Time fragment[...] does not exist.");
        return;
    }

    Advice advice = tf.getAdvice();
    ArthasMethod method = advice.getMethod();

    // ② 打开方法访问权限
    boolean accessible = method.isAccessible();
    try {
        if (!accessible) {
            method.setAccessible(true);   // 允许调用 private 方法
        }

        // ③ 循环重放（支持多次）
        for (int i = 0; i < getReplayTimes(); i++) {
            if (i > 0) {
                Thread.sleep(getReplayInterval());   // 间隔等待
                if (!process.isRunning()) return;    // 用户可能已 Ctrl+C
            }

            long beginTime = System.nanoTime();

            // ④ 拷贝原始录制信息作为结果模板
            TimeFragmentVO replayResult = createTimeFragmentVO(index, tf, expand);
            replayResult.setTimestamp(LocalDateTime.now())
                        .setCost(0)
                        .setReturn(false).setReturnObj(null)
                        .setThrow(false).setThrowExp(null);

            try {
                // ⑤ 核心！反射调用
                Object returnObj = method.invoke(advice.getTarget(), advice.getParams());
                double cost = (System.nanoTime() - beginTime) / 1000000.0;
                replayResult.setCost(cost)
                            .setReturn(true)
                            .setReturnObj(new ObjectVO(returnObj, expand));
            } catch (Throwable t) {
                // ⑥ 重放时异常
                double cost = (System.nanoTime() - beginTime) / 1000000.0;
                replayResult.setCost(cost)
                            .setThrow(true)
                            .setThrowExp(new ObjectVO(t, expand));
            }

            // ⑦ 输出重放结果
            TimeTunnelModel timeTunnelModel = new TimeTunnelModel()
                    .setReplayResult(replayResult)
                    .setReplayNo(i + 1)
                    .setExpand(expand)
                    .setSizeLimit(sizeLimit);
            process.appendResult(timeTunnelModel);
        }
        process.end();
    } finally {
        method.setAccessible(accessible);   // ⑧ 恢复原始访问权限
    }
}
```

### 4.3 ArthasMethod — 延迟反射解析

```java
public class ArthasMethod {
    private final Class<?> clazz;         // 目标类
    private final String methodName;       // 方法名
    private final String methodDesc;       // ASM 方法描述符（如 "(Ljava/lang/String;)V"）

    private Constructor<?> constructor;    // 延迟初始化
    private Method method;                 // 延迟初始化

    private void initMethod() {
        if (constructor != null || method != null) return;  // 只初始化一次

        ClassLoader loader = this.clazz.getClassLoader();
        final Type asmType = Type.getMethodType(methodDesc);

        // 将 ASM 类型描述符转换为 Java Class 对象
        final Class<?>[] argsClasses = new Class<?>[asmType.getArgumentTypes().length];
        for (int index = 0; index < argsClasses.length; index++) {
            Type argumentAsmType = asmType.getArgumentTypes()[index];
            switch (argumentAsmType.getSort()) {
                case Type.BOOLEAN: argsClasses[index] = boolean.class; break;
                case Type.INT:     argsClasses[index] = int.class;     break;
                case Type.LONG:    argsClasses[index] = long.class;    break;
                // ... 其他基本类型
                case Type.OBJECT:  argsClasses[index] = Class.forName(className, true, loader); break;
                case Type.ARRAY:   argsClasses[index] = Class.forName(internalName, true, loader); break;
            }
        }

        if ("<init>".equals(this.methodName)) {
            this.constructor = clazz.getDeclaredConstructor(argsClasses);
        } else {
            this.method = clazz.getDeclaredMethod(methodName, argsClasses);
        }
    }

    public Object invoke(Object target, Object... args) throws ... {
        initMethod();   // 延迟初始化
        if (method != null) {
            return method.invoke(target, args);    // 反射调用
        } else if (constructor != null) {
            return constructor.newInstance(args);   // 构造方法重放
        }
        return null;
    }
}
```

**为什么延迟初始化？**

录制时，`ArthasMethod` 只保存了 `(clazz, methodName, methodDesc)` 三元组。只有在**重放时**才需要解析出真正的 `java.lang.reflect.Method` 对象。这样做的好处：

1. 录制路径更轻量（不做反射解析）
2. 如果只是查看/搜索，永远不需要解析
3. 解析只发生一次（`if (method != null) return`）

### 4.4 重放的局限性和风险

```
⚠️ 重放时需要注意的问题：

1. 【状态变化】重放使用的是录制时的 target 引用。
   如果 target 的内部状态已经变化（比如数据库连接已关闭），
   重放可能失败或产生不同的结果。

2. 【参数引用】重放使用的是录制时的 params 引用。
   如果 params 中的对象已被修改（引用未变，内容变了），
   重放使用的是修改后的参数。

3. 【副作用】重放会**真正执行**方法！
   如果方法有副作用（写数据库、发消息、扣款），
   重放就会重复执行这些副作用！

4. 【线程上下文】重放在 Arthas 的命令线程中执行，
   不在原始业务线程中。ThreadLocal 变量不同。

5. 【构造方法】支持重放 <init>（构造方法），
   使用 constructor.newInstance(args)。
```

### 4.5 重放数据流

```
用户输入: tt -i 1000 -p --replay-times 2 --replay-interval 1000

processPlay():
  ① timeFragmentMap.get(1000)
     → TimeFragment{advice, 2026-02-10 14:00:00, 23.5ms}
       → advice.method = ArthasMethod{MyService, "doSomething", "(Ljava/lang/String;)V"}
       → advice.target = MyService@0x1a2b3c
       → advice.params = ["hello"]

  ② method.setAccessible(true)

  ③ 第 1 次重放:
     → method.invoke(MyService@0x1a2b3c, ["hello"])
       → initMethod()  // 第一次调用，解析反射 Method
         → Class.forName("java.lang.String", true, loader)
         → MyService.class.getDeclaredMethod("doSomething", String.class)
       → method.invoke(this, "hello")  // 真正执行！
     → returnObj = "new_result"        // 可能和录制时不同！
     → cost = 15.2ms
     → 输出: Replay No.1, return=true, cost=15.2ms, returnObj="new_result"

  ④ Thread.sleep(1000)  // 间隔 1 秒

  ⑤ 第 2 次重放:
     → method.invoke(MyService@0x1a2b3c, ["hello"])
       → initMethod()  // 已初始化，跳过
       → method.invoke(this, "hello")
     → returnObj = "new_result_2"
     → cost = 12.1ms
     → 输出: Replay No.2, return=true, cost=12.1ms, returnObj="new_result_2"

  ⑥ method.setAccessible(false)  // 恢复
```

---

## 5. 查看与搜索模式

### 5.1 processShow() — 查看单条记录

```java
private void processShow(CommandProcess process) {
    TimeFragment tf = timeFragmentMap.get(index);
    if (null == tf) {
        process.end(1, "Time fragment[...] does not exist.");
        return;
    }

    TimeFragmentVO vo = createTimeFragmentVO(index, tf, expand);
    // expand 控制对象展开深度（-x 参数）
    process.appendResult(new TimeTunnelModel().setTimeFragment(vo).setExpand(expand).setSizeLimit(sizeLimit));
    process.end();
}
```

### 5.2 processWatch() — OGNL 观察指定碎片

```java
private void processWatch(CommandProcess process) {
    TimeFragment tf = timeFragmentMap.get(index);
    Advice advice = tf.getAdvice();

    // 用 unpooledExpress（非线程池版本）对保存的 Advice 求值
    Object value = ExpressFactory.unpooledExpress(advice.getLoader())
                                .bind(advice)
                                .get(watchExpress);

    process.appendResult(new TimeTunnelModel()
            .setWatchValue(new ObjectVO(value, expand))
            .setExpand(expand).setSizeLimit(sizeLimit));
    process.end();
}
```

**与 watch 命令的区别**：
- `watch` 命令使用 `threadLocalExpress()`（线程池版，绑定当前线程的 ClassLoader）
- `tt -i -w` 使用 `unpooledExpress(advice.getLoader())`（非线程池版，使用录制时的 ClassLoader）

因为 tt 的 OGNL 求值发生在命令线程中，不在目标应用线程中，所以不能用 `threadLocalExpress`。

### 5.3 processSearch() — 搜索 + 观察

```java
private void processSearch(CommandProcess process) {
    Map<Integer, TimeFragment> matchingMap = new LinkedHashMap<>();

    // ① 遍历所有碎片，用搜索表达式过滤
    for (Map.Entry<Integer, TimeFragment> entry : timeFragmentMap.entrySet()) {
        Advice advice = entry.getValue().getAdvice();
        if (ExpressFactory.threadLocalExpress(advice).is(searchExpress)) {
            matchingMap.put(entry.getKey(), entry.getValue());
        }
    }

    if (hasWatchExpress()) {
        // ② 如果同时有 -w 参数，对匹配的碎片执行 OGNL 观察
        Map<Integer, ObjectVO> searchResults = new LinkedHashMap<>();
        for (Map.Entry<Integer, TimeFragment> entry : matchingMap.entrySet()) {
            Object value = ExpressFactory.threadLocalExpress(entry.getValue().getAdvice())
                                        .get(watchExpress);
            searchResults.put(entry.getKey(), new ObjectVO(value, expand));
        }
        process.appendResult(new TimeTunnelModel().setWatchResults(searchResults)...);
    } else {
        // ③ 没有 -w 参数，只输出匹配的碎片列表
        process.appendResult(new TimeTunnelModel().setTimeFragmentList(...)...);
    }

    process.end();
}
```

**使用示例**：

```bash
# 搜索所有 params[0] > 100 的调用，并观察其参数和返回值
tt -s '{params[0] > 100}' -w '{params, returnObj}'
```

---

## 6. createTimeFragmentVO() — 碎片视图转换

```java
public static TimeFragmentVO createTimeFragmentVO(Integer index, TimeFragment tf, Integer expand) {
    Advice advice = tf.getAdvice();

    // target 对象的 hashCode → 十六进制（用于标识对象实例）
    String object = advice.getTarget() == null
            ? "NULL"
            : "0x" + toHexString(advice.getTarget().hashCode());

    return new TimeFragmentVO()
            .setIndex(index)
            .setTimestamp(tf.getGmtCreate())
            .setCost(tf.getCost())
            .setParams(ObjectVO.array(advice.getParams(), expand))   // 参数展开
            .setReturn(advice.isAfterReturning())
            .setReturnObj(new ObjectVO(advice.getReturnObj(), expand))
            .setThrow(advice.isAfterThrowing())
            .setThrowExp(new ObjectVO(advice.getThrowExp(), expand))
            .setObject(object)
            .setClassName(advice.getClazz().getName())
            .setMethodName(advice.getMethod().getName());
}
```

---

## 7. tt 与 watch 的对比总结

| 维度 | watch | tt |
|------|-------|-----|
| **数据生命周期** | 即时输出，即时丢弃 | 保存在内存中，随时回看 |
| **数据存储** | 无 | `LinkedHashMap<Integer, TimeFragment>` |
| **OGNL 表达式** | 录制时指定，不可更改 | 录制后可以用不同的表达式反复观察 |
| **重放能力** | ❌ | ✅ `method.invoke(target, params)` |
| **搜索能力** | ❌ | ✅ `tt -s` 按条件搜索 |
| **内存开销** | 无（不存储） | **高**（保存所有对象引用，阻止 GC） |
| **适用场景** | 实时观察，问题明确 | 偶发问题录制，反复分析 |
| **性能影响** | 每次调用输出到终端 | 每次调用存入 Map（更快） |
| **并发设计** | 无需同步 | LinkedHashMap 非线程安全（有 TODO） |

### 7.1 典型使用流程

```bash
# Step 1: 录制
$ tt -t com.example.OrderService placeOrder -n 100
 INDEX  TIMESTAMP            COST(ms)  IS-RET  IS-EXP  OBJECT       CLASS                       METHOD
 1000   2026-02-10 14:00:01  23.5      true    false   0x1a2b3c     com.example.OrderService    placeOrder
 1001   2026-02-10 14:00:03  1523.7    true    false   0x1a2b3c     com.example.OrderService    placeOrder
 1002   2026-02-10 14:00:05  45.2      false   true    0x1a2b3c     com.example.OrderService    placeOrder

# Step 2: 发现 1001 很慢！看看它的参数
$ tt -i 1001 -w 'params[0]'
@Order{
    orderId=@Long[123456],
    amount=@BigDecimal[99999.99],
    items=@ArrayList[size=1000],     # ← 1000 个商品！难怪慢
}

# Step 3: 发现 1002 异常了！看看异常
$ tt -i 1002 -w 'throwExp.message'
@String["Insufficient inventory for item: SKU-789"]

# Step 4: 搜索所有异常的调用
$ tt -s 'isAfterThrowing()' -w '{params[0].orderId, throwExp.message}'
1002 → [123789, "Insufficient inventory for item: SKU-789"]

# Step 5: 修复代码后，重放验证
$ tt -i 1002 -p
 Replay No.1
 INDEX  TIMESTAMP            COST(ms)  IS-RET  IS-EXP
 1002   2026-02-10 14:05:00  38.2      true    false    # ← 修复后正常了！

# Step 6: 清理内存
$ tt --delete-all
Time fragments are cleaned.
```

---

## 8. 设计总结

### 8.1 tt 的 5 个核心设计决策

| # | 决策 | 选择 | 理由 |
|---|------|------|------|
| 1 | 深拷贝 vs 引用 | **引用** | 深拷贝代价太高，某些对象不可序列化 |
| 2 | 并发安全 | **不做** | LinkedHashMap 非线程安全，但实际冲突概率极低 |
| 3 | 参数快照栈 | **固定 512 环形** | push/pop 可能不对称，宁可不准也不要泄漏 |
| 4 | 反射解析时机 | **延迟到重放时** | 录制路径更轻量，大部分碎片不会被重放 |
| 5 | 序号起始值 | **1000** | 避免和 listenerId 等其他 ID 混淆 |

### 8.2 完整类协作图

```
┌────────────────────────────────────────────────────────────────────────┐
│                         TimeTunnelCommand                               │
│                                                                        │
│  ┌──────────────────────┐   static    ┌──────────────────────────────┐ │
│  │ timeFragmentMap      │◄────────────│ TimeTunnelAdviceListener     │ │
│  │ LinkedHashMap<>      │   putTimeTunnel()   │ before()             │ │
│  │                      │             │  → argsRef.push(args)        │ │
│  │  1000 → TimeFragment │             │ afterReturning()             │ │
│  │  1001 → TimeFragment │             │  → argsRef.pop()            │ │
│  │  1002 → TimeFragment │             │  → afterFinishing()          │ │
│  └──────┬───────────────┘             │    → new TimeFragment(...)   │ │
│         │                             │    → putTimeTunnel(...)       │ │
│         │                             └──────────────────────────────┘ │
│         │                                                              │
│    ┌────┼────────────────────────────────────────────────────┐         │
│    │    ▼                                                    │         │
│    │  TimeFragment                                           │         │
│    │  ├── advice: Advice                                     │         │
│    │  │    ├── target ──→ 原始 this 对象（引用！）            │         │
│    │  │    ├── params ──→ 入参数组（引用！）                  │         │
│    │  │    ├── returnObj ──→ 返回值（引用！）                 │         │
│    │  │    ├── throwExp ──→ 异常（引用！）                    │         │
│    │  │    └── method: ArthasMethod ──┐                      │         │
│    │  ├── gmtCreate: LocalDateTime   │                      │         │
│    │  └── cost: double               │                      │         │
│    └─────────────────────────────────┼──────────────────────┘         │
│                                       │                                │
│                                       ▼                                │
│                              ArthasMethod                              │
│                              ├── clazz: Class<?>                       │
│                              ├── methodName: String                    │
│                              ├── methodDesc: String                    │
│                              ├── method: Method (延迟初始化)            │
│                              └── invoke(target, params)                │
│                                  → method.invoke(target, params)       │
│                                    ↑ 重放的本质！                       │
│                                                                        │
│  process() 路由:                                                       │
│  ├── -t         → enhance()          → 录制                            │
│  ├── -l         → processList()      → 遍历 Map 输出                   │
│  ├── -i         → processShow()      → Map.get(index)                  │
│  ├── -i -w      → processWatch()     → OGNL 对 Advice 求值             │
│  ├── -s [-w]    → processSearch()    → 遍历 + OGNL 过滤 [+ 观察]       │
│  ├── -i -p      → processPlay()      → method.invoke(target, params)  │
│  ├── -i -d      → processDelete()    → Map.remove(index)              │
│  └── --delete-all → processDeleteAll() → Map.clear()                  │
└────────────────────────────────────────────────────────────────────────┘
```

---

> **下一节**: [Ch 9 jad/redefine/retransform](ch09_jad_redefine_retransform.md) — 反编译 + 热更新 + 类重载
