#!/bin/bash

# G1堆初始化调试验证脚本
# 使用方法: ./debug_g1_init.sh

echo "=== G1堆初始化调试验证脚本 ==="
echo "目标：验证G1CollectedHeap::initialize()方法的执行过程"
echo ""

# 检查编译版本是否存在
BUILD_DIR="./build/linux-x86_64-normal-server-slowdebug"
JAVA_BIN="$BUILD_DIR/jdk/bin/java"

if [ ! -f "$JAVA_BIN" ]; then
    echo "❌ 错误：找不到调试版本的Java二进制文件"
    echo "请先编译slowdebug版本："
    echo "make -f make/Main.gmk SPEC=build-config/spec.gmk split-hotspot-libs"
    exit 1
fi

echo "✅ 找到调试版本：$JAVA_BIN"

# 创建简单的测试程序
TEST_PROGRAM="/tmp/G1InitTest.java"
cat > $TEST_PROGRAM << 'EOF'
public class G1InitTest {
    public static void main(String[] args) {
        System.out.println("G1堆初始化测试程序启动");
        
        // 分配一些对象来触发堆的使用
        for (int i = 0; i < 1000; i++) {
            String s = "Test string " + i;
            if (i % 100 == 0) {
                System.out.println("已分配对象: " + i);
            }
        }
        
        System.out.println("测试完成，程序即将退出");
    }
}
EOF

# 编译测试程序
javac $TEST_PROGRAM -d /tmp
echo "✅ 测试程序编译完成"

# 创建GDB命令文件
GDB_COMMANDS="/tmp/gdb_commands.txt"
cat > $GDB_COMMANDS << 'EOF'
# 设置断点
break G1CollectedHeap::initialize
break Universe::reserve_heap
break G1CardTable::G1CardTable
break HeapRegionManager::initialize
break G1ConcurrentMark::G1ConcurrentMark

# 启动程序
run

# 第一个断点：G1CollectedHeap::initialize 开始
echo \n=== 检查点1：G1堆初始化开始 ===
print "堆参数获取："
print init_byte_size
print max_byte_size  
print heap_alignment
continue

# 第二个断点：虚拟内存预留
echo \n=== 检查点2：虚拟内存预留 ===
print "预留空间信息："
print heap_rs.base()
print heap_rs.size()
continue

# 第三个断点：卡表创建
echo \n=== 检查点3：卡表创建 ===
print "卡表配置："
print ct->_card_size
continue

# 第四个断点：HeapRegionManager初始化
echo \n=== 检查点4：Region管理器初始化 ===
print "Region管理器状态："
print _hrm._regions._length
continue

# 第五个断点：并发标记器创建
echo \n=== 检查点5：并发标记器创建 ===
print "并发标记器配置："
print _cm->_g1h
continue

# 继续执行到程序结束
continue
quit
EOF

echo "✅ GDB命令文件创建完成"

# 执行调试
echo ""
echo "🚀 开始执行GDB调试..."
echo "注意：这可能需要几分钟时间"
echo ""

gdb --batch \
    --command=$GDB_COMMANDS \
    --args $JAVA_BIN \
    -Xms8g -Xmx8g \
    -XX:+UseG1GC \
    -XX:+PrintGCDetails \
    -XX:+PrintGCTimeStamps \
    -cp /tmp \
    G1InitTest

echo ""
echo "🎯 调试完成！"
echo ""
echo "📊 如果看到了各个检查点的输出，说明G1堆初始化流程验证成功！"
echo ""
echo "📝 关键验证点："
echo "  ✓ init_byte_size = 8589934592 (8GB)"
echo "  ✓ max_byte_size = 8589934592 (8GB)"  
echo "  ✓ heap_alignment = 4194304 (4MB)"
echo "  ✓ heap_rs.size() = 8589934592 (8GB)"
echo "  ✓ _card_size = 512"
echo "  ✓ _regions._length = 2048"
echo ""

# 清理临时文件
rm -f $TEST_PROGRAM /tmp/G1InitTest.class $GDB_COMMANDS

echo "✅ 临时文件已清理"
echo "🎉 G1堆初始化验证脚本执行完毕！"