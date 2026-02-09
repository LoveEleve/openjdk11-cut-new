# G1 GC 术语表

## Region 相关

| 术语 | 全称 | 含义 |
|------|------|------|
| Region | Heap Region | G1 中最小的内存管理单元，固定大小（1-32MB） |
| Eden Region | - | 存放新创建对象的 Region |
| Survivor Region | - | 存放 Young GC 存活对象的 Region |
| Old Region | - | 存放经历多次 GC 仍存活的对象 |
| Humongous Region | - | 存放巨型对象（> Region/2）的 Region |
| Free Region | - | 空闲未使用的 Region |
| CSet | Collection Set | 本次 GC 要回收的 Region 集合 |

## 标记相关

| 术语 | 全称 | 含义 |
|------|------|------|
| TAMS | Top At Mark Start | 标记开始时的分配指针位置 |
| PTAMS | Prev TAMS | 上一轮标记的 TAMS |
| NTAMS | Next TAMS | 当前标记的 TAMS |
| Bitmap | Mark Bitmap | 标记位图，每个 bit 对应一个对象是否存活 |
| prev_bitmap | Previous Bitmap | 上一轮标记结果 |
| next_bitmap | Next Bitmap | 当前标记使用的位图 |
| SATB | Snapshot At The Beginning | 开始时快照，并发标记的核心算法 |

## RemSet 相关

| 术语 | 全称 | 含义 |
|------|------|------|
| RemSet | Remembered Set | 记忆集，记录"谁引用了我" |
| RSet | RemSet 缩写 | 同 RemSet |
| Card | - | 卡，512B 堆内存对应一个卡 |
| CardTable | - | 卡表，每个卡一个字节 |
| Dirty Card | - | 脏卡，表示该卡内有跨 Region 引用 |
| Refinement | - | 精炼，处理脏卡更新 RemSet 的过程 |
| PRT | Per Region Table | 细粒度记忆集，每个源 Region 一个位图 |
| Sparse PRT | - | 稀疏记忆集，适合少量引用 |
| Coarse Map | - | 粗粒度位图，每个 Region 一个 bit |

## GC 阶段

| 术语 | 全称 | 含义 |
|------|------|------|
| Young GC | - | 只回收 Young Region |
| Mixed GC | - | 同时回收 Young 和部分 Old Region |
| Full GC | - | 全堆回收（应尽量避免） |
| Initial Mark | - | 初始标记，STW，标记 GC Roots 直接引用的对象 |
| Concurrent Mark | - | 并发标记，与应用并发执行 |
| Remark | - | 重新标记，STW，处理并发期间的引用变化 |
| Cleanup | - | 清理阶段，计算存活对象，回收完全空闲的 Region |
| Evacuation | - | 疏散/转移，将存活对象复制到新 Region |

## 屏障相关

| 术语 | 全称 | 含义 |
|------|------|------|
| Write Barrier | 写屏障 | 对象引用赋值时执行的代码 |
| Pre-write Barrier | 写前屏障 | SATB 用，记录覆盖前的值 |
| Post-write Barrier | 写后屏障 | RemSet 用，标记脏卡 |
| SATB Buffer | SATB 缓冲区 | 暂存 SATB 引用的队列 |
| Dirty Card Queue | 脏卡队列 | 暂存脏卡的队列 |

## 策略相关

| 术语 | 全称 | 含义 |
|------|------|------|
| GC Efficiency | GC 效率 | (可回收空间 / 预测耗时) |
| Pause Target | 暂停目标 | -XX:MaxGCPauseMillis 设定的目标 |
| IHOP | Initiating Heap Occupancy Percent | 触发并发标记的堆占用阈值 |
| Ergonomics | 自适应调优 | JVM 自动调整参数 |

## 数据结构

| 术语 | 全称 | 含义 |
|------|------|------|
| OOP | Ordinary Object Pointer | 普通对象指针 |
| Klass | - | 类的元数据 |
| InstanceKlass | - | 普通类的元数据 |
| BOT | Block Offset Table | 块偏移表，快速定位对象起始 |
| WorkGang | - | 并行工作线程组 |
| GCTask | - | GC 任务单元 |
