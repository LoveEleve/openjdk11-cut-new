# G1CollectedHeap::initialize() 方法详细分析

## 🎯 方法概述
这个方法是G1堆初始化的核心，负责创建和配置G1垃圾收集器的所有核心数据结构。

## 📊 初始化阶段划分

### 阶段1：基础准备和参数获取
- 获取堆大小参数（-Xms, -Xmx）
- 验证对齐要求
- 预留虚拟内存空间

### 阶段2：核心数据结构创建
- 创建卡表（Card Table）
- 创建屏障集（Barrier Set）
- 创建热卡缓存（Hot Card Cache）

### 阶段3：内存映射器创建
- 堆存储映射器
- BOT映射器
- 卡表映射器
- 位图映射器

### 阶段4：管理器初始化
- HeapRegionManager初始化
- 记忆集初始化
- 并发标记器初始化

### 阶段5：最终配置
- 堆扩展到初始大小
- 策略初始化
- 各种队列初始化

## 🔍 关键对象创建时序
1. ReservedSpace heap_rs - 预留堆空间
2. G1CardTable* ct - 卡表
3. G1BarrierSet* bs - 屏障集
4. G1HotCardCache* _hot_card_cache - 热卡缓存
5. 6个G1RegionToSpaceMapper - 内存映射器
6. G1RemSet* _g1_rem_set - 记忆集
7. G1BlockOffsetTable* _bot - 块偏移表
8. G1ConcurrentMark* _cm - 并发标记器