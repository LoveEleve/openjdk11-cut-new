# 详细版GDB调试脚本 - 深入分析G1CMRootRegions
set pagination off
set print pretty on
set confirm off

# 在G1CMRootRegions::G1CMRootRegions构造函数设置断点
break G1CMRootRegions::G1CMRootRegions

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# 到达构造函数断点
printf "\n=========================================\n"
printf "断点1: G1CMRootRegions::G1CMRootRegions() 构造函数\n"
printf "=========================================\n"
printf "this (G1CMRootRegions*): %p\n", this
finish
printf "\n构造函数执行后，对象状态:\n"
print *this

# 继续到init调用
break G1CMRootRegions::init
continue

printf "\n=========================================\n"
printf "断点2: G1CMRootRegions::init() 方法入口\n"
printf "=========================================\n"
printf "this (G1CMRootRegions*): %p\n", this
printf "\n传入参数:\n"
printf "  survivors (G1SurvivorRegions*): %p\n", survivors
printf "  cm (G1ConcurrentMark*): %p\n", cm
printf "\n当前this对象状态 (init执行前):\n"
print *this
printf "\nsurvivors对象详情:\n"
print *survivors
printf "\nsurvivors->_regions (GrowableArray) 详情:\n"
print *(survivors->_regions)
printf "\n  _len (当前Survivor Region数量): %d\n", survivors->_regions->_len
printf "  _max (数组最大容量): %d\n", survivors->_regions->_max
printf "  _data (HeapRegion*数组基地址): %p\n", survivors->_regions->_data

# 执行init函数
finish
printf "\n=========================================\n"
printf "G1CMRootRegions::init() 执行完成后\n"
printf "=========================================\n"
printf "this对象状态:\n"
print *this
printf "\n验证指针:\n"
printf "  _survivors指向survivors参数: %d\n", _survivors == survivors
printf "  _cm指向cm参数: %d\n", _cm == cm

# 继续断点到G1ConcurrentMark构造函数验证整体情况
delete breakpoints
break g1ConcurrentMark.cpp:442
continue

printf "\n=========================================\n"
printf "断点3: G1ConcurrentMark构造函数 init后\n"
printf "=========================================\n"
printf "G1ConcurrentMark this: %p\n", this
printf "G1CollectedHeap _g1h: %p\n", _g1h
printf "\n_g1h->_survivor成员地址: %p\n", &(_g1h->_survivor)
printf "_g1h->survivor()返回值: %p\n", _g1h->survivor()
printf "\n验证: &(_g1h->_survivor) == _g1h->survivor() ? %d\n", &(_g1h->_survivor) == _g1h->survivor()
printf "\n_root_regions完整状态:\n"
print _root_regions
printf "\n_root_regions._survivors->_regions详情:\n"
print *(_root_regions._survivors->_regions)
printf "\n验证最终关系:\n"
printf "  _root_regions._survivors == &(_g1h->_survivor): %d\n", _root_regions._survivors == &(_g1h->_survivor)
printf "  _root_regions._cm == this: %d\n", _root_regions._cm == this

quit
