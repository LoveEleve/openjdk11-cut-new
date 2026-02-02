# 简化版: 分析 G1CMMarkStack initialize 方法
set pagination off
set print pretty on
set confirm off

# 在 initialize 调用后设置断点 (g1ConcurrentMark.cpp:500)
break g1ConcurrentMark.cpp:500

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

printf "\n=========================================\n"
printf "断点: _global_mark_stack.initialize() 调用后\n"
printf "=========================================\n"

printf "\n=== JVM参数 MarkStackSize / MarkStackSizeMax ===\n"
printf "MarkStackSize: %lu\n", MarkStackSize
printf "MarkStackSizeMax: %lu\n", MarkStackSizeMax

printf "\n=== _global_mark_stack 结构 ===\n"
print _global_mark_stack

printf "\n=== 成员变量详解 ===\n"
printf "_max_chunk_capacity: %lu\n", _global_mark_stack._max_chunk_capacity
printf "_base: %p\n", _global_mark_stack._base
printf "_chunk_capacity: %lu\n", _global_mark_stack._chunk_capacity
printf "_free_list: %p\n", _global_mark_stack._free_list
printf "_chunk_list: %p\n", _global_mark_stack._chunk_list
printf "_chunks_in_chunk_list: %lu\n", _global_mark_stack._chunks_in_chunk_list
printf "_hwm: %lu\n", _global_mark_stack._hwm

printf "\n=== 常量 EntriesPerChunk ===\n"
printf "EntriesPerChunk: %lu\n", 1023

printf "\n=== 计算分析 ===\n"
printf "sizeof(G1TaskQueueEntry): %lu bytes\n", sizeof(G1TaskQueueEntry)
# TaskQueueEntryChunk 包含 next指针 + data[1023]
# sizeof = 8 + 1023 * 8 = 8 + 8184 = 8192 bytes
printf "sizeof(TaskQueueEntryChunk) 预估: 8 + 1023 * 8 = 8192 bytes\n"

printf "\n=== 内存容量计算 ===\n"
printf "当前chunk容量: %lu chunks\n", _global_mark_stack._chunk_capacity
printf "每个chunk可存条目数: 1023\n"
printf "总条目容量: %lu entries\n", _global_mark_stack._chunk_capacity * 1023
printf "最大chunk容量: %lu chunks\n", _global_mark_stack._max_chunk_capacity
printf "最大总条目容量: %lu entries\n", _global_mark_stack._max_chunk_capacity * 1023

quit
