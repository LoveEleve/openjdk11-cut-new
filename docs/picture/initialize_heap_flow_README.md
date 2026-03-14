# Universe::initialize_heap() 流程图

## 文件说明

| 文件 | 说明 |
|------|------|
| `initialize_heap_flow.drawio` | 流程图源文件，可用 draw.io 打开编辑 |
| `initialize_heap_flow_README.md` | 本说明文件 |

## 如何打开编辑

### 方式 1: 在线 draw.io (推荐)
1. 访问 https://app.diagrams.net/
2. 点击 "Open Existing Diagram"
3. 选择 `initialize_heap_flow.drawio` 文件
4. 即可查看和编辑

### 方式 2: VS Code 插件
1. 安装 "Draw.io Integration" 插件
2. 在 VS Code 中打开 `initialize_heap_flow.drawio`
3. 直接编辑

## 流程图内容概览

### 1. 主调用链 (左侧)
```
universe_init()
    └── Universe::initialize_heap() [核心入口]
            ├── create_heap() → new G1CollectedHeap()
            ├── G1CollectedHeap::initialize() [400行]
            ├── set_max_size(262144) [2MB]
            ├── 压缩指针配置 [base=0, shift=3]
            └── startup_initialization() [_target_refills=50]
```

### 2. 类结构 (右上)
- **CollectedHeap**: 基类，定义堆接口
- **G1CollectedHeap**: G1 实现，包含 Region 管理
- **ThreadLocalAllocBuffer**: TLAB 管理结构
- **压缩指针配置**: ZeroBased 模式参数

### 3. 关键参数 (底部)
| 参数 | 值 |
|------|-----|
| 堆大小 | 8GB |
| Region 大小 | 4MB |
| Region 数量 | 2048 |
| TLAB 最大 | 2MB |
| 压缩模式 | ZeroBased |
| narrow_oop_shift | 3 |
| narrow_oop_base | 0 |
| _target_refills | 50 |

### 4. GDB 验证结果 (右下)
所有参数均已通过 GDB 实际验证 ✅

## 颜色说明

| 颜色 | 含义 |
|------|------|
| 🟨 黄色 | 标题、静态成员 |
| 🟦 蓝色 | 入口函数、基类 |
| 🟥 红色 | 核心方法、压缩指针 |
| 🟪 紫色 | G1 相关类 |
| 🟩 绿色 | TLAB 相关、验证通过 |
| ⬜ 灰色 | 参数汇总 |

## 更新记录

| 时间 | 更新内容 |
|------|----------|
| 2026-02-10 | 初始版本，包含完整调用链和数据结构 |

---

*此流程图配合文档阅读效果更佳:*
- `3.5-CompressedOops-Algorithm-Deep-Dive.md`
- `3.6-TLAB-Memory-Layout.md`
- `3.7-GDB-Real-Verification.md`
