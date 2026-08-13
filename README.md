# jellfin-flutter

Jellyfin/Emby 协议兼容的自研 Flutter 客户端，配合 [python-strm](../python-strm) 的
Emby 代理与网盘 STRM 播放链路使用。目标平台：Android（手机/TV）与 Web。

## 开发环境

- Flutter SDK（国内镜像）：`/vol1/docker-data/flutter-sdk/flutter`
- 环境变量（已在 `tool/env.sh` 提供）：
  - `PUB_HOSTED_URL=https://pub.flutter-io.cn`
  - `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`

```bash
source tool/env.sh
flutter pub get
flutter analyze
flutter test
flutter build web            # Web 产物 build/web，可由 NAS 静态托管
flutter build apk --debug    # Android 调试包
```

## 设计文档

见 `docs/design.md`（架构、服务端接口面、播放器抽象、里程碑）。
