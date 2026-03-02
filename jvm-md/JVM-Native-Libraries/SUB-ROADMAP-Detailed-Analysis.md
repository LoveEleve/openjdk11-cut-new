# JVM 原生库细化子大纲与攻克顺序

> **目标**：将每个 so 库拆分为可执行的子任务  
> **总文档数**：15+ 篇  
> **攻克顺序**：按依赖关系排列，从基础到高级

---

## 核心库依赖关系图

```
                    ┌─────────────────┐
                    │   libc.so       │
                    │  (系统基础)     │
                    └────────┬────────┘
                             │
        ┌────────────────────┼────────────────────┐
        │                    │                    │
        ▼                    ▼                    ▼
┌───────────────┐    ┌───────────────┐    ┌───────────────┐
│ libjsig.so    │    │ libjvm.so     │    │ libjava.so    │
│ (信号机制)    │◄───┤ (核心引擎)    ├───►│ (Java基础)    │
└───────┬───────┘    └───────┬───────┘    └───────┬───────┘
        │                    │                    │
        │                    ▼                    │
        │           ┌───────────────┐             │
        │           │ libattach.so  │             │
        │           │ (Attach工具) │             │
        │           └───────────────┘             │
        │                                         │
        │                    ┌────────────────────┘
        │                    │
        ▼                    ▼
┌───────────────┐    ┌───────────────┐
│ Async-Profiler │    │ libnio.so     │
│ (信号应用)    │◄───┤ (NIO/IO)      │
└───────────────┘    └───────┬───────┘
                             │
                    ┌────────┴────────┐
                    │                 │
                    ▼                 ▼
           ┌───────────────┐   ┌───────────────┐
           │ Netty/应用    │   │ libnet.so     │
           │ (实际使用)    │   │ (网络底层)    │
           └───────────────┘   └───────────────┘
```

**依赖顺序**：libc → libjsig/libjvm/libjava → libattach/libnio → 上层应用

---

## Tier 1: 核心引擎层（4 篇文档）

### 1. libjsig.so - 信号链机制（2 篇）

#### 文档 1.1: Unix 信号基础与 HotSpot 信号处理
**源码位置**：
- `src/hotspot/os/posix/os_posix.cpp`
- `src/hotspot/os/linux/os_linux.cpp`
- `src/hotspot/os/posix/vmError_posix.cpp`

**子大纲**：
```
1. Unix 信号机制回顾
   1.1 信号概念与类型
       • 可靠信号 vs 不可靠信号
       • 实时信号 vs 标准信号
       • 信号编号：SIGSEGV(11)、SIGBUS(7)、SIGILL(4)、SIGFPE(8)
   
   1.2 信号处理 API
       • signal() 传统 API
       • sigaction() 现代 API（重点）
           - sa_handler vs sa_sigaction
           - sa_mask 信号掩码
           - SA_SIGINFO 标志
       • sigprocmask() 阻塞信号
       • sigpending() 查看待处理信号
   
   1.3 异步信号安全（Async-Signal-Safe）
       • 什么是 async-signal-safe 函数
       • 可重入函数概念
       • 信号处理中禁止的操作
           - 禁止 malloc/free
           - 禁止持有锁
           - 禁止调用非安全函数

2. HotSpot 信号初始化
   2.1 os::signal_init() 流程
       • 初始化信号处理器数组
       • 设置默认处理器
       • 注册关键信号
   
   2.2 信号处理器注册
       • set_signal_handler() 实现
       • 保存原始处理器
       • 信号链建立
   
   2.3 信号掩码管理
       • 线程信号掩码
       • 全局信号阻塞
       • JVM 安全区（Safe Region）

3. 关键信号处理详解
   3.1 SIGSEGV（段错误）→ NullPointerException
       • 判断 NPE 的方法（地址 < 4096）
       • 生成 NPE 异常对象
       • 异常抛出机制
       • 代码位置：os::Linux::handler()
   
   3.2 SIGBUS（总线错误）→ StackOverflowError
       • 栈保护页机制（Guard Page）
       • Yellow Zone / Red Zone
       • 栈溢出检测流程
       • 代码位置：os::Linux::handler()
   
   3.3 SIGILL/SIGFPE → Safepoint 轮询
       • 伪指令异常（0xF4）
       • 轮询页机制
       • 线程状态切换
       • Safepoint 同步
   
   3.4 SIGUSR1/SIGUSR2 → 用户自定义
       • 线程 dump 触发
       • Heap dump 触发
       • 自定义处理

4. 实战：信号处理调试
   4.1 使用 strace 跟踪信号
       strace -e trace=signal java MyApp
   
   4.2 使用 GDB 调试信号处理
       handle SIGSEGV nostop print
       info signals
   
   4.3 编写测试程序验证
       • 触发 NPE 观察信号转换
       • 触发 SOE 观察信号转换
       • 自定义信号处理器

5. 面试高频题
   • JVM 如何将 SIGSEGV 转换为 NullPointerException？
   • 为什么需要 Yellow Zone 和 Red Zone？
   • 信号处理中为什么不能用 malloc？
```

#### 文档 1.2: libjsig.so 信号链与 Async-Profiler 应用
**源码位置**：
- `src/hotspot/os/posix/jvm_posix.cpp`
- Async-Profiler: `src/symbols.h`, `src/profiler.cpp`

**子大纲**：
```
1. 信号链（Signal Chaining）原理
   1.1 为什么需要信号链
       • 多库信号冲突问题
       • JVM 与 Native 库的信号共存
       • 信号处理器覆盖问题
   
   1.2 libjsig.so 实现机制
       • 保存原始信号处理器链
       • 拦截 sigaction() 调用
       • 链式转发逻辑
       • 代码分析：sigaction() hook
   
   1.3 使用 libjsig.so
       • LD_PRELOAD libjsig.so
       • 与 -Xrs 选项的配合
       • 实际部署案例

2. VMError 崩溃处理机制
   2.1 VMError::report_and_die() 流程
       • 接收致命信号
       • 生成 hs_err_pid.log
       • 触发 core dump
       • 调用 os::die()
   
   2.2 hs_err_pid.log 内容解析
       • 崩溃原因（信号类型）
       • 寄存器状态
       • 栈回溯
       • 线程状态
       • 内存映射
   
   2.3 崩溃恢复与调试
       • 使用 GDB 分析 core dump
       • 使用 jdb 附加调试
       • 常见问题排查

3. Async-Profiler 信号应用
   3.1 perf_event 信号机制
       • perf_event_open() 系统调用
       • PERF_SAMPLE_SIGIO 模式
       • 信号频率控制（sample rate）
   
   3.2 Async-Profiler 信号处理流程
       • 注册 SIGPROF/SIGIO 处理器
       • 信号接收与处理
       • 获取用户上下文（ucontext_t）
       • 栈回溯实现
       • 写入 JFR 文件
   
   3.3 信号冲突解决
       • 与 JVM 信号的协调
       • 与其他 Profiler 的冲突
       • 信号丢失处理
       • 递归信号防护

4. 实战案例
   4.1 案例：JVM 崩溃分析
       • 模拟 SIGSEGV
       • 分析 hs_err_pid.log
       • GDB 调试 core dump
   
   4.2 案例：Async-Profiler 信号问题
       • 信号频率过高导致性能下降
       • 与其他 Agent 的信号冲突
       • 解决方案
   
   4.3 案例：自定义信号处理器
       • 使用 libjsig.so 链式处理
       • 实现自定义监控
       • 与 JVM 信号共存

5. 进阶话题
   5.1 信号与 GC 的交互
       • GC 期间的信号处理
       • 安全点与信号
   
   5.2 信号与线程
       • 定向信号（pthread_kill）
       • 信号与线程本地存储
```

---

### 2. libjvm.so - JVMTI 深度剖析（2 篇）

#### 文档 2.1: JVMTI Agent 机制与事件系统
**源码位置**：
- `src/hotspot/share/prims/jvmti*`
- `src/hotspot/share/prims/jvmtiEnv.cpp`
- `src/hotspot/share/prims/jvmtiExport.cpp`

**子大纲**：
```
1. JVMTI 架构概览
   1.1 JVMTI 是什么
       • JVM Tool Interface 定义
       • 与 JNI 的区别
       • Agent 三种类型
   
   1.2 JVMTI 环境生命周期
       • Agent_OnLoad（启动时）
       • Agent_OnAttach（运行时）
       • Agent_OnUnload（卸载时）
   
   1.3 核心数据结构
       • jvmtiEnv 结构体
       • _jvmti_external_functions 函数表
       • JvmtiExport 导出类

2. Agent 加载机制
   2.1 命令行加载 -agentlib/-agentpath
       • Arguments::parse() 解析
       • os::dll_load() 加载库
       • 调用 Agent_OnLoad()
   
   2.2 动态 Attach 加载
       • AttachListener::dequeue()
       • load_agent() 实现
       • 与静态加载的区别
   
   2.3 Arthas 的 Agent 加载流程
       • arthas-agent 源码分析
       • InstrumentationImpl
       • ClassFileTransformer 注册

3. 事件机制详解
   3.1 事件类型分类
       • VM 生命周期事件
       • 类事件（ClassFileLoadHook）
       • 线程事件
       • GC 事件
       • 方法事件
   
   3.2 事件回调注册
       • SetEventCallbacks()
       • SetEventNotificationMode()
       • 回调线程模型
   
   3.3 性能开销分析
       • 事件启用的代价
       • 如何最小化影响
       • Async-Profiler 的事件选择

4. 字节码 Instrumentation
   4.1 ClassFileLoadHook
       • 触发时机
       • 字节码修改限制
       • RetransformClasses()
   
   4.2 Arthas 字节码增强
       • AdviceAdapter 原理
       • 方法进入/退出植入
       • 局部变量表处理
   
   4.3 实战：编写简单 Agent
       • 统计方法调用次数
       • 打印方法入参
       • 性能计时
```

#### 文档 2.2: VMStructs 与符号解析
**源码位置**：
- `src/hotspot/share/runtime/vmStructs.cpp`
- `src/hotspot/share/runtime/vmStructs.hpp`
- Async-Profiler: `src/vmStructs.cpp`

**子大纲**：
```
1. VMStructs 机制
   1.1 什么是 VMStructs
       • 类型信息导出机制
       • 为什么需要 VMStructs
       • 与调试符号的区别
   
   1.2 VMStructEntry 结构
       • typeName、fieldName、address
       • isStatic、offset
       • 类型系统映射
   
   1.3 生成与读取
       • VMStructs::generate()
       • HSDB 读取方式
       • Async-Profiler 读取实现

2. 关键数据结构偏移
   2.1 JavaThread 偏移
       • _threadObj
       • _stack_base、_stack_size
       • _tlab、_allocated_bytes
   
   2.2 Klass 与 InstanceKlass
       • _name、_super
       • _methods、_constants
   
   2.3 Heap 相关
       • G1CollectedHeap 结构
       • HeapRegion 布局
       • RememberedSet 位置

3. Async-Profiler 应用
   3.1 读取线程栈
       • 定位 JavaThread
       • 获取栈帧
       • 符号解析
   
   3.2 读取 GC 信息
       • GC 状态判断
       • TLAB 使用情况
       • Region 状态
   
   3.3 实战：自定义 VMStructs 读取工具
       • 使用 ptrace 读取
       • 解析类型信息
       • 打印线程堆栈
```

---

## Tier 2: 基础服务层（4 篇文档）

### 3. libnio.so - 直接内存与零拷贝（2 篇）

#### 文档 3.1: DirectBuffer 与 Cleaner 机制
**源码位置**：
- `src/java.base/share/classes/java/nio/DirectByteBuffer.java`
- `src/java.base/share/native/libjava/NativeLibraries.c`
- `src/hotspot/share/prims/unsafe.cpp`

**子大纲**：
```
1. DirectBuffer 架构
   1.1 什么是 DirectBuffer
       • 堆外内存（Off-Heap）
       • 与 Heap ByteBuffer 的区别
       • 适用场景
   
   1.2 内存分配路径
       • ByteBuffer.allocateDirect()
       → DirectByteBuffer 构造函数
       → Unsafe.allocateMemory()
       → os::malloc()
   
   1.3 内存布局
       • DirectByteBuffer 对象（堆上）
       • address 字段（指向堆外内存）
       • capacity、limit、position

2. Cleaner 机制深度分析
   2.1 为什么需要 Cleaner
       • 替代 finalize()
       • 及时释放堆外内存
       • 避免内存泄漏
   
   2.2 Cleaner 实现
       • Cleaner 类结构（Java 层）
       • CleanerImpl（JDK 内部）
       • ReferenceHandler 线程处理
   
   2.3 DirectByteBuffer 的清理
       • Deallocator 实现
       → Unsafe.freeMemory()
       → os::free()
       • 显式调用 clean()
       • 自动回收（GC 触发）

3. 内存泄漏分析
   3.1 常见泄漏场景
       • 未关闭的 Channel
       • 未清理的 Buffer
       • ThreadLocal 持有
   
   3.2 排查工具
       • pmap 查看进程内存
       • jcmd VM.native_memory
       • NMT（Native Memory Tracking）
       • Async-Profiler alloc 模式
   
   3.3 实战案例
       • Netty 堆外内存泄漏
       • NIO Selector 泄漏
       • 大文件映射未释放

4. 性能优化
   4.1 分配优化
       • 池化技术（Netty ByteBuf）
       • ThreadLocal 缓存
       • 批量分配
   
   4.2 使用优化
       • 避免拷贝（零拷贝）
       • 批量读写
       • 内存对齐
```

#### 文档 3.2: FileChannel 内存映射与零拷贝
**源码位置**：
- `src/java.base/share/native/libnio/FileChannelImpl.c`
- `src/java.base/unix/native/libnio/LinuxNativeDispatcher.c`

**子大纲**：
```
1. FileChannel 内存映射
   1.1 mmap 基础
       • 什么是内存映射
       • mmap() 系统调用参数
       • 与 read/write 的区别
   
   1.2 MappedByteBuffer
       • FileChannel.map()
       → map0() native 方法
       → mmap 系统调用
       • 三种模式（READ_ONLY、READ_WRITE、PRIVATE）
   
   1.3 内存管理
       • 页缓存（Page Cache）
       • 刷盘机制（force、msync）
       • 解除映射（unmap）

2. 零拷贝技术
   2.1 传统 IO 的数据拷贝
       • 4 次拷贝，4 次上下文切换
   
   2.2 sendfile 零拷贝
       • FileChannel.transferTo()
       → sendfile64() 系统调用
       • 2 次拷贝，2 次上下文切换
   
   2.3 splice 零拷贝
       • pipe 管道中转
       • 完全零拷贝
       • 限制（必须是 pipe）

3. EPollSelector 实现
   3.1 Linux IO 多路复用
       • select/poll 的局限
       • epoll 的优势（O(1)）
   
   3.2 EPollSelectorImpl
       • epoll_create()
       • epoll_ctl()
       • epoll_wait()
   
   3.3 与 Netty 的结合
       • EventLoop 实现
       • 水平触发 vs 边缘触发
```

---

## Tier 3: 辅助库（2 篇文档）

### 4. libnet.so 与 libzip.so（1 篇）

#### 文档 4.1: 网络与压缩库
**源码位置**：
- `src/java.base/unix/native/libnet/`
- `src/java.base/share/native/libzip/`

**子大纲**：
```
1. libnet.so - Socket 原生实现
   1.1 Java Socket 到 Native Socket
       • PlainSocketImpl
       → socket()/bind()/listen()/accept()
   
   1.2 NIO SocketChannel
       • 非阻塞 IO
       • Selector 注册
   
   1.3 Netty 的 Native 支持
       • netty-transport-native-epoll
       • 性能对比

2. libzip.so - JAR 解压优化
   2.1 Inflate/Deflate 算法
   2.2 ZIP 文件格式解析
   2.3 CDS（Class Data Sharing）
       • CDS 原理
       • AppCDS 使用
       • 启动加速效果
```

---

## Tier 4: 实战整合（5 篇文档）

### 5. 实战案例与项目（5 篇）

#### 文档 5.1: 内存泄漏排查案例集
#### 文档 5.2: 性能优化案例集
#### 文档 5.3: 崩溃分析案例集
#### 文档 5.4: 自定义 JVMTI Agent 开发
#### 文档 5.5: MiniProfiler 项目实战

（详细大纲见主路线图）

---

## 攻克顺序建议

### 推荐顺序（基于依赖关系）

```
Phase 1: 信号基础（2 周）
    Week 1: 文档 1.1 - Unix 信号与 HotSpot 信号处理
    Week 2: 文档 1.2 - libjsig.so 与 Async-Profiler

Phase 2: JVMTI 核心（2 周）
    Week 3: 文档 2.1 - JVMTI Agent 与事件系统
    Week 4: 文档 2.2 - VMStructs 与符号解析

Phase 3: NIO 深入（2 周）
    Week 5: 文档 3.1 - DirectBuffer 与 Cleaner
    Week 6: 文档 3.2 - FileChannel 与零拷贝

Phase 4: 辅助库（1 周）
    Week 7: 文档 4.1 - 网络与压缩

Phase 5: 实战（2 周）
    Week 8-9: 文档 5.1-5.5 实战案例与项目
```

### 快速路径（如果已有基础）

```
如果你有 HotSpot 源码分析基础：
    跳过 Phase 2（libjvm.so 部分）
    从 Phase 1 Week 2（libjsig.so）开始
    重点投入 Phase 3（libnio.so）

如果你关注性能分析工具：
    必须完成 Phase 1（信号机制）
    重点完成 Phase 2 Week 2（VMStructs）
    快速过 Phase 3-4
    重点 Phase 5（实战）
```

---

## 立即开始

**请选择一个起点：**

| 选项 | 起点 | 预计产出 | 难度 |
|------|------|----------|------|
| **A** | **文档 1.1** - Unix 信号基础 | 理解 JVM 信号处理机制 | ⭐⭐⭐ |
| **B** | **文档 1.2** - libjsig.so 与 Async-Profiler | 掌握信号链与性能分析 | ⭐⭐⭐⭐ |
| **C** | **文档 3.1** - DirectBuffer | 深入堆外内存管理 | ⭐⭐⭐ |
| **D** | **文档 5.4** - 自定义 Agent | 直接实战开发 | ⭐⭐⭐⭐⭐ |

**回复 A/B/C/D，我立即开始撰写对应文档！**
