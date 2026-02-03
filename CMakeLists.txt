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
    
    # java.instrument (libinstrument - Java Agent/Instrumentation API)
    src/java.instrument/share/native/libinstrument
    src/java.instrument/unix/native/libinstrument
    
    # jdk.attach (libattach - Attach API)
    src/jdk.attach/linux/native/libattach
    
    # libnio (Java NIO)
    src/java.base/share/native/libnio
    src/java.base/share/native/libnio/ch
    src/java.base/unix/native/libnio
    src/java.base/unix/native/libnio/ch
    src/java.base/unix/native/libnio/fs
    src/java.base/linux/native/libnio
    src/java.base/linux/native/libnio/ch
    src/java.base/linux/native/libnio/fs
    
    # libzip (JAR/ZIP)
    src/java.base/share/native/libzip
    src/java.base/share/native/libzip/zlib
    
    # libverify (字节码验证)
    src/java.base/share/native/libverify
    
    # libjdwp (JDWP 调试协议)
    src/jdk.jdwp.agent/share/native/libjdwp
    src/jdk.jdwp.agent/share/native/include
    src/jdk.jdwp.agent/unix/native/libjdwp
    
    # libmanagement_ext (JMX 监控)
    src/jdk.management/share/native/libmanagement_ext
    src/jdk.management/unix/native/libmanagement_ext
    src/jdk.management/linux/native/libmanagement_ext
    
    # libsaproc (SA 诊断工具)
    src/jdk.hotspot.agent/linux/native/libsaproc
    src/jdk.hotspot.agent/share/native/libsaproc
    
    # libjsig (信号处理链)
    src/java.base/unix/native/libjsig
    
    # libjimage (模块镜像)
    src/java.base/share/native/libjimage
    
    # libmanagement (JMX 基础)
    src/java.management/share/native/libmanagement
    
    # librmi (RMI)
    src/java.rmi/share/native/librmi
    
    # libsctp (SCTP 协议)
    src/jdk.sctp/unix/native/libsctp
    
    # libextnet (扩展网络)
    src/jdk.net/linux/native/libextnet
    
    # libprefs (Preferences)
    src/java.prefs/unix/native/libprefs
    
    # libunpack (Pack200)
    src/jdk.pack/share/native/common-unpack
    src/jdk.pack/share/native/libunpack
    
    # libdt_socket (调试传输)
    src/jdk.jdwp.agent/share/native/libdt_socket
    src/jdk.jdwp.agent/unix/native/libdt_socket
    
    # libmanagement_agent (JMX 远程代理)
    src/jdk.management.agent/unix/native/libmanagement_agent
    
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
    ${BUILD_OUTPUT_DIR}/support/headers/java.instrument
    ${BUILD_OUTPUT_DIR}/support/headers/java.management
    ${BUILD_OUTPUT_DIR}/support/headers/java.prefs
    ${BUILD_OUTPUT_DIR}/support/headers/java.rmi
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.attach
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.jdwp.agent
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.management
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.hotspot.agent
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.net
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.sctp
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.pack
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.management.agent
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

# ========== 创建 libinstrument 库目标（Java Agent/Instrumentation API）==========
# 这是 Arthas、SkyWalking 等 APM 工具的底层核心
# 收集 libinstrument 源码
file(GLOB LIBINSTRUMENT_SOURCES
    "src/java.instrument/share/native/libinstrument/*.c"
    "src/java.instrument/unix/native/libinstrument/*.c"
)

# 创建 libinstrument 共享库
add_library(instrument SHARED ${LIBINSTRUMENT_SOURCES})

# 设置包含目录
target_include_directories(instrument PRIVATE
    # libinstrument 自身头文件
    src/java.instrument/share/native/libinstrument
    src/java.instrument/unix/native/libinstrument
    
    # JNI 和 JVMTI 头文件
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base/linux
    
    # 生成的 JNI 头文件
    ${BUILD_OUTPUT_DIR}/support/headers/java.instrument
    ${BUILD_OUTPUT_DIR}/support/headers/java.base
    
    # java.base native（依赖一些通用工具）
    src/java.base/share/native/libjava
    src/java.base/share/native/libjli
    src/java.base/unix/native/libjava
    src/java.base/unix/native/libjli
    
    # JVMTI 生成文件
    ${BUILD_OUTPUT_DIR}/hotspot/variant-server/gensrc/jvmtifiles
)

# libinstrument 特定的编译选项
target_compile_definitions(instrument PRIVATE
    -DLINUX
    -D_GNU_SOURCE
    -D_REENTRANT
    -DAMD64
    -D_LP64=1
)

# 链接库
target_link_libraries(instrument dl pthread)

# 输出到 JDK lib 目录
set_target_properties(instrument PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${BUILD_OUTPUT_DIR}/jdk/lib"
)

# ========== 创建 libattach 库目标（Attach API）==========
# 这是 Arthas 连接到目标 JVM 的核心 API
# 收集 libattach 源码（Linux 平台）
file(GLOB LIBATTACH_SOURCES
    "src/jdk.attach/linux/native/libattach/*.c"
)

# 创建 libattach 共享库
add_library(attach SHARED ${LIBATTACH_SOURCES})

# 设置包含目录
target_include_directories(attach PRIVATE
    # JNI 头文件
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base/linux
    
    # 生成的 JNI 头文件
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.attach
    ${BUILD_OUTPUT_DIR}/support/headers/java.base
    
    # java.base native
    src/java.base/share/native/libjava
    src/java.base/unix/native/libjava
)

# libattach 特定的编译选项
target_compile_definitions(attach PRIVATE
    -DLINUX
    -D_GNU_SOURCE
    -D_REENTRANT
    -DAMD64
    -D_LP64=1
)

# 链接库
target_link_libraries(attach dl pthread)

# 输出到 JDK lib 目录
set_target_properties(attach PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${BUILD_OUTPUT_DIR}/jdk/lib"
)

# ========== 创建 libnio 库目标（NIO - New I/O）==========
# Java NIO（java.nio）的 native 实现，包含 Channel、Selector、Buffer 等
# 收集 libnio 源码
file(GLOB_RECURSE LIBNIO_SOURCES
    "src/java.base/share/native/libnio/*.c"
    "src/java.base/unix/native/libnio/*.c"
    "src/java.base/linux/native/libnio/*.c"
)

# 创建 libnio 共享库
add_library(nio SHARED ${LIBNIO_SOURCES})

# 设置包含目录
target_include_directories(nio PRIVATE
    # libnio 自身头文件
    src/java.base/share/native/libnio
    src/java.base/share/native/libnio/ch
    src/java.base/unix/native/libnio
    src/java.base/unix/native/libnio/ch
    src/java.base/unix/native/libnio/fs
    src/java.base/linux/native/libnio
    src/java.base/linux/native/libnio/ch
    src/java.base/linux/native/libnio/fs
    
    # java.base 通用头文件
    src/java.base/share/native/libjava
    src/java.base/unix/native/libjava
    src/java.base/share/native/include
    src/java.base/unix/native/include
    
    # JNI 头文件
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base/linux
    
    # 生成的 JNI 头文件
    ${BUILD_OUTPUT_DIR}/support/headers/java.base
)

# libnio 特定的编译选项
target_compile_definitions(nio PRIVATE
    -DLINUX
    -D_GNU_SOURCE
    -D_REENTRANT
    -DAMD64
    -D_LP64=1
)

# 链接库
target_link_libraries(nio dl pthread)

# 输出到 JDK lib 目录
set_target_properties(nio PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${BUILD_OUTPUT_DIR}/jdk/lib"
)

# ========== 创建 libnet 库目标（网络核心）==========
# Socket、DNS 解析、网络编程基础
file(GLOB LIBNET_SOURCES
    "src/java.base/share/native/libnet/*.c"
    "src/java.base/unix/native/libnet/*.c"
    "src/java.base/linux/native/libnet/*.c"
)

add_library(net SHARED ${LIBNET_SOURCES})

target_include_directories(net PRIVATE
    src/java.base/share/native/libnet
    src/java.base/unix/native/libnet
    src/java.base/linux/native/libnet
    src/java.base/share/native/libjava
    src/java.base/unix/native/libjava
    src/java.base/share/native/include
    src/java.base/unix/native/include
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base/linux
    ${BUILD_OUTPUT_DIR}/support/headers/java.base
)

target_compile_definitions(net PRIVATE -DLINUX -D_GNU_SOURCE -D_REENTRANT -DAMD64 -D_LP64=1)
target_link_libraries(net dl pthread)
set_target_properties(net PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${BUILD_OUTPUT_DIR}/jdk/lib")

# ========== 创建 libjava 库目标（Java 核心类 native）==========
# Object、Class、Thread、ClassLoader 等核心类的 native 实现
file(GLOB LIBJAVA_SOURCES
    "src/java.base/share/native/libjava/*.c"
    "src/java.base/unix/native/libjava/*.c"
    "src/java.base/linux/native/libjava/*.c"
)

add_library(java SHARED ${LIBJAVA_SOURCES})

target_include_directories(java PRIVATE
    src/java.base/share/native/libjava
    src/java.base/unix/native/libjava
    src/java.base/linux/native/libjava
    src/java.base/share/native/include
    src/java.base/unix/native/include
    src/java.base/linux/native/include
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base/linux
    ${BUILD_OUTPUT_DIR}/support/headers/java.base
)

target_compile_definitions(java PRIVATE -DLINUX -D_GNU_SOURCE -D_REENTRANT -DAMD64 -D_LP64=1)
target_link_libraries(java dl pthread)
set_target_properties(java PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${BUILD_OUTPUT_DIR}/jdk/lib")

# ========== 创建 libzip 库目标（JAR/ZIP 处理）==========
# 类加载器读取 JAR 文件的核心
file(GLOB LIBZIP_SOURCES
    "src/java.base/share/native/libzip/*.c"
    "src/java.base/share/native/libzip/zlib/*.c"
)

add_library(zip SHARED ${LIBZIP_SOURCES})

target_include_directories(zip PRIVATE
    src/java.base/share/native/libzip
    src/java.base/share/native/libzip/zlib
    src/java.base/share/native/libjava
    src/java.base/share/native/include
    src/java.base/unix/native/include
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base/linux
    ${BUILD_OUTPUT_DIR}/support/headers/java.base
)

target_compile_definitions(zip PRIVATE -DLINUX -D_GNU_SOURCE -D_REENTRANT -DAMD64 -D_LP64=1)
target_link_libraries(zip dl pthread z)
set_target_properties(zip PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${BUILD_OUTPUT_DIR}/jdk/lib")

# ========== 创建 libverify 库目标（字节码验证）==========
# 类加载时的字节码校验
file(GLOB LIBVERIFY_SOURCES
    "src/java.base/share/native/libverify/*.c"
)

add_library(verify SHARED ${LIBVERIFY_SOURCES})

target_include_directories(verify PRIVATE
    src/java.base/share/native/libverify
    src/java.base/share/native/libjava
    src/java.base/share/native/include
    src/java.base/unix/native/include
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base/linux
    ${BUILD_OUTPUT_DIR}/support/headers/java.base
)

target_compile_definitions(verify PRIVATE -DLINUX -D_GNU_SOURCE -D_REENTRANT -DAMD64 -D_LP64=1)
target_link_libraries(verify dl pthread)
set_target_properties(verify PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${BUILD_OUTPUT_DIR}/jdk/lib")

# ========== 创建 libjsig 库目标（信号处理链）==========
# JVM 信号链 - 理解 JVM 如何处理 SIGSEGV、SIGBUS 等信号
# 对于 JVM 崩溃分析、Arthas 底层机制理解很重要
file(GLOB LIBJSIG_SOURCES
    "src/java.base/unix/native/libjsig/*.c"
)

add_library(jsig SHARED ${LIBJSIG_SOURCES})

target_include_directories(jsig PRIVATE
    src/java.base/unix/native/libjsig
    src/java.base/share/native/include
    src/java.base/unix/native/include
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base/linux
)

target_compile_definitions(jsig PRIVATE -DLINUX -D_GNU_SOURCE -D_REENTRANT -DAMD64 -D_LP64=1)
target_link_libraries(jsig dl pthread)
set_target_properties(jsig PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${BUILD_OUTPUT_DIR}/jdk/lib")

# ========== 创建 libjdwp 库目标（JDWP 调试协议）==========
# Java Debug Wire Protocol - IDEA/VSCode 远程调试的底层
file(GLOB_RECURSE LIBJDWP_SOURCES
    "src/jdk.jdwp.agent/share/native/libjdwp/*.c"
    "src/jdk.jdwp.agent/unix/native/libjdwp/*.c"
)

add_library(jdwp SHARED ${LIBJDWP_SOURCES})

target_include_directories(jdwp PRIVATE
    src/jdk.jdwp.agent/share/native/libjdwp
    src/jdk.jdwp.agent/share/native/include
    src/jdk.jdwp.agent/unix/native/libjdwp
    src/java.base/share/native/libjava
    src/java.base/share/native/include
    src/java.base/unix/native/include
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base/linux
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.jdwp.agent
    ${BUILD_OUTPUT_DIR}/support/headers/java.base
    ${BUILD_OUTPUT_DIR}/hotspot/variant-server/gensrc/jvmtifiles
)

target_compile_definitions(jdwp PRIVATE -DLINUX -D_GNU_SOURCE -D_REENTRANT -DAMD64 -D_LP64=1)
target_link_libraries(jdwp dl pthread)
set_target_properties(jdwp PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${BUILD_OUTPUT_DIR}/jdk/lib")

# ========== 创建 libmanagement_ext 库目标（JMX 扩展监控）==========
# jconsole、VisualVM 等监控工具的底层
file(GLOB LIBMANAGEMENT_EXT_SOURCES
    "src/jdk.management/share/native/libmanagement_ext/*.c"
    "src/jdk.management/unix/native/libmanagement_ext/*.c"
    "src/jdk.management/linux/native/libmanagement_ext/*.c"
)

add_library(management_ext SHARED ${LIBMANAGEMENT_EXT_SOURCES})

target_include_directories(management_ext PRIVATE
    src/jdk.management/share/native/libmanagement_ext
    src/jdk.management/unix/native/libmanagement_ext
    src/jdk.management/linux/native/libmanagement_ext
    src/java.base/share/native/libjava
    src/java.base/share/native/include
    src/java.base/unix/native/include
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base/linux
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.management
    ${BUILD_OUTPUT_DIR}/support/headers/java.base
    ${BUILD_OUTPUT_DIR}/hotspot/variant-server/gensrc/jvmtifiles
)

target_compile_definitions(management_ext PRIVATE -DLINUX -D_GNU_SOURCE -D_REENTRANT -DAMD64 -D_LP64=1)
target_link_libraries(management_ext dl pthread)
set_target_properties(management_ext PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${BUILD_OUTPUT_DIR}/jdk/lib")

# ========== 创建 libsaproc 库目标（SA 诊断工具）==========
# jstack、jmap、jinfo 等诊断工具的底层（Serviceability Agent）
file(GLOB LIBSAPROC_SOURCES
    "src/jdk.hotspot.agent/linux/native/libsaproc/*.c"
    "src/jdk.hotspot.agent/share/native/libsaproc/*.c"
)

add_library(saproc SHARED ${LIBSAPROC_SOURCES})

target_include_directories(saproc PRIVATE
    src/jdk.hotspot.agent/linux/native/libsaproc
    src/jdk.hotspot.agent/share/native/libsaproc
    src/java.base/share/native/libjava
    src/java.base/share/native/include
    src/java.base/unix/native/include
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base/linux
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.hotspot.agent
    ${BUILD_OUTPUT_DIR}/support/headers/java.base
)

target_compile_definitions(saproc PRIVATE -DLINUX -D_GNU_SOURCE -D_REENTRANT -DAMD64 -D_LP64=1)
target_link_libraries(saproc dl pthread)
set_target_properties(saproc PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${BUILD_OUTPUT_DIR}/jdk/lib")

# ========== 创建 libjimage 库目标（模块镜像）==========
# JDK 9+ 模块系统核心 - 理解 jrt:// 协议和类加载
file(GLOB LIBJIMAGE_SOURCES
    "src/java.base/share/native/libjimage/*.cpp"
)

add_library(jimage SHARED ${LIBJIMAGE_SOURCES})

target_include_directories(jimage PRIVATE
    src/java.base/share/native/libjimage
    src/java.base/share/native/libjava
    src/java.base/share/native/include
    src/java.base/unix/native/include
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base/linux
    ${BUILD_OUTPUT_DIR}/support/headers/java.base
)

target_compile_definitions(jimage PRIVATE -DLINUX -D_GNU_SOURCE -D_REENTRANT -DAMD64 -D_LP64=1)
target_link_libraries(jimage dl pthread z)
set_target_properties(jimage PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${BUILD_OUTPUT_DIR}/jdk/lib")

# ========== 创建 libmanagement 库目标（JMX 基础监控）==========
# JMX 核心实现 - GC、内存、线程监控
file(GLOB LIBMANAGEMENT_SOURCES
    "src/java.management/share/native/libmanagement/*.c"
)

add_library(management SHARED ${LIBMANAGEMENT_SOURCES})

target_include_directories(management PRIVATE
    src/java.management/share/native/libmanagement
    src/java.base/share/native/libjava
    src/java.base/share/native/include
    src/java.base/unix/native/include
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base/linux
    ${BUILD_OUTPUT_DIR}/support/headers/java.management
    ${BUILD_OUTPUT_DIR}/support/headers/java.base
    ${BUILD_OUTPUT_DIR}/hotspot/variant-server/gensrc/jvmtifiles
)

target_compile_definitions(management PRIVATE -DLINUX -D_GNU_SOURCE -D_REENTRANT -DAMD64 -D_LP64=1)
target_link_libraries(management dl pthread)
set_target_properties(management PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${BUILD_OUTPUT_DIR}/jdk/lib")

# ========== 创建 librmi 库目标（RMI 远程调用）==========
# Java RMI 分布式对象
file(GLOB LIBRMI_SOURCES
    "src/java.rmi/share/native/librmi/*.c"
)

add_library(rmi SHARED ${LIBRMI_SOURCES})

target_include_directories(rmi PRIVATE
    src/java.rmi/share/native/librmi
    src/java.base/share/native/libjava
    src/java.base/share/native/include
    src/java.base/unix/native/include
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base/linux
    ${BUILD_OUTPUT_DIR}/support/headers/java.rmi
    ${BUILD_OUTPUT_DIR}/support/headers/java.base
)

target_compile_definitions(rmi PRIVATE -DLINUX -D_GNU_SOURCE -D_REENTRANT -DAMD64 -D_LP64=1)
target_link_libraries(rmi dl pthread)
set_target_properties(rmi PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${BUILD_OUTPUT_DIR}/jdk/lib")

# ========== 创建 libsctp 库目标（SCTP 协议）==========
# SCTP 流控传输协议 - 电信/5G 场景
file(GLOB LIBSCTP_SOURCES
    "src/jdk.sctp/unix/native/libsctp/*.c"
)

add_library(sctp SHARED ${LIBSCTP_SOURCES})

target_include_directories(sctp PRIVATE
    src/jdk.sctp/unix/native/libsctp
    src/java.base/share/native/libjava
    src/java.base/share/native/libnet
    src/java.base/unix/native/libnet
    src/java.base/share/native/libnio
    src/java.base/unix/native/libnio/ch
    src/java.base/share/native/include
    src/java.base/unix/native/include
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base/linux
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.sctp
    ${BUILD_OUTPUT_DIR}/support/headers/java.base
)

target_compile_definitions(sctp PRIVATE -DLINUX -D_GNU_SOURCE -D_REENTRANT -DAMD64 -D_LP64=1)
target_link_libraries(sctp dl pthread)
set_target_properties(sctp PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${BUILD_OUTPUT_DIR}/jdk/lib")

# ========== 创建 libextnet 库目标（扩展网络）==========
# Unix Domain Socket 等扩展网络功能
file(GLOB LIBEXTNET_SOURCES
    "src/jdk.net/linux/native/libextnet/*.c"
)

add_library(extnet SHARED ${LIBEXTNET_SOURCES})

target_include_directories(extnet PRIVATE
    src/jdk.net/linux/native/libextnet
    src/java.base/share/native/libjava
    src/java.base/share/native/libnet
    src/java.base/unix/native/libnet
    src/java.base/share/native/include
    src/java.base/unix/native/include
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base/linux
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.net
    ${BUILD_OUTPUT_DIR}/support/headers/java.base
)

target_compile_definitions(extnet PRIVATE -DLINUX -D_GNU_SOURCE -D_REENTRANT -DAMD64 -D_LP64=1)
target_link_libraries(extnet dl pthread)
set_target_properties(extnet PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${BUILD_OUTPUT_DIR}/jdk/lib")

# ========== 创建 libprefs 库目标（Preferences API）==========
# Java Preferences 配置存储
file(GLOB LIBPREFS_SOURCES
    "src/java.prefs/unix/native/libprefs/*.c"
)

add_library(prefs SHARED ${LIBPREFS_SOURCES})

target_include_directories(prefs PRIVATE
    src/java.prefs/unix/native/libprefs
    src/java.base/share/native/libjava
    src/java.base/share/native/include
    src/java.base/unix/native/include
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base/linux
    ${BUILD_OUTPUT_DIR}/support/headers/java.prefs
    ${BUILD_OUTPUT_DIR}/support/headers/java.base
)

target_compile_definitions(prefs PRIVATE -DLINUX -D_GNU_SOURCE -D_REENTRANT -DAMD64 -D_LP64=1)
target_link_libraries(prefs dl pthread)
set_target_properties(prefs PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${BUILD_OUTPUT_DIR}/jdk/lib")

# ========== 创建 libunpack 库目标（Pack200 解压）==========
# JAR Pack200 压缩格式处理
file(GLOB_RECURSE LIBUNPACK_SOURCES
    "src/jdk.pack/share/native/common-unpack/*.cpp"
    "src/jdk.pack/share/native/libunpack/*.cpp"
)

add_library(unpack SHARED ${LIBUNPACK_SOURCES})

target_include_directories(unpack PRIVATE
    src/jdk.pack/share/native/common-unpack
    src/jdk.pack/share/native/libunpack
    src/java.base/share/native/libjava
    src/java.base/share/native/include
    src/java.base/unix/native/include
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base/linux
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.pack
    ${BUILD_OUTPUT_DIR}/support/headers/java.base
)

target_compile_definitions(unpack PRIVATE -DLINUX -D_GNU_SOURCE -D_REENTRANT -DAMD64 -D_LP64=1)
target_link_libraries(unpack dl pthread z)
set_target_properties(unpack PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${BUILD_OUTPUT_DIR}/jdk/lib")

# ========== 创建 libdt_socket 库目标（调试传输 Socket）==========
# JDWP 调试 Socket 传输层
file(GLOB LIBDT_SOCKET_SOURCES
    "src/jdk.jdwp.agent/share/native/libdt_socket/*.c"
    "src/jdk.jdwp.agent/unix/native/libdt_socket/*.c"
)

add_library(dt_socket SHARED ${LIBDT_SOCKET_SOURCES})

target_include_directories(dt_socket PRIVATE
    src/jdk.jdwp.agent/share/native/libdt_socket
    src/jdk.jdwp.agent/share/native/include
    src/jdk.jdwp.agent/unix/native/libdt_socket
    src/java.base/share/native/libjava
    src/java.base/share/native/include
    src/java.base/unix/native/include
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base/linux
    ${BUILD_OUTPUT_DIR}/support/headers/java.base
)

target_compile_definitions(dt_socket PRIVATE -DLINUX -D_GNU_SOURCE -D_REENTRANT -DAMD64 -D_LP64=1)
target_link_libraries(dt_socket dl pthread)
set_target_properties(dt_socket PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${BUILD_OUTPUT_DIR}/jdk/lib")

# ========== 创建 libmanagement_agent 库目标（JMX 远程代理）==========
# JMX Remote Agent - jconsole/VisualVM 远程连接
file(GLOB LIBMANAGEMENT_AGENT_SOURCES
    "src/jdk.management.agent/unix/native/libmanagement_agent/*.c"
)

add_library(management_agent SHARED ${LIBMANAGEMENT_AGENT_SOURCES})

target_include_directories(management_agent PRIVATE
    src/jdk.management.agent/unix/native/libmanagement_agent
    src/java.base/share/native/libjava
    src/java.base/share/native/include
    src/java.base/unix/native/include
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base
    ${BUILD_OUTPUT_DIR}/support/modules_include/java.base/linux
    ${BUILD_OUTPUT_DIR}/support/headers/jdk.management.agent
    ${BUILD_OUTPUT_DIR}/support/headers/java.base
)

target_compile_definitions(management_agent PRIVATE -DLINUX -D_GNU_SOURCE -D_REENTRANT -DAMD64 -D_LP64=1)
target_link_libraries(management_agent dl pthread)
set_target_properties(management_agent PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${BUILD_OUTPUT_DIR}/jdk/lib")

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