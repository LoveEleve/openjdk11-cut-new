package com.wjcoder;

public class TargetClass {
    public static void sayHello() {
        System.out.println("Hello from TargetClass!");
    }
    
    public static int calculate(int a, int b) {
        return a + b;
    }
    
    public static void main(String[] args) {
        System.out.println("TargetClass main method called");
        sayHello();
        int result = calculate(10, 20);
        System.out.println("Result: " + result);
    }
}