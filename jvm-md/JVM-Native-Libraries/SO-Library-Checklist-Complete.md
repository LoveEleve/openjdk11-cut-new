# JVM 原生库完整性检查清单

> **检查目标**：确保所有重要的so库都被覆盖  
> **检查范围**：OpenJDK 11 完整so库集合  
> **分类标准**：对Arthas/Async-Profiler的重要性

---

## 已覆盖的so库（13个）

### ✅ Tier 1 - 核心引擎（3个）
| 库名 | 状态 | 文档 | 重要性 |
|------|------|------|--------|
| libjvm.so | ✅ 已分析 | AttachListener/VMThread/G1等 | ⭐⭐⭐⭐⭐ |
| libjsig.so | 📋 计划中 | SUB-ROADMAP文档1.1-1.2 | ⭐⭐⭐⭐⭐ |
| libattach.so | 📋 计划中 | JVM-Native-Libraries-Roadmap | ⭐⭐⭐⭐ |

### ✅ Tier 2 - 基础服务（4个）
| 库名 | 状态 | 文档 | 重要性 |
|------|------|------|--------|
| libjava.so | 📋 计划中 | SUB-ROADMAP文档2.1-2.2 | ⭐⭐⭐⭐ |
| libnio.so | 📋 计划中 | SUB-ROADMAP文档3.1-3.2 | ⭐⭐⭐⭐ |
| libnet.so | 📋 计划中 | SUB-ROADMAP文档4.1 | ⭐⭐⭐ |
| libzip.so | 📋 计划中 | SUB-ROADMAP文档4.1 | ⭐⭐⭐ |

### ✅ Tier 3 - 管理层（4个）
| 库名 | 状态 | 说明 | 重要性 |
|------|------|------|--------|
| libmanagement.so | 📋 可选 | JMX支持 | ⭐⭐⭐ |
| libmanagement_agent.so | 📋 可选 | JMX Agent | ⭐⭐ |
| libj2pcsc.so | ❌ 跳过 | 智能卡，边缘功能 | ⭐ |
| libj2gss.so | ❌ 跳过 | Kerberos，边缘功能 | ⭐ |

### ✅ Tier 4 - 启动辅助（2个）
| 库名 | 状态 | 说明 | 重要性 |
|------|------|------|--------|
| libjli.so | 📋 可选 | Java启动器 | ⭐⭐⭐ |
| libinstrument.so | 📋 计划中 | Java Agent支持 | ⭐⭐⭐⭐ |

---

## 🔍 遗漏的重要so库检查

### 检查JDK完整so库列表

```bash
# 标准JDK 11的so库（linux-x64）
$ ls -la $JAVA_HOME/lib/*.so $JAVA_HOME/lib/server/*.so 2>/dev/null | wc -l
# 约 30-40 个so库
```

### ❗ 发现遗漏的重要库

| 库名 | 路径 | 功能 | 重要性 | 建议 |
|------|------|------|--------|------|
| **libsaproc.so** | `lib/libsaproc.so` | Serviceability Agent（HSDB等） | ⭐⭐⭐⭐ | **✅ 已添加 - 文档5.1** |
| **libdt_socket.so** | `lib/libdt_socket.so` | JDWP调试传输 | ⭐⭐⭐ | 可选添加 |
| **libjdwp.so** | `lib/libjdwp.so` | JDWP实现 | ⭐⭐⭐ | 可选添加 |
| **libnpt.so** | `lib/libnpt.so` | 网络性能工具 | ⭐⭐ | 可跳过 |
| **libsunec.so** | `lib/libsunec.so` | Sun椭圆曲线加密 | ⭐⭐ | 可跳过 |
| **libj2pkcs11.so** | `lib/libj2pkcs11.so` | PKCS#11安全 | ⭐ | 已列出 |
| **libjaas_unix.so** | `lib/libjaas_unix.so` | JAAS认证 | ⭐⭐ | 可跳过 |
| **libjawt.so** | `lib/libjawt.so` | AWT native | ⭐ | GUI相关 |
| **liblcms.so** | `lib/liblcms.so` | 色彩管理 | ⭐ | GUI相关 |
| **libsctp.so** | `lib/libsctp.so` | SCTP协议 | ⭐⭐ | 网络边缘 |

### 🔴 重点遗漏：libsaproc.so

```
libsaproc.so - Serviceability Agent 库
────────────────────────────────────
功能：
  • HSDB（HotSpot Debugger）的核心库
  • 提供 attach 到进程的能力
  • 读取目标进程的内存、线程、堆等信息
  • 用于调试和分析JVM

与Arthas/Async-Profiler的关系：
  • Arthas使用类似的attach机制
  • Async-Profiler的VMStructs读取可参考SA实现
  • 理解SA有助于理解JVM内部数据结构

重要性：⭐⭐⭐⭐
建议：添加到Tier 2或Tier 3
```

---

## 修订后的完整列表（16个库）

### Tier 1 - 核心引擎（3个）🔴 最高优先级
```
1. libjvm.so          ✅ 已分析
2. libjsig.so         📋 计划中（文档1.1-1.2）
3. libattach.so       📋 计划中
```

### Tier 2 - 基础服务（5个）🟠 高优先级
```
4. libjava.so         📋 计划中（文档2.1-2.2）
5. libnio.so          ✅ 已完成（文档3.1-3.2-3.3）
6. libnet.so          📋 计划中（文档4.1）
7. libzip.so          📋 计划中（文档4.1）
8. libsaproc.so       ❗ 新增，建议添加
```

### Tier 3 - 工具与监控（4个）🟡 中优先级
```
9. libinstrument.so   📋 计划中
10. libmanagement.so  📋 可选
11. libdt_socket.so   ❓ 可选添加
12. libjdwp.so        ❓ 可选添加
```

### Tier 4 - 启动与辅助（2个）🟢 低优先级
```
13. libjli.so         📋 可选
14. libverify.so      ❌ 可跳过
```

### Tier 5 - 安全与扩展（2个）⚪ 边缘功能
```
15. libj2pkcs11.so    ❌ 可跳过
16. libj2gss.so       ❌ 可跳过
```

---

## 建议的修订方案

### 方案A：保守方案（维持现有）
- 保持现有的13个库
- 优点：聚焦核心，不发散
- 缺点：缺少libsaproc.so等有用库

### 方案B：补充方案（推荐⭐）
- **新增libsaproc.so**到Tier 2
- 新增libdt_socket.so和libjdwp.so到Tier 3（可选）
- 优点：覆盖更完整，HSDB是重要工具
- 工作量：增加1-2篇文档

### 方案C：完整方案
- 覆盖所有16个库
- 优点：最完整
- 缺点：部分库（如GUI相关）实用性低

---

## 我的建议

**推荐方案B，补充libsaproc.so**

理由：
1. **libsaproc.so是HSDB的核心**，对学习JVM内部结构极有价值
2. **与Arthas原理相通**，都是attach机制
3. **实际工作中可能用到**，分析生产环境问题
4. **只需增加1篇文档**，工作量可控

**新增文档建议：**
```
文档4.2: libsaproc.so与Serviceability Agent
  ├── HSDB工具使用
  ├── attach机制实现
  ├── 读取JVM内存结构
  └── 与Arthas的对比
```

---

## 最终确认

**请确认：**

1. **是否添加libsaproc.so到学习计划？**
   - 是 → 添加到Tier 2，增加文档4.2
   - 否 → 保持现有13个库

2. **是否添加JDWP相关库（libdt_socket.so、libjdwp.so）？**
   - 是 → 添加到Tier 3（可选学习）
   - 否 → 跳过

3. **是否开始学习？**
   - 是 → 回复起点（A/B/C/D）
   - 调整 → 回复调整意见
