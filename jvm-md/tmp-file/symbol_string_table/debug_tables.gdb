# GDB 调试脚本：分析 SymbolTable 和 StringTable 创建
# 条件：-Xms8g -Xmx8g -XX:+UseG1GC

set pagination off
set breakpoint pending on

# 断点1：SymbolTable::create_table
break SymbolTable::create_table
commands
    printf "\n"
    printf "╔══════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║                    SymbolTable::create_table() 入口                          ║\n"
    printf "╚══════════════════════════════════════════════════════════════════════════════╝\n"
    printf "SymbolTable::_the_table (before) = %p\n", SymbolTable::_the_table
    printf "SymbolTableSize = %lu\n", SymbolTableSize
    continue
end

# 断点2：SymbolTable 构造函数
break SymbolTable::SymbolTable()
commands
    printf "\n>>> SymbolTable 构造函数\n"
    printf "    this = %p\n", this
    continue
end

# 断点3：initialize_symbols
break SymbolTable::initialize_symbols
commands
    printf "\n>>> initialize_symbols(arena_alloc_size = %d)\n", arena_alloc_size
    continue
end

# 断点4：Arena 创建（为 Symbol 分配）
break Arena::Arena(MemoryType, unsigned long)
commands
    printf ">>> 创建 Arena: type = %d, size = %lu bytes (%lu KB)\n", x, init_size, init_size/1024
    continue
end

# 断点5：StringTable::create_table
break StringTable::create_table
commands
    printf "\n"
    printf "╔══════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║                    StringTable::create_table() 入口                          ║\n"
    printf "╚══════════════════════════════════════════════════════════════════════════════╝\n"
    printf "StringTable::_the_table (before) = %p\n", StringTable::_the_table
    printf "StringTableSize = %lu\n", StringTableSize
    continue
end

# 断点6：StringTable 构造函数
break StringTable::StringTable()
commands
    printf "\n>>> StringTable 构造函数\n"
    printf "    this = %p\n", this
    continue
end

# 断点7：OopStorage 创建
break OopStorage::OopStorage
commands
    printf "\n>>> 创建 OopStorage: name = %s\n", name
    continue
end

# 断点8：完成后检查状态
break universe.cpp:853
commands
    printf "\n"
    printf "╔══════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║                    SymbolTable & StringTable 创建完成                        ║\n"
    printf "╠══════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║ SymbolTable::_the_table = %p\n", SymbolTable::_the_table
    printf "║ SymbolTable::_arena = %p\n", SymbolTable::_arena
    printf "║ StringTable::_the_table = %p\n", StringTable::_the_table
    printf "╚══════════════════════════════════════════════════════════════════════════════╝\n"
    printf "\n=== SymbolTable 详情 ===\n"
    print *SymbolTable::_the_table
    printf "\n=== StringTable 详情 ===\n"
    print *StringTable::_the_table
    quit
end

run
