# 类加载 (Class Loading) 重要文件

> **源码路径**：`src/hotspot/share/classfile/`  
> **重要程度**：⭐⭐⭐⭐⭐

---

## 第 0 部分：核心原理 ⭐

### 0.1 本质是什么？

本文是 **类加载 (Class Loading) 重要文件** 的源码导航地图：列出该模块最重要的源码文件，说明每个文件的核心职责，帮助快速定位关键代码。

### 0.2 为什么需要？

JVM 源码体量庞大（HotSpot 约 200 万行），直接阅读容易迷失。有一份「重要文件地图」，能让学习者快速找到核心代码，避免在次要代码上浪费时间。

### 0.3 怎么解决？

按功能模块分类整理源码文件，标注每个文件的重要程度（⭐ 数量）和核心职责，并指出文件间的依赖关系。

### 0.4 为什么这样设计？

优先级排序基于「对理解 JVM 核心行为的贡献度」：直接影响 GC/JIT/类加载等核心机制的文件优先级最高。

---


## 核心类加载

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `classFileParser.cpp` | ⭐⭐⭐⭐⭐ | .class 文件解析核心 |
| `classFileParser.hpp` | ⭐⭐⭐⭐⭐ | 类解析器接口 |
| `classLoader.cpp` | ⭐⭐⭐⭐⭐ | 类加载器实现 |
| `classLoader.hpp` | ⭐⭐⭐⭐⭐ | 类加载器接口 |
| `systemDictionary.cpp` | ⭐⭐⭐⭐⭐ | 系统字典，维护已加载类 |
| `systemDictionary.hpp` | ⭐⭐⭐⭐⭐ | 系统字典接口 |
| `classLoaderData.cpp` | ⭐⭐⭐⭐⭐ | 类加载器数据管理 |
| `classLoaderData.hpp` | ⭐⭐⭐⭐⭐ | CLD 接口 |

---

## 类解析与验证

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `verifier.cpp` | ⭐⭐⭐⭐⭐ | 字节码验证器 |
| `verifier.hpp` | ⭐⭐⭐⭐⭐ | 验证器接口 |
| `classFileParser.cpp` | ⭐⭐⭐⭐⭐ | .class 文件解析 |

---

## 符号与字符串

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `symbolTable.cpp` | ⭐⭐⭐⭐⭐ | 符号表 |
| `symbolTable.hpp` | ⭐⭐⭐⭐⭐ | 符号表接口 |
| `stringTable.cpp` | ⭐⭐⭐⭐⭐ | 字符串池 |
| `stringTable.hpp` | ⭐⭐⭐⭐⭐ | 字符串池接口 |
| `vmSymbols.cpp` | ⭐⭐⭐⭐⭐ | JVM 符号定义 |
| `vmSymbols.hpp` | ⭐⭐⭐⭐⭐ | JVM 符号接口 |

---

## 字典与约束

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `dictionary.cpp` | ⭐⭐⭐⭐⭐ | 类名字典 |
| `dictionary.hpp` | ⭐⭐⭐⭐⭐ | 字典接口 |
| `loaderConstraints.cpp` | ⭐⭐⭐⭐ | 类加载器约束验证 |
| `loaderConstraints.hpp` | ⭐⭐⭐⭐ | 约束接口 |
| `protectionDomainCache.cpp` | ⭐⭐⭐⭐ | 保护域缓存 |
| `protectionDomainCache.hpp` | ⭐⭐⭐⭐ | 保护域接口 |

---

## Java 核心类

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `javaClasses.cpp` | ⭐⭐⭐⭐⭐ | Java 核心类 (Object, String, Class) 的 native 布局 |
| `javaClasses.hpp` | ⭐⭐⭐⭐⭐ | Java 类接口 |
| `javaClasses_inlines.hpp` | ⭐⭐⭐⭐⭐ | Java 类内联函数 |

---

## 模块系统

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `modules.cpp` | ⭐⭐⭐⭐⭐ | 模块系统实现 |
| `modules.hpp` | ⭐⭐⭐⭐⭐ | 模块接口 |
| `moduleEntry.cpp` | ⭐⭐⭐⭐⭐ | 模块入口管理 |
| `moduleEntry.hpp` | ⭐⭐⭐⭐⭐ | 模块入口接口 |
| `packageEntry.cpp` | ⭐⭐⭐⭐⭐ | 包管理 |
| `packageEntry.hpp` | ⭐⭐⭐⭐⭐ | 包入口接口 |

---

## 默认方法

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `defaultMethods.cpp` | ⭐⭐⭐⭐ | 默认方法处理 |
| `defaultMethods.hpp` | ⭐⭐⭐⭐ | 默认方法接口 |

---

## CDS 共享

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `systemDictionaryShared.cpp` | ⭐⭐⭐⭐ | CDS 共享类字典 |
| `classLoaderDataShared.cpp` | ⭐⭐⭐⭐ | CDS 共享数据 |

---

## 哈希表

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `hashtable.cpp` | ⭐⭐⭐⭐ | 哈希表实现 |
| `hashtable.hpp` | ⭐⭐⭐⭐ | 哈希表接口 |
| `compactHashtable.cpp` | ⭐⭐⭐⭐ | 压缩哈希表 |
| `compactHashtable.hpp` | ⭐⭐⭐⭐ | 压缩哈希表接口 |

---

## 关键数据流

```
.class 文件
    ↓
ClassFileParser::parse_stream()
    ├── 验证魔数和版本
    ├── 解析常量池
    ├── 解析类属性
    └── 返回 InstanceKlass
    ↓
SystemDictionary::resolve_or_fail()
    ├── 查找已加载类
    ├── 加载父类
    ├── 加载接口
    └── 验证
    ↓
InstanceKlass
    ↓
ClassLoaderData
    ↓
加入 SystemDictionary
```

---

## 学习建议

1. **优先级 P0**：classFileParser.cpp, systemDictionary.cpp, classLoaderData.cpp, javaClasses.cpp
2. **优先级 P1**：verifier.cpp, symbolTable.cpp, stringTable.cpp, vmSymbols.cpp
3. **优先级 P2**：modules.cpp, packageEntry.cpp, loaderConstraints.cpp
