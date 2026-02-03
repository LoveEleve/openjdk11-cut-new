#!/bin/bash
# GDB 调试：G1ConcurrentRefine 构造函数和 initialize

cd /data/workspace/openjdk-cut-new

gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'GDBEOF'
set pagination off
set confirm off
set breakpoint pending on
set stop-on-solib-events 1

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

continue
continue
continue
continue
continue

set stop-on-solib-events 0

# 断点1: 构造函数入口
break G1ConcurrentRefine::G1ConcurrentRefine
commands 1
    echo \n============================================================\n
    echo    【1】G1ConcurrentRefine 构造函数\n
    echo ============================================================\n
    
    printf "\n传入参数:\n"
    printf "   green_zone = %lu\n", green_zone
    printf "   yellow_zone = %lu\n", yellow_zone
    printf "   red_zone = %lu\n", red_zone
    printf "   min_yellow_zone_size = %lu\n", min_yellow_zone_size
    
    printf "\nthis 指针 = %p\n", this
    continue
end

# 断点2: 构造函数结束后
break g1ConcurrentRefine.cpp:229
commands 2
    echo \n--- 构造函数执行完毕 ---\n
    printf "this->_green_zone = %lu\n", this->_green_zone
    printf "this->_yellow_zone = %lu\n", this->_yellow_zone
    printf "this->_red_zone = %lu\n", this->_red_zone
    printf "this->_min_yellow_zone_size = %lu\n", this->_min_yellow_zone_size
    continue
end

# 断点3: initialize 入口
break G1ConcurrentRefine::initialize
commands 3
    echo \n============================================================\n
    echo    【2】G1ConcurrentRefine::initialize()\n
    echo ============================================================\n
    
    printf "this = %p\n", this
    printf "max_num_threads() = %u\n", max_num_threads()
    continue
end

# 断点4: _thread_control.initialize 入口
break G1ConcurrentRefineThreadControl::initialize
commands 4
    echo \n============================================================\n
    echo    【3】_thread_control.initialize()\n
    echo ============================================================\n
    
    printf "cr = %p\n", cr
    printf "num_max_threads = %u\n", num_max_threads
    continue
end

# 断点5: create_refinement_thread
break G1ConcurrentRefineThreadControl::create_refinement_thread
commands 5
    printf "创建精炼线程: worker_id = %u\n", worker_id
    continue
end

# 断点6: initialize 完成
break g1ConcurrentRefine.cpp:91
commands 6
    echo \n============================================================\n
    echo    【4】线程创建完毕\n
    echo ============================================================\n
    
    printf "_num_max_threads = %u\n", this->_num_max_threads
    printf "_threads 数组地址 = %p\n", this->_threads
    printf "_threads[0] = %p\n", this->_threads[0]
    
    continue
end

continue
quit
GDBEOF
