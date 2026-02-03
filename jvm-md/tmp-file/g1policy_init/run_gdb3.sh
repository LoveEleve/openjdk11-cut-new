#!/bin/bash
# GDB 调试脚本：G1Policy::init() 方法分析 - 使用函数断点

cd /data/workspace/openjdk-cut-new

gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'GDBEOF'
set pagination off
set confirm off

# 先运行到 main，让 libjvm.so 加载
break main
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# 删除 main 断点
delete 1

# 在 G1Policy::init 方法入口设断点
break G1Policy::init
commands
    silent
    echo \n\n========== G1Policy::init() 入口参数 ==========\n
    printf "this (G1Policy*) = %p\n", this
    printf "g1h (G1CollectedHeap*) = %p\n", g1h
    printf "collection_set (G1CollectionSet*) = %p\n", collection_set
    
    echo \n--- init() 执行前的状态 ---\n
    printf "_g1h = %p (应该为空或未初始化)\n", _g1h
    printf "_collection_set = %p (应该为空或未初始化)\n", _collection_set
    
    echo \n========== _young_gen_sizer 初始值 (init前) ==========\n
    print _young_gen_sizer
    
    continue
end

# 在 G1Policy::update_young_list_max_and_target_length 设断点，这是 init() 调用的核心方法
break G1Policy::update_young_list_max_and_target_length
commands
    silent
    echo \n\n========== update_young_list_max_and_target_length() 被调用 ==========\n
    printf "当前 _young_list_target_length = %u\n", _young_list_target_length
    printf "当前 _young_list_max_length = %u\n", _young_list_max_length
    continue
end

# 在 G1CollectionSet::start_incremental_building 设断点
break G1CollectionSet::start_incremental_building
commands
    silent
    echo \n\n========== start_incremental_building() 被调用 ==========\n
    printf "_inc_build_state (before) = %d\n", _inc_build_state
    continue
end

# 在 G1Policy::init 函数返回处设断点
break G1Policy::init
commands
end
# 继续执行到 init 函数末尾，用 finish
tbreak G1Policy::init
commands
    silent
    echo \n将执行 finish 命令...\n
end

continue

# 程序会停在 init 入口，这时执行 finish 来运行完整个函数
finish

echo \n\n==================== G1Policy::init() 执行完毕后的状态 ====================\n

echo \n--- G1Policy 基本信息 ---\n
print this
printf "G1Policy 地址 = %p\n", this
printf "_g1h = %p\n", _g1h
printf "_collection_set = %p\n", _collection_set

echo \n\n========== 1. G1YoungGenSizer (年轻代大小计算器) ==========\n
print _young_gen_sizer
printf "\n解读:\n"
printf "  _sizer_kind = %d (0=Defaults/自适应, 1=NewSizeOnly, 2=MaxNewSizeOnly, 3=MaxAndNewSize/固定, 4=NewRatio)\n", _young_gen_sizer._sizer_kind
printf "  _adaptive_size = %d (1=自适应调整年轻代, 0=固定大小)\n", _young_gen_sizer._adaptive_size
printf "  _min_desired_young_length = %u 个 Region = %u MB\n", _young_gen_sizer._min_desired_young_length, _young_gen_sizer._min_desired_young_length * 4
printf "  _max_desired_young_length = %u 个 Region = %u MB\n", _young_gen_sizer._max_desired_young_length, _young_gen_sizer._max_desired_young_length * 4

echo \n\n========== 2. 年轻代长度目标 ==========\n
printf "_young_list_target_length = %u 个 Region (当前目标)\n", _young_list_target_length
printf "_young_list_fixed_length  = %u 个 Region (固定模式时使用)\n", _young_list_fixed_length
printf "_young_list_max_length    = %u 个 Region (最大长度)\n", _young_list_max_length

echo \n\n========== 3. 空闲 Region 统计 ==========\n
printf "_free_regions_at_end_of_collection = %u 个 Region\n", _free_regions_at_end_of_collection

echo \n\n========== 4. 预留空间 (Reserve) ==========\n
printf "_reserve_factor  = %f\n", _reserve_factor
printf "_reserve_regions = %u 个 Region = %u MB\n", _reserve_regions, _reserve_regions * 4

echo \n\n========== 5. G1CollectionSet 状态 ==========\n
printf "G1CollectionSet 地址 = %p\n", _collection_set
printf "_inc_build_state = %d (0=Inactive, 1=Active)\n", _collection_set->_inc_build_state
printf "_collection_set_cur_length = %u\n", _collection_set->_collection_set_cur_length
printf "_collection_set_max_length = %u\n", _collection_set->_collection_set_max_length

echo \n\n========== 6. IHOP 控制 ==========\n
printf "_ihop_control = %p\n", _ihop_control

echo \n\n========== 计算验证 ==========\n
printf "堆总 Region 数: 2048\n"
printf "G1NewSizePercent (默认5%%): 2048 * 5%% = 约 102 个 Region\n"
printf "G1MaxNewSizePercent (默认60%%): 2048 * 60%% = 约 1228 个 Region\n"

continue
GDBEOF
