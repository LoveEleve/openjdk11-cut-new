#!/bin/bash

echo "=== Simple Java Agent Demo ==="
echo

# 创建简单的主类
cat > /data/workspace/openjdk-cut-new/demo/SimpleMain.java << 'EOF'
public class SimpleMain {
    public static void main(String[] args) {
        System.out.println("SimpleMain started");
        System.out.println("Calling some methods...");
        
        // 做一些简单的事情
        for (int i = 1; i <= 3; i++) {
            System.out.println("Step " + i + " completed");
            try {
                Thread.sleep(500);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
        
        System.out.println("SimpleMain finished");
    }
}
EOF

# 编译
javac -d classes SimpleMain.java

echo "=== 演示1: 启动时加载Agent ==="
echo "命令: java -javaagent:agent_fixed.jar=demo_mode -cp classes SimpleMain"
echo
java -Xms8g -Xmx8g -XX:+UseG1GC -javaagent:agent_fixed.jar=demo_mode -cp classes SimpleMain

echo
echo "=== 演示完成 ==="
echo "Agent输出显示了类加载的监控信息"