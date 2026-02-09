#!/bin/bash
cd /data/workspace/openjdk-cut-new

gdb -q build/linux-x86_64-normal-server-slowdebug/jdk/bin/java << 'GDBCMD'
set pagination off
set print pretty on
set breakpoint pending on

# 断点1: generate_all 开始
break TemplateInterpreterGenerator::generate_all
commands 1
  silent
  printf "\n========== generate_all() 开始 ==========\n"
  printf "this = %p\n", this
  printf "AbstractInterpreter::_code (StubQueue*) = %p\n", AbstractInterpreter::_code
  print *AbstractInterpreter::_code
  continue
end

# 断点2: slow_signature_handler 生成后 (第60行)
# 需要在生成完成后断下来查看地址

# 断点3: interpreter_init 结束
break interpreter_init
commands 3
  silent
  printf "\n========== interpreter_init() 开始 ==========\n"
  continue
end

run -Xms8g -Xmx8g -XX:+UseG1GC -version
quit
GDBCMD
