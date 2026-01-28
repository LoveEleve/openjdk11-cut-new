# G1堆初始化调试验证计划

## 🎯 调试目标
通过GDB调试验证G1堆初始化过程中每个关键对象的创建和配置。

## 🔧 调试环境准备

### 1. 编译调试版本
```bash
# 编译slowdebug版本，包含调试信息
make -f make/Main.gmk SPEC=build-config/spec.gmk split-hotspot-libs
```

### 2. GDB断点设置
```bash
# 启动GDB
gdb --args ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
    -Xms8g -Xmx8g -XX:+UseG1GC \
    -XX:+PrintGCDetails -XX:+PrintGCTimeStamps \
    -cp /tmp HelloWorld

# 设置关键断点
(gdb) break G1CollectedHeap::initialize
(gdb) break Universe::reserve_heap  
(gdb) break G1CardTable::G1CardTable
(gdb) break G1BarrierSet::G1BarrierSet
(gdb) break G1RegionToSpaceMapper::create_mapper
(gdb) break HeapRegionManager::initialize
(gdb) break G1ConcurrentMark::G1ConcurrentMark
```

## 📊 验证检查点

### 检查点1：堆参数获取
```cpp
// 在G1CollectedHeap::initialize()开始处
(gdb) p init_byte_size     // 应该是8589934592 (8GB)
(gdb) p max_byte_size      // 应该是8589934592 (8GB)  
(gdb) p heap_alignment     // 应该是4194304 (4MB)
```

### 检查点2：虚拟内存预留
```cpp
// 在Universe::reserve_heap()调用后
(gdb) p heap_rs.base()     // 预留空间起始地址
(gdb) p heap_rs.size()     // 应该是8589934592 (8GB)
(gdb) p heap_rs.is_reserved() // 应该是true
```

### 检查点3：卡表创建
```cpp
// 在G1CardTable创建后
(gdb) p ct->_whole_heap    // 应该等于reserved_region()
(gdb) p ct->_card_size     // 应该是512
(gdb) p ct->cards_required(heap_rs.size()) // 应该是16777216 (16MB)
```

### 检查点4：内存映射器创建
```cpp
// 验证6个映射器的创建
(gdb) p heap_storage->_storage._base     // 堆存储基地址
(gdb) p bot_storage->_storage._size      // BOT大小，应该约16MB
(gdb) p cardtable_storage->_storage._size // 卡表大小，应该约16MB
(gdb) p prev_bitmap_storage->_storage._size // 位图大小，应该约128MB
(gdb) p next_bitmap_storage->_storage._size // 位图大小，应该约128MB
```

### 检查点5：HeapRegionManager初始化
```cpp
// 在_hrm.initialize()调用后
(gdb) p _hrm._regions._length        // Region数组长度，应该是2048
(gdb) p _hrm._num_committed         // 已提交Region数，初始为0
(gdb) p _hrm._heap_mapper           // 应该指向heap_storage
```

### 检查点6：并发标记器创建
```cpp
// 在G1ConcurrentMark创建后
(gdb) p _cm->_g1h                   // 应该指向this
(gdb) p _cm->_prev_mark_bitmap      // 上轮标记位图
(gdb) p _cm->_next_mark_bitmap      // 当前标记位图
(gdb) p _cm->_parallel_marking_threads // 并行标记线程数
```

## 🧪 内存布局验证

### 验证地址空间布局
```bash
# 在初始化完成后，检查进程内存映射
(gdb) shell cat /proc/$(pgrep java)/maps | grep -E "(heap|anon)"
```

### 验证对象大小
```cpp
// 检查关键对象的内存占用
(gdb) p sizeof(G1CollectedHeap)      // G1堆对象大小
(gdb) p sizeof(HeapRegionManager)    // Region管理器大小
(gdb) p sizeof(G1ConcurrentMark)     // 并发标记器大小
```

## 📝 调试脚本

创建自动化调试脚本：

```bash
#!/bin/bash
# debug_g1_init.sh

echo "=== G1堆初始化调试脚本 ==="

# 启动GDB并执行调试命令
gdb --batch --ex "set confirm off" \
    --ex "break G1CollectedHeap::initialize" \
    --ex "run" \
    --ex "print init_byte_size" \
    --ex "print max_byte_size" \
    --ex "print heap_alignment" \
    --ex "continue" \
    --args ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
    -Xms8g -Xmx8g -XX:+UseG1GC HelloWorld
```

## 🎯 预期结果

通过调试验证，我们应该看到：

1. **堆参数正确获取**：8GB堆大小，4MB对齐
2. **虚拟内存成功预留**：8GB连续地址空间
3. **6个映射器创建成功**：总计约320MB辅助数据结构
4. **Region管理器初始化**：2048个Region槽位
5. **并发标记器就绪**：双缓冲位图准备完毕

这样就能完整验证G1堆初始化的每个关键步骤！