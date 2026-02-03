#!/bin/bash
# GDB 调试脚本：G1Policy::init() - 使用 sharedlibrary 事件

cd /data/workspace/openjdk-cut-new

gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'GDBEOF'
set pagination off
set confirm off
set breakpoint pending on

# 设置在 libjvm.so 加载时停止
set stop-on-solib-events 1

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# 现在应该停在某个共享库加载时，继续运行直到 libjvm.so 加载
# 需要多次 continue 直到 libjvm 加载完成

# 尝试查找 libjvm
info sharedlibrary libjvm

# 继续运行直到能找到函数
continue

info sharedlibrary libjvm
info functions G1Policy::init

continue
info sharedlibrary libjvm
continue
info sharedlibrary libjvm
continue
info sharedlibrary libjvm

# 检查是否能找到函数了
info functions G1Policy::init

# 关闭 solib 事件
set stop-on-solib-events 0

# 设置断点
break G1Policy::init

continue

# 在断点处打印信息
printf "\n==================== G1Policy::init() ====================\n"
printf "this (G1Policy*) = %p\n", this
printf "g1h = %p\n", g1h
printf "collection_set = %p\n", collection_set

printf "\n--- _young_gen_sizer 状态 ---\n"
print this->_young_gen_sizer

printf "\n--- g1h (G1CollectedHeap) 参数 ---\n"
printf "max_regions = %u\n", g1h->_hrm._max_length
printf "num_free_regions = %u\n", g1h->_hrm._num_free_regions

# 执行完 init 方法
finish

printf "\n==================== init() 执行完毕 ====================\n"
printf "_g1h = %p\n", this->_g1h
printf "_collection_set = %p\n", this->_collection_set
printf "_free_regions_at_end_of_collection = %u\n", this->_free_regions_at_end_of_collection
printf "_young_list_target_length = %u\n", this->_young_list_target_length
printf "_young_list_max_length = %u\n", this->_young_list_max_length

print this->_young_gen_sizer

continue
quit
GDBEOF
