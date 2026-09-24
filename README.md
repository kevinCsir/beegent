# Beegent

JiuwenSwarm 的原生移动客户端。

```text
hos/       HarmonyOS 客户端（ArkTS + ArkUI）
android/   Android 客户端（待迁移）
```

## HarmonyOS

使用 DevEco Studio 打开 `hos/`，不要将仓库根目录作为鸿蒙工程打开。
签名、构建、连接配置及功能说明见 [鸿蒙工程说明](hos/README.md)。

在仓库根目录编译：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\hos\scripts\build.ps1
```

## Android

目录已预留，尚未创建 Android 工程，见 [Android 迁移说明](android/README.md)。

本仓库不包含本机调试签名、模型密钥、依赖目录或构建产物。
