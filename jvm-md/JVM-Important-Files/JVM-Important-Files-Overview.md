# JVM HotSpot 源码重要文件总览

> **整理日期**：2026-02-15  
> **源码路径**：`/data/workspace/openjdk-cut-new/src/hotspot/`

---

## 目录结构概览

```
src/hotspot/
├── cpu/              # CPU 特定代码（x86, ARM, PPC 等）
├── os_cpu/          # OS + CPU 特定代码
├── os/              # 操作系统抽象层
└── share/           # 平台无关代码
    ├── adlc/        # ADLC 汇编器
    ├── aot/         # Ahead-of-Time 编译
    ├── asm/         # 汇编帮助类
    ├── c1/          # C1 编译器 (Client JIT)
    ├── ci/          # 编译器接口
    ├── classfile/   # 类文件解析
    ├── code/        # 代码缓存
    ├── compiler/    # 编译器框架
    ├── gc/          # 垃圾回收器
    ├── interpreter/ # 解释器
    ├── jfr/        # Java Flight Recorder
    ├── jvmci/      # JVM Compiler Interface
    ├── libadt/      # 抽象数据结构
    ├── logging/     # 日志系统
    ├── memory/      # 内存管理
    ├── metaprogramming/ # 元编程
    ├── oops/        # 普通对象指针
    ├── opto/       # C2 编译器 (Server JIT)
    ├── prims/      # JVM 内部原始函数
    ├── runtime/    # 运行时系统
    ├── services/   # 服务和诊断
    └── utilities/ # 工具类
```

---

## 核心模块文件数量统计

| 模块 | 重要文件数 | 说明 |
|------|-----------|------|
| GC 系统 | ~150+ | G1/Serial/Parallel/CMS/Shenandoah/ZGC |
| 运行时系统 | ~80+ | 线程/锁/同步/safepoint |
| 编译器 (C1+C2) | ~100+ | 编译管线/优化/寄存器分配 |
| 解释器 | ~20+ | 字节码执行/模板 |
| 类加载 | ~30+ | 解析/验证/加载 |
| OOP/元数据 | ~40+ | 对象表示/类结构 |
| 代码缓存 | ~15+ | nmethod/IC/Stub |
| 内存管理 | ~20+ | 堆/Metaspace/Arena |
| JFR | ~50+ | 事件录制/检查点 |
| 服务/诊断 | ~20+ | JMX/HeapDump/Attach |

---

## 各模块详细文件列表

| 序号 | 模块 | 详细文件列表 |
|------|------|-------------|
| 1 | [线程系统](./Thread-System.md) | thread.cpp, osThread.cpp, threadLocalStorage.cpp 等 |
| 2 | [运行时系统](./Runtime.md) | init.cpp, vmThread.cpp, synchronizer.cpp 等 |
| 3 | [GC 系统](./GC-System.md) | g1CollectedHeap.cpp, collectedHeap.cpp 等 |
| 4 | [内存管理](./Memory-Management.md) | heap.cpp, universe.cpp, metaspace.cpp 等 |
| 5 | [解释器](./Interpreter.md) | bytecodeInterpreter.cpp, templateInterpreter.cpp 等 |
| 6 | [编译器](./Compiler.md) | c1_Compiler.cpp, compile.cpp 等 |
| 7 | [类加载](./ClassLoading.md) | classFileParser.cpp, systemDictionary.cpp 等 |
| 8 | [OOP和元数据](./OOP-Metadata.md) | oop.cpp, klass.cpp, instanceKlass.cpp 等 |
| 9 | [代码缓存](./CodeCache.md) | codeCache.cpp, nmethod.cpp 等 |
| 10 | [操作系统抽象层](./OS-Abstraction.md) | os_linux.cpp 等 |
| 11 | [JFR](./JFR.md) | jfr.cpp, jfrRecorder.cpp 等 |
| 12 | [服务和诊断](./Services-Diagnostics.md) | management.cpp, heapDumper.cpp 等 |
| 13 | [JVM 原生库 (SO)](./JVM-Native-Libraries.md) | libjvm.so, libjli.so, libnio.so 等 |

---

## 重要程度标记说明

| 标记 | 含义 |
|------|------|
| ⭐⭐⭐⭐⭐ | 核心核心，必须掌握 |
| ⭐⭐⭐⭐ | 非常重要，建议掌握 |
| ⭐⭐⭐ | 重要，理解即可 |
| ⭐⭐ | 进阶内容 |
| ⭐ | 特定场景使用 |

---

## 学习路径建议

### 路径一：JVM 启动流程
```
init.cpp → thread.cpp → vmThread.cpp → universe.cpp → interpreter.cpp → compiler.cpp
```

### 路径二：GC 专家
```
collectedHeap.cpp → g1CollectedHeap.cpp → g1Policy.cpp → g1RemSet.cpp → g1ConcurrentMark.cpp
```

### 路径三：性能优化
```
interpreter.cpp → c1_Compiler.cpp → compile.cpp → escape.cpp → loopTransform.cpp
```

### 路径四：并发与锁
```
synchronizer.cpp → objectMonitor.cpp → biasedLocking.cpp → mutex.cpp → safepoint.cpp
```

---

*本文档为总览，详细信息请查看各模块子文档。*
