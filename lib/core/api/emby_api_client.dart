import 'package:dio/dio.dart';

import '../app_version.dart';
import '../models/models.dart';

/// Emby/Jellyfin 协议客户端（面向 python-strm 代理，兼容标准服务端）。
///
/// 认证：所有请求带 `X-Emby-Authorization`（MediaBrowser 头），登录后追加
/// `X-Emby-Token`。该头缺失时 python-strm 代理直接 400。
class EmbyApiClient {
  final Dio dio;
  final String client;
  final String device;
  final String deviceId;
  final String version;

  String _token = '';
  String _userId = '';

  EmbyApiClient({
    required String baseUrl,
    Dio? dio,
    this.client = 'JellfinFlutter',
    this.device = 'Flutter',
    required this.deviceId,
    this.version = appVersion,
  }) : dio = dio ?? Dio(BaseOptions(baseUrl: baseUrl)) {
    this.dio.options.baseUrl = baseUrl;
    this.dio.interceptors.add(
      InterceptorsWrapper(onRequest: (options, handler) {
        options.headers['X-Emby-Authorization'] = authorizationHeader;
        if (_token.isNotEmpty) {
          options.headers['X-Emby-Token'] = _token;
        }
        handler.next(options);
      }),
    );
  }

  String get userId => _userId;
  String get token => _token;
  bool get isAuthenticated => _token.isNotEmpty && _userId.isNotEmpty;

  /// 恢复持久化会话（应用启动时使用）。
  void restoreSession({required String userId, required String token}) {
    _userId = userId;
    _token = token;
  }

  String get authorizationHeader {
    final parts = [
      'Client="$client"',
      'Device="$device"',
      'DeviceId="$deviceId"',
      'Version="$version"',
    ];
    if (_userId.isNotEmpty) parts.insert(0, 'UserId="$_userId"');
    if (_token.isNotEmpty) parts.add('Token="$_token"');
    return 'MediaBrowser ${parts.join(', ')}';
  }

  Future<AuthResult> authenticateByName(String username, String password) async {
    final resp = await dio.post(
      '/emby/Users/AuthenticateByName',
      data: {'Username': username, 'Pw': password},
    );
    final auth = AuthResult.fromJson(resp.data as Map<String, dynamic>);
    _token = auth.accessToken;
    _userId = auth.userId;
    return auth;
  }

  Future<List<LibraryView>> views() async {
    final resp = await dio.get('/emby/Users/$_userId/Views');
    return (((resp.data as Map<String, dynamic>)['Items'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(LibraryView.fromJson)
        .toList();
  }

  Future<ItemsPage> items({
    String? parentId,
    String? includeItemTypes,
    String sortBy = 'SortName',
    String sortOrder = 'Ascending',
    bool recursive = false,
    int startIndex = 0,
    int limit = 50,
    String? searchTerm,
    String fields = 'PrimaryImageAspectRatio,ProductionYear,BasicSyncInfo',
  }) async {
    final resp = await dio.get('/emby/Users/$_userId/Items', queryParameters: {
      if (parentId != null) 'ParentId': parentId,
      if (includeItemTypes != null) 'IncludeItemTypes': includeItemTypes,
      if (searchTerm != null) 'SearchTerm': searchTerm,
      'SortBy': sortBy,
      'SortOrder': sortOrder,
      'Recursive': '$recursive',
      'StartIndex': '$startIndex',
      'Limit': '$limit',
      'Fields': fields,
      'ImageTypeLimit': '1',
      'EnableImageTypes': 'Primary,Backdrop,Thumb',
    });
    return ItemsPage.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<List<BaseItem>> latest({String? parentId, int limit = 20}) async {
    final resp =
        await dio.get('/emby/Users/$_userId/Items/Latest', queryParameters: {
      if (parentId != null) 'ParentId': parentId,
      'Limit': '$limit',
      'Fields': 'PrimaryImageAspectRatio,ProductionYear,BasicSyncInfo',
      'ImageTypeLimit': '1',
      'EnableImageTypes': 'Primary,Backdrop,Thumb',
    });
    // Latest 直接返回数组（无分页壳）
    return ((resp.data as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(BaseItem.fromJson)
        .toList();
  }

  Future<ItemsPage> resume({int limit = 20}) async {
    final resp =
        await dio.get('/emby/Users/$_userId/Items/Resume', queryParameters: {
      'Recursive': 'true',
      'MediaTypes': 'Video',
      'Limit': '$limit',
      'Fields':
          'BasicSyncInfo,Container,PrimaryImageAspectRatio,ProductionYear,MediaStreams,MediaSources',
      'ImageTypeLimit': '1',
      'EnableImageTypes': 'Primary,Backdrop,Thumb',
    });
    return ItemsPage.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<ItemsPage> nextUp({String? seriesId, int limit = 20}) async {
    final resp = await dio.get('/emby/Shows/NextUp', queryParameters: {
      if (seriesId != null) 'SeriesId': seriesId,
      'UserId': _userId,
      'Limit': '$limit',
      'Fields': 'PrimaryImageAspectRatio,ProductionYear,BasicSyncInfo',
    });
    return ItemsPage.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<BaseItem> itemDetail(String itemId) async {
    final resp = await dio.get('/emby/Users/$_userId/Items/$itemId');
    return BaseItem.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<ItemsPage> seasons(String seriesId) async {
    final resp = await dio.get('/emby/Shows/$seriesId/Seasons', queryParameters: {
      'UserId': _userId,
      'Fields': 'PrimaryImageAspectRatio,BasicSyncInfo',
    });
    return ItemsPage.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<ItemsPage> episodes(String seriesId, String seasonId) async {
    final resp =
        await dio.get('/emby/Shows/$seriesId/Episodes', queryParameters: {
      'UserId': _userId,
      'SeasonId': seasonId,
      'Fields':
          'PrimaryImageAspectRatio,Overview,MediaStreams,MediaSources,BasicSyncInfo',
      'ImageTypeLimit': '1',
    });
    return ItemsPage.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<PlaybackInfoResult> playbackInfo(String itemId) async {
    final resp = await dio.post(
      '/emby/Items/$itemId/PlaybackInfo',
      queryParameters: {
        'UserId': _userId,
        'IsPlayback': 'true',
        'AutoOpenLiveStream': 'false',
        'StartTimeTicks': '0',
      },
      data: {
        'DeviceProfile': {
          'MaxStreamingBitrate': 500000000,
          'DirectPlayProfiles': [
            {'Container': 'mkv,mp4,ts,mov,avi,flv,webm', 'Type': 'Video'},
          ],
          'TranscodingProfiles': <Map<String, dynamic>>[],
          'CodecProfiles': <Map<String, dynamic>>[],
          'SubtitleProfiles': [
            {'Method': 'External', 'Format': 'srt'},
            {'Method': 'External', 'Format': 'ass'},
          ],
        },
      },
    );
    return PlaybackInfoResult.fromJson(resp.data as Map<String, dynamic>);
  }

  String imageUrl(
    String itemId, {
    String type = 'Primary',
    String? tag,
    int maxWidth = 400,
  }) {
    final query = <String, String>{
      'maxWidth': '$maxWidth',
      if (tag != null) 'tag': tag,
    };
    final qs = query.entries.map((e) => '${e.key}=${e.value}').join('&');
    return '${dio.options.baseUrl}/emby/Items/$itemId/Images/$type?$qs';
  }

  // ── 播放进度上报 ────────────────────────────────────────────────────────

  Future<void> reportPlaying({
    required String itemId,
    required String playSessionId,
    required String mediaSourceId,
    int positionTicks = 0,
  }) =>
      _reportSession('/emby/Sessions/Playing', itemId, playSessionId,
          mediaSourceId, positionTicks);

  Future<void> reportProgress({
    required String itemId,
    required String playSessionId,
    required String mediaSourceId,
    required int positionTicks,
    bool isPaused = false,
  }) =>
      _reportSession('/emby/Sessions/Playing/Progress', itemId, playSessionId,
          mediaSourceId, positionTicks,
          extra: {'IsPaused': isPaused, 'EventName': 'timeupdate'});

  Future<void> reportStopped({
    required String itemId,
    required String playSessionId,
    required String mediaSourceId,
    required int positionTicks,
  }) =>
      _reportSession('/emby/Sessions/Playing/Stopped', itemId, playSessionId,
          mediaSourceId, positionTicks);

  Future<void> _reportSession(
    String path,
    String itemId,
    String playSessionId,
    String mediaSourceId,
    int positionTicks, {
    Map<String, dynamic> extra = const {},
  }) async {
    await dio.post(path, data: {
      'ItemId': itemId,
      'PlaySessionId': playSessionId,
      'MediaSourceId': mediaSourceId,
      'PositionTicks': positionTicks,
      'CanSeek': true,
      'PlayMethod': 'DirectStream',
      ...extra,
    });
  }
}
