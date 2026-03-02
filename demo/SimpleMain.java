public class SimpleMain {
    public static void main(String[] args) {
        System.out.println("SimpleMain started");
        System.out.println("Calling some methods...");
        
        // 做一些简单的事情
        for (int i = 1; i <= 3; i++) {
            System.out.println("Step " + i + " completed");
            try {
                Thread.sleep(500);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
        
        System.out.println("SimpleMain finished");
    }
}
