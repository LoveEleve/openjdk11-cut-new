#!/bin/bash
# GDB 调试：在 start_incremental_building 返回后获取数据

cd /data/workspace/openjdk-cut-new

gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'GDBEOF'
set pagination off
set confirm off
set breakpoint pending on
set stop-on-solib-events 1

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

continue
continue
continue
continue
continue

set stop-on-solib-events 0

# 在 start_incremental_building 设断点 - 这是 init() 的最后一步
break G1CollectionSet::start_incremental_building
commands 1
    silent
    echo \n=== start_incremental_building() 被调用 ===\n
    echo 此时 init() 中的 update_young_list... 已经执行完毕\n
    
    # 获取 G1Policy 指针 - 通过 _policy 成员
    set $policy = this->_policy
    
    echo \n============================================================\n
    echo    G1Policy::init() 中间状态【真实数据】\n
    echo ============================================================\n
    
    printf "\n【1】年轻代目标长度 (update_young_list 执行后)\n"
    printf "   _young_list_target_length = %u 个 Region\n", $policy->_young_list_target_length
    printf "   _young_list_max_length    = %u 个 Region\n", $policy->_young_list_max_length
    printf "   _young_list_fixed_length  = %u 个 Region\n", $policy->_young_list_fixed_length
    
    printf "\n【2】G1YoungGenSizer\n"
    printf "   _sizer_kind     = %d\n", $policy->_young_gen_sizer._sizer_kind
    printf "   _adaptive_size  = %d\n", $policy->_young_gen_sizer._adaptive_size
    printf "   _min_desired    = %u 个 Region\n", $policy->_young_gen_sizer._min_desired_young_length
    printf "   _max_desired    = %u 个 Region\n", $policy->_young_gen_sizer._max_desired_young_length
    
    printf "\n【3】空闲Region\n"
    printf "   _free_regions_at_end_of_collection = %u\n", $policy->_free_regions_at_end_of_collection
    
    printf "\n【4】预留空间\n"
    printf "   _reserve_factor  = %f\n", $policy->_reserve_factor
    printf "   _reserve_regions = %u 个 Region\n", $policy->_reserve_regions

    printf "\n【5】收集集合状态 (即将被设置为 Active)\n"
    printf "   _inc_build_state (before) = %d\n", this->_inc_build_state
    
    echo \n============================================================\n
    continue
end

continue
quit
GDBEOF
