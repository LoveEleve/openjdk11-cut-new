#!/bin/bash
# GDB 脚本：详细分析 for 循环中的队列初始化过程

cd /data/workspace/openjdk-cut-new

timeout 60 gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'EOF'
set pagination off
set print pretty on

# 在 for 循环开始处设置断点
break g1ConcurrentMark.cpp:552

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

printf "\n============================================\n"
printf "  for 循环初始化前的状态\n"
printf "============================================\n"

printf "\n【循环前 _task_queues 状态】\n"
printf "  _task_queues->_n = %u\n", this->_task_queues->_n
printf "  _task_queues->_queues[0] = %p (应为 NULL)\n", this->_task_queues->_queues[0]
printf "  _task_queues->_queues[1] = %p (应为 NULL)\n", this->_task_queues->_queues[1]

# 在创建第一个 G1CMTaskQueue 后设置断点
break g1ConcurrentMark.cpp:554

continue

printf "\n============================================\n"
printf "  第 1 次循环: new G1CMTaskQueue() 之后\n"
printf "============================================\n"

printf "\n【1. 刚创建的 task_queue 对象】\n"
printf "  task_queue 地址 = %p\n", task_queue
printf "  i = %u\n", i

printf "\n【2. task_queue 内部结构 (initialize 之前)】\n"
print *task_queue

# 执行 initialize()
next

printf "\n============================================\n"
printf "  task_queue->initialize() 之后\n"
printf "============================================\n"

printf "\n【3. _elems 数组已分配】\n"
printf "  task_queue->_elems = %p\n", task_queue->_elems
printf "  _elems 数组大小 = 131072 × 8 = 1048576 bytes (1MB)\n"

# 执行 register_queue
next

printf "\n============================================\n"
printf "  register_queue() 之后\n"
printf "============================================\n"

printf "\n【4. 队列已注册到 _task_queues】\n"
printf "  _task_queues->_queues[0] = %p\n", this->_task_queues->_queues[0]
printf "  task_queue = %p (应该相等)\n", task_queue

# 继续到循环结束后
break g1ConcurrentMark.cpp:562
continue

printf "\n============================================\n"
printf "  for 循环完成后的最终状态\n"
printf "============================================\n"

printf "\n【5. 所有队列已创建并注册】\n"
set $i = 0
while $i < 13
  printf "  _queues[%2d] = %p\n", $i, this->_task_queues->_queues[$i]
  set $i = $i + 1
end

printf "\n【6. 第一个队列的详细信息】\n"
print *(this->_task_queues->_queues[0])

quit
EOF
