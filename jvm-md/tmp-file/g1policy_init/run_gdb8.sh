#!/bin/bash
# GDB 调试脚本：G1Policy::init() - 使用 commands 捕获

cd /data/workspace/openjdk-cut-new

gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'GDBEOF'
set pagination off
set confirm off
set breakpoint pending on
set stop-on-solib-events 1

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# 快进 - 等待 libjvm.so 加载
continue
continue
continue
continue
continue

set stop-on-solib-events 0

# 断点1: init 入口
break G1Policy::init
commands 1
    echo \n\n==================== [1] G1Policy::init() 入口 ====================\n
    printf "this (G1Policy*) = %p\n", this
    printf "g1h (G1CollectedHeap*) = %p\n", g1h
    printf "collection_set = %p\n", collection_set
    
    echo \n--- _young_gen_sizer 初始状态 ---\n
    printf "_sizer_kind = %d (0=Defaults/自适应)\n", this->_young_gen_sizer._sizer_kind
    printf "_adaptive_size = %d\n", this->_young_gen_sizer._adaptive_size
    printf "_min_desired_young_length = %u Regions\n", this->_young_gen_sizer._min_desired_young_length
    printf "_max_desired_young_length = %u Regions\n", this->_young_gen_sizer._max_desired_young_length
    
    echo \n--- G1CollectedHeap 状态 ---\n
    printf "max_regions = %u\n", g1h->_hrm._max_length
    printf "num_free_regions = %u\n", g1h->_hrm._num_free_regions
    continue
end

# 断点2: adjust_max_new_size 调用前 (line 103)
break g1Policy.cpp:103
commands 2
    echo \n\n==================== [2] 调用 adjust_max_new_size 前 ====================\n
    printf "_young_list_fixed_length = %u\n", this->_young_list_fixed_length
    continue
end

# 断点3: update_young_list_max_and_target_length 调用前 (line 120)
break g1Policy.cpp:120
commands 3
    echo \n\n==================== [3] 调用 update_young_list_max_and_target_length 前 ====================\n
    printf "_free_regions_at_end_of_collection = %u\n", this->_free_regions_at_end_of_collection
    printf "_young_gen_sizer._max_desired_young_length = %u (调整后)\n", this->_young_gen_sizer._max_desired_young_length
    continue
end

# 断点4: start_incremental_building 调用前 (line 124)
break g1Policy.cpp:124
commands 4
    echo \n\n==================== [4] 调用 start_incremental_building 前 ====================\n
    printf "_young_list_target_length = %u\n", this->_young_list_target_length
    printf "_young_list_max_length = %u\n", this->_young_list_max_length
    continue
end

# 断点5: init 返回后 (line 125)
break g1Policy.cpp:125
commands 5
    echo \n\n==================== [5] G1Policy::init() 执行完毕 ====================\n
    
    echo \n--- 年轻代大小配置结果 ---\n
    printf "_young_list_target_length = %u Regions = %u MB\n", this->_young_list_target_length, this->_young_list_target_length * 4
    printf "_young_list_fixed_length = %u Regions\n", this->_young_list_fixed_length
    printf "_young_list_max_length = %u Regions = %u MB\n", this->_young_list_max_length, this->_young_list_max_length * 4
    printf "_free_regions_at_end_of_collection = %u Regions\n", this->_free_regions_at_end_of_collection
    
    echo \n--- _young_gen_sizer 最终状态 ---\n
    printf "_sizer_kind = %d\n", this->_young_gen_sizer._sizer_kind
    printf "_adaptive_size = %d\n", this->_young_gen_sizer._adaptive_size
    printf "_min_desired_young_length = %u Regions = %u MB\n", this->_young_gen_sizer._min_desired_young_length, this->_young_gen_sizer._min_desired_young_length * 4
    printf "_max_desired_young_length = %u Regions = %u MB\n", this->_young_gen_sizer._max_desired_young_length, this->_young_gen_sizer._max_desired_young_length * 4
    
    echo \n--- 预留空间 ---\n
    printf "_reserve_factor = %f\n", this->_reserve_factor
    printf "_reserve_regions = %u Regions = %u MB\n", this->_reserve_regions, this->_reserve_regions * 4
    
    echo \n--- G1CollectionSet 状态 ---\n
    printf "_inc_build_state = %d (期望=1/Active)\n", this->_collection_set->_inc_build_state
    
    echo \n==================== 计算验证 ====================\n
    echo 堆大小: 8GB = 2048 个 4MB Region\n
    echo G1NewSizePercent=5%: 2048 * 5% = 102 Regions (408MB)\n
    echo G1MaxNewSizePercent=60%: 2048 * 60% = 1228 Regions (4912MB)\n
    echo G1ReservePercent=10%: 2048 * 10% = 204 Regions\n
    continue
end

continue
quit
GDBEOF
