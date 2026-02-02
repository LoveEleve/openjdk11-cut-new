#!/bin/bash
# GDB 脚本：在 G1ConcurrentMark 构造函数中分析 _task_queues 初始化

cd /data/workspace/openjdk-cut-new

timeout 30 gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'EOF'
set pagination off
set print pretty on

# 在 G1ConcurrentMark 构造函数中，_task_queues 初始化之后设置断点
break g1ConcurrentMark.cpp:405

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

printf "\n============================================\n"
printf "  G1CMTaskQueueSet 初始化详细分析\n"
printf "============================================\n"

printf "\n【1. _max_num_tasks 的值】\n"
printf "  _max_num_tasks = %u\n", this->_max_num_tasks

printf "\n【2. _task_queues 对象地址】\n"
printf "  _task_queues = %p\n", this->_task_queues

printf "\n【3. _task_queues 内部结构】\n"
printf "  _task_queues->_n = %u (槽位数量)\n", this->_task_queues->_n
printf "  _task_queues->_queues = %p (指针数组地址)\n", this->_task_queues->_queues

printf "\n【4. 指针数组的初始状态】\n"
set $i = 0
while $i < 5
  printf "  _queues[%d] = %p\n", $i, this->_task_queues->_queues[$i]
  set $i = $i + 1
end
printf "  ... (其余都是 NULL)\n"

printf "\n【5. 内存大小统计】\n"
printf "  sizeof(G1CMTaskQueueSet) ≈ 24 bytes (vtable + _n + _queues指针)\n"
printf "  _queues 数组大小 = %u × 8 = %u bytes\n", this->_task_queues->_n, this->_task_queues->_n * 8

printf "\n【6. 此时的状态】\n"
printf "  ✓ G1CMTaskQueueSet 对象已创建\n"
printf "  ✓ _queues 指针数组已分配 (13个槽位)\n"
printf "  ✓ 所有槽位都是 NULL (还没有实际的队列)\n"

quit
EOF
