#!/bin/bash
# GDB 脚本：分析 MmapArrayAllocator 内存分配过程

cd /data/workspace/openjdk-cut-new

timeout 30 gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'EOF'
set pagination off
set print pretty on

# 在 resize 函数的 MmapArrayAllocator 调用行设置断点
break g1ConcurrentMark.cpp:99

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

printf "\n============================================\n"
printf "  MmapArrayAllocator 内存分配参数分析\n"
printf "============================================\n"

printf "\n【1. resize() 入参】\n"
printf "  new_capacity = %zu (要分配的 Chunk 数量)\n", new_capacity

printf "\n【2. 内存大小计算】\n"
printf "  sizeof(TaskQueueEntryChunk) = %zu bytes\n", sizeof(G1CMMarkStack::TaskQueueEntryChunk)
printf "  需要分配的总字节数 = %zu * %zu = %zu bytes\n", new_capacity, sizeof(G1CMMarkStack::TaskQueueEntryChunk), new_capacity * sizeof(G1CMMarkStack::TaskQueueEntryChunk)
printf "  换算成 MB = %zu MB\n", new_capacity * sizeof(G1CMMarkStack::TaskQueueEntryChunk) / 1024 / 1024

printf "\n【3. 内存对齐参数】\n"
printf "  os::vm_allocation_granularity() = %d bytes\n", os::vm_allocation_granularity()

# 执行完这行，查看分配结果
next

printf "\n【4. mmap 分配结果】\n"
printf "  new_base 地址 = %p\n", new_base

# 打印 /proc/self/maps 中的相关信息
printf "\n【5. 验证内存映射】\n"
shell cat /proc/$(pgrep -n java)/maps | grep -A1 "7fffd4"

quit
EOF
