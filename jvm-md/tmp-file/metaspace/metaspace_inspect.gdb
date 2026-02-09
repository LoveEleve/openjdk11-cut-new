# Metaspace GDB 验证脚本
# 断点设在 Metaspace::post_initialize() 完成后
# 用法: gdb -x metaspace_inspect.gdb --args java -Xms8g -Xmx8g -XX:+UseG1GC ...

set pagination off
set print pretty on
set confirm off

# 断点1: global_initialize 完成后（post_initialize 入口）
break Metaspace::post_initialize
commands
  silent
  printf "\n===== Metaspace::post_initialize() 入口 =====\n"
  printf "\n--- 全局状态 ---\n"
  printf "_first_chunk_word_size = %lu (expect 524288 = 4MB/8)\n", Metaspace::_first_chunk_word_size
  printf "_first_class_chunk_word_size = %lu (expect 49152 = 384KB/8)\n", Metaspace::_first_class_chunk_word_size
  printf "_commit_alignment = %lu\n", Metaspace::_commit_alignment
  printf "_reserve_alignment = %lu\n", Metaspace::_reserve_alignment

  printf "\n--- MetaspaceGC HWM (初始化时) ---\n"
  printf "_capacity_until_GC = %lu\n", MetaspaceGC::_capacity_until_GC

  printf "\n--- 数据元空间 VirtualSpaceList ---\n"
  printf "_space_list = %p\n", Metaspace::_space_list
  printf "  _reserved_words = %lu\n", Metaspace::_space_list->_reserved_words
  printf "  _committed_words = %lu\n", Metaspace::_space_list->_committed_words
  printf "  _virtual_space_count = %lu\n", Metaspace::_space_list->_virtual_space_count

  printf "\n--- 类元空间 VirtualSpaceList ---\n"
  printf "_class_space_list = %p\n", Metaspace::_class_space_list
  printf "  _reserved_words = %lu\n", Metaspace::_class_space_list->_reserved_words
  printf "  _committed_words = %lu\n", Metaspace::_class_space_list->_committed_words
  printf "  _virtual_space_count = %lu\n", Metaspace::_class_space_list->_virtual_space_count

  printf "\n--- 数据 ChunkManager ---\n"
  set $cm = Metaspace::_chunk_manager_metadata
  printf "_chunk_manager_metadata = %p\n", $cm
  printf "  _free_chunks_total words = %lu\n", $cm->_free_chunks_total
  printf "  _free_chunks_count = %lu\n", $cm->_free_chunks_count
  printf "  Specialized count = %lu\n", $cm->_free_chunks[0]._count
  printf "  Small count = %lu\n", $cm->_free_chunks[1]._count
  printf "  Medium count = %lu\n", $cm->_free_chunks[2]._count

  printf "\n--- 类 ChunkManager ---\n"
  set $cm_c = Metaspace::_chunk_manager_class
  printf "_chunk_manager_class = %p\n", $cm_c
  printf "  _free_chunks_total words = %lu\n", $cm_c->_free_chunks_total
  printf "  _free_chunks_count = %lu\n", $cm_c->_free_chunks_count
  printf "  Specialized count = %lu\n", $cm_c->_free_chunks[0]._count
  printf "  Small count = %lu\n", $cm_c->_free_chunks[1]._count
  printf "  Medium count = %lu\n", $cm_c->_free_chunks[2]._count

  printf "\n--- 压缩类指针 ---\n"
  printf "narrow_klass_base = %p\n", Universe::_narrow_klass._base
  printf "narrow_klass_shift = %d\n", Universe::_narrow_klass._shift
  printf "CompressedClassSpaceSize = %lu\n", CompressedClassSpaceSize

  continue
end

# 断点2: post_initialize 完成后（universe_post_init 返回前）
break universe_post_init
commands
  silent
  # 这个函数入口就会调用 Metaspace::post_initialize()
  continue
end

# 断点3: 在 SpaceManager::grow_and_allocate 观察 Chunk 分配
break SpaceManager::grow_and_allocate
commands
  silent
  printf "\n===== SpaceManager::grow_and_allocate =====\n"
  printf "this = %p, word_size = %lu\n", this, word_size
  printf "  _space_type = %d\n", this->_space_type
  printf "  _mdtype = %d\n", this->_mdtype
  printf "  _capacity_words = %lu\n", this->_capacity_words
  printf "  _used_words = %lu\n", this->_used_words
  continue
end

# 断点4: 在 VirtualSpaceNode::take_from_committed 观察 Chunk 创建
break VirtualSpaceNode::take_from_committed
commands
  silent
  printf "\n===== VSN::take_from_committed =====\n"
  printf "this = %p, chunk_word_size = %lu\n", this, chunk_word_size
  printf "  _top = %p\n", this->_top
  printf "  _container_count = %lu\n", this->_container_count
  continue
end

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -XX:+UnlockDiagnosticVMOptions -XX:+PrintMetaspaceStatisticsAtExit -version

quit
