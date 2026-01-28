cmake_minimum_required(VERSION 3.16)
project(OpenJDK11_CutNew)

# 支持的语言（包含汇编）
enable_language(C CXX ASM)

# 设置 C/C++ 标准
set(CMAKE_C_STANDARD 99)
set(CMAKE_CXX_STANDARD 98)

# 设置构建类型为 Debug（对应 slowdebug）
set(CMAKE_BUILD_TYPE Debug)

# 构建产物根目录（方便后续引用）
set(BUILD_OUTPUT_DIR ${CMAKE_SOURCE_DIR}/build/linux-x86_64-normal-server-slowdebug)

# ========== 编译选项设置 ==========
# HotSpot 关键编译选项（参考大佬版本）
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -g -O0 -fPIC -fcheck-new -Wno-deprecated-declarations -fpermissive -fno-omit-frame-pointer -std=gnu++98")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -g -O0 -fPIC -Wno-deprecated-declarations -fno-omit-frame-pointer")

# ASM 汇编选项（HotSpot 需要）
set(ASM_OPTIONS "-x assembler-with-cpp")
set(CMAKE_ASM_FLAGS "${CMAKE_C_FLAGS} ${ASM_OPTIONS}")

# ========== 宏定义设置 ==========
# 基础系统宏
add_definitions(
    -DLINUX
    -D_GNU_SOURCE
    -D_REENTRANT
    -D_LARGEFILE64_SOURCE
    -DDEBUG
    -DASSERT
    -DAMD64
    -D_LP64=1
    -DVM_LITTLE_ENDIAN
)

# 目标平台宏
add_definitions(
    -DTARGET_ARCH_x86
    -DTARGET_OS_FAMILY_linux
    -DTARGET_ARCH_MODEL_x86_64
    -DTARGET_OS_ARCH_linux_x86
    -DTARGET_OS_ARCH_MODEL_linux_x86_64
    -DTARGET_COMPILER_gcc
)

# HotSpot 特性宏
add_definitions(
    -DCOMPILER1
    -DCOMPILER2
    -DINCLUDE_ALL_GCS
    -DINCLUDE_JVMTI=1
    -DINCLUDE_SHENANDOAHGC=0
    -DHOTSPOT_LIB_ARCH="amd64"
    -DHOTSPOT_RELEASE_VERSION="11.0.20+8"
    -DHOTSPOT_BUILD_TARGET="slowdebug"
    -DHOTSPOT_BUILD_USER="openjdk-cut-new"
    -DHOTSPOT_VM_DISTRO="OpenJDK"
    -DJRE_RELEASE_VERSION="11.0.20-internal"
)

# 包含路径宏
add_definitions(
    -DINCLUDE_SUFFIX_OS=_linux
    -DINCLUDE_SUFFIX_CPU=_x86
    -DINCLUDE_SUFFIX_COMPILER=_gcc
)

# ========== 包含目录设置 ==========
include_directories(
    # ========== 源码目录 ==========
    # HotSpot 核心（参考大佬版本的简洁路径）
    src/hotspot/share
    src/hotspot/share/precompiled
    src/hotspot/share/include
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

# ========== HotSpot JVM 源码收集 ==========
# 递归扫描 HotSpot 源码（参考大佬版本的简洁方式）
file(GLOB_RECURSE HOTSPOT_SOURCES
    "src/hotspot/share/*.cpp"
    "src/hotspot/share/*.c"
    "src/hotspot/share/*.s"
    "src/hotspot/os/linux/*.cpp"
    "src/hotspot/os/linux/*.c"
    "src/hotspot/os/linux/*.s"
    "src/hotspot/os/posix/*.cpp"
    "src/hotspot/os/posix/*.c"
    "src/hotspot/os/posix/*.s"
    "src/hotspot/cpu/x86/*.cpp"
    "src/hotspot/cpu/x86/*.c"
    "src/hotspot/cpu/x86/*.s"
    "src/hotspot/os_cpu/linux_x86/*.cpp"
    "src/hotspot/os_cpu/linux_x86/*.c"
    "src/hotspot/os_cpu/linux_x86/*.s"
)

# 排除特殊文件（参考大佬版本）
list(FILTER HOTSPOT_SOURCES EXCLUDE REGEX ".*test.*")
list(FILTER HOTSPOT_SOURCES EXCLUDE REGEX ".*Test.*")
list(FILTER HOTSPOT_SOURCES EXCLUDE REGEX ".*/adlc/.*")  # 排除 adlc 目录

# Java 基础库源码
file(GLOB_RECURSE JAVA_BASE_SOURCES
    "src/java.base/share/native/*.c"
    "src/java.base/unix/native/*.c"
    "src/java.base/linux/native/*.c"
)

# ========== 创建 HotSpot 库目标 ==========
# 🎯 关键：直接替换我们本地已编译好的 libjvm.so！
# 这样修改 HotSpot 代码后，编译 2-3 分钟就能立即测试新逻辑
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${BUILD_OUTPUT_DIR}/jdk/lib/server)

# 创建 HotSpot 共享库
add_library(jvm SHARED ${HOTSPOT_SOURCES})

# 编译特性（参考大佬版本）
target_compile_features(jvm PRIVATE c_std_99 cxx_std_98)

# HotSpot 特定的包含目录
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

# 链接库（参考大佬版本）
target_link_libraries(jvm dl pthread)

# ========== 创建 Java 基础库目标 ==========
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

set_target_properties(java_base PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${BUILD_OUTPUT_DIR}/jdk/lib"
)

# ========== 调试入口程序 ==========
# 参考大佬版本，创建调试入口（如果存在 main.cpp）
if(EXISTS "${CMAKE_SOURCE_DIR}/main.cpp")
    set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "bin")
    add_executable(main_debug main.cpp)
    
    target_include_directories(main_debug PUBLIC
        src/hotspot/share/precompiled
        src/hotspot/share
    )
    
    target_compile_options(main_debug PRIVATE "-std=c++11")
    target_link_libraries(main_debug PUBLIC dl)
endif()

# ========== 自定义构建目标 ==========
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

# ========== 快速开发工作流说明 ==========
# 🚀 使用方法：
# 1. 修改 HotSpot 源码：vim src/hotspot/share/gc/g1/g1CollectedHeap.cpp
# 2. 快速编译：make -j8 jvm  (2-3 分钟，直接覆盖现有 libjvm.so)
# 3. 立即测试：./build/.../jdk/bin/java -XX:+UseG1GC MyTest
# 4. 调试：gdb --args ./build/.../jdk/bin/java -XX:+UseG1GC MyTest

# 测试目标
add_custom_target(test_java
    COMMAND ${CMAKE_SOURCE_DIR}/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java -version
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Testing built JDK"
)

# ========== 快速验证脚本 ==========
# 添加快速验证目标
add_custom_target(quick_test
    COMMAND echo "=== 验证 libjvm.so 替换成功 ==="
    COMMAND ls -la ${BUILD_OUTPUT_DIR}/jdk/lib/server/libjvm.so
    COMMAND echo "=== 测试 JVM 启动 ==="
    COMMAND ${BUILD_OUTPUT_DIR}/jdk/bin/java -version
    COMMAND echo "=== 测试 HotSpot 选项 ==="
    COMMAND ${BUILD_OUTPUT_DIR}/jdk/bin/java -XX:+PrintGCDetails -version
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Quick verification of replaced libjvm.so"
)

# 编译并立即测试
add_custom_target(build_and_test
    DEPENDS jvm
    COMMAND ${CMAKE_COMMAND} --build . --target quick_test
    COMMENT "Build JVM and run quick test"
)

# ========== 编译命令数据库生成 ==========
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)