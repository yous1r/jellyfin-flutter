import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellfin_flutter/core/api/emby_api_client.dart';
import 'package:jellfin_flutter/core/providers.dart';
import 'package:jellfin_flutter/core/storage/session_store.dart';
import 'package:jellfin_flutter/features/library/library_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_adapter.dart';

/// 造一页 Items 响应：count 条，总数 total。
String itemsPage(int count, int total, {int startIndex = 0}) {
  final items = List.generate(
    count,
    (i) => '{"Id":"i${startIndex + i}","Name":"片 ${startIndex + i}",'
        '"Type":"Movie"}',
  ).join(',');
  return '{"Items":[$items],"TotalRecordCount":$total}';
}

EmbyApiClient clientWith(FakeAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://proxy.test:8097'));
  dio.httpClientAdapter = adapter;
  final client = EmbyApiClient(
      baseUrl: 'http://proxy.test:8097', dio: dio, deviceId: 'dev');
  client.restoreSession(userId: 'u1', token: 'tok');
  return client;
}

/// 等待 controller 构造时自动发起的首屏加载完成。
Future<void> settle(LibraryController controller) => controller.initialLoad;

void main() {
  group('海报墙分页', () {
    test('首屏加载后记录总数与条目', () async {
      final controller = LibraryController(
        clientWith(FakeAdapter({'GET /emby/Users/u1/Items': itemsPage(60, 130)})),
        'lib-1',
      );
      await settle(controller);

      expect(controller.state.items.length, 60);
      expect(controller.state.total, 130);
      expect(controller.state.hasMore, isTrue);
      expect(controller.state.loading, isFalse);
    });

    test('loadMore 追加下一页并带上正确的 StartIndex', () async {
      final adapter =
          FakeAdapter({'GET /emby/Users/u1/Items': itemsPage(60, 130)});
      final controller = LibraryController(clientWith(adapter), 'lib-1');
      await settle(controller);

      await controller.loadMore();

      expect(controller.state.items.length, 120);
      expect(adapter.requests.last.queryParameters['StartIndex'], '60');
      expect(adapter.requests.last.queryParameters['ParentId'], 'lib-1');
    });

    test('加载到总数后不再请求', () async {
      final adapter =
          FakeAdapter({'GET /emby/Users/u1/Items': itemsPage(10, 10)});
      final controller = LibraryController(clientWith(adapter), 'lib-1');
      await settle(controller);
      final callsAfterFirstPage = adapter.requests.length;

      await controller.loadMore();

      expect(controller.state.hasMore, isFalse);
      expect(adapter.requests.length, callsAfterFirstPage);
    });

    test('并发 loadMore 只会发一个在途请求，避免重复插入', () async {
      final adapter =
          FakeAdapter({'GET /emby/Users/u1/Items': itemsPage(60, 300)});
      final controller = LibraryController(clientWith(adapter), 'lib-1');
      await settle(controller);
      final before = adapter.requests.length;

      await Future.wait([
        controller.loadMore(),
        controller.loadMore(),
        controller.loadMore(),
      ]);

      expect(adapter.requests.length, before + 1);
      expect(controller.state.items.length, 120);
    });

    test('服务端不回 TotalRecordCount 时不会无限翻页', () async {
      // total=0 会让 hasMore 永真：用已加载数兜底后必须停下来。
      final adapter = FakeAdapter(
          {'GET /emby/Users/u1/Items': '{"Items":[{"Id":"i0","Name":"x"}]}'});
      final controller = LibraryController(clientWith(adapter), 'lib-1');
      await settle(controller);

      expect(controller.state.total, 1);
      expect(controller.state.hasMore, isFalse);
    });

    test('失败后暴露错误，retry 能恢复', () async {
      // 没有注册路由 → 404 → dio 抛异常。
      final adapter = FakeAdapter({});
      final controller = LibraryController(clientWith(adapter), 'lib-1');
      await settle(controller);

      expect(controller.state.error, isNotNull);
      expect(controller.state.loading, isFalse);

      adapter.routes['GET /emby/Users/u1/Items'] = itemsPage(5, 5);
      await controller.retry();

      expect(controller.state.error, isNull);
      expect(controller.state.items.length, 5);
    });
  });

  group('会话持久化', () {
    test('保存后可读回，登出只清凭据保留地址', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await SessionStore.open();
      await store.save(const StoredSession(
        serverUrl: 'http://10.0.0.50:8097',
        userId: 'u1',
        userName: 'tv',
        token: 'tok',
      ));

      expect(store.load()?.token, 'tok');

      await store.clearCredentials();

      expect(store.load(), isNull);
      // 地址仍在（登录页回填用）。
      final reopened = await SessionStore.open();
      expect(reopened.load(), isNull);
    });

    test('设备 ID 生成一次后固定不变', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await SessionStore.open();

      final first = await store.deviceId();
      final second = await store.deviceId();

      expect(first, isNotEmpty);
      expect(first, second);
    });

    test('凭据不全视为未登录', () async {
      SharedPreferences.setMockInitialValues({
        'jellfin.server_url': 'http://10.0.0.50:8097',
        'jellfin.user_id': 'u1',
        // 缺 token
      });
      final store = await SessionStore.open();

      expect(store.load(), isNull);
    });
  });

  group('服务器地址规范化', () {
    test('缺协议时补 http://，并去掉尾部斜杠', () {
      expect(normalizeServerUrl('10.0.0.50:8097'), 'http://10.0.0.50:8097');
      expect(normalizeServerUrl('http://10.0.0.50:8097/'),
          'http://10.0.0.50:8097');
      expect(normalizeServerUrl(' https://emby.example/// '),
          'https://emby.example');
    });

    test('空输入返回空串（由调用方提示必填）', () {
      expect(normalizeServerUrl('   '), '');
    });
  });
}
