set pagination off
set print pretty on
set confirm off

set $call_virtual_count = 0
set $call_special_count = 0
set $call_static_count = 0
set $call_count = 0

b JavaCalls::call_virtual(JavaValue*, Klass*, Symbol*, Symbol*, JavaCallArguments*, Thread*)
commands
silent
set $call_virtual_count = $call_virtual_count + 1
c
end

b JavaCalls::call_special(JavaValue*, Klass*, Symbol*, Symbol*, JavaCallArguments*, Thread*)
commands
silent
set $call_special_count = $call_special_count + 1
c
end

b JavaCalls::call_static(JavaValue*, Klass*, Symbol*, Symbol*, JavaCallArguments*, Thread*)
commands
silent
set $call_static_count = $call_static_count + 1
c
end

b JavaCalls::call(JavaValue*, methodHandle const&, JavaCallArguments*, Thread*)
commands
silent
set $call_count = $call_count + 1
c
end

run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

printf "\n========== JavaCalls Invocation Statistics ==========\n"
printf "call_virtual: %d\n", $call_virtual_count
printf "call_special: %d\n", $call_special_count
printf "call_static:  %d\n", $call_static_count
printf "call (low-level): %d\n", $call_count
printf "total:        %d\n", $call_virtual_count + $call_special_count + $call_static_count + $call_count

quit
