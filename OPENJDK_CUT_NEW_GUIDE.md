# OpenJDK Cut-New 详细说明

本文档面向 `openjdk-cut-new` 与 `openjdk11-core` 的使用者，重点回答三件事：
1) **如何拆分**；2) **与传统构建的区别**；3) **如何高效使用**。

---

## 1. 如何拆分（Split Build 的实现方式）

### 1.1 核心思路
`openjdk-cut-new` 不是修改 OpenJDK 的代码结构，而是**在构建层面添加可拆分目标**，让你可以按“模块 + 阶段”的粒度构建。

具体做法是：
- 在 `make/Main.gmk` 中引入**拆分阶段**和**拆分目标**。
- 以 `split-<module>`、`split-<module>-<phase>` 形式声明目标。
- 通过 `build-config/module-deps.gmk` 声明模块依赖，保证构建顺序正确。
- 使用 `make/ModuleWrapper.gmk` 做阶段构建与产物复制/链接的统一封装。

### 1.2 拆分阶段（Phase）
拆分构建按阶段执行，阶段定义如下（来自 `make/Main.gmk`）：
- `gensrc` / `gendata` / `copy` / `java` / `libs` / `launchers` / `jmod`

这些阶段允许你**只重建变更影响的那一步**。

### 1.3 拆分目标与依赖
`split-<module>` 会先构建模块依赖，再按阶段生成模块产物；
`split-<module>-<phase>` 则只构建一个阶段（带依赖的对应阶段）。

模块依赖关系来自 `build-config/module-deps.gmk`，例如：
- `jdk.compiler` 依赖 `java.base` 和 `java.compiler`
- `java.desktop` 依赖 `java.base`/`java.prefs`/`java.datatransfer`/`java.xml`

### 1.4 HotSpot 的特殊拆分
HotSpot 使用独立目标：
- `split-hotspot`
- `split-hotspot-gensrc`
- `split-hotspot-libs`

它们会根据 `JVM_VARIANT_MAIN` 选择对应的 HotSpot 变体进行构建。

---

## 2. 与传统构建的区别（openjdk11-core vs openjdk-cut-new）

### 2.1 构建入口不同
- **传统构建（openjdk11-core）**
  - 典型命令：
    - `make CONF=linux-x86_64-normal-server-slowdebug hotspot`
  - 入口偏“整体”或“大模块”

- **Cut-New（openjdk-cut-new）**
  - 典型命令：
    - `make -f make/Main.gmk SPEC=build-config/spec.gmk split-hotspot-libs`
    - `make -f make/Main.gmk SPEC=build-config/spec.gmk split-java.base-libs`
  - 入口偏“模块 + 阶段”

### 2.2 增量编译更细粒度
- `openjdk11-core` 虽然支持 `hotspot` 目标，但依赖检查/生成步骤依然很重。
- `openjdk-cut-new` 把阶段拆开，**更容易只重建你真正修改的部分**。

### 2.3 构建产物一致
- 两者产物结构一致：
  - `build/linux-x86_64-normal-server-slowdebug/jdk/bin/java`
  - `build/linux-x86_64-normal-server-slowdebug/jdk/lib/server/libjvm.so`
- Cut-New 只是**改变构建粒度和入口**，不改变 JDK 的功能与二进制布局。

### 2.4 工程化调试体验更友好
- Cut-New 提供 `CMakeLists.txt`，便于 CLion 代码导航/断点调试。
- 但**真正构建仍由原生 `make` split 目标完成**。

---

## 3. 如何玩转这个项目（实战用法）

下面按“改哪里 → 用什么命令 → 如何验证 → 如何调试”的思路展开。

### 3.1 最小上手流程
1) 构建 HotSpot：
   ```bash
   make -f make/Main.gmk SPEC=build-config/spec.gmk split-hotspot-libs
   ```
2) 运行/验证：
   ```bash
   ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java -version
   ```

### 3.2 按改动类型选择构建指令（最常用）
- **只改 HotSpot C/C++**（`src/hotspot/**`）：
  ```bash
  make -f make/Main.gmk SPEC=build-config/spec.gmk split-hotspot-libs
  ```
- **只改 HotSpot 生成代码**（`.ad` / `gensrc` 相关）：
  ```bash
  make -f make/Main.gmk SPEC=build-config/spec.gmk split-hotspot-gensrc
  make -f make/Main.gmk SPEC=build-config/spec.gmk split-hotspot-libs
  ```
- **只改 `java.base` 的 native 库**（`src/java.base/*/native/**`）：
  ```bash
  make -f make/Main.gmk SPEC=build-config/spec.gmk split-java.base-libs
  ```
- **只改 `java.base` 启动器**（`src/java.base/share/native/launcher/**`）：
  ```bash
  make -f make/Main.gmk SPEC=build-config/spec.gmk split-java.base-launchers
  ```
- **只改 `java.base` 的 Java 代码**（`src/java.base/share/classes/**`）：
  ```bash
  make -f make/Main.gmk SPEC=build-config/spec.gmk split-java.base-java
  ```
- **改 `jdk.compiler`（javac）**：
  ```bash
  make -f make/Main.gmk SPEC=build-config/spec.gmk split-jdk.compiler
  ```
- **改 `jdk.jdeps` / `jlink` / `javadoc` 等工具模块**：
  ```bash
  make -f make/Main.gmk SPEC=build-config/spec.gmk split-jdk.jdeps
  make -f make/Main.gmk SPEC=build-config/spec.gmk split-jdk.jlink
  make -f make/Main.gmk SPEC=build-config/spec.gmk split-jdk.javadoc
  ```

### 3.3 典型“改动 → 重编 → 验证”套路
- **改 GC 逻辑（G1 / CMS / Z）**：
  1) 只编 HotSpot：`split-hotspot-libs`
  2) 验证运行：
     ```bash
     ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java -Xms8g -Xmx8g -XX:+UseG1GC -Xlog:gc+heap=info -version
     ```

- **改类加载/解释器/运行时**：
  1) `split-hotspot-libs`
  2) 跑你自己的测试类：
     ```bash
     ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java -Xint -cp /data/workspace/demo/src com.wjcoder.Main
     ```

- **改 `java.base` 的 Java 类**：
  1) `split-java.base-java`
  2) 运行目标程序或 `-version` 验证

### 3.4 调试 JVM 的推荐方式（两条稳定路径）
**方式 A：Attach（最稳，早期断点更容易命中）**
1) 先启动 JVM 并暂停：
   ```bash
   ./build/linux-x86_64-normal-server-slowdebug/jdk/bin/java \
     -XX:+UnlockDiagnosticVMOptions -XX:+PauseAtStartup \
     -Xms8g -Xmx8g -XX:+UseG1GC -Xint \
     -cp /data/workspace/demo/src com.wjcoder.Main
   ```
2) 在 CLion 里 `Attach to Process` 选择该 `java` 进程
3) 下断点后删除 `./vm.paused.<pid>` 放行

**方式 B：CLion 直接 Launch 调试**
- Executable 指向：
  `build/linux-x86_64-normal-server-slowdebug/jdk/bin/java`
- 参数建议：
  `-Xint -Xshare:off ...`（减少 CDS 干扰，便于断点命中）

### 3.5 建议的起始断点（入门即用）
- `JNI_CreateJavaVM`（JVM 入口）
- `Threads::create_vm`（VM 启动主流程）
- `JavaThread::run`（Java 线程运行）
- `Universe::initialize`（堆与核心运行时初始化）

### 3.6 常见问题处理
- **提示缺失生成文件**（如 `gensrc` 相关错误）：
  ```bash
  make -f make/Main.gmk SPEC=build-config/spec.gmk split-hotspot-gensrc
  make -f make/Main.gmk SPEC=build-config/spec.gmk split-hotspot-libs
  ```
- **改了 Java 代码但运行还是旧逻辑**：
  - 确认是否执行了对应模块的 `split-<module>-java`
  - 确认运行的是 `openjdk-cut-new` 的 `jdk/bin/java`

### 3.7 推荐工作流（最高效）
1) 修改源码
2) 按改动类型执行 `split-...` 目标
3) 用 `-Xinternalversion` 验证正在使用的 `libjvm.so`
4) 启动 JVM + Attach 调试

---

## 4. 两个项目如何共存使用
- `openjdk11-core`：适合做“全量构建或对照验证”。
- `openjdk-cut-new`：适合“高频调试 + 增量开发”。

你可以把 `openjdk11-core` 作为“对照基线”，把 `openjdk-cut-new` 作为“日常开发/调试版本”。

---

## 5. 推荐工作流（高效调试）
1) 在 `openjdk-cut-new` 改 HotSpot 代码。
2) `split-hotspot-libs` 快速重编。
3) 用 `PauseAtStartup` 启动 JVM。
4) CLion Attach + 断点调试。

这样可以把“修改 → 编译 → 调试”的周转时间压到最短。
