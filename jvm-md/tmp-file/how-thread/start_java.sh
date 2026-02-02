#!/bin/bash
cd /data/workspace/openjdk-cut-new/jvm-md/tmp-file/how-thread
/data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
    -Xms8g \
    -Xmx8g \
    -XX:+UseG1GC \
    -Xint \
    -cp . \
    LoopDemo
