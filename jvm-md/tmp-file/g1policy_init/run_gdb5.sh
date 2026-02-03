#!/bin/bash
# GDB 调试脚本：G1Policy::init() 方法分析 - 简化版

cd /data/workspace/openjdk-cut-new

gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'GDBEOF'
set pagination off
set confirm off

# 先运行到 main
break main
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

delete 1

# 查看已加载的共享库
echo \n查找 libjvm.so 中的 G1Policy::init 符号...\n
info functions G1Policy::init

# 设置断点在 init 方法的入口和出口附近
break 'G1Policy::init(G1CollectedHeap*, G1CollectionSet*)'
commands
    silent
    echo \n\n==================== G1Policy::init() 入口 ====================\n
    
    printf "this (G1Policy*) = %p\n", this
    printf "g1h (G1CollectedHeap*) = %p\n", g1h  
    printf "collection_set = %p\n", collection_set
    
    echo \n--- init() 执行前: _young_gen_sizer 状态 ---\n
    printf "_young_gen_sizer._sizer_kind = %d\n", this->_young_gen_sizer._sizer_kind
    printf "_young_gen_sizer._adaptive_size = %d\n", this->_young_gen_sizer._adaptive_size
    printf "_young_gen_sizer._min_desired_young_length = %u\n", this->_young_gen_sizer._min_desired_young_length
    printf "_young_gen_sizer._max_desired_young_length = %u\n", this->_young_gen_sizer._max_desired_young_length
    
    echo \n--- g1h (G1CollectedHeap) 状态 ---\n
    printf "g1h->_num_regions = %u\n", g1h->_hrm._num_committed
    printf "g1h->max_regions() = %u\n", g1h->_hrm._max_length
    printf "g1h->num_free_regions() = %u\n", g1h->_hrm._num_free_regions
    
    continue
end

# 在 update_young_list_max_and_target_length 返回后设断点
break 'G1Policy::update_young_list_max_and_target_length()'
commands
    silent
    echo \n\n==================== update_young_list_max_and_target_length() 入口 ====================\n
    printf "_young_list_target_length (before) = %u\n", this->_young_list_target_length
    printf "_young_list_max_length (before) = %u\n", this->_young_list_max_length
    printf "_free_regions_at_end_of_collection = %u\n", this->_free_regions_at_end_of_collection
    continue
end

# 在 start_incremental_building 设断点
break 'G1CollectionSet::start_incremental_building()'
commands
    silent
    echo \n\n==================== start_incremental_building() 入口 ====================\n
    printf "_inc_build_state (before) = %d (0=Inactive, 1=Active)\n", this->_inc_build_state
    continue
end

continue

# 让程序继续运行，等待断点触发后，执行查询
GDBEOF
