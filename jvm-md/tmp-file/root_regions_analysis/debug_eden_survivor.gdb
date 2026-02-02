# 分析 G1EdenRegions 和 G1SurvivorRegions 结构
set pagination off
set print pretty on
set confirm off

# 在 G1ConcurrentMark 构造函数设置断点，此时堆已经初始化完成
break g1ConcurrentMark.cpp:440

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

printf "\n=========================================\n"
printf "G1CollectedHeap 中的 _eden 和 _survivor 分析\n"
printf "=========================================\n"

printf "\n=== G1CollectedHeap 地址 ===\n"
printf "_g1h: %p\n", _g1h

printf "\n=== G1EdenRegions _eden ===\n"
printf "&(_g1h->_eden): %p\n", &(_g1h->_eden)
print _g1h->_eden
printf "  _length: %d\n", _g1h->_eden._length
printf "  sizeof(G1EdenRegions): %lu bytes\n", sizeof(_g1h->_eden)

printf "\n=== G1SurvivorRegions _survivor ===\n"
printf "&(_g1h->_survivor): %p\n", &(_g1h->_survivor)
print _g1h->_survivor
printf "  _regions指针: %p\n", _g1h->_survivor._regions
print *(_g1h->_survivor._regions)
printf "  当前survivor数量: %d\n", _g1h->_survivor._regions->_len
printf "  数组最大容量: %d\n", _g1h->_survivor._regions->_max
printf "  sizeof(G1SurvivorRegions): %lu bytes\n", sizeof(_g1h->_survivor)

printf "\n=== 年轻代区域统计方法 ===\n"
printf "eden_regions_count(): %u\n", _g1h->_eden._length
printf "survivor_regions_count(): %u\n", _g1h->_survivor._regions->_len
printf "young_regions_count() (eden+survivor): %u\n", _g1h->_eden._length + _g1h->_survivor._regions->_len

printf "\n=== 相关结构的内存布局 ===\n"
printf "G1CollectedHeap基址: %p\n", _g1h
printf "_eden偏移量: 0x%lx\n", (unsigned long)&(_g1h->_eden) - (unsigned long)_g1h
printf "_survivor偏移量: 0x%lx\n", (unsigned long)&(_g1h->_survivor) - (unsigned long)_g1h

quit
