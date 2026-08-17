import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/providers.dart';
import 'core/storage/session_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // media_kit 初始化：libmpv 原生引擎，必须在任何 Player 创建前调用。
  MediaKit.ensureInitialized();
  // 会话与设备 ID 同步读一次后注入 provider：避免每个页面各自 await 初始化。
  final store = await SessionStore.open();
  final deviceId = await store.deviceId();
  runApp(
    ProviderScope(
      overrides: [
        sessionStoreProvider.overrideWithValue(store),
        deviceIdProvider.overrideWithValue(deviceId),
      ],
      child: const JellfinApp(),
    ),
  );
}
