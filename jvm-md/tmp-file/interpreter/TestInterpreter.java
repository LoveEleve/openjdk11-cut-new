// 用于 GDB 调试解释器栈帧的测试类
public class TestInterpreter {
    private int field1 = 100;
    private Object field2 = null;
    
    public static void main(String[] args) {
        TestInterpreter obj = new TestInterpreter();
        int result = obj.testMethod(10, 20, 30);
        System.out.println("Result: " + result);
    }
    
    // 普通方法：3个参数，2个额外局部变量
    public int testMethod(int a, int b, int c) {
        int local1 = a + b;      // 额外局部变量1
        int local2 = local1 + c; // 额外局部变量2
        return local2;
    }
    
    // 同步方法
    public synchronized int syncMethod(int x) {
        return x * 2;
    }
}
