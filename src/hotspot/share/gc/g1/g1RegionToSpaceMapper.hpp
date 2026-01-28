/*
 * Copyright (c) 2014, 2018, Oracle and/or its affiliates. All rights reserved.
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

#ifndef SHARE_VM_GC_G1_G1REGIONTOSPACEMAPPER_HPP
#define SHARE_VM_GC_G1_G1REGIONTOSPACEMAPPER_HPP

#include "gc/g1/g1PageBasedVirtualSpace.hpp"
#include "memory/allocation.hpp"
#include "utilities/debug.hpp"

class WorkGang;

class G1MappingChangedListener {
 public:
  // Fired after commit of the memory, i.e. the memory this listener is registered
  // for can be accessed.
  // Zero_filled indicates that the memory can be considered as filled with zero bytes
  // when called.
  /*
   *  内存 commit 后触发
   *  start_idx: 起始 Region 索引
   *  num_regions: Region 数量
   *  zero_filled: 内存是否已零填充
   */
  virtual void on_commit(uint start_idx, size_t num_regions, bool zero_filled) = 0;
};

// Maps region based commit/uncommit requests to the underlying page sized virtual
// space.
class G1RegionToSpaceMapper : public CHeapObj<mtGC> {
 private:
  G1MappingChangedListener* _listener; // forcus 监听器，Region 状态变化时回调 (解耦内存管理和 Region 初始化)
 protected:
  // Backing storage.
  G1PageBasedVirtualSpace _storage; // forcus 底层存储：页级别的虚拟空间管理(封装 commit/uncommit 操作)

  size_t _region_granularity; // Region 粒度（字节）(将 Region 索引转换为页索引)
  // Mapping management
  CHeapBitMap _commit_map; // forcus 位图：记录每个 Region 的 commit 状态 (O(1) 查询某 Region 是否已提交)

  G1RegionToSpaceMapper(ReservedSpace rs, size_t used_size, size_t page_size, size_t region_granularity, size_t commit_factor, MemoryType type);

  void fire_on_commit(uint start_idx, size_t num_regions, bool zero_filled);
 public:
  MemRegion reserved() { return _storage.reserved(); }

  size_t reserved_size() { return _storage.reserved_size(); }
  size_t committed_size() { return _storage.committed_size(); }
  // 设置监听器
  void set_mapping_changed_listener(G1MappingChangedListener* listener) { _listener = listener; }

  virtual ~G1RegionToSpaceMapper() {}

  bool is_committed(uintptr_t idx) const {
    return _commit_map.at(idx);
  }
  // forcus 虚函数,子类必须实现
  virtual void commit_regions(uint start_idx, size_t num_regions = 1, WorkGang* pretouch_workers = NULL) = 0;
  virtual void uncommit_regions(uint start_idx, size_t num_regions = 1) = 0;

  // Creates an appropriate G1RegionToSpaceMapper for the given parameters.
  // The actual space to be used within the given reservation is given by actual_size.
  // This is because some OSes need to round up the reservation size to guarantee
  // alignment of page_size.
  // The byte_translation_factor defines how many bytes in a region correspond to
  // a single byte in the data structure this mapper is for.
  // Eg. in the card table, this value corresponds to the size a single card
  // table entry corresponds to in the heap.
  static G1RegionToSpaceMapper* create_mapper(ReservedSpace rs,
                                              size_t actual_size,
                                              size_t page_size,
                                              size_t region_granularity,
                                              size_t byte_translation_factor,
                                              MemoryType type);
};

#endif // SHARE_VM_GC_G1_G1REGIONTOSPACEMAPPER_HPP
