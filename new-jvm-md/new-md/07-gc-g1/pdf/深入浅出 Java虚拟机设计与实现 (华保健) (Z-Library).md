

![Logo of the publisher, featuring a stylized 'J' and 'M' with the text '机械工业出版社' (China Machine Press) and '机工IT' below it.](2dfa6ac3edfe874f68aa0cbccaa42322_img.jpg)

Logo of the publisher, featuring a stylized 'J' and 'M' with the text '机械工业出版社' (China Machine Press) and '机工IT' below it.

本书不仅关注对技术本身的介绍，还重点强调了这些技术所涉及的知识对读者进一步掌握工具和提高软件设计水平的重要作用，并给出了丰富的示例和最佳实践。

![A stylized, colorful illustration of a landscape with two large rock formations in the water, one on the left and one on the right. The formations are rendered in vibrant shades of blue, purple, and red, with a large red sun setting behind them. A small boat with a person is visible in the water between the formations. The scene is reflected in the calm water below.](30a26f2d17ca95672702bf50fb4f0242_img.jpg)

A stylized, colorful illustration of a landscape with two large rock formations in the water, one on the left and one on the right. The formations are rendered in vibrant shades of blue, purple, and red, with a large red sun setting behind them. A small boat with a person is visible in the water between the formations. The scene is reflected in the calm water below.

# J 深入浅出 Java 虚拟机设计与实现

华保健 著

![A traditional Chinese ink wash painting style illustration of a landscape. It features several large, craggy rock formations in the water, some with small trees on top. A small boat is visible in the water. In the background, there are mountains and a flock of birds flying towards a sun or moon in the sky.](2173c0102e23a5ff29d90d4353fc0339_img.jpg)

A traditional Chinese ink wash painting style illustration of a landscape. It features several large, craggy rock formations in the water, some with small trees on top. A small boat is visible in the water. In the background, there are mountains and a flock of birds flying towards a sun or moon in the sky.

# J 深入浅出 Java 虚拟机设计与实现

本书由国内编译器和虚拟机方面的资深研究者执笔，详细介绍了 Java 虚拟机设计与实现的各个方面，并给出了相关算法的实现。全书围绕虚拟机架构，讨论了虚拟机中的所有重要组件，包括类加载器、执行引擎、本地方法接口、异常处理、堆和垃圾收集、多线程及调试。

本书不仅关注对技术本身的介绍，还重点强调了这些技术所涉及的知识对读者进一步掌握工具和提高软件设计水平的重要作用，并给出了丰富的示例和最佳实践。

本书适合 Java 程序员、对编译器和虚拟机底层技术感兴趣的工程人员，以及高等院校计算机相关专业的学生阅读。

## 图书在版编目 (CIP) 数据

深入浅出: Java 虚拟机设计与实现 / 华保健著. — 北京: 机械工业出版社, 2020. 1

ISBN 978-7-111-64524-5

I . ①深… II . ①华… III . ① Java 语言 - 程序设计 IV . ① TP312. 8

中国版本图书馆 CIP 数据核字 (2020) 第 002183 号

机械工业出版社 (北京市百万庄大街 22 号 邮政编码 100037)

策划编辑: 孙 业 责任编辑: 孙 业 赵小花

责任校对: 张 力 责任印制: 张 博

三河市国英印务有限公司印刷

2020 年 4 月第 1 版 · 第 1 次印刷

169mm×239mm · 25 印张 · 472 千字

0001—2500 册

标准书号: ISBN 978-7-111-64524-5

定价: 99.00 元

电话服务

网络服务

客服电话: 010-88361066 机 工 官 网: www.cmpbook.com  
010-88379833 机 工 官 博: weibo.com/cmp1952  
010-68326294 金 书 网: www.golden-book.com

封底无防伪标均为盗版 机工教育服务网: www.cmpedu.com

# 前 言

![A decorative flourish or brushstroke graphic element located below the title '前言'.](dc1e692e5b7efd8e5a2a790c458646d9_img.jpg)

A decorative flourish or brushstroke graphic element located below the title '前言'.

虚拟机设计与实现是计算机科学中最古老、最成熟，也是应用最广泛的课题之一。许多通用性和领域性程序设计语言都使用某种与体系结构无关的中间语言格式作为编译目标，该中间语言在虚拟机上运行，因此虚拟机设计和实现就成为了支撑这类语言构建软件系统的关键与基础，而深入理解和掌握虚拟机设计和实现的基本原理和技术，也成为程序员必备的重要知识和技能。

但是，虚拟机的设计与实现所涉及的知识体系广而繁杂，和计算机科学的许多学科分支，如算法设计分析、程序设计语言、编译器、体系结构等，都有密切联系，并且，现代虚拟机已经发展得非常复杂，其中包含很多编程技巧和各种优化方法。虚拟机设计和实现的这些特点给初学者带来了很多困难：一方面，以小型的教学虚拟机入手研究，难以看到虚拟机设计与实现的全貌；另一方面，研究和学习工业级的虚拟机实现，又容易陷入繁复的实现细节。

本书讨论了一个典型 Java 虚拟机的设计原理和实现技术，其内容编排遵循了以下几个原则。

第一个原则是完整性。初学者在学习虚拟机设计与实现技术时，遇到的最大困难是在设计和实现一个虚拟机的过程中遇到问题的多样性，其中包括但不限于字节码文件格式、编译、动态加载和链接、执行引擎、堆和垃圾收集、本地方法接口、多线程与锁等广泛的内容。因此，若不能对这些相关技术进行全面介绍，读者就很难了解到虚拟机实现的全过程。基于此，本书完整地介绍了 Java6(JVMS2) 的实现过程，讨论了其中每个特性的实现原理和技术。

第二个原则是实践性。本书除了讨论虚拟机设计的基本原理和方法，还介绍了虚拟机的实现技术，对讨论的每个数据结构和算法都给出了类 C 语言的伪代码实现描述，这样，读者不仅能够深入理解虚拟机实现的基本原理，还能基于这些算法实现自己的虚拟机。

第三个原则是应用性，即本书特别强调了虚拟机设计和实现相关的理论和技

术对 Java 程序设计的指导作用。为此,书中结合对虚拟机实现技术的讨论,给出了较多的 Java 代码实例。一方面,通过对这些具体 Java 代码实例的讨论,读者可以更深入地理解虚拟机的运行原理;另一方面,理解虚拟机的设计与实现原理也有助于程序员构造更高质量的 Java 软件系统。笔者相信,虽然只有少量程序员会专门从事虚拟机的研究和开发工作,但理解包括虚拟机在内的底层系统的工作机理,是当前程序员知识栈中不可或缺的重要部分。

本书分为 8 章,第 1 章介绍 Java 虚拟机的整体架构。本章还讨论了一个简单的源语言——J 语言,其中包括对 J 语言语法、栈式计算机、J 字节码等方面的讲解,阐述了该源语言的程序从编译、加载到解释执行的整个过程,让读者对高级语言编译、字节码虚拟指令集、解释执行等虚拟机里的重要概念有一个全局的了解,也为后续章节中对 Java 虚拟机的深入讨论奠定基础。

第 2 章讨论了虚拟机类加载器的实现,主要内容有类的二进制定义、虚拟机方法区的设计,以及类加载的过程,包括类装载算法、类的验证、类的准备、类的解析、类的初始化和这些阶段的执行顺序。最后,本章还讨论了自定义类加载器的实现技术,并给出了自定义类加载器的两个典型应用:动态代理和热替换。

第 3 章讨论了执行引擎的设计与实现。主要内容包括:Java 运行栈的组织与数据结构设计、Java 方法调用规范与参数传递、Java 字节码执行引擎等。本章还简要讨论了本地方法执行引擎和可重入函数,以及一种常用的执行引擎实现加速技术——汇编模板。

第 4 章讨论了本地方法接口的实现技术。本章首先介绍了 Java 提供的标准本地方法接口 (Java Native Interface, JNI),用于支持 Java 代码和本地代码的相互调用,然后讨论了二进制文件的加载、方法的静态注册和动态注册、本地方法的拦截,以及本地方法回调 Java 方法的技术。

第 5 章讨论了异常处理的实现方法和技术。本章首先给出了异常处理的两种最常用的实现技术——异常栈和异常表,讨论了这两种实现方式的优缺点,然后重点讨论了 Java 中使用的基于异常表的异常处理实现技术,包括异常表数据结构、栈回滚、本地方法异常等,最后讨论了异常处理中的一些其他重要问题,包括隐式异常、异常处理与多线程,以及异常的运行效率。

第 6 章讨论了堆和垃圾收集。Java 不支持动态内存的手工回收,而必须使用自动机制。本章讨论了 Java 堆数据结构、堆分配接口、对象的存储布局,并重点

讲解了基于 Cheney 算法的复制收集算法,另外,也介绍了和 Java 程序密切相关的根节点标记算法、终结和垃圾收集的触发机制。本章还讨论了对 Java 程序进行垃圾收集的一些关键问题,包括本地方法和垃圾收集、多线程与垃圾收集、无中断垃圾收集和类型标记等。

第 7 章讨论了多线程的实现技术。本章的主要内容有三个方面:第一,Java 多线程的语义模型,包括线程库中的主要线程方法、线程状态及线程中断;第二,管程的实现,包括管程数据结构、管程操作的接口与实现、管程与对象等;第三,多线程的实现,包括线程数据结构、创建线程对象、线程操作接口的支持等。本章还讨论了多线程与虚拟机其他子系统之间的交互。

第 8 章讨论了 Java 调试技术及其实现。本章内容包括 Java 调试器的整体架构、虚拟机端调试代理的设计与实现,以及 Java 调试在可调试性和安全性方面的问题。

限于篇幅并考虑读者的学习需求,本书略去了某些虚拟机实现技术,读者可以在其他著作中进一步学习。

本书是笔者在中国科学技术大学软件学院讲授的相关课程等资料基础上精心总结而成的,在此感谢中国科学技术大学相关老师和同学对课程的支持与建议。

由于作者水平和时间有限,错漏之处在所难免,敬请批评指正。

华保健

于中国科学技术大学软件学院

# 目 录CONTENTS

# 前 言

# 第 1 章 虚拟机架构 /1

- 1.1 Java 与 Java 虚拟机 /1
  - 1.1.1 设计背景 /1
  - 1.1.2 Java 技术栈的组成要素 /2
  - 1.1.3 Java 字节码 /3
- 1.2 Java 虚拟机架构 /5
- 1.3 实例: J 语言及其编译 /7
  - 1.3.1 J 语言语法 /7
  - 1.3.2 栈式计算机 /13
  - 1.3.3 J 字节码 /17
  - 1.3.4 J 语言编译到 J 字节码 /19
- 1.4 实例: J 虚拟机 /23
  - 1.4.1 字节码加载子系统 /23
  - 1.4.2 字节码验证器 /24
  - 1.4.3 解释执行引擎 /27

# 第 2 章 类加载器 /30

- 2.1 实例: Java 的类加载 /30
- 2.2 类的二进制定义 /32
  - 2.2.1 常量池 /34
  - 2.2.2 接口 /36
  - 2.2.3 字段 /37
  - 2.2.4 方法 /37
  - 2.2.5 属性 /38
- 2.3 方法区 /41

- 2.3.1 代码区 /41
- 2.3.2 运行时常量池 /45
- 2.3.3 类辅助数据结构 /47
- 2.4 类装载 /49
  - 2.4.1 递归下降装载 /50
  - 2.4.2 接口的装载 /57
  - 2.4.3 数组的装载 /57
  - 2.4.4 基本类的装载 /59
- 2.5 验证 /61
  - 2.5.1 为什么要进行验证 /61
  - 2.5.2 验证的目标 /63
  - 2.5.3 实例: 验证规则 /63
  - 2.5.4 结构化约束 /68
  - 2.5.5 类型推导 /69
- 2.6 准备 /75
  - 2.6.1 静态字段的准备 /76
  - 2.6.2 非静态字段的准备 /77
  - 2.6.3 虚方法表 /80
- 2.7 解析 /86
  - 2.7.1 实例: 类的解析 /86
  - 2.7.2 类的解析 /88
  - 2.7.3 字段的解析 /89
  - 2.7.4 方法的解析 /91
  - 2.7.5 接口方法的解析 /98
  - 2.7.6 字符串常量的解析 /100
  - 2.7.7 常量池其他表项的解析 /101
- 2.8 初始化 /101
  - 2.8.1 类初始化方法 /102
  - 2.8.2 类初始化算法 /103
- 2.9 类加载各阶段的执行顺序 /110

2.9.1 急切策略和惰性策略 /111

2.9.2 类解析和类初始化的耦合性 /113

2.10 自定义类加载器 /114

2.10.1 独立加载模型 /116

2.10.2 双亲委派模型 /118

2.11 实例: 类加载器的典型应用 /123

2.11.1 动态代理 /124

2.11.2 热替换 /133

# 第 3 章 执行引擎 /139

3.1 栈帧结构 /139

3.2 调用规范 /140

3.3 执行引擎架构 /141

3.3.1 序列式架构 /142

3.3.2 跳转表架构 /143

3.4 执行引擎实现 /145

3.4.1 常量加载指令 /145

3.4.2 数据加载指令 /147

3.4.3 数据存储指令 /149

3.4.4 栈操作指令 /151

3.4.5 数学运算指令 /152

3.4.6 数值转换指令 /155

3.4.7 比较运算指令 /157

3.4.8 控制转移指令 /159

3.4.9 引用指令 /176

3.4.10 扩展与虚拟机保留指令 /185

3.5 本地方法执行引擎 /187

3.6 可重入方法 /194

3.7 汇编模板 /198

# 第 4 章 本地方法接口 /201

4.1 实例: Java 本地方法 /201

|              |                |             |
|--------------|----------------|-------------|
| 4.2          | 方法绑定           | /202        |
| 4.2.1        | 本地方法的数据结构      | /203        |
| 4.2.2        | 动态库加载          | /205        |
| 4.2.3        | 动态绑定           | /206        |
| 4.2.4        | 静态绑定           | /209        |
| 4.3          | 本地方法拦截         | /213        |
| 4.3.1        | 拦截机制           | /213        |
| 4.3.2        | 耦合性            | /216        |
| 4.3.3        | 反射             | /217        |
| 4.4          | 本地方法回调 Java 方法 | /218        |
| 4.4.1        | JNI 回调函数       | /220        |
| 4.4.2        | 本地方法栈帧         | /223        |
| <b>第 5 章</b> | <b>异常处理</b>    | <b>/226</b> |
| 5.1          | 实例: Java 异常处理  | /226        |
| 5.2          | 异常栈            | /228        |
| 5.3          | 异常表            | /236        |
| 5.4          | 栈回滚            | /243        |
| 5.5          | 本地方法异常         | /247        |
| 5.6          | 其他问题           | /250        |
| 5.6.1        | 隐式异常           | /250        |
| 5.6.2        | 异常处理与多线程       | /253        |
| 5.6.3        | 执行效率           | /254        |
| <b>第 6 章</b> | <b>堆和垃圾收集</b>  | <b>/255</b> |
| 6.1          | 实例: 对象与垃圾      | /255        |
| 6.1.1        | 语法垃圾与语义垃圾      | /256        |
| 6.1.2        | 内存泄漏           | /257        |
| 6.2          | 堆              | /258        |
| 6.2.1        | 堆数据结构          | /258        |
| 6.2.2        | 堆分配接口          | /259        |
| 6.3          | 存储布局           | /259        |

|              |                  |             |
|--------------|------------------|-------------|
| 6.3.1        | 对象的存储布局          | /259        |
| 6.3.2        | 类的存储布局           | /263        |
| 6.3.3        | 数组的存储布局          | /264        |
| 6.4          | 垃圾收集             | /265        |
| 6.4.1        | 根节点              | /266        |
| 6.4.2        | 复制收集             | /270        |
| 6.4.3        | 终结               | /276        |
| 6.4.4        | 垃圾收集的触发          | /280        |
| 6.5          | 本地方法和垃圾收集        | /281        |
| 6.5.1        | 局部和全局引用          | /281        |
| 6.5.2        | 对象引用相关 JNI 函数的实现 | /283        |
| 6.6          | 其他问题             | /285        |
| 6.6.1        | 多线程与垃圾收集         | /285        |
| 6.6.2        | 无中断垃圾收集          | /289        |
| 6.6.3        | 类型标记             | /291        |
| <b>第 7 章</b> | <b>多线程</b>       | <b>/293</b> |
| 7.1          | 线程语义模型           | /293        |
| 7.1.1        | 线程方法             | /293        |
| 7.1.2        | 线程状态             | /294        |
| 7.1.3        | 实例: 线程中断         | /297        |
| 7.2          | 管程               | /303        |
| 7.2.1        | 管程数据结构           | /303        |
| 7.2.2        | 接口与实现            | /307        |
| 7.2.3        | 管程指令             | /314        |
| 7.2.4        | 管程与对象            | /316        |
| 7.3          | 多线程的实现           | /318        |
| 7.3.1        | 线程数据结构           | /319        |
| 7.3.2        | 创建线程对象           | /321        |
| 7.3.3        | 启动               | /323        |
| 7.3.4        | 让出               | /325        |

- 7.3.5 睡眠 /325
- 7.3.6 中断 /327
- 7.3.7 停止、挂起和继续 /335
- 7.3.8 原子性和可见性 /337
- 7.3.9 线程与信号 /338

## 7.4 多线程与虚拟机其他子系统的交互 /342

- 7.4.1 全局数据结构与锁 /343
- 7.4.2 类初始化 /345
- 7.4.3 垃圾收集 /350

# 第 8 章 调试 /357

- 8.1 调试器架构 /357
  - 8.1.1 客户端-服务器架构 /358
  - 8.1.2 JDWP 调试协议 /359
  - 8.1.3 数据类型 /360
  - 8.1.4 实例: 断点 /361
- 8.2 调试代理 /364
  - 8.2.1 通信模块 /365
  - 8.2.2 执行引擎模块 /366
  - 8.2.3 对象管理模块 /370
  - 8.2.4 事件处理模块 /371
- 8.3 实例: jdb 调试器 /376
- 8.4 调试的其他问题 /384
  - 8.4.1 薛定谔困境 /384
  - 8.4.2 调试与安全性 /386
  - 8.4.3 实例: JVM 渗透 /387

# 第 1 章 虚拟机架构

任何一个复杂的软件系统都可以分解成若干模块来理解和实现，虚拟机也不例外。本章主要讨论 Java 虚拟机的整体架构和主要模块的划分，后续章节将分别讨论每个模块的具体实现技术。Java 虚拟机是一个典型的栈式计算机，本章首先给出在这类计算机架构上编译和解释执行程序的典型流程。为此，本章将结合一种简单的高级语言以及一个小的栈式计算机，来讨论如何把高级语言编译为栈式计算机的指令集，进而完成类加载、验证、解释执行等过程。尽管这种高级语言比 Java 简单得多，示例栈式计算机也比 Java 虚拟机简单得多，但这个过程可以帮读者建立很好的整体思路图，以便能快速理解栈式虚拟机的技术核心及各模块间的相互关系，为本书后续深入讨论 Java 语言及 Java 虚拟机奠定基础。

## 1.1 Java 与 Java 虚拟机

本节先对 Java 语言和 Java 虚拟机设计和实现的背景进行简要介绍，从而让读者对 Java 语言的特点和 Java 虚拟机的设计有一个全面的了解。

### 1.1.1 设计背景

20 世纪 90 年代初，Sun Microsystems 公司开始进行 Java 语言的设计与实现，当时的主要背景是：互联网正快速兴起，需要一种语言和平台能够对互联网上的编程及程序分发提供更好的支持。因此，在设计之初，Java 的设计者们就为这个新的语言和相应的执行平台确立了以下目标。

- 可移动：在一个平台上编写的程序代码，可以经由网络分发到其他的平台上运行（当时主要以 Applets 的形式存在）。
- 跨平台：不同平台的体系结构和软硬件存在巨大差异，程序的执行需要做到与平台无关。
- 安全性：二进制代码必须能够独立于源代码进行检查和验证，以更好地保证二进制代码的安全性，这和传统上由 C/C++ 程序编译得到的二进制代码的执行

形成了鲜明的对比。

以上这些目标极大地影响了语言设计者所做的技术选型和设计思路, 最终得到的新语言 Java 和新执行平台 Java 虚拟机都基本达到了这些最初的目标。

第一, 为了提高可移动性, Java 字节码文件格式被设计为面向流, 而且指令采用了栈式计算机字节码编码方式, 不但使字节码文件在网络上的移动非常方便, 而且由于栈式字节码隐式操作数的特点, 代码的分发占用网络流量相对较小, 因此代码分发的速度更快 (当然, 今天的网络带宽已经和 20 世纪 90 年代初不可同日而语)。

第二, 为了达到平台无关性, Java 程序不是由真实的物理机器执行, 而是用 Java 虚拟机执行; Java 虚拟机屏蔽了平台的差异性: 只要某个平台上实现了 Java 虚拟机, Java 程序就可以运行。尽管 Java 不是第一个采用虚拟指令和虚拟机执行平台的语言, 而且有许多人, 包括 C++ 之父 Bjarne Stroustrup, 都认为 Java 虚拟机不过是“又一个新的平台”, 但 Java 的成功确实影响了后续许多语言的设计, 采用虚拟机执行程序逐渐成为一个非常热门的方式, 甚至有很多其他语言直接将 Java 虚拟机作为执行平台。

第三, 在 Java 平台上, 安全性被确立为非常重要的目标: Java 字节码二进制程序运行前, 要首先经过字节码验证器的验证, 验证未通过的程序会被拒绝执行, 验证通过的程序还要在运行期间进行动态检查, 对于含有不安全操作的程序, 虚拟机会抛出运行时异常。通过引入这些机制, Java 实现了安全性的目标。这种设计理念是非常先进的, Java 也是较早全面采用类型安全的二进制代码的语言之一, 又通过和垃圾收集等其他机制进行结合, 避免了其他语言 (尤其是 C/C++) 程序中难以避免的数组越界、缓冲区溢出等安全问题。

### 1.1.2 Java 技术栈的组成要素

广义上讲, Java 技术发展至今, 包括了四方面的核心内容: Java 语言、Java 类库、Java 字节码及字节码文件格式和 Java 虚拟机。

Java 语言指的是顶层语言自身, 从 Java 1.0 开始, Java 语言就在不断地发展, 陆续加入了泛型、函数式编程等越来越多的语言特征, 演化成为目前复杂的集命令式、面向对象及函数式为一体的语言形态。

Java 类库通常指的是 Sun 公司 (已被 Oracle 收购) 伴随着 Java 语言和 Java 虚拟机发布的一套标准类库, 广义上也包括所有的第三方类库。类库里提供了非

常丰富的数据结构、输入输出、操作系统接口、多线程支持等，大大提高了程序设计效率。同样，类库也在不断地演化，不断增加新的类和新的 API，也有一些类或 API 被废弃。

Java 字节码指的是 Sun 公司定义的一种低级别、类似汇编语言的程序设计语言，它是 Java 语言编译的目标语言。Java 字节码指令集是一种抽象的栈式计算机指令集，目前共包括 200 多条字节码指令。每条字节码指令的操作码部分都统一占用一个字节（这也是“字节码”这个称谓的由来），后面可跟多个操作数。相对 Java 语言及 Java 类库，Java 字节码的变动相对较小，20 多年来只对指令做了很小的修改。

Java 字节码文件格式指的是包含 Java 字节码程序的二进制可执行文件格式。严格来说，“文件格式”其实并非一定指的是磁盘文件，而是广义上任何符合文件格式标准的二进制流。随着 Java 新版本的发布，为了支持新的 Java 特性，Java 字节码文件格式也在不断变化。

最后，Java 虚拟机指的是能够读取和解析 Java 字节码文件、运行 Java 字节码程序的软件系统。除了 Sun 公司发布的“官方”Java 虚拟机 HotSpot 外，还有很多商业的和开源的 Java 虚拟机。本书要讲解的主要内容是 Java 虚拟机的设计与实现，但也和其他三部分内容有紧密联系。Java 虚拟机要依赖 Java 字节码及其文件格式进行理解，毕竟这是 Java 虚拟机的运行目标。Java 语言和 Java 类库与 Java 虚拟机的关系值得进一步讨论。

首先，Java 虚拟机是专门为 Java 语言设计的，Java 字节码中的部分指令就是为了支持 Java 语言的一些特性，例如，monitorenter 和 monitorexit 两条指令专门用来支持管程，而 invokeinterface 专门用来支持接口方法的调用，在实现这些指令时，必须熟悉 Java 语言中相关的机制。

其次，Java 虚拟机的实现也和 Java 类库密切相关，例如，类库 Object 中的大部分方法都是本地方法，如 getClass()、wait()、notify()、hashCode() 等。这些类库方法是本地方法的原因不难理解：它们都和虚拟机内部给对象分配的具体编码相关，因此，需要得到虚拟机的特殊支持。

由此也可以看到，深入学习 Java 虚拟机的运行机理与深入理解 Java 语言、Java 类库是相辅相成的。

### 1.1.3 Java 字节码

从编译的角度看，Java 字节码本质上定义了一种特定的“中间语言”，因为它

既不像 Java 语言这样处于顶层, 也不是 X86、ARM 等汇编指令集那样的底层语言, 抽象层次处于两者之间。一般来说, 在编译的过程中, 为某种高层语言引入恰当的中间语言, 而不是将其直接编译为底层特定体系结构的指令集, 有许多好处, 其中最主要的好处是能够有效隔离高层语言和底层体系结构间的巨大差异, 并屏蔽底层体系结构的细节, 有助于实现平台无关性。

以 Java 字节码为例, 除 Java 语言外, 还有很多其他高级语言也可以编译成 Java 字节码, 然后直接在 Java 虚拟机上执行。这种架构近年来非常流行, 已经有 ML、Ruby、Python、Scala、Kotlin 等高级语言采用了这样的方案, Java 字节码也因此有了脱离 Java 技术范畴, 发展成为更通用的中间语言的趋势。

实现 Java 虚拟机, 离不开对字节码以及 Java 虚拟机的规范化。Java 虚拟机目前的官方规范是 Sun 公司发布的《Java 虚拟机规范》, 它详细规定了所有 Java 虚拟机实现所必须遵循的规则, 这些规则包括字节码文件格式、字节码文件合法性的校验规则、Java 类的初始化时机、每条字节码指令的执行语义等。这项规范是虚拟机的实现者必不可少的参考文件。

《Java 虚拟机规范》的新版本发布略落后于相应的 Java 语言规范发布及 Java 虚拟机的具体实现: Sun 公司在 20 世纪 90 年代初推出了最早期的 Java 虚拟机, 接着将公司内部的虚拟机文档整理后, 于 1996 年, 发布了《Java 虚拟机规范》的第 1 版; 在 1999 年, 伴随 Java1.2 的发布, Sun 公司发布了《Java 虚拟机规范》(第 2 版); 2005 年, 伴随着 Java6 的发布 (即 Java1.6), Sun 公司发布了《Java 虚拟机规范》(第 3 版); 2013 年, Java7 的发布改变了 Java 虚拟机规范的命名规则, 新的虚拟机规范被称为《Java 虚拟机规范》(Java SE7 版); 按新的命名规范, Oracle 又陆续于 2015 年和 2017 年发布了《Java 虚拟机规范》(Java SE8 版) 和《Java 虚拟机规范》(Java SE9 版)。

尽管每个版本的《Java 虚拟机规范》都难免受到 Sun (Oracle) 虚拟机具体实现的影响, 甚至规范在许多地方都以 Sun(Oracle) 的具体虚拟机实现 HotSpot 为例进行讲解, 但本质上, 《Java 虚拟机规范》仍然是一个较为松散的规定, 在很多方面给虚拟机的实现留下了非常大的余地和空间。

以上的讨论, 可以总结成两点:

(1) Java 字节码和 Java 虚拟机都和 Java 语言无关。尽管 Java 字节码和 Java 虚拟机最初都是为 Java 语言设计的, 但目前已经有越来越多的其他高级语言可以

运行在 Java 虚拟机上, Java 虚拟机已经成为一个通用的运行平台。

(2)《Java 虚拟机规范》和 Java 虚拟机的具体实现无关。除了 Sun (Oracle) 的“官方”虚拟机外, 不同的厂商、研究机构和个人, 都可以按照规范的要求开发商用、研究或教学性质的 Java 虚拟机。

## 1.2 Java 虚拟机架构

《Java 虚拟机规范》给出了 Java 虚拟机的架构, 整个架构比较复杂, 但可以划分成图 1-1 所示的几个子系统: 类加载子系统、堆存储子系统、执行引擎、本地方法接口、线程管理等。这些子系统通过适当的接口相互协作, 共同实现 Java 虚拟机的功能。本节先简要介绍一下各个组成模块的功能以及相互间的接口。

![Diagram of the Java Virtual Machine architecture showing the flow from bytecode program through the class loader into the JVM memory space, and the interaction between the execution engine, native method interface, and native method library.](33a8f3f01dfa8bce75d23017855a13c5_img.jpg)

The diagram illustrates the Java Virtual Machine (JVM) architecture. At the top, a box labeled "Java字节码程序" (Java bytecode program) has an arrow pointing to a 3D block labeled "类加载器" (Class loader). Below the class loader is a large rounded rectangle labeled "Java虚拟机内存" (Java Virtual Machine memory). Inside this memory box are four smaller boxes: "方法区" (Method area), "堆" (Heap), "Java调用栈" (Java call stack), and "本地方法调用栈" (Native method call stack). Below the memory box is another 3D block labeled "执行引擎" (Execution engine). The execution engine has a double-headed arrow pointing to the memory box above it. Below the execution engine are two boxes: "本地方法接口" (Native method interface) and "本地方法库" (Native method library). The execution engine has a double-headed arrow pointing to the native method interface, which in turn has a double-headed arrow pointing to the native method library.

Diagram of the Java Virtual Machine architecture showing the flow from bytecode program through the class loader into the JVM memory space, and the interaction between the execution engine, native method interface, and native method library.

图 1-1 Java 虚拟机架构

类加载子系统负责把 Java 字节码文件加载到虚拟机内部, 在虚拟机内部有专门的存储区来存放加载的类。在一些文献中, 这些存放类的内部存储区被称为“方法区”(被称为“方法区”是因为历史原因, 也许“类区”是更准确的名字)。加载完毕后, 类加载子系统还要对类做进一步的处理, 完成类的验证、准备、解析、初始化等操作, 为执行类中的方法代码做好准备。Java 虚拟机类加载子系统采用了动态加载和动态链接的机制, 即虚拟机在运行过程中会随时加载所需要的类, 并把加载进来的类整合 (链接) 到虚拟机的内部数据结构中。这种机制增加了类加载子系

统实现的复杂性,但也增强了类加载子系统的表达能力,可以完成很多静态加载和静态链接不易实现的功能,例如实现动态代理及类的热替换等。类加载子系统是虚拟机中非常重要的一个基础模块,第 2 章将深入讨论该系统。

执行引擎负责执行 Java 字节码和本地代码。执行引擎必须设计合理的 Java 栈帧的数据结构和方法调用规范,以支持 Java 字节码的执行。Java 字节码包括 200 多条字节码指令,执行引擎需要精心地逐条实现每条指令的语义;同时,执行引擎还必须能够支持对本地方法和同步方法的调用。第 3 章将讨论执行引擎的设计与实现。

本地方法接口负责 Java 字节码和本地代码之间的交互,即让 Java 字节码能够调用本地代码,同时也让本地代码能够回调 Java 字节码,这使得 Java 程序能够复用大量现有的本地库,从而大大提高 Java 编程的便利性。虚拟机中的本地方法调用模块除了支持本地方法的调用外,还需要支持反射等 Java 特性,以及处理 Java 虚拟机和 Java 类库之间的耦合性。第 4 章将讨论本地方法接口。

异常处理是 Java 的重要程序设计特性之一,它允许程序员能够简洁地处理程序运行过程中出现的各种错误和异常情况,并从中恢复。在实际应用中,有两类常用的异常处理实现技术:异常栈和异常表。Java 采用的是异常表,这种技术会稍微增加可执行程序的规模,但对程序的正常执行没有性能损耗。第 5 章将讨论 Java 异常处理的实现技术。

堆存储子系统负责管理 Java 的对象堆。堆存储子系统要完成三方面的任务:第一,堆存储子系统必须高效地管理内存,并提供最底层内存分配的高效接口;第二,堆存储管理要为所有堆分配的对象选择合理高效的对象数据结构编码,在高效支持对象操作的同时,尽量减少对象分配造成的额外空间开销;第三,Java 没有显式的内存回收,堆存储子系统必须能够高效地进行自动垃圾收集。第 6 章将详细讨论堆存储子系统的设计与实现。

多线程是 Java 程序设计的重要组成部分,Java 多线程的实现中包括对 Thread 线程库的支持、对管程的实现等。同时,多线程的引入,使得虚拟机其他模块的实现都更加复杂了,必须仔细地引入锁和同步机制。第 7 章将讨论多线程的实现。

一个生产级的 Java 虚拟机离不开周边配套系统的支持,如性能剖面工具、监控工具、调试工具等。第 8 章将讨论 Java 调试器的设计和实现,并给出对 Oracle 发布的 JDB 的分析。

综上所述,尽管 Java 虚拟机是个比较复杂的软件系统,但通过把整个虚拟机分解成若干子系统并设计、划分合理清晰的接口,便可以更模块化地理解和实现整个虚拟机。

## 1.3 实例: J 语言及其编译

本节将介绍一种高级语言 J 语言(计算器语言)和一个栈式计算机 J 虚拟机,并研究将 J 语言编译为 J 虚拟机的字节码的技术。下一小节将讨论 J 虚拟机加载 J 字节码文件并解释执行的基本技术。

尽管高级语言 J 语言和目标机器 J 虚拟机都很简单,但这部分内容能够很好地阐释高级语言编译并在栈式计算机上运行的整个流程,从而为读者建立解释型语言在虚拟机上运行的过程模型,也为本书后续章节研究高级语言(Java)在其虚拟机(JVM)上解释执行的过程奠定基础。读者会看到,尽管语言和虚拟机都变得更为复杂了,但高级语言编译、栈式计算机、字节码文件加载、解释执行引擎等概念是一致的。

### 1.3.1 J 语言语法

J 语言是一个简单的计算器型的语言,它只能完成整型数的四则运算,但是,并不难通过添加循环和跳转等更多的语言机制让它变成图灵完备的。

J 语言的语法规则由以下的上下文无关文法给出:

```
s -> x = e | print(e) | s; s  
e -> n | x | e+e | e-e | e*e | e/e
```

J 语言的程序由语句 s 构成,语句 s 一共有三种可能的语法形式:赋值语句“x=e”将等号右侧表达式 e 的值,赋值给等号左侧的变量 x;打印语句“print(e)”将表达式 e 的值打印到屏幕上,后面有一个换行指令;序列语句“s;s”由前后两个语句构成。

表达式 e 共有六种不同的语法形式:无符号整型常数 n、整型变量 x,以及整型表达式上的加(e+e)、减(e-e)、乘(e\*e)、除(e/e)四则运算。

J 语言的一个示例程序如下:

```
x = 4;  
y = 5;  
z = x + y;
```

```
print(z)
```

该程序运行时在屏幕上打印整型数 9，后跟换行。

对 J 语言程序的操作要通过抽象语法树进行。下面是 J 语言抽象语法树的 C 语言实现，首先给出语句部分的代码实现：

```
1 enum Stmt_Kind_t{
2     STM_ASSIGN,
3     STM_PRINT,
4     STM_SEQ
5 };
6
7 // common definition
8 struct Stmt_t{
9     enum Stmt_Kind_t kind;
10 };
11
12 // assign
13 struct Stmt_Assign{
14     enum Stmt_Kind_t kind;
15     char *x;
16     struct Exp_t *exp;
17 };
18
19 struct Stmt_t *Stmt_Assign_new(char *x, struct Exp_t *exp){
20     struct Stmt_Assign *p = malloc(sizeof(*p));
21     p->kind = STM_ASSIGN;
22     p->x = x;
23     p->exp = exp;
24     return (struct Stmt_t *)p;
25 }
26
27 // print
28 struct Stmt_Print{
29     enum Stmt_Kind_t kind;
```

```
30     struct Exp_t *exp;
31     };
32
33     struct Stm_t *Stm_Print_new(struct Exp_t *exp){
34         struct Stm_Print *p = malloc(sizeof(*p));
35         p->kind = STM_PRINT;
36         p->exp = exp;
37         return (struct Stm_t *)p;
38     }
39
40     // seq
41     struct Stm_Seq{
42         enum Stm_Kind_t kind;
43         struct Stm_t *s1;
44         struct Stm_t *s2;
45     };
46
47     struct Stm *Stm_Seq_new(struct Stm_t *s1, struct Stm_t *s2){
48         struct Stm_Seq *p = malloc(sizeof(*p));
49         p->kind = STM_SEQ;
50         p->s1 = s1;
51         p->s2 = s2;
52         return (struct Stm_t *)p;
53     }
```

接下来给出表达式部分的实现:

```
1 enum Exp_Kind_t{
2     EXP_NUM ,
3     EXP_VAR ,
4     EXP_ADD ,
5     EXP_SUB ,
6     EXP_TIMES ,
7     EXP_DIV
```

```
8 };
9
10 // common definition
11 struct Exp_t{
12     enum Exp_Kind_t kind;
13 };
14
15 // number
16 struct Exp_Num{
17     enum Exp_Kind_t kind;
18     int n;
19 };
20
21 struct Exp_t *Exp_Num_new(int n){
22     struct Exp_Num *p = malloc(sizeof(*p));
23     p->kind = EXP_NUM;
24     p->n = n;
25     return (struct Exp_t *)p;
26 }
27
28 // var
29 struct Exp_Var{
30     enum Exp_Kind_t kind;
31     char *x;
32 };
33
34 struct Exp_t *Exp_Var_new(char *x){
35     struct Exp_Var *p = malloc(sizeof(*p));
36     p->kind = EXP_VAR;
37     p->x = x;
38     return (struct Exp_t *)p;
39 }
40
```

```
41 // add
42 struct Exp_Add{
43     enum Exp_Kind_t kind;
44     struct Exp_t *left;
45     struct Exp_t *right;
46 };
47
48 struct Exp_t *Exp_Add_new(struct Exp_t *left, struct Exp_t *right
49     ){
50     struct Exp_Add *p = malloc(sizeof(*p));
51     p->kind = EXP_ADD;
52     p->left = left;
53     p->right = right;
54     return (struct Exp_t *)p;
55 }
56
57 // sub
58 struct Exp_Sub{
59     enum Exp_Kind_t kind;
60     struct Exp_t *left;
61     struct Exp_t *right;
62 };
63
64 struct Exp_t *Exp_Sub_new(struct Exp_t *left, struct Exp_t *right
65     ){
66     struct Exp_Add *p = malloc(sizeof(*p));
67     p->kind = EXP_SUB;
68     p->left = left;
69     p->right = right;
70     return (struct Exp_t *)p;
71 }
72
73 // times
```

```

72 struct Exp_Times{
73     enum Exp_Kind_t kind;
74     struct Exp_t *left;
75     struct Exp_t *right;
76 };
77
78 struct Exp_t *Exp_Times_new(struct Exp_t *left, struct Exp_t *
79                             right){
80     struct Exp_Add *p = malloc(sizeof(*p));
81     p->kind = EXP_TIMES;
82     p->left = left;
83     p->right = right;
84     return (struct Exp_t *)p;
85 }
86
87 // div
88 struct Exp_Div{
89     enum Exp_Kind_t kind;
90     struct Exp_t *left;
91     struct Exp_t *right;
92 };
93
94 struct Exp_t *Exp_Div_new(struct Exp_t *left, struct Exp_t *right
95                           ){
96     struct Exp_Add *p = malloc(sizeof(*p));
97     p->kind = EXP_DIV;
98     p->left = left;
99     p->right = right;
100    return (struct Exp_t *)p;
101 }

```

给定以上的语法树定义，就可以对具体的程序进行编码了。例如，对语法树前面给出的示例程序，可将其编码为下面的 C 表达式：

```
1 struct Stmt_t*s = Stmt_Seq_new(Stmt_Assign_new("x", Exp_Num_new(4)),
2     Stmt_Seq_new(Stmt_Assign_new("y", Exp_Num_new(5)),
3         Stmt_Seq_new(Stmt_Assign_new("z",Exp_Add_new(Exp_Var_new("x"),
            Exp_Var_new("y")))),Stmt_Print_new(Exp_Var_new('z')));
```

### 1.3.2 栈式计算机

J语言程序执行的目标机器是一个假想的栈式计算机,可称为J虚拟机。该机器由三部分组成:执行单元CPU、变量存储区store和操作数栈ostack,体系结构如下(真实的栈式计算机结构与此类似):

store:

```
-----  
| x | y | z | ... |  
-----
```

ostack:

```
-----  
| CPU |  
-----  
| | |  
-----
```

八

| top

变量存储区store负责存放程序中出现的所有变量(如上一小节中J语言示例程序中的变量x、y和z),变量存储区store以从0开始的整型下标作为索引,每个元素都占用4字节。

操作数栈ostack,顾名思义,负责存放运算过程中涉及的临时操作数以及运算的结果。例如,在进行加法运算前,被加数和加数分别被压到栈顶下面一个位置和栈顶上,执行完加法后,两个操作数都从栈中被弹出,计算结果(即二者的和)被压入栈顶。和变量存储区store一样,操作数栈ostack的每个元素也是4字节的。操作数栈ostack有一个栈顶指针top,总是指向栈中下一个可以存放元素的位置。

执行单元CPU完成数据的四则运算,同时也负责完成数据在变量存储区store和操作数栈ostack之间的双向移动。需要注意的是,CPU中并不含任何寄存器,所有参与运算的操作数都在操作数栈ostack中。本小节先假定变量存储区store和

操作数栈 `ostack` 都是无限长度的。

栈式 J 虚拟机的指令集包括 8 条指令, 指令 `instr` 的助记符形式如下:

```
instr -> ldc n      // push constant n onto stack
          | iload i  // load i-th variable onto the stack
          | istore i // pop the stack, and save to i-th store
          | iadd
          | isub
          | imul
          | idiv
          | invoke-print
```

指令 `ldc` 后跟了一个操作数 `n`, `n` 是一个无符号整型常量。该指令会把整型常量 `n` 压到操作数栈 `ostack` 的栈顶上, 其执行前后操作数栈 `ostack` 的状态变化是:

before: after:

```
-----      -----
....|      ....| n |
-----      -----
```

八 八  
| top | top

指令 `iload` 后是一个整型操作数 `i`, `i` 是变量存储区 `store` 的下标。该指令会把变量存储区 `store` 中第 `i` 个槽位上的整型值 `store[i]` 压入操作数栈 `ostack` 的栈顶, 指令执行前后操作数栈 `ostack` 的状态变化是:

before: after:

```
-----      -----
....|      ....| store[i] |
-----      -----
```

八 八  
| top | top

指令 `istore` 完成的操作和 `iload` 正好相反: 它把操作数栈 `ostack` 的栈顶整型元素弹出, 并把弹出的整型值存放到变量存储区 `store` 的第 `i` 个下标中。这里把指令执行前后操作数栈 `ostack` 的变化过程留给读者作为练习自行画出。

指令 `iadd` 完成整型变量的加法, 注意该指令并没有携带任何操作数, 操作数都位于操作数栈 `ostack` 的栈顶上。该指令执行前后, 操作数栈 `ostack` 的变化过程是:

|                |                  |
|----------------|------------------|
| before:        | after:           |
| -----          | -----            |
| ...   m   n    | ...   m+n        |
| -----          | -----            |
| ^            ^ | top          top |

位于操作数栈 `ostack` 栈顶的加数 `n`, 和位于栈顶下一个位置的被加数 `m` 都被从栈 `ostack` 中弹出, 由 CPU 完成加法运算后, 结果 `m+n` 被压入操作数栈顶; 加法完成后, 操作数栈的元素个数减少了 1(请读者特别留意被加数 `m` 和加数 `n` 在操作数栈 `ostack` 上的相对位置)。其他三条算术指令 `isub`、`imul` 和 `idiv` 的实现与此类似, 这里把操作数栈 `ostack` 的变化过程, 留给读者作为练习自行画出。

最后一条指令是打印指令 `invoke-print`, 该指令执行前后, 操作数栈 `ostack` 的状态变化是:

|                |                  |
|----------------|------------------|
| before:        | after:           |
| -----          | -----            |
| ...   n        | ...              |
| -----          | -----            |
| ^            ^ | top          top |

操作数栈 `ostack` 栈顶的元素 `n` 被弹出, 并输出在屏幕上, 后跟换行。实际上, 该指令并未规定虚拟机具体该如何实现输出的功能。现实中虚拟机可以选择用任何合理的方式来实现输出: 通过运行时系统来实现输出, 或者可以直接通过操作系统的系统调用实现输出, 等等。

和 J 语言的语法树构造类似, 我们也可以给 J 虚拟机的指令进行编码, 具体 C 语言实现如下:

```
1 enum Instr_Kind_t{
2     INSTR_LDC,
```

```
3   INSTR_ILOAD ,
4   INSTR_ISTORE ,
5   INSTR_IADD ,
6   // others are similar
7   };
8
9   struct Instr_t{
10  enum Instr_Kind_t kind;
11  };
12
13  // ldc
14  struct Instr_Ldc{
15  enum Instr_Kind_t kind;
16  int n;
17  };
18
19  struct Instr_t *Instr_Ldc_new(int n){
20  struct Instr_Ldc *p = malloc(sizeof(*p));
21  p->kind = INSTR_LDC;
22  p->n = n;
23  return (struct Instr_t *)p;
24  };
25
26  // iload
27  struct Instr_Iload{
28  enum Instr_Kind_t kind;
29  int i;
30  };
31
32  struct Instr_t *Instr_Iload_new(int i){
33  struct Instr_Iload *p = malloc(sizeof(*p));
34  p->kind = INSTR_ILOAD;
35  p->i = i;
```

```
36     return (struct Instr_t *)p;
37 };
38
39 // istore
40 struct Instr_Istore{
41     enum Instr_Kind_t kind;
42     int i;
43 };
44
45 struct Instr_t *Instr_Istore_new(int i){
46     struct Instr_Istore *p = malloc(sizeof(*p));
47     p->kind = INSTR_ISTORE;
48     p->i = i;
49     return (struct Instr_t *)p;
50 };
51
52 // iadd
53 struct Instr_Iadd{
54     enum Instr_Kind_t kind;
55 };
56
57 struct Instr_t *Instr_Iadd_new(){
58     struct Instr_Iadd *p = malloc(sizeof(*p));
59     p->kind = INSTR_IADD;
60     return (struct Instr_t *)p;
61 };
```

这里略去了对 isub、imul、idiv 和 invoke-print 的编码实现，它们的实现和 iadd 指令类似，读者可尝试自行完成。

### 1.3.3 J 字节码

计算机可以直接识别并执行二进制形式的程序代码，因此需要为上述助记符形式的 J 虚拟机指令集进行编码。这里采用以下编码方案。

1) 每条指令的操作码部分用单字节编码。

2) 如果指令后还跟有操作数, 该操作数直接 (按大端法) 编码在操作码后面。

不难看出, 按这种编码方案得到的指令编码是变长的, 有的指令只有 1 个字节, 即操作码, 有的指令有 5 个字节, 除了 1 字节的操作码外, 还有 4 字节的操作数。

对指令操作码 (单字节) 的编码规则见表 1-1。

表 1-1 操作码的编码规则

| 操作码    | 编码   | 操作码          | 编码   |
|--------|------|--------------|------|
| ldc    | 0x12 | isub         | 0x64 |
| istore | 0x36 | imul         | 0x68 |
| iload  | 0x15 | idiv         | 0x6c |
| iadd   | 0x60 | invoke-print | 0xfd |

按上述指令编码规则可以把 J 虚拟机上以助记符形式表示的指令翻译成二进制形式的指令。例如, 以下 J 虚拟机汇编程序:

```
ldc 4
ldc 5
iadd
```

可被翻译成如下的二进制文件 (按 16 进制表示; 请读者特别注意其中的整型常数是按大端法存储的):

```
\x12\x00\x00\x00\x04
\x12\x00\x00\x00\x05
\x60
```

把助记符形式的指令翻译成二进制形式指令的过程称为汇编。尽管汇编是程序运行过程中非常重要的一个阶段, 但从概念上讲, 这个过程基本上是指令的助记符和指令二进制编码间双向一对一映射的过程, 并不复杂。

还有两个关键点: 第一, 上述指令集编码统一用 1 个字节编码指令的操作码部分, 因此, 这种指令编码称为字节码指令, 为 J 虚拟机设计的这种字节码可简称为 J 字节码。Java 字节码的二进制指令也使用了类似的编码方式, 因此被称为 Java 字节码。这种编码方式的主要优点是操作码都是定长的, 方便了指令的解码, 并且由于大部分操作数都在操作数栈 ostack 中而不是存储在指令中, 所以很大程度上

缩短了指令编码的长度,方便指令的传输(见1.1节讨论的Java设计的背景)。当然,这种字节码编码方式也有缺点,其主要缺点是限制可用指令的条数为最多256条,但从实际应用来看,这并不是一个大问题,Java字节码已经出现了二十多年,也只用到了256条可能指令的205条,还剩余51条保留指令未使用。

第二个关键点,读者可能已经注意到,表1-1中给出的J字节码指令编码似乎是随机的,这是因为J虚拟机指令集中的8条指令(除最后一条外)刻意选取了和Java字节码指令集相同的助记符和操作码编码,例如,Java字节码中也包含iadd指令,并且该指令的编码同样是0x60。唯一的例外是J虚拟机的最后一条字节码invoke-print,由于Java字节码中并不存在这条指令,所以它选取了0xfd这个编码,这是Java字节码中尚未使用的编码。从这里可以看出,J字节码指令基本上是Java字节码指令的一个子集,读者可参考《Java虚拟机规范》中的指令集部分做进一步对比。

### 1.3.4 J 语言编译到 J 字节码

J语言的程序需要编译为J字节码,编译的过程采用了一个典型的递归下降算法。

由于J程序中出现的变量采用了变量名的形式,而J字节码中的变量采用的是下标形式,因此,在编译的过程中需要把变量名转换成下标。此处使用一个符号表的数据结构来把变量名映射为下标,该模块的实现如下:

```
1 #define MAX_IDS 1000
2
3 struct{
4     char *arr[MAX_IDS];
5     int next;
6 }map;
7
8 int Map_lookup(char *name){
9     for(int i=0; i<map.next; i++){
10         if(strcmp(name, map.arr[i])==0)
11             return i;
12     }
13     return -1;
```

```

14 }
15
16 int Map_tryInsert(char *name){
17     for(int i=0; i<map.next; i++){
18         if(strcmp(name, map.arr[i])==0)
19             return i;
20     }
21     map.arr[map.next] = name;
22     return map.next++;
23 }

```

这里并不关注模块的性能，因此使用了一个线性数组 arr 来实现该符号表。符号表中存储了程序中所有出现的变量名，给每个变量名分配的下标默认就是其在数组中的下标。在实际使用时，如果关注性能，则需要用哈希等其他更高效的数据结构来实现符号表。

函数 Map\_lookup() 用于在符号表中查找某个名为 name 的变量，并返回其下标；如果该变量未找到，则返回 -1。

函数 Map\_tryInsert() 尝试向符号表中插入变量 name，如果该变量已经存在，则返回其现有的数组下标，否则，将变量 name 追加到数组的末尾，并返回其下标。

为 J 语言程序生成 J 字节码的算法如下：

```

1 void compileStm(struct Stm_t *s){
2     switch(s->kind){
3     case STM_ASSIGN:
4         int index = Map_tryInsert(s->x);
5         compileExp(s->exp);
6         emit "istore index"
7         break;
8     case STM_PRINT:
9         compileExp(s->exp);
10        emit "invoke-print"
11        break;
12    case STM_SEQ:
13        compileStm(s->s1);

```

```
14         compileStm(s->s2);
15         break;
16     }
17 }
18
19 void compileExp(struct Exp_t *e){
20     switch(e->kind){
21     case EXP_NUM:
22         emit "ldc e->n";
23         break;
24     case EXP_VAR:
25         int index = Map_lookup(e->x);
26         emit "iload index";
27         break;
28     case EXP_ADD:
29         compileExp(e->left);
30         compileExp(e->right);
31         emit "iadd";
32         break;
33     case EXP_SUB:
34         compileExp(e->left);
35         compileExp(e->right);
36         emit "isub";
37         break;
38     case EXP_TIMES:
39         compileExp(e->left);
40         compileExp(e->right);
41         emit "imul";
42         break;
43     case EXP_DIV:
44         compileExp(e->left);
45         compileExp(e->right);
46         emit "idiv";
```

```

47     break;
48 }
49 }
```

注意,为了让代码更加清晰,上述代码中省略了部分所需的强制类型转换,并且略去了代码发射函数 emit() 的实现。本质上,emit() 函数生成的目标字节码将存储在某个数据结构中,以供后续阶段使用。

1.3.1 小节开头讨论的 J 语言示例程序经过编译后,得到如下助记符形式的 J 字节码程序(具体过程留给读者作为练习):

```

ldc 4
istore 0
ldc 5
istore 1
iload 0
iload 1
iadd
istore 2
iload 2
invoke-print
```

上述代码经过汇编后,得到了二进制形式的 J 字节码文件,内容如下:

```

\x12\x00\x00\x00\x04
\x36\x00\x00\x00\x00
\x12\x00\x00\x00\x05
\x36\x00\x00\x00\x01
\x15\x00\x00\x00\x00
\x15\x00\x00\x00\x01
\x60
\x36\x00\x00\x00\x02
\x15\x00\x00\x00\x02
\xfd
```

## 1.4 实例: J 虚拟机

将 J 语言的源程序编译得到 J 字节码程序后, 还需要实现一个 J 虚拟机, 用以解释执行 J 字节码程序。本节将讨论 J 虚拟机的实现。

从整体执行顺序上看, J 虚拟机需要先把 J 字节码文件读入其中, 并构造适当的数据结构存储被读入的程序, 为后续程序的执行做好准备, 这个过程称为加载。

在执行前, J 虚拟机还必须确保正在加载的类文件是正确的 (甚至首先要保证该文件确实是 J 字节码文件), 因此 J 虚拟机会对字节码文件进行各种校验和检查, 这个过程称为字节码验证, 或者简称为验证。只有通过验证的程序才能进入后续的执行阶段, 验证失败的程序直接被虚拟机拒绝执行。

通过字节码验证的程序将交给执行引擎执行, 并得到执行结果。

在实际的虚拟机中, 各个阶段的划分并不是一成不变的, 例如, 在 Java 虚拟机中, 类验证阶段实际上是类加载阶段的一个子阶段。接下来的三个小节会分别讨论类加载、类验证和执行引擎。

### 1.4.1 字节码加载子系统

由于 J 字节码程序相对简单, 加载的过程可以分成两个步骤完成: 第一个步骤是装载 (load), 即虚拟机把 J 字节码文件从磁盘读入内存; 第二个步骤是构造合理的数据结构来表示读入的程序。下面直接使用二进制文件的内存映射作为 J 字节码程序数据结构, 这种表示方法尽管比较简单, 但对于 J 字节码来说足够了。

基于以上设计, J 字节码的加载过程如下:

```
1 char *loadByteCodeFile(char *fileName){
2     int fd = open(fileName, O_RDWR);
3     int len = lseek(fd, 0, SEEK_END);
4     char *addr = mmap(0, len, PROT_READ, MAP_PRIVATE, fd, 0);
5     close(fd);
6     return addr;
7 }
```

其中, J 字节码加载函数 loadByteCodeFile() 将字节码文件映射到内存中, 并返回指向该内存区域首地址的指针。

Java 虚拟机中的类加载过程更加复杂: 第一, Java 虚拟机所加载的 Java 字节码文件的格式相比 J 字节码更加复杂, 不仅包括字节码指令, 还包括常量池、异常表等其他数据结构, 因此, Java 虚拟机需要构造更复杂的抽象语法树和其他辅助数据结构来表示加载进来的类; 第二, 由于 Java 类之间存在继承关系及接口的实现关系, 在 Java 字节码类文件加载的过程中, 会把被加载类的父类及该类实现的所有接口都加载进来。换句话说, 加载过程是递归的。第 2 章会深入讨论 Java 字节码的类加载。尽管 Java 虚拟机中的类加载子系统比本节所讨论的 J 虚拟机的字节码加载子系统更加复杂, 但基本原理是相同的。

### 1.4.2 字节码验证器

第二个步骤是 J 字节码验证 (verification)。J 虚拟机读入的 J 字节码文件有可能是非法的, 非法性产生的原因可能是多方面的: 首先, 该字节码文件未必是编译器自动生成的, 而可能是程序员直接手工构造的, 因此, 其中难免存在编程错误; 其次, 即便该字节码文件是由编译器生成的, 但由于编译器可能存在缺陷, 导致编译生成的字节码文件包含错误; 最后, 即便初始生成的 J 字节码文件是完全正确的, 但在存储和传输的过程中可能被有意或无意地修改过, 导致文件出错; 等等。

包含错误的 J 字节码程序会影响 J 虚拟机的执行, 例如 J 字节码的二进制内容 “\x60”, 它只包含一条加法指令 iadd, 在执行过程中, 虚拟机会因为找不到该指令的操作数而出错。当然, 虚拟机完全可以选择在运行期间动态完成这类合法性验证, 但这种做法会影响程序的执行效率, 因此, 虚拟机一般需要在字节码程序加载完成之后、执行之前, 进行字节码的合法性静态验证, 以尽可能排除非法程序。

对 J 字节码这类底层代码进行类型等合法性验证时, 基本的技术方案有两个: 一是进行类型检查, 二是进行类型推导。2.5 节将讨论针对 Java 字节码的类型推导算法。由于 J 字节码是 Java 字节码的一个子集, 因此, 该算法同样也适用于 J 字节码。下面给出对 J 字节码进行验证的算法, 该算法基于类型推导。首先分别对 J 机器模型中的局部变量存储区 store 和操作数栈 ostack 给定两个符号表:

$$\Gamma : \text{store} \to \text{int} \mid \text{Unknown}, \quad \Sigma : \text{ostack} \to \text{int}$$

其中, 第一个符号表  $\Gamma$  把存储区 store 中的每一个变量都映射到整型类型 int 或者一个特殊的不确定类型 Unknown。就 J 字节码而言, 只有一种可能会让 store 中的某个元素类型是不确定类型 Unknown, 即该元素从来未被赋值过 (在高级语言中, 这

类错误经常被称为“变量未初始化错误”)。第二个符号表 $\Sigma$ 把操作数栈`ostack`中的每个元素都映射到一个整型`int`, 该符号表被组织成一个类型栈。本质上, 这两个符号表是用来跟踪程序中的变量类型的。

有了符号表 $\Gamma$ 和 $\Sigma$ , J字节码验证器的工作流程是: 首先进行初始化, 将符号表 $\Gamma$ 中的所有元素都初始化为不确定类型`Unknown`, 将符号表类型栈 $\Sigma$ 清空; 然后, 从首行开始逐条扫描J字节码指令, 并根据不同的指令类型进行不同的操作。

- 对于`ldc n`指令, J字节码验证器直接向符号表类型栈 $\Sigma$ 中压入一个整型类型`int`, 即 $\Sigma(\text{top}++) = \text{int}$ 。

- 对于`istore i`指令, 验证器将存储类型符号表 $\Gamma$ 对应下标`i`的元素类型改为整型`int`, 即 $\Gamma(i) = \text{int}$ 。

- 对于`iload i`指令, 验证器首先检查存储类型符号表 $\Gamma$ 中对应下标`i`的类型 $\Gamma(i)$ 是否为整型`int`。若是, 验证器将整型`int`压入定型环境 $\Sigma$ 中, 即 $\Sigma(\text{top}++) = \text{int}$ ; 否则, 验证失败。

- 对于整型运算的`iadd`、`isub`、`imul`和`idiv`四条指令, J字节码验证器检查确认栈符号表 $\Sigma$ 中至少包括两个栈元素, 且都是整型类型, 即 $\Sigma(\text{top}-2) == \text{int}$ 并且 $\Sigma(\text{top}-1) == \text{int}$ 。若条件成立, 则验证器从 $\Sigma$ 中弹出一个整型; 若条件不成立, 则验证失败。

- 对于打印指令`invoke-print`, J字节码验证器检查确认栈符号表 $\Sigma$ 中至少包括一个整型元素。若条件成立, 则验证器从符号表 $\Sigma$ 中弹出一个整型类型, 否则, 验证失败。

如果扫描完所有指令且没有任何错误, 则字节码程序验证通过。下面是J字节码验证的算法:

```
1 enum Type_t{
2     TYPE_UNKNOWN = 0,
3     TYPE_INT
4 };
5
6 enum Type_t types4Store[MAX_IDS];
7
8 #define MAX_STACK 1024
9
```

```
10 struct{
11     enum Type_t arr[MAX_IDS];
12     int top;
13 }types4Stack;
14
15 void verify(struct Instr_t *instr){
16     switch(instr->kind){
17     case "ldc  n":
18         types4Stack.arr[types4Stack.top++] = TYPE_INT;
19         break;
20     case "istore  i":
21         types4Store[i] = TYPE_INT;
22         break;
23     case "iload  i":
24         if(types4Store[i] != TYPE_INT)
25             error("verify  failed,  integer  type  required");
26         break;
27     case "iadd":
28     case "isub":
29     case "imul":
30     case "idiv":
31         if(types4Stack.top < 2)
32             error("verify  failed,  two  integer  operands  "
33                    "required");
34         if(types4Stack.arr[types4Stack.top-2] != TYPE_INT ||
35             types4Stack.arr[types4Stack.top-1] != TYPE_INT)
36             error("verify  failed,  integer  type  required");
37         types4Stack.top--;
38         break;
39     case "invoke_print":
40         if(types4Stack.top < 1)
41             error("verify  failed,  one  integer  operand  "
42                    "required");
```

```
40 if(types4Stack.arr[types4Stack.top-1] != TYPE_INT)
41     error("verify  failed,  integer  type  required");
42 types4Stack.top--;
43 break;
44 }
45 }
```

上述算法用枚举的方式依次完成了对 J 字节码指令的验证,为了便于理解,其中的 J 字节码指令用字符串的形式表示,在实际实现时,要用第 1.3.2 小节给出的数据结构表示。

第 2 章将详细讨论对 Java 字节码的验证。从概念上说,Java 字节码的验证算法和上述算法非常类似,只是要处理的指令形式更多,而且还要处理子类型、控制流和异常处理等更复杂的情况。

### 1.4.3 解释执行引擎

J 字节码程序加载完毕并通过验证后,J 虚拟机就可以启动解释执行引擎子系统,对 J 字节码进行解释执行。传统的程序执行一般采用本地执行的方式,即编译器把高级语言写的源代码编译成某种目标机器上的本地机器代码,然后交由目标机器执行。而解释执行有很大不同,程序一般会被编译成某种中间抽象代码(甚至不经过编译,直接操作程序的源代码),然后写专门的解释器,对抽象代码进行解释并输出结果。从这个意义上说,解释器就是一个面向这种抽象代码的专用 CPU。

要实现 J 虚拟机的执行引擎子系统,首先要设计和实现必要的执行环境。J 虚拟机包括存储区 store、操作数栈 ostack 等,大家可以用如下的数据结构实现它们:

```
1 int store[N_STORE];
2
3 struct{
4     int arr[MAX_STACK];
5     int top;
6 }ostack;
```

这些数据结构是对 J 机器结构的自然模拟。

J 虚拟机解释执行引擎的执行过程是一个循环:不断从 J 字节码文件中读取 J 字节码指令并逐条解释执行,直到指令解释完毕为止。解释执行引擎的核心算法

由如下的 interp() 函数给出:

```

1 void interp(){
2     while(instr = decodeNextInstruction()){
3         switch(instr){
4             case "ldc \n n":
5                 ostack.arr[ostack.top++] = n;
6                 break;
7             case "istore \n i":
8                 store[i] = ostack.arr[--ostack.top];
9                 break;
10            case "iload \n i":
11                ostack.arr[ostack.top++] = store[i];
12                break;
13            case "iadd":
14                ostack.arr[ostack.top-2] = ostack.arr[ostack.top-2] +
15                    ostack.arr[ostack.top-1];
16                ostack.top--;
17                break;
18            case "invoke-print":
19                printf("%d\n", ostack.arr[--ostack.top]);
20                break;
21        }
22    }

```

以上算法中的 decodeNextInstruction() 函数从 J 字节码的二进制流中解码出下一条待执行的指令 instr, 并根据指令 instr 的不同情况执行不同的解释逻辑。当所有的指令读取完毕后, 退出 while 循环, 解释执行引擎运行结束。解释执行引擎的算法并不复杂, 不再赘述。读者可自行补充其他三条算术指令 isub、imul 和 idiv 的解释逻辑 (特别注意 idiv 指令中除数为 0 时的情况)。读者也可以对 1.3.4 小节中给出的 J 字节码程序示例给出解释执行引擎的执行过程。

Java 虚拟机的解释执行引擎和上述 J 虚拟机的解释执行引擎原理相似, 但要复杂不少: 第一, Java 虚拟机需要解释的指令种类更多 (Java 虚拟机需要解释执行

205 条指令, 而 J 虚拟机中只有 8 条); 第二, 在 Java 虚拟机中, 部分指令的实现逻辑更加复杂。

总结一下, 本节结合高级语言 J 语言以及 J 栈式虚拟机, 详细讨论了 J 语言的编译、栈式计算机设计、J 字节码格式, 还讨论了 J 虚拟机执行一个类文件的完整过程, 包括类加载、字节码验证、解释执行。在 Java 虚拟机中, 除了这些模块外, 还涉及其他几个重要子系统: 堆管理子系统、线程管理、本地方法接口等。本书接下来的章节会详细讨论 Java 虚拟机的所有相关子系统的设计原理和实现技术。

# 第 2 章 类加载器

Java 虚拟机中的类加载器子系统负责把 Java 字节码文件加载到 Java 虚拟机中, 将 Java 类文件转换为 Java 虚拟机内部对类的数据结构表示, 并对类进行验证、准备、解析和初始化等工作, 为执行类中的代码做好准备。本章讨论类加载的主要过程和所用到的主要理论和实现技术。从概念上讲, 类加载可以分成几个阶段: 首先是类的装载, 该阶段负责读取 Java 字节码程序的二进制类文件, 对类文件格式进行解析并进行语法分析, 编译成类的虚拟机内部数据结构表示, 其大量使用了编译器语法分析相关的技术; 接下来是类的验证阶段, 该阶段基于严格的语义验证规则, 对 Java 类的合法性进行校验, 如果类的验证不能通过, 虚拟机将直接拒绝执行该类; 之后, 通过验证的类会进入准备阶段, 该阶段要完成的主要工作是对类中的字段和方法分别按合理的方式进行组织和存储, 为类的静态字段分配空间并赋予默认值, 给每个类的非静态字段计算占用的总空间 (亦即该类所产生的对象将占用的空间), 并计算每个非静态字段的偏移量; 类的解析阶段会解析类的常量池, 把常量池中相应的符号表项解析成对相应实体的引用; 最后, 类的初始化阶段完成对类的初始化方法的调用。本章中将分别详细讨论每个阶段的实现技术。

## 2.1 实例: Java 的类加载

Java 程序的执行过程看起来并不复杂, 例如下面这个最简单的 Java 程序实例:

```
1 // Main.java
2 class Main{
3     public static void main(String[] args){
4         System.out.println("hello, □ world");
5     }
6 }
```

当这个实例被编译完成时,会生成字节码文件 Main.class,用标准的 java 命令就可以完成对该字节码文件 Main.class 的加载和执行:

```
$ java Main
```

那么,在这个命令执行的背后,虚拟机到底完成了哪些动作?本章要讨论的就是这些动作中的第一个:类的加载。简单来讲,类加载就是把 Main.class 类加载到虚拟机中,即从磁盘复制到虚拟机内存中,形成合理的数据结构。但其实类加载的过程比文件复制复杂,要考虑的问题比较多,例如:

- 1) 类 Main 还引用了字符串类 String、系统类 System 等,因此,这些类也要加载。
- 2) 类 Main 继承自 Object 类,因此还需要完成对 Object 类的加载。
- 3) String 类、System 类或 Object 类中还可能引用了其他类,虚拟机需要对这些被引用的类进行加载。
- 4) 类 Main 被加载后在虚拟机内部本身也是对象,即所谓的类对象,因此 Java 虚拟机需要对该类对象的类 Class 也进行加载。
- 5) 类还可能实现接口,例如上述程序中的 String 类实现了 Serializable、CharSequence 和 Comparable 三个接口,虚拟机也要对这些接口进行加载(在实际的虚拟机中,通常要加载数百个类或者接口)。
- 6) 还有一些类不存在具体的字节码文件类的实体,如上述程序中的字符串数组类 String[],因此,需要 Java 虚拟机直接“无中生有”地构造(而不是加载)类的表示。
- 7) 这些类(除了类 Main)都是系统类,为了保证安全性,Java 虚拟机只允许加载系统自带的默认类,而不能加载用户自定义的类。
- 8) 被加载的类未必是合法的,还需要对类的合法性进行验证。
- 9) 类中还可能存在静态字段以及静态代码块,所以需要在类加载结束前执行类的初始化方法 <clinit>(),等等。

上述问题只是加载过程中需解决问题的一个不完整列表,在实际的 Java 虚拟机中,加载过程的实现需要考虑上述所有问题。

以上类的加载也称为系统类加载,尽管系统类的加载过程非常复杂,但由于这个过程基本是由 Java 虚拟机自动完成的,所以对用户来说是感受不到的。但如果需要,Java 也允许用户手动显式调用虚拟机的类加载器。例如,下面的例子会调

用系统类加载器(严格来说是加载类 Main 的类加载器)，完成对类 Foo 的加载，加载进来的 Foo 对象被引用 c 指向：

```
1 class Main{
2     public static void main(String[] args){
3         System.out.println("hello, world");
4         Class c = Class.forName("Foo");
5     }
6 }
```

除系统类加载器外，Java 还支持用户自定义的类加载器。另外，Java 虚拟机还支持对基本类的加载，这些都是在本章中要详细讨论的内容。

## 2.2 类的二进制定义

要实现 Java 的类加载器，首先要理解 Java 类文件(即.class 文件)的定义。《Java 虚拟机规范》(以下简称《规范》)严格定义了 Java 字节码文件的二进制格式，并由以下 ClassFile 结构体给出：

```
1 ClassFile{
2     u4 magic;
3     u2 minor_version;
4     u2 major_version;
5     u2 constant_pool_count;
6     cp_info constant_pool[constant_pool_count - 1];
7     u2 access_flags;
8     u2 this_class;
9     u2 super_class;
10    u2 interfaces_count;
11    u2 interfaces[interface_count];
12    u2 fields_count;
13    field_info fields[fields_count];
14    u2 methods_count;
15    method_info methods[methods_count];
16    u2 attributes_count;
```

```
17     attributes_info attributes[attributes_count];  
18 }
```

Java 字节码文件的格式是“平坦”的，不存在递归结构，因此其二进制格式并不复杂。严格来说，这个二进制文件格式定义的可能是类或接口，本章剩余部分以类来进行讲解，接口的处理与之相同。在上面给出的定义中使用了一些类型，其中 u4、u2 等分别代表 4 字节和 2 字节的无符号整型数，即：

```
1 typedef unsigned char u1;  
2 typedef unsigned short int u2;  
3 typedef unsigned int u4;  
4 typedef unsigned long long u8;
```

还有一些其他类型，如 cp\_info、field\_info 等，后面也会加以讨论。

Java 字节码二进制文件 ClassFile 由若干个二进制字段组成。

第一个字段 magic 是 4 字节的文件魔数，用来标识该二进制文件的类型，虚拟机可以根据这个字段判断该二进制文件是否是 Java 字节码文件。Java 字节码二进制文件的魔数是一个固定的 4 字节常数 0xcafebabe。注意，按照《规范》，Java 字节码文件中的字段都是按大端法进行存储的，这意味着上面的 4 字节魔数实际上是按照 0xca、0xfe、0xba 和 0xbe 4 个字节的顺序从文件偏移为 0 处开始存储（高位在文件的低偏移处）。在后面对所有字节码文件字段的讨论中，请读者都注意大端法的存储特点。

第二个字段 minor\_version 是 2 字节编码的类文件小版本号，而第三个字段 major\_version 是 2 字节编码的类文件大版本号，这两个字段共同决定了类文件所遵守的类文件格式的版本，例如，如果小版本号是 v，而大版本号是 V，则该字节码二进制文件的版本号是 V.v。Java 虚拟机可以根据类文件的版本号来判断自身是否能够支持这个类文件：一般高版本的类文件如果包含了一些新增的 Java 字节码指令，就不能在低版本的虚拟机上运行，即虚拟机一般不能向上兼容；但反之，新的 Java 虚拟机往往能够运行低版本的类文件，即做到了向下兼容。大版本号的排列是有规律的：Java 的 1.0.2 版和 1.1 版使用的是 45；对于 1.v(v≥2) 的版本，其支持的 Java 字节码文件大版本号范围是 45~44+v。注意，为计算方便，Java6、Java7 等版本仍编码为 1.6、1.7 版，以此类推，最新的 Java12 可编码为 1.12 版，其大版本号是 44+12=56。小版本号不太规律，早期的 JDK 版本中使用过不同的小版本

号，但从 Java 1.2 开始，只使用了 0，具体情况见表 2-1。

表 2-1 Java 的大版本号与小版本号

| Java SE | 大版本号 | 小版本号   |
|---------|------|--------|
| 1.0.2   | 45   | 03     |
| 1.1     | 45   | 065535 |
| 1.2     | 46   | 0      |

Java 12 又引入了“预览版”的规定，但和本书讨论的内容关系不大，感兴趣的读者可参考《规范》。

### 2.2.1 常量池

ClassFile 中的字段 `constant_pool_count` 和 `constant_pool` 共同定义了类的常量池数组，前者是常量池数组的长度，后者是数组本身。由于常量池数组的长度是 `u2` 类型，所以数组的允许长度为 65536。但实际上，常量池中表项的实际个数为常量池数组长度 `constant_pool_count` 的值减去 1，原因是常量池数组 `constant_pool` 中第 0 个表项保留不使用，因此，常量数组 `constant_pool` 中存储的是从下标 1 到下标 `constant_pool_count-1` 的 `constant_pool_count-1` 个元素。

类常量池中存储了当前字节码文件所使用的所有常量，常量的类型包括数字型常数、字符串、类名、接口名等。常量池数组中的每个元素长度不同，但其格式都满足以下通用模板：

```

1 cp_info{
2     u1 tag;
3     u1 info [];
4 }
```

即所有数组表项 `cp_info` 都以 1 个无符号字节的类型常量的类型 `tag` 开头，后跟两个或多个字节的类型常量的值。理论上，`tag` 标记最多可支持 256 种不同的常量，但目前虚拟机规范只用到了十多种。《规范》中详细列出了每个 `tag` 的含义及后面数据的类型、字节数和值。接下来讨论 3 个有代表性的常量：整型常量、字符串常量和类常量。

对于整型常量，《规范》规定其数据结构是：

```
1 CONSTANT_Integer_info{
```

```

2   u1 tag; // 3
3   u4 bytes;
4 }
```

即其 tag 值是 3, 后跟 4 个字节的 (以大端法表示) 整型常量 bytes。这种类型的常量共占据常量池中的 5 个字节, 例如, 整型数 8 在常量池中表示为:

0x03 0x00 0x00 0x00 0x08

而对于字符串常量,《规范》规定其数据结构是:

```

1 CONSTANT_String_info{
2   u1 tag; // 8
3   u2 string_index;
4 }
```

即其类型标记 tag 值是 8, 其后为两个字节的常量池下标 string\_index。该下标也同一样索引了常量池, 其中包含一个 UTF-8 字符常量的常量池表项, 其数据结构是:

```

1 CONSTANT_Utf8_info{
2   u1 tag; // 1
3   u2 length;
4   u1 bytes[length];
5 }
```

其 tag 值是 1, 后跟一个长度为 length 的字符数组 bytes, 数组 bytes 中存放着字符串的 UTF-8 编码。例如, 字符串 “hello” 在常量池中的表示可以是:

0x08 0x00 0x05

即其索引了常量池下标为 5 的表项, 该表项的内容是:

0x01 0x00 0x05 0x68 0x65 0x6c 0x6c 0x6f

即这是长度为 5 的 UTF-8 字符数组, 相应字符串的内容从第 4 个字节开始。

对于类常量,《规范》规定其数据结构是:

```

1 CONSTANT_Class_info{
2   u1 tag; // 7
3   u2 name_index;
4 }
```

其 tag 值是 7，后跟一个长度为 2 的常量池下标 name\_index，该下标对应一个 UTF-8 类型的字符串常量，即类的名字。需要注意的是，数组类也同样由上述数据结构描述，类的名字就是数组的描述符，例如对于二维数组类型：

```
int [][]
```

其在常量池中的名字是：

```
[[I
```

而三维数组类型

```
Object [] [] []
```

在常量池中的名字是：

```
[[[Ljava/lang/Object;
```

其他常量类型和上面讨论的三个类型类似，这里不再逐一列举常量池中其余 tag 的可能取值了，读者可参考《规范》了解其他常量池的表项结构。值得注意的是，常量池中的每个表项都是变长的，虽然可以最大程度地节约常量池所占用的二进制文件的存储空间，但是用某个下标直接去索引表项时，都要从常量池的起始地址开始遍历查找，不是特别方便，所以在第 2.3 节将要讨论运行时常量池，对常量池表项进行统一的存储空间管理，并能够支持直接用下标进行索引。

字段 access\_flags 是一个 2 字节长的类的掩码，该掩码对类或者接口的访问权限或属性信息进行了编码。在实际应用中比较常用的值包括 0x0001 和 0x0200，前者表示当前类的访问权限是 public，而后者表示这是一个接口而不是类……读者可参阅《规范》了解所有的可能取值。

字段 this\_class 是 2 字节常量池索引，常量池该索引处的表项是对当前字节码文件所定义的类或接口信息（确切来说，是类或接口的名称）的编码。

字段 super\_class 也是 2 字节常量池索引，常量池中该索引处的表项对当前字节码文件所定义的类或接口的父类或父接口的名称进行了编码，如果当前类或接口没有父类和父接口的话（例如 Object 类），则该字段的值为 0。

### 2.2.2 接口

字段 interfaces\_count 和 interfaces 共同定义了类所实现的接口组成的数组。数组的长度是 interfaces\_count，数组 interfaces 中每个元素都是一个 2 字节常量池索引，常量池该索引处的元素都是类常量。另外，《规范》还规定，接口数组中的元素要按照类文件中实现接口从左到右的顺序排列，例如下面的类：

```

1 class Test implements I1, I2, I3{
2     // ...;
3 }
```

其字节码文件中接口数组的元素顺序是:

```

-----
| I1 | I2 | I3 |
-----
```

### 2.2.3 字段

字段 fields\_count 和 fields 共同定义了类包含的所有字段 (有的文献中也称为属性, 本书中都称之为字段), 但不包括从父类或父接口中继承的字段。该数组的长度是 fields\_count, 数组 fields 中的每个元素都是一种字段信息 field\_info, 其数据结构定义如下:

```

1 field_info{
2     u2 access_flags;
3     u2 name_index;
4     u2 descriptor_index;
5     u2 attributes_count;
6     attributes_info attributes[attributes_count];
7 }
```

其中, access\_flags 是访问权限和属性掩码, 例如, 值 0x0001 代表该字段被 public 修饰; 域 name\_index 和 descriptor\_index 是常量池索引, 被索引的常量池表项分别存放字段名字和字段的描述符; 最后两个域给出了一个长度为 attributes\_count 的属性数组 attributes, 其中存放该字段的其他属性, 例如字段被赋值的常量、字段的注解等;《规范》要求所有虚拟机实现必须能够识别其中的 ConstantValue 属性, 第 2.2.5 节将深入讨论属性。

### 2.2.4 方法

字段 methods\_count 和 methods 共同给出了类包含的所有方法。数组 methods 的长度是 methods\_count, 其中每个元素都是一个方法描述信息 method\_info, 其数据结构定义如下:

```

1 method_info{
2     u2 access_flags;
3     u2 name_index;
4     u2 descriptor_index;
5     u2 attributes_count;
6     attributes_info attributes[attributes_count];
7 }
```

其中 access\_flags 是访问权限和属性掩码, 特别需要提到的两个属性掩码是 ACC\_NATIVE 和 ACC\_ABSTRACT, 它们修饰的方法一般不含代码; 域 name\_index 和 descriptor\_index 是常量池索引, 其表项分别存放方法名和方法描述符; 最后两个字段给出了一个长度为 attributes\_count 的属性数组 attributes, 其中存放该方法的其他属性, 如方法的代码、方法的异常表、方法的注解等; 《规范》要求所有虚拟机实现必须至少能识别字节码 Code 和异常表 Exceptions 两个属性, 第 2.2.5 节将深入讨论属性。

### 2.2.5 属性

字节码类文件格式中最后两个字段 attributes\_count 和 attributes, 定义了一个长度为 attributes\_count 的属性数组 attributes, 用于存放该类具有的属性 attribute\_info。概念上来说, 属性是《规范》提供的一种机制, 该机制用来具体实现自定义扩展字节码文件的格式; 编译器生成字节码文件时, 可以新定义并插入任意的属性, 而虚拟机必须忽略自身不能识别的属性 (但不改变虚拟机自身的行为)。属性的数据结构是:

```

1 attribute_info{
2     u2 attribute_name_index;
3     u4 attribute_length;
4     u1 info[attribute_length];
5 }
```

其中, 第一个域 attribute\_name\_index 是常量池下标, 该下标处存放了 UTF-8 形式的属性名字; 第二个和第三个域共同定义了长度为 attribute\_length 的属性数组 info, info 的具体值和具体的属性相关。从抽象的角度看, 属性实际上是属性名 (字符串) 到属性值 (混合类型) 的一个映射。