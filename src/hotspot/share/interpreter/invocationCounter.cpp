/*
 * Copyright (c) 1997, 2017, Oracle and/or its affiliates. All rights reserved.
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
#include "interpreter/invocationCounter.hpp"
#include "runtime/frame.hpp"
#include "runtime/handles.inline.hpp"
#include "utilities/ostream.hpp"


// Implementation of InvocationCounter

void InvocationCounter::init() {
  _counter = 0;  // reset all the bits, including the sticky carry
  reset();
}

void InvocationCounter::reset() {
  // Only reset the state and don't make the method look like it's never
  // been executed
  set_state(wait_for_compile);
}

void InvocationCounter::set_carry() {
  set_carry_flag();
  // The carry bit now indicates that this counter had achieved a very
  // large value.  Now reduce the value, so that the method can be
  // executed many more times before re-entering the VM.
  int old_count = count();
  int new_count = MIN2(old_count, (int) (CompileThreshold / 2));
  // prevent from going to zero, to distinguish from never-executed methods
  if (new_count == 0)  new_count = 1;
  if (old_count != new_count)  set(state(), new_count);
  // [LOG] 验证 carry 粘性标志设置
  tty->print_cr("[InvocationCounter::set_carry] carry flag set! "
                "old_count=%d, new_count=%d, _counter=0x%08x, carry_bit=%d",
                old_count, new_count, _counter, carry() ? 1 : 0);
}

void InvocationCounter::set_state(State state) {
  assert(0 <= state && state < number_of_states, "illegal state");
  int init = _init[state];
  // prevent from going to zero, to distinguish from never-executed methods
  if (init == 0 && count() > 0)  init = 1;
  int carry = (_counter & carry_mask);    // the carry bit is sticky
  _counter = (init << number_of_noncount_bits) | carry | state;
}


void InvocationCounter::print() {
  tty->print_cr("invocation count: up = %d, limit = %d, carry = %s, state = %s",
                                   count(), limit(),
                                   carry() ? "true" : "false",
                                   state_as_string(state()));
}

void InvocationCounter::print_short() {
  tty->print(" [%d%s;%s]", count(), carry()?"+carry":"", state_as_short_string(state()));
}

// Initialization

int                       InvocationCounter::_init  [InvocationCounter::number_of_states];
InvocationCounter::Action InvocationCounter::_action[InvocationCounter::number_of_states];
int                       InvocationCounter::InterpreterInvocationLimit;
int                       InvocationCounter::InterpreterBackwardBranchLimit;
int                       InvocationCounter::InterpreterProfileLimit;


const char* InvocationCounter::state_as_string(State state) {
  switch (state) {
    case wait_for_nothing            : return "wait_for_nothing";
    case wait_for_compile            : return "wait_for_compile";
    default:
      ShouldNotReachHere();
      return NULL;
  }
}

const char* InvocationCounter::state_as_short_string(State state) {
  switch (state) {
    case wait_for_nothing            : return "not comp.";
    case wait_for_compile            : return "compileable";
    default:
      ShouldNotReachHere();
      return NULL;
  }
}


static address do_nothing(const methodHandle& method, TRAPS) {
  // dummy action for inactive invocation counters
  MethodCounters* mcs = method->method_counters();
  assert(mcs != NULL, "");
  mcs->invocation_counter()->set_carry();
  mcs->invocation_counter()->set_state(InvocationCounter::wait_for_nothing);
  return NULL;
}


static address do_decay(const methodHandle& method, TRAPS) {
  // decay invocation counters so compilation gets delayed
  MethodCounters* mcs = method->method_counters();
  assert(mcs != NULL, "");
  int before = mcs->invocation_counter()->count();
  mcs->invocation_counter()->decay();
  int after = mcs->invocation_counter()->count();
  // [LOG] 验证衰减机制：计数减半
  tty->print_cr("[do_decay] method=%s, count: %d -> %d (halved=%s)",
                method->name()->as_C_string(),
                before, after,
                (before > 0 && after == before / 2) ? "YES" : (before <= 1 ? "YES(min1)" : "NO!"));
  return NULL;
}


void InvocationCounter::def(State state, int init, Action action) {
  assert(0 <= state && state < number_of_states, "illegal state");
  assert(0 <= init  && init  < count_limit, "initial value out of range");
  _init  [state] = init;
  _action[state] = action;
}

address dummy_invocation_counter_overflow(const methodHandle& m, TRAPS) {
  ShouldNotReachHere();
  return NULL;
}

void InvocationCounter::reinitialize(bool delay_overflow) {
  // define states
  guarantee((int)number_of_states <= (int)state_limit, "adjust number_of_state_bits");
  def(wait_for_nothing, 0, do_nothing);
  if (delay_overflow) {
    def(wait_for_compile, 0, do_decay);
  } else {
    def(wait_for_compile, 0, dummy_invocation_counter_overflow);
  }

  InterpreterInvocationLimit = CompileThreshold << number_of_noncount_bits;
  InterpreterProfileLimit = ((CompileThreshold * InterpreterProfilePercentage) / 100)<< number_of_noncount_bits;

  // When methodData is collected, the backward branch limit is compared against a
  // methodData counter, rather than an InvocationCounter.  In the former case, we
  // don't need the shift by number_of_noncount_bits, but we do need to adjust
  // the factor by which we scale the threshold.
  if (ProfileInterpreter) {
    InterpreterBackwardBranchLimit = (CompileThreshold * (OnStackReplacePercentage - InterpreterProfilePercentage)) / 100;
  } else {
    InterpreterBackwardBranchLimit = ((CompileThreshold * OnStackReplacePercentage) / 100) << number_of_noncount_bits;
  }

  assert(0 <= InterpreterBackwardBranchLimit,
         "OSR threshold should be non-negative");
  assert(0 <= InterpreterProfileLimit &&
         InterpreterProfileLimit <= InterpreterInvocationLimit,
         "profile threshold should be less than the compilation threshold "
         "and non-negative");

  // [LOG] 验证 reinitialize() 阈值计算结果
  tty->print_cr("[InvocationCounter::reinitialize] ===========================================");
  tty->print_cr("[InvocationCounter::reinitialize] delay_overflow=%s", delay_overflow ? "true" : "false");
  tty->print_cr("[InvocationCounter::reinitialize] CompileThreshold=%d", (int)CompileThreshold);
  tty->print_cr("[InvocationCounter::reinitialize] number_of_noncount_bits=%d (= count_shift)", (int)number_of_noncount_bits);
  tty->print_cr("[InvocationCounter::reinitialize] InterpreterInvocationLimit=%d (raw), actual_count=%d",
                InterpreterInvocationLimit, InterpreterInvocationLimit >> number_of_noncount_bits);
  tty->print_cr("[InvocationCounter::reinitialize] InterpreterProfileLimit=%d (raw), actual_count=%d",
                InterpreterProfileLimit, InterpreterProfileLimit >> number_of_noncount_bits);
  tty->print_cr("[InvocationCounter::reinitialize] InterpreterBackwardBranchLimit=%d (ProfileInterpreter=%s)",
                InterpreterBackwardBranchLimit, ProfileInterpreter ? "true" : "false");
  tty->print_cr("[InvocationCounter::reinitialize] sizeof(InvocationCounter)=%zu, sizeof(MethodCounters)=%zu",
                sizeof(InvocationCounter), sizeof(MethodCounters));
  tty->print_cr("[InvocationCounter::reinitialize] count_increment=%d, carry_mask=0x%x, count_mask_value=0x%x",
                (int)count_increment, (int)carry_mask, (int)count_mask_value);
  tty->print_cr("[InvocationCounter::reinitialize] state_machine: wait_for_compile action=%s",
                delay_overflow ? "do_decay" : "dummy_invocation_counter_overflow");
  tty->print_cr("[InvocationCounter::reinitialize] ===========================================");
}

void invocationCounter_init() {
  // [LOG] 验证 invocationCounter_init() 入口
  tty->print_cr("[invocationCounter_init] called, DelayCompilationDuringStartup=%s",
                DelayCompilationDuringStartup ? "true" : "false");
  InvocationCounter::reinitialize(DelayCompilationDuringStartup);
  tty->print_cr("[invocationCounter_init] done.");
}
