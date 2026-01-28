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

#ifndef SHARE_VM_GC_G1_G1CARDTABLE_HPP
#define SHARE_VM_GC_G1_G1CARDTABLE_HPP

#include "gc/g1/g1RegionToSpaceMapper.hpp"
#include "gc/shared/cardTable.hpp"
#include "oops/oopsHierarchy.hpp"
#include "utilities/macros.hpp"

class G1CardTable;
class G1RegionToSpaceMapper;

class G1CardTableChangedListener : public G1MappingChangedListener {
 private:
  G1CardTable* _card_table; // forcus G1 Card Table
 public:
  G1CardTableChangedListener() : _card_table(NULL) { }

  void set_card_table(G1CardTable* card_table) { _card_table = card_table; }

  virtual void on_commit(uint start_idx, size_t num_regions, bool zero_filled);
};
// forcus G1的卡表实现, 继承自CardTable(通用卡表)
class G1CardTable: public CardTable {
  friend class VMStructs;
  friend class G1CardTableChangedListener;

  G1CardTableChangedListener _listener; // 监听器

  enum G1CardValues {
    g1_young_gen = CT_MR_BS_last_reserved << 1 // forcus G1特有的年轻代卡值
  };

public:
  // forcus G1 卡表构造函数, 第一个参数是整个堆的大小，第二个参数是支持并发扫描卡表(G1默认支持)
  // note 这里会调用父类的构造函数(CardTable)
  G1CardTable(MemRegion whole_heap): CardTable(whole_heap, /* scanned concurrently */ true), _listener() {
    // forcus 将当前卡表对象设置到监听器中
    /*
     * 这个listener的作用:当G1堆中的某个Region被提交(commit)时，自动清理对应的卡表区域 - 初始化为 clean_care = -1
     * note 在这里,commit代表的是什么意思呢？
     *  这里涉及到了虚拟内存的两阶段分配：
     *   1.预留:Reserve - 向OS申请一段虚拟内存空间,这里需要说明一下,是在进程的虚拟地址空间标记这段地址已经被使用,但没有实际分配物理内存(不能直接访问) - note os::reserve_memory(size)
     *   2.提交:commit - 将预留的虚拟地址映射到实际的物理内存 - note os::commit_memory(addr,size)
     *   而G1 GC在jvm启动的时候就预留(Reserve)了整个堆空间,但不会立即提交所有Region
     */
    _listener.set_card_table(this);
  }
  bool is_card_dirty(size_t card_index) {
    return _byte_map[card_index] == dirty_card_val();
  }

  static jbyte g1_young_card_val() { return g1_young_gen; }

/*
   Claimed and deferred bits are used together in G1 during the evacuation
   pause. These bits can have the following state transitions:
   1. The claimed bit can be put over any other card state. Except that
      the "dirty -> dirty and claimed" transition is checked for in
      G1 code and is not used.
   2. Deferred bit can be set only if the previous state of the card
      was either clean or claimed. mark_card_deferred() is wait-free.
      We do not care if the operation is be successful because if
      it does not it will only result in duplicate entry in the update
      buffer because of the "cache-miss". So it's not worth spinning.
 */

  bool is_card_claimed(size_t card_index) {
    jbyte val = _byte_map[card_index];
    return (val & (clean_card_mask_val() | claimed_card_val())) == claimed_card_val();
  }

  inline void set_card_claimed(size_t card_index);

  void verify_g1_young_region(MemRegion mr) PRODUCT_RETURN;
  void g1_mark_as_young(const MemRegion& mr);

  bool mark_card_deferred(size_t card_index);

  bool is_card_deferred(size_t card_index) {
    jbyte val = _byte_map[card_index];
    return (val & (clean_card_mask_val() | deferred_card_val())) == deferred_card_val();
  }

  static size_t compute_size(size_t mem_region_size_in_words) {
    size_t number_of_slots = (mem_region_size_in_words / card_size_in_words);
    return ReservedSpace::allocation_align_size_up(number_of_slots);
  }

  // Returns how many bytes of the heap a single byte of the Card Table corresponds to.
  static size_t heap_map_factor() { return card_size; }

  void initialize() {}
  void initialize(G1RegionToSpaceMapper* mapper);

  virtual void resize_covered_region(MemRegion new_region) { ShouldNotReachHere(); }

  virtual bool is_in_young(oop obj) const;
};

#endif // SHARE_VM_GC_G1_G1CARDTABLE_HPP
