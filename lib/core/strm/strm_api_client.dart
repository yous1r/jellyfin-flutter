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
  final String source; // download（原画）/ transcode（转码档）
  final bool playable;

  const PlaybackVariant({
    required this.resolution,
    required this.protocol,
    this.source = '',
    this.playable = false,
  });

  factory PlaybackVariant.fromJson(Map<String, dynamic> json) =>
      PlaybackVariant(
        resolution: (json['resolution'] ?? '') as String,
        protocol: (json['protocol'] ?? '') as String,
        source: (json['source'] ?? '') as String,
        playable: (json['playable'] ?? false) as bool,
      );
}

/// 档位友好名与标称尺寸：与服务端 `_PLAYBACK_DISPLAY_NAMES` /
/// `_PLAYBACK_NOMINAL_SIZES` 保持一致，回退路径（probe）也能给出同样的菜单文案。
const _displayNames = <String, String>{
  'raw': '原画',
  '4k': '4K',
  '2k': '2K',
  'ud': '1080P',
  'super': '1080P',
  'high': '720P',
  'hd': '720P',
  'normal': '480P',
  'sd': '480P',
  'low': '360P',
};

const _nominalSizes = <String, List<int>>{
  '4k': [3840, 2160],
  '2k': [2560, 1440],
  'super': [1920, 1080],
  'ud': [1920, 1080],
  'hd': [1280, 720],
  'high': [1280, 720],
  'normal': [854, 480],
  'sd': [854, 480],
  'low': [640, 360],
};

/// 一路可播视频流：原画直链或某个转码档，客户端画质菜单的一项。
class PlaybackStream {
  final String resolution;
  final String displayName;

  /// direct / hls_master / hls_media
  final String protocol;

  /// download（原画直链）/ transcode（转码档）
  final String source;

  /// 原画：源容器直链，画质最高但可能需要更高带宽。
  final bool isOriginal;

  /// mkv（直链，实际容器由源文件决定）/ m3u8（HLS）
  final String container;
  final int? width;
  final int? height;
  final double? durationSeconds;
  final String codecs;

  /// 稳定播放地址：服务端按 resolution 实时刷新网盘直链，客户端可长期持有。
  final String url;

  /// 直链（原画）跟随后端 302 到网盘 CDN 时需要携带的请求头（115 Cookie/UA）。
  /// HLS 档位走本站代理转发，服务端注入头，此字段为空。
  final Map<String, String>? httpHeaders;

  const PlaybackStream({
    required this.resolution,
    required this.displayName,
    required this.url,
    this.protocol = '',
    this.source = '',
    this.isOriginal = false,
    this.container = '',
    this.width,
    this.height,
    this.durationSeconds,
    this.codecs = '',
    this.httpHeaders,
  });

  /// HLS 需要播放器走清单解析（Web 端要 hls.js），直链则可原生播放。
  bool get isHls => container == 'm3u8' || protocol.startsWith('hls');

  /// 菜单副标题用：`3840×2160`；分辨率未知时为空串。
  String get resolutionLabel =>
      (width != null && height != null) ? '$width×$height' : '';

  factory PlaybackStream.fromJson(Map<String, dynamic> json) => PlaybackStream(
        resolution: (json['resolution'] ?? '') as String,
        displayName: (json['display_name'] ?? json['resolution'] ?? '') as String,
        protocol: (json['protocol'] ?? '') as String,
        source: (json['source'] ?? '') as String,
        isOriginal: (json['is_original'] ?? false) as bool,
        container: (json['container'] ?? '') as String,
        width: (json['width'] as num?)?.toInt(),
        height: (json['height'] as num?)?.toInt(),
        durationSeconds: (json['duration'] as num?)?.toDouble(),
        codecs: (json['codecs'] ?? '') as String,
        url: (json['url'] ?? '') as String,
      );

  /// 服务端未开 multistream 时，用 /probe 的档位凑出等价的一路流。
  factory PlaybackStream.fromVariant(PlaybackVariant variant,
      {required String url}) {
    final nominal = _nominalSizes[variant.resolution];
    // 两个字段各司其职（与服务端 _stream_entry 一致）：
    // is_original 看 source（夸克转码档 protocol 也是 direct，只有 download 是原画）；
    // container 看 protocol（direct = 302 到真视频字节，hls_* 才是本站代理的 m3u8）。
    // 判错任一方向都会让播放器用错误的解析方式打开真实视频，起播必败。
    final isOriginal = variant.source == 'download';
    final isHlsProtocol = variant.protocol.startsWith('hls');
    return PlaybackStream(
      resolution: variant.resolution,
      displayName: _displayNames[variant.resolution] ?? variant.resolution,
      protocol: variant.protocol,
      source: variant.source,
      isOriginal: isOriginal,
      container: isHlsProtocol ? 'm3u8' : (isOriginal ? 'mkv' : 'mp4'),
      width: nominal?.first,
      height: nominal?.last,
      url: url,
    );
  }
}

/// `/api/v1/strm/streams` 的完整响应。
class StreamManifest {
  final String cloudType;
  final String fileId;
  final String defaultResolution;

  /// 合成主清单：交给播放器自适应码率（不想自己切档时用）。
  final String masterUrl;
  final List<PlaybackStream> streams;

  const StreamManifest({
    required this.cloudType,
    required this.fileId,
    required this.defaultResolution,
    required this.masterUrl,
    required this.streams,
  });

  /// 任一路流探测到的总时长（各档同源，取第一个非空值）。
  Duration? get duration {
    for (final stream in streams) {
      final seconds = stream.durationSeconds;
      if (seconds != null && seconds > 0) {
        return Duration(microseconds: (seconds * 1000000).round());
      }
    }
    return null;
  }

  PlaybackStream? get defaultStream {
    for (final stream in streams) {
      if (stream.resolution == defaultResolution) return stream;
    }
    return streams.isEmpty ? null : streams.first;
  }

  factory StreamManifest.fromJson(Map<String, dynamic> json) => StreamManifest(
        cloudType: (json['cloud_type'] ?? '') as String,
        fileId: (json['file_id'] ?? '') as String,
        defaultResolution: (json['default_resolution'] ?? '') as String,
        masterUrl: (json['master_url'] ?? '') as String,
        streams: ((json['streams'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(PlaybackStream.fromJson)
            .toList(),
      );
}

/// 一个档位解析出的「实际播放地址」，以及播放器侧仍需施加的约束。
class ResolvedPlayback {
  /// 播放器应当真正打开的地址（已收敛到目标档位）。
  final String url;

  /// 目标档位在主清单里的 BANDWIDTH。非空说明 [url] 仍是一张多变体主清单
  /// （音轨独立成组，收敛到视频媒体清单会丢音频），播放器必须把 mpv
  /// `hls-bitrate` 钉到该值——否则默认 `hls-bitrate=max` 直接选走最高码率变体。
  final int? hlsBitrate;

  const ResolvedPlayback(this.url, {this.hlsBitrate});
}

/// 主清单里的一路变体：`#EXT-X-STREAM-INF:` 属性行 + 紧随其后的 URI。
class _MasterVariant {
  final String attributes;
  final String uri;

  const _MasterVariant(this.attributes, this.uri);

  static final _attributePattern = RegExp(r'([A-Z0-9-]+)=("([^"]*)"|([^,"]*))');

  /// 取属性值（带引号的值已去引号）；未声明该属性返回 null。
  String? attribute(String name) {
    for (final match in _attributePattern.allMatches(attributes)) {
      if (match.group(1) == name) return match.group(3) ?? match.group(4);
    }
    return null;
  }

  int? get bandwidth => int.tryParse(attribute('BANDWIDTH') ?? '');
}

class StrmApiClient {
  final Dio dio;

  StrmApiClient({required String baseUrl, Dio? dio})
      : dio = dio ?? Dio(BaseOptions(baseUrl: baseUrl)) {
    this.dio.options.baseUrl = baseUrl;
    // 503（无可播档位）/404（旧服务端无该路由）都是可预期的业务分支，
    // 交给各方法自己判断，不要在 dio 层抛异常。
    this.dio.options.validateStatus =
        (status) => status != null && (status < 500 || status == 503);
  }

  /// 已探测的可播档位列表（可能为空：从未探测过的文件）。
  Future<List<PlaybackVariant>> probeVariants(StrmPlayTarget target) async {
    try {
      final resp = await dio.get(
        '/api/v1/strm/probe/${target.cloudType}/${target.fileId}',
      );
      if (resp.statusCode != 200) return const [];
      final data = resp.data;
      if (data is! Map<String, dynamic>) return const [];
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

  /// 多视频流清单；服务端未开 multistream（503）或版本较旧（404）时返回 null。
  Future<StreamManifest?> fetchStreams(StrmPlayTarget target) async {
    try {
      final resp = await dio.get(
        '/api/v1/strm/streams/${target.cloudType}/${target.fileId}',
      );
      if (resp.statusCode != 200) return null;
      final data = resp.data;
      if (data is! Map<String, dynamic>) return null;
      final manifest = StreamManifest.fromJson(data);
      return manifest.streams.isEmpty ? null : manifest;
    } on DioException {
      return null;
    }
  }

  /// 画质菜单数据源：优先多视频流清单，不可用时用 /probe 档位凑等价列表。
  ///
  /// 两条路径产出同一种 [PlaybackStream]，播放页无需区分服务端是否开了 multistream。
  Future<List<PlaybackStream>> playbackStreams(StrmPlayTarget target) async {
    final manifest = await fetchStreams(target);
    if (manifest != null) return manifest.streams;

    final variants = await probeVariants(target);
    final streams = variants
        .map((variant) => PlaybackStream.fromVariant(
              variant,
              url: playUrl(target, resolution: variant.resolution),
            ))
        .toList();
    // 与服务端一致：原画排首位，其余按像素面积降序。
    streams.sort((a, b) {
      final byOriginal = (a.isOriginal ? 0 : 1).compareTo(b.isOriginal ? 0 : 1);
      if (byOriginal != 0) return byOriginal;
      final areaA = (a.width ?? 0) * (a.height ?? 0);
      final areaB = (b.width ?? 0) * (b.height ?? 0);
      return areaB.compareTo(areaA);
    });
    return streams;
  }

  /// 把某一档位解析成播放器可以直接打开的「实际播放地址」。
  ///
  /// 服务端始终按多视频流下发：`?resolution=high` 返回的仍是含**全部**档位的主清单
  /// （实测四个 `#EXT-X-STREAM-INF`，请求的档位只是被排到第一位），而 mpv 默认
  /// `hls-bitrate=max` 只认最高码率那一路——画质菜单因此形同虚设，切了也还是最高档。
  /// 直链档位同样如此：服务端 302 到内部播放路由时会丢掉 resolution（夸克实测五个
  /// 档位重定向到同一个地址），跟随重定向的播放器拿到的永远是默认档。
  ///
  /// 所以选档只能由客户端完成，此方法就是那一步：
  /// - HLS：抓主清单，按变体 URI 里的 `/hls/{resolution}` 精确定位目标档位并收敛到
  ///   该档的媒体清单；音轨独立成组时改用 `hls-bitrate` 钉住变体
  ///   （见 [ResolvedPlayback.hlsBitrate]），避免只拿视频清单导致没声音。
  /// - 直链转码档：沿本站 origin 跟随重定向，把服务端丢掉的 resolution 补回去。
  ///
  /// 任何异常都退回服务端原始地址，绝不阻断起播。
  Future<ResolvedPlayback> resolvePlaybackUrl(PlaybackStream stream) async {
    // 原画没有「切到别的档位」这回事，而直链探测会白白多铸一条网盘直链
    // （115 风控敏感），因此直接放行。
    if (stream.isOriginal && !stream.isHls) return ResolvedPlayback(stream.url);

    try {
      final response = await dio.get<String>(
        stream.url,
        options: Options(
          responseType: ResponseType.plain,
          // 3xx 要自己读 Location 决定怎么补档位，不能让 dio 跟随或抛异常。
          followRedirects: false,
          validateStatus: (status) => status != null && status < 400,
        ),
      );
      if ((response.statusCode ?? 0) >= 300) {
        return ResolvedPlayback(
            _reattachResolution(stream, response.headers.value('location')));
      }
      final playlist = response.data;
      if (playlist != null && playlist.contains('#EXT-X-STREAM-INF')) {
        return _pinMasterVariant(stream, playlist);
      }
    } on DioException {
      // 网络抖动/服务端异常不阻断播放，退回原地址即旧行为。
    } on FormatException {
      // 非法 URI 同样不应阻断播放。
    }
    return ResolvedPlayback(stream.url);
  }

  /// 同源跳转就把服务端丢掉的档位参数补回去，让播放器直接请求真正的档位地址。
  ///
  /// 跨源（网盘 CDN）一律不动：那种直链是一次性的，且要由播放器带着自己的请求头去
  /// 换，客户端提前解析只会白铸一条链接。
  String _reattachResolution(PlaybackStream stream, String? location) {
    if (location == null || location.isEmpty) return stream.url;
    final from = Uri.parse(stream.url);
    final to = from.resolve(location);
    final sameOrigin = to.scheme == from.scheme &&
        to.host == from.host &&
        to.port == from.port;
    if (!sameOrigin) return stream.url;
    if (stream.resolution.isEmpty ||
        to.queryParameters['resolution'] == stream.resolution) {
      return to.toString();
    }
    return to
        .replace(queryParameters: {
          ...to.queryParameters,
          'resolution': stream.resolution,
        })
        .toString();
  }

  /// 在多变体主清单里定位目标档位，收敛成单一可播地址。
  ResolvedPlayback _pinMasterVariant(PlaybackStream stream, String playlist) {
    const marker = '#EXT-X-STREAM-INF:';
    final lines = playlist.split(RegExp(r'\r?\n'));
    final variants = <_MasterVariant>[];
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].trim();
      if (!line.startsWith(marker)) continue;
      for (var next = index + 1; next < lines.length; next++) {
        final uri = lines[next].trim();
        if (uri.isEmpty || uri.startsWith('#')) continue;
        variants.add(_MasterVariant(line.substring(marker.length), uri));
        break;
      }
    }
    // 只有一路变体：服务端已经收敛到位，播放器没有可选错的对象。
    if (variants.length < 2) return ResolvedPlayback(stream.url);

    final target = _matchVariant(variants, stream);
    if (target == null) return ResolvedPlayback(stream.url);

    // 音轨独立成组（115 转码档的主清单带 #EXT-X-MEDIA:TYPE=AUDIO）：变体 URI 只是
    // 视频媒体清单，单独打开会没声音。保留主清单，改用 hls-bitrate 让 mpv 自己
    // 选中这一路变体，音轨组照常生效。
    final bandwidth = target.bandwidth;
    if (playlist.contains('#EXT-X-MEDIA:TYPE=AUDIO') && bandwidth != null) {
      return ResolvedPlayback(stream.url, hlsBitrate: bandwidth);
    }
    return ResolvedPlayback(Uri.parse(stream.url).resolve(target.uri).toString());
  }

  /// 三级匹配，优先用最不容易误判的信号：
  /// 1. 变体 URI 里的 `/hls/{resolution}` 档位标识——服务端合成主清单时原样写入，
  ///    精确且唯一；
  /// 2. `NAME="1080P"` 友好名；
  /// 3. `RESOLUTION=1920x1080` 标称尺寸。
  ///
  /// 后两者会撞车（ud/super 都叫 1080P、high/hd 都是 1280x720），因此只在唯一命中时
  /// 采用——宁可退回原地址，也不要切到另一个档位上去。
  _MasterVariant? _matchVariant(
      List<_MasterVariant> variants, PlaybackStream stream) {
    if (stream.resolution.isNotEmpty) {
      final slug = RegExp('/hls/${RegExp.escape(stream.resolution)}(?:[/?]|\$)');
      for (final variant in variants) {
        if (slug.hasMatch(variant.uri)) return variant;
      }
    }
    for (final attribute in ['NAME', 'RESOLUTION']) {
      final expected = attribute == 'NAME'
          ? stream.displayName
          : (stream.width != null && stream.height != null
              ? '${stream.width}x${stream.height}'
              : '');
      if (expected.isEmpty) continue;
      final hits =
          variants.where((v) => v.attribute(attribute) == expected).toList();
      if (hits.length == 1) return hits.first;
    }
    return null;
  }

  /// 指定档位的播放 URL（服务端 302/HLS 由播放器跟随）。
  String playUrl(StrmPlayTarget target, {String resolution = 'auto'}) {
    final base = dio.options.baseUrl.replaceAll(RegExp(r'/+$'), '');
    return '$base/api/v1/strm/play/${target.cloudType}/${target.fileId}'
        '?resolution=$resolution';
  }
}
