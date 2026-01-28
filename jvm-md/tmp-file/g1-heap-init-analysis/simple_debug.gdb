# 简化的G1调试脚本
set pagination off
set print pretty on

# 运行程序到main
run -XX:+UseG1GC -Xms8g -Xmx8g -XX:+PrintGC -XX:+PrintGCDetails SimpleTest

# 打印一些基本信息
printf "\n=== G1 GC 调试信息收集 ===\n"
printf "程序已启动，G1GC已激活\n"

# 查看内存映射
printf "\n=== 内存映射信息 ===\n"
info proc mappings

# 查看线程信息
printf "\n=== 线程信息 ===\n"
info threads

quit