#!/bin/bash
# GDB 调试：initialize_concurrent_refinement 方法

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

# 在 G1ConcurrentRefine::create 设断点
break G1ConcurrentRefine::create
commands 1
    echo \n============================================================\n
    echo    G1ConcurrentRefine::create() 入口\n
    echo ============================================================\n
    continue
end

# 在构造函数后设断点
break g1ConcurrentRefine.cpp:294
commands 2
    echo \n============================================================\n
    echo    G1ConcurrentRefine 构造完成\n
    echo ============================================================\n
    
    printf "\n【1】三色区域 (Zone) - 控制并发精炼线程\n"
    printf "   green_zone  = %lu (绿区: 缓冲区数量低于此值时，精炼线程休眠)\n", green_zone
    printf "   yellow_zone = %lu (黄区: 开始唤醒精炼线程)\n", yellow_zone
    printf "   red_zone    = %lu (红区: 应用线程也要帮忙处理)\n", red_zone
    printf "   min_yellow_zone_size = %lu\n", min_yellow_zone_size
    
    printf "\n【2】G1ConcurrentRefine 对象\n"
    printf "   cr 地址 = %p\n", cr
    printf "   cr->_green_zone = %lu\n", cr->_green_zone
    printf "   cr->_yellow_zone = %lu\n", cr->_yellow_zone
    printf "   cr->_red_zone = %lu\n", cr->_red_zone
    
    continue
end

# 在 initialize 完成后
break g1ConcurrentRefine.cpp:302
commands 3
    echo \n============================================================\n
    echo    G1ConcurrentRefine::initialize() 完成\n
    echo ============================================================\n
    
    printf "\n【3】并发精炼线程数量\n"
    printf "   G1ConcRefinementThreads = %u\n", G1ConcRefinementThreads
    
    printf "\n【4】返回的 ecode = %d (0=JNI_OK)\n", *ecode
    
    continue
end

continue
quit
GDBEOF
