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

#ifndef SHARE_VM_GC_G1_G1INCSETSTATE_HPP
#define SHARE_VM_GC_G1_G1INCSETSTATE_HPP

#include "gc/g1/g1BiasedArray.hpp"
#include "gc/g1/heapRegion.hpp"

// forcus G1GC中区域状态的核心枚举 - 性能优化的精妙设计
struct InCSetState {
 public:
  // We use different types to represent the state value. Particularly SPARC puts
  // values in structs from "left to right", i.e. MSB to LSB. This results in many
  // unnecessary shift operations when loading and storing values of this type.
  // This degrades performance significantly (>10%) on that platform.
  // Other tested ABIs do not seem to have this problem, and actually tend to
  // favor smaller types, so we use the smallest usable type there.
#ifdef SPARC
  #define CSETSTATE_FORMAT INTPTR_FORMAT
  typedef intptr_t in_cset_state_t;
#else
  #define CSETSTATE_FORMAT "%d"
  typedef int8_t in_cset_state_t;
#endif
 private:
  in_cset_state_t _value;
 public:
  enum {
    // forcus 巧妙的编码设计，优化最常见的性能检查
    // note 最频繁的操作是检查区域是否在CSet中，使用 > 0 检查即可实现
    // Selection of the values were driven to micro-optimize the encoding and
    // frequency of the checks.
    // The most common check is whether the region is in the collection set or not,
    // this encoding allows us to use an > 0 check.
    // The positive values are encoded in increasing generation order, which
    // makes getting the next generation fast by a simple increment. They are also
    // used to index into arrays.
    // The negative values are used for objects requiring various special cases,
    // for example eager reclamation of humongous objects.
    
    // forcus 巨型区域标记，负值用于特殊处理逻辑
    Humongous    = -1,    // The region is humongous
    
    // forcus 默认状态，不在收集集合中，值为0便于快速判断
    NotInCSet    =  0,    // The region is not in the collection set.
    
    // forcus 年轻代区域，正值1，便于 > 0 的CSet检查
    Young        =  1,    // The region is in the collection set and a young region.
    
    // forcus 老年代区域，正值2，按代际递增便于代际转换
    Old          =  2,    // The region is in the collection set and an old region.
    Num
  };

  InCSetState(in_cset_state_t value = NotInCSet) : _value(value) {
    assert(is_valid(), "Invalid state %d", _value);
  }

  in_cset_state_t value() const        { return _value; }

  void set_old()                       { _value = Old; }

  // forcus 关键的状态检查方法 - 在GC热路径上被频繁调用
  bool is_in_cset_or_humongous() const { return is_in_cset() || is_humongous(); }
  
  // forcus 核心优化: 通过 > 0 检查判断是否在CSet中
  // note 这比逐个比较Young和Old快得多，体现了编码设计的巧妙
  bool is_in_cset() const              { return _value > NotInCSet; }

  // forcus 各种状态的快速判断方法
  bool is_humongous() const            { return _value == Humongous; }
  bool is_young() const                { return _value == Young; }
  bool is_old() const                  { return _value == Old; }

#ifdef ASSERT
  bool is_default() const              { return _value == NotInCSet; }
  bool is_valid() const                { return (_value >= Humongous) && (_value < Num); }
  bool is_valid_gen() const            { return (_value >= Young && _value <= Old); }
#endif
};

// forcus G1收集集合快速测试数组 - 实现O(1)的CSet查找
// note 这个类是G1GC性能优化的核心，将O(n)的CSet遍历优化为O(1)的数组访问
//
// Instances of this class are used for quick tests on whether a reference points
// into the collection set and into which generation or is a humongous object
//
// Each of the array's elements indicates whether the corresponding region is in
// the collection set and if so in which generation, or a humongous region.
//
// We use this to speed up reference processing during young collection and
// quickly reclaim humongous objects. For the latter, by making a humongous region
// succeed this test, we sort-of add it to the collection set. During the reference
// iteration closures, when we see a humongous region, we then simply mark it as
// referenced, i.e. live.
class G1InCSetStateFastTestBiasedMappedArray : public G1BiasedMappedArray<InCSetState> {
 protected:
  // forcus 默认值为NotInCSet，确保初始状态下所有区域都不在CSet中
  InCSetState default_value() const { return InCSetState::NotInCSet; }
 public:
  // forcus 设置指定区域为巨型区域
  // note 巨型区域在引用处理时会被特殊对待，通过这种方式"加入"到CSet中
  void set_humongous(uintptr_t index) {
    assert(get_by_index(index).is_default(),
           "State at index " INTPTR_FORMAT " should be default but is " CSETSTATE_FORMAT, index, get_by_index(index).value());
    set_by_index(index, InCSetState::Humongous);
  }

  void clear_humongous(uintptr_t index) {
    set_by_index(index, InCSetState::NotInCSet);
  }

  void set_in_young(uintptr_t index) {
    assert(get_by_index(index).is_default(),
           "State at index " INTPTR_FORMAT " should be default but is " CSETSTATE_FORMAT, index, get_by_index(index).value());
    set_by_index(index, InCSetState::Young);
  }

  void set_in_old(uintptr_t index) {
    assert(get_by_index(index).is_default(),
           "State at index " INTPTR_FORMAT " should be default but is " CSETSTATE_FORMAT, index, get_by_index(index).value());
    set_by_index(index, InCSetState::Old);
  }

  // forcus 核心的快速查询方法 - 在GC热路径上被大量调用
  // note 通过地址直接获取区域的CSet状态，实现O(1)查找
  bool is_in_cset_or_humongous(HeapWord* addr) const { return at(addr).is_in_cset_or_humongous(); }
  bool is_in_cset(HeapWord* addr) const { return at(addr).is_in_cset(); }
  bool is_in_cset(const HeapRegion* hr) const { return get_by_index(hr->hrm_index()).is_in_cset(); }
  
  // forcus 通过地址获取InCSetState，底层调用get_by_address实现O(1)访问
  InCSetState at(HeapWord* addr) const { return get_by_address(addr); }
  
  // forcus 清理方法
  void clear() { G1BiasedMappedArray<InCSetState>::clear(); }
  void clear(const HeapRegion* hr) { return set_by_index(hr->hrm_index(), InCSetState::NotInCSet); }
};

#endif // SHARE_VM_GC_G1_G1INCSETSTATE_HPP
