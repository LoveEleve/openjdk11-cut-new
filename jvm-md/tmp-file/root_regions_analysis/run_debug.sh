#!/bin/bash
# 运行GDB调试脚本

cd /data/workspace/openjdk-cut-new

gdb -batch \
  -ex "set pagination off" \
  -ex "set print pretty on" \
  -ex "set confirm off" \
  -ex "break G1CMRootRegions::G1CMRootRegions" \
  -ex "break G1CMRootRegions::init" \
  -ex "break g1ConcurrentMark.cpp:440" \
  -ex "run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main" \
  -ex "continue" \
  -ex "continue" \
  -ex "continue" \
  ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
  2>&1 | tee jvm-md/tmp-file/root_regions_analysis/gdb_output.txt
