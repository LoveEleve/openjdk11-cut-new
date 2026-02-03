# G1StringDedup::initialize() 调试脚本 - 强制启用
set pagination off
set breakpoint pending on

# 在 initialize 之前强制设置 UseStringDeduplication = true
break G1StringDedup::initialize
commands
    printf "\n"
    printf ">>> 强制设置 UseStringDeduplication = true\n"
    set UseStringDeduplication = 1
    printf ">>> UseStringDeduplication 现在 = %d\n", UseStringDeduplication
    printf "\n"
    printf "╔══════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║  G1StringDedup::initialize() 开始 (已强制启用)                               ║\n"
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║  UseStringDeduplication = %d                                                  ║\n", UseStringDeduplication
    printf "║  StringDeduplicationAgeThreshold = %lu                                        ║\n", StringDeduplicationAgeThreshold
    printf "╚══════════════════════════════════════════════════════════════════════════════╝\n"
    continue
end

# 断点: G1StringDedupQueue 构造完成
break g1StringDedupQueue.cpp:50
commands
    printf "\n"
    printf "┌──────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│  [步骤1] G1StringDedupQueue 创建完成                                          │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  this = %p                                                       │\n", this
    printf "│  _nqueues = %lu (等于 ParallelGCThreads)                                  │\n", this->_nqueues
    printf "│  _queues  = %p (队列数组指针)                                    │\n", this->_queues
    printf "│  _max_size = 1,000,000 (每队列最大容量)                                       │\n"
    printf "│  _empty = %d, _cancel = %d                                                    │\n", this->_empty, this->_cancel
    printf "└──────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# 断点: StringDedupTable 构造完成
break stringDedupTable.cpp:234
commands
    printf "\n"
    printf "┌──────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│  [步骤2] StringDedupTable 构造完成                                           │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  this = %p                                                       │\n", this
    printf "│  _size = %lu 桶                                                          │\n", this->_size
    printf "│  _entries = %lu                                                          │\n", this->_entries
    printf "│  _grow_threshold = %lu (200%% 负载时扩容)                                 │\n", this->_grow_threshold
    printf "│  _shrink_threshold = %lu (67%% 负载时缩容)                                │\n", this->_shrink_threshold
    printf "│  _hash_seed = %lu                                                        │\n", this->_hash_seed
    printf "│  _buckets = %p (哈希桶数组)                                      │\n", this->_buckets
    printf "└──────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# 断点: StringDedupThread 启动
break stringDedupThread.cpp:44
commands
    printf "\n"
    printf "┌──────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│  [步骤3] StringDedupThread 创建并启动                                        │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  this = %p                                                       │\n", this
    printf "│  线程名: \"StrDedup\"                                                         │\n"
    printf "│  功能: 后台从队列 pop String 对象，在 Table 中去重                           │\n"
    printf "│  刚调用 create_and_start() 启动线程                                          │\n"
    printf "└──────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# 断点: 初始化完成
break g1CollectedHeap.cpp:2338
commands
    printf "\n"
    printf "╔══════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║  G1StringDedup::initialize() 全部完成!                                       ║\n"
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║  StringDedup::_enabled     = %d                                               ║\n", StringDedup::_enabled
    printf "║  StringDedupQueue::_queue  = %p                                  ║\n", StringDedupQueue::_queue
    printf "║  StringDedupTable::_table  = %p                                  ║\n", StringDedupTable::_table
    printf "║  StringDedupThread::_thread= %p                                  ║\n", StringDedupThread::_thread
    printf "╚══════════════════════════════════════════════════════════════════════════════╝\n"
    continue
end

run
