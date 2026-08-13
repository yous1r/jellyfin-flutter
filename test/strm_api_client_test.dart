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
}
