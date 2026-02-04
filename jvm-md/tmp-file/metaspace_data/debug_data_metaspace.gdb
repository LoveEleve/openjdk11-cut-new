# GDB 调试脚本：分析数据元空间（_space_list）的初始化
# 条件：-Xms8g -Xmx8g -XX:+UseG1GC

# 设置断点
set breakpoint pending on
set pagination off

# 断点1：计算首个 Chunk 大小前
break metaspace.cpp:1418
commands
    printf "\n========== 计算首个 Chunk 大小 ==========\n"
    printf "InitialBootClassLoaderMetaspaceSize = %lu bytes (%lu KB)\n", InitialBootClassLoaderMetaspaceSize, InitialBootClassLoaderMetaspaceSize/1024
    printf "BytesPerWord = %lu\n", BytesPerWord
    continue
end

# 断点2：计算 _first_chunk_word_size 后
break metaspace.cpp:1419
commands
    printf "_first_chunk_word_size (before align) = %lu words (%lu KB)\n", Metaspace::_first_chunk_word_size, (Metaspace::_first_chunk_word_size * 8)/1024
    continue
end

# 断点3：计算 _first_class_chunk_word_size 前
break metaspace.cpp:1423
commands
    printf "\n========== 计算类空间首个 Chunk 大小 ==========\n"
    printf "MediumChunk = %lu words\n", metaspace::MediumChunk
    printf "MediumChunk * 6 = %lu words\n", metaspace::MediumChunk * 6
    printf "CompressedClassSpaceSize = %lu bytes (%lu MB)\n", CompressedClassSpaceSize, CompressedClassSpaceSize/(1024*1024)
    printf "(CompressedClassSpaceSize/BytesPerWord)*2 = %lu words\n", (CompressedClassSpaceSize/8)*2
    continue
end

# 断点4：计算初始虚拟空间大小
break metaspace.cpp:1428
commands
    printf "\n========== 计算初始虚拟空间大小 ==========\n"
    printf "_first_chunk_word_size (after align) = %lu words (%lu KB)\n", Metaspace::_first_chunk_word_size, (Metaspace::_first_chunk_word_size * 8)/1024
    printf "_first_class_chunk_word_size = %lu words (%lu KB)\n", Metaspace::_first_class_chunk_word_size, (Metaspace::_first_class_chunk_word_size * 8)/1024
    printf "VIRTUALSPACEMULTIPLIER = 2\n"
    continue
end

# 断点5：创建 VirtualSpaceList 前
break metaspace.cpp:1432
commands
    printf "\n========== 创建数据元空间 VirtualSpaceList ==========\n"
    printf "word_size = %lu words (%lu MB)\n", word_size, (word_size * 8)/(1024*1024)
    printf "reserve_alignment_words = %lu words (%lu KB)\n", Metaspace::reserve_alignment_words(), (Metaspace::reserve_alignment_words()*8)/1024
    continue
end

# 断点6：VirtualSpaceList(size_t) 构造函数入口
break virtualSpaceList.cpp:153
commands
    printf "\n========== VirtualSpaceList(size_t) 构造函数 ==========\n"
    printf "word_size 参数 = %lu words (%lu MB)\n", word_size, (word_size * 8)/(1024*1024)
    printf "this = %p\n", this
    continue
end

# 断点7：create_new_virtual_space 入口
break virtualSpaceList.cpp:221
commands
    printf "\n========== create_new_virtual_space ==========\n"
    printf "vs_word_size = %lu words (%lu MB)\n", vs_word_size, (vs_word_size * 8)/(1024*1024)
    printf "is_class() = %d\n", is_class()
    continue
end

# 断点8：创建 VirtualSpaceNode
break virtualSpaceList.cpp:241
commands
    printf "\n========== 创建 VirtualSpaceNode (数据空间) ==========\n"
    printf "vs_byte_size = %lu bytes (%lu MB)\n", vs_byte_size, vs_byte_size/(1024*1024)
    printf "is_class() = %d\n", is_class()
    continue
end

# 断点9：VirtualSpaceNode(size_t) 构造函数
break virtualSpaceNode.cpp:59
commands
    printf "\n========== VirtualSpaceNode(size_t) 构造函数 ==========\n"
    printf "bytes = %lu (%lu MB)\n", bytes, bytes/(1024*1024)
    printf "is_class = %d\n", is_class
    continue
end

# 断点10：ReservedSpace 创建后
break virtualSpaceNode.cpp:64
commands
    printf "ReservedSpace 创建:\n"
    printf "  _rs._base = %p\n", _rs._base
    printf "  _rs._size = %lu (%lu MB)\n", _rs._size, _rs._size/(1024*1024)
    printf "  _rs._special = %d\n", _rs._special
    continue
end

# 断点11：VirtualSpaceNode::initialize() 完成后
break virtualSpaceNode.cpp:536
commands
    printf "\n========== VirtualSpaceNode::initialize() 完成 ==========\n"
    printf "VirtualSpace 状态:\n"
    printf "  _low_boundary = %p\n", _virtual_space._low_boundary
    printf "  _high_boundary = %p\n", _virtual_space._high_boundary
    printf "  _low = %p\n", _virtual_space._low
    printf "  _high = %p\n", _virtual_space._high
    printf "_top = %p\n", _top
    printf "smallest_chunk_size = %lu words (%lu bytes)\n", smallest_chunk_size, smallest_chunk_size * 8
    continue
end

# 断点12：link_vs 完成后
break virtualSpaceList.cpp:272
commands
    printf "\n========== link_vs 完成 (数据空间) ==========\n"
    printf "VirtualSpaceList 状态:\n"
    printf "  _is_class = %d\n", _is_class
    printf "  _reserved_words = %lu (%lu MB)\n", _reserved_words, (_reserved_words * 8)/(1024*1024)
    printf "  _committed_words = %lu\n", _committed_words
    printf "  _virtual_space_count = %lu\n", _virtual_space_count
    printf "  _envelope_lo = %p\n", _envelope_lo
    printf "  _envelope_hi = %p\n", _envelope_hi
    printf "  _virtual_space_list = %p\n", _virtual_space_list
    printf "  _current_virtual_space = %p\n", _current_virtual_space
    continue
end

# 断点13：创建 ChunkManager 前
break metaspace.cpp:1433
commands
    printf "\n========== 创建数据元空间 ChunkManager ==========\n"
    printf "_space_list = %p\n", Metaspace::_space_list
    continue
end

# 断点14：ChunkManager(false) 构造函数
break chunkManager.cpp:43
commands
    printf "\n========== ChunkManager 构造函数 ==========\n"
    printf "is_class = %d\n", is_class
    continue
end

# 断点15：ChunkManager 构造完成
break chunkManager.cpp:48
commands
    printf "ChunkManager 初始化完成:\n"
    printf "  _is_class = %d\n", _is_class
    printf "  _free_chunks_total = %lu\n", _free_chunks_total
    printf "  _free_chunks_count = %lu\n", _free_chunks_count
    printf "  SpecializedChunk size = %lu words\n", _free_chunks[0]._size
    printf "  SmallChunk size = %lu words\n", _free_chunks[1]._size
    printf "  MediumChunk size = %lu words\n", _free_chunks[2]._size
    continue
end

# 断点16：创建 MetaspaceTracer
break metaspace.cpp:1439
commands
    printf "\n========== 创建 MetaspaceTracer ==========\n"
    printf "_chunk_manager_metadata = %p\n", Metaspace::_chunk_manager_metadata
    continue
end

# 断点17：global_initialize 完成
break metaspace.cpp:1441
commands
    printf "\n========== global_initialize 完成 ==========\n"
    printf "\n=== 最终数据结构汇总 ===\n"
    printf "Metaspace 静态变量:\n"
    printf "  _first_chunk_word_size = %lu words (%lu KB)\n", Metaspace::_first_chunk_word_size, (Metaspace::_first_chunk_word_size*8)/1024
    printf "  _first_class_chunk_word_size = %lu words (%lu KB)\n", Metaspace::_first_class_chunk_word_size, (Metaspace::_first_class_chunk_word_size*8)/1024
    printf "  _space_list = %p\n", Metaspace::_space_list
    printf "  _chunk_manager_metadata = %p\n", Metaspace::_chunk_manager_metadata
    printf "  _class_space_list = %p\n", Metaspace::_class_space_list
    printf "  _chunk_manager_class = %p\n", Metaspace::_chunk_manager_class
    printf "  _tracer = %p\n", Metaspace::_tracer
    printf "  _initialized = %d\n", Metaspace::_initialized
    quit
end

run
