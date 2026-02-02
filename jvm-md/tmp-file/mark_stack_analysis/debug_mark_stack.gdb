# 分析 G1CMMarkStack 构造函数和 initialize 方法
set pagination off
set print pretty on
set confirm off

# 断点1: G1CMMarkStack 构造函数
break G1CMMarkStack::G1CMMarkStack

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

printf "\n=========================================\n"
printf "断点1: G1CMMarkStack::G1CMMarkStack() 构造函数\n"
printf "=========================================\n"
printf "this: %p\n", this
printf "\n=== 执行构造函数... ===\n"
finish

printf "\n=== 构造函数执行后的状态 ===\n"
print *this
printf "\n成员变量详情:\n"
printf "  _max_chunk_capacity: %lu\n", this->_max_chunk_capacity
printf "  _base: %p\n", this->_base
printf "  _chunk_capacity: %lu\n", this->_chunk_capacity
printf "  _free_list: %p\n", this->_free_list
printf "  _chunk_list: %p\n", this->_chunk_list
printf "  _chunks_in_chunk_list: %lu\n", this->_chunks_in_chunk_list
printf "  _hwm: %lu\n", this->_hwm

# 断点2: initialize 方法
delete breakpoints
break G1CMMarkStack::initialize

continue

printf "\n=========================================\n"
printf "断点2: G1CMMarkStack::initialize() 入口\n"
printf "=========================================\n"
printf "this: %p\n", this
printf "参数:\n"
printf "  initial_capacity: %lu\n", initial_capacity
printf "  max_capacity: %lu\n", max_capacity
printf "\n"

# 单步执行观察
printf "=== 执行 initialize 过程 ===\n"

# 执行到计算完成
next
next
next

printf "\n计算后的值:\n"
printf "  TaskEntryChunkSizeInVoidStar: %lu\n", sizeof(G1CMMarkStack::TaskQueueEntryChunk) / sizeof(G1TaskQueueEntry)
printf "  _max_chunk_capacity: %lu\n", this->_max_chunk_capacity
printf "  initial_chunk_capacity (局部变量): 待查看\n"

# 继续执行完毕
finish

printf "\n=========================================\n"
printf "initialize() 执行后的状态\n"
printf "=========================================\n"
print *this
printf "\n成员变量详情:\n"
printf "  _max_chunk_capacity: %lu (最大chunk数量)\n", this->_max_chunk_capacity
printf "  _base: %p (内存基地址)\n", this->_base
printf "  _chunk_capacity: %lu (当前chunk容量)\n", this->_chunk_capacity
printf "  _free_list: %p (空闲链表)\n", this->_free_list
printf "  _chunk_list: %p (数据链表)\n", this->_chunk_list
printf "  _chunks_in_chunk_list: %lu\n", this->_chunks_in_chunk_list
printf "  _hwm: %lu (高水位)\n", this->_hwm

quit
