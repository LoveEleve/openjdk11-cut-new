# G1 双队列系统层级图

## 一、整体架构图

```mermaid
flowchart TB
    subgraph G1BS["G1BarrierSet（全局单例）"]
        direction TB
        SATBSet["[SATBMarkQueueSet]"]
        DCSet["[DirtyCardQueueSet]"]
    end
    
    subgraph SharedQueues["全局共享队列（各1个）"]
        direction TB
        SSQ["[Queue: _shared_satb_queue<br/>SATB共享队列<br/>VM线程用]"]
        SDQ["[Queue: _shared_dirty_card_queue<br/>脏卡共享队列<br/>VM线程用]"]
    end
    
    subgraph ThreadLocal1["JavaThread 1"]
        direction TB
        TL1_SATB["[Queue: SATB队列<br/>本地]"]
        TL1_DC["[Queue: 脏卡队列<br/>本地]"]
    end
    
    subgraph ThreadLocal2["JavaThread 2"]
        direction TB
        TL2_SATB["[Queue: SATB队列<br/>本地]"]
        TL2_DC["[Queue: 脏卡队列<br/>本地]"]
    end
    
    subgraph ThreadLocalN["JavaThread N"]
        direction TB
        TLN_SATB["[Queue: SATB队列<br/>本地]"]
        TLN_DC["[Queue: 脏卡队列<br/>本地]"]
    end
    
    G1BS ===|"管理"| SATBSet
    G1BS ===|"管理"| DCSet
    
    SATBSet ===|"包含"| SSQ
    DCSet ===|"包含"| SDQ
    
    SATBSet -.->|"缓冲区满<br/>提交到"| TL1_SATB
    SATBSet -.->|"缓冲区满<br/>提交到"| TL2_SATB
    SATBSet -.->|"缓冲区满<br/>提交到"| TLN_SATB
    
    DCSet -.->|"缓冲区满<br/>提交到"| TL1_DC
    DCSet -.->|"缓冲区满<br/>提交到"| TL2_DC
    DCSet -.->|"缓冲区满<br/>提交到"| TLN_DC
    
    style G1BS fill:#e3f2fd
    style SATBSet fill:#f3e5f5
    style DCSet fill:#e8f5e9
    style SSQ fill:#f3e5f5
    style SDQ fill:#e8f5e9
    style TL1_SATB fill:#fff3e0
    style TL1_DC fill:#fff3e0
    style TL2_SATB fill:#fff3e0
    style TL2_DC fill:#fff3e0
    style TLN_SATB fill:#fff3e0
    style TLN_DC fill:#fff3e0
```

## 二、数据流转图

```mermaid
flowchart TB
    subgraph Producer["生产者：应用线程"]
        A["obj.field = newVal"]
    end
    
    subgraph PreBarrier["Pre-Write Barrier"]
        P1["读取旧值"]
        P2{"SATB<br/>激活?"}
        P3["enqueue<br/>旧引用"]
    end
    
    subgraph LocalQueue1["本地 SATB 队列 [Queue]"]
        LQ1["缓冲区<br/>[oop1, oop2, ...]"]
    end
    
    subgraph GlobalSATB["全局 SATBMarkQueueSet"]
        G_SATB["[QueueSet: 仓库管理员]"]
        SharedSATB["[Queue: _shared_satb_queue]"]
    end
    
    subgraph GCThread["消费者：GC 标记线程"]
        GC["处理队列<br/>标记对象"]
    end
    
    A --> P1 --> P2
    P2 -->|"是"| P3
    P2 -->|"否"| Skip1["跳过"]
    P3 -->|"入队"| LQ1
    
    LQ1 -->|"缓冲区满<br/>提交"| G_SATB
    G_SATB -->|"挂到链表"| SharedSATB
    SharedSATB -->|"取出"| GC
    
    style PreBarrier fill:#e3f2fd
    style LocalQueue1 fill:#fff3e0
    style GlobalSATB fill:#f3e5f5
    style GCThread fill:#ffebee
```

## 三、Post-Write Barrier 数据流转

```mermaid
flowchart TB
    subgraph Producer["生产者：应用线程"]
        A["*field = newVal"]
    end
    
    subgraph PostBarrier["Post-Write Barrier"]
        W1["计算卡地址"]
        W2{"年轻代<br/>卡?"}
        W3["标记脏"]
        W4["enqueue<br/>卡地址"]
    end
    
    subgraph LocalQueue2["本地脏卡队列 [Queue]"]
        LQ2["缓冲区<br/>[addr1, addr2, ...]"]
    end
    
    subgraph GlobalDC["全局 DirtyCardQueueSet"]
        G_DC["[QueueSet: 仓库管理员]"]
        SharedDC["[Queue: _shared_dirty_card_queue]"]
    end
    
    subgraph RefineThread["消费者：并发细化线程"]
        R["处理脏卡<br/>更新RSet"]
    end
    
    A --> W1 --> W2
    W2 -->|"否"| W3 --> W4
    W2 -->|"是"| Skip2["跳过"]
    W4 -->|"入队"| LQ2
    
    LQ2 -->|"缓冲区满<br/>提交"| G_DC
    G_DC -->|"挂到链表"| SharedDC
    SharedDC -->|"取出"| R
    
    style PostBarrier fill:#fff9c4
    style LocalQueue2 fill:#fff3e0
    style GlobalDC fill:#e8f5e9
    style RefineThread fill:#ffebee
```

## 四、完整队列系统图

```mermaid
flowchart TB
    subgraph G1BarrierSet["G1BarrierSet"]
        SATB_Set["[SATBMarkQueueSet]"]
        DC_Set["[DirtyCardQueueSet]"]
    end
    
    subgraph SATB_System["SATB 系统"]
        direction TB
        SSQ["[Queue: 共享SATB<br/>VM线程用]"]
        Buffers1["[已完成缓冲区链表<br/>head → tail]"]
    end
    
    subgraph DC_System["脏卡系统"]
        direction TB
        SDQ["[Queue: 共享脏卡<br/>VM线程用]"]
        Buffers2["[已完成缓冲区链表<br/>head → tail]"]
    end
    
    subgraph Thread1["线程1"]
        T1_SATB["[Queue: SATB<br/>本地]"]
        T1_DC["[Queue: 脏卡<br/>本地]"]
    end
    
    subgraph Thread2["线程2"]
        T2_SATB["[Queue: SATB<br/>本地]"]
        T2_DC["[Queue: 脏卡<br/>本地]"]
    end
    
    subgraph ThreadN["线程N"]
        TN_SATB["[Queue: SATB<br/>本地]"]
        TN_DC["[Queue: 脏卡<br/>本地]"]
    end
    
    G1BarrierSet --> SATB_Set
    G1BarrierSet --> DC_Set
    
    SATB_Set --> SATB_System
    DC_Set --> DC_System
    
    SATB_System -.-> T1_SATB
    SATB_System -.-> T2_SATB
    SATB_System -.-> TN_SATB
    
    DC_System -.-> T1_DC
    DC_System -.-> T2_DC
    DC_System -.-> TN_DC
    
    style G1BarrierSet fill:#e3f2fd
    style SATB_Set fill:#f3e5f5
    style DC_Set fill:#e8f5e9
    style SATB_System fill:#f3e5f5
    style DC_System fill:#e8f5e9
    style Thread1 fill:#fff3e0
    style Thread2 fill:#fff3e0
    style ThreadN fill:#fff3e0
```

## 五、队列内部结构

```mermaid
flowchart TB
    subgraph Queue["[Queue: SATBMarkQueue / DirtyCardQueue]"]
        direction TB
        Buf["_buf: void**<br/>[ 缓冲区指针 ]"]
        Idx["_index: size_t<br/>当前写入位置"]
        Active["_active: bool<br/>是否激活"]
        Qset["_qset: PtrQueueSet*<br/>指向全局队列集"]
    end
    
    subgraph QueueSet["[QueueSet: PtrQueueSet]"]
        direction TB
        Head["_completed_buffers_head<br/>已完成缓冲区链表头"]
        Tail["_completed_buffers_tail<br/>已完成缓冲区链表尾"]
        Count["_n_completed_buffers<br/>缓冲区数量"]
        Threshold["_process_completed_threshold<br/>处理阈值"]
    end
    
    Queue -.->|"缓冲区满<br/>提交"| QueueSet
    
    style Queue fill:#fff3e0
    style QueueSet fill:#f3e5f5
```

---

## 一句话说明

| 图形 | 含义 |
|------|------|
| `[Queue]` | 具体队列，存储数据 |
| `[QueueSet]` | 队列集，管理多个队列的缓冲区 |
| `===` 粗线 | 包含/管理关系 |
| `-.->` 虚线 | 数据流向（队列满→提交） |