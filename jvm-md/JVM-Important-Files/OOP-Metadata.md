# OOP 和元数据 (OOP & Metadata) 重要文件

> **源码路径**：`src/hotspot/share/oops/`  
> **重要程度**：⭐⭐⭐⭐⭐

---

## OOP 基础

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `oop.cpp` | ⭐⭐⭐⭐⭐ | OOP (Ordinary Object Pointer) 基础类 |
| `oop.hpp` | ⭐⭐⭐⭐⭐ | OOP 接口定义 |
| `oop.inline.hpp` | ⭐⭐⭐⭐⭐ | OOP 内联函数 |
| `oopsHierarchy.hpp` | ⭐⭐⭐⭐⭐ | OOP 层次结构定义 |

---

## 对象类型

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `instanceOop.cpp` | ⭐⭐⭐⭐⭐ | 实例对象 oop |
| `instanceOop.hpp` | ⭐⭐⭐⭐⭐ | 实例对象接口 |
| `arrayOop.cpp` | ⭐⭐⭐⭐⭐ | 数组对象 oop |
| `arrayOop.hpp` | ⭐⭐⭐⭐⭐ | 数组对象接口 |
| `oopDesc.hpp` | ⭐⭐⭐⭐⭐ | oop 描述基类 |

---

## 类元数据

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `klass.cpp` | ⭐⭐⭐⭐⭐ | 类元数据基类 |
| `klass.hpp` | ⭐⭐⭐⭐⭐ | 类元数据接口 |
| `instanceKlass.cpp` | ⭐⭐⭐⭐⭐ | 实例类的元数据 |
| `instanceKlass.hpp` | ⭐⭐⭐⭐⭐ | 实例类接口 |
| `instanceKlass.inline.hpp` | ⭐⭐⭐⭐⭐ | 实例类内联 |

---

## 数组类型

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `arrayKlass.cpp` | ⭐⭐⭐⭐⭐ | 数组类的元数据 |
| `arrayKlass.hpp` | ⭐⭐⭐⭐⭐ | 数组类接口 |
| `objArrayKlass.cpp` | ⭐⭐⭐⭐⭐ | 对象数组类 |
| `objArrayKlass.hpp` | ⭐⭐⭐⭐⭐ | 对象数组接口 |
| `typeArrayKlass.cpp` | ⭐⭐⭐⭐⭐ | 基本类型数组类 |
| `typeArrayKlass.hpp` | ⭐⭐⭐⭐⭐ | 基本类型数组接口 |

---

## 方法

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `method.cpp` | ⭐⭐⭐⭐⭐ | 方法元数据 |
| `method.hpp` | ⭐⭐⭐⭐⭐ | 方法接口 |
| `method.inline.hpp` | ⭐⭐⭐⭐⭐ | 方法内联 |
| `constMethod.cpp` | ⭐⭐⭐⭐⭐ | 方法字节码存储 |
| `constMethod.hpp` | ⭐⭐⭐⭐⭐ | ConstMethod 接口 |
| `methodData.cpp` | ⭐⭐⭐⭐⭐ | 方法 profiling 数据 |
| `methodData.hpp` | ⭐⭐⭐⭐⭐ | 方法数据接口 |

---

## 常量池

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `constantPool.cpp` | ⭐⭐⭐⭐⭐ | 常量池 |
| `constantPool.hpp` | ⭐⭐⭐⭐⭐ | 常量池接口 |
| `constantPool.inline.hpp` | ⭐⭐⭐⭐⭐ | 常量池内联 |
| `cpCache.cpp` | ⭐⭐⭐⭐⭐ | 方法类型缓存 |
| `cpCache.hpp` | ⭐⭐⭐⭐⭐ | CP 缓存接口 |

---

## 虚函数表

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `klassVtable.cpp` | ⭐⭐⭐⭐⭐ | 虚函数表实现 |
| `klassVtable.hpp` | ⭐⭐⭐⭐⭐ | vtable 接口 |
| `klassItable.cpp` | ⭐⭐⭐⭐⭐ | 接口函数表实现 |
| `klassItable.hpp` | ⭐⭐⭐⭐⭐ | itable 接口 |

---

## 对象头

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `markOop.cpp` | ⭐⭐⭐⭐⭐ | 对象头 mark word |
| `markOop.hpp` | ⭐⭐⭐⭐⭐ | mark 接口 |
| `markOop.inline.hpp` | ⭐⭐⭐⭐⭐ | mark 内联 |

---

## OopMap

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `generateOopMap.cpp` | ⭐⭐⭐⭐⭐ | OopMap 生成 |
| `generateOopMap.hpp` | ⭐⭐⭐⭐⭐ | OopMap 生成器接口 |
| `oopMap.cpp` | ⭐⭐⭐⭐⭐ | OopMap 实现 |
| `oopMap.hpp` | ⭐⭐⭐⭐⭐ | OopMap 接口 |
| `oopMapBlock.cpp` | ⭐⭐⭐⭐⭐ | OopMap 块 |

---

## 辅助类

| 文件名 | 重要程度 | 核心功能 |
|--------|---------|---------|
| `accessFlags.cpp` | ⭐⭐⭐⭐⭐ | 访问标志 |
| `accessFlags.hpp` | ⭐⭐⭐⭐⭐ | 访问标志接口 |
| `annotations.cpp` | ⭐⭐⭐⭐⭐ | 注解 |
| `annotations.hpp` | ⭐⭐⭐⭐⭐ | 注解接口 |
| `constantPoolMirror.cpp` | ⭐⭐⭐⭐ | 常量池镜像 |

---

## 核心数据结构

```cpp
// oopDesc 结构
class oopDesc {
    volatile markOop _mark;
    union _metadata {
        Klass*      _klass;
        narrowKlass _compressed_klass;
    } _metadata;
};

// 对象头 markOop 状态
enum { 
    locked_value             = 0,
    unlocked_value           = 1,
    monitor_value            = 2,
    marked_value             = 3,
    biased_locking_value     = 5
};
```

---

## 核心调用链

```
new Object()
  → CollectedHeap::obj_allocate()
    → instanceOopDesc::allocate()
      → InstanceKlass::allocate_instance()
        → InstanceKlass::allocate_permanent_data_space()
          → InstanceKlass::link_class()
            → ClassFileParser::verify()
              → InstanceKlass::initialize()
```

---

## 学习建议

1. **优先级 P0**：oop.hpp, instanceOop.hpp, klass.hpp, instanceKlass.hpp, method.hpp, markOop.hpp
2. **优先级 P1**：constantPool.hpp, methodData.hpp, klassVtable.cpp, generateOopMap.cpp
3. **优先级 P2**：arrayKlass.cpp, objArrayKlass.cpp, typeArrayKlass.cpp
