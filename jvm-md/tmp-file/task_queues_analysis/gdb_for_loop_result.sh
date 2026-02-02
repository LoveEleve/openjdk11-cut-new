#!/bin/bash
# GDB 脚本：分析 for 循环完成后的队列状态

cd /data/workspace/openjdk-cut-new

timeout 30 gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'EOF'
set pagination off
set print pretty on

# 在构造函数完成处设置断点
break g1ConcurrentMark.cpp:563

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

printf "\n============================================\n"
printf "  for 循环完成后的队列详细分析\n"
printf "============================================\n"

printf "\n【1. 所有队列地址】\n"
set $i = 0
while $i < 13
  printf "  _queues[%2d] = %p\n", $i, this->_task_queues->_queues[$i]
  set $i = $i + 1
end

printf "\n【2. 第一个队列 _queues[0] 的详细结构】\n"
print *(this->_task_queues->_queues[0])

printf "\n【3. 各队列的 _elems 地址】\n"
set $i = 0
while $i < 5
  printf "  _queues[%d]->_elems = %p\n", $i, this->_task_queues->_queues[$i]->_elems
  set $i = $i + 1
end

printf "\n【4. 队列容量常量】\n"
printf "  TASKQUEUE_SIZE = 131072 (2^17)\n"
printf "  max_elems = 131070 (N-2)\n"
printf "  sizeof(G1TaskQueueEntry) = 8 bytes\n"
printf "  _elems 数组大小 = 131072 × 8 = 1,048,576 bytes = 1 MB\n"

printf "\n【5. 队列初始状态】\n"
printf "  _queues[0]->_bottom = %u\n", this->_task_queues->_queues[0]->_bottom
printf "  _queues[0]->_age._fields._top = %u\n", this->_task_queues->_queues[0]->_age._fields._top
printf "  队列为空: size = _bottom - _top = 0\n"

printf "\n【6. _tasks 数组 (G1CMTask 对象)】\n"
printf "  _tasks 数组地址 = %p\n", this->_tasks
printf "  _tasks[0] = %p\n", this->_tasks[0]
printf "  _tasks[1] = %p\n", this->_tasks[1]

printf "\n【7. 内存统计】\n"
printf "  13 个 G1CMTaskQueue 对象: 13 × ~208 = ~2.7 KB\n"
printf "  13 个 _elems 数组: 13 × 1 MB = 13 MB\n"
printf "  总计: ~13 MB\n"

quit
EOF
