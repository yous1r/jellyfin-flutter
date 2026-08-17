import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/providers.dart';
import 'features/auth/login_page.dart';
import 'features/detail/detail_page.dart';
import 'features/home/home_page.dart';
import 'features/library/library_page.dart';
import 'features/player/player_page.dart';
import 'features/search/search_page.dart';

/// 路由表。未登录时一律重定向到 /login；已登录访问 /login 则回首页。
GoRouter buildRouter(Ref ref) {
  return GoRouter(
    initialLocation: '/',
    refreshListenable: _AuthListenable(ref),
    redirect: (context, state) {
      final authed = ref.read(authControllerProvider).isAuthenticated;
      final atLogin = state.matchedLocation == '/login';
      if (!authed) return atLogin ? null : '/login';
      return atLogin ? '/' : null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginPage()),
      GoRoute(path: '/', builder: (_, __) => const HomePage()),
      GoRoute(path: '/search', builder: (_, __) => const SearchPage()),
      GoRoute(
        path: '/library/:id',
        builder: (_, state) => LibraryPage(
          parentId: state.pathParameters['id']!,
          title: state.uri.queryParameters['title'] ?? '媒体库',
        ),
      ),
      GoRoute(
        path: '/detail/:id',
        builder: (_, state) => DetailPage(itemId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/player/:id',
        builder: (_, state) => PlayerPage(
          itemId: state.pathParameters['id']!,
          startTicks:
              int.tryParse(state.uri.queryParameters['ticks'] ?? '') ?? 0,
        ),
      ),
    ],
  );
}

/// 把登录态变化转成 go_router 的刷新信号。
class _AuthListenable extends ChangeNotifier {
  _AuthListenable(Ref ref) {
    ref.listen(authControllerProvider, (previous, next) {
      if (previous?.isAuthenticated != next.isAuthenticated) notifyListeners();
    });
  }
}

final routerProvider = Provider<GoRouter>(buildRouter);

class JellfinApp extends ConsumerWidget {
  const JellfinApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Jellfin',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      routerConfig: ref.watch(routerProvider),
    );
  }
}

/// 深色影音主题：海报墙在深色背景下对比更好，TV 端也更耐看。
ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF00A4DC), // Jellyfin 蓝
    brightness: Brightness.dark,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFF101318),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF101318),
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      isDense: true,
    ),
  );
}
