# jellfin-flutter

Jellyfin/Emby 协议兼容的自研 Flutter 客户端，配合 [python-strm](../python-strm) 的
Emby 代理与网盘 STRM 播放链路使用。目标平台：Android（手机/TV）与 Web。

核心差异化能力：**多视频流画质切换**。服务端开启 `strm.playback_mode: multistream`
后，原画直链与各转码档并列下发，客户端自己渲染画质菜单、自己切流（切档保留播放位置，
并记住上次选择）。服务端没开这个模式时自动退化到 PlaybackInfo 的 MediaSource 列表，
因此对着原生 Emby/Jellyfin 服务器也能正常工作。

## 开发环境

- Flutter SDK：`/vol1/docker-data/flutter-sdk/flutter-3.44.9`（stable 3.44.9）
  - 同目录的 `flutter/` 是一份残缺安装（缺 `packages/flutter_tools` 与 git 对象），**不要用**
- 环境变量见 `tool/env.sh`（SDK 路径 + 国内镜像）

```bash
source tool/env.sh
flutter pub get
flutter analyze            # 静态检查
flutter test               # 单测
flutter build web          # Web 产物 build/web，可由 NAS 静态托管
flutter build apk --debug  # Android 调试包
```

## 结构

```
lib/
  core/
    api/        EmbyApiClient —— 认证、Items、PlaybackInfo、进度上报
    strm/       StrmApiClient —— 多视频流清单 /streams、档位播放 URL、probe 回退
    models/     Emby 协议数据模型
    storage/    会话 / 设备 ID / 画质偏好持久化
    providers.dart  Riverpod 装配与登录态
  features/
    auth/ home/ library/ detail/ player/ search/ common/
  app.dart      go_router 路由 + 深色主题
  main.dart
```

播放层分三块：`PlayerAdapter`（抽象）、`VideoPlayerAdapter`（video_player 实现）、
`PlaybackController`（编排：解析多路流 → 选档 → 切档 → 进度上报）。控制流全部可单测，
真机播放走手动验收。

## 设计文档

- 客户端：`docs/design.md`
- 多视频流服务端协议：`../python-strm/docs/superpowers/specs/2026-08-14-multistream-playback-design.md`
