#!/bin/bash
# GDB 脚本：详细分析 G1CMMarkStack::initialize() 函数

cd /data/workspace/openjdk-cut-new

gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'EOF'
set pagination off
set print pretty on

# 在 initialize 函数和 resize 函数设置断点
break g1ConcurrentMark.cpp:126
break g1ConcurrentMark.cpp:94

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# ============ 第一部分：initialize() 入参分析 ============
printf "\n"
printf "========================================================\n"
printf "          G1CMMarkStack::initialize() 分析\n"
printf "========================================================\n"

printf "\n【1. 函数入参】\n"
printf "  initial_capacity = %zu (0x%lx)\n", initial_capacity, initial_capacity
printf "  max_capacity     = %zu (0x%lx)\n", max_capacity, max_capacity
printf "  换算成 MB:\n"
printf "    initial_capacity = %zu MB\n", initial_capacity / 1024 / 1024
printf "    max_capacity     = %zu MB\n", max_capacity / 1024 / 1024

printf "\n【2. 结构体大小】\n"
printf "  sizeof(TaskQueueEntryChunk) = %zu bytes\n", sizeof(G1CMMarkStack::TaskQueueEntryChunk)
printf "  sizeof(G1TaskQueueEntry)    = %zu bytes\n", sizeof(G1TaskQueueEntry)
printf "  EntriesPerChunk (静态常量)  = %zu\n", G1CMMarkStack::EntriesPerChunk

# 继续执行到 resize 断点
continue

# ============ 第二部分：resize() 分析 ============
printf "\n"
printf "========================================================\n"
printf "          G1CMMarkStack::resize() 分析\n"
printf "========================================================\n"

printf "\n【3. resize() 入参】\n"
printf "  new_capacity = %zu (要分配的 chunk 数量)\n", new_capacity

printf "\n【4. 内存分配前的状态】\n"
printf "  this->_max_chunk_capacity = %zu\n", this->_max_chunk_capacity
printf "  this->_base               = %p\n", this->_base
printf "  this->_chunk_capacity     = %zu\n", this->_chunk_capacity

# 执行到 resize 完成
finish

printf "\n【5. resize() 完成后的结果】\n"
printf "  this->_base           = %p\n", this->_base
printf "  this->_chunk_capacity = %zu\n", this->_chunk_capacity
printf "  this->_hwm            = %zu\n", this->_hwm
printf "  this->_free_list      = %p\n", this->_free_list
printf "  this->_chunk_list     = %p\n", this->_chunk_list

printf "\n【6. 内存使用统计】\n"
printf "  每个 Chunk 大小      = %zu bytes (8KB)\n", sizeof(G1CMMarkStack::TaskQueueEntryChunk)
printf "  已分配 Chunk 数量    = %zu\n", this->_chunk_capacity
printf "  最大可扩展 Chunk 数  = %zu\n", this->_max_chunk_capacity
printf "  实际分配内存总大小   = %zu bytes\n", this->_chunk_capacity * sizeof(G1CMMarkStack::TaskQueueEntryChunk)
printf "  实际分配内存 (MB)    = %zu MB\n", this->_chunk_capacity * sizeof(G1CMMarkStack::TaskQueueEntryChunk) / 1024 / 1024
printf "  最大可扩展内存 (MB)  = %zu MB\n", this->_max_chunk_capacity * sizeof(G1CMMarkStack::TaskQueueEntryChunk) / 1024 / 1024

printf "\n【7. 容量计算验证】\n"
printf "  每个 Chunk 可存储条目数  = %zu\n", G1CMMarkStack::EntriesPerChunk
printf "  当前总容量 (条目数)      = %zu\n", this->_chunk_capacity * G1CMMarkStack::EntriesPerChunk
printf "  最大总容量 (条目数)      = %zu\n", this->_max_chunk_capacity * G1CMMarkStack::EntriesPerChunk

printf "\n========================================================\n"
printf "                    分析完成\n"
printf "========================================================\n"

quit
EOF
