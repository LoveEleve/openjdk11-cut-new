# GDB 脚本：深入调试 add_workers 完整流程

set pagination off
set print pretty on
set logging file /data/workspace/openjdk-cut-new/jvm-md/tmp-file/add_workers_detail.log
set logging overwrite on
set logging enabled on

# 设置断点
break AbstractWorkGang::add_workers(unsigned int, bool)
break AbstractWorkGang::install_worker
break AbstractGangWorker::AbstractGangWorker
break os::create_thread
break os::start_thread

# 运行
run -Xms8g -Xmx8g -XX:+UseG1GC -cp /data/workspace/openjdk-cut-new/jvm-md/tmp-file/how-thread LoopDemo

# 命令脚本会在断点处自动执行
