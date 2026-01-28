# 🚀 基于本地 OpenJDK 的快速替换开发指南

## 🎯 核心思路

我们已经有了完整编译好的 `openjdk-cut-new`，现在要实现：
- **修改 HotSpot 源码** → **2-3 分钟编译** → **直接替换 `libjvm.so`** → **立即测试**

这比重新完整构建（30-60 分钟）快 **10-20 倍**！

## 📁 关键路径说明

```bash
# 我们的目标：直接替换这个文件
/data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/lib/server/libjvm.so

# 使用这个 JDK 进行测试
/data/workspace/openjdk-cut-new/build/linux-x86_64-normal-server-slowdebug/jdk/bin/java
```

## ⚡ 快速开发工作流

### 1. **初始设置**（只需一次）
```bash
cd /data/workspace/openjdk-cut-new

# 使用改进的 CMakeLists.txt
cp CMakeLists_improved.txt CMakeLists.txt

# 创建构建目录
mkdir -p cmake-build
cd cmake-build

# 配置 CMake（指向我们已有的构建产物）
cmake ..
```

### 2. **日常开发循环**
```bash
# ========== 修改代码 ==========
vim ../src/hotspot/share/gc/g1/g1CollectedHeap.cpp
# 比如添加一些调试输出或修改 GC 逻辑

# ========== 快速编译（2-3 分钟）==========
make -j8 jvm  # 只编译 HotSpot，直接覆盖 libjvm.so

# ========== 立即测试 ==========
make quick_test  # 自动验证替换成功并测试 JVM

# 或者手动测试
../build/linux-x86_64-normal-server-slowdebug/jdk/bin/java -version
../build/linux-x86_64-normal-server-slowdebug/jdk/bin/java -XX:+UseG1GC MyTest.java
```

### 3. **调试流程**
```bash
# 编译 Debug 版本
make -j8 jvm

# 使用 GDB 调试
gdb --args ../build/linux-x86_64-normal-server-slowdebug/jdk/bin/java -XX:+UseG1GC -XX:+PrintGC MyTest

# 在 GDB 中设置断点
(gdb) break G1CollectedHeap::collect
(gdb) run
```

## 🔧 CMake 目标说明

| 目标 | 作用 | 时间 |
|------|------|------|
| `make jvm` | 编译 HotSpot，直接替换 `libjvm.so` | 2-3 分钟 |
| `make quick_test` | 验证替换成功，测试 JVM 启动 | 10 秒 |
| `make build_and_test` | 编译 + 测试一条龙 | 2-3 分钟 |
| `make java_base` | 编译 java.base 库（如需要） | 1-2 分钟 |

## 💡 为什么这样做很聪明？

### **传统方式 vs 直接替换**
```bash
# ❌ 传统方式：每次修改都要完整构建
make clean && make all  # 30-60 分钟

# ✅ 直接替换：只编译修改的部分
make jvm  # 2-3 分钟，直接覆盖 libjvm.so
```

### **技术原理**
1. **动态链接特性**：`java` 可执行文件启动时动态加载 `libjvm.so`
2. **符号兼容性**：只要导出符号不变，新的 `libjvm.so` 可以无缝替换
3. **增量编译**：CMake 只重新编译修改过的源文件

## 🎯 实际使用场景

### **场景 1：研究 G1 GC 算法**
```bash
# 1. 修改 G1 收集器代码
vim src/hotspot/share/gc/g1/g1CollectedHeap.cpp

# 2. 快速编译
make jvm  # 2-3 分钟

# 3. 测试 G1 行为
../build/.../jdk/bin/java -XX:+UseG1GC -XX:+PrintGC YourTest
```

### **场景 2：调试 JIT 编译器**
```bash
# 1. 修改 C1/C2 编译器
vim src/hotspot/share/opto/compile.cpp

# 2. 编译并测试
make build_and_test

# 3. 观察 JIT 行为
../build/.../jdk/bin/java -XX:+PrintCompilation YourTest
```

### **场景 3：添加自定义 JVM 选项**
```bash
# 1. 修改参数解析
vim src/hotspot/share/runtime/arguments.cpp

# 2. 快速验证
make jvm && ../build/.../jdk/bin/java -XX:+YourNewOption -version
```

## 🚨 注意事项

1. **备份原始 `libjvm.so`**（首次使用前）
   ```bash
   cp build/.../jdk/lib/server/libjvm.so build/.../jdk/lib/server/libjvm.so.backup
   ```

2. **确保符号兼容**：不要修改公共 API 的函数签名

3. **增量编译**：CMake 会自动检测文件变化，只重编译必要的部分

4. **调试信息**：使用 `-g -O0` 确保调试符号完整

## 🎉 总结

基于我们已有的 `openjdk-cut-new`，直接替换 `libjvm.so` 的方式：

- ⚡ **速度提升 10-20 倍**（2-3 分钟 vs 30-60 分钟）
- 🎯 **专注核心**：把时间花在 JVM 逻辑研究上，而不是构建工具
- 🔧 **即插即用**：利用动态链接，无缝集成现有环境
- 🚀 **高效迭代**：支持快速的"修改-编译-测试"循环

这就是工程思维的体现：**用最简单的方式解决最核心的问题**！