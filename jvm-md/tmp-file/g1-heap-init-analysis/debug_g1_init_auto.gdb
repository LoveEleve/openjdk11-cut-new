# G1 堆初始化自动调试脚本
set pagination off
set print pretty on
set print object on

# 设置断点
break G1CollectedHeap::initialize
break G1CollectedHeap::G1CollectedHeap

# 运行程序
run -XX:+UseG1GC -Xms8g -Xmx8g SimpleTest

# 当到达G1CollectedHeap构造函数时
commands 1
  printf "\n=== G1CollectedHeap构造函数调用 ===\n"
  printf "this指针: %p\n", this
  printf "开始构造G1CollectedHeap对象...\n"
  continue
end

# 当到达initialize方法时
commands 2
  printf "\n=== G1CollectedHeap::initialize() 开始 ===\n"
  printf "this指针: %p\n", this
  
  # 打印关键参数
  printf "初始化参数检查:\n"
  printf "- 最大堆大小: %lu bytes (%.2f GB)\n", MaxHeapSize, MaxHeapSize/1024.0/1024.0/1024.0
  printf "- 初始堆大小: %lu bytes (%.2f GB)\n", InitialHeapSize, InitialHeapSize/1024.0/1024.0/1024.0
  
  # 继续执行并在关键点停止
  step 10
  printf "\n--- 步骤1: 调用父类CollectedHeap::initialize() ---\n"
  
  step 20
  printf "\n--- 步骤2: 创建HeapRegionManager ---\n"
  if _hrm
    printf "HeapRegionManager创建成功: %p\n", _hrm
  else
    printf "HeapRegionManager尚未创建\n"
  end
  
  step 30
  printf "\n--- 步骤3: 初始化G1Policy ---\n"
  if _g1_policy
    printf "G1Policy创建成功: %p\n", _g1_policy
  else
    printf "G1Policy尚未创建\n"
  end
  
  continue
end

# 设置输出重定向
set logging file /data/workspace/openjdk-cut-new/jvm-md/tmp-file/g1-heap-init-analysis/debug_output.txt
set logging on

printf "开始G1堆初始化调试...\n"