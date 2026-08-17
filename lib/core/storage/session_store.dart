import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// 一次登录会话：服务器地址 + 凭据。DeviceId 独立于会话，登出后仍保留
/// （Emby 按 DeviceId 归并会话，换 ID 会在服务端留下一堆孤儿设备）。
class StoredSession {
  final String serverUrl;
  final String userId;
  final String userName;
  final String token;

  const StoredSession({
    required this.serverUrl,
    required this.userId,
    required this.userName,
    required this.token,
  });

  bool get isValid =>
      serverUrl.isNotEmpty && userId.isNotEmpty && token.isNotEmpty;
}

/// 会话持久化（shared_preferences）：启动时恢复登录态，免去每次输密码。
class SessionStore {
  static const _kServerUrl = 'jellfin.server_url';
  static const _kUserId = 'jellfin.user_id';
  static const _kUserName = 'jellfin.user_name';
  static const _kToken = 'jellfin.token';
  static const _kDeviceId = 'jellfin.device_id';

  /// 上次选择的画质档位（按 cloud/file 维度太碎，全局记一个即可）。
  static const _kPreferredResolution = 'jellfin.preferred_resolution';

  final SharedPreferences _prefs;

  const SessionStore(this._prefs);

  static Future<SessionStore> open() async =>
      SessionStore(await SharedPreferences.getInstance());

  StoredSession? load() {
    final session = StoredSession(
      serverUrl: _prefs.getString(_kServerUrl) ?? '',
      userId: _prefs.getString(_kUserId) ?? '',
      userName: _prefs.getString(_kUserName) ?? '',
      token: _prefs.getString(_kToken) ?? '',
    );
    return session.isValid ? session : null;
  }

  Future<void> save(StoredSession session) async {
    await _prefs.setString(_kServerUrl, session.serverUrl);
    await _prefs.setString(_kUserId, session.userId);
    await _prefs.setString(_kUserName, session.userName);
    await _prefs.setString(_kToken, session.token);
  }

  /// 登出：清凭据但保留服务器地址（下次登录不用重输）与 DeviceId。
  Future<void> clearCredentials() async {
    await _prefs.remove(_kUserId);
    await _prefs.remove(_kUserName);
    await _prefs.remove(_kToken);
  }

  /// 设备 ID：首次调用生成并持久化，之后固定不变。
  Future<String> deviceId() async {
    final existing = _prefs.getString(_kDeviceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final generated = _generateDeviceId();
    await _prefs.setString(_kDeviceId, generated);
    return generated;
  }

  String? get preferredResolution => _prefs.getString(_kPreferredResolution);

  Future<void> setPreferredResolution(String resolution) =>
      _prefs.setString(_kPreferredResolution, resolution);

  static String _generateDeviceId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
