# GDB 调试脚本：分析 Metaspace 性能计数器初始化
# 条件：-Xms8g -Xmx8g -XX:+UseG1GC

set pagination off
set breakpoint pending on

# 断点1：MetaspaceCounters::initialize_performance_counters
break MetaspaceCounters::initialize_performance_counters
commands
    printf "\n"
    printf "╔══════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║       MetaspaceCounters::initialize_performance_counters()                   ║\n"
    printf "╚══════════════════════════════════════════════════════════════════════════════╝\n"
    printf "UsePerfData = %d\n", UsePerfData
    continue
end

# 断点2：MetaspacePerfCounters 构造函数（metaspace）
break MetaspacePerfCounters::MetaspacePerfCounters
commands
    printf "\n"
    printf "┌────────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│              MetaspacePerfCounters 构造函数                                    │\n"
    printf "├────────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│ 参数值：                                                                       │\n"
    printf "│   ns (命名空间) = %s\n", ns
    printf "│   min_capacity = %lu bytes\n", min_capacity
    printf "│   curr_capacity = %lu bytes (%lu MB)\n", curr_capacity, curr_capacity/(1024*1024)
    printf "│   max_capacity = %lu bytes (%lu MB)\n", max_capacity, max_capacity/(1024*1024)
    printf "│   used = %lu bytes (%lu KB)\n", used, used/1024
    printf "└────────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# 断点3：CompressedClassSpaceCounters::initialize_performance_counters
break CompressedClassSpaceCounters::initialize_performance_counters
commands
    printf "\n"
    printf "╔══════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║    CompressedClassSpaceCounters::initialize_performance_counters()           ║\n"
    printf "╚══════════════════════════════════════════════════════════════════════════════╝\n"
    printf "UsePerfData = %d\n", UsePerfData
    printf "UseCompressedClassPointers = %d\n", UseCompressedClassPointers
    continue
end

# 断点4：create_constant
break MetaspacePerfCounters::create_constant
commands
    printf "  create_constant: ns=%s, name=%s, value=%lu\n", ns, name, value
    continue
end

# 断点5：create_variable
break MetaspacePerfCounters::create_variable
commands
    printf "  create_variable: ns=%s, name=%s, value=%lu\n", ns, name, value
    continue
end

# 断点6：初始化完成后，查看最终状态
break universe.cpp:750
commands
    printf "\n"
    printf "╔══════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║                       性能计数器初始化完成                                   ║\n"
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║ MetaspaceCounters::_perf_counters = %p\n", MetaspaceCounters::_perf_counters
    printf "║ CompressedClassSpaceCounters::_perf_counters = %p\n", CompressedClassSpaceCounters::_perf_counters
    printf "╚══════════════════════════════════════════════════════════════════════════════╝\n"
    quit
end

run
