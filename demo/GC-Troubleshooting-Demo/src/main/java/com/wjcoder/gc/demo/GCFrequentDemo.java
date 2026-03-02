package com.wjcoder.gc.demo;

import java.util.ArrayList;
import java.util.List;

/**
 * GC频繁Demo - 模拟高频率GC场景
 * 
 * 场景：小堆内存 + 高对象分配速率
 * 预期现象：频繁的Young GC，可能触发并发标记
 * 
 * 运行参数：
 * -Xms128m -Xmx128m -XX:+UseG1GC \
 * -Xlog:gc*:file=gc-frequent.log:time,uptime,level,tags \
 * -XX:+PrintGCDetails
 */
public class GCFrequentDemo {
    
    // 模拟业务对象，快速产生垃圾
    private static final List<Object> tempList = new ArrayList<>();
    
    public static void main(String[] args) throws Exception {
        System.out.println("=== GC频繁Demo启动 ===");
        System.out.println("JVM参数: -Xms128m -Xmx128m -XX:+UseG1GC");
        System.out.println("模拟场景：小堆 + 高分配速率 = 频繁GC");
        System.out.println();
        
        Runtime runtime = Runtime.getRuntime();
        long maxMemory = runtime.maxMemory();
        System.out.printf("最大堆内存: %dMB%n", maxMemory / 1024 / 1024);
        System.out.println();
        
        int round = 0;
        long startTime = System.currentTimeMillis();
        
        while (round < 100) {
            round++;
            
            // 快速分配大量临时对象
            allocateGarbage(10000);
            
            // 每10轮打印一次状态
            if (round % 10 == 0) {
                long elapsed = System.currentTimeMillis() - startTime;
                long usedMemory = runtime.totalMemory() - runtime.freeMemory();
                double usage = (double) usedMemory / maxMemory * 100;
                
                System.out.printf("[Round %d] 已运行: %.1fs | 堆使用: %.1f%%%n", 
                    round, elapsed / 1000.0, usage);
            }
            
            // 短暂休眠，让GC有机会执行
            Thread.sleep(50);
        }
        
        System.out.println("\n=== Demo完成 ===");
        System.out.println("观察gc-frequent.log中的GC频率");
    }
    
    private static void allocateGarbage(int count) {
        // 创建大量临时对象，很快变成垃圾
        for (int i = 0; i < count; i++) {
            // 创建各种大小的对象
            byte[] data = new byte[1024]; // 1KB对象
            
            // 偶尔创建一些存活稍久的对象
            if (i % 100 == 0) {
                tempList.add(new BusinessObject(i));
                
                // 保持列表大小可控，防止OOM
                if (tempList.size() > 1000) {
                    tempList.subList(0, 500).clear();
                }
            }
        }
    }
    
    // 模拟业务对象
    static class BusinessObject {
        private int id;
        private String name;
        private byte[] data;
        private long timestamp;
        
        public BusinessObject(int id) {
            this.id = id;
            this.name = "BusinessObject-" + id;
            this.data = new byte[1024 * 10]; // 10KB数据
            this.timestamp = System.currentTimeMillis();
        }
    }
}
