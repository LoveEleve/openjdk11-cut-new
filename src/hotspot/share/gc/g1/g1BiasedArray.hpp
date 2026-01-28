/*
 * Copyright (c) 2013, 2018, Oracle and/or its affiliates. All rights reserved.
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

#ifndef SHARE_VM_GC_G1_G1BIASEDARRAY_HPP
#define SHARE_VM_GC_G1_G1BIASEDARRAY_HPP

#include "memory/memRegion.hpp"
#include "utilities/debug.hpp"

// Implements the common base functionality for arrays that contain provisions
// for accessing its elements using a biased index.
// The element type is defined by the instantiating the template.
class G1BiasedMappedArrayBase {
  friend class VMStructs;
public:
  typedef size_t idx_t;
protected:
  address _base;          // the real base address
  size_t _length;         // the length of the array
  address _biased_base;   // base address biased by "bias" elements
  size_t _bias;           // the bias, i.e. the offset biased_base is located to the right in elements
  uint _shift_by;         // the amount of bits to shift right when mapping to an index of the array.

protected:

  G1BiasedMappedArrayBase() : _base(NULL), _length(0), _biased_base(NULL),
    _bias(0), _shift_by(0) { }

  // Allocate a new array, generic version.
  static address create_new_base_array(size_t length, size_t elem_size);

  // Initialize the members of this class. The biased start address of this array
  // is the bias (in elements) multiplied by the element size.
  // forcus 初始化偏置数组的核心字段 - 建立快速地址映射机制
  void initialize_base(address base, size_t length, size_t bias, size_t elem_size, uint shift_by) {
    assert(base != NULL, "just checking");
    assert(length > 0, "just checking");
    assert(shift_by < sizeof(uintptr_t) * 8, "Shifting by %u, larger than word size?", shift_by);
    
    // forcus 保存实际数组的起始地址
    _base = base; // 指向malloc分配的内存起始位置
    
    // forcus 保存数组长度(区域总数)
    _length = length; // 例如: 2048个区域
    
    // forcus 计算偏置基地址 - 这是性能优化的关键
    // note 通过预先减去偏移量，后续访问时可以直接用地址索引，无需减法运算
    // 后续直接访问 _biased_base[heap_size >> 22] 即可
    _biased_base = base - (bias * elem_size); // _base - (0x1800 * 元素大小)
    
    // forcus 保存地址偏移量
    _bias = bias; // 0x1800 (堆起始地址 / 4MB = 堆起始地址对应的区域索引)
    
    // forcus 保存右移位数，用于快速地址转换
    // note log2(4MB) = 22位，地址右移22位等效于除以4MB，但比除法快得多
    _shift_by = shift_by; // 22 (因为所有Region都是4MB对齐的)
  }

  // Allocate and initialize this array to cover the heap addresses in the range
  // of [bottom, end).
  // forcus 偏置数组初始化方法 - G1GC性能优化的核心数据结构
  // note 参数说明: bottom=堆起始地址, end=堆结束地址, target_elem_size_in_bytes=元素大小, mapping_granularity_in_bytes=映射粒度(4MB)
  void initialize(HeapWord* bottom, HeapWord* end, size_t target_elem_size_in_bytes, size_t mapping_granularity_in_bytes) {

    assert(mapping_granularity_in_bytes > 0, "just checking");
    assert(is_power_of_2(mapping_granularity_in_bytes),
           "mapping granularity must be power of 2, is " SIZE_FORMAT, mapping_granularity_in_bytes);
    assert((uintptr_t)bottom % mapping_granularity_in_bytes == 0,
           "bottom mapping area address must be a multiple of mapping granularity " SIZE_FORMAT ", is  " PTR_FORMAT,
           mapping_granularity_in_bytes, p2i(bottom));
    assert((uintptr_t)end % mapping_granularity_in_bytes == 0,
           "end mapping area address must be a multiple of mapping granularity " SIZE_FORMAT ", is " PTR_FORMAT,
           mapping_granularity_in_bytes, p2i(end));
    
    // forcus 计算需要映射的区域总数 = (堆大小) / (区域大小)
    // note 例如: 8GB堆 / 4MB区域 = 2048个区域
    size_t num_target_elems = pointer_delta(end, bottom, mapping_granularity_in_bytes);

    /*
     * 这里和之前讲解的逻辑是一样的,为了避免分配大数组,这里提前计算出bias偏移量
     */
    // forcus 计算地址偏移量，用于实现O(1)地址到索引的转换
    // note 例如: 堆起始地址0x600000000 / 4MB = 0x1800 (6144)，这个偏移量让我们可以直接通过地址计算数组索引
    idx_t bias = (uintptr_t)bottom / mapping_granularity_in_bytes;
    
    // forcus 分配实际的数组内存
    // note 为所有区域分配对应的数组元素，InCSetState数组占用2048字节(数组长度为2048)
    address base = create_new_base_array(num_target_elems, target_elem_size_in_bytes);
    
    // forcus 初始化偏置数组的核心字段
    // note 设置_base、_length、_biased_base、_bias、_shift_by等，建立快速访问机制
    initialize_base(base, num_target_elems, bias, target_elem_size_in_bytes, log2_intptr(mapping_granularity_in_bytes));
  }

  size_t bias() const { return _bias; }
  uint shift_by() const { return _shift_by; }

  void verify_index(idx_t index) const PRODUCT_RETURN;
  void verify_biased_index(idx_t biased_index) const PRODUCT_RETURN;
  void verify_biased_index_inclusive_end(idx_t biased_index) const PRODUCT_RETURN;

public:
   // Return the length of the array in elements.
   size_t length() const { return _length; }
};

// Array that provides biased access and mapping from (valid) addresses in the
// heap into this array.
template<class T>
class G1BiasedMappedArray : public G1BiasedMappedArrayBase {
public:
  typedef G1BiasedMappedArrayBase::idx_t idx_t;

  T* base() const { return (T*)G1BiasedMappedArrayBase::_base; }
  // Return the element of the given array at the given index. Assume
  // the index is valid. This is a convenience method that does sanity
  // checking on the index.
  T get_by_index(idx_t index) const {
    verify_index(index);
    return this->base()[index];
  }

  // Set the element of the given array at the given index to the
  // given value. Assume the index is valid. This is a convenience
  // method that does sanity checking on the index.
  void set_by_index(idx_t index, T value) {
    verify_index(index);
    this->base()[index] = value;
  }

  // The raw biased base pointer.
  T* biased_base() const { return (T*)G1BiasedMappedArrayBase::_biased_base; }

  // forcus 通过堆地址获取对应的数组元素 - G1GC性能优化的核心方法
  // note 这是热路径上的关键操作，在GC过程中会被频繁调用
  T get_by_address(HeapWord* value) const {
    // forcus 核心优化: 通过地址右移直接计算数组索引
    // note 右移22位等效于除以4MB，但比除法运算快得多，利用了G1区域4MB对齐的特性
    idx_t biased_index = ((uintptr_t)value) >> this->shift_by();
    this->verify_biased_index(biased_index);
    
    // forcus 直接通过偏置基地址访问，实现真正的O(1)访问
    // note biased_base已经预先减去了偏移量，无需额外的减法运算
    return biased_base()[biased_index];
  }

  // Return the index of the element of the given array that covers the given
  // word in the heap.
  idx_t get_index_by_address(HeapWord* value) const {
    idx_t biased_index = ((uintptr_t)value) >> this->shift_by();
    this->verify_biased_index(biased_index);
    return biased_index - _bias;
  }

  // forcus 通过堆地址设置对应的数组元素值
  // note 用于更新区域状态，如标记区域进入CSet或设置为巨型区域
  void set_by_address(HeapWord * address, T value) {
    // forcus 同样使用右移快速计算索引
    idx_t biased_index = ((uintptr_t)address) >> this->shift_by();
    this->verify_biased_index(biased_index);
    // forcus 直接通过偏置基地址设置值
    biased_base()[biased_index] = value;
  }

  // Set the value of all array entries that correspond to addresses
  // in the specified MemRegion.
  void set_by_address(MemRegion range, T value) {
    idx_t biased_start = ((uintptr_t)range.start()) >> this->shift_by();
    idx_t biased_last = ((uintptr_t)range.last()) >> this->shift_by();
    this->verify_biased_index(biased_start);
    this->verify_biased_index(biased_last);
    for (idx_t i = biased_start; i <= biased_last; i++) {
      biased_base()[i] = value;
    }
  }

protected:
  // Returns the address of the element the given address maps to
  T* address_mapped_to(HeapWord* address) {
    idx_t biased_index = ((uintptr_t)address) >> this->shift_by();
    this->verify_biased_index_inclusive_end(biased_index);
    return biased_base() + biased_index;
  }

public:
  // Return the smallest address (inclusive) in the heap that this array covers.
  HeapWord* bottom_address_mapped() const {
    return (HeapWord*) ((uintptr_t)this->bias() << this->shift_by());
  }

  // Return the highest address (exclusive) in the heap that this array covers.
  HeapWord* end_address_mapped() const {
    return (HeapWord*) ((uintptr_t)(this->bias() + this->length()) << this->shift_by());
  }

protected:
  virtual T default_value() const = 0;
  // Set all elements of the given array to the given value.
  void clear() {
    T value = default_value();
    for (idx_t i = 0; i < length(); i++) {
      set_by_index(i, value);
    }
  }
public:
  G1BiasedMappedArray() {}

  // Allocate and initialize this array to cover the heap addresses in the range
  // of [bottom, end).
  // forcus G1BiasedMappedArray的初始化入口方法
  // note 这是_in_cset_fast_test和_humongous_reclaim_candidates调用的方法
  void initialize(HeapWord* bottom, HeapWord* end, size_t mapping_granularity) { // 参数为:堆起始地址、堆结束地址、4MB
    // forcus 调用基类初始化方法，建立偏置数组的核心数据结构
    G1BiasedMappedArrayBase::initialize(bottom, end, sizeof(T), mapping_granularity);
    
    // forcus 清空数组，将所有元素设置为默认值
    // note InCSetState数组设为NotInCSet，bool数组设为false
    this->clear();
  }
};

#endif // SHARE_VM_GC_G1_G1BIASEDARRAY_HPP
