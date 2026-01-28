# OpenJDK 11 Cut-New CMake Configuration
# 这个文件包含了从 spec.gmk 提取的关键配置信息

# 构建配置
set(OPENJDK_TARGET_OS "linux")
set(OPENJDK_TARGET_CPU "x86_64")
set(OPENJDK_DEBUG_LEVEL "slowdebug")

# 版本信息
set(VERSION_FEATURE "11")
set(VERSION_INTERIM "0")
set(VERSION_UPDATE "17")
set(VERSION_PATCH "0")
set(VERSION_PRE "internal")
set(VERSION_BUILD "0")
set(VERSION_OPT "adhoc.root.openjdk11-core")

# 路径配置
set(OPENJDK_TOPDIR "${CMAKE_SOURCE_DIR}")
set(OPENJDK_OUTPUTDIR "${CMAKE_SOURCE_DIR}/build/linux-x86_64-normal-server-slowdebug")

# 编译器配置
set(CMAKE_C_COMPILER "/usr/bin/gcc")
set(CMAKE_CXX_COMPILER "/usr/bin/g++")

# HotSpot 特定配置
set(JVM_VARIANT "server")
set(HOTSPOT_BUILD_TARGET "linux_amd64_compiler2")

# 添加 HotSpot 特定的包含目录
function(setup_hotspot_includes target)
    target_include_directories(${target} PRIVATE
        ${CMAKE_SOURCE_DIR}/src/hotspot/share
        ${CMAKE_SOURCE_DIR}/src/hotspot/os/linux
        ${CMAKE_SOURCE_DIR}/src/hotspot/os/posix
        ${CMAKE_SOURCE_DIR}/src/hotspot/cpu/x86
        ${CMAKE_SOURCE_DIR}/src/hotspot/os_cpu/linux_x86
        ${CMAKE_SOURCE_DIR}/build/linux-x86_64-normal-server-slowdebug/hotspot/variant-server/gensrc
        ${CMAKE_SOURCE_DIR}/build/linux-x86_64-normal-server-slowdebug/hotspot/variant-server/gensrc/adfiles
    )
endfunction()

# 添加 Java 基础库特定的包含目录
function(setup_java_base_includes target)
    target_include_directories(${target} PRIVATE
        ${CMAKE_SOURCE_DIR}/src/java.base/share/native/libjava
        ${CMAKE_SOURCE_DIR}/src/java.base/unix/native/libjava
        ${CMAKE_SOURCE_DIR}/src/java.base/linux/native/libjava
        ${CMAKE_SOURCE_DIR}/src/java.base/share/native/include
        ${CMAKE_SOURCE_DIR}/src/java.base/unix/native/include
        ${CMAKE_SOURCE_DIR}/src/java.base/linux/native/include
        ${CMAKE_SOURCE_DIR}/build/linux-x86_64-normal-server-slowdebug/support/modules_include/java.base
        ${CMAKE_SOURCE_DIR}/build/linux-x86_64-normal-server-slowdebug/support/modules_include/java.base/linux
    )
endfunction()