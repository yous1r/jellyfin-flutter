import 'dart:async';

import 'package:jellfin_flutter/features/player/player_adapter.dart';

/// 记录所有 open/seek 调用的假播放器，用来验证切档控制流。
class FakePlayerAdapter implements PlayerAdapter {
  final List<OpenCall> opens = [];
  final List<Duration> seeks = [];
  int playCount = 0;
  int disposeCount = 0;

  /// 置为非 null 时，下一次 open 抛出该异常（模拟切档失败）。
  Object? failNextOpen;

  /// 前 N 次 open 调用失败（抛出 StateError），之后成功。
  int failOpensBefore = 0;
  int _openAttempt = 0;

  final _states = StreamController<PlayerAdapterState>.broadcast();
  PlayerAdapterState _state = const PlayerAdapterState();

  @override
  PlayerAdapterState get state => _state;

  @override
  Stream<PlayerAdapterState> get states => _states.stream;

  /// 测试里推进播放进度。
  void emit(PlayerAdapterState next) {
    _state = next;
    _states.add(next);
  }

  @override
  Future<void> open(String url,
      {Duration start = Duration.zero,
      bool isHls = false,
      Map<String, String>? httpHeaders,
      int? hlsBitrate}) async {
    _openAttempt++;
    final failure = failNextOpen;
    if (failure != null) {
      failNextOpen = null;
      throw failure;
    }
    if (_openAttempt <= failOpensBefore) {
      throw StateError('模拟起播失败 (#$_openAttempt)');
    }
    opens.add(OpenCall(url, start,
        isHls: isHls, httpHeaders: httpHeaders, hlsBitrate: hlsBitrate));
    _state = _state.copyWith(position: start);
  }

  @override
  Future<void> play() async => playCount++;

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration to) async => seeks.add(to);

  @override
  Future<void> dispose() async {
    disposeCount++;
    await _states.close();
  }
}

class OpenCall {
  final String url;
  final Duration start;
  final bool isHls;
  final Map<String, String>? httpHeaders;

  /// 非空表示调用方要求播放器把 HLS 变体钉到该码率（mpv hls-bitrate）。
  final int? hlsBitrate;

  const OpenCall(this.url, this.start,
      {this.isHls = false, this.httpHeaders, this.hlsBitrate});

  @override
  String toString() => 'OpenCall($url, $start, isHls: $isHls, '
      'httpHeaders: $httpHeaders, hlsBitrate: $hlsBitrate)';
}
