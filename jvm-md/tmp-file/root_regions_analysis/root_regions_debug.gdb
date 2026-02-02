# GDB调试脚本：分析G1CMRootRegions的构造和init过程
# 断点位置：
# 1. G1CMRootRegions构造函数
# 2. G1CMRootRegions::init方法
# 3. G1SurvivorRegions的survivor()访问

set pagination off
set print pretty on
set confirm off

# 设置断点
# 断点1: G1CMRootRegions默认构造函数
break G1CMRootRegions::G1CMRootRegions
commands
  printf "\n========== G1CMRootRegions::G1CMRootRegions() 默认构造函数 ==========\n"
  printf "this地址: %p\n", this
  printf "构造后立即查看成员变量初始值:\n"
  printf "  _survivors = %p\n", _survivors
  printf "  _cm = %p\n", _cm
  printf "  _scan_in_progress = %d\n", _scan_in_progress
  printf "  _should_abort = %d\n", _should_abort
  printf "  _claimed_survivor_index = %d\n", _claimed_survivor_index
  continue
end

# 断点2: G1CMRootRegions::init方法
break G1CMRootRegions::init
commands
  printf "\n========== G1CMRootRegions::init() 被调用 ==========\n"
  printf "this地址: %p\n", this
  printf "传入参数:\n"
  printf "  survivors = %p\n", survivors
  printf "  cm = %p\n", cm
  printf "\n"
  printf "=== 查看survivors (G1SurvivorRegions) 对象的内容 ===\n"
  printf "survivors->_regions (GrowableArray指针): %p\n", survivors->_regions
  printf "survivors->_regions->_len (当前元素数量): %d\n", survivors->_regions->_len
  printf "survivors->_regions->_max (最大容量): %d\n", survivors->_regions->_max
  printf "survivors->_regions->_data (数据指针): %p\n", survivors->_regions->_data
  printf "\n"
  printf "=== 验证_g1h->survivor()返回的是G1CollectedHeap::_survivor成员 ===\n"
  continue
end

# 断点3: 在G1ConcurrentMark构造函数中，_root_regions.init调用前
break g1ConcurrentMark.cpp:440
commands
  printf "\n========== G1ConcurrentMark构造函数第440行: _root_regions.init调用前 ==========\n"
  printf "this (G1ConcurrentMark*): %p\n", this
  printf "_g1h (G1CollectedHeap*): %p\n", _g1h
  printf "&_root_regions: %p\n", &_root_regions
  printf "\n"
  printf "=== 查看_g1h->_survivor (G1SurvivorRegions成员) ===\n"
  printf "_g1h->_survivor地址: %p\n", &_g1h->_survivor
  printf "_g1h->survivor() 返回: %p\n", _g1h->survivor()
  printf "验证: &_g1h->_survivor == _g1h->survivor() ? %d\n", &_g1h->_survivor == _g1h->survivor()
  printf "\n"
  printf "=== G1SurvivorRegions详情 ===\n"
  printf "_g1h->_survivor._regions指针: %p\n", _g1h->_survivor._regions
  printf "_g1h->_survivor._regions->_len: %d\n", _g1h->_survivor._regions->_len
  printf "_g1h->_survivor._regions->_max: %d\n", _g1h->_survivor._regions->_max
  printf "\n"
  printf "=== _root_regions初始化前的状态 ===\n"
  printf "_root_regions._survivors: %p\n", _root_regions._survivors
  printf "_root_regions._cm: %p\n", _root_regions._cm
  printf "_root_regions._scan_in_progress: %d\n", _root_regions._scan_in_progress
  printf "_root_regions._should_abort: %d\n", _root_regions._should_abort
  printf "_root_regions._claimed_survivor_index: %d\n", _root_regions._claimed_survivor_index
  continue
end

# 断点4: 在init完成后
break g1ConcurrentMark.cpp:441
commands
  printf "\n========== G1ConcurrentMark构造函数第441行: _root_regions.init调用后 ==========\n"
  printf "=== _root_regions初始化后的状态 ===\n"
  printf "_root_regions._survivors: %p\n", _root_regions._survivors
  printf "_root_regions._cm: %p\n", _root_regions._cm
  printf "_root_regions._scan_in_progress: %d\n", _root_regions._scan_in_progress
  printf "_root_regions._should_abort: %d\n", _root_regions._should_abort
  printf "_root_regions._claimed_survivor_index: %d\n", _root_regions._claimed_survivor_index
  printf "\n"
  printf "=== 验证指针关系 ===\n"
  printf "_root_regions._survivors == _g1h->survivor() ? %d\n", _root_regions._survivors == _g1h->survivor()
  printf "_root_regions._cm == this ? %d\n", _root_regions._cm == this
  continue
end

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main
