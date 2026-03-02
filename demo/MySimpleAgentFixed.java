import java.lang.instrument.Instrumentation;
import java.lang.instrument.ClassFileTransformer;
import java.security.ProtectionDomain;
import java.lang.instrument.IllegalClassFormatException;

public class MySimpleAgentFixed {
    
    // Premain方法 - 启动时加载
    public static void premain(String agentArgs, Instrumentation inst) {
        System.out.println("[Agent] MySimpleAgentFixed.premain() called with args: " + agentArgs);
        System.out.println("[Agent] Adding transformer...");
        inst.addTransformer(new LoggingClassTransformer());
    }
    
    // Agentmain方法 - 运行时attach加载
    public static void agentmain(String agentArgs, Instrumentation inst) {
        System.out.println("[Agent] MySimpleAgentFixed.agentmain() called with args: " + agentArgs);
        System.out.println("[Agent] Adding transformer...");
        inst.addTransformer(new LoggingClassTransformer(), true);
    }
    
    // 简单的日志类转换器（不修改字节码，只打印信息）
    static class LoggingClassTransformer implements ClassFileTransformer {
        @Override
        public byte[] transform(ClassLoader loader, String className, 
                              Class<?> classBeingRedefined,
                              ProtectionDomain protectionDomain,
                              byte[] classfileBuffer) throws IllegalClassFormatException {
            
            // 将斜杠转换为点，方便阅读
            String simpleName = className.replace('/', '.');
            System.out.println("[Agent] Loading class: " + simpleName + " (size: " + classfileBuffer.length + " bytes)");
            
            // 返回null表示不修改字节码
            return null;
        }
    }
}