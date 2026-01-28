# OpenJDK 11 Cut-New - CLion 导入指南

## 🎯 项目概述

这是一个支持**模块化构建**的 OpenJDK 11 项目，可以独立编译各个组件：
- **HotSpot JVM** (`libjvm.so`)
- **Java 核心库** (`libjava.so`, `libnio.so` 等)
- **开发工具** (`javac`, `jar`, `jdeps` 等)

## 🚀 CLion 导入步骤

### 1. 打开项目
1. 启动 CLion
2. 选择 `File` → `Open`
3. 选择 `/data/workspace/openjdk-cut-new` 目录
4. CLion 会自动检测到 `CMakeLists.txt` 并开始配置

### 2. 配置构建
CLion 会自动使用 CMake 配置项目，包含以下目标：
- `jvm` - HotSpot 虚拟机库
- `java_base` - Java 基础库
- `build_split_hotspot` - 使用原生构建系统编译 HotSpot
- `build_split_java_base` - 使用原生构建系统编译 Java 基础库

### 3. 索引和导航
等待 CLion 完成源码索引后，你就可以：
- **跳转到定义** (`Ctrl+B`)
- **查找用法** (`Alt+F7`)
- **全局搜索** (`Ctrl+Shift+F`)
- **类/方法搜索** (`Ctrl+N` / `Ctrl+Shift+Alt+N`)

## 🔧 构建和调试

### 使用 CLion 构建
```bash
# 在 CLion 中可以直接构建这些目标
build_split_hotspot      # 构建 HotSpot JVM
build_split_java_base    # 构建 Java 基础库
test_java               # 测试构建的 JDK
```

### 使用命令行构建（推荐）
```bash
# 模块化构建命令
make -f make/Main.gmk SPEC=build-config/spec.gmk split-hotspot-libs
make -f make/Main.gmk SPEC=build-config/spec.gmk split-java.base-libs
make -f make/Main.gmk SPEC=build-config/spec.gmk split-jdk.compiler

# 测试构建结果
./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java -version
./build/linux-x86_64-normal-server-slowdebug/jdk/bin/javac -version
```

### 调试配置
1. 在 CLion 中创建 `GDB Remote Debug` 配置
2. 设置目标程序：`./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java`
3. 添加程序参数：`-version` 或你的测试程序
4. 设置断点并开始调试

## 📁 重要目录结构

```
openjdk-cut-new/
├── src/                          # 源码目录
│   ├── hotspot/                  # HotSpot JVM 源码
│   │   ├── share/                # 平台无关代码
│   │   ├── os/linux/            # Linux 特定代码
│   │   ├── cpu/x86/             # x86 架构代码
│   │   └── os_cpu/linux_x86/    # Linux x86 特定代码
│   ├── java.base/               # Java 核心模块
│   │   ├── share/native/        # 平台无关 Native 代码
│   │   ├── unix/native/         # Unix 特定 Native 代码
│   │   └── linux/native/        # Linux 特定 Native 代码
│   └── jdk.compiler/            # javac 编译器源码
├── make/                        # 构建脚本
├── build-config/                # 构建配置文件
└── build/                       # 构建输出目录
```

## 🎯 研究重点

### HotSpot JVM 核心组件
- **垃圾收集器**: `src/hotspot/share/gc/`
- **JIT 编译器**: `src/hotspot/share/opto/` (C2), `src/hotspot/share/c1/` (C1)
- **运行时系统**: `src/hotspot/share/runtime/`
- **内存管理**: `src/hotspot/share/memory/`
- **类加载器**: `src/hotspot/share/classfile/`

### Java 核心库
- **NIO**: `src/java.base/share/classes/java/nio/`
- **并发**: `src/java.base/share/classes/java/util/concurrent/`
- **集合**: `src/java.base/share/classes/java/util/`
- **Native 接口**: `src/java.base/*/native/`

## 💡 开发技巧

### 1. 快速定位代码
```bash
# 在 CLion 中使用 "Navigate to File" (Ctrl+Shift+N)
# 搜索关键文件：
- g1CollectedHeap.cpp    # G1 垃圾收集器
- thread.cpp             # 线程管理
- classLoader.cpp        # 类加载
- javac.java            # Java 编译器
```

### 2. 设置断点调试
- 在关键函数设置断点：`JavaMain`, `JVM_StartThread`, `G1CollectedHeap::collect`
- 使用条件断点过滤特定场景
- 观察变量和调用栈

### 3. 性能分析
- 使用 CLion 的 Profiler 分析热点
- 结合 `perf` 工具进行系统级分析
- 使用 JFR (Java Flight Recorder) 分析 Java 层性能

## 🔍 常用搜索模式

在 CLion 中搜索这些关键词来快速定位相关代码：
- `JVM_ENTRY` - JVM 入口函数
- `UNSAFE_ENTRY` - Unsafe 操作
- `GC_TRIGGER` - 垃圾收集触发点
- `CompilerThread` - JIT 编译线程
- `JavaThread` - Java 线程

## 🚀 下一步

1. **熟悉项目结构** - 浏览主要目录和文件
2. **设置调试环境** - 配置 GDB 调试
3. **运行简单测试** - 验证构建和调试功能
4. **深入特定模块** - 选择感兴趣的 JVM 组件进行研究

现在你就可以在 CLion 中愉快地研究 JVM 内部实现了！🎉