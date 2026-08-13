import 'package:dio/dio.dart';

/// python-strm 增强接口：网盘播放档位探测与按档位播放 URL。
///
/// 代理在 PlaybackInfo 注入的播放地址形如：
///   `http://host:8097/cloudplay/{cloud}/{fileId}`
///   `http://host:8095/api/v1/strm/play/{cloud}/{fileId}`
/// 从中解析出 (cloud, fileId) 后即可调用档位接口实现客户端画质切换。
class StrmPlayTarget {
  final String cloudType;
  final String fileId;

  const StrmPlayTarget(this.cloudType, this.fileId);

  static final _patterns = [
    RegExp(r'/cloudplay/(115|quark)/([A-Za-z0-9._~-]+)'),
    RegExp(r'/api/v1/strm/play/(115|quark)/([A-Za-z0-9._~-]+)'),
    RegExp(r'/api/v1/(quark|115)/play/([A-Za-z0-9._~-]+)'),
  ];

  /// 从播放 URL 解析网盘类型与文件 ID；无法识别返回 null。
  static StrmPlayTarget? tryParse(String url) {
    for (final pattern in _patterns) {
      final match = pattern.firstMatch(url);
      if (match != null) {
        return StrmPlayTarget(match.group(1)!, match.group(2)!);
      }
    }
    return null;
  }
}

class PlaybackVariant {
  final String resolution;
  final String protocol; // direct / hls_master / hls_media
  final bool playable;

  const PlaybackVariant({
    required this.resolution,
    required this.protocol,
    this.playable = false,
  });

  factory PlaybackVariant.fromJson(Map<String, dynamic> json) =>
      PlaybackVariant(
        resolution: (json['resolution'] ?? '') as String,
        protocol: (json['protocol'] ?? '') as String,
        playable: (json['playable'] ?? false) as bool,
      );
}

class StrmApiClient {
  final Dio dio;

  StrmApiClient({required String baseUrl, Dio? dio})
      : dio = dio ?? Dio(BaseOptions(baseUrl: baseUrl)) {
    this.dio.options.baseUrl = baseUrl;
  }

  /// 已探测的可播档位列表（可能为空：从未探测过的文件）。
  Future<List<PlaybackVariant>> probeVariants(StrmPlayTarget target) async {
    try {
      final resp = await dio.get(
        '/api/v1/strm/probe/${target.cloudType}/${target.fileId}',
      );
      final data = resp.data as Map<String, dynamic>;
      return ((data['variants'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PlaybackVariant.fromJson)
          .where((v) => v.playable)
          .toList();
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return const [];
      rethrow;
    }
  }

  /// 指定档位的播放 URL（服务端 302/HLS 由播放器跟随）。
  String playUrl(StrmPlayTarget target, {String resolution = 'auto'}) {
    final base = dio.options.baseUrl.replaceAll(RegExp(r'/+$'), '');
    return '$base/api/v1/strm/play/${target.cloudType}/${target.fileId}'
        '?resolution=$resolution';
  }
}
