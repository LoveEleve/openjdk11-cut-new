/**
 * 简单死循环程序，用于观察 JVM 线程
 */
public class LoopDemo {
    public static void main(String[] args) {
        System.out.println("LoopDemo started, PID: " + ProcessHandle.current().pid());
        System.out.println("Press Ctrl+C to exit...");
        
        // 死循环
        while (true) {
            try {
                Thread.sleep(1000);
            } catch (InterruptedException e) {
                break;
            }
        }
    }
}
