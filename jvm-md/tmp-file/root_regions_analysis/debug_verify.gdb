# 验证 _g1h->_survivor 与 survivor() 的地址关系
set pagination off
set print pretty on
set confirm off

# 在init调用后设置断点
break g1ConcurrentMark.cpp:441

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# 打印关键信息
printf "\n=========================================\n"
printf "验证 _root_regions.init() 调用后的状态\n"
printf "=========================================\n"

printf "\n=== 地址关系 ===\n"
printf "G1ConcurrentMark this: %p\n", this
printf "G1CollectedHeap _g1h: %p\n", _g1h
printf "&_root_regions: %p\n", &_root_regions
printf "\n"

printf "=== G1CollectedHeap::_survivor 成员 ===\n"
printf "&(_g1h->_survivor): %p\n", &(_g1h->_survivor)
printf "_g1h->survivor() 返回: %p\n", _g1h->survivor()
printf "两者相等? %d\n", &(_g1h->_survivor) == _g1h->survivor()
printf "\n"

printf "=== _root_regions 内部状态 ===\n"
printf "_root_regions._survivors: %p\n", _root_regions._survivors
printf "_root_regions._cm: %p\n", _root_regions._cm
printf "_root_regions._scan_in_progress: %d\n", _root_regions._scan_in_progress
printf "_root_regions._should_abort: %d\n", _root_regions._should_abort
printf "_root_regions._claimed_survivor_index: %d\n", _root_regions._claimed_survivor_index
printf "\n"

printf "=== 最终验证 ===\n"
printf "_root_regions._survivors == &(_g1h->_survivor)? %d\n", _root_regions._survivors == &(_g1h->_survivor)
printf "_root_regions._survivors == _g1h->survivor()? %d\n", _root_regions._survivors == _g1h->survivor()
printf "_root_regions._cm == this? %d\n", _root_regions._cm == this
printf "\n"

printf "=== G1SurvivorRegions 内部的 GrowableArray ===\n"
printf "_root_regions._survivors->_regions: %p\n", _root_regions._survivors->_regions
printf "  _len (当前survivor区域数): %d\n", _root_regions._survivors->_regions->_len
printf "  _max (最大容量): %d\n", _root_regions._survivors->_regions->_max
printf "  _data (数据指针): %p\n", _root_regions._survivors->_regions->_data
printf "\n"

printf "=== 堆内存范围 (_heap) ===\n"
printf "_heap._start: %p\n", _heap._start
printf "_heap._word_size: %lu (words) = %lu bytes = %lu GB\n", _heap._word_size, _heap._word_size * 8, (_heap._word_size * 8) / (1024*1024*1024)

quit
