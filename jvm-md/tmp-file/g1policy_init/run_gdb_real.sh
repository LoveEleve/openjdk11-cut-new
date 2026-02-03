#!/bin/bash
# GDB 调试：获取 init() 执行后的真实数据

cd /data/workspace/openjdk-cut-new

gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'GDBEOF'
set pagination off
set confirm off
set breakpoint pending on
set stop-on-solib-events 1

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# 等待 libjvm.so 加载
continue
continue
continue
continue
continue

set stop-on-solib-events 0

# 在 init 结束后的下一行设断点 (g1CollectedHeap.cpp 调用 init 后)
# 先找到调用位置
break G1CollectedHeap::initialize
commands 1
    echo \n=== 进入 G1CollectedHeap::initialize ===\n
    continue
end

# 在 G1BarrierSet 初始化处设断点（这是 init() 调用后的下一行代码）
break g1BarrierSet.cpp:166
commands 2
    echo \n\n============================================================\n
    echo    G1Policy::init() 执行完毕后的真实数据\n
    echo ============================================================\n
    
    set $policy = g1_policy()
    
    echo \n【1】年轻代目标长度（最重要）\n
    printf "   _young_list_target_length = %u 个 Region = %u MB\n", $policy->_young_list_target_length, $policy->_young_list_target_length * 4
    printf "   _young_list_max_length    = %u 个 Region = %u MB\n", $policy->_young_list_max_length, $policy->_young_list_max_length * 4
    printf "   _young_list_fixed_length  = %u 个 Region\n", $policy->_young_list_fixed_length
    
    echo \n【2】G1YoungGenSizer 配置\n
    printf "   _sizer_kind     = %d (0=自适应, 3=固定)\n", $policy->_young_gen_sizer._sizer_kind
    printf "   _adaptive_size  = %d (1=自适应开启)\n", $policy->_young_gen_sizer._adaptive_size
    printf "   _min_desired    = %u 个 Region = %u MB\n", $policy->_young_gen_sizer._min_desired_young_length, $policy->_young_gen_sizer._min_desired_young_length * 4
    printf "   _max_desired    = %u 个 Region = %u MB\n", $policy->_young_gen_sizer._max_desired_young_length, $policy->_young_gen_sizer._max_desired_young_length * 4
    
    echo \n【3】空闲Region统计\n
    printf "   _free_regions_at_end_of_collection = %u 个 Region\n", $policy->_free_regions_at_end_of_collection
    
    echo \n【4】预留空间\n
    printf "   _reserve_factor  = %f\n", $policy->_reserve_factor
    printf "   _reserve_regions = %u 个 Region = %u MB\n", $policy->_reserve_regions, $policy->_reserve_regions * 4
    
    echo \n【5】G1CollectionSet 状态\n
    printf "   _inc_build_state = %d (0=Inactive, 1=Active)\n", $policy->_collection_set->_inc_build_state
    printf "   _inc_bytes_used_before = %lu\n", $policy->_collection_set->_inc_bytes_used_before
    printf "   _inc_predicted_elapsed_time_ms = %f\n", $policy->_collection_set->_inc_predicted_elapsed_time_ms
    
    echo \n============================================================\n
    continue
end

continue
quit
GDBEOF
