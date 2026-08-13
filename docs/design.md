# jellfin-flutter 客户端设计（MVP）

日期：2026-08-13
状态：已确认（平台 Android + Web；范围 登录/浏览/播放/继续观看/搜索/字幕；服务端 python-strm Emby 代理）

## 1. 背景与目标

python-strm 通过 8097 端口提供 Emby 兼容代理（上游 fnOS trim @ 10.0.0.50:8005），并托管
115/夸克网盘的 STRM 播放链路（探测多档位能力、稳定播放 URL、进度拦截）。现有第三方客户端
（VidHub / trim_player）无法深度利用多档位能力。本项目提供自研 Flutter 客户端：

- 接口层完全兼容 Jellyfin/Emby 协议（`X-Emby-Authorization`），可对接任意 Emby 系服务端
- 深度配合 python-strm：档位探测接口 + 按 `resolution` 参数切换视频流，客户端自行切换画质
- 目标平台：Android（手机 + TV）、Web（NAS 直接部署静态站点）

## 2. 服务端接口面（与 VidHub 实测流量一致）

认证与会话：
- `POST /emby/Users/AuthenticateByName`（头 `X-Emby-Authorization: MediaBrowser Client=..., Device=..., DeviceId=..., Version=...`）
- 响应含 `AccessToken` + `User.Id`；后续请求带 `X-Emby-Token`

媒体库浏览：
- `GET /emby/Users/{userId}/Views` 媒体库列表
- `GET /emby/Users/{userId}/Items?ParentId=&IncludeItemTypes=&SortBy=&StartIndex=&Limit=` 分页海报墙
- `GET /emby/Users/{userId}/Items/Latest?ParentId=` 最新入库
- `GET /emby/Users/{userId}/Items/Resume` 继续观看
- `GET /emby/Shows/NextUp` 下一集
- `GET /emby/Shows/{seriesId}/Seasons` / `GET /emby/Shows/{seriesId}/Episodes?SeasonId=`
- `GET /emby/Users/{userId}/Items/{itemId}` 详情（MediaStreams/MediaSources/Overview/People）
- `GET /emby/Items/{itemId}/Images/Primary?maxWidth=&tag=` 图片（Primary/Backdrop/Thumb/Logo）
- `GET /emby/Users/{userId}/Items?SearchTerm=` 搜索

播放：
- `POST /emby/Items/{itemId}/PlaybackInfo` → MediaSources（代理注入 STRM 播放 URL）
- python-strm 增强接口：
  - `GET /api/v1/strm/probe/{cloud_type}/{file_id}` 已探测档位列表（resolution/protocol/playable）
  - `GET /api/v1/strm/play/{cloud_type}/{file_id}?resolution={r}` 指定档位播放（302/HLS）
- 进度上报：`POST /emby/Sessions/Playing` / `/Playing/Progress` / `/Playing/Stopped`

## 3. 架构

```
lib/
  core/
    api/        # EmbyApiClient（dio）：认证、Items、PlaybackInfo、进度上报
    strm/       # StrmApiClient：档位探测 / 档位播放 URL 构造
    models/     # 冻结数据类（Item/MediaSource/MediaStream/PlaybackVariant/User/Session）
    storage/    # 服务器地址 / token / 设备 ID 持久化（shared_preferences）
  features/
    auth/       # 服务器配置 + 登录页
    home/       # 媒体库 Views + 最新/继续观看横排
    library/    # 分页海报墙（网格 + 排序/筛选）
    detail/     # 电影/剧集详情、季/集列表
    player/     # 播放页：PlayerAdapter + 画质菜单 + 字幕选择 + 进度上报
    search/
  app.dart      # go_router 路由 + 主题
  main.dart
test/           # API 客户端单测（fixture JSON）、ViewModel 单测、widget 测试
```

状态管理 Riverpod；路由 go_router；网络 dio；图片 cached_network_image。

## 4. 播放器抽象（跨端关键设计）

```dart
abstract class PlayerAdapter {
  Future<void> open(String url, {Map<String, String> headers, Duration? start});
  Stream<PlayerState> get states;   // position/duration/buffering/error
  Future<void> setSubtitle(SubtitleTrack? track);
  Future<void> seek(Duration to); play(); pause(); dispose();
}
```

- Android 实现：`media_kit`（libmpv）——直链 MP4/MKV 与 HLS 全兼容，外挂字幕直接加载
- Web 实现：HTML5 `<video>` + hls.js（JS interop）——HLS 走 hls.js，MP4 直链原生播放
- 画质切换：切档 = 记录当前 position → open(新档位 URL, start: position)；
  档位列表来自 probe 接口；MediaSource 直链作为「原画」档
- 字幕：优先 MediaStreams 外挂字幕（`/Videos/{id}/{mediaSourceId}/Subtitles/...` 或代理下发地址）；
  内嵌字幕由 mpv 侧解复用（Web 端 MVP 仅支持外挂）

## 5. 里程碑

- M0 环境与脚手架：Flutter SDK（国内镜像）、`flutter create`（android,web）、依赖、CI 命令
  （`flutter analyze` + `flutter test`）全绿、web 构建可从 NAS 提供
- M1 API 客户端 + 登录（单测：认证头构造、token 持久化、401 处理）
- M2 首页（Views/Latest/Resume 横排）+ 海报墙分页
- M3 详情页 + 季/集导航
- M4 播放器（Android media_kit / Web hls.js）+ 画质切换 + 字幕 + 进度上报
- M5 搜索 + 继续观看闭环（NextUp、断点续播）
- M6 Android TV 焦点导航与遥控适配（MVP 后）

## 6. 测试策略

- core/api、core/strm：纯单测，fixture 采用真实代理响应脱敏样本
- ViewModel（Riverpod provider）：单测覆盖分页/错误/重试状态机
- 播放器抽象：接口层 fake 实现做交互单测；真机播放走手动验收清单
- 不追求 UI golden 测试（MVP 阶段）

## 7. 非目标（MVP 明确不做）

- 转码协商（DeviceProfile 上报最小集，直连直链/HLS 为主）
- 多用户管理、家长控制、下载离线
- 弹幕、评分刮削编辑
