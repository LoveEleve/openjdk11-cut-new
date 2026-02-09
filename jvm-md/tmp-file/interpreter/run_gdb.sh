#!/bin/bash
cd /data/workspace/openjdk-cut-new

# 使用交互式 GDB 会话的方式
gdb -q build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'GDBCMD'
set pagination off
set print pretty on
set breakpoint pending on

# 设置断点
break TemplateInterpreterGenerator::generate_all
break TemplateInterpreterGenerator::generate_slow_signature_handler

# 运行
run -Xms8g -Xmx8g -XX:+UseG1GC -version

# 如果停在断点，打印信息
bt 3
print this
print _masm
print AbstractInterpreter::_code

continue

# 第二个断点
bt 3
print/x $pc
print AbstractInterpreter::_slow_signature_handler

quit
GDBCMD
