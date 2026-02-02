#!/bin/bash
# GDB 脚本：分析 G1CMTaskQueueSet 初始化过程

cd /data/workspace/openjdk-cut-new

timeout 30 gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'EOF'
set pagination off
set print pretty on

# 在 G1ConcurrentMark 构造函数完成后设置断点
break g1ConcurrentMark.cpp:544

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

printf "\n============================================\n"
printf "     G1CMTaskQueueSet 初始化分析\n"
printf "============================================\n"

printf "\n【1. 基本参数】\n"
printf "  _max_num_tasks = %u\n", this->_max_num_tasks
printf "  ParallelGCThreads = %u\n", ParallelGCThreads
printf "  ConcGCThreads = %u\n", ConcGCThreads

printf "\n【2. _task_queues 结构】\n"
printf "  _task_queues 地址 = %p\n", this->_task_queues
printf "  _task_queues->_n (队列数量) = %u\n", this->_task_queues->_n
printf "  _task_queues->_queues (指针数组) = %p\n", this->_task_queues->_queues

printf "\n【3. TASKQUEUE_SIZE 常量】\n"
printf "  TASKQUEUE_SIZE = %d (每个队列的容量)\n", 1 << 17

printf "\n【4. 单个 TaskQueue 结构】\n"
printf "  _task_queues->_queues[0] = %p\n", this->_task_queues->_queues[0]
print *(this->_task_queues->_queues[0])

printf "\n【5. 查看 _elems 数组地址】\n"
printf "  _queues[0]->_elems = %p\n", this->_task_queues->_queues[0]->_elems

printf "\n【6. 查看其他队列】\n"
printf "  _queues[1] = %p\n", this->_task_queues->_queues[1]
printf "  _queues[2] = %p\n", this->_task_queues->_queues[2]

printf "\n【7. sizeof 验证】\n"
printf "  sizeof(G1CMTaskQueue) = %zu\n", sizeof(G1CMTaskQueue)
printf "  sizeof(G1TaskQueueEntry) = %zu\n", sizeof(G1TaskQueueEntry)

quit
EOF
