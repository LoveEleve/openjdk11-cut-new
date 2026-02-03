# G1MonitoringSupport 详细调试脚本
set pagination off
set breakpoint pending on

# 只在构造函数完成后停止，打印所有成员变量
break g1MonitoringSupport.cpp:180
commands
    printf "\n"
    printf "╔════════════════════════════════════════════════════════════════════╗\n"
    printf "║           G1MonitoringSupport 构造完成 - 详细信息                  ║\n"
    printf "╠════════════════════════════════════════════════════════════════════╣\n"
    printf "║ this = %p                                           ║\n", this
    printf "║ _g1h = %p                                           ║\n", this->_g1h
    printf "╠════════════════════════════════════════════════════════════════════╣\n"
    printf "║                     堆大小统计 (8GB -Xms/-Xmx)                     ║\n"
    printf "╠════════════════════════════════════════════════════════════════════╣\n"
    printf "║ _overall_reserved   = %12lu bytes = %8.2f GB               ║\n", this->_overall_reserved, (double)this->_overall_reserved/(1024*1024*1024)
    printf "║ _overall_committed  = %12lu bytes = %8.2f GB               ║\n", this->_overall_committed, (double)this->_overall_committed/(1024*1024*1024)
    printf "║ _overall_used       = %12lu bytes = %8.2f MB               ║\n", this->_overall_used, (double)this->_overall_used/(1024*1024)
    printf "╠════════════════════════════════════════════════════════════════════╣\n"
    printf "║                     年轻代 (Young Generation)                      ║\n"
    printf "╠════════════════════════════════════════════════════════════════════╣\n"
    printf "║ _young_region_num   = %12u regions                             ║\n", this->_young_region_num
    printf "║ _young_gen_committed= %12lu bytes = %8.2f MB               ║\n", this->_young_gen_committed, (double)this->_young_gen_committed/(1024*1024)
    printf "║ _eden_committed     = %12lu bytes = %8.2f MB               ║\n", this->_eden_committed, (double)this->_eden_committed/(1024*1024)
    printf "║ _eden_used          = %12lu bytes = %8.2f MB               ║\n", this->_eden_used, (double)this->_eden_used/(1024*1024)
    printf "║ _survivor_committed = %12lu bytes = %8.2f MB               ║\n", this->_survivor_committed, (double)this->_survivor_committed/(1024*1024)
    printf "║ _survivor_used      = %12lu bytes = %8.2f MB               ║\n", this->_survivor_used, (double)this->_survivor_used/(1024*1024)
    printf "╠════════════════════════════════════════════════════════════════════╣\n"
    printf "║                     老年代 (Old Generation)                        ║\n"
    printf "╠════════════════════════════════════════════════════════════════════╣\n"
    printf "║ _old_committed      = %12lu bytes = %8.2f GB               ║\n", this->_old_committed, (double)this->_old_committed/(1024*1024*1024)
    printf "║ _old_used           = %12lu bytes = %8.2f MB               ║\n", this->_old_used, (double)this->_old_used/(1024*1024)
    printf "╠════════════════════════════════════════════════════════════════════╣\n"
    printf "║                     GC 收集器计数器 (jstat collector.*)            ║\n"
    printf "╠════════════════════════════════════════════════════════════════════╣\n"
    printf "║ _incremental_collection_counters = %p  (collector.0)      ║\n", this->_incremental_collection_counters
    printf "║   -> G1 Young GC / Mixed GC 计数                                   ║\n"
    printf "║ _full_collection_counters        = %p  (collector.1)      ║\n", this->_full_collection_counters
    printf "║   -> G1 Full GC 计数                                               ║\n"
    printf "║ _conc_collection_counters        = %p  (collector.2)      ║\n", this->_conc_collection_counters
    printf "║   -> G1 并发GC的STW阶段计数                                        ║\n"
    printf "╠════════════════════════════════════════════════════════════════════╣\n"
    printf "║                     代空间计数器 (jstat generation.*)              ║\n"
    printf "╠════════════════════════════════════════════════════════════════════╣\n"
    printf "║ _young_collection_counters = %p  (generation.0)           ║\n", this->_young_collection_counters
    printf "║ _old_collection_counters   = %p  (generation.1)           ║\n", this->_old_collection_counters
    printf "╠════════════════════════════════════════════════════════════════════╣\n"
    printf "║                     空间计数器 (jstat space.*)                     ║\n"
    printf "╠════════════════════════════════════════════════════════════════════╣\n"
    printf "║ _eden_counters      = %p  (generation.0.space.0 = Eden)   ║\n", this->_eden_counters
    printf "║ _from_counters      = %p  (generation.0.space.1 = S0)     ║\n", this->_from_counters
    printf "║ _to_counters        = %p  (generation.0.space.2 = S1)     ║\n", this->_to_counters
    printf "║ _old_space_counters = %p  (generation.1.space.0 = Old)    ║\n", this->_old_space_counters
    printf "╚════════════════════════════════════════════════════════════════════╝\n"
    continue
end

run
