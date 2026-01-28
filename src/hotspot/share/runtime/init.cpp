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
#include "classfile/stringTable.hpp"
#include "classfile/symbolTable.hpp"
#include "code/icBuffer.hpp"
#include "gc/shared/collectedHeap.hpp"
#include "interpreter/bytecodes.hpp"
#include "memory/universe.hpp"
#include "prims/methodHandles.hpp"
#include "runtime/flags/jvmFlag.hpp"
#include "runtime/handles.inline.hpp"
#include "runtime/icache.hpp"
#include "runtime/init.hpp"
#include "runtime/safepoint.hpp"
#include "runtime/sharedRuntime.hpp"
#include "services/memTracker.hpp"
#include "utilities/macros.hpp"


// Initialization done by VM thread in vm_init_globals()
void check_ThreadShadow();
void eventlog_init();
void mutex_init();
void chunkpool_init();
void perfMemory_init();
void SuspendibleThreadSet_init();

// Initialization done by Java thread in init_globals()
void management_init();
void bytecodes_init();
void classLoader_init1();
void compilationPolicy_init();
void codeCache_init();
void VM_Version_init();
void os_init_globals();        // depends on VM_Version_init, before universe_init
void stubRoutines_init1();
jint universe_init();          // depends on codeCache_init and stubRoutines_init
// depends on universe_init, must be before interpreter_init (currently only on SPARC)
void gc_barrier_stubs_init();
void interpreter_init();       // before any methods loaded
void invocationCounter_init(); // before any methods loaded
void accessFlags_init();
void templateTable_init();
void InterfaceSupport_init();
void universe2_init();  // dependent on codeCache_init and stubRoutines_init, loads primordial classes
void referenceProcessor_init();
void jni_handles_init();
void vmStructs_init();

void vtableStubs_init();
void InlineCacheBuffer_init();
void compilerOracle_init();
bool compileBroker_init();
void dependencyContext_init();

// Initialization after compiler initialization
bool universe_post_init();  // must happen after compiler_init
void javaClasses_init();  // must happen after vtable initialization
void stubRoutines_init2(); // note: StubRoutines need 2-phase init

// Do not disable thread-local-storage, as it is important for some
// JNI/JVM/JVMTI functions and signal handlers to work properly
// during VM shutdown
void perfMemory_exit();
void ostream_exit();

void vm_init_globals() {
  check_ThreadShadow();// 忽略
  basic_types_init(); // forcus 类型大小设置(比如开启了指针压缩,那么对象引用就用4字节来表示)
  eventlog_init(); // forcus 事件初始化
  mutex_init(); // forcus 初始化互斥锁(jvm运行时所需的60+全局锁)
  chunkpool_init(); // forcus 初始化chunk池(和netty很类似)
  perfMemory_init(); // forcus 性能数据初始化
  SuspendibleThreadSet_init();
}

// forcus forcus forcus core core core
/*
 * 初始化全局变量
 */
jint init_globals() {
  HandleMark hm;
  /*i
        =========================================
        基础设施
        =========================================
   */
  management_init(); // forcus 初始化 JMX(Java Management Extensions)管理接口
  bytecodes_init(); // forcus 初始化字节码表
  classLoader_init1(); // forcus 类加载初始化-1 (在当前情况下,该方法相当于是一个空方法)
  compilationPolicy_init(); // forcus 初始化编译策略(决定何时以及如何将热点代码从解释执行切换到JIT编译执行)
  codeCache_init(); // forcus 初始化代码缓存(codeCache)
  VM_Version_init(); // forcus 检测CPU特性
  os_init_globals(); // 空方法
  stubRoutines_init1(); // forcus 负责生成 JVM 运行时需要的第一批汇编桩代码（Stub Routines）
  jint status = universe_init();  // dependent on codeCache_init and forcus 最重要的初始化方法之一,负责创建 "宇宙" - 包括 Java堆,元空间,符号表等核心数据结构
                                  // stubRoutines_init1 and metaspace_init.
  if (status != JNI_OK)
    return status;

  gc_barrier_stubs_init();   // depends on universe_init, must be before interpreter_init
  interpreter_init();        // before any methods loaded
  invocationCounter_init();  // before any methods loaded
  accessFlags_init();
  templateTable_init();
  InterfaceSupport_init();
  VMRegImpl::set_regName();  // need this before generate_stubs (for printing oop maps).
  SharedRuntime::generate_stubs();
  universe2_init();  // dependent on codeCache_init and stubRoutines_init1
  javaClasses_init();// must happen after vtable initialization, before referenceProcessor_init
  referenceProcessor_init();
  jni_handles_init();
#if INCLUDE_VM_STRUCTS
  vmStructs_init();
#endif // INCLUDE_VM_STRUCTS

  vtableStubs_init();
  InlineCacheBuffer_init();
  compilerOracle_init();
  dependencyContext_init();

  if (!compileBroker_init()) {
    return JNI_EINVAL;
  }

  if (!universe_post_init()) {
    return JNI_ERR;
  }
  stubRoutines_init2(); // note: StubRoutines need 2-phase init
  MethodHandles::generate_adapters();

#if INCLUDE_NMT
  // Solaris stack is walkable only after stubRoutines are set up.
  // On Other platforms, the stack is always walkable.
  NMT_stack_walkable = true;
#endif // INCLUDE_NMT

  // All the flags that get adjusted by VM_Version_init and os::init_2
  // have been set so dump the flags now.
  if (PrintFlagsFinal || PrintFlagsRanges) {
    JVMFlag::printFlags(tty, false, PrintFlagsRanges);
  }

  return JNI_OK;
}


void exit_globals() {
  static bool destructorsCalled = false;
  if (!destructorsCalled) {
    destructorsCalled = true;
    perfMemory_exit();
    if (PrintSafepointStatistics) {
      // Print the collected safepoint statistics.
      SafepointSynchronize::print_stat_on_exit();
    }
    if (PrintStringTableStatistics) {
      SymbolTable::dump(tty);
      StringTable::dump(tty);
    }
    ostream_exit();
  }
}

static volatile bool _init_completed = false;

bool is_init_completed() {
  return _init_completed;
}


void set_init_completed() {
  assert(Universe::is_fully_initialized(), "Should have completed initialization");
  _init_completed = true;
}
