/*
 * Copyright (c) 2015, Oracle and/or its affiliates. All rights reserved.
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

#include "runtime/threadLocalStorage.hpp"
#include <pthread.h>

static pthread_key_t _thread_key;
static bool _initialized = false;

// Restore the thread pointer if the destructor is called. This is in case
// someone from JNI code sets up a destructor with pthread_key_create to run
// detachCurrentThread on thread death. Unless we restore the thread pointer we
// will hang or crash. When detachCurrentThread is called the key will be set
// to null and we will not be called again. If detachCurrentThread is never
// called we could loop forever depending on the pthread implementation.
extern "C" void restore_thread_pointer(void* p) {
  ThreadLocalStorage::set_thread((Thread*) p);
}
// forcus : ThreadLocal
/*
 * 在java中ThreadLocal的构思是怎么样的呢？
 *  每个线程对象(Thread)都会有一个ThreadLocalMap,专门用来存储各个ThreadLocal(key) + Value
 *  所以在这里我认为结构应该是这样的：
 *      ThreadLocal tl = new ThreadLocal(); --> 在这里就是 pthread_key_t _thread_key
 *      tl.set(currentThread); --> 在这里是：pthread_setspecific(_thread_key, thread_A_ptr);  // 存入 0x100 每个线程存储自己的值
 *      Thread currentThread = t1.get() --> 在这里是：pthread_getspecific(_thread_key);
 *      ==== 经过后面的学习
 *      ps : 这里好像存储的是 JavaThread对象(每个os线程都会对应一个JavaThread对象)
 */
void ThreadLocalStorage::init() {
  assert(!_initialized, "initializing TLS more than once!");
  int rslt = pthread_key_create(&_thread_key, restore_thread_pointer);
  // If this assert fails we will get a recursive assertion failure
  // and not see the actual error message or get a hs_err file
  assert_status(rslt == 0, rslt, "pthread_key_create");
  _initialized = true; // 只能初始化一次
}

bool ThreadLocalStorage::is_initialized() {
  return _initialized;
}

Thread* ThreadLocalStorage::thread() {
  // If this assert fails we will get a recursive assertion failure
  // and not see the actual error message or get a hs_err file.
  // Which most likely indicates we have taken an error path early in
  // the initialization process, which is using Thread::current without
  // checking TLS is initialized - see java.cpp vm_exit
  assert(_initialized, "TLS not initialized yet!");
  return (Thread*) pthread_getspecific(_thread_key); // may be NULL
}

void ThreadLocalStorage::set_thread(Thread* current) {
  assert(_initialized, "TLS not initialized yet!");
  int rslt = pthread_setspecific(_thread_key, current);
  assert_status(rslt == 0, rslt, "pthread_setspecific");
}
