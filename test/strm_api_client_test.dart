import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellfin_flutter/core/strm/strm_api_client.dart';

import 'fake_adapter.dart';

void main() {
  group('StrmPlayTarget.tryParse', () {
    test('解析代理注入的 cloudplay 地址', () {
      final target = StrmPlayTarget.tryParse(
          'http://10.0.0.50:8097/cloudplay/quark/f1e2165bf68e4db9a6670daac919de9b');

      expect(target, isNotNull);
      expect(target!.cloudType, 'quark');
      expect(target.fileId, 'f1e2165bf68e4db9a6670daac919de9b');
    });

    test('解析主应用 strm play 地址（含 115 pickcode）', () {
      final target = StrmPlayTarget.tryParse(
          'http://10.0.0.50:8095/api/v1/strm/play/115/a7v1aeu9tfilfhheh?resolution=raw');

      expect(target, isNotNull);
      expect(target!.cloudType, '115');
      expect(target.fileId, 'a7v1aeu9tfilfhheh');
    });

    test('解析夸克全链路 play 地址', () {
      final target = StrmPlayTarget.tryParse(
          'http://10.0.0.50:8095/api/v1/quark/play/abc123/video.mkv');

      expect(target, isNotNull);
      expect(target!.cloudType, 'quark');
      expect(target.fileId, 'abc123');
    });

    test('无法识别的地址返回 null', () {
      expect(StrmPlayTarget.tryParse('http://example.com/movie.mp4'), isNull);
    });
  });

  test('probeVariants 只返回可播档位', () async {
    final adapter = FakeAdapter({
      'GET /api/v1/strm/probe/quark/f1':
          File('test/fixtures/strm_probe.json').readAsStringSync(),
    });
    final dio = Dio(BaseOptions(baseUrl: 'http://strm.test:8095'));
    dio.httpClientAdapter = adapter;
    final client = StrmApiClient(baseUrl: 'http://strm.test:8095', dio: dio);

    final variants =
        await client.probeVariants(const StrmPlayTarget('quark', 'f1'));

    expect(variants, isNotEmpty);
    expect(variants.every((v) => v.playable), isTrue);
    expect(variants.map((v) => v.resolution), contains('raw'));
  });

  test('probeVariants 对无记录文件返回空列表', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://strm.test:8095'));
    dio.httpClientAdapter = FakeAdapter(const {});
    final client = StrmApiClient(baseUrl: 'http://strm.test:8095', dio: dio);

    final variants =
        await client.probeVariants(const StrmPlayTarget('quark', 'missing'));

    expect(variants, isEmpty);
  });

  test('playUrl 构造指定档位地址', () {
    final client = StrmApiClient(baseUrl: 'http://strm.test:8095/');

    final url = client.playUrl(const StrmPlayTarget('115', 'pick1'),
        resolution: 'ud');

    expect(url, 'http://strm.test:8095/api/v1/strm/play/115/pick1?resolution=ud');
  });

  group('多视频流清单', () {
    StrmApiClient clientWith(Map<String, Object> routes) {
      final dio = Dio(BaseOptions(baseUrl: 'http://strm.test:8095'));
      dio.httpClientAdapter = FakeAdapter(routes);
      return StrmApiClient(baseUrl: 'http://strm.test:8095', dio: dio);
    }

    test('解析原画与转码档并列的多路流', () async {
      final client = clientWith({
        'GET /api/v1/strm/streams/115/a7v1aeu9tfilfhheh':
            File('test/fixtures/strm_streams.json').readAsStringSync(),
      });

      final manifest = await client
          .fetchStreams(const StrmPlayTarget('115', 'a7v1aeu9tfilfhheh'));

      expect(manifest, isNotNull);
      expect(manifest!.defaultResolution, 'raw');
      expect(manifest.streams.map((s) => s.displayName),
          ['原画', '4K', '1080P']);
      final original = manifest.streams.first;
      expect(original.isOriginal, isTrue);
      expect(original.container, 'mkv');
      expect(original.url,
          'http://strm.test:8095/api/v1/strm/play/115/a7v1aeu9tfilfhheh?resolution=raw');
      final uhd = manifest.streams[1];
      expect(uhd.isOriginal, isFalse);
      expect(uhd.width, 3840);
      expect(uhd.height, 2160);
      expect(uhd.isHls, isTrue);
      expect(manifest.duration, const Duration(seconds: 2712, milliseconds: 500));
    });

    test('服务端无可播档位（503）时返回 null，交由调用方回退', () async {
      final client = clientWith({
        'GET /api/v1/strm/streams/quark/f1': const FakeResponse(503),
      });

      expect(await client.fetchStreams(const StrmPlayTarget('quark', 'f1')),
          isNull);
    });

    test('旧服务端没有该路由（404）时返回 null，不抛异常', () async {
      final client = clientWith(const {});

      expect(await client.fetchStreams(const StrmPlayTarget('quark', 'f1')),
          isNull);
    });

    test('playbackStreams 优先用多视频流清单', () async {
      final client = clientWith({
        'GET /api/v1/strm/streams/115/a7v1aeu9tfilfhheh':
            File('test/fixtures/strm_streams.json').readAsStringSync(),
      });

      final streams = await client
          .playbackStreams(const StrmPlayTarget('115', 'a7v1aeu9tfilfhheh'));

      expect(streams.map((s) => s.resolution), ['raw', '4k', 'ud']);
    });

    test('清单不可用时 playbackStreams 回退到 probe 档位', () async {
      // 服务端未开 multistream / 版本较旧：仍要能凑出画质菜单，原画排首位。
      final client = clientWith({
        'GET /api/v1/strm/streams/quark/f1': const FakeResponse(503),
        'GET /api/v1/strm/probe/quark/f1':
            File('test/fixtures/strm_probe.json').readAsStringSync(),
      });

      final streams =
          await client.playbackStreams(const StrmPlayTarget('quark', 'f1'));

      expect(streams.first.resolution, 'raw');
      expect(streams.first.isOriginal, isTrue);
      expect(streams.first.displayName, '原画');
      expect(streams.map((s) => s.resolution),
          containsAll(['raw', '4k', 'super', 'high', 'low']));
      // 回退档位也要有可直接播放的 URL。
      expect(streams.last.url, startsWith('http://strm.test:8095/api/v1/strm/play/quark/f1?resolution='));
    });

    test('回退路径下夸克 direct 转码档是直连 MP4，不能标成 HLS', () async {
      // 夸克转码档的 protocol 也是 direct（见 strm_probe.json）：
      // is_original 看 source（只有 download 是原画）；
      // container 看 protocol（direct = 302 到真视频，hls_* 才是 m3u8）。
      // 标错任一方向都会让播放器用错误的解析方式打开真实视频。
      final client = clientWith({
        'GET /api/v1/strm/streams/quark/f1': const FakeResponse(503),
        'GET /api/v1/strm/probe/quark/f1':
            File('test/fixtures/strm_probe.json').readAsStringSync(),
      });

      final streams =
          await client.playbackStreams(const StrmPlayTarget('quark', 'f1'));
      final byResolution = {for (final s in streams) s.resolution: s};

      expect(byResolution['raw']!.isOriginal, isTrue);
      expect(byResolution['raw']!.container, 'mkv');
      expect(byResolution['raw']!.isHls, isFalse);
      for (final resolution in ['4k', 'super', 'high', 'low']) {
        expect(byResolution[resolution]!.isOriginal, isFalse, reason: resolution);
        expect(byResolution[resolution]!.container, 'mp4', reason: resolution);
        expect(byResolution[resolution]!.isHls, isFalse, reason: resolution);
      }
    });

    test('两者都不可用时返回空列表', () async {
      final client = clientWith({
        'GET /api/v1/strm/streams/quark/f1': const FakeResponse(503),
      });

      expect(await client.playbackStreams(const StrmPlayTarget('quark', 'f1')),
          isEmpty);
    });
  });

  group('客户端选档（服务端始终按多视频流下发）', () {
    late FakeAdapter adapter;

    StrmApiClient clientWith(Map<String, Object> routes) {
      adapter = FakeAdapter(routes);
      final dio = Dio(BaseOptions(baseUrl: 'http://strm.test:8095'));
      dio.httpClientAdapter = adapter;
      return StrmApiClient(baseUrl: 'http://strm.test:8095', dio: dio);
    }

    PlaybackStream streamOf(String resolution,
            {String displayName = '',
            int? width,
            int? height,
            String container = 'm3u8',
            bool isOriginal = false,
            String host = 'quark',
            String file = 'f1'}) =>
        PlaybackStream(
          resolution: resolution,
          displayName: displayName,
          container: container,
          isOriginal: isOriginal,
          url: 'http://strm.test:8095/api/v1/strm/play/$host/$file'
              '?resolution=$resolution',
          width: width,
          height: height,
        );

    String masterAllVariants() =>
        File('test/fixtures/strm_master_all_variants.m3u8').readAsStringSync();

    test('主清单含全部档位时收敛到目标档位的媒体清单', () async {
      // 线上实测：`?resolution=low` 也返回 4 个 EXT-X-STREAM-INF，请求的档位只是排在
      // 第一位。播放器默认按最高码率选（4K），必须由客户端挑出 low 那一路。
      final client = clientWith({
        'GET /api/v1/strm/play/quark/f1': masterAllVariants(),
      });

      final resolved = await client.resolvePlaybackUrl(streamOf('low'));

      expect(resolved.url,
          'http://strm.test:8095/api/v1/strm/play/quark/f1/hls/low');
      expect(resolved.hlsBitrate, isNull);
    });

    test('每个档位各自收敛，不会都落到最高码率那一路', () async {
      final client = clientWith({
        'GET /api/v1/strm/play/quark/f1': masterAllVariants(),
      });

      final urls = <String, String>{};
      for (final resolution in ['low', 'high', 'super', '4k']) {
        urls[resolution] =
            (await client.resolvePlaybackUrl(streamOf(resolution))).url;
      }

      expect(urls, {
        'low': 'http://strm.test:8095/api/v1/strm/play/quark/f1/hls/low',
        'high': 'http://strm.test:8095/api/v1/strm/play/quark/f1/hls/high',
        'super': 'http://strm.test:8095/api/v1/strm/play/quark/f1/hls/super',
        '4k': 'http://strm.test:8095/api/v1/strm/play/quark/f1/hls/4k',
      });
      // 四个档位必须解析出四个互不相同的地址，否则切档等于没切。
      expect(urls.values.toSet(), hasLength(4));
    });

    test('音轨独立成组时保留主清单并钉住 hls-bitrate（否则会没声音）', () async {
      // 115 转码档的主清单把音轨拆成 #EXT-X-MEDIA 组，变体 URI 只是视频媒体清单：
      // 直接打开它就没有声音，只能让 mpv 在主清单内部按码率选中该档。
      final client = clientWith({
        'GET /api/v1/strm/play/115/pick1':
            File('test/fixtures/strm_master_shared_audio.m3u8')
                .readAsStringSync(),
      });

      final resolved = await client.resolvePlaybackUrl(
          streamOf('ud', host: '115', file: 'pick1'));

      expect(resolved.url,
          'http://strm.test:8095/api/v1/strm/play/115/pick1?resolution=ud');
      expect(resolved.hlsBitrate, 8000000);
    });

    test('直链档位的 302 丢掉 resolution 时补回去，指向真正的档位地址', () async {
      // 线上实测：夸克五个档位都 302 到同一个 /api/v1/quark/play/{id}（不带档位），
      // 播放器跟随后永远播默认档。客户端要把档位补进去再交给播放器。
      final client = clientWith({
        'GET /api/v1/strm/play/quark/f1': const FakeResponse(302, {}, {
          'location': 'http://strm.test:8095/api/v1/quark/play/f1',
        }),
      });

      final resolved = await client
          .resolvePlaybackUrl(streamOf('high', container: 'mp4'));

      expect(resolved.url,
          'http://strm.test:8095/api/v1/quark/play/f1?resolution=high');
    });

    test('302 跨源到网盘 CDN 时保留原地址，不提前铸链', () async {
      // 直链是一次性的且要由播放器带自己的请求头去换，客户端提前解析只会白铸一条。
      final client = clientWith({
        'GET /api/v1/strm/play/quark/f1': const FakeResponse(302, {}, {
          'location': 'https://video-play.drive.quark.cn/abc?auth_key=1',
        }),
      });

      final stream = streamOf('high', container: 'mp4');
      final resolved = await client.resolvePlaybackUrl(stream);

      expect(resolved.url, stream.url);
    });

    test('原画直链不做探测，避免白铸一条网盘直链', () async {
      final client = clientWith(const {});

      final stream =
          streamOf('raw', container: 'mkv', isOriginal: true);
      final resolved = await client.resolvePlaybackUrl(stream);

      expect(resolved.url, stream.url);
      expect(adapter.requests, isEmpty);
    });

    test('服务端已收敛为单档主清单时保持原地址', () async {
      final client = clientWith({
        'GET /api/v1/strm/play/quark/f1': '#EXTM3U\n'
            '#EXT-X-VERSION:4\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=640x360,NAME="360P"\n'
            'http://strm.test:8095/api/v1/strm/play/quark/f1/hls/low\n',
      });

      final stream = streamOf('low');
      expect((await client.resolvePlaybackUrl(stream)).url, stream.url);
    });

    test('已是媒体清单时保持原地址', () async {
      final client = clientWith({
        'GET /api/v1/strm/play/quark/f1': '#EXTM3U\n'
            '#EXT-X-PLAYLIST-TYPE:VOD\n'
            '#EXTINF:2.000,\n'
            'http://strm.test:8095/api/v1/strm/play/quark/f1/hls/low/resource/0.ts\n',
      });

      final stream = streamOf('low');
      expect((await client.resolvePlaybackUrl(stream)).url, stream.url);
    });

    test('档位标识匹配不上时退回友好名，不会切到别的档位', () async {
      // 变体 URI 不带档位标识的服务端（老版本合成清单）：靠 NAME 唯一命中。
      final client = clientWith({
        'GET /api/v1/strm/play/quark/f1': '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=640x360,NAME="360P"\n'
            'variant-a.m3u8\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=20000000,RESOLUTION=3840x2160,NAME="4K"\n'
            'variant-b.m3u8\n',
      });

      final resolved = await client
          .resolvePlaybackUrl(streamOf('low', displayName: '360P'));

      expect(resolved.url,
          'http://strm.test:8095/api/v1/strm/play/quark/variant-a.m3u8');
    });

    test('友好名撞车且无档位标识时宁可不切，也不切到错误档位', () async {
      // ud 与 super 都叫 1080P：命中不唯一就退回原地址，交给服务端行为。
      final client = clientWith({
        'GET /api/v1/strm/play/115/pick1': '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1920x1080,NAME="1080P"\n'
            'variant-a.m3u8\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1920x1080,NAME="1080P"\n'
            'variant-b.m3u8\n',
      });

      final stream = streamOf('ud',
          displayName: '1080P',
          width: 1920,
          height: 1080,
          host: '115',
          file: 'pick1');

      expect((await client.resolvePlaybackUrl(stream)).url, stream.url);
    });

    test('探测失败不阻断播放，退回服务端原地址', () async {
      final client = clientWith({
        'GET /api/v1/strm/play/quark/f1': const FakeResponse(500),
      });

      final stream = streamOf('low');
      expect((await client.resolvePlaybackUrl(stream)).url, stream.url);
    });
  });
}
