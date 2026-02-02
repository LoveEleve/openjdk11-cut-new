# 常用编译命令

## 编译 HotSpot（JVM 核心）
```bash
cd /data/workspace/openjdk-cut-new
make -f make/Main.gmk SPEC=/data/workspace/openjdk-cut-new/build-config/spec.gmk split-hotspot
```

## 编译 java.base（包含 java.c 启动器）
```bash
cd /data/workspace/openjdk-cut-new
make -f make/Main.gmk SPEC=/data/workspace/openjdk-cut-new/build-config/spec.gmk split-java.base-libs
```

## 编译全部
```bash
cd /data/workspace/openjdk-cut-new
make -f make/Main.gmk SPEC=/data/workspace/openjdk-cut-new/build-config/spec.gmk
```

## 清理编译
```bash
cd /data/workspace/openjdk-cut-new
make -f make/Main.gmk SPEC=/data/workspace/openjdk-cut-new/build-config/spec.gmk clean
```

## 编译产物位置
- java 命令: `build/linux-x86_64-normal-server-slowdebug/jdk/bin/java`
- libjvm.so: `build/linux-x86_64-normal-server-slowdebug/jdk/lib/server/libjvm.so`
