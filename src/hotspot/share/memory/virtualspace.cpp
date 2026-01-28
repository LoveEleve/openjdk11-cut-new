/*
 * Copyright (c) 1997, 2018, Oracle and/or its affiliates. All rights reserved.
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
#include "logging/log.hpp"
#include "memory/resourceArea.hpp"
#include "memory/virtualspace.hpp"
#include "oops/markOop.hpp"
#include "oops/oop.inline.hpp"
#include "runtime/os.inline.hpp"
#include "services/memTracker.hpp"
#include "utilities/align.hpp"

// ReservedSpace

// Dummy constructor
ReservedSpace::ReservedSpace() : _base(NULL), _size(0), _noaccess_prefix(0),
                                 _alignment(0), _special(false), _executable(false), _fd_for_heap(-1) {
}

ReservedSpace::ReservedSpace(size_t size, size_t preferred_page_size) : _fd_for_heap(-1) {
    bool has_preferred_page_size = preferred_page_size != 0;
    // Want to use large pages where possible and pad with small pages.
    size_t page_size = has_preferred_page_size ? preferred_page_size : os::page_size_for_region_unaligned(size, 1);
    bool large_pages = page_size != (size_t) os::vm_page_size();
    size_t alignment;
    if (large_pages && has_preferred_page_size) {
        alignment = MAX2(page_size, (size_t) os::vm_allocation_granularity());
        // ReservedSpace initialization requires size to be aligned to the given
        // alignment. Align the size up.
        size = align_up(size, alignment);
    } else {
        // Don't force the alignment to be large page aligned,
        // since that will waste memory.
        alignment = os::vm_allocation_granularity();
    }
    // forcus 初始化(这里看的是三个G1 GC的三个辅助函数的初始化)
    // note 这里的第三个参数 requested_address 为 NULL - 这代表的是让linux自己选择一个合适的地址
    initialize(size, alignment, large_pages, NULL, false);
}

ReservedSpace::ReservedSpace(size_t size, size_t alignment,
                             bool large,
                             char *requested_address) : _fd_for_heap(-1) {
    initialize(size, alignment, large, requested_address, false);
}

ReservedSpace::ReservedSpace(size_t size, size_t alignment,
                             bool large,
                             bool executable) : _fd_for_heap(-1) {
    initialize(size, alignment, large, NULL, executable);
}

ReservedSpace::ReservedSpace(char *base, size_t size, size_t alignment,
                             bool special, bool executable) : _fd_for_heap(-1) {
    assert((size % os::vm_allocation_granularity()) == 0,
           "size not allocation aligned");
    _base = base;
    _size = size;
    _alignment = alignment;
    _noaccess_prefix = 0;
    _special = special;
    _executable = executable;
}

// Helper method
static void unmap_or_release_memory(char *base, size_t size, bool is_file_mapped) {
    if (is_file_mapped) {
        if (!os::unmap_memory(base, size)) {
            fatal("os::unmap_memory failed");
        }
    } else if (!os::release_memory(base, size)) {
        fatal("os::release_memory failed");
    }
}

// Helper method.
static bool failed_to_reserve_as_requested(char *base, char *requested_address,
                                           const size_t size, bool special, bool is_file_mapped = false) {
    if (base == requested_address || requested_address == NULL)
        return false; // did not fail

    if (base != NULL) {
        // Different reserve address may be acceptable in other cases
        // but for compressed oops heap should be at requested address.
        assert(UseCompressedOops, "currently requested address used only for compressed oops");
        log_debug(gc, heap, coops)("Reserved memory not at requested address: " PTR_FORMAT " vs " PTR_FORMAT, p2i(base),
                                   p2i(requested_address));
        // OS ignored requested address. Try different address.
        if (special) {
            if (!os::release_memory_special(base, size)) {
                fatal("os::release_memory_special failed");
            }
        } else {
            unmap_or_release_memory(base, size, is_file_mapped);
        }
    }
    return true;
}

void ReservedSpace::initialize(size_t size, size_t alignment, bool large,
                               char *requested_address,
                               bool executable) {
    const size_t granularity = os::vm_allocation_granularity();
    assert((size & (granularity - 1)) == 0,
           "size not aligned to os::vm_allocation_granularity()");
    assert((alignment & (granularity - 1)) == 0,
           "alignment not aligned to os::vm_allocation_granularity()");
    assert(alignment == 0 || is_power_of_2((intptr_t) alignment),
           "not a power of 2");

    alignment = MAX2(alignment, (size_t) os::vm_page_size());

    _base = NULL;
    _size = 0;
    _special = false;
    _executable = executable;
    _alignment = 0;
    _noaccess_prefix = 0;
    if (size == 0) {
        return;
    }

    // If OS doesn't support demand paging for large page memory, we need
    // to use reserve_memory_special() to reserve and pin the entire region.
    // If there is a backing file directory for this space then whether
    // large pages are allocated is up to the filesystem of the backing file.
    // So we ignore the UseLargePages flag in this case.
    bool special = large && !os::can_commit_large_page_memory();
    if (special && _fd_for_heap != -1) {
        special = false;
        if (UseLargePages && (!FLAG_IS_DEFAULT(UseLargePages) ||
                              !FLAG_IS_DEFAULT(LargePageSizeInBytes))) {
            log_debug(gc, heap)(
                    "Ignoring UseLargePages since large page support is up to the file system of the backing file for Java heap");
        }
    }

    char *base = NULL;

    if (special) {

        base = os::reserve_memory_special(size, alignment, requested_address, executable);

        if (base != NULL) {
            if (failed_to_reserve_as_requested(base, requested_address, size, true)) {
                // OS ignored requested address. Try different address.
                return;
            }
            // Check alignment constraints.
            assert((uintptr_t) base % alignment == 0,
                   "Large pages returned a non-aligned address, base: "
                           PTR_FORMAT " alignment: " SIZE_FORMAT_HEX,
                   p2i(base), alignment);
            _special = true;
        } else {
            // failed; try to reserve regular memory below
            if (UseLargePages && (!FLAG_IS_DEFAULT(UseLargePages) ||
                                  !FLAG_IS_DEFAULT(LargePageSizeInBytes))) {
                log_debug(gc, heap, coops)("Reserve regular memory without large pages");
            }
        }
    }
    // forcus 真正分配内存的地方
    if (base == NULL) {
        // Optimistically assume that the OSes returns an aligned base pointer.
        // When reserving a large address range, most OSes seem to align to at
        // least 64K.

        // If the memory was requested at a particular address, use
        // os::attempt_reserve_memory_at() to avoid over mapping something
        // important.  If available space is not detected, return NULL.

        if (requested_address != 0) {
            base = os::attempt_reserve_memory_at(size, requested_address, _fd_for_heap);
            if (failed_to_reserve_as_requested(base, requested_address, size, false, _fd_for_heap != -1)) {
                // OS ignored requested address. Try different address.
                base = NULL;
            }
        }
        else {
            /*
             * ReservedSpace
             * {
             *      _base = 0x00007f8b20000000 (OS选择的地址)
             *      _size = 16MB
             * }
             */
            base = MACOS_ONLY(os::reserve_memory(size, NULL, alignment, _fd_for_heap, _executable)) // forcus mmap()
                    NOT_MACOS(os::reserve_memory(size, NULL, alignment, _fd_for_heap));
        }

        if (base == NULL) return;

        // Check alignment constraints
        if ((((size_t) base) & (alignment - 1)) != 0) {
            // Base not aligned, retry
            unmap_or_release_memory(base, size, _fd_for_heap != -1 /*is_file_mapped*/);

            // Make sure that size is aligned
            size = align_up(size, alignment);
            base = os::reserve_memory_aligned(size, alignment, _fd_for_heap);

            if (requested_address != 0 &&
                failed_to_reserve_as_requested(base, requested_address, size, false, _fd_for_heap != -1)) {
                // As a result of the alignment constraints, the allocated base differs
                // from the requested address. Return back to the caller who can
                // take remedial action (like try again without a requested address).
                assert(_base == NULL, "should be");
                return;
            }
        }
    }
    // Done
    _base = base;
    _size = size;
    _alignment = alignment;
    // If heap is reserved with a backing file, the entire space has been committed. So set the _special flag to true
    if (_fd_for_heap != -1) {
        _special = true;
    }
}

ReservedSpace ReservedSpace::first_part(size_t partition_size, size_t alignment,
                                        bool split, bool realloc) {
    assert(partition_size <= size(), "partition failed");
    // 不分割
    if (split) {
        os::split_reserved_memory(base(), size(), partition_size, realloc);
    }
    // 创建一个新的 ReservedSpace对象
    ReservedSpace result(base(), partition_size, alignment, special(),
                         executable());
    return result;
}


ReservedSpace
ReservedSpace::last_part(size_t partition_size, size_t alignment) {
    assert(partition_size <= size(), "partition failed");
    ReservedSpace result(base() + partition_size, size() - partition_size,
                         alignment, special(), executable());
    return result;
}


size_t ReservedSpace::page_align_size_up(size_t size) {
    return align_up(size, os::vm_page_size());
}


size_t ReservedSpace::page_align_size_down(size_t size) {
    return align_down(size, os::vm_page_size());
}


size_t ReservedSpace::allocation_align_size_up(size_t size) {
    return align_up(size, os::vm_allocation_granularity());
}


size_t ReservedSpace::allocation_align_size_down(size_t size) {
    return align_down(size, os::vm_allocation_granularity());
}


void ReservedSpace::release() {
    if (is_reserved()) {
        char *real_base = _base - _noaccess_prefix;
        const size_t real_size = _size + _noaccess_prefix;
        if (special()) {
            if (_fd_for_heap != -1) {
                os::unmap_memory(real_base, real_size);
            } else {
                os::release_memory_special(real_base, real_size);
            }
        } else {
            os::release_memory(real_base, real_size);
        }
        _base = NULL;
        _size = 0;
        _noaccess_prefix = 0;
        _alignment = 0;
        _special = false;
        _executable = false;
    }
}

static size_t noaccess_prefix_size(size_t alignment) {
    return lcm(os::vm_page_size(), alignment);
}

void ReservedHeapSpace::establish_noaccess_prefix() {
    assert(_alignment >= (size_t) os::vm_page_size(), "must be at least page size big");
    _noaccess_prefix = noaccess_prefix_size(_alignment);

    if (base() && base() + _size > (char *) OopEncodingHeapMax) {
        if (true
                WIN64_ONLY(&& !UseLargePages)
                AIX_ONLY(&& os::vm_page_size() != 64*K)) {
            // Protect memory at the base of the allocated region.
            // If special, the page was committed (only matters on windows)
            if (!os::protect_memory(_base, _noaccess_prefix, os::MEM_PROT_NONE, _special)) {
                fatal("cannot protect protection page");
            }
            log_debug(gc, heap, coops)("Protected page at the reserved heap base: "
                                       PTR_FORMAT " / " INTX_FORMAT " bytes",
                                       p2i(_base),
                                       _noaccess_prefix);
            assert(Universe::narrow_oop_use_implicit_null_checks() == true, "not initialized?");
        } else {
            Universe::set_narrow_oop_use_implicit_null_checks(false);
        }
    }

    _base += _noaccess_prefix;
    _size -= _noaccess_prefix;
    assert(((uintptr_t) _base % _alignment == 0), "must be exactly of required alignment");
}

// Tries to allocate memory of size 'size' at address requested_address with alignment 'alignment'.
// Does not check whether the reserved memory actually is at requested_address, as the memory returned
// might still fulfill the wishes of the caller.
// Assures the memory is aligned to 'alignment'.
// NOTE: If ReservedHeapSpace already points to some reserved memory this is freed, first.
//
void ReservedHeapSpace::try_reserve_heap(size_t size,
                                         size_t alignment,
                                         bool large, // 是否使用大页,默认为false
                                         char *requested_address) { // 期望linux分配内存的地方
    // 这里通常是因为OS分配的地址不符合预期,所以需要释放掉,第一次_base都是为null的
    if (_base != NULL) {
        // We tried before, but we didn't like the address delivered.
        release();
    }

    // If OS doesn't support demand paging for large page memory, we need
    // to use reserve_memory_special() to reserve and pin the entire region.
    // If there is a backing file directory for this space then whether
    // large pages are allocated is up to the filesystem of the backing file.
    // So we ignore the UseLargePages flag in this case.
    // 默认为false,暂时不需要关心
    bool special = large && !os::can_commit_large_page_memory();
    if (special && _fd_for_heap != -1) {
        special = false;
        if (UseLargePages && (!FLAG_IS_DEFAULT(UseLargePages) ||
                              !FLAG_IS_DEFAULT(LargePageSizeInBytes))) {
            log_debug(gc, heap)("Cannot allocate large pages for Java Heap when AllocateHeapAt option is set.");
        }
    }
    char *base = NULL;
    // -Xlog:gc+heap+coops=trace
    log_trace(gc, heap, coops)("Trying to allocate at address " PTR_FORMAT
                               " heap of size " SIZE_FORMAT_HEX,
                               p2i(requested_address),
                               size);
    // 不关心大页逻辑
    if (special) {
        base = os::reserve_memory_special(size, alignment, requested_address, false);

        if (base != NULL) {
            // Check alignment constraints.
            assert((uintptr_t) base % alignment == 0,
                   "Large pages returned a non-aligned address, base: "
                           PTR_FORMAT " alignment: " SIZE_FORMAT_HEX,
                   p2i(base), alignment);
            _special = true;
        }
    }
    // forcus
    if (base == NULL) {
        // Failed; try to reserve regular memory below
        if (UseLargePages && (!FLAG_IS_DEFAULT(UseLargePages) ||
                              !FLAG_IS_DEFAULT(LargePageSizeInBytes))) {
            log_debug(gc, heap, coops)("Reserve regular memory without large pages");
        }

        // Optimistically assume that the OSes returns an aligned base pointer.
        // When reserving a large address range, most OSes seem to align to at
        // least 64K.

        // If the memory was requested at a particular address, use
        // os::attempt_reserve_memory_at() to avoid over mapping something
        // important.  If available space is not detected, return NULL.
        // forcus 如果jvm希望OS在某个地址分配内存(在这种情况下是会指定的)
        /* 下面的 _fd_for_heap通常为-1 */
        if (requested_address != 0) {
            base = os::attempt_reserve_memory_at(size, requested_address, _fd_for_heap); // forcus mmap() - 期望在 requested_address 地址分配
        } else {
            base = os::reserve_memory(size, NULL, alignment, _fd_for_heap); // forcus mmap() - 让os自己选择地址
        }
    }
    if (base == NULL) { return; } // forcus 此次从3GB位置开始分配1GB堆内存的行为失败,返回null,继续从(3GB-533MB)的位置开始尝试分配

    // forcus 否则分配成功
    // Done
    _base = base;
    _size = size;
    _alignment = alignment;

    // If heap is reserved with a backing file, the entire space has been committed. So set the _special flag to true
    // 一般堆内存不会是文件映射,暂时不关心
    if (_fd_for_heap != -1) {
        _special = true;
    }

    // Check alignment constraints 一般都是对齐的
    if ((((size_t) base) & (alignment - 1)) != 0) {
        // Base not aligned, retry.
        release();
    }
}

void ReservedHeapSpace::try_reserve_range(char *highest_start,
                                          char *lowest_start,
                                          size_t attach_point_alignment,
                                          char *aligned_heap_base_min_address,
                                          char *upper_bound,
                                          size_t size,
                                          size_t alignment,
                                          bool large) {
    /*
     * 所以这里是什么意思呢？ 因为走到这里,说明堆内存的大小 <= 2GB ，而堆的范围被限制在了[lowest_start(2GB) , 4GB - heap_size]
     */
    // 计算搜索范围[lowest_start, highest_start] - 也即堆的起始地址
    const size_t attach_range = highest_start - lowest_start;
    // Cap num_attempts at possible number.
    // At least one is possible even for 0 sized attach range.
    // 计算理论上最多能尝试多少个位置
    /*
     * 这里假设 lowest_start = 2GB, highest_start = 34GB, attach_point_alignment = 2MB, size = 1GB
     * 那么从 highest_start 开始，每次向后移动 2MB(也即朝lowest_start位置移动)，最多能尝试 (highest_start - lowest_start) / attach_point_alignment + 1(边界也算一次)次
     */
    const uint64_t num_attempts_possible = (attach_range / attach_point_alignment) + 1;
    // HeapSearchSteps 默认值是 3，限制尝试次数(在这里取两者的最小值,一般计算出来的是不会比3小的),所以在这里一般都是3
    // forcus 默认尝试次数
    const uint64_t num_attempts_to_try = MIN2((uint64_t) HeapSearchSteps, num_attempts_possible);
    // 计算每次移动的步长
    /*
     *  在这里分为两种情况:
     *   - attach_range = highest_start - lowest_start(这代表堆大小=2GB),那么尝试的次数只有1次,也就是从2GB的位置开始分配堆内存(2GB -> 4GB)
     *   - attach_range > 0(这是通常的情况)：把搜索范围均匀分成 num_attempts_to_try 份
     *      比如 heap_size = 1GB , lowest_start = 2GB , highest_start = 4GB - 1GB = 3GB attach_range = 3-2GB = 1GB
     *      在上面计算出来的默认尝试次数 num_attempts_to_try = 3
     *      那么 stepSize = align(1GB / 3,2MB) = 342MB
     *      也即第一次从3GB位置开始分配1GB的堆内存,如果失败了,那么下次就从(3GB-342MB=2.66GB)的位置开始分配1GB的内存
     */
    const size_t stepsize = (attach_range == 0) ? // Only one try.
                            (size_t) highest_start : align_up(attach_range / num_attempts_to_try,
                                                              attach_point_alignment);

    // Try attach points from top to bottom.
    // forcus 从高地址向低地址尝试分配地址 - 使用stepSize来将尝试次数限制在了3次
    /*
     * 这里介绍一下条件4
     *  当jvm通过mmap()想要在3GB的位置分配1GB的堆内存时,比如 mmap((void*)3GB, 1GB, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        此时linux内核可能不会在3GB的地方分配(因为OS会根据实际情况来分配,当然如果能分配成功那是最好了)
        而这里就是用来处理：linux内核没有按照我们要求的位置来分配内存时的场景
         - _base < aligned_heap_base_min_address ：os选择的地址太低了(< 2GB),这肯定不行
         - _base + size > upper_bound ：os选择的地址太高了(导致堆内存的末尾地址超过了4GB),这肯定也不行,因为内存访问不到
     */
    char *attach_point = highest_start; // 从最高地址开始尝试(在这里假设为3GB)
    while (attach_point >= lowest_start && // 条件1 - 还没有搜索到最低地址
           attach_point <= highest_start &&  // Avoid wrap around. 条件2 - 防止减法溢出导致地址回绕
           ((_base == NULL) || // 条件3 - 还没分配成功
            (_base < aligned_heap_base_min_address || _base + size > upper_bound))) { // forcus 条件4 - 分配成功,但是位置不在有效范围内
        try_reserve_heap(size, alignment, large, attach_point); // forcus 真正尝试分配内存的地方
        attach_point -= stepsize; // 向低地址移动
    }
}

#define SIZE_64K  ((uint64_t) UCONST64(      0x10000))
#define SIZE_256M ((uint64_t) UCONST64(   0x10000000))
#define SIZE_32G  ((uint64_t) UCONST64(  0x800000000))

// Helper for heap allocation. Returns an array with addresses
// (OS-specific) which are suited for disjoint base mode. Array is
// NULL terminated.
static char **get_attach_addresses_for_disjoint_mode() {
    static uint64_t addresses[] = {
            2 * SIZE_32G,
            3 * SIZE_32G,
            4 * SIZE_32G,
            8 * SIZE_32G,
            10 * SIZE_32G,
            1 * SIZE_64K * SIZE_32G,
            2 * SIZE_64K * SIZE_32G,
            3 * SIZE_64K * SIZE_32G,
            4 * SIZE_64K * SIZE_32G,
            16 * SIZE_64K * SIZE_32G,
            32 * SIZE_64K * SIZE_32G,
            34 * SIZE_64K * SIZE_32G,
            0
    };

    // Sort out addresses smaller than HeapBaseMinAddress. This assumes
    // the array is sorted.
    uint i = 0;
    while (addresses[i] != 0 &&
           (addresses[i] < OopEncodingHeapMax || addresses[i] < HeapBaseMinAddress)) {
        i++;
    }
    uint start = i;

    // Avoid more steps than requested.
    i = 0;
    while (addresses[start + i] != 0) {
        if (i == HeapSearchSteps) {
            addresses[start + i] = 0;
            break;
        }
        i++;
    }

    return (char **) &addresses[start];
}

// forcus 压缩指针堆分配策略
void ReservedHeapSpace::initialize_compressed_heap(const size_t size, size_t alignment, bool large) {
    /*
     * 检查堆大小是否支持压缩指针 (OopEncodingHeapMax = 32GB)
     * noaccess_prefix_size(alignment) = 保护页大小（用于 null 检查优化）
     * 堆大小 + 保护页 必须 ≤ 32GB，否则无法使用压缩指针
     */
    guarantee(size + noaccess_prefix_size(alignment) <= OopEncodingHeapMax,
              "can not allocate compressed oop heap for this size");
    guarantee(alignment == MAX2(alignment, (size_t) os::vm_page_size()), "alignment too small");
    // granularity 在linux上为page大小
    // size 和 alignment 都必须是页大小的整数倍
    const size_t granularity = os::vm_allocation_granularity();
    assert((size & (granularity - 1)) == 0,
           "size not aligned to os::vm_allocation_granularity()");
    assert((alignment & (granularity - 1)) == 0,
           "alignment not aligned to os::vm_allocation_granularity()");
    assert(alignment == 0 || is_power_of_2((intptr_t) alignment),
           "not a power of 2");

    // The necessary attach point alignment for generated wish addresses.
    // This is needed to increase the chance of attaching for mmap and shmat.
    const size_t os_attach_point_alignment =
            AIX_ONLY(SIZE_256M)  // Known shm boundary alignment.
            NOT_AIX(os::vm_allocation_granularity());
    const size_t attach_point_alignment = lcm(alignment, os_attach_point_alignment);
    // forcus 计算堆基址的最小地址
    /*
     *  HeapBaseMinAddress 在 linuxx86_64上为 2GB
     *  结果为：堆不会分配在 0~2GB 区域（这块留给 C 堆和其他用途）
     */
    char *aligned_heap_base_min_address = (char *) align_up((void *) HeapBaseMinAddress, alignment);
    // forcus 计算是否需要 noaccess_prefix , 如果堆结束地址超过 32GB，需要添加保护页前缀
    /*
     * 堆起始地址 + 堆大小 > 32GB，需要添加保护页前缀
     */
    size_t noaccess_prefix = ((aligned_heap_base_min_address + size) > (char *) OopEncodingHeapMax) ?
                             noaccess_prefix_size(alignment) : 0;

    // Attempt to alloc at user-given address.
    // 通常不会指定,可以跳过
    if (!FLAG_IS_DEFAULT(HeapBaseMinAddress)) {
        try_reserve_heap(size + noaccess_prefix, alignment, large, aligned_heap_base_min_address);
        if (_base != aligned_heap_base_min_address) { // Enforce this exact address.
            release();
        }
    }

    // Keep heap at HeapBaseMinAddress.
    // forcus
    if (_base == NULL) {

        // Try to allocate the heap at addresses that allow efficient oop compression.
        // Different schemes are tried, in order of decreasing optimization potential.
        //
        // For this, try_reserve_heap() is called with the desired heap base addresses.
        // A call into the os layer to allocate at a given address can return memory
        // at a different address than requested.  Still, this might be memory at a useful
        // address. try_reserve_heap() always returns this allocated memory, as only here
        // the criteria for a good heap are checked.

        // Attempt to allocate so that we can run without base and scale (32-Bit unscaled compressed oops).
        // Give it several tries from top of range to bottom.
        // note Unscaled模式
        // forcus aligned_heap_base_min_address(2GB) + size <= 4GB  尝试 Unscaled 模式(0~4GB) ==> 也即 堆大小 <= 2GB 时才会 尝试 Unscaled模式
        // 涉及到图解-1/2
        if (aligned_heap_base_min_address + size <= (char *) UnscaledOopHeapMax) {

            // Calc address range within we try to attach (range of possible start addresses).
            // 计算尝试范围
            /*
             *  这里的意思如下：
                虚拟地址空间（低地址 → 高地址）
                ┌─────────────────────────────────────────────────────────────────┐
                │   0GB        1GB        2GB        3GB        4GB               │
                │    │          │          │          │          │                │
                │    ▼          ▼          ▼          ▼          ▼                │
                ├────┼──────────┼──────────┼──────────┼──────────┤                │
                │    │ 系统保留  │          │   搜索范围     │                       │
                │    │ (不能用)  │  lowest  │◄────────►│  highest                  │
                │    │          │  _start  │  堆可以放这里  │ _start                │
                │    │          │   (2GB)  │          │ (4GB-size)                │
                └────┴──────────┴──────────┴──────────┴──────────┘
                                           │          │
                                           └──────────┘
                                            Unscaled 模式
                                            目标区域
             */
            // forcus highest_start = 4GB - size , 堆能放置的最高起始地址
            char *const highest_start = align_down((char *) UnscaledOopHeapMax - size, attach_point_alignment);
            // forcus lowest_start = 2GB 堆能放置的最低起始地址
            char *const lowest_start = align_up(aligned_heap_base_min_address, attach_point_alignment);
            // forcus 尝试在 Unscaled 模式下分配堆
            try_reserve_range(highest_start, // 从这里开始尝试（高地址）
                              lowest_start, // 到这里结束（低地址）
                              attach_point_alignment, // 每次递减的步长
                              aligned_heap_base_min_address, // 有效范围下界
                              (char *) UnscaledOopHeapMax, //  // 有效范围上界(4GB)
                              size,
                              alignment,
                              large);
        }

        // zerobased: Attempt to allocate in the lower 32G.
        // But leave room for the compressed class pointers, which is allocated above
        // the heap.

        char *zerobased_max = (char *) OopEncodingHeapMax; // 32GB
        // forcus 为 Compressed Class Space 预留空间
        /*
         * 为什么要处理这个呢？因为压缩类指针也需要在32GB内存范围内,所以在这里堆的上界 = 32GB - Classspace
         */
        const size_t class_space = align_up(CompressedClassSpaceSize, alignment);
        // For small heaps, save some space for compressed class pointer
        // space so it can be decoded with no base.
        // 如果堆+类空间能放进 32GB，就预留类空间
        /*
         * 这里涉及到了很多参数~~,但是不要着急,慢慢分析
         *  1.涉及到的常量值
         *   - OopEncodingHeapMax : 32GB - 压缩对象指针的最大范围
         *   - KlassEncodingMetaspaceMax : 32GB - 压缩类指针的最大范围
         *   - CompressedClassSpaceSize : 1GB(默认) - 类元数据空间大小
         *   - aligned_heap_base_min_address : 2GB - 堆的最低起始地址
         *   这段代码想要表达的意思就是: 如果堆和类空间都要在 32GB 内，那堆最多只能用到 31GB，留 1GB 给类空间
         *   note java -Xlog:gc+metaspace=info 启动时加上该参数可以看到Klass Space的空间
         */
        if (UseCompressedClassPointers &&  // 条件1: 启用了压缩类指针(默认为true)
            !UseSharedSpaces && // 条件2: 没有使用CDS(类数据共享,一般都不会使用)
            OopEncodingHeapMax <= KlassEncodingMetaspaceMax && // 条件3: 压缩对象指针的最大范围 <= 压缩类指针的最大范围
            (uint64_t) (aligned_heap_base_min_address + size + class_space) <= KlassEncodingMetaspaceMax) { // 条件4: 2GB + 堆大小 + 类空间 <= 32GB
            // forcus 以上条件都满足的时候,那么堆上界 = 32GB - 1GB = 31GB
            zerobased_max = (char *) OopEncodingHeapMax - class_space;
        }

        // Give it several tries from top of range to bottom
        // note ZeroBased 模式
        /*
         * 三个条件：
         *  - aligned_heap_base_min_address + size <= zerobased_max(堆上界地址：31GB，但是下界为2GB,所以这里 heap_size <= 29GB):
         *     - 2GB + heap_size <= 31GB 「也即堆内存大小 <= 29GB」
         *  - _base == NULL || _base + size > zerobased_max: Unscaled模式分配失败 或者 成功了但是分配的位置不理想(应该不会出现这种情况)
         *
         *  note 小堆也可能走到下面的逻辑,因为可能每次分配的位置都不理想
         */
        if (aligned_heap_base_min_address + size <= zerobased_max &&    // Zerobased theoretical possible.
            ((_base == NULL) ||                        // No previous try succeeded.
             (_base + size > zerobased_max))) {        // Unscaled delivered an arbitrary address.

            // Calc address range within we try to attach (range of possible start addresses)
            // forcus 计算搜索范围(这里假设堆内存大小为16GB) ,那么查找的起始地址为: 31GB - 8GB = 23GB
            char *const highest_start = align_down(zerobased_max - size, attach_point_alignment);
            // Need to be careful about size being guaranteed to be less
            // than UnscaledOopHeapMax due to type constraints.
            // forcus 堆起始地址的最低位置：2GB
            char *lowest_start = aligned_heap_base_min_address;
            /*
             * 避开 Unscaled 区域
             *  - 如果是小堆(比如1GB),在上面的 Unscaled模式下已经尝试过了 2GB~4GB范围了，那么在这里就需要避开这个范围
             *   - unscaled_end = 4GB - 1GB = 3GB
             *    - lowest_start = MAX2(2GB, 3GB) = 3GB note 此时堆的下界为3GB,而不是2GB了
             *  - 如果是大堆(8GB)
             *   - unscaled_end = 4GB - 8GB = -4GB(溢出变为超大值)
             *   - 那么 unscaled_end < UnscaledOopHeapMax? → false，不进入 if - 此时的 lowest_start = 2GB note 也即堆的下界依旧可以为2GB
             */
            uint64_t unscaled_end = UnscaledOopHeapMax - size;
            if (unscaled_end < UnscaledOopHeapMax) { // unscaled_end wrapped if size is large
                lowest_start = MAX2(lowest_start, (char *) unscaled_end);
            }
            lowest_start = align_up(lowest_start, attach_point_alignment);
            // forcus 同 Unscaled 模式，不再赘述
            // note 图解-3
            try_reserve_range(highest_start, lowest_start, attach_point_alignment,
                              aligned_heap_base_min_address, zerobased_max, size, alignment, large);
        }

        /*
         * note Disjoint 模式
         * 如果前面两种模式都分配失败了(走下面的基本情况就是大堆(>=29GB)) -- 这种情况暂时可以不用了解
         */
        // Now we go for heaps with base != 0.  We need a noaccess prefix to efficiently
        // implement null checks.
        // forcus 当堆不在32GB以内时,需要添加保护页(base!=0,这里的base不是上面的_base,而是指寻址方式)
        // noaccess_prefix = 保护页大小
        noaccess_prefix = noaccess_prefix_size(alignment);

        // Try to attach at addresses that are aligned to OopEncodingHeapMax. Disjointbase mode.
        // forcus 获取 Disjoint 地址列表 - 32的倍数(最小值就是为32*2GB)
        /*
         * 为什么是32的倍数呢(最小就是32*2GB)
         */
        char **addresses = get_attach_addresses_for_disjoint_mode();
        int i = 0;
        while (addresses[i] &&                                 // End of array not yet reached.
               ((_base == NULL) ||                             // No previous try succeeded.
                (_base + size > (char *) OopEncodingHeapMax && // Not zerobased or unscaled address.
                 !Universe::is_disjoint_heap_base_address((address) _base)))) {  // Not disjoint address.
            char *const attach_point = addresses[i];
            assert(attach_point >= aligned_heap_base_min_address, "Flag support broken");
            try_reserve_heap(size + noaccess_prefix, alignment, large, attach_point);
            i++;
        }

        // Last, desperate try without any placement.
        if (_base == NULL) {
            log_trace(gc, heap, coops)("Trying to allocate at address NULL heap of size " SIZE_FORMAT_HEX,
                                       size + noaccess_prefix);
            initialize(size + noaccess_prefix, alignment, large, NULL, false);
        }
    }
}
// forcus 真正分配内存的地方
/*
      参数:
          total_reserved: 堆大小
          alignment: 堆对齐
          use_large_pages: 是否使用大页 - 一般为false
          heap_allocation_directory: 指定堆文件位置(很少见) {通过 -XX:AllocateHeapAt=/path 可以把堆分配到特定文件（如 NVMe、持久内存）}
 */
ReservedHeapSpace::ReservedHeapSpace(size_t size, size_t alignment, bool large, const char *heap_allocation_directory)
        : ReservedSpace() {

    if (size == 0) {
        return; //要分配的堆内存大小为0,那么直接返回
    }
    // 指定了堆文件位置(一般不会指定)
    if (heap_allocation_directory != NULL) {
        _fd_for_heap = os::create_file_for_heap(heap_allocation_directory);
        if (_fd_for_heap == -1) {
            vm_exit_during_initialization(
                    err_msg("Could not create file for Heap at location %s", heap_allocation_directory));
        }
    }

    // Heap size should be aligned to alignment, too.
    guarantee(is_aligned(size, alignment), "set by caller");
    // forcus 使用了压缩指针(一般都会使用)
    if (UseCompressedOops) {
        initialize_compressed_heap(size, alignment, large); // forcus 压缩指针堆分配策略
        if (_size > size) {
            // We allocated heap with noaccess prefix.
            // It can happen we get a zerobased/unscaled heap with noaccess prefix,
            // if we had to try at arbitrary address.
            establish_noaccess_prefix();
        }
    } else {
        initialize(size, alignment, large, NULL, false);
    }

    assert(markOopDesc::encode_pointer_as_mark(_base)->decode_pointer() == _base,
           "area must be distinguishable from marks for mark-sweep");
    assert(markOopDesc::encode_pointer_as_mark(&_base[size])->decode_pointer() == &_base[size],
           "area must be distinguishable from marks for mark-sweep");

    if (base() != NULL) {
        MemTracker::record_virtual_memory_type((address) base(), mtJavaHeap);
    }

    if (_fd_for_heap != -1) {
        os::close(_fd_for_heap);
    }
}

// Reserve space for code segment.  Same as Java heap only we mark this as
// executable.
ReservedCodeSpace::ReservedCodeSpace(size_t r_size,
                                     size_t rs_align,
                                     bool large) :
        ReservedSpace(r_size, rs_align, large, /*executable*/ true) {
    MemTracker::record_virtual_memory_type((address) base(), mtCode);
}

// VirtualSpace

VirtualSpace::VirtualSpace() {
    _low_boundary = NULL;
    _high_boundary = NULL;
    _low = NULL;
    _high = NULL;
    _lower_high = NULL;
    _middle_high = NULL;
    _upper_high = NULL;
    _lower_high_boundary = NULL;
    _middle_high_boundary = NULL;
    _upper_high_boundary = NULL;
    _lower_alignment = 0;
    _middle_alignment = 0;
    _upper_alignment = 0;
    _special = false;
    _executable = false;
}


bool VirtualSpace::initialize(ReservedSpace rs, size_t committed_size) {
    const size_t max_commit_granularity = os::page_size_for_region_unaligned(rs.size(), 1);
    return initialize_with_granularity(rs, committed_size, max_commit_granularity);
}

bool VirtualSpace::initialize_with_granularity(ReservedSpace rs, size_t committed_size, size_t max_commit_granularity) {
    if (!rs.is_reserved()) return false;  // allocation failed.
    assert(_low_boundary == NULL, "VirtualSpace already initialized");
    assert(max_commit_granularity > 0, "Granularity must be non-zero.");

    _low_boundary = rs.base();
    _high_boundary = low_boundary() + rs.size();

    _low = low_boundary();
    _high = low();

    _special = rs.special();
    _executable = rs.executable();

    // When a VirtualSpace begins life at a large size, make all future expansion
    // and shrinking occur aligned to a granularity of large pages.  This avoids
    // fragmentation of physical addresses that inhibits the use of large pages
    // by the OS virtual memory system.  Empirically,  we see that with a 4MB
    // page size, the only spaces that get handled this way are codecache and
    // the heap itself, both of which provide a substantial performance
    // boost in many benchmarks when covered by large pages.
    //
    // No attempt is made to force large page alignment at the very top and
    // bottom of the space if they are not aligned so already.
    _lower_alignment = os::vm_page_size();
    _middle_alignment = max_commit_granularity;
    _upper_alignment = os::vm_page_size();

    // End of each region
    _lower_high_boundary = align_up(low_boundary(), middle_alignment());
    _middle_high_boundary = align_down(high_boundary(), middle_alignment());
    _upper_high_boundary = high_boundary();

    // High address of each region
    _lower_high = low_boundary();
    _middle_high = lower_high_boundary();
    _upper_high = middle_high_boundary();

    // commit to initial size
    if (committed_size > 0) {
        if (!expand_by(committed_size)) {
            return false;
        }
    }
    return true;
}


VirtualSpace::~VirtualSpace() {
    release();
}


void VirtualSpace::release() {
    // This does not release memory it reserved.
    // Caller must release via rs.release();
    _low_boundary = NULL;
    _high_boundary = NULL;
    _low = NULL;
    _high = NULL;
    _lower_high = NULL;
    _middle_high = NULL;
    _upper_high = NULL;
    _lower_high_boundary = NULL;
    _middle_high_boundary = NULL;
    _upper_high_boundary = NULL;
    _lower_alignment = 0;
    _middle_alignment = 0;
    _upper_alignment = 0;
    _special = false;
    _executable = false;
}


size_t VirtualSpace::committed_size() const {
    return pointer_delta(high(), low(), sizeof(char));
}


size_t VirtualSpace::reserved_size() const {
    return pointer_delta(high_boundary(), low_boundary(), sizeof(char));
}


size_t VirtualSpace::uncommitted_size() const {
    return reserved_size() - committed_size();
}

size_t VirtualSpace::actual_committed_size() const {
    // Special VirtualSpaces commit all reserved space up front.
    if (special()) {
        return reserved_size();
    }

    size_t committed_low = pointer_delta(_lower_high, _low_boundary, sizeof(char));
    size_t committed_middle = pointer_delta(_middle_high, _lower_high_boundary, sizeof(char));
    size_t committed_high = pointer_delta(_upper_high, _middle_high_boundary, sizeof(char));

#ifdef ASSERT
    size_t lower = pointer_delta(_lower_high_boundary, _low_boundary, sizeof(char));
    size_t middle = pointer_delta(_middle_high_boundary, _lower_high_boundary, sizeof(char));
    size_t upper = pointer_delta(_upper_high_boundary, _middle_high_boundary, sizeof(char));

    if (committed_high > 0) {
        assert(committed_low == lower, "Must be");
        assert(committed_middle == middle, "Must be");
    }

    if (committed_middle > 0) {
        assert(committed_low == lower, "Must be");
    }
    if (committed_middle < middle) {
        assert(committed_high == 0, "Must be");
    }

    if (committed_low < lower) {
        assert(committed_high == 0, "Must be");
        assert(committed_middle == 0, "Must be");
    }
#endif

    return committed_low + committed_middle + committed_high;
}


bool VirtualSpace::contains(const void *p) const {
    return low() <= (const char *) p && (const char *) p < high();
}

static void pretouch_expanded_memory(void *start, void *end) {
    assert(is_aligned(start, os::vm_page_size()), "Unexpected alignment");
    assert(is_aligned(end, os::vm_page_size()), "Unexpected alignment");

    os::pretouch_memory(start, end);
}

static bool commit_expanded(char *start, size_t size, size_t alignment, bool pre_touch, bool executable) {
    if (os::commit_memory(start, size, alignment, executable)) {
        if (pre_touch || AlwaysPreTouch) {
            pretouch_expanded_memory(start, start + size);
        }
        return true;
    }

    debug_only(warning(
            "INFO: os::commit_memory(" PTR_FORMAT ", " PTR_FORMAT
                       " size=" SIZE_FORMAT ", executable=%d) failed",
                    p2i(start), p2i(start + size), size, executable);)

    return false;
}

/*
   First we need to determine if a particular virtual space is using large
   pages.  This is done at the initialize function and only virtual spaces
   that are larger than LargePageSizeInBytes use large pages.  Once we
   have determined this, all expand_by and shrink_by calls must grow and
   shrink by large page size chunks.  If a particular request
   is within the current large page, the call to commit and uncommit memory
   can be ignored.  In the case that the low and high boundaries of this
   space is not large page aligned, the pages leading to the first large
   page address and the pages after the last large page address must be
   allocated with default pages.
*/
bool VirtualSpace::expand_by(size_t bytes, bool pre_touch) {
    if (uncommitted_size() < bytes) {
        return false;
    }

    if (special()) {
        // don't commit memory if the entire space is pinned in memory
        _high += bytes;
        return true;
    }

    char *previous_high = high();
    char *unaligned_new_high = high() + bytes;
    assert(unaligned_new_high <= high_boundary(), "cannot expand by more than upper boundary");

    // Calculate where the new high for each of the regions should be.  If
    // the low_boundary() and high_boundary() are LargePageSizeInBytes aligned
    // then the unaligned lower and upper new highs would be the
    // lower_high() and upper_high() respectively.
    char *unaligned_lower_new_high = MIN2(unaligned_new_high, lower_high_boundary());
    char *unaligned_middle_new_high = MIN2(unaligned_new_high, middle_high_boundary());
    char *unaligned_upper_new_high = MIN2(unaligned_new_high, upper_high_boundary());

    // Align the new highs based on the regions alignment.  lower and upper
    // alignment will always be default page size.  middle alignment will be
    // LargePageSizeInBytes if the actual size of the virtual space is in
    // fact larger than LargePageSizeInBytes.
    char *aligned_lower_new_high = align_up(unaligned_lower_new_high, lower_alignment());
    char *aligned_middle_new_high = align_up(unaligned_middle_new_high, middle_alignment());
    char *aligned_upper_new_high = align_up(unaligned_upper_new_high, upper_alignment());

    // Determine which regions need to grow in this expand_by call.
    // If you are growing in the lower region, high() must be in that
    // region so calculate the size based on high().  For the middle and
    // upper regions, determine the starting point of growth based on the
    // location of high().  By getting the MAX of the region's low address
    // (or the previous region's high address) and high(), we can tell if it
    // is an intra or inter region growth.
    size_t lower_needs = 0;
    if (aligned_lower_new_high > lower_high()) {
        lower_needs = pointer_delta(aligned_lower_new_high, lower_high(), sizeof(char));
    }
    size_t middle_needs = 0;
    if (aligned_middle_new_high > middle_high()) {
        middle_needs = pointer_delta(aligned_middle_new_high, middle_high(), sizeof(char));
    }
    size_t upper_needs = 0;
    if (aligned_upper_new_high > upper_high()) {
        upper_needs = pointer_delta(aligned_upper_new_high, upper_high(), sizeof(char));
    }

    // Check contiguity.
    assert(low_boundary() <= lower_high() && lower_high() <= lower_high_boundary(),
           "high address must be contained within the region");
    assert(lower_high_boundary() <= middle_high() && middle_high() <= middle_high_boundary(),
           "high address must be contained within the region");
    assert(middle_high_boundary() <= upper_high() && upper_high() <= upper_high_boundary(),
           "high address must be contained within the region");

    // Commit regions
    if (lower_needs > 0) {
        assert(lower_high() + lower_needs <= lower_high_boundary(), "must not expand beyond region");
        if (!commit_expanded(lower_high(), lower_needs, _lower_alignment, pre_touch, _executable)) {
            return false;
        }
        _lower_high += lower_needs;
    }

    if (middle_needs > 0) {
        assert(middle_high() + middle_needs <= middle_high_boundary(), "must not expand beyond region");
        if (!commit_expanded(middle_high(), middle_needs, _middle_alignment, pre_touch, _executable)) {
            return false;
        }
        _middle_high += middle_needs;
    }

    if (upper_needs > 0) {
        assert(upper_high() + upper_needs <= upper_high_boundary(), "must not expand beyond region");
        if (!commit_expanded(upper_high(), upper_needs, _upper_alignment, pre_touch, _executable)) {
            return false;
        }
        _upper_high += upper_needs;
    }

    _high += bytes;
    return true;
}

// A page is uncommitted if the contents of the entire page is deemed unusable.
// Continue to decrement the high() pointer until it reaches a page boundary
// in which case that particular page can now be uncommitted.
void VirtualSpace::shrink_by(size_t size) {
    if (committed_size() < size)
        fatal("Cannot shrink virtual space to negative size");

    if (special()) {
        // don't uncommit if the entire space is pinned in memory
        _high -= size;
        return;
    }

    char *unaligned_new_high = high() - size;
    assert(unaligned_new_high >= low_boundary(), "cannot shrink past lower boundary");

    // Calculate new unaligned address
    char *unaligned_upper_new_high =
            MAX2(unaligned_new_high, middle_high_boundary());
    char *unaligned_middle_new_high =
            MAX2(unaligned_new_high, lower_high_boundary());
    char *unaligned_lower_new_high =
            MAX2(unaligned_new_high, low_boundary());

    // Align address to region's alignment
    char *aligned_upper_new_high = align_up(unaligned_upper_new_high, upper_alignment());
    char *aligned_middle_new_high = align_up(unaligned_middle_new_high, middle_alignment());
    char *aligned_lower_new_high = align_up(unaligned_lower_new_high, lower_alignment());

    // Determine which regions need to shrink
    size_t upper_needs = 0;
    if (aligned_upper_new_high < upper_high()) {
        upper_needs =
                pointer_delta(upper_high(), aligned_upper_new_high, sizeof(char));
    }
    size_t middle_needs = 0;
    if (aligned_middle_new_high < middle_high()) {
        middle_needs =
                pointer_delta(middle_high(), aligned_middle_new_high, sizeof(char));
    }
    size_t lower_needs = 0;
    if (aligned_lower_new_high < lower_high()) {
        lower_needs =
                pointer_delta(lower_high(), aligned_lower_new_high, sizeof(char));
    }

    // Check contiguity.
    assert(middle_high_boundary() <= upper_high() &&
           upper_high() <= upper_high_boundary(),
           "high address must be contained within the region");
    assert(lower_high_boundary() <= middle_high() &&
           middle_high() <= middle_high_boundary(),
           "high address must be contained within the region");
    assert(low_boundary() <= lower_high() &&
           lower_high() <= lower_high_boundary(),
           "high address must be contained within the region");

    // Uncommit
    if (upper_needs > 0) {
        assert(middle_high_boundary() <= aligned_upper_new_high &&
               aligned_upper_new_high + upper_needs <= upper_high_boundary(),
               "must not shrink beyond region");
        if (MACOS_ONLY(!os::uncommit_memory(aligned_upper_new_high, upper_needs, _executable))
        NOT_MACOS(!os::uncommit_memory(aligned_upper_new_high, upper_needs))) {
            debug_only(warning("os::uncommit_memory failed"));
            return;
        } else {
            _upper_high -= upper_needs;
        }
    }
    if (middle_needs > 0) {
        assert(lower_high_boundary() <= aligned_middle_new_high &&
               aligned_middle_new_high + middle_needs <= middle_high_boundary(),
               "must not shrink beyond region");
        if (MACOS_ONLY(!os::uncommit_memory(aligned_middle_new_high, middle_needs, _executable))
        NOT_MACOS(!os::uncommit_memory(aligned_middle_new_high, middle_needs))) {
            debug_only(warning("os::uncommit_memory failed"));
            return;
        } else {
            _middle_high -= middle_needs;
        }
    }
    if (lower_needs > 0) {
        assert(low_boundary() <= aligned_lower_new_high &&
               aligned_lower_new_high + lower_needs <= lower_high_boundary(),
               "must not shrink beyond region");
        if (MACOS_ONLY(!os::uncommit_memory(aligned_lower_new_high, lower_needs, _executable))
        NOT_MACOS(!os::uncommit_memory(aligned_lower_new_high, lower_needs))) {
            debug_only(warning("os::uncommit_memory failed"));
            return;
        } else {
            _lower_high -= lower_needs;
        }
    }

    _high -= size;
}

#ifndef PRODUCT

void VirtualSpace::check_for_contiguity() {
    // Check contiguity.
    assert(low_boundary() <= lower_high() &&
           lower_high() <= lower_high_boundary(),
           "high address must be contained within the region");
    assert(lower_high_boundary() <= middle_high() &&
           middle_high() <= middle_high_boundary(),
           "high address must be contained within the region");
    assert(middle_high_boundary() <= upper_high() &&
           upper_high() <= upper_high_boundary(),
           "high address must be contained within the region");
    assert(low() >= low_boundary(), "low");
    assert(low_boundary() <= lower_high_boundary(), "lower high boundary");
    assert(upper_high_boundary() <= high_boundary(), "upper high boundary");
    assert(high() <= upper_high(), "upper high");
}

void VirtualSpace::print_on(outputStream *out) {
    out->print("Virtual space:");
    if (special()) out->print(" (pinned in memory)");
    out->cr();
    out->print_cr(" - committed: " SIZE_FORMAT, committed_size());
    out->print_cr(" - reserved:  " SIZE_FORMAT, reserved_size());
    out->print_cr(" - [low, high]:     [" INTPTR_FORMAT ", " INTPTR_FORMAT "]", p2i(low()), p2i(high()));
    out->print_cr(" - [low_b, high_b]: [" INTPTR_FORMAT ", " INTPTR_FORMAT "]", p2i(low_boundary()),
                  p2i(high_boundary()));
}

void VirtualSpace::print() {
    print_on(tty);
}

/////////////// Unit tests ///////////////

#ifndef PRODUCT

#define test_log(...) \
  do {\
    if (VerboseInternalVMTests) { \
      tty->print_cr(__VA_ARGS__); \
      tty->flush(); \
    }\
  } while (false)

class TestReservedSpace : AllStatic {
public:
    static void small_page_write(void *addr, size_t size) {
        size_t page_size = os::vm_page_size();

        char *end = (char *) addr + size;
        for (char *p = (char *) addr; p < end; p += page_size) {
            *p = 1;
        }
    }

    static void release_memory_for_test(ReservedSpace rs) {
        if (rs.special()) {
            guarantee(os::release_memory_special(rs.base(), rs.size()), "Shouldn't fail");
        } else {
            guarantee(os::release_memory(rs.base(), rs.size()), "Shouldn't fail");
        }
    }

    static void test_reserved_space1(size_t size, size_t alignment) {
        test_log("test_reserved_space1(%p)", (void *) (uintptr_t) size);

        assert(is_aligned(size, alignment), "Incorrect input parameters");

        ReservedSpace rs(size,          // size
                         alignment,     // alignment
                         UseLargePages, // large
                         (char *) NULL); // requested_address

        test_log(" rs.special() == %d", rs.special());

        assert(rs.base() != NULL, "Must be");
        assert(rs.size() == size, "Must be");

        assert(is_aligned(rs.base(), alignment), "aligned sizes should always give aligned addresses");
        assert(is_aligned(rs.size(), alignment), "aligned sizes should always give aligned addresses");

        if (rs.special()) {
            small_page_write(rs.base(), size);
        }

        release_memory_for_test(rs);
    }

    static void test_reserved_space2(size_t size) {
        test_log("test_reserved_space2(%p)", (void *) (uintptr_t) size);

        assert(is_aligned(size, os::vm_allocation_granularity()), "Must be at least AG aligned");

        ReservedSpace rs(size);

        test_log(" rs.special() == %d", rs.special());

        assert(rs.base() != NULL, "Must be");
        assert(rs.size() == size, "Must be");

        if (rs.special()) {
            small_page_write(rs.base(), size);
        }

        release_memory_for_test(rs);
    }

    static void test_reserved_space3(size_t size, size_t alignment, bool maybe_large) {
        test_log("test_reserved_space3(%p, %p, %d)",
                 (void *) (uintptr_t) size, (void *) (uintptr_t) alignment, maybe_large);

        if (size < alignment) {
            // Tests might set -XX:LargePageSizeInBytes=<small pages> and cause unexpected input arguments for this test.
            assert((size_t) os::vm_page_size() == os::large_page_size(), "Test needs further refinement");
            return;
        }

        assert(is_aligned(size, os::vm_allocation_granularity()), "Must be at least AG aligned");
        assert(is_aligned(size, alignment), "Must be at least aligned against alignment");

        bool large = maybe_large && UseLargePages && size >= os::large_page_size();

        ReservedSpace rs(size, alignment, large, false);

        test_log(" rs.special() == %d", rs.special());

        assert(rs.base() != NULL, "Must be");
        assert(rs.size() == size, "Must be");

        if (rs.special()) {
            small_page_write(rs.base(), size);
        }

        release_memory_for_test(rs);
    }


    static void test_reserved_space1() {
        size_t size = 2 * 1024 * 1024;
        size_t ag = os::vm_allocation_granularity();

        test_reserved_space1(size, ag);
        test_reserved_space1(size * 2, ag);
        test_reserved_space1(size * 10, ag);
    }

    static void test_reserved_space2() {
        size_t size = 2 * 1024 * 1024;
        size_t ag = os::vm_allocation_granularity();

        test_reserved_space2(size * 1);
        test_reserved_space2(size * 2);
        test_reserved_space2(size * 10);
        test_reserved_space2(ag);
        test_reserved_space2(size - ag);
        test_reserved_space2(size);
        test_reserved_space2(size + ag);
        test_reserved_space2(size * 2);
        test_reserved_space2(size * 2 - ag);
        test_reserved_space2(size * 2 + ag);
        test_reserved_space2(size * 3);
        test_reserved_space2(size * 3 - ag);
        test_reserved_space2(size * 3 + ag);
        test_reserved_space2(size * 10);
        test_reserved_space2(size * 10 + size / 2);
    }

    static void test_reserved_space3() {
        size_t ag = os::vm_allocation_granularity();

        test_reserved_space3(ag, ag, false);
        test_reserved_space3(ag * 2, ag, false);
        test_reserved_space3(ag * 3, ag, false);
        test_reserved_space3(ag * 2, ag * 2, false);
        test_reserved_space3(ag * 4, ag * 2, false);
        test_reserved_space3(ag * 8, ag * 2, false);
        test_reserved_space3(ag * 4, ag * 4, false);
        test_reserved_space3(ag * 8, ag * 4, false);
        test_reserved_space3(ag * 16, ag * 4, false);

        if (UseLargePages) {
            size_t lp = os::large_page_size();

            // Without large pages
            test_reserved_space3(lp, ag * 4, false);
            test_reserved_space3(lp * 2, ag * 4, false);
            test_reserved_space3(lp * 4, ag * 4, false);
            test_reserved_space3(lp, lp, false);
            test_reserved_space3(lp * 2, lp, false);
            test_reserved_space3(lp * 3, lp, false);
            test_reserved_space3(lp * 2, lp * 2, false);
            test_reserved_space3(lp * 4, lp * 2, false);
            test_reserved_space3(lp * 8, lp * 2, false);

            // With large pages
            test_reserved_space3(lp, ag * 4, true);
            test_reserved_space3(lp * 2, ag * 4, true);
            test_reserved_space3(lp * 4, ag * 4, true);
            test_reserved_space3(lp, lp, true);
            test_reserved_space3(lp * 2, lp, true);
            test_reserved_space3(lp * 3, lp, true);
            test_reserved_space3(lp * 2, lp * 2, true);
            test_reserved_space3(lp * 4, lp * 2, true);
            test_reserved_space3(lp * 8, lp * 2, true);
        }
    }

    static void test_reserved_space() {
        test_reserved_space1();
        test_reserved_space2();
        test_reserved_space3();
    }
};

void TestReservedSpace_test() {
    TestReservedSpace::test_reserved_space();
}

#define assert_equals(actual, expected)  \
  assert(actual == expected,             \
         "Got " SIZE_FORMAT " expected " \
         SIZE_FORMAT, actual, expected);

#define assert_ge(value1, value2)                  \
  assert(value1 >= value2,                         \
         "'" #value1 "': " SIZE_FORMAT " '"        \
         #value2 "': " SIZE_FORMAT, value1, value2);

#define assert_lt(value1, value2)                  \
  assert(value1 < value2,                          \
         "'" #value1 "': " SIZE_FORMAT " '"        \
         #value2 "': " SIZE_FORMAT, value1, value2);


class TestVirtualSpace : AllStatic {
    enum TestLargePages {
        Default,
        Disable,
        Reserve,
        Commit
    };

    static ReservedSpace reserve_memory(size_t reserve_size_aligned, TestLargePages mode) {
        switch (mode) {
            default:
            case Default:
            case Reserve:
                return ReservedSpace(reserve_size_aligned);
            case Disable:
            case Commit:
                return ReservedSpace(reserve_size_aligned,
                                     os::vm_allocation_granularity(),
                        /* large */ false, /* exec */ false);
        }
    }

    static bool initialize_virtual_space(VirtualSpace &vs, ReservedSpace rs, TestLargePages mode) {
        switch (mode) {
            default:
            case Default:
            case Reserve:
                return vs.initialize(rs, 0);
            case Disable:
                return vs.initialize_with_granularity(rs, 0, os::vm_page_size());
            case Commit:
                return vs.initialize_with_granularity(rs, 0, os::page_size_for_region_unaligned(rs.size(), 1));
        }
    }

public:
    static void test_virtual_space_actual_committed_space(size_t reserve_size, size_t commit_size,
                                                          TestLargePages mode = Default) {
        size_t granularity = os::vm_allocation_granularity();
        size_t reserve_size_aligned = align_up(reserve_size, granularity);

        ReservedSpace reserved = reserve_memory(reserve_size_aligned, mode);

        assert(reserved.is_reserved(), "Must be");

        VirtualSpace vs;
        bool initialized = initialize_virtual_space(vs, reserved, mode);
        assert(initialized, "Failed to initialize VirtualSpace");

        vs.expand_by(commit_size, false);

        if (vs.special()) {
            assert_equals(vs.actual_committed_size(), reserve_size_aligned);
        } else {
            assert_ge(vs.actual_committed_size(), commit_size);
            // Approximate the commit granularity.
            // Make sure that we don't commit using large pages
            // if large pages has been disabled for this VirtualSpace.
            size_t commit_granularity = (mode == Disable || !UseLargePages) ?
                                        os::vm_page_size() : os::large_page_size();
            assert_lt(vs.actual_committed_size(), commit_size + commit_granularity);
        }

        reserved.release();
    }

    static void test_virtual_space_actual_committed_space_one_large_page() {
        if (!UseLargePages) {
            return;
        }

        size_t large_page_size = os::large_page_size();

        ReservedSpace reserved(large_page_size, large_page_size, true, false);

        assert(reserved.is_reserved(), "Must be");

        VirtualSpace vs;
        bool initialized = vs.initialize(reserved, 0);
        assert(initialized, "Failed to initialize VirtualSpace");

        vs.expand_by(large_page_size, false);

        assert_equals(vs.actual_committed_size(), large_page_size);

        reserved.release();
    }

    static void test_virtual_space_actual_committed_space() {
        test_virtual_space_actual_committed_space(4 * K, 0);
        test_virtual_space_actual_committed_space(4 * K, 4 * K);
        test_virtual_space_actual_committed_space(8 * K, 0);
        test_virtual_space_actual_committed_space(8 * K, 4 * K);
        test_virtual_space_actual_committed_space(8 * K, 8 * K);
        test_virtual_space_actual_committed_space(12 * K, 0);
        test_virtual_space_actual_committed_space(12 * K, 4 * K);
        test_virtual_space_actual_committed_space(12 * K, 8 * K);
        test_virtual_space_actual_committed_space(12 * K, 12 * K);
        test_virtual_space_actual_committed_space(64 * K, 0);
        test_virtual_space_actual_committed_space(64 * K, 32 * K);
        test_virtual_space_actual_committed_space(64 * K, 64 * K);
        test_virtual_space_actual_committed_space(2 * M, 0);
        test_virtual_space_actual_committed_space(2 * M, 4 * K);
        test_virtual_space_actual_committed_space(2 * M, 64 * K);
        test_virtual_space_actual_committed_space(2 * M, 1 * M);
        test_virtual_space_actual_committed_space(2 * M, 2 * M);
        test_virtual_space_actual_committed_space(10 * M, 0);
        test_virtual_space_actual_committed_space(10 * M, 4 * K);
        test_virtual_space_actual_committed_space(10 * M, 8 * K);
        test_virtual_space_actual_committed_space(10 * M, 1 * M);
        test_virtual_space_actual_committed_space(10 * M, 2 * M);
        test_virtual_space_actual_committed_space(10 * M, 5 * M);
        test_virtual_space_actual_committed_space(10 * M, 10 * M);
    }

    static void test_virtual_space_disable_large_pages() {
        if (!UseLargePages) {
            return;
        }
        // These test cases verify that if we force VirtualSpace to disable large pages
        test_virtual_space_actual_committed_space(10 * M, 0, Disable);
        test_virtual_space_actual_committed_space(10 * M, 4 * K, Disable);
        test_virtual_space_actual_committed_space(10 * M, 8 * K, Disable);
        test_virtual_space_actual_committed_space(10 * M, 1 * M, Disable);
        test_virtual_space_actual_committed_space(10 * M, 2 * M, Disable);
        test_virtual_space_actual_committed_space(10 * M, 5 * M, Disable);
        test_virtual_space_actual_committed_space(10 * M, 10 * M, Disable);

        test_virtual_space_actual_committed_space(10 * M, 0, Reserve);
        test_virtual_space_actual_committed_space(10 * M, 4 * K, Reserve);
        test_virtual_space_actual_committed_space(10 * M, 8 * K, Reserve);
        test_virtual_space_actual_committed_space(10 * M, 1 * M, Reserve);
        test_virtual_space_actual_committed_space(10 * M, 2 * M, Reserve);
        test_virtual_space_actual_committed_space(10 * M, 5 * M, Reserve);
        test_virtual_space_actual_committed_space(10 * M, 10 * M, Reserve);

        test_virtual_space_actual_committed_space(10 * M, 0, Commit);
        test_virtual_space_actual_committed_space(10 * M, 4 * K, Commit);
        test_virtual_space_actual_committed_space(10 * M, 8 * K, Commit);
        test_virtual_space_actual_committed_space(10 * M, 1 * M, Commit);
        test_virtual_space_actual_committed_space(10 * M, 2 * M, Commit);
        test_virtual_space_actual_committed_space(10 * M, 5 * M, Commit);
        test_virtual_space_actual_committed_space(10 * M, 10 * M, Commit);
    }

    static void test_virtual_space() {
        test_virtual_space_actual_committed_space();
        test_virtual_space_actual_committed_space_one_large_page();
        test_virtual_space_disable_large_pages();
    }
};

void TestVirtualSpace_test() {
    TestVirtualSpace::test_virtual_space();
}

#endif // PRODUCT

#endif
