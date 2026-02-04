# GDB 调试脚本：分析数据元空间（_space_list）的初始化
# 条件：-Xms8g -Xmx8g -XX:+UseG1GC

set breakpoint pending on
set pagination off

# 在 global_initialize 入口
break Metaspace::global_initialize
commands
    printf "\n\n"
    printf "╔══════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║              Metaspace::global_initialize() 开始执行                         ║\n"
    printf "╚══════════════════════════════════════════════════════════════════════════════╝\n"
    continue
end

# 在 _first_chunk_word_size 计算完成后（第1426行是 word_size 计算前）
break metaspace.cpp:1428
commands
    printf "\n"
    printf "┌────────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│                     第1步：计算首个 Chunk 大小                                 │\n"
    printf "├────────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│ 源码逻辑：                                                                     │\n"
    printf "│   _first_chunk_word_size = InitialBootClassLoaderMetaspaceSize / BytesPerWord │\n"
    printf "│   _first_chunk_word_size = align_word_size_up(_first_chunk_word_size)         │\n"
    printf "├────────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│ GDB 验证值：                                                                   │\n"
    printf "│   InitialBootClassLoaderMetaspaceSize = %lu bytes = %lu KB                    │\n", InitialBootClassLoaderMetaspaceSize, InitialBootClassLoaderMetaspaceSize/1024
    printf "│   BytesPerWord = %lu                                                          │\n", BytesPerWord
    printf "│   _first_chunk_word_size = %lu words = %lu KB                                 │\n", Metaspace::_first_chunk_word_size, (Metaspace::_first_chunk_word_size*8)/1024
    printf "│   _first_class_chunk_word_size = %lu words = %lu KB                           │\n", Metaspace::_first_class_chunk_word_size, (Metaspace::_first_class_chunk_word_size*8)/1024
    printf "└────────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# 创建 VirtualSpaceList 前
break metaspace.cpp:1432
commands
    printf "\n"
    printf "┌────────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│                   第2步：计算初始虚拟空间大小                                  │\n"
    printf "├────────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│ 源码逻辑：                                                                     │\n"
    printf "│   word_size = VIRTUALSPACEMULTIPLIER * _first_chunk_word_size                 │\n"
    printf "│   word_size = align_up(word_size, reserve_alignment_words())                  │\n"
    printf "├────────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│ GDB 验证值：                                                                   │\n"
    printf "│   VIRTUALSPACEMULTIPLIER = 2                                                  │\n"
    printf "│   word_size = %lu words = %lu MB                                              │\n", word_size, (word_size*8)/(1024*1024)
    printf "│   reserve_alignment_words = %lu words = %lu KB                                │\n", Metaspace::reserve_alignment_words(), (Metaspace::reserve_alignment_words()*8)/1024
    printf "└────────────────────────────────────────────────────────────────────────────────┘\n"
    printf "\n>>> 即将执行: _space_list = new VirtualSpaceList(word_size)\n"
    continue
end

# VirtualSpaceList(size_t) 构造函数 - 只处理数据空间
break metaspace::VirtualSpaceList::VirtualSpaceList(unsigned long)
commands
    printf "\n"
    printf "┌────────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│             第3步：VirtualSpaceList(size_t) 构造函数                           │\n"
    printf "├────────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│ GDB 验证值：                                                                   │\n"
    printf "│   this = %p                                                                   │\n", this
    printf "│   word_size = %lu words = %lu MB                                              │\n", word_size, (word_size*8)/(1024*1024)
    printf "│                                                                               │\n"
    printf "│ 成员变量初始化：                                                              │\n"
    printf "│   _is_class = false (这是数据空间)                                            │\n"
    printf "│   _virtual_space_list = NULL                                                  │\n"
    printf "│   _current_virtual_space = NULL                                               │\n"
    printf "│   _reserved_words = 0                                                         │\n"
    printf "│   _committed_words = 0                                                        │\n"
    printf "│   _virtual_space_count = 0                                                    │\n"
    printf "└────────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# VirtualSpaceNode(bool, size_t) 构造函数 - 数据空间专用（is_class=false）
break metaspace::VirtualSpaceNode::VirtualSpaceNode(bool, unsigned long)
commands
    if is_class == 0
        printf "\n"
        printf "┌────────────────────────────────────────────────────────────────────────────────┐\n"
        printf "│              第4步：VirtualSpaceNode(bool, size_t) 构造函数                    │\n"
        printf "├────────────────────────────────────────────────────────────────────────────────┤\n"
        printf "│ GDB 验证值：                                                                   │\n"
        printf "│   this = %p                                                                   │\n", this
        printf "│   is_class = %d (数据空间)                                                    │\n", is_class
        printf "│   bytes = %lu = %lu MB                                                        │\n", bytes, bytes/(1024*1024)
        printf "│                                                                               │\n"
        printf "│ 关键操作：创建 ReservedSpace                                                  │\n"
        printf "│   _rs = ReservedSpace(bytes, reserve_alignment, large_pages)                  │\n"
        printf "└────────────────────────────────────────────────────────────────────────────────┘\n"
    end
    continue
end

# VirtualSpaceNode::initialize - 仅当是数据空间时打印
break metaspace::VirtualSpaceNode::initialize
commands
    if _is_class == 0
        printf "\n"
        printf "┌────────────────────────────────────────────────────────────────────────────────┐\n"
        printf "│              第5步：VirtualSpaceNode::initialize()                             │\n"
        printf "├────────────────────────────────────────────────────────────────────────────────┤\n"
        printf "│ GDB 验证值：                                                                   │\n"
        printf "│   _rs._base = %p                                                              │\n", _rs._base
        printf "│   _rs._size = %lu bytes = %lu MB                                              │\n", _rs._size, _rs._size/(1024*1024)
        printf "│   _rs._special = %d                                                           │\n", _rs._special
        printf "│                                                                               │\n"
        printf "│ 关键操作：                                                                    │\n"
        printf "│   1. _virtual_space.initialize_with_granularity(_rs, 0, commit_alignment)     │\n"
        printf "│   2. _top = _virtual_space.low()                                              │\n"
        printf "│   3. _occupancy_map = new OccupancyMap(...)                                   │\n"
        printf "└────────────────────────────────────────────────────────────────────────────────┘\n"
    end
    continue
end

# link_vs - 仅当是数据空间时打印
break metaspace::VirtualSpaceList::link_vs
commands
    if _is_class == 0
        printf "\n"
        printf "┌────────────────────────────────────────────────────────────────────────────────┐\n"
        printf "│              第6步：link_vs() 链接节点                                         │\n"
        printf "├────────────────────────────────────────────────────────────────────────────────┤\n"
        printf "│ GDB 验证值：                                                                   │\n"
        printf "│   new_entry = %p                                                              │\n", new_entry
        printf "│                                                                               │\n"
        printf "│ 关键操作：                                                                    │\n"
        printf "│   1. _virtual_space_list = new_entry (链表头)                                 │\n"
        printf "│   2. _current_virtual_space = new_entry                                       │\n"
        printf "│   3. _reserved_words += new_entry->reserved_words()                           │\n"
        printf "│   4. _virtual_space_count++                                                   │\n"
        printf "└────────────────────────────────────────────────────────────────────────────────┘\n"
    end
    continue
end

# 创建 ChunkManager(false)
break metaspace.cpp:1433
commands
    printf "\n"
    printf "┌────────────────────────────────────────────────────────────────────────────────┐\n"
    printf "│              第7步：创建 ChunkManager(false)                                   │\n"
    printf "├────────────────────────────────────────────────────────────────────────────────┤\n"
    printf "│ GDB 验证值：                                                                   │\n"
    printf "│   _space_list = %p                                                            │\n", Metaspace::_space_list
    printf "│                                                                               │\n"
    printf "│ 即将执行: _chunk_manager_metadata = new ChunkManager(false)                   │\n"
    printf "└────────────────────────────────────────────────────────────────────────────────┘\n"
    continue
end

# ChunkManager(false) 构造函数
break metaspace::ChunkManager::ChunkManager(bool)
commands
    if is_class == 0
        printf "\n"
        printf "┌────────────────────────────────────────────────────────────────────────────────┐\n"
        printf "│              第8步：ChunkManager(false) 构造函数                               │\n"
        printf "├────────────────────────────────────────────────────────────────────────────────┤\n"
        printf "│ GDB 验证值：                                                                   │\n"
        printf "│   this = %p                                                                   │\n", this
        printf "│   is_class = %d (数据空间)                                                    │\n", is_class
        printf "│                                                                               │\n"
        printf "│ 数据空间 Chunk 大小（稍后初始化）：                                           │\n"
        printf "│   SpecializedChunk = 128 words = 1 KB                                         │\n"
        printf "│   SmallChunk = 512 words = 4 KB                                               │\n"
        printf "│   MediumChunk = 8192 words = 64 KB                                            │\n"
        printf "└────────────────────────────────────────────────────────────────────────────────┘\n"
    end
    continue
end

# global_initialize 完成
break metaspace.cpp:1441
commands
    printf "\n"
    printf "╔══════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║              Metaspace::global_initialize() 完成                             ║\n"
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║ 最终状态汇总：                                                               ║\n"
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║ _first_chunk_word_size      = %lu words = %lu KB                             ║\n", Metaspace::_first_chunk_word_size, (Metaspace::_first_chunk_word_size*8)/1024
    printf "║ _first_class_chunk_word_size = %lu words = %lu KB                            ║\n", Metaspace::_first_class_chunk_word_size, (Metaspace::_first_class_chunk_word_size*8)/1024
    printf "║ _space_list                 = %p                                             ║\n", Metaspace::_space_list
    printf "║ _chunk_manager_metadata     = %p                                             ║\n", Metaspace::_chunk_manager_metadata
    printf "║ _class_space_list           = %p                                             ║\n", Metaspace::_class_space_list
    printf "║ _chunk_manager_class        = %p                                             ║\n", Metaspace::_chunk_manager_class
    printf "║ _tracer                     = %p                                             ║\n", Metaspace::_tracer
    printf "╚══════════════════════════════════════════════════════════════════════════════╝\n"
    quit
end

run
