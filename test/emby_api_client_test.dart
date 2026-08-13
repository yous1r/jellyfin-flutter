import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellfin_flutter/core/api/emby_api_client.dart';

import 'fake_adapter.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

EmbyApiClient buildClient(FakeAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://proxy.test:8097'));
  dio.httpClientAdapter = adapter;
  return EmbyApiClient(
    baseUrl: 'http://proxy.test:8097',
    dio: dio,
    deviceId: 'test-device',
  );
}

void main() {
  const authJson =
      '{"User":{"Id":"u1","Name":"tv"},"AccessToken":"tok-1","ServerId":"srv-1"}';

  test('认证前后 X-Emby-Authorization 头格式正确', () async {
    final adapter = FakeAdapter({
      'POST /emby/Users/AuthenticateByName': authJson,
      'GET /emby/Users/u1/Views': fixture('views.json'),
    });
    final client = buildClient(adapter);

    // 认证前：无 UserId/Token，但有 Client/Device 标识
    expect(client.authorizationHeader, contains('Client="JellfinFlutter"'));
    expect(client.authorizationHeader, contains('DeviceId="test-device"'));
    expect(client.authorizationHeader, isNot(contains('Token=')));

    final auth = await client.authenticateByName('tv', 'pw');

    expect(auth.accessToken, 'tok-1');
    expect(client.isAuthenticated, isTrue);
    expect(client.authorizationHeader, contains('UserId="u1"'));
    expect(client.authorizationHeader, contains('Token="tok-1"'));

    await client.views();
    final viewReq = adapter.requests.last;
    expect(viewReq.headers['X-Emby-Token'], 'tok-1');
    expect(viewReq.headers['X-Emby-Authorization'], contains('MediaBrowser '));
  });

  test('restoreSession 恢复会话后可直接请求', () async {
    final adapter = FakeAdapter({
      'GET /emby/Users/u9/Views': fixture('views.json'),
    });
    final client = buildClient(adapter)
      ..restoreSession(userId: 'u9', token: 'tok-9');

    final views = await client.views();

    expect(views, isNotEmpty);
    expect(adapter.requests.single.headers['X-Emby-Token'], 'tok-9');
  });

  test('items 分页参数正确传递并解析', () async {
    final adapter = FakeAdapter({
      'POST /emby/Users/AuthenticateByName': authJson,
      'GET /emby/Users/u1/Items': fixture('items_page.json'),
    });
    final client = buildClient(adapter);
    await client.authenticateByName('tv', 'pw');

    final page = await client.items(parentId: 'lib-1', startIndex: 50, limit: 25);

    expect(page.items, isNotEmpty);
    final query = adapter.requests.last.uri.queryParameters;
    expect(query['ParentId'], 'lib-1');
    expect(query['StartIndex'], '50');
    expect(query['Limit'], '25');
  });

  test('resume 解析继续观看列表', () async {
    final adapter = FakeAdapter({
      'POST /emby/Users/AuthenticateByName': authJson,
      'GET /emby/Users/u1/Items/Resume': fixture('resume.json'),
    });
    final client = buildClient(adapter);
    await client.authenticateByName('tv', 'pw');

    final page = await client.resume();

    expect(page.items, isNotEmpty);
    expect(page.items.first.userData.playbackPositionTicks, greaterThan(0));
  });

  test('playbackInfo 返回注入的 STRM 播放地址', () async {
    final adapter = FakeAdapter({
      'POST /emby/Users/AuthenticateByName': authJson,
      'POST /emby/Items/64f5/PlaybackInfo': fixture('playback_info.json'),
    });
    final client = buildClient(adapter);
    await client.authenticateByName('tv', 'pw');

    final info = await client.playbackInfo('64f5');

    expect(info.mediaSources.single.playUrl, contains('/cloudplay/quark/'));
    final query = adapter.requests.last.uri.queryParameters;
    expect(query['UserId'], 'u1');
    expect(query['IsPlayback'], 'true');
  });

  test('进度上报携带会话与位置', () async {
    final adapter = FakeAdapter({
      'POST /emby/Users/AuthenticateByName': authJson,
      'POST /emby/Sessions/Playing': '{}',
    });
    final client = buildClient(adapter);
    await client.authenticateByName('tv', 'pw');

    await client.reportProgress(
      itemId: 'i1',
      playSessionId: 'ps1',
      mediaSourceId: 'ms1',
      positionTicks: 1234567,
      isPaused: true,
    );

    final req = adapter.requests.last;
    expect(req.uri.path, '/emby/Sessions/Playing/Progress');
    final body = jsonDecode(jsonEncode(req.data)) as Map<String, dynamic>;
    expect(body['PositionTicks'], 1234567);
    expect(body['IsPaused'], true);
    expect(body['PlaySessionId'], 'ps1');
  });

  test('imageUrl 生成带尺寸与 tag 的图片地址', () async {
    final client = buildClient(FakeAdapter(const {}));

    final url = client.imageUrl('item-1', tag: 'abc', maxWidth: 300);

    expect(url,
        'http://proxy.test:8097/emby/Items/item-1/Images/Primary?maxWidth=300&tag=abc');
  });
}
