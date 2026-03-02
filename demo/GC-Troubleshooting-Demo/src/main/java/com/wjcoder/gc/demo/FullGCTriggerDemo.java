package com.wjcoder.gc.demo;

import java.util.ArrayList;
import java.util.List;

/**
 * Full GC触发Demo - 模拟导致Full GC的场景
 * 
 * 场景1：元空间不足
 * 场景2：晋升失败（Evacuation Failure）
 * 场景3：System.gc()调用
 * 
 * 运行参数：
 * -Xms256m -Xmx256m -XX:+UseG1GC \
 * -XX:MaxMetaspaceSize=32m \
 * -Xlog:gc*:file=gc-full-gc.log:time,uptime,level,tags
 */
public class FullGCTriggerDemo {
    
    private static List<Object> survivorList = new ArrayList<>();
    
    public static void main(String[] args) throws Exception {
        System.out.println("=== Full GC触发Demo启动 ===");
        System.out.println("JVM参数: -Xms256m -Xmx256m -XX:+UseG1GC");
        System.out.println("模拟场景：触发Full GC的各种情况");
        System.out.println();
        
        Runtime runtime = Runtime.getRuntime();
        long maxMemory = runtime.maxMemory();
        System.out.printf("最大堆内存: %dMB%n", maxMemory / 1024 / 1024);
        System.out.println();
        
        // 场景1：显式调用System.gc()
        System.out.println("--- 场景1：显式调用System.gc() ---");
        allocateSomeObjects();
        printMemoryStatus("分配对象后");
        System.out.println("调用System.gc()...");
        System.gc();
        Thread.sleep(1000);
        printMemoryStatus("System.gc()后");
        
        // 场景2：晋升失败（快速填满老年代）
        System.out.println("\n--- 场景2：快速填满老年代导致晋升压力 ---");
        survivorList.clear(); // 清空之前的引用
        
        for (int round = 1; round <= 10; round++) {
            // 创建大量对象并保留引用，迫使他们进入老年代
            List<Object> batch = new ArrayList<>();
            for (int i = 0; i < 1000; i++) {
                batch.add(new MediumObject(round * 1000 + i));
            }
            survivorList.addAll(batch);
            
            printMemoryStatus("Round " + round + " - 对象进入老年代");
            
            // 强制触发GC
            if (round % 3 == 0) {
                System.out.println("  -> 触发GC观察晋升");
                System.gc();
                Thread.sleep(500);
            }
            
            Thread.sleep(300);
        }
        
        // 场景3：模拟内存紧张
        System.out.println("\n--- 场景3：内存紧张状态 ---");
        System.out.println("继续分配直到接近上限...");
        
        int extraCount = 0;
        while (extraCount < 100) {
            extraCount++;
            try {
                survivorList.add(new MediumObject(extraCount));
                
                if (extraCount % 20 == 0) {
                    printMemoryStatus("继续分配中...");
                }
            } catch (OutOfMemoryError e) {
                System.err.println("OOM! 停止分配");
                break;
            }
        }
        
        System.out.println("\n=== Demo完成 ===");
        System.out.println("观察gc-full-gc.log中的Full GC事件");
    }
    
    private static void allocateSomeObjects() {
        for (int i = 0; i < 10000; i++) {
            survivorList.add(new SmallObject(i));
        }
    }
    
    private static void printMemoryStatus(String label) {
        Runtime runtime = Runtime.getRuntime();
        long totalMemory = runtime.totalMemory();
        long freeMemory = runtime.freeMemory();
        long usedMemory = totalMemory - freeMemory;
        long maxMemory = runtime.maxMemory();
        
        System.out.printf("[%s] 堆使用: %dMB/%dMB (%.1f%%)%n",
            label,
            usedMemory / 1024 / 1024,
            maxMemory / 1024 / 1024,
            (double) usedMemory / maxMemory * 100
        );
    }
    
    // 小对象（快速在Young GC中回收）
    static class SmallObject {
        private int id;
        private byte[] data = new byte[100];
        
        public SmallObject(int id) {
            this.id = id;
        }
    }
    
    // 中等对象（需要更多内存）
    static class MediumObject {
        private int id;
        private byte[] data = new byte[1024 * 10]; // 10KB
        private String info;
        
        public MediumObject(int id) {
            this.id = id;
            this.info = "Object " + id + " with more data";
        }
    }
}
