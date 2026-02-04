# GDB 调试脚本：分析数据元空间（_space_list）的初始化
# 条件：-Xms8g -Xmx8g -XX:+UseG1GC

set breakpoint pending on
set pagination off

# 断点1：计算首个 Chunk 大小
break Metaspace::global_initialize
commands
    printf "\n========== Metaspace::global_initialize 入口 ==========\n"
    continue
end

# 断点2：在 _first_chunk_word_size 计算完成后
break metaspace.cpp:1426
commands
    printf "\n========== 计算 Chunk 大小完成 ==========\n"
    printf "InitialBootClassLoaderMetaspaceSize = %lu bytes (%lu KB)\n", InitialBootClassLoaderMetaspaceSize, InitialBootClassLoaderMetaspaceSize/1024
    printf "_first_chunk_word_size = %lu words (%lu KB)\n", Metaspace::_first_chunk_word_size, (Metaspace::_first_chunk_word_size*8)/1024
    printf "_first_class_chunk_word_size = %lu words (%lu KB)\n", Metaspace::_first_class_chunk_word_size, (Metaspace::_first_class_chunk_word_size*8)/1024
    continue
end

# 断点3：计算 word_size 后，创建 VirtualSpaceList 前
break metaspace.cpp:1432
commands
    printf "\n========== 创建数据元空间 VirtualSpaceList ==========\n"
    printf "word_size = %lu words (%lu MB)\n", word_size, (word_size * 8)/(1024*1024)
    continue
end

# 断点4：VirtualSpaceList(size_t) 构造函数
break metaspace::VirtualSpaceList::VirtualSpaceList(unsigned long)
commands
    printf "\n========== VirtualSpaceList(size_t) 构造函数入口 ==========\n"
    printf "word_size = %lu words\n", word_size
    printf "this = %p\n", this
    continue
end

# 断点5：create_new_virtual_space 内部
break metaspace::VirtualSpaceList::create_new_virtual_space
commands
    printf "\n========== create_new_virtual_space ==========\n"
    printf "vs_word_size = %lu words (%lu MB)\n", vs_word_size, (vs_word_size * 8)/(1024*1024)
    continue
end

# 断点6：VirtualSpaceNode(size_t) 构造函数 - 数据空间版本
break metaspace::VirtualSpaceNode::VirtualSpaceNode(bool, unsigned long)
commands
    printf "\n========== VirtualSpaceNode(bool, size_t) 构造函数 ==========\n"
    printf "is_class = %d\n", is_class
    printf "bytes = %lu (%lu MB)\n", bytes, bytes/(1024*1024)
    continue
end

# 断点7：VirtualSpaceNode::initialize 完成
break metaspace::VirtualSpaceNode::initialize
commands
    printf "\n========== VirtualSpaceNode::initialize ==========\n"
    continue
end

# 断点8：link_vs 完成
break metaspace::VirtualSpaceList::link_vs
commands
    printf "\n========== link_vs ==========\n"
    printf "new_entry = %p\n", new_entry
    continue
end

# 断点9：创建 ChunkManager
break metaspace.cpp:1433
commands
    printf "\n========== 创建 ChunkManager(false) ==========\n"
    printf "_space_list = %p\n", Metaspace::_space_list
    continue
end

# 断点10：ChunkManager 构造函数
break metaspace::ChunkManager::ChunkManager(bool)
commands
    printf "\n========== ChunkManager(bool) 构造函数 ==========\n"
    printf "is_class = %d\n", is_class
    continue
end

# 断点11：global_initialize 完成
break metaspace.cpp:1441
commands
    printf "\n========== global_initialize 完成 ==========\n"
    printf "\n=== 最终状态汇总 ===\n"
    printf "_first_chunk_word_size = %lu words (%lu KB)\n", Metaspace::_first_chunk_word_size, (Metaspace::_first_chunk_word_size*8)/1024
    printf "_first_class_chunk_word_size = %lu words (%lu KB)\n", Metaspace::_first_class_chunk_word_size, (Metaspace::_first_class_chunk_word_size*8)/1024
    printf "_space_list = %p\n", Metaspace::_space_list
    printf "_chunk_manager_metadata = %p\n", Metaspace::_chunk_manager_metadata
    printf "_tracer = %p\n", Metaspace::_tracer
    quit
end

run
