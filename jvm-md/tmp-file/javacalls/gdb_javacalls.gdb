set pagination off
set print pretty on
set confirm off

b JavaCalls::call_helper
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# ===== 1. 结构体大小 =====
printf "\n========== Sizes ==========\n"
printf "sizeof(JavaCallWrapper): %lu bytes\n", sizeof(JavaCallWrapper)
printf "sizeof(JavaFrameAnchor): %lu bytes\n", sizeof(JavaFrameAnchor)
printf "sizeof(JavaCallArguments): %lu bytes\n", sizeof(JavaCallArguments)
printf "sizeof(JavaValue): %lu bytes\n", sizeof(JavaValue)

# ===== 2. call_stub 入口 =====
printf "\n========== StubRoutines::call_stub ==========\n"
printf "_call_stub_entry: %p\n", StubRoutines::_call_stub_entry
printf "_call_stub_return_address: %p\n", StubRoutines::_call_stub_return_address

# ===== 3. 当前方法 =====
printf "\n========== call_helper args ==========\n"
printf "method: %p\n", method._value
printf "result_type: %d\n", result->_type

# ===== 4. 线程状态 =====
set $thread = (JavaThread*)__the_thread__
printf "\n========== Thread State ==========\n"
printf "thread: %p\n", $thread
printf "thread_state: %d\n", $thread->_thread_state
printf "has_last_java_frame: %d\n", $thread->_anchor._last_Java_sp != 0
printf "active_handles: %p\n", $thread->_active_handles

# ===== 5. JavaFrameAnchor 偏移 =====
printf "\n========== JavaFrameAnchor offsets ==========\n"
printf "offset _last_Java_sp: %lu\n", (size_t)&((JavaFrameAnchor*)0)->_last_Java_sp
printf "offset _last_Java_pc: %lu\n", (size_t)&((JavaFrameAnchor*)0)->_last_Java_pc
printf "offset _last_Java_fp: %lu\n", (size_t)&((JavaFrameAnchor*)0)->_last_Java_fp

# ===== 6. JavaCallWrapper 偏移 =====
printf "\n========== JavaCallWrapper offsets ==========\n"
printf "offset _thread: %lu\n", (size_t)&((JavaCallWrapper*)0)->_thread
printf "offset _handles: %lu\n", (size_t)&((JavaCallWrapper*)0)->_handles
printf "offset _callee_method: %lu\n", (size_t)&((JavaCallWrapper*)0)->_callee_method
printf "offset _receiver: %lu\n", (size_t)&((JavaCallWrapper*)0)->_receiver
printf "offset _anchor: %lu\n", (size_t)&((JavaCallWrapper*)0)->_anchor
printf "offset _result: %lu\n", (size_t)&((JavaCallWrapper*)0)->_result

# ===== 7. entry_point =====
printf "\n========== Entry Point ==========\n"
printf "from_interpreted_entry: %p\n", method._value->_from_interpreted_entry
printf "_i2i_entry: %p\n", method._value->_i2i_entry
printf "_code: %p\n", method._value->_code

# ===== 8. 进入 JavaCallWrapper 构造函数 =====
b JavaCallWrapper::JavaCallWrapper
c

printf "\n========== Inside JavaCallWrapper ctor ==========\n"
printf "this: %p (stack allocated)\n", this
set $jt = (JavaThread*)__the_thread__
printf "thread state: %d (should be 6=_thread_in_vm)\n", $jt->_thread_state

# 继续看 anchor 保存前的 frame_anchor
printf "frame_anchor._last_Java_sp: %p\n", $jt->_anchor._last_Java_sp
printf "frame_anchor._last_Java_pc: %p\n", $jt->_anchor._last_Java_pc
printf "frame_anchor._last_Java_fp: %p\n", $jt->_anchor._last_Java_fp

# ===== 9. 统计调用次数 =====
delete breakpoints
b JavaCalls::call_helper
commands
silent
set $call_count = $call_count + 1
c
end
set $call_count = 0
c

printf "\n========== Total Invocations ==========\n"
printf "JavaCalls::call_helper count: %d\n", $call_count

quit
