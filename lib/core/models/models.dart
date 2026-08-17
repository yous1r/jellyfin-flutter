/// Emby/Jellyfin 协议数据模型（仅保留 MVP 用到的字段，全部允许缺省）。
library;

class AuthResult {
  final String userId;
  final String userName;
  final String accessToken;
  final String serverId;

  const AuthResult({
    required this.userId,
    required this.userName,
    required this.accessToken,
    required this.serverId,
  });

  factory AuthResult.fromJson(Map<String, dynamic> json) {
    final user = (json['User'] as Map<String, dynamic>?) ?? const {};
    return AuthResult(
      userId: (user['Id'] ?? '') as String,
      userName: (user['Name'] ?? '') as String,
      accessToken: (json['AccessToken'] ?? '') as String,
      serverId: (json['ServerId'] ?? '') as String,
    );
  }
}

class LibraryView {
  final String id;
  final String name;
  final String collectionType;

  const LibraryView({
    required this.id,
    required this.name,
    required this.collectionType,
  });

  factory LibraryView.fromJson(Map<String, dynamic> json) => LibraryView(
        id: (json['Id'] ?? '') as String,
        name: (json['Name'] ?? '') as String,
        collectionType: (json['CollectionType'] ?? '') as String,
      );
}

class UserData {
  final double playedPercentage;
  final int playbackPositionTicks;
  final bool played;

  const UserData({
    this.playedPercentage = 0,
    this.playbackPositionTicks = 0,
    this.played = false,
  });

  factory UserData.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const UserData();
    return UserData(
      playedPercentage: ((json['PlayedPercentage'] ?? 0) as num).toDouble(),
      playbackPositionTicks: ((json['PlaybackPositionTicks'] ?? 0) as num).toInt(),
      played: (json['Played'] ?? false) as bool,
    );
  }
}

class MediaStreamInfo {
  final int index;
  final String type; // Video / Audio / Subtitle
  final String codec;
  final String language;
  final String displayTitle;
  final bool isExternal;
  final String deliveryUrl;

  const MediaStreamInfo({
    required this.index,
    required this.type,
    this.codec = '',
    this.language = '',
    this.displayTitle = '',
    this.isExternal = false,
    this.deliveryUrl = '',
  });

  factory MediaStreamInfo.fromJson(Map<String, dynamic> json) => MediaStreamInfo(
        index: ((json['Index'] ?? -1) as num).toInt(),
        type: (json['Type'] ?? '') as String,
        codec: (json['Codec'] ?? '') as String,
        language: (json['Language'] ?? '') as String,
        displayTitle: (json['DisplayTitle'] ?? '') as String,
        isExternal: (json['IsExternal'] ?? false) as bool,
        deliveryUrl: (json['DeliveryUrl'] ?? '') as String,
      );
}

class MediaSourceInfo {
  final String id;
  final String name;
  final String directStreamUrl;
  final String path;
  final String container;
  final List<MediaStreamInfo> mediaStreams;

  /// 直链播放需要携带的 HTTP 请求头（网盘 Cookie/UA）。
  /// 服务端在 PlaybackInfo 的 MediaSource 上按 RequiredHttpHeaders 下发。
  final Map<String, String> requiredHttpHeaders;

  const MediaSourceInfo({
    required this.id,
    this.name = '',
    this.directStreamUrl = '',
    this.path = '',
    this.container = '',
    this.mediaStreams = const [],
    this.requiredHttpHeaders = const {},
  });

  /// 播放优先取 DirectStreamUrl，缺省回落 Path。
  String get playUrl => directStreamUrl.isNotEmpty ? directStreamUrl : path;

  factory MediaSourceInfo.fromJson(Map<String, dynamic> json) => MediaSourceInfo(
        id: (json['Id'] ?? '') as String,
        name: (json['Name'] ?? '') as String,
        directStreamUrl: (json['DirectStreamUrl'] ?? '') as String,
        path: (json['Path'] ?? '') as String,
        container: (json['Container'] ?? '') as String,
        mediaStreams: ((json['MediaStreams'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(MediaStreamInfo.fromJson)
            .toList(),
        requiredHttpHeaders:
            ((json['RequiredHttpHeaders'] as Map?) ?? const {})
                .map((k, v) => MapEntry(k.toString(), v.toString())),
      );
}

class PlaybackInfoResult {
  final List<MediaSourceInfo> mediaSources;
  final String playSessionId;

  const PlaybackInfoResult({
    this.mediaSources = const [],
    this.playSessionId = '',
  });

  factory PlaybackInfoResult.fromJson(Map<String, dynamic> json) =>
      PlaybackInfoResult(
        mediaSources: ((json['MediaSources'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(MediaSourceInfo.fromJson)
            .toList(),
        playSessionId: (json['PlaySessionId'] ?? '') as String,
      );
}

class BaseItem {
  final String id;
  final String name;
  final String type; // Movie / Series / Season / Episode / ...
  final String seriesName;
  final String seriesId;
  final String seasonId;
  final int? indexNumber;
  final int? parentIndexNumber;
  final int? productionYear;
  final int runTimeTicks;
  final double primaryImageAspectRatio;
  final Map<String, String> imageTags;
  final String overview;
  final UserData userData;
  final List<MediaSourceInfo> mediaSources;
  final List<MediaStreamInfo> mediaStreams;

  const BaseItem({
    required this.id,
    required this.name,
    required this.type,
    this.seriesName = '',
    this.seriesId = '',
    this.seasonId = '',
    this.indexNumber,
    this.parentIndexNumber,
    this.productionYear,
    this.runTimeTicks = 0,
    this.primaryImageAspectRatio = 0,
    this.imageTags = const {},
    this.overview = '',
    this.userData = const UserData(),
    this.mediaSources = const [],
    this.mediaStreams = const [],
  });

  /// 卡片副标题：剧集显示「剧名 · S1E2」，其余显示年份。
  String get subtitle {
    if (type == 'Episode') {
      final season = parentIndexNumber;
      final episode = indexNumber;
      final code =
          (season != null && episode != null) ? 'S${season}E$episode' : '';
      return [seriesName, code].where((v) => v.isNotEmpty).join(' · ');
    }
    return productionYear?.toString() ?? '';
  }

  /// Emby 的 tick 是 100 纳秒。
  Duration get runtime => Duration(microseconds: runTimeTicks ~/ 10);

  /// 上次播放到的位置，用于断点续播。
  Duration get resumePosition =>
      Duration(microseconds: userData.playbackPositionTicks ~/ 10);

  bool get canResume =>
      userData.playbackPositionTicks > 0 && userData.playedPercentage < 95;

  factory BaseItem.fromJson(Map<String, dynamic> json) => BaseItem(
        id: (json['Id'] ?? '') as String,
        name: (json['Name'] ?? '') as String,
        type: (json['Type'] ?? '') as String,
        seriesName: (json['SeriesName'] ?? '') as String,
        seriesId: (json['SeriesId'] ?? '') as String,
        seasonId: (json['SeasonId'] ?? '') as String,
        indexNumber: (json['IndexNumber'] as num?)?.toInt(),
        parentIndexNumber: (json['ParentIndexNumber'] as num?)?.toInt(),
        productionYear: (json['ProductionYear'] as num?)?.toInt(),
        runTimeTicks: ((json['RunTimeTicks'] ?? 0) as num).toInt(),
        primaryImageAspectRatio:
            ((json['PrimaryImageAspectRatio'] ?? 0) as num).toDouble(),
        imageTags: ((json['ImageTags'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k.toString(), v.toString())),
        overview: (json['Overview'] ?? '') as String,
        userData: UserData.fromJson(json['UserData'] as Map<String, dynamic>?),
        mediaSources: ((json['MediaSources'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(MediaSourceInfo.fromJson)
            .toList(),
        mediaStreams: ((json['MediaStreams'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(MediaStreamInfo.fromJson)
            .toList(),
      );
}

class ItemsPage {
  final List<BaseItem> items;
  final int totalRecordCount;

  const ItemsPage({this.items = const [], this.totalRecordCount = 0});

  factory ItemsPage.fromJson(Map<String, dynamic> json) => ItemsPage(
        items: ((json['Items'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(BaseItem.fromJson)
            .toList(),
        totalRecordCount: ((json['TotalRecordCount'] ?? 0) as num).toInt(),
      );
}
