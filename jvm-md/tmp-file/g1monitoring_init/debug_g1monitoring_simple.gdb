# G1MonitoringSupport 简化调试脚本
set pagination off
set breakpoint pending on

# 断点1: G1MonitoringSupport 构造函数
break G1MonitoringSupport::G1MonitoringSupport
commands
    printf "\n===== G1MonitoringSupport 构造函数开始 =====\n"
    printf "G1CollectedHeap* g1h = %p\n", g1h
    continue
end

# 断点2: recalculate_sizes 完成后 (行240)
break g1MonitoringSupport.cpp:240
commands
    printf "\n===== recalculate_sizes 计算结果 =====\n"
    printf "_overall_reserved   = %lu (%.2f GB)\n", this->_overall_reserved, (double)this->_overall_reserved/(1024*1024*1024)
    printf "_overall_committed  = %lu (%.2f GB)\n", this->_overall_committed, (double)this->_overall_committed/(1024*1024*1024)
    printf "_overall_used       = %lu\n", this->_overall_used
    printf "_young_region_num   = %u\n", this->_young_region_num
    printf "_young_gen_committed= %lu (%.2f MB)\n", this->_young_gen_committed, (double)this->_young_gen_committed/(1024*1024)
    printf "_eden_committed     = %lu (%.2f MB)\n", this->_eden_committed, (double)this->_eden_committed/(1024*1024)
    printf "_eden_used          = %lu\n", this->_eden_used
    printf "_survivor_committed = %lu\n", this->_survivor_committed
    printf "_survivor_used      = %lu\n", this->_survivor_used
    printf "_old_committed      = %lu (%.2f GB)\n", this->_old_committed, (double)this->_old_committed/(1024*1024*1024)
    printf "_old_used           = %lu\n", this->_old_used
    continue
end

# 断点3: 构造函数结束
break g1MonitoringSupport.cpp:180
commands
    printf "\n===== G1MonitoringSupport 构造完成 =====\n"
    printf "计数器创建完毕:\n"
    printf "  _incremental_collection_counters = %p (G1 incremental collections)\n", this->_incremental_collection_counters
    printf "  _full_collection_counters        = %p (G1 full collections)\n", this->_full_collection_counters
    printf "  _conc_collection_counters        = %p (G1 STW phases)\n", this->_conc_collection_counters
    printf "  _old_collection_counters         = %p (generation.1)\n", this->_old_collection_counters
    printf "  _young_collection_counters       = %p (generation.0)\n", this->_young_collection_counters
    printf "  _eden_counters                   = %p (generation.0.space.0)\n", this->_eden_counters
    printf "  _from_counters                   = %p (generation.0.space.1)\n", this->_from_counters
    printf "  _to_counters                     = %p (generation.0.space.2)\n", this->_to_counters
    printf "  _old_space_counters              = %p (generation.1.space.0)\n", this->_old_space_counters
    continue
end

run
