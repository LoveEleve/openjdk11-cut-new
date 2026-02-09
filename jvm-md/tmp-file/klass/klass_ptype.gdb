set pagination off
set print pretty on
set confirm off

b instanceKlass.cpp:430
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

ptype /o Klass
ptype /o InstanceKlass
ptype /o ArrayKlass
ptype /o ObjArrayKlass
ptype /o TypeArrayKlass

quit
