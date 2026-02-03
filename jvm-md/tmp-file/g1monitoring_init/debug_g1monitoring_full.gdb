# G1MonitoringSupport 构造函数完整调试脚本
set pagination off
set breakpoint pending on

# ====== 阶段1: 构造函数入口 ======
break G1MonitoringSupport::G1MonitoringSupport
commands
    printf "\n"
    printf "╔══════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║  [阶段1] G1MonitoringSupport 构造函数入口                                     ║\n"
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║  this = %p                                                       ║\n", this
    printf "║  g1h  = %p  (G1CollectedHeap 指针)                               ║\n", g1h
    printf "╚══════════════════════════════════════════════════════════════════════════════╝\n"
    continue
end

# ====== 阶段2: recalculate_sizes 入口 ======
break G1MonitoringSupport::recalculate_sizes
commands
    printf "\n"
    printf "╔══════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║  [阶段2] recalculate_sizes() 开始计算各区域大小                               ║\n"
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║  _overall_reserved = %lu (%.2f GB)                                   ║\n", this->_overall_reserved, (double)this->_overall_reserved/(1024*1024*1024)
    printf "╚══════════════════════════════════════════════════════════════════════════════╝\n"
    continue
end

# ====== 阶段2.1: recalculate_sizes 中间过程 - 获取 region 数量后 ======
break g1MonitoringSupport.cpp:214
commands
    printf "\n"
    printf "┌──────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│  [阶段2.1] 获取 Region 数量完成                                               │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  young_list_length      = %u regions                                          │\n", young_list_length
    printf "│  survivor_list_length   = %u regions                                          │\n", survivor_list_length
    printf "│  eden_list_length       = %u regions                                          │\n", eden_list_length
    printf "│  young_list_max_length  = %u regions  (Young Gen 最大可扩展到)                │\n", young_list_max_length
    printf "│  eden_list_max_length   = %u regions                                          │\n", eden_list_max_length
    printf "│  HeapRegion::GrainBytes = %lu bytes = %lu MB                                  │\n", HeapRegion::GrainBytes, HeapRegion::GrainBytes/(1024*1024)
    printf "└──────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# ====== 阶段2.2: recalculate_sizes 完成 ======
break g1MonitoringSupport.cpp:256
commands
    printf "\n"
    printf "┌──────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│  [阶段2.2] recalculate_sizes() 计算完成                                       │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│                          堆大小统计                                           │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  _overall_reserved   = %12lu bytes = %8.2f GB                         │\n", this->_overall_reserved, (double)this->_overall_reserved/(1024*1024*1024)
    printf "│  _overall_committed  = %12lu bytes = %8.2f GB                         │\n", this->_overall_committed, (double)this->_overall_committed/(1024*1024*1024)
    printf "│  _overall_used       = %12lu bytes = %8.2f MB                         │\n", this->_overall_used, (double)this->_overall_used/(1024*1024)
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│                       年轻代 (Young Gen)                                      │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  _young_region_num   = %12u regions                                       │\n", this->_young_region_num
    printf "│  _young_gen_committed= %12lu bytes = %8.2f MB                         │\n", this->_young_gen_committed, (double)this->_young_gen_committed/(1024*1024)
    printf "│  _eden_committed     = %12lu bytes = %8.2f MB  (= %u regions)         │\n", this->_eden_committed, (double)this->_eden_committed/(1024*1024), (unsigned)(this->_eden_committed/4194304)
    printf "│  _eden_used          = %12lu bytes = %8.2f MB                         │\n", this->_eden_used, (double)this->_eden_used/(1024*1024)
    printf "│  _survivor_committed = %12lu bytes = %8.2f MB                         │\n", this->_survivor_committed, (double)this->_survivor_committed/(1024*1024)
    printf "│  _survivor_used      = %12lu bytes = %8.2f MB                         │\n", this->_survivor_used, (double)this->_survivor_used/(1024*1024)
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│                        老年代 (Old Gen)                                       │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  _old_committed      = %12lu bytes = %8.2f GB                         │\n", this->_old_committed, (double)this->_old_committed/(1024*1024*1024)
    printf "│  _old_used           = %12lu bytes = %8.2f MB                         │\n", this->_old_used, (double)this->_old_used/(1024*1024)
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  验证: eden + survivor + old = %lu (应等于 overall_committed)          │\n", this->_eden_committed + this->_survivor_committed + this->_old_committed
    printf "└──────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# ====== 阶段3: 创建 CollectorCounters ======
break CollectorCounters::CollectorCounters
commands
    printf "\n"
    printf "┌──────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│  [阶段3] 创建 CollectorCounters                                               │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  name    = \"%s\"                                             │\n", name
    printf "│  ordinal = %d  → jstat name: collector.%d                                    │\n", ordinal, ordinal
    printf "│  创建计数器: invocations, time, lastEntryTime, lastExitTime                  │\n"
    printf "└──────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# ====== 阶段4: 创建 G1OldGenerationCounters ======
break G1OldGenerationCounters::G1OldGenerationCounters
commands
    printf "\n"
    printf "┌──────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│  [阶段4] 创建 G1OldGenerationCounters (老年代计数器)                          │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  name = \"%s\" → jstat: generation.1                                          │\n", name
    printf "│  old_gen_max() = %lu bytes (%.2f GB)                                  │\n", g1mm->_overall_reserved, (double)g1mm->_overall_reserved/(1024*1024*1024)
    printf "└──────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# ====== 阶段5: 创建 G1YoungGenerationCounters ======
break G1YoungGenerationCounters::G1YoungGenerationCounters
commands
    printf "\n"
    printf "┌──────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│  [阶段5] 创建 G1YoungGenerationCounters (年轻代计数器)                        │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  name = \"%s\" → jstat: generation.0                                        │\n", name
    printf "│  young_gen_max() = %lu bytes (%.2f GB)                                │\n", g1mm->_overall_reserved, (double)g1mm->_overall_reserved/(1024*1024*1024)
    printf "│  spaces = 3 (Eden + S0 + S1)                                                 │\n"
    printf "└──────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# ====== 阶段6: 创建 HSpaceCounters ======
break HSpaceCounters::HSpaceCounters
commands
    printf "\n"
    printf "┌──────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│  [阶段6] 创建 HSpaceCounters (空间计数器)                                     │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  name_space      = \"%s\"                                   │\n", name_space
    printf "│  name            = \"%s\"                                                      │\n", name
    printf "│  ordinal         = %d → space.%d                                             │\n", ordinal, ordinal
    printf "│  max_size        = %12lu bytes = %.2f GB                              │\n", max_size, (double)max_size/(1024*1024*1024)
    printf "│  init_capacity   = %12lu bytes = %.2f MB                              │\n", initial_capacity, (double)initial_capacity/(1024*1024)
    printf "│  创建: name, maxCapacity, capacity, used, initCapacity                       │\n"
    printf "└──────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# ====== 阶段7: 构造函数完成 ======
break g1MonitoringSupport.cpp:196
commands
    printf "\n"
    printf "╔══════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║  [阶段7] G1MonitoringSupport 构造完成!                                        ║\n"
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║                      GC 收集器计数器 (CollectorCounters)                     ║\n"
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║  _incremental_collection_counters = %p                           ║\n", this->_incremental_collection_counters
    printf "║    → collector.0: G1 Young/Mixed GC  (jstat: YGC, YGCT)                      ║\n"
    printf "║  _full_collection_counters        = %p                           ║\n", this->_full_collection_counters
    printf "║    → collector.1: G1 Full GC         (jstat: FGC, FGCT)                      ║\n"
    printf "║  _conc_collection_counters        = %p                           ║\n", this->_conc_collection_counters
    printf "║    → collector.2: G1 Concurrent STW phases                                   ║\n"
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║                      代计数器 (GenerationCounters)                           ║\n"
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║  _young_collection_counters = %p  → generation.0 (Young)         ║\n", this->_young_collection_counters
    printf "║  _old_collection_counters   = %p  → generation.1 (Old)           ║\n", this->_old_collection_counters
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║                      空间计数器 (HSpaceCounters)                             ║\n"
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║  _eden_counters      = %p  → generation.0.space.0 (Eden)         ║\n", this->_eden_counters
    printf "║  _from_counters      = %p  → generation.0.space.1 (S0, 未使用)   ║\n", this->_from_counters
    printf "║  _to_counters        = %p  → generation.0.space.2 (S1)           ║\n", this->_to_counters
    printf "║  _old_space_counters = %p  → generation.1.space.0 (Old)          ║\n", this->_old_space_counters
    printf "╚══════════════════════════════════════════════════════════════════════════════╝\n"
    continue
end

run
