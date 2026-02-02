# GDB 脚本：调试 AbstractWorkGang::add_workers

set pagination off
set print pretty on

# 在 add_workers 设置断点
break AbstractWorkGang::add_workers

# 运行程序
run -Xms8g -Xmx8g -XX:+UseG1GC -cp /data/workspace/openjdk-cut-new/jvm-md/tmp-file/how-thread LoopDemo

# 断点命中后的命令序列会在下面手动执行
