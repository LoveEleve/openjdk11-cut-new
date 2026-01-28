# 从零开始拆分 OpenJDK 11 源码教程

本教程将指导你如何从一个原始的 OpenJDK 11 源码（未构建过）创建一个支持模块化拆分构建的版本，实现**只重编你修改的模块**，大幅提升 JVM 研究与调试效率。

## 📋 前置条件

### 系统要求
- **操作系统**: Linux (推荐 Ubuntu 18.04+)
- **内存**: 至少 16GB (推荐 32GB)
- **磁盘空间**: 至少 50GB 可用空间
- **CPU**: 多核处理器 (推荐 8 核+)

### 必需工具
```bash
# Ubuntu/Debian 系统
sudo apt update
sudo apt install -y \
    build-essential \
    autoconf \
    zip \
    unzip \
    libx11-dev \
    libxext-dev \
    libxrender-dev \
    libxrandr-dev \
    libxtst-dev \
    libxt-dev \
    libcups2-dev \
    libfontconfig1-dev \
    libasound2-dev \
    cmake \
    git \
    wget

# 安装 JDK 8 或 11 (用于 bootstrap)
sudo apt install -y openjdk-11-jdk

# 验证 Java 版本
java -version
javac -version
```

---

## 🎯 第一步：获取原始 OpenJDK 11 源码

### 方法 A：从 OpenJDK 官方获取
```bash
# 创建工作目录
mkdir -p ~/openjdk-workspace
cd ~/openjdk-workspace

# 克隆 OpenJDK 11 源码
git clone https://github.com/openjdk/jdk11u.git openjdk11-original
cd openjdk11-original

# 切换到稳定版本 (推荐)
git checkout jdk-11.0.20+8  # 或其他稳定 tag
```

### 方法 B：从现有项目复制
```bash
# 如果你已有 OpenJDK 11 源码
cp -r /path/to/your/openjdk11-core ~/openjdk-workspace/openjdk11-original
cd ~/openjdk-workspace/openjdk11-original
```

---

## 🔧 第二步：初始配置与验证

### 2.1 配置构建环境
```bash
cd ~/openjdk-workspace/openjdk11-original

# 运行 configure 脚本
bash configure \
    --with-debug-level=slowdebug \
    --with-native-debug-symbols=internal \
    --with-jvm-variants=server \
    --disable-warnings-as-errors \
    --with-boot-jdk=/usr/lib/jvm/java-11-openjdk-amd64

# 检查配置结果
echo "配置完成，检查 build/*/spec.gmk 是否生成"
ls -la build/*/spec.gmk
```

### 2.2 验证原始构建能力
```bash
# 尝试完整构建 (这一步可能需要 1-2 小时)
make images

# 验证构建结果
./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java -version
```

**⚠️ 重要**: 如果这一步失败，请先解决构建问题再继续。

---

## 🚀 第三步：创建拆分版本

### 3.1 复制源码创建拆分版本
```bash
cd ~/openjdk-workspace

# 复制整个源码树
cp -r openjdk11-original openjdk11-cut-new
cd openjdk11-cut-new

# 清理之前的构建产物 (如果有)
make clean
rm -rf build/
```

### 3.2 创建拆分构建配置目录
```bash
# 创建 build-config 目录
mkdir -p build-config

# 创建 spec.gmk 配置文件
cat > build-config/spec.gmk << 'EOF'
# OpenJDK Cut-New Split Build Configuration
# Generated from original configure

# 基础配置 (需要根据你的 configure 输出调整)
SPEC := linux-x86_64-normal-server-slowdebug
CONF_NAME := linux-x86_64-normal-server-slowdebug
OPENJDK_BUILD_OS := linux
OPENJDK_BUILD_OS_TYPE := unix
OPENJDK_BUILD_CPU := x86_64
OPENJDK_TARGET_OS := linux
OPENJDK_TARGET_OS_TYPE := unix
OPENJDK_TARGET_CPU := x86_64

# 构建工具路径
BOOT_JDK := /usr/lib/jvm/java-11-openjdk-amd64
TOOLCHAIN_TYPE := gcc
CC := gcc
CXX := g++
LD := ld
AR := ar
STRIP := strip
NM := nm
OBJCOPY := objcopy
OBJDUMP := objdump

# 编译选项
DEBUG_LEVEL := slowdebug
HOTSPOT_DEBUG_LEVEL := slowdebug
JVM_VARIANTS := server
JVM_VARIANT_SERVER := true

# 路径配置
OUTPUTDIR := $(TOPDIR)/build/$(CONF_NAME)
BUILDTOOLS_OUTPUTDIR := $(OUTPUTDIR)/buildtools
HOTSPOT_OUTPUTDIR := $(OUTPUTDIR)/hotspot
JDK_OUTPUTDIR := $(OUTPUTDIR)/jdk
IMAGES_OUTPUTDIR := $(OUTPUTDIR)/images
BUNDLES_OUTPUTDIR := $(OUTPUTDIR)/bundles
TESTMAKE_OUTPUTDIR := $(OUTPUTDIR)/test-make
MAKESUPPORT_OUTPUTDIR := $(OUTPUTDIR)/make-support

# 包含原始构建系统
include $(TOPDIR)/make/common/MakeBase.gmk
include $(TOPDIR)/make/common/Modules.gmk
EOF
```

### 3.3 创建模块依赖配置
```bash
# 创建模块依赖文件
cat > build-config/module-deps.gmk << 'EOF'
# 模块依赖关系定义
# 基础模块
DEPS_java.base :=
TRANSITIVE_MODULES_java.base :=

# 核心模块依赖
DEPS_java.compiler := java.base
TRANSITIVE_MODULES_java.compiler := java.base

DEPS_java.desktop := java.base java.prefs java.datatransfer java.xml
TRANSITIVE_MODULES_java.desktop := java.base java.datatransfer java.xml

DEPS_java.logging := java.base
TRANSITIVE_MODULES_java.logging := java.base

DEPS_java.management := java.base
TRANSITIVE_MODULES_java.management := java.base

# JDK 工具模块
DEPS_jdk.compiler := java.base java.compiler
TRANSITIVE_MODULES_jdk.compiler := java.base java.compiler

DEPS_jdk.jdeps := java.base java.compiler jdk.compiler
TRANSITIVE_MODULES_jdk.jdeps := java.base

DEPS_jdk.jlink := java.base jdk.internal.opt jdk.jdeps
TRANSITIVE_MODULES_jdk.jlink := java.base

DEPS_jdk.javadoc := java.base java.xml java.compiler jdk.compiler
TRANSITIVE_MODULES_jdk.javadoc := java.base java.compiler jdk.compiler

# 更多模块依赖可以根据需要添加...
EOF
```

### 3.4 创建拆分构建主文件
```bash
# 创建主要的拆分构建逻辑
cat > build-config/main-targets.gmk << 'EOF'
# Split Build Targets for OpenJDK 11

# 定义所有可拆分的目标
SPLIT_PHASES := gensrc java libs launchers

# HotSpot 拆分目标
split-hotspot-gensrc:
	$(MAKE) -f $(TOPDIR)/make/hotspot/Hotspot.gmk hotspot-gensrc

split-hotspot-libs:
	$(MAKE) -f $(TOPDIR)/make/hotspot/Hotspot.gmk hotspot-libs

split-hotspot: split-hotspot-gensrc split-hotspot-libs

# java.base 拆分目标
split-java.base-gensrc:
	$(MAKE) -f $(TOPDIR)/make/Main.gmk java.base-gensrc

split-java.base-java:
	$(MAKE) -f $(TOPDIR)/make/Main.gmk java.base-java

split-java.base-libs:
	$(MAKE) -f $(TOPDIR)/make/Main.gmk java.base-libs

split-java.base-launchers:
	$(MAKE) -f $(TOPDIR)/make/Main.gmk java.base-launchers

split-java.base: split-java.base-gensrc split-java.base-java split-java.base-libs split-java.base-launchers

# 其他核心模块拆分目标
split-java.compiler:
	$(MAKE) -f $(TOPDIR)/make/Main.gmk java.compiler

split-java.desktop:
	$(MAKE) -f $(TOPDIR)/make/Main.gmk java.desktop

split-jdk.compiler:
	$(MAKE) -f $(TOPDIR)/make/Main.gmk jdk.compiler

split-jdk.jdeps:
	$(MAKE) -f $(TOPDIR)/make/Main.gmk jdk.jdeps

split-jdk.jlink:
	$(MAKE) -f $(TOPDIR)/make/Main.gmk jdk.jlink

split-jdk.javadoc:
	$(MAKE) -f $(TOPDIR)/make/Main.gmk jdk.javadoc

# 便捷目标
split-all-core: split-hotspot split-java.base split-java.compiler split-jdk.compiler

.PHONY: split-hotspot-gensrc split-hotspot-libs split-hotspot \
        split-java.base-gensrc split-java.base-java split-java.base-libs split-java.base-launchers split-java.base \
        split-java.compiler split-java.desktop split-jdk.compiler split-jdk.jdeps split-jdk.jlink split-jdk.javadoc \
        split-all-core
EOF
```

---

## 🛠️ 第四步：修改构建系统集成拆分功能

### 4.1 修改主 Makefile
```bash
# 备份原始 Makefile
cp Makefile Makefile.original

# 在 Makefile 末尾添加拆分构建支持
cat >> Makefile << 'EOF'

# ========== Split Build Support ==========
# Include split build configuration
-include build-config/spec.gmk
-include build-config/module-deps.gmk
-include build-config/main-targets.gmk

# Split build entry point
split-%:
	@echo "Building split target: $*"
	$(MAKE) -f build-config/main-targets.gmk split-$*

# Help for split targets
split-help:
	@echo "Available split targets:"
	@echo "  split-hotspot          - Build HotSpot JVM only"
	@echo "  split-java.base        - Build java.base module only"
	@echo "  split-java.compiler    - Build java.compiler module only"
	@echo "  split-jdk.compiler     - Build jdk.compiler (javac) only"
	@echo "  split-jdk.jdeps        - Build jdk.jdeps tool only"
	@echo "  split-jdk.jlink        - Build jdk.jlink tool only"
	@echo "  split-jdk.javadoc      - Build jdk.javadoc tool only"
	@echo "  split-all-core         - Build all core components"

.PHONY: split-help
EOF
```

### 4.2 修改 make/Main.gmk 支持拆分
```bash
# 备份原始文件
cp make/Main.gmk make/Main.gmk.original

# 在 make/Main.gmk 开头添加拆分支持
sed -i '1i# Split Build Support\n-include $(TOPDIR)/build-config/spec.gmk\n-include $(TOPDIR)/build-config/module-deps.gmk\n' make/Main.gmk
```

---

## 🎨 第五步：创建 CLion 集成支持

### 5.1 创建 CMakeLists.txt
```bash
cat > CMakeLists.txt << 'EOF'
cmake_minimum_required(VERSION 3.16)
project(OpenJDK11_CutNew)

# 设置 C/C++ 标准
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 14)

# 设置构建类型为 Debug（对应 slowdebug）
set(CMAKE_BUILD_TYPE Debug)

# 构建产物根目录（方便后续引用）
set(BUILD_OUTPUT_DIR ${CMAKE_SOURCE_DIR}/build/linux-x86_64-normal-server-slowdebug)

# 设置通用编译选项
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -g -O0 -fno-omit-frame-pointer")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -g -O0 -fno-omit-frame-pointer -std=gnu++98")

# 添加全局包含目录
include_directories(
    # ========== 源码目录 ==========
    # HotSpot 核心
    src/hotspot/share
    src/hotspot/share/include
    src/hotspot/share/precompiled
    src/hotspot/share/utilities
    src/hotspot/os/linux
    src/hotspot/os/posix
    src/hotspot/os/posix/include
    src/hotspot/cpu/x86
    src/hotspot/os_cpu/linux_x86
    
    # java.base native
    src/java.base/share/native/include
    src/java.base/share/native/libjava
    src/java.base/share/native/libjli
    src/java.base/share/native/libnet
    src/java.base/share/native/libnio
    src/java.base/share/native/libzip
    src/java.base/share/native/libverify
    src/java.base/unix/native/include
    src/java.base/unix/native/libjava
    src/java.base/unix/native/libjli
    src/java.base/unix/native/libnet
    src/java.base/unix/native/libnio
    src/java.base/linux/native/include
    src/java.base/linux/native/libjava
    
    # ========== 构建生成的头文件目录 ==========
    # modules_include（包含 jni.h, jvmti.h 等核心头文件）
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base/linux
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.desktop
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.desktop/linux
    ${BUILD_OUTPUT_DIR}/support/modules_include/jdk.jdwp.agent
    
    # headers（JNI 头文件，由 javah/javac -h 生成）
    ${BUILD_OUTPUT_DIR}/support/headers/java.base
    ${BUILD_OUTPUT_DIR}/support/headers/java.desktop
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.net
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.management
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.sctp
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.crypto.cryptoki
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.crypto.ec
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.pack
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.security.auth
    
    # HotSpot 生成文件（ad文件、jvmti、jfr、dtrace 等）
    ${BUILD_OUTPUT_DIR}/hotspot/variant-server/gensrc
    ${BUILD_OUTPUT_DIR}/hotspot/variant-server/gensrc/adfiles
    ${BUILD_OUTPUT_DIR}/hotspot/variant-server/gensrc/jvmtifiles
    ${BUILD_OUTPUT_DIR}/hotspot/variant-server/gensrc/jfrfiles
    ${BUILD_OUTPUT_DIR}/hotspot/variant-server/gensrc/dtracefiles
)

# 添加预处理器定义
add_definitions(
    -DLINUX
    -D_GNU_SOURCE
    -D_REENTRANT
    -D_LARGEFILE64_SOURCE
    -DDEBUG
    -DASSERT
    -DAMD64
    -D_LP64=1
    -DTARGET_ARCH_x86
    -DINCLUDE_SUFFIX_OS=_linux
    -DINCLUDE_SUFFIX_CPU=_x86
    -DINCLUDE_SUFFIX_COMPILER=_gcc
    -DTARGET_COMPILER_gcc
    -DHOTSPOT_LIB_ARCH="amd64"
    -DCOMPILER1
    -DCOMPILER2
    -DINCLUDE_SHENANDOAHGC=0
)

# HotSpot JVM 源码
file(GLOB_RECURSE HOTSPOT_SOURCES
    "src/hotspot/share/*.cpp"
    "src/hotspot/share/*.c"
    "src/hotspot/os/linux/*.cpp"
    "src/hotspot/os/linux/*.c"
    "src/hotspot/os/posix/*.cpp"
    "src/hotspot/os/posix/*.c"
    "src/hotspot/cpu/x86/*.cpp"
    "src/hotspot/cpu/x86/*.c"
    "src/hotspot/os_cpu/linux_x86/*.cpp"
    "src/hotspot/os_cpu/linux_x86/*.c"
)

# 排除一些特殊文件
list(FILTER HOTSPOT_SOURCES EXCLUDE REGEX ".*test.*")
list(FILTER HOTSPOT_SOURCES EXCLUDE REGEX ".*Test.*")

# Java 基础库源码
file(GLOB_RECURSE JAVA_BASE_SOURCES
    "src/java.base/share/native/*.c"
    "src/java.base/unix/native/*.c"
    "src/java.base/linux/native/*.c"
)

# 创建 HotSpot 库目标
add_library(jvm SHARED ${HOTSPOT_SOURCES})
target_include_directories(jvm PRIVATE
    src/hotspot/share
    src/hotspot/share/precompiled
    src/hotspot/share/utilities
    src/hotspot/os/linux
    src/hotspot/os/posix
    src/hotspot/cpu/x86
    src/hotspot/os_cpu/linux_x86
    ${BUILD_OUTPUT_DIR}/hotspot/variant-server/gensrc
    ${BUILD_OUTPUT_DIR}/hotspot/variant-server/gensrc/adfiles
    ${BUILD_OUTPUT_DIR}/hotspot/variant-server/gensrc/jvmtifiles
    ${BUILD_OUTPUT_DIR}/hotspot/variant-server/gensrc/jfrfiles
)

# 创建 Java 基础库目标
add_library(java_base SHARED ${JAVA_BASE_SOURCES})
target_include_directories(java_base PRIVATE
    src/java.base/share/native/libjava
    src/java.base/share/native/libjli
    src/java.base/share/native/libnet
    src/java.base/share/native/libnio
    src/java.base/share/native/libzip
    src/java.base/share/native/libverify
    src/java.base/unix/native/libjava
    src/java.base/unix/native/libjli
    src/java.base/unix/native/libnet
    src/java.base/unix/native/libnio
    src/java.base/linux/native/libjava
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base/linux
    ${BUILD_OUTPUT_DIR}/support/headers/java.base
)

# 设置输出目录
set_target_properties(jvm PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
)

set_target_properties(java_base PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
)

# 添加自定义目标用于构建
add_custom_target(build_split_hotspot
    COMMAND make -f make/Main.gmk SPEC=${CMAKE_SOURCE_DIR}/build-config/spec.gmk split-hotspot-libs
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Building HotSpot using split build system"
)

add_custom_target(build_split_java_base
    COMMAND make -f make/Main.gmk SPEC=${CMAKE_SOURCE_DIR}/build-config/spec.gmk split-java.base-libs
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Building java.base using split build system"
)

# 添加测试目标
add_custom_target(test_java
    COMMAND ${CMAKE_SOURCE_DIR}/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java -version
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Testing built JDK"
)
EOF
```

### 5.2 创建 CLion 使用说明
```bash
cat > README_CLION.md << 'EOF'
# CLion 使用指南

## 打开项目
1. 启动 CLion
2. 选择 "Open CMake Project"
3. 选择项目根目录的 `CMakeLists.txt`

## 调试 JVM
1. 使用 `build_split_hotspot` 配置
2. Executable 设置为: `build/linux-x86_64-normal-server-slowdebug/jdk/bin/java`
3. Program arguments 示例:
   ```
   -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /path/to/your/classes com.example.Main
   ```

## 常用断点位置
- `JNI_CreateJavaVM` - JVM 启动入口
- `Threads::create_vm` - VM 创建主流程
- `Universe::initialize` - 堆初始化
- `G1CollectedHeap::initialize` - G1 GC 初始化

## 构建目标说明
- `build_split_hotspot` - 只构建 HotSpot
- `build_split_java_base` - 只构建 java.base
- `test_java` - 测试构建结果
EOF
```

---

## ⚡ 第六步：首次构建与验证

### 6.1 执行初始完整构建
```bash
# 确保在项目根目录
cd ~/openjdk-workspace/openjdk11-cut-new

# 重新配置 (使用拆分配置)
bash configure \
    --with-debug-level=slowdebug \
    --with-native-debug-symbols=internal \
    --with-jvm-variants=server \
    --disable-warnings-as-errors \
    --with-boot-jdk=/usr/lib/jvm/java-11-openjdk-amd64

# 执行完整构建 (第一次需要)
make images

# 验证构建成功
./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java -version
```

### 6.2 测试拆分构建功能
```bash
# 测试 HotSpot 拆分构建
make split-hotspot-libs

# 测试 java.base 拆分构建
make split-java.base-libs

# 验证拆分构建结果
./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java -version
```

---

## 🎯 第七步：创建使用文档

### 7.1 创建完整使用指南
```bash
cat > OPENJDK_CUT_NEW_GUIDE.md << 'EOF'
# OpenJDK Cut-New 使用指南

## 快速开始

### 常用拆分构建命令
```bash
# 只重编 HotSpot (最常用)
make split-hotspot-libs

# 只重编 java.base
make split-java.base-libs

# 只重编 javac
make split-jdk.compiler

# 查看所有拆分目标
make split-help
```

### 调试 JVM
1. 构建 slowdebug 版本: `make split-hotspot-libs`
2. 启动调试: 
   ```bash
   ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
     -XX:+UnlockDiagnosticVMOptions -XX:+PauseAtStartup \
     -Xms8g -Xmx8g -XX:+UseG1GC -Xint \
     -cp /path/to/classes com.example.Main
   ```
3. 在 CLion 中 Attach 到进程
4. 删除 `./vm.paused.<pid>` 继续执行

## 性能对比
- **传统构建**: 修改一行代码 → 完整重编 → 等待 30-60 分钟
- **拆分构建**: 修改一行代码 → 拆分重编 → 等待 2-5 分钟

## 故障排查
1. 如果拆分构建失败，先尝试完整构建: `make images`
2. 如果头文件找不到，检查 `build/*/support/modules_include/` 是否存在
3. 如果链接失败，确保依赖模块已构建
EOF
```

### 7.2 创建项目说明文件
```bash
cat > PROJECT_STRUCTURE.md << 'EOF'
# 项目结构说明

## 核心目录
```
openjdk11-cut-new/
├── src/                          # 源码目录
│   ├── hotspot/                  # HotSpot JVM 源码
│   ├── java.base/                # Java 核心库
│   ├── java.compiler/            # Java 编译器 API
│   └── jdk.*/                    # JDK 工具模块
├── make/                         # 原始构建系统
├── build-config/                 # 拆分构建配置 (新增)
│   ├── spec.gmk                  # 构建规格配置
│   ├── module-deps.gmk           # 模块依赖关系
│   └── main-targets.gmk          # 拆分构建目标
├── build/                        # 构建输出目录
│   └── linux-x86_64-normal-server-slowdebug/
│       ├── jdk/                  # 完整 JDK
│       ├── hotspot/              # HotSpot 构建产物
│       └── support/              # 支持文件和头文件
├── CMakeLists.txt                # CLion 项目配置 (新增)
├── README_CLION.md               # CLion 使用说明 (新增)
└── OPENJDK_CUT_NEW_GUIDE.md      # 使用指南 (新增)
```

## 拆分构建原理
1. **模块依赖分析**: 通过 `module-deps.gmk` 定义模块间依赖关系
2. **增量构建**: 只重编修改的模块及其依赖
3. **并行构建**: 无依赖关系的模块可并行构建
4. **调试友好**: 保持完整的调试符号和源码映射
EOF
```

---

## ✅ 第八步：验证与测试

### 8.1 功能验证清单
```bash
# 创建验证脚本
cat > verify_split_build.sh << 'EOF'
#!/bin/bash

echo "=== OpenJDK Cut-New 验证脚本 ==="

# 1. 验证基础构建
echo "1. 验证完整构建..."
if ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java -version; then
    echo "✅ 完整构建验证成功"
else
    echo "❌ 完整构建验证失败"
    exit 1
fi

# 2. 验证拆分构建
echo "2. 验证 HotSpot 拆分构建..."
if make split-hotspot-libs; then
    echo "✅ HotSpot 拆分构建成功"
else
    echo "❌ HotSpot 拆分构建失败"
    exit 1
fi

# 3. 验证 java.base 拆分构建
echo "3. 验证 java.base 拆分构建..."
if make split-java.base-libs; then
    echo "✅ java.base 拆分构建成功"
else
    echo "❌ java.base 拆分构建失败"
    exit 1
fi

# 4. 验证调试符号
echo "4. 验证调试符号..."
if file build/linux-x86_64-normal-server-slowdebug/jdk/lib/server/libjvm.so | grep -q "with debug_info"; then
    echo "✅ 调试符号验证成功"
else
    echo "❌ 调试符号验证失败"
fi

# 5. 验证 CLion 配置
echo "5. 验证 CLion 配置..."
if [ -f CMakeLists.txt ] && [ -f README_CLION.md ]; then
    echo "✅ CLion 配置文件存在"
else
    echo "❌ CLion 配置文件缺失"
fi

echo "=== 验证完成 ==="
EOF

chmod +x verify_split_build.sh
./verify_split_build.sh
```

### 8.2 性能测试
```bash
# 创建性能测试脚本
cat > performance_test.sh << 'EOF'
#!/bin/bash

echo "=== 构建性能测试 ==="

# 修改一个 HotSpot 文件 (添加注释)
echo "// Performance test comment" >> src/hotspot/share/runtime/globals.hpp

# 测试拆分构建时间
echo "测试拆分构建时间..."
time make split-hotspot-libs

# 恢复文件
git checkout src/hotspot/share/runtime/globals.hpp

echo "=== 性能测试完成 ==="
EOF

chmod +x performance_test.sh
```

---

## 📚 第九步：创建完整文档

### 9.1 创建 README.md
```bash
cat > README.md << 'EOF'
# OpenJDK 11 Cut-New - 模块化拆分构建版本

## 🎯 项目目标
将 OpenJDK 11 改造为支持**模块化拆分构建**的版本，实现：
- ⚡ **快速增量编译**: 只重编修改的模块 (2-5分钟 vs 30-60分钟)
- 🔍 **高效调试体验**: 完整调试符号 + CLion 集成
- 🧩 **模块化管理**: 按需构建 HotSpot、java.base、工具等

## 🚀 快速开始

### 构建
```bash
# 完整构建 (首次)
make images

# 拆分构建 (日常使用)
make split-hotspot-libs      # 只编 HotSpot
make split-java.base-libs    # 只编 java.base
make split-jdk.compiler      # 只编 javac
```

### 调试
```bash
# 启动可调试的 JVM
./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
  -XX:+UnlockDiagnosticVMOptions -XX:+PauseAtStartup \
  -Xms8g -Xmx8g -XX:+UseG1GC -Xint \
  -cp /path/to/classes com.example.Main

# 在 CLion 中 Attach 进程，然后删除暂停文件继续
rm ./vm.paused.<pid>
```

## 📖 详细文档
- [完整拆分教程](doc/HOW_TO_SPLIT_OPENJDK11_FROM_SCRATCH.md)
- [CLion 使用指南](README_CLION.md)
- [项目使用指南](OPENJDK_CUT_NEW_GUIDE.md)

## 🏗️ 项目结构
```
├── src/                    # OpenJDK 源码
├── build-config/           # 拆分构建配置
├── CMakeLists.txt          # CLion 项目配置
└── doc/                    # 文档目录
```

## 🤝 贡献
欢迎提交 Issue 和 Pull Request！
EOF
```

### 9.2 创建文档目录
```bash
# 创建文档目录并移动文档
mkdir -p doc
mv HOW_TO_SPLIT_OPENJDK11_FROM_SCRATCH.md doc/
mv PROJECT_STRUCTURE.md doc/

# 创建文档索引
cat > doc/README.md << 'EOF'
# 文档索引

## 教程文档
- [从零开始拆分 OpenJDK 11 教程](HOW_TO_SPLIT_OPENJDK11_FROM_SCRATCH.md) - 完整的拆分步骤指南
- [项目结构说明](PROJECT_STRUCTURE.md) - 项目目录和文件说明

## 使用文档
- [CLion 使用指南](../README_CLION.md) - CLion 调试配置
- [项目使用指南](../OPENJDK_CUT_NEW_GUIDE.md) - 日常使用命令

## 脚本工具
- `verify_split_build.sh` - 验证拆分构建功能
- `performance_test.sh` - 构建性能测试
EOF
```

---

## 🎉 完成！

### 最终验证
```bash
# 运行完整验证
./verify_split_build.sh

# 如果一切正常，你现在拥有了：
echo "🎉 恭喜！你已成功创建了 OpenJDK 11 拆分构建版本"
echo "📁 项目位置: $(pwd)"
echo "🚀 开始使用: make split-hotspot-libs"
echo "🔍 调试指南: 查看 README_CLION.md"
```

### 下一步建议
1. **熟悉拆分构建**: 尝试修改 HotSpot 源码并使用 `make split-hotspot-libs`
2. **配置 CLion**: 按照 `README_CLION.md` 配置调试环境
3. **探索模块**: 根据研究方向选择对应的拆分目标
4. **性能优化**: 根据需要调整并行构建参数

---

## 📞 获取帮助

如果遇到问题：
1. 检查 `verify_split_build.sh` 输出
2. 查看构建日志中的错误信息
3. 确认所有依赖工具已正确安装
4. 参考原始 OpenJDK 构建文档

**祝你在 JVM 研究之路上取得成功！** 🚀