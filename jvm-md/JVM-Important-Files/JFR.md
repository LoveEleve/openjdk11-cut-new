# JFR (Java Flight Recorder) 重要文件

> **源码路径**：`src/hotspot/share/jfr/`  
> **重要程度**：⭐⭐⭐⭐

---

## 核心

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `jfr.cpp` | ⭐⭐⭐⭐ | JFR 入口 |
| `jfr.hpp` | ⭐⭐⭐⭐ | JFR 接口 |
| `jfrJavaSupport.cpp` | ⭐⭐⭐⭐ | Java 支持 |
| `jfrJavaSupport.hpp` | ⭐⭐⭐⭐ | Java 支持接口 |

---

## 录制器

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `recorder/jfrRecorder.cpp` | ⭐⭐⭐⭐ | 录制器主控 |
| `recorder/jfrRecorder.hpp` | ⭐⭐⭐⭐ | 录制器接口 |
| `recorder/jfrStorage.cpp` | ⭐⭐⭐⭐⭐ | 事件存储管理 |
| `recorder/jfrStorage.hpp` | ⭐⭐⭐⭐⭐ | 存储接口 |
| `recorder/jfrCheckpointManager.cpp` | ⭐⭐⭐⭐ | 检查点管理 |
| `recorder/jfrCheckpointManager.hpp` | ⭐⭐⭐⭐ | 检查点接口 |
| `recorder/jfrRecording.cpp` | ⭐⭐⭐⭐ | 录制实例 |

---

## 事件

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `jfrEvent.cpp` | ⭐⭐⭐⭐ | 事件基类 |
| `jfrEvent.hpp` | ⭐⭐⭐⭐ | 事件接口 |
| `jfrEventLevel.cpp` | ⭐⭐⭐⭐ | 事件级别 |
| `jfrEventSettings.cpp` | ⭐⭐⭐⭐ | 事件设置 |

---

## 周期性事件

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `periodic/jfrPeriodic.cpp` | ⭐⭐⭐⭐ | 周期性事件 |
| `periodic/jfrPeriodic.hpp` | ⭐⭐⭐⭐ | 周期性接口 |
| `periodic/sampling/jfrThreadSampler.cpp` | ⭐⭐⭐⭐ | 线程采样 |
| `periodic/sampling/jfrThreadSampler.hpp` | ⭐⭐⭐⭐ | 采样接口 |

---

## 栈追踪

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `recorder/stacktrace/jfrStackTrace.cpp` | ⭐⭐⭐⭐⭐ | 栈追踪 |
| `recorder/stacktrace/jfrStackTrace.hpp` | ⭐⭐⭐⭐⭐ | 栈追踪接口 |
| `recorder/stacktrace/jfrStackTraceRepository.cpp` | ⭐⭐⭐⭐ | 栈追踪仓库 |

---

## 类型集合

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `recorder/checkpoint/types/jfrTypeSet.cpp` | ⭐⭐⭐⭐ | 类型集合 |
| `recorder/checkpoint/types/jfrTypeSet.hpp` | ⭐⭐⭐⭐ | 类型集合接口 |
| `recorder/checkpoint/types/jfrType.cpp` | ⭐⭐⭐⭐ | 类型实现 |

---

## 泄漏分析

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `leakprofiler/sampling/objectSampler.cpp` | ⭐⭐⭐⭐ | 对象泄漏采样 |
| `leakprofiler/sampling/objectSampler.hpp` | ⭐⭐⭐⭐ | 采样接口 |
| `leakprofiler/leakProfiler.cpp` | ⭐⭐⭐⭐ | 泄漏分析器 |

---

## 事件转换

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `instrumentation/jfrEventClassTransformer.cpp` | ⭐⭐⭐⭐ | 事件类转换 |
| `instrumentation/jfrEventClassTransformer.hpp` | ⭐⭐⭐⭐ | 转换接口 |
| `instrumentation/jfrInstrumentation.cpp` | ⭐⭐⭐⭐ | 插桩 |

---

## 诊断命令

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `dcmd/jfrDcmds.cpp` | ⭐⭐⭐⭐⭐ | JFR 诊断命令 |
| `dcmd/jfrDcmds.hpp` | ⭐⭐⭐⭐⭐ | 命令接口 |

---

## 缓冲区

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `recorder/buffer/jfrBuffer.cpp` | ⭐⭐⭐⭐ | 缓冲区管理 |
| `recorder/buffer/jfrBuffer.hpp` | ⭐⭐⭐⭐ | 缓冲区接口 |
| `recorder/buffer/jfrMemoryBuffer.cpp` | ⭐⭐⭐⭐ | 内存缓冲区 |

---

## 核心调用链

```
JFR 录制：
JFR::start()
  → JfrRecorder::start()
    → JfrStorage::start()
      → JfrCheckpointManager::write_checkpoint()

事件记录：
Event::commit()
  → JfrStorage::add_event()
    → JfrBuffer::put()
      → 写入内存缓冲区

检查点：
JfrCheckpointManager::write_checkpoint()
  → JfrTypeSet::serialize()
    → 写入元数据
```

---

## 学习建议

1. **优先级 P1**：jfrRecorder.cpp, jfrStorage.cpp, jfrStackTrace.cpp, jfrDcmds.cpp
2. **优先级 P2**：periodic/jfrPeriodic.cpp, leakprofiler/*.cpp
