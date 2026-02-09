# JVM 架构参考

## HotSpot VM 整体架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              HotSpot VM                                      │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                           Runtime 子系统                                │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐   │ │
│  │  │  Thread     │  │ Synchroni-  │  │  Safepoint  │  │   JNI       │   │ │
│  │  │  Mgmt       │  │  zation     │  │  Mechanism  │  │  Support    │   │ │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘   │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                            GC 子系统                                    │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐   │ │
│  │  │   Serial    │  │  Parallel   │  │     G1      │  │    ZGC      │   │ │
│  │  │    GC       │  │    GC       │  │    GC       │  │   (JDK11+)  │   │ │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘   │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                          类加载子系统                                   │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐   │ │
│  │  │ClassLoader  │  │  Symbol     │  │  String     │  │  Metaspace  │   │ │
│  │  │  Hierarchy  │  │  Table      │  │  Table      │  │             │   │ │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘   │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                          编译器子系统                                   │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐   │ │
│  │  │Interpreter  │  │    C1       │  │    C2       │  │   Graal     │   │ │
│  │  │ (模板/字节码)│  │ (客户端)    │  │ (服务端)    │  │   (可选)    │   │ │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘   │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                          内存管理子系统                                 │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐   │ │
│  │  │   Java      │  │  Metaspace  │  │  Code       │  │  Native     │   │ │
│  │  │   Heap      │  │             │  │  Cache      │  │  Memory     │   │ │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘   │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 源码目录结构

```
src/hotspot/
├── share/                    # 平台无关代码
│   ├── gc/                   # 垃圾收集器
│   │   ├── shared/           # GC 共享代码
│   │   ├── g1/               # G1 GC ★
│   │   ├── parallel/         # Parallel GC
│   │   ├── serial/           # Serial GC
│   │   └── z/                # ZGC
│   ├── memory/               # 内存管理
│   │   ├── universe.cpp      # JVM 全局状态 ★
│   │   ├── heap.cpp          # 堆抽象
│   │   └── metaspace.cpp     # 元空间
│   ├── oops/                 # 对象表示
│   │   ├── oop.hpp           # 普通对象指针
│   │   ├── klass.hpp         # 类元数据
│   │   └── instanceKlass.hpp # 实例类
│   ├── classfile/            # 类加载
│   │   ├── classLoader.cpp   # 类加载器
│   │   ├── systemDictionary.cpp
│   │   ├── symbolTable.cpp   # 符号表
│   │   └── stringTable.cpp   # 字符串常量池
│   ├── runtime/              # 运行时
│   │   ├── thread.cpp        # 线程管理 ★
│   │   ├── synchronizer.cpp  # 同步机制
│   │   ├── safepoint.cpp     # 安全点
│   │   └── vmThread.cpp      # VM 线程
│   ├── interpreter/          # 解释器
│   │   ├── bytecodeInterpreter.cpp
│   │   └── templateInterpreter.cpp
│   └── compiler/             # 编译器接口
│       ├── compileBroker.cpp
│       └── compileTask.cpp
├── cpu/                      # CPU 相关
│   └── x86/                  # x86 实现
└── os/                       # 操作系统相关
    └── linux/                # Linux 实现
```

## G1 GC 核心类

| 类名 | 文件 | 功能 |
|------|------|------|
| G1CollectedHeap | g1CollectedHeap.hpp/cpp | G1 堆管理的总控制器 |
| HeapRegion | heapRegion.hpp/cpp | 单个 Region 的表示 |
| HeapRegionManager | heapRegionManager.hpp | Region 数组管理 |
| HeapRegionRemSet | heapRegionRemSet.hpp | Region 级记忆集 |
| G1CardTable | g1CardTable.hpp | G1 专用卡表 |
| G1ConcurrentMark | g1ConcurrentMark.hpp | 并发标记控制器 |
| G1ConcurrentRefine | g1ConcurrentRefine.hpp | 并发精炼（更新 RemSet） |
| G1Policy | g1Policy.hpp | GC 策略决策 |
| G1Allocator | g1Allocator.hpp | 对象分配器 |
| G1CollectionSet | g1CollectionSet.hpp | 回收集合管理 |

## 常用断点位置

```cpp
// JVM 启动
Threads::create_vm          // JVM 启动入口
universe_init               // 全局初始化
universe2_init              // 二次初始化

// GC 相关
G1CollectedHeap::do_collection_pause_at_safepoint  // GC 暂停入口
G1ConcurrentMark::mark_from_roots                  // 并发标记
G1YoungRemSetSamplingThread::sample_young          // 采样

// 对象分配
G1CollectedHeap::attempt_allocation                // 分配入口
G1CollectedHeap::attempt_allocation_slow           // 慢路径分配

// 类加载
SystemDictionary::load_instance_class              // 加载类
ClassFileParser::parse_stream                      // 解析 class 文件
```

## 标准调试配置

```bash
# 推荐 JVM 参数
-Xms8g -Xmx8g              # 固定堆大小，便于分析
-XX:+UseG1GC               # 使用 G1
-Xint                      # 解释执行，便于调试
-XX:+PrintGCDetails        # GC 详情
-Xlog:gc*=debug            # GC 日志

# 推导配置（8GB 堆）
Region 大小：4MB
Region 数量：2048
CardTable：16MB
Bitmap：128MB × 2 = 256MB
```
