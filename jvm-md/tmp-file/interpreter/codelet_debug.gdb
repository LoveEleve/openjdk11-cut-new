# GDB 脚本：捕获解释器 Codelet 数据
set pagination off
set print pretty on

# 断点1: generate_all() 开始
break templateInterpreterGenerator.cpp:57
commands
  silent
  printf "\n========== generate_all() 开始 ==========\n"
  printf "MacroAssembler: %p\n", _masm
  continue
end

# 断点2: slow_signature_handler 生成后
break templateInterpreterGenerator.cpp:60
commands
  silent
  printf "\n--- slow_signature_handler 生成完成 ---\n"
  printf "_slow_signature_handler = %p\n", AbstractInterpreter::_slow_signature_handler
  continue
end

# 断点3: error_exits 生成后
break templateInterpreterGenerator.cpp:65
commands
  silent
  printf "\n--- error_exits 生成完成 ---\n"
  printf "_unimplemented_bytecode    = %p\n", _unimplemented_bytecode
  printf "_illegal_bytecode_sequence = %p\n", _illegal_bytecode_sequence
  continue
end

# 断点4: return_entry 生成后
break templateInterpreterGenerator.cpp:105
commands
  silent
  printf "\n--- return_entry 生成完成 ---\n"
  continue
end

# 断点5: 方法入口生成 (zerolocals)
break templateInterpreterGenerator.cpp:193
commands
  silent
  printf "\n--- 即将生成 zerolocals 入口 ---\n"
  continue
end

# 断点6: generate_normal_entry 开始
break templateInterpreterGenerator_x86.cpp:1335
commands
  silent
  printf "\n========== generate_normal_entry(synchronized=%d) 开始 ==========\n", synchronized
  printf "当前 pc = %p\n", _masm->pc()
  continue
end

# 断点7: interpreter_init 完成
break interpreter.cpp:128
commands
  silent
  printf "\n========== interpreter_init() 完成 ==========\n"
  printf "\n--- StubQueue* _code ---\n"
  print AbstractInterpreter::_code
  printf "\n--- _slow_signature_handler ---\n"
  print/x AbstractInterpreter::_slow_signature_handler
  printf "\n--- _entry_table[zerolocals] ---\n"
  print/x TemplateInterpreter::_entry_table[0]
  continue
end

run -Xms8g -Xmx8g -XX:+UseG1GC -version
