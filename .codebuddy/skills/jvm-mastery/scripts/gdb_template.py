#!/usr/bin/env python3
"""
GDB 脚本生成器 - 自动生成 JVM 数据结构调试脚本

用法:
    python3 gdb_template.py <结构名> [输出目录]

示例:
    python3 gdb_template.py HeapRegion
    python3 gdb_template.py G1CollectedHeap /tmp
"""

import sys
import os
from datetime import datetime

# 预定义的结构体模板
TEMPLATES = {
    "HeapRegion": """set pagination off
set print pretty on

b universe2_init
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# ============ HeapRegion 静态变量 ============
printf "\\n========== HeapRegion Static Variables ==========\\n"
printf "GrainBytes = %lu (0x%lx) = %lu MB\\n", HeapRegion::GrainBytes, HeapRegion::GrainBytes, HeapRegion::GrainBytes/1024/1024
printf "GrainWords = %lu\\n", HeapRegion::GrainWords
printf "LogOfHRGrainBytes = %d\\n", HeapRegion::LogOfHRGrainBytes
printf "CardsPerRegion = %lu\\n", HeapRegion::CardsPerRegion

# ============ 获取实例 ============
set $g1h = (G1CollectedHeap*)Universe::_collectedHeap
set $hrm = &($g1h->_hrm)
set $base = (HeapRegion**)$hrm->_regions._base
set $r0 = $base[0]

printf "\\n========== HeapRegion[0] ==========\\n"
printf "address: %p\\n", $r0
printf "sizeof(HeapRegion): %lu bytes\\n", sizeof(HeapRegion)
printf "_bottom: %p\\n", $r0->_bottom
printf "_end: %p\\n", $r0->_end
printf "_top: %p\\n", $r0->_top
printf "_hrm_index: %u\\n", $r0->_hrm_index
printf "_type._tag: %d\\n", $r0->_type._tag
printf "_rem_set: %p\\n", $r0->_rem_set

quit
""",

    "G1CollectedHeap": """set pagination off
set print pretty on

b universe2_init
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

printf "\\n========== G1CollectedHeap ==========\\n"
set $g1h = (G1CollectedHeap*)Universe::_collectedHeap
printf "address: %p\\n", $g1h
printf "sizeof(G1CollectedHeap): %lu bytes\\n", sizeof(G1CollectedHeap)

printf "\\n--- 核心组件 ---\\n"
printf "_hrm (HeapRegionManager): %p\\n", &($g1h->_hrm)
printf "_hrm._num_committed: %u\\n", $g1h->_hrm._num_committed
printf "_bot (G1BlockOffsetTable): %p\\n", $g1h->_bot
printf "_card_table: %p\\n", $g1h->_card_table
printf "_cm (G1ConcurrentMark): %p\\n", $g1h->_cm
printf "_cr (G1ConcurrentRefine): %p\\n", $g1h->_cr
printf "_g1_policy: %p\\n", $g1h->_g1_policy
printf "_g1_rem_set: %p\\n", $g1h->_g1_rem_set

printf "\\n--- 堆信息 ---\\n"
printf "_g1_reserved: start=%p, end=%p\\n", $g1h->_g1_reserved._start, $g1h->_g1_reserved._word_size

quit
""",

    "G1ConcurrentMark": """set pagination off
set print pretty on

b universe2_init
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

set $g1h = (G1CollectedHeap*)Universe::_collectedHeap
set $cm = $g1h->_cm

printf "\\n========== G1ConcurrentMark ==========\\n"
printf "address: %p\\n", $cm
printf "sizeof(G1ConcurrentMark): %lu bytes\\n", sizeof(G1ConcurrentMark)

printf "\\n--- 位图 ---\\n"
printf "_prev_mark_bitmap: %p\\n", $cm->_prev_mark_bitmap
printf "_next_mark_bitmap: %p\\n", $cm->_next_mark_bitmap

printf "\\n--- 并发标记配置 ---\\n"
printf "_max_num_tasks: %u\\n", $cm->_max_num_tasks
printf "_num_concurrent_workers: %u\\n", $cm->_num_concurrent_workers

quit
""",

    "default": """set pagination off
set print pretty on

b universe2_init
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# TODO: 添加针对 {struct_name} 的调试命令
printf "\\n========== {struct_name} ==========\\n"
printf "请添加具体的调试命令\\n"

quit
"""
}


def generate_script(struct_name: str, output_dir: str = None) -> str:
    """生成 GDB 调试脚本"""
    
    if struct_name in TEMPLATES:
        content = TEMPLATES[struct_name]
    else:
        content = TEMPLATES["default"].replace("{struct_name}", struct_name)
    
    # 添加头部注释
    header = f"""# GDB 调试脚本 - {struct_name}
# 生成时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}
# 标准条件: -Xms8g -Xmx8g -XX:+UseG1GC
#
# 用法:
#   cd /data/workspace/openjdk-cut-new
#   gdb -x {struct_name.lower()}_debug.txt ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java
#

"""
    
    full_content = header + content
    
    # 输出文件
    if output_dir is None:
        output_dir = f"/data/workspace/openjdk-cut-new/jvm-md/tmp-file/{struct_name.lower()}"
    
    os.makedirs(output_dir, exist_ok=True)
    output_path = os.path.join(output_dir, f"gdb_{struct_name.lower()}.txt")
    
    with open(output_path, 'w') as f:
        f.write(full_content)
    
    print(f"已生成: {output_path}")
    return output_path


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        print("\n支持的结构体:")
        for name in TEMPLATES.keys():
            if name != "default":
                print(f"  - {name}")
        sys.exit(1)
    
    struct_name = sys.argv[1]
    output_dir = sys.argv[2] if len(sys.argv) > 2 else None
    
    generate_script(struct_name, output_dir)


if __name__ == "__main__":
    main()
