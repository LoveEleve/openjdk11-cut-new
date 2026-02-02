#!/bin/bash
# GDB 脚本：详细分析 G1CMTaskQueueSet 构造过程

cd /data/workspace/openjdk-cut-new

timeout 30 gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'EOF'
set pagination off
set print pretty on

# 在构造函数入口处设置断点
break taskqueue.inline.hpp:37

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

printf "\n============================================\n"
printf "  GenericTaskQueueSet 构造函数详细分析\n"
printf "============================================\n"

printf "\n【1. 构造函数入参】\n"
printf "  n = %d (要创建的槽位数量)\n", n

printf "\n【2. this 指针 (新分配的对象地址)】\n"
printf "  this = %p\n", this

# 执行到分配数组那行
next
next

printf "\n【3. NEW_C_HEAP_ARRAY 分配后】\n"
printf "  _queues 数组地址 = %p\n", this->_queues
printf "  _n = %u\n", this->_n

printf "\n【4. 数组大小计算】\n"
printf "  每个指针大小 = %zu bytes\n", sizeof(void*)
printf "  数组总大小 = %d × %zu = %zu bytes\n", n, sizeof(void*), n * sizeof(void*)

# 执行完 for 循环
next
next
next

printf "\n【5. 初始化完成后，检查所有槽位】\n"
printf "  _queues[0] = %p\n", this->_queues[0]
printf "  _queues[1] = %p\n", this->_queues[1]
printf "  _queues[2] = %p\n", this->_queues[2]

printf "\n【6. 对象内存布局】\n"
print *this

quit
EOF
