# G1StringDedup::initialize() 调试脚本 v3
# 使用条件断点来验证 UseStringDeduplication 值
set pagination off
set breakpoint pending on

# 在 arguments.cpp 中设置断点来验证参数解析
break Arguments::apply_ergo
commands
    printf "\n>>> Arguments::apply_ergo() 被调用\n"
    printf ">>> UseStringDeduplication = %d\n", UseStringDeduplication
    continue
end

# 断点: G1StringDedup::initialize 入口
break G1StringDedup::initialize
commands
    printf "\n"
    printf "╔══════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║  G1StringDedup::initialize() 入口                                            ║\n"
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║  UseStringDeduplication = %d                                                  ║\n", UseStringDeduplication
    printf "║  StringDeduplicationAgeThreshold = %lu                                        ║\n", StringDeduplicationAgeThreshold
    if UseStringDeduplication
        printf "║  → 将初始化 String Deduplication 组件                                        ║\n"
    else
        printf "║  → UseStringDeduplication=false, 跳过初始化                                  ║\n"
    end
    printf "╚══════════════════════════════════════════════════════════════════════════════╝\n"
    continue
end

# 断点: 只有当 UseStringDeduplication=true 时才触发的内部初始化
break stringDedup.inline.hpp:34 if UseStringDeduplication == 1
commands
    printf "\n"
    printf "┌──────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│  进入 initialize_impl() - UseStringDeduplication = true                      │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  即将创建:                                                                   │\n"
    printf "│    1. StringDedupQueue (去重候选队列)                                        │\n"
    printf "│    2. StringDedupTable (去重哈希表)                                          │\n"
    printf "│    3. StringDedupThread (去重后台线程)                                       │\n"
    printf "└──────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# 断点: G1StringDedupQueue 构造
break G1StringDedupQueue::G1StringDedupQueue
commands
    printf "\n"
    printf "┌──────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│  创建 G1StringDedupQueue                                                     │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  ParallelGCThreads = %u → 创建 %u 个工作队列                                  │\n", ParallelGCThreads, ParallelGCThreads
    printf "│  每个队列最大容量 = 1,000,000                                                 │\n"
    printf "└──────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# 断点: StringDedupTable::create
break StringDedupTable::create
commands
    printf "\n"
    printf "┌──────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│  创建 StringDedupTable                                                       │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  初始大小 = 1024 桶                                                          │\n"
    printf "│  最大大小 = 16,777,216 桶                                                    │\n"
    printf "│  Entry 缓存最大 = 102 条目                                                   │\n"
    printf "└──────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# 断点: StringDedupThread 构造
break StringDedupThread::StringDedupThread
commands
    printf "\n"
    printf "┌──────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│  创建 StringDedupThread (StrDedup)                                           │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  线程名: \"StrDedup\"                                                         │\n"
    printf "│  类型: ConcurrentGCThread                                                    │\n"
    printf "│  功能: 后台处理去重候选队列                                                  │\n"
    printf "└──────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

run
