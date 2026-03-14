

![TURING logo](2dfa6ac3edfe874f68aa0cbccaa42322_img.jpg)

TURING logo

图灵程序  
设计丛书

# 深入 Java 虚拟机

[日] 中村成洋 / 著 吴炎昌 杨文轩 / 译

# JVM G1GC 的算法与实现

结合实用JVM，图解Java垃圾回收机制的关键技术

90张图表 + 33段代码  
轻松理解G1GC算法原理

HotSpotVM源码剖析  
深入探讨G1GC具体实现

![Illustration of glasses with binary code on the lenses](6ed175c791b5e156d9c98a8dbcc3318c_img.jpg)

Illustration of glasses with binary code on the lenses

![Logo of China Information Industry Press](84a1d09fb489061482111515543b60dc_img.jpg)

Logo of China Information Industry Press

中国工信出版集团

![Logo of Posts & Telecom Press](d3294dc879b451b369c0b06f42e9b39f_img.jpg)

Logo of Posts & Telecom Press

人民邮电出版社  
POSTS & TELECOM PRESS

###### 中村成洋

生于1985年。日本网络应用通信研究所研究员。因为偶然的机会对GC产生浓厚兴趣，本人却说不清为何喜欢GC，被人追问原因时，总是回答“是缘分”。现在是CRuby的committer，每天致力于GC的改善。著有《垃圾回收的算法与实现》。

###### 吴炎昌

毕业于西北工业大学软件工程专业，曾供职于多家日本软件公司，从事系统开发工作。2015年回国后加入美团点评，现任系统研发工程师。爱好旅行、电影和品尝各种美食，有一位志趣相投的伴侣。

## 数字版权声明

图灵社区的电子书没有采用专有客户端，您可以在任意设备上，用自己喜欢的浏览器和PDF阅读器进行阅读。

但您购买的电子书仅供您个人使用，未经授权，不得进行传播。

我们愿意相信读者具有这样的良知和觉悟，与我们共同保护知识产权。

如果购买者有侵权行为，我们可能对该用户实施包括但不限于关闭该帐号等维权措施，并可能追究法律责任。

![Figure 18.1: A stacked bar chart showing the trend of average values across 10 categories. The y-axis represents percentages from 0% to 100%. Each bar is composed of segments in blue, orange, yellow, green, red, and light blue. The total height of the bars varies, with the first bar at 100% and subsequent bars generally decreasing in total height.](5d92d5c9cc01a262b0389d138caa9aea_img.jpg)

| Category | Blue (%) | Orange (%) | Yellow (%) | Green (%) | Red (%) | Light Blue (%) | Total (%) |
|----------|----------|------------|------------|-----------|---------|----------------|-----------|
| 1个       | 100      | 0          | 0          | 0         | 0       | 0              | 100       |
| 2个       | 50       | 50         | 0          | 0         | 0       | 0              | 100       |
| 3个       | 35       | 30         | 35         | 0         | 0       | 0              | 100       |
| 4个       | 25       | 25         | 30         | 20        | 0       | 0              | 100       |
| 5个       | 20       | 20         | 20         | 20        | 20      | 0              | 100       |
| 6个       | 18       | 15         | 15         | 15        | 15      | 17             | 100       |
| 7个       | 15       | 15         | 15         | 15        | 15      | 15             | 100       |
| 8个       | 12       | 12         | 15         | 15        | 15      | 16             | 100       |
| 9个       | 10       | 10         | 15         | 10        | 15      | 10             | 100       |
| 10个      | 8        | 10         | 15         | 10        | 15      | 12             | 100       |

Figure 18.1: A stacked bar chart showing the trend of average values across 10 categories. The y-axis represents percentages from 0% to 100%. Each bar is composed of segments in blue, orange, yellow, green, red, and light blue. The total height of the bars varies, with the first bar at 100% and subsequent bars generally decreasing in total height.

图 18.1 均值的变化趋势

![Figure 18.2: A stacked bar chart showing the trend of decayed average values across 10 categories. The y-axis represents percentages from 0% to 100%. Each bar is composed of segments in blue, orange, yellow, green, red, light blue, and dark blue. The total height of the bars decreases significantly from 100% to approximately 5%.](7fb5215fd72210a2e4cce6df55550c89_img.jpg)

| Category | Blue (%) | Orange (%) | Yellow (%) | Green (%) | Red (%) | Light Blue (%) | Dark Blue (%) | Total (%) |
|----------|----------|------------|------------|-----------|---------|----------------|---------------|-----------|
| 1个       | 100      | 0          | 0          | 0         | 0       | 0              | 0             | 100       |
| 2个       | 70       | 30         | 0          | 0         | 0       | 0              | 0             | 100       |
| 3个       | 50       | 20         | 30         | 0         | 0       | 0              | 0             | 100       |
| 4个       | 35       | 15         | 25         | 25        | 0       | 0              | 0             | 100       |
| 5个       | 25       | 10         | 15         | 20        | 30      | 0              | 0             | 100       |
| 6个       | 15       | 10         | 10         | 10        | 15      | 40             | 10            | 100       |
| 7个       | 10       | 5          | 5          | 5         | 10      | 25             | 40            | 100       |
| 8个       | 5        | 5          | 5          | 5         | 10      | 20             | 50            | 100       |
| 9个       | 2        | 2          | 5          | 5         | 10      | 15             | 61            | 100       |
| 10个      | 1        | 1          | 5          | 5         | 5       | 10             | 73            | 100       |

Figure 18.2: A stacked bar chart showing the trend of decayed average values across 10 categories. The y-axis represents percentages from 0% to 100%. Each bar is composed of segments in blue, orange, yellow, green, red, light blue, and dark blue. The total height of the bars decreases significantly from 100% to approximately 5%.

图 18.2 衰减均值的变化趋势

![TURING logo](bb08c83fc8939517c6803d65c69dd06b_img.jpg)

TURING logo

图灵程序  
设计丛书

# 深入Java 虚拟机

![Glasses with binary code on the lenses](17a042ee648d9fdaddb609aead503980_img.jpg)

Glasses with binary code on the lenses

# JVM G1GC 的算法与实现

[日] 中村成洋 / 著 吴炎昌 杨文轩 / 译

人民邮电出版社  
北 京

## 图书在版编目(CIP)数据

深入 Java 虚拟机: JVM G1GC 的算法与实现 / (日) 中村成洋著; 吴炎昌, 杨文轩译. -- 北京 : 人民邮电出版社, 2021.1  
(图灵程序设计丛书)  
ISBN 978-7-115-55452-9

I. ①深… II. ①中… ②吴… ③杨… III. ①JAVA 语言—程序设计 IV. ①TP312.8

中国版本图书馆 CIP 数据核字(2020)第 237831 号

## 内 容 提 要

本书深入 Java 虚拟机底层原理, 对 JVM 内存管理中的垃圾回收算法 G1GC 进行了详细解读。全书分为“算法篇”和“实现篇”两大部分: 前一部分主要介绍 G1GC 的算法原理, 内容包括 G1GC 的并发标记、转移功能、软实时性的实现和分代 G1GC 模式; 后一部分聚焦算法篇中没有详细讲解的实现部分, 基于 HotSpotVM 源码, 讲解对象管理功能、内存分配器的机制、线程管理方法和 G1GC 的具体实现。

本书以图配文, 通俗易懂, 既系统介绍了 G1GC 的基础算法, 又贴近现实, 剖析了实用 JVM 中的 G1GC 实现, 同时还包含了作者对 G1GC 的研究成果和独到见解, 是深入理解 JVM 和 G1GC 机制的佳作。

本书适合对所有 JVM 和垃圾回收算法感兴趣的读者阅读。

- 
- ◆ 著 [日] 中村成洋
  - 译 吴炎昌 杨文轩
  - 责任编辑 高宇涵
  - 责任印制 周昇亮
  - ◆ 人民邮电出版社出版发行 北京市丰台区成寿寺路 11 号
  - 邮编 100164 电子邮件 315@ptpress.com.cn
  - 网址 <https://www.ptpress.com.cn>
  - 北京 印刷
  - ◆ 开本: 880×1230 1/32
  - 印张: 7.5
  - 字数: 224 千字 2021 年 1 月第 1 版
  - 印数: 1-3 000 册 2021 年 1 月北京第 1 次印刷
  - 著作权合同登记号 图字: 01-2017-0781 号
- 

定价: 59.00 元

读者服务热线: (010) 51095183 转 600 印装质量热线: (010) 81055316

反盗版热线: (010) 81055315

广告经营许可证: 京东市监广登字 20170147 号

## 前言 ---

重要的是持续提出问题。<sup>①</sup>

——阿尔伯特·爱因斯坦

垃圾回收（Garbage Collection，下文简称 GC）这门技术有许多谜团。很多程序员不太了解 GC 程序的运行原理，因此有时它也被称为“秘技”或“魔法”。

拙作《垃圾回收的算法与实现》<sup>[1]</sup>（下文简称“GC 书”）已经解开了这门秘技的大部分谜团。很多读者表示解谜的过程轻松愉快。作为作者之一，我感到非常开心。

这本书和“GC 书”一样，全书由“算法篇”和“实现篇”两大部分构成。

在算法篇中，我们将探讨 OpenJDK 7（即 Java 7）中引入的 GC 算法——G1GC（Garbage First Garbage Collection）的原理。G1GC 中有一个很大的谜团，那就是 GC 暂停处理的预测暂停时间，本书将花上数十页的篇幅来揭示它。

关于 G1GC 的资料，具有代表性的是由大卫·德特勒夫斯（David Detlefs）等人所写的英语论文<sup>[2]</sup>。但是那篇论文非常深奥晦涩，只读一遍是无法透彻理解的。

我初次接触那篇论文是在 2007 年。当时我的英语阅读能力有限，也不怎么了解 GC，所以没读多少就放弃了。3 年后，我掌握了一定程度的 GC 知识，所以再次挑战了那篇论文，结果仍然没能彻底理解。在那之后的半年多里，我读完论文读源码，读完源码又去读论文，如此反复，终于彻底理解了全部内容。对于我来说，理解 G1GC 的过程可以称得上“荆棘之路”了。

---

① 原句为 The important thing is not to stop questioning。——编者注

本书的算法篇比原始论文更加详细地介绍了 G1GC 的算法原理，对于我以前理解起来比较困难的地方，还特意进行了详细的说明，因此内容要比原始论文易于理解。即使是不太了解 GC 的读者，理解起来应该也没有什么问题。

在实现篇中，我们将结合实用 JVM，聚焦算法篇中没有详细讲解的实现部分。

首先，我们会了解 HotSpotVM。现在，HotSpotVM 实现了包括 G1GC 在内的 5 种 GC 算法。不过这些算法并非凭空而来，而是基于 HotSpotVM 中专为 GC 算法设计的框架实现的。因此，接着我们就会了解作为框架之一的对象管理功能。得益于对象管理功能的接口，多种 GC 算法之间的切换成为可能，而且新 GC 算法的添加也变得更加简单。之后，我们会了解对象的数据结构和内存分配器。有关分配器的讲解会稍微涉及对操作系统调用。除此以外，我们还将了解 G1GC 中用到的线程管理方法。HotSpotVM 内部同样也有能够在 GC 过程中简单地操作线程的框架，各种 GC 算法都是通过这个框架来实现并行 GC 和并发 GC 的。

再后面就是 G1GC 的具体实现，讲解了 G1GC 的并发标记和转移，以及调度程序的实现。这部分尽量省略了算法篇中已经详细讲解过的内 容，着重讲解前面没有涉及的内容。

对于 G1GC，我曾有过不少疑问。比如“G1GC 是如何实现精准 GC 的”和“实现了这么多 GC 不会导致写屏障变慢吗”，等等。因此我研究了 G1GC 的实现方式，并将得到的结果放在了本书的最后两章。

本书的目的在于将我走过的“荆棘之路”变成更多人易于踏上的坦途。希望各位读者轻松愉快地走过这条坦途，用最短的时间掌握 G1GC。这就是我的心愿。

最后，我想借此机会对那些始终相信并支持我写作本书的赞助人表示感谢，真的非常感谢你们！

## 注意事项

本书的算法篇是对德特勒夫斯等人的 G1GC 论文的详细解读，不过相

对于论文，理解起来会更轻松。对于论文内容和实际实现<sup>①</sup>有出入的地方，本书以实现为准进行了适当的修正，因此个别地方会与原始论文不同。

此外，部分 G1GC 算法已经在美国取得了专利<sup>②</sup>，因此在实现并公开 G1GC 时请注意不要侵犯他人的专利权。

## 读者对象

本书适合对所有 JVM 和 GC 感兴趣的读者阅读。

本书是对“GC 书”的补充。只要读过“GC 书”，就应该能理解本书的内容。不过即使没有读过，只要具备一些 GC 的基础知识，阅读本书应该也不成问题。具体来说，需要事先掌握标记—清除 GC、复制 GC 和增量 GC 等的基础算法。关于这些基础知识，请参考“GC 书”。

如果不具备任何 GC 相关的知识，而且也不打算阅读“GC 书”，那么建议先自己在网络上简单了解一下 GC。

另外，本书还适合对实现 OpenJDK 7 的内存管理感兴趣的人阅读。由于本书实现篇会引用算法篇中的内容，因此建议大家按照顺序从头开始阅读。

### 本书中的符号

### 图中的箭头

本书的插图中会出现各种各样的箭头。关于本书中主要使用的箭头，请参考图 0.1。

![Figure 0.1 shows three types of arrows: (a) a thin horizontal arrow pointing right, (b) a thick horizontal arrow pointing right, and (c) a wide horizontal arrow pointing right with a triangular head.](0feb2e46baef0867fa0d69ee9cb290d7_img.jpg)

Figure 0.1 shows three types of arrows: (a) a thin horizontal arrow pointing right, (b) a thick horizontal arrow pointing right, and (c) a wide horizontal arrow pointing right with a triangular head.

图 0.1 箭头的样式

① G1GC 在 OpenJDK 7 中得到了实现。源码可以从 OpenJDK 的官网获得。

② 美国专利号为 7340494。

箭头 (a) 表示引用关系，用于从根<sup>①</sup>到对象的引用等。

箭头 (b) 表示赋值操作和转移操作，用于给变量赋值、复制对象、转移对象等。它还可以在执行示意图中用来表示正在执行处理（参见第 ix 页的图 0.2）。

箭头 (c) 表示时间的流逝。

### 伪代码

为了帮助读者理解 GC 算法，本书采用伪代码进行解说。关于用到的伪代码，后文中会说明其表示法。

### 命名规则

变量以及函数都用小写字母表示（例：obj）。常量都用大写字母表示（例：COPIED）。另外，本书用下划线连接两个及两个以上的单词（例：free\_list、update\_ptr()、HEAP\_SIZE）。

### 空指针和真假值

设真值为 TRUE，假值为 FALSE。拥有真假值的变量 var 的否定为 not var。

除此之外，本书用 Null 表示没有指向任何地址的指针。

### 函数

本书采用与一般编程语言相同的描述方法来定义函数。例如，我们将以 arg1、arg2 为参数的函数 func() 定义如下。

```
1: def func(arg1, arg2):
2: ...
```

当以整数 100 和 200 为实参调用该函数时，写作 func(100, 200)。

### 缩进

我们将缩进也算作语法的一部分。例如像下面这样，用缩进表示 if

① 根（root）：追踪对象引用关系时的“起点”。

语句的作用域。

```

1: if True:
2:     a = 1
3:     b = 2
4:     c = 3
5: d = 4
```

在上面的例子中，只有当 `test` 为真时，才会执行第 2 行到第 4 行。第 5 行与 `test` 的值没有关系，所以一定会被执行。我们把缩进长度设为两个空格。

此外，全局变量（所有函数都可以访问的变量）的开头要加上 `$` 前缀。例如 `$global`。

### 指针

在 GC 算法中，指针是不可或缺的。我们用星号（`*`）来访问指针所引用的内存空间。例如我们把指针 `ptr` 指向的对象表示为 `*ptr`。

### 域

我们可以用 `obj.field` 来访问对象 `obj` 的域 `field`。例如，我们要想在对象 `girl` 的各个域 `name`、`age`、`job` 中分别代入值，可按如下书写。

```

1: girl.name = "Alice"
2: girl.age = 30
3: girl.job = "lawyer"
```

###### for 循环

给整数增量的时候，我们使用 `for` 循环。例如用变量 `sum` 求 1 到 10 的和，代码如下所示。

```

1: sum = 0
2: for i in range(1, 10):
3:     sum += i
```

### 队列 ---

GC 中经常用到队列这种数据结构。队列是先进入的数据先取出，即 FIFO（First-In First-Out，先进先出）式的数据结构。

我们用 `enqueue()` 函数给队列添加数据，用 `dequeue()` 函数从队列中取出数据，用 `enqueue(queue, data)` 向队列 `queue` 中添加数据 `data`，用 `dequeue(queue)` 从 `queue` 取出并返回数据。

### 特殊的函数 ---

除了上面介绍的函数之外，还有一个会在伪代码中出现的特殊函数。

`copy_data()` 是复制内存区域的函数。我们用 `copy_data(ptr1, ptr2, size)` 把 `size` 个字节的数据从指针 `ptr2` 指向的内存区域复制到 `ptr1` 指向的内存区域。这个函数跟 C 语言中的 `memcpy()` 函数用法相同。

### 并行 GC 和并发 GC ---

本书中即将介绍的 G1GC 算法组合使用了并行 GC（*parallel GC*）和并发 GC（*concurrent GC*）。这里先介绍一下这两种 GC 的基础知识，以便大家在阅读正文时能更好地理解它们在 G1GC 中是如何被使用的。

一般来说，以多线程执行的 GC 就被称为并行 GC/并发 GC。简单的 GC 以单线程执行为前提，而并行 GC/并发 GC 的前提是多线程执行。因为这样可以更高效地发挥多个处理器的性能，进而达到缩短暂停时间的目的。

“并行”“并发”这两个词虽然长得很像，但是在 GC 中的意思完全不同。

并行 GC 会先暂停 *mutator*<sup>①</sup> 的运行，然后开启多个线程并行地执行 GC（图 0.2）。

---

① *mutator*：一般指“应用程序”，用于改变（*mutate*）GC 对象之间的引用关系。

![Diagram illustrating Parallel GC execution. It shows two horizontal lines. The top line is labeled 'mutator' and has three solid black arrows pointing to the right, separated by dotted lines. The bottom line is labeled 'GC' and also has three solid black arrows pointing to the right, separated by dotted lines. The arrows on both lines are perfectly aligned, indicating that the GC threads run concurrently with the mutator thread.](4e4be0bd8b235167902f2c03e41da651_img.jpg)

Diagram illustrating Parallel GC execution. It shows two horizontal lines. The top line is labeled 'mutator' and has three solid black arrows pointing to the right, separated by dotted lines. The bottom line is labeled 'GC' and also has three solid black arrows pointing to the right, separated by dotted lines. The arrows on both lines are perfectly aligned, indicating that the GC threads run concurrently with the mutator thread.

图 0.2 并行 GC 的执行示意图

暂停 mutator，多个线程并行执行 GC。

而并发 GC 是在不暂停 mutator 运行的同时，直接开启 GC 线程，并发地执行 GC（图 0.3）。

![Diagram illustrating Concurrent GC execution. It shows two horizontal lines. The top line is labeled 'mutator' and has one long solid black arrow pointing to the right. The bottom line is labeled 'GC' and also has one long solid black arrow pointing to the right. The GC arrow starts after the mutator arrow has already begun, and they overlap, indicating that the GC thread runs concurrently with the mutator thread.](410562339ce067fdc6fa41940c118658_img.jpg)

Diagram illustrating Concurrent GC execution. It shows two horizontal lines. The top line is labeled 'mutator' and has one long solid black arrow pointing to the right. The bottom line is labeled 'GC' and also has one long solid black arrow pointing to the right. The GC arrow starts after the mutator arrow has already begun, and they overlap, indicating that the GC thread runs concurrently with the mutator thread.

图 0.3 并发 GC 的执行示意图

不暂停 mutator，GC 线程和 mutator 并发执行。

并行 GC 的目标是尽量缩短 mutator 的暂停时间，而并发 GC 的目标是消除 mutator 的暂停时间。

需要注意的是，因为并发 GC 是和 mutator 并发执行的，所以在标记存活对象的过程中，对象的引用关系可能会被 mutator 改变。GC 线程需要知道到这种引用关系的变化，于是并发 GC 采用了增量式 GC 中也有的写屏障<sup>①</sup>技术。

并行 GC 虽然需要暂停 mutator，但算法实现起来比较简单；并发 GC 不需要暂停 mutator，算法的实现却比较复杂。

另外，并行 GC 和并发 GC 可以配合起来使用。本书中即将介绍的 G1GC 正是如此。在 G1GC 中，大多数时候 GC 线程和 mutator 会并发地执行 GC，但是在个别阶段的处理中，出于算法的考虑则需要暂停 mutator。这时，G1GC 就会启动多个线程，通过并行处理来缩短 mutator 的暂停时间。

① 写屏障：一种处理技术，用于记录由 mutator 改变的对象之间的引用关系。

### 代码中的表示方法 ---

在实现篇中，为了让 OpenJDK 的部分代码更易于阅读，本书在展示代码时有所省略和修改。

部分省略如下所示。

- 用于调试的代码
- 异常处理的代码

部分修改如下所示。

- 修改缩进
- 换行
- 英语注释的翻译
- 为便于说明添加了一些注释
- 为便于说明进行了宏展开

在正文代码中，以上省略和修改恕不逐行标注。

## 致谢 ---

感谢阅读过本书原稿并给出许多评论的下列朋友们：稻叶一浩、finalfusion、mokehehe、三浦英树、相川光、樱庭祐一和中村实。

感谢达人出版会的高桥征义先生。他对本书编辑工作的辛勤付出和耐心让我有更多的时间专注于本书的创作。

还有本书审阅者之一的相川光先生，我们在合著“GC书”时，曾一起将 G1GC 的论文翻译成了日语。在写作本书的过程中，我也多次参考了这份译稿。这里再次表示感谢。

最后，我想感谢一下对我用蹩脚英语提出的问题也进行了耐心解答的 G1GC 之父——HotSpotVM 的 GC 开发团队。

I would like to thank Developer of HotSpotVM's GC.

# 目录 ---

# 算法篇

## 第1章 G1GC是什么 ---

|              |   |
|--------------|---|
| 1.1 G1GC和实时性 | 2 |
| 1.2 堆结构      | 5 |
| 1.3 执行过程     | 5 |
| 1.4 并发标记和转移  | 7 |

## 第2章 并发标记 ---

|                 |    |
|-----------------|----|
| 2.1 什么是并发标记     | 8  |
| 2.2 标记位图        | 9  |
| 2.3 执行步骤        | 10 |
| 2.4 步骤①——初始标记阶段 | 10 |
| 2.5 步骤②——并发标记阶段 | 12 |
| 2.6 步骤③——最终标记阶段 | 18 |
| 2.7 步骤④——存活对象计数 | 19 |
| 2.8 步骤⑤——收尾工作   | 21 |
| 2.9 总结          | 22 |

## 第3章 转移 ---

|                  |    |
|------------------|----|
| 3.1 什么是转移        | 25 |
| 3.2 转移专用记忆集合     | 26 |
| 3.3 转移专用写屏障      | 28 |
| 3.4 转移专用记忆集合维护线程 | 31 |
| 3.5 热卡片          | 32 |

|                      |    |
|----------------------|----|
| 3.6 执行步骤·····        | 32 |
| 3.7 步骤①——选择回收集合····· | 33 |
| 3.8 步骤②——根转移·····    | 34 |
| 3.9 步骤③——转移·····     | 39 |
| 3.10 标记信息的作用·····    | 39 |
| 3.11 总结·····         | 40 |

## 第 4 章 软实时性

|                     |    |
|---------------------|----|
| 4.1 用户的需求·····      | 41 |
| 4.2 预测转移时间·····     | 42 |
| 4.3 预测可信度·····      | 43 |
| 4.4 GC 暂停处理的调度····· | 44 |
| 4.5 并发标记中的暂停处理····· | 46 |

## 第 5 章 分代 G1GC 模式

|                     |    |
|---------------------|----|
| 5.1 不同点·····        | 47 |
| 5.2 新生代区域·····      | 48 |
| 5.3 分代对象转移·····     | 49 |
| 5.4 执行过程简述·····     | 49 |
| 5.5 分代选择回收集合·····   | 51 |
| 5.6 设置最大新生代区域数····· | 51 |
| 5.7 GC 的切换·····     | 52 |
| 5.8 GC 执行的时机·····   | 52 |

## 第 6 章 算法篇总结

|              |    |
|--------------|----|
| 6.1 关系图····· | 53 |
| 6.2 优点·····  | 54 |
| 6.3 缺点·····  | 54 |
| 6.4 结束语····· | 55 |

# 实现篇

## 第 7 章 准备工作

|                   |    |
|-------------------|----|
| 7.1 什么是 HotSpotVM | 58 |
| 7.2 什么是 OpenJDK   | 58 |
| 7.3 获取源码          | 59 |
| 7.4 代码结构          | 60 |
| 7.5 两个特殊类         | 61 |
| 7.6 适用于各种操作系统的接口  | 63 |

## 第 8 章 对象管理功能

|                       |    |
|-----------------------|----|
| 8.1 对象管理功能的接口         | 64 |
| 8.2 对象管理功能的全貌         | 65 |
| 8.3 CollectedHeap 类   | 66 |
| 8.4 CollectorPolicy 类 | 67 |
| 8.5 各个 GC 类           | 68 |

## 第 9 章 堆结构

|            |    |
|------------|----|
| 9.1 VM 堆   | 70 |
| 9.2 G1GC 堆 | 72 |
| 9.3 常驻空间   | 75 |

## 第 10 章 分配器

|              |    |
|--------------|----|
| 10.1 内存分配的流程 | 76 |
| 10.2 VM 堆的申请 | 77 |
| 10.3 VM 堆的分配 | 79 |
| 10.4 对象的分配   | 86 |
| 10.5 TLAB    | 90 |

## 第 11 章 对象结构 ---

|                               |    |
|-------------------------------|----|
| 11.1 oopDesc 类·····           | 92 |
| 11.2 klassOopDesc 类·····      | 93 |
| 11.3 Klass 类·····             | 94 |
| 11.4 类之间的关系·····              | 95 |
| 11.5 不要在 oopDesc 类中定义虚函数····· | 96 |
| 11.6 对象头·····                 | 97 |

## 第 12 章 HotSpotVM 的线程管理 ---

|                           |     |
|---------------------------|-----|
| 12.1 线程操作的抽象化·····        | 103 |
| 12.2 Thread 类·····        | 103 |
| 12.3 线程的生命周期·····         | 104 |
| 12.4 Windows 线程的创建·····   | 107 |
| 12.5 Windows 线程的处理开始····· | 110 |
| 12.6 Linux 线程的创建·····     | 113 |
| 12.7 开始 Linux 线程的处理·····  | 117 |

## 第 13 章 线程的互斥处理 ---

|                         |     |
|-------------------------|-----|
| 13.1 什么是互斥处理·····       | 119 |
| 13.2 互斥量·····           | 119 |
| 13.3 监视器·····           | 120 |
| 13.4 监视器的实现·····        | 122 |
| 13.5 Monitor 类·····     | 127 |
| 13.6 Mutex 类·····       | 129 |
| 13.7 MutexLocker 类····· | 130 |

## 第 14 章 GC 线程（并行篇） ---

|                              |     |
|------------------------------|-----|
| 14.1 并行执行的流程·····            | 132 |
| 14.2 AbstractWorkGang 类····· | 136 |
| 14.3 AbstractGangTask 类····· | 137 |

|                             |     |
|-----------------------------|-----|
| 14.4 GangWorker 类           | 137 |
| 14.5 并行 GC 的执行示例            | 138 |
| <hr/>                       |     |
| <b>第 15 章 GC 线程（并发篇）</b>    |     |
| 15.1 ConcurrentGCThread 类   | 146 |
| 15.2 SuspendibleThreadSet 类 | 147 |
| 15.3 安全点                    | 150 |
| 15.4 VM 线程                  | 152 |
| <hr/>                       |     |
| <b>第 16 章 并发标记</b>          |     |
| 16.1 并发标记的全貌                | 155 |
| 16.2 步骤①——初始标记阶段            | 160 |
| 16.3 步骤②——并发标记阶段            | 168 |
| 16.4 步骤③——最终标记阶段            | 170 |
| 16.5 步骤④——存活对象计数            | 172 |
| 16.6 步骤⑤——收尾工作              | 172 |
| <hr/>                       |     |
| <b>第 17 章 转移</b>            |     |
| 17.1 转移的全貌                  | 174 |
| 17.2 步骤①——选择回收集合            | 178 |
| 17.3 步骤②——根转移               | 181 |
| 17.4 步骤③——转移                | 185 |
| <hr/>                       |     |
| <b>第 18 章 预测与调度</b>         |     |
| 18.1 根据历史记录进行预测             | 187 |
| 18.2 并发标记的调度                | 194 |
| 18.3 转移的调度                  | 195 |
| <hr/>                       |     |
| <b>第 19 章 准确式 GC 的实现</b>    |     |
| 19.1 栈图                     | 197 |
| 19.2 句柄区域与句柄标记              | 209 |

## 第 20 章 写屏障的性能开销

|                       |     |
|-----------------------|-----|
| 20.1 运行时切换 GC 算法····· | 212 |
| 20.2 解释器的写屏障·····     | 214 |
| 20.3 JIT 编译器的写屏障····· | 216 |

|         |     |
|---------|-----|
| 后记····· | 220 |
|---------|-----|

|           |     |
|-----------|-----|
| 参考文献····· | 223 |
|-----------|-----|

### --- ■本书主页

[ituring.cn/book/1922](http://ituring.cn/book/1922)

### ■注意事项

- ①与本书内容相关的网址，均可在本书主页下方的“相关文章”处查询
- ②本书记载的软件或服务的版本、URL 等都是 2012 年 5 月撰写时的信息。这些信息可能会发生变更，敬请知悉
- ③本书出版之际，我们力求内容的准确性，但是作者、人民邮电出版社和译者均不对内容做任何保证，对于运用本书内容所造成的任何结果，不承担任何责任
- ④本书中出现的公司名称、产品名称皆为各公司的商标或注册商标，正文中省略了 ®、TM 等标识

# G1GC

Garbage First Garbage Collection

# 算法篇

![Hand-drawn diagram illustrating G1GC's 'Dead line' concept.](79e1709a7317ead45379cbb8ff3ba802_img.jpg)

A hand-drawn diagram illustrating the G1GC 'Dead line' concept. It features several elements:

- A rectangular box at the top left containing the text "Dead line 5ms".
- A central vertical line with the number "1" written on it.
- Three small, round, sad-faced characters (representing objects) positioned around the central line:
  - One on the left with a "3ms" label next to it.
  - One on the right with a "1ms" label next to it.
  - One above the central line, connected to it by a line, with a "5ms" label next to it.
- Three rectangular blocks labeled "2", "1", and "3" at the bottom, with the central block "1" directly under the central line.
- A trash can icon on the right containing a circular arrow symbol.

Hand-drawn diagram illustrating G1GC's 'Dead line' concept.

## 1

## G1GC 是什么

本章将介绍 G1GC 的基础知识。

### 1.1 G1GC 和实时性

G1GC 最大的特征是非常重视实时性。本节首先会介绍一般意义上的实时性，然后再探讨 G1GC 中的实时性是什么样的。

#### 1.1.1 实时性

处理实时性的要求是，它必须能在最后期限（deadline）之前完成。

最后期限可以自由指定。如果指定的期限较短，那么程序就要保证在短时间内完成处理；相反，如果指定的期限较长，那么程序只要能保证在这个较长的时间内完成处理就可以了。

另外，即使同为实时程序，如果处理内容不同，最后期限的重要性也会很不一样。有些处理只要超出最后期限一次，就会带来致命的问题，而有些处理稍微打破几次最后期限也不会有太大的问题。这两种处理分别称为“硬实时性（hard real-time）处理”和“软实时性（soft real-time）处理”。

#### 1.1.2 硬实时性和软实时性

硬实时性的处理，多存在于保护人类免于受伤、远离危险，以安全为第一位的场景中。例如，医疗机器人控制系统、航空管制系统等都会要求硬实时性。如果这类系统中的处理超出了最后期限，很可能出现

致命的问题。而且，硬实时性的处理必须在处理开始后的很短时间内完成。

软实时性处理多用于稍微超出几次最后期限也没什么问题的系统中，例如网络银行系统。用户总会期待所有的交易都能完美地处理好，但是稍微超出几次最后期限，比如交易完成界面的展示慢了一些，应该也不会构成致命的问题。

软实时性的处理可以超出最后期限，但超出期限的频率很重要。只有超出频率在用户能够容忍范围之内的处理，我们才能说它具备软实时性。

#### 1.1.3 可预测性

《Java 并发编程实战》<sup>[2]</sup> 的作者之一布赖恩·戈茨 (Brian Goetz) 曾在一篇文章<sup>[7]</sup> 中像下面这样写道：

实时处理很多时候会与“高速性”相关。但是，高速性其实只是实时处理的特征之一。

对于实时处理来说，真正重要的特征是“可预测性”。

实时处理必须尽力保证不超出最后期限。因此相比高速性，**可预测性**更重要一些。

这里所说的可预测性，指的是“可以预测处理大约会耗费多长时间”。即使处理速度再快，如果无法在执行前预测出需要的时间，处理也是没有使用价值的——因为该处理存在随时超出最后期限的可能。如果能够预测出大致的处理时间，就可以据此来评估是否会超出最后期限。如果有超出期限的可能，就可以事先采取应对措施，例如对处理内容进行分解。

因此，在保证实时性方面，可预测性是一个重要的因素。

#### 1.1.4 G1GC 中的实时性

G1GC 具有软实时性。为了实现软实时性，它具备以下两个功能。

- ① 设置期望暂停时间（最后期限）
- ② 可预测性

①是支持用户自定义 mutator 暂停时间的功能。G1GC 具有软实时性，因此会尽力保证处理不超过该暂停时间。

②是用来预测下次 GC 会导致 mutator 暂停多长时间的功能。根据预测出来的结果，G1GC 会通过延迟执行 GC、拆分 GC 目标对象等手段来遵守①中设置的期望暂停时间。通过这种方式，能够尽量减少超出用户期望暂停时间的频率，从而实现软实时性。

#### 1.1.5 Java 中出现 G1GC 的背景 ---

Java（OpenJDK）中已经存在并行 GC、并发 GC 和增量 GC<sup>①</sup>等多种 GC 算法。除了 Java 之外，没有哪种语言提供这么多的 GC 算法供用户选择。那么，Java 为什么还要增加新的算法 G1GC 呢？

现在，Java 语言广泛用于服务端应用程序的开发，而其中有些应用程序需要具备软实时性。例如，管理电话呼叫的服务端应用程序等（实际上已经存在一些用 Java 语言实现的应用程序了<sup>②</sup>）。

这类应用程序当前主要是采用增量 GC 或者并发 GC 来缩短最大暂停时间的。但是，缩短最大暂停时间很容易导致吞吐量<sup>③</sup>下降。还有，因为无法预测暂停时间，GC 可能会有 mutator 长时间停止的风险。

于是 G1GC 诞生了，其目的就是高效地实现软实时性。Java 先前的 GC 算法都在一味地尝试缩短最大暂停时间，而 G1GC 则是让用户去设置期望暂停时间。用户按照自己的需求设置合适的 GC 暂停时间，在确保吞吐量比以往的 GC 更好的前提下，实现了软实时性。

另外，追求软实时性的服务端应用程序，大都运行在拥有巨大的

---

① 增量 GC：通过慢慢地进行 GC 来缩短 mutator 最大暂停时间的一种手段。

② 出自参考文献 [3] 中的 “1.INTRODUCTION”。

③ 吞吐量：单位时间内回收垃圾的量。如果 GC 的吞吐量下降，总的暂停时间就会变长。

堆<sup>①</sup>和多处理器的服务器设备之上。因此，内部的 GC 算法必须能够在短时间内以高吞吐量来处理巨大的堆，而且还要高效地发挥多处理器的优势。G1GC 的设计就很符合这些要求，它能够最大程度地利用服务器上多处理器的优势，而且在处理巨大的堆时，也不会降低 GC 的性能。

### 1.2 堆结构

G1GC 中的堆结构和列车 GC<sup>②</sup>中的堆结构非常相似。

堆的内部被划分为大小相等的区域，所有区域排列成一排。G1GC 以区域为单位进行 GC。用户可以随意设置区域大小，但是内部会将用户设置的值向上调整为 2 的指数幂 ( $2^n$ )，并以该正数作为区域的大小（图 1.1）。

![Diagram of the G1GC heap structure. The heap is a long horizontal bar labeled '堆' (Heap) at the top. It is divided into several rectangular blocks. The first two blocks are filled with grey rectangles, each containing three smaller grey squares, and are labeled '区域 (默认 1 MB)' (Region (default 1 MB)). The next two blocks are white and labeled '空闲' (Free). An arrow from the label '空闲区域链表' (Free Region List) points to the first '空闲' block. Another arrow points to the second '空闲' block. The diagram ends with an ellipsis '...'.](a0739aaf13fa5a632d4faa830f6b2708_img.jpg)

Diagram of the G1GC heap structure. The heap is a long horizontal bar labeled '堆' (Heap) at the top. It is divided into several rectangular blocks. The first two blocks are filled with grey rectangles, each containing three smaller grey squares, and are labeled '区域 (默认 1 MB)' (Region (default 1 MB)). The next two blocks are white and labeled '空闲' (Free). An arrow from the label '空闲区域链表' (Free Region List) points to the first '空闲' block. Another arrow points to the second '空闲' block. The diagram ends with an ellipsis '...'.

图 1.1 堆结构

如果正在分配对象的某个区域已经满了，GC 线程会寻找下一个空闲的区域来继续分配。空闲区域是通过链表进行管理的，因此查找的时间复杂度是固定的  $O(1)$ 。

### 1.3 执行过程

下面我们简要地介绍一下 G1GC 的执行过程。G1GC 主要有下面两

① 堆：程序运行时用于创建对象的内存区域。

② 详情可参考“GC 书”算法篇中的 7.7 节。

个功能。

①并发标记（concurrent marking）

②转移（evacuation）

①并发标记基本能和 mutator 并发执行，会针对区域内所有的存活对象<sup>①</sup>进行标记。

②转移负责释放堆中死亡对象所占的内存空间。

首先，从众多区域中选择一个进行 GC 操作。如果该区域中有存活对象，则将其复制到其他空闲区域中（图 1.2）。

![Diagram illustrating the state of the heap (堆) during GC. The left grid shows three circles (live objects) in a 3x4 grid of cells. The top row is white (empty), the middle row is grey (used), and the bottom row is white (empty). The circles are in the middle row (grey) and the bottom row (white). Arrows show the circles being moved from their original positions to the bottom row. A large arrow points to the right grid, which shows the heap after evacuation. The right grid is a 3x4 grid where the top row is white, the middle row is grey, and the bottom row is white. The circles are now only in the bottom row (white), and the cells they occupied in the middle row are now white, indicating they are empty.](20136850feb70fd71c7d41cdae203ebb_img.jpg)

Diagram illustrating the state of the heap (堆) during GC. The left grid shows three circles (live objects) in a 3x4 grid of cells. The top row is white (empty), the middle row is grey (used), and the bottom row is white (empty). The circles are in the middle row (grey) and the bottom row (white). Arrows show the circles being moved from their original positions to the bottom row. A large arrow points to the right grid, which shows the heap after evacuation. The right grid is a 3x4 grid where the top row is white, the middle row is grey, and the bottom row is white. The circles are now only in the bottom row (white), and the cells they occupied in the middle row are now white, indicating they are empty.

图 1.2 堆的状态

白色区域是空闲区域，灰色区域是使用中的区域。左图表示的是在选中区域后开始将存活对象复制到空闲区域的操作；右图表示的是转移后堆的状态。为了方便展示，图中的区域以二维的方式排列，但是在内存中其实是如图 1.1 所示排列成一排的。

当选择的空闲区域也满了的时候，GC 线程会再次选择其他空闲区域来存放存活对象。对象复制完成之后，只剩下死亡对象<sup>②</sup>的区域会被重置为空闲区域以便复用。

转移其实也起到了压缩<sup>③</sup>的作用，因此 G1GC 中的区域不会发生碎

① 存活对象：活着的对象，即有可能被程序使用的对象。

② 死亡对象：已死亡的对象，即不可能再被程序使用的对象。

③ 压缩：将存活对象挤到内存中同一侧的操作。因为压缩之后对象之间没有空隙，所以区域不会有碎片化的问题。

片化<sup>①</sup>。

### 1.4 并发标记和转移

正如上一节中提到的那样，G1GC 的主要功能是并发标记和转移。其中并发标记由并发标记线程来执行。

并发标记的作用是在尽量不暂停 mutator 的情况下标记出存活对象。而且，还需要在并发标记结束之后记录下每个区域内存活对象的数量。这个信息在转移时会用到。

转移的作用是将待回收区域内的存活对象复制到其他的空闲区域，然后将待回收区域重置为空闲状态。这很像复制 GC 算法，只不过是以区域为单位进行的。

需要注意的是，并发标记和转移在处理上是相互独立的。并发标记的结果信息对于转移来说并不是必须的。因此，转移处理可能发生在并发标记开始之前，也可能发生在并发标记的过程中。

---

① 碎片化：对象零散地存在于堆中的现象。

## 2

## 并发标记

本章将详细介绍并发标记。并发标记的主要作用是提供转移过程所需要的信息。

### 2.1 什么是并发标记

在简单标记中，所有可从根直接触达的对象都会被添加标记。带标记的是存活对象，不带标记的是死亡对象。

图 2.1 表示标记开始时和结束时的堆的状态。标记结束后，可从根触达的对象 a、b、c 都带有标记，而对象 d、e 则会因为不带标记而被当作死亡对象处理。

![Diagram illustrating the heap state at the start and end of marking. At the start, objects a, b, and c are reachable from the root, while d and e are not. At the end, objects a, b, and c are marked (shaded black), while d and e remain unmarked.](805c475f0859e607af0530ba43194bf1_img.jpg)

The diagram shows two states of a heap. In the initial state (left), a root node points to objects a, b, and c. Objects a and b are in '区域 A' and object c is in '区域 B'. Objects d and e are also in '区域 B' but are not directly reachable from the root. An arrow indicates a transition to the final state (right). In the final state, objects a, b, and c are shaded black, indicating they have been marked. Objects d and e remain unshaded.

Diagram illustrating the heap state at the start and end of marking. At the start, objects a, b, and c are reachable from the root, while d and e are not. At the end, objects a, b, and c are marked (shaded black), while d and e remain unmarked.

图 2.1 标记开始时和结束时的堆的状态

对象 a、c 由根直接引用。标记结束后，可从根触达的对象 a、b、c 都带有标记。这里用黑色来表示它们。

在并发标记中，存活对象的标记和 mutator 的运行几乎是并发进行的。相比简单标记而言，并发标记的执行步骤更加复杂。详情将在 2.3 节中介绍。

需要注意的是，并发标记其实并不是直接在对象上添加标记，而是

在标记位图<sup>①</sup>上添加标记。

### 2.2 标记位图

图 2.2 表示堆中的一个区域。位图中的黑色表示已标记，白色表示未标记。

![Diagram illustrating the internal structure of a marking bitmap and a region. The diagram shows two rows of bitmaps: 'next' and 'prev'. The 'next' row has 10 cells, with the 1st, 3rd, 5th, and 7th cells marked black. The 'prev' row has 3 cells, with the 1st and 3rd cells marked black. Below these is a 'Region' containing four objects: A, B, C, and D. Object A is black, B is white, C is black, and D is white. Arrows point from the 'next' bitmap cells to objects A, C, and D, and from the 'prev' bitmap cells to objects A and C. The region is divided into 'bottom' (from A to D) and 'top' (the rest of the region). The 'top' section is labeled '未使用' (Unused). The 'bottom' section has markers 'bottom', 'prevTAMS', and 'top' (nextTAMS) below it. The 'top' section has a marker 'top' (nextTAMS) below it. Objects A and C have diagonal lines through them, indicating they are live objects. Objects B and D are white and have no diagonal lines, indicating they are dead objects.](474a819357587e34949a3e110ff19b30_img.jpg)

Diagram illustrating the internal structure of a marking bitmap and a region. The diagram shows two rows of bitmaps: 'next' and 'prev'. The 'next' row has 10 cells, with the 1st, 3rd, 5th, and 7th cells marked black. The 'prev' row has 3 cells, with the 1st and 3rd cells marked black. Below these is a 'Region' containing four objects: A, B, C, and D. Object A is black, B is white, C is black, and D is white. Arrows point from the 'next' bitmap cells to objects A, C, and D, and from the 'prev' bitmap cells to objects A and C. The region is divided into 'bottom' (from A to D) and 'top' (the rest of the region). The 'top' section is labeled '未使用' (Unused). The 'bottom' section has markers 'bottom', 'prevTAMS', and 'top' (nextTAMS) below it. The 'top' section has a marker 'top' (nextTAMS) below it. Objects A and C have diagonal lines through them, indicating they are live objects. Objects B and D are white and have no diagonal lines, indicating they are dead objects.

图 2.2 标记位图和区域的内部结构

位图中的黑色表示已标记，白色表示未标记。黑色的是存活对象，带有叉号的是死亡对象。

每个区域都带有两个标记位图：`next` 和 `prev`。`next` 是本次标记的标记位图，而 `prev` 是上次标记的标记位图，保存了上次标记的结果。

标记位图中每个比特都对应着关联区域内对象的开头部分。我们假设单个对象的大小都是 8 个字节，那么每 8 个字节就会对应标记位图中的 1 个比特。图中标记位图里黑色的地方表示比特值是 1，白色的地方表示比特值是 0。相应地，区域内黑色的是存活对象，带有叉号的是死亡对象。

图 2.2 中的 `bottom` 表示区域内众多对象的末尾，`top` 表示开头。`nextTAMS` 中的 `TAMS` 是 “Top At Marking Start”（标记开始时的 `top`）的缩写。`nextTAMS` 保存了本次标记开始时的 `top`，而 `prevTAMS` 保存了上次标记开始时的 `top`。

① 标记位图：将用于标记的比特值等信息单独拿出来放到其他地方，用来匹配对应的对象。

### 2.3 执行步骤

并发标记过程包括以下5个步骤。

- ① 初始标记阶段
- ② 并发标记阶段
- ③ 最终标记阶段
- ④ 存活对象计数
- ⑤ 收尾工作

下面分别简单介绍一下各个步骤。

①暂停 mutator 的运行，标记可由根直接引用的对象。后文中，我们将需要暂停 mutator 的处理称为**暂停处理**（pause）。

②标记（扫描）①中标记的对象所引用的对象。本步骤会开启并发标记线程进行标记，这个过程和 mutator 的运行是并发进行的。

③暂停处理。本步骤会扫描②中没有标记的对象。在本步骤结束之后，堆内所有存活的对象都会被标记。

④对每个区域中被标记的对象进行计数。这个过程也是和 mutator 并发进行的。

⑤暂停处理。本步骤主要进行一些收尾工作，并为下次标记做准备。在本步骤结束之后，整个并发标记过程全部结束。

其中，②、③、④、⑤这4个步骤一般都会开启多个线程，并行地执行任务。但是，本书中为了便于读者理解，会以单线程执行为前提展开讨论。

### 2.4 步骤①——初始标记阶段

从本节开始，我们将详细介绍并发标记过程中各个步骤的处理内容。图2.3表示的是堆中的某个区域。

![Diagram illustrating the state of the heap region after the initial marking phase. It shows a sequence of objects A through I. Object C is shaded gray, indicating it is unscanned. The 'next' marking bitmap shows the first two cells as black, and the 'prev' pointer points to the start of the region. The 'bottom' pointer is at the start of the region, and the 'top' pointer is at the end of object I. The 'nextTAMS' pointer is aligned with the 'top' pointer. A root node points to object C.](5d3455c6c2a37cb3aff761fedeb8644e_img.jpg)

The diagram illustrates the state of the heap region after the initial marking phase. At the top, there is a marking bitmap labeled 'next' with two black cells followed by eight white cells. Below it is a pointer labeled 'prev' pointing to the start of the region. The main part of the diagram shows a sequence of objects labeled A through I within a box labeled '区域' (Region). Object C is shaded gray, while others are white. A pointer labeled 'bottom' points to the start of the region, and a pointer labeled 'top' points to the end of object I. A pointer labeled 'nextTAMS' is also shown at the 'top' position. A root node, represented by an oval labeled '根', has an arrow pointing to object C. The 'prevTAMS' label points to the 'bottom' pointer.

Diagram illustrating the state of the heap region after the initial marking phase. It shows a sequence of objects A through I. Object C is shaded gray, indicating it is unscanned. The 'next' marking bitmap shows the first two cells as black, and the 'prev' pointer points to the start of the region. The 'bottom' pointer is at the start of the region, and the 'top' pointer is at the end of object I. The 'nextTAMS' pointer is aligned with the 'top' pointer. A root node points to object C.

图 2.3 初始标记阶段结束后区域的状态

本图和图 2.2 中选取的是不同的区域。灰色对象表示的是未扫描的对象。

在初始标记阶段，GC 线程首先会创建标记位图 `next`。`nextTAMS` 指的就是标记开始时 `top` 所在的位置，所以在这里我们将它和 `top` 对齐。在创建位图时，其大小也和 `top` 对齐，为  $((\text{top}-\text{bottom})/8)$  字节。这些处理都是和 `mutator` 并发进行的。

对可由根直接引用的对象进行标记的过程叫作根扫描。等所有区域的标记位图都创建完成之后，就可以开始进行根扫描了。

为了防止在根扫描的过程中根被修改，在这个过程中 `mutator` 是暂停执行的。虽然 G1GC 中采用的写屏障技术可以获知对象的修改，但是大多数根并不是对象，它们的修改并不能被写屏障获知，因此在进行根扫描时必须暂停 `mutator` 的执行。

根需要频繁修改，所以其中大部分不在写屏障可以获知的范围内。也许 G1GC 的设计者认为，与其频繁地通过写屏障去获知修改的方式，还不如直接暂停 `mutator` 来进行根扫描的方式性能更佳。

如果一个对象本身被标记了，但其子对象并没有被扫描，我们就称它为未扫描对象。图 2.3 使用灰色表示未扫描对象。虽然图中该对象已在根扫描中被标记，但其子对象还没有被扫描到，所以是未扫描对象（灰色）。也就是说，对象 C 持有子对象 A 和 E，但是因为根扫描不会扫

描子对象，所以对象 C 作为未扫描对象被表示为灰色。未扫描对象 C 的处理会在后面 2.5 节中讲解。

完成根扫描后，mutator 会再次开启执行，GC 处理也会进入下一阶段。

#### 专栏

#### 读屏障

有一种和写屏障相对应的技术，叫作**读屏障**。写屏障用来获知对象的修改，而读屏障用来获知引用的读取。

读屏障有多种实现方式，例如可以在寄存器调取内存的时候触发读屏障。

读屏障可以获知所有的引用读取，因此也能获知根的变更，所以如果使用读屏障，就不需要在根扫描时暂停 mutator 了。

这样看来读屏障似乎很完美，但实际上它有一个致命的缺点——慢。对所有的引用读取行为都进行处理，其实对系统来说是很大的负担。因此人们几乎不会使用读屏障。

### 2.5 步骤②——并发标记阶段

在并发标记阶段，GC 线程继续扫描在初始标记阶段被标记过的对象，完成对大部分存活对象的标记。为什么说是大部分对象而不是全部对象呢？这个会在 2.6 节中解释。

图 2.4 表示的是并发标记阶段结束后区域的状态。对象 C 的子对象 A 和 E 都被标记了。像 E 这样，一个对象对应了标记位图中多个位的情况，只有起始的标记位（mark bit）会被涂成黑色。

![Diagram illustrating the state of a region after the concurrent marking phase. The region contains objects A through K. Objects A, C, E, J, and K are marked (black). Objects B, D, F, G, H, and I are unmarked (white). The region is bounded by 'bottom' and 'top'. 'prevTAMS' points to object A. 'nextTAMS' points to object J. 'prev' and 'next' are pointers at the top, with 'prev' pointing to object A and 'next' pointing to object K. An arrow labeled '新分配' (New Allocation) points to the space between J and K. The region is labeled '区域' (Region).](c76da2d73c064464051d1583fd80bb6b_img.jpg)

Diagram illustrating the state of a region after the concurrent marking phase. The region contains objects A through K. Objects A, C, E, J, and K are marked (black). Objects B, D, F, G, H, and I are unmarked (white). The region is bounded by 'bottom' and 'top'. 'prevTAMS' points to object A. 'nextTAMS' points to object J. 'prev' and 'next' are pointers at the top, with 'prev' pointing to object A and 'next' pointing to object K. An arrow labeled '新分配' (New Allocation) points to the space between J and K. The region is labeled '区域' (Region).

图 2.4 并发标记阶段结束后区域的状态

对象 C 的子对象 A 和 E 被涂成了黑色。在并发标记执行期间新创建的对象 J 和 K 也在区域内被分配了空间。对象 J 和 K 也被涂成了黑色，因此会被 GC 当成存活对象。

并发标记阶段的一个重要特点是 GC 线程和 mutator 是并发执行的。因为 mutator 在执行过程中可能会改变对象之间的引用关系，所以如果只采用一般的标记方法，可能会发生“标记遗漏”<sup>①</sup>。因此，必须使用写屏障技术来记录对象间引用关系的变化。针对这种情况，G1GC 中所采用的写屏障将在 2.5.1 节中介绍。并发标记阶段也会标记和扫描被写屏障获知变化的对象。

处理完待标记对象之后，就会进入最终标记阶段。

#### 2.5.1 SATB

SATB (Snapshot At The Beginning, 初始快照) 是一种将并发标记阶段开始时对象间的引用关系，以逻辑快照的形式进行保存的手段<sup>②</sup>。在 SATB 中，标记过程中新生成的对象会被看作“已完成扫描和标记”，因此其子对象不会被标记。图 2.4 中 nextTAMS 和 top 之间的对象 J 和 K 就是在标记过程中新生成的对象。因为它们的引用关系在标记开始时并不存在，所以它们都会被当成存活对象。因此，也不必专门为标记过程中新生成的对象创建标记位图。这样我们就明白为什么图 2.4 中对象 J

① 详情请参考“GC 书”算法篇中的 8.1.4 节。

② 详情请参考“GC 书”算法篇中的 8.4 节。

和 K 没有对应的标记位图了。

另外，如果在并发标记的过程中对象的域上发生了写操作，就必须以某种方式记录下被改写之前的引用关系。G1GC 通过对汤浅的算法<sup>①</sup>稍加优化而得到的写屏障技术，实现了这个功能。因为优化后的写屏障是用于 SATB 的，因此我们称之为 **SATB 专用写屏障**。SATB 专用写屏障的伪代码如代码清单 2.1 所示。

代码清单 2.1 satb\_write\_barrier() 函数

```

1: def satb_write_barrier(field, newobj):
2:   if $gc_phase == GC_CONCURRENT_MARK:
3:     oldobj = *field
4:     if oldobj != Null:
5:       enqueue($current_thread.stab_local_queue, oldobj)
6:
7:   *field = newobj

```

参数 `field` 表示被写入对象的域，参数 `newobj` 表示被写入域的值。第 2 行的 `GC_CONCURRENT_MARK` 用来表示并发标记阶段的标志位（`flag`）。第 4 行会检查当前是否处于并发标记阶段且被写入之前 `field` 域的值是不是 `Null`。如果检查通过，则在第 5 行将 `oldobj` 添加到 `$current_thread.stab_local_queue` 中。然后，在第 7 行进行实际的写入操作。

这个算法没有对 `oldobj` 进行任何标记处理，这一点和汤浅的算法不同。原生算法会在第 4 行检查 `oldobj` 是否带标记，然后在第 5 行进行标记，但 G1GC 的这个算法不会对 `oldobj` 进行标记。具体原因会在 2.5.2 节中介绍。

另外，在实现 SATB 专用写屏障的实现考虑到了多线程环境下的执行。其中的奥妙就在于第 5 行的 `$current_thread.stab_local_queue`（SATB 本地队列）。`$current_thread.stab_local_queue` 是 `mutator` 各自持有的线程本地队列，而非全局的队列，因此在执行

① 汤浅的算法：由汤浅太一于 1990 年开发的算法。这种算法是以 GC 开始时对象间的引用关系为基础来执行 GC 的。详情请参考“GC 书”算法篇中的 8.4 节。

——编者注

enqueue() 时不用担心线程之间会发生资源竞争。

如图 2.5 所示, SATB 本地队列在装满 (默认大小为 1 KB) 之后, 会被添加到全局的 SATB 队列集合中。这些被添加的 SATB 本地队列, 都是并发标记阶段的待标记对象。

![Diagram illustrating the SATB Queue Set and SATB Local Queues. The SATB 队列集合 (SATB Queue Set) is represented by an oval containing several horizontal bars. Below it are mutator 1 专用 SATB 本地队列, mutator 2 专用 SATB 本地队列, and mutator 3 专用 SATB 本地队列, each represented by a horizontal bar. A thick black arrow labeled '添加已装满的 SATB 本地队列' points from the bottom of the SATB 队列集合 oval to the top of the mutator 1 专用 SATB 本地队列 bar.](6e15fc9ea763541c5913d26f85072ae1_img.jpg)

The diagram shows the relationship between the SATB Queue Set and the SATB Local Queues. The SATB 队列集合 (SATB Queue Set) is an oval containing several horizontal bars representing local queues. Below it are mutator 1 专用 SATB 本地队列, mutator 2 专用 SATB 本地队列, and mutator 3 专用 SATB 本地队列, each represented by a horizontal bar. A thick black arrow labeled '添加已装满的 SATB 本地队列' points from the bottom of the SATB 队列集合 oval to the top of the mutator 1 专用 SATB 本地队列 bar.

Diagram illustrating the SATB Queue Set and SATB Local Queues. The SATB 队列集合 (SATB Queue Set) is represented by an oval containing several horizontal bars. Below it are mutator 1 专用 SATB 本地队列, mutator 2 专用 SATB 本地队列, and mutator 3 专用 SATB 本地队列, each represented by a horizontal bar. A thick black arrow labeled '添加已装满的 SATB 本地队列' points from the bottom of the SATB 队列集合 oval to the top of the mutator 1 专用 SATB 本地队列 bar.

图 2.5 SATB 队列集合和 SATB 本地队列

在并发标记阶段, GC 线程会定期检查 SATB 队列集合的大小。如果发现其中有队列, 则会对队列中的全部对象进行标记和扫描。前面已经讲过, SATB 专用写屏障并不检查目标对象是否被标记, 因此队列中可能存在已经被标记的对象。这些已经被标记的对象不会再次被标记和扫描。

另外, 比起 2.5 节中提到的“从根开始逐一扫描存活对象并进行标记的处理”, 扫描 SATB 队列集合的处理优先级更高。这是因为, 写屏障会不断地往 SATB 本地队列中添加对象, 但是对象间引用关系的变化并不会改变存活对象的触达链路的总条数。因此, 扫描 SATB 队列集合, 比扫描存活对象触达链路的优先级更高也是合理的。

#### 2.5.2 SATB 专用写屏障的优化

和汤浅的算法相比，SATB 专用写屏障有以下两点不同之处。

- ① 不检查目标对象是否被标记
- ② 不对目标对象进行标记

但是①和②的处理并不是消失了，而是由 GC 线程在并发标记过程中处理了。这样做就可以减少写屏障的开销，增加并发标记的开销。

这种优化的目的，在于将写屏障的系统负荷转移到并发标记处理中，从而分担 mutator 的负担。因为 mutator 会频繁地执行写屏障，所以减少写屏障的开销也会减轻 mutator 的负担。而且，并发标记处理是由 GC 线程和 mutator 并发执行的，所以多个 mutator 就能平摊这些负担，进而减轻单个 mutator 的负担。

如果把这些优化放到不支持并发标记的 GC 中，该 GC 的负荷反而会增加。这种针对写屏障的优化，可以说是专为采用了并发标记的 G1GC 设计的。

#### 2.5.3 SATB 专用写屏障和多线程执行

我们再看一下代码清单 2.2。

代码清单 2.2 satb\_write\_barrier() 函数（再次出现）

```

1: def satb_write_barrier(field, newobj):
2:     if $gc_phase == GC_CONCURRENT_MARK:
3:         oldobj = *field // (a)
4:         if oldobj != Null:
5:             enqueue($current_thread.stab_local_queue, oldobj) // (b)
6:
7:         *field = newobj // (c)
```

代码清单 2.2 中的代码会在各 mutator 的对象发生改写时被调用执行。但是，代码中 (a) 到 (c) 的步骤并没有加锁，所以如果多个线程同时改写域 \*field, oldobj 就可能会存入意想不到的值。

例如下面这样的场景。

- `*field`的值是`obj0`（对象的地址）
- `t1`（线程1）想要往`*field`中写入`obj1`
- `t2`（线程2）想要往`*field`中写入`obj2`

如果 `t1` 和 `t2` 按照先后顺序执行，那么 `t1` 会往 SATB 本地队列中写入 `obj0`，`t2` 会写入 `obj1`。但是 `t1` 和 `t2` 也有可能按照以下顺序执行。

- ① `t1` 执行 (a) : `oldobj = obj0`
- ② `t2` 执行 (a) : `oldobj = obj0`
- ③ `t1` 执行 (b) : `obj0` 被添加到 `$current_thread.stab_local_queue` 中
- ④ `t2` 执行 (b) : `obj0` 被添加到 `$current_thread.stab_local_queue` 中
- ⑤ `t1` 执行 (c) : `*field = obj1`
- ⑥ `t2` 执行 (c) : `*field = obj2`

在这种情况下，`*field` 最终会被 `t2` 写入 `obj2`。但是 `t1` 写入的 `obj1` 并不会被添加到 SATB 本地队列中。也就是说，`obj1` 并没有被 SATB 专用写屏障获知。这看起来像是致命的缺陷，但实际上，即使 `obj1` 没有被添加到 SATB 本地队列中也没有关系。

SATB 专用写屏障本来是用来防止发生标记遗漏的，那么 `obj1` 没有被添加到 SATB 本地队列这件事会不会导致标记遗漏呢？

图 2.6 表示的是 `obj1` 未被 SATB 专用写屏障获知时对象之间的关系。我们假定并发标记进行到了 `obj3`。由于 `obj1` 不会被添加到 SATB 本地队列中，所以会保持为白色。而 `obj0` 会被添加到 SATB 本地队列中，所以会变成灰色。但是在后续扫描 `obj4` 时，`obj1` 最终还是会被标记，所以不存在标记遗漏。

![Diagram 2.6: Object relationships when obj1 is not known by SATB write barrier. The left side shows obj3 pointing to obj1, and obj4 pointing to obj1. obj0 and obj2 are also shown. The right side shows the state after a transition, where obj3 now points to obj0, and obj4 no longer points to obj1. obj0 and obj2 are shaded gray, while obj1 is white.](7f5df81190b8dc50dad2604562ae0715_img.jpg)

Diagram 2.6: Object relationships when obj1 is not known by SATB write barrier. The left side shows obj3 pointing to obj1, and obj4 pointing to obj1. obj0 and obj2 are also shown. The right side shows the state after a transition, where obj3 now points to obj0, and obj4 no longer points to obj1. obj0 and obj2 are shaded gray, while obj1 is white.

图 2.6 obj1 未被 SATB 专用写屏障获知时对象之间的关系

标记完成的对象用黑色表示；添加到 SATB 本地队列中的对象用灰色表示；其余对象用白色表示。

那么，如果 obj1 不再被 obj4 引用，而变为被 obj2 引用时，情况又是怎样的呢？图 2.7 进行了演示。

![Diagram 2.7: Object relationships when obj1 is no longer referenced by obj4 but is referenced by obj2. The left side shows obj3 pointing to obj1, and obj4 pointing to obj1. obj0 and obj2 are also shown. The right side shows the state after a transition, where obj3 now points to obj0, and obj4 no longer points to obj1. obj0 and obj2 are shaded gray, while obj1 is also shaded gray.](382a9c9e4816bd229191ab4591424dd8_img.jpg)

Diagram 2.7: Object relationships when obj1 is no longer referenced by obj4 but is referenced by obj2. The left side shows obj3 pointing to obj1, and obj4 pointing to obj1. obj0 and obj2 are also shown. The right side shows the state after a transition, where obj3 now points to obj0, and obj4 no longer points to obj1. obj0 and obj2 are shaded gray, while obj1 is also shaded gray.

图 2.7 obj1 不再被 obj4 引用，变为被 obj2 引用时对象之间的关系

当来自 obj4 的引用消失时，obj1 就会变成灰色。

在这种情况下，来自 obj4 的引用消失会被 SATB 专用写屏障获知，obj1 会变成灰色，所以也不会有问题。

SATB 专用写屏障会记录下并发标记阶段开始时对象之间的引用关系。这么来看，因为 obj3 对 obj1 的引用在并发标记阶段开始时并不存在，所以根本没有必要记录 obj1。相反，因为 obj3 对 obj0 的引用在并发标记阶段开始时就存在，所以记录 obj0 是有必要的。

代码清单 2.2 中 (a) 到 (c) 的步骤虽然没有加锁，但是 SATB 专用写屏障技术严格遵守了前面这些约束条件，所以即使不记录 obj1 也是没有问题的。

### 2.6 步骤③——最终标记阶段

最终标记阶段的处理是暂停处理，需要暂停 mutator 的运行。

因为未装满的 SATB 本地队列不会被添加到 SATB 队列集合中，所

以在并发标记阶段结束后，各个线程的 SATB 本地队列中可能仍然存在待扫描的对象。而最终标记阶段就会扫描这些“残留的 SATB 本地队列”。在图 2.8 中，队列中保存了对象 G 和 H 的引用。因此在扫描 SATB 本地队列之后，对象 G 和 H，以及对象 H 的子对象 I 都会被标记。

![Diagram illustrating the state of the heap region after the final marking phase. It shows a mutator thread's SATB local queue containing references to objects G and H. After a full scan of the SATB queue, these objects and their references are marked. The heap region is shown with objects A through K, where A, C, E, G, H, and I are marked (shaded black). The scan boundary is indicated by nextTAMS and top. The next marking bit array shows the state of the heap.](47a7beddcb8a1b7abdca746967e32bb4_img.jpg)

The diagram illustrates the state of the heap region after the final marking phase. At the top, a "mutator 线程 1 专用 SATB 本地队列" (Mutator Thread 1's dedicated SATB local queue) contains objects G and H. An arrow labeled "全部扫描" (Full Scan) points down to the heap region, indicating that the SATB queue has been scanned. The heap region is represented as a long horizontal bar containing objects A through K. Objects A, C, E, G, H, and I are shaded black, indicating they are marked. The scan boundary is indicated by "nextTAMS" and "top". Above the heap, there is a "next" marking bit array and a "prev" marking bit array. The "next" array shows a series of black and white squares, with the first few squares corresponding to objects A, C, E, G, H, and I. The "prev" array is mostly white. The "bottom" and "prevTAMS" labels are also present.

Diagram illustrating the state of the heap region after the final marking phase. It shows a mutator thread's SATB local queue containing references to objects G and H. After a full scan of the SATB queue, these objects and their references are marked. The heap region is shown with objects A through K, where A, C, E, G, H, and I are marked (shaded black). The scan boundary is indicated by nextTAMS and top. The next marking bit array shows the state of the heap.

图 2.8 最终标记阶段结束后区域的状态

因为 SATB 本地队列中存在对象 G 和 H 的引用，所以扫描后，对象 G 和 H，以及对象 H 的子对象 I 都会变成黑色。

本步骤结束后，所有的存活对象都已被标记。因此，此时所有不带标记的对象都可以判定为死亡对象。

因为 SATB 本地队列中的数据会被 mutator 操作，所以本步骤不能和 mutator 并发执行。

### 2.7 步骤④——存活对象计数

这个步骤会扫描各个区域的标记位图 next，统计区域内存活对象的字节数，然后将其存入区域内的 next\_marked\_bytes 中。图 2.9 中的存活对象是 A、C、E、G、H 和 I，因此计算出的总字节数 56 会被存入 next\_marked\_bytes 中。对象 E 虽然只有头部的 1 个比特被标记了，

但参与统计的是它的真实大小，即 16 字节。

![Diagram illustrating the state of the heap region after counting live objects. The diagram shows a sequence of objects A through M. Objects A, C, E, G, H, and I are marked (shaded black). Objects B, D, F, J, K, L, and M are unmarked (white). The 'next' pointer points to the start of the region. 'next_marked_bytes' is 56. 'prev' points to the start of the region. 'prev_marked_bytes' is 0. 'bottom' points to the start of the region. 'nextTAMS' points to object J. 'top' points to object M. Arrows indicate the flow of pointers and the relationship between the counters and the objects.](e151d3468319b81f042ca232c4d82e4b_img.jpg)

Diagram illustrating the state of the heap region after counting live objects. The diagram shows a sequence of objects A through M. Objects A, C, E, G, H, and I are marked (shaded black). Objects B, D, F, J, K, L, and M are unmarked (white). The 'next' pointer points to the start of the region. 'next\_marked\_bytes' is 56. 'prev' points to the start of the region. 'prev\_marked\_bytes' is 0. 'bottom' points to the start of the region. 'nextTAMS' points to object J. 'top' points to object M. Arrows indicate the flow of pointers and the relationship between the counters and the objects.

图 2.9 存活对象计数结束后区域的状态

`next_marked_bytes` 表示对象 A、C、E、G、H 和 I 的总字节数，一共 56 字节。计数过程中新创建了对象 L 和 M。

另外，我们假设在计数过程中新创建了对象 L 和 M。由于这些包含在 `nextTAMS` 和 `top` 之间的对象都会被当作存活对象来处理，所以不会在这里特意进行计数。

`prev_marked_bytes` 中存放了上次标记结束时存活对象的字节数。图 2.9 中的区域在此之前未曾进行过标记，因此 `prev_marked_bytes` 中存放的是初始值 0。

计数处理和 `mutator` 是并发执行的。但是，计数过程中操作的对象也可能会被转移的记忆集合（remembered set）线程使用，因此需要先停掉记忆集合线程。

另外，转移处理也可能在计数过程中启动。这时，需要先将正在计数中的区域统计完，再开始转移处理。已完成计数的区域在转移后会变成空区域，所以 `next_marked_bytes` 也会变成 0。而转移目标区域内都是存活对象，所以也不会对它进行计数。

### 2.8 步骤⑤——收尾工作

收尾工作所操作的数据中有些是和 mutator 共享的，因此需要暂停 mutator 的运行。

在此期间 GC 线程会逐个扫描每个区域，将标记位图 next 中的并发标记结果移动到标记位图 prev 中，再对并发标记中使用过的标记值进行重置，为下次并发标记做好准备。

此外，对没有存活对象的区域进行回收的工作也在这个时候进行。可以把它理解成以区域为单位进行的清除<sup>①</sup>处理。

在扫描过程中还会计算每个区域的转移效率，并按照该效率对区域进行降序排序。关于转移效率的内容，我们将在 2.8.1 节中介绍。

图 2.10 展示了收尾工作结束后区域的状态。图 2.9 里 `next.next_marked_bytes` 中的值被移到了 `prev.prev_marked_bytes` 中。同时，`prevTAMS` 被移到了 `nextTAMS` 先前的位置。`prevTAMS` 表示的是“上次并发标记开始时 `top` 的位置”。

![Diagram illustrating the state of a region after the finalization step. It shows the 'next' and 'prev' regions. The 'next' region has a 'next_marked_bytes' value of 0. The 'prev' region has a 'prev_marked_bytes' value of 56. The 'prev' region contains objects A through M. 'bottom' and 'nextTAMS' point to the start of the 'prev' region. 'prevTAMS' points to the start of the 'next' region. 'top' points to the end of the 'prev' region.](52e112d1ba42a3c660bf62a0fea927d3_img.jpg)

The diagram illustrates the state of a region after the finalization step. It shows the 'next' and 'prev' regions. The 'next' region has a 'next\_marked\_bytes' value of 0. The 'prev' region has a 'prev\_marked\_bytes' value of 56. The 'prev' region contains objects A through M. 'bottom' and 'nextTAMS' point to the start of the 'prev' region. 'prevTAMS' points to the start of the 'next' region. 'top' points to the end of the 'prev' region.

Diagram illustrating the state of a region after the finalization step. It shows the 'next' and 'prev' regions. The 'next' region has a 'next\_marked\_bytes' value of 0. The 'prev' region has a 'prev\_marked\_bytes' value of 56. The 'prev' region contains objects A through M. 'bottom' and 'nextTAMS' point to the start of the 'prev' region. 'prevTAMS' points to the start of the 'next' region. 'top' points to the end of the 'prev' region.

图 2.10 收尾工作完成后区域的状态

`next` 中的信息会被移到 `prev` 中。

`next.next_marked_bytes` 也会被重置，同时 `nextTAMS` 会移动到

① 清除：即标记—清除 GC 中的清除，指释放那些不带标记的对象的内存空间。

bottom 的位置。nextTAMS 会在下次并发标记开始时，移动到 top 的最新位置（参考 2.4 节）。

收尾工作结束后，整个并发标记就结束了。并发标记线程会一直处于等待状态，直到下次并发标记开始。

### 转移效率

转移效率可以通过公式“死亡对象的字节数  $\div$  转移所需时间”来计算。换句话说，转移效率指的就是转移 1 个字节所需的时间。区域的转移效率可以通过公式“区域内死亡对象的字节数  $\div$  转移整个区域所需时间”来计算。

这里的“转移所需时间”严格来说是转移的预测时间。转移的预测时间可以根据过去的实际转移时间来计算。详细内容将在 4.2 节中介绍。

另外，一般来说死亡对象越多，转移效率就越高。死亡对象多就意味着存活对象少；存活对象越少，转移所需的时间就越少，所以转移效率就会越高。

转移效率这一重要概念在后文中会多次出现，请理解清楚并牢记。

### 2.9 总结

并发标记结束后，转移处理可以得到以下信息（参考图 2.10）。

- ① 并发标记完成时存活对象和死亡对象的区分（标记位图 prev）
- ② 存活对象的字节数（prev\_marked\_bytes）

这些信息在并发标记阶段不会被改变，因此，即使在并发标记阶段就开始转移处理也不会有问题。另外，虽然新的对象是在并发标记结束后被创建的，但由于它是分配在 prevTAMS 和 top 之间的，所以会被当成存活对象处理。

#### 专栏

#### 对象的担忧（死亡标记）

对象 A：“喂，你头上的是死亡标记吧？”

对象 B：“啊！好可怕！”

![A four-panel comic strip illustrating the 'Death Mark' pattern. Panel 1: A character with a '1' on their head looks at another character. Panel 2: A character with a '1' on their head looks at a car. Panel 3: A character with a '1' on their head looks at a car with a stick figure character. Panel 4: A character with a '1' on their head looks at a car with a stick figure character running away.](140913b7b42defa2c3887852c721a34f_img.jpg)

The comic strip consists of four panels. In the first panel, a character with a '1' on their head is looking at another character. In the second panel, the character with the '1' on their head is looking at a car. In the third panel, the character with the '1' on their head is looking at a car with a stick figure character. In the fourth panel, the character with the '1' on their head is looking at a car with a stick figure character running away.

A four-panel comic strip illustrating the 'Death Mark' pattern. Panel 1: A character with a '1' on their head looks at another character. Panel 2: A character with a '1' on their head looks at a car. Panel 3: A character with a '1' on their head looks at a car with a stick figure character. Panel 4: A character with a '1' on their head looks at a car with a stick figure character running away.

#### 专栏

![A hand-drawn cartoon of a car with a driver inside. The car has a small 'U' shape on its side, which is a common symbol for a parking lot or a specific type of marker. The car is drawn with simple lines and has a small '=' symbol at the back.](fef13e705ab28b357c22ed6444dde1a2_img.jpg)

A hand-drawn cartoon of a car with a driver inside. The car has a small 'U' shape on its side, which is a common symbol for a parking lot or a specific type of marker. The car is drawn with simple lines and has a small '=' symbol at the back.

1

![A simple stick figure drawing of a person standing.](340f40c5c3c7fdaf4c4717f0cb63ed68_img.jpg)

A simple stick figure drawing of a person standing.

对象 B：“哦，原来不是死亡标记，而是存活标记啊。”

## 3

## 转移

本章将介绍实际进行 GC 的转移功能。

### 3.1 什么是转移

通过转移，所选区域内所有存活对象都会被转移到空闲区域。这样一来，被转移的区域内就只剩下死亡对象。重置之后，该区域就会成为空闲区域，能够再次利用。

图 3.1 表示了转移开始前和结束后的状态。转移结束后，可从根触达的存活对象 a、b、c 会被转移到空闲区域 C，而死亡对象 d 和 e 不会被转移，整个区域 B 会被重置以供再次利用。

![Diagram illustrating the transfer process before and after. The top part shows the initial state with three regions: A, B, and C. Region A contains objects a and b. Region B contains objects c, d, and e. Region C is empty. A root node points to objects a, b, and c. A downward arrow indicates the transfer process. The bottom part shows the final state: Region A and Region B are now empty (labeled '空闲'). Region C now contains objects a, b, and c. The root node still points to objects a, b, and c.](ff5f89b660edddb67971d7d3d4ce87ef_img.jpg)

Diagram illustrating the transfer process before and after. The top part shows the initial state with three regions: A, B, and C. Region A contains objects a and b. Region B contains objects c, d, and e. Region C is empty. A root node points to objects a, b, and c. A downward arrow indicates the transfer process. The bottom part shows the final state: Region A and Region B are now empty (labeled '空闲'). Region C now contains objects a, b, and c. The root node still points to objects a, b, and c.

图 3.1 转移开始前和结束后的状态

待转移对象所在的区域是 A 和 B。可从根触达的对象 a、b、c 会被转移到区域 C。

### 3.2 转移专用记忆集合

除了可以从根和并发标记的结果发现存活对象之外，转移功能还能通过转移专用记忆集合来发现对象。2.5.1 节介绍的 SATB 队列集合主要用来记录标记过程中对象之间引用关系的变化，而转移专用记忆集合则用来记录区域之间的引用关系。通过使用转移专用记忆集合，在转移时即使不扫描所有区域内的对象，也可以查到待转移对象所在区域内的对象被其他区域引用的情况，从而简化单个区域的转移处理（图 3.2）。

![Diagram illustrating the Transfer Special Memory Set (TSMS). It shows a central '待转移对象所在区域' (Target Region) containing several objects. Two other regions, labeled '其他区域' (Other Regions), each contain one object. Arrows indicate that the objects in the other regions reference objects in the target region. A small box at the top labeled '记录在转移专用记忆集合中' (Recorded in Transfer Special Memory Set) has arrows pointing to the objects in the other regions, indicating that these references are recorded in the TSMS.](4e85fe330de2c4f5eea6de4b2a53c77f_img.jpg)

Diagram illustrating the Transfer Special Memory Set (TSMS). It shows a central '待转移对象所在区域' (Target Region) containing several objects. Two other regions, labeled '其他区域' (Other Regions), each contain one object. Arrows indicate that the objects in the other regions reference objects in the target region. A small box at the top labeled '记录在转移专用记忆集合中' (Recorded in Transfer Special Memory Set) has arrows pointing to the objects in the other regions, indicating that these references are recorded in the TSMS.

图 3.2 转移专用记忆集合

转移专用记忆集合中记录了来自其他区域的引用，因此即使不扫描所有区域内的对象，也可以确定待转移对象所在区域内的存活对象。

G1GC 是通过卡表（card table）来实现转移专用记忆集合的。

#### 3.2.1 卡表

卡表是由元素大小为 1 B 的数组实现的（图 3.3）。卡表里的元素称为卡片。堆中大小适当的一段存储空间会对应卡表中的 1 个元素（卡片）。在当前的 JDK 中，这个大小被定为 512 B。因此，当堆的大小是 1 GB 时，可以计算出卡表的大小就是 2 MB。

![Diagram illustrating the construction of a Card Table. The Card Table is an array of card indices (0, 1, 2, 3, ..., 2097151, 2097152). Each index corresponds to a 1B card in a 1GB heap. The heap is divided into regions of 512B each. Cards are represented as boxes: white for '净卡片' (clean cards) and gray for '脏卡片' (dirty cards). The first card (index 0) is shown with diagonal hatching, representing a 512B region. The legend indicates white boxes for '净卡片' and gray boxes for '脏卡片'.](5db6545aedab79741ebae9b27bb363b3_img.jpg)

Diagram illustrating the construction of a Card Table. The Card Table is an array of card indices (0, 1, 2, 3, ..., 2097151, 2097152). Each index corresponds to a 1B card in a 1GB heap. The heap is divided into regions of 512B each. Cards are represented as boxes: white for '净卡片' (clean cards) and gray for '脏卡片' (dirty cards). The first card (index 0) is shown with diagonal hatching, representing a 512B region. The legend indicates white boxes for '净卡片' and gray boxes for '脏卡片'.

图 3.3 卡表的构造

卡表的实体是数组。数组的元素是 1 B 的卡片，对应了堆中的 512 B。脏卡片用灰色表示，净卡片用白色表示。

堆中的对象所对应的卡片在卡表中的索引值可以通过以下公式快速计算出来。

(对象的地址 - 堆的头部地址) / 512

因为卡片的大小是 1 B，所以可以用来表示很多状态。卡片的种类很多，本书主要关注以下两种。

- ① 净卡片
- ② 脏卡片

关于这两种卡片的详细内容，我们将在 3.3 节中介绍。其他卡片是 JDK 在实现过程中根据需要引入的，本书就不赘述了。

#### 3.2.2 转移专用记忆集合的构造

转移专用记忆集合的构造如图 3.4 所示。

![Diagram illustrating the construction of a Transfer专用记忆集合 (Transfer专用 Memory Set).](b9c0d46c1148cf65cb79f27fac420981_img.jpg)

The diagram shows two regions, Region A and Region B, each with a transfer专用记忆集合 A (散列表) (Transfer专用 Memory Set A (Hash Table)).

**Region A's Transfer专用记忆集合 A (散列表):**

| 键 (Key) | 值 (Value)        |
|---------|------------------|
| C       | 6144, 6364, 6932 |
| D       | 8199             |
| B       | 2048             |

Key is the address of the region. Value is the array of card indices.

**Region B's Transfer专用记忆集合 A (散列表):**

| 键 (Key) | 值 (Value) |
|---------|-----------|
| 0       | ...       |
| 2048    | ...       |

Key is the address of the region. Value is the array of card indices.

**Objects and References:**

- Region A contains object **a**.
- Region B contains object **b**.
- Object **b** in Region B has a reference to object **a** in Region A.
- The card index 2048 is highlighted in Region B's card table, and a dashed line points to the entry for key B in Region A's transfer专用记忆集合 A.

Diagram illustrating the construction of a Transfer专用记忆集合 (Transfer专用 Memory Set).

图 3.4 转移专用记忆集合的构造

每个区域都有一个转移专用记忆集合，它是通过散列表实现的。图中对象 b 引用了对象 a，因此对象 b 所对应的卡片索引就被记录在了区域 A 的转移专用记忆集合中。

每个区域中都有一个转移专用记忆集合，它是通过散列表实现的。散列表的键是引用本区域的其他区域的地址，而散列表的值是一个数组，数组的元素是引用方的对象所对应的卡片索引。

在图 3.4 中，区域 B 中的对象 b 引用了区域 A 中的对象 a。因为对象 b 不是区域 A 中的对象，所以必须记录下这个引用关系。而在转移专用记忆集合 A 中，以区域 B 的地址为键的值中记录了卡片的索引 2048。因为对象 b 所对应的卡片索引就是 2048，所以对象 b 对对象 a 的引用被准确地记录了下来。

由此我们可以明白，区域间对象的引用关系是由转移专用记忆集合以卡片为单位粗略记录的。因此，在转移时必须扫描被记录的卡片所对应的全部对象的引用。关于这一点的详细内容，我们将在 3.8 节中介绍。

### 3.3 转移专用写屏障

当对象的域被修改时，被修改对象所对应的卡片会被转移专用写屏障记录到转移专用记忆集合中。转移专用写屏障的伪代码如代码清单 3.1 所示。

代码清单 3.1 evacuation\_write\_barrier() 函数

```

1: def evacuation_write_barrier(obj, field, newobj):
2:     check = obj ^ newobj
3:     check = check >> LOG_OF_HEAP_REGION_SIZE
4:     if newobj == Null:
5:         check = 0
6:     if check == 0:
7:         return
8:
9:     if not is_dirty_card(obj):
10:        to_dirty(obj)
11:        enqueue($current_thread.rs_log, obj)
12:
13:     *field = newobj

```

这个函数的参数和第 2 章中代码清单 2.1 的作用相同。

第 2 行到第 7 行的代码会在 `obj` 和 `newobj` 位于同一个区域，或者 `newobj` 为 `Null` 时，起到过滤的作用。这是达尔科·斯特凡诺维奇（Darko Stefanović）等人<sup>[4]</sup>提出的过滤技术。我们逐行分析一下代码。

第 2 行的“^”（XOR 运算符）用来检测两个对象地址的高位部分是否相等。每个区域都是按固定大小进行分配的，如果 `obj` 和 `newobj` 是同一个区域中的地址，那么由于两个地址中超过区域大小的高位部分是完全相等的，所以第 2 行变量 `check` 的值小于区域的大小。第 3 行的 `LOG_OF_HEAP_REGION_SIZE` 是区域大小的对数（底为 2）。1.2 节提到过，区域大小必须是“2 的指数幂”（ $2^n$ ），而指数  $n$  就是 `LOG_OF_HEAP_REGION_SIZE`。将 `check` 右移 `LOG_OF_HEAP_REGION_SIZE` 后，小于区域大小的比特值都会归 0。这样一来，如果 `check` 的值小于区域大小，右移之后的结果就会变为 0。第 4 行检查 `newobj` 是否为 `Null`，第 6 行检查 `check` 是否为 0。

第 9 行的函数 `is_dirty_card()` 用来检查参数 `obj` 所对应的卡片是否为脏卡片。脏卡片指的是已经被转移专用写屏障添加到转移专用记忆集合日志中的卡片。该行的检查就是为了避免向转移专用记忆集合日志中添加重复的卡片。相反，不在转移专用记忆集合日志中的卡片是净卡片。如果是净卡片，则该卡片将在第 10 行变成脏卡片，然后在第 11 行被添加到队列 `$current_thread.rs_log` 中。这个处理能够保证转移专用记忆集合日志中的卡片都是脏卡片。

另外，转移专用写屏障和 SATB 专用写屏障做了同样的优化，在多线程环境下性能也不会变差。

图 3.5 表示了“转移专用记忆集合日志”和“转移专用记忆集合日志集合”的结构。每个 mutator 线程都持有一个名为转移专用记忆集合日志的缓冲区，其中存放的是卡片索引的数组。当对象 b 的域被修改时，写屏障就会获知，并会将对象 b 所对应的卡片索引添加到转移专用记忆集合日志中。转移专用记忆集合日志是由各个 mutator 线程持有的，所以在添加时不用担心线程之间的竞争。也是得益于这种设计，转移专用写屏障不需要进行排他处理，因而具有更好的性能。代码清单 3.1 中的 `$current_thread.rs_log` 就是转移专用记忆集合日志。

![Diagram illustrating the Transfer Special Remember Set (TSRS) and its collection (TSRS Collection).](3442f31a562d1ef45bfa18b18a6a1ddc_img.jpg)

The diagram illustrates the structure of Transfer Special Remember Set (TSRS) and its collection. It shows two mutator threads, A and B, each maintaining their own TSRS (a buffer of card index arrays). Thread A's TSRS is shown as a dashed oval containing card indices: 9432, 42, 52661, ..., 57352, 2048. Thread B's TSRS contains 5935, followed by empty slots and an ellipsis. A label "写满了" (Full) points to Thread A's TSRS. Below these is a "转移专用记忆集合日志集合 (数组)" (TSRS Collection Array) which is a stack of TSRS buffers. The top buffer is labeled "写满的转移专用记忆集合日志" (Full TSRS) and contains three slots, with the bottom one labeled "新添加" (Newly added). A "写屏障" (Write Barrier) starburst points to a "卡表" (Card Table) entry for address 2048. This entry is marked "变成脏卡片" (Becoming dirty card). The card table entry points to a "新的引用" (New reference) for object "b" in a "区域" (Region). An arrow labeled "添加索引" (Add index) points from the card table entry to Thread A's TSRS. Another arrow labeled "添加" (Add) points from Thread A's TSRS to the TSRS Collection Array.

Diagram illustrating the Transfer Special Remember Set (TSRS) and its collection (TSRS Collection).

图 3.5 转移专用记忆集合日志及其集合

当 mutator 线程 A 的转移专用记忆集合日志写满之后，它会被添加到转移专用集合日志的集合中。

另外，转移专用记忆集合日志会在写满后被添加到全局的转移专用记忆集合日志集合中。这个添加过程可能存在多个线程之间的竞争，所