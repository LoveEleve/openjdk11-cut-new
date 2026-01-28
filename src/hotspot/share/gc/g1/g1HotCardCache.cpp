/*
 * Copyright (c) 2013, 2017, Oracle and/or its affiliates. All rights reserved.
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
#include "gc/g1/dirtyCardQueue.hpp"
#include "gc/g1/g1CollectedHeap.inline.hpp"
#include "gc/g1/g1HotCardCache.hpp"
#include "runtime/atomic.hpp"

/*
 * 构造函数:
 *   _g1h(g1h):指向 G1CollectedHeap 的指针
 *   _hot_cache:热卡缓存数组（后续 initialize 分配）
 *   _use_cache:是否启用缓存（后续 initialize 设置）
 *   _card_counts:卡计数器，记录每张卡被修改的次数
 */
G1HotCardCache::G1HotCardCache(G1CollectedHeap *g1h):
  _g1h(g1h), _hot_cache(NULL), _use_cache(false), _card_counts(g1h) {}
// forcus G1HotCardCache 初始化
void G1HotCardCache::initialize(G1RegionToSpaceMapper* card_counts_storage) {
    // forcus 通常都是true
  if (default_use_cache()) { // G1ConcRSLogCacheSize = 10(默认为10)
    _use_cache = true;
    // 计算缓存大小 _hot_cache_size = 1 << 10 = 1024
    // note 热卡缓存默认可以存储 1024个热卡指针
    _hot_cache_size = (size_t)1 << G1ConcRSLogCacheSize;
    // forcus 分配缓存数组,存储 jbyte* 指针(数组大小为1024) - 每个元素是指向卡表中某张卡的指针
    _hot_cache = ArrayAllocator<jbyte*>::allocate(_hot_cache_size, mtGC);
    // 清0操作
    reset_hot_cache_internal();


    // forcus 设置并行处理参数 - 用于多线程并行处理热卡缓存中的卡
    // For refining the cards in the hot cache in parallel
    _hot_cache_par_chunk_size = ClaimChunkSize; // 并行处理时每个线程处理的块大小
    _hot_cache_par_claimed_idx = 0; // 并行处理时的索引计数器
    // forcus 初始化G1CardCounts  使用 card_counts_storage 提供的内存空间
    /*
     * 热卡缓存的工作原理：
            热卡：被频繁修改的卡（跨代引用频繁的区域）
            通过 G1CardCounts 统计每张卡的修改次数
            超过阈值 G1ConcRSHotCardLimit（默认4次）的卡被认为是热卡
     */
    _card_counts.initialize(card_counts_storage);
  }
}

G1HotCardCache::~G1HotCardCache() {
  if (default_use_cache()) {
    assert(_hot_cache != NULL, "Logic");
    ArrayAllocator<jbyte*>::free(_hot_cache, _hot_cache_size);
    _hot_cache = NULL;
  }
}

jbyte* G1HotCardCache::insert(jbyte* card_ptr) {
  uint count = _card_counts.add_card_count(card_ptr);
  if (!_card_counts.is_hot(count)) {
    // The card is not hot so do not store it in the cache;
    // return it for immediate refining.
    return card_ptr;
  }
  // Otherwise, the card is hot.
  size_t index = Atomic::add(1u, &_hot_cache_idx) - 1;
  size_t masked_index = index & (_hot_cache_size - 1);
  jbyte* current_ptr = _hot_cache[masked_index];

  // Try to store the new card pointer into the cache. Compare-and-swap to guard
  // against the unlikely event of a race resulting in another card pointer to
  // have already been written to the cache. In this case we will return
  // card_ptr in favor of the other option, which would be starting over. This
  // should be OK since card_ptr will likely be the older card already when/if
  // this ever happens.
  jbyte* previous_ptr = Atomic::cmpxchg(card_ptr,
                                        &_hot_cache[masked_index],
                                        current_ptr);
  return (previous_ptr == current_ptr) ? previous_ptr : card_ptr;
}

void G1HotCardCache::drain(CardTableEntryClosure* cl, uint worker_i) {
  assert(default_use_cache(), "Drain only necessary if we use the hot card cache.");

  assert(_hot_cache != NULL, "Logic");
  assert(!use_cache(), "cache should be disabled");

  while (_hot_cache_par_claimed_idx < _hot_cache_size) {
    size_t end_idx = Atomic::add(_hot_cache_par_chunk_size,
                                 &_hot_cache_par_claimed_idx);
    size_t start_idx = end_idx - _hot_cache_par_chunk_size;
    // The current worker has successfully claimed the chunk [start_idx..end_idx)
    end_idx = MIN2(end_idx, _hot_cache_size);
    for (size_t i = start_idx; i < end_idx; i++) {
      jbyte* card_ptr = _hot_cache[i];
      if (card_ptr != NULL) {
        bool result = cl->do_card_ptr(card_ptr, worker_i);
        assert(result, "Closure should always return true");
      } else {
        break;
      }
    }
  }

  // The existing entries in the hot card cache, which were just refined
  // above, are discarded prior to re-enabling the cache near the end of the GC.
}

void G1HotCardCache::reset_card_counts(HeapRegion* hr) {
  _card_counts.clear_region(hr);
}
