# GDB script for debugging interpreter stack frame
set pagination off
set print pretty on

# 在解释器入口点设置条件断点
# 我们要在 testMethod 被调用时停下来

# 断点在 notify_method_entry，这是方法入口后的通知点
b InterpreterRuntime::member_name_arg

run -Xint -XX:+UseG1GC -Xms8g -Xmx8g TestInterpreter

# 第一次命中后继续几次跳过系统类
c
c
c
c
c
c
c
c
c
c

# 打印当前方法名
printf "\n========== Current Method ==========\n"
call (void)((Method*)*((intptr_t*)$rbp-3))->print()

# 打印栈帧布局
printf "\n========== Stack Frame Layout ==========\n"
printf "rbp = %p\n", $rbp
printf "rsp = %p\n", $rsp
printf "r13 (bcp) = %p\n", $r13
printf "r14 (locals) = %p\n", $r14
printf "r15 (thread) = %p\n", $r15

printf "\n========== Frame Fields (rbp-based) ==========\n"
printf "[rbp+8]  return_addr   = %p\n", *(intptr_t*)($rbp+8)
printf "[rbp+0]  saved_rbp     = %p\n", *(intptr_t*)($rbp+0)
printf "[rbp-8]  sender_sp     = %p\n", *(intptr_t*)($rbp-8)
printf "[rbp-16] last_sp       = %p\n", *(intptr_t*)($rbp-16)
printf "[rbp-24] Method*       = %p\n", *(intptr_t*)($rbp-24)
printf "[rbp-32] mirror        = %p\n", *(intptr_t*)($rbp-32)
printf "[rbp-40] mdp           = %p\n", *(intptr_t*)($rbp-40)
printf "[rbp-48] cache         = %p\n", *(intptr_t*)($rbp-48)
printf "[rbp-56] locals        = %p\n", *(intptr_t*)($rbp-56)
printf "[rbp-64] bcp           = %p\n", *(intptr_t*)($rbp-64)
printf "[rbp-72] initial_sp    = %p\n", *(intptr_t*)($rbp-72)

printf "\n========== Raw memory dump (rbp-72 to rbp+16) ==========\n"
x/12gx $rbp-72

quit
