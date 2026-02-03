/*
 * Copyright (c) 2002, 2015, Oracle and/or its affiliates. All rights reserved.
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
#include "gc/shared/collectorCounters.hpp"
#include "memory/allocation.inline.hpp"
#include "memory/resourceArea.hpp"
#include "runtime/os.hpp"
/*
    计数器创建	                jstat 对应名称	                                含义	jstat 列
    collector.0.invocations	    sun.gc.collector.0.invocations	                Young/Mixed GC 次数	YGC
    collector.0.time	        sun.gc.collector.0.time	Young/Mixed             GC 耗时	YGCT
    collector.1.invocations	    sun.gc.collector.1.invocations	                Full GC 次数	FGC
    collector.1.time	        sun.gc.collector.1.time	                        Full GC 耗时	FGCT
 */
CollectorCounters::CollectorCounters(const char* name, int ordinal) {

  if (UsePerfData) {
    EXCEPTION_MARK;
    ResourceMark rm;
      // 创建命名空间: "sun.gc.collector.{ordinal}"
    const char* cns = PerfDataManager::name_space("collector", ordinal);

    _name_space = NEW_C_HEAP_ARRAY(char, strlen(cns)+1, mtGC);
    strcpy(_name_space, cns);

      // 1. collector.N.name        - GC名称 (字符串常量)
    char* cname = PerfDataManager::counter_name(_name_space, "name");
    PerfDataManager::create_string_constant(SUN_GC, cname, name, CHECK);
      // 2. collector.N.invocations - GC调用次数
    cname = PerfDataManager::counter_name(_name_space, "invocations");
    _invocations = PerfDataManager::create_counter(SUN_GC, cname,
                                                   PerfData::U_Events, CHECK);
      // 3. collector.N.time        - GC总耗时
    cname = PerfDataManager::counter_name(_name_space, "time");
    _time = PerfDataManager::create_counter(SUN_GC, cname, PerfData::U_Ticks,
                                            CHECK);
      // 4. collector.N.lastEntryTime - 最近一次GC开始时间
    cname = PerfDataManager::counter_name(_name_space, "lastEntryTime");
    _last_entry_time = PerfDataManager::create_variable(SUN_GC, cname,
                                                        PerfData::U_Ticks,
                                                        CHECK);
      // 5. collector.N.lastExitTime  - 最近一次GC结束时间
    cname = PerfDataManager::counter_name(_name_space, "lastExitTime");
    _last_exit_time = PerfDataManager::create_variable(SUN_GC, cname,
                                                       PerfData::U_Ticks,
                                                       CHECK);
  }
}

CollectorCounters::~CollectorCounters() {
  if (_name_space != NULL) {
    FREE_C_HEAP_ARRAY(char, _name_space);
  }
}

TraceCollectorStats::TraceCollectorStats(CollectorCounters* c) :
    PerfTraceTimedEvent(c->time_counter(), c->invocation_counter()),
    _c(c) {

  if (UsePerfData) {
     _c->last_entry_counter()->set_value(os::elapsed_counter());
  }
}

TraceCollectorStats::~TraceCollectorStats() {
  if (UsePerfData) {
    _c->last_exit_counter()->set_value(os::elapsed_counter());
  }
}
