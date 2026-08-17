import 'dart:async';
import 'dart:developer' as developer;

import '../../core/api/emby_api_client.dart';
import '../../core/models/models.dart';
import '../../core/storage/session_store.dart';
import '../../core/strm/strm_api_client.dart';
import 'player_adapter.dart';

class PlaybackState {
  final bool loading;
  final Object? error;
  final BaseItem? item;

  /// 可选画质列表（多视频流清单，或从 PlaybackInfo 的多 MediaSource 推导）。
  final List<PlaybackStream> streams;
  final String currentResolution;
  final bool switching;

  const PlaybackState({
    this.loading = true,
    this.error,
    this.item,
    this.streams = const [],
    this.currentResolution = '',
    this.switching = false,
  });

  PlaybackStream? get current {
    for (final stream in streams) {
      if (stream.resolution == currentResolution) return stream;
    }
    return streams.isEmpty ? null : streams.first;
  }

  PlaybackState copyWith({
    bool? loading,
    Object? error,
    BaseItem? item,
    List<PlaybackStream>? streams,
    String? currentResolution,
    bool? switching,
    bool clearError = false,
  }) =>
      PlaybackState(
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
        item: item ?? this.item,
        streams: streams ?? this.streams,
        currentResolution: currentResolution ?? this.currentResolution,
        switching: switching ?? this.switching,
      );
}

/// 播放编排：解析可播的多路流 → 选档 → 驱动播放器 → 上报进度。
///
/// 画质来源有两级，保证既能吃到 python-strm 的增强能力，也能对着原生 Emby 工作：
/// 1. `/api/v1/strm/streams` 多视频流清单（含原画/转码档、分辨率、是否 HLS）；
/// 2. 退化到 PlaybackInfo 的多 MediaSource——multistream 模式下服务端已按档位展开，
///    原生 Emby 服务器则至少有一路默认源。
class PlaybackController {
  final EmbyApiClient emby;
  final StrmApiClient? strm;
  final SessionStore? store;
  final PlayerAdapter adapter;
  final String itemId;
  final Duration startAt;

  PlaybackState _state = const PlaybackState();
  final _controller = StreamController<PlaybackState>.broadcast();

  String _playSessionId = '';
  String _mediaSourceId = '';
  Timer? _progressTimer;
  StreamSubscription<PlayerAdapterState>? _playerSub;
  bool _disposed = false;

  PlaybackController({
    required this.emby,
    required this.adapter,
    required this.itemId,
    this.strm,
    this.store,
    this.startAt = Duration.zero,
  });

  PlaybackState get state => _state;

  Stream<PlaybackState> get states => _controller.stream;

  void _emit(PlaybackState next) {
    if (_disposed) return;
    _state = next;
    _controller.add(next);
  }

  Future<void> load() async {
    _emit(_state.copyWith(loading: true, clearError: true));
    try {
      final item = await emby.itemDetail(itemId);
      final info = await emby.playbackInfo(itemId);
      developer.log('PlaybackInfo sources=${info.mediaSources.length} '
          'first.id=${info.mediaSources.isEmpty ? "-" : info.mediaSources.first.id} '
          'first.playUrl=${info.mediaSources.isEmpty ? "-" : info.mediaSources.first.playUrl}',
          name: 'jellfin/playback');
      if (info.mediaSources.isEmpty) {
        throw StateError('服务端没有返回可播放源');
      }
      _playSessionId = info.playSessionId;
      _mediaSourceId = info.mediaSources.first.id;

      final streams = await _resolveStreams(info.mediaSources);
      developer.log('resolved streams=${streams.length} '
          'resolutions=${streams.map((s) => s.resolution).join(",")}',
          name: 'jellfin/playback');
      if (streams.isEmpty) throw StateError('没有可播放的视频流');

      // 一个标记区分「用户已记住档位」：记住的档位应直接作为首选，
      // 不要被 HLS 优先策略覆盖。
      PlaybackStream? preferred;
      final remembered = store?.preferredResolution;
      if (remembered != null) {
        for (final stream in streams) {
          if (stream.resolution == remembered) {
            preferred = stream;
            break;
          }
        }
      }

      _emit(_state.copyWith(
        loading: false,
        item: item,
        streams: streams,
      ));

      // 按优先级顺序尝试每一路流，直到成功起播。
      // 原画直链（raw）走 302 到网盘 CDN，ExoPlayer 跟随重定向时丢失
      // 115 必需的特殊请求头（Cookie/UA），经常被 CDN 拒绝。HLS 流走
      // 本地代理转发，请求头完整，兼容性更好，排在前面尝试。
      final candidates = preferred != null
          ? [preferred, ..._playOrder(streams).where((s) => s != preferred)]
          : _playOrder(streams);
      Object? lastError;
      for (final chosen in candidates) {
        lastError = null;
        developer.log('trying stream resolution=${chosen.resolution} '
            'url=${chosen.url} isHls=${chosen.isHls} '
            'headers=${chosen.httpHeaders?.keys.join(",") ?? "-"}',
            name: 'jellfin/playback');
        _emit(_state.copyWith(
          currentResolution: chosen.resolution,
          clearError: true,
        ));
        try {
          final resolved = await _resolvePlayback(chosen);
          await adapter.open(
            resolved.url,
            start: startAt,
            isHls: chosen.isHls,
            httpHeaders: chosen.httpHeaders,
            hlsBitrate: resolved.hlsBitrate,
          );
          await adapter.play();
          developer.log('stream started resolution=${chosen.resolution}',
              name: 'jellfin/playback');
          _watchPlayer();
          await _reportPlaying();
          _startProgressTimer();
          return; // 起播成功，跳出循环
        } catch (error) {
          developer.log('stream FAILED resolution=${chosen.resolution}: $error',
              name: 'jellfin/playback');
          lastError = error;
          // 等待一小段时间让播放器清理状态，再试下一路流
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }
      // 全部流都尝试失败，报最后一个错误
      throw lastError ?? StateError('所有视频流均无法播放');
    } catch (error) {
      _emit(_state.copyWith(loading: false, error: error));
    }
  }

  /// 按优先级排列播放候选流：HLS（1080P → 720P → 其他 HLS）→ 原画直链。
  List<PlaybackStream> _playOrder(List<PlaybackStream> streams) {
    final result = <PlaybackStream>[];
    final hls = <PlaybackStream>[];
    final direct = <PlaybackStream>[];
    for (final s in streams) {
      (s.isHls ? hls : direct).add(s);
    }
    // HLS 流：按分辨率降序，优先 1080P（码率适中，解码压力小）
    hls.sort((a, b) => _resolutionScore(b.resolution)
        .compareTo(_resolutionScore(a.resolution)));
    result.addAll(hls);
    // 直链流：原画优先
    direct.sort((a, b) => (a.isOriginal ? 0 : 1).compareTo(b.isOriginal ? 0 : 1));
    result.addAll(direct);
    return result;
  }

  static int _resolutionScore(String res) {
    const scores = {
      'ud': 90, 'super': 85, 'high': 70, 'hd': 70,
      'normal': 50, 'sd': 50, 'low': 30, '4k': 100, '2k': 95,
    };
    return scores[res] ?? 0;
  }

  /// 优先多视频流清单；拿不到就把 PlaybackInfo 的每个 MediaSource 当一路流。
  Future<List<PlaybackStream>> _resolveStreams(
      List<MediaSourceInfo> sources) async {
    final target = StrmPlayTarget.tryParse(sources.first.playUrl);
    if (strm != null && target != null) {
      final manifest = await strm!.playbackStreams(target);
      if (manifest.isNotEmpty) return manifest;
    }
    return [
      for (final source in sources)
        PlaybackStream(
          resolution: source.id,
          displayName: source.name.isEmpty ? '默认' : source.name,
          // 服务端 multistream 下 container 是可信的；缺省时按直链处理
          // （原生 Emby 的本地源就是直链），由 PlaybackStream.isHls 兜底判断。
          container: source.container.isEmpty ? 'mkv' : source.container,
          isOriginal: source.container != 'm3u8',
          url: source.playUrl,
          // 直链（如 115 原画 302 到 CDN）所需的请求头透传给播放器；HLS 档位走
          // 本站代理转发，服务端注入头，此处置空，不污染媒体清单请求。
          httpHeaders: source.requiredHttpHeaders.isEmpty
              ? null
              : source.requiredHttpHeaders,
        ),
    ];
  }

  /// 切画质：记录当前位置 → 用新档位地址重开 → 定位回去。
  Future<void> switchTo(String resolution) async {
    if (resolution == _state.currentResolution || _state.switching) return;
    PlaybackStream? next;
    for (final stream in _state.streams) {
      if (stream.resolution == resolution) next = stream;
    }
    if (next == null) return;

    final resumeAt = adapter.state.position;
    _emit(_state.copyWith(switching: true, clearError: true));
    try {
      final resolved = await _resolvePlayback(next);
      developer.log('switching to resolution=$resolution url=${resolved.url} '
          'hlsBitrate=${resolved.hlsBitrate ?? "-"}',
          name: 'jellfin/playback');
      await adapter.open(
        resolved.url,
        start: resumeAt,
        isHls: next.isHls,
        httpHeaders: next.httpHeaders,
        hlsBitrate: resolved.hlsBitrate,
      );
      await adapter.play();
      await store?.setPreferredResolution(resolution);
      _emit(_state.copyWith(currentResolution: resolution, switching: false));
    } catch (error) {
      // 切档失败保留原档位标记，让用户知道当前还在播哪一路。
      _emit(_state.copyWith(switching: false, error: error));
    }
  }

  /// 把档位收敛成真正只播该档的地址。
  ///
  /// 服务端每次都按多视频流下发（`?resolution=high` 也返回含全部档位的主清单，直链
  /// 档位的 302 还会把 resolution 丢掉），所以选档必须落在客户端：这里请求实际的
  /// 播放地址，拿不到 strm 客户端（原生 Emby）时退回服务端给的原始地址。
  Future<ResolvedPlayback> _resolvePlayback(PlaybackStream stream) async {
    final client = strm;
    if (client == null) return ResolvedPlayback(stream.url);
    return client.resolvePlaybackUrl(stream);
  }

  void _watchPlayer() {
    _playerSub = adapter.states.listen((PlayerAdapterState playerState) {
      if (playerState.completed) _reportStopped();
    });
  }

  void _startProgressTimer() {
    _progressTimer?.cancel();
    // Emby 客户端惯例：10 秒一次心跳，够断点续播用又不至于打爆服务端。
    _progressTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _reportProgress(),
    );
  }

  Future<void> _reportPlaying() => _guard(() => emby.reportPlaying(
        itemId: itemId,
        playSessionId: _playSessionId,
        mediaSourceId: _mediaSourceId,
        positionTicks: startAt.inMicroseconds * 10,
      ));

  Future<void> _reportProgress() => _guard(() => emby.reportProgress(
        itemId: itemId,
        playSessionId: _playSessionId,
        mediaSourceId: _mediaSourceId,
        positionTicks: adapter.state.position.inMicroseconds * 10,
        isPaused: !adapter.state.playing,
      ));

  Future<void> _reportStopped() => _guard(() => emby.reportStopped(
        itemId: itemId,
        playSessionId: _playSessionId,
        mediaSourceId: _mediaSourceId,
        positionTicks: adapter.state.position.inMicroseconds * 10,
      ));

  /// 进度上报失败不能打断播放（离线/服务端抖动都很常见）。
  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {}
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _progressTimer?.cancel();
    await _reportStopped();
    await _playerSub?.cancel();
    _disposed = true;
    await _controller.close();
    await adapter.dispose();
  }
}
