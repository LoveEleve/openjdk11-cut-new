#!/bin/bash
# GDB 调试：SATBMarkQueueSet::initialize 初始化后的状态

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

# 在 satbMarkQueue.cpp:208 设断点 (initialize 的最后一行之后)
break satbMarkQueue.cpp:208
commands 1
    echo \n============================================================\n
    echo    SATBMarkQueueSet::initialize() 执行完毕后\n
    echo ============================================================\n
    
    printf "\n【1】PtrQueueSet (父类) 字段\n"
    printf "   _cbl_mon = %p\n", this->_cbl_mon
    printf "   _fl_lock = %p\n", this->_fl_lock
    printf "   _process_completed_threshold = %d\n", this->_process_completed_threshold
    printf "   _max_completed_queue = %d\n", this->_max_completed_queue
    printf "   _fl_owner = %p (应该等于 this)\n", this->_fl_owner
    printf "   _completed_buffers_head = %p\n", this->_completed_buffers_head
    printf "   _completed_buffers_tail = %p\n", this->_completed_buffers_tail
    printf "   _n_completed_buffers = %lu\n", this->_n_completed_buffers
    printf "   _buf_free_list = %p\n", this->_buf_free_list
    printf "   _buf_free_list_sz = %lu\n", this->_buf_free_list_sz
    printf "   _all_active = %d\n", this->_all_active
    printf "   _buffer_size = %lu\n", this->_buffer_size
    printf "   _completed_queue_padding = %lu\n", this->_completed_queue_padding
    
    printf "\n【2】_shared_satb_queue (SATBMarkQueue) 字段\n"
    printf "   地址 = %p\n", &(this->_shared_satb_queue)
    printf "   _qset = %p (应指向 this)\n", this->_shared_satb_queue._qset
    printf "   _active = %d\n", this->_shared_satb_queue._active
    printf "   _permanent = %d\n", this->_shared_satb_queue._permanent
    printf "   _index = %lu\n", this->_shared_satb_queue._index
    printf "   _capacity_in_bytes = %lu\n", this->_shared_satb_queue._capacity_in_bytes
    printf "   _lock = %p\n", this->_shared_satb_queue._lock
    printf "   _buf = %p\n", this->_shared_satb_queue._buf
    
    printf "\n【3】锁的名称\n"
    printf "   _cbl_mon 名称: %s\n", this->_cbl_mon->name()
    printf "   _fl_lock 名称: %s\n", this->_fl_lock->name()
    printf "   _shared_satb_queue._lock 名称: %s\n", this->_shared_satb_queue._lock->name()
    
    echo \n============================================================\n
    continue
end

continue
quit
GDBEOF
