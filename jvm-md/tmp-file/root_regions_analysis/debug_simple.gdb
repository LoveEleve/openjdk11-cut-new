# 简化版GDB调试脚本
set pagination off
set print pretty on
set confirm off

# 在G1ConcurrentMark构造函数的_root_regions.init行设置断点
break g1ConcurrentMark.cpp:440

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# 到达断点后打印信息
printf "\n===== 到达断点: _root_regions.init调用前 =====\n"
print this
print _g1h
printf "\n===== _root_regions 结构 (init前) =====\n"
print _root_regions
printf "\n===== G1SurvivorRegions (_g1h->_survivor) =====\n"
print _g1h->_survivor
print _g1h->_survivor._regions
print *(_g1h->_survivor._regions)
printf "\n===== _g1h->survivor() 验证 =====\n"
print _g1h->survivor()
print &(_g1h->_survivor)
printf "\n"

# 单步执行init调用
next

printf "\n===== _root_regions.init() 调用后 =====\n"
print _root_regions
printf "\n===== 验证指针设置 =====\n"
print _root_regions._survivors
print _root_regions._cm
print _root_regions._survivors == _g1h->survivor()
print _root_regions._cm == this

quit
