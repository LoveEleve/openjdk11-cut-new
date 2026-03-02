import java.lang.instrument.Instrumentation;
import java.lang.instrument.ClassFileTransformer;
import java.security.ProtectionDomain;
import java.lang.instrument.IllegalClassFormatException;

public class MySimpleAgent {
    
    // Premain方法 - 启动时加载
    public static void premain(String agentArgs, Instrumentation inst) {
        System.out.println("MySimpleAgent.premain() called with args: " + agentArgs);
        inst.addTransformer(new SimpleClassTransformer());
    }
    
    // Agentmain方法 - 运行时attach加载
    public static void agentmain(String agentArgs, Instrumentation inst) {
        System.out.println("MySimpleAgent.agentmain() called with args: " + agentArgs);
        inst.addTransformer(new SimpleClassTransformer(), true);
    }
    
    // 简单的类转换器
    static class SimpleClassTransformer implements ClassFileTransformer {
        @Override
        public byte[] transform(ClassLoader loader, String className, 
                              Class<?> classBeingRedefined,
                              ProtectionDomain protectionDomain,
                              byte[] classfileBuffer) throws IllegalClassFormatException {
            
            // 只转换特定的类
            if ("com/wjcoder/TargetClass".equals(className)) {
                System.out.println("Transforming class: " + className);
                
                // 这里应该返回修改后的字节码
                // 为了演示，我们返回一个简单的修改标记
                String message = "\n// Transformed by MySimpleAgent at " + System.currentTimeMillis() + "\n";
                byte[] messageBytes = message.getBytes();
                
                // 合并原字节码和新消息（简化演示）
                byte[] result = new byte[classfileBuffer.length + messageBytes.length];
                System.arraycopy(classfileBuffer, 0, result, 0, classfileBuffer.length);
                System.arraycopy(messageBytes, 0, result, classfileBuffer.length, messageBytes.length);
                
                return result;
            }
            return null; // 返回null表示不修改
        }
    }
}