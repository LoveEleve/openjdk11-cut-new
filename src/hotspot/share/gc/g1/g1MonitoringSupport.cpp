/*
 * Copyright (c) 2011, 2018, Oracle and/or its affiliates. All rights reserved.
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
#include "gc/g1/g1MonitoringSupport.hpp"
#include "gc/g1/g1Policy.hpp"
#include "gc/shared/collectorCounters.hpp"
#include "gc/shared/hSpaceCounters.hpp"
#include "memory/metaspaceCounters.hpp"

G1GenerationCounters::G1GenerationCounters(G1MonitoringSupport *g1mm,
                                           const char *name,
                                           int ordinal, int spaces,
                                           size_t min_capacity,
                                           size_t max_capacity,
                                           size_t curr_capacity)
        : GenerationCounters(name, ordinal, spaces, min_capacity,
                             max_capacity, curr_capacity), _g1mm(g1mm) {}

// We pad the capacity three times given that the young generation
// contains three spaces (eden and two survivors).
G1YoungGenerationCounters::G1YoungGenerationCounters(G1MonitoringSupport *g1mm,
                                                     const char *name)
        : G1GenerationCounters(g1mm, name,
                               0 /* ordinal */, // 代的序号，年轻代是第 0 代 / 效果: 创建命名空间 "generation.0" / jstat 名称: sun.gc.generation.0.*
                               3 /* spaces */, // 这个代包含 3 个空间 / space.0 = Eden / space.1 = Survivor S0 (G1 不用，但为了兼容 jstat) / space.2 = Survivor S1 / jstat: sun.gc.generation.0.spaces = 3
                               G1MonitoringSupport::pad_capacity(0, 3) /* min_capacity */, // 年轻代最小容量 = 24 bytes（只是 padding）
                               G1MonitoringSupport::pad_capacity(g1mm->young_gen_max(), 3),
                               G1MonitoringSupport::pad_capacity(0, 3) /* curr_capacity */) {
    if (UsePerfData) {
        update_all();
    }
}

G1OldGenerationCounters::G1OldGenerationCounters(G1MonitoringSupport *g1mm,
                                                 const char *name)
        : G1GenerationCounters(g1mm, name,
                               1 /* ordinal */,   // ordinal=1 (老年代序号)
                               1 /* spaces */, // spaces=1 (只有1个空间)
                               G1MonitoringSupport::pad_capacity(0) /* min_capacity */,
                               G1MonitoringSupport::pad_capacity(g1mm->old_gen_max()), // max_capacity = 8GB
                               G1MonitoringSupport::pad_capacity(0) /* curr_capacity */) { // curr_capacity
    if (UsePerfData) {
        update_all(); // 立即更新当前容量
    }
}

void G1YoungGenerationCounters::update_all() {
    size_t committed =
            G1MonitoringSupport::pad_capacity(_g1mm->young_gen_committed(), 3);
    _current_size->set_value(committed);
}

void G1OldGenerationCounters::update_all() {
    size_t committed =
            G1MonitoringSupport::pad_capacity(_g1mm->old_gen_committed());
    _current_size->set_value(committed);
}
/*
    jstat列    含义             G1MonitoringSupport 字段/计数器                调试值
    S0C     Survivor 0       容量 _from_counters->capacity                  8 bytes
    S1C     Survivor 1       容量 _to_counters->capacity                    8 bytes
    S0U     Survivor 0       使用 _from_counters->used                      0
    S1U     Survivor 1       使用 _to_counters->used                        0
    EC      Eden 容量         _eden_counters->capacity                      432 MB
    EU      Eden 使用         _eden_counters->used                          0
    OC      Old 容量          _old_space_counters->capacity                 7.58 GB
    OU      Old 使用          _old_space_counters->used                     0
    YGC     Young GC 次数     _incremental_collection_counters->invocations 0
    YGCT    Young GC 耗时     _incremental_collection_counters->time        0
    FGC     ull GC 次数       _full_collection_counters->invocations        0
    FGCT    Full GC 耗时      _full_collection_counters->time               0
    GCT     总 GC 耗时        YGCT + FGCT                                   0
 */
G1MonitoringSupport::G1MonitoringSupport(G1CollectedHeap *g1h) :
        _g1h(g1h), // 保存 g1h 指针
        // -- 初始化所有计数器指针为 NULL
        _incremental_collection_counters(NULL),
        _full_collection_counters(NULL),
        _conc_collection_counters(NULL),
        _old_collection_counters(NULL),
        _old_space_counters(NULL),
        _young_collection_counters(NULL),
        _eden_counters(NULL),
        _from_counters(NULL),
        _to_counters(NULL),

        _overall_reserved(0),
        _overall_committed(0), _overall_used(0),
        _young_region_num(0),
        _young_gen_committed(0),
        _eden_committed(0), _eden_used(0),
        _survivor_committed(0), _survivor_used(0),
        _old_committed(0), _old_used(0) {

    _overall_reserved = g1h->max_capacity(); // 8GB
    /*
          forcus 计算各区域大小
              获取 young/survivor/eden region 数量
              计算 _eden_used, _survivor_used, _old_used
              计算 _eden_committed, _survivor_committed, _old_committed
     */
    recalculate_sizes();

    // Counters for GC collections
    //
    //  name "collector.0".  In a generational collector this would be the
    // young generation collection.
    /*
          forcus 创建 GC 收集器计数器 (CollectorCounters)
              collector.0: G1 incremental collections (Young/Mixed GC) -- 年轻代/混合GC 计数
              collector.1: G1 stop-the-world full collections (Full GC) -- Full GC 计数
              collector.2: G1 stop-the-world phases (并发GC的STW阶段) -- 并发GC的STW阶段计数
     */
    _incremental_collection_counters =
            new CollectorCounters("G1 incremental collections", 0);
    //   name "collector.1".  In a generational collector this would be the
    // old generation collection.
    _full_collection_counters =
            new CollectorCounters("G1 stop-the-world full collections", 1);
    //   name "collector.2".  In a generational collector this would be the
    // STW phases in concurrent collection.
    _conc_collection_counters =
            new CollectorCounters("G1 stop-the-world phases", 2);

    // timer sampling for all counters supporting sampling only update the
    // used value.  See the take_sample() method.  G1 requires both used and
    // capacity updated so sampling is not currently used.  It might
    // be sufficient to update all counters in take_sample() even though
    // take_sample() only returns "used".  When sampling was used, there
    // were some anomolous values emitted which may have been the consequence
    // of not updating all values simultaneously (i.e., see the calculation done
    // in eden_space_used(), is it possible that the values used to
    // calculate either eden_used or survivor_used are being updated by
    // the collector when the sample is being done?).
    const bool sampled = false;

    // "Generation" and "Space" counters.
    //
    //  name "generation.1" This is logically the old generation in
    // generational GC terms.  The "1, 1" parameters are for
    // the n-th generation (=1) with 1 space.
    // Counters are created from minCapacity, maxCapacity, and capacity
    /*
          forcus 创建代空间计数器 (GenerationCounters)
     */
    // generation.1 - 老年代
    _old_collection_counters = new G1OldGenerationCounters(this, "old");

    //  name  "generation.1.space.0"
    // Counters are created from maxCapacity, capacity, initCapacity,
    // and used.
    // generation.1.space.0 - 老年代空间
    _old_space_counters = new HSpaceCounters(_old_collection_counters->name_space(),
                                             "space", 0 /* ordinal */,
                                             pad_capacity(overall_reserved()) /* max_capacity */, // max = 8GB + padding
                                             pad_capacity(
                                                     old_space_committed()) /* init_capacity */);  // init = 7.58GB + padding

    //   Young collection set
    //  name "generation.0".  This is logically the young generation.
    //  The "0, 3" are parameters for the n-th generation (=0) with 3 spaces.
    // See  _old_collection_counters for additional counters
    // generation.0 - 年轻代
    _young_collection_counters = new G1YoungGenerationCounters(this, "young");

    const char *young_collection_name_space = _young_collection_counters->name_space();


    //  name "generation.0.space.0"
    // See _old_space_counters for additional counters
    // generation.0.space.0 - Eden
    _eden_counters = new HSpaceCounters(young_collection_name_space,
                                        "eden", 0 /* ordinal */,
                                        pad_capacity(overall_reserved()) /* max_capacity */, // max = 8GB
                                        pad_capacity(eden_space_committed()) /* init_capacity */); // init = 432MB

    //  name "generation.0.space.1"
    // See _old_space_counters for additional counters
    // Set the arguments to indicate that this survivor space is not used.
    // generation.0.space.1 - Survivor S0 (G1中未使用!)
    // forcus G1 不像传统分代 GC 那样在 S0/S1 之间复制对象。G1 的 Survivor 是一组离散的 Region，不区分 from/to，所以只用 S1 来表示所有 Survivor Region。
    _from_counters = new HSpaceCounters(young_collection_name_space,
                                        "s0", 1 /* ordinal */,
                                        pad_capacity(0) /* max_capacity */, // max = 0 (不用)
                                        pad_capacity(0) /* init_capacity */); // init = 0

    //  name "generation.0.space.2"
    // See _old_space_counters for additional counters
    // generation.0.space.2 - Survivor S1 (真正使用的Survivor)
    _to_counters = new HSpaceCounters(young_collection_name_space,
                                      "s1", 2 /* ordinal */,
                                      pad_capacity(overall_reserved()) /* max_capacity */, // max = 8GB
                                      pad_capacity(survivor_space_committed()) /* init_capacity */);  // init = 0

    if (UsePerfData) {
        // Given that this survivor space is not used, we update it here
        // once to reflect that its used space is 0 so that we don't have to
        // worry about updating it again later.
        _from_counters->update_used(0);
    }
}

void G1MonitoringSupport::recalculate_sizes() {
    // Recalculate all the sizes from scratch. We assume that this is
    // called at a point where no concurrent updates to the various
    // values we read here are possible (i.e., at a STW phase at the end
    // of a GC).
    // forcus-1 获取 Region 数量
    uint young_list_length = _g1h->young_regions_count(); // 初始=0
    uint survivor_list_length = _g1h->survivor_regions_count(); // 初始=0
    assert(young_list_length >= survivor_list_length, "invariant");
    uint eden_list_length = young_list_length - survivor_list_length; // 初始=0
    // Max length includes any potential extensions to the young gen
    // we'll do when the GC locker is active.
    uint young_list_max_length = _g1h->g1_policy()->young_list_max_length(); // =108
    assert(young_list_max_length >= survivor_list_length, "invariant");
    uint eden_list_max_length = young_list_max_length - survivor_list_length; // =108

    // forcus-2 计算使用量 (used)
    _overall_used = _g1h->used_unlocked(); // 初始=0
    _eden_used = (size_t) eden_list_length * HeapRegion::GrainBytes; // =0
    _survivor_used = (size_t) survivor_list_length * HeapRegion::GrainBytes; // =0
    _young_region_num = young_list_length;
    _old_used = subtract_up_to_zero(_overall_used, _eden_used + _survivor_used); // =0

    // forcus-3 计算提交量 (committed)
    // First calculate the committed sizes that can be calculated independently.
    _survivor_committed = _survivor_used; // =0
    _old_committed = HeapRegion::align_up_to_region_byte_size(_old_used); // =0

    // Next, start with the overall committed size.
    _overall_committed = _g1h->capacity(); // =8GB
    size_t committed = _overall_committed; // 8GB

    // Remove the committed size we have calculated so far (for the
    // survivor and old space).
    assert(committed >= (_survivor_committed + _old_committed), "sanity");
    committed -= _survivor_committed + _old_committed;

    // Next, calculate and remove the committed size for the eden.
    _eden_committed = (size_t) eden_list_max_length * HeapRegion::GrainBytes; // 432MB = 108 × 4MB
    // Somewhat defensive: be robust in case there are inaccuracies in
    // the calculations
    _eden_committed = MIN2(_eden_committed, committed);
    committed -= _eden_committed; // 7.58GB

    // Finally, give the rest to the old space...
    _old_committed += committed; // 7.58GB
    // ..and calculate the young gen committed.
    _young_gen_committed = _eden_committed + _survivor_committed; // 432MB

    assert(_overall_committed ==
           (_eden_committed + _survivor_committed + _old_committed),
           "the committed sizes should add up");
    // Somewhat defensive: cap the eden used size to make sure it
    // never exceeds the committed size.
    _eden_used = MIN2(_eden_used, _eden_committed);
    // _survivor_committed and _old_committed are calculated in terms of
    // the corresponding _*_used value, so the next two conditions
    // should hold.
    assert(_survivor_used <= _survivor_committed, "post-condition");
    assert(_old_used <= _old_committed, "post-condition");
}

void G1MonitoringSupport::recalculate_eden_size() {
    // When a new eden region is allocated, only the eden_used size is
    // affected (since we have recalculated everything else at the last GC).

    uint young_region_num = _g1h->young_regions_count();
    if (young_region_num > _young_region_num) {
        uint diff = young_region_num - _young_region_num;
        _eden_used += (size_t) diff * HeapRegion::GrainBytes;
        // Somewhat defensive: cap the eden used size to make sure it
        // never exceeds the committed size.
        _eden_used = MIN2(_eden_used, _eden_committed);
        _young_region_num = young_region_num;
    }
}

void G1MonitoringSupport::update_sizes() {
    recalculate_sizes();
    if (UsePerfData) {
        eden_counters()->update_capacity(pad_capacity(eden_space_committed()));
        eden_counters()->update_used(eden_space_used());
        // only the to survivor space (s1) is active, so we don't need to
        // update the counters for the from survivor space (s0)
        to_counters()->update_capacity(pad_capacity(survivor_space_committed()));
        to_counters()->update_used(survivor_space_used());
        old_space_counters()->update_capacity(pad_capacity(old_space_committed()));
        old_space_counters()->update_used(old_space_used());
        old_collection_counters()->update_all();
        young_collection_counters()->update_all();
        MetaspaceCounters::update_performance_counters();
        CompressedClassSpaceCounters::update_performance_counters();
    }
}

void G1MonitoringSupport::update_eden_size() {
    recalculate_eden_size();
    if (UsePerfData) {
        eden_counters()->update_used(eden_space_used());
    }
}
