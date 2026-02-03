#!/bin/bash
# GDB 调试脚本：G1Policy::init() 方法分析 - 交互式版本

cd /data/workspace/openjdk-cut-new

gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'GDBEOF'
set pagination off
set confirm off

# 添加源码路径
directory /data/workspace/openjdk-cut-new/src/hotspot/share/gc/g1

# 运行程序，等待 libjvm.so 加载
start -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# 现在 libjvm 应该已加载，设置断点
echo \n========== 设置断点 ==========\n

# 方式1: 在 g1Policy.cpp 的 init 方法设断点
break g1Policy.cpp:79
break g1Policy.cpp:120

continue

GDBEOF
