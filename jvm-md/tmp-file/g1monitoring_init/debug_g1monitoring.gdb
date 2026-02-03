# G1MonitoringSupport 初始化调试脚本
# 使用方法:
# gdb -x /data/workspace/openjdk-cut-new/jvm-md/tmp-file/g1monitoring_init/debug_g1monitoring.gdb \
#     --args /data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
#     -Xms8G -Xmx8G -XX:+UseG1GC -version

set pagination off
set breakpoint pending on

# 断点1: G1MonitoringSupport 构造函数入口
break G1MonitoringSupport::G1MonitoringSupport
commands
    printf "\n========== G1MonitoringSupport 构造函数开始 ==========\n"
    printf "G1CollectedHeap* g1h = %p\n", g1h
    printf "g1h->max_capacity() = %lu bytes (%.2f GB)\n", g1h->_hrm._num_committed * 4194304, (double)(g1h->_hrm._num_committed * 4194304) / (1024*1024*1024)
    continue
end

# 断点2: recalculate_sizes 函数 - 查看堆区域计算
break G1MonitoringSupport::recalculate_sizes
commands
    printf "\n========== recalculate_sizes() 被调用 ==========\n"
    printf "this = %p\n", this
    continue
end

# 断点3: 在 recalculate_sizes 返回前查看计算结果
break g1MonitoringSupport.cpp:240
commands
    printf "\n---------- recalculate_sizes 计算结果 ----------\n"
    printf "_overall_reserved   = %lu bytes (%.2f GB)\n", _overall_reserved, (double)_overall_reserved/(1024*1024*1024)
    printf "_overall_committed  = %lu bytes (%.2f MB)\n", _overall_committed, (double)_overall_committed/(1024*1024)
    printf "_overall_used       = %lu bytes (%.2f MB)\n", _overall_used, (double)_overall_used/(1024*1024)
    printf "\n--- Young Generation ---\n"
    printf "_young_region_num   = %u regions\n", _young_region_num
    printf "_young_gen_committed= %lu bytes (%.2f MB)\n", _young_gen_committed, (double)_young_gen_committed/(1024*1024)
    printf "_eden_committed     = %lu bytes (%.2f MB)\n", _eden_committed, (double)_eden_committed/(1024*1024)
    printf "_eden_used          = %lu bytes (%.2f MB)\n", _eden_used, (double)_eden_used/(1024*1024)
    printf "_survivor_committed = %lu bytes (%.2f MB)\n", _survivor_committed, (double)_survivor_committed/(1024*1024)
    printf "_survivor_used      = %lu bytes (%.2f MB)\n", _survivor_used, (double)_survivor_used/(1024*1024)
    printf "\n--- Old Generation ---\n"
    printf "_old_committed      = %lu bytes (%.2f MB)\n", _old_committed, (double)_old_committed/(1024*1024)
    printf "_old_used           = %lu bytes (%.2f MB)\n", _old_used, (double)_old_used/(1024*1024)
    continue
end

# 断点4: 创建 CollectorCounters 时
break CollectorCounters::CollectorCounters
commands
    printf "\n---------- 创建 CollectorCounters ----------\n"
    printf "name = %s\n", name
    printf "ordinal = %d\n", ordinal
    continue
end

# 断点5: 创建 G1OldGenerationCounters 时
break G1OldGenerationCounters::G1OldGenerationCounters
commands
    printf "\n---------- 创建 G1OldGenerationCounters ----------\n"
    printf "name = %s\n", name
    printf "g1mm->old_gen_max() = %lu bytes (%.2f GB)\n", g1mm->_overall_reserved, (double)g1mm->_overall_reserved/(1024*1024*1024)
    continue
end

# 断点6: 创建 G1YoungGenerationCounters 时
break G1YoungGenerationCounters::G1YoungGenerationCounters
commands
    printf "\n---------- 创建 G1YoungGenerationCounters ----------\n"
    printf "name = %s\n", name
    printf "g1mm->young_gen_max() = %lu bytes (%.2f GB)\n", g1mm->_overall_reserved, (double)g1mm->_overall_reserved/(1024*1024*1024)
    continue
end

# 断点7: 创建 HSpaceCounters 时
break HSpaceCounters::HSpaceCounters
commands
    printf "\n---------- 创建 HSpaceCounters ----------\n"
    printf "name = %s\n", name
    printf "ordinal = %d\n", ordinal
    printf "max_capacity = %lu bytes\n", max_capacity
    printf "init_capacity = %lu bytes\n", init_capacity
    continue
end

# 断点8: G1MonitoringSupport 构造函数结束 (在 _from_counters->update_used 后)
break g1MonitoringSupport.cpp:180
commands
    printf "\n========== G1MonitoringSupport 构造函数完成 ==========\n"
    printf "已创建的计数器:\n"
    printf "  _incremental_collection_counters = %p\n", _incremental_collection_counters
    printf "  _full_collection_counters        = %p\n", _full_collection_counters
    printf "  _conc_collection_counters        = %p\n", _conc_collection_counters
    printf "  _old_collection_counters         = %p\n", _old_collection_counters
    printf "  _young_collection_counters       = %p\n", _young_collection_counters
    printf "  _old_space_counters              = %p\n", _old_space_counters
    printf "  _eden_counters                   = %p\n", _eden_counters
    printf "  _from_counters                   = %p\n", _from_counters
    printf "  _to_counters                     = %p\n", _to_counters
    continue
end

run
