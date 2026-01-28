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
#include "gc/g1/g1CollectedHeap.inline.hpp"
#include "gc/g1/g1ConcurrentRefine.hpp"
#include "gc/g1/heapRegion.hpp"
#include "gc/g1/heapRegionManager.inline.hpp"
#include "gc/g1/heapRegionSet.inline.hpp"
#include "memory/allocation.hpp"
#include "utilities/bitMap.inline.hpp"

void HeapRegionManager::initialize(G1RegionToSpaceMapper* heap_storage,
                               G1RegionToSpaceMapper* prev_bitmap,
                               G1RegionToSpaceMapper* next_bitmap,
                               G1RegionToSpaceMapper* bot,
                               G1RegionToSpaceMapper* cardtable,
                               G1RegionToSpaceMapper* card_counts) {
   // 重置已分配的HeapRegion实例数量计数器
  _allocated_heapregions_length = 0;
  // 保存各种映射器引用(6个)
  _heap_mapper = heap_storage;

  _prev_bitmap_mapper = prev_bitmap;
  _next_bitmap_mapper = next_bitmap;

  _bot_mapper = bot;
  _cardtable_mapper = cardtable;
  _card_counts_mapper = card_counts;

  // forcus  初始化区域表
  // 获取堆存储的预留内存区域(8GB)
  MemRegion reserved = heap_storage->reserved();
  // note 图解-6
  // _regions : G1HeapRegionTable 继承自G1BiasedMappedArray<HeapRegion*>
  // initialize:初始化区域表，建立地址到区域索引的映射(区域数量: 8GB ÷ 4MB = 2048个区域)
  _regions.initialize(reserved.start(), reserved.end(), HeapRegion::GrainBytes);
  // 初始化可用性位图
  // _available_map CHeapBitMap (2048位 = 256字节)
  // 作用: 跟踪每个区域是否可用于分配
  _available_map.initialize(_regions.length());
}
/*
 *  forcus _available_map是一个位图,标记每个Region是否可用
    - `true`：Region已分配并可用
    - `false`：Region未分配或不可用
 */
bool HeapRegionManager::is_available(uint region) const {
  return _available_map.at(region);
}

#ifdef ASSERT
bool HeapRegionManager::is_free(HeapRegion* hr) const {
  return _free_list.contains(hr);
}
#endif

HeapRegion* HeapRegionManager::new_heap_region(uint hrm_index) {
  G1CollectedHeap* g1h = G1CollectedHeap::heap(); // 获取到G1堆引用
  /*
   * forcus 计算Region的内存范围 - 这里与 hrm_index 有关 (这个是Region的下标,代表是第几个Region)
   * bottom = 堆基址(0x600000000) + hrm_index(第几个Region) * HeapRegion::GrainWords(4MB)
   */
  HeapWord* bottom = g1h->bottom_addr_for_region(hrm_index);
  // forcus 创建 MemRegion 对象 - 代表是一段连续的内存区域
  MemRegion mr(bottom, bottom + HeapRegion::GrainWords);
  assert(reserved().contains(mr), "invariant");
  // forcus 创建HeapRegion对象
  return g1h->new_heap_region(hrm_index, mr);
}

void HeapRegionManager::commit_regions(uint index, size_t num_regions, WorkGang* pretouch_gang) {
  guarantee(num_regions > 0, "Must commit more than zero regions");
  guarantee(_num_committed + num_regions <= max_length(), "Cannot commit more than the maximum amount of regions");
  // 更新已提交Region计数 (0 -> 2048)
  _num_committed += (uint)num_regions;
  /*
   * 下面的都是 通过 G1RegionsLargerThanCommitSizeMapper::commit_regions()来提交
   */
  // forcus 提交主堆内存（8GB）
  _heap_mapper->commit_regions(index, num_regions, pretouch_gang);

  // forcus 提交辅助数据结构(5个mapper)
  // Also commit auxiliary data
  _prev_bitmap_mapper->commit_regions(index, num_regions, pretouch_gang);
  _next_bitmap_mapper->commit_regions(index, num_regions, pretouch_gang);

  _bot_mapper->commit_regions(index, num_regions, pretouch_gang);
  _cardtable_mapper->commit_regions(index, num_regions, pretouch_gang);

  _card_counts_mapper->commit_regions(index, num_regions, pretouch_gang);
}

void HeapRegionManager::uncommit_regions(uint start, size_t num_regions) {
  guarantee(num_regions >= 1, "Need to specify at least one region to uncommit, tried to uncommit zero regions at %u", start);
  guarantee(_num_committed >= num_regions, "pre-condition");

  // Print before uncommitting.
  if (G1CollectedHeap::heap()->hr_printer()->is_active()) {
    for (uint i = start; i < start + num_regions; i++) {
      HeapRegion* hr = at(i);
      G1CollectedHeap::heap()->hr_printer()->uncommit(hr);
    }
  }

  _num_committed -= (uint)num_regions;

  _available_map.par_clear_range(start, start + num_regions, BitMap::unknown_range);
  _heap_mapper->uncommit_regions(start, num_regions);

  // Also uncommit auxiliary data
  _prev_bitmap_mapper->uncommit_regions(start, num_regions);
  _next_bitmap_mapper->uncommit_regions(start, num_regions);

  _bot_mapper->uncommit_regions(start, num_regions);
  _cardtable_mapper->uncommit_regions(start, num_regions);

  _card_counts_mapper->uncommit_regions(start, num_regions);
}
// `make_regions_available(0, 2048, _workers)`
void HeapRegionManager::make_regions_available(uint start, uint num_regions, WorkGang* pretouch_gang) {
  guarantee(num_regions > 0, "No point in calling this for zero regions");
  // forcus 提交虚拟内存
  commit_regions(start, num_regions, pretouch_gang);
  // forcus 循环创建HeapRegion对象 (2048个)
  for (uint i = start; i < start + num_regions; i++) {
    if (_regions.get_by_index(i) == NULL) { // forcus 检查_regions数组在索引i位置是否已存在HeapRegion对象,初始时全为NULL
      HeapRegion* new_hr = new_heap_region(i); // forcus 创建HeapRegion对象
      OrderAccess::storestore(); // 内存屏障确保可见性
      // forcus 将新创建的HeapRegion对象指针存储到_regions数组
      /*
       * 建立Region索引到HeapRegion对象的映射关系
       * 后续可通过索引快速查找HeapRegion对象
       */
      _regions.set_by_index(i, new_hr);
      // forcus 记录已分配HeapRegion实例的最大索引+1
      // 与_num_committed（已提交Region数量）不同，这是实例分配的边界
      _allocated_heapregions_length = MAX2(_allocated_heapregions_length, i + 1);
    }
  }
  // forcus 标记Region为可用 (标记指定范围的Region为可用状态)
  // 在这里设置为true(1),标记所有Region为可用
  _available_map.par_set_range(start, start + num_regions, BitMap::unknown_range);
  // forcus 初始化Region并加入空闲列表
  for (uint i = start; i < start + num_regions; i++) {
    assert(is_available(i), "Just made region %u available but is apparently not.", i);
    HeapRegion* hr = at(i);
    // 打印Region提交信息（如果启用）
    if (G1CollectedHeap::heap()->hr_printer()->is_active()) {
      G1CollectedHeap::heap()->hr_printer()->commit(hr);
    }
    // forcus 计算某个Region的内存范围(0~2047)
    HeapWord* bottom = G1CollectedHeap::heap()->bottom_addr_for_region(i);
    MemRegion mr(bottom, bottom + HeapRegion::GrainWords);
    // forcus 初始化Region
    hr->initialize(mr);
    // forcus 加入空闲Region列表 ==> _free_list
    insert_into_free_list(at(i));
  }
}

MemoryUsage HeapRegionManager::get_auxiliary_data_memory_usage() const {
  size_t used_sz =
    _prev_bitmap_mapper->committed_size() +
    _next_bitmap_mapper->committed_size() +
    _bot_mapper->committed_size() +
    _cardtable_mapper->committed_size() +
    _card_counts_mapper->committed_size();

  size_t committed_sz =
    _prev_bitmap_mapper->reserved_size() +
    _next_bitmap_mapper->reserved_size() +
    _bot_mapper->reserved_size() +
    _cardtable_mapper->reserved_size() +
    _card_counts_mapper->reserved_size();

  return MemoryUsage(0, used_sz, committed_sz, committed_sz);
}

uint HeapRegionManager::expand_by(uint num_regions, WorkGang* pretouch_workers) {
  return expand_at(0, num_regions, pretouch_workers);
}


uint HeapRegionManager::expand_at(uint start, uint num_regions, WorkGang* pretouch_workers) {
  // num_regions = 2048
  if (num_regions == 0) {
    return 0;
  }

  uint cur = start; // 当前搜索位置 = 0(start初始就为0)
  uint idx_last_found = 0; // 找到的未分配Region起始索引
  uint num_last_found = 0; // 找到的连续未分配Region数量

  uint expanded = 0; // 已成功扩展的Region数量
  /*
   * forcus 循环查找并分配可用的Region范围
   *  - num_last_found = find_unavailable_from_idx(cur, &idx_last_found): 查找连续的未分配Region
   *    这个方法会影响到两个值
   *     1. num_last_found：2048
   *     2. idx_last_found：0
   *    这表示0～2047个Region都是未分配的,这是符合预期的,因为初始化时时所有的Region都是未分配的
   */
  while (expanded < num_regions &&
         (num_last_found = find_unavailable_from_idx(cur, &idx_last_found)) > 0) {
      // 2048
    uint to_expand = MIN2(num_regions - expanded, num_last_found);
    // forcus 内存分配的核心方法
    make_regions_available(idx_last_found, to_expand, pretouch_workers);
    expanded += to_expand;
    cur = idx_last_found + num_last_found + 1;
  }

  verify_optional();
  return expanded;
}

uint HeapRegionManager::find_contiguous(size_t num, bool empty_only) {
  uint found = 0;
  size_t length_found = 0;
  uint cur = 0;

  while (length_found < num && cur < max_length()) {
    HeapRegion* hr = _regions.get_by_index(cur);
    if ((!empty_only && !is_available(cur)) || (is_available(cur) && hr != NULL && hr->is_empty())) {
      // This region is a potential candidate for allocation into.
      length_found++;
    } else {
      // This region is not a candidate. The next region is the next possible one.
      found = cur + 1;
      length_found = 0;
    }
    cur++;
  }

  if (length_found == num) {
    for (uint i = found; i < (found + num); i++) {
      HeapRegion* hr = _regions.get_by_index(i);
      // sanity check
      guarantee((!empty_only && !is_available(i)) || (is_available(i) && hr != NULL && hr->is_empty()),
                "Found region sequence starting at " UINT32_FORMAT ", length " SIZE_FORMAT
                " that is not empty at " UINT32_FORMAT ". Hr is " PTR_FORMAT, found, num, i, p2i(hr));
    }
    return found;
  } else {
    return G1_NO_HRM_INDEX;
  }
}

HeapRegion* HeapRegionManager::next_region_in_heap(const HeapRegion* r) const {
  guarantee(r != NULL, "Start region must be a valid region");
  guarantee(is_available(r->hrm_index()), "Trying to iterate starting from region %u which is not in the heap", r->hrm_index());
  for (uint i = r->hrm_index() + 1; i < _allocated_heapregions_length; i++) {
    HeapRegion* hr = _regions.get_by_index(i);
    if (is_available(i)) {
      return hr;
    }
  }
  return NULL;
}

void HeapRegionManager::iterate(HeapRegionClosure* blk) const {
  uint len = max_length();

  for (uint i = 0; i < len; i++) {
    if (!is_available(i)) {
      continue;
    }
    guarantee(at(i) != NULL, "Tried to access region %u that has a NULL HeapRegion*", i);
    bool res = blk->do_heap_region(at(i));
    if (res) {
      blk->set_incomplete();
      return;
    }
  }
}

uint HeapRegionManager::find_unavailable_from_idx(uint start_idx, uint* res_idx) const {
  guarantee(res_idx != NULL, "checking");
  guarantee(start_idx <= (max_length() + 1), "checking");

  uint num_regions = 0;

  uint cur = start_idx;
  // forcus is_available()：用来判断某个Region是否可用
  while (cur < max_length() && is_available(cur)) {
    cur++;
  }
  if (cur == max_length()) {
    return num_regions;
  }
  *res_idx = cur;
  while (cur < max_length() && !is_available(cur)) {
    cur++;
  }
  num_regions = cur - *res_idx;
#ifdef ASSERT
  for (uint i = *res_idx; i < (*res_idx + num_regions); i++) {
    assert(!is_available(i), "just checking");
  }
  assert(cur == max_length() || num_regions == 0 || is_available(cur),
         "The region at the current position %u must be available or at the end of the heap.", cur);
#endif
  return num_regions;
}

uint HeapRegionManager::find_highest_free(bool* expanded) {
  // Loop downwards from the highest region index, looking for an
  // entry which is either free or not yet committed.  If not yet
  // committed, expand_at that index.
  uint curr = max_length() - 1;
  while (true) {
    HeapRegion *hr = _regions.get_by_index(curr);
    if (hr == NULL) {
      uint res = expand_at(curr, 1, NULL);
      if (res == 1) {
        *expanded = true;
        return curr;
      }
    } else {
      if (hr->is_free()) {
        *expanded = false;
        return curr;
      }
    }
    if (curr == 0) {
      return G1_NO_HRM_INDEX;
    }
    curr--;
  }
}

bool HeapRegionManager::allocate_containing_regions(MemRegion range, size_t* commit_count, WorkGang* pretouch_workers) {
  size_t commits = 0;
  uint start_index = (uint)_regions.get_index_by_address(range.start());
  uint last_index = (uint)_regions.get_index_by_address(range.last());

  // Ensure that each G1 region in the range is free, returning false if not.
  // Commit those that are not yet available, and keep count.
  for (uint curr_index = start_index; curr_index <= last_index; curr_index++) {
    if (!is_available(curr_index)) {
      commits++;
      expand_at(curr_index, 1, pretouch_workers);
    }
    HeapRegion* curr_region  = _regions.get_by_index(curr_index);
    if (!curr_region->is_free()) {
      return false;
    }
  }

  allocate_free_regions_starting_at(start_index, (last_index - start_index) + 1);
  *commit_count = commits;
  return true;
}

void HeapRegionManager::par_iterate(HeapRegionClosure* blk, HeapRegionClaimer* hrclaimer, const uint start_index) const {
  // Every worker will actually look at all regions, skipping over regions that
  // are currently not committed.
  // This also (potentially) iterates over regions newly allocated during GC. This
  // is no problem except for some extra work.
  const uint n_regions = hrclaimer->n_regions();
  for (uint count = 0; count < n_regions; count++) {
    const uint index = (start_index + count) % n_regions;
    assert(index < n_regions, "sanity");
    // Skip over unavailable regions
    if (!is_available(index)) {
      continue;
    }
    HeapRegion* r = _regions.get_by_index(index);
    // We'll ignore regions already claimed.
    // However, if the iteration is specified as concurrent, the values for
    // is_starts_humongous and is_continues_humongous can not be trusted,
    // and we should just blindly iterate over regions regardless of their
    // humongous status.
    if (hrclaimer->is_region_claimed(index)) {
      continue;
    }
    // OK, try to claim it
    if (!hrclaimer->claim_region(index)) {
      continue;
    }
    bool res = blk->do_heap_region(r);
    if (res) {
      return;
    }
  }
}

uint HeapRegionManager::shrink_by(uint num_regions_to_remove) {
  assert(length() > 0, "the region sequence should not be empty");
  assert(length() <= _allocated_heapregions_length, "invariant");
  assert(_allocated_heapregions_length > 0, "we should have at least one region committed");
  assert(num_regions_to_remove < length(), "We should never remove all regions");

  if (num_regions_to_remove == 0) {
    return 0;
  }

  uint removed = 0;
  uint cur = _allocated_heapregions_length - 1;
  uint idx_last_found = 0;
  uint num_last_found = 0;

  while ((removed < num_regions_to_remove) &&
      (num_last_found = find_empty_from_idx_reverse(cur, &idx_last_found)) > 0) {
    uint to_remove = MIN2(num_regions_to_remove - removed, num_last_found);

    shrink_at(idx_last_found + num_last_found - to_remove, to_remove);

    cur = idx_last_found;
    removed += to_remove;
  }

  verify_optional();

  return removed;
}

void HeapRegionManager::shrink_at(uint index, size_t num_regions) {
#ifdef ASSERT
  for (uint i = index; i < (index + num_regions); i++) {
    assert(is_available(i), "Expected available region at index %u", i);
    assert(at(i)->is_empty(), "Expected empty region at index %u", i);
    assert(at(i)->is_free(), "Expected free region at index %u", i);
  }
#endif
  uncommit_regions(index, num_regions);
}

uint HeapRegionManager::find_empty_from_idx_reverse(uint start_idx, uint* res_idx) const {
  guarantee(start_idx < _allocated_heapregions_length, "checking");
  guarantee(res_idx != NULL, "checking");

  uint num_regions_found = 0;

  jlong cur = start_idx;
  while (cur != -1 && !(is_available(cur) && at(cur)->is_empty())) {
    cur--;
  }
  if (cur == -1) {
    return num_regions_found;
  }
  jlong old_cur = cur;
  // cur indexes the first empty region
  while (cur != -1 && is_available(cur) && at(cur)->is_empty()) {
    cur--;
  }
  *res_idx = cur + 1;
  num_regions_found = old_cur - cur;

#ifdef ASSERT
  for (uint i = *res_idx; i < (*res_idx + num_regions_found); i++) {
    assert(at(i)->is_empty(), "just checking");
  }
#endif
  return num_regions_found;
}

void HeapRegionManager::verify() {
  guarantee(length() <= _allocated_heapregions_length,
            "invariant: _length: %u _allocated_length: %u",
            length(), _allocated_heapregions_length);
  guarantee(_allocated_heapregions_length <= max_length(),
            "invariant: _allocated_length: %u _max_length: %u",
            _allocated_heapregions_length, max_length());

  bool prev_committed = true;
  uint num_committed = 0;
  HeapWord* prev_end = heap_bottom();
  for (uint i = 0; i < _allocated_heapregions_length; i++) {
    if (!is_available(i)) {
      prev_committed = false;
      continue;
    }
    num_committed++;
    HeapRegion* hr = _regions.get_by_index(i);
    guarantee(hr != NULL, "invariant: i: %u", i);
    guarantee(!prev_committed || hr->bottom() == prev_end,
              "invariant i: %u " HR_FORMAT " prev_end: " PTR_FORMAT,
              i, HR_FORMAT_PARAMS(hr), p2i(prev_end));
    guarantee(hr->hrm_index() == i,
              "invariant: i: %u hrm_index(): %u", i, hr->hrm_index());
    // Asserts will fire if i is >= _length
    HeapWord* addr = hr->bottom();
    guarantee(addr_to_region(addr) == hr, "sanity");
    // We cannot check whether the region is part of a particular set: at the time
    // this method may be called, we have only completed allocation of the regions,
    // but not put into a region set.
    prev_committed = true;
    prev_end = hr->end();
  }
  for (uint i = _allocated_heapregions_length; i < max_length(); i++) {
    guarantee(_regions.get_by_index(i) == NULL, "invariant i: %u", i);
  }

  guarantee(num_committed == _num_committed, "Found %u committed regions, but should be %u", num_committed, _num_committed);
  _free_list.verify();
}

#ifndef PRODUCT
void HeapRegionManager::verify_optional() {
  verify();
}
#endif // PRODUCT

HeapRegionClaimer::HeapRegionClaimer(uint n_workers) :
    _n_workers(n_workers), _n_regions(G1CollectedHeap::heap()->_hrm._allocated_heapregions_length), _claims(NULL) {
  assert(n_workers > 0, "Need at least one worker.");
  uint* new_claims = NEW_C_HEAP_ARRAY(uint, _n_regions, mtGC);
  memset(new_claims, Unclaimed, sizeof(*_claims) * _n_regions);
  _claims = new_claims;
}

HeapRegionClaimer::~HeapRegionClaimer() {
  if (_claims != NULL) {
    FREE_C_HEAP_ARRAY(uint, _claims);
  }
}

uint HeapRegionClaimer::offset_for_worker(uint worker_id) const {
  assert(worker_id < _n_workers, "Invalid worker_id.");
  return _n_regions * worker_id / _n_workers;
}

bool HeapRegionClaimer::is_region_claimed(uint region_index) const {
  assert(region_index < _n_regions, "Invalid index.");
  return _claims[region_index] == Claimed;
}

bool HeapRegionClaimer::claim_region(uint region_index) {
  assert(region_index < _n_regions, "Invalid index.");
  uint old_val = Atomic::cmpxchg(Claimed, &_claims[region_index], Unclaimed);
  return old_val == Unclaimed;
}
