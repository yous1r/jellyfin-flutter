import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 预置一条带非 200 状态码的响应（如 503：服务端探测不到可播档位）。
class FakeResponse {
  final int statusCode;
  final Object body;

  /// 额外响应头，如 302 的 `location`（验证客户端如何处理服务端重定向）。
  final Map<String, String> headers;

  const FakeResponse(this.statusCode,
      [this.body = const {}, this.headers = const {}]);
}

/// 按「METHOD 路径前缀」匹配返回预置响应的 dio 适配器，供单测离线复现服务端行为。
class FakeAdapter implements HttpClientAdapter {
  /// key 形如 'GET /emby/Users/u1/Views'，按注册顺序前缀匹配；带 `?` 的 key
  /// （如 'GET /api/v1/strm/play/quark/f1?resolution=low'）则连 query 一起匹配，
  /// 用来区分同一路由的不同档位。
  /// value 是 JSON 文本 / 可编码对象，或 [FakeResponse]（需要指定状态码/响应头时）。
  final Map<String, Object> routes;
  final List<RequestOptions> requests = [];

  FakeAdapter(this.routes);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = '${options.method} ${options.uri.path}';
    final query = options.uri.query;
    final withQuery = query.isEmpty ? path : '$path?$query';
    for (final entry in routes.entries) {
      final target = entry.key.contains('?') ? withQuery : path;
      if (target.startsWith(entry.key)) {
        final value = entry.value;
        final status = value is FakeResponse ? value.statusCode : 200;
        final body = value is FakeResponse ? value.body : value;
        final extra = value is FakeResponse ? value.headers : const <String, String>{};
        final text = body is String ? body : jsonEncode(body);
        return ResponseBody.fromString(
          text,
          status,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
            for (final header in extra.entries) header.key: [header.value],
          },
        );
      }
    }
    return ResponseBody.fromString('{"error":"no fake route for $path"}', 404,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        });
  }

  @override
  void close({bool force = false}) {}
}
