/*
 * Copyright (c) 2018, Oracle and/or its affiliates. All rights reserved.
 * Copyright (c) 2017, Red Hat, Inc. and/or its affiliates.
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
#include "gc/g1/g1Arguments.hpp"
#include "gc/g1/g1CollectedHeap.inline.hpp"
#include "gc/g1/g1CollectorPolicy.hpp"
#include "gc/g1/g1HeapVerifier.hpp"
#include "gc/g1/heapRegion.hpp"
#include "gc/shared/gcArguments.inline.hpp"
#include "runtime/globals.hpp"
#include "runtime/globals_extension.hpp"
#include "runtime/vm_version.hpp"

size_t G1Arguments::conservative_max_heap_alignment() {
  return HeapRegion::max_region_size();
}

void G1Arguments::initialize_verification_types() {
  if (strlen(VerifyGCType) > 0) {
    const char delimiter[] = " ,\n";
    size_t length = strlen(VerifyGCType);
    char* type_list = NEW_C_HEAP_ARRAY(char, length + 1, mtInternal);
    strncpy(type_list, VerifyGCType, length + 1);
    char* save_ptr;

    char* token = strtok_r(type_list, delimiter, &save_ptr);
    while (token != NULL) {
      parse_verification_type(token);
      token = strtok_r(NULL, delimiter, &save_ptr);
    }
    FREE_C_HEAP_ARRAY(char, type_list);
  }
}

void G1Arguments::parse_verification_type(const char* type) {
  if (strcmp(type, "young-normal") == 0) {
    G1HeapVerifier::enable_verification_type(G1HeapVerifier::G1VerifyYoungNormal);
  } else if (strcmp(type, "concurrent-start") == 0) {
    G1HeapVerifier::enable_verification_type(G1HeapVerifier::G1VerifyConcurrentStart);
  } else if (strcmp(type, "mixed") == 0) {
    G1HeapVerifier::enable_verification_type(G1HeapVerifier::G1VerifyMixed);
  } else if (strcmp(type, "remark") == 0) {
    G1HeapVerifier::enable_verification_type(G1HeapVerifier::G1VerifyRemark);
  } else if (strcmp(type, "cleanup") == 0) {
    G1HeapVerifier::enable_verification_type(G1HeapVerifier::G1VerifyCleanup);
  } else if (strcmp(type, "full") == 0) {
    G1HeapVerifier::enable_verification_type(G1HeapVerifier::G1VerifyFull);
  } else {
    log_warning(gc, verify)("VerifyGCType: '%s' is unknown. Available types are: "
                            "young-normal, concurrent-start, mixed, remark, cleanup and full", type);
  }
}
// forcus G1相关的初始化,该方法是在为G1 GC 设置各种默认参数
/*
 * 在该方法中一共初始化了10个参数
 * 1. ParallelGCThreads - STW 阶段并行线程数
 * 2. G1ConcRefinementThreads - 并发 RSet 更新线程数
 * 3. MarkStackSizeMax - 并发标记栈最大容量
 * 4. GCTimeRatio - GC 时间占比目标
 * 5. MaxGCPauseMillis - GC 暂停时间目标(默认为200ms,最核心的调优参数,根据SLA调整)
 * 6. GCPauseIntervalMillis - GC 暂停间隔
 * 7. ParallelRefProcEnabled - 并行引用处理
 * 8. GCDrainStackTargetSize - 任务队列目标大小(负载均衡)
 * 9. LoopStripMiningIter
 * 10. LoopStripMiningStackSize
 */
void G1Arguments::initialize() {
  // forcus 首先调用基类的初始化方法 (核心关注一点就是设置:ScavengeBeforeFullGC == false),也即 g1不需要在full gc之前做一次young gc
  GCArguments::initialize();
  assert(UseG1GC, "Error");
  // forcus 设置 ParallelGCThreads (影响所有STW阶段的并行度)
  /*
   * 等价于: ParallelGCThreads = Abstract_VM_Version::parallel_worker_threads();
   */
  FLAG_SET_DEFAULT(ParallelGCThreads, Abstract_VM_Version::parallel_worker_threads());
  // 如果 ParallelGCThreads == 0,则退出,一般不会
  if (ParallelGCThreads == 0) {
    assert(!FLAG_IS_DEFAULT(ParallelGCThreads), "The default value for ParallelGCThreads should not be 0.");
    vm_exit_during_initialization("The flag -XX:+UseG1GC can not be combined with -XX:ParallelGCThreads=0", NULL);
  }
  // forcus G1ConcRefinementThreads 的作用：并发处理 RSet（Remembered Set）更新的线程数，默认等于 ParallelGCThreads。
  if (FLAG_IS_DEFAULT(G1ConcRefinementThreads)) {
    FLAG_SET_ERGO(uint, G1ConcRefinementThreads, ParallelGCThreads);
  }

  // MarkStackSize will be set (if it hasn't been set by the user)
  // when concurrent marking is initialized.
  // Its value will be based upon the number of parallel marking threads.
  // But we do set the maximum mark stack size here.
  // forcus 并发标记阶段标记栈的最大容量
  /*
   * g1 gc在并发标记阶段用来存储待处理对象引用的数据结构(暂时了解一下)
   */
  if (FLAG_IS_DEFAULT(MarkStackSizeMax)) {
    FLAG_SET_DEFAULT(MarkStackSizeMax, 128 * TASKQUEUE_SIZE); // forcus 64位: 131072 (128K)
  }
  // forcus 1 / (1 + GCTimeRatio)
  if (FLAG_IS_DEFAULT(GCTimeRatio) || GCTimeRatio == 0) {
    // In G1, we want the default GC overhead goal to be higher than
    // it is for PS, or the heap might be expanded too aggressively.
    // We set it here to ~8%.
    FLAG_SET_DEFAULT(GCTimeRatio, 12);
  }

  // Below, we might need to calculate the pause time interval based on
  // the pause target. When we do so we are going to give G1 maximum
  // flexibility and allow it to do pauses when it needs to. So, we'll
  // arrange that the pause interval to be pause time target + 1 to
  // ensure that a) the pause time target is maximized with respect to
  // the pause interval and b) we maintain the invariant that pause
  // time target < pause interval. If the user does not want this
  // maximum flexibility, they will have to set the pause interval
  // explicitly.
  // forcus MaxGCPauseMillis - G1最核心的参数 - 默认 200ms 暂停时间目标
  if (FLAG_IS_DEFAULT(MaxGCPauseMillis)) {
    // The default pause time target in G1 is 200ms
    FLAG_SET_DEFAULT(MaxGCPauseMillis, 200);
  }

  // Then, if the interval parameter was not set, set it according to
  // the pause time target (this will also deal with the case when the
  // pause time target is the default value).
  // forcus GCPauseIntervalMillis 默认 201ms，给 G1 最大灵活性，允许它在需要时立即 GC
  if (FLAG_IS_DEFAULT(GCPauseIntervalMillis)) {
    FLAG_SET_DEFAULT(GCPauseIntervalMillis, MaxGCPauseMillis + 1);
  }
  // forcus 启用并行引用处理 多线程时自动启用，并行处理 Soft/Weak/Phantom Reference。
  if (FLAG_IS_DEFAULT(ParallelRefProcEnabled) && ParallelGCThreads > 1) {
    FLAG_SET_DEFAULT(ParallelRefProcEnabled, true);
  }

  log_trace(gc)("MarkStackSize: %uk  MarkStackSizeMax: %uk", (unsigned int) (MarkStackSize / K), (uint) (MarkStackSizeMax / K));

  // By default do not let the target stack size to be more than 1/4 of the entries
  // forcus 设置 GCDrainStackTargetSize 计算（64位）：min(默认值, 131072/4) = min(默认值, 32768)
  // forcus 用于 GC 工作线程的工作窃取负载均衡
  if (FLAG_IS_DEFAULT(GCDrainStackTargetSize)) {
    FLAG_SET_ERGO(uintx, GCDrainStackTargetSize, MIN2(GCDrainStackTargetSize, (uintx)TASKQUEUE_SIZE / 4));
  }

#ifdef COMPILER2 // forcus 如果开启了C2编译器,那么启用循环安全点
  // forcus Loop Strip Mining：在长循环中每 1000 次迭代插入安全点检查，防止长循环阻塞 GC
  // Enable loop strip mining to offer better pause time guarantees
  if (FLAG_IS_DEFAULT(UseCountedLoopSafepoints)) {
    FLAG_SET_DEFAULT(UseCountedLoopSafepoints, true);
    if (FLAG_IS_DEFAULT(LoopStripMiningIter)) {
      FLAG_SET_DEFAULT(LoopStripMiningIter, 1000);
    }
  }
#endif
  initialize_verification_types();
}

// forcus 这里创建了一个 G1CollectedHeap 对象，还没有真正分配堆内存
CollectedHeap* G1Arguments::create_heap() {
  return create_heap_with_policy<G1CollectedHeap, G1CollectorPolicy>();
}
