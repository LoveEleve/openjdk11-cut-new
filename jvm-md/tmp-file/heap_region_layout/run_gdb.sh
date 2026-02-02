#!/bin/bash
# 交互式 GDB 调试脚本

cd /data/workspace/openjdk-cut-new

gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'EOF'
set pagination off
set confirm off

# 先运行到 main，让 libjvm.so 加载
break main
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# 现在 libjvm.so 已加载，可以设置断点
delete breakpoints

# 在 make_regions_available 完成后查看 Region
break HeapRegionManager::make_regions_available
commands
    silent
    finish
    
    echo \n========== HeapRegion 内存布局分析 ==========\n
    
    echo \n--- HeapRegion 0 完整结构 ---\n
    set $hr0 = _regions.get_by_index(0)
    print *$hr0
    
    echo \n--- Space 基类字段 (地址范围) ---\n
    printf "_bottom = %p\n", $hr0->_bottom
    printf "_end    = %p\n", $hr0->_end
    printf "_saved_mark_word = %p\n", $hr0->_saved_mark_word
    
    echo \n--- CompactibleSpace 字段 ---\n
    printf "_compaction_top = %p\n", $hr0->_compaction_top
    printf "_next_compaction_space = %p\n", $hr0->_next_compaction_space
    
    echo \n--- G1ContiguousSpace 字段 ---\n
    printf "_top = %p\n", $hr0->_top
    printf "_pre_dummy_top = %p\n", $hr0->_pre_dummy_top
    print $hr0->_bot_part
    
    echo \n--- HeapRegion 核心字段 ---\n
    printf "_hrm_index = %u\n", $hr0->_hrm_index
    print $hr0->_type
    printf "_humongous_start_region = %p\n", $hr0->_humongous_start_region
    printf "_evacuation_failed = %d\n", $hr0->_evacuation_failed
    printf "_next = %p\n", $hr0->_next
    printf "_prev = %p\n", $hr0->_prev
    
    echo \n--- 并发标记相关 ---\n
    printf "_prev_marked_bytes = %lu\n", $hr0->_prev_marked_bytes
    printf "_next_marked_bytes = %lu\n", $hr0->_next_marked_bytes
    printf "_prev_top_at_mark_start = %p\n", $hr0->_prev_top_at_mark_start
    printf "_next_top_at_mark_start = %p\n", $hr0->_next_top_at_mark_start
    
    echo \n--- GC 效率和年龄相关 ---\n
    printf "_gc_efficiency = %f\n", $hr0->_gc_efficiency
    printf "_young_index_in_cset = %d\n", $hr0->_young_index_in_cset
    printf "_surv_rate_group = %p\n", $hr0->_surv_rate_group
    printf "_age_index = %d\n", $hr0->_age_index
    
    echo \n--- 记忆集 ---\n
    printf "_rem_set = %p\n", $hr0->_rem_set
    print *($hr0->_rem_set)
    
    echo \n--- Region 大小验证 ---\n
    printf "容量 (end - bottom) = %lu bytes = %lu MB\n", (size_t)$hr0->_end - (size_t)$hr0->_bottom, ((size_t)$hr0->_end - (size_t)$hr0->_bottom) / 1048576
    printf "已用 (top - bottom) = %lu bytes\n", (size_t)$hr0->_top - (size_t)$hr0->_bottom
    printf "空闲 (end - top)    = %lu bytes\n", (size_t)$hr0->_end - (size_t)$hr0->_top
    
    echo \n--- Region 1 和 Region 2047 对比 ---\n
    set $hr1 = _regions.get_by_index(1)
    set $hr_last = _regions.get_by_index(2047)
    printf "Region 1:    index=%u, bottom=%p, end=%p\n", $hr1->_hrm_index, $hr1->_bottom, $hr1->_end
    printf "Region 2047: index=%u, bottom=%p, end=%p\n", $hr_last->_hrm_index, $hr_last->_bottom, $hr_last->_end
    
    echo \n--- HeapRegion 对象大小 ---\n
    print sizeof(HeapRegion)
    
    continue
end

continue
EOF
