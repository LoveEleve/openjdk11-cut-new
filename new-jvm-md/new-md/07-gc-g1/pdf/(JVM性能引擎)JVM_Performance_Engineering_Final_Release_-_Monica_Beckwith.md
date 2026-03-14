

ORACLE  
PRESS

![Java logo featuring a steaming coffee cup icon and the word 'Java' in a stylized font.](935eed7aa61f7777f62cfc032e11bee9_img.jpg)

Java logo featuring a steaming coffee cup icon and the word 'Java' in a stylized font.

# JVM Performance Engineering

Inside OpenJDK and the  
HotSpot Java Virtual Machine

ORACLE

Monica Beckwith

# JVM Performance Engineering ---

*This page intentionally left blank*

# JVM Performance Engineering ---

Inside OpenJDK and the  
HotSpot Java Virtual Machine

Monica Beckwith

◆ Addison-Wesley

Hoboken, New Jersey

Cover image: Amiak / Shutterstock

Figures 7.8–7.18, 7.22–7.29: The Apache Software Foundation

Many of the designations used by manufacturers and sellers to distinguish their products are claimed as trademarks. Where those designations appear in this book, and the publisher was aware of a trademark claim, the designations have been printed with initial capital letters or in all capitals.

The author and publisher have taken care in the preparation of this book, but make no expressed or implied warranty of any kind and assume no responsibility for errors or omissions. No liability is assumed for incidental or consequential damages in connection with or arising out of the use of the information or programs contained herein.

The views expressed in this book are those of the author and do not necessarily reflect the views of Oracle.

Oracle America Inc. does not make any representations or warranties as to the accuracy, adequacy or completeness of any information contained in this work, and is not responsible for any errors or omissions.

For information about buying this title in bulk quantities, or for special sales opportunities (which may include electronic versions; custom cover designs; and content particular to your business, training goals, marketing focus, or branding interests), please contact our corporate sales department at [corpsales@pearsoned.com](mailto:corpsales@pearsoned.com) or (800) 382-3419.

For government sales inquiries, please contact [governmentsales@pearsoned.com](mailto:governmentsales@pearsoned.com).

For questions about sales outside the U.S., please contact [intlcs@pearson.com](mailto:intlcs@pearson.com).

Visit us on the Web: [informit.com/aw](http://informit.com/aw)

Library of Congress Control Number: 2024930211

Copyright © 2024 Pearson Education, Inc.

All rights reserved. This publication is protected by copyright, and permission must be obtained from the publisher prior to any prohibited reproduction, storage in a retrieval system, or transmission in any form or by any means, electronic, mechanical, photocopying, recording, or likewise. For information regarding permissions, request forms and the appropriate contacts within the Pearson Education Global Rights & Permissions Department, please visit [www.pearson.com/permissions](http://www.pearson.com/permissions).

ISBN-13: 978-0-13-465987-9

ISBN-10: 0-13-465987-2

\$PrintCode

*To my cherished companions, who have provided endless inspiration and comfort throughout the journey of writing this book:*

*In loving memory of Perl, Sherekhan, Cami, Mr. Spots, and Ruby. Their memories continue to guide and brighten my days with their lasting legacy of love and warmth.*

*And to Delphi, Calypso, Ivy, Selene, and little Bash, who continue to fill my life with joy, curiosity, and playful adventures. Their presence brings daily reminders of the beauty and wonder in the world around us.*

*This book is a tribute to all of them—those who have passed and those who are still by my side—celebrating the unconditional love and irreplaceable companionship they have graciously shared with me.*

*This page intentionally left blank*

# Contents

Preface xv

Acknowledgments xxiii

About the Author xxvii

# 1 The Performance Evolution of Java: The Language and the Virtual Machine 1

A New Ecosystem Is Born 2

A Few Pages from History 2

Understanding Java HotSpot VM and Its Compilation Strategies 3

The Evolution of the HotSpot Execution Engine 3

Interpreter and JIT Compilation 5

Print Compilation 5

Tiered Compilation 6

Client and Server Compilers 7

Segmented Code Cache 7

Adaptive Optimization and Deoptimization 9

HotSpot Garbage Collector: Memory Management Unit 13

Generational Garbage Collection, Stop-the-World, and Concurrent Algorithms 13

Young Collections and Weak Generational Hypothesis 14

Old-Generation Collection and Reclamation Triggers 16

Parallel GC Threads, Concurrent GC Threads, and Their Configuration 16

The Evolution of the Java Programming Language and Its Ecosystem: A Closer Look 18

Java 1.1 to Java 1.4.2 (J2SE 1.4.2) 18

Java 5 (J2SE 5.0) 19

Java 6 (Java SE 6) 23

Java 7 (Java SE 7) 25

Java 8 (Java SE 8) 30

Java 9 (Java SE 9) to Java 16 (Java SE 16) 32

Java 17 (Java SE 17) 40

Embracing Evolution for Enhanced Performance 42

# **2 Performance Implications of Java's Type System Evolution 43**

Java's Primitive Types and Literals Prior to J2SE 5.0 44

Java's Reference Types Prior to J2SE 5.0 45

Java Interface Types 45

Java Class Types 47

Java Array Types 48

Java's Type System Evolution from J2SE 5.0 until Java SE 8 49

Enumerations 49

Annotations 50

Other Noteworthy Enhancements (Java SE 8) 51

Java's Type System Evolution: Java 9 and Java 10 52

Variable Handle Typed Reference 52

Java's Type System Evolution: Java 11 to Java 17 55

Switch Expressions 55

Sealed Classes 56

Records 57

Beyond Java 17: Project Valhalla 58

Performance Implications of the Current Type System 58

The Emergence of Value Classes: Implications for Memory Management 63

Redefining Generics with Primitive Support 64

Exploring the Current State of Project Valhalla 65

Early Access Release: Advancing Project Valhalla's Concepts 66

Use Case Scenarios: Bringing Theory to Practice 67

A Comparative Glance at Other Languages 67

Conclusion 68

# **3 From Monolithic to Modular Java: A Retrospective and Ongoing Evolution 69**

Introduction 69

Understanding the Java Platform Module System 70

Demystifying Modules 70

Modules Example 71

Compilation and Run Details 72

Introducing a New Module 73

From Monolithic to Modular: The Evolution of the JDK 78

Continuing the Evolution: Modular JDK in JDK 11 and Beyond 78

|                                                             |           |
|-------------------------------------------------------------|-----------|
| Implementing Modular Services with JDK 17                   | 78        |
| Service Provider                                            | 79        |
| Service Consumer                                            | 79        |
| A Working Example                                           | 80        |
| Implementation Details                                      | 81        |
| JAR Hell Versioning Problem and Jigsaw Layers               | 83        |
| Working Example: JAR Hell                                   | 85        |
| Implementation Details                                      | 86        |
| Open Services Gateway Initiative                            | 91        |
| OSGi Overview                                               | 91        |
| Similarities                                                | 91        |
| Differences                                                 | 92        |
| Introduction to Jdeps, Jlink, Jdeprscan, and Jmod           | 93        |
| Jdeps                                                       | 93        |
| Jdeprscan                                                   | 94        |
| Jmod                                                        | 95        |
| Jlink                                                       | 96        |
| Conclusion                                                  | 96        |
| Performance Implications                                    | 97        |
| Tools and Future Developments                               | 97        |
| Embracing the Modular Programming Paradigm                  | 97        |
| <b>4 The Unified Java Virtual Machine Logging Interface</b> | <b>99</b> |
| The Need for Unified Logging                                | 99        |
| Unification and Infrastructure                              | 100       |
| Performance Metrics                                         | 101       |
| Tags in the Unified Logging System                          | 101       |
| Log Tags                                                    | 101       |
| Specific Tags                                               | 102       |
| Identifying Missing Information                             | 102       |
| Diving into Levels, Outputs, and Decorators                 | 103       |
| Levels                                                      | 103       |
| Decorators                                                  | 104       |
| Outputs                                                     | 105       |
| Practical Examples of Using the Unified Logging System      | 107       |
| Benchmarking and Performance Testing                        | 108       |
| Tools and Techniques                                        | 108       |

|                                                                                                           |            |
|-----------------------------------------------------------------------------------------------------------|------------|
| Optimizing and Managing the Unified Logging System                                                        | 109        |
| Asynchronous Logging and the Unified Logging System                                                       | 110        |
| Benefits of Asynchronous Logging                                                                          | 110        |
| Implementing Asynchronous Logging in Java                                                                 | 110        |
| Best Practices and Considerations                                                                         | 111        |
| Understanding the Enhancements in JDK 11 and JDK 17                                                       | 113        |
| JDK 11                                                                                                    | 113        |
| JDK 17                                                                                                    | 113        |
| Conclusion                                                                                                | 113        |
| <b>5 End-to-End Java Performance Optimization: Engineering Techniques and Micro-benchmarking with JMH</b> | <b>115</b> |
| Introduction                                                                                              | 115        |
| Performance Engineering: A Central Pillar of Software Engineering                                         | 116        |
| Decoding the Layers of Software Engineering                                                               | 116        |
| Performance: A Key Quality Attribute                                                                      | 117        |
| Understanding and Evaluating Performance                                                                  | 117        |
| Defining Quality of Service                                                                               | 117        |
| Success Criteria for Performance Requirements                                                             | 118        |
| Metrics for Measuring Java Performance                                                                    | 118        |
| Footprint                                                                                                 | 119        |
| Responsiveness                                                                                            | 123        |
| Throughput                                                                                                | 123        |
| Availability                                                                                              | 124        |
| Digging Deeper into Response Time and Availability                                                        | 125        |
| The Mechanics of Response Time with an Application Timeline                                               | 126        |
| The Role of Hardware in Performance                                                                       | 128        |
| Decoding Hardware–Software Dynamics                                                                       | 129        |
| Performance Symphony: Languages, Processors, and Memory Models                                            | 131        |
| Enhancing Performance: Optimizing the Harmony                                                             | 132        |
| Memory Models: Deciphering Thread Dynamics and Performance Impacts                                        | 133        |
| Concurrent Hardware: Navigating the Labyrinth                                                             | 136        |
| Order Mechanisms in Concurrent Computing: Barriers, Fences, and Volatiles                                 | 138        |

|                                                                              |            |
|------------------------------------------------------------------------------|------------|
| Atomicity in Depth: Java Memory Model and <i>Happens-Before</i> Relationship | 139        |
| Concurrent Memory Access and Coherency in Multiprocessor Systems             | 141        |
| NUMA Deep Dive: My Experiences at AMD, Sun Microsystems, and Arm             | 141        |
| Bridging Theory and Practice: Concurrency, Libraries, and Advanced Tooling   | 145        |
| Performance Engineering Methodology: A Dynamic and Detailed Approach         | 145        |
| Experimental Design                                                          | 146        |
| Bottom-Up Methodology                                                        | 146        |
| Top-Down Methodology                                                         | 148        |
| Building a Statement of Work                                                 | 149        |
| The Performance Engineering Process: A Top-Down Approach                     | 150        |
| Building on the Statement of Work: Subsystems Under Investigation            | 151        |
| Key Takeaways                                                                | 158        |
| The Importance of Performance Benchmarking                                   | 158        |
| Key Performance Metrics                                                      | 159        |
| The Performance Benchmark Regime: From Planning to Analysis                  | 159        |
| Benchmarking JVM Memory Management: A Comprehensive Guide                    | 161        |
| Why Do We Need a Benchmarking Harness?                                       | 164        |
| The Role of the Java Micro-Benchmark Suite in Performance Optimization       | 165        |
| Getting Started with Maven                                                   | 166        |
| Writing, Building, and Running Your First Micro-benchmark in JMH             | 166        |
| Benchmark Phases: Warm-Up and Measurement                                    | 168        |
| Loop Optimizations and <code>@OperationsPerInvocation</code>                 | 169        |
| Benchmarking Modes in JMH                                                    | 170        |
| Understanding the Profilers in JMH                                           | 170        |
| Key Annotations in JMH                                                       | 171        |
| JVM Benchmarking with JMH                                                    | 172        |
| Profiling JMH Benchmarks with perfasm                                        | 174        |
| Conclusion                                                                   | 175        |
| <b>6 Advanced Memory Management and Garbage Collection in OpenJDK</b>        | <b>177</b> |
| Introduction                                                                 | 177        |
| Overview of Garbage Collection in Java                                       | 178        |

|                                                                                   |            |
|-----------------------------------------------------------------------------------|------------|
| Thread-Local Allocation Buffers and Promotion-Local Allocation Buffers            | 179        |
| Optimizing Memory Access with NUMA-Aware Garbage Collection                       | 181        |
| Exploring Garbage Collection Improvements                                         | 183        |
| G1 Garbage Collector: A Deep Dive into Advanced Heap Management                   | 184        |
| Advantages of the Regionalized Heap                                               | 186        |
| Optimizing G1 Parameters for Peak Performance                                     | 188        |
| Z Garbage Collector: A Scalable, Low-Latency GC for Multi-terabyte Heaps          | 197        |
| Future Trends in Garbage Collection                                               | 210        |
| Practical Tips for Evaluating GC Performance                                      | 212        |
| Evaluating GC Performance in Various Workloads                                    | 214        |
| Types of Transactional Workloads                                                  | 214        |
| Synthesis                                                                         | 215        |
| Live Data Set Pressure                                                            | 216        |
| Understanding Data Lifespan Patterns                                              | 216        |
| Impact on Different GC Algorithms                                                 | 217        |
| Optimizing Memory Management                                                      | 217        |
| <b>7 Runtime Performance Optimizations: A Focus on Strings, Locks, and Beyond</b> | <b>219</b> |
| Introduction                                                                      | 219        |
| String Optimizations                                                              | 220        |
| Literal and Interned String Optimization in HotSpot VM                            | 221        |
| String Deduplication Optimization and G1 GC                                       | 223        |
| Reducing Strings' Footprint                                                       | 224        |
| Enhanced Multithreading Performance: Java Thread Synchronization                  | 236        |
| The Role of Monitor Locks                                                         | 238        |
| Lock Types in OpenJDK HotSpot VM                                                  | 238        |
| Code Example and Analysis                                                         | 239        |
| Advancements in Java's Locking Mechanisms                                         | 241        |
| Optimizing Contention: Enhancements since Java 9                                  | 243        |
| Visualizing Contended Lock Optimization: A Performance Engineering Exercise       | 245        |
| Synthesizing Contended Lock Optimization: A Reflection                            | 256        |
| Spin-Wait Hints: An Indirect Locking Improvement                                  | 257        |

|                                                                                   |            |
|-----------------------------------------------------------------------------------|------------|
| Transitioning from the Thread-per-Task Model to More Scalable Models              | 259        |
| Traditional One-to-One Thread Mapping                                             | 260        |
| Increasing Scalability with the Thread-per-Request Model                          | 261        |
| Reimagining Concurrency with Virtual Threads                                      | 265        |
| Conclusion                                                                        | 270        |
| <b>8 Accelerating Time to Steady State with OpenJDK HotSpot VM</b>                | <b>273</b> |
| Introduction                                                                      | 273        |
| JVM Start-up and Warm-up Optimization Techniques                                  | 274        |
| Decoding Time to Steady State in Java Applications                                | 274        |
| Ready, Set, Start up!                                                             | 274        |
| Phases of JVM Start-up                                                            | 275        |
| Reaching the Application's Steady State                                           | 276        |
| An Application's Life Cycle                                                       | 278        |
| Managing State at Start-up and Ramp-up                                            | 278        |
| State During Start-up                                                             | 278        |
| Transition to Ramp-up and Steady State                                            | 281        |
| Benefits of Efficient State Management                                            | 281        |
| Class Data Sharing                                                                | 282        |
| Ahead-of-Time Compilation                                                         | 283        |
| GraalVM: Revolutionizing Java's Time to Steady State                              | 290        |
| Emerging Technologies: CRIU and Project CRaC for Checkpoint/Restore Functionality | 292        |
| Start-up and Ramp-up Optimization in Serverless and Other Environments            | 295        |
| Serverless Computing and JVM Optimization                                         | 296        |
| Containerized Environments: Ensuring Swift Start-ups and Efficient Scaling        | 297        |
| GraalVM's Present-Day Contributions                                               | 298        |
| Key Takeaways                                                                     | 298        |
| Boosting Warm-up Performance with OpenJDK HotSpot VM                              | 300        |
| Compiler Enhancements                                                             | 300        |
| Segmented Code Cache and Project Leyden Enhancements                              | 303        |
| The Evolution from PermGen to Metaspace: A Leap Forward Toward Peak Performance   | 304        |
| Conclusion                                                                        | 306        |

# 9 Harnessing Exotic Hardware: The Future of JVM Performance Engineering 307

Introduction to Exotic Hardware and the JVM 307

Exotic Hardware in the Cloud 309

Hardware Heterogeneity 310

API Compatibility and Hypervisor Constraints 310

Performance Trade-offs 311

Resource Contention 311

Cloud-Specific Limitations 311

The Role of Language Design and Toolchains 312

Case Studies 313

LWJGL: A Baseline Example 314

Aparapi: Bridging Java and OpenCL 317

Project Sumatra: A Significant Effort 321

TornadoVM: A Specialized JVM for Hardware Accelerators 324

Project Panama: A New Horizon 327

Envisioning the Future of JVM and Project Panama 333

High-Level JVM-Language APIs and Native Libraries 333

Vector API and Vectorized Data Processing Systems 334

Accelerator Descriptors for Data Access, Caching, and Formatting 335

The Future Is Already Knocking at the Door! 335

Concluding Thoughts: The Future of JVM Performance Engineering 336

**Index 337**

## Preface

Welcome to my guide to JVM performance engineering, distilled from more than 20 years of expertise as a Java Champion and performance engineer. Within these pages lies a journey through the evolution of the JVM—a narrative that unfolds Java's robust capabilities and architectural prowess. This book meticulously navigates the intricacies of JVM internals and the art and science of performance engineering, examining everything from the inner workings of the HotSpot VM to the strategic adoption of modular programming. By asserting Java's pivotal role in modern computing—from server environments to the integration with exotic hardware—it stands as a beacon for practitioners and enthusiasts alike, heralding the next frontier in JVM performance engineering.

### Intended Audience

This book is primarily written for Java developers and software engineers who are keen to enhance their understanding of JVM internals and performance tuning. It will also greatly benefit system architects and designers, providing them with insights into JVM's impact on system performance. Performance engineers and JVM tuners will find advanced techniques for optimizing JVM performance. Additionally, computer science and engineering students and educators will gain a comprehensive understanding of JVM's complexities and advanced features.

With the hope of furthering education in performance engineering, particularly with a focus on the JVM, this text also aligns with advanced courses on programming languages, algorithms, systems, computer architectures, and software engineering. I am passionate about fostering a deeper understanding of these concepts and excited about contributing to coursework that integrates the principles of JVM performance engineering and prepares the next generation of engineers with the knowledge and skills to excel in this critical area of technology.

Focusing on the intricacies and strengths of the language and runtime, this book offers a thorough dissection of Java's capabilities in concurrency, its strengths in multithreading, and the sophisticated memory management mechanisms that drive peak performance across varied environments.

### Book Organization

**Chapter 1, "The Performance Evolution of Java: The Language and the Virtual Machine,"** expertly traces Java's journey from its inception in the mid-1990s to the sophisticated advancements in Java 17. Highlighting Java's groundbreaking runtime environment, complete with the JVM, expansive class libraries, and a formidable set of tools, the chapter sets the stage for Java's innovative advancements, underlying technical excellence, continuous progress, and flexibility.

Key highlights include an examination of the OpenJDK HotSpot VM's transformative garbage collectors (GCs) and streamlined Java bytecode. This section illustrates Java's dedication to

performance, showcasing advanced JIT compilation and avant-garde optimization techniques. Additionally, the chapter explores the synergistic relationship between the HotSpot VM's client and server compilers, and their dynamic optimization capabilities, demonstrating Java's continuous pursuit of agility and efficiency.

Another focal point is the exploration of OpenJDK's memory management with the HotSpot GCs, particularly highlighting the adoption of the "weak generational hypothesis." This concept underpins the efficiency of collectors in HotSpot, employing parallel and concurrent GC threads as needed, ensuring peak memory optimization and application responsiveness.

The chapter maintains a balance between technical depth and accessibility, making it suitable for both seasoned Java developers and those new to the language. Practical examples and code snippets are interspersed to provide a hands-on understanding of the concepts discussed.

**Chapter 2, "Performance Implications of Java's Type System Evolution,"** seamlessly continues from the performance focus of Chapter 1, delving into the heart of Java: its evolving type system. The chapter explores Java's foundational elements—primitive and reference types, interfaces, classes, and arrays—that anchored Java programming prior to Java SE 5.0.

The narrative continues with the transformative enhancements from Java SE 5.0 onward, such as the introduction of generics, annotations, and VarHandle type reference—all further enriching the language. The chapter spotlights recent additions such as switch expressions, sealed classes, and the much-anticipated records.

Special attention is given to Project Valhalla's ongoing work, examining the performance nuances of the existing type system and the potential of future value classes. The section offers insights into Project Valhalla's ongoing endeavors, from refined generics to the conceptualization of classes for basic primitives.

Java's type system is more than just a set of types—it's a reflection of Java's commitment to versatility, efficiency, and innovation. The goal of this chapter is to illuminate the type system's past, present, and promising future, fostering a profound understanding of its intricacies.

**Chapter 3, "From Monolithic to Modular Java: A Retrospective and Ongoing Evolution,"** provides extensive coverage of the Java Platform Module System (JPMS) and its breakthrough impact on modular programming. This chapter marks Java's bold transition into the modular era, beginning with a fundamental exploration of modules. It offers hands-on guidance through the creation, compilation, and execution of modules, making it accessible even to newcomers in this domain.

Highlighting Java's transition from a monolithic JDK to a modular framework, the chapter reflects Java's adaptability to evolving needs and its commitment to innovation. A standout section of this chapter is the practical implementation of modular services using JDK 17, which navigates the intricacies of module interactions, from service providers to consumers, enriched by working examples. The chapter addresses key concepts like encapsulation of implementation details and the challenges of JAR hell, illustrating how Jigsaw layers offer elegant solutions in the modular landscape.

Further enriching this exploration, the chapter draws insightful comparisons with OSGi, spotlighting the parallels and distinctions, to give readers a comprehensive understanding of Java's

modular systems. The introduction of essential tools such as *jdeps*, *jlink*, *jdeprscan*, and *jmod*, integral to the modular ecosystem, is accompanied by thorough explanations and practical examples. This approach empowers readers to effectively utilize these tools in their developmental work.

Concluding with a reflection on the performance nuances of JPMS, the chapter looks forward to the future of Java's modular evolution, inviting readers to contemplate its potential impacts and developments.

**Chapter 4, "The Unified Java Virtual Machine Logging Interface,"** delves into the vital yet often underappreciated world of logs in software development. It begins by underscoring the necessity of a unified logging system in Java, addressing the challenges posed by disparate logging systems and the myriad benefits of a cohesive approach. The chapter not only highlights the unification and infrastructure of the logging system but also emphasizes its role in monitoring performance and optimization.

The narrative explores the vast array of log tags and their specific roles, emphasizing the importance of creating comprehensive and insightful logs. In tackling the challenges of discerning any missing information, the chapter provides a lucid understanding of log levels, outputs, and decorators. The intricacies of these features are meticulously examined, with practical examples illuminating their application in tangible scenarios.

A key aspect of this chapter is the exploration of asynchronous logging, a critical feature for enhancing log performance with minimal impact on application efficiency. This feature is essential for developers seeking to balance comprehensive logging with system performance.

Concluding the chapter, the importance of logs as a diagnostic tool is emphasized, showcasing their role in both proactive system monitoring and reactive problem-solving. Chapter 4 not only highlights the power of effective logging in Java, but also underscores its significance in building and maintaining robust applications. This chapter reinforces the theme of Java's ongoing evolution, showcasing how advancements in logging contribute significantly to the language's capability and versatility in application development.

**Chapter 5, "End-to-End Java Performance Optimization: Engineering Techniques and Microbenchmarking with JMH,"** focuses on the essence of performance engineering within the Java ecosystem. Emphasizing that performance transcends mere speed, this chapter highlights its critical role in crafting an unparalleled user experience. It commences with a formative exploration of performance engineering's pivotal role within the broader software development realm, highlighting its status as a fundamental quality attribute and unraveling its multifaceted layers.

With precision, the chapter delineates the metrics pivotal to gauging Java's performance, encompassing aspects from footprint to the nuances of availability, ensuring readers grasp the full spectrum of performance dynamics. Stepping in further. It explores the intricacies of response time and its symbiotic relationship with availability. This inspection provides insights into the mechanics of application timelines, intricately weaving the narrative of response time, throughput, and the inevitable pauses that punctuate them.

Yet, the performance narrative is only complete by acknowledging the profound influence of hardware. This chapter decodes the symbiotic relationship between hardware and software,

emphasizing the harmonious symphony that arises from the confluence of languages, processors, and memory models. From the subtleties of memory models and their bearing on thread dynamics to the foundational principles of Java Memory Model, this chapter journeys through the maze of concurrent hardware, shedding light on the order mechanisms pivotal to concurrent computing.

Moving beyond theoretical discussions, this chapter draws on over two decades of hands-on experience in performance optimization. It introduces a systematic approach to performance diagnostics and analysis, offering insights into methodologies and a detailed investigation of subsystems and approaches to identifying potential performance issues. The methodologies are not only vital for software developers focused on performance optimization but also provide valuable insights into the intricate relationship between underlying hardware, software stacks, and application performance.

The chapter emphasizes the importance of a structured benchmarking regime, encompassing everything from memory management to the assessment of feature releases and system layers. This sets the stage for the Java Micro-Benchmark Suite (JMH), the *pièce de résistance* of JVM benchmarking. From its foundational setup to the intricacies of its myriad features, the journey encompasses the genesis of writing benchmarks, to their execution, enriched with insights into benchmarking modes, profilers, and JMH's pivotal annotations.

Chapter 5 thus serves as a comprehensive guide to end-to-end Java performance optimization and as a launchpad for further chapters. It inspires a fervor for relentless optimization and arms readers with the knowledge and tools required to unlock Java's unparalleled performance potential.

Memory management is the silent guardian of Java applications, often operating behind the scenes but crucial to their success. **Chapter 6, "Advanced Memory Management and Garbage Collection in OpenJDK,"** marks a deep dive into specialized JVM improvements, showcasing advanced performance tools and techniques. This chapter offers a leap into the world of garbage collection, unraveling the techniques and innovations that ensure Java applications run efficiently and effectively.

The chapter commences with a foundational overview of garbage collection in Java, setting the stage for the detailed exploration of Thread-Local Allocation Buffers (TLABs) and Promotion Local Allocation Buffers (PLABs), and elucidating their pivotal roles in memory management. As we progress, the chapter sheds light on optimizing memory access, emphasizing the significance of the NUMA-aware garbage collection and its impact on performance.

The highlight of this chapter lies in its exploration of advanced garbage collection techniques. The narrative reviews the G1 Garbage Collector (G1 GC), unraveling its revolutionary approach to heap management. From grasping the advantages of a regionalized heap to optimizing G1 GC parameters for peak performance, this section promises a holistic cognizance of one of Java's most advanced garbage collectors. Additionally, the Z Garbage Collector (ZGC) is presented as a technological marvel with its adaptive optimization techniques, and the advancements that make it a game-changer in real-time applications.

This chapter also offers insights into the emerging trends in garbage collection, setting the stage for what lies ahead. Practicality remains at the forefront, with a dedicated section offering invaluable tips for evaluating GC performance. From sympathizing with various workloads, such as Online Analytical Processing (OLAP) to Online Transaction Processing (OLTP) and Hybrid Transactional/Analytical Processing (HTAP), to synthesizing live data set pressure and data lifespan patterns, the chapter equips readers with the apparatus and knowledge to optimize memory management effectively. This chapter is an accessible guide to advanced garbage collection techniques that Java professionals need to navigate the topography of memory management.

**Chapter 7, “Runtime Performance Optimizations: A Focus on Strings, Locks, and Beyond,”** is dedicated to exploring the critical facets of Java’s runtime performance, particularly in the realms of string handling and lock synchronization—two areas essential for efficient application performance.

The chapter excels at taking a comprehensive approach to demystifying these JVM optimizations through detailed under-the-hood analysis—utilizing a range of profiling techniques, from bytecode analysis to memory and sample-based profiling to gathering call stack views of profiled methods—to enrich the reader’s understanding. Additionally, the chapter leverages JMH benchmarking to highlight the tangible improvements such optimizations bring. The practical use of *async-profiler* for method-level insights and NetBeans memory profiler further enhances the reader’s granular understanding of the JVM enhancements. This chapter aims to test and illuminate the optimizations, equipping readers with a comprehensive approach to using these tools effectively, thereby building on the performance engineering methodologies and processes discussed in Chapter 5.

The journey continues with an extensive review of the string optimizations in Java, highlighting major advancements across various Java versions, and then shifts focus onto enhanced multithreading performance, highlighting Java’s thread synchronization mechanisms.

Further, the chapter helps navigate the world of concurrency, with discussion of the transition from the thread-per-task model to the scalable thread-per-request model. The examination of Java’s Executor Service, ThreadPools, ForkJoinPool framework, and CompletableFuture ensures a robust comprehension of Java’s concurrency mechanisms.

The chapter concludes with a glimpse into the future of concurrency in Java with virtual threads. From understanding virtual threads and their carriers to discussing parallelism and integration with existing APIs, this chapter is a practical guide to advanced concurrency mechanisms and string optimizations in Java.

**Chapter 8, “Accelerating Time to Steady State with OpenJDK HotSpot VM,”** is dedicated to optimizing start-up to steady-state performance, crucial for transient applications such as containerized environments, serverless architectures, and microservices. The chapter emphasizes the importance of minimizing JVM start-up and warm-up time to enhance efficient execution, incorporating a pivotal exploration into GraalVM’s revolutionary role in this domain.

The narrative dissects the phases of JVM start-up and the journey to an application’s steady-state, highlighting the significance of managing state during these phases across various

architectures. An in-depth look at Class Data Sharing (CDS) sheds light on shared archive files and memory mapping, underscoring the advantages in multi-instance setups. The narrative then shifts to ahead-of-time (AOT) compilation, contrasting it with just-in-time (JIT) compilation and detailing the transformative impact of HotSpot VM's Project Leyden and its forecasted ability to manage states via CDS and AOT. This sets the stage for GraalVM and its revolutionary impact on Java's performance landscape. By harnessing advanced optimization techniques, including static images and dynamic compilation, GraalVM enhances performance for a wide array of applications. The exploration of cutting-edge technologies like GraalVM alongside a holistic survey of OpenJDK projects such as CRU and CraC, which introduce groundbreaking checkpoint/restore functionality, adds depth to the discussion. This comprehensive coverage provides insights into the evolving strategies for optimizing Java applications, making this chapter an invaluable resource for developers looking to navigate today's cloud native environments.

The final chapter, **Chapter 9, "Harnessing Exotic Hardware: The Future of JVM Performance Engineering,"** focuses on the fascinating intersection of exotic hardware and the JVM, illuminating its galvanizing impact on performance engineering. This chapter begins with an introduction to the increasingly prominent world of exotic hardware, particularly within cloud environments. It explores the integration of this hardware with the JVM, underscoring the pivotal role of language design and toolchains in this process.

Through a series of carefully detailed case studies, the chapter showcases the real-world applications and challenges of integrating such hardware accelerators. From the Lightweight Java Game Library (LWJGL), to the innovative Aparapi, which bridges Java and OpenCL, each study offers valuable insights into the complexities and triumphs of these integrations. The chapter also examines Project Sumatra's significant contributions to this realm and introduces TornadoVM, a specialized JVM tailored for hardware accelerators.

Through these case studies, the symbiotic potential of integrating exotic hardware with the JVM becomes increasingly evident, leading up to an overview of Project Panama, heralding a new horizon in JVM performance engineering. At the heart of Project Panama lies the Vector API, a symbol of innovation designed for vector computations. This API is not just about computations—it's about ensuring they are efficiently vectorized and tailored for hardware that thrives on vector operations. This ensures that developers have the tools to express parallel computations optimized for diverse hardware architectures. But Panama isn't just about vectors. The Foreign Function and Memory API emerges as a pivotal tool, a bridge that allows Java to converse seamlessly with native libraries. This is Java's answer to the age-old challenge of interoperability, ensuring Java applications can interface effortlessly with native code, breaking language barriers.

Yet, the integration is no walk in the park. From managing intricate memory access patterns to deciphering hardware-specific behaviors, the path to optimization is laden with complexities. But these challenges drive innovation, pushing the boundaries of what's possible. Looking to the future, the chapter showcases my vision of Project Panama as the gold standard for JVM interoperability. The horizon looks promising, with Panama poised to redefine performance and efficiency for Java applications.

This isn't just about the present or the imminent future. The world of JVM performance engineering is on the cusp of a revolution. Innovations are knocking at our door, waiting to be embraced—with Tornado VM's Hybrid APIs, and with HAT toolkit and Project Babylon on the horizon.

### How to Use This Book

1. *Sequential Reading for Comprehensive Understanding*: This book is designed to be read from beginning to end, as each chapter builds upon the knowledge of the previous ones. This approach is especially recommended for readers new to JVM performance engineering.
2. *Modular Approach for Specific Topics*: Experienced readers may prefer to jump directly to chapters that address their specific interests or challenges. The table of contents and index can guide you to relevant sections.
3. *Practical Examples and Code*: Throughout the book, practical examples and code snippets are provided to illustrate key concepts. To get the most out of these examples, readers are encouraged to build on and run the code themselves. (See item 5.)
4. *Visual Aids for Enhanced Understanding*: In addition to written explanations, this book employs a variety of textual and visual aids to deepen your understanding.
  - a. *Case Studies*: Real-world scenarios that demonstrate the application of JVM performance techniques.
  - b. *Screenshots*: Visual outputs depicting profiling results as well as various GC plots, which are essential for understanding the GC process and phases.
  - c. *Use-Case Diagrams*: Visual representations that map out the system's functional requirements, showing how different entities interact with each other.
  - d. *Block Diagrams*: Illustrations that outline the architecture of a particular JVM or system component, highlighting performance features.
  - e. *Class Diagrams*: Detailed object-oriented designs of various code examples, showing relationships and hierarchies.
  - f. *Process Flowcharts*: Step-by-step diagrams that walk you through various performance optimization processes and components.
  - g. *Timelines*: Visual representations of the different phases or state changes in an activity and the sequence of actions that are taken.
5. *Utilizing the Companion GitHub Repository*: A significant portion of the book's value lies in its practical application. To facilitate this, I have created JVM Performance Engineering GitHub Repository (<https://github.com/mo-beck/JVM-Performance-Engineering>). Here, you will find
  - a. *Complete Code Listings*: All the code snippets and scripts mentioned in the book are available. This allows you to see the code and experiment with it. Use it as a launchpad for your projects and fork and improve it.
  - b. *Additional Resources and Updates*: The field of JVM Performance Engineering is ever evolving. The repository will be periodically updated with new scripts, resources, and information to keep you abreast of the latest developments.
  - c. *Interactive Learning*: Engage with the material by cloning the repository, running the GC scripts against your GC log files, and modifying them to see how outcomes better suit your GC learning and understanding journey.

6. *Engage with the Community:* I encourage readers to engage with the wider community. Use the GitHub repository to contribute your ideas, ask questions, and share your insights. This collaborative approach enriches the learning experience for everyone involved.
7. *Feedback and Suggestions:* Your feedback is invaluable. If you have suggestions, corrections, or insights, I warmly invite you to share them. You can provide feedback via the GitHub repository, via email ([jvmbook@codekaram.com](mailto:jvmbook@codekaram.com)), or via social media platforms (<https://www.linkedin.com/in/monicabeckwith/> or <https://twitter.com/JVMPerfEngineer>).

---

*In Java's vast realm, my tale takes wing,  
A narrative so vivid, of wonders I sing.  
Distributed systems, both near and afar,  
With JVM shining—the brightest star!*

*Its rise through the ages, a saga profound,  
With each chronicle, inquiries resound.  
“Where lies the wisdom, the legends so grand?”  
They ask with a fervor, eager to understand.*

*This book is a beacon for all who pursue,  
A tapestry of insights, both aged and new.  
In chapters that flow, like streams to the seas,  
I share my heart's journey, my tech odyssey.*

—Monica Beckwith

Register your copy of *JVM Performance Engineering* on the InformIT site for convenient access to updates and/or corrections as they become available. To start the registration process, go to [informit.com/register](https://www.informit.com/register) and log in or create an account. Enter the product ISBN (9780134659879) and click Submit. If you would like to be notified of exclusive offers on new editions and updates, please check the box to receive email from us.

### Acknowledgments

Reflecting on the journey of creating this book, my heart is full of gratitude for the many individuals whose support, expertise, and encouragement have been the wind beneath my wings.

At the forefront of my gratitude is my family—the unwavering pillars of support. To my husband, Ben: Your understanding and belief in my work, coupled with your boundless love and care, have been the bedrock of my perseverance.

To my children, Annika and Bodin: Your patience and resilience have been my inspiration. Balancing the demands of a teen's life with the years it took to bring this book to fruition, you have shown a maturity and understanding well beyond your years. Your support, whether it be a kind word at just the right moment or understanding my need for quiet as I wrestled with complex ideas, has meant more to me than words can express. Your unwavering faith, even when my work required sacrifices from us all, has been a source of strength and motivation. I am incredibly proud of the kind and supportive individuals you are becoming, and I hope this book reflects the values we cherish as a family.

### Editorial Guidance

A special word of thanks goes to my executive editor at Pearson, Greg Doench, whose patience has been nothing short of saintly. Over the years, through health challenges, the dynamic nature of JVM release cycles and project developments, and the unprecedented times of COVID, Greg has been a beacon of encouragement. His unwavering support and absence of frustration in the face of my tardiness have been nothing less than extraordinary. Greg, your steadfast presence and guidance have not only helped shape this manuscript but have also been a personal comfort.

### Chapter Contributions

The richness of this book's content is a culmination of my extensive work, research, and insights in the field, enriched further by the invaluable contributions of various experts, colleagues, collaborators, and friends. Their collective knowledge, feedback, and support have been instrumental in adding depth and clarity to each topic discussed, reflecting years of dedicated expertise in this domain.

- In Chapter 3, Nikita Lipski's deep experience in Java modularity added compelling depth, particularly on the topics of the JAR hell versioning issues, layers, and his remarkable insights on OSGi.
- Stefano Doni's enriched field expertise in Quality of Service (QoS), performance stack, and theoretical expertise in operational laws and queueing, significantly enhanced Chapter 5, bringing a blend of theoretical and practical perspectives.
- The insights and collaborative interactions with Per Liden and Stefan Karlsson were crucial in refining my exploration of the Z Garbage Collector (ZGC) in Chapter 6. Per's

- numerous talks and blog posts have also been instrumental in helping the community understand the intricacies of ZGC in greater detail.
- Chapter 7 benefitted from the combined insights of Alan Bateman and Heinz Kabutz. Alan was instrumental in helping me refine this chapter's coverage of Java's locking mechanisms and virtual threads. His insights helped clarify complex concepts, added depth to the discussion of monitor locks, and provided valuable perspective on the evolution of Java's concurrency model. Heinz's thorough review ensured the relevance and accuracy of the content.
- For Chapter 8, Ludovic Henry's insistence on clarity with respect to the various terminologies and persistence to include advanced topics and Alina Yurenko's insights into GraalVM and its future developments provided depth and foresight and reshaped the chapter to its glorious state today.

Alina has also influenced me to track the developments in GraalVM—especially the introduction of layered native images, which promises to reduce build times and enable sharing of base images.

- Last but not the least, for Chapter 9, I am grateful to Gary Frost for his thorough review of Aparapi, Project Sumatra, and insights on leveraging the latest JDK (early access) version for developing projects like Project Panama. Dr. Juan Fumero's leadership in the development of TornadoVM and insights into parallel programming challenges have been instrumental in providing relevant insights for my chapter, deepening its clarity, and enhancing its narrative.

It was a revelation to see our visions converge and witness these industry stalwarts drive the enhancements in the integration of Java with modern hardware accelerators.

### Mentors, Influencers, and Friends

Several mentors, leaders, and friends have significantly influenced my broader understanding of technology:

- Charlie Hunt's guidance in my GC performance engineering journey has been foundational. His groundbreaking work on String density has inspired many of my own approaches with methodologies and process. His seminal work *Java Performance* is an essential resource for all performance enthusiasts and is highly recommended for its depth and insight.
- Gil Tene's work on the C4 Garbage Collector and his educational contributions have deeply influenced my perspective on low pause collectors and their interactive nature. I value our check-ins, which I took as mentorship opportunities to learn from one of the brightest minds.
- Thomas Schatzl's generous insights on the G1 Garbage Collector have added depth and context to this area of study, enriching my understanding following my earlier work on G1 GC. Thomas is a GC performance expert whose work, including on Parallel GC, continues to inspire me.

- Vladimir Kozlov's leadership and work in various aspects of the HotSpot JVM have been crucial in pushing the boundaries of Java's performance capabilities. I cherish our work together on prefetching, tiered thresholds, various code generation, and JVM optimizations, and I appreciate his dedication to HotSpot VM.
- Kirk Pepperdine, for our ongoing collaborations that span from the early days of developing G1 GC parser scripts for our joint hands-on lab sessions at JavaOne, to our recent methodologies, processes, and benchmarking endeavors at Microsoft, continuously pushes the envelope in performance engineering.
- Sergey Kuksenko and Alexey Shipilev, along with my fellow JVM performance engineering experts, have been my comrades in relentless pursuit of Java performance optimizations.
- Erik Österlund's development of generational ZGC represents an exciting and forward-looking aspect of garbage collection technology.
- John Rose, for his unparalleled expertise in JVM internals and his pivotal role in the evolution of Java as a language and platform. His vision and deep technical knowledge have not only propelled the field forward but also provided me with invaluable insights throughout my career.

Each of these individuals has not only contributed to the technical depth and richness of this book but also played a vital role in my personal and professional growth. Their collective wisdom, expertise, and support have been instrumental in shaping both the content and the journey of this book, reflecting the collaborative spirit of the Java community.

*This page intentionally left blank*

### About the Author

**Monica Beckwith** is a leading figure in Java Virtual Machine (JVM) performance tuning and optimizations. With a strong Electrical and Computer Engineering academic foundation, Monica has carved out an illustrious, impactful, and inspiring professional journey.

At Advanced Micro Devices (AMD), Monica refined her expertise in Java, JVM, and systems performance engineering. Her work brought critical insights to NUMA's architectural enhancements, improving both hardware and JVM performance through optimized code generation, improved footprint and advanced JVM techniques, and memory management. She continued her professional growth at Sun Microsystems, contributing significantly to JVM performance enhancements across Sun SPARC, Solaris, and Linux, aiding in the evolution of a scalable Java ecosystem.

Monica's role as a Java Champion and coauthor of *Java Performance Companion*, as well as authoring this current book, highlight her steadfast commitment to the Java community. Notably, her work in the optimization of G1 Garbage Collector went beyond optimization; she delved into diagnosing pain points, fine-tuning processes, and identifying critical areas for enhancement, thereby setting new precedents in JVM performance. Her expertise not only elevated the efficiency of the G1 GC but also showcased her intricate knowledge of JVM's complexities. At Arm, as a managed runtimes performance architect, Monica played a key role in shaping a unified strategy for the Arm ecosystem, fostering a competitive edge for performance on Arm-based servers.

Monica's significant contributions and thought leadership have enriched the broader tech community. Monica serves on the program committee for various prestigious conferences and hosts JVM and performance-themed tracks, further emphasizing her commitment to knowledge sharing and community building.

At Microsoft, Monica's expertise shines brightly as she optimizes JVM-based workloads, applications, and key services, across a diverse range of deployment scenarios, from bare metal to sophisticated Azure VMs. Her deep-seated understanding of hardware and software engineering, combined with her adeptness in systems engineering and benchmarking principles, uniquely positions her at the critical juncture of the hardware and software. This position enables her to significantly contribute to the performance, scalability and power efficiency characterization, evaluation, and analysis of both current and emerging hardware systems within the Azure Compute infrastructure.

Beyond her technical prowess, Monica embodies values that resonate deeply with those around her. She is a beacon of integrity, authenticity, and continuous learning. Her belief in the transformative power of actions, the sanctity of reflection, and the profound impact of empathy defines her interactions and approach. A passionate speaker, Monica's commitment to lifelong learning is evident in her zeal for delivering talks and disseminating knowledge.

Outside the confines of the tech world, Monica's dedication extends to nurturing young minds as a First Lego League coach. This multifaceted persona, combined with her roles as a Java Champion, author, and performance engineer at Microsoft, cements her reputation as a respected figure in the tech community and a source of inspiration for many.

*This page intentionally left blank*

# Chapter 1The Performance Evolution of Java: The Language and the Virtual Machine

More than three decades ago, the programming languages landscape was largely defined by C and its object-oriented extension, C++. In this period, the world of computing was undergoing a significant shift from large, cumbersome mainframes to smaller, more efficient minicomputers. C, with its suitability for Unix systems, and C++, with its innovative introduction of classes for object-oriented design, were at the forefront of this technological evolution.

However, as the industry started to shift toward more specialized and cost-effective systems, such as microcontrollers and microcomputers, a new set of challenges emerged. Applications were ballooning in terms of lines of code, and the need to “port” software to various platforms became an increasingly pressing concern. This often necessitated rewriting or heavily modifying the application for each specific target, a labor-intensive and error-prone process. Developers also faced the complexities of managing numerous static library dependencies and the demand for lightweight software on embedded systems—areas where C++ fell short.

It was against this backdrop that Java emerged in the mid-1990s. Its creators aimed to fill this niche by offering a “write once, run anywhere” solution. But Java was more than just a programming language. It introduced its own runtime environment, complete with a virtual machine (Java Virtual Machine [JVM]), class libraries, and a comprehensive set of tools. This all-encompassing ecosystem, known as the Java Development Kit (JDK), was designed to tackle the challenges of the era and set the stage for the future of programming. Today, more than a quarter of a century later, Java’s influence in the world of programming languages remains strong, a testament to its adaptability and the robustness of its design.

The performance of applications emerged as a critical factor during this time, especially with the rise of large-scale, data-intensive applications. The evolution of Java’s runtime system has played a pivotal role in addressing these performance challenges. Thanks to the optimization in generics, autoboxing and unboxing, and enhancements to the concurrency utilities, Java applications have seen significant improvements in both performance and scalability. Moreover, the changes have had far-reaching implications for the performance of the JVM itself. In

particular, the JVM has had to adapt and optimize its execution strategies to efficiently handle these new language features. As you read this book, bear in mind the historical context and the driving forces that led to Java's inception. The evolution of Java and its virtual machine have profoundly influenced the way developers write and optimize software for various platforms.

In this chapter, we will thoroughly examine the history of Java and JVM, highlighting the technological advancements and key milestones that have significantly shaped its development. From its early days as a solution for platform independence, through the introduction of new language features, to the ongoing improvements to the JVM, Java has evolved into a powerful and versatile tool in the arsenal of modern software development.

### A New Ecosystem Is Born

In the 1990s, the internet was emerging, and web pages became more interactive with the introduction of Java applets. Java applets were small applications that ran within web browsers, providing a “real-time” experience for end users.

Applets were not only platform independent but also “secure,” in the sense that the user needed to trust the applet writer. When discussing security in the context of the JVM, it's essential to understand that direct access to memory should be forbidden. As a result, Java introduced its own memory management system, called the garbage collector (GC).

**NOTE** In this book, the acronym GC is used to refer to both *garbage collection*, the process of automatic memory management, and *garbage collector*, the module within the JVM that performs this process. The specific meaning will be clear based on the context in which GC is used.

Additionally, an abstraction layer, known as Java bytecode, was added to any executable. Java applets quickly gained popularity because their bytecode, residing on the web server, would be transferred and executed as its own process during web page rendering. Although the Java bytecode is platform independent, it is interpreted and compiled into native code specific to the underlying platform.

### A Few Pages from History

The JDK included tools such as a Java compiler that translated Java code into Java bytecode. Java bytecode is the executable handled by the Java Runtime Environment (JRE). Thus, for different environments, only the runtime needed to be updated. As long as a JVM for a specific environment existed, the bytecode could be executed. The JVM and the GC served as the execution engines. For Java versions 1.0 and 1.1, the bytecode was interpreted to the native machine code, and there was no dynamic compilation.

Soon after the release of Java versions 1.0 and 1.1, it became apparent that Java needed to be more performant. Consequently, a just-in-time (JIT) compiler was introduced in Java 1.2. When

combined with the JVM, it provided dynamic compilation based on hot methods and loop-back branch counts. This new VM was called the Java HotSpot VM.

### Understanding Java HotSpot VM and Its Compilation Strategies

The Java HotSpot VM plays a critical role in executing Java programs efficiently. It includes JIT compilation, tiered compilation, and adaptive optimization to improve the performance of Java applications.

### The Evolution of the HotSpot Execution Engine

The HotSpot VM performs *mixed-mode* execution, which means that the VM starts in interpreted mode, with the bytecode being converted into native code based on a description table. The table has a template of native code corresponding to each bytecode instruction known as the *TemplateTable*; it is just a simple lookup table. The execution code is stored in a code cache (known as *CodeCache*). *CodeCache* stores native code and is also a useful cache for storing JIT-ted code.

**NOTE** HotSpot VM also provides an interpreter that doesn't need a template, called the C++ interpreter. Some OpenJDK ports<sup>1</sup> choose this route to simplify porting of the VM to non-x86 platforms.

### Performance-Critical Methods and Their Optimization

Performance engineering is a critical aspect of software development, and a key part of this process involves identifying and optimizing performance-critical methods. These methods are frequently executed or contain performance-sensitive code, and they stand to gain the most from JIT compilation. Optimizing performance-critical methods is not just about choosing appropriate data structures and algorithms; it also involves identifying and optimizing the methods based on their frequency of invocation, size and complexity, and available system resources.

Consider the following `BookProgress` class as an example:

---

```
import java.util.*;

public class BookProgress {
    private String title;
    private Map<String, Integer> chapterPages;
    private Map<String, Integer> chapterPagesWritten;

    public BookProgress(String title) {
        this.title = title;
    }
}
```

---

<sup>1</sup><https://wiki.openjdk.org/pages/viewpage.action?pageId=13729802>

```

        this.chapterPages = new HashMap<>();
        this.chapterPagesWritten = new HashMap<>();
    }

    public void addChapter(String chapter, int totalPages) {
        this.chapterPages.put(chapter, totalPages);
        this.chapterPagesWritten.put(chapter, 0);
    }

    public void updateProgress(String chapter, int pagesWritten) {
        this.chapterPagesWritten.put(chapter, pagesWritten);
    }

    public double getProgress(String chapter) {
        return ((double) chapterPagesWritten.get(chapter) / chapterPages.get(chapter)) * 100;
    }

    public double getTotalProgress() {
        int totalWritten = chapterPagesWritten.values().stream().mapToInt(Integer::intValue).sum();
        int total = chapterPages.values().stream().mapToInt(Integer::intValue).sum();
        return ((double) totalWritten / total) * 100;
    }
}

public class Main {
    public static void main(String[] args) {
        BookProgress book = new BookProgress("JVM Performance Engineering");
        String[] chapters = {
            "Performance Evolution",
            "Performance and Type System",
            "Monolithic to Modular",
            "Unified Logging System",
            "End-to-End Performance Optimization",
            "Advanced Memory Management",
            "Runtime Performance Optimization",
            "Accelerating Startup",
            "Harnessing Exotic Hardware"
        };
        for (String chapter : chapters) {
            book.addChapter(chapter, 100);
        }
        for (int i = 0; i < 50; i++) {
            for (String chapter : chapters) {
                int currentPagesWritten = book.chapterPagesWritten.get(chapter);
                if (currentPagesWritten < 100) {
                    book.updateProgress(chapter, currentPagesWritten + 2);
                    double progress = book.getProgress(chapter);

```

```
        System.out.println("Progress for chapter " + chapter + ": " + progress + "%");
    }
}
}
System.out.println("Total book progress: " + book.getTotalProgress() + "%");
}
```

---

In this code, we've defined a `BookProgress` class to track the progress of writing a book, which is divided into chapters. Each chapter has a total number of pages and a current count of pages written. The class provides methods to add chapters, update progress, and calculate the progress of each chapter and the overall book.

The `Main` class creates a `BookProgress` object for a book titled "JVM Performance Engineering." It adds nine chapters, each with 100 pages, and simulates writing the book by updating the progress of each chapter in a round-robin fashion, writing two pages at a time. After each update, it calculates and prints the progress of the current chapter and, once all pages are written, the overall progress of the book.

The `getProgress(String chapter)` and `updateProgress(String chapter, int pagesWritten)` methods are identified as performance-critical methods. Their frequent invocation makes them prime candidates for optimization by the HotSpot VM, illustrating how certain methods in a program may require more attention for performance optimization due to their high frequency of use.

#### Interpreter and JIT Compilation

The HotSpot VM provides an interpreter that converts bytecode into native code based on the *TemplateTable*. Interpretation is the first step in adaptive optimization offered by this VM and is considered the slowest form of bytecode execution. To make the execution faster, the HotSpot VM utilizes adaptive JIT compilation. The JIT-optimized code replaces the template code for methods that are identified as performance critical.

As mentioned in the previous section, the HotSpot VM monitors executed code for performance-critical methods based on two key metrics—method entry counts and loop-back branch counts. The VM assigns call counters to individual methods in the Java application. When the entry count exceeds a preestablished value, the method or its callee is chosen for asynchronous JIT compilation. Similarly, there is a counter for each loop in the code. Once the HotSpot VM determines that the loop-back branches (also known as loop-back edges) have crossed their threshold, the JIT optimizes that particular loop. This optimization is called on-stack replacement (OSR). With OSR, only the loop for which the loop-back branch counter overflowed will be compiled and replaced asynchronously on the execution stack.

#### Print Compilation

A very handy command-line option that can help us better understand adaptive optimization in the HotSpot VM is `-XX:+PrintCompilation`. This option also returns information on different optimized compilation levels, which are provided by an adaptive optimization called tiered compilation (discussed in the next subsection).

The output of the `-XX:+PrintCompilation` option is a log of the HotSpot VM's compilation tasks. Each line of the log represents a single compilation task and includes several pieces of information:

- The timestamp in milliseconds since the JVM started and this compilation task was logged.
- The unique identifier for this compilation task.
- Flags indicating certain properties of the method being compiled, such as whether it's an OSR method (%), whether it's synchronized (s), whether it has an exception handler (!), whether it's blocking (b), or whether it's native (n).
- The tiered compilation level, indicating the level of optimization applied to this method.
- The fully qualified name of the method being compiled.
- For OSR methods, the bytecode index where the compilation started. This is usually the start of a loop.
- The size of the method in the bytecode, in bytes.

Here are a few examples of the output of the `-XX:+PrintCompilation` option:

---

|     |     |     |   |                                                        |
|-----|-----|-----|---|--------------------------------------------------------|
| 567 | 693 | % ! | 3 | org.h2.command.dml.Insert::insertRows @ 76 (513 bytes) |
| 656 | 797 | n   | 0 | java.lang.Object::clone (native)                       |
| 779 | 835 | s   | 4 | java.lang.StringBuffer::append (13 bytes)              |

---

These logs provide valuable insights into the behavior of the HotSpot VM's adaptive optimization, helping us understand how our Java applications are optimized at runtime.

#### Tiered Compilation

Tiered compilation, which was introduced in Java 7, provides multiple levels of optimized compilations, ranging from T0 to T4:

1. **T0:** Interpreted code, devoid of compilation. This is where the code starts and then moves on to the T1, T2, or T3 level.
2. **T1–T3:** Client-compiled mode. T1 is the first step where the method invocation counters and loop-back branch counters are used. At T2, the client compiler includes profiling information, referred to as profile-guided optimization; it may be familiar to readers who are conversant in static compiler optimizations. At the T3 compilation level, completely profiled code can be generated.
3. **T4:** The highest level of optimization provided by the HotSpot VM's server compiler.

Prior to tiered compilation, the server compiler would employ the interpreter to collect such profiling information. With the introduction of tiered compilation, the code reaches client compilation levels faster, and now the profiling information is generated by client-compiled methods themselves, providing better start-up times.

**NOTE** Tiered compilation has been enabled by default since Java 8.

#### Client and Server Compilers

The HotSpot VM provides two flavors of compilers: the fast client compiler (also known as the C1 compiler) and the server compiler (also known as the C2 compiler).

1. **Client compiler (C1):** Aims for fast start-up times in a client setup. The JIT invocation thresholds are lower for a client compiler than for a server compiler. This compiler is designed to compile code quickly, providing a fast start-up time, but the code it generates is less optimized.
2. **Server compiler (C2):** Offers many more adaptive optimizations and better thresholds geared toward higher performance. The counters that determine when a method/loop needs to be compiled are still the same, but the invocation thresholds are different (much lower) for a client compiler than for a server compiler. The server compiler takes longer to compile methods but produces highly optimized code that is beneficial for long-running applications. Some of the optimizations performed by the C2 compiler include *inlining* (replacing method invocations with the method's body), loop unrolling (increasing the loop body size to decrease the overhead of loop checks and to potentially apply other optimizations such as loop vectorization), dead code elimination (removing code that does not affect the program results), and range-check elimination (removing checks for index out-of-bounds errors if it can be assured that the array index never crosses its bounds). These optimizations help to improve the execution speed of the code and reduce the overhead of certain operations.<sup>2</sup>

#### Segmented Code Cache

As we delve deeper into the intricacies of the HotSpot VM, it's important to revisit the concept of the code cache. Recall that the code cache is a storage area for native code generated by the JIT compiler or the interpreter. With the introduction of tiered compilation, the code cache also becomes a repository for profiling information gathered at different levels of tiered compilation. Interestingly, even the *TemplateTable*, which the interpreter uses to look up the native code sequence for each bytecode, is stored in the code cache.

The size of the code cache is fixed at start-up but can be modified on the command line by passing the desired maximum value to `-XX:ReservedCodeCacheSize`. Prior to Java 7, the default value for this size was 48 MB. Once the code cache was filled up, all compilation would cease. This posed a significant problem when tiered compilation was enabled, as the code cache would contain not only JIT-compiled code (represented as *nmethod* in the HotSpot VM) but also profiled code. The *nmethod* refers to the internal representation of a Java method that has been compiled into machine code by the JIT compiler. In contrast, the profiled code is the code that has been analyzed and optimized based on its runtime behavior. The code cache needs

---

<sup>2</sup> "What the JIT!? Anatomy of the OpenJDK HotSpot VM." infoq.com.

to manage both of these types of code, leading to increased complexity and potential performance issues.

To address these problems, the default value for `ReservedCodeCacheSize` was increased to 240 MB in JDK 7 update 40. Furthermore, when the code cache occupancy crosses a preset `CodeCacheMinimumFreeSpace` threshold, the JIT compilation halts and the JVM runs a *sweeper*. The *nmethod* sweeper reclaims space by evacuating older compilations. However, sweeping the entire code cache data structure can be time-consuming, especially when the code cache is large and nearly full.

Java 9 introduced a significant change to the code cache: It was segmented into different regions based on the type of code. This not only reduced the sweeping time but also minimized fragmentation of the long-lived code by shorter-lived code. Co-locating code of the same type also reduced hardware-level instruction cache misses.

The current implementation of the segmented code cache includes the following regions:

- **Non-method code heap region:** This region is reserved for VM internal data structures that are not related to Java methods. For example, the *TemplateTable*, which is a VM internal data structure, resides here. This region doesn't contain compiled Java methods.
- **Non-profiled *nmethod* code heap:** This region contains Java methods that have been compiled by the JIT compiler without profiling information. These methods are fully optimized and are expected to be long-lived, meaning they won't be recompiled frequently and may need to be reclaimed only infrequently by the sweeper.
- **Profiled *nmethod* code heap:** This region contains Java methods that have been compiled with profiling information. These methods are not as optimized as those in the non-profiled region. They are considered transient because they can be recompiled into more optimized versions and moved to the non-profiled region as more profiling information becomes available. They can also be reclaimed by the sweeper as often as needed.

Each of these regions has a fixed size that can be set by their respective command-line options:

| Heap Region Type                      | Size Command-Line Option                 |
|---------------------------------------|------------------------------------------|
| Non-method code heap                  | <code>-XX:NonMethodCodeHeapSize</code>   |
| Non-profiled <i>nmethod</i> code heap | <code>-XX:NonProfiledCodeHeapSize</code> |
| Profiled <i>nmethod</i> code heap     | <code>-XX:ProfiledCodeHeapSize</code>    |

Going forward, the hope is that the segmented code caches can accommodate additional code regions for heterogeneous code such as ahead-of-time (AOT)-compiled code and code for hardware accelerators.<sup>3</sup> There's also the expectation that the fixed sizing thresholds can be upgraded to utilize adaptive resizing, thereby avoiding wastage of memory.

<sup>3</sup> JEP 197: Segmented Code Cache. <https://openjdk.org/eps/197>.

### Adaptive Optimization and Deoptimization

Adaptive optimization allows the HotSpot VM runtime to optimize the interpreted code into compiled code or insert an optimized loop on the stack (so we could have something like an “interpreted to compiled, and back to interpreted” code execution sequence). There is another major advantage of adaptive optimization, however—in deoptimization of code. That means the compiled code could go back to being interpreted, or a higher-optimized code sequence could be rolled back into a less-optimized sequence.

Dynamic deoptimization helps Java reclaim code that may no longer be relevant. A few example use cases are when checking interdependencies during dynamic class loading, when dealing with polymorphic call sites, and when reclaiming less-optimized code. Deoptimization will first make the code “not entrant” and eventually reclaim it after marking it as “zombie” code.<sup>4</sup>

#### Deoptimization Scenarios

Deoptimization can occur in several scenarios when working with Java applications. In this section, we’ll explore two of these scenarios.

#### Class Loading and Unloading

Consider an application containing two classes, `Car` and `DriverLicense`. The `Car` class requires a `DriverLicense` to enable drive mode. The JIT compiler optimizes the interaction between these two classes. However, if a new version of the `DriverLicense` class is loaded due to changes in driving regulations, the previously compiled code may no longer be valid. This necessitates deoptimization to revert to the interpreted mode or a less-optimized state. This allows the application to employ the new version of the `DriverLicense` class.

Here’s an example code snippet:

---

```
class Car {
    private DriverLicense driverLicense;

    public Car(DriverLicense driverLicense) {
        this.driverLicense = driverLicense;
    }

    public void enableDriveMode() {
        if (driverLicense.isAdult()) {
            System.out.println("Drive mode enabled!");
        } else if (driverLicense.isTeenDriver()) {
            if (driverLicense.isLearner()) {
                System.out.println("You cannot drive without a licensed adult's supervision.");
            } else {
                System.out.println("Drive mode enabled!");
            }
        } else {
    }
}
```

---

<sup>4</sup><https://www.infoq.com/articles/OpenJDK-HotSpot-What-the-JIT/>

```

        System.out.println("You don't have a valid driver's license.");
    }
}

class DriverLicense {
    private boolean isTeenDriver;
    private boolean isAdult;
    private boolean isLearner;

    public DriverLicense(boolean isTeenDriver, boolean isAdult, boolean isLearner) {
        this.isTeenDriver = isTeenDriver;
        this.isAdult = isAdult;
        this.isLearner = isLearner;
    }

    public boolean isTeenDriver() {
        return isTeenDriver;
    }

    public boolean isAdult() {
        return isAdult;
    }

    public boolean isLearner() {
        return isLearner;
    }
}

public class Main {
    public static void main(String[] args) {
        DriverLicense driverLicense = new DriverLicense(false, true, false);
        Car myCar = new Car(driverLicense);
        myCar.enableDriveMode();
    }
}

```

---

In this example, the `Car` class requires a `DriverLicense` to enable drive mode. The driver's license can be for an adult, a teen driver with a learner's permit, or a teen driver with a full license. The `enableDriveMode()` method checks the driver's license using the `isAdult()`, `isTeenDriver()`, and `isLearner()` methods, and prints the appropriate message to the console.

If a new version of the `DriverLicense` class is loaded, the previously optimized code may no longer be valid, triggering deoptimization. This allows the application to use the new version of the `DriverLicense` class without any issues.

#### Polymorphic Call Sites

Deoptimization can also occur when working with polymorphic call sites, where the actual method to be invoked is determined at runtime. Let's look at an example using the `DriverLicense` class:

---

```
abstract class DriverLicense {  
    public abstract void drive();  
}  
  
class AdultLicense extends DriverLicense {  
    public void drive() {  
        System.out.println("Thanks for driving responsibly as an adult");  
    }  
}  
  
class TeenPermit extends DriverLicense {  
    public void drive() {  
        System.out.println("Thanks for learning to drive responsibly as a teen");  
    }  
}  
  
class SeniorLicense extends DriverLicense {  
    public void drive() {  
        System.out.println("Thanks for being a valued senior citizen");  
    }  
}  
  
public class Main {  
    public static void main(String[] args) {  
        DriverLicense license = new AdultLicense();  
        license.drive(); // monomorphic call site  
  
        // Changing the call site to bimorphic  
        if (Math.random() < 0.5) {  
            license = new AdultLicense();  
        } else {  
            license = new TeenPermit();  
        }  
        license.drive(); // bimorphic call site  
  
        // Changing the call site to megamorphic  
        for (int i = 0; i < 100; i++) {  
            if (Math.random() < 0.33) {  
                license = new AdultLicense();
```

```

    } else if (Math.random() < 0.66) {
        license = new TeenPermit();
    } else {
        license = new SeniorLicense();
    }
    license.drive(); // megamorphic call site
}
}

```

---

In this example, the abstract `DriverLicense` class has three subclasses: `AdultLicense`, `TeenPermit`, and `SeniorLicense`. The `drive()` method is overridden in each subclass with different implementations.

First, when we assign an `AdultLicense` object to a `DriverLicense` variable and call `drive()`, the HotSpot VM optimizes the call site to a monomorphic call site and caches the target method address in an *inline cache* (a structure to track the call site's type profile).

Next, we change the call site to a bimorphic call site by randomly assigning an `AdultLicense` or `TeenPermit` object to the `DriverLicense` variable and calling `drive()`. Because there are two possible types, the VM can no longer use the monomorphic dispatch mechanism, so it switches to the bimorphic dispatch mechanism. This change does not require deoptimization—and still provides a performance boost by reducing the number of virtual method dispatches needed at the call site.

Finally, we change the call site to a megamorphic call site by randomly assigning an `AdultLicense`, `TeenPermit`, or `SeniorLicense` object to the `DriverLicense` variable and calling `drive()` 100 times. As there are now three possible types, the VM cannot use the bimorphic dispatch mechanism and must switch to the megamorphic dispatch mechanism. This change also does not require deoptimization.

However, if we were to introduce a new subclass `InternationalLicense` and change the call site to include it, the VM could potentially deoptimize the call site and switch to a megamorphic or polymorphic call site to handle the new type. This change is necessary because the VM's type profiling information for the call site would be outdated, and the previously optimized code would no longer be valid.

Here's the code snippet for the new subclass and the updated call site:

---

```

class InternationalLicense extends DriverLicense {
    public void drive() {
        System.out.println("Thanks for driving responsibly as an international driver");
    }
}

// Updated call site
for (int i = 0; i < 100; i++) {

```

```
if (Math.random() < 0.25) {  
    license = new AdultLicense();  
} else if (Math.random() < 0.5) {  
    license = new TeenPermit();  
} else if (Math.random() < 0.75) {  
    license = new SeniorLicense();  
} else {  
    license = new InternationalLicense();  
}  
license.drive(); // megamorphic call site with a new type  
}
```

---

### HotSpot Garbage Collector: Memory Management Unit

A crucial component of the HotSpot execution engine is its memory management unit, commonly known as the garbage collector (GC). HotSpot provides multiple garbage collection algorithms that cater to a trifecta of performance aspects: application responsiveness, throughput, and overall footprint. *Responsiveness* refers to the time taken to receive a response from the system after sending a stimulus. *Throughput* measures the number of operations that can be performed per second on a given system. *Footprint* can be defined in two ways: as optimizing the amount of data or objects that can fit into the available space and as removing redundant information to save space.

### Generational Garbage Collection, Stop-the-World, and Concurrent Algorithms

OpenJDK offers a variety of generational GCs that utilize different strategies to manage memory, with the common goal of improving application performance. These collectors are designed based on the principle that “most objects die young,” meaning that most newly allocated objects on the Java heap are short-lived. By taking advantage of this observation, generational GCs aim to optimize memory management and significantly reduce the negative impact of garbage collection on the performance of the application.

Heap collection in GC terms involves identifying live objects, reclaiming space occupied by garbage objects, and, in some cases, compacting the heap to reduce fragmentation. Fragmentation can occur in two ways: (1) internal fragmentation, where allocated memory blocks are larger than necessary, leaving wasted space within the blocks; and (2) external fragmentation, where memory is allocated and deallocated in such a way that free memory is divided into noncontiguous blocks. External fragmentation can lead to inefficient memory use and potential allocation failures. Compaction is a technique used by some GCs to combat external fragmentation; it involves moving objects in memory to consolidate free memory into a single contiguous block. However, compaction can be a costly operation in terms of CPU usage and can cause lengthy pause times if it's done as a stop-the-world operation.

The OpenJDK GCs employ several different GC algorithms:

- **Stop-the-world (STW) algorithms:** STW algorithms pause application threads for the entire duration of the garbage collection work. Serial, Parallel, (Mostly) Concurrent Mark and Sweep (CMS), and Garbage First (G1) GCs use STW algorithms in specific phases of their collection cycles. The STW approach can result in longer pause times when the heap fills up and runs out of allocation space, especially in nongenerational heaps, which treat the heap as a single continuous space without segregating it into generations.
- **Concurrent algorithms:** These algorithms aim to minimize pause times by performing most of their work concurrently with the application threads. CMS is an example of a collector using concurrent algorithms. However, because CMS does not perform compaction, fragmentation can become an issue over time. This can lead to longer pause times or even cause a fallback to a full GC using the Serial Old collector, which does include compaction.
- **Incremental compacting algorithms:** The G1 GC introduced incremental compaction to deal with the fragmentation issue found in CMS. G1 divides the heap into smaller regions and performs garbage collection on a subset of regions during a collection cycle. This approach helps maintain more predictable pause times while also handling compaction.
- **Thread-local handshakes:** Newer GCs like Shenandoah and ZGC leverage thread-local handshakes to minimize STW pauses. By employing this mechanism, they can perform certain GC operations on a per-thread basis, allowing application threads to continue running while the GC works. This approach helps to reduce the overall impact of garbage collection on application performance.
- **Ultra-low-pause-time collectors:** The Shenandoah and ZGC aim to have ultra-low pause times by performing concurrent marking, relocation, and compaction. Both minimize the STW pauses to a small fraction of the overall garbage collection work, offering consistent low latency for applications. While these GCs are not generational in the traditional sense, they do divide the heap into regions and collect different regions at different times. This approach builds upon the principles of incremental and “garbage first” collection. As of this writing, efforts are ongoing to further develop these newer collectors into generational ones, but they are included in this section due to their innovative strategies that enhance the principles of generational garbage collection.

Each collector has its advantages and trade-offs, allowing developers to choose the one that best suits their application requirements.

#### Young Collections and Weak Generational Hypothesis

In the realm of a generational heap, the majority of allocations take place in the *eden* space of the *young* generation. An allocating thread may encounter an allocation failure when this eden space is near its capacity, indicating that the GC must step in and reclaim space.

During the first *young* collection, the eden space undergoes a scavenging process in which live objects are identified and subsequently moved into the *to* survivor space. The survivor

space serves as a transitional area where surviving objects are copied, aged, and moved back and forth between the *from* and *to* spaces until they cross a tenuring threshold. Once an object crosses this threshold, it is promoted to the *old* generation. The underlying objective here is to promote only those objects that have proven their longevity, thereby creating a “Teenage Wasteland,” as Charlie Hunt<sup>5</sup> would explain. ☺

The generational garbage collection is based on two main characteristics related to the weak-generational hypothesis:

1. **Most objects die young:** This means that we promote only long-lived objects. If the generational GC is efficient, we don't promote transients, nor do we promote medium-lived objects. This usually results in smaller long-lived data sets, keeping premature promotions, fragmentation, evacuation failures, and similar degenerative issues at bay.
2. **Maintenance of generations:** The generational algorithm has proven to be a great help to OpenJDK GCs, but it comes with a cost. Because the young-generation collector works separately and more often than the old-generation collector, it ends up moving live data. Therefore, generational GCs incur maintenance/bookkeeping overhead to ensure that they mark all reachable objects—a feat achieved through the use of “write barriers” that track cross-generational references.

Figure 1.1 depicts the three key concepts of generational GCs, providing a visual reinforcement of the information discussed here. The word cloud consists of the following phrases:

- **Objects die young:** Highlighting the idea that most objects are short-lived and only long-lived objects are promoted.
- **Small long-lived data sets:** Emphasizing the efficiency of the generational GC in not promoting transients or medium-lived objects, resulting in smaller long-lived data sets.
- **Maintenance barriers:** Highlighting the overhead and bookkeeping required by generational GCs to mark all reachable objects, achieved through the use of write barriers.

![A word cloud graphic titled 'Generational' in the center. The words 'Objects die young', 'Small, long-lived data sets', and 'Maintenance barriers' are arranged around the central title, representing the three key concepts of generational garbage collectors.](69350f1ebebf4e4b2d5644dfc6671d7c_img.jpg)

A word cloud graphic titled 'Generational' in the center. The words 'Objects die young', 'Small, long-lived data sets', and 'Maintenance barriers' are arranged around the central title, representing the three key concepts of generational garbage collectors.

Figure 1.1 Key Concepts for Generational Garbage Collectors

<sup>5</sup> Charlie Hunt is my mentor, the author of *Java Performance* (<https://ptgmedia.pearsoncmg.com/images/9780137142521/samplepages/0137142528.pdf>), and my co-author for *Java Performance Companion* ([www.pearson.com/en-us/subject-catalog/p/java-performance-companion/P200000009127/9780133796827](http://www.pearson.com/en-us/subject-catalog/p/java-performance-companion/P200000009127/9780133796827)).

Most HotSpot GCs employ the renowned “scavenge” algorithm for young collections. The Serial GC in HotSpot VM employs a single garbage collection thread dedicated to efficiently reclaiming memory within the young-generation space. In contrast, generational collectors such as the Parallel GC (throughput collector), G1 GC, and CMS GC leverage multiple GC worker threads.

#### Old-Generation Collection and Reclamation Triggers

Old-generation reclamation algorithms in HotSpot VM’s generational GCs are optimized for throughput, responsiveness, or a combination of both. The Serial GC employs a single-threaded mark-sweep-compacting (MSC) GC. The Parallel GC uses a similar MSC GC with multiple threads. The CMS GC performs mostly concurrent marking, dividing the process into STW or concurrent phases. After marking, CMS reclaims old-generation space by performing in-place deallocation without compaction. If fragmentation occurs, CMS falls back to the serial MSC.

G1 GC, introduced in Java 7 update 4 and refined over time, is the first incremental collector. Specifically, it incrementally reclaims and compacts the old-generation space, as opposed to performing the single monolithic reclamation and compaction that is part of MSC. G1 GC divides the heap into smaller regions and performs garbage collection on a subset of regions during a collection cycle, which helps maintain more predictable pause times while also handling compaction.

After multiple young-generation collections, the old generation starts filling up, and garbage collection kicks in to reclaim space in the old generation. To do so, a full heap marking cycle must be triggered by either (1) a promotion failure, (2) a promotion of a regular-sized object that makes the old generation or the total heap cross the marking threshold, or (3) a large object allocation (also known as humongous allocation in the G1 GC) that causes the heap occupancy to cross a predetermined threshold.

Shenandoah GC and ZGC—introduced in JDK 12 and JDK 11, respectively—are ultra-low-pause-time collectors that aim to minimize STW pauses. In JDK 17, they are single-generational collectors. Apart from utilizing thread-local handshakes, these collectors know how to optimize for low-pause scenarios either by employing the application threads to help out or by asking the application threads to back off. This GC technique is known as graceful degradation.

### Parallel GC Threads, Concurrent GC Threads, and Their Configuration

In the HotSpot VM, the total number of GC worker threads (also known as parallel GC threads) is calculated as a fraction of the total number of processing cores available to the Java process at start-up. Users can adjust the parallel GC thread count by assigning it directly on the command line using the `-XX:ParallelGCThreads=<n>` flag.

This configuration flag enables developers to define the number of parallel GC threads for GC algorithms that use parallel collection phases. It is particularly useful for tuning generational GCs, such as the Parallel GC and G1 GC. Recent additions like Shenandoah and ZGC, also use multiple GC worker threads and perform garbage collection concurrently with the application threads to minimize pause times. They benefit from load balancing, work sharing, and work stealing, which enhance performance and efficiency by parallelizing the garbage collection

process. This parallelization is particularly beneficial for applications running on multi-core processors, as it allows the GC to make better use of the available hardware resources.

In a similar vein, the `-XX:ConcGCThreads=<n>` configuration flag allows developers to specify the number of concurrent GC threads for specific GC algorithms that use concurrent collection phases. This flag is particularly useful for tuning GCs like G1, which performs concurrent work during marking, and Shenandoah and ZGC, which aim to minimize STW pauses by executing concurrent marking, relocation, and compaction.

By default, the number of parallel GC threads is automatically calculated based on the available CPU cores. Concurrent GC threads usually default to one-fourth of the parallel GC threads. However, developers may want to adjust the number of parallel or concurrent GC threads to better align with their application's performance requirements and available hardware resources.

Increasing the number of parallel GC threads can help improve overall GC throughput, as more threads work simultaneously on the parallel phases of this process. This increase may result in shorter GC pause times and potentially higher application throughput, but developers should be cautious not to over-commit processing resources.

By comparison, increasing the number of concurrent GC threads can enhance overall GC performance and expedite the GC cycle, as more threads work simultaneously on the concurrent phases of this process. However, this increase may come at the cost of higher CPU utilization and competition with application threads for CPU resources.

Conversely, reducing the number of parallel or concurrent GC threads may lower CPU utilization but could result in longer GC pause times, potentially affecting application performance and responsiveness. In some cases, if the concurrent collector is unable to keep up with the rate at which the application allocates objects (a situation referred to as the GC “losing the race”), it may lead to a graceful degradation—that is, the GC falls back to a less optimal but more reliable mode of operation, such as a STW collection mode, or might employ strategies like throttling the application's allocation rate to prevent it from overloading the collector.

Figure 1.2 shows the key concepts as a word cloud related to GC work:

- **Task queues:** Highlighting the mechanisms used by GCs to manage and distribute work among the GC threads.
- **Concurrent work:** Emphasizing the operations performed by the GC simultaneously with the application threads, aiming to minimize pause times.
- **Graceful degradation:** Referring to the GC's ability to switch to a less optimal but more reliable mode of operation when it can't keep up with the application's object allocation rate.
- **Pauses:** Highlighting the STW events during which application threads are halted to allow the GC to perform certain tasks.
- **Task stealing:** Emphasizing the strategy employed by some GCs in which idle GC threads “steal” tasks from the work queues of busier threads to ensure efficient load balancing.
- **Lots of threads:** Highlighting the use of multiple threads by GCs to parallelize the garbage collection process and improve throughput.

![A diagram titled 'Key Concepts for Garbage Collection Work' showing a central concept 'GC Work' surrounded by several related terms: 'Concurrent work', 'Task queues', 'Lots of threads', 'Task stealing', 'Pauses', and 'Graceful degradation'.](5db6545aedab79741ebae9b27bb363b3_img.jpg)

The diagram consists of a central, irregularly shaped light gray area labeled 'GC Work'. Surrounding this central area are several text labels: 'Concurrent work' is at the top left; 'Task queues' is at the top center; 'Lots of threads' is at the top right; 'Task stealing' is on the right side; 'Pauses' is at the bottom center; and 'Graceful degradation' is at the bottom left.

A diagram titled 'Key Concepts for Garbage Collection Work' showing a central concept 'GC Work' surrounded by several related terms: 'Concurrent work', 'Task queues', 'Lots of threads', 'Task stealing', 'Pauses', and 'Graceful degradation'.

Figure 1.2 Key Concepts for Garbage Collection Work

It is crucial to find the right balance between the number of parallel and concurrent GC threads and application performance. Developers should conduct performance testing and monitoring to identify the optimal configuration for their specific use case. When tuning these threads, consider factors such as the number of available CPU cores, the nature of the application workload, and the desired balance between garbage collection throughput and application responsiveness.

### The Evolution of the Java Programming Language and Its Ecosystem: A Closer Look

The Java language has evolved steadily since the early Java 1.0 days. To appreciate the advancements in the JVM, and particularly the HotSpot VM, it's crucial to understand the evolution of the Java programming language and its ecosystem. Gaining insight into how language features, libraries, frameworks, and tools have shaped and influenced the JVM's performance optimizations and garbage collection strategies will help us grasp the broader context.

### Java 1.1 to Java 1.4.2 (J2SE 1.4.2)

Java 1.1, originally known as JDK 1.1, introduced JavaBeans, which allowed multiple objects to be encapsulated in a bean. This version also brought Java Database Connectivity (JDBC), Remote Method Invocation (RMI), and inner classes. These features set the stage for more complex applications, which in turn demanded improved JVM performance and garbage collection strategies.

From Java 1.2 to Java 5.0, the releases were renamed to include the version name, resulting in names like J2SE (Platform, Standard Edition). The renaming helped differentiate between Java 2 Micro Edition (J2ME) and Java 2 Enterprise Edition (J2EE).<sup>6</sup> J2SE 1.2 introduced two significant improvements to Java: the Collections Framework and the JIT compiler. The Collections Framework provided “a unified architecture for representing and manipulating collections”.<sup>7</sup>

<sup>6</sup>[www.oracle.com/java/technologies/javase/javanaming.html](http://www.oracle.com/java/technologies/javase/javanaming.html)

<sup>7</sup>Collections Framework Overview. <https://docs.oracle.com/javase/8/docs/technnotes/guides/collections/overview.html>.

which became essential for managing large-scale data structures and optimizing memory management in the JVM.

Java 1.3 (J2SE 1.3) added new APIs to the Collections Framework, introduced Math classes, and made the HotSpot VM the default Java VM. A directory services API was included for Java RMI to look up any directory or name service. These enhancements further influenced JVM efficiency by enabling more memory-efficient data management and interaction patterns.

The introduction of the New Input/Output (NIO) API in Java 1.4 (J2SE 1.4), based on Java Specification Request (JSR) #51,<sup>8</sup> significantly improved I/O operation efficiency. This enhancement resulted in reduced waiting times for I/O tasks and an overall boost in JVM performance. J2SE 1.4 also introduced the Logging API, which allowed for generating text or XML-formatted log messages that could be directed to a file or console.

J2SE 1.4.1 was soon superseded by J2SE 1.4.2, which included numerous performance enhancements in HotSpot's client and server compilers. Security enhancements were added as well, and Java users were introduced to Java updates via the Java Plug-in Control Panel Update tab. With the continuous improvements in the Java language and its ecosystem, JVM performance strategies evolved to accommodate increasingly more complex and resource-demanding applications.

#### Java 5 (J2SE 5.0)

The Java language made its first significant leap toward language refinement with the release of Java 5.0. This version introduced several key features, including generics, autoboxing/unboxing, annotations, and an enhanced for loop.

#### Language Features

Generics introduced two major changes: (1) a change in syntax and (2) modifications to the core API. Generics allow you to reuse your code for different data types, meaning you can write just a single class—there is no need to rewrite it for different inputs.

To compile the generics-enriched Java 5.0 code, you would need to use the Java compiler `javac`, which was packaged with the Java 5.0 JDK. (Any version prior to Java 5.0 did not have the core API changes.) The new Java compiler would produce errors if any type safety violations were detected at compile time. Hence, generics introduced type safety into Java. Also, generics eliminated the need for explicit casting, as casting became implicit.

Here's an example of how to create a generic class named `FreshmenAdmissions` in Java 5.0:

---

```
class FreshmenAdmissions<K, V> {  
    //...  
}
```

---

<sup>8</sup><https://jcp.org/en/jsr/detail?id=51>

In this example, `K` and `V` are placeholders for the actual types of objects. The class `FreshmenAdmissions` is a generic type. If we declare an instance of this generic type without specifying the actual types for `K` and `V`, then it is considered to be a raw type of the generic type `FreshmenAdmissions<K, V>`. Raw types exist for generic types and are used when the specific type parameters are unknown.

---

```
FreshmenAdmissions applicationStatus;
```

---

However, suppose we declare the instance with actual types:

---

```
FreshmenAdmissions<String, Boolean>
```

---

Then `applicationStatus` is said to be a parameterized type—specifically, it is parameterized over types `String` and `Boolean`.

---

```
FreshmenAdmissions<String, Boolean> applicationStatus;
```

---

**NOTE** Many C++ developers may see the angle brackets `< >` and immediately draw parallels to C++ templates. Although both C++ and Java use generic types, C++ templates are more like a compile-time mechanism, where the generic type is replaced by the actual type by the C++ compiler, offering robust type safety.

While discussing generics, we should also touch on autoboxing and unboxing. In the `FreshmenAdmissions<K, V>` class, we can have a generic method that returns the type `V`:

---

```
public V getApprovalInfo() {
    return boolOrNumValue;
}
```

---

Based on our declaration of `V` in the parameterized type, we can perform a `Boolean` check and the code would compile correctly. For example:

---

```
applicationStatus = new FreshmenAdmissions<>();
if (applicationStatus.getApprovalInfo()) {
    //...
}
```

---

In this example, we see a generic type invocation of `V` as a `Boolean`. Autoboxing ensures that this code will compile correctly. In contrast, if we had done the generic type invocation of `V` as an `Integer`, we would get an “incompatible types” error. Thus, autoboxing is a Java compiler conversion that understands the relationship between a primitive and its object class. Just as autoboxing encapsulates a `boolean` value into its `Boolean` wrapper class, unboxing helps return a `boolean` value when the return type is a `Boolean`.

Here's the entire example (using Java 5.0):

---

```
class FreshmenAdmissions<K, V> {
    private K key;
    private V boolOrNumValue;

    public void admissionInformation(K name, V value) {
        key = name;
        boolOrNumValue = value;
    }

    public V getApprovalInfo() {
        return boolOrNumValue;
    }

    public K getApprovedName() {
        return key;
    }
}

public class GenericExample {

    public static void main(String[] args) {
        FreshmenAdmissions<String, Boolean> applicationStatus;
        applicationStatus = new FreshmenAdmissions<String, Boolean>();

        FreshmenAdmissions<String, Integer> applicantRollNumber;
        applicantRollNumber = new FreshmenAdmissions<String, Boolean>();

        applicationStatus.admissionInformation("Annika", true);

        if (applicationStatus.getApprovalInfo()) {
            applicantRollNumber.admissionInformation(applicationStatus.getApprovedName(), 4);
        }

        System.out.println("Applicant " + applicantRollNumber.getApprovedName() +
            " has been admitted with roll number of " + applicantRollNumber.getApprovalInfo());
    }
}
```

---

Figure 1.3 shows a class diagram to help visualize the relationship between the classes. In the diagram, the `FreshmenAdmissions` class has three methods: `admissionInformation(K,V)`, `getApprovalInfo():V`, and `getApprovedName():K`. The `GenericExample` class uses the `FreshmenAdmissions` class and has a `main(String[] args)` method.