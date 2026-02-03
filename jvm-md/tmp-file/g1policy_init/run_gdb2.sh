#!/bin/bash
# GDB 调试脚本：G1Policy::init() 方法分析 - 改进版

cd /data/workspace/openjdk-cut-new

gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'GDBEOF'
set pagination off
set confirm off

# 先运行到 main，让 libjvm.so 加载
break main
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# 删除 main 断点
delete 1

# 在 init 方法结束后的位置设断点 (g1CollectedHeap.cpp 调用 init 之后)
break g1CollectedHeap.cpp:2207
commands
    silent
    echo \n\n========== G1Policy::init() 执行完毕后的状态 ==========\n
    
    # 获取 g1_policy 指针
    set $policy = g1_policy()
    
    echo \n--- G1Policy 基本信息 ---\n
    printf "G1Policy 地址 = %p\n", $policy
    printf "_g1h = %p\n", $policy->_g1h
    printf "_collection_set = %p\n", $policy->_collection_set
    
    echo \n\n========== 1. G1YoungGenSizer (年轻代大小计算器) ==========\n
    print $policy->_young_gen_sizer
    printf "\n解读:\n"
    printf "  _sizer_kind = %d (0=Defaults/自适应, 1=NewSizeOnly, 2=MaxNewSizeOnly, 3=MaxAndNewSize/固定, 4=NewRatio)\n", $policy->_young_gen_sizer._sizer_kind
    printf "  _adaptive_size = %d (1=自适应调整年轻代, 0=固定大小)\n", $policy->_young_gen_sizer._adaptive_size
    printf "  _min_desired_young_length = %u 个 Region = %u MB\n", $policy->_young_gen_sizer._min_desired_young_length, $policy->_young_gen_sizer._min_desired_young_length * 4
    printf "  _max_desired_young_length = %u 个 Region = %u MB\n", $policy->_young_gen_sizer._max_desired_young_length, $policy->_young_gen_sizer._max_desired_young_length * 4
    
    echo \n\n========== 2. 年轻代长度目标 ==========\n
    printf "_young_list_target_length = %u 个 Region (当前目标)\n", $policy->_young_list_target_length
    printf "_young_list_fixed_length  = %u 个 Region (固定模式时使用)\n", $policy->_young_list_fixed_length
    printf "_young_list_max_length    = %u 个 Region (最大长度)\n", $policy->_young_list_max_length
    
    echo \n\n========== 3. 空闲 Region 统计 ==========\n
    printf "_free_regions_at_end_of_collection = %u 个 Region\n", $policy->_free_regions_at_end_of_collection
    
    echo \n\n========== 4. 预留空间 (Reserve) ==========\n
    printf "_reserve_factor  = %f\n", $policy->_reserve_factor
    printf "_reserve_regions = %u 个 Region = %u MB\n", $policy->_reserve_regions, $policy->_reserve_regions * 4
    
    echo \n\n========== 5. G1CollectionSet 状态 ==========\n
    set $cset = $policy->_collection_set
    printf "G1CollectionSet 地址 = %p\n", $cset
    printf "_inc_build_state = %d (0=Inactive, 1=Active)\n", $cset->_inc_build_state
    printf "_collection_set_cur_length = %u\n", $cset->_collection_set_cur_length
    printf "_collection_set_max_length = %u\n", $cset->_collection_set_max_length
    printf "_eden_region_length = %u\n", $cset->_eden_region_length
    printf "_survivor_region_length = %u\n", $cset->_survivor_region_length
    printf "_old_region_length = %u\n", $cset->_old_region_length
    printf "\n增量构建统计:\n"
    printf "_inc_bytes_used_before = %lu\n", $cset->_inc_bytes_used_before
    printf "_inc_recorded_rs_lengths = %lu\n", $cset->_inc_recorded_rs_lengths
    printf "_inc_predicted_elapsed_time_ms = %f\n", $cset->_inc_predicted_elapsed_time_ms
    
    echo \n\n========== 6. IHOP 控制 (并发标记触发阈值) ==========\n
    printf "_ihop_control = %p\n", $policy->_ihop_control
    print *($policy->_ihop_control)
    
    echo \n\n========== 7. 分析器 (G1Analytics) ==========\n
    printf "_analytics = %p\n", $policy->_analytics
    
    echo \n\n========== 8. 存活率组 (SurvRateGroup) ==========\n
    printf "_survivor_surv_rate_group = %p\n", $policy->_survivor_surv_rate_group
    printf "_short_lived_surv_rate_group = %p\n", $policy->_short_lived_surv_rate_group
    
    echo \n\n========== 9. GC 阶段状态 ==========\n
    set $state = $policy->_g1h->_collector_state
    printf "collector_state 地址 = %p\n", &($policy->_g1h->_collector_state)
    printf "_in_young_only_phase = %d\n", $state._in_young_only_phase
    printf "_in_initial_mark_gc = %d\n", $state._in_initial_mark_gc
    printf "_in_young_gc_before_mixed = %d\n", $state._in_young_gc_before_mixed
    printf "_initiate_conc_mark_if_possible = %d\n", $state._initiate_conc_mark_if_possible
    printf "_mark_or_rebuild_in_progress = %d\n", $state._mark_or_rebuild_in_progress
    printf "_clearing_next_bitmap = %d\n", $state._clearing_next_bitmap
    
    echo \n\n========== 10. 暂停时间目标 ==========\n
    printf "MaxGCPauseMillis = %u ms\n", MaxGCPauseMillis
    
    echo \n\n========== 计算验证 ==========\n
    printf "堆总 Region 数: 2048\n"
    printf "G1NewSizePercent (默认5%%): 2048 * 5%% = 102 个 Region\n"
    printf "G1MaxNewSizePercent (默认60%%): 2048 * 60%% = 1228 个 Region\n"
    printf "G1ReservePercent (默认10%%): 2048 * 10%% = 204 个 Region\n"
    
    continue
end

continue
GDBEOF
