/*
 * Copyright (c) 2001, 2016, Oracle and/or its affiliates. All rights reserved.
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This code is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 only, as
 * published by the Free Software Foundation.
 *
 * This code is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * version 2 for more details (a copy is included in the LICENSE file that
 * accompanied this code).
 *
 * You should have received a copy of the GNU General Public License version
 * 2 along with this work; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.
 *
 * Please contact Oracle, 500 Oracle Parkway, Redwood Shores, CA 94065 USA
 * or visit www.oracle.com if you need additional information or have any
 * questions.
 *
 */

#include "precompiled.hpp"
#include "gc/g1/g1Analytics.hpp"
#include "gc/g1/g1CollectorPolicy.hpp"
#include "gc/g1/g1YoungGenSizer.hpp"
#include "gc/g1/heapRegion.hpp"
#include "gc/g1/heapRegionRemSet.hpp"
#include "gc/shared/gcPolicyCounters.hpp"
#include "runtime/globals.hpp"
#include "utilities/debug.hpp"

G1CollectorPolicy::G1CollectorPolicy() {

  // Set up the region size and associated fields. Given that the
  // policy is created before the heap, we have to set this up here,
  // so it's done as soon as possible.

  // It would have been natural to pass initial_heap_byte_size() and
  // max_heap_byte_size() to setup_heap_region_size() but those have
  // not been set up at this point since they should be aligned with
  // the region size. So, there is a circular dependency here. We base
  // the region size on the heap size, but the heap size should be
  // aligned with the region size. To get around this we use the
  // unaligned values for the heap.
  /*
         解决循环依赖：堆大小需要对齐到 Region，Region 大小又依赖堆大小
         所以用未对齐的原始值来计算 Region 大小
         (8GB,8GB) -> HeapRegion::GrainBytes = 4MB (全局静态变量)
   */
  HeapRegion::setup_heap_region_size(InitialHeapSize, MaxHeapSize);
  /*
        设置 RSet 相关大小常量,确定每个 Region 的 RSet 初始容量 - 以 Region_Size = 4MB 为例
            - G1RSetSparseRegionEntries: 12
                - Sparse 表每个 entry 最多存多少张 Card

            - G1RSetRegionEntries: 768
                - Fine-grain 表最多追踪多少个来源 Region
        那么 Sparse / Fine-grain / Coarse 是什么呢？
        这是 G1 RSet（记忆集）的三层存储结构，每个 Region 都有一个 OtherRegionsTable，里面同时包含这三层：
            - 第一层：
            {
                Sparse 表（SparsePRT），记录：哪些 Region 引用了我，以及具体是哪几张 Card
                  Sparse 表结构：
                  来源Region_A → [Card#3, Card#7, Card#12, ...]  ← 最多 12 个 Card
                  来源Region_B → [Card#1, Card#5, ...]
                  来源Region_C → [Card#9, ...]
                  ...
            }
            G1RSetSparseRegionEntries = 12 就是这里用的：每个来源 Region 最多记录 12 张 Card
            优点：精确知道哪张 Card，扫描时只扫这几张 Card，非常快
            缺点：只适合引用很少的情况

            - 第二层：Fine-grain 表（PerRegionTable[]）,记录：哪些 Region 引用了我，用位图精确记录每张 Card
            {
                Fine-grain 表结构（哈希表）：
                  来源Region_A → BitMap[0..CardsPerRegion]  ← 每个 bit 代表一张 Card
                  来源Region_B → BitMap[0..CardsPerRegion]
                  ...
                  最多 768 个来源 Region
                G1RSetRegionEntries = 768 就是这里用的：Fine-grain 表最多追踪 768 个来源 Region
                比 Sparse 更精确（位图覆盖所有 Card），但每个 Region 要分配一个位图，内存更多
            }

            - 第三层：Coarse 位图（CHeapBitMap _coarse_map）,记录：哪些 Region 引用了我（只记 Region，不记具体 Card）
            {
                Coarse 位图：
                  bit[0]=0, bit[1]=1, bit[2]=0, bit[3]=1, ...
                  ↑ Region 0 没引用我   ↑ Region 1 引用了我

                只知道"哪个 Region 引用了我"，不知道具体哪张 Card
                GC 时必须扫描整个 Region，效率最低
                但内存最省（整个堆只需 max_regions / 8 字节）

            }

        forcus
            新引用进来
                ↓
            先放 Sparse 表（精确，省内存）
                ↓ Sparse 表满了（某个来源Region的Card超过12个）
            升级到 Fine-grain 表（精确，中等内存）
                ↓ Fine-grain 表满了（来源Region数超过768个）
            降级到 Coarse 位图（粗糙，最省内存）


        一句话总结
            setup_remset_size() 设置了：
            G1RSetSparseRegionEntries = 12：Sparse 表每个来源 Region 最多记 12 张 Card
            G1RSetRegionEntries = 768：Fine-grain 表最多追踪 768 个来源 Region
            这两个值是 RSet 三层结构的容量阈值，决定什么时候从精确模式降级到粗糙模式。
   */
  HeapRegionRemSet::setup_remset_size();
}

void G1CollectorPolicy::initialize_alignments() {
  _space_alignment = HeapRegion::GrainBytes;
  size_t card_table_alignment = CardTableRS::ct_max_alignment_constraint();
  size_t page_size = UseLargePages ? os::large_page_size() : os::vm_page_size();
  _heap_alignment = MAX3(card_table_alignment, _space_alignment, page_size);
}
