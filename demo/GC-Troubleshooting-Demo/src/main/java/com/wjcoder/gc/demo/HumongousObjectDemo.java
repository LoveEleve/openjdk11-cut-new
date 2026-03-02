package com.wjcoder.gc.demo;

import java.util.ArrayList;
import java.util.List;

/**
 * 大对象(Humongous)Demo - 模拟G1 Humongous对象分配
 * 
 * 场景：G1中，超过Region大小50%的对象被视为Humongous对象
 * 问题：Humongous对象直接分配在老年代，可能导致内存碎片和过早GC
 * 
 * 运行参数：
 * -Xms512m -Xmx512m -XX:+UseG1GC \
 * -XX:G1HeapRegionSize=1m \
 * -Xlog:gc*:file=gc-humongous.log:time,uptime,level,tags
 */
public class HumongousObjectDemo {
    
    // Region大小1MB，Humongous阈值 = 512KB (50%)
    private static final int HUMONGOUS_THRESHOLD = 512 * 1024; // 512KB
    
    private static List<byte[]> humongousObjects = new ArrayList<>();
    
    public static void main(String[] args) throws Exception {
        System.out.println("=== Humongous对象Demo启动 ===");
        System.out.println("JVM参数: -Xms512m -Xmx512m -XX:+UseG1GC -XX:G1HeapRegionSize=1m");
        System.out.println("模拟场景：频繁分配512KB+的大对象");
        System.out.println("Region大小1MB，Humongous阈值512KB（50%）");
        System.out.println();
        
        Runtime runtime = Runtime.getRuntime();
        long maxMemory = runtime.maxMemory();
        System.out.printf("最大堆内存: %dMB%n", maxMemory / 1024 / 1024);
        System.out.println();
        
        // 阶段1：分配正常小对象
        System.out.println("--- 阶段1：分配正常对象 ---");
        allocateNormalObjects(100);
        printMemoryStatus("正常对象分配后");
        Thread.sleep(1000);
        
        // 阶段2：开始分配Humongous对象
        System.out.println("\n--- 阶段2：分配Humongous对象（512KB+）---");
        for (int i = 1; i <= 20; i++) {
            // 分配600KB的大对象（超过512KB阈值）
            byte[] humongous = new byte[600 * 1024];
            humongousObjects.add(humongous);
            
            if (i % 5 == 0) {
                printMemoryStatus("已分配 " + i + " 个大对象");
            }
            
            Thread.sleep(200);
        }
        
        // 阶段3：分配更大的对象
        System.out.println("\n--- 阶段3：分配超大对象（跨Region）---");
        for (int i = 1; i <= 5; i++) {
            // 分配2.5MB的超大对象（需要多个连续Region）
            byte[] giant = new byte[2500 * 1024];
            humongousObjects.add(giant);
            printMemoryStatus("分配超大对象 #" + i + " (2.5MB)");
            Thread.sleep(500);
        }
        
        System.out.println("\n=== Demo完成 ===");
        System.out.println("观察gc-humongous.log中的Humongous regions数量");
        System.out.println("Humongous对象直接分配在老年代区域，不会经过Eden");
    }
    
    private static void allocateNormalObjects(int count) {
        List<Object> temp = new ArrayList<>();
        for (int i = 0; i < count; i++) {
            temp.add(new NormalObject(i));
        }
    }
    
    private static void printMemoryStatus(String label) {
        Runtime runtime = Runtime.getRuntime();
        long totalMemory = runtime.totalMemory();
        long freeMemory = runtime.freeMemory();
        long usedMemory = totalMemory - freeMemory;
        long maxMemory = runtime.maxMemory();
        
        System.out.printf("[%s] 堆使用: %dMB/%dMB (%.1f%%) | 大对象数: %d%n",
            label,
            usedMemory / 1024 / 1024,
            maxMemory / 1024 / 1024,
            (double) usedMemory / maxMemory * 100,
            humongousObjects.size()
        );
    }
    
    static class NormalObject {
        private int id;
        private String data;
        
        public NormalObject(int id) {
            this.id = id;
            this.data = "Normal object data " + id;
        }
    }
}
