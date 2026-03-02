# 代码缓存 (Code Cache) 重要文件

> **源码路径**：`src/hotspot/share/code/`  
> **重要程度**：⭐⭐⭐⭐⭐

---

## 核心

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `codeCache.cpp` | ⭐⭐⭐⭐⭐ | 代码缓存管理 |
| `codeCache.hpp` | ⭐⭐⭐⭐⭐ | 代码缓存接口 |
| `codeCache.inline.hpp` | ⭐⭐⭐⭐⭐ | 代码缓存内联 |
| `codeBlob.cpp` | ⭐⭐⭐⭐⭐ | 代码块抽象 |
| `codeBlob.hpp` | ⭐⭐⭐⭐⭐ | CodeBlob 接口 |

---

## 编译后方法

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `nmethod.cpp` | ⭐⭐⭐⭐⭐ | 编译后方法管理 |
| `nmethod.hpp` | ⭐⭐⭐⭐⭐ | nmethod 接口 |
| `nmethod.inline.hpp` | ⭐⭐⭐⭐⭐ | nmethod 内联 |
| `compiledMethod.cpp` | ⭐⭐⭐⭐⭐ | 编译后方法基类 |
| `compiledMethod.hpp` | ⭐⭐⭐⭐⭐ | 编译方法接口 |

---

## 内联缓存

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `compiledIC.cpp` | ⭐⭐⭐⭐⭐ | 编译后内联缓存 |
| `compiledIC.hpp` | ⭐⭐⭐⭐⭐ | IC 接口 |
| `compiledIC.inline.hpp` | ⭐⭐⭐⭐⭐ | IC 内联 |
| `icBuffer.cpp` | ⭐⭐⭐⭐ | Inline Cache 缓冲区 |
| `icBuffer.hpp` | ⭐⭐⭐⭐ | IC 缓冲区接口 |

---

## 虚表存根

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `vtableStubs.cpp` | ⭐⭐⭐⭐⭐ | 虚表存根生成 |
| `vtableStubs.hpp` | ⭐⭐⭐⭐⭐ | 存根接口 |

---

## 重定位

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `relocInfo.cpp` | ⭐⭐⭐⭐⭐ | 代码重定位信息 |
| `relocInfo.hpp` | ⭐⭐⭐⭐⭐ | 重定位接口 |
| `relocInfo_ext.hpp` | ⭐⭐⭐⭐ | 扩展重定位 |
| `relocator.cpp` | ⭐⭐⭐⭐ | 代码重定位 |

---

## 依赖管理

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `dependencies.cpp` | ⭐⭐⭐⭐⭐ | 编译依赖关系 |
| `dependencies.hpp` | ⭐⭐⭐⭐⭐ | 依赖接口 |

---

## 代码清理

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `sweeper.cpp` | ⭐⭐⭐⭐⭐ | 代码缓存清理（OSR 编译缓存） |
| `sweeper.hpp` | ⭐⭐⭐⭐⭐ | 清理器接口 |

---

## 调试信息

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `debugInfo.cpp` | ⭐⭐⭐⭐⭐ | 调试信息编码 |
| `debugInfo.hpp` | ⭐⭐⭐⭐⭐ | 调试信息接口 |
| `debugInfoRec.cpp` | ⭐⭐⭐⭐ | 调试信息记录 |
| `pcDesc.cpp` | ⭐⭐⭐⭐ | PC 描述 |
| `pcDesc.hpp` | ⭐⭐⭐⭐ | PC 描述接口 |

---

## Scope

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `scopeDesc.cpp` | ⭐⭐⭐⭐ | 作用域描述 |
| `scopeDesc.hpp` | ⭐⭐⭐⭐ | 作用域接口 |

---

## 核心调用链

```
编译完成：
C1Compiler / C2Compiler
  → Compilation::install_code()
    → nmethod::new_nmethod()
      → CodeCache::allocate()
        → CodeBlob::alive()

OSR 编译：
Interpreter::bytecode_counter_reached_backedge_counter()
  → CompiledMethod::has_osr_entry()
    → CompiledMethod::get_osr_entry()
```

---

## 代码缓存结构

```
┌─────────────────────────────────────────┐
│           CodeCache                      │
├─────────────────────────────────────────┤
│ Non-NMethod (Blob::non_nmethod):       │
│   ├── vtableStubs                       │
│   ├── static CallStub                    │
│   ├── runtime stubs                      │
│   └── deoptimization Blob               │
│                                          │
│ NMethod (Blob::nmethod):                 │
│   ├── C1 compiled                       │
│   ├── C2 compiled                       │
│   └── OSR compiled                     │
└─────────────────────────────────────────┘
```

---

## 学习建议

1. **优先级 P0**：codeCache.cpp, nmethod.cpp, compiledIC.cpp, vtableStubs.cpp
2. **优先级 P1**：relocInfo.cpp, dependencies.cpp, sweeper.cpp
3. **优先级 P2**：debugInfo.cpp, scopeDesc.cpp
