import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'player_adapter.dart';

/// 真机调试开关：起播路径关键步骤打印到 console（adb logcat | grep jellfin）。
/// 线上构建保留 true——播放失败时没有日志两眼一抹黑，开销可忽略。
const _debug = bool.fromEnvironment('dart.vm.product_mode', defaultValue: true)
    ? kDebugMode
    : true;

/// media_kit（libmpv/FFmpeg）实现：Android 走 libmpv 原生播放。
///
/// 与 `video_player`（ExoPlayer）相比，media_kit 的优势：
/// - 硬解失败时自动回退 FFmpeg 软解，不会报 MediaCodecVideoRenderer error；
/// - 自动根据 URL 检测 HLS 格式，无需 formatHint；
/// - 起播更稳定（Mate 30 / Kirin 990 实测）。
///
/// 每次 [open] 都重建底层 Player——切画质本质是换一条完全不同的流，
/// 复用 Player 在 HLS ↔ 直链之间切换会留下脏状态。
class MediaKitAdapter implements PlayerAdapter {
  final _states = StreamController<PlayerAdapterState>.broadcast();

  /// 供 UI 渲染画面；每次切流都会指向新的 controller。
  final ValueNotifier<VideoController?> controller =
      ValueNotifier<VideoController?>(null);

  PlayerAdapterState _state = const PlayerAdapterState();
  Player? _active;
  bool _disposed = false;

  @override
  PlayerAdapterState get state => _state;

  @override
  Stream<PlayerAdapterState> get states => _states.stream;

  void _emit(PlayerAdapterState next) {
    if (_disposed) return;
    _state = next;
    _states.add(next);
  }

  @override
  Future<void> open(String url,
      {Duration start = Duration.zero,
      bool isHls = false,
      Map<String, String>? httpHeaders,
      int? hlsBitrate}) async {
    final previous = _active;
    // media_kit 自动检测 HLS/直链格式，无需 formatHint。
    // 每次切流都建新 Player，避免脏状态。
    // logLevel=info：把 libmpv 的 info 级日志也透到 stream.log，方便真机排查起播失败
    // （默认 error 级只在失败后给一句话，看不到 HLS 解析/demux 阶段的上下文）。
    final next = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.info),
    );
    _active = next;

    // 订阅所有状态流
    next.stream.position.listen((Duration position) {
      if (_disposed || !identical(next, _active)) return;
      _emit(_state.copyWith(position: position));
    });
    next.stream.duration.listen((Duration duration) {
      if (_disposed || !identical(next, _active)) return;
      _emit(_state.copyWith(duration: duration));
    });
    next.stream.playing.listen((bool playing) {
      if (_disposed || !identical(next, _active)) return;
      _emit(_state.copyWith(playing: playing));
    });
    next.stream.buffering.listen((bool buffering) {
      if (_disposed || !identical(next, _active)) return;
      _emit(_state.copyWith(buffering: buffering));
    });
    next.stream.completed.listen((bool completed) {
      if (_disposed || !identical(next, _active)) return;
      _emit(_state.copyWith(completed: completed));
    });
    next.stream.error.listen((String error) {
      if (_disposed || !identical(next, _active)) return;
      if (_debug) debugPrint('[jellfin/player] mpv error: $error');
      _emit(_state.copyWith(error: error));
    });
    // libmpv 日志：info 级，排查 HLS demux/网络问题时关键。
    next.stream.log.listen((PlayerLog log) {
      if (_debug && (log.level == 'error' || log.level == 'warn')) {
        debugPrint('[jellfin/player] mpv ${log.level}/${log.prefix}: ${log.text}');
      }
    });

    try {
      if (_debug) {
        debugPrint('[jellfin/player] open url=$url isHls=$isHls '
            'headers=${httpHeaders?.keys.join(",") ?? "-"} start=$start '
            'hlsBitrate=${hlsBitrate ?? "-"}');
      }
      // 创建 Media 对象。
      // HLS 流走本地代理转发，请求头由服务端注入，不需要 httpHeaders。
      // 直链（raw）走 302 到网盘 CDN：115 必须携带 Cookie/UA，否则 CDN 拒绝；
      // libmpv 跟随 302 时默认会保留自定义 header，因此把网盘必需头透传给 mpv。
      final media = httpHeaders != null && httpHeaders.isNotEmpty
          ? Media(url, httpHeaders: httpHeaders)
          : Media(url);
      // 服务端不论请求哪个档位都下发含全部视频流的主清单，而 mpv 默认
      // hls-bitrate=max 只认最高码率那一路——不钉住码率，切档就等于没切。
      // 钉到目标档位的 BANDWIDTH 后 mpv 选「不高于该值的最高码率」，正好命中该档，
      // 且主清单里独立成组的音轨照常生效（收敛到视频媒体清单会没声音）。
      //
      // setProperty 只在原生 NativePlayer 上有（web stub 没有这个方法），因此用
      // dynamic 调用 + try/catch：拿不到该能力时退回服务端原始行为，不能因此起播失败。
      if (hlsBitrate != null) {
        try {
          await (next.platform as dynamic)
              .setProperty('hls-bitrate', '$hlsBitrate');
          if (_debug) {
            debugPrint('[jellfin/player] pinned hls-bitrate=$hlsBitrate');
          }
        } catch (error) {
          if (_debug) {
            debugPrint('[jellfin/player] hls-bitrate pin failed: $error');
          }
        }
      }
      await next.open(media, play: false);
      if (_debug) debugPrint('[jellfin/player] mpv open returned, seeking=$start');
      if (start > Duration.zero) {
        await next.seek(start);
      }
      // 创建 VideoController。
      // 对华为麒麟 990 等设备，禁用硬件加速可以避免兼容性问题（libmpv
      // 硬解失败时自动回退 FFmpeg 软解，但禁用硬解能跳过不稳定的初始化路径）。
      controller.value = VideoController(
        next,
        configuration: const VideoControllerConfiguration(
          enableHardwareAcceleration: false,
        ),
      );
      _emit(_state.copyWith(
        duration: next.state.duration,
        position: start,
        buffering: false,
      ));
    } catch (error) {
      if (_debug) debugPrint('[jellfin/player] open FAILED: $error');
      _emit(_state.copyWith(error: '$error', buffering: false));
      rethrow;
    } finally {
      // 新流就位后再关旧的，避免切档时画面闪黑。
      await previous?.dispose();
    }
  }

  @override
  Future<void> play() async => _active?.play();

  @override
  Future<void> pause() async => _active?.pause();

  @override
  Future<void> seek(Duration to) async => _active?.seek(to);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _active?.dispose();
    _active = null;
    controller.value = null;
    await _states.close();
  }
}