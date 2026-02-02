#!/bin/bash
# 快速编译单个 .cpp 文件
# 用法: ./quick_compile.sh <源文件路径> [--link]

set -e

SRC_FILE="$1"
DO_LINK="$2"

if [ -z "$SRC_FILE" ]; then
    echo "用法: $0 <源文件路径> [--link]"
    echo "示例: $0 src/hotspot/share/gc/shared/workgroup.cpp        # 只编译.o"
    echo "      $0 src/hotspot/share/gc/shared/workgroup.cpp --link # 编译+链接"
    exit 1
fi

BASE_NAME=$(basename "$SRC_FILE" .cpp)
OBJ_DIR="/data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/hotspot/variant-server/libjvm/objs"
OBJ_FILE="$OBJ_DIR/${BASE_NAME}.o"
CMDLINE_FILE="$OBJ_FILE.cmdline"

if [ ! -f "$CMDLINE_FILE" ]; then
    echo "找不到编译命令文件: $CMDLINE_FILE"
    echo "请先完整编译一次: make images"
    exit 1
fi

echo "=== 编译 $SRC_FILE ==="
time ccache /usr/bin/g++ $(cat "$CMDLINE_FILE" | sed 's|^[^ ]* ||')
echo "编译完成: $OBJ_FILE"

if [ "$DO_LINK" = "--link" ]; then
    echo ""
    echo "=== 重新链接 libjvm.so ==="
    cd /data/workspace/openjdk-cut-new
    time make -f make/Main.gmk SPEC=/data/workspace/openjdk-cut-new/build-config/spec.gmk split-hotspot-libs
fi

echo ""
echo "=== 完成 ==="
