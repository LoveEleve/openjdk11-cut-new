# G1YoungGenerationCounters 详细调试脚本
set pagination off
set breakpoint pending on

# 断点1: G1YoungGenerationCounters 构造函数入口
break G1YoungGenerationCounters::G1YoungGenerationCounters
commands
    printf "\n"
    printf "╔══════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║  G1YoungGenerationCounters 构造函数                                          ║\n"
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║  this = %p                                                       ║\n", this
    printf "║  g1mm = %p                                                       ║\n", g1mm
    printf "║  name = \"%s\"                                                              ║\n", name
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║  传递给 G1GenerationCounters 的参数:                                         ║\n"
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║  ordinal      = 0  → 命名空间: generation.0                                  ║\n"
    printf "║  spaces       = 3  → Eden + S0 + S1                                          ║\n"
    printf "║  min_capacity = pad_capacity(0, 3)         = %lu bytes                   ║\n", 0 + 8*3
    printf "║  max_capacity = pad_capacity(young_max, 3) = %lu bytes              ║\n", g1mm->_overall_reserved + 8*3
    printf "║              = %.2f GB + 24 bytes                                           ║\n", (double)g1mm->_overall_reserved/(1024*1024*1024)
    printf "║  curr_capacity= pad_capacity(0, 3)         = %lu bytes (初始)            ║\n", 0 + 8*3
    printf "╚══════════════════════════════════════════════════════════════════════════════╝\n"
    continue
end

# 断点2: GenerationCounters::initialize - 创建 PerfData
break GenerationCounters::initialize
commands
    printf "\n"
    printf "┌──────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│  GenerationCounters::initialize() 创建性能计数器                             │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  name         = \"%s\"                                                       │\n", name
    printf "│  ordinal      = %d  → namespace: generation.%d                               │\n", ordinal, ordinal
    printf "│  spaces       = %d                                                           │\n", spaces
    printf "│  min_capacity = %lu bytes                                                │\n", min_capacity
    printf "│  max_capacity = %lu bytes = %.2f GB                              │\n", max_capacity, (double)max_capacity/(1024*1024*1024)
    printf "│  curr_capacity= %lu bytes                                                │\n", curr_capacity
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  将创建以下 PerfData 计数器:                                                 │\n"
    printf "│    • generation.%d.name         = \"%s\" (string constant)                   │\n", ordinal, name
    printf "│    • generation.%d.spaces       = %d (constant)                              │\n", ordinal, spaces
    printf "│    • generation.%d.minCapacity  = %lu (constant)                         │\n", ordinal, min_capacity
    printf "│    • generation.%d.maxCapacity  = %lu (constant)                   │\n", ordinal, max_capacity
    printf "│    • generation.%d.capacity     = %lu (variable, 可动态更新)             │\n", ordinal, curr_capacity
    printf "└──────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# 断点3: G1YoungGenerationCounters::update_all - 更新当前容量
break G1YoungGenerationCounters::update_all
commands
    printf "\n"
    printf "┌──────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│  G1YoungGenerationCounters::update_all() 更新当前容量                        │\n"
    printf "├──────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│  _g1mm->young_gen_committed() = %lu bytes = %.2f MB              │\n", this->_g1mm->_young_gen_committed, (double)this->_g1mm->_young_gen_committed/(1024*1024)
    printf "│  pad_capacity(上述, 3)        = %lu bytes                        │\n", this->_g1mm->_young_gen_committed + 8*3
    printf "│  → 将 _current_size 更新为此值                                               │\n"
    printf "└──────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

run
