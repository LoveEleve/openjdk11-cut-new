# ClassLoading 模块文档索引

> **源码版本**: OpenJDK 11
> **标准环境**: `-Xms8g -Xmx8g -XX:+UseG1GC`，Region=4MB
> **分析标准**: 第 0 节核心原理 + 完整数据结构（sizeof/创建位置/生命周期）+ 真实源码+逐行注释 + Mermaid 关系图 + 总结节

---

## 文档清单

| 文档 | 核心内容 | 状态 |
|------|----------|------|
| [classloading_complete_flow.md](classloading_complete_flow.md) | 类加载端到端全景：`resolve_instance_class_or_null` 6阶段、四种并发场景、Bootstrap 三阶段搜索、数据结构关系图 | ✅ 完整 |
| [ClassLoading-Part1-Bootstrap.md](ClassLoading-Part1-Bootstrap.md) | Bootstrap ClassLoader：`ClassPathEntry` 体系（Dir/Zip/Image）、`load_class` 三阶段搜索、`setup_bootstrap_search_path` | ✅ 完整 |
| [klass_hierarchy.md](klass_hierarchy.md) | Klass 层次结构：oop/klass 二分法、六种 Klass 子类（含 sizeof）、`_layout_helper` 三种编码、`_primary_supers` Cohen's Display、嵌入式 vtable/itable/oop-map、InstanceKlass 创建流程 | ✅ 完整 |
| [system_dictionary_deep_dive.md](system_dictionary_deep_dive.md) | SystemDictionary 深度分析：四张表（Dictionary/PlaceholderTable/LoaderConstraintTable/PD cache）、`resolve_instance_class_or_null` 8阶段逐行分析、四种并发场景、`find_or_define_instance_class` DEFINE_CLASS token | ✅ 完整 |
| [ClassFileParser-Expert-Analysis.md](ClassFileParser-Expert-Analysis.md) | ClassFileParser 专家级分析：字节流解析、ConstantPool/Method/Field 构建、`create_instance_klass` | ✅ 完整 |
| [classfile_parser.md](classfile_parser.md) | ClassFileParser 基础分析（早期版本，与 Expert-Analysis 互补） | ✅ 完整 |
| [class_linking_initialization.md](class_linking_initialization.md) | 类链接与初始化：验证/准备/解析三阶段、`<clinit>` 执行、并发初始化状态机 | ✅ 完整 |
| [ch06_classloader_hierarchy.md](ch06_classloader_hierarchy.md) | 类加载器层次结构：Bootstrap/Platform/App/Custom 四层 | ✅ 完整 |
| [ch07_parent_delegation_loadclass.md](ch07_parent_delegation_loadclass.md) | 双亲委派模型：Java 层 `loadClass` 源码分析 | ✅ 完整 |
| [ch08_defineclass_jni_bridge.md](ch08_defineclass_jni_bridge.md) | defineClass JNI 桥接：从 Java 层到 C++ 层的完整路径 | ✅ 完整 |
| [ch09_classloading_interview_gdb.md](ch09_classloading_interview_gdb.md) | 类加载面试题 + GDB 验证 | ✅ 完整 |

---

## 冗余文档说明

| 文档 | 说明 |
|------|------|
| [InstanceKlass-Expert-Analysis.md](InstanceKlass-Expert-Analysis.md) | ⚠️ **冗余**：内容与 `klass_hierarchy.md` 高度重叠，且质量低于后者（缺少第 0 节、数据结构不完整、算法描述为伪代码）。建议以 `klass_hierarchy.md` 为准，本文档仅作历史参考 |

---

## 阅读顺序建议

```
入门路径：
  ch06（层次结构）→ ch07（双亲委派）→ classloading_complete_flow（全景）

深入路径：
  classloading_complete_flow → ClassLoading-Part1-Bootstrap → system_dictionary_deep_dive
  → klass_hierarchy → ClassFileParser-Expert-Analysis → class_linking_initialization

面试准备：
  classloading_complete_flow（全景骨架）+ system_dictionary_deep_dive（并发细节）
  + klass_hierarchy（数据结构）+ ch09（面试题+GDB）
```

---

*最后更新: 2026-03-02*
