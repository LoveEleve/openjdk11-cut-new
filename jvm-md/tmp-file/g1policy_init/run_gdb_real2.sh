#!/bin/bash
# GDB 调试：获取 init() 内部的真实数据

cd /data/workspace/openjdk-cut-new

gdb -q ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'GDBEOF'
set pagination off
set confirm off
set breakpoint pending on
set stop-on-solib-events 1

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# 等待 libjvm.so 加载
continue
continue
continue
continue
continue

set stop-on-solib-events 0

# 在 G1Policy::init 入口设断点
break G1Policy::init
commands 1
    silent
    # 直接在这里 finish 执行完整个函数
end

continue

# 现在停在 init 入口，执行 finish 等函数执行完毕
echo \n=== 执行 finish 等待 init() 完成 ===\n
finish

# 此时 init() 已执行完毕，this 指针仍有效
echo \n============================================================\n
echo    G1Policy::init() 执行完毕后的【真实数据】\n
echo ============================================================\n

echo \n【1】年轻代目标长度\n
print this->_young_list_target_length
print this->_young_list_max_length
print this->_young_list_fixed_length

echo \n【2】G1YoungGenSizer\n
print this->_young_gen_sizer._sizer_kind
print this->_young_gen_sizer._adaptive_size
print this->_young_gen_sizer._min_desired_young_length
print this->_young_gen_sizer._max_desired_young_length

echo \n【3】空闲Region\n
print this->_free_regions_at_end_of_collection

echo \n【4】预留空间\n
print this->_reserve_factor
print this->_reserve_regions

echo \n【5】收集集合状态\n
print this->_collection_set->_inc_build_state
print this->_collection_set->_inc_bytes_used_before

echo \n============================================================\n

continue
quit
GDBEOF
