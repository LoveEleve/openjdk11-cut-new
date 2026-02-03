# G1StringDedup::initialize() 调试脚本
set pagination off
set breakpoint pending on

# 断点1: G1StringDedup::initialize 入口
break G1StringDedup::initialize
commands
    printf "\n"
    printf "╔══════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║  G1StringDedup::initialize() 开始                                            ║\n"
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║  UseStringDeduplication = %d                                                  ║\n", UseStringDeduplication
    printf "║  StringDeduplicationAgeThreshold = %lu (对象年龄阈值)                         ║\n", StringDeduplicationAgeThreshold
    printf "╚══════════════════════════════════════════════════════════════════════════════╝\n"
    continue
end

# 断点2: G1StringDedupQueue 构造函数
break G1StringDedupQueue::G1StringDedupQueue
commands
    printf "\n"
    printf "┌──────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│  [步骤1] 创建 G1StringDedupQueue (去重候选队列)                               │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  this = %p                                                       │\n", this
    printf "│  ParallelGCThreads = %u  → 将创建 %u 个工作队列                               │\n", ParallelGCThreads, ParallelGCThreads
    printf "│  _max_size = 1,000,000 (每个队列最大容量)                                     │\n"
    printf "└──────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# 断点3: StringDedupTable::create
break StringDedupTable::create
commands
    printf "\n"
    printf "┌──────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│  [步骤2] 创建 StringDedupTable (去重哈希表)                                   │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  即将创建:                                                                   │\n"
    printf "│    • _entry_cache: Entry 缓存 (max = 1024 * 0.1 = 102)                       │\n"
    printf "│    • _table: 哈希表 (初始大小 = 1024 桶)                                     │\n"
    printf "└──────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# 断点4: StringDedupTable 构造函数
break StringDedupTable::StringDedupTable
commands
    printf "\n"
    printf "┌──────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│  StringDedupTable 构造                                                       │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  size = %lu 桶                                                           │\n", size
    printf "│  hash_seed = %lu                                                         │\n", hash_seed
    printf "│  _grow_threshold = size * 2.0 = %lu                                      │\n", (unsigned long)(size * 2.0)
    printf "│  _shrink_threshold = size * 0.67 = %lu                                   │\n", (unsigned long)(size * 0.67)
    printf "└──────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# 断点5: StringDedupThread 构造函数
break StringDedupThread::StringDedupThread
commands
    printf "\n"
    printf "┌──────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│  [步骤3] 创建 StringDedupThread (去重后台线程)                               │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  this = %p                                                       │\n", this
    printf "│  线程名: \"StrDedup\"                                                         │\n"
    printf "│  功能: 后台并发处理去重候选队列中的 String 对象                              │\n"
    printf "└──────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# 断点6: 初始化完成后回到调用处
break g1CollectedHeap.cpp:2338
commands
    printf "\n"
    printf "╔══════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║  G1StringDedup::initialize() 完成!                                           ║\n"
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║  String Deduplication 已启用:                                                ║\n"
    printf "║    • Queue: %u 个工作队列, 每队列最大 1M 条目                                 ║\n", ParallelGCThreads
    printf "║    • Table: 初始 1024 桶, 最大 16M 桶                                         ║\n"
    printf "║    • Thread: StrDedup 后台线程已启动                                         ║\n"
    printf "╚══════════════════════════════════════════════════════════════════════════════╝\n"
    continue
end

run
