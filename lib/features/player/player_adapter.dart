import 'dart:async';

/// 播放器实时状态。position/duration 由具体实现按帧或定时推送。
///
/// 注意：media_kit 也定义了 `PlayerState`，为避免导入冲突重命名为
/// `PlayerAdapterState`。
class PlayerAdapterState {
  final Duration position;
  final Duration duration;
  final bool playing;
  final bool buffering;
  final bool completed;
  final String? error;

  const PlayerAdapterState({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.error,
  });

  PlayerAdapterState copyWith({
    Duration? position,
    Duration? duration,
    bool? playing,
    bool? buffering,
    bool? completed,
    String? error,
  }) =>
      PlayerAdapterState(
        position: position ?? this.position,
        duration: duration ?? this.duration,
        playing: playing ?? this.playing,
        buffering: buffering ?? this.buffering,
        completed: completed ?? this.completed,
        error: error ?? this.error,
      );
}

/// 播放器抽象：把「取哪一路流、什么时候切」与「用什么引擎播」解耦。
///
/// 切画质就是 `open(新档位 URL, start: 当前位置)`——多视频流模式下每个档位都是一条
/// 独立可播地址，不依赖引擎自己的 ABR，因此这个接口足够表达全部画质切换行为。
/// 单测用 FakePlayerAdapter 验证控制流，真机播放走手动验收。
abstract class PlayerAdapter {
  /// 打开一路流；[start] 用于切档/续播时的定位。
  ///
  /// [isHls] 必须由调用方明确告知，不能让播放器自己猜：本项目的播放地址形如
  /// `.../play/115/pick1?resolution=4k`，没有 `.m3u8` 后缀，而 ExoPlayer 默认
  /// 按 URL 后缀推断容器，会把 HLS 清单文本当成 MP4 解析并解码失败。
  ///
  /// [httpHeaders]：直链（如 115 原画 302 到 CDN）跟随重定向时播放器需要携带的
  /// 请求头（网盘 Cookie/UA）。HLS 走本站代理转发，由服务端注入，无需在此提供。
  ///
  /// [hlsBitrate]：当 [url] 仍是一张多变体主清单时，把播放器的变体选择钉到这个码率
  /// （mpv `hls-bitrate`）。服务端不论请求哪个档位都下发全部视频流，而播放器默认取
  /// 最高码率，不钉住就等于没切档。
  Future<void> open(String url,
      {Duration start = Duration.zero,
      bool isHls = false,
      Map<String, String>? httpHeaders,
      int? hlsBitrate});

  Stream<PlayerAdapterState> get states;

  PlayerAdapterState get state;

  Future<void> play();

  Future<void> pause();

  Future<void> seek(Duration to);

  Future<void> dispose();
}
