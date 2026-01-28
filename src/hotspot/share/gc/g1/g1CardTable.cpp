/*
 * Copyright (c) 2001, 2018, Oracle and/or its affiliates. All rights reserved.
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
#include "gc/g1/g1CardTable.hpp"
#include "gc/g1/g1CollectedHeap.inline.hpp"
#include "gc/shared/memset_with_concurrent_readers.hpp"
#include "logging/log.hpp"
#include "runtime/atomic.hpp"
#include "runtime/orderAccess.hpp"

bool G1CardTable::mark_card_deferred(size_t card_index) {
  jbyte val = _byte_map[card_index];
  // It's already processed
  if ((val & (clean_card_mask_val() | deferred_card_val())) == deferred_card_val()) {
    return false;
  }

  // Cached bit can be installed either on a clean card or on a claimed card.
  jbyte new_val = val;
  if (val == clean_card_val()) {
    new_val = (jbyte)deferred_card_val();
  } else {
    if (val & claimed_card_val()) {
      new_val = val | (jbyte)deferred_card_val();
    }
  }
  if (new_val != val) {
    Atomic::cmpxchg(new_val, &_byte_map[card_index], val);
  }
  return true;
}

void G1CardTable::g1_mark_as_young(const MemRegion& mr) {
  jbyte *const first = byte_for(mr.start());
  jbyte *const last = byte_after(mr.last());

  memset_with_concurrent_readers(first, g1_young_gen, last - first);
}

#ifndef PRODUCT
void G1CardTable::verify_g1_young_region(MemRegion mr) {
  verify_region(mr, g1_young_gen,  true);
}
#endif

void G1CardTableChangedListener::on_commit(uint start_idx, size_t num_regions, bool zero_filled) {
  // Default value for a clean card on the card table is -1. So we cannot take advantage of the zero_filled parameter.
  MemRegion mr(G1CollectedHeap::heap()->bottom_addr_for_region(start_idx), num_regions * HeapRegion::GrainWords);
  _card_table->clear(mr);
}
// forcus 初始化卡表,传入了 cardtable_storage
void G1CardTable::initialize(G1RegionToSpaceMapper* mapper) {
    // 为 cardtable_storage 设置监听器
  mapper->set_mapping_changed_listener(&_listener);
  // forcus 设置卡表字节数组大小
  // 对于8GB堆：8GB ÷ 512字节 = 16MB个卡 . 每张卡用1字节表示：_byte_map_size = 16MB
  _byte_map_size = mapper->reserved().byte_size();
  // forcus 计算守护索引和最后有效索引
  // _guard_index = 16M + 1 - 1 = 16M note 该索引的作用是守护
  _guard_index = cards_required(_whole_heap.word_size()) - 1; // _whole_heap.word_size() = 8GB / 8B = 1G个word
  // _last_valid_index = 16M - 1
  // 堆的最后一个有效地址应该映射到 _last_valid_index位置
  _last_valid_index = _guard_index - 1;
  // forcus 获取堆边界(start & end)
  HeapWord* low_bound  = _whole_heap.start();
  HeapWord* high_bound = _whole_heap.end();
  // forcus 设置覆盖区域
  _cur_covered_regions = 1; // G1与传统分代GC的多区域不同,G1采用的是单一覆盖区域
  _covered[0] = _whole_heap; // 保存到_covered[0]中
  // forcus 设置卡表数组指针
  /*
   * 其实该值就是 cardtable_storage 的 _low_boundary (不过在内部会以_low_boundary来创建一个MemRegion对象，然后通过start()来获取这个地址)
   * 面向对象的体现 - 通过MemRegion对象来封装和管理内存区域信息
   * note 这里我混淆了一个概念：mapper中的 _low_boundary 和 _commited 数组了，其实这是两部分空间
   * note _low_boundary指向的地址是用于存储卡表数据的(对于8GB的堆内存,需要16MB的卡表)
   * note _commited是单独的,另外的一个数组
   */
  _byte_map = (jbyte*) mapper->reserved().start();
  // forcus 计算偏移基地址
  /*
   *  low_bound = start(堆起始地址)
   *  _byte_map_base = _byte_map - low_bound >> 9
   *  note 问题: 给定堆中任意地址,如何快速找到对应的card?
   *   传统的做法:
   *     - offset_from_heap_start = heap_address - heap_start
   *     - card_index = offset_from_heap_start >> 9
   *     - return &_byte_map[card_index] - 这里的
   *   优化思路:不要减法,太慢了
   *     创建虚拟数组的起始位置：_byte_map(卡表的起始位置) - low_bound(堆起始位置) >> 9
   *     _byte_map_base = _byte_map - low_bound >> 9
   *     那么现在计算某个堆位置 heap_address 所对于的卡表,只需要通过下面的方式就可以了，不需要通过传统的做法
   *     &_byte_map_base[ heap_address >> 9 ]
   *      = _byte_map_base + heap_address >> 9
   *      = _byte_map - low_bound >> 9  + heap_address >> 9
   *      = _byte_map + (heap_address - low_bound) >> 9 note _byte_map就是卡表的起始地址
   *       [low_bound,low_bound+512) , ..., 如果 heap_address 在这个区间，那么 (heap_address - low_bound) >> 9 计算出来的就是 0 ，也就是_byte_map,也就是第一个卡表项,这是符合预期的
   *       后续的一样的推倒
   *
   */
  _byte_map_base = _byte_map - (uintptr_t(low_bound) >> card_shift);
  assert(byte_for(low_bound) == &_byte_map[0], "Checking start of map");
  assert(byte_for(high_bound-1) <= &_byte_map[_last_valid_index], "Checking end of map");

  log_trace(gc, barrier)("G1CardTable::G1CardTable: ");
  log_trace(gc, barrier)("    &_byte_map[0]: " INTPTR_FORMAT "  &_byte_map[_last_valid_index]: " INTPTR_FORMAT,
                         p2i(&_byte_map[0]), p2i(&_byte_map[_last_valid_index]));
  log_trace(gc, barrier)("    _byte_map_base: " INTPTR_FORMAT,  p2i(_byte_map_base));

}

bool G1CardTable::is_in_young(oop obj) const {
  volatile jbyte* p = byte_for(obj);
  return *p == G1CardTable::g1_young_card_val();
}
