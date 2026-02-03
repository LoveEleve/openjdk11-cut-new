/*
 * Copyright (c) 2018, Oracle and/or its affiliates. All rights reserved.
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

#ifndef SHARE_VM_GC_SHARED_STRINGDEDUP_STRINGDEDUP_INLINE_HPP
#define SHARE_VM_GC_SHARED_STRINGDEDUP_STRINGDEDUP_INLINE_HPP

#include "gc/shared/stringdedup/stringDedup.hpp"
#include "gc/shared/stringdedup/stringDedupThread.inline.hpp"

template <typename Q, typename S>
void StringDedup::initialize_impl() {
  if (UseStringDeduplication) { // UseStringDeduplication = 1
    _enabled = true;// 设置启用标志
    /*
        G1StringDedupQueue
        {
            _cursor(0),          // 当前消费位置
            _cancel(false),      // 取消标志
            _empty(true),        // 队列空标志
            _dropped(0) {        // 丢弃计数
            _nqueues = ParallelGCThreads;  // 13 个队列 (计算出来的13个并行线程数,实际上我的为16C)
             _queues = NEW_C_HEAP_ARRAY(G1StringDedupWorkerQueue, _nqueues, mtGC);
             for (size_t i = 0; i < _nqueues; i++) {
                new (_queues + i) G1StringDedupWorkerQueue(..., _max_size);  // 每个队列最大 100万
              }
        }
        forcus 从这个可以看出来,每个 GC Worker 有独立队列
            每个 Worker 往自己的队列 push，无锁竞争
            去重线程 round-robin 从各队列 pop
     */
    StringDedupQueue::create<Q>(); // step-1: 创建队列(G1StringDedupQueue)
    /*
        StringDedupTable
        {
            _size = 1024
            _entries = 0
            _grow_threshold = 2048 (200% 负载时扩容 - 1024 * 2.0 = 2048)
            _shrink_threshold = 682 (67% 负载时缩容 1024 * 0.67 = 682)
            _hash_seed = 0
            _buckets = 0x7ffff0c89780 (哈希桶数组)
                {
                        [0] NULL → StringDedupEntry → StringDedupEntry → NULL (链表)
                            {
                                _next: StringDedupEntry* : 链表下一个
                                 _hash: unsigned int: 哈希值
                                 _latin1: bool  : 是否 Latin1 编码
                                 _obj: typeArrayOop  : 指向 char[]/byte[] (弱引用)
                            }
                        [1] NULL
                        [2] NULL
                }
        }
     */
    StringDedupTable::create();  // step-2: 创建哈希表
    /*
        StringDedupThread // 继承自 ConcurrentGCThread
        {
            线程名设为 "StrDedup"
            // 创建并启动线程
        }
     */
    StringDedupThreadImpl<S>::create(); // step-3: 创建后台线程
  }
}

#endif // SHARE_VM_GC_SHARED_STRINGDEDUP_STRINGDEDUP_INLINE_HPP
