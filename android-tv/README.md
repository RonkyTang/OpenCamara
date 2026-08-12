# OpenCamara TV

面向某米电视和其他 Android TV 设备的 USB 摄像头实时预览应用。

## 运行要求

- 电视系统：Android 6.0（API 23）或更高版本
- 摄像头：支持 UVC（USB Video Class）的免驱 USB 摄像头
- 电视固件需要将 USB 摄像头开放给 Android 外置摄像头服务（Camera2 external camera provider）

最后一项由电视厂商固件决定。应用能检测到 UVC 设备，但如果电视没有开放外置摄像头服务，第三方应用无法取得视频流；此时应用会显示明确提示。优先使用某米电视官方支持的摄像头或经该电视型号验证过的 UVC 摄像头。

## 在某米电视上安装

### 使用 U 盘

1. 将 `OpenCamaraTV-debug.apk` 复制到 U 盘。
2. 在电视的“设置 → 账号与安全”中允许安装未知来源应用。
3. 用电视文件管理器打开 APK 并安装。
4. 插入 USB 摄像头，再从应用列表启动 **OpenCamara TV**。
5. 首次启动时允许摄像头权限和 USB 设备访问权限。

不同 MIUI for TV / 某米电视系统版本的设置名称可能略有差异。

### 使用 ADB

先在电视中开启开发者模式和网络调试，然后在电脑执行：

```bash
adb connect <电视的 IP 地址>:5555
adb install -r OpenCamaraTV-debug.apk
```

## 从源码构建

用 Android Studio 打开本目录，等待项目同步完成后运行 `app`。也可以在已安装 JDK 17 和 Android SDK 的环境中执行：

```bash
./gradlew assembleDebug
```

输出文件位于：

```text
app/build/outputs/apk/debug/app-debug.apk
```

工程使用 Android Gradle Plugin 9.0、Gradle 9.1 和 compileSdk 35；构建机需安装 Android SDK Platform 35 与 Build Tools 36.0.0。安装包同时声明 Android TV 与普通 Android 启动入口，以兼容部分某米电视的定制桌面。

## 使用方式

- 启动后应用自动寻找已连接的 UVC 摄像头。
- 如果摄像头尚未连接，请插入后用遥控器选择“重新检测”。
- 拔出摄像头后预览会自动停止；重新插入即可再次检测。
- 使用遥控器选择左下角“镜像”按钮可水平翻转画面，应用会记住上次选择。
- 使用“拍照”按钮可将当前画面保存为 JPG，位置为 `DCIM/OpenCamaraTV`，并自动加入系统相册索引。
- 实时预览不叠加全屏变暗遮罩。
- 按遥控器返回键退出。

## 常见问题

### 已检测到 USB 设备，但无法打开摄像头

这通常表示电视固件没有把该 USB 摄像头接入 Android Camera2 外置摄像头服务，而不是 USB 权限问题。可依次尝试：

1. 确认摄像头明确支持 UVC 1.0/1.1。
2. 换用电视的另一个 USB 接口，避免无供电 USB Hub。
3. 将摄像头分辨率能力限制在 1080p 或以下，或更换常见 720p/1080p UVC 摄像头。
4. 更新电视系统。
5. 使用某米官方适配该电视型号的摄像头。

### 画面卡顿或黑屏

- 优先将摄像头直接连接电视，不经过扩展坞。
- 4K 摄像头需同时提供 1080p 或 720p 输出档位；应用不会主动选择超过 1080p 的档位。
- 某些摄像头需要更高 USB 供电，可尝试带独立电源的 USB Hub。

## 当前范围

此版本只做实时预览，不录音、不录像，也不会上传或保存任何图像。所有画面都只在电视本机显示。
