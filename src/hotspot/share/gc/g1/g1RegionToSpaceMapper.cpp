/*
 * Copyright (c) 2001, 2017, Oracle and/or its affiliates. All rights reserved.
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
#include "gc/g1/g1BiasedArray.hpp"
#include "gc/g1/g1RegionToSpaceMapper.hpp"
#include "memory/allocation.inline.hpp"
#include "memory/virtualspace.hpp"
#include "services/memTracker.hpp"
#include "utilities/align.hpp"
#include "utilities/bitMap.inline.hpp"
// forcus 基类构造函数
G1RegionToSpaceMapper::G1RegionToSpaceMapper(ReservedSpace rs,
                                             size_t used_size,
                                             size_t page_size,
                                             size_t region_granularity,
                                             size_t commit_factor,
                                             MemoryType type) :
  // 成员初始化列表 (C++ 语法)
  _storage(rs, used_size, page_size), // 1. 初始化底层存储 forcus G1PageBasedVirtualSpace
  _region_granularity(region_granularity), // 2. 保存 Region 粒度
  _listener(NULL), // 3. 监听器初始为空
  /*
   * note _commit_map 大小计算
   *  = 堆大小 × 提交因子 / Region大小
   */
  _commit_map(rs.size() * commit_factor / region_granularity, mtGC) {  // 4. 初始化 commit 位图
  guarantee(is_power_of_2(page_size), "must be");
  guarantee(is_power_of_2(region_granularity), "must be");

  MemTracker::record_virtual_memory_type((address)rs.base(), type); // NMT 记录
}

// G1RegionToSpaceMapper implementation where the region granularity is larger than
// or the same as the commit granularity.
// Basically, the space corresponding to one region region spans several OS pages.
class G1RegionsLargerThanCommitSizeMapper : public G1RegionToSpaceMapper {
 private:
  size_t _pages_per_region; // forcus 每个 Region 对应的 Page 数
 // note 先看下基类的构造函数
 public:
  G1RegionsLargerThanCommitSizeMapper(ReservedSpace rs,
                                      size_t actual_size,
                                      size_t page_size,
                                      size_t alloc_granularity,
                                      size_t commit_factor,
                                      MemoryType type) :
    G1RegionToSpaceMapper(rs, actual_size, page_size, alloc_granularity, commit_factor, type), // forcus 父类的构造函数
    _pages_per_region(alloc_granularity / (page_size * commit_factor)) // forcus 每个 Region 对应的 Page 数 ( Region_Size / Page_Size)
  {
    guarantee(alloc_granularity >= page_size, "allocation granularity smaller than commit granularity");
  }
  // forcus 提交 Region
  virtual void commit_regions(uint start_idx, size_t num_regions, WorkGang* pretouch_gang) {
      // 1. 计算起始页号(第一次进来为0)
    size_t const start_page = (size_t)start_idx * _pages_per_region;
      // forcus 调用底层 commit
    bool zero_filled = _storage.commit(start_page, num_regions * _pages_per_region); // total_page = num_regions * _pages_per_region
    // 并行预触摸(默认为false)
    if (AlwaysPreTouch) {
      _storage.pretouch(start_page, num_regions * _pages_per_region, pretouch_gang);
    }
      // forcus 更新 _commit_map 位图 (0 ~ 2048)
      /*
            result:
             _commit_map内存结构（每个字64位）：
                字0: [1111111111111111111111111111111111111111111111111111111111111111] (Region 0-63)
                字1: [1111111111111111111111111111111111111111111111111111111111111111] (Region 64-127)
                ...
                字31:[1111111111111111111111111111111111111111111111111111111111111111] (Region 1984-2047)
       */
    _commit_map.set_range(start_idx, start_idx + num_regions);
      // forcus 触发监听器回调
    fire_on_commit(start_idx, num_regions, zero_filled);
  }

  virtual void uncommit_regions(uint start_idx, size_t num_regions) {
    _storage.uncommit((size_t)start_idx * _pages_per_region, num_regions * _pages_per_region);
    _commit_map.clear_range(start_idx, start_idx + num_regions);
  }
};

// G1RegionToSpaceMapper implementation where the region granularity is smaller
// than the commit granularity.
// Basically, the contents of one OS page span several regions.
class G1RegionsSmallerThanCommitSizeMapper : public G1RegionToSpaceMapper {
 private:
  class CommitRefcountArray : public G1BiasedMappedArray<uint> {
   protected:
     virtual uint default_value() const { return 0; }
  };

  size_t _regions_per_page;

  CommitRefcountArray _refcounts;

  uintptr_t region_idx_to_page_idx(uint region) const {
    return region / _regions_per_page;
  }

 public:
  G1RegionsSmallerThanCommitSizeMapper(ReservedSpace rs,
                                       size_t actual_size,
                                       size_t page_size,
                                       size_t alloc_granularity,
                                       size_t commit_factor,
                                       MemoryType type) :
    G1RegionToSpaceMapper(rs, actual_size, page_size, alloc_granularity, commit_factor, type),
    _regions_per_page((page_size * commit_factor) / alloc_granularity), _refcounts() {

    guarantee((page_size * commit_factor) >= alloc_granularity, "allocation granularity smaller than commit granularity");
    _refcounts.initialize((HeapWord*)rs.base(), (HeapWord*)(rs.base() + align_up(rs.size(), page_size)), page_size);
  }

  virtual void commit_regions(uint start_idx, size_t num_regions, WorkGang* pretouch_gang) {
    size_t const NoPage = ~(size_t)0;

    size_t first_committed = NoPage;
    size_t num_committed = 0;

    bool all_zero_filled = true;

    for (uint i = start_idx; i < start_idx + num_regions; i++) {
      assert(!_commit_map.at(i), "Trying to commit storage at region %u that is already committed", i);
      size_t idx = region_idx_to_page_idx(i);
      uint old_refcount = _refcounts.get_by_index(idx);

      bool zero_filled = false;
      if (old_refcount == 0) {
        if (first_committed == NoPage) {
          first_committed = idx;
          num_committed = 1;
        } else {
          num_committed++;
        }
        zero_filled = _storage.commit(idx, 1);
      }
      all_zero_filled &= zero_filled;

      _refcounts.set_by_index(idx, old_refcount + 1);
      _commit_map.set_bit(i);
    }
    if (AlwaysPreTouch && num_committed > 0) {
      _storage.pretouch(first_committed, num_committed, pretouch_gang);
    }
    fire_on_commit(start_idx, num_regions, all_zero_filled);
  }

  virtual void uncommit_regions(uint start_idx, size_t num_regions) {
    for (uint i = start_idx; i < start_idx + num_regions; i++) {
      assert(_commit_map.at(i), "Trying to uncommit storage at region %u that is not committed", i);
      size_t idx = region_idx_to_page_idx(i);
      uint old_refcount = _refcounts.get_by_index(idx);
      assert(old_refcount > 0, "must be");
      if (old_refcount == 1) {
        _storage.uncommit(idx, 1);
      }
      _refcounts.set_by_index(idx, old_refcount - 1);
      _commit_map.clear_bit(i);
    }
  }
};

void G1RegionToSpaceMapper::fire_on_commit(uint start_idx, size_t num_regions, bool zero_filled) {
  if (_listener != NULL) {
    _listener->on_commit(start_idx, num_regions, zero_filled);
  }
}

G1RegionToSpaceMapper* G1RegionToSpaceMapper::create_mapper(ReservedSpace rs, // 预留堆空间对象
                                                            size_t actual_size, // 堆大小
                                                            size_t page_size, // Page 大小
                                                            size_t region_granularity, // Region 大小
                                                            size_t commit_factor, // 提交因子
                                                            MemoryType type) { // NMT 类型

  if (region_granularity >= (page_size * commit_factor)) {
    // forcus Region >= Page: 一个 Region 包含多个 Page (这是通常的情况)
    // note 不要忘了看基类的构造函数/成员变量
    return new G1RegionsLargerThanCommitSizeMapper(rs, actual_size, page_size, region_granularity, commit_factor, type);
  } else {
    // 大页情况,暂时可以忽略
    return new G1RegionsSmallerThanCommitSizeMapper(rs, actual_size, page_size, region_granularity, commit_factor, type);
  }
}
