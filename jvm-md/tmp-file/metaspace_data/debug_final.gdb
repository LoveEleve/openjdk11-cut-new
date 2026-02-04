# 最终调试脚本
set pagination off
set breakpoint pending on

break MetaspaceTracer::MetaspaceTracer
commands
    printf "\n"
    printf "╔══════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║                    GDB 验证：数据元空间初始化结果                            ║\n"
    printf "╚══════════════════════════════════════════════════════════════════════════════╝\n"
    
    printf "\n=== 1. 基础参数 ===\n"
    printf "InitialBootClassLoaderMetaspaceSize = %lu bytes = %lu MB\n", InitialBootClassLoaderMetaspaceSize, InitialBootClassLoaderMetaspaceSize/(1024*1024)
    printf "_first_chunk_word_size = %lu words = %lu KB\n", Metaspace::_first_chunk_word_size, (Metaspace::_first_chunk_word_size*8)/1024
    printf "_first_class_chunk_word_size = %lu words = %lu KB\n", Metaspace::_first_class_chunk_word_size, (Metaspace::_first_class_chunk_word_size*8)/1024
    
    printf "\n=== 2. _space_list (数据元空间 VirtualSpaceList) ===\n"
    print *Metaspace::_space_list
    
    printf "\n=== 3. _space_list->_virtual_space_list (VirtualSpaceNode) ===\n"
    print *Metaspace::_space_list->_virtual_space_list
    
    printf "\n=== 4. VirtualSpaceNode 内部的 _rs (ReservedSpace) ===\n"
    print Metaspace::_space_list->_virtual_space_list->_rs
    
    printf "\n=== 5. VirtualSpaceNode 内部的 _virtual_space (VirtualSpace) ===\n"
    print Metaspace::_space_list->_virtual_space_list->_virtual_space
    
    printf "\n=== 6. _chunk_manager_metadata (数据元空间 ChunkManager) ===\n"
    print *Metaspace::_chunk_manager_metadata
    
    printf "\n=== 7. ChunkManager 空闲链表大小 ===\n"
    printf "SpecializedChunk: %lu words = %lu KB\n", Metaspace::_chunk_manager_metadata->_free_chunks[0]._size, (Metaspace::_chunk_manager_metadata->_free_chunks[0]._size*8)/1024
    printf "SmallChunk: %lu words = %lu KB\n", Metaspace::_chunk_manager_metadata->_free_chunks[1]._size, (Metaspace::_chunk_manager_metadata->_free_chunks[1]._size*8)/1024
    printf "MediumChunk: %lu words = %lu KB\n", Metaspace::_chunk_manager_metadata->_free_chunks[2]._size, (Metaspace::_chunk_manager_metadata->_free_chunks[2]._size*8)/1024
    
    quit
end

run
