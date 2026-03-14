

![华章IT logo](2dfa6ac3edfe874f68aa0cbccaa42322_img.jpg)

华章IT logo

由资深Java工程师撰写，来自一线实践经验的结晶  
详细解剖ZGC的运行原理以及调优方法，讲解细腻，图示丰富，可帮助  
Java工程师深入理解垃圾回收技术

![Java核心技术系列 logo](30a26f2d17ca95672702bf50fb4f0242_img.jpg)

Java核心技术系列 logo

# 新一代垃圾回收器 ZGC设计与实现

ZGC Implementation and Performance Tuning

彭成寒 著

![A blue ceramic cup with a textured pattern, symbolizing the 'ZGC' (Zero Pause GC) concept.](0538daaa5583c23e17db3a12f2281a55_img.jpg)

A blue ceramic cup with a textured pattern, symbolizing the 'ZGC' (Zero Pause GC) concept.

![机械工业出版社 logo](4f4b52340aaccb1bcf733468dca9ee03_img.jpg)

机械工业出版社 logo

机械工业出版社  
China Machine Press

Java核心技术系列

# 新一代垃圾回收器ZGC设计与实现

彭成寒 著

ISBN: 978-7-111-63365-5

本书纸版由机械工业出版社于2019年出版，电子版由华章分社（北京华章图文信息有限公司，北京奥维博世图书发行有限公司）全球范围内制作与发行。

版权所有，侵权必究

客服热线：+ 86-10-68995265

客服信箱：service@bbbvip.com

官方网址：www.hzmedia.com.cn

新浪微博 @华章数媒

微信公众号 华章电子书（微信号：hzebook）

# 目录

前言

# 第1章 垃圾回收器概述

## 1.1 垃圾回收算法

## 1.2 JVM垃圾回收器

### 1.2.1 串行回收

### 1.2.2 并行回收

### 1.2.3 CMS

### 1.2.4 G1

### 1.2.5 ZGC

### 1.2.6 Shenandoah

# 第2章 ZGC内存管理

## 2.1 操作系统地址管理

## 2.2 ZGC内存管理

### 2.2.1 多视图映射

### 2.2.2 ZGC多视图映射

### 2.2.3 页面设计

### 2.2.4 对NUMA的支持

### 2.2.5 ZGC中的物理内存管理

### 2.2.6 ZGC中的虚拟内存管理

### 2.2.7 ZGC内存预分配

## 2.3 ZGC对象分配管理

### 2.3.1 对象空间分配

### 2.3.2 页面分配

# 第3章 ZGC线程

## 3.1 线程的基本概念

## 3.2 控制线程

### 3.2.1 时钟触发器

### 3.2.2 消息触发

### 3.2.3 VMThread

## 3.3 工作线程

## 3.4 垃圾回收触发的时机

# 第4章 ZGC垃圾回收算法的设计

## 4.1 并发垃圾回收算法

### 4.1.1 并发垃圾回收算法概述

### 4.1.2 ZGC并发算法的设计

## 4.2 并发处理

### 4.2.1 并发处理概述

### 4.2.2 ZGC并发处理算法

### 4.2.3 ZGC并发处理算法演示

# 第5章 ZGC垃圾回收算法的实现

## 5.1 垃圾回收的实现

### 5.1.1 初始标记

### 5.1.2 并发标记

### 5.1.3 再标记和非强根并行标记

### 5.1.4 非强引用并发标记和引用并发处理

### 5.1.5 重置转移集

### 5.1.6 回收无效的页面

### 5.1.7 选择待回收的页面

### 5.1.8 初始化待转移集合的转移表

### 5.1.9 初始转移

### 5.1.10 并发转移

### 5.1.11 垃圾回收算法再讨论

## 5.2 垃圾回收算法演示

# 第6章 ZGC日志解读

## 6.1 Xlog简介

## 6.2 测试用例设计

## 6.3 ZGC初始化信息

## 6.4 垃圾回收触发信息

## 6.5 垃圾回收过程中每一步的信息

## 6.6 统计信息

### 6.6.1 垃圾回收器信息

- 6.6.2 竞争信息
- 6.6.3 同步等待信息
- 6.6.4 内存信息
- 6.6.5 垃圾回收步骤信息
- 6.6.6 子阶段信息
- 6.6.7 线程信息

# 第7章 ZGC参数和基准测试

- 7.1 参数简介
  - 7.1.1 ZGC新引入参数
  - 7.1.2 GC通用参数
- 7.2 测试评估
  - 7.2.1 测试准备
  - 7.2.2 测试与测试报告

# 第8章 ZGC的发展与展望

- 8.1 类回收
- 8.2 单代回收
- 8.3 新功能和多平台

# 第9章 JVM编译调试

- 9.1 下载源代码
- 9.2 代码概览
- 9.3 编译JVM

## 9.4 调试ZGC

### 9.4.1 启动GDB

### 9.4.2 对象分配

### 9.4.3 触发垃圾回收

### 9.4.4 初始标记

### 9.4.5 并发标记

### 9.4.6 初始转移

### 9.4.7 并发转移

### 9.4.8 重定位

## 9.5 使用HSDB学习JVM中对象布局

### 9.5.1 C++对象布局原理

### 9.5.2 Java对象布局原理

### 9.5.3 用HSDB分析Java对象布局

# 第10章 Shenandoah简介

## 10.1 概述

## 10.2 Shenandoah垃圾回收策略

## 10.3 Shenandoah垃圾回收算法

### 10.3.1 正常回收算法

### 10.3.2 遍历回收算法

# 附录A Cassandra简介

# 附录B YCSB简介

# 前言

JDK 11于2018年9月25日正式发布，这个版本引入了许多新的特性，其中最为引人注目的就是实现了一款新的垃圾回收器ZGC。Java开发人员日常工作中最关注、接触最多的就是JVM中的垃圾回收器，所以该垃圾回收器一经发布，立即吸引了大量开发人员的目光。在JDK 11中，ZGC被明确标记为实验性质（意味着还不成熟），这样一款尚不成熟的垃圾回收器为什么能合入OpenJDK的官方项目中？它对以前的垃圾回收器的改进体现在哪里？它的创新点是什么？它的不足有哪些？本书尝试从ZGC的代码出发，分析ZGC的设计和实现，希望能找到上述问题的答案。

ZGC是一款开源的垃圾回收器，本书从原理和代码角度对ZGC进行剖析，与大家一起学习ZGC，并希望通过本书的介绍让更多的人认识和使用它，也希望大家在学习的过程中都能理解、掌握、精通ZGC，并能在社区中贡献自己的力量。

本书共分为10章：

- 第1章介绍JVM中实现的垃圾回收器，其中着重介绍了G1，最后介绍了ZGC对G1的改进以及当下ZGC尚需完善之处。

- 第2章首先介绍内存地址多视图映射，然后介绍ZGC中的物理内存和虚拟内存，以及它们的管理，最后介绍ZGC如何分配对象。

- 第3章主要介绍ZGC中涉及的四大控制线程：ZDirector负责垃圾回收的触发，ZDriver负责垃圾回收的执行，ZStat负责收集统计信息，VMThread负责控制进行STW操作。

- 第4章介绍ZGC如何利用地址多视图映射设计并发算法进行并发标记、并发转移和并发重定位。

- 第5章介绍ZGC垃圾回收过程的10个步骤以及每一步所做的工作，同时给出了算法示例图演示整个垃圾回收的过程。

- 第6章分析一个完整的ZGC运行日志，并针对每一行日志进行解释，为读者了解ZGC的运行情况提供帮助。

- 第7章首先介绍ZGC中最常用的参数，包括ZGC新引入的参数、ZGC重用的通用GC参数，然后介绍分别使用G1和ZGC作为垃圾回收器运行Cassandra和YCSB，从停顿时间和吞吐率两个方面比较ZGC和G1的运行效果。

- 第8章主要介绍ZGC目前存在的不足以及未来的发展方向。

- 第9章介绍两种调试方法：根据源代码编译后使用GDB调试JVM，着重介绍ZGC垃圾回收过程的调试；根据HotSpot Debugger工具对运行

的Java程序进行分析。

- 第10章对Shenandoah进行简要介绍。Shenandoah在JDK 12中作为实验项目加入OpenJDK，它和ZGC的定位非常类似，但实现方法并不相同。该章简单地介绍Shenandoah和G1、ZGC之间的区别，Shenandoah垃圾回收触发的策略以及Shenandoah实现的几种垃圾回收算法。

本书主要基于JDK 11源代码进行分析，所用的版本是jdk11u1，读者可以自行到OpenJDK的官网下载，也可以从笔者在GitHub（<https://github.com/chenghanpeng/jdk11u>）的备份中下载。

在本书中，为了让读者更加清晰、直观地了解一些基本概念，笔者设计了一些样例程序，这些样例代码可以从仓库（<https://github.com/chenghanpeng/jdk11u/tree/master/example>）中下载。另外，本书介绍了ZGC在JDK 12中的新功能——类回收，为了便于读者学习研究，笔者也维护了一份JDK 12的源代码（<https://github.com/chenghanpeng/jdk12>），供感兴趣的读者下载。

最后再强调一点，ZGC处于持续迭代开发中，变化也会很快。为了能够深入探索ZGC，希望读者在阅读本书时要始终抱着质疑的态度，不断地问自己：书中的介绍和解释是否正确？ZGC的实现是否有改进的空

问？如果有该如何改进？只有不断地提出问题、解决问题，才能深入理解和运用ZGC。

由于笔者水平有限，时间仓促，书中难免存在错漏之处，恳请读者批评指正。你可以通过

<https://github.com/chenghanpeng/jdk11lu/issues> 提交问题。期待能够得到读者朋友们的真情反馈，在技术道路上互勉共进。

在创作本书的过程中，得到了很多朋友以及同事的帮助和支持，在此表示衷心的感谢！

感谢策划编辑吴怡的支持和鼓励，她不仅给出了非常多的写作意见和建议，还不厌其烦地、认真地和笔者沟通，力争做到清晰、准确、无误地将内容呈现给读者。

感谢我的家人，特别是我的儿子，能够体谅我牺牲了陪伴他的时间。有了他们的支持和帮助，我才有时间和精力去完成写作。

# 第1章 垃圾回收器概述

Java是流行多年的编程语言，深受广大程序员的欢迎，其最主要的两个特点为：

- 跨平台：“一次编译，到处运行”是最为贴切的总结。一次编译指的是Java源文件被编译器编译成字节码文件（通常以.class作为后缀，所以也称为Class文件）；到处运行指的是在安装了Java Virtual Machine（JVM）的不同平台上，Class文件都可以运行，由JVM负责解释或者编译执行字节码。

- 垃圾回收：程序员不用再像C/C++程序员一样关心内存的分配和释放，由垃圾回收器负责内存的管理，所以提高了程序开发的效率，减少了内存泄漏的概率。垃圾回收器由JVM的后台线程实现垃圾对象[\[1\]](#)的识别和回收。

自Java中引入垃圾回收器以来，垃圾回收器的发展从未停止过。Java中成熟的垃圾回收器有串行垃圾回收器、并行垃圾回收器、并发标记回收器（Concurrent Mark Sweep，CMS）、垃圾优先回收器

（Garbage First，也称为G1）。在JDK 11中引入了一款新的垃圾回收器ZGC，在JDK 12中又引入了另一款新的垃圾回收器Shenandoah。虽然新的垃圾回收器不断地涌现，但是垃圾回收的基本算法变化并不大。

简单来说，回收算法主要有复制、标记清除、标记压缩。JVM中不同的垃圾回收器都是基于这些基本算法实现的，不同的垃圾回收器区别在于：选择的算法不同，实现时后台线程采用的并行/并发方式不同。

本章介绍JVM中实现的垃圾回收器，并着重回顾了G1，最后介绍为什么需要ZGC，以及ZGC的创新点和不足之处。

[1] 垃圾对象指的是应用程序中分配、使用后不再使用的对象。

## 1.1 垃圾回收算法

Garbage Collection (GC) 垃圾回收 (垃圾收集) 指的是程序不关心对象在内存中的生存周期, 创建后只需要使用, 不用关心何时释放以及如何释放, 由JVM自动管理内存、释放这些对象所占用的空间。垃圾回收的历史非常悠久, 从1960年Lisp语言开始就支持垃圾回收。垃圾回收针对的是堆空间, 目前垃圾回收算法主要有两类:

- 引用计数法: 在堆内存中分配对象时, 会为对象分配一段额外的空间, 这个空间用于维护一个计数器, 如果对象增加了一个新的引用, 则将增加计数器的值; 如果一个引用关系失效, 则减少计数器的值。当一个对象的计数器的值变为0, 则说明该对象已经被废弃, 处于不活跃状态, 可以被回收。引用计数法需要解决循环依赖的问题, 大家熟知的Python语言中的垃圾回收就使用了引用计数法。

- 可达性分析法 (也称为根引用分析法), 基本思路就是通过根集合 (root set) 作为起始点, 从这些节点出发, 根据引用关系开始搜索, 所经过的路径称为引用链, 当一个对象没有被任何引用链访问到时, 则证明此对象是不活跃的, 可以被回收。在JVM中常见的根 (root) 有线程栈帧 (thread frame, 用于跟踪线程中活跃对象)、符号表 (symbol dictionary)、字符串表 (string table)、对象监

视器（object synchronizer）、元数据对象（universe）等，这些根共同构成了根集合。

这两种算法各有优缺点，具体可以参考其他文献。JVM的垃圾回收采用了可达性分析法。垃圾回收算法也在不断地演化，按照不同的标准有不同的分类：

- 从垃圾回收算法实现主要分为复制（copy）、标记清除（mark-sweep）和标记压缩（mark-compact）。
- 从回收方式上可以分为串行回收、并行回收、并发回收。
- 从内存管理上可以分为代管理和非代管理。

关于垃圾回收的基本算法，本书不再介绍，具体可以参考其他书籍。

## 1.2 JVM垃圾回收器

JVM垃圾回收器基于分代管理和回收算法，结合回收的方式，实现了串行回收器、并行回收器、CMS、G1、ZGC和Shenandoah。这些垃圾回收器从程序执行方式的角度可以分为以下3类：

- 串行执行：应用程序和垃圾回收器交替执行，垃圾回收器执行的时候应用程序暂停执行。串行执行指的是垃圾回收器有且仅有一个后台线程执行垃圾对象的识别和回收。

- 并行执行：应用程序和垃圾回收器交替执行，垃圾回收器执行的时候应用程序暂停执行。并行执行指的是垃圾回收器有多个后台线程执行垃圾对象的识别和回收，多个线程并行执行。

- 并发执行：应用程序和垃圾回收器同时运行，除了在某些必要的情况下垃圾回收器需要暂停应用程序的执行，其余的时候在应用程序运行的同时，垃圾回收器的后台线程也运行，如标识垃圾对象并回收垃圾对象所占的空间。

Java中的垃圾回收器对应的执行方式可以总结为表1-1。

表1-1 垃圾回收器对应的执行方式

| 执行方式 | 垃圾回收器                 |
|------|-----------------------|
| 串行执行 | 串行垃圾回收器               |
| 并行执行 | 并行垃圾回收                |
| 并发执行 | CMS、G1、ZGC、Shenandoah |

下面我们看一下这些垃圾回收器的特点以及在执行垃圾回收时的活动图。

### 1.2.1 串行回收

使用单线程进行垃圾回收，在回收时应用程序（mutator）都需要执行暂停（Stop The World, STW）。新生代通常采用复制算法，老生代通常采用标记压缩算法。串行回收典型的执行过程如图1-1所示。

![Diagram illustrating the serial garbage collection process. It shows three vertical stages: '新生代回收' (Young Generation Collection), '老生代回收' (Old Generation Collection), and a final stage. The first stage is labeled '复制' (Copy) and the second '标记压缩' (Mark-Compact). Each stage is separated by a vertical line. Within each stage, there are two horizontal lines representing the heap. The top line has a solid blue arrow pointing right, labeled 'mutator' at its start and '...' at its end. The bottom line has a hollow arrow pointing right, also labeled 'mutator' at its start and '...' at its end. A thick blue arrow points from the end of the first stage to the start of the second stage. Another thick blue arrow points from the end of the second stage to the start of the final stage.](dfe556fea00682b09a59427aaf72051c_img.jpg)

Diagram illustrating the serial garbage collection process. It shows three vertical stages: '新生代回收' (Young Generation Collection), '老生代回收' (Old Generation Collection), and a final stage. The first stage is labeled '复制' (Copy) and the second '标记压缩' (Mark-Compact). Each stage is separated by a vertical line. Within each stage, there are two horizontal lines representing the heap. The top line has a solid blue arrow pointing right, labeled 'mutator' at its start and '...' at its end. The bottom line has a hollow arrow pointing right, also labeled 'mutator' at its start and '...' at its end. A thick blue arrow points from the end of the first stage to the start of the second stage. Another thick blue arrow points from the end of the second stage to the start of the final stage.

图1-1 串行回收

注：本书的图例中没有mutator运行的区间都是指STW。实际上串行回收中的老生代回收不仅仅回收老生代，还回收新生代。图中一个箭头表示一个线程，此图中执行垃圾回收过程只有一个箭头，表示只有一个后台线程执行回收任务。深色箭头表示的是垃圾回收工作线程，空心箭头表示应用程序线程。

### 1.2.2 并行回收

使用多线程进行垃圾回收，在回收时应用程序需要暂停，新生代通常采用复制算法，老生代通常采用标记压缩算法。并行回收的执行过程如图1-2所示。

在并发回收时，如果发现内存不足，需要对整个堆进行垃圾回收（也就是我们常说的Full GC，也称为FGC），在Full GC时需要STW，并且是串行回收。

![Diagram illustrating the parallel garbage collection process. It shows two main phases: '新生代回收' (Young Generation Collection) and '老生代回收' (Old Generation Collection). In the Young Generation phase, mutators (represented by white arrows) and a blue arrow labeled '复制' (Copy) are shown. In the Old Generation phase, mutators and a blue arrow labeled '标记压缩' (Mark-Compact) are shown. The diagram illustrates how mutators continue to run while the GC process is active in parallel.](8fa679f79a1bb1f527cba9f29e784e89_img.jpg)

The diagram illustrates the parallel garbage collection process across two generations: Young Generation and Old Generation. In the Young Generation phase, mutators (represented by white arrows) and a blue arrow labeled '复制' (Copy) are shown. In the Old Generation phase, mutators and a blue arrow labeled '标记压缩' (Mark-Compact) are shown. The diagram illustrates how mutators continue to run while the GC process is active in parallel.

Diagram illustrating the parallel garbage collection process. It shows two main phases: '新生代回收' (Young Generation Collection) and '老生代回收' (Old Generation Collection). In the Young Generation phase, mutators (represented by white arrows) and a blue arrow labeled '复制' (Copy) are shown. In the Old Generation phase, mutators and a blue arrow labeled '标记压缩' (Mark-Compact) are shown. The diagram illustrates how mutators continue to run while the GC process is active in parallel.

图1-2 并行回收

### 1.2.3 CMS

整个回收期间划分成多个阶段：初始标记、并发标记、重新标记、并发清除等。在初始标记和重新标记阶段需要暂停应用程序线程，在并发标记和并发清除期间工作线程可以和应用程序并发运行。这个算法通常适用于老生代，新生代可以采用并行复制回收，也可以采用串行复制算法。CMS垃圾回收的执行过程如图1-3所示。

![Diagram illustrating the CMS (Concurrent Mark Sweep) garbage collection process. The diagram shows a timeline with four main phases: 初始标记 (Initial Mark), 并发标记 (Concurrent Mark), 再标记 (Remark), and 并发清除 (Concurrent Sweep). Vertical lines separate these phases. Blue arrows represent the flow of mutator threads. In the Initial Mark phase, mutator threads enter and then pause. In the Concurrent Mark phase, mutator threads enter and continue running concurrently. In the Remark phase, mutator threads enter and pause again. In the Concurrent Sweep phase, mutator threads enter and run concurrently. A bracket at the bottom labels the entire process as '老生代回收' (Old Generation Collection).](5445597cceefaca1ac89e710fe339325_img.jpg)

Diagram illustrating the CMS (Concurrent Mark Sweep) garbage collection process. The diagram shows a timeline with four main phases: 初始标记 (Initial Mark), 并发标记 (Concurrent Mark), 再标记 (Remark), and 并发清除 (Concurrent Sweep). Vertical lines separate these phases. Blue arrows represent the flow of mutator threads. In the Initial Mark phase, mutator threads enter and then pause. In the Concurrent Mark phase, mutator threads enter and continue running concurrently. In the Remark phase, mutator threads enter and pause again. In the Concurrent Sweep phase, mutator threads enter and run concurrently. A bracket at the bottom labels the entire process as '老生代回收' (Old Generation Collection).

图1-3 CMS垃圾回收

同样，在老生代回收时，因为是并发执行，如果在分配内存时发现内存不足，则需要进行FGC，也需要STW并对整个内存进行串行回收。

### 1.2.4 G1

从执行方式来看，垃圾回收器的发展经历了最初期的串行执行，到并行执行用于提高执行效率，再到目前主流的并发执行用于减少垃圾回收器停顿时间。第一款成熟的并发执行垃圾回收器是CMS。CMS是一款非常成功的垃圾回收器，是使用最多和最广的垃圾回收器，但是其复杂性（有上百个参数）给程序员的使用带来了不便，所以需要设计一款简单的垃圾回收器来替代CMS，G1应运而生。

G1是从JDK 7 Update 4及后续版本开始正式提供的。G1致力于在多CPU和大内存服务器上对垃圾回收提供软实时目标（soft real-time goal）和高吞吐量（high throughput）。目前G1已经相当成熟，从众多的测评结果上看，也达到了G1最初的设计目标。从JDK 9开始G1作为默认的垃圾回收器，目前已经有不少公司开始在生产环境中逐步使用G1。

G1垃圾回收器的设计和前面提到的3种回收器都不同，在并行、串行以及CMS中针对堆空间的管理方式都是连续的，如图1-4所示。

![Diagram illustrating continuous space management in memory. The main vertical stack shows a sequence of colored blocks: three blue blocks at the top, followed by a blue block and a white block, then a white block and a grey block, then a large grey block, then a grey block and a white block, and finally a white block at the bottom. To the right, a legend shows: a blue square for '新生代空间' (New Generation Space), a grey square for '老生代空间' (Old Generation Space), and a white square for '待使用空间' (Available Space).](e69b9188aa2c14ec6b21c83f711fef65_img.jpg)

Diagram illustrating continuous space management in memory. The main vertical stack shows a sequence of colored blocks: three blue blocks at the top, followed by a blue block and a white block, then a white block and a grey block, then a large grey block, then a grey block and a white block, and finally a white block at the bottom. To the right, a legend shows: a blue square for '新生代空间' (New Generation Space), a grey square for '老生代空间' (Old Generation Space), and a white square for '待使用空间' (Available Space).

图1-4 连续空间管理

连续的内存将导致垃圾回收时收集时间过长，停顿时间不可控。所以G1将堆拆成一系列的分区（heap region），这样在一个时间段内，大部分垃圾回收操作就只是针对一部分分区执行，而不是整个堆或整个（老年）代，从而满足在指定的停顿时间内完成垃圾回收的动作。G1内存分区如图1-5所示。

在G1里，新生代就是一系列的内存分区，这意味着不用再要求新生代是一个连续的内存块。类似地，老生代也是由一系列的分区组成。在JVM运行时，从内存管理角度不需要预先设置分区是老生代分区还是新生代分区，而是在内存分配时决定：当新生代需要空间时，则分区被加入新生代中；当老生代需要内存空间时，则分区被加入老生

代中。事实上，G1通常的运行状态是：映射G1分区的虚拟内存随着时间的推移在不同的代之间切换。例如，一个G1分区最初被指定为新生代，经过一次新生代的回收之后，整个新生代分区都被划入待使用的分区中，那它既可以作为新生代分区使用，也可以作为老生代分区使用。很可能在完成一个新生代回收之后，一个新生代的分区在未来的某个时刻被用于老生代分区。同样，在一个老生代分区完成回收之后，它就成为待使用分区，在未来某个时候作为一个新生代分区使用。

![Diagram illustrating G1 region space management. A 10x8 grid of cells represents memory regions. The legend on the right defines four types: 新生代分区 (blue), 老生代分区 (gray), 待使用分区 (white), and 大对象分区 (black). The grid shows: Row 0: [blue] [white] [white] [white] [white] [white] [white] [white]; Row 1: [white] [white] [white] [gray] [white] [white] [white] [white]; Row 2: [white] [white] [white] [white] [white] [white] [white] [white]; Row 3: [white] [white] [white] [white] [white] [white] [white] [white]; Row 4: [white] [white] [white] [white] [white] [white] [white] [white]; Row 5: [white] [white] [white] [white] [white] [white] [white] [white]; Row 6: [white] [white] [white] [white] [white] [white] [white] [white]; Row 7: [white] [white] [white] [white] [white] [white] [white] [white]; Row 8: [white] [white] [white] [white] [white] [white] [white] [white]; Row 9: [white] [white] [white] [white] [white] [white] [white] [white].](365b54f616aff249b4e6c0edafdcb9b3_img.jpg)

新生代分区

老生代分区

待使用分区

大对象分区

Diagram illustrating G1 region space management. A 10x8 grid of cells represents memory regions. The legend on the right defines four types: 新生代分区 (blue), 老生代分区 (gray), 待使用分区 (white), and 大对象分区 (black). The grid shows: Row 0: [blue] [white] [white] [white] [white] [white] [white] [white]; Row 1: [white] [white] [white] [gray] [white] [white] [white] [white]; Row 2: [white] [white] [white] [white] [white] [white] [white] [white]; Row 3: [white] [white] [white] [white] [white] [white] [white] [white]; Row 4: [white] [white] [white] [white] [white] [white] [white] [white]; Row 5: [white] [white] [white] [white] [white] [white] [white] [white]; Row 6: [white] [white] [white] [white] [white] [white] [white] [white]; Row 7: [white] [white] [white] [white] [white] [white] [white] [white]; Row 8: [white] [white] [white] [white] [white] [white] [white] [white]; Row 9: [white] [white] [white] [white] [white] [white] [white] [white].

图1-5 分区空间管理 <sup>[1]</sup>

G1新生代的回收方式是并行回收，采用复制算法。与其他JVM垃圾回收器一样，一旦发生一次新生代回收，整个新生代都会被回收。这就是我们常说的新生代回收（Young GC，YGC）。但是G1和其他垃圾回收器的不同之处在于：①G1会根据预测时间动态地改变新生代的大小<sup>[2]</sup>；②G1老生代的垃圾回收方式与其他JVM垃圾回收器对老生代处理有着极大的不同。G1老生代的回收不会为了释放老生代的空间而对整个老生代进行回收。相反，在任意时刻只有一部分老生代分区会被回收，并且这部分老生代分区将在下一次增量回收时与所有的新生代分区一起被回收，这就是我们所说的混合回收（Mixed GC）。在选择老生代分区时，优先考虑垃圾多的分区。

老生代分区的选择涉及G1的并发标记算法，这个过程称为“并发标记阶段”。并发标记是指并发标记线程和应用程序线程同时运行，它有4个典型的子阶段：初始标记子阶段、并发标记子阶段、再标记子阶段和清理子阶段。

#### 1. 初始标记子阶段

负责标记所有从根集合直接可达的对象，根集合是对象图的起点，初始标记需要将应用程序线程暂停，也就是需要一个STW的时间段。在混合回收中的初始标记子阶段和新生代的初始标记几乎一样。实际上混合回收的初始标记子阶段是借用了新生代回收的结果，即新生代垃圾回收后的新生代Survivor分区作为根，所以混合回收一定发

生在新生代回收之后，且不需要再进行一次初始标记。这就是所谓的“借道”。

#### 2. 并发标记子阶段

当YGC执行结束之后，如果发现满足并发标记的条件，并发线程就开始进行并发标记。根据新生代的Survivor分区开始并发标记。并发标记的时机是在YGC后，只有内存消耗达到一定的阈值后才会触发。在G1中，这个阈值通过参数`InitiatingHeapOccupancyPercent`控制（默认值是45，表示的是当已经分配的内存加上本次将分配的内存超过内存总容量的45%时就可以开始并发标记）。多个并发标记线程启动，每个线程每次只扫描一个分区，从而标记出存活对象。在标记的时候还会计算存活对象的数量，同时会计算存活对象所占用的内存大小，并计入分区空间。

并发标记子阶段会对所有分区的对象进行标记。这个阶段并不需要STW，故标记线程和应用程序线程并发运行。使用Snapshot-At-The-Beginning (SATB) 算法进行并发标记。

#### 3. 再标记子阶段

再标记是最后一个标记阶段。在该阶段中，G1需要一个STW的时间段，找出所有未被访问的存活对象，同时完成存活内存数据计算。引

入该阶段是为了能够达到结束标记的目标。要结束标记过程，需要满足3个条件：

- 从根（survivor）出发并发标记子阶段已经标记出所有的存活对象。

- 标记栈是空的。

- 所有的引用变更对象都被处理了。这里的引用变更对象包括新增空间分配的对象和引用变更对象，新增空间所有对象被认为都是活跃的（即使对象已经“死亡”也没有关系，在这种情况下只是增加了一些浮动垃圾），引用变更处理的对象通过一个队列记录，在该子阶段会处理这个队列中所有的对象。

前两个条件是很容易满足的，但是满足最后一个条件是很困难的。如果不引入一个STW的再标记过程，那么应用会不断地更新引用，也就是说，会不断地产生新的引用变更，因而永远无法达成完成标记的条件。

这个子阶段是并行执行的。

#### 4. 清理子阶段

再标记子阶段之后是清理子阶段，该子阶段也需要一个STW的时间段。清理子阶段主要执行以下操作：

- 统计存活对象，统计的结果将会用来排序分区，以用于下一次的垃圾回收时分区的选择。

- 交换标记位图，为下次并发标记做准备。

- 把空闲分区放到空闲分区列表中。这里的空闲分区指的是全都是垃圾对象的分区，如果分区中还有活跃对象，则不会释放，真正释放的动作发生在混合回收中。

该阶段比较容易引起误解的地方在于，清理子阶段并不会清理垃圾对象，也不会执行存活对象的复制。也就是说，在极端情况下，该阶段结束之后，空闲分区列表将毫无变化，JVM的内存使用情况也毫无变化。

该子阶段也是并行执行的。

并发标记阶段完成之后，在下一次进行垃圾回收的时候就会回收垃圾比较多的老生代分区。这时进行的垃圾回收称为混合回收，混合回收和YGC最大的区别就是混合回收不仅仅回收所有的新生代分区，也回收部分垃圾多的老生代分区，所以JVM在实现混合回收时重用了YGC所有的代码，两者的不同之处就在于是否回收老生代分区。整个G1垃圾回收的过程如图1-6所示。

![Diagram illustrating the G1 Garbage Collection process. The process is divided into several stages: 1. 复制 (Copy) - Initial copying of objects. 2. 新生代回收 (New Generation Collection) - Initial marking phase. 3. 复制 (Copy) - Further copying. 4. 并发标记 (Concurrent Mark) - Concurrent marking phase. 5. 再标记 (Remark) - Final marking phase. 6. 清理 (Cleanup) - Cleanup phase. 7. 复制 (Copy) - Final copying. 8. 混合回收 (Mixed Collection) - Mixed collection phase that recycles both new and old generation regions. The diagram shows mutator threads (mutator) interacting with these stages, with blue arrows representing the flow of objects and data.](8c348bf9c2c81b018017ae1d19506a9a_img.jpg)

Diagram illustrating the G1 Garbage Collection process. The process is divided into several stages: 1. 复制 (Copy) - Initial copying of objects. 2. 新生代回收 (New Generation Collection) - Initial marking phase. 3. 复制 (Copy) - Further copying. 4. 并发标记 (Concurrent Mark) - Concurrent marking phase. 5. 再标记 (Remark) - Final marking phase. 6. 清理 (Cleanup) - Cleanup phase. 7. 复制 (Copy) - Final copying. 8. 混合回收 (Mixed Collection) - Mixed collection phase that recycles both new and old generation regions. The diagram shows mutator threads (mutator) interacting with these stages, with blue arrows representing the flow of objects and data.

图1-6 G1垃圾回收

#### 注意

在图1-6所示并发标记阶段中还可以发生YGC（可以是一次YGC，也可以是多次YGC），但为了简化并未体现；另外，在图中混合回收也可能发生多次，因为G1对停顿时间是有要求的，G1会根据预测的停顿时间决定一次回收老生代分区的数目，所以可能需要多次混合回收，才能完成并发标记阶段识别的垃圾比较多的老生代分区的回收。

最后，同样在垃圾回收过程或者并发执行过程中，当内存不足需要进行FGC时，也需要STW对整个内存进行串行回收。在JDK 10中对FGC做了改进，把串行回收改进成并行回收，注意是并行的FGC，而不是并发回收。

在G1工作时，还有两个值得注意的地方：

- G1的引用集RSet处理，它是并发执行的，目的是记录对象的引用关系，能减少垃圾回收过程中的停顿时间。

- 在G1中，并发标记算法使用了SATB算法，该算法是G1并发标记的核心。

引用集RSet的处理是代际管理垃圾回收器中非常重要的一个内容，虽然ZGC目前是单代管理，暂时不会涉及引用集概念，但是ZGC未来很有可能会支持多代管理。另外，ZGC中并发算法和G1的并发标记算法有相似之处，都是基于SATB实现的，但实现方式不同，所以有必要对G1的RSet处理和SATB算法做一个介绍。

#### 1. RSet处理

RSet是一个抽象概念，记录对象在不同代际之间的引用关系，目的是加速垃圾回收的速度。JVM使用的是根对象引用的收集算法，即从根集合出发，标记所有存活的对象，然后遍历对象的每一个成员变量[3]并继续标记，直到所有的对象标记完毕。在分代垃圾回收中，我们知道新生代和老生代处于不同的回收阶段，如果还是采用这样的标记方法，不合理也没必要。假设我们只回收新生代，如果标记时把老生代中的活跃对象全部标记，但回收时并没有回收老生代，则浪费了时间。同理，在回收老生代时有同样的问题。当且仅当我们要进行FGC时，才需要对内存做全部标记。所以算法设计者做了这样的设计——用一个RSet记录从非收集部分指向收集部分的指针的集合，而这个集合描述就是对象的引用关系。通常有两种方法记录引用关系，第一种为Point Out，第二种为Point In。假设有这样的引用关系，对象A的

成员变量指向对象B（伪代码为：ObjA.Field=ObjB），对于Point Out的记录方式来说，会在对象A（ObjA）的RSet中记录对象B（ObjB）的地址；对于Point In的记录方式来说，会在对象B（ObjB）的RSet中记录对象A（ObjA）的地址，这相当于一种反向引用。这二者的区别在于处理时有所不同：Point Out记录简单，但是需要对RSet做全部扫描；Point In记录操作复杂，但是在标记扫描时可以直接找到有用和无用的对象，不需要进行额外的扫描，因为RSet里面的对象可以看作根对象。G1中使用的是Point In的方式，为了提高RSet的存储效率，使用了3种数据结构：

1）稀疏表，通过哈希表方式（哈希表底层使用数组）来存储。

2）细粒度表，通过数组来存储，每个数组元素指向引用者分区中512字节内存块对本分区的引用情况。

3）粗粒度位图，通过位图来指示，每1位表示对应的分区有引用到本分区。

RSet的3种数据结构如图1-7所示。

![Diagram illustrating three RSet implementation methods: 1) Sparse table, 2) Fine-grained table, and 3) Coarse-grained bitmap.](c494cd874a082a97b50b3c4d3938f467_img.jpg)

1) 稀疏表, 使用固定长度的数组记录

3) 粗粒度位图, 1位代表一个分区

2) 细粒度表, 使用数组作为一级缓存, 每个数组元素记录一个引用页面的信息

分区的起始地址

1位代表一个512字节的卡表块

HeapRegion\*  
bitmap  
prev\*  
next\*  
colision\_list\*

Diagram illustrating three RSet implementation methods: 1) Sparse table, 2) Fine-grained table, and 3) Coarse-grained bitmap.

图1-7 RSet的3种实现方式

G1新引入了Refine线程, 它实际上是一个线程池, 有两大功能:

- 用于处理新生代分区的抽样, 并且在满足响应时间这个指标的情况下, 更新新生代分区的数目, 通常由一个单独的线程来处理。

- 更新RSet (也是最重要的功能)。对于RSet的更新并不是同步完成的, G1会把所有引用关系都先放入一个队列中, 称为Dirty Card Queue (DCQ), 然后使用Refine线程来消费这个队列完成引用关系的记录。正常来说有G1ConcRefinementThreads [4] 个线程处理; 实际上

除了Refine线程更新RSet之外，GC工作线程<sup>[5]</sup>或者应用程序线程<sup>[6]</sup>也可能会更新RSet；DCQ通过Dirty Card Queue Set（DCQS）来管理；为了能够快速、并发地处理，每个Refine线程只负责DCQS中的某几个DCQ。

虽然RSet是为了记录对象在代际之间的引用，但是并不是所有代际之间的引用都需要记录。我们简单地分析一下哪些情况需要使用RSet进行记录。分区之间的引用关系可以归纳为：

- 分区内部有引用关系。
- 新生代分区到新生代分区之间有引用关系。
- 新生代分区到老生代分区之间有引用关系。
- 老生代分区到新生代分区之间有引用关系。
- 老生代分区到老生代分区之间有引用关系。

这里的引用关系指的是分区里面有一个对象存在一个指针指向另一个分区的对象。针对这5种情况，最简单的方式就是在RSet中记录所有的引用关系，但这并不是最优的设计方案，因为使用RSet进行回收实际上有两个重大的缺点：

- 需要额外的内存空间；这一部分通常是G1最大的额外开销，一般会达到1%~20%。

- 可能导致浮动垃圾；由于根据RSet回收，而RSet里面的对象可能已经死亡，这个时候被引用对象会被认为是活跃对象，实质上它是浮动垃圾。

所以有必要对RSet进行优化，根据垃圾回收的原理，我们来逐一分析哪些引用关系需要记录在RSet中：

- 分区内部有引用关系，无论是新生代分区还是老生代分区内部的引用，都无须记录引用关系，因为回收的时候是针对一个分区而言，即这个分区要么被回收，要么不回收。如果分区回收，则会遍历整个分区，所以无须记录这种额外的引用关系。

- 新生代分区到新生代分区之间有引用关系，这无须记录，原因在于G1的YGC/Mixed GC/FGC回收算法都会全量处理新生代分区，所以它们都会被遍历，所以无须记录新生代到新生代之间的引用。

- 新生代分区到老生代分区之间有引用关系，这无须记录，对于G1中YGC针对的新生代分区，无须知道这个引用关系，混合回收发生时，G1会使用新生代分区作为根，那么遍历新生代分区时自然能找到新生代分区到老生代分区的引用，所以也无须记录这个引用关系，对于FGC来说更是如此，所有的分区都会被处理。

- 老生代分区到新生代分区之间有引用关系，这需要记录，在YGC的时候有两种根：一个就是栈空间/全局空间变量的引用，另外一个就是老生代分区到新生代分区的引用。

- 老生代分区到老生代分区之间有引用关系，这需要记录，在混合回收的时候可能只有部分分区被回收，所以必须记录引用关系，快速找到哪些对象是活的。

表1-2中总结了上面的关系。

表1-2 需要使用RSet保存引用关系的情况

| 引用关系        | 是否需要 RSet |
|-------------|-----------|
| 分区内部        | 不需要       |
| 新生代分区到新生代分区 | 不需要       |
| 新生代分区到老生代分区 | 不需要       |
| 老生代分区到新生代分区 | 需要        |
| 老生代分区到老生代分区 | 需要        |

#### 2. SATB算法介绍

并发标记指的是标记线程和应用程序线程并发运行。那么标记线程如何并发地进行标记？并发标记时，一边标记垃圾对象，一边还在生成垃圾对象，如何能正确标记对象？为了解决这个问题，以前的垃圾回收算法采用串行执行方式，这里的串行指的是标记工作和对象生

成工作不同时进行。而G1中引入了新的算法SATB，在介绍算法之前，我们先回顾一下对象分配。

在堆分区中分配对象时，对象都是连续分配的，所以可以设计几个指针，分别是Bottom、Prev、Next和Top。用Bottom指向堆分区的起始地址，用Prev指针指向上一次并发处理后的地址，用Next指向并发标记开始之前内存已经分配成功的地址，当并发标记开始之后，如果有新的对象分配，可以移动Top指针，使用Top指针指向当前内存分配成功的地址。Next指针和Top指针之间的地址就是应用程序线程新增对象使用的内存空间。如果假设Prev指针之前的对象已经标记成功，在并发标记的时候从根出发，不仅仅标记Prev和Next之间的对象，还标记了Prev指针之前活跃的对象。当并发标记结束之后，只需要把Prev指针设置为Next指针即可开始新一轮的标记处理。

Prev和Next指针解决了并发标记工作内存区域的问题，还需要引入两个额外的数据结构来记录内存标记的状态，典型的是使用位图（BitMap）来指示哪块内存已经使用，哪块内存还未使用，所以并发标记引入两个位图PrevBitmap和NextBitmap，用PrevBitmap记录Prev指针之前内存的标记状况，用NextBitmap表示整个内存从Bottom到Next指针之前的标记状态。

也许你会奇怪，NextBitmap包含了整个使用内存的标记状态，那为什么要引入PrevBitmap这个数据结构？这个数据结构在什么时候使

用？我们可以想象，如果并发标记每次都成功，我们确实不需要用到PrevBitmap，只需要根据NextBitmap这个位图对对象进行清除即可。但是如果标记失败将会发生什么？我们将丢失上一次对Prev指针之前所有内存的标记状况，也就是说当不能完成并发标记时，将需要重新标记整个内存，这显然是不对的。我们通过示意图来演示一下并发标记的过程。

假定初始情况如图1-8所示。

![Diagram illustrating the initial state of concurrent marking. It shows a large horizontal rectangle representing the heap, divided into a shaded left section and an unshaded right section. A vertical line labeled 'Top' separates them. Above the heap is a horizontal array of five empty boxes labeled 'NextBitmap'. Two blue arrows point from the labels 'Bottom Prev' and 'Top Next' to the 'Top' boundary of the heap.](1142ba0197b158bb198186fe8baccc32_img.jpg)

The diagram illustrates the initial state of concurrent marking. It features a large horizontal rectangle representing the heap, divided into a shaded left section and an unshaded right section. A vertical line labeled 'Top' separates them. Above the heap is a horizontal array of five empty boxes labeled 'NextBitmap'. Two blue arrows point from the labels 'Bottom Prev' and 'Top Next' to the 'Top' boundary of the heap.

Diagram illustrating the initial state of concurrent marking. It shows a large horizontal rectangle representing the heap, divided into a shaded left section and an unshaded right section. A vertical line labeled 'Top' separates them. Above the heap is a horizontal array of five empty boxes labeled 'NextBitmap'. Two blue arrows point from the labels 'Bottom Prev' and 'Top Next' to the 'Top' boundary of the heap.

图1-8 并发标记开始之前

这里用Bottom表示分区的底部，Top表示分区空间使用的顶部，TAMS指的是Top-At-Mark-Start，Prev就是前一次标记的地址，即Prev TAMS，Next指向的是当前开始标记时最新的地址，即Next TAMS。并发标记开始是从根对象<sup>[7]</sup>出发开始并发的标记。在第一次标记时PrevBitmap为空，NextBitmap待标记。开始进行并发标记，结束后如图1-9所示。

![Diagram illustrating the state after concurrent marking. It shows a 'NextBitmap' with a 6-bit sequence (white, black, white, black, black, white). Below it is a large horizontal bar representing the heap, divided into three sections: a light gray section from 'Bottom Prev' to 'Next', a medium gray section from 'Next' to 'Top', and a white section from 'Top' onwards. The label '并发标记' (Concurrent Marking) is on the right. A label '标记过程新分配对象' (Newly allocated objects during marking process) is centered below the 'Next' and 'Top' markers. Blue arrows point from 'Bottom Prev', 'Next', and 'Top' to their respective positions on the heap bar.](f57c7b37d7a05a99618104f390089f03_img.jpg)

Diagram illustrating the state after concurrent marking. It shows a 'NextBitmap' with a 6-bit sequence (white, black, white, black, black, white). Below it is a large horizontal bar representing the heap, divided into three sections: a light gray section from 'Bottom Prev' to 'Next', a medium gray section from 'Next' to 'Top', and a white section from 'Top' onwards. The label '并发标记' (Concurrent Marking) is on the right. A label '标记过程新分配对象' (Newly allocated objects during marking process) is centered below the 'Next' and 'Top' markers. Blue arrows point from 'Bottom Prev', 'Next', and 'Top' to their respective positions on the heap bar.

图1-9 并发标记结束后的状态

并发标记结束后，NextBitmap记录了分区对象存活的情况，假定上述位图中黑色区域表示堆分区中对应的对象还活着。在并发标记的同时应用程序继续运行，所以Top指针发生了变化，继续增长。

这个时候，可以认为NextBitmap中活跃对象以及Next和Top之间的对象都是活跃的。在进行垃圾回收的时候，如果分区需要被回收，则会把这些对象都进行复制；如果分区可用空间比较多，那么分区不需要回收。当应用程序继续执行，新一轮的并发标记启动时，初始状态如图1-10所示。

在新一轮的并发标记开始时，交换Bitmap，重置指针。根据根对象对Bottom和Next TAMS之间的内存对象进行标记，标记结束后，状态如图1-11所示。

![Diagram illustrating the state before the second concurrent marking begins. It shows three horizontal components: a 10-cell 'NextBitmap' with all cells white, a 5-cell 'PrevBitmap' with cells 2, 3, 4, and 5 black, and a large horizontal bar representing the heap space. The heap space is divided into three shaded segments by vertical lines labeled 'Bottom', 'Prev TAMS', and 'Next TAMS'. The label '第二次初始标记' (Second Initial Marking) is on the right.](e64c7b989e5bdb2708cd7aefd18b06e1_img.jpg)

Diagram illustrating the state before the second concurrent marking begins. It shows three horizontal components: a 10-cell 'NextBitmap' with all cells white, a 5-cell 'PrevBitmap' with cells 2, 3, 4, and 5 black, and a large horizontal bar representing the heap space. The heap space is divided into three shaded segments by vertical lines labeled 'Bottom', 'Prev TAMS', and 'Next TAMS'. The label '第二次初始标记' (Second Initial Marking) is on the right.

图1-10 第二次并发标记开始之前的状态

![Diagram illustrating the state after the second concurrent marking ends. The 'NextBitmap' now has cells 4, 5, 7, 8, and 9 black. The 'PrevBitmap' remains the same. The heap space now has four shaded segments, with the third segment labeled '标记过程新分配对象' (New objects allocated during marking process). The 'Top' pointer is now at the end of the heap space.](02bb4edc0dbdf4f0749ffd3e0ea2805c_img.jpg)

Diagram illustrating the state after the second concurrent marking ends. The 'NextBitmap' now has cells 4, 5, 7, 8, and 9 black. The 'PrevBitmap' remains the same. The heap space now has four shaded segments, with the third segment labeled '标记过程新分配对象' (New objects allocated during marking process). The 'Top' pointer is now at the end of the heap space.

图1-11 第二次并发标记结束后的状态

当标记完成时，如果分区垃圾对象满足一定条件（如分区的垃圾对象占用的内存空间达到一定的数值），分区就可以被回收。

这里演示的仅仅是并发标记的SATB算法，但是还有一个主要的问题没有解决，那就是应用程序和并发标记工作线程对同一个对象进行修改，如何保证标记的正确性？这一内容将在4.2.1节中进一步讨论。

#### 3. G1中的屏障

在G1中使用了两种屏障：读屏障和写屏障。其中写屏障是为了处理RSet引入的，而读屏障是为了处理SATB并发标记引入的，所以一句简单的Java赋值语句，例如Object.Field=other\_object，实际上被JVM处理成3条伪代码，如下所示：

---

```
JVM -----> Insert Pre-write barrier, 处理
SATB, 保证标记的正确性

Object.Field = other_object; 真正的代码

JVM -----> Insert Post-write Barrier, 处理
RSet, 即产生对象到
DCQ中
```

---

关于读屏障和写屏障这里不再进一步介绍。另外，G1中还引入了字符串去重的功能，在JDK 10中还对G1的FGC进行了优化，从串行回收变成了并行回收等，更多相关内容可以参考其他书籍。

[1] 图1-5中，大对象分区也是老生代分区的一种，当对象比较大（超过一定大小）时被分配到大对象分区，一个大对象分区可以由多个分区组成。

[2] 注意其他垃圾回收新生代的大小也可以动态地变化，但这个变化主要是根据内存的使用情况进行的。G1中则是以预测时间为导向，根

据内存的使用情况，调整新生代分区的数目。

[3] Java中的变量类型可以分为基本类型和引用类型。基本类型指int、double等8种类型；引用类型指通过类实例化的对象或者数组类型。在本书中讨论的成员变量类型都是指Java的引用类型。

[4] 这是G1提供的一个参数，控制并发Refine线程的个数。

[5] GC工作线程会处理一部分RSet，个数由参数G1ConcRefinementGreenZone控制。

[6] 应用程序线程在Refine忙的时候会主动承担RSet的处理。应用程序线程如何判断Refine忙？主要是通过DCQS中DCQ的个数判断，当个数超过一定数目时，就会主动参与RSet的处理。

[7] G1的并发标记以上一次垃圾回收（YGC）后的Survivor分区作为根对象。

### 1.2.5 ZGC

G1作为新一代成熟的垃圾回收器尚未得到广泛使用，新一代的垃圾回收器ZGC在JDK 11中引入，ZGC是2017年Oracle公司贡献给OpenJDK社区的，正式成为OpenJDK的开源项目，也就是JEP 333，目前它被明确地标记为实验性质（意味着还不成熟）。新一代的垃圾回收器一经发布，虽然尚不成熟，但是仍然阻挡不了众多Java程序员对它的追捧。ZGC是为了解决G1的不足，我们先看一下G1有哪些不足。

G1的目标是在可控的停顿时间<sup>[1]</sup>内完成垃圾回收，所以进行了分区设计，在回收时采用部分内存回收（在YGC时会回收所有新生代分区，在混合回收时会回收所有的新生代分区和部分老生代分区），支持的内存也可以达到几十个GB或者上百个GB。为了进行部分回收，G1实现了RSet管理对象的引用关系。基于G1设计上的特点，导致存在以下问题：

- 停顿时间过长，通常G1的停顿时间要达到几十到几百毫秒；这个数字其实已经非常小了，但是我们知道垃圾回收发生导致应用程序在这几十或者几百毫秒中不能提供服务，在某些场景中，特别是对用户体验有较高要求的情况下不能满足实际需求。

- 内存利用率不高，通常引用关系的处理需要额外消耗内存，一般占整个内存的1%~20%左右。

- 支持的内存空间有限，不适用于超大内存的系统，特别是在内存容量高于100GB的系统中，会因内存过大而导致停顿时间增长。

ZGC作为新一代的垃圾回收器，在设计之初就定义了三大目标：支持TB级内存，停顿时间控制在10ms之内，对程序吞吐量影响小于15%。实际上目前ZGC已经满足设计之初定义的目标，最大支持4TB堆空间，依据实际测试的情况来看，停顿时间通常都在10ms以下，并且垃圾回收所引起的暂停时间并不会随着内存的增大而延长。下面我们看一看ZGC是如何满足设计目标的。

看到这三大目标，是不是觉得不可思议，应该如何设计或者如何改进以前的垃圾回收器才能实现这些目标？ZGC的设计思路借鉴了一款商业垃圾回收器——Azul的C4（关于C4的介绍，可以参考相关论文[2]）。C4这款垃圾回收器号称无停顿时间，所以很多人认为ZGC也是完全无停顿时间的，即ZGC在执行垃圾回收时完全不需要暂停应用程序，这实际上是对无停顿时间的误解。在这里对无停顿时间做个简要介绍，实际上从垃圾回收器的角度出发，没有任何一款垃圾回收器能做到完全无停顿时间，所谓的无停顿时间指的是停顿时间足够短，这个时间不影响应用程序的运行，比如ZGC的停顿时间小于10ms，从应用程序来看这个停顿时间就可以忽略，所以称为无停顿时间。大家在学

习时应该知道这一概念指的是什么，另外，ZGC希望能将停顿时间控制在10ms以内，但不是所有垃圾回收活动都能在10ms内完成，注意，这里的10ms是一个目标值。那么哪些因素可能影响ZGC的目标停顿时间？除了ZGC中本身的STW活动，还有进入安全点（执行垃圾回收活动之前）的花费，比如我们知道在JVM中进入安全点时会进行字符串回收（这里字符串回收指的是回收因使用String类中的intern方法而产生的垃圾），所以ZGC为了保证进入安全点的时间足够短，会把这一部分工作优化成并发处理。

回到ZGC如何设计以达成目标这一问题。简单地说，就是ZGC把一切能并发处理的工作都并发执行。在这里再强调一下JVM中“并行”和“并发”这两个词：并行指多个垃圾回收相关线程在操作系统之上并发地运行，强调的是只有垃圾回收线程工作，Java应用程序都暂停执行，因此并行线程执行的时候一定发生了STW；并发指如果启动了多个线程，那么与垃圾回收相关的线程并发地运行，同时这些线程会和Java应用程序并发地运行。所有线程都由操作系统调度，交替执行。哪些工作是可以并发执行的？我们看一下ZGC的设计思路。

ZGC是在G1的基础上发展起来的，我们知道G1中实现了并发标记（参考图1-6），所以标记已经不会再影响停顿时间了。G1中的停顿时间主要来自垃圾回收（YGC和混合回收）阶段中的复制算法，在复制算法中，需要把对象转移到新的空间中，并且更新其他对象到这个对象

的引用。实际中对象的转移涉及内存的分配和对象成员变量的复制，而对象成员变量的复制是非常耗时的。在G1中对象的转移都是在STW中并行执行的 [\[3\]](#) ，而ZGC就是把对象的转移也并发执行，从而满足停顿时间在10ms以下。我们看一个实际的例子，这是使用G1作为垃圾回收器运行Cassandra [\[4\]](#) 的一个日志片段。在Cassandra的配置中，希望每次停顿时间为100ms，但是G1在这一次垃圾回收时花费了497.945ms，其中Evacuate Collection Set花费493ms。

---

```
GC(259) Pause Young (Normal) (G1 Evacuation Pause)
GC(259) Using 8 workers of 8 for evacuation
GC(259) MMU target violated: 101.0ms (100.0ms/101.0ms)
GC(259)   Pre Evacuate Collection Set: 0.1ms
GC(259)   Evacuate Collection Set: 493.0ms
GC(259)   Post Evacuate Collection Set: 3.5ms
GC(259)   Other: 1.2ms
GC(259) Eden regions:163->0(164)
GC(259) Survivor regions:16->15(23)
GC(259) Old regions:520->523
GC(259) Humongous regions:3->3
GC(259) Metaspace: 48742K->48742K(1093632K)
GC(259) Pause Young (Normal) (G1 Evacuation Pause) 2804M->2162M(14336M)
497.945ms
GC(259) User=2.18s Sys=0.01s Real=0.50s
```

---

Evacuate Collection Set就是对整个回收集合的分区进行标记和转移。493ms包含了标记和转移所用时间，如果使用一些诊断参数查看更细粒度的统计数据，通常转移时间占比在80%左右。转移时因为存在内存复制，所以极其耗时，从而导致停顿时间不可控，更多细节可以参考其他文档。ZGC中的改进就是把这步最耗时的动作变成了并发执行。

另外，在G1中可能存在FGC，如果发生了FGC，也可能导致停顿时间不可控。在目前的ZGC中，垃圾回收就是全量回收，也就是每发生一次垃圾回收就是一次FGC，而每次垃圾回收的停顿时间在10ms以下，所以FGC导致停顿时间不可控这一存在于G1中的问题也解决了。因为ZGC中每次垃圾回收都是全量回收（即每次都是FGC），那么大家可能会问，如果对象分配不成功，ZGC将如何处理这种情况呢？这里先留一个疑问，后文中将回答。

ZGC除了并发转移，还对整个垃圾回收进入STW的过程做了改进，把原来串行执行的动作也并发执行。在这里我们比较一下不同垃圾回收器在并发粒度上的区别，如表1-3所示。

表1-3 不同垃圾回收器的并发执行 [5]

| 并发性<br>垃圾回收器 | 串行回收器 | 并行回收器 | CMS | G1  | ZGC             |
|--------------|-------|-------|-----|-----|-----------------|
|              | 标记    | 不支持   | 不支持 | 支持  | 支持              |
| 转移           | 不支持   | 不支持   | 不支持 | 不支持 | 支持              |
| 引用处理         | 不支持   | 不支持   | 不支持 | 不支持 | 支持              |
| 符号表          | 不支持   | 不支持   | 不支持 | 不支持 | 支持              |
| 字符串表         | 不支持   | 不支持   | 不支持 | 不支持 | 支持              |
| 弱引用处理        | 不支持   | 不支持   | 不支持 | 不支持 | 支持              |
| 类卸载          | 不支持   | 不支持   | 不支持 | 不支持 | 支持 <sup>②</sup> |

注释：从JDK 12开始支持并发类卸载。

这里的不支持并发执行，对于不同的垃圾回收器，概念还有区别。对于串行回收器来说，不支持并发执行意味着所有步骤是串行执

行的。对于其他垃圾回收器，不支持并发执行又分成两种情况，一种是并行执行，例如转移、引用处理、弱引用处理；另一种是串行执行，如符号表、字符串表、类卸载。它们通常是在进入安全点的时候执行（通过VMThread串行执行，VMThread是整个JVM执行垃圾回收的核心，关于VMThread的详细内容将在3.2.3节介绍）。这样设计的目的是在实现复杂性和保证效率间寻找平衡，通常来说并发处理效率高，但是实现复杂；串行/并行效率略低，实现简单。

最后对ZGC做一个简单的总结。除了并发执行这个显著特点之外，ZGC还有以下特点：

- 不分代的垃圾回收器，即垃圾回收时对全量内存进行标记，但是回收时仅针对部分内存回收，优先回收垃圾比较多的页面。
- 仅支持Linux 64位系统，不支持32位平台。
- 不支持使用压缩指针。
- 内存分区管理，且支持不同的分区粒度，在ZGC中分区称为页面（page），有小页面、中页面、大页面3种。
- 具有颜色指针（color pointer），通过设计不同的标记位区分不同的虚拟空间，而这些不同标记位指示的不同虚拟空间通过mmap映

射在同一物理地址；颜色指针能够快速实现并发标记、转移和重定位。

- 设计了读屏障，实现了并发标记和并发转移的处理。
- 支持NUMA，尽量把对象分配在访问速度比较快的地方。

关于这些特点，后文都会一一介绍。最后还要强调一下，目前ZGC仅仅是实验性质的垃圾回收器，在一些大内存的场景中表现了良好的性能，同时也说明ZGC还有一些不足，主要有：

• 仅实现了单代内存管理，也就是说没有考虑热点数据与冷数据，分代内存管理在C4中已经得到支持。据Azul官网文章介绍，所实现的分代的内存管理器比没有分代的内存管理器效率高10倍，也就是说ZGC还有巨大的进步空间。

- C2的支持还不够完善。
- 不支持Graal、HDSB等功能。
- 一些功能尚待完善，比如尚不支持类回收。
- 稳定性尚需提高。

粗略估计ZGC可能要到下一个Long Term Support的版本才能得到完善。那么为什么还不完善的ZGC这么快就被纳入了OpenJDK的官方项

目？据Per Lin、Eric等ZGC的几个主要维护者的观点，这样做是希望能尽快推出ZGC以得到广大开源爱好者的支持，并由社区推动，快速发展。关于ZGC更多的介绍可以参考官方网站 [\[6\]](#)。

[\[1\]](#) 停顿时间指的是执行一次YGC或者Mixed GC的时间，或者并发标记中STW的初始标记、再标记和清理阶段花费的时间。

[\[2\]](#) G Tene, B Iyengar, M Wolf. C4: The Continuously Concurrent Compacting Collector. In Proceedings of the 10th International Symposium on Memory Management, ISMM 2011.

[\[3\]](#) 串行回收器、并行回收器和CMS中的复制也是在STW中完成的。

[\[4\]](#) Cassandra是一套开源分布式NoSQL数据库系统，是现在主流的大数据产品之一。其官网地址为<https://cassandra.apache.org/>。

[\[5\]](#) 参考了 <http://cr.openjdk.java.net/~pliden/slides/ZGC-Devopxx-2018.pdf>，Oracle拥有该表的版权，此处使用已获得授权。

[\[6\]](#) 网址为<https://wiki.openjdk.java.net/display/zgc/Main>。

### 1.2.6 Shenandoah

Shenandoah是另一款实验性质的垃圾回收器，在JDK 12中将正式合入OpenJDK的官方项目。Shenandoah的起源要追溯到2014年之前，最早由Red Hat公司发起，目标是利用现代多核CPU的优势，减少大堆内存存在垃圾回收发生时的停顿时间。Shenandoah后来被贡献给了OpenJDK，正式成为OpenJDK的开源项目，也就是JEP 189。

Shenandoah最初的目标是把垃圾回收停顿时间降到毫秒级别，并且对内存的支持扩展到太字节（TB）级别。为了降低停顿时间，回收器需要使用更多的线程来并行处理回收任务。如果要在降低停顿时间的同时支持更大的堆空间，那么CPU需要具备更好的多核处理能力。相比于CMS和G1，Shenandoah不仅进行并行的垃圾标记，在压缩堆空间时也是并发进行的。从这一点上看，Shenandoah和ZGC是非常类似的，都是解决了并发转移的问题，不过它们两者在实现上采用不同的方法。目前从效果来看，Shenandoah和ZGC存在竞争关系，当然竞争不是坏事，一方面可以促进社区的蓬勃发展，另外一方面这两个项目可以相互借鉴，这也是为什么在ZGC加入OpenJDK之后，Shenandoah也被整合到OpenJDK。

Shenandoah不像ZGC仅支持Linux 64位系统，它是在原来的对象头上增加一个额外的指针，通过这个指针可以实现读屏障、写屏障和比

较屏障，从而实现并发标记和并发转移时的并发处理。因为Shenandoah立项比较早，所以实现的功能也更多、更全。到目前为止，Shenandoah已经实现了很多特性，包括解释器、C1屏障、C2屏障、对引用的支持、对JNI临界区域的支持、对System.gc()的支持等。Shenandoah目前还算稳定，它的平均性能能够达到G1的90%，有时会差一些，比如只有G1的70%，不过有时候会超过G1的性能，比如达到G1的150%。

虽然Shenandoah和ZGC都加入OpenJDK中，就目前的结果来说，Shenandoah功能实现得更为齐全，但Shenandoah在进行并发处理时需要3种屏障，而ZGC在进行并发处理时仅需要读屏障，且不需要访问内存对象，所以效率更高。但两者的路都还很长，最后的结果如何目前还未可知。关于Shenandoah更多的内容可以参考官方网站 [1] 。

[1] 网 址 为  
<https://wiki.openjdk.java.net/display/shenandoah/Main>。