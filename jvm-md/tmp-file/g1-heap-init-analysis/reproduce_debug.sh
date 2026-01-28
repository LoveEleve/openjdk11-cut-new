#!/bin/bash
# G1堆初始化调试重现脚本
# 用于重现和验证G1CollectedHeap初始化过程

echo "=== G1堆初始化调试重现脚本 ==="
echo "时间: $(date)"
echo "位置: $(pwd)"
echo

# 设置变量
OPENJDK_ROOT="/data/workspace/openjdk-cut-new"
BUILD_DIR="$OPENJDK_ROOT/build/linux-x86_64-normal-server-slowdebug"
JAVA_BIN="$BUILD_DIR/jdk/bin/java"
JAVAC_BIN="$BUILD_DIR/jdk/bin/javac"

echo "1. 检查OpenJDK构建..."
if [ ! -f "$JAVA_BIN" ]; then
    echo "❌ 错误: 找不到Java可执行文件: $JAVA_BIN"
    exit 1
fi
echo "✅ Java可执行文件: $JAVA_BIN"

echo
echo "2. 编译测试程序..."
if [ ! -f "SimpleTest.class" ]; then
    echo "编译SimpleTest.java..."
    $JAVAC_BIN SimpleTest.java
    if [ $? -eq 0 ]; then
        echo "✅ 编译成功"
    else
        echo "❌ 编译失败"
        exit 1
    fi
else
    echo "✅ SimpleTest.class已存在"
fi

echo
echo "3. 执行G1调试运行..."
echo "JVM参数: -XX:+UseG1GC -Xms8g -Xmx8g -XX:+PrintGC -XX:+PrintGCDetails"
echo "开始运行..."

$JAVA_BIN -XX:+UseG1GC -Xms8g -Xmx8g -XX:+PrintGC -XX:+PrintGCDetails SimpleTest 2>&1 | tee g1_runtime_output.txt

echo
echo "4. 分析运行结果..."

# 提取关键信息
echo "=== 关键信息提取 ==="

echo "Region大小:"
grep "Heap region size" g1_runtime_output.txt

echo
echo "G1收集器激活:"
grep "Using G1" g1_runtime_output.txt

echo
echo "堆地址和大小:"
grep "Heap address" g1_runtime_output.txt

echo
echo "最终堆状态:"
grep "garbage-first heap" g1_runtime_output.txt

echo
echo "内存区域分布:"
grep "region size.*young.*survivors" g1_runtime_output.txt

echo
echo "5. 验证结果总结..."

# 验证Region大小
REGION_SIZE=$(grep "Heap region size" g1_runtime_output.txt | grep -o "[0-9]*M")
if [ "$REGION_SIZE" = "4M" ]; then
    echo "✅ Region大小验证通过: $REGION_SIZE"
else
    echo "❌ Region大小异常: $REGION_SIZE (期望4M)"
fi

# 验证G1激活
if grep -q "Using G1" g1_runtime_output.txt; then
    echo "✅ G1收集器激活验证通过"
else
    echo "❌ G1收集器激活失败"
fi

# 验证堆大小
HEAP_SIZE=$(grep "Heap address" g1_runtime_output.txt | grep -o "size: [0-9]* MB" | grep -o "[0-9]*")
if [ "$HEAP_SIZE" = "8192" ]; then
    echo "✅ 堆大小验证通过: ${HEAP_SIZE}MB"
else
    echo "❌ 堆大小异常: ${HEAP_SIZE}MB (期望8192MB)"
fi

echo
echo "6. 生成调试报告..."
cat > debug_summary.txt << EOF
G1堆初始化调试总结报告
========================

执行时间: $(date)
测试程序: SimpleTest.java
JVM版本: $(${JAVA_BIN} -version 2>&1 | head -1)

关键验证结果:
- Region大小: $REGION_SIZE
- 堆大小: ${HEAP_SIZE}MB
- G1激活: $(grep -q "Using G1" g1_runtime_output.txt && echo "成功" || echo "失败")

详细日志: g1_runtime_output.txt
EOF

echo "✅ 调试报告已生成: debug_summary.txt"

echo
echo "=== 调试完成 ==="
echo "所有调试文件已保存在当前目录:"
ls -la *.txt *.class *.java 2>/dev/null | grep -E "\.(txt|class|java)$"

echo
echo "如需重新运行，请执行: ./reproduce_debug.sh"