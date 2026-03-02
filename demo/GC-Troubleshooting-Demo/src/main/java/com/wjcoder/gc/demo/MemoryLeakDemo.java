package com.wjcoder.gc.demo;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/**
 * 内存泄漏Demo - 模拟电商订单缓存泄漏
 * 
 * 运行参数：
 * -Xms512m -Xmx512m -XX:+UseG1GC -XX:MaxGCPauseMillis=100 \
 * -Xlog:gc*:file=gc-memory-leak.log:time,uptime,level,tags \
 * -XX:+HeapDumpOnOutOfMemoryError \
 * -XX:HeapDumpPath=memory-leak-dump.hprof
 */
public class MemoryLeakDemo {
    
    // ★ 问题：静态Map，无容量限制，无过期时间
    private static final Map<String, Order> orderCache = new HashMap<>();
    
    private static long orderId = 0;
    
    public static void main(String[] args) throws Exception {
        System.out.println("=== 内存泄漏Demo启动 ===");
        System.out.println("JVM参数: -Xms512m -Xmx512m -XX:+UseG1GC");
        System.out.println("模拟场景：订单缓存无限增长");
        System.out.println();
        
        // 打印初始内存状态
        printMemoryStatus("初始状态");
        
        // 模拟订单创建
        while (true) {
            createOrder();
            
            // 每1000单打印一次状态
            if (orderId % 1000 == 0) {
                printMemoryStatus("已创建 " + orderId + " 单");
                
                // 检查是否接近OOM
                Runtime runtime = Runtime.getRuntime();
                long usedMemory = runtime.totalMemory() - runtime.freeMemory();
                long maxMemory = runtime.maxMemory();
                double usage = (double) usedMemory / maxMemory * 100;
                
                if (usage > 90) {
                    System.err.println("⚠ 内存使用超过90%，即将OOM！");
                    System.err.println("缓存条目数: " + orderCache.size());
                    
                    // 触发GC，看能否回收
                    System.out.println("触发System.gc()...");
                    System.gc();
                    Thread.sleep(1000);
                    
                    printMemoryStatus("GC后");
                    
                    if (orderCache.size() > 100000) {
                        System.out.println("\n=== 分析 ===");
                        System.out.println("缓存持有 " + orderCache.size() + " 个订单，无法回收");
                        System.out.println("这就是内存泄漏！");
                        break;
                    }
                }
            }
            
            // 模拟订单创建间隔
            if (orderId % 100 == 0) {
                Thread.sleep(10);
            }
        }
        
        // 保持运行，让OOM发生
        System.out.println("\n等待OOM...");
        Thread.sleep(60000);
    }
    
    private static void createOrder() {
        orderId++;
        
        Order order = new Order();
        order.setOrderId("ORDER_" + orderId);
        order.setUserId(orderId % 10000);
        order.setProductName("Product_" + (orderId % 1000));
        order.setAmount(100.0 + (orderId % 1000));
        order.setStatus("CREATED");
        
        // ★ 问题：无条件放入缓存，永不清理
        orderCache.put(order.getOrderId(), order);
    }
    
    private static void printMemoryStatus(String label) {
        Runtime runtime = Runtime.getRuntime();
        long totalMemory = runtime.totalMemory();
        long freeMemory = runtime.freeMemory();
        long usedMemory = totalMemory - freeMemory;
        long maxMemory = runtime.maxMemory();
        
        System.out.printf("[%s] 缓存: %d | 堆使用: %dMB/%dMB (%.1f%%)%n",
            label,
            orderCache.size(),
            usedMemory / 1024 / 1024,
            maxMemory / 1024 / 1024,
            (double) usedMemory / maxMemory * 100
        );
    }
    
    // 订单对象 - 模拟真实订单大小
    public static class Order {
        private String orderId;
        private long userId;
        private String productName;
        private double amount;
        private String status;
        private long createTime = System.currentTimeMillis();
        
        // 模拟其他字段，增加对象大小
        private String field1 = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
        private String field2 = "yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy";
        private String field3 = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz";
        
        // Getters and Setters
        public String getOrderId() { return orderId; }
        public void setOrderId(String orderId) { this.orderId = orderId; }
        public long getUserId() { return userId; }
        public void setUserId(long userId) { this.userId = userId; }
        public String getProductName() { return productName; }
        public void setProductName(String productName) { this.productName = productName; }
        public double getAmount() { return amount; }
        public void setAmount(double amount) { this.amount = amount; }
        public String getStatus() { return status; }
        public void setStatus(String status) { this.status = status; }
    }
}
