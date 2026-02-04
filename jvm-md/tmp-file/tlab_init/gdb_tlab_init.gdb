# GDB 调试脚本 - TLAB 启动初始化分析
# 标准条件: -Xms8g -Xmx8g，G1 GC，Region 4MB

set print pretty on
set pagination off

# 断点1: startup_initialization 入口
break ThreadLocalAllocBuffer::startup_initialization
commands
    printf "\n========== TLAB startup_initialization() 开始 ==========\n"
    continue
end

# 断点2: initial_desired_size 函数
break ThreadLocalAllocBuffer::initial_desired_size
commands
    printf "\n========== initial_desired_size() 计算 ==========\n"
    printf "  TLABSize (用户设置) = %lu bytes\n", TLABSize
    continue
end

# 断点3: 计算完成处
break threadLocalAllocBuffer.cpp:324
commands
    printf "\n[TLAB 大小计算]\n"
    printf "  nof_threads (平均分配线程数) = %u\n", nof_threads
    printf "  target_refills() = %u\n", target_refills()
    printf "  tlab_capacity = %lu bytes\n", Universe::heap()->tlab_capacity(myThread())
    printf "\n  计算公式: init_sz = tlab_capacity / (nof_threads * target_refills)\n"
    printf "  init_sz (计算后) = %lu words = %lu bytes = %lu KB\n", init_sz, init_sz * 8, (init_sz * 8) / 1024
    continue
end

# 断点4: 返回前（应用了 min/max 限制后）
break threadLocalAllocBuffer.cpp:325
commands
    printf "\n[应用 min/max 限制后]\n"
    printf "  min_size() = %lu words = %lu KB\n", min_size(), (min_size() * 8) / 1024
    printf "  max_size() = %lu words = %lu KB = %lu MB\n", max_size(), (max_size() * 8) / 1024, (max_size() * 8) / 1024 / 1024
    printf "  最终 init_sz = %lu words = %lu KB\n", init_sz, (init_sz * 8) / 1024
    continue
end

# 断点5: 日志打印处
break threadLocalAllocBuffer.cpp:307
commands
    printf "\n========== TLAB 初始化完成 ==========\n"
    printf "  _target_refills = %u\n", _target_refills
    printf "  _reserve_for_allocation_prefetch = %d words\n", _reserve_for_allocation_prefetch
    printf "  _global_stats = %p\n", _global_stats
    printf "\n  min_size  = %lu words = %lu KB\n", min_size(), (min_size() * 8) / 1024
    printf "  max_size  = %lu words = %lu MB\n", max_size(), (max_size() * 8) / 1024 / 1024
    printf "  initial   = %lu words = %lu KB\n", Thread::current()->tlab()._desired_size, (Thread::current()->tlab()._desired_size * 8) / 1024
    continue
end

run

