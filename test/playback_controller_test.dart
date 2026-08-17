import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellfin_flutter/core/api/emby_api_client.dart';
import 'package:jellfin_flutter/core/storage/session_store.dart';
import 'package:jellfin_flutter/core/strm/strm_api_client.dart';
import 'package:jellfin_flutter/features/player/playback_controller.dart';
import 'package:jellfin_flutter/features/player/player_adapter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_adapter.dart';
import 'fake_player_adapter.dart';

const _itemJson = '{"Id":"item-1","Name":"琅琊榜","Type":"Movie"}';

/// multistream 模式下代理下发的 PlaybackInfo：每个档位一个 MediaSource。
const _playbackInfoJson = '''
{"PlaySessionId":"sess-1","MediaSources":[
 {"Id":"src-1","Name":"原画","Container":"mkv",
  "DirectStreamUrl":"http://proxy.test:8097/api/v1/strm/play/115/pick1?resolution=raw"},
 {"Id":"src-1-ud","Name":"1080P","Container":"m3u8",
  "DirectStreamUrl":"http://proxy.test:8097/api/v1/strm/play/115/pick1?resolution=ud"}]}
''';

/// 非网盘条目：只有一路本地源，解析不出 StrmPlayTarget。
const _localPlaybackInfoJson = '''
{"PlaySessionId":"sess-2","MediaSources":[
 {"Id":"src-2","Name":"Local","Container":"mkv",
  "DirectStreamUrl":"http://proxy.test:8097/videos/item-2/stream.mkv"}]}
''';

({EmbyApiClient emby, StrmApiClient strm, FakeAdapter adapter}) buildClients(
    Map<String, Object> routes) {
  final adapter = FakeAdapter(routes);
  final embyDio = Dio(BaseOptions(baseUrl: 'http://proxy.test:8097'));
  embyDio.httpClientAdapter = adapter;
  final emby = EmbyApiClient(
      baseUrl: 'http://proxy.test:8097', dio: embyDio, deviceId: 'dev');
  emby.restoreSession(userId: 'u1', token: 'tok');

  final strmDio = Dio(BaseOptions(baseUrl: 'http://proxy.test:8097'));
  strmDio.httpClientAdapter = adapter;
  final strm =
      StrmApiClient(baseUrl: 'http://proxy.test:8097', dio: strmDio);
  return (emby: emby, strm: strm, adapter: adapter);
}

Map<String, Object> multistreamRoutes() => {
      'GET /emby/Users/u1/Items/item-1': _itemJson,
      'POST /emby/Items/item-1/PlaybackInfo': _playbackInfoJson,
      'GET /api/v1/strm/streams/115/pick1':
          File('test/fixtures/strm_streams.json').readAsStringSync(),
      'POST /emby/Sessions/Playing': '{}',
    };

Future<SessionStore> emptyStore() async {
  SharedPreferences.setMockInitialValues({});
  return SessionStore.open();
}

void main() {
  test('加载多视频流清单并默认走 HLS 转码流（1080P 优先于原画直链）', () async {
    final clients = buildClients(multistreamRoutes());
    final player = FakePlayerAdapter();
    final controller = PlaybackController(
      emby: clients.emby,
      strm: clients.strm,
      store: await emptyStore(),
      adapter: player,
      itemId: 'item-1',
    );

    await controller.load();

    expect(controller.state.error, isNull);
    expect(controller.state.streams.map((s) => s.displayName),
        ['原画', '4K', '1080P']);
    // HLS 流优先于原画直链：4K 是 HLS 流中分辨率最高的，排第一。
    expect(controller.state.currentResolution, '4k');
    expect(player.opens.single.url, endsWith('resolution=4k'));
    expect(player.opens.single.isHls, isTrue);
    expect(player.playCount, 1);
  });

  test('带续播位置进入时从该位置起播', () async {
    final clients = buildClients(multistreamRoutes());
    final player = FakePlayerAdapter();
    final controller = PlaybackController(
      emby: clients.emby,
      strm: clients.strm,
      store: await emptyStore(),
      adapter: player,
      itemId: 'item-1',
      startAt: const Duration(minutes: 12),
    );

    await controller.load();

    expect(player.opens.single.start, const Duration(minutes: 12));
  });

  test('切画质：用新档位地址重开，并定位回切换前的位置', () async {
    final clients = buildClients(multistreamRoutes());
    final player = FakePlayerAdapter();
    final store = await emptyStore();
    final controller = PlaybackController(
      emby: clients.emby,
      strm: clients.strm,
      store: store,
      adapter: player,
      itemId: 'item-1',
    );
    await controller.load();

    // 默认档是 4K（HLS 最优），切到 ud 1080P 验证。
    player.emit(const PlayerStateStub(Duration(minutes: 8)).toState());
    await controller.switchTo('ud');

    expect(player.opens.length, 2);
    expect(player.opens.last.url, endsWith('resolution=ud'));
    expect(player.opens.last.start, const Duration(minutes: 8));
    expect(controller.state.currentResolution, 'ud');
    expect(controller.state.switching, isFalse);
    // 选择被记住，下次进播放页直接用这个档位。
    expect(store.preferredResolution, 'ud');
  });

  test('服务端下发全档位主清单时，起播与切档都收敛到该档的媒体清单', () async {
    // 这是「切了画质还是按最高分辨率播」的根因：服务端不论请求哪个档位都返回含全部
    // 视频流的主清单，播放器默认取最高码率那一路。客户端必须自己挑出目标档位。
    const masterAllVariants = '#EXTM3U\n'
        '#EXT-X-VERSION:4\n'
        '#EXT-X-INDEPENDENT-SEGMENTS\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=20000000,RESOLUTION=3840x2160,NAME="4K"\n'
        'http://strm.test:8095/api/v1/strm/play/115/a7v1aeu9tfilfhheh/hls/4k\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1920x1080,NAME="1080P"\n'
        'http://strm.test:8095/api/v1/strm/play/115/a7v1aeu9tfilfhheh/hls/ud\n';
    final clients = buildClients({
      ...multistreamRoutes(),
      'GET /api/v1/strm/play/115/a7v1aeu9tfilfhheh': masterAllVariants,
    });
    final player = FakePlayerAdapter();
    final controller = PlaybackController(
      emby: clients.emby,
      strm: clients.strm,
      store: await emptyStore(),
      adapter: player,
      itemId: 'item-1',
    );

    await controller.load();
    await controller.switchTo('ud');

    // 起播默认 4K：打开的是 4K 变体，而不是让播放器自己在主清单里选。
    expect(player.opens.first.url,
        'http://strm.test:8095/api/v1/strm/play/115/a7v1aeu9tfilfhheh/hls/4k');
    // 切到 1080P：真的换成了 ud 变体，不再是同一张主清单。
    expect(player.opens.last.url,
        'http://strm.test:8095/api/v1/strm/play/115/a7v1aeu9tfilfhheh/hls/ud');
    expect(controller.state.currentResolution, 'ud');
  });

  test('音轨独立成组的主清单：切档改为把 hls-bitrate 钉到该档码率', () async {
    // 115 转码档的变体 URI 只是视频媒体清单，单独打开会没声音，只能钉码率。
    final clients = buildClients({
      ...multistreamRoutes(),
      'GET /api/v1/strm/play/115/a7v1aeu9tfilfhheh':
          File('test/fixtures/strm_master_shared_audio.m3u8')
              .readAsStringSync(),
    });
    final player = FakePlayerAdapter();
    final controller = PlaybackController(
      emby: clients.emby,
      strm: clients.strm,
      store: await emptyStore(),
      adapter: player,
      itemId: 'item-1',
    );

    await controller.load();
    await controller.switchTo('ud');

    expect(player.opens.last.url, endsWith('resolution=ud'));
    expect(player.opens.last.hlsBitrate, 8000000);
    // 起播的 4K 档同样被钉住，否则默认仍会走最高码率。
    expect(player.opens.first.hlsBitrate, 20000000);
  });

  test('起播与切档都要把「是否 HLS」透传给播放器', () async {
    // 播放地址没有 .m3u8 后缀，播放器无法从 URL 推断容器；
    // 判断错会让 ExoPlayer 把 HLS 清单当 MP4 解析并解码失败。
    final clients = buildClients(multistreamRoutes());
    final player = FakePlayerAdapter();
    final controller = PlaybackController(
      emby: clients.emby,
      strm: clients.strm,
      store: await emptyStore(),
      adapter: player,
      itemId: 'item-1',
    );
    await controller.load();

    // 默认档是 4K HLS 流（优先级最高），必须按 HLS 打开。
    expect(player.opens.single.isHls, isTrue);

    // 切到原画直链 → 不能当 HLS。
    await controller.switchTo('raw');
    expect(player.opens.last.isHls, isFalse);

    // 再切到 1080P HLS 流 → 又必须按 HLS 打开。
    await controller.switchTo('ud');
    expect(player.opens.last.isHls, isTrue);
  });

  test('切到当前档位是空操作，不会重开流', () async {
    final clients = buildClients(multistreamRoutes());
    final player = FakePlayerAdapter();
    final controller = PlaybackController(
      emby: clients.emby,
      strm: clients.strm,
      store: await emptyStore(),
      adapter: player,
      itemId: 'item-1',
    );
    await controller.load();

    await controller.switchTo('4k');

    expect(player.opens.length, 1);
  });

  test('切档失败时保留原档位标记，并暴露错误', () async {
    final clients = buildClients(multistreamRoutes());
    final player = FakePlayerAdapter();
    final controller = PlaybackController(
      emby: clients.emby,
      strm: clients.strm,
      store: await emptyStore(),
      adapter: player,
      itemId: 'item-1',
    );
    await controller.load();

    // 默认已在 4K（HLS 最优档），切到 ud 失败应保留 4K。
    player.failNextOpen = StateError('转码档拉不起来');
    await controller.switchTo('ud');

    expect(controller.state.currentResolution, '4k');
    expect(controller.state.switching, isFalse);
    expect(controller.state.error, isNotNull);
  });

  test('起播自动降级：HLS 4K 失败后顺序尝试下一条流直到成功', () async {
    final clients = buildClients(multistreamRoutes());
    final player = FakePlayerAdapter();
    final controller = PlaybackController(
      emby: clients.emby,
      strm: clients.strm,
      store: await emptyStore(),
      adapter: player,
      itemId: 'item-1',
    );

    // 让第一条 HLS 流（4K）起播失败，第二条（1080P）成功。
    player.failOpensBefore = 1;
    await controller.load();

    expect(controller.state.error, isNull);
    // 成功的那一条流记录在 opens 中（失败的不计入）
    expect(player.opens.length, 1);
    expect(player.opens.last.url, endsWith('resolution=ud'));
    expect(player.opens.last.isHls, isTrue);
    expect(player.playCount, 1);
  });

  test('所有流都起播失败时报错暴露最后的错误', () async {
    final clients = buildClients(multistreamRoutes());
    final player = FakePlayerAdapter();
    final controller = PlaybackController(
      emby: clients.emby,
      strm: clients.strm,
      store: await emptyStore(),
      adapter: player,
      itemId: 'item-1',
    );

    player.failOpensBefore = 99;
    await controller.load();

    expect(controller.state.error, isNotNull);
    expect(player.playCount, 0);
  });

  test('记住的档位优先于清单默认档', () async {
    SharedPreferences.setMockInitialValues(
        {'jellfin.preferred_resolution': 'ud'});
    final store = await SessionStore.open();
    final clients = buildClients(multistreamRoutes());
    final player = FakePlayerAdapter();
    final controller = PlaybackController(
      emby: clients.emby,
      strm: clients.strm,
      store: store,
      adapter: player,
      itemId: 'item-1',
    );

    await controller.load();

    expect(controller.state.currentResolution, 'ud');
    expect(player.opens.single.url, endsWith('resolution=ud'));
  });

  test('清单不可用时退化用 PlaybackInfo 的多 MediaSource 当画质列表', () async {
    // 服务端没开 multistream 或版本旧：/streams 与 /probe 都不可用，
    // 但 PlaybackInfo 已按档位展开，画质菜单仍要能用。
    final clients = buildClients({
      'GET /emby/Users/u1/Items/item-1': _itemJson,
      'POST /emby/Items/item-1/PlaybackInfo': _playbackInfoJson,
      'GET /api/v1/strm/streams/115/pick1': const FakeResponse(503),
      'GET /api/v1/strm/probe/115/pick1': const FakeResponse(404),
      'POST /emby/Sessions/Playing': '{}',
    });
    final player = FakePlayerAdapter();
    final controller = PlaybackController(
      emby: clients.emby,
      strm: clients.strm,
      store: await emptyStore(),
      adapter: player,
      itemId: 'item-1',
    );

    await controller.load();

    expect(controller.state.streams.map((s) => s.displayName),
        ['原画', '1080P']);
    // HLS 流（1080P）优先于原画直链
    expect(player.opens.single.url, endsWith('resolution=ud'));
    expect(player.opens.single.isHls, isTrue);
  });

  test('非网盘条目只有一路源，也能正常起播', () async {
    final clients = buildClients({
      'GET /emby/Users/u1/Items/item-2': '{"Id":"item-2","Name":"本地片"}',
      'POST /emby/Items/item-2/PlaybackInfo': _localPlaybackInfoJson,
      'POST /emby/Sessions/Playing': '{}',
    });
    final player = FakePlayerAdapter();
    final controller = PlaybackController(
      emby: clients.emby,
      strm: clients.strm,
      store: await emptyStore(),
      adapter: player,
      itemId: 'item-2',
    );

    await controller.load();

    expect(controller.state.streams.length, 1);
    expect(player.opens.single.url, endsWith('/videos/item-2/stream.mkv'));
  });

  test('没有任何可播源时报错而不是静默黑屏', () async {
    final clients = buildClients({
      'GET /emby/Users/u1/Items/item-3': '{"Id":"item-3","Name":"坏条目"}',
      'POST /emby/Items/item-3/PlaybackInfo':
          '{"PlaySessionId":"s","MediaSources":[]}',
    });
    final player = FakePlayerAdapter();
    final controller = PlaybackController(
      emby: clients.emby,
      strm: clients.strm,
      store: await emptyStore(),
      adapter: player,
      itemId: 'item-3',
    );

    await controller.load();

    expect(controller.state.error, isNotNull);
    expect(player.opens, isEmpty);
  });

  test('进度上报失败不影响播放', () async {
    // Sessions/Playing 没有注册路由 → FakeAdapter 回 404，dio 抛异常。
    final clients = buildClients({
      'GET /emby/Users/u1/Items/item-1': _itemJson,
      'POST /emby/Items/item-1/PlaybackInfo': _playbackInfoJson,
      'GET /api/v1/strm/streams/115/pick1':
          File('test/fixtures/strm_streams.json').readAsStringSync(),
    });
    final player = FakePlayerAdapter();
    final controller = PlaybackController(
      emby: clients.emby,
      strm: clients.strm,
      store: await emptyStore(),
      adapter: player,
      itemId: 'item-1',
    );

    await controller.load();

    expect(controller.state.error, isNull);
    expect(player.playCount, 1);
  });
}

/// 小助手：只关心 position 的 PlayerAdapterState。
class PlayerStateStub {
  final Duration position;

  const PlayerStateStub(this.position);

  PlayerAdapterState toState() => PlayerAdapterState(position: position, playing: true);
}
