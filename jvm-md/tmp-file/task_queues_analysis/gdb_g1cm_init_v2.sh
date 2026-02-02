#!/bin/bash
# GDB 脚本：在 G1ConcurrentMark 构造函数体内分析 _task_queues

cd /data/workspace/openjdk-cut-new

timeout 30 gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'EOF'
set pagination off
set print pretty on

# 在构造函数体开始处 (位图初始化那行)
break g1ConcurrentMark.cpp:444

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

printf "\n============================================\n"
printf "  G1CMTaskQueueSet 初始化详细分析\n"
printf "============================================\n"

printf "\n【1. _max_num_tasks 的值及来源】\n"
printf "  _max_num_tasks = %u\n", this->_max_num_tasks
printf "  ParallelGCThreads = %u\n", ParallelGCThreads
printf "  说明: _max_num_tasks = ParallelGCThreads\n"

printf "\n【2. _task_queues 对象】\n"
printf "  _task_queues 地址 = %p\n", this->_task_queues

printf "\n【3. _task_queues 内部成员】\n"
printf "  _task_queues->_n = %u (槽位数量)\n", this->_task_queues->_n
printf "  _task_queues->_queues = %p (指针数组首地址)\n", this->_task_queues->_queues

printf "\n【4. 指针数组当前状态 (应全为NULL)】\n"
set $i = 0
while $i < 13
  printf "  _queues[%2d] = %p\n", $i, this->_task_queues->_queues[$i]
  set $i = $i + 1
end

printf "\n【5. 内存分配统计】\n"
printf "  G1CMTaskQueueSet 对象大小 ≈ 24 bytes\n"
printf "  _queues 指针数组大小 = 13 × 8 = 104 bytes\n"
printf "  此阶段总内存 ≈ 128 bytes\n"

quit
EOF
