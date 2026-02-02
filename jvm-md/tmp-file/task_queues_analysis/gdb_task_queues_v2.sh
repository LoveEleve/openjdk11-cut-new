#!/bin/bash
# GDB 脚本：分析 _elems 数组的内存分配

cd /data/workspace/openjdk-cut-new

timeout 30 gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'EOF'
set pagination off
set print pretty on

break g1ConcurrentMark.cpp:544

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

printf "\n============================================\n"
printf "     _elems 数组内存分析\n"
printf "============================================\n"

printf "\n【1. _elems 数组大小计算】\n"
printf "  TASKQUEUE_SIZE = 131072 (2^17)\n"
printf "  sizeof(G1TaskQueueEntry) = 8 bytes\n"
printf "  _elems 数组总大小 = 131072 * 8 = %zu bytes = %zu KB = 1 MB\n", 131072 * 8, 131072 * 8 / 1024

printf "\n【2. 每个队列的 _elems 地址】\n"
set $i = 0
while $i < 5
  printf "  _queues[%d]->_elems = %p\n", $i, this->_task_queues->_queues[$i]->_elems
  set $i = $i + 1
end

printf "\n【3. 内存布局验证】\n"
printf "  _queues[0]->_elems = %p\n", this->_task_queues->_queues[0]->_elems
printf "  _queues[1]->_elems = %p\n", this->_task_queues->_queues[1]->_elems
printf "  差值 = %ld bytes\n", (char*)this->_task_queues->_queues[1]->_elems - (char*)this->_task_queues->_queues[0]->_elems

printf "\n【4. max_elems() 计算】\n"
printf "  max_elems = TASKQUEUE_SIZE - 2 = %d\n", 131072 - 2

printf "\n【5. 队列初始状态】\n"
printf "  _bottom = %u\n", this->_task_queues->_queues[0]->_bottom
printf "  _age._fields._top = %u\n", this->_task_queues->_queues[0]->_age._fields._top
printf "  size() = bottom - top = %u\n", this->_task_queues->_queues[0]->_bottom - this->_task_queues->_queues[0]->_age._fields._top

quit
EOF
