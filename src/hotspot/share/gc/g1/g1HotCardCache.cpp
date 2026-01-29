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
 *
 *   这个热卡缓存是 G1写屏障优化的核心组件之一
 *   问题场景：
 *       某些内存区域（如热点数据）会被频繁修改，导致：
 *          - 同一张卡被反复标记为"脏"
 *          - 并发精炼线程反复处理同一张卡
 *          - 大量重复工作，浪费 CPU 资源
 *   解决方案：
 *          - 统计每张卡被修改的次数（_card_counts）
 *          - 当修改次数 >= 4 时，认为这是"热卡"
 *          - 热卡不立即精炼，而是放入缓存（_hot_cache）
 *          - 等 GC 暂停时批量处理，减少重复工作
 */
/*
    在上面的注释中又引入了 “精炼” 这个概念：
        精炼（Refinement） 是 G1 GC 中将"脏卡"转换为"记忆集条目"的过程
        简单来说：
            写屏障：标记卡为"脏"（只是说明该卡覆盖的内存区域有引用修改）
            精炼：扫描脏卡，找出跨 Region 的引用，更新目标 Region 的记忆集
        为什么叫"精炼"？
            脏卡只知道"某个 512 字节区域有引用被修改了"
            精炼后知道"具体是哪个对象的哪个字段，指向了哪个 Region"
            从粗粒度变成细粒度，从模糊变成精确

        这里有个问题：卡表和记忆集有什么关系和区别呢？
            卡表：记录"哪里被修改了"，整个堆共享一个，更新时机为写屏障立即更新(更新速度极快，一条指令),粒度为512B
            记忆集：记录"谁引用了我"，每个region一个，更新时机为 精炼线程异步更新(更新慢,需要分析引用)，粒度为卡级别
        G1的核心问题:如何找到所有的引用？回收某个region的时候: 比如其中的一个A对象，如何知道有哪些其他Region的对象还引用了A对象呢？
            全Region遍历,当然没问题，但是是不可能采用这种做法的,性能太差
            同样也是空间换时间的做法，为每个Region维护一个RSet，Rset中记录的是：哪些其他Region中的对象引用了该Region中的对象
 */
G1HotCardCache::G1HotCardCache(G1CollectedHeap *g1h):
  _g1h(g1h), _hot_cache(NULL), _use_cache(false), _card_counts(g1h) {}
// forcus G1HotCardCache 初始化
void G1HotCardCache::initialize(G1RegionToSpaceMapper* card_counts_storage) {
    // forcus 通常都是true
  if (default_use_cache()) { // G1ConcRSLogCacheSize = 10(默认为10)
    _use_cache = true;
    // 计算缓存大小 _hot_cache_size = 1 << 10 = 1024，每个元素是一个指针(8B),总大小为8KB
    // note 热卡缓存默认可以存储 1024个热卡指针
    _hot_cache_size = (size_t)1 << G1ConcRSLogCacheSize;
    // forcus 分配缓存数组,存储 jbyte* 指针(数组大小为1024) - 每个元素是指向卡表中某张卡的指针
    _hot_cache = ArrayAllocator<jbyte*>::allocate(_hot_cache_size, mtGC);
    // 清0操作
    reset_hot_cache_internal();


    // forcus 设置并行处理参数 - 用于多线程并行处理热卡缓存中的卡
    /*
        用于 GC 暂停时多线程并行处理热卡缓存，每个线程一次处理 32 个卡
     */
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
