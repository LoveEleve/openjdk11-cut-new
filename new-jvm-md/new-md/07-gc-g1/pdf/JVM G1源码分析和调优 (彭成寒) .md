

![Logo of China Machine Press, featuring a stylized '1' inside a square frame.](2dfa6ac3edfe874f68aa0cbccaa42322_img.jpg)

Logo of China Machine Press, featuring a stylized '1' inside a square frame.

资深Java工程师撰写，来自一线实战经验的结晶

详细分析G1的基本运行原理以及调优方法，讲解细致，图示丰富，可帮助Java工程师深入理解垃圾回收技术

![Small orange icon of a coffee cup.](64662465bba247703fdec49c8f3309f9_img.jpg)

Small orange icon of a coffee cup.

# JVM G1 源码分析和调优

JVM G1 Implementation and Performance Tuning

彭成寒 编著

![A detailed illustration of a golden, ornate coffee cup with a handle, set against a background of soft, wavy lines in light purple and white.](4f4b52340aaccb1bcf733468dca9ee03_img.jpg)

A detailed illustration of a golden, ornate coffee cup with a handle, set against a background of soft, wavy lines in light purple and white.

![Logo of China Machine Press, featuring a stylized red circle with a white character inside.](6ed175c791b5e156d9c98a8dbcc3318c_img.jpg)

Logo of China Machine Press, featuring a stylized red circle with a white character inside.

机械工业出版社  
China Machine Press

# 目录

1. [目录](#)
2. [封面](#)
3. [版权信息](#)
4. [前言](#)
5. [第1章 垃圾回收概述](#)
6. [1.1 Java发展概述](#)
7. [1.2 本书常见术语](#)
8. [1.3 回收算法概述](#)
9. [1.3.1 分代管理算法](#)
10. [1.3.2 复制算法](#)
11. [1.3.3 标记清除](#)
12. [1.3.4 标记压缩](#)
13. [1.3.5 算法小结](#)
14. [1.4 JVM垃圾回收器概述](#)
15. [1.4.1 串行回收](#)
16. [1.4.2 并行回收](#)
17. [1.4.3 并发标记回收](#)
18. [1.4.4 垃圾优先回收](#)
19. [第2章 G1的基本概念](#)
20. [2.1 分区](#)
21. [2.2 G1停顿预测模型](#)
22. [2.3 卡表和位图](#)
23. [2.4 对象头](#)
24. [2.5 内存分配和管理](#)
25. [2.6 线程](#)
26. [2.6.1 栈帧](#)

- 27. [2.6.2 句柄](#)
- 28. [2.6.3 JVM本地方法栈中的对象](#)
- 29. [2.6.4 Java本地方法栈中的对象](#)
- 30. [2.7 日志解读](#)
- 31. [2.8 参数介绍和调优](#)
- 32. [第3章 G1的对象分配](#)
- 33. [3.1 对象分配概述](#)
- 34. [3.2 快速分配](#)
- 35. [3.3 慢速分配](#)
- 36. [3.3.1 大对象分配](#)
- 37. [3.3.2 最后的分配尝试](#)
- 38. [3.4 G1垃圾回收的时机](#)
- 39. [3.4.1 分配时发生回收](#)
- 40. [3.4.2 外部调用的回收](#)
- 41. [3.5 参数介绍和调优](#)
- 42. [第4章 G1的Refine线程](#)
- 43. [4.1 记忆集](#)
- 44. [4.2 Refine线程的功能及原理](#)
- 45. [4.2.1 抽样线程](#)
- 46. [4.2.2 管理RSet](#)
- 47. [4.2.3 Mutator处理DCQ](#)
- 48. [4.2.4 Refine线程的工作原理](#)
- 49. [4.3 Refinement Zone](#)
- 50. [4.4 RSet涉及的写屏障](#)
- 51. [4.5 日志解读](#)
- 52. [4.6 参数介绍和调优](#)
- 53. [第5章 新生代回收](#)
- 54. [5.1 YGC算法概述](#)
- 55. [5.2 YGC代码分析](#)
- 56. [5.2.1 并行任务](#)

- 57. [5.2.2 其他处理](#)
- 58. [5.3 YGC算法演示](#)
- 59. [5.3.1 选择CSet](#)
- 60. [5.3.2 根处理](#)
- 61. [5.3.3 RSet处理](#)
- 62. [5.3.4 复制](#)
- 63. [5.3.5 Redirty](#)
- 64. [5.3.6 释放空间](#)
- 65. [5.4 日志解读](#)
- 66. [5.4.2 大对象日志分析](#)
- 67. [5.4.3 对象年龄日志分析](#)
- 68. [5.5 参数介绍和调优](#)
- 69. [第6章 混合回收](#)
- 70. [6.1 并发标记算法详解](#)
- 71. [6.2 并发标记算法的难点](#)
- 72. [6.2.1 三色标记法](#)
- 73. [6.2.2 难点示意图](#)
- 74. [6.2.3 再谈写屏障](#)
- 75. [6.3 G1中混合回收的步骤](#)
- 76. [6.4 混合回收中并发标记处理的线程](#)
- 77. [6.4.1 并发标记线程启动的时机](#)
- 78. [6.4.2 根扫描子阶段](#)
- 79. [6.4.3 并发标记子阶段](#)
- 80. [6.4.4 再标记子阶段](#)
- 81. [6.4.5 清理子阶段](#)
- 82. [6.4.6 启动混合收集](#)
- 83. [6.5 并发标记算法演示](#)
- 84. [6.5.1 初始标记子阶段](#)
- 85. [6.5.2 根扫描子阶段](#)
- 86. [6.5.3 并发标记子阶段](#)

- 87. [6.5.4 再标记子阶段](#)
- 88. [6.5.5 清理子阶段](#)
- 89. [6.6 GC活动图](#)
- 90. [6.7 日志解读](#)
- 91. [6.8 参数优化](#)
- 92. [第7章 Full GC](#)
- 93. [7.1 Evac失败](#)
- 94. [7.2 串行FGC](#)
- 95. [7.2.1 标记活跃对象](#)
- 96. [7.2.2 计算对象的新地址](#)
- 97. [7.2.3 更新引用对象的地址](#)
- 98. [7.2.4 移动对象完成压缩](#)
- 99. [7.2.5 后处理](#)
- 100. [7.3 并行FGC](#)
- 101. [7.3.1 并行标记活跃对象](#)
- 102. [7.3.2 计算对象的新地址](#)
- 103. [7.3.3 更新引用对象的地址](#)
- 104. [7.3.4 移动对象完成压缩](#)
- 105. [7.3.5 后处理](#)
- 106. [7.4 日志解读](#)
- 107. [7.5 参数介绍和调优](#)
- 108. [第8章 G1中的引用处理](#)
- 109. [8.1 引用概述](#)
- 110. [8.2 可回收对象发现](#)
- 111. [8.3 在GC时的处理发现列表](#)
- 112. [8.4 重新激活可达的引用](#)
- 113. [8.5 日志解读](#)
- 114. [8.6 参数介绍和调优](#)
- 115. [第9章 G1的新特性：字符串去重](#)

- 116. [9.1 字符串去重概述](#)
- 117. [9.2 日志解读](#)
- 118. [9.3 参数介绍和调优](#)
- 119. [9.4 字符串去重和String.intern的区别](#)
- 120. [9.5 String.intern中的实现](#)
- 121. [第10章 线程中的安全点](#)
- 122. [10.1 安全点的基本概念](#)
- 123. [10.2 G1并发线程进入安全点](#)
- 124. [10.3 解释线程进入安全点](#)
- 125. [10.4 编译线程进入安全点](#)
- 126. [10.5 正在执行本地代码的线程进入安全点](#)
- 127. [10.6 安全点小结](#)
- 128. [10.7 日志分析](#)
- 129. [10.8 参数介绍和调优](#)
- 130. [第11章 垃圾回收器的选择](#)
- 131. [11.1 如何衡量垃圾回收器](#)
- 132. [11.2 G1调优的方向](#)
- 133. [第12章 新一代垃圾回收器](#)
- 134. [12.1 Shenandoah](#)
- 135. [12.2 ZGC](#)
- 136. [附录A 编译调试JVM](#)
- 137. [附录B 本地内存跟踪](#)
- 138. [附录C 阅读JVM需要了解的C++知识](#)



## 版权信息

书名：JVM G1源码分析和调优

作者：彭成寒

出版社：机械工业出版社

出版时间：2019-03-01

ISBN：9787111621973

品牌方：机械工业出版社有限公司

---

本书由机械工业出版社有限公司授权微信读书进行制作与发行

版权所有·侵权必究

## 前言

G1是目前最成熟的垃圾回收器，已经广泛应用在众多公司的生产环境中。我们知道，CMS作为使用最为广泛的垃圾回收器，也有令人头疼的问题，即如何对其众多的参数进行正确的设置。G1的目标就是替代CMS，所以在设计之初就希望降低程序员的负担，减少人工的介入。但这并不意味着我们完全不需要了解G1的原理和参数调优。笔者在实际工作中遇到过一些因参数设置不正确而导致GC停顿时间过长的问题。但要正确设置参数并不容易，这里涉及两个方面：第一，需要对G1的原理熟悉，只有熟悉G1的原理才知道调优的方向；第二，能分析和解读G1运行的日志信息，根据日志信息找到G1运行过程中的异常信息，并推断哪些参数可以解决这些异常。

本书尝试从G1的原理出发，系统地介绍新生代回收、混合回收、Full GC、并发标记、Refine线程等内容；同时依托于jdk8u的源代码介绍Hotspot如何实现G1，通过对源代码的分析来了解G1提供了哪些参数、这些参数的具体意义；最后本书还设计了一些示例代码，给出了G1在运行这些示例代码时的日志，通过日志分析来尝试调整参数并达到性能优化，还分析了参数调整可能带来的负面影响。

乍听起来，G1非常复杂，应该会有很多的参数。实际上在JDK8的G1实现中，一共新增了93个参数，其中开发参数（develop）有41个，产品参数（product）有31个，诊断参数（diagnostic）有9个，实验参数（experimental）有12个。开发参数需要在调试版本中才能进行验证（本书只涉及个别参数），其余的三类参数都可以在发布版本中打开、验证和使用。本书除了几个用于验证的诊断参数外，覆盖了发布版本中涉及的所有参数，为读者理解G1以及调优G1提供了帮助。

本书共分为12章，主要内容如下：

·第1章介绍垃圾回收的发展及使用的算法，同时还介绍一些重要并常见的术语。该章的知识不仅仅限于本书介绍的G1，对于研读JVM文章或者JVM源码都有帮助。

·第2章介绍G1中的基本概念，包括分区、卡表、根集合、线程栈等和垃圾回收相关的基本知识点。

·第3章介绍G1是如何分配对象的，包括TLAB和慢速分配，G1的对象分配和其他垃圾回收器的对象分配非常类似，只不过在分配的时候以分区为基础，除此之外没有额外的变化，所以该章知识不仅仅适用于G1也适用于其他垃圾回收器，最后介绍了参数调优，同样也适用于其他的垃圾回收器。

·第4章介绍G1 Refine线程，包括G1如何管理和处理代际引用，从而加快垃圾回收速度，介绍了Refinement调优涉及的参数；虽然CMS也有卡表处理代际引用，但是G1的处理和CMS并不相同，Refine线程是G1新引入的部分。

·第5章介绍新生代回收，包括G1如何进行新生代回收，包括对象标记、复制、分区释放等细节，还介绍了新生代调优涉及的参数。

·第6章介绍混合回收。主要介绍G1的并发标记算法及其难点，以及G1中如何解决这个难点，同时介绍了并发标记的步骤：并发标记、Remark（再标记）和清理阶段；最后还介绍了并发标记的调优参数。

·第7章介绍Full GC。在G1中，Full GC对整个堆进行垃圾回收，该章介绍G1的串行Full GC和JDK 10之后的并行Full GC算法。

·第8章介绍垃圾回收过程中如何处理引用，该功能不是G1独有的，也适用于其他垃圾回收器。

·第9章介绍G1的新特性：字符串去重。根据OpenJDK的官方文档，该特性可平均节约内存13%左右，所以这是一个非常有用特性，值得大家尝试和使用。另外，该特性和JDK中String类的intern方法有一些类似的地方，所以该章还比较了它们之间的不同。

·第10章介绍线程中的安全点。安全点在实际调优中涉及的并不多，所以很多人并不是特别熟悉。实际上，垃圾回收发生时，在进入安全点中做了不少的工作，而这些工作基本上是串行进行的，这些事情很有可能导致垃圾回收的时间过长。该章除了介绍如何进入安全点之外，还介绍了在安全点中做的一些回收工作，以及当发现它们导致GC过长时该如何调优。

·第11章介绍如何选择垃圾回收器，以及选择G1遇到问题需要调优时我们该如何下手。该章属于理论性的指导，在实际工作中需要根据本书提到的参数正面影响和负面影响综合考虑，并不断调整。

·第12章介绍了下一代垃圾回收器Shenandoah和ZGC。G1作为发挥重要作用的垃圾回收器仍有不足之处，因此未来的垃圾回收器仍会继续发展，该章介绍了下一代垃圾回收器Shenandoah和ZGC对G1的改进之处及其工作原理。

本书的附录包含如下内容：

·附录A介绍如何开始阅读和调试JVM代码。这里简单介绍了G1的代码架构和组织形式。另外简单介绍了Linux的调试工具GDB，这个工具对于想要了解JVM细节的同学必不可少。

·附录B介绍如何使用NMT对JVM内存进行跟踪和调试。这个知识对于想要深入理解JVM内存的管理非常有帮助，另外在实际工作中，特别是JDK升级中我们必须比较同一应用在不同JVM运行情况下的内存使用。

·附录C介绍了Java程序员阅读JVM时需要知道的一些C++知识。这里并未罗列C++的语法以及语法特性，仅仅介绍一些C++语言特有的、而Java语言没有的语法，或者Java语言中的使用或理解不同于C++语言的部分语法。这个知识是为Java程序员准备的，特别是为在阅读JVM代码时准备的。

G1在JDK 6中出现，经历JDK 7的发展，到JDK 8已经相当成熟，在JDK 9之后G1就作为JVM的默认垃圾回收器。JDK 8作为Oracle公司长期支持的版本，本书主要基于JDK 8进行分析，所用的版本是jdk8u60。在第7章中为了扩展读者的视野，追踪最新的技术，还介绍了JDK 10中的并行Full GC。读者可以自行到OpenJDK的官网下载，也可以使用笔者在GitHub中的备份（JDK 8：

<https://github.com/chenghanpeng/jdk8u60>，JDK 10：

<https://github.com/chenghanpeng/jdk10u>）。

本书在分析源码的时候会给出源代码所属的文件，例如在介绍G1分区类型时，指出源代码位于

hotspot/src/share/vm/gc\_implementation/g1/heapRegionType.hpp，这里的hotspot就是你下载的jdk8u60代码里面的一级目录。如果你不希望在本地保留源代码可以直接浏览网址

<https://github.com/chenghanpeng/jdk8u60>，在此你可以找到这个一级目录hotspot，然后通过逐个查看子目录src、share、vm、gc\_implementation、g1就可以找到源文件heapRegionType.hpp。

需要注意的是，在分析源码的时候为了节约篇幅，通常会对原始的代码进行一些调整，例如删除一些大括号、统计信息、打印信息，或者删除一些不影响理解原理和算法的代码，大家在和源码比较时需要注意这些变化。另外对于定义在header文件和cpp文件中的一些函数，为了使代码紧凑，通常会忽略头文件中的定义，直接按照C++的语法，即类名::成员函数的方式给出源码，这样的代码可能和原文件不完全一致，但是完全符合C++语言的组织，阅读源码时要注意将定义和实现分开。

由于笔者水平有限，时间仓促，书中难免出现一些错误或者不准确的地方，恳请读者批评指正。可以通过

<https://github.com/chenghanpeng/jdk8u60/issues>进行讨论，期待能够得到读者朋友们的真情反馈，在技术道路上互勉共进。

在本书的写作过程中，得到了很多朋友以及同事的帮助和支持，在此表示衷心的感谢！

感谢吴怡编辑的支持和鼓励，在写作过程中给出了非常多的意见和建议，不厌其烦地认真和笔者沟通，力争做到清晰、准确、无误。感谢你的耐心，为你的专业精神致敬！

感谢我的家人，特别是谢谢我的儿子，体谅爸爸牺牲了陪伴你的时间。有了你们的支持和帮助，我才有时间和精力去完成写作。

# 第1章 垃圾回收概述

Java的发展已经超过了20年，已是最流行的编程语言。为了更好地了解和使用Java，越来越多的开发人员开始关注Java虚拟机

(JVM)的实现技术，其中**垃圾回收**(也称垃圾收集)是最热门的技术点之一。目前G1作为JVM中最新、最成熟的垃圾回收器受到很多的人关注，本书从G1的原理出发，介绍新生代收集、混合收集、Full GC、并发标记、Refine、Evacuation等内容。本章先回顾Java语言的发展历程，然后介绍JVM中一些常用的概念以便与读者统一术语，随后介绍垃圾回收的主要算法以及JVM中实现了哪些垃圾回收的算法。

## 1.1 Java发展概述

Java平台和语言最开始是SUN公司在1990年12月进行的一个内部研究项目，我们通常所说的Java一般泛指JDK（Java Developer Kit），它既包含了Java语言和开发工具，也包含了执行Java的虚拟机（Java Virtual Machine，JVM）。从1996年1月23日开始，JDK 1.0版本正式发布，到如今Java已经经历了23个春秋。以下是Java发展历程中值得纪念的几个时间点：

·1998年12月4日JDK迎来了一个里程碑版本1.2。其技术体系被分为三个方向，J2SE、J2EE、J2ME。代表技术包括EJB、Java Plugin、Swing；虚拟机第一次内置了JIT编译器；语言上引入了Collections集合类等。

·2000年5月8日，JDK1.3发布。在该版本中Hotspot正式成为默认的虚拟机，Hotspot是1997年SUN公司收购LongView Technologies公司而获得的。

·2002年2月13日，JDK1.4发布。该版本是Java走向成熟的一个版本。从此之后，每一个新的版本都会增加新的特性，比如JDK5改进了内存模型、支持泛型等；JDK6增强了锁同步等；JDK7正式支持G1垃圾回收、升级类加载的架构等；JDK8支持函数式编程等。

·2006年11月13日的JavaOne大会上，SUN公司宣布最终会把Java开源，由OpenJDK组织对这些源码独立管理，从此之后Java程序员多了一个研究JVM的官方渠道。

·2009年4月20日，Oracle公司宣布正式以74亿美元的价格收购SUN公司，Java商标从此正式归Oracle所有，自此Oracle对Java的管理和发布进入了一个新的时期。

随着时间的推移，JDK 9和JDK 10也已经正式发布，但是JDK 9和JDK 10并不是Oracle长期支持的版本（Long Term Support），这意味着JDK 9和JDK 10只是JDK 11的一个过渡版本，它们只用于整合新的特性，当下一个版本发布之后，这些过渡版本将不再更新维护。2018年9月25日JDK 11正式发布，随着新版本的发布，Oracle公司未来对JDK的支持也会变化。按照现在的声明，从2019年1月起对于商业用户，Oracle公司对JDK 8不再提供公共的更新，从2020年12月起对个人用户也不再提供公共的更新。

G1作为CMS的替代者，一直吸引着众多Java开发者的目光，自从JDK 7正式推出以来，G1不断地增强，并从JDK 8开始越来越成熟，在JDK 9、JDK 10、JDK 11中都成为默认的垃圾回收器。实际上也有越来越多的公司开始在生产环境中使用G1作为垃圾回收器，有一篇文章描述了JDK 9中GC的基准测试（benchmark），表明G1已经优于其他的GC<sup>注</sup>。可以预见随着JDK 11的推出，会有越来越多的公司和个人使用G1作为生产环境中的垃圾回收器。

G1的目标是在满足短时间停顿的同时达到一个高的吞吐量，适用于多核处理器、大内存容量的系统。其实现特点为：

·短停顿时间且可控：G1对内存进行分区，可以应用在大内存系统中；设计了基于部分内存回收的新生代收集和混合收集。

·高吞吐量：优化GC工作，使其尽可能与Mutator并发工作。设计了新的并发标记线程，用于并发标记内存；设计了Refine线程并发处理分区之间的引用关系，加快垃圾回收的速度。

新生代收集指针对全部新生代分区进行垃圾回收；混合收集指不仅仅回收新生代分区，同时回收一部分老生代分区，这通常发生在并发标记之后；Full GC指内存不足时需要对全部内存进行垃圾回收。

并发标记是G1新引入的部分，指的是在Mutator运行的同时标记哪些对象是垃圾，看到这里大家一定非常好奇G1到底是怎么实现的，举一个简单的例子。比如你的妈妈正在打扫房间，扫房房间需要识别哪些物品有用哪些无用，无用的物品就是垃圾。同时你正在房间活动，活动的同时你可能往房间增加了新的物品，也可能把房间的物品重新组合，也可能产生新的无用物品。最简单的垃圾回收器如串行回收器的做法就是在打扫房间标识物品的时候，你要暂停一切活动，这个时候你的妈妈就能完美地识别哪些物品有用哪些无用。但最大的问题就是需要你暂停一切活动直到房间里面的物品识别完毕，在实际系统中意味着这段时间应用程序不能提供服务。G1的并发标记就是在打扫房间识别物品有用或者无用的同时，你还可以继续活动，怎么正确做标记呢？一个简单的办法就是在打扫房间识别垃圾物品开始的时候记录你增加了哪些物品，动过哪些物品。然后在物品标记结束的时候对这些变更过的物品重新标记一次，当然在这一次标记时需要你暂停一切活动，否则永远也没有尽头，这通常称为再标记（Remark）。这个就是所谓的增量并发标记，在G1中具体的算法是Snapshot-At-The-Beginning（SATB），关于这个算法我们会在第6章详细介绍。Refine线程也是G1新引入的，它的目的是为了在进行部分收集的时候加速识别活跃对象，具体介绍参见第4章。

本书依托于jdk8u的源代码来介绍JVM如何实现G1，通过源代码的分析理解算法以及了解G1提供的参数的具体意义；最后还会给出一些例子，通过日志，分析该如何调整参数以达到性能优化。

这里提到的jdk8u是指OpenJDK的代码，OpenJDK是SUN公司（现Oracle）推出的JDK开源代码，因为标准的JDK（这里指Oracle版的JDK）会有一些内部功能的代码，那些代码在开源的时候并未公开。在2017年9月Oracle公司宣布Oracle JDK和OpenJDK将能自由切换，Oracle JDK也会依赖OpenJDK的代码进行构建，所以通常都是使用OpenJDK的代码进行分析和研究。读者可以自行到OpenJDK的官网上下载源代码，值得一提的是，JDK的代码会随着bug修复不断改变，所以为了保持阅读的一致性，我把本书使用的代码推送到GitHub上<sup>①</sup>，也使用该版本进行编译调试。

## 1.2 本书常见术语

JVM系统非常复杂，市面上有很多中英文书籍从不同的角度来介绍JVM，其中都用到了很多术语，但是大家对某些术语的解释并不完全相同。为了便于读者的理解，在这里统一定义和解释本书使用的一些术语。这些术语有些是我们约定俗成的叫法，有些是JVM里面的特别约定，还有一些是G1算法引入的。为了保持准确性，这里仅仅解释这些术语的含义，后续会进一步解释相关内容，本书将尽量使用这里定义的术语。

·并行（parallelism），指两个或者多个事件在同一时刻发生，在现代计算机中通常指多台处理器上同时处理多个任务。

·并发（concurrency），指两个或多个事件在同一时间间隔内发生，在现代计算机中一台处理器“同时”处理多个任务，那么这些任务只能交替运行，从处理器的角度上看任务只能串行执行，从用户的角度看这些任务“并行”执行，实际上是处理器根据一定的策略不断地切换执行这些“并行”的任务。

在JVM中，我们也常看到并行和并发。比如，典型的ParNew一般称为**并行收集器**，CMS一般称为**并发标记清除**（Concurrent Mark Sweep）。这看起来很奇怪，因为并行和并发是从处理器角度出发，但是这里明显不是，实际上并行和并发在JVM被重新定义了。

**JVM中的并行**，指多个垃圾回收相关线程在操作系统之上并发运行，这里的并行强调的是只有垃圾回收线程工作，Java应用程序都暂

停执行，因此ParNew工作的时候一定发生了STW。本书提到的\*\*\*ParTask（例如G1ParTask）指的就是在这些任务运行的时候应用程序都必须暂停。

·JVM中的并发，指垃圾回收相关的线程并发运行（如果启动多个线程），同时这些线程会和Java应用程序并发运行。本书提到的\*\*\*Concurrent\*\*\*Thread（例如ConcurrentG1RefineThread）就是指这些线程和Java应用程序同时运行。

·Stop-the-world（STW），直译就是停止一切，在JVM中指停止一切Java应用线程。

·安全点（Safepoint），指JVM在执行一些操作的时候需要STW，但并不是任何线程在任何地方都能进入STW，例如我们正在执行一段代码时，线程如何能够停止？设计安全点的目的是，当线程进入到安全点时，线程就会主动停止。

·Mutator，在很多英文文献和JVM源码中，经常看到这个单词，它指的是我们的Java应用线程。Mutator的含义是可变的，在这里的含义是因为线程运行，导致了内存的变化。GC中通常需要STW才能使Mutator暂停。

·记忆集（Remember Set），简称为RSet。主要记录不同代间对象的引用关系。

·Refine，尚未有统一的翻译，有时翻译为细化，但是不太准确，本书中不做翻译。G1中的ConcurrentG1RefineThread主要指处理RSet的线程。

·Evacuation，转移、撤退或者回收，简称为Evac，本书中不做翻译。在G1中指的是发现活跃对象，并将对象复制到新地址的过程。

·回收（Reclaim），通常指的是分区对象已经死亡或者已经完成Evac，分区可以被JVM再次使用。

·Closure，闭包，本书中不做翻译。在JVM中是一种辅助类，类似于我们已知的iterator，它通常提供了对内存的访问。

·GC Root，垃圾回收的根。在JVM的垃圾回收过程中，需要从GC Root出发标记活跃对象，确保正在使用的对象在垃圾回收后都是存活的。

·根集合（Root Set）。在JVM的垃圾回收过程中，需要从不同的GC Root出发，这些GC Root有线程栈、monitor列表、JNI对象等，而这些GC Root就构成了Root Set。

·Full GC，简称为FGC，整个堆的垃圾回收动作。通常Full GC是串行的，G1的Full GC不仅有串行实现，在JDK10中还有并行实现。

·再标记（Remark）。在本书中指的是并发标记算法中，处理完并发标记后，需要更新并发标记中Mutator变更的引用，这一步需要STW。

## 1.3 回收算法概述

垃圾回收（Garbage Collection, GC）指的是程序不用关心对象在内存中的生存周期，创建后只需要使用对象，不用关心何时释放以及如何释放对象，由JVM自动管理内存并释放这些对象所占用的空间。GC的历史非常悠久，从1960年Lisp语言开始就支持GC。垃圾回收针对的是堆空间，目前垃圾回收算法主要有两类：

·引用计数法：在堆内存中分配对象时，会为对象分配一段额外的空间，这个空间用于维护一个计数器，如果对象增加了一个新的引用，则将增加计数器。如果一个引用关系失效则减少计数器。当一个对象的计数器变为0，则说明该对象已经被废弃，处于不活跃状态，可以被回收。引用计数法需要解决循环依赖的问题，在我们众所周知的Python语言里，垃圾回收就使用了引用计数法。

·可达性分析法（根引用分析法），基本思路就是将根集合作为起始点，从这些节点开始向下搜索，搜索所走过的路径称为引用链，当一个对象没有被任何引用链访问到时，则证明此对象是不活跃的，可以被回收。

这两种算法各有优缺点，具体可以参考其他文献。JVM的垃圾回收采用了可达性分析法。垃圾回收算法也一直不断地演化，主要有以下分类：

·垃圾回收算法实现主要分为复制（Copy）、标记清除（Mark-Sweep）和标记压缩（Mark-Compact）。

·在回收方法上又可以分为串行回收、并行回收、并发回收。

在内存管理上可以分为代管理和非代管理。

我们首先看一下基本的收集算法。

### 1.3.1 分代管理算法

分代管理就是把内存划分成不同的区域进行管理，其思想来源是：有些对象存活的时间短，有些对象存活的时间长，把存活时间短的对象放在一个区域管理，把存活时间长的对象放在另一个区域管理。那么可以为两个不同的区域选择不同的算法，加快垃圾回收的效率。我们假定内存被划分成2个代：新生代和老生代。把容易死亡的对象放在新生代，通常采用复制算法回收；把预期存活时间较长的对象放在老生代，通常采用标记清除算法。

### 1.3.2 复制算法

复制算法的实现也有很多种，可以使用两个分区，也可以使用多个分区。使用两个分区时内存的利用率只有50%；使用多个分区（如3个分区），则可以提高内存的使用率。我们这里演示把堆空间分为1个新生代（分为3个分区：Eden、Survivor0、Survivor1）、1个老生代的收集过程。

普通对象创建的时候都是放在Eden区，S0和S1分别是两个存活区。第一次垃圾收集前S0和S1都为空，在垃圾收集后，Eden和S0里面的活跃对象（即可以通过根集合到达的对象）都放入了S1区，如图1-1所示。

![Diagram illustrating the first garbage collection step of the copying algorithm. The top row shows the state '第一次回收前' (Before first recovery) with Eden, Reserved Space, S0, S1, Old Generation, and Reserved Space. The bottom row shows the state '第一次回收' (First recovery) with Eden, Reserved Space, S0, S1, Old Generation, and Reserved Space. A line with an arrow points from the Eden area of the top row to the S1 area of the bottom row, indicating that live objects from Eden and S0 are copied to S1.](90ddb84c323b956e2d50a54d3f870566_img.jpg)

|      |      |    |    |     |      |        |
|------|------|----|----|-----|------|--------|
| Eden | 保留空间 | S0 | S1 | 老生代 | 保留空间 | 第一次回收前 |
| Eden | 保留空间 | S0 | S1 | 老生代 | 保留空间 | 第一次回收  |

Diagram illustrating the first garbage collection step of the copying algorithm. The top row shows the state '第一次回收前' (Before first recovery) with Eden, Reserved Space, S0, S1, Old Generation, and Reserved Space. The bottom row shows the state '第一次回收' (First recovery) with Eden, Reserved Space, S0, S1, Old Generation, and Reserved Space. A line with an arrow points from the Eden area of the top row to the S1 area of the bottom row, indicating that live objects from Eden and S0 are copied to S1.

图1-1 复制算法第一次回收

回收后Mutator继续运行并产生垃圾，在第二次运行前Eden和S1都有活跃对象，在垃圾收集后，Eden和S1里面的活跃对象（即可以通过根节点到达的对象）都被放入到S0区，一直这样循环收集，如图1-2所示。

![Diagram illustrating the second recovery step of the copying algorithm. It shows two memory layouts: '第二次回收前' (Before Second Recovery) and '第二次回收' (After Second Recovery).](aaf3e6e44cdeabd6d1df869c5f392ea1_img.jpg)

The diagram illustrates the state of memory during the second recovery step of the copying algorithm. It shows two horizontal bars representing memory layouts.

**Top Layout (Before Second Recovery):**

|      |      |    |    |     |      |        |
|------|------|----|----|-----|------|--------|
| Eden | 保留空间 | S0 | S1 | 老生代 | 保留空间 | 第二次回收前 |
|------|------|----|----|-----|------|--------|

**Bottom Layout (After Second Recovery):**

|      |      |    |    |     |    |      |       |
|------|------|----|----|-----|----|------|-------|
| Eden | 保留空间 | S0 | S1 | 老生代 | 晋升 | 保留空间 | 第二次回收 |
|------|------|----|----|-----|----|------|-------|

Two arrows originate from the '保留空间' (Reserved Space) cells in the Eden and S1 regions of the top layout, pointing to the '晋升' (Promotion) cell in the bottom layout, indicating that objects from these regions are being moved to the Old Generation.

Diagram illustrating the second recovery step of the copying algorithm. It shows two memory layouts: '第二次回收前' (Before Second Recovery) and '第二次回收' (After Second Recovery).

图1-2 复制算法第二次回收

### 1.3.3 标记清除

从根集合出发，遍历对象，把活跃对象入栈，并依次处理。处理方式可以是广度优先搜索也可以是深度优先搜索（通常使用深度优先搜索，节约内存）。标记出活跃对象之后，就可以把不活跃对象清除。下面演示一个简单的例子，从根集合出发查找堆空间的活跃对象，如图1-3所示。

![Diagram illustrating the Mark-and-Sweep algorithm with a depth-first search approach.](b235edb1dbe659e2782c9a0e47775ca4_img.jpg)

The diagram illustrates the Mark-and-Sweep algorithm using a depth-first search (DFS) approach. At the top, a root set (根集合) is shown as an oval. An arrow from the root set points to object 1 in the Eden space. Below the root set is a horizontal bar representing the heap space, divided into several segments: Eden (containing objects 1 and 3), a Reserved space (保留空间), Survivor space S1 (containing objects 2 and 4), the Old Generation (老生代) containing object 5, and another Reserved space (保留空间). Curved arrows indicate the traversal path: from root to object 1, then to object 3, then to the Reserved space, then to object 2, then to object 4, and finally to object 5. Below the heap space, there are five vertical rectangles representing the stack space (栈空间). Each stack frame contains two cells: the top cell contains the number 2, 4, 5, 3, or 1 respectively from left to right, and the bottom cell contains the number 1. This represents the objects being pushed onto the stack during the DFS traversal.

典型的深度空间搜索

Diagram illustrating the Mark-and-Sweep algorithm with a depth-first search approach.

图1-3 标记清除算法

这里仅仅演示了如何找到对象，没有进一步介绍找到对象后如何处理。对于标记清除算法其实还需要额外的数据结构（比如一个链表）来记录可用空间，在对象分配的时候从这个链表中寻找能够容纳对象的空间。当然这里还有很多细节都未涉及，比如在分配时如何找

到最合适的内存空间，有First Fit、Best Fit和Worst Fit等方法，这里不再赘述。标记清除算法最大的缺点就是使内存碎片化。

### 1.3.4 标记压缩

标记压缩算法是为了解决标记清除算法中使内存碎片化的问题，除了上述的标记动作之外，还会把活跃对象重新整理从头开始排列，减少内存碎片。

### 1.3.5 算法小结

垃圾回收的基础算法自提出以来并没有大的变化。表1-1对几种算法的优缺点进行了比较，更加详细的介绍请参考其他书籍。

表1-1 垃圾回收基础算法的优缺点

| 算法   | 优点                                     | 缺点                                 |
|------|----------------------------------------|------------------------------------|
| 复制   | 吞吐量大（一次能收集整个空间），分配效率高（对象可以连续分配），没有内存碎片 | 堆的使用效率低（需要额外的一个空间 To Space），需要移动对象 |
| 标记清除 | 无须移动对象，算法简单                            | 内存碎片化，分配慢（需要找到一个合适的空间）             |
| 标记压缩 | 堆的使用效率高，无内存碎片                          | 暂停时间更长，对缓存不友好（对象移动后顺序关系不存在）        |
| 分代   | 组合算法，分配效率高，堆的使用效率高                     | 算法复杂                               |

## 1.4 JVM垃圾回收器概述

为了达到最大性能，基于分代管理和回收算法，结合回收的时机，JVM实现垃圾回收器了：串行回收、并行回收、并发标记回收（CMS）和垃圾优先回收。

### 1.4.1 串行回收

串行回收使用单线程进行垃圾回收，在回收的时候Mutator需要STW。新生代通常采用复制算法，老生代通常采用标记压缩算法。串行回收典型的线程交互图如图1-4所示。

![Diagram illustrating the serial garbage collection (GC) process. It shows two vertical timelines labeled 'Mutator'. The left timeline has five horizontal arrows pointing right, representing the mutator's work. A thick gray arrow labeled '串行GC工作' (Serial GC Work) points from the left timeline to the right timeline, indicating that the GC process blocks the mutator. The right timeline also has five horizontal arrows pointing right, representing the mutator's work after the GC is complete.](318886a86a1dcc59e1fc83db6f157c60_img.jpg)

The diagram illustrates the serial garbage collection process. It features two vertical lines representing the execution timeline of the Mutator. The left timeline shows five horizontal arrows pointing to the right, representing the mutator's normal execution. A thick gray arrow labeled "串行GC工作" (Serial GC Work) points from the left timeline to the right timeline, indicating that the GC process blocks the mutator. The right timeline also shows five horizontal arrows pointing to the right, representing the mutator's execution after the GC is complete.

Diagram illustrating the serial garbage collection (GC) process. It shows two vertical timelines labeled 'Mutator'. The left timeline has five horizontal arrows pointing right, representing the mutator's work. A thick gray arrow labeled '串行GC工作' (Serial GC Work) points from the left timeline to the right timeline, indicating that the GC process blocks the mutator. The right timeline also has five horizontal arrows pointing right, representing the mutator's work after the GC is complete.

图1-4 串行回收

### 1.4.2 并行回收

并行回收使用多线程进行垃圾回收，在回收的时候Mutator需要暂停，新生代通常采用复制算法，老生代通常采用标记压缩算法。线程交互如图1-5所示。

![Diagram illustrating parallel garbage collection (GC) with mutator threads.](cfb98c691c1af5befe32ff9442eea511_img.jpg)

The diagram illustrates the interaction between Mutator threads and the GC worker during parallel garbage collection. It shows two vertical lines representing the execution timelines of the Mutator threads. Between these lines, a central horizontal bar is labeled "并行GC工作" (Parallel GC Work). The Mutator threads are represented by horizontal arrows pointing to the right. On the left side, there are six light gray arrows representing the Mutator threads. On the right side, there are six white arrows representing the Mutator threads. The central "并行GC工作" bar overlaps with the execution of the Mutator threads, indicating that the GC work is performed in parallel with the Mutator threads.

Diagram illustrating parallel garbage collection (GC) with mutator threads.

图1-5 并行回收

### 1.4.3 并发标记回收

并发标记回收（CMS）的整个回收期间划分成多个阶段：初始标记、并发标记、重新标记、并发清除等。在初始标记和重新标记阶段需要暂停Mutator，在并发标记和并发清除期间可以和Mutator并发运行，如图1-6所示。这个算法通常适用于老生代，新生代可以采用并行回收。

### 1.4.4 垃圾优先回收

垃圾优先回收器（Garbage-First，也称为G1）从JDK7 Update 4开始正式提供。G1致力于在多CPU和大内存服务器上对垃圾回收提供软实时目标和高吞吐量。G1垃圾回收器的设计和前面提到的3种回收器都不一样，它在并行、串行以及CMS GC针对堆空间的管理方式上都是连续的，如图1-7所示。

![Diagram illustrating the concurrent marking process in the G1 garbage collector. The diagram shows a timeline with four vertical phases: '初始标记' (Initial Mark), '并发标记' (Concurrent Mark), '再标记' (Remark), and '并发清除' (Concurrent Sweep). Arrows represent the flow of execution. In the '初始标记' phase, a 'Mutator' thread starts and a 'Marking' thread begins. In the '并发标记' phase, both 'Mutator' and 'Marking' threads run concurrently. In the '再标记' phase, the 'Marking' thread continues while the 'Mutator' thread is paused. In the '并发清除' phase, the 'Marking' thread is paused and the 'Mutator' thread resumes concurrent execution.](1142ba0197b158bb198186fe8baccc32_img.jpg)

The diagram illustrates the concurrent marking process in the G1 garbage collector. It is divided into four vertical phases: '初始标记' (Initial Mark), '并发标记' (Concurrent Mark), '再标记' (Remark), and '并发清除' (Concurrent Sweep). Each phase is represented by a vertical line. The '初始标记' phase shows a 'Mutator' thread starting and a 'Marking' thread beginning. The '并发标记' phase shows both 'Mutator' and 'Marking' threads running concurrently. The '再标记' phase shows the 'Marking' thread continuing while the 'Mutator' thread is paused. The '并发清除' phase shows the 'Marking' thread paused and the 'Mutator' thread resuming concurrent execution.

Diagram illustrating the concurrent marking process in the G1 garbage collector. The diagram shows a timeline with four vertical phases: '初始标记' (Initial Mark), '并发标记' (Concurrent Mark), '再标记' (Remark), and '并发清除' (Concurrent Sweep). Arrows represent the flow of execution. In the '初始标记' phase, a 'Mutator' thread starts and a 'Marking' thread begins. In the '并发标记' phase, both 'Mutator' and 'Marking' threads run concurrently. In the '再标记' phase, the 'Marking' thread continues while the 'Mutator' thread is paused. In the '并发清除' phase, the 'Marking' thread is paused and the 'Mutator' thread resumes concurrent execution.

图1-6 并发标记回收

![Diagram illustrating continuous space management in a heap. The heap is represented as a vertical stack of horizontal regions. The legend indicates: 新生代空间 (New Generation Space) is light gray, 老生代空间 (Old Generation Space) is dark gray, and 空白分区 (Blank Partition) is white. The diagram shows several regions of varying lengths, some containing sub-regions of different colors, representing the allocation of memory for different generations and blank space.](f57c7b37d7a05a99618104f390089f03_img.jpg)

The diagram shows a vertical stack of horizontal regions representing a heap. The legend on the right identifies three types of regions: 新生代空间 (New Generation Space) in light gray, 老生代空间 (Old Generation Space) in dark gray, and 空白分区 (Blank Partition) in white. The stack consists of several regions of varying lengths. Some regions are solid light gray or dark gray, while others are composed of sub-regions of different colors, representing the allocation of memory for different generations and blank space.

Diagram illustrating continuous space management in a heap. The heap is represented as a vertical stack of horizontal regions. The legend indicates: 新生代空间 (New Generation Space) is light gray, 老生代空间 (Old Generation Space) is dark gray, and 空白分区 (Blank Partition) is white. The diagram shows several regions of varying lengths, some containing sub-regions of different colors, representing the allocation of memory for different generations and blank space.

图1-7 连续空间管理

连续的内存将导致垃圾回收时收集时间过长，停顿时间不可控。因此G1将堆拆成一系列的分区（Heap Region），这样在一个时间段内，大部分的垃圾收集操作只针对一部分分区，而不是整个堆或整个（老生）代，如图1-8所示。

![Diagram illustrating G1 memory space management. A 10x10 grid represents memory partitions. The legend indicates: light gray for '新生代分区' (New Generation), dark gray for '老生代分区' (Old Generation), white for '空白分区' (Blank), and a dark gray with a white vertical bar for '大对象' (Large Object). The grid shows several partitions: a single light gray cell at (1,1), a single dark gray cell at (3,4), a single light gray cell at (3,6), a single dark gray cell at (4,5), a single light gray cell at (5,3), a single dark gray cell at (5,4), a single dark gray cell at (5,5), and a single dark gray cell at (5,6).](e64c7b989e5bdb2708cd7aefd18b06e1_img.jpg)

Diagram illustrating G1 memory space management. A 10x10 grid represents memory partitions. The legend indicates: light gray for '新生代分区' (New Generation), dark gray for '老生代分区' (Old Generation), white for '空白分区' (Blank), and a dark gray with a white vertical bar for '大对象' (Large Object). The grid shows several partitions: a single light gray cell at (1,1), a single dark gray cell at (3,4), a single light gray cell at (3,6), a single dark gray cell at (4,5), a single light gray cell at (5,3), a single dark gray cell at (5,4), a single dark gray cell at (5,5), and a single dark gray cell at (5,6).

图1-8 分区空间管理

在G1里，新生代就是一系列的内存分区，这意味着不用再要求新生代是一个连续的内存块。类似地，老生代也是由一系列的分区组成。这样也就不需要在JVM运行时考虑哪些分区是老生代，哪些是新生代。事实上，G1通常的运行状态是：映射G1分区的虚拟内存随着时间的推移在不同的代之间切换。例如一个G1分区最初被指定为新生代，经过一次新生代的回收之后，会将整个新生代分区都划入未使用的分区中，那它可以作为新生代分区使用，也可以作为老生代分区使用。很可能在完成一个新生代收集之后，一个新生代的分区在未来的某个时刻可用于老生代分区。同样，在一个老生代分区完成收集之后，它就成为了可用分区，在未来某个时候可作为一个新生代分区来使用。

G1新生代的收集方式是并行收集，采用复制算法。与其他JVM垃圾回收器一样，一旦发生一次新生代回收，整个新生代都会被回收，这也就是我们常说的**新生代回收**（Young GC）。但是G1和其他垃圾回收器不同的地方在于：

- G1会根据预测时间动态改变新生代的大小。

![Note icon: a speech bubble with a question mark and the character '注意' (Attention) next to it.](f3ce2d7158eb708e3487b8e35415db35_img.jpg)

Note icon: a speech bubble with a question mark and the character '注意' (Attention) next to it.

其他垃圾回收新生代的大小也可以动态变化，但这个变化主要是根据内存的使用情况进行的。G1中则是以预测时间为导向，根据内存的使用情况调整新生代分区的数目。

- G1老生代的垃圾回收方式与其他JVM垃圾回收器对老生代处理有着极大的不同。G1老生代的收集不会为了释放老生代的空间对整个老生代做回收。相反，在任意时刻只有一部分老生代分区会被回收，并且，这部分老生代分区将在下一次增量回收时与所有的新生代分区一起被收集。这就是我们所说的混合回收（Mixed GC）。在选择老生代分区的时候，优先考虑垃圾多的分区，这也正是垃圾优先这个名字的由来。后续我们将逐一介绍这些内容。

在G1中还有一个概念就是大对象，指的是待分配的对象大小超过一定的阈值之后，为了减少这种对象在垃圾回收过程的复制时间，直接把对象分配到老生代分区中而不是新生代分区中。

从实现角度来看，G1算法是复合算法，吸收了以下算法的优势：

- 列车算法，对内存进行分区，参见图1-8。
- CMS，对分区进行并发标记。
- 最老优先，最老的数据（通常也是垃圾）优先收集。

关于列车算法、CMS和最老优先可以参考其他的书籍，这里不再赘述。

# 第2章 G1的基本概念

通常我们所说的GC是指垃圾回收，但是在JVM的实现中GC更为准确的意思是指内存管理器，它有两个职能，第一是内存的分配管理，第二是垃圾回收。这两者是一个事物的两个方面，每一种垃圾回收策略都和内存的分配策略息息相关，脱离内存的分配去谈垃圾回收是没有任何意义的。

本书第3章会介绍G1如何分配对象，第4章到第10章都是介绍G1是如何进行垃圾回收的。为了更好地理解后续章节，本章主要介绍G1的一些基本概念，主要有：G1实现中所用的一些基础数据分区、G1的停顿预测模型、垃圾回收中使用到的对象头、并发标记中涉及的卡表和位图，以及垃圾回收过程中涉及的线程、栈帧和句柄等。

## 2.1 分区

分区（Heap Region，HR）或称堆分区，是G1堆和操作系统交互的最小管理单位。G1的分区类型（HeapRegionType）大致可以分为四类：

- 自由分区（Free Heap Region，FHR）
- 新生代分区（Young Heap Region，YHR）
- 大对象分区（Humongous Heap Region，HHR）
- 老生代分区（Old Heap Region，OHR）

其中新生代分区又可以分为Eden和Survivor；大对象分区又可以分为：大对象头分区和大对象连续分区。

每一个分区都对应一个分区类型，在代码中常见的is\_young、is\_old、is\_houmongous等判断分区类型的函数都是基于上述的分区类型实现，关于分区类型代码如下所示：

```
hotspot/src/share/vm/gc_implementation/g1/heapRegionType.hpp
// 0000 0 [ 0] Free
//
// 0001 0      Young Mask
// 0001 0 [ 2] Eden
// 0001 1 [ 3] Survivor
//
```

```
// 0010 0      Humongous Mask
// 0010 0 [ 4] Humongous Starts
// 0010 1 [ 5] Humongous Continues
//
// 01000 [ 8] Old
```

在G1中每个分区的大小都是相同的。该如何设置HR的大小？设置HR的大小有哪些考虑？

HR的大小直接影响分配和垃圾回收效率。如果过大，一个HR可以存放多个对象，分配效率高，但是回收的时候花费时间过长；如果太小则导致分配效率低下。为了达到分配效率和清理效率的平衡，HR有一个上限值和下限值，目前上限是32MB，下限是1MB（为了适应更小的内存分配，下限可能会被修改，在目前的版本中HR的大小只能为1MB、2MB、4MB、8MB、16MB和32MB），默认情况下，整个堆空间分为2048个HR（该值可以自动根据最小的堆分区大小计算得出）。HR大小可由以下方式确定：

·可以通过参数G1HeapRegionSize来指定大小，这个参数的默认值为0。

·启发式推断，即在不指定HR大小的时候，由G1启发式地推断HR大小。

HR启发式推断根据堆空间的最大值和最小值以及HR个数进行推断，设置Initial HeapSize（默认为0）等价于设置Xms，设置MaxHeapSize（默认为96MB）等价于设置Xmx。堆分区默认大小的

计算方式在HeapRegion.cpp中的setup\_heap\_region\_size()，代码如下所示：

```
hotspot/src/share/vm/gc_implementation/g1/heapRegion.cpp
void HeapRegion::setup_heap_region_size(...) {
    /*判断是否是设置过堆分区大小，如果有则使用；没有，则根据初始内存和最大
分配内存，获得平均值，并根据HR的个数得到分区的大小，和分区的下限比较，取
两者的最大值。*/
    uintx region_size = G1HeapRegionSize;
    if (FLAG_IS_DEFAULT(G1HeapRegionSize)) {
        size_t average_heap_size = (initial_heap_size +
max_heap_size) / 2;
        region_size = MAX2(average_heap_size /
HeapRegionBounds::target_number(),
                    (uintx) HeapRegionBounds::min_size());
    }
    // 对region_size按2的幂次对齐，并且保证其落在上下限范围内
    int region_size_log = log2_long((jlong) region_size);
    region_size = ((uintx)1 << region_size_log);
    // 确保region_size落在[1MB, 32MB]之间
    if (region_size < HeapRegionBounds::min_size()) {
        region_size = HeapRegionBounds::min_size();
    } else if (region_size > HeapRegionBounds::max_size()) {
        region_size = HeapRegionBounds::max_size();
    }
    // 根据region_size计算一些变量，如卡表大小
    region_size_log = log2_long((jlong) region_size);
    LogOfHRGrainBytes = region_size_log;
```

```
LogOfHRGrainWords = LogOfHRGrainBytes - LogHeapWordSize;
GrainBytes = (size_t)region_size;
GrainWords = GrainBytes >> LogHeapWordSize;
CardsPerRegion = GrainBytes >>
CardTableModRefBS::card_shift;
}
```

按照默认值计算，G1可以管理的最大内存为  
 $2048 \times 32 \text{ MB} = 64 \text{ GB}$ 。假设设置 `xms=32G`，`mx=128G`，则每个堆分区的大小为32M，分区个数动态变化范围从1024到4096个。

G1中大对象不使用新生代空间，直接进入老生代，那么多大的对象能称为大对象？简单来说是 `region_size` 的一半。

新生代大小

新生代大小指的是新生代内存空间的大小，前面提到G1中新生代大小按分区组织，即首先计算整个新生代的大小，然后根据上一节中的计算方法计算得到分区大小，两者相除得到需要多少个分区。G1中与新生代大小相关的参数设置和其他GC算法类似，G1中还增加了两个参数 `G1MaxNewSizePercent` 和 `G1NewSizePercent` 用于控制新生代的大小，整体逻辑如下：

如果设置新生代最大值（`MaxNewSize`）和最小值（`NewSize`），可以根据这些值计算新生代包含的最大的分区和最小的分区；注意 `Xmn` 等价于设置了 `MaxNewSize` 和 `NewSize`，且 `NewSize=MaxNewSize`。

·如果既设置了最大值或者最小值，又设置了NewRatio，则忽略NewRatio。

·如果没有设置新生代最大值和最小值，但是设置了NewRatio，则新生代的最大值和最小值是相同的，都是整个堆空间/(NewRatio+1)。

·如果没有设置新生代最大值和最小值，或者只设置了最大值和最小值中的一个，那么G1将根据参数G1MaxNewSizePercent（默认值为60）和G1NewSizePercent（默认值为5）占整个堆空间的比例来计算最大值和最小值。

值得注意的是，如果G1推断出最大值和最小值相等，则说明新生代不会动态变化。不会动态变化意味着G1在后续对新生代垃圾回收的时候可能不能满足期望停顿的时间，具体内容将在后文继续介绍。新生代大小相关的代码如下所示：

```
hotspot/src/share/vm/gc_implementation/g1/g1CollectorPolicy.cpp
// 初始化新生代大小参数，根据不同的JVM参数判断计算新生代大小，供后续使用
G1YoungGenSizer::G1YoungGenSizer() :
_sizer_kind(SizerDefaults), _adaptive_
size(true), _min_desired_young_length(0),
_max_desired_young_length(0) {
    // 如果设置NewRatio且同时设置NewSize或MaxNewSize的情况下，则
    NewRatio被忽略
    if (FLAG_IS_CMDLINE(NewRatio)) {
        if (FLAG_IS_CMDLINE(NewSize) ||
        FLAG_IS_CMDLINE(MaxNewSize)) {
            warning("-XX:NewSize and -XX:MaxNewSize override -
```

```
XX:NewRatio");
    } else {
        _sizer_kind = SizerNewRatio;
        _adaptive_size = false;
        return;
    }
}

// 参数传递有问题，最小值大于最大值
if (NewSize > MaxNewSize) {
    if (FLAG_IS_CMDLINE(MaxNewSize)) {
        warning("...");
    }
    MaxNewSize = NewSize;
}

// 根据参数计算分区的个数
if (FLAG_IS_CMDLINE(NewSize)) {
    _min_desired_young_length = MAX2((uint) (NewSize /
HeapRegion::
    GrainBytes), 1U);
    if (FLAG_IS_CMDLINE(MaxNewSize)) {
        _max_desired_young_length = MAX2((uint) (MaxNewSize /
HeapRegion::
    GrainBytes), 1U);
    _sizer_kind = SizerMaxAndNewSize;
    _adaptive_size = _min_desired_young_length ==
_max_desired_young_length;
    } else {
        _sizer_kind = SizerNewSizeOnly;
    }
} else if (FLAG_IS_CMDLINE(MaxNewSize)) {
```

```

    _max_desired_young_length = MAX2((uint) (MaxNewSize /
HeapRegion:::
    GrainBytes), 1U);
    _sizer_kind = SizerMaxNewSizeOnly;
}
}
// 使用G1NewSizePercent来计算新生代的最小值
uint G1YoungGenSizer::calculate_default_min_length(uint
new_number_of_heap_
    regions) {
    uint default_value = (new_number_of_heap_regions *
G1NewSizePercent) / 100;
    return MAX2(1U, default_value);
}
// 使用G1MaxNewSizePercent来计算新生代的最大值
uint G1YoungGenSizer::calculate_default_max_length(uint
new_number_of_heap_
    regions) {
    uint default_value = (new_number_of_heap_regions *
G1MaxNewSizePercent) / 100;
    return MAX2(1U, default_value);
}
/*这里根据不同的参数输入来计算大小。
recalculate_min_max_young_length在初始化时被调用，在堆空间改变时也
会被调用。*/
void G1YoungGenSizer::recalculate_min_max_young_length(uint
number_of_heap_
    regions, uint* min_young_length, uint* max_young_length) {
    assert(number_of_heap_regions > 0, "Heap must be
initialized");

```

```
switch (_sizer_kind) {
    case SizerDefaults:
        *min_young_length =
        calculate_default_min_length(number_of_heap_regions);
        *max_young_length =
        calculate_default_max_length(number_of_heap_regions);
        break;
    case SizerNewSizeOnly:
        *max_young_length =
        calculate_default_max_length(number_of_heap_regions);
        *max_young_length = MAX2(*min_young_length,
*max_young_length);
        break;
    case SizerMaxNewSizeOnly:
        *min_young_length =
        calculate_default_min_length(number_of_heap_regions);
        *min_young_length = MIN2(*min_young_length,
*max_young_length);
        break;
    case SizerMaxAndNewSize:
        // Do nothing. Values set on the command line, don't
update them at runtime.
        break;
    case SizerNewRatio:
        *min_young_length = number_of_heap_regions / (NewRatio
+ 1);
        *max_young_length = *min_young_length;
        break;
    default:
        ShouldNotReachHere();

```

```
    }  
}
```

如果G1是启发式推断新生代的大小，那么当新生代变化时该如何实现？简单地说，使用一个分区间表，扩张时如果有空闲的分区间表则可以直接把空闲分区加入到新生代分区间表中，如果没有的话则分配新的分区间然后把它加入到新生代分区间表中。G1有一个线程专门抽样处理预测新生代分区间表的长度应该多大，并动态调整。

另外还有一个问题，就是分配新的分区间时，何时扩展？一次扩展多少内存？

G1是自适应扩展内存空间的。参数-XX:GCTimeRatio表示GC与应用的耗费时间比，G1中默认为9，计算方式为  
 $_gc\_overhead\_perc=100.0\times(1.0/(1.0+GCTimeRatio))$ ，即G1 GC时间与应用时间占比不超过10%时不需要动态扩展，当GC时间超过这个阈值的10%，可以动态扩展。扩展时有一个参数G1ExpandByPercentOfAvailable（默认值是20）来控制一次扩展的比例，即每次都至少从未提交的内存中申请20%，有下限要求（一次申请的内存不能少于1M，最多是当前已分配的一倍），代码如下所示：

```
size_t G1CollectorPolicy::expansion_amount() {  
    // 先根据历史信息获取平均GC时间  
    double recent_gc_overhead = recent_avg_pause_time_ratio() *
```