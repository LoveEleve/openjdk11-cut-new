#!/bin/bash
# GDB 脚本：分析 G1CMMarkStack::initialize() 函数

cd /data/workspace/openjdk-cut-new

gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'EOF'
set pagination off
set print pretty on

# 在 initialize 函数入口设置断点
break g1ConcurrentMark.cpp:126

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# 打印入参
printf "\n====== initialize() 入参 ======\n"
printf "initial_capacity = %zu (0x%lx)\n", initial_capacity, initial_capacity
printf "max_capacity = %zu (0x%lx)\n", max_capacity, max_capacity
printf "initial_capacity (MB) = %zu\n", initial_capacity / 1024 / 1024
printf "max_capacity (MB) = %zu\n", max_capacity / 1024 / 1024

# 单步执行到计算 TaskEntryChunkSizeInVoidStar
next
next

printf "\n====== 关键常量计算 ======\n"
printf "sizeof(TaskQueueEntryChunk) = %zu\n", sizeof(G1CMMarkStack::TaskQueueEntryChunk)
printf "sizeof(G1TaskQueueEntry) = %zu\n", sizeof(G1TaskQueueEntry)
printf "TaskEntryChunkSizeInVoidStar = %zu\n", TaskEntryChunkSizeInVoidStar
printf "EntriesPerChunk = %zu\n", G1CMMarkStack::EntriesPerChunk

# 继续执行到计算 _max_chunk_capacity
next

printf "\n====== capacity_alignment() 返回值 ======\n"
printf "capacity_alignment() = %zu\n", capacity_alignment()

# 单步查看 _max_chunk_capacity 计算
printf "\n====== _max_chunk_capacity 计算过程 ======\n"
printf "align_up(max_capacity, capacity_alignment()) = %zu\n", align_up(max_capacity, capacity_alignment())
printf "this->_max_chunk_capacity = %zu\n", this->_max_chunk_capacity

# 继续执行
next

printf "\n====== initial_chunk_capacity 计算 ======\n"
printf "initial_chunk_capacity = %zu\n", initial_chunk_capacity
printf "align_up(initial_capacity, capacity_alignment()) = %zu\n", align_up(initial_capacity, capacity_alignment())

# 执行到 resize 调用前
next
next
next
next

printf "\n====== 调用 resize() 前的状态 ======\n"
printf "即将调用: resize(%zu)\n", initial_chunk_capacity
print *this

# 进入 resize 函数
step

printf "\n====== 进入 resize() 函数 ======\n"
printf "new_capacity = %zu\n", new_capacity

# 执行完 resize
finish

printf "\n====== initialize() 完成后的结果 ======\n"
print *this

printf "\n====== 内存分配验证 ======\n"
printf "_base 地址 = %p\n", this->_base
printf "_chunk_capacity = %zu\n", this->_chunk_capacity
printf "_max_chunk_capacity = %zu\n", this->_max_chunk_capacity
printf "实际分配内存大小 = %zu 字节 (%zu MB)\n", this->_chunk_capacity * sizeof(G1CMMarkStack::TaskQueueEntryChunk), this->_chunk_capacity * sizeof(G1CMMarkStack::TaskQueueEntryChunk) / 1024 / 1024

quit
EOF
