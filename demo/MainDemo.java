import com.wjcoder.TargetClass;

public class MainDemo {
    public static void main(String[] args) throws InterruptedException {
        System.out.println("MainDemo started");
        
        // 调用被监控的类
        TargetClass.sayHello();
        int result = TargetClass.calculate(10, 20);
        System.out.println("Calculation result: " + result);
        
        // 保持运行一段时间，以便演示attach
        if (args.length > 0 && "wait".equals(args[0])) {
            System.out.println("Waiting for attach...");
            Thread.sleep(30000);
        }
        
        System.out.println("MainDemo finished");
    }
}
