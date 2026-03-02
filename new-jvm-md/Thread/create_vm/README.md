# Threads::create_vm 完整分析

> 目标：彻底理解 Threads::create_vm 方法
> 源码位置：`src/hotspot/share/runtime/thread.cpp:3876-4307`
> 标准环境：-Xms8g -Xmx8g -XX:+UseG1GC

---

## 分析计划

本系列将 `Threads::create_vm` 拆分为多个详细文档，每个文档都深入分析一个阶段或主题。

### 已完成

| 序号 | 文档 | 内容 |
|------|------|------|
| 0 | [**全景宏观理解**](./0-Macro-Understanding.md) | **设计哲学、12阶段依赖分析、三明治结构** |
| 1 | [Phase 1: 前置检查](./1-Phase1-Pre-Check.md) | VM_Version、TLS、输出流初始化 |
| 2 | [Phase 2: OS与参数解析](./2-Phase2-OS-Arguments.md) | 参数解析、自动调优、Ergonomics |
| 3 | [Phase 5: 线程创建](./3-Phase5-Thread-Creation.md) | JavaThread、OSThread、栈保护页 |
| 4 | [Phase 6: init_globals](./4-Phase6-init_globals.md) | 核心模块初始化、堆、元空间 |
| 5 | [**Phase 6: universe_init 深入**](./5-universe_init-Deep-Dive.md) | **堆创建、压缩指针、Metaspace、符号表、GDB验证** |
| 6 | [**Phase 6: G1CollectedHeap::initialize**](./6-G1CollectedHeap-initialize-Deep-Dive.md) | **6个映射器、2048 Region、CardTable、ConcurrentMark、GDB验证** |
| 7 | [**Phase 7: VMThread**](./7-VMThread-Deep-Dive.md) | **VMThread事件循环、VMOperationQueue、SafepointSynchronize、GDB验证** |

### 待完成

| 序号 | 文档 | 内容 |
|------|------|------|
| 8 | Phase 8: Java类初始化 | 核心类加载 |
| 9 | Phase 9-12: 服务初始化 | AttachListener、ServiceThread |

---

## 核心调用链

```
JavaMain
  → JNI_CreateJavaVM
    → Threads::create_vm
      → Phase 1: 前置检查
      → Phase 2: OS + 参数解析
      → Phase 3: 安全点
      → Phase 4: Agent
      → Phase 5: 线程创建
        → vm_init_globals
      → Phase 6: 核心模块
        → init_globals
          → universe_init
            → Universe::initialize_heap
              → G1CollectedHeap::initialize
      → Phase 7: VMThread
      → Phase 8: Java类初始化
      → Phase 9: 服务初始化
      → Phase 10-12: 完成
```

---

## 核心对象创建顺序

1. JavaThread（主线程对象）
2. OSThread（OS 线程描述）
3. G1CollectedHeap（堆管理）
4. HeapRegionManager（Region 管理）
5. G1CardTable（卡表Thread（GC 后台线程）
7. ServiceThread（）
6. VMJVMTI 事件）
8. WatcherThread（定期任务）

---

## 文档规范

每篇文档包含：
1. **宏观理解**：整体定位和作用
2. **逐行分析**：每个关键步骤的详细解释
3. **数据结构**：涉及的 C++ 结构
4. **GDB 验证**：实际运行验证
5. **总结**：核心发现

---

## 更新日志

- 2026-02-14: 创建主索引，开始分析
- 2026-02-23: 完成 #5 universe_init 深度分析（含 GDB 验证）
- 2026-02-23: 完成 #6 G1CollectedHeap::initialize 深度分析（含 GDB 验证）
- 2026-02-24: 完成 #7 VMThread 深度分析（含 GDB 验证）
