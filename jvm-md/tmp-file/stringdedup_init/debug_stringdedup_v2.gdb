# G1StringDedup::initialize() 调试脚本 v2
set pagination off
set breakpoint pending on

# 断点: StringDedup::initialize_impl 内部，检查条件后
break stringDedup.inline.hpp:34
commands
    printf "\n"
    printf "╔══════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║  StringDedup::initialize_impl<G1StringDedupQueue, G1StringDedupStat>()       ║\n"
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║  UseStringDeduplication 已确认为 true                                        ║\n"
    printf "║  即将执行:                                                                   ║\n"
    printf "║    1. _enabled = true                                                        ║\n"
    printf "║    2. StringDedupQueue::create<G1StringDedupQueue>()                         ║\n"
    printf "║    3. StringDedupTable::create()                                             ║\n"
    printf "║    4. StringDedupThreadImpl<G1StringDedupStat>::create()                     ║\n"
    printf "╚══════════════════════════════════════════════════════════════════════════════╝\n"
    continue
end

# 断点: G1StringDedupQueue 构造函数完成后
break g1StringDedupQueue.cpp:50
commands
    printf "\n"
    printf "┌──────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│  [步骤1] G1StringDedupQueue 创建完成                                          │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  _nqueues = %lu (等于 ParallelGCThreads)                                  │\n", this->_nqueues
    printf "│  _queues  = %p                                                   │\n", this->_queues
    printf "│  _cursor  = %lu                                                          │\n", this->_cursor
    printf "│  _cancel  = %d                                                               │\n", this->_cancel
    printf "│  _empty   = %d                                                               │\n", this->_empty
    printf "│  _dropped = %lu                                                          │\n", this->_dropped
    printf "│  _max_size = 1000000 (每个队列最大容量)                                       │\n"
    printf "└──────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# 断点: StringDedupTable 创建完成
break stringDedupTable.cpp:244
commands
    printf "\n"
    printf "┌──────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│  [步骤2] StringDedupTable 创建完成                                           │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  _table = %p                                                     │\n", StringDedupTable::_table
    printf "│  _table->_size = %lu 桶                                                  │\n", StringDedupTable::_table->_size
    printf "│  _table->_entries = %lu                                                  │\n", StringDedupTable::_table->_entries
    printf "│  _table->_grow_threshold = %lu                                           │\n", StringDedupTable::_table->_grow_threshold
    printf "│  _table->_shrink_threshold = %lu                                         │\n", StringDedupTable::_table->_shrink_threshold
    printf "│  _table->_hash_seed = %lu                                                │\n", StringDedupTable::_table->_hash_seed
    printf "│  _entry_cache = %p                                               │\n", StringDedupTable::_entry_cache
    printf "└──────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# 断点: StringDedupThread 启动
break stringDedupThread.cpp:43
commands
    printf "\n"
    printf "┌──────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│  [步骤3] StringDedupThread 创建并启动                                        │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  this = %p                                                       │\n", this
    printf "│  线程名: \"StrDedup\"                                                         │\n"
    printf "│  即将调用 create_and_start() 启动线程                                        │\n"
    printf "└──────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# 断点: 全部完成
break g1CollectedHeap.cpp:2338
commands
    printf "\n"
    printf "╔══════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║  G1StringDedup::initialize() 全部完成!                                       ║\n"
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║  StringDedup::is_enabled() = %d                                               ║\n", StringDedup::_enabled
    printf "║  StringDedupQueue::_queue  = %p                                  ║\n", StringDedupQueue::_queue
    printf "║  StringDedupTable::_table  = %p                                  ║\n", StringDedupTable::_table
    printf "║  StringDedupThread::_thread= %p                                  ║\n", StringDedupThread::_thread
    printf "╚══════════════════════════════════════════════════════════════════════════════╝\n"
    continue
end

run
