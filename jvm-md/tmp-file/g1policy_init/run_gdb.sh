#!/bin/bash
# GDB 调试脚本：G1Policy::init() 方法分析

cd /data/workspace/openjdk-cut-new

gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'GDBEOF'
set pagination off
set confirm off

# 先运行到 main，让 libjvm.so 加载
break main
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# 删除 main 断点
delete 1

# 在 G1Policy::init 设置断点
break G1Policy::init
commands
    silent
    echo \n\n========== G1Policy::init() 开始 ==========\n
    echo \n--- 入参 ---\n
    printf "g1h = %p\n", g1h
    printf "collection_set = %p\n", collection_set
    
    echo \n--- 调用前 G1Policy 状态 ---\n
    printf "this = %p\n", this
    printf "_g1h = %p (应该为 NULL 或未初始化)\n", this->_g1h
    printf "_collection_set = %p\n", this->_collection_set
    
    echo \n--- G1YoungGenSizer 状态 ---\n
    print this->_young_gen_sizer
    
    echo \n--- 继续执行到方法结束 ---\n
    finish
    
    echo \n\n========== G1Policy::init() 完成 ==========\n
    
    echo \n--- 调用后 G1Policy 核心字段 ---\n
    printf "_g1h = %p\n", this->_g1h
    printf "_collection_set = %p\n", this->_collection_set
    
    echo \n--- 年轻代大小配置 (G1YoungGenSizer) ---\n
    print this->_young_gen_sizer
    printf "_adaptive_size = %d (是否自适应)\n", this->_young_gen_sizer._adaptive_size
    printf "_min_desired_young_length = %u (最小年轻代 Region 数)\n", this->_young_gen_sizer._min_desired_young_length
    printf "_max_desired_young_length = %u (最大年轻代 Region 数)\n", this->_young_gen_sizer._max_desired_young_length
    printf "_sizer_kind = %d (0=Defaults,1=NewSizeOnly,2=MaxNewSizeOnly,3=MaxAndNewSize,4=NewRatio)\n", this->_young_gen_sizer._sizer_kind
    
    echo \n--- 计算结果（字节转换） ---\n
    printf "最小年轻代大小 = %lu MB\n", (unsigned long)this->_young_gen_sizer._min_desired_young_length * 4
    printf "最大年轻代大小 = %lu MB\n", (unsigned long)this->_young_gen_sizer._max_desired_young_length * 4
    
    echo \n--- 空闲 Region 统计 ---\n
    printf "_free_regions_at_end_of_collection = %u\n", this->_free_regions_at_end_of_collection
    
    echo \n--- 年轻代长度目标 ---\n
    printf "_young_list_target_length = %u\n", this->_young_list_target_length
    printf "_young_list_fixed_length = %u\n", this->_young_list_fixed_length
    printf "_young_list_max_length = %u\n", this->_young_list_max_length
    
    echo \n--- 预留空间 ---\n
    printf "_reserve_factor = %f\n", this->_reserve_factor
    printf "_reserve_regions = %u\n", this->_reserve_regions
    
    echo \n--- G1CollectionSet 状态 ---\n
    print *collection_set
    printf "_inc_build_state = %d (0=Inactive, 1=Active)\n", collection_set->_inc_build_state
    
    echo \n--- IHOP 控制 ---\n
    print this->_ihop_control
    
    echo \n--- 分析器 (Analytics) ---\n
    printf "_analytics = %p\n", this->_analytics
    
    continue
end

continue
GDBEOF
