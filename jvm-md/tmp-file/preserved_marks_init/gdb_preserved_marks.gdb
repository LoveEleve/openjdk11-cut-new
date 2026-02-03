# GDB 调试脚本 - PreservedMarksSet::init() 分析
# 用于验证 _preserved_marks_set.init(ParallelGCThreads) 的初始化过程
# 标准条件: -Xms8g -Xmx8g，非大页，非NUMA，G1 GC，Region 4MB

# 断点1: init() 方法入口
break PreservedMarksSet::init
commands
    printf "\n========== PreservedMarksSet::init() ==========\n"
    printf "[参数] num = %u (ParallelGCThreads)\n", num
    printf "[成员] _in_c_heap = %d\n", _in_c_heap
    printf "[成员] _stacks (before) = %p\n", _stacks
    printf "[成员] _num (before) = %u\n", _num
    continue
end

# 断点2: 数组分配后 (在 for 循环之前)
break preservedMarks.cpp:86
commands
    printf "\n[内存分配完成]\n"
    printf "[成员] _stacks (allocated) = %p\n", _stacks
    printf "[即将创建 %u 个 PreservedMarks 对象]\n", num
    continue
end

# 断点3: PreservedMarks 构造函数
break PreservedMarks::PreservedMarks
commands
    printf "\n[PreservedMarks 构造] this = %p\n", this
    continue
end

# 断点4: init() 完成
break preservedMarks.cpp:91
commands
    printf "\n========== init() 完成 ==========\n"
    printf "[结果] _num = %u\n", _num
    printf "[结果] _stacks = %p\n", _stacks
    printf "\n[验证各个 PreservedMarks 对象]\n"
    set $i = 0
    while $i < _num
        set $pm = _stacks + $i
        printf "  _stacks[%u]: this=%p, stack.size=%lu\n", $i, $pm, ((PreservedMarks*)$pm)->_stack._full_seg_size + ((PreservedMarks*)$pm)->_stack._cur_seg_size
        set $i = $i + 1
    end
    continue
end

# 运行程序
run

