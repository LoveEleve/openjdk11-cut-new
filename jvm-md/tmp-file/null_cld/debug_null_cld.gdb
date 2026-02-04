# GDB 调试脚本：分析 ClassLoaderData::init_null_class_loader_data()
# 条件：-Xms8g -Xmx8g -XX:+UseG1GC

set pagination off
set breakpoint pending on

# 断点1：init_null_class_loader_data 入口
break ClassLoaderData::init_null_class_loader_data
commands
    printf "\n"
    printf "╔══════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║      ClassLoaderData::init_null_class_loader_data() 入口                     ║\n"
    printf "╚══════════════════════════════════════════════════════════════════════════════╝\n"
    printf "_the_null_class_loader_data (before) = %p\n", ClassLoaderData::_the_null_class_loader_data
    printf "ClassLoaderDataGraph::_head (before) = %p\n", ClassLoaderDataGraph::_head
    continue
end

# 断点2：ClassLoaderData 构造函数
break ClassLoaderData::ClassLoaderData(Handle, bool)
commands
    printf "\n"
    printf "┌────────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│              ClassLoaderData 构造函数                                          │\n"
    printf "├────────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│ 参数：                                                                         │\n"
    printf "│   this = %p\n", this
    printf "│   h_class_loader.is_null() = %d\n", h_class_loader._handle == 0
    printf "│   is_anonymous = %d\n", is_anonymous
    printf "└────────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# 断点3：创建 Metaspace 锁
break Mutex::Mutex
commands
    # 只打印 Metaspace 锁的创建
    continue
end

# 断点4：创建 PackageEntryTable
break PackageEntryTable::PackageEntryTable
commands
    printf "\n>>> 创建 PackageEntryTable: size = %d\n", table_size
    continue
end

# 断点5：创建 boot unnamed module
break ModuleEntry::create_boot_unnamed_module
commands
    printf "\n>>> 创建 boot loader 的 unnamed module\n"
    printf "    loader_data = %p\n", loader_data
    continue
end

# 断点6：创建 Dictionary
break ClassLoaderData::create_dictionary
commands
    printf "\n>>> 创建 Dictionary (类字典)\n"
    continue
end

# 断点7：init_null_class_loader_data 完成后
break classLoaderData.cpp:96
commands
    printf "\n"
    printf "╔══════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║      ClassLoaderData::init_null_class_loader_data() 完成                     ║\n"
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║ 结果验证：                                                                   ║\n"
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║ _the_null_class_loader_data = %p\n", ClassLoaderData::_the_null_class_loader_data
    printf "║ ClassLoaderDataGraph::_head = %p\n", ClassLoaderDataGraph::_head
    printf "╚══════════════════════════════════════════════════════════════════════════════╝\n"
    printf "\n=== ClassLoaderData 对象详情 ===\n"
    print *ClassLoaderData::_the_null_class_loader_data
    quit
end

run
