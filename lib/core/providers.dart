import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/emby_api_client.dart';
import 'storage/session_store.dart';
import 'strm/strm_api_client.dart';

/// 会话存储：在 `main()` 里用已 open 的实例覆盖，避免全应用等待异步初始化。
final sessionStoreProvider = Provider<SessionStore>(
  (ref) => throw UnimplementedError('sessionStoreProvider 必须在 main() 中覆盖'),
);

/// 本次运行的设备 ID：同样在 `main()` 覆盖（Emby 按 DeviceId 归并会话）。
final deviceIdProvider = Provider<String>(
  (ref) => throw UnimplementedError('deviceIdProvider 必须在 main() 中覆盖'),
);

/// 当前登录态。null = 未登录。
class AuthState {
  final StoredSession? session;
  final bool busy;
  final String? error;

  const AuthState({this.session, this.busy = false, this.error});

  bool get isAuthenticated => session != null;

  AuthState copyWith({
    StoredSession? session,
    bool? busy,
    String? error,
    bool clearSession = false,
    bool clearError = false,
  }) =>
      AuthState(
        session: clearSession ? null : (session ?? this.session),
        busy: busy ?? this.busy,
        error: clearError ? null : (error ?? this.error),
      );
}

class AuthController extends StateNotifier<AuthState> {
  final SessionStore _store;
  final String _deviceId;

  AuthController(this._store, this._deviceId)
      : super(AuthState(session: _store.load()));

  /// 登录：成功后持久化会话，失败把可读原因放进 state.error。
  Future<bool> login({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final normalized = normalizeServerUrl(serverUrl);
    if (normalized.isEmpty) {
      state = state.copyWith(error: '请填写服务器地址', busy: false);
      return false;
    }
    state = state.copyWith(busy: true, clearError: true);
    try {
      final client = EmbyApiClient(baseUrl: normalized, deviceId: _deviceId);
      final auth = await client.authenticateByName(username, password);
      if (auth.accessToken.isEmpty) {
        state = state.copyWith(busy: false, error: '服务器未返回访问令牌');
        return false;
      }
      final session = StoredSession(
        serverUrl: normalized,
        userId: auth.userId,
        userName: auth.userName,
        token: auth.accessToken,
      );
      await _store.save(session);
      state = AuthState(session: session);
      return true;
    } on DioException catch (e) {
      state = state.copyWith(busy: false, error: describeDioError(e));
      return false;
    } catch (e) {
      state = state.copyWith(busy: false, error: '登录失败：$e');
      return false;
    }
  }

  Future<void> logout() async {
    await _store.clearCredentials();
    state = const AuthState();
  }

  /// 令牌被服务端作废（401）时调用：清本地会话，让路由回到登录页。
  Future<void> onUnauthorized() async {
    await _store.clearCredentials();
    state = const AuthState(error: '登录已过期，请重新登录');
  }
}

/// 补全协议并去掉尾部斜杠；空输入返回空串。
String normalizeServerUrl(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return '';
  if (!value.startsWith('http://') && !value.startsWith('https://')) {
    value = 'http://$value';
  }
  return value.replaceAll(RegExp(r'/+$'), '');
}

String describeDioError(DioException e) {
  final status = e.response?.statusCode;
  if (status == 401) return '用户名或密码错误';
  if (status == 400) return '服务器拒绝了请求（检查地址是否为 Emby/Jellyfin 服务）';
  if (status != null) return '服务器返回 $status';
  return '连不上服务器，检查地址与网络';
}

final authControllerProvider =
    StateNotifierProvider<AuthController, AuthState>((ref) {
  return AuthController(
    ref.watch(sessionStoreProvider),
    ref.watch(deviceIdProvider),
  );
});

/// 已登录时可用的 Emby 客户端；未登录返回 null。
final embyClientProvider = Provider<EmbyApiClient?>((ref) {
  final session = ref.watch(authControllerProvider).session;
  if (session == null) return null;
  final client = EmbyApiClient(
    baseUrl: session.serverUrl,
    deviceId: ref.watch(deviceIdProvider),
  );
  client.restoreSession(userId: session.userId, token: session.token);
  // 令牌过期立刻掉回登录页，而不是让每个页面各自报错。
  client.dio.interceptors.add(
    InterceptorsWrapper(onError: (error, handler) {
      if (error.response?.statusCode == 401) {
        ref.read(authControllerProvider.notifier).onUnauthorized();
      }
      handler.next(error);
    }),
  );
  return client;
});

/// STRM 增强接口客户端：与 Emby 同源（代理会把 /api/v1/strm/... 回环转发到主 App）。
final strmClientProvider = Provider<StrmApiClient?>((ref) {
  final session = ref.watch(authControllerProvider).session;
  if (session == null) return null;
  return StrmApiClient(baseUrl: session.serverUrl);
});
