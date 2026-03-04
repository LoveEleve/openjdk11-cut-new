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
#include "memory/metaspaceClosure.hpp"
#include "oops/methodCounters.hpp"
#include "runtime/handles.inline.hpp"
#include "utilities/ostream.hpp"

MethodCounters* MethodCounters::allocate(const methodHandle& mh, TRAPS) {
  ClassLoaderData* loader_data = mh->method_holder()->class_loader_data();
  MethodCounters* mc = new(loader_data, method_counters_size(), MetaspaceObj::MethodCountersType, THREAD) MethodCounters(mh);
  // [LOG] 验证 MethodCounters 分配位置（Metaspace）和 per-method 阈值
  // as_C_string() 内部调用 ResourceArea::allocate_bytes，必须有 ResourceMark
  if (mc != NULL && !HAS_PENDING_EXCEPTION) {
    ResourceMark rm(THREAD);
    tty->print_cr("[MethodCounters::allocate] method=%s::%s, mc=%p (Metaspace)",
                  mh->method_holder()->name()->as_C_string(),
                  mh->name()->as_C_string(),
                  mc);
    tty->print_cr("  sizeof(MethodCounters)=%zu bytes", sizeof(MethodCounters));
    tty->print_cr("  _invocation_counter offset=0x%zx, _backedge_counter offset=0x%zx",
                  (size_t)((char*)mc->invocation_counter() - (char*)mc),
                  (size_t)((char*)mc->backedge_counter() - (char*)mc));
    tty->print_cr("  per-method _interpreter_invocation_limit=%d (raw), actual=%d",
                  mc->_interpreter_invocation_limit,
                  mc->_interpreter_invocation_limit >> InvocationCounter::count_shift);
    tty->print_cr("  per-method _interpreter_profile_limit=%d (raw), actual=%d",
                  mc->_interpreter_profile_limit,
                  mc->_interpreter_profile_limit >> InvocationCounter::count_shift);
    tty->print_cr("  per-method _interpreter_backward_branch_limit=%d",
                  mc->_interpreter_backward_branch_limit);
    tty->print_cr("  _nmethod_age=%d (INT_MAX=%d, match=%s)",
                  mc->nmethod_age(), INT_MAX,
                  mc->nmethod_age() == INT_MAX ? "YES" : "NO!");
    tty->print_cr("  invocation_counter initial _counter=0x%08x (state=%d=wait_for_compile?%s)",
                  mc->invocation_counter()->raw_counter(),
                  mc->invocation_counter()->state(),
                  mc->invocation_counter()->state() == InvocationCounter::wait_for_compile ? "YES" : "NO");
  }
  return mc;
}

void MethodCounters::clear_counters() {
  invocation_counter()->reset();
  backedge_counter()->reset();
  set_interpreter_throwout_count(0);
  set_interpreter_invocation_count(0);
  set_nmethod_age(INT_MAX);
#ifdef TIERED
  set_prev_time(0);
  set_rate(0);
  set_highest_comp_level(0);
  set_highest_osr_comp_level(0);
#endif
}


int MethodCounters::highest_comp_level() const {
#ifdef TIERED
  return _highest_comp_level;
#else
  return CompLevel_none;
#endif
}

void MethodCounters::set_highest_comp_level(int level) {
#ifdef TIERED
  _highest_comp_level = level;
#endif
}

int MethodCounters::highest_osr_comp_level() const {
#ifdef TIERED
  return _highest_osr_comp_level;
#else
  return CompLevel_none;
#endif
}

void MethodCounters::set_highest_osr_comp_level(int level) {
#ifdef TIERED
  _highest_osr_comp_level = level;
#endif
}

void MethodCounters::metaspace_pointers_do(MetaspaceClosure* it) {
  log_trace(cds)("Iter(MethodCounters): %p", this);
#if INCLUDE_AOT
  it->push(&_method);
#endif
}

void MethodCounters::print_value_on(outputStream* st) const {
  assert(is_methodCounters(), "must be methodCounters");
  st->print("method counters");
  print_address_on(st);
}


