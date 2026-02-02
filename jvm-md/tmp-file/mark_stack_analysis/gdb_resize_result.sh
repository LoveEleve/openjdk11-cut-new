#!/bin/bash
# GDB 脚本：分析 resize() 完成后的结果

cd /data/workspace/openjdk-cut-new

timeout 30 gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'EOF'
set pagination off
set print pretty on

# 在 resize 函数返回前设置断点 (return true 那行)
break g1ConcurrentMark.cpp:114

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

printf "\n========== resize() 完成后的状态 ==========\n"
printf "\n【内存池状态】\n"
printf "  _base (内存池基地址)      = %p\n", this->_base
printf "  _chunk_capacity (Chunk数) = %zu\n", this->_chunk_capacity
printf "  _max_chunk_capacity       = %zu\n", this->_max_chunk_capacity

printf "\n【链表状态】\n"
printf "  _free_list  = %p\n", this->_free_list
printf "  _chunk_list = %p\n", this->_chunk_list
printf "  _chunks_in_chunk_list = %zu\n", this->_chunks_in_chunk_list
printf "  _hwm (高水位标记) = %zu\n", this->_hwm

printf "\n【内存计算】\n"
printf "  sizeof(TaskQueueEntryChunk) = %zu bytes\n", sizeof(G1CMMarkStack::TaskQueueEntryChunk)
printf "  实际分配内存 = %zu * 8192 = %zu bytes = %zu MB\n", this->_chunk_capacity, this->_chunk_capacity * 8192, this->_chunk_capacity * 8192 / 1024 / 1024

printf "\n【容量计算】\n"
printf "  EntriesPerChunk = %zu\n", G1CMMarkStack::EntriesPerChunk
printf "  总容量(条目数) = %zu * 1023 = %zu\n", this->_chunk_capacity, this->_chunk_capacity * 1023

quit
EOF
