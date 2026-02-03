# GDB 调试脚本 - G1CollectionSet::initialize() 分析
# 用于验证 _collection_set.initialize(max_regions()) 的初始化过程
# 标准条件: -Xms8g -Xmx8g，非大页，非NUMA，G1 GC，Region 4MB

# 设置断点前先设置一些方便的显示选项
set print pretty on
set pagination off

# 断点1: G1CollectionSet 构造函数 (先于 initialize 调用)
break G1CollectionSet::G1CollectionSet
commands
    printf "\n========== G1CollectionSet 构造函数 ==========\n"
    printf "[参数] g1h = %p\n", g1h
    printf "[参数] policy = %p\n", policy
    printf "[初始化] _cset_chooser 将创建 CollectionSetChooser\n"
    continue
end

# 断点2: initialize() 方法入口
break G1CollectionSet::initialize
commands
    printf "\n========== G1CollectionSet::initialize() ==========\n"
    printf "[参数] max_region_length = %u\n", max_region_length
    printf "\n[计算说明]\n"
    printf "  堆大小 = 8GB = 8 * 1024 MB = 8192 MB\n"
    printf "  Region大小 = 4MB\n"
    printf "  max_regions = 8192 / 4 = 2048 个Region\n"
    printf "\n[成员变量 - 初始化前]\n"
    printf "  _collection_set_regions = %p (应为NULL)\n", this->_collection_set_regions
    printf "  _collection_set_max_length = %lu\n", this->_collection_set_max_length
    printf "  _collection_set_cur_length = %lu\n", this->_collection_set_cur_length
    continue
end

# 断点3: NEW_C_HEAP_ARRAY 后
break g1CollectionSet.cpp:98
commands
    printf "\n========== 数组分配完成 ==========\n"
    printf "[结果]\n"
    printf "  _collection_set_max_length = %lu\n", _collection_set_max_length
    printf "  _collection_set_regions = %p\n", _collection_set_regions
    printf "\n[内存分配详情]\n"
    printf "  元素类型: uint (4字节)\n"
    printf "  元素数量: %lu\n", _collection_set_max_length
    printf "  总大小: %lu 字节 = %lu KB\n", _collection_set_max_length * 4, (_collection_set_max_length * 4) / 1024
    continue
end

# 断点4: 验证 max_regions() 的值
break g1CollectedHeap.cpp:2363
commands
    printf "\n========== 调用 _collection_set.initialize() ==========\n"
    printf "[调用位置] g1CollectedHeap.cpp:2363\n"
    printf "[参数] max_regions() = %u\n", max_regions()
    printf "[验证] _hrm.max_length() = %u\n", _hrm._regions._len
    continue
end

# 运行
run

