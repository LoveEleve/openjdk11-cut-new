#!/bin/bash

echo "=== Java Agent Demo Script ==="
echo "1. 演示启动时加载Agent (-javaagent)"
echo "2. 演示运行时Attach加载Agent"
echo

# 创建测试主类
cat > /data/workspace/openjdk-cut-new/demo/MainDemo.java << 'EOF'
import com.wjcoder.TargetClass;

public class MainDemo {
    public static void main(String[] args) throws InterruptedException {
        System.out.println("MainDemo started");
        
        // 调用被监控的类
        TargetClass.sayHello();
        int result = TargetClass.calculate(10, 20);
        System.out.println("Calculation result: " + result);
        
        // 保持运行一段时间，以便演示attach
        if (args.length > 0 && "wait".equals(args[0])) {
            System.out.println("Waiting for attach...");
            Thread.sleep(30000);
        }
        
        System.out.println("MainDemo finished");
    }
}
EOF

# 编译主类
javac -cp classes -d classes MainDemo.java

echo "=== 演示1: 启动时加载Agent ==="
echo "命令: java -javaagent:agent.jar=startup_mode -cp classes MainDemo"
echo
java -Xms8g -Xmx8g -XX:+UseG1GC -javaagent:agent.jar=startup_mode -cp classes MainDemo

echo
echo "=== 演示2: 运行时Attach加载Agent ==="
echo "先启动目标程序..."
# 启动目标程序（后台运行）
java -Xms8g -Xmx8g -XX:+UseG1GC -cp classes MainDemo wait > demo_output.log 2>&1 &
PID=$!
echo "目标程序PID: $PID"
sleep 3

echo "执行Attach..."
# 使用jattach工具进行attach（模拟arthas的行为）
TOOLS_JAR="/data/workspace/openjdk11-core/build/linux-x86_64-normal-server-slowdebug/jdk/lib/tools.jar"
if [ -f "$TOOLS_JAR" ]; then
    java -cp $TOOLS_JAR sun.tools.attach.HotSpotVirtualMachine $PID load instrument false agent.jar=attach_mode
else
    echo "tools.jar not found, simulating attach..."
    # 模拟attach效果
    echo "Simulating: load agent.jar=attach_mode to PID $PID"
fi

echo "等待程序结束..."
wait $PID

echo "演示输出:"
cat demo_output.log

echo
echo "=== 演示完成 ==="