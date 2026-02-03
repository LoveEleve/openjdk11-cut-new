#!/bin/bash
# GDB 调试脚本：G1Policy::init() - 精简版

cd /data/workspace/openjdk-cut-new

gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'GDBEOF'
set pagination off
set confirm off
set breakpoint pending on
set stop-on-solib-events 1

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# 等待直到 libjvm.so 加载 - 快进5次
continue
continue
continue
continue
continue

# 关闭 solib 事件
set stop-on-solib-events 0

# 设置断点
break G1Policy::init

continue

# 在断点处 - 打印入口信息
echo \n\n==================== [1] G1Policy::init() 入口 ====================\n
printf "this (G1Policy*) = %p\n", this
printf "g1h (G1CollectedHeap*) = %p\n", g1h
printf "collection_set = %p\n", collection_set

echo \n--- _young_gen_sizer 状态 (init 前，构造函数已设置) ---\n
printf "_sizer_kind = %d (0=Defaults, 1=NewSizeOnly, 2=MaxNewSizeOnly, 3=Fixed, 4=NewRatio)\n", this->_young_gen_sizer._sizer_kind
printf "_adaptive_size = %d\n", this->_young_gen_sizer._adaptive_size
printf "_min_desired_young_length = %u Regions\n", this->_young_gen_sizer._min_desired_young_length
printf "_max_desired_young_length = %u Regions\n", this->_young_gen_sizer._max_desired_young_length

echo \n--- G1CollectedHeap 状态 ---\n
printf "max_regions = %u\n", g1h->_hrm._max_length
printf "num_free_regions = %u\n", g1h->_hrm._num_free_regions

# 执行到 init 方法结束
finish

echo \n\n==================== [2] G1Policy::init() 执行完毕 ====================\n
printf "_g1h = %p\n", this->_g1h
printf "_collection_set = %p\n", this->_collection_set

echo \n--- 年轻代配置结果 ---\n
printf "_free_regions_at_end_of_collection = %u Regions\n", this->_free_regions_at_end_of_collection
printf "_young_list_target_length = %u Regions\n", this->_young_list_target_length  
printf "_young_list_fixed_length = %u Regions\n", this->_young_list_fixed_length
printf "_young_list_max_length = %u Regions\n", this->_young_list_max_length

echo \n--- _young_gen_sizer 更新后的状态 ---\n
printf "_sizer_kind = %d\n", this->_young_gen_sizer._sizer_kind
printf "_adaptive_size = %d\n", this->_young_gen_sizer._adaptive_size
printf "_min_desired_young_length = %u Regions = %u MB\n", this->_young_gen_sizer._min_desired_young_length, this->_young_gen_sizer._min_desired_young_length * 4
printf "_max_desired_young_length = %u Regions = %u MB\n", this->_young_gen_sizer._max_desired_young_length, this->_young_gen_sizer._max_desired_young_length * 4

echo \n--- 预留空间 ---\n
printf "_reserve_factor = %f\n", this->_reserve_factor
printf "_reserve_regions = %u Regions = %u MB\n", this->_reserve_regions, this->_reserve_regions * 4

echo \n--- G1CollectionSet 状态 ---\n
printf "_inc_build_state = %d (0=Inactive, 1=Active)\n", this->_collection_set->_inc_build_state
printf "_collection_set_cur_length = %u\n", this->_collection_set->_collection_set_cur_length
printf "_inc_bytes_used_before = %lu\n", this->_collection_set->_inc_bytes_used_before

echo \n--- IHOP 控制 ---\n
printf "_ihop_control = %p\n", this->_ihop_control

echo \n==================== 计算验证 ====================\n
echo 堆大小: 8GB = 2048 个 4MB Region\n
echo G1NewSizePercent=5%: 2048 * 5% = 102 Regions\n
echo G1MaxNewSizePercent=60%: 2048 * 60% = 1228 Regions\n
echo G1ReservePercent=10%: 2048 * 10% = 204 Regions\n

continue
quit
GDBEOF
