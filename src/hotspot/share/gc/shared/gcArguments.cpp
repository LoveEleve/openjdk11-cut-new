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
#include "gc/shared/gcArguments.hpp"
#include "runtime/arguments.hpp"
#include "runtime/globals.hpp"
#include "runtime/globals_extension.hpp"
#include "utilities/macros.hpp"

void GCArguments::initialize() {
  // -XX:+FullGCALot(调试选项,用于频繁的触发Full GC) and -XX:MarkSweepAlwaysCompactCount (每隔多少次GC执行一次压缩)
  if (FullGCALot && FLAG_IS_DEFAULT(MarkSweepAlwaysCompactCount)) {
    MarkSweepAlwaysCompactCount = 1;  // Move objects every gc. 每次gc的时候都压缩移动对象,更容易暴露对象移动相关的bug,生产环境不建议开启
  }
  // Parallel GC：Young GC 和 Full GC 是分开的，先做 Young GC 可以减少 Full GC 的工作量
  // 对于G1 GC来说,不需要这个
  // forcus 对于G1 GC来说,会设置 ScavengeBeforeFullGC 参数 = false
  if (!(UseParallelGC || UseParallelOldGC) && FLAG_IS_DEFAULT(ScavengeBeforeFullGC)) {
    FLAG_SET_DEFAULT(ScavengeBeforeFullGC, false);
  }
  // GCTimeLimit 边界处理 GC 时间占比上限（默认 98%）
  /*
   * 如果用户设置了 GCTimeLimit 为 100% (也即允许100%时间用于GC)，说明用户不想要GC开销检查(因为你都允许100%时间了,还检查个damn)
   * 一般不会开启,jvm默认会在GC时间超过98%的时候就抛出异常 - OutOfMemoryError: GC overhead limit exceeded
   */
  if (GCTimeLimit == 100) {
    // Turn off gc-overhead-limit-exceeded checks
    FLAG_SET_DEFAULT(UseGCOverheadLimit, false); // 是否检查 GC 开销超限
  }
  // MinHeapFreeRatio 边界修正 堆最小空闲比例，低于此值会扩容
  // 100% 空闲意味着堆里不能有任何对象，这是不可能的，所以强制改为 99%
  if (MinHeapFreeRatio == 100) {
    // Keeping the heap 100% free is hard ;-) so limit it to 99%.
    FLAG_SET_ERGO(uintx, MinHeapFreeRatio, 99);
  }

  if (!ClassUnloading) {
    // If class unloading is disabled, also disable concurrent class unloading.
    FLAG_SET_CMDLINE(bool, ClassUnloadingWithConcurrentMark, false);
  }
}
