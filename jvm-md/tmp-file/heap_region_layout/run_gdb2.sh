#!/bin/bash
# 简化的 GDB 调试脚本 - 直接在 expand_at 返回后查看

cd /data/workspace/openjdk-cut-new

gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'GDBEOF'
set pagination off
set confirm off

# 先运行到 main，让 libjvm.so 加载
break main
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# 删除 main 断点
delete 1

# 在 expand_at 末尾设置断点 (return 语句)
break heapRegionManager.cpp:259
commands
    silent
    echo \n\n========== HeapRegion 内存布局完整分析 ==========\n\n
    
    echo --- HeapRegion 0 完整结构 dump ---\n
    set $hr0 = this->_regions.get_by_index(0)
    print *$hr0
    
    echo \n\n--- 1. Space 基类字段 (内存地址范围) ---\n
    printf "_bottom         = 0x%lx (Region 起始地址)\n", $hr0->_bottom
    printf "_end            = 0x%lx (Region 结束地址)\n", $hr0->_end
    printf "_saved_mark_word= 0x%lx\n", $hr0->_saved_mark_word
    
    echo \n--- 2. CompactibleSpace 字段 (压缩相关) ---\n
    printf "_compaction_top        = 0x%lx\n", $hr0->_compaction_top
    printf "_next_compaction_space = 0x%lx\n", $hr0->_next_compaction_space
    
    echo \n--- 3. G1ContiguousSpace 字段 (分配相关) ---\n
    printf "_top            = 0x%lx (当前分配位置)\n", $hr0->_top
    printf "_pre_dummy_top  = 0x%lx\n", $hr0->_pre_dummy_top
    echo _bot_part (BlockOffsetTablePart):
    print $hr0->_bot_part
    
    echo \n--- 4. HeapRegion 核心标识字段 ---\n
    printf "_hrm_index      = %u (Region 索引)\n", $hr0->_hrm_index
    echo _type (Region 类型):
    print $hr0->_type
    printf "_humongous_start_region = 0x%lx\n", $hr0->_humongous_start_region
    printf "_evacuation_failed      = %d\n", $hr0->_evacuation_failed
    
    echo \n--- 5. 空闲链表指针 ---\n
    printf "_next = 0x%lx (下一个 Region)\n", $hr0->_next
    printf "_prev = 0x%lx (上一个 Region)\n", $hr0->_prev
    
    echo \n--- 6. 并发标记相关字段 ---\n
    printf "_prev_marked_bytes      = %lu (上次标记存活字节)\n", $hr0->_prev_marked_bytes
    printf "_next_marked_bytes      = %lu (本次标记存活字节)\n", $hr0->_next_marked_bytes
    printf "_prev_top_at_mark_start = 0x%lx\n", $hr0->_prev_top_at_mark_start
    printf "_next_top_at_mark_start = 0x%lx\n", $hr0->_next_top_at_mark_start
    
    echo \n--- 7. GC 策略相关字段 ---\n
    printf "_gc_efficiency       = %f (GC 效率值)\n", $hr0->_gc_efficiency
    printf "_young_index_in_cset = %d\n", $hr0->_young_index_in_cset
    printf "_surv_rate_group     = 0x%lx\n", $hr0->_surv_rate_group
    printf "_age_index           = %d\n", $hr0->_age_index
    printf "_recorded_rs_length  = %lu\n", $hr0->_recorded_rs_length
    printf "_predicted_elapsed_time_ms = %f\n", $hr0->_predicted_elapsed_time_ms
    
    echo \n--- 8. 记忆集 (HeapRegionRemSet) ---\n
    printf "_rem_set = 0x%lx\n", $hr0->_rem_set
    print *($hr0->_rem_set)
    
    echo \n\n========== Region 大小验证 ==========\n
    printf "Region 0 容量: %lu bytes = %lu MB\n", (unsigned long)$hr0->_end - (unsigned long)$hr0->_bottom, ((unsigned long)$hr0->_end - (unsigned long)$hr0->_bottom) / 1048576
    printf "Region 0 已用: %lu bytes\n", (unsigned long)$hr0->_top - (unsigned long)$hr0->_bottom
    printf "Region 0 空闲: %lu bytes\n", (unsigned long)$hr0->_end - (unsigned long)$hr0->_top
    
    echo \n========== 多个 Region 对比 ==========\n
    set $hr1 = this->_regions.get_by_index(1)
    set $hr100 = this->_regions.get_by_index(100)
    set $hr_last = this->_regions.get_by_index(2047)
    
    printf "Region 0:    hrm_index=%4u, bottom=0x%lx, end=0x%lx, type=%s\n", $hr0->_hrm_index, $hr0->_bottom, $hr0->_end, $hr0->_type._type == 0 ? "FREE" : "OTHER"
    printf "Region 1:    hrm_index=%4u, bottom=0x%lx, end=0x%lx, type=%s\n", $hr1->_hrm_index, $hr1->_bottom, $hr1->_end, $hr1->_type._type == 0 ? "FREE" : "OTHER"
    printf "Region 100:  hrm_index=%4u, bottom=0x%lx, end=0x%lx, type=%s\n", $hr100->_hrm_index, $hr100->_bottom, $hr100->_end, $hr100->_type._type == 0 ? "FREE" : "OTHER"
    printf "Region 2047: hrm_index=%4u, bottom=0x%lx, end=0x%lx, type=%s\n", $hr_last->_hrm_index, $hr_last->_bottom, $hr_last->_end, $hr_last->_type._type == 0 ? "FREE" : "OTHER"
    
    echo \n========== HeapRegion 对象元数据 ==========\n
    printf "sizeof(HeapRegion) = %lu bytes\n", sizeof(HeapRegion)
    printf "sizeof(Space)      = %lu bytes\n", sizeof(Space)
    printf "sizeof(HeapRegionRemSet) = %lu bytes\n", sizeof(HeapRegionRemSet)
    
    echo \n========== 堆地址范围总结 ==========\n
    printf "堆起始: 0x%lx\n", $hr0->_bottom
    printf "堆结束: 0x%lx\n", $hr_last->_end
    printf "堆总大小: %lu bytes = %lu GB\n", (unsigned long)$hr_last->_end - (unsigned long)$hr0->_bottom, ((unsigned long)$hr_last->_end - (unsigned long)$hr0->_bottom) / 1073741824
    
    continue
end

continue
GDBEOF
