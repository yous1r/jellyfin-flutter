# APK 产物说明

由 `tool/build-apk.sh` 生成。四个包功能完全一致，只是打包的 CPU 架构不同。

## 装哪个

| 文件 | 体积 | 适用 |
| --- | --- | --- |
| `jellfin-<ver>-arm64-v8a.apk` | ~19 MB | **绝大多数设备选这个**：2017 年后的手机、主流 Android TV / 电视盒子 |
| `jellfin-<ver>-armeabi-v7a.apk` | ~17 MB | 老旧 32 位设备、部分低端电视盒子 |
| `jellfin-<ver>-x86_64.apk` | ~21 MB | 模拟器、x86 平板（真机基本用不到） |
| `jellfin-<ver>-universal.apk` | ~53 MB | 不确定架构时的保底选择，装谁都能跑 |

查设备架构：`adb shell getprop ro.product.cpu.abi`

## 两个坑

1. **versionCode 不同**：拆分包按 Flutter 惯例带 ABI 偏移
   （armeabi-v7a=1001、arm64-v8a=2001、x86_64=4001），通用包是 1。
   先装了拆分包再装通用包会被系统当作**降级**拒绝，需先卸载。
2. **debug 密钥签名**：`android/app/build.gradle.kts` 里 release 仍用
   `signingConfigs.debug`。侧载没问题，但上不了应用商店；换成正式 keystore 后
   已装版本必须卸载重装（签名不同无法覆盖升级）。

## 体积说明

包体大头是 Flutter 引擎（`libflutter.so` 11 MB）与 Dart AOT 产物
（`libapp.so` 6 MB），两者都无法再压；`classes.dex` 只有 2 MB，
开 R8 代码压缩最多再省 1 MB 左右，不值得为此引入反射类被误删的风险。
拆包已经是这里能拿到的主要收益。
