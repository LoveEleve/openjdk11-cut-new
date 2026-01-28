/*
 * Copyright (c) 2001, 2018, Oracle and/or its affiliates. All rights reserved.
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
#include "gc/g1/g1BarrierSet.inline.hpp"
#include "gc/g1/g1BarrierSetAssembler.hpp"
#include "gc/g1/g1CardTable.inline.hpp"
#include "gc/g1/g1CollectedHeap.inline.hpp"
#include "gc/g1/g1ThreadLocalData.hpp"
#include "gc/g1/heapRegion.hpp"
#include "gc/g1/satbMarkQueue.hpp"
#include "logging/log.hpp"
#include "oops/access.inline.hpp"
#include "oops/compressedOops.inline.hpp"
#include "oops/oop.inline.hpp"
#include "runtime/interfaceSupport.inline.hpp"
#include "runtime/mutexLocker.hpp"
#include "runtime/thread.inline.hpp"
#include "utilities/macros.hpp"
#ifdef COMPILER1
#include "gc/g1/c1/g1BarrierSetC1.hpp"
#endif
#ifdef COMPILER2
#include "gc/g1/c2/g1BarrierSetC2.hpp"
#endif

class G1BarrierSetC1;
class G1BarrierSetC2;

// forcus G1BarrierSet的静态成功
/*
 * SATB = Snapshot-At-The-Beginning（起始快照）
 *  1.作用：并发标记期间，记录所有被覆盖的旧引用值
 *  2.为什么需要：并发标记时，应用线程还在运行，可能修改引用。如果不记录旧值，可能漏标存活对象
 *  3.工作流程：
 *      - 应用线程修改引用前，把旧值放入线程本地 SATB 队列
 *      - 队列满了，批量提交到全局队列集
 *      - GC 线程处理全局队列，确保旧值指向的对象被标记
 */
SATBMarkQueueSet G1BarrierSet::_satb_mark_queue_set; // note SATB 标记队列集
/*
 * 脏卡队列集（_dirty_card_queue_set）
 *  1.作用：记录被修改的卡表项
 *  2.为什么需要：直接扫描整个卡表太慢，用队列记录哪些卡变脏了
 *  3.工作流程：
 *      - 应用线程修改引用后，把脏卡地址放入线程本地队列
 *      - 队列满了，批量提交到全局队列集
 *      - 并发细化线程（Concurrent Refinement） 后台处理，更新 RSet
 */
DirtyCardQueueSet G1BarrierSet::_dirty_card_queue_set; // note 脏卡队列集

G1BarrierSet::G1BarrierSet(G1CardTable* card_table) :
  // forcus 调用父类CardTableBarrierSet()构造函数
  /*
   * note 三种编译器实现,因为java代码有三种执行方式：1.解释执行 2.C1编译 3.C2编译
   */
/*
* note 知识拓展：类型标签机制
*  在 C++ 中，判断一个对象的实际类型通常用 dynamic_cast，但这需要开启 RTTI（运行时类型信息），会带来性能开销
*  HotSpot JVM 选择自己实现一套轻量级的类型识别机制，就是 FakeRtti（Fake Runtime Type Information，伪运行时类型信息）。
*   每种屏障集都有一个唯一的枚举值作为标签。
*  FakeRtti 内部使用一个位掩码（bitmask） 来存储标签 { uint32_t _tag_set;  // 位掩码，每个bit代表一个标签 }
*   {
         // G1BarrierSet 构造
         G1BarrierSet(...) :
           CardTableBarrierSet(..., FakeRtti(G1BarrierSet))  // 初始标签: G1BarrierSet
                                                              // _tag_set = 0b0100

         // CardTableBarrierSet 构造
         CardTableBarrierSet(...) :
           ModRefBarrierSet(..., fake_rtti.add_tag(CardTableBarrierSet))  // 添加标签
                                                                           // _tag_set = 0b0110

         // ModRefBarrierSet 构造
         ModRefBarrierSet(...) :
           BarrierSet(..., fake_rtti.add_tag(ModRef))  // 添加标签
                                                        // _tag_set = 0b0111
         note 最终 _tag_set = 0b0111，包含了三个标签。
         note 通过is_a()来使用标签
             bool is_a(BarrierSet::Name bsn) const {
                   return _fake_rtti.has_tag(bsn);
                 }
         note 对于 G1BarrierSet（_tag_set = 0b0111）：
             bs->is_a(G1BarrierSet)         // 检查 bit 2: 0b0111 & 0b0100 = 0b0100 ≠ 0 → true
             bs->is_a(CardTableBarrierSet)  // 检查 bit 1: 0b0111 & 0b0010 = 0b0010 ≠ 0 → true
             bs->is_a(ModRef)               // 检查 bit 0: 0b0111 & 0b0001 = 0b0001 ≠ 0 → true
             bs->is_a(ShenandoahBarrierSet) // 检查 bit 3: 0b0111 & 0b1000 = 0b0000 = 0  → false
*   }
*/
  CardTableBarrierSet(make_barrier_set_assembler<G1BarrierSetAssembler>(), // note 创建汇编器，用于生成解释器和运行时 Stub 的屏障汇编代码
                      make_barrier_set_c1<G1BarrierSetC1>(), // 创建C1编译器的屏障支持
                      make_barrier_set_c2<G1BarrierSetC2>(), // 创建C2编译器的屏障支持
                      card_table, // G1CardTable
                      BarrierSet::FakeRtti(BarrierSet::G1BarrierSet)) // note 运行时类型标识，用于 is_a() 检查
                      {}

void G1BarrierSet::enqueue(oop pre_val) {
  // Nulls should have been already filtered.
  assert(oopDesc::is_oop(pre_val, true), "Error");

  if (!_satb_mark_queue_set.is_active()) return;
  Thread* thr = Thread::current();
  if (thr->is_Java_thread()) {
    G1ThreadLocalData::satb_mark_queue(thr).enqueue(pre_val);
  } else {
    MutexLockerEx x(Shared_SATB_Q_lock, Mutex::_no_safepoint_check_flag);
    _satb_mark_queue_set.shared_satb_queue()->enqueue(pre_val);
  }
}

template <class T> void
G1BarrierSet::write_ref_array_pre_work(T* dst, size_t count) {
  if (!_satb_mark_queue_set.is_active()) return;
  T* elem_ptr = dst;
  for (size_t i = 0; i < count; i++, elem_ptr++) {
    T heap_oop = RawAccess<>::oop_load(elem_ptr);
    if (!CompressedOops::is_null(heap_oop)) {
      enqueue(CompressedOops::decode_not_null(heap_oop));
    }
  }
}

void G1BarrierSet::write_ref_array_pre(oop* dst, size_t count, bool dest_uninitialized) {
  if (!dest_uninitialized) {
    write_ref_array_pre_work(dst, count);
  }
}

void G1BarrierSet::write_ref_array_pre(narrowOop* dst, size_t count, bool dest_uninitialized) {
  if (!dest_uninitialized) {
    write_ref_array_pre_work(dst, count);
  }
}

void G1BarrierSet::write_ref_field_post_slow(volatile jbyte* byte) {
  // In the slow path, we know a card is not young
  assert(*byte != G1CardTable::g1_young_card_val(), "slow path invoked without filtering");
  OrderAccess::storeload();
  if (*byte != G1CardTable::dirty_card_val()) {
    *byte = G1CardTable::dirty_card_val();
    Thread* thr = Thread::current();
    if (thr->is_Java_thread()) {
      G1ThreadLocalData::dirty_card_queue(thr).enqueue(byte);
    } else {
      MutexLockerEx x(Shared_DirtyCardQ_lock,
                      Mutex::_no_safepoint_check_flag);
      _dirty_card_queue_set.shared_dirty_card_queue()->enqueue(byte);
    }
  }
}

void G1BarrierSet::invalidate(MemRegion mr) {
  if (mr.is_empty()) {
    return;
  }
  volatile jbyte* byte = _card_table->byte_for(mr.start());
  jbyte* last_byte = _card_table->byte_for(mr.last());
  Thread* thr = Thread::current();
    // skip all consecutive young cards
  for (; byte <= last_byte && *byte == G1CardTable::g1_young_card_val(); byte++);

  if (byte <= last_byte) {
    OrderAccess::storeload();
    // Enqueue if necessary.
    if (thr->is_Java_thread()) {
      for (; byte <= last_byte; byte++) {
        if (*byte == G1CardTable::g1_young_card_val()) {
          continue;
        }
        if (*byte != G1CardTable::dirty_card_val()) {
          *byte = G1CardTable::dirty_card_val();
          G1ThreadLocalData::dirty_card_queue(thr).enqueue(byte);
        }
      }
    } else {
      MutexLockerEx x(Shared_DirtyCardQ_lock,
                      Mutex::_no_safepoint_check_flag);
      for (; byte <= last_byte; byte++) {
        if (*byte == G1CardTable::g1_young_card_val()) {
          continue;
        }
        if (*byte != G1CardTable::dirty_card_val()) {
          *byte = G1CardTable::dirty_card_val();
          _dirty_card_queue_set.shared_dirty_card_queue()->enqueue(byte);
        }
      }
    }
  }
}

void G1BarrierSet::on_thread_create(Thread* thread) {
  // Create thread local data
  // forcus G1ThreadLocalData：每个线程的本地数据
  G1ThreadLocalData::create(thread);
}

void G1BarrierSet::on_thread_destroy(Thread* thread) {
  // Destroy thread local data
  G1ThreadLocalData::destroy(thread);
}

void G1BarrierSet::on_thread_attach(JavaThread* thread) {
  // This method initializes the SATB and dirty card queues before a
  // JavaThread is added to the Java thread list. Right now, we don't
  // have to do anything to the dirty card queue (it should have been
  // activated when the thread was created), but we have to activate
  // the SATB queue if the thread is created while a marking cycle is
  // in progress. The activation / de-activation of the SATB queues at
  // the beginning / end of a marking cycle is done during safepoints
  // so we have to make sure this method is called outside one to be
  // able to safely read the active field of the SATB queue set. Right
  // now, it is called just before the thread is added to the Java
  // thread list in the Threads::add() method. That method is holding
  // the Threads_lock which ensures we are outside a safepoint. We
  // cannot do the obvious and set the active field of the SATB queue
  // when the thread is created given that, in some cases, safepoints
  // might happen between the JavaThread constructor being called and the
  // thread being added to the Java thread list (an example of this is
  // when the structure for the DestroyJavaVM thread is created).
  assert(!SafepointSynchronize::is_at_safepoint(), "We should not be at a safepoint");
  assert(!G1ThreadLocalData::satb_mark_queue(thread).is_active(), "SATB queue should not be active");
  assert(G1ThreadLocalData::satb_mark_queue(thread).is_empty(), "SATB queue should be empty");
  assert(G1ThreadLocalData::dirty_card_queue(thread).is_active(), "Dirty card queue should be active");

  // If we are creating the thread during a marking cycle, we should
  // set the active field of the SATB queue to true.
  if (_satb_mark_queue_set.is_active()) {
    G1ThreadLocalData::satb_mark_queue(thread).set_active(true);
  }
}

void G1BarrierSet::on_thread_detach(JavaThread* thread) {
  // Flush any deferred card marks, SATB buffers and dirty card queue buffers
  CardTableBarrierSet::on_thread_detach(thread);
  G1ThreadLocalData::satb_mark_queue(thread).flush();
  G1ThreadLocalData::dirty_card_queue(thread).flush();
}
