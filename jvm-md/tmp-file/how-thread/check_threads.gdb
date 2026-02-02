# GDB 脚本：检查 G1 GC 下 JVM 的所有线程

# 设置断点在 main 线程睡眠时
set pagination off
set print thread-events off

# 运行程序
run

# 等待程序启动完成后，查看所有线程
info threads

# 退出
quit
