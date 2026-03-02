# GDB 调试脚本 - universe_init() 验证

## 快速验证脚本

将以下内容保存为 `gdb_universe_init.gdb`，用于验证 `universe_init()` 的执行结果：

```gdb
# gdb_universe_init.gdb
set pagination off
set print pretty on

# 断点设置在 universe_init 函数
b universe_init
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

printf "\n============================================================\n"
printf "           universe_init() GDB 验证数据                      \n"
printf "============================================================\n"

# 1. CollectedHeap (G1CollectedHeap)
printf "\n========== 1. CollectedHeap ==========\n"
set $heap = Universe::_collectedHeap
printf "Universe::_collectedHeap 地址: %p\n", $heap
printf "堆 reserved_region:\n"
printf "  _start: %p\n", $heap->_reserved._start
printf "  _word_size: %lu words = %lu bytes = %lu MB\n", \
    $heap->_reserved._word_size, \
    $heap->_reserved._word_size * 8, \
    $heap->_reserved._word_size * 8 / 1024 / 1024

# G1 特有信息
set $g1 = (G1CollectedHeap*)$heap
printf "\nG1CollectedHeap:\n"
printf "  _hrm (HeapRegionManager) 地址: %p\n", &$g1->_hrm
printf "  _num_committed regions: %u\n", $g1->_hrm._num_committed

# 2. 压缩指针配置
printf "\n========== 2. 压缩指针 (NarrowOop) ==========\n"
printf "Universe::_narrow_oop:\n"
printf "  _base: %p\n", Universe::_narrow_oop._base
printf "  _shift: %d\n", Universe::_narrow_oop._shift
printf "  _use_implicit_null_checks: %d\n", Universe::_narrow_oop._use_implicit_null_checks

printf "\nUniverse::_narrow_klass:\n"
printf "  _base: %p\n", Universe::_narrow_klass._base
printf "  _shift: %d\n", Universe::_narrow_klass._shift

# 3. LatestMethodCache
printf "\n========== 3. LatestMethodCache ==========\n"
printf "_finalizer_register_cache: %p\n", Universe::_finalizer_register_cache
printf "  _klass: %p, _method_idnum: %d\n", \
    Universe::_finalizer_register_cache->_klass, \
    Universe::_finalizer_register_cache->_method_idnum

# 4. SymbolTable
printf "\n========== 4. SymbolTable ==========\n"
printf "SymbolTable::_the_table 地址: %p\n", SymbolTable::_the_table
printf "  _table_size (bucket 数): %d\n", SymbolTable::_the_table->_table_size
printf "  _number_of_entries: %d\n", SymbolTable::_the_table->_number_of_entries

# 5. 状态标志
printf "\n========== 5. Universe 状态标志 ==========\n"
printf "Universe::_bootstrapping: %d\n", Universe::_bootstrapping
printf "Universe::_fully_initialized: %d\n", Universe::_fully_initialized

# 6. TLAB 配置
printf "\n========== 6. TLAB 配置 ==========\n"
printf "ThreadLocalAllocBuffer::_max_size: %lu words = %lu KB\n", \
    ThreadLocalAllocBuffer::_max_size, ThreadLocalAllocBuffer::_max_size * 8 / 1024

# 7. HeapRegion 配置
printf "\n========== 7. HeapRegion 配置 ==========\n"
printf "HeapRegion::GrainBytes: %lu = %lu MB\n", HeapRegion::GrainBytes, HeapRegion::GrainBytes / 1024 / 1024
printf "HeapRegion::GrainWords: %lu\n", HeapRegion::GrainWords
printf "HeapRegion::CardsPerRegion: %lu\n", HeapRegion::CardsPerRegion

# 8. 第一个 HeapRegion
printf "\n========== 8. 第一个 HeapRegion ==========\n"
set $hrm = &$g1->_hrm
set $base = (HeapRegion**)$hrm->_regions._base
set $region0 = $base[0]
printf "Region[0] 地址: %p\n", $region0
printf "  bottom: %p\n", $region0->_bottom
printf "  end: %p\n", $region0->_end
printf "  type: %d\n", $region0->_type._tag

printf "\n============================================================\n"
printf "                     验证完成                                \n"
printf "============================================================\n"
```

## 使用方法

```bash
# 1. 编译带调试信息的JDK
export JAVA_HOME=/data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk

# 2. 准备测试程序
cd /data/workspace/demo/src
javac com/wjcoder/Main.java

# 3. 运行GDB调试
gdb --args $JAVA_HOME/bin/java \
    -Xms8g -Xmx8g -XX:+UseG1GC -Xint \
    -cp /data/workspace/demo/src com.wjcoder.Main

# 4. 在GDB中加载脚本
source gdb_universe_init.gdb
```

## 预期输出

在标准条件下（-Xms8g -Xmx8g -XX:+UseG1GC），你应该看到：

```
========== 1. CollectedHeap ==========
Universe::_collectedHeap 地址: 0x7ffff00324e0
堆 reserved_region:
  _start: 0x600000000
  _word_size: 1073741824 words = 8589934592 bytes = 8192 MB

========== 2. 压缩指针 (NarrowOop) ==========
Universe::_narrow_oop:
  _base: 0x0
  _shift: 3
Universe::_narrow_klass:
  _base: 0x800000000
  _shift: 0

========== 7. HeapRegion 配置 ==========
HeapRegion::GrainBytes: 4194304 = 4 MB
HeapRegion::GrainWords: 524288
HeapRegion::CardsPerRegion: 8192
```

## 关键验证点

1. **堆地址范围**: 0x600000000 - 0x800000000 (8GB)
2. **压缩指针模式**: ZeroBased (base=0, shift=3)
3. **压缩类指针**: base=0x800000000, shift=0
4. **Region大小**: 4MB (G1标准配置)
5. **Region数量**: 2048个 (8GB/4MB)