#!/bin/bash

# 工作目录
WORK_DIR="/data/workspace/openjdk-cut-new/jvm-md/tmp-file/how-thread"
JAVA_CMD="/data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java"

cd $WORK_DIR

# 后台启动 Java 程序
$JAVA_CMD \
    -Xms8g \
    -Xmx8g \
    -XX:+UseG1GC \
    -Xint \
    -cp . \
    LoopDemo &

JAVA_PID=$!
echo "Java PID: $JAVA_PID"

# 等待程序完全启动
sleep 3

# 使用 GDB 查看线程
echo "========================================"
echo "All threads in JVM (via GDB):"
echo "========================================"
gdb -p $JAVA_PID -batch -ex "info threads" 2>/dev/null | tee threads_gdb.txt

echo ""
echo "========================================"
echo "Thread names (filtered):"
echo "========================================"
cat threads_gdb.txt | grep -E "Thread|GC|G1|Marker|Refine|VM" | head -50

# 清理
kill $JAVA_PID 2>/dev/null
