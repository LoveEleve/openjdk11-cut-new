# Lesson 10: FlameGraph 输出格式深度解析

## 一、整体架构

FlameGraph 输出的核心是将采样数据转换为可交互的 HTML 火焰图。

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      FlameGraph 输出流水线                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   采样数据                Trie 构建                  HTML 输出            │
│  ┌─────────┐          ┌───────────┐            ┌───────────┐           │
│  │CallTrace│  ──────▶ │   Trie    │  ────────▶ │ flame.html│           │
│  │ Storage │          │  树形结构   │            │  交互式    │           │
│  └─────────┘          └───────────┘            └───────────┘           │
│       │                     │                        │                  │
│       │                     │                        │                  │
│       ▼                     ▼                        ▼                  │
│  哈希表存储            Trie* 链表              常量池压缩                │
│  去重+计数             层级关系                前缀压缩                  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 源码文件结构

```
/data/workspace/async-profiler/src/
├── flameGraph.cpp        # FlameGraph 核心实现
├── flameGraph.h          # Trie 树结构定义
├── writer.cpp            # 输出抽象层
├── writer.h              # Writer 接口定义
├── incbin.h              # 二进制嵌入工具
└── res/
    ├── flame.html        # FlameGraph 模板
    └── tree.html         # Tree 视图模板
```

---

## 二、Trie 数据结构深度解析

### 2.1 Trie 类定义（逐字段解析）

```cpp
// flameGraph.h:17-68
class Trie {
  public:
    std::map<u32, Trie*> _children;  // 子节点映射
    u64 _total;                       // 总采样数
    u64 _self;                        // 自身采样数（不含子节点）
    u64 _inlined, _c1_compiled, _interpreted;  // Java 特殊帧类型计数
```

**字段详解：**

| 字段 | 类型 | 大小 | 作用 | 典型值 |
|-----|------|-----|------|-------|
| `_children` | `std::map<u32, Trie*>` | 48 bytes (指针) | 存储子节点，key = name_index \| (type << 28) | `{0x50000001: Trie*, 0x60000002: Trie*}` |
| `_total` | `u64` | 8 bytes | 该帧及其所有子帧的总采样数 | 1000 |
| `_self` | `u64` | 8 bytes | 该帧自身采样数（叶节点特有） | 50 |
| `_inlined` | `u64` | 8 bytes | 内联帧计数 | 200 |
| `_c1_compiled` | `u64` | 8 bytes | C1 编译帧计数 | 100 |
| `_interpreted` | `u64` | 8 bytes | 解释执行帧计数 | 50 |

**总大小：80 + std::map 开销 ≈ 80-128 bytes per Trie node**

### 2.2 key 编码方案

```cpp
// 32位 key 编码
// ┌─────────────────────────────────┬───────────────────────────────┐
// │     高 4 位: FrameTypeId        │      低 28 位: name_index      │
// │     (FRAME_NATIVE = 5)          │      (方法名在 cpool 中的索引)  │
// └─────────────────────────────────┴───────────────────────────────┘
//   31..28                              27..0
```

**FrameTypeId 枚举值：**

```cpp
// vmEntry.h 中的定义
enum FrameTypeId {
    FRAME_INTERPRETED  = 0,  // 解释执行
    FRAME_JIT_COMPILED = 1,  // JIT 编译
    FRAME_INLINED      = 2,  // 内联
    FRAME_NATIVE       = 3,  // 原生代码
    FRAME_CPP          = 4,  // C++ 代码
    FRAME_KERNEL       = 5,  // 内核代码
    FRAME_C1_COMPILED  = 6,  // C1 编译
};
```

**示例 key 值：**
- `0x50000001` = FRAME_NATIVE (5) | name_index=1
- `0x10000042` = FRAME_JIT_COMPILED (1) | name_index=66

### 2.3 type() 方法：帧类型推断

```cpp
// flameGraph.h:33-43
FrameTypeId type(u32 key) const {
    if (_inlined * 3 >= _total) {       // 内联帧占比 >= 33%
        return FRAME_INLINED;
    } else if (_c1_compiled * 2 >= _total) {  // C1 编译占比 >= 50%
        return FRAME_C1_COMPILED;
    } else if (_interpreted * 2 >= _total) {  // 解释执行占比 >= 50%
        return FRAME_INTERPRETED;
    } else {
        return (FrameTypeId)(key >> 28);      // 默认使用 key 中的类型
    }
}
```

**六层面分析：**

| 层面 | 分析 |
|-----|------|
| **设计原理** | 同一方法可能在不同时刻被不同方式执行（解释/JIT/内联），用启发式规则选择最代表性的类型 |
| **边界条件** | 当 `_total = 0` 时，所有条件都不满足，使用 key 中的类型 |
| **并发安全** | 只读操作，无竞争 |
| **JVM 交互** | 无直接交互，数据来自 `ASGCT_CallFrame` |
| **性能影响** | 3 次乘法比较，约 5-10 CPU 周期 |
| **替代方案** | 可用权重平均或更复杂的决策树 |

### 2.4 child() 方法：获取/创建子节点

```cpp
// flameGraph.h:49-55
Trie* child(u32 name_index, FrameTypeId type) {
    Trie** ptr = &_children[name_index | type << 28];  // 计算 key，获取指针的指针
    if (*ptr == nullptr) {
        *ptr = new Trie();  // 不存在则创建
    }
    return *ptr;
}
```

**逐行展开：**

```
Line 50: Trie** ptr = &_children[name_index | type << 28];
         │
         ├─ type << 28
         │   └─ 将 FrameTypeId 移到高 4 位
         │      例如: FRAME_NATIVE (5) << 28 = 0x50000000
         │
         ├─ name_index | type << 28
         │   └─ 组合 key
         │      例如: name_index=42, type=5 → key=0x5000002A
         │
         └─ &_children[key]
             └─ std::map<u32, Trie*>::operator[]
                 │
                 ├─ 查找 key
                 │   └─ 红黑树查找: O(log n)
                 │      典型 CPU 周期: ~100 cycles (20-30 比较)
                 │
                 └─ 如果不存在，插入 nullptr
                     返回值: Trie** (指向 map 中 value 的指针)

Line 51-53: if (*ptr == nullptr) { *ptr = new Trie(); }
            │
            ├─ *ptr == nullptr
            │   └─ 解引用 Trie**，得到 Trie*
            │      如果是新插入的，则为 nullptr
            │
            └─ new Trie()
                └─ 分配 80 bytes + std::map 开销
                   malloc() 系统调用: ~100-500 cycles
                   构造函数: 初始化所有字段为 0
```

**六层面分析：**

| 层面 | 分析 |
|-----|------|
| **设计原理** | 懒创建策略：只在需要时才分配 Trie 节点，节省内存 |
| **边界条件** | 当 `_children` 为空 map 时，第一次插入触发红黑树根节点创建 |
| **并发安全** | **非线程安全！** 只能在 dump 阶段（单线程）调用 |
| **JVM 交互** | 无 |
| **性能影响** | 红黑树插入 + 内存分配，约 200-1000 CPU 周期 |
| **替代方案** | 可用 `std::unordered_map` (哈希表) 替代，O(1) 查找 |

### 2.5 depth() 方法：计算树深度

```cpp
// flameGraph.h:57-67
int depth(u64 cutoff, u32* name_order) const {
    int max_depth = 0;
    for (auto it = _children.begin(); it != _children.end(); ++it) {
        if (it->second->_total >= cutoff) {  // 只统计超过阈值的子节点
            name_order[nameIndex(it->first)] = 1;  // 标记该方法名已使用
            int d = it->second->depth(cutoff, name_order);  // 递归计算
            if (d > max_depth) max_depth = d;
        }
    }
    return max_depth + 1;  // 包含自身
}
```

**递归展开示例：**

```
假设 Trie 结构：
          root (total=1000)
         /    \
    foo_500  bar_300
       |
   baz_200

depth(100, name_order) 的执行过程：
1. root.depth() 被调用
2. 遍历 _children: foo (500 >= 100 ✓), bar (300 >= 100 ✓)
3. 对于 foo:
   - name_order[foo.name_index] = 1
   - 递归: foo.depth()
     - 遍历 _children: baz (200 >= 100 ✓)
     - 对于 baz:
       - name_order[baz.name_index] = 1
       - 递归: baz.depth() = 1 (无子节点)
     - max_depth = 1
     - return 2
4. 对于 bar:
   - name_order[bar.name_index] = 1
   - 递归: bar.depth() = 1 (无子节点)
5. max_depth = max(2, 1) = 2
6. return 3

最终深度 = 3 (root → foo → baz)
```

**六层面分析：**

| 层面 | 分析 |
|-----|------|
| **设计原理** | cutoff 过滤低频帧，避免火焰图过深；同时标记使用的方法名 |
| **边界条件** | 空树返回 1（只有 root） |
| **并发安全** | 只读，线程安全 |
| **JVM 交互** | 无 |
| **性能影响** | O(n) 遍历所有节点，n = 总帧数 |
| **替代方案** | 可缓存深度，但收益不大 |

---

## 三、FlameGraph 类核心方法

### 3.1 addChild() 方法：添加帧到 Trie

```cpp
// flameGraph.cpp:87-112
Trie* FlameGraph::addChild(Trie* f, const char* name, FrameTypeId type, u64 value) {
    size_t len = strlen(name);
    bool has_suffix = len > 4 && name[len - 4] == '_' && name[len - 3] == '[' && name[len - 1] == ']';
    std::string s(name, has_suffix ? len - 4 : len);

    u32 name_index = _cpool[s];
    if (name_index == 0) {
        name_index = _cpool[s] = _cpool.size();
    }

    f->_total += value;

    switch (type) {
        case FRAME_INLINED:
            (f = f->child(name_index, FRAME_JIT_COMPILED))->_inlined += value;
            return f;
        case FRAME_C1_COMPILED:
            (f = f->child(name_index, FRAME_JIT_COMPILED))->_c1_compiled += value;
            return f;
        case FRAME_INTERPRETED:
            (f = f->child(name_index, FRAME_JIT_COMPILED))->_interpreted += value;
            return f;
        default:
            return f->child(name_index, type);
    }
}
```

**逐行展开：**

```
Line 88: size_t len = strlen(name);
         │
         ├─ strlen(name)
         │   └─ 计算字符串长度
         │      实现细节:
         │      - 从 name 地址开始逐字节读取
         │      - 直到遇到 '\0'
         │      - CPU: 字符串长度 n, 约 n cycles
         │      - 优化: 现代 CPU 用 SIMD (SSE/AVX) 可一次比较 16/32 字节

Line 89: bool has_suffix = len > 4 && name[len - 4] == '_' && name[len - 3] == '[' && name[len - 1] == ']';
         │
         └─ 检测是否为 "_[k]" 类型后缀 (内核帧)
            例如: "sys_read_[k]" → has_suffix = true
            这些后缀在显示时要去掉

Line 90: std::string s(name, has_suffix ? len - 4 : len);
         │
         └─ 创建 std::string 对象
            - 分配堆内存 (小字符串优化 SS0 可能用栈)
            - 复制字符串内容
            - CPU: ~50-200 cycles (取决于长度)

Line 92-95: name_index 处理
            │
            ├─ _cpool[s]
            │   └─ std::map<std::string, u32>::operator[]
            │      红黑树查找: O(log m), m = 方法名数量
            │      CPU: ~100-300 cycles (字符串比较 + 树遍历)
            │
            └─ name_index == 0 表示未找到
                - _cpool[s] = _cpool.size()  // 插入新条目
                - 新索引 = 当前大小
                - 例如: 第一个方法名 → index=1

Line 97: f->_total += value;
         │
         └─ 累加采样计数
            - 原子操作？否！
            - 这是单线程操作 (dump 阶段)
            - CPU: 1 条 ADD 指令

Line 99-111: switch 处理不同帧类型
             │
             ├─ FRAME_INLINED (2)
             │   └─ 创建 JIT_COMPILED (1) 类型节点
             │      累加 _inlined 计数
             │
             ├─ FRAME_C1_COMPILED (6)
             │   └─ 创建 JIT_COMPILED (1) 类型节点
             │      累加 _c1_compiled 计数
             │
             ├─ FRAME_INTERPRETED (0)
             │   └─ 创建 JIT_COMPILED (1) 类型节点
             │      累加 _interpreted 计数
             │
             └─ default (FRAME_NATIVE, FRAME_CPP, FRAME_KERNEL)
                 └─ 直接创建对应类型节点
```

**为什么 INLINED/C1/INTERPRETED 映射到 JIT_COMPILED？**

```
┌────────────────────────────────────────────────────────────────────┐
│  同一个 Java 方法可能在不同时刻以不同方式执行：                       │
│                                                                    │
│  Thread 1: 调用 foo() → JIT 编译执行  (FRAME_JIT_COMPILED)          │
│  Thread 2: 调用 foo() → 解释执行      (FRAME_INTERPRETED)           │
│  Thread 3: bar() 内联了 foo()        (FRAME_INLINED)               │
│                                                                    │
│  在 Trie 中，它们共享同一个节点，但分别计数：                          │
│  Trie node "foo()" {                                               │
│      _total = 300          // 总计                                  │
│      _inlined = 100        // 内联                                  │
│      _interpreted = 50     // 解释                                  │
│      _c1_compiled = 20     // C1 编译                               │
│      // 其余 130 = JIT (C2) 编译                                    │
│  }                                                                 │
│                                                                    │
│  type() 方法根据比例决定最终显示颜色                                  │
└────────────────────────────────────────────────────────────────────┘
```

**六层面分析：**

| 层面 | 分析 |
|-----|------|
| **设计原理** | 合并同一方法的不同执行方式，避免节点爆炸；同时保留执行方式统计 |
| **边界条件** | 当 `name` 为空字符串时，`strlen` 返回 0，`has_suffix` 为 false |
| **并发安全** | **非线程安全！** 假设单线程调用 |
| **JVM 交互** | `name` 来自 `jmethodID` 解析或 native symbol table |
| **性能影响** | 字符串操作 + 红黑树查找，约 200-500 cycles per frame |
| **替代方案** | 可用 string interning 或 hash map 优化方法名查找 |

---

## 四、常量池压缩技术

### 4.1 printCpool() 方法解析

```cpp
// flameGraph.cpp:269-295
void FlameGraph::printCpool(Writer& out) {
    out << "'all'";  // 索引 0 = "all"

    std::string prev;
    u32 index = 0;
    for (std::map<std::string, u32>::const_iterator it = _cpool.begin(); it != _cpool.end(); ++it) {
        if (_name_order[it->second]) {  // 只输出实际使用的名字
            _name_order[it->second] = ++index;

            size_t prefix_len = StringUtils::getCommonPrefix(prev, it->first);
            prev = it->first;

            if (prefix_len > 95) prefix_len = 95;  // 限制：前缀长度编码在一个字符中
            std::string s(1, (char)(prefix_len + ' '));  // 编码前缀长度
            s.append(it->first, prefix_len, std::string::npos);  // 只存差异部分

            StringUtils::replace(s, '\\', "\\\\", 2);  // 转义
            StringUtils::replace(s, '\'', "\\'", 2);
            out << ",\n'";
            out.write(s.data(), s.size());
            out << "'";
        }
    }

    // 释放内存
    _cpool = std::map<std::string, u32>();
}
```

**前缀压缩示例：**

```
原始方法名列表 (按字母排序):
  "java/lang/String.hashCode"
  "java/lang/String.length"
  "java/lang/String.substring"

压缩后输出:
  ' all'
  ' java/lang/String.hashCode'          // 前缀 0, 差异 "java/lang/String.hashCode"
  ',5length'                            // 前缀 "java/lang/String." = 19 字符
  ',5substring'                         // 编码为 ' ' + 19 = '3' (ASCII 51)
                                        // 但 prefix_len > 95 限制，实际可能是分段

更详细示例:
  prev = ""
  it->first = "com/example/MyClass.foo"
  
  prefix_len = getCommonPrefix("", "com/example/MyClass.foo") = 0
  s = " " + "com/example/MyClass.foo"   // ' ' = ASCII 32 = 0 + 32
  
  prev = "com/example/MyClass.foo"
  it->first = "com/example/MyClass.bar"
  
  prefix_len = getCommonPrefix("com/example/MyClass.foo", "com/example/MyClass.bar")
             = 19  // "com/example/MyClass."
  s = (char)(19 + ' ') + "bar"          // ASCII 51 + "bar"
    = '3' + "bar"                       // 但注意: 19 + 32 = 51 = '3'
```

**解码过程（JavaScript 端）：**

```javascript
// flame.html:249-253
function unpack(cpool) {
    for (let i = 1; i < cpool.length; i++) {
        // 第一个字符编码了前缀长度
        // charCodeAt(0) - 32 得到前缀长度
        // 从前一个字符串复制前缀，加上当前字符串的剩余部分
        cpool[i] = cpool[i - 1].substring(0, cpool[i].charCodeAt(0) - 32) + cpool[i].substring(1);
    }
}
```

**压缩效果：**

```
假设有 1000 个方法名，平均 50 字符：

未压缩:
  1000 * 50 = 50,000 bytes

前缀压缩后（假设平均前缀长度 30）:
  1000 * (1 + 20) = 21,000 bytes
  压缩率: 58% 节省

典型实际效果:
  - JDK 类名: 节省 60-70%
  - 用户代码: 节省 40-50%
```

### 4.2 getCommonPrefix() 实现

```cpp
// flameGraph.cpp:29-37
static size_t getCommonPrefix(const std::string& a, const std::string& b) {
    size_t length = a.size() < b.size() ? a.size() : b.size();
    for (size_t i = 0; i < length; i++) {
        if (a[i] != b[i] || a[i] > 127) {  // 遇到不同或非 ASCII 字符停止
            return i;
        }
    }
    return length;
}
```

**为什么 `a[i] > 127` 时停止？**

```
非 ASCII 字符（如 UTF-8 多字节字符）可能导致:
1. 字节级比较错误
2. 前缀长度计算不一致

例如:
  a = "中文方法" (UTF-8: E4 B8 AD E6 96 87 E6 96 B9 E6 B3 95)
  b = "中文类"   (UTF-8: E4 B8 AD E6 96 87 E7 B1 BB)
  
  前两个字符 "中文" 相同，但字节序列:
  E4 B8 AD E6 96 87 vs E4 B8 AD E6 96 87
  
  第 5 字节开始不同:
  E6 (方法) vs E7 (类)
  
  如果继续比较，前缀长度 = 5 字节，但显示时可能只对齐到 "中文"
  
  为安全起见，遇到非 ASCII (a[i] > 127) 就停止
```

**六层面分析：**

| 层面 | 分析 |
|-----|------|
| **设计原理** | 方法名通常有长公共前缀（包名+类名），压缩传输量 |
| **边界条件** | prefix_len > 95 时截断，因为编码在一个 char 中 (0-95 映射到 ' ' - 127) |
| **并发安全** | 只读操作，线程安全 |
| **JVM 交互** | 无 |
| **性能影响** | O(n) 比较两个字符串，n = 最小长度 |
| **替代方案** | 可用 Huffman 编码或字典压缩，但实现复杂 |

---

## 五、帧数据紧凑编码

### 5.1 printFrame() 方法解析

```cpp
// flameGraph.cpp:172-220
void FlameGraph::printFrame(Writer& out, u32 key, const Trie& f, int level, u64 x) {
    u32 name_and_type = _name_order[f.nameIndex(key)] << 3 | f.type(key);
    bool has_extra_types = (f._inlined | f._c1_compiled | f._interpreted) &&
                           f._inlined < f._total && f._interpreted < f._total;

    char* p = _buf;
    if (level == _last_level + 1 && x == _last_x) {
        p += snprintf(p, 100, "u(%u", name_and_type);           // u = 上一层的孩子
    } else if (level == _last_level && x == _last_x + _last_total) {
        p += snprintf(p, 100, "n(%u", name_and_type);           // n = 同层邻居
    } else {
        p += snprintf(p, 100, "f(%u,%d,%llu", name_and_type, level, x - _last_x);  // f = 新帧
    }

    if (f._total != _last_total || has_extra_types) {
        p += snprintf(p, 100, ",%llu", f._total);
        if (has_extra_types) {
            p += snprintf(p, 100, ",%llu,%llu,%llu", f._inlined, f._c1_compiled, f._interpreted);
        }
    }

    strcpy(p, ")\n");
    out << _buf;

    _last_level = level;
    _last_x = x;
    _last_total = f._total;

    // 递归处理子节点...
}
```

**三种编码命令：**

```
┌─────────────────────────────────────────────────────────────────────┐
│                     帧数据紧凑编码                                    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  u(name_and_type[, total, inlined, c1, interpreted])               │
│  │                                                                  │
│  └─ "up": 当前帧是上一个帧的直接子节点                                 │
│     隐含信息: level = last_level + 1, x = last_x                    │
│     节省: level 和 x 坐标不用传输                                     │
│                                                                     │
│  n(name_and_type[, total, ...])                                     │
│  │                                                                  │
│  └─ "next": 当前帧是上一个帧的邻居（同一层）                           │
│     隐含信息: level = last_level, x = last_x + last_total           │
│     节省: level 和 x 坐标不用传输                                     │
│                                                                     │
│  f(name_and_type, level, x_offset[, total, ...])                    │
│  │                                                                  │
│  └─ "full": 完整编码，用于无法用 u/n 表示的情况                        │
│     需要指定 level 和 x_offset（相对于 last_x 的偏移）                │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

**编码示例：**

```
假设 Trie 结构:
              root (level=0, x=0, total=1000)
             /                              \
        foo (l=1, x=0, t=600)            bar (l=1, x=600, t=400)
           |                                    |
        baz (l=2, x=0, t=300)              qux (l=2, x=600, t=200)

输出编码:
  f(5,0,0,1000)        // root: 完整编码
  u(10,600)            // foo: up (root 的子节点)
  u(15,300)            // baz: up (foo 的子节点)
  n(20,400)            // bar: next (baz 的邻居，跳回 level 1)
  u(25,200)            // qux: up (bar 的子节点)

解码过程:
  1. f(5,0,0,1000) → level=0, x=0, total=1000
     last_level=0, last_x=0, last_total=1000
  
  2. u(10,600) → level=last_level+1=1, x=last_x=0, total=600
     last_level=1, last_x=0, last_total=600
  
  3. u(15,300) → level=2, x=0, total=300
     last_level=2, last_x=0, last_total=300
  
  4. n(20,400) → level=last_level=1, x=last_x+last_total=0+600=600, total=400
     last_level=1, last_x=600, last_total=400
  
  5. u(25,200) → level=2, x=600, total=200
```

**name_and_type 编码：**

```cpp
u32 name_and_type = _name_order[f.nameIndex(key)] << 3 | f.type(key);
```

```
name_and_type 编码:
┌────────────────────────────────────────────────────────┐
│  高位: name_index (重排后的索引)      低位: FrameTypeId │
│                                                        │
│  例如: name_index=42, type=FRAME_NATIVE(5)             │
│  name_and_type = 42 << 3 | 5 = 341                     │
│                                                        │
│  JavaScript 解码:                                      │
│  name = cpool[name_and_type >>> 3]  // 42             │
│  type = name_and_type & 7           // 5              │
└────────────────────────────────────────────────────────┘
```

### 5.2 JavaScript 解码实现

```javascript
// flame.html:114-127
function f(key, level, left, width, inln, c1, int) {
    levels[level0 = level].push({
        level, 
        left: left0 += left, 
        width: width0 = width || width0,
        color: getColor(palette[key & 7]), 
        title: cpool[key >>> 3],
        details: (int ? ', int=' + int : '') + (c1 ? ', c1=' + c1 : '') + (inln ? ', inln=' + inln : '')
    });
}

function u(key, width, inln, c1, int) {
    f(key, level0 + 1, 0, width, inln, c1, int)  // level = last_level + 1
}

function n(key, width, inln, c1, int) {
    f(key, level0, width0, width, inln, c1, int)  // level = last_level, left = last_left + last_width
}
```

**六层面分析：**

| 层面 | 分析 |
|-----|------|
| **设计原理** | 利用火焰图的拓扑特性（树形结构），用增量编码减少数据量 |
| **边界条件** | 跨越多个不连续子树时需要用 `f()` 命令 |
| **并发安全** | 单线程输出，无竞争 |
| **JVM 交互** | 无 |
| **性能影响** | 每帧约 50-100 bytes 输出，网络传输和解析都是 O(n) |
| **替代方案** | 可用二进制格式（如 Protocol Buffers），但可读性差 |

---

## 六、完整输出流程

### 6.1 dump() 方法主流程

```cpp
// flameGraph.cpp:114-170
void FlameGraph::dump(Writer& out, bool tree) {
    _name_order = new u32[_cpool.size() + 1]();
    _mintotal = _minwidth == 0 && tree ? _root._total / 1000 : (u64)(_root._total * _minwidth / 100);
    int depth = _root.depth(_mintotal, _name_order);

    if (tree) {
        // Tree 视图输出...
    } else {
        // FlameGraph 视图输出
        const char* tail = FLAMEGRAPH_TEMPLATE;  // 内嵌的 HTML 模板

        tail = printTill(out, tail, "/*height:*/300");
        out << std::min(depth * 16, MAX_CANVAS_HEIGHT);

        tail = printTill(out, tail, "/*title:*/");
        out << _title;

        tail = printTill(out, tail, "/*inverted:*/false");
        out << (_reverse ^ _inverted ? "true" : "false");

        tail = printTill(out, tail, "/*depth:*/0");
        out << depth;

        tail = printTill(out, tail, "/*cpool:*/");
        printCpool(out);

        tail = printTill(out, tail, "/*frames:*/");
        printFrame(out, FRAME_NATIVE << 28, _root, 0, 0);

        tail = printTill(out, tail, "/*highlight:*/");

        out << tail;
    }

    delete[] _name_order;
}
```

**printTill() 方法：模板替换**

```cpp
// flameGraph.cpp:297-301
const char* FlameGraph::printTill(Writer& out, const char* data, const char* till) {
    const char* pos = strstr(data, till);  // 查找占位符
    out.write(data, pos - data);            // 输出占位符之前的内容
    return pos + strlen(till);              // 返回占位符之后的位置
}
```

**模板替换示例：**

```
flame.html 模板:
...
canvas {width: 100%; height: /*height:*/300px}
...

替换过程:
1. printTill(out, template, "/*height:*/300")
   - 找到 "/*height:*/300"
   - 输出之前的内容: "canvas {width: 100%; height: "
   - 返回 "300px}\n..."

2. out << std::min(depth * 16, MAX_CANVAS_HEIGHT)
   - 输出实际高度值，如 "512"

最终输出:
canvas {width: 100%; height: 512px}
```

### 6.2 INCBIN 机制：模板嵌入

```cpp
// flameGraph.cpp:17-18
INCBIN(FLAMEGRAPH_TEMPLATE, "src/res/flame.html")
INCBIN(TREE_TEMPLATE, "src/res/tree.html")
```

**展开后：**

```cpp
// incbin.h:17-28
extern "C" const char FLAMEGRAPH_TEMPLATE[];
extern "C" const char FLAMEGRAPH_TEMPLATE_END[];

asm(
    ".section \".rodata\", \"a\"\n"
    ".globl FLAMEGRAPH_TEMPLATE\n"
    "FLAMEGRAPH_TEMPLATE:\n"
    ".incbin \"src/res/flame.html\"\n"  // 在编译时嵌入文件
    ".globl FLAMEGRAPH_TEMPLATE_END\n"
    "FLAMEGRAPH_TEMPLATE_END:\n"
    ".byte 0x00\n"  // null 终止符
    ".previous\n"
);
```

**优点：**
1. **零运行时开销**：模板直接嵌入二进制，无需文件 I/O
2. **单文件部署**：libasyncProfiler.so 自包含，无需外部模板文件
3. **编译时验证**：模板语法错误在编译时发现

**缺点：**
1. **增大二进制大小**：模板约 13KB 直接加入 .so 文件
2. **修改模板需重编译**：无法运行时替换模板

---

## 七、GDB 验证脚本

### 7.1 验证 Trie 构建

```bash
# gdb_flamegraph_trie.gdb
set pagination off
set print pretty on

# 在 addChild 处设断点
break FlameGraph::addChild

commands
    # 打印参数
    printf "addChild: name=%s, type=%d, value=%lu\n", $name, $type, $value
    
    # 打印当前 Trie 节点
    printf "  f->_total before: %lu\n", $f->_total
    
    continue
end

run
```

### 7.2 验证常量池压缩

```bash
# gdb_flamegraph_cpool.gdb
set pagination off

# 在 printCpool 处设断点
break FlameGraph::printCpool

commands
    # 打印 cpool 大小
    printf "cpool size: %lu\n", *((size_t*)&_cpool + 2)  # std::map 内部大小
    
    # 遍历前 10 个条目
    set $i = 0
    set $it = _cpool._M_t._M_impl._M_start
    while $i < 10 && $it != _cpool._M_t._M_impl._M_finish
        printf "  [%d] %s -> %u\n", $i, ((std::pair<std::string, u32>*)$it)->first.c_str(), ((std::pair<std::string, u32>*)$it)->second
        set $it = $it + 1
        set $i = $i + 1
    end
    
    continue
end

run
```

### 7.3 验证帧编码输出

```bash
# gdb_flamegraph_frames.gdb
set pagination off

# 在 printFrame 处设断点
break FlameGraph::printFrame

commands
    # 打印当前帧信息
    printf "Frame: level=%d, x=%lu, total=%lu\n", $level, $x, $f._total
    printf "  key=%08x, name_index=%u, type=%d\n", $key, $f.nameIndex($key), $f.type($key)
    printf "  encoded: %s\n", $_buf
    
    continue
end

run
```

---

## 八、性能分析

### 8.1 时间复杂度

| 操作 | 时间复杂度 | 说明 |
|-----|-----------|------|
| `addChild()` | O(log m) | m = 方法名数量，红黑树查找 |
| `depth()` | O(n) | n = Trie 节点总数 |
| `printCpool()` | O(m log m) | 排序 + 遍历 |
| `printFrame()` | O(n log k) | n = 节点数，k = 平均子节点数，排序开销 |
| **总输出** | O(n log n) | 主要开销在排序子节点 |

### 8.2 空间复杂度

| 组件 | 空间 | 说明 |
|-----|------|------|
| Trie 节点 | 80-128 bytes/节点 | std::map 开销 |
| 常量池 | O(m * L) | m = 方法名数，L = 平均长度 |
| `_name_order` | O(m) | 索引重排数组 |
| 输出缓冲 | 4KB | `_buf[4096]` |

### 8.3 实际性能数据

```
典型场景: 10 万采样，5000 唯一方法名

构建 Trie:
  - 时间: ~100ms
  - 内存: ~10MB (Trie) + ~500KB (cpool)

输出 HTML:
  - 时间: ~50ms
  - 文件大小: ~2MB (压缩前)

前缀压缩效果:
  - 压缩前: ~250KB (方法名字符串)
  - 压缩后: ~100KB
  - 节省: 60%
```

---

## 九、总结

### 核心技术要点

1. **Trie 数据结构**：高效合并相同调用栈前缀，支持增量统计
2. **常量池压缩**：前缀压缩减少 60% 字符串传输量
3. **帧编码优化**：`u/n/f` 三种命令利用树形拓扑特性
4. **模板嵌入**：编译时嵌入 HTML，零运行时开销

### 设计亮点

- **懒创建 Trie 节点**：只在需要时分配内存
- **启发式类型推断**：根据执行方式比例选择代表性颜色
- **增量编码**：利用上下文信息减少数据量

### 改进空间

- 可用 `std::unordered_map` 替代 `std::map`，加速查找
- 可用二进制格式（如 Protobuf）替代文本编码
- 可支持流式输出，避免内存中构建完整 Trie

---

**下一课将分析 Tree 视图输出和交互式功能。**
