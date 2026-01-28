# 详细的G1堆初始化调试脚本
set pagination off
set print pretty on
set print object on
set logging file /data/workspace/openjdk-cut-new/jvm-md/tmp-file/g1-heap-init-analysis/detailed_debug_output.txt
set logging overwrite on
set logging enabled on

# 设置断点
break G1CollectedHeap::G1CollectedHeap
break G1CollectedHeap::initialize
break HeapRegionManager::HeapRegionManager
break G1Policy::G1Policy

# 运行程序
run -XX:+UseG1GC -Xms8g -Xmx8g SimpleTest

# G1CollectedHeap构造函数
commands 1
  printf "\n========== G1CollectedHeap构造函数 ==========\n"
  printf "时间戳: %s", ctime(&time)
  printf "this指针: %p\n", this
  printf "collector_policy指针: %p\n", collector_policy
  
  # 检查一些关键的初始化值
  printf "\n--- 构造函数中的关键初始化 ---\n"
  printf "_young_list: %p\n", &_young_list
  printf "_survivor_plab_stats: %p\n", &_survivor_plab_stats
  printf "_old_plab_stats: %p\n", &_old_plab_stats
  
  continue
end

# G1CollectedHeap::initialize方法
commands 2
  printf "\n========== G1CollectedHeap::initialize() ==========\n"
  printf "this指针: %p\n", this
  
  # 获取堆大小信息
  printf "\n--- 堆大小配置 ---\n"
  printf "MaxHeapSize: %lu bytes (%.2f GB)\n", MaxHeapSize, MaxHeapSize/1024.0/1024.0/1024.0
  printf "InitialHeapSize: %lu bytes (%.2f GB)\n", InitialHeapSize, InitialHeapSize/1024.0/1024.0/1024.0
  
  # 单步执行关键部分
  printf "\n--- 开始单步调试initialize方法 ---\n"
  step
  printf "第1步完成\n"
  
  step
  printf "第2步完成\n"
  
  step
  printf "第3步完成 - 检查_hrm状态\n"
  if _hrm
    printf "HeapRegionManager已创建: %p\n", _hrm
  else
    printf "HeapRegionManager尚未创建\n"
  end
  
  continue
end

# HeapRegionManager构造函数
commands 3
  printf "\n========== HeapRegionManager构造函数 ==========\n"
  printf "this指针: %p\n", this
  continue
end

# G1Policy构造函数  
commands 4
  printf "\n========== G1Policy构造函数 ==========\n"
  printf "this指针: %p\n", this
  continue
end

printf "开始详细G1堆初始化调试...\n"