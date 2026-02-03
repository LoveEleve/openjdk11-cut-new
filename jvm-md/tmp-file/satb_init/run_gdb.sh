#!/bin/bash
# GDB 调试：SATBMarkQueueSet::initialize 方法

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

# 断点1: SATBMarkQueueSet::initialize 入口
break SATBMarkQueueSet::initialize
commands 1
    echo \n============================================================\n
    echo    SATBMarkQueueSet::initialize() 入口\n
    echo ============================================================\n
    
    printf "\n【1】传入参数\n"
    printf "   this (SATBMarkQueueSet*) = %p\n", this
    printf "   cbl_mon (Monitor*)       = %p\n", cbl_mon
    printf "   fl_lock (Mutex*)         = %p\n", fl_lock
    printf "   process_completed_threshold = %d\n", process_completed_threshold
    printf "   lock (Mutex*)            = %p\n", lock
    
    printf "\n【2】初始化前的状态\n"
    printf "   _cbl_mon = %p\n", this->_cbl_mon
    printf "   _fl_lock = %p\n", this->_fl_lock
    printf "   _completed_buffers_head = %p\n", this->_completed_buffers_head
    printf "   _completed_buffers_tail = %p\n", this->_completed_buffers_tail
    printf "   _n_completed_buffers = %lu\n", this->_n_completed_buffers
    printf "   _process_completed_threshold = %d\n", this->_process_completed_threshold
    printf "   _buf_free_list = %p\n", this->_buf_free_list
    printf "   _buf_free_list_sz = %lu\n", this->_buf_free_list_sz
    printf "   _all_active = %d\n", this->_all_active
    printf "   _buffer_size = %lu\n", this->_buffer_size
    
    printf "\n【3】_shared_satb_queue 状态\n"
    printf "   _shared_satb_queue 地址 = %p\n", &(this->_shared_satb_queue)
    printf "   _shared_satb_queue._active = %d\n", this->_shared_satb_queue._active
    printf "   _shared_satb_queue._index = %lu\n", this->_shared_satb_queue._index
    
    continue
end

# 断点2: PtrQueueSet::initialize (被调用的父类方法)
break PtrQueueSet::initialize
commands 2
    echo \n\n============================================================\n
    echo    PtrQueueSet::initialize() 入口\n
    echo ============================================================\n
    
    printf "   this = %p\n", this
    printf "   cbl_mon = %p\n", cbl_mon
    printf "   fl_lock = %p\n", fl_lock
    printf "   process_completed_threshold = %d\n", process_completed_threshold
    printf "   max_completed_queue = %d\n", max_completed_queue
    printf "   fl_owner = %p\n", fl_owner
    
    continue
end

# 断点3: 在 set_lock 调用处 - 但我们用 finish 代替
# 在 SATBMarkQueueSet::initialize 结束后查看状态

continue

# 继续执行，让程序跑起来
continue
quit
GDBEOF
