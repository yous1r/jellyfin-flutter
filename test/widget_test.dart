import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellfin_flutter/app.dart';
import 'package:jellfin_flutter/core/providers.dart';
import 'package:jellfin_flutter/core/storage/session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> pumpApp(WidgetTester tester,
    {Map<String, Object> prefs = const {}}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final store = await SessionStore.open();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionStoreProvider.overrideWithValue(store),
        deviceIdProvider.overrideWithValue('test-device'),
      ],
      child: const JellfinApp(),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('没有会话时落在登录页', (tester) async {
    await pumpApp(tester);

    expect(find.text('连接 Emby / Jellyfin 服务器'), findsOneWidget);
    // 输入框用 labelText，文案渲染在 InputDecorator 里。
    expect(find.text('服务器地址'), findsOneWidget);
    expect(find.text('用户名'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
  });

  testWidgets('登出后重进：服务器地址仍回填，不用重输', (tester) async {
    await pumpApp(tester, prefs: {
      // 只有地址没有 token/userId —— 等价于登出后的状态。
      'jellfin.server_url': 'http://10.0.0.50:8097',
    });

    expect(find.text('http://10.0.0.50:8097'), findsOneWidget);
  });
}
